#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

@interface SRWeChatReader : NSObject
@property(nonatomic, readonly, copy, nullable) NSString *accountID;
@property(nonatomic, readonly, copy) NSString *version;
@property(nonatomic, readonly, copy) NSArray<NSString *> *warnings;
- (instancetype)initWithVersion:(NSString *)version classResolver:(Class _Nullable (^)(NSString *name))resolver;
- (BOOL)connect:(NSError **)error;
- (BOOL)verifyAccount:(NSString *)account error:(NSError **)error;
/* Returned IDs are native usernames, never inferred from a nickname. */
- (nullable NSArray<NSDictionary *> *)groups:(NSError **)error;
- (nullable NSArray<NSDictionary *> *)membersOfGroup:(NSString *)group error:(NSError **)error;
/* Contains version/signature information only; no member IDs or message content. */
- (NSDictionary *)diagnostics;
@end
NS_ASSUME_NONNULL_END
