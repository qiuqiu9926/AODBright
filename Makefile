TARGET = iphone:clang:latest:14.0
ARCHS = arm64
THEOS_PACKAGE_SCHEME = rootless

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AODBright
AODBright_FILES = AODBright.m
AODBright_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
AODBright_FRAMEWORKS = UIKit Foundation AudioToolbox

include $(THEOS_MAKE_PATH)/tweak.mk