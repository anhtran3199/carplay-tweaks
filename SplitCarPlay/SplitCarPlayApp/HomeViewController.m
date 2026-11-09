//
//  HomeViewController.m -- "Trang chủ" tab
//
//  One switch, like SidePlay2's: "Đang bật" shows the picked apps on the
//  car screen every time CarPlay connects (pref carPlayAutoHost, read by
//  Tweak.xm in SpringBoard). Above it nothing else competes: a 3-step
//  checklist only while setup isn't done, then the CarPlay status card
//  (status SpringBoard publishes with SCPGetCarPlayState) with the two
//  apps that will show on the car.
//
//  If SpringBoard dies during a CarPlay session, it switches "Đang bật"
//  off on its next start and sets carPlayCrashNotice, shown here until the
//  switch is turned back on.
//
#import <UIKit/UIKit.h>
#import "../SplitCarPlayShared.h"

extern void SplitCarPlaySetPref(NSString *key, id value);                 // AppPickerController.m
extern NSString *SplitCarPlayDisplayNameForBundleID(NSString *bundleID);  // AppPickerController.m
extern UIImage *SplitCarPlayAppIcon(NSString *bundleID);                  // AppPickerController.m

@interface OnCarViewController : UIViewController
+ (UIViewController *)quickOpenPage; // "App khi cắm xe"
@end

static NSString * const kSCPHomeLogPath = @"/var/mobile/Library/Logs/splitcarplay_hosting.log";

static UIImageView *SCPHomeSymbolView(NSString *name, CGFloat size, UIColor *tint) {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:size weight:UIImageSymbolWeightRegular];
    UIImageView *view = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:name withConfiguration:config]];
    view.tintColor = tint;
    view.contentMode = UIViewContentModeCenter;
    return view;
}

static BOOL SCPHomeTweakInstalled(void) {
    NSFileManager *files = [NSFileManager defaultManager];
    return [files fileExistsAtPath:@"/var/jb/Library/MobileSubstrate/DynamicLibraries/SplitCarPlay.dylib"]
        || [files fileExistsAtPath:@"/Library/MobileSubstrate/DynamicLibraries/SplitCarPlay.dylib"];
}

// A 44pt row: status mark, text, optional chevron. Tappable when it has a target.
static UIButton *SCPHomeRowButton(void) {
    UIButton *row = [UIButton buttonWithType:UIButtonTypeCustom];
    UIImageView *mark = [[UIImageView alloc] init];
    mark.tag = 101;
    mark.contentMode = UIViewContentModeCenter;
    [row addSubview:mark];
    UILabel *label = [[UILabel alloc] init];
    label.tag = 102;
    label.font = [UIFont systemFontOfSize:15];
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.85;
    [row addSubview:label];
    UIImageView *chevron = SCPHomeSymbolView(@"chevron.right", 13, [UIColor tertiaryLabelColor]);
    chevron.tag = 103;
    [row addSubview:chevron];
    return row;
}

#pragma mark - Motion helpers

// Non-essential motion is skipped with Reduce Motion on; colour/opacity
// fades still run (they aren't motion).
static inline BOOL SCPHomeReduceMotion(void) {
    return UIAccessibilityIsReduceMotionEnabled();
}

// Sets a CALayer colour property (borderColor...), optionally fading from
// what is on screen now. Layer-only, so frames set by layout stay untouched.
static void SCPHomeSetLayerColor(CALayer *layer, NSString *key, UIColor *color, BOOL animated) {
    id to = (__bridge id)color.CGColor;
    if (animated) {
        CALayer *current = layer.presentationLayer ?: layer;
        CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:key];
        fade.fromValue = [current valueForKey:key];
        fade.toValue = to;
        fade.duration = 0.3;
        [layer addAnimation:fade forKey:[@"scpFade." stringByAppendingString:key]];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES]; // stand-alone layers would add their own implicit animation
    [layer setValue:to forKey:key];
    [CATransaction commit];
}

// Endless back-and-forth loop. Kept on the layer when the app is
// backgrounded (removedOnCompletion NO); removed explicitly instead.
static CAAnimationGroup *SCPHomeLoopGroup(NSArray<CAAnimation *> *parts, CFTimeInterval duration, BOOL autoreverses) {
    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.animations = parts;
    group.duration = duration;
    group.autoreverses = autoreverses;
    group.repeatCount = HUGE_VALF;
    group.removedOnCompletion = NO;
    return group;
}

static CABasicAnimation *SCPHomeBasic(NSString *keyPath, id from, id to, CFTimeInterval duration, NSString *timing) {
    CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:keyPath];
    animation.fromValue = from;
    animation.toValue = to;
    animation.duration = duration;
    animation.timingFunction = [CAMediaTimingFunction functionWithName:timing];
    return animation;
}

// One-shot "pop" on transform.scale. Presentation-only, so it doesn't
// fight the frames layout sets.
static void SCPHomePop(CALayer *layer, NSArray<NSNumber *> *values, CFTimeInterval duration) {
    if (SCPHomeReduceMotion()) return;
    CAKeyframeAnimation *pop = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
    pop.values = values;
    pop.duration = duration;
    pop.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [layer addAnimation:pop forKey:@"scpPop"];
}

@interface HomeViewController : UIViewController
@end

@implementation HomeViewController {
    UIScrollView *_scroll;
    UIImageView *_logo;
    UILabel *_titleLabel;
    UILabel *_versionLabel;

    UILabel *_switchTitle;
    UILabel *_switchSubtitle;
    UISwitch *_mainSwitch;

    UIView *_noticeBox;
    UILabel *_noticeLabel;
    UIButton *_noticeButton;

    UIView *_setupCard;      // shown until the 3 steps are done
    UILabel *_setupTitle;
    NSArray<UIButton *> *_setupRows;

    UIView *_statusCard;
    UIView *_phoneShape;
    UIView *_linkDots;
    UIView *_carShape;
    UIImageView *_carIcon;
    UIView *_statusDot;
    UILabel *_statusLabel;
    UIView *_appsSeparator;
    UIButton *_appsRow;      // Ô 1 / Ô 2, opens "App khi cắm xe"
    UIImageView *_leftIcon;
    UIImageView *_rightIcon;
    UILabel *_appsLabel;

    UIButton *_respringButton; // "Khởi động lại SpringBoard"

    // Status card motion (see "Status card motion" below)
    UIView *_miniSplit;      // two panes + divider inside the car while showing
    UIView *_miniLeft;
    UIView *_miniRight;
    UIView *_miniDivider;
    CAShapeLayer *_searchRing; // faint ring sweeping out of the phone while disconnected
    CALayer *_packet;          // glowing dot travelling phone -> car while connected
    uint64_t _shownState;      // CarPlay state the card currently shows
    BOOL _hasShownState;
    BOOL _cardMotionActive;    // between viewWillAppear and viewWillDisappear
    NSInteger _setupDoneMask;  // done steps last refresh (bit per row), -1 = not known yet

    NSTimer *_statusTimer;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    _scroll = [[UIScrollView alloc] init];
    _scroll.alwaysBounceVertical = YES;
    _scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever; // laid out from the safe area by hand
    [self.view addSubview:_scroll];

    // Header: the app icon (Resources/AppIcon60x60@2x.png, drawn by Icon/make_icon.py), name, version
    _logo = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"AppIcon60x60"]];
    _logo.layer.cornerRadius = 12;
    _logo.layer.cornerCurve = kCACornerCurveContinuous;
    _logo.clipsToBounds = YES;
    [_scroll addSubview:_logo];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.text = @"SplitCarPlay";
    _titleLabel.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    [_scroll addSubview:_titleLabel];

    _versionLabel = [[UILabel alloc] init];
    NSString *version = [NSBundle mainBundle].infoDictionary[@"CFBundleShortVersionString"] ?: @"";
    _versionLabel.text = [NSString stringWithFormat:@"Phiên bản %@", version];
    _versionLabel.font = [UIFont systemFontOfSize:13];
    _versionLabel.textColor = [UIColor secondaryLabelColor];
    [_scroll addSubview:_versionLabel];

    // The switch
    _switchTitle = [[UILabel alloc] init];
    _switchTitle.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
    [_scroll addSubview:_switchTitle];

    _switchSubtitle = [[UILabel alloc] init];
    _switchSubtitle.font = [UIFont systemFontOfSize:13];
    _switchSubtitle.numberOfLines = 0;
    [_scroll addSubview:_switchSubtitle];

    _mainSwitch = [[UISwitch alloc] init];
    _mainSwitch.onTintColor = [UIColor systemGreenColor];
    _mainSwitch.transform = CGAffineTransformMakeScale(1.15, 1.15);
    [_mainSwitch addTarget:self action:@selector(mainSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    [_scroll addSubview:_mainSwitch];

    // Crash notice (hidden unless SpringBoard switched it off)
    _noticeBox = [[UIView alloc] init];
    _noticeBox.backgroundColor = [[UIColor systemYellowColor] colorWithAlphaComponent:0.22];
    _noticeBox.layer.cornerRadius = 12;
    [_scroll addSubview:_noticeBox];
    _noticeLabel = [[UILabel alloc] init];
    _noticeLabel.font = [UIFont systemFontOfSize:13];
    _noticeLabel.numberOfLines = 0;
    _noticeLabel.text = @"⚠️ SpringBoard bị lỗi khi đang hiện trên CarPlay nên đã tự tắt. Gửi log để sửa, rồi bật lại.";
    [_noticeBox addSubview:_noticeLabel];
    _noticeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_noticeButton setTitle:@"Gửi log" forState:UIControlStateNormal];
    _noticeButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [_noticeButton addTarget:self action:@selector(shareLog:) forControlEvents:UIControlEventTouchUpInside];
    [_noticeBox addSubview:_noticeButton];

    // Setup checklist
    _setupCard = [[UIView alloc] init];
    _setupCard.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    _setupCard.layer.cornerRadius = 12;
    [_scroll addSubview:_setupCard];
    _setupTitle = [[UILabel alloc] init];
    _setupTitle.text = @"BẮT ĐẦU";
    _setupTitle.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    _setupTitle.textColor = [UIColor secondaryLabelColor];
    [_setupCard addSubview:_setupTitle];
    NSMutableArray *rows = [NSMutableArray new];
    for (int i = 0; i < 3; i++) {
        UIButton *row = SCPHomeRowButton();
        row.tag = i;
        [row addTarget:self action:@selector(setupRowTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_setupCard addSubview:row];
        [rows addObject:row];
    }
    _setupRows = rows;

    // Status card: phone ··· car, then the two apps
    _statusCard = [[UIView alloc] init];
    _statusCard.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    _statusCard.layer.cornerRadius = 16;
    [_scroll addSubview:_statusCard];

    _phoneShape = [[UIView alloc] init];
    _phoneShape.layer.borderWidth = 2;
    _phoneShape.layer.cornerRadius = 8;
    [_statusCard addSubview:_phoneShape];

    _linkDots = [[UIView alloc] init];
    [_statusCard addSubview:_linkDots];

    _carShape = [[UIView alloc] init];
    _carShape.layer.borderWidth = 1;
    _carShape.layer.cornerRadius = 12;
    [_statusCard addSubview:_carShape];
    _carIcon = SCPHomeSymbolView(@"car.fill", 22, [UIColor secondaryLabelColor]);
    [_carShape addSubview:_carIcon];

    // Mini split screen (Ô 1 | Ô 2) that replaces the car glyph while the
    // apps are on the car. Decorative only; the status label says it too.
    _miniSplit = [[UIView alloc] init];
    _miniSplit.userInteractionEnabled = NO;
    _miniSplit.alpha = 0;
    [_carShape addSubview:_miniSplit];
    _miniLeft = [[UIView alloc] init];
    _miniRight = [[UIView alloc] init];
    for (UIView *pane in @[_miniLeft, _miniRight]) {
        pane.layer.cornerRadius = 5;
        [_miniSplit addSubview:pane];
    }
    _miniDivider = [[UIView alloc] init];
    _miniDivider.layer.cornerRadius = 1;
    [_miniSplit addSubview:_miniDivider];

    // Plain layers owned by the card; invisible (opacity 0) unless animating.
    _searchRing = [CAShapeLayer layer];
    _searchRing.fillColor = [UIColor clearColor].CGColor;
    _searchRing.lineWidth = 1.5;
    _searchRing.opacity = 0;
    [_statusCard.layer insertSublayer:_searchRing below:_phoneShape.layer];
    _packet = [CALayer layer];
    _packet.bounds = CGRectMake(0, 0, 7, 7);
    _packet.cornerRadius = 3.5;
    _packet.shadowOpacity = 0.9;
    _packet.shadowRadius = 4;
    _packet.shadowOffset = CGSizeZero;
    _packet.opacity = 0;
    [_statusCard.layer addSublayer:_packet];

    _statusDot = [[UIView alloc] init];
    _statusDot.layer.cornerRadius = 4;
    [_statusCard addSubview:_statusDot];
    _statusLabel = [[UILabel alloc] init];
    _statusLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    [_statusCard addSubview:_statusLabel];

    _appsSeparator = [[UIView alloc] init];
    _appsSeparator.backgroundColor = [UIColor separatorColor];
    [_statusCard addSubview:_appsSeparator];
    _appsRow = [UIButton buttonWithType:UIButtonTypeCustom];
    [_appsRow addTarget:self action:@selector(openQuickOpen) forControlEvents:UIControlEventTouchUpInside];
    _appsRow.accessibilityLabel = @"App khi cắm xe";
    [_statusCard addSubview:_appsRow];
    _leftIcon = [[UIImageView alloc] init];
    _rightIcon = [[UIImageView alloc] init];
    for (UIImageView *icon in @[_leftIcon, _rightIcon]) {
        icon.layer.cornerRadius = 7;
        icon.clipsToBounds = YES;
        icon.userInteractionEnabled = NO;
        [_appsRow addSubview:icon];
    }
    _appsLabel = [[UILabel alloc] init];
    _appsLabel.font = [UIFont systemFontOfSize:15];
    _appsLabel.userInteractionEnabled = NO;
    [_appsRow addSubview:_appsLabel];
    UIImageView *chevron = SCPHomeSymbolView(@"chevron.right", 13, [UIColor tertiaryLabelColor]);
    chevron.tag = 103;
    chevron.userInteractionEnabled = NO;
    [_appsRow addSubview:chevron];

    // Respring: for when the car screen or the live preview gets stuck.
    _respringButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *respringConfig = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];
    [_respringButton setImage:[UIImage systemImageNamed:@"arrow.clockwise.circle.fill" withConfiguration:respringConfig] forState:UIControlStateNormal];
    [_respringButton setTitle:@"  Khởi động lại SpringBoard" forState:UIControlStateNormal];
    _respringButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _respringButton.tintColor = [UIColor systemRedColor];
    _respringButton.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    _respringButton.layer.cornerRadius = 12;
    [_respringButton addTarget:self action:@selector(confirmRespring) forControlEvents:UIControlEventTouchUpInside];
    [_scroll addSubview:_respringButton];

    // Loops are restarted if Reduce Motion changes, or after coming back
    // from the background (iOS may drop running layer animations there).
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(startCardAnimations)
                                                 name:UIAccessibilityReduceMotionStatusDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(startCardAnimations)
                                                 name:UIApplicationWillEnterForegroundNotification object:nil];

    _setupDoneMask = -1;
    [self refresh];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // The header above is the title; no navigation bar repeating it.
    [self.navigationController setNavigationBarHidden:YES animated:animated];
    _cardMotionActive = YES;
    _hasShownState = NO; // repaint the card and restart its loops for whatever the state is now
    [self refresh];
    [_statusTimer invalidate];
    _statusTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(refreshStatus) userInfo:nil repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_statusTimer invalidate];
    _statusTimer = nil;
    _cardMotionActive = NO; // no animation work while the tab is hidden
    [self stopCardAnimations];
}

- (void)mainSwitchChanged:(UISwitch *)sender {
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
    if (sender.on) {
        SplitCarPlaySetPref(@"carPlayCrashNotice", @NO);
        SplitCarPlaySetPref(@"enabled", @YES);
    }
    SplitCarPlaySetPref(@"carPlayAutoHost", @(sender.on));
    [self refresh];
}

- (void)confirmRespring {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Khởi động lại SpringBoard?"
                                                                   message:@"Màn hình sẽ tắt vài giây rồi về màn hình khoá. Dùng khi màn hình xe hoặc Mô phỏng bị kẹt."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Khởi động lại" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        notify_post(SCP_RESPRING_NOTIFICATION); // handled by Tweak.xm in SpringBoard
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)openQuickOpen {
    UIViewController *page = [OnCarViewController quickOpenPage];
    if (!page) return;
    [self.navigationController setNavigationBarHidden:NO animated:YES];
    [self.navigationController pushViewController:page animated:YES];
}

- (void)setupRowTapped:(UIButton *)sender {
    if (sender.tag == 1) {
        [self openQuickOpen];
    } else if (sender.tag == 2 && !_mainSwitch.on) {
        [_mainSwitch setOn:YES animated:YES];
        [self mainSwitchChanged:_mainSwitch];
    }
}

// Shares a copy (in this app's tmp folder) so the receiving app can read it.
- (void)shareLog:(UIView *)sender {
    NSData *data = [NSData dataWithContentsOfFile:kSCPHomeLogPath];
    if (data.length == 0) return;
    NSString *copyPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"splitcarplay_hosting.log"];
    [data writeToFile:copyPath atomically:YES];
    UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:copyPath]]
                                                                        applicationActivities:nil];
    sheet.popoverPresentationController.sourceView = sender;
    sheet.popoverPresentationController.sourceRect = sender.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)configureRow:(UIButton *)row done:(BOOL)done text:(NSString *)text tappable:(BOOL)tappable {
    UIImageView *mark = [row viewWithTag:101];
    UILabel *label = [row viewWithTag:102];
    UIView *chevron = [row viewWithTag:103];
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold];
    mark.image = [UIImage systemImageNamed:done ? @"checkmark.circle.fill" : @"circle" withConfiguration:config];
    mark.tintColor = done ? [UIColor systemGreenColor] : [UIColor tertiaryLabelColor];
    label.text = text;
    label.textColor = done ? [UIColor secondaryLabelColor] : [UIColor labelColor];
    chevron.hidden = done || !tappable;
    row.userInteractionEnabled = !done && tappable;
}

- (void)refresh {
    NSDictionary *prefs = SCPCopyPrefs();
    BOOL onScreen = self.view.window != nil;
    BOOL on = SCPIsCarPlayOn(prefs);
    _mainSwitch.on = on;
    NSString *switchTitle = on ? @"Đang bật" : @"Đang tắt";
    if (onScreen && _switchTitle.text && ![_switchTitle.text isEqualToString:switchTitle]) {
        // Crossfade the on/off wording and its colour instead of snapping.
        UIViewAnimationOptions fade = UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction;
        [UIView transitionWithView:_switchTitle duration:0.25 options:fade animations:nil completion:nil];
        [UIView transitionWithView:_switchSubtitle duration:0.25 options:fade animations:nil completion:nil];
    }
    _switchTitle.text = switchTitle;
    _switchSubtitle.text = on ? @"Cắm CarPlay là app tự hiện trên màn hình xe." : @"Bật để hiện app trên màn hình xe mỗi khi cắm CarPlay.";
    _switchSubtitle.textColor = on ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];

    NSString *leftID = prefs[@"leftBundleID"];
    NSString *rightID = prefs[@"rightBundleID"];
    BOOL single = [prefs[@"experimentalSingleApp"] boolValue];
    BOOL hasApp = leftID.length > 0;
    BOOL tweak = SCPHomeTweakInstalled();

    // A step that just turned done (seen on screen): success haptic, and
    // its mark crossfades to the green check with a small pop.
    NSInteger doneMask = (tweak ? 1 : 0) | (hasApp ? 2 : 0) | (on ? 4 : 0);
    NSInteger newlyDone = _setupDoneMask >= 0 ? (doneMask & ~_setupDoneMask) : 0;
    _setupDoneMask = doneMask;
    BOOL celebrate = newlyDone != 0 && onScreen && !_setupCard.hidden;
    if (celebrate) {
        for (NSUInteger i = 0; i < _setupRows.count; i++) {
            if (!(newlyDone & (1 << i))) continue;
            UIView *mark = [_setupRows[i] viewWithTag:101];
            [UIView transitionWithView:mark duration:0.25 options:UIViewAnimationOptionTransitionCrossDissolve animations:nil completion:nil];
            SCPHomePop(mark.layer, @[@0.6, @1.15, @1.0], 0.35);
        }
        UINotificationFeedbackGenerator *haptic = [[UINotificationFeedbackGenerator alloc] init];
        [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];
    }
    [self configureRow:_setupRows[0] done:tweak
                  text:tweak ? @"Tweak đã cài" : @"Cài SplitCarPlay từ Sileo rồi respring" tappable:NO];
    [self configureRow:_setupRows[1] done:hasApp text:hasApp ? @"Đã chọn app" : @"Chọn app cho ô 1 và ô 2" tappable:YES];
    [self configureRow:_setupRows[2] done:on text:on ? @"Đã bật" : @"Bật \"Đang bật\" rồi cắm CarPlay" tappable:YES];

    _leftIcon.image = SplitCarPlayAppIcon(leftID);
    _rightIcon.image = single ? nil : SplitCarPlayAppIcon(rightID);
    _rightIcon.hidden = single || rightID.length == 0;
    if (!hasApp) {
        _appsLabel.text = @"Chưa chọn app · Chọn ngay";
        _appsLabel.textColor = [UIColor systemBlueColor];
    } else {
        NSString *left = SplitCarPlayDisplayNameForBundleID(leftID);
        NSString *right = rightID.length ? SplitCarPlayDisplayNameForBundleID(rightID) : nil;
        _appsLabel.text = (single || !right) ? [NSString stringWithFormat:@"%@ · 1 app", left]
                                             : [NSString stringWithFormat:@"%@ + %@", left, right];
        _appsLabel.textColor = [UIColor labelColor];
    }
    [self setNoticeHidden:![prefs[@"carPlayCrashNotice"] boolValue] setupHidden:(tweak && hasApp && on)];
    [self refreshStatus];
    [self.view setNeedsLayout];
}

// Leaving card: a snapshot fades out where it was (the real one is hidden
// at once, so layout never counts it).
- (void)addGhostOf:(UIView *)card to:(NSMutableArray<UIView *> *)ghosts {
    UIView *ghost = [card snapshotViewAfterScreenUpdates:NO];
    if (!ghost) return;
    ghost.frame = card.frame;
    ghost.userInteractionEnabled = NO;
    [_scroll insertSubview:ghost belowSubview:_statusCard];
    [ghosts addObject:ghost];
}

// Shows/hides the crash notice and the setup checklist. On screen the
// cards below slide to their new spots and the changed card fades, instead
// of everything jumping: lay out the end state, then animate from the old
// frames.
- (void)setNoticeHidden:(BOOL)noticeHidden setupHidden:(BOOL)setupHidden {
    BOOL noticeChanges = _noticeBox.hidden != noticeHidden;
    BOOL setupChanges = _setupCard.hidden != setupHidden;
    if ((!noticeChanges && !setupChanges) || !self.view.window || _statusCard.bounds.size.width <= 0) {
        _noticeBox.hidden = noticeHidden;
        _setupCard.hidden = setupHidden;
        return;
    }
    NSMutableArray<UIView *> *ghosts = [NSMutableArray new];
    if (noticeChanges && noticeHidden) [self addGhostOf:_noticeBox to:ghosts];
    if (setupChanges && setupHidden) [self addGhostOf:_setupCard to:ghosts];

    NSArray<UIView *> *cards = @[_noticeBox, _setupCard, _statusCard];
    NSMutableArray<NSValue *> *before = [NSMutableArray new];
    for (UIView *card in cards) [before addObject:[NSValue valueWithCGRect:card.frame]];
    UIView *appearingNotice = nil;
    if (noticeChanges && !noticeHidden) appearingNotice = _noticeBox;
    UIView *appearingSetup = (setupChanges && !setupHidden) ? _setupCard : nil;

    _noticeBox.hidden = noticeHidden;
    _setupCard.hidden = setupHidden;
    [self.view setNeedsLayout];
    [UIView performWithoutAnimation:^{ [self.view layoutIfNeeded]; }];

    BOOL reduce = SCPHomeReduceMotion();
    NSMutableArray<UIView *> *movers = [NSMutableArray new];
    NSMutableArray<NSValue *> *targets = [NSMutableArray new];
    for (NSUInteger i = 0; i < cards.count; i++) {
        UIView *card = cards[i];
        CGRect from = before[i].CGRectValue;
        if (card.hidden || card == appearingNotice || card == appearingSetup || CGRectIsEmpty(from) || reduce) continue;
        if (CGRectEqualToRect(from, card.frame)) continue;
        [movers addObject:card];
        [targets addObject:[NSValue valueWithCGRect:card.frame]];
        card.frame = from;
    }
    appearingNotice.alpha = 0;
    appearingSetup.alpha = 0;
    [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0
                        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        for (NSUInteger i = 0; i < movers.count; i++) movers[i].frame = targets[i].CGRectValue;
        appearingNotice.alpha = 1;
        appearingSetup.alpha = 1;
        for (UIView *ghost in ghosts) ghost.alpha = 0;
    } completion:^(BOOL finished) {
        for (UIView *ghost in ghosts) [ghost removeFromSuperview];
        appearingNotice.alpha = 1;
        appearingSetup.alpha = 1;
    }];
}

#pragma mark - Status card motion

// Colours, label and the car's glyph for _shownState.
- (void)applyStatusLookAnimated:(BOOL)animated {
    uint64_t state = _shownState;
    UIColor *color = [UIColor systemGrayColor];
    NSString *text = @"Chưa kết nối CarPlay";
    if (state == SCPCarPlayStateShowing) {
        color = [UIColor systemGreenColor];
        text = @"Đang hiển thị trên CarPlay";
    } else if (state == SCPCarPlayStateConnected) {
        color = [UIColor systemBlueColor];
        text = @"Đã kết nối CarPlay";
    }
    BOOL connected = state != SCPCarPlayStateDisconnected;
    BOOL showing = state == SCPCarPlayStateShowing;
    UITraitCollection *traits = self.traitCollection;
    UIColor *lineColor = [(connected ? color : [UIColor tertiaryLabelColor]) resolvedColorWithTraitCollection:traits];
    UIColor *carFill = connected ? [color colorWithAlphaComponent:0.08] : [UIColor tertiarySystemFillColor];
    UIColor *iconTint = connected ? color : [UIColor secondaryLabelColor];
    NSArray<UIView *> *dots = _linkDots.subviews;
    UIView *statusDot = _statusDot, *carShape = _carShape, *carIcon = _carIcon, *miniSplit = _miniSplit;
    UILabel *statusLabel = _statusLabel;

    void (^colors)(void) = ^{
        statusDot.backgroundColor = color;
        carShape.backgroundColor = carFill;
        for (UIView *dot in dots) dot.backgroundColor = lineColor;
        carIcon.alpha = showing ? 0 : 1;   // the mini split screen stands in for the car glyph
        miniSplit.alpha = showing ? 1 : 0;
    };
    if (animated) {
        UIViewAnimationOptions fade = UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction;
        [UIView transitionWithView:statusLabel duration:0.3 options:fade animations:^{ statusLabel.text = text; } completion:nil];
        [UIView transitionWithView:carIcon duration:0.3 options:fade animations:^{ carIcon.tintColor = iconTint; } completion:nil];
        [UIView animateWithDuration:0.3 delay:0
                            options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                         animations:colors completion:nil];
        if (showing) SCPHomePop(_miniSplit.layer, @[@0.6, @1.05, @1.0], 0.4); // split screen grows in
    } else {
        statusLabel.text = text;
        carIcon.tintColor = iconTint;
        colors();
    }
    SCPHomeSetLayerColor(_phoneShape.layer, @"borderColor", lineColor, animated);
    SCPHomeSetLayerColor(_carShape.layer, @"borderColor", lineColor, animated);

    UIColor *resolved = [color resolvedColorWithTraitCollection:traits];
    _miniLeft.backgroundColor = [resolved colorWithAlphaComponent:0.28];
    _miniRight.backgroundColor = [resolved colorWithAlphaComponent:0.28];
    _miniDivider.backgroundColor = resolved;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _packet.backgroundColor = resolved.CGColor;
    _packet.shadowColor = resolved.CGColor;
    _searchRing.strokeColor = [[UIColor secondaryLabelColor] resolvedColorWithTraitCollection:traits].CGColor;
    [CATransaction commit];
}

- (void)stopCardAnimations {
    [_phoneShape.layer removeAnimationForKey:@"scpBreathe"];
    [_searchRing removeAnimationForKey:@"scpSweep"];
    [_packet removeAnimationForKey:@"scpPacket"];
    [_statusDot.layer removeAnimationForKey:@"scpPulse"];
    for (UIView *dot in _linkDots.subviews) [dot.layer removeAnimationForKey:@"scpFlow"];
}

// The loops for _shownState. Started on appear, on a state change and when
// the dots were rebuilt -- never by the 1 s status timer on its own.
- (void)startCardAnimations {
    [self stopCardAnimations];
    if (!_cardMotionActive || !_hasShownState || SCPHomeReduceMotion()) return;
    NSString *easeInOut = kCAMediaTimingFunctionEaseInEaseOut;

    if (_shownState == SCPCarPlayStateDisconnected) {
        // Idle: the phone gently breathes and a faint ring sweeps out of it,
        // "looking" for the car. Dots and car stay dim and still.
        CAAnimationGroup *breathe = SCPHomeLoopGroup(@[
            SCPHomeBasic(@"transform.scale", @1.0, @1.03, 1.0, easeInOut),
            SCPHomeBasic(@"opacity", @1.0, @0.7, 1.0, easeInOut),
        ], 1.0, YES);
        [_phoneShape.layer addAnimation:breathe forKey:@"scpBreathe"];
        CAAnimationGroup *sweep = SCPHomeLoopGroup(@[
            SCPHomeBasic(@"transform.scale", @0.7, @1.4, 1.6, kCAMediaTimingFunctionEaseOut),
            SCPHomeBasic(@"opacity", @0.45, @0.0, 1.6, kCAMediaTimingFunctionEaseOut),
        ], 2.5, NO);
        [_searchRing addAnimation:sweep forKey:@"scpSweep"];
        return;
    }

    BOOL showing = _shownState == SCPCarPlayStateShowing;
    // Dots light up one after another towards the car (each runs the same
    // loop, phase-shifted so later dots peak later).
    CFTimeInterval flow = 1.2;
    NSArray<UIView *> *dots = _linkDots.subviews;
    for (NSUInteger i = 0; i < dots.count; i++) {
        CAKeyframeAnimation *wave = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
        wave.values = @[@0.3, @1.0, @0.3];
        wave.keyTimes = @[@0, @0.5, @1];
        wave.duration = flow;
        wave.repeatCount = HUGE_VALF;
        wave.removedOnCompletion = NO;
        wave.timeOffset = flow - fmod(i * 0.1, flow);
        [dots[i].layer addAnimation:wave forKey:@"scpFlow"];
    }
    // A glowing packet travels phone -> car: with a pause while only
    // connected, back to back while the apps are showing.
    CGRect link = _linkDots.frame;
    if (link.size.width > 12) {
        CGFloat y = CGRectGetMidY(link);
        CABasicAnimation *travel = SCPHomeBasic(@"position", [NSValue valueWithCGPoint:CGPointMake(CGRectGetMinX(link), y)],
                                                [NSValue valueWithCGPoint:CGPointMake(CGRectGetMaxX(link), y)], 1.2, easeInOut);
        CAKeyframeAnimation *glow = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
        glow.values = @[@0, @1, @1, @0];
        glow.keyTimes = @[@0, @0.15, @0.85, @1];
        glow.duration = 1.2;
        [_packet addAnimation:SCPHomeLoopGroup(@[travel, glow], showing ? 1.2 : 2.0, NO) forKey:@"scpPacket"];
    }
    CAAnimationGroup *pulse = SCPHomeLoopGroup(@[
        SCPHomeBasic(@"opacity", @1.0, @0.4, showing ? 0.7 : 1.0, easeInOut),
        SCPHomeBasic(@"transform.scale", @1.0, @1.3, showing ? 0.7 : 1.0, easeInOut),
    ], showing ? 0.7 : 1.0, YES);
    [_statusDot.layer addAnimation:pulse forKey:@"scpPulse"];
}

// Every second (timer), and on layout/trait changes. Only a real state
// change repaints with animation and restarts the loops.
- (void)refreshStatus {
    uint64_t state = SCPGetCarPlayState();
    BOOL changed = !_hasShownState || state != _shownState;
    if (!changed) {
        [self applyStatusLookAnimated:NO]; // cheap; keeps CGColors right after trait changes
        return;
    }
    // Animate only a change seen on screen, not the first paint on appear.
    BOOL animated = _hasShownState && _cardMotionActive && self.view.window != nil;
    BOOL wasDisconnected = _hasShownState && _shownState == SCPCarPlayStateDisconnected;
    _shownState = state;
    _hasShownState = YES;
    [self applyStatusLookAnimated:animated];
    if (animated && wasDisconnected && state != SCPCarPlayStateDisconnected) {
        // "Connected" moment: one pop of the car and a light tap.
        SCPHomePop(_carShape.layer, @[@1.0, @1.06, @0.99, @1.0], 0.45);
        UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [haptic impactOccurred];
    }
    [self startCardAnimations];
    [self.view setNeedsLayout]; // the status label is sized to its text
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self refreshStatus]; // CGColor borders
}

- (void)layoutRow:(UIButton *)row width:(CGFloat)w {
    [row viewWithTag:101].frame = CGRectMake(14, 0, 28, 44);
    [row viewWithTag:102].frame = CGRectMake(50, 0, w - 50 - 34, 44);
    [row viewWithTag:103].frame = CGRectMake(w - 30, 0, 16, 44);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _scroll.frame = self.view.bounds;
    _scroll.contentInset = UIEdgeInsetsMake(0, 0, self.view.safeAreaInsets.bottom, 0); // floating tab bar
    CGFloat x = 20, w = self.view.bounds.size.width - 40;
    CGFloat y = self.view.safeAreaInsets.top + 16;

    _logo.frame = CGRectMake(x, y, 52, 52);
    _titleLabel.frame = CGRectMake(x + 64, y + 2, w - 64, 32);
    _versionLabel.frame = CGRectMake(x + 64, y + 34, w - 64, 16);
    y += 52 + 24;

    CGSize switchSize = _mainSwitch.bounds.size;
    _mainSwitch.center = CGPointMake(x + w - switchSize.width * 1.15 / 2.0, y + 15);
    _switchTitle.frame = CGRectMake(x, y, w - 80, 28);
    CGSize subSize = [_switchSubtitle sizeThatFits:CGSizeMake(w - 80, CGFLOAT_MAX)];
    _switchSubtitle.frame = CGRectMake(x, y + 30, w - 80, subSize.height);
    y = CGRectGetMaxY(_switchSubtitle.frame) + 16;

    if (!_noticeBox.hidden) {
        CGSize noticeSize = [_noticeLabel sizeThatFits:CGSizeMake(w - 24, CGFLOAT_MAX)];
        _noticeLabel.frame = CGRectMake(12, 10, w - 24, noticeSize.height);
        _noticeButton.frame = CGRectMake(12, CGRectGetMaxY(_noticeLabel.frame) + 2, 90, 44);
        _noticeButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        _noticeBox.frame = CGRectMake(x, y, w, CGRectGetMaxY(_noticeButton.frame) + 2);
        y = CGRectGetMaxY(_noticeBox.frame) + 16;
    }

    if (!_setupCard.hidden) {
        _setupTitle.frame = CGRectMake(16, 10, w - 32, 18);
        CGFloat rowY = 32;
        for (UIButton *row in _setupRows) {
            row.frame = CGRectMake(0, rowY, w, 44);
            [self layoutRow:row width:w];
            rowY += 44;
        }
        _setupCard.frame = CGRectMake(x, y, w, rowY + 6);
        y = CGRectGetMaxY(_setupCard.frame) + 16;
    }

    // Status card
    CGFloat phoneW = 34, phoneH = 60;
    CGFloat carW = MIN(170, w * 0.5), carH = 104;
    CGFloat midY = 20 + carH / 2.0;
    _phoneShape.frame = CGRectMake(28, midY - phoneH / 2.0, phoneW, phoneH);
    _carShape.frame = CGRectMake(w - 24 - carW, 20, carW, carH);
    _carIcon.frame = _carShape.bounds;
    CGRect splitArea = CGRectInset(_carShape.bounds, 16, 18);
    _miniSplit.frame = splitArea;
    CGFloat splitW = splitArea.size.width, splitH = splitArea.size.height;
    CGFloat miniPaneW = MAX(0, floor((splitW - 8) / 2.0));
    _miniLeft.frame = CGRectMake(0, 0, miniPaneW, splitH);
    _miniRight.frame = CGRectMake(splitW - miniPaneW, 0, miniPaneW, splitH);
    _miniDivider.frame = CGRectMake(floor((splitW - 2) / 2.0), floor(splitH * 0.3), 2, ceil(splitH * 0.4));

    CGFloat dotsX = CGRectGetMaxX(_phoneShape.frame) + 10;
    CGFloat dotsW = CGRectGetMinX(_carShape.frame) - 10 - dotsX;
    CGRect oldLink = _linkDots.frame;
    _linkDots.frame = CGRectMake(dotsX, midY - 2, MAX(0, dotsW), 4);
    // Rebuilt only when the count changes, so running dot animations
    // aren't thrown away on every layout pass.
    NSUInteger dotCount = 0;
    for (CGFloat dx = 0; dx + 6 <= dotsW; dx += 12) dotCount++;
    BOOL linkChanged = !CGRectEqualToRect(oldLink, _linkDots.frame);
    if (_linkDots.subviews.count != dotCount) {
        [_linkDots.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
        for (NSUInteger i = 0; i < dotCount; i++) {
            UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(i * 12, 0, 6, 3)];
            dot.layer.cornerRadius = 1.5;
            [_linkDots addSubview:dot];
        }
        linkChanged = YES;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CGFloat ringSize = 60;
    _searchRing.frame = CGRectMake(CGRectGetMidX(_phoneShape.frame) - ringSize / 2.0, midY - ringSize / 2.0, ringSize, ringSize);
    _searchRing.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, ringSize, ringSize)].CGPath;
    _packet.position = CGPointMake(CGRectGetMinX(_linkDots.frame), CGRectGetMidY(_linkDots.frame));
    [CATransaction commit];
    CGFloat statusY = 20 + carH + 18;
    CGSize statusSize = [_statusLabel sizeThatFits:CGSizeMake(w - 60, 22)];
    CGFloat statusW = MIN(w - 60, statusSize.width);
    CGFloat statusX = (w - statusW - 14) / 2.0;
    _statusDot.frame = CGRectMake(statusX, statusY + 7, 8, 8);
    _statusLabel.frame = CGRectMake(statusX + 14, statusY, statusW, 22);

    CGFloat appsY = statusY + 22 + 16;
    _appsSeparator.frame = CGRectMake(16, appsY, w - 32, 1.0 / MAX(1.0, [UIScreen mainScreen].scale));
    _appsRow.frame = CGRectMake(0, appsY, w, 52);
    CGFloat iconX = 16;
    _leftIcon.frame = CGRectMake(iconX, 11, 30, 30);
    if (!_rightIcon.hidden) {
        _rightIcon.frame = CGRectMake(iconX + 36, 11, 30, 30);
        iconX += 36;
    }
    CGFloat labelX = _leftIcon.image ? iconX + 42 : 16;
    _appsLabel.frame = CGRectMake(labelX, 0, w - labelX - 34, 52);
    [_appsRow viewWithTag:103].frame = CGRectMake(w - 30, 0, 16, 52);
    _statusCard.frame = CGRectMake(x, y, w, CGRectGetMaxY(_appsRow.frame));
    y = CGRectGetMaxY(_statusCard.frame) + 16;

    _respringButton.frame = CGRectMake(x, y, w, 48);
    y = CGRectGetMaxY(_respringButton.frame) + 24;

    _scroll.contentSize = CGSizeMake(self.view.bounds.size.width, y);
    [self refreshStatus]; // dot colors for the freshly made dots
    if (linkChanged) [self startCardAnimations]; // new dots / packet path
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_statusTimer invalidate];
}

@end
