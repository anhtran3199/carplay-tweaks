# Standalone companion app, matching SidePlay's own product shape
# (Trang chủ / Trên xe / Mô phỏng / Tài khoản tabs) instead of a Settings
# preferences bundle -- see ROADMAP.md's "Architecture pivot" entry for
# why. Ships as its own .app inside the same .deb as the tweak
# (aggregated via the top-level Makefile's SUBPROJECTS, same mechanism
# already used for Prefs.bundle).
#
# Pinned to the same exact SDK version as Prefs.bundle (not "latest") --
# see that Makefile's comment; this project doesn't actually need the
# private-framework stubs Prefs.bundle does (no Preferences.framework
# linkage here), but pinning keeps every subproject building against the
# same SDK rather than mixing "latest" and a pinned version.
TARGET := iphone:clang:16.5:14.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = SplitCarPlayApp
SplitCarPlayApp_FILES = main.m AppDelegate.m \
	HomeViewController.m OnCarViewController.m \
	PreviewViewController.m AppPickerController.m \
	AccountViewController.m
SplitCarPlayApp_FRAMEWORKS = UIKit CoreGraphics QuartzCore Metal MetalKit CoreImage
SplitCarPlayApp_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/application.mk

after-install::
	install.exec "uicache || true"

