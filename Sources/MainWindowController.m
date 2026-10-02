#import "MainWindowController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "Account.h"
#import "AccountInsights.h"
#import "AccountInspectorController.h"
#import "AccountRefresher.h"
#import "AccountSidebarController.h"
#import "AuthorizationLink.h"
#import "AuthorizationWindowController.h"
#import "BillingReader.h"
#import "BrowserPaneController.h"
#import "BrowserSession.h"
#import "DeskUI.h"
#import "ManagementController.h"
#import "ManagementNavigatorController.h"
#import "ManagementScope.h"
#import "NetworkProxy.h"
#import "SubscriptionParser.h"

NSString *const ReleaseIdlePagesMinutesDefaultsKey = @"releaseIdlePagesMinutes";

static NSToolbarItemIdentifier const ToolbarBack = @"back";
static NSToolbarItemIdentifier const ToolbarForward = @"forward";
static NSToolbarItemIdentifier const ToolbarReload = @"reload";
static NSToolbarItemIdentifier const ToolbarHome = @"home";
static NSToolbarItemIdentifier const ToolbarAccountMenu = @"accountMenu";
static NSToolbarItemIdentifier const ToolbarRefreshUsage = @"refreshUsageLabeled";
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

@interface MainWindowController () <NSToolbarDelegate, NSWindowDelegate, NSMenuItemValidation, NSToolbarItemValidation,
    NSTokenFieldDelegate, NSMenuDelegate>
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
@property (nonatomic, strong) ManagementNavigatorController *navigator;
@property (nonatomic, strong) DeskContentController *sidebarContainer;
@property (nonatomic, strong) BillingReader *billingReader;
@property (nonatomic, strong) UsageHistory *history;
@property (nonatomic) BOOL historyDirty;
@property (nonatomic, strong, nullable) NSTimer *maintenanceTimer;
/// When each loaded page was last on screen, for releasing idle background pages.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *sessionActivity;
/// Billing reads started together, reported in one summary when the last one finishes.
@property (nonatomic, strong) NSMutableSet<NSString *> *billingBatch;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *billingFailures;
@property (nonatomic, strong, nullable) NSPopUpButton *accountMenuButton;
@property (nonatomic, strong, nullable) NSButton *refreshUsageButton;
@property (nonatomic, strong, nullable) NSToolbarItemGroup *modeGroup;
@property (nonatomic, strong) NSMutableDictionary<NSString *, BrowserSession *> *sessions;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *probeTokens;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *scripts;
@property (nonatomic, strong) NSMutableArray<AuthorizationWindowController *> *authorizationWindows;
@property (nonatomic, strong) AccountRefresher *refresher;
@property (nonatomic, strong, nullable) NSTimer *usageTimer;
/// When automatic refresh last tried each account, so failing accounts are not retried every minute.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *usageAttempts;
@property (nonatomic) NSUInteger billingReadToken;
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
        _authorizationWindows = [NSMutableArray array];
        _usageAttempts = [NSMutableDictionary dictionary];
        _sessionActivity = [NSMutableDictionary dictionary];
        _billingBatch = [NSMutableSet set];
        _billingFailures = [NSMutableDictionary dictionary];
        NSURL *directory = store.fileURL.URLByDeletingLastPathComponent;
        _history = [[UsageHistory alloc] initWithFileURL:[directory URLByAppendingPathComponent:@"usage-history.json"]];
        _refresher = [[AccountRefresher alloc] initWithStore:store];
        __weak typeof(self) weakRefresherSelf = self;
        _refresher.dataStoreProvider = ^WKWebsiteDataStore *(NSString *identifier) {
            return [weakRefresherSelf dataStoreForAccountID:identifier];
        };
        _refresher.stateChanged = ^{ [weakRefresherSelf refresherStateChanged]; };
        _refresher.usageRead = ^(NSString *identifier) { [weakRefresherSelf recordUsageOfAccountID:identifier]; };
        _billingReader = [BillingReader new];
        _billingReader.dataStoreProvider = ^WKWebsiteDataStore *(NSString *identifier) {
            return [weakRefresherSelf dataStoreForAccountID:identifier];
        };
        _billingReader.applyReading = ^BOOL(NSString *identifier, NSDictionary *page) {
            return [weakRefresherSelf applyPageReading:page toAccountID:identifier];
        };
        _billingReader.stateChanged = ^{ [weakRefresherSelf refresherStateChanged]; };
        _billingReader.accountFinished = ^(NSString *identifier, NSString *failure) {
            [weakRefresherSelf billingFinishedForAccountID:identifier failure:failure];
        };
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
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(userAgentPreferenceDidChange:)
            name:BrowserUserAgentPreferenceDidChangeNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(scheduleUsageRefresh)
            name:UsageRefreshSettingsDidChangeNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(defaultProxyDidChange:)
            name:ProxySettingsDidChangeNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(exchangeRatesDidChange:)
            name:ExchangeRatesDidChangeNotification object:nil];
        [NSUserDefaults.standardUserDefaults registerDefaults:@{ReleaseIdlePagesMinutesDefaultsKey: @30}];
        [self scheduleUsageRefresh];
        _maintenanceTimer = [NSTimer scheduledTimerWithTimeInterval:60 target:self selector:@selector(performMaintenance)
            userInfo:nil repeats:YES];
        _maintenanceTimer.tolerance = 15;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakRefresherSelf refreshStaleUsage];
        });
        [self applyMode];
        [self updateDockBadge];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self.maintenanceTimer invalidate];
}

- (void)buildWindow {
    NSWindow *window = self.window;
    window.title = @"智枢矩阵";
    window.minSize = NSMakeSize(980, 620);
    window.toolbarStyle = NSWindowToolbarStyleUnified;
    window.delegate = self;
    window.restorable = NO;
    // Closing the window only hides it when the app keeps running in the menu bar.
    window.releasedWhenClosed = NO;

    self.sidebar = [[AccountSidebarController alloc] initWithCoordinator:self];
    self.inspector = [[AccountInspectorController alloc] initWithCoordinator:self];
    self.browser = [[BrowserPaneController alloc] initWithCoordinator:self];
    self.management = [[ManagementController alloc] initWithCoordinator:self];
    self.navigator = [[ManagementNavigatorController alloc] initWithCoordinator:self];
    self.management.scope = self.navigator.scope;
    __weak typeof(self) weakSelf = self;
    self.navigator.scopeChosen = ^(ManagementScope *scope) {
        weakSelf.management.scope = scope;
        [weakSelf updateWindowTitle];
    };
    self.management.scopeChosen = ^(ManagementScope *scope) {
        weakSelf.navigator.scope = scope;
        [weakSelf updateWindowTitle];
    };
    self.content = [[DeskContentController alloc] initWithPages:@[self.browser, self.management]];
    self.sidebarContainer = [[DeskContentController alloc] initWithPages:@[self.sidebar, self.navigator]];

    self.splitController = [NSSplitViewController new];
    self.sidebarItem = [NSSplitViewItem sidebarWithViewController:self.sidebarContainer];
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

- (void)showWindow:(id)sender {
    [super showWindow:sender];
    // The page may have been released while the window was closed.
    if (self.mode == DeskModeBrowser && !self.browser.session) [self showSelectedPage];
}

- (void)showError:(NSString *)title detail:(NSString *)detail {
    NSAlert *alert = [NSAlert new];
    alert.messageText = title;
    alert.informativeText = detail ?: @"";
    if (self.window.isVisible) [alert beginSheetModalForWindow:self.window completionHandler:nil];
    else [alert runModal];
}

- (void)prepareForTermination {
    [self.inspector commitPendingEdits];
    [self saveHistory];
}

- (void)windowWillClose:(NSNotification *)notification { [self prepareForTermination]; }

#pragma mark - State

- (void)storeDidChange:(NSNotification *)notification {
    NSString *selected = self.selectedAccountID;
    if (![self.store accountWithID:selected]) selected = self.store.accounts.firstObject.identifier;
    BOOL selectionChanged = !(selected == self.selectedAccountID || [selected isEqualToString:self.selectedAccountID]);
    if (selectionChanged) [self rememberSelection:selected];
    [self.sidebar reloadAccounts];
    [self.navigator reloadAccounts];
    [self.management reloadAccounts];
    [self.inspector showAccountID:selected selectionCount:[self inspectorSelectionCount]];
    if (self.mode == DeskModeBrowser && (selectionChanged || (selected && !self.browser.session))) [self showSelectedPage];
    [self updateWindowTitle];
    [self updateDockBadge];
    [self updateToolbarState];
}

- (void)dayDidChange:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.sidebar reloadAccounts];
        [self.navigator reloadAccounts];
        [self.management reloadAccounts];
        [self.inspector reloadAccount];
        [self updateWindowTitle];
        [self updateDockBadge];
    });
}

- (void)userAgentPreferenceDidChange:(NSNotification *)notification {
    for (BrowserSession *session in self.sessions.allValues) [session applyPreferredUserAgent];
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
    [self updateToolbarState];
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
    [self updateToolbarState];
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
    [self.sidebarContainer showPageAtIndex:self.mode];
    [self.inspector applyMode];
    self.modeGroup.selectedIndex = self.mode;
    if (self.mode == DeskModeBrowser) {
        [self showSelectedPage];
    } else {
        [self.management reloadAccounts];
        [self.management reflectSelection];
    }
    [self.inspector showAccountID:self.selectedAccountID selectionCount:[self inspectorSelectionCount]];
    [self updateWindowTitle];
    [self updateToolbarState];
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
    NSString *title = @"智枢矩阵";
    NSString *subtitle = @"";
    if (self.mode == DeskModeManagement) {
        title = @"账号管理";
        ManagementScope *scope = self.navigator.scope;
        subtitle = scope.kind == ManagementScopeAll ? [NSString stringWithFormat:@"%lu 个账号", (unsigned long)self.store.accounts.count]
            : scope.title;
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
    for (Account *account in self.store.accounts)
        if ([AccountStatus statusForAccount:account now:now].kind >= AccountStatusExpiringSoon) attention++;
    NSApp.dockTile.badgeLabel = attention ? [NSString stringWithFormat:@"%lu", (unsigned long)attention] : nil;
}


#pragma mark - Pages

- (BrowserSession *)sessionForAccountID:(NSString *)identifier {
    BrowserSession *session = self.sessions[identifier];
    if (session) return session;
    session = [[BrowserSession alloc] initWithAccountID:identifier dataStore:[self dataStoreForAccountID:identifier]
        initialURL:BrowserHomeURL()];
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
    NSString *previous = self.browser.session.accountID;
    if (previous) self.sessionActivity[previous] = NSDate.date;
    [self.browser showSession:[self sessionForAccountID:account.identifier]];
    self.sessionActivity[account.identifier] = NSDate.date;
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
        [self.sessionActivity removeObjectForKey:identifier];
    }
    [self updateToolbarState];
}

- (WKWebsiteDataStore *)dataStoreForAccountID:(NSString *)identifier {
    WKWebsiteDataStore *loaded = self.sessions[identifier].webView.configuration.websiteDataStore;
    if (loaded) {
        ApplyProxyText(EffectiveProxyText([self.store accountWithID:identifier]), loaded);
        return loaded;
    }
    return AccountDataStore(identifier, [self.store accountWithID:identifier]);
}

- (void)proxyDidChangeForAccountID:(NSString *)identifier {
    BrowserSession *session = self.sessions[identifier];
    if (!session) return;
    [self dataStoreForAccountID:identifier];
    [session.webView reload];
}

- (void)defaultProxyDidChange:(NSNotification *)notification {
    for (NSString *identifier in self.sessions.allKeys) {
        if ([self.store accountWithID:identifier].proxy.length) continue;
        [self proxyDidChangeForAccountID:identifier];
    }
}

/// Every minute: releases background pages left unused for the configured time and saves usage history.
- (void)performMaintenance {
    [self saveHistory];
    NSInteger minutes = [NSUserDefaults.standardUserDefaults integerForKey:ReleaseIdlePagesMinutesDefaultsKey];
    NSString *visible = self.mode == DeskModeBrowser && self.window.isVisible ? self.browser.session.accountID : nil;
    if (visible) self.sessionActivity[visible] = NSDate.date;
    if (minutes <= 0) return;
    NSDate *threshold = [NSDate dateWithTimeIntervalSinceNow:-minutes * 60];
    NSMutableArray<NSString *> *idle = [NSMutableArray array];
    for (NSString *identifier in self.sessions.allKeys) {
        if ([identifier isEqualToString:visible]) continue;
        NSDate *active = self.sessionActivity[identifier];
        if (active && [active compare:threshold] == NSOrderedDescending) continue;
        if (!active) { self.sessionActivity[identifier] = NSDate.date; continue; }
        [idle addObject:identifier];
    }
    for (NSString *identifier in idle) {
        if (self.browser.session == self.sessions[identifier]) [self.browser showSession:nil];
        [self.sessions[identifier] invalidate];
        [self.sessions removeObjectForKey:identifier];
        [self.sessionActivity removeObjectForKey:identifier];
    }
    if (idle.count) [self updateToolbarState];
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
    __weak typeof(self) weakSelf = self;
    [self evaluatePlanProbeForAccountID:identifier completion:^(NSDictionary *page, NSString *failure) {
        MainWindowController *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (failure) {
            if (reportFailure) [strongSelf showError:@"无法读取订阅信息" detail:failure];
            return;
        }
        if (![strongSelf applyPageReading:page toAccountID:identifier] && reportFailure)
            [strongSelf showError:@"未识别到订阅信息"
                detail:@"当前页面没有可识别的套餐或到期日期。可使用“从账单页读取”，或在右侧手动填写。"];
    }];
}

- (void)evaluatePlanProbeForAccountID:(NSString *)identifier completion:(void (^)(NSDictionary *page, NSString *failure))completion {
    WKWebView *webView = self.sessions[identifier].webView;
    if (!webView || !IsChatGPTPage(webView.URL)) {
        completion(nil, @"请先在“浏览”中打开此账号的 ChatGPT 页面，等待加载完成后重试。");
        return;
    }
    NSString *script = [self scriptNamed:@"PlanProbe"];
    if (!script) {
        completion(nil, @"应用缺少页面识别资源，请重新构建应用。");
        return;
    }
    __weak typeof(self) weakSelf = self;
    [webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        if (!weakSelf.sessions[identifier]) return;
        completion([result isKindOfClass:NSDictionary.class] ? result : @{}, error.localizedDescription);
    }];
}

/// Applies what PlanProbe.js read from the page. Returns whether anything was recognised.
- (BOOL)applyPageReading:(NSDictionary *)page toAccountID:(NSString *)identifier {
    Account *account = [self.store accountWithID:identifier];
    NSString *profile = [page[@"profile"] isKindOfClass:NSString.class] ? page[@"profile"] : @"";
    NSString *details = [page[@"details"] isKindOfClass:NSString.class] ? page[@"details"] : @"";
    BOOL billing = [SubscriptionParser isBillingText:details];
    NSString *plan = [SubscriptionParser planFromProfile:profile details:details];
    NSDictionary *renewal = [SubscriptionParser renewalFromBillingText:details];
    NSString *date = renewal[@"date"] ?: [SubscriptionParser expiryFromDetails:details];
    NSDictionary *price = billing ? [SubscriptionParser priceFromBillingText:details] : nil;
    NSString *supplier = billing ? [SubscriptionParser supplierFromBillingText:details] : nil;
    NSString *card = billing ? [SubscriptionParser cardLast4FromBillingText:details] : nil;
    NSArray<NSDictionary *> *charges = billing ? [SubscriptionParser paymentsFromBillingText:details] : @[];
    if (!account || (!plan && !date && !price && !supplier && !card && !charges.count)) return NO;
    // A subscription bought through a reseller is paid on ChatGPT with the reseller's card; what is on the page
    // is then not what you paid, so it only fills in accounts bought directly.
    BOOL direct = account.supplier.length == 0;
    BOOL changed = [account applyDetectedPlan:plan source:@"page"];
    if (date && (![account.expiresAt isEqualToString:date] || ![account.expirySource isEqualToString:@"page"])) {
        account.expiresAt = date;
        account.expirySource = @"page";
        changed = YES;
    }
    if (renewal[@"autoRenew"] && ![account.autoRenew isEqual:renewal[@"autoRenew"]]) {
        account.autoRenew = renewal[@"autoRenew"];
        changed = YES;
    }
    if (price && (direct || !account.monthlyPrice) &&
        (![account.monthlyPrice isEqual:price[@"amount"]] || ![account.currency isEqualToString:price[@"currency"]])) {
        account.monthlyPrice = price[@"amount"];
        account.currency = price[@"currency"];
        changed = YES;
    }
    if (supplier && direct) {
        account.supplier = supplier;
        changed = YES;
    }
    if (card && direct && !account.cardLast4.length) {
        account.cardLast4 = card;
        changed = YES;
    }
    if (charges.count && account.supplier.length == 0) {
        NSMutableArray<AccountPayment *> *payments = [NSMutableArray array];
        for (NSDictionary *charge in charges) {
            AccountPayment *payment = [[AccountPayment alloc] initWithDictionary:@{@"date": charge[@"date"],
                @"amount": charge[@"amount"], @"currency": charge[@"currency"], @"source": @"page"}];
            payment.paymentMethod = account.paymentMethod;
            payment.cardLast4 = account.cardLast4;
            if (payment) [payments addObject:payment];
        }
        if ([account addPayments:payments]) changed = YES;
    }
    if (changed) [self.store commit];
    return YES;
}

- (void)openBillingPageForAccountID:(NSString *)identifier {
    if (![self.store accountWithID:identifier]) return;
    [self selectAccountID:identifier];
    [self switchToMode:DeskModeBrowser];
    BrowserSession *session = [self sessionForAccountID:identifier];
    if (self.browser.session != session) [self.browser showSession:session];
    WKWebView *webView = session.webView;
    if (IsChatGPTPage(webView.URL) && !webView.loading)
        [webView evaluateJavaScript:@"location.hash = '#settings/Billing'" completionHandler:nil];
    else
        [webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://chatgpt.com/#settings/Billing"]]];
    [self readBillingForAccountID:identifier attempt:0 token:++self.billingReadToken];
}

- (void)readBillingForAccountID:(NSString *)identifier attempt:(NSUInteger)attempt token:(NSUInteger)token {
    NSArray<NSNumber *> *delays = @[@2.5, @2.5, @3, @4];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[attempt].doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        MainWindowController *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.billingReadToken != token) return;
        [strongSelf evaluatePlanProbeForAccountID:identifier completion:^(NSDictionary *page, NSString *failure) {
            NSString *details = [page[@"details"] isKindOfClass:NSString.class] ? page[@"details"] : @"";
            if (!failure && [SubscriptionParser isBillingText:details] && [weakSelf applyPageReading:page toAccountID:identifier]) return;
            if (attempt + 1 < delays.count) {
                [weakSelf readBillingForAccountID:identifier attempt:attempt + 1 token:token];
                return;
            }
            [weakSelf showError:@"未能读取账单页"
                detail:failure ?: @"请确认此账号已登录，并在 ChatGPT 的“设置 → 账单”中能看到套餐和交易记录，然后重试。"];
        }];
    });
}

#pragma mark - Background billing

- (BOOL)isReadingBillingForAccountID:(NSString *)identifier { return [self.billingReader isReadingAccountID:identifier]; }

- (void)readBillingForAccountID:(NSString *)identifier { [self readBillingForAccountIDs:@[identifier]]; }

- (void)readBillingForAccountIDs:(NSArray<NSString *> *)identifiers {
    NSArray<Account *> *accounts = [self.store accountsWithIDs:identifiers];
    if (!accounts.count) return;
    if (!self.billingReader.isReading) [self.billingFailures removeAllObjects];
    for (Account *account in accounts) [self.billingBatch addObject:account.identifier];
    [self.billingReader readAccountIDs:[accounts valueForKey:@"identifier"]];
}

- (void)readAllBilling:(id)sender {
    NSMutableArray *identifiers = [NSMutableArray array];
    for (Account *account in self.store.accounts)
        if (!account.signedIn || account.signedIn.boolValue) [identifiers addObject:account.identifier];
    [self readBillingForAccountIDs:identifiers];
}

- (void)billingFinishedForAccountID:(NSString *)identifier failure:(NSString *)failure {
    if (failure) self.billingFailures[identifier] = failure;
    BOOL batched = [self.billingBatch containsObject:identifier];
    [self.billingBatch removeObject:identifier];
    if (!batched || self.billingReader.isReading) return;
    NSDictionary<NSString *, NSString *> *failures = [self.billingFailures copy];
    [self.billingFailures removeAllObjects];
    if (!failures.count) return;
    if (failures.count == 1) {
        NSString *failed = failures.allKeys.firstObject;
        Account *account = [self.store accountWithID:failed];
        NSAlert *alert = [NSAlert new];
        alert.messageText = [NSString stringWithFormat:@"未能读取“%@”的账单", account.name ?: @"账号"];
        alert.informativeText = [failures[failed] stringByAppendingString:@"\n\n也可以在浏览模式中打开账单页，确认页面显示后再读取。"];
        [alert addButtonWithTitle:@"打开账单页"];
        [alert addButtonWithTitle:@"好"];
        __weak typeof(self) weakSelf = self;
        [self presentAlert:alert completion:^(NSModalResponse response) {
            if (response == NSAlertFirstButtonReturn) [weakSelf openBillingPageForAccountID:failed];
        }];
        return;
    }
    NSMutableArray *lines = [NSMutableArray array];
    [failures enumerateKeysAndObjectsUsingBlock:^(NSString *failed, NSString *reason, BOOL *stop) {
        [lines addObject:[NSString stringWithFormat:@"• %@：%@", [self.store accountWithID:failed].name ?: @"已删除的账号", reason]];
    }];
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"%lu 个账号的账单未能读取", (unsigned long)failures.count];
    alert.informativeText = [lines componentsJoinedByString:@"\n"];
    [self presentAlert:alert completion:nil];
}

- (void)presentAlert:(NSAlert *)alert completion:(void (^)(NSModalResponse))completion {
    if (self.window.isVisible && !self.window.attachedSheet) {
        [alert beginSheetModalForWindow:self.window completionHandler:completion];
        return;
    }
    NSModalResponse response = [alert runModal];
    if (completion) completion(response);
}

#pragma mark - Usage history

- (void)recordUsageOfAccountID:(NSString *)identifier {
    Account *account = [self.store accountWithID:identifier];
    if (!account.usage.windows.count) return;
    [self.history recordUsageWindows:account.usage.windows forAccountID:identifier at:account.usage.fetchedAt ?: NSDate.date];
    self.historyDirty = YES;
}

- (NSArray<NSDictionary *> *)usageHistoryForAccountID:(NSString *)identifier { return [self.history pointsForAccountID:identifier]; }

- (void)saveHistory {
    if (!self.historyDirty) return;
    self.historyDirty = NO;
    [self.history save:nil];
}

#pragma mark - Usage refresh

- (BOOL)isRefreshingUsage { return self.refresher.isRefreshing; }
- (BOOL)isRefreshingAccountID:(NSString *)identifier { return [self.refresher isRefreshingAccountID:identifier]; }

- (void)refreshUsageForAccountIDs:(NSArray<NSString *> *)identifiers {
    if (identifiers.count) [self.refresher refreshAccountIDs:identifiers];
}

- (void)refreshAllUsage:(id)sender { [self refreshUsageForAccountIDs:[self.store.accounts valueForKey:@"identifier"]]; }
- (void)refreshSelectedUsage:(id)sender { [self refreshUsageForAccountIDs:[self targetAccountIDs]]; }

- (void)refresherStateChanged {
    [self.management reloadAccounts];
    [self.inspector reloadAccount];
    [self updateToolbarState];
}

- (void)scheduleUsageRefresh {
    [self.usageTimer invalidate];
    self.usageTimer = nil;
    if (UsageRefreshMinutes() <= 0) return;
    self.usageTimer = [NSTimer scheduledTimerWithTimeInterval:60 target:self selector:@selector(refreshStaleUsage)
        userInfo:nil repeats:YES];
    self.usageTimer.tolerance = 10;
}

- (void)refreshStaleUsage {
    NSInteger minutes = UsageRefreshMinutes();
    if (minutes <= 0) return;
    NSDate *threshold = [NSDate dateWithTimeIntervalSinceNow:-minutes * 60 + 30];
    NSMutableArray<NSString *> *stale = [NSMutableArray array];
    for (Account *account in self.store.accounts) {
        if (account.signedIn && !account.signedIn.boolValue) continue;
        NSDate *attempted = self.usageAttempts[account.identifier];
        if (attempted && [attempted compare:threshold] == NSOrderedDescending) continue;
        if (account.usage && [account.usage.fetchedAt compare:threshold] == NSOrderedDescending) continue;
        self.usageAttempts[account.identifier] = NSDate.date;
        [stale addObject:account.identifier];
    }
    [self refreshUsageForAccountIDs:stale];
}

#pragma mark - Tags

- (NSArray<NSString *> *)tokenField:(NSTokenField *)tokenField completionsForSubstring:(NSString *)substring
    indexOfToken:(NSInteger)tokenIndex indexOfSelectedItem:(NSInteger *)selectedIndex {
    NSMutableArray *matches = [NSMutableArray array];
    for (NSString *tag in self.store.tags)
        if (!substring.length || [tag localizedCaseInsensitiveContainsString:substring]) [matches addObject:tag];
    return matches;
}

- (void)promptTagsForAccountIDs:(NSArray<NSString *> *)identifiers {
    NSArray<Account *> *accounts = [self.store accountsWithIDs:identifiers];
    if (!accounts.count) return;
    NSAlert *alert = [NSAlert new];
    alert.messageText = accounts.count == 1
        ? [NSString stringWithFormat:@"为“%@”添加标签", accounts.firstObject.name]
        : [NSString stringWithFormat:@"为 %lu 个账号添加标签", (unsigned long)accounts.count];
    alert.informativeText = @"输入标签后按回车或逗号分隔，已有标签会自动补全。移除标签可在右键菜单的“标签”中取消勾选。";
    NSTokenField *field = [[NSTokenField alloc] initWithFrame:NSMakeRect(0, 0, 320, 24)];
    field.tokenizingCharacterSet = [NSCharacterSet characterSetWithCharactersInString:@",，"];
    field.placeholderString = @"例如：主力、备用、风控中";
    field.delegate = self;
    alert.accessoryView = field;
    [alert addButtonWithTitle:@"添加"];
    [alert addButtonWithTitle:@"取消"];
    [alert layout];
    alert.window.initialFirstResponder = field;
    __weak typeof(self) weakSelf = self;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        NSMutableArray<NSString *> *tags = [NSMutableArray array];
        if ([field.objectValue isKindOfClass:NSArray.class]) [tags addObjectsFromArray:field.objectValue];
        [tags addObjectsFromArray:[field.stringValue componentsSeparatedByCharactersInSet:field.tokenizingCharacterSet]];
        NSArray<NSString *> *normalized = AccountNormalizedTags(tags);
        if (!normalized.count) return;
        for (Account *account in accounts) account.tags = [account.tags arrayByAddingObjectsFromArray:normalized];
        [weakSelf.store commit];
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
    for (AuthorizationWindowController *authorization in self.authorizationWindows.copy)
        if ([identifiers containsObject:authorization.accountID]) [authorization closeAuthorization];
    if ([identifiers containsObject:self.browser.session.accountID]) [self.browser showSession:nil];
    for (NSString *identifier in identifiers) [self.sessions[identifier] invalidate];
    [self.sessions removeObjectsForKeys:identifiers];
    [self.probeTokens removeObjectsForKeys:identifiers];
    [self.sessionActivity removeObjectsForKeys:identifiers];
    [self.history removeAccountIDs:identifiers];
    self.historyDirty = YES;
    [self.store removeAccountsWithIDs:identifiers];
    [self rememberSelection:next];
    [self.store commit];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        for (NSString *identifier in identifiers) [weakSelf removeDataStoreForAccountID:identifier attempt:1];
    });
}

- (void)removeDataStoreForAccountID:(NSString *)identifier attempt:(NSUInteger)attempt {
    __weak typeof(self) weakSelf = self;
    [WKWebsiteDataStore removeDataStoreForIdentifier:[[NSUUID alloc] initWithUUIDString:identifier]
        completionHandler:^(NSError *error) {
            if (!error) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                // Web views that used the store (e.g. a just-closed authorization window) are torn down asynchronously.
                if (attempt >= 5) {
                    [weakSelf showError:@"会话数据清除失败" detail:error.localizedDescription];
                    return;
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [weakSelf removeDataStoreForAccountID:identifier attempt:attempt + 1];
                });
            });
        }];
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
    WKWebsiteDataStore *dataStore = session ? session.webView.configuration.websiteDataStore : [self dataStoreForAccountID:identifier];
    __weak typeof(self) weakSelf = self;
    if (self.loginDataCleared) self.loginDataCleared(@[identifier]);
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

#pragma mark - Client authorization

- (void)openAuthorizationLink:(id)sender {
    NSArray<NSString *> *identifiers = [self targetAccountIDs];
    if (identifiers.count == 1) [self promptAuthorizationForAccountID:identifiers.firstObject];
}

- (void)promptAuthorizationForAccountID:(NSString *)identifier {
    Account *account = [self.store accountWithID:identifier];
    if (!account) return;
    NSString *initial = account.authURL.length ? account.authURL
        : ([NSUserDefaults.standardUserDefaults stringForKey:DefaultAuthorizationURLDefaultsKey] ?: @"");
    [self promptAuthorizationForAccount:account text:initial invalid:NO];
}

- (void)promptAuthorizationForAccount:(Account *)account text:(NSString *)text invalid:(BOOL)invalid {
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"用“%@”授权第三方登录", account.name];
    alert.informativeText = invalid
        ? @"无法识别授权链接，请粘贴以 http:// 或 https:// 开头的完整链接。"
        : @"粘贴第三方应用或网站提供的授权链接，它会在此账号的独立会话中打开；授权后会通过回调地址自动跳回对方完成登录。授权链接通常只能使用一次，请使用最新的链接。";
    if (invalid) alert.alertStyle = NSAlertStyleWarning;
    NSView *accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 440, 122)];
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 52, 440, 70)];
    field.placeholderString = @"https://auth.openai.com/oauth/authorize?…";
    field.usesSingleLineMode = NO;
    field.cell.wraps = YES;
    field.cell.scrollable = NO;
    field.lineBreakMode = NSLineBreakByCharWrapping;
    field.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    field.stringValue = text ?: @"";
    NSButton *remember = [NSButton checkboxWithTitle:@"保存为此账号的授权链接" target:nil action:nil];
    remember.frame = NSMakeRect(0, 24, 440, 20);
    NSButton *capture = [NSButton checkboxWithTitle:@"只获取回调地址，不在本机打开（第三方应用在其他设备上时使用）" target:nil action:nil];
    capture.frame = NSMakeRect(0, 0, 440, 20);
    capture.toolTip = @"授权后拦截 localhost 回调，只显示回调地址供复制，授权码不会发送给本机的任何程序";
    capture.state = [NSUserDefaults.standardUserDefaults boolForKey:CaptureAuthorizationCallbackDefaultsKey]
        ? NSControlStateValueOn : NSControlStateValueOff;
    [accessory addSubview:field];
    [accessory addSubview:remember];
    [accessory addSubview:capture];
    alert.accessoryView = accessory;
    [alert addButtonWithTitle:@"打开"];
    [alert addButtonWithTitle:@"取消"];
    [alert layout];
    alert.window.initialFirstResponder = field;
    NSString *identifier = account.identifier;
    __weak typeof(self) weakSelf = self;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        MainWindowController *strongSelf = weakSelf;
        Account *current = [strongSelf.store accountWithID:identifier];
        if (!current || response != NSAlertFirstButtonReturn) return;
        NSURL *url = AuthorizationURLFromText(field.stringValue);
        if (!url) {
            NSString *typed = field.stringValue;
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf promptAuthorizationForAccount:current text:typed invalid:YES];
            });
            return;
        }
        if (remember.state == NSControlStateValueOn && ![current.authURL isEqualToString:url.absoluteString]) {
            current.authURL = url.absoluteString;
            [strongSelf.store commit];
        }
        BOOL captureCallback = capture.state == NSControlStateValueOn;
        [NSUserDefaults.standardUserDefaults setBool:captureCallback forKey:CaptureAuthorizationCallbackDefaultsKey];
        [strongSelf openAuthorizationURL:url forAccountID:identifier captureCallback:captureCallback];
    }];
}

- (AuthorizationWindowController *)openAuthorizationURL:(NSURL *)url forAccountID:(NSString *)identifier
    captureCallback:(BOOL)captureCallback {
    Account *account = [self.store accountWithID:identifier];
    if (!account) return nil;
    // Share the loaded page's store so a sign-in done in either window is visible to the other.
    WKWebsiteDataStore *dataStore = [self dataStoreForAccountID:identifier];
    AuthorizationWindowController *controller = [[AuthorizationWindowController alloc] initWithAccount:account
        URL:url dataStore:dataStore captureCallback:captureCallback];
    __weak typeof(self) weakSelf = self;
    controller.authorized = ^(AuthorizationWindowController *finished, NSDictionary<NSString *, NSString *> *details) {
        MainWindowController *strongSelf = weakSelf;
        Account *current = [strongSelf.store accountWithID:finished.accountID];
        if (!current) return;
        NSString *name = AuthorizationDefaultAppName();
        [current recordAuthorizationWithClientID:details[@"clientID"] redirect:details[@"redirect"] scope:details[@"scope"]
            appName:name.length ? name : details[@"appName"] at:NSDate.date];
        [strongSelf.store commit];
    };
    controller.closed = ^(AuthorizationWindowController *closed) {
        // Let the window finish closing before the controller that owns it is released.
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf.authorizationWindows removeObject:closed];
            if (weakSelf.sessions[closed.accountID]) [weakSelf scheduleProbesForAccountID:closed.accountID];
        });
    };
    [self.authorizationWindows addObject:controller];
    [controller showWindow:nil];
    return controller;
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
    NSUInteger duplicates = AccountDuplicateEmails(self.store.accounts).count;
    if (duplicates) alert.informativeText = [alert.informativeText stringByAppendingFormat:
        @"\n\n有 %lu 个邮箱被多个账号使用，可在账号管理的“重复邮箱”中查看。", (unsigned long)duplicates];
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

- (void)exportRenewalCalendar:(id)sender {
    NSArray<Account *> *accounts = self.mode == DeskModeManagement && self.management.selectedAccountIDs.count > 1
        ? [self.store accountsWithIDs:self.management.selectedAccountIDs] : self.store.accounts;
    NSMutableArray<Account *> *dated = [NSMutableArray array];
    for (Account *account in accounts) if (account.expiresAt) [dated addObject:account];
    if (!dated.count) {
        [self showError:@"没有可导出的日期" detail:@"请先为账号设置续费 / 到期日期，或读取账单页。"];
        return;
    }
    NSData *data = [AccountRenewalCalendar(dated) dataUsingEncoding:NSUTF8StringEncoding];
    NSSavePanel *panel = [NSSavePanel savePanel];
    UTType *calendar = [UTType typeWithFilenameExtension:@"ics"];
    if (calendar) panel.allowedContentTypes = @[calendar];
    panel.nameFieldStringValue = [NSString stringWithFormat:@"智枢矩阵-续费日历-%@.ics", AccountDayString(NSDate.date)];
    panel.message = [NSString stringWithFormat:@"导出 %lu 个账号的续费与到期日期。自动续费的账号按月重复，并在前一天提醒；"
        "可导入“日历”等应用。", (unsigned long)dated.count];
    __weak typeof(self) weakSelf = self;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK || !panel.URL) return;
        NSError *error = nil;
        if (![data writeToURL:panel.URL options:NSDataWritingAtomic error:&error]) {
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf showError:@"无法导出日历" detail:error.localizedDescription]; });
        }
    }];
}

- (void)exchangeRatesDidChange:(NSNotification *)notification {
    [self.management reloadAccounts];
    [self.inspector reloadAccount];
}

- (void)exportPaymentsCSV:(id)sender {
    NSData *data = [self.store paymentsCSVWithRates:AccountExchangeRates()];
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[UTTypeCommaSeparatedText];
    panel.nameFieldStringValue = [NSString stringWithFormat:@"智枢矩阵-付款记录-%@.csv", AccountDayString(NSDate.date)];
    panel.message = @"导出全部账号的付款记录（日期、账号、供应商、付款方式、卡尾号、金额、折合人民币），可用 Numbers 或 Excel 打开。";
    __weak typeof(self) weakSelf = self;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK || !panel.URL) return;
        NSError *error = nil;
        if (![data writeToURL:panel.URL options:NSDataWritingAtomic error:&error])
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf showError:@"无法导出付款记录" detail:error.localizedDescription]; });
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
        [menu addItem:[self menuItem:@"打开授权链接…" symbol:@"person.badge.key" action:@selector(authorizeFromMenu:) object:ids]];
        if (self.sessions[account.identifier])
            [menu addItem:[self menuItem:@"查看当前会话" symbol:@"key.horizontal" action:@selector(sessionFromMenu:) object:ids]];
        [menu addItem:[NSMenuItem separatorItem]];
    }
    [menu addItem:[self menuItem:@"刷新用量与订阅" symbol:@"arrow.clockwise" action:@selector(refreshFromMenu:) object:ids]];
    [menu addItem:[self menuItem:accounts.count == 1 ? @"读取账单（档位与月费）" : @"读取所选账号的账单"
        symbol:@"creditcard" action:@selector(billingFromMenu:) object:ids]];
    if (accounts.count == 1)
        [menu addItem:[self menuItem:@"在浏览中打开账单页" symbol:@"safari" action:@selector(billingPageFromMenu:) object:ids]];
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *tagItem = [self menuItem:@"标签" symbol:@"tag" action:nil object:nil];
    NSMenu *tagMenu = [NSMenu new];
    for (NSString *tag in self.store.tags) {
        NSUInteger tagged = 0;
        for (Account *account in accounts) if ([account.tags containsObject:tag]) tagged++;
        NSMenuItem *item = [self menuItem:tag symbol:nil action:@selector(toggleTagFromMenu:) object:@{@"ids": ids, @"tag": tag}];
        item.state = tagged == accounts.count ? NSControlStateValueOn : (tagged ? NSControlStateValueMixed : NSControlStateValueOff);
        [tagMenu addItem:item];
    }
    if (tagMenu.numberOfItems) [tagMenu addItem:[NSMenuItem separatorItem]];
    [tagMenu addItem:[self menuItem:@"添加标签…" symbol:nil action:@selector(promptTagsFromMenu:) object:ids]];
    tagItem.submenu = tagMenu;
    [menu addItem:tagItem];

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

    NSMenuItem *supplierItem = [self menuItem:@"供应商" symbol:@"storefront" action:nil object:nil];
    NSMenu *supplierMenu = [NSMenu new];
    NSSet *currentSuppliers = [NSSet setWithArray:[accounts valueForKey:@"supplier"]];
    for (NSString *supplier in self.store.suppliers) {
        NSMenuItem *item = [self menuItem:supplier symbol:nil action:@selector(assignSupplierFromMenu:) object:@{@"ids": ids, @"supplier": supplier}];
        item.state = currentSuppliers.count == 1 && [currentSuppliers containsObject:supplier] ? NSControlStateValueOn : NSControlStateValueOff;
        [supplierMenu addItem:item];
    }
    if (!(currentSuppliers.count == 1 && [currentSuppliers containsObject:@""])) {
        [supplierMenu addItem:[NSMenuItem separatorItem]];
        [supplierMenu addItem:[self menuItem:@"清除供应商" symbol:nil action:@selector(assignSupplierFromMenu:) object:@{@"ids": ids, @"supplier": @""}]];
    }
    supplierItem.submenu = supplierMenu;
    [menu addItem:supplierItem];
    [menu addItem:[self menuItem:accounts.count == 1 ? @"设置付款信息…" : @"批量设置付款信息…" symbol:@"creditcard.and.123"
        action:@selector(paymentInfoFromMenu:) object:ids]];
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
- (void)authorizeFromMenu:(NSMenuItem *)sender { [self promptAuthorizationForAccountID:[sender.representedObject firstObject]]; }
- (void)promptGroupFromMenu:(NSMenuItem *)sender { [self promptGroupForAccountIDs:sender.representedObject]; }
- (void)promptTagsFromMenu:(NSMenuItem *)sender { [self promptTagsForAccountIDs:sender.representedObject]; }
- (void)refreshFromMenu:(NSMenuItem *)sender { [self refreshUsageForAccountIDs:sender.representedObject]; }
- (void)billingFromMenu:(NSMenuItem *)sender { [self readBillingForAccountIDs:sender.representedObject]; }
- (void)billingPageFromMenu:(NSMenuItem *)sender { [self openBillingPageForAccountID:[sender.representedObject firstObject]]; }
- (void)sessionFromMenu:(NSMenuItem *)sender {
    [self selectAccountID:[sender.representedObject firstObject]];
    [self showCurrentSession:sender];
}

- (void)toggleTagFromMenu:(NSMenuItem *)sender {
    NSDictionary *payload = sender.representedObject;
    NSString *tag = payload[@"tag"];
    NSArray<Account *> *accounts = [self.store accountsWithIDs:payload[@"ids"]];
    BOOL allTagged = YES;
    for (Account *account in accounts) if (![account.tags containsObject:tag]) allTagged = NO;
    for (Account *account in accounts) {
        NSMutableArray *tags = [account.tags mutableCopy];
        if (allTagged) [tags removeObject:tag]; else [tags addObject:tag];
        account.tags = tags;
    }
    [self.store commit];
}
- (void)exportFromMenu:(NSMenuItem *)sender { [self exportAccountIDs:sender.representedObject]; }
- (void)clearFromMenu:(NSMenuItem *)sender { [self clearLoginDataForAccountIDs:sender.representedObject]; }
- (void)deleteFromMenu:(NSMenuItem *)sender { [self deleteAccountIDs:sender.representedObject]; }

- (void)copyEmailFromMenu:(NSMenuItem *)sender {
    Account *account = [self.store accountWithID:[sender.representedObject firstObject]];
    if (!account.email.length) return;
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:account.email forType:NSPasteboardTypeString];
}

- (void)paymentInfoFromMenu:(NSMenuItem *)sender { [self promptPaymentInfoForAccountIDs:sender.representedObject]; }
- (void)setPaymentInfoForSelected:(id)sender { [self promptPaymentInfoForAccountIDs:[self targetAccountIDs]]; }

- (void)promptPaymentInfoForAccountIDs:(NSArray<NSString *> *)identifiers {
    NSArray<Account *> *accounts = [self.store accountsWithIDs:identifiers];
    if (!accounts.count) return;
    NSString *(^shared)(NSString *) = ^NSString *(NSString *key) {
        NSSet *values = [NSSet setWithArray:[accounts valueForKey:key]];
        return values.count == 1 ? values.anyObject : @"";
    };
    NSComboBox *supplier = [NSComboBox new];
    [supplier addItemsWithObjectValues:self.store.suppliers];
    supplier.stringValue = shared(@"supplier");
    NSComboBox *method = [NSComboBox new];
    [method addItemsWithObjectValues:self.store.paymentMethods];
    method.stringValue = shared(@"paymentMethod");
    NSTextField *card = [NSTextField new];
    card.stringValue = shared(@"cardLast4");
    card.placeholderString = @"卡号后 4 位";
    for (NSControl *control in @[supplier, method, card]) [control.widthAnchor constraintEqualToConstant:220].active = YES;
    if (accounts.count > 1)
        for (NSTextField *field in @[supplier, method, card])
            if (!field.stringValue.length) field.placeholderString = @"多个值，留空保持不变";
    NSGridView *grid = [NSGridView gridViewWithViews:@[
        @[DeskLabel(@"供应商", 13, NSFontWeightRegular), supplier],
        @[DeskLabel(@"付款方式", 13, NSFontWeightRegular), method],
        @[DeskLabel(@"卡尾号", 13, NSFontWeightRegular), card]]];
    grid.rowSpacing = 8;
    grid.columnSpacing = 10;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    grid.frame = NSMakeRect(0, 0, 310, grid.fittingSize.height);
    NSAlert *alert = [NSAlert new];
    alert.messageText = accounts.count == 1 ? [NSString stringWithFormat:@"设置“%@”的付款信息", accounts.firstObject.name]
        : [NSString stringWithFormat:@"设置 %lu 个账号的付款信息", (unsigned long)accounts.count];
    alert.informativeText = accounts.count == 1 ? @"卡号只保存后 4 位。" : @"填写的项目会应用到所有所选账号，留空的项目保持各账号原值。卡号只保存后 4 位。";
    alert.accessoryView = grid;
    [alert addButtonWithTitle:@"保存"];
    [alert addButtonWithTitle:@"取消"];
    [alert layout];
    alert.window.initialFirstResponder = supplier;
    __weak typeof(self) weakSelf = self;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        NSString *last4 = AccountCardLast4(card.stringValue);
        for (Account *account in accounts) {
            if (supplier.stringValue.length || accounts.count == 1) account.supplier = supplier.stringValue;
            if (method.stringValue.length || accounts.count == 1) account.paymentMethod = method.stringValue;
            if (last4.length || (accounts.count == 1 && !card.stringValue.length)) account.cardLast4 = last4;
        }
        [weakSelf.store commit];
    }];
}

- (void)assignSupplierFromMenu:(NSMenuItem *)sender {
    NSDictionary *payload = sender.representedObject;
    for (Account *account in [self.store accountsWithIDs:payload[@"ids"]]) account.supplier = payload[@"supplier"];
    [self.store commit];
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
- (void)addTagsToSelected:(id)sender { [self promptTagsForAccountIDs:[self targetAccountIDs]]; }
- (void)readBillingForSelected:(id)sender { [self readBillingForAccountIDs:[self targetAccountIDs]]; }
- (void)openBillingPageForSelected:(id)sender {
    NSArray<NSString *> *identifiers = [self targetAccountIDs];
    if (identifiers.count == 1) [self openBillingPageForAccountID:identifiers.firstObject];
}
- (void)clearSelectedLoginData:(id)sender { [self clearLoginDataForAccountIDs:[self targetAccountIDs]]; }
- (void)deleteSelectedAccounts:(id)sender { [self deleteAccountIDs:[self targetAccountIDs]]; }

#pragma mark - Validation

- (BOOL)validateAction:(SEL)action {
    if (self.locked) return NO;
    BrowserSession *visible = self.mode == DeskModeBrowser ? self.browser.session : nil;
    if (action == @selector(goBack:)) return visible.webView.canGoBack;
    if (action == @selector(goForward:)) return visible.webView.canGoForward;
    if (action == @selector(reloadPage:) || action == @selector(goHome:)) return visible != nil;
    if (action == @selector(showCurrentSession:) || action == @selector(syncSubscription:))
        return self.selectedAccountID && self.sessions[self.selectedAccountID];
    if (action == @selector(selectPreviousAccount:) || action == @selector(selectNextAccount:))
        return self.sidebar.visibleAccountIDs.count > 1;
    if (action == @selector(renameSelectedAccount:) || action == @selector(openAuthorizationLink:) ||
        action == @selector(openBillingPageForSelected:))
        return [self targetAccountIDs].count == 1;
    if (action == @selector(readBillingForSelected:) || action == @selector(setPaymentInfoForSelected:))
        return [self targetAccountIDs].count > 0;
    if (action == @selector(readAllBilling:)) return self.store.accounts.count > 0 && !self.billingReader.isReading;
    if (action == @selector(exportPaymentsCSV:)) {
        for (Account *account in self.store.accounts) if (account.payments.count) return YES;
        return NO;
    }
    if (action == @selector(exportRenewalCalendar:)) {
        for (Account *account in self.store.accounts) if (account.expiresAt) return YES;
        return NO;
    }
    if (action == @selector(refreshAllUsage:)) return self.store.accounts.count > 0;
    if (action == @selector(refreshSelectedUsage:) || action == @selector(addTagsToSelected:)) return [self targetAccountIDs].count > 0;
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

- (void)setLocked:(BOOL)locked {
    _locked = locked;
    [self updateToolbarState];
}

#pragma mark - Toolbar

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    return @[NSToolbarToggleSidebarItemIdentifier, NSToolbarSidebarTrackingSeparatorItemIdentifier,
             ToolbarBack, ToolbarForward, NSToolbarFlexibleSpaceItemIdentifier, ToolbarMode, NSToolbarFlexibleSpaceItemIdentifier,
             ToolbarReload, ToolbarHome, ToolbarAccountMenu, ToolbarRefreshUsage,
             NSToolbarInspectorTrackingSeparatorItemIdentifier, NSToolbarFlexibleSpaceItemIdentifier,
             NSToolbarToggleInspectorItemIdentifier];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    return [[self toolbarDefaultItemIdentifiers:toolbar] arrayByAddingObjectsFromArray:@[ToolbarAdd, NSToolbarSpaceItemIdentifier]];
}

- (NSToolbarItem *)accountMenuItem {
    NSPopUpButton *button = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
    button.bezelStyle = NSBezelStyleToolbar;
    NSMenuItem *title = [[NSMenuItem alloc] initWithTitle:@"账号" action:nil keyEquivalent:@""];
    title.image = [NSImage imageWithSystemSymbolName:@"person.crop.circle" accessibilityDescription:nil];
    [button.menu addItem:title];
    button.menu.delegate = self;
    button.toolTip = @"当前账号的操作：授权登录、读取账单、标签、分组…";
    self.accountMenuButton = button;
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:ToolbarAccountMenu];
    item.view = button;
    item.label = @"账号";
    item.autovalidates = NO;
    return item;
}

- (NSToolbarItem *)refreshUsageItem {
    NSButton *button = [NSButton buttonWithTitle:@"刷新用量" image:[NSImage imageWithSystemSymbolName:@"arrow.triangle.2.circlepath"
        accessibilityDescription:nil] target:self action:@selector(refreshAllUsage:)];
    button.bezelStyle = NSBezelStyleToolbar;
    button.imagePosition = NSImageLeading;
    button.toolTip = @"读取全部账号的额度、续费日期与是否自动续订（⇧⌘R）";
    self.refreshUsageButton = button;
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:ToolbarRefreshUsage];
    item.view = button;
    item.label = @"刷新用量";
    item.autovalidates = NO;
    return item;
}

- (void)updateToolbarState {
    [self.window.toolbar validateVisibleItems];
    BOOL refreshing = self.refresher.isRefreshing;
    self.refreshUsageButton.title = refreshing ? @"正在刷新…" : @"刷新用量";
    self.refreshUsageButton.enabled = !self.locked && !refreshing && self.store.accounts.count > 0;
    self.accountMenuButton.enabled = !self.locked && [self targetAccountIDs].count > 0;
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (menu != self.accountMenuButton.menu) return;
    NSMenuItem *title = menu.itemArray.firstObject;
    [menu removeAllItems];
    [menu addItem:title];
    NSMenu *actions = [NSMenu new];
    [self populateMenu:actions forAccountIDs:[self targetAccountIDs]];
    for (NSMenuItem *item in actions.itemArray.copy) {
        [actions removeItem:item];
        [menu addItem:item];
    }
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
    if ([identifier isEqualToString:ToolbarAccountMenu]) return [self accountMenuItem];
    if ([identifier isEqualToString:ToolbarRefreshUsage]) return [self refreshUsageItem];
    NSDictionary<NSString *, NSArray *> *specs = @{
        ToolbarBack: @[@"chevron.backward", @"后退", NSStringFromSelector(@selector(goBack:))],
        ToolbarForward: @[@"chevron.forward", @"前进", NSStringFromSelector(@selector(goForward:))],
        ToolbarReload: @[@"arrow.clockwise", @"重新载入", NSStringFromSelector(@selector(reloadPage:))],
        ToolbarHome: @[@"house", @"ChatGPT 首页", NSStringFromSelector(@selector(goHome:))],
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
