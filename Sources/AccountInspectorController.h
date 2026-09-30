#import <Cocoa/Cocoa.h>
#import "AccountCoordinator.h"

NS_ASSUME_NONNULL_BEGIN

/// Right-hand panel with the selected account's profile. Edits are saved as soon as a field is committed.
@interface AccountInspectorController : NSViewController
- (instancetype)initWithCoordinator:(id<AccountCoordinator>)coordinator;
- (void)showAccountID:(nullable NSString *)identifier selectionCount:(NSUInteger)count;
- (void)reloadAccount;
/// Ends any in-progress edit in the inspector so it is saved before the selection changes.
- (void)commitPendingEdits;
@end

NS_ASSUME_NONNULL_END
