#import "NetworkProxy.h"
#import <Network/Network.h>
#import "Account.h"
#import "AccountInsights.h"
#import "BrowserSession.h"

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
        NSMutableDictionary *values = [NSMutableDictionary dictionary];
        for (NSString *line in [([result isKindOfClass:NSString.class] ? result : @"") componentsSeparatedByString:@"\n"]) {
            NSRange equals = [line rangeOfString:@"="];
            if (equals.location != NSNotFound)
                values[[line substringToIndex:equals.location]] = [line substringFromIndex:NSMaxRange(equals)];
        }
        if (!values[@"ip"]) {
            [weakSelf finishWithSummary:nil failure:@"已连接，但没有读到 chatgpt.com 的出口信息"];
            return;
        }
        NSString *region = values[@"loc"] ?: @"未知";
        NSString *summary = [NSString stringWithFormat:@"出口 IP %@ · 地区 %@", values[@"ip"], region];
        if ([@[@"CN", @"HK", @"MO"] containsObject:region]) summary = [summary stringByAppendingString:@"（ChatGPT 不支持此地区）"];
        [weakSelf finishWithSummary:summary failure:nil];
    }];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self finishWithSummary:nil failure:error.localizedDescription ?: @"无法连接"];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self finishWithSummary:nil failure:error.localizedDescription ?: @"无法连接"];
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
