#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

@class Account;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, AuthorizationState) {
    AuthorizationStateBrowsing = 0,
    /// The flow came back to a callback address on this Mac.
    AuthorizationStateCompleted,
    /// The flow ended on a custom scheme that macOS passed to a client app.
    AuthorizationStateHandedOff,
    AuthorizationStateFailed,
};

/// Opens a client's authorization link in its own window, signed in as one account.
@interface AuthorizationWindowController : NSWindowController
@property (nonatomic, readonly) NSString *accountID;
@property (nonatomic, readonly) AuthorizationState state;
@property (nonatomic, copy, nullable) void (^closed)(AuthorizationWindowController *controller);

- (instancetype)initWithAccount:(Account *)account URL:(NSURL *)url dataStore:(nullable WKWebsiteDataStore *)dataStore;
- (void)closeAuthorization;
@end

NS_ASSUME_NONNULL_END
