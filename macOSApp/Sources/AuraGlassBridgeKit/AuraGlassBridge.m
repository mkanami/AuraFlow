#import "AuraGlassBridge.h"

#if __has_include(<AppKit/NSGlassEffectView.h>)
#import <AppKit/NSGlassEffectView.h>
#endif

@interface AuraGlassBridgeView ()

@property(nonatomic, strong) NSView *hostView;
@property(nonatomic, strong) NSVisualEffectView *fallbackView;
@property(nonatomic) NSInteger revealGeneration;
@property(nonatomic, strong) NSMutableArray<id> *windowObservers;

#if __has_include(<AppKit/NSGlassEffectView.h>)
@property(nonatomic, strong, nullable) NSGlassEffectView *glassEffectView API_AVAILABLE(macos(26.0));
@property(nonatomic, strong, nullable) NSView *glassContentView API_AVAILABLE(macos(26.0));
- (void)updateWindowObservers;
- (void)updateInactiveFallbackVisibility API_AVAILABLE(macos(26.0));
- (void)armNativeGlassReveal API_AVAILABLE(macos(26.0));
#endif

@end

@implementation AuraGlassBridgeView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _cornerRadius = 14.0;
        _style = AuraGlassBridgeStyleRegular;
        _containerSpacing = 0.0;
        _windowObservers = [NSMutableArray array];
        [self commonInit];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        _cornerRadius = 14.0;
        _style = AuraGlassBridgeStyleRegular;
        _containerSpacing = 0.0;
        _windowObservers = [NSMutableArray array];
        [self commonInit];
    }
    return self;
}

- (BOOL)isOpaque {
    return NO;
}

- (void)setCornerRadius:(CGFloat)cornerRadius {
    if (fabs(_cornerRadius - cornerRadius) < 0.5) {
        return;
    }
    _cornerRadius = cornerRadius;
    [self updateAppearance];
}

- (void)setStyle:(AuraGlassBridgeStyle)style {
    if (_style == style) {
        return;
    }
    _style = style;
    [self updateAppearance];
}

- (void)setTintColor:(NSColor *)tintColor {
    if ((_tintColor == nil && tintColor == nil) || [_tintColor isEqual:tintColor]) {
        return;
    }
    _tintColor = [tintColor copy];
    [self updateAppearance];
}

- (void)setContainerSpacing:(CGFloat)containerSpacing {
    if (fabs(_containerSpacing - containerSpacing) < 0.5) {
        return;
    }
    _containerSpacing = containerSpacing;
}

- (void)layout {
    [super layout];
    self.hostView.frame = self.bounds;
#if __has_include(<AppKit/NSGlassEffectView.h>)
    if (@available(macOS 26.0, *)) {
        self.glassEffectView.frame = self.bounds;
        self.glassContentView.frame = self.bounds;
    }
#endif
    self.fallbackView.frame = self.bounds;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
#if __has_include(<AppKit/NSGlassEffectView.h>)
    [self updateWindowObservers];
#endif
    [self updateAppearance];
#if __has_include(<AppKit/NSGlassEffectView.h>)
    if (@available(macOS 26.0, *)) {
        [self armNativeGlassReveal];
    }
#endif
}

- (void)commonInit {
    self.wantsLayer = YES;
    self.layer.backgroundColor = NSColor.clearColor.CGColor;

    self.fallbackView = [[NSVisualEffectView alloc] initWithFrame:self.bounds];
    self.fallbackView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.fallbackView.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    self.fallbackView.state = NSVisualEffectStateActive;
    self.fallbackView.material = NSVisualEffectMaterialUnderWindowBackground;
    self.fallbackView.emphasized = NO;

#if __has_include(<AppKit/NSGlassEffectView.h>)
    if (@available(macOS 26.0, *)) {
        self.glassEffectView = [[NSGlassEffectView alloc] initWithFrame:self.bounds];
        self.glassEffectView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        self.glassEffectView.contentView = [[NSView alloc] initWithFrame:self.bounds];
        self.glassEffectView.contentView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        self.glassContentView = self.glassEffectView.contentView;

        [self addSubview:self.fallbackView];
        self.glassEffectView.alphaValue = 0.0;

        self.hostView = self.glassEffectView;
        [self addSubview:self.glassEffectView];
        [self updateAppearance];
        [self armNativeGlassReveal];
        return;
    }
#endif

    self.hostView = self.fallbackView;
    [self addSubview:self.fallbackView];
    [self updateAppearance];
}

- (void)updateAppearance {
#if __has_include(<AppKit/NSGlassEffectView.h>)
    if (@available(macOS 26.0, *)) {
        self.glassEffectView.cornerRadius = self.cornerRadius;
        self.glassEffectView.style = self.style == AuraGlassBridgeStyleClear ? NSGlassEffectViewStyleClear : NSGlassEffectViewStyleRegular;
        self.glassEffectView.tintColor = self.tintColor;
        [self updateInactiveFallbackVisibility];
        return;
    }
#endif

    self.fallbackView.material = NSVisualEffectMaterialUnderWindowBackground;
    self.fallbackView.state = NSVisualEffectStateActive;
    self.fallbackView.emphasized = NO;
    self.fallbackView.wantsLayer = YES;
    self.fallbackView.layer.cornerRadius = self.cornerRadius;
    self.fallbackView.layer.masksToBounds = YES;
}

#if __has_include(<AppKit/NSGlassEffectView.h>)
- (void)updateWindowObservers {
    for (id observer in self.windowObservers) {
        [[NSNotificationCenter defaultCenter] removeObserver:observer];
    }
    [self.windowObservers removeAllObjects];

    NSWindow *window = self.window;
    if (window == nil) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    NSArray<NSNotificationName> *names = @[
        NSWindowDidBecomeKeyNotification,
        NSWindowDidResignKeyNotification,
        NSApplicationDidBecomeActiveNotification,
        NSApplicationDidResignActiveNotification
    ];

    for (NSNotificationName name in names) {
        id observer = [[NSNotificationCenter defaultCenter] addObserverForName:name object:(name == NSApplicationDidBecomeActiveNotification || name == NSApplicationDidResignActiveNotification) ? nil : window queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            if (@available(macOS 26.0, *)) {
                [weakSelf updateInactiveFallbackVisibility];
            }
        }];
        if (observer != nil) {
            [self.windowObservers addObject:observer];
        }
    }
}

- (void)updateInactiveFallbackVisibility API_AVAILABLE(macos(26.0)) {
    if (self.glassEffectView == nil) {
        return;
    }

    BOOL windowActive = self.window != nil && NSApp.active && (self.window.isMainWindow || self.window.isKeyWindow);
    if (self.glassEffectView.alphaValue < 0.99) {
        self.fallbackView.hidden = NO;
        self.fallbackView.alphaValue = 1.0;
        return;
    }

    self.fallbackView.hidden = NO;
    self.fallbackView.alphaValue = windowActive ? 0.0 : 1.0;
}

- (void)armNativeGlassReveal API_AVAILABLE(macos(26.0)) {
    self.revealGeneration += 1;
    NSInteger generation = self.revealGeneration;

    if (self.window == nil) {
        self.fallbackView.hidden = NO;
        self.fallbackView.alphaValue = 1.0;
        self.glassEffectView.alphaValue = 0.0;
        return;
    }

    self.fallbackView.hidden = NO;
    self.fallbackView.alphaValue = 1.0;
    self.glassEffectView.alphaValue = 0.0;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != self.revealGeneration || self.window == nil) {
            return;
        }

        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.05;
            self.glassEffectView.animator.alphaValue = 1.0;
        } completionHandler:^{
            if (generation != self.revealGeneration) {
                return;
            }
            [self updateInactiveFallbackVisibility];
        }];
    });
}
#endif

- (void)dealloc {
    for (id observer in self.windowObservers) {
        [[NSNotificationCenter defaultCenter] removeObserver:observer];
    }
}

@end
