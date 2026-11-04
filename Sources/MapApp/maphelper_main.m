#import <Foundation/Foundation.h>
#import <signal.h>
#import <sys/stat.h>
#import <unistd.h>
#import <string.h>
#import "SharedConfig.h"

static void ensureMapHelperPermissions(void) {
    upgradeSharedFilesProtectionNone();
    NSArray<NSString *> *paths = @[
        kConfigPlistPath,
        kRuntimeStatePath,
        kMapRelayQueuePath,
        kGmapsBundleCachePath,
        kGmapsSyncStatePath,
        kGmapsInfoBackupPath,
        kDaemonLogPath
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

static int runReturnToDriverHelper(const char *rawBid) {
    @autoreleasepool {
        signal(SIGHUP,  SIG_IGN);
        signal(SIGPIPE, SIG_IGN);
        NSString *argBid = (rawBid && rawBid[0] != '\0') ? [NSString stringWithUTF8String:rawBid] : nil;
        FilterConfig *cfg = [FilterConfig loadFromDisk];
        NSString *targetBid = resolveEffectiveDriverBundleID(cfg.driverAppBundleID, argBid);
        if (targetBid.length == 0) return 1;

        const useconds_t delaysUs[6] = { 240000, 320000, 380000, 450000, 520000, 600000 };
        for (int i = 0; i < 6; i++) {
            usleep(delaysUs[i]);
            if (isDeviceScreenLocked()) break;
            if (i >= 1 && isDriverAppTrulyFrontmostAndOursBackgrounded(targetBid)) {
                break;
            }
            launchAppByBundleID(targetBid);
            if (isDriverAppTrulyFrontmostAndOursBackgrounded(targetBid)) {
                break;
            }
        }
    }
    return 0;
}

int main(int argc, char *argv[]) {
    setuid(0);
    setgid(0);

    if (argc >= 2) {
        if (strcmp(argv[1], "--sync-gmaps-scheme") == 0) {
            @autoreleasepool {
                ensureMapHelperPermissions();
                FilterConfig *cfg = [FilterConfig loadFromDisk];
                syncGoogleMapsSchemeInterceptionForConfig(cfg);
                ensureMapHelperPermissions();
            }
            return 0;
        }
        if (strcmp(argv[1], "--restore-gmaps") == 0) {
            @autoreleasepool {
                ensureMapHelperPermissions();
                BOOL ok = forceRestoreGoogleMapsIconNow();
                ensureMapHelperPermissions();
                return ok ? 0 : 1;
            }
        }
        if (strcmp(argv[1], "--return-to-app") == 0) {
            const char *bidArg = (argc >= 3) ? argv[2] : NULL;
            return runReturnToDriverHelper(bidArg);
        }
    }

    @autoreleasepool {
        ensureMapHelperPermissions();
        FilterConfig *cfg = [FilterConfig loadFromDisk];
        syncGoogleMapsSchemeInterceptionForConfig(cfg);
        ensureMapHelperPermissions();
    }
    return 0;
}
