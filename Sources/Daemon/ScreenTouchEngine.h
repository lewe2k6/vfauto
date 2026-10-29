#ifndef ScreenTouchEngine_h
#define ScreenTouchEngine_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreImage/CoreImage.h>

@interface ScreenTouchEngine : NSObject

@property (nonatomic, readonly) CGSize logicalScreenSize; // e.g., 375 x 667 on iPhone 8
@property (nonatomic, readonly) CGFloat screenScale;      // e.g., 2.0 on iPhone 8

+ (instancetype)sharedEngine;

// Captures current full display silently into a CIImage (nil on failure)
- (CIImage *)captureScreenCIImage;

// Dispatches hardware-level digitizer tap with jitter & variable hold time.
// Writes actual tapped point into outActualPoint if non-NULL.
- (BOOL)performHumanTapAtPoint:(CGPoint)logicalPoint
                  jitterRadius:(double)jitterRadiusPt
                     holdMinMs:(NSInteger)holdMinMs
                     holdMaxMs:(NSInteger)holdMaxMs
                outActualPoint:(CGPoint *)outActualPoint;

@end

#endif /* ScreenTouchEngine_h */
