#import <Cocoa/Cocoa.h>
#import "AccountCoordinator.h"

@class Account, AccountUsageWindow;

NS_ASSUME_NONNULL_BEGIN

/// One usage window: title, bar, remaining percentage and reset countdown.
@interface DeskQuotaRow : NSView
- (void)showWindow:(nullable AccountUsageWindow *)window title:(NSString *)title;
@end

/// Card for one account in the management grid.
@interface AccountCardItem : NSCollectionViewItem
@property (nonatomic, weak, nullable) id<AccountCoordinator> coordinator;
/// The accounts a right-click or the "…" menu acts on (the selection when this card is part of it).
@property (nonatomic, copy, nullable) NSArray<NSString *> *_Nonnull (^menuAccountIDs)(NSString *accountID);
- (void)configureWithAccount:(Account *)account refreshing:(BOOL)refreshing now:(NSDate *)now;
@end

NS_ASSUME_NONNULL_END
