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
# Statically subclassing PSListController (@interface X : PSListController)
# needs its _OBJC_CLASS_$_PSListController symbol at LINK time too, not
# just at runtime -- forward-declaring the interface alone wasn't enough
# (confirmed: CI failed with "Undefined symbols ... PSListController").
# Preferences.framework is about the most common private framework in the
# whole tweak ecosystem (every PSListController-based prefs bundle needs
# it), so unlike BackBoardServices et al. earlier, the community SDK is
# expected to ship a stub for it.
SplitCarPlayPrefs_PRIVATE_FRAMEWORKS = Preferences

include $(THEOS_MAKE_PATH)/bundle.mk

after-install::
	install.exec "killall -9 Preferences || true"
