#import <Foundation/Foundation.h>

@class Account, AccountUsageWindow;

NS_ASSUME_NONNULL_BEGIN

/// Below this share of a usage window an account is short of quota.
extern double const AccountLowQuotaPercent;

typedef NS_ENUM(NSInteger, AccountStatusKind) {
    AccountStatusNormal = 0,
    AccountStatusRecommended,
    AccountStatusRefreshFailed,
    AccountStatusExpiringSoon,
    AccountStatusQuotaLow,
    AccountStatusExpired,
    AccountStatusSignedOut,
};

typedef NS_ENUM(NSInteger, AccountStatusTone) {
    AccountStatusToneNeutral = 0,
    AccountStatusToneGood,
    AccountStatusToneWarning,
    AccountStatusToneCritical,
};

/// The single most important thing to know about an account right now.
@interface AccountStatus : NSObject
@property (nonatomic, readonly) AccountStatusKind kind;
@property (nonatomic, readonly) AccountStatusTone tone;
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly, copy) NSString *symbol;
+ (instancetype)statusForAccount:(Account *)account recommended:(BOOL)recommended now:(NSDate *)now;
@end

/// Signed in, has usage, and the most quota left in its tightest window (at least 10%).
Account *_Nullable AccountRecommended(NSArray<Account *> *accounts);

/// Lowercased email → accounts sharing it, for emails used by more than one account.
NSDictionary<NSString *, NSArray<Account *> *> *AccountDuplicateEmails(NSArray<Account *> *accounts);

/// An iCalendar file with each account's renewal (monthly when it auto-renews) or expiry, reminded a day before.
NSString *AccountRenewalCalendar(NSArray<Account *> *accounts);

/// Parses "http://host:port", "socks5://user:pass@host:port" or "host:port" into
/// {@"scheme": http|https|socks5, @"host", @"port", @"user"?, @"password"?}; nil when it is not a proxy address.
NSDictionary<NSString *, id> *_Nullable AccountProxyComponents(NSString *_Nullable text);

typedef NS_OPTIONS(NSUInteger, AccountAlertKinds) {
    AccountAlertQuota = 1 << 0,      // a window drops under AccountLowQuotaPercent, or recovers after that
    AccountAlertRenewal = 1 << 1,    // expiry within three days, or an automatic renewal tomorrow
    AccountAlertSignedOut = 1 << 2,  // an account that was signed in is signed out
};

/// Works out which notifications are due. `state` remembers what was already announced (keep it between
/// launches); it is updated in place. Each alert: {id, kind, accountID, title, body, recommendedID?}.
NSArray<NSDictionary<NSString *, NSString *> *> *AccountAlertsDue(NSArray<Account *> *accounts, NSDate *now,
    NSMutableDictionary *state, AccountAlertKinds kinds);
/// Stops a deliberate sign-out (clearing login data) from being announced as an expired login.
void AccountAlertsForgetSignIn(NSMutableDictionary *state, NSArray<NSString *> *identifiers);

/// Local history of usage snapshots, for trends and run-out estimates.
@interface UsageHistory : NSObject
- (instancetype)initWithFileURL:(NSURL *)fileURL;
/// Adds a point {t, short, long} (remaining percentages) and keeps eight days.
- (void)recordUsageWindows:(NSArray<AccountUsageWindow *> *)windows forAccountID:(NSString *)identifier at:(NSDate *)date;
- (NSArray<NSDictionary *> *)pointsForAccountID:(NSString *)identifier;
- (void)removeAccountIDs:(NSArray<NSString *> *)identifiers;
- (BOOL)save:(NSError **)error;
/// When the window runs out at the recent pace, or nil if it lasts until its reset.
+ (nullable NSDate *)predictedExhaustionOfWindow:(AccountUsageWindow *)window key:(NSString *)key
    points:(NSArray<NSDictionary *> *)points now:(NSDate *)now;
@end

NS_ASSUME_NONNULL_END
