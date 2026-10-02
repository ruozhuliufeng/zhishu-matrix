#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// NSUserDefaults key for the authorization link used when an account has none of its own.
extern NSString *const DefaultAuthorizationURLDefaultsKey;
/// NSUserDefaults key remembering whether the last authorization only captured the callback address.
extern NSString *const CaptureAuthorizationCallbackDefaultsKey;
/// NSUserDefaults key: name given to newly recorded authorizations ("" names them after the redirect address).
extern NSString *const AuthorizationDefaultAppNameDefaultsKey;
/// The saved default name, "AI服务中心" unless changed; empty means "name after the redirect address".
NSString *AuthorizationDefaultAppName(void);

/// The http(s) link in `text`: the whole string when it is a link (line breaks from wrapped
/// terminal output are ignored), otherwise the first link found inside it.
NSURL *_Nullable AuthorizationURLFromText(NSString *_Nullable text);

/// Whether `url` points at this Mac (localhost, 127.x.x.x or ::1), where clients receive callbacks.
BOOL AuthorizationIsLoopbackURL(NSURL *_Nullable url);

/// scheme://host:port, used to tell a callback apart from the page that started the flow.
NSString *AuthorizationOrigin(NSURL *url);

/// {@"clientID", @"redirect", @"scope"} from an OAuth authorize link (keys only when present);
/// nil when the link names neither a client nor a redirect address.
NSDictionary<NSString *, NSString *> *_Nullable AuthorizationRequestFromURL(NSURL *_Nullable url);
/// Whether `url` is the redirect address: same scheme, host, port and path.
BOOL AuthorizationURLMatchesRedirect(NSURL *_Nullable url, NSString *_Nullable redirect);
/// Whether a callback carries an authorization code rather than an error such as access_denied.
BOOL AuthorizationCallbackSucceeded(NSURL *_Nullable url);
/// A readable default name for the app behind a redirect address: "app.example.com", "cursor",
/// "本机应用（localhost:1455）".
NSString *AuthorizationAppName(NSString *_Nullable redirect);

NS_ASSUME_NONNULL_END
