ARCHS = arm64 arm64e
TARGET = iphone:clang:15.6:15.0
THEOS_PACKAGE_COMPRESSION_TYPE = xz
FINALPACKAGE = 1
DEBUG = 0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SyncRelay
SyncRelay_FILES = Tweak/SRBootstrap.m Core/SRStore.m Core/SRPacing.c Core/SRConfiguration.m Core/SRSelection.m Core/SRGroupPlanner.m Core/SRSourceMessage.m Core/SRSourceCapture.m Core/SRRunner.m Core/SREntryPreferences.m Adapter/SRRuntime.m Adapter/SRWeChatReader.m Adapter/SRWeChatReceiver.m Adapter/SRWeChatSendProbe.m Adapter/SRWeChatSettingsEntry.m UI/SRPanel.m UI/SRPlanScreens.m UI/SRSettingsFallback.m
SyncRelay_CFLAGS = -fobjc-arc -Wall -Wextra -Werror -I$(THEOS_PROJECT_DIR)
SyncRelay_FRAMEWORKS = Foundation UIKit
SyncRelay_LIBRARIES = sqlite3

include $(THEOS_MAKE_PATH)/tweak.mk
