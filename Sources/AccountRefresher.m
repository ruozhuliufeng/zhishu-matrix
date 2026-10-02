#import "AccountRefresher.h"
#import "Account.h"
#import "BrowserSession.h"
#import "SubscriptionParser.h"

NSString *const UsageRefreshMinutesDefaultsKey = @"usageRefreshMinutes";
NSNotificationName const UsageRefreshSettingsDidChangeNotification = @"UsageRefreshSettingsDidChangeNotification";

NSInteger UsageRefreshMinutes(void) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:UsageRefreshMinutesDefaultsKey];
    return value ? MAX(0, [value integerValue]) : 1440;
}

void MigrateUsageRefreshToDaily(void) {
    // 0.2.9: subscription records only need a daily read; earlier versions refreshed every 30 minutes.
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults boolForKey:@"usageRefreshMigratedToDaily"]) return;
    id value = [defaults objectForKey:UsageRefreshMinutesDefaultsKey];
    if (value && [value integerValue] > 0 && [value integerValue] < 1440) [defaults setInteger:1440 forKey:UsageRefreshMinutesDefaultsKey];
    [defaults setBool:YES forKey:@"usageRefreshMigratedToDaily"];
}

static BOOL IsSuccess(NSInteger status) { return status >= 200 && status < 300; }

static NSString *FailureMessage(NSInteger status) {
    switch (status) {
        case 0: return @"无法连接 ChatGPT，请检查网络或代理";
        case 401: return @"登录已失效，请在浏览模式中重新登录";
        case 403: return @"请求被拒绝（HTTP 403），可在浏览模式中打开此账号后重试";
        case 404: return @"此账号暂无用量数据";
        case 429: return @"请求过于频繁，请稍后再试";
        default:
            if (status >= 500) return [NSString stringWithFormat:@"ChatGPT 服务暂时不可用（HTTP %ld）", (long)status];
            return [NSString stringWithFormat:@"无法读取用量（HTTP %ld）", (long)status];
    }
}

/// One hidden page on an account's data store that runs UsageProbe.js and reports what it returned.
@interface AccountProbeRun : NSObject <WKNavigationDelegate>
@property (nonatomic, strong, nullable) WKWebView *webView;
@property (nonatomic, copy) NSString *script;
@property (nonatomic, copy, nullable) void (^completion)(NSDictionary *_Nullable result, NSString *_Nullable failure);
@end

@implementation AccountProbeRun

- (void)startWithDataStore:(WKWebsiteDataStore *)dataStore url:(NSURL *)url {
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.websiteDataStore = dataStore;
    self.webView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 320, 240) configuration:configuration];
    self.webView.customUserAgent = BrowserPreferredUserAgent();
    self.webView.navigationDelegate = self;
    [self.webView loadRequest:[NSURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20]];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(40 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf finishWithResult:nil failure:@"读取超时，请检查网络或代理"];
    });
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    __weak typeof(self) weakSelf = self;
    [webView callAsyncJavaScript:self.script arguments:@{} inFrame:nil inContentWorld:WKContentWorld.pageWorld
        completionHandler:^(id result, NSError *error) {
            [weakSelf finishWithResult:[result isKindOfClass:NSDictionary.class] ? result : nil
                failure:error ? FailureMessage(0) : nil];
        }];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self finishWithResult:nil failure:error.localizedDescription ?: FailureMessage(0)];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self finishWithResult:nil failure:error.localizedDescription ?: FailureMessage(0)];
}

- (void)finishWithResult:(NSDictionary *)result failure:(NSString *)failure {
    if (!self.completion) return;
    void (^completion)(NSDictionary *, NSString *) = self.completion;
    self.completion = nil;
    self.webView.navigationDelegate = nil;
    [self.webView stopLoading];
    self.webView = nil;
    completion(result, failure);
}
@end

@implementation AccountRefresher {
    AccountStore *_store;
    NSMutableArray<NSString *> *_queue;
    NSMutableSet<NSString *> *_active;
    NSMutableSet<AccountProbeRun *> *_runs;
}

- (instancetype)initWithStore:(AccountStore *)store {
    if ((self = [super init])) {
        _store = store;
        _queue = [NSMutableArray array];
        _active = [NSMutableSet set];
        _runs = [NSMutableSet set];
        _baseURL = [NSURL URLWithString:@"https://chatgpt.com"];
    }
    return self;
}

- (BOOL)isRefreshing { return _active.count > 0 || _queue.count > 0; }

- (BOOL)isRefreshingAccountID:(NSString *)identifier {
    return [_active containsObject:identifier] || [_queue containsObject:identifier];
}

- (void)notify { if (self.stateChanged) self.stateChanged(); }

- (void)refreshAccountIDs:(NSArray<NSString *> *)identifiers {
    for (NSString *identifier in identifiers)
        if (![self isRefreshingAccountID:identifier]) [_queue addObject:identifier];
    [self notify];
    [self pump];
}

- (void)pump {
    while (_active.count < 2 && _queue.count) {
        NSString *identifier = _queue.firstObject;
        [_queue removeObjectAtIndex:0];
        [_active addObject:identifier];
        [self probeAccountID:identifier completion:^(NSDictionary *result, NSString *failure) {
            [self apply:result failure:failure toAccountID:identifier];
            [self->_active removeObject:identifier];
            [self notify];
            [self pump];
        }];
    }
}

- (NSString *)script {
    NSString *path = [NSBundle.mainBundle pathForResource:@"UsageProbe" ofType:@"js"];
    return path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] : nil;
}

- (void)probeAccountID:(NSString *)identifier completion:(void (^)(NSDictionary *result, NSString *failure))completion {
    NSString *script = self.script;
    if (!script) {
        completion(nil, @"应用缺少用量读取资源，请重新构建应用。");
        return;
    }
    WKWebsiteDataStore *dataStore = self.dataStoreProvider ? self.dataStoreProvider(identifier)
        : [WKWebsiteDataStore dataStoreForIdentifier:[[NSUUID alloc] initWithUUIDString:identifier]];
    AccountProbeRun *run = [AccountProbeRun new];
    run.script = script;
    __weak typeof(self) weakSelf = self;
    __weak AccountProbeRun *weakRun = run;
    run.completion = ^(NSDictionary *result, NSString *failure) {
        AccountRefresher *strongSelf = weakSelf;
        AccountProbeRun *finished = weakRun;
        if (finished) [strongSelf->_runs removeObject:finished];
        completion(result, failure);
    };
    [_runs addObject:run];
    // A tiny same-origin document gives the script ChatGPT's origin, cookies and Cloudflare clearance.
    [run startWithDataStore:dataStore url:[self.baseURL URLByAppendingPathComponent:@"robots.txt"]];
}

#pragma mark - Results

- (void)apply:(NSDictionary *)result failure:(NSString *)failure toAccountID:(NSString *)identifier {
    Account *account = [_store accountWithID:identifier];
    if (!account) return;
    if ([result[@"signedIn"] isEqual:@NO]) {
        account.signedIn = @NO;
        account.refreshError = @"未登录，请在浏览模式中登录此账号";
        [_store commit];
        return;
    }
    if (!result) {
        account.refreshError = failure ?: FailureMessage(0);
        [_store commit];
        return;
    }
    NSDictionary *usageReply = [result[@"usage"] isKindOfClass:NSDictionary.class] ? result[@"usage"] : @{};
    NSDictionary *subscriptionReply = [result[@"subscription"] isKindOfClass:NSDictionary.class] ? result[@"subscription"] : @{};
    NSInteger usageStatus = [usageReply[@"status"] integerValue];
    NSInteger subscriptionStatus = [subscriptionReply[@"status"] integerValue];
    if ([result[@"signedIn"] isEqual:@YES]) account.signedIn = @YES;
    if (IsSuccess(usageStatus)) {
        NSString *planType = nil;
        AccountUsage *usage = [SubscriptionParser usageFromJSON:usageReply[@"body"] planType:&planType];
        if (usage) account.usage = usage;
        [account applyDetectedPlan:[SubscriptionParser planFromPlanType:planType] source:@"api"];
    }
    if (IsSuccess(subscriptionStatus)) {
        NSDictionary *subscription = [SubscriptionParser subscriptionFromJSON:subscriptionReply[@"body"]];
        [account applyDetectedPlan:subscription[@"plan"] source:@"api"];
        if (subscription[@"expiresAt"]) {
            account.expiresAt = subscription[@"expiresAt"];
            account.expirySource = @"api";
        }
        if (subscription[@"autoRenew"]) account.autoRenew = subscription[@"autoRenew"];
    }
    [account applyListedPrice];
    NSString *email = [result[@"email"] isKindOfClass:NSString.class] ? result[@"email"] : nil;
    if (email.length && !account.email.length) account.email = email;
    account.refreshError = IsSuccess(usageStatus) ? nil : FailureMessage(usageStatus);
    [_store commit];
    if (IsSuccess(usageStatus) && account.usage && self.usageRead) self.usageRead(identifier);
}
@end
