/* Link with SRNavigationController.m and the UIKit test-app entry point. */
#import "UI/SRNavigationController.h"
#include <assert.h>
#include <stdio.h>

@interface SRNavigationDraftFixture : UIViewController <SRNavigationBackGuard>
@property(nonatomic) BOOL dirty;
@property(nonatomic) NSUInteger closeRequests;
@end
@implementation SRNavigationDraftFixture
- (BOOL)sr_hasUnsavedChanges { return self.dirty; }
- (void)sr_requestClose {
    self.closeRequests++;
    if (!self.dirty) SRPopPluginPage(self, NO);
}
@end

static void SRSettleNavigation(SRNavigationController *navigation) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1];
    while (navigation.transitionCoordinator && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    assert(navigation.transitionCoordinator == nil);
}

void SRRunNavigationTests(UIWindow *window) {
    UIViewController *home = [[UIViewController alloc] init];
    SRNavigationController *navigation = [[SRNavigationController alloc] initWithRootViewController:home];
    window.rootViewController = navigation; [navigation view];
    assert(!SRPopPluginPage(home, NO));
    assert(![navigation gestureRecognizerShouldBegin:navigation.interactivePopGestureRecognizer]);
    for (NSUInteger destination = 0; destination < 4; destination++) {
        SRNavigationDraftFixture *page = [[SRNavigationDraftFixture alloc] init];
        [navigation pushViewController:page animated:NO];
        assert(page.navigationItem.leftBarButtonItem != nil);
        assert([navigation gestureRecognizerShouldBegin:navigation.interactivePopGestureRecognizer]);
        [navigation requestBack];
        SRSettleNavigation(navigation);
        assert(navigation.topViewController == home && navigation.viewControllers.count == 1);
    }
    SRNavigationDraftFixture *settings = [[SRNavigationDraftFixture alloc] init];
    [navigation pushViewController:settings animated:NO];
    UIViewController *detail = [[UIViewController alloc] init];
    [navigation pushViewController:detail animated:NO];
    assert(!SRPopPluginPage(settings, NO)); /* A stale callback cannot pop a newer page. */
    [navigation requestBack];
    SRSettleNavigation(navigation);
    assert(navigation.topViewController == settings && navigation.viewControllers.count == 2);
    settings.dirty = YES;
    [navigation requestBack];
    assert(settings.closeRequests == 1 && navigation.topViewController == settings);
    assert(![navigation gestureRecognizerShouldBegin:navigation.interactivePopGestureRecognizer]);
    assert(settings.closeRequests == 2 && navigation.topViewController == settings);
    /* Cancel leaves the stack intact; explicit discard uses the same bound page. */
    assert(navigation.viewControllers.count == 2);
    settings.dirty = NO; assert(SRPopPluginPage(settings, NO));
    assert(navigation.topViewController == home);
    [navigation requestBack]; assert(navigation.topViewController == home);
    puts("PASS: four destinations, nested return, dirty back/swipe guard, stale page and root preservation");
}
