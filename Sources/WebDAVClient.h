#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A backup file found in the WebDAV folder.
@interface WebDAVFile : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong, nullable) NSDate *modifiedAt;
@property (nonatomic) long long size;
@end

/// Minimal WebDAV client for one folder (Nextcloud, Synology, 坚果云…), authenticated with Basic or Digest.
@interface WebDAVClient : NSObject
@property (nonatomic, readonly) NSURL *folderURL;
/// `server` is the WebDAV root (e.g. https://dav.jianguoyun.com/dav/), `folder` a path below it.
- (nullable instancetype)initWithServer:(NSString *)server folder:(nullable NSString *)folder
    username:(NSString *)username password:(NSString *)password;
/// Checks the credentials and creates the folder when it does not exist yet.
- (void)prepareFolderWithCompletion:(void (^)(NSString *_Nullable failure))completion;
- (void)uploadData:(NSData *)data name:(NSString *)name completion:(void (^)(NSString *_Nullable failure))completion;
/// Files in the folder whose names start with `prefix`, newest name first.
- (void)listFilesWithPrefix:(NSString *)prefix completion:(void (^)(NSArray<WebDAVFile *> *_Nullable files, NSString *_Nullable failure))completion;
- (void)downloadName:(NSString *)name completion:(void (^)(NSData *_Nullable data, NSString *_Nullable failure))completion;
- (void)deleteName:(NSString *)name completion:(void (^)(NSString *_Nullable failure))completion;

/// Parses a PROPFIND multistatus body into the non-folder entries directly inside `folderPath`.
+ (NSArray<WebDAVFile *> *)filesFromMultistatus:(NSData *)data folderPath:(NSString *)folderPath;
/// Explains an HTTP status from a WebDAV server in a sentence.
+ (NSString *)messageForStatus:(NSInteger)status;
@end

NS_ASSUME_NONNULL_END
