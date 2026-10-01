#import <Cocoa/Cocoa.h>
#import "AccountCoordinator.h"

@class AuthorizationWindowController;

NS_ASSUME_NONNULL_BEGIN

@interface MainWindowController : NSWindowController <AccountCoordinator>
- (instancetype)initWithStore:(AccountStore *)store;
- (void)showError:(NSString *)title detail:(nullable NSString *)detail;
- (void)prepareForTermination;
/// Opens `url` in a new authorization window signed in as the account. With `captureCallback`, the
/// localhost callback is only shown for copying instead of being opened on this Mac.
- (nullable AuthorizationWindowController *)openAuthorizationURL:(NSURL *)url forAccountID:(NSString *)identifier
    captureCallback:(BOOL)captureCallback;

- (IBAction)revealDataFile:(nullable id)sender;
- (IBAction)focusSearch:(nullable id)sender;
- (IBAction)toggleSidebar:(nullable id)sender;
- (IBAction)toggleInspector:(nullable id)sender;
- (IBAction)releaseBackgroundPages:(nullable id)sender;
- (IBAction)selectPreviousAccount:(nullable id)sender;
- (IBAction)selectNextAccount:(nullable id)sender;
- (IBAction)goBack:(nullable id)sender;
- (IBAction)goForward:(nullable id)sender;
- (IBAction)reloadPage:(nullable id)sender;
- (IBAction)goHome:(nullable id)sender;
- (IBAction)renameSelectedAccount:(nullable id)sender;
- (IBAction)moveSelectedToGroup:(nullable id)sender;
- (IBAction)clearSelectedLoginData:(nullable id)sender;
- (IBAction)deleteSelectedAccounts:(nullable id)sender;
@end

NS_ASSUME_NONNULL_END
