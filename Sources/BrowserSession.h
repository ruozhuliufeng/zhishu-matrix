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

- (instancetype)initWithAccountID:(NSString *)accountID;
- (void)goHome;
- (void)retry;
- (void)invalidate;
@end

NS_ASSUME_NONNULL_END
