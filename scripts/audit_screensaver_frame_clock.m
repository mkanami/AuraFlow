// Isolated native-timer regression and performance probe. No window is ordered,
// no system saver is started, and all runtime writes go to a temporary fixture.
// Compile: xcrun clang -O2 -fobjc-arc -mmacosx-version-min=13.0 \
//   -framework AppKit -framework ScreenSaver -framework QuartzCore \
//   scripts/audit_screensaver_frame_clock.m -o .build/audit_screensaver_frame_clock
// Run: .build/audit_screensaver_frame_clock PATH_TO_SAVER FIXTURE_OR_APP_SUPPORT
#import <AppKit/AppKit.h>
#import <ScreenSaver/ScreenSaver.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <sys/resource.h>

static NSURL *fixture;
static BOOL lowPower;
static NSURL *supportRoot(id object, SEL selector) { return fixture; }
static BOOL powerMode(id object, SEL selector) { return lowPower; }
static void spin(double seconds) {
    double deadline = CACurrentMediaTime() + seconds;
    while (CACurrentMediaTime() < deadline) @autoreleasepool {
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
}
static double cpu(void) {
    struct rusage r; getrusage(RUSAGE_SELF, &r);
    return r.ru_utime.tv_sec + r.ru_utime.tv_usec / 1e6 + r.ru_stime.tv_sec + r.ru_stime.tv_usec / 1e6;
}
static NSDictionary *status(ScreenSaverView *view) { return [[view valueForKey:@"effects"] valueForKey:@"diagnostics"]; }
static unsigned long long frames(ScreenSaverView *view) { return [status(view)[@"renderedFrames"] unsignedLongLongValue]; }
static BOOL measure(ScreenSaverView *view, double target) {
    spin(1);
    unsigned long long initial = frames(view), native = [[view valueForKey:@"animationTicks"] unsignedLongLongValue];
    unsigned long long glass = [status(view)[@"glassRenderedFrames"] unsignedLongLongValue];
    double start = CACurrentMediaTime(), cpuStart = cpu();
    spin(3);
    double elapsed = CACurrentMediaTime() - start;
    unsigned long long count = frames(view) - initial;
    unsigned long long ticks = [[view valueForKey:@"animationTicks"] unsignedLongLongValue] - native;
    unsigned long long glassCount = [status(view)[@"glassRenderedFrames"] unsignedLongLongValue] - glass;
    double fps = count / elapsed;
    printf("target=%.0f fps=%.2f glass_fps=%.2f native_ticks=%llu effect_frames=%llu cpu_percent=%.2f\n",
        target, fps, glassCount / elapsed, ticks, count, 100 * (cpu() - cpuStart) / elapsed);
    return fps >= target * 0.85 && fps <= target * 1.1 && llabs((long long)count - (long long)ticks) <= 1;
}

int main(int argc, const char *argv[]) { @autoreleasepool {
    if (argc != 3) { fprintf(stderr, "usage: audit_screensaver_frame_clock SAVER FIXTURE_OR_APP_SUPPORT\n"); return 2; }
    [NSApplication sharedApplication];
    NSFileManager *fm = NSFileManager.defaultManager;
    fixture = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    if (![fm createDirectoryAtURL:fixture withIntermediateDirectories:YES attributes:nil error:nil]) return 3;
    NSURL *input = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]];
    // Config paths continue to reference the original media read-only. Never
    // copy or alter native wallpaper descriptors, registration or user media.
    for (NSString *name in @[@"config.json", @"wallpaper-effects.json", @"last_frame.png"])
        [fm copyItemAtURL:[input URLByAppendingPathComponent:name] toURL:[fixture URLByAppendingPathComponent:name] error:nil];
    if (![fm fileExistsAtPath:[fixture URLByAppendingPathComponent:@"wallpaper-effects.json"].path]) return 4;
    NSBundle *bundle = [NSBundle bundleWithPath:[NSString stringWithUTF8String:argv[1]]];
    NSError *error = nil;
    if (![bundle loadAndReturnError:&error]) { NSLog(@"%@", error); return 5; }
    Class saverClass = bundle.principalClass;
    method_setImplementation(class_getInstanceMethod(saverClass, NSSelectorFromString(@"applicationSupportURL")), (IMP)supportRoot);
    // Vary only this probe's policy sample, never the machine's power setting.
    method_setImplementation(class_getInstanceMethod(object_getClass(NSProcessInfo.processInfo), @selector(isLowPowerModeEnabled)), (IMP)powerMode);
    NSSize size = NSScreen.mainScreen.frame.size;
    if (size.width <= 0 || size.height <= 0) size = NSMakeSize(1280, 720);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:(NSRect){NSZeroPoint, size}
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;
    ScreenSaverView *view = [[saverClass alloc] initWithFrame:(NSRect){NSZeroPoint, size} isPreview:YES];
    window.contentView = view;
    [view startAnimation];
    BOOL normal = measure(view, 60);
    lowPower = YES;
    BOOL saving = measure(view, 30);
    NSURL *pause = [fixture URLByAppendingPathComponent:@"wallpaper_daemon.paused"];
    [NSData.data writeToURL:pause atomically:YES];
    spin(0.7);
    unsigned long long paused = frames(view);
    spin(0.3);
    BOOL stops = frames(view) == paused;
    [fm removeItemAtURL:pause error:nil];
    spin(0.8);
    BOOL resumes = frames(view) > paused;
    [view stopAnimation];
    unsigned long long stopped = frames(view);
    spin(0.1);
    BOOL noStrayFrames = frames(view) == stopped;
    window.contentView = nil;
    [fm removeItemAtURL:fixture error:nil];
    printf("normal=%d power_saving=%d pause=%d resume=%d stopped=%d\n", normal, saving, stops, resumes, noStrayFrames);
    return normal && saving && stops && resumes && noStrayFrames ? 0 : 1;
} }
