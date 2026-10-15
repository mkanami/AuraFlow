#import <Foundation/Foundation.h>
#import "AuraFlowTerminalSurface.h"
#import <unistd.h>

// CLI test host for the real saver renderer. No window, runtime configuration,
// or screen-lock action is needed to verify cross-process surface lookup.
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) return 2;
        NSData *data = [[NSString stringWithUTF8String:argv[1]] dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *descriptor = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        AuraFlowTerminalSurfaceRenderer *renderer = [AuraFlowTerminalSurfaceRenderer new];
        if (![renderer updateDescriptor:descriptor expectedAgentPID:atoi(argv[2])]) return 3;
        MTLTextureDescriptor *output = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
            width:2 height:2 mipmapped:NO];
        output.storageMode = MTLStorageModeShared;
        output.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> target = [renderer.device newTextureWithDescriptor:output];
        id<MTLCommandQueue> queue = [renderer.device newCommandQueue];
        for (int frame = 0; frame < 2; frame++) {
            id<MTLCommandBuffer> command = [queue commandBuffer];
            if (![renderer encodeToTexture:target commandBuffer:command scaleMode:@"fill"]) return 4;
            [command commit]; [command waitUntilCompleted];
            if (command.status != MTLCommandBufferStatusCompleted) return 5;
            uint8_t pixel[4] = {0};
            [target getBytes:pixel bytesPerRow:4 fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0];
            printf("%u,%u,%u,%u\n",pixel[0],pixel[1],pixel[2],pixel[3]); fflush(stdout);
            if (frame == 0 && getchar() == EOF) return 6;
        }
    }
    return 0;
}
