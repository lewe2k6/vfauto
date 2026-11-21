// C:/Users/Acer/.gemini/antigravity/scratch/pin-nhiet-do-ts/Sources/DashcamApp/DashcamConfig.h
// Context: Objective-C Header / CoolDash6 / iOS 12.0+ arm64 / iPhone 6 (A8)

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, DashcamProfileMode) {
    DashcamProfileEco5Min   = 0, // 720p @ 20fps, 1.15 Mbps, 5 min (~44.3 MB/clip)
    DashcamProfileSharp3Min = 1  // 720p @ 24fps, 1.90 Mbps, 3 min (~43.5 MB/clip)
};

@interface DashcamConfig : NSObject

@property (nonatomic, copy)   NSString *telegramBotToken;
@property (nonatomic, copy)   NSString *telegramChatId;
@property (nonatomic, copy)   NSString *homeWifiSSID;
@property (nonatomic, copy)   NSString *homeWifiBSSID;

@property (nonatomic, assign) DashcamProfileMode profileMode;
@property (nonatomic, assign) BOOL recordAudio;
@property (nonatomic, assign) BOOL enableGPS;
@property (nonatomic, assign) BOOL autoRecordOnLaunch;
@property (nonatomic, assign) BOOL enableTelegramUpload;

@property (nonatomic, assign) NSInteger dailyMeteredLimitMB; // Default 3500 MB (3.5 GB)
@property (nonatomic, assign) double maxLoopStorageGB;       // Default 30.0 GB
@property (nonatomic, assign) double maxLockedStorageGB;     // Default 6.0 GB
@property (nonatomic, assign) double minFreeSpaceGB;         // Default 4.0 GB
@property (nonatomic, assign) double gSensorThresholdG;      // Default 2.8 G

+ (instancetype)sharedConfig;
- (void)load;
- (void)save;

// Derived parameters for active profile
- (NSInteger)segmentDurationSeconds;
- (NSInteger)targetFPS;
- (NSInteger)videoBitrateBps;
- (NSString *)profileDisplayName;
- (BOOL)hasValidTelegramConfig;

@end
