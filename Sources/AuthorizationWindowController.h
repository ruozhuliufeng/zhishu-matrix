#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

@class Account;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, AuthorizationState) {
    AuthorizationStateBrowsing = 0,
    /// The flow came back to a callback address on this Mac and it answered.
    AuthorizationStateCompleted,
    /// The callback address was captured and, as requested, not opened on this Mac.
    AuthorizationStateCaptured,
    /// The flow ended on a custom scheme that macOS passed to a client app.
    AuthorizationStateHandedOff,
    AuthorizationStateFailed,
};

/// Opens a client's authorization link in its own window, signed in as one account.
@interface AuthorizationWindowController : NSWindowController
@property (nonatomic, readonly) NSString *accountID;
@property (nonatomic, readonly) AuthorizationState state;
/// The localhost callback (with the authorization code) the flow redirected to, once known.
@property (nonatomic, readonly, nullable) NSURL *callbackURL;
@property (nonatomic, copy, nullable) void (^closed)(AuthorizationWindowController *controller);

/// With `captureCallback`, the localhost callback is recorded for copying but not opened on this Mac.
- (instancetype)initWithAccount:(Account *)account URL:(NSURL *)url dataStore:(nullable WKWebsiteDataStore *)dataStore
    captureCallback:(BOOL)captureCallback;
- (void)copyCallbackURL:(nullable id)sender;
- (void)closeAuthorization;
@end

NS_ASSUME_NONNULL_END
