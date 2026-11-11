#import <ScreenCaptureKit/ScreenCaptureKit.h>

@protocol BMCaptureDelegate <NSObject>
- (void)captureImage:(CGImageRef)image;
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
- (void)stop;
@end
