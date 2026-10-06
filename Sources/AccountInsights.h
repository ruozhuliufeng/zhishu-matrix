#import <Foundation/Foundation.h>

@class Account, AccountUsageWindow, PaymentCard;

NS_ASSUME_NONNULL_BEGIN

/// Below this share of a usage window an account is short of quota.
extern double const AccountLowQuotaPercent;

typedef NS_ENUM(NSInteger, AccountStatusKind) {
    AccountStatusNormal = 0,
    AccountStatusArchived,
    /// Disabled, banned or transferred.
    AccountStatusRetired,
    AccountStatusIdle,
    /// Profile or payment details are missing (see AccountMissingFields).
    AccountStatusIncomplete,
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
+ (instancetype)statusForAccount:(Account *)account now:(NSDate *)now;
@end

/// What is missing from an account's record, in display order: "邮箱", "订阅级别", "续费 / 到期日期", "月费", "币种",
/// "供应商", "付款方式", "卡尾号", "付款记录", "近 35 天未记付款". Free accounts only need an email and a plan;
/// archived and retired accounts need nothing.
NSArray<NSString *> *AccountMissingFields(Account *account, NSDate *now);

/// The latest renewal of an auto-renewing paid account with no payment recorded within three days before it
/// or any time after ("yyyy-MM-dd"), or nil. The renewal is `expiresAt` once that day has come, otherwise the
/// month before it.
NSString *_Nullable AccountUnrecordedRenewal(Account *account, NSDate *now);

/// Actual spend in one year, from payment records, converted to CNY.
@interface AccountExpenseReport : NSObject
@property (nonatomic, readonly) NSInteger year;
/// Net of refunds; failed charges count for nothing.
@property (nonatomic, readonly) double total;
/// Payments and refunds counted.
@property (nonatomic, readonly) NSUInteger count;
/// Refunded money in CNY (positive), already taken off `total`.
@property (nonatomic, readonly) double refundTotal;
@property (nonatomic, readonly) NSUInteger failedCount;
/// Twelve totals, January first.
@property (nonatomic, readonly) NSArray<NSNumber *> *monthTotals;
/// Twelve {supplier: total} dictionaries.
@property (nonatomic, readonly) NSArray<NSDictionary<NSString *, NSNumber *> *> *monthSupplierTotals;
/// [{@"name", @"total", @"count"}] largest first; byAccount entries also carry @"accountID".
@property (nonatomic, readonly) NSArray<NSDictionary *> *bySupplier;
@property (nonatomic, readonly) NSArray<NSDictionary *> *bySource;
@property (nonatomic, readonly) NSArray<NSDictionary *> *byAccount;
/// Currencies of payments left out for lack of a rate.
@property (nonatomic, readonly) NSArray<NSString *> *missingCurrencies;
+ (instancetype)reportForAccounts:(NSArray<Account *> *)accounts year:(NSInteger)year rates:(NSDictionary<NSString *, NSNumber *> *)rates;
/// What each account was expected to pay in the month containing `day` against what was recorded, sorted by date:
/// [{@"accountID", @"name", @"date" ("" if none), @"expected" (CNY or NSNull), @"recorded" (CNY),
///   @"state": recorded | different | missing | upcoming | extra | failed}]. Refunds are taken off what was recorded;
/// a month with only a failed charge is "failed".
+ (NSArray<NSDictionary *> *)reconciliationForAccounts:(NSArray<Account *> *)accounts month:(NSDate *)day now:(NSDate *)now
    rates:(NSDictionary<NSString *, NSNumber *> *)rates;
@end

/// What was spent in the month containing `day`, in CNY: payments less refunds. Failed charges and currencies
/// without a rate are left out.
double AccountSpentInMonth(NSArray<Account *> *accounts, NSDate *day, NSDictionary<NSString *, NSNumber *> *rates);
/// Once this month's spending goes over `budget` (when above 0): {id, kind: budget, accountID: "", title, body}.
/// Announced once a month; `state` remembers it.
NSDictionary<NSString *, NSString *> *_Nullable AccountBudgetAlert(NSArray<Account *> *accounts, NSDate *now, double budget,
    NSDictionary<NSString *, NSNumber *> *rates, NSMutableDictionary *state);

/// Cards that expire within 30 days, or have expired, while tracked paid accounts still pay with them:
/// [{id, kind: card, accountID: "", card: last4, title, body}]. Each stage is announced once; `state` remembers it.
NSArray<NSDictionary<NSString *, NSString *> *> *AccountCardAlertsDue(NSArray<PaymentCard *> *cards, NSArray<Account *> *accounts,
    NSDate *now, NSMutableDictionary *state);

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

/// Works out which notifications are due. Payment prompts ({kind: payment, date}) come with the renewal kind. `state` remembers what was already announced (keep it between
/// launches); it is updated in place. Each alert: {id, kind, accountID, title, body}.
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
