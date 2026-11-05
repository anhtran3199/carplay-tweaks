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

    UITabBarController *tabBar = [[UITabBarController alloc] init];
    tabBar.viewControllers = @[
        [self tabWithRoot:[[HomeViewController alloc] init] title:@"Trang chủ" systemImage:@"house.fill"],
        [self tabWithRoot:[[OnCarViewController alloc] init] title:@"Trên xe" systemImage:@"car.fill"],
        [self tabWithRoot:[[PreviewViewController alloc] init] title:@"Mô phỏng" systemImage:@"play.rectangle.fill"],
        [self tabWithRoot:[[AccountViewController alloc] init] title:@"Tài khoản" systemImage:@"person.crop.circle"],
    ];
    // "Mô phỏng" is the tab SidePlay's own screenshots default-open to in
    // this project's reference images, and the most useful one to land
    // on first (actually shows something interactive right away).
    tabBar.selectedIndex = 2;

    self.window.rootViewController = tabBar;
    [self.window makeKeyAndVisible];
    return YES;
}

@end
