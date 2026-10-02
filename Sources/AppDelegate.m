#import "AppDelegate.h"
#import "Account.h"
#import "AccountAlerts.h"
#import "AccountRefresher.h"
#import "AppLock.h"
#import "BackupManager.h"
#import "MainWindowController.h"
#import "SettingsWindowController.h"
#import "StatusItemController.h"

@interface AppDelegate () <NSMenuItemValidation>
@property (nonatomic, strong) AccountStore *store;
@property (nonatomic, strong) MainWindowController *windowController;
@property (nonatomic, strong, nullable) SettingsWindowController *settingsController;
@property (nonatomic, strong) BackupManager *backup;
@property (nonatomic, strong) AccountAlerts *alerts;
@property (nonatomic, strong) AppLock *lock;
@property (nonatomic, strong) StatusItemController *statusItem;
@property (nonatomic, strong, nullable) NSTimer *alertTimer;
/// The lock screen came up before the main window was ever shown.
@property (nonatomic) BOOL showWindowAfterUnlock;
@end

@implementation AppDelegate

- (NSURL *)resolvedDataDirectory {
    if (self.dataDirectory) return self.dataDirectory;
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    // Kept from the app's former name (ChatGPT Account Desk) so existing accounts carry over.
    return [support URLByAppendingPathComponent:@"ChatGPTAccountDesk" isDirectory:YES];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSString *iconPath = [NSBundle.mainBundle pathForResource:@"AppIcon" ofType:@"icns"];
    NSImage *icon = iconPath ? [[NSImage alloc] initWithContentsOfFile:iconPath] : nil;
    if (icon) NSApp.applicationIconImage = icon;

    MigrateUsageRefreshToDaily();
    NSURL *directory = [self resolvedDataDirectory];
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
    self.store = [[AccountStore alloc] initWithFileURL:[directory URLByAppendingPathComponent:@"accounts.json"]];
    NSError *loadError = nil;
    BOOL loaded = [self.store load:&loadError];

    self.windowController = [[MainWindowController alloc] initWithStore:self.store];
    self.backup = [[BackupManager alloc] initWithStore:self.store directory:[directory URLByAppendingPathComponent:@"Backups" isDirectory:YES]];
    self.alerts = [[AccountAlerts alloc] initWithStore:self.store];
    self.lock = [AppLock new];
    self.statusItem = [[StatusItemController alloc] initWithStore:self.store];
    [self wireServices];
    [self buildMenus];

    // Lock before anything is shown, so account details never flash on screen.
    [self.lock start];
    if (self.lock.isLocked) {
        self.showWindowAfterUnlock = YES;
        [self.lock showLockScreen];
    } else {
        [self showMainWindow];
    }
    [self.statusItem applySettings];
    [self.alerts start];
    if (loaded) [self.backup scheduleAutomaticBackup];

    if (!loaded) {
        NSString *detail = loadError.localizedDescription ?: @"";
        if (self.store.recoveredBackupURL)
            detail = [detail stringByAppendingFormat:@"\n\n原文件已备份为 %@，应用将以空列表启动。", self.store.recoveredBackupURL.lastPathComponent];
        [self.windowController showError:@"无法读取账号列表" detail:detail];
    }
}

- (void)wireServices {
    __weak typeof(self) weakSelf = self;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(storeDidChange:) name:AccountStoreDidChangeNotification object:self.store];
    [center addObserver:self selector:@selector(statusItemSettingsChanged:) name:StatusItemSettingsDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(alertSettingsChanged:) name:AlertSettingsDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(windowWillClose:) name:NSWindowWillCloseNotification object:self.windowController.window];
    [center addObserver:self selector:@selector(dayChanged:) name:NSCalendarDayChangedNotification object:nil];

    self.windowController.loginDataCleared = ^(NSArray<NSString *> *identifiers) { [weakSelf.alerts forgetSignInOfAccountIDs:identifiers]; };
    self.alerts.openAccount = ^(NSString *identifier) { [weakSelf openAccountID:identifier]; };
    self.lock.lockStateChanged = ^(BOOL locked) { [weakSelf lockStateChanged:locked]; };

    self.statusItem.openAccount = ^(NSString *identifier) { [weakSelf openAccountID:identifier]; };
    self.statusItem.isRefreshing = ^BOOL { return weakSelf.windowController.isRefreshingUsage; };
    self.statusItem.isLocked = ^BOOL { return weakSelf.lock.isLocked; };
    self.statusItem.canLock = ^BOOL { return weakSelf.lock.isEnabled; };
    self.statusItem.perform = ^(StatusItemCommand command) { [weakSelf performStatusCommand:command]; };

    // Renewal reminders depend on the date, not only on changes to the list.
    self.alertTimer = [NSTimer scheduledTimerWithTimeInterval:3600 target:self.alerts selector:@selector(evaluate) userInfo:nil repeats:YES];
    self.alertTimer.tolerance = 300;
}

- (void)storeDidChange:(NSNotification *)notification {
    [self.statusItem update];
    [self.alerts evaluate];
    [self.backup scheduleAutomaticBackup];
}

- (void)dayChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.alerts evaluate];
        [self.statusItem update];
    });
}

- (void)alertSettingsChanged:(NSNotification *)notification { [self.alerts evaluate]; }

- (void)statusItemSettingsChanged:(NSNotification *)notification {
    [self.statusItem applySettings];
    if (!self.keepsRunningInMenuBar) [self showDockIcon];
}

- (BOOL)keepsRunningInMenuBar {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    return [defaults boolForKey:StatusItemEnabledDefaultsKey] && [defaults boolForKey:KeepRunningInMenuBarDefaultsKey];
}

#pragma mark - Windows

- (void)showDockIcon {
    if (NSApp.activationPolicy != NSApplicationActivationPolicyRegular)
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
}

- (void)showMainWindow {
    if (self.lock.isLocked) {
        self.showWindowAfterUnlock = YES;
        [self.lock showLockScreen];
        return;
    }
    [self showDockIcon];
    [self.windowController showWindow:nil];
    [NSApp activate];
}

- (void)openAccountID:(NSString *)identifier {
    if (self.lock.isLocked) {
        [self.lock showLockScreen];
        return;
    }
    [self showMainWindow];
    [self.windowController openAccountID:identifier];
}

- (void)windowWillClose:(NSNotification *)notification {
    if (!self.keepsRunningInMenuBar) return;
    // Hide the Dock icon once nothing but the menu bar item is left.
    dispatch_async(dispatch_get_main_queue(), ^{
        for (NSWindow *window in NSApp.windows)
            if (window.isVisible && ![window isKindOfClass:NSPanel.class] && window.canBecomeMainWindow) return;
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    });
}

- (void)lockStateChanged:(BOOL)locked {
    self.windowController.locked = locked;
    [self.statusItem update];
    if (locked) {
        [self.settingsController.window orderOut:nil];
        return;
    }
    if (self.showWindowAfterUnlock) {
        self.showWindowAfterUnlock = NO;
        [self showMainWindow];
    }
}

- (void)performStatusCommand:(StatusItemCommand)command {
    switch (command) {
        case StatusItemCommandShowWindow:
            [self showMainWindow];
            [self.windowController showBrowser:nil];
            break;
        case StatusItemCommandShowManagement:
            [self showMainWindow];
            [self.windowController showManagement:nil];
            break;
        case StatusItemCommandRefreshAll:
            [self.windowController refreshAllUsage:nil];
            break;
        case StatusItemCommandSettings:
            [self showSettings:nil];
            break;
        case StatusItemCommandLock:
            [self.lock lock];
            break;
        case StatusItemCommandUnlock:
            [self.lock showLockScreen];
            break;
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return !self.keepsRunningInMenuBar; }

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)visible {
    if (self.lock.isLocked) [self.lock showLockScreen];
    else if (!self.windowController.window.isVisible) [self showMainWindow];
    return NO;
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app { return YES; }

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.settingsController commitEditing];
    [self.windowController prepareForTermination];
}

#pragma mark - Actions

- (SettingsWindowController *)settings {
    if (!self.settingsController)
        self.settingsController = [[SettingsWindowController alloc] initWithStore:self.store backup:self.backup alerts:self.alerts lock:self.lock];
    return self.settingsController;
}

- (void)showSettings:(id)sender {
    if (self.lock.isLocked) { [self.lock showLockScreen]; return; }
    [self showDockIcon];
    [self.settings showWindow:sender];
    [NSApp activate];
}

- (void)showBackupSettings:(id)sender {
    if (self.lock.isLocked) { [self.lock showLockScreen]; return; }
    [self showDockIcon];
    [self.settings showPane:SettingsPaneBackup];
    [NSApp activate];
}

- (void)backupNow:(id)sender {
    NSError *error = nil;
    NSURL *file = [self.backup backupNow:&error];
    NSAlert *alert = [NSAlert new];
    alert.messageText = file ? @"已备份" : @"备份失败";
    BOOL remote = [NSUserDefaults.standardUserDefaults boolForKey:WebDAVEnabledDefaultsKey];
    alert.informativeText = file
        ? [NSString stringWithFormat:@"账号资料已保存为 %@%@", file.lastPathComponent, remote ? @"，并正在上传到 WebDAV。" : @"。"]
        : error.localizedDescription ?: @"";
    if (file) [alert addButtonWithTitle:@"好"];
    if (file) [alert addButtonWithTitle:@"在访达中显示"];
    NSWindow *window = self.windowController.window;
    void (^done)(NSModalResponse) = ^(NSModalResponse response) {
        if (file && response == NSAlertSecondButtonReturn) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[file]];
    };
    if (window.isVisible && !window.attachedSheet) [alert beginSheetModalForWindow:window completionHandler:done];
    else done([alert runModal]);
}

- (void)lockApp:(id)sender { [self.lock lock]; }

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    SEL action = item.action;
    if (action == @selector(lockApp:)) return self.lock.isEnabled && !self.lock.isLocked;
    if (action == @selector(showSettings:) || action == @selector(showBackupSettings:) || action == @selector(backupNow:))
        return !self.lock.isLocked;
    return YES;
}

#pragma mark - Menus

- (NSMenu *)addMenu:(NSString *)title to:(NSMenu *)mainMenu {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:title];
    item.submenu = menu;
    [mainMenu addItem:item];
    return menu;
}

- (NSMenuItem *)add:(NSString *)title action:(SEL)action key:(NSString *)key
    modifiers:(NSEventModifierFlags)modifiers to:(NSMenu *)menu target:(id)target {
    NSMenuItem *item = [menu addItemWithTitle:title action:action keyEquivalent:key ?: @""];
    if (key.length) item.keyEquivalentModifierMask = modifiers;
    item.target = target;
    return item;
}

- (void)buildMenus {
    MainWindowController *controller = self.windowController;
    NSEventModifierFlags command = NSEventModifierFlagCommand;
    NSEventModifierFlags shift = NSEventModifierFlagShift;
    NSEventModifierFlags option = NSEventModifierFlagOption;
    NSEventModifierFlags control = NSEventModifierFlagControl;
    NSString *up = [NSString stringWithFormat:@"%C", (unichar)NSUpArrowFunctionKey];
    NSString *down = [NSString stringWithFormat:@"%C", (unichar)NSDownArrowFunctionKey];
    NSMenu *mainMenu = [NSMenu new];

    NSMenu *app = [self addMenu:@"智枢矩阵" to:mainMenu];
    [self add:@"关于智枢矩阵" action:@selector(orderFrontStandardAboutPanel:) key:nil modifiers:0 to:app target:NSApp];
    [app addItem:[NSMenuItem separatorItem]];
    [self add:@"设置…" action:@selector(showSettings:) key:@"," modifiers:command to:app target:self];
    [self add:@"锁定智枢矩阵" action:@selector(lockApp:) key:nil modifiers:0 to:app target:self];
    [app addItem:[NSMenuItem separatorItem]];
    [self add:@"隐藏智枢矩阵" action:@selector(hide:) key:@"h" modifiers:command to:app target:NSApp];
    [self add:@"隐藏其他" action:@selector(hideOtherApplications:) key:@"h" modifiers:command | option to:app target:NSApp];
    [self add:@"全部显示" action:@selector(unhideAllApplications:) key:nil modifiers:0 to:app target:NSApp];
    [app addItem:[NSMenuItem separatorItem]];
    [self add:@"退出智枢矩阵" action:@selector(terminate:) key:@"q" modifiers:command to:app target:NSApp];

    NSMenu *file = [self addMenu:@"文件" to:mainMenu];
    [self add:@"添加账号…" action:@selector(addAccount:) key:@"n" modifiers:command to:file target:controller];
    [file addItem:[NSMenuItem separatorItem]];
    // No shortcut: ⇧⌘I belongs to ChatGPT's custom instructions and menu shortcuts win over the page.
    [self add:@"导入账号资料…" action:@selector(importAccounts:) key:nil modifiers:0 to:file target:controller];
    [self add:@"导出全部账号资料…" action:@selector(exportAccounts:) key:@"e" modifiers:command | shift to:file target:controller];
    [self add:@"导出续费日历（.ics）…" action:@selector(exportRenewalCalendar:) key:nil modifiers:0 to:file target:controller];
    [self add:@"导出付款记录（CSV）…" action:@selector(exportPaymentsCSV:) key:nil modifiers:0 to:file target:controller];
    [file addItem:[NSMenuItem separatorItem]];
    [self add:@"立即备份" action:@selector(backupNow:) key:nil modifiers:0 to:file target:self];
    [self add:@"备份与恢复…" action:@selector(showBackupSettings:) key:nil modifiers:0 to:file target:self];
    [self add:@"在访达中显示数据文件" action:@selector(revealDataFile:) key:nil modifiers:0 to:file target:controller];
    [file addItem:[NSMenuItem separatorItem]];
    [self add:@"关闭窗口" action:@selector(performClose:) key:nil modifiers:0 to:file target:nil];

    NSMenu *edit = [self addMenu:@"编辑" to:mainMenu];
    [self add:@"撤销" action:@selector(undo:) key:@"z" modifiers:command to:edit target:nil];
    [self add:@"重做" action:@selector(redo:) key:@"z" modifiers:command | shift to:edit target:nil];
    [edit addItem:[NSMenuItem separatorItem]];
    [self add:@"剪切" action:@selector(cut:) key:@"x" modifiers:command to:edit target:nil];
    [self add:@"复制" action:@selector(copy:) key:@"c" modifiers:command to:edit target:nil];
    [self add:@"粘贴" action:@selector(paste:) key:@"v" modifiers:command to:edit target:nil];
    [edit addItem:[NSMenuItem separatorItem]];
    [self add:@"全选" action:@selector(selectAll:) key:@"a" modifiers:command to:edit target:nil];
    [edit addItem:[NSMenuItem separatorItem]];
    [self add:@"搜索账号" action:@selector(focusSearch:) key:@"f" modifiers:command to:edit target:controller];

    NSMenu *view = [self addMenu:@"显示" to:mainMenu];
    [self add:@"浏览" action:@selector(showBrowser:) key:@"1" modifiers:command to:view target:controller];
    [self add:@"账号管理" action:@selector(showManagement:) key:@"2" modifiers:command to:view target:controller];
    [view addItem:[NSMenuItem separatorItem]];
    [self add:@"隐藏侧边栏" action:@selector(toggleSidebar:) key:@"s" modifiers:command | control to:view target:controller];
    [self add:@"隐藏账号详情" action:@selector(toggleInspector:) key:@"i" modifiers:command | control to:view target:controller];
    [view addItem:[NSMenuItem separatorItem]];
    [self add:@"释放后台账号页面" action:@selector(releaseBackgroundPages:) key:nil modifiers:0 to:view target:controller];
    [view addItem:[NSMenuItem separatorItem]];
    [self add:@"进入全屏幕" action:@selector(toggleFullScreen:) key:@"f" modifiers:command | control to:view target:nil];

    NSMenu *account = [self addMenu:@"账号" to:mainMenu];
    [self add:@"上一个账号" action:@selector(selectPreviousAccount:) key:up modifiers:command | option to:account target:controller];
    [self add:@"下一个账号" action:@selector(selectNextAccount:) key:down modifiers:command | option to:account target:controller];
    [account addItem:[NSMenuItem separatorItem]];
    [self add:@"后退" action:@selector(goBack:) key:@"[" modifiers:command to:account target:controller];
    [self add:@"前进" action:@selector(goForward:) key:@"]" modifiers:command to:account target:controller];
    [self add:@"重新载入页面" action:@selector(reloadPage:) key:@"r" modifiers:command to:account target:controller];
    [self add:@"ChatGPT 首页" action:@selector(goHome:) key:@"h" modifiers:command | shift to:account target:controller];
    [account addItem:[NSMenuItem separatorItem]];
    [self add:@"刷新全部账号用量" action:@selector(refreshAllUsage:) key:@"r" modifiers:command | shift to:account target:controller];
    [self add:@"刷新所选账号用量" action:@selector(refreshSelectedUsage:) key:nil modifiers:0 to:account target:controller];
    [self add:@"读取所选账号的账单（档位与月费）" action:@selector(readBillingForSelected:) key:nil modifiers:0 to:account target:controller];
    [self add:@"后台读取全部账号账单" action:@selector(readAllBilling:) key:nil modifiers:0 to:account target:controller];
    [self add:@"在浏览中打开账单页" action:@selector(openBillingPageForSelected:) key:nil modifiers:0 to:account target:controller];
    [self add:@"从当前页面读取订阅" action:@selector(syncSubscription:) key:nil modifiers:0 to:account target:controller];
    [self add:@"查看当前会话" action:@selector(showCurrentSession:) key:@"k" modifiers:command | shift to:account target:controller];
    [self add:@"打开授权链接…" action:@selector(openAuthorizationLink:) key:@"l" modifiers:command | shift to:account target:controller];
    [account addItem:[NSMenuItem separatorItem]];
    [self add:@"重命名…" action:@selector(renameSelectedAccount:) key:nil modifiers:0 to:account target:controller];
    [self add:@"移动到分组…" action:@selector(moveSelectedToGroup:) key:nil modifiers:0 to:account target:controller];
    [self add:@"添加标签…" action:@selector(addTagsToSelected:) key:nil modifiers:0 to:account target:controller];
    [self add:@"清除登录数据…" action:@selector(clearSelectedLoginData:) key:nil modifiers:0 to:account target:controller];
    [self add:@"删除账号…" action:@selector(deleteSelectedAccounts:) key:nil modifiers:0 to:account target:controller];

    NSMenu *window = [self addMenu:@"窗口" to:mainMenu];
    [self add:@"最小化" action:@selector(performMiniaturize:) key:@"m" modifiers:command to:window target:nil];
    [self add:@"缩放" action:@selector(performZoom:) key:nil modifiers:0 to:window target:nil];
    [window addItem:[NSMenuItem separatorItem]];
    [self add:@"智枢矩阵" action:@selector(showMainWindowFromMenu:) key:@"0" modifiers:command to:window target:self];
    [self add:@"前置全部窗口" action:@selector(arrangeInFront:) key:nil modifiers:0 to:window target:nil];

    NSApp.mainMenu = mainMenu;
    NSApp.windowsMenu = window;
}

- (void)showMainWindowFromMenu:(id)sender { [self showMainWindow]; }
@end
