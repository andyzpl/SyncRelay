#import "SRFloatingProgress.h"
#import "SRNativeStyle.h"

@interface SRFloatingProgress () <UIGestureRecognizerDelegate>
@property(nonatomic, strong) UILabel *countLabel;
@property(nonatomic, strong) UILabel *phaseLabel;
@property(nonatomic, strong) UIButton *actionButton;
@property(nonatomic, strong) UIButton *menuButton;
@property(nonatomic, copy) NSDictionary *model;
@property(nonatomic) CGFloat unitX;
@property(nonatomic) CGFloat unitY;
@property(nonatomic) BOOL dragging;
@property(nonatomic) CGRect keyboardFrame;
@end

@implementation SRFloatingProgress
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _unitX = 1;
        _unitY = 0.35;
        self.backgroundColor = SRSettingsCellBackground(); self.layer.cornerRadius = 27;
        self.layer.shadowColor = UIColor.blackColor.CGColor; self.layer.shadowOpacity = 0.14;
        self.layer.shadowRadius = 10; self.layer.shadowOffset = CGSizeMake(0, 3);
        _countLabel = [[UILabel alloc] init]; _countLabel.textColor = UIColor.labelColor;
        _phaseLabel = [[UILabel alloc] init]; _phaseLabel.textColor = UIColor.secondaryLabelColor;
        _actionButton = [UIButton buttonWithType:UIButtonTypeSystem]; _actionButton.tintColor = SRSettingsAccent();
        _actionButton.backgroundColor = SRSettingsBackground(); _actionButton.layer.cornerRadius = 18;
        [_actionButton addTarget:self action:@selector(pressed) forControlEvents:UIControlEventTouchUpInside];
        _menuButton = [UIButton buttonWithType:UIButtonTypeSystem]; _menuButton.tintColor = UIColor.secondaryLabelColor;
        [_menuButton setTitle:@"..." forState:UIControlStateNormal];
        [_menuButton addTarget:self action:@selector(menuPressed) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_countLabel]; [self addSubview:_phaseLabel]; [self addSubview:_actionButton]; [self addSubview:_menuButton];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openPressed)];
        tap.cancelsTouchesInView = NO; tap.delegate = self; [self addGestureRecognizer:tap];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)];
        [self addGestureRecognizer:pan];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(keyboardChanged:) name:UIKeyboardWillChangeFrameNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(keyboardChanged:) name:UIKeyboardWillHideNotification object:nil];
        self.accessibilityIdentifier = @"SyncRelay.ExecutionProgress";
        _countLabel.accessibilityLabel = @"已处理群数，不代表已送达";
    }
    return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (CGRect)availableBounds {
    UIWindow *window = self.window; if (!window) return CGRectZero;
    CGRect bounds = UIEdgeInsetsInsetRect(window.bounds, window.safeAreaInsets);
    bounds = CGRectInset(bounds, 12, 12);
    if (!CGRectIsEmpty(self.keyboardFrame)) {
        CGRect keyboard = [window convertRect:self.keyboardFrame fromCoordinateSpace:window.screen.coordinateSpace];
        if (CGRectIntersectsRect(bounds, keyboard) && CGRectGetWidth(keyboard) > CGRectGetWidth(bounds) * 0.5)
            bounds.size.height = MAX(0, MIN(CGRectGetMaxY(bounds), CGRectGetMinY(keyboard) - 12) - CGRectGetMinY(bounds));
    }
    return bounds;
}
- (void)place {
    if (!self.window || self.dragging) return;
    CGRect available = [self availableBounds];
    CGFloat scale = MIN(1.45, MAX(1, [UIFont preferredFontForTextStyle:UIFontTextStyleBody].pointSize / 17));
    CGFloat width = MIN(CGRectGetWidth(available), 176 * scale), height = MIN(CGRectGetHeight(available), 56 * scale);
    if (width < 132 || height < 44) { self.hidden = YES; return; }
    self.hidden = NO;
    CGFloat x = CGRectGetMinX(available) + (CGRectGetWidth(available) - width) * MAX(0, MIN(1, self.unitX));
    CGFloat y = CGRectGetMinY(available) + (CGRectGetHeight(available) - height) * self.unitY;
    self.frame = CGRectMake(x, y, width, height); self.layer.cornerRadius = height / 2;
    [self setNeedsLayout];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat height = self.bounds.size.height, width = self.bounds.size.width;
    CGFloat scale = height / 56, buttonWidth = 54 * scale, menuWidth = 28 * scale;
    self.countLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleHeadline] scaledFontForFont:[UIFont monospacedDigitSystemFontOfSize:17 weight:UIFontWeightSemibold] maximumPointSize:25];
    self.phaseLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleFootnote] scaledFontForFont:[UIFont systemFontOfSize:13] maximumPointSize:18];
    self.actionButton.titleLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody] scaledFontForFont:[UIFont systemFontOfSize:15] maximumPointSize:22];
    CGFloat textWidth = width - buttonWidth - menuWidth - 32;
    self.countLabel.frame = CGRectMake(16, 7 * scale, textWidth, 23 * scale);
    self.phaseLabel.frame = CGRectMake(16, 30 * scale, textWidth, 18 * scale);
    self.actionButton.frame = CGRectMake(width - buttonWidth - 6, 6, buttonWidth, height - 12);
    self.actionButton.layer.cornerRadius = (height - 12) / 2;
    self.menuButton.frame = CGRectMake(width - buttonWidth - menuWidth - 3, 0, menuWidth, height);
    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:self.layer.cornerRadius].CGPath;
}
- (void)showModel:(NSDictionary *)model inWindow:(UIWindow *)window {
    BOOL entering = self.superview != window;
    BOOL changed = ![self.model isEqual:model]; self.model = model;
    if (entering) { [self removeFromSuperview]; [window addSubview:self]; }
    [window bringSubviewToFront:self];
    if (changed) {
        self.countLabel.text = model[@"countText"] ?: [NSString stringWithFormat:@"%@ / %@", model[@"processed"] ?: @0, model[@"total"] ?: @0];
        NSString *phase = model[@"phase"];
        self.phaseLabel.text = [@{@"running": @"转发中", @"paused": @"已暂停", @"settling": @"在途处理中",
            @"ready": @"待转发", @"waiting": @"等待消息", @"completed": @"本组完成"} objectForKey:phase] ?: @"状态待核对";
        self.phaseLabel.textColor = [phase isEqual:@"running"] ? SRSettingsAccent() : UIColor.secondaryLabelColor;
        NSString *title = [phase isEqual:@"settling"] ? @"等待" :
            ([model[@"action"] isEqual:@"pause"] ? @"暂停" : ([model[@"action"] isEqual:@"open"] ? @"查看" : @"继续"));
        [self.actionButton setTitle:title forState:UIControlStateNormal];
        self.actionButton.enabled = [model[@"actionEnabled"] boolValue];
        self.menuButton.hidden = ![model[@"menuEnabled"] boolValue];
        self.actionButton.accessibilityLabel = [model[@"action"] isEqual:@"pause"] ? @"暂停转发，不撤回在途消息" :
            ([model[@"action"] isEqual:@"open"] ? @"打开运营首页" : @"继续未尝试的群，不重发未知结果");
    }
    [self place];
    self.actionButton.enabled = [model[@"actionEnabled"] boolValue];
    self.menuButton.hidden = ![model[@"menuEnabled"] boolValue];
    if (entering && !UIAccessibilityIsReduceMotionEnabled()) {
        self.alpha = 0;
        [UIView animateWithDuration:0.18 animations:^{ self.alpha = 1; }];
    }
}
- (void)hide { [self removeFromSuperview]; self.model = nil; }
- (void)pressed {
    self.actionButton.enabled = NO;
    if ([self.model[@"action"] isEqual:@"open"]) { if (self.openAction) self.openAction(); }
    else if (self.action) self.action();
}
- (void)openPressed { if (self.openAction && ![self.model[@"action"] isEqual:@"open"]) self.openAction(); }
- (void)menuPressed { if (self.menuAction) self.menuAction(); }
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if (![gestureRecognizer isKindOfClass:UITapGestureRecognizer.class]) return YES;
    UIView *view = touch.view;
    return view != self.actionButton && view != self.menuButton && ![view isDescendantOfView:self.actionButton] && ![view isDescendantOfView:self.menuButton];
}
- (void)keyboardChanged:(NSNotification *)notification {
    self.keyboardFrame = [notification.name isEqual:UIKeyboardWillHideNotification] ? CGRectZero : [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    [self place];
}
- (void)drag:(UIPanGestureRecognizer *)pan {
    if (!self.window) return;
    if (pan.state == UIGestureRecognizerStateBegan) self.dragging = YES;
    CGPoint translation = [pan translationInView:self.window]; [pan setTranslation:CGPointZero inView:self.window];
    CGRect bounds = [self availableBounds];
    CGRect frame = self.frame; frame.origin.x += translation.x; frame.origin.y += translation.y;
    frame.origin.x = MAX(CGRectGetMinX(bounds), MIN(frame.origin.x, CGRectGetMaxX(bounds) - frame.size.width));
    frame.origin.y = MAX(CGRectGetMinY(bounds), MIN(frame.origin.y, CGRectGetMaxY(bounds) - frame.size.height)); self.frame = frame;
    if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled || pan.state == UIGestureRecognizerStateFailed) {
        self.dragging = NO;
        CGFloat travelX = bounds.size.width - frame.size.width;
        CGFloat travelY = bounds.size.height - frame.size.height;
        /* The operations capsule is a persistent entry point: release snaps it
         * to the nearer safe edge instead of leaving a second floating button
         * in the middle of a chat or video surface. */
        self.unitX = travelX > 0 && (CGRectGetMidX(frame) - CGRectGetMinX(bounds)) >= bounds.size.width * 0.5 ? 1 : 0;
        self.unitY = travelY > 0 ? MAX(0, MIN(1, (frame.origin.y - bounds.origin.y) / travelY)) : 0;
        if (UIAccessibilityIsReduceMotionEnabled()) [self place];
        else [UIView animateWithDuration:0.18 animations:^{ [self place]; }];
    }
}
@end
