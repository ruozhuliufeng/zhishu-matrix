#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// NSUserDefaults key for the authorization link used when an account has none of its own.
extern NSString *const DefaultAuthorizationURLDefaultsKey;

/// The http(s) link in `text`: the whole string when it is a link (line breaks from wrapped
/// terminal output are ignored), otherwise the first link found inside it.
NSURL *_Nullable AuthorizationURLFromText(NSString *_Nullable text);

/// Whether `url` points at this Mac (localhost, 127.x.x.x or ::1), where clients receive callbacks.
BOOL AuthorizationIsLoopbackURL(NSURL *_Nullable url);

/// scheme://host:port, used to tell a callback apart from the page that started the flow.
NSString *AuthorizationOrigin(NSURL *url);

NS_ASSUME_NONNULL_END
