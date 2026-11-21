// C:/Users/Acer/.gemini/antigravity/scratch/pin-nhiet-do-ts/Sources/DashcamApp/dashcam_main.m
// Context: Objective-C Entry Point / CoolDash6 AppDelegate / iOS 12.0+ arm64

#import <UIKit/UIKit.h>
#import "BlackoutDashboardVC.h"
#import "CoolCameraEngine.h"

@interface DashcamAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) BlackoutDashboardVC *rootVC;
@end

@implementation DashcamAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    application.idleTimerDisabled = YES; // Keep dashcam awake while mounted on motorcycle

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = [UIColor blackColor];
    self.rootVC = [[BlackoutDashboardVC alloc] init];
    self.window.rootViewController = self.rootVC;
    [self.window makeKeyAndVisible];
    return YES;
}

- (void)applicationWillResignActive:(UIApplication *)application {
    [self.rootVC restoreUserBrightness];
}

- (void)applicationWillTerminate:(UIApplication *)application {
    [self.rootVC restoreUserBrightness];
    [[CoolCameraEngine sharedEngine] stopRecording];
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([DashcamAppDelegate class]));
    }
}
