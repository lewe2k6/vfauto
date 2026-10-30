#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <notify.h>
#import <signal.h>
#import <spawn.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <unistd.h>
#import <math.h>
#import <string.h>
#import "SharedConfig.h"
#import "ScreenTouchEngine.h"
#import "OrderScanner.h"

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

#define kExitCodeProactiveRAMTrim        42

static void applyCriticalJetsamToPid(pid_t targetPid, int32_t limitMB) {
    memorystatus_control_f fnMemCtl = (memorystatus_control_f)dlsym(RTLD_DEFAULT, "memorystatus_control");
    if (fnMemCtl) {
        jetsam_priority_props_t props = { JETSAM_PRIO_CRITICAL, 0 };
        fnMemCtl(MEMSTAT_CMD_SET_PRIORITY_PROPS,  targetPid, 0, &props, sizeof(props));
        fnMemCtl(MEMSTAT_CMD_SET_HIGH_WATER_MARK, targetPid, (uint32_t)-1, NULL, 0);
        fnMemCtl(MEMSTAT_CMD_SET_TASK_LIMIT,      targetPid, (uint32_t)limitMB, NULL, 0);
        fnMemCtl(MEMSTAT_CMD_SET_IS_MANAGED,      targetPid, 0, NULL, 0);
        fnMemCtl(MEMSTAT_CMD_SET_IS_FREEZABLE,    targetPid, 0, NULL, 0);
    }
}

static void ensureSharedFilesPermissions(void) {
    NSArray<NSString *> *paths = @[
        kConfigPlistPath,
        kRuntimeStatePath,
        kDaemonLogPath,
        kDaemonPidPath,
        kWatchdogPidPath
    ];
    for (NSString *p in paths) {
        chown([p fileSystemRepresentation], 501, 501);
        chmod([p fileSystemRepresentation], 0666);
    }
}

#pragma mark - Watchdog Supervisor (~0.8 MB RAM, Zero Vision/GPU Footprint)

static volatile BOOL gWatchdogExit = NO;

static void handleWatchdogSignal(int sig) {
    gWatchdogExit = YES;
}

static int runWatchdogMain(const char *execPath) {
    pid_t me = getpid();

    @autoreleasepool {
        // Terminate any previous watchdog or worker instance cleanly while uid=0
        pid_t oldWd = getRunningWatchdogPID();
        if (oldWd > 1 && oldWd != me) {
            kill(oldWd, SIGTERM);
            usleep(100000);
            if (kill(oldWd, 0) == 0) kill(oldWd, SIGKILL);
        }
        pid_t oldWk = getRunningDaemonPID();
        if (oldWk > 1 && oldWk != me) {
            kill(oldWk, SIGTERM);
            usleep(100000);
            if (kill(oldWk, 0) == 0) kill(oldWk, SIGKILL);
        }

        applyCriticalJetsamToPid(me, 64);
        ensureSharedFilesPermissions();

        signal(SIGHUP, SIG_IGN);
        signal(SIGTERM, handleWatchdogSignal);
        signal(SIGINT, handleWatchdogSignal);
        setsid();

        NSString *wdPidStr = [NSString stringWithFormat:@"%d", me];
        [wdPidStr writeToFile:kWatchdogPidPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        chown([kWatchdogPidPath fileSystemRepresentation], 501, 501);
        chmod([kWatchdogPidPath fileSystemRepresentation], 0666);

        dispatch_queue_t wdQ = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
        int stopTok = 0;
        notify_register_dispatch(kNotifyStopDaemon, &stopTok, wdQ, ^(int t) {
            gWatchdogExit = YES;
        });

        while (!gWatchdogExit) {
            @autoreleasepool {
                FilterConfig *cfg = [FilterConfig loadFromDisk];
                if (!cfg.masterEnabled) {
                    break;
                }

                char *childArgv[3];
                childArgv[0] = (char *)execPath;
                childArgv[1] = "--worker";
                childArgv[2] = NULL;

                pid_t workerPid = 0;
                int spRet = posix_spawn(&workerPid, execPath, NULL, NULL, childArgv, environ);
                if (spRet != 0 || workerPid <= 0) {
                    usleep(1000000);
                    continue;
                }

                applyCriticalJetsamToPid(workerPid, 512);

                int status = 0;
                int tickCount = 0;
                BOOL workerAlive = YES;

                while (workerAlive && !gWatchdogExit) {
                    pid_t w = waitpid(workerPid, &status, WNOHANG);
                    if (w == workerPid || (w == -1)) {
                        workerAlive = NO;
                        break;
                    }

                    tickCount++;
                    if (tickCount % 20 == 0) { // Every ~5s check heartbeat & master switch
                        @autoreleasepool {
                            FilterConfig *chkCfg = [FilterConfig loadFromDisk];
                            if (!chkCfg.masterEnabled) {
                                gWatchdogExit = YES;
                                break;
                            }
                            RuntimeDaemonState *st = [RuntimeDaemonState loadState];
                            double now = [[NSDate date] timeIntervalSince1970];
                            if (st.workerHeartbeatEpoch > 0.0 && (now - st.workerHeartbeatEpoch) > 50.0) {
                                appendDaemonLog(@"[WATCHDOG] Worker phản hồi chậm >50s -> Làm mới tiến trình ngay!");
                                kill(workerPid, SIGKILL);
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
                    break;
                }

                // Worker exited while masterEnabled is still ON -> Auto-revive!
                BOOL wasCleanRAMTrim = (WIFEXITED(status) && WEXITSTATUS(status) == kExitCodeProactiveRAMTrim);
                if (wasCleanRAMTrim) {
                    usleep(100000);
                } else {
                    FilterConfig *chkCfg = [FilterConfig loadFromDisk];
                    if (!chkCfg.masterEnabled) break;
                    appendDaemonLog(@"[WATCHDOG] iOS thiếu RAM đóng Worker -> Đã tự hồi sinh Worker mới trong 0.15s!");
                    notify_post(kNotifyStatsUpdated);
                    usleep(150000);
                }
            }
        }

        notify_cancel(stopTok);
        unlink([kWatchdogPidPath fileSystemRepresentation]);
        unlink([kDaemonPidPath fileSystemRepresentation]);
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
    applyCriticalJetsamToPid(me, 512);
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

    if (config.driverAppBundleID.length > 0 && [frontBid isEqualToString:config.driverAppBundleID]) {
        return YES;
    }

    NSString *lower = frontBid.lowercaseString;
    if ([lower containsString:@"gsm"] ||
        [lower containsString:@"xanhsm"] ||
        [lower containsString:@"greensm"] ||
        [lower containsString:@"vinfast"]) {
        return YES;
    }

    // Allow Apple Photos when Dry-Run is active so user can test screenshots freely
    if (config.dryRunMode && [frontBid isEqualToString:@"com.apple.mobileslideshow"]) {
        return YES;
    }

    return NO;
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
                                               config:config
                                      priceRetryCount:0];

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
    } else if (ana.isLobbyOnline) {
        matched = @"SẢNH ĐANG TRỰC TUYẾN -> Nút tắt [Power] tại (40, 455)";
    } else if (ana.isLobbyOffline) {
        matched = [NSString stringWithFormat:@"SẢNH OFFLINE -> Nút [Mở nhận chuyến] tại (%.0f, %.0f)",
                   ana.onlineStartPoint.x, ana.onlineStartPoint.y];
    }

    triggerHapticFeedback(YES);
    appendDaemonLog(@"[TEST OK] Đọc %ld cụm chữ (Tiêu đề: '%@'): [%@]",
                    (long)ana.ocrBlockCount,
                    ana.detectedServiceTitle ?: @"",
                    ana.ocrSampleSummary ?: @"");
    appendDaemonLog(@"[KẾT QUẢ NHẬN DIỆN] %@", matched);
    notify_post(kNotifyStatsUpdated);
}

static void runOfflinePauseAndRestartCycle(FilterConfig **ioConfig,
                                           RuntimeDaemonState *state,
                                           ScreenTouchEngine *engine,
                                           OrderScanner *scanner,
                                           BOOL resumingExistingPause) {
    FilterConfig *config = *ioConfig;
    gSkipPauseRequested = NO;

    BOOL didKillApp     = NO;
    BOOL didRelaunchApp = NO;

    if (!resumingExistingPause) {
        state.phaseDescription = @"Đang bấm [Power] Tắt nhận chuyến...";
        state.workerHeartbeatEpoch = [[NSDate date] timeIntervalSince1970];
        [state saveStateAndNotify:YES];

        usleep(1400000);

        BOOL confirmedOffline = NO;
        for (int attempt = 0; attempt < 12 && !gShouldExit && !gSkipPauseRequested; attempt++) {
            @autoreleasepool {
                state.workerHeartbeatEpoch = [[NSDate date] timeIntervalSince1970];
                [state saveStateAndNotify:NO];

                CIImage *img = [engine captureScreenCIImage];
                ScreenAnalysis *ana = [scanner analyzeScreenImage:img screenSize:engine.logicalScreenSize config:config priceRetryCount:0];

                if (ana.isLobbyOffline) {
                    confirmedOffline = YES;
                    break;
                }

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
                        usleep(1500000);
                        continue;
                    }
                }

                if (ana.isLobbyOnline || attempt >= 2) {
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
                        usleep(1700000);
                        continue;
                    }
                }

                usleep(600000);
            }
        }

        if (gShouldExit) return;

        NSInteger pauseSec = MAX(20, config.pauseDurationSec);
        double nowEpoch = [[NSDate date] timeIntervalSince1970];
        state.pauseEndEpoch        = nowEpoch + (double)pauseSec;
        state.workerHeartbeatEpoch = nowEpoch;
        state.phaseDescription     = [NSString stringWithFormat:@"Đang nghỉ xả Food (%lds)...", (long)pauseSec];
        [state saveStateAndNotify:YES];

        appendDaemonLog(@"%@ Bắt đầu nghỉ %ld giây trước khi bật lại nhận chuyến.",
                        confirmedOffline ? @"Đã Offline thành công!" : @"Chuyển pha nghỉ:", (long)pauseSec);

        if (config.autoKillAndRelaunchApp && !config.dryRunMode) {
            usleep(1500000);
            BOOL killed = killAppByBundleIDAndExec(config.driverAppBundleID, config.driverAppExecName);
            didKillApp = YES;
            appendDaemonLog(@"%@ tiến trình App Tài xế để xả RAM & làm mới phiên.",
                            killed ? @"Đã tự động Kill" : @"Đã gửi lệnh đóng");
        }
    } else {
        didKillApp = config.autoKillAndRelaunchApp;
        appendDaemonLog(@"[WATCHDOG] Tiếp tục đếm ngược chu kỳ nghỉ xả Food đang chạy dở...");
    }

    double lastHbSave = 0.0;
    while (!gShouldExit && !gSkipPauseRequested) {
        @autoreleasepool {
            if (gNeedsReload) {
                *ioConfig = [FilterConfig loadFromDisk];
                config = *ioConfig;
                gNeedsReload = NO;
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

            if (config.autoKillAndRelaunchApp && didKillApp && !didRelaunchApp && !config.dryRunMode) {
                if (rem <= (double)MAX(8, config.relaunchLeadSec)) {
                    if (config.hapticEnabled) triggerHapticFeedback(NO);
                    BOOL launched = launchAppByBundleID(config.driverAppBundleID);
                    didRelaunchApp = YES;
                    state.phaseDescription = @"Đang mở lại App Tài xế chờ khóa GPS...";
                    state.workerHeartbeatEpoch = cur;
                    [state saveStateAndNotify:YES];
                    appendDaemonLog(@"Còn %.0fs -> %@ App Tài xế chờ load bản đồ!",
                                    rem, launched ? @"Đã tự mở lại" : @"Đã gọi mở lại");
                }
            }

            usleep(500000);
        }
    }

    state.pauseEndEpoch = 0.0;
    state.workerHeartbeatEpoch = [[NSDate date] timeIntervalSince1970];
    if (gShouldExit) {
        [state saveStateAndNotify:YES];
        return;
    }

    if (gSkipPauseRequested) {
        appendDaemonLog(@"Nhận lệnh bỏ qua đếm ngược -> Bật lại nhận chuyến ngay!");
        gSkipPauseRequested = NO;
    }

    if (config.autoKillAndRelaunchApp && didKillApp && !didRelaunchApp && !config.dryRunMode) {
        launchAppByBundleID(config.driverAppBundleID);
        usleep(2500000);
    }

    state.phaseDescription = @"Đang bấm [Mở nhận chuyến]...";
    [state saveStateAndNotify:YES];

    BOOL backOnline = NO;
    for (int waitIdx = 0; waitIdx < 28 && !gShouldExit; waitIdx++) {
        @autoreleasepool {
            state.workerHeartbeatEpoch = [[NSDate date] timeIntervalSince1970];
            [state saveStateAndNotify:NO];

            CIImage *img = [engine captureScreenCIImage];
            ScreenAnalysis *ana = [scanner analyzeScreenImage:img screenSize:engine.logicalScreenSize config:config priceRetryCount:0];

            if (ana.isLobbyOnline) {
                backOnline = YES;
                break;
            }

            if (ana.isLobbyOffline) {
                uint32_t dMs = 260 + arc4random_uniform(300);
                usleep(dMs * 1000);

                if (config.dryRunMode) {
                    appendDaemonLog(@"[THỬ] Hết nghỉ -> Sẽ bấm [Mở nhận chuyến] tại (%.0f, %.0f)",
                                    ana.onlineStartPoint.x, ana.onlineStartPoint.y);
                } else {
                    CGPoint pt = CGPointZero;
                    [engine performHumanTapAtPoint:ana.onlineStartPoint
                                      jitterRadius:config.jitterRadiusPt
                                         holdMinMs:config.holdMinMs
                                         holdMaxMs:config.holdMaxMs
                                    outActualPoint:&pt];
                    appendDaemonLog(@"Hết giờ nghỉ -> Đã bấm [Mở nhận chuyến] tại (%.0f, %.0f)!", pt.x, pt.y);
                }

                if (config.hapticEnabled) triggerHapticFeedback(YES);
                usleep(2000000);
                backOnline = YES;
                break;
            }

            usleep(900000);
        }
    }

    if (!backOnline && !gShouldExit) {
        appendDaemonLog(@"[CHÚ Ý] Quá 25s chưa thấy chữ 'Mở nhận chuyến' trên màn hình.");
    }

    [engine invalidateAnalyzedBaseline];
    state.phaseDescription = @"Đang trực tuyến / Canh đơn";
    state.workerHeartbeatEpoch = [[NSDate date] timeIntervalSince1970];
    [state saveStateAndNotify:YES];
}

static int runWorkerMain(void) {
    prepareWorkerSession();

    @autoreleasepool {
        signal(SIGHUP, SIG_IGN);
        signal(SIGTERM, handleWorkerSignal);
        signal(SIGINT, handleWorkerSignal);

        NSString *myPidStr = [NSString stringWithFormat:@"%d", getpid()];
        [myPidStr writeToFile:kDaemonPidPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        chmod([kDaemonPidPath fileSystemRepresentation], 0666);

        dispatch_queue_t bgQ = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
        int reloadTok = 0, stopTok = 0, skipTok = 0, resetNavTok = 0, resetCntTok = 0, diagTok = 0;

        notify_register_dispatch(kNotifyReloadConfig,  &reloadTok,   bgQ, ^(int t) { gNeedsReload = YES; });
        notify_register_dispatch(kNotifyStopDaemon,    &stopTok,     bgQ, ^(int t) { gShouldExit = YES; });
        notify_register_dispatch(kNotifySkipPause,     &skipTok,     bgQ, ^(int t) { gSkipPauseRequested = YES; });
        notify_register_dispatch(kNotifyResetNavLocks, &resetNavTok, bgQ, ^(int t) { gResetNavRequested = YES; });
        notify_register_dispatch(kNotifyResetCounters, &resetCntTok, bgQ, ^(int t) { gResetCntRequested = YES; });
        notify_register_dispatch(kNotifyDiagCapture,   &diagTok,     bgQ, ^(int t) { gDiagRequested = YES; });

        FilterConfig *config      = [FilterConfig loadFromDisk];
        RuntimeDaemonState *state = [RuntimeDaemonState loadState];
        double bootEpoch          = [[NSDate date] timeIntervalSince1970];
        BOOL hadPreviousVersion   = [state.daemonVersion isEqualToString:kCurrentDaemonVersion];

        state.daemonVersion        = kCurrentDaemonVersion;
        state.workerHeartbeatEpoch = bootEpoch;
        if (state.pauseEndEpoch <= bootEpoch + 2.0) {
            state.pauseEndEpoch    = 0.0;
            state.phaseDescription = @"Đang trực tuyến / Canh đơn";
        }
        [state saveStateAndNotify:YES];
        gNeedsReload = NO;

        ScreenTouchEngine *engine = [ScreenTouchEngine sharedEngine];
        OrderScanner *scanner     = [OrderScanner sharedScanner];

        if (!hadPreviousVersion) {
            CIImage *probeImg = [engine captureScreenCIImage];
            BOOL screenOk = (probeImg != nil && engine.lastCaptureHadPixels);
            appendDaemonLog(@"pind v4.1 Bất Tử + Siêu Mát chạy (WD:%d WK:%d, Quét:%@). Food >= %ldđ",
                            getRunningWatchdogPID(), getpid(),
                            screenOk ? @"OK" : @"LỖI",
                            (long)config.minFoodPriceVND);
            notify_post(kNotifyStatsUpdated);
        }

        // Seamlessly finish an in-progress Food Pause if revived mid-countdown
        if (state.pauseEndEpoch > bootEpoch + 2.0 && config.masterEnabled) {
            runOfflinePauseAndRestartCycle(&config, state, engine, scanner, YES);
        }

        NSInteger retryCount                = 0;
        BOOL didSwipeBannerForCurrentPopup  = NO;
        NSString *lastSkippedPopupSignature = nil;
        BOOL wasInCoolSleep                 = NO;
        double turboUntilEpoch              = bootEpoch + 4.0;
        double lastFullOCREpoch             = 0.0;
        double lastHeartbeatSaveEpoch       = bootEpoch;

        while (!gShouldExit) {
            @autoreleasepool {
                double now = [[NSDate date] timeIntervalSince1970];

                if (now - lastHeartbeatSaveEpoch >= 4.0) {
                    state.workerHeartbeatEpoch = now;
                    [state saveStateAndNotify:NO];
                    lastHeartbeatSaveEpoch = now;
                }

                if (gNeedsReload) {
                    config = [FilterConfig loadFromDisk];
                    gNeedsReload = NO;
                    [engine invalidateAnalyzedBaseline];
                }
                if (gResetNavRequested) {
                    gResetNavRequested = NO;
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
                    usleep(450000);
                    continue;
                }

                // --- TẦNG HẠ NHIỆT 1: SMART-SLEEP KHI MÀN HÌNH KHÓA HOẶC ĐANG MỞ GOOGLE MAPS ---
                if (config.smartCoolMode) {
                    BOOL screenLocked = isDeviceScreenLocked();
                    NSString *frontBid = screenLocked ? nil : currentFrontmostAppBundleIDForConfig(config);
                    BOOL canScan = (!screenLocked && isFrontmostAppAllowedForScan(frontBid, config));

                    if (!canScan) {
                        if (!wasInCoolSleep) {
                            wasInCoolSleep = YES;
                            retryCount = 0;
                            didSwipeBannerForCurrentPopup = NO;
                            [engine invalidateAnalyzedBaseline];
                            state.phaseDescription = screenLocked
                                ? @"Ngủ mát 0% Nhiệt (Đang khóa màn hình)"
                                : [NSString stringWithFormat:@"Ngủ mát 0%% Nhiệt (Đang mở %@)",
                                   [frontBid isEqualToString:@"com.google.Maps"] ? @"Google Maps" : @"app ngoài"];
                            state.workerHeartbeatEpoch = now;
                            [state saveStateAndNotify:YES];
                        }

                        // Proactive memory recycle while safely sleeping outside Xanh SM (> 85 MB dirty footprint)
                        if ((now - bootEpoch) > 60.0 && currentProcessFootprintMB() > 85) {
                            state.workerHeartbeatEpoch = now;
                            [state saveStateAndNotify:NO];
                            _exit(kExitCodeProactiveRAMTrim);
                        }

                        usleep(500000);
                        continue;
                    } else if (wasInCoolSleep) {
                        // Just switched from Google Maps / outside app back into Xanh SM -> Instant 6.5s Turbo!
                        wasInCoolSleep = NO;
                        turboUntilEpoch = now + 6.5;
                        [engine invalidateAnalyzedBaseline];
                        state.phaseDescription = @"Đang trực tuyến / Canh đơn (Turbo)";
                        state.workerHeartbeatEpoch = now;
                        [state saveStateAndNotify:YES];
                    }
                } else if (wasInCoolSleep) {
                    wasInCoolSleep = NO;
                    state.phaseDescription = @"Đang trực tuyến / Canh đơn";
                    [state saveStateAndNotify:YES];
                }

                // --- CHỤP KHUNG HÌNH & TẦNG HẠ NHIỆT 2: CẢM BIẾN PIXEL 0.02ms CHỐNG ĐỌC LẶP ---
                CIImage *screenImg = [engine captureScreenCIImage];
                if (!screenImg) {
                    usleep((useconds_t)(MAX(200, config.scanIntervalMs) * 1000));
                    continue;
                }

                BOOL inTurbo = (now < turboUntilEpoch) ||
                               engine.lastFrameLikelyHasOrderPopup ||
                               (retryCount > 0);

                if (config.smartCoolMode &&
                    !inTurbo &&
                    engine.lastFrameChangedSamples <= 3 &&
                    (now - lastFullOCREpoch) < 2.2) {
                    // Static screen inside Xanh SM with no order popup -> skip heavy Vision ANE OCR!
                    if ((now - bootEpoch) > 90.0 && currentProcessFootprintMB() > 90) {
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
                                                           config:config
                                                  priceRetryCount:retryCount];

                // 1. KIỂM TRA 3 ĐIỀU KIỆN MỞ KHÓA CHỐT ĐIỀU HƯỚNG (GIỮ NGUYÊN CHỐT KHI NỐI CHUYẾN)
                if (ana.isPaymentConfirmScreen) {
                    resetBothNavLocks(state, @"Thấy màn 'Xác nhận hoàn thành' -> Xóa sạch 2 chốt Điều hướng!");
                } else if (ana.isLobbyOnline || ana.isLobbyOffline) {
                    resetBothNavLocks(state, @"Về màn hình sảnh chờ -> Xóa sạch 2 chốt Điều hướng!");
                } else if (ana.hasPassengerAndNav && ana.isPickupStage && state.navDropoffLocked) {
                    resetBothNavLocks(state, @"Phát hiện cuốc nối chuyến mới -> Xóa chốt cũ đón khách mới!");
                }

                // 2. XỬ LÝ BẢNG NỔ ĐƠN ('Bike' / 'Express' / 'Express 2H' vs 'Green Food')
                if (ana.hasOrderPopup) {
                    turboUntilEpoch = now + 4.0;

                    if (ana.orderAction == OrderActionHeaderCovered) {
                        retryCount++;
                        if (!config.dryRunMode && !didSwipeBannerForCurrentPopup && retryCount >= 2) {
                            CGFloat midX = engine.logicalScreenSize.width * 0.5;
                            [engine performQuickSwipeFromPoint:CGPointMake(midX, 62.0)
                                                       toPoint:CGPointMake(midX, 6.0)
                                                    durationMs:55];
                            didSwipeBannerForCurrentPopup = YES;
                            appendDaemonLog(@"[CHỐNG CHE] Vuốt hất banner thông báo đỉnh màn hình để đọc rõ tên đơn...");
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
                            usleep(95000);
                            spentVerifyMs = 95;
                            if (gShouldExit) break;

                            CIImage *verifyImg = [engine captureScreenCIImage];
                            if (verifyImg) {
                                [engine markCurrentFrameAnalyzed];
                                ScreenAnalysis *verifyAna = [scanner analyzeScreenImage:verifyImg
                                                                             screenSize:engine.logicalScreenSize
                                                                                 config:config
                                                                        priceRetryCount:retryCount + 1];
                                if (!verifyAna.hasOrderPopup) {
                                    retryCount = 0;
                                    didSwipeBannerForCurrentPopup = NO;
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
                        }

                        retryCount = 0;
                        didSwipeBannerForCurrentPopup = NO;
                        lastSkippedPopupSignature = nil;

                        if (ana.orderAction != OrderActionTapAccept && ana.orderAction != OrderActionTapRejectX) {
                            continue;
                        }

                        BOOL isAccept = (ana.orderAction == OrderActionTapAccept);
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
                            // BẤM VÒNG KÍN CÓ KIỂM CHỨNG & BỒI CHỐNG TRƯỢT CẢM ỨNG (CLOSED-LOOP TAP RETRY)
                            NSInteger maxRetries = config.tapVerifyRetries;
                            CGPoint targetPt     = ana.orderTargetPoint;
                            CGPoint actualPt     = targetPt;
                            NSInteger tapsSent   = 0;
                            BOOL confirmedGone   = NO;

                            for (NSInteger attempt = 0; attempt <= maxRetries && !gShouldExit; attempt++) {
                                if (attempt > 0 && !isAccept) {
                                    // Nếu phát đầu bấm [X] Food chưa tắt (có thể vướng banner góc trên), hất banner lên trước khi bồi
                                    CGFloat midX = engine.logicalScreenSize.width * 0.5;
                                    [engine performQuickSwipeFromPoint:CGPointMake(midX, 62.0)
                                                               toPoint:CGPointMake(midX, 6.0)
                                                            durationMs:50];
                                    usleep(120000);
                                }

                                BOOL tapOk = [engine performHumanTapAtPoint:targetPt
                                                               jitterRadius:config.jitterRadiusPt
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

                                // Chờ 380ms rồi chụp kiểm tra xem bảng đơn đã biến mất thật chưa
                                usleep(380000);
                                if (gShouldExit) break;

                                CIImage *chkImg = [engine captureScreenCIImage];
                                if (!chkImg) {
                                    confirmedGone = YES;
                                    break;
                                }
                                [engine markCurrentFrameAnalyzed];
                                ScreenAnalysis *chkAna = [scanner analyzeScreenImage:chkImg
                                                                          screenSize:engine.logicalScreenSize
                                                                              config:config
                                                                     priceRetryCount:2];
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

                                if (!chkAna.hasOrderPopup) {
                                    confirmedGone = YES;
                                    break;
                                }

                                // Bảng đơn vẫn còn trên màn hình -> cập nhật tọa độ nút mới nhất để bồi ngay!
                                if ((isAccept && chkAna.orderAction == OrderActionTapAccept) ||
                                    (!isAccept && chkAna.orderAction == OrderActionTapRejectX)) {
                                    targetPt = chkAna.orderTargetPoint;
                                }
                            }

                            if (tapsSent > 0) {
                                if (isAccept) {
                                    state.statAcceptedCount += 1;
                                    state.phaseDescription = @"Vừa nhận chuyến mới";
                                } else {
                                    state.statRejectedCount += 1;
                                }
                                state.workerHeartbeatEpoch = [[NSDate date] timeIntervalSince1970];
                                [state saveStateAndNotify:YES];

                                NSString *tapNote = (tapsSent == 1)
                                    ? @"Ăn ngay phát 1"
                                    : [NSString stringWithFormat:@"Bồi %ld phát%@", (long)tapsSent, confirmedGone ? @" ăn chắc" : @""];
                                appendDaemonLog(@"%@ | Chạm (%.0f, %.0f) [%@]",
                                                ana.orderReason, actualPt.x, actualPt.y, tapNote);
                                if (config.hapticEnabled) triggerHapticFeedback(isAccept);
                                notify_post(kNotifyStatsUpdated);
                            }
                        }

                        [engine invalidateAnalyzedBaseline];

                        if (!isAccept && ana.isGreenFood && config.pauseAfterRejectFood) {
                            runOfflinePauseAndRestartCycle(&config, state, engine, scanner, NO);
                            continue;
                        }

                        NSInteger cdMs = MAX(600, config.cooldownMs - 380);
                        usleep((useconds_t)(cdMs * 1000));
                        continue;
                    }
                } else {
                    retryCount = 0;
                    didSwipeBannerForCurrentPopup = NO;
                    lastSkippedPopupSignature = nil;
                }

                // 3. XỬ LÝ AUTO TAP NÚT TRÒN XANH 'ĐIỀU HƯỚNG' (CHỐNG LẶP 100%)
                if (ana.hasPassengerAndNav) {
                    BOOL needPickupTap  = (ana.isPickupStage  && config.autoNavPickup  && !state.navPickupLocked);
                    BOOL needDropoffTap = (ana.isDropoffStage && config.autoNavDropoff && !state.navDropoffLocked);

                    if (needPickupTap || needDropoffTap) {
                        NSInteger settleMs = MAX(200, config.navSettleDelayMs);
                        usleep((useconds_t)(settleMs * 1000));
                        if (gShouldExit) break;

                        CIImage *settledImg = [engine captureScreenCIImage];
                        [engine markCurrentFrameAnalyzed];
                        ScreenAnalysis *settledAna = [scanner analyzeScreenImage:settledImg
                                                                      screenSize:engine.logicalScreenSize
                                                                          config:config
                                                                 priceRetryCount:0];

                        BOOL stillValid = settledAna.hasPassengerAndNav &&
                                          ((needPickupTap && settledAna.isPickupStage) ||
                                           (needDropoffTap && settledAna.isDropoffStage));

                        if (stillValid) {
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
                            }

                            if (config.hapticEnabled) triggerHapticFeedback(NO);
                            notify_post(kNotifyStatsUpdated);
                            usleep(2000000);
                            continue;
                        }
                    }
                }

                // Turbo 180ms right after switching into Xanh SM or seeing an order card; normal scanIntervalMs otherwise
                NSInteger sleepMs = (now < turboUntilEpoch || engine.lastFrameLikelyHasOrderPopup)
                    ? MIN(180, MAX(140, config.scanIntervalMs))
                    : MAX(150, config.scanIntervalMs);
                usleep((useconds_t)(sleepMs * 1000));
            }
        }

        unlink([kDaemonPidPath fileSystemRepresentation]);
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
    if (argc >= 2 && strcmp(argv[1], "--worker") == 0) {
        return runWorkerMain();
    }
    return runWatchdogMain(argv[0]);
}
