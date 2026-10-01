#import <Foundation/Foundation.h>

@class AccountStore, WebDAVClient;

NS_ASSUME_NONNULL_BEGIN

extern NSString *const AutoBackupDefaultsKey;           // BOOL, default YES
extern NSString *const WebDAVEnabledDefaultsKey;        // BOOL, upload automatic backups
extern NSString *const WebDAVServerDefaultsKey;
extern NSString *const WebDAVFolderDefaultsKey;         // default "ZhishuMatrix"
extern NSString *const WebDAVUsernameDefaultsKey;
extern NSString *const WebDAVKeychainService;
/// Posted when a backup starts or finishes, or the backup settings change.
extern NSNotificationName const BackupStateDidChangeNotification;
/// Backup files are named "<prefix>YYYYMMDD-HHmmss.json" locally and on WebDAV.
extern NSString *const BackupFilePrefix;

/// Keeps dated copies of the account list in the data folder and, when configured, on a WebDAV server.
/// Backups hold the same profile data as an export: no passwords, sign-ins or tokens.
@interface BackupManager : NSObject
@property (nonatomic, readonly) NSURL *directory;
@property (nonatomic, readonly, nullable) NSDate *lastLocalBackup;
@property (nonatomic, readonly, nullable) NSDate *lastRemoteBackup;
@property (nonatomic, readonly, nullable) NSString *lastRemoteError;
@property (nonatomic, readonly) BOOL isUploading;
/// How many dated files to keep in each place.
@property (nonatomic) NSUInteger localRetention;
@property (nonatomic) NSUInteger remoteRetention;
/// Minimum time between automatic backups of a changed list.
@property (nonatomic) NSTimeInterval automaticInterval;

- (instancetype)initWithStore:(AccountStore *)store directory:(NSURL *)directory;
/// Call when the account list changed; writes an automatic backup after a short pause when one is due.
- (void)scheduleAutomaticBackup;
/// Writes a backup now (and uploads it when WebDAV is enabled). Returns the local file.
- (nullable NSURL *)backupNow:(NSError **)error;
- (NSArray<NSURL *> *)localBackups;
/// A client for the saved WebDAV settings, or nil when they are incomplete.
- (nullable WebDAVClient *)webDAVClient;
- (void)uploadData:(NSData *)data completion:(nullable void (^)(NSString *_Nullable failure))completion;
@end

NS_ASSUME_NONNULL_END
