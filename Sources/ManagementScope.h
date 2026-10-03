#import <Foundation/Foundation.h>

@class Account;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ManagementScopeKind) {
    ManagementScopeAll = 0,
    ManagementScopeQuotaLow,
    ManagementScopeExpiring,     // expiring within a week or already expired, without automatic renewal
    ManagementScopeSignedOut,    // not signed in on this Mac (or never checked)
    ManagementScopeAutoRenew,
    ManagementScopeDuplicates,   // shares its email with another account
    ManagementScopeGroup,        // value: group name, "" = ungrouped
    ManagementScopeTag,          // value: tag
    ManagementScopeSupplier,     // value: supplier, "" = not filled in
    ManagementScopeIncomplete,   // something is missing from the record (AccountMissingFields)
    ManagementScopeAuthorizedApp, // value: third-party app name with an active authorization
    ManagementScopeArchived,     // the only scope that lists archived accounts
};

/// One entry of the management sidebar: a smart list, a group or a tag.
@interface ManagementScope : NSObject <NSCopying>
@property (nonatomic, readonly) ManagementScopeKind kind;
@property (nonatomic, readonly, copy) NSString *value;
@property (nonatomic, readonly) NSString *title;
@property (nonatomic, readonly) NSString *symbol;
/// Groups, tags, suppliers and apps carry a value; smart lists do not.
@property (nonatomic, readonly) BOOL hasValue;
+ (instancetype)scopeWithKind:(ManagementScopeKind)kind value:(nullable NSString *)value;
+ (instancetype)all;
/// The smart lists shown above groups and tags.
+ (NSArray<ManagementScope *> *)smartScopes;
/// `duplicateIDs` are the identifiers of accounts that share an email (see AccountDuplicateEmails).
/// Archived accounts only belong to the archived scope; retired ones drop out of the reminder lists.
- (BOOL)includesAccount:(Account *)account now:(NSDate *)now duplicateIDs:(NSSet<NSString *> *)duplicateIDs;
/// Persistable form, e.g. "tag:主力".
@property (nonatomic, readonly) NSString *stringValue;
+ (nullable instancetype)scopeFromString:(nullable NSString *)string;
@end

/// Identifiers of accounts whose email is used by another account too.
NSSet<NSString *> *AccountDuplicateIDs(NSArray<Account *> *accounts);

NS_ASSUME_NONNULL_END
