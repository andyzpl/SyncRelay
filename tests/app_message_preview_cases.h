#import "Adapter/SRWeChatFileSource.h"
#import "Core/SRSourceMessage.h"
#include <unistd.h>
#include <sys/stat.h>

@interface FilePreviewWrap : AppMessageBodyWrap
@property(nonatomic, copy) NSString *nativePath;
@property(nonatomic) NSUInteger pathReads;
@property(nonatomic, copy) void (^onPathRead)(void);
@end
@implementation FilePreviewWrap
- (NSString *)GetAppAttachmentPath {
    self.pathReads++; if (self.onPathRead) self.onPathRead(); return self.nativePath;
}
@end
@interface FileScalarGetter : ReceiveWrap
@end
@implementation FileScalarGetter
- (double)GetAppAttachmentPath { abort(); }
@end

static void checkAppMessagePreview(void) {
    __block NSString *account = @"wxid_account";
    SRWeChatReceiver *receiver = [[SRWeChatReceiver alloc] initWithVersion:@"8.0.79" classResolver:^Class(NSString *name) {
        return [name isEqual:@"CMessageMgr"] ? ReceiveManager.class : ReceiveWrap.class;
    } currentAccount:^NSString *{ return account; } received:^(__unused NSDictionary *message) { abort(); }];
    ReceiveManager *manager = [ReceiveManager new]; NSMutableDictionary *config = draft();
    NSString *linkXML = @"<msg><appmsg><type>5</type><title><![CDATA[private link title]]></title><url>https://example.invalid/private?a=1&amp;b=2</url></appmsg></msg>";
    CHECK([receiver armAppMessagePreviewForAccount:account configuration:config kind:@"link" error:NULL]);
    [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:wrap()]; pump();
    CHECK(!receiver.appMessagePreview && [receiver.diagnostics[@"armed"] boolValue]);
    AppMessageBodyWrap *value = appMessage(linkXML);
    [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:value]; pump();
    CHECK(receiver.appMessagePreviewActive && ![receiver.diagnostics[@"armed"] boolValue]);
    CHECK([receiver.appMessagePreview[@"title"] isEqual:@"private link title"]);
    CHECK([receiver.appMessagePreview[@"url"] isEqual:@"https://example.invalid/private?a=1&b=2"]);
    CHECK([receiver.appMessagePreview[@"relayable"] isEqual:@NO] && [receiver.appMessagePreview[@"metadataOnly"] isEqual:@YES]);
    value.m_nsContent = @"changed";
    CHECK([receiver.appMessagePreview[@"title"] isEqual:@"private link title"]);
    NSString *diagnostic = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:receiver.diagnostics options:0 error:NULL] encoding:NSUTF8StringEncoding];
    for (NSString *secret in @[@"private link title", @"example.invalid", @"wxid_account", @"privateFields", @"sha256"])
        CHECK(![diagnostic containsString:secret]);
    [receiver stop]; CHECK(!receiver.appMessagePreview && !receiver.appMessagePreviewActive);

    for (NSString *url in @[@"javascript:alert(1)", @"file:///private/test", @"https:///missing-host", @"https://user:pw@example.invalid/a",
        @"https://example.invalid:0/a", @"https://example.invalid:99999/a", @"https://example.invalid/a b", @"//example.invalid/path"]) {
        CHECK([receiver armAppMessagePreviewForAccount:account configuration:config kind:@"link" error:NULL]);
        NSString *xml = [NSString stringWithFormat:@"<appmsg><type>5</type><title>Title</title><url>%@</url></appmsg>", url];
        [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:appMessage(xml)]; pump();
        CHECK(!receiver.appMessagePreview && [receiver.diagnostics[@"appMessagePreview"][@"state"] isEqual:@"invalid_url"]); [receiver stop];
    }
    CHECK([receiver armAppMessagePreviewForAccount:account configuration:config kind:@"link" error:NULL]);
    AppMessageBodyWrap *stale = appMessage(linkXML);
    [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:stale]; [receiver stop]; pump(); CHECK(!stale.bodyReads && !receiver.appMessagePreview);
    CHECK([receiver armAppMessagePreviewForAccount:account configuration:config kind:@"link" error:NULL]);
    stale.onBodyRead = ^{ account = @"wxid_other"; };
    [manager AsyncOnAddMsg:@"mother@chatroom" MsgWrap:stale]; pump(); CHECK(!receiver.appMessagePreview); [receiver stop]; account = @"wxid_account";
    config[@"senders"] = @[@{@"id": account, @"name": @"Self"}];
    CHECK([receiver armAppMessagePreviewForAccount:account configuration:config kind:@"link" error:NULL]);
    value = appMessage(linkXML); value.m_nsFromUsr = account; value.m_nsToUsr = @"mother@chatroom"; value.m_nsRealChatUsr = nil;
    value.m_n64MesSvrID = 0; [manager AddMsg:@"mother@chatroom" MsgWrap:value]; pump();
    CHECK(receiver.appMessagePreview && ![receiver.diagnostics[@"ownTextPending"] boolValue]); [receiver stop];

    // Preview-only data must not become an ordinary source envelope or plan.
    NSDictionary *unsupported = @{@"account": account, @"group": @"mother@chatroom", @"sender": account,
        @"messageID": @"svr:1", @"type": @"link", @"generatedByRelay": @NO,
        @"payload": @{@"title": @"Title", @"url": @"https://example.invalid/"}};
    CHECK(![SRSourceMessage matchesEnvelope:unsupported configuration:config account:account]);
    CHECK(![receiver armAppMessagePreviewForAccount:account configuration:config kind:@"video" error:NULL]);

    NSString *home = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *documents = [home stringByAppendingPathComponent:@"Documents"];
    CHECK([NSFileManager.defaultManager createDirectoryAtPath:documents withIntermediateDirectories:YES attributes:nil error:NULL]);
    NSString *path = [documents stringByAppendingPathComponent:@"native-file.bin"];
    NSData *bytes = [@"private file bytes" dataUsingEncoding:NSUTF8StringEncoding];
    CHECK([bytes writeToFile:path atomically:NO]);
    FilePreviewWrap *file = [FilePreviewWrap new]; file.m_uiMessageType = 49; file.nativePath = path;
    NSString *state; NSDictionary *snapshot = [SRWeChatFileSource snapshotForWrap:file expectedSize:bytes.length home:home allowed:^BOOL { return YES; } state:&state];
    CHECK([state isEqual:@"file_snapshot_ready"] && [snapshot[@"data"] isEqual:bytes]);
    CHECK([snapshot[@"sha256"] length] == 64 && [snapshot[@"byteCount"] unsignedIntegerValue] == bytes.length);
    CHECK(!snapshot[@"path"] && !snapshot[@"nativePath"]);
    CHECK([[@"different" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:NO]);
    CHECK([snapshot[@"data"] isEqual:bytes]);
    CHECK(![SRWeChatFileSource snapshotForWrap:file expectedSize:bytes.length home:home allowed:^BOOL { return YES; } state:&state]);
    CHECK([state isEqual:@"file_length_mismatch"]);
    CHECK([bytes writeToFile:path atomically:NO]);
    for (NSNumber *size in @[@0, @(8ULL * 1024 * 1024 + 1)]) {
        NSUInteger reads = file.pathReads;
        CHECK(![SRWeChatFileSource snapshotForWrap:file expectedSize:size.unsignedLongLongValue home:home allowed:^BOOL { return YES; } state:&state]);
        CHECK(reads == file.pathReads && [state isEqual:@"file_size_rejected"]);
    }
    __block BOOL allowed = YES;
    file.onPathRead = ^{ allowed = NO; };
    CHECK(![SRWeChatFileSource snapshotForWrap:file expectedSize:bytes.length home:home allowed:^BOOL { return allowed; } state:&state]);
    CHECK([state isEqual:@"file_context_changed"]); file.onPathRead = nil;
    FileScalarGetter *scalar = [FileScalarGetter new]; scalar.m_uiMessageType = 49;
    CHECK(![SRWeChatFileSource snapshotForWrap:scalar expectedSize:bytes.length home:home allowed:^BOOL { return YES; } state:&state]);
    CHECK([state isEqual:@"file_getter_unavailable"]);
    for (NSString *bad in @[@"/etc/passwd", [home stringByAppendingString:@"-sibling/Documents/native-file.bin"],
        [documents stringByAppendingPathComponent:@"../Documents/native-file.bin"], [home stringByAppendingPathComponent:@"Library/Preferences/config.plist"]]) {
        file.nativePath = bad;
        CHECK(![SRWeChatFileSource snapshotForWrap:file expectedSize:bytes.length home:home allowed:^BOOL { return YES; } state:&state]);
        CHECK([state isEqual:@"file_path_rejected"]);
    }
    NSString *symlinkPath = [documents stringByAppendingPathComponent:@"symlink.bin"];
    CHECK(symlink(path.fileSystemRepresentation, symlinkPath.fileSystemRepresentation) == 0);
    file.nativePath = symlinkPath;
    CHECK(![SRWeChatFileSource snapshotForWrap:file expectedSize:bytes.length home:home allowed:^BOOL { return YES; } state:&state]);
    CHECK([state isEqual:@"file_not_ready"]);
    NSString *alias = [documents stringByAppendingPathComponent:@"alias"];
    CHECK(symlink(documents.fileSystemRepresentation, alias.fileSystemRepresentation) == 0);
    file.nativePath = [alias stringByAppendingPathComponent:@"native-file.bin"];
    CHECK(![SRWeChatFileSource snapshotForWrap:file expectedSize:bytes.length home:home allowed:^BOOL { return YES; } state:&state]);
    NSString *hard = [documents stringByAppendingPathComponent:@"hard.bin"];
    CHECK(link(path.fileSystemRepresentation, hard.fileSystemRepresentation) == 0);
    file.nativePath = hard;
    snapshot = [SRWeChatFileSource snapshotForWrap:file expectedSize:bytes.length home:home allowed:^BOOL { return YES; } state:&state];
    CHECK([state isEqual:@"file_snapshot_ready"] && [snapshot[@"data"] isEqual:bytes]);
    CHECK(![SRWeChatFileSource snapshotForWrap:file expectedSize:bytes.length + 1 home:home allowed:^BOOL { return YES; } state:&state]);
    CHECK([state isEqual:@"file_length_mismatch"]);
    NSMutableData *mutatedBytes = [bytes mutableCopy]; ((unsigned char *)mutatedBytes.mutableBytes)[0] ^= 1;
    CHECK([mutatedBytes writeToFile:path atomically:NO]);
    CHECK([snapshot[@"data"] isEqual:bytes]);
    CHECK([bytes writeToFile:path atomically:NO]);
    NSString *extraHard = [documents stringByAppendingPathComponent:@"extra-hard.bin"];
    __block NSUInteger fileChecks = 0;
    CHECK(![SRWeChatFileSource snapshotForWrap:file expectedSize:bytes.length home:home allowed:^BOOL {
        if (++fileChecks == 3) CHECK(link(path.fileSystemRepresentation, extraHard.fileSystemRepresentation) == 0);
        return YES;
    } state:&state]);
    CHECK([state isEqual:@"file_changed"]);
    CHECK(unlink(extraHard.fileSystemRepresentation) == 0);
    fileChecks = 0;
    CHECK(![SRWeChatFileSource snapshotForWrap:file expectedSize:bytes.length home:home allowed:^BOOL {
        if (++fileChecks == 3) CHECK(unlink(hard.fileSystemRepresentation) == 0);
        return YES;
    } state:&state]);
    CHECK([state isEqual:@"file_changed"]);
    CHECK(link(path.fileSystemRepresentation, hard.fileSystemRepresentation) == 0);
    CHECK(unlink(hard.fileSystemRepresentation) == 0);
    NSString *fifo = [documents stringByAppendingPathComponent:@"fifo"];
    CHECK(mkfifo(fifo.fileSystemRepresentation, 0600) == 0); file.nativePath = fifo;
    CHECK(![SRWeChatFileSource snapshotForWrap:file expectedSize:bytes.length home:home allowed:^BOOL { return YES; } state:&state]);
    CHECK([state isEqual:@"file_non_regular"]);
    CHECK([NSFileManager.defaultManager removeItemAtPath:home error:NULL]);
    puts("PASS: preview-only link freezing and URL gates, account/generation privacy, native attachment ABI, bounded immutable file copies and path guards (no plan/send)");
}
