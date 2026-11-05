//
//  AccountViewController.m -- "Tài khoản" tab
//
//  SidePlay's own version of this tab is a real login/account system
//  (their commercial product). SplitCarPlay has no backend and needs
//  none -- this tab exists only to match the tab structure, and just
//  shows version/credit info instead.
//
#import <UIKit/UIKit.h>

@interface AccountViewController : UIViewController
@end

@implementation AccountViewController {
    UILabel *_infoLabel;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"Tài khoản";

    _infoLabel = [[UILabel alloc] init];
    NSDictionary *appInfo = [NSBundle mainBundle].infoDictionary;
    NSString *version = appInfo[@"CFBundleShortVersionString"] ?: @"?";
    _infoLabel.text = [NSString stringWithFormat:
        @"SplitCarPlay %@\n\n"
        @"SplitCarPlay không có hệ thống tài khoản/đăng nhập nào — tab này chỉ để khớp cấu trúc 4 tab với SidePlay.\n\n"
        @"Mã nguồn: github.com/anhtran3199/carplay-tweaks\n"
        @"Liên hệ: anhtran3199@gmail.com",
        version];
    _infoLabel.font = [UIFont systemFontOfSize:15];
    _infoLabel.textColor = [UIColor secondaryLabelColor];
    _infoLabel.numberOfLines = 0;
    [self.view addSubview:_infoLabel];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat x = 20, w = self.view.bounds.size.width - 40;
    CGFloat y = self.view.safeAreaInsets.top + 24;
    CGSize size = [_infoLabel sizeThatFits:CGSizeMake(w, CGFLOAT_MAX)];
    _infoLabel.frame = CGRectMake(x, y, w, size.height);
}

@end
