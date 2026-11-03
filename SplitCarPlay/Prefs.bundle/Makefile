# Pinned to an exact SDK version (not "latest") that the CI workflow
# explicitly installs from theos/sdks' patched release assets, which
# include a Preferences.framework stub -- "latest" was resolving to the
# runner's bare Xcode SDK, which (like every official Apple SDK since
# Xcode 7.3) has none. See build-and-publish.yml for where this SDK
# comes from.
TARGET = iphone:clang:16.5:14.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = SplitCarPlayPrefs
SplitCarPlayPrefs_FILES = SplitCarPlayPrefsListController.m
SplitCarPlayPrefs_INSTALL_PATH = /Library/PreferenceBundles
SplitCarPlayPrefs_CFLAGS = -fobjc-arc
SplitCarPlayPrefs_FRAMEWORKS = UIKit
SplitCarPlayPrefs_PRIVATE_FRAMEWORKS = Preferences

include $(THEOS_MAKE_PATH)/bundle.mk

after-install::
	install.exec "killall -9 Preferences || true"
