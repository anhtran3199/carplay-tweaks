include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = SplitCarPlayPrefs
# Needs a real compiled controller: the reference tweak we compared
# against on-device (CarSplit) registers with isController=true + an
# actual PSListController subclass -- a resource-only bundle
# (isController=false, no _FILES) never showed up in Settings in testing.
SplitCarPlayPrefs_FILES = SplitCarPlayPrefsListController.m
SplitCarPlayPrefs_INSTALL_PATH = /Library/PreferenceBundles
SplitCarPlayPrefs_CFLAGS = -fobjc-arc
SplitCarPlayPrefs_FRAMEWORKS = UIKit
# No _PRIVATE_FRAMEWORKS: the CI build SDK has no stub for Preferences.framework
# either (confirmed: "ld: framework 'Preferences' not found"), so
# SplitCarPlayPrefsListController.m builds its PSListController subclass
# entirely at runtime via the ObjC runtime API instead of static
# subclassing -- see the comment at the top of that file.

include $(THEOS_MAKE_PATH)/bundle.mk

after-install::
	install.exec "killall -9 Preferences || true"
