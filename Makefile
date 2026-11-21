SDK       := $(shell xcrun --sdk iphoneos --show-sdk-path)
CC        := xcrun --sdk iphoneos clang
LDID      := ldid

APP_NAME  := PinNhietDo
BUNDLE_DIR:= build/Payload/$(APP_NAME).app
OUT_TIPA  := build/PinNhietDo_TS.tipa
OUT_IPA   := build/PinNhietDo_TS.ipa

MAP_APP_NAME   := BanMapXanh
MAP_BUNDLE_DIR := build/MapPayload/Payload/$(MAP_APP_NAME).app
OUT_MAP_TIPA   := build/BanMap_TS.tipa
OUT_MAP_IPA    := build/BanMap_TS.ipa

DASHCAM_APP_NAME   := CoolDash6
DASHCAM_BUNDLE_DIR := build/DashcamPayload/Payload/$(DASHCAM_APP_NAME).app
OUT_DASHCAM_IPA    := build/CoolDash6.ipa

CFLAGS    := -arch arm64 -isysroot $(SDK) -miphoneos-version-min=15.0 -fobjc-arc -O2 \
             -IShared -ISources/App -ISources/Daemon -ISources/MapApp -Wno-deprecated-declarations

DASHCAM_CFLAGS := -arch arm64 -isysroot $(SDK) -miphoneos-version-min=12.0 -fobjc-arc -O2 \
                  -ISources/DashcamApp -Wno-deprecated-declarations

APP_SRCS  := Sources/App/main.m \
             Sources/App/StealthBatteryViewController.m \
             Sources/App/SecretConfigViewController.m \
             Sources/App/CoordinatePickerViewController.m \
             Shared/TSUtil.m

DAEMON_SRCS := Sources/Daemon/pind_main.m \
               Sources/Daemon/ScreenTouchEngine.m \
               Sources/Daemon/OrderScanner.m \
               Sources/Daemon/HanoiFoodFilterEngine.m \
               Sources/Daemon/GSMOrderPayloadSniffer.m \
               Sources/Daemon/StealthStatusPillHUD.m \
               Shared/TSUtil.m

MAP_APP_SRCS := Sources/MapApp/map_main.m \
                Sources/MapApp/MapRelayViewController.m \
                Shared/TSUtil.m

MAP_HELPER_SRCS := Sources/MapApp/maphelper_main.m \
                   Shared/TSUtil.m

DASHCAM_SRCS := Sources/DashcamApp/dashcam_main.m \
                Sources/DashcamApp/DashcamConfig.m \
                Sources/DashcamApp/RingStorageManager.m \
                Sources/DashcamApp/NetworkClassifier.m \
                Sources/DashcamApp/TelemetryAndGSensor.m \
                Sources/DashcamApp/CoolCameraEngine.m \
                Sources/DashcamApp/TelegramUploader.m \
                Sources/DashcamApp/BlackoutDashboardVC.m \
                Sources/DashcamApp/SettingsVC.m

APP_FRAMEWORKS    := -framework Foundation -framework UIKit -framework CoreGraphics \
                     -framework QuartzCore -framework AudioToolbox

DAEMON_FRAMEWORKS := -framework Foundation -framework CoreGraphics \
                     -framework CoreImage -framework QuartzCore \
                     -framework CoreText -framework Vision -framework AudioToolbox -lz

DASHCAM_FRAMEWORKS := -framework Foundation -framework UIKit -framework AVFoundation \
                      -framework CoreMedia -framework CoreVideo -framework VideoToolbox \
                      -framework CoreLocation -framework CoreMotion -framework SystemConfiguration \
                      -framework QuartzCore -lsqlite3

.PHONY: all clean

all: $(OUT_TIPA)

$(OUT_TIPA): $(APP_SRCS) $(DAEMON_SRCS) $(MAP_APP_SRCS) $(MAP_HELPER_SRCS) $(DASHCAM_SRCS) Sources/App/PureQRCode.h Resources/Info.plist Resources/Info_BanMap.plist Resources/Info_CoolDash6.plist Resources/app.entitlements Resources/daemon.entitlements Resources/dashcam.entitlements Resources/hanoi_food_index.zlib
	@echo "==> Generating App Icons & Verifying Hanoi Food Index..."
	python3 scripts/generate_icon.py
	python3 scripts/build_hanoi_food_index.py
	@echo "==> Preparing App Bundle..."
	rm -rf build
	mkdir -p "$(BUNDLE_DIR)"
	cp Resources/Info.plist "$(BUNDLE_DIR)/Info.plist"
	cp Resources/AppIcon60x60@2x.png "$(BUNDLE_DIR)/"
	cp Resources/AppIcon60x60@3x.png "$(BUNDLE_DIR)/"
	cp Resources/hanoi_food_index.zlib "$(BUNDLE_DIR)/hanoi_food_index.zlib"
	@echo "==> Compiling Root Daemon (pind)..."
	$(CC) $(CFLAGS) $(DAEMON_SRCS) $(DAEMON_FRAMEWORKS) -o "$(BUNDLE_DIR)/pind"
	chmod 0755 "$(BUNDLE_DIR)/pind"
	$(LDID) -SResources/daemon.entitlements "$(BUNDLE_DIR)/pind"
	@echo "==> Compiling Disguise UI App ($(APP_NAME))..."
	$(CC) $(CFLAGS) $(APP_SRCS) $(APP_FRAMEWORKS) -o "$(BUNDLE_DIR)/$(APP_NAME)"
	chmod 0755 "$(BUNDLE_DIR)/$(APP_NAME)"
	$(LDID) -SResources/app.entitlements "$(BUNDLE_DIR)/$(APP_NAME)"
	@echo "==> Packaging TrollStore .tipa & .ipa..."
	cd build && zip -qry PinNhietDo_TS.tipa Payload
	cp "$(OUT_TIPA)" "$(OUT_IPA)"
	@echo "==> Preparing Standalone Map Relay App Bundle ($(MAP_APP_NAME))..."
	mkdir -p "$(MAP_BUNDLE_DIR)"
	cp Resources/Info_BanMap.plist "$(MAP_BUNDLE_DIR)/Info.plist"
	cp Resources/AppIcon60x60@2x.png "$(MAP_BUNDLE_DIR)/"
	cp Resources/AppIcon60x60@3x.png "$(MAP_BUNDLE_DIR)/"
	$(CC) $(CFLAGS) -DMAP_RELAY_STANDALONE=1 $(MAP_HELPER_SRCS) $(APP_FRAMEWORKS) -o "$(MAP_BUNDLE_DIR)/pind"
	chmod 0755 "$(MAP_BUNDLE_DIR)/pind"
	$(LDID) -SResources/daemon.entitlements "$(MAP_BUNDLE_DIR)/pind"
	$(CC) $(CFLAGS) -DMAP_RELAY_STANDALONE=1 $(MAP_APP_SRCS) $(APP_FRAMEWORKS) -o "$(MAP_BUNDLE_DIR)/$(MAP_APP_NAME)"
	chmod 0755 "$(MAP_BUNDLE_DIR)/$(MAP_APP_NAME)"
	$(LDID) -SResources/app.entitlements "$(MAP_BUNDLE_DIR)/$(MAP_APP_NAME)"
	cd build/MapPayload && zip -qry ../BanMap_TS.tipa Payload
	cp "$(OUT_MAP_TIPA)" "$(OUT_MAP_IPA)"
	rm -rf build/MapPayload
	@echo "==> Preparing CoolDash6 iOS 12 Dashcam Bundle ($(DASHCAM_APP_NAME))..."
	mkdir -p "$(DASHCAM_BUNDLE_DIR)"
	cp Resources/Info_CoolDash6.plist "$(DASHCAM_BUNDLE_DIR)/Info.plist"
	cp Resources/AppIcon60x60@2x.png "$(DASHCAM_BUNDLE_DIR)/"
	cp Resources/AppIcon60x60@3x.png "$(DASHCAM_BUNDLE_DIR)/"
	$(CC) $(DASHCAM_CFLAGS) $(DASHCAM_SRCS) $(DASHCAM_FRAMEWORKS) -o "$(DASHCAM_BUNDLE_DIR)/$(DASHCAM_APP_NAME)"
	chmod 0755 "$(DASHCAM_BUNDLE_DIR)/$(DASHCAM_APP_NAME)"
	$(LDID) -SResources/dashcam.entitlements "$(DASHCAM_BUNDLE_DIR)/$(DASHCAM_APP_NAME)"
	cd build/DashcamPayload && zip -qry ../CoolDash6.ipa Payload
	rm -rf build/DashcamPayload
	@echo "==> DONE: $(OUT_TIPA), $(OUT_MAP_TIPA) & $(OUT_DASHCAM_IPA)"

clean:
	rm -rf build
