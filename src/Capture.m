#import "Capture.h"
#include "Timing.h"
#include <stdatomic.h>
#include <unistd.h>

typedef NS_ENUM(NSUInteger, BMPreparation) { BMStill, BMLive, BMWarmup };

@implementation BMCapture {
    SCStream *_stream;
    SCContentFilter *_filter;
    SCStreamConfiguration *_configuration;
    // Only cancellation crosses threads. Cached resources and live/UI state
    // are accessed on main; asynchronous requests capture immutable references.
    _Atomic(NSUInteger) _generation;
    BOOL _busy, _warming;
}
@synthesize displayID = _displayID;
- (void)setDisplayID:(CGDirectDisplayID)displayID {
    if (_displayID == displayID) return;
    [self invalidate]; _displayID = displayID;
}
- (void)prepare:(BMPreparation)mode generation:(NSUInteger)generation {
    if (_filter) {
        bm_startup_mark("capture filter reused");
        if (mode == BMWarmup) { _warming = NO; return; }
        [self captureWithFilter:_filter configuration:_configuration mode:mode generation:generation cached:YES];
        return;
    }
    bm_startup_mark("shareable content requested");
    CGDirectDisplayID displayID = self.displayID;
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:NO
        completionHandler:^(SCShareableContent *content, NSError *error) {
        if (generation != self->_generation) return;
        bm_startup_mark("shareable content received");
        if (error) { [self fail:error generation:generation mode:mode]; return; }
        SCDisplay *display = nil;
        for (SCDisplay *d in content.displays) if (d.displayID == displayID) { display = d; break; }
        if (!display) {
            [self fail:[NSError errorWithDomain:@"Boomer.Capture" code:1 userInfo:@{
                NSLocalizedDescriptionKey:@"The selected display is no longer connected."}]
                generation:generation mode:mode]; return;
        }
        NSMutableArray<SCRunningApplication *> *excluded = [NSMutableArray array];
        for (SCRunningApplication *app in content.applications)
            if (app.processID == getpid()) [excluded addObject:app];
        if (mode == BMLive && excluded.count == 0) {
            [self fail:[NSError errorWithDomain:@"Boomer.Capture" code:1 userInfo:@{
                NSLocalizedDescriptionKey:@"ScreenCaptureKit could not exclude Boomer from live capture. Try L again."}]
                generation:generation mode:mode]; return;
        }
        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingApplications:excluded exceptingWindows:@[]];
        SCStreamConfiguration *config = [SCStreamConfiguration new];
        config.width = (size_t)llround(filter.contentRect.size.width * filter.pointPixelScale);
        config.height = (size_t)llround(filter.contentRect.size.height * filter.pointPixelScale);
        config.pixelFormat = kCVPixelFormatType_32BGRA;
        config.colorSpaceName = kCGColorSpaceSRGB;
        config.showsCursor = NO;
        config.scalesToFit = YES;
        config.queueDepth = 3;
        config.minimumFrameInterval = CMTimeMake(1, 60);
        config.capturesAudio = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_generation) return;
            // A filter made before our first window exists may not exclude
            // Boomer. Never reuse that filter once the overlay is visible.
            if (excluded.count) { self->_filter = filter; self->_configuration = config; }
            if (mode == BMWarmup) self->_warming = NO;
        });
        if (mode != BMWarmup)
            [self captureWithFilter:filter configuration:config mode:mode generation:generation cached:NO];
    }];
}
- (void)captureWithFilter:(SCContentFilter *)filter configuration:(SCStreamConfiguration *)config
    mode:(BMPreparation)mode generation:(NSUInteger)generation cached:(BOOL)cached {
    if (generation != _generation) return;
    if (mode == BMLive) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_generation) return;
            SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];
            NSError *error = nil;
            if (![stream addStreamOutput:self type:SCStreamOutputTypeScreen
                    sampleHandlerQueue:dispatch_get_main_queue() error:&error]) {
                [self fail:error]; return;
            }
            self->_stream = stream;
            [stream startCaptureWithCompletionHandler:^(NSError *startError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation != self->_generation) return;
                    self->_busy = NO;
                    if (startError) [self fail:startError];
                });
            }];
        });
        return;
    }
    bm_startup_mark("screenshot requested");
    [SCScreenshotManager captureSampleBufferWithFilter:filter configuration:config
        completionHandler:^(CMSampleBufferRef sample, NSError *error) {
        CVPixelBufferRef buffer = sample && CMSampleBufferIsValid(sample) ? CMSampleBufferGetImageBuffer(sample) : NULL;
        CVPixelBufferRef held = buffer ? CVPixelBufferRetain(buffer) : NULL;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation == self->_generation) {
                if ((error || !held) && cached) {
                    // A display can change between notifications. Retry once
                    // with a fresh filter, preserving cancellation semantics.
                    self->_filter = nil; self->_configuration = nil;
                    [self prepare:BMStill generation:generation];
                } else {
                    self->_busy = NO;
                    if (error || !held) [self fail:error];
                    else [self.delegate captureFrame:held];
                }
            }
            if (held) CVPixelBufferRelease(held);
        });
    }];
}
- (void)fail:(NSError *)error generation:(NSUInteger)generation mode:(BMPreparation)mode {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != self->_generation) return;
        if (mode == BMWarmup) { self->_warming = NO; return; }
        [self fail:error];
    });
}
- (void)fail:(NSError *)error {
    [self invalidate];
    [self.delegate captureFailed:error ? error : [NSError errorWithDomain:@"Boomer.Capture" code:2
        userInfo:@{NSLocalizedDescriptionKey:@"Screen capture returned no image."}]];
}
- (void)takeScreenshot {
    if (_busy || _live) return;
    _busy = YES; _warming = NO;
    [self prepare:BMStill generation:++_generation];
}
- (void)startLive {
    if (_live) return;
    [self stop];
    _live = YES; _busy = YES;
    [self prepare:BMLive generation:++_generation];
}
- (void)warmUp {
    if (_filter || _busy || _warming || _live) return;
    _warming = YES;
    [self prepare:BMWarmup generation:_generation];
}
- (void)invalidate {
    [self stop]; _filter = nil; _configuration = nil;
}
- (void)stop {
    ++_generation; _busy = NO; _live = NO; _warming = NO;
    SCStream *old = _stream; _stream = nil;
    if (old) [old stopCaptureWithCompletionHandler:^(NSError *error) { (void)old; (void)error; }];
}
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sample ofType:(SCStreamOutputType)type {
    if (stream != _stream || !_live || type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sample)) return;
    NSArray *attachments = (__bridge NSArray *)CMSampleBufferGetSampleAttachmentsArray(sample, false);
    NSNumber *status = attachments.firstObject[SCStreamFrameInfoStatus];
    if (!status || status.integerValue != SCFrameStatusComplete) return;
    CVPixelBufferRef buffer = CMSampleBufferGetImageBuffer(sample);
    if (buffer) [self.delegate captureFrame:buffer];
}
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{ if (stream == self->_stream) [self fail:error]; });
}
@end
