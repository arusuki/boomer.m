// Exercise the actual startup path, including its screen-relative AppKit
// initializer. No screenshot permission or visible windows are required.
#define main boomer_main
#import "../src/main.m"
#undef main

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
                options.quitAfter = 1; // Fail promptly if Metal initialization fails.
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
                [controller applicationWillTerminate:[NSNotification
                    notificationWithName:NSApplicationWillTerminateNotification object:NSApp]];
            }
        }
        if (!testedSecondaryOrigin)
            fprintf(stderr, "NOTE: connect a second display to test a nonzero screen origin.\n");
        return failures ? 1 : 0;
    }
}
