#import "BrowserPaneController.h"
#import "BrowserSession.h"
#import "DeskUI.h"
#import "NetworkDiagnosis.h"
#import "NetworkDiagnosisWindowController.h"

@interface BrowserPaneController ()
@property (nonatomic, weak) id<AccountCoordinator> coordinator;
@property (nonatomic, strong, readwrite, nullable) BrowserSession *session;
@property (nonatomic, strong) DeskProgressLine *progressLine;
@property (nonatomic, strong) NSView *emptyView;
@property (nonatomic, strong) DeskFillView *errorView;
@property (nonatomic, strong) NSTextField *errorDetail;
@property (nonatomic, strong) NSTextField *errorHint;
@property (nonatomic, copy) NSArray<NSLayoutConstraint *> *webConstraints;
@end

@implementation BrowserPaneController

- (instancetype)initWithCoordinator:(id<AccountCoordinator>)coordinator {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _coordinator = coordinator;
        _webConstraints = @[];
    }
    return self;
}

- (NSImageView *)symbol:(NSString *)name size:(CGFloat)size {
    NSImageView *image = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:name accessibilityDescription:nil]];
    image.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:size weight:NSFontWeightLight];
    image.contentTintColor = NSColor.tertiaryLabelColor;
    return image;
}

- (NSTextField *)hint:(NSString *)text {
    NSTextField *hint = [NSTextField wrappingLabelWithString:text];
    hint.alignment = NSTextAlignmentCenter;
    hint.textColor = NSColor.secondaryLabelColor;
    hint.font = [NSFont systemFontOfSize:13];
    hint.preferredMaxLayoutWidth = 360;
    return hint;
}

- (NSView *)buildEmptyView {
    NSButton *add = DeskButton(@"添加账号", @"plus", self.coordinator, @selector(addAccount:));
    add.controlSize = NSControlSizeLarge;
    add.bezelColor = NSColor.controlAccentColor;
    NSButton *import = DeskButton(@"导入账号资料…", @"square.and.arrow.down", self.coordinator, @selector(importAccounts:));
    import.controlSize = NSControlSizeLarge;
    NSStackView *buttons = [NSStackView stackViewWithViews:@[import, add]];
    buttons.spacing = 10;
    NSStackView *stack = [NSStackView stackViewWithViews:@[
        [self symbol:@"person.2.crop.square.stack" size:52],
        DeskLabel(@"还没有账号", 22, NSFontWeightSemibold),
        [self hint:@"每个账号使用独立的本地会话，互不影响。添加账号后在 ChatGPT 页面登录即可，密码由 ChatGPT 页面处理，应用不会保存。"],
        buttons
    ]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.spacing = 14;
    [stack setCustomSpacing:22 afterView:stack.arrangedSubviews[2]];
    return stack;
}

- (DeskFillView *)buildErrorView {
    DeskFillView *overlay = [DeskFillView new];
    self.errorDetail = [self hint:@""];
    self.errorDetail.textColor = NSColor.labelColor;
    self.errorDetail.selectable = YES;
    self.errorHint = [self hint:@""];
    self.errorHint.font = [NSFont systemFontOfSize:12];
    self.errorHint.preferredMaxLayoutWidth = 460;
    NSButton *retry = DeskButton(@"重新加载", @"arrow.clockwise", self, @selector(retry:));
    NSButton *diagnose = DeskButton(@"网络诊断", @"stethoscope", self, @selector(diagnose:));
    NSStackView *buttons = [NSStackView stackViewWithViews:@[diagnose, retry]];
    buttons.spacing = 10;
    NSStackView *stack = [NSStackView stackViewWithViews:@[
        [self symbol:@"wifi.exclamationmark" size:44],
        DeskLabel(@"页面加载失败", 18, NSFontWeightSemibold),
        self.errorDetail,
        self.errorHint,
        buttons
    ]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.spacing = 12;
    [stack setCustomSpacing:6 afterView:self.errorDetail];
    [stack setCustomSpacing:18 afterView:self.errorHint];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [overlay addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor constant:-20]
    ]];
    return overlay;
}

- (void)loadView {
    NSView *root = [NSView new];
    self.view = root;
    self.progressLine = [DeskProgressLine new];
    self.emptyView = [self buildEmptyView];
    self.errorView = [self buildErrorView];
    self.errorView.hidden = YES;
    for (NSView *view in @[self.emptyView, self.errorView, self.progressLine]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [root addSubview:view];
    }
    NSLayoutGuide *safe = root.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.progressLine.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.progressLine.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [self.progressLine.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [self.progressLine.heightAnchor constraintEqualToConstant:2],
        [self.emptyView.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [self.emptyView.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor constant:-20],
        [self.emptyView.widthAnchor constraintLessThanOrEqualToAnchor:root.widthAnchor constant:-48],
        [self.errorView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.errorView.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [self.errorView.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [self.errorView.bottomAnchor constraintEqualToAnchor:root.bottomAnchor]
    ]];
}

- (void)showSession:(BrowserSession *)session {
    (void)self.view;
    if (self.session != session) {
        [NSLayoutConstraint deactivateConstraints:self.webConstraints];
        self.webConstraints = @[];
        if (self.session.webView.superview == self.view) [self.session.webView removeFromSuperview];
        self.session = session;
        if (session) {
            WKWebView *webView = session.webView;
            webView.translatesAutoresizingMaskIntoConstraints = NO;
            [self.view addSubview:webView positioned:NSWindowBelow relativeTo:self.errorView];
            self.webConstraints = @[
                [webView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
                [webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
                [webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
                [webView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
            ];
            [NSLayoutConstraint activateConstraints:self.webConstraints];
        }
    }
    self.emptyView.hidden = session != nil;
    [self updateState];
}

- (void)updateState {
    if (!self.isViewLoaded) return;
    WKWebView *webView = self.session.webView;
    BOOL loading = webView.loading;
    [self.progressLine setProgress:webView.estimatedProgress loading:loading];
    NSError *error = self.session.lastError;
    self.errorView.hidden = !error || loading;
    if (!error) return;
    NetworkFailure failure = NetworkFailureForError(error);
    NSString *host = NetworkFailingHost(error);
    NSString *reason = failure == NetworkFailureOther ? error.localizedDescription : NetworkFailureDescription(failure);
    self.errorDetail.stringValue = host ? [NSString stringWithFormat:@"无法打开 %@：%@", host, reason ?: @"连接失败"]
                                        : (reason ?: @"请检查网络连接后重试。");
    self.errorHint.stringValue = NetworkFailureHint(failure) ?: @"";
    self.errorHint.hidden = !self.errorHint.stringValue.length;
    self.errorHint.toolTip = failure == NetworkFailureOther ? nil : error.localizedDescription;
}

- (void)diagnose:(id)sender {
    [NetworkDiagnosisWindowController showForAccount:[self.coordinator.store accountWithID:self.session.accountID]];
}

- (void)retry:(id)sender {
    [self.session retry];
    [self updateState];
}
@end
