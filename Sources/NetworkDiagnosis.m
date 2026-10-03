#import "NetworkDiagnosis.h"
#import "AccountInsights.h"

static NSString *const CFNetworkErrorDomain = @"kCFErrorDomainCFNetwork";

static NetworkFailure FailureForCode(NSInteger code) {
    switch (code) {
        case NSURLErrorNotConnectedToInternet: case NSURLErrorInternationalRoamingOff:
        case NSURLErrorCallIsActive: case NSURLErrorDataNotAllowed:
            return NetworkFailureOffline;
        case NSURLErrorCannotFindHost: case NSURLErrorDNSLookupFailed:
            return NetworkFailureDNS;
        case NSURLErrorCannotConnectToHost:
            return NetworkFailureConnect;
        case NSURLErrorTimedOut:
            return NetworkFailureTimeout;
        case NSURLErrorSecureConnectionFailed: case NSURLErrorClientCertificateRejected:
        case NSURLErrorClientCertificateRequired:
            return NetworkFailureTLS;
        case NSURLErrorServerCertificateHasBadDate: case NSURLErrorServerCertificateUntrusted:
        case NSURLErrorServerCertificateHasUnknownRoot: case NSURLErrorServerCertificateNotYetValid:
            return NetworkFailureCertificate;
        case NSURLErrorNetworkConnectionLost: case NSURLErrorBadServerResponse:
        case NSURLErrorCannotParseResponse: case NSURLErrorZeroByteResource:
            return NetworkFailureLost;
        // kCFErrorHTTPProxyConnectionFailure, kCFErrorHTTPSProxyConnectionFailure,
        // kCFStreamErrorHTTPSProxyFailureUnexpectedResponseToCONNECTMethod, SOCKS errors.
        case 306: case 310: case 311: case 100: case 101: case 110: case 111: case 112: case 113:
        case 120: case 121: case 123: case 124:
            return NetworkFailureProxy;
        case 307: case 122: // kCFErrorHTTPBadProxyCredentials, kCFSOCKS5ErrorBadCredentials
            return NetworkFailureProxyAuth;
        default:
            return NetworkFailureOther;
    }
}

static NetworkFailure FailureForPOSIXCode(NSInteger code) {
    switch (code) {
        case ECONNREFUSED: case ENETUNREACH: case EHOSTUNREACH: case EHOSTDOWN: return NetworkFailureConnect;
        case ETIMEDOUT: return NetworkFailureTimeout;
        case ECONNRESET: case ECONNABORTED: case EPIPE: return NetworkFailureLost;
        case ENETDOWN: return NetworkFailureOffline;
        default: return NetworkFailureOther;
    }
}

NetworkFailure NetworkFailureForError(NSError *error) {
    for (NSError *current = error; current; ) {
        NetworkFailure failure = NetworkFailureOther;
        if ([current.domain isEqualToString:NSURLErrorDomain] || [current.domain isEqualToString:CFNetworkErrorDomain])
            failure = FailureForCode(current.code);
        else if ([current.domain isEqualToString:NSPOSIXErrorDomain])
            failure = FailureForPOSIXCode(current.code);
        if (failure != NetworkFailureOther) return failure;
        id underlying = current.userInfo[NSUnderlyingErrorKey];
        current = [underlying isKindOfClass:NSError.class] ? underlying : nil;
    }
    return error ? NetworkFailureOther : NetworkFailureNone;
}

NSString *NetworkFailureDescription(NetworkFailure failure) {
    switch (failure) {
        case NetworkFailureNone: return @"可连接";
        case NetworkFailureOffline: return @"没有网络连接";
        case NetworkFailureDNS: return @"无法解析域名";
        case NetworkFailureConnect: return @"无法建立连接";
        case NetworkFailureTimeout: return @"连接超时";
        case NetworkFailureTLS: return @"安全连接（TLS）被中断";
        case NetworkFailureCertificate: return @"证书不受信任";
        case NetworkFailureLost: return @"连接中途断开";
        case NetworkFailureProxy: return @"代理拒绝了连接";
        case NetworkFailureProxyAuth: return @"代理认证失败";
        case NetworkFailureOther: return @"连接失败";
    }
    return @"连接失败";
}

NSString *NetworkFailureHint(NetworkFailure failure) {
    switch (failure) {
        case NetworkFailureNone: case NetworkFailureOther: return nil;
        case NetworkFailureOffline: return @"请检查 Wi‑Fi 或网线连接后重试。";
        case NetworkFailureCertificate:
            return @"可能是代理软件开启了 HTTPS 解密（MITM），或 Mac 的日期和时间不正确。";
        case NetworkFailureProxyAuth: return @"请检查代理地址中的用户名和密码。";
        default:
            return @"常见原因是代理节点失效，或代理规则没有让 OpenAI 的域名走代理。\n点“网络诊断”可以逐个检查。";
    }
}

NSString *NetworkFailingHost(NSError *error) {
    id url = error.userInfo[NSURLErrorFailingURLErrorKey];
    if (![url isKindOfClass:NSURL.class]) {
        id text = error.userInfo[NSURLErrorFailingURLStringErrorKey];
        url = [text isKindOfClass:NSString.class] ? [NSURL URLWithString:text] : nil;
    }
    NSString *host = [(NSURL *)url host];
    return host.length ? host : nil;
}

BOOL NetworkRegionUnsupported(NSString *region) {
    return region.length && [@[@"CN", @"HK", @"MO", @"RU", @"IR", @"KP", @"SY", @"CU"] containsObject:region.uppercaseString];
}

NSDictionary<NSString *, NSString *> *NetworkTraceValues(NSString *body) {
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    for (NSString *line in [body ?: @"" componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSRange equals = [line rangeOfString:@"="];
        if (equals.location == NSNotFound || !equals.location) continue;
        NSString *key = [[line substringToIndex:equals.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *value = [[line substringFromIndex:NSMaxRange(equals)] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (key.length && value.length) values[key] = value;
    }
    return values;
}

static BOOL SettingEnabled(NSDictionary *settings, NSString *key) {
    id value = settings[key];
    return [value respondsToSelector:@selector(boolValue)] && [value boolValue];
}

NSString *NetworkSystemProxySummary(NSDictionary *settings, NSString **host, NSInteger *port) {
    if (host) *host = nil;
    if (port) *port = 0;
    if (SettingEnabled(settings, @"ProxyAutoConfigEnable")) return @"自动代理配置（PAC）";
    if (SettingEnabled(settings, @"ProxyAutoDiscoveryEnable")) return @"自动发现代理（WPAD）";
    for (NSArray *kind in @[@[@"HTTPS", @"HTTPS"], @[@"SOCKS", @"SOCKS"]]) {
        NSString *prefix = kind[0];
        NSString *proxyHost = settings[[prefix stringByAppendingString:@"Proxy"]];
        NSInteger proxyPort = [settings[[prefix stringByAppendingString:@"Port"]] integerValue];
        if (!SettingEnabled(settings, [prefix stringByAppendingString:@"Enable"]) ||
            ![proxyHost isKindOfClass:NSString.class] || !proxyHost.length || proxyPort <= 0) continue;
        if (host) *host = proxyHost;
        if (port) *port = proxyPort;
        return [NSString stringWithFormat:@"%@ %@:%ld", kind[1], proxyHost, (long)proxyPort];
    }
    return @"";
}

#pragma mark - Checks

@interface NetworkCheck ()
@property (nonatomic, readwrite) NSString *title;
@property (nonatomic, readwrite) NSURL *URL;
@property (nonatomic, readwrite) BOOL control;
@property (nonatomic, readwrite) BOOL finished;
@property (nonatomic, readwrite) NetworkFailure failure;
@property (nonatomic, readwrite) NSInteger statusCode;
@property (nonatomic, readwrite) NSTimeInterval duration;
@property (nonatomic, readwrite, nullable) NSString *errorText;
@end

@implementation NetworkCheck

+ (instancetype)checkWithTitle:(NSString *)title URL:(NSString *)url control:(BOOL)control {
    NetworkCheck *check = [NetworkCheck new];
    check.title = title;
    check.URL = [NSURL URLWithString:url];
    check.control = control;
    return check;
}

- (NSString *)host { return self.URL.host ?: @""; }
- (BOOL)readsTrace { return [self.URL.path hasSuffix:@"/cdn-cgi/trace"]; }
- (BOOL)succeeded { return self.finished && self.failure == NetworkFailureNone; }

- (void)finishWithStatus:(NSInteger)status duration:(NSTimeInterval)duration {
    if (self.finished) return;
    self.statusCode = status;
    self.failure = status == 407 ? NetworkFailureProxyAuth : NetworkFailureNone;
    self.duration = duration;
    self.finished = YES;
}

- (void)finishWithError:(NSError *)error duration:(NSTimeInterval)duration {
    if (self.finished) return;
    self.failure = NetworkFailureForError(error);
    self.errorText = error.localizedDescription;
    self.duration = duration;
    self.finished = YES;
}

- (void)finishWithFailure:(NetworkFailure)failure duration:(NSTimeInterval)duration {
    if (self.finished) return;
    self.failure = failure;
    self.duration = duration;
    self.finished = YES;
}

- (NSString *)detail {
    if (!self.finished) return @"正在检测…";
    if (self.failure != NetworkFailureNone) return NetworkFailureDescription(self.failure);
    return [NSString stringWithFormat:@"可连接 · %.0f 毫秒", self.duration * 1000];
}
@end

#pragma mark - Diagnosis

@interface NetworkDiagnosis ()
@property (nonatomic, readwrite) NSString *proxyText;
@property (nonatomic, readwrite) NSString *proxyDescription;
@property (nonatomic, readwrite) BOOL usesProxy;
@property (nonatomic, readwrite, nullable) NSString *proxyHost;
@property (nonatomic, readwrite) NSInteger proxyPort;
@property (nonatomic, readwrite) NSArray<NetworkCheck *> *checks;
@end

@implementation NetworkDiagnosis

+ (NSArray<NetworkCheck *> *)standardChecks {
    return @[
        [NetworkCheck checkWithTitle:@"ChatGPT 网页" URL:@"https://chatgpt.com/cdn-cgi/trace" control:NO],
        [NetworkCheck checkWithTitle:@"登录与授权" URL:@"https://auth.openai.com/" control:NO],
        [NetworkCheck checkWithTitle:@"网页脚本与样式" URL:@"https://cdn.oaistatic.com/" control:NO],
        [NetworkCheck checkWithTitle:@"图片与文件" URL:@"https://files.oaiusercontent.com/" control:NO],
        [NetworkCheck checkWithTitle:@"对照：Google" URL:@"https://www.google.com/generate_204" control:YES],
    ];
}

- (instancetype)initWithProxyText:(NSString *)proxyText origin:(NSString *)origin
    systemSettings:(NSDictionary *)systemSettings checks:(NSArray<NetworkCheck *> *)checks {
    if ((self = [super init])) {
        _proxyText = [proxyText ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        _checks = [checks copy];
        NSDictionary *components = AccountProxyComponents(_proxyText);
        if (components) {
            _usesProxy = YES;
            _proxyHost = components[@"host"];
            _proxyPort = [components[@"port"] integerValue];
            NSString *address = [NSString stringWithFormat:@"%@://%@:%ld", components[@"scheme"], _proxyHost, (long)_proxyPort];
            if ([components[@"user"] length]) address = [address stringByAppendingString:@"（带认证）"];
            _proxyDescription = [NSString stringWithFormat:@"%@ %@", origin.length ? origin : @"代理", address];
        } else {
            NSString *host = nil;
            NSInteger port = 0;
            NSString *summary = NetworkSystemProxySummary(systemSettings, &host, &port);
            _usesProxy = summary.length > 0;
            _proxyHost = host;
            _proxyPort = port;
            _proxyDescription = summary.length ? [@"系统代理 " stringByAppendingString:summary] : @"未使用代理（直连）";
        }
    }
    return self;
}

- (BOOL)finished {
    for (NetworkCheck *check in self.checks) if (!check.finished) return NO;
    return !self.proxyHost || self.proxyReachable != nil;
}

- (NSArray<NetworkCheck *> *)openAIChecks {
    return [self.checks filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"control == NO"]];
}

- (NetworkVerdict)verdict {
    if (!self.finished) return NetworkVerdictPending;
    if (self.proxyReachable && !self.proxyReachable.boolValue) return NetworkVerdictProxyDown;
    NSArray<NetworkCheck *> *openAI = [self openAIChecks];
    NSUInteger working = 0;
    for (NetworkCheck *check in openAI) if (check.succeeded) working++;
    if (working == openAI.count)
        return NetworkRegionUnsupported(self.region) ? NetworkVerdictUnsupportedRegion : NetworkVerdictOK;
    BOOL offline = YES, controlWorks = NO;
    for (NetworkCheck *check in self.checks) {
        if (check.succeeded) offline = NO;
        else if (check.failure != NetworkFailureOffline) offline = NO;
        if (check.control && check.succeeded) controlWorks = YES;
    }
    if (offline) return NetworkVerdictOffline;
    if (working) return NetworkVerdictPartial;
    return controlWorks ? NetworkVerdictOpenAIRoute : NetworkVerdictNoRoute;
}

- (NSString *)proxyAddress {
    return [NSString stringWithFormat:@"%@:%ld", self.proxyHost, (long)self.proxyPort];
}

- (NSString *)headline {
    switch (self.verdict) {
        case NetworkVerdictPending: return @"正在检测…";
        case NetworkVerdictOK: return @"网络正常";
        case NetworkVerdictUnsupportedRegion:
            return [NSString stringWithFormat:@"出口地区 %@ 不受 ChatGPT 支持", self.region];
        case NetworkVerdictPartial: return @"部分 OpenAI 域名连不上";
        case NetworkVerdictOpenAIRoute:
            return self.usesProxy ? @"代理可用，但连不上 OpenAI" : @"能访问外网，但连不上 OpenAI";
        case NetworkVerdictNoRoute:
            return self.usesProxy ? @"代理已连接，但访问不了外网" : @"无法直接访问 ChatGPT";
        case NetworkVerdictProxyDown: return [NSString stringWithFormat:@"代理 %@ 连不上", [self proxyAddress]];
        case NetworkVerdictOffline: return @"没有网络连接";
    }
    return @"";
}

- (NSString *)advice {
    static NSString *const Rules = @"在代理软件中为 OpenAI 换一个可用节点，或临时切到全局模式；规则模式下确认 "
        "chatgpt.com、openai.com、oaistatic.com、oaiusercontent.com 都走代理。";
    static NSString *const NoProxy = @"当前没有使用代理。开启代理软件的“系统代理”，或在“设置 → 网络”中填写代理地址。";
    switch (self.verdict) {
        case NetworkVerdictPending: return nil;
        case NetworkVerdictOK:
            return @"ChatGPT 用到的域名都能连上。如果页面仍打不开，点“重新加载”；仍不行可以稍后再试，或在代理软件中换一个节点。";
        case NetworkVerdictUnsupportedRegion:
            return [NSString stringWithFormat:@"能连上 OpenAI，但出口在 %@，ChatGPT 会拒绝服务。请在代理软件中为 OpenAI 的域名换用"
                "美国、日本、新加坡等地区的节点。", self.region];
        case NetworkVerdictPartial: {
            NSMutableArray *failed = [NSMutableArray array];
            for (NetworkCheck *check in [self openAIChecks])
                if (!check.succeeded) [failed addObject:[NSString stringWithFormat:@"%@（%@）", check.title, check.host]];
            return [NSString stringWithFormat:@"连不上：%@。页面可能能打开，但登录、授权或图片会失败。通常是代理规则只覆盖了部分域名，"
                "或节点对部分域名不稳定。%@", [failed componentsJoinedByString:@"、"], Rules];
        }
        case NetworkVerdictOpenAIRoute:
            return self.usesProxy ? [@"Google 能访问，说明代理本身正常，问题出在 OpenAI 用的节点或规则。" stringByAppendingString:Rules]
                                  : NoProxy;
        case NetworkVerdictNoRoute:
            return self.usesProxy ? @"代理端口能连上，但经过它访问不了任何外网站点，当前节点可能已经失效。在代理软件中切换节点后重新检测。"
                                  : NoProxy;
        case NetworkVerdictProxyDown:
            return @"代理软件可能没有运行，或端口与填写的不一致。打开代理软件，确认它正在运行、端口一致后重新检测。";
        case NetworkVerdictOffline: return @"请检查 Wi‑Fi 或网线连接后重新检测。";
    }
    return nil;
}

- (NSString *)textReport {
    NSMutableArray *lines = [NSMutableArray arrayWithObjects:@"智枢矩阵 · 网络诊断", [@"代理：" stringByAppendingString:self.proxyDescription], nil];
    if (self.proxyHost && self.proxyReachable)
        [lines addObject:[NSString stringWithFormat:@"代理端口 %@：%@", [self proxyAddress], self.proxyReachable.boolValue ? @"可连接" : @"连不上"]];
    for (NetworkCheck *check in self.checks) {
        NSString *line = [NSString stringWithFormat:@"%@ %@：%@", check.title, check.host, check.detail];
        if (check.failure != NetworkFailureNone && check.errorText.length)
            line = [line stringByAppendingFormat:@"（%@）", check.errorText];
        [lines addObject:line];
    }
    if (self.exitIP.length || self.region.length)
        [lines addObject:[NSString stringWithFormat:@"出口：%@ · %@", self.exitIP ?: @"未知", self.region ?: @"未知"]];
    [lines addObject:[@"结论：" stringByAppendingString:self.headline]];
    if (self.advice) [lines addObject:self.advice];
    return [lines componentsJoinedByString:@"\n"];
}
@end
