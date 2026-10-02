#import <Cocoa/Cocoa.h>
#import "AccountCoordinator.h"

NS_ASSUME_NONNULL_BEGIN

/// Right-hand panel with the selected account's profile. Edits are saved as soon as a field is committed.
@interface AccountInspectorController : NSViewController
- (instancetype)initWithCoordinator:(id<AccountCoordinator>)coordinator;
- (void)showAccountID:(nullable NSString *)identifier selectionCount:(NSUInteger)count;
- (void)reloadAccount;
/// Opens the form for recording a payment of the shown account, dated `date` ("yyyy-MM-dd") or today,
/// with the expected amount filled in.
- (void)presentAddPaymentWithDate:(nullable NSString *)date;
/// Collapses or expands the sections as last chosen for the coordinator's current mode.
- (void)applyMode;
/// Ends any in-progress edit in the inspector so it is saved before the selection changes.
- (void)commitPendingEdits;
@end

NS_ASSUME_NONNULL_END
