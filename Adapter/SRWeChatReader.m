#import "SRWeChatReader.h"
#import "SRRuntime.h"

@interface SRWeChatReader ()
@property(nonatomic, copy, nullable) NSString *accountID;
@property(nonatomic, copy) NSString *version;
@property(nonatomic, copy) NSArray<NSString *> *warnings;
@property(nonatomic, copy) Class (^resolver)(NSString *);
@property(nonatomic, strong) id manager;
@end

@implementation SRWeChatReader
- (instancetype)initWithVersion:(NSString *)version classResolver:(Class (^)(NSString *))resolver {
    self = [super init];
    if (self) { _version = [version copy]; _resolver = [resolver copy]; _warnings = @[]; }
    return self;
}
- (BOOL)fail:(NSString *)message error:(NSError **)error {
    if (error) *error = [NSError errorWithDomain:@"SyncRelay.Reader" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}
- (BOOL)connect:(NSError **)error {
    self.manager = nil;
    self.accountID = nil;
    self.warnings = @[];
    if (!NSThread.isMainThread) return [self fail:@"请在主线程读取微信联系人" error:error];
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
    self.accountID = account;
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
    return @{@"id": identifier, @"name": name.length ? name : identifier};
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
    // Candidate arguments from legacy contact-list usage; completeness is not assumed.
    id result = SRReadObjectWithIntegers(self.manager, @"getContactList:contactType:", @[@1, @0], error);
    NSArray *contacts = [result isKindOfClass:NSArray.class] ? result : nil;
    if (!contacts) { [self fail:@"联系人列表接口未返回数组，请导出诊断；不会猜测其他参数" error:error]; return nil; }
    NSMutableDictionary *rows = [NSMutableDictionary dictionary];
    for (id contact in contacts) {
        NSDictionary *row = [self rowForContact:contact fallbackID:nil];
        if ([row[@"id"] hasSuffix:@"@chatroom"]) rows[row[@"id"]] = row;
    }
    self.warnings = @[@"仅列出当前接口返回的普通群；未确认覆盖全部已加入群，请核对数量。"];
    return [self orderedRows:rows];
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
    return @{@"pluginVersion": @"0.2.0", @"wechatVersion": self.version,
        @"supportedReadCandidate": @([@[@"8.0.76", @"8.0.79"] containsObject:self.version]),
        @"centerClassPresent": @(center != Nil), @"contactClassPresent": @(manager != Nil),
        @"accountReadable": @(self.accountID.length > 0), @"sendingEnabled": @NO,
        @"methods": @[SRDescribeMethod(center, @"defaultCenter"),
            SRDescribeInstanceMethod(center, @"getService:"),
            SRDescribeInstanceMethod(manager, @"getSelfContact"), SRDescribeInstanceMethod(manager, @"getContactList:contactType:"),
            SRDescribeInstanceMethod(manager, @"getContactByName:"), SRDescribeInstanceMethod(contact, @"m_nsUsrName"),
            SRDescribeInstanceMethod(contact, @"m_nsNickName"), SRDescribeInstanceMethod(contact, @"m_nsChatRoomMemList")], @"warnings": self.warnings};
}
@end
