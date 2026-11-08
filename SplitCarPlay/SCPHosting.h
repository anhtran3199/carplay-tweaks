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

// Phone preview vs CarPlay: never host the same app's view in both places.
// Starting a CarPlay session closes the phone preview and blocks it until
// the session ends. Returns YES if a phone preview had to be closed (it
// lets go of its apps over ~2 s).
BOOL SCPHostSetCarPlaySessionActive(BOOL active);
BOOL SCPHostIsCarPlaySessionActive(void);
