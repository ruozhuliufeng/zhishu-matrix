#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Hands back `data` ready to import: as it is when it is not encrypted, otherwise decrypted with the saved backup
/// password or, failing that, with one typed into a sheet on `window`. `completion` gets nil when cancelled.
void BackupOpenData(NSData *data, NSString *name, NSWindow *window, void (^completion)(NSData *_Nullable data));

/// Asks for a new backup password, typed twice. `completion` gets nil when cancelled.
void BackupAskNewPassword(NSWindow *window, NSString *title, void (^completion)(NSString *_Nullable password));

NS_ASSUME_NONNULL_END
