#import <Cocoa/Cocoa.h>

@class Account;

NS_ASSUME_NONNULL_BEGIN

/// Actual spend from payment records: a year's months stacked by supplier, totals by supplier, payment source and
/// account, and one month's expected charges checked against what was recorded.
@interface ExpenseReportView : NSView
@property (nonatomic, copy) NSArray<Account *> *accounts;
/// Suppliers in the order that fixes their colors.
@property (nonatomic, copy) NSArray<NSString *> *supplierOrder;
@property (nonatomic, copy, nullable) void (^recordPayment)(NSString *accountID, NSString *date);
@property (nonatomic, copy, nullable) void (^selectAccount)(NSString *accountID);
- (void)reload;
@end

NS_ASSUME_NONNULL_END
