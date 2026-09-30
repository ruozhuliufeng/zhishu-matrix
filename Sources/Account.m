#import "Account.h"

NSInteger const AccountExpiringSoonDays = 7;
NSErrorDomain const AccountStoreErrorDomain = @"AccountStoreErrorDomain";
NSNotificationName const AccountStoreDidChangeNotification = @"AccountStoreDidChangeNotification";

NSArray<NSString *> *AccountPlans(void) {
    return @[@"Free", @"Go", @"Plus", @"Pro", @"Business", @"Enterprise", @"Edu"];
}

static NSString *Trimmed(NSString *value) {
    return [value ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *StringOrNil(id value) {
    return [value isKindOfClass:NSString.class] && [value length] ? value : nil;
}

NSString *AccountCanonicalPlan(id plan) {
    NSString *value = Trimmed(StringOrNil(plan));
    for (NSString *candidate in AccountPlans())
        if ([candidate caseInsensitiveCompare:value] == NSOrderedSame) return candidate;
    return nil;
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

static NSArray<NSString *> *KnownKeys(void) {
    return @[@"id", @"name", @"email", @"plan", @"planSource", @"expiresAt", @"expirySource",
             @"group", @"notes", @"authURL", @"createdAt", @"lastUsedAt", @"signedIn"];
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
        _group = Trimmed(StringOrNil(dictionary[@"group"]));
        _notes = StringOrNil(dictionary[@"notes"]) ?: @"";
        _authURL = Trimmed(StringOrNil(dictionary[@"authURL"]));
        _createdAt = TimestampOrNil(dictionary[@"createdAt"]);
        _lastUsedAt = TimestampOrNil(dictionary[@"lastUsedAt"]);
        id signedIn = dictionary[@"signedIn"];
        _signedIn = [signedIn isKindOfClass:NSNumber.class] ? @([signedIn boolValue]) : nil;
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
    if (self.group.length) dictionary[@"group"] = self.group;
    if (self.notes.length) dictionary[@"notes"] = self.notes;
    if (self.authURL.length) dictionary[@"authURL"] = self.authURL;
    if (self.createdAt) dictionary[@"createdAt"] = [TimestampFormatter() stringFromDate:self.createdAt];
    if (self.lastUsedAt) dictionary[@"lastUsedAt"] = [TimestampFormatter() stringFromDate:self.lastUsedAt];
    if (self.signedIn) dictionary[@"signedIn"] = self.signedIn;
    return dictionary;
}

- (NSDictionary *)exportRepresentation {
    // Login state and usage time describe this Mac, not the account.
    NSMutableDictionary *dictionary = [[self dictionaryRepresentation] mutableCopy];
    [dictionary removeObjectsForKeys:@[@"lastUsedAt", @"signedIn"]];
    return dictionary;
}

- (void)applyProfileFrom:(Account *)other {
    self.name = other.name;
    if (other.email.length) self.email = other.email;
    if (other.plan) { self.plan = other.plan; self.planSource = other.planSource; }
    if (other.expiresAt) { self.expiresAt = other.expiresAt; self.expirySource = other.expirySource; }
    if (other.group.length) self.group = other.group;
    if (other.notes.length) self.notes = other.notes;
    if (other.authURL.length) self.authURL = other.authURL;
    if (other.createdAt && (!self.createdAt || [other.createdAt compare:self.createdAt] == NSOrderedAscending))
        self.createdAt = other.createdAt;
}

- (NSString *)planTitle { return self.plan ?: @"未获取"; }
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
    if (days.integerValue < 0) return AccountExpiryStateExpired;
    if (days.integerValue <= AccountExpiringSoonDays) return AccountExpiryStateExpiringSoon;
    return AccountExpiryStateActive;
}

- (NSString *)expiryDescriptionFromDate:(NSDate *)now {
    NSNumber *days = [self daysRemainingFromDate:now];
    if (!days) return @"未设置到期";
    NSInteger value = days.integerValue;
    if (value < 0) return [NSString stringWithFormat:@"已过期 %ld 天", (long)-value];
    if (value == 0) return @"今天到期";
    return [NSString stringWithFormat:@"剩余 %ld 天", (long)value];
}

- (BOOL)matchesSearch:(NSString *)query {
    NSString *needle = Trimmed(query);
    if (!needle.length) return YES;
    for (NSString *field in @[self.name, self.email, self.group, self.notes, self.plan ?: @""])
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
