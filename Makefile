SDK       := $(shell xcrun --sdk iphoneos --show-sdk-path)
CC        := xcrun --sdk iphoneos clang
LDID      := ldid

APP_NAME  := PinNhietDo
BUNDLE_DIR:= build/Payload/$(APP_NAME).app
OUT_TIPA  := build/PinNhietDo_TS.tipa
OUT_IPA   := build/PinNhietDo_TS.ipa

CFLAGS    := -arch arm64 -isysroot $(SDK) -miphoneos-version-min=15.0 -fobjc-arc -O2 \
             -IShared -ISources/App -ISources/Daemon -Wno-deprecated-declarations

APP_SRCS  := Sources/App/main.m \
             Sources/App/StealthBatteryViewController.m \
             Sources/App/SecretConfigViewController.m \
             Sources/App/CoordinatePickerViewController.m \
             Shared/TSUtil.m

DAEMON_SRCS := Sources/Daemon/pind_main.m \
               Sources/Daemon/ScreenTouchEngine.m \
               Sources/Daemon/OrderScanner.m \
               Sources/Daemon/HanoiFoodFilterEngine.m \
               Shared/TSUtil.m

APP_FRAMEWORKS    := -framework Foundation -framework UIKit -framework CoreGraphics \
                     -framework QuartzCore -framework AudioToolbox

DAEMON_FRAMEWORKS := -framework Foundation -framework CoreGraphics \
                     -framework CoreImage -framework QuartzCore \
                     -framework Vision -framework AudioToolbox -lz

.PHONY: all clean

all: $(OUT_TIPA)

$(OUT_TIPA): $(APP_SRCS) $(DAEMON_SRCS) Resources/Info.plist Resources/app.entitlements Resources/daemon.entitlements Resources/hanoi_food_index.zlib
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
	@echo "==> DONE: $(OUT_TIPA)"

clean:
	rm -rf build
