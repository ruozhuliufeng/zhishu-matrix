#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface SettingsWindowController : NSWindowController
/// Ends editing so a typed value is saved (e.g. before quitting).
- (void)commitEditing;
@end

NS_ASSUME_NONNULL_END
