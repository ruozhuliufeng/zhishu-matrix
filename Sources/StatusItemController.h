#import <Cocoa/Cocoa.h>

@class AccountStore;

NS_ASSUME_NONNULL_BEGIN

extern NSString *const StatusItemEnabledDefaultsKey;     // BOOL, default YES
extern NSString *const KeepRunningInMenuBarDefaultsKey;  // BOOL, default YES: closing the window keeps the app in the menu bar
extern NSNotificationName const StatusItemSettingsDidChangeNotification;

typedef NS_ENUM(NSInteger, StatusItemCommand) {
    StatusItemCommandShowWindow,
    StatusItemCommandShowManagement,
    StatusItemCommandRefreshAll,
    StatusItemCommandSettings,
    StatusItemCommandLock,
    StatusItemCommandUnlock,
};

/// Menu bar item: accounts that need attention, charges and expiries in the next 30 days, spend in CNY and quick actions.
@interface StatusItemController : NSObject
@property (nonatomic, copy, nullable) void (^openAccount)(NSString *identifier);
@property (nonatomic, copy, nullable) void (^perform)(StatusItemCommand command);
@property (nonatomic, copy, nullable) BOOL (^isRefreshing)(void);
@property (nonatomic, copy, nullable) BOOL (^isLocked)(void);
@property (nonatomic, copy, nullable) BOOL (^canLock)(void);
- (instancetype)initWithStore:(AccountStore *)store;
/// Shows or removes the item according to the settings.
- (void)applySettings;
/// Updates the icon after accounts changed.
- (void)update;
@end

NS_ASSUME_NONNULL_END
