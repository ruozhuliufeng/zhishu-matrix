#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Turns text scraped by PlanProbe.js / SessionProbe.js into account fields.
@interface SubscriptionParser : NSObject
+ (nullable NSString *)planFromProfile:(nullable NSString *)profile details:(nullable NSString *)details;
+ (nullable NSString *)expiryFromDetails:(nullable NSString *)details;
+ (nullable NSString *)normalizedDate:(nullable NSString *)raw;
+ (nullable NSString *)planFromPlanType:(nullable NSString *)planType;
@end

NS_ASSUME_NONNULL_END
