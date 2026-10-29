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

    // Auto-revive daemon if masterEnabled was left ON before reboot
    FilterConfig *cfg = [FilterConfig loadFromDisk];
    if (cfg.masterEnabled) {
        startFilterDaemonIfNeeded();
    }

    return YES;
}

@end

int main(int argc, char * argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
