#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/* Only existing methods with checked object-return/argument encodings are invoked. */
FOUNDATION_EXPORT id _Nullable SRReadObject(id _Nullable target, NSString *selector,
                                           NSArray *arguments, NSError **error);
FOUNDATION_EXPORT id _Nullable SRReadObjectWithIntegers(id _Nullable target, NSString *selector,
                                                       NSArray<NSNumber *> *arguments, NSError **error);
FOUNDATION_EXPORT NSString * _Nullable SRReadString(id _Nullable target, NSString *selector);
typedef NS_ENUM(NSUInteger, SRStringReadState) {
    SRStringReadNoObject = 0, SRStringReadMissing = 1, SRStringReadIncompatible = 2,
    SRStringReadFailed = 3, SRStringReadNil = 4, SRStringReadNotString = 5,
    SRStringReadEmpty = 6, SRStringReadValue = 7
};
/* Real zero-argument methods only. Validates runtime ABI, not an object's reflection override. */
FOUNDATION_EXPORT NSString * _Nullable SRReadDeclaredString(id _Nullable target, NSString *selector,
                                                           SRStringReadState * _Nullable state);
/* Exact zero-argument scalar getters only; rejects negatives, floats and pointers. */
FOUNDATION_EXPORT NSNumber * _Nullable SRReadUnsignedInteger(id _Nullable target, NSString *selector, NSError **error);
/* Read-only object(object, integer) lookup. Rejects overflow instead of truncating IDs. */
FOUNDATION_EXPORT id _Nullable SRReadObjectWithObjectAndUnsignedInteger(id _Nullable target, NSString *selector,
                                                                       id object, NSNumber *integer, NSError **error);
FOUNDATION_EXPORT NSDictionary *SRDescribeMethod(id _Nullable target, NSString *selector);
FOUNDATION_EXPORT NSDictionary *SRDescribeInstanceMethod(Class _Nullable type, NSString *selector);
NS_ASSUME_NONNULL_END
