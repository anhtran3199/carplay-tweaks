//
//  SplitCarPlayPrefsListController.m
//
//  Registers a PSListController subclass that just loads Root.plist.
//
//  WHY THIS IS BUILT WITH RAW OBJC RUNTIME CALLS INSTEAD OF
//  `@interface X : PSListController`
//
//  Statically subclassing a forward-declared class (`@interface X : Y`)
//  makes the linker require Y's real symbol (_OBJC_CLASS_$_Y) to be
//  resolvable at BUILD time -- even though PSListController only truly
//  exists at runtime inside Settings.app/Preferences.app. We tried
//  linking against Preferences.framework (where PSListController lives)
//  to satisfy that, but the CI build SDK doesn't ship a stub for it
//  either (confirmed: "ld: framework 'Preferences' not found").
//
//  So instead this builds the subclass entirely at runtime with the ObjC
//  runtime API (objc_allocateClassPair/class_addMethod/
//  objc_registerClassPair), resolving the real PSListController class by
//  NAME via objc_getClass(), the same pattern the main SplitCarPlay.dylib
//  already uses for other private classes. That needs zero static
//  linking against any private framework -- only UIKit.
//
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSArray *SplitCarPlayPrefs_specifiers(id self, SEL _cmd) {
    static NSArray *specifiers = nil;
    if (!specifiers) {
        // loadSpecifiersFromPlistName:target: takes exactly two object
        // arguments, which -performSelector:withObject:withObject:
        // supports directly -- avoids needing a raw objc_msgSend cast.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        specifiers = [self performSelector:@selector(loadSpecifiersFromPlistName:target:)
                                 withObject:@"Root"
                                 withObject:self];
#pragma clang diagnostic pop
    }
    return specifiers;
}

__attribute__((constructor))
static void SplitCarPlayPrefsListControllerInit(void) {
    Class superclass = objc_getClass("PSListController");
    if (!superclass) return;
    if (objc_getClass("SplitCarPlayPrefsListController")) return; // already registered

    Class newClass = objc_allocateClassPair(superclass, "SplitCarPlayPrefsListController", 0);
    if (!newClass) return;

    class_addMethod(newClass, @selector(specifiers), (IMP)SplitCarPlayPrefs_specifiers, "@@:");
    objc_registerClassPair(newClass);
}
