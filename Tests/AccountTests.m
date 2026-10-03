#import <Foundation/Foundation.h>
#import "../Sources/Account.h"
#import "../Sources/AccountInsights.h"
#import "../Sources/AuthorizationLink.h"
#import "../Sources/ManagementScope.h"
#import "../Sources/NetworkDiagnosis.h"
#import "../Sources/SubscriptionParser.h"
#import "../Sources/WebDAVClient.h"

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


static AccountUsage *UsageWith(double shortUsed, double longUsed) {
    return [[AccountUsage alloc] initWithDictionary:@{
        @"fetchedAt": @"2026-10-01T08:00:00Z",
        @"windows": @[@{@"usedPercent": @(shortUsed), @"windowSeconds": @18000},
                      @{@"usedPercent": @(longUsed), @"windowSeconds": @604800}]}];
}

static void TestInsights(void) {
    NSDate *today = AccountDateFromDayString(@"2026-10-01");
    Account *healthy = [Account accountWithName:@"主力"];
    healthy.signedIn = @YES;
    healthy.usage = UsageWith(20, 30);
    CHECK(healthy.usage.windows.count == 2, "builds usage snapshots for insight tests");
    Account *roomy = [Account accountWithName:@"备用"];
    roomy.signedIn = @YES;
    roomy.usage = UsageWith(10, 5);
    Account *low = [Account accountWithName:@"告急"];
    low.signedIn = @YES;
    low.usage = UsageWith(10, 95);
    Account *signedOut = [Account accountWithName:@"掉线"];
    signedOut.signedIn = @NO;
    signedOut.usage = UsageWith(0, 0);
    Account *fresh = [Account accountWithName:@"新号"];

    CHECK([AccountStatus statusForAccount:signedOut now:today].kind == AccountStatusSignedOut, "signed out wins");
    AccountStatus *lowStatus = [AccountStatus statusForAccount:low now:today];
    CHECK(lowStatus.kind == AccountStatusQuotaLow && [lowStatus.title isEqualToString:@"额度剩 5%"], "reports low quota with the percentage");
    CHECK(lowStatus.tone == AccountStatusToneCritical, "low quota is critical");
    low.expiresAt = @"2026-09-20";
    CHECK([AccountStatus statusForAccount:low now:today].kind == AccountStatusExpired, "expiry outranks quota");
    healthy.expiresAt = @"2026-10-04";
    AccountStatus *soon = [AccountStatus statusForAccount:healthy now:today];
    CHECK(soon.kind == AccountStatusExpiringSoon && [soon.title isEqualToString:@"3 天后到期"], "reports an expiry within a week");
    healthy.autoRenew = @YES;
    AccountStatus *renewing = [AccountStatus statusForAccount:healthy now:today];
    CHECK(renewing.kind != AccountStatusExpiringSoon && renewing.tone == AccountStatusToneNeutral, "an auto-renewing date is not a risk");
    AccountStatus *bare = [AccountStatus statusForAccount:fresh now:today];
    CHECK(bare.kind == AccountStatusIncomplete && [bare.title isEqualToString:@"资料缺 2 项"] && bare.tone == AccountStatusToneNeutral,
        "an empty record is incomplete, not alarming");
    fresh.email = @"fresh@example.com";
    fresh.plan = @"Free";
    CHECK([AccountStatus statusForAccount:fresh now:today].kind == AccountStatusNormal, "a free account needs only email and plan");
    fresh.refreshError = @"HTTP 500";
    CHECK([AccountStatus statusForAccount:fresh now:today].kind == AccountStatusRefreshFailed, "reports refresh failures");

    Account *twin = [Account accountWithName:@"重复"];
    twin.email = @"Same@Example.com";
    healthy.email = @"same@example.com";
    NSDictionary *duplicates = AccountDuplicateEmails(@[healthy, roomy, twin, fresh]);
    CHECK(duplicates.count == 1 && [duplicates[@"same@example.com"] count] == 2, "finds emails used twice regardless of case");
    CHECK(AccountDuplicateEmails(@[roomy, fresh]).count == 0, "empty emails are not duplicates");

    healthy.monthlyPrice = @(8919.64);
    healthy.currency = @"PHP";
    healthy.tags = @[@"主力"];
    roomy.expiresAt = @"2026-10-25";
    NSString *calendar = AccountRenewalCalendar(@[healthy, roomy, fresh]);
    CHECK([calendar hasPrefix:@"BEGIN:VCALENDAR\r\n"] && [calendar hasSuffix:@"END:VCALENDAR\r\n"], "writes a calendar with CRLF lines");
    CHECK([calendar componentsSeparatedByString:@"BEGIN:VEVENT"].count == 3, "adds one event per account with a date");
    CHECK([calendar containsString:@"DTSTART;VALUE=DATE:20261004"] && [calendar containsString:@"DTEND;VALUE=DATE:20261005"],
        "uses all-day events");
    CHECK([calendar componentsSeparatedByString:@"RRULE:FREQ=MONTHLY"].count == 2, "repeats only auto-renewing accounts");
    CHECK([calendar containsString:@"PHP 8\\,919.64"], "escapes commas in text");
    CHECK([calendar containsString:@"TRIGGER:-P1D"], "reminds a day before");
    BOOL folded = YES;
    for (NSString *line in [calendar componentsSeparatedByString:@"\r\n"])
        if ([line lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 75) folded = NO;
    CHECK(folded, "folds long lines at 75 octets");

    NSDictionary *proxy = AccountProxyComponents(@"127.0.0.1:7890");
    CHECK([proxy[@"scheme"] isEqualToString:@"http"] && [proxy[@"host"] isEqualToString:@"127.0.0.1"] && [proxy[@"port"] isEqual:@7890],
        "reads a bare host:port as an HTTP proxy");
    proxy = AccountProxyComponents(@" socks5://user:p%40ss@proxy.example.com:1080 ");
    CHECK([proxy[@"scheme"] isEqualToString:@"socks5"] && [proxy[@"user"] isEqualToString:@"user"] &&
        [proxy[@"password"] isEqualToString:@"p@ss"], "reads SOCKS5 proxies with credentials");
    CHECK(AccountProxyComponents(@"ftp://host:21") == nil && AccountProxyComponents(@"host") == nil &&
        AccountProxyComponents(@"") == nil && AccountProxyComponents(@"http://host:99999") == nil, "rejects non-proxy text");

    NSURL *historyURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"usage-history-%@.json", NSUUID.UUID.UUIDString]]];
    UsageHistory *history = [[UsageHistory alloc] initWithFileURL:historyURL];
    NSDate *start = [NSDate dateWithTimeIntervalSince1970:1790000000];
    for (int hour = 0; hour < 4; hour++) {
        AccountUsageWindow *weekly = [AccountUsageWindow new];
        weekly.windowSeconds = 604800;
        weekly.usedPercent = 40 + hour * 10;
        [history recordUsageWindows:@[weekly] forAccountID:WorkID at:[start dateByAddingTimeInterval:hour * 3600]];
    }
    AccountUsageWindow *repeat = [AccountUsageWindow new];
    repeat.windowSeconds = 604800;
    repeat.usedPercent = 70;
    [history recordUsageWindows:@[repeat] forAccountID:WorkID at:[start dateByAddingTimeInterval:3 * 3600 + 30]];
    CHECK([history pointsForAccountID:WorkID].count == 4, "skips an identical reading taken right after the last one");
    NSError *error = nil;
    CHECK([history save:&error], "saves usage history");
    UsageHistory *reloaded = [[UsageHistory alloc] initWithFileURL:historyURL];
    NSArray *points = [reloaded pointsForAccountID:WorkID];
    CHECK(points.count == 4 && [points.lastObject[@"long"] isEqual:@30], "reloads usage history");

    AccountUsageWindow *current = [AccountUsageWindow new];
    current.windowSeconds = 604800;
    current.usedPercent = 70;
    NSDate *now = [start dateByAddingTimeInterval:3 * 3600];
    current.resetAt = [now dateByAddingTimeInterval:3 * 86400];
    NSDate *exhaustion = [UsageHistory predictedExhaustionOfWindow:current key:@"long" points:points now:now];
    CHECK(exhaustion && fabs(exhaustion.timeIntervalSince1970 - (now.timeIntervalSince1970 + 3 * 3600)) < 60,
        "projects 10% an hour to run out three hours later");
    current.resetAt = [now dateByAddingTimeInterval:3600];
    CHECK([UsageHistory predictedExhaustionOfWindow:current key:@"long" points:points now:now] == nil,
        "no warning when the window resets first");
    current.resetAt = [now dateByAddingTimeInterval:3 * 86400];
    CHECK([UsageHistory predictedExhaustionOfWindow:current key:@"short" points:points now:now] == nil,
        "needs readings of the same window");
    NSDate *later = [start dateByAddingTimeInterval:9 * 86400];
    AccountUsageWindow *weekly = [AccountUsageWindow new];
    weekly.windowSeconds = 604800;
    weekly.usedPercent = 5;
    [reloaded recordUsageWindows:@[weekly] forAccountID:WorkID at:later];
    CHECK([reloaded pointsForAccountID:WorkID].count == 1, "drops readings older than eight days");
    [reloaded removeAccountIDs:@[WorkID]];
    CHECK([reloaded pointsForAccountID:WorkID].count == 0, "forgets removed accounts");
    [NSFileManager.defaultManager removeItemAtURL:historyURL error:nil];

    Account *proxied = [[Account alloc] initWithDictionary:@{@"id": TeamID, @"name": @"代理", @"proxy": @" socks5://127.0.0.1:1080 "}];
    CHECK([proxied.proxy isEqualToString:@"socks5://127.0.0.1:1080"] &&
        [proxied.dictionaryRepresentation[@"proxy"] isEqualToString:@"socks5://127.0.0.1:1080"], "stores a per-account proxy");
    proxied.proxy = @"http://me:secret@10.0.0.2:3128";
    CHECK([proxied.exportRepresentation[@"proxy"] isEqualToString:@"http://me@10.0.0.2:3128"] &&
        [proxied.dictionaryRepresentation[@"proxy"] containsString:@"secret"], "exports leave the proxy password behind");
}

static void TestWebDAV(void) {
    NSString *xml = @"<?xml version=\"1.0\"?><D:multistatus xmlns:D=\"DAV:\" xmlns:lp1=\"DAV:\">"
        "<D:response><D:href>/dav/Zhishu%20Matrix/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype>"
        "</D:prop></D:propstat></D:response>"
        "<D:response><D:href>https://dav.example.com/dav/Zhishu%20Matrix/zhishu-matrix-20261001-120000.json</D:href>"
        "<D:propstat><D:prop><lp1:getlastmodified>Thu, 01 Oct 2026 12:00:05 GMT</lp1:getlastmodified>"
        "<D:getcontentlength>2048</D:getcontentlength><D:resourcetype/></D:prop></D:propstat></D:response>"
        "<D:response><D:href>/dav/Zhishu%20Matrix/old/zhishu-matrix-20250101-000000.json</D:href><D:propstat><D:prop>"
        "<D:resourcetype/></D:prop></D:propstat></D:response>"
        "<D:response><D:href>/dav/Zhishu%20Matrix/sub/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype>"
        "</D:prop></D:propstat></D:response>"
        "<d:response xmlns:d=\"DAV:\"><d:href>/dav/Zhishu%20Matrix/notes.txt</d:href></d:response>"
        "</D:multistatus>";
    NSArray<WebDAVFile *> *files = [WebDAVClient filesFromMultistatus:[xml dataUsingEncoding:NSUTF8StringEncoding]
        folderPath:@"/dav/Zhishu Matrix"];
    CHECK(files.count == 2, "lists only the files directly inside the folder");
    WebDAVFile *backup = files.firstObject;
    CHECK([backup.name isEqualToString:@"zhishu-matrix-20261001-120000.json"] && backup.size == 2048, "reads names and sizes");
    CHECK(backup.modifiedAt.timeIntervalSince1970 == 1790856005, "reads modification dates");
    CHECK([WebDAVClient filesFromMultistatus:[@"not xml" dataUsingEncoding:NSUTF8StringEncoding] folderPath:@"/"].count == 0,
        "ignores unreadable replies");
    WebDAVClient *client = [[WebDAVClient alloc] initWithServer:@" https://dav.jianguoyun.com/dav " folder:@"/智枢矩阵/备份/"
        username:@"me" password:@"pw"];
    CHECK([client.folderURL.absoluteString isEqualToString:
        @"https://dav.jianguoyun.com/dav/%E6%99%BA%E6%9E%A2%E7%9F%A9%E9%98%B5/%E5%A4%87%E4%BB%BD/"], "joins server and folder");
    CHECK([[WebDAVClient alloc] initWithServer:@"ftp://example.com" folder:nil username:@"" password:@""] == nil,
        "only accepts http(s) servers");
    CHECK([[WebDAVClient messageForStatus:401] containsString:@"密码"], "explains authentication failures");
}

static void TestAlerts(void) {
    NSDate *now = AccountDateFromDayString(@"2026-10-01");
    Account *main = [[Account alloc] initWithDictionary:@{@"id": WorkID, @"name": @"主力"}];
    main.signedIn = @YES;
    main.usage = UsageWith(10, 92);
    main.usage.longWindow.resetAt = [now dateByAddingTimeInterval:2 * 86400];
    Account *spare = [[Account alloc] initWithDictionary:@{@"id": HomeID, @"name": @"备用"}];
    spare.signedIn = @YES;
    spare.usage = UsageWith(0, 24);
    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    AccountAlertKinds all = AccountAlertQuota | AccountAlertRenewal | AccountAlertSignedOut;

    NSArray *alerts = AccountAlertsDue(@[main, spare], now, state, all);
    CHECK(alerts.count == 1 && [alerts[0][@"kind"] isEqualToString:@"quota"], "announces a window running low");
    CHECK([alerts[0][@"title"] isEqualToString:@"“主力”额度告急：每周剩 8%"], "names the account and the window");
    CHECK([alerts[0][@"body"] isEqualToString:@"2 天后重置。"], "says when the window resets");
    CHECK(alerts[0][@"recommendedID"] == nil && ![alerts[0][@"body"] containsString:@"备用"], "suggests no other account");
    CHECK(AccountAlertsDue(@[main, spare], now, state, all).count == 0, "announces each low window once");

    NSData *saved = [NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
    NSMutableDictionary *restored = [[NSJSONSerialization JSONObjectWithData:saved options:NSJSONReadingMutableContainers error:nil] mutableCopy];
    CHECK(saved && AccountAlertsDue(@[main, spare], now, restored, all).count == 0, "remembers announcements across launches");

    main.usage = UsageWith(0, 95);
    main.usage.longWindow.resetAt = [now dateByAddingTimeInterval:2 * 86400 + 300];
    CHECK(AccountAlertsDue(@[main, spare], now, state, all).count == 0, "small drifts in the reset time are the same period");
    main.usage = UsageWith(0, 0);
    main.usage.longWindow.resetAt = [now dateByAddingTimeInterval:9 * 86400];
    alerts = AccountAlertsDue(@[main, spare], now, state, all);
    CHECK(alerts.count == 1 && [alerts[0][@"kind"] isEqualToString:@"reset"] && [alerts[0][@"title"] containsString:@"已恢复"],
        "announces when a low window recovers");
    CHECK(AccountAlertsDue(@[main, spare], now, state, AccountAlertRenewal).count == 0, "respects disabled kinds");

    spare.signedIn = @NO;
    alerts = AccountAlertsDue(@[main, spare], now, state, all);
    CHECK(alerts.count == 1 && [alerts[0][@"kind"] isEqualToString:@"signedOut"], "announces a lost sign-in");
    CHECK(AccountAlertsDue(@[main, spare], now, state, all).count == 0, "announces a lost sign-in once");
    Account *fresh = [Account accountWithName:@"新号"];
    fresh.signedIn = @NO;
    CHECK(AccountAlertsDue(@[main, fresh], now, state, all).count == 0, "never-signed-in accounts are not announced");
    AccountAlertsForgetSignIn(state, @[WorkID]);
    main.signedIn = @NO;
    CHECK(AccountAlertsDue(@[main], now, state, all).count == 0, "a deliberate sign-out is not announced");

    Account *renewing = [[Account alloc] initWithDictionary:@{@"id": TeamID, @"name": @"续费号", @"expiresAt": @"2026-10-02",
        @"autoRenew": @YES, @"plan": @"Pro 200", @"monthlyPrice": @(8919.64), @"currency": @"PHP"}];
    Account *ending = [Account accountWithName:@"到期号"];
    ending.expiresAt = @"2026-10-04";
    Account *later = [Account accountWithName:@"远期"];
    later.expiresAt = @"2026-10-20";
    alerts = AccountAlertsDue(@[renewing, ending, later], now, state, AccountAlertRenewal);
    CHECK(alerts.count == 2, "reminds about renewals tomorrow and expiries within three days");
    CHECK([alerts[0][@"title"] isEqualToString:@"“续费号”明天自动续费"] && [alerts[0][@"body"] containsString:@"PHP 8,919.64"],
        "mentions the renewal price");
    CHECK([alerts[1][@"title"] isEqualToString:@"“到期号”3 天后到期"], "counts the days to expiry");
    CHECK(AccountAlertsDue(@[renewing, ending, later], now, state, AccountAlertRenewal).count == 0, "reminds once per stage");
    NSDate *nextDay = AccountDateFromDayString(@"2026-10-03");
    alerts = AccountAlertsDue(@[renewing, ending, later], nextDay, state, AccountAlertRenewal);
    CHECK(alerts.count == 2 && [alerts[0][@"title"] isEqualToString:@"“到期号”明天到期"], "reminds again the day before");
    CHECK([alerts[1][@"kind"] isEqualToString:@"payment"] && [alerts[1][@"date"] isEqualToString:@"2026-10-02"] &&
        [alerts[1][@"title"] isEqualToString:@"“续费号”已于 2026-10-02 续费，记一笔付款？"], "asks to record the renewal payment");
    CHECK(AccountAlertsDue(@[renewing, ending, later], nextDay, state, AccountAlertRenewal).count == 0, "asks once per renewal");
    AccountAlertsDue(@[ending], nextDay, state, AccountAlertRenewal);
    CHECK(![[state[@"renewal"] componentsJoinedByString:@","] containsString:TeamID], "forgets reminders of removed accounts");
}

static void TestScopes(void) {
    NSDate *now = AccountDateFromDayString(@"2026-10-01");
    Account *a = [[Account alloc] initWithDictionary:@{@"id": WorkID, @"name": @"A", @"email": @"x@example.com", @"group": @"客户",
        @"tags": @[@"主力"], @"expiresAt": @"2026-10-03"}];
    a.usage = UsageWith(0, 90);
    a.signedIn = @YES;
    Account *b = [[Account alloc] initWithDictionary:@{@"id": HomeID, @"name": @"B", @"email": @"X@example.com", @"expiresAt": @"2026-10-03",
        @"autoRenew": @YES}];
    NSSet *duplicates = AccountDuplicateIDs(@[a, b]);
    CHECK(duplicates.count == 2, "collects accounts sharing an email");
    CHECK([[ManagementScope scopeWithKind:ManagementScopeQuotaLow value:nil] includesAccount:a now:now duplicateIDs:duplicates] &&
        ![[ManagementScope scopeWithKind:ManagementScopeQuotaLow value:nil] includesAccount:b now:now duplicateIDs:duplicates],
        "quota scope lists low accounts");
    ManagementScope *expiring = [ManagementScope scopeWithKind:ManagementScopeExpiring value:nil];
    CHECK([expiring includesAccount:a now:now duplicateIDs:duplicates] && ![expiring includesAccount:b now:now duplicateIDs:duplicates],
        "expiring scope skips auto-renewing accounts");
    CHECK([[ManagementScope scopeWithKind:ManagementScopeSignedOut value:nil] includesAccount:b now:now duplicateIDs:duplicates],
        "accounts never checked count as signed out");
    CHECK([[ManagementScope scopeWithKind:ManagementScopeGroup value:@""] includesAccount:b now:now duplicateIDs:duplicates] &&
        [[ManagementScope scopeWithKind:ManagementScopeTag value:@"主力"] includesAccount:a now:now duplicateIDs:duplicates],
        "group and tag scopes");
    ManagementScope *tag = [ManagementScope scopeFromString:@"tag:主力:备用"];
    CHECK(tag.kind == ManagementScopeTag && [tag.value isEqualToString:@"主力:备用"] &&
        [[ManagementScope scopeFromString:tag.stringValue] isEqual:tag], "round-trips scopes through strings");
    CHECK([ManagementScope scopeFromString:@"group"] == nil && [ManagementScope scopeFromString:@"nonsense"] == nil, "rejects bad scopes");
    CHECK([[ManagementScope scopeWithKind:ManagementScopeGroup value:@""].title isEqualToString:@"未分组"], "names the ungrouped list");
}

static void TestPayments(void) {
    CHECK([AccountCardLast4(@"6222 0212 3456 7890") isEqualToString:@"7890"], "keeps only the last four card digits");
    CHECK([AccountCardLast4(@"尾号 1234") isEqualToString:@"1234"] && [AccountCardLast4(@"12") isEqualToString:@""],
        "rejects fewer than four digits");
    NSArray *expectedSuppliers = @[@"Google Play", @"iOS", @"世事宜AI", @"Bewild"];
    CHECK([AccountSuppliers() isEqualToArray:expectedSuppliers], "offers the four suppliers");

    Account *account = [[Account alloc] initWithDictionary:@{@"id": WorkID, @"name": @"主力", @"supplier": @" 世事宜AI ",
        @"paymentMethod": @"信用卡", @"cardLast4": @"4111 1111 1111 1234", @"monthlyPrice": @100, @"currency": @"usd",
        @"payments": @[@{@"date": @"2026-08-25", @"amount": @100, @"currency": @"USD", @"cardLast4": @"1234"},
                       @{@"date": @"2026-09-25", @"amount": @"100.00", @"currency": @"USD", @"note": @"续费"},
                       @{@"date": @"bad", @"amount": @1}]}];
    CHECK([account.supplier isEqualToString:@"世事宜AI"] && [account.cardLast4 isEqualToString:@"1234"], "reads payment details");
    CHECK(account.payments.count == 2 && [account.lastPayment.date isEqualToString:@"2026-09-25"], "keeps valid payments newest first");
    CHECK([account.paymentSummary isEqualToString:@"世事宜AI · 信用卡 · 尾号 1234"], "summarises the payment details");
    CHECK([account matchesSearch:@"1234"] && [account matchesSearch:@"世事宜"], "search covers payment details");
    NSDictionary *saved = account.dictionaryRepresentation;
    CHECK([saved[@"cardLast4"] isEqualToString:@"1234"] && [saved[@"payments"] count] == 2 &&
        [saved[@"payments"][0][@"note"] isEqualToString:@"续费"], "saves payment details");
    Account *reloaded = [[Account alloc] initWithDictionary:saved];
    CHECK([reloaded.lastPayment.identifier isEqualToString:account.lastPayment.identifier], "keeps payment ids across saves");

    AccountPayment *duplicate = [[AccountPayment alloc] initWithDictionary:@{@"date": @"2026-09-25", @"amount": @100, @"currency": @"USD"}];
    AccountPayment *october = [[AccountPayment alloc] initWithDictionary:@{@"date": @"2026-10-25", @"amount": @100, @"currency": @"USD"}];
    NSArray *incoming = @[duplicate, october];
    CHECK([account addPayments:incoming] == 1 && account.payments.count == 3, "skips charges already recorded");

    NSDictionary *rates = @{@"USD": @7.1, @"CNY": @1};
    CHECK([AccountAmountInCNY(@100, @"USD", rates) doubleValue] == 710, "converts with the given rate");
    CHECK([AccountAmountInCNY(@50, @"RMB", @{}) doubleValue] == 50 && AccountAmountInCNY(@5, @"PHP", rates) == nil,
        "CNY needs no rate; other currencies do");
    CHECK([AccountFormatCNY(@1115.5) isEqualToString:@"¥1,115.50"], "formats yuan");

    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    AccountStore *store = [[AccountStore alloc] initWithFileURL:url];
    [store load:nil];
    Account *added = [store addAccountNamed:@"菲律宾号" group:nil];
    added.plan = @"Pro 200";
    added.monthlyPrice = @8919.64;
    added.currency = @"PHP";
    added.supplier = @"Bewild";
    Account *dollar = [store addAccountNamed:@"美元号" group:nil];
    dollar.plan = @"Plus";
    dollar.monthlyPrice = @20;
    dollar.currency = @"USD";
    dollar.supplier = @"iOS";
    [dollar addPayments:@[october]];
    NSArray *missing = nil;
    double monthly = [store monthlySpendInCNYWithRates:rates missingCurrencies:&missing];
    NSArray *expectedMissing = @[@"PHP"];
    CHECK(fabs(monthly - 142) < 0.001 && [missing isEqualToArray:expectedMissing], "totals in CNY and lists currencies without a rate");
    NSArray *suppliers = store.suppliers;
    CHECK(suppliers.count == 4 && [suppliers containsObject:@"Bewild"], "lists the default suppliers once");
    NSData *data = [store paymentsCSVWithRates:rates];
    const unsigned char *bytes = data.bytes;
    NSString *csv = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    CHECK(data.length > 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF, "starts the CSV with a BOM for Excel");
    CHECK([csv hasPrefix:@"日期,类型,账号"] && [csv containsString:@"2026-10-25,付款,美元号,,Plus,,,,100,USD,710.00,,手动"],
        "exports payments as CSV with yuan amounts");
    [NSFileManager.defaultManager removeItemAtURL:url error:nil];
}

static void TestBillingPayments(void) {
    NSString *billing = @"账单\nChatGPT Pro 200\n您的套餐将在 2026年10月25日 自动续订。\n付款方式\nVisa •••• 4242\n管理订阅\n交易记录\n"
        "2026年9月25日\nPHP 8,919.64\n已支付\n2026年8月25日\nPHP 8,919.64\n已支付\n2026年7月25日 PHP 8,919.64 失败\n"
        "2026年6月25日 ₱1,099.00 已退款";
    NSArray *payments = [SubscriptionParser paymentsFromBillingText:billing];
    CHECK(payments.count == 5 && [payments[0][@"date"] isEqualToString:@"2026-09-25"] &&
        [payments[0][@"amount"] isEqual:@8919.64] && [payments[0][@"currency"] isEqualToString:@"PHP"] &&
        [payments[0][@"kind"] isEqualToString:@""], "reads paid charges from the payment history");
    CHECK([payments[2][@"date"] isEqualToString:@"2026-07-25"] && [payments[2][@"kind"] isEqualToString:@"failed"],
        "keeps failed charges as failed");
    NSMutableSet *june = [NSMutableSet set];
    for (NSDictionary *payment in payments)
        if ([payment[@"date"] isEqualToString:@"2026-06-25"]) [june addObject:payment[@"kind"]];
    CHECK([june isEqualToSet:([NSSet setWithObjects:@"", @"refund", nil])], "a refunded invoice is a payment and its refund");
    CHECK([SubscriptionParser paymentsFromBillingText:@"交易记录\n2026年5月25日 $20.00 Pending\n2026年4月25日 $20.00 Void"].count == 0,
        "pending and void invoices are not payments");
    CHECK([SubscriptionParser paymentsFromBillingText:@"您的套餐将在 2026年10月25日 自动续订 PHP 8,919.64"].count == 0,
        "the renewal sentence is not a payment");
    CHECK([[SubscriptionParser cardLast4FromBillingText:billing] isEqualToString:@"4242"], "reads the card's last digits");
    CHECK([[SubscriptionParser cardLast4FromBillingText:@"Mastercard ending in 5555"] isEqualToString:@"5555"], "reads 'ending in'");
    CHECK([SubscriptionParser cardLast4FromBillingText:@"ChatGPT Pro 200 2026年10月25日"] == nil, "no card, no digits");
    NSString *apple = @"账单\nChatGPT Plus\n你的订阅通过 Apple 管理。请在 App Store 中管理或取消订阅。";
    CHECK([SubscriptionParser isBillingText:apple] && [[SubscriptionParser supplierFromBillingText:apple] isEqualToString:@"iOS"],
        "recognises subscriptions managed by Apple");
    CHECK([[SubscriptionParser supplierFromBillingText:@"Your subscription is managed through Google Play."] isEqualToString:@"Google Play"],
        "recognises Google Play subscriptions");
    CHECK([SubscriptionParser supplierFromBillingText:billing] == nil, "web subscriptions name no store");
}

static void TestAuthorizationRecords(void) {
    NSURL *link = [NSURL URLWithString:@"https://auth.openai.com/oauth/authorize?response_type=code&client_id=app_123"
        "&redirect_uri=https%3A%2F%2Fwww.example.com%2Fauth%2Fcallback&scope=openid%20email&state=xyz"];
    NSDictionary *request = AuthorizationRequestFromURL(link);
    CHECK([request[@"clientID"] isEqualToString:@"app_123"] && [request[@"redirect"] isEqualToString:@"https://www.example.com/auth/callback"]
        && [request[@"scope"] isEqualToString:@"openid email"], "reads client_id, redirect_uri and scope");
    CHECK(AuthorizationRequestFromURL([NSURL URLWithString:@"https://chatgpt.com/"]) == nil, "an ordinary page is no request");
    CHECK(AuthorizationURLMatchesRedirect([NSURL URLWithString:@"https://www.example.com/auth/callback?code=1"], request[@"redirect"]) &&
        !AuthorizationURLMatchesRedirect([NSURL URLWithString:@"https://www.example.com/other?code=1"], request[@"redirect"]),
        "matches the redirect address by origin and path");
    CHECK(AuthorizationCallbackSucceeded([NSURL URLWithString:@"https://x.test/cb?code=abc&state=1"]) &&
        !AuthorizationCallbackSucceeded([NSURL URLWithString:@"https://x.test/cb?error=access_denied"]) &&
        AuthorizationCallbackSucceeded([NSURL URLWithString:@"https://x.test/cb#access_token=t"]), "tells success from refusal");
    CHECK([AuthorizationAppName(request[@"redirect"]) isEqualToString:@"example.com"] &&
        [AuthorizationAppName(@"http://localhost:1455/auth/callback") isEqualToString:@"本机应用（localhost:1455）"] &&
        [AuthorizationAppName(@"cursor://auth/callback") isEqualToString:@"cursor"], "names apps after their redirect address");

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults removeObjectForKey:AuthorizationDefaultAppNameDefaultsKey];
    CHECK([AuthorizationDefaultAppName() isEqualToString:@"AI服务中心"], "names new records AI服务中心 by default");
    [defaults setObject:@"  " forKey:AuthorizationDefaultAppNameDefaultsKey];
    CHECK(AuthorizationDefaultAppName().length == 0, "a cleared default name falls back to the redirect address");
    [defaults removeObjectForKey:AuthorizationDefaultAppNameDefaultsKey];

    Account *account = [[Account alloc] initWithDictionary:@{@"id": WorkID, @"name": @"主力"}];
    NSDate *first = [NSDate dateWithTimeIntervalSince1970:1790000000];
    AccountAuthorization *entry = [account recordAuthorizationWithClientID:@"app_123" redirect:request[@"redirect"] scope:@"openid"
        appName:@"example.com" at:first];
    entry.appName = @"示例应用";
    entry.revokedAt = first;
    CHECK(account.activeAuthorizations.count == 0, "revoked authorizations are not active");
    AccountAuthorization *again = [account recordAuthorizationWithClientID:@"app_123" redirect:@"https://www.example.com/auth/callback"
        scope:@"openid email" appName:@"example.com" at:[first dateByAddingTimeInterval:86400]];
    CHECK(again == entry && account.authorizations.count == 1 && entry.count == 2 && !entry.revoked,
        "authorizing the same app again revives and counts the entry");
    CHECK([entry.appName isEqualToString:@"示例应用"] && [entry.scope isEqualToString:@"openid email"], "keeps the given name");
    [account recordAuthorizationWithClientID:nil redirect:@"http://localhost:8765/cb" scope:nil appName:@"本机应用（localhost:8765）"
        at:[first dateByAddingTimeInterval:172800]];
    CHECK(account.authorizations.count == 2 && [account.authorizations.firstObject.redirect isEqualToString:@"http://localhost:8765/cb"],
        "a different app gets its own entry, newest first");
    CHECK([account matchesSearch:@"示例"], "search covers authorized apps");

    Account *reloaded = [[Account alloc] initWithDictionary:account.dictionaryRepresentation];
    AccountAuthorization *saved = reloaded.authorizations.lastObject;
    CHECK(reloaded.authorizations.count == 2 && [saved.identifier isEqualToString:entry.identifier] && saved.count == 2 &&
        [saved.firstAuthorizedAt isEqualToDate:first] && [account.exportRepresentation[@"authorizations"] count] == 2,
        "saves and exports authorization records");

    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    AccountStore *store = [[AccountStore alloc] initWithFileURL:url];
    [store load:nil];
    Account *one = [store addAccountNamed:@"一" group:nil];
    Account *two = [store addAccountNamed:@"二" group:nil];
    [one recordAuthorizationWithClientID:@"a" redirect:nil scope:nil appName:@"Notion" at:first];
    [two recordAuthorizationWithClientID:@"b" redirect:nil scope:nil appName:@"Cursor" at:first];
    [two recordAuthorizationWithClientID:@"c" redirect:nil scope:nil appName:@"Zed" at:first].revokedAt = first;
    NSArray *apps = store.authorizedApps;
    NSArray *expectedApps = @[@"Cursor", @"Notion"];
    CHECK([apps isEqualToArray:expectedApps], "lists apps with active authorizations");
    ManagementScope *cursor = [ManagementScope scopeWithKind:ManagementScopeAuthorizedApp value:@"Cursor"];
    CHECK([cursor includesAccount:two now:first duplicateIDs:[NSSet set]] && ![cursor includesAccount:one now:first duplicateIDs:[NSSet set]],
        "the app list shows the accounts that authorized it");
    CHECK([[ManagementScope scopeFromString:cursor.stringValue] isEqual:cursor] &&
        [ManagementScope scopeFromString:@"incomplete"].kind == ManagementScopeIncomplete &&
        [ManagementScope scopeFromString:@"incomplete:x"] == nil && [ManagementScope scopeFromString:@"app"] == nil,
        "round-trips the new lists");
    [NSFileManager.defaultManager removeItemAtURL:url error:nil];
}

static void TestCompleteness(void) {
    NSDate *now = AccountDateFromDayString(@"2026-10-02");
    Account *account = [Account accountWithName:@"空"];
    NSArray *missing = AccountMissingFields(account, now);
    NSArray *bare = @[@"邮箱", @"订阅级别"];
    CHECK([missing isEqualToArray:bare], "an empty record lacks email and plan");
    account.email = @"a@example.com";
    account.plan = @"Pro 200";
    missing = AccountMissingFields(account, now);
    NSArray *paid = @[@"续费 / 到期日期", @"月费", @"供应商", @"付款方式", @"付款记录"];
    CHECK([missing isEqualToArray:paid], "a paid account needs renewal, price, supplier, method and payments");
    account.expiresAt = @"2026-10-25";
    account.monthlyPrice = @1599;
    account.supplier = @"iOS";
    account.paymentMethod = @"信用卡";
    NSArray *card = @[@"币种", @"卡尾号", @"付款记录"];
    CHECK([AccountMissingFields(account, now) isEqualToArray:card], "a card payment needs its last digits; a price needs a currency");
    account.paymentMethod = @"礼品卡 / 余额";
    CHECK(![AccountMissingFields(account, now) containsObject:@"卡尾号"], "gift cards have no card number");
    account.currency = @"CNY";
    account.autoRenew = @YES;
    [account addPayments:@[[[AccountPayment alloc] initWithDictionary:@{@"date": @"2026-08-20", @"amount": @1599, @"currency": @"CNY"}]]];
    NSArray *stale = @[@"近 35 天未记付款"];
    CHECK([AccountMissingFields(account, now) isEqualToArray:stale], "an auto-renewing account with no recent payment is flagged");
    [account addPayments:@[[[AccountPayment alloc] initWithDictionary:@{@"date": @"2026-09-20", @"amount": @1599, @"currency": @"CNY"}]]];
    CHECK(AccountMissingFields(account, now).count == 0, "a complete record lacks nothing");
    CHECK([AccountStatus statusForAccount:account now:now].kind == AccountStatusNormal, "and has no status");
    account.autoRenew = @NO;
    account.expiresAt = @"2026-10-05";
    CHECK([AccountStatus statusForAccount:account now:now].kind == AccountStatusExpiringSoon, "real risks outrank completeness");
    ManagementScope *incomplete = [ManagementScope scopeWithKind:ManagementScopeIncomplete value:nil];
    account.supplier = @"";
    CHECK([incomplete includesAccount:account now:now duplicateIDs:[NSSet set]], "the incomplete list includes it");
}

static void TestPaymentsDue(void) {
    NSDate *now = AccountDateFromDayString(@"2026-10-02");
    Account *account = [[Account alloc] initWithDictionary:@{@"id": WorkID, @"name": @"主力", @"plan": @"Pro 200",
        @"expiresAt": @"2026-10-19", @"autoRenew": @YES, @"monthlyPrice": @1599, @"currency": @"CNY"}];
    CHECK([AccountUnrecordedRenewal(account, now) isEqualToString:@"2026-09-19"], "the current period's renewal needs a payment");
    [account addPayments:@[[[AccountPayment alloc] initWithDictionary:@{@"date": @"2026-09-17", @"amount": @1599, @"currency": @"CNY"}]]];
    CHECK(AccountUnrecordedRenewal(account, now) == nil, "a payment around the renewal counts");
    account.expiresAt = @"2026-10-02";
    CHECK([AccountUnrecordedRenewal(account, now) isEqualToString:@"2026-10-02"], "renewal day itself is due before the date moves on");
    account.autoRenew = @NO;
    CHECK(AccountUnrecordedRenewal(account, now) == nil, "manual renewals are not predicted");
    account.autoRenew = @YES;
    account.plan = @"Free";
    CHECK(AccountUnrecordedRenewal(account, now) == nil, "free accounts pay nothing");

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:@[@{@"supplier": @"世事宜AI", @"plan": @"Pro 200", @"amount": @1599, @"currency": @"cny"},
                          @{@"supplier": @"iOS", @"plan": @"plus", @"amount": @"158", @"currency": @"CNY"},
                          @{@"supplier": @"", @"plan": @"Plus", @"amount": @1}] forKey:SupplierPricesDefaultsKey];
    CHECK(AccountSupplierPrices().count == 2, "ignores incomplete price list entries");
    CHECK([AccountListedPrice(@"iOS", @"Plus")[@"amount"] isEqual:@158] && AccountListedPrice(@"iOS", @"Pro 200") == nil,
        "looks prices up by supplier and plan");
    Account *reseller = [Account accountWithName:@"代充"];
    reseller.plan = @"Pro 200";
    reseller.supplier = @"世事宜AI";
    CHECK([reseller applyListedPrice] && [reseller.monthlyPrice isEqual:@1599] && [reseller.currency isEqualToString:@"CNY"] &&
        [reseller.priceSource isEqualToString:@"list"], "fills the price from the list");
    CHECK(![reseller applyListedPrice], "applying the same price again changes nothing");
    reseller.monthlyPrice = @1499;
    reseller.priceSource = @"manual";
    CHECK(![reseller applyListedPrice] && [reseller.monthlyPrice isEqual:@1499], "a price typed by hand wins");
    CHECK([reseller.expectedCharge[@"amount"] isEqual:@1599], "expects the listed price for the next charge");
    Account *saved = [[Account alloc] initWithDictionary:reseller.dictionaryRepresentation];
    CHECK([saved.priceSource isEqualToString:@"manual"], "saves where the price came from");
    [defaults removeObjectForKey:SupplierPricesDefaultsKey];
}

static void TestExpenseReport(void) {
    Account *ios = [[Account alloc] initWithDictionary:@{@"id": WorkID, @"name": @"苹果号", @"plan": @"Plus", @"supplier": @"iOS",
        @"paymentMethod": @"信用卡", @"cardLast4": @"1234", @"expiresAt": @"2026-10-19", @"autoRenew": @YES,
        @"monthlyPrice": @158, @"currency": @"CNY", @"createdAt": @"2026-08-01T00:00:00Z",
        @"payments": @[@{@"date": @"2026-08-19", @"amount": @158, @"currency": @"CNY"},
                       @{@"date": @"2026-09-19", @"amount": @158, @"currency": @"CNY"},
                       @{@"date": @"2025-12-19", @"amount": @158, @"currency": @"CNY"}]}];
    Account *reseller = [[Account alloc] initWithDictionary:@{@"id": HomeID, @"name": @"代充号", @"plan": @"Pro 200",
        @"supplier": @"世事宜AI", @"paymentMethod": @"支付宝", @"expiresAt": @"2026-10-05", @"autoRenew": @NO,
        @"monthlyPrice": @1599, @"currency": @"CNY",
        @"payments": @[@{@"date": @"2026-09-05", @"amount": @1599, @"currency": @"CNY"},
                       @{@"date": @"2026-09-06", @"amount": @20, @"currency": @"USD", @"supplier": @"Bewild"},
                       @{@"date": @"2026-09-07", @"amount": @100, @"currency": @"PHP"}]}];
    NSDictionary *rates = @{@"USD": @7, @"CNY": @1};
    AccountExpenseReport *report = [AccountExpenseReport reportForAccounts:@[ios, reseller] year:2026 rates:rates];
    CHECK(report.count == 4 && fabs(report.total - (158 * 2 + 1599 + 140)) < 0.001, "totals the year's payments in CNY");
    CHECK([report.monthTotals[7] isEqual:@158] && fabs(report.monthTotals[8].doubleValue - (158 + 1599 + 140)) < 0.001 &&
        [report.monthTotals[11] isEqual:@0], "splits the total by month");
    CHECK([report.monthSupplierTotals[8][@"Bewild"] isEqual:@140], "keeps each payment's own supplier");
    CHECK([report.bySupplier.firstObject[@"name"] isEqualToString:@"世事宜AI"] && [report.bySupplier.firstObject[@"count"] isEqual:@1],
        "ranks suppliers by spend");
    NSArray *sources = [report.bySource valueForKey:@"name"];
    CHECK([sources containsObject:@"信用卡 · 尾号 1234"] && [sources containsObject:@"支付宝"], "names payment sources");
    CHECK([report.byAccount.firstObject[@"accountID"] isEqualToString:HomeID], "links account totals to their accounts");
    NSArray *missingCurrencies = @[@"PHP"];
    CHECK([report.missingCurrencies isEqualToArray:missingCurrencies], "lists currencies without a rate");

    NSDate *now = AccountDateFromDayString(@"2026-10-02");
    NSArray *october = [AccountExpenseReport reconciliationForAccounts:@[ios, reseller] month:now now:now rates:rates];
    CHECK(october.count == 2 && [october[0][@"name"] isEqualToString:@"代充号"] && [october[0][@"state"] isEqualToString:@"upcoming"] &&
        [october[1][@"date"] isEqualToString:@"2026-10-19"], "expects October's charges by their dates");
    NSArray *september = [AccountExpenseReport reconciliationForAccounts:@[ios, reseller] month:AccountDateFromDayString(@"2026-09-15")
        now:now rates:rates];
    NSDictionary *sepIOS = nil, *sepReseller = nil;
    for (NSDictionary *row in september) {
        if ([row[@"accountID"] isEqualToString:WorkID]) sepIOS = row;
        if ([row[@"accountID"] isEqualToString:HomeID]) sepReseller = row;
    }
    CHECK([sepIOS[@"state"] isEqualToString:@"recorded"] && [sepIOS[@"date"] isEqualToString:@"2026-09-19"], "a matching payment is recorded");
    CHECK([sepReseller[@"state"] isEqualToString:@"extra"], "payments without an expected charge are listed too");
    NSArray *july = [AccountExpenseReport reconciliationForAccounts:@[ios] month:AccountDateFromDayString(@"2025-11-10") now:now rates:rates];
    CHECK(july.count == 0, "months before the account was tracked expect nothing");
    [ios addPayments:@[[[AccountPayment alloc] initWithDictionary:@{@"date": @"2026-10-19", @"amount": @168, @"currency": @"CNY"}]]];
    october = [AccountExpenseReport reconciliationForAccounts:@[ios] month:now now:AccountDateFromDayString(@"2026-10-20") rates:rates];
    CHECK([october[0][@"state"] isEqualToString:@"different"], "flags a charge that differs from the expected price");
    ios.payments = [ios.payments subarrayWithRange:NSMakeRange(1, ios.payments.count - 1)];
    october = [AccountExpenseReport reconciliationForAccounts:@[ios] month:now now:AccountDateFromDayString(@"2026-10-20") rates:rates];
    CHECK([october[0][@"state"] isEqualToString:@"missing"], "flags a renewal without a payment once its day has passed");
}

static NSError *URLError(NSInteger code, NSString *url) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (url) info[NSURLErrorFailingURLErrorKey] = [NSURL URLWithString:url];
    return [NSError errorWithDomain:NSURLErrorDomain code:code userInfo:info];
}

static NetworkDiagnosis *Diagnosis(NSString *proxy, NSDictionary *system, NSArray<NSNumber *> *failures, NSNumber *reachable) {
    NSArray<NetworkCheck *> *checks = NetworkDiagnosis.standardChecks;
    NetworkDiagnosis *diagnosis = [[NetworkDiagnosis alloc] initWithProxyText:proxy origin:@"默认代理" systemSettings:system checks:checks];
    [checks enumerateObjectsUsingBlock:^(NetworkCheck *check, NSUInteger index, BOOL *stop) {
        NetworkFailure failure = (NetworkFailure)failures[index].integerValue;
        if (failure == NetworkFailureNone) [check finishWithStatus:200 duration:0.25];
        else [check finishWithFailure:failure duration:1];
    }];
    diagnosis.proxyReachable = reachable;
    return diagnosis;
}

static void TestNetworkDiagnosis(void) {
    CHECK(NetworkFailureForError(nil) == NetworkFailureNone, "no error is no failure");
    CHECK(NetworkFailureForError(URLError(NSURLErrorSecureConnectionFailed, nil)) == NetworkFailureTLS, "classifies TLS failures");
    CHECK(NetworkFailureForError(URLError(NSURLErrorTimedOut, nil)) == NetworkFailureTimeout, "classifies timeouts");
    CHECK(NetworkFailureForError(URLError(NSURLErrorCannotFindHost, nil)) == NetworkFailureDNS, "classifies DNS failures");
    CHECK(NetworkFailureForError(URLError(NSURLErrorCannotConnectToHost, nil)) == NetworkFailureConnect, "classifies refused connections");
    CHECK(NetworkFailureForError(URLError(NSURLErrorNotConnectedToInternet, nil)) == NetworkFailureOffline, "classifies offline");
    CHECK(NetworkFailureForError(URLError(NSURLErrorServerCertificateUntrusted, nil)) == NetworkFailureCertificate, "classifies certificates");
    CHECK(NetworkFailureForError([NSError errorWithDomain:@"kCFErrorDomainCFNetwork" code:310 userInfo:nil]) == NetworkFailureProxy,
        "classifies HTTPS proxy failures");
    CHECK(NetworkFailureForError([NSError errorWithDomain:@"kCFErrorDomainCFNetwork" code:122 userInfo:nil]) == NetworkFailureProxyAuth,
        "classifies SOCKS credential failures");
    NSError *wrapped = [NSError errorWithDomain:@"WebKitErrorDomain" code:999 userInfo:@{
        NSUnderlyingErrorKey: [NSError errorWithDomain:NSPOSIXErrorDomain code:ECONNREFUSED userInfo:nil]}];
    CHECK(NetworkFailureForError(wrapped) == NetworkFailureConnect, "looks through underlying errors");
    CHECK(NetworkFailureForError([NSError errorWithDomain:@"Other" code:1 userInfo:nil]) == NetworkFailureOther, "unknown errors are other");
    CHECK([NetworkFailingHost(URLError(NSURLErrorSecureConnectionFailed, @"https://auth.openai.com/authorize?x=1")) isEqualToString:@"auth.openai.com"],
        "reads the failing host");
    NSError *stringURL = [NSError errorWithDomain:NSURLErrorDomain code:-1 userInfo:@{NSURLErrorFailingURLStringErrorKey: @"https://chatgpt.com/"}];
    CHECK([NetworkFailingHost(stringURL) isEqualToString:@"chatgpt.com"], "reads the failing URL string");
    CHECK(NetworkFailureHint(NetworkFailureTLS) != nil && NetworkFailureHint(NetworkFailureOther) == nil, "hints at proxy problems");
    CHECK([NetworkFailureDescription(NetworkFailureTLS) containsString:@"TLS"], "describes TLS failures");

    NSDictionary *trace = NetworkTraceValues(@"fl=1\nip=203.0.113.9\nts=1\nloc=US\n\n=bad\n");
    CHECK([trace[@"ip"] isEqualToString:@"203.0.113.9"] && [trace[@"loc"] isEqualToString:@"US"] && trace.count == 4, "parses trace pages");
    CHECK(NetworkRegionUnsupported(@"hk") && NetworkRegionUnsupported(@"CN") && !NetworkRegionUnsupported(@"JP") && !NetworkRegionUnsupported(nil),
        "knows unsupported regions");

    NSString *host = nil;
    NSInteger port = 0;
    NSDictionary *clash = @{@"HTTPEnable": @1, @"HTTPProxy": @"127.0.0.1", @"HTTPPort": @7890,
                            @"HTTPSEnable": @1, @"HTTPSProxy": @"127.0.0.1", @"HTTPSPort": @7890, @"SOCKSEnable": @0};
    CHECK([NetworkSystemProxySummary(clash, &host, &port) isEqualToString:@"HTTPS 127.0.0.1:7890"] && [host isEqualToString:@"127.0.0.1"] && port == 7890,
        "describes the system HTTPS proxy");
    NSDictionary *socks = @{@"SOCKSEnable": @1, @"SOCKSProxy": @"10.0.0.2", @"SOCKSPort": @1080};
    CHECK([NetworkSystemProxySummary(socks, &host, &port) isEqualToString:@"SOCKS 10.0.0.2:1080"] && port == 1080, "describes a SOCKS proxy");
    CHECK([NetworkSystemProxySummary(@{@"ProxyAutoConfigEnable": @1, @"HTTPSEnable": @1, @"HTTPSProxy": @"h", @"HTTPSPort": @1}, &host, &port)
        containsString:@"PAC"] && host == nil, "PAC has no endpoint to probe");
    CHECK(NetworkSystemProxySummary(@{@"HTTPEnable": @1, @"HTTPProxy": @"h", @"HTTPPort": @80}, &host, &port).length == 0 && host == nil,
        "an HTTP-only system proxy leaves https direct");

    NSArray *allOK = @[@0, @0, @0, @0, @0];
    NetworkDiagnosis *ok = Diagnosis(@"socks5://user:secret@127.0.0.1:1080", nil, allOK, @YES);
    ok.region = @"US";
    CHECK(ok.usesProxy && [ok.proxyHost isEqualToString:@"127.0.0.1"] && ok.proxyPort == 1080, "probes the configured proxy");
    CHECK([ok.proxyDescription isEqualToString:@"默认代理 socks5://127.0.0.1:1080（带认证）"], "never shows the proxy password");
    CHECK(ok.verdict == NetworkVerdictOK && [ok.headline isEqualToString:@"网络正常"], "all hosts working is OK");
    CHECK(![ok.textReport containsString:@"secret"], "the report leaves out the password");
    ok.region = @"HK";
    CHECK(ok.verdict == NetworkVerdictUnsupportedRegion && [ok.advice containsString:@"HK"], "flags unsupported exit regions");

    NetworkDiagnosis *pending = Diagnosis(@"http://127.0.0.1:7890", nil, allOK, nil);
    CHECK(!pending.finished && pending.verdict == NetworkVerdictPending, "waits for the proxy probe");

    NSNumber *tls = @(NetworkFailureTLS), *refused = @(NetworkFailureConnect), *offline = @(NetworkFailureOffline);
    NetworkDiagnosis *down = Diagnosis(@"http://127.0.0.1:7890", nil, @[refused, refused, refused, refused, refused], @NO);
    CHECK(down.verdict == NetworkVerdictProxyDown && [down.headline containsString:@"127.0.0.1:7890"], "a closed proxy port is reported first");

    NetworkDiagnosis *partial = Diagnosis(@"http://127.0.0.1:7890", nil, @[@0, tls, @0, @0, @0], @YES);
    CHECK(partial.verdict == NetworkVerdictPartial && [partial.advice containsString:@"auth.openai.com"], "names the hosts that fail");

    NetworkDiagnosis *route = Diagnosis(@"http://127.0.0.1:7890", nil, @[tls, tls, tls, tls, @0], @YES);
    CHECK(route.verdict == NetworkVerdictOpenAIRoute && [route.advice containsString:@"规则"], "control working blames the OpenAI route");

    NetworkDiagnosis *dead = Diagnosis(@"http://127.0.0.1:7890", nil, @[tls, tls, tls, tls, tls], @YES);
    CHECK(dead.verdict == NetworkVerdictNoRoute && [dead.headline containsString:@"代理已连接"], "nothing working blames the node");

    NetworkDiagnosis *direct = Diagnosis(@"", @{}, @[refused, refused, refused, refused, refused], nil);
    CHECK(!direct.usesProxy && direct.proxyHost == nil && direct.finished, "direct connections need no probe");
    CHECK(direct.verdict == NetworkVerdictNoRoute && [direct.advice containsString:@"没有使用代理"], "suggests a proxy when going direct");
    CHECK([direct.proxyDescription isEqualToString:@"未使用代理（直连）"], "describes direct connections");

    NetworkDiagnosis *system = Diagnosis(@"", clash, allOK, @YES);
    CHECK([system.proxyDescription isEqualToString:@"系统代理 HTTPS 127.0.0.1:7890"] && system.proxyPort == 7890, "follows the system proxy");

    NetworkDiagnosis *noNetwork = Diagnosis(@"", @{}, @[offline, offline, offline, offline, offline], nil);
    CHECK(noNetwork.verdict == NetworkVerdictOffline, "detects being offline");

    NetworkCheck *auth = [NetworkCheck checkWithTitle:@"代理" URL:@"https://chatgpt.com/" control:NO];
    [auth finishWithStatus:407 duration:0.1];
    CHECK(auth.failure == NetworkFailureProxyAuth && !auth.succeeded, "407 is a proxy authentication failure");
    [auth finishWithStatus:200 duration:0.1];
    CHECK(auth.failure == NetworkFailureProxyAuth, "a check finishes once");
    NetworkCheck *fast = [NetworkCheck checkWithTitle:@"x" URL:@"https://cdn.oaistatic.com/" control:NO];
    [fast finishWithStatus:404 duration:0.32];
    CHECK(fast.succeeded && [fast.detail isEqualToString:@"可连接 · 320 毫秒"] && !fast.readsTrace, "any HTTP response means reachable");
    CHECK(NetworkDiagnosis.standardChecks.firstObject.readsTrace, "the first check reads the exit region");
}

static void TestLifecycleAndArchive(void) {
    NSDate *now = AccountDateFromDayString(@"2026-10-02");
    NSDictionary *paid = @{@"name": @"付费号", @"email": @"paid@example.com", @"plan": @"Plus", @"expiresAt": @"2026-10-01",
        @"autoRenew": @YES, @"monthlyPrice": @158, @"currency": @"CNY", @"supplier": @"iOS", @"paymentMethod": @"礼品卡 / 余额",
        @"createdAt": @"2026-08-01T00:00:00Z",
        @"payments": @[@{@"date": @"2026-09-01", @"amount": @158, @"currency": @"CNY"}]};
    Account *active = [[Account alloc] initWithDictionary:[paid mutableCopy]];
    CHECK(active.lifecycle.length == 0 && !active.archived && !active.retired && active.tracked, "accounts start in use");
    CHECK(AccountUnrecordedRenewal(active, now) != nil, "an active account expects its renewal to be recorded");

    NSMutableDictionary *bannedRecord = [paid mutableCopy];
    bannedRecord[@"lifecycle"] = @"Banned";
    bannedRecord[@"lifecycleChangedAt"] = @"2026-09-20T08:00:00Z";
    Account *banned = [[Account alloc] initWithDictionary:bannedRecord];
    CHECK([banned.lifecycle isEqualToString:@"banned"] && banned.retired && !banned.tracked, "reads the lifecycle");
    CHECK([banned.dictionaryRepresentation[@"lifecycle"] isEqualToString:@"banned"] &&
        [banned.dictionaryRepresentation[@"lifecycleChangedAt"] isEqualToString:@"2026-09-20T08:00:00Z"], "saves the lifecycle");
    AccountStatus *bannedStatus = [AccountStatus statusForAccount:banned now:now];
    CHECK(bannedStatus.kind == AccountStatusRetired && [bannedStatus.title isEqualToString:@"已封禁"] &&
        bannedStatus.tone == AccountStatusToneCritical, "a banned account shows as banned");
    CHECK(AccountMissingFields(banned, now).count == 0 && AccountUnrecordedRenewal(banned, now) == nil,
        "retired accounts need no details or payments");
    CHECK([banned matchesSearch:@"封禁"], "finds accounts by lifecycle");

    Account *odd = [[Account alloc] initWithDictionary:@{@"name": @"x", @"lifecycle": @"sold"}];
    CHECK(odd.lifecycle.length == 0 && !odd.dictionaryRepresentation[@"lifecycle"], "ignores unknown lifecycles");
    Account *idle = [[Account alloc] initWithDictionary:@{@"name": @"闲置号", @"email": @"idle@example.com", @"plan": @"Free",
        @"lifecycle": @"idle"}];
    CHECK(idle.tracked && [AccountStatus statusForAccount:idle now:now].kind == AccountStatusIdle, "idle accounts stay tracked");
    CHECK([AccountLifecycleTitle(@"transferred") isEqualToString:@"已转让"] && [AccountLifecycleTitle(@"") isEqualToString:@"使用中"],
        "titles lifecycles");

    NSMutableDictionary *archivedRecord = [paid mutableCopy];
    archivedRecord[@"archivedAt"] = @"2026-09-30T00:00:00Z";
    archivedRecord[@"email"] = @"PAID@example.com";
    Account *archived = [[Account alloc] initWithDictionary:archivedRecord];
    CHECK(archived.archived && !archived.tracked && [AccountStatus statusForAccount:archived now:now].kind == AccountStatusArchived,
        "reads the archive date");
    CHECK([archived.exportRepresentation[@"archivedAt"] isEqualToString:@"2026-09-30T00:00:00Z"], "exports the archive date");
    Account *legacyArchived = [[Account alloc] initWithDictionary:@{@"name": @"y", @"archived": @YES}];
    CHECK(legacyArchived.archived, "accepts a plain archived flag");
    CHECK(AccountDuplicateEmails(@[active, archived]).count == 0, "archived accounts don't count as duplicates");

    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    banned.usage = UsageWith(0, 99);
    banned.signedIn = @YES;
    AccountAlertKinds all = AccountAlertQuota | AccountAlertRenewal | AccountAlertSignedOut;
    CHECK(AccountAlertsDue(@[banned, archived], now, state, all).count == 0, "no reminders for retired or archived accounts");

    AccountStore *store = TemporaryStore(@"lifecycle.json");
    [store load:nil];
    Account *one = [store addAccountNamed:@"一" group:@"旧号"];
    one.plan = @"Plus"; one.monthlyPrice = @158; one.currency = @"CNY";
    Account *two = [store addAccountNamed:@"二" group:nil];
    two.plan = @"Pro 200"; two.monthlyPrice = @1598; two.currency = @"CNY"; two.lifecycle = @"disabled";
    Account *three = [store addAccountNamed:@"三" group:@"归档组"];
    three.plan = @"Plus"; three.monthlyPrice = @20; three.currency = @"USD"; three.archivedAt = now;
    CHECK(store.visibleAccounts.count == 2 && store.archivedAccounts.count == 1 && store.trackedAccounts.count == 1,
        "splits visible, archived and tracked accounts");
    CHECK([store.monthlySpendByCurrency isEqualToDictionary:@{@"CNY": @158}], "monthly spend counts tracked accounts only");
    CHECK(![store.groups containsObject:@"归档组"], "groups of archived accounts leave the lists");
    CHECK([store save:nil] && [store load:nil] && [store accountWithID:three.identifier].archived &&
        [[store accountWithID:two.identifier].lifecycle isEqualToString:@"disabled"], "lifecycle and archive survive saving");

    NSSet *none = [NSSet set];
    ManagementScope *archive = [ManagementScope scopeWithKind:ManagementScopeArchived value:nil];
    CHECK([archive includesAccount:archived now:now duplicateIDs:none] && ![archive includesAccount:active now:now duplicateIDs:none],
        "the archive lists archived accounts");
    CHECK(![ManagementScope.all includesAccount:archived now:now duplicateIDs:none], "other lists leave archived accounts out");
    ManagementScope *signedOut = [ManagementScope scopeWithKind:ManagementScopeSignedOut value:nil];
    banned.signedIn = @NO;
    CHECK(![signedOut includesAccount:banned now:now duplicateIDs:none] && [ManagementScope.all includesAccount:banned now:now duplicateIDs:none],
        "retired accounts drop out of reminder lists only");
    CHECK([[ManagementScope scopeFromString:archive.stringValue] isEqual:archive] && [archive.title isEqualToString:@"已归档"],
        "the archive scope round-trips");

    NSArray *rows = [AccountExpenseReport reconciliationForAccounts:@[archived] month:AccountDateFromDayString(@"2026-09-15")
        now:now rates:@{@"CNY": @1}];
    CHECK(rows.count == 1 && [rows[0][@"state"] isEqualToString:@"extra"] && [rows[0][@"date"] length] == 0,
        "archived accounts expect no charges but keep their payments");
    AccountExpenseReport *report = [AccountExpenseReport reportForAccounts:@[archived] year:2026 rates:@{@"CNY": @1}];
    CHECK(report.count == 1 && fabs(report.total - 158) < 0.001, "reports keep archived payments");

    Account *incoming = [[Account alloc] initWithDictionary:@{@"name": @"付费号", @"lifecycle": @"transferred",
        @"archivedAt": @"2026-10-01T00:00:00Z"}];
    [active applyProfileFrom:incoming];
    CHECK([active.lifecycle isEqualToString:@"transferred"] && active.archived, "imports bring the lifecycle and archive");
}

static void TestRefundsAndBudget(void) {
    NSDate *now = AccountDateFromDayString(@"2026-10-03");
    Account *account = [[Account alloc] initWithDictionary:@{@"id": WorkID, @"name": @"退款号", @"email": @"r@example.com",
        @"plan": @"Plus", @"expiresAt": @"2026-10-01", @"autoRenew": @YES, @"monthlyPrice": @158, @"currency": @"CNY",
        @"supplier": @"iOS", @"paymentMethod": @"礼品卡 / 余额", @"createdAt": @"2026-08-01T00:00:00Z",
        @"payments": @[@{@"date": @"2026-09-01", @"amount": @158, @"currency": @"CNY"},
                       @{@"date": @"2026-09-05", @"amount": @58, @"currency": @"CNY", @"kind": @"refund"},
                       @{@"date": @"2026-10-01", @"amount": @158, @"currency": @"CNY", @"kind": @"failed"},
                       @{@"date": @"2026-10-02", @"amount": @20, @"currency": @"USD", @"kind": @"bogus"}]}];
    AccountPayment *refund = nil, *failed = nil;
    for (AccountPayment *payment in account.payments) {
        if (payment.isRefund) refund = payment;
        if (payment.isFailed) failed = payment;
    }
    CHECK(refund.sign == -1 && failed.sign == 0 && [refund.dictionaryRepresentation[@"kind"] isEqualToString:@"refund"],
        "reads payment kinds");
    CHECK([account.payments.firstObject.kind isEqualToString:@""] && account.payments.firstObject.isCharge, "unknown kinds are payments");
    CHECK([account.lastPayment.date isEqualToString:@"2026-10-02"], "the last payment is the newest real payment");
    CHECK([AccountPaymentKindTitle(@"failed") isEqualToString:@"扣款失败"] && [AccountPaymentKindTitle(nil) isEqualToString:@"付款"],
        "titles payment kinds");

    AccountPayment *sameRefund = [[AccountPayment alloc] initWithDictionary:@{@"date": @"2026-09-05", @"amount": @58,
        @"currency": @"CNY", @"kind": @"refund"}];
    AccountPayment *sameAsCharge = [[AccountPayment alloc] initWithDictionary:@{@"date": @"2026-09-05", @"amount": @58, @"currency": @"CNY"}];
    NSArray *incoming = @[sameRefund, sameAsCharge];
    CHECK([account addPayments:incoming] == 1, "a charge and a refund of the same amount are different records");

    NSDictionary *rates = @{@"CNY": @1, @"USD": @7};
    AccountExpenseReport *report = [AccountExpenseReport reportForAccounts:@[account] year:2026 rates:rates];
    CHECK(fabs(report.total - (158 - 58 + 140 + 58)) < 0.001 && fabs(report.refundTotal - 58) < 0.001 && report.failedCount == 1 &&
        report.count == 4, "refunds come off the total and failed charges count for nothing");
    CHECK(fabs(report.monthTotals[8].doubleValue - (158 - 58 + 58)) < 0.001, "refunds come off their month");

    Account *failing = [[Account alloc] initWithDictionary:@{@"id": HomeID, @"name": @"失败号", @"plan": @"Plus",
        @"expiresAt": @"2026-10-01", @"autoRenew": @YES, @"monthlyPrice": @158, @"currency": @"CNY", @"createdAt": @"2026-08-01T00:00:00Z",
        @"payments": @[@{@"date": @"2026-09-01", @"amount": @158, @"currency": @"CNY"},
                       @{@"date": @"2026-10-01", @"amount": @158, @"currency": @"CNY", @"kind": @"failed"}]}];
    CHECK([AccountUnrecordedRenewal(failing, now) isEqualToString:@"2026-10-01"], "a failed charge does not settle a renewal");
    NSArray *rows = [AccountExpenseReport reconciliationForAccounts:@[failing] month:now now:now rates:rates];
    CHECK(rows.count == 1 && [rows[0][@"state"] isEqualToString:@"failed"], "reconciliation shows failed charges");
    NSArray *september = [AccountExpenseReport reconciliationForAccounts:@[account] month:AccountDateFromDayString(@"2026-09-10")
        now:now rates:rates];
    CHECK(september.count == 1 && [september[0][@"recorded"] doubleValue] == 158 && [september[0][@"state"] isEqualToString:@"recorded"],
        "refunds are taken off what was recorded");

    CHECK(fabs(AccountSpentInMonth(@[account, failing], now, rates) - 140) < 0.001, "this month's spending leaves out failed charges");
    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    CHECK(AccountBudgetAlert(@[account], now, 200, rates, state) == nil, "no alert within the budget");
    CHECK(AccountBudgetAlert(@[account], now, 0, rates, state) == nil, "no alert without a budget");
    NSDictionary *alert = AccountBudgetAlert(@[account], now, 100, rates, state);
    CHECK([alert[@"kind"] isEqualToString:@"budget"] && [alert[@"title"] isEqualToString:@"10 月支出已超出预算"] &&
        [alert[@"body"] containsString:@"超出 ¥40.00"], "announces going over the budget");
    CHECK(AccountBudgetAlert(@[account], now, 100, rates, state) == nil, "announces it once a month");
    CHECK(AccountBudgetAlert(@[account], AccountDateFromDayString(@"2026-11-02"), 100, rates, state) == nil,
        "a new month starts within the budget");
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
        TestInsights();
        TestWebDAV();
        TestAlerts();
        TestScopes();
        TestPayments();
        TestBillingPayments();
        TestAuthorizationRecords();
        TestCompleteness();
        TestPaymentsDue();
        TestExpenseReport();
        TestNetworkDiagnosis();
        TestLifecycleAndArchive();
        TestRefundsAndBudget();
    }
    printf("%d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
