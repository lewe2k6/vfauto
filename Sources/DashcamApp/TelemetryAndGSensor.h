// C:/Users/Acer/.gemini/antigravity/scratch/pin-nhiet-do-ts/Sources/DashcamApp/TelemetryAndGSensor.h
// Context: Objective-C Header / Low-Power GPS & 20Hz G-Sensor Shock Detector / iOS 12.0+ arm64

#import <Foundation/Foundation.h>

@protocol TelemetryShockDelegate <NSObject>
- (void)telemetryDidDetectShockWithPeakG:(double)peakG;
@end

@interface TelemetryAndGSensor : NSObject

@property (nonatomic, weak) id<TelemetryShockDelegate> delegate;
@property (nonatomic, readonly) double currentSpeedKmh;
@property (nonatomic, readonly) double segmentMaxSpeedKmh;
@property (nonatomic, readonly) double segmentPeakG;
@property (nonatomic, readonly) double lastLat;
@property (nonatomic, readonly) double lastLng;
@property (nonatomic, readonly) BOOL hasValidGPS;

+ (instancetype)sharedTelemetry;
- (void)start;
- (void)stop;
- (void)resetSegmentStats;
- (NSString *)buildCaptionForStartEpoch:(double)startEpoch
                            durationSec:(NSInteger)durationSec
                              sizeBytes:(int64_t)sizeBytes
                               isLocked:(BOOL)isLocked;

@end
