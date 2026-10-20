#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface SRSelection : NSObject
@property(nonatomic, readonly, copy) NSArray<NSDictionary *> *rows;
@property(nonatomic, readonly, copy) NSArray<NSDictionary *> *selectedRows;
- (instancetype)initWithRows:(NSArray<NSDictionary *> *)rows excludedIDs:(NSSet<NSString *> *)excluded
                 selectedIDs:(NSSet<NSString *> *)selected;
- (NSArray<NSDictionary *> *)rowsMatching:(NSString *)query;
- (BOOL)isSelected:(NSString *)identifier;
- (void)toggle:(NSString *)identifier;
- (void)selectFirst:(NSUInteger)count;
@end
NS_ASSUME_NONNULL_END
