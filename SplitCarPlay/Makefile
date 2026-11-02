ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0

THEOS_DEVICE_IP =
INSTALL_TARGET_PROCESSES = CarPlayApp

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SplitCarPlay
SplitCarPlay_FILES = Tweak.xm
SplitCarPlay_CFLAGS = -fobjc-arc
SplitCarPlay_FRAMEWORKS = UIKit CoreGraphics QuartzCore
SplitCarPlay_PRIVATE_FRAMEWORKS = BackBoardServices FrontBoardServices SpringBoardFoundation SpringBoardServices

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += Prefs.bundle
include $(THEOS_MAKE_PATH)/aggregate.mk
