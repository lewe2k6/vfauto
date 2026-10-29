#ifndef SharedConfig_h
#define SharedConfig_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#define kAppBundleID            @"com.vn.utility.batterycheck"
#define kConfigPlistPath        @"/var/mobile/Library/Preferences/com.vn.utility.batterycheck.plist"
#define kDaemonLogPath          @"/var/mobile/Library/Preferences/com.vn.utility.batterycheck.log"
#define kDaemonPidPath          @"/var/mobile/Library/Preferences/com.vn.utility.batterycheck.pid"

#define kNotifyReloadConfig     "com.vn.utility.batterycheck.reload"
#define kNotifyStopDaemon       "com.vn.utility.batterycheck.stop"
#define kNotifyStatsUpdated     "com.vn.utility.batterycheck.stats"

// Default screen dimensions for iPhone 8 (logical points)
#define kDefaultScreenW         375.0
#define kDefaultScreenH         667.0

typedef NS_ENUM(NSInteger, CoordMode) {
    CoordModeAutoOCRWithOffset = 0,
    CoordModeFixedManual       = 1
};

@interface FilterConfig : NSObject

// Master & Tactical Toggles
@property (nonatomic, assign) BOOL masterEnabled;
@property (nonatomic, assign) BOOL autoAcceptBike;
@property (nonatomic, assign) BOOL rejectAllFood;
@property (nonatomic, assign) NSInteger minFoodPriceVND; // e.g., 25000
@property (nonatomic, assign) BOOL hapticEnabled;
@property (nonatomic, assign) BOOL dryRunMode;

// Coordinate Settings
@property (nonatomic, assign) CoordMode coordMode;

// Mode 0: Auto OCR Anchor + Offset
@property (nonatomic, assign) double closeXRatio;       // Default 0.912 (~342pt on 375w)
@property (nonatomic, assign) double closeOffsetX;      // -50 .. +50 pt
@property (nonatomic, assign) double closeOffsetY;      // -50 .. +50 pt
@property (nonatomic, assign) double acceptOffsetX;     // -80 .. +80 pt
@property (nonatomic, assign) double acceptOffsetY;     // -50 .. +50 pt

// Mode 1: Fixed Manual Coordinates (375 x 667 space)
@property (nonatomic, assign) double manualCloseX;      // Default 342.0
@property (nonatomic, assign) double manualCloseY;      // Default 52.0
@property (nonatomic, assign) double manualAcceptX;     // Default 187.5
@property (nonatomic, assign) double manualAcceptY;     // Default 625.0

// Timing & Humanizer (ms)
@property (nonatomic, assign) NSInteger scanIntervalMs; // Default 350
@property (nonatomic, assign) NSInteger acceptDelayMinMs; // Default 180
@property (nonatomic, assign) NSInteger acceptDelayMaxMs; // Default 420
@property (nonatomic, assign) NSInteger rejectDelayMinMs; // Default 400
@property (nonatomic, assign) NSInteger rejectDelayMaxMs; // Default 850
@property (nonatomic, assign) double jitterRadiusPt;    // Default 6.0
@property (nonatomic, assign) NSInteger holdMinMs;      // Default 45
@property (nonatomic, assign) NSInteger holdMaxMs;      // Default 85
@property (nonatomic, assign) NSInteger cooldownMs;     // Default 2500

// Daily Counters
@property (nonatomic, assign) NSInteger statAcceptedCount;
@property (nonatomic, assign) NSInteger statRejectedCount;

+ (instancetype)loadFromDisk;
- (void)saveToDiskAndNotify:(BOOL)sendNotify;
- (void)resetDailyStats;

@end

// Text normalization helper: lowercase + strip Vietnamese accents + đ->d
static inline NSString *NormalizeVNText(NSString *input) {
    if (!input || input.length == 0) return @"";
    NSMutableString *mutableStr = [input.lowercaseString mutableCopy];
    [mutableStr replaceOccurrencesOfString:@"đ" withString:@"d" options:0 range:NSMakeRange(0, mutableStr.length)];
    CFStringTransform((__bridge CFMutableStringRef)mutableStr, NULL, kCFStringTransformStripCombiningMarks, false);
    return [mutableStr copy];
}

// Daemon & System Helpers (implemented in TSUtil.m)
int spawnRoot(NSString *path, NSArray<NSString *> *args);
pid_t getRunningDaemonPID(void);
BOOL startFilterDaemonIfNeeded(void);
void stopFilterDaemon(void);
void appendDaemonLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
NSString *readDaemonLogs(void);
void clearDaemonLogs(void);
void triggerHapticFeedback(BOOL isAccept);

#endif /* SharedConfig_h */
