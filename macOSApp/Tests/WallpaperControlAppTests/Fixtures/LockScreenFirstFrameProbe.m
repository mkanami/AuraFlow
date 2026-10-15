#import "AuraFlowLockScreen.h"
#import <QuartzCore/QuartzCore.h>
#import <unistd.h>

static NSURL *runtimeRoot;

@interface FirstFrameSaver : AuraFlowLockScreen
@property(nonatomic) NSUInteger videoConfigurationReads;
@end

@implementation FirstFrameSaver
- (NSURL *)terminalRuntimeURLForFile:(NSString *)name {
    return [runtimeRoot URLByAppendingPathComponent:name];
}
- (BOOL)runtimePauseMarkerExists { return NO; }
- (NSDictionary *)resolvedConfiguration {
    self.videoConfigurationReads += 1;
    return @{@"video_path":@"", @"fallback_path":@"", @"scale_mode":@"fill", @"playback_rate":@"1"};
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2) return 2;
        [NSApplication sharedApplication];
        NSURL *root = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
        runtimeRoot = [root URLByAppendingPathComponent:@"terminal-wallpaper"];
        [[NSFileManager defaultManager] createDirectoryAtURL:runtimeRoot withIntermediateDirectories:YES attributes:nil error:nil];
        NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL pixelsWide:2 pixelsHigh:2 bitsPerSample:8
            samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
            bytesPerRow:8 bitsPerPixel:32];
        for (NSUInteger i = 0; i < 16; i += 4) {
            bitmap.bitmapData[i] = 255; bitmap.bitmapData[i + 1] = 0;
            bitmap.bitmapData[i + 2] = 0; bitmap.bitmapData[i + 3] = 255;
        }
        [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
            writeToURL:[runtimeRoot URLByAppendingPathComponent:@"lock-screen-frame.png"] atomically:YES];
        NSURL *heartbeat = [runtimeRoot URLByAppendingPathComponent:@"lock-screen-heartbeat.json"];
        NSData *lease = [NSJSONSerialization dataWithJSONObject:
            @{@"pid":@(getpid()), @"updatedAt":@1} options:0 error:nil];
        [lease writeToURL:heartbeat atomically:YES];
        NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
        FirstFrameSaver *saver = [[FirstFrameSaver alloc] initWithFrame:NSMakeRect(0,0,320,240) isPreview:YES];
        CALayer *frame = [saver valueForKey:@"terminalLayer"];
        CGImageRef image = (__bridge CGImageRef)frame.contents;
        // No animation tick or run-loop delivery has occurred. The existing
        // raster must already be selected and visible in the initial view.
        BOOL ready = [[saver valueForKey:@"terminalModeActive"] boolValue] && !frame.hidden
            && image && CGImageGetWidth(image) == 2 && CGImageGetHeight(image) == 2
            && saver.videoConfigurationReads == 0;
        if (!ready) return 3;
        printf("first-frame-before-start %.6f\n", NSProcessInfo.processInfo.systemUptime - started);
        [saver startAnimation];
        if (saver.videoConfigurationReads != 0 || frame.hidden) return 4;
        // OFF must reject a live terminal lease immediately, even if the
        // helper has not consumed its update command yet.
        NSURL *configURL = [root URLByAppendingPathComponent:@"config.json"];
        [[NSJSONSerialization dataWithJSONObject:@{@"show_on_lock_screen":@NO} options:0 error:nil] writeToURL:configURL atomically:YES];
        [saver animateOneFrame];
        if ([[saver valueForKey:@"terminalModeActive"] boolValue] || !frame.hidden) return 7;
        [[NSJSONSerialization dataWithJSONObject:@{@"show_on_lock_screen":@YES} options:0 error:nil] writeToURL:configURL atomically:YES];
        [saver animateOneFrame];
        if (![[saver valueForKey:@"terminalModeActive"] boolValue] || frame.hidden) return 8;
        // An expired route must still restore the normal wallpaper lazily.
        [[NSFileManager defaultManager] removeItemAtURL:heartbeat error:nil];
        [saver animateOneFrame];
        if ([[saver valueForKey:@"terminalModeActive"] boolValue] || !frame.hidden
            || saver.videoConfigurationReads == 0) return 5;
        [saver stopAnimation];
        // A fresh view without a live lease must not expose a stale PNG.
        FirstFrameSaver *stale = [[FirstFrameSaver alloc] initWithFrame:NSMakeRect(0,0,320,240) isPreview:YES];
        if ([[stale valueForKey:@"terminalModeActive"] boolValue] || stale.videoConfigurationReads == 0) return 6;
        return 0;
    }
}
