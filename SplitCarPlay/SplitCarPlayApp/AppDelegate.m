//
//  AppDelegate.m
//
//  Sets up the 4-tab structure matching SidePlay's own app (Trang chủ /
//  Trên xe / Mô phỏng / Tài khoản) -- see ROADMAP.md's "Architecture
//  pivot" entry for why this standalone app exists instead of a
//  Settings preferences bundle.
//
#import "AppDelegate.h"

// Each of these is declared inline in its own .m file (no separate
// header) -- same convention as the rest of this project. A plain
// forward interface is enough since AppDelegate only ever does
// [[Class alloc] init] on them.
@interface HomeViewController : UIViewController
@end
@interface OnCarViewController : UIViewController
@end
@interface PreviewViewController : UIViewController
@end
@interface AccountViewController : UIViewController
@end

#pragma mark - Floating tab bar

// The reference screenshots' tab bar floats: a white rounded bar inset from
// the screen edges with a soft shadow, and the selected tab sits on a light
// blue pill. Done with the stock UITabBar (no custom tab bar view): after
// UIKit lays it out, its frame is pulled in from the sides (and lifted a
// little on home-button phones), the bar's own layer draws the rounded
// background + shadow, and the pill is the selection-indicator image.
static const CGFloat kSCPTabBarSideInset = 12;
static const CGFloat kSCPTabBarBottomGap = 6; // only on phones without a home indicator
static const CGFloat kSCPTabBarCornerRadius = 20;

@interface SCPFloatingTabBarController : UITabBarController <UITabBarControllerDelegate>
@end

@implementation SCPFloatingTabBarController {
    CGSize _indicatorSize;
    CGFloat _appliedBottomGap;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    UITabBar *bar = self.tabBar;
    bar.tintColor = [UIColor systemBlueColor];
    bar.unselectedItemTintColor = [UIColor secondaryLabelColor];
    // System colours so the bar follows light/dark mode.
    bar.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    bar.layer.cornerRadius = kSCPTabBarCornerRadius;
    bar.layer.masksToBounds = NO;
    bar.layer.borderWidth = 1.0 / MAX(1.0, [UIScreen mainScreen].scale);
    bar.layer.borderColor = [UIColor separatorColor].CGColor;
    bar.layer.shadowColor = [UIColor blackColor].CGColor;
    bar.layer.shadowOpacity = 0.10;
    bar.layer.shadowRadius = 12;
    bar.layer.shadowOffset = CGSizeMake(0, 4);
    _appliedBottomGap = -1;
    [self applyAppearanceWithIndicator:nil];
    self.delegate = self; // only for the icon bounce below
}

#pragma mark - Orientation: only Mô phỏng turns landscape

- (BOOL)previewTabSelected {
    UIViewController *selected = self.selectedViewController;
    if ([selected isKindOfClass:[UINavigationController class]]) selected = ((UINavigationController *)selected).topViewController;
    return [selected isKindOfClass:NSClassFromString(@"PreviewViewController")];
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return [self previewTabSelected] ? UIInterfaceOrientationMaskAllButUpsideDown : UIInterfaceOrientationMaskPortrait;
}

- (BOOL)shouldAutorotate {
    return YES;
}

// Leaving Mô phỏng while landscape: iOS 15 doesn't rotate back by itself
// when the allowed orientations shrink, so ask for portrait.
- (void)returnToPortraitIfNeeded {
    if ([self previewTabSelected]) return;
    UIWindowScene *scene = self.view.window.windowScene;
    if (!scene || UIInterfaceOrientationIsPortrait(scene.interfaceOrientation)) return;
    [[UIDevice currentDevice] setValue:@(UIInterfaceOrientationPortrait) forKey:@"orientation"];
    [UIViewController attemptRotationToDeviceOrientation];
}

#pragma mark - Selected-tab bounce

// UIKit's own button for the tab at `index`: the bar's UIControl subviews
// in on-screen order. nil if that doesn't match the item count (then we
// just skip the bounce).
- (UIView *)buttonForTabAtIndex:(NSUInteger)index {
    NSMutableArray<UIView *> *buttons = [NSMutableArray new];
    for (UIView *subview in self.tabBar.subviews) {
        if ([subview isKindOfClass:[UIControl class]]) [buttons addObject:subview];
    }
    if (buttons.count != self.tabBar.items.count || index >= buttons.count) return nil;
    [buttons sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        CGFloat ax = CGRectGetMinX(a.frame), bx = CGRectGetMinX(b.frame);
        return ax < bx ? NSOrderedAscending : (ax > bx ? NSOrderedDescending : NSOrderedSame);
    }];
    if (self.tabBar.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft) {
        index = buttons.count - 1 - index;
    }
    return buttons[index];
}

// The icon is the smallest image view in the button (anything bigger is
// background/selection art).
- (UIView *)iconInTabButton:(UIView *)button {
    UIView *icon = nil;
    for (UIView *subview in button.subviews) {
        if (![subview isKindOfClass:[UIImageView class]] || subview.bounds.size.width <= 0) continue;
        if (!icon || subview.bounds.size.width < icon.bounds.size.width) icon = subview;
    }
    return icon;
}

- (void)tabBarController:(UITabBarController *)tabBarController didSelectViewController:(UIViewController *)viewController {
    [self returnToPortraitIfNeeded];
    if (UIAccessibilityIsReduceMotionEnabled()) return;
    UIView *button = [self buttonForTabAtIndex:tabBarController.selectedIndex];
    UIView *target = [self iconInTabButton:button] ?: button;
    if (!target) return;
    // Layer-only keyframes (presentation layer), so the bar's own layout
    // and frames are never touched.
    CAKeyframeAnimation *bounce = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
    bounce.values = @[@1.0, @0.86, @1.12, @0.97, @1.0];
    bounce.keyTimes = @[@0, @0.2, @0.5, @0.75, @1];
    bounce.duration = 0.35;
    bounce.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [target.layer addAnimation:bounce forKey:@"scpTabBounce"];
}

- (void)applyAppearanceWithIndicator:(UIImage *)indicator {
    UIColor *selectedColor = [UIColor systemBlueColor];
    UIColor *normalColor = [UIColor secondaryLabelColor];
    if (@available(iOS 13.0, *)) {
        // Transparent bar background: the bar's own (rounded) layer
        // background shows through instead of UIKit's square one.
        UITabBarAppearance *appearance = [[UITabBarAppearance alloc] init];
        [appearance configureWithTransparentBackground];
        appearance.backgroundColor = [UIColor clearColor];
        appearance.shadowColor = [UIColor clearColor];
        appearance.selectionIndicatorImage = indicator;
        NSDictionary *normalText = @{
            NSForegroundColorAttributeName: normalColor,
            NSFontAttributeName: [UIFont systemFontOfSize:10 weight:UIFontWeightMedium],
        };
        NSDictionary *selectedText = @{
            NSForegroundColorAttributeName: selectedColor,
            NSFontAttributeName: [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold],
        };
        NSArray<UITabBarItemAppearance *> *itemAppearances = @[
            appearance.stackedLayoutAppearance,
            appearance.inlineLayoutAppearance,
            appearance.compactInlineLayoutAppearance,
        ];
        for (UITabBarItemAppearance *itemAppearance in itemAppearances) {
            itemAppearance.normal.iconColor = normalColor;
            itemAppearance.normal.titleTextAttributes = normalText;
            itemAppearance.selected.iconColor = selectedColor;
            itemAppearance.selected.titleTextAttributes = selectedText;
        }
        self.tabBar.standardAppearance = appearance;
        if (@available(iOS 15.0, *)) {
            self.tabBar.scrollEdgeAppearance = appearance;
        }
    } else {
        self.tabBar.backgroundImage = [UIImage new];
        self.tabBar.shadowImage = [UIImage new];
        self.tabBar.selectionIndicatorImage = indicator;
    }
}

// Light-blue rounded pill, sized to exactly one tab item so it doesn't
// matter whether UIKit draws the indicator at its natural size or
// stretches it to the item.
- (UIImage *)indicatorImageOfSize:(CGSize)size {
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGRect pill = CGRectInset(CGRectMake(0, 0, size.width, size.height), 8, 4);
        [[[UIColor systemBlueColor] colorWithAlphaComponent:0.15] setFill]; // reads on light and dark
        [[UIBezierPath bezierPathWithRoundedRect:pill cornerRadius:14] fill];
    }];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UITabBar *bar = self.tabBar;
    CGRect viewBounds = self.view.bounds;
    CGFloat bottomSafe = self.view.safeAreaInsets.bottom;
    CGFloat gap = bottomSafe > 0 ? 0 : kSCPTabBarBottomGap;

    // Keep UIKit's height (49pt + home-indicator area); only inset the
    // sides and lift by `gap`.
    CGRect frame = bar.frame;
    frame.origin.x = kSCPTabBarSideInset;
    frame.size.width = MAX(0, viewBounds.size.width - kSCPTabBarSideInset * 2);
    frame.origin.y = viewBounds.size.height - frame.size.height - gap;
    if (!CGRectEqualToRect(bar.frame, frame)) bar.frame = frame;
    bar.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:bar.bounds cornerRadius:kSCPTabBarCornerRadius].CGPath;

    // Children already get a bottom safe-area inset for the bar's height;
    // add the lift so nothing ends up hidden behind the floating bar.
    if (_appliedBottomGap != gap) {
        _appliedBottomGap = gap;
        for (UIViewController *child in self.viewControllers) {
            UIEdgeInsets insets = child.additionalSafeAreaInsets;
            insets.bottom = gap;
            child.additionalSafeAreaInsets = insets;
        }
    }

    NSUInteger count = MAX((NSUInteger)1, self.viewControllers.count);
    CGFloat itemHeight = MAX(1, MIN(49, frame.size.height - bottomSafe));
    CGSize itemSize = CGSizeMake(MAX(1, floor(frame.size.width / count)), itemHeight);
    if (!CGSizeEqualToSize(itemSize, _indicatorSize)) {
        _indicatorSize = itemSize;
        [self applyAppearanceWithIndicator:[self indicatorImageOfSize:itemSize]];
    }
}

// CGColor borders don't follow light/dark by themselves.
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previous]) {
        self.tabBar.layer.borderColor = [UIColor separatorColor].CGColor;
        if (_indicatorSize.width > 0) [self applyAppearanceWithIndicator:[self indicatorImageOfSize:_indicatorSize]];
    }
}

@end

@implementation AppDelegate

- (UIViewController *)tabWithRoot:(UIViewController *)root title:(NSString *)title systemImage:(NSString *)imageName {
    root.title = title;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
    if (@available(iOS 13.0, *)) {
        nav.tabBarItem = [[UITabBarItem alloc] initWithTitle:title image:[UIImage systemImageNamed:imageName] tag:0];
    } else {
        nav.tabBarItem = [[UITabBarItem alloc] initWithTitle:title image:nil tag:0];
    }
    return nav;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

    UITabBarController *tabBar = [[SCPFloatingTabBarController alloc] init];
    tabBar.viewControllers = @[
        [self tabWithRoot:[[HomeViewController alloc] init] title:@"Trang chủ" systemImage:@"house.fill"],
        [self tabWithRoot:[[OnCarViewController alloc] init] title:@"Trên xe" systemImage:@"car.fill"],
        [self tabWithRoot:[[PreviewViewController alloc] init] title:@"Mô phỏng" systemImage:@"play.rectangle.fill"],
        [self tabWithRoot:[[AccountViewController alloc] init] title:@"Tài khoản" systemImage:@"person.crop.circle"],
    ];
    // Open on Trang chủ (like SidePlay2). Mô phỏng starts the real apps as
    // soon as it shows, which shouldn't happen just by opening the app.
    tabBar.selectedIndex = 0;

    self.window.rootViewController = tabBar;
    [self.window makeKeyAndVisible];
    return YES;
}

@end
