#import <Cocoa/Cocoa.h>

@class AccountStore;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, DeskMode) {
    DeskModeBrowser = 0,
    DeskModeManagement = 1,
};

/// Implemented by the main window controller; child view controllers route every account action through it.
@protocol AccountCoordinator <NSObject>
@property (nonatomic, readonly) AccountStore *store;
@property (nonatomic, readonly, nullable) NSString *selectedAccountID;
@property (nonatomic, readonly) DeskMode mode;

- (void)selectAccountID:(nullable NSString *)identifier;
- (void)openAccountID:(NSString *)identifier;
- (void)managementSelectionDidChange:(NSArray<NSString *> *)identifiers;
- (void)populateMenu:(NSMenu *)menu forAccountIDs:(NSArray<NSString *> *)identifiers;
- (void)deleteAccountIDs:(NSArray<NSString *> *)identifiers;
- (void)clearLoginDataForAccountIDs:(NSArray<NSString *> *)identifiers;
- (void)promptGroupForAccountIDs:(NSArray<NSString *> *)identifiers;
- (void)exportAccountIDs:(nullable NSArray<NSString *> *)identifiers;
- (void)promptAuthorizationForAccountID:(NSString *)identifier;

- (IBAction)addAccount:(nullable id)sender;
- (IBAction)importAccounts:(nullable id)sender;
- (IBAction)exportAccounts:(nullable id)sender;
- (IBAction)syncSubscription:(nullable id)sender;
- (IBAction)showCurrentSession:(nullable id)sender;
- (IBAction)openAuthorizationLink:(nullable id)sender;
- (IBAction)showBrowser:(nullable id)sender;
- (IBAction)showManagement:(nullable id)sender;
@end

NS_ASSUME_NONNULL_END
