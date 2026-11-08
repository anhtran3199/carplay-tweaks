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
#import "../SplitCarPlayShared.h"

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

#pragma mark - Small UI helpers

// SF Symbol at a fixed point size. Deployment target is iOS 14, so the
// availability check is always true on real devices; kept anyway so the
// file stays self-evidently safe if the target is ever lowered.
static UIImage *SCPSymbol(NSString *name, CGFloat pointSize, BOOL bold) {
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:pointSize
                                                                                               weight:(bold ? UIImageSymbolWeightBold : UIImageSymbolWeightMedium)];
        return [UIImage systemImageNamed:name withConfiguration:config];
    }
    return nil;
}

static CGFloat SCPHairline(void) {
    CGFloat scale = [UIScreen mainScreen].scale;
    return scale > 0 ? 1.0 / scale : 1.0;
}

// Pref values are expected to be strings; anything else (missing, wrong
// type) reads as "" so callers can just check .length.
static NSString *SCPStringPref(NSDictionary *prefs, NSString *key) {
    id value = prefs[key];
    return [value isKindOfClass:[NSString class]] ? (NSString *)value : @"";
}

static NSString * const kSCPVietmapBundleID = @"vn.vietmap.live";

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
// isLive = real Vietmap Live data vs. made-up demo numbers. The Card style
// switches between two looks: idle (date / battery / big number / dashed
// speed-limit circle, plus a small "Demo" tag so the made-up number is
// never mistaken for real data) and connected (speed in a green-bordered
// box, green check, Vietmap icon, "Đã kết nối VIETMAP LIVE", green bar).
- (void)applySpeedText:(NSString *)text overLimit:(BOOL)overLimit isLive:(BOOL)isLive;
@end

@implementation PreviewBubbleView {
    UIView *_speedBox;
    UILabel *_speedLabel;
    UILabel *_unitLabel;
    UIImageView *_statusIconView;
    UIView *_statusBar;
    UILabel *_extrasLabel;        // date, its own line
    UIImageView *_batteryIconView;
    UILabel *_batteryLabel;       // battery %, same line as the glyph
    UIView *_separator;
    UIView *_compassView;         // dashed circle for the speed limit -- always "--" in this preview
    CAShapeLayer *_compassDashLayer;
    UILabel *_compassLabel;
    UILabel *_demoLabel;
    UIImageView *_liveAppIconView;
    UILabel *_liveTextLabel;
    CAShapeLayer *_ringLayer;
    UIPanGestureRecognizer *_pan;
    UIPinchGestureRecognizer *_pinch;
    CGFloat _currentScale;
    BOOL _isLive;
    BOOL _overLimit;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor whiteColor];
        self.layer.borderWidth = SCPHairline();
        self.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.10].CGColor;
        // Plain cornerRadius (no mask, no masksToBounds) so the soft drop
        // shadow isn't clipped; every subview is laid out inside the
        // rounded area, so nothing pokes out of the corners.
        self.layer.masksToBounds = NO;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.16;
        self.layer.shadowRadius = 8;
        self.layer.shadowOffset = CGSizeMake(0, 3);

        UIColor *secondary = [UIColor colorWithWhite:0.45 alpha:1];

        _speedBox = [[UIView alloc] init];
        _speedBox.backgroundColor = [UIColor whiteColor];
        _speedBox.layer.cornerRadius = 10;
        _speedBox.layer.borderWidth = 2;
        [self addSubview:_speedBox];

        _speedLabel = [[UILabel alloc] init];
        _speedLabel.textAlignment = NSTextAlignmentCenter;
        _speedLabel.font = [UIFont systemFontOfSize:40 weight:UIFontWeightSemibold];
        _speedLabel.adjustsFontSizeToFitWidth = YES;
        _speedLabel.minimumScaleFactor = 0.5;
        _speedLabel.textColor = [UIColor colorWithWhite:0.1 alpha:1];
        _speedLabel.text = @"--";
        [self addSubview:_speedLabel];

        _unitLabel = [[UILabel alloc] init];
        _unitLabel.textAlignment = NSTextAlignmentCenter;
        _unitLabel.font = [UIFont systemFontOfSize:11];
        _unitLabel.textColor = secondary;
        _unitLabel.text = @"km/h";
        [self addSubview:_unitLabel];

        _statusIconView = [[UIImageView alloc] init];
        _statusIconView.contentMode = UIViewContentModeScaleAspectFit;
        [self addSubview:_statusIconView];

        _extrasLabel = [[UILabel alloc] init];
        _extrasLabel.textAlignment = NSTextAlignmentCenter;
        _extrasLabel.font = [UIFont systemFontOfSize:12];
        _extrasLabel.textColor = secondary;
        [self addSubview:_extrasLabel];

        _batteryIconView = [[UIImageView alloc] init];
        _batteryIconView.contentMode = UIViewContentModeScaleAspectFit;
        _batteryIconView.tintColor = secondary;
        [self addSubview:_batteryIconView];

        _batteryLabel = [[UILabel alloc] init];
        _batteryLabel.textAlignment = NSTextAlignmentLeft;
        _batteryLabel.font = [UIFont systemFontOfSize:12];
        _batteryLabel.textColor = secondary;
        [self addSubview:_batteryLabel];

        _separator = [[UIView alloc] init];
        _separator.backgroundColor = [UIColor colorWithWhite:0.86 alpha:1];
        [self addSubview:_separator];

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
        _compassLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        _compassLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1];
        [_compassView addSubview:_compassLabel];

        _demoLabel = [[UILabel alloc] init];
        _demoLabel.text = @"Demo";
        _demoLabel.textAlignment = NSTextAlignmentCenter;
        _demoLabel.font = [UIFont systemFontOfSize:9 weight:UIFontWeightMedium];
        _demoLabel.textColor = [UIColor systemOrangeColor];
        [self addSubview:_demoLabel];

        _liveAppIconView = [[UIImageView alloc] init];
        _liveAppIconView.contentMode = UIViewContentModeScaleAspectFit;
        _liveAppIconView.layer.cornerRadius = 7;
        _liveAppIconView.layer.masksToBounds = YES;
        [self addSubview:_liveAppIconView];

        NSMutableParagraphStyle *centered = [[NSMutableParagraphStyle alloc] init];
        centered.alignment = NSTextAlignmentCenter;
        NSMutableAttributedString *liveText = [[NSMutableAttributedString alloc] initWithString:@"Đã kết nối\n" attributes:@{
            NSFontAttributeName: [UIFont systemFontOfSize:10 weight:UIFontWeightMedium],
            NSForegroundColorAttributeName: [UIColor colorWithWhite:0.25 alpha:1],
            NSParagraphStyleAttributeName: centered,
        }];
        [liveText appendAttributedString:[[NSAttributedString alloc] initWithString:@"VIETMAP\nLIVE" attributes:@{
            NSFontAttributeName: [UIFont systemFontOfSize:11 weight:UIFontWeightBold],
            NSForegroundColorAttributeName: [UIColor systemGreenColor],
            NSParagraphStyleAttributeName: centered,
        }]];
        _liveTextLabel = [[UILabel alloc] init];
        _liveTextLabel.numberOfLines = 0;
        _liveTextLabel.attributedText = liveText;
        [self addSubview:_liveTextLabel];

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

- (void)applyCornerRadius:(CGFloat)radius {
    self.layer.cornerRadius = radius;
    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:radius].CGPath;
}

// Every style starts from "nothing optional visible" and turns on only
// what it uses -- keeps the three layouts from leaking views into each other.
- (void)hideOptionalViews {
    _speedBox.hidden = YES;
    _statusIconView.hidden = YES;
    _statusBar.hidden = YES;
    _extrasLabel.hidden = YES;
    _batteryIconView.hidden = YES;
    _batteryLabel.hidden = YES;
    _separator.hidden = YES;
    _compassView.hidden = YES;
    _demoLabel.hidden = YES;
    _liveAppIconView.hidden = YES;
    _liveTextLabel.hidden = YES;
    _ringLayer.hidden = YES;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self hideOptionalViews];
    switch (self.style) {
        case SplitCarPlayBubbleStyleRing: [self layoutRing]; return;
        case SplitCarPlayBubbleStyleBar: [self layoutBar]; return;
        case SplitCarPlayBubbleStyleCard: default:
            [self applyCornerRadius:14];
            if (_isLive) {
                [self layoutCardLive];
            } else {
                [self layoutCardIdle];
            }
            return;
    }
}

- (void)layoutCardIdle {
    CGFloat w = self.bounds.size.width, pad = 8;
    CGFloat y = pad;

    if (self.showDate) {
        _extrasLabel.hidden = NO;
        _extrasLabel.text = SplitCarPlayWeekdayDateString([NSDate date]);
        _extrasLabel.frame = CGRectMake(pad, y, w - pad * 2, 15);
        y = CGRectGetMaxY(_extrasLabel.frame) + 1;
    }
    UIDevice *device = [UIDevice currentDevice];
    if (self.showBattery && device.batteryState != UIDeviceBatteryStateUnknown && device.batteryLevel >= 0) {
        _batteryLabel.hidden = NO;
        _batteryIconView.hidden = NO;
        _batteryLabel.text = [NSString stringWithFormat:@"%.0f%%", device.batteryLevel * 100];
        _batteryIconView.image = SplitCarPlayBatteryIcon(device.batteryLevel);
        CGFloat labelW = ceil([_batteryLabel sizeThatFits:CGSizeMake(w, 15)].width);
        CGFloat glyphW = 20, gap = 3;
        CGFloat x0 = floor((w - (labelW + gap + glyphW)) / 2.0);
        _batteryLabel.frame = CGRectMake(x0, y, labelW, 15);
        _batteryIconView.frame = CGRectMake(x0 + labelW + gap, y + 2, glyphW, 11);
        y += 15;
    }
    if (y > pad) {
        y += 5;
        _separator.hidden = NO;
        _separator.frame = CGRectMake(pad, y, w - pad * 2, SCPHairline());
        y += 4;
    }

    [self addSubview:_speedLabel];
    [self addSubview:_unitLabel];
    _speedLabel.font = [UIFont systemFontOfSize:40 weight:UIFontWeightSemibold];
    _speedLabel.frame = CGRectMake(4, y, w - 8, 46);
    _unitLabel.frame = CGRectMake(0, CGRectGetMaxY(_speedLabel.frame) - 2, w, 13);
    y = CGRectGetMaxY(_unitLabel.frame) + 8;

    CGFloat compassSize = MIN(54, w - pad * 2);
    _compassView.hidden = NO;
    _compassView.frame = CGRectMake(floor((w - compassSize) / 2.0), y, compassSize, compassSize);
    _compassLabel.frame = _compassView.bounds;
    _compassDashLayer.frame = _compassView.bounds;
    _compassDashLayer.path = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(_compassView.bounds, 1, 1)].CGPath;
    y = CGRectGetMaxY(_compassView.frame) + 4;

    _demoLabel.hidden = NO;
    _demoLabel.frame = CGRectMake(0, y, w, 11);
}

- (void)layoutCardLive {
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height, pad = 8;

    CGFloat boxW = MIN(w - pad * 2, 68);
    _speedBox.hidden = NO;
    _speedBox.frame = CGRectMake(floor((w - boxW) / 2.0), pad + 2, boxW, 56);
    [_speedBox addSubview:_speedLabel];
    [_speedBox addSubview:_unitLabel];
    _speedLabel.font = [UIFont systemFontOfSize:28 weight:UIFontWeightSemibold];
    _speedLabel.frame = CGRectMake(2, 5, boxW - 4, 32);
    _unitLabel.frame = CGRectMake(0, 36, boxW, 13);
    CGFloat y = CGRectGetMaxY(_speedBox.frame) + 8;

    CGFloat checkSize = 20;
    _statusIconView.hidden = NO;
    _statusIconView.frame = CGRectMake(floor((w - checkSize) / 2.0), y, checkSize, checkSize);
    y += checkSize + 6;

    CGFloat appIconSize = 28;
    _liveAppIconView.hidden = NO;
    _liveAppIconView.frame = CGRectMake(floor((w - appIconSize) / 2.0), y, appIconSize, appIconSize);
    y += appIconSize + 6;

    _liveTextLabel.hidden = NO;
    _liveTextLabel.frame = CGRectMake(4, y, w - 8, 44);

    CGFloat barHeight = 3, barInset = pad + 4;
    _statusBar.hidden = NO;
    _statusBar.frame = CGRectMake(barInset, h - barHeight - 7, w - barInset * 2, barHeight);
    _statusBar.layer.cornerRadius = barHeight / 2.0;
}

- (void)layoutRing {
    CGFloat side = MIN(self.bounds.size.width, self.bounds.size.height);
    [self applyCornerRadius:side / 2.0];
    _ringLayer.hidden = NO;

    CGRect ringFrame = CGRectMake((self.bounds.size.width - side) / 2.0, (self.bounds.size.height - side) / 2.0, side, side);
    CGFloat inset = _ringLayer.lineWidth / 2.0 + 2;
    _ringLayer.path = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(ringFrame, inset, inset)].CGPath;
    _ringLayer.frame = self.bounds;

    _speedLabel.font = [UIFont boldSystemFontOfSize:28];
    [self addSubview:_speedLabel];
    _speedLabel.frame = CGRectMake(10, side / 2.0 - 20, self.bounds.size.width - 20, 28);
    [self addSubview:_unitLabel];
    _unitLabel.frame = CGRectMake(0, side / 2.0 + 6, self.bounds.size.width, 14);

    _statusIconView.hidden = NO;
    CGFloat iconSize = 16;
    _statusIconView.frame = CGRectMake((self.bounds.size.width - iconSize) / 2.0, side - iconSize - 10, iconSize, iconSize);
}

- (void)layoutBar {
    [self applyCornerRadius:self.bounds.size.height / 2.0];
    _statusBar.hidden = NO;

    CGFloat h = self.bounds.size.height, pad = 10;
    CGFloat iconSize = MIN(16, h - 8);
    _statusIconView.hidden = NO;
    _statusIconView.frame = CGRectMake(pad + 4, (h - iconSize) / 2.0, iconSize, iconSize);

    _speedLabel.font = [UIFont boldSystemFontOfSize:MIN(22, h * 0.5)];
    [self addSubview:_speedLabel];
    _speedLabel.frame = CGRectMake(CGRectGetMaxX(_statusIconView.frame) + 8, 0, 70, h);
    [self addSubview:_unitLabel];
    _unitLabel.frame = CGRectMake(CGRectGetMaxX(_speedLabel.frame), 0, 36, h);

    CGFloat barHeight = 3;
    _statusBar.frame = CGRectMake(pad + 8, h - barHeight - 3, self.bounds.size.width - (pad + 8) * 2, barHeight);
    _statusBar.layer.cornerRadius = barHeight / 2.0;
}

- (void)applySpeedText:(NSString *)text overLimit:(BOOL)overLimit isLive:(BOOL)isLive {
    _isLive = isLive;
    _overLimit = overLimit;
    _speedLabel.text = text.length > 0 ? text : @"--";
    _speedLabel.textColor = overLimit ? [UIColor systemRedColor] : [UIColor colorWithWhite:0.1 alpha:1];

    UIColor *accent = overLimit ? [UIColor systemRedColor]
        : (isLive ? [UIColor systemGreenColor] : [UIColor colorWithWhite:0.75 alpha:1]);
    _speedBox.layer.borderColor = accent.CGColor;
    _ringLayer.strokeColor = (overLimit ? [UIColor systemRedColor]
        : (isLive ? [UIColor systemGreenColor] : [UIColor systemGrayColor])).CGColor;
    if (@available(iOS 13.0, *)) {
        _statusIconView.image = [UIImage systemImageNamed:isLive ? @"checkmark.circle.fill" : @"questionmark.circle"];
    }
    _statusIconView.tintColor = isLive ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
    _statusBar.backgroundColor = overLimit ? [UIColor systemRedColor]
        : (isLive ? [UIColor systemGreenColor] : [UIColor systemOrangeColor]);
    if (isLive && !_liveAppIconView.image) {
        _liveAppIconView.image = SplitCarPlayAppIcon(kSCPVietmapBundleID);
    }
    [self setNeedsLayout];
}

@end

#pragma mark - One pane of the split preview (browser-tab look)

static const CGFloat kSCPPaneBarHeight = 34;
static const CGFloat kSCPPaneCircleSize = 18;
static const CGFloat kSCPPaneButtonSlot = 24; // tap target per circle button; the visible circle is kSCPPaneCircleSize
static const CGFloat kSCPPaneGap = 6;         // gap between the two panes (the divider pill sits over it)
static const CGFloat kSCPCarFramePad = 6;     // outer car-screen frame around both panes

// A UIButton whose visible part is a small colored circle centered in a
// bigger tap target. The circle is a non-interactive subview kept behind
// the button's image view.
@interface SCPCircleButton : UIButton
@property (nonatomic, strong) UIView *circleView;
@end

@implementation SCPCircleButton
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat s = kSCPPaneCircleSize;
    self.circleView.frame = CGRectMake(floor((self.bounds.size.width - s) / 2.0),
                                       floor((self.bounds.size.height - s) / 2.0), s, s);
    [self sendSubviewToBack:self.circleView];
}
@end

static SCPCircleButton *SCPMakeCircleButton(NSString *symbolName) {
    SCPCircleButton *button = [SCPCircleButton buttonWithType:UIButtonTypeCustom];
    UIView *circle = [[UIView alloc] init];
    circle.userInteractionEnabled = NO; // touches must land on the button itself
    circle.layer.cornerRadius = kSCPPaneCircleSize / 2.0;
    [button addSubview:circle];
    button.circleView = circle;
    [button setImage:[SCPSymbol(symbolName, 8, YES) imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
            forState:UIControlStateNormal];
    return button;
}

static void SCPStyleCircleButton(SCPCircleButton *button, UIColor *fill, UIColor *glyph, BOOL enabled) {
    button.circleView.backgroundColor = fill;
    button.tintColor = glyph;
    button.enabled = enabled;
}

@interface PreviewPaneView : UIView
@property (nonatomic, strong, readonly) UIControl *tabControl;
@property (nonatomic, strong, readonly) SCPCircleButton *reloadButton;
@property (nonatomic, strong, readonly) SCPCircleButton *swapButton;
@property (nonatomic, strong, readonly) SCPCircleButton *closeButton;
// Filled in by PreviewViewController (it owns the recent-apps data and the
// tap targets); the pane only sizes it to its content area.
@property (nonatomic, strong, readonly) UIView *emptyState;
@property (nonatomic, assign) CGSize emptyStateBuiltSize; // controller's "already populated at this size" marker
@property (nonatomic, assign, readonly) BOOL isEmpty;
- (void)showEmpty;
- (void)showAppNamed:(NSString *)name icon:(UIImage *)icon snapshot:(UIImage *)snapshot;
@end

@implementation PreviewPaneView {
    UIView *_bar;
    UIImageView *_tabIcon;
    UILabel *_tabLabel;
    UIImageView *_tabChevron;
    UIView *_contentView;
    UIImageView *_snapshotView;
    UIView *_pickedTile;
    UIImageView *_pickedIcon;
    UILabel *_pickedName;
    UILabel *_pickedSubtitle;
    BOOL _hasSnapshot;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        UIColor *paper = [UIColor colorWithWhite:0.985 alpha:1];
        self.backgroundColor = paper;
        self.layer.cornerRadius = 10;
        self.layer.masksToBounds = YES;
        self.layer.borderWidth = SCPHairline();
        self.layer.borderColor = [UIColor colorWithWhite:0.80 alpha:1].CGColor;

        _contentView = [[UIView alloc] init];
        _contentView.backgroundColor = paper;
        _contentView.clipsToBounds = YES;
        [self addSubview:_contentView];

        _snapshotView = [[UIImageView alloc] init];
        _snapshotView.contentMode = UIViewContentModeScaleToFill; // frame is computed as an aspect-fill, top-aligned rect
        [_contentView addSubview:_snapshotView];

        _pickedTile = [[UIView alloc] init];
        _pickedTile.backgroundColor = [UIColor whiteColor];
        _pickedTile.layer.cornerRadius = 14;
        _pickedTile.layer.shadowColor = [UIColor blackColor].CGColor;
        _pickedTile.layer.shadowOpacity = 0.12;
        _pickedTile.layer.shadowRadius = 6;
        _pickedTile.layer.shadowOffset = CGSizeMake(0, 2);
        [_contentView addSubview:_pickedTile];

        _pickedIcon = [[UIImageView alloc] init];
        _pickedIcon.contentMode = UIViewContentModeScaleAspectFit;
        _pickedIcon.layer.cornerRadius = 10;
        _pickedIcon.layer.masksToBounds = YES;
        [_pickedTile addSubview:_pickedIcon];

        _pickedName = [[UILabel alloc] init];
        _pickedName.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        _pickedName.textColor = [UIColor colorWithWhite:0.15 alpha:1];
        _pickedName.textAlignment = NSTextAlignmentCenter;
        _pickedName.lineBreakMode = NSLineBreakByTruncatingTail;
        [_contentView addSubview:_pickedName];

        // Honest about what this screen can do: it shows iOS's cached
        // app-switcher snapshot, which only exists after the app has been
        // opened (and backgrounded) at least once. It cannot launch apps.
        _pickedSubtitle = [[UILabel alloc] init];
        _pickedSubtitle.text = @"Mở app này 1 lần để có ảnh xem trước";
        _pickedSubtitle.font = [UIFont systemFontOfSize:11];
        _pickedSubtitle.textColor = [UIColor colorWithWhite:0.5 alpha:1];
        _pickedSubtitle.textAlignment = NSTextAlignmentCenter;
        _pickedSubtitle.numberOfLines = 3;
        [_contentView addSubview:_pickedSubtitle];

        _emptyState = [[UIView alloc] init];
        [_contentView addSubview:_emptyState];

        _bar = [[UIView alloc] init];
        _bar.backgroundColor = [UIColor colorWithWhite:0.90 alpha:1];
        [self addSubview:_bar];

        // The "browser tab": same color as the content below so it reads
        // as one piece, rounded on its top corners only.
        _tabControl = [[UIControl alloc] init];
        _tabControl.backgroundColor = paper;
        _tabControl.layer.cornerRadius = 8;
        _tabControl.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
        [_bar addSubview:_tabControl];

        _tabIcon = [[UIImageView alloc] init];
        _tabIcon.contentMode = UIViewContentModeScaleAspectFit;
        _tabIcon.layer.masksToBounds = YES;
        [_tabControl addSubview:_tabIcon];

        _tabLabel = [[UILabel alloc] init];
        _tabLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        _tabLabel.textColor = [UIColor colorWithWhite:0.2 alpha:1];
        _tabLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [_tabControl addSubview:_tabLabel];

        _tabChevron = [[UIImageView alloc] init];
        _tabChevron.contentMode = UIViewContentModeScaleAspectFit;
        _tabChevron.image = [SCPSymbol(@"chevron.down", 8, YES) imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        _tabChevron.tintColor = [UIColor colorWithWhite:0.45 alpha:1];
        [_tabControl addSubview:_tabChevron];

        _reloadButton = SCPMakeCircleButton(@"arrow.clockwise");
        _swapButton = SCPMakeCircleButton(@"arrow.left.arrow.right");
        _closeButton = SCPMakeCircleButton(@"xmark");
        _reloadButton.accessibilityLabel = @"Tải lại ảnh xem trước";
        _swapButton.accessibilityLabel = @"Đổi chỗ 2 ô";
        _closeButton.accessibilityLabel = @"Bỏ app khỏi ô này";
        [_bar addSubview:_reloadButton];
        [_bar addSubview:_swapButton];
        [_bar addSubview:_closeButton];

        [self showEmpty];
    }
    return self;
}

- (void)showEmpty {
    _isEmpty = YES;
    _hasSnapshot = NO;
    _tabIcon.image = [SCPSymbol(@"plus", 11, NO) imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    _tabIcon.tintColor = [UIColor colorWithWhite:0.35 alpha:1];
    _tabIcon.layer.cornerRadius = 0;
    _tabLabel.text = @"Tab mới";
    _tabControl.accessibilityLabel = @"Tab mới, chọn app";
    _snapshotView.image = nil;
    _pickedIcon.image = nil;
    _pickedName.text = nil;
    [self setNeedsLayout];
}

- (void)showAppNamed:(NSString *)name icon:(UIImage *)icon snapshot:(UIImage *)snapshot {
    _isEmpty = NO;
    _hasSnapshot = snapshot != nil;
    _tabIcon.image = icon;
    _tabIcon.layer.cornerRadius = 4;
    _tabLabel.text = name;
    _tabControl.accessibilityLabel = name;
    _snapshotView.image = snapshot;
    _pickedIcon.image = icon;
    _pickedName.text = name;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    _bar.frame = CGRectMake(0, 0, w, kSCPPaneBarHeight);
    _contentView.frame = CGRectMake(0, kSCPPaneBarHeight, w, MAX(0, h - kSCPPaneBarHeight));
    [self layoutBar];
    [self layoutContent];
}

- (void)layoutBar {
    CGFloat w = _bar.bounds.size.width, barH = kSCPPaneBarHeight;
    CGFloat slot = kSCPPaneButtonSlot, rightPad = 5;

    // A very narrow pane (split dragged far to one side) keeps only ✕.
    BOOL roomForAll = w >= rightPad + slot * 3 + 12 + 40;
    _reloadButton.hidden = !roomForAll;
    _swapButton.hidden = !roomForAll;
    CGFloat x = w - rightPad - slot;
    _closeButton.frame = CGRectMake(x, 0, slot, barH);
    if (roomForAll) {
        x -= slot;
        _swapButton.frame = CGRectMake(x, 0, slot, barH);
        x -= slot;
        _reloadButton.frame = CGRectMake(x, 0, slot, barH);
    }

    CGFloat tabX = 6, tabY = 6, tabH = barH - tabY, pad = 8;
    CGFloat avail = MAX(0, x - 4 - tabX);
    CGFloat iconSize = _isEmpty ? 12 : 16;
    CGFloat gapIconLabel = _isEmpty ? 5 : 6, gapLabelChevron = 4, chevronW = 9;
    CGFloat labelW = ceil([_tabLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, tabH)].width);
    CGFloat fixedW = pad + iconSize + gapIconLabel + gapLabelChevron + chevronW + pad;
    CGFloat iconOnlyW = pad + iconSize + pad;

    BOOL showLabel = NO;
    CGFloat tabW = iconOnlyW;
    if (avail >= fixedW + labelW) {
        showLabel = YES;
        tabW = fixedW + labelW;
    } else if (!_isEmpty && avail >= fixedW + 28) {
        showLabel = YES; // app name, truncated
        labelW = avail - fixedW;
        tabW = avail;
    } else {
        tabW = MIN(MAX(avail, 24), iconOnlyW); // just "+" or just the icon
    }

    _tabControl.frame = CGRectMake(tabX, tabY, tabW, tabH);
    _tabLabel.hidden = !showLabel;
    _tabChevron.hidden = !showLabel;
    CGFloat iconX = showLabel ? pad : floor((tabW - iconSize) / 2.0);
    _tabIcon.frame = CGRectMake(iconX, floor((tabH - iconSize) / 2.0), iconSize, iconSize);
    if (showLabel) {
        _tabLabel.frame = CGRectMake(CGRectGetMaxX(_tabIcon.frame) + gapIconLabel, 0, MAX(0, labelW), tabH);
        _tabChevron.frame = CGRectMake(CGRectGetMaxX(_tabLabel.frame) + gapLabelChevron, floor((tabH - 9) / 2.0), chevronW, 9);
    }
}

- (void)layoutContent {
    CGFloat cw = _contentView.bounds.size.width, ch = _contentView.bounds.size.height;
    BOOL showPicked = !_isEmpty && !_hasSnapshot;

    _emptyState.frame = _contentView.bounds;
    _emptyState.hidden = !_isEmpty;
    _snapshotView.hidden = !_hasSnapshot;
    _pickedTile.hidden = !showPicked;
    _pickedName.hidden = !showPicked;
    _pickedSubtitle.hidden = !showPicked;

    if (_hasSnapshot) {
        // Aspect fill, but pinned to the top edge (status bar / app header
        // of the snapshot stays visible) instead of UIKit's centered fill.
        CGSize imageSize = _snapshotView.image.size;
        if (imageSize.width > 0 && imageSize.height > 0 && cw > 0 && ch > 0) {
            CGFloat s = MAX(cw / imageSize.width, ch / imageSize.height);
            CGFloat drawW = ceil(imageSize.width * s), drawH = ceil(imageSize.height * s);
            _snapshotView.frame = CGRectMake(floor((cw - drawW) / 2.0), 0, drawW, drawH);
        } else {
            _snapshotView.frame = _contentView.bounds;
        }
    }

    if (showPicked) {
        CGFloat tile = MIN(64, MAX(0, cw - 16));
        CGFloat textW = MAX(0, cw - 20);
        CGFloat subH = MIN(44, ceil([_pickedSubtitle sizeThatFits:CGSizeMake(textW, CGFLOAT_MAX)].height));
        CGFloat blockH = tile + 10 + 20 + 4 + subH;
        CGFloat y = MAX(8, floor((ch - blockH) / 2.0) - 8);
        _pickedTile.frame = CGRectMake(floor((cw - tile) / 2.0), y, tile, tile);
        _pickedTile.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:_pickedTile.bounds cornerRadius:14].CGPath;
        CGFloat icon = floor(tile * 0.69);
        _pickedIcon.frame = CGRectMake(floor((tile - icon) / 2.0), floor((tile - icon) / 2.0), icon, icon);
        y = CGRectGetMaxY(_pickedTile.frame) + 10;
        _pickedName.frame = CGRectMake(10, y, textW, 20);
        y += 24;
        _pickedSubtitle.frame = CGRectMake(10, y, textW, subH);
    }
}

@end

#pragma mark - Preview screen

@interface PreviewViewController : UIViewController <UIGestureRecognizerDelegate>
@end


@implementation PreviewViewController {
    UILabel *_headingLabel;
    UIView *_carScreenFrame;
    PreviewPaneView *_leftPane;
    PreviewPaneView *_rightPane;
    UIView *_dividerHandle;   // big invisible drag target
    UIView *_dividerPill;     // the visible white "≡" pill inside it
    UIButton *_edgeHandle;    // left-edge half-capsule, toggles the speed card
    UIView *_edgeVisual;
    UIImageView *_edgeChevron;
    PreviewBubbleView *_bubble;
    UISegmentedControl *_styleControl;
    UISegmentedControl *_positionControl;
    UILabel *_captionLabel;
    CGFloat _splitRatio;
    CGFloat _dragStartRatio;
    BOOL _bubbleWasAdjusted; // once the bubble's been dragged, stop re-centering it every layout pass
    BOOL _bubbleHiddenLocally; // edge-handle toggle; preview only, never written to prefs

    // Real apps hosted over the panes by SpringBoard (LivePreview.xm),
    // started automatically while this tab is on screen. State comes back
    // through SCPGetLiveState().
    NSTimer *_liveTimer;
    BOOL _visible;          // between viewDidAppear and viewWillDisappear
    BOOL _autoStartPending; // a restart is coming, so a stop isn't the user's ✕
    BOOL _singleThisVisit;  // SpringBoard crashed with 2 apps last time: run ô 1 only
    uint64_t _shownLiveState;

    // Looked up once per refresh (display-name lookup walks every
    // installed app), reused by the "Gần đây" empty state on every layout
    // pass -- including every frame of a divider drag.
    NSArray<NSString *> *_recentIDs;
    NSDictionary<NSString *, UIImage *> *_recentIcons;
    NSDictionary<NSString *, NSString *> *_recentNames;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Mô phỏng";
    // Reference screenshots show a big bold heading directly on a white
    // page, no visible nav bar. Hides the nav bar for just this tab's own
    // navigation controller and draws the heading as a real label instead.
    self.view.backgroundColor = [UIColor whiteColor];
    // Without this, batteryState stays Unknown and the card's battery row
    // never shows (nothing else in this app turns monitoring on).
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;

    _headingLabel = [[UILabel alloc] init];
    _headingLabel.text = @"Mô phỏng";
    _headingLabel.font = [UIFont boldSystemFontOfSize:34];
    _headingLabel.textColor = [UIColor blackColor];
    [self.view addSubview:_headingLabel];

    // One outer "car screen" frame wrapping both panes -- the one physical
    // CarPlay display being split in two. Added behind the panes.
    _carScreenFrame = [[UIView alloc] init];
    _carScreenFrame.backgroundColor = [UIColor colorWithWhite:0.95 alpha:1];
    _carScreenFrame.layer.cornerRadius = 16;
    _carScreenFrame.layer.borderWidth = SCPHairline();
    _carScreenFrame.layer.borderColor = [UIColor colorWithWhite:0.80 alpha:1].CGColor;
    _carScreenFrame.layer.shadowColor = [UIColor blackColor].CGColor;
    _carScreenFrame.layer.shadowOpacity = 0.06;
    _carScreenFrame.layer.shadowRadius = 10;
    _carScreenFrame.layer.shadowOffset = CGSizeMake(0, 3);
    [self.view addSubview:_carScreenFrame];

    _leftPane = [self makePaneWithTag:1];
    _rightPane = [self makePaneWithTag:2];

    // Drag this to resize the split live -- same "splitRatio" pref the
    // "Split Ratio" slider on the "Trên xe" tab controls, so either one
    // moves the other. The visible pill is small; the clear container
    // around it is the (much easier to grab) hit area.
    _dividerHandle = [[UIView alloc] init];
    _dividerHandle.backgroundColor = [UIColor clearColor];
    _dividerHandle.userInteractionEnabled = YES;
    [self.view addSubview:_dividerHandle];

    _dividerPill = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 56)];
    _dividerPill.backgroundColor = [UIColor whiteColor];
    _dividerPill.layer.cornerRadius = 5;
    _dividerPill.layer.borderWidth = SCPHairline();
    _dividerPill.layer.borderColor = [UIColor colorWithWhite:0.78 alpha:1].CGColor;
    _dividerPill.layer.shadowColor = [UIColor blackColor].CGColor;
    _dividerPill.layer.shadowOpacity = 0.15;
    _dividerPill.layer.shadowRadius = 3;
    _dividerPill.layer.shadowOffset = CGSizeMake(0, 1);
    _dividerPill.userInteractionEnabled = NO;
    for (NSInteger i = 0; i < 3; i++) { // "≡" grip
        UIView *line = [[UIView alloc] initWithFrame:CGRectMake(3, 23 + i * 4, 4, 1)];
        line.backgroundColor = [UIColor colorWithWhite:0.5 alpha:1];
        line.layer.cornerRadius = 0.5;
        [_dividerPill addSubview:line];
    }
    [_dividerHandle addSubview:_dividerPill];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleDividerPan:)];
    [_dividerHandle addGestureRecognizer:pan];

    _styleControl = [[UISegmentedControl alloc] initWithItems:@[@"Card", @"Ring", @"Bar"]];
    NSDictionary *prefs = SCPCopyPrefs();
    _styleControl.selectedSegmentIndex = [prefs[@"bubbleStyle"] integerValue];
    [_styleControl addTarget:self action:@selector(styleChanged:) forControlEvents:UIControlEventValueChanged];
    // Not shown: style and side are set in "Trên xe". The controls only
    // hold the current values for this screen's bubble layout.

    _positionControl = [[UISegmentedControl alloc] initWithItems:@[@"Trái", @"Phải"]];
    _positionControl.selectedSegmentIndex = [prefs[@"bubblePosition"] integerValue];
    [_positionControl addTarget:self action:@selector(positionChanged:) forControlEvents:UIControlEventValueChanged];

    _captionLabel = [[UILabel alloc] init];
    _captionLabel.textColor = [UIColor colorWithWhite:0.45 alpha:1];
    _captionLabel.font = [UIFont systemFontOfSize:12];
    _captionLabel.textAlignment = NSTextAlignmentCenter;
    _captionLabel.numberOfLines = 0;
    _captionLabel.text = nil; // only used for errors and warnings
    [self.view addSubview:_captionLabel];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appDidEnterBackground)
                                                 name:UIApplicationDidEnterBackgroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(scheduleAutoStart)
                                                 name:UIApplicationDidBecomeActiveNotification object:nil];
    [self updateLiveUI];

    _bubble = [[PreviewBubbleView alloc] initWithFrame:CGRectZero];
    [self.view addSubview:_bubble];
    // Drag the bubble anywhere, pinch to resize it -- persists the scale
    // to the shared "bubbleScale" pref (also read by the real CarPlay
    // bubble in Tweak.xm) and stops this screen's own layout from
    // re-centering it on every pass once moved.
    __weak typeof(self) weakSelf = self;
    _bubble.onUserAdjusted = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_bubbleWasAdjusted = YES;
        SplitCarPlaySetPref(@"bubbleScale", @(strongSelf->_bubble.scale));
    };

    // Left-edge half-capsule: shows/hides the speed card in this preview.
    // Added last so it stays tappable even when the card sits next to it.
    _edgeHandle = [UIButton buttonWithType:UIButtonTypeCustom];
    _edgeHandle.accessibilityLabel = @"Ẩn/hiện thẻ tốc độ";
    [_edgeHandle addTarget:self action:@selector(edgeHandleTapped) forControlEvents:UIControlEventTouchUpInside];
    _edgeVisual = [[UIView alloc] init];
    _edgeVisual.userInteractionEnabled = NO;
    _edgeVisual.backgroundColor = [UIColor whiteColor];
    _edgeVisual.layer.cornerRadius = 8;
    _edgeVisual.layer.maskedCorners = kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner;
    _edgeVisual.layer.borderWidth = SCPHairline();
    _edgeVisual.layer.borderColor = [UIColor colorWithWhite:0.80 alpha:1].CGColor;
    _edgeVisual.layer.shadowColor = [UIColor blackColor].CGColor;
    _edgeVisual.layer.shadowOpacity = 0.12;
    _edgeVisual.layer.shadowRadius = 3;
    _edgeVisual.layer.shadowOffset = CGSizeMake(1, 1);
    [_edgeHandle addSubview:_edgeVisual];
    _edgeChevron = [[UIImageView alloc] init];
    _edgeChevron.userInteractionEnabled = NO;
    _edgeChevron.contentMode = UIViewContentModeScaleAspectFit;
    _edgeChevron.tintColor = [UIColor colorWithWhite:0.35 alpha:1];
    [_edgeVisual addSubview:_edgeChevron];
    [self.view addSubview:_edgeHandle];
    [self updateEdgeChevron];

    [self refresh];
}

- (PreviewPaneView *)makePaneWithTag:(NSInteger)tag {
    PreviewPaneView *pane = [[PreviewPaneView alloc] initWithFrame:CGRectZero];
    pane.tag = tag;
    pane.tabControl.tag = tag;
    pane.reloadButton.tag = tag;
    pane.swapButton.tag = tag;
    pane.closeButton.tag = tag;
    [pane.tabControl addTarget:self action:@selector(paneTabTapped:) forControlEvents:UIControlEventTouchUpInside];
    [pane.reloadButton addTarget:self action:@selector(paneReloadTapped:) forControlEvents:UIControlEventTouchUpInside];
    [pane.swapButton addTarget:self action:@selector(paneSwapTapped:) forControlEvents:UIControlEventTouchUpInside];
    [pane.closeButton addTarget:self action:@selector(paneCloseTapped:) forControlEvents:UIControlEventTouchUpInside];

    // Tapping anywhere else in the pane also opens the picker (same as
    // before this restyle). The delegate lets taps on the pane's own
    // controls -- tab, circle buttons, recent-app tiles, "Tất cả app" --
    // reach those controls instead.
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(paneContentTapped:)];
    tap.delegate = self;
    [pane addGestureRecognizer:tap];
    [self.view addSubview:pane];
    return pane;
}

- (void)handleDividerPan:(UIPanGestureRecognizer *)gesture {
    CGFloat usableWidth = self.view.bounds.size.width - 32 - kSCPPaneGap;
    if (usableWidth <= 0) return;
    if (gesture.state == UIGestureRecognizerStateBegan) {
        _dragStartRatio = _splitRatio > 0 ? _splitRatio : 0.5;
    }
    CGFloat deltaRatio = [gesture translationInView:self.view].x / usableWidth;
    _splitRatio = MAX(0.2, MIN(0.8, _dragStartRatio + deltaRatio));
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
    BOOL ended = gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled;
    if ([self liveIsActive]) {
        // The real apps follow the panes (LivePreview.xm applyResizeFromApp).
        CGRect leftRect = [self liveContentRectOfPane:_leftPane];
        CGRect rightRect = [self liveContentRectOfPane:_rightPane];
        SCPPostLiveResize(leftRect.size.width, rightRect.origin.x, rightRect.size.width, ended);
    }
    if (ended) {
        // Persist only once the drag finishes -- matches the slider's
        // own behavior and avoids writing the plist on every pixel.
        SplitCarPlaySetPref(@"splitRatio", @(_splitRatio));
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.navigationController.navigationBarHidden = YES; // this tab only -- the big _headingLabel replaces it, matching the reference screenshots
    [self refresh]; // picked app / live Vietmap data may have changed since last time
    [_liveTimer invalidate];
    _liveTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(updateLiveUI) userInfo:nil repeats:YES];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    _visible = YES;
    [self scheduleAutoStart]; // the real apps open as soon as the tab is on screen
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    _visible = NO;
    _singleThisVisit = NO;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(autoStartLive) object:nil];
    [self stopLiveIfRunning]; // never leave hosted apps floating over another tab
    [_liveTimer invalidate];
    _liveTimer = nil;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    CGFloat side = 16;
    CGFloat contentW = bounds.size.width - side * 2;

    _headingLabel.frame = CGRectMake(side, self.view.safeAreaInsets.top + 8, contentW, 42);
    CGFloat paneTop = CGRectGetMaxY(_headingLabel.frame) + 14;

    // Car screen height ~0.95 x width, but never so tall that the
    // controls + caption below get pushed under the (floating) tab bar.
    CGFloat captionH = _captionLabel.text.length ? MIN(64, ceil([_captionLabel sizeThatFits:CGSizeMake(contentW, CGFLOAT_MAX)].height)) : 0;
    CGFloat controlsBlockH = (captionH > 0 ? 10 + captionH : 0) + 8;
    CGFloat maxCarH = bounds.size.height - self.view.safeAreaInsets.bottom - paneTop - controlsBlockH;
    CGFloat carH = floor(MIN(contentW * 0.95, maxCarH));
    carH = MAX(carH, 200);

    CGFloat usableWidth = contentW - kSCPPaneGap;
    CGFloat ratio = _splitRatio > 0 ? _splitRatio : 0.5;
    CGFloat leftWidth = floor(usableWidth * ratio);
    CGFloat rightWidth = usableWidth - leftWidth;
    _leftPane.frame = CGRectMake(side, paneTop, leftWidth, carH);
    _rightPane.frame = CGRectMake(CGRectGetMaxX(_leftPane.frame) + kSCPPaneGap, paneTop, rightWidth, carH);
    [_leftPane layoutIfNeeded];
    [_rightPane layoutIfNeeded];
    [self populateEmptyStateIfNeeded:_leftPane isLeft:YES];
    [self populateEmptyStateIfNeeded:_rightPane isLeft:NO];

    _carScreenFrame.frame = CGRectInset(CGRectUnion(_leftPane.frame, _rightPane.frame), -kSCPCarFramePad, -kSCPCarFramePad);
    _carScreenFrame.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:_carScreenFrame.bounds cornerRadius:16].CGPath;

    // Divider: 28x80 invisible hit area centered on the gap, white pill inside.
    CGFloat hitW = 28, hitH = 80;
    CGFloat boundaryX = CGRectGetMaxX(_leftPane.frame) + kSCPPaneGap / 2.0;
    _dividerHandle.frame = CGRectMake(boundaryX - hitW / 2.0, paneTop + floor((carH - hitH) / 2.0), hitW, hitH);
    _dividerPill.frame = CGRectMake((hitW - 10) / 2.0, (hitH - 56) / 2.0, 10, 56);
    _dividerPill.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:_dividerPill.bounds cornerRadius:5].CGPath;

    // Edge handle hugs the car frame's left edge, just under the title bars.
    CGFloat edgeVisualW = 14, edgeH = 84;
    _edgeHandle.frame = CGRectMake(CGRectGetMinX(_carScreenFrame.frame), paneTop + kSCPPaneBarHeight + 14, edgeVisualW + 10, edgeH);
    _edgeVisual.frame = CGRectMake(0, 0, edgeVisualW, edgeH);
    _edgeChevron.frame = CGRectMake(floor((edgeVisualW - 9) / 2.0), floor((edgeH - 12) / 2.0), 9, 12);

    CGFloat bubbleW = 96, bubbleH = 196;
    switch ((SplitCarPlayBubbleStyle)_styleControl.selectedSegmentIndex) {
        case SplitCarPlayBubbleStyleRing: bubbleW = bubbleH = 100; break;
        case SplitCarPlayBubbleStyleBar: bubbleW = 220; bubbleH = 44; break;
        default: break;
    }
    // Uses bounds+center, not .frame: the bubble carries a pinch-driven
    // scale transform, and -frame is undefined (per Apple's docs) once a
    // view's transform isn't the identity transform.
    _bubble.bounds = CGRectMake(0, 0, bubbleW, bubbleH);
    if (!_bubbleWasAdjusted) {
        BOOL bubbleOnLeft = _positionControl.selectedSegmentIndex == 0;
        CGFloat bubbleX = bubbleOnLeft ? CGRectGetMinX(_leftPane.frame) + 8
                                        : CGRectGetMaxX(_rightPane.frame) - bubbleW - 8;
        _bubble.center = CGPointMake(bubbleX + bubbleW / 2.0, paneTop + kSCPPaneBarHeight + 8 + bubbleH / 2.0);
    }

    _captionLabel.frame = CGRectMake(side, CGRectGetMaxY(_leftPane.frame) + 10, contentW, captionH);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    // Let a tap that lands on (or inside) one of the pane's own controls
    // handle itself instead of this whole-pane tap swallowing it first.
    for (UIView *view = touch.view; view && view != gestureRecognizer.view; view = view.superview) {
        if ([view isKindOfClass:[UIControl class]]) return NO;
    }
    return YES;
}

#pragma mark - Pane actions

- (void)paneTabTapped:(UIControl *)sender { [self showAppPickerForLeftSide:(sender.tag == 1)]; }

- (void)paneContentTapped:(UITapGestureRecognizer *)gesture { [self showAppPickerForLeftSide:(gesture.view.tag == 1)]; }

// Green: re-read the snapshot (e.g. after opening that app once).
- (void)paneReloadTapped:(UIButton *)sender { [self refresh]; }

// Yellow: swap the two panes' apps.
- (void)paneSwapTapped:(UIButton *)sender {
    NSDictionary *prefs = SCPCopyPrefs();
    NSString *leftID = SCPStringPref(prefs, @"leftBundleID");
    NSString *rightID = SCPStringPref(prefs, @"rightBundleID");
    SplitCarPlaySetPref(@"leftBundleID", rightID);
    SplitCarPlaySetPref(@"rightBundleID", leftID);
    [self refresh];
}

// Red: clear this pane back to "Tab mới".
- (void)paneCloseTapped:(UIButton *)sender {
    SplitCarPlaySetPref(sender.tag == 1 ? @"leftBundleID" : @"rightBundleID", @"");
    [self refresh];
}

- (void)edgeHandleTapped {
    _bubbleHiddenLocally = !_bubbleHiddenLocally;
    _bubble.hidden = _bubbleHiddenLocally || [self liveIsActive]; // SpringBoard draws it while live
    [self updateEdgeChevron];
}

// "›" = pull the card out (currently hidden), "‹" = tuck it away.
- (void)updateEdgeChevron {
    NSString *name = _bubbleHiddenLocally ? @"chevron.right" : @"chevron.left";
    _edgeChevron.image = [SCPSymbol(name, 10, YES) imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

- (void)showAppPickerForLeftSide:(BOOL)isLeft {
    [AppPickerController presentFrom:self
                                title:isLeft ? @"Chọn app ô 1" : @"Chọn app ô 2"
                               onPick:^(NSString *bundleID) {
        SplitCarPlaySetPref(isLeft ? @"leftBundleID" : @"rightBundleID", bundleID);
        [self refresh];
    }];
}

#pragma mark - "Tab mới" empty state

- (void)populateEmptyStateIfNeeded:(PreviewPaneView *)pane isLeft:(BOOL)isLeft {
    if (!pane.isEmpty) return;
    UIView *emptyState = pane.emptyState;
    CGSize size = emptyState.bounds.size;
    if (size.width <= 0 || size.height <= 0) return;
    if (CGSizeEqualToSize(pane.emptyStateBuiltSize, size)) return;
    pane.emptyStateBuiltSize = size;

    for (UIView *subview in [emptyState.subviews copy]) [subview removeFromSuperview];

    CGFloat w = size.width, h = size.height;
    CGFloat tile = 52, gap = 10, sidePad = 12;
    NSInteger fit = (NSInteger)floor((w - sidePad * 2 + gap) / (tile + gap));
    NSInteger count = MIN((NSInteger)_recentIDs.count, MAX((NSInteger)0, fit));
    CGFloat blockH = (count > 0 ? (16 + 8 + tile + 4 + 13 + 18) : 0) + 20;
    CGFloat y = MAX(12, floor((h - blockH) * 0.38)); // upper-middle, like the reference

    if (count > 0) {
        CGFloat groupW = count * tile + (count - 1) * gap;
        CGFloat x0 = floor((w - groupW) / 2.0);

        UILabel *header = [[UILabel alloc] initWithFrame:CGRectMake(x0, y, MAX(0, w - x0 - sidePad), 16)];
        header.text = @"Gần đây";
        header.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        header.textColor = [UIColor colorWithWhite:0.25 alpha:1];
        [emptyState addSubview:header];
        y += 24;

        for (NSInteger i = 0; i < count; i++) {
            NSString *bundleID = _recentIDs[i];
            CGFloat x = x0 + i * (tile + gap);
            UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
            button.frame = CGRectMake(x, y, tile, tile);
            button.backgroundColor = [UIColor colorWithWhite:0.93 alpha:1];
            button.layer.cornerRadius = 12;
            button.accessibilityIdentifier = bundleID;
            button.accessibilityLabel = _recentNames[bundleID];
            button.tag = isLeft ? 1 : 2;
            [button addTarget:self action:@selector(emptyStateRecentTapped:) forControlEvents:UIControlEventTouchUpInside];

            CGFloat iconSize = 42;
            UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectMake((tile - iconSize) / 2.0, (tile - iconSize) / 2.0, iconSize, iconSize)];
            icon.image = _recentIcons[bundleID];
            icon.contentMode = UIViewContentModeScaleAspectFit;
            icon.layer.cornerRadius = 10;
            icon.layer.masksToBounds = YES;
            icon.userInteractionEnabled = NO;
            [button addSubview:icon];
            [emptyState addSubview:button];

            UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(x - 4, y + tile + 4, tile + 8, 13)];
            label.text = _recentNames[bundleID] ?: bundleID;
            label.font = [UIFont systemFontOfSize:10];
            label.textColor = [UIColor colorWithWhite:0.3 alpha:1];
            label.textAlignment = NSTextAlignmentCenter;
            label.lineBreakMode = NSLineBreakByTruncatingTail;
            [emptyState addSubview:label];
        }
        y += tile + 4 + 13 + 18;
    }

    UIButton *allAppsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [allAppsButton setTitle:@"Tất cả app ›" forState:UIControlStateNormal];
    allAppsButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    allAppsButton.titleLabel.adjustsFontSizeToFitWidth = YES;
    allAppsButton.titleLabel.minimumScaleFactor = 0.7;
    allAppsButton.tintColor = [UIColor systemBlueColor];
    allAppsButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    allAppsButton.frame = CGRectMake(6, y, MAX(0, w - 12), 22);
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

#pragma mark - Refresh

- (void)configurePane:(PreviewPaneView *)pane bundleID:(NSString *)bundleID names:(NSDictionary *)names icons:(NSDictionary *)icons {
    BOOL empty = bundleID.length == 0;
    if (empty) {
        [pane showEmpty];
    } else {
        // Prefer a real cached app-switcher snapshot (looks like the actual
        // app) over the icon tile -- see this file's header comment. Either
        // can be nil (app never backgrounded yet, wrong path guess, decode
        // failure) with no crash either way.
        [pane showAppNamed:(names[bundleID] ?: bundleID)
                      icon:icons[bundleID]
                  snapshot:SplitCarPlayAppSnapshot(bundleID)];
    }

    UIColor *offFill = [UIColor colorWithWhite:0.85 alpha:1];
    UIColor *offGlyph = [UIColor colorWithWhite:0.62 alpha:1];
    UIColor *greenFill = [UIColor colorWithRed:0.30 green:0.80 blue:0.40 alpha:1];
    UIColor *greenGlyph = [UIColor colorWithRed:0.05 green:0.40 blue:0.14 alpha:1];
    UIColor *yellowFill = [UIColor colorWithRed:1.00 green:0.78 blue:0.20 alpha:1];
    UIColor *yellowGlyph = [UIColor colorWithRed:0.55 green:0.36 blue:0.00 alpha:1];
    UIColor *redFill = [UIColor colorWithRed:1.00 green:0.38 blue:0.36 alpha:1];
    UIColor *redGlyph = [UIColor colorWithRed:0.55 green:0.06 blue:0.06 alpha:1];
    SCPStyleCircleButton(pane.reloadButton, empty ? offFill : greenFill, empty ? offGlyph : greenGlyph, !empty);
    SCPStyleCircleButton(pane.swapButton, yellowFill, yellowGlyph, YES);
    SCPStyleCircleButton(pane.closeButton, empty ? offFill : redFill, empty ? offGlyph : redGlyph, !empty);
    pane.emptyStateBuiltSize = CGSizeZero; // recents may have changed -- rebuild on next layout
}

- (void)refresh {
    [self stopLiveIfRunning]; // the picked apps or panes may be changing
    NSDictionary *prefs = SCPCopyPrefs();
    NSString *leftID = SCPStringPref(prefs, @"leftBundleID");
    NSString *rightID = SCPStringPref(prefs, @"rightBundleID");

    // One name/icon lookup per distinct app, shared by both panes and the
    // "Gần đây" rows.
    NSArray<NSString *> *recent = SplitCarPlayRecentBundleIDs();
    NSMutableArray<NSString *> *needed = [NSMutableArray new];
    for (NSString *bundleID in [@[leftID, rightID] arrayByAddingObjectsFromArray:recent]) {
        if (bundleID.length > 0 && ![needed containsObject:bundleID]) [needed addObject:bundleID];
    }
    NSMutableDictionary<NSString *, NSString *> *names = [NSMutableDictionary new];
    NSMutableDictionary<NSString *, UIImage *> *icons = [NSMutableDictionary new];
    for (NSString *bundleID in needed) {
        names[bundleID] = SplitCarPlayDisplayNameForBundleID(bundleID) ?: bundleID;
        UIImage *icon = SplitCarPlayAppIcon(bundleID);
        if (icon) icons[bundleID] = icon;
    }
    _recentIDs = recent;
    _recentNames = names;
    _recentIcons = icons;

    [self configurePane:_leftPane bundleID:leftID names:names icons:icons];
    [self configurePane:_rightPane bundleID:rightID names:names icons:icons];

    // Match Tweak.xm's loadPreferences defaults for anything the user
    // hasn't touched yet in "Trên xe".
    _bubble.style = (SplitCarPlayBubbleStyle)[prefs[@"bubbleStyle"] integerValue];
    _bubble.showDate = prefs[@"showDate"] ? [prefs[@"showDate"] boolValue] : YES;
    _bubble.showBattery = prefs[@"showBattery"] ? [prefs[@"showBattery"] boolValue] : YES;
    _bubble.scale = prefs[@"bubbleScale"] ? [prefs[@"bubbleScale"] doubleValue] : 1.0;
    _positionControl.selectedSegmentIndex = prefs[@"bubblePosition"] ? [prefs[@"bubblePosition"] integerValue] : 1;
    _styleControl.selectedSegmentIndex = [prefs[@"bubbleStyle"] integerValue]; // may have changed in "Trên xe"
    _splitRatio = prefs[@"splitRatio"] ? [prefs[@"splitRatio"] doubleValue] : 0.5;

    // Set by SpringBoard when it restarted in the middle of "Chạy thật"
    // (LivePreview.xm %ctor). Shown once.
    NSInteger crashNotice = [prefs[@"livePreviewCrashNotice"] integerValue];
    if (crashNotice) {
        SplitCarPlaySetPref(@"livePreviewCrashNotice", @0);
        if (crashNotice == 2) _singleThisVisit = YES;
        _captionLabel.text = crashNotice == 2
            ? @"Lần trước chạy 2 app làm SpringBoard bị lỗi (máy vào safe mode), nên lần này chỉ chạy app ô 1. Gửi file /var/mobile/Library/Logs/splitcarplay_hosting.log để sửa."
            : @"Lần trước chạy app thật làm SpringBoard bị lỗi. Gửi file /var/mobile/Library/Logs/splitcarplay_hosting.log để sửa.";
    }

    // Newer of the shared file and the notify-state copy (the file may be
    // blocked by Vietmap Live's sandbox) -- same rule as Tweak.xm.
    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:kVietmapSharedStatePath];
    NSDictionary *notifyState = SCPReadSpeedState();
    if ([notifyState[@"timestamp"] doubleValue] > [state[@"timestamp"] doubleValue]) state = notifyState;
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
    [self scheduleAutoStart]; // (re)open the real apps for the current picks
}

#pragma mark - "Chạy thật" (LivePreview.xm in SpringBoard)

- (BOOL)liveIsActive {
    uint64_t state = SCPGetLiveState();
    return state == SCPLiveStateStarting || state == SCPLiveStateRunning;
}

- (void)stopLiveIfRunning {
    if ([self liveIsActive]) notify_post(SCP_LIVE_STOP_NOTIFICATION);
}

- (void)appDidEnterBackground {
    [self stopLiveIfRunning];
}

// A pane's content area (below its title bar) in screen points. This app
// is full screen, so window coordinates are screen coordinates.
- (CGRect)liveContentRectOfPane:(UIView *)pane {
    CGRect rect = CGRectMake(0, kSCPPaneBarHeight, pane.bounds.size.width, pane.bounds.size.height - kSCPPaneBarHeight);
    return [pane convertRect:rect toView:nil];
}

// Debounced: refresh can run several times in a row (appear, pick, swap).
- (void)scheduleAutoStart {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(autoStartLive) object:nil];
    _autoStartPending = YES;
    [self performSelector:@selector(autoStartLive) withObject:nil afterDelay:0.4];
}

// Opens the picked apps for real: ô 1 always, ô 2 too when it has a
// different app. Nothing to do without an app in ô 1 (the pane shows its
// picker). ✕ stops it until the next refresh (↻, a new pick, or coming
// back to this tab).
- (void)autoStartLive {
    _autoStartPending = NO;
    if (!_visible || !self.view.window) return;
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;
    if ([self liveIsActive]) return;
    NSDictionary *prefs = SCPCopyPrefs();
    NSString *leftID = SCPStringPref(prefs, @"leftBundleID");
    NSString *rightID = SCPStringPref(prefs, @"rightBundleID");
    if (leftID.length == 0) return;
    BOOL both = rightID.length > 0 && ![rightID isEqualToString:leftID] && !_singleThisVisit;
    // Content area of each pane (below its title bar), in screen points.
    // This app is full screen, so window coordinates are screen coordinates.
    [self.view layoutIfNeeded];
    SCPSetPref(@"livePreviewLeftFrame", NSStringFromCGRect([self liveContentRectOfPane:_leftPane]));
    SCPSetPref(@"livePreviewRightFrame", NSStringFromCGRect([self liveContentRectOfPane:_rightPane]));
    SCPSetPref(@"livePreviewBoth", @(both));
    // The app's bubble ends up under the hosted apps, so SpringBoard draws
    // its own on top, at this bubble's screen position and size.
    // Same for the left-edge show/hide handle, which the hosted apps cover.
    BOOL showBubble = prefs[@"showSpeedBubble"] ? [prefs[@"showSpeedBubble"] boolValue] : YES;
    SCPSetPref(@"livePreviewBubble", @(showBubble));
    SCPSetPref(@"livePreviewBubbleHidden", @(_bubbleHiddenLocally));
    SCPSetPref(@"livePreviewEdgeFrame", NSStringFromCGRect([self.view convertRect:_edgeHandle.frame toView:nil]));
    SCPSetPref(@"livePreviewBubbleCenter", NSStringFromCGPoint([self.view convertPoint:_bubble.center toView:nil]));
    SCPSetPref(@"livePreviewBubbleWidth", @(_bubble.bounds.size.width * _bubble.scale));
    SCPSetPref(@"livePreviewBubbleBaseWidth", @(_bubble.bounds.size.width));
    SCPSetLiveState(SCPLiveStateStarting); // SpringBoard overwrites this; shows feedback right away
    notify_post(SCP_LIVE_START_NOTIFICATION);
    [self updateLiveUI];
}

- (void)updateLiveUI {
    uint64_t state = SCPGetLiveState();
    BOOL live = state == SCPLiveStateStarting || state == SCPLiveStateRunning;
    _bubble.hidden = _bubbleHiddenLocally || live; // SpringBoard draws it on top while live
    if (state == _shownLiveState) return;
    BOOL wasLive = _shownLiveState == SCPLiveStateStarting || _shownLiveState == SCPLiveStateRunning;
    _shownLiveState = state;
    if (wasLive && !live) [self restoreBubbleFromLive];
    switch (state) {
        case SCPLiveStateStarting:
            _captionLabel.text = nil;
            break;
        case SCPLiveStateRunning:
            _captionLabel.text = nil;
            break;
        case SCPLiveStateFailed:
            _captionLabel.text = @"App thật không mở được hoặc đã bị iOS đóng (thường do thiếu RAM khi chạy 2 app). Gửi file /var/mobile/Library/Logs/splitcarplay_hosting.log để sửa.";
            break;
        default:
            // Closed with ✕ while on screen: say how to get it back.
            _captionLabel.text = (wasLive && _visible && !_autoStartPending) ? @"Đã tắt app thật. Bấm nút ↻ xanh ở khung để mở lại." : nil;
            break;
    }
    [self.view setNeedsLayout];
}

// SpringBoard writes back where its bubble was dragged or pinched to
// (LivePreview.xm stop). Move this screen's bubble there.
- (void)restoreBubbleFromLive {
    NSDictionary *prefs = SCPCopyPrefs();
    NSString *centerString = prefs[@"livePreviewBubbleCenter"];
    if (centerString.length) {
        _bubble.center = [self.view convertPoint:CGPointFromString(centerString) fromView:nil];
        _bubbleWasAdjusted = YES; // keep it there instead of re-homing on layout
    }
    if (prefs[@"bubbleScale"]) _bubble.scale = [prefs[@"bubbleScale"] doubleValue];
    // Shown/hidden with SpringBoard's copy of the edge handle while live.
    if (prefs[@"livePreviewBubbleHidden"]) {
        _bubbleHiddenLocally = [prefs[@"livePreviewBubbleHidden"] boolValue];
        _bubble.hidden = _bubbleHiddenLocally;
        [self updateEdgeChevron];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_liveTimer invalidate];
}

@end
