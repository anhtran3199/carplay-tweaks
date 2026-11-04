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
//  APP PLACEHOLDERS: A REAL SNAPSHOT WHEN ONE EXISTS, ELSE THE ICON
//
//  SidePlay2's own "Mô phỏng" turned out to use Apple's PUBLIC CarPlay
//  framework (CPTemplateApplicationScene/CPInterfaceController -- real
//  strings in their binary, confirmed by scanning it the same way as
//  everywhere else in this project) for ITS OWN CarPlay UI, which can
//  only show Apple's own templates (maps/lists/alerts) -- it cannot
//  embed arbitrary video/WebView content like a YouTube feed. The
//  YouTube-looking content in the screenshot that prompted this is
//  almost certainly NOT a live render at all: it's very likely iOS's own
//  **app-switcher snapshot** -- a real, standard iOS feature where every
//  backgrounded app has its last-seen appearance cached to disk as an
//  image, normally just for the multitasking UI, but readable by any
//  process on a jailbroken device.
//
//  So that's what this does: finds the picked app's container (scanning
//  /var/mobile/Containers/Data/Application/*/.com.apple.mobile_container_manager.metadata.plist
//  for a matching MCMMetadataIdentifier -- a standard technique, not a
//  private API), then the newest file under its
//  Library/SplashBoard/Snapshots or Library/Caches/Snapshots. iOS 13+
//  (this device's iOS 15.8.8 included) stores these as **.ktx** files --
//  a GPU-compressed texture format, not a plain image -- decoded here via
//  MetalKit; older-style plain .png/.jpg snapshots are also handled.
//  Every step degrades to nil on failure (wrong path guess, decode
//  error, app never backgrounded so no snapshot exists yet, ...) and the
//  caller always falls back to the plain app icon -- never a crash,
//  never a blank box.
//
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <CoreImage/CoreImage.h>

extern NSString *SplitCarPlayDisplayNameForBundleID(NSString *bundleID); // SplitCarPlayAppPickerController.m
extern UIImage *SplitCarPlayAppIcon(NSString *bundleID); // SplitCarPlayAppPickerController.m

#pragma mark - App-switcher snapshot lookup (see header comment)

static NSString *SplitCarPlayFindContainerPath(NSString *bundleID) {
    if (bundleID.length == 0) return nil;
    NSString *base = @"/var/mobile/Containers/Data/Application";
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *dirs = [fm contentsOfDirectoryAtPath:base error:nil];
    for (NSString *dir in dirs) {
        NSString *metadataPath = [NSString stringWithFormat:@"%@/%@/.com.apple.mobile_container_manager.metadata.plist", base, dir];
        NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
        if ([metadata[@"MCMMetadataIdentifier"] isEqualToString:bundleID]) {
            return [base stringByAppendingPathComponent:dir];
        }
    }
    return nil;
}

// Most recently modified image-like file under either known snapshot
// location, searched recursively (the real layout nests snapshots under
// a per-scene subfolder whose exact name isn't worth hardcoding).
static NSString *SplitCarPlayFindSnapshotFile(NSString *containerPath) {
    if (containerPath.length == 0) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *roots = @[
        [containerPath stringByAppendingPathComponent:@"Library/SplashBoard/Snapshots"],
        [containerPath stringByAppendingPathComponent:@"Library/Caches/Snapshots"],
    ];
    NSString *bestPath = nil;
    NSDate *bestDate = nil;
    for (NSString *root in roots) {
        NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:root];
        for (NSString *relativePath in enumerator) {
            NSString *lower = relativePath.lowercaseString;
            if (![lower hasSuffix:@".png"] && ![lower hasSuffix:@".ktx"] && ![lower hasSuffix:@".jpg"]) continue;
            NSString *fullPath = [root stringByAppendingPathComponent:relativePath];
            NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
            NSDate *modDate = attrs[NSFileModificationDate];
            if (!bestDate || [modDate compare:bestDate] == NSOrderedDescending) {
                bestDate = modDate;
                bestPath = fullPath;
            }
        }
    }
    return bestPath;
}

static UIImage *SplitCarPlayLoadKTXImage(NSString *path) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return nil;
    MTKTextureLoader *loader = [[MTKTextureLoader alloc] initWithDevice:device];
    NSError *error = nil;
    id<MTLTexture> texture = [loader newTextureWithContentsOfURL:[NSURL fileURLWithPath:path]
                                                           options:nil
                                                             error:&error];
    if (!texture) return nil;
    CIImage *ciImage = [CIImage imageWithMTLTexture:texture options:nil];
    if (!ciImage) return nil;
    // Metal textures have their origin at the top-left; Core Image's
    // coordinate space has its origin at the bottom-left (same as
    // OpenGL). Without this flip, every KTX snapshot renders upside down.
    CGAffineTransform flip = CGAffineTransformMake(1, 0, 0, -1, 0, ciImage.extent.size.height);
    ciImage = [ciImage imageByApplyingTransform:flip];
    CIContext *context = [CIContext context];
    CGImageRef cgImage = [context createCGImage:ciImage fromRect:ciImage.extent];
    if (!cgImage) return nil;
    UIImage *image = [UIImage imageWithCGImage:cgImage];
    CGImageRelease(cgImage);
    return image;
}

// Public, not static -- used by SplitCarPlayPreviewController below.
// Returns nil on ANY failure (not found, wrong format guess, decode
// error); always pair with an icon fallback.
UIImage *SplitCarPlayAppSnapshot(NSString *bundleID) {
    NSString *containerPath = SplitCarPlayFindContainerPath(bundleID);
    NSString *snapshotPath = SplitCarPlayFindSnapshotFile(containerPath);
    if (snapshotPath.length == 0) return nil;
    NSString *lower = snapshotPath.lowercaseString;
    @try {
        if ([lower hasSuffix:@".png"] || [lower hasSuffix:@".jpg"]) {
            return [UIImage imageWithContentsOfFile:snapshotPath];
        }
        if ([lower hasSuffix:@".ktx"]) {
            return SplitCarPlayLoadKTXImage(snapshotPath);
        }
    } @catch (NSException *exception) {
        return nil;
    }
    return nil;
}

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

static const CGFloat kSplitCarPlayTitleBarHeight = 26;

@interface SplitCarPlayPreviewController : UIViewController
@end

@implementation SplitCarPlayPreviewController {
    UIView *_leftPlaceholder;
    UIView *_rightPlaceholder;
    UIImageView *_leftIconView;
    UIImageView *_rightIconView;
    UILabel *_leftLabel;
    UILabel *_rightLabel;
    UIView *_leftTitleBar;
    UIView *_rightTitleBar;
    UIImageView *_leftTitleIcon;
    UIImageView *_rightTitleIcon;
    SplitCarPlayPreviewBubbleView *_bubble;
    UISegmentedControl *_styleControl;
    UISegmentedControl *_positionControl;
    UILabel *_captionLabel;
    UIView *_dividerHandle;
    CGFloat _splitRatio;
    CGFloat _dragStartRatio;
    BOOL _leftHasSnapshot;
    BOOL _rightHasSnapshot;
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

    // A fake "browser/app window" title bar (3 traffic-light dots + a
    // small icon + the app name) on top of each box -- purely cosmetic,
    // same idea SidePlay's own "Mô phỏng" screen uses on its two app
    // mockups (confirmed from a screenshot: the YouTube side shows grey
    // skeleton placeholders under that bar, not real video, so it's
    // decoration there too, not a real window with working buttons).
    _leftTitleBar = [self makeTitleBarWithDots];
    _rightTitleBar = [self makeTitleBarWithDots];
    [_leftPlaceholder addSubview:_leftTitleBar];
    [_rightPlaceholder addSubview:_rightTitleBar];

    _leftTitleIcon = [self makeTitleIconView];
    _rightTitleIcon = [self makeTitleIconView];
    [_leftTitleBar addSubview:_leftTitleIcon];
    [_rightTitleBar addSubview:_rightTitleIcon];

    _leftLabel = [self makeTitleBarLabel];
    _rightLabel = [self makeTitleBarLabel];
    [_leftTitleBar addSubview:_leftLabel];
    [_rightTitleBar addSubview:_rightLabel];

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
    _captionLabel.text = @"Xem trước giao diện — không cần cắm CarPlay thật. Kéo thanh ở giữa để đổi tỉ lệ chia màn hình, đổi kiểu/vị trí bên dưới để xem ngay. Đây chỉ là ảnh xem trước (không bấm vào app được) — 2 app chỉ thật sự chạy và thao tác được khi cắm CarPlay thật.";
    [self.view addSubview:_captionLabel];

    _bubble = [[SplitCarPlayPreviewBubbleView alloc] initWithFrame:CGRectZero];
    [self.view addSubview:_bubble];

    // Drag this to resize the split live -- same "splitRatio" pref the
    // "Split Ratio" slider on the main Settings screen controls, so
    // either one moves the other.
    _dividerHandle = [[UIView alloc] init];
    _dividerHandle.backgroundColor = [UIColor colorWithWhite:1 alpha:0.35];
    _dividerHandle.layer.cornerRadius = 3;
    [self.view addSubview:_dividerHandle];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleDividerPan:)];
    [_dividerHandle addGestureRecognizer:pan];
    _dividerHandle.userInteractionEnabled = YES;

    [self refresh];
}

- (void)handleDividerPan:(UIPanGestureRecognizer *)gesture {
    CGFloat dividerWidth = 4;
    CGFloat usableWidth = self.view.bounds.size.width - 32 - dividerWidth;
    if (gesture.state == UIGestureRecognizerStateBegan) {
        _dragStartRatio = _splitRatio > 0 ? _splitRatio : 0.5;
    }
    CGFloat deltaRatio = [gesture translationInView:self.view].x / usableWidth;
    _splitRatio = MAX(0.2, MIN(0.8, _dragStartRatio + deltaRatio));
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
    if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled) {
        // Persist only once the drag finishes -- matches the slider's
        // own behavior and avoids writing the plist on every pixel.
        SplitCarPlaySetPref(@"splitRatio", @(_splitRatio));
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refresh]; // picked app / live Vietmap data may have changed since last time
}

- (UIView *)makePlaceholder {
    UIView *view = [[UIView alloc] init];
    view.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1];
    view.layer.cornerRadius = 8;
    view.layer.masksToBounds = YES; // keep the title bar's top corners and the snapshot's edges inside the rounded card
    return view;
}

- (UIImageView *)makeIconView {
    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.layer.cornerRadius = 12;
    iconView.layer.masksToBounds = YES;
    return iconView;
}

- (UIView *)makeTitleBarWithDots {
    UIView *bar = [[UIView alloc] init];
    bar.backgroundColor = [UIColor colorWithWhite:0.24 alpha:1];
    NSArray<UIColor *> *dotColors = @[
        [UIColor colorWithRed:1.0 green:0.37 blue:0.34 alpha:1],  // red
        [UIColor colorWithRed:1.0 green:0.74 blue:0.18 alpha:1],  // yellow
        [UIColor colorWithRed:0.2 green:0.78 blue:0.35 alpha:1],  // green
    ];
    CGFloat dotSize = 8, dotGap = 6, x = 8;
    for (UIColor *color in dotColors) {
        UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(x, (kSplitCarPlayTitleBarHeight - dotSize) / 2.0, dotSize, dotSize)];
        dot.backgroundColor = color;
        dot.layer.cornerRadius = dotSize / 2.0;
        [bar addSubview:dot];
        x += dotSize + dotGap;
    }
    return bar;
}

- (UIImageView *)makeTitleIconView {
    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.layer.cornerRadius = 3;
    iconView.layer.masksToBounds = YES;
    return iconView;
}

- (UILabel *)makeTitleBarLabel {
    UILabel *label = [[UILabel alloc] init];
    label.textColor = [UIColor colorWithWhite:0.88 alpha:1];
    label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    label.textAlignment = NSTextAlignmentLeft;
    label.numberOfLines = 1;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
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

    // A wider invisible hit area than the thin visible line, centered on
    // the boundary between the two placeholders, so it's actually easy
    // to grab with a finger.
    CGFloat handleHitWidth = 28, handleVisibleWidth = 5, handleHeight = 64;
    CGFloat boundaryX = CGRectGetMaxX(_leftPlaceholder.frame) + dividerWidth / 2.0;
    _dividerHandle.frame = CGRectMake(boundaryX - handleHitWidth / 2.0,
                                       topInset + (carScreenHeight - handleHeight) / 2.0,
                                       handleHitWidth, handleHeight);
    _dividerHandle.layer.cornerRadius = handleVisibleWidth / 2.0;
    // Only the thin center strip is drawn; the rest of the frame is
    // just a bigger invisible tap/drag target.
    CGRect visibleRect = CGRectMake((handleHitWidth - handleVisibleWidth) / 2.0, 0, handleVisibleWidth, handleHeight);
    CAShapeLayer *mask = [CAShapeLayer layer];
    mask.path = [UIBezierPath bezierPathWithRoundedRect:visibleRect cornerRadius:handleVisibleWidth / 2.0].CGPath;
    _dividerHandle.layer.mask = mask;

    _leftTitleBar.frame = CGRectMake(0, 0, _leftPlaceholder.bounds.size.width, kSplitCarPlayTitleBarHeight);
    _rightTitleBar.frame = CGRectMake(0, 0, _rightPlaceholder.bounds.size.width, kSplitCarPlayTitleBarHeight);
    [self layoutTitleBar:_leftTitleBar icon:_leftTitleIcon label:_leftLabel];
    [self layoutTitleBar:_rightTitleBar icon:_rightTitleIcon label:_rightLabel];

    // A real snapshot fills the rest of the box below the title bar
    // (it already looks like the app, same as a real screenshot);
    // falling back to the plain icon centers it in that same area.
    [self layoutAppBox:_leftPlaceholder icon:_leftIconView hasSnapshot:_leftHasSnapshot];
    [self layoutAppBox:_rightPlaceholder icon:_rightIconView hasSnapshot:_rightHasSnapshot];

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

- (void)layoutTitleBar:(UIView *)bar icon:(UIImageView *)icon label:(UILabel *)label {
    CGFloat dotsEndX = 8 + 3 * 8 + 2 * 6; // matches makeTitleBarWithDots's dotSize/dotGap/start-x
    CGFloat iconSize = 14;
    CGFloat iconX = dotsEndX + 10;
    icon.frame = CGRectMake(iconX, (kSplitCarPlayTitleBarHeight - iconSize) / 2.0, iconSize, iconSize);
    CGFloat labelX = CGRectGetMaxX(icon.frame) + 6;
    CGFloat labelWidth = MAX(0, bar.bounds.size.width - labelX - 10);
    label.frame = CGRectMake(labelX, 0, labelWidth, kSplitCarPlayTitleBarHeight);
}

- (void)layoutAppBox:(UIView *)placeholder icon:(UIImageView *)icon hasSnapshot:(BOOL)hasSnapshot {
    CGRect contentArea = CGRectMake(0, kSplitCarPlayTitleBarHeight,
                                     placeholder.bounds.size.width,
                                     placeholder.bounds.size.height - kSplitCarPlayTitleBarHeight);
    icon.layer.cornerRadius = hasSnapshot ? 0 : 12;
    if (hasSnapshot) {
        icon.frame = contentArea; // fill the box edge-to-edge, like a real screenshot
    } else {
        CGFloat iconSize = MIN(56, contentArea.size.width - 24);
        icon.frame = CGRectMake(CGRectGetMinX(contentArea) + (contentArea.size.width - iconSize) / 2.0,
                                 CGRectGetMinY(contentArea) + (contentArea.size.height - iconSize) / 2.0,
                                 iconSize, iconSize);
    }
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
    _leftTitleIcon.image = SplitCarPlayAppIcon(leftID);
    _rightTitleIcon.image = SplitCarPlayAppIcon(rightID);

    // Prefer a real cached app-switcher snapshot (looks like the actual
    // app) over the plain icon -- see this file's header comment. Either
    // can be nil (app never backgrounded yet, wrong path guess, decode
    // failure, nothing picked) with no crash either way.
    UIImage *leftSnapshot = SplitCarPlayAppSnapshot(leftID);
    UIImage *rightSnapshot = SplitCarPlayAppSnapshot(rightID);
    _leftHasSnapshot = leftSnapshot != nil;
    _rightHasSnapshot = rightSnapshot != nil;
    _leftIconView.image = leftSnapshot ?: SplitCarPlayAppIcon(leftID);
    _rightIconView.image = rightSnapshot ?: SplitCarPlayAppIcon(rightID);
    _leftIconView.contentMode = _leftHasSnapshot ? UIViewContentModeScaleAspectFill : UIViewContentModeScaleAspectFit;
    _rightIconView.contentMode = _rightHasSnapshot ? UIViewContentModeScaleAspectFill : UIViewContentModeScaleAspectFit;

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
