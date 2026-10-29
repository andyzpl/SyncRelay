#import <Foundation/Foundation.h>
@class SRLibraryIntake;

NS_ASSUME_NONNULL_BEGIN

/* Why an installation was refused. Only SRMenuGateMatched may install. */
typedef NS_ENUM(NSUInteger, SRMenuGateStatus) {
    SRMenuGateMatched = 0,
    SRMenuGateClassMissing = 1,
    SRMenuGateMethodMissing = 2,
    SRMenuGateKindMismatch = 3,
    SRMenuGateEncodingMismatch = 4,
};

/* One menu confirmation, frozen at the moment the menu was built. Every field is
 * read-only and copied at initialization: nothing here can be rewritten after
 * the fact, and no external mutable string is retained. */
@interface SRMenuMessageContext : NSObject
@property(nonatomic, copy, readonly) NSString *account;
@property(nonatomic, copy, readonly) NSString *body;
@property(nonatomic, copy, readonly) NSString *generation;
/* Stable owner/receiver token for the menu instance that produced this item. */
@property(nonatomic, copy, readonly) NSString *ownerToken;
/* Stable identity of the selected message as reported by the host adapter. */
@property(nonatomic, copy, readonly) NSString *messageIdentity;
@property(nonatomic, copy, readonly) NSString *operationKey;
- (instancetype)initWithAccount:(NSString *)account body:(NSString *)body generation:(NSString *)generation
                     ownerToken:(NSString *)ownerToken messageIdentity:(NSString *)messageIdentity
                operationKey:(NSString *)operationKey;
@end

/* Identity observed again when the host dispatches a menu click. This is a
 * separate value object so a stale cell/menu context cannot be validated by
 * reusing the frozen context itself. */
@interface SRMenuCurrentIdentity : NSObject
@property(nonatomic, copy, readonly) NSString *account;
@property(nonatomic, copy, readonly) NSString *ownerToken;
@property(nonatomic, copy, readonly) NSString *generation;
@property(nonatomic, copy, readonly) NSString *messageIdentity;
- (instancetype)initWithAccount:(NSString *)account ownerToken:(NSString *)ownerToken
                      generation:(NSString *)generation messageIdentity:(NSString *)messageIdentity;
@end

/* What a click produced. Mirrors the intake outcomes so the caller can show
 * distinct messages instead of one "failed". */
typedef NS_ENUM(NSUInteger, SRMenuIntentResult) {
    SRMenuIntentSaved = 0,
    SRMenuIntentDuplicate = 1,
    SRMenuIntentUnsupported = 2,
    SRMenuIntentContextStale = 3,
    SRMenuIntentStorageUnavailable = 4,
    SRMenuIntentWriteFailed = 5,
    SRMenuIntentNotOurs = 6,
    /* The entry preference is off: the menu is left exactly as the host and
     * any other tweak built it, and an old item refuses to save. */
    SRMenuIntentDisabled = 7,
};

/* Controlled adapter for the chat long-press menu.
 *
 * Two halves, deliberately separated:
 * - `gateMenuClass:itemClass:` is pure: it checks that the host
 *   really declares the candidate methods with the expected kind, argument count
 *   and type encodings. It never trusts a helper's encoding and never treats
 *   respondsToSelector as proof.
 * - `appendOwnItemToItems:` / `handleSelection:current:` are the
 *   behaviour: one appended item per generation, one intent per operation, and
 *   a stale account / owner / generation / message identity refuses without
 *   touching the library.
 *
 * The class performs no SQLite work, creates no task and sends nothing; it only
 * normalizes a selection and reports an intent to its owner, which calls the
 * intake. */
@interface SRMessageMenuHook : NSObject
- (instancetype)initWithIntake:(SRLibraryIntake *)intake
                currentAccount:(NSString * _Nullable (^)(void))currentAccount
                 accountActive:(BOOL (^)(NSString *account))accountActive
                       enabled:(BOOL (^ _Nullable)(void))enabled;


/* Supported candidate signatures, fixed by this build rather than read back:
 *   setMenuItems:                     void   ( self, _cmd, object )
 *   onMenuItemSelected:itemView:      void   ( self, _cmd, object, object )
 *   initWithTitle:icon:target:action: object ( self, _cmd, object, object, object, SEL )
 * Each return type and every argument type is compared individually. An object,
 * a block, a SEL, a pointer and an integer never substitute for each other.
 * These are the shapes this build can drive - not evidence that a host build
 * exposes them. The gate only inspects; it installs and calls nothing. */
- (SRMenuGateStatus)gateMenuClass:(nullable Class)menuClass itemClass:(nullable Class)itemClass;

- (BOOL)isInstalled;
- (void)markInstalled;

/* Appends one private marker per active generation. Foreign items — including a
 * same-titled item from another tweak — are kept untouched and never treated as
 * ours. The marker is a testable adapter object until a verified host item
 * factory is supplied by the entry layer. */
- (NSArray *)appendOwnItemToItems:(nullable NSArray *)items
                       generation:(NSString *)generation
                           source:(SRMenuMessageContext *)source;

/* YES only for the item this hook created. */
- (BOOL)ownsItem:(nullable id)item;

/* Delivers an intent only when the independently observed identity still
 * matches the frozen menu context. */
- (SRMenuIntentResult)handleSelection:(nullable id)item
                              current:(nullable SRMenuCurrentIdentity *)current;

- (nullable SRMenuMessageContext *)contextForOwnItem:(nullable id)item;
@end
NS_ASSUME_NONNULL_END
