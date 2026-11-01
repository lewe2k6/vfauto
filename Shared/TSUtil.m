#import "SharedConfig.h"
#import <AudioToolbox/AudioToolbox.h>
#import <mach/mach.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <spawn.h>
#import <signal.h>
#import <notify.h>
#import <fcntl.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <sys/wait.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>

#ifndef SZOMB
#define SZOMB 5
#endif

#ifndef POSIX_SPAWN_CLOEXEC_DEFAULT
#define POSIX_SPAWN_CLOEXEC_DEFAULT 0x4000
#endif

#ifndef F_SETPROTECTIONCLASS
#define F_SETPROTECTIONCLASS 64
#endif

#ifndef PROTECTION_CLASS_D
#define PROTECTION_CLASS_D 4
#endif

#define kDaemonControlLockPath "/var/mobile/Library/Preferences/com.vn.utility.batterycheck.ctl.lock"

#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
typedef int (*persona_np_f)(const posix_spawnattr_t * __restrict, uid_t, uint32_t);
typedef int (*persona_id_f)(const posix_spawnattr_t * __restrict, uid_t);
typedef void (*BKSTerminateApp_f)(CFStringRef bundleID, int reasonID, bool report, CFStringRef description);
typedef int (*SBSLaunchApp_f)(CFStringRef bundleID, Boolean suspended);
typedef CFStringRef (*SBSCopyFrontmostApp_f)(void);
extern char **environ;

@implementation InstalledAppInfo
@end

#pragma mark - Lock-Screen Safe (PROTECTION_CLASS_D) Atomic File I/O

static void markFileProtectionNone(const char *cPath) {
    if (!cPath || cPath[0] == '\0') return;
    int fd = open(cPath, O_RDWR);
    if (fd < 0) {
        fd = open(cPath, O_RDONLY);
    }
    if (fd >= 0) {
        fcntl(fd, F_SETPROTECTIONCLASS, PROTECTION_CLASS_D);
        close(fd);
    }
    if (geteuid() == 0) {
        chown(cPath, 501, 501);
    }
    chmod(cPath, 0666);
}

static BOOL writeDictUnprotectedAtomically(NSDictionary *dict, NSString *path) {
    if (!dict || !path || path.length == 0) return NO;
    NSError *err = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:dict
                                                              format:NSPropertyListBinaryFormat_v1_0
                                                             options:0
                                                               error:&err];
    if (!data || err) return NO;

    BOOL ok = [data writeToFile:path
                        options:(NSDataWritingAtomic | NSDataWritingFileProtectionNone)
                          error:nil];
    if (!ok) {
        ok = [data writeToFile:path options:NSDataWritingAtomic error:nil];
    }
    markFileProtectionNone([path fileSystemRepresentation]);
    return ok;
}

BOOL writeStringUnprotectedAtomically(NSString *str, NSString *path) {
    if (!path || path.length == 0) return NO;
    NSData *data = [(str ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return NO;

    BOOL ok = [data writeToFile:path
                        options:(NSDataWritingAtomic | NSDataWritingFileProtectionNone)
                          error:nil];
    if (!ok) {
        ok = [data writeToFile:path options:NSDataWritingAtomic error:nil];
    }
    markFileProtectionNone([path fileSystemRepresentation]);
    return ok;
}

void upgradeSharedFilesProtectionNone(void) {
    NSArray<NSString *> *paths = @[
        kConfigPlistPath,
        kRuntimeStatePath,
        kDaemonLogPath,
        kDaemonPidPath,
        kWatchdogPidPath
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in paths) {
        const char *cPath = [p fileSystemRepresentation];
        if (cPath && access(cPath, F_OK) == 0) {
            [fm setAttributes:@{ NSFileProtectionKey: NSFileProtectionNone } ofItemAtPath:p error:nil];
            markFileProtectionNone(cPath);
        }
    }
}

static NSDictionary *readDictSafelyWithRetry(NSString *path) {
    if (!path || path.length == 0) return nil;
    const char *cPath = [path fileSystemRepresentation];
    if (!cPath || (access(cPath, F_OK) != 0 && errno == ENOENT)) {
        return nil;
    }

    for (int attempt = 0; attempt < 4; attempt++) {
        if (attempt > 0) {
            usleep(18000);
        }
        NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingUncached error:nil];
        if (data.length > 0) {
            id obj = [NSPropertyListSerialization propertyListWithData:data
                                                               options:NSPropertyListImmutable
                                                                format:NULL
                                                                 error:nil];
            if ([obj isKindOfClass:[NSDictionary class]]) {
                return (NSDictionary *)obj;
            }
        }
        NSDictionary *fallback = [NSDictionary dictionaryWithContentsOfFile:path];
        if ([fallback isKindOfClass:[NSDictionary class]]) {
            return fallback;
        }
    }
    return nil;
}

BOOL readMasterEnabledSafely(BOOL defaultIfUnreadable) {
    const char *cPath = [kConfigPlistPath fileSystemRepresentation];
    if (!cPath) return NO;
    if (access(cPath, F_OK) != 0) {
        if (errno == ENOENT) {
            return NO;
        }
        return defaultIfUnreadable;
    }
    NSDictionary *dict = readDictSafelyWithRetry(kConfigPlistPath);
    if (!dict) {
        // File exists on disk, so a nil dictionary means transient lock/I/O contention — NEVER kill Watchdog!
        return defaultIfUnreadable;
    }
    id val = dict[@"masterEnabled"];
    return val ? [val boolValue] : NO;
}

@implementation RuntimeDaemonState

- (instancetype)init {
    self = [super init];
    if (self) {
        _statAcceptedCount    = 0;
        _statRejectedCount    = 0;
        _navPickupLocked      = NO;
        _navDropoffLocked     = NO;
        _pauseEndEpoch        = 0.0;
        _workerHeartbeatEpoch = 0.0;
        _phaseDescription     = @"Đang rảnh / Canh đơn";
        _daemonVersion        = @"";
    }
    return self;
}

+ (instancetype)loadState {
    RuntimeDaemonState *st = [[RuntimeDaemonState alloc] init];
    NSDictionary *d = readDictSafelyWithRetry(kRuntimeStatePath);
    if (!d) return st;
    if (d[@"statAcceptedCount"])    st.statAcceptedCount    = [d[@"statAcceptedCount"] integerValue];
    if (d[@"statRejectedCount"])    st.statRejectedCount    = [d[@"statRejectedCount"] integerValue];
    if (d[@"navPickupLocked"])      st.navPickupLocked      = [d[@"navPickupLocked"] boolValue];
    if (d[@"navDropoffLocked"])     st.navDropoffLocked     = [d[@"navDropoffLocked"] boolValue];
    if (d[@"pauseEndEpoch"])        st.pauseEndEpoch        = [d[@"pauseEndEpoch"] doubleValue];
    if (d[@"workerHeartbeatEpoch"]) st.workerHeartbeatEpoch = [d[@"workerHeartbeatEpoch"] doubleValue];
    if (d[@"phaseDescription"])     st.phaseDescription     = d[@"phaseDescription"];
    if (d[@"daemonVersion"])        st.daemonVersion        = d[@"daemonVersion"];
    return st;
}

- (void)saveStateAndNotify:(BOOL)sendNotify {
    NSDictionary *d = @{
        @"statAcceptedCount":    @(self.statAcceptedCount),
        @"statRejectedCount":    @(self.statRejectedCount),
        @"navPickupLocked":      @(self.navPickupLocked),
        @"navDropoffLocked":     @(self.navDropoffLocked),
        @"pauseEndEpoch":        @(self.pauseEndEpoch),
        @"workerHeartbeatEpoch": @(self.workerHeartbeatEpoch),
        @"phaseDescription":     self.phaseDescription ?: @"",
        @"daemonVersion":        self.daemonVersion ?: @""
    };
    writeDictUnprotectedAtomically(d, kRuntimeStatePath);
    if (sendNotify) {
        notify_post(kNotifyStatsUpdated);
    }
}

@end

@implementation FilterConfig

- (instancetype)init {
    self = [super init];
    if (self) {
        _masterEnabled          = NO;
        _autoAcceptBike         = YES;
        _rejectAllFood          = NO;
        _minFoodPriceVND        = 25000;
        _foodBlockMallAndBasement = YES;
        _foodBlockCrowdedChains   = YES;
        _foodMaxMerchantOrders    = 8000;
        _foodMallKeywords         = kDefaultFoodMallKeywords;
        _foodChainKeywords        = kDefaultFoodChainKeywords;
        _foodAcceptLongDistance   = YES;
        _minFoodDistanceKm        = 3.0;
        _smartCoolMode          = YES;
        _tapVerifyRetries       = 2;
        _hapticEnabled          = YES;
        _dryRunMode             = NO;

        _pauseAfterRejectFood   = YES;
        _pauseDurationSec       = 120; // 2 minutes
        _autoKillAndRelaunchApp = NO;
        _relaunchLeadSec        = 15;
        _driverAppBundleID      = @"";
        _driverAppExecName      = @"";
        _driverAppDisplayName   = @"Tự động dò Xanh SM";

        _autoNavPickup          = YES;
        _autoNavDropoff         = YES;
        _navTapCount            = 3;
        _navTapIntervalMs       = 180;
        _navSettleDelayMs       = 650;

        _coordMode              = CoordModeAutoOCRWithOffset;
        _closeXRatio            = 0.903; // 338.6 / 375.0 measured on iPhone 8
        _closeOffsetX           = 0.0;
        _closeOffsetY           = 0.0;
        _acceptOffsetX          = 0.0;
        _acceptOffsetY          = 0.0;
        _onlineOffsetX          = 0.0;
        _onlineOffsetY          = 0.0;
        _navOffsetX             = 0.0;
        _navOffsetY             = -26.0; // Blue circle center is 26pt above 'Điều hướng' text

        // Exact coordinates measured from real iPhone 8 (375 x 667 pt) screenshots
        _manualCloseX           = 339.0;
        _manualCloseY           = 52.0;
        _manualAcceptX          = 187.0;
        _manualAcceptY          = 640.0;
        _manualOfflineX         = 40.0;
        _manualOfflineY         = 455.0;
        _manualOnlineX          = 187.0;
        _manualOnlineY          = 307.0;
        _manualNavX             = 323.0;
        _manualNavY             = 278.0;

        _scanIntervalMs         = 350;
        _acceptDelayMinMs       = 180;
        _acceptDelayMaxMs       = 420;
        _rejectDelayMinMs       = 400;
        _rejectDelayMaxMs       = 850;
        _jitterRadiusPt         = 5.0;
        _holdMinMs              = 45;
        _holdMaxMs              = 85;
        _cooldownMs             = 2500;
    }
    return self;
}

+ (instancetype)loadFromDisk {
    FilterConfig *cfg = [[FilterConfig alloc] init];
    NSDictionary *dict = readDictSafelyWithRetry(kConfigPlistPath);
    if (!dict) {
        const char *cPath = [kConfigPlistPath fileSystemRepresentation];
        if (cPath && access(cPath, F_OK) == 0) {
            // Existing config file had a momentary lock/I/O contention -> keep Master ON safely!
            cfg.masterEnabled = YES;
        }
        if (geteuid() != 0) {
            InstalledAppInfo *detected = autoDetectDriverApp();
            if (detected) {
                cfg.driverAppBundleID    = detected.bundleID;
                cfg.driverAppExecName    = detected.executableName;
                cfg.driverAppDisplayName = detected.displayName;
            }
        }
        return cfg;
    }

    if (dict[@"masterEnabled"])          cfg.masterEnabled          = [dict[@"masterEnabled"] boolValue];
    if (dict[@"autoAcceptBike"])         cfg.autoAcceptBike         = [dict[@"autoAcceptBike"] boolValue];
    if (dict[@"rejectAllFood"])          cfg.rejectAllFood          = [dict[@"rejectAllFood"] boolValue];
    if (dict[@"minFoodPriceVND"])        cfg.minFoodPriceVND        = [dict[@"minFoodPriceVND"] integerValue];
    if (dict[@"foodBlockMallAndBasement"]) cfg.foodBlockMallAndBasement = [dict[@"foodBlockMallAndBasement"] boolValue];
    if (dict[@"foodBlockCrowdedChains"])   cfg.foodBlockCrowdedChains   = [dict[@"foodBlockCrowdedChains"] boolValue];
    if (dict[@"foodMaxMerchantOrders"])    cfg.foodMaxMerchantOrders    = [dict[@"foodMaxMerchantOrders"] integerValue];
    if ([dict[@"foodMallKeywords"] isKindOfClass:[NSString class]]) {
        cfg.foodMallKeywords = dict[@"foodMallKeywords"];
    }
    if ([dict[@"foodChainKeywords"] isKindOfClass:[NSString class]]) {
        cfg.foodChainKeywords = dict[@"foodChainKeywords"];
    }
    if (dict[@"foodAcceptLongDistance"])   cfg.foodAcceptLongDistance   = [dict[@"foodAcceptLongDistance"] boolValue];
    if (dict[@"minFoodDistanceKm"])        cfg.minFoodDistanceKm        = [dict[@"minFoodDistanceKm"] doubleValue];
    if (dict[@"smartCoolMode"])          cfg.smartCoolMode          = [dict[@"smartCoolMode"] boolValue];
    if (dict[@"tapVerifyRetries"])       cfg.tapVerifyRetries       = [dict[@"tapVerifyRetries"] integerValue];
    if (dict[@"hapticEnabled"])          cfg.hapticEnabled          = [dict[@"hapticEnabled"] boolValue];
    if (dict[@"dryRunMode"])             cfg.dryRunMode             = [dict[@"dryRunMode"] boolValue];

    if (dict[@"pauseAfterRejectFood"])   cfg.pauseAfterRejectFood   = [dict[@"pauseAfterRejectFood"] boolValue];
    if (dict[@"pauseDurationSec"])       cfg.pauseDurationSec       = [dict[@"pauseDurationSec"] integerValue];
    if (dict[@"autoKillAndRelaunchApp"]) cfg.autoKillAndRelaunchApp = [dict[@"autoKillAndRelaunchApp"] boolValue];
    if (dict[@"relaunchLeadSec"])        cfg.relaunchLeadSec        = [dict[@"relaunchLeadSec"] integerValue];
    if (dict[@"driverAppBundleID"])      cfg.driverAppBundleID      = dict[@"driverAppBundleID"];
    if (dict[@"driverAppExecName"])      cfg.driverAppExecName      = dict[@"driverAppExecName"];
    if (dict[@"driverAppDisplayName"])   cfg.driverAppDisplayName   = dict[@"driverAppDisplayName"];

    if (dict[@"autoNavPickup"])          cfg.autoNavPickup          = [dict[@"autoNavPickup"] boolValue];
    if (dict[@"autoNavDropoff"])         cfg.autoNavDropoff         = [dict[@"autoNavDropoff"] boolValue];
    if (dict[@"navTapCount"])            cfg.navTapCount            = [dict[@"navTapCount"] integerValue];
    if (dict[@"navTapIntervalMs"])       cfg.navTapIntervalMs       = [dict[@"navTapIntervalMs"] integerValue];
    if (dict[@"navSettleDelayMs"])       cfg.navSettleDelayMs       = [dict[@"navSettleDelayMs"] integerValue];

    if (dict[@"coordMode"])              cfg.coordMode              = (CoordMode)[dict[@"coordMode"] integerValue];
    if (dict[@"closeXRatio"])            cfg.closeXRatio            = [dict[@"closeXRatio"] doubleValue];
    if (dict[@"closeOffsetX"])           cfg.closeOffsetX           = [dict[@"closeOffsetX"] doubleValue];
    if (dict[@"closeOffsetY"])           cfg.closeOffsetY           = [dict[@"closeOffsetY"] doubleValue];
    if (dict[@"acceptOffsetX"])          cfg.acceptOffsetX          = [dict[@"acceptOffsetX"] doubleValue];
    if (dict[@"acceptOffsetY"])          cfg.acceptOffsetY          = [dict[@"acceptOffsetY"] doubleValue];
    if (dict[@"onlineOffsetX"])          cfg.onlineOffsetX          = [dict[@"onlineOffsetX"] doubleValue];
    if (dict[@"onlineOffsetY"])          cfg.onlineOffsetY          = [dict[@"onlineOffsetY"] doubleValue];
    if (dict[@"navOffsetX"])             cfg.navOffsetX             = [dict[@"navOffsetX"] doubleValue];
    if (dict[@"navOffsetY"])             cfg.navOffsetY             = [dict[@"navOffsetY"] doubleValue];

    if (dict[@"manualCloseX"])           cfg.manualCloseX           = [dict[@"manualCloseX"] doubleValue];
    if (dict[@"manualCloseY"])           cfg.manualCloseY           = [dict[@"manualCloseY"] doubleValue];
    if (dict[@"manualAcceptX"])          cfg.manualAcceptX          = [dict[@"manualAcceptX"] doubleValue];
    if (dict[@"manualAcceptY"])          cfg.manualAcceptY          = [dict[@"manualAcceptY"] doubleValue];
    if (dict[@"manualOfflineX"])         cfg.manualOfflineX         = [dict[@"manualOfflineX"] doubleValue];
    if (dict[@"manualOfflineY"])         cfg.manualOfflineY         = [dict[@"manualOfflineY"] doubleValue];
    if (dict[@"manualOnlineX"])          cfg.manualOnlineX          = [dict[@"manualOnlineX"] doubleValue];
    if (dict[@"manualOnlineY"])          cfg.manualOnlineY          = [dict[@"manualOnlineY"] doubleValue];
    if (dict[@"manualNavX"])             cfg.manualNavX             = [dict[@"manualNavX"] doubleValue];
    if (dict[@"manualNavY"])             cfg.manualNavY             = [dict[@"manualNavY"] doubleValue];

    if (dict[@"scanIntervalMs"])         cfg.scanIntervalMs         = [dict[@"scanIntervalMs"] integerValue];
    if (dict[@"acceptDelayMinMs"])       cfg.acceptDelayMinMs       = [dict[@"acceptDelayMinMs"] integerValue];
    if (dict[@"acceptDelayMaxMs"])       cfg.acceptDelayMaxMs       = [dict[@"acceptDelayMaxMs"] integerValue];
    if (dict[@"rejectDelayMinMs"])       cfg.rejectDelayMinMs       = [dict[@"rejectDelayMinMs"] integerValue];
    if (dict[@"rejectDelayMaxMs"])       cfg.rejectDelayMaxMs       = [dict[@"rejectDelayMaxMs"] integerValue];
    if (dict[@"jitterRadiusPt"])         cfg.jitterRadiusPt         = [dict[@"jitterRadiusPt"] doubleValue];
    if (dict[@"holdMinMs"])              cfg.holdMinMs              = [dict[@"holdMinMs"] integerValue];
    if (dict[@"holdMaxMs"])              cfg.holdMaxMs              = [dict[@"holdMaxMs"] integerValue];
    if (dict[@"cooldownMs"])             cfg.cooldownMs             = [dict[@"cooldownMs"] integerValue];

    if (geteuid() != 0 && (cfg.driverAppBundleID.length == 0 || cfg.driverAppExecName.length == 0)) {
        InstalledAppInfo *matched = nil;
        if (cfg.driverAppBundleID.length > 0) {
            for (InstalledAppInfo *app in listInstalledUserApps()) {
                if ([app.bundleID isEqualToString:cfg.driverAppBundleID]) {
                    matched = app;
                    break;
                }
            }
        }
        if (!matched) {
            matched = autoDetectDriverApp();
        }
        if (matched) {
            if (cfg.driverAppBundleID.length == 0)    cfg.driverAppBundleID    = matched.bundleID;
            if (cfg.driverAppExecName.length == 0)    cfg.driverAppExecName    = matched.executableName;
            if (cfg.driverAppDisplayName.length == 0 || [cfg.driverAppDisplayName isEqualToString:@"Tự động dò Xanh SM"]) {
                cfg.driverAppDisplayName = matched.displayName;
            }
        }
    }

    if (cfg.acceptDelayMaxMs < cfg.acceptDelayMinMs) cfg.acceptDelayMaxMs = cfg.acceptDelayMinMs + 50;
    if (cfg.rejectDelayMaxMs < cfg.rejectDelayMinMs) cfg.rejectDelayMaxMs = cfg.rejectDelayMinMs + 50;
    if (cfg.holdMaxMs < cfg.holdMinMs) cfg.holdMaxMs = cfg.holdMinMs + 15;
    if (cfg.scanIntervalMs < 150) cfg.scanIntervalMs = 150;
    if (cfg.pauseDurationSec < 20) cfg.pauseDurationSec = 20;
    if (cfg.navTapCount < 1) cfg.navTapCount = 1;
    if (cfg.navTapCount > 5) cfg.navTapCount = 5;
    if (cfg.tapVerifyRetries < 0) cfg.tapVerifyRetries = 0;
    if (cfg.tapVerifyRetries > 4) cfg.tapVerifyRetries = 4;
    if (cfg.foodMaxMerchantOrders < 0) cfg.foodMaxMerchantOrders = 0;
    if (cfg.foodMaxMerchantOrders > 200000) cfg.foodMaxMerchantOrders = 200000;
    if (cfg.minFoodDistanceKm < 0.5) cfg.minFoodDistanceKm = 0.5;
    if (cfg.minFoodDistanceKm > 25.0) cfg.minFoodDistanceKm = 25.0;

    return cfg;
}

- (void)saveToDiskAndNotify:(BOOL)sendNotify {
    NSDictionary *dict = @{
        @"masterEnabled":          @(self.masterEnabled),
        @"autoAcceptBike":         @(self.autoAcceptBike),
        @"rejectAllFood":          @(self.rejectAllFood),
        @"minFoodPriceVND":        @(self.minFoodPriceVND),
        @"foodBlockMallAndBasement": @(self.foodBlockMallAndBasement),
        @"foodBlockCrowdedChains":   @(self.foodBlockCrowdedChains),
        @"foodMaxMerchantOrders":    @(self.foodMaxMerchantOrders),
        @"foodMallKeywords":         self.foodMallKeywords ?: kDefaultFoodMallKeywords,
        @"foodChainKeywords":        self.foodChainKeywords ?: kDefaultFoodChainKeywords,
        @"foodAcceptLongDistance":   @(self.foodAcceptLongDistance),
        @"minFoodDistanceKm":        @(self.minFoodDistanceKm),
        @"smartCoolMode":          @(self.smartCoolMode),
        @"tapVerifyRetries":       @(self.tapVerifyRetries),
        @"hapticEnabled":          @(self.hapticEnabled),
        @"dryRunMode":             @(self.dryRunMode),

        @"pauseAfterRejectFood":   @(self.pauseAfterRejectFood),
        @"pauseDurationSec":       @(self.pauseDurationSec),
        @"autoKillAndRelaunchApp": @(self.autoKillAndRelaunchApp),
        @"relaunchLeadSec":        @(self.relaunchLeadSec),
        @"driverAppBundleID":      self.driverAppBundleID ?: @"",
        @"driverAppExecName":      self.driverAppExecName ?: @"",
        @"driverAppDisplayName":   self.driverAppDisplayName ?: @"",

        @"autoNavPickup":          @(self.autoNavPickup),
        @"autoNavDropoff":         @(self.autoNavDropoff),
        @"navTapCount":            @(self.navTapCount),
        @"navTapIntervalMs":       @(self.navTapIntervalMs),
        @"navSettleDelayMs":       @(self.navSettleDelayMs),

        @"coordMode":              @(self.coordMode),
        @"closeXRatio":            @(self.closeXRatio),
        @"closeOffsetX":           @(self.closeOffsetX),
        @"closeOffsetY":           @(self.closeOffsetY),
        @"acceptOffsetX":          @(self.acceptOffsetX),
        @"acceptOffsetY":          @(self.acceptOffsetY),
        @"onlineOffsetX":          @(self.onlineOffsetX),
        @"onlineOffsetY":          @(self.onlineOffsetY),
        @"navOffsetX":             @(self.navOffsetX),
        @"navOffsetY":             @(self.navOffsetY),

        @"manualCloseX":           @(self.manualCloseX),
        @"manualCloseY":           @(self.manualCloseY),
        @"manualAcceptX":          @(self.manualAcceptX),
        @"manualAcceptY":          @(self.manualAcceptY),
        @"manualOfflineX":         @(self.manualOfflineX),
        @"manualOfflineY":         @(self.manualOfflineY),
        @"manualOnlineX":          @(self.manualOnlineX),
        @"manualOnlineY":          @(self.manualOnlineY),
        @"manualNavX":             @(self.manualNavX),
        @"manualNavY":             @(self.manualNavY),

        @"scanIntervalMs":         @(self.scanIntervalMs),
        @"acceptDelayMinMs":       @(self.acceptDelayMinMs),
        @"acceptDelayMaxMs":       @(self.acceptDelayMaxMs),
        @"rejectDelayMinMs":       @(self.rejectDelayMinMs),
        @"rejectDelayMaxMs":       @(self.rejectDelayMaxMs),
        @"jitterRadiusPt":         @(self.jitterRadiusPt),
        @"holdMinMs":              @(self.holdMinMs),
        @"holdMaxMs":              @(self.holdMaxMs),
        @"cooldownMs":             @(self.cooldownMs)
    };

    writeDictUnprotectedAtomically(dict, kConfigPlistPath);

    if (sendNotify) {
        notify_post(kNotifyReloadConfig);
    }
}

@end

#pragma mark - Frontmost App, Screen Lock & Memory Footprint Helpers

static BOOL bundleIDMatchesDriverOrAllowed(NSString *bid, FilterConfig *config) {
    if (!bid || bid.length == 0) return NO;
    if (config && config.driverAppBundleID.length > 0) {
        if ([bid isEqualToString:config.driverAppBundleID] ||
            [bid rangeOfString:config.driverAppBundleID options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    NSString *lower = bid.lowercaseString;
    if ([lower containsString:@"gsm"] ||
        [lower containsString:@"xanhsm"] ||
        [lower containsString:@"greensm"] ||
        [lower containsString:@"xanh.sm"] ||
        [lower containsString:@"green.sm"] ||
        [lower containsString:@"vinfast"]) {
        return YES;
    }
    if (config && config.dryRunMode && [lower containsString:@"com.apple.mobileslideshow"]) {
        return YES;
    }
    return NO;
}

static BOOL isSystemOverlayIdentifier(NSString *ident) {
    if (!ident || ident.length == 0) return YES;
    NSString *lower = ident.lowercaseString;
    if ([lower isEqualToString:@"com.apple.springboard"]) {
        return NO; // Real home screen
    }
    NSArray<NSString *> *overlays = @[
        @"accessibilityuiserver",
        @"assistivetouch",
        @"inputui",
        @"textinput",
        @"bannerkit",
        @"druid",
        @"posterboard",
        @"systemaperture",
        @"passbookuiservice",
        @"coreauthui",
        @"siri",
        @"status-bar",
        @"statusbar",
        @"control-center",
        @"controlcenter",
        @"cover-sheet",
        @"coversheet",
        @"passcodelock",
        @"screenshotservices",
        @"pip",
        @"universalcontrol",
        @"carplay",
        @"springboard." // e.g. com.apple.springboard.status-bar
    ];
    for (NSString *ov in overlays) {
        if ([lower containsString:ov]) {
            return YES;
        }
    }
    return NO;
}

static NSString *normalizeSceneIdentifierToBundleID(NSString *raw) {
    if (!raw || raw.length == 0) return nil;
    if ([raw containsString:@"com.google.Maps"]) {
        return @"com.google.Maps";
    }
    NSString *s = raw;
    if ([s hasPrefix:@"sceneID:"]) {
        s = [s substringFromIndex:8];
        NSRange defRange = [s rangeOfString:@"-default" options:NSBackwardsSearch];
        if (defRange.location != NSNotFound) {
            s = [s substringToIndex:defRange.location];
        } else {
            NSRange dashRange = [s rangeOfString:@"-" options:NSBackwardsSearch];
            if (dashRange.location != NSNotFound && dashRange.location > 3) {
                s = [s substringToIndex:dashRange.location];
            }
        }
    }
    return s;
}

static NSRecursiveLock *frontMonitorLock(void) {
    static NSRecursiveLock *sLock = nil;
    static dispatch_once_t onceTok;
    dispatch_once(&onceTok, ^{
        sLock = [[NSRecursiveLock alloc] init];
        dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_LAZY);
        dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_LAZY);
    });
    return sLock;
}

static id gLayoutMonitor       = nil;
static id gLatestLayout        = nil;
static NSTimeInterval gLatestLayoutUp = 0.0;
static NSTimeInterval gLastLayoutInitUp = 0.0;
static int gNilLayoutStreak    = 0;

static id gAppStateMonitor     = nil;
static NSTimeInterval gLastBKSInitUp = 0.0;

static void invalidateMonitorSafely(id mon) {
    if (!mon) return;
    SEL invSel = NSSelectorFromString(@"invalidate");
    if ([mon respondsToSelector:invSel]) {
        @try {
            ((void (*)(id, SEL))objc_msgSend)(mon, invSel);
        } @catch (NSException *ex) {}
    }
}

void resetFrontmostAppMonitors(void) {
    NSRecursiveLock *lk = frontMonitorLock();
    [lk lock];
    invalidateMonitorSafely(gLayoutMonitor);
    gLayoutMonitor = nil;
    gLatestLayout  = nil;
    gLatestLayoutUp = 0.0;
    gLastLayoutInitUp = 0.0;
    gNilLayoutStreak = 0;

    invalidateMonitorSafely(gAppStateMonitor);
    gAppStateMonitor = nil;
    gLastBKSInitUp   = 0.0;
    [lk unlock];
}

NSString *currentFrontmostAppBundleIDForConfig(FilterConfig *config) {
    // Drain pending XPC / Mach notifications so FrontBoard & BackBoard never stall on a raw C loop
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.001, false);

    NSRecursiveLock *lk = frontMonitorLock();
    NSTimeInterval nowUp = [NSProcessInfo processInfo].systemUptime;
    BOOL mapsInForeground = NO;

    [lk lock];
    @try {
        // 1. Refresh BKSApplicationStateMonitor every 12s so cached XPC states never go stale across hours of sleep
        if (!gAppStateMonitor || (nowUp - gLastBKSInitUp) > 12.0) {
            invalidateMonitorSafely(gAppStateMonitor);
            gAppStateMonitor = nil;
            Class bksMonCls = NSClassFromString(@"BKSApplicationStateMonitor");
            if (bksMonCls) {
                gAppStateMonitor = [[bksMonCls alloc] init];
                gLastBKSInitUp = nowUp;
            }
        }

        // Layer B1: Check foreground bitmask (bit 3 == 8 == BKSApplicationStateForeground; can be 8|32 == 40 on iOS 16!)
        SEL appStateSel = NSSelectorFromString(@"applicationStateForApplication:");
        if (gAppStateMonitor && [gAppStateMonitor respondsToSelector:appStateSel]) {
            if (config && config.dryRunMode) {
                unsigned int photoSt = ((unsigned int (*)(id, SEL, NSString *))objc_msgSend)(
                    gAppStateMonitor, appStateSel, @"com.apple.mobileslideshow");
                if ((photoSt & 8U) != 0) {
                    return @"com.apple.mobileslideshow";
                }
            }

            if (config && config.driverAppBundleID.length > 0) {
                unsigned int drvSt = ((unsigned int (*)(id, SEL, NSString *))objc_msgSend)(
                    gAppStateMonitor, appStateSel, config.driverAppBundleID);
                if ((drvSt & 8U) != 0) {
                    return config.driverAppBundleID;
                }
            }

            unsigned int mapsSt = ((unsigned int (*)(id, SEL, NSString *))objc_msgSend)(
                gAppStateMonitor, appStateSel, @"com.google.Maps");
            if ((mapsSt & 8U) != 0) {
                mapsInForeground = YES;
            }
        }

        // 2. Ensure FBSDisplayLayoutMonitor is active & fresh
        if (!gLayoutMonitor && (nowUp - gLastLayoutInitUp) > 3.0) {
            gLastLayoutInitUp = nowUp;
            Class cfgCls = NSClassFromString(@"FBSDisplayLayoutMonitorConfiguration");
            Class monCls = NSClassFromString(@"FBSDisplayLayoutMonitor");
            SEL cfgSel   = NSSelectorFromString(@"configurationForDefaultMainDisplayMonitor");
            SEL monSel   = NSSelectorFromString(@"monitorWithConfiguration:");

            if (cfgCls && monCls && [cfgCls respondsToSelector:cfgSel] && [monCls respondsToSelector:monSel]) {
                id mCfg = ((id (*)(id, SEL))objc_msgSend)(cfgCls, cfgSel);
                if (mCfg) {
                    SEL prioSel = NSSelectorFromString(@"setNeedsUserInteractivePriority:");
                    if ([mCfg respondsToSelector:prioSel]) {
                        ((void (*)(id, SEL, BOOL))objc_msgSend)(mCfg, prioSel, YES);
                    }
                    SEL handlerSel = NSSelectorFromString(@"setTransitionHandler:");
                    if ([mCfg respondsToSelector:handlerSel]) {
                        void (^handlerBlock)(id, id) = ^(id mon, id layout) {
                            if (layout) {
                                NSRecursiveLock *hlk = frontMonitorLock();
                                [hlk lock];
                                gLatestLayout   = layout;
                                gLatestLayoutUp = [NSProcessInfo processInfo].systemUptime;
                                [hlk unlock];
                            }
                        };
                        ((void (*)(id, SEL, id))objc_msgSend)(mCfg, handlerSel, handlerBlock);
                    }
                    gLayoutMonitor = ((id (*)(id, SEL, id))objc_msgSend)(monCls, monSel, mCfg);
                }
            }
        }

        // Layer A: Inspect visible display scenes (both bundleIdentifier and sceneID:<bundleID>, ignoring AssistiveTouch/InputUI overlays)
        if (gLayoutMonitor) {
            id layout = [gLayoutMonitor valueForKey:@"currentLayout"];
            if (!layout && gLatestLayout && (nowUp - gLatestLayoutUp) <= 2.5) {
                layout = gLatestLayout;
            }

            if (!layout) {
                gNilLayoutStreak++;
                if (gNilLayoutStreak >= 3) {
                    invalidateMonitorSafely(gLayoutMonitor);
                    gLayoutMonitor = nil;
                    gNilLayoutStreak = 0;
                }
            } else {
                gNilLayoutStreak = 0;
                NSArray *elements = [layout valueForKey:@"elements"];
                NSString *topAppBundle = nil;
                NSInteger topLevel = NSIntegerMin;

                for (id elem in elements) {
                    NSString *bid   = nil;
                    NSString *ident = nil;
                    @try { bid   = [elem valueForKey:@"bundleIdentifier"]; } @catch (NSException *e) {}
                    @try { ident = [elem valueForKey:@"identifier"]; }       @catch (NSException *e) {}

                    // Priority 1: If Xanh SM (or Photos in Dry-Run) is visible in ANY scene, return it immediately!
                    if (bundleIDMatchesDriverOrAllowed(bid, config)) {
                        return bid;
                    }
                    if (bundleIDMatchesDriverOrAllowed(ident, config)) {
                        return (config && config.driverAppBundleID.length > 0) ? config.driverAppBundleID : @"vn.gsm.driver";
                    }

                    NSString *cand = (bid.length > 0) ? bid : normalizeSceneIdentifierToBundleID(ident);
                    if (!cand || cand.length == 0) continue;
                    if (isSystemOverlayIdentifier(cand) || isSystemOverlayIdentifier(ident)) {
                        continue;
                    }

                    NSNumber *lvlNum = nil;
                    @try { lvlNum = [elem valueForKey:@"level"]; } @catch (NSException *e) {}
                    NSInteger lvl = lvlNum ? [lvlNum integerValue] : 0;
                    if (lvl >= topLevel) {
                        topLevel = lvl;
                        topAppBundle = cand;
                    }
                }

                if (topAppBundle.length > 0) {
                    return topAppBundle;
                }
            }
        }
    } @catch (NSException *ex) {
    } @finally {
        [lk unlock];
    }

    if (mapsInForeground) {
        return @"com.google.Maps";
    }

    // Fail-open (nil -> canScan = YES) if neither monitor identified a foreign app
    return nil;
}

BOOL isDeviceScreenLocked(void) {
    static int sLockToken = -1;
    static dispatch_once_t sLockOnce;
    dispatch_once(&sLockOnce, ^{
        notify_register_check("com.apple.springboard.lockstate", &sLockToken);
    });
    if (sLockToken == -1) return NO;
    uint64_t state64 = 0;
    if (notify_get_state(sLockToken, &state64) == NOTIFY_STATUS_OK) {
        return (state64 != 0);
    }
    return NO;
}

uint64_t currentProcessFootprintMB(void) {
    task_vm_info_data_t vmInfo;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vmInfo, &count);
    if (kr == KERN_SUCCESS) {
        return (uint64_t)(vmInfo.phys_footprint / (1024ULL * 1024ULL));
    }
    return 0;
}

#pragma mark - LaunchServices App Discovery, Kill & Relaunch

NSArray<InstalledAppInfo *> *listInstalledUserApps(void) {
    NSMutableArray<InstalledAppInfo *> *result = [NSMutableArray array];
    Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
    if (!wsCls) return result;

    SEL defSel = NSSelectorFromString(@"defaultWorkspace");
    if (![wsCls respondsToSelector:defSel]) return result;
    id workspace = ((id (*)(id, SEL))objc_msgSend)(wsCls, defSel);
    if (!workspace) return result;

    SEL allSel = NSSelectorFromString(@"allInstalledApplications");
    if (![workspace respondsToSelector:allSel]) return result;
    NSArray *proxies = ((NSArray * (*)(id, SEL))objc_msgSend)(workspace, allSel);

    for (id proxy in proxies) {
        @try {
            NSString *appType = [proxy valueForKey:@"applicationType"];
            if (appType && ![appType isEqualToString:@"User"]) continue;

            NSString *bid = [proxy valueForKey:@"applicationIdentifier"];
            if (!bid || [bid isEqualToString:kAppBundleID] || [bid hasPrefix:@"com.apple."]) continue;

            NSString *name = nil;
            SEL locSel = NSSelectorFromString(@"localizedName");
            if ([proxy respondsToSelector:locSel]) {
                name = ((NSString * (*)(id, SEL))objc_msgSend)(proxy, locSel);
            }
            if (!name || name.length == 0) {
                name = [proxy valueForKey:@"itemName"] ?: bid;
            }

            NSString *exec = [proxy valueForKey:@"bundleExecutable"] ?: @"";

            InstalledAppInfo *info = [[InstalledAppInfo alloc] init];
            info.bundleID       = bid;
            info.displayName    = name;
            info.executableName = exec;
            [result addObject:info];
        } @catch (NSException *ex) {}
    }

    [result sortUsingComparator:^NSComparisonResult(InstalledAppInfo *a, InstalledAppInfo *b) {
        return [a.displayName localizedCaseInsensitiveCompare:b.displayName];
    }];
    return result;
}

InstalledAppInfo *autoDetectDriverApp(void) {
    NSArray<InstalledAppInfo *> *apps = listInstalledUserApps();
    for (InstalledAppInfo *app in apps) {
        NSString *normName = NormalizeVNText(app.displayName);
        NSString *normBid  = app.bundleID.lowercaseString;
        if (([normName containsString:@"xanh"] && ([normName containsString:@"tai"] || [normName containsString:@"driver"] || [normName containsString:@"platform"])) ||
            [normBid containsString:@"gsm.driver"] ||
            [normBid containsString:@"xanhsm.driver"] ||
            [normName containsString:@"bac tai"]) {
            return app;
        }
    }
    for (InstalledAppInfo *app in apps) {
        NSString *normName = NormalizeVNText(app.displayName);
        if ([normName containsString:@"xanh sm"] || [normName containsString:@"greensm"] || [app.bundleID.lowercaseString containsString:@"xanhsm"]) {
            return app;
        }
    }
    return nil;
}

static BOOL isUserAppPidAlive(pid_t pid) {
    if (pid <= 1) return NO;
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, (int)pid };
    struct kinfo_proc info;
    size_t len = sizeof(info);
    memset(&info, 0, sizeof(info));
    if (sysctl(mib, 4, &info, &len, NULL, 0) == 0 && len > 0 && info.kp_proc.p_pid == pid) {
        return (info.kp_proc.p_stat != SZOMB);
    }
    return (kill(pid, 0) == 0 || errno == EPERM);
}

static NSArray<NSNumber *> *findRunningAppPIDs(NSString *bundleID, NSString *execName) {
    NSMutableSet<NSNumber *> *pidSet = [NSMutableSet set];
    pid_t selfPid = getpid();

    // Source 1: Exact PID from BackBoardServices applicationInfoForApplication:
    if (bundleID.length > 0) {
        void *bks = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_LAZY);
        Class bksMonCls = NSClassFromString(@"BKSApplicationStateMonitor");
        if (bksMonCls) {
            @try {
                id mon = [[bksMonCls alloc] init];
                SEL infoSel = NSSelectorFromString(@"applicationInfoForApplication:");
                if (mon && [mon respondsToSelector:infoSel]) {
                    NSDictionary *info = ((NSDictionary * (*)(id, SEL, NSString *))objc_msgSend)(mon, infoSel, bundleID);
                    if ([info isKindOfClass:[NSDictionary class]]) {
                        NSNumber *pidNum = info[@"SBApplicationStateProcessIDKey"] ?: info[@"BKSApplicationStateProcessIDKey"];
                        if (!pidNum && bks) {
                            NSString * const *symKey = (NSString * const *)dlsym(bks, "BKSApplicationStateProcessIDKey");
                            if (symKey && *symKey) {
                                pidNum = info[*symKey];
                            }
                        }
                        if ([pidNum respondsToSelector:@selector(intValue)]) {
                            pid_t p = (pid_t)[pidNum intValue];
                            if (p > 1 && p != selfPid && isUserAppPidAlive(p)) {
                                [pidSet addObject:@(p)];
                            }
                        }
                    }
                }
                invalidateMonitorSafely(mon);
            } @catch (NSException *ex) {}
        }
    }

    // Source 2: Kernel process table match against executableName (p_comm holds up to MAXCOMLEN=16 chars)
    if (execName.length > 0) {
        const char *execCStr = [execName UTF8String];
        size_t cmpLen = strlen(execCStr);
        if (cmpLen > 16) cmpLen = 16;

        if (cmpLen > 0 &&
            strncmp(execCStr, "pind", 4) != 0 &&
            strncmp(execCStr, "PinNhietDo", 10) != 0 &&
            strncmp(execCStr, "SpringBoard", 11) != 0) {
            int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
            size_t size = 0;
            if (sysctl(mib, 4, NULL, &size, NULL, 0) == 0 && size > 0) {
                size_t allocSize = size + (size / 4);
                struct kinfo_proc *procs = (struct kinfo_proc *)malloc(allocSize);
                if (procs) {
                    if (sysctl(mib, 4, procs, &allocSize, NULL, 0) == 0) {
                        size_t count = allocSize / sizeof(struct kinfo_proc);
                        for (size_t i = 0; i < count; i++) {
                            pid_t p = procs[i].kp_proc.p_pid;
                            if (p <= 1 || p == selfPid || procs[i].kp_proc.p_stat == SZOMB) continue;
                            if (strncmp(procs[i].kp_proc.p_comm, execCStr, cmpLen) == 0) {
                                [pidSet addObject:@(p)];
                            }
                        }
                    }
                    free(procs);
                }
            }
        }
    }

    return [pidSet allObjects];
}

static NSString *resolvePindBinaryPath(void) {
    NSString *cand1 = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"pind"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:cand1]) {
        return cand1;
    }
    NSString *arg0 = [NSProcessInfo processInfo].arguments.firstObject;
    if (arg0.length > 0 && [arg0.lastPathComponent isEqualToString:@"pind"] &&
        [[NSFileManager defaultManager] fileExistsAtPath:arg0]) {
        return arg0;
    }
    return nil;
}

BOOL killAppByBundleIDAndExec(NSString *bundleID, NSString *execName) {
    if (!bundleID || bundleID.length == 0 || !execName || execName.length == 0) {
        InstalledAppInfo *det = nil;
        if (bundleID.length > 0) {
            for (InstalledAppInfo *app in listInstalledUserApps()) {
                if ([app.bundleID isEqualToString:bundleID]) {
                    det = app;
                    break;
                }
            }
        }
        if (!det) det = autoDetectDriverApp();
        if (det) {
            if (!bundleID || bundleID.length == 0) bundleID = det.bundleID;
            if (!execName || execName.length == 0) execName = det.executableName;
        }
    }
    if (!bundleID || bundleID.length == 0) return NO;

    NSArray<NSNumber *> *initialPIDs = findRunningAppPIDs(bundleID, execName);

    // Layer 1: Modern FrontBoardServices FBSSystemService termination (cleans scene & app switcher state)
    dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_LAZY);
    Class fbsSysCls = NSClassFromString(@"FBSSystemService");
    if (fbsSysCls) {
        @try {
            SEL sharedSel = NSSelectorFromString(@"sharedService");
            SEL termSel   = NSSelectorFromString(@"terminateApplication:forReason:andReport:withDescription:");
            if ([fbsSysCls respondsToSelector:sharedSel]) {
                id sysSvc = ((id (*)(id, SEL))objc_msgSend)(fbsSysCls, sharedSel);
                if (sysSvc && [sysSvc respondsToSelector:termSel]) {
                    ((void (*)(id, SEL, NSString *, NSInteger, BOOL, NSString *))objc_msgSend)(
                        sysSvc, termSel, bundleID, 5, NO, @"Session refresh");
                }
            }
        } @catch (NSException *ex) {}
    }

    // Layer 2: BackBoardServices BKSTerminateApplicationForReasonAndReportWithDescription
    void *bks = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_LAZY);
    if (bks) {
        BKSTerminateApp_f fnTerm = (BKSTerminateApp_f)dlsym(bks, "BKSTerminateApplicationForReasonAndReportWithDescription");
        if (fnTerm) {
            fnTerm((__bridge CFStringRef)bundleID, 5, false, CFSTR("Session refresh"));
        }
    }

    // Wait up to 350ms to verify whether FrontBoard/BackBoard actually terminated the process
    for (int i = 0; i < 7; i++) {
        usleep(50000);
        NSArray<NSNumber *> *aliveNow = findRunningAppPIDs(bundleID, execName);
        if (aliveNow.count == 0) {
            BOOL anyInitialAlive = NO;
            for (NSNumber *n in initialPIDs) {
                if (isUserAppPidAlive((pid_t)[n intValue])) {
                    anyInitialAlive = YES;
                    break;
                }
            }
            if (!anyInitialAlive) {
                resetFrontmostAppMonitors();
                return YES;
            }
        }
    }

    // Layer 3: Ironclad Kernel SIGTERM -> SIGKILL (+ root fallback) on any surviving PID
    NSMutableSet<NSNumber *> *remaining = [NSMutableSet setWithArray:findRunningAppPIDs(bundleID, execName)];
    for (NSNumber *n in initialPIDs) {
        if (isUserAppPidAlive((pid_t)[n intValue])) {
            [remaining addObject:n];
        }
    }

    NSString *pindBin = resolvePindBinaryPath();
    for (NSNumber *n in remaining) {
        pid_t targetPid = (pid_t)[n intValue];
        if (targetPid <= 1) continue;

        kill(targetPid, SIGTERM);
        usleep(80000);
        if (isUserAppPidAlive(targetPid)) {
            if (kill(targetPid, SIGKILL) != 0 && errno == EPERM && pindBin) {
                spawnRoot(pindBin, @[@"--kill-pid", [NSString stringWithFormat:@"%d", targetPid]]);
            }
            usleep(80000);
        }
    }

    resetFrontmostAppMonitors();
    NSArray<NSNumber *> *afterKill = findRunningAppPIDs(bundleID, execName);
    return (afterKill.count == 0);
}

static BOOL isAppCurrentlyForeground(NSString *bundleID) {
    if (!bundleID || bundleID.length == 0) return NO;
    Class bksMonCls = NSClassFromString(@"BKSApplicationStateMonitor");
    if (!bksMonCls) return NO;
    BOOL fg = NO;
    @try {
        id mon = [[bksMonCls alloc] init];
        SEL stSel = NSSelectorFromString(@"applicationStateForApplication:");
        if (mon && [mon respondsToSelector:stSel]) {
            unsigned int st = ((unsigned int (*)(id, SEL, NSString *))objc_msgSend)(mon, stSel, bundleID);
            fg = ((st & 8U) != 0);
        }
        invalidateMonitorSafely(mon);
    } @catch (NSException *ex) {}
    return fg;
}

BOOL launchAppByBundleID(NSString *bundleID) {
    if (!bundleID || bundleID.length == 0) {
        InstalledAppInfo *det = autoDetectDriverApp();
        if (!det) return NO;
        bundleID = det.bundleID;
    }

    resetFrontmostAppMonitors();
    BOOL invokedAny = NO;

    // Layer 1: LSApplicationWorkspace openApplicationWithBundleID:
    Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
    if (wsCls) {
        @try {
            SEL defSel = NSSelectorFromString(@"defaultWorkspace");
            id workspace = ((id (*)(id, SEL))objc_msgSend)(wsCls, defSel);
            SEL openSel = NSSelectorFromString(@"openApplicationWithBundleID:");
            if (workspace && [workspace respondsToSelector:openSel]) {
                if (((BOOL (*)(id, SEL, NSString *))objc_msgSend)(workspace, openSel, bundleID)) {
                    invokedAny = YES;
                }
            }
        } @catch (NSException *ex) {}
    }

    usleep(220000);
    if (isAppCurrentlyForeground(bundleID)) {
        resetFrontmostAppMonitors();
        return YES;
    }

    // Layer 2: FrontBoardServices FBSOpenApplicationService (works reliably from headless background daemons on iOS 16)
    dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_LAZY);
    Class fbsOpenCls = NSClassFromString(@"FBSOpenApplicationService");
    if (fbsOpenCls) {
        @try {
            SEL epSel   = NSSelectorFromString(@"serviceWithDefaultShellEndpoint");
            SEL openSel = NSSelectorFromString(@"openApplication:withOptions:completion:");
            if ([fbsOpenCls respondsToSelector:epSel]) {
                id openSvc = ((id (*)(id, SEL))objc_msgSend)(fbsOpenCls, epSel);
                if (openSvc && [openSvc respondsToSelector:openSel]) {
                    ((void (*)(id, SEL, NSString *, id, id))objc_msgSend)(openSvc, openSel, bundleID, nil, nil);
                    invokedAny = YES;
                }
            }
        } @catch (NSException *ex) {}
    }

    usleep(180000);
    if (isAppCurrentlyForeground(bundleID)) {
        resetFrontmostAppMonitors();
        return YES;
    }

    // Layer 3: SpringBoardServices fallback
    void *sbs = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
    if (sbs) {
        SBSLaunchApp_f fnLaunch = (SBSLaunchApp_f)dlsym(sbs, "SBSLaunchApplicationWithIdentifier");
        if (fnLaunch) {
            if (fnLaunch((__bridge CFStringRef)bundleID, false) == 0) {
                invokedAny = YES;
            }
        }
    }

    resetFrontmostAppMonitors();
    return invokedAny || isAppCurrentlyForeground(bundleID);
}

#pragma mark - TrollStore Root Spawner & Dual-Process Daemon Control

int spawnRoot(NSString *path, NSArray<NSString *> *args) {
    if (!path || path.length == 0) return -1;

    NSMutableArray *fullArgs = [NSMutableArray arrayWithObject:path];
    if (args) [fullArgs addObjectsFromArray:args];

    int argc = (int)fullArgs.count;
    char **argv = calloc(argc + 1, sizeof(char *));
    if (!argv) return -1;
    for (int i = 0; i < argc; i++) {
        argv[i] = strdup([fullArgs[i] UTF8String]);
    }
    argv[argc] = NULL;

    posix_spawn_file_actions_t fileActions;
    posix_spawn_file_actions_init(&fileActions);
    posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO,  "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);

    persona_np_f fnSetPersona = (persona_np_f)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_np");
    persona_id_f fnSetUid     = (persona_id_f)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_uid_np");
    persona_id_f fnSetGid     = (persona_id_f)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_gid_np");

    if (fnSetPersona) fnSetPersona(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    if (fnSetUid)     fnSetUid(&attr, 0);
    if (fnSetGid)     fnSetGid(&attr, 0);

    posix_spawnattr_setpgroup(&attr, 0);
    short flags = (short)(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT);
    posix_spawnattr_setflags(&attr, flags);

    pid_t pid = 0;
    int ret = posix_spawn(&pid, [path fileSystemRepresentation], &fileActions, &attr, argv, environ);
    if (ret != 0) {
        // Fallback without CLOEXEC_DEFAULT in case an older kernel rejects the flag
        posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
        ret = posix_spawn(&pid, [path fileSystemRepresentation], &fileActions, &attr, argv, environ);
    }

    posix_spawn_file_actions_destroy(&fileActions);
    posix_spawnattr_destroy(&attr);
    for (int i = 0; i < argc; i++) free(argv[i]);
    free(argv);

    if (ret == 0 && pid > 0 && args.count > 0) {
        NSString *firstArg = args.firstObject;
        if ([firstArg isEqualToString:@"--daemonize"] ||
            [firstArg isEqualToString:@"--stop"] ||
            [firstArg isEqualToString:@"--kill-pid"]) {
            int wstatus = 0;
            for (int w = 0; w < 25; w++) {
                pid_t r = waitpid(pid, &wstatus, WNOHANG);
                if (r == pid || r == -1) break;
                usleep(20000);
            }
        }
    }

    return (ret == 0) ? (int)pid : -ret;
}

static BOOL isPidAlivePind(pid_t pid) {
    if (pid <= 1) return NO;
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, (int)pid };
    struct kinfo_proc info;
    size_t len = sizeof(info);
    memset(&info, 0, sizeof(info));
    if (sysctl(mib, 4, &info, &len, NULL, 0) == 0 && len > 0 && info.kp_proc.p_pid == pid) {
        if (info.kp_proc.p_stat == SZOMB) {
            return NO;
        }
        return (strncmp(info.kp_proc.p_comm, "pind", 4) == 0);
    }
    return (kill(pid, 0) == 0 || errno == EPERM);
}

static pid_t readAlivePidFromFile(NSString *filePath) {
    NSData *data = [NSData dataWithContentsOfFile:filePath options:NSDataReadingUncached error:nil];
    if (!data || data.length == 0) return 0;
    NSString *pidStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!pidStr) return 0;
    pid_t pid = (pid_t)[pidStr intValue];
    if (pid <= 1) return 0;
    if (isPidAlivePind(pid)) {
        return pid;
    }
    return 0;
}

pid_t getRunningDaemonPID(void) {
    return readAlivePidFromFile(kDaemonPidPath);
}

pid_t getRunningWatchdogPID(void) {
    return readAlivePidFromFile(kWatchdogPidPath);
}

static NSRecursiveLock *daemonControlMutex(void) {
    static NSRecursiveLock *sCtlLock = nil;
    static dispatch_once_t onceTok;
    dispatch_once(&onceTok, ^{
        sCtlLock = [[NSRecursiveLock alloc] init];
    });
    return sCtlLock;
}

static int acquireCrossProcessCtlLock(void) {
    int fd = open(kDaemonControlLockPath, O_CREAT | O_RDWR, 0666);
    if (fd >= 0) {
        fcntl(fd, F_SETPROTECTIONCLASS, PROTECTION_CLASS_D);
        chmod(kDaemonControlLockPath, 0666);
        flock(fd, LOCK_EX);
    }
    return fd;
}

static void releaseCrossProcessCtlLock(int fd) {
    if (fd >= 0) {
        flock(fd, LOCK_UN);
        close(fd);
    }
}

static void stopFilterDaemonUnlocked(void) {
    notify_post(kNotifyStopDaemon);
    usleep(120000);

    // Execute --stop as uid=0 via spawnRoot so root Watchdog & Worker are guaranteed terminated cleanly
    NSString *daemonPath = resolvePindBinaryPath();
    if (daemonPath.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:daemonPath]) {
        chmod([daemonPath fileSystemRepresentation], 0755);
        spawnRoot(daemonPath, @[@"--stop"]);
        usleep(100000);
    } else {
        pid_t wkPid = getRunningDaemonPID();
        if (wkPid > 1) kill(wkPid, SIGKILL);
    }

    unlink([kWatchdogPidPath fileSystemRepresentation]);
    unlink([kDaemonPidPath fileSystemRepresentation]);
}

BOOL startFilterDaemonIfNeeded(void) {
    NSRecursiveLock *mtx = daemonControlMutex();
    [mtx lock];
    int lockFd = acquireCrossProcessCtlLock();
    BOOL finalResult = NO;

    @try {
        upgradeSharedFilesProtectionNone();

        pid_t existingWatchdog = getRunningWatchdogPID();
        if (existingWatchdog > 0) {
            // Wait up to 1.6s if Watchdog is in the middle of spawning/recycling Worker
            for (int w = 0; w < 8 && getRunningDaemonPID() <= 0; w++) {
                usleep(200000);
                if (getRunningWatchdogPID() <= 0) break;
            }

            existingWatchdog = getRunningWatchdogPID();
            pid_t existingWorker = getRunningDaemonPID();
            RuntimeDaemonState *st = [RuntimeDaemonState loadState];

            if (existingWatchdog > 0 && existingWorker > 0 &&
                [st.daemonVersion isEqualToString:kCurrentDaemonVersion]) {
                double now = [[NSDate date] timeIntervalSince1970];
                if (st.workerHeartbeatEpoch <= 0.0 || fabs(now - st.workerHeartbeatEpoch) < 60.0) {
                    notify_post(kNotifyReloadConfig);
                    finalResult = YES;
                    return finalResult;
                }

                // Device may have just woken from deep pocket sleep -> poke Worker and wait up to 1.5s
                notify_post(kNotifyReloadConfig);
                for (int k = 0; k < 6; k++) {
                    usleep(250000);
                    st  = [RuntimeDaemonState loadState];
                    now = [[NSDate date] timeIntervalSince1970];
                    if (getRunningWatchdogPID() > 0 &&
                        getRunningDaemonPID() > 0 &&
                        st.workerHeartbeatEpoch > 0.0 &&
                        fabs(now - st.workerHeartbeatEpoch) < 60.0) {
                        finalResult = YES;
                        return finalResult;
                    }
                }
            }
        }

        stopFilterDaemonUnlocked();

        NSString *daemonPath = resolvePindBinaryPath();
        if (!daemonPath || daemonPath.length == 0) {
            daemonPath = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"pind"];
        }
        chmod([daemonPath fileSystemRepresentation], 0755);

        // Double-spawn via --daemonize so launchd (PID 1) adopts Watchdog cleanly (immune to UI App Switcher swipe-kill!)
        int res = spawnRoot(daemonPath, @[@"--daemonize"]);
        if (res > 0) {
            for (int i = 0; i < 20; i++) {
                usleep(60000);
                if (getRunningWatchdogPID() > 0 || getRunningDaemonPID() > 0) {
                    finalResult = YES;
                    return finalResult;
                }
            }
            if (getRunningWatchdogPID() > 0 || getRunningDaemonPID() > 0) {
                finalResult = YES;
                return finalResult;
            }
        }

        // Direct fallback to --watchdog if --daemonize didn't materialize PID files yet
        res = spawnRoot(daemonPath, @[@"--watchdog"]);
        if (res > 0) {
            for (int i = 0; i < 16; i++) {
                usleep(60000);
                if (getRunningWatchdogPID() > 0 || getRunningDaemonPID() > 0) {
                    finalResult = YES;
                    return finalResult;
                }
            }
            finalResult = YES;
            return finalResult;
        }

        appendDaemonLog(@"[LỖI] Không kích được pind v4.6.1 (mã: %d). Hãy kiểm tra đã cài qua TrollStore chưa.", res);
        finalResult = NO;
    } @finally {
        releaseCrossProcessCtlLock(lockFd);
        [mtx unlock];
    }
    return finalResult;
}

BOOL forceRestartFilterDaemon(void) {
    NSRecursiveLock *mtx = daemonControlMutex();
    [mtx lock];
    int lockFd = acquireCrossProcessCtlLock();
    @try {
        stopFilterDaemonUnlocked();
        usleep(120000);
    } @finally {
        releaseCrossProcessCtlLock(lockFd);
        [mtx unlock];
    }
    return startFilterDaemonIfNeeded();
}

void stopFilterDaemon(void) {
    NSRecursiveLock *mtx = daemonControlMutex();
    [mtx lock];
    int lockFd = acquireCrossProcessCtlLock();
    @try {
        stopFilterDaemonUnlocked();
    } @finally {
        releaseCrossProcessCtlLock(lockFd);
        [mtx unlock];
    }
}

#pragma mark - Logging & Haptics

void appendDaemonLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    static dispatch_queue_t sLogQueue = nil;
    static NSDateFormatter *sDateFmt  = nil;
    static dispatch_once_t sLogOnce;
    dispatch_once(&sLogOnce, ^{
        sLogQueue = dispatch_queue_create("com.vn.utility.batterycheck.logq", DISPATCH_QUEUE_SERIAL);
        sDateFmt  = [[NSDateFormatter alloc] init];
        sDateFmt.dateFormat = @"HH:mm:ss";
    });

    dispatch_sync(sLogQueue, ^{
        NSString *line = [NSString stringWithFormat:@"[%@] %@", [sDateFmt stringFromDate:[NSDate date]], msg];

        NSString *existing = [NSString stringWithContentsOfFile:kDaemonLogPath encoding:NSUTF8StringEncoding error:nil];
        NSMutableArray<NSString *> *lines = existing
            ? [[existing componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] mutableCopy]
            : [NSMutableArray array];
        [lines removeObject:@""];
        [lines addObject:line];

        while (lines.count > 65) {
            [lines removeObjectAtIndex:0];
        }

        NSString *joined = [lines componentsJoinedByString:@"\n"];
        writeStringUnprotectedAtomically(joined, kDaemonLogPath);
    });
}

NSString *readDaemonLogs(void) {
    NSString *txt = [NSString stringWithContentsOfFile:kDaemonLogPath encoding:NSUTF8StringEncoding error:nil];
    if (!txt || txt.length == 0) {
        return @"Chưa có nhật ký hoạt động...";
    }
    return txt;
}

void clearDaemonLogs(void) {
    writeStringUnprotectedAtomically(@"", kDaemonLogPath);
}

void triggerHapticFeedback(BOOL isAccept) {
    if (isAccept) {
        AudioServicesPlaySystemSound(1520);
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
        usleep(160000);
        AudioServicesPlaySystemSound(1520);
    } else {
        AudioServicesPlaySystemSound(1519);
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
    }
}
