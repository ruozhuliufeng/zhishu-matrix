#import <Cocoa/Cocoa.h>
#import "AccountCoordinator.h"

NS_ASSUME_NONNULL_BEGIN

@interface AccountSidebarController : NSViewController
- (instancetype)initWithCoordinator:(id<AccountCoordinator>)coordinator;
- (void)reloadAccounts;
- (void)reflectSelection;
- (void)focusSearch;
/// Account IDs in the order the sidebar shows them.
- (NSArray<NSString *> *)visibleAccountIDs;
@end

NS_ASSUME_NONNULL_END
