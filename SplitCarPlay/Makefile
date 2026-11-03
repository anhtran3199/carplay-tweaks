ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0

THEOS_DEVICE_IP =
INSTALL_TARGET_PROCESSES = CarPlayApp

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SplitCarPlay
SplitCarPlay_FILES = Tweak.xm VietmapLiveHook.xm
SplitCarPlay_CFLAGS = -fobjc-arc
SplitCarPlay_FRAMEWORKS = UIKit CoreGraphics QuartzCore
# No _PRIVATE_FRAMEWORKS here on purpose: every private class in Tweak.xm is
# resolved dynamically via objc_getClass(...)/runtime messaging rather than
# imported headers with direct symbol references, so nothing needs to be
# linked against at build time — only present at runtime inside the host
# process (CarPlayApp), which already has them loaded. Declaring them here
# instead requires the build SDK to ship a stub for every one of them,
# which is what broke the CI build (BackBoardServices wasn't present).

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += Prefs.bundle
include $(THEOS_MAKE_PATH)/aggregate.mk
