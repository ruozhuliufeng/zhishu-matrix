#import "AuthorizationWindowController.h"
#import "Account.h"
#import "AuthorizationLink.h"
#import "BrowserSession.h"
#import "DeskUI.h"

static NSString *HostAndPort(NSURL *url) {
    return url.port ? [NSString stringWithFormat:@"%@:%@", url.host, url.port] : (url.host ?: @"");
}

static NSString *const CopyTitle = @"复制回调地址";

@interface AuthorizationWindowController () <NSWindowDelegate>
@property (nonatomic, readwrite) AuthorizationState state;
@property (nonatomic, readwrite, nullable) NSURL *callbackURL;
@property (nonatomic) BOOL capturesCallback;
@property (nonatomic, strong) BrowserSession *session;
@property (nonatomic, strong) NSURL *initialURL;
@property (nonatomic, strong) NSMutableSet<NSString *> *origins;
@property (nonatomic, copy, nullable) NSString *handoffMessage;
@property (nonatomic, strong) DeskFillView *banner;
@property (nonatomic, strong) NSImageView *statusIcon;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSTextField *callbackLabel;
@property (nonatomic, strong) NSButton *callbackCopyButton;
@property (nonatomic, strong) NSButton *actionButton;
@property (nonatomic, strong) DeskProgressLine *progressLine;
@end

@implementation AuthorizationWindowController

- (instancetype)initWithAccount:(Account *)account URL:(NSURL *)url dataStore:(WKWebsiteDataStore *)dataStore
    captureCallback:(BOOL)captureCallback {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 880, 720)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    if ((self = [super initWithWindow:window])) {
        _accountID = [account.identifier copy];
        _initialURL = url;
        _capturesCallback = captureCallback;
        _origins = [NSMutableSet setWithObject:AuthorizationOrigin(url)];
        window.title = [NSString stringWithFormat:@"授权登录 · %@", account.name];
        window.minSize = NSMakeSize(560, 460);
        window.releasedWhenClosed = NO;
        window.restorable = NO;
        window.delegate = self;

        _session = [[BrowserSession alloc] initWithAccountID:account.identifier dataStore:dataStore initialURL:url];
        __weak typeof(self) weakSelf = self;
        _session.stateChanged = ^(BrowserSession *session) { [weakSelf sessionChanged]; };
        _session.allowsNavigation = ^BOOL(BrowserSession *session, NSURL *target) {
            AuthorizationWindowController *strongSelf = weakSelf;
            return strongSelf ? [strongSelf allowsNavigationTo:target] : YES;
        };
        _session.externalURLOpened = ^(BrowserSession *session, NSURL *target, BOOL opened) {
            [weakSelf handedOffURL:target opened:opened];
        };
        [self buildContent];
        [self updateStatus];
        [window center];
    }
    return self;
}

- (void)buildContent {
    NSView *root = [NSView new];
    self.window.contentView = root;
    self.banner = [DeskFillView new];
    self.statusIcon = [NSImageView new];
    self.statusIcon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightMedium];
    self.statusLabel = DeskLabel(@"", 12, NSFontWeightRegular);
    self.statusLabel.selectable = YES;
    self.statusLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.callbackLabel = DeskLabel(@"", 11, NSFontWeightRegular);
    self.callbackLabel.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.callbackLabel.textColor = NSColor.secondaryLabelColor;
    self.callbackLabel.selectable = YES;
    self.callbackLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    for (NSTextField *label in @[self.statusLabel, self.callbackLabel])
        [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *labels = [NSStackView stackViewWithViews:@[self.statusLabel, self.callbackLabel]];
    labels.orientation = NSUserInterfaceLayoutOrientationVertical;
    labels.alignment = NSLayoutAttributeLeading;
    labels.spacing = 3;
    [labels setClippingResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.callbackCopyButton = DeskButton(CopyTitle, @"doc.on.doc", self, @selector(copyCallbackURL:));
    self.callbackCopyButton.toolTip = @"复制完整的回调地址（包含一次性授权码），粘贴到客户端或在客户端所在设备上打开";
    self.actionButton = DeskButton(@"重新载入", nil, self, @selector(performAction:));
    for (NSButton *button in @[self.callbackCopyButton, self.actionButton]) {
        button.controlSize = NSControlSizeSmall;
        [button setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    }
    NSStackView *buttons = [NSStackView stackViewWithViews:@[self.callbackCopyButton, self.actionButton]];
    buttons.spacing = 8;
    NSBox *separator = DeskSeparator();
    self.progressLine = [DeskProgressLine new];
    WKWebView *webView = self.session.webView;

    for (NSView *view in @[self.banner, separator, webView, self.progressLine]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [root addSubview:view];
    }
    for (NSView *view in @[self.statusIcon, labels, buttons]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [self.banner addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [self.banner.topAnchor constraintEqualToAnchor:root.topAnchor],
        [self.banner.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [self.banner.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [self.banner.heightAnchor constraintGreaterThanOrEqualToConstant:38],
        [labels.topAnchor constraintGreaterThanOrEqualToAnchor:self.banner.topAnchor constant:9],
        [labels.centerYAnchor constraintEqualToAnchor:self.banner.centerYAnchor],
        [self.statusIcon.leadingAnchor constraintEqualToAnchor:self.banner.leadingAnchor constant:14],
        [self.statusIcon.centerYAnchor constraintEqualToAnchor:self.banner.centerYAnchor],
        [self.statusIcon.widthAnchor constraintEqualToConstant:18],
        [labels.leadingAnchor constraintEqualToAnchor:self.statusIcon.trailingAnchor constant:8],
        [labels.trailingAnchor constraintLessThanOrEqualToAnchor:buttons.leadingAnchor constant:-12],
        [buttons.trailingAnchor constraintEqualToAnchor:self.banner.trailingAnchor constant:-12],
        [buttons.centerYAnchor constraintEqualToAnchor:self.banner.centerYAnchor],
        [separator.topAnchor constraintEqualToAnchor:self.banner.bottomAnchor],
        [separator.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [separator.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [webView.topAnchor constraintEqualToAnchor:separator.bottomAnchor],
        [webView.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [webView.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [webView.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [self.progressLine.topAnchor constraintEqualToAnchor:separator.bottomAnchor],
        [self.progressLine.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [self.progressLine.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [self.progressLine.heightAnchor constraintEqualToConstant:2]
    ]];
    NSLayoutConstraint *compact = [self.banner.heightAnchor constraintEqualToConstant:38];
    compact.priority = NSLayoutPriorityDefaultLow;
    compact.active = YES;
}

#pragma mark - Callback detection

/// A loopback address reached after the flow visited another origin is the client's callback.
- (BOOL)isCallbackURL:(NSURL *)url {
    if (!AuthorizationIsLoopbackURL(url)) return NO;
    NSString *origin = AuthorizationOrigin(url);
    return [self.origins objectsPassingTest:^BOOL(NSString *other, BOOL *stop) {
        return ![other isEqualToString:origin];
    }].count > 0;
}

- (void)noteCallbackURL:(NSURL *)url {
    if (self.callbackURL || ![self isCallbackURL:url]) return;
    self.callbackURL = url;
}

- (BOOL)allowsNavigationTo:(NSURL *)url {
    [self noteCallbackURL:url];
    if (self.capturesCallback && self.callbackURL && [url isEqual:self.callbackURL]) {
        self.state = AuthorizationStateCaptured;
        [self updateStatus];
        return NO;
    }
    if (url.host.length) [self.origins addObject:AuthorizationOrigin(url)];
    return YES;
}

- (void)sessionChanged {
    WKWebView *webView = self.session.webView;
    [self.progressLine setProgress:webView.estimatedProgress loading:webView.loading];
    NSURL *url = webView.URL;
    NSURL *failed = self.session.lastError.userInfo[NSURLErrorFailingURLErrorKey];
    if ([failed isKindOfClass:NSURL.class]) [self noteCallbackURL:failed];
    if (url.host.length) {
        [self noteCallbackURL:url];
        if (!webView.loading && !self.session.lastError && self.state == AuthorizationStateBrowsing && [self isCallbackURL:url])
            self.state = AuthorizationStateCompleted;
        [self.origins addObject:AuthorizationOrigin(url)];
    }
    [self updateStatus];
}

- (void)handedOffURL:(NSURL *)url opened:(BOOL)opened {
    if (opened) {
        NSURL *app = [NSWorkspace.sharedWorkspace URLForApplicationToOpenURL:url];
        NSString *name = app ? [NSFileManager.defaultManager displayNameAtPath:app.path] : url.scheme;
        self.handoffMessage = [NSString stringWithFormat:@"授权结果已交给“%@”，客户端会自动完成登录，可以关闭此窗口。", name];
        self.state = AuthorizationStateHandedOff;
    } else {
        self.handoffMessage = [NSString stringWithFormat:@"没有应用可以处理 %@:// 回调，请确认客户端已安装。", url.scheme];
        self.state = AuthorizationStateFailed;
    }
    [self updateStatus];
}

#pragma mark - Display

- (void)updateStatus {
    WKWebView *webView = self.session.webView;
    NSURL *url = webView.URL ?: self.initialURL;
    NSError *error = self.session.lastError;
    NSString *symbol = @"lock.fill";
    NSColor *tint = NSColor.secondaryLabelColor;
    NSColor *fill = NSColor.controlBackgroundColor;
    NSString *text = url.absoluteString ?: @"";
    NSString *action = @"重新载入";
    NSColor *green = NSColor.systemGreenColor, *orange = NSColor.systemOrangeColor;

    if (self.state == AuthorizationStateCaptured) {
        text = @"已获取回调地址，未在本机打开。复制后粘贴到客户端，或在客户端所在的设备上打开。";
        symbol = @"checkmark.circle.fill";
        tint = green;
        fill = [green colorWithAlphaComponent:0.12];
        action = @"关闭窗口";
    } else if (error && self.state != AuthorizationStateCompleted) {
        NSURL *failed = error.userInfo[NSURLErrorFailingURLErrorKey];
        failed = [failed isKindOfClass:NSURL.class] ? failed : url;
        text = AuthorizationIsLoopbackURL(failed)
            ? (self.callbackURL
                ? [NSString stringWithFormat:@"本机 %@ 没有客户端在等待回调。客户端在其他设备上时，复制回调地址到那里使用；否则请在客户端重新生成授权链接。", HostAndPort(failed)]
                : [NSString stringWithFormat:@"无法连接到客户端的回调地址 %@。请确认客户端仍在等待登录；如已超时，请在客户端重新生成授权链接。", HostAndPort(failed)])
            : [NSString stringWithFormat:@"页面加载失败：%@", error.localizedDescription];
        symbol = @"exclamationmark.triangle.fill";
        tint = orange;
        fill = [orange colorWithAlphaComponent:0.12];
        action = @"重试";
    } else if (self.state == AuthorizationStateFailed) {
        text = self.handoffMessage;
        symbol = @"exclamationmark.triangle.fill";
        tint = orange;
        fill = [orange colorWithAlphaComponent:0.12];
    } else if (self.state == AuthorizationStateCompleted || self.state == AuthorizationStateHandedOff) {
        text = self.state == AuthorizationStateHandedOff ? self.handoffMessage
            : [NSString stringWithFormat:@"授权结果已发送给客户端（%@），可以关闭此窗口。", HostAndPort(url)];
        symbol = @"checkmark.circle.fill";
        tint = green;
        fill = [green colorWithAlphaComponent:0.12];
        action = @"关闭窗口";
    } else if (AuthorizationIsLoopbackURL(url)) {
        symbol = @"desktopcomputer";
    } else if (![url.scheme.lowercaseString isEqualToString:@"https"]) {
        symbol = @"lock.open.fill";
        tint = orange;
    }

    self.statusIcon.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
    self.statusIcon.contentTintColor = tint;
    self.statusLabel.stringValue = text ?: @"";
    self.statusLabel.toolTip = text;
    NSString *callback = self.callbackURL.absoluteString;
    self.callbackLabel.stringValue = callback ? [@"回调地址：" stringByAppendingString:callback] : @"";
    self.callbackLabel.toolTip = callback;
    self.callbackLabel.hidden = callback == nil;
    self.callbackCopyButton.hidden = callback == nil;
    self.banner.fillColor = fill;
    self.actionButton.title = action;
    self.window.subtitle = url.host ?: @"";
}

#pragma mark - Actions

- (void)copyCallbackURL:(id)sender {
    NSString *callback = self.callbackURL.absoluteString;
    if (!callback) return;
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:callback forType:NSPasteboardTypeString];
    self.callbackCopyButton.title = @"已复制";
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        weakSelf.callbackCopyButton.title = CopyTitle;
    });
}

- (void)performAction:(id)sender {
    AuthorizationState state = self.state;
    if (state == AuthorizationStateCompleted || state == AuthorizationStateHandedOff || state == AuthorizationStateCaptured) {
        [self closeAuthorization];
    } else if (self.session.lastError) {
        [self.session retry];
    } else {
        [self.session.webView reload];
    }
}

- (void)closeAuthorization { [self.window close]; }

- (void)windowWillClose:(NSNotification *)notification {
    [self.session invalidate];
    if (self.closed) self.closed(self);
}
@end
