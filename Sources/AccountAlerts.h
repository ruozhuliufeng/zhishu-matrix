#import <Foundation/Foundation.h>

@class AccountStore;

NS_ASSUME_NONNULL_BEGIN

extern NSString *const NotifyQuotaDefaultsKey;       // BOOL, default YES
extern NSString *const NotifyRenewalDefaultsKey;     // BOOL, default YES
extern NSString *const NotifySignedOutDefaultsKey;   // BOOL, default YES
extern NSNotificationName const AlertSettingsDidChangeNotification;

/// Posts macOS notifications for low or recovered quota, upcoming renewals and lost sign-ins.
@interface AccountAlerts : NSObject
@property (nonatomic, copy, nullable) void (^openAccount)(NSString *identifier);
/// Asks to record a payment for the account; `date` is "yyyy-MM-dd" or empty for today.
@property (nonatomic, copy, nullable) void (^recordPayment)(NSString *identifier, NSString *date);
- (instancetype)initWithStore:(AccountStore *)store;
/// Asks for permission when any kind is enabled and checks the accounts once.
- (void)start;
/// Checks the accounts for anything new to announce.
- (void)evaluate;
- (void)forgetSignInOfAccountIDs:(NSArray<NSString *> *)identifiers;
/// "已开启", "未允许…" for the settings window.
- (void)describeAuthorization:(void (^)(NSString *description, BOOL allowed))completion;
@end

NS_ASSUME_NONNULL_END
