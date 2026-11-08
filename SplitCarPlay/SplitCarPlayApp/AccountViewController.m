//
//  AccountViewController.m -- "Tài khoản" tab
//
//  SidePlay's version is a login/licence screen backed by their server.
//  SplitCarPlay has no server and no account, so this tab holds what is
//  real for a personal tweak: this device, updates from the Sileo repo,
//  support (share the log, report a problem), resetting the settings, and
//  credits.
//
#import <UIKit/UIKit.h>
#import <sys/utsname.h>
#import "../SplitCarPlayShared.h"

static NSString * const kSCPRepoURL = @"https://anhtran3199.github.io/carplay-tweaks/";
static NSString * const kSCPPackageID = @"com.example.splitcarplay";
static NSString * const kSCPSourceURL = @"https://github.com/anhtran3199/carplay-tweaks";
static NSString * const kSCPContact = @"anhtran3199@gmail.com";
static NSString * const kSCPLogPath = @"/var/mobile/Library/Logs/splitcarplay_hosting.log";

typedef NS_ENUM(NSInteger, SCPAccountAction) {
    SCPAccountActionNone,
    SCPAccountActionCheckUpdate,
    SCPAccountActionOpenSileo,
    SCPAccountActionCopyRepo,
    SCPAccountActionShareLog,
    SCPAccountActionReport,
    SCPAccountActionEmail,
    SCPAccountActionReset,
    SCPAccountActionSource,
};

@interface SCPAccountRow : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *value;
@property (nonatomic, copy) NSString *symbol;
@property (nonatomic, strong) UIColor *color;
@property (nonatomic, assign) SCPAccountAction action;
@property (nonatomic, assign) BOOL destructive;
@end

@implementation SCPAccountRow
@end

static SCPAccountRow *SCPInfo(NSString *title, NSString *value) {
    SCPAccountRow *row = [SCPAccountRow new];
    row.title = title; row.value = value;
    return row;
}

static SCPAccountRow *SCPAction(NSString *title, NSString *symbol, UIColor *color, SCPAccountAction action) {
    SCPAccountRow *row = [SCPAccountRow new];
    row.title = title; row.symbol = symbol; row.color = color; row.action = action;
    return row;
}

static UIImage *SCPAccountIcon(NSString *symbol, UIColor *color) {
    CGFloat size = 29;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(size, size)];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [color setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size, size) cornerRadius:7] fill];
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];
        UIImage *glyph = [[UIImage systemImageNamed:symbol withConfiguration:config] imageWithTintColor:[UIColor whiteColor]
                                                                                           renderingMode:UIImageRenderingModeAlwaysOriginal];
        if (glyph) [glyph drawInRect:CGRectMake((size - glyph.size.width) / 2.0, (size - glyph.size.height) / 2.0, glyph.size.width, glyph.size.height)];
    }];
}

static NSString *SCPDeviceModel(void) {
    struct utsname info;
    uname(&info);
    return [NSString stringWithCString:info.machine encoding:NSUTF8StringEncoding] ?: @"?";
}

static NSString *SCPJailbreakDescription(void) {
    NSFileManager *files = [NSFileManager defaultManager];
    if ([files fileExistsAtPath:@"/var/jb"]) return @"Rootless (Dopamine / palera1n)";
    if ([files fileExistsAtPath:@"/Applications/Sileo.app"] || [files fileExistsAtPath:@"/Applications/Cydia.app"]) return @"Rootful";
    return @"Không phát hiện";
}

static BOOL SCPTweakInstalled(void) {
    NSFileManager *files = [NSFileManager defaultManager];
    return [files fileExistsAtPath:@"/var/jb/Library/MobileSubstrate/DynamicLibraries/SplitCarPlay.dylib"]
        || [files fileExistsAtPath:@"/Library/MobileSubstrate/DynamicLibraries/SplitCarPlay.dylib"];
}

// "1.10.2" > "1.9" etc.
static NSComparisonResult SCPCompareVersions(NSString *a, NSString *b) {
    return [a compare:b options:NSNumericSearch];
}

@interface AccountViewController : UITableViewController
@end

@implementation AccountViewController {
    NSArray<NSString *> *_titles;
    NSArray<NSString *> *_footers;
    NSArray<NSArray<SCPAccountRow *> *> *_sections;
    NSString *_updateStatus;
    BOOL _checking;
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (NSString *)appVersion {
    return [NSBundle mainBundle].infoDictionary[@"CFBundleShortVersionString"] ?: @"?";
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Tài khoản";
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.tableView.tableHeaderView = [self makeHeader];
    _updateStatus = @"Chạm để kiểm tra";
    [self rebuildRows];
}

- (UIView *)makeHeader {
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 150)];
    UIImageView *logo = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"AppIcon60x60"]];
    logo.frame = CGRectMake(0, 14, 72, 72);
    logo.layer.cornerRadius = 16;
    logo.layer.cornerCurve = kCACornerCurveContinuous;
    logo.clipsToBounds = YES;
    logo.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    logo.center = CGPointMake(header.bounds.size.width / 2.0, logo.center.y);
    [header addSubview:logo];

    UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(0, 94, header.bounds.size.width, 26)];
    name.text = @"SplitCarPlay";
    name.font = [UIFont systemFontOfSize:21 weight:UIFontWeightBold];
    name.textAlignment = NSTextAlignmentCenter;
    name.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [header addSubview:name];

    UILabel *plan = [[UILabel alloc] initWithFrame:CGRectMake(0, 120, header.bounds.size.width, 20)];
    plan.text = [NSString stringWithFormat:@"Bản cá nhân · không cần đăng nhập · %@", [self appVersion]];
    plan.font = [UIFont systemFontOfSize:13];
    plan.textColor = [UIColor secondaryLabelColor];
    plan.textAlignment = NSTextAlignmentCenter;
    plan.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [header addSubview:plan];
    return header;
}

- (void)rebuildRows {
    UIDevice *device = [UIDevice currentDevice];
    SCPAccountRow *update = SCPAction(@"Kiểm tra cập nhật", @"arrow.down.circle.fill", [UIColor systemGreenColor], SCPAccountActionCheckUpdate);
    update.value = _checking ? @"Đang kiểm tra…" : _updateStatus;
    SCPAccountRow *reset = SCPAction(@"Đặt lại toàn bộ cài đặt", @"arrow.counterclockwise", [UIColor systemRedColor], SCPAccountActionReset);
    reset.destructive = YES;

    _titles = @[@"Thiết bị", @"Cập nhật", @"Hỗ trợ", @"Dữ liệu", @"Giới thiệu"];
    _footers = @[
        @"",
        [NSString stringWithFormat:@"Nguồn Sileo: %@", kSCPRepoURL],
        @"Khi báo lỗi, gửi kèm log debug và (nếu máy vào safe mode) file SpringBoard-….ips trong Cài đặt › Quyền riêng tư & Bảo mật › Phân tích & Cải tiến › Dữ liệu phân tích.",
        @"Đưa mọi cài đặt (app đã chọn, bong bóng, thanh tab…) về mặc định. Tắt luôn \"Đang bật\".",
        @"Cách hiển thị app trên màn hình xe dựa theo dự án mã nguồn mở carplay-cast (EthanArbuckle, Apache-2.0).",
    ];
    _sections = @[
        @[ SCPInfo(@"Máy", SCPDeviceModel()),
           SCPInfo(@"iOS", device.systemVersion),
           SCPInfo(@"Jailbreak", SCPJailbreakDescription()),
           SCPInfo(@"Tweak SplitCarPlay", SCPTweakInstalled() ? @"Đã cài" : @"Chưa thấy") ],
        @[ SCPInfo(@"Phiên bản đang dùng", [self appVersion]),
           update,
           SCPAction(@"Mở trong Sileo", @"shippingbox.fill", [UIColor systemBlueColor], SCPAccountActionOpenSileo),
           SCPAction(@"Sao chép địa chỉ nguồn", @"doc.on.doc.fill", [UIColor systemGrayColor], SCPAccountActionCopyRepo) ],
        @[ SCPAction(@"Gửi log debug", @"square.and.arrow.up.fill", [UIColor systemIndigoColor], SCPAccountActionShareLog),
           SCPAction(@"Báo lỗi trên GitHub", @"ladybug.fill", [UIColor systemOrangeColor], SCPAccountActionReport),
           SCPAction(@"Gửi email", @"envelope.fill", [UIColor systemBlueColor], SCPAccountActionEmail) ],
        @[ reset ],
        @[ SCPAction(@"Mã nguồn", @"chevron.left.forwardslash.chevron.right", [UIColor darkGrayColor], SCPAccountActionSource) ],
    ];
    [self.tableView reloadData];
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return _sections.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return _titles[section];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return _footers[section].length ? _footers[section] : nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _sections[section].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    SCPAccountRow *row = _sections[indexPath.section][indexPath.row];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.textLabel.text = row.title;
    cell.detailTextLabel.text = row.value;
    if (row.symbol) cell.imageView.image = SCPAccountIcon(row.symbol, row.color ?: [UIColor systemBlueColor]);
    if (row.destructive) cell.textLabel.textColor = [UIColor systemRedColor];
    cell.selectionStyle = row.action == SCPAccountActionNone ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    SCPAccountRow *row = _sections[indexPath.section][indexPath.row];
    UIView *anchor = [tableView cellForRowAtIndexPath:indexPath] ?: self.view;
    switch (row.action) {
        case SCPAccountActionCheckUpdate: {
            [self checkForUpdate];
            break;
        }
        case SCPAccountActionOpenSileo: {
            [self openSileo];
            break;
        }
        case SCPAccountActionCopyRepo: {
            [UIPasteboard generalPasteboard].string = kSCPRepoURL;
            [self toast:@"Đã sao chép địa chỉ nguồn"];
            break;
        }
        case SCPAccountActionShareLog: {
            [self shareLogFrom:anchor];
            break;
        }
        case SCPAccountActionReport: {
            [self openURL:[kSCPSourceURL stringByAppendingString:@"/issues/new"]];
            break;
        }
        case SCPAccountActionEmail: {
            NSString *subject = [[NSString stringWithFormat:@"SplitCarPlay %@", [self appVersion]]
                stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
            [self openURL:[NSString stringWithFormat:@"mailto:%@?subject=%@", kSCPContact, subject]];
            break;
        }
        case SCPAccountActionReset: {
            [self confirmReset];
            break;
        }
        case SCPAccountActionSource: {
            [self openURL:kSCPSourceURL];
            break;
        }
        default:
            break;
    }
}

#pragma mark Actions

- (void)openURL:(NSString *)string {
    NSURL *url = [NSURL URLWithString:string];
    if (url) [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

- (void)toast:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:message preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:YES completion:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [alert dismissViewControllerAnimated:YES completion:nil];
    });
}

// Package page in Sileo; adds the source first if Sileo doesn't have it.
- (void)openSileo {
    NSURL *package = [NSURL URLWithString:[@"sileo://package/" stringByAppendingString:kSCPPackageID]];
    NSURL *source = [NSURL URLWithString:[@"sileo://source/" stringByAppendingString:kSCPRepoURL]];
    [[UIApplication sharedApplication] openURL:package options:@{} completionHandler:^(BOOL success) {
        if (!success) [[UIApplication sharedApplication] openURL:source options:@{} completionHandler:nil];
    }];
}

// Reads the repo's Packages file and compares its version with this one.
- (void)checkForUpdate {
    if (_checking) return;
    _checking = YES;
    [self rebuildRows];
    NSURL *url = [NSURL URLWithString:[kSCPRepoURL stringByAppendingString:@"Packages"]];
    NSURLRequest *request = [NSURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSString *latest = nil;
        NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        NSString *marker = [NSString stringWithFormat:@"Package: %@\n", kSCPPackageID];
        for (NSString *stanza in [text componentsSeparatedByString:@"\n\n"]) {
            if ([[stanza stringByAppendingString:@"\n"] rangeOfString:marker].location == NSNotFound) continue;
            for (NSString *line in [stanza componentsSeparatedByString:@"\n"]) {
                if (![line hasPrefix:@"Version: "]) continue;
                NSString *version = [line substringFromIndex:9];
                if (!latest || SCPCompareVersions(version, latest) == NSOrderedDescending) latest = version;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_checking = NO;
            if (!latest) {
                self->_updateStatus = @"Không kiểm tra được";
            } else if (SCPCompareVersions(latest, [self appVersion]) == NSOrderedDescending) {
                self->_updateStatus = [NSString stringWithFormat:@"Có bản %@", latest];
            } else {
                self->_updateStatus = @"Đang là bản mới nhất";
            }
            [self rebuildRows];
        });
    }] resume];
}

- (void)shareLogFrom:(UIView *)anchor {
    NSData *data = [NSData dataWithContentsOfFile:kSCPLogPath];
    if (data.length == 0) {
        [self toast:@"Chưa có log"];
        return;
    }
    NSString *copyPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"splitcarplay_hosting.log"];
    [data writeToFile:copyPath atomically:YES];
    UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:copyPath]]
                                                                        applicationActivities:nil];
    sheet.popoverPresentationController.sourceView = anchor;
    sheet.popoverPresentationController.sourceRect = anchor.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)confirmReset {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Đặt lại toàn bộ cài đặt?"
                                                                   message:@"Mọi lựa chọn sẽ về mặc định và \"Đang bật\" sẽ tắt."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Đặt lại" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        CFArrayRef keys = CFPreferencesCopyKeyList(SCP_PREFS_DOMAIN, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        if (keys) {
            CFPreferencesSetMultiple(NULL, keys, SCP_PREFS_DOMAIN, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
            CFRelease(keys);
        }
        CFPreferencesAppSynchronize(SCP_PREFS_DOMAIN);
        SCPPostReload();
        [self toast:@"Đã đặt lại"];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
