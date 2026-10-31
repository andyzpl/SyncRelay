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
/* Session/chat, numeric message type and host creation time as frozen text. */
@property(nonatomic, copy, readonly) NSString *session;
@property(nonatomic, copy, readonly) NSString *messageType;
@property(nonatomic, copy, readonly) NSString *createdAt;
/* Receiver generation token captured with this menu. */
@property(nonatomic, copy, readonly) NSString *epoch;
@property(nonatomic, copy, readonly) NSString *operationKey;
- (instancetype)initWithAccount:(NSString *)account body:(NSString *)body generation:(NSString *)generation
                     ownerToken:(NSString *)ownerToken messageIdentity:(NSString *)messageIdentity
                        session:(NSString *)session messageType:(NSString *)messageType
                      createdAt:(NSString *)createdAt epoch:(NSString *)epoch operationKey:(NSString *)operationKey;
@end

/* Identity observed again when the host dispatches a menu click. This is a
 * separate value object so a stale cell/menu context cannot be validated by
 * reusing the frozen context itself. */
@interface SRMenuCurrentIdentity : NSObject
@property(nonatomic, copy, readonly) NSString *account;
@property(nonatomic, copy, readonly) NSString *ownerToken;
@property(nonatomic, copy, readonly) NSString *generation;
@property(nonatomic, copy, readonly) NSString *messageIdentity;
@property(nonatomic, copy, readonly) NSString *session;
@property(nonatomic, copy, readonly) NSString *messageType;
@property(nonatomic, copy, readonly) NSString *createdAt;
@property(nonatomic, copy, readonly) NSString *epoch;
@property(nonatomic, copy, readonly) NSString *body;
- (instancetype)initWithAccount:(NSString *)account ownerToken:(NSString *)ownerToken
                     generation:(NSString *)generation messageIdentity:(NSString *)messageIdentity
                        session:(NSString *)session messageType:(NSString *)messageType
                      createdAt:(NSString *)createdAt epoch:(NSString *)epoch body:(NSString *)body;
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

/* Production wiring for the real host menu. `configureHostClasses:` fixes the
 * three classes once; every later resolution re-checks them. */
- (void)configureHostClasses:(nullable Class)menuClass coverClass:(nullable Class)coverClass
                   cellClass:(nullable Class)cellClass;
/* Overrides the message-manager class used for the second-source readback. */
- (void)configureReadbackProvider:(nullable id (^)(void))provider;
- (void)configureEpochProvider:(nullable unsigned long long (^)(void))provider;
- (nullable SRMenuMessageContext *)contextForMenu:(nullable id)menu generation:(nonnull NSString *)generation;
- (nullable SRMenuMessageContext *)contextForMenu:(nullable id)menu generation:(nonnull NSString *)generation
                                        responder:(nullable id)responder;
- (void)rememberResponder:(nullable id)responder forMenu:(nullable id)menu;
/* Optional host icon object (UIImage) supplied by the UI layer. */
- (void)configureMenuIcon:(nullable id)icon;
- (nullable NSArray *)appendHostItemToItems:(nullable NSArray *)items menu:(nullable id)menu
                                     source:(nullable SRMenuMessageContext *)source
                                  itemClass:(nullable Class)itemClass generation:(nonnull NSString *)generation;

@end

/* Strict, metadata-gated resolution of the message a host menu belongs to:
 *   menu.responder -> rich-text cover view -> delegate -> message cell
 *   -> getCurrentMessageWrap
 * Every hop must be a declared method with the expected ABI, and every object
 * must be an instance of the expected class (or a subclass). Any miss returns
 * nil; there is no fallback to a recent message, selection text or clipboard. */
@interface SRMenuHostSource : NSObject
+ (nullable instancetype)sourceForMenu:(nullable id)menu
                             menuClass:(nullable Class)menuClass
                            coverClass:(nullable Class)coverClass
                             cellClass:(nullable Class)cellClass
                               account:(nullable NSString *)account;
@property(nonatomic, copy, readonly, nullable) NSString *messageIdentity;
@property(nonatomic, copy, readonly, nullable) NSString *body;
@property(nonatomic, copy, readonly, nullable) NSString *session;
@property(nonatomic, copy, readonly, nullable) NSString *messageType;
@property(nonatomic, copy, readonly, nullable) NSString *createdAt;
@property(nonatomic) unsigned long long localID;
@property(nonatomic, readonly) BOOL isText;
@end

/* Interceptor state. `installed` means the three IMPs are replaced and every
 * call is forwarded; `sampling` means the session is still recording. Stopping
 * a session never claims the interceptors were removed. */
typedef NS_ENUM(NSUInteger, SRMenuCallObserverState) {
    SRMenuCallObserverIdle = 0,
    SRMenuCallObserverInstalled = 1,
    SRMenuCallObserverSampling = 2,
    SRMenuCallObserverStopped = 3,
};

/* Observation-only interception of the three verified menu methods.
 *
 * This is NOT the read-only metadata scan: it replaces the three IMPs for one
 * explicit session and forwards every call to the original implementation once,
 * unchanged. It never installs itself, never restarts, never adds a menu item,
 * never calls the intake, store, network or media, and never reads a body.
 * `-install...` and `-beginSampling...` are separate, so "interceptors placed"
 * and "recording" are distinct facts.
 *
 * The caller must have obtained an explicit user confirmation before
 * -beginSampling...; this class cannot start a session on its own.
 *
 * The event list holds only fixed labels, integers and booleans. Object
 * references are used only for in-session identity comparison and are never
 * exported. A separate, independently bounded metadata area carries sanitized
 * class names, one action selector name and normalized type tokens taken from
 * the same trampoline arguments; it never carries addresses, descriptions,
 * bodies, accounts, group or message identifiers, or media tokens.
 * The events are a bounded observation, not a business generation. */
@interface SRMenuCallObserver : NSObject
/* Test seam only: the production path uses the wall clock. */
- (instancetype)initWithClock:(NSTimeInterval (^)(void))clock;

@property(nonatomic, readonly) BOOL installed;
@property(nonatomic, readonly) BOOL sampling;
@property(nonatomic, readonly) SRMenuCallObserverState state;
/* YES when -uninstall found that a later hook had already replaced one of the
 * trampolines: the originals were not written back, the interceptors stay in
 * place and keep forwarding lazily, and `installed` stays YES. */
@property(nonatomic, readonly) BOOL restoreRefused;

/* One-time placement of the observers. Fails closed if a candidate method is
 * missing, already installed, or the pair is invalid. Places interceptors only;
 * nothing is recorded until -beginSampling... succeeds. */
- (BOOL)installOnMenuClass:(nullable Class)menuClass itemClass:(nullable Class)itemClass
                     error:(NSError **)error;

/* Starts one bounded session. Requires an explicit caller confirmation, an
 * installed observer, and no active session. `timeout` is a hard wall-clock
 * deadline; `eventBudget` caps all recorded events. */
- (BOOL)beginSamplingWithTimeout:(NSTimeInterval)timeout eventBudget:(NSUInteger)eventBudget
                           error:(NSError **)error;

/* Stops recording. The interceptors stay placed and keep forwarding, so a
 * stopped session is never reported as uninstalled. */
- (void)stopSampling;
/* Same as -stopSampling, with a fixed "lifecycle" reason (foreground exit). */
- (void)stopForLifecycle;

/* Restores the original IMPs only when all three are still this observer's
 * trampolines. If a later hook replaced any of them, nothing is written back:
 * the interceptors stay installed, keep forwarding lazily, and
 * -restoreRefused reports YES instead of claiming an uninstall. */
- (void)uninstall;

/* Current session token. It changes on every successful -beginSampling... and
 * never changes while a session runs, so a delayed callback can prove it still
 * belongs to the session it was scheduled for. */
@property(nonatomic, readonly) NSUInteger sessionToken;

/* Stops the running session only when `token` is still current, with the fixed
 * "timeout" reason. A stale timer therefore cannot stop a later session.
 * Returns YES only when it actually stopped the session. */
- (BOOL)stopForDeadlineToken:(NSUInteger)token;

/* Closes the session identified by `token`: stops recording if it is still
 * sampling, then attempts the safe restore. Returns NO and touches nothing when
 * `token` no longer identifies the current session, so a stale timer can never
 * stop or uninstall a newer one. When the session already stopped on its own
 * (budget, host call, status read) the same token still closes it and the
 * restore is still attempted. */
- (BOOL)finishSessionWithToken:(NSUInteger)token;
/* Same as above with the fixed "timeout" reason for the deadline path. */
- (BOOL)finishSessionForDeadlineToken:(NSUInteger)token;

/* Fixed keys only: state, installed, sampling, restoreRefused, stopReason,
 * counts, budget, the bounded event list and `menuCallMetadata` (bounded class
 * and selector tokens plus normalized type tokens). The select entries also
 * carry candidate handler clues of the clicked item (target/responder class,
 * action name, declared signature and block presence) read only from declared
 * getters. No address, description, account, body, message identity, group,
 * path or media token is included. */
- (NSDictionary *)diagnostics;
@end
NS_ASSUME_NONNULL_END

NS_ASSUME_NONNULL_BEGIN
/* Production menu-build interposer. It appends the one library item through the
 * adapter and forwards the host call exactly once; it never observes, samples or
 * reads the message on its own. */
@interface SRMenuBuildHook : NSObject
- (instancetype)initWithHook:(SRMessageMenuHook *)hook
                   menuClass:(nullable Class)menuClass coverClass:(nullable Class)coverClass
                   cellClass:(nullable Class)cellClass itemClass:(nullable Class)itemClass;
- (BOOL)install:(NSError **)error;
- (void)uninstall;
@property(nonatomic, readonly) BOOL installed;
/* YES when a later hook owned the method: nothing was restored, the trampoline
 * keeps forwarding and `installed` stays YES. */
@property(nonatomic, readonly) BOOL restoreRefused;
@end
NS_ASSUME_NONNULL_END
