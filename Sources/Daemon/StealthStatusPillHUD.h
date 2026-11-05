#ifndef StealthStatusPillHUD_h
#define StealthStatusPillHUD_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "SharedConfig.h"

typedef NS_ENUM(NSInteger, StealthPillMode) {
    StealthPillModeHidden      = 0,
    StealthPillModeScanning    = 1,
    StealthPillModeActiveTrip  = 2,
    StealthPillModePausingFood = 3,
    StealthPillModeCoolSleep   = 4
};

@interface StealthStatusPillHUD : NSObject

+ (instancetype)sharedHUD;

// Configure logical screen size (375x667 on iPhone 8) & retina scale (2.0 on iPhone 8)
- (void)configureWithLogicalScreenSize:(CGSize)logicalSize scale:(CGFloat)scale;

// Update read-only status pill (0% CPU/GPU if text & mode haven't changed since last frame)
- (void)updateWithMode:(StealthPillMode)mode
         acceptedCount:(NSInteger)acceptedCount
         rejectedCount:(NSInteger)rejectedCount
      pauseRemainingSec:(NSInteger)pauseRemainingSec
     orderPopupVisible:(BOOL)orderPopupVisible
               enabled:(BOOL)enabled;

// Show 2.5-second post-action toast (e.g. "ĐỚP Bike • 48k" or "HỦY Food 17k • 1.9km") in y = 1.8..18.3pt
- (void)showActionToastWithSummary:(NSString *)summary
                          isAccept:(BOOL)isAccept
                       durationSec:(double)durationSec;

// Hide pill immediately (e.g. when screen locks or daemon stops)
- (void)hideImmediately;

// Pure CoreGraphics + CoreText bitmap renderer (exposed for native unit test verification)
+ (CGImageRef)createPillBitmapWithText:(NSString *)text
                               isCompact:(BOOL)isCompact
                               bgRed:(CGFloat)bgR bgGreen:(CGFloat)bgG bgBlue:(CGFloat)bgB bgAlpha:(CGFloat)bgA
                           borderRed:(CGFloat)bdR borderGreen:(CGFloat)bdG borderBlue:(CGFloat)bdB
                              dotRed:(CGFloat)dtR dotGreen:(CGFloat)dtG dotBlue:(CGFloat)dtB
                             scale:(CGFloat)scale CF_RETURNS_RETAINED;

// Exact logical frame on 375x667 iPhone 8 screen (exposed for native geometry collision tests)
+ (CGRect)logicalFrameForCompact:(BOOL)isCompact screenSize:(CGSize)screenSize;

@end

#endif /* StealthStatusPillHUD_h */
