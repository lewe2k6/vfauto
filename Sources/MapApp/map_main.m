#import <UIKit/UIKit.h>
#import "MapRelayViewController.h"
#import "SharedConfig.h"

@interface MapAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation MapAppDelegate

static double    gLastMapRelayOpenEpoch = 0.0;
static NSString *gLastMapRelaySourceBid = nil;

- (void)relayIncomingURLWithBackgroundAssertion:(NSURL *)url sourceTag:(NSString *)sourceTag {
    if (!url || url.absoluteString.length == 0) return;

    gLastMapRelayOpenEpoch = [[NSDate date] timeIntervalSince1970];
    if ([sourceTag isKindOfClass:[NSString class]] &&
        sourceTag.length >= 5 &&
        [sourceTag rangeOfString:@"."].location != NSNotFound &&
        ![sourceTag isEqualToString:kAppBundleID]) {
        gLastMapRelaySourceBid = [sourceTag copy];
    }

    UIApplication *app = [UIApplication sharedApplication];
    __block UIBackgroundTaskIdentifier bgTask = UIBackgroundTaskInvalid;
    void (^endTaskSafely)(void) = ^{
        if (bgTask != UIBackgroundTaskInvalid) {
            UIBackgroundTaskIdentifier toEnd = bgTask;
            bgTask = UIBackgroundTaskInvalid;
            [app endBackgroundTask:toEnd];
        }
    };

    bgTask = [app beginBackgroundTaskWithName:@"StandaloneMapRelay" expirationHandler:^{
        dispatch_async(dispatch_get_main_queue(), endTaskSafely);
    }];

    NSString *effectiveSource = gLastMapRelaySourceBid ?: (sourceTag ?: @"XanhSM");
    enqueueAndTriggerMapRelayFromURLString(url.absoluteString, effectiveSource, YES, ^(BOOL ok, NSString *detail) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), endTaskSafely);
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(7.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), endTaskSafely);
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    NSURL *launchURL = launchOptions[UIApplicationLaunchOptionsURLKey];
    if ([launchURL isKindOfClass:[NSURL class]]) {
        NSString *srcApp = launchOptions[UIApplicationLaunchOptionsSourceApplicationKey];
        NSString *tag = ([srcApp isKindOfClass:[NSString class]] && srcApp.length > 0) ? srcApp : @"XanhSM";
        [self relayIncomingURLWithBackgroundAssertion:launchURL sourceTag:tag];
    }

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[[MapRelayViewController alloc] init]];
    nav.navigationBar.barStyle = UIBarStyleBlack;
    nav.navigationBar.tintColor = [UIColor colorWithRed:0.00 green:0.88 blue:0.75 alpha:1.0];
    nav.navigationBar.titleTextAttributes = @{ NSForegroundColorAttributeName: [UIColor whiteColor] };
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}

- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey,id> *)options {
    if ([url isKindOfClass:[NSURL class]]) {
        NSString *srcApp = options[UIApplicationOpenURLOptionsSourceApplicationKey];
        NSString *tag = ([srcApp isKindOfClass:[NSString class]] && srcApp.length > 0) ? srcApp : (gLastMapRelaySourceBid ?: @"XanhSM");
        [self relayIncomingURLWithBackgroundAssertion:url sourceTag:tag];
        return YES;
    }
    return NO;
}

- (BOOL)application:(UIApplication *)application continueUserActivity:(NSUserActivity *)userActivity restorationHandler:(void (^)(NSArray<id<UIUserActivityRestoring>> * _Nullable))restorationHandler {
    if ([userActivity.activityType isEqualToString:NSUserActivityTypeBrowsingWeb] && userActivity.webpageURL) {
        [self relayIncomingURLWithBackgroundAssertion:userActivity.webpageURL sourceTag:@"WebLink"];
        return YES;
    }
    return NO;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    double now = [[NSDate date] timeIntervalSince1970];
    BOOL justInterceptedMapURL = (gLastMapRelayOpenEpoch > 0.0 && fabs(now - gLastMapRelayOpenEpoch) < 3.8);

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        upgradeSharedFilesProtectionNone();
        FilterConfig *cfg = [FilterConfig loadFromDisk];
        if (justInterceptedMapURL) {
            if (cfg.masterEnabled && cfg.mapRelayEnabled && cfg.mapRelayReturnToDriver) {
                NSString *targetBid = resolveEffectiveDriverBundleID(cfg.driverAppBundleID, gLastMapRelaySourceBid);
                returnToDriverAppReliably(cfg.driverAppBundleID, gLastMapRelaySourceBid);
                usleep(65000);
                if (!isDriverAppTrulyFrontmostAndOursBackgrounded(targetBid)) {
                    launchAppByBundleID(targetBid);
                }
                usleep(280000);
                if (!isDriverAppTrulyFrontmostAndOursBackgrounded(targetBid)) {
                    launchAppByBundleID(targetBid);
                }
            }
            return;
        }

        syncGoogleMapsSchemeInterceptionForConfig(cfg);
    });
}

@end

int main(int argc, char * argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([MapAppDelegate class]));
    }
}
