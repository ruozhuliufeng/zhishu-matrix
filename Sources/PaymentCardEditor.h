#import <Cocoa/Cocoa.h>

@class AccountStore;

NS_ASSUME_NONNULL_BEGIN

/// Edits the name, expiry and note of the card ending in `last4` in a sheet on `window`, then commits the store.
void PaymentCardEdit(NSWindow *window, AccountStore *store, NSString *last4);

NS_ASSUME_NONNULL_END
