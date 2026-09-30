#import <Cocoa/Cocoa.h>
#import "AccountCoordinator.h"

NS_ASSUME_NONNULL_BEGIN

/// Overview of every account: statistics, filters, a sortable table and batch actions.
@interface ManagementController : NSViewController
@property (nonatomic, readonly) NSArray<NSString *> *selectedAccountIDs;
- (instancetype)initWithCoordinator:(id<AccountCoordinator>)coordinator;
- (void)reloadAccounts;
- (void)reflectSelection;
- (void)focusSearch;
- (void)focusTable;
@end

NS_ASSUME_NONNULL_END
