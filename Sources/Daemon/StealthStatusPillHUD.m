#import "StealthStatusPillHUD.h"
#import <QuartzCore/QuartzCore.h>
#import <CoreText/CoreText.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <math.h>

@implementation StealthStatusPillHUD {
    CGSize _logicalSize;
    CGFloat _screenScale;

    id _caContext;
    CALayer *_rootLayer;
    CALayer *_pillLayer;
    BOOL _contextInitialized;
    double _lastContextInitEpoch;

    NSString *_lastRenderedKey;
    BOOL _isCurrentlyHidden;

    NSString *_activeToastText;
    BOOL _activeToastIsAccept;
    double _activeToastExpireEpoch;
}

+ (instancetype)sharedHUD {
    static StealthStatusPillHUD *sHUD = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sHUD = [[StealthStatusPillHUD alloc] init];
    });
    return sHUD;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _logicalSize            = CGSizeMake(kDefaultScreenW, kDefaultScreenH);
        _screenScale            = 2.0;
        _contextInitialized     = NO;
        _lastContextInitEpoch   = 0.0;
        _lastRenderedKey        = @"";
        _isCurrentlyHidden      = YES;
        _activeToastText        = nil;
        _activeToastIsAccept    = YES;
        _activeToastExpireEpoch = 0.0;
    }
    return self;
}

- (void)configureWithLogicalScreenSize:(CGSize)logicalSize scale:(CGFloat)scale {
    if (logicalSize.width >= 300.0 && logicalSize.height >= 480.0) {
        _logicalSize = logicalSize;
    }
    if (scale >= 1.0 && scale <= 4.0) {
        _screenScale = scale;
    }
}

#pragma mark - Exact iPhone 8 (375x667pt) Zero-Collision Status Bar Geometry

+ (CGRect)logicalFrameForCompact:(BOOL)isCompact screenSize:(CGSize)screenSize {
    CGFloat screenW = (screenSize.width >= 300.0) ? screenSize.width : kDefaultScreenW;
    CGFloat scaleX  = screenW / 375.0;

    if (isCompact) {
        // Measured empty slot on iPhone 8 Status Bar between center clock (x <= 212pt) and right GPS/Lock/Battery icons (x >= 310pt):
        // x = 215 .. 307 pt (width 92pt), y = 2.0 .. 18.0 pt (height 16pt, center y = 10pt < 21pt OCR cutoff!)
        CGFloat x = round(215.0 * scaleX);
        CGFloat w = round(92.0 * scaleX);
        return CGRectMake(x, 2.0, w, 16.0);
    } else {
        // Post-action 2.5s toast slot: x = 138 .. 307 pt (width 169pt), y = 1.8 .. 18.3 pt (height 16.5pt)
        // Clears left "◄ Google Maps 4G" breadcrumb (x <= 136pt), right GPS/Battery (x >= 310pt), and stays 100% inside y < 19pt!
        CGFloat x = round(138.0 * scaleX);
        CGFloat w = round(169.0 * scaleX);
        return CGRectMake(x, 1.8, w, 16.5);
    }
}

#pragma mark - CoreGraphics + CoreText Crisp Retina Capsule Renderer

+ (CGImageRef)createPillBitmapWithText:(NSString *)text
                             isCompact:(BOOL)isCompact
                                 bgRed:(CGFloat)bgR bgGreen:(CGFloat)bgG bgBlue:(CGFloat)bgB bgAlpha:(CGFloat)bgA
                             borderRed:(CGFloat)bdR borderGreen:(CGFloat)bdG borderBlue:(CGFloat)bdB
                                dotRed:(CGFloat)dtR dotGreen:(CGFloat)dtG dotBlue:(CGFloat)dtB
                                 scale:(CGFloat)scale {
    if (scale < 1.0) scale = 2.0;
    CGRect logicalRect = [self logicalFrameForCompact:isCompact screenSize:CGSizeMake(kDefaultScreenW, kDefaultScreenH)];
    size_t pxW = (size_t)llround(logicalRect.size.width * scale);
    size_t pxH = (size_t)llround(logicalRect.size.height * scale);
    if (pxW < 16 || pxH < 8) return NULL;

    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (!cs) cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL,
                                             pxW,
                                             pxH,
                                             8,
                                             pxW * 4,
                                             cs,
                                             (CGBitmapInfo)(kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little));
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;

    CGContextClearRect(ctx, CGRectMake(0, 0, pxW, pxH));
    CGContextSetAllowsAntialiasing(ctx, true);
    CGContextSetShouldAntialias(ctx, true);

    CGFloat w = (CGFloat)pxW;
    CGFloat h = (CGFloat)pxH;
    CGFloat inset = 0.75 * scale;
    CGRect pillRect = CGRectInset(CGRectMake(0, 0, w, h), inset, inset);
    CGFloat radius = pillRect.size.height * 0.5;

    // 1. Rounded capsule background + 1pt glowing border
    CGPathRef pillPath = CGPathCreateWithRoundedRect(pillRect, radius, radius, NULL);
    if (pillPath) {
        CGContextSaveGState(ctx);
        CGContextAddPath(ctx, pillPath);
        CGContextSetRGBFillColor(ctx, bgR, bgG, bgB, bgA);
        CGContextFillPath(ctx);

        CGContextAddPath(ctx, pillPath);
        CGContextSetLineWidth(ctx, 1.0 * scale);
        CGContextSetRGBStrokeColor(ctx, bdR, bdG, bdB, 0.92);
        CGContextStrokePath(ctx);
        CGContextRestoreGState(ctx);
        CGPathRelease(pillPath);
    }

    // 2. Glowing status LED circle on the left
    CGFloat dotRadius = (isCompact ? 2.8 : 3.0) * scale;
    CGFloat dotCenterX = inset + (isCompact ? 7.2 : 8.0) * scale;
    CGFloat dotCenterY = h * 0.5;

    // Subtle outer halo
    CGContextSetRGBFillColor(ctx, dtR, dtG, dtB, 0.28);
    CGContextFillEllipseInRect(ctx, CGRectMake(dotCenterX - dotRadius * 1.45,
                                               dotCenterY - dotRadius * 1.45,
                                               dotRadius * 2.9,
                                               dotRadius * 2.9));
    // Solid inner LED core
    CGContextSetRGBFillColor(ctx, dtR, dtG, dtB, 1.0);
    CGContextFillEllipseInRect(ctx, CGRectMake(dotCenterX - dotRadius,
                                               dotCenterY - dotRadius,
                                               dotRadius * 2.0,
                                               dotRadius * 2.0));

    // 3. Crisp auto-fitting Vietnamese text via CoreText
    NSString *safeText = (text.length > 0) ? text : @"CANH";
    CGFloat textLeftX  = dotCenterX + dotRadius + (3.6 * scale);
    CGFloat textRightX = w - inset - (4.2 * scale);
    CGFloat maxTextW   = MAX(10.0, textRightX - textLeftX);

    CGFloat fontSizePx = (isCompact ? 9.8 : 10.2) * scale;
    CTFontRef font = CTFontCreateWithName(CFSTR("HelveticaNeue-Bold"), fontSizePx, NULL);
    if (!font) {
        font = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, fontSizePx, NULL);
    }

    if (font) {
        CGFloat whiteComponents[4] = { 1.0, 1.0, 1.0, 0.98 };
        CGColorSpaceRef rgbCS = CGColorSpaceCreateDeviceRGB();
        CGColorRef textColor = CGColorCreate(rgbCS, whiteComponents);
        CGColorSpaceRelease(rgbCS);

        NSDictionary *attrs = @{
            (__bridge NSString *)kCTFontAttributeName: (__bridge id)font,
            (__bridge NSString *)kCTForegroundColorAttributeName: (__bridge id)textColor
        };
        NSAttributedString *attrStr = [[NSAttributedString alloc] initWithString:safeText attributes:attrs];
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attrStr);

        if (line) {
            CGFloat ascent = 0.0, descent = 0.0, leading = 0.0;
            double lineW = CTLineGetTypographicBounds(line, &ascent, &descent, &leading);

            // Auto-shrink font if text exceeds available capsule width
            if (lineW > maxTextW && lineW > 1.0) {
                CGFloat shrunkSize = MAX(7.2 * scale, fontSizePx * (maxTextW / (CGFloat)lineW) * 0.97);
                CFRelease(line);
                CFRelease(font);
                font = CTFontCreateWithName(CFSTR("HelveticaNeue-Bold"), shrunkSize, NULL);
                if (!font) {
                    font = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, shrunkSize, NULL);
                }
                attrs = @{
                    (__bridge NSString *)kCTFontAttributeName: (__bridge id)font,
                    (__bridge NSString *)kCTForegroundColorAttributeName: (__bridge id)textColor
                };
                attrStr = [[NSAttributedString alloc] initWithString:safeText attributes:attrs];
                line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attrStr);
                lineW = CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
            }

            if (line) {
                CGFloat textHeight = ascent + descent;
                CGFloat baselineY  = floor((h - textHeight) * 0.5 + descent + 0.3 * scale);
                CGFloat drawX      = textLeftX;
                if ((CGFloat)lineW < maxTextW) {
                    // Center slightly within the text zone for clean visual balance
                    drawX = textLeftX + floor((maxTextW - (CGFloat)lineW) * 0.35);
                }

                CGContextSetTextMatrix(ctx, CGAffineTransformIdentity);
                CGContextSetTextPosition(ctx, drawX, baselineY);
                CTLineDraw(line, ctx);
                CFRelease(line);
            }
        }
        if (textColor) CGColorRelease(textColor);
        if (font) CFRelease(font);
    }

    CGImageRef outImg = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return outImg;
}

#pragma mark - CAContext WindowServer Setup (100% Read-Only Touch-Passthrough)

- (BOOL)ensureCAContextReady {
    double now = [[NSDate date] timeIntervalSince1970];
    if (_contextInitialized && _caContext && _rootLayer && _pillLayer) {
        return YES;
    }
    if ((now - _lastContextInitEpoch) < 2.0) {
        return NO;
    }
    _lastContextInitEpoch = now;

    @try {
        void *qc = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY);
        Class caCtxCls  = NSClassFromString(@"CAContext");
        Class caDispCls = NSClassFromString(@"CADisplay");
        if (!caCtxCls) return NO;

        uint32_t dispId = 1;
        if (caDispCls && [caDispCls respondsToSelector:NSSelectorFromString(@"mainDisplay")]) {
            id mainDisp = [caDispCls valueForKey:@"mainDisplay"];
            if (mainDisp && [mainDisp respondsToSelector:NSSelectorFromString(@"displayId")]) {
                NSNumber *dNum = [mainDisp valueForKey:@"displayId"];
                if ([dNum respondsToSelector:@selector(unsignedIntValue)] && [dNum unsignedIntValue] > 0) {
                    dispId = [dNum unsignedIntValue];
                }
            }
        }

        NSMutableDictionary *opts = [NSMutableDictionary dictionaryWithDictionary:@{
            @"displayable":    @YES,
            @"secure":         @YES,
            @"ignoresHitTest": @YES,
            @"displayId":      @(dispId)
        }];

        if (qc) {
            NSString * const *kDisp = (NSString * const *)dlsym(qc, "kCAContextDisplayable");
            if (kDisp && *kDisp) opts[*kDisp] = @YES;
            NSString * const *kSec  = (NSString * const *)dlsym(qc, "kCAContextSecure");
            if (kSec && *kSec) opts[*kSec] = @YES;
            NSString * const *kHit  = (NSString * const *)dlsym(qc, "kCAContextIgnoresHitTest");
            if (kHit && *kHit) opts[*kHit] = @YES;
            NSString * const *kDid  = (NSString * const *)dlsym(qc, "kCAContextDisplayId");
            if (kDid && *kDid) opts[*kDid] = @(dispId);
        }

        SEL remOptSel = NSSelectorFromString(@"remoteContextWithOptions:");
        SEL remSel    = NSSelectorFromString(@"remoteContext");
        id ctx = nil;
        if ([caCtxCls respondsToSelector:remOptSel]) {
            ctx = ((id (*)(id, SEL, NSDictionary *))objc_msgSend)(caCtxCls, remOptSel, opts);
        }
        if (!ctx && [caCtxCls respondsToSelector:remSel]) {
            ctx = ((id (*)(id, SEL))objc_msgSend)(caCtxCls, remSel);
        }
        if (!ctx) return NO;

        // Explicitly disable hit-testing on the context so 100% of touches pass straight through to underlying apps
        SEL hitSel = NSSelectorFromString(@"setIgnoresHitTest:");
        if ([ctx respondsToSelector:hitSel]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(ctx, hitSel, YES);
        }
        SEL secSel = NSSelectorFromString(@"setSecure:");
        if ([ctx respondsToSelector:secSel]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(ctx, secSel, YES);
        }
        SEL lvlSel = NSSelectorFromString(@"setLevel:");
        if ([ctx respondsToSelector:lvlSel]) {
            // Level 2500 sits right above iOS Status Bar (1000) & Alerts (2000)
            ((void (*)(id, SEL, float))objc_msgSend)(ctx, lvlSel, 2500.0f);
        }

        CGFloat physW = _logicalSize.width * _screenScale;
        CGFloat physH = _logicalSize.height * _screenScale;

        [CATransaction begin];
        [CATransaction setDisableActions:YES];

        CALayer *root = [CALayer layer];
        root.anchorPoint = CGPointZero;
        root.position    = CGPointZero;
        root.bounds      = CGRectMake(0.0, 0.0, physW, physH);
        root.backgroundColor = NULL;

        CALayer *pill = [CALayer layer];
        pill.anchorPoint = CGPointZero;
        CGRect initLog = [StealthStatusPillHUD logicalFrameForCompact:YES screenSize:_logicalSize];
        pill.frame = CGRectMake(initLog.origin.x * _screenScale,
                                initLog.origin.y * _screenScale,
                                initLog.size.width * _screenScale,
                                initLog.size.height * _screenScale);
        pill.contentsGravity = kCAGravityResize;
        pill.hidden = YES;
        [root addSublayer:pill];

        SEL layerSel = NSSelectorFromString(@"setLayer:");
        if ([ctx respondsToSelector:layerSel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(ctx, layerSel, root);
        }

        [CATransaction commit];
        [CATransaction flush];

        _caContext          = ctx;
        _rootLayer          = root;
        _pillLayer          = pill;
        _contextInitialized = YES;
        _isCurrentlyHidden  = YES;
        _lastRenderedKey    = @"";
        return YES;
    } @catch (NSException *ex) {
        return NO;
    }
}

#pragma mark - Live Status & Toast Updates

- (void)hideImmediately {
    _activeToastText = nil;
    _activeToastExpireEpoch = 0.0;
    if (!_contextInitialized || !_pillLayer || _isCurrentlyHidden) return;

    @try {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _pillLayer.hidden = YES;
        _pillLayer.contents = nil;
        [CATransaction commit];
        [CATransaction flush];
        _isCurrentlyHidden = YES;
        _lastRenderedKey = @"HIDDEN";
    } @catch (NSException *ex) {}
}

- (void)showActionToastWithSummary:(NSString *)summary
                          isAccept:(BOOL)isAccept
                       durationSec:(double)durationSec {
    if (!summary || summary.length == 0) return;
    double now = [[NSDate date] timeIntervalSince1970];
    _activeToastText        = [summary copy];
    _activeToastIsAccept    = isAccept;
    _activeToastExpireEpoch = now + ((durationSec > 0.4) ? durationSec : 2.5);
}

- (void)updateWithMode:(StealthPillMode)mode
         acceptedCount:(NSInteger)acceptedCount
         rejectedCount:(NSInteger)rejectedCount
     pauseRemainingSec:(NSInteger)pauseRemainingSec
     orderPopupVisible:(BOOL)orderPopupVisible
               enabled:(BOOL)enabled {
    if (!enabled || mode == StealthPillModeHidden) {
        [self hideImmediately];
        return;
    }

    if (![self ensureCAContextReady]) {
        return;
    }

    double now = [[NSDate date] timeIntervalSince1970];

    // If a new order popup is actively on screen being evaluated, immediately collapse any previous toast
    // so the pill stays locked in its compact 92x16pt slot at x=215..307, y=2..18pt!
    if (orderPopupVisible && _activeToastExpireEpoch > 0.0) {
        _activeToastText = nil;
        _activeToastExpireEpoch = 0.0;
    }

    BOOL showToast = (_activeToastText.length > 0 && now < _activeToastExpireEpoch && !orderPopupVisible);
    if (!showToast && _activeToastExpireEpoch > 0.0 && now >= _activeToastExpireEpoch) {
        _activeToastText = nil;
        _activeToastExpireEpoch = 0.0;
    }

    BOOL isCompact = !showToast;
    NSString *displayText = nil;
    CGFloat bgR = 0.05, bgG = 0.07, bgB = 0.10, bgA = 0.88;
    CGFloat bdR = 0.00, bdG = 0.90, bdB = 0.46;
    CGFloat dtR = 0.00, dtG = 0.90, dtB = 0.46;

    if (showToast) {
        displayText = _activeToastText;
        if (_activeToastIsAccept) {
            // Emerald Accept Toast
            bgR = 0.03; bgG = 0.30; bgB = 0.20; bgA = 0.94;
            bdR = 0.00; bdG = 0.92; bdB = 0.50;
            dtR = 0.15; dtG = 1.00; dtB = 0.58;
        } else {
            // Crimson-Coral Reject Toast
            bgR = 0.42; bgG = 0.09; bgB = 0.07; bgA = 0.94;
            bdR = 1.00; bdG = 0.32; bdB = 0.32;
            dtR = 1.00; dtG = 0.40; dtB = 0.35;
        }
    } else {
        switch (mode) {
            case StealthPillModeScanning:
                displayText = [NSString stringWithFormat:@"CANH %ld/%ld", (long)acceptedCount, (long)rejectedCount];
                bgR = 0.05; bgG = 0.08; bgB = 0.11; bgA = 0.88;
                bdR = 0.00; bdG = 0.88; bdB = 0.48;
                dtR = 0.00; dtG = 0.92; dtB = 0.48;
                break;

            case StealthPillModeActiveTrip:
                displayText = @"TRONG CUỐC";
                bgR = 0.05; bgG = 0.10; bgB = 0.18; bgA = 0.88;
                bdR = 0.16; bdG = 0.71; bdB = 0.96;
                dtR = 0.16; dtG = 0.75; dtB = 1.00;
                break;

            case StealthPillModePausingFood: {
                NSInteger rem = MAX(0, pauseRemainingSec);
                displayText = [NSString stringWithFormat:@"NGHỈ %lds", (long)rem];
                bgR = 0.15; bgG = 0.10; bgB = 0.03; bgA = 0.91;
                bdR = 1.00; bdG = 0.70; bdB = 0.00;
                dtR = 1.00; dtG = 0.75; dtB = 0.05;
                break;
            }

            case StealthPillModeCoolSleep:
                displayText = @"NGỦ MÁT";
                bgR = 0.06; bgG = 0.08; bgB = 0.10; bgA = 0.80;
                bdR = 0.50; bdG = 0.72; bdB = 0.76;
                dtR = 0.56; dtG = 0.82; dtB = 0.86;
                break;

            case StealthPillModeHidden:
            default:
                [self hideImmediately];
                return;
        }
    }

    NSString *renderKey = [NSString stringWithFormat:@"%d|%d|%@", (int)mode, isCompact ? 1 : 0, displayText];
    if (!_isCurrentlyHidden && [renderKey isEqualToString:_lastRenderedKey]) {
        return; // Zero change -> 0% CPU/GPU!
    }

    CGImageRef cgImg = [StealthStatusPillHUD createPillBitmapWithText:displayText
                                                            isCompact:isCompact
                                                                bgRed:bgR bgGreen:bgG bgBlue:bgB bgAlpha:bgA
                                                            borderRed:bdR borderGreen:bdG borderBlue:bdB
                                                               dotRed:dtR dotGreen:dtG dotBlue:dtB
                                                                scale:_screenScale];
    if (!cgImg) return;

    @try {
        CGRect logRect = [StealthStatusPillHUD logicalFrameForCompact:isCompact screenSize:_logicalSize];
        CGRect physRect = CGRectMake(logRect.origin.x * _screenScale,
                                     logRect.origin.y * _screenScale,
                                     logRect.size.width * _screenScale,
                                     logRect.size.height * _screenScale);

        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _pillLayer.frame    = physRect;
        _pillLayer.contents = (__bridge id)cgImg;
        _pillLayer.hidden   = NO;
        [CATransaction commit];
        [CATransaction flush];

        _isCurrentlyHidden = NO;
        _lastRenderedKey   = renderKey;
    } @catch (NSException *ex) {
    } @finally {
        CGImageRelease(cgImg);
    }
}

@end
