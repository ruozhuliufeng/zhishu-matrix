#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface AppDelegate : NSObject <NSApplicationDelegate>
/// Where accounts.json lives. Defaults to ~/Library/Application Support/ChatGPTAccountDesk.
@property (nonatomic, strong, nullable) NSURL *dataDirectory;
@end

NS_ASSUME_NONNULL_END
