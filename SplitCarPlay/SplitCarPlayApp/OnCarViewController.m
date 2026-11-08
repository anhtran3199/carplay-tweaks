//
//  OnCarViewController.m -- "Trên xe" tab
//
//  Native UIKit re-implementation of what used to be the Settings
//  Root.plist (Prefs.bundle) -- same shared prefs file, same keys, just
//  a plain table view instead of PSSpecifiers now that this is its own
//  app rather than a Settings panel. See ROADMAP.md's "Architecture
//  pivot" entry for why.
//
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "../SplitCarPlayShared.h"

extern NSString *SplitCarPlayDisplayNameForBundleID(NSString *bundleID); // AppPickerController.m
extern void SplitCarPlaySetPref(NSString *key, id value); // AppPickerController.m
@interface AppPickerController : UIViewController
+ (void)presentFrom:(UIViewController *)presenter title:(NSString *)title onPick:(void (^)(NSString *bundleID))onPick;
@end


typedef NS_ENUM(NSInteger, SplitCarPlayRowKind) {
    SplitCarPlayRowKindSwitch,
    SplitCarPlayRowKindSlider,
    SplitCarPlayRowKindButton,
};

@interface SplitCarPlayRow : NSObject
@property (nonatomic, copy) NSString *label;
@property (nonatomic, copy) NSString *key;
@property (nonatomic, assign) SplitCarPlayRowKind kind;
@property (nonatomic, assign) CGFloat sliderMin;
@property (nonatomic, assign) CGFloat sliderMax;
@property (nonatomic, assign) BOOL defaultOn; // SplitCarPlayRowKindSwitch only -- must match Tweak.xm's loadPreferences defaults
@property (nonatomic, copy) NSString *buttonAction; // selector name as string, resolved in cellForRow
@end
@implementation SplitCarPlayRow
@end

#pragma mark - Log viewer (for the experimental section below)

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

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                                              target:self action:@selector(reload)];

    _textView = [[UITextView alloc] init];
    _textView.editable = NO;
    _textView.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont systemFontOfSize:11];
    [self.view addSubview:_textView];

    [self reload];
}

- (void)reload {
    NSString *content = [NSString stringWithContentsOfFile:kHostingLogPath encoding:NSUTF8StringEncoding error:nil];
    _textView.text = content.length > 0 ? content
        : @"(Chưa có log — log chỉ được ghi khi \"Bật thử nghiệm\" ở trên đang BẬT và CarPlay thật được cắm vào.)";
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _textView.frame = self.view.bounds;
}

@end

@interface OnCarViewController : UITableViewController
@end

@implementation OnCarViewController {
    NSArray<NSString *> *_sectionTitles;
    NSArray<NSString *> *_sectionFooters;
    NSArray<NSArray<SplitCarPlayRow *> *> *_sections;
}

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (SplitCarPlayRow *)rowSwitch:(NSString *)label key:(NSString *)key {
    return [self rowSwitch:label key:key default:YES];
}

- (SplitCarPlayRow *)rowSwitch:(NSString *)label key:(NSString *)key default:(BOOL)defaultOn {
    SplitCarPlayRow *row = [SplitCarPlayRow new];
    row.label = label; row.key = key; row.kind = SplitCarPlayRowKindSwitch; row.defaultOn = defaultOn;
    return row;
}

- (SplitCarPlayRow *)rowSlider:(NSString *)label key:(NSString *)key min:(CGFloat)min max:(CGFloat)max {
    SplitCarPlayRow *row = [SplitCarPlayRow new];
    row.label = label; row.key = key; row.kind = SplitCarPlayRowKindSlider;
    row.sliderMin = min; row.sliderMax = max;
    return row;
}

- (SplitCarPlayRow *)rowButton:(NSString *)label key:(NSString *)key {
    SplitCarPlayRow *row = [SplitCarPlayRow new];
    row.label = label; row.key = key; row.kind = SplitCarPlayRowKindButton;
    return row;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Trên xe";

    _sectionTitles = @[@"Trạng thái", @"Ứng dụng", @"Bố cục", @"Thẻ tốc độ", @"Ứng dụng nguồn (Vietmap Live)", @"Thử nghiệm: chia màn hình CarPlay thật"];
    _sectionFooters = @[
        @"", @"", @"", @"", @"",
        @"⚠️ Chế độ thử 1 lần: công tắc tự TẮT khi bắt đầu một lần thử, nên lần cắm CarPlay sau sẽ trở lại bình thường. Cửa sổ chỉ hiện khi đã có app; nếu sau 12 giây không có app nào thì tự gỡ. Muốn app tự hiện mỗi lần cắm xe thì dùng công tắc \"Đang bật\" ở Trang chủ. Trên màn hình xe: bấm ✕ hoặc giữ 2 ngón tay 1 giây để thoát. Mọi bước được ghi vào log debug.",
    ];
    _sections = @[
        @[ [self rowSwitch:@"Bật tính năng" key:@"enabled"] ],
        @[ [self rowButton:@"Ô 1" key:@"leftBundleID"],
           [self rowButton:@"Ô 2" key:@"rightBundleID"] ],
        @[ [self rowSlider:@"Tỉ lệ chia (trái %)" key:@"splitRatio" min:0.2 max:0.8],
           [self rowSwitch:@"Hiện thanh chia" key:@"showDivider"],
           [self rowButton:@"Kiểu bong bóng" key:@"bubbleStyle"],
           [self rowButton:@"Vị trí bong bóng" key:@"bubblePosition"],
           [self rowSlider:@"Kích thước bong bóng" key:@"bubbleScale" min:0.6 max:1.6] ],
        @[ [self rowSwitch:@"Cảnh báo vượt tốc độ" key:@"speedAudioAlert"],
           [self rowSwitch:@"Hiện ngày" key:@"showDate"],
           [self rowSwitch:@"Hiện pin" key:@"showBattery"],
           [self rowSwitch:@"Hiện nhạc đang phát" key:@"showNowPlaying"] ],
        @[ [self rowSwitch:@"Giữ chạy nền" key:@"keepSourceAppAlive"],
           [self rowSwitch:@"Tự thoát khi rút CarPlay" key:@"autoExitSourceApp" default:NO] ],
        @[ [self rowSwitch:@"⚠️ Bật thử nghiệm (1 lần)" key:@"experimentalHostingEnabled" default:NO],
           [self rowSwitch:@"Chỉ 1 app toàn màn hình (ô 1)" key:@"experimentalSingleApp" default:YES],
           [self rowButton:@"Xem log debug" key:@"_viewLog"] ],
    ];
}

// Re-read prefs each time the tab shows: the tweak turns
// experimentalHostingEnabled back off by itself after each attempt.
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (NSDictionary *)prefs {
    return SCPCopyPrefs(); // includes the shared defaults (../SplitCarPlayShared.h)
}

- (BOOL)boolForKey:(NSString *)key default:(BOOL)defaultValue {
    id value = [self prefs][key];
    return value ? [value boolValue] : defaultValue;
}

- (CGFloat)floatForKey:(NSString *)key default:(CGFloat)defaultValue {
    id value = [self prefs][key];
    return value ? [value doubleValue] : defaultValue;
}

#pragma mark - Table view

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return _sections.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return _sectionTitles[section];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    NSString *footer = _sectionFooters[section];
    return footer.length > 0 ? footer : nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _sections[section].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    SplitCarPlayRow *row = _sections[indexPath.section][indexPath.row];
    static NSString * const kIdentifier = @"Row";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kIdentifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:kIdentifier];
    cell.textLabel.text = row.label;
    cell.detailTextLabel.text = nil;
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    switch (row.kind) {
        case SplitCarPlayRowKindSwitch: {
            UISwitch *toggle = [[UISwitch alloc] init];
            toggle.on = [self boolForKey:row.key default:row.defaultOn];
            toggle.tag = indexPath.section * 100 + indexPath.row;
            [toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
            objc_setAssociatedObject(toggle, "key", row.key, OBJC_ASSOCIATION_RETAIN);
            cell.accessoryView = toggle;
            break;
        }
        case SplitCarPlayRowKindSlider: {
            UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 160, 31)];
            slider.minimumValue = row.sliderMin;
            slider.maximumValue = row.sliderMax;
            slider.value = [self floatForKey:row.key default:(row.sliderMin + row.sliderMax) / 2.0];
            [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
            objc_setAssociatedObject(slider, "key", row.key, OBJC_ASSOCIATION_RETAIN);
            cell.accessoryView = slider;
            break;
        }
        case SplitCarPlayRowKindButton: {
            cell.detailTextLabel.text = [self detailTextForButtonRow:row];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            break;
        }
    }
    return cell;
}

- (NSString *)detailTextForButtonRow:(SplitCarPlayRow *)row {
    if ([row.key isEqualToString:@"leftBundleID"] || [row.key isEqualToString:@"rightBundleID"]) {
        return SplitCarPlayDisplayNameForBundleID([self prefs][row.key]) ?: @"(chưa chọn)";
    }
    if ([row.key isEqualToString:@"bubbleStyle"]) {
        NSArray *names = @[@"Card", @"Ring", @"Bar"];
        NSInteger index = [self floatForKey:row.key default:0];
        return names[MAX(0, MIN(names.count - 1, index))];
    }
    if ([row.key isEqualToString:@"bubblePosition"]) {
        NSArray *names = @[@"Trái", @"Phải"];
        NSInteger index = [self floatForKey:row.key default:1];
        return names[MAX(0, MIN(names.count - 1, index))];
    }
    return nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    SplitCarPlayRow *row = _sections[indexPath.section][indexPath.row];
    if (row.kind != SplitCarPlayRowKindButton) return;

    if ([row.key isEqualToString:@"leftBundleID"] || [row.key isEqualToString:@"rightBundleID"]) {
        NSString *key = row.key;
        [AppPickerController presentFrom:self
                                    title:[key isEqualToString:@"leftBundleID"] ? @"Chọn app ô 1" : @"Chọn app ô 2"
                                   onPick:^(NSString *bundleID) {
            SplitCarPlaySetPref(key, bundleID);
            [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
        }];
        return;
    }
    if ([row.key isEqualToString:@"bubbleStyle"]) {
        [self presentChoiceForKey:@"bubbleStyle" title:@"Kiểu bong bóng" options:@[@"Card", @"Ring", @"Bar"] indexPath:indexPath];
        return;
    }
    if ([row.key isEqualToString:@"bubblePosition"]) {
        [self presentChoiceForKey:@"bubblePosition" title:@"Vị trí bong bóng" options:@[@"Trái", @"Phải"] indexPath:indexPath];
        return;
    }
    if ([row.key isEqualToString:@"_viewLog"]) {
        [self.navigationController pushViewController:[[LogViewerController alloc] init] animated:YES];
        return;
    }
}

- (void)presentChoiceForKey:(NSString *)key title:(NSString *)title options:(NSArray<NSString *> *)options indexPath:(NSIndexPath *)indexPath {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [options enumerateObjectsUsingBlock:^(NSString *option, NSUInteger index, BOOL *stop) {
        [sheet addAction:[UIAlertAction actionWithTitle:option style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            SplitCarPlaySetPref(key, @(index));
            [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
        }]];
    }];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
    // iPad needs a popover anchor or this crashes; harmless on iPhone.
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = [self.tableView rectForRowAtIndexPath:indexPath];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)switchChanged:(UISwitch *)sender {
    NSString *key = objc_getAssociatedObject(sender, "key");
    SplitCarPlaySetPref(key, @(sender.isOn));
}

- (void)sliderChanged:(UISlider *)sender {
    NSString *key = objc_getAssociatedObject(sender, "key");
    SplitCarPlaySetPref(key, @(sender.value));
}

@end
