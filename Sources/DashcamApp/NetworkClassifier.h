// C:/Users/Acer/.gemini/antigravity/scratch/pin-nhiet-do-ts/Sources/DashcamApp/NetworkClassifier.h
// Context: Objective-C Header / Home Wi-Fi vs Android Hotspot Metered Classifier / iOS 12.0+ arm64

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, DashcamNetMode) {
    DashcamNetModeOffline        = 0,
    DashcamNetModeMeteredHotspot = 1, // Default safe mode (4G or Android Hotspot -> <= 3.5 GB/day)
    DashcamNetModeHomeUnlimited  = 2  // Only when matching saved Home Wi-Fi SSID/BSSID
};

extern NSString *const kDashcamNetworkChangedNotification;

@interface NetworkClassifier : NSObject

@property (nonatomic, readonly) DashcamNetMode currentMode;
@property (nonatomic, readonly, copy) NSString *currentSSID;
@property (nonatomic, readonly, copy) NSString *currentBSSID;

+ (instancetype)sharedClassifier;
- (void)startMonitoring;
- (void)stopMonitoring;
- (void)refreshNow;
- (NSString *)modeDisplayString;

@end
