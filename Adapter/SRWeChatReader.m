#import "SRWeChatReader.h"
#import "SRRuntime.h"

@interface SRWeChatReader ()
@property(nonatomic, copy, nullable) NSString *accountID;
@property(nonatomic, copy) NSString *version;
@property(nonatomic, copy) NSArray<NSString *> *warnings;
@property(nonatomic, copy) Class (^resolver)(NSString *);
@property(nonatomic, strong) id manager;
@property(nonatomic, strong) id center;
@property(nonatomic, copy) NSDictionary *groupRead;
@end

@implementation SRWeChatReader
- (instancetype)initWithVersion:(NSString *)version classResolver:(Class (^)(NSString *))resolver {
    self = [super init];
    if (self) { _version = [version copy]; _resolver = [resolver copy]; _warnings = @[]; _groupRead = @{ @"state": @"not_read" }; }
    return self;
}
- (BOOL)fail:(NSString *)message error:(NSError **)error {
    if (error) *error = [NSError errorWithDomain:@"SyncRelay.Reader" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}
- (BOOL)connect:(NSError **)error {
    if (!NSThread.isMainThread) return [self fail:@"请在主线程读取微信联系人" error:error];
    NSString *previousAccount = self.accountID;
    self.manager = nil;
    self.center = nil;
    self.accountID = nil;
    self.warnings = @[];
    if (![@[@"8.0.76", @"8.0.79"] containsObject:self.version]) return [self fail:@"此微信版本尚未纳入读取适配，请先导出诊断" error:error];
    Class centerClass = self.resolver(@"MMServiceCenter");
    Class managerClass = self.resolver(@"CContactMgr");
    if (!centerClass || !managerClass) return [self fail:@"联系人服务尚不可用，请登录微信后重试" error:error];
    id center = SRReadObject(centerClass, @"defaultCenter", @[], error);
    id manager = center ? SRReadObject(center, @"getService:", @[managerClass], error) : nil;
    if (!manager) return [self fail:@"无法取得微信联系人服务" error:error];
    id myself = SRReadObject(manager, @"getSelfContact", @[], error);
    NSString *account = SRReadString(myself, @"m_nsUsrName");
    if (!account.length) return [self fail:@"无法读取当前账号 wxid；不会按昵称代替" error:error];
    self.manager = manager;
    self.center = center;
    self.accountID = account;
    if (![previousAccount isEqual:account]) self.groupRead = @{ @"state": @"not_read" };
    return YES;
}
- (BOOL)verifyAccount:(NSString *)account error:(NSError **)error {
    if (![self connect:error]) return NO;
    if (![self.accountID isEqual:account]) return [self fail:@"微信账号已改变，请重新载入配置，当前选择未保存" error:error];
    return YES;
}
- (NSDictionary *)rowForContact:(id)contact fallbackID:(NSString *)fallback {
    NSString *identifier = SRReadString(contact, @"m_nsUsrName");
    if (!identifier.length) identifier = fallback;
    if (!identifier.length) return nil;
    NSString *name = SRReadString(contact, @"m_nsNickName");
    return @{@"id": [identifier copy], @"name": [(name.length ? name : identifier) copy]};
}
- (NSArray *)orderedRows:(NSDictionary<NSString *, NSDictionary *> *)rows {
    return [rows.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult result = [a[@"name"] localizedStandardCompare:b[@"name"]];
        return result == NSOrderedSame ? [a[@"id"] compare:b[@"id"]] : result;
    }];
}
- (NSArray *)groups:(NSError **)error {
    NSString *account = self.accountID;
    if (!account || ![self verifyAccount:account error:error]) return nil;
    // Keep the observed (1, 0) arguments; supplement the partial list with local sessions.
    id result = SRReadObjectWithIntegers(self.manager, @"getContactList:contactType:", @[@1, @0], NULL);
    NSArray *contacts = [result isKindOfClass:NSArray.class] ? result : nil;
    Class sessionsClass = self.resolver(@"MMNewSessionMgr");
    id sessionsManager = sessionsClass ? SRReadObject(self.center, @"getService:", @[sessionsClass], NULL) : nil;
    id sessionResult = SRReadObject(sessionsManager, @"GetUserNamesOnSessionList", @[], NULL);
    NSArray *sessions = [sessionResult isKindOfClass:NSArray.class] ? sessionResult :
        ([sessionResult isKindOfClass:NSSet.class] ? [sessionResult allObjects] : nil);
    NSString *sessionState = !sessionsClass ? @"class_missing" : (!sessionsManager ? @"service_unavailable" :
        (sessions ? @"ok" : @"incompatible_or_unexpected_result"));
    NSMutableDictionary *rows = [NSMutableDictionary dictionary];
    NSMutableSet *contactGroups = [NSMutableSet set], *sessionGroups = [NSMutableSet set];
    NSUInteger unresolved = 0, invalidSessions = 0;
    for (id contact in contacts) {
        NSDictionary *row = [self rowForContact:contact fallbackID:nil];
        if ([self isGroupID:row[@"id"]]) { rows[row[@"id"]] = row; [contactGroups addObject:row[@"id"]]; }
    }
    for (id identifier in sessions) {
        if (![identifier isKindOfClass:NSString.class]) { invalidSessions++; continue; }
        if (![self isGroupID:identifier]) continue;
        if ([sessionGroups containsObject:identifier]) continue;
        [sessionGroups addObject:identifier];
        if (rows[identifier]) continue;
        id contact = SRReadObject(self.manager, @"getContactByName:", @[identifier], NULL);
        if (![SRReadString(contact, @"m_nsUsrName") isEqual:identifier]) { unresolved++; continue; }
        rows[identifier] = [self rowForContact:contact fallbackID:nil];
    }
    // Do not expose a collection assembled while the active account changed.
    if (![self verifyAccount:account error:error]) return nil;
    self.groupRead = @{ @"state": contacts || sessions ? @"read" : @"unavailable", @"completeJoinedGroupListConfirmed": @NO,
        @"contacts": @{ @"state": contacts ? @"ok" : @"incompatible_or_unexpected_result", @"returnedCount": @(contacts.count),
                        @"ordinaryGroupCount": @(contactGroups.count) },
        @"sessions": @{ @"state": sessionState, @"returnedCount": @(sessions.count), @"ordinaryGroupCount": @(sessionGroups.count),
                        @"unresolvedGroupCount": @(unresolved), @"invalidItemCount": @(invalidSessions) },
        @"mergedGroupCount": @(rows.count) };
    if (!contacts && !sessions) {
        [self fail:@"本地联系人和会话群列表均不可读，请导出诊断；不会猜测参数或请求服务器通讯录" error:error]; return nil;
    }
    NSMutableArray *warnings = [NSMutableArray arrayWithObject:[NSString stringWithFormat:
        @"本地联系人 %lu 群、会话 %lu 群，按原始群 ID 去重后可读 %lu 群；尚未确认覆盖全部已加入群，请核对数量。",
        (unsigned long)contactGroups.count, (unsigned long)sessionGroups.count, (unsigned long)rows.count]];
    if (!contacts) [warnings addObject:@"联系人列表不可读，本次仅使用可核对的本地会话群。"];
    if (!sessions) [warnings addObject:@"会话列表不可读，本次仅使用联系人列表；若数量偏少请复制适配诊断。"];
    if (unresolved) [warnings addObject:@"部分会话群无法核对本地联系人，未加入可选列表；不会把未知或不匹配的 ID 当作目标。"];
    self.warnings = warnings;
    return [self orderedRows:rows];
}
- (BOOL)isGroupID:(id)identifier {
    return [identifier isKindOfClass:NSString.class] && [identifier length] > @"@chatroom".length &&
        [identifier hasSuffix:@"@chatroom"] &&
        [identifier rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location == NSNotFound;
}
- (NSArray *)membersOfGroup:(NSString *)group error:(NSError **)error {
    NSString *account = self.accountID;
    if (!account || ![self verifyAccount:account error:error]) return nil;
    if (![group hasSuffix:@"@chatroom"]) { [self fail:@"无效的普通群 ID" error:error]; return nil; }
    id contact = SRReadObject(self.manager, @"getContactByName:", @[group], error);
    if (!contact || ![SRReadString(contact, @"m_nsUsrName") isEqual:group]) {
        [self fail:@"无法核对母群联系人，停止读取成员" error:error]; return nil;
    }
    // The stored member list avoids guessing the ABI/semantics of group manager APIs.
    NSString *memberList = SRReadString(contact, @"m_nsChatRoomMemList");
    if (!memberList.length) { [self fail:@"母群成员列表尚不可读，请先在微信打开该群后重试" error:error]; return nil; }
    NSArray *identifiers = [memberList componentsSeparatedByString:@";"];
    NSMutableDictionary *rows = [NSMutableDictionary dictionary];
    for (NSString *identifier in identifiers) {
        if (!identifier.length) continue;
        if ([identifier rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound ||
            [identifier containsString:@","] || [identifier hasSuffix:@"@chatroom"]) {
            [self fail:@"成员列表格式不匹配，停止读取；请导出诊断" error:error]; return nil;
        }
        id member = SRReadObject(self.manager, @"getContactByName:", @[identifier], NULL);
        NSString *returnedID = SRReadString(member, @"m_nsUsrName");
        if (returnedID.length && ![returnedID isEqual:identifier]) {
            [self fail:@"成员 wxid 核对不一致，停止读取" error:error]; return nil;
        }
        NSDictionary *row = [self rowForContact:member fallbackID:identifier];
        rows[identifier] = row;
    }
    if (!rows.count) { [self fail:@"未读取到有效成员 wxid" error:error]; return nil; }
    self.warnings = @[@"成员来自微信本地群记录；昵称缺失时显示原始 wxid，不按昵称推断身份。"];
    return [self orderedRows:rows];
}
- (NSDictionary *)diagnostics {
    Class center = self.resolver(@"MMServiceCenter");
    Class manager = self.resolver(@"CContactMgr");
    Class contact = self.resolver(@"CContact");
    Class sessions = self.resolver(@"MMNewSessionMgr");
    return @{@"pluginVersion": @"0.2.3", @"wechatVersion": self.version,
        @"supportedReadCandidate": @([@[@"8.0.76", @"8.0.79"] containsObject:self.version]),
        @"centerClassPresent": @(center != Nil), @"contactClassPresent": @(manager != Nil),
        @"accountReadable": @(self.accountID.length > 0), @"sendingEnabled": @NO,
        @"groupRead": self.groupRead, @"sessionClassPresent": @(sessions != Nil),
        @"methods": @[SRDescribeMethod(center, @"defaultCenter"),
            SRDescribeInstanceMethod(center, @"getService:"),
            SRDescribeInstanceMethod(manager, @"getSelfContact"), SRDescribeInstanceMethod(manager, @"getContactList:contactType:"),
            SRDescribeInstanceMethod(manager, @"getContactByName:"), SRDescribeInstanceMethod(sessions, @"GetUserNamesOnSessionList"),
            SRDescribeInstanceMethod(contact, @"m_nsUsrName"),
            SRDescribeInstanceMethod(contact, @"m_nsNickName"), SRDescribeInstanceMethod(contact, @"m_nsChatRoomMemList")], @"warnings": self.warnings};
}
@end
