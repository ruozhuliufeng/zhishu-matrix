#import "ExpenseReportView.h"
#import "Account.h"
#import "AccountInsights.h"
#import "DeskUI.h"

static NSString *const OtherSupplier = @"其他";

/// Categorical slots of the reference palette, light and dark steps, in their validated order.
static NSColor *SlotColor(NSUInteger slot) {
    static NSArray<NSArray<NSString *> *> *hexes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hexes = @[@[@"2a78d6", @"3987e5"], @[@"eb6834", @"d95926"], @[@"1baf7a", @"199e70"], @[@"eda100", @"c98500"],
                  @[@"e87ba4", @"d55181"], @[@"008300", @"008300"], @[@"4a3aa7", @"9085e9"]];
    });
    NSArray<NSString *> *pair = slot < hexes.count ? hexes[slot] : @[@"9b9a95", @"6f6e69"];
    NSColor *(^color)(NSString *) = ^NSColor *(NSString *hex) {
        unsigned value = 0;
        [[NSScanner scannerWithString:hex] scanHexInt:&value];
        return [NSColor colorWithSRGBRed:((value >> 16) & 0xff) / 255.0 green:((value >> 8) & 0xff) / 255.0 blue:(value & 0xff) / 255.0 alpha:1];
    };
    NSColor *light = color(pair[0]), *dark = color(pair[1]);
    return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
        return [appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]]
            == NSAppearanceNameDarkAqua ? dark : light;
    }];
}

static NSString *ShortYuan(double value) {
    if (value >= 10000) return [NSString stringWithFormat:@"¥%.1f万", value / 10000];
    return [NSString stringWithFormat:@"¥%.0f", value];
}

#pragma mark - Chart

@interface ExpenseChartView : NSView
@property (nonatomic, strong, nullable) AccountExpenseReport *report;
/// Series in stacking order (bottom first); the last may be OtherSupplier.
@property (nonatomic, copy) NSArray<NSString *> *series;
@property (nonatomic, copy) NSDictionary<NSString *, NSColor *> *colors;
@property (nonatomic) NSInteger selectedMonth;
/// Monthly budget in CNY drawn as a reference line; 0 for none.
@property (nonatomic) double budget;
@property (nonatomic, copy, nullable) void (^monthClicked)(NSInteger month);
- (void)updateToolTips;
@end

@implementation ExpenseChartView

- (BOOL)isFlipped { return NO; }

- (NSRect)plotRect { return NSMakeRect(58, 26, NSWidth(self.bounds) - 58 - 12, NSHeight(self.bounds) - 26 - 22); }

/// Height of a month's stack: refunds come off the total but a supplier's segment never drops below zero.
- (double)stackTotalForMonth:(NSInteger)month {
    double total = 0;
    for (NSNumber *value in self.report.monthSupplierTotals[month].allValues) total += MAX(0, value.doubleValue);
    return total;
}

- (double)scaleMax {
    double maximum = self.budget;
    for (NSInteger month = 0; month < 12; month++) maximum = MAX(maximum, [self stackTotalForMonth:month]);
    if (maximum <= 0) return 100;
    double magnitude = pow(10, floor(log10(maximum)));
    for (NSNumber *step in @[@1, @2, @2.5, @5, @10])
        if (step.doubleValue * magnitude >= maximum) return step.doubleValue * magnitude;
    return 10 * magnitude;
}

- (NSRect)columnRectForMonth:(NSInteger)month {
    NSRect plot = self.plotRect;
    CGFloat slot = NSWidth(plot) / 12;
    return NSMakeRect(NSMinX(plot) + slot * month, NSMinY(plot), slot, NSHeight(plot));
}

/// A bar segment whose top corners are rounded when it is the topmost one.
static NSBezierPath *SegmentPath(NSRect rect, CGFloat radius) {
    radius = MIN(radius, MIN(NSWidth(rect) / 2, NSHeight(rect)));
    NSBezierPath *path = [NSBezierPath bezierPath];
    [path moveToPoint:NSMakePoint(NSMinX(rect), NSMinY(rect))];
    [path lineToPoint:NSMakePoint(NSMaxX(rect), NSMinY(rect))];
    [path lineToPoint:NSMakePoint(NSMaxX(rect), NSMaxY(rect) - radius)];
    [path appendBezierPathWithArcFromPoint:NSMakePoint(NSMaxX(rect), NSMaxY(rect)) toPoint:NSMakePoint(NSMaxX(rect) - radius, NSMaxY(rect))
        radius:radius];
    [path lineToPoint:NSMakePoint(NSMinX(rect) + radius, NSMaxY(rect))];
    [path appendBezierPathWithArcFromPoint:NSMakePoint(NSMinX(rect), NSMaxY(rect)) toPoint:NSMakePoint(NSMinX(rect), NSMaxY(rect) - radius)
        radius:radius];
    [path closePath];
    return path;
}

- (NSDictionary *)textAttributes:(NSColor *)color size:(CGFloat)size weight:(NSFontWeight)weight {
    return @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:size weight:weight], NSForegroundColorAttributeName: color};
}

- (void)drawRect:(NSRect)dirtyRect {
    NSRect plot = self.plotRect;
    double maximum = self.scaleMax;
    // Recessive grid with yuan labels.
    for (NSInteger step = 0; step <= 4; step++) {
        CGFloat y = NSMinY(plot) + NSHeight(plot) * step / 4;
        NSBezierPath *line = [NSBezierPath bezierPath];
        [line moveToPoint:NSMakePoint(NSMinX(plot), y)];
        [line lineToPoint:NSMakePoint(NSMaxX(plot), y)];
        line.lineWidth = step == 0 ? 1 : 0.5;
        [(step == 0 ? NSColor.separatorColor : [NSColor.separatorColor colorWithAlphaComponent:0.5]) setStroke];
        [line stroke];
        NSString *label = ShortYuan(maximum * step / 4);
        NSDictionary *attributes = [self textAttributes:NSColor.tertiaryLabelColor size:10 weight:NSFontWeightRegular];
        NSSize size = [label sizeWithAttributes:attributes];
        [label drawAtPoint:NSMakePoint(NSMinX(plot) - 8 - size.width, y - size.height / 2) withAttributes:attributes];
    }
    for (NSInteger month = 0; month < 12; month++) {
        NSRect column = [self columnRectForMonth:month];
        BOOL selected = month == self.selectedMonth;
        if (selected) {
            [[NSColor.labelColor colorWithAlphaComponent:0.05] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(NSMakeRect(NSMinX(column), NSMinY(column) - 22, NSWidth(column),
                NSHeight(column) + 22), 2, 0) xRadius:6 yRadius:6] fill];
        }
        NSString *name = [NSString stringWithFormat:@"%ld月", (long)month + 1];
        NSDictionary *attributes = [self textAttributes:selected ? NSColor.labelColor : NSColor.secondaryLabelColor size:10.5
            weight:selected ? NSFontWeightSemibold : NSFontWeightRegular];
        NSSize size = [name sizeWithAttributes:attributes];
        [name drawAtPoint:NSMakePoint(NSMidX(column) - size.width / 2, NSMinY(plot) - 6 - size.height) withAttributes:attributes];

        NSDictionary<NSString *, NSNumber *> *totals = self.report.monthSupplierTotals[month];
        double total = self.report.monthTotals[month].doubleValue;
        if ([self stackTotalForMonth:month] <= 0) continue;
        CGFloat width = MIN(28, NSWidth(column) * 0.56);
        CGFloat x = NSMidX(column) - width / 2;
        __block CGFloat y = NSMinY(plot);
        NSMutableArray<NSArray *> *segments = [NSMutableArray array];
        for (NSString *series in self.series) {
            double value = 0;
            if ([series isEqualToString:OtherSupplier]) {
                for (NSString *supplier in totals) if (![self.series containsObject:supplier]) value += totals[supplier].doubleValue;
            } else {
                value = totals[series].doubleValue;
            }
            if (value > 0) [segments addObject:@[series, @(value)]];
        }
        [segments enumerateObjectsUsingBlock:^(NSArray *segment, NSUInteger index, BOOL *stop) {
            BOOL top = index == segments.count - 1;
            CGFloat height = NSHeight(plot) * [segment[1] doubleValue] / maximum;
            // A 2px surface gap separates stacked segments.
            CGFloat gap = top ? 0 : 2;
            NSRect rect = NSMakeRect(x, y, width, MAX(1, height - gap));
            [self.colors[segment[0]] setFill];
            [(top ? SegmentPath(rect, 4) : [NSBezierPath bezierPathWithRect:rect]) fill];
            y += height;
        }];
        // Only the selected month carries a value label.
        if (selected) {
            NSString *value = AccountFormatCNY(@(total));
            NSDictionary *labelAttributes = [self textAttributes:NSColor.labelColor size:10.5 weight:NSFontWeightSemibold];
            NSSize labelSize = [value sizeWithAttributes:labelAttributes];
            CGFloat top = NSMinY(plot) + NSHeight(plot) * [self stackTotalForMonth:month] / maximum + 4;
            CGFloat left = MIN(MAX(NSMidX(column) - labelSize.width / 2, NSMinX(plot)), NSMaxX(plot) - labelSize.width);
            [value drawAtPoint:NSMakePoint(left, MIN(top, NSMaxY(self.bounds) - labelSize.height)) withAttributes:labelAttributes];
        }
    }
    if (self.budget > 0) {
        // A dashed reference line, labelled at the right end, in text ink rather than a series color.
        CGFloat y = round(NSMinY(plot) + NSHeight(plot) * self.budget / maximum) + 0.5;
        NSBezierPath *line = [NSBezierPath bezierPath];
        [line moveToPoint:NSMakePoint(NSMinX(plot), y)];
        [line lineToPoint:NSMakePoint(NSMaxX(plot), y)];
        line.lineWidth = 1;
        CGFloat dash[] = {4, 3};
        [line setLineDash:dash count:2 phase:0];
        [NSColor.secondaryLabelColor setStroke];
        [line stroke];
        NSString *label = [@"预算 " stringByAppendingString:ShortYuan(self.budget)];
        NSDictionary *attributes = [self textAttributes:NSColor.secondaryLabelColor size:10 weight:NSFontWeightMedium];
        NSSize size = [label sizeWithAttributes:attributes];
        NSRect back = NSMakeRect(NSMaxX(plot) - size.width - 6, y + 2, size.width + 6, size.height);
        [NSColor.controlBackgroundColor setFill];
        NSRectFill(back);
        [label drawAtPoint:NSMakePoint(NSMinX(back) + 3, NSMinY(back)) withAttributes:attributes];
    }
    if (self.report.count == 0) {
        NSString *empty = @"这一年还没有付款记录";
        NSDictionary *attributes = @{NSFontAttributeName: [NSFont systemFontOfSize:12], NSForegroundColorAttributeName: NSColor.secondaryLabelColor};
        NSSize size = [empty sizeWithAttributes:attributes];
        [empty drawAtPoint:NSMakePoint(NSMidX(plot) - size.width / 2, NSMidY(plot) - size.height / 2) withAttributes:attributes];
    }
}

- (void)updateToolTips {
    [self removeAllToolTips];
    for (NSInteger month = 0; month < 12; month++) [self addToolTipRect:[self columnRectForMonth:month] owner:self userData:(void *)(intptr_t)month];
}

- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    [self updateToolTips];
}

- (NSString *)view:(NSView *)view stringForToolTip:(NSToolTipTag)tag point:(NSPoint)point userData:(void *)data {
    NSInteger month = (NSInteger)(intptr_t)data;
    if (!self.report || month < 0 || month > 11) return @"";
    double total = self.report.monthTotals[month].doubleValue;
    NSMutableArray *lines = [NSMutableArray arrayWithObject:[NSString stringWithFormat:@"%ld 年 %ld 月：%@", (long)self.report.year,
        (long)month + 1, total != 0 || [self stackTotalForMonth:month] > 0 ? AccountFormatCNY(@(total)) : @"无付款"]];
    if (self.budget > 0 && total > self.budget)
        [lines addObject:[@"超出预算 " stringByAppendingString:AccountFormatCNY(@(total - self.budget))]];
    NSDictionary<NSString *, NSNumber *> *totals = self.report.monthSupplierTotals[month];
    for (NSString *supplier in [totals keysSortedByValueUsingSelector:@selector(compare:)].reverseObjectEnumerator)
        [lines addObject:[NSString stringWithFormat:@"%@　%@", supplier, AccountFormatCNY(totals[supplier])]];
    return [lines componentsJoinedByString:@"\n"];
}

- (void)mouseUp:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    for (NSInteger month = 0; month < 12; month++)
        if (NSPointInRect(point, NSInsetRect([self columnRectForMonth:month], 0, -24)) && self.monthClicked) self.monthClicked(month);
}

- (void)resetCursorRects { [self addCursorRect:self.plotRect cursor:NSCursor.pointingHandCursor]; }
@end

#pragma mark - Report

/// Table cell with an optional status icon whose slot collapses when there is no icon.
@interface ExpenseReportCell : NSTableCellView
@property (nonatomic, strong) NSLayoutConstraint *iconWidth;
@end

@implementation ExpenseReportCell
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        NSImageView *icon = [NSImageView new];
        icon.translatesAutoresizingMaskIntoConstraints = NO;
        NSTextField *label = DeskLabel(@"", 11.5, NSFontWeightRegular);
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        [self addSubview:icon];
        [self addSubview:label];
        self.imageView = icon;
        self.textField = label;
        _iconWidth = [icon.widthAnchor constraintEqualToConstant:0];
        [NSLayoutConstraint activateConstraints:@[
            _iconWidth,
            [icon.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:2],
            [icon.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:4],
            [label.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-2],
            [label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor]
        ]];
    }
    return self;
}
- (void)showIcon:(NSImage *)image {
    self.imageView.image = image;
    self.iconWidth.constant = image ? 14 : 0;
}
@end

@interface ExpenseReportView () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic) NSInteger year;
@property (nonatomic) NSInteger month;
@property (nonatomic, strong, nullable) AccountExpenseReport *report;
@property (nonatomic, copy) NSArray<NSDictionary *> *reconciliation;
@property (nonatomic, strong) NSTextField *yearLabel;
@property (nonatomic, strong) NSTextField *summaryLabel;
@property (nonatomic, strong) ExpenseChartView *chart;
@property (nonatomic, strong) NSStackView *legend;
@property (nonatomic, strong) NSTableView *supplierTable;
@property (nonatomic, strong) NSTableView *sourceTable;
@property (nonatomic, strong) NSTableView *accountTable;
@property (nonatomic, strong) NSTableView *checkTable;
@property (nonatomic, strong) NSTextField *checkTitle;
@property (nonatomic, strong) NSTextField *checkSummary;
@end

@implementation ExpenseReportView

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _accounts = @[];
        _supplierOrder = @[];
        _reconciliation = @[];
        NSDateComponents *today = [NSCalendar.currentCalendar components:NSCalendarUnitYear | NSCalendarUnitMonth fromDate:NSDate.date];
        _year = today.year;
        _month = today.month - 1;
        [self build];
    }
    return self;
}

- (NSTableView *)tableWithColumns:(NSArray<NSArray *> *)columns {
    NSTableView *table = [NSTableView new];
    table.style = NSTableViewStylePlain;
    table.usesAlternatingRowBackgroundColors = YES;
    table.rowHeight = 22;
    table.intercellSpacing = NSMakeSize(8, 2);
    table.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;
    for (NSArray *spec in columns) {
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:spec[0]];
        column.title = spec[1];
        column.width = [spec[2] doubleValue];
        column.minWidth = 44;
        if ([spec[0] isEqualToString:@"total"] || [spec[0] isEqualToString:@"count"] || [spec[0] isEqualToString:@"expected"] ||
            [spec[0] isEqualToString:@"recorded"]) column.headerCell.alignment = NSTextAlignmentRight;
        [table addTableColumn:column];
    }
    table.dataSource = self;
    table.delegate = self;
    return table;
}

- (NSScrollView *)scrollForTable:(NSTableView *)table height:(CGFloat)height {
    NSScrollView *scroll = [NSScrollView new];
    scroll.documentView = table;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSBezelBorder;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll.heightAnchor constraintEqualToConstant:height].active = YES;
    return scroll;
}

- (NSStackView *)titled:(NSString *)title view:(NSView *)view {
    NSTextField *label = DeskLabel(title, 12, NSFontWeightSemibold);
    NSStackView *stack = [NSStackView stackViewWithViews:@[label, view]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 6;
    [view.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    return stack;
}

- (void)build {
    NSScrollView *scroll = [NSScrollView new];
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.drawsBackground = NO;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:scroll];
    DeskFlippedView *document = [DeskFlippedView new];
    document.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.documentView = document;

    NSButton *previous = DeskIconButton(@"chevron.left", @"上一年", self, @selector(previousYear:));
    NSButton *next = DeskIconButton(@"chevron.right", @"下一年", self, @selector(nextYear:));
    self.yearLabel = DeskLabel(@"", 15, NSFontWeightSemibold);
    NSButton *thisYear = [NSButton buttonWithTitle:@"今年" target:self action:@selector(currentYear:)];
    thisYear.controlSize = NSControlSizeSmall;
    self.summaryLabel = DeskLabel(@"", 12, NSFontWeightRegular);
    self.summaryLabel.textColor = NSColor.secondaryLabelColor;
    [self.summaryLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *header = [NSStackView stackViewWithViews:@[previous, self.yearLabel, next, thisYear, self.summaryLabel]];
    header.spacing = 8;
    [header setCustomSpacing:16 afterView:thisYear];

    self.chart = [ExpenseChartView new];
    self.chart.translatesAutoresizingMaskIntoConstraints = NO;
    [self.chart.heightAnchor constraintEqualToConstant:220].active = YES;
    __weak typeof(self) weakSelf = self;
    self.chart.monthClicked = ^(NSInteger month) {
        weakSelf.month = month;
        [weakSelf reload];
    };
    self.legend = [NSStackView new];
    self.legend.spacing = 14;

    self.supplierTable = [self tableWithColumns:@[@[@"name", @"供应商", @110], @[@"count", @"笔数", @44], @[@"total", @"金额", @90]]];
    self.sourceTable = [self tableWithColumns:@[@[@"name", @"付款来源", @130], @[@"count", @"笔数", @44], @[@"total", @"金额", @90]]];
    self.accountTable = [self tableWithColumns:@[@[@"name", @"账号", @120], @[@"count", @"笔数", @44], @[@"total", @"金额", @90]]];
    self.accountTable.target = self;
    self.accountTable.doubleAction = @selector(accountRowOpened:);
    NSStackView *breakdowns = [NSStackView stackViewWithViews:@[
        [self titled:@"按供应商" view:[self scrollForTable:self.supplierTable height:170]],
        [self titled:@"按付款来源" view:[self scrollForTable:self.sourceTable height:170]],
        [self titled:@"按账号" view:[self scrollForTable:self.accountTable height:170]]]];
    breakdowns.distribution = NSStackViewDistributionFillEqually;
    breakdowns.spacing = 14;
    breakdowns.alignment = NSLayoutAttributeTop;

    self.checkTitle = DeskLabel(@"", 12, NSFontWeightSemibold);
    self.checkSummary = DeskLabel(@"", 11, NSFontWeightRegular);
    self.checkSummary.textColor = NSColor.secondaryLabelColor;
    NSStackView *checkHeader = [NSStackView stackViewWithViews:@[self.checkTitle, self.checkSummary]];
    checkHeader.spacing = 10;
    checkHeader.alignment = NSLayoutAttributeFirstBaseline;
    self.checkTable = [self tableWithColumns:@[@[@"name", @"账号", @160], @[@"date", @"预计扣款日", @96], @[@"expected", @"预计", @96],
        @[@"recorded", @"已记", @96], @[@"state", @"状态", @110]]];
    self.checkTable.target = self;
    self.checkTable.doubleAction = @selector(checkRowOpened:);
    NSScrollView *checkScroll = [self scrollForTable:self.checkTable height:200];
    NSTextField *checkHint = DeskLabel(@"双击“未记”或“待扣款”的账号可以直接记一笔付款。", 11, NSFontWeightRegular);
    checkHint.textColor = NSColor.tertiaryLabelColor;

    NSStackView *stack = [NSStackView stackViewWithViews:@[header, self.chart, self.legend, DeskSeparator(), breakdowns, DeskSeparator(),
        checkHeader, checkScroll, checkHint]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 12;
    stack.edgeInsets = NSEdgeInsetsMake(16, 24, 24, 24);
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [document addSubview:stack];
    for (NSView *view in @[self.chart, breakdowns, checkScroll, stack.arrangedSubviews[3], stack.arrangedSubviews[5]])
        [view.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-48].active = YES;
    NSClipView *clip = scroll.contentView;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [document.leadingAnchor constraintEqualToAnchor:clip.leadingAnchor],
        [document.trailingAnchor constraintEqualToAnchor:clip.trailingAnchor],
        [document.topAnchor constraintEqualToAnchor:clip.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:document.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:document.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:document.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:document.bottomAnchor]
    ]];
}

- (void)setAccounts:(NSArray<Account *> *)accounts {
    _accounts = [accounts copy] ?: @[];
    [self reload];
}

- (void)previousYear:(id)sender { self.year--; self.month = 11; [self reload]; }
- (void)nextYear:(id)sender { self.year++; self.month = 0; [self reload]; }
- (void)currentYear:(id)sender {
    NSDateComponents *today = [NSCalendar.currentCalendar components:NSCalendarUnitYear | NSCalendarUnitMonth fromDate:NSDate.date];
    self.year = today.year;
    self.month = today.month - 1;
    [self reload];
}

- (void)reload {
    NSDictionary *rates = AccountExchangeRates();
    self.report = [AccountExpenseReport reportForAccounts:self.accounts year:self.year rates:rates];
    self.yearLabel.stringValue = [NSString stringWithFormat:@"%ld 年", (long)self.year];
    // Most important first: the label truncates at the end when the window is narrow.
    NSMutableArray *summary = [NSMutableArray array];
    [summary addObject:self.report.count ? [NSString stringWithFormat:@"实付 %@", AccountFormatCNY(@(self.report.total))] : @"没有付款记录"];
    double budget = AccountMonthlyBudget();
    NSDateComponents *today = [NSCalendar.currentCalendar components:NSCalendarUnitYear | NSCalendarUnitMonth fromDate:NSDate.date];
    if (budget > 0 && self.year == today.year) {
        double spent = self.report.monthTotals[(NSUInteger)today.month - 1].doubleValue;
        [summary addObject:spent > budget
            ? [NSString stringWithFormat:@"本月 %@，超出预算 %@", AccountFormatCNY(@(spent)), AccountFormatCNY(@(spent - budget))]
            : [NSString stringWithFormat:@"本月 %@ / 预算 %@", AccountFormatCNY(@(spent)), AccountFormatCNY(@(budget))]];
    } else if (budget > 0) {
        NSUInteger over = 0;
        for (NSNumber *total in self.report.monthTotals) if (total.doubleValue > budget) over++;
        [summary addObject:over ? [NSString stringWithFormat:@"%lu 个月超出预算", (unsigned long)over] : @"每月都在预算内"];
    }
    if (self.report.missingCurrencies.count)
        [summary addObject:[NSString stringWithFormat:@"%@ 未设汇率，未计入", [self.report.missingCurrencies componentsJoinedByString:@"、"]]];
    if (self.report.refundTotal > 0)
        [summary addObject:[NSString stringWithFormat:@"已扣除退款 %@", AccountFormatCNY(@(self.report.refundTotal))]];
    if (self.report.failedCount)
        [summary addObject:[NSString stringWithFormat:@"扣款失败 %lu 次", (unsigned long)self.report.failedCount]];
    if (self.report.count) {
        NSInteger months = 0;
        for (NSNumber *total in self.report.monthTotals) if (total.doubleValue > 0) months++;
        [summary addObject:[NSString stringWithFormat:@"%lu 笔", (unsigned long)self.report.count]];
        if (months) [summary addObject:[NSString stringWithFormat:@"月均 %@", AccountFormatCNY(@(self.report.total / months))]];
    }
    self.summaryLabel.stringValue = [summary componentsJoinedByString:@" · "];
    self.summaryLabel.toolTip = [summary componentsJoinedByString:@"\n"];

    // Colors follow the supplier: its place in the fixed order picks the slot.
    NSMutableArray<NSString *> *series = [NSMutableArray array];
    NSMutableDictionary *colors = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *present = [NSMutableSet set];
    for (NSDictionary *totals in self.report.monthSupplierTotals) [present addObjectsFromArray:totals.allKeys];
    BOOL other = NO;
    NSUInteger slot = 0;
    for (NSString *supplier in self.supplierOrder) {
        if (slot >= 7) break;
        NSUInteger index = slot++;
        if (![present containsObject:supplier]) continue;
        [series addObject:supplier];
        colors[supplier] = SlotColor(index);
    }
    for (NSString *supplier in present) if (![series containsObject:supplier]) other = YES;
    if (other) {
        [series addObject:OtherSupplier];
        colors[OtherSupplier] = SlotColor(99);
    }
    self.chart.report = self.report;
    self.chart.budget = budget;
    self.chart.series = series;
    self.chart.colors = colors;
    self.chart.selectedMonth = self.month;
    [self.chart setNeedsDisplay:YES];
    [self.chart updateToolTips];

    for (NSView *view in self.legend.arrangedSubviews.copy) [view removeFromSuperview];
    // One series needs no legend: the title names it.
    if (series.count > 1)
        for (NSString *name in series) {
            NSImage *swatch = [NSImage imageWithSize:NSMakeSize(10, 10) flipped:NO drawingHandler:^BOOL(NSRect rect) {
                [colors[name] setFill];
                [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:2 yRadius:2] fill];
                return YES;
            }];
            NSImageView *icon = [NSImageView imageViewWithImage:swatch];
            NSTextField *label = DeskLabel([name isEqualToString:OtherSupplier] ? @"其他 / 未填写供应商" : name, 11, NSFontWeightRegular);
            label.textColor = NSColor.secondaryLabelColor;
            NSStackView *item = [NSStackView stackViewWithViews:@[icon, label]];
            item.spacing = 5;
            [item setHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
            [self.legend addView:item inGravity:NSStackViewGravityLeading];
        }

    NSDate *monthDay = [NSCalendar.currentCalendar dateWithEra:1 year:self.year month:self.month + 1 day:1 hour:12 minute:0 second:0 nanosecond:0];
    self.reconciliation = [AccountExpenseReport reconciliationForAccounts:self.accounts month:monthDay now:NSDate.date rates:rates];
    self.checkTitle.stringValue = [NSString stringWithFormat:@"%ld 年 %ld 月核对", (long)self.year, (long)self.month + 1];
    NSUInteger missing = 0, different = 0, upcoming = 0, failed = 0;
    for (NSDictionary *row in self.reconciliation) {
        if ([row[@"state"] isEqualToString:@"failed"]) failed++;
        if ([row[@"state"] isEqualToString:@"missing"]) missing++;
        if ([row[@"state"] isEqualToString:@"different"]) different++;
        if ([row[@"state"] isEqualToString:@"upcoming"]) upcoming++;
    }
    NSMutableArray *check = [NSMutableArray array];
    if (failed) [check addObject:[NSString stringWithFormat:@"%lu 笔扣款失败", (unsigned long)failed]];
    if (missing) [check addObject:[NSString stringWithFormat:@"%lu 笔未记", (unsigned long)missing]];
    if (different) [check addObject:[NSString stringWithFormat:@"%lu 笔金额不同", (unsigned long)different]];
    if (upcoming) [check addObject:[NSString stringWithFormat:@"%lu 笔待扣款", (unsigned long)upcoming]];
    self.checkSummary.stringValue = self.reconciliation.count ? (check.count ? [check componentsJoinedByString:@" · "] : @"都已记账")
        : @"这个月没有预计的扣款，也没有付款记录";
    for (NSTableView *table in @[self.supplierTable, self.sourceTable, self.accountTable, self.checkTable]) [table reloadData];
}

#pragma mark - Tables

- (NSArray *)rowsForTable:(NSTableView *)table {
    if (table == self.supplierTable) return self.report.bySupplier ?: @[];
    if (table == self.sourceTable) return self.report.bySource ?: @[];
    if (table == self.accountTable) return self.report.byAccount ?: @[];
    return self.reconciliation;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return (NSInteger)[self rowsForTable:tableView].count; }

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    ExpenseReportCell *cell = [tableView makeViewWithIdentifier:@"ReportCell" owner:self];
    if (!cell) {
        cell = [[ExpenseReportCell alloc] initWithFrame:NSZeroRect];
        cell.identifier = @"ReportCell";
    }
    NSDictionary *item = [self rowsForTable:tableView][(NSUInteger)row];
    NSString *key = column.identifier;
    NSTextField *label = cell.textField;
    label.font = [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightRegular];
    label.textColor = NSColor.labelColor;
    label.alignment = NSTextAlignmentLeft;
    [cell showIcon:nil];
    if ([key isEqualToString:@"name"]) {
        label.stringValue = item[@"name"];
    } else if ([key isEqualToString:@"count"]) {
        label.stringValue = [item[@"count"] stringValue];
        label.alignment = NSTextAlignmentRight;
    } else if ([key isEqualToString:@"total"]) {
        label.stringValue = AccountFormatCNY(item[@"total"]);
        label.alignment = NSTextAlignmentRight;
    } else if ([key isEqualToString:@"date"]) {
        label.stringValue = [item[@"date"] length] ? item[@"date"] : @"—";
        label.textColor = [item[@"date"] length] ? NSColor.labelColor : NSColor.tertiaryLabelColor;
    } else if ([key isEqualToString:@"expected"]) {
        label.stringValue = [item[@"expected"] isKindOfClass:NSNumber.class] ? AccountFormatCNY(item[@"expected"]) : @"—";
        label.alignment = NSTextAlignmentRight;
    } else if ([key isEqualToString:@"recorded"]) {
        double recorded = [item[@"recorded"] doubleValue];
        label.stringValue = recorded != 0 ? AccountFormatCNY(item[@"recorded"]) : @"—";
        label.alignment = NSTextAlignmentRight;
    } else if ([key isEqualToString:@"state"]) {
        // Status colors always come with an icon and a word.
        NSDictionary *states = @{
            @"recorded": @[@"已记", @"checkmark.circle.fill", NSColor.systemGreenColor],
            @"different": @[@"金额不同", @"exclamationmark.circle.fill", NSColor.systemOrangeColor],
            @"missing": @[@"未记", @"xmark.circle.fill", NSColor.systemRedColor],
            @"failed": @[@"扣款失败", @"exclamationmark.triangle.fill", NSColor.systemRedColor],
            @"upcoming": @[@"待扣款", @"clock", NSColor.secondaryLabelColor],
            @"extra": @[@"计划外付款", @"plus.circle", NSColor.secondaryLabelColor]};
        NSArray *state = states[item[@"state"]] ?: states[@"extra"];
        label.stringValue = state[0];
        label.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium];
        [cell showIcon:[[NSImage imageWithSystemSymbolName:state[1] accessibilityDescription:nil]
            imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[state[2]]]]];
    }
    return cell;
}

- (void)accountRowOpened:(id)sender {
    NSInteger row = self.accountTable.clickedRow;
    if (row < 0 || row >= (NSInteger)self.report.byAccount.count) return;
    NSString *identifier = self.report.byAccount[(NSUInteger)row][@"accountID"];
    if (identifier && self.selectAccount) self.selectAccount(identifier);
}

- (void)checkRowOpened:(id)sender {
    NSInteger row = self.checkTable.clickedRow;
    if (row < 0 || row >= (NSInteger)self.reconciliation.count) return;
    NSDictionary *item = self.reconciliation[(NSUInteger)row];
    NSString *state = item[@"state"];
    if (([state isEqualToString:@"missing"] || [state isEqualToString:@"upcoming"] || [state isEqualToString:@"failed"]) &&
        self.recordPayment)
        self.recordPayment(item[@"accountID"], item[@"date"]);
    else if (self.selectAccount)
        self.selectAccount(item[@"accountID"]);
}
@end
