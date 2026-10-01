#import <Cocoa/Cocoa.h>
#import "AccountCoordinator.h"

@class ManagementScope;

NS_ASSUME_NONNULL_BEGIN

/// Overview of the accounts in the chosen smart list, group or tag: summary, cards / table / calendar and batch actions.
@interface ManagementController : NSViewController
@property (nonatomic, readonly) NSArray<NSString *> *selectedAccountIDs;
@property (nonatomic, strong, null_resettable) ManagementScope *scope;
/// The summary chips changed the scope.
@property (nonatomic, copy, nullable) void (^scopeChosen)(ManagementScope *scope);
- (instancetype)initWithCoordinator:(id<AccountCoordinator>)coordinator;
- (void)reloadAccounts;
- (void)reflectSelection;
- (void)focusSearch;
- (void)focusTable;
@end

NS_ASSUME_NONNULL_END
