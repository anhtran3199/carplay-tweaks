//
//  SplitCarPlayPrefsListController.m
//
//  Statically subclasses the real PSListController (Preferences.framework)
//  and loads Root.plist. Two earlier approaches were tried and both opened
//  to a blank page on-device:
//   1. A static subclass overriding -specifiers via
//      performSelector:withObject:withObject: -- plausible but unverified
//      from memory.
//   2. An empty class built purely at runtime via objc_allocateClassPair
//      (worked around a missing Preferences.framework stub at the time) --
//      also blank, likely because a dynamically-allocated class with zero
//      of its own methods has no code living in this bundle's own Mach-O
//      image, which may break NSBundle-based "which bundle is this
//      Root.plist in" resolution that PSListController relies on
//      internally.
//
//  The CI workflow now installs a patched SDK (theos/sdks release asset)
//  specifically so Preferences.framework is linkable, making proper
//  static subclassing possible again -- confirmed as the right shape by
//  extracting CarSplit's real working prefs bundle (doguner1/repo): it
//  statically subclasses PSListController too, isController=true, and its
//  settings page renders correctly on this same device.
//
#import <UIKit/UIKit.h>

// Forward-declared rather than #import <Preferences/PSListController.h> --
// the patched SDK we link against ships the .tbd needed to resolve this
// class's symbol, but may not ship a matching header, so we don't depend
// on one existing.
@interface PSListController : UIViewController {
    NSArray *_specifiers;
}
- (id)loadSpecifiersFromPlistName:(NSString *)plistName target:(id)target;
@end

// Defined in SplitCarPlayAppPickerController.m (same bundle/binary).
@interface SplitCarPlayAppPickerController : UITableViewController
@property (nonatomic, copy) NSString *defaultsKey;
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

// Pushed manually with plain UINavigationController API from here, rather
// than via Root.plist's PSLinkCell "detail" auto-push (which crashed --
// see SplitCarPlayAppPickerController.m's header comment). PSButtonCell's
// "action" calling a method here is the same pattern CarSplit's own real,
// working Root.plist uses for its "Reset Layout" button.

- (void)pickLeftApp:(id)sender {
    [self pushAppPickerWithDefaultsKey:@"leftBundleID" title:@"Left App"];
}

- (void)pickRightApp:(id)sender {
    [self pushAppPickerWithDefaultsKey:@"rightBundleID" title:@"Right App"];
}

- (void)pushAppPickerWithDefaultsKey:(NSString *)key title:(NSString *)title {
    SplitCarPlayAppPickerController *picker = [[SplitCarPlayAppPickerController alloc] initWithStyle:UITableViewStyleGrouped];
    picker.defaultsKey = key;
    picker.title = title;
    [self.navigationController pushViewController:picker animated:YES];
}

@end
