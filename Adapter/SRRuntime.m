#import "SRRuntime.h"
#import <objc/runtime.h>
#include <string.h>

static const char *SRType(const char *type) {
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static id SRInvoke(id target, NSString *name, NSArray *arguments, BOOL integers, NSError **error) {
    @try {
        SEL selector = NSSelectorFromString(name);
        if (!target || ![target respondsToSelector:selector]) {
            @throw [NSException exceptionWithName:@"SRRuntime" reason:@"接口不存在" userInfo:nil];
        }
        NSMethodSignature *signature = [target methodSignatureForSelector:selector];
        const char *resultType = signature ? SRType(signature.methodReturnType) : "";
        if (!signature || resultType[0] != '@' || resultType[1] == '?' ||
            signature.numberOfArguments != arguments.count + 2) {
            @throw [NSException exceptionWithName:@"SRRuntime" reason:@"接口返回值或参数数量不匹配" userInfo:nil];
        }
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.target = target;
        invocation.selector = selector;
        for (NSUInteger i = 0; i < arguments.count; i++) {
            const char *type = SRType([signature getArgumentTypeAtIndex:i + 2]);
            id argument = arguments[i];
            if (integers) {
                if (![argument isKindOfClass:NSNumber.class]) {
                    @throw [NSException exceptionWithName:@"SRRuntime" reason:@"参数必须是整数" userInfo:nil];
                }
                switch (type[0]) {
#define SR_INTEGER_CASE(encoding, ctype, getter) \
                    case encoding: { ctype value = [argument getter]; [invocation setArgument:&value atIndex:i + 2]; break; }
                    SR_INTEGER_CASE('i', int, intValue)
                    SR_INTEGER_CASE('I', unsigned int, unsignedIntValue)
                    SR_INTEGER_CASE('q', long long, longLongValue)
                    SR_INTEGER_CASE('Q', unsigned long long, unsignedLongLongValue)
                    SR_INTEGER_CASE('l', long, longValue)
                    SR_INTEGER_CASE('L', unsigned long, unsignedLongValue)
#undef SR_INTEGER_CASE
                    default: @throw [NSException exceptionWithName:@"SRRuntime" reason:@"整数接口签名不匹配" userInfo:nil];
                }
            } else {
                if ((type[0] != '@' && type[0] != '#') || (type[0] == '@' && type[1] == '?')) {
                    @throw [NSException exceptionWithName:@"SRRuntime" reason:@"对象接口签名不匹配" userInfo:nil];
                }
                if (type[0] == '#' && !object_isClass(argument)) {
                    @throw [NSException exceptionWithName:@"SRRuntime" reason:@"接口需要类对象" userInfo:nil];
                }
                __unsafe_unretained id value = argument == NSNull.null ? nil : argument;
                [invocation setArgument:&value atIndex:i + 2];
            }
        }
        [invocation invoke];
        __unsafe_unretained id result = nil;
        [invocation getReturnValue:&result];
        return result;
    } @catch (__unused NSException *exception) {
        if (error) *error = [NSError errorWithDomain:@"SyncRelay.Runtime" code:1
            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"无法安全读取接口 %@，请查看适配诊断", name]}];
        return nil;
    }
}

id SRReadObject(id target, NSString *selector, NSArray *arguments, NSError **error) {
    return SRInvoke(target, selector, arguments, NO, error);
}
id SRReadObjectWithIntegers(id target, NSString *selector, NSArray<NSNumber *> *arguments, NSError **error) {
    return SRInvoke(target, selector, arguments, YES, error);
}
NSString *SRReadString(id target, NSString *selector) {
    id result = SRReadObject(target, selector, @[], NULL);
    return [result isKindOfClass:NSString.class] ? result : nil;
}
NSDictionary *SRDescribeMethod(id target, NSString *selector) {
    @try {
        SEL sel = NSSelectorFromString(selector);
        NSMethodSignature *signature = [target respondsToSelector:sel] ? [target methodSignatureForSelector:sel] : nil;
        if (!signature) return @{@"selector": selector, @"available": @NO};
        NSMutableArray *types = [NSMutableArray array];
        for (NSUInteger i = 2; i < signature.numberOfArguments; i++) [types addObject:@([signature getArgumentTypeAtIndex:i])];
        return @{@"selector": selector, @"available": @YES, @"return": @(signature.methodReturnType), @"arguments": types};
    } @catch (__unused NSException *exception) {
        return @{@"selector": selector, @"available": @NO};
    }
}

NSDictionary *SRDescribeInstanceMethod(Class type, NSString *selector) {
    Method method = type ? class_getInstanceMethod(type, NSSelectorFromString(selector)) : NULL;
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    return @{@"selector": selector, @"available": @(encoding != NULL), @"encoding": encoding ? @(encoding) : @""};
}
