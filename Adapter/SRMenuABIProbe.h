#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* Read-only metadata snapshot of the three candidate host menu methods.
 *
 * The probe reads existing method lists only: it walks class_copyMethodList along
 * the superclass chain and the metaclass chain instead of class_getInstanceMethod
 * / class_getClassMethod, because those may trigger +resolveInstanceMethod: /
 * +resolveClassMethod: on a host class. It therefore cannot run host code: no IMP
 * is executed, no message is sent to a candidate class or object, no host object
 * is created, no message or ivar is read, and the library, intake and network are
 * never touched.
 *
 * The output is a fixed three-entry array with fixed keys and a closed vocabulary
 * of values, so it can be attached to a diagnostic report without leaking
 * bodies, identifiers, addresses or paths. A class name from the host is never
 * echoed back; only the candidate label is. */
@interface SRMenuABIProbe : NSObject

/* `resolver` maps a candidate class name to a Class. The default resolver asks
 * the runtime (`NSClassFromString`), which also does not initialize the class.
 * Injecting one keeps the probe testable without any host present. */
- (instancetype)initWithResolver:(nullable Class _Nullable (^)(NSString *className))resolver;

/* Three entries, in this order:
 *   MMMenuController / setMenuItems:
 *   MMMenuController / onMenuItemSelected:itemView:
 *   MMMenuItem       / initWithTitle:icon:target:action:
 *
 * Keys: candidate, classStatus, methodStatus, argumentCount, returnToken,
 * argumentTokens. Values come from fixed sets:
 *   classStatus  : present | missing
 *   methodStatus : direct | inherited | class_only | missing
 *   argumentCount: a decimal string up to 8, or over_limit
 *   *Token       : void | object | block | SEL | bool | char | uchar | int16 |
 *                  uint16 | int32 | uint32 | long | ulong | int64 | uint64 |
 *                  pointer | unknown
 * argumentTokens includes self and _cmd. `char` is never reported as BOOL, and
 * raw `l`/`L` encodings stay distinct from `q`/`Q`; on LP64 a C `long` may
 * therefore be reported as `int64`/`uint64` because the compiler emits q/Q. */
- (NSArray<NSDictionary *> *)snapshot;

@end
NS_ASSUME_NONNULL_END
