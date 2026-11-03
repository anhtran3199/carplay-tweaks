//
//  SplitCarPlayAppPickerController.m  (v2 — fixes a crash)
//
//  v1 used Root.plist's PSLinkCell "detail" key to let PreferenceLoader/
//  Preferences.framework auto-push the picker. That crashed on-device.
//  Most likely cause: PSLinkCell's push path probably expects the pushed
//  class to respond to PSListController-specific setup (it may call
//  something like -setSpecifier: or an unusual initializer after alloc),
//  which a plain UITableViewController simply doesn't implement --
//  "unrecognized selector" would exactly match "crashes out to the home
//  screen" (Settings/Preferences.app force-closing).
//
//  v2 sidesteps that entirely: Root.plist's rows are now PSButtonCell
//  (confirmed-working pattern -- extracted directly from CarSplit's own
//  real, working Root.plist, which uses exactly this for its "Reset
//  Layout" button), and SplitCarPlayPrefsListController itself pushes
//  this picker with the completely standard, no-private-API
//  UINavigationController -pushViewController:animated: + plain
//  -initWithStyle:. No PSLinkCell auto-push involved at all.
//
//  Also defensively respondsToSelector:-guards the LSApplicationProxy
//  property names (bundleIdentifier is certain; localizedName is the
//  conventional name but unverified against a real binary the way
//  everything else in this prefs bundle now is) so a wrong guess there
//  degrades to a fallback label instead of crashing again.
//
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - Private API (LaunchServices) — real, widely used by app-picker tweaks

@interface LSApplicationProxy : NSObject
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray<LSApplicationProxy *> *)allInstalledApplications;
- (LSApplicationProxy *)applicationProxyForIdentifier:(NSString *)bundleID;
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
    return SplitCarPlayAppBundleID(app); // last-resort fallback, never nil if bundleIdentifier worked
}

// Exported (not static) so SplitCarPlayPrefsListController.m can show the
// currently-selected app's name next to "Left App"/"Right App".
NSString *SplitCarPlayDisplayNameForBundleID(NSString *bundleID) {
    if (bundleID.length == 0) return nil;
    LSApplicationWorkspace *workspace = SplitCarPlayWorkspace();
    if (![workspace respondsToSelector:@selector(applicationProxyForIdentifier:)]) return bundleID;
    LSApplicationProxy *app = [workspace applicationProxyForIdentifier:bundleID];
    return app ? SplitCarPlayAppDisplayName(app) : bundleID;
}

// Real, widely-used private API for fetching an app's icon outside of
// SpringBoard (e.g. App Switcher-style UIs). respondsToSelector:-guarded:
// if this selector name turns out wrong on this iOS version, icons just
// don't show (nil) instead of crashing.
static UIImage *SplitCarPlayAppIcon(NSString *bundleID) {
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

#pragma mark - Shared prefs I/O (same contract SplitCarPlay.dylib reads/writes)

static NSString * const kPrefsPath = @"/var/mobile/Library/Preferences/com.example.splitcarplay.plist";
static NSString * const kReloadNotification = @"com.example.splitcarplay/reload";

static void SplitCarPlaySetPref(NSString *key, NSString *value) {
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:kPrefsPath] ?: [NSMutableDictionary new];
    prefs[key] = value;
    [prefs writeToFile:kPrefsPath atomically:YES];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                          (__bridge CFStringRef)kReloadNotification, NULL, NULL, YES);
}

#pragma mark - Picker (plain UITableViewController, pushed manually -- see header comment)

@interface SplitCarPlayAppPickerController : UITableViewController
@property (nonatomic, copy) NSString *defaultsKey;
@end

@implementation SplitCarPlayAppPickerController {
    NSArray<LSApplicationProxy *> *_apps;
    NSArray<NSString *> *_names;
    NSArray<NSString *> *_bundleIDs;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    LSApplicationWorkspace *workspace = SplitCarPlayWorkspace();
    NSArray<LSApplicationProxy *> *all = @[];
    if ([workspace respondsToSelector:@selector(allInstalledApplications)]) {
        all = [workspace allInstalledApplications] ?: @[];
    }

    NSMutableArray<LSApplicationProxy *> *validApps = [NSMutableArray new];
    for (LSApplicationProxy *app in all) {
        if (SplitCarPlayAppBundleID(app).length > 0) [validApps addObject:app];
    }
    [validApps sortUsingComparator:^NSComparisonResult(LSApplicationProxy *a, LSApplicationProxy *b) {
        return [SplitCarPlayAppDisplayName(a) caseInsensitiveCompare:SplitCarPlayAppDisplayName(b)];
    }];

    _apps = validApps;
    NSMutableArray<NSString *> *names = [NSMutableArray new];
    NSMutableArray<NSString *> *ids = [NSMutableArray new];
    for (LSApplicationProxy *app in validApps) {
        [names addObject:SplitCarPlayAppDisplayName(app)];
        [ids addObject:SplitCarPlayAppBundleID(app)];
    }
    _names = names;
    _bundleIDs = ids;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _names.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString * const kIdentifier = @"App";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kIdentifier];
    }
    cell.textLabel.text = _names[indexPath.row];
    cell.detailTextLabel.text = _bundleIDs[indexPath.row];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.imageView.image = SplitCarPlayAppIcon(_bundleIDs[indexPath.row]);
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *bundleID = _bundleIDs[indexPath.row];
    if (self.defaultsKey.length > 0 && bundleID.length > 0) {
        SplitCarPlaySetPref(self.defaultsKey, bundleID);
    }
    [self.navigationController popViewControllerAnimated:YES];
}

@end
