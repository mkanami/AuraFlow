#import "AuraFlowLockScreen.h"
#import "AuraFlowTerminalSurface.h"

#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <libproc.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <signal.h>
#import <errno.h>
#import <pwd.h>
#import <unistd.h>
#import <sys/stat.h>

static void *AuraFlowReadyForDisplayContext = &AuraFlowReadyForDisplayContext;
static NSString * const AuraFlowRuntimeCommandNotification =
    @"com.andrijvergeles.auraflow.runtime-command-did-change";

typedef struct {
    dev_t device;
    ino_t inode;
    off_t size;
    struct timespec modified;
    struct timespec changed;
} AuraFlowJSONMetadata;

static BOOL AuraFlowJSONMetadataAtURL(NSURL *url, AuraFlowJSONMetadata *metadata) {
    struct stat info;
    if (stat(url.fileSystemRepresentation, &info) != 0) return NO;
    *metadata = (AuraFlowJSONMetadata){info.st_dev, info.st_ino, info.st_size,
        info.st_mtimespec, info.st_ctimespec};
    return YES;
}

static BOOL AuraFlowJSONMetadataEqual(AuraFlowJSONMetadata a, AuraFlowJSONMetadata b) {
    return a.device == b.device && a.inode == b.inode && a.size == b.size
        && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
        && a.changed.tv_sec == b.changed.tv_sec && a.changed.tv_nsec == b.changed.tv_nsec;
}

@interface AuraFlowJSONCacheEntry : NSObject
@property(nonatomic) AuraFlowJSONMetadata metadata;
@property(nonatomic) CFTimeInterval createdAt;
@property(nonatomic, copy) NSDictionary *dictionary;
@end
@implementation AuraFlowJSONCacheEntry
@end

@interface AuraFlowLockScreen ()
@property(nonatomic, strong) CALayer *fallbackLayer;
@property(nonatomic, strong) CALayer *terminalLayer;
@property(nonatomic, strong) AuraFlowTerminalSurfaceLayer *terminalSurfaceLayer;
@property(nonatomic) BOOL sharedSurfacePresentationEnabled;
@property(nonatomic, copy, nullable) NSString *terminalFrameRevision;
@property(nonatomic) BOOL terminalModeActive;
@property(nonatomic, strong) CALayer *webLayer;
@property(nonatomic) BOOL webModeActive;
@property(nonatomic, copy, nullable) NSString *webFrameRevision;
@property(nonatomic, copy, nullable) NSString *terminalDiagnosticState;
@property(nonatomic, strong, nullable) AVQueuePlayer *player;
@property(nonatomic, strong, nullable) AVPlayerLayer *playerLayer;
@property(nonatomic, strong, nullable) AVPlayerLooper *playerLooper;
@property(nonatomic, copy, nullable) NSString *configurationSignature;
@property(nonatomic) CFTimeInterval configurationCheckedAt;
@property(nonatomic, copy) NSString *scaleMode;
@property(nonatomic) float playbackRate;
@property(nonatomic) BOOL observingReadyForDisplay;
@property(nonatomic) BOOL runtimePaused;
@property(nonatomic) BOOL playerLayerPaused;
@property(nonatomic, strong) NSMutableDictionary<NSString *, AuraFlowJSONCacheEntry *> *jsonCache;
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
        self.jsonCache = [NSMutableDictionary dictionary];
        self.animationTimeInterval = 1.0 / 30.0;
        self.scaleMode = @"fill";
        self.playbackRate = 1.0;
        [self createLayers];
        // The agent has already published a frame before Lock. Paint it while
        // the view is constructed, without waiting for startAnimation or
        // preparing an unrelated video underneath the terminal/web route.
        [self syncTerminalFrame];
        [self syncWebFrame];
        if (!self.terminalModeActive && !self.webModeActive) {
            [self applyResolvedConfiguration:[self resolvedConfiguration] force:YES];
        }
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
    self.terminalLayer = [CALayer layer];
    self.terminalLayer.backgroundColor = NSColor.blackColor.CGColor;
    self.terminalLayer.contentsGravity = kCAGravityResizeAspectFill;
    self.terminalLayer.hidden = YES;
    [self.layer addSublayer:self.terminalLayer];
    // Image frames must replace one another, not cross-fade for the default
    // quarter-second Core Animation transaction duration.
    self.terminalLayer.actions = @{@"contents":NSNull.null, @"hidden":NSNull.null};
    self.webLayer = [CALayer layer];
    self.webLayer.contentsGravity = kCAGravityResizeAspect;
    self.webLayer.backgroundColor = NSColor.blackColor.CGColor;
    self.webLayer.hidden = YES;
    [self.layer addSublayer:self.webLayer];
    [self layoutVideoLayers];
}

- (void)startAnimation {
    [super startAnimation];
    // Construction paints the existing PNG immediately. Metal is needed only
    // for live presentation; do not compile its pipeline before the first frame.
    self.sharedSurfacePresentationEnabled = YES;

    // ScreenSaverView instances can be reused. Refresh only when the effective
    // paths or scale mode changed so a pre-rolled first frame is preserved.
    [self syncTerminalFrame];
    [self syncWebFrame];
    if (!self.terminalModeActive && !self.webModeActive) {
        [self applyResolvedConfiguration:[self resolvedConfiguration] force:NO];
    }
    [self syncRuntimePauseState];
    if (!self.runtimePaused && !self.terminalModeActive && !self.webModeActive) {
        [self.player playImmediatelyAtRate:self.playbackRate];
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
    BOOL hadLiveSource = self.terminalModeActive || self.webModeActive;
    [self syncRuntimePauseState];
    [self syncTerminalFrame];
    [self syncWebFrame];
    if (!self.terminalModeActive && !self.webModeActive &&
        (hadLiveSource || CACurrentMediaTime() - self.configurationCheckedAt >= 1)) {
        // A route can expire after the initial video setup was skipped. Keep
        // checking while idle so a helper starting after login can take over,
        // and a removed video or changed user wallpaper cannot leave a stale view.
        [self applyResolvedConfiguration:[self resolvedConfiguration] force:NO];
        [self syncRuntimePauseState];
        if (!self.runtimePaused) [self.player playImmediatelyAtRate:self.playbackRate];
    }
}

- (void)runtimeCommandDidChange:(NSNotification *)notification {
    // The command is written before the distributed notification is posted.
    // Hop to the screen-saver view's thread so the player is paused before
    // the next secure-surface refresh, without waiting for animateOneFrame.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self syncTerminalFrame];
        [self syncWebFrame];
        if (!self.terminalModeActive && !self.webModeActive) {
            [self applyResolvedConfiguration:[self resolvedConfiguration] force:NO];
        }
        [self syncRuntimePauseState];
        if (!self.runtimePaused && !self.terminalModeActive && !self.webModeActive) {
            [self.player playImmediatelyAtRate:self.playbackRate];
        }
    });
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self layoutVideoLayers];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.fallbackLayer != nil && !self.terminalModeActive && !self.webModeActive) {
        // Construction has no window yet; resolve this display's wallpaper
        // again once macOS attaches the saver to its secure surface.
        [self applyResolvedConfiguration:[self resolvedConfiguration] force:NO];
    }
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
    self.terminalLayer.frame = self.bounds;
    self.terminalSurfaceLayer.frame = self.bounds;
    self.terminalSurfaceLayer.contentsScale = self.window.backingScaleFactor ?: NSScreen.mainScreen.backingScaleFactor;
    self.webLayer.frame = self.bounds;
    [CATransaction commit];
}

- (NSURL *)terminalRuntimeURLForFile:(NSString *)name {
    // legacyScreenSaver may run with a container HOME. Terminal frames are
    // published by the user's helper, not into the extension's container.
    static NSString *home;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        struct passwd account;
        struct passwd *resolved = NULL;
        char buffer[16384];
        home = NSHomeDirectory();
        if (getpwuid_r(getuid(), &account, buffer, sizeof(buffer), &resolved) == 0 &&
            resolved != NULL && resolved->pw_dir != NULL) {
            home = [NSString stringWithUTF8String:resolved->pw_dir] ?: home;
        }
    });
    NSString *path = [home stringByAppendingPathComponent:
        [@"Library/Application Support/AuraFlow/terminal-wallpaper"
            stringByAppendingPathComponent:name]];
    return [NSURL fileURLWithPath:path];
}

- (BOOL)terminalAgentIsAlive {
    NSURL *auraRoot = [self applicationSupportURL];
    NSDictionary *config = [self JSONDictionaryAtURL:[auraRoot URLByAppendingPathComponent:@"config.json"]];
    if ([config[@"show_on_lock_screen"] isEqual:@NO]) return NO;
    NSDictionary *heartbeat = [self JSONDictionaryAtURL:
        [self terminalRuntimeURLForFile:@"lock-screen-heartbeat.json"]];
    NSNumber *pid = heartbeat[@"pid"];
    NSNumber *updatedAt = heartbeat[@"updatedAt"];
    if (![pid isKindOfClass:NSNumber.class] ||
        ![updatedAt isKindOfClass:NSNumber.class] || pid.intValue <= 0 ||
        updatedAt.doubleValue <= 0) {
        return NO;
    }
    // macOS can App Nap an idle/static TUI helper while the session is locked.
    // Its last frame is still valid as long as that helper process lives;
    // requiring a fresh timer tick made the Lock Screen turn blank after 6 s.
    return [self terminalProcessIsAlive:pid.intValue];
}

- (BOOL)terminalProcessIsAlive:(pid_t)pid {
    if (kill(pid, 0) != 0 && errno != EPERM) return NO;
    // A persisted heartbeat survives reboot, and its PID may now belong to an
    // unrelated process. Such a lease must never hide the user's wallpaper.
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    return proc_pidpath(pid, path, sizeof(path)) > 0 &&
        [[NSString stringWithUTF8String:path].lastPathComponent isEqualToString:@"AuraTerminalWallpaperAgent"];
}

// Web owns a separate route/lease. Never borrow terminal publications or the
// ordinary video fallback configuration for an imported HTML wallpaper.
- (void)syncWebFrame {
    NSURL *auraRoot = [self applicationSupportURL];
    NSURL *root = [auraRoot URLByAppendingPathComponent:@"wallpaper-engine/runtime" isDirectory:YES];
    NSDictionary *status = [self JSONDictionaryAtURL:[root URLByAppendingPathComponent:@"status.json"]];
    NSString *route = [NSString stringWithContentsOfURL:[root URLByAppendingPathComponent:@"route-active"] encoding:NSUTF8StringEncoding error:nil];
    NSNumber *pid = status[@"pid"];
    NSString *generation = status[@"generation"];
    NSDictionary *frames = status[@"frames"];
    char processPath[PROC_PIDPATHINFO_MAXSIZE] = {0};
    BOOL ownsProcess = [pid isKindOfClass:NSNumber.class] && pid.intValue > 0 &&
        proc_pidpath(pid.intValue, processPath, sizeof(processPath)) > 0 &&
        [[NSString stringWithUTF8String:processPath].lastPathComponent isEqualToString:@"AuraWebWallpaperAgent"];
    BOOL valid = [pid isKindOfClass:NSNumber.class] && pid.intValue > 0 &&
        ownsProcess &&
        [generation isKindOfClass:NSString.class] && [route isEqualToString:generation] &&
        [frames isKindOfClass:NSDictionary.class];
    NSString *display = [self.window.screen.deviceDescription[@"NSScreenNumber"] stringValue];
    NSString *path = valid ? ((display ? frames[display] : nil) ?: frames.allValues.firstObject) : nil;
    if (![path isKindOfClass:NSString.class] || ![path hasPrefix:[root.path stringByAppendingString:@"/"]]) {
        if (self.webModeActive) {
            self.webLayer.hidden = YES; self.webLayer.contents = nil;
            self.webModeActive = NO; self.webFrameRevision = nil;
            if (!self.runtimePaused && !self.terminalModeActive) [self.player playImmediatelyAtRate:self.playbackRate];
        }
        return;
    }
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if (![self.webFrameRevision hasPrefix:[generation stringByAppendingString:@":"]]) {
        self.webLayer.contents = nil; self.webLayer.hidden = YES;
        self.webModeActive = NO;
    }
    NSString *revision = [NSString stringWithFormat:@"%@:%@:%0.9f", generation, path, [attributes[NSFileModificationDate] timeIntervalSince1970]];
    if (![revision isEqualToString:self.webFrameRevision]) {
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
        if (source != NULL) {
            CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
            if (image != NULL) {
                self.webLayer.contents = (__bridge id)image; self.webFrameRevision = revision;
                CGImageRelease(image);
            }
            CFRelease(source);
        }
    }
    if (self.webLayer.contents != nil) {
        self.webModeActive = YES; self.webLayer.hidden = NO; [self.player pause];
    }
}

- (void)syncTerminalFrame {
    NSURL *frameURL = [self terminalRuntimeURLForFile:@"lock-screen-frame.png"];
    BOOL alive = [self terminalAgentIsAlive];
    BOOL readable = [[NSFileManager defaultManager] isReadableFileAtPath:frameURL.path];
    NSString *diagnostic = [NSString stringWithFormat:@"alive=%d readable=%d", alive, readable];
    if (![diagnostic isEqualToString:self.terminalDiagnosticState]) {
        self.terminalDiagnosticState = diagnostic;
        NSLog(@"AuraFlow terminal saver %@ path=%@", diagnostic, frameURL.path);
    }
    if (!alive) {
        self.terminalSurfaceLayer.hidden = YES;
        [self.terminalSurfaceLayer resetSource];
        if (self.terminalModeActive) {
            self.terminalModeActive = NO;
            self.terminalLayer.hidden = YES;
            self.terminalFrameRevision = nil;
            if (!self.runtimePaused && self.player != nil) {
                [self.player playImmediatelyAtRate:self.playbackRate];
            }
        }
        return;
    }

    NSDictionary *terminalConfig = [self JSONDictionaryAtURL:[self terminalRuntimeURLForFile:@"config.json"]];
    id render = terminalConfig[@"render"];
    id configuredMode = [render isKindOfClass:NSDictionary.class] ? render[@"scaleMode"] : nil;
    NSString *mode = [configuredMode isKindOfClass:NSString.class] ? configuredMode : @"fill";
    id fps = [render isKindOfClass:NSDictionary.class] ? render[@"maxFPS"] : nil;
    if ([fps isKindOfClass:NSNumber.class]) self.animationTimeInterval = 1.0 / MAX(1, MIN(60, [fps integerValue]));
    NSDictionary *heartbeat = [self JSONDictionaryAtURL:[self terminalRuntimeURLForFile:@"lock-screen-heartbeat.json"]];
    NSDictionary *surface = [self JSONDictionaryAtURL:[self terminalRuntimeURLForFile:@"shared-frame.json"]];
    if (self.sharedSurfacePresentationEnabled && self.terminalSurfaceLayer == nil &&
        [surface[@"surfaceID"] isKindOfClass:NSNumber.class] &&
        [surface[@"surfaceID"] unsignedIntValue] > 0 &&
        [surface[@"agentPID"] isKindOfClass:NSNumber.class] &&
        [surface[@"agentPID"] intValue] == [heartbeat[@"pid"] intValue]) {
        self.terminalSurfaceLayer = [AuraFlowTerminalSurfaceLayer layer];
        self.terminalSurfaceLayer.hidden = YES;
        [self.layer insertSublayer:self.terminalSurfaceLayer below:self.webLayer];
        [self layoutVideoLayers];
    }
    NSDictionary *background = [render isKindOfClass:NSDictionary.class] && [render[@"background"] isKindOfClass:NSDictionary.class]
        ? render[@"background"] : @{};
    id configuredOpacity = [render isKindOfClass:NSDictionary.class] ? render[@"backgroundOpacity"] : nil;
    double opacity = [configuredOpacity respondsToSelector:@selector(doubleValue)] ? [configuredOpacity doubleValue] : 1;
    NSColor *canvasColor = [NSColor colorWithRed:[background[@"red"] doubleValue] * opacity
        green:[background[@"green"] doubleValue] * opacity blue:[background[@"blue"] doubleValue] * opacity alpha:1];
    self.terminalLayer.backgroundColor = canvasColor.CGColor;
    self.terminalSurfaceLayer.backgroundColor = canvasColor.CGColor;
    if ([self.terminalSurfaceLayer presentDescriptor:surface ?: @{}
        expectedAgentPID:[heartbeat[@"pid"] intValue] scaleMode:mode]) {
        self.terminalModeActive = YES;
        self.terminalSurfaceLayer.hidden = NO;
        // Keep the decoded PNG underneath Metal. WindowServer may discard
        // drawables during lid sleep; switching to the retained raster must
        // not depend on another successful file read at that instant.
        self.terminalLayer.hidden = self.terminalLayer.contents == nil;
        [self.player pause];
        return;
    }
    self.terminalSurfaceLayer.hidden = YES;
    self.terminalLayer.contentsGravity = [mode isEqualToString:@"stretch"]
        ? kCAGravityResize : ([mode isEqualToString:@"fill"] ? kCAGravityResizeAspectFill : kCAGravityResizeAspect);
    if (!readable) return;

    // PNGs are replaced atomically several times per second. The generic
    // revision formatter rounds NSDate to whole seconds, which would make
    // animation appear frozen whenever consecutive frames have equal size.
    NSDictionary<NSFileAttributeKey, id> *frameAttributes =
        [[NSFileManager defaultManager] attributesOfItemAtPath:frameURL.path error:nil];
    NSString *revision = [NSString stringWithFormat:@"%@:%@:%0.9f",
        frameAttributes[NSFileSystemFileNumber],
        frameAttributes[NSFileSize],
        [frameAttributes[NSFileModificationDate] timeIntervalSince1970]];
    if (![revision isEqualToString:self.terminalFrameRevision]) {
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)frameURL, NULL);
        if (source != NULL) {
            CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
            if (image != NULL) {
                self.terminalLayer.contents = (__bridge id)image;
                self.terminalFrameRevision = revision;
                CGImageRelease(image);
            }
            CFRelease(source);
        }
    }
    if (self.terminalLayer.contents != nil) {
        if (!self.terminalModeActive) {
            NSLog(@"AuraFlow terminal saver displaying frame %@", self.terminalFrameRevision);
        }
        self.terminalModeActive = YES;
        self.terminalLayer.hidden = NO;
        [self.player pause];
    }
}

- (NSURL *)applicationSupportURL {
    // All routes must use the account's real home, including when the saver
    // host supplies a container HOME after login or automatic locking.
    return [[[self terminalRuntimeURLForFile:@"unused"] URLByDeletingLastPathComponent] URLByDeletingLastPathComponent];
}

- (nullable NSURL *)currentDesktopImageURL {
    NSScreen *screen = self.window.screen ?: NSScreen.mainScreen;
    return screen == nil ? nil : [NSWorkspace.sharedWorkspace desktopImageURLForScreen:screen];
}

- (NSURL *)wallpaperStoreURL {
    return [[[self applicationSupportURL] URLByDeletingLastPathComponent]
        URLByAppendingPathComponent:@"com.apple.wallpaper/Store/Index.plist"];
}

- (nullable NSURL *)extensionResourcesURLForProvider:(NSString *)provider {
    NSString *prefix = @"com.apple.wallpaper.choice.";
    if (![provider hasPrefix:prefix]) return nil;
    NSString *identifier = [@"com.apple.wallpaper.extension." stringByAppendingString:[provider substringFromIndex:prefix.length]];
    static NSDictionary<NSString *, NSURL *> *resourceURLs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *found = [NSMutableDictionary dictionary];
        NSURL *extensions = [NSURL fileURLWithPath:@"/System/Library/ExtensionKit/Extensions" isDirectory:YES];
        NSArray<NSURL *> *urls = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:extensions
            includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
        for (NSURL *url in urls) {
            if (![url.pathExtension isEqualToString:@"appex"]) continue;
            NSBundle *bundle = [NSBundle bundleWithURL:url];
            if ([bundle.bundleIdentifier hasPrefix:@"com.apple.wallpaper.extension."] && bundle.resourceURL != nil) {
                found[bundle.bundleIdentifier] = bundle.resourceURL;
            }
        }
        resourceURLs = found.copy;
    });
    return resourceURLs[identifier];
}

- (nullable NSURL *)nativeDesktopWallpaperURL {
    // NSWorkspace can report DefaultDesktop.heic for a selected procedural
    // wallpaper (for example Sequoia). Its provider's thumbnail represents
    // the actual user selection, without trying to run another native provider.
    NSDictionary *store = [NSDictionary dictionaryWithContentsOfURL:[self wallpaperStoreURL]];
    NSScreen *screen = self.window.screen ?: NSScreen.mainScreen;
    NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
    CFUUIDRef uuid = number == nil ? NULL : CGDisplayCreateUUIDFromDisplayID(number.unsignedIntValue);
    NSString *displayKey = uuid == NULL ? @"" : CFBridgingRelease(CFUUIDCreateString(NULL, uuid));
    if (uuid != NULL) CFRelease(uuid);
    NSDictionary *displays = store[@"Displays"];
    NSDictionary *route = [displays isKindOfClass:NSDictionary.class] ? displays[displayKey] : nil;
    route = route ?: store[@"AllSpacesAndDisplays"] ?: store[@"SystemDefault"];
    if (![route isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *mode = route[@"Desktop"] ?: route[@"Linked"];
    if (![mode isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *content = mode[@"Content"];
    if (![content isKindOfClass:NSDictionary.class]) return nil;
    NSArray *choices = content[@"Choices"];
    if (![choices isKindOfClass:NSArray.class]) return nil;
    for (NSDictionary *choice in choices) {
        if (![choice isKindOfClass:NSDictionary.class]) continue;
        NSString *provider = choice[@"Provider"];
        if (![provider isKindOfClass:NSString.class]) continue;
        NSURL *resources = [self extensionResourcesURLForProvider:provider];
        if (resources == nil) continue;
        NSURL *thumbnail = [self existingURLForConfiguredValue:@"thumbnail.heic" relativeTo:resources];
        if (thumbnail != nil) return thumbnail;
    }
    return nil;
}

- (nullable NSURL *)userWallpaperURL {
    NSURL *root = [self applicationSupportURL];
    NSMutableArray<NSURL *> *candidates = [NSMutableArray array];
    NSURL *current = [self currentDesktopImageURL];
    NSURL *native = current == nil || [current.lastPathComponent isEqualToString:@"DefaultDesktop.heic"] ||
        [current.pathExtension isEqualToString:@"madesktop"] ? [self nativeDesktopWallpaperURL] : nil;
    if (native != nil) [candidates addObject:native];
    if (current != nil) [candidates addObject:current];
    NSScreen *screen = self.window.screen ?: NSScreen.mainScreen;
    NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
    CGDirectDisplayID display = number.unsignedIntValue;
    NSString *displayKey = number == nil ? @"" : [NSString stringWithFormat:@"display-%u-%u-%u",
        CGDisplayVendorNumber(display), CGDisplayModelNumber(display), CGDisplaySerialNumber(display)];
    for (NSString *name in @[@"lock_screen_desktop_backup.json", @"wallpaper_backup_original.json", @"wallpaper_backup.json"]) {
        NSDictionary *backup = [self JSONDictionaryAtURL:[root URLByAppendingPathComponent:name]];
        NSURL *matching = [self existingURLForConfiguredValue:backup[displayKey] relativeTo:root];
        if (matching != nil) [candidates addObject:matching];
        for (NSString *key in [backup.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            NSURL *url = [self existingURLForConfiguredValue:backup[key] relativeTo:root];
            if (url != nil) [candidates addObject:url];
        }
    }
    [candidates addObject:[NSURL fileURLWithPath:@"/System/Library/CoreServices/DefaultDesktop.heic"]];
    NSString *managedFrame = [root URLByAppendingPathComponent:@"last_frame.png"].URLByStandardizingPath.path;
    NSString *terminalFrame = [self terminalRuntimeURLForFile:@"lock-screen-frame.png"].URLByStandardizingPath.path;
    for (NSURL *url in candidates) {
        if (!url.isFileURL || [url.URLByStandardizingPath.path isEqualToString:managedFrame] ||
            [url.URLByStandardizingPath.path isEqualToString:terminalFrame]) continue;
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
        if (source == NULL) continue;
        CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
        CFRelease(source);
        if (image != NULL) {
            CGImageRelease(image);
            return url;
        }
    }
    return nil;
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

    NSURL *applicationSupportURL = [self applicationSupportURL];
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
    if (runtimeVideoURL != nil && [runtimeConfig[@"blend_interpolation"] boolValue]) {
        NSDictionary *sources = [self JSONDictionaryAtURL:
            [applicationSupportURL URLByAppendingPathComponent:@"FrameBlendCache/sources.json"]];
        NSDictionary *entry = sources[runtimeVideoURL.path];
        if ([entry isKindOfClass:NSDictionary.class]) {
            NSDictionary *attributes = [[NSFileManager defaultManager]
                attributesOfItemAtPath:runtimeVideoURL.path error:nil];
            double modified = [attributes[NSFileModificationDate] timeIntervalSince1970];
            BOOL matches = [entry[@"size"] isEqual:attributes[NSFileSize]]
                && fabs([entry[@"modified"] doubleValue] - modified) < 0.000001;
            NSURL *prepared = matches ? [self existingURLForConfiguredValue:entry[@"path"]
                relativeTo:applicationSupportURL] : nil;
            if (prepared != nil) { runtimeVideoURL = prepared; }
        }
    }
    if (runtimeVideoURL != nil) {
        videoURL = runtimeVideoURL;
    }
    if ([runtimeConfig[@"scale_mode"] isKindOfClass:NSString.class]) {
        scaleMode = [self normalizedScaleMode:runtimeConfig[@"scale_mode"]];
    }

    double playbackSpeed = 1.0;
    if ([runtimeConfig[@"playback_speed"] isKindOfClass:NSNumber.class]) {
        playbackSpeed = [runtimeConfig[@"playback_speed"] doubleValue];
    }
    playbackSpeed = MAX(0.1, MIN(playbackSpeed, 4.0));

    NSURL *runtimeFallbackURL =
        [applicationSupportURL URLByAppendingPathComponent:@"last_frame.png"];
    // A cached Aura frame is only a fallback for its configured media. After
    // reboot with autostart disabled, an orphaned terminal/web saver must show
    // the user's wallpaper instead of an old video frame or an empty black layer.
    if (runtimeVideoURL != nil && [[NSFileManager defaultManager] isReadableFileAtPath:runtimeFallbackURL.path]) {
        fallbackURL = runtimeFallbackURL;
    }
    if ([runtimeConfig[@"show_on_lock_screen"] isEqual:@NO]) {
        videoURL = nil;
        fallbackURL = nil;
    }
    if (fallbackURL == nil) fallbackURL = [self userWallpaperURL];
    if (videoURL == nil) scaleMode = @"fill";

    return @{
        @"video_path" : videoURL.path ?: @"",
        @"fallback_path" : fallbackURL.path ?: @"",
        @"scale_mode" : scaleMode,
        @"playback_rate" : [NSString stringWithFormat:@"%.6f", playbackSpeed],
    };
}

- (BOOL)runtimePauseMarkerExists {
    NSString *applicationSupportPath = [self applicationSupportURL].path;
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
    if (!self.terminalModeActive && !self.webModeActive) {
        [self.player playImmediatelyAtRate:self.playbackRate];
    }
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

    NSString *path = URL.path;
    AuraFlowJSONMetadata before, after;
    if (!AuraFlowJSONMetadataAtURL(URL, &before)) {
        [self.jsonCache removeObjectForKey:path];
        return @{};
    }
    CFTimeInterval now = CACurrentMediaTime();
    AuraFlowJSONCacheEntry *cached = self.jsonCache[path];
    if (cached && now >= cached.createdAt && now - cached.createdAt < 60
        && AuraFlowJSONMetadataEqual(before, cached.metadata)) {
        return cached.dictionary;
    }
    NSData *data = [NSData dataWithContentsOfURL:URL
                                         options:NSDataReadingMappedIfSafe
                                           error:nil];
    if (data == nil) {
        [self.jsonCache removeObjectForKey:path];
        return @{};
    }

    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![object isKindOfClass:NSDictionary.class]) {
        [self.jsonCache removeObjectForKey:path];
        return @{};
    }
    // Atomic replacement, same-size edits and permission changes invalidate
    // immediately. Never retain a read that raced a writer; no per-frame logs.
    if (AuraFlowJSONMetadataAtURL(URL, &after) && AuraFlowJSONMetadataEqual(before, after)) {
        if (self.jsonCache.count >= 16) [self.jsonCache removeAllObjects];
        AuraFlowJSONCacheEntry *entry = [AuraFlowJSONCacheEntry new];
        entry.metadata = before;
        entry.createdAt = now;
        entry.dictionary = object;
        self.jsonCache[path] = entry;
    } else {
        [self.jsonCache removeObjectForKey:path];
    }
    return object;
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
    self.configurationCheckedAt = CACurrentMediaTime();
    float requestedPlaybackRate = [configuration[@"playback_rate"] floatValue];
    if (requestedPlaybackRate < 0.1 || requestedPlaybackRate > 4.0) {
        requestedPlaybackRate = 1.0;
    }
    BOOL playbackRateChanged = fabsf(self.playbackRate - requestedPlaybackRate)
        > 0.0001f;
    self.playbackRate = requestedPlaybackRate;
    NSString *signature =
        [NSString stringWithFormat:@"%@|%@|%@|%@|%@",
                                   configuration[@"video_path"],
                                   configuration[@"fallback_path"],
                                   configuration[@"scale_mode"],
                                   [self fileRevisionAtPath:configuration[@"video_path"]],
                                   [self fileRevisionAtPath:configuration[@"fallback_path"]]];
    if (!force && [signature isEqualToString:self.configurationSignature]) {
        if (playbackRateChanged && !self.runtimePaused && !self.terminalModeActive && !self.webModeActive && self.player != nil) {
            [self.player playImmediatelyAtRate:self.playbackRate];
        }
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
    NSImage *image = path.length == 0 ? nil : [[NSImage alloc] initWithContentsOfFile:path];
    CGImageRef CGImage = [image CGImageForProposedRect:NULL context:nil hints:nil];
    if (CGImage == NULL) {
        NSURL *userWallpaper = [self userWallpaperURL];
        image = userWallpaper == nil ? nil : [[NSImage alloc] initWithContentsOfURL:userWallpaper];
        CGImage = [image CGImageForProposedRect:NULL context:nil hints:nil];
    }
    self.fallbackLayer.contents = (__bridge id)CGImage;
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
        dispatch_async(dispatch_get_main_queue(), ^{
            if (observedLayer == self.playerLayer) {
                // Read on the presentation thread: a queued "ready" callback
                // can otherwise hide the still after wake made it unready.
                self.fallbackLayer.hidden = observedLayer.readyForDisplay;
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
