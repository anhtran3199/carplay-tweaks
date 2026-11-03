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
# No _PRIVATE_FRAMEWORKS = Preferences: PSListController is forward-
# declared in the .m file and resolved at runtime (inside Settings.app,
# where this bundle actually loads), so we don't need the CI build SDK to
# have a Preferences.framework stub -- avoids repeating the
# "framework not found" link failure we hit on SplitCarPlay itself.

include $(THEOS_MAKE_PATH)/bundle.mk

after-install::
	install.exec "killall -9 Preferences || true"
