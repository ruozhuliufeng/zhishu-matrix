#import <Cocoa/Cocoa.h>

@class Account;

NS_ASSUME_NONNULL_BEGIN

/// Checks whether ChatGPT's hosts can be reached through the proxy an account uses and explains failures.
@interface NetworkDiagnosisWindowController : NSWindowController
/// Shows the diagnosis window and starts checking `account`'s proxy, or the default proxy when nil.
+ (void)showForAccount:(nullable Account *)account;
@end

NS_ASSUME_NONNULL_END
