#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The password saved in the login keychain for this service and account, if any.
NSString *_Nullable KeychainPassword(NSString *service, NSString *account);
/// Saves the password (an empty or nil password deletes it). Returns NO when the keychain refused.
BOOL KeychainSetPassword(NSString *_Nullable password, NSString *service, NSString *account);

NS_ASSUME_NONNULL_END
