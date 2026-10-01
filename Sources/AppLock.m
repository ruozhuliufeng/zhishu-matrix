#import "AppLock.h"
#import <LocalAuthentication/LocalAuthentication.h>
#import "DeskUI.h"

NSString *const AppLockEnabledDefaultsKey = @"appLockEnabled";
NSString *const AppLockIdleMinutesDefaultsKey = @"appLockIdleMinutes";
NSString *const AppLockOnScreenLockDefaultsKey = @"appLockOnScreenLock";
NSNotificationName const AppLockSettingsDidChangeNotification = @"AppLockSettingsDidChangeNotification";

@interface AppLock () <NSWindowDelegate>
@property (nonatomic, strong, nullable) NSWindow *lockWindow;
@property (nonatomic, strong, nullable) NSTextField *messageLabel;
@property (nonatomic, strong, nullable) NSButton *unlockButton;
@property (nonatomic, strong) NSMutableArray<NSWindow *> *hiddenWindows;
@property (nonatomic, strong, nullable) NSTimer *idleTimer;
@property (nonatomic, strong, nullable) NSDate *resignedActiveAt;
@property (nonatomic) BOOL authenticating;
@end

@implementation AppLock

+ (BOOL)canAuthenticate:(NSString **)reason {
    NSError *error = nil;
    BOOL can = [[LAContext new] canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&error];
    if (!can && reason) *reason = error.localizedDescription ?: @"这台 Mac 未设置登录密码";
    return can;
}

+ (void)authenticateWithReason:(NSString *)reason completion:(void (^)(BOOL, NSString *))completion {
    LAContext *context = [LAContext new];
    context.localizedCancelTitle = @"取消";
    [context evaluatePolicy:LAPolicyDeviceOwnerAuthentication localizedReason:reason reply:^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL cancelled = error.code == LAErrorUserCancel || error.code == LAErrorSystemCancel || error.code == LAErrorAppCancel;
            completion(success, success || cancelled ? nil : error.localizedDescription);
        });
    }];
}

- (instancetype)init {
    if ((self = [super init])) {
        _hiddenWindows = [NSMutableArray array];
        [NSUserDefaults.standardUserDefaults registerDefaults:@{AppLockOnScreenLockDefaultsKey: @YES}];
    }
    return self;
}

- (BOOL)isEnabled {
    return [NSUserDefaults.standardUserDefaults boolForKey:AppLockEnabledDefaultsKey] && [AppLock canAuthenticate:NULL];
}

- (void)start {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(settingsChanged:) name:AppLockSettingsDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(appResigned:) name:NSApplicationDidResignActiveNotification object:nil];
    [center addObserver:self selector:@selector(appActivated:) name:NSApplicationDidBecomeActiveNotification object:nil];
    NSNotificationCenter *workspace = NSWorkspace.sharedWorkspace.notificationCenter;
    [workspace addObserver:self selector:@selector(screenLocked:) name:NSWorkspaceScreensDidSleepNotification object:nil];
    [workspace addObserver:self selector:@selector(screenLocked:) name:NSWorkspaceWillSleepNotification object:nil];
    [workspace addObserver:self selector:@selector(screenLocked:) name:NSWorkspaceSessionDidResignActiveNotification object:nil];
    [NSDistributedNotificationCenter.defaultCenter addObserver:self selector:@selector(screenLocked:)
        name:@"com.apple.screenIsLocked" object:nil];
    [self settingsChanged:nil];
    if (self.enabled) [self lock];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
    [NSDistributedNotificationCenter.defaultCenter removeObserver:self];
}

- (void)settingsChanged:(NSNotification *)notification {
    [self.idleTimer invalidate];
    self.idleTimer = nil;
    if (!self.enabled || [NSUserDefaults.standardUserDefaults integerForKey:AppLockIdleMinutesDefaultsKey] <= 0) return;
    self.idleTimer = [NSTimer scheduledTimerWithTimeInterval:20 target:self selector:@selector(checkIdle) userInfo:nil repeats:YES];
    self.idleTimer.tolerance = 5;
}

- (void)checkIdle {
    NSInteger minutes = [NSUserDefaults.standardUserDefaults integerForKey:AppLockIdleMinutesDefaultsKey];
    if (self.locked || !self.enabled || minutes <= 0) return;
    NSTimeInterval limit = minutes * 60;
    CFTimeInterval idle = CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateCombinedSessionState, kCGAnyInputEventType);
    BOOL away = self.resignedActiveAt && -self.resignedActiveAt.timeIntervalSinceNow >= limit;
    if (idle >= limit || away) [self lock];
}

- (void)appResigned:(NSNotification *)notification { self.resignedActiveAt = NSDate.date; }

- (void)appActivated:(NSNotification *)notification {
    self.resignedActiveAt = nil;
    if (self.locked) [self showLockScreen];
}

- (void)screenLocked:(NSNotification *)notification {
    if (self.enabled && [NSUserDefaults.standardUserDefaults boolForKey:AppLockOnScreenLockDefaultsKey]) [self lock];
}

#pragma mark - Locking

- (void)lock {
    if (self.locked || !self.enabled) return;
    _locked = YES;
    [self.hiddenWindows removeAllObjects];
    for (NSWindow *window in NSApp.windows) {
        // Only document-style windows: the menu bar item and panels live in borderless windows.
        if (!window.isVisible || window == self.lockWindow || !(window.styleMask & NSWindowStyleMaskTitled)) continue;
        [self.hiddenWindows addObject:window];
        // Sheets stay attached to their parent and are hidden with it.
        if (!window.sheetParent) [window orderOut:nil];
    }
    [self buildLockWindowIfNeeded];
    if (self.lockStateChanged) self.lockStateChanged(YES);
    if (NSApp.isActive) [self showLockScreen];
}

- (void)buildLockWindowIfNeeded {
    if (self.lockWindow) return;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 360, 280)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskFullSizeContentView
        backing:NSBackingStoreBuffered defer:NO];
    window.title = @"智枢矩阵";
    window.titleVisibility = NSWindowTitleHidden;
    window.titlebarAppearsTransparent = YES;
    window.releasedWhenClosed = NO;
    window.restorable = NO;
    window.delegate = self;
    NSVisualEffectView *background = [NSVisualEffectView new];
    background.material = NSVisualEffectMaterialUnderWindowBackground;
    window.contentView = background;

    NSImageView *icon = [NSImageView imageViewWithImage:NSApp.applicationIconImage ?: [NSImage imageNamed:NSImageNameApplicationIcon]];
    [icon.widthAnchor constraintEqualToConstant:72].active = YES;
    [icon.heightAnchor constraintEqualToConstant:72].active = YES;
    NSImageView *lock = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"lock.fill" accessibilityDescription:nil]];
    lock.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightSemibold];
    lock.contentTintColor = NSColor.secondaryLabelColor;
    NSTextField *title = DeskLabel(@"智枢矩阵已锁定", 17, NSFontWeightSemibold);
    NSStackView *titleRow = [NSStackView stackViewWithViews:@[lock, title]];
    titleRow.spacing = 6;
    self.messageLabel = DeskLabel(@"使用 Touch ID 或 Mac 登录密码解锁", 12, NSFontWeightRegular);
    self.messageLabel.textColor = NSColor.secondaryLabelColor;
    self.messageLabel.alignment = NSTextAlignmentCenter;
    self.unlockButton = [NSButton buttonWithTitle:@"解锁" target:self action:@selector(unlockClicked:)];
    self.unlockButton.keyEquivalent = @"\r";
    self.unlockButton.controlSize = NSControlSizeLarge;
    NSButton *quit = [NSButton buttonWithTitle:@"退出" target:NSApp action:@selector(terminate:)];
    quit.bordered = NO;
    quit.contentTintColor = NSColor.secondaryLabelColor;
    NSStackView *stack = [NSStackView stackViewWithViews:@[icon, titleRow, self.messageLabel, self.unlockButton, quit]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.spacing = 10;
    [stack setCustomSpacing:16 afterView:icon];
    [stack setCustomSpacing:18 afterView:self.messageLabel];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [background addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:background.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:background.centerYAnchor constant:6],
        [self.unlockButton.widthAnchor constraintGreaterThanOrEqualToConstant:140]
    ]];
    [window center];
    self.lockWindow = window;
}

- (void)showLockScreen {
    if (!self.locked) return;
    [self buildLockWindowIfNeeded];
    [NSApp activate];
    [self.lockWindow makeKeyAndOrderFront:nil];
    [self authenticate];
}

- (void)unlockClicked:(id)sender { [self authenticate]; }

- (void)authenticate {
    if (self.authenticating || !self.locked) return;
    self.authenticating = YES;
    self.unlockButton.enabled = NO;
    self.messageLabel.textColor = NSColor.secondaryLabelColor;
    self.messageLabel.stringValue = @"使用 Touch ID 或 Mac 登录密码解锁";
    __weak typeof(self) weakSelf = self;
    [AppLock authenticateWithReason:@"解锁智枢矩阵" completion:^(BOOL success, NSString *failure) {
        AppLock *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.authenticating = NO;
        strongSelf.unlockButton.enabled = YES;
        if (success) {
            [strongSelf unlock];
        } else if (failure) {
            strongSelf.messageLabel.stringValue = failure;
            strongSelf.messageLabel.textColor = NSColor.systemRedColor;
        }
    }];
}

- (void)unlock {
    _locked = NO;
    self.resignedActiveAt = nil;
    [self.lockWindow orderOut:nil];
    for (NSWindow *window in self.hiddenWindows) if (!window.sheetParent) [window orderFront:nil];
    [self.hiddenWindows.firstObject makeKeyWindow];
    [self.hiddenWindows removeAllObjects];
    if (self.lockStateChanged) self.lockStateChanged(NO);
}

- (BOOL)windowShouldClose:(NSWindow *)sender { return NO; }
@end
