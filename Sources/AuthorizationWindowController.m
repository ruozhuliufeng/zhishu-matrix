#import "AuthorizationWindowController.h"
#import "Account.h"
#import "AuthorizationLink.h"
#import "BrowserSession.h"
#import "DeskUI.h"

static NSString *HostAndPort(NSURL *url) {
    return url.port ? [NSString stringWithFormat:@"%@:%@", url.host, url.port] : (url.host ?: @"");
}

@interface AuthorizationWindowController () <NSWindowDelegate>
@property (nonatomic, readwrite) AuthorizationState state;
@property (nonatomic, strong) BrowserSession *session;
@property (nonatomic, strong) NSURL *initialURL;
@property (nonatomic, strong) NSMutableSet<NSString *> *origins;
@property (nonatomic, copy, nullable) NSString *handoffMessage;
@property (nonatomic, strong) DeskFillView *banner;
@property (nonatomic, strong) NSImageView *statusIcon;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSButton *actionButton;
@property (nonatomic, strong) DeskProgressLine *progressLine;
@end

@implementation AuthorizationWindowController

- (instancetype)initWithAccount:(Account *)account URL:(NSURL *)url dataStore:(WKWebsiteDataStore *)dataStore {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 880, 720)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    if ((self = [super initWithWindow:window])) {
        _accountID = [account.identifier copy];
        _initialURL = url;
        _origins = [NSMutableSet setWithObject:AuthorizationOrigin(url)];
        window.title = [NSString stringWithFormat:@"授权登录 · %@", account.name];
        window.minSize = NSMakeSize(520, 460);
        window.releasedWhenClosed = NO;
        window.restorable = NO;
        window.delegate = self;

        _session = [[BrowserSession alloc] initWithAccountID:account.identifier dataStore:dataStore initialURL:url];
        __weak typeof(self) weakSelf = self;
        _session.stateChanged = ^(BrowserSession *session) { [weakSelf sessionChanged]; };
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
    self.banner.fillColor = NSColor.controlBackgroundColor;
    self.statusIcon = [NSImageView new];
    self.statusIcon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightMedium];
    self.statusLabel = DeskLabel(@"", 12, NSFontWeightRegular);
    self.statusLabel.selectable = YES;
    self.statusLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.statusLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.actionButton = DeskButton(@"重新载入", nil, self, @selector(performAction:));
    self.actionButton.controlSize = NSControlSizeSmall;
    NSBox *separator = DeskSeparator();
    self.progressLine = [DeskProgressLine new];
    WKWebView *webView = self.session.webView;

    for (NSView *view in @[self.banner, separator, webView, self.progressLine]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [root addSubview:view];
    }
    for (NSView *view in @[self.statusIcon, self.statusLabel, self.actionButton]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [self.banner addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [self.banner.topAnchor constraintEqualToAnchor:root.topAnchor],
        [self.banner.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [self.banner.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [self.banner.heightAnchor constraintEqualToConstant:38],
        [self.statusIcon.leadingAnchor constraintEqualToAnchor:self.banner.leadingAnchor constant:14],
        [self.statusIcon.centerYAnchor constraintEqualToAnchor:self.banner.centerYAnchor],
        [self.statusIcon.widthAnchor constraintEqualToConstant:18],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.statusIcon.trailingAnchor constant:8],
        [self.statusLabel.centerYAnchor constraintEqualToAnchor:self.banner.centerYAnchor],
        [self.statusLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.actionButton.leadingAnchor constant:-12],
        [self.actionButton.trailingAnchor constraintEqualToAnchor:self.banner.trailingAnchor constant:-12],
        [self.actionButton.centerYAnchor constraintEqualToAnchor:self.banner.centerYAnchor],
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
}

#pragma mark - State

- (void)sessionChanged {
    WKWebView *webView = self.session.webView;
    [self.progressLine setProgress:webView.estimatedProgress loading:webView.loading];
    NSURL *url = webView.URL;
    if (url.host.length) {
        // A loopback page reached after visiting another origin is the client's callback.
        if (!webView.loading && !self.session.lastError && AuthorizationIsLoopbackURL(url) &&
            [self.origins objectsPassingTest:^BOOL(NSString *origin, BOOL *stop) {
                return ![origin isEqualToString:AuthorizationOrigin(url)];
            }].count) {
            self.state = AuthorizationStateCompleted;
        }
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

- (void)updateStatus {
    WKWebView *webView = self.session.webView;
    NSURL *url = webView.URL ?: self.initialURL;
    NSError *error = self.session.lastError;
    NSString *symbol = @"lock.fill";
    NSColor *tint = NSColor.secondaryLabelColor;
    NSColor *fill = NSColor.controlBackgroundColor;
    NSString *text = url.absoluteString ?: @"";
    NSString *action = @"重新载入";

    if (error && self.state != AuthorizationStateCompleted) {
        NSURL *failed = error.userInfo[NSURLErrorFailingURLErrorKey];
        failed = [failed isKindOfClass:NSURL.class] ? failed : url;
        text = AuthorizationIsLoopbackURL(failed)
            ? [NSString stringWithFormat:@"无法连接到客户端的回调地址 %@。请确认客户端仍在等待登录；如已超时，请在客户端重新生成授权链接。", HostAndPort(failed)]
            : [NSString stringWithFormat:@"页面加载失败：%@", error.localizedDescription];
        symbol = @"exclamationmark.triangle.fill";
        tint = NSColor.systemOrangeColor;
        fill = [NSColor.systemOrangeColor colorWithAlphaComponent:0.12];
        action = @"重试";
    } else if (self.state == AuthorizationStateFailed) {
        text = self.handoffMessage;
        symbol = @"exclamationmark.triangle.fill";
        tint = NSColor.systemOrangeColor;
        fill = [NSColor.systemOrangeColor colorWithAlphaComponent:0.12];
    } else if (self.state == AuthorizationStateCompleted || self.state == AuthorizationStateHandedOff) {
        text = self.state == AuthorizationStateHandedOff ? self.handoffMessage
            : [NSString stringWithFormat:@"授权结果已发送给客户端（%@），可以关闭此窗口。", HostAndPort(url)];
        symbol = @"checkmark.circle.fill";
        tint = NSColor.systemGreenColor;
        fill = [NSColor.systemGreenColor colorWithAlphaComponent:0.12];
        action = @"关闭窗口";
    } else if (AuthorizationIsLoopbackURL(url)) {
        symbol = @"desktopcomputer";
    } else if (![url.scheme.lowercaseString isEqualToString:@"https"]) {
        symbol = @"lock.open.fill";
        tint = NSColor.systemOrangeColor;
    }

    self.statusIcon.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
    self.statusIcon.contentTintColor = tint;
    self.statusLabel.stringValue = text ?: @"";
    self.statusLabel.toolTip = url.absoluteString;
    self.banner.fillColor = fill;
    self.actionButton.title = action;
    self.window.subtitle = url.host ?: @"";
}

- (void)performAction:(id)sender {
    if (self.state == AuthorizationStateCompleted || self.state == AuthorizationStateHandedOff) {
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
