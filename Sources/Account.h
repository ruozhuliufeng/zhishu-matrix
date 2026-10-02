#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, AccountExpiryState) {
    AccountExpiryStateUnknown = 0,
    AccountExpiryStateActive,
    AccountExpiryStateExpiringSoon,
    AccountExpiryStateExpired,
    /// The subscription renews automatically on `expiresAt`, so the date is not a risk.
    AccountExpiryStateRenewing,
};

extern NSInteger const AccountExpiringSoonDays;
extern NSErrorDomain const AccountStoreErrorDomain;
extern NSNotificationName const AccountStoreDidChangeNotification;

/// Plans in display order; the tier-less "Pro" is used when the Pro tier is unknown.
NSArray<NSString *> *AccountPlans(void);
NSString *_Nullable AccountCanonicalPlan(id _Nullable plan);
/// "Pro" for every Pro tier, otherwise the plan itself.
NSString *_Nullable AccountPlanFamily(NSString *_Nullable plan);
NSString *AccountDayString(NSDate *date);
NSDate *_Nullable AccountDateFromDayString(NSString *_Nullable day);
/// Trimmed, non-empty, de-duplicated tags in their original order.
NSArray<NSString *> *AccountNormalizedTags(id _Nullable tags);
/// "PHP 8,919.64"; empty when the amount is missing.
NSString *AccountFormatMoney(NSNumber *_Nullable amount, NSString *_Nullable currency);
/// "¥1,115.00"; empty when the amount is missing.
NSString *AccountFormatCNY(NSNumber *_Nullable amount);

/// Suppliers offered in pickers; accounts can also use their own.
NSArray<NSString *> *AccountSuppliers(void);
/// Payment methods offered in pickers.
NSArray<NSString *> *AccountPaymentMethods(void);
/// The last four digits in `text` ("6222 **** 1234" → "1234"); empty when it has fewer than four digits.
NSString *AccountCardLast4(NSString *_Nullable text);

/// NSUserDefaults key: {currency code: CNY per unit}, edited by hand in Settings.
extern NSString *const ExchangeRatesDefaultsKey;
extern NSNotificationName const ExchangeRatesDidChangeNotification;
/// The saved rates, always including CNY = 1.
NSDictionary<NSString *, NSNumber *> *AccountExchangeRates(void);
/// `amount` in CNY with these rates, or nil when the currency has no rate.
NSNumber *_Nullable AccountAmountInCNY(NSNumber *_Nullable amount, NSString *_Nullable currency,
    NSDictionary<NSString *, NSNumber *> *rates);

/// NSUserDefaults key: the supplier price list, [{@"supplier", @"plan", @"amount", @"currency"}].
extern NSString *const SupplierPricesDefaultsKey;
extern NSNotificationName const SupplierPricesDidChangeNotification;
/// Valid entries of the saved price list.
NSArray<NSDictionary *> *AccountSupplierPrices(void);
/// {@"amount", @"currency"} listed for this supplier and plan, if any.
NSDictionary *_Nullable AccountListedPrice(NSString *_Nullable supplier, NSString *_Nullable plan);

/// A third-party app this account signed in to with "Sign in with ChatGPT".
@interface AccountAuthorization : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy, null_resettable) NSString *appName;
@property (nonatomic, copy, null_resettable) NSString *clientID;
/// The redirect address of the authorization request.
@property (nonatomic, copy, null_resettable) NSString *redirect;
@property (nonatomic, copy, null_resettable) NSString *scope;
@property (nonatomic, copy, null_resettable) NSString *note;
/// "app" when recorded by the authorization window, "manual" when added by hand.
@property (nonatomic, copy, null_resettable) NSString *source;
@property (nonatomic, strong) NSDate *firstAuthorizedAt;
@property (nonatomic, strong) NSDate *lastAuthorizedAt;
@property (nonatomic) NSInteger count;
@property (nonatomic, strong, nullable) NSDate *revokedAt;
@property (nonatomic, readonly, getter=isRevoked) BOOL revoked;
- (nullable instancetype)initWithDictionary:(NSDictionary *)dictionary;
- (NSDictionary *)dictionaryRepresentation;
/// Same client (by client_id, else by redirect address).
- (BOOL)isSameAppAsClientID:(nullable NSString *)clientID redirect:(nullable NSString *)redirect;
@end

/// One payment made for an account's subscription.
@interface AccountPayment : NSObject
@property (nonatomic, copy) NSString *identifier;
/// "yyyy-MM-dd".
@property (nonatomic, copy) NSString *date;
@property (nonatomic, strong) NSNumber *amount;
@property (nonatomic, copy, null_resettable) NSString *currency;
@property (nonatomic, copy, null_resettable) NSString *supplier;
@property (nonatomic, copy, null_resettable) NSString *paymentMethod;
@property (nonatomic, copy, null_resettable) NSString *cardLast4;
@property (nonatomic, copy, null_resettable) NSString *note;
/// "manual" or "page" (read from the billing page).
@property (nonatomic, copy, null_resettable) NSString *source;
- (nullable instancetype)initWithDictionary:(NSDictionary *)dictionary;
- (NSDictionary *)dictionaryRepresentation;
/// Same day, amount and currency: the same charge read twice.
- (BOOL)isSameChargeAs:(AccountPayment *)other;
@end

/// One rolling usage limit reported by ChatGPT, such as the 5-hour or weekly window.
@interface AccountUsageWindow : NSObject
@property (nonatomic) double usedPercent;
@property (nonatomic, strong, nullable) NSDate *resetAt;
@property (nonatomic) NSInteger windowSeconds;
@property (nonatomic, readonly) double remainingPercent;
/// "5 小时", "每周", "30 天"...
@property (nonatomic, readonly) NSString *title;
- (nullable instancetype)initWithDictionary:(NSDictionary *)dictionary;
- (NSDictionary *)dictionaryRepresentation;
@end

/// Last usage snapshot read from ChatGPT for an account.
@interface AccountUsage : NSObject
/// Sorted from the shortest window to the longest.
@property (nonatomic, copy) NSArray<AccountUsageWindow *> *windows;
@property (nonatomic, strong, nullable) NSNumber *creditBalance;
@property (nonatomic) BOOL unlimitedCredits;
@property (nonatomic, strong) NSDate *fetchedAt;
/// The window of a day or less (the 5-hour limit).
@property (nonatomic, readonly, nullable) AccountUsageWindow *shortWindow;
/// The longest window over a day (the weekly limit).
@property (nonatomic, readonly, nullable) AccountUsageWindow *longWindow;
@property (nonatomic, readonly, nullable) NSNumber *lowestRemainingPercent;
- (nullable instancetype)initWithDictionary:(NSDictionary *)dictionary;
- (NSDictionary *)dictionaryRepresentation;
@end

/// Locally stored profile of one ChatGPT account. Passwords and tokens are never part of it.
@interface Account : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy, null_resettable) NSString *email;
@property (nonatomic, copy, nullable) NSString *plan;
@property (nonatomic, copy, nullable) NSString *planSource;
/// The day the current paid period ends ("yyyy-MM-dd"); the renewal day when `autoRenew` is YES.
@property (nonatomic, copy, nullable) NSString *expiresAt;
@property (nonatomic, copy, nullable) NSString *expirySource;
@property (nonatomic, strong, nullable) NSNumber *autoRenew;
@property (nonatomic, strong, nullable) NSNumber *monthlyPrice;
/// Where the monthly price came from: "list" (supplier price list), "page" (billing page) or "manual".
@property (nonatomic, copy, nullable) NSString *priceSource;
@property (nonatomic, copy, null_resettable) NSString *currency;
@property (nonatomic, copy, null_resettable) NSString *group;
@property (nonatomic, copy, null_resettable) NSArray<NSString *> *tags;
@property (nonatomic, copy, null_resettable) NSString *notes;
/// Client authorization link remembered for this account; empty means "use the default link".
@property (nonatomic, copy, null_resettable) NSString *authURL;
/// Proxy for this account's pages ("http://host:port", "socks5://host:port"); empty means the app default.
@property (nonatomic, copy, null_resettable) NSString *proxy;
/// Where the subscription was bought: Google Play, iOS, a reseller…
@property (nonatomic, copy, null_resettable) NSString *supplier;
/// How it is paid: 信用卡, 支付宝…
@property (nonatomic, copy, null_resettable) NSString *paymentMethod;
/// Last four digits of the paying card; never more.
@property (nonatomic, copy, null_resettable) NSString *cardLast4;
/// Newest first.
@property (nonatomic, copy, null_resettable) NSArray<AccountPayment *> *payments;
/// Most recently authorized first.
@property (nonatomic, copy, null_resettable) NSArray<AccountAuthorization *> *authorizations;
@property (nonatomic, strong, nullable) NSDate *createdAt;
@property (nonatomic, strong, nullable) NSDate *lastUsedAt;
@property (nonatomic, strong, nullable) NSNumber *signedIn;
@property (nonatomic, strong, nullable) AccountUsage *usage;
/// Why the last usage refresh failed; kept in memory only.
@property (nonatomic, copy, nullable) NSString *refreshError;

@property (nonatomic, readonly) NSString *planTitle;
@property (nonatomic, readonly, nullable) AccountPayment *lastPayment;
/// "Google Play · 尾号 1234"; empty when nothing is filled in.
@property (nonatomic, readonly) NSString *paymentSummary;
@property (nonatomic, readonly, nullable) NSString *planFamily;
@property (nonatomic, readonly) BOOL isPaid;
@property (nonatomic, readonly) NSInteger planRank;

+ (instancetype)accountWithName:(NSString *)name;
- (instancetype)initWithDictionary:(NSDictionary *)dictionary NS_DESIGNATED_INITIALIZER;
- (NSDictionary *)dictionaryRepresentation;
- (NSDictionary *)exportRepresentation;
/// Merges an imported profile; empty fields in `other` keep the local value.
- (void)applyProfileFrom:(Account *)other;
/// Applies a plan read from ChatGPT. A tier-less "Pro" keeps a known Pro tier. Returns YES when it changed anything.
- (BOOL)applyDetectedPlan:(nullable NSString *)plan source:(NSString *)source;
- (nullable NSNumber *)daysRemainingFromDate:(NSDate *)now;
- (AccountExpiryState)expiryStateFromDate:(NSDate *)now;
/// Relative: "剩余 23 天", "3 天后续费", "已过期 2 天"...
- (NSString *)expiryDescriptionFromDate:(NSDate *)now;
/// Absolute: "10月25日自动续费", "10月25日到期", "未设置到期".
- (NSString *)renewalDescription;
/// For narrow columns: "10/25 续费 · 24 天", "10/5 到期 · 4 天", "9/28 已过期"; empty when unknown.
- (NSString *)compactRenewalDescriptionFromDate:(NSDate *)now;
- (BOOL)matchesSearch:(nullable NSString *)query;
/// Takes the price list's price for this supplier and plan unless the price was typed in by hand.
/// Returns YES when the price changed.
- (BOOL)applyListedPrice;
/// What the next charge should be: the listed price, else the monthly price ({@"amount", @"currency"}).
@property (nonatomic, readonly, nullable) NSDictionary *expectedCharge;
/// Adds payments, skipping charges already recorded; returns how many were new.
- (NSUInteger)addPayments:(NSArray<AccountPayment *> *)payments;
/// Notes a successful authorization: updates the app's entry (reviving it if revoked) or adds one.
- (AccountAuthorization *)recordAuthorizationWithClientID:(nullable NSString *)clientID redirect:(nullable NSString *)redirect
    scope:(nullable NSString *)scope appName:(NSString *)appName at:(NSDate *)date;
@property (nonatomic, readonly) NSArray<AccountAuthorization *> *activeAuthorizations;
@end

@interface AccountStore : NSObject
@property (nonatomic, readonly) NSURL *fileURL;
@property (nonatomic, readonly) NSArray<Account *> *accounts;
/// Set when `load:` found an unreadable file and copied it aside before starting empty.
@property (nonatomic, readonly, nullable) NSURL *recoveredBackupURL;
@property (nonatomic, copy, nullable) void (^saveFailed)(NSError *error);

- (instancetype)initWithFileURL:(NSURL *)fileURL;
- (BOOL)load:(NSError **)error;
- (BOOL)save:(NSError **)error;
/// Saves and posts AccountStoreDidChangeNotification.
- (void)commit;

- (nullable Account *)accountWithID:(nullable NSString *)identifier;
- (NSArray<Account *> *)accountsWithIDs:(NSArray<NSString *> *)identifiers;
- (Account *)addAccountNamed:(NSString *)name group:(nullable NSString *)group;
- (void)removeAccountsWithIDs:(NSArray<NSString *> *)identifiers;
- (void)moveAccountsWithIDs:(NSArray<NSString *> *)identifiers toIndex:(NSUInteger)index;
- (NSArray<NSString *> *)groups;
- (NSArray<NSString *> *)tags;
/// The default suppliers followed by any others in use.
- (NSArray<NSString *> *)suppliers;
/// The default payment methods followed by any others in use.
- (NSArray<NSString *> *)paymentMethods;
/// Names of third-party apps with an active authorization, sorted.
- (NSArray<NSString *> *)authorizedApps;
/// Sum of the monthly prices of paid accounts, per currency.
- (NSDictionary<NSString *, NSNumber *> *)monthlySpendByCurrency;
/// The monthly total in CNY; `missing` receives the currencies without a rate, which are left out.
- (double)monthlySpendInCNYWithRates:(NSDictionary<NSString *, NSNumber *> *)rates
    missingCurrencies:(NSArray<NSString *> *_Nullable *_Nullable)missing;
/// Every payment of every account as CSV (UTF-8 with BOM, for Excel), newest first.
- (NSData *)paymentsCSVWithRates:(NSDictionary<NSString *, NSNumber *> *)rates;

- (nullable NSData *)exportDataForAccountIDs:(nullable NSArray<NSString *> *)identifiers error:(NSError **)error;
- (BOOL)importData:(NSData *)data added:(nullable NSUInteger *)added updated:(nullable NSUInteger *)updated error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
