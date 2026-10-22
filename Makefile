ARCHS = arm64 arm64e
TARGET = iphone:clang:15.6:15.0
THEOS_PACKAGE_COMPRESSION_TYPE = xz
FINALPACKAGE = 1
DEBUG = 0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SyncRelay
SyncRelay_FILES = Tweak/SRBootstrap.m Core/SRStore.m Core/SRPacing.c Core/SRConfiguration.m Core/SRSelection.m Core/SRGroupPlanner.m Core/SRSourceMessage.m Core/SRImageAssetStore.m Core/SRSourceCapture.m Core/SRRunner.m Core/SREntryPreferences.m Core/SRRuntimeLog.m Adapter/SRRuntime.m Adapter/SRWeChatImageSource.m Adapter/SRWeChatImageSendProbe.m Adapter/SRWeChatReader.m Adapter/SRWeChatReceiver.m Adapter/SRWeChatSendProbe.m Adapter/SRWeChatTextSendAdapter.m Adapter/SRWeChatTextSendHost.m Adapter/SRWeChatSettingsEntry.m UI/SRPanel.m UI/SRPlanScreens.m UI/SRSettingsFallback.m
SyncRelay_FILES += Adapter/SRWeChatImageSendHost.m Adapter/SRWeChatImageMaterial.m
SyncRelay_FILES += Adapter/SRSmallGroupSession.m
SyncRelay_FILES += Core/SRExecutionProgress.m UI/SRFloatingProgress.m
SyncRelay_FILES += Core/SROperationsState.c
SyncRelay_FILES += Core/SRRelayCoordinator.m
SyncRelay_FILES += Adapter/SRWeChatFileSource.m UI/SRAppMessagePreviewScreen.m
SyncRelay_CFLAGS = -fobjc-arc -Wall -Wextra -Werror -I$(THEOS_PROJECT_DIR)
SyncRelay_FRAMEWORKS = Foundation UIKit ImageIO CoreGraphics
SyncRelay_LIBRARIES = sqlite3

include $(THEOS_MAKE_PATH)/tweak.mk
