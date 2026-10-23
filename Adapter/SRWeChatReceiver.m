#import "SRWeChatReceiver.h"
#import "SRRuntime.h"
#import "Core/SRSourceMessage.h"
#import "Core/SRConfiguration.h"
#import "Core/SRImageAssetStore.h"
#import "Core/SROperationsState.h"
#import <objc/runtime.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

static const NSUInteger SRAppMessageByteLimit = 128 * 1024;
static const NSUInteger SRAppMessageSampleLimit = 16;

/* Read only structural evidence. No title, URL, attachment ID or raw XML is
 * retained in the result, and a parsed subtype is never a relay payload. */
@interface SRAppMessageXMLProbe : NSObject <NSXMLParserDelegate>
@property(nonatomic, strong) NSMutableArray<NSString *> *path;
@property(nonatomic, strong) NSMutableSet<NSString *> *seen;
@property(nonatomic, strong) NSMutableDictionary *presence;
@property(nonatomic, strong) NSMutableString *typeText;
@property(nonatomic, copy) NSString *field;
@property(nonatomic, copy) NSString *failure;
@property(nonatomic) NSUInteger appDepth;
@property(nonatomic) NSUInteger elements;
+ (NSDictionary *)summaryForContent:(NSString *)content sender:(NSString *)sender;
@end

@implementation SRAppMessageXMLProbe
- (void)reject:(NSString *)state parser:(NSXMLParser *)parser {
    if (!self.failure) self.failure = state;
    [parser abortParsing];
}
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)element
    namespaceURI:(__unused NSString *)namespaceURI qualifiedName:(__unused NSString *)qualifiedName
    attributes:(NSDictionary<NSString *, NSString *> *)attributes {
    if (++self.elements > 1024 || self.path.count >= 32) { [self reject:@"too_complex" parser:parser]; return; }
    if (self.field) { [self reject:@"unsupported_structure" parser:parser]; return; }
    for (NSString *key in attributes)
        if ([key isEqual:@"xmlns"] || [key hasPrefix:@"xmlns:"]) { [self reject:@"unsupported_structure" parser:parser]; return; }
    if (!self.path.count && ![@[@"msg", @"appmsg"] containsObject:element]) {
        [self reject:@"unsupported_structure" parser:parser]; return;
    }
    [self.path addObject:element];
    if ([element isEqual:@"appmsg"]) {
        if (self.appDepth || (self.path.count != 1 &&
            !(self.path.count == 2 && [self.path[0] isEqual:@"msg"]))) {
            [self reject:@"unsupported_structure" parser:parser]; return;
        }
        self.appDepth = self.path.count;
    }
    BOOL direct = self.appDepth && self.path.count == self.appDepth + 1 &&
        [self.path[self.appDepth - 1] isEqual:@"appmsg"];
    BOOL attachment = self.appDepth && self.path.count == self.appDepth + 2 &&
        [self.path[self.appDepth - 1] isEqual:@"appmsg"] && [self.path[self.appDepth] isEqual:@"appattach"];
    NSString *field = nil;
    if (direct) field = @{@"type": @"type", @"title": @"hasTitle", @"url": @"hasURL", @"appattach": @"hasAttachment"}[element];
    if (attachment) field = @{@"attachid": @"hasAttachmentID", @"fileext": @"hasFileExtension", @"totallen": @"hasTotalLength"}[element];
    if (!field) return;
    if ([self.seen containsObject:field]) { [self reject:@"ambiguous_fields" parser:parser]; return; }
    [self.seen addObject:field];
    if ([field isEqual:@"hasAttachment"]) self.presence[field] = @YES;
    else self.field = field;
}
- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)text {
    if ([self.field isEqual:@"type"]) {
        if (text.length > 32 - self.typeText.length) { [self reject:@"invalid_subtype" parser:parser]; return; }
        [self.typeText appendString:text];
    } else if (self.field && [text rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet.invertedSet].location != NSNotFound) {
        self.presence[self.field] = @YES;
    }
}
- (void)parser:(NSXMLParser *)parser foundCDATA:(NSData *)data {
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) { [self reject:@"invalid_xml" parser:parser]; return; }
    [self parser:parser foundCharacters:text];
}
- (void)parser:(__unused NSXMLParser *)parser didEndElement:(__unused NSString *)element
    namespaceURI:(__unused NSString *)namespaceURI qualifiedName:(__unused NSString *)qualifiedName {
    self.field = nil; if (self.path.count) [self.path removeLastObject];
}
- (NSData *)parser:(NSXMLParser *)parser resolveExternalEntityName:(__unused NSString *)name systemID:(__unused NSString *)systemID {
    [self reject:@"unsafe_xml" parser:parser]; return nil;
}
- (void)parser:(__unused NSXMLParser *)parser parseErrorOccurred:(__unused NSError *)error {
    // Treat every error callback as failure independently of the parse return.
    if (!self.failure) self.failure = @"invalid_xml";
}
+ (NSDictionary *)summaryForContent:(NSString *)content sender:(NSString *)sender {
    if (!content.length) return @{@"state": @"empty_content"};
    if (content.length > SRAppMessageByteLimit) return @{@"state": @"too_large"};
    // NULs could make a UTF-8 buffer look like UTF-16 to an auto-detecting parser.
    if ([content rangeOfCharacterFromSet:[NSCharacterSet characterSetWithRange:NSMakeRange(0, 1)]].location != NSNotFound)
        return @{@"state": @"unsafe_xml"};
    NSString *xml = [content stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([xml hasPrefix:@"\uFEFF"]) xml = [[xml substringFromIndex:1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (![xml hasPrefix:@"<"]) {
        NSRange newline = [xml rangeOfString:@"\n"];
        if (newline.location == NSNotFound || newline.location > 256) return @{@"state": @"unsupported_structure"};
        NSString *prefix = [xml substringToIndex:newline.location];
        if ([prefix hasSuffix:@"\r"]) prefix = [prefix substringToIndex:prefix.length - 1];
        if (![prefix isEqual:[sender stringByAppendingString:@":"]]) return @{@"state": @"sender_prefix_mismatch"};
        xml = [[xml substringFromIndex:newline.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    }
    if ([xml hasPrefix:@"\uFEFF"]) xml = [[xml substringFromIndex:1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([xml hasPrefix:@"<?xml"]) {
        NSRange end = [xml rangeOfString:@"?>" options:0 range:NSMakeRange(0, MIN(xml.length, (NSUInteger)256))];
        if (end.location == NSNotFound) return @{@"state": @"invalid_xml"};
        NSString *declaration = [xml substringToIndex:end.location + end.length];
        NSRegularExpression *encoding = [NSRegularExpression regularExpressionWithPattern:@"\\bencoding\\s*=\\s*(['\"])([^'\"]+)\\1"
            options:NSRegularExpressionCaseInsensitive error:NULL];
        NSArray<NSTextCheckingResult *> *matches = [encoding matchesInString:declaration options:0 range:NSMakeRange(0, declaration.length)];
        if (matches.count > 1) return @{@"state": @"invalid_xml"};
        if (matches.count && [[declaration substringWithRange:[matches[0] rangeAtIndex:2]] caseInsensitiveCompare:@"UTF-8"] != NSOrderedSame)
            return @{@"state": @"unsafe_xml"};
        if (!matches.count && [declaration rangeOfString:@"encoding" options:NSCaseInsensitiveSearch].location != NSNotFound)
            return @{@"state": @"invalid_xml"};
    }
    // Reject DTDs before Foundation sees them, including internal/parameter entities.
    if ([xml rangeOfString:@"<!DOCTYPE" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [xml rangeOfString:@"<!ENTITY" options:NSCaseInsensitiveSearch].location != NSNotFound)
        return @{@"state": @"unsafe_xml"};
    NSData *data = [xml dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return @{@"state": @"invalid_xml"};
    if (data.length > SRAppMessageByteLimit) return @{@"state": @"too_large"};
    SRAppMessageXMLProbe *probe = [SRAppMessageXMLProbe new];
    probe.path = [NSMutableArray array]; probe.seen = [NSMutableSet set];
    probe.typeText = [NSMutableString string]; probe.presence = [NSMutableDictionary dictionary];
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data]; parser.delegate = probe;
    parser.shouldResolveExternalEntities = NO;
    parser.externalEntityResolvingPolicy = NSXMLParserResolveExternalEntitiesNever;
    BOOL parsed = [parser parse];
    if (!parsed || probe.failure) return @{@"state": probe.failure ?: @"invalid_xml"};
    if (!probe.appDepth) return @{@"state": @"unsupported_structure"};
    NSString *type = [probe.typeText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!type.length || type.length > 10) return @{@"state": @"invalid_subtype"};
    unsigned long long value = 0;
    for (NSUInteger index = 0; index < type.length; index++) {
        unichar digit = [type characterAtIndex:index];
        if (digit < '0' || digit > '9') return @{@"state": @"invalid_subtype"};
        value = value * 10 + digit - '0';
        if (value > UINT32_MAX) return @{@"state": @"invalid_subtype"};
    }
    NSMutableDictionary *result = [@{@"state": @"parsed", @"subtype": @(value),
        @"kindHint": value == 5 ? @"link" : (value == 6 ? @"file" : @"other")} mutableCopy];
    for (NSString *key in @[@"hasTitle", @"hasURL", @"hasAttachment", @"hasAttachmentID", @"hasFileExtension", @"hasTotalLength"])
        result[key] = @([probe.presence[key] boolValue]);
    return [result copy];
}
@end

@class SRReceiveTap;
@interface SRPendingOwnText : NSObject
@property(nonatomic, strong) id wrap;
@property(nonatomic, weak) id manager;
@property(nonatomic, copy) NSString *text;
@property(nonatomic, copy) NSNumber *localID;
@property(nonatomic, copy) NSNumber *messageType;
@property(nonatomic, copy) NSDictionary *timeEvidence;
@end
@implementation SRPendingOwnText
@end

@interface SRPendingImage : NSObject
@property(nonatomic, strong) id wrap;
@property(nonatomic, copy) NSDictionary *source;
@property(nonatomic, copy) NSDictionary *timeEvidence;
@property(nonatomic) NSTimeInterval deadline;
@end
@implementation SRPendingImage
@end

@interface SRDirectionObservation : NSObject
@property(nonatomic, weak) SRWeChatReceiver *owner;
@property(nonatomic) NSUInteger generation;
@property(nonatomic, copy) NSDictionary *before;
@end
@implementation SRDirectionObservation
@end

@interface SRWeChatReceiver ()
@property(nonatomic, copy) NSString *version;
@property(nonatomic, copy) Class (^resolver)(NSString *);
@property(nonatomic, copy) NSString *(^currentAccount)(void);
@property(nonatomic, copy) void (^received)(NSDictionary *);
@property(nonatomic, copy) NSTimeInterval (^clock)(void);
@property(nonatomic, copy) NSString *account;
@property(nonatomic, copy) NSString *group;
@property(nonatomic, copy) NSString *problem;
@property(nonatomic) BOOL armed;
@property(nonatomic) NSUInteger generation;
@property(nonatomic, strong) SRReceiveTap *tap;
@property(nonatomic, strong) SRReceiveTap *outgoingTap;
@property(nonatomic, strong) SRPendingOwnText *pendingOutgoing;
@property(nonatomic, copy) NSString *ownTextState;
@property(nonatomic) NSUInteger queuedOutgoing;
@property(nonatomic, strong) NSMutableDictionary *counters;
@property(nonatomic) NSTimeInterval armedAt;
@property(nonatomic) NSTimeInterval lastCallbackAt;
@property(nonatomic, strong) NSMutableArray *directionSamples;
@property(nonatomic) NSUInteger directionReservations;
@property(nonatomic) NSUInteger directionDropped;
@property(nonatomic, copy) NSSet *senderIDs;
@property(nonatomic, copy) NSSet *selectedTypes;
/* Bounded, numeric-only probe for device evidence. This does not make an
 * unsupported type capturable or relayable. */
@property(nonatomic, strong) NSMutableDictionary *observedMessageTypes;
@property(nonatomic, strong) NSMutableArray *observedMessageTypeSequence;
@property(nonatomic, strong) NSMutableArray *appMessageSamples;
@property(nonatomic) NSUInteger appMessageReservations;
@property(nonatomic) NSUInteger appMessageDropped;
@property(nonatomic, strong) SRPendingImage *pendingImage;
@property(nonatomic, copy) NSString *imageState;
@property(nonatomic) NSUInteger imageReads;
@property(nonatomic) NSUInteger queuedImages;
@property(nonatomic) NSUInteger imagePreparationCode;
@property(nonatomic) BOOL newMessagesOnly;
- (SRDirectionObservation *)beginDirectionForSession:(id)session wrap:(id)wrap;
- (void)finishDirection:(SRDirectionObservation *)observation path:(NSString *)path wrap:(id)wrap;
- (NSDictionary *)beginTimeEvidenceForSession:(id)session wrap:(id)wrap;
- (void)observeSession:(id)session wrap:(id)wrap timeEvidence:(NSDictionary *)evidence;
- (void)observeOutgoingManager:(id)manager session:(id)session wrap:(id)wrap timeEvidence:(NSDictionary *)evidence;
- (void)observeMessageType:(NSNumber *)type;
- (void)observeAppMessageWrap:(id)wrap sender:(NSString *)sender from:(NSString *)from to:(NSString *)to
    timeEvidence:(NSDictionary *)evidence generation:(NSUInteger)generation;
- (void)pollOutgoing:(SRPendingOwnText *)pending group:(NSString *)group account:(NSString *)account generation:(NSUInteger)generation remaining:(NSUInteger)remaining;
@end

@interface SRReceiveTap : NSObject
@property(nonatomic) IMP original;
@property(atomic, weak) SRWeChatReceiver *listener;
@end
@implementation SRReceiveTap
@end

static NSMutableDictionary *SRTaps(void) {
    static NSMutableDictionary *taps; static dispatch_once_t once;
    dispatch_once(&once, ^{ taps = [NSMutableDictionary dictionary]; }); return taps;
}
static const char *SRReceiveType(const char *type) {
    while (*type && strchr("rnNoORV", *type)) type++; return type;
}
static BOOL SRReceiveSignature(Method method) {
    if (!method) return NO;
    @try {
        NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
        if (strcmp(SRReceiveType(signature.methodReturnType), "v") || signature.numberOfArguments != 4) return NO;
        for (NSUInteger i = 2; i < 4; i++) {
            const char *type = SRReceiveType([signature getArgumentTypeAtIndex:i]);
            if (type[0] != '@' || type[1] == '?') return NO;
        }
        return YES;
    } @catch (__unused id exception) { return NO; }
}
static BOOL SRReceiveGetter(Class type, NSString *name, BOOL integer) {
    Method method = type ? class_getInstanceMethod(type, NSSelectorFromString(name)) : NULL;
    if (!method) return NO;
    @try {
        NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
        const char *result = SRReceiveType(signature.methodReturnType);
        if (signature.numberOfArguments != 2 || !result[0]) return NO;
        return integer ? strchr("iIqQlLsScC", result[0]) != NULL : (result[0] == '@' && result[1] != '?');
    } @catch (__unused id exception) { return NO; }
}
static BOOL SRReceiveTimeGetter(Class type) {
    if (!SRReceiveGetter(type, @"m_uiCreateTime", YES)) return NO;
    Method method = class_getInstanceMethod(type, NSSelectorFromString(@"m_uiCreateTime"));
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    const char *result = SRReceiveType(signature.methodReturnType);
    return result[0] && !result[1] && strchr("iIqQlL", result[0]) != NULL;
}

// Reflection is diagnostic evidence, never a substitute for the declared getter ABI.
static NSUInteger SRDirectionReflection(id wrap, NSString *name) {
    @try {
        if (!wrap) return 0;
        SEL selector = NSSelectorFromString(name);
        if (![wrap respondsToSelector:selector]) return 1;
        NSMethodSignature *signature = [wrap methodSignatureForSelector:selector];
        const char *type = signature ? SRReceiveType(signature.methodReturnType) : "";
        return signature && signature.numberOfArguments == 2 && type[0] == '@' && type[1] != '?' ? 7 : 2;
    } @catch (__unused id exception) { return 3; }
}
static NSDictionary *SRDirectionSnapshot(id wrap, Class expected, NSString *account, NSString *group) {
    SRStringReadState fromState, toState, senderState;
    NSString *from = SRReadDeclaredString(wrap, @"m_nsFromUsr", &fromState);
    NSString *to = SRReadDeclaredString(wrap, @"m_nsToUsr", &toState);
    NSString *sender = SRReadDeclaredString(wrap, @"m_nsRealChatUsr", &senderState);
    NSUInteger classCode = !wrap ? 0 : (expected && object_getClass(wrap) == expected ? 1 :
        (expected && [wrap isKindOfClass:expected] ? 2 : 3));
    NSNumber *type = SRReadUnsignedInteger(wrap, @"m_uiMessageType", NULL);
    return @{@"wrapClassCode": @(classCode), @"fromState": @(fromState), @"toState": @(toState), @"senderState": @(senderState),
        @"fromInstanceSignatureState": @(SRDirectionReflection(wrap, @"m_nsFromUsr")),
        @"toInstanceSignatureState": @(SRDirectionReflection(wrap, @"m_nsToUsr")),
        @"senderInstanceSignatureState": @(SRDirectionReflection(wrap, @"m_nsRealChatUsr")),
        @"fromIsAccount": @([from isEqual:account]), @"fromIsSource": @([from isEqual:group]), @"fromIsGroup": @([from hasSuffix:@"@chatroom"]),
        @"toIsAccount": @([to isEqual:account]), @"toIsSource": @([to isEqual:group]), @"toIsGroup": @([to hasSuffix:@"@chatroom"]),
        @"senderIsAccount": @([sender isEqual:account]), @"senderIsSource": @([sender isEqual:group]),
        @"senderIsGroup": @([sender hasSuffix:@"@chatroom"]), @"fromEqualsTo": @(from.length && [from isEqual:to]),
        @"senderEqualsFrom": @(sender.length && [sender isEqual:from]), @"senderEqualsTo": @(sender.length && [sender isEqual:to]),
        @"typeReadable": @(type != nil), @"messageType": type ?: @0};
}

static NSDictionary *SRMessageTypeProbeSnapshot(NSDictionary *counts, NSArray *sequence) {
    NSMutableArray *rows = [NSMutableArray array];
    NSArray *keys = [counts.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
        unsigned long long a = (unsigned long long)left.longLongValue, b = (unsigned long long)right.longLongValue;
        return a < b ? NSOrderedAscending : (a > b ? NSOrderedDescending : [left compare:right]);
    }];
    for (NSString *key in keys) {
        NSNumber *type = @((unsigned long long)key.longLongValue);
        NSNumber *count = counts[key];
        if (type.unsignedLongLongValue > UINT32_MAX || ![count isKindOfClass:NSNumber.class]) continue;
        NSMutableDictionary *row = [@{ @"type": type, @"count": count } mutableCopy];
        /* These are only static Mikoto route observations.  They are not
         * payload decoders and must never make a type relayable. */
        switch (type.unsignedIntValue) {
            case 34: row[@"observedRoute"] = @"receiveMessageWrapWithType34"; break;
            case 42: row[@"observedRoute"] = @"receiveMessageWrapWithType42"; break;
            case 47: row[@"observedRoute"] = @"receiveMessageWrapWithType47"; break;
            case 49: row[@"observedRoute"] = @"receiveMessageWrapWithType49"; break;
            default: break;
        }
        [rows addObject:row];
    }
    return @{ @"schema": @1, @"rows": rows, @"sequence": sequence ?: @[] };
}

@implementation SRWeChatReceiver
- (instancetype)initWithVersion:(NSString *)version classResolver:(Class (^)(NSString *))resolver
                currentAccount:(NSString *(^)(void))currentAccount received:(void (^)(NSDictionary *))received {
    return [self initWithVersion:version classResolver:resolver currentAccount:currentAccount received:received
        clock:^NSTimeInterval { return NSDate.date.timeIntervalSince1970; }];
}
- (instancetype)initWithVersion:(NSString *)version classResolver:(Class (^)(NSString *))resolver
                currentAccount:(NSString *(^)(void))currentAccount received:(void (^)(NSDictionary *))received clock:(NSTimeInterval (^)(void))clock {
    self = [super init];
    if (self) {
        _version = [version copy]; _resolver = [resolver copy]; _currentAccount = [currentAccount copy];
        _received = [received copy]; _clock = [clock copy];
    }
    return self;
}
- (NSTimeInterval)observationTime {
    @try { NSTimeInterval time = self.clock(); return isfinite(time) && time > 0 ? time : 0; }
    @catch (__unused id exception) { return 0; }
}
- (NSDictionary *)beginTimeEvidenceForSession:(id)session wrap:(id)wrap {
    NSUInteger generation; NSTimeInterval since;
    @synchronized(self) {
        if (!self.armed || ![session isKindOfClass:NSString.class] || ![session isEqual:self.group]) return nil;
        generation = self.generation; since = self.armedAt;
    }
    NSTimeInterval received = [self observationTime];
    NSNumber *created = SRReadDeclaredUnsignedInteger(wrap, @"m_uiCreateTime");
    // JSON/double time evidence must remain exact; never round a large host ID.
    if (!created.unsignedLongLongValue || created.unsignedLongLongValue > 9007199254740991ULL) created = nil;
    return @{@"schema": @1, @"generation": @(generation), @"createdAt": created ?: (id)NSNull.null,
        @"receivedAt": @(received), @"listeningSince": @(since)};
}
- (NSDictionary *)beginTimeHookForSession:(id)session wrap:(id)wrap evidence:(NSDictionary *)evidence {
    NSString *account, *group; NSSet *senders;
    NSUInteger generation;
    @synchronized(self) {
        if (!self.armed || !self.observeTimeHook || ![session isEqual:self.group] || !evidence ||
            [evidence[@"generation"] unsignedIntegerValue] != self.generation) return nil;
        account = self.account; group = self.group; senders = self.senderIDs; generation = self.generation;
    }
    // Host getters run outside our lock; they may reenter the original chain.
    NSString *from = SRReadDeclaredString(wrap, @"m_nsFromUsr", NULL);
    NSString *to = SRReadDeclaredString(wrap, @"m_nsToUsr", NULL);
    NSString *sender = SRReadDeclaredString(wrap, @"m_nsRealChatUsr", NULL);
    BOOL own = [from isEqual:account] && [to isEqual:group];
    if (own) {
        if (sender.length && ![sender isEqual:account]) return nil;
        sender = account;
    } else if (![from isEqual:group] || ![to isEqual:account]) return nil;
    if (!sender.length || ![senders containsObject:sender]) return nil;
    NSNumber *type = SRReadDeclaredUnsignedInteger(wrap, @"m_uiMessageType");
    if (![@[@1, @3] containsObject:type]) return nil;
    @synchronized(self) {
        if (!self.armed || !self.observeTimeHook || self.generation != generation) return nil;
        // Reserve before queueing: hook bursts cannot allocate an unbounded
        // main-queue backlog. Raw identifiers stay inside this process only.
        NSUInteger reserved = [self.counters[@"time_hook_reserved"] unsignedIntegerValue];
        if (reserved >= 16) return nil;
        self.counters[@"time_hook_reserved"] = @(reserved + 1);
    }
    Class actual = object_getClass(wrap);
    Method method = actual ? class_getInstanceMethod(actual, NSSelectorFromString(@"m_uiCreateTime")) : NULL;
    NSString *encoding = method ? @"incompatible" : @"missing";
    if (method && SRReceiveTimeGetter(actual)) {
        NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
        if (!strcmp(SRReceiveType([signature getArgumentTypeAtIndex:0]), "@") &&
            !strcmp(SRReceiveType([signature getArgumentTypeAtIndex:1]), ":"))
            encoding = [NSString stringWithUTF8String:SRReceiveType(signature.methodReturnType)];
    }
    NSNumber *server = SRReadDeclaredUnsignedInteger(wrap, @"m_n64MesSvrID");
    NSNumber *local = SRReadDeclaredUnsignedInteger(wrap, @"m_uiMesLocalID");
    return @{@"account": account, @"sender": sender, @"type": type, @"selfSource": @(own),
        @"serverID": server ?: @0, @"localID": local ?: @0, @"evidence": evidence,
        @"actualGetterEncoding": encoding};
}
- (void)finishTimeHook:(NSDictionary *)observation path:(NSString *)path {
    if (!observation) return;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        SRWeChatReceiver *receiver = weakSelf;
        if (!receiver) return;
        @try {
            @synchronized(receiver) {
                if (!receiver.armed || !receiver.observeTimeHook ||
                    [observation[@"evidence"][@"generation"] unsignedIntegerValue] != receiver.generation) return;
            }
            if (![receiver.currentAccount() isEqual:observation[@"account"]]) return;
            void (^consume)(NSDictionary *) = nil;
            @synchronized(receiver) {
                if (!receiver.armed || [observation[@"evidence"][@"generation"] unsignedIntegerValue] != receiver.generation) return;
                consume = [receiver.observeTimeHook copy];
            }
            NSMutableDictionary *sample = [observation mutableCopy]; sample[@"path"] = path;
            if (consume) consume(sample);
        } @catch (__unused id exception) { /* Observation must not alter the host chain. */ }
    });
}
- (BOOL)acceptsTimeEvidence:(NSDictionary *)evidence wrap:(id)wrap generation:(NSUInteger)generation {
    BOOL strict;
    @synchronized(self) {
        if (!evidence || !self.armed || self.generation != generation || [evidence[@"generation"] unsignedIntegerValue] != generation) return NO;
        strict = self.newMessagesOnly;
    }
    if (!strict) return YES;
    NSNumber *created = evidence[@"createdAt"];
    if (![created isKindOfClass:NSNumber.class] ||
        !SROpsNewMessage(created.doubleValue, [evidence[@"listeningSince"] doubleValue], [evidence[@"receivedAt"] doubleValue]) ||
        [evidence[@"receivedAt"] doubleValue] > [self observationTime]) {
        [self note:@"source_time_rejected"]; return NO;
    }
    if (![SRReadDeclaredUnsignedInteger(wrap, @"m_uiCreateTime") isEqual:created]) {
        [self note:@"source_time_changed"]; return NO;
    }
    return YES;
}
- (void)deliverMessage:(NSDictionary *)message timeEvidence:(NSDictionary *)evidence {
    if (self.receivedWithTimeEvidence) self.receivedWithTimeEvidence(message, evidence);
    else self.received(message);
}
- (BOOL)fail:(NSString *)reason error:(NSError **)error {
    @synchronized(self) { self.problem = reason; }
    if (error) *error = [NSError errorWithDomain:@"SyncRelay.Receiver" code:1 userInfo:@{NSLocalizedDescriptionKey: reason}];
    return NO;
}
- (void)note:(NSString *)event {
    BOOL first;
    @synchronized(self) {
        if (!self.counters) self.counters = [NSMutableDictionary dictionary];
        NSUInteger count = [self.counters[event] unsignedIntegerValue]; first = count == 0;
        self.counters[event] = @(count == NSUIntegerMax ? count : count + 1);
        self.lastCallbackAt = NSDate.date.timeIntervalSince1970;
    }
    if (first) @try { if (self.trace) self.trace(event, @{}); } @catch (__unused id exception) { }
}
- (SRDirectionObservation *)beginDirectionForSession:(id)session wrap:(id)wrap {
    NSString *account, *group; NSUInteger generation;
    @synchronized(self) {
        if (!self.armed || ![session isKindOfClass:NSString.class] || ![session isEqual:self.group]) return nil;
        if (self.directionReservations >= 12) {
            if (self.directionDropped < NSUIntegerMax) self.directionDropped++;
            return nil;
        }
        self.directionReservations++; account = self.account; group = self.group; generation = self.generation;
    }
    SRDirectionObservation *observation = [[SRDirectionObservation alloc] init];
    observation.owner = self; observation.generation = generation;
    observation.before = SRDirectionSnapshot(wrap, self.resolver(@"CMessageWrap"), account, group);
    return observation;
}
- (void)finishDirection:(SRDirectionObservation *)observation path:(NSString *)path wrap:(id)wrap {
    if (!observation || observation.owner != self) return;
    NSString *account, *group;
    @synchronized(self) {
        if (!self.armed || self.generation != observation.generation) return;
        account = self.account; group = self.group;
    }
    NSDictionary *after = SRDirectionSnapshot(wrap, self.resolver(@"CMessageWrap"), account, group);
    @synchronized(self) {
        if (!self.armed || self.generation != observation.generation) return;
        [self.directionSamples addObject:@{@"path": path, @"time": @(NSDate.date.timeIntervalSince1970),
            @"before": observation.before, @"after": after}];
    }
}
- (BOOL)armForAccount:(NSString *)account sourceGroup:(NSString *)group error:(NSError **)error {
    if (!NSThread.isMainThread) return [self fail:@"Receive capture must be armed on the main thread" error:error];
    if (![@[@"8.0.76", @"8.0.79"] containsObject:self.version]) return [self fail:@"This version has no receive candidate" error:error];
    if (!account.length || [account hasSuffix:@"@chatroom"] || ![group hasSuffix:@"@chatroom"])
        return [self fail:@"A stable account and source group are required" error:error];
    @synchronized(self) { if (self.armed) return [self fail:@"Stop the current capture before arming again" error:error]; }
    @try { if (![self.currentAccount() isEqual:account]) return [self fail:@"Account changed before capture" error:error]; }
    @catch (__unused id exception) { return [self fail:@"Cannot verify the current account" error:error]; }
    Class manager = self.resolver(@"CMessageMgr"); SEL selector = NSSelectorFromString(@"AsyncOnAddMsg:MsgWrap:");
    Method method = manager ? class_getInstanceMethod(manager, selector) : NULL;
    if (!SRReceiveSignature(method)) return [self fail:@"Receive entry is absent or is not void(object, object)" error:error];
    Class wrapClass = self.resolver(@"CMessageWrap");
    for (NSString *name in @[@"m_nsFromUsr", @"m_nsToUsr", @"m_nsRealChatUsr", @"m_nsContent"])
        if (!SRReceiveGetter(wrapClass, name, NO)) return [self fail:@"Message string getters are absent or incompatible" error:error];
    for (NSString *name in @[@"m_uiMessageType", @"m_n64MesSvrID"])
        if (!SRReceiveGetter(wrapClass, name, YES)) return [self fail:@"Message integer getters are absent or incompatible" error:error];
    @synchronized(SRTaps()) {
        NSValue *key = [NSValue valueWithPointer:(__bridge const void *)manager];
        SRReceiveTap *tap = SRTaps()[key];
        if (tap.listener && tap.listener != self) return [self fail:@"Another receiver owns this capture entry" error:error];
        if (!tap) {
            tap = [[SRReceiveTap alloc] init]; tap.original = method_getImplementation(method);
            SRReceiveTap *installed = tap;
            IMP replacement = imp_implementationWithBlock(^(id object, id session, id wrap) {
                SRWeChatReceiver *listener = installed.listener;
                SRDirectionObservation *observation = nil;
                NSDictionary *evidence = nil;
                NSDictionary *timeHook = nil;
                @try {
                    evidence = [listener beginTimeEvidenceForSession:session wrap:wrap];
                    timeHook = [listener beginTimeHookForSession:session wrap:wrap evidence:evidence];
                    observation = [listener beginDirectionForSession:session wrap:wrap];
                } @catch (__unused id exception) { }
                ((void (*)(id, SEL, id, id))installed.original)(object, selector, session, wrap);
                @try { if (installed.listener == listener) [listener finishTimeHook:timeHook path:@"receive"]; } @catch (__unused id exception) { }
                // Never let optional observation exceptions change WeChat's receive behavior.
                @try { [installed.listener finishDirection:observation path:@"receive" wrap:wrap]; } @catch (__unused id exception) { }
                @try { if (installed.listener == listener) [listener observeSession:session wrap:wrap timeEvidence:evidence]; } @catch (__unused id exception) { }
            });
            if (!class_addMethod(manager, selector, replacement, method_getTypeEncoding(method)))
                tap.original = method_setImplementation(class_getInstanceMethod(manager, selector), replacement);
            SRTaps()[key] = tap;
        }
        @synchronized(self) {
            self.account = account; self.group = group; self.problem = nil; self.generation++;
            self.counters = [NSMutableDictionary dictionary]; self.armedAt = [self observationTime]; self.lastCallbackAt = 0;
            self.directionSamples = [NSMutableArray array]; self.directionReservations = 0; self.directionDropped = 0;
            self.pendingOutgoing = nil; self.queuedOutgoing = 0; self.ownTextState = @"unavailable";
            self.senderIDs = nil; self.selectedTypes = [NSSet setWithObject:@"text"];
            self.observedMessageTypes = [NSMutableDictionary dictionary];
            self.observedMessageTypeSequence = [NSMutableArray array];
            self.appMessageSamples = [NSMutableArray array]; self.appMessageReservations = 0; self.appMessageDropped = 0;
            self.pendingImage = nil; self.imageState = @"disabled"; self.imageReads = 0; self.queuedImages = 0;
            self.imagePreparationCode = 0;
            self.newMessagesOnly = NO;
            self.tap = tap; self.armed = YES; tap.listener = self;
        }
        // Optional outgoing observation. Never invoke AddMsg ourselves.
        SEL outgoingSelector = NSSelectorFromString(@"AddMsg:MsgWrap:");
        Method outgoingMethod = class_getInstanceMethod(manager, outgoingSelector);
        if (SRReceiveSignature(outgoingMethod)) {
            NSString *outgoingKey = [NSString stringWithFormat:@"%p:AddMsg", manager];
            SRReceiveTap *outgoing = SRTaps()[outgoingKey];
            if (!outgoing) {
                outgoing = [[SRReceiveTap alloc] init]; outgoing.original = method_getImplementation(outgoingMethod);
                SRReceiveTap *installed = outgoing;
                IMP replacement = imp_implementationWithBlock(^(id object, id session, id wrap) {
                    SRWeChatReceiver *listener = installed.listener;
                    SRDirectionObservation *observation = nil;
                    NSDictionary *evidence = nil;
                    NSDictionary *timeHook = nil;
                    @try {
                        evidence = [listener beginTimeEvidenceForSession:session wrap:wrap];
                        timeHook = [listener beginTimeHookForSession:session wrap:wrap evidence:evidence];
                        observation = [listener beginDirectionForSession:session wrap:wrap];
                    } @catch (__unused id exception) { }
                    ((void (*)(id, SEL, id, id))installed.original)(object, outgoingSelector, session, wrap);
                    @try { if (installed.listener == listener) [listener finishTimeHook:timeHook path:@"outgoing"]; } @catch (__unused id exception) { }
                    @try { [installed.listener finishDirection:observation path:@"outgoing" wrap:wrap]; } @catch (__unused id exception) { }
                    @try { if (installed.listener == listener) [listener observeOutgoingManager:object session:session wrap:wrap timeEvidence:evidence]; } @catch (__unused id exception) { }
                });
                if (!class_addMethod(manager, outgoingSelector, replacement, method_getTypeEncoding(outgoingMethod)))
                    outgoing.original = method_setImplementation(class_getInstanceMethod(manager, outgoingSelector), replacement);
                SRTaps()[outgoingKey] = outgoing;
            }
            if (!outgoing.listener || outgoing.listener == self) {
                self.outgoingTap = outgoing; outgoing.listener = self; self.ownTextState = @"waiting";
            }
        }
    }
    [self note:@"receiver_arm"];
    return YES;
}
- (BOOL)armForAccount:(NSString *)account configuration:(NSDictionary *)configuration error:(NSError **)error {
    return [self armForAccount:account configuration:configuration newMessagesOnly:NO error:error];
}
- (BOOL)armForAccount:(NSString *)account configuration:(NSDictionary *)configuration newMessagesOnly:(BOOL)newMessagesOnly error:(NSError **)error {
    if (![SRConfiguration validateDraft:configuration error:NULL] || ![configuration[@"senders"] count])
        return [self fail:@"Capture requires validated sender and type filters" error:error];
    if ([configuration[@"types"] containsObject:@"image"] && (!self.prepareImage || !self.discardImage))
        return [self fail:@"Image snapshot preparation is unavailable" error:error];
    if (newMessagesOnly && (!self.receivedWithTimeEvidence ||
        !SRReceiveTimeGetter(self.resolver(@"CMessageWrap")) || [self observationTime] <= 0))
        return [self fail:@"A declared creation-time getter, valid clock and evidence callback are required" error:error];
    if (![self armForAccount:account sourceGroup:configuration[@"sourceGroup"][@"id"] error:error]) return NO;
    @synchronized(self) {
        self.senderIDs = [NSSet setWithArray:[configuration[@"senders"] valueForKey:@"id"]];
        self.selectedTypes = [NSSet setWithArray:configuration[@"types"]];
        self.imageState = [self.selectedTypes containsObject:@"image"] ? @"waiting" : @"disabled";
        self.newMessagesOnly = newMessagesOnly;
    }
    return YES;
}
- (BOOL)allowsSender:(NSString *)sender type:(NSNumber *)type {
    @synchronized(self) {
        if (self.senderIDs && ![self.senderIDs containsObject:sender]) { [self note:@"receive_sender_filtered"]; return NO; }
        NSString *name = [type isEqual:@1] ? @"text" : ([type isEqual:@3] ? @"image" : @"unsupported");
        if (![self.selectedTypes containsObject:name]) { [self note:@"receive_type_filtered"]; return NO; }
        return YES;
    }
}
- (void)observeSession:(id)session wrap:(id)wrap timeEvidence:(NSDictionary *)evidence {
    NSString *account, *group; NSUInteger generation;
    @synchronized(self) {
        if (!self.armed) return;
        account = self.account; group = self.group; generation = self.generation;
    }
    [self note:@"receive_callback"];
    if (![session isKindOfClass:NSString.class] || ![session isEqual:group]) { [self note:@"receive_wrong_session"]; return; }
    NSString *from = SRReadDeclaredString(wrap, @"m_nsFromUsr", NULL), *to = SRReadDeclaredString(wrap, @"m_nsToUsr", NULL);
    NSString *sender = SRReadDeclaredString(wrap, @"m_nsRealChatUsr", NULL);
    BOOL outgoing = [from isEqual:account] && [to isEqual:group];
    if (outgoing) {
        if (sender.length && ![sender isEqual:account]) { [self note:@"receive_invalid_sender"]; return; }
        sender = account;
    }
    if (!outgoing && (![from isEqual:group] || ![to isEqual:account])) { [self note:@"receive_wrong_direction"]; return; }
    if (!sender.length ||
        [sender hasSuffix:@"@chatroom"] ||
        [sender rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) { [self note:@"receive_invalid_sender"]; return; }
    NSNumber *type = SRReadUnsignedInteger(wrap, @"m_uiMessageType", NULL);
    NSNumber *serverID = SRReadUnsignedInteger(wrap, @"m_n64MesSvrID", NULL);
    [self observeMessageType:type];
    if ([type isEqual:@49]) [self observeAppMessageWrap:wrap sender:sender from:from to:to timeEvidence:evidence generation:generation];
    // The source-time probe has already consumed bounded text/image metadata
    // in the original hook path. Delivery remains restricted to the normal
    // filters; early type-3 callbacks without a server ID cannot prepare media.
    if (![self allowsSender:sender type:type]) return;
    if (!serverID.unsignedLongLongValue) { [self note:@"receive_no_server_id"]; return; }
    if (![self acceptsTimeEvidence:evidence wrap:wrap generation:generation]) return;
    if ([type isEqual:@3]) {
        NSDictionary *identity = @{@"account": account, @"group": group, @"sender": sender,
            @"messageID": [@"svr:" stringByAppendingString:serverID.stringValue], @"type": @"image", @"generatedByRelay": @NO};
        @synchronized(self) {
            if (self.pendingImage || self.queuedImages) return;
            self.queuedImages++;
        }
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            SRWeChatReceiver *receiver = weakSelf; if (!receiver) return;
            @synchronized(receiver) {
                if (!receiver.armed || receiver.generation != generation) return;
                receiver.queuedImages--;
                if (receiver.pendingImage) return;
                SRPendingImage *pending = [[SRPendingImage alloc] init]; pending.wrap = wrap; pending.source = identity;
                pending.timeEvidence = evidence;
                pending.deadline = NSProcessInfo.processInfo.systemUptime + 30;
                receiver.pendingImage = pending; receiver.imageState = @"awaiting_native_image";
            }
            [receiver note:@"image_pending"];
            [receiver pollImage:receiver.pendingImage generation:generation remaining:30];
        });
        return;
    }
    @synchronized(self) { if (self.pendingImage || self.queuedImages) return; }
    NSString *content = SRReadDeclaredString(wrap, @"m_nsContent", NULL);
    if (!content.length) { [self note:@"receive_empty_text"]; return; }
    NSDictionary *message = [SRSourceMessage frozenJSON:@{@"account": account, @"group": group, @"sender": sender,
        @"messageID": [@"svr:" stringByAppendingString:serverID.stringValue], @"type": @"text",
        @"generatedByRelay": @NO, @"payload": @{@"text": content}}];
    if (!message) return;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        SRWeChatReceiver *receiver = weakSelf; if (!receiver) return;
        @synchronized(receiver) { if (!receiver.armed || receiver.generation != generation) return; }
        @try {
            if (![receiver.currentAccount() isEqual:account]) {
                [receiver note:@"account_changed"];
                [receiver stop]; [receiver fail:@"Account changed; receive capture stopped" error:NULL]; return;
            }
            @synchronized(receiver) { if (!receiver.armed || receiver.generation != generation) return; }
            if (![receiver acceptsTimeEvidence:evidence wrap:wrap generation:generation]) return;
            [receiver note:@"source_candidate"]; [receiver deliverMessage:message timeEvidence:evidence];
        } @catch (__unused id exception) {
            [receiver stop]; [receiver fail:@"Receive callback failed; capture stopped" error:NULL];
        }
    });
}
- (void)observeMessageType:(NSNumber *)type {
    if (![type isKindOfClass:NSNumber.class] || type.unsignedLongLongValue > UINT32_MAX) return;
    @synchronized(self) {
        if (!self.observedMessageTypes) self.observedMessageTypes = [NSMutableDictionary dictionary];
        if (!self.observedMessageTypeSequence) self.observedMessageTypeSequence = [NSMutableArray array];
        /* Keep diagnostics bounded even if a host emits malformed values. */
        NSString *key = type.stringValue;
        if (!self.observedMessageTypes[key] && self.observedMessageTypes.count >= 32) return;
        NSUInteger count = [self.observedMessageTypes[key] unsignedIntegerValue];
        self.observedMessageTypes[key] = @(count == NSUIntegerMax ? count : count + 1);
        /* The order is numeric only, so one device run can correlate each
         * sent fixture with a callback without retaining message content. */
        if (self.observedMessageTypeSequence.count < 64) [self.observedMessageTypeSequence addObject:type];
    }
}
- (void)observeAppMessageWrap:(id)wrap sender:(NSString *)sender from:(NSString *)from to:(NSString *)to
    timeEvidence:(NSDictionary *)evidence generation:(NSUInteger)generation {
    NSString *account, *group;
    @synchronized(self) {
        // The numeric probe remains body-free for unselected senders and legacy arms.
        if (!self.armed || self.observeTimeHook || self.generation != generation || ![self.senderIDs containsObject:sender]) return;
        if (self.appMessageReservations >= SRAppMessageSampleLimit) {
            if (self.appMessageDropped < NSUIntegerMax) self.appMessageDropped++;
            return;
        }
        self.appMessageReservations++; account = self.account; group = self.group;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        SRWeChatReceiver *receiver = weakSelf; if (!receiver) return;
        @synchronized(receiver) { if (!receiver.armed || receiver.generation != generation) return; }
        @try {
            if (![receiver.currentAccount() isEqual:account]) return;
            BOOL (^identityMatches)(void) = ^BOOL {
                if (![SRReadDeclaredString(wrap, @"m_nsFromUsr", NULL) isEqual:from] ||
                    ![SRReadDeclaredString(wrap, @"m_nsToUsr", NULL) isEqual:to] ||
                    ![SRReadUnsignedInteger(wrap, @"m_uiMessageType", NULL) isEqual:@49]) return NO;
                NSString *currentSender = SRReadDeclaredString(wrap, @"m_nsRealChatUsr", NULL);
                if (!currentSender.length && [from isEqual:account] && [to isEqual:group]) currentSender = account;
                return [currentSender isEqual:sender];
            };
            if (!identityMatches() || ![receiver acceptsTimeEvidence:evidence wrap:wrap generation:generation]) return;
            @synchronized(receiver) { if (!receiver.armed || receiver.generation != generation) return; }
            SRStringReadState state;
            NSString *content = SRReadDeclaredString(wrap, @"m_nsContent", &state);
            NSDictionary *sample = content ? [SRAppMessageXMLProbe summaryForContent:content sender:sender] :
                @{@"state": @"content_unavailable", @"getterState": @(state)};
            if (![receiver.currentAccount() isEqual:account] || !identityMatches() ||
                ![receiver acceptsTimeEvidence:evidence wrap:wrap generation:generation]) return;
            @synchronized(receiver) {
                if (!receiver.armed || receiver.generation != generation) return;
                [receiver.appMessageSamples addObject:sample];
            }
        } @catch (__unused id exception) { /* Optional diagnostics cannot stop capture or alter the host chain. */ }
    });
}
- (void)observeOutgoingManager:(id)manager session:(id)session wrap:(id)wrap timeEvidence:(NSDictionary *)evidence {
    NSString *account, *group; NSUInteger generation;
    @synchronized(self) {
        if (!self.armed) return;
        account = self.account; group = self.group; generation = self.generation;
    }
    [self note:@"outgoing_callback"];
    if (![session isKindOfClass:NSString.class] || ![session isEqual:group]) { [self note:@"outgoing_wrong_session"]; return; }
    if (![SRReadDeclaredString(wrap, @"m_nsFromUsr", NULL) isEqual:account] || ![SRReadDeclaredString(wrap, @"m_nsToUsr", NULL) isEqual:group]) {
        [self note:@"outgoing_wrong_direction"]; return;
    }
    NSNumber *type = SRReadUnsignedInteger(wrap, @"m_uiMessageType", NULL);
    if ([type isEqual:@49]) {
        [self observeMessageType:type];
        [self observeAppMessageWrap:wrap sender:account from:account to:group timeEvidence:evidence generation:generation];
    }
    if (![self allowsSender:account type:type]) return;
    if (![self acceptsTimeEvidence:evidence wrap:wrap generation:generation]) return;
    NSString *text = [type isEqual:@1] ? [SRReadDeclaredString(wrap, @"m_nsContent", NULL) copy] : nil;
    if ([type isEqual:@1] && !text.length) return;
    SRPendingOwnText *pending = [[SRPendingOwnText alloc] init];
    pending.wrap = wrap; pending.manager = manager; pending.text = text;
    pending.timeEvidence = evidence;
    pending.messageType = type;
    pending.localID = SRReadUnsignedInteger(wrap, @"m_uiMesLocalID", NULL);
    @synchronized(self) {
        if (!self.armed || self.generation != generation || self.pendingOutgoing || self.queuedOutgoing >= 16) return;
        self.queuedOutgoing++;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        SRWeChatReceiver *receiver = weakSelf;
        if (!receiver) return;
        @synchronized(receiver) {
            if (!receiver.armed || receiver.generation != generation) return;
            receiver.queuedOutgoing--;
            if (receiver.pendingOutgoing) return;
            receiver.pendingOutgoing = pending; receiver.ownTextState = @"awaiting_server_id";
        }
        [receiver note:@"own_pending"];
        [receiver pollOutgoing:pending group:group account:account generation:generation remaining:30];
    });
}
- (BOOL)ownWrap:(id)wrap matchesPending:(SRPendingOwnText *)pending group:(NSString *)group account:(NSString *)account {
    NSString *sender = SRReadDeclaredString(wrap, @"m_nsRealChatUsr", NULL);
    return [SRReadDeclaredString(wrap, @"m_nsFromUsr", NULL) isEqual:account] && [SRReadDeclaredString(wrap, @"m_nsToUsr", NULL) isEqual:group] &&
        (![pending.messageType isEqual:@1] || [SRReadDeclaredString(wrap, @"m_nsContent", NULL) isEqual:pending.text]) && (!sender.length || [sender isEqual:account]) &&
        [SRReadUnsignedInteger(wrap, @"m_uiMessageType", NULL) isEqual:pending.messageType] &&
        (!pending.localID.unsignedLongLongValue || [SRReadUnsignedInteger(wrap, @"m_uiMesLocalID", NULL) isEqual:pending.localID]);
}
- (void)pollOutgoing:(SRPendingOwnText *)pending group:(NSString *)group account:(NSString *)account generation:(NSUInteger)generation remaining:(NSUInteger)remaining {
    @synchronized(self) { if (!self.armed || self.generation != generation || self.pendingOutgoing != pending) return; }
    @try {
        if (![self.currentAccount() isEqual:account]) { [self note:@"account_changed"]; [self stop]; return; }
        if (![self ownWrap:pending.wrap matchesPending:pending group:group account:account] ||
            ![self acceptsTimeEvidence:pending.timeEvidence wrap:pending.wrap generation:generation]) {
            self.pendingOutgoing = nil; self.ownTextState = @"conflict";
            [self note:@"own_conflict"];
            [self fail:@"Own message fields changed; no source was captured" error:NULL]; return;
        }
        id wrap = pending.wrap;
        // Some hosts replace the wrap after sending. Only read back its exact, observed local ID.
        if (!SRReadUnsignedInteger(wrap, @"m_n64MesSvrID", NULL).unsignedLongLongValue && pending.localID.unsignedLongLongValue) {
            id stored = SRReadObjectWithObjectAndUnsignedInteger(pending.manager, @"GetMsg:LocalID:", group, pending.localID, NULL);
            [self note:@"own_readback"];
            if (stored && [self ownWrap:stored matchesPending:pending group:group account:account]) {
                if (![self acceptsTimeEvidence:pending.timeEvidence wrap:stored generation:generation]) {
                    self.pendingOutgoing = nil; self.ownTextState = @"conflict"; [self note:@"own_conflict"]; return;
                }
                // Keep the exact local ID in-process so the source-time probe can
                // correlate this settled readback with its earlier anonymous hook.
                // It is never written to diagnostics.
                NSMutableDictionary *correlated = [pending.timeEvidence mutableCopy];
                @synchronized(self) {
                    if (self.armed && self.generation == generation && self.observeTimeHook &&
                        self.counters[@"time_hook_reserved"])
                        correlated[@"correlationLocalID"] = pending.localID;
                }
                pending.timeEvidence = correlated;
                wrap = stored;
            }
        }
        if (SRReadUnsignedInteger(wrap, @"m_n64MesSvrID", NULL).unsignedLongLongValue) {
            if (![self.currentAccount() isEqual:account]) { [self stop]; return; }
            [self observeSession:group wrap:wrap timeEvidence:pending.timeEvidence]; self.pendingOutgoing = nil; self.ownTextState = @"source_candidate"; return;
        }
        if (!remaining) {
            self.pendingOutgoing = nil; self.ownTextState = @"timed_out";
            [self note:@"own_timeout"];
            [self fail:@"Own message has no server message ID after 30 seconds; no source was captured" error:NULL]; return;
        }
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [weakSelf pollOutgoing:pending group:group account:account generation:generation remaining:remaining - 1];
        });
    } @catch (__unused id exception) {
        self.pendingOutgoing = nil; self.ownTextState = @"error"; [self fail:@"Own message observation failed" error:NULL];
    }
}
- (BOOL)imageWrap:(id)wrap matches:(NSDictionary *)source {
    NSString *from = SRReadDeclaredString(wrap, @"m_nsFromUsr", NULL), *to = SRReadDeclaredString(wrap, @"m_nsToUsr", NULL);
    NSString *sender = SRReadDeclaredString(wrap, @"m_nsRealChatUsr", NULL);
    BOOL outgoing = [from isEqual:source[@"account"]] && [to isEqual:source[@"group"]];
    if (outgoing && (!sender.length || [sender isEqual:source[@"account"]])) sender = source[@"account"];
    NSNumber *server = SRReadUnsignedInteger(wrap, @"m_n64MesSvrID", NULL);
    return (outgoing || ([from isEqual:source[@"group"]] && [to isEqual:source[@"account"]])) &&
        [sender isEqual:source[@"sender"]] && [SRReadUnsignedInteger(wrap, @"m_uiMessageType", NULL) isEqual:@3] &&
        server.unsignedLongLongValue && [[@"svr:" stringByAppendingString:server.stringValue] isEqual:source[@"messageID"]];
}
- (void)pollImage:(SRPendingImage *)pending generation:(NSUInteger)generation remaining:(NSUInteger)remaining {
    @synchronized(self) { if (!self.armed || self.generation != generation || self.pendingImage != pending) return; }
    NSDictionary *payload = nil;
    BOOL offered = NO;
    @try {
        if (![self.currentAccount() isEqual:pending.source[@"account"]]) { [self note:@"account_changed"]; [self stop]; return; }
        if (![self imageWrap:pending.wrap matches:pending.source]) {
            self.imageState = @"identity_conflict"; [self note:@"image_conflict"]; [self stop]; return;
        }
        if (![self acceptsTimeEvidence:pending.timeEvidence wrap:pending.wrap generation:generation]) {
            self.imageState = @"time_unverified"; [self stop]; return;
        }
        if (!remaining || NSProcessInfo.processInfo.systemUptime >= pending.deadline) {
            self.imageState = @"timed_out"; [self note:@"image_timeout"]; [self stop];
            [self fail:@"Image not available after 30 seconds. Open it in the source group, then arm capture and send a new image" error:NULL]; return;
        }
        @synchronized(self) { if (!self.armed || self.generation != generation || self.pendingImage != pending) return; }
        NSError *error = nil; self.imageReads++;
        payload = self.prepareImage ? self.prepareImage(pending.wrap, pending.source, &error) : nil;
        @synchronized(self) {
            if (!self.armed || self.generation != generation || self.pendingImage != pending) {
                if (payload && self.discardImage) self.discardImage(payload);
                return;
            }
        }
        if (error || (payload && ![SRImageAssetStore validPayload:payload])) {
            self.imagePreparationCode = [error.domain isEqual:@"SyncRelay.ImageSource"] ? 101 :
                ([error.domain isEqual:@"SyncRelay.ImageAsset"] && error.code >= 1 && error.code <= 8 ? (NSUInteger)error.code : 9);
            if (payload && self.discardImage) self.discardImage(payload);
            self.imageState = @"preparation_failed"; [self note:@"image_failed"]; [self stop];
            [self fail:@"Image preparation failed; export diagnostics. No message was sent" error:NULL]; return;
        }
        // Native preparation may reenter host code. Recheck ownership and all source fields.
        BOOL live;
        @synchronized(self) { live = self.armed && self.generation == generation && self.pendingImage == pending; }
        BOOL identityMatches = live && [self.currentAccount() isEqual:pending.source[@"account"]] &&
            [self imageWrap:pending.wrap matches:pending.source] && [self acceptsTimeEvidence:pending.timeEvidence wrap:pending.wrap generation:generation];
        @synchronized(self) { live = self.armed && self.generation == generation && self.pendingImage == pending; }
        if (!live || !identityMatches) {
            if (payload && self.discardImage) self.discardImage(payload);
            if (live) { self.imageState = @"identity_conflict"; [self note:@"image_conflict"]; [self stop]; }
            return;
        }
        if (payload) {
            NSMutableDictionary *message = [pending.source mutableCopy]; message[@"payload"] = payload;
            self.pendingImage = nil; self.imageState = @"snapshot_ready"; [self note:@"image_ready"];
            offered = YES;
            [self note:@"source_candidate"]; [self deliverMessage:[SRSourceMessage frozenJSON:message] timeEvidence:pending.timeEvidence]; return;
        }
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [weakSelf pollImage:pending generation:generation remaining:remaining - 1];
        });
    } @catch (__unused id exception) {
        // The consumer may have durably retained the asset before throwing.
        if (payload && !offered && self.discardImage) self.discardImage(payload);
        self.imagePreparationCode = 10; self.imageState = @"preparation_failed"; [self note:@"image_failed"]; [self stop];
        [self fail:@"Image observation failed; export diagnostics" error:NULL];
    }
}
- (void)stop {
    BOOL wasArmed;
    @synchronized(SRTaps()) {
        @synchronized(self) {
            wasArmed = self.armed;
            self.armed = NO; self.generation++;
            if (self.tap.listener == self) self.tap.listener = nil;
            if (self.outgoingTap.listener == self) self.outgoingTap.listener = nil;
            self.pendingOutgoing = nil;
            self.pendingImage = nil; self.queuedImages = 0;
            self.queuedOutgoing = 0;
            self.account = nil; self.group = nil;
        }
    }
    if (wasArmed) [self note:@"receiver_stopped"];
}
- (NSDictionary *)diagnostics {
    @synchronized(self) {
        Class manager = self.resolver(@"CMessageMgr"), wrap = self.resolver(@"CMessageWrap");
        NSMutableArray *methods = [NSMutableArray arrayWithObject:SRDescribeInstanceMethod(manager, @"AsyncOnAddMsg:MsgWrap:")];
        [methods addObject:SRDescribeInstanceMethod(manager, @"AddMsg:MsgWrap:")];
        [methods addObject:SRDescribeInstanceMethod(manager, @"GetMsg:LocalID:")];
        for (NSString *name in @[@"m_nsFromUsr", @"m_nsToUsr", @"m_nsRealChatUsr", @"m_uiMessageType", @"m_n64MesSvrID", @"m_nsContent", @"m_uiMesLocalID", @"m_uiCreateTime"])
            [methods addObject:SRDescribeInstanceMethod(wrap, name)];
        return @{@"wechatVersion": self.version, @"armed": @(self.armed), @"installed": @(self.tap != nil),
            @"ownTextHookAvailable": @(self.outgoingTap != nil), @"ownTextPending": @(self.pendingOutgoing != nil),
            @"ownTextState": self.ownTextState ?: @"idle",
            @"armedAt": @(self.armedAt), @"lastEventAt": @(self.lastCallbackAt), @"counters": [self.counters copy] ?: @{},
            @"directionEvidenceSchema": @2, @"stringReadStrategy": @"declared_runtime", @"directionSampleLimit": @12,
            @"directionSamples": [self.directionSamples copy] ?: @[],
            @"directionSamplesDropped": @(self.directionDropped),
            @"messageTypeProbe": SRMessageTypeProbeSnapshot(self.observedMessageTypes ?: @{}, [self.observedMessageTypeSequence copy] ?: @[]),
            @"appMessageProbe": @{@"schema": @1, @"observerOnly": @YES, @"relayable": @NO, @"deviceVerified": @NO,
                @"limit": @(SRAppMessageSampleLimit), @"byteLimit": @(SRAppMessageByteLimit),
                @"attempts": @(self.appMessageReservations), @"dropped": @(self.appMessageDropped),
                @"samples": [self.appMessageSamples copy] ?: @[]},
            @"textOnlyCandidate": @(![self.selectedTypes containsObject:@"image"]), @"imageCaptureSchema": @1, @"imageState": self.imageState ?: @"idle",
            @"imagePending": @(self.pendingImage != nil), @"imageReads": @(self.imageReads), @"imageWaitLimit": @30,
            @"imagePreparationCode": @(self.imagePreparationCode),
            @"sourceTimeEvidenceSchema": @1, @"newMessagesOnly": @(self.newMessagesOnly),
            @"receiverGeneration": @(self.generation),
            @"creationTimeGetterABICompatible": @(SRReceiveTimeGetter(wrap)), @"sourceTimeSemanticsVerified": @NO,
            @"senderFilterCount": @(self.senderIDs.count), @"sendingEnabled": @NO, @"problem": self.problem ?: @"", @"methods": methods};
    }
}
@end
