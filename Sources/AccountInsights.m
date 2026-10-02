#import "AccountInsights.h"
#import "Account.h"

double const AccountLowQuotaPercent = 20;

@implementation AccountStatus

- (instancetype)initWithKind:(AccountStatusKind)kind tone:(AccountStatusTone)tone title:(NSString *)title symbol:(NSString *)symbol {
    if ((self = [super init])) {
        _kind = kind;
        _tone = tone;
        _title = [title copy];
        _symbol = [symbol copy];
    }
    return self;
}

+ (instancetype)statusForAccount:(Account *)account now:(NSDate *)now {
    AccountExpiryState state = [account expiryStateFromDate:now];
    NSNumber *lowest = account.usage.lowestRemainingPercent;
    if (account.signedIn && !account.signedIn.boolValue)
        return [[self alloc] initWithKind:AccountStatusSignedOut tone:AccountStatusToneCritical title:@"未登录"
            symbol:@"person.crop.circle.badge.exclamationmark"];
    if (state == AccountExpiryStateExpired)
        return [[self alloc] initWithKind:AccountStatusExpired tone:AccountStatusToneCritical title:@"已过期" symbol:@"xmark.circle.fill"];
    if (lowest && lowest.doubleValue < AccountLowQuotaPercent)
        return [[self alloc] initWithKind:AccountStatusQuotaLow tone:AccountStatusToneCritical
            title:[NSString stringWithFormat:@"额度剩 %.0f%%", lowest.doubleValue] symbol:@"gauge.with.dots.needle.0percent"];
    if (state == AccountExpiryStateExpiringSoon) {
        NSInteger days = [account daysRemainingFromDate:now].integerValue;
        return [[self alloc] initWithKind:AccountStatusExpiringSoon tone:AccountStatusToneWarning
            title:days == 0 ? @"今天到期" : [NSString stringWithFormat:@"%ld 天后到期", (long)days] symbol:@"clock.badge.exclamationmark"];
    }
    if (account.refreshError.length)
        return [[self alloc] initWithKind:AccountStatusRefreshFailed tone:AccountStatusToneWarning title:@"读取失败"
            symbol:@"exclamationmark.triangle.fill"];
    return [[self alloc] initWithKind:AccountStatusNormal tone:AccountStatusToneNeutral title:@"正常" symbol:@"checkmark.circle"];
}
@end

NSDictionary<NSString *, NSArray<Account *> *> *AccountDuplicateEmails(NSArray<Account *> *accounts) {
    NSMutableDictionary<NSString *, NSMutableArray<Account *> *> *byEmail = [NSMutableDictionary dictionary];
    for (Account *account in accounts) {
        NSString *email = account.email.lowercaseString;
        if (!email.length) continue;
        if (!byEmail[email]) byEmail[email] = [NSMutableArray array];
        [byEmail[email] addObject:account];
    }
    NSMutableDictionary *duplicates = [NSMutableDictionary dictionary];
    [byEmail enumerateKeysAndObjectsUsingBlock:^(NSString *email, NSMutableArray<Account *> *matches, BOOL *stop) {
        if (matches.count > 1) duplicates[email] = [matches copy];
    }];
    return duplicates;
}

#pragma mark - Alerts

static NSMutableDictionary *MutableEntry(NSMutableDictionary *state, NSString *key) {
    id value = state[key];
    NSMutableDictionary *entry = [value isKindOfClass:NSDictionary.class] ? [value mutableCopy] : [NSMutableDictionary dictionary];
    state[key] = entry;
    return entry;
}

static NSMutableArray *MutableList(NSMutableDictionary *state, NSString *key) {
    id value = state[key];
    NSMutableArray *list = [value isKindOfClass:NSArray.class] ? [value mutableCopy] : [NSMutableArray array];
    state[key] = list;
    return list;
}

/// Identifies one period of a usage window: its reset time, or the day when the reset time is unknown.
static NSString *WindowPeriod(AccountUsageWindow *window, NSDate *now) {
    if (window.resetAt) return [NSString stringWithFormat:@"%.0f", window.resetAt.timeIntervalSince1970];
    return AccountDayString(now);
}

/// Reported reset times drift a little between reads of the same period.
static BOOL SamePeriod(id stored, NSString *period) {
    if (![stored isKindOfClass:NSString.class]) return NO;
    if ([stored isEqualToString:period]) return YES;
    BOOL timestamps = ![stored containsString:@"-"] && ![period containsString:@"-"];
    return timestamps && fabs([stored doubleValue] - period.doubleValue) < 1800;
}

static NSString *ResetPhrase(NSDate *resetAt, NSDate *now) {
    if (!resetAt) return nil;
    NSTimeInterval seconds = [resetAt timeIntervalSinceDate:now];
    if (seconds <= 0) return @"即将重置";
    if (seconds < 3600) return [NSString stringWithFormat:@"%.0f 分钟后重置", ceil(seconds / 60)];
    if (seconds < 86400) return [NSString stringWithFormat:@"%.0f 小时后重置", round(seconds / 3600)];
    return [NSString stringWithFormat:@"%.0f 天后重置", round(seconds / 86400)];
}

void AccountAlertsForgetSignIn(NSMutableDictionary *state, NSArray<NSString *> *identifiers) {
    [MutableList(state, @"signedIn") removeObjectsInArray:identifiers];
}

NSArray<NSDictionary<NSString *, NSString *> *> *AccountAlertsDue(NSArray<Account *> *accounts, NSDate *now,
    NSMutableDictionary *state, AccountAlertKinds kinds) {
    NSMutableArray *alerts = [NSMutableArray array];
    NSMutableDictionary *quota = MutableEntry(state, @"quota");
    NSMutableArray *signedIn = MutableList(state, @"signedIn");
    NSMutableArray *renewals = MutableList(state, @"renewal");
    NSSet *known = [NSSet setWithArray:[accounts valueForKey:@"identifier"]];
    for (NSString *key in quota.allKeys)
        if (![known containsObject:[key componentsSeparatedByString:@"."].firstObject]) [quota removeObjectForKey:key];
    [signedIn filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *identifier, NSDictionary *bindings) {
        return [known containsObject:identifier];
    }]];
    NSString *today = AccountDayString(now);
    [renewals filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *key, NSDictionary *bindings) {
        NSArray *parts = [key componentsSeparatedByString:@"|"];
        return parts.count == 3 && [known containsObject:parts[0]] && [parts[1] compare:today] != NSOrderedAscending;
    }]];

    for (Account *account in accounts) {
        NSString *identifier = account.identifier;
        if (kinds & AccountAlertQuota) {
            NSMutableArray<NSString *> *low = [NSMutableArray array], *recovered = [NSMutableArray array];
            NSDate *soonestReset = nil;
            for (AccountUsageWindow *window in account.usage.windows) {
                NSString *key = [NSString stringWithFormat:@"%@.%ld", identifier, (long)window.windowSeconds];
                NSString *period = WindowPeriod(window, now);
                if (window.remainingPercent < AccountLowQuotaPercent) {
                    if (SamePeriod(quota[key], period)) continue;
                    quota[key] = period;
                    [low addObject:[NSString stringWithFormat:@"%@剩 %.0f%%", window.title, window.remainingPercent]];
                    if (window.resetAt && (!soonestReset || [window.resetAt compare:soonestReset] == NSOrderedAscending))
                        soonestReset = window.resetAt;
                } else if (quota[key] && window.remainingPercent >= 50) {
                    [quota removeObjectForKey:key];
                    [recovered addObject:window.title];
                }
            }
            if (low.count) {
                NSString *reset = ResetPhrase(soonestReset, now);
                [alerts addObject:@{@"id": [NSString stringWithFormat:@"quota.%@.%.0f", identifier, now.timeIntervalSince1970],
                    @"kind": @"quota", @"accountID": identifier,
                    @"title": [NSString stringWithFormat:@"“%@”额度告急：%@", account.name, [low componentsJoinedByString:@"、"]],
                    @"body": reset ? [NSString stringWithFormat:@"%@。", reset] : @"额度即将用完。"}];
            } else if (recovered.count) {
                [alerts addObject:@{@"id": [NSString stringWithFormat:@"reset.%@.%.0f", identifier, now.timeIntervalSince1970],
                    @"kind": @"reset", @"accountID": identifier,
                    @"title": [NSString stringWithFormat:@"“%@”额度已恢复", account.name],
                    @"body": [NSString stringWithFormat:@"%@额度已重置，可以继续使用。", [recovered componentsJoinedByString:@"、"]]}];
            }
        }

        if (account.signedIn.boolValue) {
            if (![signedIn containsObject:identifier]) [signedIn addObject:identifier];
        } else if (account.signedIn && [signedIn containsObject:identifier]) {
            [signedIn removeObject:identifier];
            if (kinds & AccountAlertSignedOut)
                [alerts addObject:@{@"id": [NSString stringWithFormat:@"signedout.%@.%.0f", identifier, now.timeIntervalSince1970],
                    @"kind": @"signedOut", @"accountID": identifier,
                    @"title": [NSString stringWithFormat:@"“%@”登录已失效", account.name],
                    @"body": @"请在浏览模式中打开此账号重新登录，否则无法读取用量。"}];
        }

        NSNumber *days = [account daysRemainingFromDate:now];
        if (!(kinds & AccountAlertRenewal) || !days || days.integerValue < 0) continue;
        NSInteger left = days.integerValue;
        BOOL renews = account.autoRenew.boolValue;
        NSString *bucket = renews ? (left <= 1 ? @"renew" : nil) : (left == 0 ? @"0" : (left == 1 ? @"1" : (left <= 3 ? @"3" : nil)));
        if (!bucket) continue;
        NSString *key = [NSString stringWithFormat:@"%@|%@|%@", identifier, account.expiresAt, bucket];
        if ([renewals containsObject:key]) continue;
        [renewals addObject:key];
        NSString *when = left == 0 ? @"今天" : (left == 1 ? @"明天" : [NSString stringWithFormat:@"%ld 天后", (long)left]);
        NSString *price = account.monthlyPrice ? AccountFormatMoney(account.monthlyPrice, account.currency) : nil;
        NSString *title = renews ? [NSString stringWithFormat:@"“%@”%@自动续费", account.name, when]
                                 : [NSString stringWithFormat:@"“%@”%@到期", account.name, when];
        NSString *body = renews
            ? [NSString stringWithFormat:@"%@%@，如不再需要请提前取消订阅。", account.planTitle, price ? [@" · " stringByAppendingString:price] : @""]
            : [NSString stringWithFormat:@"%@ 将在 %@ 到期，到期后需要重新订阅。", account.planTitle, account.expiresAt];
        [alerts addObject:@{@"id": [@"renewal." stringByAppendingString:key], @"kind": @"renewal", @"accountID": identifier,
            @"title": title, @"body": body}];
    }
    return alerts;
}

#pragma mark - Calendar

static NSString *CalendarText(NSString *text) {
    return [[[[text stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
        stringByReplacingOccurrencesOfString:@";" withString:@"\\;"]
        stringByReplacingOccurrencesOfString:@"," withString:@"\\,"]
        stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
}

/// Folds a content line at 75 octets without splitting a UTF-8 character (RFC 5545 §3.1).
static NSString *FoldedLine(NSString *line) {
    NSMutableString *result = [NSMutableString string];
    __block NSUInteger octets = 0;
    [line enumerateSubstringsInRange:NSMakeRange(0, line.length) options:NSStringEnumerationByComposedCharacterSequences
        usingBlock:^(NSString *character, NSRange range, NSRange enclosing, BOOL *stop) {
            NSUInteger size = [character lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            if (octets + size > 75) {
                [result appendString:@"\r\n "];
                octets = 1;
            }
            [result appendString:character];
            octets += size;
        }];
    return result;
}

NSString *AccountRenewalCalendar(NSArray<Account *> *accounts) {
    NSDateFormatter *stamp = [NSDateFormatter new];
    stamp.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    stamp.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    stamp.dateFormat = @"yyyyMMdd'T'HHmmss'Z'";
    NSDateFormatter *day = [NSDateFormatter new];
    day.locale = stamp.locale;
    day.dateFormat = @"yyyyMMdd";
    NSString *now = [stamp stringFromDate:NSDate.date];
    NSMutableArray<NSString *> *lines = [@[@"BEGIN:VCALENDAR", @"VERSION:2.0", @"PRODID:-//Zhishu Matrix//Renewals//ZH",
                                          @"CALSCALE:GREGORIAN", @"X-WR-CALNAME:智枢矩阵 · 续费与到期"] mutableCopy];
    for (Account *account in accounts) {
        NSDate *date = AccountDateFromDayString(account.expiresAt);
        if (!date) continue;
        BOOL renews = account.autoRenew.boolValue;
        NSString *price = account.monthlyPrice ? AccountFormatMoney(account.monthlyPrice, account.currency) : nil;
        NSString *summary = renews
            ? [NSString stringWithFormat:@"%@ 自动续费%@", account.name, price ? [NSString stringWithFormat:@"（%@）", price] : @""]
            : [NSString stringWithFormat:@"%@ 订阅到期", account.name];
        NSMutableArray *details = [NSMutableArray arrayWithObject:[@"订阅：" stringByAppendingString:account.planTitle]];
        if (account.email.length) [details addObject:[@"邮箱：" stringByAppendingString:account.email]];
        if (account.tags.count) [details addObject:[@"标签：" stringByAppendingString:[account.tags componentsJoinedByString:@"、"]]];
        if (account.paymentSummary.length) [details addObject:[@"付款：" stringByAppendingString:account.paymentSummary]];
        NSNumber *cny = AccountAmountInCNY(account.monthlyPrice, account.currency, AccountExchangeRates());
        if (cny && ![account.currency isEqualToString:@"CNY"]) [details addObject:[@"折合：" stringByAppendingString:AccountFormatCNY(cny)]];
        NSDate *next = [NSCalendar.currentCalendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:date options:0];
        [lines addObjectsFromArray:@[
            @"BEGIN:VEVENT",
            [NSString stringWithFormat:@"UID:%@@zhishu-matrix", account.identifier],
            [@"DTSTAMP:" stringByAppendingString:now],
            [@"DTSTART;VALUE=DATE:" stringByAppendingString:[day stringFromDate:date]],
            [@"DTEND;VALUE=DATE:" stringByAppendingString:[day stringFromDate:next]],
            [@"SUMMARY:" stringByAppendingString:CalendarText(summary)],
            [@"DESCRIPTION:" stringByAppendingString:CalendarText([details componentsJoinedByString:@"\n"])],
        ]];
        if (renews) [lines addObject:@"RRULE:FREQ=MONTHLY"];
        [lines addObjectsFromArray:@[@"BEGIN:VALARM", @"TRIGGER:-P1D", @"ACTION:DISPLAY",
            [@"DESCRIPTION:" stringByAppendingString:CalendarText(summary)], @"END:VALARM", @"END:VEVENT"]];
    }
    [lines addObject:@"END:VCALENDAR"];
    NSMutableArray *folded = [NSMutableArray arrayWithCapacity:lines.count];
    for (NSString *line in lines) [folded addObject:FoldedLine(line)];
    return [[folded componentsJoinedByString:@"\r\n"] stringByAppendingString:@"\r\n"];
}

#pragma mark - Proxy

NSDictionary<NSString *, id> *AccountProxyComponents(NSString *text) {
    NSString *trimmed = [text ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) return nil;
    if (![trimmed containsString:@"://"]) trimmed = [@"http://" stringByAppendingString:trimmed];
    NSURLComponents *components = [NSURLComponents componentsWithString:trimmed];
    NSString *scheme = components.scheme.lowercaseString;
    NSDictionary *schemes = @{@"http": @"http", @"https": @"https", @"socks": @"socks5", @"socks5": @"socks5", @"socks5h": @"socks5"};
    NSInteger port = components.port.integerValue;
    if (!schemes[scheme] || !components.host.length || port <= 0 || port > 65535 || components.path.length > 1) return nil;
    NSMutableDictionary *result = [@{@"scheme": schemes[scheme], @"host": components.host, @"port": @(port)} mutableCopy];
    if (components.user.length) result[@"user"] = components.user;
    if (components.password.length) result[@"password"] = components.password;
    return result;
}

#pragma mark - Usage history

static NSTimeInterval const HistoryRetention = 8 * 86400;

static BOOL SameValue(id left, id right) { return left == right || [left isEqual:right]; }

@implementation UsageHistory {
    NSURL *_fileURL;
    NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *_points;
    BOOL _dirty;
}

- (instancetype)initWithFileURL:(NSURL *)fileURL {
    if ((self = [super init])) {
        _fileURL = fileURL;
        _points = [NSMutableDictionary dictionary];
        NSData *data = [NSData dataWithContentsOfURL:fileURL];
        NSDictionary *saved = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([saved isKindOfClass:NSDictionary.class]) {
            [saved enumerateKeysAndObjectsUsingBlock:^(NSString *identifier, NSArray *points, BOOL *stop) {
                if (![points isKindOfClass:NSArray.class]) return;
                NSMutableArray *valid = [NSMutableArray array];
                for (NSDictionary *point in points)
                    if ([point isKindOfClass:NSDictionary.class] && [point[@"t"] isKindOfClass:NSNumber.class]) [valid addObject:point];
                self->_points[identifier] = valid;
            }];
        }
    }
    return self;
}

- (void)recordUsageWindows:(NSArray<AccountUsageWindow *> *)windows forAccountID:(NSString *)identifier at:(NSDate *)date {
    NSMutableDictionary *point = [@{@"t": @(floor(date.timeIntervalSince1970))} mutableCopy];
    for (AccountUsageWindow *window in windows) {
        NSString *key = window.windowSeconds <= 86400 ? @"short" : @"long";
        point[key] = @(window.remainingPercent);
    }
    if (point.count < 2) return;
    NSMutableArray<NSDictionary *> *points = _points[identifier] ?: [NSMutableArray array];
    NSDictionary *last = points.lastObject;
    // Back-to-back refreshes with the same reading add nothing to a trend.
    if (last && [point[@"t"] doubleValue] - [last[@"t"] doubleValue] < 120 &&
        SameValue(last[@"short"], point[@"short"]) && SameValue(last[@"long"], point[@"long"])) return;
    [points addObject:point];
    double cutoff = date.timeIntervalSince1970 - HistoryRetention;
    while (points.count && ([points.firstObject[@"t"] doubleValue] < cutoff || points.count > 600)) [points removeObjectAtIndex:0];
    _points[identifier] = points;
    _dirty = YES;
}

- (NSArray<NSDictionary *> *)pointsForAccountID:(NSString *)identifier { return [_points[identifier] copy] ?: @[]; }

- (void)removeAccountIDs:(NSArray<NSString *> *)identifiers {
    [_points removeObjectsForKeys:identifiers];
    _dirty = YES;
}

- (BOOL)save:(NSError **)error {
    if (!_dirty) return YES;
    NSData *data = [NSJSONSerialization dataWithJSONObject:_points options:0 error:error];
    if (!data || ![data writeToURL:_fileURL options:NSDataWritingAtomic error:error]) return NO;
    _dirty = NO;
    return YES;
}

+ (NSDate *)predictedExhaustionOfWindow:(AccountUsageWindow *)window key:(NSString *)key points:(NSArray<NSDictionary *> *)points now:(NSDate *)now {
    double windowStart = (window.resetAt ? window.resetAt.timeIntervalSince1970 : now.timeIntervalSince1970) - window.windowSeconds;
    NSMutableArray<NSDictionary *> *samples = [NSMutableArray array];
    for (NSDictionary *point in points)
        if ([point[@"t"] doubleValue] >= windowStart && [point[key] isKindOfClass:NSNumber.class]) [samples addObject:point];
    if (samples.count < 2) return nil;
    double firstTime = [samples.firstObject[@"t"] doubleValue], lastTime = [samples.lastObject[@"t"] doubleValue];
    if (lastTime - firstTime < 20 * 60) return nil;
    // Least-squares slope of remaining percentage over time.
    double count = samples.count, sumT = 0, sumV = 0, sumTT = 0, sumTV = 0;
    for (NSDictionary *point in samples) {
        double t = [point[@"t"] doubleValue] - firstTime, v = [point[key] doubleValue];
        sumT += t; sumV += v; sumTT += t * t; sumTV += t * v;
    }
    double denominator = count * sumTT - sumT * sumT;
    if (denominator <= 0) return nil;
    double slope = (count * sumTV - sumT * sumV) / denominator;
    if (slope >= -1e-6) return nil;
    NSDate *exhaustion = [NSDate dateWithTimeIntervalSince1970:lastTime + window.remainingPercent / -slope];
    if (window.resetAt && [exhaustion compare:window.resetAt] != NSOrderedAscending) return nil;
    return exhaustion;
}
@end
