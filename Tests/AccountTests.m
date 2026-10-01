#import <Foundation/Foundation.h>
#import "../Sources/Account.h"
#import "../Sources/AuthorizationLink.h"
#import "../Sources/SubscriptionParser.h"

static int failures = 0;
static int checks = 0;

#define CHECK(condition, message) do { \
    checks++; \
    if (!(condition)) { failures++; fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, message); } \
} while (0)

static NSString *const WorkID = @"7C9E6679-7425-40DE-944B-E07FC1F90AE7";
static NSString *const HomeID = @"1B4E28BA-2FA1-11D2-883F-0016D3CCA427";
static NSString *const TeamID = @"E4B3B8A1-4D6C-4B1E-9F0A-2E3C4D5E6F70";

static void TestLegacyRecords(void) {
    Account *legacy = [[Account alloc] initWithDictionary:@{
        @"id": WorkID.lowercaseString, @"name": @"  工作 ", @"email": @"", @"plan": @"未获取",
        @"planSource": @"manual", @"expiresAt": @"2026-1-5", @"futureKey": @42
    }];
    CHECK([legacy.identifier isEqualToString:WorkID], "normalizes ids to the uppercase UUID string");
    CHECK([legacy.name isEqualToString:@"工作"], "trims names");
    CHECK(legacy.plan == nil && legacy.planSource == nil, "treats the legacy 未获取 plan as unknown");
    CHECK([legacy.expiresAt isEqualToString:@"2026-01-05"], "normalizes expiry dates");
    NSDictionary *saved = legacy.dictionaryRepresentation;
    CHECK([saved[@"futureKey"] isEqual:@42], "keeps unknown keys when saving");
    CHECK(saved[@"plan"] == nil && saved[@"email"] == nil, "omits empty fields");

    Account *pro = [[Account alloc] initWithDictionary:@{@"id": HomeID, @"name": @"家", @"plan": @"PRO"}];
    CHECK([pro.plan isEqualToString:@"Pro"] && pro.isPaid, "canonicalizes plan names");
    Account *broken = [[Account alloc] initWithDictionary:@{@"id": @"not-a-uuid", @"name": @"x"}];
    CHECK([[NSUUID alloc] initWithUUIDString:broken.identifier] != nil, "replaces invalid ids with a fresh UUID");
}

static void TestExpiry(void) {
    NSDate *today = AccountDateFromDayString(@"2026-10-01");
    Account *account = [Account accountWithName:@"x"];
    CHECK([account expiryStateFromDate:today] == AccountExpiryStateUnknown, "no date means unknown");
    account.expiresAt = @"2026-10-01";
    CHECK([account expiryStateFromDate:today] == AccountExpiryStateExpiringSoon, "expiring today is soon");
    CHECK([[account expiryDescriptionFromDate:today] isEqualToString:@"今天到期"], "describes today");
    account.expiresAt = @"2026-10-08";
    CHECK([[account daysRemainingFromDate:today] integerValue] == 7, "counts calendar days");
    CHECK([account expiryStateFromDate:today] == AccountExpiryStateExpiringSoon, "seven days is still soon");
    account.expiresAt = @"2026-10-09";
    CHECK([account expiryStateFromDate:today] == AccountExpiryStateActive, "eight days is active");
    account.expiresAt = @"2026-09-28";
    CHECK([account expiryStateFromDate:today] == AccountExpiryStateExpired, "past dates are expired");
    CHECK([[account expiryDescriptionFromDate:today] isEqualToString:@"已过期 3 天"], "describes expired days");
}

static void TestSearch(void) {
    Account *account = [Account accountWithName:@"Work"];
    account.email = @"team@example.com";
    account.group = @"客户 A";
    account.notes = @"续费提醒";
    CHECK([account matchesSearch:@""], "empty search matches everything");
    CHECK([account matchesSearch:@"EXAMPLE"], "search is case-insensitive");
    CHECK([account matchesSearch:@"客户"], "search covers groups");
    CHECK([account matchesSearch:@"续费"], "search covers notes");
    CHECK(![account matchesSearch:@"personal"], "search rejects non-matches");
}

static AccountStore *TemporaryStore(NSString *name) {
    NSURL *directory = [NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    return [[AccountStore alloc] initWithFileURL:[directory URLByAppendingPathComponent:name]];
}

static void TestStore(void) {
    AccountStore *store = TemporaryStore(@"accounts.json");
    NSError *error = nil;
    CHECK([store load:&error] && store.accounts.count == 0, "a missing file loads as an empty list");
    Account *a = [store addAccountNamed:@"A" group:nil];
    Account *b = [store addAccountNamed:@"B" group:@"团队"];
    Account *c = [store addAccountNamed:@"C" group:@"个人"];
    NSSet *expectedGroups = [NSSet setWithObjects:@"个人", @"团队", nil];
    CHECK(store.groups.count == 2 && [[NSSet setWithArray:store.groups] isEqualToSet:expectedGroups], "lists distinct groups");

    [store moveAccountsWithIDs:@[c.identifier] toIndex:0];
    CHECK([[store.accounts valueForKey:@"name"] isEqualToArray:(@[@"C", @"A", @"B"])], "moves an account to the front");
    [store moveAccountsWithIDs:@[c.identifier] toIndex:3];
    CHECK([[store.accounts valueForKey:@"name"] isEqualToArray:(@[@"A", @"B", @"C"])], "moves an account to the end");
    [store moveAccountsWithIDs:@[a.identifier, b.identifier] toIndex:3];
    CHECK([[store.accounts valueForKey:@"name"] isEqualToArray:(@[@"C", @"A", @"B"])], "moves several accounts together");
    [store moveAccountsWithIDs:@[a.identifier] toIndex:1];
    CHECK([[store.accounts valueForKey:@"name"] isEqualToArray:(@[@"C", @"A", @"B"])], "dropping an account onto itself is a no-op");

    b.lastUsedAt = NSDate.date;
    b.signedIn = @YES;
    CHECK([store save:&error], "saves");
    AccountStore *reloaded = [[AccountStore alloc] initWithFileURL:store.fileURL];
    CHECK([reloaded load:&error] && reloaded.accounts.count == 3, "reloads what it saved");
    CHECK([[reloaded accountWithID:b.identifier].group isEqualToString:@"团队"], "round-trips groups");
    CHECK([[reloaded accountWithID:b.identifier].signedIn boolValue], "round-trips login state");

    NSData *export = [store exportDataForAccountIDs:@[b.identifier] error:&error];
    NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:export options:0 error:nil];
    NSDictionary *exported = [payload[@"accounts"] firstObject];
    CHECK([payload[@"accounts"] count] == 1, "exports only the requested accounts");
    CHECK(exported[@"signedIn"] == nil && exported[@"lastUsedAt"] == nil, "export leaves out per-Mac state");

    [store removeAccountsWithIDs:@[a.identifier]];
    CHECK(store.accounts.count == 2 && ![store accountWithID:a.identifier], "removes accounts");
}

static void TestImport(void) {
    AccountStore *store = TemporaryStore(@"accounts.json");
    Account *existing = [store addAccountNamed:@"Old" group:@"团队"];
    existing.email = @"keep@example.com";
    NSDictionary *payload = @{@"accounts": @[
        @{@"id": existing.identifier, @"name": @"Renamed", @"email": @"", @"plan": @"Plus"},
        @{@"id": TeamID, @"name": @"New"},
        @{@"id": HomeID},
        @"garbage"
    ]};
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    NSUInteger added = 0, updated = 0;
    NSError *error = nil;
    CHECK([store importData:data added:&added updated:&updated error:&error], "imports the export format");
    CHECK(added == 1 && updated == 1, "counts added and updated accounts, skipping nameless entries");
    CHECK([existing.name isEqualToString:@"Renamed"] && [existing.plan isEqualToString:@"Plus"], "updates matching accounts");
    CHECK([existing.email isEqualToString:@"keep@example.com"] && [existing.group isEqualToString:@"团队"],
        "empty imported fields keep local values");

    NSData *plainArray = [NSJSONSerialization dataWithJSONObject:@[@{@"name": @"Plain"}] options:0 error:nil];
    CHECK([store importData:plainArray added:&added updated:&updated error:&error] && added == 1, "imports a raw accounts.json array");
    CHECK(![store importData:[@"{\"hello\":1}" dataUsingEncoding:NSUTF8StringEncoding] added:NULL updated:NULL error:&error],
        "rejects JSON without an account list");
}

static void TestUnreadableFileIsBackedUp(void) {
    AccountStore *store = TemporaryStore(@"accounts.json");
    [NSFileManager.defaultManager createDirectoryAtURL:store.fileURL.URLByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:nil];
    [@"{ not json" writeToURL:store.fileURL atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSError *error = nil;
    CHECK(![store load:&error] && error, "reports unreadable files");
    CHECK(store.recoveredBackupURL && [NSFileManager.defaultManager fileExistsAtPath:store.recoveredBackupURL.path],
        "copies unreadable files aside before starting empty");
}

static void TestParser(void) {
    CHECK([[SubscriptionParser planFromProfile:@"bucktooth 免费版，打开“个人资料”菜单" details:nil] isEqualToString:@"Free"],
        "reads Chinese profile labels");
    CHECK([[SubscriptionParser planFromProfile:@"bucktooth PRO" details:nil] isEqualToString:@"Pro"], "canonicalizes plans");
    CHECK([[SubscriptionParser planFromProfile:@"" details:@"Current plan\nChatGPT Plus\nRenews"] isEqualToString:@"Plus"],
        "falls back to the subscription details");
    CHECK([SubscriptionParser planFromProfile:@"" details:@"Upgrade to Plus"] == nil, "ignores upgrade offers in details");
    CHECK([[SubscriptionParser expiryFromDetails:@"Current plan\nChatGPT Pro\nExpires on October 30, 2026"] isEqualToString:@"2026-10-30"],
        "reads English expiry dates");
    CHECK([[SubscriptionParser expiryFromDetails:@"到期日期：2026年3月5日"] isEqualToString:@"2026-03-05"], "reads Chinese expiry dates");
    CHECK([SubscriptionParser expiryFromDetails:@"Next billing date October 30, 2026"] == nil, "ignores renewal dates");
    CHECK([[SubscriptionParser planFromPlanType:@"team"] isEqualToString:@"Business"], "maps team to Business");
    CHECK([SubscriptionParser planFromPlanType:@"mystery"] == nil, "ignores unknown plan types");
}

static void TestAuthorizationLinks(void) {
    NSString *codex = @"https://auth.openai.com/oauth/authorize?response_type=code&client_id=app_x"
        "&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&scope=openid+profile&state=abc";
    CHECK([AuthorizationURLFromText(codex).absoluteString isEqualToString:codex], "accepts a full authorization link");
    CHECK([AuthorizationURLFromText([NSString stringWithFormat:@"  %@\n", codex]).absoluteString isEqualToString:codex],
        "trims surrounding whitespace");
    NSString *wrapped = [NSString stringWithFormat:@"%@\n%@", [codex substringToIndex:60], [codex substringFromIndex:60]];
    CHECK([AuthorizationURLFromText(wrapped).absoluteString isEqualToString:codex], "joins a link wrapped across lines");
    NSString *prose = [NSString stringWithFormat:@"If your browser did not open, navigate to this URL to authenticate:\n\n%@\n", codex];
    CHECK([AuthorizationURLFromText(prose).host isEqualToString:@"auth.openai.com"], "finds the link inside CLI output");
    CHECK([AuthorizationURLFromText(@"https://client.example.com/login?名称=工作").host isEqualToString:@"client.example.com"],
        "accepts links with unencoded characters");
    CHECK(AuthorizationURLFromText(@"") == nil, "rejects empty input");
    CHECK(AuthorizationURLFromText(@"not a link") == nil, "rejects plain text");
    CHECK(AuthorizationURLFromText(@"javascript:alert(1)") == nil, "rejects non-web schemes");
    CHECK(AuthorizationURLFromText(@"ftp://example.com/x") == nil, "rejects ftp links");

    CHECK(AuthorizationIsLoopbackURL([NSURL URLWithString:@"http://localhost:1455/auth/callback"]), "localhost is loopback");
    CHECK(AuthorizationIsLoopbackURL([NSURL URLWithString:@"http://127.0.0.1:8080/cb"]), "127.0.0.1 is loopback");
    CHECK(AuthorizationIsLoopbackURL([NSURL URLWithString:@"http://[::1]:8080/cb"]), "::1 is loopback");
    CHECK(!AuthorizationIsLoopbackURL([NSURL URLWithString:@"https://auth.openai.com/"]), "remote hosts are not loopback");
    CHECK(!AuthorizationIsLoopbackURL([NSURL URLWithString:@"http://localhost.example.com/"]), "lookalike hosts are not loopback");

    CHECK([AuthorizationOrigin([NSURL URLWithString:@"https://auth.openai.com/a?b"]) isEqualToString:@"https://auth.openai.com:443"],
        "origins include the default port");
    CHECK(![AuthorizationOrigin([NSURL URLWithString:@"http://localhost:1455/x"])
        isEqualToString:AuthorizationOrigin([NSURL URLWithString:@"http://localhost:1456/x"])], "ports distinguish origins");

    Account *account = [Account accountWithName:@"x"];
    account.authURL = @"  https://client.example.com/login  ";
    CHECK([account.authURL isEqualToString:@"https://client.example.com/login"], "trims saved authorization links");
    CHECK([account.dictionaryRepresentation[@"authURL"] isEqualToString:account.authURL], "saves the authorization link");
    CHECK([account.exportRepresentation[@"authURL"] isEqualToString:account.authURL], "exports the authorization link");
    Account *reloaded = [[Account alloc] initWithDictionary:account.dictionaryRepresentation];
    CHECK([reloaded.authURL isEqualToString:account.authURL], "reloads the authorization link");
    Account *incoming = [[Account alloc] initWithDictionary:@{@"id": account.identifier, @"name": @"x"}];
    [account applyProfileFrom:incoming];
    CHECK(account.authURL.length > 0, "an import without a link keeps the local one");
    account.authURL = nil;
    CHECK(account.authURL.length == 0 && !account.dictionaryRepresentation[@"authURL"], "clearing the link removes it");
}

static void TestPlanTiersAndTags(void) {
    CHECK([AccountCanonicalPlan(@"ChatGPT Pro 200") isEqualToString:@"Pro 200"], "reads tier names");
    CHECK([AccountCanonicalPlan(@"pro500") isEqualToString:@"Pro 500"], "reads compact tier names");
    CHECK([AccountCanonicalPlan(@"PRO") isEqualToString:@"Pro"], "keeps tier-less Pro");
    CHECK([AccountCanonicalPlan(@"team") isEqualToString:@"Business"], "maps team to Business");
    CHECK(AccountCanonicalPlan(@"Pro 300") == nil, "rejects unknown tiers");
    CHECK([AccountPlanFamily(@"Pro 100") isEqualToString:@"Pro"] && [AccountPlanFamily(@"Plus") isEqualToString:@"Plus"], "groups tiers into a family");

    Account *account = [Account accountWithName:@"x"];
    CHECK([account applyDetectedPlan:@"Pro 200" source:@"page"], "applies a detected tier");
    CHECK(![account applyDetectedPlan:@"pro" source:@"page"] && [account.plan isEqualToString:@"Pro 200"],
        "a tier-less Pro from the API keeps the known tier");
    CHECK([account applyDetectedPlan:@"plus" source:@"api"] && [account.plan isEqualToString:@"Plus"], "a different family replaces the plan");

    account.tags = @[@" 主力 ", @"备用", @"主力", @""];
    CHECK([account.tags isEqualToArray:(@[@"主力", @"备用"])], "normalizes tags");
    CHECK([account matchesSearch:@"备用"], "search covers tags");
    Account *reloaded = [[Account alloc] initWithDictionary:account.dictionaryRepresentation];
    CHECK([reloaded.tags isEqualToArray:account.tags], "round-trips tags");
    Account *incoming = [[Account alloc] initWithDictionary:@{@"id": account.identifier, @"name": @"x", @"tags": @[@"风控", @"主力"]}];
    [account applyProfileFrom:incoming];
    CHECK([account.tags isEqualToArray:(@[@"主力", @"备用", @"风控"])], "imports merge tags");
}

static void TestRenewalAndPrice(void) {
    NSDate *today = AccountDateFromDayString(@"2026-10-01");
    Account *account = [Account accountWithName:@"x"];
    account.expiresAt = @"2026-10-04";
    account.autoRenew = @YES;
    CHECK([account expiryStateFromDate:today] == AccountExpiryStateRenewing, "auto-renewing accounts are not expiring");
    CHECK([[account expiryDescriptionFromDate:today] isEqualToString:@"3 天后续费"], "describes renewals");
    CHECK([account.renewalDescription isEqualToString:@"10月4日自动续费"], "describes the renewal day");
    account.autoRenew = @NO;
    CHECK([account expiryStateFromDate:today] == AccountExpiryStateExpiringSoon, "cancelled plans expire");
    CHECK([account.renewalDescription isEqualToString:@"10月4日到期"], "describes the expiry day");

    account.plan = @"Pro 200";
    account.monthlyPrice = @8919.64;
    account.currency = @"php";
    CHECK([account.currency isEqualToString:@"PHP"], "uppercases currencies");
    CHECK([AccountFormatMoney(account.monthlyPrice, account.currency) isEqualToString:@"PHP 8,919.64"], "formats money");
    Account *reloaded = [[Account alloc] initWithDictionary:account.dictionaryRepresentation];
    CHECK([reloaded.monthlyPrice isEqual:@8919.64] && [reloaded.autoRenew isEqual:@NO], "round-trips price and renewal");

    AccountStore *store = [[AccountStore alloc] initWithFileURL:[NSURL fileURLWithPath:@"/dev/null"]];
    Account *a = [store addAccountNamed:@"a" group:nil]; a.plan = @"Pro 200"; a.monthlyPrice = @100; a.currency = @"PHP";
    Account *b = [store addAccountNamed:@"b" group:nil]; b.plan = @"Plus"; b.monthlyPrice = @20.5; b.currency = @"PHP";
    Account *c = [store addAccountNamed:@"c" group:nil]; c.plan = @"Plus"; c.monthlyPrice = @20; c.currency = @"USD";
    Account *d = [store addAccountNamed:@"d" group:nil]; d.plan = @"Free"; d.monthlyPrice = @99; d.currency = @"USD";
    NSDictionary *totals = store.monthlySpendByCurrency;
    CHECK([totals[@"PHP"] isEqual:@120.5] && [totals[@"USD"] isEqual:@20], "sums paid monthly prices per currency");
}

static void TestBillingPage(void) {
    NSString *zh = @"账单\nChatGPT Pro 200\n您的套餐将在 2026年10月25日 自动续订\n更改套餐\n交易记录\nChatGPT Pro 200\n2026/9/25\n已支付\nPHP 8,919.64\n"
        "ChatGPT Pro 200\n2026/8/25\n已支付\nPHP 8,919.64\n账单信息\n账单地址\n27072 Ballston Rd\nSheridan, OR, 97378";
    CHECK([[SubscriptionParser planFromBillingText:zh] isEqualToString:@"Pro 200"], "reads the tier from the billing page");
    NSDictionary *renewal = [SubscriptionParser renewalFromBillingText:zh];
    CHECK([renewal[@"date"] isEqualToString:@"2026-10-25"] && [renewal[@"autoRenew"] isEqual:@YES], "reads the Chinese renewal date");
    NSDictionary *price = [SubscriptionParser priceFromBillingText:zh];
    CHECK([price[@"currency"] isEqualToString:@"PHP"] && [price[@"amount"] isEqual:@8919.64], "reads the latest charge");
    CHECK([[SubscriptionParser planFromProfile:@"" details:zh] isEqualToString:@"Pro 200"], "page reads prefer the billing tier");

    NSString *en = @"Billing\nChatGPT Plus\nYour plan will be canceled on November 3, 2026\nInvoices\nOct 3, 2026 Paid US$20.00";
    NSDictionary *cancel = [SubscriptionParser renewalFromBillingText:en];
    CHECK([cancel[@"date"] isEqualToString:@"2026-11-03"] && [cancel[@"autoRenew"] isEqual:@NO], "reads a cancellation date");
    NSDictionary *usd = [SubscriptionParser priceFromBillingText:en];
    CHECK([usd[@"currency"] isEqualToString:@"USD"] && [usd[@"amount"] isEqual:@20], "reads symbol prices");
    CHECK([[SubscriptionParser renewalFromBillingText:@"Your plan renews on Oct 25, 2026"][@"autoRenew"] isEqual:@YES],
        "reads an English renewal");
    CHECK([[SubscriptionParser priceFromBillingText:@"每月 ₱9,990"][@"currency"] isEqualToString:@"PHP"], "maps peso signs");
    CHECK([SubscriptionParser priceFromBillingText:@"GPT 5 is here"] == nil, "ignores non-currency words");
    NSString *upgrade = @"升级套餐\nChatGPT Plus\nUSD 20/月\nChatGPT Pro\nUSD 200/月";
    CHECK(![SubscriptionParser isBillingText:upgrade] && [SubscriptionParser isBillingText:zh], "tells the billing page from the upgrade dialog");
    CHECK([SubscriptionParser planFromProfile:@"" details:upgrade] == nil, "the upgrade dialog does not set a plan");
}

static void TestBackendJSON(void) {
    NSDictionary *usageJSON = @{
        @"plan_type": @"pro",
        @"rate_limit": @{
            @"primary_window": @{@"used_percent": @20, @"limit_window_seconds": @18000, @"reset_at": @1790000000},
            @"secondary_window": @{@"used_percent": @91, @"limit_window_seconds": @604800, @"reset_at": @1790500000}
        },
        @"credits": @{@"has_credits": @YES, @"unlimited": @NO, @"balance": @"62500"}
    };
    NSString *planType = nil;
    AccountUsage *usage = [SubscriptionParser usageFromJSON:usageJSON planType:&planType];
    CHECK([planType isEqualToString:@"pro"], "reads plan_type");
    CHECK(usage.windows.count == 2 && usage.shortWindow.remainingPercent == 80 && usage.longWindow.remainingPercent == 9,
        "reads both usage windows");
    CHECK([usage.shortWindow.title isEqualToString:@"5 小时"] && [usage.longWindow.title isEqualToString:@"每周"], "names the windows");
    CHECK(usage.longWindow.resetAt.timeIntervalSince1970 == 1790500000, "reads reset times");
    CHECK([usage.creditBalance isEqual:@62500] && [usage.lowestRemainingPercent isEqual:@9], "reads credits and the tightest window");
    AccountUsage *roundTrip = [[AccountUsage alloc] initWithDictionary:usage.dictionaryRepresentation];
    CHECK(roundTrip.windows.count == 2 && roundTrip.longWindow.usedPercent == 91 && [roundTrip.creditBalance isEqual:@62500],
        "round-trips usage snapshots");
    CHECK([SubscriptionParser usageFromJSON:@{@"plan_type": @"free"} planType:NULL] == nil, "no windows means no snapshot");

    NSDictionary *subscription = [SubscriptionParser subscriptionFromJSON:@{
        @"active_until": @"2026-10-25T08:30:00.123456+00:00", @"will_renew": @YES, @"plan": @"chatgptpro200"}];
    CHECK(subscription[@"expiresAt"] && [subscription[@"autoRenew"] isEqual:@YES], "reads active_until and will_renew");
    CHECK([subscription[@"plan"] isEqualToString:@"Pro 200"], "spots a Pro tier in subscription values");
    NSDictionary *freeSubscription = @{@"active_until": [NSNull null], @"will_renew": [NSNull null]};
    CHECK([SubscriptionParser subscriptionFromJSON:freeSubscription] == nil, "a free account has no subscription data");
    CHECK([[SubscriptionParser planFromPlanType:@"pro"] isEqualToString:@"Pro"], "maps plan_type pro");
}

int main(void) {
    @autoreleasepool {
        TestLegacyRecords();
        TestExpiry();
        TestSearch();
        TestStore();
        TestImport();
        TestUnreadableFileIsBackedUp();
        TestParser();
        TestAuthorizationLinks();
        TestPlanTiersAndTags();
        TestRenewalAndPrice();
        TestBillingPage();
        TestBackendJSON();
    }
    printf("%d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
