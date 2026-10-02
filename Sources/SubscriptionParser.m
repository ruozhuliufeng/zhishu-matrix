#import "SubscriptionParser.h"
#import "Account.h"

static NSString *Capture(NSString *pattern, NSString *text) {
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:pattern
        options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *match = [expression firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (!match || [match rangeAtIndex:1].location == NSNotFound) return nil;
    return [text substringWithRange:[match rangeAtIndex:1]];
}

static NSString *const DatePattern =
    @"([0-9]{4}[-/][0-9]{1,2}[-/][0-9]{1,2}|[0-9]{4}年[0-9]{1,2}月[0-9]{1,2}日|"
     "[A-Za-z]+ +[0-9]{1,2},? +[0-9]{4}|[0-9]{1,2} +[A-Za-z]+ +[0-9]{4})";

static NSNumber *NumberValue(id value) {
    if ([value isKindOfClass:NSNumber.class]) return value;
    if ([value isKindOfClass:NSString.class]) {
        NSScanner *scanner = [NSScanner scannerWithString:[value stringByReplacingOccurrencesOfString:@"," withString:@""]];
        double number = 0;
        if ([scanner scanDouble:&number] && scanner.isAtEnd) return @(number);
    }
    return nil;
}

static NSDate *DateFromUnixValue(id value) {
    NSNumber *number = NumberValue(value);
    if (!number || number.doubleValue <= 0) return nil;
    double seconds = number.doubleValue > 1e12 ? number.doubleValue / 1000 : number.doubleValue;
    return [NSDate dateWithTimeIntervalSince1970:seconds];
}

static NSDate *DateFromISOValue(id value) {
    if (![value isKindOfClass:NSString.class] || ![value length]) return DateFromUnixValue(value);
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    NSDate *date = [formatter dateFromString:value];
    if (date) return date;
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    date = [formatter dateFromString:value];
    if (date) return date;
    formatter.formatOptions = NSISO8601DateFormatWithFullDate;
    return [formatter dateFromString:[value substringToIndex:MIN((NSUInteger)10, [value length])]];
}

@implementation SubscriptionParser

+ (NSString *)planFromProfile:(NSString *)profile details:(NSString *)details {
    profile = profile ?: @"";
    // The billing page names the exact tier ("ChatGPT Pro 200"); the profile button only says "Pro".
    NSString *billingPlan = [self isBillingText:details] ? [self planFromBillingText:details] : nil;
    if (billingPlan) return billingPlan;
    NSString *plan = nil;
    if ([profile containsString:@"免费版"]) plan = @"Free";
    else if ([profile containsString:@"团队版"] || [profile containsString:@"商业版"]) plan = @"Business";
    else if ([profile containsString:@"企业版"]) plan = @"Enterprise";
    else if ([profile containsString:@"教育版"]) plan = @"Edu";
    else plan = Capture(@"\\b(Free|Go|Plus|Pro(?: ?(?:100|200|500))?|Business|Enterprise|Edu)\\b", profile);
    if (!plan) {
        plan = Capture(@"(?:^|\\n)[ \\t]*(?:Current plan|Your plan|My plan|当前套餐|我的套餐|当前订阅|订阅方案|订阅级别)"
            "[\\s\\S]{0,80}?\\b(Free|Go|Plus|Pro|Business|Enterprise|Edu)\\b", details ?: @"");
    }
    return AccountCanonicalPlan(plan);
}

+ (NSString *)expiryFromDetails:(NSString *)details {
    NSString *pattern = [@"(?:Expires on|Expiration date|Expiry date|Subscription ends|到期日期|到期时间|订阅结束日期)[\\s\\S]{0,50}?"
        stringByAppendingString:DatePattern];
    return [self normalizedDate:Capture(pattern, details ?: @"")];
}

+ (NSString *)normalizedDate:(NSString *)raw {
    if (!raw.length) return nil;
    NSString *value = [[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.lenient = NO;
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    for (NSString *format in @[@"yyyy-M-d", @"yyyy年M月d日", @"MMM d, yyyy", @"MMMM d, yyyy", @"MMM d yyyy", @"MMMM d yyyy",
                               @"d MMM yyyy", @"d MMMM yyyy"]) {
        formatter.dateFormat = format;
        NSDate *date = [formatter dateFromString:value];
        if (date) return AccountDayString(date);
    }
    return nil;
}

+ (NSString *)planFromPlanType:(NSString *)planType {
    if (![planType isKindOfClass:NSString.class] || !planType.length) return nil;
    NSDictionary *plans = @{@"free": @"Free", @"free_workspace": @"Free", @"guest": @"Free", @"k12": @"Edu", @"education": @"Edu"};
    return plans[planType.lowercaseString] ?: AccountCanonicalPlan(planType);
}

#pragma mark - Billing page

static NSString *const StoreManagedPattern =
    @"(?:通过|在|由)\\s*(Apple|App Store|iOS|Google Play|Google)\\s*(?:中)?(?:管理|订阅|续订|付款)|"
     "(?:managed|billed|purchased)\\s+(?:through|by|via|on|in)\\s+(?:the\\s+)?(Apple|App Store|iOS|Google Play|Google)";

+ (BOOL)isBillingText:(NSString *)text {
    if (!text.length) return NO;
    return Capture(@"(交易记录|账单信息|账单地址|更改套餐|管理订阅|Payment history|Invoices|Billing information|"
        "Billing address|Manage subscription|Change plan)", text) != nil || Capture(StoreManagedPattern, text) != nil;
}

+ (NSString *)supplierFromBillingText:(NSString *)text {
    if (!text.length) return nil;
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:StoreManagedPattern
        options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *match = [expression firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (!match) return nil;
    NSRange store = [match rangeAtIndex:1].location != NSNotFound ? [match rangeAtIndex:1] : [match rangeAtIndex:2];
    return [[text substringWithRange:store].lowercaseString hasPrefix:@"google"] ? @"Google Play" : @"iOS";
}

+ (NSString *)cardLast4FromBillingText:(NSString *)text {
    if (!text.length) return nil;
    for (NSString *pattern in @[
        @"(?:Visa|Mastercard|American Express|Amex|UnionPay|银联|JCB|Discover|Diners)[^\\n0-9]{0,16}?(?:[•·*xX]\\s*){2,}([0-9]{4})\\b",
        @"(?:ending in|ends in|尾号|末四位|结尾为)\\s*([0-9]{4})\\b",
        @"(?:[•*]\\s*){4,}([0-9]{4})\\b"]) {
        NSString *digits = Capture(pattern, text);
        if (digits) return digits;
    }
    return nil;
}

+ (NSArray<NSDictionary *> *)paymentsFromBillingText:(NSString *)text {
    if (!text.length) return @[];
    // Only the payment history lists past charges; the renewal sentence above it has a date too.
    NSRange heading = [text rangeOfString:@"(交易记录|付款记录|账单记录|账单历史|Payment history|Billing history|Invoices|Invoice history)"
        options:NSRegularExpressionSearch | NSCaseInsensitiveSearch];
    if (heading.location == NSNotFound) return @[];
    NSArray<NSString *> *lines = [[text substringFromIndex:NSMaxRange(heading)] componentsSeparatedByCharactersInSet:
        NSCharacterSet.newlineCharacterSet];
    NSRegularExpression *datePattern = [NSRegularExpression regularExpressionWithPattern:DatePattern options:0 error:nil];
    NSMutableArray<NSDictionary *> *payments = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSUInteger index = 0; index < lines.count; index++) {
        NSString *line = lines[index];
        NSTextCheckingResult *match = [datePattern firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
        NSString *date = match ? [self normalizedDate:[line substringWithRange:match.range]] : nil;
        if (!date) continue;
        // A row is the dated line plus the following lines up to the next date.
        NSMutableString *row = [[line substringFromIndex:NSMaxRange(match.range)] mutableCopy];
        for (NSUInteger next = index + 1; next < MIN(lines.count, index + 5); next++) {
            if ([datePattern firstMatchInString:lines[next] options:0 range:NSMakeRange(0, lines[next].length)]) break;
            [row appendFormat:@"\n%@", lines[next]];
        }
        if (Capture(@"(失败|未支付|待支付|已退款|退款|已取消|作废|Failed|Unpaid|Refunded|Void|Declined)", row)) continue;
        NSDictionary *price = [self priceFromBillingText:row];
        if (!price) continue;
        NSString *key = [NSString stringWithFormat:@"%@|%@|%@", date, price[@"amount"], price[@"currency"]];
        if ([seen containsObject:key]) continue;
        [seen addObject:key];
        [payments addObject:@{@"date": date, @"amount": price[@"amount"], @"currency": price[@"currency"]}];
    }
    return [payments sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"date"] compare:a[@"date"]];
    }];
}

+ (NSString *)planFromBillingText:(NSString *)text {
    if (!text.length) return nil;
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:
        @"ChatGPT\\s*(Pro|Plus|Go|Business|Team|Enterprise|Edu|Free)(?:\\s*(100|200|500))?\\b"
        options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *match = [expression firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (!match) return nil;
    NSString *plan = [text substringWithRange:[match rangeAtIndex:1]];
    if ([match rangeAtIndex:2].location != NSNotFound)
        plan = [NSString stringWithFormat:@"%@ %@", plan, [text substringWithRange:[match rangeAtIndex:2]]];
    return AccountCanonicalPlan(plan);
}

+ (NSDictionary *)renewalFromBillingText:(NSString *)text {
    if (!text.length) return nil;
    NSArray<NSArray *> *rules = @[
        @[[NSString stringWithFormat:@"(?:将在|将于|于)\\s*%@\\s*(?:自动)?(?:续订|续费|续期)", DatePattern], @YES],
        @[[NSString stringWithFormat:@"(?:将在|将于|于)\\s*%@\\s*(?:到期|结束|终止|取消)", DatePattern], @NO],
        @[[NSString stringWithFormat:@"(?:auto-?renews?|renews?|will renew|next billing date is)\\s*(?:automatically\\s*)?(?:on\\s*)?%@", DatePattern], @YES],
        @[[NSString stringWithFormat:@"(?:will be cancell?ed|cancels|expires|ends|will end|access until)\\s*(?:on\\s*)?%@", DatePattern], @NO],
    ];
    for (NSArray *rule in rules) {
        NSString *date = [self normalizedDate:Capture(rule[0], text)];
        if (date) return @{@"date": date, @"autoRenew": rule[1]};
    }
    return nil;
}

+ (NSDictionary *)priceFromBillingText:(NSString *)text {
    if (!text.length) return nil;
    NSString *codes = @"USD|EUR|GBP|PHP|CNY|RMB|HKD|TWD|JPY|KRW|SGD|MYR|THB|IDR|VND|INR|AUD|CAD|NZD|CHF|BRL|MXN|TRY|AED|SAR";
    NSString *amount = @"([0-9][0-9,]*(?:\\.[0-9]+)?)";
    NSDictionary *symbols = @{@"US$": @"USD", @"HK$": @"HKD", @"NT$": @"TWD", @"S$": @"SGD", @"A$": @"AUD", @"C$": @"CAD",
                              @"$": @"USD", @"₱": @"PHP", @"€": @"EUR", @"£": @"GBP", @"￥": @"CNY", @"¥": @"CNY", @"₩": @"KRW", @"₹": @"INR"};
    NSRegularExpression *byCode = [NSRegularExpression regularExpressionWithPattern:
        [NSString stringWithFormat:@"\\b(%@)\\s?%@", codes, amount] options:0 error:nil];
    NSRegularExpression *bySymbol = [NSRegularExpression regularExpressionWithPattern:
        [NSString stringWithFormat:@"(US\\$|HK\\$|NT\\$|S\\$|A\\$|C\\$|\\$|₱|€|£|￥|¥|₩|₹)\\s?%@", amount] options:0 error:nil];
    NSTextCheckingResult *code = [byCode firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    NSTextCheckingResult *symbol = [bySymbol firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    NSTextCheckingResult *match = code;
    if (symbol && (!code || symbol.range.location < code.range.location)) match = symbol;
    if (!match) return nil;
    NSString *unit = [text substringWithRange:[match rangeAtIndex:1]];
    NSNumber *value = NumberValue([text substringWithRange:[match rangeAtIndex:2]]);
    if (!value || value.doubleValue <= 0) return nil;
    NSString *currency = match == code ? ([unit isEqualToString:@"RMB"] ? @"CNY" : unit) : symbols[unit];
    return @{@"amount": value, @"currency": currency ?: @""};
}

#pragma mark - Backend API

+ (AccountUsage *)usageFromJSON:(id)json planType:(NSString **)planType {
    if (![json isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *root = json;
    if (planType) *planType = [root[@"plan_type"] isKindOfClass:NSString.class] ? root[@"plan_type"] : nil;
    NSMutableArray<AccountUsageWindow *> *windows = [NSMutableArray array];
    NSDictionary *limits = [root[@"rate_limit"] isKindOfClass:NSDictionary.class] ? root[@"rate_limit"] : nil;
    for (NSString *key in @[@"primary_window", @"secondary_window"]) {
        NSDictionary *item = [limits[key] isKindOfClass:NSDictionary.class] ? limits[key] : nil;
        NSNumber *used = NumberValue(item[@"used_percent"]);
        NSNumber *seconds = NumberValue(item[@"limit_window_seconds"]);
        if (!used || seconds.integerValue <= 0) continue;
        AccountUsageWindow *window = [AccountUsageWindow new];
        window.usedPercent = MAX(0, MIN(100, used.doubleValue));
        window.windowSeconds = seconds.integerValue;
        window.resetAt = DateFromUnixValue(item[@"reset_at"]);
        if (!window.resetAt && NumberValue(item[@"reset_after_seconds"]))
            window.resetAt = [NSDate dateWithTimeIntervalSinceNow:NumberValue(item[@"reset_after_seconds"]).doubleValue];
        [windows addObject:window];
    }
    NSDictionary *credits = [root[@"credits"] isKindOfClass:NSDictionary.class] ? root[@"credits"] : nil;
    if (!windows.count && !credits) return nil;
    AccountUsage *usage = [AccountUsage new];
    usage.windows = windows;
    usage.creditBalance = NumberValue(credits[@"balance"]);
    usage.unlimitedCredits = [credits[@"unlimited"] isKindOfClass:NSNumber.class] && [credits[@"unlimited"] boolValue];
    usage.fetchedAt = NSDate.date;
    return usage;
}

+ (NSDictionary *)subscriptionFromJSON:(id)json {
    if (![json isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *root = json;
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSDate *activeUntil = DateFromISOValue(root[@"active_until"] ?: root[@"activeUntil"]);
    if (activeUntil) result[@"expiresAt"] = AccountDayString(activeUntil);
    id willRenew = root[@"will_renew"] ?: root[@"willRenew"];
    if ([willRenew isKindOfClass:NSNumber.class]) result[@"autoRenew"] = @([willRenew boolValue]);
    // The response has no secrets; scan its plain values for a Pro tier such as "chatgptpro200".
    for (id value in root.allValues) {
        if (![value isKindOfClass:NSString.class]) continue;
        NSString *tier = Capture(@"pro[ _-]?(100|200|500)\\b", value);
        if (tier) { result[@"plan"] = [@"Pro " stringByAppendingString:tier]; break; }
    }
    return result.count ? result : nil;
}
@end
