#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <limits.h>
#import <notify.h>
#import <signal.h>
#import <spawn.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <sys/wait.h>
#import <unistd.h>
#import <stdlib.h>
#import <math.h>
#import <string.h>
#import "SharedConfig.h"
#import "ScreenTouchEngine.h"
#import "OrderScanner.h"
#import "HanoiFoodFilterEngine.h"

#ifndef POSIX_SPAWN_CLOEXEC_DEFAULT
#define POSIX_SPAWN_CLOEXEC_DEFAULT 0x4000
#endif

extern char **environ;

typedef struct {
    int32_t priority;
    uint64_t user_data;
} jetsam_priority_props_t;

typedef int (*memorystatus_control_f)(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t buffersize);

#define MEMSTAT_CMD_SET_PRIORITY_PROPS   2
#define MEMSTAT_CMD_SET_HIGH_WATER_MARK  5
#define MEMSTAT_CMD_SET_TASK_LIMIT       6
#define MEMSTAT_CMD_SET_IS_MANAGED       16
#define MEMSTAT_CMD_SET_IS_FREEZABLE     18
#define JETSAM_PRIO_CRITICAL             19
#define JETSAM_PRIO_IMPORTANT            18

#define kExitCodeProactiveRAMTrim        42

static void ignoreBenignDaemonSignals(void) {
    signal(SIGHUP,  SIG_IGN);
    signal(SIGPIPE, SIG_IGN);
    signal(SIGXCPU, SIG_IGN);
    signal(SIGXFSZ, SIG_IGN);
}

static pid_t readRawPidValueFromFile(NSString *path) {
    if (!path) return 0;
    NSData *d = [NSData dataWithContentsOfFile:path options:NSDataReadingUncached error:nil];
    if (!d || d.length == 0) return 0;
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    return s ? (pid_t)[s intValue] : 0;
}

static void unlinkPidFileIfOwnedByMe(NSString *path) {
    pid_t owner = readRawPidValueFromFile(path);
    if (owner == getpid()) {
        unlink([path fileSystemRepresentation]);
    }
}

static void applyCriticalJetsamToPid(pid_t targetPid, int32_t limitMB) {
    memorystatus_control_f fnMemCtl = (memorystatus_control_f)dlsym(RTLD_DEFAULT, "memorystatus_control");
    if (fnMemCtl) {
        jetsam_priority_props_t props = { JETSAM_PRIO_CRITICAL, 0 };
        if (fnMemCtl(MEMSTAT_CMD_SET_PRIORITY_PROPS, targetPid, 0, &props, sizeof(props)) != 0) {
            props.priority = JETSAM_PRIO_IMPORTANT;
            fnMemCtl(MEMSTAT_CMD_SET_PRIORITY_PROPS, targetPid, 0, &props, sizeof(props));
        }
        int32_t safeLimitMB = (limitMB < 1024) ? 1024 : limitMB;
        fnMemCtl(MEMSTAT_CMD_SET_HIGH_WATER_MARK, targetPid, (uint32_t)-1, NULL, 0);
        fnMemCtl(MEMSTAT_CMD_SET_TASK_LIMIT,      targetPid, (uint32_t)safeLimitMB, NULL, 0);
        fnMemCtl(MEMSTAT_CMD_SET_IS_MANAGED,      targetPid, 0, NULL, 0);
        fnMemCtl(MEMSTAT_CMD_SET_IS_FREEZABLE,    targetPid, 0, NULL, 0);
    }
}

static void ensureSharedFilesPermissions(void) {
    upgradeSharedFilesProtectionNone();
    NSArray<NSString *> *paths = @[
        kConfigPlistPath,
        kRuntimeStatePath,
        kDaemonLogPath,
        kDaemonPidPath,
        kWatchdogPidPath
    ];
    for (NSString *p in paths) {
        const char *cPath = [p fileSystemRepresentation];
        if (cPath && access(cPath, F_OK) == 0) {
            if (geteuid() == 0) {
                chown(cPath, 501, 501);
            }
            chmod(cPath, 0666);
        }
    }
}

#pragma mark - Watchdog Supervisor (~0.8 MB RAM, Zero Vision/GPU Footprint)

static volatile BOOL gWatchdogExit = NO;

static void handleWatchdogSignal(int sig) {
    gWatchdogExit = YES;
}

static void killAllOtherPindProcesses(void) {
    pid_t me = getpid();
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0 || len == 0) {
        pid_t oldWd = getRunningWatchdogPID();
        if (oldWd > 1 && oldWd != me) { kill(oldWd, SIGTERM); usleep(80000); kill(oldWd, SIGKILL); }
        pid_t oldWk = getRunningDaemonPID();
        if (oldWk > 1 && oldWk != me) { kill(oldWk, SIGTERM); usleep(80000); kill(oldWk, SIGKILL); }
        return;
    }

    size_t allocLen = len + sizeof(struct kinfo_proc) * 16;
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(allocLen);
    if (!procs) return;

    if (sysctl(mib, 4, procs, &allocLen, NULL, 0) == 0) {
        size_t count = allocLen / sizeof(struct kinfo_proc);
        BOOL killedAny = NO;
        for (size_t i = 0; i < count; i++) {
            pid_t p = procs[i].kp_proc.p_pid;
            if (p > 1 && p != me && strncmp(procs[i].kp_proc.p_comm, "pind", 4) == 0) {
                kill(p, SIGTERM);
                killedAny = YES;
            }
        }
        if (killedAny) {
            usleep(90000);
            for (size_t i = 0; i < count; i++) {
                pid_t p = procs[i].kp_proc.p_pid;
                if (p > 1 && p != me && strncmp(procs[i].kp_proc.p_comm, "pind", 4) == 0) {
                    if (kill(p, 0) == 0) {
                        kill(p, SIGKILL);
                    }
                }
            }
        }
    }
    free(procs);
}

static int runStopMain(void) {
    killAllOtherPindProcesses();
    unlink([kWatchdogPidPath fileSystemRepresentation]);
    unlink([kDaemonPidPath fileSystemRepresentation]);
    return 0;
}

static int runKillPidMain(pid_t targetPid) {
    if (targetPid <= 50 || targetPid == getpid()) return 1;
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, (int)targetPid };
    struct kinfo_proc info;
    size_t len = sizeof(info);
    memset(&info, 0, sizeof(info));
    if (sysctl(mib, 4, &info, &len, NULL, 0) == 0 && len > 0) {
        const char *comm = info.kp_proc.p_comm;
        if (strncmp(comm, "SpringBoard", 11) == 0 ||
            strncmp(comm, "backboardd", 10) == 0 ||
            strncmp(comm, "launchd", 7) == 0) {
            return 1;
        }
    }
    kill(targetPid, SIGTERM);
    usleep(60000);
    kill(targetPid, SIGKILL);
    return 0;
}

static int runDaemonizeMain(const char *execPath) {
    ignoreBenignDaemonSignals();
    setsid();
    for (int fd = 3; fd < 128; fd++) {
        close(fd);
    }

    char resolvedPath[PATH_MAX];
    const char *finalPath = execPath;
    if (execPath && realpath(execPath, resolvedPath) != NULL) {
        finalPath = resolvedPath;
    }

    @autoreleasepool {
        NSString *execStr = [NSString stringWithUTF8String:finalPath];
        int res = spawnRoot(execStr, @[@"--watchdog"]);
        if (res <= 0) {
            posix_spawn_file_actions_t fa;
            posix_spawn_file_actions_init(&fa);
            posix_spawn_file_actions_addopen(&fa, STDIN_FILENO,  "/dev/null", O_RDONLY, 0);
            posix_spawn_file_actions_addopen(&fa, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
            posix_spawn_file_actions_addopen(&fa, STDERR_FILENO, "/dev/null", O_WRONLY, 0);

            posix_spawnattr_t attr;
            posix_spawnattr_init(&attr);
            posix_spawnattr_setpgroup(&attr, 0);
            posix_spawnattr_setflags(&attr, (short)(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT));

            char *cArgv[3] = { (char *)finalPath, "--watchdog", NULL };
            pid_t wdPid = 0;
            if (posix_spawn(&wdPid, finalPath, &fa, &attr, cArgv, environ) != 0) {
                posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
                posix_spawn(&wdPid, finalPath, &fa, &attr, cArgv, environ);
            }
            posix_spawn_file_actions_destroy(&fa);
            posix_spawnattr_destroy(&attr);
        }
    }

    // Exit immediately so launchd (PID 1) adopts Watchdog cleanly outside UI App Switcher coalition!
    _exit(0);
    return 0;
}

static BOOL isMasterConfirmedDisabledTwice(void) {
    if (readMasterEnabledSafely(YES)) {
        return NO;
    }
    usleep(250000);
    return !readMasterEnabledSafely(YES);
}

static int runWatchdogMain(const char *execPath) {
    pid_t me = getpid();
    char resolvedExec[PATH_MAX];
    const char *workerExecPath = execPath;
    if (execPath && realpath(execPath, resolvedExec) != NULL) {
        workerExecPath = resolvedExec;
    }

    @autoreleasepool {
        ignoreBenignDaemonSignals();
        signal(SIGTERM, handleWatchdogSignal);
        signal(SIGINT,  handleWatchdogSignal);
        setsid();

        // Terminate any previous watchdog or worker instance cleanly while uid=0
        killAllOtherPindProcesses();

        // 1024 MB ceiling (never 64 MB!) so linked frameworks can NEVER trigger per-process-limit Jetsam kill
        applyCriticalJetsamToPid(me, 1024);
        ensureSharedFilesPermissions();

        NSString *wdPidStr = [NSString stringWithFormat:@"%d", me];
        NSString *myExecStr = workerExecPath ? [NSString stringWithUTF8String:workerExecPath] : @"";
        writeStringUnprotectedAtomically(wdPidStr, kWatchdogPidPath);

        dispatch_queue_t wdQ = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
        int stopTok = 0;
        notify_register_dispatch(kNotifyStopDaemon, &stopTok, wdQ, ^(int t) {
            gWatchdogExit = YES;
        });

        while (!gWatchdogExit) {
            @autoreleasepool {
                if (isMasterConfirmedDisabledTwice()) {
                    appendDaemonLog(@"[WATCHDOG] Công tắc tổng TẮT -> Dừng Lõi Ngầm an toàn.");
                    break;
                }

                // TROLLSTORE OVER-INSTALL / UNINSTALL SELF-MIGRATION:
                // If user updated/reinstalled .tipa via TrollStore (old UUID folder deleted -> ENOENT, or new UUID folder created),
                // automatically hand over supervision to the newly installed pind binary without requiring app reinstall!
                BOOL myBinaryMissing = (!workerExecPath || access(workerExecPath, X_OK) != 0);
                NSString *livePindPath = resolveLiveAppPindBinaryPath();
                BOOL newBundleInstalled = (livePindPath.length > 0 &&
                                           myExecStr.length > 0 &&
                                           ![livePindPath isEqualToString:myExecStr] &&
                                           access([livePindPath fileSystemRepresentation], X_OK) == 0);
                if (myBinaryMissing || newBundleInstalled) {
                    if (livePindPath.length > 0 && access([livePindPath fileSystemRepresentation], X_OK) == 0) {
                        appendDaemonLog(@"[WATCHDOG] Phát hiện bản cài mới qua TrollStore -> Tự chuyển sang Lõi mới ngay!");
                        unlinkPidFileIfOwnedByMe(kWatchdogPidPath);
                        chmod([livePindPath fileSystemRepresentation], 0755);
                        spawnRoot(livePindPath, @[@"--daemonize"]);
                    } else {
                        unlinkPidFileIfOwnedByMe(kWatchdogPidPath);
                        unlink([kDaemonPidPath fileSystemRepresentation]);
                    }
                    break;
                }

                if (readRawPidValueFromFile(kWatchdogPidPath) != me) {
                    writeStringUnprotectedAtomically(wdPidStr, kWatchdogPidPath);
                }

                posix_spawn_file_actions_t fa;
                posix_spawn_file_actions_init(&fa);
                posix_spawn_file_actions_addopen(&fa, STDIN_FILENO,  "/dev/null", O_RDONLY, 0);
                posix_spawn_file_actions_addopen(&fa, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
                posix_spawn_file_actions_addopen(&fa, STDERR_FILENO, "/dev/null", O_WRONLY, 0);

                posix_spawnattr_t attr;
                posix_spawnattr_init(&attr);
                posix_spawnattr_setflags(&attr, (short)POSIX_SPAWN_CLOEXEC_DEFAULT);

                char *childArgv[3];
                childArgv[0] = (char *)workerExecPath;
                childArgv[1] = "--worker";
                childArgv[2] = NULL;

                pid_t workerPid = 0;
                int spRet = posix_spawn(&workerPid, workerExecPath, &fa, &attr, childArgv, environ);
                if (spRet != 0) {
                    spRet = posix_spawn(&workerPid, workerExecPath, &fa, NULL, childArgv, environ);
                }
                posix_spawn_file_actions_destroy(&fa);
                posix_spawnattr_destroy(&attr);

                if (spRet != 0 || workerPid <= 0) {
                    usleep(500000);
                    continue;
                }

                applyCriticalJetsamToPid(workerPid, 1024);

                int status = 0;
                int tickCount = 0;
                BOOL workerAlive = YES;
                BOOL migrateToNewBundle = NO;
                NSString *migrateTarget = nil;
                double lastLoopWallEpoch = [[NSDate date] timeIntervalSince1970];
                double wakeGraceUntilEpoch = lastLoopWallEpoch + 14.0;

                while (workerAlive && !gWatchdogExit) {
                    pid_t w = waitpid(workerPid, &status, WNOHANG);
                    if (w == workerPid || (w == -1)) {
                        workerAlive = NO;
                        break;
                    }

                    double nowWall = [[NSDate date] timeIntervalSince1970];
                    if (nowWall - lastLoopWallEpoch > 3.0) {
                        // Device just woke up from iOS deep sleep -> grant Worker 14s grace to refresh heartbeat
                        wakeGraceUntilEpoch = nowWall + 14.0;
                    }
                    lastLoopWallEpoch = nowWall;

                    tickCount++;
                    if (tickCount % 20 == 0) { // Every ~5s self-heal PID file, check TrollStore update, master switch & heartbeat
                        @autoreleasepool {
                            if (readRawPidValueFromFile(kWatchdogPidPath) != me) {
                                writeStringUnprotectedAtomically(wdPidStr, kWatchdogPidPath);
                            }
                            if (isMasterConfirmedDisabledTwice()) {
                                appendDaemonLog(@"[WATCHDOG] Công tắc tổng TẮT -> Dừng Lõi Ngầm an toàn.");
                                gWatchdogExit = YES;
                                break;
                            }
                            BOOL curBinGone = (!workerExecPath || access(workerExecPath, X_OK) != 0);
                            NSString *curLive = resolveLiveAppPindBinaryPath();
                            if (curBinGone || (curLive.length > 0 && myExecStr.length > 0 && ![curLive isEqualToString:myExecStr])) {
                                migrateToNewBundle = YES;
                                migrateTarget = curLive;
                                gWatchdogExit = YES;
                                break;
                            }
                            if (nowWall > wakeGraceUntilEpoch) {
                                RuntimeDaemonState *st = [RuntimeDaemonState loadState];
                                if (st.workerHeartbeatEpoch > 0.0 && (nowWall - st.workerHeartbeatEpoch) > 20.0) {
                                    appendDaemonLog(@"[WATCHDOG] Worker phản hồi chậm >20s -> Tự làm mới tiến trình tức thì!");
                                    kill(workerPid, SIGKILL);
                                }
                            }
                        }
                    }

                    usleep(250000);
                }

                if (gWatchdogExit) {
                    if (workerAlive && workerPid > 1) {
                        kill(workerPid, SIGTERM);
                        for (int k = 0; k < 8; k++) {
                            usleep(50000);
                            if (waitpid(workerPid, &status, WNOHANG) == workerPid) {
                                workerAlive = NO;
                                break;
                            }
                        }
                        if (workerAlive) {
                            kill(workerPid, SIGKILL);
                            waitpid(workerPid, &status, 0);
                        }
                    }
                    if (migrateToNewBundle && migrateTarget.length > 0 && access([migrateTarget fileSystemRepresentation], X_OK) == 0) {
                        appendDaemonLog(@"[WATCHDOG] Tự chuyển sang bản cài mới qua TrollStore ngay lập tức!");
                        unlinkPidFileIfOwnedByMe(kWatchdogPidPath);
                        chmod([migrateTarget fileSystemRepresentation], 0755);
                        spawnRoot(migrateTarget, @[@"--daemonize"]);
                    }
                    break;
                }

                // Worker exited while masterEnabled is still ON -> Auto-revive!
                BOOL wasCleanRAMTrim = (WIFEXITED(status) && WEXITSTATUS(status) == kExitCodeProactiveRAMTrim);
                if (wasCleanRAMTrim) {
                    usleep(80000);
                } else {
                    if (isMasterConfirmedDisabledTwice()) {
                        appendDaemonLog(@"[WATCHDOG] Công tắc tổng TẮT -> Dừng Lõi Ngầm an toàn.");
                        break;
                    }
                    int termSig  = WIFSIGNALED(status) ? WTERMSIG(status) : 0;
                    int exitCode = WIFEXITED(status)   ? WEXITSTATUS(status) : 0;
                    appendDaemonLog(@"[WATCHDOG] Worker đóng (sig:%d code:%d) -> Đã tự hồi sinh tức thì trong 0.12s!",
                                    termSig, exitCode);
                    notify_post(kNotifyStatsUpdated);
                    usleep(120000);
                }
            }
        }

        notify_cancel(stopTok);
        unlinkPidFileIfOwnedByMe(kWatchdogPidPath);
    }
    return 0;
}

#pragma mark - Worker Process (Mobile 501 Session: Screen Capture, Vision OCR & HID Touch)

static volatile BOOL gShouldExit         = NO;
static volatile BOOL gNeedsReload        = YES;
static volatile BOOL gSkipPauseRequested = NO;
static volatile BOOL gResetNavRequested  = NO;
static volatile BOOL gResetCntRequested  = NO;
static volatile BOOL gDiagRequested      = NO;

static void handleWorkerSignal(int sig) {
    gShouldExit = YES;
}

static void prepareWorkerSession(void) {
    pid_t me = getpid();
    applyCriticalJetsamToPid(me, 1024);
    ensureSharedFilesPermissions();

    if (getgid() != 501) {
        setgid(501);
    }
    if (getuid() != 501) {
        setuid(501);
    }
}

static BOOL isFrontmostAppAllowedForScan(NSString *frontBid, FilterConfig *config) {
    // Fail-open when frontBid is temporarily nil during app switcher transitions
    if (!frontBid || frontBid.length == 0) {
        return YES;
    }
    return bundleIDMatchesDriverApp(frontBid, config);
}

static void resetBothNavLocks(RuntimeDaemonState *state, NSString *reasonLog) {
    if (state.navPickupLocked || state.navDropoffLocked) {
        state.navPickupLocked  = NO;
        state.navDropoffLocked = NO;
        state.phaseDescription = @"Đang rảnh / Đã mở khóa chốt Map";
        state.workerHeartbeatEpoch = [[NSDate date] timeIntervalSince1970];
        [state saveStateAndNotify:YES];
        if (reasonLog.length > 0) {
            appendDaemonLog(@"%@", reasonLog);
        }
    }
}

static BOOL extractFingerprintParts(NSString *fp, NSString **outType, NSInteger *outPrice, NSString **outPickupPrefix) {
    if (!fp || fp.length == 0) return NO;
    NSArray<NSString *> *parts = [fp componentsSeparatedByString:@"|"];
    if (parts.count < 3) return NO;
    if (outType) *outType = parts[0];
    if (outPrice) *outPrice = [parts[1] integerValue];
    if (outPickupPrefix) *outPickupPrefix = parts[2];
    return YES;
}

static BOOL isSameSpinningOrderOnWeak4G(ScreenAnalysis *ana,
                                        NSString *lastFingerprint,
                                        double lastHandledEpoch,
                                        BOOL lastWasAccept,
                                        double nowEpoch) {
    if (!ana || !ana.hasOrderPopup || !lastFingerprint || lastFingerprint.length == 0) return NO;
    // CRITICAL: For [Nhận chuyến], cap weak-4G spin window to 0.85s so if a tap ever dropped or GSM didn't ACK,
    // pind taps [Nhận chuyến] AGAIN within <1s before the 7s countdown expires! Keep full 4.2s ONLY for [X] Reject Food!
    double maxSpinWindowSec = lastWasAccept ? 0.85 : 4.2;
    if (lastHandledEpoch <= 0.0 || (nowEpoch - lastHandledEpoch) > maxSpinWindowSec) return NO;

    NSString *lastType = nil, *lastPickup = nil;
    NSInteger lastPrice = 0;
    if (!extractFingerprintParts(lastFingerprint, &lastType, &lastPrice, &lastPickup)) return NO;

    NSString *curType = ana.isGreenFood ? @"FOOD" : @"RIDE";
    if (![curType isEqualToString:lastType]) {
        return NO; // Switched between Food and Bike/Express -> 100% brand-new order!
    }

    if (ana.detectedPriceVND > 0 && lastPrice > 0 && ana.detectedPriceVND != lastPrice) {
        return NO; // Different fare -> 100% brand-new order!
    }

    NSString *curFp = ana.orderFingerprint ?: @"";
    if ([curFp isEqualToString:lastFingerprint]) {
        return YES;
    }

    NSString *curTypeDummy = nil, *curPickup = nil;
    NSInteger curPriceDummy = 0;
    extractFingerprintParts(curFp, &curTypeDummy, &curPriceDummy, &curPickup);

    // If loading spinner temporarily covered pickup text while fare & service stayed identical -> still same spinning card!
    if ((!curPickup || curPickup.length == 0) && ana.detectedPriceVND > 0 && ana.detectedPriceVND == lastPrice) {
        return YES;
    }

    if (curPickup.length >= 8 && lastPickup.length >= 8) {
        NSUInteger cmpLen = MIN((NSUInteger)26, MIN(curPickup.length, lastPickup.length));
        NSUInteger sameChars = 0;
        for (NSUInteger i = 0; i < cmpLen; i++) {
            if ([curPickup characterAtIndex:i] == [lastPickup characterAtIndex:i]) {
                sameChars++;
            }
        }
        if (sameChars * 5 >= cmpLen * 4) { // >= 80% match across up to 26 chars (prevents "Số 12 Đường Láng" vs "Số 12 Đường Giải Phóng" collision while tolerating OCR wobble!)
            return YES;
        }
    }

    return NO;
}

static void runDiagnosticCapture4Sec(FilterConfig *config,
                                     ScreenTouchEngine *engine,
                                     OrderScanner *scanner,
                                     RuntimeDaemonState *state) {
    appendDaemonLog(@"[TEST 4s] Đếm ngược 4 giây -> Hãy mở sang Ảnh hoặc App Tài xế ngay!");
    notify_post(kNotifyStatsUpdated);

    for (int i = 0; i < 8 && !gShouldExit; i++) {
        usleep(500000);
    }
    if (gShouldExit) return;

    state.workerHeartbeatEpoch = [[NSDate date] timeIntervalSince1970];
    [state saveStateAndNotify:NO];

    CIImage *img = [engine captureScreenCIImage];
    if (!img || !engine.lastCaptureHadPixels) {
        triggerHapticFeedback(NO);
        appendDaemonLog(@"[TEST LỖI] Khung hình trả về ĐEN/RỖNG! Hãy cài lại qua TrollStore.");
        notify_post(kNotifyStatsUpdated);
        return;
    }

    [engine markCurrentFrameAnalyzed];
    ScreenAnalysis *ana = [scanner analyzeScreenImage:img
                                           screenSize:engine.logicalScreenSize
                                           yellowDotY:engine.lastOrderYellowDotY
                                     hasBottomTealBar:engine.lastFrameHasBottomTealButton
                                    hasTopWhiteHeader:engine.lastFrameHasOrderHeaderAtTop
                                   headerIconWarmFood:engine.lastFrameHeaderIconWarmFood
                                   headerIconCoolRide:engine.lastFrameHeaderIconCoolRide
                                               config:config
                                      priceRetryCount:6];

    NSString *matched = @"Màn hình bình thường (không phải bảng đơn/chuyến)";
    if (ana.hasOrderPopup) {
        matched = [NSString stringWithFormat:@"BẢNG NỔ ĐƠN -> %@ tại (%.0f, %.0f)",
                   ana.orderReason ?: @"", ana.orderTargetPoint.x, ana.orderTargetPoint.y];
    } else if (ana.hasPassengerAndNav && ana.isPickupStage) {
        matched = [NSString stringWithFormat:@"PHA 1 ĐÓN KHÁCH -> Tap nút xanh Điều hướng (%.0f, %.0f)",
                   ana.navBluePoint.x, ana.navBluePoint.y];
    } else if (ana.hasPassengerAndNav && ana.isDropoffStage) {
        matched = [NSString stringWithFormat:@"PHA 2 TRẢ KHÁCH -> Tap nút xanh Điều hướng (%.0f, %.0f)",
                   ana.navBluePoint.x, ana.navBluePoint.y];
    } else if (ana.isPaymentConfirmScreen) {
        matched = @"MÀN THANH TOÁN ('Xác nhận hoàn thành') -> Xóa sạch 2 chốt Map!";
    } else if (ana.hasBlockingBottomSheet) {
        matched = @"BẢNG PHỤ CHE SẢNH ('0.0/8 lái xe liên tục') -> Tự vuốt/chạm đóng ngay!";
    } else if (ana.isLobbyOnline) {
        matched = @"SẢNH ĐANG TRỰC TUYẾN -> Nút tắt [Power] tại (40, 455)";
    } else if (ana.isLobbyOffline) {
        matched = [NSString stringWithFormat:@"SẢNH OFFLINE -> Nút [Mở nhận chuyến] tại (%.0f, %.0f)",
                   ana.onlineStartPoint.x, ana.onlineStartPoint.y];
    }

    NSString *detFront = currentFrontmostAppBundleIDForConfig(config) ?: @"auto";
    triggerHapticFeedback(YES);
    appendDaemonLog(@"[TEST OK] App:%@ | Đọc %ld cụm (Tiêu đề: '%@', Chấm vàng Y:%.0f): [%@]",
                    detFront,
                    (long)ana.ocrBlockCount,
                    ana.detectedServiceTitle ?: @"",
                    engine.lastOrderYellowDotY,
                    ana.ocrSampleSummary ?: @"");
    if (ana.hasOrderPopup && (ana.pickupTitle.length > 0 || ana.dropoffTitle.length > 0)) {
        appendDaemonLog(@"[ĐỊA CHỈ] Nhận: '%@' | Giao: '%@'",
                        ana.pickupTitle.length > 0 ? ana.pickupTitle : ana.pickupSubtitle,
                        ana.dropoffSubtitle.length > 0 ? ana.dropoffSubtitle : ana.dropoffTitle);
    }
    appendDaemonLog(@"[KẾT QUẢ NHẬN DIỆN] %@", matched);
    notify_post(kNotifyStatsUpdated);
}

static void dismissBlockingLobbySheet(ScreenTouchEngine *engine, FilterConfig *config) {
    CGFloat midX   = engine.logicalScreenSize.width * 0.5;
    CGFloat startY = engine.logicalScreenSize.height * 0.742; // ~495pt on iPhone 8 (handle bar of 0.0/8 sheet)
    CGFloat endY   = engine.logicalScreenSize.height * 0.985; // ~657pt on iPhone 8
    [engine performQuickSwipeFromPoint:CGPointMake(midX, startY)
                               toPoint:CGPointMake(midX, endY)
                            durationMs:95];
    usleep(220000);
    // Also tap the dimmed grey modal scrim at (187, 205) where zero Lobby buttons exist
    CGPoint scrimPt = CGPointMake(midX, engine.logicalScreenSize.height * 0.307);
    CGPoint outPt   = CGPointZero;
    [engine performHumanTapAtPoint:scrimPt
                      jitterRadius:MIN(3.0, config.jitterRadiusPt)
                         holdMinMs:40
                         holdMaxMs:65
                    outActualPoint:&outPt];
    usleep(420000);
    [engine invalidateAnalyzedBaseline];
}

static BOOL runOfflinePauseAndRestartCycle(FilterConfig **ioConfig,
                                           RuntimeDaemonState *state,
                                           ScreenTouchEngine *engine,
                                           OrderScanner *scanner,
                                           BOOL resumingExistingPause,
                                           BOOL *ioInActiveTrip,
                                           NSString *lastHandledOrderFp,
                                           double lastHandledOrderEpoch) {
    FilterConfig *config = *ioConfig;
    gSkipPauseRequested = NO;

    BOOL didKillApp     = NO;
    BOOL didRelaunchApp = NO;
    BOOL loggedWeak4GSpin = NO;

    if (!resumingExistingPause) {
        state.phaseDescription = @"Đang bấm [Power] Tắt nhận chuyến...";
        state.workerHeartbeatEpoch = [[NSDate date] timeIntervalSince1970];
        [state saveStateAndNotify:YES];

        // Short 480ms settle after [X] closes so [Power] is tapped fast while catching any back-to-back order
        usleep(480000);

        BOOL confirmedOffline = NO;
        for (int attempt = 0; attempt < 18 && !gShouldExit && !gSkipPauseRequested; attempt++) {
            @autoreleasepool {
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.002, false);
                double iterNow = [[NSDate date] timeIntervalSince1970];
                state.workerHeartbeatEpoch = iterNow;
                [state saveStateAndNotify:NO];

                CIImage *img = [engine captureScreenCIImage];
                ScreenAnalysis *ana = [scanner analyzeScreenImage:img
                                                       screenSize:engine.logicalScreenSize
                                                       yellowDotY:engine.lastOrderYellowDotY
                                                 hasBottomTealBar:engine.lastFrameHasBottomTealButton
                                                hasTopWhiteHeader:engine.lastFrameHasOrderHeaderAtTop
                                               headerIconWarmFood:engine.lastFrameHeaderIconWarmFood
                                               headerIconCoolRide:engine.lastFrameHeaderIconCoolRide
                                                           config:config
                                                  priceRetryCount:0];

                // SAFETY GUARD 1: Active trip (Bike / Express / Food chained-ride) -> NEVER tap [Power] or Kill App!
                if (ana.isAnyActiveTripScreen || ana.isPaymentConfirmScreen) {
                    if (ioInActiveTrip) {
                        *ioInActiveTrip = ana.isAnyActiveTripScreen;
                    }
                    appendDaemonLog(@"Đang chạy cuốc xe dở (nối chuyến) -> Chỉ từ chối Food, giữ nguyên App!");
                    state.phaseDescription = @"Đang trong chuyến xe / Canh nối chuyến";
                    state.workerHeartbeatEpoch = [[NSDate date] timeIntervalSince1970];
                    [state saveStateAndNotify:YES];
                    return NO;
                }

                // Already confirmed Offline ('Mở nhận chuyến' visible)
                if (ana.isLobbyOffline) {
                    if (ioInActiveTrip) *ioInActiveTrip = NO;
                    confirmedOffline = YES;
                    break;
                }

                // WEAK-4G SPINNING CARD GUARD + BACK-TO-BACK ORDER INTERRUPT:
                // - If the SAME Food popup is still spinning on weak 4G waiting for server reject ACK -> wait quietly!
                // - If a DIFFERENT order (Bike/Express OR 2nd Food shop) popped up -> abort Offline immediately to handle it!
                if (ana.hasOrderPopup && ana.orderAction != OrderActionSkipDisabled) {
                    if (isSameSpinningOrderOnWeak4G(ana, lastHandledOrderFp, lastHandledOrderEpoch, NO, iterNow)) {
                        if (!loggedWeak4GSpin) {
                            loggedWeak4GSpin = YES;
                            appendDaemonLog(@"[CHỐNG LAG 4G] Đơn cũ đang xoay chờ mạng đóng -> Chờ êm, không bấm bồi [X]!");
                        }
                        usleep(450000);
                        continue;
                    }
                    appendDaemonLog(@"Nổ liền đơn mới (%@) khi chưa kịp Tắt app -> Quay lại xử lý đơn ngay!",
                                    ana.detectedServiceTitle.length > 0 ? ana.detectedServiceTitle : @"Mới");
                    [engine invalidateAnalyzedBaseline];
                    return YES;
                }

                // Clear lingering reject-reason confirmation dialog
                if (ana.hasRejectConfirmPopup && !config.dryRunMode) {
                    CGPoint rPt = CGPointZero;
                    [engine performHumanTapAtPoint:ana.rejectConfirmPoint
                                      jitterRadius:config.jitterRadiusPt
                                         holdMinMs:config.holdMinMs
                                         holdMaxMs:config.holdMaxMs
                                    outActualPoint:&rPt];
                    appendDaemonLog(@"Đã bấm đóng hộp thoại từ chối Food tại (%.0f, %.0f)", rPt.x, rPt.y);
                    usleep(950000);
                    continue;
                }

                // Confirm Offline modal ('Xác nhận' / 'Đồng ý' / 'Tắt nhận chuyến')
                if (ana.hasOfflineConfirmPopup) {
                    if (config.dryRunMode) {
                        appendDaemonLog(@"[THỬ] Sẽ bấm xác nhận tắt trực tuyến tại (%.0f, %.0f)",
                                        ana.confirmPopupPoint.x, ana.confirmPopupPoint.y);
                        confirmedOffline = YES;
                        break;
                    } else {
                        CGPoint pt = CGPointZero;
                        [engine performHumanTapAtPoint:ana.confirmPopupPoint
                                          jitterRadius:config.jitterRadiusPt
                                             holdMinMs:config.holdMinMs
                                             holdMaxMs:config.holdMaxMs
                                        outActualPoint:&pt];
                        appendDaemonLog(@"Đã bấm nút xác nhận ngừng nhận chuyến (%.0f, %.0f)", pt.x, pt.y);
                        usleep(1350000);
                        continue;
                    }
                }

                // Dismiss accidental '0.0/8 — Bạn đã lái xe liên tục' or warning bottom sheet immediately so 'Đang trực tuyến' & [Power] uncover!
                if (ana.hasBlockingBottomSheet) {
                    if (config.dryRunMode) {
                        appendDaemonLog(@"[THỬ] Sẽ đóng bảng phụ '0.0/8 lái xe liên tục' đang che nút Tắt trực tuyến");
                    } else {
                        appendDaemonLog(@"Phát hiện bảng phụ '0.0/8' che sảnh -> Tự hất đóng ngay để bấm Tắt trực tuyến!");
                        dismissBlockingLobbySheet(engine, config);
                        continue;
                    }
                }

                // Tap circular [Power] button when Lobby Online ('Đang trực tuyến') OR uncovered bright-teal [Power] ring at (40, 455) is confirmed
                BOOL canTapOfflinePower = ana.isLobbyOnline ||
                                          (attempt >= 2 &&
                                           engine.lastFrameLikelyHasLobbyPowerButton &&
                                           !ana.hasOrderPopup &&
                                           !ana.isAnyActiveTripScreen &&
                                           !ana.isPaymentConfirmScreen &&
                                           !ana.isLobbyOffline &&
                                           !ana.hasBlockingBottomSheet);

                if (canTapOfflinePower) {
                    if (ioInActiveTrip) *ioInActiveTrip = NO;
                    if (config.dryRunMode) {
                        appendDaemonLog(@"[THỬ] Sẽ bấm nút [Power] Tắt nhận chuyến tại (%.0f, %.0f)",
                                        ana.offlinePowerPoint.x, ana.offlinePowerPoint.y);
                        confirmedOffline = YES;
                        break;
                    } else {
                        CGPoint pt = CGPointZero;
                        [engine performHumanTapAtPoint:ana.offlinePowerPoint
                                          jitterRadius:config.jitterRadiusPt
                                             holdMinMs:config.holdMinMs
                                             holdMaxMs:config.holdMaxMs
                                        outActualPoint:&pt];
                        appendDaemonLog(@"Bấm nút tròn [Power] Tắt nhận chuyến tại (%.0f, %.0f)", pt.x, pt.y);
                        usleep(1500000);
                        continue;
                    }
                }

                usleep(500000);
            }
        }

        if (gShouldExit) return NO;

        // CRITICAL SAFETY: NEVER enter a blind 2-minute sleep if Xanh SM has NOT actually gone Offline!
        // Otherwise Xanh SM stays 'Đang trực tuyến' on screen while pind sleeps for 120s and misses real Bike/Express orders!
        if (!confirmedOffline && !config.dryRunMode) {
            state.pauseEndEpoch        = 0.0;
            state.workerHeartbeatEpoch = [[NSDate date] timeIntervalSince1970];
            state.phaseDescription     = @"Đang trực tuyến / Canh đơn";
            [state saveStateAndNotify:YES];
            appendDaemonLog(@"[AN TOÀN] App chưa tắt trực tuyến -> Bỏ qua nghỉ, quay lại canh đơn ngay để không lỡ cuốc!");
            [engine invalidateAnalyzedBaseline];
            return NO;
        }

        NSInteger pauseSec = MAX(20, config.pauseDurationSec);
        double nowEpoch = [[NSDate date] timeIntervalSince1970];
        state.pauseEndEpoch        = nowEpoch + (double)pauseSec;
        state.workerHeartbeatEpoch = nowEpoch;
        state.phaseDescription     = [NSString stringWithFormat:@"Đang nghỉ xả Food (%lds)...", (long)pauseSec];
        [state saveStateAndNotify:YES];

        appendDaemonLog(@"Đã Offline thành công! Bắt đầu nghỉ %ld giây trước khi bật lại nhận chuyến.",
                        (long)pauseSec);

        // SAFETY GUARD 2: Only kill Xanh SM AFTER Offline is confirmed on screen so GSM server never ghost-dispatches orders!
        if (config.autoKillAndRelaunchApp && !config.dryRunMode) {
            if (confirmedOffline) {
                // Allow 1.2s for Xanh SM's Offline network packet to flush cleanly before terminating process
                usleep(1200000);
                BOOL killed = killAppByBundleIDAndExec(config.driverAppBundleID, config.driverAppExecName);
                didKillApp = killed;
                appendDaemonLog(@"%@ tiến trình Xanh SM để xả sạch RAM & làm mới phiên.",
                                killed ? @"Đã tự động Kill sạch" : @"[CHÚ Ý] Lệnh Kill chưa dứt điểm");
            }
        }
    } else {
        didKillApp = config.autoKillAndRelaunchApp;
        appendDaemonLog(@"[WATCHDOG] Tiếp tục đếm ngược chu kỳ nghỉ xả Food đang chạy dở...");
    }

    double pauseLoopStartEpoch = [[NSDate date] timeIntervalSince1970];
    int pauseTick = 0;
    double lastHbSave = 0.0;
    while (!gShouldExit && !gSkipPauseRequested) {
        @autoreleasepool {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.002, false);
            if (gNeedsReload) {
                FilterConfig *reloaded = [FilterConfig loadFromDisk];
                if (!reloaded.masterEnabled && readMasterEnabledSafely(YES)) {
                    reloaded.masterEnabled = YES;
                }
                *ioConfig = reloaded;
                config = *ioConfig;
                gNeedsReload = NO;
                resetFrontmostAppMonitors();
            }
            if (!config.masterEnabled || !config.pauseAfterRejectFood) {
                break;
            }
            if (gResetNavRequested) {
                gResetNavRequested = NO;
                state.navPickupLocked  = NO;
                state.navDropoffLocked = NO;
                state.workerHeartbeatEpoch = [[NSDate date] timeIntervalSince1970];
                [state saveStateAndNotify:YES];
                appendDaemonLog(@"Đã Reset thủ công cả 2 chốt khóa Điều hướng về FALSE.");
            }
            if (gResetCntRequested) {
                gResetCntRequested = NO;
                state.statAcceptedCount = 0;
                state.statRejectedCount = 0;
                state.workerHeartbeatEpoch = [[NSDate date] timeIntervalSince1970];
                [state saveStateAndNotify:YES];
            }

            double cur = [[NSDate date] timeIntervalSince1970];
            if (cur - lastHbSave >= 3.0) {
                state.workerHeartbeatEpoch = cur;
                [state saveStateAndNotify:NO];
                lastHbSave = cur;
            }

            double rem = state.pauseEndEpoch - cur;
            if (rem <= 0.0) break;

            // LIVE PIXEL WAKEUP DURING PAUSE (0% Vision OCR, 0.02ms):
            // If driver manually pressed 'Mở nhận chuyến' to go back Online early, OR an order popped up -> cancel pause immediately!
            pauseTick++;
            if ((pauseTick % 2 == 0) && !config.dryRunMode && !isDeviceScreenLocked()) {
                NSString *fgDuringPause = currentFrontmostAppBundleIDForConfig(config);
                if (isFrontmostAppAllowedForScan(fgDuringPause, config)) {
                    CIImage *pauseProbe = [engine captureScreenCIImage];
                    if (pauseProbe && engine.lastFrameLikelyHasOrderPopup) {
                        state.pauseEndEpoch        = 0.0;
                        state.workerHeartbeatEpoch = cur;
                        state.phaseDescription     = @"Đang trực tuyến / Canh đơn (Turbo)";
                        [state saveStateAndNotify:YES];
                        appendDaemonLog(@"Phát hiện có đơn nổ giữa lúc nghỉ -> Hủy đếm ngược vào bắt đơn ngay!");
                        [engine invalidateAnalyzedBaseline];
                        return YES;
                    }
                    if (pauseProbe && !didRelaunchApp && (cur - pauseLoopStartEpoch) >= 4.0 && engine.lastFrameLikelyHasLobbyPowerButton) {
                        state.pauseEndEpoch        = 0.0;
                        state.workerHeartbeatEpoch = cur;
                        state.phaseDescription     = @"Đang trực tuyến / Canh đơn";
                        [state saveStateAndNotify:YES];
                        appendDaemonLog(@"Phát hiện bạn vừa bật lại Trực tuyến sớm -> Tự kết thúc nghỉ, canh đơn ngay!");
                        [engine invalidateAnalyzedBaseline];
                        return NO;
                    }
                }
            }

            // Pre-relaunch Xanh SM ahead of timer ONLY when screen is unlocked (if locked in pocket, wait until unlock!)
            if (config.autoKillAndRelaunchApp && didKillApp && !didRelaunchApp && !config.dryRunMode) {
                if (rem <= (double)MAX(10, config.relaunchLeadSec) && !isDeviceScreenLocked()) {
                    if (config.hapticEnabled) triggerHapticFeedback(NO);
                    BOOL launched = launchAppByBundleID(config.driverAppBundleID);
                    didRelaunchApp = launched;
                    state.phaseDescription = @"Đang mở lại App Tài xế chờ khóa GPS...";
                    state.workerHeartbeatEpoch = cur;
                    [state saveStateAndNotify:YES];
                    appendDaemonLog(@"Còn %.0fs -> %@ App Tài xế chờ load bản đồ & GPS!",
                                    rem, launched ? @"Đã tự mở lại" : @"Đang gọi mở lại");
                }
            }

            usleep(500000);
        }
    }

    state.pauseEndEpoch = 0.0;
    state.workerHeartbeatEpoch = [[NSDate date] timeIntervalSince1970];
    if (gShouldExit) {
        [state saveStateAndNotify:YES];
        return NO;
    }

    if (gSkipPauseRequested) {
        appendDaemonLog(@"Nhận lệnh bỏ qua đếm ngược -> Bật lại nhận chuyến ngay!");
        gSkipPauseRequested = NO;
    }

    // If phone screen is currently locked when pause ends, wait cleanly until unlocked so iOS allows foreground launch & UI tap
    if (isDeviceScreenLocked() && !config.dryRunMode) {
        state.phaseDescription = @"Hết giờ nghỉ — Chờ mở khóa màn hình để bật lại App...";
        state.workerHeartbeatEpoch = [[NSDate date] timeIntervalSince1970];
        [state saveStateAndNotify:YES];
        appendDaemonLog(@"Hết giờ nghỉ nhưng máy đang khóa -> Sẽ tự mở lại Xanh SM ngay khi mở khóa màn hình!");

        while (!gShouldExit && isDeviceScreenLocked()) {
            double cur = [[NSDate date] timeIntervalSince1970];
            if (cur - lastHbSave >= 3.0) {
                state.workerHeartbeatEpoch = cur;
                [state saveStateAndNotify:NO];
                lastHbSave = cur;
            }
            usleep(450000);
        }
        if (gShouldExit) return NO;
        usleep(400000);
    }

    if (config.autoKillAndRelaunchApp && !didRelaunchApp && !config.dryRunMode) {
        launchAppByBundleID(config.driverAppBundleID);
        didRelaunchApp = YES;
        usleep(2500000);
    }

    state.phaseDescription = @"Đang bấm [Mở nhận chuyến]...";
    state.workerHeartbeatEpoch = [[NSDate date] timeIntervalSince1970];
    [state saveStateAndNotify:YES];

    BOOL backOnline = NO;
    int onlineTapsSent = 0;

    // Closed-loop re-online check (up to ~36s so iPhone 8 cold-launch + GSM Maps + GPS lock completes smoothly)
    for (int waitIdx = 0; waitIdx < 36 && !gShouldExit; waitIdx++) {
        @autoreleasepool {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.002, false);
            state.workerHeartbeatEpoch = [[NSDate date] timeIntervalSince1970];
            [state saveStateAndNotify:NO];

            // Auto re-bring Xanh SM to foreground if cold-launch stalled or stayed on SpringBoard
            if (config.autoKillAndRelaunchApp && !config.dryRunMode && (waitIdx % 6 == 2)) {
                NSString *fgBid = currentFrontmostAppBundleIDForConfig(config);
                if (fgBid.length > 0 && !isFrontmostAppAllowedForScan(fgBid, config)) {
                    launchAppByBundleID(config.driverAppBundleID);
                    usleep(1800000);
                }
            }

            CIImage *img = [engine captureScreenCIImage];
            ScreenAnalysis *ana = [scanner analyzeScreenImage:img
                                                   screenSize:engine.logicalScreenSize
                                                   yellowDotY:engine.lastOrderYellowDotY
                                             hasBottomTealBar:engine.lastFrameHasBottomTealButton
                                            hasTopWhiteHeader:engine.lastFrameHasOrderHeaderAtTop
                                           headerIconWarmFood:engine.lastFrameHeaderIconWarmFood
                                           headerIconCoolRide:engine.lastFrameHeaderIconCoolRide
                                                       config:config
                                              priceRetryCount:0];

            if (!ana.isLobbyOffline && ana.hasOrderPopup) {
                resetFrontmostAppMonitors();
                [engine invalidateAnalyzedBaseline];
                if (ioInActiveTrip) *ioInActiveTrip = NO;
                state.phaseDescription = @"Đang trực tuyến / Canh đơn (Turbo)";
                state.workerHeartbeatEpoch = [[NSDate date] timeIntervalSince1970];
                [state saveStateAndNotify:YES];
                return YES;
            }

            if (ana.isLobbyOnline || ana.hasPassengerAndNav) {
                backOnline = YES;
                break;
            }

            if (ana.hasBlockingBottomSheet && !config.dryRunMode) {
                dismissBlockingLobbySheet(engine, config);
                continue;
            }

            if (ana.isLobbyOffline && onlineTapsSent < 4) {
                uint32_t dMs = 260 + arc4random_uniform(280);
                usleep(dMs * 1000);

                if (config.dryRunMode) {
                    appendDaemonLog(@"[THỬ] Hết nghỉ -> Sẽ bấm [Mở nhận chuyến] tại (%.0f, %.0f)",
                                    ana.onlineStartPoint.x, ana.onlineStartPoint.y);
                    backOnline = YES;
                    break;
                } else {
                    CGPoint pt = CGPointZero;
                    [engine performHumanTapAtPoint:ana.onlineStartPoint
                                      jitterRadius:config.jitterRadiusPt
                                         holdMinMs:config.holdMinMs
                                         holdMaxMs:config.holdMaxMs
                                    outActualPoint:&pt];
                    onlineTapsSent++;
                    appendDaemonLog(@"Hết giờ nghỉ -> Đã bấm [Mở nhận chuyến] phát %d tại (%.0f, %.0f)!",
                                    onlineTapsSent, pt.x, pt.y);
                    if (onlineTapsSent == 1 && config.hapticEnabled) {
                        triggerHapticFeedback(YES);
                    }

                    // Wait 1.9s then verify on next iteration that 'Đang trực tuyến' actually appeared!
                    usleep(1900000);
                    CIImage *vImg = [engine captureScreenCIImage];
                    ScreenAnalysis *vAna = [scanner analyzeScreenImage:vImg
                                                            screenSize:engine.logicalScreenSize
                                                            yellowDotY:engine.lastOrderYellowDotY
                                                      hasBottomTealBar:engine.lastFrameHasBottomTealButton
                                                     hasTopWhiteHeader:engine.lastFrameHasOrderHeaderAtTop
                                                    headerIconWarmFood:engine.lastFrameHeaderIconWarmFood
                                                    headerIconCoolRide:engine.lastFrameHeaderIconCoolRide
                                                                config:config
                                                       priceRetryCount:0];
                    if (!vAna.isLobbyOffline && vAna.hasOrderPopup) {
                        resetFrontmostAppMonitors();
                        [engine invalidateAnalyzedBaseline];
                        if (ioInActiveTrip) *ioInActiveTrip = NO;
                        state.phaseDescription = @"Đang trực tuyến / Canh đơn (Turbo)";
                        state.workerHeartbeatEpoch = [[NSDate date] timeIntervalSince1970];
                        [state saveStateAndNotify:YES];
                        return YES;
                    }
                    if (vAna.isLobbyOnline) {
                        backOnline = YES;
                        break;
                    }
                    continue;
                }
            }

            usleep(950000);
        }
    }

    if (!backOnline && !gShouldExit) {
        appendDaemonLog(@"[CHÚ Ý] Quá 35s chưa xác nhận lên 'Đang trực tuyến' — hãy kiểm tra màn hình GPS/mạng.");
    }

    resetFrontmostAppMonitors();
    [engine invalidateAnalyzedBaseline];
    if (ioInActiveTrip) *ioInActiveTrip = NO;
    state.phaseDescription = @"Đang trực tuyến / Canh đơn";
    state.workerHeartbeatEpoch = [[NSDate date] timeIntervalSince1970];
    [state saveStateAndNotify:YES];
    return NO;
}

static int runWorkerMain(void) {
    prepareWorkerSession();

    @autoreleasepool {
        ignoreBenignDaemonSignals();
        signal(SIGTERM, handleWorkerSignal);
        signal(SIGINT,  handleWorkerSignal);

        pid_t myPid = getpid();
        NSString *myPidStr = [NSString stringWithFormat:@"%d", myPid];
        writeStringUnprotectedAtomically(myPidStr, kDaemonPidPath);

        dispatch_queue_t bgQ = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
        int reloadTok = 0, stopTok = 0, skipTok = 0, resetNavTok = 0, resetCntTok = 0, diagTok = 0;

        notify_register_dispatch(kNotifyReloadConfig,  &reloadTok,   bgQ, ^(int t) { gNeedsReload = YES; });
        notify_register_dispatch(kNotifyStopDaemon,    &stopTok,     bgQ, ^(int t) { gShouldExit = YES; });
        notify_register_dispatch(kNotifySkipPause,     &skipTok,     bgQ, ^(int t) { gSkipPauseRequested = YES; });
        notify_register_dispatch(kNotifyResetNavLocks, &resetNavTok, bgQ, ^(int t) { gResetNavRequested = YES; });
        notify_register_dispatch(kNotifyResetCounters, &resetCntTok, bgQ, ^(int t) { gResetCntRequested = YES; });
        notify_register_dispatch(kNotifyDiagCapture,   &diagTok,     bgQ, ^(int t) { gDiagRequested = YES; });

        FilterConfig *config      = [FilterConfig loadFromDisk];
        if (!config.masterEnabled && readMasterEnabledSafely(YES)) {
            config.masterEnabled = YES;
        }
        RuntimeDaemonState *state = [RuntimeDaemonState loadState];
        double bootEpoch          = [[NSDate date] timeIntervalSince1970];
        NSString *myLiveBinPath   = resolveLiveAppPindBinaryPath() ?: @"";
        BOOL hadPreviousVersion   = [state.daemonVersion isEqualToString:kCurrentDaemonVersion] &&
                                    (myLiveBinPath.length == 0 || [state.daemonBinaryPath isEqualToString:myLiveBinPath]);

        state.daemonVersion        = kCurrentDaemonVersion;
        if (myLiveBinPath.length > 0) {
            state.daemonBinaryPath = myLiveBinPath;
        }
        state.workerHeartbeatEpoch = bootEpoch;
        if (state.pauseEndEpoch <= bootEpoch + 2.0) {
            state.pauseEndEpoch    = 0.0;
            state.phaseDescription = @"Đang trực tuyến / Canh đơn";
        }
        [state saveStateAndNotify:YES];
        gNeedsReload = NO;

        ScreenTouchEngine *engine = [ScreenTouchEngine sharedEngine];
        OrderScanner *scanner     = [OrderScanner sharedScanner];
        HanoiFoodFilterEngine *foodEngine = [HanoiFoodFilterEngine sharedEngine];

        if (!hadPreviousVersion) {
            CIImage *probeImg = [engine captureScreenCIImage];
            BOOL screenOk = (probeImg != nil && engine.lastCaptureHadPixels);
            appendDaemonLog(@"pind v4.9 Bất Tử + Tự Chữa Lành + DB 3 Sàn (%ld quán + %ld ghim HN) chạy (WD:%d WK:%d, Quét:%@)",
                            (long)foodEngine.loadedMerchantCount,
                            (long)foodEngine.loadedStreetPinCount,
                            getRunningWatchdogPID(), myPid,
                            screenOk ? @"OK" : @"LỖI");
            notify_post(kNotifyStatsUpdated);
        }

        BOOL inActiveTripSession = (state.navPickupLocked || state.navDropoffLocked);
        int consecutiveOfflineInterrupts = 0;

        // Seamlessly finish an in-progress Food Pause if revived mid-countdown
        if (state.pauseEndEpoch > bootEpoch + 2.0 && config.masterEnabled) {
            runOfflinePauseAndRestartCycle(&config, state, engine, scanner, YES, &inActiveTripSession, nil, 0.0);
        }

        NSInteger retryCount                  = 0;
        int bannerSwipeCountForPopup          = 0;
        NSString *lastSkippedPopupSignature   = nil;
        NSString *lastHandledOrderFingerprint = nil;
        double lastHandledOrderEpoch          = 0.0;
        BOOL lastHandledWasAccept             = NO;
        BOOL wasInCoolSleep                   = NO;
        BOOL prevFrameHadBlueNav              = NO;
        BOOL activeTripConfirmedNonBike       = NO;
        double lockedSinceEpoch               = 0.0;
        int coolSleepTickCounter              = 0;
        double turboUntilEpoch                = bootEpoch + 6.0;
        double postTransitionUntilEpoch       = 0.0;
        double lastFullOCREpoch               = 0.0;
        double lastHeartbeatSaveEpoch         = bootEpoch;

        while (!gShouldExit) {
            @autoreleasepool {
                @try {
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.002, false);
                double now = [[NSDate date] timeIntervalSince1970];

                if (now - lastHeartbeatSaveEpoch >= 4.0) {
                    if (readRawPidValueFromFile(kDaemonPidPath) != myPid) {
                        writeStringUnprotectedAtomically(myPidStr, kDaemonPidPath);
                    }
                    state.workerHeartbeatEpoch = now;
                    [state saveStateAndNotify:NO];
                    lastHeartbeatSaveEpoch = now;
                }

                if (gNeedsReload) {
                    FilterConfig *reloaded = [FilterConfig loadFromDisk];
                    if (!reloaded.masterEnabled && readMasterEnabledSafely(YES)) {
                        reloaded.masterEnabled = YES;
                    }
                    config = reloaded;
                    gNeedsReload = NO;
                    resetFrontmostAppMonitors();
                    [engine invalidateAnalyzedBaseline];
                }
                if (gResetNavRequested) {
                    gResetNavRequested = NO;
                    inActiveTripSession    = NO;
                    activeTripConfirmedNonBike = NO;
                    state.navPickupLocked  = NO;
                    state.navDropoffLocked = NO;
                    [state saveStateAndNotify:YES];
                    appendDaemonLog(@"Đã Reset thủ công cả 2 chốt khóa Điều hướng về FALSE.");
                }
                if (gResetCntRequested) {
                    gResetCntRequested = NO;
                    state.statAcceptedCount = 0;
                    state.statRejectedCount = 0;
                    [state saveStateAndNotify:YES];
                }
                if (gDiagRequested) {
                    gDiagRequested = NO;
                    runDiagnosticCapture4Sec(config, engine, scanner, state);
                    continue;
                }

                if (!config.masterEnabled) {
                    if (readMasterEnabledSafely(YES)) {
                        config.masterEnabled = YES;
                    } else {
                        usleep(450000);
                        continue;
                    }
                }

                // Always track lock-screen state so unlocking after >= 3 mins spawns a 100% fresh Worker
                BOOL screenLocked = isDeviceScreenLocked();
                if (screenLocked) {
                    if (lockedSinceEpoch <= 0.0) {
                        lockedSinceEpoch = now;
                    }
                    if (!wasInCoolSleep) {
                        wasInCoolSleep = YES;
                        prevFrameHadBlueNav = NO;
                        retryCount = 0;
                        bannerSwipeCountForPopup = 0;
                        [engine invalidateAnalyzedBaseline];
                        state.phaseDescription = @"Ngủ mát 0% Nhiệt (Đang khóa màn hình)";
                        state.workerHeartbeatEpoch = now;
                        [state saveStateAndNotify:YES];
                    }
                    if ((now - bootEpoch) > 1800.0 || currentProcessFootprintMB() > 175) {
                        state.workerHeartbeatEpoch = now;
                        [state saveStateAndNotify:NO];
                        _exit(kExitCodeProactiveRAMTrim);
                    }
                    usleep(550000);
                    continue;
                } else if (lockedSinceEpoch > 0.0) {
                    double lockedDuration = now - lockedSinceEpoch;
                    lockedSinceEpoch = 0.0;
                    if (lockedDuration >= 180.0) {
                        // Phone was locked >= 3 mins (e.g. morning -> afternoon) -> Spawn brand-new Worker in 0.08s!
                        state.workerHeartbeatEpoch = now;
                        state.phaseDescription = @"Đang trực tuyến / Canh đơn (Mới mở khóa)";
                        [state saveStateAndNotify:NO];
                        _exit(kExitCodeProactiveRAMTrim);
                    }
                }

                CIImage *preCapturedImg = nil;

                // --- TẦNG HẠ NHIỆT 1: SMART-SLEEP KHI ĐANG MỞ GOOGLE MAPS / APP NGOÀI (CÓ CẢM BIẾN PIXEL TỰ ĐÁNH THỨC) ---
                if (config.smartCoolMode) {
                    NSString *frontBid = currentFrontmostAppBundleIDForConfig(config);
                    BOOL canScan = isFrontmostAppAllowedForScan(frontBid, config);

                    if (!canScan) {
                        coolSleepTickCounter++;
                        BOOL isGoogleMaps = [frontBid isEqualToString:@"com.google.Maps"];
                        int probeInterval = isGoogleMaps ? 4 : 2; // ~2.0s in Google Maps, ~1.0s in other/unknown state (0% Vision OCR!)

                        if ((coolSleepTickCounter % probeInterval) == 0) {
                            CIImage *probe = [engine captureScreenCIImage];
                            BOOL pixelLooksLikeDriverUI = (!isGoogleMaps &&
                                                           (engine.lastFrameLikelyHasBlueNavButton ||
                                                            engine.lastFrameLikelyHasLobbyPowerButton));
                            if (probe && (engine.lastFrameLikelyHasOrderPopup || pixelLooksLikeDriverUI)) {
                                // Self-healing override: Xanh SM order popup or Driver UI is on screen right now!
                                canScan = YES;
                                preCapturedImg = probe;
                                resetFrontmostAppMonitors();
                            }
                        }
                    }

                    if (!canScan) {
                        if (!wasInCoolSleep) {
                            wasInCoolSleep = YES;
                            prevFrameHadBlueNav = NO;
                            retryCount = 0;
                            bannerSwipeCountForPopup = 0;
                            [engine invalidateAnalyzedBaseline];
                            state.phaseDescription = [frontBid isEqualToString:@"com.google.Maps"]
                                ? @"Ngủ mát 0% Nhiệt (Đang mở Google Maps)"
                                : [NSString stringWithFormat:@"Ngủ mát 0%% Nhiệt (App ngoài: %@)", frontBid ?: @"khác"];
                            state.workerHeartbeatEpoch = now;
                            [state saveStateAndNotify:YES];
                        }

                        if (((now - bootEpoch) > 180.0 && currentProcessFootprintMB() > 180) ||
                            (now - bootEpoch) > 3600.0) {
                            state.workerHeartbeatEpoch = now;
                            [state saveStateAndNotify:NO];
                            _exit(kExitCodeProactiveRAMTrim);
                        }

                        usleep(500000);
                        continue;
                    } else if (wasInCoolSleep) {
                        // Switched back into Xanh SM -> Instant 6.5s Turbo!
                        wasInCoolSleep = NO;
                        coolSleepTickCounter = 0;
                        turboUntilEpoch = now + 6.5;
                        [engine invalidateAnalyzedBaseline];
                        state.phaseDescription = @"Đang trực tuyến / Canh đơn (Turbo)";
                        state.workerHeartbeatEpoch = now;
                        [state saveStateAndNotify:YES];
                    } else {
                        coolSleepTickCounter = 0;
                    }
                } else if (wasInCoolSleep) {
                    wasInCoolSleep = NO;
                    coolSleepTickCounter = 0;
                    state.phaseDescription = @"Đang trực tuyến / Canh đơn";
                    [state saveStateAndNotify:YES];
                }

                // --- CHỤP KHUNG HÌNH & TẦNG HẠ NHIỆT 2: KHIÊN GOOGLE MAPS + CẢM BIẾN PIXEL 0.02ms ---
                CIImage *screenImg = preCapturedImg ?: [engine captureScreenCIImage];
                if (!screenImg) {
                    usleep((useconds_t)(MAX(200, config.scanIntervalMs) * 1000));
                    continue;
                }

                if (config.smartCoolMode &&
                    engine.lastFrameLooksLikeGoogleMapsNav &&
                    !engine.lastFrameLikelyHasOrderPopup) {
                    // Pixel backup shield: Google Maps green turn-by-turn banner is active -> 0% Vision OCR!
                    usleep(450000);
                    continue;
                }

                NSInteger frameChangedBeforeMark = engine.lastFrameChangedSamples;
                BOOL hasUnlockedNavPhase = ((config.autoNavPickup && !state.navPickupLocked) ||
                                            (config.autoNavDropoff && !state.navDropoffLocked));
                BOOL blueNavJustAppeared = (engine.lastFrameLikelyHasBlueNavButton && !prevFrameHadBlueNav);
                prevFrameHadBlueNav = engine.lastFrameLikelyHasBlueNavButton;
                BOOL blueNavDueForOCR = (engine.lastFrameLikelyHasBlueNavButton &&
                                         hasUnlockedNavPhase &&
                                         (blueNavJustAppeared || (!activeTripConfirmedNonBike && (now - lastFullOCREpoch) >= 0.70)));

                BOOL inTurbo = (now < turboUntilEpoch) ||
                               (now < postTransitionUntilEpoch) ||
                               engine.lastFrameLikelyHasOrderPopup ||
                               blueNavDueForOCR ||
                               (retryCount > 0);

                if (config.smartCoolMode &&
                    !inTurbo &&
                    frameChangedBeforeMark <= 3 &&
                    (now - lastFullOCREpoch) < 2.2) {
                    // Static screen inside Xanh SM with no order popup -> skip heavy Vision ANE OCR!
                    // Emergency RAM ceiling only (>220 MB): normal steady state with DB 3 Sàn + Vision is ~108-120 MB
                    if ((now - bootEpoch) > 300.0 && currentProcessFootprintMB() > 220) {
                        state.workerHeartbeatEpoch = now;
                        [state saveStateAndNotify:NO];
                        _exit(kExitCodeProactiveRAMTrim);
                    }
                    NSInteger idleMs = MAX(220, config.scanIntervalMs);
                    usleep((useconds_t)(idleMs * 1000));
                    continue;
                }

                [engine markCurrentFrameAnalyzed];
                lastFullOCREpoch = now;

                ScreenAnalysis *ana = [scanner analyzeScreenImage:screenImg
                                                       screenSize:engine.logicalScreenSize
                                                       yellowDotY:engine.lastOrderYellowDotY
                                                 hasBottomTealBar:engine.lastFrameHasBottomTealButton
                                                hasTopWhiteHeader:engine.lastFrameHasOrderHeaderAtTop
                                               headerIconWarmFood:engine.lastFrameHeaderIconWarmFood
                                               headerIconCoolRide:engine.lastFrameHeaderIconCoolRide
                                                           config:config
                                                  priceRetryCount:retryCount];

                if (!ana.hasOrderPopup && frameChangedBeforeMark >= 18) {
                    // Screen just underwent a big visual transition (e.g., order card sliding up at 40ms):
                    // force a fast 180ms follow-up OCR scan so we NEVER settle onto a 2.2s static skip!
                    postTransitionUntilEpoch = now + 0.85;
                }

                // 1. KIỂM TRA 3 ĐIỀU KIỆN MỞ KHÓA CHỐT ĐIỀU HƯỚNG & TRẠNG THÁI ĐANG TRONG CHUYẾN (NỐI CHUYẾN)
                if (ana.isPaymentConfirmScreen) {
                    inActiveTripSession = NO;
                    activeTripConfirmedNonBike = NO;
                    resetBothNavLocks(state, @"Thấy màn 'Xác nhận hoàn thành' -> Xóa sạch 2 chốt Điều hướng!");
                } else if (ana.isLobbyOnline || ana.isLobbyOffline) {
                    inActiveTripSession = NO;
                    activeTripConfirmedNonBike = NO;
                    consecutiveOfflineInterrupts = 0;
                    resetBothNavLocks(state, @"Về màn hình sảnh chờ -> Xóa sạch 2 chốt Điều hướng!");
                } else if (ana.isAnyActiveTripScreen) {
                    inActiveTripSession = YES;
                    consecutiveOfflineInterrupts = 0;
                    if (ana.hasPassengerAndNav) {
                        activeTripConfirmedNonBike = NO;
                        if (ana.isPickupStage && state.navDropoffLocked) {
                            resetBothNavLocks(state, @"Phát hiện cuốc Bike nối chuyến mới -> Xóa chốt cũ đón khách mới!");
                        }
                    } else if (engine.lastFrameLikelyHasBlueNavButton) {
                        // Đang chạy đơn giao hàng Express / Express 2H / Food -> Không auto tap Điều hướng, ngắt hỏi OCR lặp!
                        activeTripConfirmedNonBike = YES;
                    }
                }

                // 2. XỬ LÝ BẢNG NỔ ĐƠN ('Bike' / 'Express' / 'Express 2H' vs 'Green Food')
                if (ana.hasOrderPopup) {
                    turboUntilEpoch = now + 4.0;

                    // WEAK-4G SPINNING POPUP GUARD:
                    // If we JUST confirmed-tapped [Nhận] (0.85s) or [X] (4.2s) on this exact order and 4G lag keeps it spinning,
                    // wait smoothly for GSM server ACK without double-tapping or double-counting stats!
                    if (!config.dryRunMode &&
                        isSameSpinningOrderOnWeak4G(ana, lastHandledOrderFingerprint, lastHandledOrderEpoch, lastHandledWasAccept, now)) {
                        usleep(220000);
                        continue;
                    }

                    if (ana.orderAction == OrderActionHeaderCovered) {
                        retryCount++;
                        if (!config.dryRunMode && bannerSwipeCountForPopup < 2 && (retryCount == 1 || retryCount == 3)) {
                            CGFloat midX = engine.logicalScreenSize.width * 0.5;
                            [engine performQuickSwipeFromPoint:CGPointMake(midX, 62.0)
                                                       toPoint:CGPointMake(midX, 6.0)
                                                    durationMs:55];
                            bannerSwipeCountForPopup++;
                            appendDaemonLog(@"[CHỐNG CHE] Vuốt hất banner thông báo đỉnh màn hình (nhịp %d) để đọc rõ tên đơn...", bannerSwipeCountForPopup);
                            notify_post(kNotifyStatsUpdated);
                            usleep(165000);
                            continue;
                        }
                        usleep(115000);
                        continue;
                    }

                    if (ana.orderAction == OrderActionWaitRetryPrice) {
                        retryCount++;
                        usleep(115000);
                        continue;
                    }

                    if (ana.orderAction == OrderActionSkipDisabled) {
                        NSString *sig = ana.orderReason ?: @"skip";
                        if (![lastSkippedPopupSignature isEqualToString:sig]) {
                            lastSkippedPopupSignature = sig;
                            appendDaemonLog(@"%@", sig);
                            notify_post(kNotifyStatsUpdated);
                        }
                        usleep(550000);
                        continue;
                    }

                    if (ana.orderAction == OrderActionTapAccept || ana.orderAction == OrderActionTapRejectX) {
                        uint32_t spentVerifyMs = 0;

                        // KHÓA KIỂM CHỨNG GIÁ 2 KHUNG HÌNH CHO ĐƠN GREEN FOOD (CHỐNG NHÒE 17k -> 77k)
                        if (ana.isGreenFood && !config.rejectAllFood) {
                            double tVerifyStart = CFAbsoluteTimeGetCurrent();
                            usleep(95000);
                            if (gShouldExit) break;

                            CIImage *verifyImg = [engine captureScreenCIImage];
                            if (verifyImg) {
                                [engine markCurrentFrameAnalyzed];
                                ScreenAnalysis *verifyAna = [scanner analyzeScreenImage:verifyImg
                                                                             screenSize:engine.logicalScreenSize
                                                                             yellowDotY:engine.lastOrderYellowDotY
                                                                       hasBottomTealBar:engine.lastFrameHasBottomTealButton
                                                                      hasTopWhiteHeader:engine.lastFrameHasOrderHeaderAtTop
                                                                     headerIconWarmFood:engine.lastFrameHeaderIconWarmFood
                                                                     headerIconCoolRide:engine.lastFrameHeaderIconCoolRide
                                                                                 config:config
                                                                        priceRetryCount:retryCount + 1];
                                if (!verifyAna.hasOrderPopup) {
                                    retryCount = 0;
                                    bannerSwipeCountForPopup = 0;
                                    continue;
                                }
                                if (verifyAna.isGreenFood && verifyAna.detectedPriceVND > 0) {
                                    if (verifyAna.detectedPriceVND != ana.detectedPriceVND && retryCount < 2) {
                                        // Giá đang dao động do trượt bảng -> Đợi nhịp kế tiếp lấy số đứng im
                                        retryCount++;
                                        continue;
                                    }
                                    ana = verifyAna;
                                }
                            }
                            double verifyElapsedMs = (CFAbsoluteTimeGetCurrent() - tVerifyStart) * 1000.0;
                            spentVerifyMs = (verifyElapsedMs > 0.0) ? (uint32_t)verifyElapsedMs : 95;
                        }

                        retryCount = 0;
                        bannerSwipeCountForPopup = 0;
                        lastSkippedPopupSignature = nil;

                        if (ana.orderAction != OrderActionTapAccept && ana.orderAction != OrderActionTapRejectX) {
                            continue;
                        }

                        BOOL isAccept = (ana.orderAction == OrderActionTapAccept);
                        BOOL newOrderArrivedImmediately = NO;
                        NSInteger minD = isAccept ? config.acceptDelayMinMs : config.rejectDelayMinMs;
                        NSInteger maxD = isAccept ? config.acceptDelayMaxMs : config.rejectDelayMaxMs;
                        if (maxD < minD) maxD = minD + 20;

                        uint32_t rawDelayMs = (uint32_t)(minD + arc4random_uniform((uint32_t)(maxD - minD + 1)));
                        uint32_t remainDelayMs = (rawDelayMs > spentVerifyMs + 25) ? (rawDelayMs - spentVerifyMs) : 25;
                        usleep(remainDelayMs * 1000);
                        if (gShouldExit) break;

                        if (config.dryRunMode) {
                            appendDaemonLog(@"[THỬ] %@ | Tâm (%.0f, %.0f) trễ %ums",
                                            ana.orderReason, ana.orderTargetPoint.x, ana.orderTargetPoint.y, rawDelayMs);
                            if (config.hapticEnabled) triggerHapticFeedback(isAccept);
                            notify_post(kNotifyStatsUpdated);
                        } else {
                            // KHÓA AN TOÀN 0.5ms TRƯỚC KHI BẤM [X]: Nếu bảng đơn vừa tự trôi mất trong lúc chờ delay -> HỦY CHẠM NGAY!
                            if (!isAccept) {
                                CIImage *preTapImg = [engine captureScreenCIImage];
                                if (!preTapImg || !engine.lastFrameLikelyHasOrderPopup) {
                                    appendDaemonLog(@"[AN TOÀN] Bảng đơn Green Food vừa tự trôi mất trước khi hạ ngón tay -> Hủy cú chạm [X] (tránh bấm nhầm 0.0/8)!");
                                    [engine invalidateAnalyzedBaseline];
                                    notify_post(kNotifyStatsUpdated);
                                    turboUntilEpoch = [[NSDate date] timeIntervalSince1970] + 4.5;
                                    continue;
                                }
                            }

                            // BẤM VÒNG KÍN CÓ KIỂM CHỨNG & BỒI CHỐNG TRƯỢT CẢM ỨNG (CLOSED-LOOP TAP RETRY)
                            // Riêng nút [X] góc trên phải trùng khít vị trí nút ⚠️ / 0.0/8 ở sảnh -> Tối đa bồi 1 nhịp + chờ 620ms đủ đóng hẳn!
                            NSInteger maxRetries = isAccept ? config.tapVerifyRetries : MIN(1, config.tapVerifyRetries);
                            CGFloat tapJitter    = isAccept ? config.jitterRadiusPt   : MIN(3.0, config.jitterRadiusPt);
                            CGPoint targetPt     = ana.orderTargetPoint;
                            CGPoint actualPt     = targetPt;
                            NSInteger tapsSent   = 0;
                            BOOL confirmedGone   = NO;

                            for (NSInteger attempt = 0; attempt <= maxRetries && !gShouldExit; attempt++) {
                                if (attempt == 1) {
                                    [engine refreshHIDClient];
                                }
                                if (attempt > 0 && !isAccept) {
                                    // Nếu phát đầu bấm [X] Food chưa tắt (vướng banner góc trên), hất banner lên rồi kiểm tra lại pixel 1 lần nữa trước khi bồi!
                                    CGFloat midX = engine.logicalScreenSize.width * 0.5;
                                    [engine performQuickSwipeFromPoint:CGPointMake(midX, 62.0)
                                                               toPoint:CGPointMake(midX, 6.0)
                                                            durationMs:50];
                                    usleep(140000);
                                    CIImage *recheckImg = [engine captureScreenCIImage];
                                    if (!recheckImg || !engine.lastFrameLikelyHasOrderPopup || !engine.lastFrameHasOrderHeaderAtTop) {
                                        confirmedGone = YES;
                                        break;
                                    }
                                }

                                BOOL tapOk = [engine performHumanTapAtPoint:targetPt
                                                               jitterRadius:tapJitter
                                                                  holdMinMs:config.holdMinMs
                                                                  holdMaxMs:config.holdMaxMs
                                                             outActualPoint:&actualPt];
                                if (tapOk) {
                                    tapsSent++;
                                }

                                if (maxRetries <= 0) {
                                    confirmedGone = YES;
                                    break;
                                }

                                // Với [X] hủy Food: chờ đủ 620ms cho hiệu ứng trượt bảng đóng dứt điểm (không bồi xuyên xuống nút ⚠️ / 0.0/8)!
                                uint32_t postTapWaitUs = isAccept ? 380000 : 620000;
                                usleep(postTapWaitUs);
                                if (gShouldExit) break;

                                CIImage *chkImg = [engine captureScreenCIImage];
                                if (!chkImg) {
                                    confirmedGone = YES;
                                    break;
                                }

                                // Kiểm tra nhanh 0.01ms bằng cảm biến Pixel: nếu thanh xanh 'Nhận chuyến' đáy màn đã biến mất -> Bảng đơn đã tắt 100%!
                                if (!isAccept && !engine.lastFrameLikelyHasOrderPopup) {
                                    confirmedGone = YES;
                                    break;
                                }

                                [engine markCurrentFrameAnalyzed];
                                ScreenAnalysis *chkAna = [scanner analyzeScreenImage:chkImg
                                                                          screenSize:engine.logicalScreenSize
                                                                          yellowDotY:engine.lastOrderYellowDotY
                                                                    hasBottomTealBar:engine.lastFrameHasBottomTealButton
                                                                   hasTopWhiteHeader:engine.lastFrameHasOrderHeaderAtTop
                                                                  headerIconWarmFood:engine.lastFrameHeaderIconWarmFood
                                                                  headerIconCoolRide:engine.lastFrameHeaderIconCoolRide
                                                                              config:config
                                                                     priceRetryCount:2];
                                if (chkAna.isAnyActiveTripScreen) {
                                    inActiveTripSession = YES;
                                } else if (chkAna.isLobbyOnline || chkAna.isLobbyOffline || chkAna.isPaymentConfirmScreen || chkAna.hasAnyLobbyMarker) {
                                    inActiveTripSession = NO;
                                }

                                if (chkAna.hasBlockingBottomSheet && !config.dryRunMode) {
                                    appendDaemonLog(@"[GỠ KẸT] Đóng bảng '0.0/8 Lái xe liên tục' ngay sau khi hủy đơn!");
                                    dismissBlockingLobbySheet(engine, config);
                                    confirmedGone = YES;
                                    break;
                                }

                                if (!isAccept && chkAna.hasRejectConfirmPopup) {
                                    CGPoint cfmPt = CGPointZero;
                                    [engine performHumanTapAtPoint:chkAna.rejectConfirmPoint
                                                      jitterRadius:config.jitterRadiusPt
                                                         holdMinMs:config.holdMinMs
                                                         holdMaxMs:config.holdMaxMs
                                                    outActualPoint:&cfmPt];
                                    appendDaemonLog(@"Đã bấm xác nhận từ chối đơn Food tại (%.0f, %.0f)", cfmPt.x, cfmPt.y);
                                    usleep(350000);
                                    confirmedGone = YES;
                                    break;
                                }

                                if (!chkAna.hasOrderPopup || (!isAccept && chkAna.hasAnyLobbyMarker)) {
                                    confirmedGone = YES;
                                    break;
                                }

                                // Nếu vừa bấm [X] hủy Food xong mà nổ liền 1 đơn Bike/Express/Food ngon (hoặc đơn Food thứ 2 khác quán/khác giá):
                                // DỪNG BỒI [X] NGAY LẬP TỨC để sang nhịp sau vồ đơn Bike/Express hoặc xử lý chuẩn đơn mới!
                                if (!isAccept) {
                                    double chkEpoch = [[NSDate date] timeIntervalSince1970];
                                    BOOL switchedToAcceptOrder = (chkAna.orderAction == OrderActionTapAccept || !chkAna.isGreenFood);
                                    BOOL switchedToDifferentFood = (chkAna.isGreenFood &&
                                                                    ana.orderFingerprint.length > 0 &&
                                                                    !isSameSpinningOrderOnWeak4G(chkAna, ana.orderFingerprint, chkEpoch, NO, chkEpoch));
                                    if (switchedToAcceptOrder || switchedToDifferentFood) {
                                        confirmedGone = YES;
                                        newOrderArrivedImmediately = YES;
                                        break;
                                    }
                                    if (!engine.lastFrameHasOrderHeaderAtTop && chkAna.orderAction != OrderActionHeaderCovered) {
                                        // Tiêu đề đơn đã tụt khỏi đỉnh màn hình -> Đang đóng dở, tuyệt đối không bồi!
                                        confirmedGone = YES;
                                        break;
                                    }
                                }

                                // Bảng đơn cũ vẫn còn trên màn hình -> cập nhật tọa độ nút mới nhất để bồi ngay!
                                if ((isAccept && chkAna.orderAction == OrderActionTapAccept) ||
                                    (!isAccept && chkAna.orderAction == OrderActionTapRejectX)) {
                                    targetPt = chkAna.orderTargetPoint;
                                }
                            }

                            BOOL acceptedBikeOrder = NO;
                            if (tapsSent > 0) {
                                double doneNow = [[NSDate date] timeIntervalSince1970];
                                // CRITICAL: Only lock out Accept if the card actually closed (confirmedGone)!
                                // If an Accept tap missed and the popup is still sitting there, allow immediate retry on next loop!
                                if (ana.orderFingerprint.length > 0 && (!isAccept || confirmedGone)) {
                                    lastHandledOrderFingerprint = ana.orderFingerprint;
                                    lastHandledOrderEpoch       = doneNow;
                                    lastHandledWasAccept        = isAccept;
                                }
                                if (isAccept) {
                                    if (confirmedGone) {
                                        inActiveTripSession = YES;
                                        consecutiveOfflineInterrupts = 0;
                                        state.statAcceptedCount += 1;
                                    }
                                    NSString *svcLow = (ana.detectedServiceTitle ?: @"").lowercaseString;
                                    acceptedBikeOrder = (!ana.isGreenFood && ![svcLow containsString:@"express"] && ![svcLow containsString:@"food"]);
                                    if (acceptedBikeOrder) {
                                        activeTripConfirmedNonBike = NO;
                                        state.phaseDescription = @"Vừa nhận Bike -> Đang canh nút Điều hướng";
                                        // Kích hoạt Turbo 15 giây liên tục để vồ nút xanh 'Điều hướng' ngay khi Xanh SM dựng xong thẻ khách Bike!
                                        turboUntilEpoch = doneNow + 15.0;
                                    } else if (confirmedGone) {
                                        activeTripConfirmedNonBike = YES;
                                        state.phaseDescription = @"Đang chạy đơn giao hàng (Không auto bấm Map)";
                                    }
                                } else {
                                    state.statRejectedCount += 1;
                                }
                                state.workerHeartbeatEpoch = doneNow;
                                [state saveStateAndNotify:YES];

                                NSString *tapNote = (tapsSent == 1)
                                    ? @"Ăn ngay phát 1"
                                    : [NSString stringWithFormat:@"Bồi %ld phát%@", (long)tapsSent, confirmedGone ? @" ăn chắc" : @" (sẽ bồi tiếp nếu còn)"];
                                appendDaemonLog(@"%@ | Chạm (%.0f, %.0f) [%@]",
                                                ana.orderReason, actualPt.x, actualPt.y, tapNote);
                                if (config.hapticEnabled && (!isAccept || confirmedGone)) triggerHapticFeedback(isAccept);
                                notify_post(kNotifyStatsUpdated);
                            }
                        }

                        [engine invalidateAnalyzedBaseline];

                        // CASE 1: Nổ liền đơn thứ 2 ngay tức khắc sau khi vừa hủy Food -> Xử lý đơn mới luôn với độ trễ 0ms!
                        if (!isAccept && newOrderArrivedImmediately) {
                            appendDaemonLog(@"Nổ chèn đơn mới ngay lập tức -> Dừng Tắt app để vồ/xử lý đơn mới ngay!");
                            turboUntilEpoch = [[NSDate date] timeIntervalSince1970] + 6.5;
                            continue;
                        }

                        // CASE 2: Đơn Food nổ kiểu NỐI CHUYẾN khi đang dở cuốc xe -> CHỈ TỪ CHỐI [X], TUYỆT ĐỐI KHÔNG TẮT APP!
                        if (!isAccept && ana.isGreenFood &&
                            (inActiveTripSession || state.navPickupLocked || state.navDropoffLocked)) {
                            appendDaemonLog(@"Đã từ chối Food nối chuyến — Đang trong chuyến xe nên giữ nguyên cuốc, KHÔNG tắt app!");
                            state.phaseDescription = @"Đang trong chuyến xe / Canh nối chuyến";
                            state.workerHeartbeatEpoch = [[NSDate date] timeIntervalSince1970];
                            [state saveStateAndNotify:YES];
                            NSInteger cdTripMs = MAX(450, MIN(900, config.cooldownMs - 380));
                            usleep((useconds_t)(cdTripMs * 1000));
                            continue;
                        }

                        // CASE 3: Ở sảnh chờ rảnh rỗi vừa hủy Food -> Vào quy trình Tắt nhận chuyến + Kill App (nếu nổ chèn đơn mới thì tự ngắt quay ra ngay!)
                        if (!isAccept && ana.isGreenFood && config.pauseAfterRejectFood) {
                            BOOL interruptedByNewOrder = runOfflinePauseAndRestartCycle(&config, state, engine, scanner, NO, &inActiveTripSession, lastHandledOrderFingerprint, lastHandledOrderEpoch);
                            if (interruptedByNewOrder && consecutiveOfflineInterrupts < 8) {
                                consecutiveOfflineInterrupts++;
                                turboUntilEpoch = [[NSDate date] timeIntervalSince1970] + 6.5;
                                continue;
                            }
                            consecutiveOfflineInterrupts = 0;
                            continue;
                        }

                        // Khi vừa bấm [Nhận chuyến] Bike chở khách: chỉ nghỉ 180ms (nếu chưa đóng hẳn) hoặc 320ms rồi quét ngay thẻ khách để tap 'Điều hướng' tức thì!
                        NSString *svcLowCd = (ana.detectedServiceTitle ?: @"").lowercaseString;
                        BOOL isBikeAcceptCd = (isAccept && !ana.isGreenFood && ![svcLowCd containsString:@"express"] && ![svcLowCd containsString:@"food"]);
                        NSInteger cdMs = isAccept ? (isBikeAcceptCd ? 300 : 420) : MAX(600, config.cooldownMs - 380);
                        usleep((useconds_t)(cdMs * 1000));
                        continue;
                    }
                } else {
                    retryCount = 0;
                    bannerSwipeCountForPopup = 0;
                    lastSkippedPopupSignature = nil;
                    if (lastHandledOrderFingerprint && (now - lastHandledOrderEpoch) > 0.55) {
                        // Card has cleanly left the screen -> reset fingerprint immediately!
                        lastHandledOrderFingerprint = nil;
                        lastHandledOrderEpoch       = 0.0;
                        lastHandledWasAccept        = NO;
                    }

                    if (ana.hasBlockingBottomSheet) {
                        inActiveTripSession = NO;
                        if (!config.dryRunMode) {
                            appendDaemonLog(@"[GỠ KẸT] Thấy bảng '0.0/8 Lái xe liên tục' che sảnh -> Tự đóng ngay!");
                            dismissBlockingLobbySheet(engine, config);
                            [engine invalidateAnalyzedBaseline];
                            notify_post(kNotifyStatsUpdated);
                            continue;
                        }
                    }
                }

                // 3. XỬ LÝ AUTO TAP NÚT TRÒN XANH 'ĐIỀU HƯỚNG' (NHẠY TỨC THÌ KỂ CẢ KHI MÀN ĐỨNG YÊN + CHỐNG LẶP 100%)
                if (ana.hasPassengerAndNav) {
                    BOOL needPickupTap  = (ana.isPickupStage  && config.autoNavPickup  && !state.navPickupLocked);
                    BOOL needDropoffTap = (ana.isDropoffStage && config.autoNavDropoff && !state.navDropoffLocked);

                    if (needPickupTap || needDropoffTap) {
                        NSInteger settleMs = (config.navSettleDelayMs == 650) ? 320 : MAX(180, config.navSettleDelayMs);
                        usleep((useconds_t)(settleMs * 1000));
                        if (gShouldExit) break;

                        CIImage *settledImg = [engine captureScreenCIImage];
                        ScreenAnalysis *settledAna = settledImg
                            ? [scanner analyzeScreenImage:settledImg
                                               screenSize:engine.logicalScreenSize
                                               yellowDotY:engine.lastOrderYellowDotY
                                         hasBottomTealBar:engine.lastFrameHasBottomTealButton
                                        hasTopWhiteHeader:engine.lastFrameHasOrderHeaderAtTop
                                       headerIconWarmFood:engine.lastFrameHeaderIconWarmFood
                                       headerIconCoolRide:engine.lastFrameHeaderIconCoolRide
                                                   config:config
                                          priceRetryCount:0]
                            : nil;

                        BOOL stillValid = settledAna && settledAna.hasPassengerAndNav &&
                                          ((needPickupTap && settledAna.isPickupStage) ||
                                           (needDropoffTap && settledAna.isDropoffStage));

                        if (stillValid) {
                            [engine markCurrentFrameAnalyzed];
                            if (needPickupTap) {
                                state.navPickupLocked  = YES;
                                state.phaseDescription = @"Đã mở Map Đón khách (Khóa Pha 1)";
                            } else {
                                state.navDropoffLocked = YES;
                                state.phaseDescription = @"Đã mở Map Trả khách (Khóa Pha 2)";
                            }
                            state.workerHeartbeatEpoch = [[NSDate date] timeIntervalSince1970];
                            [state saveStateAndNotify:YES];

                            CGPoint targetNav = settledAna.navBluePoint;
                            if (config.dryRunMode) {
                                appendDaemonLog(@"[THỬ] %@ -> Sẽ tap %ld lần nút xanh Điều hướng (%.0f, %.0f)",
                                                needPickupTap ? @"Pha Đón khách" : @"Pha Trả khách",
                                                (long)config.navTapCount, targetNav.x, targetNav.y);
                                if (config.hapticEnabled) triggerHapticFeedback(NO);
                                notify_post(kNotifyStatsUpdated);
                                usleep(1500000);
                            } else {
                                CGPoint lastPt = targetNav;
                                [engine performMultiTapAtPoint:targetNav
                                                      tapCount:config.navTapCount
                                                    intervalMs:config.navTapIntervalMs
                                                  jitterRadius:MIN(4.0, config.jitterRadiusPt)
                                                     holdMinMs:config.holdMinMs
                                                     holdMaxMs:config.holdMaxMs
                                                  outLastPoint:&lastPt];

                                appendDaemonLog(@"%@ -> Đã tap %ld lần nút xanh Điều hướng (%.0f, %.0f) [KHÓA CHỐT]",
                                                needPickupTap ? @"Pha 1 (Đã đến điểm đón)" : @"Pha 2 (Hoàn thành chuyến)",
                                                (long)config.navTapCount, lastPt.x, lastPt.y);
                                if (config.hapticEnabled) triggerHapticFeedback(NO);
                                notify_post(kNotifyStatsUpdated);

                                // Closed-loop 850ms verification: if Xanh SM stayed frontmost with blue Nav button untouched (4G/UI lag swallowed tap), fire 1 clean recovery tap!
                                usleep(850000);
                                if (!gShouldExit) {
                                    NSString *afterNavBid = currentFrontmostAppBundleIDForConfig(config);
                                    if (isFrontmostAppAllowedForScan(afterNavBid, config)) {
                                        CIImage *chkNavImg = [engine captureScreenCIImage];
                                        if (chkNavImg && engine.lastFrameLikelyHasBlueNavButton && !engine.lastFrameLooksLikeGoogleMapsNav) {
                                            [engine refreshHIDClient];
                                            CGPoint recPt = targetNav;
                                            [engine performMultiTapAtPoint:targetNav
                                                                  tapCount:1
                                                                intervalMs:config.navTapIntervalMs
                                                              jitterRadius:2.0
                                                                 holdMinMs:config.holdMinMs
                                                                 holdMaxMs:config.holdMaxMs
                                                              outLastPoint:&recPt];
                                            appendDaemonLog(@"[BỒI MAP] Nút Điều hướng chưa mở Map -> Bồi thêm 1 chạm tại (%.0f, %.0f)!", recPt.x, recPt.y);
                                            notify_post(kNotifyStatsUpdated);
                                        }
                                    }
                                }
                                usleep(1150000);
                            }
                            continue;
                        } else {
                            // Màn hình đang chuyển cảnh chưa ổn định -> Xóa baseline & giữ Turbo để 150ms sau quét bấm lại ngay (không cần người dùng vuốt màn)!
                            [engine invalidateAnalyzedBaseline];
                            turboUntilEpoch = [[NSDate date] timeIntervalSince1970] + 5.0;
                        }
                    }
                }

                // Turbo 180ms right after switching into Xanh SM or seeing an order card / transition; normal scanIntervalMs otherwise
                NSInteger sleepMs = (now < turboUntilEpoch || now < postTransitionUntilEpoch || engine.lastFrameLikelyHasOrderPopup)
                    ? MIN(180, MAX(140, config.scanIntervalMs))
                    : MAX(150, config.scanIntervalMs);
                usleep((useconds_t)(sleepMs * 1000));
                } @catch (NSException *ex) {
                    appendDaemonLog(@"[TỰ PHỤC HỒI] Bắt ngoại lệ %@ -> Tự làm mới và tiếp tục canh đơn!", ex.name ?: @"ObjC");
                    resetFrontmostAppMonitors();
                    [engine invalidateAnalyzedBaseline];
                    usleep(250000);
                }
            }
        }

        unlinkPidFileIfOwnedByMe(kDaemonPidPath);
        notify_cancel(reloadTok);
        notify_cancel(stopTok);
        notify_cancel(skipTok);
        notify_cancel(resetNavTok);
        notify_cancel(resetCntTok);
        notify_cancel(diagTok);
    }
    return 0;
}

int main(int argc, char *argv[]) {
    if (argc >= 2 && strcmp(argv[1], "--daemonize") == 0) {
        return runDaemonizeMain(argv[0]);
    }
    if (argc >= 2 && strcmp(argv[1], "--stop") == 0) {
        return runStopMain();
    }
    if (argc >= 3 && strcmp(argv[1], "--kill-pid") == 0) {
        return runKillPidMain((pid_t)atoi(argv[2]));
    }
    if (argc >= 2 && strcmp(argv[1], "--worker") == 0) {
        return runWorkerMain();
    }
    return runWatchdogMain(argv[0]);
}
