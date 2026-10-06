#import "BackupManager.h"
#import "Account.h"
#import "BackupCrypto.h"
#import "Keychain.h"
#import "WebDAVClient.h"

NSString *const AutoBackupDefaultsKey = @"autoBackup";
NSString *const WebDAVEnabledDefaultsKey = @"webdavEnabled";
NSString *const WebDAVServerDefaultsKey = @"webdavServer";
NSString *const WebDAVFolderDefaultsKey = @"webdavFolder";
NSString *const WebDAVUsernameDefaultsKey = @"webdavUsername";
NSString *const WebDAVKeychainService = @"local.zhishu.webdav";
NSNotificationName const BackupStateDidChangeNotification = @"BackupStateDidChangeNotification";
NSString *const BackupFilePrefix = @"zhishu-matrix-";
NSString *const BackupEncryptionDefaultsKey = @"backupEncryption";

static NSString *const EncryptionKeychainService = @"local.zhishu.backup-encryption";
static NSString *const EncryptionKeychainAccount = @"backup";

NSString *BackupEncryptionPassword(void) { return KeychainPassword(EncryptionKeychainService, EncryptionKeychainAccount); }

BOOL BackupSetEncryptionPassword(NSString *password) {
    return KeychainSetPassword(password, EncryptionKeychainService, EncryptionKeychainAccount);
}

BOOL BackupEncryptionActive(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:BackupEncryptionDefaultsKey] && BackupEncryptionPassword().length > 0;
}

static NSString *const LastRemoteBackupDefaultsKey = @"webdavLastBackup";

static NSDateFormatter *NameFormatter(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyyMMdd-HHmmss";
    });
    return formatter;
}

/// The accounts and card details of an export payload, ignoring when it was exported.
static NSData *AccountsFingerprint(NSData *payload) {
    NSDictionary *json = payload ? [NSJSONSerialization JSONObjectWithData:payload options:0 error:nil] : nil;
    id accounts = [json isKindOfClass:NSDictionary.class] ? json[@"accounts"] : nil;
    if (![accounts isKindOfClass:NSArray.class]) return nil;
    return [NSJSONSerialization dataWithJSONObject:@{@"accounts": accounts, @"cards": json[@"cards"] ?: @[]}
        options:NSJSONWritingSortedKeys error:nil];
}

@implementation BackupManager {
    AccountStore *_store;
    NSData *_lastFingerprint;
    BOOL _pending;
}

- (instancetype)initWithStore:(AccountStore *)store directory:(NSURL *)directory {
    if ((self = [super init])) {
        _store = store;
        _directory = directory;
        _localRetention = 30;
        _remoteRetention = 30;
        _automaticInterval = 3600;
        [NSUserDefaults.standardUserDefaults registerDefaults:@{AutoBackupDefaultsKey: @YES, WebDAVFolderDefaultsKey: @"ZhishuMatrix"}];
        NSURL *latest = self.localBackups.firstObject;
        if (latest) _lastFingerprint = AccountsFingerprint([NSData dataWithContentsOfURL:latest]);
    }
    return self;
}

- (NSArray<NSURL *> *)localBackups {
    NSArray<NSURL *> *items = [NSFileManager.defaultManager contentsOfDirectoryAtURL:self.directory
        includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[];
    NSMutableArray<NSURL *> *backups = [NSMutableArray array];
    for (NSURL *item in items)
        if ([item.lastPathComponent hasPrefix:BackupFilePrefix] && [item.pathExtension isEqualToString:@"json"]) [backups addObject:item];
    [backups sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        return [b.lastPathComponent compare:a.lastPathComponent];
    }];
    return backups;
}

- (NSDate *)dateOfBackupNamed:(NSString *)name {
    NSString *stamp = [[name stringByDeletingPathExtension] substringFromIndex:MIN(name.length, BackupFilePrefix.length)];
    return [NameFormatter() dateFromString:stamp];
}

- (NSDate *)lastLocalBackup {
    NSURL *latest = self.localBackups.firstObject;
    return latest ? [self dateOfBackupNamed:latest.lastPathComponent] : nil;
}

- (NSDate *)lastRemoteBackup { return [NSUserDefaults.standardUserDefaults objectForKey:LastRemoteBackupDefaultsKey]; }

- (void)notify {
    [NSNotificationCenter.defaultCenter postNotificationName:BackupStateDidChangeNotification object:self];
}

#pragma mark - Local

- (void)scheduleAutomaticBackup {
    if (_pending || ![NSUserDefaults.standardUserDefaults boolForKey:AutoBackupDefaultsKey]) return;
    _pending = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf runAutomaticBackup];
    });
}

- (void)runAutomaticBackup {
    _pending = NO;
    if (!_store.accounts.count) return;
    NSDate *last = self.lastLocalBackup;
    if (!_lastFingerprint && self.localBackups.firstObject) {
        // The newest backup may be encrypted; opening it once avoids repeating an unchanged backup after a relaunch.
        NSData *latest = [NSData dataWithContentsOfURL:self.localBackups.firstObject];
        NSString *password = BackupDataIsEncrypted(latest) ? BackupEncryptionPassword() : nil;
        if (password) _lastFingerprint = AccountsFingerprint(BackupDecrypt(latest, password, nil));
    }
    if (last && -last.timeIntervalSinceNow < self.automaticInterval) {
        // Too soon after the last one; try again when the interval has passed.
        _pending = YES;
        __weak typeof(self) weakSelf = self;
        NSTimeInterval wait = self.automaticInterval + last.timeIntervalSinceNow + 1;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf runAutomaticBackup];
        });
        return;
    }
    NSData *payload = [_store exportDataForAccountIDs:nil error:nil];
    NSData *fingerprint = AccountsFingerprint(payload);
    if (!payload || [fingerprint isEqualToData:_lastFingerprint]) return;
    NSError *error = nil;
    if (![self writeBackup:payload error:&error]) {
        _lastLocalError = [error.localizedDescription copy];
        [self notify];
    }
}

/// The payload as it is stored: encrypted when encryption is on. Encryption that is on but has lost its
/// password fails rather than falling back to plain text.
- (NSData *)sealedPayload:(NSData *)payload error:(NSError **)error {
    if (![NSUserDefaults.standardUserDefaults boolForKey:BackupEncryptionDefaultsKey]) return payload;
    NSString *password = BackupEncryptionPassword();
    if (!password.length) {
        if (error) *error = [NSError errorWithDomain:BackupCryptoErrorDomain code:BackupCryptoErrorFailed userInfo:@{
            NSLocalizedDescriptionKey: @"备份加密已开启，但钥匙串中没有备份密码。请在“设置 → 备份”中重新设置密码。"}];
        return nil;
    }
    return BackupEncrypt(payload, password, error);
}

- (NSURL *)writeBackup:(NSData *)payload error:(NSError **)error {
    if (![NSFileManager.defaultManager createDirectoryAtURL:self.directory withIntermediateDirectories:YES attributes:nil error:error])
        return nil;
    NSData *sealed = [self sealedPayload:payload error:error];
    if (!sealed) return nil;
    NSString *name = [NSString stringWithFormat:@"%@%@.json", BackupFilePrefix, [NameFormatter() stringFromDate:NSDate.date]];
    NSURL *url = [self.directory URLByAppendingPathComponent:name];
    if (![sealed writeToURL:url options:NSDataWritingAtomic error:error]) return nil;
    _lastFingerprint = AccountsFingerprint(payload);
    _lastLocalError = nil;
    NSArray<NSURL *> *backups = self.localBackups;
    for (NSUInteger index = self.localRetention; index < backups.count; index++)
        [NSFileManager.defaultManager removeItemAtURL:backups[index] error:nil];
    if ([NSUserDefaults.standardUserDefaults boolForKey:WebDAVEnabledDefaultsKey]) [self uploadSealedData:sealed name:name completion:nil];
    [self notify];
    return url;
}

- (NSURL *)backupNow:(NSError **)error {
    NSData *payload = [_store exportDataForAccountIDs:nil error:error];
    return payload ? [self writeBackup:payload error:error] : nil;
}

#pragma mark - WebDAV

- (WebDAVClient *)webDAVClient {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *server = [defaults stringForKey:WebDAVServerDefaultsKey];
    NSString *username = [defaults stringForKey:WebDAVUsernameDefaultsKey] ?: @"";
    if (!server.length) return nil;
    NSString *password = KeychainPassword(WebDAVKeychainService, username) ?: @"";
    return [[WebDAVClient alloc] initWithServer:server folder:[defaults stringForKey:WebDAVFolderDefaultsKey]
        username:username password:password];
}

- (void)uploadData:(NSData *)data completion:(void (^)(NSString *))completion {
    NSError *error = nil;
    NSData *sealed = [self sealedPayload:data error:&error];
    if (!sealed) {
        [self finishUploadWithFailure:error.localizedDescription completion:completion];
        return;
    }
    NSString *name = [NSString stringWithFormat:@"%@%@.json", BackupFilePrefix, [NameFormatter() stringFromDate:NSDate.date]];
    [self uploadSealedData:sealed name:name completion:completion];
}

- (void)uploadSealedData:(NSData *)data name:(NSString *)name completion:(void (^)(NSString *))completion {
    WebDAVClient *client = [self webDAVClient];
    if (!client) {
        [self finishUploadWithFailure:@"请先在“设置 → 备份”中填写 WebDAV 服务器地址" completion:completion];
        return;
    }
    _isUploading = YES;
    [self notify];
    __weak typeof(self) weakSelf = self;
    [client prepareFolderWithCompletion:^(NSString *failure) {
        if (failure) { [weakSelf finishUploadWithFailure:failure completion:completion]; return; }
        [client uploadData:data name:name completion:^(NSString *uploadFailure) {
            BackupManager *strongSelf = weakSelf;
            if (!strongSelf) return;
            if (!uploadFailure) {
                [NSUserDefaults.standardUserDefaults setObject:NSDate.date forKey:LastRemoteBackupDefaultsKey];
                [strongSelf pruneRemoteWithClient:client];
            }
            [strongSelf finishUploadWithFailure:uploadFailure completion:completion];
        }];
    }];
}

- (void)finishUploadWithFailure:(NSString *)failure completion:(void (^)(NSString *))completion {
    _isUploading = NO;
    _lastRemoteError = [failure copy];
    [self notify];
    if (completion) completion(failure);
}

- (void)pruneRemoteWithClient:(WebDAVClient *)client {
    NSUInteger keep = self.remoteRetention;
    [client listFilesWithPrefix:BackupFilePrefix completion:^(NSArray<WebDAVFile *> *files, NSString *failure) {
        for (NSUInteger index = keep; index < files.count; index++)
            [client deleteName:files[index].name completion:^(NSString *ignored) {}];
    }];
}
@end
