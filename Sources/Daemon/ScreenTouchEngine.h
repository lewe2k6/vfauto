#ifndef ScreenTouchEngine_h
#define ScreenTouchEngine_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreImage/CoreImage.h>

@interface ScreenTouchEngine : NSObject

@property (nonatomic, readonly) CGSize logicalScreenSize;            // 375 x 667 on iPhone 8
@property (nonatomic, readonly) CGFloat screenScale;                 // 2.0 on iPhone 8
@property (nonatomic, readonly) BOOL lastCaptureHadPixels;           // YES when IOSurface has real non-black pixels
@property (nonatomic, readonly) BOOL lastFrameLikelyHasOrderPopup;   // 0.02ms pixel sensor: teal accept bar + white fare card
@property (nonatomic, readonly) NSInteger lastFrameChangedSamples;   // Out of 256 grid samples vs last OCR-analyzed frame

+ (instancetype)sharedEngine;

- (CIImage *)captureScreenCIImage;
- (void)markCurrentFrameAnalyzed;
- (void)invalidateAnalyzedBaseline;

- (BOOL)performHumanTapAtPoint:(CGPoint)logicalPoint
                  jitterRadius:(double)jitterRadiusPt
                     holdMinMs:(NSInteger)holdMinMs
                     holdMaxMs:(NSInteger)holdMaxMs
                outActualPoint:(CGPoint *)outActualPoint;

- (BOOL)performMultiTapAtPoint:(CGPoint)logicalPoint
                      tapCount:(NSInteger)tapCount
                    intervalMs:(NSInteger)intervalMs
                  jitterRadius:(double)jitterRadiusPt
                     holdMinMs:(NSInteger)holdMinMs
                     holdMaxMs:(NSInteger)holdMaxMs
                  outLastPoint:(CGPoint *)outLastPoint;

- (BOOL)performQuickSwipeFromPoint:(CGPoint)startPt
                           toPoint:(CGPoint)endPt
                        durationMs:(NSInteger)durationMs;

@end

#endif /* ScreenTouchEngine_h */
