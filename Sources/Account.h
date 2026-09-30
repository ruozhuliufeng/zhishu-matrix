#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, AccountExpiryState) {
    AccountExpiryStateUnknown = 0,
    AccountExpiryStateActive,
    AccountExpiryStateExpiringSoon,
    AccountExpiryStateExpired,
};

extern NSInteger const AccountExpiringSoonDays;
extern NSErrorDomain const AccountStoreErrorDomain;
extern NSNotificationName const AccountStoreDidChangeNotification;

NSArray<NSString *> *AccountPlans(void);
NSString *_Nullable AccountCanonicalPlan(id _Nullable plan);
NSString *AccountDayString(NSDate *date);
NSDate *_Nullable AccountDateFromDayString(NSString *_Nullable day);

/// Locally stored profile of one ChatGPT account. Passwords and tokens are never part of it.
@interface Account : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy, null_resettable) NSString *email;
@property (nonatomic, copy, nullable) NSString *plan;
@property (nonatomic, copy, nullable) NSString *planSource;
@property (nonatomic, copy, nullable) NSString *expiresAt;
@property (nonatomic, copy, nullable) NSString *expirySource;
@property (nonatomic, copy, null_resettable) NSString *group;
@property (nonatomic, copy, null_resettable) NSString *notes;
@property (nonatomic, strong, nullable) NSDate *createdAt;
@property (nonatomic, strong, nullable) NSDate *lastUsedAt;
@property (nonatomic, strong, nullable) NSNumber *signedIn;

@property (nonatomic, readonly) NSString *planTitle;
@property (nonatomic, readonly) BOOL isPaid;
@property (nonatomic, readonly) NSInteger planRank;

+ (instancetype)accountWithName:(NSString *)name;
- (instancetype)initWithDictionary:(NSDictionary *)dictionary NS_DESIGNATED_INITIALIZER;
- (NSDictionary *)dictionaryRepresentation;
- (NSDictionary *)exportRepresentation;
/// Merges an imported profile; empty fields in `other` keep the local value.
- (void)applyProfileFrom:(Account *)other;
- (nullable NSNumber *)daysRemainingFromDate:(NSDate *)now;
- (AccountExpiryState)expiryStateFromDate:(NSDate *)now;
- (NSString *)expiryDescriptionFromDate:(NSDate *)now;
- (BOOL)matchesSearch:(nullable NSString *)query;
@end

@interface AccountStore : NSObject
@property (nonatomic, readonly) NSURL *fileURL;
@property (nonatomic, readonly) NSArray<Account *> *accounts;
/// Set when `load:` found an unreadable file and copied it aside before starting empty.
@property (nonatomic, readonly, nullable) NSURL *recoveredBackupURL;
@property (nonatomic, copy, nullable) void (^saveFailed)(NSError *error);

- (instancetype)initWithFileURL:(NSURL *)fileURL;
- (BOOL)load:(NSError **)error;
- (BOOL)save:(NSError **)error;
/// Saves and posts AccountStoreDidChangeNotification.
- (void)commit;

- (nullable Account *)accountWithID:(nullable NSString *)identifier;
- (NSArray<Account *> *)accountsWithIDs:(NSArray<NSString *> *)identifiers;
- (Account *)addAccountNamed:(NSString *)name group:(nullable NSString *)group;
- (void)removeAccountsWithIDs:(NSArray<NSString *> *)identifiers;
- (void)moveAccountsWithIDs:(NSArray<NSString *> *)identifiers toIndex:(NSUInteger)index;
- (NSArray<NSString *> *)groups;

- (nullable NSData *)exportDataForAccountIDs:(nullable NSArray<NSString *> *)identifiers error:(NSError **)error;
- (BOOL)importData:(NSData *)data added:(nullable NSUInteger *)added updated:(nullable NSUInteger *)updated error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
