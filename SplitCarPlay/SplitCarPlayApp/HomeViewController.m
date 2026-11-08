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

    [self refresh];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // The header above is the title; no navigation bar repeating it.
    [self.navigationController setNavigationBarHidden:YES animated:animated];
    [self refresh];
    [_statusTimer invalidate];
    _statusTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(refreshStatus) userInfo:nil repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_statusTimer invalidate];
    _statusTimer = nil;
}

- (void)mainSwitchChanged:(UISwitch *)sender {
    if (sender.on) {
        SplitCarPlaySetPref(@"carPlayCrashNotice", @NO);
        SplitCarPlaySetPref(@"enabled", @YES);
    }
    SplitCarPlaySetPref(@"carPlayAutoHost", @(sender.on));
    [self refresh];
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
    BOOL on = SCPIsCarPlayOn(prefs);
    _mainSwitch.on = on;
    _switchTitle.text = on ? @"Đang bật" : @"Đang tắt";
    _switchSubtitle.text = on ? @"Cắm CarPlay là app tự hiện trên màn hình xe." : @"Bật để hiện app trên màn hình xe mỗi khi cắm CarPlay.";
    _switchSubtitle.textColor = on ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
    _noticeBox.hidden = ![prefs[@"carPlayCrashNotice"] boolValue];

    NSString *leftID = prefs[@"leftBundleID"];
    NSString *rightID = prefs[@"rightBundleID"];
    BOOL single = [prefs[@"experimentalSingleApp"] boolValue];
    BOOL hasApp = leftID.length > 0;
    BOOL tweak = SCPHomeTweakInstalled();
    [self configureRow:_setupRows[0] done:tweak
                  text:tweak ? @"Tweak đã cài" : @"Cài SplitCarPlay từ Sileo rồi respring" tappable:NO];
    [self configureRow:_setupRows[1] done:hasApp text:hasApp ? @"Đã chọn app" : @"Chọn app cho ô 1 và ô 2" tappable:YES];
    [self configureRow:_setupRows[2] done:on text:on ? @"Đã bật" : @"Bật \"Đang bật\" rồi cắm CarPlay" tappable:YES];
    _setupCard.hidden = tweak && hasApp && on;

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
    [self refreshStatus];
    [self.view setNeedsLayout];
}

- (void)refreshStatus {
    uint64_t state = SCPGetCarPlayState();
    UIColor *color = [UIColor systemGrayColor];
    NSString *text = @"Chưa kết nối CarPlay";
    if (state == SCPCarPlayStateShowing) {
        color = [UIColor systemGreenColor];
        text = @"Đang hiển thị trên CarPlay";
    } else if (state == SCPCarPlayStateConnected) {
        color = [UIColor systemBlueColor];
        text = @"Đã kết nối CarPlay";
    }
    _statusDot.backgroundColor = color;
    _statusLabel.text = text;
    BOOL connected = state != SCPCarPlayStateDisconnected;
    UIColor *lineColor = connected ? color : [UIColor tertiaryLabelColor];
    _phoneShape.layer.borderColor = lineColor.CGColor;
    _carShape.layer.borderColor = lineColor.CGColor;
    _carShape.backgroundColor = connected ? [color colorWithAlphaComponent:0.08] : [UIColor tertiarySystemFillColor];
    _carIcon.tintColor = connected ? color : [UIColor secondaryLabelColor];
    for (UIView *dot in _linkDots.subviews) dot.backgroundColor = lineColor;
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
    CGFloat dotsX = CGRectGetMaxX(_phoneShape.frame) + 10;
    CGFloat dotsW = CGRectGetMinX(_carShape.frame) - 10 - dotsX;
    _linkDots.frame = CGRectMake(dotsX, midY - 2, MAX(0, dotsW), 4);
    [_linkDots.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    for (CGFloat dx = 0; dx + 6 <= dotsW; dx += 12) {
        UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(dx, 0, 6, 3)];
        dot.layer.cornerRadius = 1.5;
        [_linkDots addSubview:dot];
    }
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
    y = CGRectGetMaxY(_statusCard.frame) + 24;

    _scroll.contentSize = CGSizeMake(self.view.bounds.size.width, y);
    [self refreshStatus]; // dot colors for the freshly made dots
}

- (void)dealloc {
    [_statusTimer invalidate];
}

@end
