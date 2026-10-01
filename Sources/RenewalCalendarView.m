#import "RenewalCalendarView.h"
#import "Account.h"
#import "DeskUI.h"

typedef NS_ENUM(NSInteger, CalendarEventKind) {
    CalendarEventRenewal,
    CalendarEventPastRenewal,
    CalendarEventProjectedRenewal,
    CalendarEventExpiry,
    CalendarEventExpired,
};

@interface CalendarEvent : NSObject
@property (nonatomic, strong) Account *account;
@property (nonatomic, strong) NSDate *day;
@property (nonatomic) CalendarEventKind kind;
@property (nonatomic, readonly) BOOL isRenewal;
@property (nonatomic, readonly) NSColor *color;
@property (nonatomic, readonly) NSString *kindTitle;
@end

@implementation CalendarEvent
- (BOOL)isRenewal { return self.kind <= CalendarEventProjectedRenewal; }
- (NSColor *)color {
    switch (self.kind) {
        case CalendarEventRenewal: return NSColor.systemBlueColor;
        case CalendarEventProjectedRenewal: return NSColor.systemTealColor;
        case CalendarEventPastRenewal: return NSColor.systemGrayColor;
        case CalendarEventExpiry: return NSColor.systemOrangeColor;
        case CalendarEventExpired: return NSColor.systemRedColor;
    }
    return NSColor.systemGrayColor;
}
- (NSString *)kindTitle {
    switch (self.kind) {
        case CalendarEventRenewal: return @"自动续费";
        case CalendarEventProjectedRenewal: return @"预计续费";
        case CalendarEventPastRenewal: return @"已续费";
        case CalendarEventExpiry: return @"到期";
        case CalendarEventExpired: return @"已过期";
    }
    return @"";
}
@end

@class RenewalCalendarView;

@interface RenewalGridView : NSView <NSViewToolTipOwner>
@property (nonatomic, weak) RenewalCalendarView *owner;
@property (nonatomic, strong) NSDate *month;
@property (nonatomic, copy) NSArray<CalendarEvent *> *events;
@property (nonatomic, copy) NSArray<NSString *> *selectedIDs;
@end

@interface RenewalCalendarView ()
@property (nonatomic, strong) NSDate *month;
@property (nonatomic, strong) RenewalGridView *grid;
@property (nonatomic, strong) NSTextField *monthLabel;
@property (nonatomic, strong) NSTextField *summaryLabel;
@end

static NSCalendar *Calendar(void) {
    NSCalendar *calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    calendar.firstWeekday = 2;
    return calendar;
}

@implementation RenewalGridView {
    NSMutableArray<NSDictionary *> *_chips;
}

- (BOOL)isFlipped { return YES; }

- (NSInteger)leadingDays {
    NSInteger weekday = [Calendar() component:NSCalendarUnitWeekday fromDate:self.month];
    return (weekday + 5) % 7;
}

- (NSInteger)rows {
    NSInteger days = [Calendar() rangeOfUnit:NSCalendarUnitDay inUnit:NSCalendarUnitMonth forDate:self.month].length;
    return (NSInteger)ceil((self.leadingDays + days) / 7.0);
}

- (NSDate *)firstVisibleDay {
    return [Calendar() dateByAddingUnit:NSCalendarUnitDay value:-self.leadingDays toDate:self.month options:0];
}

- (void)drawRect:(NSRect)dirtyRect {
    NSCalendar *calendar = Calendar();
    _chips = [NSMutableArray array];
    [self removeAllToolTips];
    CGFloat header = 24;
    NSInteger rows = MAX(self.rows, 1);
    CGFloat cellWidth = NSWidth(self.bounds) / 7, cellHeight = (NSHeight(self.bounds) - header) / rows;

    NSArray *weekdays = @[@"一", @"二", @"三", @"四", @"五", @"六", @"日"];
    NSDictionary *weekdayAttributes = @{NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
                                        NSForegroundColorAttributeName: NSColor.secondaryLabelColor};
    for (NSInteger column = 0; column < 7; column++) {
        NSSize size = [weekdays[column] sizeWithAttributes:weekdayAttributes];
        [weekdays[column] drawAtPoint:NSMakePoint(column * cellWidth + (cellWidth - size.width) / 2, (header - size.height) / 2)
            withAttributes:weekdayAttributes];
    }

    NSDate *today = [calendar startOfDayForDate:NSDate.date];
    NSInteger month = [calendar component:NSCalendarUnitMonth fromDate:self.month];
    NSDate *first = self.firstVisibleDay;
    for (NSInteger index = 0; index < rows * 7; index++) {
        NSDate *day = [calendar dateByAddingUnit:NSCalendarUnitDay value:index toDate:first options:0];
        NSRect cell = NSMakeRect((index % 7) * cellWidth, header + (index / 7) * cellHeight, cellWidth, cellHeight);
        BOOL inMonth = [calendar component:NSCalendarUnitMonth fromDate:day] == month;
        if (index % 7 >= 5) {
            [[NSColor.labelColor colorWithAlphaComponent:0.025] setFill];
            NSRectFillUsingOperation(cell, NSCompositingOperationSourceOver);
        }
        [NSColor.separatorColor setStroke];
        NSBezierPath *border = [NSBezierPath bezierPathWithRect:NSInsetRect(cell, 0.25, 0.25)];
        border.lineWidth = 0.5;
        [border stroke];

        NSString *number = [NSString stringWithFormat:@"%ld", (long)[calendar component:NSCalendarUnitDay fromDate:day]];
        BOOL isToday = [day isEqualToDate:today];
        NSColor *numberColor = isToday ? NSColor.whiteColor : (inMonth ? NSColor.labelColor : NSColor.tertiaryLabelColor);
        NSDictionary *numberAttributes = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:12 weight:isToday ? NSFontWeightSemibold : NSFontWeightRegular],
                                           NSForegroundColorAttributeName: numberColor};
        NSSize numberSize = [number sizeWithAttributes:numberAttributes];
        NSPoint numberPoint = NSMakePoint(NSMinX(cell) + 8, NSMinY(cell) + 5);
        if (isToday) {
            CGFloat diameter = MAX(numberSize.width, numberSize.height) + 6;
            [NSColor.controlAccentColor setFill];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(numberPoint.x - (diameter - numberSize.width) / 2,
                numberPoint.y - (diameter - numberSize.height) / 2, diameter, diameter)] fill];
        }
        [number drawAtPoint:numberPoint withAttributes:numberAttributes];

        NSMutableArray<CalendarEvent *> *events = [NSMutableArray array];
        for (CalendarEvent *event in self.events) if ([event.day isEqualToDate:day]) [events addObject:event];
        if (!events.count) continue;
        NSInteger capacity = MAX(1, (NSInteger)floor((NSHeight(cell) - 28) / 20));
        NSInteger visible = (NSInteger)events.count > capacity ? capacity - 1 : (NSInteger)events.count;
        CGFloat y = NSMinY(cell) + 26;
        for (NSInteger position = 0; position < visible; position++) {
            [self drawEvent:events[position] inRect:NSMakeRect(NSMinX(cell) + 4, y, cellWidth - 8, 17) dimmed:!inMonth];
            y += 20;
        }
        if (visible < (NSInteger)events.count) {
            NSString *more = [NSString stringWithFormat:@"还有 %lu 个", (unsigned long)(events.count - visible)];
            [more drawAtPoint:NSMakePoint(NSMinX(cell) + 8, y) withAttributes:@{
                NSFontAttributeName: [NSFont systemFontOfSize:10.5], NSForegroundColorAttributeName: NSColor.secondaryLabelColor}];
        }
    }
}

- (void)drawEvent:(CalendarEvent *)event inRect:(NSRect)rect dimmed:(BOOL)dimmed {
    NSColor *color = event.color;
    BOOL selected = [self.selectedIDs containsObject:event.account.identifier];
    CGFloat alpha = dimmed ? 0.5 : 1;
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:4 yRadius:4];
    [[color colorWithAlphaComponent:(event.kind == CalendarEventProjectedRenewal ? 0.1 : 0.18) * alpha] setFill];
    [path fill];
    if (selected) {
        [color setStroke];
        path.lineWidth = 1.5;
        [path stroke];
    }
    NSRect strip = NSMakeRect(NSMinX(rect), NSMinY(rect), 3, NSHeight(rect));
    [[color colorWithAlphaComponent:alpha] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:strip xRadius:1.5 yRadius:1.5] fill];
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary *attributes = @{NSFontAttributeName: [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium],
                                 NSForegroundColorAttributeName: [NSColor.labelColor colorWithAlphaComponent:dimmed ? 0.45 : 0.85],
                                 NSParagraphStyleAttributeName: style};
    [event.account.name drawInRect:NSMakeRect(NSMinX(rect) + 7, NSMinY(rect) + 1.5, NSWidth(rect) - 10, NSHeight(rect) - 2)
        withAttributes:attributes];
    NSUInteger index = _chips.count;
    [_chips addObject:@{@"rect": [NSValue valueWithRect:rect], @"event": event}];
    [self addToolTipRect:rect owner:self userData:(void *)(intptr_t)index];
}

- (NSString *)view:(NSView *)view stringForToolTip:(NSToolTipTag)tag point:(NSPoint)point userData:(void *)data {
    NSUInteger index = (NSUInteger)(intptr_t)data;
    if (index >= _chips.count) return @"";
    CalendarEvent *event = _chips[index][@"event"];
    Account *account = event.account;
    NSMutableArray *parts = [NSMutableArray arrayWithObjects:account.name, account.planTitle, event.kindTitle, nil];
    if (event.isRenewal && account.monthlyPrice) [parts addObject:AccountFormatMoney(account.monthlyPrice, account.currency)];
    return [parts componentsJoinedByString:@" · "];
}

- (CalendarEvent *)eventAtPoint:(NSPoint)point {
    for (NSDictionary *chip in _chips)
        if (NSPointInRect(point, [chip[@"rect"] rectValue])) return chip[@"event"];
    return nil;
}

- (void)mouseDown:(NSEvent *)event {
    CalendarEvent *hit = [self eventAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (!hit) return;
    RenewalCalendarView *owner = self.owner;
    if (event.clickCount >= 2) {
        if (owner.openAccount) owner.openAccount(hit.account.identifier);
    } else if (owner.selectAccount) {
        owner.selectAccount(hit.account.identifier, (event.modifierFlags & NSEventModifierFlagCommand) != 0);
    }
}

- (NSMenu *)menuForEvent:(NSEvent *)event {
    CalendarEvent *hit = [self eventAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    RenewalCalendarView *owner = self.owner;
    return hit && owner.menuForAccount ? owner.menuForAccount(hit.account.identifier) : nil;
}
@end

@implementation RenewalCalendarView

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _accounts = @[];
        _selectedIDs = @[];
        NSCalendar *calendar = Calendar();
        _month = [calendar dateFromComponents:[calendar components:NSCalendarUnitYear | NSCalendarUnitMonth fromDate:NSDate.date]];
        [self buildContent];
    }
    return self;
}

- (void)buildContent {
    NSButton *previous = DeskIconButton(@"chevron.backward", @"上个月", self, @selector(previousMonth:));
    NSButton *next = DeskIconButton(@"chevron.forward", @"下个月", self, @selector(nextMonth:));
    NSButton *today = DeskButton(@"本月", nil, self, @selector(showToday:));
    today.controlSize = NSControlSizeSmall;
    self.monthLabel = DeskLabel(@"", 15, NSFontWeightSemibold);
    self.summaryLabel = DeskLabel(@"", 12, NSFontWeightRegular);
    self.summaryLabel.textColor = NSColor.secondaryLabelColor;
    [self.summaryLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *header = [NSStackView stackViewWithViews:@[previous, self.monthLabel, next, today, self.summaryLabel]];
    header.spacing = 8;
    [header setCustomSpacing:14 afterView:today];
    self.grid = [RenewalGridView new];
    self.grid.owner = self;
    for (NSView *view in @[header, self.grid]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:self.topAnchor constant:10],
        [header.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [header.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-16],
        [self.grid.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:8],
        [self.grid.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [self.grid.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [self.grid.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-12]
    ]];
    [self reload];
}

- (void)setAccounts:(NSArray<Account *> *)accounts { _accounts = [accounts copy]; [self reload]; }
- (void)setSelectedIDs:(NSArray<NSString *> *)selectedIDs {
    _selectedIDs = [selectedIDs copy] ?: @[];
    self.grid.selectedIDs = _selectedIDs;
    [self.grid setNeedsDisplay:YES];
}

- (void)previousMonth:(id)sender { [self moveMonths:-1]; }
- (void)nextMonth:(id)sender { [self moveMonths:1]; }
- (void)moveMonths:(NSInteger)months {
    self.month = [Calendar() dateByAddingUnit:NSCalendarUnitMonth value:months toDate:self.month options:0];
    [self reload];
}

- (void)showToday:(id)sender {
    NSCalendar *calendar = Calendar();
    self.month = [calendar dateFromComponents:[calendar components:NSCalendarUnitYear | NSCalendarUnitMonth fromDate:NSDate.date]];
    [self reload];
}

- (void)reload {
    NSCalendar *calendar = Calendar();
    NSDateComponents *parts = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth fromDate:self.month];
    self.monthLabel.stringValue = [NSString stringWithFormat:@"%ld年%ld月", (long)parts.year, (long)parts.month];

    self.grid.month = self.month;
    NSDate *start = self.grid.firstVisibleDay;
    NSDate *end = [calendar dateByAddingUnit:NSCalendarUnitDay value:self.grid.rows * 7 toDate:start options:0];
    NSDate *today = [calendar startOfDayForDate:NSDate.date];
    NSMutableArray<CalendarEvent *> *events = [NSMutableArray array];
    for (Account *account in self.accounts) {
        NSDate *due = AccountDateFromDayString(account.expiresAt);
        if (!due) continue;
        NSInteger from = account.autoRenew.boolValue ? -24 : 0, to = account.autoRenew.boolValue ? 24 : 0;
        for (NSInteger offset = from; offset <= to; offset++) {
            NSDate *day = [calendar startOfDayForDate:[calendar dateByAddingUnit:NSCalendarUnitMonth value:offset toDate:due options:0]];
            if ([day compare:start] == NSOrderedAscending || [day compare:end] != NSOrderedAscending) continue;
            CalendarEvent *event = [CalendarEvent new];
            event.account = account;
            event.day = day;
            if (account.autoRenew.boolValue)
                event.kind = offset < 0 ? CalendarEventPastRenewal : (offset == 0 ? CalendarEventRenewal : CalendarEventProjectedRenewal);
            else
                event.kind = [day compare:today] == NSOrderedAscending ? CalendarEventExpired : CalendarEventExpiry;
            [events addObject:event];
        }
    }
    [events sortUsingComparator:^NSComparisonResult(CalendarEvent *a, CalendarEvent *b) {
        return [a.account.name localizedStandardCompare:b.account.name];
    }];
    self.grid.events = events;
    self.grid.selectedIDs = self.selectedIDs;
    [self.grid setNeedsDisplay:YES];

    NSUInteger renewals = 0, expiries = 0;
    NSMutableDictionary<NSString *, NSNumber *> *totals = [NSMutableDictionary dictionary];
    for (CalendarEvent *event in events) {
        if ([calendar component:NSCalendarUnitMonth fromDate:event.day] != parts.month) continue;
        if (!event.isRenewal) { expiries++; continue; }
        renewals++;
        if (event.account.monthlyPrice) {
            NSString *currency = event.account.currency;
            totals[currency] = @(totals[currency].doubleValue + event.account.monthlyPrice.doubleValue);
        }
    }
    NSMutableArray *summary = [NSMutableArray array];
    if (renewals) [summary addObject:[NSString stringWithFormat:@"续费 %lu 笔", (unsigned long)renewals]];
    for (NSString *currency in [totals.allKeys sortedArrayUsingSelector:@selector(compare:)])
        [summary addObject:AccountFormatMoney(totals[currency], currency)];
    if (expiries) [summary addObject:[NSString stringWithFormat:@"%lu 个账号到期", (unsigned long)expiries]];
    self.summaryLabel.stringValue = summary.count ? [summary componentsJoinedByString:@" · "] : @"本月没有续费或到期";
}
@end
