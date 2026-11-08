//
//  SCPHosting.h
//
//  The app-hosting core that works on the phone (LivePreview.xm), shared
//  with the CarPlay window (Tweak.xm). SpringBoard only, main thread only.
//
//  What it encodes, learned on the device (iOS 15.8.8):
//    - SBDeviceApplicationSceneEntity initWithApplicationForMainDisplay: +
//      SBAppViewController initWithIdentifier:andApplicationSceneEntity: +
//      setRequestedMode:2 shows a live app.
//    - Freeing an SBAppViewController aborts SpringBoard, so they are kept
//      for the life of SpringBoard and reused per app.
//    - Never talk to the scene of an app iOS has killed.
//
#pragma once
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <os/proc.h>
#import <sys/resource.h>

// Appends one line to /var/mobile/Library/Logs/splitcarplay_hosting.log on a
// background queue (handle kept open, file trimmed past 512 KB). Used by
// both SCPLiveLog and Tweak.xm's SplitCarPlayHostingLog.
void SCPHostAppendLog(NSString *line);

// One-line resource snapshot for the log: SpringBoard's memory footprint,
// memory still available to it, CPU time used so far, and window count.
// Two "[mem]" lines a minute apart give SpringBoard's CPU % for that minute.
static inline NSString *SCPMemLine(void) {
    task_vm_info_data_t vm;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    double footprint = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &count) == KERN_SUCCESS
        ? vm.phys_footprint / 1048576.0 : -1;
    struct rusage usage;
    getrusage(RUSAGE_SELF, &usage);
    double cpu = usage.ru_utime.tv_sec + usage.ru_stime.tv_sec + (usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6;
    return [NSString stringWithFormat:@"foot=%.1fMB avail=%.1fMB cpu=%.1fs windows=%lu",
            footprint, os_proc_available_memory() / 1048576.0, cpu,
            (unsigned long)[UIApplication sharedApplication].windows.count];
}

// How many view controllers/windows the hosting core keeps alive.
NSUInteger SCPHostKeptObjectCount(void);

// Starts the app's process without bringing it to the front.
void SCPHostLaunchSuspended(NSString *bundleID, void (^completion)(NSError *error));

// SBApplication for a bundle ID, or nil.
id SCPHostApplication(NSString *bundleID);

// The app's SBAppViewController: the one used last time if there is one,
// otherwise a new one. Never freed. nil if it can't be made.
UIViewController *SCPHostAppViewController(NSString *bundleID, id application);

// The app died: its view controller won't be reused (it stays alive).
void SCPHostForgetAppViewController(NSString *bundleID, UIViewController *controller);

// NO once iOS has killed the app or replaced/invalidated its scene.
BOOL SCPHostAppLooksAlive(id application, id sceneHandle, id scene);

// Foreground + size (setFrame:) of the app's scene.
void SCPHostSetSceneForeground(id scene, BOOL foreground, CGSize size);

// The size an app is told it has for a pane: at least phone width, with
// the pane's aspect ratio. The view is then scaled down to fit the pane.
CGSize SCPHostVirtualSize(CGSize pane);

// Sizes and scales an app's view to fill a pane of this size.
void SCPHostLayoutContent(UIView *content, CGSize pane);

// Keeps an object for the life of SpringBoard (windows that held app views).
void SCPHostKeepForever(id object);

// Removes our own views from a window we stop using; containers holding an
// app's view stay (with only that view in them).
void SCPHostStripOwnViews(UIView *root);

// Phone preview vs CarPlay: never host the same app's view in both places.
// Starting a CarPlay session closes the phone preview and blocks it until
// the session ends. Returns YES if a phone preview had to be closed (it
// lets go of its apps over ~2 s).
BOOL SCPHostSetCarPlaySessionActive(BOOL active);
BOOL SCPHostIsCarPlaySessionActive(void);
