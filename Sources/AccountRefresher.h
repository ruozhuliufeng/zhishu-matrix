#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

@class AccountStore;

NS_ASSUME_NONNULL_BEGIN

/// NSUserDefaults key: minutes between automatic usage refreshes; 0 turns them off. Defaults to 30.
extern NSString *const UsageRefreshMinutesDefaultsKey;
extern NSNotificationName const UsageRefreshSettingsDidChangeNotification;
NSInteger UsageRefreshMinutes(void);

/// Reads usage limits and subscription renewal for accounts from ChatGPT's backend API. Each account is read in a
/// hidden web view on its own data store, so WebKit supplies the sign-in exactly as when browsing; only the parsed
/// results leave the page.
@interface AccountRefresher : NSObject
/// https://chatgpt.com; replaceable for tests.
@property (nonatomic, copy) NSURL *baseURL;
/// Returns the data store holding an account's sign-in.
@property (nonatomic, copy, nullable) WKWebsiteDataStore *_Nonnull (^dataStoreProvider)(NSString *accountID);
/// Called on the main queue whenever an account starts or finishes refreshing.
@property (nonatomic, copy, nullable) void (^stateChanged)(void);
/// Called after an account's usage was read successfully.
@property (nonatomic, copy, nullable) void (^usageRead)(NSString *identifier);
@property (nonatomic, readonly) BOOL isRefreshing;

- (instancetype)initWithStore:(AccountStore *)store;
- (void)refreshAccountIDs:(NSArray<NSString *> *)identifiers;
- (BOOL)isRefreshingAccountID:(NSString *)identifier;
@end

NS_ASSUME_NONNULL_END
