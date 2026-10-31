#import <UIKit/UIKit.h>
#import "StealthBatteryViewController.h"
#import "SharedConfig.h"

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[StealthBatteryViewController alloc] init];
    [self.window makeKeyAndVisible];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        FilterConfig *cfg = [FilterConfig loadFromDisk];
        if (cfg.masterEnabled) {
            startFilterDaemonIfNeeded();
        }
    });

    return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        FilterConfig *cfg = [FilterConfig loadFromDisk];
        if (cfg.masterEnabled) {
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
