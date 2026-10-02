#import "AuthorizationLink.h"

NSString *const DefaultAuthorizationURLDefaultsKey = @"defaultAuthorizationURL";
NSString *const CaptureAuthorizationCallbackDefaultsKey = @"captureAuthorizationCallback";
NSString *const AuthorizationDefaultAppNameDefaultsKey = @"authorizationDefaultAppName";

NSString *AuthorizationDefaultAppName(void) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:AuthorizationDefaultAppNameDefaultsKey];
    NSString *name = [value isKindOfClass:NSString.class] ? value : @"AI服务中心";
    return [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static BOOL IsWebURL(NSURL *url) {
    NSString *scheme = url.scheme.lowercaseString;
    return ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) && url.host.length > 0;
}

NSURL *AuthorizationURLFromText(NSString *text) {
    NSCharacterSet *whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    NSString *trimmed = [text ?: @"" stringByTrimmingCharactersInSet:whitespace];
    if (!trimmed.length) return nil;
    // Strict first: the lenient parser would percent-encode a stray line break into the link.
    NSURL *direct = [NSURL URLWithString:trimmed encodingInvalidCharacters:NO];
    if (IsWebURL(direct)) return direct;
    if ([trimmed rangeOfCharacterFromSet:NSCharacterSet.whitespaceCharacterSet].location == NSNotFound) {
        NSString *joined = [[trimmed componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]
            componentsJoinedByString:@""];
        NSURL *unwrapped = [NSURL URLWithString:joined encodingInvalidCharacters:NO] ?: [NSURL URLWithString:joined];
        if (IsWebURL(unwrapped)) return unwrapped;
    }
    NSDataDetector *detector = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink error:nil];
    __block NSURL *found = nil;
    [detector enumerateMatchesInString:trimmed options:0 range:NSMakeRange(0, trimmed.length)
        usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) {
            if (IsWebURL(result.URL)) {
                found = result.URL;
                *stop = YES;
            }
        }];
    return found;
}

BOOL AuthorizationIsLoopbackURL(NSURL *url) {
    NSString *host = url.host.lowercaseString;
    if (!host.length) return NO;
    return [host isEqualToString:@"localhost"] || [host hasSuffix:@".localhost"] ||
        [host isEqualToString:@"::1"] || [host isEqualToString:@"[::1]"] || [host hasPrefix:@"127."];
}

NSDictionary<NSString *, NSString *> *AuthorizationRequestFromURL(NSURL *url) {
    NSURLComponents *components = url ? [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO] : nil;
    NSMutableDictionary *request = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *item in components.queryItems) {
        if (!item.value.length) continue;
        if ([item.name isEqualToString:@"client_id"]) request[@"clientID"] = item.value;
        else if ([item.name isEqualToString:@"redirect_uri"]) request[@"redirect"] = item.value;
        else if ([item.name isEqualToString:@"scope"]) request[@"scope"] = item.value;
    }
    return request[@"clientID"] || request[@"redirect"] ? request : nil;
}

BOOL AuthorizationURLMatchesRedirect(NSURL *url, NSString *redirect) {
    NSURL *target = redirect.length ? [NSURL URLWithString:redirect] : nil;
    if (!url || !target.scheme.length) return NO;
    if (![url.scheme.lowercaseString isEqualToString:target.scheme.lowercaseString]) return NO;
    if (!target.host.length) return YES;
    NSString *path = url.path.length ? url.path : @"/", *targetPath = target.path.length ? target.path : @"/";
    return [AuthorizationOrigin(url) isEqualToString:AuthorizationOrigin(target)] && [path isEqualToString:targetPath];
}

BOOL AuthorizationCallbackSucceeded(NSURL *url) {
    NSURLComponents *components = url ? [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO] : nil;
    BOOL code = NO, error = NO;
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:@"code"] && item.value.length) code = YES;
        if ([item.name isEqualToString:@"error"]) error = YES;
    }
    // Some clients put the result in the fragment instead.
    NSString *fragment = components.fragment ?: @"";
    if ([fragment containsString:@"code="] || [fragment containsString:@"access_token="]) code = YES;
    if ([fragment containsString:@"error="]) error = YES;
    return code && !error;
}

NSString *AuthorizationAppName(NSString *redirect) {
    NSURL *url = redirect.length ? [NSURL URLWithString:redirect] : nil;
    NSString *scheme = url.scheme.lowercaseString;
    if (!scheme.length) return @"未知应用";
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return url.scheme;
    if (AuthorizationIsLoopbackURL(url))
        return [NSString stringWithFormat:@"本机应用（%@%@）", url.host, url.port ? [NSString stringWithFormat:@":%@", url.port] : @""];
    NSString *host = url.host.lowercaseString ?: @"";
    return [host hasPrefix:@"www."] ? [host substringFromIndex:4] : host;
}

NSString *AuthorizationOrigin(NSURL *url) {
    NSString *scheme = url.scheme.lowercaseString ?: @"";
    NSNumber *port = url.port ?: ([scheme isEqualToString:@"https"] ? @443 : ([scheme isEqualToString:@"http"] ? @80 : @0));
    return [NSString stringWithFormat:@"%@://%@:%@", scheme, url.host.lowercaseString ?: @"", port];
}
