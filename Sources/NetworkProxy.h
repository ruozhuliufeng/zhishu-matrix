#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

@class Account;
@class NetworkDiagnosis;

NS_ASSUME_NONNULL_BEGIN

/// NSUserDefaults key: proxy used by accounts without their own ("" = macOS system proxy settings).
extern NSString *const DefaultProxyDefaultsKey;
extern NSNotificationName const ProxySettingsDidChangeNotification;

/// The account's own proxy, else the default one; empty when pages follow the system settings.
NSString *EffectiveProxyText(Account *_Nullable account);
/// The account's persistent WebKit data store with its proxy applied.
WKWebsiteDataStore *AccountDataStore(NSString *identifier, Account *_Nullable account);
/// Applies `text` (see AccountProxyComponents) to the store; returns NO when the text is not a proxy address.
BOOL ApplyProxyText(NSString *_Nullable text, WKWebsiteDataStore *store);

/// Loads chatgpt.com's trace page through `text` (or the system settings when empty) and reports the exit IP and region.
@interface ProxyCheck : NSObject
+ (void)checkProxyText:(nullable NSString *)text completion:(void (^)(NSString *_Nullable summary, NSString *_Nullable failure))completion;
@end

/// Runs a NetworkDiagnosis: probes the proxy's port and loads each check in its own page through the proxy.
@interface NetworkDiagnosisRunner : NSObject
/// A diagnosis of the proxy `account` uses (its own, else the default one, else the system settings).
+ (NetworkDiagnosis *)diagnosisForAccount:(nullable Account *)account;
/// `update` runs on the main thread after each finished check, the last time with `diagnosis.finished` set.
+ (instancetype)run:(NetworkDiagnosis *)diagnosis update:(void (^)(NetworkDiagnosis *diagnosis))update;
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
