#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

static NSURL *HomeURL(void) { return [NSURL URLWithString:@"https://chatgpt.com/"]; }

@interface FlippedView : NSView
@end
@implementation FlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface BrowserSession : NSObject <WKNavigationDelegate, WKUIDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) NSMutableDictionary<NSValue *, NSWindow *> *popups;
@property (nonatomic, copy) void (^navigationChanged)(void);
@property (nonatomic, copy) void (^pageReady)(void);
- (instancetype)initWithIdentifier:(NSUUID *)identifier;
- (void)invalidate;
@end

@implementation BrowserSession
- (instancetype)initWithIdentifier:(NSUUID *)identifier {
    if ((self = [super init])) {
        WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
        configuration.websiteDataStore = [WKWebsiteDataStore dataStoreForIdentifier:identifier];
        _webView = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:configuration];
        _webView.navigationDelegate = self;
        _webView.UIDelegate = self;
        _webView.allowsBackForwardNavigationGestures = YES;
        _popups = [NSMutableDictionary dictionary];
        [_webView loadRequest:[NSURLRequest requestWithURL:HomeURL()]];
    }
    return self;
}
- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
    if (webView == self.webView && self.navigationChanged) self.navigationChanged();
}
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    if (webView == self.webView) {
        if (self.navigationChanged) self.navigationChanged();
        if (self.pageReady) self.pageReady();
    }
}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if (webView == self.webView && error.code != NSURLErrorCancelled) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"页面加载失败";
        alert.informativeText = error.localizedDescription;
        [alert runModal];
    }
    if (webView == self.webView && self.navigationChanged) self.navigationChanged();
}
- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
   forNavigationAction:(WKNavigationAction *)navigationAction windowFeatures:(WKWindowFeatures *)windowFeatures {
    WKWebView *popup = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 780, 680) configuration:configuration];
    popup.navigationDelegate = self;
    popup.UIDelegate = self;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:popup.frame
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    window.title = @"ChatGPT 登录";
    window.contentView = popup;
    [window center];
    [window makeKeyAndOrderFront:nil];
    self.popups[[NSValue valueWithNonretainedObject:popup]] = window;
    return popup;
}
- (void)webViewDidClose:(WKWebView *)webView {
    NSValue *key = [NSValue valueWithNonretainedObject:webView];
    [self.popups[key] close];
    [self.popups removeObjectForKey:key];
}
- (void)invalidate {
    for (NSWindow *window in self.popups.allValues) [window close];
    [self.popups removeAllObjects];
    self.webView.navigationDelegate = nil;
    self.webView.UIDelegate = nil;
}
@end

@interface AppController : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) NSView *sidebar;
@property (nonatomic, strong) NSView *browserArea;
@property (nonatomic, strong) NSView *toolbar;
@property (nonatomic, strong) NSStackView *accountList;
@property (nonatomic, strong) NSTextField *nameField;
@property (nonatomic, strong) NSTextField *emailField;
@property (nonatomic, strong) NSPopUpButton *planPicker;
@property (nonatomic, strong) NSButton *dateToggle;
@property (nonatomic, strong) NSDatePicker *datePicker;
@property (nonatomic, strong) NSTextField *sourceLabel;
@property (nonatomic, strong) NSButton *syncButton;
@property (nonatomic, strong) NSButton *sessionButton;
@property (nonatomic, strong) NSButton *saveButton;
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *hostLabel;
@property (nonatomic, strong) NSButton *backButton;
@property (nonatomic, strong) NSButton *forwardButton;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *accounts;
@property (nonatomic, strong) NSMutableDictionary<NSString *, BrowserSession *> *sessions;
@property (nonatomic, copy) NSString *selectedID;
@property (nonatomic, strong) NSURL *accountsURL;
@end

@implementation AppController
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [self buildMenus];
    NSString *iconPath = [NSBundle.mainBundle pathForResource:@"AppIcon" ofType:@"icns"];
    NSImage *icon = [[NSImage alloc] initWithContentsOfFile:iconPath];
    if (icon) NSApp.applicationIconImage = icon;
    self.sessions = [NSMutableDictionary dictionary];
    NSURL *support = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *directory = [support URLByAppendingPathComponent:@"ChatGPTAccountDesk" isDirectory:YES];
    NSError *error = nil;
    [[NSFileManager defaultManager] createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error];
    self.accountsURL = [directory URLByAppendingPathComponent:@"accounts.json"];
    NSData *data = [NSData dataWithContentsOfURL:self.accountsURL];
    NSArray *saved = data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&error] : nil;
    self.accounts = [saved isKindOfClass:NSArray.class] ? [saved mutableCopy] : [NSMutableArray array];
    NSString *previousSelection = [NSUserDefaults.standardUserDefaults stringForKey:@"selectedAccountID"];
    for (NSDictionary *account in self.accounts) {
        if ([account[@"id"] isEqualToString:previousSelection]) self.selectedID = previousSelection;
    }
    if (!self.selectedID) self.selectedID = self.accounts.firstObject[@"id"];
    [self buildWindow];
    [self refreshAccounts];
    [self showSelected];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }

- (void)buildMenus {
    NSMenu *mainMenu = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new];
    [mainMenu addItem:appItem];
    NSMenu *appMenu = [NSMenu new];
    appItem.submenu = appMenu;
    [appMenu addItemWithTitle:@"退出 ChatGPT Account Desk" action:@selector(terminate:) keyEquivalent:@"q"];

    NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:@"编辑" action:nil keyEquivalent:@""];
    [mainMenu addItem:editItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"编辑"];
    editItem.submenu = editMenu;
    [editMenu addItemWithTitle:@"撤销" action:@selector(undo:) keyEquivalent:@"z"];
    NSMenuItem *redo = [editMenu addItemWithTitle:@"重做" action:@selector(redo:) keyEquivalent:@"z"];
    redo.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"剪切" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"复制" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"粘贴" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"全选" action:@selector(selectAll:) keyEquivalent:@"a"];
    NSApp.mainMenu = mainMenu;
}

- (NSTextField *)label:(NSString *)text size:(CGFloat)size weight:(NSFontWeight)weight {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

- (NSButton *)iconButton:(NSString *)symbol tooltip:(NSString *)tooltip action:(SEL)action {
    NSButton *button = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tooltip]
        target:self action:action];
    button.bordered = NO;
    button.toolTip = tooltip;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.widthAnchor constraintEqualToConstant:32].active = YES;
    [button.heightAnchor constraintEqualToConstant:32].active = YES;
    return button;
}

- (void)buildWindow {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1240, 780)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"ChatGPT Account Desk";
    self.window.minSize = NSMakeSize(940, 640);
    [self.window center];

    NSView *root = [NSView new];
    root.wantsLayer = YES;
    self.window.contentView = root;
    self.sidebar = [NSView new];
    self.sidebar.wantsLayer = YES;
    self.sidebar.layer.backgroundColor = NSColor.controlBackgroundColor.CGColor;
    self.browserArea = [NSView new];
    for (NSView *view in @[self.sidebar, self.browserArea]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [root addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [self.browserArea.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [self.browserArea.trailingAnchor constraintEqualToAnchor:self.sidebar.leadingAnchor],
        [self.sidebar.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [self.sidebar.topAnchor constraintEqualToAnchor:root.topAnchor],
        [self.sidebar.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [self.sidebar.widthAnchor constraintEqualToConstant:320],
        [self.browserArea.topAnchor constraintEqualToAnchor:root.topAnchor],
        [self.browserArea.bottomAnchor constraintEqualToAnchor:root.bottomAnchor]
    ]];

    NSTextField *heading = [self label:@"账号列表" size:16 weight:NSFontWeightSemibold];
    NSButton *add = [self iconButton:@"plus" tooltip:@"添加账号" action:@selector(addAccount:)];
    NSScrollView *scroll = [NSScrollView new];
    scroll.hasVerticalScroller = YES;
    scroll.drawsBackground = NO;
    FlippedView *document = [FlippedView new];
    self.accountList = [NSStackView new];
    self.accountList.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.accountList.alignment = NSLayoutAttributeLeading;
    self.accountList.spacing = 4;
    self.accountList.translatesAutoresizingMaskIntoConstraints = NO;
    document.translatesAutoresizingMaskIntoConstraints = NO;
    [document addSubview:self.accountList];
    scroll.documentView = document;
    [NSLayoutConstraint activateConstraints:@[
        [document.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
        [document.heightAnchor constraintGreaterThanOrEqualToAnchor:scroll.contentView.heightAnchor],
        [self.accountList.leadingAnchor constraintEqualToAnchor:document.leadingAnchor],
        [self.accountList.trailingAnchor constraintEqualToAnchor:document.trailingAnchor],
        [self.accountList.topAnchor constraintEqualToAnchor:document.topAnchor],
        [self.accountList.bottomAnchor constraintLessThanOrEqualToAnchor:document.bottomAnchor]
    ]];
    NSBox *divider = [NSBox new];
    divider.boxType = NSBoxSeparator;
    NSView *details = [self buildDetails];
    NSTextField *footer = [self label:@"会话仅保存在本机" size:11 weight:NSFontWeightRegular];
    footer.textColor = NSColor.secondaryLabelColor;
    for (NSView *view in @[heading, add, scroll, divider, details, footer]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [self.sidebar addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [heading.leadingAnchor constraintEqualToAnchor:self.sidebar.leadingAnchor constant:17],
        [heading.topAnchor constraintEqualToAnchor:self.sidebar.topAnchor constant:23],
        [add.trailingAnchor constraintEqualToAnchor:self.sidebar.trailingAnchor constant:-13],
        [add.centerYAnchor constraintEqualToAnchor:heading.centerYAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.sidebar.leadingAnchor constant:12],
        [scroll.trailingAnchor constraintEqualToAnchor:self.sidebar.trailingAnchor constant:-12],
        [scroll.topAnchor constraintEqualToAnchor:heading.bottomAnchor constant:17],
        [scroll.heightAnchor constraintEqualToConstant:174],
        [divider.leadingAnchor constraintEqualToAnchor:self.sidebar.leadingAnchor],
        [divider.trailingAnchor constraintEqualToAnchor:self.sidebar.trailingAnchor],
        [divider.topAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:14],
        [details.leadingAnchor constraintEqualToAnchor:self.sidebar.leadingAnchor constant:16],
        [details.trailingAnchor constraintEqualToAnchor:self.sidebar.trailingAnchor constant:-16],
        [details.topAnchor constraintEqualToAnchor:divider.bottomAnchor constant:16],
        [details.bottomAnchor constraintLessThanOrEqualToAnchor:footer.topAnchor constant:-12],
        [footer.leadingAnchor constraintEqualToAnchor:self.sidebar.leadingAnchor constant:16],
        [footer.bottomAnchor constraintEqualToAnchor:self.sidebar.bottomAnchor constant:-16]
    ]];

    self.toolbar = [NSView new];
    self.toolbar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.browserArea addSubview:self.toolbar];
    self.titleLabel = [self label:@"" size:14 weight:NSFontWeightSemibold];
    self.hostLabel = [self label:@"chatgpt.com" size:11 weight:NSFontWeightRegular];
    self.hostLabel.textColor = NSColor.secondaryLabelColor;
    self.hostLabel.alignment = NSTextAlignmentRight;
    self.backButton = [self iconButton:@"chevron.left" tooltip:@"后退" action:@selector(goBack:)];
    self.forwardButton = [self iconButton:@"chevron.right" tooltip:@"前进" action:@selector(goForward:)];
    NSButton *reload = [self iconButton:@"arrow.clockwise" tooltip:@"刷新" action:@selector(reload:)];
    NSButton *home = [self iconButton:@"house" tooltip:@"ChatGPT 首页" action:@selector(goHome:)];
    NSStackView *tools = [NSStackView stackViewWithViews:@[self.backButton, self.forwardButton, reload, home]];
    tools.spacing = 5;
    for (NSView *view in @[self.titleLabel, tools, self.hostLabel]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [self.toolbar addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [self.toolbar.leadingAnchor constraintEqualToAnchor:self.browserArea.leadingAnchor],
        [self.toolbar.trailingAnchor constraintEqualToAnchor:self.browserArea.trailingAnchor],
        [self.toolbar.topAnchor constraintEqualToAnchor:self.browserArea.topAnchor],
        [self.toolbar.heightAnchor constraintEqualToConstant:52],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.toolbar.leadingAnchor constant:17],
        [self.titleLabel.centerYAnchor constraintEqualToAnchor:self.toolbar.centerYAnchor],
        [self.titleLabel.widthAnchor constraintLessThanOrEqualToConstant:180],
        [tools.leadingAnchor constraintEqualToAnchor:self.titleLabel.trailingAnchor constant:18],
        [tools.centerYAnchor constraintEqualToAnchor:self.toolbar.centerYAnchor],
        [self.hostLabel.trailingAnchor constraintEqualToAnchor:self.toolbar.trailingAnchor constant:-17],
        [self.hostLabel.centerYAnchor constraintEqualToAnchor:self.toolbar.centerYAnchor],
        [self.hostLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:tools.trailingAnchor constant:8]
    ]];
}

- (NSView *)buildDetails {
    NSStackView *form = [NSStackView new];
    form.orientation = NSUserInterfaceLayoutOrientationVertical;
    form.alignment = NSLayoutAttributeLeading;
    form.spacing = 7;

    NSTextField *heading = [self label:@"账号信息" size:14 weight:NSFontWeightSemibold];
    self.nameField = [NSTextField new];
    self.nameField.placeholderString = @"账号名称";
    self.emailField = [NSTextField new];
    self.emailField.placeholderString = @"邮箱（可选）";
    self.planPicker = [NSPopUpButton new];
    [self.planPicker addItemsWithTitles:@[@"未获取", @"Free", @"Go", @"Plus", @"Pro", @"Business", @"Enterprise", @"Edu"]];
    self.dateToggle = [NSButton checkboxWithTitle:@"设置到期日期" target:self action:@selector(toggleDate:)];
    self.datePicker = [NSDatePicker new];
    self.datePicker.datePickerStyle = NSDatePickerStyleTextFieldAndStepper;
    self.datePicker.datePickerElements = NSDatePickerElementFlagYearMonthDay;
    self.datePicker.enabled = NO;
    self.sourceLabel = [self label:@"状态：未获取" size:11 weight:NSFontWeightRegular];
    self.sourceLabel.textColor = NSColor.secondaryLabelColor;
    self.syncButton = [NSButton buttonWithTitle:@"从当前页面读取" target:self action:@selector(syncSubscription:)];
    self.syncButton.toolTip = @"先在 ChatGPT 打开账号设置中的订阅信息";
    self.sessionButton = [NSButton buttonWithTitle:@"查看当前会话" target:self action:@selector(showCurrentSession:)];
    self.sessionButton.image = [NSImage imageWithSystemSymbolName:@"key.horizontal" accessibilityDescription:nil];
    self.sessionButton.imagePosition = NSImageLeft;
    self.sessionButton.toolTip = @"读取当前账号的 chatgpt.com/api/auth/session 响应";
    self.saveButton = [NSButton buttonWithTitle:@"保存" target:self action:@selector(saveDetails:)];

    NSStackView *actions = [NSStackView stackViewWithViews:@[self.syncButton, self.saveButton]];
    actions.spacing = 8;
    for (NSView *view in @[
        heading,
        [self label:@"名称" size:11 weight:NSFontWeightMedium], self.nameField,
        [self label:@"邮箱" size:11 weight:NSFontWeightMedium], self.emailField,
        [self label:@"订阅级别" size:11 weight:NSFontWeightMedium], self.planPicker,
        self.dateToggle, self.datePicker, self.sourceLabel, actions, self.sessionButton
    ]) {
        [form addArrangedSubview:view];
    }
    for (NSView *view in @[self.nameField, self.emailField, self.planPicker, self.datePicker]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [view.widthAnchor constraintEqualToConstant:288].active = YES;
    }
    return form;
}

- (void)refreshDetails {
    NSDictionary *account = [self selectedAccount];
    BOOL hasAccount = account != nil;
    self.nameField.enabled = hasAccount;
    self.emailField.enabled = hasAccount;
    self.planPicker.enabled = hasAccount;
    self.dateToggle.enabled = hasAccount;
    self.syncButton.enabled = hasAccount;
    self.sessionButton.enabled = hasAccount;
    self.saveButton.enabled = hasAccount;
    self.nameField.stringValue = account[@"name"] ?: @"";
    self.emailField.stringValue = account[@"email"] ?: @"";
    NSString *plan = account[@"plan"] ?: @"未获取";
    if ([self.planPicker itemWithTitle:plan]) [self.planPicker selectItemWithTitle:plan];
    else [self.planPicker selectItemWithTitle:@"未获取"];
    NSString *date = account[@"expiresAt"];
    self.dateToggle.state = date.length ? NSControlStateValueOn : NSControlStateValueOff;
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateFormat = @"yyyy-MM-dd";
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    self.datePicker.dateValue = [formatter dateFromString:date] ?: NSDate.date;
    self.datePicker.enabled = hasAccount && date.length > 0;
    [self updateSourceLabelForAccount:account];
}

- (void)updateSourceLabelForAccount:(NSDictionary *)account {
    NSString *planSource = account[@"planSource"];
    NSString *expirySource = account[@"expirySource"];
    NSString *planStatus = [planSource isEqualToString:@"page"] ? @"页面" :
        ([planSource isEqualToString:@"manual"] ? @"手动" : @"未获取");
    NSString *expiryStatus = [expirySource isEqualToString:@"page"] ? @"页面" :
        ([expirySource isEqualToString:@"manual"] ? @"手动" : @"未获取");
    self.sourceLabel.stringValue = [NSString stringWithFormat:@"订阅：%@ · 到期：%@", planStatus, expiryStatus];
}

- (void)toggleDate:(id)sender {
    self.datePicker.enabled = self.dateToggle.state == NSControlStateValueOn;
}

- (void)saveDetails:(id)sender {
    NSMutableDictionary *account = [self selectedAccount];
    if (!account) return;
    NSString *name = [self.nameField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!name.length) { [self showError:@"名称不能为空" detail:@"请输入账号名称。"] ; return; }
    account[@"name"] = name;
    account[@"email"] = [self.emailField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    account[@"plan"] = self.planPicker.titleOfSelectedItem ?: @"未获取";
    if ([account[@"plan"] isEqualToString:@"未获取"]) [account removeObjectForKey:@"planSource"];
    else account[@"planSource"] = @"manual";
    if (self.dateToggle.state == NSControlStateValueOn) {
        NSDateFormatter *formatter = [NSDateFormatter new];
        formatter.dateFormat = @"yyyy-MM-dd";
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        account[@"expiresAt"] = [formatter stringFromDate:self.datePicker.dateValue];
        account[@"expirySource"] = @"manual";
    } else {
        [account removeObjectForKey:@"expiresAt"];
        [account removeObjectForKey:@"expirySource"];
    }
    [self saveAccounts]; [self refreshAccounts]; [self refreshDetails];
    self.titleLabel.stringValue = name;
}

- (void)saveAccounts {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.accounts options:NSJSONWritingPrettyPrinted error:&error];
    if (!error) [data writeToURL:self.accountsURL options:NSDataWritingAtomic error:&error];
    if (error) [self showError:@"无法保存账号列表" detail:error.localizedDescription];
}

- (void)showError:(NSString *)title detail:(NSString *)detail {
    NSAlert *alert = [NSAlert new];
    alert.messageText = title;
    alert.informativeText = detail;
    [alert runModal];
}

- (NSMutableDictionary *)selectedAccount {
    for (NSMutableDictionary *account in self.accounts)
        if ([account[@"id"] isEqualToString:self.selectedID]) return account;
    return nil;
}

- (BrowserSession *)selectedSession {
    if (!self.selectedID) return nil;
    BrowserSession *session = self.sessions[self.selectedID];
    if (!session) {
        session = [[BrowserSession alloc] initWithIdentifier:[[NSUUID alloc] initWithUUIDString:self.selectedID]];
        __weak typeof(self) weakSelf = self;
        session.navigationChanged = ^{ [weakSelf updateNavigation]; };
        NSString *identifier = [self.selectedID copy];
        session.pageReady = ^{ [weakSelf schedulePlanReadForAccountID:identifier]; };
        self.sessions[self.selectedID] = session;
    }
    return session;
}

- (void)refreshAccounts {
    for (NSView *view in self.accountList.arrangedSubviews.copy) {
        [self.accountList removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    for (NSMutableDictionary *account in self.accounts) {
        BOOL selected = [account[@"id"] isEqualToString:self.selectedID];
        NSView *row = [NSView new];
        row.wantsLayer = YES;
        row.layer.cornerRadius = 6;
        row.layer.backgroundColor = selected ? [NSColor.controlAccentColor colorWithAlphaComponent:0.14].CGColor : NSColor.clearColor.CGColor;
        NSButton *button = [NSButton buttonWithTitle:account[@"name"] target:self action:@selector(selectAccount:)];
        button.identifier = account[@"id"];
        button.bordered = NO;
        button.alignment = NSTextAlignmentLeft;
        button.lineBreakMode = NSLineBreakByTruncatingTail;
        button.image = [NSImage imageWithSystemSymbolName:@"person.crop.circle.fill" accessibilityDescription:nil];
        button.imagePosition = NSImageLeft;
        NSString *planText = account[@"plan"];
        if (!planText.length || [planText isEqualToString:@"未获取"]) planText = @"未获取订阅";
        NSTextField *plan = [self label:planText size:10 weight:NSFontWeightRegular];
        plan.textColor = NSColor.secondaryLabelColor;
        NSButton *more = [self iconButton:@"ellipsis" tooltip:@"账号操作" action:@selector(showAccountMenu:)];
        more.identifier = account[@"id"];
        for (NSView *view in @[button, plan, more]) { view.translatesAutoresizingMaskIntoConstraints = NO; [row addSubview:view]; }
        row.translatesAutoresizingMaskIntoConstraints = NO;
        [self.accountList addArrangedSubview:row];
        [NSLayoutConstraint activateConstraints:@[
            [row.widthAnchor constraintEqualToAnchor:self.accountList.widthAnchor],
            [row.heightAnchor constraintEqualToConstant:52],
            [button.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:9],
            [button.trailingAnchor constraintEqualToAnchor:more.leadingAnchor constant:-4],
            [button.topAnchor constraintEqualToAnchor:row.topAnchor constant:5],
            [plan.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:32],
            [plan.trailingAnchor constraintEqualToAnchor:more.leadingAnchor constant:-4],
            [plan.topAnchor constraintEqualToAnchor:button.bottomAnchor constant:1],
            [more.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-4],
            [more.centerYAnchor constraintEqualToAnchor:row.centerYAnchor]
        ]];
    }
}

- (void)showSelected {
    for (NSView *view in self.browserArea.subviews.copy)
        if (view != self.toolbar) [view removeFromSuperview];
    NSMutableDictionary *account = [self selectedAccount];
    [self refreshDetails];
    self.toolbar.hidden = account == nil;
    if (!account) {
        NSStackView *empty = [NSStackView new];
        empty.orientation = NSUserInterfaceLayoutOrientationVertical;
        empty.alignment = NSLayoutAttributeCenterX;
        empty.spacing = 14;
        NSTextField *title = [self label:@"还没有账号" size:22 weight:NSFontWeightSemibold];
        NSTextField *hint = [self label:@"添加一个账号，随后在 ChatGPT 页面登录。" size:13 weight:NSFontWeightRegular];
        hint.textColor = NSColor.secondaryLabelColor;
        NSButton *add = [NSButton buttonWithTitle:@"添加账号" target:self action:@selector(addAccount:)];
        add.bezelStyle = NSBezelStyleRounded;
        [empty addArrangedSubview:title]; [empty addArrangedSubview:hint]; [empty addArrangedSubview:add];
        empty.translatesAutoresizingMaskIntoConstraints = NO;
        [self.browserArea addSubview:empty];
        [empty.centerXAnchor constraintEqualToAnchor:self.browserArea.centerXAnchor].active = YES;
        [empty.centerYAnchor constraintEqualToAnchor:self.browserArea.centerYAnchor].active = YES;
        return;
    }
    self.titleLabel.stringValue = account[@"name"];
    WKWebView *webView = [self selectedSession].webView;
    webView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.browserArea addSubview:webView];
    [NSLayoutConstraint activateConstraints:@[
        [webView.leadingAnchor constraintEqualToAnchor:self.browserArea.leadingAnchor],
        [webView.trailingAnchor constraintEqualToAnchor:self.browserArea.trailingAnchor],
        [webView.topAnchor constraintEqualToAnchor:self.toolbar.bottomAnchor constant:1],
        [webView.bottomAnchor constraintEqualToAnchor:self.browserArea.bottomAnchor]
    ]];
    [self updateNavigation];
    [self schedulePlanReadForAccountID:self.selectedID];
}

- (void)updateNavigation {
    BrowserSession *session = self.sessions[self.selectedID];
    self.backButton.enabled = session.webView.canGoBack;
    self.forwardButton.enabled = session.webView.canGoForward;
    self.hostLabel.stringValue = session.webView.URL.host ?: @"chatgpt.com";
}

- (NSString *)capture:(NSString *)pattern from:(NSString *)text {
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:pattern
        options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *match = [expression firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (!match || [match rangeAtIndex:1].location == NSNotFound) return nil;
    return [text substringWithRange:[match rangeAtIndex:1]];
}

- (NSString *)normalizedDate:(NSString *)raw {
    if (!raw.length) return nil;
    NSString *value = [[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.lenient = NO;
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    NSDate *date = nil;
    for (NSString *format in @[@"yyyy-M-d", @"yyyy年M月d日", @"MMM d, yyyy", @"MMMM d, yyyy", @"d MMM yyyy", @"d MMMM yyyy"]) {
        formatter.dateFormat = format;
        date = [formatter dateFromString:value];
        if (date) break;
    }
    if (!date) return nil;
    formatter.dateFormat = @"yyyy-MM-dd";
    return [formatter stringFromDate:date];
}

- (void)schedulePlanReadForAccountID:(NSString *)identifier {
    if (!identifier) return;
    for (NSNumber *delay in @[@1.5, @4.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self readSubscriptionForAccountID:identifier reportFailure:NO];
        });
    }
}

- (void)syncSubscription:(id)sender {
    [self readSubscriptionForAccountID:self.selectedID reportFailure:YES];
}

- (void)showCurrentSession:(id)sender {
    NSString *identifier = [self.selectedID copy];
    BrowserSession *session = [self selectedSession];
    WKWebView *webView = session.webView;
    if (!identifier || ![webView.URL.host.lowercaseString isEqualToString:@"chatgpt.com"]) {
        [self showError:@"无法读取当前会话" detail:@"请先打开当前账号的 ChatGPT 页面，等待页面加载完成后重试。"];
        return;
    }
    NSString *accountName = [[self selectedAccount][@"name"] copy];
    self.sessionButton.enabled = NO;
    NSString *script = @"const response = await fetch('https://chatgpt.com/api/auth/session', "
        "{ credentials: 'include', cache: 'no-store' }); "
        "return { status: response.status, body: await response.text() };";
    __weak typeof(self) weakSelf = self;
    [webView callAsyncJavaScript:script arguments:@{} inFrame:nil inContentWorld:WKContentWorld.pageWorld
        completionHandler:^(id result, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                AppController *selfRef = weakSelf;
                if (!selfRef || ![selfRef.selectedID isEqualToString:identifier] ||
                    selfRef.sessions[identifier] != session) return;
                selfRef.sessionButton.enabled = YES;
                if (error) {
                    [selfRef showError:@"无法读取当前会话" detail:error.localizedDescription];
                    return;
                }
                NSDictionary *response = [result isKindOfClass:NSDictionary.class] ? result : nil;
                NSString *body = [response[@"body"] isKindOfClass:NSString.class] ? response[@"body"] : nil;
                NSNumber *status = [response[@"status"] isKindOfClass:NSNumber.class] ? response[@"status"] : nil;
                if (!body || !status) {
                    [selfRef showError:@"无法读取当前会话" detail:@"服务器返回了无法识别的响应。"];
                    return;
                }
                [selfRef presentSessionBody:body status:status accountName:accountName];
            });
        }];
}

- (void)presentSessionBody:(NSString *)body status:(NSNumber *)status accountName:(NSString *)accountName {
    NSString *display = body;
    NSData *data = [body dataUsingEncoding:NSUTF8StringEncoding];
    id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:nil] : nil;
    if (json) {
        NSData *formatted = [NSJSONSerialization dataWithJSONObject:json
            options:NSJSONWritingPrettyPrinted | NSJSONWritingFragmentsAllowed error:nil];
        if (formatted) display = [[NSString alloc] initWithData:formatted encoding:NSUTF8StringEncoding] ?: body;
    }

    NSTextView *textView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 620, 340)];
    textView.editable = NO;
    textView.selectable = YES;
    textView.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    textView.string = display;
    textView.textContainerInset = NSMakeSize(8, 8);
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 620, 340)];
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = YES;
    scroll.borderType = NSBezelBorder;
    scroll.documentView = textView;

    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"%@ · 当前会话", accountName ?: @"账号"];
    alert.informativeText = [NSString stringWithFormat:@"HTTP %@ · 会话内容可能包含访问令牌，复制后会留在系统剪贴板中。", status];
    alert.accessoryView = scroll;
    [alert addButtonWithTitle:@"关闭"];
    NSButton *copyButton = [alert addButtonWithTitle:@"复制内容"];
    copyButton.enabled = display.length > 0;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSAlertSecondButtonReturn) {
            NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
            [pasteboard clearContents];
            [pasteboard setString:display forType:NSPasteboardTypeString];
        }
    }];
}

- (void)readSubscriptionForAccountID:(NSString *)identifier reportFailure:(BOOL)reportFailure {
    BrowserSession *session = self.sessions[identifier];
    WKWebView *webView = session.webView;
    if (!webView) return;
    NSString *host = webView.URL.host.lowercaseString;
    if (![host isEqualToString:@"chatgpt.com"] && ![host hasSuffix:@".chatgpt.com"]) {
        if (reportFailure) [self showError:@"无法读取订阅信息" detail:@"请先打开当前账号的 ChatGPT 页面。"];
        return;
    }
    NSString *script = [NSString stringWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"PlanProbe" ofType:@"js"]
        encoding:NSUTF8StringEncoding error:nil];
    if (!script) {
        if (reportFailure) [self showError:@"无法读取订阅信息" detail:@"应用缺少页面识别资源，请重新构建应用。"];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        AppController *selfRef = weakSelf;
        if (!selfRef || !selfRef.sessions[identifier]) return;
        NSDictionary *page = [result isKindOfClass:NSDictionary.class] ? result : nil;
        NSString *profile = [page[@"profile"] isKindOfClass:NSString.class] ? page[@"profile"] : @"";
        NSString *text = [page[@"details"] isKindOfClass:NSString.class] ? page[@"details"] : @"";
        if (error) {
            if (reportFailure) [selfRef showError:@"未获取到订阅信息" detail:error.localizedDescription];
            return;
        }
        NSString *plan = nil;
        if ([profile containsString:@"免费版"]) plan = @"Free";
        else if ([profile containsString:@"团队版"] || [profile containsString:@"商业版"]) plan = @"Business";
        else if ([profile containsString:@"企业版"]) plan = @"Enterprise";
        else if ([profile containsString:@"教育版"]) plan = @"Edu";
        else plan = [selfRef capture:@"\\b(Free|Go|Plus|Pro|Business|Enterprise|Edu)\\b" from:profile];
        if (!plan) plan = [selfRef capture:@"(?:^|\\n)[ \\t]*(?:Current plan|Your plan|My plan|当前套餐|我的套餐|当前订阅|订阅方案|订阅级别)[\\s\\S]{0,80}?\\b(Free|Go|Plus|Pro|Business|Enterprise|Edu)\\b" from:text];
        NSString *rawDate = [selfRef capture:@"(?:Expires on|Expiration date|Expiry date|Subscription ends|到期日期|到期时间|订阅结束日期)[\\s\\S]{0,50}?([0-9]{4}[-/][0-9]{1,2}[-/][0-9]{1,2}|[0-9]{4}年[0-9]{1,2}月[0-9]{1,2}日|[A-Za-z]+ +[0-9]{1,2},? +[0-9]{4}|[0-9]{1,2} +[A-Za-z]+ +[0-9]{4})" from:text];
        NSString *date = [selfRef normalizedDate:rawDate];
        if (!plan && !date) {
            if (reportFailure) [selfRef showError:@"未识别到订阅信息" detail:@"当前页面没有可识别的套餐或到期日期。你可以在右侧手动填写。"];
            return;
        }
        NSMutableDictionary *account = nil;
        for (NSMutableDictionary *item in selfRef.accounts) {
            if ([item[@"id"] isEqualToString:identifier]) { account = item; break; }
        }
        if (!account) return;
        BOOL changed = NO;
        NSString *previousPlan = account[@"plan"] ?: @"未获取";
        if (plan) {
            NSString *normalized = [plan capitalizedString];
            if (![account[@"plan"] isEqualToString:normalized] || ![account[@"planSource"] isEqualToString:@"page"]) {
                account[@"plan"] = normalized;
                account[@"planSource"] = @"page";
                changed = YES;
            }
        }
        if (date && (![account[@"expiresAt"] isEqualToString:date] || ![account[@"expirySource"] isEqualToString:@"page"])) {
            account[@"expiresAt"] = date;
            account[@"expirySource"] = @"page";
            changed = YES;
        }
        if (changed) {
            [selfRef saveAccounts];
            [selfRef refreshAccounts];
            if ([selfRef.selectedID isEqualToString:identifier]) {
                if (plan && [selfRef.planPicker.titleOfSelectedItem isEqualToString:previousPlan]) {
                    [selfRef.planPicker selectItemWithTitle:account[@"plan"]];
                }
                if (date && selfRef.dateToggle.state == NSControlStateValueOff) {
                    selfRef.dateToggle.state = NSControlStateValueOn;
                    selfRef.datePicker.enabled = YES;
                    NSDateFormatter *formatter = [NSDateFormatter new];
                    formatter.dateFormat = @"yyyy-MM-dd";
                    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
                    selfRef.datePicker.dateValue = [formatter dateFromString:date] ?: NSDate.date;
                }
                [selfRef updateSourceLabelForAccount:account];
            }
        }
    }];
}

- (NSString *)promptForName:(NSString *)title initial:(NSString *)initial {
    NSAlert *alert = [NSAlert new];
    alert.messageText = title;
    [alert addButtonWithTitle:@"保存"];
    [alert addButtonWithTitle:@"取消"];
    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 26)];
    input.placeholderString = @"名称，例如：工作账号";
    input.stringValue = initial ?: @"";
    alert.accessoryView = input;
    if ([alert runModal] != NSAlertFirstButtonReturn) return nil;
    NSString *name = [input.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return name.length ? name : nil;
}

- (void)addAccount:(id)sender {
    NSString *name = [self promptForName:@"添加账号" initial:nil];
    if (!name) return;
    NSString *identifier = NSUUID.UUID.UUIDString;
    [self.accounts addObject:[@{@"id":identifier, @"name":name} mutableCopy]];
    self.selectedID = identifier;
    [NSUserDefaults.standardUserDefaults setObject:identifier forKey:@"selectedAccountID"];
    [self saveAccounts]; [self refreshAccounts]; [self showSelected];
}

- (void)selectAccount:(NSButton *)sender {
    self.selectedID = sender.identifier;
    [NSUserDefaults.standardUserDefaults setObject:self.selectedID forKey:@"selectedAccountID"];
    [self refreshAccounts]; [self showSelected];
}

- (void)showAccountMenu:(NSButton *)sender {
    NSMenu *menu = [NSMenu new];
    NSMenuItem *rename = [[NSMenuItem alloc] initWithTitle:@"重命名" action:@selector(renameAccount:) keyEquivalent:@""];
    NSMenuItem *delete = [[NSMenuItem alloc] initWithTitle:@"删除账号" action:@selector(deleteAccount:) keyEquivalent:@""];
    rename.target = self; delete.target = self;
    rename.representedObject = sender.identifier; delete.representedObject = sender.identifier;
    [menu addItem:rename]; [menu addItem:[NSMenuItem separatorItem]]; [menu addItem:delete];
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, sender.bounds.size.height) inView:sender];
}

- (void)renameAccount:(NSMenuItem *)sender {
    for (NSMutableDictionary *account in self.accounts) if ([account[@"id"] isEqualToString:sender.representedObject]) {
        NSString *name = [self promptForName:@"重命名账号" initial:account[@"name"]];
        if (name) { account[@"name"] = name; [self saveAccounts]; [self refreshAccounts]; [self showSelected]; }
        break;
    }
}

- (void)deleteAccount:(NSMenuItem *)sender {
    NSString *identifier = sender.representedObject;
    NSMutableDictionary *account = nil;
    for (NSMutableDictionary *item in self.accounts) if ([item[@"id"] isEqualToString:identifier]) { account = item; break; }
    if (!account) return;
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"删除“%@”？", account[@"name"]];
    alert.informativeText = @"此账号在本机的登录状态和网站数据将被清除，不会删除线上 ChatGPT 账号。";
    [alert addButtonWithTitle:@"删除账号及本地会话"];
    [alert addButtonWithTitle:@"取消"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    [self.accounts removeObject:account];
    BOOL wasSelected = [self.selectedID isEqualToString:identifier];
    if (wasSelected) self.selectedID = self.accounts.firstObject[@"id"];
    if (wasSelected) {
        if (self.selectedID) [NSUserDefaults.standardUserDefaults setObject:self.selectedID forKey:@"selectedAccountID"];
        else [NSUserDefaults.standardUserDefaults removeObjectForKey:@"selectedAccountID"];
    }
    [self showSelected];
    [self.sessions[identifier] invalidate];
    [self.sessions removeObjectForKey:identifier];
    [self saveAccounts]; [self refreshAccounts];
    // WebKit requires all views using the store to be released first.
    dispatch_async(dispatch_get_main_queue(), ^{
        [WKWebsiteDataStore removeDataStoreForIdentifier:[[NSUUID alloc] initWithUUIDString:identifier]
            completionHandler:^(NSError *error) {
                if (error) [self showError:@"会话数据清除失败" detail:error.localizedDescription];
            }];
    });
}

- (void)goBack:(id)sender { [[self selectedSession].webView goBack]; }
- (void)goForward:(id)sender { [[self selectedSession].webView goForward]; }
- (void)reload:(id)sender { [[self selectedSession].webView reload]; }
- (void)goHome:(id)sender { [[self selectedSession].webView loadRequest:[NSURLRequest requestWithURL:HomeURL()]]; }
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *application = NSApplication.sharedApplication;
        AppController *controller = [AppController new];
        application.delegate = controller;
        application.activationPolicy = NSApplicationActivationPolicyRegular;
        [application run];
    }
    return 0;
}
