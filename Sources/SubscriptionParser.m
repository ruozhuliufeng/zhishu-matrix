#import "SubscriptionParser.h"
#import "Account.h"

static NSString *Capture(NSString *pattern, NSString *text) {
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:pattern
        options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *match = [expression firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (!match || [match rangeAtIndex:1].location == NSNotFound) return nil;
    return [text substringWithRange:[match rangeAtIndex:1]];
}

@implementation SubscriptionParser

+ (NSString *)planFromProfile:(NSString *)profile details:(NSString *)details {
    profile = profile ?: @"";
    NSString *plan = nil;
    if ([profile containsString:@"免费版"]) plan = @"Free";
    else if ([profile containsString:@"团队版"] || [profile containsString:@"商业版"]) plan = @"Business";
    else if ([profile containsString:@"企业版"]) plan = @"Enterprise";
    else if ([profile containsString:@"教育版"]) plan = @"Edu";
    else plan = Capture(@"\\b(Free|Go|Plus|Pro|Business|Enterprise|Edu)\\b", profile);
    if (!plan) {
        plan = Capture(@"(?:^|\\n)[ \\t]*(?:Current plan|Your plan|My plan|当前套餐|我的套餐|当前订阅|订阅方案|订阅级别)"
            "[\\s\\S]{0,80}?\\b(Free|Go|Plus|Pro|Business|Enterprise|Edu)\\b", details ?: @"");
    }
    return AccountCanonicalPlan(plan);
}

+ (NSString *)expiryFromDetails:(NSString *)details {
    NSString *raw = Capture(@"(?:Expires on|Expiration date|Expiry date|Subscription ends|到期日期|到期时间|订阅结束日期)"
        "[\\s\\S]{0,50}?([0-9]{4}[-/][0-9]{1,2}[-/][0-9]{1,2}|[0-9]{4}年[0-9]{1,2}月[0-9]{1,2}日|"
        "[A-Za-z]+ +[0-9]{1,2},? +[0-9]{4}|[0-9]{1,2} +[A-Za-z]+ +[0-9]{4})", details ?: @"");
    return [self normalizedDate:raw];
}

+ (NSString *)normalizedDate:(NSString *)raw {
    if (!raw.length) return nil;
    NSString *value = [[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.lenient = NO;
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    for (NSString *format in @[@"yyyy-M-d", @"yyyy年M月d日", @"MMM d, yyyy", @"MMMM d, yyyy", @"d MMM yyyy", @"d MMMM yyyy"]) {
        formatter.dateFormat = format;
        NSDate *date = [formatter dateFromString:value];
        if (date) return AccountDayString(date);
    }
    return nil;
}

+ (NSString *)planFromPlanType:(NSString *)planType {
    NSDictionary *plans = @{
        @"free": @"Free", @"go": @"Go", @"plus": @"Plus", @"pro": @"Pro",
        @"team": @"Business", @"business": @"Business", @"enterprise": @"Enterprise",
        @"edu": @"Edu", @"education": @"Edu"
    };
    return planType.length ? plans[planType.lowercaseString] : nil;
}
@end
