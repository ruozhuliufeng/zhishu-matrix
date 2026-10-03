#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Why a connection failed, in the terms a user can act on.
typedef NS_ENUM(NSInteger, NetworkFailure) {
    NetworkFailureNone = 0,
    NetworkFailureOffline,
    NetworkFailureDNS,
    NetworkFailureConnect,
    NetworkFailureTimeout,
    NetworkFailureTLS,
    NetworkFailureCertificate,
    NetworkFailureLost,
    NetworkFailureProxy,
    NetworkFailureProxyAuth,
    NetworkFailureOther,
};

/// Classifies an NSURL / CFNetwork / POSIX error, looking through underlying errors when the outer one is generic.
NetworkFailure NetworkFailureForError(NSError *_Nullable error);
/// "安全连接（TLS）被中断".
NSString *NetworkFailureDescription(NetworkFailure failure);
/// The likely cause and what to do, or nil when there is nothing better than the description.
NSString *_Nullable NetworkFailureHint(NetworkFailure failure);
/// Host of the URL that failed to load, from the error's user info.
NSString *_Nullable NetworkFailingHost(NSError *error);
/// Regions ChatGPT does not serve (Cloudflare `loc` codes).
BOOL NetworkRegionUnsupported(NSString *_Nullable region);
/// key=value lines of a Cloudflare trace page.
NSDictionary<NSString *, NSString *> *NetworkTraceValues(NSString *_Nullable body);
/// "HTTPS 127.0.0.1:7890" for the proxy macOS uses for https pages; "" when they go direct.
/// `settings` is CFNetworkCopySystemProxySettings(). `host`/`port` receive the endpoint to probe, if any.
NSString *NetworkSystemProxySummary(NSDictionary *_Nullable settings, NSString *_Nullable *_Nullable host, NSInteger *_Nullable port);

/// One site loaded through the proxy under test.
@interface NetworkCheck : NSObject
+ (instancetype)checkWithTitle:(NSString *)title URL:(NSString *)url control:(BOOL)control;
@property (nonatomic, readonly) NSString *title;
@property (nonatomic, readonly) NSURL *URL;
@property (nonatomic, readonly) NSString *host;
/// A site outside OpenAI, to tell a dead proxy from a broken OpenAI route.
@property (nonatomic, readonly) BOOL control;
/// Reads the exit IP and region from the page.
@property (nonatomic, readonly) BOOL readsTrace;
@property (nonatomic, readonly) BOOL finished;
@property (nonatomic, readonly) BOOL succeeded;
@property (nonatomic, readonly) NetworkFailure failure;
@property (nonatomic, readonly) NSInteger statusCode;
@property (nonatomic, readonly) NSTimeInterval duration;
@property (nonatomic, readonly, nullable) NSString *errorText;
- (void)finishWithStatus:(NSInteger)status duration:(NSTimeInterval)duration;
- (void)finishWithError:(nullable NSError *)error duration:(NSTimeInterval)duration;
- (void)finishWithFailure:(NetworkFailure)failure duration:(NSTimeInterval)duration;
/// "可连接 · 320 毫秒" or the failure.
@property (nonatomic, readonly) NSString *detail;
@end

typedef NS_ENUM(NSInteger, NetworkVerdict) {
    NetworkVerdictPending = 0,
    NetworkVerdictOK,
    NetworkVerdictUnsupportedRegion,
    /// Some OpenAI hosts work and others don't.
    NetworkVerdictPartial,
    /// The control site works but no OpenAI host does.
    NetworkVerdictOpenAIRoute,
    /// Nothing works through the proxy (or directly, without one).
    NetworkVerdictNoRoute,
    NetworkVerdictProxyDown,
    NetworkVerdictOffline,
};

/// Loads ChatGPT's hosts and a control site through one proxy and explains the result.
@interface NetworkDiagnosis : NSObject
/// `proxyText` "" follows the system settings described by `systemSettings`.
/// `origin` names where the proxy comes from ("账号代理", "默认代理").
- (instancetype)initWithProxyText:(nullable NSString *)proxyText origin:(nullable NSString *)origin
    systemSettings:(nullable NSDictionary *)systemSettings checks:(NSArray<NetworkCheck *> *)checks;
+ (NSArray<NetworkCheck *> *)standardChecks;
@property (nonatomic, readonly) NSString *proxyText;
/// "默认代理 http://127.0.0.1:7890", "系统代理 HTTPS 127.0.0.1:7890", "未使用代理（直连）".
@property (nonatomic, readonly) NSString *proxyDescription;
@property (nonatomic, readonly) BOOL usesProxy;
/// The proxy's own address, probed separately; nil for automatic configuration or direct connections.
@property (nonatomic, readonly, nullable) NSString *proxyHost;
@property (nonatomic, readonly) NSInteger proxyPort;
/// nil until probed (or when there is nothing to probe).
@property (nonatomic, strong, nullable) NSNumber *proxyReachable;
@property (nonatomic, readonly) NSArray<NetworkCheck *> *checks;
@property (nonatomic, copy, nullable) NSString *exitIP;
@property (nonatomic, copy, nullable) NSString *region;
@property (nonatomic, readonly) BOOL finished;
@property (nonatomic, readonly) NetworkVerdict verdict;
@property (nonatomic, readonly) NSString *headline;
@property (nonatomic, readonly, nullable) NSString *advice;
/// Plain-text summary for the clipboard.
- (NSString *)textReport;
@end

NS_ASSUME_NONNULL_END
