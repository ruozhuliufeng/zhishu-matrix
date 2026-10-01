#import <Cocoa/Cocoa.h>

@class Account;

NS_ASSUME_NONNULL_BEGIN

/// Month grid of renewals and expiries. Auto-renewing accounts repeat monthly from their renewal day.
@interface RenewalCalendarView : NSView
@property (nonatomic, copy) NSArray<Account *> *accounts;
@property (nonatomic, copy) NSArray<NSString *> *selectedIDs;
@property (nonatomic, copy, nullable) void (^selectAccount)(NSString *accountID, BOOL extendSelection);
@property (nonatomic, copy, nullable) void (^openAccount)(NSString *accountID);
@property (nonatomic, copy, nullable) NSMenu *_Nullable (^menuForAccount)(NSString *accountID);
- (void)showToday:(nullable id)sender;
@end

NS_ASSUME_NONNULL_END
