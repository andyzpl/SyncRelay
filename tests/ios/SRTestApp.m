/* Reuse the unmodified entrypoints and their synthetic fixtures in one TU.
 * Rename the legacy main; its app delegate is deliberately never instantiated. */
#define main SRUnusedVisualTestMain
#import "SRFloatingProgressTests.m"
#undef main
#import "SRNavigationTests.m"

@interface SRScreenshotStore : SRImageStoreFixture
@end
@implementation SRScreenshotStore
- (NSDictionary *)configurationForAccount:(NSString *)account error:(__unused NSError **)error {
    assert([account isEqual:@"fixture-account"]);
    return @{@"sourceGroup": @{@"id": @"synthetic-source", @"name": @"演示母群"},
        @"rules": @[@{@"name": @"演示分组", @"targets": @[@{@"id": @"synthetic-target"}]}]};
}
@end

static void SRSaveAfter(UIWindow *window, NSString *name) {
    [window layoutIfNeeded];
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1; format.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:window.bounds.size format:format];
    NSData *png = [renderer PNGDataWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        assert([window drawViewHierarchyInRect:window.bounds afterScreenUpdates:YES]);
    }];
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSError *error = nil;
    assert([png writeToFile:[documents stringByAppendingPathComponent:name] options:NSDataWritingAtomic error:&error]);
    assert(!error && png.length > 0);
}

static void SRCaptureAfter(UIWindow *window) {
    for (UIView *view in window.subviews.copy)
        if ([view isKindOfClass:SRFloatingProgress.class]) [view removeFromSuperview];
    SRScreenshotStore *store = [[SRScreenshotStore alloc] init];
    UITableViewController *home = (id)SRCreateNavigationHome((id)store, @"fixture-account", ^{ return YES; },
        ^(__unused NSUInteger destination) {});
    window.rootViewController = [[SRNavigationController alloc] initWithRootViewController:home];
    [home.tableView layoutIfNeeded];
    assert(home.tableView.numberOfSections == 1 && [home.tableView numberOfRowsInSection:0] == 5);
    for (NSInteger row = 0; row < 5; row++) {
        UITableViewCell *cell = [home.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]];
        assert(cell && !CGRectIsEmpty(CGRectIntersection(cell.frame, home.tableView.bounds)));
    }
    SRSaveAfter(window, @"after-home-five-entrances.png");
    UIGraphicsImageRenderer *fixture = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(600, 300)];
    store.bytes = [fixture PNGDataWithActions:^(UIGraphicsImageRendererContext *context) {
        [UIColor.systemBlueColor setFill]; [context fillRect:CGRectMake(0, 0, 600, 300)];
        [UIColor.systemYellowColor setFill]; [context fillRect:CGRectMake(40, 40, 180, 220)];
    }];
    UITableViewController *preview = (id)SRCreateLibraryItem((id)store, @"fixture-account", ^{ return YES; }, @"fixture-item", nil, nil);
    window.rootViewController = [[SRNavigationController alloc] initWithRootViewController:preview];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    UIImageView *image = nil;
    do {
        [preview.tableView layoutIfNeeded];
        image = (id)SRFindMessageElement(preview.view, @"SyncRelay.LibraryImagePreview");
        if (!image.image) SRPumpPreviews();
    } while (!image.image && deadline.timeIntervalSinceNow > 0);
    assert(image.image && store.imageReads >= 1);
    SRSaveAfter(window, @"after-local-image-preview.png");
}

@interface SRTestApp : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation SRTestApp
- (BOOL)application:(__unused UIApplication *)app didFinishLaunchingWithOptions:(__unused NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 390, 844)];
    self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    self.window.rootViewController = [[UIViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
- (void)applicationDidBecomeActive:(__unused UIApplication *)application {
    static BOOL started = NO;
    if (started) return;
    started = YES;
    // Nested test run-loop pumping must be able to drain main-queue image completions.
    [self performSelector:@selector(runTests:) withObject:nil afterDelay:0];
}
- (void)runTests:(__unused id)sender {
    assert(NSThread.isMainThread);
    __block BOOL mainQueueDrained = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ mainQueueDrained = YES; });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
    while (!mainQueueDrained && deadline.timeIntervalSinceNow > 0) SRPumpPreviews();
    assert(mainQueueDrained);
    puts("PASS: nested test run loop drains asynchronous main-queue completions");
    [UIView setAnimationsEnabled:NO];
    SRRunVisualTests(self.window);
    puts("SR_TEST_ENTRYPOINT_PASS: SRFloatingProgressTests");
    SRRunNavigationTests(self.window);
    puts("SR_TEST_ENTRYPOINT_PASS: SRNavigationTests");
    SRCaptureAfter(self.window);
    puts("SR_UI_TESTS_PASS"); fflush(stdout); fflush(stderr);
    exit(EXIT_SUCCESS);
}
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(SRTestApp.class)); }
}
