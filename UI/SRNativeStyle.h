#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

static inline UIColor *SRSettingsBackground(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        CGFloat component = traits.userInterfaceStyle == UIUserInterfaceStyleDark ? 0.067 : 0.929;
        return [UIColor colorWithWhite:component alpha:1];
    }];
}

static inline UIColor *SRSettingsCellBackground(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return [UIColor colorWithWhite:traits.userInterfaceStyle == UIUserInterfaceStyleDark ? 0.098 : 1 alpha:1];
    }];
}

static inline UIColor *SRSettingsAccent(void) {
    return [UIColor colorWithRed:7.0 / 255 green:193.0 / 255 blue:96.0 / 255 alpha:1];
}

static inline UIFont *SRSettingsFont(CGFloat size, UIFontTextStyle style) {
    return [[UIFontMetrics metricsForTextStyle:style] scaledFontForFont:[UIFont systemFontOfSize:size]];
}

static inline void SRStyleSettingsController(UIViewController *controller) {
    controller.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    controller.navigationItem.backButtonDisplayMode = UINavigationItemBackButtonDisplayModeMinimal;
}

static inline void SRStyleSettingsTable(UITableViewController *controller) {
    SRStyleSettingsController(controller);
    UITableView *table = controller.tableView;
    table.backgroundColor = SRSettingsBackground();
    table.tintColor = SRSettingsAccent();
    table.rowHeight = UITableViewAutomaticDimension;
    table.estimatedRowHeight = 56;
    table.sectionHeaderTopPadding = 0;
    table.separatorInset = UIEdgeInsetsMake(0, 16, 0, 0);
    table.cellLayoutMarginsFollowReadableWidth = YES;
    table.tableHeaderView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 8)];
}

static inline void SRStyleSettingsCell(UITableViewCell *cell) {
    cell.backgroundColor = SRSettingsCellBackground();
    cell.tintColor = SRSettingsAccent();
    cell.textLabel.font = SRSettingsFont(17, UIFontTextStyleBody);
    cell.detailTextLabel.font = SRSettingsFont(14, UIFontTextStyleSubheadline);
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.layoutMargins = UIEdgeInsetsMake(16, 16, 16, 16);
}

// Configure only our navigation controller, not the host or a global appearance proxy.
static inline void SRStyleSettingsNavigation(UINavigationController *navigation, UINavigationController * _Nullable host) {
    UINavigationBarAppearance *appearance = [host.navigationBar.standardAppearance copy];
    if (!appearance) {
        appearance = [[UINavigationBarAppearance alloc] init];
        [appearance configureWithOpaqueBackground];
        appearance.backgroundColor = SRSettingsBackground();
        appearance.shadowColor = UIColor.clearColor;
        appearance.titleTextAttributes = @{NSFontAttributeName: [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold],
            NSForegroundColorAttributeName: UIColor.labelColor};
    }
    navigation.navigationBar.prefersLargeTitles = NO;
    navigation.navigationBar.standardAppearance = appearance;
    navigation.navigationBar.scrollEdgeAppearance = [appearance copy];
    navigation.navigationBar.compactAppearance = [appearance copy];
    navigation.navigationBar.tintColor = host.navigationBar.tintColor ?: UIColor.labelColor;
}

NS_ASSUME_NONNULL_END
