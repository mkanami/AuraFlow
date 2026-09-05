#import "AuraFlowLockScreen.h"

#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>

static void *AuraFlowReadyForDisplayContext = &AuraFlowReadyForDisplayContext;
static NSString * const AuraFlowRuntimeCommandNotification =
    @"com.andrijvergeles.auraflow.runtime-command-did-change";

@interface AuraFlowLockScreen ()
@property(nonatomic, strong) CALayer *fallbackLayer;
@property(nonatomic, strong, nullable) AVQueuePlayer *player;
@property(nonatomic, strong, nullable) AVPlayerLayer *playerLayer;
@property(nonatomic, strong, nullable) AVPlayerLooper *playerLooper;
@property(nonatomic, copy, nullable) NSString *configurationSignature;
@property(nonatomic, copy) NSString *scaleMode;
@property(nonatomic) BOOL observingReadyForDisplay;
@property(nonatomic) BOOL runtimePaused;
@property(nonatomic) BOOL playerLayerPaused;
@end

@implementation AuraFlowLockScreen

+ (BOOL)performGammaFade {
    // Keep the captured fallback frame visible while AVPlayer pre-rolls.
    // ScreenSaverView's default gamma fade darkens the desktop first and can
    // look like a black flash on an otherwise seamless transition.
    return NO;
}

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self) {
        self.animationTimeInterval = 1.0 / 30.0;
        self.scaleMode = @"fill";
        [self createLayers];
        [self applyResolvedConfiguration:[self resolvedConfiguration] force:YES];
        [[NSDistributedNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(runtimeCommandDidChange:)
                   name:AuraFlowRuntimeCommandNotification
                 object:nil
     suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    }
    return self;
}

- (void)dealloc {
    [[NSDistributedNotificationCenter defaultCenter]
        removeObserver:self
                  name:AuraFlowRuntimeCommandNotification
                object:nil];
    [self tearDownPlayer];
}

- (void)createLayers {
    self.wantsLayer = YES;
    self.layer = [CALayer layer];
    self.layer.backgroundColor = NSColor.blackColor.CGColor;
    self.layer.masksToBounds = YES;

    self.fallbackLayer = [CALayer layer];
    self.fallbackLayer.backgroundColor = NSColor.blackColor.CGColor;
    self.fallbackLayer.contentsGravity = kCAGravityResizeAspectFill;
    self.fallbackLayer.masksToBounds = YES;
    [self.layer addSublayer:self.fallbackLayer];
    [self layoutVideoLayers];
}

- (void)startAnimation {
    [super startAnimation];

    // ScreenSaverView instances can be reused. Refresh only when the effective
    // paths or scale mode changed so a pre-rolled first frame is preserved.
    [self applyResolvedConfiguration:[self resolvedConfiguration] force:NO];
    [self syncRuntimePauseState];
    if (!self.runtimePaused) {
        [self.player playImmediatelyAtRate:1.0];
    }
}

- (void)stopAnimation {
    [self.player pause];
    [super stopAnimation];
}

- (void)animateOneFrame {
    // AVPlayerLayer renders on its own clock. The runtime pause marker is the
    // cross-process Stop contract: ScreenSaverView is a separate process from
    // AuraWallpaperAgent, so the agent's CALayer pause alone cannot stop this
    // player when macOS enters the secure Lock Screen.
    [self syncRuntimePauseState];
}

- (void)runtimeCommandDidChange:(NSNotification *)notification {
    // The command is written before the distributed notification is posted.
    // Hop to the screen-saver view's thread so the player is paused before
    // the next secure-surface refresh, without waiting for animateOneFrame.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self syncRuntimePauseState];
    });
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self layoutVideoLayers];
}

- (BOOL)hasConfigureSheet {
    return NO;
}

- (nullable NSWindow *)configureSheet {
    return nil;
}

- (void)layoutVideoLayers {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.playerLayer.frame = self.bounds;
    self.fallbackLayer.frame = self.bounds;
    [CATransaction commit];
}

- (NSDictionary<NSString *, NSString *> *)resolvedConfiguration {
    NSBundle *bundle = [NSBundle bundleForClass:self.class];
    NSURL *resourcesURL = bundle.resourceURL;
    NSURL *bundleConfigURL =
        [resourcesURL URLByAppendingPathComponent:@"AuraFlowLockScreenConfig.json"];
    NSDictionary *bundleConfig = [self JSONDictionaryAtURL:bundleConfigURL];

    NSString *scaleMode = [self normalizedScaleMode:bundleConfig[@"scale_mode"]];
    NSURL *videoURL = [self existingURLForConfiguredValue:bundleConfig[@"video_file"]
                                                relativeTo:resourcesURL];
    NSURL *fallbackURL =
        [self existingURLForConfiguredValue:bundleConfig[@"fallback_frame_file"]
                                  relativeTo:resourcesURL];

    NSURL *applicationSupportURL =
        [NSURL fileURLWithPath:[NSHomeDirectory()
            stringByAppendingPathComponent:@"Library/Application Support/AuraFlow"]
                   isDirectory:YES];
    NSURL *runtimeConfigURL =
        [applicationSupportURL URLByAppendingPathComponent:@"config.json"];
    NSDictionary *runtimeConfig = [self JSONDictionaryAtURL:runtimeConfigURL];

    // The app runtime contract uses video_path while the portable saver
    // resource uses video_file. A lock-only agent has a separate source
    // contract; never let a stale Desktop config win over the wallpaper the
    // user selected for this Lock Screen generation.
    NSString *lockOnlySourceMarkerPath =
        [applicationSupportURL.path stringByAppendingPathComponent:
            @"lock_screen_only_source.json"];
    NSURL *runtimeVideoURL = nil;
    if ([[NSFileManager defaultManager]
            fileExistsAtPath:lockOnlySourceMarkerPath]) {
        NSURL *lockOnlySourceURL =
            [applicationSupportURL URLByAppendingPathComponent:
                @"lock_screen_only_source.json"];
        NSDictionary *lockOnlySource =
            [self JSONDictionaryAtURL:lockOnlySourceURL];
        runtimeVideoURL =
            [self existingURLForConfiguredValue:lockOnlySource[@"path"]
                                        relativeTo:applicationSupportURL];
    }
    if (runtimeVideoURL == nil) {
        runtimeVideoURL =
            [self existingURLForConfiguredValue:runtimeConfig[@"video_path"]
                                        relativeTo:applicationSupportURL];
    }
    if (runtimeVideoURL != nil) {
        videoURL = runtimeVideoURL;
    }
    if ([runtimeConfig[@"scale_mode"] isKindOfClass:NSString.class]) {
        scaleMode = [self normalizedScaleMode:runtimeConfig[@"scale_mode"]];
    }

    NSURL *runtimeFallbackURL =
        [applicationSupportURL URLByAppendingPathComponent:@"last_frame.png"];
    if ([[NSFileManager defaultManager] isReadableFileAtPath:runtimeFallbackURL.path]) {
        fallbackURL = runtimeFallbackURL;
    }

    return @{
        @"video_path" : videoURL.path ?: @"",
        @"fallback_path" : fallbackURL.path ?: @"",
        @"scale_mode" : scaleMode,
    };
}

- (BOOL)runtimePauseMarkerExists {
    NSString *applicationSupportPath =
        [NSHomeDirectory() stringByAppendingPathComponent:
            @"Library/Application Support/AuraFlow"];
    NSString *pauseMarkerPath =
        [applicationSupportPath stringByAppendingPathComponent:
            @"wallpaper_daemon.paused"];
    return [[NSFileManager defaultManager] fileExistsAtPath:pauseMarkerPath];
}

- (void)syncRuntimePauseState {
    BOOL paused = [self runtimePauseMarkerExists];
    if (paused) {
        self.runtimePaused = YES;
        // Enforce the paused state on every saver tick as well as on the
        // distributed notification. macOS may recreate the AVPlayerLayer
        // during a lock refresh, resetting its timing without changing the
        // marker state.
        [self pausePlayerLayerAtCurrentFrame];
        [self.player pause];
        return;
    }

    if (!self.runtimePaused) {
        return;
    }

    self.runtimePaused = NO;
    [self resumePlayerLayer];
    [self.player playImmediatelyAtRate:1.0];
}

- (void)pausePlayerLayerAtCurrentFrame {
    AVPlayerLayer *layer = self.playerLayer;
    if (layer == nil || self.playerLayerPaused) {
        return;
    }

    // AVPlayer and AVPlayerLayer have separate clocks. Freezing only the
    // player still lets the compositor advance a frame during a secure-lock
    // refresh, which is why Lock Screen used to keep moving after Stop.
    CFTimeInterval pausedTime = [layer convertTime:CACurrentMediaTime()
                                          fromLayer:nil];
    layer.speed = 0.0;
    layer.timeOffset = pausedTime;
    self.playerLayerPaused = YES;
}

- (void)resumePlayerLayer {
    AVPlayerLayer *layer = self.playerLayer;
    if (layer == nil || !self.playerLayerPaused) {
        return;
    }

    CFTimeInterval pausedTime = layer.timeOffset;
    layer.speed = 1.0;
    layer.timeOffset = 0.0;
    layer.beginTime = 0.0;
    CFTimeInterval currentTime = [layer convertTime:CACurrentMediaTime()
                                           fromLayer:nil];
    layer.beginTime = currentTime - pausedTime;
    self.playerLayerPaused = NO;
}

- (NSDictionary *)JSONDictionaryAtURL:(NSURL *)URL {
    if (URL == nil) {
        return @{};
    }

    NSData *data = [NSData dataWithContentsOfURL:URL
                                         options:NSDataReadingMappedIfSafe
                                           error:nil];
    if (data == nil) {
        return @{};
    }

    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:NSDictionary.class] ? object : @{};
}

- (nullable NSURL *)existingURLForConfiguredValue:(id)value
                                        relativeTo:(nullable NSURL *)baseURL {
    if (![value isKindOfClass:NSString.class]) {
        return nil;
    }

    NSString *path = [(NSString *)value stringByExpandingTildeInPath];
    if (path.length == 0) {
        return nil;
    }

    NSURL *URL = nil;
    if (path.isAbsolutePath) {
        URL = [NSURL fileURLWithPath:path];
    } else if (baseURL != nil) {
        URL = [baseURL URLByAppendingPathComponent:path];
    }

    if (URL != nil && [[NSFileManager defaultManager] isReadableFileAtPath:URL.path]) {
        return URL.URLByStandardizingPath;
    }
    return nil;
}

- (NSString *)normalizedScaleMode:(id)value {
    if (![value isKindOfClass:NSString.class]) {
        return @"fill";
    }
    NSString *mode = [(NSString *)value lowercaseString];
    if ([mode isEqualToString:@"fit"] || [mode isEqualToString:@"stretch"]) {
        return mode;
    }
    return @"fill";
}

- (void)applyResolvedConfiguration:(NSDictionary<NSString *, NSString *> *)configuration
                             force:(BOOL)force {
    NSString *signature =
        [NSString stringWithFormat:@"%@|%@|%@|%@|%@",
                                   configuration[@"video_path"],
                                   configuration[@"fallback_path"],
                                   configuration[@"scale_mode"],
                                   [self fileRevisionAtPath:configuration[@"video_path"]],
                                   [self fileRevisionAtPath:configuration[@"fallback_path"]]];
    if (!force && [signature isEqualToString:self.configurationSignature]) {
        return;
    }

    self.configurationSignature = signature;
    self.scaleMode = configuration[@"scale_mode"];
    [self setFallbackImageAtPath:configuration[@"fallback_path"]];
    [self tearDownPlayer];
    [self applyScaleMode];

    NSString *videoPath = configuration[@"video_path"];
    if (videoPath.length == 0) {
        self.fallbackLayer.hidden = NO;
        return;
    }

    AVURLAsset *asset =
        [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:videoPath]
                            options:@{AVURLAssetPreferPreciseDurationAndTimingKey : @NO}];
    AVPlayerItem *templateItem = [AVPlayerItem playerItemWithAsset:asset];
    AVQueuePlayer *queuePlayer = [AVQueuePlayer queuePlayerWithItems:@[]];
    queuePlayer.muted = YES;
    queuePlayer.volume = 0.0;
    queuePlayer.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    queuePlayer.automaticallyWaitsToMinimizeStalling = NO;
    if (@available(macOS 10.15, *)) {
        queuePlayer.preventsDisplaySleepDuringVideoPlayback = NO;
    }

    AVPlayerLayer *playerLayer = [AVPlayerLayer playerLayerWithPlayer:queuePlayer];
    playerLayer.backgroundColor = NSColor.blackColor.CGColor;
    playerLayer.masksToBounds = YES;
    self.player = queuePlayer;
    self.playerLayer = playerLayer;
    self.playerLooper = [AVPlayerLooper playerLooperWithPlayer:queuePlayer
                                                  templateItem:templateItem];
    [self applyScaleMode];

    [self.layer insertSublayer:playerLayer below:self.fallbackLayer];
    [self layoutVideoLayers];
    self.fallbackLayer.hidden = NO;

    [playerLayer addObserver:self
                 forKeyPath:@"readyForDisplay"
                    options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                    context:AuraFlowReadyForDisplayContext];
    self.observingReadyForDisplay = YES;

    // Constructing the item and layer begins asynchronous asset preparation.
    // Playback stays paused until startAnimation, while the fallback remains
    // visible until AVPlayerLayer reports a decoded frame.
}

- (NSString *)fileRevisionAtPath:(NSString *)path {
    if (path.length == 0) {
        return @"";
    }
    NSDictionary<NSFileAttributeKey, id> *attributes =
        [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    return [NSString stringWithFormat:@"%@:%@",
                                      attributes[NSFileModificationDate],
                                      attributes[NSFileSize]];
}

- (void)setFallbackImageAtPath:(NSString *)path {
    self.fallbackLayer.hidden = NO;
    if (path.length == 0) {
        return;
    }

    NSImage *image = [[NSImage alloc] initWithContentsOfFile:path];
    CGImageRef CGImage = [image CGImageForProposedRect:NULL context:nil hints:nil];
    if (CGImage != NULL) {
        self.fallbackLayer.contents = (__bridge id)CGImage;
    }
}

- (void)applyScaleMode {
    if ([self.scaleMode isEqualToString:@"fit"]) {
        self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspect;
        self.fallbackLayer.contentsGravity = kCAGravityResizeAspect;
    } else if ([self.scaleMode isEqualToString:@"stretch"]) {
        self.playerLayer.videoGravity = AVLayerVideoGravityResize;
        self.fallbackLayer.contentsGravity = kCAGravityResize;
    } else {
        self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        self.fallbackLayer.contentsGravity = kCAGravityResizeAspectFill;
    }
}

- (void)tearDownPlayer {
    self.playerLayerPaused = NO;
    [self.player pause];
    if (self.observingReadyForDisplay && self.playerLayer != nil) {
        [self.playerLayer removeObserver:self
                              forKeyPath:@"readyForDisplay"
                                 context:AuraFlowReadyForDisplayContext];
    }
    self.observingReadyForDisplay = NO;
    [self.playerLayer removeFromSuperlayer];
    self.playerLooper = nil;
    self.playerLayer.player = nil;
    self.playerLayer = nil;
    self.player = nil;
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
    if (context == AuraFlowReadyForDisplayContext) {
        AVPlayerLayer *observedLayer = object;
        BOOL ready = observedLayer.readyForDisplay;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (observedLayer == self.playerLayer) {
                self.fallbackLayer.hidden = ready;
            }
        });
        return;
    }
    [super observeValueForKeyPath:keyPath
                         ofObject:object
                           change:change
                          context:context];
}

@end
