// C:/Users/Acer/.gemini/antigravity/scratch/pin-nhiet-do-ts/Sources/DashcamApp/CoolCameraEngine.h
// Context: Objective-C Header / Hardware H.264 Dual-Writer Ping-Pong Engine / iOS 12.0+ arm64

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

@protocol CoolCameraEngineDelegate <NSObject>
- (void)cameraEngineDidFinishClipAtPath:(NSString *)filePath
                             startEpoch:(double)startEpoch
                            durationSec:(NSInteger)durationSec
                               isLocked:(BOOL)isLocked;
- (void)cameraEngineDidUpdateStatus:(NSString *)statusText
                   segmentElapsedSec:(NSInteger)elapsedSec
                        thermalLabel:(NSString *)thermalLabel;
@end

@interface CoolCameraEngine : NSObject

@property (nonatomic, weak) id<CoolCameraEngineDelegate> delegate;
@property (nonatomic, readonly) BOOL isRecording;
@property (nonatomic, readonly) BOOL currentSegmentLocked;
@property (nonatomic, readonly) NSInteger currentSegmentElapsedSec;
@property (nonatomic, readonly) NSProcessInfoThermalState lastThermalState;

+ (instancetype)sharedEngine;

- (void)attachPreviewToView:(UIView *)containerView;
- (void)detachPreview; // Zero-GPU Blackout Mode!

- (void)startRecording;
- (void)stopRecording;
- (void)lockCurrentSegment; // Marks current segment (and previous if < 15s elapsed) as LOCKED

- (NSString *)thermalStateDisplayString;

@end
