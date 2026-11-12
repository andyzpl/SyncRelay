#import "SRNavigationController.h"

@interface SRNavigationController ()
@property(nonatomic, weak) UIViewController *pluginRoot;
@end

BOOL SRPopPluginPage(UIViewController *controller, BOOL animated) {
    UINavigationController *navigation = controller.navigationController;
    NSArray<UIViewController *> *stack = navigation.viewControllers;
    if (navigation.topViewController != controller || stack.count < 2 ||
        navigation.transitionCoordinator) return NO;
    [navigation setViewControllers:[stack subarrayWithRange:NSMakeRange(0, stack.count - 1)] animated:animated];
    return YES;
}

@implementation SRNavigationController
- (instancetype)initWithRootViewController:(UIViewController *)rootViewController {
    self = [super initWithRootViewController:rootViewController];
    if (self) _pluginRoot = rootViewController;
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.delegate = self;
    self.interactivePopGestureRecognizer.delegate = self;
}
- (void)navigationController:(__unused UINavigationController *)navigation
     willShowViewController:(UIViewController *)controller animated:(__unused BOOL)animated {
    // Keep the root's Close item out of the child Back setup during stack transitions.
    if (controller == self.pluginRoot || controller == self.viewControllers.firstObject) return;
    __weak typeof(self) weakSelf = self;
    __weak UIViewController *weakPage = controller;
    UIAction *back = [UIAction actionWithTitle:@"" image:[UIImage systemImageNamed:@"chevron.backward"] identifier:nil handler:^(__unused UIAction *action) {
        if (weakSelf.topViewController == weakPage) [weakSelf requestBack];
    }];
    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithPrimaryAction:back];
    item.accessibilityLabel = @"返回";
    /* Preserve pickers' batch menus next to our explicit return action. */
    NSMutableArray<UIBarButtonItem *> *items = [NSMutableArray arrayWithObject:item];
    for (UIBarButtonItem *existing in controller.navigationItem.leftBarButtonItems)
        if (existing.menu) [items addObject:existing];
    controller.navigationItem.leftItemsSupplementBackButton = NO;
    controller.navigationItem.leftBarButtonItems = items;
}
- (void)requestBack {
    UIViewController *page = self.topViewController;
    if (self.viewControllers.count < 2 || self.transitionCoordinator || self.presentedViewController) return;
    if ([page conformsToProtocol:@protocol(SRNavigationBackGuard)])
        [(id<SRNavigationBackGuard>)page sr_requestClose];
    else SRPopPluginPage(page, YES);
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    if (gesture != self.interactivePopGestureRecognizer) return YES;
    if (self.viewControllers.count < 2 || self.transitionCoordinator || self.presentedViewController) return NO;
    UIViewController *page = self.topViewController;
    if ([page conformsToProtocol:@protocol(SRNavigationBackGuard)] &&
        [(id<SRNavigationBackGuard>)page sr_hasUnsavedChanges]) {
        [(id<SRNavigationBackGuard>)page sr_requestClose];
        return NO;
    }
    return YES;
}
@end
