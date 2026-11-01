#ifndef SharedConfig_h
#define SharedConfig_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#define kAppBundleID            @"com.vn.utility.batterycheck"
#define kCurrentDaemonVersion   @"5.0.1"
#define kConfigPlistPath        @"/var/mobile/Library/Preferences/com.vn.utility.batterycheck.plist"
#define kRuntimeStatePath       @"/var/mobile/Library/Preferences/com.vn.utility.batterycheck.state.plist"
#define kMapRelayQueuePath      @"/var/mobile/Library/Preferences/com.vn.utility.batterycheck.maprelay.plist"
#define kDaemonLogPath          @"/var/mobile/Library/Preferences/com.vn.utility.batterycheck.log"
#define kDaemonPidPath          @"/var/mobile/Library/Preferences/com.vn.utility.batterycheck.pid"
#define kWatchdogPidPath        @"/var/mobile/Library/Preferences/com.vn.utility.batterycheck.watchdog.pid"

#define kNotifyReloadConfig     "com.vn.utility.batterycheck.reload"
#define kNotifyStopDaemon       "com.vn.utility.batterycheck.stop"
#define kNotifyStatsUpdated     "com.vn.utility.batterycheck.stats"
#define kNotifySkipPause        "com.vn.utility.batterycheck.skippause"
#define kNotifyResetCounters    "com.vn.utility.batterycheck.resetcnt"
#define kNotifyDiagCapture      "com.vn.utility.batterycheck.diag"
#define kNotifySendMapRelay     "com.vn.utility.batterycheck.maprelay"

#define kMapRelayViewerBaseURL  @"https://lewe2k6.github.io/vfauto/map.html"

// Native iPhone 8 logical screen points
#define kDefaultScreenW         375.0
#define kDefaultScreenH         667.0

#define kDefaultFoodMallKeywords @"vincom, vincommall, aeon, aeonmall, lotte mall, lottemall, lotte center, lotte centre, lotte dao tan, lotte mart, lottemart, royal city, times city, park hill, big c, bigc, go! thang long, go mall, tops market, top market, topmarket, mega market, the garden, indochina, iph, the loop, keangnam, landmark 72, tasco mall, tascomall, savico, artemis, discovery complex, trang tien plaza, ho guom plaza, mac plaza, machinco, mipec, the zei, tnr tower, sun plaza, cho dong xuan, rox center, ha noi centre, ebest, trung tam thuong mai, tttm, tang ham, ham b1, ham b2, ham b3, gian hang, kiosk, food court, goods court, tang l1, tang l2, tang l3, tang l4, tang l5, 72a nguyen trai, 458 minh khai, 191 ba trieu, 54a nguyen chi thanh, 119 tran duy hung, 222 tran duy hung, 272 vo chi cong, 54 lieu giai, 29 lieu giai, 241 xuan thuy, 27 co linh, 302 cau giay, 236 pham van dong"

#define kDefaultFoodChainKeywords @"phe la, katinat, ca phe muoi chu long, phuc long, koi the, the alley, gong cha, chagee, starbucks, lotteria, kfc, jollibee, mcdonald, popeyes, texas chicken, burger king, pizza 4p, pizza hut, domino, al fresco, the pizza company, pizza home, don chicken, com tho anh nguyen, com suon cay himc, com suon dao duy tu, bami king, kaoya, yu tang, haidilao, dookki, manwah, gogi house, kichi kichi, marukame"

typedef NS_ENUM(NSInteger, CoordMode) {
    CoordModeAutoOCRWithOffset = 0,
    CoordModeFixedManual       = 1
};

@interface InstalledAppInfo : NSObject
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSString *executableName;
@end

@interface RuntimeDaemonState : NSObject
@property (nonatomic, assign) NSInteger statAcceptedCount;
@property (nonatomic, assign) NSInteger statRejectedCount;
@property (nonatomic, assign) double pauseEndEpoch;        // 0 if not pausing
@property (nonatomic, assign) double workerHeartbeatEpoch; // Updated continuously by --worker
@property (nonatomic, copy)   NSString *phaseDescription;
@property (nonatomic, copy)   NSString *daemonVersion;
@property (nonatomic, copy)   NSString *daemonBinaryPath;  // Tracks active TrollStore UUID bundle path
@property (nonatomic, copy)   NSString *lastRelayedSummary;// Latest coordinates/address beamed to peer phone
@property (nonatomic, assign) double lastRelayedEpoch;

+ (instancetype)loadState;
- (void)saveStateAndNotify:(BOOL)sendNotify;
@end

@interface FilterConfig : NSObject

// 1. Master, Price Filter & Smart-Cool Toggles
@property (nonatomic, assign) BOOL masterEnabled;
@property (nonatomic, assign) BOOL autoAcceptBike;             // Auto-accept Bike, Express, Express 2H, etc.
@property (nonatomic, assign) BOOL rejectAllFood;
@property (nonatomic, assign) NSInteger minFoodPriceVND;       // Default 25000
@property (nonatomic, assign) BOOL foodBlockMallAndBasement;   // Default YES (Hard-reject [X] TTTM / Basement / Booth on Pickup)
@property (nonatomic, assign) BOOL foodBlockCrowdedChains;     // Default YES (Hard-reject [X] crowded long-queue chains on Pickup)
@property (nonatomic, assign) NSInteger foodMaxMerchantOrders; // Default 8000 (0 = disabled; Hard-reject if Hanoi DB order_count >= threshold)
@property (nonatomic, copy)   NSString *foodMallKeywords;      // Editable CSV keywords for TTTM / Basement
@property (nonatomic, copy)   NSString *foodChainKeywords;     // Editable CSV keywords for long-queue chains
@property (nonatomic, assign) BOOL foodAcceptLongDistance;     // Default YES ("Một trong hai": clean shop accepts if Price >= min OR Distance > threshold)
@property (nonatomic, assign) double minFoodDistanceKm;        // Default 3.0 km (Pickup -> Dropoff motorbike road distance)
@property (nonatomic, assign) BOOL smartCoolMode;              // Default YES (0% OCR/GPU when outside driver app / locked)
@property (nonatomic, assign) NSInteger tapVerifyRetries;      // Default 2 (closed-loop tap retries if popup remains)
@property (nonatomic, assign) BOOL hapticEnabled;
@property (nonatomic, assign) BOOL dryRunMode;

// 2. 2-Minute Pause & Kill/Relaunch Cycle After Rejecting Food
@property (nonatomic, assign) BOOL pauseAfterRejectFood;       // Default YES
@property (nonatomic, assign) NSInteger pauseDurationSec;      // Default 120 (2 mins)
@property (nonatomic, assign) BOOL autoKillAndRelaunchApp;     // Default NO (user can toggle ON)
@property (nonatomic, assign) NSInteger relaunchLeadSec;       // Default 15s before pause ends
@property (nonatomic, copy)   NSString *driverAppBundleID;     // Auto-detected or user-picked
@property (nonatomic, copy)   NSString *driverAppExecName;
@property (nonatomic, copy)   NSString *driverAppDisplayName;

// 3. Navigation Relay Bridge (iPhone 8 -> Second Phone via ntfy + /map.html)
@property (nonatomic, assign) BOOL mapRelayEnabled;            // Default YES
@property (nonatomic, copy)   NSString *mapRelayTopic;         // Unique secret channel code (e.g. vf-map-8a92k1)
@property (nonatomic, assign) BOOL mapRelayReturnToDriver;     // Default YES (bounce right back to Xanh SM in 0.08s)

// 4. Coordinate Settings (4 Core Buttons: Close X, Accept, Offline Power, Online Start)
@property (nonatomic, assign) CoordMode coordMode;

// Mode 0: Auto OCR Anchor + Offset
@property (nonatomic, assign) double closeXRatio;              // Measured 0.903 (339pt / 375pt)
@property (nonatomic, assign) double closeOffsetX;
@property (nonatomic, assign) double closeOffsetY;
@property (nonatomic, assign) double acceptOffsetX;
@property (nonatomic, assign) double acceptOffsetY;
@property (nonatomic, assign) double onlineOffsetX;
@property (nonatomic, assign) double onlineOffsetY;

// Mode 1: Fixed Manual Coordinates (Measured from real iPhone 8 screenshots)
@property (nonatomic, assign) double manualCloseX;             // Default 339.0
@property (nonatomic, assign) double manualCloseY;             // Default 52.0
@property (nonatomic, assign) double manualAcceptX;            // Default 187.0
@property (nonatomic, assign) double manualAcceptY;            // Default 640.0
@property (nonatomic, assign) double manualOfflineX;           // Default 40.0  (Teal power [Power])
@property (nonatomic, assign) double manualOfflineY;           // Default 455.0
@property (nonatomic, assign) double manualOnlineX;            // Default 187.0 ('Mở nhận chuyến')
@property (nonatomic, assign) double manualOnlineY;            // Default 307.0

// 5. Timing & Humanizer (ms)
@property (nonatomic, assign) NSInteger scanIntervalMs;        // Default 350
@property (nonatomic, assign) NSInteger acceptDelayMinMs;      // Default 180
@property (nonatomic, assign) NSInteger acceptDelayMaxMs;      // Default 420
@property (nonatomic, assign) NSInteger rejectDelayMinMs;      // Default 400
@property (nonatomic, assign) NSInteger rejectDelayMaxMs;      // Default 850
@property (nonatomic, assign) double jitterRadiusPt;           // Default 5.0
@property (nonatomic, assign) NSInteger holdMinMs;             // Default 45
@property (nonatomic, assign) NSInteger holdMaxMs;             // Default 85
@property (nonatomic, assign) NSInteger cooldownMs;            // Default 2500

+ (instancetype)loadFromDisk;
- (void)saveToDiskAndNotify:(BOOL)sendNotify;

@end

// Text normalization helper: lowercase + strip Vietnamese accents + đ->d
static inline NSString *NormalizeVNText(NSString *input) {
    if (!input || input.length == 0) return @"";
    NSMutableString *mutableStr = [input.lowercaseString mutableCopy];
    [mutableStr replaceOccurrencesOfString:@"đ" withString:@"d" options:0 range:NSMakeRange(0, mutableStr.length)];
    CFStringTransform((__bridge CFMutableStringRef)mutableStr, NULL, kCFStringTransformStripCombiningMarks, false);
    return [mutableStr copy];
}

// Daemon, App Lifecycle, Map Relay & System Helpers (implemented in TSUtil.m)
int spawnRoot(NSString *path, NSArray<NSString *> *args);
NSString *resolveLiveAppPindBinaryPath(void);
pid_t getRunningDaemonPID(void);
pid_t getRunningWatchdogPID(void);
BOOL startFilterDaemonIfNeeded(void);
BOOL forceRestartFilterDaemon(void);
void stopFilterDaemon(void);
BOOL readMasterEnabledSafely(BOOL defaultIfUnreadable);
BOOL writeStringUnprotectedAtomically(NSString *str, NSString *path);
void upgradeSharedFilesProtectionNone(void);

NSArray<InstalledAppInfo *> *listInstalledUserApps(void);
InstalledAppInfo *autoDetectDriverApp(void);
BOOL isGoogleMapsInstalledOnDevice(void);
BOOL bundleIDMatchesDriverApp(NSString *bid, FilterConfig *config);
BOOL killAppByBundleIDAndExec(NSString *bundleID, NSString *execName);
BOOL launchAppByBundleID(NSString *bundleID);

NSString *generateRandomMapRelayTopic(void);
NSString *sanitizeMapRelayTopic(NSString *rawTopic);
NSString *buildMapRelayViewerURLString(NSString *topic);
BOOL parseNavigationTargetFromString(NSString *rawInput,
                                     BOOL *outHasCoords,
                                     double *outLat,
                                     double *outLng,
                                     NSString * __strong *outQueryLabel);
void dispatchMapRelayPayloadAsync(double lat,
                                  double lng,
                                  BOOL hasCoords,
                                  NSString *queryLabel,
                                  NSString *sourceTag,
                                  FilterConfig *config,
                                  void (^completion)(BOOL ok, NSString *detail));
BOOL enqueueAndTriggerMapRelayFromURLString(NSString *rawInput,
                                            NSString *sourceTag,
                                            BOOL allowReturnToDriver,
                                            void (^completion)(BOOL ok, NSString *detail));
void processPendingMapRelayQueueIfAny(FilterConfig *config);

NSString *currentFrontmostAppBundleIDForConfig(FilterConfig *config);
void resetFrontmostAppMonitors(void);
BOOL isDeviceScreenLocked(void);
BOOL isLowRAMDevice(void);
uint64_t currentProcessFootprintMB(void);

void appendDaemonLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
NSString *readDaemonLogs(void);
void clearDaemonLogs(void);
void triggerHapticFeedback(BOOL isAccept);

#endif /* SharedConfig_h */
