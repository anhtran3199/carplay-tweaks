//
//  SplitCarPlayPrefsListController.m
//
//  Minimal PSListController subclass that just loads Root.plist. This
//  exists because the real, working reference tweak we compared against
//  (CarSplit, github.com/doguner1/repo) registers with isController=true
//  and an actual compiled controller class, not a resource-only bundle
//  (isController=false) -- our earlier resource-only attempt never showed
//  up in Settings on-device, this does.
//
//  PSListController itself comes from the private Preferences.framework,
//  which we deliberately do NOT link against (see Prefs.bundle/Makefile)
//  -- forward-declaring just enough of its shape and resolving the real
//  class at runtime (inside Settings.app/Preferences.app, where this
//  bundle actually loads) avoids depending on whether the CI build SDK
//  has a Preferences.framework stub at all.
//
#import <UIKit/UIKit.h>

@interface PSListController : UIViewController {
    NSArray *_specifiers;
}
- (id)loadSpecifiersFromPlistName:(NSString *)plistName target:(id)target;
@end

@interface SplitCarPlayPrefsListController : PSListController
@end

@implementation SplitCarPlayPrefsListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

@end
