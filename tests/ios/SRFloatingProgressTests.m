/* Native UIKit test-app entry point. Link with UI/SRFloatingProgress.m in an
 * iOS Simulator application. This is not a macOS Foundation test and cannot
 * validate WeChat's gesture arbitration or host lifecycle. */
#import <UIKit/UIKit.h>
#import "UI/SRFloatingProgress.h"
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
extern void SRRunNavigationTests(UIWindow *window);

@interface SRFloatingProgress (VisualTests)
- (void)openPressed;
- (void)pressed;
- (void)drag:(UIPanGestureRecognizer *)pan;
@end

@interface SRVisualTestPan : UIPanGestureRecognizer
@property(nonatomic) UIGestureRecognizerState testState;
@property(nonatomic) CGPoint testTranslation;
@end
@implementation SRVisualTestPan
- (UIGestureRecognizerState)state { return self.testState; }
- (CGPoint)translationInView:(__unused UIView *)view { return self.testTranslation; }
- (void)setTranslation:(CGPoint)translation inView:(__unused UIView *)view { self.testTranslation = translation; }
@end

static NSDictionary *SRVisualModel(NSString *phase) {
    NSMutableDictionary *model = [@{ @"phase": phase, @"processed": @12, @"total": @20,
        @"action": [phase isEqual:@"running"] ? @"pause" : @"resume",
        @"actionEnabled": @(![phase isEqual:@"settling"]), @"uiAccount": @"synthetic-account" } mutableCopy];
    if (![phase isEqual:@"idle"]) model[@"uiRunID"] = @"synthetic-run";
    return model;
}
static void SRVisualDrag(SRFloatingProgress *view, CGFloat dx, UIGestureRecognizerState end) {
    SRVisualTestPan *pan = [[SRVisualTestPan alloc] init];
    pan.testState = UIGestureRecognizerStateBegan; [view drag:pan];
    pan.testTranslation = CGPointMake(dx, 0); pan.testState = end; [view drag:pan];
    [view layoutIfNeeded];
}
static void SRRunVisualTests(UIWindow *window) {
    [UIView setAnimationsEnabled:NO];
    SRFloatingProgress *view = [[SRFloatingProgress alloc] initWithFrame:CGRectZero];
    __block NSUInteger opens = 0, commands = 0, closes = 0;
    view.openAction = ^{ opens++; }; view.action = ^{ commands++; };
    view.closeResultAction = ^{ closes++; };
    [view showModel:SRVisualModel(@"idle") inWindow:window];
    UILabel *count = [view valueForKey:@"countLabel"];
    assert(CGRectGetWidth(view.frame) >= 88 && CGRectGetHeight(view.frame) == 44);
    assert([count.text isEqual:@"同步"]);
    assert([view accessibilityActivate]); assert(opens == 1 && commands == 0);
    [view showModel:SRVisualModel(@"running") inWindow:window];
    assert(![[view valueForKey:@"progressExpanded"] boolValue]);
    UIButton *action = [view valueForKey:@"actionButton"];
    assert(!action.hidden && [action.currentTitle isEqual:@"暂停"]);
    assert([count.text isEqual:@"已处理 12/20"]);
    [view pressed]; assert(commands == 1);

    /* Ordinary edge contact and a cancelled outward gesture stay full size. */
    SRVisualDrag(view, 0, UIGestureRecognizerStateEnded);
    assert(![[view valueForKey:@"docked"] boolValue]);
    SRVisualDrag(view, 29, UIGestureRecognizerStateCancelled);
    assert(![[view valueForKey:@"docked"] boolValue]);
    SRVisualDrag(view, 29, UIGestureRecognizerStateEnded);
    assert([[view valueForKey:@"docked"] boolValue]);
    UIView *surface = [view valueForKey:@"dockSurface"];
    CGRect visible = [view convertRect:surface.frame toView:window];
    assert(CGRectGetWidth(visible) == 22 && CGRectGetHeight(visible) == 90);
    assert(CGRectGetMaxX(visible) == CGRectGetWidth(window.bounds));
    CGRect dock = view.frame;
    for (NSString *phase in @[@"paused", @"settling", @"completed"]) {
        [view showModel:SRVisualModel(phase) inWindow:window];
        assert(CGRectEqualToRect(dock, view.frame));
        assert([[view valueForKey:@"docked"] boolValue]);
        NSString *state = [@{ @"paused": @"‹\n已\n暂\n停", @"settling": @"‹\n收\n尾\n中",
            @"completed": @"‹\n已\n结\n束" } objectForKey:phase];
        assert([((UILabel *)[view valueForKey:@"dockLabel"]).text isEqual:state]);
        assert(opens == 1 && commands == 1);
    }
    UILabel *label = [view valueForKey:@"dockLabel"];
    assert([label.text isEqual:@"‹\n已\n结\n束"]);
    [view openPressed];
    assert(![[view valueForKey:@"docked"] boolValue]);
    assert(![[view valueForKey:@"progressExpanded"] boolValue]);
    assert(opens == 1 && commands == 1);
    [view pressed]; assert(closes == 1 && commands == 1);

    /* Inward restoration does not open details, resume or pause. */
    SRVisualDrag(view, 29, UIGestureRecognizerStateEnded);
    SRVisualDrag(view, -15, UIGestureRecognizerStateEnded);
    assert(![[view valueForKey:@"docked"] boolValue]);
    assert(opens == 1 && commands == 1);
    [view setInitialPositionUnitX:0 unitY:0.5];
    SRVisualDrag(view, -29, UIGestureRecognizerStateEnded);
    visible = [view convertRect:surface.frame toView:window];
    assert(CGRectGetMinX(visible) == 0 && CGRectGetWidth(visible) == 22);
    assert([label.text hasPrefix:@"›"]);
    assert(![view pointInside:CGPointMake(2, 45) withEvent:nil]);
    NSMutableDictionary *next = [SRVisualModel(@"running") mutableCopy]; next[@"uiRunID"] = @"next-run";
    [view showModel:next inWindow:window];
    assert(![[view valueForKey:@"docked"] boolValue]);
    assert(![[view valueForKey:@"progressExpanded"] boolValue]);
    [view showModel:SRVisualModel(@"idle") inWindow:window];
    assert([count.text isEqual:@"同步"] && ![[view valueForKey:@"docked"] boolValue]);
    puts("PASS: native UIKit idle, running, edge docking, restore, paused and ended projections");
}

@interface SRVisualTestApp : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation SRVisualTestApp
- (BOOL)application:(__unused UIApplication *)app didFinishLaunchingWithOptions:(__unused NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 390, 844)];
    self.window.rootViewController = [[UIViewController alloc] init];
    [self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_main_queue(), ^{ SRRunVisualTests(self.window); SRRunNavigationTests(self.window); exit(0); });
    return YES;
}
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(SRVisualTestApp.class)); }
}
