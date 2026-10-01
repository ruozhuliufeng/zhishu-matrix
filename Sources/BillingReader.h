#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Reads the plan tier, renewal and price from each account's billing settings in a hidden page, one account at a time.
@interface BillingReader : NSObject
@property (nonatomic, copy) NSURL *billingURL;
@property (nonatomic, copy, nullable) WKWebsiteDataStore *_Nonnull (^dataStoreProvider)(NSString *identifier);
/// Applies what PlanProbe.js read; returns NO when nothing was recognised.
@property (nonatomic, copy, nullable) BOOL (^applyReading)(NSString *identifier, NSDictionary *page);
@property (nonatomic, copy, nullable) void (^stateChanged)(void);
/// Called once per account; `failure` is nil when the billing page was read.
@property (nonatomic, copy, nullable) void (^accountFinished)(NSString *identifier, NSString *_Nullable failure);
@property (nonatomic, readonly) BOOL isReading;
- (BOOL)isReadingAccountID:(NSString *)identifier;
- (void)readAccountIDs:(NSArray<NSString *> *)identifiers;
@end

NS_ASSUME_NONNULL_END
