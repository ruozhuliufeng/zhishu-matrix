#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The "format" of an encrypted backup envelope.
extern NSString *const BackupEncryptedFormat;
extern NSErrorDomain const BackupCryptoErrorDomain;

typedef NS_ERROR_ENUM(BackupCryptoErrorDomain, BackupCryptoError) {
    /// Not an envelope this version can read.
    BackupCryptoErrorUnreadable = 1,
    /// The password is wrong or the file was changed.
    BackupCryptoErrorWrongPassword = 2,
    BackupCryptoErrorFailed = 3,
};

/// YES when `data` is an encrypted backup envelope (JSON with "format": BackupEncryptedFormat).
BOOL BackupDataIsEncrypted(NSData *_Nullable data);

/// Encrypts with AES-256-CBC and authenticates with HMAC-SHA256 (encrypt-then-MAC). Both keys come from the
/// password through PBKDF2-SHA256 with a random salt; the IV is random too. Returns the JSON envelope.
NSData *_Nullable BackupEncrypt(NSData *plaintext, NSString *password, NSError **error);
/// Checks the MAC before decrypting; a wrong password and a modified file both give BackupCryptoErrorWrongPassword.
NSData *_Nullable BackupDecrypt(NSData *envelope, NSString *password, NSError **error);

NS_ASSUME_NONNULL_END
