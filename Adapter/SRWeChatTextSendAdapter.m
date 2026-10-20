#import "SRWeChatTextSendAdapter.h"
#import "SRRuntime.h"
#import <objc/runtime.h>
#include <string.h>

@interface SRWeChatTextSendAdapter ()
@property(nonatomic, copy) NSString *version;
@property(nonatomic, copy) Class (^resolver)(NSString *);
@property(nonatomic, copy) NSString *(^currentAccount)(void);
@property(nonatomic, copy) BOOL (^environmentAllowed)(void);
@property(nonatomic, copy) SRTextSendOperation operation;
@property(nonatomic, copy) NSString *account;
@property(nonatomic, copy) NSString *group;
@property(nonatomic, copy) NSDictionary *snapshot;
@property(nonatomic, copy) NSString *state;
@property(nonatomic, copy) NSString *problem;
@property(nonatomic, copy) NSString *outcome;
@property(nonatomic) BOOL abiValidated;
@property(nonatomic) BOOL wrapABIValidated;
@property(nonatomic) BOOL submitted;
@property(nonatomic) NSUInteger callbackCount;
@end

static const char *SRTextSendType(const char *type) {
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL SRTextSendObjectType(const char *type) {
    type = SRTextSendType(type);
    return type[0] == '@' && type[1] != '?';
}

static BOOL SRTextSendABI(Class manager) {
    Method method = manager ? class_getInstanceMethod(manager, NSSelectorFromString(@"AddMsg:MsgWrap:")) : NULL;
    if (!method) return NO;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    return signature.numberOfArguments == 4 && !strcmp(SRTextSendType(signature.methodReturnType), "v") &&
        SRTextSendObjectType([signature getArgumentTypeAtIndex:2]) &&
        SRTextSendObjectType([signature getArgumentTypeAtIndex:3]);
}

static BOOL SRTextSendWrapABI(Class wrap) {
    if (!wrap) return NO;
    for (NSString *name in @[@"m_nsFromUsr", @"m_nsToUsr", @"m_nsContent"]) {
        Method method = class_getInstanceMethod(wrap, NSSelectorFromString(name));
        NSMethodSignature *signature = method ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)] : nil;
        if (!signature || signature.numberOfArguments != 2 || !SRTextSendObjectType(signature.methodReturnType)) return NO;
    }
    for (NSString *name in @[@"m_uiMessageType", @"m_uiMesLocalID", @"m_n64MesSvrID", @"m_uiStatus"]) {
        Method method = class_getInstanceMethod(wrap, NSSelectorFromString(name));
        NSMethodSignature *signature = method ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)] : nil;
        const char *type = signature ? SRTextSendType(signature.methodReturnType) : "";
        if (!signature || signature.numberOfArguments != 2 || !type[0] || type[1] || !strchr("iIqQlLsScC", type[0])) return NO;
    }
    return YES;
}

static BOOL SRTextSendSafeIdentifier(NSString *value, BOOL group) {
    if (![value isKindOfClass:NSString.class] || !value.length ||
        [value rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound)
        return NO;
    return !group || [value hasSuffix:@"@chatroom"];
}

static BOOL SRTextSendNonEmptyString(NSString *value) {
    return [value isKindOfClass:NSString.class] && value.length > 0;
}

static NSDictionary *SRTextSendFrozenDictionary(NSDictionary *dictionary) {
    if (![dictionary isKindOfClass:NSDictionary.class] || ![NSJSONSerialization isValidJSONObject:dictionary]) return nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:dictionary options:0 error:NULL];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
}

@implementation SRWeChatTextSendAdapter

- (instancetype)initWithVersion:(NSString *)version classResolver:(Class (^)(NSString *))resolver
                 currentAccount:(NSString *(^)(void))currentAccount
            environmentAllowed:(BOOL (^)(void))environmentAllowed
                       operation:(SRTextSendOperation)operation {
    self = [super init];
    if (self) {
        _version = [version copy];
        _resolver = [resolver copy];
        _currentAccount = [currentAccount copy];
        _environmentAllowed = [environmentAllowed copy];
        _operation = [operation copy];
        _state = @"idle";
        _outcome = @"not_determined";
    }
    return self;
}

- (BOOL)fail:(NSString *)reason error:(NSError **)error {
    @synchronized (self) { self.problem = reason; self.state = @"blocked"; }
    if (error) *error = [NSError errorWithDomain:@"SyncRelay.TextSendAdapter" code:1
        userInfo:@{NSLocalizedDescriptionKey: reason}];
    return NO;
}

- (BOOL)prepareForAccount:(NSString *)account targetGroup:(NSString *)group
           sourceSnapshot:(NSDictionary *)snapshot confirmed:(BOOL)confirmed error:(NSError **)error {
    if (!NSThread.isMainThread) return [self fail:@"Text send preparation must run on the main thread" error:error];
    if (![@[@"8.0.76", @"8.0.79"] containsObject:self.version])
        return [self fail:@"This WeChat version has no text-send adapter candidate" error:error];
    if (!confirmed) return [self fail:@"A second confirmation is required before a text-send test" error:error];
    if (!SRTextSendSafeIdentifier(account, NO) || !SRTextSendSafeIdentifier(group, YES) ||
        [account hasSuffix:@"@chatroom"])
        return [self fail:@"A stable account and one target group are required" error:error];
    NSDictionary *frozen = SRTextSendFrozenDictionary(snapshot);
    if (!frozen || ![frozen[@"account"] isEqual:account] || !SRTextSendSafeIdentifier(frozen[@"group"], YES) ||
        [frozen[@"group"] isEqual:group] ||
        ![frozen[@"type"] isEqual:@"text"] || ![frozen[@"generatedByRelay"] isEqual:@NO] ||
        !SRTextSendSafeIdentifier(frozen[@"sender"], NO) || [frozen[@"sender"] hasSuffix:@"@chatroom"] ||
        !SRTextSendSafeIdentifier(frozen[@"messageID"], NO) ||
        ![frozen[@"payload"] isKindOfClass:NSDictionary.class] ||
        !SRTextSendNonEmptyString(frozen[@"payload"][@"text"]))
        return [self fail:@"Only one confirmed text source snapshot is eligible" error:error];
    Class manager = self.resolver ? self.resolver(@"CMessageMgr") : Nil;
    Class wrap = self.resolver ? self.resolver(@"CMessageWrap") : Nil;
    if (!manager || !SRTextSendABI(manager) || !SRTextSendWrapABI(wrap))
        return [self fail:@"CMessageMgr/CMessageWrap has an absent or incompatible ABI" error:error];
    @synchronized (self) {
        if (self.submitted) return [self fail:@"Reset the previous single-target test before preparing again" error:error];
        self.account = account; self.group = group; self.snapshot = frozen;
        self.abiValidated = YES; self.wrapABIValidated = YES; self.state = @"prepared"; self.problem = nil;
        self.outcome = @"not_determined"; self.callbackCount = 0;
    }
    return YES;
}

- (BOOL)canSendForAccount:(NSString *)account {
    BOOL ready = NO; NSString *preparedAccount; BOOL submitted; BOOL abi;
    @synchronized (self) {
        preparedAccount = self.account; submitted = self.submitted; abi = self.abiValidated;
    }
    @try {
        ready = !submitted && abi && self.operation && [preparedAccount isEqual:account] &&
            [self.currentAccount() isEqual:account] && self.environmentAllowed();
    } @catch (__unused NSException *exception) { ready = NO; }
    return ready;
}

- (void)submitDelivery:(NSDictionary *)delivery snapshot:(NSDictionary *)snapshot completion:(SRSendCompletion)completion {
    NSString *account, *group; NSDictionary *source; SRTextSendOperation operation; BOOL alreadySubmitted;
    @synchronized (self) {
        account = self.account; group = self.group; source = self.snapshot; operation = self.operation; alreadySubmitted = self.submitted;
    }
    NSString *reason = nil;
    if (alreadySubmitted) reason = @"A single-target test does not retry automatically";
    else if (!operation || ![self canSendForAccount:account]) reason = @"Text-send adapter is not ready for this account/environment";
    else if (![snapshot isEqual:source] || ![delivery isKindOfClass:NSDictionary.class] ||
             ![delivery[@"target"] isEqual:group] || ![delivery[@"state"] isEqual:@"submitting"])
        reason = @"Delivery target or frozen source snapshot changed";
    if (reason) {
        if (completion) completion(@"uncertain", nil, reason);
        @synchronized (self) { self.outcome = @"uncertain"; self.problem = reason; self.state = @"blocked"; }
        return;
    }
    @synchronized (self) { self.submitted = YES; self.state = @"submitting"; }
    NSDictionary *request = @{@"account": account, @"target": group, @"type": @"text",
        @"sourceGroup": source[@"group"], @"sourceSender": source[@"sender"],
        @"sourceMessageID": source[@"messageID"], @"payload": source[@"payload"]};
    __block BOOL callbackUsed = NO;
    __weak typeof(self) weakSelf = self;
    SRSendCompletion guarded = ^(NSString *state, NSString *messageID, NSString *callbackReason) {
        @synchronized (weakSelf) {
            if (callbackUsed) return;
            callbackUsed = YES; weakSelf.callbackCount++;
            if ([state isEqual:@"confirmed"] && messageID.length) weakSelf.outcome = @"confirmed";
            else if ([state isEqual:@"failed"]) weakSelf.outcome = @"failed";
            else weakSelf.outcome = @"uncertain";
            weakSelf.state = @"finished"; weakSelf.problem = callbackReason;
        }
        if (completion) completion(([state isEqual:@"confirmed"] && messageID.length) || [state isEqual:@"failed"] ? state : @"uncertain",
                                   ([state isEqual:@"confirmed"] && messageID.length) ? messageID : nil,
                                   callbackReason ?: ([state isEqual:@"failed"] ? @"Host send failed" : @"Host confirmation is not reliable"));
    };
    @try { operation(request, guarded); }
    @catch (__unused NSException *exception) { guarded(@"uncertain", nil, @"Text-send operation threw before a result"); }
}

- (void)reset {
    @synchronized (self) {
        self.account = nil; self.group = nil; self.snapshot = nil; self.abiValidated = NO; self.wrapABIValidated = NO;
        self.submitted = NO; self.state = @"idle"; self.problem = nil; self.outcome = @"not_determined"; self.callbackCount = 0;
    }
}

- (NSDictionary *)diagnostics {
    @synchronized (self) {
        return @{@"wechatVersion": self.version ?: @"", @"observerOnly": @NO, @"sendingEnabled": @NO,
            @"adapterCandidate": @YES, @"operationInjected": @(self.operation != nil),
            @"abiValidated": @(self.abiValidated), @"wrapABIValidated": @(self.wrapABIValidated),
            @"prepared": @(self.snapshot != nil),
            @"submitted": @(self.submitted), @"callbackCount": @(self.callbackCount),
            @"state": self.state ?: @"idle", @"outcome": self.outcome ?: @"not_determined",
            @"problem": self.problem ?: @""};
    }
}

@end
