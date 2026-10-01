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
    NSString *family = AccountPlanFamily(plan);
    return (family ? colors[family] : nil) ?: NSColor.systemGrayColor;
}

NSColor *DeskColorForExpiry(AccountExpiryState state) {
    switch (state) {
        case AccountExpiryStateExpired: return NSColor.systemRedColor;
        case AccountExpiryStateExpiringSoon: return NSColor.systemOrangeColor;
        case AccountExpiryStateActive: return NSColor.systemGreenColor;
        case AccountExpiryStateRenewing: return NSColor.systemBlueColor;
        case AccountExpiryStateUnknown: return NSColor.systemGrayColor;
    }
    return NSColor.systemGrayColor;
}

NSColor *DeskColorForQuota(double remainingPercent) {
    if (remainingPercent < 20) return NSColor.systemRedColor;
    if (remainingPercent < 50) return NSColor.systemOrangeColor;
    return NSColor.systemGreenColor;
}

NSColor *DeskColorForTone(AccountStatusTone tone) {
    switch (tone) {
        case AccountStatusToneCritical: return NSColor.systemRedColor;
        case AccountStatusToneWarning: return NSColor.systemOrangeColor;
        case AccountStatusToneGood: return NSColor.systemGreenColor;
        case AccountStatusToneNeutral: return NSColor.systemGrayColor;
    }
    return NSColor.systemGrayColor;
}

NSColor *DeskColorForTag(NSString *tag) { return DeskColorForSeed([@"tag:" stringByAppendingString:tag ?: @""]); }

NSString *DeskResetDescription(NSDate *resetAt) {
    if (!resetAt) return @"";
    NSTimeInterval seconds = resetAt.timeIntervalSinceNow;
    if (seconds <= 60) return @"即将重置";
    if (seconds < 3600) return [NSString stringWithFormat:@"%ld 分钟后重置", (long)ceil(seconds / 60)];
    if (seconds < 86400) {
        long hours = (long)(seconds / 3600), minutes = (long)fmod(seconds, 3600) / 60;
        return minutes ? [NSString stringWithFormat:@"%ld 小时 %ld 分后重置", hours, minutes]
                       : [NSString stringWithFormat:@"%ld 小时后重置", hours];
    }
    long days = (long)(seconds / 86400), hours = (long)fmod(seconds, 86400) / 3600;
    return hours ? [NSString stringWithFormat:@"%ld 天 %ld 小时后重置", days, hours]
                 : [NSString stringWithFormat:@"%ld 天后重置", days];
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
- (void)setSymbol:(NSString *)symbol {
    _symbol = [symbol copy];
    [self invalidateIntrinsicContentSize];
    [self setNeedsDisplay:YES];
}
- (void)setTintColor:(NSColor *)tintColor { _tintColor = tintColor ?: NSColor.systemGrayColor; [self setNeedsDisplay:YES]; }
- (void)setBackgroundStyle:(NSBackgroundStyle)backgroundStyle { _backgroundStyle = backgroundStyle; [self setNeedsDisplay:YES]; }
- (void)showStatus:(AccountStatus *)status showsNormal:(BOOL)showsNormal {
    BOOL visible = status && (showsNormal || status.kind != AccountStatusNormal);
    self.text = visible ? status.title : @"";
    self.symbol = visible ? status.symbol : nil;
    self.tintColor = DeskColorForTone(status.tone);
    self.toolTip = visible ? status.title : nil;
}
- (CGFloat)symbolWidth { return self.symbol.length ? 13 : 0; }
- (NSSize)intrinsicContentSize {
    if (!self.text.length) return NSMakeSize(0, 18);
    NSSize size = [self.text sizeWithAttributes:@{NSFontAttributeName: PillFont()}];
    return NSMakeSize(ceil(size.width) + 14 + self.symbolWidth, 18);
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
    CGFloat contentWidth = size.width + self.symbolWidth;
    CGFloat x = round((NSWidth(self.bounds) - contentWidth) / 2);
    if (self.symbol.length) {
        NSImageSymbolConfiguration *configuration = [[NSImageSymbolConfiguration configurationWithPointSize:9 weight:NSFontWeightBold]
            configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:tint]];
        NSImage *image = [[NSImage imageWithSystemSymbolName:self.symbol accessibilityDescription:nil]
            imageWithSymbolConfiguration:configuration];
        NSSize imageSize = image.size;
        [image drawInRect:NSMakeRect(x, round((NSHeight(self.bounds) - imageSize.height) / 2), imageSize.width, imageSize.height)];
        x += self.symbolWidth;
    }
    [self.text drawAtPoint:NSMakePoint(x, round((NSHeight(self.bounds) - size.height) / 2)) withAttributes:attributes];
}
@end

@implementation DeskSparklineView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _points = @[];
        _span = 7 * 86400;
        self.translatesAutoresizingMaskIntoConstraints = NO;
    }
    return self;
}
- (BOOL)isFlipped { return NO; }
- (void)setPoints:(NSArray<NSDictionary *> *)points {
    _points = [points copy] ?: @[];
    // Show the history that exists: at least six hours, at most a week.
    double first = [_points.firstObject[@"t"] doubleValue];
    double covered = first > 0 ? NSDate.date.timeIntervalSince1970 - first : 0;
    _span = MAX(6 * 3600, MIN(7 * 86400, covered * 1.05));
    [self setNeedsDisplay:YES];
}
- (void)drawRect:(NSRect)dirtyRect {
    NSRect plot = NSInsetRect(self.bounds, 1, 2);
    NSBezierPath *frame = [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:6 yRadius:6];
    [[NSColor.labelColor colorWithAlphaComponent:0.035] setFill];
    [frame fill];
    [[NSColor.labelColor colorWithAlphaComponent:0.08] setStroke];
    for (NSNumber *level in @[@20, @50]) {
        CGFloat y = NSMinY(plot) + NSHeight(plot) * level.doubleValue / 100;
        NSBezierPath *line = [NSBezierPath bezierPath];
        CGFloat dash[] = {2, 3};
        [line setLineDash:dash count:2 phase:0];
        [line moveToPoint:NSMakePoint(NSMinX(plot), y)];
        [line lineToPoint:NSMakePoint(NSMaxX(plot), y)];
        [line stroke];
    }
    double end = NSDate.date.timeIntervalSince1970, start = end - self.span;
    NSArray *series = @[@[@"long", NSColor.systemIndigoColor], @[@"short", NSColor.systemTealColor]];
    for (NSArray *line in series) {
        NSBezierPath *path = [NSBezierPath bezierPath];
        path.lineWidth = 1.5;
        path.lineJoinStyle = NSLineJoinStyleRound;
        BOOL started = NO;
        for (NSDictionary *point in self.points) {
            double t = [point[@"t"] doubleValue];
            NSNumber *value = point[line[0]];
            if (t < start || ![value isKindOfClass:NSNumber.class]) continue;
            NSPoint p = NSMakePoint(NSMinX(plot) + NSWidth(plot) * (t - start) / self.span,
                                    NSMinY(plot) + NSHeight(plot) * MAX(0, MIN(100, value.doubleValue)) / 100);
            if (started) [path lineToPoint:p]; else [path moveToPoint:p];
            started = YES;
        }
        if (!started) continue;
        [(NSColor *)line[1] setStroke];
        [path stroke];
    }
}
@end

@implementation DeskQuotaBar
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) self.translatesAutoresizingMaskIntoConstraints = NO;
    return self;
}
- (void)setRemainingPercent:(NSNumber *)remainingPercent { _remainingPercent = remainingPercent; [self setNeedsDisplay:YES]; }
- (NSSize)intrinsicContentSize { return NSMakeSize(NSViewNoIntrinsicMetric, 6); }
- (void)drawRect:(NSRect)dirtyRect {
    CGFloat radius = NSHeight(self.bounds) / 2;
    [[NSColor.labelColor colorWithAlphaComponent:0.08] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:radius yRadius:radius] fill];
    if (!self.remainingPercent) return;
    double value = MAX(0, MIN(100, self.remainingPercent.doubleValue));
    NSRect fill = self.bounds;
    fill.size.width = MAX(value > 0 ? NSHeight(fill) : 0, round(NSWidth(fill) * value / 100));
    [DeskColorForQuota(value) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:fill xRadius:radius yRadius:radius] fill];
}
@end

@implementation DeskTagsView
static NSFont *TagFont(void) { return [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium]; }
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _tags = @[];
        self.translatesAutoresizingMaskIntoConstraints = NO;
        [self setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    }
    return self;
}
- (void)setTags:(NSArray<NSString *> *)tags {
    _tags = [tags copy] ?: @[];
    self.toolTip = _tags.count ? [_tags componentsJoinedByString:@"、"] : nil;
    [self invalidateIntrinsicContentSize];
    [self setNeedsDisplay:YES];
}
- (void)setBackgroundStyle:(NSBackgroundStyle)backgroundStyle { _backgroundStyle = backgroundStyle; [self setNeedsDisplay:YES]; }
- (CGFloat)widthOfTag:(NSString *)tag {
    return ceil([tag sizeWithAttributes:@{NSFontAttributeName: TagFont()}].width) + 12;
}
- (NSSize)intrinsicContentSize {
    if (!self.tags.count) return NSMakeSize(0, 0);
    CGFloat width = 0;
    for (NSString *tag in self.tags) width += [self widthOfTag:tag] + 4;
    return NSMakeSize(width, 17);
}
- (void)drawChip:(NSString *)text atX:(CGFloat)x width:(CGFloat)width tint:(NSColor *)tint {
    BOOL emphasized = self.backgroundStyle == NSBackgroundStyleEmphasized;
    if (emphasized) tint = NSColor.whiteColor;
    CGFloat height = MIN(17, NSHeight(self.bounds));
    NSRect chip = NSMakeRect(x, round((NSHeight(self.bounds) - height) / 2), width, height);
    [[tint colorWithAlphaComponent:emphasized ? 0.25 : 0.15] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:chip xRadius:4 yRadius:4] fill];
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary *attributes = @{NSFontAttributeName: TagFont(), NSForegroundColorAttributeName: tint, NSParagraphStyleAttributeName: style};
    CGFloat textHeight = [text sizeWithAttributes:attributes].height;
    [text drawInRect:NSMakeRect(x + 6, NSMinY(chip) + round((height - textHeight) / 2), width - 12, textHeight) withAttributes:attributes];
}

- (void)drawRect:(NSRect)dirtyRect {
    CGFloat x = 0, limit = NSWidth(self.bounds);
    NSUInteger count = self.tags.count;
    for (NSUInteger index = 0; index < count; index++) {
        NSString *tag = self.tags[index];
        CGFloat width = [self widthOfTag:tag];
        NSUInteger after = count - index - 1;
        CGFloat reserve = after ? [self widthOfTag:[NSString stringWithFormat:@"+%lu", (unsigned long)after]] + 4 : 0;
        if (x + width + reserve > limit) {
            CGFloat available = limit - x - reserve;
            if (index == 0 && available >= 30) {
                // Always show the first tag, shortened, before the "+N".
                [self drawChip:tag atX:x width:available tint:DeskColorForTag(tag)];
                if (after) [self drawChip:[NSString stringWithFormat:@"+%lu", (unsigned long)after] atX:x + available + 4
                    width:reserve - 4 tint:NSColor.secondaryLabelColor];
            } else {
                NSString *rest = [NSString stringWithFormat:@"+%lu", (unsigned long)(count - index)];
                CGFloat restWidth = [self widthOfTag:rest];
                if (x + restWidth <= limit) [self drawChip:rest atX:x width:restWidth tint:NSColor.secondaryLabelColor];
            }
            return;
        }
        [self drawChip:tag atX:x width:width tint:DeskColorForTag(tag)];
        x += width + 4;
    }
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
