#import <UIKit/UIKit.h>
#import "StealthBatteryViewController.h"
#import "SharedConfig.h"

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation AppDelegate

- (void)relayIncomingURLWithBackgroundAssertion:(NSURL *)url sourceTag:(NSString *)sourceTag {
    if (!url || url.absoluteString.length == 0) return;

    UIApplication *app = [UIApplication sharedApplication];
    __block UIBackgroundTaskIdentifier bgTask = [app beginBackgroundTaskWithName:@"PinMapRelay" expirationHandler:^{
        if (bgTask != UIBackgroundTaskInvalid) {
            [app endBackgroundTask:bgTask];
            bgTask = UIBackgroundTaskInvalid;
        }
    }];

    enqueueAndTriggerMapRelayFromURLString(url.absoluteString, sourceTag ?: @"XanhSM", YES, ^(BOOL ok, NSString *detail) {
        if (bgTask != UIBackgroundTaskInvalid) {
            [app endBackgroundTask:bgTask];
            bgTask = UIBackgroundTaskInvalid;
        }
    });

    // If handed off asynchronously to pind (no completion callback invoked directly), release bgTask cleanly after 5.5s
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (bgTask != UIBackgroundTaskInvalid) {
            [app endBackgroundTask:bgTask];
            bgTask = UIBackgroundTaskInvalid;
        }
    });
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[StealthBatteryViewController alloc] init];
    [self.window makeKeyAndVisible];

    NSURL *launchURL = launchOptions[UIApplicationLaunchOptionsURLKey];
    if ([launchURL isKindOfClass:[NSURL class]]) {
        [self relayIncomingURLWithBackgroundAssertion:launchURL sourceTag:@"XanhSM"];
    }
    return YES;
}

- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey,id> *)options {
    if ([url isKindOfClass:[NSURL class]]) {
        NSString *srcApp = options[UIApplicationOpenURLOptionsSourceApplicationKey];
        NSString *tag = ([srcApp isKindOfClass:[NSString class]] && srcApp.length > 0) ? srcApp : @"XanhSM";
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
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (readMasterEnabledSafely(NO)) {
            startFilterDaemonIfNeeded();
        }
    });
}

@end

int main(int argc, char * argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
