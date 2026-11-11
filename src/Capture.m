#import "Capture.h"
#include <unistd.h>

@implementation BMCapture {
    SCStream *_stream;
    NSUInteger _generation;
    BOOL _busy;
}
- (void)prepare:(BOOL)live generation:(NSUInteger)generation {
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:NO
        completionHandler:^(SCShareableContent *content, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_generation) return;
            if (error) { [self fail:error]; return; }
            SCDisplay *display = nil;
            for (SCDisplay *d in content.displays) if (d.displayID == self.displayID) { display = d; break; }
            if (!display) { [self failMessage:@"The selected display is no longer connected."]; return; }
            NSMutableArray<SCRunningApplication *> *excluded = [NSMutableArray array];
            for (SCRunningApplication *app in content.applications) {
                if (app.processID == getpid()) [excluded addObject:app];
            }
            if (live && excluded.count == 0) {
                [self failMessage:@"ScreenCaptureKit could not exclude Boomer from live capture. Try L again."]; return;
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
            if (live) {
                SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];
                NSError *outputError = nil;
                if (![stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:dispatch_get_main_queue() error:&outputError]) {
                    [self fail:outputError]; return;
                }
                self->_stream = stream;
                [stream startCaptureWithCompletionHandler:^(NSError *startError) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (generation != self->_generation) return;
                        self->_busy = NO;
                        if (startError) [self fail:startError];
                    });
                }];
            } else {
                [SCScreenshotManager captureImageWithFilter:filter configuration:config completionHandler:^(CGImageRef image, NSError *captureError) {
                    CGImageRef held = image ? CGImageRetain(image) : NULL;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (generation == self->_generation) {
                            self->_busy = NO;
                            if (captureError || !held) [self fail:captureError];
                            else [self.delegate captureImage:held];
                        }
                        if (held) CGImageRelease(held);
                    });
                }];
            }
        });
    }];
}
- (void)failMessage:(NSString *)message {
    [self fail:[NSError errorWithDomain:@"Boomer.Capture" code:1 userInfo:@{NSLocalizedDescriptionKey:message}]];
}
- (void)fail:(NSError *)error {
    [self stop];
    [self.delegate captureFailed:error ? error : [NSError errorWithDomain:@"Boomer.Capture" code:2
        userInfo:@{NSLocalizedDescriptionKey:@"Screen capture returned no image."}]];
}
- (void)takeScreenshot {
    if (_busy || _live) return;
    _busy = YES;
    [self prepare:NO generation:++_generation];
}
- (void)startLive {
    if (_live) return;
    [self stop];
    _live = YES; _busy = YES;
    [self prepare:YES generation:++_generation];
}
- (void)stop {
    ++_generation; _busy = NO; _live = NO;
    SCStream *old = _stream; _stream = nil;
    // Retain until asynchronous stop finishes, including a pending start.
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
    dispatch_async(dispatch_get_main_queue(), ^{
        if (stream == self->_stream) [self fail:error];
    });
}
@end
