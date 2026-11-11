#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <ImageIO/ImageIO.h>
#import "Camera.h"
#import "Renderer.h"
#import "Capture.h"
#include <errno.h>

static NSString *const Version = @"boomer.m 0.1.1";
static const char *DefaultConfig =
    "# Boomer.m — ~/.config/boomer/config (or $XDG_CONFIG_HOME/boomer/config)\n"
    "min_scale = 0.01\nmax_scale = 64\nscroll_speed = 1.5\n"
    "drag_friction = 6\nscale_friction = 12\n"
    "flashlight_radius = 200\nflashlight_dim = 0.8\n"
    "# 0 = nearest, 1 = linear, 2 = bicubic (smooth text)\nfilter_mode = 2\n";

@interface BMOptions : NSObject
@property BOOL windowed, demo, live, selfTest, listDisplays;
@property NSInteger displayIndex;
@property double delay, quitAfter;
@property(copy) NSString *imagePath, *configPath, *shaderPath, *generatedConfigPath;
@property BOOL explicitConfig;
@end
@implementation BMOptions
@end

static void Usage(void) {
    puts("Usage: boomer [OPTIONS]\n"
         "  -h, --help               Show help\n"
         "  -V, --version            Print version\n"
         "  -w, --windowed           Use a resizable window\n"
         "  -d, --delay SECONDS      Delay capture (0–3600)\n"
         "  -c, --config PATH        Load a configuration file\n"
         "      --new-config [PATH]  Create default config; never overwrite\n"
         "      --list-displays      List display indices\n"
         "      --display INDEX      Capture this display (default: under pointer)\n"
         "      --live               Start live capture; L freezes/resumes\n"
         "      --image PATH         Open an image without screen capture\n"
         "      --demo               Built-in test card; no capture permission\n"
         "      --shader PATH        Load Metal source; Ctrl-R reloads it\n"
         "      --self-test          Run offscreen Metal rendering tests\n"
         "      --quit-after SECONDS Auto-quit after startup (for smoke tests)\n\n"
         "Controls: wheel / +/- / pinch = zoom at pointer, left drag = pan\n"
         "          0 = reset, M = mirror, F = flashlight, Ctrl-wheel = radius\n"
         "          R = reload config, L = live/freeze, Space = refresh screenshot\n"
         "          P = nearest/linear/bicubic filtering, H / ? = help, Q / Esc = quit");
}
static BOOL ParseNumber(NSString *s, double lo, double hi, double *out) {
    const char *raw = s.UTF8String; char *end;
    errno = 0; double n = strtod(raw, &end);
    if (raw == end || *end || errno || !isfinite(n) || n < lo || n > hi) return NO;
    *out = n; return YES;
}
static BMOptions *ParseOptions(int argc, const char **argv, int *result) {
    BMOptions *o = [BMOptions new]; o.displayIndex = -1;
    NSString *xdg = NSProcessInfo.processInfo.environment[@"XDG_CONFIG_HOME"];
    o.configPath = [(xdg.length ? xdg : [NSHomeDirectory() stringByAppendingPathComponent:@".config"])
        stringByAppendingPathComponent:@"boomer/config"];
    *result = 0;
    for (int i = 1; i < argc; ++i) {
        NSString *a = @(argv[i]);
        if ([a isEqual:@"--help"] || [a isEqual:@"-h"]) { Usage(); return nil; }
        if ([a isEqual:@"--version"] || [a isEqual:@"-V"]) { puts(Version.UTF8String); return nil; }
        if ([a hasPrefix:@"-psn_"]) continue;
        if ([a isEqual:@"--windowed"] || [a isEqual:@"-w"]) o.windowed = YES;
        else if ([a isEqual:@"--demo"]) o.demo = YES;
        else if ([a isEqual:@"--live"]) o.live = YES;
        else if ([a isEqual:@"--self-test"]) o.selfTest = YES;
        else if ([a isEqual:@"--list-displays"]) o.listDisplays = YES;
        else if ([a isEqual:@"--new-config"]) {
            o.generatedConfigPath = i + 1 < argc && argv[i + 1][0] != '-' ? @(argv[++i]) : o.configPath;
        } else {
            BOOL numeric = [a isEqual:@"--delay"] || [a isEqual:@"-d"] || [a isEqual:@"--quit-after"] || [a isEqual:@"--display"];
            BOOL path = [a isEqual:@"--config"] || [a isEqual:@"-c"] || [a isEqual:@"--image"] || [a isEqual:@"--shader"];
            if ((!numeric && !path) || i + 1 == argc) {
                fprintf(stderr, "Invalid option or missing value: %s\n", argv[i]); *result = 2; return nil;
            }
            NSString *value = @(argv[++i]);
            if (numeric) {
                double number;
                if (!ParseNumber(value, 0, [a isEqual:@"--display"] ? 128 : 3600, &number) ||
                    ([a isEqual:@"--display"] && number != floor(number))) {
                    fprintf(stderr, "Invalid value for %s: %s\n", a.UTF8String, value.UTF8String); *result = 2; return nil;
                }
                if ([a isEqual:@"--display"]) o.displayIndex = (NSInteger)number;
                else if ([a isEqual:@"--quit-after"]) o.quitAfter = number;
                else o.delay = number;
            } else if ([a isEqual:@"--image"]) o.imagePath = value.stringByExpandingTildeInPath;
            else if ([a isEqual:@"--shader"]) o.shaderPath = value.stringByExpandingTildeInPath;
            else { o.configPath = value.stringByExpandingTildeInPath; o.explicitConfig = YES; }
        }
    }
    if ((o.demo && o.imagePath) || (o.live && (o.demo || o.imagePath))) {
        fprintf(stderr, "--demo, --image and --live cannot be combined.\n"); *result = 2; return nil;
    }
    return o;
}

static CGImageRef CreateDemoImage(void) CF_RETURNS_RETAINED;
static CGImageRef CreateDemoImage(void) {
    const size_t w = 1600, h = 1000;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, w * 4, space,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    if (!ctx) return NULL;
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
    [[NSColor colorWithSRGBRed:0.055 green:0.07 blue:0.095 alpha:1] setFill];
    NSRectFill(NSMakeRect(0,0,w,h));
    [[NSColor colorWithSRGBRed:0.12 green:0.15 blue:0.19 alpha:1] setStroke];
    NSBezierPath *grid = [NSBezierPath bezierPath]; grid.lineWidth = 1;
    for (int x = 0; x < (int)w; x += 40) { [grid moveToPoint:NSMakePoint(x,0)]; [grid lineToPoint:NSMakePoint(x,h)]; }
    for (int y = 0; y < (int)h; y += 40) { [grid moveToPoint:NSMakePoint(0,y)]; [grid lineToPoint:NSMakePoint(w,y)]; }
    [grid stroke];
    NSDictionary *title = @{NSFontAttributeName:[NSFont systemFontOfSize:96 weight:NSFontWeightBold], NSForegroundColorAttributeName:NSColor.whiteColor};
    [@"boomer.m" drawAtPoint:NSMakePoint(100,730) withAttributes:title];
    NSDictionary *body = @{NSFontAttributeName:[NSFont monospacedSystemFontOfSize:25 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName:[NSColor colorWithSRGBRed:0.63 green:0.73 blue:0.82 alpha:1]};
    [@"A closer look.  C / Objective-C + Metal." drawAtPoint:NSMakePoint(105,680) withAttributes:body];
    NSArray<NSColor *> *colors = @[[NSColor colorWithSRGBRed:0.98 green:0.37 blue:0.28 alpha:1],
        [NSColor colorWithSRGBRed:0.98 green:0.76 blue:0.28 alpha:1],
        [NSColor colorWithSRGBRed:0.30 green:0.79 blue:0.65 alpha:1],
        [NSColor colorWithSRGBRed:0.29 green:0.59 blue:0.94 alpha:1]];
    for (int i = 0; i < 4; ++i) {
        [colors[i] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(105 + i * 355,350,320,230) xRadius:20 yRadius:20] fill];
        [[NSString stringWithFormat:@"0%d", i + 1] drawAtPoint:NSMakePoint(130 + i * 355,405)
            withAttributes:@{NSFontAttributeName:[NSFont monospacedSystemFontOfSize:72 weight:NSFontWeightBold],
                            NSForegroundColorAttributeName:[NSColor colorWithWhite:0.08 alpha:1]}];
    }
    [@"SCROLL / PINCH   Zoom at cursor      DRAG   Pan" drawAtPoint:NSMakePoint(105,235) withAttributes:body];
    [@"F   Flashlight     M   Mirror     0   Reset     H   Help" drawAtPoint:NSMakePoint(105,185) withAttributes:body];
    [@"TOP LEFT" drawAtPoint:NSMakePoint(32,950) withAttributes:body];
    [@"BOTTOM RIGHT" drawAtPoint:NSMakePoint(1360,25) withAttributes:body];
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    [NSGraphicsContext restoreGraphicsState]; CGContextRelease(ctx);
    return image;
}

@class BMController;
@interface BMWindow : NSWindow
@end
@implementation BMWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

@interface BMView : MTKView
@property(nonatomic, weak) BMController *controller;
@end

@interface BMController : NSObject <NSApplicationDelegate, NSWindowDelegate, MTKViewDelegate, BMCaptureDelegate>
@property(nonatomic, strong) BMOptions *options;
- (void)wake;
- (void)key:(NSEvent *)event;
- (void)scroll:(NSEvent *)event;
- (void)magnify:(NSEvent *)event;
- (void)mouseDown:(NSEvent *)event;
- (void)mouseDragged:(NSEvent *)event;
- (void)mouseUp:(NSEvent *)event;
@end

@implementation BMView {
    NSTrackingArea *_tracking;
}
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
        owner:self userInfo:nil];
    [self addTrackingArea:_tracking];
}
- (void)keyDown:(NSEvent *)event { [self.controller key:event]; }
- (void)scrollWheel:(NSEvent *)event { [self.controller scroll:event]; }
- (void)magnifyWithEvent:(NSEvent *)event { [self.controller magnify:event]; }
- (void)mouseDown:(NSEvent *)event { [self.controller mouseDown:event]; }
- (void)mouseDragged:(NSEvent *)event { [self.controller mouseDragged:event]; }
- (void)mouseUp:(NSEvent *)event { [self.controller mouseUp:event]; }
- (void)mouseMoved:(NSEvent *)event { (void)event; [self.controller wake]; }
- (void)rightMouseDown:(NSEvent *)event { (void)event; }
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:NSCursor.crosshairCursor]; }
@end

@implementation BMController {
    BMWindow *_window;
    BMView *_view;
    BMRenderer *_renderer;
    BMCapture *_capture;
    NSScreen *_screen;
    NSRunningApplication *_previousApp;
    NSTextField *_hud;
    BMConfig _config;
    BMCamera _camera;
    BOOL _mirror, _flashlight, _help, _shown, _quitting, _frameDrawn;
    double _radius, _dim, _lastFrame, _lastDrag;
    BMPoint _dragPoint;
    NSUInteger _hudGeneration;
    int _exitCode;
}
- (void)quit:(id)sender { (void)sender; [NSApp terminate:nil]; }
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    _previousApp = NSWorkspace.sharedWorkspace.frontmostApplication;
    NSMenu *main = [NSMenu new];
    NSMenuItem *appMenu = [NSMenuItem new]; [main addItem:appMenu];
    appMenu.submenu = [NSMenu new];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit Boomer" action:@selector(quit:) keyEquivalent:@"q"];
    quit.target = self; [appMenu.submenu addItem:quit]; NSApp.mainMenu = main;
    _config = bm_config_default();
    if (![self loadConfig:YES]) return;
    bm_camera_reset(&_camera, &_config); _radius = _config.flashlight_radius;
    NSError *error = nil;
    _renderer = [[BMRenderer alloc] initWithError:&error];
    if (!_renderer || (self.options.shaderPath && ![_renderer reloadShader:self.options.shaderPath error:&error])) {
        [self fatal:error.localizedDescription]; return;
    }
    NSArray<NSScreen *> *screens = NSScreen.screens;
    if (!screens.count || self.options.displayIndex >= (NSInteger)screens.count) {
        [self fatal:@"Display index does not exist. Use --list-displays."]; return;
    }
    _screen = screens.firstObject;
    if (self.options.displayIndex >= 0) _screen = screens[self.options.displayIndex];
    else for (NSScreen *s in screens) if (NSPointInRect(NSEvent.mouseLocation, s.frame)) { _screen = s; break; }
    BOOL windowed = self.options.windowed;
    NSRect rect = _screen.frame;
    if (windowed) {
        NSRect visible = _screen.visibleFrame;
        rect.size = NSMakeSize(MIN(1100, visible.size.width * 0.85), MIN(720, visible.size.height * 0.85));
        rect.origin = NSMakePoint(NSMidX(visible) - rect.size.width / 2, NSMidY(visible) - rect.size.height / 2);
    }
    NSWindowStyleMask style = windowed ? NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable : NSWindowStyleMaskBorderless;
    // NSScreen frames are global, but this initializer adds the supplied
    // screen's origin. Convert once so secondary displays aren't offset twice.
    NSRect localRect = NSOffsetRect(rect, -_screen.frame.origin.x, -_screen.frame.origin.y);
    _window = [[BMWindow alloc] initWithContentRect:localRect styleMask:style backing:NSBackingStoreBuffered defer:NO screen:_screen];
    _window.title = @"Boomer — Metal"; _window.delegate = self;
    _window.releasedWhenClosed = NO;
    _window.animationBehavior = NSWindowAnimationBehaviorNone;
    _window.backgroundColor = NSColor.blackColor;
    _window.acceptsMouseMovedEvents = YES;
    _window.minSize = NSMakeSize(480,320);
    _window.hasShadow = windowed;
    if (!windowed) {
        _window.level = NSMainMenuWindowLevel + 1;
        _window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    }
    _view = [[BMView alloc] initWithFrame:NSMakeRect(0,0,rect.size.width,rect.size.height) device:_renderer.device];
    _view.controller = self; _view.delegate = self;
    _view.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    _view.clearColor = MTLClearColorMake(0.035,0.04,0.05,1);
    _view.preferredFramesPerSecond = 120;
    _view.enableSetNeedsDisplay = NO; _view.paused = YES;
    _view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    // Match the sRGB capture and image conversion to the display compositor.
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    ((CAMetalLayer *)_view.layer).colorspace = space;
    CGColorSpaceRelease(space);
    _window.contentView = _view;
    _hud = [NSTextField wrappingLabelWithString:@""];
    _hud.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightMedium];
    _hud.textColor = NSColor.whiteColor;
    _hud.backgroundColor = [NSColor colorWithWhite:0.04 alpha:0.92];
    _hud.drawsBackground = YES;
    _hud.selectable = NO;
    _hud.hidden = YES;
    _hud.accessibilityLabel = @"Boomer status and keyboard shortcuts";
    [_view addSubview:_hud];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(screensChanged:)
        name:NSApplicationDidChangeScreenParametersNotification object:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.options.delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self->_quitting) [self begin];
    });
}
- (void)begin {
    if (self.options.demo || self.options.imagePath) {
        CGImageRef image = NULL;
        if (self.options.demo) image = CreateDemoImage();
        else {
            NSURL *url = [NSURL fileURLWithPath:self.options.imagePath];
            CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
            // Thumbnail API applies EXIF orientation and bounds very large inputs.
            if (source) {
                image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)@{
                    (id)kCGImageSourceCreateThumbnailFromImageAlways:@YES,
                    (id)kCGImageSourceCreateThumbnailWithTransform:@YES,
                    (id)kCGImageSourceThumbnailMaxPixelSize:@16384});
                CFRelease(source);
            }
        }
        if (!image) { [self fatal:@"Could not load the image."]; return; }
        [self captureImage:image]; CGImageRelease(image);
    } else {
        _capture = [BMCapture new]; _capture.delegate = self;
        _capture.displayID = [_screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        // ScreenCaptureKit performs its own authorization. A preflight result
        // alone must not prevent us from trying the API we actually use.
        [_capture takeScreenshot];
    }
}
- (BOOL)loadConfig:(BOOL)initial {
    char error[1400];
    BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:self.options.configPath];
    if (!exists && !self.options.explicitConfig) {
        _config = bm_config_default();
        if (!initial) [self toast:@"No config file; using defaults"];
        return YES;
    }
    if (!bm_config_load(self.options.configPath.fileSystemRepresentation, &_config, error, sizeof error)) {
        if (initial) [self fatal:@(error)]; else [self toast:@(error)];
        return NO;
    }
    if (!initial) [self toast:@"Configuration reloaded"];
    return YES;
}
- (void)fatal:(NSString *)message {
    fprintf(stderr, "Boomer: %s\n", message.UTF8String);
    _exitCode = 1;
    // Automation should fail promptly rather than block on an alert.
    if (!self.options.quitAfter) {
        [NSApp activateIgnoringOtherApps:YES];
        NSAlert *alert = [NSAlert new]; alert.messageText = @"Boomer could not start";
        alert.informativeText = message; [alert addButtonWithTitle:@"Quit"]; [alert runModal];
    }
    [self applicationWillTerminate:[NSNotification notificationWithName:NSApplicationWillTerminateNotification object:NSApp]];
    exit(EXIT_FAILURE);
}
- (void)captureImage:(CGImageRef)image {
    NSError *error = nil;
    if (![_renderer setImage:image error:&error]) { [self captureFailed:error]; return; }
    if (!_shown) {
        fprintf(stderr, "Capture ready: %zu x %zu pixels; app=%s\n",
            CGImageGetWidth(image), CGImageGetHeight(image), NSBundle.mainBundle.bundlePath.fileSystemRepresentation);
        [self showInitialFrameBefore:CACurrentMediaTime() + 5];
        return;
    }
    [self toast:@"Screenshot refreshed"];
    [self wake];
}
- (void)showInitialFrameBefore:(CFTimeInterval)deadline {
    if (_quitting || _shown) return;
    // Commit real Metal content before exposing the opaque window. Merely
    // uploading the screenshot, or starting the display timer, leaves a black
    // window visible until the GPU and compositor catch up.
    [_view layoutSubtreeIfNeeded];
    _view.drawableSize = [_view convertRectToBacking:_view.bounds].size;
    _view.presentsWithTransaction = YES;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _frameDrawn = NO;
    _lastFrame = CACurrentMediaTime();
    [_view draw];
    [CATransaction commit];
    [CATransaction flush];
    _view.presentsWithTransaction = NO;
    if (!_frameDrawn) {
        if (CACurrentMediaTime() >= deadline) {
            [self fatal:@"Could not render the first frame."]; return;
        }
        // A drawable can be temporarily unavailable. Keep the window hidden
        // and retry on the main run loop instead of exposing an empty frame.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 60), dispatch_get_main_queue(), ^{
            [self showInitialFrameBefore:deadline];
        });
        return;
    }
    _shown = YES;
    [_window makeKeyAndOrderFront:nil]; [_window makeFirstResponder:_view];
    [NSApp activateIgnoringOtherApps:YES];
    [self toast:@"Scroll / pinch to zoom · Drag to pan · H for help · Esc to quit"];
    if (self.options.live) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (!self->_quitting) [self->_capture startLive];
        });
    }
    if (self.options.quitAfter > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.options.quitAfter * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
    }
    [self wake];
}
- (void)captureFrame:(CVPixelBufferRef)buffer {
    if ([_renderer setPixelBuffer:buffer]) [self wake];
}
- (void)captureFailed:(NSError *)error {
    NSString *details = [NSString stringWithFormat:@"%@ (%@, %ld)",
        error.localizedDescription, error.domain, (long)error.code];
    if (!_shown && [error.domain isEqualToString:SCStreamErrorDomain] && error.code == SCStreamErrorUserDeclined) {
        [self fatal:[NSString stringWithFormat:
            @"macOS denied screen capture for this copy of Boomer.\n\n"
             "If Boomer is already enabled in Screen & System Audio Recording, its saved permission may belong to an older build. Remove that Boomer entry, add the app below again, then relaunch.\n\n"
             "App: %@\n\n%@", NSBundle.mainBundle.bundlePath, details]];
    }
    else if (!_shown) [self fatal:details];
    else { fprintf(stderr, "Capture: %s\n", error.localizedDescription.UTF8String); [self toast:error.localizedDescription]; }
}
- (BMPoint)pointer {
    NSPoint p = [_view convertPoint:[_window convertPointFromScreen:NSEvent.mouseLocation] fromView:nil];
    return (BMPoint){p.x,p.y};
}
- (BMPoint)pointForEvent:(NSEvent *)event {
    NSPoint p = [_view convertPoint:event.locationInWindow fromView:nil]; return (BMPoint){p.x,p.y};
}
- (void)wake {
    if (!_shown || _quitting || !_window.visible || _window.miniaturized) return;
    if (_view.paused) _lastFrame = CACurrentMediaTime() - 1.0 / 120;
    _view.paused = NO;
}
- (void)drawInMTKView:(MTKView *)view {
    _frameDrawn = NO;
    double now = CACurrentMediaTime(), dt = fmin(0.1, fmax(0, now - _lastFrame)); _lastFrame = now;
    BOOL moving = bm_camera_step(&_camera, &_config, dt);
    double desiredDim = _flashlight ? _config.flashlight_dim : 0;
    _dim += (desiredDim - _dim) * -expm1(-16 * dt);
    if (fabs(_dim - desiredDim) < 0.001) _dim = desiredDim;
    CGSize size = view.bounds.size, image = _renderer.imageSize;
    if (!size.width || !size.height || !image.width || !image.height) { view.paused = YES; return; }
    double fit = fmin(size.width / image.width, size.height / image.height);
    BMPoint pointer = [self pointer];
    BMUniforms u = {.viewport = {(float)size.width,(float)size.height},
        .offset = {(float)_camera.offset.x,(float)_camera.offset.y},
        .imageSize = {(float)(image.width * fit),(float)(image.height * fit)},
        .cursor = {(float)pointer.x,(float)pointer.y}, .scale = (float)_camera.scale,
        .radius = (float)(_radius * _camera.scale), .dim = (float)_dim,
        .mirror = _mirror, .filterMode = _config.filter_mode};
    _frameDrawn = [_renderer drawInView:view uniforms:u];
    // Failed submissions still need a frame even when the camera is idle.
    // Hidden startup frames are retried explicitly by showInitialFrameBefore:.
    view.paused = !_shown || (_frameDrawn && !moving && _dim == desiredDim);
}
- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    (void)view; (void)size;
    [self layoutHUD]; [self wake];
}
- (void)layoutHUD {
    CGFloat width = MAX(100, MIN(660, _view.bounds.size.width - 32));
    _hud.frame = NSMakeRect(16,16,width,_help ? 162 : 56);
}
- (void)showHelp {
    _hud.stringValue = @"  BOOMER / METAL\n  Scroll · +/- · Pinch    Zoom at cursor\n  Left drag              Pan with inertia\n  F · Ctrl-scroll        Flashlight · Radius\n  M · P · 0              Mirror · Filter · Reset\n  L · Space              Live/freeze · New screenshot\n  R · Ctrl-R             Reload config · Shader\n  H / ? · Q / Esc        Help · Quit";
    _hud.hidden = NO; [self layoutHUD];
}
- (void)toast:(NSString *)message {
    if (_help) return;
    NSUInteger generation = ++_hudGeneration;
    _hud.stringValue = [@"  " stringByAppendingString:message]; _hud.hidden = NO; [self layoutHUD];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (generation == self->_hudGeneration && !self->_help) self->_hud.hidden = YES;
    });
}
- (void)key:(NSEvent *)event {
    NSString *s = event.charactersIgnoringModifiers.lowercaseString;
    if (event.keyCode == 53 || [s isEqual:@"q"]) { [NSApp terminate:nil]; return; }
    if ([s isEqual:@"0"]) {
        bm_camera_reset(&_camera, &_config); _mirror = NO; _flashlight = NO;
        _radius = _config.flashlight_radius; [self toast:@"Reset · 1×"];
    } else if ([s isEqual:@"m"]) { _mirror = !_mirror; [self toast:_mirror ? @"Mirror on" : @"Mirror off"]; }
    else if ([s isEqual:@"f"]) { _flashlight = !_flashlight; [self toast:_flashlight ? @"Flashlight on · Ctrl-scroll adjusts radius" : @"Flashlight off"]; }
    else if ([s isEqual:@"p"]) {
        _config.filter_mode = (BMFilterMode)((_config.filter_mode + 1) % 3);
        NSArray<NSString *> *names = @[@"Nearest-pixel filtering", @"Linear filtering", @"Bicubic filtering · Smooth text"];
        [self toast:names[_config.filter_mode]];
    }
    else if ([s isEqual:@"h"] || [s isEqual:@"?"] || [event.characters isEqual:@"?"]) {
        _help = !_help; ++_hudGeneration;
        if (_help) [self showHelp]; else _hud.hidden = YES;
    } else if ([s isEqual:@"="] || [s isEqual:@"+"] || [s isEqual:@"-"]) {
        bm_camera_zoom(&_camera, &_config, [self pointer], ([s isEqual:@"-"] ? -1 : 1) * 0.12 * _config.scroll_speed);
    } else if ([s isEqual:@"r"]) {
        if (event.modifierFlags & NSEventModifierFlagControl) {
            NSError *error = nil;
            if (!self.options.shaderPath) [self toast:@"Start with --shader src/Shaders.metal to enable shader reload"];
            else if (![_renderer reloadShader:self.options.shaderPath error:&error]) [self toast:error.localizedDescription];
            else [self toast:@"Metal shader reloaded"];
        } else if ([self loadConfig:NO]) _radius = _config.flashlight_radius;
    } else if ([s isEqual:@"l"] && _capture) {
        if (_capture.live) { [_capture stop]; [self toast:@"Frozen"]; }
        else { [_capture startLive]; [self toast:@"Live capture"]; }
    } else if ([s isEqual:@" "] && _capture) {
        [_capture stop]; [_capture takeScreenshot];
    }
    [self wake];
}
- (void)scroll:(NSEvent *)event {
    double amount = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.003 : 0.12);
    if (event.modifierFlags & NSEventModifierFlagControl) _radius = fmin(10000, fmax(1, _radius * exp(amount)));
    else bm_camera_zoom(&_camera, &_config, [self pointForEvent:event], amount * _config.scroll_speed);
    [self wake];
}
- (void)magnify:(NSEvent *)event {
    bm_camera_zoom(&_camera, &_config, [self pointForEvent:event], log(fmax(0.01, 1 + event.magnification)));
    [self wake];
}
- (void)mouseDown:(NSEvent *)event {
    _camera.dragging = YES; _camera.velocity = (BMPoint){0}; _camera.target_scale = _camera.scale;
    _dragPoint = [self pointForEvent:event]; _lastDrag = event.timestamp;
    [NSCursor.closedHandCursor set]; [self wake];
}
- (void)mouseDragged:(NSEvent *)event {
    BMPoint p = [self pointForEvent:event];
    bm_camera_drag(&_camera, (BMPoint){p.x - _dragPoint.x,p.y - _dragPoint.y}, event.timestamp - _lastDrag);
    _dragPoint = p; _lastDrag = event.timestamp; [self wake];
}
- (void)mouseUp:(NSEvent *)event {
    _camera.dragging = NO;
    if (event.timestamp - _lastDrag > 0.08) _camera.velocity = (BMPoint){0};
    [NSCursor.crosshairCursor set]; [self wake];
}
- (void)windowDidResignKey:(NSNotification *)notification {
    (void)notification; _camera.dragging = NO; _camera.velocity = (BMPoint){0};
    // Let other applications cover the overlay when Cmd-Tabbing away.
    if (!self.options.windowed) _window.level = NSNormalWindowLevel;
}
- (void)windowDidBecomeKey:(NSNotification *)notification {
    (void)notification;
    if (!self.options.windowed) _window.level = NSMainMenuWindowLevel + 1;
    [self wake];
}
- (void)windowDidDeminiaturize:(NSNotification *)notification { (void)notification; [self wake]; }
- (void)windowDidChangeBackingProperties:(NSNotification *)notification { (void)notification; [self wake]; }
- (BOOL)windowShouldClose:(NSWindow *)sender { (void)sender; [NSApp terminate:nil]; return NO; }
- (void)screensChanged:(NSNotification *)notification {
    (void)notification;
    CGDirectDisplayID displayID = [_screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
    NSScreen *found = nil;
    for (NSScreen *s in NSScreen.screens) if ([s.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == displayID) found = s;
    if (!found) { [NSApp terminate:nil]; return; }
    _screen = found;
    if (!self.options.windowed) [_window setFrame:found.frame display:YES];
    if (_capture.live) { [_capture stop]; [_capture startLive]; }
    [self wake];
}
- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification; _quitting = YES; _view.paused = YES;
    [_capture stop]; [_window orderOut:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_previousApp && !_previousApp.terminated && _previousApp.processIdentifier != NSProcessInfo.processInfo.processIdentifier && NSApp.active)
        [_previousApp activateWithOptions:0];
}
- (int)exitCode { return _exitCode; }
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        int result;
        BMOptions *options = ParseOptions(argc, argv, &result);
        if (!options) return result;
        if (options.generatedConfigPath) {
            NSString *path = options.generatedConfigPath.stringByExpandingTildeInPath;
            NSError *error = nil;
            if (![NSFileManager.defaultManager createDirectoryAtPath:(path.stringByDeletingLastPathComponent.length ? path.stringByDeletingLastPathComponent : @".")
                withIntermediateDirectories:YES attributes:nil error:&error]) {
                fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1;
            }
            NSData *data = [@(DefaultConfig) dataUsingEncoding:NSUTF8StringEncoding];
            if (![data writeToFile:path options:NSDataWritingWithoutOverwriting error:&error]) {
                fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1;
            }
            printf("Created %s\n", path.fileSystemRepresentation); return 0;
        }
        if (options.selfTest) {
            NSError *error = nil;
            BMRenderer *renderer = [[BMRenderer alloc] initWithError:&error];
            if (!renderer || ![renderer selfTest:&error]) {
                fprintf(stderr, "Metal self-test failed: %s\n", error.localizedDescription.UTF8String); return 1;
            }
            printf("Metal self-test passed: %s (orientation, color, mirror, dimming, zoom, filtering, alpha)\n", renderer.device.name.UTF8String);
            return 0;
        }
        [NSApplication sharedApplication];
        if (options.listDisplays) {
            NSInteger i = 0;
            for (NSScreen *s in NSScreen.screens) printf("%ld: %s — %.0f × %.0f points, %.1f× Retina, ID %u\n",
                (long)i++, s.localizedName.UTF8String, s.frame.size.width,s.frame.size.height,s.backingScaleFactor,
                [s.deviceDescription[@"NSScreenNumber"] unsignedIntValue]);
            return 0;
        }
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        BMController *controller = [BMController new]; controller.options = options;
        NSApp.delegate = controller;
        [NSApp run];
        return controller.exitCode;
    }
}
