#import "WebDAVClient.h"

@implementation WebDAVFile
@end

#pragma mark - Multistatus parsing

@interface WebDAVMultistatusParser : NSObject <NSXMLParserDelegate>
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *responses;
@end

@implementation WebDAVMultistatusParser {
    NSMutableDictionary *_current;
    NSMutableString *_text;
}

- (instancetype)init {
    if ((self = [super init])) _responses = [NSMutableArray array];
    return self;
}

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)name namespaceURI:(NSString *)namespaceURI
    qualifiedName:(NSString *)qualifiedName attributes:(NSDictionary *)attributes {
    NSString *local = name.lowercaseString;
    if ([local isEqualToString:@"response"]) _current = [NSMutableDictionary dictionary];
    else if ([local isEqualToString:@"collection"]) _current[@"collection"] = @YES;
    _text = [NSMutableString string];
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string { [_text appendString:string]; }

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)name namespaceURI:(NSString *)namespaceURI
    qualifiedName:(NSString *)qualifiedName {
    NSString *local = name.lowercaseString;
    NSString *text = [_text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([local isEqualToString:@"response"]) {
        if (_current[@"href"]) [self.responses addObject:_current];
        _current = nil;
    } else if (_current && text.length && ([local isEqualToString:@"href"] || [local isEqualToString:@"getlastmodified"] ||
                                           [local isEqualToString:@"getcontentlength"])) {
        if (!_current[local]) _current[local] = text;
    }
    _text = [NSMutableString string];
}
@end

static NSDate *HTTPDate(NSString *text) {
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
        formatter.dateFormat = @"EEE, dd MMM yyyy HH:mm:ss zzz";
    });
    return text.length ? [formatter dateFromString:text] : nil;
}

static NSString *DirectoryPath(NSString *path) {
    NSString *decoded = path.stringByRemovingPercentEncoding ?: path;
    return [decoded hasSuffix:@"/"] ? decoded : [decoded stringByAppendingString:@"/"];
}

#pragma mark - Client

/// Answers Basic and Digest challenges once. Kept apart from the client because a session retains its
/// delegate until it is invalidated, which happens when the client goes away.
@interface WebDAVCredentialDelegate : NSObject <NSURLSessionTaskDelegate>
@property (nonatomic, copy) NSString *username;
@property (nonatomic, copy) NSString *password;
@end

@implementation WebDAVCredentialDelegate
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
    completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    NSString *method = challenge.protectionSpace.authenticationMethod;
    BOOL password = [method isEqualToString:NSURLAuthenticationMethodHTTPBasic] || [method isEqualToString:NSURLAuthenticationMethodHTTPDigest];
    if (password && challenge.previousFailureCount == 0) {
        completionHandler(NSURLSessionAuthChallengeUseCredential,
            [NSURLCredential credentialWithUser:self.username password:self.password persistence:NSURLCredentialPersistenceNone]);
        return;
    }
    completionHandler(password ? NSURLSessionAuthChallengeRejectProtectionSpace : NSURLSessionAuthChallengePerformDefaultHandling, nil);
}
@end

@interface WebDAVClient ()
@property (nonatomic, copy) NSString *username;
@property (nonatomic, copy) NSString *password;
@property (nonatomic, strong) NSURLSession *session;
@end

@implementation WebDAVClient

- (instancetype)initWithServer:(NSString *)server folder:(NSString *)folder username:(NSString *)username password:(NSString *)password {
    NSString *base = [server stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSURLComponents *components = [NSURLComponents componentsWithString:base];
    NSString *scheme = components.scheme.lowercaseString;
    if (!components.host.length || !([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"])) return nil;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *path in @[components.path ?: @"", folder ?: @""])
        for (NSString *part in [path componentsSeparatedByString:@"/"]) {
            NSString *trimmed = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (trimmed.length && ![trimmed isEqualToString:@"."] && ![trimmed isEqualToString:@".."]) [parts addObject:trimmed];
        }
    components.path = parts.count ? [NSString stringWithFormat:@"/%@/", [parts componentsJoinedByString:@"/"]] : @"/";
    components.query = nil;
    components.fragment = nil;
    if (!components.URL) return nil;
    if ((self = [super init])) {
        _folderURL = components.URL;
        _username = [username copy] ?: @"";
        _password = [password copy] ?: @"";
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.timeoutIntervalForRequest = 30;
        configuration.URLCredentialStorage = nil;
        configuration.HTTPCookieStorage = nil;
        WebDAVCredentialDelegate *delegate = [WebDAVCredentialDelegate new];
        delegate.username = _username;
        delegate.password = _password;
        _session = [NSURLSession sessionWithConfiguration:configuration delegate:delegate delegateQueue:NSOperationQueue.mainQueue];
    }
    return self;
}

- (void)dealloc { [_session finishTasksAndInvalidate]; }

+ (NSString *)messageForStatus:(NSInteger)status {
    switch (status) {
        case 401: return @"用户名或密码错误（HTTP 401）。坚果云等服务需要使用“应用密码”。";
        case 403: return @"服务器拒绝访问此目录（HTTP 403）";
        case 404: return @"服务器上找不到此地址（HTTP 404），请检查服务器地址";
        case 405: return @"服务器不支持此操作（HTTP 405），请确认填写的是 WebDAV 地址";
        case 409: return @"上级目录不存在（HTTP 409）";
        case 423: return @"文件被锁定（HTTP 423），请稍后重试";
        case 507: return @"WebDAV 空间不足（HTTP 507）";
        default:
            if (status >= 500) return [NSString stringWithFormat:@"WebDAV 服务器出错（HTTP %ld）", (long)status];
            return [NSString stringWithFormat:@"WebDAV 请求失败（HTTP %ld）", (long)status];
    }
}

- (NSURL *)URLForName:(NSString *)name {
    NSString *escaped = [name stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
    return [NSURL URLWithString:escaped relativeToURL:self.folderURL].absoluteURL;
}

- (NSMutableURLRequest *)requestWithMethod:(NSString *)method URL:(NSURL *)url {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
        timeoutInterval:30];
    request.HTTPMethod = method;
    // Sent up front so servers that only accept Basic answer on the first round trip.
    NSData *pair = [[NSString stringWithFormat:@"%@:%@", self.username, self.password] dataUsingEncoding:NSUTF8StringEncoding];
    [request setValue:[@"Basic " stringByAppendingString:[pair base64EncodedStringWithOptions:0]] forHTTPHeaderField:@"Authorization"];
    return request;
}

- (void)send:(NSURLRequest *)request body:(NSData *)body
    completion:(void (^)(NSInteger status, NSData *data, NSString *failure))completion {
    void (^handler)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSString *failure = error ? (error.localizedDescription ?: @"无法连接 WebDAV 服务器") : nil;
        if (error.code == NSURLErrorAppTransportSecurityRequiresSecureConnection)
            failure = @"系统阻止了不加密的 HTTP 连接，请改用 HTTPS 地址";
        else if (error.code == NSURLErrorTimedOut) failure = @"连接 WebDAV 服务器超时，请检查地址、端口和网络";
        else if (error.code == NSURLErrorCannotConnectToHost) failure = @"无法连接到 WebDAV 服务器，请检查地址和端口";
        completion(status, data, failure);
    };
    NSURLSessionTask *task = body ? [self.session uploadTaskWithRequest:request fromData:body completionHandler:handler]
                                  : [self.session dataTaskWithRequest:request completionHandler:handler];
    [task resume];
}

- (NSData *)propfindBody {
    return [@"<?xml version=\"1.0\" encoding=\"utf-8\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/>"
             "<d:getlastmodified/><d:getcontentlength/></d:prop></d:propfind>" dataUsingEncoding:NSUTF8StringEncoding];
}

- (void)propfind:(NSURL *)url depth:(NSString *)depth completion:(void (^)(NSInteger status, NSData *data, NSString *failure))completion {
    NSMutableURLRequest *request = [self requestWithMethod:@"PROPFIND" URL:url];
    [request setValue:depth forHTTPHeaderField:@"Depth"];
    [request setValue:@"application/xml; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = [self propfindBody];
    [self send:request body:nil completion:completion];
}

- (void)createCollection:(NSURL *)url depth:(NSUInteger)depth completion:(void (^)(NSString *failure))completion {
    __weak typeof(self) weakSelf = self;
    [self send:[self requestWithMethod:@"MKCOL" URL:url] body:nil completion:^(NSInteger status, NSData *data, NSString *failure) {
        if (failure) { completion(failure); return; }
        // 405: it already exists.
        if ((status >= 200 && status < 300) || status == 405) { completion(nil); return; }
        NSURL *parent = url.URLByDeletingLastPathComponent;
        if (status == 409 && depth < 8 && parent.path.length > 1 && ![parent isEqual:url]) {
            [weakSelf createCollection:parent depth:depth + 1 completion:^(NSString *parentFailure) {
                if (parentFailure) { completion(parentFailure); return; }
                [weakSelf createCollection:url depth:depth + 1 completion:completion];
            }];
            return;
        }
        completion([WebDAVClient messageForStatus:status]);
    }];
}

- (void)prepareFolderWithCompletion:(void (^)(NSString *))completion {
    __weak typeof(self) weakSelf = self;
    [self propfind:self.folderURL depth:@"0" completion:^(NSInteger status, NSData *data, NSString *failure) {
        if (failure) { completion(failure); return; }
        if (status == 207 || (status >= 200 && status < 300)) { completion(nil); return; }
        if (status == 404) { [weakSelf createCollection:weakSelf.folderURL depth:0 completion:completion]; return; }
        completion([WebDAVClient messageForStatus:status]);
    }];
}

- (void)uploadData:(NSData *)data name:(NSString *)name completion:(void (^)(NSString *))completion {
    NSMutableURLRequest *request = [self requestWithMethod:@"PUT" URL:[self URLForName:name]];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [self send:request body:data completion:^(NSInteger status, NSData *reply, NSString *failure) {
        if (failure) completion(failure);
        else completion(status >= 200 && status < 300 ? nil : [WebDAVClient messageForStatus:status]);
    }];
}

- (void)listFilesWithPrefix:(NSString *)prefix completion:(void (^)(NSArray<WebDAVFile *> *, NSString *))completion {
    NSString *folderPath = self.folderURL.path;
    [self propfind:self.folderURL depth:@"1" completion:^(NSInteger status, NSData *data, NSString *failure) {
        if (failure) { completion(nil, failure); return; }
        if (status != 207) { completion(nil, [WebDAVClient messageForStatus:status]); return; }
        NSMutableArray<WebDAVFile *> *files = [NSMutableArray array];
        for (WebDAVFile *file in [WebDAVClient filesFromMultistatus:data folderPath:folderPath])
            if ([file.name hasPrefix:prefix]) [files addObject:file];
        [files sortUsingComparator:^NSComparisonResult(WebDAVFile *a, WebDAVFile *b) { return [b.name compare:a.name]; }];
        completion(files, nil);
    }];
}

- (void)downloadName:(NSString *)name completion:(void (^)(NSData *, NSString *))completion {
    [self send:[self requestWithMethod:@"GET" URL:[self URLForName:name]] body:nil
        completion:^(NSInteger status, NSData *data, NSString *failure) {
            if (failure) completion(nil, failure);
            else if (status >= 200 && status < 300) completion(data ?: [NSData data], nil);
            else completion(nil, [WebDAVClient messageForStatus:status]);
        }];
}

- (void)deleteName:(NSString *)name completion:(void (^)(NSString *))completion {
    [self send:[self requestWithMethod:@"DELETE" URL:[self URLForName:name]] body:nil
        completion:^(NSInteger status, NSData *data, NSString *failure) {
            if (failure) completion(failure);
            else completion((status >= 200 && status < 300) || status == 404 ? nil : [WebDAVClient messageForStatus:status]);
        }];
}

+ (NSArray<WebDAVFile *> *)filesFromMultistatus:(NSData *)data folderPath:(NSString *)folderPath {
    if (!data.length) return @[];
    WebDAVMultistatusParser *delegate = [WebDAVMultistatusParser new];
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
    parser.shouldProcessNamespaces = YES;
    parser.shouldResolveExternalEntities = NO;
    parser.delegate = delegate;
    if (![parser parse]) return @[];
    NSString *folder = DirectoryPath(folderPath);
    NSMutableArray<WebDAVFile *> *files = [NSMutableArray array];
    for (NSDictionary *response in delegate.responses) {
        if ([response[@"collection"] boolValue]) continue;
        NSString *href = response[@"href"];
        NSURL *url = [NSURL URLWithString:href];
        NSString *path = (url.path.length ? url.path : href.stringByRemovingPercentEncoding) ?: href;
        NSString *parent = DirectoryPath(path.stringByDeletingLastPathComponent);
        NSString *name = path.lastPathComponent;
        if (!name.length || ![parent isEqualToString:folder]) continue;
        WebDAVFile *file = [WebDAVFile new];
        file.name = name;
        file.modifiedAt = HTTPDate(response[@"getlastmodified"]);
        file.size = [response[@"getcontentlength"] longLongValue];
        [files addObject:file];
    }
    return files;
}
@end
