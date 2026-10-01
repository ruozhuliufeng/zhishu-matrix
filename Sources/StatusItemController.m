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
        for (Account *account in self.store.accounts)
            if ([AccountStatus statusForAccount:account recommended:NO now:now].tone == AccountStatusToneCritical) attention++;
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

- (NSAttributedString *)titleForAccount:(Account *)account detail:(NSString *)detail color:(NSColor *)color {
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.tabStops = @[[[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentRight location:300 options:@{}]];
    NSMutableAttributedString *title = [[NSMutableAttributedString alloc] initWithString:account.name
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

    NSArray<Account *> *accounts = self.store.accounts;
    NSDate *now = NSDate.date;
    Account *recommended = AccountRecommended(accounts);
    NSMenuItem *header = [menu addItemWithTitle:recommended
        ? [NSString stringWithFormat:@"推荐使用：%@（%@）", recommended.name, QuotaSummary(recommended)]
        : (accounts.count ? @"暂无可推荐的账号，刷新用量后再看" : @"还没有账号") action:nil keyEquivalent:@""];
    header.enabled = NO;
    if (accounts.count) [menu addItem:[NSMenuItem separatorItem]];
    for (Account *account in accounts) {
        AccountStatus *status = [AccountStatus statusForAccount:account recommended:account == recommended now:now];
        NSString *detail = QuotaSummary(account);
        if (status.kind == AccountStatusSignedOut || status.kind == AccountStatusExpired || status.kind == AccountStatusExpiringSoon ||
            status.kind == AccountStatusRefreshFailed || !detail.length) detail = status.kind == AccountStatusNormal ? @"" : status.title;
        NSColor *color = status.tone == AccountStatusToneNeutral ? NSColor.secondaryLabelColor : ToneColor(status.tone);
        NSMenuItem *item = [self addTitle:account.name action:@selector(openAccountItem:) tag:0 to:menu];
        item.attributedTitle = [self titleForAccount:account detail:detail color:color];
        item.image = DotImage(ToneColor(status.tone));
        item.representedObject = account.identifier;
        item.toolTip = [NSString stringWithFormat:@"%@ · %@ · %@", account.planTitle, status.title, [account expiryDescriptionFromDate:now]];
    }
    [menu addItem:[NSMenuItem separatorItem]];
    BOOL refreshing = self.isRefreshing && self.isRefreshing();
    NSMenuItem *refresh = [self addTitle:refreshing ? @"正在刷新用量…" : @"刷新全部用量" action:@selector(command:)
        tag:StatusItemCommandRefreshAll to:menu];
    refresh.enabled = !refreshing && accounts.count > 0;
    [menu addItem:[NSMenuItem separatorItem]];
    [self addTitle:@"打开智枢矩阵" action:@selector(command:) tag:StatusItemCommandShowWindow to:menu];
    [self addTitle:@"账号管理" action:@selector(command:) tag:StatusItemCommandShowManagement to:menu];
    [self addTitle:@"设置…" action:@selector(command:) tag:StatusItemCommandSettings to:menu];
    if (self.canLock && self.canLock()) [self addTitle:@"立即锁定" action:@selector(command:) tag:StatusItemCommandLock to:menu];
    [menu addItem:[NSMenuItem separatorItem]];
    [self addTitle:@"退出智枢矩阵" action:@selector(quit:) tag:0 to:menu];
}

- (void)openAccountItem:(NSMenuItem *)sender {
    if (self.openAccount && sender.representedObject) self.openAccount(sender.representedObject);
}

- (void)command:(NSMenuItem *)sender {
    if (self.perform) self.perform((StatusItemCommand)sender.tag);
}

- (void)quit:(id)sender { [NSApp terminate:sender]; }
@end
