#import "NetworkProxy.h"
#import <Network/Network.h>
#import "Account.h"
#import "AccountInsights.h"
#import "BrowserSession.h"
#import "NetworkDiagnosis.h"

NSString *const DefaultProxyDefaultsKey = @"defaultProxy";
NSNotificationName const ProxySettingsDidChangeNotification = @"ProxySettingsDidChangeNotification";

NSString *EffectiveProxyText(Account *account) {
    if (account.proxy.length) return account.proxy;
    return [NSUserDefaults.standardUserDefaults stringForKey:DefaultProxyDefaultsKey] ?: @"";
}

static nw_proxy_config_t ProxyConfiguration(NSDictionary *components) {
    NSString *port = [components[@"port"] stringValue];
    nw_endpoint_t endpoint = nw_endpoint_create_host([components[@"host"] UTF8String], port.UTF8String);
    NSString *scheme = components[@"scheme"];
    nw_proxy_config_t config = [scheme isEqualToString:@"socks5"]
        ? nw_proxy_config_create_socksv5(endpoint)
        : nw_proxy_config_create_http_connect(endpoint, [scheme isEqualToString:@"https"] ? nw_tls_create_options() : nil);
    NSString *user = components[@"user"];
    if (config && user.length)
        nw_proxy_config_set_username_and_password(config, user.UTF8String, [components[@"password"] ?: @"" UTF8String]);
    return config;
}

BOOL ApplyProxyText(NSString *text, WKWebsiteDataStore *store) {
    NSDictionary *components = AccountProxyComponents(text);
    nw_proxy_config_t config = components ? ProxyConfiguration(components) : nil;
    store.proxyConfigurations = config ? @[config] : @[];
    return config != nil || !text.length;
}

WKWebsiteDataStore *AccountDataStore(NSString *identifier, Account *account) {
    WKWebsiteDataStore *store = [WKWebsiteDataStore dataStoreForIdentifier:[[NSUUID alloc] initWithUUIDString:identifier]];
    ApplyProxyText(EffectiveProxyText(account), store);
    return store;
}

@interface ProxyCheck () <WKNavigationDelegate>
@property (nonatomic, strong, nullable) WKWebView *webView;
@property (nonatomic, copy, nullable) void (^completion)(NSString *summary, NSString *failure);
@property (nonatomic, strong, nullable) ProxyCheck *keepAlive;
@end

@implementation ProxyCheck

+ (void)checkProxyText:(NSString *)text completion:(void (^)(NSString *, NSString *))completion {
    WKWebsiteDataStore *store = WKWebsiteDataStore.nonPersistentDataStore;
    if (!ApplyProxyText(text, store)) {
        completion(nil, @"无法识别代理地址，请填写如 http://127.0.0.1:7890 或 socks5://127.0.0.1:1080");
        return;
    }
    ProxyCheck *check = [ProxyCheck new];
    check.keepAlive = check;
    check.completion = completion;
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.websiteDataStore = store;
    check.webView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300) configuration:configuration];
    check.webView.customUserAgent = BrowserPreferredUserAgent();
    check.webView.navigationDelegate = check;
    NSURL *url = [NSURL URLWithString:@"https://chatgpt.com/cdn-cgi/trace"];
    [check.webView loadRequest:[NSURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20]];
    __weak ProxyCheck *weakCheck = check;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakCheck finishWithSummary:nil failure:@"连接超时，请检查代理是否可用"];
    });
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    __weak typeof(self) weakSelf = self;
    [webView evaluateJavaScript:@"document.body ? document.body.innerText : ''" completionHandler:^(id result, NSError *error) {
        NSDictionary *values = NetworkTraceValues([result isKindOfClass:NSString.class] ? result : nil);
        if (!values[@"ip"]) {
            [weakSelf finishWithSummary:nil failure:@"已连接，但没有读到 chatgpt.com 的出口信息"];
            return;
        }
        NSString *region = values[@"loc"] ?: @"未知";
        NSString *summary = [NSString stringWithFormat:@"出口 IP %@ · 地区 %@", values[@"ip"], region];
        if (NetworkRegionUnsupported(region)) summary = [summary stringByAppendingString:@"（ChatGPT 不支持此地区）"];
        [weakSelf finishWithSummary:summary failure:nil];
    }];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self failWithError:error];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self failWithError:error];
}

- (void)failWithError:(NSError *)error {
    NetworkFailure failure = NetworkFailureForError(error);
    NSString *text = failure == NetworkFailureOther ? (error.localizedDescription ?: @"无法连接")
        : [NSString stringWithFormat:@"无法连接 chatgpt.com：%@", NetworkFailureDescription(failure)];
    [self finishWithSummary:nil failure:text];
}

- (void)finishWithSummary:(NSString *)summary failure:(NSString *)failure {
    if (!self.completion) return;
    void (^completion)(NSString *, NSString *) = self.completion;
    self.completion = nil;
    self.webView.navigationDelegate = nil;
    [self.webView stopLoading];
    self.webView = nil;
    self.keepAlive = nil;
    completion(summary, failure);
}
@end

#pragma mark - Diagnosis

static NSTimeInterval const DiagnosisCheckTimeout = 15;

@interface NetworkDiagnosisRunner () <WKNavigationDelegate>
@property (nonatomic, strong) NetworkDiagnosis *diagnosis;
@property (nonatomic, copy, nullable) void (^update)(NetworkDiagnosis *diagnosis);
@property (nonatomic, strong) NSMapTable<WKWebView *, NetworkCheck *> *pages;
@property (nonatomic, strong) NSDate *start;
@property (nonatomic, strong, nullable) nw_connection_t proxyConnection;
@property (nonatomic, strong, nullable) NetworkDiagnosisRunner *keepAlive;
@end

@implementation NetworkDiagnosisRunner

+ (NetworkDiagnosis *)diagnosisForAccount:(Account *)account {
    NSString *origin = account.proxy.length ? @"账号代理" : @"默认代理";
    NSDictionary *system = CFBridgingRelease(CFNetworkCopySystemProxySettings());
    return [[NetworkDiagnosis alloc] initWithProxyText:EffectiveProxyText(account) origin:origin
        systemSettings:system checks:NetworkDiagnosis.standardChecks];
}

+ (instancetype)run:(NetworkDiagnosis *)diagnosis update:(void (^)(NetworkDiagnosis *))update {
    NetworkDiagnosisRunner *runner = [NetworkDiagnosisRunner new];
    runner.diagnosis = diagnosis;
    runner.update = update;
    runner.keepAlive = runner;
    runner.start = NSDate.date;
    runner.pages = [NSMapTable strongToStrongObjectsMapTable];
    [runner probeProxy];
    WKWebsiteDataStore *store = WKWebsiteDataStore.nonPersistentDataStore;
    ApplyProxyText(diagnosis.proxyText, store);
    for (NetworkCheck *check in diagnosis.checks) [runner load:check store:store];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((DiagnosisCheckTimeout + 5) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [runner timeOutRemaining];
    });
    return runner;
}

- (void)load:(NetworkCheck *)check store:(WKWebsiteDataStore *)store {
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.websiteDataStore = store;
    WKWebView *page = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300) configuration:configuration];
    page.customUserAgent = BrowserPreferredUserAgent();
    page.navigationDelegate = self;
    [self.pages setObject:check forKey:page];
    [page loadRequest:[NSURLRequest requestWithURL:check.URL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
        timeoutInterval:DiagnosisCheckTimeout]];
}

/// Connects to the proxy's port directly, so "the proxy app isn't running" is told apart from a dead node.
- (void)probeProxy {
    NetworkDiagnosis *diagnosis = self.diagnosis;
    if (!diagnosis.proxyHost) return;
    NSString *port = [NSString stringWithFormat:@"%ld", (long)diagnosis.proxyPort];
    nw_endpoint_t endpoint = nw_endpoint_create_host(diagnosis.proxyHost.UTF8String, port.UTF8String);
    nw_parameters_t parameters = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_parameters_set_prefer_no_proxy(parameters, true);
    nw_connection_t connection = nw_connection_create(endpoint, parameters);
    self.proxyConnection = connection;
    __weak typeof(self) weakSelf = self;
    nw_connection_set_queue(connection, dispatch_get_main_queue());
    nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t error) {
        if (state == nw_connection_state_ready) [weakSelf finishProxyProbe:YES];
        else if (state == nw_connection_state_failed || state == nw_connection_state_waiting) [weakSelf finishProxyProbe:NO];
    });
    nw_connection_start(connection);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf finishProxyProbe:NO];
    });
}

- (void)finishProxyProbe:(BOOL)reachable {
    if (!self.proxyConnection) return;
    nw_connection_t connection = self.proxyConnection;
    self.proxyConnection = nil;
    nw_connection_set_state_changed_handler(connection, nil);
    nw_connection_cancel(connection);
    self.diagnosis.proxyReachable = @(reachable);
    [self changed];
}

- (NSTimeInterval)elapsed { return -self.start.timeIntervalSinceNow; }

- (void)webView:(WKWebView *)webView decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse
    decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
    NetworkCheck *check = [self.pages objectForKey:webView];
    NSInteger status = [navigationResponse.response isKindOfClass:NSHTTPURLResponse.class]
        ? [(NSHTTPURLResponse *)navigationResponse.response statusCode] : 0;
    if (check.readsTrace && status == 200) {
        decisionHandler(WKNavigationResponsePolicyAllow);
        return;
    }
    // Any response means the host is reachable; there's no need to load the page itself.
    decisionHandler(WKNavigationResponsePolicyCancel);
    [check finishWithStatus:status duration:[self elapsed]];
    [self closePage:webView];
}

- (void)webView:(WKWebView *)webView didReceiveServerRedirectForProvisionalNavigation:(WKNavigation *)navigation {
    NetworkCheck *check = [self.pages objectForKey:webView];
    if (check.readsTrace) return;
    [check finishWithStatus:302 duration:[self elapsed]];
    [self closePage:webView];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    NetworkCheck *check = [self.pages objectForKey:webView];
    if (!check) return;
    NSTimeInterval duration = [self elapsed];
    __weak typeof(self) weakSelf = self;
    [webView evaluateJavaScript:@"document.body ? document.body.innerText : ''" completionHandler:^(id result, NSError *error) {
        NetworkDiagnosisRunner *strongSelf = weakSelf;
        if (!strongSelf || check.finished) return;
        NSDictionary *values = NetworkTraceValues([result isKindOfClass:NSString.class] ? result : nil);
        strongSelf.diagnosis.exitIP = values[@"ip"];
        strongSelf.diagnosis.region = values[@"loc"];
        [check finishWithStatus:200 duration:duration];
        [strongSelf closePage:webView];
    }];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self page:webView failedWithError:error];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self page:webView failedWithError:error];
}

- (void)page:(WKWebView *)webView failedWithError:(NSError *)error {
    NetworkCheck *check = [self.pages objectForKey:webView];
    if (!check) return;
    [check finishWithError:error duration:[self elapsed]];
    [self closePage:webView];
}

- (void)closePage:(WKWebView *)webView {
    if (![self.pages objectForKey:webView]) return;
    webView.navigationDelegate = nil;
    [webView stopLoading];
    [self.pages removeObjectForKey:webView];
    [self changed];
}

- (void)timeOutRemaining {
    for (WKWebView *page in self.pages.keyEnumerator.allObjects) {
        [[self.pages objectForKey:page] finishWithFailure:NetworkFailureTimeout duration:[self elapsed]];
        [self closePage:page];
    }
    [self finishProxyProbe:NO];
}

- (void)changed {
    if (self.update) self.update(self.diagnosis);
    if (self.diagnosis.finished) [self cancel];
}

- (void)cancel {
    self.update = nil;
    for (WKWebView *page in self.pages.keyEnumerator.allObjects) {
        page.navigationDelegate = nil;
        [page stopLoading];
    }
    [self.pages removeAllObjects];
    if (self.proxyConnection) {
        nw_connection_set_state_changed_handler(self.proxyConnection, nil);
        nw_connection_cancel(self.proxyConnection);
        self.proxyConnection = nil;
    }
    self.keepAlive = nil;
}
@end
