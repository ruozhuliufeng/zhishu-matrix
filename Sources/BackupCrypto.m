#import "BackupCrypto.h"
#import <CommonCrypto/CommonCrypto.h>
#import <CommonCrypto/CommonRandom.h>

NSString *const BackupEncryptedFormat = @"zhishu-matrix-encrypted";
NSErrorDomain const BackupCryptoErrorDomain = @"BackupCryptoErrorDomain";

static NSUInteger const DefaultIterations = 200000;
// Bounds for envelopes read back, so a crafted file can neither weaken the key nor stall the app.
static NSUInteger const MinimumIterations = 100000;
static NSUInteger const MaximumIterations = 5000000;
static size_t const SaltLength = 16;
static size_t const KeyLength = kCCKeySizeAES256;

static NSError *CryptoError(BackupCryptoError code, NSString *description) {
    return [NSError errorWithDomain:BackupCryptoErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: description}];
}

static NSData *RandomBytes(size_t length) {
    NSMutableData *data = [NSMutableData dataWithLength:length];
    return CCRandomGenerateBytes(data.mutableBytes, length) == kCCSuccess ? data : nil;
}

/// 64 bytes: the AES key followed by the HMAC key.
static NSData *DerivedKeys(NSString *password, NSData *salt, NSUInteger iterations) {
    NSData *secret = [password dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *keys = [NSMutableData dataWithLength:KeyLength * 2];
    int status = CCKeyDerivationPBKDF(kCCPBKDF2, secret.bytes, secret.length, salt.bytes, salt.length, kCCPRFHmacAlgSHA256,
        (unsigned)iterations, keys.mutableBytes, keys.length);
    return status == kCCSuccess ? keys : nil;
}

/// The MAC covers the parameters as well as the ciphertext, so none of them can be swapped.
static NSData *Tag(NSData *keys, NSUInteger iterations, NSData *salt, NSData *iv, NSData *ciphertext) {
    NSMutableData *message = [[[NSString stringWithFormat:@"%@|1|%lu|", BackupEncryptedFormat, (unsigned long)iterations]
        dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [message appendData:salt];
    [message appendData:iv];
    [message appendData:ciphertext];
    NSMutableData *tag = [NSMutableData dataWithLength:CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, (const uint8_t *)keys.bytes + KeyLength, KeyLength, message.bytes, message.length, tag.mutableBytes);
    return tag;
}

static NSData *AES(CCOperation operation, NSData *keys, NSData *iv, NSData *input) {
    NSMutableData *output = [NSMutableData dataWithLength:input.length + kCCBlockSizeAES128];
    size_t written = 0;
    CCCryptorStatus status = CCCrypt(operation, kCCAlgorithmAES, kCCOptionPKCS7Padding, keys.bytes, KeyLength, iv.bytes,
        input.bytes, input.length, output.mutableBytes, output.length, &written);
    if (status != kCCSuccess) return nil;
    output.length = written;
    return output;
}

static NSDictionary *Envelope(NSData *data) {
    if (!data.length) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [json isKindOfClass:NSDictionary.class] && [json[@"format"] isEqual:BackupEncryptedFormat] ? json : nil;
}

static NSData *Base64Field(NSDictionary *envelope, NSString *key) {
    id value = envelope[key];
    return [value isKindOfClass:NSString.class] ? [[NSData alloc] initWithBase64EncodedString:value options:0] : nil;
}

BOOL BackupDataIsEncrypted(NSData *data) { return Envelope(data) != nil; }

NSData *BackupEncrypt(NSData *plaintext, NSString *password, NSError **error) {
    NSData *salt = RandomBytes(SaltLength), *iv = RandomBytes(kCCBlockSizeAES128);
    NSData *keys = salt && iv && password.length ? DerivedKeys(password, salt, DefaultIterations) : nil;
    NSData *ciphertext = keys ? AES(kCCEncrypt, keys, iv, plaintext) : nil;
    if (!ciphertext) {
        if (error) *error = CryptoError(BackupCryptoErrorFailed, @"无法加密备份");
        return nil;
    }
    NSDictionary *envelope = @{
        @"format": BackupEncryptedFormat, @"version": @1,
        @"kdf": @"PBKDF2-SHA256", @"iterations": @(DefaultIterations), @"cipher": @"AES-256-CBC", @"mac": @"HMAC-SHA256",
        @"salt": [salt base64EncodedStringWithOptions:0], @"iv": [iv base64EncodedStringWithOptions:0],
        @"data": [ciphertext base64EncodedStringWithOptions:0],
        @"tag": [Tag(keys, DefaultIterations, salt, iv, ciphertext) base64EncodedStringWithOptions:0]};
    return [NSJSONSerialization dataWithJSONObject:envelope options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:error];
}

NSData *BackupDecrypt(NSData *data, NSString *password, NSError **error) {
    NSDictionary *envelope = Envelope(data);
    NSData *salt = Base64Field(envelope, @"salt"), *iv = Base64Field(envelope, @"iv");
    NSData *ciphertext = Base64Field(envelope, @"data"), *tag = Base64Field(envelope, @"tag");
    id iterationValue = envelope[@"iterations"];
    NSUInteger iterations = [iterationValue isKindOfClass:NSNumber.class] ? [iterationValue unsignedIntegerValue] : 0;
    if (![envelope[@"version"] isEqual:@1] || salt.length < 8 || iv.length != kCCBlockSizeAES128 || !ciphertext.length ||
        tag.length != CC_SHA256_DIGEST_LENGTH || iterations < MinimumIterations || iterations > MaximumIterations) {
        if (error) *error = CryptoError(BackupCryptoErrorUnreadable, @"无法识别这个加密备份，可能需要更新版本的智枢矩阵");
        return nil;
    }
    NSData *keys = password.length ? DerivedKeys(password, salt, iterations) : nil;
    NSData *expected = keys ? Tag(keys, iterations, salt, iv, ciphertext) : nil;
    // Constant-time comparison.
    uint8_t difference = expected ? 0 : 1;
    for (NSUInteger index = 0; expected && index < CC_SHA256_DIGEST_LENGTH; index++)
        difference |= ((const uint8_t *)expected.bytes)[index] ^ ((const uint8_t *)tag.bytes)[index];
    NSData *plaintext = difference == 0 ? AES(kCCDecrypt, keys, iv, ciphertext) : nil;
    if (!plaintext) {
        if (error) *error = CryptoError(BackupCryptoErrorWrongPassword, @"密码不正确，或备份文件已被修改");
        return nil;
    }
    return plaintext;
}
