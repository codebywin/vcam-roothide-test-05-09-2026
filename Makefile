THEOS_PACKAGE_SCHEME ?= rootless
TARGET              := iphone:clang:15.6:15.0
ARCHS                = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = vcamios

vcamios_FILES      = Tweak.x VCAMLicenseManager.m VCAMFlashLivenessManager.m
vcamios_CFLAGS     = -fobjc-arc -Wno-deprecated-declarations -include VCAMObfuscation.h -fvisibility=hidden -Oz
vcamios_LDFLAGS    = -Wl,-dead_strip
vcamios_FRAMEWORKS = Foundation UIKit AVFoundation CoreMedia CoreVideo VideoToolbox CoreImage Security QuartzCore

vcamios_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk
