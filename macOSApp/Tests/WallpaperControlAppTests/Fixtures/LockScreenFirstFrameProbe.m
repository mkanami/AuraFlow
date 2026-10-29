#import "AuraFlowLockScreen.h"
#import "AuraFlowTerminalSurface.h"
#import <QuartzCore/QuartzCore.h>
#import <unistd.h>

static NSURL *runtimeRoot;
static NSURL *desktopImageURL;

@interface AuraFlowLockScreen (Probe)
- (BOOL)terminalAgentIsAlive;
- (NSDictionary *)resolvedConfiguration;
- (BOOL)runtimePauseMarkerExists;
@end

@interface AccountHomeSaver : AuraFlowLockScreen
@end
@implementation AccountHomeSaver
- (NSURL *)terminalRuntimeURLForFile:(NSString *)name {
    return [runtimeRoot URLByAppendingPathComponent:name];
}
- (NSURL *)currentDesktopImageURL { return desktopImageURL; }
- (NSURL *)wallpaperStoreURL {
    return [[runtimeRoot URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"Index.plist"];
}
- (NSURL *)extensionResourcesURLForProvider:(NSString *)provider {
    if (![provider isEqualToString:@"com.apple.wallpaper.choice.sequoia"]) return nil;
    return [[runtimeRoot URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"native-resources"];
}
@end

@interface IntermittentSurface : AuraFlowTerminalSurfaceLayer
@property(nonatomic) BOOL canPresent;
@end
@implementation IntermittentSurface
- (BOOL)presentDescriptor:(NSDictionary *)descriptor expectedAgentPID:(int)pid scaleMode:(NSString *)mode {
    return self.canPresent;
}
@end

@interface FirstFrameSaver : AccountHomeSaver
@property(nonatomic) NSUInteger videoConfigurationReads;
@end

@implementation FirstFrameSaver
- (BOOL)terminalProcessIsAlive:(pid_t)pid { return pid == getpid(); }
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
        // The user's wallpaper is deliberately different from a stale Aura
        // frame, so an orphaned saver must select and paint the right source.
        for (NSUInteger i = 0; i < 16; i += 4) {
            bitmap.bitmapData[i] = 0; bitmap.bitmapData[i + 1] = 255;
        }
        desktopImageURL = [root URLByAppendingPathComponent:@"user-wallpaper.png"];
        [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
            writeToURL:desktopImageURL atomically:YES];
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
        // A GPU drawable may become unavailable while the lid wakes, even
        // when the live route and its last published image remain valid.
        IntermittentSurface *surface = [IntermittentSurface layer];
        [saver setValue:surface forKey:@"terminalSurfaceLayer"];
        [saver.layer addSublayer:surface];
        surface.canPresent = YES;
        [saver animateOneFrame];
        if (surface.hidden || frame.hidden || frame.contents == nil) return 9;
        NSURL *frameURL = [runtimeRoot URLByAppendingPathComponent:@"lock-screen-frame.png"];
        NSData *savedPNG = [NSData dataWithContentsOfURL:frameURL];
        [[NSFileManager defaultManager] removeItemAtURL:frameURL error:nil];
        surface.canPresent = NO;
        [saver animateOneFrame];
        if (!surface.hidden || frame.hidden || frame.contents == nil ||
            ![[saver valueForKey:@"terminalModeActive"] boolValue]) return 10;
        [savedPNG writeToURL:frameURL atomically:YES];
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

        // Reboot without autostart: the saver stays selected, but there is no
        // helper. A stale video frame must not outrank the user's wallpaper.
        [savedPNG writeToURL:[root URLByAppendingPathComponent:@"last_frame.png"] atomically:YES];
        AccountHomeSaver *orphaned = [[AccountHomeSaver alloc] initWithFrame:NSMakeRect(0,0,320,240) isPreview:YES];
        NSDictionary *resolved = [orphaned resolvedConfiguration];
        CALayer *fallback = [orphaned valueForKey:@"fallbackLayer"];
        if (![resolved[@"video_path"] isEqualToString:@""] ||
            ![resolved[@"fallback_path"] isEqualToString:desktopImageURL.path] ||
            fallback.hidden || fallback.contents == nil) return 11;
        // A PID can be reused after reboot. The process exists, but it is
        // this probe rather than AuraTerminalWallpaperAgent.
        [lease writeToURL:heartbeat atomically:YES];
        if ([orphaned terminalAgentIsAlive]) return 12;
        // Media and pause markers must resolve through the same real account
        // root as terminal/web, rather than the screen-saver host's HOME.
        NSURL *media = [root URLByAppendingPathComponent:@"wallpaper.mov"];
        [NSData.data writeToURL:media atomically:YES];
        [[NSJSONSerialization dataWithJSONObject:@{@"video_path":media.path, @"scale_mode":@"fit", @"show_on_lock_screen":@YES}
            options:0 error:nil] writeToURL:configURL atomically:YES];
        resolved = [orphaned resolvedConfiguration];
        if (![resolved[@"video_path"] isEqualToString:media.path] ||
            ![resolved[@"fallback_path"] isEqualToString:[root URLByAppendingPathComponent:@"last_frame.png"].path] ||
            ![resolved[@"scale_mode"] isEqualToString:@"fit"]) return 13;
        NSURL *pause = [root URLByAppendingPathComponent:@"wallpaper_daemon.paused"];
        [NSData.data writeToURL:pause atomically:YES];
        if (![orphaned runtimePauseMarkerExists]) return 14;
        [[NSFileManager defaultManager] removeItemAtURL:pause error:nil];
        // OFF overrides persisted media without reviving a previous Aura frame.
        [[NSJSONSerialization dataWithJSONObject:@{@"video_path":media.path, @"show_on_lock_screen":@NO}
            options:0 error:nil] writeToURL:configURL atomically:YES];
        resolved = [orphaned resolvedConfiguration];
        if (![resolved[@"video_path"] isEqualToString:@""] ||
            ![resolved[@"fallback_path"] isEqualToString:desktopImageURL.path]) return 15;
        // Missing media falls back even if its config and cached PNG survive.
        [[NSJSONSerialization dataWithJSONObject:@{@"video_path":[root URLByAppendingPathComponent:@"missing.mov"].path}
            options:0 error:nil] writeToURL:configURL atomically:YES];
        resolved = [orphaned resolvedConfiguration];
        if (![resolved[@"video_path"] isEqualToString:@""] ||
            ![resolved[@"fallback_path"] isEqualToString:desktopImageURL.path]) return 16;
        // The API may still report Aura's managed frame. Use the saved user
        // picture, and skip a corrupt/missing backup instead of painting black.
        NSURL *savedDesktop = desktopImageURL;
        desktopImageURL = [root URLByAppendingPathComponent:@"last_frame.png"];
        [[NSJSONSerialization dataWithJSONObject:@{@"1":@"/missing.png", @"2":savedDesktop.path}
            options:0 error:nil] writeToURL:[root URLByAppendingPathComponent:@"wallpaper_backup_original.json"] atomically:YES];
        resolved = [orphaned resolvedConfiguration];
        if (![resolved[@"fallback_path"] isEqualToString:savedDesktop.path]) return 17;
        // Reused views refresh the user's wallpaper even without a live route
        // transition or distributed notification.
        desktopImageURL = [root URLByAppendingPathComponent:@"changed-wallpaper.png"];
        [savedPNG writeToURL:desktopImageURL atomically:YES];
        [orphaned setValue:@0 forKey:@"configurationCheckedAt"];
        [orphaned animateOneFrame];
        if (![[orphaned valueForKey:@"configurationSignature"] containsString:desktopImageURL.path] ||
            fallback.hidden || fallback.contents == nil) return 18;
        // A procedural provider's stock preview is not the user's selected
        // appearance. Never substitute its light thumbnail for automatic/dark.
        NSURL *resources = [root URLByAppendingPathComponent:@"native-resources"];
        [[NSFileManager defaultManager] createDirectoryAtURL:resources withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *thumbnail = [resources URLByAppendingPathComponent:@"thumbnail.heic"];
        [[NSData dataWithContentsOfURL:savedDesktop] writeToURL:thumbnail atomically:YES];
        desktopImageURL = [root URLByAppendingPathComponent:@"DefaultDesktop.heic"];
        NSDictionary *mode = @{@"Content":@{@"Choices":@[@{@"Provider":@"com.apple.wallpaper.choice.sequoia"}]}};
        NSURL *indexURL = [root URLByAppendingPathComponent:@"Index.plist"];
        [@{@"AllSpacesAndDisplays":@{@"Desktop":mode, @"Idle":@{}}} writeToURL:indexURL atomically:YES];
        resolved = [orphaned resolvedConfiguration];
        if (![resolved[@"fallback_path"] isEqualToString:savedDesktop.path]) return 19;
        // A missing provider preview must still reach the saved user image.
        [[NSFileManager defaultManager] removeItemAtURL:thumbnail error:nil];
        resolved = [orphaned resolvedConfiguration];
        if (![resolved[@"fallback_path"] isEqualToString:savedDesktop.path]) return 20;
        [@{@"AllSpacesAndDisplays":@{@"Desktop":@{@"Content":@"$null"}}} writeToURL:indexURL atomically:YES];
        resolved = [orphaned resolvedConfiguration];
        if (![resolved[@"fallback_path"] isEqualToString:savedDesktop.path]) return 21;
        // No known user image: leave the native background visible, never
        // manufacture a stock preview (or an opaque black substitute).
        [[NSFileManager defaultManager] removeItemAtURL:[root URLByAppendingPathComponent:@"wallpaper_backup_original.json"] error:nil];
        desktopImageURL = [NSURL fileURLWithPath:@"/System/Library/CoreServices/DefaultDesktop.heic"];
        resolved = [orphaned resolvedConfiguration];
        if ([resolved[@"fallback_path"] length] != 0) return 22;
        [orphaned setValue:@0 forKey:@"configurationCheckedAt"];
        [orphaned animateOneFrame];
        if (fallback.contents != nil || CGColorGetAlpha(orphaned.layer.backgroundColor) != 0) return 23;
        [orphaned stopAnimation];
        return 0;
    }
}
