//
//  AppPickerController.m
//
//  Shared across this app's tabs (OnCarViewController, PreviewViewController
//  -- same binary, so this one copy is genuinely reused, unlike the
//  Prefs.bundle/Tweak.xm split elsewhere in this project where each
//  process needs its own copy). Grid-style "Chọn app..." picker,
//  presented modally -- same visual idea as the in-place card version
//  built for Settings' Preview screen, just as a real presented
//  UIViewController now that there's no Settings-navigation constraint
//  to work around.
//
#import <UIKit/UIKit.h>
#import "../SplitCarPlayShared.h"
#import <objc/runtime.h>

#pragma mark - Private API (LaunchServices) -- real, widely used by app-picker tweaks

@interface LSApplicationProxy : NSObject
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray<LSApplicationProxy *> *)allInstalledApplications;
@end

static LSApplicationWorkspace *SplitCarPlayWorkspace(void) {
    Class workspaceClass = objc_getClass("LSApplicationWorkspace");
    if (!workspaceClass || ![workspaceClass respondsToSelector:@selector(defaultWorkspace)]) return nil;
    return [workspaceClass defaultWorkspace];
}

static NSString *SplitCarPlayAppBundleID(LSApplicationProxy *app) {
    if ([app respondsToSelector:@selector(bundleIdentifier)]) {
        return [app performSelector:@selector(bundleIdentifier)];
    }
    return nil;
}

static NSString *SplitCarPlayAppDisplayName(LSApplicationProxy *app) {
    SEL candidates[] = { @selector(localizedName), @selector(displayName), @selector(bundleName) };
    for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
        if ([app respondsToSelector:candidates[i]]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            NSString *name = [app performSelector:candidates[i]];
#pragma clang diagnostic pop
            if (name.length > 0) return name;
        }
    }
    return SplitCarPlayAppBundleID(app);
}

static BOOL SplitCarPlayAppLooksUserInstalled(LSApplicationProxy *app) {
    if (![app respondsToSelector:@selector(applicationType)]) return YES;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    NSString *type = [app performSelector:@selector(applicationType)];
#pragma clang diagnostic pop
    return [type isEqualToString:@"User"];
}

// bundle ID -> display name for every installed app, built in one pass and
// kept for 60 s (it used to walk every installed app on each lookup, i.e.
// once per table cell).
static NSDictionary<NSString *, NSString *> *SplitCarPlayAllDisplayNames(void) {
    static NSDictionary *names;
    static CFAbsoluteTime builtAt = 0;
    if (names && CFAbsoluteTimeGetCurrent() - builtAt < 60) return names;
    NSMutableDictionary *map = [NSMutableDictionary new];
    LSApplicationWorkspace *workspace = SplitCarPlayWorkspace();
    if ([workspace respondsToSelector:@selector(allInstalledApplications)]) {
        for (LSApplicationProxy *app in [workspace allInstalledApplications]) {
            NSString *bundleID = SplitCarPlayAppBundleID(app);
            if (bundleID.length) map[bundleID] = SplitCarPlayAppDisplayName(app) ?: bundleID;
        }
    }
    names = map;
    builtAt = CFAbsoluteTimeGetCurrent();
    return names;
}

NSString *SplitCarPlayDisplayNameForBundleID(NSString *bundleID) {
    if (bundleID.length == 0) return nil;
    return SplitCarPlayAllDisplayNames()[bundleID] ?: bundleID;
}

static UIImage *SplitCarPlayAppIconUncached(NSString *bundleID);

UIImage *SplitCarPlayAppIcon(NSString *bundleID) {
    if (bundleID.length == 0) return nil;
    static NSCache<NSString *, UIImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });
    UIImage *icon = [cache objectForKey:bundleID];
    if (!icon) {
        icon = SplitCarPlayAppIconUncached(bundleID);
        if (icon) [cache setObject:icon forKey:bundleID];
    }
    return icon;
}

static UIImage *SplitCarPlayAppIconUncached(NSString *bundleID) {
    SEL sel = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if (![UIImage respondsToSelector:sel]) return nil;

    NSMethodSignature *signature = [UIImage methodSignatureForSelector:sel];
    if (!signature) return nil;
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.selector = sel;
    NSInteger format = 0;
    CGFloat scale = [UIScreen mainScreen].scale;
    [invocation setArgument:&bundleID atIndex:2];
    [invocation setArgument:&format atIndex:3];
    [invocation setArgument:&scale atIndex:4];
    [invocation invokeWithTarget:[UIImage class]];

    __unsafe_unretained UIImage *result = nil;
    [invocation getReturnValue:&result];
    return result;
}

NSArray<NSString *> *SplitCarPlayUserInstalledBundleIDsSorted(void) {
    LSApplicationWorkspace *workspace = SplitCarPlayWorkspace();
    NSArray<LSApplicationProxy *> *all = @[];
    if ([workspace respondsToSelector:@selector(allInstalledApplications)]) {
        all = [workspace allInstalledApplications] ?: @[];
    }
    NSMutableArray<LSApplicationProxy *> *validApps = [NSMutableArray new];
    for (LSApplicationProxy *app in all) {
        if (SplitCarPlayAppBundleID(app).length > 0 && SplitCarPlayAppLooksUserInstalled(app)) {
            [validApps addObject:app];
        }
    }
    [validApps sortUsingComparator:^NSComparisonResult(LSApplicationProxy *a, LSApplicationProxy *b) {
        return [SplitCarPlayAppDisplayName(a) caseInsensitiveCompare:SplitCarPlayAppDisplayName(b)];
    }];
    NSMutableArray<NSString *> *ids = [NSMutableArray new];
    for (LSApplicationProxy *app in validApps) [ids addObject:SplitCarPlayAppBundleID(app)];
    return ids;
}

#pragma mark - Shared prefs path (same contract SplitCarPlay.dylib/Prefs.bundle read/write)

void SplitCarPlaySetPref(NSString *key, id value) {
    SCPSetPref(key, value); // CFPreferences, see ../SplitCarPlayShared.h
    SCPPostReload();
}

// "Recent" is a simplification used throughout this project: just the two
// currently-picked apps (deduplicated), not a persisted history.
NSArray<NSString *> *SplitCarPlayRecentBundleIDs(void) {
    NSDictionary *prefs = SCPCopyPrefs();
    NSMutableArray<NSString *> *recent = [NSMutableArray new];
    for (NSString *bundleID in @[ prefs[@"leftBundleID"] ?: @"", prefs[@"rightBundleID"] ?: @"" ]) {
        if (bundleID.length > 0 && ![recent containsObject:bundleID]) [recent addObject:bundleID];
    }
    return recent;
}

#pragma mark - Grid picker (modal)

// Presented over the current screen as a floating white card (faint dim
// behind it) rather than a full-screen sheet -- matches the reference
// "Chọn app ô 1/2" screenshots. Tap the dim area or ✕ to dismiss.
//
// Motion: UIKit's cross-dissolve fades the backdrop and card in/out; on
// top of that the card scales 0.94 -> 1 and slides up a little (skipped
// with Reduce Motion, which leaves the plain fade).

static inline BOOL SCPPickerReduceMotion(void) {
    return UIAccessibilityIsReduceMotionEnabled();
}

static CGAffineTransform SCPPickerCardOffTransform(void) {
    return CGAffineTransformScale(CGAffineTransformMakeTranslation(0, 16), 0.94, 0.94);
}

static const NSInteger kSCPPickerIconTag = 201;

@interface AppPickerController : UIViewController
@property (nonatomic, copy) void (^onPick)(NSString *bundleID);
@property (nonatomic, copy) NSString *pickerTitle;
+ (void)presentFrom:(UIViewController *)presenter title:(NSString *)title onPick:(void (^)(NSString *bundleID))onPick;
@end

@implementation AppPickerController {
    UIView *_backdrop;
    UIView *_card;
    UILabel *_titleLabel;
    UIButton *_closeButton;
    UIScrollView *_scroll;
    CGFloat _gridWidth; // width the grid was last built for; rebuilt only when it changes
    UISelectionFeedbackGenerator *_selectionHaptic;
}

+ (void)presentFrom:(UIViewController *)presenter title:(NSString *)title onPick:(void (^)(NSString *bundleID))onPick {
    AppPickerController *picker = [[AppPickerController alloc] init];
    picker.pickerTitle = title;
    picker.onPick = onPick;
    picker.modalPresentationStyle = UIModalPresentationOverFullScreen;
    picker.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    [presenter presentViewController:picker animated:YES completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    CGFloat hairline = 1.0 / MAX(1.0, [UIScreen mainScreen].scale);

    // Separate backdrop view (behind the card) owns the dismiss tap, so
    // taps on the card never need to be filtered out.
    _backdrop = [[UIView alloc] init];
    _backdrop.backgroundColor = [UIColor colorWithWhite:0 alpha:0.25];
    [_backdrop addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(close)]];
    [self.view addSubview:_backdrop];

    // No masksToBounds so the soft shadow shows; the scroll view inside
    // is inset from the rounded corners and clips its own content.
    _card = [[UIView alloc] init];
    _card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor]; // follows light/dark
    _card.layer.cornerRadius = 16;
    _card.layer.borderWidth = hairline;
    _card.layer.borderColor = [UIColor separatorColor].CGColor;
    _card.layer.shadowColor = [UIColor blackColor].CGColor;
    _card.layer.shadowOpacity = 0.14;
    _card.layer.shadowRadius = 18;
    _card.layer.shadowOffset = CGSizeMake(0, 6);
    [self.view addSubview:_card];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.text = self.pickerTitle;
    _titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _titleLabel.textColor = [UIColor labelColor];
    [_card addSubview:_titleLabel];

    _closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImage *xmark = nil;
    if (@available(iOS 13.0, *)) {
        xmark = [UIImage systemImageNamed:@"xmark"
                        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold]];
    }
    if (xmark) {
        [_closeButton setImage:xmark forState:UIControlStateNormal];
    } else {
        [_closeButton setTitle:@"✕" forState:UIControlStateNormal];
    }
    _closeButton.tintColor = [UIColor secondaryLabelColor];
    _closeButton.accessibilityLabel = @"Đóng";
    [_closeButton addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:_closeButton];

    _scroll = [[UIScrollView alloc] init];
    _scroll.alwaysBounceVertical = YES;
    _scroll.clipsToBounds = YES;
    [_card addSubview:_scroll];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    _backdrop.frame = bounds;

    CGFloat top = self.view.safeAreaInsets.top + 70;
    CGFloat height = MIN(bounds.size.height * 0.60, bounds.size.height - top - self.view.safeAreaInsets.bottom - 16);
    height = MAX(height, 200);
    CGRect cardFrame = CGRectMake(16, top, bounds.size.width - 32, height);
    // bounds + center, not frame: the card carries a transform while it
    // animates in/out, and -frame is undefined then.
    _card.bounds = CGRectMake(0, 0, cardFrame.size.width, cardFrame.size.height);
    _card.center = CGPointMake(CGRectGetMidX(cardFrame), CGRectGetMidY(cardFrame));
    _card.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:_card.bounds cornerRadius:16].CGPath;

    _titleLabel.frame = CGRectMake(18, 14, cardFrame.size.width - 18 - 52, 24);
    _closeButton.frame = CGRectMake(cardFrame.size.width - 50, 4, 44, 44); // 44pt touch target

    // Stops 10pt short of the card's bottom so its square corners stay
    // inside the card's rounded ones.
    _scroll.frame = CGRectMake(0, 50, cardFrame.size.width, MAX(0, cardFrame.size.height - 50 - 10));

    if (_scroll.bounds.size.width > 0 && _scroll.bounds.size.width != _gridWidth) {
        _gridWidth = _scroll.bounds.size.width;
        [self populateGrid];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (!animated || SCPPickerReduceMotion()) return;
    // Runs next to UIKit's cross-dissolve (which fades backdrop + card).
    _card.transform = SCPPickerCardOffTransform();
    UIView *card = _card;
    [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0
                        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ card.transform = CGAffineTransformIdentity; }
                     completion:nil];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    id<UIViewControllerTransitionCoordinator> coordinator = self.transitionCoordinator;
    if (!animated || !coordinator || SCPPickerReduceMotion()) return;
    UIView *card = _card;
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        card.transform = SCPPickerCardOffTransform();
    } completion:nil];
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    _card.layer.borderColor = [UIColor separatorColor].CGColor;
}

- (void)populateGrid {
    for (UIView *subview in [_scroll.subviews copy]) {
        if ([subview isKindOfClass:[UIButton class]] || [subview isKindOfClass:[UILabel class]]) [subview removeFromSuperview];
    }

    CGFloat y = 4;
    NSArray<NSString *> *recent = SplitCarPlayRecentBundleIDs();
    if (recent.count > 0) {
        y = [self addSection:@"GẦN ĐÂY" bundleIDs:recent startY:y];
    }
    y = [self addSection:@"TẤT CẢ" bundleIDs:SplitCarPlayUserInstalledBundleIDsSorted() startY:y];
    _scroll.contentSize = CGSizeMake(_scroll.bounds.size.width, y + 8);
}

- (CGFloat)addSection:(NSString *)title bundleIDs:(NSArray<NSString *> *)bundleIDs startY:(CGFloat)y {
    // ~5 columns on a 375pt-wide phone (343pt card).
    CGFloat sidePad = 14, iconSize = 56, labelH = 16, rowGap = 12; // 16: room for Vietnamese stacked marks
    CGFloat contentW = MAX(1, _scroll.bounds.size.width - sidePad * 2);
    NSInteger columns = MAX((NSInteger)1, (NSInteger)floor(contentW / 62.0));
    CGFloat itemWidth = floor(contentW / columns);
    CGFloat itemHeight = iconSize + 4 + labelH;

    UILabel *header = [[UILabel alloc] initWithFrame:CGRectMake(sidePad + floor((itemWidth - iconSize) / 2.0), y,
                                                                _scroll.bounds.size.width - sidePad * 2, 18)];
    header.attributedText = [[NSAttributedString alloc] initWithString:title attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: [UIColor secondaryLabelColor],
        NSKernAttributeName: @1.2,
    }];
    [_scroll addSubview:header];
    y += 26;

    NSInteger col = 0;
    CGFloat rowY = y;
    for (NSString *bundleID in bundleIDs) {
        CGFloat x = sidePad + col * itemWidth;
        NSString *name = SplitCarPlayDisplayNameForBundleID(bundleID);
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.frame = CGRectMake(x, rowY, itemWidth, itemHeight);
        button.accessibilityIdentifier = bundleID;
        button.accessibilityLabel = name;
        [button addTarget:self action:@selector(appTapped:) forControlEvents:UIControlEventTouchUpInside];
        [button addTarget:self action:@selector(appPressDown:) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
        [button addTarget:self action:@selector(appPressUp:)
         forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchDragExit | UIControlEventTouchCancel];

        UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectMake(floor((itemWidth - iconSize) / 2.0), 0, iconSize, iconSize)];
        icon.tag = kSCPPickerIconTag;
        icon.image = SplitCarPlayAppIcon(bundleID);
        icon.contentMode = UIViewContentModeScaleAspectFit;
        icon.layer.cornerRadius = 13;
        icon.layer.masksToBounds = YES;
        icon.userInteractionEnabled = NO;
        [button addSubview:icon];

        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(1, iconSize + 4, itemWidth - 2, labelH)];
        label.text = name;
        label.font = [UIFont systemFontOfSize:11];
        label.textColor = [UIColor labelColor];
        label.textAlignment = NSTextAlignmentCenter;
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        label.userInteractionEnabled = NO;
        [button addSubview:label];

        [_scroll addSubview:button];

        col++;
        if (col >= columns) {
            col = 0;
            rowY += itemHeight + rowGap;
        }
    }
    if (col != 0) rowY += itemHeight + rowGap;
    return rowY + 6;
}

// Icon press-down: shrinks to 0.92 while the finger is on it, springs back
// on release/cancel. The icon's frame is set once when the grid is built,
// so a transform on it is safe.
- (void)setIconOf:(UIButton *)button pressed:(BOOL)pressed {
    UIView *icon = [button viewWithTag:kSCPPickerIconTag];
    if (!icon) return;
    CGAffineTransform target = (pressed && !SCPPickerReduceMotion()) ? CGAffineTransformMakeScale(0.92, 0.92) : CGAffineTransformIdentity;
    [UIView animateWithDuration:(pressed ? 0.15 : 0.3) delay:0 usingSpringWithDamping:(pressed ? 0.9 : 0.75) initialSpringVelocity:0
                        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ icon.transform = target; }
                     completion:nil];
}

- (void)appPressDown:(UIButton *)sender {
    [self setIconOf:sender pressed:YES];
    if (!_selectionHaptic) _selectionHaptic = [[UISelectionFeedbackGenerator alloc] init];
    [_selectionHaptic prepare];
}

- (void)appPressUp:(UIButton *)sender {
    [self setIconOf:sender pressed:NO];
}

- (void)appTapped:(UIButton *)sender {
    NSString *bundleID = sender.accessibilityIdentifier;
    if (bundleID.length == 0) return;
    if (!_selectionHaptic) _selectionHaptic = [[UISelectionFeedbackGenerator alloc] init];
    [_selectionHaptic selectionChanged];
    if (self.onPick) self.onPick(bundleID);
    [self close];
}

@end
