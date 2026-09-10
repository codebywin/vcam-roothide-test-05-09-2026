THEOS_PACKAGE_SCHEME ?= rootless
TARGET              := iphone:clang:15.6:15.0
ARCHS                = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = vcamios

vcamios_FILES      = Tweak.x VCAMLicenseManager.m
vcamios_CFLAGS     = -fobjc-arc
vcamios_FRAMEWORKS = Foundation UIKit AVFoundation CoreMedia CoreVideo VideoToolbox CoreImage Security

vcamios_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk
