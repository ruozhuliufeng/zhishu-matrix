#import "AuthorizationLink.h"

NSString *const DefaultAuthorizationURLDefaultsKey = @"defaultAuthorizationURL";
NSString *const CaptureAuthorizationCallbackDefaultsKey = @"captureAuthorizationCallback";

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

NSString *AuthorizationOrigin(NSURL *url) {
    NSString *scheme = url.scheme.lowercaseString ?: @"";
    NSNumber *port = url.port ?: ([scheme isEqualToString:@"https"] ? @443 : ([scheme isEqualToString:@"http"] ? @80 : @0));
    return [NSString stringWithFormat:@"%@://%@:%@", scheme, url.host.lowercaseString ?: @"", port];
}
