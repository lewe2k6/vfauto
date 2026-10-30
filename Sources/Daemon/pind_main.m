#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <notify.h>
#import <signal.h>
#import <sys/stat.h>
#import <unistd.h>
#import <math.h>
#import "SharedConfig.h"
#import "ScreenTouchEngine.h"
#import "OrderScanner.h"

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

static void liftJetsamAndAlignSession(void) {
    pid_t me = getpid();

    // Terminate any previous root/mobile pind instance while we still hold uid 0
    @autoreleasepool {
        pid_t oldPid = getRunningDaemonPID();
        if (oldPid > 1 && oldPid != me) {
            kill(oldPid, SIGTERM);
            usleep(120000);
            if (kill(oldPid, 0) == 0) {
                kill(oldPid, SIGKILL);
                usleep(60000);
            }
        }
    }

    memorystatus_control_f fnMemCtl = (memorystatus_control_f)dlsym(RTLD_DEFAULT, "memorystatus_control");
    if (fnMemCtl) {
        jetsam_priority_props_t props = { JETSAM_PRIO_CRITICAL, 0 };
        fnMemCtl(MEMSTAT_CMD_SET_PRIORITY_PROPS,  me, 0, &props, sizeof(props));
        fnMemCtl(MEMSTAT_CMD_SET_HIGH_WATER_MARK, me, (uint32_t)-1, NULL, 0);
        fnMemCtl(MEMSTAT_CMD_SET_TASK_LIMIT,      me, 512, NULL, 0);
        fnMemCtl(MEMSTAT_CMD_SET_IS_MANAGED,      me, 0, NULL, 0);
        fnMemCtl(MEMSTAT_CMD_SET_IS_FREEZABLE,    me, 0, NULL, 0);
    }

    // Ensure all shared files in /var/mobile/Library/Preferences belong to mobile (501:501)
    NSArray<NSString *> *paths = @[kConfigPlistPath, kRuntimeStatePath, kDaemonLogPath, kDaemonPidPath];
    for (NSString *p in paths) {
        chown([p fileSystemRepresentation], 501, 501);
        chmod([p fileSystemRepresentation], 0666);
    }

    // Align daemon UID/GID with mobile (501) user session just like TrollVNC so
    // CARenderServer, Vision ANE, AudioServices haptics, and LSApplicationWorkspace connect cleanly
    if (getgid() != 501) {
        setgid(501);
    }
    if (getuid() != 501) {
        setuid(501);
    }
}

static volatile BOOL gShouldExit         = NO;
static volatile BOOL gNeedsReload        = YES;
static volatile BOOL gSkipPauseRequested = NO;
static volatile BOOL gResetNavRequested  = NO;
static volatile BOOL gResetCntRequested  = NO;
static volatile BOOL gDiagRequested      = NO;

static void handleSignal(int sig) {
    gShouldExit = YES;
}

static void resetBothNavLocks(RuntimeDaemonState *state, NSString *reasonLog) {
    if (state.navPickupLocked || state.navDropoffLocked) {
        state.navPickupLocked  = NO;
        state.navDropoffLocked = NO;
        state.phaseDescription = @"Đang rảnh / Đã mở khóa chốt Map";
        [state saveStateAndNotify:YES];
        if (reasonLog.length > 0) {
            appendDaemonLog(@"%@", reasonLog);
        }
    }
}

static void runDiagnosticCapture4Sec(FilterConfig *config,
                                     ScreenTouchEngine *engine,
                                     OrderScanner *scanner) {
    appendDaemonLog(@"[TEST 4s] Bắt đầu đếm ngược 4 giây -> Hãy mở sang Ảnh chụp màn hình ngay!");
    notify_post(kNotifyStatsUpdated);

    for (int i = 0; i < 8 && !gShouldExit; i++) {
        usleep(500000);
    }
    if (gShouldExit) return;

    CIImage *img = [engine captureScreenCIImage];
    if (!img || !engine.lastCaptureHadPixels) {
        triggerHapticFeedback(NO);
        appendDaemonLog(@"[TEST LỖI] Khung hình trả về ĐEN/RỖNG! Hãy cài lại bản v3.2 qua TrollStore.");
        notify_post(kNotifyStatsUpdated);
        return;
    }

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
        matched = @"SẢNH ĐANG TRỰC TUYẾN -> Nút tắt [⏻] tại (40, 455)";
    } else if (ana.isLobbyOffline) {
        matched = [NSString stringWithFormat:@"SẢNH OFFLINE -> Nút [Mở nhận chuyến] tại (%.0f, %.0f)",
                   ana.onlineStartPoint.x, ana.onlineStartPoint.y];
    }

    triggerHapticFeedback(YES);
    appendDaemonLog(@"[TEST OK] Ảnh sáng nét! Đọc %ld cụm chữ: [%@]",
                    (long)ana.ocrBlockCount, ana.ocrSampleSummary ?: @"");
    appendDaemonLog(@"[KẾT QUẢ NHẬN DIỆN] %@", matched);
    notify_post(kNotifyStatsUpdated);
}

static void runOfflinePauseAndRestartCycle(FilterConfig **ioConfig,
                                           RuntimeDaemonState *state,
                                           ScreenTouchEngine *engine,
                                           OrderScanner *scanner) {
    FilterConfig *config = *ioConfig;
    gSkipPauseRequested = NO;

    state.phaseDescription = @"Đang bấm [⏻] Tắt nhận chuyến...";
    [state saveStateAndNotify:YES];

    usleep(1400000);

    BOOL confirmedOffline = NO;
    for (int attempt = 0; attempt < 12 && !gShouldExit && !gSkipPauseRequested; attempt++) {
        @autoreleasepool {
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
                    appendDaemonLog(@"[THỬ] Sẽ bấm nút [⏻] Tắt nhận chuyến tại (%.0f, %.0f)",
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
                    appendDaemonLog(@"Bấm nút tròn [⏻] Tắt nhận chuyến tại (%.0f, %.0f)", pt.x, pt.y);
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
    state.pauseEndEpoch    = nowEpoch + (double)pauseSec;
    state.phaseDescription = [NSString stringWithFormat:@"Đang nghỉ xả Food (%lds)...", (long)pauseSec];
    [state saveStateAndNotify:YES];

    appendDaemonLog(@"%@ Bắt đầu nghỉ %ld giây trước khi bật lại nhận chuyến.",
                    confirmedOffline ? @"Đã Offline thành công!" : @"Chuyển pha nghỉ:", (long)pauseSec);

    BOOL didKillApp     = NO;
    BOOL didRelaunchApp = NO;

    if (config.autoKillAndRelaunchApp && !config.dryRunMode) {
        usleep(1500000);
        BOOL killed = killAppByBundleIDAndExec(config.driverAppBundleID, config.driverAppExecName);
        didKillApp = YES;
        appendDaemonLog(@"%@ tiến trình App Tài xế để xả RAM & làm mới phiên.",
                        killed ? @"Đã tự động Kill" : @"Đã gửi lệnh đóng");
    }

    while (!gShouldExit && !gSkipPauseRequested) {
        @autoreleasepool {
            if (gNeedsReload) {
                *ioConfig = [FilterConfig loadFromDisk];
                config = *ioConfig;
                gNeedsReload = NO;
            }

            double cur = [[NSDate date] timeIntervalSince1970];
            double rem = state.pauseEndEpoch - cur;
            if (rem <= 0.0) break;

            if (config.autoKillAndRelaunchApp && didKillApp && !didRelaunchApp && !config.dryRunMode) {
                if (rem <= (double)MAX(8, config.relaunchLeadSec)) {
                    if (config.hapticEnabled) triggerHapticFeedback(NO);
                    BOOL launched = launchAppByBundleID(config.driverAppBundleID);
                    didRelaunchApp = YES;
                    state.phaseDescription = @"Đang mở lại App Tài xế chờ khóa GPS...";
                    [state saveStateAndNotify:YES];
                    appendDaemonLog(@"Còn %.0fs -> %@ App Tài xế chờ load bản đồ!",
                                    rem, launched ? @"Đã tự mở lại" : @"Đã gọi mở lại");
                }
            }

            usleep(500000);
        }
    }

    state.pauseEndEpoch = 0.0;
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

    state.phaseDescription = @"Đang trực tuyến / Canh đơn";
    [state saveStateAndNotify:YES];
}

int main(int argc, char *argv[]) {
    // 1. Lift 2GB RAM Jetsam limit while uid=0, then drop to mobile (501) session
    liftJetsamAndAlignSession();

    @autoreleasepool {
        signal(SIGHUP, SIG_IGN);
        signal(SIGTERM, handleSignal);
        signal(SIGINT, handleSignal);
        setsid();

        pid_t oldPid = getRunningDaemonPID();
        if (oldPid > 0 && oldPid != getpid()) {
            kill(oldPid, SIGTERM);
            usleep(120000);
        }

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

        FilterConfig *config = [FilterConfig loadFromDisk];
        RuntimeDaemonState *state = [RuntimeDaemonState loadState];
        state.pauseEndEpoch    = 0.0;
        state.daemonVersion    = kCurrentDaemonVersion;
        state.phaseDescription = @"Đang trực tuyến / Canh đơn";
        [state saveStateAndNotify:YES];
        gNeedsReload = NO;

        ScreenTouchEngine *engine = [ScreenTouchEngine sharedEngine];
        OrderScanner *scanner     = [OrderScanner sharedScanner];

        CIImage *probeImg = [engine captureScreenCIImage];
        BOOL screenOk = (probeImg != nil && engine.lastCaptureHadPixels);

        appendDaemonLog(@"pind v3.3 chạy (PID %d, UID %d, Màn %.0fx%.0f, Quét hình: %@). Giá Food >= %ldđ",
                        getpid(), getuid(), engine.logicalScreenSize.width, engine.logicalScreenSize.height,
                        screenOk ? @"OK" : @"LỖI ĐEN MÀN",
                        (long)config.minFoodPriceVND);
        notify_post(kNotifyStatsUpdated);

        NSInteger priceRetryCount = 0;

        while (!gShouldExit) {
            @autoreleasepool {
                if (gNeedsReload) {
                    config = [FilterConfig loadFromDisk];
                    gNeedsReload = NO;
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
                    runDiagnosticCapture4Sec(config, engine, scanner);
                    continue;
                }

                if (!config.masterEnabled) {
                    usleep(400000);
                    continue;
                }

                CIImage *screenImg = [engine captureScreenCIImage];
                if (!screenImg) {
                    usleep((useconds_t)(MAX(200, config.scanIntervalMs) * 1000));
                    continue;
                }

                ScreenAnalysis *ana = [scanner analyzeScreenImage:screenImg
                                                       screenSize:engine.logicalScreenSize
                                                           config:config
                                                  priceRetryCount:priceRetryCount];

                // 1. KIỂM TRA 3 ĐIỀU KIỆN MỞ KHÓA CHỐT ĐIỀU HƯỚNG (RESET VỀ FALSE)
                // (Tuyệt đối KHÔNG reset khi vừa bấm 'Nhận chuyến', tránh lỗi lặp Map khi đớp cuốc nối chuyến giữa đường)
                if (ana.isPaymentConfirmScreen) {
                    resetBothNavLocks(state, @"Thấy màn 'Xác nhận hoàn thành' -> Xóa sạch 2 chốt Điều hướng!");
                } else if (ana.isLobbyOnline || ana.isLobbyOffline) {
                    resetBothNavLocks(state, @"Về màn hình sảnh chờ -> Xóa sạch 2 chốt Điều hướng!");
                } else if (ana.hasPassengerAndNav && ana.isPickupStage && state.navDropoffLocked) {
                    resetBothNavLocks(state, @"Phát hiện cuốc nối chuyến mới -> Xóa chốt cũ đón khách mới!");
                }

                // 2. XỬ LÝ BẢNG NỔ ĐƠN MỚI ('Cước phí' + 'Nhận chuyến')
                if (ana.hasOrderPopup) {
                    if (ana.orderAction == OrderActionWaitRetryPrice) {
                        priceRetryCount++;
                        usleep(140000);
                        continue;
                    }
                    priceRetryCount = 0;

                    if (ana.orderAction == OrderActionTapAccept || ana.orderAction == OrderActionTapRejectX) {
                        BOOL isAccept = (ana.orderAction == OrderActionTapAccept);
                        NSInteger minD = isAccept ? config.acceptDelayMinMs : config.rejectDelayMinMs;
                        NSInteger maxD = isAccept ? config.acceptDelayMaxMs : config.rejectDelayMaxMs;
                        if (maxD < minD) maxD = minD + 20;

                        uint32_t delayMs = (uint32_t)(minD + arc4random_uniform((uint32_t)(maxD - minD + 1)));
                        usleep(delayMs * 1000);
                        if (gShouldExit) break;

                        if (config.dryRunMode) {
                            appendDaemonLog(@"[THỬ] %@ | Tâm (%.0f, %.0f) trễ %ums",
                                            ana.orderReason, ana.orderTargetPoint.x, ana.orderTargetPoint.y, delayMs);
                            if (config.hapticEnabled) triggerHapticFeedback(isAccept);
                            notify_post(kNotifyStatsUpdated);
                        } else {
                            CGPoint actualPt = ana.orderTargetPoint;
                            BOOL ok = [engine performHumanTapAtPoint:ana.orderTargetPoint
                                                        jitterRadius:config.jitterRadiusPt
                                                           holdMinMs:config.holdMinMs
                                                           holdMaxMs:config.holdMaxMs
                                                      outActualPoint:&actualPt];
                            if (ok) {
                                if (isAccept) {
                                    state.statAcceptedCount += 1;
                                    // Giữ nguyên navPickupLocked & navDropoffLocked để nếu là đơn nối chuyến
                                    // khi chưa xong cuốc hiện tại thì quay về màn cuốc cũ KHÔNG bị tap lại Map!
                                    state.phaseDescription = @"Vừa nhận chuyến mới";
                                } else {
                                    state.statRejectedCount += 1;
                                }
                                [state saveStateAndNotify:YES];

                                appendDaemonLog(@"%@ | Chạm (%.0f, %.0f) trễ %ums",
                                                ana.orderReason, actualPt.x, actualPt.y, delayMs);
                                if (config.hapticEnabled) triggerHapticFeedback(isAccept);
                                notify_post(kNotifyStatsUpdated);
                            }
                        }

                        if (!isAccept && ana.isGreenFood && config.pauseAfterRejectFood) {
                            runOfflinePauseAndRestartCycle(&config, state, engine, scanner);
                            continue;
                        }

                        NSInteger cdMs = MAX(800, config.cooldownMs);
                        usleep((useconds_t)(cdMs * 1000));
                        continue;
                    }
                } else {
                    priceRetryCount = 0;
                }

                // 3. XỬ LÝ AUTO TAP 2-3 LẦN NÚT TRÒN XANH 'ĐIỀU HƯỚNG' (CHỐNG LẶP 100%)
                if (ana.hasPassengerAndNav) {
                    BOOL needPickupTap  = (ana.isPickupStage  && config.autoNavPickup  && !state.navPickupLocked);
                    BOOL needDropoffTap = (ana.isDropoffStage && config.autoNavDropoff && !state.navDropoffLocked);

                    if (needPickupTap || needDropoffTap) {
                        NSInteger settleMs = MAX(200, config.navSettleDelayMs);
                        usleep((useconds_t)(settleMs * 1000));
                        if (gShouldExit) break;

                        CIImage *settledImg = [engine captureScreenCIImage];
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

                NSInteger sleepMs = MAX(150, config.scanIntervalMs);
                usleep((useconds_t)(sleepMs * 1000));
            }
        }

        appendDaemonLog(@"Lõi ngầm pind đã dừng.");
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
