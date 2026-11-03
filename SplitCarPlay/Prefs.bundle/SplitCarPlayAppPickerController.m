//
//  SplitCarPlayAppPickerController.m
//
//  A plain UITableViewController (NOT a PSListController/PSSpecifier
//  setup) listing every installed app, pushed when the user taps
//  "Left App"/"Right App" on the main Root.plist page (via PSLinkCell's
//  "detail" key -- that push mechanism just needs any UIViewController,
//  so a plain table controller works without touching the trickier
//  PSSpecifier/PSActionCell machinery).
//
//  App enumeration uses LSApplicationWorkspace, the standard private API
//  for "list every installed app" on iOS -- used by essentially every
//  jailbreak tweak that offers an app picker.
//
//  Picking an app writes straight into the same prefs plist SplitCarPlay
//  itself reads (/var/mobile/Library/Preferences/com.example.splitcarplay.plist)
//  and posts the same reload notification the PSSwitchCell/PSSliderCell
//  rows already use, so SplitCarPlay.dylib picks it up live.
//
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - Private API (LaunchServices) — real, widely used by app-picker tweaks

@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly) NSString *bundleIdentifier;
@property (nonatomic, readonly) NSString *localizedName;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray<LSApplicationProxy *> *)allInstalledApplications;
@end

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

#pragma mark - Base picker

@interface SplitCarPlayAppPickerBaseController : UITableViewController
@property (nonatomic, copy) NSArray<LSApplicationProxy *> *apps;
- (NSString *)defaultsKey; // override in subclass
@end

@implementation SplitCarPlayAppPickerBaseController

- (NSString *)defaultsKey {
    return nil; // subclasses override
}

- (void)viewDidLoad {
    [super viewDidLoad];

    Class workspaceClass = objc_getClass("LSApplicationWorkspace");
    NSArray<LSApplicationProxy *> *all = workspaceClass ? [[workspaceClass defaultWorkspace] allInstalledApplications] : @[];

    NSPredicate *hasName = [NSPredicate predicateWithBlock:^BOOL(LSApplicationProxy *app, NSDictionary *bindings) {
        return app.localizedName.length > 0 && app.bundleIdentifier.length > 0;
    }];
    NSArray *filtered = [all filteredArrayUsingPredicate:hasName];
    self.apps = [filtered sortedArrayUsingComparator:^NSComparisonResult(LSApplicationProxy *a, LSApplicationProxy *b) {
        return [a.localizedName caseInsensitiveCompare:b.localizedName];
    }];

    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"App"];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.apps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"App"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"App"];
    }
    LSApplicationProxy *app = self.apps[indexPath.row];
    cell.textLabel.text = app.localizedName;
    cell.detailTextLabel.text = app.bundleIdentifier;
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    LSApplicationProxy *app = self.apps[indexPath.row];
    NSString *key = [self defaultsKey];
    if (key.length > 0 && app.bundleIdentifier.length > 0) {
        SplitCarPlaySetPref(key, app.bundleIdentifier);
    }
    [self.navigationController popViewControllerAnimated:YES];
}

@end

#pragma mark - Leaf controllers (named exactly as referenced by Root.plist's PSLinkCell "detail")

@interface SplitCarPlayAppPickerLeftController : SplitCarPlayAppPickerBaseController
@end

@implementation SplitCarPlayAppPickerLeftController
- (NSString *)defaultsKey { return @"leftBundleID"; }
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"Left App"; }
@end

@interface SplitCarPlayAppPickerRightController : SplitCarPlayAppPickerBaseController
@end

@implementation SplitCarPlayAppPickerRightController
- (NSString *)defaultsKey { return @"rightBundleID"; }
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"Right App"; }
@end
