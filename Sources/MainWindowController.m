#import "MainWindowController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "Account.h"
#import "AccountInspectorController.h"
#import "AccountSidebarController.h"
#import "BrowserPaneController.h"
#import "BrowserSession.h"
#import "DeskUI.h"
#import "ManagementController.h"
#import "SubscriptionParser.h"

static NSToolbarItemIdentifier const ToolbarBack = @"back";
static NSToolbarItemIdentifier const ToolbarForward = @"forward";
static NSToolbarItemIdentifier const ToolbarReload = @"reload";
static NSToolbarItemIdentifier const ToolbarHome = @"home";
static NSToolbarItemIdentifier const ToolbarSession = @"session";
static NSToolbarItemIdentifier const ToolbarMode = @"mode";
static NSToolbarItemIdentifier const ToolbarAdd = @"add";

static NSString *const SelectedAccountDefaultsKey = @"selectedAccountID";
static NSString *const ModeDefaultsKey = @"displayMode";

static BOOL IsChatGPTPage(NSURL *url) {
    NSString *host = url.host.lowercaseString;
    return [host isEqualToString:@"chatgpt.com"] || [host hasSuffix:@".chatgpt.com"];
}

/// Hosts the browser pane and the management view in the split view's content slot.
@interface DeskContentController : NSViewController
@property (nonatomic, copy) NSArray<NSViewController *> *pages;
@end

@implementation DeskContentController
- (instancetype)initWithPages:(NSArray<NSViewController *> *)pages {
    if ((self = [super initWithNibName:nil bundle:nil])) _pages = [pages copy];
    return self;
}
- (void)loadView {
    NSView *root = [NSView new];
    self.view = root;
    for (NSViewController *page in self.pages) {
        [self addChildViewController:page];
        NSView *view = page.view;
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [root addSubview:view];
        [NSLayoutConstraint activateConstraints:@[
            [view.topAnchor constraintEqualToAnchor:root.topAnchor],
            [view.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
            [view.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
            [view.bottomAnchor constraintEqualToAnchor:root.bottomAnchor]
        ]];
    }
}
- (void)showPageAtIndex:(NSUInteger)index {
    (void)self.view;
    [self.pages enumerateObjectsUsingBlock:^(NSViewController *page, NSUInteger position, BOOL *stop) {
        page.view.hidden = position != index;
    }];
}
@end

@interface MainWindowController () <NSToolbarDelegate, NSWindowDelegate, NSMenuItemValidation, NSToolbarItemValidation>
@property (nonatomic, strong, readwrite) AccountStore *store;
@property (nonatomic, copy, readwrite, nullable) NSString *selectedAccountID;
@property (nonatomic, readwrite) DeskMode mode;
@property (nonatomic, strong) NSSplitViewController *splitController;
@property (nonatomic, strong) NSSplitViewItem *sidebarItem;
@property (nonatomic, strong) NSSplitViewItem *inspectorItem;
@property (nonatomic, strong) AccountSidebarController *sidebar;
@property (nonatomic, strong) AccountInspectorController *inspector;
@property (nonatomic, strong) BrowserPaneController *browser;
@property (nonatomic, strong) ManagementController *management;
@property (nonatomic, strong) DeskContentController *content;
@property (nonatomic, strong, nullable) NSToolbarItemGroup *modeGroup;
@property (nonatomic, strong) NSMutableDictionary<NSString *, BrowserSession *> *sessions;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *probeTokens;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *scripts;
@property (nonatomic) NSUInteger nextProbeToken;
@end

@implementation MainWindowController

- (instancetype)initWithStore:(AccountStore *)store {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1280, 820)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
                  NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView
        backing:NSBackingStoreBuffered defer:NO];
    if ((self = [super initWithWindow:window])) {
        _store = store;
        _sessions = [NSMutableDictionary dictionary];
        _probeTokens = [NSMutableDictionary dictionary];
        _scripts = [NSMutableDictionary dictionary];
        __weak typeof(self) weakSelf = self;
        store.saveFailed = ^(NSError *error) {
            [weakSelf showError:@"无法保存账号列表" detail:error.localizedDescription];
        };
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSString *previous = [defaults stringForKey:SelectedAccountDefaultsKey];
        _selectedAccountID = [store accountWithID:previous] ? previous : store.accounts.firstObject.identifier;
        _mode = [defaults integerForKey:ModeDefaultsKey] == DeskModeManagement ? DeskModeManagement : DeskModeBrowser;
        [self buildWindow];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(storeDidChange:)
            name:AccountStoreDidChangeNotification object:store];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(dayDidChange:)
            name:NSCalendarDayChangedNotification object:nil];
        [self applyMode];
        [self updateDockBadge];
    }
    return self;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)buildWindow {
    NSWindow *window = self.window;
    window.title = @"ChatGPT Account Desk";
    window.minSize = NSMakeSize(980, 620);
    window.toolbarStyle = NSWindowToolbarStyleUnified;
    window.delegate = self;
    window.restorable = NO;

    self.sidebar = [[AccountSidebarController alloc] initWithCoordinator:self];
    self.inspector = [[AccountInspectorController alloc] initWithCoordinator:self];
    self.browser = [[BrowserPaneController alloc] initWithCoordinator:self];
    self.management = [[ManagementController alloc] initWithCoordinator:self];
    self.content = [[DeskContentController alloc] initWithPages:@[self.browser, self.management]];

    self.splitController = [NSSplitViewController new];
    self.sidebarItem = [NSSplitViewItem sidebarWithViewController:self.sidebar];
    self.sidebarItem.minimumThickness = 220;
    self.sidebarItem.maximumThickness = 360;
    NSSplitViewItem *contentItem = [NSSplitViewItem splitViewItemWithViewController:self.content];
    contentItem.minimumThickness = 460;
    self.inspectorItem = [NSSplitViewItem inspectorWithViewController:self.inspector];
    self.inspectorItem.minimumThickness = 270;
    self.inspectorItem.maximumThickness = 380;
    self.splitController.splitViewItems = @[self.sidebarItem, contentItem, self.inspectorItem];
    self.splitController.splitView.autosaveName = @"MainSplitView";
    window.contentViewController = self.splitController;

    NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"MainToolbar"];
    toolbar.delegate = self;
    toolbar.displayMode = NSToolbarDisplayModeIconOnly;
    toolbar.centeredItemIdentifiers = [NSSet setWithObject:ToolbarMode];
    window.toolbar = toolbar;

    [window setContentSize:NSMakeSize(1280, 820)];
    [window center];
    [window setFrameAutosaveName:@"MainWindow"];
}

- (void)showError:(NSString *)title detail:(NSString *)detail {
    NSAlert *alert = [NSAlert new];
    alert.messageText = title;
    alert.informativeText = detail ?: @"";
    if (self.window.isVisible) [alert beginSheetModalForWindow:self.window completionHandler:nil];
    else [alert runModal];
}

- (void)prepareForTermination { [self.inspector commitPendingEdits]; }

- (void)windowWillClose:(NSNotification *)notification { [self prepareForTermination]; }

#pragma mark - State

- (void)storeDidChange:(NSNotification *)notification {
    NSString *selected = self.selectedAccountID;
    if (![self.store accountWithID:selected]) selected = self.store.accounts.firstObject.identifier;
    BOOL selectionChanged = !(selected == self.selectedAccountID || [selected isEqualToString:self.selectedAccountID]);
    if (selectionChanged) [self rememberSelection:selected];
    [self.sidebar reloadAccounts];
    [self.management reloadAccounts];
    [self.inspector showAccountID:selected selectionCount:[self inspectorSelectionCount]];
    if (self.mode == DeskModeBrowser && (selectionChanged || (selected && !self.browser.session))) [self showSelectedPage];
    [self updateWindowTitle];
    [self updateDockBadge];
    [self.window.toolbar validateVisibleItems];
}

- (void)dayDidChange:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.sidebar reloadAccounts];
        [self.management reloadAccounts];
        [self.inspector reloadAccount];
        [self updateWindowTitle];
        [self updateDockBadge];
    });
}

- (void)rememberSelection:(NSString *)identifier {
    self.selectedAccountID = identifier;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (identifier) [defaults setObject:identifier forKey:SelectedAccountDefaultsKey];
    else [defaults removeObjectForKey:SelectedAccountDefaultsKey];
}

- (NSUInteger)inspectorSelectionCount {
    return self.mode == DeskModeManagement ? MAX(self.management.selectedAccountIDs.count, 1u) : 1;
}

- (NSArray<NSString *> *)targetAccountIDs {
    if (self.mode == DeskModeManagement) {
        NSArray *identifiers = self.management.selectedAccountIDs;
        if (identifiers.count) return identifiers;
    }
    return self.selectedAccountID ? @[self.selectedAccountID] : @[];
}

- (void)selectAccountID:(NSString *)identifier {
    if (![self.store accountWithID:identifier]) identifier = nil;
    BOOL changed = !(identifier == self.selectedAccountID || [identifier isEqualToString:self.selectedAccountID]);
    if (changed) [self.inspector commitPendingEdits];
    [self rememberSelection:identifier];
    [self.sidebar reflectSelection];
    [self.management reflectSelection];
    [self.inspector showAccountID:identifier selectionCount:[self inspectorSelectionCount]];
    if (self.mode == DeskModeBrowser && (changed || !self.browser.session)) [self showSelectedPage];
    [self updateWindowTitle];
    [self.window.toolbar validateVisibleItems];
}

- (void)openAccountID:(NSString *)identifier {
    [self selectAccountID:identifier];
    [self switchToMode:DeskModeBrowser];
    if (self.browser.session) [self.window makeFirstResponder:self.browser.session.webView];
}

- (void)managementSelectionDidChange:(NSArray<NSString *> *)identifiers {
    if (identifiers.count == 1) {
        [self selectAccountID:identifiers.firstObject];
        return;
    }
    [self.inspector showAccountID:self.selectedAccountID selectionCount:MAX(identifiers.count, 1u)];
    [self updateWindowTitle];
}

- (void)switchToMode:(DeskMode)mode {
    if (self.mode == mode) return;
    [self.inspector commitPendingEdits];
    self.mode = mode;
    [NSUserDefaults.standardUserDefaults setInteger:mode forKey:ModeDefaultsKey];
    [self applyMode];
}

- (void)applyMode {
    [self.content showPageAtIndex:self.mode];
    self.modeGroup.selectedIndex = self.mode;
    if (self.mode == DeskModeBrowser) {
        [self showSelectedPage];
    } else {
        [self.management reloadAccounts];
        [self.management reflectSelection];
    }
    [self.inspector showAccountID:self.selectedAccountID selectionCount:[self inspectorSelectionCount]];
    [self updateWindowTitle];
    [self.window.toolbar validateVisibleItems];
}

- (void)modeChanged:(NSToolbarItemGroup *)sender { [self switchToMode:sender.selectedIndex == 1 ? DeskModeManagement : DeskModeBrowser]; }

- (void)showBrowser:(id)sender {
    [self switchToMode:DeskModeBrowser];
    if (self.browser.session) [self.window makeFirstResponder:self.browser.session.webView];
}

- (void)showManagement:(id)sender {
    [self switchToMode:DeskModeManagement];
    [self.management focusTable];
}

- (void)updateWindowTitle {
    Account *account = [self.store accountWithID:self.selectedAccountID];
    NSString *title = @"ChatGPT Account Desk";
    NSString *subtitle = @"";
    if (self.mode == DeskModeManagement) {
        title = @"账号管理";
        subtitle = [NSString stringWithFormat:@"%lu 个账号", (unsigned long)self.store.accounts.count];
    } else if (account) {
        title = account.name;
        NSMutableArray *parts = [NSMutableArray arrayWithObject:account.plan ?: @"未获取订阅"];
        if (account.expiresAt) [parts addObject:[account expiryDescriptionFromDate:NSDate.date]];
        NSString *host = self.browser.session.webView.URL.host;
        if (host.length && ![host isEqualToString:@"chatgpt.com"]) [parts addObject:host];
        subtitle = [parts componentsJoinedByString:@" · "];
    }
    if (![self.window.title isEqualToString:title]) self.window.title = title;
    if (![self.window.subtitle isEqualToString:subtitle]) self.window.subtitle = subtitle;
}

- (void)updateDockBadge {
    NSDate *now = NSDate.date;
    NSUInteger attention = 0;
    for (Account *account in self.store.accounts) {
        AccountExpiryState state = [account expiryStateFromDate:now];
        if (state == AccountExpiryStateExpiringSoon || state == AccountExpiryStateExpired) attention++;
    }
    NSApp.dockTile.badgeLabel = attention ? [NSString stringWithFormat:@"%lu", (unsigned long)attention] : nil;
}

#pragma mark - Pages

- (BrowserSession *)sessionForAccountID:(NSString *)identifier {
    BrowserSession *session = self.sessions[identifier];
    if (session) return session;
    session = [[BrowserSession alloc] initWithAccountID:identifier];
    __weak typeof(self) weakSelf = self;
    session.stateChanged = ^(BrowserSession *changed) { [weakSelf sessionStateChanged:changed]; };
    session.pageReady = ^(BrowserSession *ready) { [weakSelf scheduleProbesForAccountID:ready.accountID]; };
    session.downloadEnded = ^(BrowserSession *owner, NSURL *file, NSError *error) {
        [weakSelf downloadEndedWithFile:file error:error];
    };
    self.sessions[identifier] = session;
    return session;
}

- (void)showSelectedPage {
    Account *account = [self.store accountWithID:self.selectedAccountID];
    if (!account) {
        [self.browser showSession:nil];
        return;
    }
    [self.browser showSession:[self sessionForAccountID:account.identifier]];
    [self scheduleProbesForAccountID:account.identifier];
    NSString *identifier = account.identifier;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        Account *current = [weakSelf.store accountWithID:identifier];
        if (!current) return;
        current.lastUsedAt = NSDate.date;
        [weakSelf.store commit];
    });
}

- (void)sessionStateChanged:(BrowserSession *)session {
    if (session != self.browser.session) return;
    [self.browser updateState];
    [self updateWindowTitle];
    [self.window.toolbar validateVisibleItems];
}

- (void)downloadEndedWithFile:(NSURL *)file error:(NSError *)error {
    if (error) {
        [self showError:@"下载失败" detail:error.localizedDescription];
        return;
    }
    if (!file) return;
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"下载完成";
    alert.informativeText = [NSString stringWithFormat:@"“%@”已保存到“下载”文件夹。", file.lastPathComponent];
    [alert addButtonWithTitle:@"在访达中显示"];
    [alert addButtonWithTitle:@"好"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[file]];
    }];
}

- (void)releaseBackgroundPages:(id)sender {
    NSString *keep = self.mode == DeskModeBrowser ? self.browser.session.accountID : nil;
    for (NSString *identifier in self.sessions.allKeys) {
        if ([identifier isEqualToString:keep]) continue;
        if (self.browser.session == self.sessions[identifier]) [self.browser showSession:nil];
        [self.sessions[identifier] invalidate];
        [self.sessions removeObjectForKey:identifier];
    }
    [self.window.toolbar validateVisibleItems];
}

- (void)goBack:(id)sender { [self.browser.session.webView goBack]; }
- (void)goForward:(id)sender { [self.browser.session.webView goForward]; }
- (void)reloadPage:(id)sender { [self.browser.session.webView reload]; }
- (void)goHome:(id)sender { [self.browser.session goHome]; }

#pragma mark - Page probes

- (NSString *)scriptNamed:(NSString *)name {
    NSString *script = self.scripts[name];
    if (script) return script;
    NSString *path = [NSBundle.mainBundle pathForResource:name ofType:@"js"];
    script = path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] : nil;
    if (script) self.scripts[name] = script;
    return script;
}

- (void)scheduleProbesForAccountID:(NSString *)identifier {
    NSNumber *token = @(++self.nextProbeToken);
    self.probeTokens[identifier] = token;
    __weak typeof(self) weakSelf = self;
    for (NSNumber *delay in @[@1.5, @4.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            MainWindowController *strongSelf = weakSelf;
            if (![strongSelf.probeTokens[identifier] isEqualToNumber:token]) return;
            [strongSelf readSubscriptionForAccountID:identifier reportFailure:NO];
            if (delay.doubleValue < 2) [strongSelf probeSessionForAccountID:identifier];
        });
    }
}

- (void)syncSubscription:(id)sender {
    if (self.selectedAccountID) [self readSubscriptionForAccountID:self.selectedAccountID reportFailure:YES];
}

- (void)readSubscriptionForAccountID:(NSString *)identifier reportFailure:(BOOL)reportFailure {
    WKWebView *webView = self.sessions[identifier].webView;
    if (!webView || !IsChatGPTPage(webView.URL)) {
        if (reportFailure) [self showError:@"无法读取订阅信息" detail:@"请先在“浏览”中打开此账号的 ChatGPT 页面，等待加载完成后重试。"];
        return;
    }
    NSString *script = [self scriptNamed:@"PlanProbe"];
    if (!script) {
        if (reportFailure) [self showError:@"无法读取订阅信息" detail:@"应用缺少页面识别资源，请重新构建应用。"];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        MainWindowController *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.sessions[identifier]) return;
        if (error) {
            if (reportFailure) [strongSelf showError:@"未获取到订阅信息" detail:error.localizedDescription];
            return;
        }
        NSDictionary *page = [result isKindOfClass:NSDictionary.class] ? result : nil;
        NSString *profile = [page[@"profile"] isKindOfClass:NSString.class] ? page[@"profile"] : @"";
        NSString *details = [page[@"details"] isKindOfClass:NSString.class] ? page[@"details"] : @"";
        NSString *plan = [SubscriptionParser planFromProfile:profile details:details];
        NSString *date = [SubscriptionParser expiryFromDetails:details];
        if (!plan && !date) {
            if (reportFailure) [strongSelf showError:@"未识别到订阅信息"
                detail:@"当前页面没有可识别的套餐或到期日期。可在 ChatGPT 的账号设置中打开订阅详情后重试，或在右侧手动填写。"];
            return;
        }
        Account *account = [strongSelf.store accountWithID:identifier];
        if (!account) return;
        BOOL changed = NO;
        if (plan && (![account.plan isEqualToString:plan] || ![account.planSource isEqualToString:@"page"])) {
            account.plan = plan;
            account.planSource = @"page";
            changed = YES;
        }
        if (date && (![account.expiresAt isEqualToString:date] || ![account.expirySource isEqualToString:@"page"])) {
            account.expiresAt = date;
            account.expirySource = @"page";
            changed = YES;
        }
        if (changed) [strongSelf.store commit];
    }];
}

- (void)probeSessionForAccountID:(NSString *)identifier {
    WKWebView *webView = self.sessions[identifier].webView;
    NSString *script = [self scriptNamed:@"SessionProbe"];
    if (!webView || !script || !IsChatGPTPage(webView.URL)) return;
    __weak typeof(self) weakSelf = self;
    [webView callAsyncJavaScript:script arguments:@{} inFrame:nil inContentWorld:WKContentWorld.pageWorld
        completionHandler:^(id result, NSError *error) {
            MainWindowController *strongSelf = weakSelf;
            NSDictionary *info = [result isKindOfClass:NSDictionary.class] ? result : nil;
            if (!strongSelf || error || ![info[@"parsed"] boolValue] || [info[@"status"] integerValue] != 200) return;
            Account *account = [strongSelf.store accountWithID:identifier];
            if (!account) return;
            BOOL signedIn = [info[@"signedIn"] boolValue];
            BOOL changed = NO;
            if (!account.signedIn || account.signedIn.boolValue != signedIn) {
                account.signedIn = @(signedIn);
                changed = YES;
            }
            NSString *email = [info[@"email"] isKindOfClass:NSString.class] ? info[@"email"] : @"";
            if (signedIn && email.length && !account.email.length) {
                account.email = email;
                changed = YES;
            }
            NSString *planType = [info[@"planType"] isKindOfClass:NSString.class] ? info[@"planType"] : nil;
            NSString *plan = [SubscriptionParser planFromPlanType:planType];
            if (signedIn && plan && !account.plan) {
                account.plan = plan;
                account.planSource = @"page";
                changed = YES;
            }
            if (changed) [strongSelf.store commit];
        }];
}

- (void)showCurrentSession:(id)sender {
    NSString *identifier = [self.selectedAccountID copy];
    BrowserSession *session = identifier ? self.sessions[identifier] : nil;
    WKWebView *webView = session.webView;
    if (!webView || ![webView.URL.host.lowercaseString isEqualToString:@"chatgpt.com"]) {
        [self showError:@"无法读取当前会话" detail:@"请先在“浏览”中打开当前账号的 ChatGPT 页面，等待页面加载完成后重试。"];
        return;
    }
    NSString *accountName = [[self.store accountWithID:identifier].name copy];
    NSString *script = @"const response = await fetch('https://chatgpt.com/api/auth/session', "
        "{ credentials: 'include', cache: 'no-store' }); "
        "return { status: response.status, body: await response.text() };";
    __weak typeof(self) weakSelf = self;
    [webView callAsyncJavaScript:script arguments:@{} inFrame:nil inContentWorld:WKContentWorld.pageWorld
        completionHandler:^(id result, NSError *error) {
            MainWindowController *strongSelf = weakSelf;
            if (!strongSelf || ![strongSelf.selectedAccountID isEqualToString:identifier] ||
                strongSelf.sessions[identifier] != session) return;
            if (error) {
                [strongSelf showError:@"无法读取当前会话" detail:error.localizedDescription];
                return;
            }
            NSDictionary *response = [result isKindOfClass:NSDictionary.class] ? result : nil;
            NSString *body = [response[@"body"] isKindOfClass:NSString.class] ? response[@"body"] : nil;
            NSNumber *status = [response[@"status"] isKindOfClass:NSNumber.class] ? response[@"status"] : nil;
            if (!body || !status) {
                [strongSelf showError:@"无法读取当前会话" detail:@"服务器返回了无法识别的响应。"];
                return;
            }
            [strongSelf presentSessionBody:body status:status accountName:accountName];
        }];
}

- (void)presentSessionBody:(NSString *)body status:(NSNumber *)status accountName:(NSString *)accountName {
    NSString *display = body;
    NSData *data = [body dataUsingEncoding:NSUTF8StringEncoding];
    id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:nil] : nil;
    if (json) {
        NSData *formatted = [NSJSONSerialization dataWithJSONObject:json
            options:NSJSONWritingPrettyPrinted | NSJSONWritingFragmentsAllowed | NSJSONWritingWithoutEscapingSlashes error:nil];
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

#pragma mark - Account operations

- (NSComboBox *)groupComboWithValue:(NSString *)value {
    NSComboBox *combo = [[NSComboBox alloc] initWithFrame:NSMakeRect(0, 0, 300, 26)];
    combo.placeholderString = @"分组（可选）";
    combo.completes = YES;
    [combo addItemsWithObjectValues:self.store.groups];
    combo.stringValue = value ?: @"";
    return combo;
}

- (void)addAccount:(id)sender {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"添加账号";
    alert.informativeText = @"起一个便于识别的名称，添加后在 ChatGPT 页面登录。每个账号的登录状态单独保存在本机。";
    NSView *fields = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 60)];
    NSTextField *name = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 34, 300, 24)];
    name.placeholderString = [NSString stringWithFormat:@"名称，例如：工作账号（默认“账号 %lu”）", (unsigned long)self.store.accounts.count + 1];
    Account *current = [self.store accountWithID:self.selectedAccountID];
    NSComboBox *group = [self groupComboWithValue:current.group];
    group.frame = NSMakeRect(0, 0, 300, 26);
    [fields addSubview:name];
    [fields addSubview:group];
    alert.accessoryView = fields;
    [alert addButtonWithTitle:@"添加"];
    [alert addButtonWithTitle:@"取消"];
    [alert layout];
    alert.window.initialFirstResponder = name;
    __weak typeof(self) weakSelf = self;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        MainWindowController *strongSelf = weakSelf;
        if (!strongSelf || response != NSAlertFirstButtonReturn) return;
        NSString *value = [name.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!value.length) value = [NSString stringWithFormat:@"账号 %lu", (unsigned long)strongSelf.store.accounts.count + 1];
        Account *account = [strongSelf.store addAccountNamed:value group:group.stringValue];
        [strongSelf.store commit];
        [strongSelf openAccountID:account.identifier];
    }];
}

- (void)renameAccountID:(NSString *)identifier {
    Account *account = [self.store accountWithID:identifier];
    if (!account) return;
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"重命名账号";
    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)];
    input.stringValue = account.name;
    alert.accessoryView = input;
    [alert addButtonWithTitle:@"保存"];
    [alert addButtonWithTitle:@"取消"];
    [alert layout];
    alert.window.initialFirstResponder = input;
    __weak typeof(self) weakSelf = self;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        NSString *name = [input.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (response != NSAlertFirstButtonReturn || !name.length) return;
        account.name = name;
        [weakSelf.store commit];
    }];
}

- (void)promptGroupForAccountIDs:(NSArray<NSString *> *)identifiers {
    NSArray<Account *> *accounts = [self.store accountsWithIDs:identifiers];
    if (!accounts.count) return;
    NSSet *groups = [NSSet setWithArray:[accounts valueForKey:@"group"]];
    NSAlert *alert = [NSAlert new];
    alert.messageText = accounts.count == 1
        ? [NSString stringWithFormat:@"移动“%@”到分组", accounts.firstObject.name]
        : [NSString stringWithFormat:@"移动 %lu 个账号到分组", (unsigned long)accounts.count];
    alert.informativeText = @"输入新分组名称或选择已有分组，留空表示移出分组。";
    NSComboBox *combo = [self groupComboWithValue:groups.count == 1 ? groups.anyObject : @""];
    alert.accessoryView = combo;
    [alert addButtonWithTitle:@"移动"];
    [alert addButtonWithTitle:@"取消"];
    [alert layout];
    alert.window.initialFirstResponder = combo;
    __weak typeof(self) weakSelf = self;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) [weakSelf assignGroup:combo.stringValue toAccounts:accounts];
    }];
}

- (void)assignGroup:(NSString *)group toAccounts:(NSArray<Account *> *)accounts {
    for (Account *account in accounts) account.group = group;
    [self.store commit];
}

- (void)deleteAccountIDs:(NSArray<NSString *> *)identifiers {
    NSArray<Account *> *accounts = [self.store accountsWithIDs:identifiers];
    if (!accounts.count) return;
    NSAlert *alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = accounts.count == 1
        ? [NSString stringWithFormat:@"删除“%@”？", accounts.firstObject.name]
        : [NSString stringWithFormat:@"删除 %lu 个账号？", (unsigned long)accounts.count];
    alert.informativeText = @"账号资料以及它在本机的登录状态和网站数据会被清除，此操作无法撤销。线上 ChatGPT 账号不受影响。";
    [alert addButtonWithTitle:@"删除"].hasDestructiveAction = YES;
    [alert addButtonWithTitle:@"取消"];
    __weak typeof(self) weakSelf = self;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) [weakSelf removeAccounts:accounts];
    }];
}

- (void)removeAccounts:(NSArray<Account *> *)accounts {
    NSArray<NSString *> *identifiers = [accounts valueForKey:@"identifier"];
    NSString *next = self.selectedAccountID;
    if ([identifiers containsObject:next]) {
        next = nil;
        NSArray<NSString *> *order = self.sidebar.visibleAccountIDs;
        NSUInteger index = [order indexOfObject:self.selectedAccountID];
        if (index != NSNotFound) {
            for (NSUInteger position = index + 1; position < order.count && !next; position++)
                if (![identifiers containsObject:order[position]]) next = order[position];
            for (NSUInteger position = index; position > 0 && !next; position--)
                if (![identifiers containsObject:order[position - 1]]) next = order[position - 1];
        }
        for (Account *account in self.store.accounts)
            if (!next && ![identifiers containsObject:account.identifier]) next = account.identifier;
    }

    // WebKit only removes a data store once no web view uses it.
    if ([identifiers containsObject:self.browser.session.accountID]) [self.browser showSession:nil];
    for (NSString *identifier in identifiers) [self.sessions[identifier] invalidate];
    [self.sessions removeObjectsForKeys:identifiers];
    [self.probeTokens removeObjectsForKeys:identifiers];
    [self.store removeAccountsWithIDs:identifiers];
    [self rememberSelection:next];
    [self.store commit];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        for (NSString *identifier in identifiers) {
            [WKWebsiteDataStore removeDataStoreForIdentifier:[[NSUUID alloc] initWithUUIDString:identifier]
                completionHandler:^(NSError *error) {
                    if (error) [weakSelf showError:@"会话数据清除失败" detail:error.localizedDescription];
                }];
        }
    });
}

- (void)clearLoginDataForAccountIDs:(NSArray<NSString *> *)identifiers {
    NSArray<Account *> *accounts = [self.store accountsWithIDs:identifiers];
    if (!accounts.count) return;
    NSAlert *alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = accounts.count == 1
        ? [NSString stringWithFormat:@"清除“%@”的登录数据？", accounts.firstObject.name]
        : [NSString stringWithFormat:@"清除 %lu 个账号的登录数据？", (unsigned long)accounts.count];
    alert.informativeText = @"会退出在本机的 ChatGPT 登录，并清除 Cookie、缓存等网站数据。账号资料（名称、订阅、分组、备注）会保留。";
    [alert addButtonWithTitle:@"清除"].hasDestructiveAction = YES;
    [alert addButtonWithTitle:@"取消"];
    __weak typeof(self) weakSelf = self;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        for (Account *account in accounts) [weakSelf clearWebsiteDataForAccountID:account.identifier];
    }];
}

- (void)clearWebsiteDataForAccountID:(NSString *)identifier {
    BrowserSession *session = self.sessions[identifier];
    WKWebsiteDataStore *dataStore = session ? session.webView.configuration.websiteDataStore
        : [WKWebsiteDataStore dataStoreForIdentifier:[[NSUUID alloc] initWithUUIDString:identifier]];
    __weak typeof(self) weakSelf = self;
    [dataStore removeDataOfTypes:WKWebsiteDataStore.allWebsiteDataTypes modifiedSince:[NSDate dateWithTimeIntervalSince1970:0]
        completionHandler:^{
            MainWindowController *strongSelf = weakSelf;
            Account *account = [strongSelf.store accountWithID:identifier];
            if (!account) return;
            account.signedIn = @NO;
            [strongSelf.store commit];
            [strongSelf.sessions[identifier] goHome];
        }];
}

#pragma mark - Import / export

- (void)importAccounts:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = @[UTTypeJSON];
    panel.message = @"选择之前导出的账号资料文件。同一账号会更新资料，文件中为空的字段保留本机数据。";
    panel.prompt = @"导入";
    __weak typeof(self) weakSelf = self;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK || !panel.URL) return;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf importFileAtURL:panel.URL]; });
    }];
}

- (void)importFileAtURL:(NSURL *)url {
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&error];
    NSUInteger added = 0, updated = 0;
    if (!data || ![self.store importData:data added:&added updated:&updated error:&error]) {
        [self showError:@"无法导入账号资料" detail:error.localizedDescription];
        return;
    }
    [self.store commit];
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"导入完成";
    alert.informativeText = [NSString stringWithFormat:@"新增 %lu 个账号，更新 %lu 个账号。新增的账号需要在 ChatGPT 页面重新登录。",
        (unsigned long)added, (unsigned long)updated];
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

- (void)exportAccounts:(id)sender { [self exportAccountIDs:nil]; }

- (void)exportAccountIDs:(NSArray<NSString *> *)identifiers {
    NSError *error = nil;
    NSData *data = [self.store exportDataForAccountIDs:identifiers error:&error];
    if (!data) {
        [self showError:@"无法导出账号资料" detail:error.localizedDescription];
        return;
    }
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[UTTypeJSON];
    panel.nameFieldStringValue = [NSString stringWithFormat:@"ChatGPT-Accounts-%@.json", AccountDayString(NSDate.date)];
    panel.message = identifiers
        ? [NSString stringWithFormat:@"导出所选的 %lu 个账号。文件只包含账号资料，不含密码、登录状态或访问令牌。", (unsigned long)identifiers.count]
        : @"导出全部账号资料。文件只包含账号资料，不含密码、登录状态或访问令牌。";
    __weak typeof(self) weakSelf = self;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK || !panel.URL) return;
        NSError *writeError = nil;
        if (![data writeToURL:panel.URL options:NSDataWritingAtomic error:&writeError]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf showError:@"无法导出账号资料" detail:writeError.localizedDescription];
            });
        }
    }];
}

- (void)revealDataFile:(id)sender {
    NSURL *file = self.store.fileURL;
    if ([NSFileManager.defaultManager fileExistsAtPath:file.path]) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[file]];
    else [NSWorkspace.sharedWorkspace openURL:file.URLByDeletingLastPathComponent];
}

#pragma mark - Context menu

- (NSMenuItem *)menuItem:(NSString *)title symbol:(NSString *)symbol action:(SEL)action object:(id)object {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    item.representedObject = object;
    if (symbol) item.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
    return item;
}

- (void)populateMenu:(NSMenu *)menu forAccountIDs:(NSArray<NSString *> *)identifiers {
    [menu removeAllItems];
    NSArray<Account *> *accounts = [self.store accountsWithIDs:identifiers];
    if (!accounts.count) {
        [menu addItem:[self menuItem:@"添加账号…" symbol:@"plus" action:@selector(addAccount:) object:nil]];
        return;
    }
    NSArray<NSString *> *ids = [accounts valueForKey:@"identifier"];
    if (accounts.count == 1) {
        Account *account = accounts.firstObject;
        [menu addItem:[self menuItem:@"在浏览器中打开" symbol:@"globe" action:@selector(openFromMenu:) object:ids]];
        [menu addItem:[self menuItem:@"重命名…" symbol:@"pencil" action:@selector(renameFromMenu:) object:ids]];
        if (account.email.length)
            [menu addItem:[self menuItem:@"复制邮箱" symbol:@"doc.on.doc" action:@selector(copyEmailFromMenu:) object:ids]];
        [menu addItem:[NSMenuItem separatorItem]];
    }

    NSMenuItem *groupItem = [self menuItem:@"移动到分组" symbol:@"folder" action:nil object:nil];
    NSMenu *groupMenu = [NSMenu new];
    NSSet *currentGroups = [NSSet setWithArray:[accounts valueForKey:@"group"]];
    for (NSString *group in self.store.groups) {
        NSMenuItem *item = [self menuItem:group symbol:nil action:@selector(assignGroupFromMenu:) object:@{@"ids": ids, @"group": group}];
        item.state = currentGroups.count == 1 && [currentGroups containsObject:group] ? NSControlStateValueOn : NSControlStateValueOff;
        [groupMenu addItem:item];
    }
    if (groupMenu.numberOfItems) [groupMenu addItem:[NSMenuItem separatorItem]];
    [groupMenu addItem:[self menuItem:@"新建分组…" symbol:nil action:@selector(promptGroupFromMenu:) object:ids]];
    if (!(currentGroups.count == 1 && [currentGroups containsObject:@""]))
        [groupMenu addItem:[self menuItem:@"移出分组" symbol:nil action:@selector(assignGroupFromMenu:) object:@{@"ids": ids, @"group": @""}]];
    groupItem.submenu = groupMenu;
    [menu addItem:groupItem];
    [menu addItem:[self menuItem:accounts.count == 1 ? @"导出资料…" : @"导出所选资料…" symbol:@"square.and.arrow.up"
        action:@selector(exportFromMenu:) object:ids]];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:[self menuItem:@"清除登录数据…" symbol:@"rectangle.portrait.and.arrow.right"
        action:@selector(clearFromMenu:) object:ids]];
    NSString *deleteTitle = accounts.count == 1 ? @"删除账号…" : [NSString stringWithFormat:@"删除 %lu 个账号…", (unsigned long)accounts.count];
    [menu addItem:[self menuItem:deleteTitle symbol:@"trash" action:@selector(deleteFromMenu:) object:ids]];
}

- (void)openFromMenu:(NSMenuItem *)sender { [self openAccountID:[sender.representedObject firstObject]]; }
- (void)renameFromMenu:(NSMenuItem *)sender { [self renameAccountID:[sender.representedObject firstObject]]; }
- (void)promptGroupFromMenu:(NSMenuItem *)sender { [self promptGroupForAccountIDs:sender.representedObject]; }
- (void)exportFromMenu:(NSMenuItem *)sender { [self exportAccountIDs:sender.representedObject]; }
- (void)clearFromMenu:(NSMenuItem *)sender { [self clearLoginDataForAccountIDs:sender.representedObject]; }
- (void)deleteFromMenu:(NSMenuItem *)sender { [self deleteAccountIDs:sender.representedObject]; }

- (void)copyEmailFromMenu:(NSMenuItem *)sender {
    Account *account = [self.store accountWithID:[sender.representedObject firstObject]];
    if (!account.email.length) return;
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:account.email forType:NSPasteboardTypeString];
}

- (void)assignGroupFromMenu:(NSMenuItem *)sender {
    NSDictionary *payload = sender.representedObject;
    [self assignGroup:payload[@"group"] toAccounts:[self.store accountsWithIDs:payload[@"ids"]]];
}

#pragma mark - Menu bar actions

- (void)focusSearch:(id)sender {
    if (self.mode == DeskModeManagement) {
        [self.management focusSearch];
        return;
    }
    if (self.sidebarItem.isCollapsed) self.sidebarItem.animator.collapsed = NO;
    [self.sidebar focusSearch];
}

- (void)toggleSidebar:(id)sender { [self.splitController toggleSidebar:sender]; }
- (void)toggleInspector:(id)sender { [self.splitController toggleInspector:sender]; }

- (void)selectAdjacentAccount:(NSInteger)offset {
    NSArray<NSString *> *order = self.sidebar.visibleAccountIDs;
    if (!order.count) return;
    NSUInteger index = [order indexOfObject:self.selectedAccountID];
    NSInteger count = (NSInteger)order.count;
    NSInteger next = index == NSNotFound ? 0 : (((NSInteger)index + offset) % count + count) % count;
    [self selectAccountID:order[next]];
}

- (void)selectPreviousAccount:(id)sender { [self selectAdjacentAccount:-1]; }
- (void)selectNextAccount:(id)sender { [self selectAdjacentAccount:1]; }

- (void)renameSelectedAccount:(id)sender {
    NSArray *identifiers = [self targetAccountIDs];
    if (identifiers.count == 1) [self renameAccountID:identifiers.firstObject];
}

- (void)moveSelectedToGroup:(id)sender { [self promptGroupForAccountIDs:[self targetAccountIDs]]; }
- (void)clearSelectedLoginData:(id)sender { [self clearLoginDataForAccountIDs:[self targetAccountIDs]]; }
- (void)deleteSelectedAccounts:(id)sender { [self deleteAccountIDs:[self targetAccountIDs]]; }

#pragma mark - Validation

- (BOOL)validateAction:(SEL)action {
    BrowserSession *visible = self.mode == DeskModeBrowser ? self.browser.session : nil;
    if (action == @selector(goBack:)) return visible.webView.canGoBack;
    if (action == @selector(goForward:)) return visible.webView.canGoForward;
    if (action == @selector(reloadPage:) || action == @selector(goHome:)) return visible != nil;
    if (action == @selector(showCurrentSession:) || action == @selector(syncSubscription:))
        return self.selectedAccountID && self.sessions[self.selectedAccountID];
    if (action == @selector(selectPreviousAccount:) || action == @selector(selectNextAccount:))
        return self.sidebar.visibleAccountIDs.count > 1;
    if (action == @selector(renameSelectedAccount:)) return [self targetAccountIDs].count == 1;
    if (action == @selector(moveSelectedToGroup:) || action == @selector(clearSelectedLoginData:) ||
        action == @selector(deleteSelectedAccounts:)) return [self targetAccountIDs].count > 0;
    if (action == @selector(exportAccounts:)) return self.store.accounts.count > 0;
    if (action == @selector(releaseBackgroundPages:)) {
        NSString *keep = self.mode == DeskModeBrowser ? self.browser.session.accountID : nil;
        return self.sessions.count > (keep ? 1u : 0u);
    }
    return YES;
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    SEL action = item.action;
    if (action == @selector(showBrowser:)) item.state = self.mode == DeskModeBrowser ? NSControlStateValueOn : NSControlStateValueOff;
    if (action == @selector(showManagement:)) item.state = self.mode == DeskModeManagement ? NSControlStateValueOn : NSControlStateValueOff;
    if (action == @selector(toggleSidebar:)) item.title = self.sidebarItem.isCollapsed ? @"显示侧边栏" : @"隐藏侧边栏";
    if (action == @selector(toggleInspector:)) item.title = self.inspectorItem.isCollapsed ? @"显示账号详情" : @"隐藏账号详情";
    if (action == @selector(deleteSelectedAccounts:)) {
        NSUInteger count = [self targetAccountIDs].count;
        item.title = count > 1 ? [NSString stringWithFormat:@"删除 %lu 个账号…", (unsigned long)count] : @"删除账号…";
    }
    return [self validateAction:action];
}

- (BOOL)validateToolbarItem:(NSToolbarItem *)item { return [self validateAction:item.action]; }

#pragma mark - Toolbar

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    return @[NSToolbarToggleSidebarItemIdentifier, NSToolbarSidebarTrackingSeparatorItemIdentifier,
             ToolbarBack, ToolbarForward, NSToolbarFlexibleSpaceItemIdentifier, ToolbarMode, NSToolbarFlexibleSpaceItemIdentifier,
             ToolbarReload, ToolbarHome, ToolbarSession,
             NSToolbarInspectorTrackingSeparatorItemIdentifier, NSToolbarFlexibleSpaceItemIdentifier,
             NSToolbarToggleInspectorItemIdentifier];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    return [[self toolbarDefaultItemIdentifiers:toolbar] arrayByAddingObjectsFromArray:@[ToolbarAdd, NSToolbarSpaceItemIdentifier]];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)identifier
    willBeInsertedIntoToolbar:(BOOL)flag {
    if ([identifier isEqualToString:ToolbarMode]) {
        NSToolbarItemGroup *group = [NSToolbarItemGroup groupWithItemIdentifier:ToolbarMode titles:@[@"浏览", @"管理"]
            selectionMode:NSToolbarItemGroupSelectionModeSelectOne labels:@[@"浏览", @"管理"]
            target:self action:@selector(modeChanged:)];
        group.label = @"视图";
        group.toolTip = @"在 ChatGPT 页面与账号管理之间切换（⌘1 / ⌘2）";
        group.selectedIndex = self.mode;
        self.modeGroup = group;
        return group;
    }
    NSDictionary<NSString *, NSArray *> *specs = @{
        ToolbarBack: @[@"chevron.backward", @"后退", NSStringFromSelector(@selector(goBack:))],
        ToolbarForward: @[@"chevron.forward", @"前进", NSStringFromSelector(@selector(goForward:))],
        ToolbarReload: @[@"arrow.clockwise", @"重新载入", NSStringFromSelector(@selector(reloadPage:))],
        ToolbarHome: @[@"house", @"ChatGPT 首页", NSStringFromSelector(@selector(goHome:))],
        ToolbarSession: @[@"key.horizontal", @"查看当前会话", NSStringFromSelector(@selector(showCurrentSession:))],
        ToolbarAdd: @[@"plus", @"添加账号", NSStringFromSelector(@selector(addAccount:))],
    };
    NSArray *spec = specs[identifier];
    if (!spec) return nil;
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
    item.image = [NSImage imageWithSystemSymbolName:spec[0] accessibilityDescription:spec[1]];
    item.label = spec[1];
    item.toolTip = spec[1];
    item.target = self;
    item.action = NSSelectorFromString(spec[2]);
    item.bordered = YES;
    item.navigational = [identifier isEqualToString:ToolbarBack] || [identifier isEqualToString:ToolbarForward];
    return item;
}
@end
