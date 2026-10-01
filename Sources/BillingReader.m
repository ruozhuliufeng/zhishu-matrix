#import "BillingReader.h"
#import "BrowserSession.h"
#import "SubscriptionParser.h"

@interface BillingReader () <WKNavigationDelegate>
@property (nonatomic, strong) NSMutableArray<NSString *> *queue;
@property (nonatomic, copy, nullable) NSString *current;
@property (nonatomic, strong, nullable) WKWebView *webView;
/// Never shown; gives the page a window so it lays out like a normal tab.
@property (nonatomic, strong, nullable) NSWindow *host;
@property (nonatomic) NSUInteger token;
@property (nonatomic) NSUInteger attempt;
@end

@implementation BillingReader

- (instancetype)init {
    if ((self = [super init])) {
        _queue = [NSMutableArray array];
        _billingURL = [NSURL URLWithString:@"https://chatgpt.com/#settings/Billing"];
    }
    return self;
}

- (BOOL)isReading { return self.current != nil || self.queue.count > 0; }

- (BOOL)isReadingAccountID:(NSString *)identifier {
    return [self.current isEqualToString:identifier] || [self.queue containsObject:identifier];
}

- (void)readAccountIDs:(NSArray<NSString *> *)identifiers {
    for (NSString *identifier in identifiers)
        if (![self isReadingAccountID:identifier]) [self.queue addObject:identifier];
    [self notify];
    [self pump];
}

- (void)notify { if (self.stateChanged) self.stateChanged(); }

- (NSString *)script {
    NSString *path = [NSBundle.mainBundle pathForResource:@"PlanProbe" ofType:@"js"];
    return path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] : nil;
}

- (void)pump {
    if (self.current || !self.queue.count) return;
    self.current = self.queue.firstObject;
    [self.queue removeObjectAtIndex:0];
    self.attempt = 0;
    NSUInteger token = ++self.token;
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.websiteDataStore = self.dataStoreProvider ? self.dataStoreProvider(self.current)
        : [WKWebsiteDataStore dataStoreForIdentifier:[[NSUUID alloc] initWithUUIDString:self.current]];
    self.host = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1280, 900) styleMask:NSWindowStyleMaskBorderless
        backing:NSBackingStoreBuffered defer:YES];
    self.host.releasedWhenClosed = NO;
    self.host.excludedFromWindowsMenu = YES;
    self.webView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 1280, 900) configuration:configuration];
    self.webView.customUserAgent = BrowserPreferredUserAgent();
    self.webView.navigationDelegate = self;
    self.host.contentView = self.webView;
    [self.webView loadRequest:[NSURLRequest requestWithURL:self.billingURL]];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakSelf.token == token) [weakSelf finishWithFailure:@"读取超时，请检查网络或代理"];
    });
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    if (self.attempt == 0) [self scheduleProbeAfter:3];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self finishWithFailure:error.localizedDescription ?: @"无法打开账单页"];
}

- (void)scheduleProbeAfter:(NSTimeInterval)delay {
    NSUInteger token = self.token;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakSelf.token == token) [weakSelf probe];
    });
}

- (void)probe {
    NSString *script = self.script;
    if (!script) { [self finishWithFailure:@"应用缺少页面识别资源，请重新构建应用。"]; return; }
    self.attempt++;
    NSUInteger token = self.token;
    NSString *identifier = self.current;
    __weak typeof(self) weakSelf = self;
    [self.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        BillingReader *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.token != token) return;
        NSDictionary *page = [result isKindOfClass:NSDictionary.class] ? result : @{};
        NSString *details = [page[@"details"] isKindOfClass:NSString.class] ? page[@"details"] : @"";
        if ([SubscriptionParser isBillingText:details] && strongSelf.applyReading && strongSelf.applyReading(identifier, page)) {
            [strongSelf finishWithFailure:nil];
            return;
        }
        // Being sent to another site (the login page) means the account is signed out.
        NSString *host = strongSelf.webView.URL.host.lowercaseString, *home = strongSelf.billingURL.host.lowercaseString;
        if (host && ![host isEqualToString:home] && ![host hasSuffix:[@"." stringByAppendingString:home]]) {
            [strongSelf finishWithFailure:@"未登录，请在浏览模式中登录此账号"];
            return;
        }
        if (strongSelf.attempt >= 7) {
            [strongSelf finishWithFailure:@"没有读到账单信息。请确认此账号已登录，并在“设置 → 账单”中能看到套餐和交易记录。"];
            return;
        }
        // The settings dialog sometimes opens only after the app has finished starting.
        if (strongSelf.attempt == 2 || strongSelf.attempt == 4)
            [strongSelf.webView evaluateJavaScript:@"location.hash = '#settings/Billing'" completionHandler:nil];
        [strongSelf scheduleProbeAfter:3];
    }];
}

- (void)finishWithFailure:(NSString *)failure {
    NSString *identifier = self.current;
    if (!identifier) return;
    self.token++;
    self.webView.navigationDelegate = nil;
    [self.webView stopLoading];
    self.webView = nil;
    self.host.contentView = nil;
    self.host = nil;
    self.current = nil;
    if (self.accountFinished) self.accountFinished(identifier, failure);
    [self notify];
    [self pump];
}
@end
