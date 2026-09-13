THEOS_PACKAGE_SCHEME ?= roothide
TARGET              := iphone:clang:16.5:15.0
ARCHS                = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = com_hid_dev

com_hid_dev_FILES      = Tweak.x
com_hid_dev_CFLAGS     = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function -Wno-unused-variable -Oz -fvisibility=hidden
com_hid_dev_LDFLAGS    = -Wl,-dead_strip
com_hid_dev_FRAMEWORKS = Foundation UIKit Security

include $(THEOS_MAKE_PATH)/tweak.mk
