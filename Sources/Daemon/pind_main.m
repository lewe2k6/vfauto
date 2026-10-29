#import <Foundation/Foundation.h>
#import <notify.h>
#import <signal.h>
#import <sys/stat.h>
#import <unistd.h>
#import "SharedConfig.h"
#import "ScreenTouchEngine.h"
#import "OrderScanner.h"

static volatile BOOL gShouldExit = NO;
static volatile BOOL gNeedsReload = YES;

static void handleSignal(int sig) {
    gShouldExit = YES;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // Ignore SIGHUP, handle SIGTERM/SIGINT cleanly
        signal(SIGHUP, SIG_IGN);
        signal(SIGTERM, handleSignal);
        signal(SIGINT, handleSignal);

        setsid();

        // Single-instance check
        pid_t oldPid = getRunningDaemonPID();
        if (oldPid > 0 && oldPid != getpid()) {
            kill(oldPid, SIGTERM);
            usleep(120000);
        }

        NSString *myPidStr = [NSString stringWithFormat:@"%d", getpid()];
        [myPidStr writeToFile:kDaemonPidPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        chmod([kDaemonPidPath fileSystemRepresentation], 0666);

        int reloadToken = 0;
        notify_register_dispatch(kNotifyReloadConfig, &reloadToken, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(int token) {
            gNeedsReload = YES;
        });

        int stopToken = 0;
        notify_register_dispatch(kNotifyStopDaemon, &stopToken, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(int token) {
            gShouldExit = YES;
        });

        FilterConfig *config = [FilterConfig loadFromDisk];
        gNeedsReload = NO;

        ScreenTouchEngine *engine = [ScreenTouchEngine sharedEngine];
        OrderScanner *scanner = [OrderScanner sharedScanner];

        appendDaemonLog(@"Lõi ngầm pind khởi động (PID %d, Màn %.0fx%.0f). Ngưỡng Food: %ldđ",
                        getpid(), engine.logicalScreenSize.width, engine.logicalScreenSize.height,
                        (long)config.minFoodPriceVND);

        NSInteger priceRetryCount = 0;

        while (!gShouldExit) {
            @autoreleasepool {
                if (gNeedsReload) {
                    config = [FilterConfig loadFromDisk];
                    gNeedsReload = NO;
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

                ScanDecision *dec = [scanner analyzeScreenImage:screenImg
                                                     screenSize:engine.logicalScreenSize
                                                         config:config
                                                priceRetryCount:priceRetryCount];

                if (dec.type == ScanDecisionWaitRetryPrice) {
                    priceRetryCount++;
                    usleep(150000); // Chờ 150ms đọc lại số tiền cho nét
                    continue;
                }

                priceRetryCount = 0;

                if (dec.type == ScanDecisionTapAccept || dec.type == ScanDecisionTapRejectX) {
                    BOOL isAccept = (dec.type == ScanDecisionTapAccept);
                    NSInteger minD = isAccept ? config.acceptDelayMinMs : config.rejectDelayMinMs;
                    NSInteger maxD = isAccept ? config.acceptDelayMaxMs : config.rejectDelayMaxMs;
                    if (maxD < minD) maxD = minD + 20;

                    uint32_t delayMs = (uint32_t)(minD + arc4random_uniform((uint32_t)(maxD - minD + 1)));
                    usleep(delayMs * 1000);

                    if (gShouldExit) break;

                    if (config.dryRunMode) {
                        appendDaemonLog(@"[THỬ] %@ | Tâm (%.0f, %.0f) | Trễ %ums",
                                        dec.reasonSummary,
                                        dec.targetLogicalPoint.x,
                                        dec.targetLogicalPoint.y,
                                        delayMs);
                        if (config.hapticEnabled) triggerHapticFeedback(isAccept);
                    } else {
                        CGPoint actualPt = dec.targetLogicalPoint;
                        BOOL ok = [engine performHumanTapAtPoint:dec.targetLogicalPoint
                                                    jitterRadius:config.jitterRadiusPt
                                                       holdMinMs:config.holdMinMs
                                                       holdMaxMs:config.holdMaxMs
                                                  outActualPoint:&actualPt];

                        if (ok) {
                            // Reload freshest config before incrementing stats to avoid overwriting live UI edits
                            FilterConfig *fresh = [FilterConfig loadFromDisk];
                            if (isAccept) {
                                fresh.statAcceptedCount += 1;
                            } else {
                                fresh.statRejectedCount += 1;
                            }
                            [fresh saveToDiskAndNotify:NO];
                            config = fresh;
                            notify_post(kNotifyStatsUpdated);

                            appendDaemonLog(@"%@ | Chạm (%.0f, %.0f) trễ %ums",
                                            dec.reasonSummary, actualPt.x, actualPt.y, delayMs);

                            if (config.hapticEnabled) triggerHapticFeedback(isAccept);
                        } else {
                            appendDaemonLog(@"[LỖI CHẠM] Không gửi được sự kiện IOHIDEvent!");
                        }
                    }

                    // Nghỉ Cooldown chờ bảng nổ đơn đóng hẳn
                    NSInteger cdMs = MAX(800, config.cooldownMs);
                    usleep((useconds_t)(cdMs * 1000));
                    continue;
                }

                // Không có đơn nổ -> ngủ theo chu kỳ quét
                NSInteger sleepMs = MAX(150, config.scanIntervalMs);
                usleep((useconds_t)(sleepMs * 1000));
            }
        }

        appendDaemonLog(@"Lõi ngầm pind đã dừng.");
        unlink([kDaemonPidPath fileSystemRepresentation]);
        notify_cancel(reloadToken);
        notify_cancel(stopToken);
    }
    return 0;
}
