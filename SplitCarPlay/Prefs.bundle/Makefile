include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = SplitCarPlayPrefs
# No _FILES: this bundle is resource-only (stock PS*Cell specifiers, no
# custom controller code — Entry.plist already sets isController = false).
# bundle.mk supports that; Root.plist/Entry.plist just need to live under
# Resources/ so the default _RESOURCE_DIRS picks them up and copies them
# to the bundle root (where PreferenceLoader/Settings expect to find them).
SplitCarPlayPrefs_INSTALL_PATH = /Library/PreferenceBundles
# No _FRAMEWORKS/_PRIVATE_FRAMEWORKS either — nothing here compiles or
# links, so declaring them would risk the same "framework not found" link
# failure we hit on SplitCarPlay itself if the CI SDK lacks a stub for one.

include $(THEOS_MAKE_PATH)/bundle.mk

after-install::
	install.exec "killall -9 Preferences || true"
