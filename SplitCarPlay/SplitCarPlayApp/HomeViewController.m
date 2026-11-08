//
//  HomeViewController.m -- "Trang chủ" tab
//
//  One switch, like SidePlay2's: "Đang bật" shows the picked apps on the
//  car screen every time CarPlay connects (pref carPlayAutoHost, read by
//  Tweak.xm in SpringBoard). Below it, the CarPlay status SpringBoard
//  publishes (SCPGetCarPlayState) and the two picked apps.
//
//  If SpringBoard dies during a CarPlay session, it switches "Đang bật"
//  off on its next start and sets carPlayCrashNotice, shown here until the
//  switch is turned back on.
//
#import <UIKit/UIKit.h>
#import "../SplitCarPlayShared.h"

extern NSString *SplitCarPlayDisplayNameForBundleID(NSString *bundleID); // AppPickerController.m
extern UIImage *SplitCarPlayAppIcon(NSString *bundleID);                 // AppPickerController.m
extern void SplitCarPlaySetPref(NSString *key, id value);                // AppPickerController.m

static UIColor *SCPHomeCardColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithWhite:0.13 alpha:1] : [UIColor whiteColor];
    }];
}

static UIImageView *SCPHomeSymbolView(NSString *name, CGFloat size, UIColor *tint) {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:size weight:UIImageSymbolWeightRegular];
    UIImageView *view = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:name withConfiguration:config]];
    view.tintColor = tint;
    view.contentMode = UIViewContentModeCenter;
    return view;
}

@interface HomeViewController : UIViewController
@end

@implementation HomeViewController {
    UIScrollView *_scroll;
    UIView *_logo;
    UILabel *_titleLabel;
    UILabel *_versionLabel;

    UILabel *_switchTitle;
    UILabel *_switchSubtitle;
    UISwitch *_mainSwitch;

    UIView *_noticeBox;
    UILabel *_noticeLabel;

    UIView *_statusCard;
    UIView *_phoneShape;
    UIView *_linkDots;
    UIView *_carShape;
    UIImageView *_carIcon;
    UIView *_statusDot;
    UILabel *_statusLabel;

    UIView *_appsCard;
    UIImageView *_leftIcon;
    UILabel *_leftLabel;
    UIImageView *_rightIcon;
    UILabel *_rightLabel;
    UILabel *_hintLabel;

    NSTimer *_statusTimer;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    _scroll = [[UIScrollView alloc] init];
    _scroll.alwaysBounceVertical = YES;
    [self.view addSubview:_scroll];

    // Header: logo, name, version
    _logo = [[UIView alloc] init];
    _logo.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1];
    _logo.layer.cornerRadius = 12;
    UIImageView *logoGlyph = SCPHomeSymbolView(@"rectangle.split.2x1.fill", 20, [UIColor whiteColor]);
    logoGlyph.frame = CGRectMake(0, 0, 48, 48);
    [_logo addSubview:logoGlyph];
    [_scroll addSubview:_logo];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.text = @"SplitCarPlay";
    _titleLabel.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBold];
    [_scroll addSubview:_titleLabel];

    _versionLabel = [[UILabel alloc] init];
    NSString *version = [NSBundle mainBundle].infoDictionary[@"CFBundleShortVersionString"] ?: @"";
    _versionLabel.text = [NSString stringWithFormat:@"Phiên bản %@", version];
    _versionLabel.font = [UIFont systemFontOfSize:13];
    _versionLabel.textColor = [UIColor secondaryLabelColor];
    [_scroll addSubview:_versionLabel];

    // The switch
    _switchTitle = [[UILabel alloc] init];
    _switchTitle.font = [UIFont systemFontOfSize:22 weight:UIFontWeightSemibold];
    [_scroll addSubview:_switchTitle];

    _switchSubtitle = [[UILabel alloc] init];
    _switchSubtitle.font = [UIFont systemFontOfSize:14];
    _switchSubtitle.numberOfLines = 0;
    [_scroll addSubview:_switchSubtitle];

    _mainSwitch = [[UISwitch alloc] init];
    _mainSwitch.onTintColor = [UIColor systemGreenColor];
    _mainSwitch.transform = CGAffineTransformMakeScale(1.15, 1.15);
    [_mainSwitch addTarget:self action:@selector(mainSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    [_scroll addSubview:_mainSwitch];

    // Crash notice (hidden unless SpringBoard switched it off)
    _noticeBox = [[UIView alloc] init];
    _noticeBox.backgroundColor = [UIColor colorWithRed:1 green:0.84 blue:0.4 alpha:0.25];
    _noticeBox.layer.cornerRadius = 12;
    [_scroll addSubview:_noticeBox];
    _noticeLabel = [[UILabel alloc] init];
    _noticeLabel.font = [UIFont systemFontOfSize:13];
    _noticeLabel.numberOfLines = 0;
    _noticeLabel.text = @"⚠️ Lần trước SpringBoard bị lỗi khi đang hiển thị trên CarPlay, nên đã tự tắt để không lỗi lại mỗi lần cắm xe. Gửi file /var/mobile/Library/Logs/splitcarplay_hosting.log để sửa, rồi bật lại.";
    [_noticeBox addSubview:_noticeLabel];

    // Status card: phone ··· car
    _statusCard = [[UIView alloc] init];
    _statusCard.backgroundColor = SCPHomeCardColor();
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
    _statusLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    _statusLabel.textAlignment = NSTextAlignmentLeft;
    [_statusCard addSubview:_statusLabel];

    // Picked apps
    _appsCard = [[UIView alloc] init];
    _appsCard.backgroundColor = SCPHomeCardColor();
    _appsCard.layer.cornerRadius = 16;
    [_scroll addSubview:_appsCard];
    _leftIcon = [[UIImageView alloc] init];
    _leftIcon.layer.cornerRadius = 7;
    _leftIcon.clipsToBounds = YES;
    [_appsCard addSubview:_leftIcon];
    _leftLabel = [[UILabel alloc] init];
    _leftLabel.font = [UIFont systemFontOfSize:15];
    [_appsCard addSubview:_leftLabel];
    _rightIcon = [[UIImageView alloc] init];
    _rightIcon.layer.cornerRadius = 7;
    _rightIcon.clipsToBounds = YES;
    [_appsCard addSubview:_rightIcon];
    _rightLabel = [[UILabel alloc] init];
    _rightLabel.font = [UIFont systemFontOfSize:15];
    [_appsCard addSubview:_rightLabel];

    _hintLabel = [[UILabel alloc] init];
    _hintLabel.font = [UIFont systemFontOfSize:12];
    _hintLabel.textColor = [UIColor secondaryLabelColor];
    _hintLabel.numberOfLines = 0;
    _hintLabel.text = @"Đổi app ở tab Trên xe hoặc Mô phỏng. Trên màn hình xe: bấm ✕ (góc trên trái) hoặc giữ 2 ngón tay 1 giây để quay về CarPlay bình thường; app sẽ tự hiện lại ở lần cắm xe sau.";
    [_scroll addSubview:_hintLabel];

    [self refresh];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
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

- (void)refresh {
    NSDictionary *prefs = SCPCopyPrefs();
    BOOL on = [prefs[@"carPlayAutoHost"] boolValue] && [prefs[@"enabled"] boolValue];
    _mainSwitch.on = on;
    _switchTitle.text = on ? @"Đang bật" : @"Đang tắt";
    _switchSubtitle.text = on ? @"Cắm CarPlay là app tự hiện trên màn hình xe." : @"Bật để hiện app trên màn hình xe mỗi khi cắm CarPlay.";
    _switchSubtitle.textColor = on ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
    _noticeBox.hidden = ![prefs[@"carPlayCrashNotice"] boolValue];

    BOOL single = [prefs[@"experimentalSingleApp"] boolValue];
    NSString *leftID = prefs[@"leftBundleID"];
    NSString *rightID = prefs[@"rightBundleID"];
    _leftIcon.image = SplitCarPlayAppIcon(leftID);
    _rightIcon.image = SplitCarPlayAppIcon(rightID);
    _leftLabel.text = [NSString stringWithFormat:@"Ô 1: %@", SplitCarPlayDisplayNameForBundleID(leftID) ?: @"(chưa chọn)"];
    _rightLabel.text = single ? @"Ô 2: (tắt, đang để 1 app toàn màn hình)"
                              : [NSString stringWithFormat:@"Ô 2: %@", SplitCarPlayDisplayNameForBundleID(rightID) ?: @"(chưa chọn)"];
    _rightLabel.textColor = single ? [UIColor secondaryLabelColor] : [UIColor labelColor];
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

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _scroll.frame = self.view.bounds;
    CGFloat x = 20, w = self.view.bounds.size.width - 40;
    CGFloat y = 16;

    _logo.frame = CGRectMake(x, y, 48, 48);
    _titleLabel.frame = CGRectMake(x + 60, y + 2, w - 60, 28);
    _versionLabel.frame = CGRectMake(x + 60, y + 30, w - 60, 16);
    y += 48 + 24;

    CGSize switchSize = _mainSwitch.bounds.size;
    _mainSwitch.center = CGPointMake(x + w - switchSize.width * 1.15 / 2.0, y + 16);
    _switchTitle.frame = CGRectMake(x, y, w - 80, 30);
    CGSize subSize = [_switchSubtitle sizeThatFits:CGSizeMake(w - 80, CGFLOAT_MAX)];
    _switchSubtitle.frame = CGRectMake(x, y + 32, w - 80, subSize.height);
    y = CGRectGetMaxY(_switchSubtitle.frame) + 16;

    if (!_noticeBox.hidden) {
        CGSize noticeSize = [_noticeLabel sizeThatFits:CGSizeMake(w - 24, CGFLOAT_MAX)];
        _noticeLabel.frame = CGRectMake(12, 10, w - 24, noticeSize.height);
        _noticeBox.frame = CGRectMake(x, y, w, noticeSize.height + 20);
        y = CGRectGetMaxY(_noticeBox.frame) + 16;
    }

    // Status card
    CGFloat cardH = 190;
    _statusCard.frame = CGRectMake(x, y, w, cardH);
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
    CGSize statusSize = [_statusLabel sizeThatFits:CGSizeMake(w - 60, 22)];
    CGFloat statusW = MIN(w - 60, statusSize.width);
    CGFloat statusX = (w - statusW - 14) / 2.0;
    _statusDot.frame = CGRectMake(statusX, cardH - 40 + 7, 8, 8);
    _statusLabel.frame = CGRectMake(statusX + 14, cardH - 40, statusW, 22);
    y = CGRectGetMaxY(_statusCard.frame) + 16;

    // Apps card
    _appsCard.frame = CGRectMake(x, y, w, 104);
    _leftIcon.frame = CGRectMake(16, 16, 30, 30);
    _leftLabel.frame = CGRectMake(56, 16, w - 72, 30);
    _rightIcon.frame = CGRectMake(16, 58, 30, 30);
    _rightLabel.frame = CGRectMake(56, 58, w - 72, 30);
    y = CGRectGetMaxY(_appsCard.frame) + 12;

    CGSize hintSize = [_hintLabel sizeThatFits:CGSizeMake(w - 8, CGFLOAT_MAX)];
    _hintLabel.frame = CGRectMake(x + 4, y, w - 8, hintSize.height);
    y = CGRectGetMaxY(_hintLabel.frame) + 24;

    _scroll.contentSize = CGSizeMake(self.view.bounds.size.width, y);
    [self refreshStatus]; // dot colors for the freshly made dots
}

- (void)dealloc {
    [_statusTimer invalidate];
}

@end
