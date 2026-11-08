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

NSString *SplitCarPlayDisplayNameForBundleID(NSString *bundleID) {
    if (bundleID.length == 0) return nil;
    LSApplicationWorkspace *workspace = SplitCarPlayWorkspace();
    if (![workspace respondsToSelector:@selector(allInstalledApplications)]) return bundleID;
    for (LSApplicationProxy *app in [workspace allInstalledApplications]) {
        if ([SplitCarPlayAppBundleID(app) isEqualToString:bundleID]) {
            return SplitCarPlayAppDisplayName(app);
        }
    }
    return bundleID;
}

UIImage *SplitCarPlayAppIcon(NSString *bundleID) {
    if (bundleID.length == 0) return nil;
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
    _backdrop.backgroundColor = [UIColor colorWithWhite:0 alpha:0.12];
    [_backdrop addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(close)]];
    [self.view addSubview:_backdrop];

    // No masksToBounds so the soft shadow shows; the scroll view inside
    // is inset from the rounded corners and clips its own content.
    _card = [[UIView alloc] init];
    _card.backgroundColor = [UIColor whiteColor];
    _card.layer.cornerRadius = 16;
    _card.layer.borderWidth = hairline;
    _card.layer.borderColor = [UIColor colorWithWhite:0.84 alpha:1].CGColor;
    _card.layer.shadowColor = [UIColor blackColor].CGColor;
    _card.layer.shadowOpacity = 0.14;
    _card.layer.shadowRadius = 18;
    _card.layer.shadowOffset = CGSizeMake(0, 6);
    [self.view addSubview:_card];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.text = self.pickerTitle;
    _titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _titleLabel.textColor = [UIColor colorWithWhite:0.1 alpha:1];
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
    _closeButton.tintColor = [UIColor colorWithWhite:0.45 alpha:1];
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
    _card.frame = cardFrame;
    _card.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:_card.bounds cornerRadius:16].CGPath;

    _titleLabel.frame = CGRectMake(18, 14, cardFrame.size.width - 18 - 52, 24);
    _closeButton.frame = CGRectMake(cardFrame.size.width - 46, 8, 36, 36);

    // Stops 10pt short of the card's bottom so its square corners stay
    // inside the card's rounded ones.
    _scroll.frame = CGRectMake(0, 50, cardFrame.size.width, MAX(0, cardFrame.size.height - 50 - 10));

    if (_scroll.bounds.size.width > 0 && _scroll.bounds.size.width != _gridWidth) {
        _gridWidth = _scroll.bounds.size.width;
        [self populateGrid];
    }
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
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
    CGFloat sidePad = 14, iconSize = 56, labelH = 14, rowGap = 12;
    CGFloat contentW = MAX(1, _scroll.bounds.size.width - sidePad * 2);
    NSInteger columns = MAX((NSInteger)1, (NSInteger)floor(contentW / 62.0));
    CGFloat itemWidth = floor(contentW / columns);
    CGFloat itemHeight = iconSize + 4 + labelH;

    UILabel *header = [[UILabel alloc] initWithFrame:CGRectMake(sidePad + floor((itemWidth - iconSize) / 2.0), y,
                                                                _scroll.bounds.size.width - sidePad * 2, 18)];
    header.attributedText = [[NSAttributedString alloc] initWithString:title attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: [UIColor colorWithWhite:0.55 alpha:1],
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

        UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectMake(floor((itemWidth - iconSize) / 2.0), 0, iconSize, iconSize)];
        icon.image = SplitCarPlayAppIcon(bundleID);
        icon.contentMode = UIViewContentModeScaleAspectFit;
        icon.layer.cornerRadius = 13;
        icon.layer.masksToBounds = YES;
        icon.userInteractionEnabled = NO;
        [button addSubview:icon];

        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(1, iconSize + 4, itemWidth - 2, labelH)];
        label.text = name;
        label.font = [UIFont systemFontOfSize:11];
        label.textColor = [UIColor colorWithWhite:0.2 alpha:1];
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

- (void)appTapped:(UIButton *)sender {
    NSString *bundleID = sender.accessibilityIdentifier;
    if (bundleID.length == 0) return;
    if (self.onPick) self.onPick(bundleID);
    [self close];
}

@end
