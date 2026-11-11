// Exercise the actual startup path, including its screen-relative AppKit
// initializer and first-frame presentation. No screenshot permission is needed;
// startup checks briefly display the demo card on each connected screen.
#define main boomer_main
#import "../src/main.m"
#undef main

@interface BMStartupRenderer : BMRenderer
@property NSUInteger unavailableFrames, startupFrames;
@property BOOL exposedEmptyWindow;
@end
@implementation BMStartupRenderer
- (BOOL)drawInView:(MTKView *)view uniforms:(BMUniforms)uniforms {
    if (view.presentsWithTransaction && view.window.visible) self.exposedEmptyWindow = YES;
    if (self.unavailableFrames) { --self.unavailableFrames; return NO; }
    BOOL drawn = [super drawInView:view uniforms:uniforms];
    if (drawn && view.presentsWithTransaction) ++self.startupFrames;
    return drawn;
}
@end

static BOOL CheckStartup(BMController *controller) {
    BMWindow *window = [controller valueForKey:@"window"];
    BMView *view = [controller valueForKey:@"view"];
    NSError *error = nil;
    BMStartupRenderer *renderer = [[BMStartupRenderer alloc] initWithError:&error];
    if (!renderer) { fprintf(stderr, "FAIL startup renderer: %s\n", error.localizedDescription.UTF8String); return NO; }
    [controller setValue:renderer forKey:@"renderer"];
    // Simulate temporary drawable starvation. Startup must remain hidden and
    // retry even though the camera is idle and the display timer is paused.
    renderer.unavailableFrames = 2;
    [controller begin];
    BOOL hiddenUntilReady = !window.visible && ![[controller valueForKey:@"shown"] boolValue];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:4];
    while (!window.visible && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    NSSize expected = [view convertRectToBacking:view.bounds].size;
    BOOL ready = hiddenUntilReady && window.visible && renderer.startupFrames == 1 &&
        !renderer.exposedEmptyWindow && !view.presentsWithTransaction &&
        NSEqualSizes(view.drawableSize, expected);
    // Once shown, a skipped idle frame must keep drawing until it succeeds.
    renderer.unavailableFrames = 1;
    [view draw];
    BOOL retriesIdleFrame = !view.paused;
    [view draw];
    BOOL pausesAfterSuccess = view.paused;
    fprintf(stderr, "%s first frame: hidden until rendered, backing pixels, retry, then idle\n",
        ready && retriesIdleFrame && pausesAfterSuccess ? "PASS" : "FAIL");
    return ready && retriesIdleFrame && pausesAfterSuccess;
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSArray<NSScreen *> *screens = NSScreen.screens;
        if (!screens.count) {
            fprintf(stderr, "Window tests require a graphical user session.\n");
            return 1;
        }
        BOOL testedSecondaryOrigin = NO;
        int failures = 0;
        for (NSUInteger index = 0; index < screens.count; ++index) {
            NSScreen *screen = screens[index];
            if (!NSEqualPoints(screen.frame.origin, NSZeroPoint)) testedSecondaryOrigin = YES;
            for (int windowed = 0; windowed <= 1; ++windowed) {
                BMOptions *options = [BMOptions new];
                options.demo = YES;
                options.windowed = windowed;
                options.displayIndex = (NSInteger)index;
                options.configPath = @"/dev/null";
                options.delay = 3600; // Inspect geometry before begin/capture.
                options.quitAfter = 3600; // Fail promptly on errors; don't quit during the test run.
                BMController *controller = [BMController new];
                controller.options = options;
                [controller applicationDidFinishLaunching:[NSNotification
                    notificationWithName:NSApplicationDidFinishLaunchingNotification object:NSApp]];
                NSWindow *window = [controller valueForKey:@"window"];
                NSRect content = [window contentRectForFrameRect:window.frame];
                NSRect expected = screen.frame;
                if (windowed) {
                    NSRect visible = screen.visibleFrame;
                    NSSize size = NSMakeSize(MIN(1100, visible.size.width * 0.85),
                                            MIN(720, visible.size.height * 0.85));
                    expected = NSMakeRect(NSMidX(visible) - size.width / 2,
                                          NSMidY(visible) - size.height / 2,
                                          size.width, size.height);
                }
                // AppKit may round window geometry to backing pixels.
                BOOL matches = fabs(content.origin.x - expected.origin.x) <= 1 &&
                    fabs(content.origin.y - expected.origin.y) <= 1 &&
                    fabs(content.size.width - expected.size.width) <= 1 &&
                    fabs(content.size.height - expected.size.height) <= 1;
                fprintf(stderr, "%s display %lu (%s), %s: expected %s, got %s\n",
                    matches ? "PASS" : "FAIL", (unsigned long)index,
                    screen.localizedName.UTF8String, windowed ? "windowed" : "overlay",
                    NSStringFromRect(expected).UTF8String, NSStringFromRect(content).UTF8String);
                if (!matches) ++failures;
                if (!CheckStartup(controller)) ++failures;
                [controller applicationWillTerminate:[NSNotification
                    notificationWithName:NSApplicationWillTerminateNotification object:NSApp]];
            }
        }
        if (!testedSecondaryOrigin)
            fprintf(stderr, "NOTE: connect a second display to test a nonzero screen origin.\n");
        return failures ? 1 : 0;
    }
}
