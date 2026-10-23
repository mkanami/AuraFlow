#import "AuraFlowTerminalSurface.h"
#import <AppKit/AppKit.h>
#import <IOSurface/IOSurface.h>
#import <simd/simd.h>
#import <math.h>

@interface AuraFlowTerminalSurfaceRenderer ()
@property(nonatomic, strong, readwrite) id<MTLDevice> device;
@property(nonatomic, strong) id<MTLRenderPipelineState> pipeline;
@property(nonatomic, strong) id<MTLTexture> sourceTexture;
@property(nonatomic, strong) id surface;
@property(nonatomic, copy) NSDictionary *descriptor;
@end

@implementation AuraFlowTerminalSurfaceRenderer
- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _device = MTLCreateSystemDefaultDevice();
    _clearColor = MTLClearColorMake(0, 0, 0, 1);
    NSString *shader = @"#include <metal_stdlib>\n"
        "using namespace metal;\n"
        "struct V { float4 position [[position]]; float2 uv; };\n"
        "vertex V surface_vertex(uint i [[vertex_id]], constant float2 &scale [[buffer(0)]]) {\n"
        " const float2 p[4] = { float2(-1,-1),float2(1,-1),float2(-1,1),float2(1,1) };\n"
        " const float2 uv[4] = { float2(0,1),float2(1,1),float2(0,0),float2(1,0) };\n"
        " return { float4(p[i]*scale,0,1), uv[i] }; }\n"
        "fragment float4 surface_fragment(V v [[stage_in]], texture2d<float> frame [[texture(0)]]) {\n"
        " constexpr sampler s(filter::linear, address::clamp_to_edge); return frame.sample(s,v.uv); }\n";
    id<MTLLibrary> library = [_device newLibraryWithSource:shader options:nil error:nil];
    if (library) {
        MTLRenderPipelineDescriptor *pipeline = [MTLRenderPipelineDescriptor new];
        pipeline.vertexFunction = [library newFunctionWithName:@"surface_vertex"];
        pipeline.fragmentFunction = [library newFunctionWithName:@"surface_fragment"];
        pipeline.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        _pipeline = [_device newRenderPipelineStateWithDescriptor:pipeline error:nil];
    }
    return self;
}

- (BOOL)updateDescriptor:(NSDictionary *)descriptor expectedAgentPID:(int)pid {
    NSNumber *surfaceID = descriptor[@"surfaceID"], *width = descriptor[@"width"], *height = descriptor[@"height"];
    NSNumber *owner = descriptor[@"agentPID"];
    NSString *generation = descriptor[@"generation"];
    BOOL valid = [surfaceID isKindOfClass:NSNumber.class] && surfaceID.unsignedLongLongValue > 0
        && surfaceID.unsignedLongLongValue <= UINT32_MAX
        && [width isKindOfClass:NSNumber.class] && width.integerValue > 0 && width.integerValue <= 16384
        && [height isKindOfClass:NSNumber.class] && height.integerValue > 0 && height.integerValue <= 16384
        && [owner isKindOfClass:NSNumber.class] && pid > 0 && owner.intValue == pid
        && [generation isKindOfClass:NSString.class] && generation.length > 0;
    if (!valid || !self.pipeline) {
        self.sourceTexture = nil; self.surface = nil; self.descriptor = nil;
        return NO;
    }
    if ([descriptor isEqualToDictionary:self.descriptor] && self.sourceTexture) return YES;
    self.sourceTexture = nil; self.surface = nil; self.descriptor = nil;
    IOSurfaceRef surface = IOSurfaceLookup(surfaceID.unsignedIntValue);
    if (!surface) return NO;
    BOOL matches = IOSurfaceGetWidth(surface) == width.unsignedIntegerValue
        && IOSurfaceGetHeight(surface) == height.unsignedIntegerValue
        && IOSurfaceGetBytesPerElement(surface) == 4
        && IOSurfaceGetPixelFormat(surface) == 0x42475241
        && IOSurfaceGetPlaneCount(surface) == 0
        && IOSurfaceGetBytesPerRow(surface) >= width.unsignedIntegerValue * 4
        && IOSurfaceGetBytesPerRow(surface) % 16 == 0
        && IOSurfaceGetAllocSize(surface) >= IOSurfaceGetBytesPerRow(surface) * height.unsignedIntegerValue;
    if (matches) {
        MTLTextureDescriptor *texture = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
            width:width.unsignedIntegerValue height:height.unsignedIntegerValue mipmapped:NO];
        texture.storageMode = MTLStorageModeShared;
        texture.usage = MTLTextureUsageShaderRead;
        self.sourceTexture = [self.device newTextureWithDescriptor:texture iosurface:surface plane:0];
        if (self.sourceTexture) {
            self.surface = (__bridge id)surface;
            self.descriptor = descriptor;
        }
    }
    CFRelease(surface);
    return self.sourceTexture != nil;
}

- (BOOL)encodeToTexture:(id<MTLTexture>)target commandBuffer:(id<MTLCommandBuffer>)commandBuffer scaleMode:(NSString *)mode {
    if (!self.sourceTexture || !self.pipeline || target.pixelFormat != MTLPixelFormatBGRA8Unorm) return NO;
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor new];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = self.clearColor;
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder) return NO;
    double x = (double)target.width / self.sourceTexture.width;
    double y = (double)target.height / self.sourceTexture.height;
    double uniform = [mode isEqualToString:@"fill"] ? fmax(x,y) : fmin(x,y);
    simd_float2 scale = [mode isEqualToString:@"stretch"] ? (simd_float2){1,1}
        : (simd_float2){(float)(uniform/x),(float)(uniform/y)};
    [encoder setRenderPipelineState:self.pipeline];
    [encoder setVertexBytes:&scale length:sizeof(scale) atIndex:0];
    [encoder setFragmentTexture:self.sourceTexture atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [encoder endEncoding];
    return YES;
}
@end

@interface AuraFlowTerminalSurfaceLayer ()
@property(nonatomic, strong) AuraFlowTerminalSurfaceRenderer *renderer;
@property(nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property(nonatomic) BOOL frameInFlight;
@property(nonatomic) BOOL hasPresented;
@property(nonatomic) NSUInteger sourceGeneration;
@end

@implementation AuraFlowTerminalSurfaceLayer
- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _renderer = [AuraFlowTerminalSurfaceRenderer new];
    self.device = _renderer.device;
    _commandQueue = [self.device newCommandQueue];
    self.pixelFormat = MTLPixelFormatBGRA8Unorm;
    self.framebufferOnly = YES;
    self.opaque = YES;
    self.backgroundColor = NSColor.blackColor.CGColor;
    self.maximumDrawableCount = 2;
    self.actions = @{@"contents":NSNull.null, @"hidden":NSNull.null, @"bounds":NSNull.null, @"position":NSNull.null};
    return self;
}

- (BOOL)presentDescriptor:(NSDictionary *)descriptor expectedAgentPID:(int)pid scaleMode:(NSString *)mode {
    if (![self.renderer updateDescriptor:descriptor expectedAgentPID:pid]) { [self resetSource]; return NO; }
    if (self.bounds.size.width <= 0 || self.bounds.size.height <= 0 || !self.superlayer) return NO;
    CGSize size = CGSizeMake(self.bounds.size.width * self.contentsScale, self.bounds.size.height * self.contentsScale);
    if (!CGSizeEqualToSize(self.drawableSize, size)) {
        // Resizing discards the previous drawable. Do not treat its completed
        // frame as proof that the new display size has been rendered.
        self.sourceGeneration += 1;
        self.hasPresented = NO;
        self.drawableSize = size;
    }
    if (self.frameInFlight) return self.hasPresented;
    id<CAMetalDrawable> drawable = [self nextDrawable];
    id<MTLCommandBuffer> command = [self.commandQueue commandBuffer];
    NSColor *background = [NSColor colorWithCGColor:self.backgroundColor ?: NSColor.blackColor.CGColor];
    background = [background colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
    self.renderer.clearColor = MTLClearColorMake(background.redComponent, background.greenComponent, background.blueComponent, 1);
    if (!drawable || !command || ![self.renderer encodeToTexture:drawable.texture commandBuffer:command scaleMode:mode]) return NO;
    self.frameInFlight = YES;
    NSUInteger generation = self.sourceGeneration;
    __weak AuraFlowTerminalSurfaceLayer *weakSelf = self;
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AuraFlowTerminalSurfaceLayer *layer = weakSelf;
            if (!layer) return;
            layer.frameInFlight = NO;
            if (layer.sourceGeneration == generation) {
                layer.hasPresented = completed.status == MTLCommandBufferStatusCompleted;
            }
        });
    }];
    [command presentDrawable:drawable];
    [command commit];
    // Submission is not a displayed frame. Leave the saver on its retained
    // PNG until the GPU has completed the first drawable successfully.
    return self.hasPresented;
}

- (void)resetSource {
    self.sourceGeneration += 1;
    self.hasPresented = NO;
    [self.renderer updateDescriptor:@{} expectedAgentPID:0];
}
@end
