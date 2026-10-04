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
    if (account.archived)
        return [[self alloc] initWithKind:AccountStatusArchived tone:AccountStatusToneNeutral title:@"已归档" symbol:@"archivebox"];
    if (account.retired) {
        NSDictionary *symbols = @{@"disabled": @"pause.circle", @"banned": @"nosign", @"transferred": @"arrow.right.circle"};
        return [[self alloc] initWithKind:AccountStatusRetired
            tone:[account.lifecycle isEqualToString:@"banned"] ? AccountStatusToneCritical : AccountStatusToneNeutral
            title:AccountLifecycleTitle(account.lifecycle) symbol:symbols[account.lifecycle]];
    }
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
    NSArray<NSString *> *missing = AccountMissingFields(account, now);
    if (missing.count)
        return [[self alloc] initWithKind:AccountStatusIncomplete tone:AccountStatusToneNeutral
            title:[NSString stringWithFormat:@"资料缺 %lu 项", (unsigned long)missing.count] symbol:@"list.bullet.clipboard"];
    if ([account.lifecycle isEqualToString:@"idle"])
        return [[self alloc] initWithKind:AccountStatusIdle tone:AccountStatusToneNeutral title:@"闲置" symbol:@"moon.zzz"];
    return [[self alloc] initWithKind:AccountStatusNormal tone:AccountStatusToneNeutral title:@"使用中" symbol:@"checkmark.circle"];
}
@end

NSArray<NSString *> *AccountMissingFields(Account *account, NSDate *now) {
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    if (!account.tracked) return missing;
    if (!account.email.length) [missing addObject:@"邮箱"];
    if (!account.plan) [missing addObject:@"订阅级别"];
    if (!account.isPaid) return missing;
    if (!account.expiresAt) [missing addObject:@"续费 / 到期日期"];
    if (!account.monthlyPrice) [missing addObject:@"月费"];
    else if (!account.currency.length) [missing addObject:@"币种"];
    if (!account.supplier.length) [missing addObject:@"供应商"];
    if (!account.paymentMethod.length) [missing addObject:@"付款方式"];
    else if (!account.cardLast4.length && [account.paymentMethod rangeOfString:@"(信用卡|借记卡|银行卡|储蓄卡|Visa|Master|Card)"
        options:NSRegularExpressionSearch | NSCaseInsensitiveSearch].location != NSNotFound) [missing addObject:@"卡尾号"];
    if (!account.lastPayment) {
        [missing addObject:@"付款记录"];
    } else if (account.autoRenew.boolValue) {
        // A monthly renewal should leave a payment at least every month or so.
        NSDate *last = AccountDateFromDayString(account.lastPayment.date);
        if (last && [now timeIntervalSinceDate:last] > 35 * 86400) [missing addObject:@"近 35 天未记付款"];
    }
    return missing;
}

NSDictionary<NSString *, NSArray<Account *> *> *AccountDuplicateEmails(NSArray<Account *> *accounts) {
    NSMutableDictionary<NSString *, NSMutableArray<Account *> *> *byEmail = [NSMutableDictionary dictionary];
    for (Account *account in accounts) {
        NSString *email = account.email.lowercaseString;
        if (!email.length || account.archived) continue;
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
    // Archived and retired accounts are no longer looked after.
    accounts = [accounts filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"tracked == YES"]];
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
        NSString *bucket = renews ? (left == 1 ? @"renew" : nil) : (left == 0 ? @"0" : (left == 1 ? @"1" : (left <= 3 ? @"3" : nil)));
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

    // Renewals that went through without a payment being recorded.
    NSMutableArray *payments = MutableList(state, @"payment");
    NSString *cutoff = AccountDayString([now dateByAddingTimeInterval:-60 * 86400]);
    [payments filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *key, NSDictionary *bindings) {
        NSArray *parts = [key componentsSeparatedByString:@"|"];
        return parts.count == 2 && [known containsObject:parts[0]] && [parts[1] compare:cutoff] != NSOrderedAscending;
    }]];
    if (!(kinds & AccountAlertRenewal)) return alerts;
    NSString *weekAgo = AccountDayString([now dateByAddingTimeInterval:-7 * 86400]);
    NSDictionary *rates = AccountExchangeRates();
    for (Account *account in accounts) {
        NSString *date = AccountUnrecordedRenewal(account, now);
        // Older gaps are listed in the app instead of arriving as a burst of notifications.
        if (!date || [date compare:weekAgo] == NSOrderedAscending) continue;
        NSString *key = [NSString stringWithFormat:@"%@|%@", account.identifier, date];
        if ([payments containsObject:key]) continue;
        [payments addObject:key];
        NSDictionary *charge = account.expectedCharge;
        NSNumber *cny = AccountAmountInCNY(charge[@"amount"], charge[@"currency"], rates);
        NSString *amount = cny ? AccountFormatCNY(cny) : (charge ? AccountFormatMoney(charge[@"amount"], charge[@"currency"]) : nil);
        NSMutableArray *details = [NSMutableArray arrayWithObject:account.planTitle];
        if (amount) [details addObject:amount];
        if (account.paymentSummary.length) [details addObject:account.paymentSummary];
        BOOL today = [date isEqualToString:AccountDayString(now)];
        [alerts addObject:@{@"id": [@"payment." stringByAppendingString:key], @"kind": @"payment",
            @"accountID": account.identifier, @"date": date,
            @"title": today ? [NSString stringWithFormat:@"“%@”今天续费，记一笔付款？", account.name]
                            : [NSString stringWithFormat:@"“%@”已于 %@ 续费，记一笔付款？", account.name, date],
            @"body": [details componentsJoinedByString:@" · "]}];
    }
    return alerts;
}

#pragma mark - Payments due

NSString *AccountUnrecordedRenewal(Account *account, NSDate *now) {
    NSDate *expiry = AccountDateFromDayString(account.expiresAt);
    if (!account.tracked || !account.isPaid || !account.autoRenew.boolValue || !expiry) return nil;
    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSDate *today = [calendar startOfDayForDate:now];
    NSDate *renewal = [expiry compare:today] != NSOrderedDescending ? expiry
        : [calendar dateByAddingUnit:NSCalendarUnitMonth value:-1 toDate:expiry options:0];
    if ([renewal compare:today] == NSOrderedDescending) return nil;
    NSString *earliest = AccountDayString([renewal dateByAddingTimeInterval:-3 * 86400]);
    // Only money actually paid settles a renewal; a refund or a failed charge does not.
    for (AccountPayment *payment in account.payments)
        if (payment.isCharge && [payment.date compare:earliest] != NSOrderedAscending) return nil;
    return AccountDayString(renewal);
}

#pragma mark - Budget

static NSString *MonthPrefix(NSDate *day) {
    NSDateComponents *parts = [NSCalendar.currentCalendar components:NSCalendarUnitYear | NSCalendarUnitMonth fromDate:day];
    return [NSString stringWithFormat:@"%04ld-%02ld", (long)parts.year, (long)parts.month];
}

double AccountSpentInMonth(NSArray<Account *> *accounts, NSDate *day, NSDictionary<NSString *, NSNumber *> *rates) {
    NSString *prefix = [MonthPrefix(day) stringByAppendingString:@"-"];
    double spent = 0;
    for (Account *account in accounts)
        for (AccountPayment *payment in account.payments)
            if ([payment.date hasPrefix:prefix])
                spent += AccountAmountInCNY(payment.amount, payment.currency, rates).doubleValue * payment.sign;
    return spent;
}

NSDictionary<NSString *, NSString *> *AccountBudgetAlert(NSArray<Account *> *accounts, NSDate *now, double budget,
    NSDictionary<NSString *, NSNumber *> *rates, NSMutableDictionary *state) {
    if (budget <= 0) return nil;
    NSString *month = MonthPrefix(now);
    if ([state[@"budget"] isEqual:month]) return nil;
    double spent = AccountSpentInMonth(accounts, now, rates);
    if (spent <= budget + 0.005) return nil;
    state[@"budget"] = month;
    NSInteger monthNumber = [[month substringFromIndex:5] integerValue];
    return @{@"id": [@"budget." stringByAppendingString:month], @"kind": @"budget", @"accountID": @"",
        @"title": [NSString stringWithFormat:@"%ld 月支出已超出预算", (long)monthNumber],
        @"body": [NSString stringWithFormat:@"本月已付 %@，预算 %@，超出 %@。", AccountFormatCNY(@(spent)), AccountFormatCNY(@(budget)),
            AccountFormatCNY(@(spent - budget))]};
}

#pragma mark - Expense report

static NSArray<NSDictionary *> *SortedGroups(NSDictionary<NSString *, NSNumber *> *totals, NSDictionary<NSString *, NSNumber *> *counts,
    NSDictionary<NSString *, NSString *> *ids) {
    NSMutableArray *groups = [NSMutableArray array];
    for (NSString *name in counts) {
        NSMutableDictionary *group = [@{@"name": name, @"total": totals[name] ?: @0, @"count": counts[name]} mutableCopy];
        if (ids[name]) group[@"accountID"] = ids[name];
        [groups addObject:group];
    }
    [groups sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult result = [b[@"total"] compare:a[@"total"]];
        return result != NSOrderedSame ? result : [a[@"name"] localizedStandardCompare:b[@"name"]];
    }];
    return groups;
}

static void Add(NSMutableDictionary<NSString *, NSNumber *> *totals, NSString *key, double value) {
    totals[key] = @(totals[key].doubleValue + value);
}

@implementation AccountExpenseReport

+ (instancetype)reportForAccounts:(NSArray<Account *> *)accounts year:(NSInteger)year rates:(NSDictionary<NSString *, NSNumber *> *)rates {
    AccountExpenseReport *report = [self new];
    report->_year = year;
    NSMutableArray<NSNumber *> *months = [NSMutableArray array];
    NSMutableArray<NSMutableDictionary *> *monthSuppliers = [NSMutableArray array];
    for (NSInteger month = 0; month < 12; month++) {
        [months addObject:@0];
        [monthSuppliers addObject:[NSMutableDictionary dictionary]];
    }
    NSMutableDictionary *supplierTotals = [NSMutableDictionary dictionary], *supplierCounts = [NSMutableDictionary dictionary];
    NSMutableDictionary *sourceTotals = [NSMutableDictionary dictionary], *sourceCounts = [NSMutableDictionary dictionary];
    NSMutableDictionary *accountTotals = [NSMutableDictionary dictionary], *accountCounts = [NSMutableDictionary dictionary];
    NSMutableDictionary *accountIDs = [NSMutableDictionary dictionary];
    NSMutableOrderedSet *missing = [NSMutableOrderedSet orderedSet];
    NSString *prefix = [NSString stringWithFormat:@"%04ld-", (long)year];
    double total = 0, refunds = 0;
    NSUInteger count = 0, failed = 0;
    for (Account *account in accounts) {
        NSString *accountKey = account.name;
        if (accountIDs[accountKey] && ![accountIDs[accountKey] isEqualToString:account.identifier])
            accountKey = [NSString stringWithFormat:@"%@（%@）", account.name, [account.identifier substringToIndex:4]];
        for (AccountPayment *payment in account.payments) {
            if (![payment.date hasPrefix:prefix]) continue;
            if (payment.isFailed) { failed++; continue; }
            NSNumber *cny = AccountAmountInCNY(payment.amount, payment.currency, rates);
            if (!cny) {
                [missing addObject:payment.currency.length ? payment.currency : @"未填币种"];
                continue;
            }
            NSInteger month = [[payment.date substringWithRange:NSMakeRange(5, 2)] integerValue] - 1;
            if (month < 0 || month > 11) continue;
            double value = cny.doubleValue * payment.sign;
            if (payment.isRefund) refunds += cny.doubleValue;
            NSString *supplier = payment.supplier.length ? payment.supplier : (account.supplier.length ? account.supplier : @"未填写供应商");
            NSString *method = payment.paymentMethod.length ? payment.paymentMethod : account.paymentMethod;
            NSString *card = payment.cardLast4.length ? payment.cardLast4 : account.cardLast4;
            NSString *source = method.length ? method : @"未填写付款方式";
            if (card.length) source = [NSString stringWithFormat:@"%@ · 尾号 %@", source, card];
            months[month] = @(months[month].doubleValue + value);
            Add(monthSuppliers[month], supplier, value);
            Add(supplierTotals, supplier, value);
            Add(supplierCounts, supplier, 1);
            Add(sourceTotals, source, value);
            Add(sourceCounts, source, 1);
            Add(accountTotals, accountKey, value);
            Add(accountCounts, accountKey, 1);
            accountIDs[accountKey] = account.identifier;
            total += value;
            count++;
        }
    }
    report->_total = total;
    report->_count = count;
    report->_refundTotal = refunds;
    report->_failedCount = failed;
    report->_monthTotals = months;
    report->_monthSupplierTotals = monthSuppliers;
    report->_bySupplier = SortedGroups(supplierTotals, supplierCounts, nil);
    report->_bySource = SortedGroups(sourceTotals, sourceCounts, nil);
    report->_byAccount = SortedGroups(accountTotals, accountCounts, accountIDs);
    report->_missingCurrencies = [missing.array sortedArrayUsingSelector:@selector(compare:)];
    return report;
}

+ (NSArray<NSDictionary *> *)reconciliationForAccounts:(NSArray<Account *> *)accounts month:(NSDate *)day now:(NSDate *)now
    rates:(NSDictionary<NSString *, NSNumber *> *)rates {
    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSDateComponents *target = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth fromDate:day];
    NSString *prefix = [NSString stringWithFormat:@"%04ld-%02ld-", (long)target.year, (long)target.month];
    NSDate *monthStart = [calendar dateFromComponents:target];
    NSString *today = AccountDayString(now);
    NSMutableArray *rows = [NSMutableArray array];
    for (Account *account in accounts) {
        double recorded = 0;
        BOOL anyRecorded = NO, anyCharge = NO, anyFailed = NO;
        for (AccountPayment *payment in account.payments) {
            if (![payment.date hasPrefix:prefix]) continue;
            if (payment.isFailed) { anyFailed = YES; continue; }
            anyRecorded = YES;
            if (payment.isCharge) anyCharge = YES;
            recorded += AccountAmountInCNY(payment.amount, payment.currency, rates).doubleValue * payment.sign;
        }
        // The charge expected this month: the renewal day moved into this month for auto-renewals,
        // the expiry for subscriptions renewed by hand.
        NSString *date = @"";
        NSDate *expiry = AccountDateFromDayString(account.expiresAt);
        if (account.tracked && account.isPaid && expiry) {
            if (account.autoRenew.boolValue) {
                NSDateComponents *from = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth fromDate:expiry];
                NSInteger shift = (target.year - from.year) * 12 + (target.month - from.month);
                NSDate *candidate = [calendar dateByAddingUnit:NSCalendarUnitMonth value:shift toDate:expiry options:0];
                // Months before the account was being tracked expect nothing.
                NSDate *tracked = account.createdAt;
                NSDate *firstPayment = AccountDateFromDayString(account.payments.lastObject.date);
                if (firstPayment && (!tracked || [firstPayment compare:tracked] == NSOrderedAscending)) tracked = firstPayment;
                NSDate *trackedMonth = tracked ? [calendar dateFromComponents:[calendar components:NSCalendarUnitYear | NSCalendarUnitMonth
                    fromDate:tracked]] : nil;
                if (candidate && [AccountDayString(candidate) hasPrefix:prefix] &&
                    (!trackedMonth || [monthStart compare:trackedMonth] != NSOrderedAscending))
                    date = AccountDayString(candidate);
            } else if ([account.expiresAt hasPrefix:prefix]) {
                date = account.expiresAt;
            }
        }
        if (!date.length && !anyRecorded && !anyFailed) continue;
        NSDictionary *charge = account.expectedCharge;
        NSNumber *expected = date.length ? AccountAmountInCNY(charge[@"amount"], charge[@"currency"], rates) : nil;
        NSString *state = anyRecorded ? @"extra" : @"failed";
        if (date.length) {
            if (anyCharge) state = !expected || fabs(expected.doubleValue - recorded) <= MAX(1, expected.doubleValue * 0.01)
                ? @"recorded" : @"different";
            else if (anyFailed) state = @"failed";
            else if (anyRecorded) state = @"different";
            else state = [date compare:today] == NSOrderedDescending ? @"upcoming" : @"missing";
        }
        [rows addObject:@{@"accountID": account.identifier, @"name": account.name, @"date": date,
            @"expected": expected ?: (id)NSNull.null, @"recorded": @(recorded), @"state": state}];
    }
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSString *left = [a[@"date"] length] ? a[@"date"] : @"9999", *right = [b[@"date"] length] ? b[@"date"] : @"9999";
        NSComparisonResult result = [left compare:right];
        return result != NSOrderedSame ? result : [a[@"name"] localizedStandardCompare:b[@"name"]];
    }];
    return rows;
}
@end

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
        if (!date || !account.tracked) continue;
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
