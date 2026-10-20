#import "SRSettingsFallback.h"
#import <objc/runtime.h>
#include <math.h>

static char SRSettingsFooterKey;

@interface SRSettingsFooter : UIView
@property(nonatomic, weak) UITableView *table;
@property(nonatomic, weak) UIViewController *controller;
@property(nonatomic, strong) UIView *originalFooter;
@property(nonatomic, strong) UIButton *button;
@property(nonatomic, copy) void (^open)(UIViewController *);
- (void)activate;
@end
@implementation SRSettingsFooter
- (void)activate {
    UIViewController *controller = self.controller;
    if (NSThread.isMainThread && controller && self.table.tableFooterView == self) self.open(controller);
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat originalHeight = self.originalFooter.frame.size.height;
    self.originalFooter.frame = CGRectMake(0, 0, self.bounds.size.width, originalHeight);
    self.button.frame = CGRectMake(16, originalHeight + 16, MAX(0, self.bounds.size.width - 32), self.bounds.size.height - originalHeight - 32);
}
@end

static UITableView *SRSettingsVisibleTable(UIViewController *controller) {
    UIView *root = controller.viewIfLoaded;
    if (!root) return nil;
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:root];
    // Only search this settings screen's existing views; never instantiate a host view.
    for (NSUInteger visited = 0; pending.count && visited < 256; visited++) {
        UIView *view = pending.firstObject; [pending removeObjectAtIndex:0];
        if (view.hidden) continue;
        if ([view isKindOfClass:UITableView.class]) return (UITableView *)view;
        [pending addObjectsFromArray:view.subviews];
    }
    return nil;
}

BOOL SRUpdateSettingsFallback(UIViewController *controller, BOOL nativeRowPresent, void (^open)(UIViewController *)) {
    if (!NSThread.isMainThread) return NO;
    SRSettingsFooter *existing = objc_getAssociatedObject(controller, &SRSettingsFooterKey);
    UITableView *table = nativeRowPresent ? nil : SRSettingsVisibleTable(controller);
    if (existing && existing.table == table && table.tableFooterView == existing) {
        existing.open = open; return YES;
    }
    if (existing) {
        if (existing.table.tableFooterView == existing) {
            [existing.originalFooter removeFromSuperview];
            existing.table.tableFooterView = existing.originalFooter;
        }
        objc_setAssociatedObject(controller, &SRSettingsFooterKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!table) return NO;
    SRSettingsFooter *footer = [[SRSettingsFooter alloc] init];
    footer.table = table; footer.controller = controller; footer.open = open;
    footer.originalFooter = table.tableFooterView;
    UIFont *font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    CGFloat height = MAX(52, ceil(font.lineHeight) + 24);
    footer.frame = CGRectMake(0, 0, table.bounds.size.width, footer.originalFooter.frame.size.height + height + 32);
    if (footer.originalFooter) [footer addSubview:footer.originalFooter];
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:@"SyncRelay 转发  ›" forState:UIControlStateNormal];
    button.titleLabel.font = font; button.titleLabel.adjustsFontForContentSizeCategory = YES;
    button.accessibilityLabel = @"SyncRelay 转发";
    button.accessibilityHint = @"打开转发设置和适配诊断";
    button.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    [button setTitleColor:UIColor.labelColor forState:UIControlStateNormal]; button.layer.cornerRadius = 10;
    [button addTarget:footer action:@selector(activate) forControlEvents:UIControlEventTouchUpInside];
    footer.button = button; [footer addSubview:button];
    objc_setAssociatedObject(controller, &SRSettingsFooterKey, footer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    table.tableFooterView = footer;
    return YES;
}
