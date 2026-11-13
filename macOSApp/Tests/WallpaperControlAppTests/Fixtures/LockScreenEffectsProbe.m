#import <AppKit/AppKit.h>
#import <ScreenSaver/ScreenSaver.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Load the actual packaged saver in a separate process. Every source points
// into a temporary fixture. No test window is ordered and no OS saver/lock
// API is called; startAnimation only starts this isolated ScreenSaverView.
static NSURL *fixtureRoot;
static NSURL *fixtureImage;
static id supportURL(id self, SEL cmd) { return fixtureRoot; }
static id terminalURL(id self, SEL cmd, NSString *name) {
    return [[fixtureRoot URLByAppendingPathComponent:@"terminal-wallpaper"] URLByAppendingPathComponent:name];
}
static id desktopURL(id self, SEL cmd) { return fixtureImage; }
static void writeJSON(NSDictionary *value, NSURL *url) {
    [[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:nil] writeToURL:url atomically:YES];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3) return 2;
        [NSApplication sharedApplication];
        fixtureRoot = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]];
        [[NSFileManager defaultManager] createDirectoryAtURL:fixtureRoot withIntermediateDirectories:YES attributes:nil error:nil];
        fixtureImage = [fixtureRoot URLByAppendingPathComponent:@"photo.png"];
        NSBitmapImageRep *image = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
            pixelsWide:640 pixelsHigh:400 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
            isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:640*4 bitsPerPixel:32];
        for (int y=0;y<400;y++) for (int x=0;x<640;x++) {
            unsigned char *pixel = image.bitmapData+y*image.bytesPerRow+x*4;
            pixel[0]=(x%40)<4 ? 230 : 15; pixel[1]=(y%40)<4 ? 200 : 30;
            pixel[2]=120; pixel[3]=255;
        }
        NSData *png = [image representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        [png writeToURL:fixtureImage atomically:YES];
        [png writeToURL:[fixtureRoot URLByAppendingPathComponent:@"last_frame.png"] atomically:YES];
        writeJSON(@{@"video_path":fixtureImage.path, @"show_on_lock_screen":@YES, @"playback_speed":@1},
            [fixtureRoot URLByAppendingPathComponent:@"config.json"]);
        writeJSON(@{@"enabled":@YES, @"rainEnabled":@YES, @"rainAmount":@0.8, @"rainColor":@"red",
            @"glassRainEnabled":@YES, @"glassRainIntensity":@0.7, @"bloomEnabled":@YES, @"flareEnabled":@YES,
            @"reflectionEnabled":@YES, @"sparkleEnabled":@YES, @"reactsToCursor":@NO},
            [fixtureRoot URLByAppendingPathComponent:@"wallpaper-effects.json"]);
        NSBundle *bundle = [NSBundle bundleWithPath:[NSString stringWithUTF8String:argv[1]]];
        NSError *error = nil;
        if (![bundle loadAndReturnError:&error]) { NSLog(@"load: %@", error); return 3; }
        Class saverClass = NSClassFromString(@"AuraFlowLockScreen");
        if (!saverClass || !NSClassFromString(@"AuraFlowSaverEffects")) return 4;
        Class child = objc_allocateClassPair(saverClass, "AuraEffectsFixtureSaver", 0);
        class_addMethod(child, NSSelectorFromString(@"applicationSupportURL"), (IMP)supportURL, "@@:");
        class_addMethod(child, NSSelectorFromString(@"terminalRuntimeURLForFile:"), (IMP)terminalURL, "@@:@");
        class_addMethod(child, NSSelectorFromString(@"currentDesktopImageURL"), (IMP)desktopURL, "@@:");
        objc_registerClassPair(child);
        ScreenSaverView *saver = [[child alloc] initWithFrame:NSMakeRect(0,0,640,400) isPreview:YES];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:saver.frame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        window.releasedWhenClosed = NO;
        window.contentView = saver;
        [saver startAnimation];
        id effects = [saver valueForKey:@"effects"];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:8];
        NSDictionary *status;
        do {
            [saver animateOneFrame];
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.035]];
            status = [effects valueForKey:@"diagnostics"];
        } while ([deadline timeIntervalSinceNow]>0 && [status[@"glassRenderedFrames"] integerValue]<3);
        writeJSON(status ?: @{}, [fixtureRoot URLByAppendingPathComponent:@"diagnostics.json"]);
        NSLog(@"Packaged effects: %@", status);
        if (![status[@"active"] boolValue] || [status[@"renderedFrames"] integerValue]<3
            || [status[@"glassRenderedFrames"] integerValue]<2 || [status[@"glassAirRainCount"] integerValue]<1
            || [status[@"glassDropCount"] integerValue]<1 || ![status[@"surface"] isEqual:@"lockScreen"]) return 5;
        if (window.visible) return 6;
        [saver stopAnimation];
        status = [effects valueForKey:@"diagnostics"];
        if ([status[@"active"] boolValue] || [status[@"framesPerSecond"] doubleValue]!=0) return 7;
        puts("Packaged Lock Screen effects render air rain and refracting glass; Stop releases the clock; no window ordered.");
        return 0;
    }
}
