#ifndef ScreenTouchEngine_h
#define ScreenTouchEngine_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreImage/CoreImage.h>

@interface ScreenTouchEngine : NSObject

@property (nonatomic, readonly) CGSize logicalScreenSize;               // 375 x 667 on iPhone 8
@property (nonatomic, readonly) CGFloat screenScale;                    // 2.0 on iPhone 8
@property (nonatomic, readonly) BOOL lastCaptureHadPixels;              // YES when IOSurface has real non-black pixels
@property (nonatomic, readonly) BOOL lastFrameHasBottomTealButton;      // 0.01ms pixel sensor: 4-row bottom teal button scan
@property (nonatomic, readonly) BOOL lastFrameLikelyHasOrderPopup;      // 0.02ms pixel sensor: teal accept bar + white order card
@property (nonatomic, readonly) BOOL lastFrameHasOrderHeaderAtTop;      // 0.01ms pixel sensor: order header flush at y~52pt (safe to tap [X])
@property (nonatomic, readonly) BOOL lastFrameHeaderIconWarmFood;       // 0.01ms pixel sensor: top-left icon has warm food colors
@property (nonatomic, readonly) BOOL lastFrameHeaderIconCoolRide;       // 0.01ms pixel sensor: top-left icon is pure cool cyan (Bike/Express)
@property (nonatomic, readonly) BOOL lastFrameLikelyHasLobbyPowerButton;// 0.01ms pixel sensor: uncovered teal [Power] circle around (40, 455)
@property (nonatomic, readonly) BOOL lastFrameLooksLikeGoogleMapsNav;   // 0.01ms pixel sensor: Google Maps top green turn banner
@property (nonatomic, readonly) double lastOrderYellowDotY;             // 0.005ms pixel sensor: logical Y (pt) of yellow dropoff ring ◉ on order popup
@property (nonatomic, readonly) NSInteger lastFrameChangedSamples;      // Out of 256 grid samples vs last OCR-analyzed frame

+ (instancetype)sharedEngine;

- (CIImage *)captureScreenCIImage;
- (void)markCurrentFrameAnalyzed;
- (void)invalidateAnalyzedBaseline;
- (void)refreshHIDClient;

- (BOOL)performHumanTapAtPoint:(CGPoint)logicalPoint
                  jitterRadius:(double)jitterRadiusPt
                     holdMinMs:(NSInteger)holdMinMs
                     holdMaxMs:(NSInteger)holdMaxMs
                outActualPoint:(CGPoint *)outActualPoint;

- (BOOL)performQuickSwipeFromPoint:(CGPoint)startPt
                           toPoint:(CGPoint)endPt
                        durationMs:(NSInteger)durationMs;

@end

#endif /* ScreenTouchEngine_h */
