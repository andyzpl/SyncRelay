/* Included by receive_test.m so the existing native target runs these cases. */
@interface AppMessageBodyWrap : ReceiveWrap
@property(nonatomic) NSUInteger bodyReads;
@property(nonatomic) NSUInteger bodyMode;
@property(nonatomic, copy) void (^onBodyRead)(void);
@end
@implementation AppMessageBodyWrap
- (NSString *)m_nsContent {
    self.bodyReads++;
    if (self.onBodyRead) self.onBodyRead();
    if (self.bodyMode == 1) @throw @"private appmsg getter failure";
    if (self.bodyMode == 2) return (id)@123;
    if (self.bodyMode == 3) return nil;
    return [super m_nsContent];
}
@end

@interface AppMessageScalarBodyWrap : NSObject
@property(nonatomic, copy) NSString *m_nsFromUsr;
@property(nonatomic, copy) NSString *m_nsToUsr;
@property(nonatomic, copy) NSString *m_nsRealChatUsr;
@property(nonatomic) unsigned int m_uiMessageType;
@property(nonatomic) unsigned long long m_n64MesSvrID;
- (double)m_nsContent;
@end
@implementation AppMessageScalarBodyWrap
- (double)m_nsContent { abort(); }
@end

static AppMessageBodyWrap *appMessage(NSString *content) {
    AppMessageBodyWrap *value = [AppMessageBodyWrap new];
    value.m_nsFromUsr = @"mother@chatroom"; value.m_nsToUsr = @"wxid_account";
    value.m_nsRealChatUsr = @"wxid_sender"; value.m_uiMessageType = 49;
    value.m_n64MesSvrID = 9007199254740993ULL; value.m_nsContent = content;
    return value;
}
static NSArray *appSamples(SRWeChatReceiver *receiver) {
    return receiver.diagnostics[@"appMessageProbe"][@"samples"];
}
static void checkAppMessageProbe(void) {
    __block NSString *account = @"wxid_account";
    __block NSUInteger accepted = 0;
    SRWeChatReceiver *receiver = [[SRWeChatReceiver alloc] initWithVersion:@"8.0.79" classResolver:^Class(NSString *name) {
        return [name isEqual:@"CMessageMgr"] ? ReceiveManager.class : ([name isEqual:@"CMessageWrap"] ? ReceiveWrap.class : Nil);
    } currentAccount:^NSString *{ CHECK(NSThread.isMainThread); return account; }
        received:^(__unused NSDictionary *message) { accepted++; }];
    ReceiveManager *manager = [ReceiveManager new];
    NSMutableDictionary *configuration = draft(); configuration[@"types"] = @[@"text"];
    NSString *link = @"<msg><appmsg appid=\"private-appid\"><title><![CDATA[private title]]></title>"
        "<url>https://example.invalid/private-link?a=1&amp;b=2</url><type>5</type></appmsg></msg>";
    NSString *file = @"wxid_sender:\n<msg><appmsg><type><![CDATA[6]]></type><title>private-file.zip</title>"
        "<appattach><totallen>123456789</totallen><attachid>private-attach-id</attachid>"
        "<fileext>zip</fileext></appattach></appmsg></msg>";
    CHECK([receiver armForAccount:account configuration:configuration error:NULL]);
    AppMessageBodyWrap *linkWrap = appMessage(link), *fileWrap = appMessage(file);
    [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:linkWrap];
    [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:fileWrap]; pump();
    NSArray *samples = appSamples(receiver);
    CHECK(samples.count == 2 && !accepted && linkWrap.bodyReads == 1 && fileWrap.bodyReads == 1);
    CHECK([samples[0][@"state"] isEqual:@"parsed"] && [samples[0][@"subtype"] isEqual:@5]);
    CHECK([samples[0][@"kindHint"] isEqual:@"link"] && [samples[0][@"hasTitle"] boolValue] && [samples[0][@"hasURL"] boolValue]);
    CHECK(![samples[0][@"hasAttachment"] boolValue]);
    CHECK([samples[1][@"subtype"] isEqual:@6] && [samples[1][@"kindHint"] isEqual:@"file"]);
    for (NSString *key in @[@"hasTitle", @"hasAttachment", @"hasAttachmentID", @"hasFileExtension", @"hasTotalLength"])
        CHECK([samples[1][key] boolValue]);
    NSDictionary *probe = receiver.diagnostics[@"appMessageProbe"];
    CHECK([probe[@"observerOnly"] boolValue] && ![probe[@"relayable"] boolValue] && ![probe[@"deviceVerified"] boolValue]);
    CHECK(![receiver.diagnostics[@"ownTextPending"] boolValue] && ![receiver.diagnostics[@"imagePending"] boolValue]);
    NSString *json = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:receiver.diagnostics options:0 error:NULL] encoding:NSUTF8StringEncoding];
    for (NSString *secret in @[@"private title", @"private-file.zip", @"private-appid", @"private-link", @"private-attach-id",
        @"123456789", @"9007199254740993", @"wxid_sender", @"mother@chatroom", @"<appmsg"])
        CHECK(![json containsString:secret]);
    [receiver stop]; CHECK(samples.count == 2);

    NSArray *cases = @[
        @[@"<appmsg><type> 5 </type><title>   </title><url><![CDATA[ ]]></url></appmsg>", @"parsed", @5],
        @[@"<?xml version=\"1.0\"?><msg><appmsg><type>6</type></appmsg></msg>", @"parsed", @6],
        @[@"<?xml version=\"1.0\" encoding=\"UTF-8\"?><msg><appmsg><type>5</type></appmsg></msg>", @"parsed", @5],
        @[@"<?xml version=\"1.0\" encoding=\"UTF-7\"?>+ADw-!DOCTYPE msg+AD4-+ADw-msg/+AD4-", @"unsafe_xml"],
        @[@"wxid_sender:\n\uFEFF<?xml version=\"1.0\" encoding=\"UTF-7\"?>+ADw-!DOCTYPE msg+AD4-", @"unsafe_xml"],
        @[@"<?xml version=\"1.0\" encoding=\"UTF-8\" encoding=\"UTF-7\"?><msg/>", @"invalid_xml"],
        @[@"wxid_sender:\r\n<msg><appmsg><type>5</type></appmsg></msg>", @"parsed", @5],
        @[@"\uFEFF<msg><appmsg><type>2000</type></appmsg></msg>", @"parsed", @2000],
        @[@"<msg><appmsg><type>4294967295</type></appmsg></msg>", @"parsed", @(UINT32_MAX)],
        @[@"", @"empty_content"],
        @[@"<msg><appmsg><type>5</type></appmsg>", @"invalid_xml"],
        @[@"<msg><appmsg><type>5</type></appmsg></msg>private trailing data", @"invalid_xml"],
        @[@"<msg><appmsg><type>5</type></appmsg></msg><msg/>", @"invalid_xml"],
        @[@"<msg/>", @"unsupported_structure"],
        @[@"<wrapper><appmsg><type>5</type></appmsg></wrapper>", @"unsupported_structure"],
        @[@"<msg xmlns=\"private-namespace\"><appmsg><type>5</type></appmsg></msg>", @"unsupported_structure"],
        @[@"<msg><appmsg><type>5</type></appmsg><appmsg><type>6</type></appmsg></msg>", @"unsupported_structure"],
        @[@"<msg><appmsg><type><type>5</type></type></appmsg></msg>", @"unsupported_structure"],
        @[@"<msg><appmsg><type>5</type><type>6</type></appmsg></msg>", @"ambiguous_fields"],
        @[@"<msg><appmsg><type>5</type><url>a</url><url>b</url></appmsg></msg>", @"ambiguous_fields"],
        @[@"<appmsg><type>6</type><appattach/><appattach/></appmsg>", @"ambiguous_fields"],
        @[@"<appmsg><type>6</type><appattach><attachid>a</attachid><attachid>b</attachid></appattach></appmsg>", @"ambiguous_fields"],
        @[@"wxid_other:\n<msg><appmsg><type>5</type></appmsg></msg>", @"sender_prefix_mismatch"],
        @[@"private prefix<msg><appmsg><type>5</type></appmsg></msg>", @"unsupported_structure"],
        @[@"<msg><appmsg><wrapper><type>5</type></wrapper></appmsg></msg>", @"invalid_subtype"],
        @[@"<msg><appmsg><type><![CDATA[<type>5</type>]]></type></appmsg></msg>", @"invalid_subtype"],
        @[@"<msg><appmsg><type>4294967296</type></appmsg></msg>", @"invalid_subtype"],
        @[@"<msg><appmsg><type>-5</type></appmsg></msg>", @"invalid_subtype"],
        @[@"<msg><appmsg><type>5.0</type></appmsg></msg>", @"invalid_subtype"],
        @[@"<!DOCTYPE msg [<!ENTITY a 'private-entity'>]><msg><appmsg><type>5</type><title>&a;</title></appmsg></msg>", @"unsafe_xml"],
        @[@"<!DOCTYPE msg SYSTEM 'file:///private-secret'><msg><appmsg><type>5</type></appmsg></msg>", @"unsafe_xml"],
        @[@"<!DOCTYPE msg [<!ENTITY % a SYSTEM 'https://example.invalid/private-entity'>%a;]><msg/>", @"unsafe_xml"],
        // Foundation may route undeclared entities through its resolution delegate.
        @[@"<msg><appmsg><type>5</type><title>&private_unknown_entity;</title></appmsg></msg>", @[@"invalid_xml", @"unsafe_xml"]]
    ];
    NSUInteger caseIndex = 0;
    for (NSArray *test in cases) {
        CHECK([receiver armForAccount:account configuration:configuration error:NULL]);
        [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:appMessage(test[0])]; pump();
        CHECK(appSamples(receiver).count == 1);
        NSDictionary *sample = appSamples(receiver)[0];
        NSArray *expectedStates = [test[1] isKindOfClass:NSArray.class] ? test[1] : @[test[1]];
        if (![expectedStates containsObject:sample[@"state"]])
            fprintf(stderr, "appmsg case %lu expected=%s actual=%s\n", (unsigned long)caseIndex,
                [expectedStates.description UTF8String], [sample[@"state"] UTF8String]);
        CHECK([expectedStates containsObject:sample[@"state"]]);
        CHECK(test.count > 2 ? [sample[@"subtype"] isEqual:test[2]] : sample[@"subtype"] == nil);
        if ([sample[@"subtype"] isEqual:@2000] || [sample[@"subtype"] isEqual:@(UINT32_MAX)]) CHECK([sample[@"kindHint"] isEqual:@"other"]);
        CHECK(!accepted && [receiver.diagnostics[@"armed"] boolValue]); [receiver stop];
        caseIndex++;
    }
    NSMutableString *deep = [NSMutableString stringWithString:@"<msg><appmsg><type>5</type>"];
    for (NSUInteger i = 0; i < 40; i++) [deep appendString:@"<x>"];
    for (NSUInteger i = 0; i < 40; i++) [deep appendString:@"</x>"];
    [deep appendString:@"</appmsg></msg>"];
    NSMutableString *wide = [NSMutableString stringWithString:@"<msg><appmsg><type>5</type>"];
    for (NSUInteger i = 0; i < 1030; i++) [wide appendString:@"<x/>"];
    [wide appendString:@"</appmsg></msg>"];
    NSArray *limits = @[
        @[[link stringByPaddingToLength:128 * 1024 + 1 withString:@" " startingAtIndex:0], @"too_large"],
        @[[NSString stringWithFormat:@"<appmsg><type>5</type><title>%@</title></appmsg>",
            [@"\u4E2D" stringByPaddingToLength:50000 withString:@"\u4E2D" startingAtIndex:0]], @"too_large"],
        @[@"<appmsg><type>555555555555555555555555555555555</type></appmsg>", @"invalid_subtype"],
        @[deep, @"too_complex"], @[wide, @"too_complex"]
    ];
    for (NSArray *test in limits) {
        CHECK([receiver armForAccount:account configuration:configuration error:NULL]);
        [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:appMessage(test[0])]; pump();
        CHECK([appSamples(receiver)[0][@"state"] isEqual:test[1]]); [receiver stop];
    }
    NSMutableString *nulInterleaved = [NSMutableString string];
    NSString *dtd = @"<!DOCTYPE msg [<!ENTITY a 'private'>]><msg><appmsg><type>5</type></appmsg></msg>";
    for (NSUInteger i = 0; i < dtd.length; i++) [nulInterleaved appendFormat:@"%C%C", [dtd characterAtIndex:i], (unichar)0];
    CHECK([receiver armForAccount:account configuration:configuration error:NULL]);
    [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:appMessage(nulInterleaved)]; pump();
    CHECK([appSamples(receiver)[0][@"state"] isEqual:@"unsafe_xml"]); [receiver stop];
    for (NSUInteger mode = 1; mode <= 3; mode++) {
        CHECK([receiver armForAccount:account configuration:configuration error:NULL]);
        AppMessageBodyWrap *bad = appMessage(link); bad.bodyMode = mode;
        [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:bad]; pump();
        CHECK([appSamples(receiver)[0][@"state"] isEqual:@"content_unavailable"] && !accepted);
        CHECK([receiver.diagnostics[@"armed"] boolValue]); [receiver stop];
    }
    CHECK([receiver armForAccount:account configuration:configuration error:NULL]);
    AppMessageScalarBodyWrap *scalar = [AppMessageScalarBodyWrap new];
    scalar.m_nsFromUsr = @"mother@chatroom"; scalar.m_nsToUsr = account;
    scalar.m_nsRealChatUsr = @"wxid_sender"; scalar.m_uiMessageType = 49; scalar.m_n64MesSvrID = 1;
    [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:scalar]; pump();
    CHECK([appSamples(receiver)[0][@"state"] isEqual:@"content_unavailable"]);
    CHECK([appSamples(receiver)[0][@"getterState"] isEqual:@2]); [receiver stop];

    // None of the rejection paths may read an unrelated message's body.
    CHECK([receiver armForAccount:account configuration:configuration error:NULL]);
    for (NSUInteger mode = 0; mode < 5; mode++) {
        AppMessageBodyWrap *value = appMessage(link); NSString *session = @"mother@chatroom";
        if (mode == 0) session = @"other@chatroom";
        if (mode == 1) value.m_nsFromUsr = @"other@chatroom";
        if (mode == 2) value.m_nsToUsr = @"wxid_other";
        if (mode == 3) value.m_nsRealChatUsr = @"wxid_other";
        if (mode == 4) value.m_nsRealChatUsr = nil;
        [manager AsyncOnAddMsg:session MsgWrap:value]; pump(); CHECK(!value.bodyReads);
    }
    for (NSNumber *type in @[@34, @42, @43, @47]) {
        AppMessageBodyWrap *value = appMessage(link); value.m_uiMessageType = type.unsignedIntValue;
        [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:value]; pump(); CHECK(!value.bodyReads);
    }
    CHECK(!appSamples(receiver).count); [receiver stop];
    CHECK([receiver armForAccount:account sourceGroup:@"mother@chatroom" error:NULL]);
    AppMessageBodyWrap *legacy = appMessage(link);
    [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:legacy]; pump(); CHECK(!legacy.bodyReads); [receiver stop];

    // A bounded queue is reserved before dispatch; excess callbacks do not read XML.
    CHECK([receiver armForAccount:account configuration:configuration error:NULL]);
    AppMessageBodyWrap *many = appMessage(link);
    for (NSUInteger i = 0; i < 24; i++) [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:many];
    pump(); CHECK(many.bodyReads == 16 && appSamples(receiver).count == 16);
    CHECK([receiver.diagnostics[@"appMessageProbe"][@"dropped"] isEqual:@8]);
    [receiver stop];
    CHECK([receiver armForAccount:account configuration:configuration error:NULL]);
    CHECK(!appSamples(receiver).count && [receiver.diagnostics[@"appMessageProbe"][@"attempts"] isEqual:@0]);
    AppMessageBodyWrap *stale = appMessage(link);
    [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:stale]; [receiver stop];
    CHECK([receiver armForAccount:account configuration:configuration error:NULL]); pump();
    CHECK(!stale.bodyReads && !appSamples(receiver).count);
    [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:stale]; account = @"wxid_changed"; pump();
    CHECK(!stale.bodyReads && !appSamples(receiver).count); account = @"wxid_account";
    [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:stale]; stale.m_nsRealChatUsr = @"wxid_other"; pump();
    CHECK(!stale.bodyReads && !appSamples(receiver).count); stale.m_nsRealChatUsr = @"wxid_sender";
    __weak SRWeChatReceiver *weak = receiver;
    stale.onBodyRead = ^{ [weak stop]; CHECK([weak armForAccount:account configuration:configuration error:NULL]); };
    [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:stale]; pump();
    CHECK(stale.bodyReads == 1 && !appSamples(receiver).count); stale.onBodyRead = nil;
    stale.onBodyRead = ^{ account = @"wxid_changed"; };
    [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:stale]; pump();
    CHECK(!appSamples(receiver).count); account = @"wxid_account"; stale.onBodyRead = nil;
    __weak AppMessageBodyWrap *weakStale = stale;
    stale.onBodyRead = ^{ weakStale.m_nsToUsr = @"wxid_other"; };
    [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:stale]; pump();
    CHECK(!appSamples(receiver).count); stale.onBodyRead = nil; stale.m_nsToUsr = account;
    [receiver stop];

    // Own type-49 observation does not start a server-ID wait or a send.
    configuration[@"senders"] = @[@{@"id": account, @"name": @"Self"}];
    CHECK([receiver armForAccount:account configuration:configuration error:NULL]);
    AppMessageBodyWrap *own = appMessage(link); own.m_nsFromUsr = account; own.m_nsToUsr = @"mother@chatroom";
    own.m_nsRealChatUsr = @"wxid_other"; own.m_n64MesSvrID = 0;
    [manager AddMsg:@"mother@chatroom" MsgWrap:own]; pump(); CHECK(!own.bodyReads && !appSamples(receiver).count);
    own.m_nsRealChatUsr = nil; [manager AddMsg:@"mother@chatroom" MsgWrap:own]; pump();
    CHECK(own.bodyReads == 1 && [appSamples(receiver)[0][@"subtype"] isEqual:@5]);
    CHECK(![receiver.diagnostics[@"ownTextPending"] boolValue] && !accepted); [receiver stop];

    __block double now = 100.2;
    SRWeChatReceiver *timed = [[SRWeChatReceiver alloc] initWithVersion:@"8.0.79" classResolver:^Class(NSString *name) {
        return [name isEqual:@"CMessageMgr"] ? TimeManager.class : ([name isEqual:@"CMessageWrap"] ? TimedReceiveWrap.class : Nil);
    } currentAccount:^NSString *{ return account; } received:^(__unused NSDictionary *message) { abort(); } clock:^double { return now; }];
    timed.receivedWithTimeEvidence = ^(__unused NSDictionary *message, __unused NSDictionary *evidence) { abort(); };
    configuration = draft(); configuration[@"types"] = @[@"text"];
    CHECK([timed armForAccount:account configuration:configuration newMessagesOnly:YES error:NULL]);
    TimeManager *timeManager = [TimeManager new]; now = 102;
    for (NSNumber *created in @[@0, @80, @100, @103, @101]) {
        TimedReceiveWrap *value = timedWrap(created.unsignedIntValue); value.m_uiMessageType = 49; value.m_nsContent = link;
        [timeManager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:value]; pump();
    }
    CHECK(appSamples(timed).count == 1 && [appSamples(timed)[0][@"subtype"] isEqual:@5]); [timed stop];
    puts("PASS: appmsg structural subtype probe, XML limits/entities, privacy, filters, bounded queue and late generations (not relay support)");
}
