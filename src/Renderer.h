#import <MetalKit/MetalKit.h>
#import <CoreVideo/CoreVideo.h>
#import <simd/simd.h>

typedef struct {
    vector_float2 viewport, offset, imageSize, cursor;
    float scale, radius, dim, mirror;
    float filterMode, padding0, padding1, padding2;
} BMUniforms;
_Static_assert(sizeof(BMUniforms) == 64, "Metal uniform layout mismatch");

@interface BMRenderer : NSObject
@property(nonatomic, readonly) id<MTLDevice> device;
@property(nonatomic, readonly) CGSize imageSize;
- (instancetype)initWithError:(NSError **)error;
- (BOOL)setImage:(CGImageRef)image error:(NSError **)error;
- (BOOL)setPixelBuffer:(CVPixelBufferRef)buffer;
- (BOOL)reloadShader:(NSString *)path error:(NSError **)error;
- (void)drawInView:(MTKView *)view uniforms:(BMUniforms)uniforms;
- (BOOL)selfTest:(NSError **)error;
@end
