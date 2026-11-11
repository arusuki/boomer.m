#import <ScreenCaptureKit/ScreenCaptureKit.h>

@protocol BMCaptureDelegate <NSObject>
// Both still screenshots and live frames use an IOSurface-backed buffer.
- (void)captureFrame:(CVPixelBufferRef)buffer;
- (void)captureFailed:(NSError *)error;
@end

// All public methods and delegate callbacks run on the main thread.
@interface BMCapture : NSObject <SCStreamOutput, SCStreamDelegate>
@property(nonatomic, weak) id<BMCaptureDelegate> delegate;
@property(nonatomic) CGDirectDisplayID displayID;
@property(nonatomic, readonly) BOOL live;
- (void)takeScreenshot;
- (void)startLive;
// Prepare reusable self-excluding filters while visible; does not capture.
- (void)warmUp;
// Stop in-flight work and discard cached display/filter information.
- (void)invalidate;
- (void)stop;
@end
