#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const AppLockEnabledDefaultsKey;        // BOOL: lock at launch
extern NSString *const AppLockIdleMinutesDefaultsKey;    // NSInteger: lock after this much inactivity, 0 = never
extern NSString *const AppLockOnScreenLockDefaultsKey;   // BOOL, default YES: lock when the screen locks or sleeps
extern NSNotificationName const AppLockSettingsDidChangeNotification;

/// Hides every window behind a lock screen until the user authenticates with Touch ID or the Mac password.
@interface AppLock : NSObject
@property (nonatomic, readonly, getter=isLocked) BOOL locked;
@property (nonatomic, readonly, getter=isEnabled) BOOL enabled;
/// Called after locking and after unlocking.
@property (nonatomic, copy, nullable) void (^lockStateChanged)(BOOL locked);
/// Whether this Mac can authenticate the owner; otherwise `reason` explains why not.
+ (BOOL)canAuthenticate:(NSString *_Nullable *_Nullable)reason;
/// Asks for Touch ID or the password; used before turning the lock on or off.
+ (void)authenticateWithReason:(NSString *)reason completion:(void (^)(BOOL success, NSString *_Nullable failure))completion;
- (void)start;
- (void)lock;
/// Brings the lock screen forward and asks to authenticate.
- (void)showLockScreen;
@end

NS_ASSUME_NONNULL_END
