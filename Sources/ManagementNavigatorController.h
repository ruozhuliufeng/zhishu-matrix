#import <Cocoa/Cocoa.h>
#import "AccountCoordinator.h"

@class ManagementScope;

NS_ASSUME_NONNULL_BEGIN

/// Sidebar of the management view: smart lists, groups and tags, each with its account count.
@interface ManagementNavigatorController : NSViewController
@property (nonatomic, strong) ManagementScope *scope;
@property (nonatomic, copy, nullable) void (^scopeChosen)(ManagementScope *scope);
- (instancetype)initWithCoordinator:(id<AccountCoordinator>)coordinator;
- (void)reloadAccounts;
@end

NS_ASSUME_NONNULL_END
