#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

@class Account;

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

NS_ASSUME_NONNULL_END
