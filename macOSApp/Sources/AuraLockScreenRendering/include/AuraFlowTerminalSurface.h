#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

/// Reads the terminal agent's existing BGRA IOSurface without PNG encoding,
/// filesystem frame copies, or a second animation clock.
@interface AuraFlowTerminalSurfaceRenderer : NSObject
@property(nonatomic, readonly, nullable) id<MTLDevice> device;
@property(nonatomic) MTLClearColor clearColor;
- (BOOL)updateDescriptor:(NSDictionary *)descriptor expectedAgentPID:(int)pid;
- (BOOL)encodeToTexture:(id<MTLTexture>)target
         commandBuffer:(id<MTLCommandBuffer>)commandBuffer
             scaleMode:(NSString *)scaleMode;
@end

/// Presents only the latest available surface; slow display passes never queue
/// old animation frames. If surface access fails the saver keeps its PNG path.
@interface AuraFlowTerminalSurfaceLayer : CAMetalLayer
- (BOOL)presentDescriptor:(NSDictionary *)descriptor
        expectedAgentPID:(int)pid
               scaleMode:(NSString *)scaleMode;
- (void)resetSource;
@end

NS_ASSUME_NONNULL_END
