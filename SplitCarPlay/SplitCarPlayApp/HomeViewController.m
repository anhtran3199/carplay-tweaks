//
//  HomeViewController.m -- "Trang chủ" tab
//
//  Just a short status/welcome screen -- the actual controls live in
//  "Trên xe" and "Mô phỏng". Kept deliberately simple since the user's
//  ask was the overall 4-tab shape, not a detailed home dashboard.
//
#import <UIKit/UIKit.h>
#import "../SplitCarPlayShared.h"

extern NSString *SplitCarPlayDisplayNameForBundleID(NSString *bundleID); // AppPickerController.m


@interface HomeViewController : UIViewController
@end

@implementation HomeViewController {
    UILabel *_titleLabel;
    UILabel *_subtitleLabel;
    UILabel *_statusLabel;
    UIView *_warningBox;
    UILabel *_warningLabel;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.text = @"SplitCarPlay";
    _titleLabel.font = [UIFont boldSystemFontOfSize:30];
    [self.view addSubview:_titleLabel];

    _subtitleLabel = [[UILabel alloc] init];
    _subtitleLabel.text = @"Chia đôi màn hình CarPlay, bong bóng tốc độ từ Vietmap Live.";
    _subtitleLabel.font = [UIFont systemFontOfSize:15];
    _subtitleLabel.textColor = [UIColor secondaryLabelColor];
    _subtitleLabel.numberOfLines = 0;
    [self.view addSubview:_subtitleLabel];

    _statusLabel = [[UILabel alloc] init];
    _statusLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    _statusLabel.numberOfLines = 0;
    [self.view addSubview:_statusLabel];

    _warningBox = [[UIView alloc] init];
    _warningBox.backgroundColor = [UIColor colorWithRed:1 green:0.84 blue:0.4 alpha:0.2];
    _warningBox.layer.cornerRadius = 10;
    [self.view addSubview:_warningBox];

    _warningLabel = [[UILabel alloc] init];
    _warningLabel.text = @"⚠️ Tính năng chia màn hình thật trên CarPlay hiện đang tạm tắt — lần test thật đầu tiên trên xe cho thấy màn hình CarPlay bị trống/đen. Đang tìm hướng kỹ thuật khác (xem ROADMAP.md).";
    _warningLabel.font = [UIFont systemFontOfSize:13];
    _warningLabel.textColor = [UIColor labelColor];
    _warningLabel.numberOfLines = 0;
    [_warningBox addSubview:_warningLabel];

    [self refresh];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refresh];
}

- (void)refresh {
    NSDictionary *prefs = SCPCopyPrefs();
    NSString *leftName = SplitCarPlayDisplayNameForBundleID(prefs[@"leftBundleID"]) ?: @"(chưa chọn)";
    NSString *rightName = SplitCarPlayDisplayNameForBundleID(prefs[@"rightBundleID"]) ?: @"(chưa chọn)";
    BOOL enabled = prefs[@"enabled"] ? [prefs[@"enabled"] boolValue] : YES;
    _statusLabel.text = [NSString stringWithFormat:@"Trạng thái: %@\nÔ 1: %@\nÔ 2: %@",
                          enabled ? @"Đã bật" : @"Đã tắt", leftName, rightName];
    [self.view setNeedsLayout];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat x = 20, w = self.view.bounds.size.width - 40;
    CGFloat y = self.view.safeAreaInsets.top + 24;

    _titleLabel.frame = CGRectMake(x, y, w, 40);
    y = CGRectGetMaxY(_titleLabel.frame) + 6;

    CGSize subtitleSize = [_subtitleLabel sizeThatFits:CGSizeMake(w, CGFLOAT_MAX)];
    _subtitleLabel.frame = CGRectMake(x, y, w, subtitleSize.height);
    y = CGRectGetMaxY(_subtitleLabel.frame) + 20;

    CGSize statusSize = [_statusLabel sizeThatFits:CGSizeMake(w, CGFLOAT_MAX)];
    _statusLabel.frame = CGRectMake(x, y, w, statusSize.height);
    y = CGRectGetMaxY(_statusLabel.frame) + 24;

    CGFloat warningPad = 12;
    CGSize warningTextSize = [_warningLabel sizeThatFits:CGSizeMake(w - warningPad * 2, CGFLOAT_MAX)];
    _warningLabel.frame = CGRectMake(warningPad, warningPad, w - warningPad * 2, warningTextSize.height);
    _warningBox.frame = CGRectMake(x, y, w, warningTextSize.height + warningPad * 2);
}

@end
