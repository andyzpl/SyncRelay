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

/* The resolver delivers the resolved class through a non-owning out-parameter
 * instead of returning it: the probe passes the address of its own
 * Nil-initialized `__unsafe_unretained Class` local, and the block writes to it
 * only when it recognises the name. A block that writes nothing therefore leaves
 * the candidate `missing`; once a resolver is supplied the probe never falls
 * back to the runtime lookup.
 *
 * This is the shape the probe itself requests, not a claim that the delivery is
 * free of runtime effects: the resolver block, the property copy and the caller's
 * scope still run under ARC. Only when no resolver is provided does the probe ask
 * the runtime (`NSClassFromString`), which also does not initialize the class.
 * Injecting a resolver keeps the probe testable without any host present. */
typedef void (^SRMenuABIResolver)(NSString *className,
                                  __unsafe_unretained Class _Nullable * _Nonnull resolvedClass);

- (instancetype)initWithResolver:(nullable SRMenuABIResolver)resolver;

/* Explicit collection: runs the read-only scan once and replaces the stored
 * entries, so only the latest three results are kept. It never runs from init,
 * from -lastSnapshot, or from the diagnostic report; one call is one collection
 * and nothing retries on its own. The default state before the first call is
 * "not collected", which the diagnostic report renders as `not_run`. */
- (void)collect;

/* The most recent collection, or nil before the first -collect. Read-only:
 * reading it never re-runs the scan and never changes the stored entries. */
- (nullable NSArray<NSDictionary *> *)lastSnapshot;

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
