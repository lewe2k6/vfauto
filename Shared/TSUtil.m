#import "SharedConfig.h"
#import <AudioToolbox/AudioToolbox.h>
#import <dlfcn.h>
#import <spawn.h>
#import <signal.h>
#import <notify.h>
#import <sys/stat.h>
#import <unistd.h>

#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
typedef int (*persona_np_f)(const posix_spawnattr_t * __restrict, uid_t, uint32_t);
typedef int (*persona_id_f)(const posix_spawnattr_t * __restrict, uid_t);
extern char **environ;

@implementation FilterConfig

- (instancetype)init {
    self = [super init];
    if (self) {
        _masterEnabled      = NO;
        _autoAcceptBike     = YES;
        _rejectAllFood      = NO;
        _minFoodPriceVND    = 25000;
        _hapticEnabled      = YES;
        _dryRunMode         = NO;

        _coordMode          = CoordModeAutoOCRWithOffset;
        _closeXRatio        = 0.912;
        _closeOffsetX       = 0.0;
        _closeOffsetY       = 0.0;
        _acceptOffsetX      = 0.0;
        _acceptOffsetY      = 0.0;

        _manualCloseX       = 342.0;
        _manualCloseY       = 52.0;
        _manualAcceptX      = 187.5;
        _manualAcceptY      = 625.0;

        _scanIntervalMs     = 350;
        _acceptDelayMinMs   = 180;
        _acceptDelayMaxMs   = 420;
        _rejectDelayMinMs   = 400;
        _rejectDelayMaxMs   = 850;
        _jitterRadiusPt     = 6.0;
        _holdMinMs          = 45;
        _holdMaxMs          = 85;
        _cooldownMs         = 2500;

        _statAcceptedCount  = 0;
        _statRejectedCount  = 0;
    }
    return self;
}

+ (instancetype)loadFromDisk {
    FilterConfig *cfg = [[FilterConfig alloc] init];
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:kConfigPlistPath];
    if (!dict) return cfg;

    if (dict[@"masterEnabled"])    cfg.masterEnabled    = [dict[@"masterEnabled"] boolValue];
    if (dict[@"autoAcceptBike"])   cfg.autoAcceptBike   = [dict[@"autoAcceptBike"] boolValue];
    if (dict[@"rejectAllFood"])    cfg.rejectAllFood    = [dict[@"rejectAllFood"] boolValue];
    if (dict[@"minFoodPriceVND"])  cfg.minFoodPriceVND  = [dict[@"minFoodPriceVND"] integerValue];
    if (dict[@"hapticEnabled"])    cfg.hapticEnabled    = [dict[@"hapticEnabled"] boolValue];
    if (dict[@"dryRunMode"])       cfg.dryRunMode       = [dict[@"dryRunMode"] boolValue];

    if (dict[@"coordMode"])        cfg.coordMode        = (CoordMode)[dict[@"coordMode"] integerValue];
    if (dict[@"closeXRatio"])      cfg.closeXRatio      = [dict[@"closeXRatio"] doubleValue];
    if (dict[@"closeOffsetX"])     cfg.closeOffsetX     = [dict[@"closeOffsetX"] doubleValue];
    if (dict[@"closeOffsetY"])     cfg.closeOffsetY     = [dict[@"closeOffsetY"] doubleValue];
    if (dict[@"acceptOffsetX"])    cfg.acceptOffsetX    = [dict[@"acceptOffsetX"] doubleValue];
    if (dict[@"acceptOffsetY"])    cfg.acceptOffsetY    = [dict[@"acceptOffsetY"] doubleValue];

    if (dict[@"manualCloseX"])     cfg.manualCloseX     = [dict[@"manualCloseX"] doubleValue];
    if (dict[@"manualCloseY"])     cfg.manualCloseY     = [dict[@"manualCloseY"] doubleValue];
    if (dict[@"manualAcceptX"])    cfg.manualAcceptX    = [dict[@"manualAcceptX"] doubleValue];
    if (dict[@"manualAcceptY"])    cfg.manualAcceptY    = [dict[@"manualAcceptY"] doubleValue];

    if (dict[@"scanIntervalMs"])   cfg.scanIntervalMs   = [dict[@"scanIntervalMs"] integerValue];
    if (dict[@"acceptDelayMinMs"]) cfg.acceptDelayMinMs = [dict[@"acceptDelayMinMs"] integerValue];
    if (dict[@"acceptDelayMaxMs"]) cfg.acceptDelayMaxMs = [dict[@"acceptDelayMaxMs"] integerValue];
    if (dict[@"rejectDelayMinMs"]) cfg.rejectDelayMinMs = [dict[@"rejectDelayMinMs"] integerValue];
    if (dict[@"rejectDelayMaxMs"]) cfg.rejectDelayMaxMs = [dict[@"rejectDelayMaxMs"] integerValue];
    if (dict[@"jitterRadiusPt"])   cfg.jitterRadiusPt   = [dict[@"jitterRadiusPt"] doubleValue];
    if (dict[@"holdMinMs"])        cfg.holdMinMs        = [dict[@"holdMinMs"] integerValue];
    if (dict[@"holdMaxMs"])        cfg.holdMaxMs        = [dict[@"holdMaxMs"] integerValue];
    if (dict[@"cooldownMs"])       cfg.cooldownMs       = [dict[@"cooldownMs"] integerValue];

    if (dict[@"statAcceptedCount"]) cfg.statAcceptedCount = [dict[@"statAcceptedCount"] integerValue];
    if (dict[@"statRejectedCount"]) cfg.statRejectedCount = [dict[@"statRejectedCount"] integerValue];

    // Clamp min/max sanity
    if (cfg.acceptDelayMaxMs < cfg.acceptDelayMinMs) cfg.acceptDelayMaxMs = cfg.acceptDelayMinMs + 50;
    if (cfg.rejectDelayMaxMs < cfg.rejectDelayMinMs) cfg.rejectDelayMaxMs = cfg.rejectDelayMinMs + 50;
    if (cfg.holdMaxMs < cfg.holdMinMs) cfg.holdMaxMs = cfg.holdMinMs + 15;
    if (cfg.scanIntervalMs < 150) cfg.scanIntervalMs = 150;

    return cfg;
}

- (void)saveToDiskAndNotify:(BOOL)sendNotify {
    NSDictionary *dict = @{
        @"masterEnabled":     @(self.masterEnabled),
        @"autoAcceptBike":    @(self.autoAcceptBike),
        @"rejectAllFood":     @(self.rejectAllFood),
        @"minFoodPriceVND":   @(self.minFoodPriceVND),
        @"hapticEnabled":     @(self.hapticEnabled),
        @"dryRunMode":        @(self.dryRunMode),

        @"coordMode":         @(self.coordMode),
        @"closeXRatio":       @(self.closeXRatio),
        @"closeOffsetX":      @(self.closeOffsetX),
        @"closeOffsetY":      @(self.closeOffsetY),
        @"acceptOffsetX":     @(self.acceptOffsetX),
        @"acceptOffsetY":     @(self.acceptOffsetY),

        @"manualCloseX":      @(self.manualCloseX),
        @"manualCloseY":      @(self.manualCloseY),
        @"manualAcceptX":     @(self.manualAcceptX),
        @"manualAcceptY":     @(self.manualAcceptY),

        @"scanIntervalMs":    @(self.scanIntervalMs),
        @"acceptDelayMinMs":  @(self.acceptDelayMinMs),
        @"acceptDelayMaxMs":  @(self.acceptDelayMaxMs),
        @"rejectDelayMinMs":  @(self.rejectDelayMinMs),
        @"rejectDelayMaxMs":  @(self.rejectDelayMaxMs),
        @"jitterRadiusPt":    @(self.jitterRadiusPt),
        @"holdMinMs":         @(self.holdMinMs),
        @"holdMaxMs":         @(self.holdMaxMs),
        @"cooldownMs":        @(self.cooldownMs),

        @"statAcceptedCount": @(self.statAcceptedCount),
        @"statRejectedCount": @(self.statRejectedCount)
    };

    [dict writeToFile:kConfigPlistPath atomically:YES];
    chmod([kConfigPlistPath fileSystemRepresentation], 0666);

    if (sendNotify) {
        notify_post(kNotifyReloadConfig);
    }
}

- (void)resetDailyStats {
    self.statAcceptedCount = 0;
    self.statRejectedCount = 0;
    [self saveToDiskAndNotify:YES];
}

@end

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
        notify_post(kNotifyReloadConfig);
        return YES;
    }
    NSString *daemonPath = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"pind"];
    chmod([daemonPath fileSystemRepresentation], 0755);
    int res = spawnRoot(daemonPath, @[@"--daemon"]);
    if (res > 0) {
        usleep(180000);
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

    while (lines.count > 60) {
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
        // Double crisp pulse for accepting ride
        AudioServicesPlaySystemSound(1520); // Actuate 'Pop'
        usleep(140000);
        AudioServicesPlaySystemSound(1520);
    } else {
        // Single short tap pulse for rejecting cheap food
        AudioServicesPlaySystemSound(1519); // Actuate 'Peek'
    }
}
