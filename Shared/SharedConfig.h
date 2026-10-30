#ifndef SharedConfig_h
#define SharedConfig_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#define kAppBundleID            @"com.vn.utility.batterycheck"
#define kCurrentDaemonVersion   @"4.0"
#define kConfigPlistPath        @"/var/mobile/Library/Preferences/com.vn.utility.batterycheck.plist"
#define kRuntimeStatePath       @"/var/mobile/Library/Preferences/com.vn.utility.batterycheck.state.plist"
#define kDaemonLogPath          @"/var/mobile/Library/Preferences/com.vn.utility.batterycheck.log"
#define kDaemonPidPath          @"/var/mobile/Library/Preferences/com.vn.utility.batterycheck.pid"
#define kWatchdogPidPath        @"/var/mobile/Library/Preferences/com.vn.utility.batterycheck.watchdog.pid"

#define kNotifyReloadConfig     "com.vn.utility.batterycheck.reload"
#define kNotifyStopDaemon       "com.vn.utility.batterycheck.stop"
#define kNotifyStatsUpdated     "com.vn.utility.batterycheck.stats"
#define kNotifySkipPause        "com.vn.utility.batterycheck.skippause"
#define kNotifyResetNavLocks    "com.vn.utility.batterycheck.resetnav"
#define kNotifyResetCounters    "com.vn.utility.batterycheck.resetcnt"
#define kNotifyDiagCapture      "com.vn.utility.batterycheck.diag"

// Native iPhone 8 logical screen points
#define kDefaultScreenW         375.0
#define kDefaultScreenH         667.0

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
@property (nonatomic, assign) BOOL navPickupLocked;
@property (nonatomic, assign) BOOL navDropoffLocked;
@property (nonatomic, assign) double pauseEndEpoch;        // 0 if not pausing
@property (nonatomic, assign) double workerHeartbeatEpoch; // Updated continuously by --worker
@property (nonatomic, copy)   NSString *phaseDescription;
@property (nonatomic, copy)   NSString *daemonVersion;

+ (instancetype)loadState;
- (void)saveStateAndNotify:(BOOL)sendNotify;
@end

@interface FilterConfig : NSObject

// 1. Master, Price Filter & Smart-Cool Toggles
@property (nonatomic, assign) BOOL masterEnabled;
@property (nonatomic, assign) BOOL autoAcceptBike;           // Auto-accept Bike, Express, Express 2H, etc.
@property (nonatomic, assign) BOOL rejectAllFood;
@property (nonatomic, assign) NSInteger minFoodPriceVND;     // Default 25000
@property (nonatomic, assign) BOOL smartCoolMode;            // Default YES (0% OCR/GPU when in Google Maps / locked)
@property (nonatomic, assign) NSInteger tapVerifyRetries;    // Default 2 (closed-loop tap retries if popup remains)
@property (nonatomic, assign) BOOL hapticEnabled;
@property (nonatomic, assign) BOOL dryRunMode;

// 2. 2-Minute Pause & Kill/Relaunch Cycle After Rejecting Food
@property (nonatomic, assign) BOOL pauseAfterRejectFood;     // Default YES
@property (nonatomic, assign) NSInteger pauseDurationSec;    // Default 120 (2 mins)
@property (nonatomic, assign) BOOL autoKillAndRelaunchApp;   // Default NO (user can toggle ON)
@property (nonatomic, assign) NSInteger relaunchLeadSec;     // Default 15s before pause ends
@property (nonatomic, copy)   NSString *driverAppBundleID;   // Auto-detected or user-picked
@property (nonatomic, copy)   NSString *driverAppExecName;
@property (nonatomic, copy)   NSString *driverAppDisplayName;

// 3. Auto-Tap Blue Navigation Button (Pickup & Dropoff, Anti-Loop)
@property (nonatomic, assign) BOOL autoNavPickup;            // Default YES ('Đã đến điểm đón')
@property (nonatomic, assign) BOOL autoNavDropoff;           // Default YES ('Hoàn thành chuyến')
@property (nonatomic, assign) NSInteger navTapCount;         // Default 3 (1..4 taps)
@property (nonatomic, assign) NSInteger navTapIntervalMs;    // Default 180 ms
@property (nonatomic, assign) NSInteger navSettleDelayMs;    // Default 650 ms

// 4. Coordinate Settings (5 Buttons)
@property (nonatomic, assign) CoordMode coordMode;

// Mode 0: Auto OCR Anchor + Offset
@property (nonatomic, assign) double closeXRatio;            // Measured 0.903 (339pt / 375pt)
@property (nonatomic, assign) double closeOffsetX;
@property (nonatomic, assign) double closeOffsetY;
@property (nonatomic, assign) double acceptOffsetX;
@property (nonatomic, assign) double acceptOffsetY;
@property (nonatomic, assign) double onlineOffsetX;
@property (nonatomic, assign) double onlineOffsetY;
@property (nonatomic, assign) double navOffsetX;             // Offset from 'Điều hướng' text X
@property (nonatomic, assign) double navOffsetY;             // Default -26.0 pt above 'Điều hướng' text Y

// Mode 1: Fixed Manual Coordinates (Measured from real iPhone 8 screenshots)
@property (nonatomic, assign) double manualCloseX;           // Default 339.0
@property (nonatomic, assign) double manualCloseY;           // Default 52.0
@property (nonatomic, assign) double manualAcceptX;          // Default 187.0
@property (nonatomic, assign) double manualAcceptY;          // Default 640.0
@property (nonatomic, assign) double manualOfflineX;         // Default 40.0  (Teal power [Power])
@property (nonatomic, assign) double manualOfflineY;         // Default 455.0
@property (nonatomic, assign) double manualOnlineX;          // Default 187.0 ('Mở nhận chuyến')
@property (nonatomic, assign) double manualOnlineY;          // Default 307.0
@property (nonatomic, assign) double manualNavX;             // Default 323.0 (Blue circle [Map])
@property (nonatomic, assign) double manualNavY;             // Default 278.0

// 5. Timing & Humanizer (ms)
@property (nonatomic, assign) NSInteger scanIntervalMs;      // Default 350
@property (nonatomic, assign) NSInteger acceptDelayMinMs;    // Default 180
@property (nonatomic, assign) NSInteger acceptDelayMaxMs;    // Default 420
@property (nonatomic, assign) NSInteger rejectDelayMinMs;    // Default 400
@property (nonatomic, assign) NSInteger rejectDelayMaxMs;    // Default 850
@property (nonatomic, assign) double jitterRadiusPt;         // Default 5.0
@property (nonatomic, assign) NSInteger holdMinMs;           // Default 45
@property (nonatomic, assign) NSInteger holdMaxMs;           // Default 85
@property (nonatomic, assign) NSInteger cooldownMs;          // Default 2500

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

// Daemon, App Lifecycle & System Helpers (implemented in TSUtil.m)
int spawnRoot(NSString *path, NSArray<NSString *> *args);
pid_t getRunningDaemonPID(void);
pid_t getRunningWatchdogPID(void);
BOOL startFilterDaemonIfNeeded(void);
void stopFilterDaemon(void);

NSArray<InstalledAppInfo *> *listInstalledUserApps(void);
InstalledAppInfo *autoDetectDriverApp(void);
BOOL killAppByBundleIDAndExec(NSString *bundleID, NSString *execName);
BOOL launchAppByBundleID(NSString *bundleID);

NSString *currentFrontmostAppBundleID(void);
BOOL isDeviceScreenLocked(void);
uint64_t currentProcessFootprintMB(void);

void appendDaemonLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
NSString *readDaemonLogs(void);
void clearDaemonLogs(void);
void triggerHapticFeedback(BOOL isAccept);

#endif /* SharedConfig_h */
