// Exercise the actual startup path, including its screen-relative AppKit
// initializer and first-frame presentation. No screenshot permission is needed;
// startup checks briefly display the demo card on each connected screen.
#define main boomer_main
#import "../src/main.m"
#undef main

// Exercise the resident lifecycle without competing for the user's shortcut.
// Registration and real Carbon event dispatch are covered by test-hotkey.
@interface BMTestController : BMController
@end
@implementation BMTestController

- (void)installResidentControls {
}

@end

@interface BMCountingCapture : BMCapture
@property NSUInteger starts, invalidations;
@end
@implementation BMCountingCapture

- (void)startLive {
    ++self.starts;
}

- (void)warmUp {
}

- (void)invalidate {
    ++self.invalidations;
    [super invalidate];
}

@end

static void RunFor(double seconds) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:deadline];
}

@interface BMStartupRenderer : BMRenderer
@property NSUInteger unavailableFrames, startupFrames;
@property BOOL exposedEmptyWindow;
@end
@implementation BMStartupRenderer

- (BOOL)drawInView:(MTKView *)view uniforms:(BMUniforms)uniforms {
    if (view.presentsWithTransaction && view.window.visible)
        self.exposedEmptyWindow = YES;
    if (self.unavailableFrames) {
        --self.unavailableFrames;
        return NO;
    }
    BOOL drawn = [super drawInView:view uniforms:uniforms];
    if (drawn && view.presentsWithTransaction)
        ++self.startupFrames;
    return drawn;
}

@end

static BOOL CheckStartup(BMController *controller) {
    BMWindow *window = [controller valueForKey:@"window"];
    BMView *view = [controller valueForKey:@"view"];
    NSError *error = nil;
    BMStartupRenderer *renderer = [[BMStartupRenderer alloc] initWithError:&error];
    if (!renderer) {
        fprintf(stderr, "FAIL startup renderer: %s\n", error.localizedDescription.UTF8String);
        return NO;
    }
    [controller setValue:renderer forKey:@"renderer"];
    // Simulate temporary drawable starvation. Startup must remain hidden and
    // retry even though the camera is idle and the display timer is paused.
    renderer.unavailableFrames = 2;
    [controller begin];
    BOOL hiddenUntilReady = !window.visible && ![[controller valueForKey:@"shown"] boolValue];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:4];
    while (!window.visible && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                               beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
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

static BOOL CheckEarlyCapture(void) {
    BMOptions *options = [BMOptions new];
    options.demo = YES;
    options.displayIndex = 0;
    options.configPath = @"/dev/null";
    options.delay = options.quitAfter = 3600;
    BMController *controller = [BMTestController new];
    controller.options = options;
    [controller setValue:@YES forKey:@"sessionActive"];
    CVPixelBufferRef buffer = NULL;
    NSDictionary *attributes = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
        (id)kCVPixelBufferMetalCompatibilityKey : @YES
    };
    if (CVPixelBufferCreate(NULL, 8, 8, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attributes, &buffer) != kCVReturnSuccess)
        return NO;
    CVPixelBufferLockBaseAddress(buffer, 0);
    memset(CVPixelBufferGetBaseAddress(buffer), 255, CVPixelBufferGetBytesPerRow(buffer) * 8);
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    // Simulate capture beating AppKit startup, then ending its callback.
    [controller captureFrame:buffer];
    CVPixelBufferRelease(buffer);
    [controller applicationDidFinishLaunching:
                    [NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification
                                                  object:NSApp]];
    BMRenderer *renderer = [controller valueForKey:@"renderer"];
    NSWindow *window = [controller valueForKey:@"window"];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:4];
    while (!window.visible && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                               beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    BOOL passed = window.visible && CGSizeEqualToSize(renderer.imageSize, CGSizeMake(8, 8));
    [controller
        applicationWillTerminate:[NSNotification
                                     notificationWithName:NSApplicationWillTerminateNotification
                                                   object:NSApp]];
    fprintf(stderr, "%s capture before window setup: retained and presented after setup\n",
            passed ? "PASS" : "FAIL");
    return passed;
}

static BOOL CheckResidentCycle(BMController *controller) {
    BMWindow *window = [controller valueForKey:@"window"];
    BMView *view = [controller valueForKey:@"view"];
    BMStartupRenderer *renderer = [controller valueForKey:@"renderer"];
    controller.options.delay = 0;
    [controller setValue:@YES forKey:@"mirror"];
    NSEvent *escape = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                       location:NSZeroPoint
                                  modifierFlags:0
                                      timestamp:0
                                   windowNumber:window.windowNumber
                                        context:nil
                                     characters:@"\033"
                    charactersIgnoringModifiers:@"\033"
                                      isARepeat:NO
                                        keyCode:53];
    [controller key:escape];
    BOOL hidden = !window.visible && view.paused && renderer.imageSize.width == 0 &&
                  ![[controller valueForKey:@"shown"] boolValue] &&
                  ![[controller valueForKey:@"sessionActive"] boolValue] &&
                  ![[controller valueForKey:@"quitting"] boolValue];
    [controller applicationShouldHandleReopen:NSApp hasVisibleWindows:NO];
    BOOL reused = window == [controller valueForKey:@"window"] &&
                  renderer == [controller valueForKey:@"renderer"] && window.visible &&
                  ![[controller valueForKey:@"mirror"] boolValue] && renderer.startupFrames == 2;
    [controller applicationShouldHandleReopen:NSApp hasVisibleWindows:YES];
    BOOL noDuplicate = renderer.startupFrames == 2;
    [controller dismissSession];
    renderer.unavailableFrames = 2;
    [controller toggleCapture:nil]; // Waiting for a drawable.
    [controller toggleCapture:nil]; // Cancel before the scheduled retry.
    RunFor(0.06);
    BOOL canceled = !window.visible && view.paused && renderer.startupFrames == 2;
    renderer.unavailableFrames = 0;
    [controller toggleCapture:nil];
    BOOL fresh = window.visible && renderer.startupFrames == 3 && !renderer.exposedEmptyWindow;
    [controller dismissSession];
    BMCountingCapture *capture = [BMCountingCapture new];
    [controller setValue:capture forKey:@"capture"];
    controller.options.live = YES;
    [controller startSession]; // Schedule live capture after the first frame.
    [controller dismissSession];
    controller.options.live = NO;
    [controller startSession];
    RunFor(0.22);
    BOOL noStaleLive = capture.starts == 0 && window.visible;
    [controller screensChanged:nil];
    BOOL screenChange = !window.visible && capture.invalidations == 1 &&
                        ![[controller valueForKey:@"quitting"] boolValue];
    BOOL passed =
        hidden && reused && noDuplicate && canceled && fresh && noStaleLive && screenChange;
    fprintf(stderr,
            "%s resident: hide/reopen, reuse/reset, cancel retry, stale live timer, display "
            "invalidation\n",
            passed ? "PASS" : "FAIL");
    if (!passed)
        fprintf(stderr,
                "  hidden=%d reused=%d duplicate=%d canceled=%d fresh=%d live=%d screens=%d\n",
                hidden, reused, noDuplicate, canceled, fresh, noStaleLive, screenChange);
    return passed;
}

static BOOL CheckBackgroundStartup(void) {
    BMOptions *options = [BMOptions new];
    options.demo = options.background = YES;
    options.displayIndex = 0;
    options.configPath = @"/dev/null";
    options.quitAfter = 3600;
    BMController *controller = [BMTestController new];
    controller.options = options;
    [controller applicationDidFinishLaunching:
                    [NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification
                                                  object:NSApp]];
    NSWindow *window = [controller valueForKey:@"window"];
    BMRenderer *renderer = [controller valueForKey:@"renderer"];
    BOOL hidden = !window.visible && ![[controller valueForKey:@"sessionActive"] boolValue] &&
                  renderer.imageSize.width == 0;
    [controller toggleCapture:nil];
    BOOL shown = window.visible;
    [controller windowShouldClose:window];
    BOOL stays = !window.visible && ![[controller valueForKey:@"quitting"] boolValue];
    [controller
        applicationWillTerminate:[NSNotification
                                     notificationWithName:NSApplicationWillTerminateNotification
                                                   object:NSApp]];
    fprintf(stderr, "%s background: no initial capture, hotkey opens, close hides\n",
            hidden && shown && stays ? "PASS" : "FAIL");
    return hidden && shown && stays;
}

static BOOL CheckDisplaySwitch(NSArray<NSScreen *> *screens) {
    BOOL passed = YES;
    for (int windowed = 0; windowed < 2; ++windowed) {
        BMOptions *options = [BMOptions new];
        options.demo = options.background = YES;
        options.windowed = windowed;
        options.configPath = @"/dev/null";
        options.quitAfter = 3600;
        BMController *controller = [BMTestController new];
        controller.options = options;
        [controller
            applicationDidFinishLaunching:
                [NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification
                                              object:NSApp]];
        NSWindow *window = [controller valueForKey:@"window"];
        BMRenderer *renderer = [controller valueForKey:@"renderer"];
        for (NSUInteger step = 0; step <= screens.count; ++step) {
            NSUInteger index = step % screens.count;
            options.displayIndex = (NSInteger)index;
            [controller startSession];
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:4];
            while (!window.visible && deadline.timeIntervalSinceNow > 0)
                [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                                       beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
            NSRect content = [window contentRectForFrameRect:window.frame];
            NSRect expected = windowed ? screens[index].visibleFrame : screens[index].frame;
            BMView *view = [controller valueForKey:@"view"];
            passed &= window.visible && window == [controller valueForKey:@"window"] &&
                      renderer == [controller valueForKey:@"renderer"] &&
                      fabs(NSMidX(content) - NSMidX(expected)) <= 1 &&
                      fabs(NSMidY(content) - NSMidY(expected)) <= 1 &&
                      NSEqualSizes(view.drawableSize, [view convertRectToBacking:view.bounds].size);
            [controller dismissSession];
        }
        [controller
            applicationWillTerminate:[NSNotification
                                         notificationWithName:NSApplicationWillTerminateNotification
                                                       object:NSApp]];
    }
    fprintf(stderr,
            "%s resident: same window/renderer moves between displays and back at correct backing "
            "scale\n",
            passed ? "PASS" : "FAIL");
    return passed;
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
        if (!CheckEarlyCapture())
            ++failures;
        if (!CheckBackgroundStartup())
            ++failures;
        if (!CheckDisplaySwitch(screens))
            ++failures;
        for (NSUInteger index = 0; index < screens.count; ++index) {
            NSScreen *screen = screens[index];
            if (!NSEqualPoints(screen.frame.origin, NSZeroPoint))
                testedSecondaryOrigin = YES;
            for (int windowed = 0; windowed <= 1; ++windowed) {
                BMOptions *options = [BMOptions new];
                options.demo = YES;
                options.windowed = windowed;
                options.displayIndex = (NSInteger)index;
                options.configPath = @"/dev/null";
                options.delay = 3600; // Inspect geometry before begin/capture.
                options.quitAfter =
                    3600; // Fail promptly on errors; don't quit during the test run.
                BMController *controller = [BMTestController new];
                controller.options = options;
                [controller applicationDidFinishLaunching:
                                [NSNotification
                                    notificationWithName:NSApplicationDidFinishLaunchingNotification
                                                  object:NSApp]];
                NSWindow *window = [controller valueForKey:@"window"];
                NSRect content = [window contentRectForFrameRect:window.frame];
                NSRect expected = screen.frame;
                if (windowed) {
                    NSRect visible = screen.visibleFrame;
                    NSSize size = NSMakeSize(MIN(1100, visible.size.width * 0.85),
                                             MIN(720, visible.size.height * 0.85));
                    expected =
                        NSMakeRect(NSMidX(visible) - size.width / 2,
                                   NSMidY(visible) - size.height / 2, size.width, size.height);
                }
                // AppKit may round window geometry to backing pixels.
                BOOL matches = fabs(content.origin.x - expected.origin.x) <= 1 &&
                               fabs(content.origin.y - expected.origin.y) <= 1 &&
                               fabs(content.size.width - expected.size.width) <= 1 &&
                               fabs(content.size.height - expected.size.height) <= 1;
                fprintf(stderr, "%s display %lu (%s), %s: expected %s, got %s\n",
                        matches ? "PASS" : "FAIL", (unsigned long)index,
                        screen.localizedName.UTF8String, windowed ? "windowed" : "overlay",
                        NSStringFromRect(expected).UTF8String,
                        NSStringFromRect(content).UTF8String);
                if (!matches)
                    ++failures;
                if (!CheckStartup(controller))
                    ++failures;
                if (!CheckResidentCycle(controller))
                    ++failures;
                [controller
                    applicationWillTerminate:
                        [NSNotification notificationWithName:NSApplicationWillTerminateNotification
                                                      object:NSApp]];
            }
        }
        if (!testedSecondaryOrigin)
            fprintf(stderr, "NOTE: connect a second display to test a nonzero screen origin.\n");
        return failures ? 1 : 0;
    }
}
