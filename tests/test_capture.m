// Controlled API completions exercise lifetime/cancellation without recording
// the desktop or requiring Screen Recording permission.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "../src/Capture.m"

typedef void (^BMSampleCompletion)(CMSampleBufferRef, NSError *);
typedef void (^BMContentCompletion)(SCShareableContent *, NSError *);
static NSMutableArray<BMSampleCompletion> *samples;
static NSMutableArray<BMContentCompletion> *contents;

@interface BMCaptureAPIMock : NSObject
@end
@implementation BMCaptureAPIMock
+ (void)captureSampleBufferWithFilter:(SCContentFilter *)filter configuration:(SCStreamConfiguration *)config
    completionHandler:(BMSampleCompletion)completion {
    (void)filter; (void)config; [samples addObject:[completion copy]];
}
+ (void)getShareableContentExcludingDesktopWindows:(BOOL)desktop onScreenWindowsOnly:(BOOL)onScreen
    completionHandler:(BMContentCompletion)completion {
    (void)desktop; (void)onScreen; [contents addObject:[completion copy]];
}
@end

@interface BMCaptureRecorder : NSObject <BMCaptureDelegate>
@property NSUInteger frames, failures;
@property BOOL correctThread, validPixels;
@end
@implementation BMCaptureRecorder
- (void)captureFrame:(CVPixelBufferRef)buffer {
    ++_frames; _correctThread = NSThread.isMainThread;
    CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    _validPixels = CVPixelBufferGetWidth(buffer) == 8 && ((uint8_t *)CVPixelBufferGetBaseAddress(buffer))[0] == 123;
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
}
- (void)captureFailed:(NSError *)error { (void)error; ++_failures; _correctThread = NSThread.isMainThread; }
@end

static void Drain(void) {
    __block BOOL done = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ done = YES; });
    while (!done) [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}
static void SeedCache(BMCapture *capture) {
    // The mocked API treats filter/config as opaque, as the cache should.
    [capture setValue:[NSObject new] forKey:@"filter"];
    [capture setValue:[SCStreamConfiguration new] forKey:@"configuration"];
}
static BOOL CompleteSample(NSUInteger index) {
    CVPixelBufferRef buffer = NULL;
    CMVideoFormatDescriptionRef format = NULL;
    CMSampleBufferRef sample = NULL;
    if (CVPixelBufferCreate(NULL, 8, 8, kCVPixelFormatType_32BGRA, NULL, &buffer) != kCVReturnSuccess) return NO;
    CVPixelBufferLockBaseAddress(buffer, 0);
    memset(CVPixelBufferGetBaseAddress(buffer), 123, CVPixelBufferGetBytesPerRow(buffer) * 8);
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(NULL, buffer, &format);
    CMSampleTimingInfo timing = {kCMTimeInvalid, kCMTimeZero, kCMTimeInvalid};
    if (status == noErr) status = CMSampleBufferCreateReadyWithImageBuffer(NULL, buffer, format, &timing, &sample);
    if (status == noErr) dispatch_sync(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        samples[index](sample, nil);
    });
    if (sample) CFRelease(sample);
    if (format) CFRelease(format);
    CVPixelBufferRelease(buffer);
    Drain();
    return status == noErr;
}
static void Swap(Class cls, SEL selector) {
    method_exchangeImplementations(class_getClassMethod(cls, selector), class_getClassMethod(BMCaptureAPIMock.class, selector));
}

int main(void) {
    @autoreleasepool {
        samples = [NSMutableArray array]; contents = [NSMutableArray array];
        Swap(SCScreenshotManager.class, @selector(captureSampleBufferWithFilter:configuration:completionHandler:));
        Swap(SCShareableContent.class, @selector(getShareableContentExcludingDesktopWindows:onScreenWindowsOnly:completionHandler:));
        BMCapture *capture = [BMCapture new]; capture.displayID = 1;
        BMCaptureRecorder *recorder = [BMCaptureRecorder new]; capture.delegate = recorder;
        SeedCache(capture);
        [capture takeScreenshot]; [capture takeScreenshot];
        BOOL coalesced = samples.count == 1 && contents.count == 0;
        BOOL lifetime = CompleteSample(0) && recorder.frames == 1 && recorder.correctThread && recorder.validPixels;
        [capture stop]; [capture takeScreenshot]; [capture stop];
        BOOL canceled = CompleteSample(1) && recorder.frames == 1 && recorder.failures == 0;
        [capture takeScreenshot];
        BOOL reused = samples.count == 3 && contents.count == 0;
        NSError *error = [NSError errorWithDomain:@"test" code:1 userInfo:nil];
        // A stale cached filter falls back to enumeration exactly once.
        samples[2](NULL, error); Drain();
        BOOL retried = contents.count == 1 && recorder.failures == 0;
        contents[0](nil, error); Drain();
        BOOL failed = recorder.failures == 1 && recorder.correctThread && [capture valueForKey:@"filter"] == nil;
        SeedCache(capture); [capture warmUp];
        BOOL warmCache = contents.count == 1 && samples.count == 3;
        [capture takeScreenshot]; capture.displayID = 2;
        BOOL changed = [capture valueForKey:@"filter"] == nil && CompleteSample(3) && recorder.frames == 1;
        // Cancel during the enumeration stage, including an old warmup error.
        [capture warmUp]; [capture stop];
        contents[1](nil, error); Drain();
        [capture takeScreenshot]; [capture invalidate];
        contents[2](nil, error); Drain();
        BOOL staleErrors = recorder.failures == 1;
        BOOL passed = coalesced && lifetime && canceled && reused && retried && failed && warmCache && changed && staleErrors;
        fprintf(stderr, "%s capture: cache reuse, retained buffer, coalescing, cancellation, one retry, display invalidation\n", passed ? "PASS" : "FAIL");
        return passed ? 0 : 1;
    }
}
