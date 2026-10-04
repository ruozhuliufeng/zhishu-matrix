#import "BrowserSession.h"

NSURL *BrowserHomeURL(void) { return [NSURL URLWithString:@"https://chatgpt.com/"]; }

NSString *const IdentifyAsSafariDefaultsKey = @"identifyAsSafari";
NSNotificationName const BrowserUserAgentPreferenceDidChangeNotification = @"BrowserUserAgentPreferenceDidChangeNotification";

NSString *BrowserPreferredUserAgent(void) {
    id enabled = [NSUserDefaults.standardUserDefaults objectForKey:IdentifyAsSafariDefaultsKey];
    if (enabled && ![enabled boolValue]) return nil;
    static NSString *agent;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:@"/Applications/Safari.app/Contents/Info.plist"];
        NSString *version = [info[@"CFBundleShortVersionString"] isKindOfClass:NSString.class] ? info[@"CFBundleShortVersionString"] : nil;
        // Same shape as Safari's own string; WebKit freezes the OS and engine versions in it.
        agent = [NSString stringWithFormat:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
            "(KHTML, like Gecko) Version/%@ Safari/605.1.15", version.length ? version : @"18.6"];
    });
    return agent;
}

static void *ObserverContext = &ObserverContext;

static NSArray<NSString *> *ObservedKeys(void) {
    return @[@"loading", @"estimatedProgress", @"title", @"URL", @"canGoBack", @"canGoForward"];
}

/// Pop-ups for these hosts stay in-app so sign-in flows keep their window.opener; other links open in the default browser.
static BOOL KeepsPopupInApp(NSURL *url) {
    NSString *host = url.host.lowercaseString;
    if (!host.length || !([url.scheme isEqualToString:@"http"] || [url.scheme isEqualToString:@"https"])) return YES;
    for (NSString *domain in @[@"chatgpt.com", @"openai.com", @"accounts.google.com", @"appleid.apple.com",
                               @"login.microsoftonline.com", @"login.live.com"]) {
        if ([host isEqualToString:domain] || [host hasSuffix:[@"." stringByAppendingString:domain]]) return YES;
    }
    return NO;
}

static NSURL *UniqueDownloadURL(NSString *suggestedName) {
    NSURL *folder = [NSFileManager.defaultManager URLsForDirectory:NSDownloadsDirectory inDomains:NSUserDomainMask].firstObject;
    NSString *name = suggestedName.lastPathComponent.length ? suggestedName.lastPathComponent : @"download";
    NSURL *candidate = [folder URLByAppendingPathComponent:name];
    NSString *base = name.stringByDeletingPathExtension;
    NSString *extension = name.pathExtension;
    for (NSUInteger copy = 2; [NSFileManager.defaultManager fileExistsAtPath:candidate.path]; copy++) {
        NSString *numbered = [NSString stringWithFormat:@"%@ (%lu)", base, (unsigned long)copy];
        if (extension.length) numbered = [numbered stringByAppendingPathExtension:extension];
        candidate = [folder URLByAppendingPathComponent:numbered];
    }
    return candidate;
}

@interface BrowserSession () <WKDownloadDelegate, NSWindowDelegate>
@property (nonatomic, readwrite, nullable) NSError *lastError;
@property (nonatomic, strong) NSMutableArray<NSWindow *> *popupWindows;
@property (nonatomic, strong) NSMapTable<WKDownload *, NSURL *> *downloads;
@end

@implementation BrowserSession {
    BOOL _observing;
}

- (instancetype)initWithAccountID:(NSString *)accountID {
    return [self initWithAccountID:accountID dataStore:nil initialURL:BrowserHomeURL()];
}

- (instancetype)initWithAccountID:(NSString *)accountID dataStore:(WKWebsiteDataStore *)dataStore initialURL:(NSURL *)initialURL {
    if ((self = [super init])) {
        _accountID = [accountID copy];
        WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
        configuration.websiteDataStore = dataStore ?: [WKWebsiteDataStore dataStoreForIdentifier:[[NSUUID alloc] initWithUUIDString:accountID]];
        _webView = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:configuration];
        _webView.navigationDelegate = self;
        _webView.UIDelegate = self;
        _webView.allowsBackForwardNavigationGestures = YES;
        _webView.allowsMagnification = YES;
        _webView.customUserAgent = BrowserPreferredUserAgent();
        _popupWindows = [NSMutableArray array];
        _downloads = [NSMapTable strongToStrongObjectsMapTable];
        for (NSString *key in ObservedKeys()) [_webView addObserver:self forKeyPath:key options:0 context:ObserverContext];
        _observing = YES;
        [_webView loadRequest:[NSURLRequest requestWithURL:initialURL]];
    }
    return self;
}

- (void)dealloc { [self stopObserving]; }

- (void)stopObserving {
    if (!_observing) return;
    for (NSString *key in ObservedKeys()) [_webView removeObserver:self forKeyPath:key context:ObserverContext];
    _observing = NO;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != ObserverContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    [self notifyStateChanged];
}

- (void)notifyStateChanged { if (self.stateChanged) self.stateChanged(self); }

- (void)goHome { [self.webView loadRequest:[NSURLRequest requestWithURL:BrowserHomeURL()]]; }

- (void)applyPreferredUserAgent {
    NSString *agent = BrowserPreferredUserAgent();
    NSString *current = self.webView.customUserAgent.length ? self.webView.customUserAgent : nil;
    if (agent == current || [agent isEqualToString:current]) return;
    self.webView.customUserAgent = agent;
    for (NSWindow *window in self.popupWindows) {
        if ([window.contentView isKindOfClass:WKWebView.class]) ((WKWebView *)window.contentView).customUserAgent = agent;
    }
    if (self.webView.URL) [self.webView reload];
}

- (void)retry {
    NSURL *failed = self.lastError.userInfo[NSURLErrorFailingURLErrorKey];
    NSURL *target = [failed isKindOfClass:NSURL.class] ? failed : (self.webView.URL ?: BrowserHomeURL());
    self.lastError = nil;
    [self.webView loadRequest:[NSURLRequest requestWithURL:target]];
}

- (void)invalidate {
    for (NSWindow *window in self.popupWindows.copy) {
        window.delegate = nil;
        [window close];
    }
    [self.popupWindows removeAllObjects];
    [self stopObserving];
    [self.webView stopLoading];
    self.webView.navigationDelegate = nil;
    self.webView.UIDelegate = nil;
    [self.webView removeFromSuperview];
    self.stateChanged = nil;
    self.pageReady = nil;
    self.externalURLOpened = nil;
    self.allowsNavigation = nil;
}

- (void)openExternally:(NSURL *)url {
    // With no app for the scheme macOS would put up its own "no application set" dialog; the caller reports it instead.
    NSWorkspace *workspace = NSWorkspace.sharedWorkspace;
    BOOL opened = [workspace URLForApplicationToOpenURL:url] != nil && [workspace openURL:url];
    if (self.externalURLOpened) self.externalURLOpened(self, url, opened);
}

#pragma mark - Navigation

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = navigationAction.request.URL;
    NSString *scheme = url.scheme.lowercaseString;
    if (navigationAction.targetFrame.isMainFrame && scheme.length &&
        ![@[@"http", @"https", @"about", @"blob", @"data"] containsObject:scheme]) {
        [self openExternally:url];
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    BOOL mainFrame = !navigationAction.targetFrame || navigationAction.targetFrame.isMainFrame;
    if (webView == self.webView && mainFrame && self.allowsNavigation &&
        ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) && !self.allowsNavigation(self, url)) {
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    decisionHandler(navigationAction.shouldPerformDownload ? WKNavigationActionPolicyDownload : WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse
    decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
    NSHTTPURLResponse *response = [navigationResponse.response isKindOfClass:NSHTTPURLResponse.class]
        ? (NSHTTPURLResponse *)navigationResponse.response : nil;
    NSString *disposition = [response valueForHTTPHeaderField:@"Content-Disposition"].lowercaseString;
    BOOL attachment = [disposition hasPrefix:@"attachment"];
    decisionHandler(attachment || !navigationResponse.canShowMIMEType
        ? WKNavigationResponsePolicyDownload : WKNavigationResponsePolicyAllow);
}

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
    if (webView != self.webView) return;
    self.lastError = nil;
    [self notifyStateChanged];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    if (webView != self.webView) return;
    [self notifyStateChanged];
    if (self.pageReady) self.pageReady(self);
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self navigationFailed:error inWebView:webView];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self navigationFailed:error inWebView:webView];
}

- (void)navigationFailed:(NSError *)error inWebView:(WKWebView *)webView {
    if (webView != self.webView) return;
    // A redirect to a client's custom scheme can fail as "unsupported URL" instead of asking for a policy.
    NSURL *failed = error.userInfo[NSURLErrorFailingURLErrorKey];
    NSString *failedScheme = [failed isKindOfClass:NSURL.class] ? failed.scheme.lowercaseString : nil;
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorUnsupportedURL && failedScheme.length &&
        ![@[@"http", @"https", @"about", @"blob", @"data"] containsObject:failedScheme]) {
        [self openExternally:failed];
        [self notifyStateChanged];
        return;
    }
    BOOL cancelled = [error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled;
    // WebKitErrorFrameLoadInterruptedByPolicyChange: the navigation turned into a download.
    BOOL interrupted = [error.domain isEqualToString:@"WebKitErrorDomain"] && error.code == 102;
    if (!cancelled && !interrupted) self.lastError = error;
    [self notifyStateChanged];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    if (webView == self.webView) [webView reload];
}

#pragma mark - Downloads

- (void)webView:(WKWebView *)webView navigationAction:(WKNavigationAction *)navigationAction didBecomeDownload:(WKDownload *)download {
    download.delegate = self;
}

- (void)webView:(WKWebView *)webView navigationResponse:(WKNavigationResponse *)navigationResponse didBecomeDownload:(WKDownload *)download {
    download.delegate = self;
}

- (void)download:(WKDownload *)download decideDestinationUsingResponse:(NSURLResponse *)response
    suggestedFilename:(NSString *)suggestedFilename completionHandler:(void (^)(NSURL *))completionHandler {
    NSURL *destination = UniqueDownloadURL(suggestedFilename);
    [self.downloads setObject:destination forKey:download];
    completionHandler(destination);
}

- (void)downloadDidFinish:(WKDownload *)download {
    NSURL *file = [self.downloads objectForKey:download];
    [self.downloads removeObjectForKey:download];
    if (file) [NSDistributedNotificationCenter.defaultCenter postNotificationName:@"com.apple.DownloadFileFinished" object:file.path];
    if (self.downloadEnded) self.downloadEnded(self, file, nil);
}

- (void)download:(WKDownload *)download didFailWithError:(NSError *)error resumeData:(NSData *)resumeData {
    NSURL *file = [self.downloads objectForKey:download];
    [self.downloads removeObjectForKey:download];
    if (self.downloadEnded) self.downloadEnded(self, file, error);
}

#pragma mark - UI

- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
   forNavigationAction:(WKNavigationAction *)navigationAction windowFeatures:(WKWindowFeatures *)windowFeatures {
    NSURL *url = navigationAction.request.URL;
    if (!KeepsPopupInApp(url)) {
        [NSWorkspace.sharedWorkspace openURL:url];
        return nil;
    }
    WKWebView *popup = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 780, 680) configuration:configuration];
    popup.customUserAgent = self.webView.customUserAgent;
    popup.navigationDelegate = self;
    popup.UIDelegate = self;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:popup.frame
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;
    window.title = url.host.length ? url.host : @"ChatGPT";
    window.contentView = popup;
    window.delegate = self;
    [window center];
    [window makeKeyAndOrderFront:nil];
    [self.popupWindows addObject:window];
    return popup;
}

- (void)webViewDidClose:(WKWebView *)webView {
    for (NSWindow *window in self.popupWindows.copy)
        if (window.contentView == webView) [window close];
}

- (void)windowWillClose:(NSNotification *)notification {
    [self.popupWindows removeObject:notification.object];
}

- (void)presentAlert:(NSAlert *)alert forWebView:(WKWebView *)webView completion:(void (^)(NSModalResponse response))completion {
    NSWindow *window = webView.window;
    if (window) [alert beginSheetModalForWindow:window completionHandler:completion];
    else completion([alert runModal]);
}

- (void)webView:(WKWebView *)webView runJavaScriptAlertPanelWithMessage:(NSString *)message
    initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(void))completionHandler {
    NSAlert *alert = [NSAlert new];
    alert.messageText = frame.request.URL.host ?: @"网页消息";
    alert.informativeText = message;
    [alert addButtonWithTitle:@"好"];
    [self presentAlert:alert forWebView:webView completion:^(NSModalResponse response) { completionHandler(); }];
}

- (void)webView:(WKWebView *)webView runJavaScriptConfirmPanelWithMessage:(NSString *)message
    initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(BOOL))completionHandler {
    NSAlert *alert = [NSAlert new];
    alert.messageText = frame.request.URL.host ?: @"网页消息";
    alert.informativeText = message;
    [alert addButtonWithTitle:@"好"];
    [alert addButtonWithTitle:@"取消"];
    [self presentAlert:alert forWebView:webView completion:^(NSModalResponse response) {
        completionHandler(response == NSAlertFirstButtonReturn);
    }];
}

- (void)webView:(WKWebView *)webView runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt
    defaultText:(NSString *)defaultText initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(NSString *))completionHandler {
    NSAlert *alert = [NSAlert new];
    alert.messageText = frame.request.URL.host ?: @"网页消息";
    alert.informativeText = prompt;
    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)];
    input.stringValue = defaultText ?: @"";
    alert.accessoryView = input;
    [alert addButtonWithTitle:@"好"];
    [alert addButtonWithTitle:@"取消"];
    [self presentAlert:alert forWebView:webView completion:^(NSModalResponse response) {
        completionHandler(response == NSAlertFirstButtonReturn ? input.stringValue : nil);
    }];
}

- (void)webView:(WKWebView *)webView runOpenPanelWithParameters:(WKOpenPanelParameters *)parameters
    initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(NSArray<NSURL *> *))completionHandler {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = parameters.allowsDirectories;
    panel.allowsMultipleSelection = parameters.allowsMultipleSelection;
    void (^finish)(NSModalResponse) = ^(NSModalResponse response) {
        completionHandler(response == NSModalResponseOK ? panel.URLs : nil);
    };
    if (webView.window) [panel beginSheetModalForWindow:webView.window completionHandler:finish];
    else finish([panel runModal]);
}
@end
