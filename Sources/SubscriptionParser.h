#import <Foundation/Foundation.h>

@class AccountUsage;

NS_ASSUME_NONNULL_BEGIN

/// Turns what ChatGPT returns (page text from PlanProbe.js, JSON from its backend API) into account fields.
@interface SubscriptionParser : NSObject
+ (nullable NSString *)planFromProfile:(nullable NSString *)profile details:(nullable NSString *)details;
+ (nullable NSString *)expiryFromDetails:(nullable NSString *)details;
+ (nullable NSString *)normalizedDate:(nullable NSString *)raw;
+ (nullable NSString *)planFromPlanType:(nullable NSString *)planType;

/// Whether page text comes from the billing settings rather than, say, the upgrade dialog (which also lists plans and prices).
+ (BOOL)isBillingText:(nullable NSString *)text;
/// "ChatGPT Pro 200" on the billing settings page → "Pro 200".
+ (nullable NSString *)planFromBillingText:(nullable NSString *)text;
/// {@"date": yyyy-MM-dd, @"autoRenew": BOOL} from "将在 2026年10月25日 自动续订" / "renews on …" / "will be canceled on …".
+ (nullable NSDictionary *)renewalFromBillingText:(nullable NSString *)text;
/// {@"amount": number, @"currency": ISO code} for the first amount on the page (the latest charge).
+ (nullable NSDictionary *)priceFromBillingText:(nullable NSString *)text;
/// "iOS" when the subscription is managed by Apple, "Google Play" when by Google.
+ (nullable NSString *)supplierFromBillingText:(nullable NSString *)text;
/// Last four digits of the payment card shown on the page ("Visa •••• 1234").
+ (nullable NSString *)cardLast4FromBillingText:(nullable NSString *)text;
/// Charges listed under the payment history, newest first: [{@"date": yyyy-MM-dd, @"amount", @"currency", @"kind", @"note"}].
/// Failed charges have kind "failed"; a refunded invoice gives a payment and a "refund" of the same amount;
/// pending, cancelled and void invoices are left out.
+ (NSArray<NSDictionary *> *)paymentsFromBillingText:(nullable NSString *)text;

/// GET /backend-api/wham/usage → usage windows and credits; `planType` receives "plan_type".
+ (nullable AccountUsage *)usageFromJSON:(nullable id)json planType:(NSString *_Nullable *_Nullable)planType;
/// GET /backend-api/subscriptions → {@"expiresAt": yyyy-MM-dd, @"autoRenew": BOOL, @"plan": tier}; keys only when present.
+ (nullable NSDictionary *)subscriptionFromJSON:(nullable id)json;
@end

NS_ASSUME_NONNULL_END
