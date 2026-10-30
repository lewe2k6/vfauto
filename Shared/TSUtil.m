#import "SharedConfig.h"
#import <AudioToolbox/AudioToolbox.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <spawn.h>
#import <signal.h>
#import <notify.h>
#import <sys/stat.h>
#import <unistd.h>
#import <errno.h>

#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
typedef int (*persona_np_f)(const posix_spawnattr_t * __restrict, uid_t, uint32_t);
typedef int (*persona_id_f)(const posix_spawnattr_t * __restrict, uid_t);
typedef void (*BKSTerminateApp_f)(CFStringRef bundleID, int reasonID, bool report, CFStringRef description);
typedef int (*SBSLaunchApp_f)(CFStringRef bundleID, Boolean suspended);
extern char **environ;

@implementation InstalledAppInfo
@end

@implementation RuntimeDaemonState

- (instancetype)init {
    self = [super init];
    if (self) {
        _statAcceptedCount = 0;
        _statRejectedCount = 0;
        _navPickupLocked   = NO;
        _navDropoffLocked  = NO;
        _pauseEndEpoch     = 0.0;
        _phaseDescription  = @"Đang rảnh / Canh đơn";
        _daemonVersion     = @"";
    }
    return self;
}

+ (instancetype)loadState {
    RuntimeDaemonState *st = [[RuntimeDaemonState alloc] init];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kRuntimeStatePath];
    if (!d) return st;
    if (d[@"statAcceptedCount"]) st.statAcceptedCount = [d[@"statAcceptedCount"] integerValue];
    if (d[@"statRejectedCount"]) st.statRejectedCount = [d[@"statRejectedCount"] integerValue];
    if (d[@"navPickupLocked"])   st.navPickupLocked   = [d[@"navPickupLocked"] boolValue];
    if (d[@"navDropoffLocked"])  st.navDropoffLocked  = [d[@"navDropoffLocked"] boolValue];
    if (d[@"pauseEndEpoch"])     st.pauseEndEpoch     = [d[@"pauseEndEpoch"] doubleValue];
    if (d[@"phaseDescription"])  st.phaseDescription  = d[@"phaseDescription"];
    if (d[@"daemonVersion"])     st.daemonVersion     = d[@"daemonVersion"];
    return st;
}

- (void)saveStateAndNotify:(BOOL)sendNotify {
    NSDictionary *d = @{
        @"statAcceptedCount": @(self.statAcceptedCount),
        @"statRejectedCount": @(self.statRejectedCount),
        @"navPickupLocked":   @(self.navPickupLocked),
        @"navDropoffLocked":  @(self.navDropoffLocked),
        @"pauseEndEpoch":     @(self.pauseEndEpoch),
        @"phaseDescription":  self.phaseDescription ?: @"",
        @"daemonVersion":     self.daemonVersion ?: @""
    };
    [d writeToFile:kRuntimeStatePath atomically:YES];
    chmod([kRuntimeStatePath fileSystemRepresentation], 0666);
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
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:kConfigPlistPath];
    if (!dict) {
        // Attempt auto-detection of driver app on first load
        InstalledAppInfo *detected = autoDetectDriverApp();
        if (detected) {
            cfg.driverAppBundleID    = detected.bundleID;
            cfg.driverAppExecName    = detected.executableName;
            cfg.driverAppDisplayName = detected.displayName;
        }
        return cfg;
    }

    if (dict[@"masterEnabled"])          cfg.masterEnabled          = [dict[@"masterEnabled"] boolValue];
    if (dict[@"autoAcceptBike"])         cfg.autoAcceptBike         = [dict[@"autoAcceptBike"] boolValue];
    if (dict[@"rejectAllFood"])          cfg.rejectAllFood          = [dict[@"rejectAllFood"] boolValue];
    if (dict[@"minFoodPriceVND"])        cfg.minFoodPriceVND        = [dict[@"minFoodPriceVND"] integerValue];
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

    if (cfg.driverAppBundleID.length == 0) {
        InstalledAppInfo *detected = autoDetectDriverApp();
        if (detected) {
            cfg.driverAppBundleID    = detected.bundleID;
            cfg.driverAppExecName    = detected.executableName;
            cfg.driverAppDisplayName = detected.displayName;
        }
    }

    if (cfg.acceptDelayMaxMs < cfg.acceptDelayMinMs) cfg.acceptDelayMaxMs = cfg.acceptDelayMinMs + 50;
    if (cfg.rejectDelayMaxMs < cfg.rejectDelayMinMs) cfg.rejectDelayMaxMs = cfg.rejectDelayMinMs + 50;
    if (cfg.holdMaxMs < cfg.holdMinMs) cfg.holdMaxMs = cfg.holdMinMs + 15;
    if (cfg.scanIntervalMs < 150) cfg.scanIntervalMs = 150;
    if (cfg.pauseDurationSec < 20) cfg.pauseDurationSec = 20;
    if (cfg.navTapCount < 1) cfg.navTapCount = 1;
    if (cfg.navTapCount > 5) cfg.navTapCount = 5;

    return cfg;
}

- (void)saveToDiskAndNotify:(BOOL)sendNotify {
    NSDictionary *dict = @{
        @"masterEnabled":          @(self.masterEnabled),
        @"autoAcceptBike":         @(self.autoAcceptBike),
        @"rejectAllFood":          @(self.rejectAllFood),
        @"minFoodPriceVND":        @(self.minFoodPriceVND),
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

    [dict writeToFile:kConfigPlistPath atomically:YES];
    chmod([kConfigPlistPath fileSystemRepresentation], 0666);

    if (sendNotify) {
        notify_post(kNotifyReloadConfig);
    }
}

@end

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

BOOL killAppByBundleIDAndExec(NSString *bundleID, NSString *execName) {
    if (!bundleID || bundleID.length == 0) {
        InstalledAppInfo *det = autoDetectDriverApp();
        if (!det) return NO;
        bundleID = det.bundleID;
    }

    void *bks = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_LAZY);
    if (bks) {
        BKSTerminateApp_f fnTerm = (BKSTerminateApp_f)dlsym(bks, "BKSTerminateApplicationForReasonAndReportWithDescription");
        if (fnTerm) {
            fnTerm((__bridge CFStringRef)bundleID, 5, false, CFSTR("Session refresh"));
            return YES;
        }
    }
    return NO;
}

BOOL launchAppByBundleID(NSString *bundleID) {
    if (!bundleID || bundleID.length == 0) {
        InstalledAppInfo *det = autoDetectDriverApp();
        if (!det) return NO;
        bundleID = det.bundleID;
    }

    Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
    if (wsCls) {
        SEL defSel = NSSelectorFromString(@"defaultWorkspace");
        id workspace = ((id (*)(id, SEL))objc_msgSend)(wsCls, defSel);
        SEL openSel = NSSelectorFromString(@"openApplicationWithBundleID:");
        if (workspace && [workspace respondsToSelector:openSel]) {
            BOOL ok = ((BOOL (*)(id, SEL, NSString *))objc_msgSend)(workspace, openSel, bundleID);
            if (ok) return YES;
        }
    }

    void *sbs = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
    if (sbs) {
        SBSLaunchApp_f fnLaunch = (SBSLaunchApp_f)dlsym(sbs, "SBSLaunchApplicationWithIdentifier");
        if (fnLaunch) {
            return (fnLaunch((__bridge CFStringRef)bundleID, false) == 0);
        }
    }
    return NO;
}

#pragma mark - TrollStore Root Spawner & Daemon Control

int spawnRoot(NSString *path, NSArray<NSString *> *args) {
    NSMutableArray *fullArgs = [NSMutableArray arrayWithObject:path];
    if (args) [fullArgs addObjectsFromArray:args];

    int argc = (int)fullArgs.count;
    char **argv = calloc(argc + 1, sizeof(char *));
    for (int i = 0; i < argc; i++) {
        argv[i] = strdup([fullArgs[i] UTF8String]);
    }
    argv[argc] = NULL;

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);

    persona_np_f fnSetPersona = (persona_np_f)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_np");
    persona_id_f fnSetUid     = (persona_id_f)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_uid_np");
    persona_id_f fnSetGid     = (persona_id_f)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_gid_np");

    if (fnSetPersona) fnSetPersona(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    if (fnSetUid)     fnSetUid(&attr, 0);
    if (fnSetGid)     fnSetGid(&attr, 0);

    posix_spawnattr_setpgroup(&attr, 0);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);

    pid_t pid = 0;
    int ret = posix_spawn(&pid, [path fileSystemRepresentation], NULL, &attr, argv, environ);

    posix_spawnattr_destroy(&attr);
    for (int i = 0; i < argc; i++) free(argv[i]);
    free(argv);

    return (ret == 0) ? (int)pid : -ret;
}

pid_t getRunningDaemonPID(void) {
    NSString *pidStr = [NSString stringWithContentsOfFile:kDaemonPidPath encoding:NSUTF8StringEncoding error:nil];
    if (!pidStr) return 0;
    pid_t pid = (pid_t)[pidStr intValue];
    if (pid <= 1) return 0;
    if (kill(pid, 0) == 0 || errno == EPERM) {
        return pid;
    }
    return 0;
}

BOOL startFilterDaemonIfNeeded(void) {
    pid_t existing = getRunningDaemonPID();
    if (existing > 0) {
        RuntimeDaemonState *st = [RuntimeDaemonState loadState];
        if (kill(existing, 0) == 0 && [st.daemonVersion isEqualToString:kCurrentDaemonVersion]) {
            notify_post(kNotifyReloadConfig);
            return YES;
        }
        stopFilterDaemon();
    }
    NSString *daemonPath = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"pind"];
    chmod([daemonPath fileSystemRepresentation], 0755);
    int res = spawnRoot(daemonPath, @[@"--daemon"]);
    if (res > 0) {
        usleep(250000);
        return (getRunningDaemonPID() > 0);
    }
    appendDaemonLog(@"[LỖI] Không kích được pind (mã: %d). Hãy kiểm tra đã cài qua TrollStore chưa.", res);
    return NO;
}

void stopFilterDaemon(void) {
    notify_post(kNotifyStopDaemon);
    usleep(150000);
    pid_t pid = getRunningDaemonPID();
    if (pid > 0) {
        kill(pid, SIGTERM);
    }
    unlink([kDaemonPidPath fileSystemRepresentation]);
}

#pragma mark - Logging & Haptics

void appendDaemonLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"[%@] %@", [df stringFromDate:[NSDate date]], msg];

    NSString *existing = [NSString stringWithContentsOfFile:kDaemonLogPath encoding:NSUTF8StringEncoding error:nil];
    NSMutableArray<NSString *> *lines = existing ? [[existing componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] mutableCopy] : [NSMutableArray array];
    [lines removeObject:@""];
    [lines addObject:line];

    while (lines.count > 65) {
        [lines removeObjectAtIndex:0];
    }

    NSString *joined = [lines componentsJoinedByString:@"\n"];
    [joined writeToFile:kDaemonLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    chmod([kDaemonLogPath fileSystemRepresentation], 0666);
}

NSString *readDaemonLogs(void) {
    NSString *txt = [NSString stringWithContentsOfFile:kDaemonLogPath encoding:NSUTF8StringEncoding error:nil];
    if (!txt || txt.length == 0) {
        return @"Chưa có nhật ký hoạt động...";
    }
    return txt;
}

void clearDaemonLogs(void) {
    [@"" writeToFile:kDaemonLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    chmod([kDaemonLogPath fileSystemRepresentation], 0666);
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
