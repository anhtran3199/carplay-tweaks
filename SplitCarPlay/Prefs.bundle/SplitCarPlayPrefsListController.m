//
//  SplitCarPlayPrefsListController.m
//
//  Registers an EMPTY PSListController subclass -- no custom -specifiers
//  override. A prior version added one (calling
//  -loadSpecifiersFromPlistName:target: via performSelector:withObject:
//  withObject:), which got far enough to show the row in Settings but
//  opened to a blank page -- the override itself is the most likely
//  culprit (wrong selector arity/behavior assumed from memory, not
//  verified against a real binary). The stock PSListController already
//  auto-loads "Root.plist" by convention when a subclass adds nothing of
//  its own, which is why so many real prefs bundles ship a totally empty
//  controller class -- so try relying on that default before writing any
//  more custom loading logic.
//
//  Built via the ObjC runtime API (not `@interface X : PSListController`)
//  because the CI build SDK has no Preferences.framework stub to
//  statically link against -- see git history for the earlier attempts.
//
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

__attribute__((constructor))
static void SplitCarPlayPrefsListControllerInit(void) {
    Class superclass = objc_getClass("PSListController");
    if (!superclass) return;
    if (objc_getClass("SplitCarPlayPrefsListController")) return; // already registered

    Class newClass = objc_allocateClassPair(superclass, "SplitCarPlayPrefsListController", 0);
    if (!newClass) return;

    objc_registerClassPair(newClass);
}
