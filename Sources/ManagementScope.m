#import "ManagementScope.h"
#import "Account.h"
#import "AccountInsights.h"

static NSArray<NSString *> *KindNames(void) {
    return @[@"all", @"quota", @"expiring", @"signedout", @"autorenew", @"duplicates", @"group", @"tag", @"supplier"];
}

NSSet<NSString *> *AccountDuplicateIDs(NSArray<Account *> *accounts) {
    NSMutableSet *identifiers = [NSMutableSet set];
    for (NSArray<Account *> *matches in AccountDuplicateEmails(accounts).allValues)
        [identifiers addObjectsFromArray:[matches valueForKey:@"identifier"]];
    return identifiers;
}

@implementation ManagementScope

+ (instancetype)scopeWithKind:(ManagementScopeKind)kind value:(NSString *)value {
    ManagementScope *scope = [self new];
    scope->_kind = kind;
    scope->_value = [value ?: @"" copy];
    return scope;
}

+ (instancetype)all { return [self scopeWithKind:ManagementScopeAll value:nil]; }

+ (NSArray<ManagementScope *> *)smartScopes {
    NSMutableArray *scopes = [NSMutableArray array];
    for (ManagementScopeKind kind = ManagementScopeAll; kind <= ManagementScopeDuplicates; kind++)
        [scopes addObject:[self scopeWithKind:kind value:nil]];
    return scopes;
}

- (id)copyWithZone:(NSZone *)zone { return self; }

- (BOOL)isEqual:(id)object {
    if (![object isKindOfClass:ManagementScope.class]) return NO;
    ManagementScope *other = object;
    return other.kind == self.kind && [other.value isEqualToString:self.value];
}

- (NSUInteger)hash { return (NSUInteger)self.kind ^ self.value.hash; }

- (NSString *)title {
    switch (self.kind) {
        case ManagementScopeAll: return @"全部账号";
        case ManagementScopeQuotaLow: return @"额度告急";
        case ManagementScopeExpiring: return @"即将到期";
        case ManagementScopeSignedOut: return @"未登录";
        case ManagementScopeAutoRenew: return @"自动续费";
        case ManagementScopeDuplicates: return @"重复邮箱";
        case ManagementScopeGroup: return self.value.length ? self.value : @"未分组";
        case ManagementScopeTag: return self.value;
        case ManagementScopeSupplier: return self.value.length ? self.value : @"未填写供应商";
    }
    return @"";
}

- (NSString *)symbol {
    switch (self.kind) {
        case ManagementScopeAll: return @"person.2";
        case ManagementScopeQuotaLow: return @"gauge.with.dots.needle.0percent";
        case ManagementScopeExpiring: return @"clock.badge.exclamationmark";
        case ManagementScopeSignedOut: return @"person.crop.circle.badge.xmark";
        case ManagementScopeAutoRenew: return @"arrow.triangle.2.circlepath";
        case ManagementScopeDuplicates: return @"person.2.slash";
        case ManagementScopeGroup: return self.value.length ? @"folder" : @"tray";
        case ManagementScopeTag: return @"tag";
        case ManagementScopeSupplier: return self.value.length ? @"storefront" : @"questionmark.circle";
    }
    return @"circle";
}

- (BOOL)includesAccount:(Account *)account now:(NSDate *)now duplicateIDs:(NSSet<NSString *> *)duplicateIDs {
    switch (self.kind) {
        case ManagementScopeAll: return YES;
        case ManagementScopeQuotaLow: {
            NSNumber *lowest = account.usage.lowestRemainingPercent;
            return lowest && lowest.doubleValue < AccountLowQuotaPercent;
        }
        case ManagementScopeExpiring: {
            AccountExpiryState state = [account expiryStateFromDate:now];
            return state == AccountExpiryStateExpiringSoon || state == AccountExpiryStateExpired;
        }
        case ManagementScopeSignedOut: return !account.signedIn.boolValue;
        case ManagementScopeAutoRenew: return account.autoRenew.boolValue && account.expiresAt != nil;
        case ManagementScopeDuplicates: return [duplicateIDs containsObject:account.identifier];
        case ManagementScopeGroup: return [account.group isEqualToString:self.value];
        case ManagementScopeTag: return [account.tags containsObject:self.value];
        case ManagementScopeSupplier: return [account.supplier isEqualToString:self.value];
    }
    return YES;
}

- (NSString *)stringValue {
    NSString *name = KindNames()[(NSUInteger)self.kind];
    return self.kind >= ManagementScopeGroup ? [NSString stringWithFormat:@"%@:%@", name, self.value] : name;
}

+ (instancetype)scopeFromString:(NSString *)string {
    if (!string.length) return nil;
    NSRange colon = [string rangeOfString:@":"];
    NSString *name = colon.location == NSNotFound ? string : [string substringToIndex:colon.location];
    NSUInteger kind = [KindNames() indexOfObject:name];
    if (kind == NSNotFound) return nil;
    NSString *value = colon.location == NSNotFound ? nil : [string substringFromIndex:NSMaxRange(colon)];
    if (kind >= ManagementScopeGroup && !value) return nil;
    return [self scopeWithKind:(ManagementScopeKind)kind value:value];
}
@end
