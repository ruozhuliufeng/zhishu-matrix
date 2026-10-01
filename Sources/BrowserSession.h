#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

NSURL *BrowserHomeURL(void);

/// One account's ChatGPT page, backed by its own persistent WebKit data store.
@interface BrowserSession : NSObject <WKNavigationDelegate, WKUIDelegate>
@property (nonatomic, readonly) NSString *accountID;
@property (nonatomic, readonly) WKWebView *webView;
@property (nonatomic, readonly, nullable) NSError *lastError;
/// Loading, progress, title, URL or history changed.
@property (nonatomic, copy, nullable) void (^stateChanged)(BrowserSession *session);
/// A main-frame navigation finished.
@property (nonatomic, copy, nullable) void (^pageReady)(BrowserSession *session);
/// A download finished (error is nil) or failed.
@property (nonatomic, copy, nullable) void (^downloadEnded)(BrowserSession *session, NSURL *_Nullable file, NSError *_Nullable error);
/// The page navigated to a non-web scheme (e.g. a client's callback) and it was passed to macOS;
/// `opened` is NO when no app handles the scheme.
@property (nonatomic, copy, nullable) void (^externalURLOpened)(BrowserSession *session, NSURL *url, BOOL opened);
/// Asked before each main-frame http(s) navigation, including redirects; return NO to cancel it.
@property (nonatomic, copy, nullable) BOOL (^allowsNavigation)(BrowserSession *session, NSURL *url);

- (instancetype)initWithAccountID:(NSString *)accountID;
/// `dataStore` defaults to the account's persistent store; pass a loaded session's store to share it.
- (instancetype)initWithAccountID:(NSString *)accountID dataStore:(nullable WKWebsiteDataStore *)dataStore
    initialURL:(NSURL *)initialURL;
- (void)goHome;
- (void)retry;
- (void)invalidate;
@end

NS_ASSUME_NONNULL_END
