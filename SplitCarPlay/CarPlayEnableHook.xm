//
//  CarPlayEnableHook.xm
//
//  Makes `hostApp:inContainer:replacingExisting:` (Tweak.xm) able to
//  resolve and scene apps that DON'T declare native CarPlay support
//  (YouTube, most ordinary apps) -- without this, iOS's own CarPlay
//  eligibility checks almost certainly reject such apps before scene
//  creation is even attempted, regardless of how correct the rest of
//  the scene-creation chain is. Native CarPlay apps (Maps, Music,
//  Spotify, Waze, ...) don't need this at all.
//
//  WHERE THIS CAME FROM, AND WHY IT'S LESS CERTAIN THAN THE REST OF THIS
//  PROJECT'S PRIVATE-API USAGE
//
//  Grounded in the open-source (Apache-2.0) carplay-cast project
//  (EthanArbuckle/carplay-cast, src/hooks/CarPlay.xm), which does exactly
//  this job. Unlike the SidePlay2.dylib-derived parts of Tweak.xm
//  (extracted as literal strings straight out of a real compiled
//  binary), I don't have carplay-cast's literal source here -- an AI
//  summarization tool declined to reproduce the file verbatim (citing
//  fair use, even though Apache-2.0 explicitly permits copying with
//  attribution) and gave back a paraphrased description of its
//  property/selector names instead. So:
//    - The CLASS name (CRCarPlayAppDeclaration) and the FOUR property
//      names (supportsTemplates, supportsMaps, bundleIdentifier,
//      bundlePath) are real, from that description.
//    - HOW a constructed declaration actually gets registered into the
//      app library object `_newApplicationLibrary` returns, and exactly
//      which object the "_tags" ivar lives on, were NOT specified in
//      that description (only that an ivar called "_tags" gets set via
//      direct ivar access, containing "CarPlayEnable") -- those two
//      specific mechanics below are a best-effort reconstruction, not a
//      confirmed one. If this doesn't work, check
//      /var/mobile/Library/Logs/splitcarplay_carplayenable.log (written
//      whenever this runs) to see exactly which step failed, then
//      consult carplay-cast's actual source yourself (it's real, it's
//      Apache-2.0, you're free to read and adapt it directly) rather
//      than guess further from a secondhand description the way this
//      file had to.
//
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// Each .xm file in this project compiles as its own translation unit, so
// this forward declaration (same shape as the one in
// SplitCarPlayAppPickerController.m) is needed again here too -- without
// it, messaging an entirely-undeclared selector on an `id`-typed receiver
// is a hard error under ARC (confirmed: this is exactly what broke CI).
@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allInstalledApplications;
@end

static BOOL SplitCarPlay_RunningInCarPlayApp(void) {
    return [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.CarPlayApp"];
}

static void SplitCarPlayEnableLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *path = @"/var/mobile/Library/Logs/splitcarplay_carplayenable.log";
    NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], line];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        handle = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    [handle seekToEndOfFile];
    [handle writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
    NSLog(@"[SplitCarPlay/CarPlayEnable] %@", line);
}

static void SplitCarPlaySetIvarObject(id object, NSString *ivarName, id value) {
    if (!object) return;
    Ivar ivar = class_getInstanceVariable([object class], [ivarName UTF8String]);
    if (!ivar) {
        SplitCarPlayEnableLog(@"no ivar named %@ on %@ -- tagging skipped", ivarName, [object class]);
        return;
    }
    object_setIvar(object, ivar, value);
}

// Builds one fake declaration for an app that has no native CarPlay
// support, tags it "CarPlayEnable", and tries a few plausible ways to
// register it into the library object `_newApplicationLibrary` produced
// -- logging exactly which (if any) worked.
static void SplitCarPlayRegisterAppWithLibrary(id library, NSString *bundleID, NSString *bundlePath) {
    Class declarationClass = objc_getClass("CRCarPlayAppDeclaration");
    if (!declarationClass) {
        SplitCarPlayEnableLog(@"CRCarPlayAppDeclaration class not found -- cannot fake CarPlay support");
        return;
    }

    id declaration = [[declarationClass alloc] init];
    @try {
        [declaration setValue:@NO forKey:@"supportsTemplates"];
        [declaration setValue:@YES forKey:@"supportsMaps"];
        [declaration setValue:bundleID forKey:@"bundleIdentifier"];
        if (bundlePath.length > 0) [declaration setValue:bundlePath forKey:@"bundlePath"];
    } @catch (NSException *exception) {
        SplitCarPlayEnableLog(@"setting CRCarPlayAppDeclaration properties for %@ threw: %@", bundleID, exception);
        return;
    }

    SplitCarPlaySetIvarObject(declaration, @"_tags", @[@"CarPlayEnable"]);

    // ADAPT: how a declaration actually joins the library isn't
    // confirmed -- try a few plausible shapes defensively.
    BOOL registered = NO;
    if ([library respondsToSelector:@selector(addApplicationDeclaration:)]) {
        @try {
            [library performSelector:@selector(addApplicationDeclaration:) withObject:declaration];
            registered = YES;
        } @catch (NSException *exception) {
            SplitCarPlayEnableLog(@"addApplicationDeclaration: for %@ threw: %@", bundleID, exception);
        }
    }
    if (!registered) {
        for (NSString *key in @[@"declarations", @"applications", @"applicationDeclarations"]) {
            @try {
                NSMutableArray *array = [library mutableArrayValueForKey:key];
                if (array) {
                    [array addObject:declaration];
                    registered = YES;
                    SplitCarPlayEnableLog(@"registered %@ via mutableArrayValueForKey:%@", bundleID, key);
                    break;
                }
            } @catch (NSException *exception) {
                // try the next candidate key
            }
        }
    }

    if (!registered) {
        SplitCarPlayEnableLog(@"could not find a way to register %@'s fake declaration with the library -- "
                                "see this file's header comment; you'll likely need to class-dump the real "
                                "library object on your device to find the right method/property", bundleID);
    }
}

// Only apps that the normal scene-creation path would otherwise reject
// need this -- native CarPlay apps already have a real declaration in
// the original library, and re-declaring them could only cause problems.
// We don't have a reliable way to ask "does %orig's library already
// contain this app" without knowing its real shape (same uncertainty as
// registration above), so for now this registers every non-system app
// unconditionally; %orig's own entries for native apps are untouched
// either way since we only ADD, never remove/replace.
static void SplitCarPlayAddDeclarationsForAllApps(id library) {
    Class workspaceClass = objc_getClass("LSApplicationWorkspace");
    if (![workspaceClass respondsToSelector:@selector(defaultWorkspace)]) {
        SplitCarPlayEnableLog(@"LSApplicationWorkspace unavailable -- cannot enumerate apps to enable");
        return;
    }
    id workspace = [workspaceClass defaultWorkspace];
    if (![workspace respondsToSelector:@selector(allInstalledApplications)]) return;

    NSInteger count = 0;
    for (id app in [workspace allInstalledApplications]) {
        if (![app respondsToSelector:@selector(bundleIdentifier)]) continue;
        NSString *bundleID = [app performSelector:@selector(bundleIdentifier)];
        if (bundleID.length == 0) continue;
        if ([bundleID hasPrefix:@"com.apple."]) continue; // skip Apple's own apps -- already natively handled

        NSString *bundlePath = nil;
        if ([app respondsToSelector:@selector(bundleURL)]) {
            id url = [app performSelector:@selector(bundleURL)];
            if ([url respondsToSelector:@selector(path)]) bundlePath = [url performSelector:@selector(path)];
        }

        SplitCarPlayRegisterAppWithLibrary(library, bundleID, bundlePath);
        count++;
    }
    SplitCarPlayEnableLog(@"attempted to register %ld third-party apps for CarPlay eligibility", (long)count);
}

%hook CARApplication

+ (id)_newApplicationLibrary {
    id library = %orig;
    if (SplitCarPlay_RunningInCarPlayApp() && library) {
        SplitCarPlayAddDeclarationsForAllApps(library);
    }
    return library;
}

%end
