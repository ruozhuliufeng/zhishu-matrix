#import "Account.h"

NSInteger const AccountExpiringSoonDays = 7;
NSErrorDomain const AccountStoreErrorDomain = @"AccountStoreErrorDomain";
NSNotificationName const AccountStoreDidChangeNotification = @"AccountStoreDidChangeNotification";

NSArray<NSString *> *AccountPlans(void) {
    return @[@"Free", @"Go", @"Plus", @"Pro", @"Pro 100", @"Pro 200", @"Pro 500", @"Business", @"Enterprise", @"Edu"];
}

static NSString *Trimmed(NSString *value) {
    return [value ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *StringOrNil(id value) {
    return [value isKindOfClass:NSString.class] && [value length] ? value : nil;
}

static NSNumber *NumberOrNil(id value) {
    if ([value isKindOfClass:NSNumber.class]) return value;
    if ([value isKindOfClass:NSString.class] && [value length]) {
        NSString *digits = [value stringByReplacingOccurrencesOfString:@"," withString:@""];
        NSScanner *scanner = [NSScanner scannerWithString:digits];
        double number = 0;
        if ([scanner scanDouble:&number] && scanner.isAtEnd) return @(number);
    }
    return nil;
}

NSString *AccountCanonicalPlan(id plan) {
    // "ChatGPT Pro 200", "pro200", "PRO" and "team" all map onto the display names.
    NSString *key = [[Trimmed(StringOrNil(plan)) lowercaseString] stringByReplacingOccurrencesOfString:@" " withString:@""];
    if ([key hasPrefix:@"chatgpt"]) key = [key substringFromIndex:7];
    if (!key.length) return nil;
    NSDictionary *aliases = @{@"team": @"Business", @"education": @"Edu"};
    if (aliases[key]) return aliases[key];
    for (NSString *candidate in AccountPlans()) {
        NSString *compact = [candidate.lowercaseString stringByReplacingOccurrencesOfString:@" " withString:@""];
        if ([compact isEqualToString:key]) return candidate;
    }
    return nil;
}

NSString *AccountPlanFamily(NSString *plan) {
    return [plan hasPrefix:@"Pro"] ? @"Pro" : plan;
}

NSArray<NSString *> *AccountNormalizedTags(id tags) {
    NSMutableOrderedSet<NSString *> *result = [NSMutableOrderedSet orderedSet];
    if ([tags isKindOfClass:NSArray.class]) {
        for (id tag in tags) {
            NSString *value = Trimmed(StringOrNil(tag));
            if (value.length) [result addObject:value];
        }
    }
    return result.array;
}

NSString *AccountFormatMoney(NSNumber *amount, NSString *currency) {
    if (!amount) return @"";
    static NSNumberFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSNumberFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.numberStyle = NSNumberFormatterDecimalStyle;
        formatter.usesGroupingSeparator = YES;
        formatter.groupingSeparator = @",";
        formatter.minimumFractionDigits = 0;
        formatter.maximumFractionDigits = 2;
    });
    NSString *value = [formatter stringFromNumber:amount] ?: amount.stringValue;
    return currency.length ? [NSString stringWithFormat:@"%@ %@", currency, value] : value;
}

NSString *AccountFormatCNY(NSNumber *amount) {
    if (!amount) return @"";
    static NSNumberFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSNumberFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.numberStyle = NSNumberFormatterDecimalStyle;
        formatter.usesGroupingSeparator = YES;
        formatter.groupingSeparator = @",";
        formatter.minimumFractionDigits = 2;
        formatter.maximumFractionDigits = 2;
    });
    return [@"¥" stringByAppendingString:[formatter stringFromNumber:amount] ?: amount.stringValue];
}

NSArray<NSString *> *AccountSuppliers(void) { return @[@"Google Play", @"iOS", @"世事宜AI", @"Bewild"]; }

NSArray<NSString *> *AccountPaymentMethods(void) {
    return @[@"信用卡", @"借记卡", @"支付宝", @"微信支付", @"PayPal", @"礼品卡 / 余额"];
}

NSString *AccountCardLast4(NSString *text) {
    NSMutableString *digits = [NSMutableString string];
    for (NSUInteger index = 0; index < text.length; index++) {
        unichar character = [text characterAtIndex:index];
        if (character >= '0' && character <= '9') [digits appendFormat:@"%C", character];
    }
    return digits.length >= 4 ? [digits substringFromIndex:digits.length - 4] : @"";
}

NSString *const ExchangeRatesDefaultsKey = @"exchangeRatesToCNY";
NSNotificationName const ExchangeRatesDidChangeNotification = @"ExchangeRatesDidChangeNotification";

NSDictionary<NSString *, NSNumber *> *AccountExchangeRates(void) {
    NSMutableDictionary *rates = [NSMutableDictionary dictionary];
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:ExchangeRatesDefaultsKey];
    [saved enumerateKeysAndObjectsUsingBlock:^(NSString *currency, id rate, BOOL *stop) {
        if ([currency isKindOfClass:NSString.class] && [rate isKindOfClass:NSNumber.class] && [rate doubleValue] > 0)
            rates[currency.uppercaseString] = rate;
    }];
    rates[@"CNY"] = @1;
    return rates;
}

NSNumber *AccountAmountInCNY(NSNumber *amount, NSString *currency, NSDictionary<NSString *, NSNumber *> *rates) {
    if (!amount) return nil;
    NSString *code = currency.uppercaseString;
    if ([code isEqualToString:@"RMB"] || [code isEqualToString:@"CNY"]) return amount;
    NSNumber *rate = code.length ? rates[code] : nil;
    return rate ? @(amount.doubleValue * rate.doubleValue) : nil;
}

static NSDateFormatter *DayFormatter(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
        formatter.dateFormat = @"yyyy-MM-dd";
    });
    return formatter;
}

static NSISO8601DateFormatter *TimestampFormatter(void) {
    static NSISO8601DateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ formatter = [NSISO8601DateFormatter new]; });
    return formatter;
}

static NSDate *TimestampOrNil(id value) {
    NSString *string = StringOrNil(value);
    return string ? [TimestampFormatter() dateFromString:string] : nil;
}

NSString *AccountDayString(NSDate *date) { return [DayFormatter() stringFromDate:date]; }

NSDate *AccountDateFromDayString(NSString *day) {
    return day.length ? [DayFormatter() dateFromString:day] : nil;
}

#pragma mark - Usage

@implementation AccountUsageWindow

- (instancetype)initWithDictionary:(NSDictionary *)dictionary {
    NSNumber *used = NumberOrNil(dictionary[@"usedPercent"]);
    NSNumber *seconds = NumberOrNil(dictionary[@"windowSeconds"]);
    if (!used || seconds.integerValue <= 0) return nil;
    if ((self = [super init])) {
        _usedPercent = MAX(0, MIN(100, used.doubleValue));
        _windowSeconds = seconds.integerValue;
        _resetAt = TimestampOrNil(dictionary[@"resetAt"]);
    }
    return self;
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableDictionary *dictionary = [@{@"usedPercent": @(self.usedPercent), @"windowSeconds": @(self.windowSeconds)} mutableCopy];
    if (self.resetAt) dictionary[@"resetAt"] = [TimestampFormatter() stringFromDate:self.resetAt];
    return dictionary;
}

- (double)remainingPercent { return MAX(0, 100 - self.usedPercent); }

- (NSString *)title {
    NSInteger seconds = self.windowSeconds;
    if (seconds == 7 * 86400) return @"每周";
    if (seconds % 86400 == 0) return [NSString stringWithFormat:@"%ld 天", (long)(seconds / 86400)];
    if (seconds % 3600 == 0) return [NSString stringWithFormat:@"%ld 小时", (long)(seconds / 3600)];
    return [NSString stringWithFormat:@"%ld 分钟", (long)MAX(1, seconds / 60)];
}
@end

@implementation AccountUsage

- (instancetype)init {
    if ((self = [super init])) {
        _windows = @[];
        _fetchedAt = NSDate.date;
    }
    return self;
}

- (instancetype)initWithDictionary:(NSDictionary *)dictionary {
    if (![dictionary isKindOfClass:NSDictionary.class]) return nil;
    if ((self = [self init])) {
        NSMutableArray *windows = [NSMutableArray array];
        id items = dictionary[@"windows"];
        if ([items isKindOfClass:NSArray.class]) {
            for (id item in items) {
                AccountUsageWindow *window = [item isKindOfClass:NSDictionary.class] ? [[AccountUsageWindow alloc] initWithDictionary:item] : nil;
                if (window) [windows addObject:window];
            }
        }
        self.windows = windows;
        _creditBalance = NumberOrNil(dictionary[@"creditBalance"]);
        _unlimitedCredits = [dictionary[@"unlimitedCredits"] boolValue];
        _fetchedAt = TimestampOrNil(dictionary[@"fetchedAt"]) ?: NSDate.distantPast;
    }
    return self;
}

- (void)setWindows:(NSArray<AccountUsageWindow *> *)windows {
    _windows = [windows sortedArrayUsingComparator:^NSComparisonResult(AccountUsageWindow *a, AccountUsageWindow *b) {
        return [@(a.windowSeconds) compare:@(b.windowSeconds)];
    }];
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
    dictionary[@"windows"] = [self.windows valueForKey:@"dictionaryRepresentation"];
    if (self.creditBalance) dictionary[@"creditBalance"] = self.creditBalance;
    if (self.unlimitedCredits) dictionary[@"unlimitedCredits"] = @YES;
    dictionary[@"fetchedAt"] = [TimestampFormatter() stringFromDate:self.fetchedAt];
    return dictionary;
}

- (AccountUsageWindow *)shortWindow {
    AccountUsageWindow *first = self.windows.firstObject;
    return first.windowSeconds <= 86400 ? first : nil;
}

- (AccountUsageWindow *)longWindow {
    AccountUsageWindow *last = self.windows.lastObject;
    return last.windowSeconds > 86400 ? last : nil;
}

- (NSNumber *)lowestRemainingPercent {
    NSNumber *lowest = nil;
    for (AccountUsageWindow *window in self.windows)
        if (!lowest || window.remainingPercent < lowest.doubleValue) lowest = @(window.remainingPercent);
    return lowest;
}
@end

#pragma mark - Authorizations

@implementation AccountAuthorization

- (instancetype)init {
    if ((self = [super init])) {
        _identifier = NSUUID.UUID.UUIDString;
        _appName = @"";
        _clientID = @"";
        _redirect = @"";
        _scope = @"";
        _note = @"";
        _source = @"manual";
        _firstAuthorizedAt = NSDate.date;
        _lastAuthorizedAt = _firstAuthorizedAt;
        _count = 1;
    }
    return self;
}

- (instancetype)initWithDictionary:(NSDictionary *)dictionary {
    if (![dictionary isKindOfClass:NSDictionary.class]) return nil;
    NSDate *last = TimestampOrNil(dictionary[@"lastAuthorizedAt"]);
    if (!last || !(StringOrNil(dictionary[@"appName"]) || StringOrNil(dictionary[@"clientID"]) || StringOrNil(dictionary[@"redirect"])))
        return nil;
    if ((self = [self init])) {
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:StringOrNil(dictionary[@"id"]) ?: @""];
        if (uuid) _identifier = uuid.UUIDString;
        self.appName = StringOrNil(dictionary[@"appName"]);
        self.clientID = StringOrNil(dictionary[@"clientID"]);
        self.redirect = StringOrNil(dictionary[@"redirect"]);
        self.scope = StringOrNil(dictionary[@"scope"]);
        self.note = StringOrNil(dictionary[@"note"]);
        self.source = StringOrNil(dictionary[@"source"]);
        _lastAuthorizedAt = last;
        _firstAuthorizedAt = TimestampOrNil(dictionary[@"firstAuthorizedAt"]) ?: last;
        _count = MAX(1, [NumberOrNil(dictionary[@"count"]) integerValue]);
        _revokedAt = TimestampOrNil(dictionary[@"revokedAt"]);
    }
    return self;
}

- (void)setAppName:(NSString *)appName { _appName = [Trimmed(appName) copy]; }
- (void)setClientID:(NSString *)clientID { _clientID = [Trimmed(clientID) copy]; }
- (void)setRedirect:(NSString *)redirect { _redirect = [Trimmed(redirect) copy]; }
- (void)setScope:(NSString *)scope { _scope = [Trimmed(scope) copy]; }
- (void)setNote:(NSString *)note { _note = [Trimmed(note) copy]; }
- (void)setSource:(NSString *)source { _source = [Trimmed(source).length ? Trimmed(source) : @"manual" copy]; }
- (BOOL)isRevoked { return self.revokedAt != nil; }

- (NSDictionary *)dictionaryRepresentation {
    NSMutableDictionary *dictionary = [@{@"id": self.identifier, @"source": self.source, @"count": @(self.count),
        @"firstAuthorizedAt": [TimestampFormatter() stringFromDate:self.firstAuthorizedAt],
        @"lastAuthorizedAt": [TimestampFormatter() stringFromDate:self.lastAuthorizedAt]} mutableCopy];
    if (self.appName.length) dictionary[@"appName"] = self.appName;
    if (self.clientID.length) dictionary[@"clientID"] = self.clientID;
    if (self.redirect.length) dictionary[@"redirect"] = self.redirect;
    if (self.scope.length) dictionary[@"scope"] = self.scope;
    if (self.note.length) dictionary[@"note"] = self.note;
    if (self.revokedAt) dictionary[@"revokedAt"] = [TimestampFormatter() stringFromDate:self.revokedAt];
    return dictionary;
}

- (BOOL)isSameAppAsClientID:(NSString *)clientID redirect:(NSString *)redirect {
    if (clientID.length && self.clientID.length) return [clientID isEqualToString:self.clientID];
    return redirect.length && [redirect isEqualToString:self.redirect];
}
@end

#pragma mark - Payments

@implementation AccountPayment

- (instancetype)initWithDictionary:(NSDictionary *)dictionary {
    if (![dictionary isKindOfClass:NSDictionary.class]) return nil;
    NSDate *day = AccountDateFromDayString(StringOrNil(dictionary[@"date"]));
    NSNumber *amount = NumberOrNil(dictionary[@"amount"]);
    if (!day || !amount) return nil;
    if ((self = [super init])) {
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:StringOrNil(dictionary[@"id"]) ?: @""];
        _identifier = (uuid ?: [NSUUID UUID]).UUIDString;
        _date = AccountDayString(day);
        _amount = amount;
        self.currency = StringOrNil(dictionary[@"currency"]);
        self.supplier = StringOrNil(dictionary[@"supplier"]);
        self.paymentMethod = StringOrNil(dictionary[@"paymentMethod"]);
        self.cardLast4 = StringOrNil(dictionary[@"cardLast4"]);
        self.note = StringOrNil(dictionary[@"note"]);
        self.source = StringOrNil(dictionary[@"source"]);
    }
    return self;
}

- (instancetype)init {
    if ((self = [super init])) {
        _identifier = NSUUID.UUID.UUIDString;
        _date = AccountDayString(NSDate.date);
        _amount = @0;
        _currency = @"";
        _supplier = @"";
        _paymentMethod = @"";
        _cardLast4 = @"";
        _note = @"";
        _source = @"manual";
    }
    return self;
}

- (void)setCurrency:(NSString *)currency { _currency = [Trimmed(currency).uppercaseString copy]; }
- (void)setSupplier:(NSString *)supplier { _supplier = [Trimmed(supplier) copy]; }
- (void)setPaymentMethod:(NSString *)paymentMethod { _paymentMethod = [Trimmed(paymentMethod) copy]; }
- (void)setCardLast4:(NSString *)cardLast4 { _cardLast4 = [AccountCardLast4(cardLast4) copy]; }
- (void)setNote:(NSString *)note { _note = [Trimmed(note) copy]; }
- (void)setSource:(NSString *)source { _source = [Trimmed(source).length ? Trimmed(source) : @"manual" copy]; }

- (NSDictionary *)dictionaryRepresentation {
    NSMutableDictionary *dictionary = [@{@"id": self.identifier, @"date": self.date, @"amount": self.amount, @"source": self.source}
        mutableCopy];
    if (self.currency.length) dictionary[@"currency"] = self.currency;
    if (self.supplier.length) dictionary[@"supplier"] = self.supplier;
    if (self.paymentMethod.length) dictionary[@"paymentMethod"] = self.paymentMethod;
    if (self.cardLast4.length) dictionary[@"cardLast4"] = self.cardLast4;
    if (self.note.length) dictionary[@"note"] = self.note;
    return dictionary;
}

- (BOOL)isSameChargeAs:(AccountPayment *)other {
    return [other.date isEqualToString:self.date] && [other.currency isEqualToString:self.currency] &&
        fabs(other.amount.doubleValue - self.amount.doubleValue) < 0.005;
}
@end

#pragma mark - Account

static NSArray<NSString *> *KnownKeys(void) {
    return @[@"id", @"name", @"email", @"plan", @"planSource", @"expiresAt", @"expirySource", @"autoRenew",
             @"monthlyPrice", @"currency", @"group", @"tags", @"notes", @"authURL", @"proxy", @"supplier", @"paymentMethod", @"cardLast4", @"payments", @"authorizations", @"createdAt", @"lastUsedAt",
             @"signedIn", @"usage"];
}

@implementation Account {
    NSDictionary *_extras;
}

+ (instancetype)accountWithName:(NSString *)name {
    Account *account = [[Account alloc] initWithDictionary:@{@"name": name ?: @""}];
    account.createdAt = NSDate.date;
    return account;
}

- (instancetype)init { return [self initWithDictionary:@{}]; }

- (instancetype)initWithDictionary:(NSDictionary *)dictionary {
    if ((self = [super init])) {
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:StringOrNil(dictionary[@"id"]) ?: @""];
        _identifier = (uuid ?: [NSUUID UUID]).UUIDString;
        NSString *name = Trimmed(StringOrNil(dictionary[@"name"]));
        _name = name.length ? name : @"未命名账号";
        _email = Trimmed(StringOrNil(dictionary[@"email"]));
        _plan = AccountCanonicalPlan(dictionary[@"plan"]);
        _planSource = _plan ? StringOrNil(dictionary[@"planSource"]) : nil;
        NSDate *expiry = AccountDateFromDayString(StringOrNil(dictionary[@"expiresAt"]));
        _expiresAt = expiry ? AccountDayString(expiry) : nil;
        _expirySource = _expiresAt ? StringOrNil(dictionary[@"expirySource"]) : nil;
        id autoRenew = dictionary[@"autoRenew"];
        _autoRenew = [autoRenew isKindOfClass:NSNumber.class] ? @([autoRenew boolValue]) : nil;
        _monthlyPrice = NumberOrNil(dictionary[@"monthlyPrice"]);
        _currency = Trimmed(StringOrNil(dictionary[@"currency"])).uppercaseString;
        _group = Trimmed(StringOrNil(dictionary[@"group"]));
        _tags = AccountNormalizedTags(dictionary[@"tags"]);
        _notes = StringOrNil(dictionary[@"notes"]) ?: @"";
        _authURL = Trimmed(StringOrNil(dictionary[@"authURL"]));
        _proxy = Trimmed(StringOrNil(dictionary[@"proxy"]));
        _supplier = Trimmed(StringOrNil(dictionary[@"supplier"]));
        _paymentMethod = Trimmed(StringOrNil(dictionary[@"paymentMethod"]));
        _cardLast4 = AccountCardLast4(StringOrNil(dictionary[@"cardLast4"]));
        NSMutableArray *payments = [NSMutableArray array];
        if ([dictionary[@"payments"] isKindOfClass:NSArray.class])
            for (id item in dictionary[@"payments"]) {
                AccountPayment *payment = [[AccountPayment alloc] initWithDictionary:item];
                if (payment) [payments addObject:payment];
            }
        self.payments = payments;
        NSMutableArray *authorizations = [NSMutableArray array];
        if ([dictionary[@"authorizations"] isKindOfClass:NSArray.class])
            for (id item in dictionary[@"authorizations"]) {
                AccountAuthorization *authorization = [[AccountAuthorization alloc] initWithDictionary:item];
                if (authorization) [authorizations addObject:authorization];
            }
        self.authorizations = authorizations;
        _createdAt = TimestampOrNil(dictionary[@"createdAt"]);
        _lastUsedAt = TimestampOrNil(dictionary[@"lastUsedAt"]);
        id signedIn = dictionary[@"signedIn"];
        _signedIn = [signedIn isKindOfClass:NSNumber.class] ? @([signedIn boolValue]) : nil;
        _usage = [dictionary[@"usage"] isKindOfClass:NSDictionary.class] ? [[AccountUsage alloc] initWithDictionary:dictionary[@"usage"]] : nil;
        NSMutableDictionary *extras = [dictionary mutableCopy];
        [extras removeObjectsForKeys:KnownKeys()];
        _extras = [extras copy];
    }
    return self;
}

- (void)setEmail:(NSString *)email { _email = [Trimmed(email) copy]; }
- (void)setGroup:(NSString *)group { _group = [Trimmed(group) copy]; }
- (void)setNotes:(NSString *)notes { _notes = [notes ?: @"" copy]; }
- (void)setAuthURL:(NSString *)authURL { _authURL = [Trimmed(authURL) copy]; }
- (void)setProxy:(NSString *)proxy { _proxy = [Trimmed(proxy) copy]; }
- (void)setSupplier:(NSString *)supplier { _supplier = [Trimmed(supplier) copy]; }
- (void)setPaymentMethod:(NSString *)paymentMethod { _paymentMethod = [Trimmed(paymentMethod) copy]; }
- (void)setCardLast4:(NSString *)cardLast4 { _cardLast4 = [AccountCardLast4(cardLast4) copy]; }
- (void)setPayments:(NSArray<AccountPayment *> *)payments {
    _payments = [payments ?: @[] sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(AccountPayment *a, AccountPayment *b) {
        return [b.date compare:a.date];
    }];
}

- (NSUInteger)addPayments:(NSArray<AccountPayment *> *)payments {
    NSMutableArray<AccountPayment *> *merged = [self.payments mutableCopy];
    NSUInteger added = 0;
    for (AccountPayment *payment in payments) {
        BOOL known = NO;
        for (AccountPayment *existing in merged)
            if ([existing.identifier isEqualToString:payment.identifier] || [existing isSameChargeAs:payment]) known = YES;
        if (known) continue;
        [merged addObject:payment];
        added++;
    }
    if (added) self.payments = merged;
    return added;
}

- (AccountPayment *)lastPayment { return self.payments.firstObject; }

- (void)setAuthorizations:(NSArray<AccountAuthorization *> *)authorizations {
    _authorizations = [authorizations ?: @[] sortedArrayWithOptions:NSSortStable
        usingComparator:^NSComparisonResult(AccountAuthorization *a, AccountAuthorization *b) {
            return [b.lastAuthorizedAt compare:a.lastAuthorizedAt];
        }];
}

- (NSArray<AccountAuthorization *> *)activeAuthorizations {
    return [self.authorizations filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(AccountAuthorization *item, id bindings) {
        return !item.revoked;
    }]];
}

- (AccountAuthorization *)recordAuthorizationWithClientID:(NSString *)clientID redirect:(NSString *)redirect scope:(NSString *)scope
    appName:(NSString *)appName at:(NSDate *)date {
    for (AccountAuthorization *existing in self.authorizations) {
        if (![existing isSameAppAsClientID:clientID redirect:redirect]) continue;
        existing.lastAuthorizedAt = date;
        existing.count += 1;
        existing.revokedAt = nil;
        if (scope.length) existing.scope = scope;
        if (redirect.length) existing.redirect = redirect;
        if (!existing.appName.length) existing.appName = appName;
        self.authorizations = self.authorizations;
        return existing;
    }
    AccountAuthorization *authorization = [AccountAuthorization new];
    authorization.appName = appName;
    authorization.clientID = clientID;
    authorization.redirect = redirect;
    authorization.scope = scope;
    authorization.source = @"app";
    authorization.firstAuthorizedAt = date;
    authorization.lastAuthorizedAt = date;
    self.authorizations = [self.authorizations arrayByAddingObject:authorization];
    return authorization;
}

- (NSString *)paymentSummary {
    NSMutableArray *parts = [NSMutableArray array];
    if (self.supplier.length) [parts addObject:self.supplier];
    if (self.paymentMethod.length) [parts addObject:self.paymentMethod];
    if (self.cardLast4.length) [parts addObject:[@"尾号 " stringByAppendingString:self.cardLast4]];
    return [parts componentsJoinedByString:@" · "];
}
- (void)setCurrency:(NSString *)currency { _currency = [Trimmed(currency).uppercaseString copy]; }
- (void)setTags:(NSArray<NSString *> *)tags { _tags = AccountNormalizedTags(tags); }

- (NSDictionary *)dictionaryRepresentation {
    NSMutableDictionary *dictionary = [_extras mutableCopy] ?: [NSMutableDictionary dictionary];
    dictionary[@"id"] = self.identifier;
    dictionary[@"name"] = self.name;
    if (self.email.length) dictionary[@"email"] = self.email;
    if (self.plan) {
        dictionary[@"plan"] = self.plan;
        if (self.planSource) dictionary[@"planSource"] = self.planSource;
    }
    if (self.expiresAt) {
        dictionary[@"expiresAt"] = self.expiresAt;
        if (self.expirySource) dictionary[@"expirySource"] = self.expirySource;
    }
    if (self.autoRenew) dictionary[@"autoRenew"] = self.autoRenew;
    if (self.monthlyPrice) dictionary[@"monthlyPrice"] = self.monthlyPrice;
    if (self.currency.length) dictionary[@"currency"] = self.currency;
    if (self.group.length) dictionary[@"group"] = self.group;
    if (self.tags.count) dictionary[@"tags"] = self.tags;
    if (self.notes.length) dictionary[@"notes"] = self.notes;
    if (self.authURL.length) dictionary[@"authURL"] = self.authURL;
    if (self.proxy.length) dictionary[@"proxy"] = self.proxy;
    if (self.supplier.length) dictionary[@"supplier"] = self.supplier;
    if (self.paymentMethod.length) dictionary[@"paymentMethod"] = self.paymentMethod;
    if (self.cardLast4.length) dictionary[@"cardLast4"] = self.cardLast4;
    if (self.payments.count) dictionary[@"payments"] = [self.payments valueForKey:@"dictionaryRepresentation"];
    if (self.authorizations.count) dictionary[@"authorizations"] = [self.authorizations valueForKey:@"dictionaryRepresentation"];
    if (self.createdAt) dictionary[@"createdAt"] = [TimestampFormatter() stringFromDate:self.createdAt];
    if (self.lastUsedAt) dictionary[@"lastUsedAt"] = [TimestampFormatter() stringFromDate:self.lastUsedAt];
    if (self.signedIn) dictionary[@"signedIn"] = self.signedIn;
    if (self.usage) dictionary[@"usage"] = self.usage.dictionaryRepresentation;
    return dictionary;
}

- (NSDictionary *)exportRepresentation {
    // Login state, usage and usage time describe this Mac's session, not the account.
    NSMutableDictionary *dictionary = [[self dictionaryRepresentation] mutableCopy];
    [dictionary removeObjectsForKeys:@[@"lastUsedAt", @"signedIn", @"usage"]];
    // Exports and backups may leave this Mac, so a proxy password stays behind.
    NSURLComponents *proxy = self.proxy.length ? [NSURLComponents componentsWithString:self.proxy] : nil;
    if (proxy.password.length) {
        proxy.password = nil;
        dictionary[@"proxy"] = proxy.string ?: @"";
    }
    return dictionary;
}

- (void)applyProfileFrom:(Account *)other {
    self.name = other.name;
    if (other.email.length) self.email = other.email;
    if (other.plan) { self.plan = other.plan; self.planSource = other.planSource; }
    if (other.expiresAt) { self.expiresAt = other.expiresAt; self.expirySource = other.expirySource; }
    if (other.autoRenew) self.autoRenew = other.autoRenew;
    if (other.monthlyPrice) { self.monthlyPrice = other.monthlyPrice; self.currency = other.currency; }
    if (other.group.length) self.group = other.group;
    if (other.tags.count) self.tags = [self.tags arrayByAddingObjectsFromArray:other.tags];
    if (other.notes.length) self.notes = other.notes;
    if (other.authURL.length) self.authURL = other.authURL;
    if (other.proxy.length) self.proxy = other.proxy;
    if (other.supplier.length) self.supplier = other.supplier;
    if (other.paymentMethod.length) self.paymentMethod = other.paymentMethod;
    if (other.cardLast4.length) self.cardLast4 = other.cardLast4;
    [self addPayments:other.payments];
    NSMutableArray<AccountAuthorization *> *authorizations = [self.authorizations mutableCopy];
    for (AccountAuthorization *incoming in other.authorizations) {
        AccountAuthorization *match = nil;
        for (AccountAuthorization *existing in authorizations)
            if ([existing.identifier isEqualToString:incoming.identifier] ||
                [existing isSameAppAsClientID:incoming.clientID redirect:incoming.redirect]) match = existing;
        if (!match) [authorizations addObject:incoming];
        else if ([incoming.lastAuthorizedAt compare:match.lastAuthorizedAt] == NSOrderedDescending)
            [authorizations replaceObjectAtIndex:[authorizations indexOfObject:match] withObject:incoming];
    }
    self.authorizations = authorizations;
    if (other.createdAt && (!self.createdAt || [other.createdAt compare:self.createdAt] == NSOrderedAscending))
        self.createdAt = other.createdAt;
}

- (BOOL)applyDetectedPlan:(NSString *)plan source:(NSString *)source {
    NSString *canonical = AccountCanonicalPlan(plan);
    if (!canonical) return NO;
    // Usage and session APIs only say "pro"; the tier comes from the billing page.
    if ([canonical isEqualToString:@"Pro"] && [self.plan hasPrefix:@"Pro "]) canonical = self.plan;
    if ([canonical isEqualToString:self.plan] && [source isEqualToString:self.planSource]) return NO;
    self.plan = canonical;
    self.planSource = source;
    return YES;
}

- (NSString *)planTitle { return self.plan ?: @"未获取"; }
- (NSString *)planFamily { return AccountPlanFamily(self.plan); }
- (BOOL)isPaid { return self.plan && ![self.plan isEqualToString:@"Free"]; }
- (NSInteger)planRank { return self.plan ? (NSInteger)[AccountPlans() indexOfObject:self.plan] + 1 : 0; }

- (NSNumber *)daysRemainingFromDate:(NSDate *)now {
    NSDate *expiry = AccountDateFromDayString(self.expiresAt);
    if (!expiry) return nil;
    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSDateComponents *difference = [calendar components:NSCalendarUnitDay
        fromDate:[calendar startOfDayForDate:now] toDate:[calendar startOfDayForDate:expiry] options:0];
    return @(difference.day);
}

- (AccountExpiryState)expiryStateFromDate:(NSDate *)now {
    NSNumber *days = [self daysRemainingFromDate:now];
    if (!days) return AccountExpiryStateUnknown;
    if (self.autoRenew.boolValue) return AccountExpiryStateRenewing;
    if (days.integerValue < 0) return AccountExpiryStateExpired;
    if (days.integerValue <= AccountExpiringSoonDays) return AccountExpiryStateExpiringSoon;
    return AccountExpiryStateActive;
}

- (NSString *)expiryDescriptionFromDate:(NSDate *)now {
    NSNumber *days = [self daysRemainingFromDate:now];
    if (!days) return @"未设置到期";
    NSInteger value = days.integerValue;
    if (self.autoRenew.boolValue) {
        if (value < 0) return @"续费日已过，待刷新";
        if (value == 0) return @"今天续费";
        return [NSString stringWithFormat:@"%ld 天后续费", (long)value];
    }
    if (value < 0) return [NSString stringWithFormat:@"已过期 %ld 天", (long)-value];
    if (value == 0) return @"今天到期";
    return [NSString stringWithFormat:@"剩余 %ld 天", (long)value];
}

- (NSString *)renewalDescription {
    NSDate *date = AccountDateFromDayString(self.expiresAt);
    if (!date) return @"未设置到期";
    NSDateComponents *parts = [NSCalendar.currentCalendar components:NSCalendarUnitMonth | NSCalendarUnitDay fromDate:date];
    return [NSString stringWithFormat:@"%ld月%ld日%@", (long)parts.month, (long)parts.day,
        self.autoRenew.boolValue ? @"自动续费" : @"到期"];
}

- (NSString *)compactRenewalDescriptionFromDate:(NSDate *)now {
    NSDate *date = AccountDateFromDayString(self.expiresAt);
    NSNumber *days = [self daysRemainingFromDate:now];
    if (!date || !days) return @"";
    NSDateComponents *parts = [NSCalendar.currentCalendar components:NSCalendarUnitMonth | NSCalendarUnitDay fromDate:date];
    NSString *day = [NSString stringWithFormat:@"%ld/%ld", (long)parts.month, (long)parts.day];
    NSInteger value = days.integerValue;
    if (self.autoRenew.boolValue) {
        if (value < 0) return [day stringByAppendingString:@" 续费 · 待刷新"];
        return value == 0 ? @"今天续费" : [NSString stringWithFormat:@"%@ 续费 · %ld 天", day, (long)value];
    }
    if (value < 0) return [day stringByAppendingString:@" 已过期"];
    return value == 0 ? @"今天到期" : [NSString stringWithFormat:@"%@ 到期 · %ld 天", day, (long)value];
}

- (BOOL)matchesSearch:(NSString *)query {
    NSString *needle = Trimmed(query);
    if (!needle.length) return YES;
    NSArray *fields = [[@[self.name, self.email, self.group, self.notes, self.plan ?: @"", self.supplier, self.paymentMethod,
        self.cardLast4] arrayByAddingObjectsFromArray:self.tags] arrayByAddingObjectsFromArray:[self.authorizations valueForKey:@"appName"]];
    for (NSString *field in fields)
        if ([field localizedCaseInsensitiveContainsString:needle]) return YES;
    return NO;
}
@end

static NSArray *AccountItemsFromJSON(NSData *data, NSError **error) {
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if ([json isKindOfClass:NSArray.class]) return json;
    if ([json isKindOfClass:NSDictionary.class] && [json[@"accounts"] isKindOfClass:NSArray.class]) return json[@"accounts"];
    if (json && error) {
        *error = [NSError errorWithDomain:AccountStoreErrorDomain code:1
            userInfo:@{NSLocalizedDescriptionKey: @"文件中没有可识别的账号列表。"}];
    }
    return nil;
}

@implementation AccountStore {
    NSMutableArray<Account *> *_accounts;
    BOOL _readOnly;
}

- (instancetype)initWithFileURL:(NSURL *)fileURL {
    if ((self = [super init])) {
        _fileURL = fileURL;
        _accounts = [NSMutableArray array];
    }
    return self;
}

- (NSArray<Account *> *)accounts { return [_accounts copy]; }

- (BOOL)load:(NSError **)error {
    [_accounts removeAllObjects];
    _recoveredBackupURL = nil;
    _readOnly = NO;
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfURL:self.fileURL options:0 error:&readError];
    if (!data) {
        if ([readError.domain isEqualToString:NSCocoaErrorDomain] && readError.code == NSFileReadNoSuchFileError) return YES;
        // Keep the unreadable file intact instead of overwriting it with an empty list.
        _readOnly = YES;
        if (error) *error = readError;
        return NO;
    }
    NSError *parseError = nil;
    NSArray *items = AccountItemsFromJSON(data, &parseError);
    if (!items) {
        NSDateFormatter *formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyyMMdd-HHmmss";
        NSString *name = [NSString stringWithFormat:@"accounts.unreadable-%@.json", [formatter stringFromDate:NSDate.date]];
        NSURL *backup = [self.fileURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:name];
        if ([NSFileManager.defaultManager copyItemAtURL:self.fileURL toURL:backup error:nil]) _recoveredBackupURL = backup;
        else _readOnly = YES;
        if (error) *error = parseError;
        return NO;
    }
    [self mergeItems:items added:NULL updated:NULL];
    return YES;
}

- (BOOL)save:(NSError **)error {
    if (_readOnly) {
        if (error) *error = [NSError errorWithDomain:AccountStoreErrorDomain code:2
            userInfo:@{NSLocalizedDescriptionKey: @"启动时未能读取账号列表文件，为避免覆盖原文件已暂停保存。请检查文件权限后重新打开应用。"}];
        return NO;
    }
    NSMutableArray *items = [NSMutableArray arrayWithCapacity:_accounts.count];
    for (Account *account in _accounts) [items addObject:account.dictionaryRepresentation];
    NSData *data = [NSJSONSerialization dataWithJSONObject:items
        options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes error:error];
    if (!data) return NO;
    [NSFileManager.defaultManager createDirectoryAtURL:self.fileURL.URLByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:nil];
    return [data writeToURL:self.fileURL options:NSDataWritingAtomic error:error];
}

- (void)commit {
    NSError *error = nil;
    if (![self save:&error] && self.saveFailed) self.saveFailed(error);
    [NSNotificationCenter.defaultCenter postNotificationName:AccountStoreDidChangeNotification object:self];
}

- (Account *)accountWithID:(NSString *)identifier {
    if (!identifier) return nil;
    for (Account *account in _accounts)
        if ([account.identifier isEqualToString:identifier]) return account;
    return nil;
}

- (NSArray<Account *> *)accountsWithIDs:(NSArray<NSString *> *)identifiers {
    NSSet *wanted = [NSSet setWithArray:identifiers];
    NSMutableArray *result = [NSMutableArray array];
    for (Account *account in _accounts)
        if ([wanted containsObject:account.identifier]) [result addObject:account];
    return result;
}

- (Account *)addAccountNamed:(NSString *)name group:(NSString *)group {
    Account *account = [Account accountWithName:name];
    account.group = group;
    [_accounts addObject:account];
    return account;
}

- (void)removeAccountsWithIDs:(NSArray<NSString *> *)identifiers {
    [_accounts removeObjectsInArray:[self accountsWithIDs:identifiers]];
}

- (void)moveAccountsWithIDs:(NSArray<NSString *> *)identifiers toIndex:(NSUInteger)index {
    NSSet *moving = [NSSet setWithArray:identifiers];
    NSMutableArray<Account *> *moved = [NSMutableArray array];
    NSUInteger movedBeforeIndex = 0;
    for (NSUInteger position = 0; position < _accounts.count; position++) {
        if (![moving containsObject:_accounts[position].identifier]) continue;
        [moved addObject:_accounts[position]];
        if (position < index) movedBeforeIndex++;
    }
    if (!moved.count) return;
    [_accounts removeObjectsInArray:moved];
    NSUInteger target = MIN(index - movedBeforeIndex, _accounts.count);
    [_accounts insertObjects:moved atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(target, moved.count)]];
}

- (NSArray<NSString *> *)groups {
    NSMutableOrderedSet *groups = [NSMutableOrderedSet orderedSet];
    for (Account *account in _accounts) if (account.group.length) [groups addObject:account.group];
    return [groups.array sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}

- (NSArray<NSString *> *)tags {
    NSMutableOrderedSet *tags = [NSMutableOrderedSet orderedSet];
    for (Account *account in _accounts) [tags addObjectsFromArray:account.tags];
    return [tags.array sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}

- (NSArray<NSString *> *)orderedValues:(NSArray<NSString *> *)defaults key:(NSString *)key {
    NSMutableOrderedSet *values = [NSMutableOrderedSet orderedSetWithArray:defaults];
    NSMutableArray *extra = [NSMutableArray array];
    for (Account *account in _accounts) {
        NSString *value = [account valueForKey:key];
        if (value.length && ![values containsObject:value] && ![extra containsObject:value]) [extra addObject:value];
    }
    [values addObjectsFromArray:[extra sortedArrayUsingSelector:@selector(localizedStandardCompare:)]];
    return values.array;
}

- (NSArray<NSString *> *)suppliers { return [self orderedValues:AccountSuppliers() key:@"supplier"]; }
- (NSArray<NSString *> *)paymentMethods { return [self orderedValues:AccountPaymentMethods() key:@"paymentMethod"]; }

- (NSArray<NSString *> *)authorizedApps {
    NSMutableSet *names = [NSMutableSet set];
    for (Account *account in _accounts)
        for (AccountAuthorization *authorization in account.activeAuthorizations)
            if (authorization.appName.length) [names addObject:authorization.appName];
    return [names.allObjects sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}

- (double)monthlySpendInCNYWithRates:(NSDictionary<NSString *, NSNumber *> *)rates missingCurrencies:(NSArray<NSString *> **)missing {
    __block double total = 0;
    NSMutableOrderedSet *unconverted = [NSMutableOrderedSet orderedSet];
    [self.monthlySpendByCurrency enumerateKeysAndObjectsUsingBlock:^(NSString *currency, NSNumber *amount, BOOL *stop) {
        NSNumber *converted = AccountAmountInCNY(amount, currency, rates);
        if (converted) total += converted.doubleValue;
        else [unconverted addObject:currency.length ? currency : @"未填币种"];
    }];
    if (missing) *missing = [unconverted.array sortedArrayUsingSelector:@selector(compare:)];
    return total;
}

static NSString *CSVField(NSString *value) {
    NSString *text = value ?: @"";
    if ([text rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@",\"\n\r"]].location == NSNotFound) return text;
    return [NSString stringWithFormat:@"\"%@\"", [text stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]];
}

- (NSData *)paymentsCSVWithRates:(NSDictionary<NSString *, NSNumber *> *)rates {
    NSMutableArray<NSArray *> *rows = [NSMutableArray array];
    for (Account *account in _accounts)
        for (AccountPayment *payment in account.payments) [rows addObject:@[payment, account]];
    [rows sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        return [((AccountPayment *)b[0]).date compare:((AccountPayment *)a[0]).date];
    }];
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObject:@"日期,账号,邮箱,订阅,供应商,付款方式,卡尾号,金额,币种,折合人民币,备注,来源"];
    for (NSArray *row in rows) {
        AccountPayment *payment = row[0];
        Account *account = row[1];
        NSNumber *cny = AccountAmountInCNY(payment.amount, payment.currency, rates);
        NSArray *fields = @[payment.date, account.name, account.email, account.plan ?: @"", payment.supplier, payment.paymentMethod,
            payment.cardLast4, payment.amount.stringValue, payment.currency, cny ? [NSString stringWithFormat:@"%.2f", cny.doubleValue] : @"",
            payment.note, [payment.source isEqualToString:@"page"] ? @"账单页" : @"手动"];
        NSMutableArray *escaped = [NSMutableArray array];
        for (NSString *field in fields) [escaped addObject:CSVField(field)];
        [lines addObject:[escaped componentsJoinedByString:@","]];
    }
    NSString *csv = [@"\uFEFF" stringByAppendingString:[[lines componentsJoinedByString:@"\r\n"] stringByAppendingString:@"\r\n"]];
    return [csv dataUsingEncoding:NSUTF8StringEncoding];
}

- (NSDictionary<NSString *, NSNumber *> *)monthlySpendByCurrency {
    NSMutableDictionary<NSString *, NSNumber *> *totals = [NSMutableDictionary dictionary];
    for (Account *account in _accounts) {
        if (!account.isPaid || !account.monthlyPrice) continue;
        NSString *currency = account.currency.length ? account.currency : @"";
        totals[currency] = @(totals[currency].doubleValue + account.monthlyPrice.doubleValue);
    }
    return totals;
}

- (NSData *)exportDataForAccountIDs:(NSArray<NSString *> *)identifiers error:(NSError **)error {
    NSArray<Account *> *accounts = identifiers ? [self accountsWithIDs:identifiers] : _accounts;
    NSMutableArray *items = [NSMutableArray arrayWithCapacity:accounts.count];
    for (Account *account in accounts) [items addObject:account.exportRepresentation];
    NSDictionary *payload = @{
        @"format": @"chatgpt-account-desk",
        @"version": @1,
        @"exportedAt": [TimestampFormatter() stringFromDate:NSDate.date],
        @"accounts": items
    };
    return [NSJSONSerialization dataWithJSONObject:payload
        options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes error:error];
}

- (BOOL)importData:(NSData *)data added:(NSUInteger *)added updated:(NSUInteger *)updated error:(NSError **)error {
    NSArray *items = AccountItemsFromJSON(data, error);
    if (!items) return NO;
    [self mergeItems:items added:added updated:updated];
    return YES;
}

- (void)mergeItems:(NSArray *)items added:(NSUInteger *)added updated:(NSUInteger *)updated {
    NSUInteger addedCount = 0, updatedCount = 0;
    for (id item in items) {
        if (![item isKindOfClass:NSDictionary.class] || !Trimmed(StringOrNil(item[@"name"])).length) continue;
        Account *incoming = [[Account alloc] initWithDictionary:item];
        Account *existing = [self accountWithID:incoming.identifier];
        if (existing) {
            [existing applyProfileFrom:incoming];
            updatedCount++;
        } else {
            [_accounts addObject:incoming];
            addedCount++;
        }
    }
    if (added) *added = addedCount;
    if (updated) *updated = updatedCount;
}
@end
