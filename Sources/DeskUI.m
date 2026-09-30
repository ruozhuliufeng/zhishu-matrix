#import "DeskUI.h"

NSTextField *DeskLabel(NSString *text, CGFloat size, NSFontWeight weight) {
    NSTextField *label = [NSTextField labelWithString:text ?: @""];
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

NSTextField *DeskCaption(NSString *text) {
    NSTextField *label = DeskLabel(text, 11, NSFontWeightMedium);
    label.textColor = NSColor.secondaryLabelColor;
    return label;
}

NSButton *DeskIconButton(NSString *symbol, NSString *tooltip, id target, SEL action) {
    NSButton *button = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tooltip]
        target:target action:action];
    button.bordered = NO;
    button.toolTip = tooltip;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.widthAnchor constraintEqualToConstant:28].active = YES;
    [button.heightAnchor constraintEqualToConstant:28].active = YES;
    return button;
}

NSButton *DeskButton(NSString *title, NSString *symbol, id target, SEL action) {
    NSButton *button = [NSButton buttonWithTitle:title target:target action:action];
    if (symbol) {
        button.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
        button.imagePosition = NSImageLeading;
    }
    button.translatesAutoresizingMaskIntoConstraints = NO;
    return button;
}

NSBox *DeskSeparator(void) {
    NSBox *box = [NSBox new];
    box.boxType = NSBoxSeparator;
    box.translatesAutoresizingMaskIntoConstraints = NO;
    return box;
}

NSColor *DeskColorForSeed(NSString *seed) {
    static NSArray<NSColor *> *palette;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        palette = @[
            [NSColor colorWithSRGBRed:0.31 green:0.49 blue:0.98 alpha:1],
            [NSColor colorWithSRGBRed:0.55 green:0.36 blue:0.93 alpha:1],
            [NSColor colorWithSRGBRed:0.90 green:0.30 blue:0.58 alpha:1],
            [NSColor colorWithSRGBRed:0.94 green:0.45 blue:0.13 alpha:1],
            [NSColor colorWithSRGBRed:0.07 green:0.66 blue:0.60 alpha:1],
            [NSColor colorWithSRGBRed:0.16 green:0.62 blue:0.34 alpha:1],
            [NSColor colorWithSRGBRed:0.39 green:0.40 blue:0.92 alpha:1],
            [NSColor colorWithSRGBRed:0.05 green:0.54 blue:0.82 alpha:1],
            [NSColor colorWithSRGBRed:0.85 green:0.18 blue:0.30 alpha:1],
            [NSColor colorWithSRGBRed:0.80 green:0.50 blue:0.08 alpha:1],
        ];
    });
    uint32_t hash = 2166136261u;
    for (NSUInteger index = 0; index < seed.length; index++) {
        hash ^= [seed characterAtIndex:index];
        hash *= 16777619u;
    }
    return palette[hash % palette.count];
}

NSColor *DeskColorForPlan(NSString *plan) {
    NSDictionary<NSString *, NSColor *> *colors = @{
        @"Go": NSColor.systemTealColor,
        @"Plus": NSColor.systemGreenColor,
        @"Pro": NSColor.systemPurpleColor,
        @"Business": NSColor.systemBlueColor,
        @"Enterprise": NSColor.systemIndigoColor,
        @"Edu": NSColor.systemOrangeColor
    };
    return (plan ? colors[plan] : nil) ?: NSColor.systemGrayColor;
}

NSColor *DeskColorForExpiry(AccountExpiryState state) {
    switch (state) {
        case AccountExpiryStateExpired: return NSColor.systemRedColor;
        case AccountExpiryStateExpiringSoon: return NSColor.systemOrangeColor;
        case AccountExpiryStateActive: return NSColor.systemBlueColor;
        case AccountExpiryStateUnknown: return NSColor.systemGrayColor;
    }
    return NSColor.systemGrayColor;
}

NSString *DeskRelativeTime(NSDate *date) {
    if (!date) return @"—";
    NSTimeInterval age = -date.timeIntervalSinceNow;
    if (age < 60) return @"刚刚";
    if (age < 7 * 24 * 3600) {
        static NSRelativeDateTimeFormatter *formatter;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            formatter = [NSRelativeDateTimeFormatter new];
            formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
            formatter.unitsStyle = NSRelativeDateTimeFormatterUnitsStyleFull;
        });
        return [formatter localizedStringForDate:date relativeToDate:NSDate.date];
    }
    return AccountDayString(date);
}

NSString *DeskDateTimeString(NSDate *date) {
    if (!date) return @"—";
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm";
    });
    return [formatter stringFromDate:date];
}

@implementation DeskFlippedView
- (BOOL)isFlipped { return YES; }
@end

@implementation DeskFillView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) _fillColor = NSColor.windowBackgroundColor;
    return self;
}
- (void)setFillColor:(NSColor *)fillColor { _fillColor = fillColor; [self setNeedsDisplay:YES]; }
- (void)drawRect:(NSRect)dirtyRect {
    [self.fillColor setFill];
    NSRectFill(dirtyRect);
}
@end

@implementation DeskAvatarView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _name = @"";
        _seed = @"";
    }
    return self;
}
- (void)setName:(NSString *)name { _name = [name ?: @"" copy]; [self setNeedsDisplay:YES]; }
- (void)setSeed:(NSString *)seed { _seed = [seed ?: @"" copy]; [self setNeedsDisplay:YES]; }
- (void)setStatusColor:(NSColor *)statusColor { _statusColor = statusColor; [self setNeedsDisplay:YES]; }

- (void)drawRect:(NSRect)dirtyRect {
    CGFloat diameter = MIN(NSWidth(self.bounds), NSHeight(self.bounds));
    NSRect circle = NSMakeRect(NSMidX(self.bounds) - diameter / 2, NSMidY(self.bounds) - diameter / 2, diameter, diameter);
    NSColor *base = DeskColorForSeed(self.seed.length ? self.seed : self.name);
    NSColor *light = [base blendedColorWithFraction:0.3 ofColor:NSColor.whiteColor] ?: base;
    NSGradient *gradient = [[NSGradient alloc] initWithStartingColor:light endingColor:base];
    [gradient drawInBezierPath:[NSBezierPath bezierPathWithOvalInRect:circle] angle:-90];

    NSString *trimmed = [self.name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *initial = trimmed.length
        ? [trimmed substringWithRange:[trimmed rangeOfComposedCharacterSequenceAtIndex:0]].localizedUppercaseString : @"?";
    NSDictionary *attributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:round(diameter * 0.42) weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: NSColor.whiteColor
    };
    NSSize size = [initial sizeWithAttributes:attributes];
    [initial drawAtPoint:NSMakePoint(NSMidX(circle) - size.width / 2, NSMidY(circle) - size.height / 2) withAttributes:attributes];

    if (self.statusColor) {
        CGFloat dot = MAX(8, round(diameter * 0.32));
        NSRect ring = NSMakeRect(NSMaxX(circle) - dot, NSMinY(circle), dot, dot);
        [NSColor.windowBackgroundColor setFill];
        [[NSBezierPath bezierPathWithOvalInRect:ring] fill];
        [self.statusColor setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(ring, 1.5, 1.5)] fill];
    }
}
@end

static NSFont *PillFont(void) { return [NSFont systemFontOfSize:10.5 weight:NSFontWeightSemibold]; }

@implementation DeskPillView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _text = @"";
        _tintColor = NSColor.systemGrayColor;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        for (NSNumber *orientation in @[@(NSLayoutConstraintOrientationHorizontal), @(NSLayoutConstraintOrientationVertical)]) {
            [self setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:orientation.integerValue];
            [self setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:orientation.integerValue];
        }
    }
    return self;
}
- (void)setText:(NSString *)text {
    _text = [text ?: @"" copy];
    [self invalidateIntrinsicContentSize];
    [self setNeedsDisplay:YES];
}
- (void)setTintColor:(NSColor *)tintColor { _tintColor = tintColor ?: NSColor.systemGrayColor; [self setNeedsDisplay:YES]; }
- (void)setBackgroundStyle:(NSBackgroundStyle)backgroundStyle { _backgroundStyle = backgroundStyle; [self setNeedsDisplay:YES]; }
- (NSSize)intrinsicContentSize {
    if (!self.text.length) return NSMakeSize(0, 18);
    NSSize size = [self.text sizeWithAttributes:@{NSFontAttributeName: PillFont()}];
    return NSMakeSize(ceil(size.width) + 14, 18);
}
- (void)drawRect:(NSRect)dirtyRect {
    if (!self.text.length) return;
    BOOL emphasized = self.backgroundStyle == NSBackgroundStyleEmphasized;
    NSColor *tint = emphasized ? NSColor.whiteColor : self.tintColor;
    CGFloat radius = NSHeight(self.bounds) / 2;
    [[tint colorWithAlphaComponent:emphasized ? 0.25 : 0.16] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:radius yRadius:radius] fill];
    NSDictionary *attributes = @{NSFontAttributeName: PillFont(), NSForegroundColorAttributeName: tint};
    NSSize size = [self.text sizeWithAttributes:attributes];
    [self.text drawAtPoint:NSMakePoint(round((NSWidth(self.bounds) - size.width) / 2),
        round((NSHeight(self.bounds) - size.height) / 2)) withAttributes:attributes];
}
@end

@implementation DeskProgressLine {
    double _progress;
}
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.alphaValue = 0;
    }
    return self;
}
- (void)setProgress:(double)progress loading:(BOOL)loading {
    _progress = loading ? MAX(0.08, MIN(progress, 1)) : 1;
    [self setNeedsDisplay:YES];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = loading ? 0.1 : 0.45;
        self.animator.alphaValue = loading ? 1 : 0;
    }];
}
- (void)drawRect:(NSRect)dirtyRect {
    NSRect bar = self.bounds;
    bar.size.width = round(NSWidth(self.bounds) * _progress);
    [NSColor.controlAccentColor setFill];
    NSRectFill(bar);
}
@end

@implementation DeskTableView
- (void)keyDown:(NSEvent *)event {
    unichar key = event.charactersIgnoringModifiers.length ? [event.charactersIgnoringModifiers characterAtIndex:0] : 0;
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL plain = !(flags & (NSEventModifierFlagOption | NSEventModifierFlagControl | NSEventModifierFlagShift));
    if (plain && (key == NSDeleteCharacter || key == NSDeleteFunctionKey) && self.deleteHandler) {
        self.deleteHandler();
        return;
    }
    if (plain && (key == NSCarriageReturnCharacter || key == NSEnterCharacter) && self.returnHandler) {
        self.returnHandler();
        return;
    }
    [super keyDown:event];
}
@end
