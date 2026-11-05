//
//  PreviewViewController.m -- "Mô phỏng" tab
//
//  Ported from Prefs.bundle/SplitCarPlayPreviewController.m (the old
//  Settings-panel version of this screen) now that this project is a
//  standalone app instead -- see ROADMAP.md's "Architecture pivot"
//  entry. Behavior is unchanged except: the "Thử chạy app thật" button
//  and its Darwin-notification-triggered live-overlay experiment are
//  removed (that mechanism is now known-broken on real CarPlay
//  hardware, and this app has no reason to inject into Preferences.app
//  anyway), and the in-place grid picker is now the shared
//  AppPickerController (presented modally) instead of a duplicated
//  copy -- this app is one binary, so "duplicated across processes"
//  doesn't apply here the way it did for Prefs.bundle/Tweak.xm.
//
//  WHY THIS IS STILL A SEPARATE RENDER OF THE BUBBLE, NOT A REUSE OF
//  Tweak.xm's SpeedBubbleView
//
//  This app doesn't get SplitCarPlay.dylib injected into it (it's a
//  stock, un-tweaked process) -- same reasoning as before, just a
//  different host process than Settings.
//
//  APP PLACEHOLDERS: A REAL SNAPSHOT WHEN ONE EXISTS, ELSE THE ICON
//
//  SidePlay2's own "Mô phỏng" turned out to use Apple's PUBLIC CarPlay
//  framework (CPTemplateApplicationScene/CPInterfaceController -- real
//  strings in their binary) for ITS OWN CarPlay UI, which can only show
//  Apple's own templates -- it cannot embed arbitrary video/WebView
//  content. The YouTube-looking content in the screenshot that prompted
//  this is almost certainly iOS's own **app-switcher snapshot** -- every
//  backgrounded app's last-seen appearance, cached to disk, normally
//  just for the multitasking UI but readable by any process on a
//  jailbroken device.
//
//  So that's what this does: finds the picked app's container (scanning
//  /var/mobile/Containers/Data/Application/*/.com.apple.mobile_container_manager.metadata.plist
//  for a matching MCMMetadataIdentifier), then the newest file under its
//  Library/SplashBoard/Snapshots or Library/Caches/Snapshots. iOS 13+
//  stores these as **.ktx** files -- decoded here via MetalKit; older
//  plain .png/.jpg snapshots are also handled. Every step degrades to
//  nil on failure, and the caller always falls back to the plain app
//  icon -- never a crash, never a blank box.
//
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <CoreImage/CoreImage.h>

extern NSString *SplitCarPlayDisplayNameForBundleID(NSString *bundleID); // AppPickerController.m
extern UIImage *SplitCarPlayAppIcon(NSString *bundleID); // AppPickerController.m
extern void SplitCarPlaySetPref(NSString *key, id value); // AppPickerController.m
extern NSArray<NSString *> *SplitCarPlayRecentBundleIDs(void); // AppPickerController.m
@interface AppPickerController : UIViewController
+ (void)presentFrom:(UIViewController *)presenter title:(NSString *)title onPick:(void (^)(NSString *bundleID))onPick;
@end

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

// Returns nil on ANY failure (not found, wrong format guess, decode
// error); always pair with an icon fallback.
static UIImage *SplitCarPlayAppSnapshot(NSString *bundleID) {
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
static NSString * const kVietmapSharedStatePath = @"/var/mobile/Library/Caches/com.example.splitcarplay/vietmap_speed.plist";

// "T5, 5/11" -- matches the reference screenshot's date format; mirrors
// Tweak.xm's SplitCarPlayWeekdayDateString (separate process there,
// can't share the compiled function -- not true for this app, but kept
// as its own copy here for a straightforward 1:1 port).
static NSString *SplitCarPlayWeekdayDateString(NSDate *date) {
    NSDateComponents *comps = [[NSCalendar currentCalendar] components:(NSCalendarUnitWeekday | NSCalendarUnitDay | NSCalendarUnitMonth)
                                                                fromDate:date];
    NSArray<NSString *> *weekdayNames = @[@"CN", @"T2", @"T3", @"T4", @"T5", @"T6", @"T7"];
    NSString *weekday = weekdayNames[(comps.weekday - 1) % 7];
    return [NSString stringWithFormat:@"%@, %ld/%ld", weekday, (long)comps.day, (long)comps.month];
}

static UIImage *SplitCarPlayBatteryIcon(CGFloat level) {
    NSString *name = level >= 0.95 ? @"battery.100"
                    : level >= 0.70 ? @"battery.75"
                    : level >= 0.45 ? @"battery.50"
                    : level >= 0.20 ? @"battery.25"
                    : @"battery.0";
    if (@available(iOS 13.0, *)) {
        return [UIImage systemImageNamed:name];
    }
    return nil;
}

#pragma mark - Minimal bubble preview (3 styles — mirrors Tweak.xm's SpeedBubbleView)

@interface PreviewBubbleView : UIView
@property (nonatomic, assign) SplitCarPlayBubbleStyle style;
@property (nonatomic, assign) BOOL showDate;
@property (nonatomic, assign) BOOL showBattery;
// Pinch-to-resize, same CGAffineTransform-based approach as the real
// SpeedBubbleView in Tweak.xm -- see that class's own comment for why a
// transform (not a frame/bounds resize) is used. Clamped [0.6, 1.6].
@property (nonatomic, assign) CGFloat scale;
// Fires once per drag/pinch gesture (on end), not per-frame, so the
// Preview controller can persist without spamming disk writes.
@property (nonatomic, copy) void (^onUserAdjusted)(void);
// isLive = real Vietmap Live data vs. made-up demo numbers (controls the
// status icon/text and whether the ring/bar tint as "connected"); the
// speed number itself always shows (demo or real) so the preview always
// looks populated.
- (void)applySpeedText:(NSString *)text overLimit:(BOOL)overLimit isLive:(BOOL)isLive;
@end

@implementation PreviewBubbleView {
    UIView *_speedBox;
    UILabel *_speedLabel;
    UILabel *_unitLabel;
    UIImageView *_statusIconView;
    UILabel *_statusLabel;
    UIView *_statusBar;
    UILabel *_extrasLabel;        // date, its own line
    UIImageView *_batteryIconView;
    UILabel *_batteryLabel;       // battery %, its own line
    UIView *_compassView;         // dashed-circle heading indicator, see Tweak.xm's SpeedBubbleView for why it's always "--"
    CAShapeLayer *_compassDashLayer;
    UILabel *_compassLabel;
    CAShapeLayer *_ringLayer;
    CAShapeLayer *_maskLayer;
    UIPanGestureRecognizer *_pan;
    UIPinchGestureRecognizer *_pinch;
    CGFloat _currentScale;
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
        _extrasLabel.textAlignment = NSTextAlignmentLeft;
        _extrasLabel.font = [UIFont systemFontOfSize:11];
        _extrasLabel.textColor = [UIColor colorWithWhite:0.4 alpha:1];
        [self addSubview:_extrasLabel];

        _batteryIconView = [[UIImageView alloc] init];
        _batteryIconView.contentMode = UIViewContentModeScaleAspectFit;
        _batteryIconView.tintColor = [UIColor colorWithWhite:0.4 alpha:1];
        [self addSubview:_batteryIconView];

        _batteryLabel = [[UILabel alloc] init];
        _batteryLabel.textAlignment = NSTextAlignmentLeft;
        _batteryLabel.font = [UIFont systemFontOfSize:11];
        _batteryLabel.textColor = [UIColor colorWithWhite:0.4 alpha:1];
        [self addSubview:_batteryLabel];

        _compassView = [[UIView alloc] init];
        _compassView.backgroundColor = [UIColor clearColor];
        [self addSubview:_compassView];

        _compassDashLayer = [CAShapeLayer new];
        _compassDashLayer.fillColor = [UIColor clearColor].CGColor;
        _compassDashLayer.strokeColor = [UIColor colorWithWhite:0.6 alpha:1].CGColor;
        _compassDashLayer.lineWidth = 1.5;
        _compassDashLayer.lineDashPattern = @[@3, @3];
        [_compassView.layer addSublayer:_compassDashLayer];

        _compassLabel = [[UILabel alloc] init];
        _compassLabel.text = @"--";
        _compassLabel.textAlignment = NSTextAlignmentCenter;
        _compassLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        _compassLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1];
        [_compassView addSubview:_compassLabel];

        _statusBar = [[UIView alloc] init];
        [self addSubview:_statusBar];

        _ringLayer = [CAShapeLayer new];
        _ringLayer.fillColor = [UIColor clearColor].CGColor;
        _ringLayer.lineWidth = 5;
        _ringLayer.hidden = YES;
        [self.layer addSublayer:_ringLayer];

        _currentScale = 1.0;
        _pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:_pan];
        _pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(handlePinch:)];
        [self addGestureRecognizer:_pinch];
        self.userInteractionEnabled = YES;
    }
    return self;
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self.superview];
    self.center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:self.superview];
    if (pan.state == UIGestureRecognizerStateEnded && self.onUserAdjusted) self.onUserAdjusted();
}

- (void)handlePinch:(UIPinchGestureRecognizer *)pinch {
    if (pinch.state == UIGestureRecognizerStateChanged) {
        CGFloat candidate = MAX(0.6, MIN(1.6, _currentScale * pinch.scale));
        self.transform = CGAffineTransformMakeScale(candidate, candidate);
    } else if (pinch.state == UIGestureRecognizerStateEnded || pinch.state == UIGestureRecognizerStateCancelled) {
        _currentScale = MAX(0.6, MIN(1.6, _currentScale * pinch.scale));
        self.transform = CGAffineTransformMakeScale(_currentScale, _currentScale);
        if (self.onUserAdjusted) self.onUserAdjusted();
    }
}

- (void)setScale:(CGFloat)scale {
    _currentScale = MAX(0.6, MIN(1.6, scale));
    self.transform = CGAffineTransformMakeScale(_currentScale, _currentScale);
}

- (CGFloat)scale {
    return _currentScale;
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

    // Date and battery on their own lines -- matches the reference
    // screenshot's stacked "T5, 5/11" / "77%" rather than one combined
    // centered line.
    _extrasLabel.hidden = !self.showDate;
    if (!_extrasLabel.hidden) {
        _extrasLabel.text = SplitCarPlayWeekdayDateString([NSDate date]);
        _extrasLabel.frame = CGRectMake(pad, y, w - pad * 2, 14);
        y = CGRectGetMaxY(_extrasLabel.frame) + 1;
    }
    UIDevice *device = [UIDevice currentDevice];
    BOOL showBatteryRow = self.showBattery && device.batteryState != UIDeviceBatteryStateUnknown;
    _batteryIconView.hidden = !showBatteryRow;
    _batteryLabel.hidden = !showBatteryRow;
    if (showBatteryRow) {
        _batteryLabel.text = [NSString stringWithFormat:@"%.0f%%", device.batteryLevel * 100];
        _batteryIconView.image = SplitCarPlayBatteryIcon(device.batteryLevel);
        CGFloat battIconSize = 12;
        _batteryIconView.frame = CGRectMake(pad, y + 1, battIconSize, battIconSize);
        _batteryLabel.frame = CGRectMake(CGRectGetMaxX(_batteryIconView.frame) + 4, y, w - pad - CGRectGetMaxX(_batteryIconView.frame) - 4, 14);
        y = CGRectGetMaxY(_batteryLabel.frame) + 4;
    }

    _speedBox.frame = CGRectMake(pad, y, w - pad * 2, 52);
    _speedLabel.frame = CGRectMake(0, 4, _speedBox.bounds.size.width, 30);
    _unitLabel.frame = CGRectMake(0, 34, _speedBox.bounds.size.width, 14);
    y = CGRectGetMaxY(_speedBox.frame) + 8;

    // Dashed-circle heading indicator, matching the reference screenshot
    // -- see the ivar comment on _compassView for why it's always "--".
    CGFloat compassSize = MIN(60, w - pad * 2);
    _compassView.hidden = NO;
    _compassView.frame = CGRectMake((w - compassSize) / 2.0, y, compassSize, compassSize);
    _compassLabel.frame = _compassView.bounds;
    _compassDashLayer.frame = _compassView.bounds;
    _compassDashLayer.path = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(_compassView.bounds, 1, 1)].CGPath;
    y = CGRectGetMaxY(_compassView.frame) + 8;

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
    _batteryIconView.hidden = YES;
    _batteryLabel.hidden = YES;
    _compassView.hidden = YES;

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
    _batteryIconView.hidden = YES;
    _batteryLabel.hidden = YES;
    _compassView.hidden = YES;

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

@interface PreviewViewController : UIViewController <UIGestureRecognizerDelegate>
@end

@implementation PreviewViewController {
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
    PreviewBubbleView *_bubble;
    UISegmentedControl *_styleControl;
    UISegmentedControl *_positionControl;
    UILabel *_headingLabel;
    UILabel *_captionLabel;
    UIView *_dividerHandle;
    CGFloat _splitRatio;
    CGFloat _dragStartRatio;
    BOOL _leftHasSnapshot;
    BOOL _rightHasSnapshot;
    BOOL _bubbleWasAdjusted; // once the bubble's been dragged, stop re-centering it every layout pass

    // "Tab mới" empty state (shown in a box until an app is picked for
    // it) -- styled after SidePlay's own "Mô phỏng" screen.
    UIView *_leftEmptyState;
    UIView *_rightEmptyState;
    BOOL _leftIsEmpty;
    BOOL _rightIsEmpty;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Mô phỏng";
    // Reference screenshots show a big bold heading directly on a white
    // page, no visible nav bar -- not a thin standard nav-bar title on a
    // dark background (how this screen looked before). Hides the nav
    // bar for just this tab's own navigation controller and draws the
    // heading as a real label instead.
    self.view.backgroundColor = [UIColor whiteColor];

    _headingLabel = [[UILabel alloc] init];
    _headingLabel.text = @"Mô phỏng";
    _headingLabel.font = [UIFont boldSystemFontOfSize:34];
    _headingLabel.textColor = [UIColor blackColor];
    [self.view addSubview:_headingLabel];

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

    // "Tab mới" empty state (SidePlay's own look for a box with nothing
    // picked yet) -- populated dynamically in viewDidLayoutSubviews since
    // its own layout needs the placeholder's final width.
    _leftEmptyState = [[UIView alloc] init];
    _rightEmptyState = [[UIView alloc] init];
    [_leftPlaceholder addSubview:_leftEmptyState];
    [_rightPlaceholder addSubview:_rightEmptyState];

    // Tap a box to open the grid-style "Chọn app ô 1/2" picker (same
    // whether it's empty or already showing an app -- lets you change
    // the pick, not just make the first one). The gesture's delegate
    // skips touches that land on a button inside the empty state (the
    // recent-app icons / "Tất cả app" link) so they get their own tap
    // instead of this one swallowing it.
    UITapGestureRecognizer *leftTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(leftPlaceholderTapped)];
    leftTap.delegate = self;
    [_leftPlaceholder addGestureRecognizer:leftTap];
    _leftPlaceholder.userInteractionEnabled = YES;
    UITapGestureRecognizer *rightTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(rightPlaceholderTapped)];
    rightTap.delegate = self;
    [_rightPlaceholder addGestureRecognizer:rightTap];
    _rightPlaceholder.userInteractionEnabled = YES;

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
    _captionLabel.textColor = [UIColor colorWithWhite:0.4 alpha:1];
    _captionLabel.font = [UIFont systemFontOfSize:12];
    _captionLabel.textAlignment = NSTextAlignmentCenter;
    _captionLabel.numberOfLines = 0;
    _captionLabel.text = @"Khung bên trên chỉ là ảnh xem trước tĩnh (không bấm vào app được) — kéo thanh ở giữa để đổi tỉ lệ chia màn hình, đổi kiểu/vị trí bên dưới để xem ngay. Kéo bong bóng để đổi vị trí, chụm/mở 2 ngón để đổi kích thước.";
    [self.view addSubview:_captionLabel];

    _bubble = [[PreviewBubbleView alloc] initWithFrame:CGRectZero];
    [self.view addSubview:_bubble];
    // Drag the bubble anywhere, pinch to resize it -- persists the scale
    // to the shared "bubbleScale" pref (also read by the real CarPlay
    // bubble in Tweak.xm, once that feature works again) and stops this
    // screen's own layout from re-centering it on every pass once moved.
    __weak typeof(self) weakSelf = self;
    _bubble.onUserAdjusted = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_bubbleWasAdjusted = YES;
        SplitCarPlaySetPref(@"bubbleScale", @(strongSelf->_bubble.scale));
    };

    // Drag this to resize the split live -- same "splitRatio" pref the
    // "Split Ratio" slider on the "Trên xe" tab controls, so either one
    // moves the other.
    _dividerHandle = [[UIView alloc] init];
    _dividerHandle.backgroundColor = [UIColor colorWithWhite:0 alpha:0.25];
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
    self.navigationController.navigationBarHidden = YES; // this tab only -- the big _headingLabel replaces it, matching the reference screenshots
    [self refresh]; // picked app / live Vietmap data may have changed since last time
}

- (UIView *)makePlaceholder {
    UIView *view = [[UIView alloc] init];
    view.backgroundColor = [UIColor colorWithWhite:0.96 alpha:1];
    view.layer.cornerRadius = 8;
    view.layer.masksToBounds = YES; // keep the title bar's top corners and the snapshot's edges inside the rounded card
    view.layer.borderWidth = 1;
    view.layer.borderColor = [UIColor colorWithWhite:0.85 alpha:1].CGColor; // card definition against the white page, matching the reference screenshots' light theme
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
    bar.backgroundColor = [UIColor colorWithWhite:0.90 alpha:1];
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
    label.textColor = [UIColor colorWithWhite:0.15 alpha:1];
    label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    label.textAlignment = NSTextAlignmentLeft;
    label.numberOfLines = 1;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;

    _headingLabel.frame = CGRectMake(16, self.view.safeAreaInsets.top + 8, bounds.size.width - 32, 42);
    CGFloat topInset = CGRectGetMaxY(_headingLabel.frame) + 16;
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

    // Real SidePlay screenshots show this title bar only while a box is
    // still empty/loading (picking an app, "Đang mở...") -- once real
    // content is actually showing, it disappears and the content fills
    // the box edge-to-edge with no notch at the top. Matches that: hide
    // the bar (and let the snapshot take the full height) exactly when
    // we have a real snapshot to show.
    _leftTitleBar.hidden = _leftHasSnapshot;
    _rightTitleBar.hidden = _rightHasSnapshot;
    _leftTitleBar.frame = CGRectMake(0, 0, _leftPlaceholder.bounds.size.width, kSplitCarPlayTitleBarHeight);
    _rightTitleBar.frame = CGRectMake(0, 0, _rightPlaceholder.bounds.size.width, kSplitCarPlayTitleBarHeight);
    [self layoutTitleBar:_leftTitleBar icon:_leftTitleIcon label:_leftLabel];
    [self layoutTitleBar:_rightTitleBar icon:_rightTitleIcon label:_rightLabel];

    // A real snapshot fills the whole box now that the title bar above
    // is hidden; falling back to the plain icon centers it in the area
    // below the (still visible) title bar.
    [self layoutAppBox:_leftPlaceholder icon:_leftIconView hasSnapshot:_leftHasSnapshot];
    [self layoutAppBox:_rightPlaceholder icon:_rightIconView hasSnapshot:_rightHasSnapshot];

    _leftEmptyState.frame = CGRectMake(0, kSplitCarPlayTitleBarHeight,
                                        _leftPlaceholder.bounds.size.width,
                                        _leftPlaceholder.bounds.size.height - kSplitCarPlayTitleBarHeight);
    _rightEmptyState.frame = CGRectMake(0, kSplitCarPlayTitleBarHeight,
                                         _rightPlaceholder.bounds.size.width,
                                         _rightPlaceholder.bounds.size.height - kSplitCarPlayTitleBarHeight);
    [self populateEmptyState:_leftEmptyState isLeft:YES];
    [self populateEmptyState:_rightEmptyState isLeft:NO];
    _leftEmptyState.hidden = !_leftIsEmpty;
    _rightEmptyState.hidden = !_rightIsEmpty;
    _leftIconView.hidden = _leftIsEmpty;
    _rightIconView.hidden = _rightIsEmpty;

    CGFloat bubbleW = 116, bubbleH = 266;
    switch ((SplitCarPlayBubbleStyle)_styleControl.selectedSegmentIndex) {
        case SplitCarPlayBubbleStyleRing: bubbleW = bubbleH = 100; break;
        case SplitCarPlayBubbleStyleBar: bubbleW = 220; bubbleH = 44; break;
        default: break;
    }
    // Uses bounds+center, not .frame: the bubble carries a pinch-driven
    // scale transform now, and -frame is undefined (per Apple's docs)
    // once a view's transform isn't the identity transform.
    _bubble.bounds = CGRectMake(0, 0, bubbleW, bubbleH);
    if (!_bubbleWasAdjusted) {
        BOOL bubbleOnLeft = _positionControl.selectedSegmentIndex == 0;
        CGFloat bubbleX = bubbleOnLeft ? CGRectGetMinX(_leftPlaceholder.frame) + 8
                                        : CGRectGetMaxX(_rightPlaceholder.frame) - bubbleW - 8;
        _bubble.center = CGPointMake(bubbleX + bubbleW / 2.0, topInset + 8 + bubbleH / 2.0);
    }

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
    // The title bar is hidden whenever hasSnapshot is YES (see
    // viewDidLayoutSubviews), so the content area only needs to leave
    // room for it while showing the icon fallback.
    CGFloat topOffset = hasSnapshot ? 0 : kSplitCarPlayTitleBarHeight;
    CGRect contentArea = CGRectMake(0, topOffset,
                                     placeholder.bounds.size.width,
                                     placeholder.bounds.size.height - topOffset);
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

- (BOOL)gestureRecognizer:(UITapGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    // Let a tap that lands on one of the empty state's own buttons (a
    // recent-app icon, "Tất cả app") handle itself instead of this
    // whole-box tap swallowing it first.
    return ![touch.view isKindOfClass:[UIControl class]];
}

- (void)leftPlaceholderTapped { [self showAppPickerForLeftSide:YES]; }
- (void)rightPlaceholderTapped { [self showAppPickerForLeftSide:NO]; }

- (void)showAppPickerForLeftSide:(BOOL)isLeft {
    [AppPickerController presentFrom:self
                                title:isLeft ? @"Chọn app ô 1" : @"Chọn app ô 2"
                               onPick:^(NSString *bundleID) {
        SplitCarPlaySetPref(isLeft ? @"leftBundleID" : @"rightBundleID", bundleID);
        [self refresh];
    }];
}

#pragma mark - "Tab mới" empty state

- (void)populateEmptyState:(UIView *)emptyState isLeft:(BOOL)isLeft {
    for (UIView *subview in emptyState.subviews) [subview removeFromSuperview];
    if (emptyState.bounds.size.width <= 0) return;

    UILabel *header = [[UILabel alloc] initWithFrame:CGRectMake(10, 8, emptyState.bounds.size.width - 20, 14)];
    header.text = @"Gần đây";
    header.font = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
    header.textColor = [UIColor colorWithWhite:0.5 alpha:1];
    [emptyState addSubview:header];

    CGFloat itemW = 52, x = 10, y = 26;
    for (NSString *bundleID in SplitCarPlayRecentBundleIDs()) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.frame = CGRectMake(x, y, itemW, 56);
        button.accessibilityIdentifier = bundleID;
        button.tag = isLeft ? 1 : 2;
        [button addTarget:self action:@selector(emptyStateRecentTapped:) forControlEvents:UIControlEventTouchUpInside];

        UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectMake((itemW - 36) / 2.0, 0, 36, 36)];
        icon.image = SplitCarPlayAppIcon(bundleID);
        icon.layer.cornerRadius = 8;
        icon.layer.masksToBounds = YES;
        icon.userInteractionEnabled = NO;
        [button addSubview:icon];

        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 38, itemW, 14)];
        label.text = SplitCarPlayDisplayNameForBundleID(bundleID);
        label.font = [UIFont systemFontOfSize:9];
        label.textColor = [UIColor colorWithWhite:0.15 alpha:1];
        label.textAlignment = NSTextAlignmentCenter;
        label.userInteractionEnabled = NO;
        [button addSubview:label];

        [emptyState addSubview:button];
        x += itemW + 8;
        if (x + itemW > emptyState.bounds.size.width) break; // only as many as fit on one row
    }

    UIButton *allAppsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [allAppsButton setTitle:@"Tất cả app >" forState:UIControlStateNormal];
    allAppsButton.titleLabel.font = [UIFont systemFontOfSize:11];
    allAppsButton.tintColor = [UIColor colorWithRed:0.35 green:0.62 blue:1 alpha:1];
    allAppsButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    allAppsButton.frame = CGRectMake(10, y + 64, emptyState.bounds.size.width - 20, 18);
    allAppsButton.tag = isLeft ? 1 : 2;
    [allAppsButton addTarget:self action:@selector(emptyStateAllAppsTapped:) forControlEvents:UIControlEventTouchUpInside];
    [emptyState addSubview:allAppsButton];
}

- (void)emptyStateRecentTapped:(UIButton *)sender {
    NSString *bundleID = sender.accessibilityIdentifier;
    if (bundleID.length == 0) return;
    SplitCarPlaySetPref(sender.tag == 1 ? @"leftBundleID" : @"rightBundleID", bundleID);
    [self refresh];
}

- (void)emptyStateAllAppsTapped:(UIButton *)sender {
    [self showAppPickerForLeftSide:(sender.tag == 1)];
}

- (void)styleChanged:(UISegmentedControl *)sender {
    SplitCarPlaySetPref(@"bubbleStyle", @(sender.selectedSegmentIndex));
    _bubble.style = (SplitCarPlayBubbleStyle)sender.selectedSegmentIndex;
    _bubbleWasAdjusted = NO; // an explicit style pick re-homes the bubble to the Left/Right default spot
    [self.view setNeedsLayout];
}

- (void)positionChanged:(UISegmentedControl *)sender {
    SplitCarPlaySetPref(@"bubblePosition", @(sender.selectedSegmentIndex));
    _bubbleWasAdjusted = NO; // ditto -- Left/Right is an explicit placement choice, not overridden by a stale drag
    [self.view setNeedsLayout];
}

- (void)refresh {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath] ?: @{};
    NSString *leftID = prefs[@"leftBundleID"];
    NSString *rightID = prefs[@"rightBundleID"];
    _leftIsEmpty = leftID.length == 0;
    _rightIsEmpty = rightID.length == 0;

    // "+ Tab mới" in the title bar, same as an empty browser tab, when
    // nothing's picked yet for that box -- the "Gần đây"/"Tất cả app"
    // empty state below fills the rest (see populateEmptyState:isLeft:).
    _leftLabel.text = _leftIsEmpty ? @"+  Tab mới" : (SplitCarPlayDisplayNameForBundleID(leftID) ?: leftID);
    _rightLabel.text = _rightIsEmpty ? @"+  Tab mới" : (SplitCarPlayDisplayNameForBundleID(rightID) ?: rightID);
    _leftTitleIcon.image = _leftIsEmpty ? nil : SplitCarPlayAppIcon(leftID);
    _rightTitleIcon.image = _rightIsEmpty ? nil : SplitCarPlayAppIcon(rightID);

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
    // hasn't touched yet in "Trên xe" -- an untouched row shows its
    // "default" on-screen but doesn't necessarily write that value into
    // this plist file until actually changed, so reading the file
    // directly (as this whole controller does, for simplicity) needs the
    // same fallback or this preview can show a different starting value
    // than what the real CarPlay bubble would actually use.
    _bubble.style = (SplitCarPlayBubbleStyle)[prefs[@"bubbleStyle"] integerValue];
    _bubble.showDate = prefs[@"showDate"] ? [prefs[@"showDate"] boolValue] : YES;
    _bubble.showBattery = prefs[@"showBattery"] ? [prefs[@"showBattery"] boolValue] : YES;
    _bubble.scale = prefs[@"bubbleScale"] ? [prefs[@"bubbleScale"] doubleValue] : 1.0;
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
