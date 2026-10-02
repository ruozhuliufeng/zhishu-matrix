#import "SettingsWindowController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "Account.h"
#import "AccountAlerts.h"
#import "AccountInsights.h"
#import "AccountRefresher.h"
#import "AppLock.h"
#import "AuthorizationLink.h"
#import "BackupManager.h"
#import "BrowserSession.h"
#import "DeskUI.h"
#import "Keychain.h"
#import "MainWindowController.h"
#import "NetworkProxy.h"
#import "StatusItemController.h"
#import "WebDAVClient.h"

NSString *const SettingsPaneGeneral = @"general";
NSString *const SettingsPaneUsage = @"usage";
NSString *const SettingsPaneSecurity = @"security";
NSString *const SettingsPaneBackup = @"backup";
NSString *const SettingsPaneNetwork = @"network";
NSString *const SettingsPaneCost = @"cost";

static CGFloat const PaneWidth = 580;

static NSTextField *Hint(NSString *text) {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.font = [NSFont systemFontOfSize:11];
    label.textColor = NSColor.secondaryLabelColor;
    label.preferredMaxLayoutWidth = PaneWidth - 60;
    return label;
}

static NSTextField *Title(NSString *text) { return DeskLabel(text, 13, NSFontWeightSemibold); }

static NSStackView *Row(NSArray<NSView *> *views) {
    NSStackView *row = [NSStackView stackViewWithViews:views];
    row.spacing = 8;
    row.alignment = NSLayoutAttributeCenterY;
    return row;
}

static NSPopUpButton *PopUp(NSArray<NSArray *> *options, NSInteger selected, id target, SEL action) {
    NSPopUpButton *popUp = [NSPopUpButton new];
    for (NSArray *option in options) {
        [popUp addItemWithTitle:option[0]];
        popUp.lastItem.tag = [option[1] integerValue];
    }
    if (![popUp selectItemWithTag:selected]) [popUp selectItemAtIndex:0];
    popUp.target = target;
    popUp.action = action;
    return popUp;
}

static NSString *BackupTime(NSDate *date) {
    if (!date) return @"还没有";
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    formatter.dateFormat = [NSCalendar.currentCalendar isDateInToday:date] ? @"今天 HH:mm" : @"yyyy年M月d日 HH:mm";
    return [formatter stringFromDate:date];
}

/// A settings pane: a vertical stack with a fixed width whose height follows its content.
@interface SettingsPane : NSViewController
@property (nonatomic, copy) NSArray<NSView *> *rows;
@end

@implementation SettingsPane
- (void)loadView {
    NSStackView *stack = [NSStackView new];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 8;
    stack.edgeInsets = NSEdgeInsetsMake(20, 24, 22, 24);
    for (NSView *row in self.rows) {
        row.translatesAutoresizingMaskIntoConstraints = NO;
        [stack addArrangedSubview:row];
        if ([row isKindOfClass:NSBox.class] || [row isKindOfClass:NSTextField.class])
            [row.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-48].active = YES;
    }
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [stack.widthAnchor constraintEqualToConstant:PaneWidth].active = YES;
    self.view = stack;
}
@end

/// Resizes the window to each pane's height, keeping its top edge in place.
@interface SettingsTabController : NSTabViewController
- (void)fitItem:(NSTabViewItem *)item;
@end

@implementation SettingsTabController
- (void)tabView:(NSTabView *)tabView didSelectTabViewItem:(NSTabViewItem *)item {
    [super tabView:tabView didSelectTabViewItem:item];
    [self fitItem:item];
}

- (void)fitItem:(NSTabViewItem *)item {
    NSWindow *window = self.view.window;
    NSView *pane = item.viewController.view;
    if (!window || !pane) return;
    window.title = item.label;
    [pane layoutSubtreeIfNeeded];
    NSSize size = pane.fittingSize;
    NSRect content = [window contentRectForFrameRect:window.frame];
    NSRect target = [window frameRectForContentRect:NSMakeRect(NSMinX(content), NSMaxY(content) - size.height, size.width, size.height)];
    [window setFrame:target display:YES animate:window.isVisible];
}
@end

@interface SettingsWindowController () <NSTextFieldDelegate, NSWindowDelegate>
@property (nonatomic, strong) AccountStore *store;
@property (nonatomic, strong) BackupManager *backup;
@property (nonatomic, strong) AccountAlerts *alerts;
@property (nonatomic, strong) AppLock *lock;
@property (nonatomic, strong) SettingsTabController *tabs;
// General
@property (nonatomic, strong) NSButton *statusItemToggle;
@property (nonatomic, strong) NSButton *keepRunningToggle;
@property (nonatomic, strong) NSButton *safariToggle;
@property (nonatomic, strong) NSTextField *authField;
@property (nonatomic, strong) NSTextField *authError;
@property (nonatomic, strong) NSTextField *authNameField;
// Usage & notifications
@property (nonatomic, strong) NSTextField *notificationStatus;
// Security
@property (nonatomic, strong) NSButton *lockToggle;
@property (nonatomic, strong) NSPopUpButton *idlePopUp;
@property (nonatomic, strong) NSButton *screenLockToggle;
@property (nonatomic, strong) NSButton *lockNowButton;
@property (nonatomic, strong) NSTextField *lockStatus;
// Backup
@property (nonatomic, strong) NSButton *autoBackupToggle;
@property (nonatomic, strong) NSTextField *localStatus;
@property (nonatomic, strong) NSTextField *serverField;
@property (nonatomic, strong) NSTextField *usernameField;
@property (nonatomic, strong) NSSecureTextField *passwordField;
@property (nonatomic, strong) NSTextField *folderField;
@property (nonatomic, strong) NSButton *webdavToggle;
@property (nonatomic, strong) NSTextField *webdavStatus;
@property (nonatomic, strong) NSArray<NSButton *> *webdavButtons;
// Cost
@property (nonatomic, strong) NSStackView *ratesStack;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSTextField *> *rateFields;
@property (nonatomic, strong) NSComboBox *currencyPicker;
@property (nonatomic, strong) NSMutableSet<NSString *> *pendingCurrencies;
// Network
@property (nonatomic, strong) NSTextField *proxyField;
@property (nonatomic, strong) NSTextField *proxyResult;
@property (nonatomic, strong) NSButton *proxyTestButton;
@end

@implementation SettingsWindowController

- (instancetype)initWithStore:(AccountStore *)store backup:(BackupManager *)backup alerts:(AccountAlerts *)alerts lock:(AppLock *)lock {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, PaneWidth, 420)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    if ((self = [super initWithWindow:window])) {
        _store = store;
        _backup = backup;
        _alerts = alerts;
        _lock = lock;
        window.title = @"设置";
        window.releasedWhenClosed = NO;
        window.restorable = NO;
        window.delegate = self;
        [self buildTabs];
        [window center];
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:self selector:@selector(backupStateChanged:) name:BackupStateDidChangeNotification object:nil];
        [center addObserver:self selector:@selector(refreshSecurity) name:AppLockSettingsDidChangeNotification object:nil];
    }
    return self;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (NSTabViewItem *)itemWithIdentifier:(NSString *)identifier label:(NSString *)label symbol:(NSString *)symbol rows:(NSArray *)rows {
    SettingsPane *pane = [SettingsPane new];
    pane.rows = rows;
    pane.title = label;
    NSTabViewItem *item = [NSTabViewItem tabViewItemWithViewController:pane];
    item.identifier = identifier;
    item.label = label;
    item.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:label];
    return item;
}

- (void)buildTabs {
    self.tabs = [SettingsTabController new];
    self.tabs.tabStyle = NSTabViewControllerTabStyleToolbar;
    for (NSTabViewItem *item in @[
        [self itemWithIdentifier:SettingsPaneGeneral label:@"通用" symbol:@"gearshape" rows:[self generalRows]],
        [self itemWithIdentifier:SettingsPaneUsage label:@"用量与通知" symbol:@"bell.badge" rows:[self usageRows]],
        [self itemWithIdentifier:SettingsPaneSecurity label:@"安全" symbol:@"lock" rows:[self securityRows]],
        [self itemWithIdentifier:SettingsPaneBackup label:@"备份" symbol:@"externaldrive.badge.timemachine" rows:[self backupRows]],
        [self itemWithIdentifier:SettingsPaneCost label:@"费用" symbol:@"yensign.circle" rows:[self costRows]],
        [self itemWithIdentifier:SettingsPaneNetwork label:@"网络" symbol:@"network" rows:[self networkRows]]])
        [self.tabs addTabViewItem:item];
    self.window.contentViewController = self.tabs;
    [self refreshBackupStatus];
    [self refreshSecurity];
}

- (void)showPane:(NSString *)identifier {
    NSInteger index = [self.tabs.tabView indexOfTabViewItemWithIdentifier:identifier];
    if (index != NSNotFound) self.tabs.selectedTabViewItemIndex = index;
    [self showWindow:nil];
    [self.window makeKeyAndOrderFront:nil];
}

- (void)showWindow:(id)sender {
    [super showWindow:sender];
    [self.tabs fitItem:self.tabs.tabView.selectedTabViewItem];
    [self.window makeFirstResponder:nil];
    [self.alerts describeAuthorization:^(NSString *description, BOOL allowed) {
        self.notificationStatus.stringValue = description;
        self.notificationStatus.textColor = allowed ? NSColor.secondaryLabelColor : NSColor.systemOrangeColor;
    }];
    [self refreshBackupStatus];
    [self refreshSecurity];
}

#pragma mark - General

- (NSArray<NSView *> *)generalRows {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    self.statusItemToggle = [NSButton checkboxWithTitle:@"在菜单栏显示智枢矩阵" target:self action:@selector(statusItemToggled:)];
    self.statusItemToggle.state = [defaults boolForKey:StatusItemEnabledDefaultsKey];
    self.keepRunningToggle = [NSButton checkboxWithTitle:@"关闭主窗口后继续在菜单栏运行（隐藏程序坞图标）" target:self
        action:@selector(statusItemToggled:)];
    self.keepRunningToggle.state = [defaults boolForKey:KeepRunningInMenuBarDefaultsKey];
    self.keepRunningToggle.enabled = self.statusItemToggle.state == NSControlStateValueOn;

    self.safariToggle = [NSButton checkboxWithTitle:@"以 Safari 浏览器身份打开网页（推荐）" target:self action:@selector(safariToggled:)];
    self.safariToggle.state = BrowserPreferredUserAgent() ? NSControlStateValueOn : NSControlStateValueOff;

    NSPopUpButton *release = PopUp(@[@[@"从不", @0], @[@"15 分钟", @15], @[@"30 分钟", @30], @[@"1 小时", @60], @[@"2 小时", @120]],
        [defaults integerForKey:ReleaseIdlePagesMinutesDefaultsKey], self, @selector(releaseIntervalChanged:));

    self.authField = [NSTextField new];
    self.authField.placeholderString = @"https://…";
    self.authField.usesSingleLineMode = NO;
    self.authField.cell.wraps = YES;
    self.authField.cell.scrollable = NO;
    self.authField.lineBreakMode = NSLineBreakByCharWrapping;
    self.authField.delegate = self;
    self.authField.stringValue = [defaults stringForKey:DefaultAuthorizationURLDefaultsKey] ?: @"";
    [self.authField.heightAnchor constraintEqualToConstant:52].active = YES;
    self.authNameField = [NSTextField new];
    self.authNameField.stringValue = AuthorizationDefaultAppName();
    self.authNameField.placeholderString = @"留空则按回调地址命名";
    self.authNameField.delegate = self;
    self.authError = DeskLabel(@"无法识别为 http:// 或 https:// 链接，未保存。", 11, NSFontWeightRegular);
    self.authError.textColor = NSColor.systemRedColor;
    self.authError.hidden = YES;

    return @[Title(@"菜单栏"), self.statusItemToggle, self.keepRunningToggle,
        Hint(@"菜单栏图标会列出需要处理的账号、30 天内的扣款与到期和每月支出，并可一键刷新用量。"), DeskSeparator(),
        Title(@"网页"), self.safariToggle,
        Hint(@"关闭后，ChatGPT 会把本应用识别为桌面客户端，只显示 Work 和 Codex，账单等设置也会要求前往网页版。修改后已打开的页面会重新载入。"),
        Row(@[DeskLabel(@"自动释放闲置的后台账号页面：", 13, NSFontWeightRegular), release]),
        Hint(@"切换账号后，之前的页面会在后台保留以便快速切回；超过设定时间未使用的页面会被释放以节省内存，再次打开时重新载入。"),
        DeskSeparator(),
        Title(@"授权记录的默认名称"), self.authNameField,
        Hint(@"用本应用授权成功后，新的授权记录使用这个名称，之后可以在账号详情中逐条修改。留空则按回调地址命名（例如 notion.so）。"),
        DeskSeparator(),
        Title(@"默认授权链接"), self.authField, self.authError,
        Hint(@"账号没有单独设置授权链接时，“打开授权链接”会预先填入此地址。每次授权都会生成新链接的第三方应用不需要设置，打开时粘贴最新链接即可。")];
}

- (void)statusItemToggled:(id)sender {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:self.statusItemToggle.state == NSControlStateValueOn forKey:StatusItemEnabledDefaultsKey];
    [defaults setBool:self.keepRunningToggle.state == NSControlStateValueOn forKey:KeepRunningInMenuBarDefaultsKey];
    self.keepRunningToggle.enabled = self.statusItemToggle.state == NSControlStateValueOn;
    [NSNotificationCenter.defaultCenter postNotificationName:StatusItemSettingsDidChangeNotification object:nil];
}

- (void)safariToggled:(id)sender {
    [NSUserDefaults.standardUserDefaults setBool:self.safariToggle.state == NSControlStateValueOn forKey:IdentifyAsSafariDefaultsKey];
    [NSNotificationCenter.defaultCenter postNotificationName:BrowserUserAgentPreferenceDidChangeNotification object:nil];
}

- (void)releaseIntervalChanged:(NSPopUpButton *)sender {
    [NSUserDefaults.standardUserDefaults setInteger:sender.selectedTag forKey:ReleaseIdlePagesMinutesDefaultsKey];
}

- (void)saveAuthorizationURL {
    NSString *text = [self.authField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (!text.length) {
        [defaults removeObjectForKey:DefaultAuthorizationURLDefaultsKey];
        self.authError.hidden = YES;
        return;
    }
    NSURL *url = AuthorizationURLFromText(text);
    self.authError.hidden = url != nil;
    if (!url) return;
    [defaults setObject:url.absoluteString forKey:DefaultAuthorizationURLDefaultsKey];
    self.authField.stringValue = url.absoluteString;
}

#pragma mark - Usage & notifications

- (NSArray<NSView *> *)usageRows {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSPopUpButton *refresh = PopUp(@[@[@"关闭", @0], @[@"每 6 小时", @360], @[@"每 12 小时", @720], @[@"每天", @1440]],
        UsageRefreshMinutes(), self, @selector(refreshIntervalChanged:));
    NSMutableArray *rows = [@[Title(@"用量"), Row(@[DeskLabel(@"自动刷新用量与订阅：", 13, NSFontWeightRegular), refresh]),
        Hint(@"使用各账号在本机已有的登录状态读取 5 小时 / 每周额度、续费日期与是否自动续订；未登录的账号会跳过。读取结果会记录近 8 天的趋势，用来预估额度何时用完。"),
        DeskSeparator(), Title(@"通知")] mutableCopy];
    NSArray *toggles = @[
        @[[NSString stringWithFormat:@"额度告急与恢复（5 小时或每周额度低于 %.0f%%）", AccountLowQuotaPercent], NotifyQuotaDefaultsKey],
        @[@"续费与到期提醒（不自动续费的提前 3 天和前一天，自动续费的前一天）", NotifyRenewalDefaultsKey],
        @[@"登录失效（曾经登录的账号被退出时）", NotifySignedOutDefaultsKey]];
    for (NSArray *toggle in toggles) {
        NSButton *checkbox = [NSButton checkboxWithTitle:toggle[0] target:self action:@selector(notificationToggled:)];
        checkbox.identifier = toggle[1];
        checkbox.state = [defaults boolForKey:toggle[1]] ? NSControlStateValueOn : NSControlStateValueOff;
        [rows addObject:checkbox];
    }
    self.notificationStatus = Hint(@"");
    NSButton *systemSettings = [NSButton buttonWithTitle:@"打开系统通知设置…" target:self action:@selector(openNotificationSettings:)];
    [rows addObjectsFromArray:@[Row(@[self.notificationStatus]), systemSettings]];
    return rows;
}

- (void)refreshIntervalChanged:(NSPopUpButton *)sender {
    [NSUserDefaults.standardUserDefaults setInteger:sender.selectedTag forKey:UsageRefreshMinutesDefaultsKey];
    [NSNotificationCenter.defaultCenter postNotificationName:UsageRefreshSettingsDidChangeNotification object:nil];
}

- (void)notificationToggled:(NSButton *)sender {
    [NSUserDefaults.standardUserDefaults setBool:sender.state == NSControlStateValueOn forKey:sender.identifier];
    [NSNotificationCenter.defaultCenter postNotificationName:AlertSettingsDidChangeNotification object:nil];
    [self.alerts start];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.alerts describeAuthorization:^(NSString *description, BOOL allowed) {
            self.notificationStatus.stringValue = description;
            self.notificationStatus.textColor = allowed ? NSColor.secondaryLabelColor : NSColor.systemOrangeColor;
        }];
    });
}

- (void)openNotificationSettings:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.Notifications-Settings.extension"]];
}

#pragma mark - Security

- (NSArray<NSView *> *)securityRows {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    self.lockToggle = [NSButton checkboxWithTitle:@"打开智枢矩阵时需要验证（Touch ID 或 Mac 登录密码）" target:self action:@selector(lockToggled:)];
    self.idlePopUp = PopUp(@[@[@"从不", @0], @[@"5 分钟", @5], @[@"15 分钟", @15], @[@"30 分钟", @30], @[@"1 小时", @60]],
        [defaults integerForKey:AppLockIdleMinutesDefaultsKey], self, @selector(idleChanged:));
    self.screenLockToggle = [NSButton checkboxWithTitle:@"屏幕锁定或电脑睡眠时立即锁定" target:self action:@selector(screenLockToggled:)];
    self.lockNowButton = [NSButton buttonWithTitle:@"立即锁定" target:self action:@selector(lockNow:)];
    self.lockStatus = Hint(@"");
    return @[Title(@"应用锁"), self.lockToggle,
        Row(@[DeskLabel(@"无操作或离开超过以下时间后锁定：", 13, NSFontWeightRegular), self.idlePopUp]),
        self.screenLockToggle, self.lockNowButton, self.lockStatus,
        Hint(@"锁定时会隐藏所有窗口，已打开的页面、自动刷新和提醒照常运行；菜单栏只显示“解锁”。关闭应用锁同样需要验证。")];
}

- (void)refreshSecurity {
    if (!self.lockToggle) return;
    NSString *reason = nil;
    BOOL available = [AppLock canAuthenticate:&reason];
    BOOL enabled = self.lock.enabled;
    self.lockToggle.enabled = available;
    self.lockToggle.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.idlePopUp.enabled = enabled;
    self.screenLockToggle.enabled = enabled;
    self.screenLockToggle.state = [NSUserDefaults.standardUserDefaults boolForKey:AppLockOnScreenLockDefaultsKey];
    self.lockNowButton.enabled = enabled;
    self.lockStatus.stringValue = available ? (enabled ? @"应用锁已开启。" : @"应用锁未开启。")
        : [NSString stringWithFormat:@"这台 Mac 无法验证身份：%@", reason ?: @"未设置登录密码"];
    self.lockStatus.textColor = available ? NSColor.secondaryLabelColor : NSColor.systemOrangeColor;
}

- (void)lockToggled:(NSButton *)sender {
    BOOL turnOn = sender.state == NSControlStateValueOn;
    sender.state = turnOn ? NSControlStateValueOff : NSControlStateValueOn;
    [AppLock authenticateWithReason:turnOn ? @"开启智枢矩阵应用锁" : @"关闭智枢矩阵应用锁" completion:^(BOOL success, NSString *failure) {
        if (success) {
            [NSUserDefaults.standardUserDefaults setBool:turnOn forKey:AppLockEnabledDefaultsKey];
            [NSNotificationCenter.defaultCenter postNotificationName:AppLockSettingsDidChangeNotification object:nil];
        } else if (failure) {
            self.lockStatus.stringValue = failure;
            self.lockStatus.textColor = NSColor.systemRedColor;
            return;
        }
        [self refreshSecurity];
    }];
}

- (void)idleChanged:(NSPopUpButton *)sender {
    [NSUserDefaults.standardUserDefaults setInteger:sender.selectedTag forKey:AppLockIdleMinutesDefaultsKey];
    [NSNotificationCenter.defaultCenter postNotificationName:AppLockSettingsDidChangeNotification object:nil];
}

- (void)screenLockToggled:(NSButton *)sender {
    [NSUserDefaults.standardUserDefaults setBool:sender.state == NSControlStateValueOn forKey:AppLockOnScreenLockDefaultsKey];
}

- (void)lockNow:(id)sender { [self.lock lock]; }

#pragma mark - Backup

- (NSTextField *)field:(NSString *)placeholder value:(NSString *)value {
    NSTextField *field = [NSTextField new];
    field.placeholderString = placeholder;
    field.stringValue = value ?: @"";
    field.delegate = self;
    [field.widthAnchor constraintEqualToConstant:360].active = YES;
    return field;
}

- (NSStackView *)formRow:(NSString *)caption field:(NSView *)field {
    NSTextField *label = DeskLabel(caption, 13, NSFontWeightRegular);
    label.alignment = NSTextAlignmentRight;
    [label.widthAnchor constraintEqualToConstant:84].active = YES;
    return Row(@[label, field]);
}

- (NSArray<NSView *> *)backupRows {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    self.autoBackupToggle = [NSButton checkboxWithTitle:@"账号资料变化后自动备份到本机（最多每小时一次，保留最近 30 份）"
        target:self action:@selector(autoBackupToggled:)];
    self.autoBackupToggle.state = [defaults boolForKey:AutoBackupDefaultsKey] ? NSControlStateValueOn : NSControlStateValueOff;
    self.localStatus = Hint(@"");
    NSButton *backupNow = [NSButton buttonWithTitle:@"立即备份" target:self action:@selector(backupNow:)];
    NSButton *reveal = [NSButton buttonWithTitle:@"在访达中显示" target:self action:@selector(revealBackups:)];
    NSButton *restoreLocal = [NSButton buttonWithTitle:@"从本机备份恢复…" target:self action:@selector(restoreLocal:)];

    NSString *username = [defaults stringForKey:WebDAVUsernameDefaultsKey] ?: @"";
    self.serverField = [self field:@"https://dav.jianguoyun.com/dav/" value:[defaults stringForKey:WebDAVServerDefaultsKey]];
    self.usernameField = [self field:@"用户名 / 邮箱" value:username];
    self.passwordField = [NSSecureTextField new];
    self.passwordField.placeholderString = @"密码或应用密码（保存在钥匙串）";
    self.passwordField.delegate = self;
    [self.passwordField.widthAnchor constraintEqualToConstant:360].active = YES;
    if (username.length && KeychainPassword(WebDAVKeychainService, username).length) self.passwordField.stringValue = @"••••••••";
    self.folderField = [self field:@"ZhishuMatrix" value:[defaults stringForKey:WebDAVFolderDefaultsKey]];
    self.webdavToggle = [NSButton checkboxWithTitle:@"自动备份时同时上传到 WebDAV（远端保留最近 30 份）" target:self
        action:@selector(webdavToggled:)];
    self.webdavToggle.state = [defaults boolForKey:WebDAVEnabledDefaultsKey] ? NSControlStateValueOn : NSControlStateValueOff;
    NSButton *test = [NSButton buttonWithTitle:@"测试连接" target:self action:@selector(testWebDAV:)];
    NSButton *upload = [NSButton buttonWithTitle:@"立即上传" target:self action:@selector(uploadNow:)];
    NSButton *restoreRemote = [NSButton buttonWithTitle:@"从 WebDAV 恢复…" target:self action:@selector(restoreRemote:)];
    self.webdavButtons = @[test, upload, restoreRemote];
    self.webdavStatus = Hint(@"");

    return @[Title(@"本机备份"), self.autoBackupToggle, Row(@[backupNow, reveal, restoreLocal]), self.localStatus,
        DeskSeparator(), Title(@"WebDAV"),
        [self formRow:@"服务器" field:self.serverField], [self formRow:@"用户名" field:self.usernameField],
        [self formRow:@"密码" field:self.passwordField], [self formRow:@"远程目录" field:self.folderField],
        self.webdavToggle, Row(@[test, upload, restoreRemote]), self.webdavStatus,
        Hint(@"备份只包含账号资料（名称、邮箱、订阅、分组、标签、备注、授权链接），不含密码、登录状态、访问令牌和代理密码。"
             "恢复会合并到当前列表：同一账号更新资料，列表中其他账号保留。坚果云请在“账户信息 → 安全选项”中生成第三方应用密码。")];
}

- (void)backupStateChanged:(NSNotification *)notification { [self refreshBackupStatus]; }

- (void)refreshBackupStatus {
    if (!self.localStatus) return;
    NSUInteger count = self.backup.localBackups.count;
    self.localStatus.stringValue = [NSString stringWithFormat:@"最近一次本机备份：%@ · 共 %lu 份 · 位于数据文件夹的 Backups 中",
        BackupTime(self.backup.lastLocalBackup), (unsigned long)count];
    NSString *status = nil;
    if (self.backup.isUploading) status = @"正在上传…";
    else if (self.backup.lastRemoteError) status = [@"上次上传失败：" stringByAppendingString:self.backup.lastRemoteError];
    else status = [@"最近一次上传：" stringByAppendingString:BackupTime(self.backup.lastRemoteBackup)];
    self.webdavStatus.stringValue = status;
    self.webdavStatus.textColor = self.backup.lastRemoteError && !self.backup.isUploading ? NSColor.systemRedColor : NSColor.secondaryLabelColor;
    for (NSButton *button in self.webdavButtons) button.enabled = !self.backup.isUploading;
}

- (void)autoBackupToggled:(NSButton *)sender {
    [NSUserDefaults.standardUserDefaults setBool:sender.state == NSControlStateValueOn forKey:AutoBackupDefaultsKey];
    if (sender.state == NSControlStateValueOn) [self.backup scheduleAutomaticBackup];
}

- (void)webdavToggled:(NSButton *)sender {
    [self saveWebDAVFields];
    [NSUserDefaults.standardUserDefaults setBool:sender.state == NSControlStateValueOn forKey:WebDAVEnabledDefaultsKey];
}

- (void)saveWebDAVFields {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSCharacterSet *spaces = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    NSString *previousUser = [defaults stringForKey:WebDAVUsernameDefaultsKey] ?: @"";
    NSString *user = [self.usernameField.stringValue stringByTrimmingCharactersInSet:spaces];
    [defaults setObject:[self.serverField.stringValue stringByTrimmingCharactersInSet:spaces] forKey:WebDAVServerDefaultsKey];
    [defaults setObject:user forKey:WebDAVUsernameDefaultsKey];
    NSString *folder = [self.folderField.stringValue stringByTrimmingCharactersInSet:spaces];
    if (folder.length) [defaults setObject:folder forKey:WebDAVFolderDefaultsKey];
    else [defaults removeObjectForKey:WebDAVFolderDefaultsKey];
    NSString *password = self.passwordField.stringValue;
    if (![user isEqualToString:previousUser]) {
        NSString *kept = KeychainPassword(WebDAVKeychainService, previousUser);
        KeychainSetPassword(nil, WebDAVKeychainService, previousUser);
        if ([password isEqualToString:@"••••••••"] && kept) KeychainSetPassword(kept, WebDAVKeychainService, user);
    }
    if (![password isEqualToString:@"••••••••"]) KeychainSetPassword(password, WebDAVKeychainService, user);
}

- (void)showWebDAVStatus:(NSString *)text failed:(BOOL)failed {
    self.webdavStatus.stringValue = text;
    self.webdavStatus.textColor = failed ? NSColor.systemRedColor : NSColor.systemGreenColor;
}

- (void)testWebDAV:(id)sender {
    [self commitEditing];
    [self saveWebDAVFields];
    WebDAVClient *client = [self.backup webDAVClient];
    if (!client) { [self showWebDAVStatus:@"请填写以 https:// 或 http:// 开头的服务器地址" failed:YES]; return; }
    self.webdavStatus.stringValue = @"正在连接…";
    self.webdavStatus.textColor = NSColor.secondaryLabelColor;
    [client prepareFolderWithCompletion:^(NSString *failure) {
        if (failure) { [self showWebDAVStatus:failure failed:YES]; return; }
        [client listFilesWithPrefix:BackupFilePrefix completion:^(NSArray<WebDAVFile *> *files, NSString *listFailure) {
            if (listFailure) [self showWebDAVStatus:listFailure failed:YES];
            else [self showWebDAVStatus:[NSString stringWithFormat:@"连接成功：%@ 中有 %lu 份备份", client.folderURL.path,
                (unsigned long)files.count] failed:NO];
        }];
    }];
}

- (void)uploadNow:(id)sender {
    [self commitEditing];
    [self saveWebDAVFields];
    NSError *error = nil;
    NSData *payload = [self.store exportDataForAccountIDs:nil error:&error];
    if (!payload) { [self showWebDAVStatus:error.localizedDescription ?: @"无法生成备份" failed:YES]; return; }
    [self.backup uploadData:payload completion:^(NSString *failure) {
        if (!failure) [self showWebDAVStatus:[@"已上传：" stringByAppendingString:BackupTime(NSDate.date)] failed:NO];
    }];
}

- (void)backupNow:(id)sender {
    NSError *error = nil;
    NSURL *file = [self.backup backupNow:&error];
    self.localStatus.stringValue = file ? [@"已备份为 " stringByAppendingString:file.lastPathComponent]
                                        : [@"备份失败：" stringByAppendingString:error.localizedDescription ?: @""];
    self.localStatus.textColor = file ? NSColor.systemGreenColor : NSColor.systemRedColor;
}

- (void)revealBackups:(id)sender {
    NSURL *latest = self.backup.localBackups.firstObject;
    if (latest) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[latest]];
    else {
        [NSFileManager.defaultManager createDirectoryAtURL:self.backup.directory withIntermediateDirectories:YES attributes:nil error:nil];
        [NSWorkspace.sharedWorkspace openURL:self.backup.directory];
    }
}

- (void)restoreLocal:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.directoryURL = self.backup.directory;
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"json"] ?: UTTypeData];
    panel.message = @"选择要恢复的备份文件。恢复会合并到当前账号列表。";
    panel.prompt = @"恢复";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK || !panel.URL) return;
        NSData *data = [NSData dataWithContentsOfURL:panel.URL];
        dispatch_async(dispatch_get_main_queue(), ^{ [self confirmRestoreData:data name:panel.URL.lastPathComponent]; });
    }];
}

- (void)restoreRemote:(id)sender {
    [self commitEditing];
    [self saveWebDAVFields];
    WebDAVClient *client = [self.backup webDAVClient];
    if (!client) { [self showWebDAVStatus:@"请先填写 WebDAV 服务器地址" failed:YES]; return; }
    self.webdavStatus.stringValue = @"正在读取备份列表…";
    self.webdavStatus.textColor = NSColor.secondaryLabelColor;
    [client listFilesWithPrefix:BackupFilePrefix completion:^(NSArray<WebDAVFile *> *files, NSString *failure) {
        if (failure || !files.count) {
            [self showWebDAVStatus:failure ?: @"WebDAV 目录中还没有备份" failed:YES];
            return;
        }
        [self refreshBackupStatus];
        NSPopUpButton *picker = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 360, 26)];
        NSByteCountFormatter *sizes = [NSByteCountFormatter new];
        for (WebDAVFile *file in files) {
            NSString *title = [NSString stringWithFormat:@"%@ · %@", BackupTime(file.modifiedAt),
                file.size ? [sizes stringFromByteCount:file.size] : file.name];
            [picker addItemWithTitle:title];
            picker.lastItem.representedObject = file.name;
            picker.lastItem.toolTip = file.name;
        }
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"从 WebDAV 恢复";
        alert.informativeText = [NSString stringWithFormat:@"%@ 中有 %lu 份备份，选择要恢复的一份。", client.folderURL.path,
            (unsigned long)files.count];
        alert.accessoryView = picker;
        [alert addButtonWithTitle:@"下载并恢复…"];
        [alert addButtonWithTitle:@"取消"];
        [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
            if (response != NSAlertFirstButtonReturn) return;
            NSString *name = picker.selectedItem.representedObject;
            self.webdavStatus.stringValue = @"正在下载…";
            [client downloadName:name completion:^(NSData *data, NSString *downloadFailure) {
                if (!data) { [self showWebDAVStatus:downloadFailure ?: @"下载失败" failed:YES]; return; }
                [self refreshBackupStatus];
                [self confirmRestoreData:data name:name];
            }];
        }];
    }];
}

- (void)confirmRestoreData:(NSData *)data name:(NSString *)name {
    NSDictionary *payload = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSArray *accounts = [payload isKindOfClass:NSDictionary.class] ? payload[@"accounts"] : nil;
    if (![accounts isKindOfClass:NSArray.class]) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"无法恢复";
        alert.informativeText = [NSString stringWithFormat:@"“%@”不是智枢矩阵的备份文件。", name];
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
        return;
    }
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"恢复“%@”？", name];
    alert.informativeText = [NSString stringWithFormat:@"备份中有 %lu 个账号，会合并到当前的 %lu 个账号中：同一账号更新资料，"
        "备份里没有的账号保留。恢复前会先把当前列表备份到本机。", (unsigned long)accounts.count, (unsigned long)self.store.accounts.count];
    [alert addButtonWithTitle:@"恢复"];
    [alert addButtonWithTitle:@"取消"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        if (self.store.accounts.count) [self.backup backupNow:nil];
        NSError *error = nil;
        NSUInteger added = 0, updated = 0;
        BOOL imported = [self.store importData:data added:&added updated:&updated error:&error];
        if (imported) [self.store commit];
        NSAlert *result = [NSAlert new];
        result.messageText = imported ? @"恢复完成" : @"无法恢复";
        result.informativeText = imported
            ? [NSString stringWithFormat:@"新增 %lu 个账号，更新 %lu 个账号。新增的账号需要在 ChatGPT 页面重新登录。",
                (unsigned long)added, (unsigned long)updated]
            : error.localizedDescription ?: @"";
        dispatch_async(dispatch_get_main_queue(), ^{ [result beginSheetModalForWindow:self.window completionHandler:nil]; });
    }];
}

#pragma mark - Cost

- (NSArray<NSView *> *)costRows {
    self.ratesStack = [NSStackView new];
    self.ratesStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.ratesStack.alignment = NSLayoutAttributeLeading;
    self.ratesStack.spacing = 8;
    self.rateFields = [NSMutableDictionary dictionary];
    self.pendingCurrencies = [NSMutableSet set];
    self.currencyPicker = [NSComboBox new];
    [self.currencyPicker addItemsWithObjectValues:@[@"USD", @"PHP", @"HKD", @"TWD", @"EUR", @"GBP", @"JPY", @"SGD", @"KRW", @"TRY",
        @"INR", @"BRL", @"NGN", @"MYR", @"THB"]];
    self.currencyPicker.placeholderString = @"币种代码";
    [self.currencyPicker.widthAnchor constraintEqualToConstant:110].active = YES;
    NSButton *add = [NSButton buttonWithTitle:@"添加币种" target:self action:@selector(addCurrency:)];
    [self rebuildRates];
    return @[Title(@"汇率（换算为人民币）"), self.ratesStack, Row(@[self.currencyPicker, add]),
        Hint(@"所有费用统一折合为人民币显示与汇总：每月支出、续费日历、菜单栏和付款记录。汇率按“1 单位外币 = 多少人民币”填写，"
             "需要手动维护；没有填写汇率的币种不计入人民币合计，并会提示“未设汇率”。账号或付款记录中用到的币种会自动列出。")];
}

/// Currencies in use plus those with a saved rate, CNY excluded.
- (NSArray<NSString *> *)currenciesForRates {
    NSMutableOrderedSet *codes = [NSMutableOrderedSet orderedSet];
    for (Account *account in self.store.accounts) {
        if (account.monthlyPrice && account.currency.length) [codes addObject:account.currency];
        for (AccountPayment *payment in account.payments) if (payment.currency.length) [codes addObject:payment.currency];
    }
    [codes addObjectsFromArray:AccountExchangeRates().allKeys];
    [codes addObjectsFromArray:self.pendingCurrencies.allObjects];
    [codes removeObject:@"CNY"];
    [codes removeObject:@"RMB"];
    return [codes.array sortedArrayUsingSelector:@selector(compare:)];
}

- (void)rebuildRates {
    for (NSView *view in self.ratesStack.arrangedSubviews.copy) [view removeFromSuperview];
    [self.rateFields removeAllObjects];
    NSDictionary *rates = AccountExchangeRates();
    NSArray *codes = [self currenciesForRates];
    if (!codes.count) [self.ratesStack addArrangedSubview:Hint(@"还没有外币。为账号填写月费和币种，或在下方添加。")];
    NSNumberFormatter *formatter = [NSNumberFormatter new];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    formatter.minimum = @0;
    formatter.maximumFractionDigits = 6;
    formatter.lenient = YES;
    for (NSString *code in codes) {
        NSTextField *label = DeskLabel([NSString stringWithFormat:@"1 %@ =", code], 13, NSFontWeightMedium);
        label.font = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightMedium];
        [label.widthAnchor constraintEqualToConstant:84].active = YES;
        NSTextField *field = [NSTextField new];
        field.formatter = formatter;
        field.placeholderString = @"未设置";
        field.objectValue = rates[code];
        field.delegate = self;
        field.identifier = code;
        [field.widthAnchor constraintEqualToConstant:120].active = YES;
        self.rateFields[code] = field;
        NSTextField *unit = DeskLabel(@"人民币", 13, NSFontWeightRegular);
        NSTextField *state = DeskLabel(rates[code] ? @"" : @"未设汇率，不计入合计", 11, NSFontWeightRegular);
        state.textColor = NSColor.systemOrangeColor;
        [self.ratesStack addArrangedSubview:Row(@[label, field, unit, state])];
    }
}

- (void)saveRateField:(NSTextField *)field {
    NSMutableDictionary *saved = [[NSUserDefaults.standardUserDefaults dictionaryForKey:ExchangeRatesDefaultsKey] mutableCopy]
        ?: [NSMutableDictionary dictionary];
    NSNumber *rate = [field.objectValue isKindOfClass:NSNumber.class] && [field.objectValue doubleValue] > 0 ? field.objectValue : nil;
    if ([saved[field.identifier] isEqual:rate] || (!rate && !saved[field.identifier])) return;
    if (rate) saved[field.identifier] = rate; else [saved removeObjectForKey:field.identifier];
    [NSUserDefaults.standardUserDefaults setObject:saved forKey:ExchangeRatesDefaultsKey];
    [NSNotificationCenter.defaultCenter postNotificationName:ExchangeRatesDidChangeNotification object:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self rebuildRates];
        [self.tabs fitItem:self.tabs.tabView.selectedTabViewItem];
    });
}

- (void)addCurrency:(id)sender {
    NSString *code = [[self.currencyPicker.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] uppercaseString];
    if (code.length != 3 || [code isEqualToString:@"CNY"]) { NSBeep(); return; }
    self.currencyPicker.stringValue = @"";
    // Listed with an empty rate until one is typed in.
    [self.pendingCurrencies addObject:code];
    [self rebuildRates];
    [self.tabs fitItem:self.tabs.tabView.selectedTabViewItem];
    [self.window makeFirstResponder:self.rateFields[code]];
}

#pragma mark - Network

- (NSArray<NSView *> *)networkRows {
    self.proxyField = [NSTextField new];
    self.proxyField.placeholderString = @"留空跟随系统代理，例如 http://127.0.0.1:7890";
    self.proxyField.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    self.proxyField.stringValue = [NSUserDefaults.standardUserDefaults stringForKey:DefaultProxyDefaultsKey] ?: @"";
    self.proxyField.delegate = self;
    [self.proxyField.widthAnchor constraintEqualToConstant:360].active = YES;
    self.proxyTestButton = [NSButton buttonWithTitle:@"测试连接" target:self action:@selector(testProxy:)];
    self.proxyResult = Hint(@"");
    return @[Title(@"默认代理"), Row(@[self.proxyField, self.proxyTestButton]), self.proxyResult,
        Hint(@"支持 http://、https:// 和 socks5:// 代理，可带用户名和密码（user:pass@host:port）。留空时跟随 macOS 的系统代理设置"
             "（如 Clash、Surge 开启的系统代理）。代理作用于账号页面、用量与账单读取以及授权窗口；单个账号可在右侧详情的“网络”中单独设置。"
             "“测试连接”会显示 chatgpt.com 看到的出口 IP 与地区。")];
}

- (void)saveProxy {
    NSString *text = [self.proxyField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (text.length && !AccountProxyComponents(text)) {
        self.proxyResult.stringValue = @"无法识别代理地址，未保存。示例：http://127.0.0.1:7890、socks5://127.0.0.1:1080";
        self.proxyResult.textColor = NSColor.systemRedColor;
        return;
    }
    if ([text isEqualToString:[defaults stringForKey:DefaultProxyDefaultsKey] ?: @""]) return;
    if (text.length) [defaults setObject:text forKey:DefaultProxyDefaultsKey];
    else [defaults removeObjectForKey:DefaultProxyDefaultsKey];
    self.proxyField.stringValue = text;
    self.proxyResult.stringValue = @"已保存，正在使用默认代理的账号页面会重新载入。";
    self.proxyResult.textColor = NSColor.secondaryLabelColor;
    [NSNotificationCenter.defaultCenter postNotificationName:ProxySettingsDidChangeNotification object:nil];
}

- (void)testProxy:(id)sender {
    [self commitEditing];
    NSString *proxy = [NSUserDefaults.standardUserDefaults stringForKey:DefaultProxyDefaultsKey] ?: @"";
    self.proxyTestButton.enabled = NO;
    self.proxyResult.stringValue = proxy.length ? [NSString stringWithFormat:@"正在通过 %@ 连接 chatgpt.com…", proxy]
                                                : @"正在按系统代理设置连接 chatgpt.com…";
    self.proxyResult.textColor = NSColor.secondaryLabelColor;
    [ProxyCheck checkProxyText:proxy completion:^(NSString *summary, NSString *failure) {
        self.proxyTestButton.enabled = YES;
        self.proxyResult.stringValue = summary ?: failure;
        self.proxyResult.textColor = failure ? NSColor.systemRedColor
            : ([summary containsString:@"不支持"] ? NSColor.systemOrangeColor : NSColor.systemGreenColor);
    }];
}

#pragma mark - Editing

- (void)controlTextDidEndEditing:(NSNotification *)notification {
    id field = notification.object;
    if ([self.rateFields.allValues containsObject:field]) { [self saveRateField:field]; return; }
    if (field == self.authField) [self saveAuthorizationURL];
    else if (field == self.authNameField)
        [NSUserDefaults.standardUserDefaults setObject:[self.authNameField.stringValue
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] forKey:AuthorizationDefaultAppNameDefaultsKey];
    else if (field == self.proxyField) [self saveProxy];
    else if (field == self.serverField || field == self.usernameField || field == self.passwordField || field == self.folderField)
        [self saveWebDAVFields];
}

- (void)commitEditing {
    if ([self.window.firstResponder isKindOfClass:NSTextView.class]) [self.window makeFirstResponder:nil];
}

- (void)windowWillClose:(NSNotification *)notification { [self commitEditing]; }
@end
