#import <Cocoa/Cocoa.h>
#import "Account.h"

NS_ASSUME_NONNULL_BEGIN

NSTextField *DeskLabel(NSString *text, CGFloat size, NSFontWeight weight);
NSTextField *DeskCaption(NSString *text);
NSButton *DeskIconButton(NSString *symbol, NSString *tooltip, id _Nullable target, SEL action);
NSButton *DeskButton(NSString *title, NSString *_Nullable symbol, id _Nullable target, SEL action);
NSBox *DeskSeparator(void);

NSColor *DeskColorForSeed(NSString *seed);
NSColor *DeskColorForPlan(NSString *_Nullable plan);
NSColor *DeskColorForExpiry(AccountExpiryState state);
/// Green with plenty left, orange under half, red under a fifth.
NSColor *DeskColorForQuota(double remainingPercent);
NSColor *DeskColorForTag(NSString *tag);
/// "3 小时后重置", "6 天后重置".
NSString *DeskResetDescription(NSDate *_Nullable resetAt);
NSString *DeskRelativeTime(NSDate *_Nullable date);
NSString *DeskDateTimeString(NSDate *_Nullable date);

@interface DeskFlippedView : NSView
@end

/// Plain view that paints a (dynamic) background color.
@interface DeskFillView : NSView
@property (nonatomic, strong) NSColor *fillColor;
@end

/// Circular initial avatar with a stable color per account and an optional status dot.
@interface DeskAvatarView : NSView
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *seed;
@property (nonatomic, strong, nullable) NSColor *statusColor;
@end

/// Rounded tinted capsule used for plan, expiry and login badges.
@interface DeskPillView : NSView
@property (nonatomic, copy) NSString *text;
@property (nonatomic, strong) NSColor *tintColor;
@property (nonatomic) NSBackgroundStyle backgroundStyle;
@end

/// Rounded usage bar; draws an empty track when the value is unknown.
@interface DeskQuotaBar : NSView
@property (nonatomic, strong, nullable) NSNumber *remainingPercent;
@end

/// A row of tag capsules that truncates with "+N".
@interface DeskTagsView : NSView
@property (nonatomic, copy) NSArray<NSString *> *tags;
@property (nonatomic) NSBackgroundStyle backgroundStyle;
@end

/// Thin page-loading indicator.
@interface DeskProgressLine : NSView
- (void)setProgress:(double)progress loading:(BOOL)loading;
@end

/// Table view that forwards Delete and Return to blocks.
@interface DeskTableView : NSTableView
@property (nonatomic, copy, nullable) void (^deleteHandler)(void);
@property (nonatomic, copy, nullable) void (^returnHandler)(void);
@end

NS_ASSUME_NONNULL_END
