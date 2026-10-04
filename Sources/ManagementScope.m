#import "ManagementScope.h"
#import "Account.h"
#import "AccountInsights.h"

static NSArray<NSString *> *KindNames(void) {
    return @[@"all", @"quota", @"expiring", @"signedout", @"autorenew", @"duplicates", @"group", @"tag", @"supplier",
             @"incomplete", @"app", @"archived", @"lifecycle"];
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
    for (NSNumber *kind in @[@(ManagementScopeAll), @(ManagementScopeQuotaLow), @(ManagementScopeExpiring), @(ManagementScopeSignedOut),
                             @(ManagementScopeAutoRenew), @(ManagementScopeIncomplete), @(ManagementScopeDuplicates),
                             @(ManagementScopeArchived)])
        [scopes addObject:[self scopeWithKind:kind.integerValue value:nil]];
    return scopes;
}

- (BOOL)hasValue {
    return self.kind == ManagementScopeGroup || self.kind == ManagementScopeTag || self.kind == ManagementScopeSupplier ||
        self.kind == ManagementScopeAuthorizedApp || self.kind == ManagementScopeLifecycle;
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
        case ManagementScopeIncomplete: return @"资料不完整";
        case ManagementScopeAuthorizedApp: return self.value;
        case ManagementScopeArchived: return @"已归档";
        case ManagementScopeLifecycle: return AccountLifecycleTitle(self.value);
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
        case ManagementScopeIncomplete: return @"list.bullet.clipboard";
        case ManagementScopeAuthorizedApp: return @"person.badge.key";
        case ManagementScopeArchived: return @"archivebox";
        case ManagementScopeLifecycle: {
            NSDictionary *symbols = @{@"idle": @"moon.zzz", @"disabled": @"pause.circle", @"banned": @"nosign",
                                      @"transferred": @"arrow.right.circle"};
            return symbols[self.value] ?: @"checkmark.circle";
        }
    }
    return @"circle";
}

- (BOOL)includesAccount:(Account *)account now:(NSDate *)now duplicateIDs:(NSSet<NSString *> *)duplicateIDs {
    if (self.kind == ManagementScopeArchived) return account.archived;
    if (account.archived) return NO;
    switch (self.kind) {
        case ManagementScopeQuotaLow: case ManagementScopeExpiring: case ManagementScopeSignedOut: case ManagementScopeAutoRenew:
            if (account.retired) return NO;
            break;
        default: break;
    }
    switch (self.kind) {
        case ManagementScopeAll: case ManagementScopeArchived: return YES;
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
        case ManagementScopeIncomplete: return AccountMissingFields(account, now).count > 0;
        case ManagementScopeAuthorizedApp:
            for (AccountAuthorization *authorization in account.activeAuthorizations)
                if ([authorization.appName isEqualToString:self.value]) return YES;
            return NO;
        case ManagementScopeLifecycle: return [account.lifecycle isEqualToString:self.value];
    }
    return YES;
}

- (NSString *)stringValue {
    NSString *name = KindNames()[(NSUInteger)self.kind];
    return self.hasValue ? [NSString stringWithFormat:@"%@:%@", name, self.value] : name;
}

+ (instancetype)scopeFromString:(NSString *)string {
    if (!string.length) return nil;
    NSRange colon = [string rangeOfString:@":"];
    NSString *name = colon.location == NSNotFound ? string : [string substringToIndex:colon.location];
    NSUInteger kind = [KindNames() indexOfObject:name];
    if (kind == NSNotFound) return nil;
    NSString *value = colon.location == NSNotFound ? nil : [string substringFromIndex:NSMaxRange(colon)];
    ManagementScope *scope = [self scopeWithKind:(ManagementScopeKind)kind value:value];
    if (scope.hasValue != (value != nil)) return nil;
    return scope;
}
@end
