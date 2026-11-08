//
//  OnCarViewController.m -- "Trên xe" tab
//
//  Laid out like SidePlay2's tab of the same name: a CARPLAY section of
//  switches and a TUỲ CHỈNH section of sub-pages, plus NÂNG CAO (the
//  one-shot test switch and the debug log). Every value is a pref in the
//  shared domain (../SplitCarPlayShared.h), read by Tweak.xm in SpringBoard.
//
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "../SplitCarPlayShared.h"

extern NSString *SplitCarPlayDisplayNameForBundleID(NSString *bundleID); // AppPickerController.m
extern UIImage *SplitCarPlayAppIcon(NSString *bundleID);                 // AppPickerController.m
extern NSArray<NSString *> *SplitCarPlayUserInstalledBundleIDsSorted(void); // AppPickerController.m
extern void SplitCarPlaySetPref(NSString *key, id value);                // AppPickerController.m
@interface AppPickerController : UIViewController
+ (void)presentFrom:(UIViewController *)presenter title:(NSString *)title onPick:(void (^)(NSString *bundleID))onPick;
@end

static const NSUInteger kSCPMaxCarApps = 12;

#pragma mark - Rows

typedef NS_ENUM(NSInteger, SCPRowKind) {
    SCPRowKindSwitch,
    SCPRowKindSlider,
    SCPRowKindChoice,   // one of `options`, stored as its index
    SCPRowKindApp,      // a bundle ID, picked with AppPickerController
    SCPRowKindPage,     // pushes `pageBuilder`
    SCPRowKindAction,   // runs `action`
};

@interface SCPRow : NSObject
@property (nonatomic, copy) NSString *label;
@property (nonatomic, copy) NSString *key;
@property (nonatomic, assign) SCPRowKind kind;
@property (nonatomic, copy) NSString *symbol;      // SF Symbol for the coloured square, optional
@property (nonatomic, strong) UIColor *symbolColor;
@property (nonatomic, assign) BOOL defaultOn;
@property (nonatomic, assign) CGFloat sliderMin;
@property (nonatomic, assign) CGFloat sliderMax;
@property (nonatomic, copy) NSArray<NSString *> *options;
@property (nonatomic, strong) NSArray *optionValues; // stored instead of the index when set
@property (nonatomic, copy) NSString * (^detail)(NSDictionary *prefs);
@property (nonatomic, copy) UIViewController * (^pageBuilder)(void);
@property (nonatomic, copy) void (^action)(UIViewController *from);
@property (nonatomic, copy) void (^afterChange)(id value); // e.g. keep two prefs in sync
@end

@implementation SCPRow
@end

static SCPRow *SCPSwitch(NSString *label, NSString *key, BOOL defaultOn) {
    SCPRow *row = [SCPRow new];
    row.label = label; row.key = key; row.kind = SCPRowKindSwitch; row.defaultOn = defaultOn;
    return row;
}

static SCPRow *SCPSlider(NSString *label, NSString *key, CGFloat min, CGFloat max) {
    SCPRow *row = [SCPRow new];
    row.label = label; row.key = key; row.kind = SCPRowKindSlider; row.sliderMin = min; row.sliderMax = max;
    return row;
}

static SCPRow *SCPChoice(NSString *label, NSString *key, NSArray<NSString *> *options) {
    SCPRow *row = [SCPRow new];
    row.label = label; row.key = key; row.kind = SCPRowKindChoice; row.options = options;
    return row;
}

static SCPRow *SCPApp(NSString *label, NSString *key) {
    SCPRow *row = [SCPRow new];
    row.label = label; row.key = key; row.kind = SCPRowKindApp;
    return row;
}

static SCPRow *SCPPage(NSString *label, UIViewController * (^builder)(void)) {
    SCPRow *row = [SCPRow new];
    row.label = label; row.kind = SCPRowKindPage; row.pageBuilder = builder;
    return row;
}

static SCPRow *SCPWithIcon(SCPRow *row, NSString *symbol, UIColor *color) {
    row.symbol = symbol;
    row.symbolColor = color;
    return row;
}

static UIImage *SCPRowIcon(NSString *symbol, UIColor *color) {
    CGFloat size = 29;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(size, size)];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [color setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size, size) cornerRadius:7] fill];
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];
        UIImage *glyph = [[UIImage systemImageNamed:symbol withConfiguration:config] imageWithTintColor:[UIColor whiteColor]
                                                                                           renderingMode:UIImageRenderingModeAlwaysOriginal];
        if (glyph) {
            CGSize g = glyph.size;
            [glyph drawInRect:CGRectMake((size - g.width) / 2.0, (size - g.height) / 2.0, g.width, g.height)];
        }
    }];
}

#pragma mark - Generic settings list

@interface SCPSettingsListController : UITableViewController
@property (nonatomic, copy) NSArray<NSString *> *sectionTitles;
@property (nonatomic, copy) NSArray<NSString *> *sectionFooters;
@property (nonatomic, copy) NSArray<NSArray<SCPRow *> *> *sections;
@end

@implementation SCPSettingsListController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData]; // SpringBoard changes some prefs by itself
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.sections.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSString *title = section < (NSInteger)self.sectionTitles.count ? self.sectionTitles[section] : nil;
    return title.length ? title : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    NSString *footer = section < (NSInteger)self.sectionFooters.count ? self.sectionFooters[section] : nil;
    return footer.length ? footer : nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.sections[section].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    SCPRow *row = self.sections[indexPath.section][indexPath.row];
    NSDictionary *prefs = SCPCopyPrefs();
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.textLabel.text = row.label;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (row.symbol) cell.imageView.image = SCPRowIcon(row.symbol, row.symbolColor ?: [UIColor systemBlueColor]);

    switch (row.kind) {
        case SCPRowKindSwitch: {
            UISwitch *toggle = [[UISwitch alloc] init];
            toggle.on = prefs[row.key] ? [prefs[row.key] boolValue] : row.defaultOn;
            [toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
            objc_setAssociatedObject(toggle, "row", row, OBJC_ASSOCIATION_RETAIN);
            cell.accessoryView = toggle;
            break;
        }
        case SCPRowKindSlider: {
            UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 150, 31)];
            slider.minimumValue = row.sliderMin;
            slider.maximumValue = row.sliderMax;
            slider.value = prefs[row.key] ? [prefs[row.key] floatValue] : (row.sliderMin + row.sliderMax) / 2.0;
            [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
            objc_setAssociatedObject(slider, "row", row, OBJC_ASSOCIATION_RETAIN);
            cell.accessoryView = slider;
            break;
        }
        case SCPRowKindChoice:
        case SCPRowKindApp:
        case SCPRowKindPage:
        case SCPRowKindAction:
            cell.detailTextLabel.text = [self detailForRow:row prefs:prefs];
            cell.accessoryType = row.kind == SCPRowKindAction ? UITableViewCellAccessoryNone : UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            if (row.kind == SCPRowKindApp) {
                UIImage *icon = SplitCarPlayAppIcon(prefs[row.key]);
                if (icon) {
                    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(29, 29)];
                    cell.imageView.image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
                        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 29, 29) cornerRadius:7] addClip];
                        [icon drawInRect:CGRectMake(0, 0, 29, 29)];
                    }];
                }
            }
            break;
    }
    return cell;
}

- (NSString *)detailForRow:(SCPRow *)row prefs:(NSDictionary *)prefs {
    if (row.detail) return row.detail(prefs);
    if (row.kind == SCPRowKindApp) return SplitCarPlayDisplayNameForBundleID(prefs[row.key]) ?: @"(chưa chọn)";
    if (row.kind == SCPRowKindChoice) {
        id stored = prefs[row.key];
        NSUInteger index = row.optionValues ? [row.optionValues indexOfObject:stored ?: @0] : (NSUInteger)[stored integerValue];
        if (index == NSNotFound || index >= row.options.count) index = 0;
        return row.options[index];
    }
    return nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    SCPRow *row = self.sections[indexPath.section][indexPath.row];
    __weak __typeof__(self) weakSelf = self;
    switch (row.kind) {
        case SCPRowKindPage: {
            UIViewController *page = row.pageBuilder ? row.pageBuilder() : nil;
            if (page) [self.navigationController pushViewController:page animated:YES];
            break;
        }
        case SCPRowKindAction:
            if (row.action) row.action(self);
            break;
        case SCPRowKindApp: {
            [AppPickerController presentFrom:self title:row.label onPick:^(NSString *bundleID) {
                SplitCarPlaySetPref(row.key, bundleID);
                if (row.afterChange) row.afterChange(bundleID);
                [weakSelf.tableView reloadData];
            }];
            break;
        }
        case SCPRowKindChoice: {
            UIAlertController *sheet = [UIAlertController alertControllerWithTitle:row.label message:nil preferredStyle:UIAlertControllerStyleActionSheet];
            [row.options enumerateObjectsUsingBlock:^(NSString *option, NSUInteger index, BOOL *stop) {
                [sheet addAction:[UIAlertAction actionWithTitle:option style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    id value = row.optionValues ? row.optionValues[index] : @(index);
                    SplitCarPlaySetPref(row.key, value);
                    if (row.afterChange) row.afterChange(value);
                    [weakSelf.tableView reloadData];
                }]];
            }];
            [sheet addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
            sheet.popoverPresentationController.sourceView = self.view;
            sheet.popoverPresentationController.sourceRect = [tableView rectForRowAtIndexPath:indexPath];
            [self presentViewController:sheet animated:YES completion:nil];
            break;
        }
        default:
            break;
    }
}

- (void)switchChanged:(UISwitch *)sender {
    SCPRow *row = objc_getAssociatedObject(sender, "row");
    SplitCarPlaySetPref(row.key, @(sender.isOn));
    if (row.afterChange) row.afterChange(@(sender.isOn));
}

- (void)sliderChanged:(UISlider *)sender {
    SCPRow *row = objc_getAssociatedObject(sender, "row");
    SplitCarPlaySetPref(row.key, @(sender.value));
}

@end

#pragma mark - "Ứng dụng": which apps the car's app bar offers

@interface SCPCarAppsController : UITableViewController
@end

@implementation SCPCarAppsController {
    NSArray<NSString *> *_installed;
    NSMutableArray<NSString *> *_chosen;
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Ứng dụng";
    _installed = SplitCarPlayUserInstalledBundleIDsSorted();
    NSArray *stored = SCPCopyPrefs()[@"carApps"];
    _chosen = [stored isKindOfClass:[NSArray class]] ? [stored mutableCopy] : [NSMutableArray new];
    [self updateTitle];
}

- (void)updateTitle {
    self.navigationItem.prompt = nil;
    self.title = [NSString stringWithFormat:@"Ứng dụng (%lu/%lu)", (unsigned long)_chosen.count, (unsigned long)kSCPMaxCarApps];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _installed.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return [NSString stringWithFormat:@"Các app được chọn (tối đa %lu) hiện trên thanh tab ở màn hình xe. Trên xe: chạm icon để mở ở ô 1, giữ icon để mở ở ô 2.", (unsigned long)kSCPMaxCarApps];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *bundleID = _installed[indexPath.row];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.textLabel.text = SplitCarPlayDisplayNameForBundleID(bundleID);
    UIImage *icon = SplitCarPlayAppIcon(bundleID);
    if (icon) {
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(29, 29)];
        cell.imageView.image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 29, 29) cornerRadius:7] addClip];
            [icon drawInRect:CGRectMake(0, 0, 29, 29)];
        }];
    }
    cell.accessoryType = [_chosen containsObject:bundleID] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *bundleID = _installed[indexPath.row];
    if ([_chosen containsObject:bundleID]) {
        [_chosen removeObject:bundleID];
    } else if (_chosen.count < kSCPMaxCarApps) {
        [_chosen addObject:bundleID];
    } else {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Đã đủ 12 app"
                                                                       message:@"Bỏ chọn một app khác trước."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    SplitCarPlaySetPref(@"carApps", [_chosen copy]);
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    [self updateTitle];
}

@end

#pragma mark - Log viewer (share / clear)

static NSString * const kHostingLogPath = @"/var/mobile/Library/Logs/splitcarplay_hosting.log";

@interface LogViewerController : UIViewController
@end

@implementation LogViewerController {
    UITextView *_textView;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Log debug";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    UIBarButtonItem *share = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                                           target:self action:@selector(shareLog:)];
    UIBarButtonItem *reload = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                            target:self action:@selector(reload)];
    UIBarButtonItem *clear = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemTrash
                                                                           target:self action:@selector(confirmClear)];
    self.navigationItem.rightBarButtonItems = @[share, reload, clear];

    _textView = [[UITextView alloc] init];
    _textView.editable = NO;
    _textView.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont systemFontOfSize:11];
    [self.view addSubview:_textView];

    [self reload];
}

- (void)reload {
    NSString *content = [NSString stringWithContentsOfFile:kHostingLogPath encoding:NSUTF8StringEncoding error:nil];
    _textView.text = content.length > 0 ? content : @"(Chưa có log.)";
    if (content.length > 0) {
        // Newest lines are at the end.
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_textView scrollRangeToVisible:NSMakeRange(self->_textView.text.length - 1, 1)];
        });
    }
}

// Shares a copy (in this app's tmp folder) so the receiving app can read it.
- (void)shareLog:(UIBarButtonItem *)sender {
    NSData *data = [NSData dataWithContentsOfFile:kHostingLogPath];
    if (data.length == 0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Chưa có log" message:nil preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    NSString *copyPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"splitcarplay_hosting.log"];
    [data writeToFile:copyPath atomically:YES];
    NSArray *items = @[[NSURL fileURLWithPath:copyPath]];
    UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
    sheet.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)confirmClear {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Xoá log?"
                                                                   message:@"Xoá trước khi thử lại để log mới dễ đọc hơn."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Xoá" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [[NSData data] writeToFile:kHostingLogPath atomically:NO];
        [self reload];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _textView.frame = self.view.bounds;
}

@end

#pragma mark - "Trên xe"

static NSString *SCPAppBarDetail(NSDictionary *prefs) {
    NSInteger seconds = [prefs[@"appBarAutoHide"] integerValue];
    return seconds > 0 ? [NSString stringWithFormat:@"%ld giây", (long)seconds] : @"Luôn hiện";
}

@interface OnCarViewController : SCPSettingsListController
@end

@implementation OnCarViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Trên xe";
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;

    UIColor *blue = [UIColor systemBlueColor];
    UIColor *indigo = [UIColor systemIndigoColor];

    SCPRow *openOnConnect = SCPWithIcon(SCPSwitch(@"Mở khi kết nối CarPlay", @"carPlayAutoHost", NO), @"car.fill", blue);
    openOnConnect.afterChange = ^(id value) {
        // Same switch as "Đang bật" on Trang chủ.
        if ([value boolValue]) {
            SplitCarPlaySetPref(@"enabled", @YES);
            SplitCarPlaySetPref(@"carPlayCrashNotice", @NO);
        }
    };

    self.sectionTitles = @[@"CarPlay", @"Tuỳ chỉnh", @"Nâng cao"];
    self.sectionFooters = @[
        @"\"Mở khi kết nối CarPlay\" là cùng công tắc với \"Đang bật\" ở Trang chủ. \"Tự làm tối màn hình\": 10 giây sau khi app hiện trên xe, màn hình điện thoại tối đi; tắt app trên xe thì sáng lại.",
        @"",
        @"\"Thử 1 lần\" tự TẮT khi bắt đầu một lần thử. Trên màn hình xe: bấm ✕ trên thanh tab hoặc giữ 2 ngón tay 1 giây để quay về CarPlay bình thường.",
    ];
    self.sections = @[
        @[ openOnConnect,
           SCPWithIcon(SCPSwitch(@"Mở lại bố cục lần cuối", @"restoreLastLayout", YES), @"arrow.counterclockwise", indigo),
           SCPWithIcon(SCPSwitch(@"Tự làm tối màn hình", @"autoDimPhone", NO), @"power", indigo) ],
        @[ SCPWithIcon(SCPPage(@"Bong bóng tốc độ", ^UIViewController *{ return [OnCarViewController bubblePage]; }),
                       @"speedometer", [UIColor systemOrangeColor]),
           [self appBarRow],
           SCPWithIcon(SCPPage(@"Mở nhanh", ^UIViewController *{ return [OnCarViewController quickOpenPage]; }),
                       @"sparkles", blue),
           SCPWithIcon(SCPPage(@"Màn hình trên xe", ^UIViewController *{ return [OnCarViewController carScreenPage]; }),
                       @"rectangle.split.2x1", blue),
           [self appsRow] ],
        @[ SCPWithIcon(SCPSwitch(@"Thử 1 lần (lần cắm xe tới)", @"experimentalHostingEnabled", NO), @"exclamationmark.triangle.fill", [UIColor systemYellowColor]),
           [self logRow] ],
    ];
}

- (SCPRow *)appBarRow {
    SCPRow *row = SCPChoice(@"Thanh tab ứng dụng", @"appBarAutoHide", @[@"Luôn hiện", @"3 giây", @"5 giây", @"10 giây"]);
    row.optionValues = @[@0, @3, @5, @10];
    row.detail = ^NSString *(NSDictionary *prefs) { return SCPAppBarDetail(prefs); };
    return SCPWithIcon(row, @"menubar.rectangle", [UIColor systemGrayColor]);
}

- (SCPRow *)appsRow {
    SCPRow *row = SCPPage(@"Ứng dụng", ^UIViewController *{ return [SCPCarAppsController new]; });
    row.detail = ^NSString *(NSDictionary *prefs) {
        NSArray *apps = [prefs[@"carApps"] isKindOfClass:[NSArray class]] ? prefs[@"carApps"] : @[];
        return [NSString stringWithFormat:@"%lu/%lu", (unsigned long)apps.count, (unsigned long)kSCPMaxCarApps];
    };
    return SCPWithIcon(row, @"square.grid.2x2.fill", [UIColor systemPurpleColor]);
}

- (SCPRow *)logRow {
    SCPRow *row = SCPPage(@"Xem log debug", ^UIViewController *{ return [LogViewerController new]; });
    return SCPWithIcon(row, @"doc.text.magnifyingglass", [UIColor systemGrayColor]);
}

+ (UIViewController *)bubblePage {
    SCPSettingsListController *page = [SCPSettingsListController new];
    page.title = @"Bong bóng tốc độ";
    page.sectionTitles = @[@"", @"Hiển thị", @"Ứng dụng nguồn (Vietmap Live)"];
    page.sectionFooters = @[@"", @"", @"Tốc độ lấy từ Vietmap Live đang chạy trên điện thoại."];
    page.sections = @[
        @[ SCPSwitch(@"Hiện bong bóng", @"showSpeedBubble", YES),
           SCPChoice(@"Kiểu", @"bubbleStyle", @[@"Card", @"Ring", @"Bar"]),
           SCPChoice(@"Vị trí", @"bubblePosition", @[@"Trái", @"Phải"]),
           SCPSlider(@"Kích thước", @"bubbleScale", 0.6, 1.6) ],
        @[ SCPSwitch(@"Cảnh báo vượt tốc độ", @"speedAudioAlert", YES),
           SCPSwitch(@"Hiện ngày", @"showDate", YES),
           SCPSwitch(@"Hiện pin", @"showBattery", YES),
           SCPSwitch(@"Hiện nhạc đang phát", @"showNowPlaying", YES) ],
        @[ SCPSwitch(@"Giữ chạy nền", @"keepSourceAppAlive", YES),
           SCPSwitch(@"Tự thoát khi rút CarPlay", @"autoExitSourceApp", NO) ],
    ];
    return page;
}

+ (UIViewController *)quickOpenPage {
    SCPSettingsListController *page = [SCPSettingsListController new];
    page.title = @"Mở nhanh";
    page.sectionTitles = @[@"Mở khi cắm xe"];
    page.sectionFooters = @[@"Bố cục mở ra khi cắm CarPlay. Nếu bật \"Mở lại bố cục lần cuối\", lần sau sẽ mở lại đúng app và tỉ lệ đã dùng lần trước trên xe thay cho bố cục này."];
    page.sections = @[
        @[ SCPApp(@"Ô 1", @"leftBundleID"),
           SCPApp(@"Ô 2", @"rightBundleID"),
           SCPSwitch(@"Chỉ 1 app toàn màn hình (ô 1)", @"experimentalSingleApp", YES) ],
    ];
    return page;
}

+ (UIViewController *)carScreenPage {
    SCPSettingsListController *page = [SCPSettingsListController new];
    page.title = @"Màn hình trên xe";
    page.sectionTitles = @[@"Bố cục"];
    page.sectionFooters = @[@"Trên xe có thể kéo thanh chia để đổi tỉ lệ; tỉ lệ mới được nhớ lại."];
    page.sections = @[
        @[ SCPSlider(@"Tỉ lệ chia (ô 1)", @"splitRatio", 0.2, 0.8),
           SCPSwitch(@"Hiện thanh chia", @"showDivider", YES) ],
    ];
    return page;
}

@end
