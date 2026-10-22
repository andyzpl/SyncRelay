#import "SRAppMessagePreviewScreen.h"
#import "SRNativeStyle.h"
#import "Adapter/SRWeChatReceiver.h"

@interface SRAppMessagePreviewScreen : UIViewController
@property(nonatomic, strong) SRWeChatReceiver *receiver;
@property(nonatomic, copy) NSString *account;
@property(nonatomic, copy) BOOL (^verify)(void);
@end
@implementation SRAppMessagePreviewScreen
- (void)loadView {
    UITextView *text = [UITextView new]; text.editable = NO; text.dataDetectorTypes = UIDataDetectorTypeNone;
    text.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; text.adjustsFontForContentSizeCategory = YES;
    text.textColor = UIColor.labelColor; text.backgroundColor = SRSettingsCellBackground();
    text.textContainerInset = UIEdgeInsetsMake(20, 16, 24, 16); self.view = text;
}
- (void)viewDidLoad {
    [super viewDidLoad]; SRStyleSettingsController(self); self.title = @"链接／文件实验预览";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"清除" style:UIBarButtonItemStylePlain target:self action:@selector(clear)];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(hide) name:UIApplicationWillResignActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload) name:UIApplicationDidBecomeActiveNotification object:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reload]; }
- (void)viewDidDisappear:(BOOL)animated { [super viewDidDisappear:animated]; ((UITextView *)self.viewIfLoaded).text = @""; }
- (void)hide { [self.receiver stop]; ((UITextView *)self.viewIfLoaded).text = @"已清除。回前台后需手动重新捕获。"; }
- (void)clear { [self.receiver stop]; [self reload]; }
- (void)reload {
    BOOL verified = NO;
    @try { verified = self.verify && self.verify(); } @catch (__unused id exception) { }
    NSDictionary *preview = verified ? self.receiver.appMessagePreview : nil;
    if (!verified) [self.receiver stop];
    if (!preview || ![preview[@"account"] isEqual:self.account]) {
        if (preview) [self.receiver stop];
        ((UITextView *)self.view).text = @"没有当前账号的实验预览。切后台、锁屏或取消会清除内存快照，请返回手动重新捕获。"; return;
    }
    NSString *text;
    if ([preview[@"kind"] isEqual:@"link"]) {
        text = [NSString stringWithFormat:@"链接标题\n%@\n\n网址\n%@\n\n仅显示冻结的标题和网址，不打开网页、不下载缩略图，也不代表完整链接卡片。", preview[@"title"], preview[@"url"]];
    } else {
        NSDictionary *file = preview[@"fileSnapshot"];
        text = [NSString stringWithFormat:@"文件名（消息标题）\n%@\n\n扩展名\n%@\n\n已读取快照\n%@ 字节\n\nSHA-256\n%@\n\n仅复制已存在的本地文件并校验长度与读取期间稳定性；不是文件内容渲染，不打开、不执行文件。", preview[@"title"], preview[@"fileExtension"], file[@"byteCount"], file[@"sha256"]];
    }
    ((UITextView *)self.view).text = [text stringByAppendingString:@"\n\n本页仅实验预览，不建立计划，不发送。快照只在内存中，切后台即清除。"];
}
@end
UIViewController *SRCreateAppMessagePreviewScreen(SRWeChatReceiver *receiver, NSString *account, BOOL (^verify)(void)) {
    SRAppMessagePreviewScreen *screen = [SRAppMessagePreviewScreen new];
    screen.receiver = receiver; screen.account = account; screen.verify = verify; return screen;
}
