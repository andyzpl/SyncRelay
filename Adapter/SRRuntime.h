#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/* Only existing methods with checked object-return/argument encodings are invoked. */
FOUNDATION_EXPORT id _Nullable SRReadObject(id _Nullable target, NSString *selector,
                                           NSArray *arguments, NSError **error);
FOUNDATION_EXPORT id _Nullable SRReadObjectWithIntegers(id _Nullable target, NSString *selector,
                                                       NSArray<NSNumber *> *arguments, NSError **error);
FOUNDATION_EXPORT NSString * _Nullable SRReadString(id _Nullable target, NSString *selector);
/* Exact zero-argument scalar getters only; rejects negatives, floats and pointers. */
FOUNDATION_EXPORT NSNumber * _Nullable SRReadUnsignedInteger(id _Nullable target, NSString *selector, NSError **error);
FOUNDATION_EXPORT NSDictionary *SRDescribeMethod(id _Nullable target, NSString *selector);
FOUNDATION_EXPORT NSDictionary *SRDescribeInstanceMethod(Class _Nullable type, NSString *selector);
NS_ASSUME_NONNULL_END
