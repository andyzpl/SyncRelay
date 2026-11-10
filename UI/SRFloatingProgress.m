#import "SRFloatingProgress.h"
#import "SRNativeStyle.h"
#import "SRCapsuleGeometry.h"

@interface SRFloatingProgress () <UIGestureRecognizerDelegate>
@property(nonatomic, strong) UILabel *countLabel;
@property(nonatomic, strong) UILabel *phaseLabel;
@property(nonatomic, strong) UIButton *actionButton;
@property(nonatomic, strong) UIButton *menuButton;
@property(nonatomic, copy) NSDictionary *model;
@property(nonatomic, copy) NSString *displayAccount;
@property(nonatomic, copy) NSString *displayRun;
@property(nonatomic, copy) NSNumber *previewGeneration;
@property(nonatomic) BOOL previewCollapsed;
@property(nonatomic) BOOL progressExpanded;
@property(nonatomic) BOOL docked;
@property(nonatomic) BOOL dragStartedDocked;
@property(nonatomic) CGRect dragStartFrame;
@property(nonatomic, strong) UILabel *dockLabel;
@property(nonatomic, strong) UIView *dockSurface;
@property(nonatomic, strong) UIView *idleSurface;
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
        _unitY = 0.82;
        self.backgroundColor = SRSettingsCellBackground(); self.layer.cornerRadius = 27;
        self.layer.shadowColor = UIColor.blackColor.CGColor; self.layer.shadowOpacity = 0.14;
        self.layer.shadowRadius = 10; self.layer.shadowOffset = CGSizeMake(0, 3);
        _countLabel = [[UILabel alloc] init]; _countLabel.textColor = UIColor.labelColor;
        _phaseLabel = [[UILabel alloc] init]; _phaseLabel.textColor = UIColor.secondaryLabelColor;
        _actionButton = [UIButton buttonWithType:UIButtonTypeSystem]; _actionButton.tintColor = UIColor.systemBlueColor;
        _actionButton.backgroundColor = SRSettingsBackground(); _actionButton.layer.cornerRadius = 18;
        [_actionButton addTarget:self action:@selector(pressed) forControlEvents:UIControlEventTouchUpInside];
        _menuButton = [UIButton buttonWithType:UIButtonTypeSystem]; _menuButton.tintColor = UIColor.secondaryLabelColor;
        [_menuButton setTitle:@"..." forState:UIControlStateNormal];
        [_menuButton addTarget:self action:@selector(menuPressed) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_countLabel]; [self addSubview:_phaseLabel]; [self addSubview:_actionButton]; [self addSubview:_menuButton];
        _dockLabel = [[UILabel alloc] init]; _dockLabel.numberOfLines = 0; _dockLabel.textAlignment = NSTextAlignmentCenter;
        _dockLabel.textColor = UIColor.labelColor; _dockLabel.hidden = YES;
        _dockSurface = [[UIView alloc] init]; _dockSurface.userInteractionEnabled = NO;
        _dockSurface.backgroundColor = [UIColor colorWithWhite:0.18 alpha:0.86];
        _dockSurface.layer.cornerRadius = 10; _dockSurface.hidden = YES;
        [self addSubview:_dockSurface];
        _idleSurface = [[UIView alloc] init]; _idleSurface.userInteractionEnabled = NO;
        _idleSurface.backgroundColor = UIColor.secondarySystemBackgroundColor;
        _idleSurface.layer.cornerRadius = 19; _idleSurface.hidden = YES;
        [self insertSubview:_idleSurface atIndex:0];
        [self addSubview:_dockLabel];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openPressed)];
        tap.cancelsTouchesInView = NO; tap.delegate = self; [self addGestureRecognizer:tap];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)];
        [self addGestureRecognizer:pan];
        /* A drag must never also expand the capsule or invoke a body tap. */
        [tap requireGestureRecognizerToFail:pan];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(keyboardChanged:) name:UIKeyboardWillChangeFrameNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(keyboardChanged:) name:UIKeyboardWillHideNotification object:nil];
        self.accessibilityIdentifier = @"SyncRelay.ExecutionProgress";
        _countLabel.accessibilityLabel = @"已处理群数，不代表已送达";
    }
    return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)setInitialPositionUnitX:(CGFloat)unitX unitY:(CGFloat)unitY {
    if (!isfinite(unitX) || !isfinite(unitY)) return;
    self.unitX = MAX(0, MIN(1, unitX)); self.unitY = MAX(0, MIN(1, unitY));
    [self place];
}
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
    BOOL preview = [self.model[@"phase"] isEqual:@"preview"];
    BOOL idle = [self.model[@"phase"] isEqual:@"idle"];
    BOOL expanded = !self.docked && ((preview && !self.previewCollapsed) || (!preview && self.progressExpanded));
    CGFloat width = self.docked || idle ? 44 : MIN(CGRectGetWidth(available), (expanded ? 264 : 240) * scale);
    CGFloat height = self.docked ? 90 : (idle ? 44 : (expanded ? (preview ? 90 : 116) : 56) * scale);
    CGFloat minimumWidth = self.docked || idle ? 44 : (expanded ? 196 : 216) * scale;
    CGFloat minimumHeight = height;
    if (CGRectGetHeight(available) < minimumHeight) { self.hidden = YES; return; }
    if (width < minimumWidth || height < minimumHeight) { self.hidden = YES; return; }
    self.hidden = NO;
    CGFloat x = CGRectGetMinX(available) + (CGRectGetWidth(available) - width) * MAX(0, MIN(1, self.unitX));
    if (self.docked) x = SRCapsuleHandleOriginX(CGRectGetWidth(self.window.bounds), self.unitX < 0.5);
    CGFloat y = CGRectGetMinY(available) + (CGRectGetHeight(available) - height) * self.unitY;
    self.frame = CGRectMake(x, y, width, height); self.layer.cornerRadius = self.docked ? 12 : (expanded ? 20 : height / 2);
    [self setNeedsLayout];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat height = self.bounds.size.height, width = self.bounds.size.width;
    CGFloat scale = height / 56, buttonWidth = 56 * scale;
    self.countLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleHeadline] scaledFontForFont:[UIFont monospacedDigitSystemFontOfSize:17 weight:UIFontWeightSemibold] maximumPointSize:25];
    self.phaseLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleFootnote] scaledFontForFont:[UIFont systemFontOfSize:13] maximumPointSize:18];
    self.actionButton.titleLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody] scaledFontForFont:[UIFont systemFontOfSize:15] maximumPointSize:22];
    self.countLabel.textAlignment = NSTextAlignmentLeft;
    self.countLabel.hidden = NO;
    self.phaseLabel.hidden = NO;
    self.menuButton.hidden = ![self.model[@"menuEnabled"] boolValue];
    self.actionButton.backgroundColor = SRSettingsBackground();
    self.actionButton.hidden = NO; self.dockLabel.hidden = !self.docked;
    BOOL idle = [self.model[@"phase"] isEqual:@"idle"];
    self.dockSurface.hidden = !self.docked; self.idleSurface.hidden = !idle;
    self.backgroundColor = self.docked || idle ? UIColor.clearColor : SRSettingsCellBackground();
    self.layer.shadowOpacity = self.docked || idle ? 0 : 0.10;
    if (idle) {
        self.idleSurface.frame = CGRectMake(3, 3, 38, 38);
        self.countLabel.text = @"S"; self.countLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
        self.countLabel.textAlignment = NSTextAlignmentCenter; self.countLabel.frame = self.bounds;
        self.phaseLabel.hidden = YES; self.actionButton.hidden = YES; self.menuButton.hidden = YES;
        self.isAccessibilityElement = YES; self.accessibilityTraits = UIAccessibilityTraitButton;
        self.accessibilityLabel = @"SyncRelay 快捷入口"; self.accessibilityHint = @"打开入口，不会发送消息";
        return;
    }
    self.isAccessibilityElement = NO; self.accessibilityLabel = nil; self.accessibilityHint = nil;
    if (self.docked) {
        self.countLabel.hidden = YES; self.phaseLabel.hidden = YES;
        self.actionButton.hidden = YES; self.menuButton.hidden = YES;
        NSString *phase = self.model[@"phase"];
        NSString *state = [@{@"running": @"转\n发\n中", @"paused": @"已\n暂\n停", @"settling": @"收\n尾\n中",
            @"completed": @"已\n结\n束", @"waiting": @"等\n待\n中", @"preview": @"待\n同\n步", @"ready": @"待\n转\n发"} objectForKey:phase] ?: @"转\n发";
        self.dockLabel.text = [NSString stringWithFormat:@"%@\n%@", self.unitX < 0.5 ? @"›" : @"‹", state];
        self.dockLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        self.dockLabel.textColor = UIColor.whiteColor;
        CGFloat surfaceX = SRCapsuleHandleSurfaceX(self.unitX < 0.5);
        self.dockSurface.frame = CGRectMake(surfaceX, 0, 22, 90);
        self.dockSurface.layer.maskedCorners = self.unitX < 0.5 ?
            kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner : kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner;
        self.dockLabel.frame = CGRectMake(surfaceX, 8, 22, 74);
        self.dockLabel.accessibilityLabel = [NSString stringWithFormat:@"%@，已收纳，轻触展开胶囊，不会改变转发状态",
            [state stringByReplacingOccurrencesOfString:@"\n" withString:@""]];
        self.isAccessibilityElement = YES; self.accessibilityTraits = UIAccessibilityTraitButton;
        self.accessibilityLabel = self.dockLabel.accessibilityLabel;
        self.accessibilityHint = @"轻触或向屏幕内拖动，恢复胶囊";
        return;
    }
    if ([self.model[@"phase"] isEqual:@"preview"]) {
        self.phaseLabel.hidden = YES;
        [self updatePreviewControls];
        if (self.previewCollapsed) {
            self.actionButton.frame = CGRectInset(self.bounds, 4, 4);
            self.actionButton.layer.cornerRadius = (height - 8) / 2;
        } else {
            CGFloat half = (width - 28) / 2;
            self.countLabel.frame = CGRectMake(14, 8, width - 28, height - 60);
            self.actionButton.frame = CGRectMake(14, height - 52, half, 44);
            self.actionButton.layer.cornerRadius = 12;
            self.menuButton.frame = CGRectMake(14 + half, height - 52, half, 44);
            self.menuButton.titleLabel.font = self.actionButton.titleLabel.font;
        }
        self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:self.layer.cornerRadius].CGPath;
        return;
    }
    if (self.progressExpanded) {
        CGFloat expandedScale = height / 116, inset = 14 * expandedScale;
        self.countLabel.frame = CGRectMake(inset, 8 * expandedScale, width - inset * 2, 26 * expandedScale);
        self.phaseLabel.frame = CGRectMake(inset, 36 * expandedScale, width - inset * 2, 20 * expandedScale);
        CGFloat half = (width - inset * 2) / 2;
        self.actionButton.frame = CGRectMake(inset, height - 52 * expandedScale, half, 44 * expandedScale);
        self.actionButton.layer.cornerRadius = 12;
        self.menuButton.frame = CGRectMake(inset + half, height - 52 * expandedScale, half, 44 * expandedScale);
        self.menuButton.titleLabel.font = self.actionButton.titleLabel.font;
        [self.menuButton setTitle:@"查看详情" forState:UIControlStateNormal];
        self.menuButton.hidden = NO;
        self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:self.layer.cornerRadius].CGPath;
        return;
    }
    [self.menuButton setTitle:@"..." forState:UIControlStateNormal];
    if ([self.model[@"phase"] isEqual:@"waiting"]) {
        [self.actionButton setTitle:@"查看" forState:UIControlStateNormal];
        self.actionButton.accessibilityLabel = @"打开群同步";
    }
    CGFloat textWidth = width - buttonWidth - 38;
    self.phaseLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleHeadline]
        scaledFontForFont:[UIFont systemFontOfSize:16 weight:UIFontWeightSemibold] maximumPointSize:23];
    self.countLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleFootnote]
        scaledFontForFont:[UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular] maximumPointSize:19];
    self.phaseLabel.textColor = UIColor.labelColor; self.countLabel.textColor = UIColor.secondaryLabelColor;
    self.phaseLabel.frame = CGRectMake(16, 7 * scale, textWidth, 23 * scale);
    self.countLabel.frame = CGRectMake(16, 30 * scale, textWidth, 18 * scale);
    self.actionButton.frame = CGRectMake(width - buttonWidth - 6, 6, buttonWidth, height - 12);
    self.actionButton.layer.cornerRadius = (height - 12) / 2;
    self.menuButton.hidden = YES;
    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:self.layer.cornerRadius].CGPath;
}
- (void)showModel:(NSDictionary *)model inWindow:(UIWindow *)window {
    BOOL entering = self.superview != window;
    BOOL idle = [model[@"phase"] isEqual:@"idle"];
    BOOL accountChanged = self.displayAccount && ![self.displayAccount isEqual:model[@"uiAccount"]];
    self.displayAccount = model[@"uiAccount"];
    BOOL newRun = [model[@"uiRunID"] length] && ![self.displayRun isEqual:model[@"uiRunID"]];
    self.displayRun = model[@"uiRunID"];
    if (idle || accountChanged || newRun) { self.docked = NO; self.progressExpanded = NO; }
    if ([model[@"phase"] isEqual:@"running"] && ![self.model[@"phase"] isEqual:@"running"] &&
        ![@[@"paused", @"settling"] containsObject:self.model[@"phase"] ?: @""]) self.progressExpanded = NO;
    BOOL changed = ![self.model isEqual:model]; self.model = model;
    NSNumber *generation = model[@"previewGeneration"];
    if (generation && ![generation isEqual:self.previewGeneration]) {
        self.previewGeneration = generation;
        self.previewCollapsed = self.docked;
    }
    if (entering) { [self removeFromSuperview]; [window addSubview:self]; }
    [window bringSubviewToFront:self];
    if (changed) {
        self.countLabel.text = model[@"countText"] ?: [NSString stringWithFormat:@"已处理 %@/%@", model[@"processed"] ?: @0, model[@"total"] ?: @0];
        NSString *phase = model[@"phase"];
        BOOL preview = [phase isEqual:@"preview"];
        self.countLabel.hidden = NO;
        self.phaseLabel.hidden = preview;
        self.countLabel.accessibilityLabel = model[@"countText"] ? self.countLabel.text : @"已处理群数，不代表已送达";
        self.countLabel.adjustsFontSizeToFitWidth = preview;
        self.countLabel.minimumScaleFactor = 0.75;
        self.phaseLabel.text = [@{@"running": @"转发中", @"paused": @"已暂停", @"settling": @"在途处理中",
            @"ready": @"待转发", @"waiting": @"等待消息", @"completed": @"本次执行结束", @"idle": @"快捷入口"} objectForKey:phase] ?: @"状态待核对";
        self.phaseLabel.textColor = [phase isEqual:@"running"] ? SRSettingsAccent() : UIColor.secondaryLabelColor;
        NSString *title = @"继续";
        if (preview) title = @"转发分组";
        else if ([phase isEqual:@"settling"]) title = @"等待";
        else if ([phase isEqual:@"completed"] && self.closeResultAction) title = @"关闭";
        else if ([model[@"action"] isEqual:@"pause"]) title = @"暂停";
        else if ([model[@"action"] isEqual:@"open"]) title = @"查看";
        [self.actionButton setTitle:title forState:UIControlStateNormal];
        [self.menuButton setTitle:preview ? @"忽略这条" : @"..." forState:UIControlStateNormal];
        self.actionButton.enabled = [model[@"actionEnabled"] boolValue];
        self.menuButton.hidden = ![model[@"menuEnabled"] boolValue];
        self.actionButton.accessibilityLabel = preview ? @"转发分组，打开分组列表，不会发送" :
            ([model[@"action"] isEqual:@"pause"] ? @"暂停转发，不撤回在途消息" :
            ([model[@"action"] isEqual:@"open"] ? @"打开群同步" : @"继续未尝试的群，不重发未知结果"));
        if ([phase isEqual:@"completed"] && self.closeResultAction)
            self.actionButton.accessibilityLabel = @"关闭本次结果摘要，保留转发记录";
    }
    [self place];
    self.actionButton.enabled = [model[@"actionEnabled"] boolValue];
    [self layoutIfNeeded];
    if (entering && !UIAccessibilityIsReduceMotionEnabled()) {
        self.alpha = 0;
        [UIView animateWithDuration:0.18 animations:^{ self.alpha = 1; }];
    }
}
- (void)updatePreviewControls {
    self.countLabel.hidden = self.previewCollapsed;
    self.menuButton.hidden = self.previewCollapsed;
    [self.actionButton setTitle:self.previewCollapsed ? @"1 条待同步 · 展开" : @"转发分组" forState:UIControlStateNormal];
    self.actionButton.accessibilityLabel = self.previewCollapsed ? @"展开待同步消息" : @"转发分组，打开分组列表，不会发送";
}
- (void)togglePreview {
    self.previewCollapsed = !self.previewCollapsed;
    [self updatePreviewControls];
    [self place];
}
- (void)hide { [self removeFromSuperview]; self.model = nil; }
- (void)pressed {
    if ([self.model[@"phase"] isEqual:@"preview"] && self.previewCollapsed) { [self togglePreview]; return; }
    if ([self.model[@"phase"] isEqual:@"completed"] && self.closeResultAction) { self.closeResultAction(); return; }
    self.actionButton.enabled = NO;
    if ([self.model[@"action"] isEqual:@"open"]) { if (self.openAction) self.openAction(); }
    else if (self.action) self.action();
}
/* Restoring from the edge changes only the display shape, never the run. */
- (void)restoreFromDock {
    self.docked = NO; self.progressExpanded = NO; self.previewCollapsed = YES;
    if (UIAccessibilityIsReduceMotionEnabled()) [self place];
    else [UIView animateWithDuration:0.18 animations:^{ [self place]; }];
}
- (void)openPressed {
    if (self.docked) { [self restoreFromDock]; return; }
    if ([self.model[@"phase"] isEqual:@"idle"]) { if (self.openAction) self.openAction(); return; }
    if ([self.model[@"phase"] isEqual:@"preview"]) [self togglePreview];
    else { self.progressExpanded = !self.progressExpanded; [self place]; }
}
- (BOOL)accessibilityActivate {
    [self openPressed]; return YES;
}
- (void)menuPressed {
    if (self.progressExpanded && ![self.model[@"phase"] isEqual:@"preview"]) { if (self.openAction) self.openAction(); }
    else if (self.menuAction) self.menuAction();
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if (![gestureRecognizer isKindOfClass:UITapGestureRecognizer.class]) return YES;
    UIView *view = touch.view;
    return view != self.actionButton && view != self.menuButton && ![view isDescendantOfView:self.actionButton] && ![view isDescendantOfView:self.menuButton];
}
- (void)keyboardChanged:(NSNotification *)notification {
    self.keyboardFrame = [notification.name isEqual:UIKeyboardWillHideNotification] ? CGRectZero : [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    [self place];
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    /* Leave the outermost left-edge strip to the host's back gesture. The
     * right handle can use the full 44pt target without painting it wider. */
    if (self.docked && self.unitX < 0.5 && point.x < 20) return NO;
    return [super pointInside:point withEvent:event];
}
- (void)drag:(UIPanGestureRecognizer *)pan {
    if (!self.window) return;
    if (pan.state == UIGestureRecognizerStateBegan) {
        self.dragging = YES; self.dragStartFrame = self.frame; self.dragStartedDocked = self.docked;
    }
    CGPoint translation = [pan translationInView:self.window];
    CGRect bounds = [self availableBounds];
    BOOL inward = SRCapsuleRestoresInward(translation.x, self.unitX < 0.5);
    if (self.docked && inward) {
        self.docked = NO; self.progressExpanded = NO; self.previewCollapsed = YES;
        self.dragging = NO; [self place]; self.dragging = YES;
        self.dragStartFrame = self.frame; [pan setTranslation:CGPointZero inView:self.window]; translation = CGPointZero;
    }
    CGRect frame = self.dragStartFrame; frame.origin.x += translation.x; frame.origin.y += translation.y;
    CGFloat desiredX = frame.origin.x;
    frame.origin.x = self.docked ? SRCapsuleHandleOriginX(CGRectGetWidth(self.window.bounds), self.unitX < 0.5) :
        MAX(CGRectGetMinX(bounds), MIN(frame.origin.x, CGRectGetMaxX(bounds) - frame.size.width));
    frame.origin.y = MAX(CGRectGetMinY(bounds), MIN(frame.origin.y, CGRectGetMaxY(bounds) - frame.size.height)); self.frame = frame;
    if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled || pan.state == UIGestureRecognizerStateFailed) {
        self.dragging = NO;
        CGFloat travelX = bounds.size.width - frame.size.width;
        CGFloat travelY = bounds.size.height - frame.size.height;
        /* Merely touching an edge never docks. Only an intentional outward
         * overshoot on a successfully ended drag changes the display shape. */
        int side = SRCapsuleDockSide(desiredX, CGRectGetMinX(bounds), CGRectGetMaxX(bounds) - frame.size.width,
            pan.state == UIGestureRecognizerStateEnded, self.dragStartedDocked);
        if (side && ![self.model[@"phase"] isEqual:@"idle"]) {
            self.docked = YES; self.unitX = side < 0 ? 0 : 1;
            self.previewCollapsed = YES; self.progressExpanded = NO;
        } else if (!self.docked) self.unitX = travelX > 0 ? MAX(0, MIN(1, (frame.origin.x - bounds.origin.x) / travelX)) : 1;
        self.unitY = travelY > 0 ? MAX(0, MIN(1, (frame.origin.y - bounds.origin.y) / travelY)) : 0;
        if (self.positionChanged) self.positionChanged(self.unitX, self.unitY);
        if (UIAccessibilityIsReduceMotionEnabled()) [self place];
        else [UIView animateWithDuration:0.18 animations:^{ [self place]; }];
    }
}
@end
