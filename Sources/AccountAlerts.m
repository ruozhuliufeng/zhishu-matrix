#import "AccountAlerts.h"
#import <UserNotifications/UserNotifications.h>
#import "Account.h"
#import "AccountInsights.h"

NSString *const NotifyQuotaDefaultsKey = @"notifyQuota";
NSString *const NotifyRenewalDefaultsKey = @"notifyRenewal";
NSString *const NotifySignedOutDefaultsKey = @"notifySignedOut";
NSNotificationName const AlertSettingsDidChangeNotification = @"AlertSettingsDidChangeNotification";

static NSString *const AlertStateDefaultsKey = @"alertState";
static NSString *const PaymentCategory = @"payment";
static NSString *const RecordPaymentAction = @"record-payment";

@interface AccountAlerts () <UNUserNotificationCenterDelegate>
@end

@implementation AccountAlerts {
    AccountStore *_store;
    NSMutableDictionary *_state;
    BOOL _scheduled;
}

- (instancetype)initWithStore:(AccountStore *)store {
    if ((self = [super init])) {
        _store = store;
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        [defaults registerDefaults:@{NotifyQuotaDefaultsKey: @YES, NotifyRenewalDefaultsKey: @YES, NotifySignedOutDefaultsKey: @YES}];
        NSDictionary *saved = [defaults dictionaryForKey:AlertStateDefaultsKey];
        _state = saved ? [saved mutableCopy] : [NSMutableDictionary dictionary];
    }
    return self;
}

- (AccountAlertKinds)enabledKinds {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    AccountAlertKinds kinds = 0;
    if ([defaults boolForKey:NotifyQuotaDefaultsKey]) kinds |= AccountAlertQuota;
    if ([defaults boolForKey:NotifyRenewalDefaultsKey]) kinds |= AccountAlertRenewal;
    if ([defaults boolForKey:NotifySignedOutDefaultsKey]) kinds |= AccountAlertSignedOut;
    return kinds;
}

- (void)start {
    UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
    center.delegate = self;
    UNNotificationAction *record = [UNNotificationAction actionWithIdentifier:RecordPaymentAction title:@"记一笔"
        options:UNNotificationActionOptionForeground];
    [center setNotificationCategories:[NSSet setWithObject:[UNNotificationCategory categoryWithIdentifier:PaymentCategory
        actions:@[record] intentIdentifiers:@[] options:0]]];
    if (self.enabledKinds)
        [center requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound
            completionHandler:^(BOOL granted, NSError *error) {}];
    [self evaluate];
}

- (void)evaluate {
    // Store changes arrive in bursts while accounts refresh; check once they settle.
    if (_scheduled) return;
    _scheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self->_scheduled = NO;
        [self evaluateNow];
    });
}

- (void)evaluateNow {
    NSArray<NSDictionary *> *alerts = AccountAlertsDue(_store.accounts, NSDate.date, _state, self.enabledKinds);
    [NSUserDefaults.standardUserDefaults setObject:_state forKey:AlertStateDefaultsKey];
    for (NSDictionary *alert in alerts) [self post:alert];
}

- (void)forgetSignInOfAccountIDs:(NSArray<NSString *> *)identifiers {
    AccountAlertsForgetSignIn(_state, identifiers);
    [NSUserDefaults.standardUserDefaults setObject:_state forKey:AlertStateDefaultsKey];
}

- (void)post:(NSDictionary *)alert {
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = alert[@"title"];
    content.body = alert[@"body"];
    content.sound = UNNotificationSound.defaultSound;
    content.threadIdentifier = alert[@"accountID"];
    BOOL payment = [alert[@"kind"] isEqualToString:@"payment"] || [alert[@"kind"] isEqualToString:@"renewal"];
    if (payment) content.categoryIdentifier = PaymentCategory;
    content.userInfo = @{@"accountID": alert[@"accountID"], @"kind": alert[@"kind"] ?: @"", @"date": alert[@"date"] ?: @""};
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:alert[@"id"] content:content trigger:nil];
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:request withCompletionHandler:nil];
}

- (void)describeAuthorization:(void (^)(NSString *, BOOL))completion {
    [UNUserNotificationCenter.currentNotificationCenter getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        dispatch_async(dispatch_get_main_queue(), ^{
            switch (settings.authorizationStatus) {
                case UNAuthorizationStatusAuthorized:
                case UNAuthorizationStatusProvisional:
                    completion(@"通知权限已开启", YES);
                    break;
                case UNAuthorizationStatusDenied:
                    completion(@"通知未被允许，请在“系统设置 → 通知 → 智枢矩阵”中开启", NO);
                    break;
                default:
                    completion(@"开启任一提醒后，系统会询问是否允许通知", NO);
                    break;
            }
        });
    }];
}

#pragma mark - UNUserNotificationCenterDelegate

- (void)userNotificationCenter:(UNUserNotificationCenter *)center willPresentNotification:(UNNotification *)notification
    withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList | UNNotificationPresentationOptionSound);
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center didReceiveNotificationResponse:(UNNotificationResponse *)response
    withCompletionHandler:(void (^)(void))completionHandler {
    NSDictionary *info = response.notification.request.content.userInfo;
    NSString *identifier = info[@"accountID"];
    NSString *date = [info[@"date"] isKindOfClass:NSString.class] ? info[@"date"] : @"";
    // A payment prompt opens the payment form, whether its button or the notification itself was clicked.
    BOOL record = [response.actionIdentifier isEqualToString:RecordPaymentAction] || [info[@"kind"] isEqual:@"payment"];
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([identifier isKindOfClass:NSString.class]) {
            if (record && self.recordPayment) self.recordPayment(identifier, date);
            else if (self.openAccount) self.openAccount(identifier);
        }
        completionHandler();
    });
}
@end
