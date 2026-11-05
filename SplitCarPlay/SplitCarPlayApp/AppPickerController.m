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

static NSString * const kPrefsPath = @"/var/mobile/Library/Preferences/com.example.splitcarplay.plist";
static NSString * const kReloadNotification = @"com.example.splitcarplay/reload";

void SplitCarPlaySetPref(NSString *key, id value) {
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:kPrefsPath] ?: [NSMutableDictionary new];
    prefs[key] = value;
    [prefs writeToFile:kPrefsPath atomically:YES];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                          (__bridge CFStringRef)kReloadNotification, NULL, NULL, YES);
}

// "Recent" is a simplification used throughout this project: just the two
// currently-picked apps (deduplicated), not a persisted history.
NSArray<NSString *> *SplitCarPlayRecentBundleIDs(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath] ?: @{};
    NSMutableArray<NSString *> *recent = [NSMutableArray new];
    for (NSString *bundleID in @[ prefs[@"leftBundleID"] ?: @"", prefs[@"rightBundleID"] ?: @"" ]) {
        if (bundleID.length > 0 && ![recent containsObject:bundleID]) [recent addObject:bundleID];
    }
    return recent;
}

#pragma mark - Grid picker (modal)

@interface AppPickerController : UIViewController
@property (nonatomic, copy) void (^onPick)(NSString *bundleID);
@property (nonatomic, copy) NSString *pickerTitle;
+ (void)presentFrom:(UIViewController *)presenter title:(NSString *)title onPick:(void (^)(NSString *bundleID))onPick;
@end

@implementation AppPickerController {
    UIScrollView *_scroll;
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
    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];

    UITapGestureRecognizer *dimTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(close)];
    [self.view addGestureRecognizer:dimTap];

    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [UIColor colorWithWhite:0.14 alpha:1];
    card.layer.cornerRadius = 14;
    card.layer.masksToBounds = YES;
    card.tag = 9001;
    [self.view addSubview:card];
    // Eat taps on the card itself so they don't fall through to the dim
    // background's close gesture.
    [card addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(doNothing)]];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = self.pickerTitle;
    titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.tag = 9002;
    [card addSubview:titleLabel];

    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [closeButton setTitle:@"✕" forState:UIControlStateNormal];
    closeButton.tintColor = [UIColor colorWithWhite:0.7 alpha:1];
    closeButton.tag = 9003;
    [closeButton addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:closeButton];

    _scroll = [[UIScrollView alloc] init];
    [card addSubview:_scroll];

    [self populateGrid];
}

- (void)doNothing {
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIView *card = [self.view viewWithTag:9001];
    CGRect cardFrame = CGRectMake(16, self.view.safeAreaInsets.top + 40,
                                   self.view.bounds.size.width - 32,
                                   self.view.bounds.size.height * 0.62);
    card.frame = cardFrame;

    UILabel *titleLabel = (UILabel *)[card viewWithTag:9002];
    titleLabel.frame = CGRectMake(16, 14, cardFrame.size.width - 60, 24);

    UIButton *closeButton = (UIButton *)[card viewWithTag:9003];
    closeButton.frame = CGRectMake(cardFrame.size.width - 44, 6, 36, 36);

    _scroll.frame = CGRectMake(0, 48, cardFrame.size.width, cardFrame.size.height - 48);
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)populateGrid {
    for (UIView *subview in _scroll.subviews) [subview removeFromSuperview];
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded]; // need _scroll's real width before laying out the grid below

    CGFloat y = 8;
    NSArray<NSString *> *recent = SplitCarPlayRecentBundleIDs();
    if (recent.count > 0) {
        y = [self addSection:@"GẦN ĐÂY" bundleIDs:recent startY:y];
    }
    y = [self addSection:@"TẤT CẢ" bundleIDs:SplitCarPlayUserInstalledBundleIDsSorted() startY:y];
    _scroll.contentSize = CGSizeMake(_scroll.bounds.size.width, y + 12);
}

- (CGFloat)addSection:(NSString *)title bundleIDs:(NSArray<NSString *> *)bundleIDs startY:(CGFloat)y {
    UILabel *header = [[UILabel alloc] initWithFrame:CGRectMake(12, y, _scroll.bounds.size.width - 24, 18)];
    header.text = title;
    header.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    header.textColor = [UIColor colorWithWhite:0.55 alpha:1];
    [_scroll addSubview:header];
    y += 26;

    CGFloat itemWidth = 72, itemIconSize = 60, padding = 4;
    NSInteger columns = MAX(1, (NSInteger)(_scroll.bounds.size.width / itemWidth));
    CGFloat sideInset = (_scroll.bounds.size.width - columns * itemWidth) / 2.0;

    NSInteger col = 0;
    CGFloat rowY = y;
    for (NSString *bundleID in bundleIDs) {
        CGFloat x = sideInset + col * itemWidth;
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.frame = CGRectMake(x, rowY, itemWidth, itemIconSize + 26);
        button.accessibilityIdentifier = bundleID;
        [button addTarget:self action:@selector(appTapped:) forControlEvents:UIControlEventTouchUpInside];

        UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectMake((itemWidth - itemIconSize) / 2.0, 0, itemIconSize, itemIconSize)];
        icon.image = SplitCarPlayAppIcon(bundleID);
        icon.contentMode = UIViewContentModeScaleAspectFit;
        icon.layer.cornerRadius = 12;
        icon.layer.masksToBounds = YES;
        icon.userInteractionEnabled = NO;
        [button addSubview:icon];

        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, itemIconSize + 2, itemWidth, 16)];
        label.text = SplitCarPlayDisplayNameForBundleID(bundleID);
        label.font = [UIFont systemFontOfSize:11];
        label.textColor = [UIColor whiteColor];
        label.textAlignment = NSTextAlignmentCenter;
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        label.userInteractionEnabled = NO;
        [button addSubview:label];

        [_scroll addSubview:button];

        col++;
        if (col >= columns) {
            col = 0;
            rowY += itemIconSize + 26 + padding;
        }
    }
    if (col != 0) rowY += itemIconSize + 26 + padding;
    return rowY + 14;
}

- (void)appTapped:(UIButton *)sender {
    NSString *bundleID = sender.accessibilityIdentifier;
    if (bundleID.length == 0) return;
    if (self.onPick) self.onPick(bundleID);
    [self close];
}

@end
