#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <ScreenSaver/ScreenSaver.h>

static void fail(NSString *message) {
    fprintf(stderr, "%s\n", message.UTF8String);
    exit(1);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) {
            fail(@"usage: screensaver_smoke_host PATH_TO_SAVER");
        }

        NSString *bundlePath = [NSString stringWithUTF8String:argv[1]];
        NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
        if (bundle == nil) {
            fail([NSString stringWithFormat:@"bundle not found: %@", bundlePath]);
        }

        NSError *loadError = nil;
        if (![bundle loadAndReturnError:&loadError]) {
            fail([NSString stringWithFormat:@"bundle load failed: %@", loadError]);
        }

        Class principalClass = bundle.principalClass;
        if (principalClass == Nil ||
            ![principalClass isSubclassOfClass:ScreenSaverView.class]) {
            fail(@"principal class is missing or is not a ScreenSaverView");
        }

        [NSApplication sharedApplication];
        ScreenSaverView *view =
            [[principalClass alloc] initWithFrame:NSMakeRect(0, 0, 1280, 720)
                                       isPreview:NO];
        if (view == nil) {
            fail(@"screen saver view initialization failed");
        }

        NSWindow *window =
            [[NSWindow alloc] initWithContentRect:NSMakeRect(-10000, -10000, 1280, 720)
                                       styleMask:NSWindowStyleMaskBorderless
                                         backing:NSBackingStoreBuffered
                                           defer:NO];
        window.contentView = view;
        [window orderBack:nil];
        [view startAnimation];

        // 4K assets can take several seconds to produce their first decoded
        // frame on a cold AVFoundation launch.
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10.0];
        while ([deadline timeIntervalSinceNow] > 0) {
            @autoreleasepool {
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                         beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            }
        }

        CALayer *fallbackLayer = [view valueForKey:@"fallbackLayer"];
        AVPlayerLayer *playerLayer = [view valueForKey:@"playerLayer"];
        AVPlayer *player = [view valueForKey:@"player"];
        BOOL fallbackDecoded = fallbackLayer.contents != nil;
        BOOL videoLayerCreated = playerLayer != nil;
        BOOL videoReady = playerLayer.readyForDisplay;
        BOOL playbackActive =
            player.timeControlStatus == AVPlayerTimeControlStatusPlaying;
        BOOL gammaFadeDisabled = ![principalClass performGammaFade];

        printf(
            "class=%s fallbackDecoded=%s videoLayerCreated=%s "
            "videoReady=%s playbackActive=%s fallbackHidden=%s "
            "gammaFadeDisabled=%s\n",
            NSStringFromClass(principalClass).UTF8String,
            fallbackDecoded ? "true" : "false",
            videoLayerCreated ? "true" : "false",
            videoReady ? "true" : "false",
            playbackActive ? "true" : "false",
            fallbackLayer.hidden ? "true" : "false",
            gammaFadeDisabled ? "true" : "false"
        );

        [view stopAnimation];
        [window orderOut:nil];

        if (!fallbackDecoded || !videoLayerCreated || !videoReady ||
            !playbackActive || !gammaFadeDisabled) {
            return 2;
        }
    }

    return 0;
}
