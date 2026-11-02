ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VietmapLiveExport
VietmapLiveExport_FILES = Tweak.xm
VietmapLiveExport_CFLAGS = -fobjc-arc
VietmapLiveExport_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
