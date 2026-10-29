#ifndef ScreenTouchEngine_h
#define ScreenTouchEngine_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreImage/CoreImage.h>

@interface ScreenTouchEngine : NSObject

@property (nonatomic, readonly) CGSize logicalScreenSize; // 375 x 667 on iPhone 8
@property (nonatomic, readonly) CGFloat screenScale;      // 2.0 on iPhone 8

+ (instancetype)sharedEngine;

- (CIImage *)captureScreenCIImage;

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

@end

#endif /* ScreenTouchEngine_h */
