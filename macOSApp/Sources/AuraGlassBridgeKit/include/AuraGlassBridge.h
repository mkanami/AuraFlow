#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, AuraGlassBridgeStyle) {
    AuraGlassBridgeStyleRegular = 0,
    AuraGlassBridgeStyleClear = 1,
} NS_SWIFT_NAME(AuraGlassBridgeView.Style);

@interface AuraGlassBridgeView : NSView

@property(nonatomic) CGFloat cornerRadius;
@property(nonatomic) AuraGlassBridgeStyle style;
@property(nonatomic, copy, nullable) NSColor *tintColor;
@property(nonatomic) CGFloat containerSpacing;

@end

NS_ASSUME_NONNULL_END
