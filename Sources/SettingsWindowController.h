#import <Cocoa/Cocoa.h>

@class AccountAlerts, AccountStore, AppLock, BackupManager;

NS_ASSUME_NONNULL_BEGIN

extern NSString *const SettingsPaneGeneral;
extern NSString *const SettingsPaneUsage;
extern NSString *const SettingsPaneSecurity;
extern NSString *const SettingsPaneBackup;
extern NSString *const SettingsPaneNetwork;
extern NSString *const SettingsPaneCost;

@interface SettingsWindowController : NSWindowController
- (instancetype)initWithStore:(AccountStore *)store backup:(BackupManager *)backup alerts:(AccountAlerts *)alerts lock:(AppLock *)lock;
- (void)showPane:(NSString *)identifier;
/// Ends any in-progress edit so it is saved.
- (void)commitEditing;
@end

NS_ASSUME_NONNULL_END
