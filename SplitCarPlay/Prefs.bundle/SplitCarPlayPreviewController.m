//
//  SplitCarPlayPreviewController.m
//
//  A "Mô phỏng" (simulation) screen, same idea as Vietmap Live's own
//  preview tab and SidePlay2's static mockup images (see ROADMAP.md) —
//  shows what the CarPlay layout/speed bubble will look like without
//  needing to actually be plugged into a car.
//
//  WHY THIS IS A SEPARATE COPY OF THE BUBBLE RENDERING, NOT A REUSE
//
//  This runs inside Settings.app/Preferences.app (Prefs.bundle is its
//  own Mach-O image), which never loads SplitCarPlay.dylib (that only
//  injects into CarPlayApp/springboard/Vietmap Live — see
//  SplitCarPlay.plist). So the real SpeedBubbleView class from Tweak.xm
//  isn't available here; this is a small, intentionally-duplicated
//  render of the same three styles, fed either real data (the shared
//  state file is a plain path on disk, readable from any process) or
//  clearly-labeled demo numbers when there's nothing real to show yet.
//
//  WHY THE APP PLACEHOLDERS SHOW AN ICON, NOT A LIVE APP VIEW
//
//  SidePlay2's own preview actually renders its navigation app live.
//  That's not reproducible here: Settings.app/Preferences.app has no way
//  to host another app's scene the way CarPlayApp can (the exact
//  mechanism `Tweak.xm`'s `hostApp:inContainer:replacingExisting:` uses,
//  and still marked ADAPT/untested there) — this process simply isn't
//  CarPlayApp. Showing the real app icon (same private API the picker
//  list already uses) is the honest, safe middle ground: more "alive"
//  looking than plain text, without pretending to do something this
//  process can't actually do.
//
#import <UIKit/UIKit.h>

extern NSString *SplitCarPlayDisplayNameForBundleID(NSString *bundleID); // SplitCarPlayAppPickerController.m
extern UIImage *SplitCarPlayAppIcon(NSString *bundleID); // SplitCarPlayAppPickerController.m

typedef NS_ENUM(NSInteger, SplitCarPlayBubbleStyle) {
    SplitCarPlayBubbleStyleCard = 0,
    SplitCarPlayBubbleStyleRing = 1,
    SplitCarPlayBubbleStyleBar = 2,
};

static NSString * const kPrefsPath = @"/var/mobile/Library/Preferences/com.example.splitcarplay.plist";
static NSString * const kReloadNotification = @"com.example.splitcarplay/reload";
static NSString * const kVietmapSharedStatePath = @"/var/mobile/Library/Caches/com.example.splitcarplay/vietmap_speed.plist";

static void SplitCarPlaySetPref(NSString *key, id value) {
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:kPrefsPath] ?: [NSMutableDictionary new];
    prefs[key] = value;
    [prefs writeToFile:kPrefsPath atomically:YES];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                          (__bridge CFStringRef)kReloadNotification, NULL, NULL, YES);
}

#pragma mark - Minimal bubble preview (3 styles — mirrors Tweak.xm's SpeedBubbleView)

@interface SplitCarPlayPreviewBubbleView : UIView
@property (nonatomic, assign) SplitCarPlayBubbleStyle style;
@property (nonatomic, assign) BOOL showDate;
@property (nonatomic, assign) BOOL showBattery;
// isLive = real Vietmap Live data vs. made-up demo numbers (controls the
// status icon/text and whether the ring/bar tint as "connected"); the
// speed number itself always shows (demo or real) so the preview always
// looks populated.
- (void)applySpeedText:(NSString *)text overLimit:(BOOL)overLimit isLive:(BOOL)isLive;
@end

@implementation SplitCarPlayPreviewBubbleView {
    UIView *_speedBox;
    UILabel *_speedLabel;
    UILabel *_unitLabel;
    UIImageView *_statusIconView;
    UILabel *_statusLabel;
    UIView *_statusBar;
    UILabel *_extrasLabel;
    CAShapeLayer *_ringLayer;
    CAShapeLayer *_maskLayer;
    NSDateFormatter *_timeFormatter;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.96];
        self.layer.borderWidth = 1;
        self.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.08].CGColor;

        // Rounded-corner clip via a mask (not masksToBounds=YES), so the
        // drop shadow below isn't clipped away too — same technique as
        // the real SpeedBubbleView in Tweak.xm.
        self.layer.masksToBounds = NO;
        _maskLayer = [CAShapeLayer new];
        self.layer.mask = _maskLayer;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.25;
        self.layer.shadowRadius = 6;
        self.layer.shadowOffset = CGSizeMake(0, 2);

        _timeFormatter = [NSDateFormatter new];
        _timeFormatter.dateFormat = @"HH:mm";

        _speedBox = [[UIView alloc] init];
        _speedBox.backgroundColor = [UIColor whiteColor];
        _speedBox.layer.cornerRadius = 8;
        _speedBox.layer.borderWidth = 1.5;
        [self addSubview:_speedBox];

        _speedLabel = [[UILabel alloc] init];
        _speedLabel.textAlignment = NSTextAlignmentCenter;
        _speedLabel.font = [UIFont boldSystemFontOfSize:28];
        _speedLabel.text = @"--";
        [_speedBox addSubview:_speedLabel];
        [self addSubview:_speedLabel];

        _unitLabel = [[UILabel alloc] init];
        _unitLabel.textAlignment = NSTextAlignmentCenter;
        _unitLabel.font = [UIFont systemFontOfSize:11];
        _unitLabel.textColor = [UIColor colorWithWhite:0.4 alpha:1];
        _unitLabel.text = @"km/h";
        [_speedBox addSubview:_unitLabel];
        [self addSubview:_unitLabel];

        _statusIconView = [[UIImageView alloc] init];
        _statusIconView.contentMode = UIViewContentModeScaleAspectFit;
        [self addSubview:_statusIconView];

        _statusLabel = [[UILabel alloc] init];
        _statusLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
        _statusLabel.textAlignment = NSTextAlignmentLeft;
        _statusLabel.numberOfLines = 1;
        _statusLabel.textColor = [UIColor colorWithWhite:0.35 alpha:1];
        [self addSubview:_statusLabel];

        _extrasLabel = [[UILabel alloc] init];
        _extrasLabel.textAlignment = NSTextAlignmentCenter;
        _extrasLabel.font = [UIFont systemFontOfSize:10];
        _extrasLabel.textColor = [UIColor colorWithWhite:0.45 alpha:1];
        [self addSubview:_extrasLabel];

        _statusBar = [[UIView alloc] init];
        [self addSubview:_statusBar];

        _ringLayer = [CAShapeLayer new];
        _ringLayer.fillColor = [UIColor clearColor].CGColor;
        _ringLayer.lineWidth = 5;
        _ringLayer.hidden = YES;
        [self.layer addSublayer:_ringLayer];
    }
    return self;
}

- (void)setStyle:(SplitCarPlayBubbleStyle)style {
    _style = style;
    [self setNeedsLayout];
}

- (void)updateMaskWithCornerRadius:(CGFloat)radius {
    self.layer.cornerRadius = radius;
    _maskLayer.frame = self.bounds;
    _maskLayer.path = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:radius].CGPath;
}

- (NSString *)extrasText {
    NSMutableArray<NSString *> *parts = [NSMutableArray new];
    if (self.showDate) [parts addObject:[_timeFormatter stringFromDate:[NSDate date]]];
    if (self.showBattery) {
        UIDevice *device = [UIDevice currentDevice];
        if (device.batteryState != UIDeviceBatteryStateUnknown) {
            [parts addObject:[NSString stringWithFormat:@"%.0f%%", device.batteryLevel * 100]];
        }
    }
    return [parts componentsJoinedByString:@" · "];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    switch (self.style) {
        case SplitCarPlayBubbleStyleRing: [self layoutRing]; return;
        case SplitCarPlayBubbleStyleBar: [self layoutBar]; return;
        case SplitCarPlayBubbleStyleCard: default: [self layoutCard]; return;
    }
}

- (void)layoutCard {
    [self updateMaskWithCornerRadius:14];
    _ringLayer.hidden = YES;
    _speedBox.hidden = NO;
    _speedLabel.font = [UIFont boldSystemFontOfSize:28];
    [_speedBox addSubview:_speedLabel];
    [_speedBox addSubview:_unitLabel];
    _statusIconView.hidden = NO;
    _statusLabel.hidden = NO;
    _statusBar.hidden = NO;

    CGFloat w = self.bounds.size.width, pad = 8;
    CGFloat y = pad;

    _extrasLabel.hidden = !(self.showDate || self.showBattery);
    if (!_extrasLabel.hidden) {
        _extrasLabel.text = [self extrasText];
        _extrasLabel.frame = CGRectMake(pad, y, w - pad * 2, 12);
        y = CGRectGetMaxY(_extrasLabel.frame) + 2;
    }

    _speedBox.frame = CGRectMake(pad, y, w - pad * 2, 52);
    _speedLabel.frame = CGRectMake(0, 4, _speedBox.bounds.size.width, 30);
    _unitLabel.frame = CGRectMake(0, 34, _speedBox.bounds.size.width, 14);
    y = CGRectGetMaxY(_speedBox.frame) + 6;

    CGFloat iconSize = 14;
    _statusIconView.frame = CGRectMake(pad, y + 1, iconSize, iconSize);
    _statusLabel.frame = CGRectMake(CGRectGetMaxX(_statusIconView.frame) + 4, y, w - pad - CGRectGetMaxX(_statusIconView.frame) - 4, iconSize + 2);

    CGFloat barHeight = 4;
    _statusBar.frame = CGRectMake(pad, self.bounds.size.height - barHeight - 6, w - pad * 2, barHeight);
    _statusBar.layer.cornerRadius = barHeight / 2.0;
}

- (void)layoutRing {
    CGFloat side = MIN(self.bounds.size.width, self.bounds.size.height);
    [self updateMaskWithCornerRadius:side / 2.0];
    _ringLayer.hidden = NO;
    _speedBox.hidden = YES;
    _statusLabel.hidden = YES;
    _statusBar.hidden = YES;
    _extrasLabel.hidden = YES;

    CGRect ringFrame = CGRectMake((self.bounds.size.width - side) / 2.0, (self.bounds.size.height - side) / 2.0, side, side);
    CGFloat inset = _ringLayer.lineWidth / 2.0 + 2;
    _ringLayer.path = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(ringFrame, inset, inset)].CGPath;
    _ringLayer.frame = self.bounds;

    _speedLabel.font = [UIFont boldSystemFontOfSize:28];
    [self addSubview:_speedLabel];
    _speedLabel.frame = CGRectMake(0, side / 2.0 - 20, self.bounds.size.width, 28);
    [self addSubview:_unitLabel];
    _unitLabel.frame = CGRectMake(0, side / 2.0 + 6, self.bounds.size.width, 14);

    _statusIconView.hidden = NO;
    CGFloat iconSize = 16;
    _statusIconView.frame = CGRectMake((self.bounds.size.width - iconSize) / 2.0, side - iconSize - 10, iconSize, iconSize);
}

- (void)layoutBar {
    [self updateMaskWithCornerRadius:self.bounds.size.height / 2.0];
    _ringLayer.hidden = YES;
    _speedBox.hidden = YES;
    _statusLabel.hidden = YES;
    _statusBar.hidden = NO;
    _extrasLabel.hidden = YES;

    CGFloat h = self.bounds.size.height, pad = 10;
    CGFloat iconSize = MIN(16, h - 8);
    _statusIconView.hidden = NO;
    _statusIconView.frame = CGRectMake(pad, (h - iconSize) / 2.0, iconSize, iconSize);
    [self addSubview:_statusIconView];

    _speedLabel.font = [UIFont boldSystemFontOfSize:MIN(22, h * 0.5)];
    [self addSubview:_speedLabel];
    _speedLabel.frame = CGRectMake(CGRectGetMaxX(_statusIconView.frame) + 8, 0, 70, h);
    [self addSubview:_unitLabel];
    _unitLabel.frame = CGRectMake(CGRectGetMaxX(_speedLabel.frame), 0, 36, h);

    CGFloat barHeight = 3;
    _statusBar.frame = CGRectMake(pad, h - barHeight - 3, self.bounds.size.width - pad * 2, barHeight);
    _statusBar.layer.cornerRadius = barHeight / 2.0;
}

- (void)applySpeedText:(NSString *)text overLimit:(BOOL)overLimit isLive:(BOOL)isLive {
    _speedLabel.text = text.length > 0 ? text : @"--";
    UIColor *accent = overLimit ? [UIColor systemRedColor] : [UIColor colorWithWhite:0.75 alpha:1];
    _speedBox.layer.borderColor = accent.CGColor;
    _ringLayer.strokeColor = (overLimit ? [UIColor systemRedColor] : [UIColor systemGrayColor]).CGColor;
    if (@available(iOS 13.0, *)) {
        _statusIconView.image = [UIImage systemImageNamed:isLive ? @"checkmark.circle.fill" : @"questionmark.circle"];
    }
    _statusIconView.tintColor = isLive ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
    _statusLabel.text = isLive ? @"Vietmap Live" : @"Demo";
    _statusBar.backgroundColor = overLimit ? [UIColor systemRedColor]
        : (isLive ? [UIColor systemGreenColor] : [UIColor systemOrangeColor]);
}

@end

#pragma mark - Preview screen

@interface SplitCarPlayPreviewController : UIViewController
@end

@implementation SplitCarPlayPreviewController {
    UIView *_leftPlaceholder;
    UIView *_rightPlaceholder;
    UIImageView *_leftIconView;
    UIImageView *_rightIconView;
    UILabel *_leftLabel;
    UILabel *_rightLabel;
    SplitCarPlayPreviewBubbleView *_bubble;
    UISegmentedControl *_styleControl;
    UISegmentedControl *_positionControl;
    UILabel *_captionLabel;
    CGFloat _splitRatio;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Mô phỏng";
    self.view.backgroundColor = [UIColor blackColor];

    _leftPlaceholder = [self makePlaceholder];
    _rightPlaceholder = [self makePlaceholder];
    [self.view addSubview:_leftPlaceholder];
    [self.view addSubview:_rightPlaceholder];

    _leftIconView = [self makeIconView];
    _rightIconView = [self makeIconView];
    [_leftPlaceholder addSubview:_leftIconView];
    [_rightPlaceholder addSubview:_rightIconView];

    _leftLabel = [self makePlaceholderLabel];
    _rightLabel = [self makePlaceholderLabel];
    [_leftPlaceholder addSubview:_leftLabel];
    [_rightPlaceholder addSubview:_rightLabel];

    _styleControl = [[UISegmentedControl alloc] initWithItems:@[@"Card", @"Ring", @"Bar"]];
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath] ?: @{};
    _styleControl.selectedSegmentIndex = [prefs[@"bubbleStyle"] integerValue];
    [_styleControl addTarget:self action:@selector(styleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:_styleControl];

    _positionControl = [[UISegmentedControl alloc] initWithItems:@[@"Trái", @"Phải"]];
    _positionControl.selectedSegmentIndex = [prefs[@"bubblePosition"] integerValue];
    [_positionControl addTarget:self action:@selector(positionChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:_positionControl];

    _captionLabel = [[UILabel alloc] init];
    _captionLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1];
    _captionLabel.font = [UIFont systemFontOfSize:12];
    _captionLabel.textAlignment = NSTextAlignmentCenter;
    _captionLabel.numberOfLines = 0;
    _captionLabel.text = @"Xem trước giao diện — không cần cắm CarPlay thật. Đổi kiểu/vị trí bên dưới để xem ngay; thay đổi cũng áp dụng cho màn hình CarPlay thật nếu đang cắm.";
    [self.view addSubview:_captionLabel];

    _bubble = [[SplitCarPlayPreviewBubbleView alloc] initWithFrame:CGRectZero];
    [self.view addSubview:_bubble];

    [self refresh];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refresh]; // picked app / live Vietmap data may have changed since last time
}

- (UIView *)makePlaceholder {
    UIView *view = [[UIView alloc] init];
    view.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1];
    view.layer.cornerRadius = 8;
    return view;
}

- (UIImageView *)makeIconView {
    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.layer.cornerRadius = 12;
    iconView.layer.masksToBounds = YES;
    return iconView;
}

- (UILabel *)makePlaceholderLabel {
    UILabel *label = [[UILabel alloc] init];
    label.textColor = [UIColor colorWithWhite:0.6 alpha:1];
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 2;
    return label;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    CGFloat topInset = self.view.safeAreaInsets.top + 12;
    CGFloat carScreenHeight = 220;

    CGFloat dividerWidth = 4;
    CGFloat usableWidth = bounds.size.width - 32 - dividerWidth;
    CGFloat ratio = _splitRatio > 0 ? _splitRatio : 0.5;
    CGFloat leftWidth = floor(usableWidth * ratio);
    CGFloat rightWidth = usableWidth - leftWidth;
    _leftPlaceholder.frame = CGRectMake(16, topInset, leftWidth, carScreenHeight);
    _rightPlaceholder.frame = CGRectMake(CGRectGetMaxX(_leftPlaceholder.frame) + dividerWidth, topInset, rightWidth, carScreenHeight);

    CGFloat iconSize = MIN(56, _leftPlaceholder.bounds.size.width - 24);
    _leftIconView.frame = CGRectMake((_leftPlaceholder.bounds.size.width - iconSize) / 2.0, 70, iconSize, iconSize);
    _rightIconView.frame = CGRectMake((_rightPlaceholder.bounds.size.width - iconSize) / 2.0, 70, iconSize, iconSize);
    _leftLabel.frame = CGRectMake(4, CGRectGetMaxY(_leftIconView.frame) + 8, _leftPlaceholder.bounds.size.width - 8, 32);
    _rightLabel.frame = CGRectMake(4, CGRectGetMaxY(_rightIconView.frame) + 8, _rightPlaceholder.bounds.size.width - 8, 32);

    CGFloat bubbleW = 116, bubbleH = 188;
    switch ((SplitCarPlayBubbleStyle)_styleControl.selectedSegmentIndex) {
        case SplitCarPlayBubbleStyleRing: bubbleW = bubbleH = 100; break;
        case SplitCarPlayBubbleStyleBar: bubbleW = 220; bubbleH = 44; break;
        default: break;
    }
    BOOL bubbleOnLeft = _positionControl.selectedSegmentIndex == 0;
    CGFloat bubbleX = bubbleOnLeft ? CGRectGetMinX(_leftPlaceholder.frame) + 8
                                    : CGRectGetMaxX(_rightPlaceholder.frame) - bubbleW - 8;
    _bubble.frame = CGRectMake(bubbleX, topInset + 8, bubbleW, bubbleH);

    _styleControl.frame = CGRectMake(16, CGRectGetMaxY(_leftPlaceholder.frame) + 20, bounds.size.width - 32, 32);
    _positionControl.frame = CGRectMake(16, CGRectGetMaxY(_styleControl.frame) + 12, bounds.size.width - 32, 32);
    _captionLabel.frame = CGRectMake(16, CGRectGetMaxY(_positionControl.frame) + 12, bounds.size.width - 32, 60);
}

- (void)styleChanged:(UISegmentedControl *)sender {
    SplitCarPlaySetPref(@"bubbleStyle", @(sender.selectedSegmentIndex));
    _bubble.style = (SplitCarPlayBubbleStyle)sender.selectedSegmentIndex;
    [self.view setNeedsLayout];
}

- (void)positionChanged:(UISegmentedControl *)sender {
    SplitCarPlaySetPref(@"bubblePosition", @(sender.selectedSegmentIndex));
    [self.view setNeedsLayout];
}

- (void)refresh {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath] ?: @{};
    NSString *leftID = prefs[@"leftBundleID"];
    NSString *rightID = prefs[@"rightBundleID"];
    _leftLabel.text = SplitCarPlayDisplayNameForBundleID(leftID) ?: @"(chưa chọn)";
    _rightLabel.text = SplitCarPlayDisplayNameForBundleID(rightID) ?: @"(chưa chọn)";
    _leftIconView.image = SplitCarPlayAppIcon(leftID);
    _rightIconView.image = SplitCarPlayAppIcon(rightID);

    // Match Tweak.xm's loadPreferences defaults for anything the user
    // hasn't touched yet in Settings -- an untouched PS specifier shows
    // its "default" on-screen but doesn't necessarily write that value
    // into this plist file until actually changed, so reading the file
    // directly (as this whole controller does, for simplicity) needs the
    // same fallback or this preview can show a different starting value
    // than what the real CarPlay bubble would actually use.
    _bubble.style = (SplitCarPlayBubbleStyle)[prefs[@"bubbleStyle"] integerValue];
    _bubble.showDate = prefs[@"showDate"] ? [prefs[@"showDate"] boolValue] : YES;
    _bubble.showBattery = prefs[@"showBattery"] ? [prefs[@"showBattery"] boolValue] : YES;
    _positionControl.selectedSegmentIndex = prefs[@"bubblePosition"] ? [prefs[@"bubblePosition"] integerValue] : 1;
    _splitRatio = prefs[@"splitRatio"] ? [prefs[@"splitRatio"] doubleValue] : 0.5;

    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:kVietmapSharedStatePath];
    NSNumber *timestamp = state[@"timestamp"];
    BOOL fresh = timestamp && ([[NSDate date] timeIntervalSince1970] - timestamp.doubleValue) < 6.0;
    NSString *speedText = state[@"currentSpeedText"];
    if (fresh && speedText.length > 0) {
        [_bubble applySpeedText:speedText overLimit:[state[@"isOverLimit"] boolValue] isLive:YES];
    } else {
        // No live Vietmap Live data right now — show clearly-labeled demo
        // numbers so the preview still means something.
        [_bubble applySpeedText:@"45" overLimit:NO isLive:NO];
    }
    [self.view setNeedsLayout];
}

@end
