#import "Renderer.h"
#include "Timing.h"
#include "Shaders.inc"

static NSError *BMRenderError(NSString *message) {
    return [NSError errorWithDomain:@"Boomer.Metal"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

@implementation BMRenderer {
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLTexture> _texture;
    CVMetalTextureCacheRef _cache;
    CVPixelBufferRef _pixelBuffer;
    CVMetalTextureRef _videoTexture;
    dispatch_semaphore_t _inflight;
}

- (instancetype)initWithError:(NSError **)error {
    self = [super init];
    if (!self)
        return nil;
    _device = MTLCreateSystemDefaultDevice();
    bm_startup_mark("Metal device created");
    if (!_device) {
        if (error)
            *error = BMRenderError(@"No Metal device available.");
        return nil;
    }
    _queue = [_device newCommandQueue];
    _inflight = dispatch_semaphore_create(3);
    if (!_queue ||
        CVMetalTextureCacheCreate(NULL, NULL, _device, NULL, &_cache) != kCVReturnSuccess) {
        if (error)
            *error = BMRenderError(@"Could not create Metal resources.");
        return nil;
    }
    NSString *source = [[NSString alloc] initWithBytes:src_Shaders_metal
                                                length:src_Shaders_metal_len
                                              encoding:NSUTF8StringEncoding];
    if (![self compileSource:source error:error])
        return nil;
    return self;
}

- (void)dealloc {
    if (_videoTexture)
        CFRelease(_videoTexture);
    if (_pixelBuffer)
        CVPixelBufferRelease(_pixelBuffer);
    if (_cache)
        CFRelease(_cache);
}

- (BOOL)compileSource:(NSString *)source error:(NSError **)error {
    id<MTLLibrary> library = [_device newLibraryWithSource:source options:nil error:error];
    bm_startup_mark("Metal library compiled");
    if (!library)
        return NO;
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [library newFunctionWithName:@"fullscreenVertex"];
    d.fragmentFunction = [library newFunctionWithName:@"screenFragment"];
    d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    if (!d.vertexFunction || !d.fragmentFunction) {
        if (error)
            *error = BMRenderError(@"Shader must define fullscreenVertex and screenFragment.");
        return NO;
    }
    id<MTLRenderPipelineState> next = [_device newRenderPipelineStateWithDescriptor:d error:error];
    bm_startup_mark("Metal pipeline created");
    if (!next)
        return NO;
    _pipeline = next;
    return YES;
}

- (BOOL)reloadShader:(NSString *)path error:(NSError **)error {
    NSString *s = [NSString stringWithContentsOfFile:path
                                            encoding:NSUTF8StringEncoding
                                               error:error];
    return s && [self compileSource:s error:error];
}

- (CGSize)imageSize {
    return CGSizeMake((CGFloat)_texture.width, (CGFloat)_texture.height);
}

- (void)clearImage {
    _texture = nil;
    if (_videoTexture) {
        CFRelease(_videoTexture);
        _videoTexture = NULL;
    }
    if (_pixelBuffer) {
        CVPixelBufferRelease(_pixelBuffer);
        _pixelBuffer = NULL;
    }
    CVMetalTextureCacheFlush(_cache, 0);
}

- (BOOL)setImage:(CGImageRef)image error:(NSError **)error {
    size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
    if (!w || !h || w > 16384 || h > 16384) {
        if (error)
            *error = BMRenderError(@"Image dimensions must be between 1 and 16384 pixels.");
        return NO;
    }
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(
        NULL, w, h, 8, w * 4, space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    if (!context) {
        if (error)
            *error = BMRenderError(@"Could not allocate image pixels.");
        return NO;
    }
    CGContextDrawImage(context, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), image);
    MTLTextureDescriptor *desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:w
                                                          height:h
                                                       mipmapped:NO];
    desc.storageMode = MTLStorageModeShared;
    id<MTLTexture> next = [_device newTextureWithDescriptor:desc];
    if (next)
        [next replaceRegion:MTLRegionMake2D(0, 0, w, h)
                mipmapLevel:0
                  withBytes:CGBitmapContextGetData(context)
                bytesPerRow:w * 4];
    CGContextRelease(context);
    if (!next) {
        if (error)
            *error = BMRenderError(@"Could not allocate image texture.");
        return NO;
    }
    _texture = next;
    if (_videoTexture) {
        CFRelease(_videoTexture);
        _videoTexture = NULL;
    }
    if (_pixelBuffer) {
        CVPixelBufferRelease(_pixelBuffer);
        _pixelBuffer = NULL;
    }
    return YES;
}

- (BOOL)setPixelBuffer:(CVPixelBufferRef)buffer {
    CVMetalTextureRef next = NULL;
    CVReturn result = CVMetalTextureCacheCreateTextureFromImage(
        NULL, _cache, buffer, NULL, MTLPixelFormatBGRA8Unorm, CVPixelBufferGetWidth(buffer),
        CVPixelBufferGetHeight(buffer), 0, &next);
    if (result != kCVReturnSuccess || !next)
        return NO;
    if (_videoTexture)
        CFRelease(_videoTexture);
    if (_pixelBuffer)
        CVPixelBufferRelease(_pixelBuffer);
    _videoTexture = next;
    _pixelBuffer = CVPixelBufferRetain(buffer);
    _texture = CVMetalTextureGetTexture(next);
    return _texture != nil;
}

- (void)encode:(id<MTLCommandBuffer>)commands
          pass:(MTLRenderPassDescriptor *)pass
      uniforms:(BMUniforms)u {
    id<MTLRenderCommandEncoder> encoder = [commands renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:_pipeline];
    [encoder setFragmentTexture:_texture atIndex:0];
    [encoder setFragmentBytes:&u length:sizeof u atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
}

- (BOOL)drawInView:(MTKView *)view uniforms:(BMUniforms)uniforms {
    if (!_texture || dispatch_semaphore_wait(_inflight, DISPATCH_TIME_NOW))
        return NO;
    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!pass || !drawable) {
        dispatch_semaphore_signal(_inflight);
        return NO;
    }
    id<MTLCommandBuffer> commands = [_queue commandBuffer];
    if (!commands) {
        dispatch_semaphore_signal(_inflight);
        return NO;
    }
    // Keep the IOSurface and its CV wrapper alive until GPU sampling completes.
    CVPixelBufferRef buffer = _pixelBuffer ? CVPixelBufferRetain(_pixelBuffer) : NULL;
    CVMetalTextureRef video = _videoTexture ? (CVMetalTextureRef)CFRetain(_videoTexture) : NULL;
    dispatch_semaphore_t semaphore = _inflight;
    [commands addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        if (buffer)
            CVPixelBufferRelease(buffer);
        if (video)
            CFRelease(video);
        if (completed.error)
            fprintf(stderr, "Metal: %s\n", completed.error.localizedDescription.UTF8String);
        dispatch_semaphore_signal(semaphore);
    }];
    [self encode:commands pass:pass uniforms:uniforms];
    if (view.presentsWithTransaction) {
        // Prepare the first frame while the window is still hidden. Present
        // directly on this thread so it joins the caller's CA transaction.
        // GPU completion alone (or presentDrawable:) does not commit that
        // transaction to the window compositor.
        [commands commit];
        [commands waitUntilCompleted];
        if (commands.status != MTLCommandBufferStatusCompleted)
            return NO;
        [drawable present];
        return YES;
    }
    [commands presentDrawable:drawable];
    [commands commit];
    return YES;
}

- (BOOL)selfTestFiltering:(NSError **)error {
    // Mid-gray steps expose cubic overshoot that a black/white fixture would
    // hide through the render target's own [0,1] clamp. Also exercise alpha.
    const uint8_t expectedRows[3][16] = {
        {64, 64, 64, 64, 64, 64, 64, 64, 192, 192, 192, 192, 192, 192, 192, 192},
        {64, 64, 64, 64, 64, 64, 80, 112, 144, 176, 192, 192, 192, 192, 192, 192},
        {64, 64, 64, 64, 64, 64, 75, 108, 148, 181, 192, 192, 192, 192, 192, 192}};
    const int sizes[] = {2, 4, 16}; // Minification, 1:1, and physical-pixel magnification.
    const double background[] = {0.05, 0.04, 0.035}; // BGRA order.
    for (int transparent = 0; transparent < 2; ++transparent) {
        uint8_t pixels[4 * 4 * 4];
        for (int y = 0; y < 4; ++y)
            for (int x = 0; x < 4; ++x) {
                uint8_t value = x < 2 ? 64 : 192;
                size_t i = (size_t)(y * 4 + x) * 4;
                pixels[i] = pixels[i + 1] = transparent ? 0 : value;
                pixels[i + 2] = value;
                pixels[i + 3] = transparent ? value : 255;
            }
        MTLTextureDescriptor *sourceDesc =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                               width:4
                                                              height:4
                                                           mipmapped:NO];
        sourceDesc.storageMode = MTLStorageModeShared;
        _texture = [_device newTextureWithDescriptor:sourceDesc];
        if (!_texture) {
            if (error)
                *error = BMRenderError(@"Could not allocate filter test input.");
            return NO;
        }
        [_texture replaceRegion:MTLRegionMake2D(0, 0, 4, 4)
                    mipmapLevel:0
                      withBytes:pixels
                    bytesPerRow:16];
        for (int sizeIndex = 0; sizeIndex < 3; ++sizeIndex) {
            int size = sizes[sizeIndex];
            MTLTextureDescriptor *desc =
                [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                   width:(NSUInteger)size
                                                                  height:(NSUInteger)size
                                                               mipmapped:NO];
            desc.usage = MTLTextureUsageRenderTarget;
            desc.storageMode = MTLStorageModeShared;
            id<MTLTexture> target = [_device newTextureWithDescriptor:desc];
            if (!target) {
                if (error)
                    *error = BMRenderError(@"Could not allocate filter test output.");
                return NO;
            }
            for (int filter = 0; filter < 3; ++filter)
                for (int mirror = 0; mirror < 2; ++mirror) {
                    // Logical scale stays 1; the drawable determines magnification.
                    BMUniforms u = {.viewport = {4, 4},
                                    .imageSize = {4, 4},
                                    .scale = 1,
                                    .radius = 1,
                                    .filterMode = (float)filter,
                                    .mirror = (float)mirror};
                    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
                    pass.colorAttachments[0].texture = target;
                    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
                    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
                    id<MTLCommandBuffer> commands = [_queue commandBuffer];
                    [self encode:commands pass:pass uniforms:u];
                    [commands commit];
                    [commands waitUntilCompleted];
                    if (commands.error) {
                        if (error)
                            *error = commands.error;
                        return NO;
                    }
                    uint8_t result[16 * 16 * 4];
                    [target getBytes:result
                         bytesPerRow:(NSUInteger)size * 4
                          fromRegion:MTLRegionMake2D(0, 0, (NSUInteger)size, (NSUInteger)size)
                         mipmapLevel:0];
                    for (int y = 0; y < size; ++y)
                        for (int x = 0; x < size; ++x) {
                            int sx = mirror ? size - 1 - x : x;
                            int value =
                                size == 16 ? expectedRows[filter][sx] : (sx < size / 2 ? 64 : 192);
                            for (int channel = 0; channel < 4; ++channel) {
                                int expected = channel == 3 ? 255 : value;
                                if (transparent && channel < 3)
                                    expected = (int)lround((channel == 2 ? value : 0) +
                                                           background[channel] * (255 - value));
                                if (abs(result[(y * size + x) * 4 + channel] - expected) > 1) {
                                    if (error)
                                        *error = BMRenderError([NSString
                                            stringWithFormat:
                                                @"Filter %d test failed: size %d, alpha %d, mirror "
                                                @"%d, (%d,%d), channel %d: got %u, expected %d.",
                                                filter, size, transparent, mirror, x, y, channel,
                                                result[(y * size + x) * 4 + channel], expected]);
                                    return NO;
                                }
                            }
                        }
                }
        }
    }
    return YES;
}

- (BOOL)selfTestImageSource:(BOOL)usePixelBuffer error:(NSError **)error {
    // Asymmetric 2×2 fixture catches flips, mirroring, channel swaps and shader ABI issues.
    uint8_t pixels[] = {0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255, 255, 255, 255, 255};
    if (usePixelBuffer) {
        CVPixelBufferRef buffer = NULL;
        NSDictionary *attributes = @{
            (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
            (id)kCVPixelBufferMetalCompatibilityKey : @YES
        };
        if (CVPixelBufferCreate(NULL, 2, 2, kCVPixelFormatType_32BGRA,
                                (__bridge CFDictionaryRef)attributes,
                                &buffer) != kCVReturnSuccess) {
            if (error)
                *error = BMRenderError(@"Could not allocate capture buffer test input.");
            return NO;
        }
        CVPixelBufferLockBaseAddress(buffer, 0);
        uint8_t *base = CVPixelBufferGetBaseAddress(buffer);
        size_t stride = CVPixelBufferGetBytesPerRow(buffer);
        for (size_t row = 0; row < 2; ++row)
            memcpy(base + row * stride, pixels + row * 8, 8);
        CVPixelBufferUnlockBaseAddress(buffer, 0);
        BOOL loaded = [self setPixelBuffer:buffer];
        // Rendering must retain the IOSurface after the capture callback ends.
        CVPixelBufferRelease(buffer);
        if (!loaded) {
            if (error)
                *error = BMRenderError(@"Could not map capture buffer test input.");
            return NO;
        }
    } else {
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef ctx =
            CGBitmapContextCreate(pixels, 2, 2, 8, 8, space,
                                  kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
        CGColorSpaceRelease(space);
        CGImageRef image = CGBitmapContextCreateImage(ctx);
        BOOL loaded = [self setImage:image error:error];
        CGImageRelease(image);
        CGContextRelease(ctx);
        if (!loaded)
            return NO;
    }
    MTLTextureDescriptor *desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:8
                                                          height:8
                                                       mipmapped:NO];
    desc.usage = MTLTextureUsageRenderTarget;
    desc.storageMode = MTLStorageModeShared;
    id<MTLTexture> target = [_device newTextureWithDescriptor:desc];
    for (int mode = 0; mode < 4; ++mode) {
        BMUniforms u = {.viewport = {8, 8},
                        .imageSize = {8, 8},
                        .scale = 1,
                        .radius = 1,
                        .cursor = {100, 100},
                        .mirror = mode == 1 ? 1.0f : 0.0f,
                        .dim = mode == 2 ? 0.8f : 0};
        if (mode == 3) {
            u.scale = 2;
            u.offset = (vector_float2){-2, -2};
        }
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = target;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandBuffer> commands = [_queue commandBuffer];
        [self encode:commands pass:pass uniforms:u];
        [commands commit];
        [commands waitUntilCompleted];
        if (commands.error) {
            if (error)
                *error = commands.error;
            return NO;
        }
        uint8_t result[8 * 8 * 4];
        [target getBytes:result
             bytesPerRow:32
              fromRegion:MTLRegionMake2D(0, 0, 8, 8)
             mipmapLevel:0];
        for (int y = 0; y < 8; ++y)
            for (int x = 0; x < 8; ++x) {
                int sx = x / 4, sy = y / 4;
                if (mode == 3) {
                    sx = (x + 2) / 8;
                    sy = (y + 2) / 8;
                }
                if (mode == 1)
                    sx = 1 - sx;
                for (int channel = 0; channel < 4; ++channel) {
                    int expected = pixels[(sy * 2 + sx) * 4 + channel];
                    if (mode == 2 && channel < 3)
                        expected = (int)lround(expected * 0.2);
                    if (abs(result[(y * 8 + x) * 4 + channel] - expected) > 1) {
                        if (error)
                            *error = BMRenderError([NSString
                                stringWithFormat:@"GPU test mode %d failed at (%d,%d), channel %d.",
                                                 mode, x, y, channel]);
                        return NO;
                    }
                }
            }
    }
    return YES;
}

- (BOOL)selfTest:(NSError **)error {
    return [self selfTestImageSource:NO error:error] &&
           [self selfTestImageSource:YES error:error] && [self selfTestFiltering:error];
}

@end
