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
@property (nonatomic, readwrite, nullable) NSDictionary<NSString *, NSString *> *request;
@property (nonatomic, copy, nullable) NSString *handoffAppName;
@property (nonatomic) BOOL reported;
@property (nonatomic, strong) DeskFillView *banner;
@property (nonatomic, strong) NSImageView *statusIcon;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSButton *actionButton;
/// Covers the stalled page once there is a callback address to hand over.
@property (nonatomic, strong) DeskFillView *resultView;
@property (nonatomic, strong) NSImageView *resultIcon;
@property (nonatomic, strong) NSTextField *resultTitle;
@property (nonatomic, strong) NSTextField *resultMessage;
@property (nonatomic, strong) NSTextField *addressLabel;
@property (nonatomic, strong) NSButton *callbackCopyButton;
@property (nonatomic, strong) NSButton *resultSecondaryButton;
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
        _request = AuthorizationRequestFromURL(url);
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
    [self.statusLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
        forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.actionButton = DeskButton(@"重新载入", nil, self, @selector(performAction:));
    self.actionButton.controlSize = NSControlSizeSmall;
    [self.actionButton setContentCompressionResistancePriority:NSLayoutPriorityRequired
        forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSBox *separator = DeskSeparator();
    self.progressLine = [DeskProgressLine new];
    self.resultView = [self buildResultView];
    self.resultView.hidden = YES;
    WKWebView *webView = self.session.webView;

    for (NSView *view in @[self.banner, separator, webView, self.resultView, self.progressLine]) {
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
        [self.resultView.topAnchor constraintEqualToAnchor:separator.bottomAnchor],
        [self.resultView.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [self.resultView.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [self.resultView.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [self.progressLine.topAnchor constraintEqualToAnchor:separator.bottomAnchor],
        [self.progressLine.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [self.progressLine.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [self.progressLine.heightAnchor constraintEqualToConstant:2]
    ]];
}

/// A centred card: icon, title, explanation, the full callback address in a wrapping box, and the actions.
- (DeskFillView *)buildResultView {
    DeskFillView *view = [DeskFillView new];
    view.fillColor = NSColor.windowBackgroundColor;
    self.resultIcon = [NSImageView new];
    self.resultIcon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:40 weight:NSFontWeightRegular];
    self.resultTitle = DeskLabel(@"", 19, NSFontWeightSemibold);
    self.resultTitle.alignment = NSTextAlignmentCenter;
    self.resultMessage = [NSTextField wrappingLabelWithString:@""];
    self.resultMessage.font = [NSFont systemFontOfSize:13];
    self.resultMessage.textColor = NSColor.secondaryLabelColor;
    self.resultMessage.alignment = NSTextAlignmentCenter;

    NSTextField *caption = DeskCaption(@"回调地址");
    self.addressLabel = [NSTextField wrappingLabelWithString:@""];
    self.addressLabel.selectable = YES;
    self.addressLabel.lineBreakMode = NSLineBreakByCharWrapping;
    self.addressLabel.translatesAutoresizingMaskIntoConstraints = NO;
    NSStackView *addressStack = [NSStackView stackViewWithViews:@[caption, self.addressLabel]];
    addressStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    addressStack.alignment = NSLayoutAttributeLeading;
    addressStack.spacing = 6;
    addressStack.translatesAutoresizingMaskIntoConstraints = NO;
    NSBox *addressBox = [NSBox new];
    addressBox.boxType = NSBoxCustom;
    addressBox.borderWidth = 0;
    addressBox.cornerRadius = 10;
    addressBox.fillColor = NSColor.quaternarySystemFillColor;
    addressBox.contentViewMargins = NSMakeSize(14, 12);
    addressBox.translatesAutoresizingMaskIntoConstraints = NO;
    [addressBox.contentView addSubview:addressStack];
    NSView *boxContent = addressBox.contentView;
    [NSLayoutConstraint activateConstraints:@[
        [addressStack.topAnchor constraintEqualToAnchor:boxContent.topAnchor],
        [addressStack.bottomAnchor constraintEqualToAnchor:boxContent.bottomAnchor],
        [addressStack.leadingAnchor constraintEqualToAnchor:boxContent.leadingAnchor],
        [addressStack.trailingAnchor constraintEqualToAnchor:boxContent.trailingAnchor],
        [self.addressLabel.widthAnchor constraintEqualToAnchor:addressStack.widthAnchor]
    ]];

    NSImageView *lock = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"lock.shield" accessibilityDescription:nil]];
    lock.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:11 weight:NSFontWeightRegular];
    lock.contentTintColor = NSColor.tertiaryLabelColor;
    NSTextField *note = DeskLabel(@"地址中包含一次性授权码，只粘贴到发起登录的应用，不要分享给他人。", 11, NSFontWeightRegular);
    note.textColor = NSColor.tertiaryLabelColor;
    NSStackView *noteRow = [NSStackView stackViewWithViews:@[lock, note]];
    noteRow.spacing = 4;

    self.callbackCopyButton = DeskButton(CopyTitle, @"doc.on.doc", self, @selector(copyCallbackURL:));
    self.callbackCopyButton.controlSize = NSControlSizeLarge;
    self.callbackCopyButton.bezelColor = NSColor.controlAccentColor;
    self.callbackCopyButton.toolTip = @"复制完整的回调地址，粘贴到第三方应用或在其所在设备上打开";
    self.resultSecondaryButton = DeskButton(@"关闭窗口", nil, self, @selector(performAction:));
    self.resultSecondaryButton.controlSize = NSControlSizeLarge;
    NSStackView *buttons = [NSStackView stackViewWithViews:@[self.resultSecondaryButton, self.callbackCopyButton]];
    buttons.spacing = 10;

    NSStackView *card = [NSStackView stackViewWithViews:@[self.resultIcon, self.resultTitle, self.resultMessage, addressBox, noteRow, buttons]];
    card.orientation = NSUserInterfaceLayoutOrientationVertical;
    card.alignment = NSLayoutAttributeCenterX;
    card.spacing = 10;
    [card setCustomSpacing:6 afterView:self.resultIcon];
    [card setCustomSpacing:20 afterView:self.resultMessage];
    [card setCustomSpacing:8 afterView:addressBox];
    [card setCustomSpacing:24 afterView:noteRow];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [view addSubview:card];
    NSLayoutConstraint *preferred = [card.widthAnchor constraintEqualToConstant:540];
    preferred.priority = NSLayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:view.centerYAnchor constant:-30],
        [card.widthAnchor constraintLessThanOrEqualToAnchor:view.widthAnchor constant:-64],
        preferred,
        [addressBox.widthAnchor constraintEqualToAnchor:card.widthAnchor],
        [self.resultMessage.widthAnchor constraintEqualToAnchor:card.widthAnchor]
    ]];
    return view;
}

/// The address with its path in the label color and the query (code, state) dimmed, so it reads at a glance.
- (NSAttributedString *)formattedAddress:(NSURL *)url {
    NSString *text = url.absoluteString ?: @"";
    NSRange query = [text rangeOfString:@"?"];
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.lineBreakMode = NSLineBreakByCharWrapping;
    paragraph.lineSpacing = 2;
    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: NSColor.secondaryLabelColor, NSParagraphStyleAttributeName: paragraph}];
    NSRange base = NSMakeRange(0, query.location == NSNotFound ? text.length : query.location);
    [result addAttributes:@{NSFontAttributeName: [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: NSColor.labelColor} range:base];
    return result;
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

- (void)setState:(AuthorizationState)state {
    _state = state;
    if (state == AuthorizationStateCompleted || state == AuthorizationStateHandedOff || state == AuthorizationStateCaptured)
        [self reportAuthorized];
}

/// The app's own web page as the redirect address (not this Mac): the flow ends there.
- (BOOL)isWebCallbackURL:(NSURL *)url {
    NSString *redirect = self.request[@"redirect"];
    NSURL *target = redirect.length ? [NSURL URLWithString:redirect] : nil;
    NSString *scheme = target.scheme.lowercaseString;
    if (!([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) || AuthorizationIsLoopbackURL(target)) return NO;
    return AuthorizationURLMatchesRedirect(url, redirect);
}

- (void)reportAuthorized {
    if (self.reported || !self.authorized) return;
    NSURL *callback = self.callbackURL ?: self.session.webView.URL;
    // A callback carrying error=access_denied means the user declined.
    if (self.state != AuthorizationStateHandedOff && !AuthorizationCallbackSucceeded(callback)) return;
    self.reported = YES;
    NSMutableDictionary *details = [NSMutableDictionary dictionaryWithDictionary:self.request ?: @{}];
    NSString *redirect = details[@"redirect"];
    if (!redirect.length && callback) {
        NSURLComponents *components = [NSURLComponents componentsWithURL:callback resolvingAgainstBaseURL:NO];
        components.query = nil;
        components.fragment = nil;
        redirect = components.string;
        if (redirect.length) details[@"redirect"] = redirect;
    }
    details[@"appName"] = self.handoffAppName ?: AuthorizationAppName(redirect);
    self.authorized(self, details);
}

- (BOOL)allowsNavigationTo:(NSURL *)url {
    if (!self.request[@"redirect"]) {
        NSDictionary *request = AuthorizationRequestFromURL(url);
        if (request[@"redirect"]) self.request = request;
    }
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
        if (!webView.loading && !self.session.lastError && self.state == AuthorizationStateBrowsing &&
            ([self isCallbackURL:url] || ([self isWebCallbackURL:url] && AuthorizationCallbackSucceeded(url))))
            self.state = AuthorizationStateCompleted;
        [self.origins addObject:AuthorizationOrigin(url)];
    }
    [self updateStatus];
}

- (void)handedOffURL:(NSURL *)url opened:(BOOL)opened {
    if (opened) {
        NSURL *app = [NSWorkspace.sharedWorkspace URLForApplicationToOpenURL:url];
        NSString *name = app ? [NSFileManager.defaultManager displayNameAtPath:app.path] : url.scheme;
        self.handoffMessage = [NSString stringWithFormat:@"授权结果已交给“%@”，对方会自动完成登录，可以关闭此窗口。", name];
        self.handoffAppName = app ? name : nil;
        if (!self.request[@"redirect"]) {
            NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
            components.query = nil;
            components.fragment = nil;
            NSMutableDictionary *request = [self.request mutableCopy] ?: [NSMutableDictionary dictionary];
            if (components.string) request[@"redirect"] = components.string;
            self.request = request;
        }
        self.state = AuthorizationStateHandedOff;
    } else {
        self.handoffMessage = [NSString stringWithFormat:@"没有应用可以处理 %@:// 回调，请确认对应的应用已安装。", url.scheme];
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

    // Set when the page has stopped at a callback address the user still has to carry over.
    NSString *resultTitle = nil, *resultMessage = nil;
    if (self.state == AuthorizationStateCaptured) {
        text = @"已获取回调地址，未在本机打开";
        symbol = @"checkmark.circle.fill";
        tint = green;
        fill = [green colorWithAlphaComponent:0.12];
        action = @"关闭窗口";
        resultTitle = @"已获取回调地址";
        resultMessage = @"按你的选择，回调地址没有在本机打开。复制后粘贴到第三方应用，或在它所在的设备上打开，即可完成登录。";
    } else if (error && self.state != AuthorizationStateCompleted) {
        NSURL *failed = error.userInfo[NSURLErrorFailingURLErrorKey];
        failed = [failed isKindOfClass:NSURL.class] ? failed : url;
        text = AuthorizationIsLoopbackURL(failed)
            ? (self.callbackURL
                ? [NSString stringWithFormat:@"本机 %@ 没有应用在等待回调", HostAndPort(failed)]
                : [NSString stringWithFormat:@"无法连接到回调地址 %@。请确认第三方应用仍在等待登录；如已超时，请让对方重新生成授权链接。", HostAndPort(failed)])
            : [NSString stringWithFormat:@"页面加载失败：%@", error.localizedDescription];
        if (AuthorizationIsLoopbackURL(failed) && self.callbackURL) {
            resultTitle = @"回调没有送达";
            resultMessage = [NSString stringWithFormat:@"本机的 %@ 没有应用在等待登录结果。第三方应用在其他设备上时，复制回调地址到那里打开；"
                "如果它就在这台 Mac 上，请确认它仍在等待登录，或让它重新生成授权链接。", HostAndPort(failed)];
        }
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
            : [NSString stringWithFormat:@"授权结果已发送给第三方应用（%@），可以关闭此窗口。", HostAndPort(url)];
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
    self.banner.fillColor = fill;
    self.actionButton.title = action;
    BOOL showsResult = resultTitle && self.callbackURL;
    self.resultView.hidden = !showsResult;
    // The card carries the actions; the banner just states where things are.
    self.actionButton.hidden = showsResult;
    // Return copies only while the card is up; on the sign-in page it belongs to the page's forms.
    self.callbackCopyButton.keyEquivalent = showsResult ? @"\r" : @"";
    if (showsResult) {
        BOOL captured = self.state == AuthorizationStateCaptured;
        self.resultIcon.image = [NSImage imageWithSystemSymbolName:captured ? @"checkmark.circle.fill" : @"arrow.up.forward.app"
            accessibilityDescription:nil];
        self.resultIcon.contentTintColor = captured ? green : orange;
        self.resultTitle.stringValue = resultTitle;
        self.resultMessage.stringValue = resultMessage;
        self.addressLabel.attributedStringValue = [self formattedAddress:self.callbackURL];
        self.addressLabel.toolTip = self.callbackURL.absoluteString;
        self.resultSecondaryButton.title = captured ? @"关闭窗口" : @"重试";
    }
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
