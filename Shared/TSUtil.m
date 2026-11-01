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
        kMapRelayQueuePath,
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

NSString *generateRandomMapRelayTopic(void) {
    static const char kAlphabet[] = "abcdefghjkmnpqrstuvwxyz23456789";
    char buf[9];
    for (int i = 0; i < 8; i++) {
        buf[i] = kAlphabet[arc4random_uniform((uint32_t)(sizeof(kAlphabet) - 1))];
    }
    buf[8] = '\0';
    return [NSString stringWithFormat:@"vf-map-%s", buf];
}

NSString *sanitizeMapRelayTopic(NSString *rawTopic) {
    if (!rawTopic || rawTopic.length == 0) return @"";
    NSString *low = [rawTopic.lowercaseString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableString *clean = [NSMutableString stringWithCapacity:low.length];
    for (NSUInteger i = 0; i < low.length && clean.length < 48; i++) {
        unichar c = [low characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_') {
            [clean appendFormat:@"%C", c];
        }
    }
    while ([clean hasPrefix:@"-"] || [clean hasPrefix:@"_"]) {
        [clean deleteCharactersInRange:NSMakeRange(0, 1)];
    }
    return [clean copy];
}

NSString *buildMapRelayViewerURLString(NSString *topic) {
    NSString *clean = sanitizeMapRelayTopic(topic);
    if (clean.length < 4) clean = @"vf-map";
    return [NSString stringWithFormat:@"%@?k=%@", kMapRelayViewerBaseURL, clean];
}

@implementation RuntimeDaemonState

- (instancetype)init {
    self = [super init];
    if (self) {
        _statAcceptedCount    = 0;
        _statRejectedCount    = 0;
        _pauseEndEpoch        = 0.0;
        _workerHeartbeatEpoch = 0.0;
        _phaseDescription     = @"Đang rảnh / Canh đơn";
        _daemonVersion        = @"";
        _daemonBinaryPath     = @"";
        _lastRelayedSummary   = @"";
        _lastRelayedEpoch     = 0.0;
    }
    return self;
}

+ (instancetype)loadState {
    RuntimeDaemonState *st = [[RuntimeDaemonState alloc] init];
    NSDictionary *d = readDictSafelyWithRetry(kRuntimeStatePath);
    if (!d) return st;
    if (d[@"statAcceptedCount"])    st.statAcceptedCount    = [d[@"statAcceptedCount"] integerValue];
    if (d[@"statRejectedCount"])    st.statRejectedCount    = [d[@"statRejectedCount"] integerValue];
    if (d[@"pauseEndEpoch"])        st.pauseEndEpoch        = [d[@"pauseEndEpoch"] doubleValue];
    if (d[@"workerHeartbeatEpoch"]) st.workerHeartbeatEpoch = [d[@"workerHeartbeatEpoch"] doubleValue];
    if (d[@"phaseDescription"])     st.phaseDescription     = d[@"phaseDescription"];
    if (d[@"daemonVersion"])        st.daemonVersion        = d[@"daemonVersion"];
    if (d[@"daemonBinaryPath"])     st.daemonBinaryPath     = d[@"daemonBinaryPath"];
    if (d[@"lastRelayedSummary"])   st.lastRelayedSummary   = d[@"lastRelayedSummary"];
    if (d[@"lastRelayedEpoch"])     st.lastRelayedEpoch     = [d[@"lastRelayedEpoch"] doubleValue];
    return st;
}

- (void)saveStateAndNotify:(BOOL)sendNotify {
    NSDictionary *d = @{
        @"statAcceptedCount":    @(self.statAcceptedCount),
        @"statRejectedCount":    @(self.statRejectedCount),
        @"pauseEndEpoch":        @(self.pauseEndEpoch),
        @"workerHeartbeatEpoch": @(self.workerHeartbeatEpoch),
        @"phaseDescription":     self.phaseDescription ?: @"",
        @"daemonVersion":        self.daemonVersion ?: @"",
        @"daemonBinaryPath":     self.daemonBinaryPath ?: @"",
        @"lastRelayedSummary":   self.lastRelayedSummary ?: @"",
        @"lastRelayedEpoch":     @(self.lastRelayedEpoch)
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
        _masterEnabled            = NO;
        _autoAcceptBike           = YES;
        _rejectAllFood            = NO;
        _minFoodPriceVND          = 25000;
        _foodBlockMallAndBasement = YES;
        _foodBlockCrowdedChains   = YES;
        _foodMaxMerchantOrders    = 8000;
        _foodMallKeywords         = kDefaultFoodMallKeywords;
        _foodChainKeywords        = kDefaultFoodChainKeywords;
        _foodAcceptLongDistance   = YES;
        _minFoodDistanceKm        = 3.0;
        _smartCoolMode            = YES;
        _tapVerifyRetries         = 2;
        _hapticEnabled            = YES;
        _dryRunMode               = NO;

        _pauseAfterRejectFood     = YES;
        _pauseDurationSec         = 120; // 2 minutes
        _autoKillAndRelaunchApp   = NO;
        _relaunchLeadSec          = 15;
        _driverAppBundleID        = @"";
        _driverAppExecName        = @"";
        _driverAppDisplayName     = @"Tự động dò Xanh SM";

        _mapRelayEnabled          = YES;
        _mapRelayTopic            = @"";
        _mapRelayReturnToDriver   = YES;

        _coordMode                = CoordModeAutoOCRWithOffset;
        _closeXRatio              = 0.903; // 338.6 / 375.0 measured on iPhone 8
        _closeOffsetX             = 0.0;
        _closeOffsetY             = 0.0;
        _acceptOffsetX            = 0.0;
        _acceptOffsetY            = 0.0;
        _onlineOffsetX            = 0.0;
        _onlineOffsetY            = 0.0;

        // Exact coordinates measured from real iPhone 8 (375 x 667 pt) screenshots
        _manualCloseX             = 339.0;
        _manualCloseY             = 52.0;
        _manualAcceptX            = 187.0;
        _manualAcceptY            = 640.0;
        _manualOfflineX           = 40.0;
        _manualOfflineY           = 455.0;
        _manualOnlineX            = 187.0;
        _manualOnlineY            = 307.0;

        _scanIntervalMs           = 350;
        _acceptDelayMinMs         = 180;
        _acceptDelayMaxMs         = 420;
        _rejectDelayMinMs         = 400;
        _rejectDelayMaxMs         = 850;
        _jitterRadiusPt           = 5.0;
        _holdMinMs                = 45;
        _holdMaxMs                = 85;
        _cooldownMs               = 2500;
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
        cfg.mapRelayTopic = generateRandomMapRelayTopic();
        if (geteuid() != 0) {
            InstalledAppInfo *detected = autoDetectDriverApp();
            if (detected) {
                cfg.driverAppBundleID    = detected.bundleID;
                cfg.driverAppExecName    = detected.executableName;
                cfg.driverAppDisplayName = detected.displayName;
            }
            if (!cPath || access(cPath, F_OK) != 0) {
                [cfg saveToDiskAndNotify:NO];
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
        NSString *savedMall = dict[@"foodMallKeywords"];
        NSString *v47DefaultMall = @"vincom, aeon, lotte mall, lotte center, lotte mart, royal city, times city, park hill, big c, bigc, go! thang long, tops market, mega market, the garden, indochina, iph, the loop, keangnam, landmark 72, tasco mall, savico, artemis, discovery complex, trang tien plaza, ho guom plaza, mac plaza, machinco, mipec, the zei, tnr tower, sun plaza, cho dong xuan, trung tam thuong mai, tttm, tang ham, ham b1, ham b2, ham b3, gian hang, kiosk, food court, goods court, tang l1, tang l2, tang l3, tang l4, tang l5, 72a nguyen trai, 458 minh khai, 191 ba trieu, 54a nguyen chi thanh, 119 tran duy hung, 222 tran duy hung, 272 vo chi cong, 54 lieu giai, 241 xuan thuy, 27 co linh, 302 cau giay";
        cfg.foodMallKeywords = [savedMall isEqualToString:v47DefaultMall] ? kDefaultFoodMallKeywords : savedMall;
    }
    if ([dict[@"foodChainKeywords"] isKindOfClass:[NSString class]]) {
        NSString *savedChain = dict[@"foodChainKeywords"];
        NSString *v47DefaultChain = @"phe la, katinat, ca phe muoi chu long, phuc long, koi the, the alley, gong cha, chagee, starbucks, lotteria, kfc, jollibee, mcdonald, popeyes, texas chicken, burger king, pizza 4p, pizza hut, domino, al fresco, com tho anh nguyen, com suon cay himc, bami king, haidilao, dookki, manwah, gogi house, kichi kichi, marukame";
        cfg.foodChainKeywords = [savedChain isEqualToString:v47DefaultChain] ? kDefaultFoodChainKeywords : savedChain;
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

    if (dict[@"mapRelayEnabled"])        cfg.mapRelayEnabled        = [dict[@"mapRelayEnabled"] boolValue];
    if ([dict[@"mapRelayTopic"] isKindOfClass:[NSString class]]) {
        cfg.mapRelayTopic = sanitizeMapRelayTopic(dict[@"mapRelayTopic"]);
    }
    if (dict[@"mapRelayReturnToDriver"]) cfg.mapRelayReturnToDriver = [dict[@"mapRelayReturnToDriver"] boolValue];

    BOOL generatedNewTopic = NO;
    if (cfg.mapRelayTopic.length < 4) {
        cfg.mapRelayTopic = generateRandomMapRelayTopic();
        generatedNewTopic = YES;
    }

    if (dict[@"coordMode"])              cfg.coordMode              = (CoordMode)[dict[@"coordMode"] integerValue];
    if (dict[@"closeXRatio"])            cfg.closeXRatio            = [dict[@"closeXRatio"] doubleValue];
    if (dict[@"closeOffsetX"])           cfg.closeOffsetX           = [dict[@"closeOffsetX"] doubleValue];
    if (dict[@"closeOffsetY"])           cfg.closeOffsetY           = [dict[@"closeOffsetY"] doubleValue];
    if (dict[@"acceptOffsetX"])          cfg.acceptOffsetX          = [dict[@"acceptOffsetX"] doubleValue];
    if (dict[@"acceptOffsetY"])          cfg.acceptOffsetY          = [dict[@"acceptOffsetY"] doubleValue];
    if (dict[@"onlineOffsetX"])          cfg.onlineOffsetX          = [dict[@"onlineOffsetX"] doubleValue];
    if (dict[@"onlineOffsetY"])          cfg.onlineOffsetY          = [dict[@"onlineOffsetY"] doubleValue];

    if (dict[@"manualCloseX"])           cfg.manualCloseX           = [dict[@"manualCloseX"] doubleValue];
    if (dict[@"manualCloseY"])           cfg.manualCloseY           = [dict[@"manualCloseY"] doubleValue];
    if (dict[@"manualAcceptX"])          cfg.manualAcceptX          = [dict[@"manualAcceptX"] doubleValue];
    if (dict[@"manualAcceptY"])          cfg.manualAcceptY          = [dict[@"manualAcceptY"] doubleValue];
    if (dict[@"manualOfflineX"])         cfg.manualOfflineX         = [dict[@"manualOfflineX"] doubleValue];
    if (dict[@"manualOfflineY"])         cfg.manualOfflineY         = [dict[@"manualOfflineY"] doubleValue];
    if (dict[@"manualOnlineX"])          cfg.manualOnlineX          = [dict[@"manualOnlineX"] doubleValue];
    if (dict[@"manualOnlineY"])          cfg.manualOnlineY          = [dict[@"manualOnlineY"] doubleValue];

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
    if (cfg.tapVerifyRetries < 0) cfg.tapVerifyRetries = 0;
    if (cfg.tapVerifyRetries > 4) cfg.tapVerifyRetries = 4;
    if (cfg.foodMaxMerchantOrders < 0) cfg.foodMaxMerchantOrders = 0;
    if (cfg.foodMaxMerchantOrders > 200000) cfg.foodMaxMerchantOrders = 200000;
    if (cfg.minFoodDistanceKm < 0.5) cfg.minFoodDistanceKm = 0.5;
    if (cfg.minFoodDistanceKm > 25.0) cfg.minFoodDistanceKm = 25.0;

    if (generatedNewTopic && geteuid() != 0) {
        [cfg saveToDiskAndNotify:NO];
    }

    return cfg;
}

- (void)saveToDiskAndNotify:(BOOL)sendNotify {
    NSString *cleanTopic = sanitizeMapRelayTopic(self.mapRelayTopic);
    if (cleanTopic.length < 4) {
        cleanTopic = generateRandomMapRelayTopic();
        self.mapRelayTopic = cleanTopic;
    }
    NSDictionary *dict = @{
        @"masterEnabled":            @(self.masterEnabled),
        @"autoAcceptBike":           @(self.autoAcceptBike),
        @"rejectAllFood":            @(self.rejectAllFood),
        @"minFoodPriceVND":          @(self.minFoodPriceVND),
        @"foodBlockMallAndBasement": @(self.foodBlockMallAndBasement),
        @"foodBlockCrowdedChains":   @(self.foodBlockCrowdedChains),
        @"foodMaxMerchantOrders":    @(self.foodMaxMerchantOrders),
        @"foodMallKeywords":         self.foodMallKeywords ?: kDefaultFoodMallKeywords,
        @"foodChainKeywords":        self.foodChainKeywords ?: kDefaultFoodChainKeywords,
        @"foodAcceptLongDistance":   @(self.foodAcceptLongDistance),
        @"minFoodDistanceKm":        @(self.minFoodDistanceKm),
        @"smartCoolMode":            @(self.smartCoolMode),
        @"tapVerifyRetries":         @(self.tapVerifyRetries),
        @"hapticEnabled":            @(self.hapticEnabled),
        @"dryRunMode":               @(self.dryRunMode),

        @"pauseAfterRejectFood":     @(self.pauseAfterRejectFood),
        @"pauseDurationSec":         @(self.pauseDurationSec),
        @"autoKillAndRelaunchApp":   @(self.autoKillAndRelaunchApp),
        @"relaunchLeadSec":          @(self.relaunchLeadSec),
        @"driverAppBundleID":        self.driverAppBundleID ?: @"",
        @"driverAppExecName":        self.driverAppExecName ?: @"",
        @"driverAppDisplayName":     self.driverAppDisplayName ?: @"",

        @"mapRelayEnabled":          @(self.mapRelayEnabled),
        @"mapRelayTopic":            cleanTopic,
        @"mapRelayReturnToDriver":   @(self.mapRelayReturnToDriver),

        @"coordMode":                @(self.coordMode),
        @"closeXRatio":              @(self.closeXRatio),
        @"closeOffsetX":             @(self.closeOffsetX),
        @"closeOffsetY":             @(self.closeOffsetY),
        @"acceptOffsetX":            @(self.acceptOffsetX),
        @"acceptOffsetY":            @(self.acceptOffsetY),
        @"onlineOffsetX":            @(self.onlineOffsetX),
        @"onlineOffsetY":            @(self.onlineOffsetY),

        @"manualCloseX":             @(self.manualCloseX),
        @"manualCloseY":             @(self.manualCloseY),
        @"manualAcceptX":            @(self.manualAcceptX),
        @"manualAcceptY":            @(self.manualAcceptY),
        @"manualOfflineX":           @(self.manualOfflineX),
        @"manualOfflineY":           @(self.manualOfflineY),
        @"manualOnlineX":            @(self.manualOnlineX),
        @"manualOnlineY":            @(self.manualOnlineY),

        @"scanIntervalMs":           @(self.scanIntervalMs),
        @"acceptDelayMinMs":         @(self.acceptDelayMinMs),
        @"acceptDelayMaxMs":         @(self.acceptDelayMaxMs),
        @"rejectDelayMinMs":         @(self.rejectDelayMinMs),
        @"rejectDelayMaxMs":         @(self.rejectDelayMaxMs),
        @"jitterRadiusPt":           @(self.jitterRadiusPt),
        @"holdMinMs":                @(self.holdMinMs),
        @"holdMaxMs":                @(self.holdMaxMs),
        @"cooldownMs":               @(self.cooldownMs)
    };

    writeDictUnprotectedAtomically(dict, kConfigPlistPath);

    if (sendNotify) {
        notify_post(kNotifyReloadConfig);
    }
}

@end

#pragma mark - Frontmost App, Screen Lock & Memory Footprint Helpers

static NSString *cachedAutoDetectedDriverBundleID(void) {
    static NSString *sCachedBid = nil;
    static NSTimeInterval sLastDetectUp = 0.0;
    NSTimeInterval nowUp = [NSProcessInfo processInfo].systemUptime;
    if (sCachedBid.length > 0 && (nowUp - sLastDetectUp) < 120.0) {
        return sCachedBid;
    }
    if ((nowUp - sLastDetectUp) < 15.0) {
        return sCachedBid;
    }
    sLastDetectUp = nowUp;
    InstalledAppInfo *det = autoDetectDriverApp();
    if (det && det.bundleID.length > 0) {
        sCachedBid = [det.bundleID copy];
    }
    return sCachedBid;
}

BOOL bundleIDMatchesDriverApp(NSString *bid, FilterConfig *config) {
    if (!bid || bid.length == 0) return NO;
    if (config && config.driverAppBundleID.length > 0) {
        if ([bid isEqualToString:config.driverAppBundleID] ||
            [bid rangeOfString:config.driverAppBundleID options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    NSString *autoBid = cachedAutoDetectedDriverBundleID();
    if (autoBid.length > 0 &&
        ([bid isEqualToString:autoBid] ||
         [bid rangeOfString:autoBid options:NSCaseInsensitiveSearch].location != NSNotFound)) {
        return YES;
    }
    NSString *lower = bid.lowercaseString;
    if ([lower containsString:@"gsm"] ||
        [lower containsString:@"xanhsm"] ||
        [lower containsString:@"greensm"] ||
        [lower containsString:@"xanh.sm"] ||
        [lower containsString:@"green.sm"] ||
        [lower containsString:@"bactai"] ||
        [lower containsString:@"sm.driver"] ||
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
        // 1. Refresh BKSApplicationStateMonitor every 45s (reduces BackBoard XPC load >73% on iPhone 8 A11)
        if (!gAppStateMonitor || (nowUp - gLastBKSInitUp) > 45.0) {
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

            NSString *effectiveDriverBid = (config && config.driverAppBundleID.length > 0)
                ? config.driverAppBundleID
                : cachedAutoDetectedDriverBundleID();
            if (effectiveDriverBid.length > 0) {
                unsigned int drvSt = ((unsigned int (*)(id, SEL, NSString *))objc_msgSend)(
                    gAppStateMonitor, appStateSel, effectiveDriverBid);
                if ((drvSt & 8U) != 0) {
                    return effectiveDriverBid;
                }
            }

            unsigned int mapsSt = ((unsigned int (*)(id, SEL, NSString *))objc_msgSend)(
                gAppStateMonitor, appStateSel, @"com.google.Maps");
            if ((mapsSt & 8U) != 0) {
                mapsInForeground = YES;
            }
        }

        // 2. Periodically recycle FBSDisplayLayoutMonitor every 90s (cuts SpringBoard XPC churn on 2GB devices while gNilLayoutStreak self-heals instantly)
        if (gLayoutMonitor && (nowUp - gLastLayoutInitUp) > 90.0) {
            invalidateMonitorSafely(gLayoutMonitor);
            gLayoutMonitor = nil;
        }
        if (!gLayoutMonitor && (nowUp - gLastLayoutInitUp) > 2.0) {
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
                    if (bundleIDMatchesDriverApp(bid, config)) {
                        return bid;
                    }
                    if (bundleIDMatchesDriverApp(ident, config)) {
                        NSString *eff = (config && config.driverAppBundleID.length > 0)
                            ? config.driverAppBundleID
                            : cachedAutoDetectedDriverBundleID();
                        return eff.length > 0 ? eff : @"vn.gsm.driver";
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

BOOL isLowRAMDevice(void) {
    static BOOL sIsLow = NO;
    static dispatch_once_t onceTok;
    dispatch_once(&onceTok, ^{
        unsigned long long mem = [NSProcessInfo processInfo].physicalMemory;
        // iPhone 8 / SE2 / X <= 2.75 GB RAM -> aggressive proactive RAM trim & safe Jetsam priority
        sIsLow = (mem > 0 && mem <= (2800ULL * 1024ULL * 1024ULL));
    });
    return sIsLow;
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

static NSString *canonicalizedPathString(NSString *rawPath) {
    if (!rawPath || rawPath.length == 0) return nil;
    char resolved[PATH_MAX];
    const char *cStr = [rawPath fileSystemRepresentation];
    if (cStr && realpath(cStr, resolved) != NULL) {
        return [NSString stringWithUTF8String:resolved];
    }
    return rawPath;
}

NSString *resolveLiveAppPindBinaryPath(void) {
    NSFileManager *fm = [NSFileManager defaultManager];

    // Priority 1: Live LaunchServices bundle lookup (always returns NEW TrollStore UUID even inside old Watchdog!)
    Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
    Class proxyCls = NSClassFromString(@"LSApplicationProxy");
    if (proxyCls) {
        @try {
            SEL prxSel = NSSelectorFromString(@"applicationProxyForIdentifier:");
            if ([proxyCls respondsToSelector:prxSel]) {
                id proxy = ((id (*)(id, SEL, NSString *))objc_msgSend)(proxyCls, prxSel, kAppBundleID);
                NSURL *bUrl = proxy ? [proxy valueForKey:@"bundleURL"] : nil;
                NSString *bPath = [bUrl isKindOfClass:[NSURL class]] ? bUrl.path : nil;
                if (bPath.length > 0) {
                    NSString *cand = [bPath stringByAppendingPathComponent:@"pind"];
                    if ([fm fileExistsAtPath:cand]) {
                        return canonicalizedPathString(cand);
                    }
                }
            }
        } @catch (NSException *ex) {}
    }
    if (wsCls) {
        @try {
            SEL defSel = NSSelectorFromString(@"defaultWorkspace");
            id ws = [wsCls respondsToSelector:defSel] ? ((id (*)(id, SEL))objc_msgSend)(wsCls, defSel) : nil;
            SEL allSel = NSSelectorFromString(@"allInstalledApplications");
            if (ws && [ws respondsToSelector:allSel]) {
                NSArray *proxies = ((NSArray * (*)(id, SEL))objc_msgSend)(ws, allSel);
                for (id proxy in proxies) {
                    NSString *bid = [proxy valueForKey:@"applicationIdentifier"];
                    if ([bid isEqualToString:kAppBundleID]) {
                        NSURL *bUrl = [proxy valueForKey:@"bundleURL"];
                        NSString *bPath = [bUrl isKindOfClass:[NSURL class]] ? bUrl.path : nil;
                        if (bPath.length > 0) {
                            NSString *cand = [bPath stringByAppendingPathComponent:@"pind"];
                            if ([fm fileExistsAtPath:cand]) {
                                return canonicalizedPathString(cand);
                            }
                        }
                    }
                }
            }
        } @catch (NSException *ex) {}
    }

    // Priority 2: Current process mainBundle (valid inside UI App)
    NSString *candBundle = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"pind"];
    if (candBundle.length > 0 && [fm fileExistsAtPath:candBundle]) {
        return canonicalizedPathString(candBundle);
    }

    // Priority 3: Direct filesystem scan of /var/containers/Bundle/Application/*/PinNhietDo.app/pind (works as uid=0 even if lsd is busy!)
    NSString *appsRoot = @"/var/containers/Bundle/Application";
    NSArray<NSString *> *uuids = [fm contentsOfDirectoryAtPath:appsRoot error:nil];
    NSString *newestPind = nil;
    time_t newestMtime = 0;
    for (NSString *u in uuids) {
        NSString *cand = [[appsRoot stringByAppendingPathComponent:u] stringByAppendingPathComponent:@"PinNhietDo.app/pind"];
        struct stat st;
        if (stat([cand fileSystemRepresentation], &st) == 0 && S_ISREG(st.st_mode)) {
            if (!newestPind || st.st_mtime >= newestMtime) {
                newestMtime = st.st_mtime;
                newestPind  = cand;
            }
        }
    }
    if (newestPind) {
        return canonicalizedPathString(newestPind);
    }

    // Priority 4: argv[0] fallback if still present on disk
    NSString *arg0 = [NSProcessInfo processInfo].arguments.firstObject;
    if (arg0.length > 0 && [arg0.lastPathComponent isEqualToString:@"pind"] && [fm fileExistsAtPath:arg0]) {
        return canonicalizedPathString(arg0);
    }
    return nil;
}

static NSString *resolvePindBinaryPath(void) {
    return resolveLiveAppPindBinaryPath();
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
    int openFlags = O_CREAT | O_RDWR;
#ifdef O_CLOEXEC
    openFlags |= O_CLOEXEC;
#endif
    int fd = open(kDaemonControlLockPath, openFlags, 0666);
    if (fd >= 0) {
        fcntl(fd, F_SETFD, FD_CLOEXEC);
        fcntl(fd, F_SETPROTECTIONCLASS, PROTECTION_CLASS_D);
        if (geteuid() == 0) {
            chown(kDaemonControlLockPath, 501, 501);
        }
        chmod(kDaemonControlLockPath, 0666);

        BOOL locked = NO;
        for (int i = 0; i < 24; i++) {
            if (flock(fd, LOCK_EX | LOCK_NB) == 0) {
                locked = YES;
                break;
            }
            usleep(50000);
        }
        if (!locked) {
            // Break stale lock held by any hung/orphaned descriptor so control never deadlocks!
            close(fd);
            unlink(kDaemonControlLockPath);
            fd = open(kDaemonControlLockPath, openFlags, 0666);
            if (fd >= 0) {
                fcntl(fd, F_SETFD, FD_CLOEXEC);
                fcntl(fd, F_SETPROTECTIONCLASS, PROTECTION_CLASS_D);
                chmod(kDaemonControlLockPath, 0666);
                flock(fd, LOCK_EX | LOCK_NB);
            }
        }
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

    // Clear stale Food Pause & Heartbeat so next start begins scanning immediately at 0ms!
    RuntimeDaemonState *st = [RuntimeDaemonState loadState];
    if (st.pauseEndEpoch > 0.0 || st.workerHeartbeatEpoch > 0.0) {
        st.pauseEndEpoch        = 0.0;
        st.workerHeartbeatEpoch = 0.0;
        st.phaseDescription     = @"Đang trực tuyến / Canh đơn";
        [st saveStateAndNotify:NO];
    }

    // Execute --stop as uid=0 via spawnRoot so root Watchdog & Worker are guaranteed terminated cleanly
    NSString *daemonPath = resolvePindBinaryPath();
    if (daemonPath.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:daemonPath]) {
        chmod([daemonPath fileSystemRepresentation], 0755);
        spawnRoot(daemonPath, @[@"--stop"]);
        usleep(100000);
    } else {
        pid_t wdPid = getRunningWatchdogPID();
        if (wdPid > 1) kill(wdPid, SIGKILL);
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

        NSString *liveDaemonPath = resolvePindBinaryPath();
        if (!liveDaemonPath || liveDaemonPath.length == 0) {
            liveDaemonPath = canonicalizedPathString([[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"pind"]);
        }

        pid_t existingWatchdog = getRunningWatchdogPID();
        if (existingWatchdog > 0) {
            // Wait up to 1.2s if Watchdog is in the middle of spawning/recycling Worker
            for (int w = 0; w < 6 && getRunningDaemonPID() <= 0; w++) {
                usleep(200000);
                if (getRunningWatchdogPID() <= 0) break;
            }

            existingWatchdog = getRunningWatchdogPID();
            pid_t existingWorker = getRunningDaemonPID();
            RuntimeDaemonState *st = [RuntimeDaemonState loadState];

            BOOL sameBundlePath = (liveDaemonPath.length == 0) ||
                                  (st.daemonBinaryPath.length > 0 &&
                                   [st.daemonBinaryPath isEqualToString:liveDaemonPath] &&
                                   access([liveDaemonPath fileSystemRepresentation], X_OK) == 0);

            if (existingWatchdog > 0 && existingWorker > 0 &&
                [st.daemonVersion isEqualToString:kCurrentDaemonVersion] &&
                sameBundlePath) {
                double now = [[NSDate date] timeIntervalSince1970];
                if (st.workerHeartbeatEpoch > 0.0 && fabs(now - st.workerHeartbeatEpoch) < 22.0) {
                    notify_post(kNotifyReloadConfig);
                    finalResult = YES;
                    return finalResult;
                }

                // Device may have just woken from pocket sleep -> poke Worker and wait up to 1.5s
                notify_post(kNotifyReloadConfig);
                for (int k = 0; k < 6; k++) {
                    usleep(250000);
                    st  = [RuntimeDaemonState loadState];
                    now = [[NSDate date] timeIntervalSince1970];
                    if (getRunningWatchdogPID() > 0 &&
                        getRunningDaemonPID() > 0 &&
                        st.workerHeartbeatEpoch > 0.0 &&
                        fabs(now - st.workerHeartbeatEpoch) < 22.0) {
                        finalResult = YES;
                        return finalResult;
                    }
                }
            }
        }

        stopFilterDaemonUnlocked();

        NSString *daemonPath = liveDaemonPath;
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

        appendDaemonLog(@"[LỖI] Không kích được pind v5.0 (mã: %d). Hãy kiểm tra đã cài qua TrollStore chưa.", res);
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

#pragma mark - Navigation URL Interceptor & Dual-Path Peer Relay (ntfy.sh + Anti-DNS-Poison IP Fallback)

BOOL isGoogleMapsInstalledOnDevice(void) {
    Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
    if (wsCls) {
        @try {
            SEL defSel = NSSelectorFromString(@"defaultWorkspace");
            id ws = [wsCls respondsToSelector:defSel] ? ((id (*)(id, SEL))objc_msgSend)(wsCls, defSel) : nil;
            SEL instSel = NSSelectorFromString(@"applicationIsInstalled:");
            if (ws && [ws respondsToSelector:instSel]) {
                return ((BOOL (*)(id, SEL, NSString *))objc_msgSend)(ws, instSel, @"com.google.Maps");
            }
        } @catch (NSException *ex) {}
    }
    return NO;
}

static BOOL extractFirstLatLngPairFromString(NSString *str, double *outLat, double *outLng) {
    if (!str || str.length < 7) return NO;
    static NSRegularExpression *sCoordRx = nil;
    static dispatch_once_t onceTok;
    dispatch_once(&onceTok, ^{
        sCoordRx = [NSRegularExpression regularExpressionWithPattern:
            @"(-?\\d{1,2}\\.\\d{3,12})\\s*,\\s*(-?\\d{1,3}\\.\\d{3,12})"
            options:0 error:nil];
    });
    if (!sCoordRx) return NO;
    NSTextCheckingResult *m = [sCoordRx firstMatchInString:str options:0 range:NSMakeRange(0, str.length)];
    if (!m || m.numberOfRanges < 3) return NO;

    double lat = [[str substringWithRange:[m rangeAtIndex:1]] doubleValue];
    double lng = [[str substringWithRange:[m rangeAtIndex:2]] doubleValue];
    if (fabs(lat) > 90.0 || fabs(lng) > 180.0) return NO;
    if (fabs(lat) < 0.001 && fabs(lng) < 0.001) return NO;

    if (outLat) *outLat = lat;
    if (outLng) *outLng = lng;
    return YES;
}

static NSString *decodeURLQueryComponent(NSString *raw) {
    if (!raw || raw.length == 0) return @"";
    NSString *plusFixed = [raw stringByReplacingOccurrencesOfString:@"+" withString:@" "];
    NSString *decoded = [plusFixed stringByRemovingPercentEncoding];
    return [(decoded ?: plusFixed) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

BOOL parseNavigationTargetFromString(NSString *rawInput,
                                     BOOL *outHasCoords,
                                     double *outLat,
                                     double *outLng,
                                     NSString * __strong *outQueryLabel) {
    if (outHasCoords)  *outHasCoords  = NO;
    if (outLat)        *outLat        = 0.0;
    if (outLng)        *outLng        = 0.0;
    if (outQueryLabel) *outQueryLabel = @"";

    if (!rawInput) return NO;
    NSString *trimmed = [rawInput stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length < 4) return NO;

    // 1. Handle Android-style google.navigation:q=... if ever pasted/tested
    if ([trimmed.lowercaseString hasPrefix:@"google.navigation:"]) {
        NSRange qRange = [trimmed rangeOfString:@"q=" options:NSCaseInsensitiveSearch];
        if (qRange.location != NSNotFound) {
            NSString *rest = [trimmed substringFromIndex:qRange.location + 2];
            NSRange amp = [rest rangeOfString:@"&"];
            if (amp.location != NSNotFound) rest = [rest substringToIndex:amp.location];
            NSString *dec = decodeURLQueryComponent(rest);
            double lat = 0.0, lng = 0.0;
            if (extractFirstLatLngPairFromString(dec, &lat, &lng)) {
                if (outHasCoords)  *outHasCoords  = YES;
                if (outLat)        *outLat        = lat;
                if (outLng)        *outLng        = lng;
                if (outQueryLabel) *outQueryLabel = [NSString stringWithFormat:@"%.6f, %.6f", lat, lng];
                return YES;
            } else if (dec.length >= 3) {
                if (outQueryLabel) *outQueryLabel = dec;
                return YES;
            }
        }
    }

    // 2. Parse URL query parameters with strict destination priority (daddr > destination > to > q > query > ll > center)
    NSURLComponents *comp = [NSURLComponents componentsWithString:trimmed];
    if (comp) {
        NSMutableDictionary<NSString *, NSString *> *qMap = [NSMutableDictionary dictionary];
        for (NSURLQueryItem *item in comp.queryItems) {
            if (item.name.length > 0 && item.value.length > 0) {
                qMap[item.name.lowercaseString] = [item.value stringByReplacingOccurrencesOfString:@"+" withString:@" "];
            }
        }
        // Fallback manual query parse if raw URL had unescaped '+' or nested params
        if (qMap.count == 0 && comp.percentEncodedQuery.length > 0) {
            NSArray<NSString *> *pairs = [comp.percentEncodedQuery componentsSeparatedByString:@"&"];
            for (NSString *pair in pairs) {
                NSRange eq = [pair rangeOfString:@"="];
                if (eq.location != NSNotFound && eq.location > 0 && eq.location + 1 < pair.length) {
                    NSString *k = [[pair substringToIndex:eq.location] lowercaseString];
                    NSString *v = decodeURLQueryComponent([pair substringFromIndex:eq.location + 1]);
                    if (v.length > 0) qMap[k] = v;
                }
            }
        }

        NSArray<NSString *> *destKeys = @[@"daddr", @"destination", @"to", @"q", @"query", @"ll", @"sll", @"center", @"coord", @"target"];
        for (NSString *dk in destKeys) {
            NSString *val = qMap[dk];
            if (!val || val.length == 0) continue;
            NSString *cleanVal = [val stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([cleanVal.lowercaseString hasPrefix:@"loc:"]) {
                cleanVal = [[cleanVal substringFromIndex:4] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            }
            double lat = 0.0, lng = 0.0;
            if (extractFirstLatLngPairFromString(cleanVal, &lat, &lng)) {
                if (outHasCoords)  *outHasCoords  = YES;
                if (outLat)        *outLat        = lat;
                if (outLng)        *outLng        = lng;
                if (outQueryLabel) *outQueryLabel = [NSString stringWithFormat:@"%.6f, %.6f", lat, lng];
                return YES;
            }
            if (cleanVal.length >= 3) {
                if (outQueryLabel) *outQueryLabel = cleanVal;
                return YES;
            }
        }

        // Check URL path for /maps/dir/<origin>/<dest> or /@lat,lng
        NSString *path = comp.path ?: @"";
        if (path.length > 0) {
            NSRange atRange = [path rangeOfString:@"@"];
            if (atRange.location != NSNotFound) {
                NSString *afterAt = [path substringFromIndex:atRange.location + 1];
                double lat = 0.0, lng = 0.0;
                if (extractFirstLatLngPairFromString(afterAt, &lat, &lng)) {
                    if (outHasCoords)  *outHasCoords  = YES;
                    if (outLat)        *outLat        = lat;
                    if (outLng)        *outLng        = lng;
                    if (outQueryLabel) *outQueryLabel = [NSString stringWithFormat:@"%.6f, %.6f", lat, lng];
                    return YES;
                }
            }
            if ([path.lowercaseString containsString:@"/dir/"]) {
                NSArray<NSString *> *segs = [path componentsSeparatedByString:@"/"];
                if (segs.count >= 2) {
                    NSString *lastSeg = decodeURLQueryComponent(segs.lastObject);
                    double lat = 0.0, lng = 0.0;
                    if (extractFirstLatLngPairFromString(lastSeg, &lat, &lng)) {
                        if (outHasCoords)  *outHasCoords  = YES;
                        if (outLat)        *outLat        = lat;
                        if (outLng)        *outLng        = lng;
                        if (outQueryLabel) *outQueryLabel = [NSString stringWithFormat:@"%.6f, %.6f", lat, lng];
                        return YES;
                    }
                }
            }
        }
    }

    // 3. Direct coordinate pair or plain address text (excluding saddr=... if raw malformed URL)
    NSString *scrubbed = trimmed;
    NSRange daddrPos = [scrubbed rangeOfString:@"daddr=" options:NSCaseInsensitiveSearch];
    if (daddrPos.location != NSNotFound) {
        scrubbed = [scrubbed substringFromIndex:daddrPos.location + 6];
        NSRange amp = [scrubbed rangeOfString:@"&"];
        if (amp.location != NSNotFound) scrubbed = [scrubbed substringToIndex:amp.location];
        scrubbed = decodeURLQueryComponent(scrubbed);
    }

    double directLat = 0.0, directLng = 0.0;
    if (extractFirstLatLngPairFromString(scrubbed, &directLat, &directLng)) {
        if (outHasCoords)  *outHasCoords  = YES;
        if (outLat)        *outLat        = directLat;
        if (outLng)        *outLng        = directLng;
        if (outQueryLabel) *outQueryLabel = [NSString stringWithFormat:@"%.6f, %.6f", directLat, directLng];
        return YES;
    }

    if (![trimmed containsString:@"://"] && trimmed.length >= 5) {
        if (outQueryLabel) *outQueryLabel = trimmed;
        return YES;
    }

    return NO;
}

static NSURLSession *sharedMapRelayURLSession(void) {
    static NSURLSession *sSess = nil;
    static dispatch_once_t onceTok;
    dispatch_once(&onceTok, ^{
        NSURLSessionConfiguration *sc = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        sc.timeoutIntervalForRequest  = 3.2;
        sc.timeoutIntervalForResource = 4.2;
        sc.waitsForConnectivity       = NO;
        sc.HTTPMaximumConnectionsPerHost = 2;
        sSess = [NSURLSession sessionWithConfiguration:sc];
    });
    return sSess;
}

static NSString *resolveNtfyIPv4ViaCloudflareDoH(void) {
    // Queries literal 1.1.1.1 over HTTPS (zero local DNS lookup!) when iOS 16 mDNSResponder is poisoned on Android Hotspot
    NSURL *dohURL = [NSURL URLWithString:@"https://1.1.1.1/dns-query?name=ntfy.sh&type=A"];
    if (!dohURL) return @"159.203.148.75";
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:dohURL
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:1.5];
    [req setValue:@"application/dns-json" forHTTPHeaderField:@"Accept"];

    __block NSString *resolvedIP = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[sharedMapRelayURLSession() dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (data && !err) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSArray *ans = [json isKindOfClass:[NSDictionary class]] ? json[@"Answer"] : nil;
            if ([ans isKindOfClass:[NSArray class]]) {
                for (NSDictionary *rec in ans) {
                    if ([rec isKindOfClass:[NSDictionary class]] && [rec[@"type"] intValue] == 1) {
                        NSString *ip = rec[@"data"];
                        if ([ip isKindOfClass:[NSString class]] && ip.length >= 7) {
                            resolvedIP = ip;
                            break;
                        }
                    }
                }
            }
        }
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)));
    return resolvedIP.length >= 7 ? resolvedIP : @"159.203.148.75";
}

static BOOL postNtfyPayloadSynchronously(NSString *urlString,
                                         NSString *hostHeaderOverride,
                                         NSString *clickURL,
                                         NSData *jsonBody,
                                         NSError * __strong *outError) {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url || !jsonBody) return NO;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:3.2];
    req.HTTPMethod = @"POST";
    req.HTTPBody   = jsonBody;
    [req setValue:@"application/json; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"Xanh SM -> Mo Google Maps"       forHTTPHeaderField:@"Title"];
    [req setValue:@"5"                               forHTTPHeaderField:@"Priority"];
    [req setValue:@"motorcycle,round_pushpin"        forHTTPHeaderField:@"Tags"];
    if (clickURL.length > 0) {
        [req setValue:clickURL forHTTPHeaderField:@"Click"];
    }
    if (hostHeaderOverride.length > 0) {
        [req setValue:hostHeaderOverride forHTTPHeaderField:@"Host"];
    }

    __block BOOL success = NO;
    __block NSError *reqErr = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[sharedMapRelayURLSession() dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSHTTPURLResponse *http = [resp isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)resp : nil;
        if (!err && http && http.statusCode >= 200 && http.statusCode < 300) {
            success = YES;
        } else {
            reqErr = err;
        }
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)));
    if (outError) *outError = reqErr;
    return success;
}

void dispatchMapRelayPayloadAsync(double lat,
                                  double lng,
                                  BOOL hasCoords,
                                  NSString *queryLabel,
                                  NSString *sourceTag,
                                  FilterConfig *config,
                                  void (^completion)(BOOL ok, NSString *detail)) {
    FilterConfig *cfg = config ?: [FilterConfig loadFromDisk];
    NSString *topic = sanitizeMapRelayTopic(cfg.mapRelayTopic);
    if (topic.length < 4) {
        topic = generateRandomMapRelayTopic();
        cfg.mapRelayTopic = topic;
        [cfg saveToDiskAndNotify:NO];
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        NSString *destParam = hasCoords
            ? [NSString stringWithFormat:@"%.6f,%.6f", lat, lng]
            : ([queryLabel stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: @"");
        NSString *humanLabel = hasCoords
            ? [NSString stringWithFormat:@"%.6f, %.6f", lat, lng]
            : (queryLabel ?: @"Điểm đến");

        NSString *gmapsWebURL = [NSString stringWithFormat:
            @"https://www.google.com/maps/dir/?api=1&destination=%@&travelmode=two-wheeler", destParam];
        NSString *androidNavURI = [NSString stringWithFormat:
            @"google.navigation:q=%@&mode=l", destParam];
        NSString *iosNavURI = [NSString stringWithFormat:
            @"comgooglemaps://?daddr=%@&directionsmode=driving", destParam];

        uint64_t tsMs = (uint64_t)([[NSDate date] timeIntervalSince1970] * 1000.0);
        NSString *nonce = [NSString stringWithFormat:@"%llu-%u", tsMs, arc4random_uniform(999999)];

        NSDictionary *payload = @{
            @"v":          @(1),
            @"id":         nonce,
            @"hasCoords":  @(hasCoords),
            @"lat":        @(hasCoords ? lat : 0.0),
            @"lng":        @(hasCoords ? lng : 0.0),
            @"label":      humanLabel,
            @"source":     sourceTag ?: @"XanhSM",
            @"gmapsUrl":   gmapsWebURL,
            @"androidUri": androidNavURI,
            @"iosUri":     iosNavURI,
            @"ts":         @(tsMs)
        };
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];

        NSString *primaryURL = [NSString stringWithFormat:@"https://ntfy.sh/%@", topic];
        NSError *netErr = nil;
        BOOL usedDirectIP = NO;
        BOOL sentOK = postNtfyPayloadSynchronously(primaryURL, nil, gmapsWebURL, jsonData, &netErr);

        if (!sentOK) {
            // Instant Anti-DNS-Poison Bypass for iPhone 8 on Android Hotspot:
            // Resolve ntfy.sh via literal 1.1.1.1 DoH (or hardcoded 159.203.148.75) and push directly by IP!
            NSString *directIP = resolveNtfyIPv4ViaCloudflareDoH();
            NSString *fallbackURL = [NSString stringWithFormat:@"http://%@/%@", directIP, topic];
            sentOK = postNtfyPayloadSynchronously(fallbackURL, @"ntfy.sh", gmapsWebURL, jsonData, &netErr);
            if (sentOK) {
                usedDirectIP = YES;
            }
        }

        double doneEpoch = [[NSDate date] timeIntervalSince1970];
        RuntimeDaemonState *st = [RuntimeDaemonState loadState];
        if (sentOK) {
            st.lastRelayedSummary = [NSString stringWithFormat:@"%@ (%@)", humanLabel, usedDirectIP ? @"Xuyên DNS" : @"OK"];
            st.lastRelayedEpoch   = doneEpoch;
            [st saveStateAndNotify:YES];
            appendDaemonLog(@"[BẮN MAP %@] %@ -> Kênh '%@'%@",
                            sourceTag ?: @"XanhSM",
                            humanLabel,
                            topic,
                            usedDirectIP ? @" [Đã vượt rào lỗi DNS Hotspot!]" : @"");
        } else {
            appendDaemonLog(@"[LỖI BẮN MAP] Chưa gửi được '%@' (Kiểm tra Wi-Fi/4G trên iPhone 8: %@)",
                            humanLabel,
                            netErr.localizedDescription ?: @"Mất kết nối");
            notify_post(kNotifyStatsUpdated);
        }

        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(sentOK, humanLabel);
            });
        }
    });
}

void processPendingMapRelayQueueIfAny(FilterConfig *config) {
    const char *cPath = [kMapRelayQueuePath fileSystemRepresentation];
    if (!cPath || access(cPath, F_OK) != 0) return;

    NSDictionary *q = readDictSafelyWithRetry(kMapRelayQueuePath);
    unlink(cPath);
    if (!q || ![q isKindOfClass:[NSDictionary class]]) return;

    double qEpoch = [q[@"epoch"] doubleValue];
    double now = [[NSDate date] timeIntervalSince1970];
    if (qEpoch > 0.0 && fabs(now - qEpoch) > 25.0) {
        return; // Expired stale item
    }

    BOOL hasCoords  = [q[@"hasCoords"] boolValue];
    double lat      = [q[@"lat"] doubleValue];
    double lng      = [q[@"lng"] doubleValue];
    NSString *label = [q[@"label"] isKindOfClass:[NSString class]] ? q[@"label"] : @"";
    NSString *src   = [q[@"source"] isKindOfClass:[NSString class]] ? q[@"source"] : @"XanhSM";

    if (!hasCoords && label.length == 0) return;
    dispatchMapRelayPayloadAsync(lat, lng, hasCoords, label, src, config, nil);
}

BOOL enqueueAndTriggerMapRelayFromURLString(NSString *rawInput,
                                            NSString *sourceTag,
                                            BOOL allowReturnToDriver,
                                            void (^completion)(BOOL ok, NSString *detail)) {
    static NSString *sLastRawURL = nil;
    static double sLastRawEpoch  = 0.0;

    if (!rawInput || rawInput.length == 0) return NO;
    double now = [[NSDate date] timeIntervalSince1970];
    if (!completion && sLastRawURL && [sLastRawURL isEqualToString:rawInput] && fabs(now - sLastRawEpoch) < 1.2) {
        return YES; // Deduplicate double launch callback from iOS UIKit
    }
    sLastRawURL   = [rawInput copy];
    sLastRawEpoch = now;

    FilterConfig *cfg = [FilterConfig loadFromDisk];
    if (!cfg.mapRelayEnabled && allowReturnToDriver) {
        appendDaemonLog(@"[BẮN MAP] Nhận link Điều hướng nhưng công tắc Bắn Map đang TẮT.");
        notify_post(kNotifyStatsUpdated);
        return NO;
    }

    BOOL hasCoords = NO;
    double lat = 0.0, lng = 0.0;
    NSString *label = nil;
    if (!parseNavigationTargetFromString(rawInput, &hasCoords, &lat, &lng, &label)) {
        appendDaemonLog(@"[BẮN MAP] Không tách được tọa độ từ URL: %@", rawInput);
        notify_post(kNotifyStatsUpdated);
        if (completion) completion(NO, rawInput);
        return NO;
    }

    if (cfg.hapticEnabled) {
        triggerHapticFeedback(NO);
    }

    NSString *nonce = [NSString stringWithFormat:@"%llu-%u", (uint64_t)(now * 1000.0), arc4random_uniform(999999)];
    pid_t daemonPid = getRunningDaemonPID();

    if (daemonPid > 0 && !completion) {
        // Hand off to background pind worker so PinNhietDo UI app can jump back to Xanh SM in 0.06s with zero suspension risk!
        NSDictionary *qDict = @{
            @"nonce":     nonce,
            @"hasCoords": @(hasCoords),
            @"lat":       @(lat),
            @"lng":       @(lng),
            @"label":     label ?: @"",
            @"source":    sourceTag ?: @"XanhSM",
            @"epoch":     @(now)
        };
        writeDictUnprotectedAtomically(qDict, kMapRelayQueuePath);
        notify_post(kNotifySendMapRelay);

        // Safety net: if pind worker was sleeping/recycling and didn't consume kMapRelayQueuePath within 0.45s, send directly!
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            const char *cPath = [kMapRelayQueuePath fileSystemRepresentation];
            if (cPath && access(cPath, F_OK) == 0) {
                NSDictionary *rem = readDictSafelyWithRetry(kMapRelayQueuePath);
                if ([rem isKindOfClass:[NSDictionary class]] && [rem[@"nonce"] isEqual:nonce]) {
                    unlink(cPath);
                    dispatchMapRelayPayloadAsync(lat, lng, hasCoords, label, sourceTag, cfg, nil);
                }
            }
        });
    } else {
        // Master daemon is OFF or interactive UI test requested -> send directly!
        dispatchMapRelayPayloadAsync(lat, lng, hasCoords, label, sourceTag, cfg, completion);
    }

    if (allowReturnToDriver && cfg.mapRelayReturnToDriver) {
        NSString *driverBid = cfg.driverAppBundleID;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            launchAppByBundleID(driverBid);
        });
    }

    return YES;
}
