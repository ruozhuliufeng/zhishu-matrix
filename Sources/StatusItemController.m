#import "StatusItemController.h"
#import "Account.h"
#import "AccountInsights.h"
#import "DeskUI.h"

NSString *const StatusItemEnabledDefaultsKey = @"statusItemEnabled";
NSString *const KeepRunningInMenuBarDefaultsKey = @"keepRunningInMenuBar";
NSNotificationName const StatusItemSettingsDidChangeNotification = @"StatusItemSettingsDidChangeNotification";

static NSColor *ToneColor(AccountStatusTone tone) {
    switch (tone) {
        case AccountStatusToneCritical: return NSColor.systemRedColor;
        case AccountStatusToneWarning: return NSColor.systemOrangeColor;
        case AccountStatusToneGood: return NSColor.systemGreenColor;
        case AccountStatusToneNeutral: return NSColor.tertiaryLabelColor;
    }
    return NSColor.tertiaryLabelColor;
}

static NSImage *DotImage(NSColor *color) {
    return [NSImage imageWithSize:NSMakeSize(10, 10) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [color setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(rect, 1.5, 1.5)] fill];
        return YES;
    }];
}

static NSString *QuotaSummary(Account *account) {
    NSMutableArray *parts = [NSMutableArray array];
    if (account.usage.longWindow) [parts addObject:[NSString stringWithFormat:@"周 %.0f%%", account.usage.longWindow.remainingPercent]];
    if (account.usage.shortWindow) [parts addObject:[NSString stringWithFormat:@"5h %.0f%%", account.usage.shortWindow.remainingPercent]];
    return [parts componentsJoinedByString:@" · "];
}

@interface StatusItemController () <NSMenuDelegate>
@property (nonatomic, strong) AccountStore *store;
@property (nonatomic, strong, nullable) NSStatusItem *item;
@end

@implementation StatusItemController

- (instancetype)initWithStore:(AccountStore *)store {
    if ((self = [super init])) {
        _store = store;
        [NSUserDefaults.standardUserDefaults registerDefaults:@{StatusItemEnabledDefaultsKey: @YES, KeepRunningInMenuBarDefaultsKey: @YES}];
    }
    return self;
}

- (void)applySettings {
    BOOL enabled = [NSUserDefaults.standardUserDefaults boolForKey:StatusItemEnabledDefaultsKey];
    if (enabled && !self.item) {
        self.item = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
        self.item.autosaveName = @"ZhishuMatrixStatusItem";
        NSMenu *menu = [NSMenu new];
        menu.delegate = self;
        menu.autoenablesItems = NO;
        self.item.menu = menu;
        [self update];
    } else if (!enabled && self.item) {
        [NSStatusBar.systemStatusBar removeStatusItem:self.item];
        self.item = nil;
    }
}

- (void)update {
    NSStatusBarButton *button = self.item.button;
    if (!button) return;
    BOOL locked = self.isLocked && self.isLocked();
    NSUInteger attention = 0;
    NSDate *now = NSDate.date;
    if (!locked)
        for (Account *account in self.store.trackedAccounts)
            if ([AccountStatus statusForAccount:account now:now].tone == AccountStatusToneCritical) attention++;
    NSImage *image = [NSImage imageWithSystemSymbolName:locked ? @"lock.square" : @"square.grid.3x3.square" accessibilityDescription:@"智枢矩阵"];
    image.template = YES;
    button.image = image;
    button.imagePosition = NSImageLeading;
    button.title = attention ? [NSString stringWithFormat:@" %lu", (unsigned long)attention] : @"";
    button.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightMedium];
    button.toolTip = attention ? [NSString stringWithFormat:@"智枢矩阵 · %lu 个账号需要处理", (unsigned long)attention] : @"智枢矩阵";
}

#pragma mark - Menu

- (NSMenuItem *)addTitle:(NSString *)title action:(SEL)action tag:(NSInteger)tag to:(NSMenu *)menu {
    NSMenuItem *item = [menu addItemWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    item.tag = tag;
    return item;
}

- (NSAttributedString *)titleWithText:(NSString *)text detail:(NSString *)detail color:(NSColor *)color {
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.tabStops = @[[[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentRight location:300 options:@{}]];
    NSMutableAttributedString *title = [[NSMutableAttributedString alloc] initWithString:text
        attributes:@{NSFontAttributeName: [NSFont menuFontOfSize:0], NSParagraphStyleAttributeName: paragraph}];
    if (detail.length)
        [title appendAttributedString:[[NSAttributedString alloc] initWithString:[@"\t" stringByAppendingString:detail] attributes:@{
            NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular],
            NSForegroundColorAttributeName: color, NSParagraphStyleAttributeName: paragraph}]];
    return title;
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    if (self.isLocked && self.isLocked()) {
        NSMenuItem *header = [menu addItemWithTitle:@"智枢矩阵已锁定" action:nil keyEquivalent:@""];
        header.enabled = NO;
        [self addTitle:@"解锁…" action:@selector(command:) tag:StatusItemCommandUnlock to:menu];
        [menu addItem:[NSMenuItem separatorItem]];
        [self addTitle:@"退出智枢矩阵" action:@selector(quit:) tag:0 to:menu];
        return;
    }

    NSArray<Account *> *accounts = self.store.visibleAccounts;
    NSArray<Account *> *tracked = self.store.trackedAccounts;
    NSDate *now = NSDate.date;
    NSDictionary *rates = AccountExchangeRates();

    // Accounts that need something done.
    NSMutableArray<NSArray *> *attention = [NSMutableArray array];
    for (Account *account in tracked) {
        AccountStatus *status = [AccountStatus statusForAccount:account now:now];
        if (status.tone == AccountStatusToneCritical || status.tone == AccountStatusToneWarning) [attention addObject:@[account, status]];
    }
    [attention sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        return [@(((AccountStatus *)b[1]).kind) compare:@(((AccountStatus *)a[1]).kind)];
    }];
    [self addHeader:attention.count ? [NSString stringWithFormat:@"需要处理（%lu）", (unsigned long)attention.count]
        : (accounts.count ? @"没有需要处理的账号" : @"还没有账号") to:menu];
    for (NSArray *entry in attention) {
        Account *account = entry[0];
        AccountStatus *status = entry[1];
        [self addAccountItem:account text:account.name detail:status.title color:ToneColor(status.tone) dot:ToneColor(status.tone) to:menu];
    }

    // Renewals that went through without a payment being recorded.
    NSMutableArray<NSArray *> *unrecorded = [NSMutableArray array];
    for (Account *account in tracked) {
        NSString *date = AccountUnrecordedRenewal(account, now);
        if (date) [unrecorded addObject:@[account, date]];
    }
    [unrecorded sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [a[1] compare:b[1]]; }];
    if (unrecorded.count) {
        [menu addItem:[NSMenuItem separatorItem]];
        [self addHeader:[NSString stringWithFormat:@"待记账（%lu）· 点击记一笔", (unsigned long)unrecorded.count] to:menu];
        NSDateFormatter *dayFormat = [NSDateFormatter new];
        dayFormat.dateFormat = @"M月d日";
        for (NSArray *entry in unrecorded) {
            Account *account = entry[0];
            NSDictionary *charge = account.expectedCharge;
            NSNumber *cny = AccountAmountInCNY(charge[@"amount"], charge[@"currency"], rates);
            NSString *amount = cny ? AccountFormatCNY(cny) : (charge ? AccountFormatMoney(charge[@"amount"], charge[@"currency"]) : @"");
            NSString *text = [NSString stringWithFormat:@"%@　%@", [dayFormat stringFromDate:AccountDateFromDayString(entry[1])], account.name];
            NSMenuItem *item = [self addAccountItem:account text:text detail:amount color:NSColor.secondaryLabelColor
                dot:NSColor.systemBrownColor to:menu];
            item.action = @selector(recordPaymentItem:);
            item.representedObject = @[account.identifier, entry[1]];
        }
    }

    // Charges and expiries in the next 30 days.
    NSMutableArray<Account *> *upcoming = [NSMutableArray array];
    for (Account *account in tracked) {
        NSNumber *days = [account daysRemainingFromDate:now];
        if (days && days.integerValue >= 0 && days.integerValue <= 30) [upcoming addObject:account];
    }
    [upcoming sortUsingComparator:^NSComparisonResult(Account *a, Account *b) { return [a.expiresAt compare:b.expiresAt]; }];
    [menu addItem:[NSMenuItem separatorItem]];
    [self addHeader:upcoming.count ? @"30 天内扣款 / 到期" : @"30 天内没有扣款或到期" to:menu];
    NSDateFormatter *day = [NSDateFormatter new];
    day.dateFormat = @"M月d日";
    for (Account *account in upcoming) {
        NSDate *date = AccountDateFromDayString(account.expiresAt);
        NSString *detail = @"到期";
        NSColor *color = NSColor.systemOrangeColor;
        if (account.autoRenew.boolValue) {
            NSDictionary *charge = account.expectedCharge;
            NSNumber *cny = AccountAmountInCNY(charge[@"amount"], charge[@"currency"], rates);
            detail = cny ? [@"扣款 " stringByAppendingString:AccountFormatCNY(cny)]
                : (charge ? [@"扣款 " stringByAppendingString:AccountFormatMoney(charge[@"amount"], charge[@"currency"])] : @"自动续费");
            color = NSColor.secondaryLabelColor;
        }
        [self addAccountItem:account text:[NSString stringWithFormat:@"%@　%@", [day stringFromDate:date], account.name]
            detail:detail color:color dot:account.autoRenew.boolValue ? NSColor.systemBlueColor : NSColor.systemOrangeColor to:menu];
    }
    NSArray<NSString *> *missing = nil;
    double spend = [self.store monthlySpendInCNYWithRates:rates missingCurrencies:&missing];
    if (spend > 0 || missing.count)
        [self addHeader:[NSString stringWithFormat:@"每月支出 %@%@", AccountFormatCNY(@(spend)),
            missing.count ? [NSString stringWithFormat:@"（%@ 未设汇率）", [missing componentsJoinedByString:@"、"]] : @""] to:menu];

    // Every account, for opening one quickly.
    if (accounts.count) {
        [menu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *all = [self addTitle:@"全部账号" action:nil tag:0 to:menu];
        NSMenu *list = [NSMenu new];
        list.autoenablesItems = NO;
        for (Account *account in accounts) {
            AccountStatus *status = [AccountStatus statusForAccount:account now:now];
            NSString *detail = status.kind == AccountStatusNormal ? QuotaSummary(account) : status.title;
            NSColor *color = status.tone == AccountStatusToneNeutral ? NSColor.secondaryLabelColor : ToneColor(status.tone);
            [self addAccountItem:account text:account.name detail:detail color:color dot:ToneColor(status.tone) to:list];
        }
        all.submenu = list;
    }
    [menu addItem:[NSMenuItem separatorItem]];
    BOOL refreshing = self.isRefreshing && self.isRefreshing();
    NSMenuItem *refresh = [self addTitle:refreshing ? @"正在刷新用量…" : @"刷新全部用量" action:@selector(command:)
        tag:StatusItemCommandRefreshAll to:menu];
    refresh.enabled = !refreshing && tracked.count > 0;
    [menu addItem:[NSMenuItem separatorItem]];
    [self addTitle:@"打开智枢矩阵" action:@selector(command:) tag:StatusItemCommandShowWindow to:menu];
    [self addTitle:@"账号管理" action:@selector(command:) tag:StatusItemCommandShowManagement to:menu];
    [self addTitle:@"设置…" action:@selector(command:) tag:StatusItemCommandSettings to:menu];
    if (self.canLock && self.canLock()) [self addTitle:@"立即锁定" action:@selector(command:) tag:StatusItemCommandLock to:menu];
    [menu addItem:[NSMenuItem separatorItem]];
    [self addTitle:@"退出智枢矩阵" action:@selector(quit:) tag:0 to:menu];
}

- (void)addHeader:(NSString *)title to:(NSMenu *)menu {
    NSMenuItem *header = [menu addItemWithTitle:title action:nil keyEquivalent:@""];
    header.enabled = NO;
}

- (NSMenuItem *)addAccountItem:(Account *)account text:(NSString *)text detail:(NSString *)detail color:(NSColor *)color
    dot:(NSColor *)dot to:(NSMenu *)menu {
    NSMenuItem *item = [self addTitle:text action:@selector(openAccountItem:) tag:0 to:menu];
    item.attributedTitle = [self titleWithText:text detail:detail color:color];
    item.image = DotImage(dot);
    item.representedObject = account.identifier;
    NSString *payment = account.paymentSummary;
    item.toolTip = [NSString stringWithFormat:@"%@ · %@%@", account.planTitle, [account expiryDescriptionFromDate:NSDate.date],
        payment.length ? [@" · " stringByAppendingString:payment] : @""];
    return item;
}

- (void)recordPaymentItem:(NSMenuItem *)sender {
    NSArray *entry = sender.representedObject;
    if (self.recordPayment && entry.count == 2) self.recordPayment(entry[0], entry[1]);
}

- (void)openAccountItem:(NSMenuItem *)sender {
    if (self.openAccount && sender.representedObject) self.openAccount(sender.representedObject);
}

- (void)command:(NSMenuItem *)sender {
    if (self.perform) self.perform((StatusItemCommand)sender.tag);
}

- (void)quit:(id)sender { [NSApp terminate:sender]; }
@end
