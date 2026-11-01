#import "ScreenTouchEngine.h"
#import "SharedConfig.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <objc/message.h>
#import <math.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

typedef double IOHIDFloat;
typedef uint32_t IOOptionBits;
typedef CFTypeRef IOHIDEventRef;
typedef CFTypeRef IOHIDEventSystemClientRef;
typedef struct __IOSurfaceAccelerator *IOSurfaceAcceleratorRef;

typedef IOSurfaceRef (*IOSurfaceCreate_f)(CFDictionaryRef properties);
typedef size_t (*IOSurfaceAlignProperty_f)(CFStringRef property, size_t value);
typedef kern_return_t (*IOSurfaceLock_f)(IOSurfaceRef buffer, uint32_t options, uint32_t *seed);
typedef kern_return_t (*IOSurfaceUnlock_f)(IOSurfaceRef buffer, uint32_t options, uint32_t *seed);
typedef void *(*IOSurfaceGetBaseAddress_f)(IOSurfaceRef buffer);
typedef size_t (*IOSurfaceGetAllocSize_f)(IOSurfaceRef buffer);
typedef kern_return_t (*IOSurfaceAcceleratorCreate_f)(CFAllocatorRef allocator, CFDictionaryRef properties, IOSurfaceAcceleratorRef *outAcc);
typedef kern_return_t (*IOSurfaceAcceleratorTransferSurface_f)(IOSurfaceAcceleratorRef acc, IOSurfaceRef src, IOSurfaceRef dst, void *, void *, void *, void *);

#define kIOSurfaceLockReadOnlyFlag 0x00000001

typedef void (*CARenderServerRenderDisplay_f)(kern_return_t, CFStringRef, IOSurfaceRef, int, int);

typedef IOHIDEventSystemClientRef (*IOHIDEventSystemClientCreate_f)(CFAllocatorRef);
typedef void (*IOHIDEventSystemClientDispatchEvent_f)(IOHIDEventSystemClientRef, IOHIDEventRef);

typedef IOHIDEventRef (*IOHIDEventCreateDigitizerEvent_f)(
    CFAllocatorRef allocator, uint64_t timeStamp, uint32_t type,
    uint32_t index, uint32_t identity, uint32_t eventMask, uint32_t buttonMask,
    IOHIDFloat x, IOHIDFloat y, IOHIDFloat z, IOHIDFloat tipPressure, IOHIDFloat barrelPressure,
    Boolean range, Boolean touch, IOOptionBits options);

typedef IOHIDEventRef (*IOHIDEventCreateDigitizerFingerEvent_f)(
    CFAllocatorRef allocator, uint64_t timeStamp, uint32_t index, uint32_t identity,
    uint32_t eventMask, IOHIDFloat x, IOHIDFloat y, IOHIDFloat z,
    IOHIDFloat tipPressure, IOHIDFloat twist, Boolean range, Boolean touch, IOOptionBits options);

typedef void (*IOHIDEventAppendEvent_f)(IOHIDEventRef parent, IOHIDEventRef child, IOOptionBits options);
typedef void (*IOHIDEventSetSenderID_f)(IOHIDEventRef event, uint64_t senderID);
typedef void (*IOHIDEventSetIntegerValue_f)(IOHIDEventRef event, uint32_t field, CFIndex value);
typedef void (*IOHIDEventSetFloatValue_f)(IOHIDEventRef event, uint32_t field, IOHIDFloat value);

// Exact IOKitSPI constants verified for iOS 15 / iOS 16 (STHIDEventGenerator)
#define kIOHIDDigitizerTransducerTypeHand            3
#define kIOHIDDigitizerEventRange                    (1 << 0)
#define kIOHIDDigitizerEventTouch                    (1 << 1)
#define kIOHIDDigitizerEventPosition                 (1 << 2)
#define kIOHIDDigitizerEventIdentity                 (1 << 5)

#define kIOHIDEventFieldIsBuiltIn                    4
#define kIOHIDEventFieldDigitizerMajorRadius         0xB0014
#define kIOHIDEventFieldDigitizerMinorRadius         0xB0015
#define kIOHIDEventFieldDigitizerIsDisplayIntegrated 0xB0019

#define kGridDim 16
#define kGridCount (kGridDim * kGridDim)

typedef NS_ENUM(NSInteger, TouchPhaseMode) {
    TouchPhaseDown = 0,
    TouchPhaseMove = 1,
    TouchPhaseUp   = 2
};

@implementation ScreenTouchEngine {
    IOSurfaceCreate_f _fnSurfaceCreate;
    IOSurfaceAlignProperty_f _fnSurfaceAlign;
    IOSurfaceLock_f _fnSurfaceLock;
    IOSurfaceUnlock_f _fnSurfaceUnlock;
    IOSurfaceGetBaseAddress_f _fnSurfaceBaseAddr;
    IOSurfaceGetAllocSize_f _fnSurfaceAllocSize;
    IOSurfaceAcceleratorCreate_f _fnAccCreate;
    IOSurfaceAcceleratorTransferSurface_f _fnAccTransfer;

    CARenderServerRenderDisplay_f _fnRenderDisplay;

    IOHIDEventSystemClientCreate_f _fnClientCreate;
    IOHIDEventSystemClientDispatchEvent_f _fnDispatchEvent;
    IOHIDEventCreateDigitizerEvent_f _fnCreateDigitizer;
    IOHIDEventCreateDigitizerFingerEvent_f _fnCreateFinger;
    IOHIDEventAppendEvent_f _fnAppendEvent;
    IOHIDEventSetSenderID_f _fnSetSenderID;
    IOHIDEventSetIntegerValue_f _fnSetIntVal;
    IOHIDEventSetFloatValue_f _fnSetFloatVal;

    IOHIDEventSystemClientRef _hidClient;
    dispatch_queue_t _hidQueue;

    IOSurfaceRef _srcSurface;
    IOSurfaceRef _dstSurface;
    IOSurfaceAcceleratorRef _accelerator;

    int _pixelW;
    int _pixelH;
    size_t _bytesPerRow;
    int _consecutiveEmptyCaptures;

    BOOL _hasAnalyzedBaseline;
    uint8_t _currentR[kGridCount];
    uint8_t _currentG[kGridCount];
    uint8_t _currentB[kGridCount];
    uint8_t _analyzedR[kGridCount];
    uint8_t _analyzedG[kGridCount];
    uint8_t _analyzedB[kGridCount];
}

+ (instancetype)sharedEngine {
    static ScreenTouchEngine *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[ScreenTouchEngine alloc] init];
    });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _logicalScreenSize                  = CGSizeMake(kDefaultScreenW, kDefaultScreenH);
        _screenScale                        = 2.0;
        _lastCaptureHadPixels               = NO;
        _lastFrameLikelyHasOrderPopup       = NO;
        _lastFrameHasOrderHeaderAtTop       = NO;
        _lastFrameLikelyHasBlueNavButton    = NO;
        _lastFrameLikelyHasLobbyPowerButton = NO;
        _lastFrameLooksLikeGoogleMapsNav    = NO;
        _lastOrderYellowDotY                = 0.0;
        _lastFrameChangedSamples            = kGridCount;
        _hasAnalyzedBaseline                = NO;
        _consecutiveEmptyCaptures           = 0;

        CGSize pxSize = CGSizeZero;
        SEL unjailedSel = NSSelectorFromString(@"_unjailedReferenceBoundsInPixels");
        if ([[UIScreen mainScreen] respondsToSelector:unjailedSel]) {
            CGRect r = ((CGRect (*)(id, SEL))objc_msgSend)([UIScreen mainScreen], unjailedSel);
            pxSize = r.size;
        }
        if (pxSize.width < 640 || pxSize.height < 1136) {
            Class caDispCls = NSClassFromString(@"CADisplay");
            if (caDispCls && [caDispCls respondsToSelector:NSSelectorFromString(@"mainDisplay")]) {
                id mainDisp = [caDispCls valueForKey:@"mainDisplay"];
                NSValue *boundsVal = mainDisp ? [mainDisp valueForKey:@"bounds"] : nil;
                if (boundsVal && strcmp([boundsVal objCType], @encode(CGRect)) == 0) {
                    CGRect r = CGRectZero;
                    [boundsVal getValue:&r];
                    pxSize = r.size;
                }
            }
        }

        if (pxSize.width >= 640 && pxSize.height >= 1136) {
            if ((int)round(pxSize.width) == 750 && (int)round(pxSize.height) == 1334) {
                _logicalScreenSize = CGSizeMake(375.0, 667.0);
                _screenScale = 2.0;
            } else if ((int)round(pxSize.width) >= 1080) {
                _screenScale = 3.0;
                _logicalScreenSize = CGSizeMake(round(pxSize.width / 3.0), round(pxSize.height / 3.0));
            } else {
                _screenScale = 2.0;
                _logicalScreenSize = CGSizeMake(round(pxSize.width / 2.0), round(pxSize.height / 2.0));
            }
        }

        dispatch_queue_attr_t qAttr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
        _hidQueue = dispatch_queue_create("com.vn.utility.batterycheck.hid", qAttr);

        [self resolveSymbols];
        [self setupHIDClient];
        [self setupCaptureSurfaces];
    }
    return self;
}

- (void)resolveSymbols {
    void *iosf = dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_LAZY);
    if (iosf) {
        _fnSurfaceCreate    = (IOSurfaceCreate_f)dlsym(iosf, "IOSurfaceCreate");
        _fnSurfaceAlign     = (IOSurfaceAlignProperty_f)dlsym(iosf, "IOSurfaceAlignProperty");
        _fnSurfaceLock      = (IOSurfaceLock_f)dlsym(iosf, "IOSurfaceLock");
        _fnSurfaceUnlock    = (IOSurfaceUnlock_f)dlsym(iosf, "IOSurfaceUnlock");
        _fnSurfaceBaseAddr  = (IOSurfaceGetBaseAddress_f)dlsym(iosf, "IOSurfaceGetBaseAddress");
        _fnSurfaceAllocSize = (IOSurfaceGetAllocSize_f)dlsym(iosf, "IOSurfaceGetAllocSize");
        _fnAccCreate        = (IOSurfaceAcceleratorCreate_f)dlsym(iosf, "IOSurfaceAcceleratorCreate");
        _fnAccTransfer      = (IOSurfaceAcceleratorTransferSurface_f)dlsym(iosf, "IOSurfaceAcceleratorTransferSurface");
    }

    if (!_fnAccCreate) {
        void *accLib = dlopen("/System/Library/PrivateFrameworks/IOSurfaceAccelerator.framework/IOSurfaceAccelerator", RTLD_LAZY);
        if (accLib) {
            _fnAccCreate   = (IOSurfaceAcceleratorCreate_f)dlsym(accLib, "IOSurfaceAcceleratorCreate");
            _fnAccTransfer = (IOSurfaceAcceleratorTransferSurface_f)dlsym(accLib, "IOSurfaceAcceleratorTransferSurface");
        }
    }

    void *qc = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY);
    if (qc) {
        _fnRenderDisplay = (CARenderServerRenderDisplay_f)dlsym(qc, "CARenderServerRenderDisplay");
    }

    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (iokit) {
        _fnClientCreate    = (IOHIDEventSystemClientCreate_f)dlsym(iokit, "IOHIDEventSystemClientCreate");
        _fnDispatchEvent   = (IOHIDEventSystemClientDispatchEvent_f)dlsym(iokit, "IOHIDEventSystemClientDispatchEvent");
        _fnCreateDigitizer = (IOHIDEventCreateDigitizerEvent_f)dlsym(iokit, "IOHIDEventCreateDigitizerEvent");
        _fnCreateFinger    = (IOHIDEventCreateDigitizerFingerEvent_f)dlsym(iokit, "IOHIDEventCreateDigitizerFingerEvent");
        _fnAppendEvent     = (IOHIDEventAppendEvent_f)dlsym(iokit, "IOHIDEventAppendEvent");
        _fnSetSenderID     = (IOHIDEventSetSenderID_f)dlsym(iokit, "IOHIDEventSetSenderID");
        _fnSetIntVal       = (IOHIDEventSetIntegerValue_f)dlsym(iokit, "IOHIDEventSetIntegerValue");
        _fnSetFloatVal     = (IOHIDEventSetFloatValue_f)dlsym(iokit, "IOHIDEventSetFloatValue");
    }
}

- (void)setupHIDClient {
    if (_fnClientCreate) {
        _hidClient = _fnClientCreate(kCFAllocatorDefault);
    }
}

- (void)refreshHIDClient {
    if (!_fnClientCreate || !_hidQueue) return;
    dispatch_sync(_hidQueue, ^{
        if (self->_hidClient) {
            CFRelease(self->_hidClient);
            self->_hidClient = NULL;
        }
        self->_hidClient = self->_fnClientCreate(kCFAllocatorDefault);
    });
}

- (void)rebuildCaptureSurfaces {
    if (_srcSurface) {
        CFRelease(_srcSurface);
        _srcSurface = NULL;
    }
    if (_dstSurface) {
        CFRelease(_dstSurface);
        _dstSurface = NULL;
    }
    if (_accelerator) {
        CFRelease((CFTypeRef)_accelerator);
        _accelerator = NULL;
    }
    [self setupCaptureSurfaces];
}

- (void)setupCaptureSurfaces {
    if (!_fnSurfaceCreate) return;

    _pixelW = (int)round(_logicalScreenSize.width * _screenScale);
    _pixelH = (int)round(_logicalScreenSize.height * _screenScale);
    int bytesPerElement = 4;
    size_t rawRow = (size_t)(_pixelW * bytesPerElement);
    _bytesPerRow = _fnSurfaceAlign
        ? _fnSurfaceAlign(CFSTR("IOSurfaceBytesPerRow"), rawRow)
        : ((rawRow + 63) & ~((size_t)63));
    if (_bytesPerRow < rawRow) {
        _bytesPerRow = ((rawRow + 63) & ~((size_t)63));
    }
    size_t allocSize = _bytesPerRow * (size_t)_pixelH;

    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CFPropertyListRef csProp = cs ? CGColorSpaceCopyPropertyList(cs) : NULL;
    if (cs) CGColorSpaceRelease(cs);

    NSMutableDictionary *props = [@{
        @"IOSurfaceBytesPerElement": @(bytesPerElement),
        @"IOSurfaceBytesPerRow":     @(_bytesPerRow),
        @"IOSurfaceWidth":           @(_pixelW),
        @"IOSurfaceHeight":          @(_pixelH),
        @"IOSurfacePixelFormat":     @(0x42475241), // 'BGRA'
        @"IOSurfaceAllocSize":       @(allocSize)
    } mutableCopy];

    if (csProp) {
        props[@"IOSurfaceColorSpace"] = CFBridgingRelease(csProp);
    }

    _srcSurface = _fnSurfaceCreate((__bridge CFDictionaryRef)props);
    _dstSurface = _fnSurfaceCreate((__bridge CFDictionaryRef)props);

    if (_fnAccCreate) {
        _fnAccCreate(kCFAllocatorDefault, NULL, &_accelerator);
    }
}

- (BOOL)inspectSurfacePixelsAndSensors:(IOSurfaceRef)surface updateMetrics:(BOOL)updateMetrics {
    if (!surface || !_fnSurfaceLock || !_fnSurfaceUnlock || !_fnSurfaceBaseAddr || !_fnSurfaceAllocSize) return NO;

    _fnSurfaceLock(surface, kIOSurfaceLockReadOnlyFlag, NULL);
    const uint8_t *base = (const uint8_t *)_fnSurfaceBaseAddr(surface);
    size_t totalBytes   = _fnSurfaceAllocSize(surface);

    if (!base || totalBytes < _bytesPerRow * (size_t)_pixelH || _pixelW < 100 || _pixelH < 100) {
        _fnSurfaceUnlock(surface, kIOSurfaceLockReadOnlyFlag, NULL);
        return NO;
    }

    BOOL nonZero = NO;
    const uint32_t *u32 = (const uint32_t *)base;
    size_t count = totalBytes / sizeof(uint32_t);
    size_t step = count / 97;
    if (step == 0) step = 1;
    for (size_t i = step; i < count; i += step) {
        if ((u32[i] & 0x00FFFFFF) != 0) {
            nonZero = YES;
            break;
        }
    }

    if (nonZero && updateMetrics) {
        // 1. Sample 16x16 UI grid ( focusing on y = 25%..97% where Xanh SM cards/buttons live so map shimmer is minimized )
        int idx = 0;
        NSInteger changed = 0;
        for (int gy = 0; gy < kGridDim; gy++) {
            // Focus y from 6% to 97%
            int py = (int)((0.06 + (0.91 * (double)gy / (double)(kGridDim - 1))) * (double)(_pixelH - 1));
            const uint8_t *row = base + (size_t)py * _bytesPerRow;
            for (int gx = 0; gx < kGridDim; gx++) {
                int px = (int)((0.08 + (0.84 * (double)gx / (double)(kGridDim - 1))) * (double)(_pixelW - 1));
                uint32_t bgra = *((const uint32_t *)(row + (size_t)px * 4));
                uint8_t b = bgra & 0xFF;
                uint8_t g = (bgra >> 8) & 0xFF;
                uint8_t r = (bgra >> 16) & 0xFF;

                _currentR[idx] = r;
                _currentG[idx] = g;
                _currentB[idx] = b;

                // Weight UI card & header zones (y < 22% or y > 52%) strictly; ignore minor GPS map tile drift in middle
                int thresh = (gy >= 4 && gy <= 8) ? 38 : 22;
                if (!_hasAnalyzedBaseline ||
                    abs((int)r - (int)_analyzedR[idx]) >= thresh ||
                    abs((int)g - (int)_analyzedG[idx]) >= thresh ||
                    abs((int)b - (int)_analyzedB[idx]) >= thresh) {
                    changed++;
                }
                idx++;
            }
        }
        _lastFrameChangedSamples = changed;

        // 2. Fast Order Popup Sensor (0.01ms): Teal 'Nhận chuyến' button at y ~ 95.8% + White card at y ~ 15.0%
        int yAccept   = (int)(0.958 * (double)(_pixelH - 1));
        int yFareCard = (int)(0.155 * (double)(_pixelH - 1));
        int yMidCard  = (int)(0.340 * (double)(_pixelH - 1));
        int yGMapTop  = (int)(0.095 * (double)(_pixelH - 1));
        int yGMapSub  = (int)(0.135 * (double)(_pixelH - 1));
        const uint8_t *rowAccept = base + (size_t)yAccept * _bytesPerRow;
        const uint8_t *rowFare   = base + (size_t)yFareCard * _bytesPerRow;
        const uint8_t *rowMid    = base + (size_t)yMidCard * _bytesPerRow;
        const uint8_t *rowGMTop  = base + (size_t)yGMapTop * _bytesPerRow;
        const uint8_t *rowGMSub  = base + (size_t)yGMapSub * _bytesPerRow;

        int tealHits      = 0;
        int whiteHits     = 0;
        int gmapsGreenHit = 0;
        for (int s = 0; s < 12; s++) {
            int px = (int)((0.16 + (0.68 * (double)s / 11.0)) * (double)(_pixelW - 1));
            uint32_t pAcc = *((const uint32_t *)(rowAccept + (size_t)px * 4));
            uint8_t bA = pAcc & 0xFF, gA = (pAcc >> 8) & 0xFF, rA = (pAcc >> 16) & 0xFF;
            if (gA >= 110 && bA >= 110 && (int)gA - (int)rA >= 45 && (int)bA - (int)rA >= 45) {
                tealHits++;
            }

            uint32_t pFare = *((const uint32_t *)(rowFare + (size_t)px * 4));
            uint8_t bF = pFare & 0xFF, gF = (pFare >> 8) & 0xFF, rF = (pFare >> 16) & 0xFF;
            uint32_t pMid = *((const uint32_t *)(rowMid + (size_t)px * 4));
            uint8_t bM = pMid & 0xFF, gM = (pMid >> 8) & 0xFF, rM = (pMid >> 16) & 0xFF;
            if ((rF >= 232 && gF >= 232 && bF >= 232) || (rM >= 235 && gM >= 235 && bM >= 235)) {
                whiteHits++;
            }

            uint32_t pG1 = *((const uint32_t *)(rowGMTop + (size_t)px * 4));
            uint8_t bG1 = pG1 & 0xFF, gG1 = (pG1 >> 8) & 0xFF, rG1 = (pG1 >> 16) & 0xFF;
            uint32_t pG2 = *((const uint32_t *)(rowGMSub + (size_t)px * 4));
            uint8_t bG2 = pG2 & 0xFF, gG2 = (pG2 >> 8) & 0xFF, rG2 = (pG2 >> 16) & 0xFF;
            BOOL topGreen = (gG1 >= 95 && rG1 <= 65 && (int)gG1 - (int)rG1 >= 50 && (int)gG1 - (int)bG1 >= 18);
            BOOL subGreen = (gG2 >= 95 && rG2 <= 65 && (int)gG2 - (int)rG2 >= 50 && (int)gG2 - (int)bG2 >= 18);
            if (topGreen || subGreen) {
                gmapsGreenHit++;
            }
        }
        _lastFrameLikelyHasOrderPopup    = (tealHits >= 5 && whiteHits >= 6);
        _lastFrameLooksLikeGoogleMapsNav = (!_lastFrameLikelyHasOrderPopup && gmapsGreenHit >= 8);

        // 3. Top Header Flush Sensor (0.01ms): Ensures Order Popup header bar is still flush at y ~ 52pt
        //    (On Lobby, the '454.970đ' pill + map sits at y=52pt, so pureWhiteHeader drops to <= 4/10 immediately!)
        int yHdr52 = (int)((52.0 / 667.0) * (double)(_pixelH - 1));
        const uint8_t *rowHdr52 = base + (size_t)yHdr52 * _bytesPerRow;
        int pureWhiteHdrHits = 0;
        for (int s = 0; s < 10; s++) {
            int px = (int)((0.35 + (0.43 * (double)s / 9.0)) * (double)(_pixelW - 1));
            uint32_t pH = *((const uint32_t *)(rowHdr52 + (size_t)px * 4));
            uint8_t bH = pH & 0xFF, gH = (pH >> 8) & 0xFF, rH = (pH >> 16) & 0xFF;
            if (rH >= 248 && gH >= 248 && bH >= 248 &&
                abs((int)rH - (int)gH) <= 4 && abs((int)gH - (int)bH) <= 4) {
                pureWhiteHdrHits++;
            }
        }
        _lastFrameHasOrderHeaderAtTop = (_lastFrameLikelyHasOrderPopup && pureWhiteHdrHits >= 7);

        // 3b. Yellow Dropoff Ring ◉ Sensor (0.005ms): Finds exact Y separator between Điểm Nhận & Điểm Giao
        if (_lastFrameLikelyHasOrderPopup && _logicalScreenSize.width > 100.0 && _logicalScreenSize.height > 100.0) {
            double ySum   = 0.0;
            int yellowCnt = 0;
            int yLo = (int)(0.36 * _logicalScreenSize.height);
            int yHi = (int)(0.86 * _logicalScreenSize.height);
            int xLo = (int)(0.038 * _logicalScreenSize.width);
            int xHi = (int)(0.115 * _logicalScreenSize.width);
            for (int ly = yLo; ly <= yHi; ly += 2) {
                int py = (int)(((double)ly / _logicalScreenSize.height) * (double)(_pixelH - 1));
                const uint8_t *rowY = base + (size_t)py * _bytesPerRow;
                for (int lx = xLo; lx <= xHi; lx += 2) {
                    int px = (int)(((double)lx / _logicalScreenSize.width) * (double)(_pixelW - 1));
                    uint32_t pY = *((const uint32_t *)(rowY + (size_t)px * 4));
                    uint8_t bY = pY & 0xFF, gY = (pY >> 8) & 0xFF, rY = (pY >> 16) & 0xFF;
                    if (rY >= 210 && gY >= 135 && gY <= 230 && bY <= 85 && ((int)rY - (int)bY >= 140)) {
                        ySum += (double)ly;
                        yellowCnt++;
                    }
                }
            }
            _lastOrderYellowDotY = (yellowCnt >= 6) ? (ySum / (double)yellowCnt) : 0.0;
        } else {
            _lastOrderYellowDotY = 0.0;
        }

        // 4. Blue Navigation Circle Sensor (0.01ms): Detects blue [Map] circle around x ~ 323pt (y = 185..475pt)
        //    Wakes OCR immediately even when the map & sheet are 100% motionless after accepting an order!
        int blueNavHits = 0;
        int xNavCols[3] = {
            (int)((315.0 / 375.0) * (double)(_pixelW - 1)),
            (int)((323.0 / 375.0) * (double)(_pixelW - 1)),
            (int)((331.0 / 375.0) * (double)(_pixelW - 1))
        };
        for (int ly = 188; ly <= 472; ly += 6) {
            int py = (int)(((double)ly / 667.0) * (double)(_pixelH - 1));
            const uint8_t *rowNav = base + (size_t)py * _bytesPerRow;
            for (int c = 0; c < 3; c++) {
                uint32_t pN = *((const uint32_t *)(rowNav + (size_t)xNavCols[c] * 4));
                uint8_t bN = pN & 0xFF, gN = (pN >> 8) & 0xFF, rN = (pN >> 16) & 0xFF;
                if (bN >= 165 && rN <= 48 && gN >= 85 && gN <= 170 && ((int)bN - (int)rN >= 125)) {
                    blueNavHits++;
                }
            }
        }
        _lastFrameLikelyHasBlueNavButton = (!_lastFrameLikelyHasOrderPopup && blueNavHits >= 6);

        // 5. Uncovered Lobby Teal [Power] Circle Sensor around (40, 455) (0.01ms):
        //    Hits ONLY when Online [Power] button is bright uncovered teal (not dimmed by 0.0/8 modal backdrop!)
        static const double kPwrRingX[6] = { 28.0/375.0, 52.0/375.0, 40.0/375.0, 40.0/375.0, 31.0/375.0, 49.0/375.0 };
        static const double kPwrRingY[6] = { 455.0/667.0, 455.0/667.0, 441.0/667.0, 469.0/667.0, 445.0/667.0, 465.0/667.0 };
        int pwrRingHits = 0;
        for (int k = 0; k < 6; k++) {
            int px = (int)(kPwrRingX[k] * (double)(_pixelW - 1));
            int py = (int)(kPwrRingY[k] * (double)(_pixelH - 1));
            uint32_t pP = *((const uint32_t *)(base + (size_t)py * _bytesPerRow + (size_t)px * 4));
            uint8_t bP = pP & 0xFF, gP = (pP >> 8) & 0xFF, rP = (pP >> 16) & 0xFF;
            if (gP >= 175 && bP >= 180 && rP <= 85 && ((int)gP - (int)rP >= 100)) {
                pwrRingHits++;
            }
        }
        _lastFrameLikelyHasLobbyPowerButton = (!_lastFrameLikelyHasOrderPopup && pwrRingHits >= 4);
    }

    _fnSurfaceUnlock(surface, kIOSurfaceLockReadOnlyFlag, NULL);
    return nonZero;
}

- (void)markCurrentFrameAnalyzed {
    memcpy(_analyzedR, _currentR, kGridCount);
    memcpy(_analyzedG, _currentG, kGridCount);
    memcpy(_analyzedB, _currentB, kGridCount);
    _hasAnalyzedBaseline = YES;
}

- (void)invalidateAnalyzedBaseline {
    _hasAnalyzedBaseline = NO;
    _lastFrameChangedSamples = kGridCount;
}

- (CIImage *)captureScreenCIImage {
    if (!_fnRenderDisplay || !_srcSurface) {
        _lastCaptureHadPixels               = NO;
        _lastFrameLikelyHasOrderPopup       = NO;
        _lastFrameHasOrderHeaderAtTop       = NO;
        _lastFrameLikelyHasBlueNavButton    = NO;
        _lastFrameLikelyHasLobbyPowerButton = NO;
        _lastOrderYellowDotY                = 0.0;
        return nil;
    }

    _fnRenderDisplay(0, CFSTR("LCD"), _srcSurface, 0, 0);

    IOSurfaceRef activeSurface = _srcSurface;
    BOOL hasPixels = NO;

    if (_accelerator && _fnAccTransfer && _dstSurface) {
        kern_return_t kr = _fnAccTransfer(_accelerator, _srcSurface, _dstSurface, NULL, NULL, NULL, NULL);
        if (kr == KERN_SUCCESS && [self inspectSurfacePixelsAndSensors:_dstSurface updateMetrics:YES]) {
            activeSurface = _dstSurface;
            hasPixels = YES;
        }
    }

    if (!hasPixels && [self inspectSurfacePixelsAndSensors:_srcSurface updateMetrics:YES]) {
        activeSurface = _srcSurface;
        hasPixels = YES;
    }

    if (!hasPixels) {
        _fnRenderDisplay(0, NULL, _srcSurface, 0, 0);
        if ([self inspectSurfacePixelsAndSensors:_srcSurface updateMetrics:YES]) {
            activeSurface = _srcSurface;
            hasPixels = YES;
        }
    }

    _lastCaptureHadPixels = hasPixels;
    if (!hasPixels) {
        _lastFrameLikelyHasOrderPopup       = NO;
        _lastFrameHasOrderHeaderAtTop       = NO;
        _lastFrameLikelyHasBlueNavButton    = NO;
        _lastFrameLikelyHasLobbyPowerButton = NO;
        _lastFrameLooksLikeGoogleMapsNav    = NO;
        _lastOrderYellowDotY                = 0.0;
        _consecutiveEmptyCaptures++;
        if (_consecutiveEmptyCaptures >= 3) {
            _consecutiveEmptyCaptures = 0;
            [self rebuildCaptureSurfaces];
            [self refreshHIDClient];
        }
        return nil;
    }
    _consecutiveEmptyCaptures = 0;

    return [CIImage imageWithIOSurface:activeSurface];
}

- (void)dispatchTouchMode:(TouchPhaseMode)mode normX:(double)nx normY:(double)ny {
    if (!_hidClient || !_fnCreateDigitizer || !_fnCreateFinger || !_fnAppendEvent || !_fnDispatchEvent) return;

    dispatch_sync(_hidQueue, ^{
        uint64_t now = mach_absolute_time();
        BOOL isDown = (mode != TouchPhaseUp);
        uint32_t eventMask = (mode == TouchPhaseMove)
            ? kIOHIDDigitizerEventPosition
            : (kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventIdentity);

        IOHIDEventRef parent = self->_fnCreateDigitizer(
            kCFAllocatorDefault,
            now,
            kIOHIDDigitizerTransducerTypeHand,
            0,
            0,
            eventMask,
            0,
            0.0, 0.0, 0.0,
            0.0, 0.0,
            0,
            isDown ? 1 : 0,
            0
        );
        if (!parent) return;

        if (self->_fnSetIntVal) {
            self->_fnSetIntVal(parent, kIOHIDEventFieldIsBuiltIn, 1);
            self->_fnSetIntVal(parent, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
        }

        IOHIDEventRef child = self->_fnCreateFinger(
            kCFAllocatorDefault,
            now,
            2,
            2,
            eventMask,
            nx, ny, 0.0,
            0.0,
            90.0,
            isDown ? 1 : 0,
            isDown ? 1 : 0,
            0
        );

        if (child) {
            if (self->_fnSetFloatVal) {
                IOHIDFloat radius = isDown ? 5.0 : 0.0;
                self->_fnSetFloatVal(child, kIOHIDEventFieldDigitizerMinorRadius, radius);
                self->_fnSetFloatVal(child, kIOHIDEventFieldDigitizerMajorRadius, radius);
            }
            self->_fnAppendEvent(parent, child, 0);
            CFRelease(child);
        }

        if (self->_fnSetSenderID) {
            self->_fnSetSenderID(parent, 0x8000000817319371ULL);
        }

        self->_fnDispatchEvent(self->_hidClient, parent);
        CFRelease(parent);
    });
}

- (BOOL)performHumanTapAtPoint:(CGPoint)logicalPoint
                  jitterRadius:(double)jitterRadiusPt
                     holdMinMs:(NSInteger)holdMinMs
                     holdMaxMs:(NSInteger)holdMaxMs
                outActualPoint:(CGPoint *)outActualPoint {
    if (!_hidClient || !_fnDispatchEvent) return NO;

    double jx = 0.0, jy = 0.0;
    if (jitterRadiusPt > 0.1) {
        double u1 = (double)arc4random() / (double)UINT32_MAX;
        double u2 = (double)arc4random() / (double)UINT32_MAX;
        double r  = jitterRadiusPt * sqrt(u1);
        double th = 2.0 * M_PI * u2;
        jx = r * cos(th);
        jy = r * sin(th);
    }

    double finalX = fmax(4.0, fmin(_logicalScreenSize.width - 4.0, logicalPoint.x + jx));
    double finalY = fmax(4.0, fmin(_logicalScreenSize.height - 4.0, logicalPoint.y + jy));

    if (outActualPoint) {
        *outActualPoint = CGPointMake(finalX, finalY);
    }

    double nx = finalX / _logicalScreenSize.width;
    double ny = finalY / _logicalScreenSize.height;

    NSInteger lo = MAX(25, holdMinMs);
    NSInteger hi = MAX(lo + 5, holdMaxMs);
    uint32_t holdMs = (uint32_t)(lo + arc4random_uniform((uint32_t)(hi - lo + 1)));

    [self dispatchTouchMode:TouchPhaseDown normX:nx normY:ny];
    usleep(holdMs * 1000);
    [self dispatchTouchMode:TouchPhaseUp normX:nx normY:ny];

    return YES;
}

- (BOOL)performMultiTapAtPoint:(CGPoint)logicalPoint
                      tapCount:(NSInteger)tapCount
                    intervalMs:(NSInteger)intervalMs
                  jitterRadius:(double)jitterRadiusPt
                     holdMinMs:(NSInteger)holdMinMs
                     holdMaxMs:(NSInteger)holdMaxMs
                  outLastPoint:(CGPoint *)outLastPoint {
    NSInteger count = MAX(1, MIN(5, tapCount));
    NSInteger gapMs = MAX(80, intervalMs);
    BOOL anyOk = NO;
    for (NSInteger i = 0; i < count; i++) {
        BOOL ok = [self performHumanTapAtPoint:logicalPoint
                                  jitterRadius:jitterRadiusPt
                                     holdMinMs:holdMinMs
                                     holdMaxMs:holdMaxMs
                                outActualPoint:outLastPoint];
        if (ok) anyOk = YES;
        if (i + 1 < count) {
            uint32_t jitterGap = (uint32_t)(gapMs + arc4random_uniform(35));
            usleep(jitterGap * 1000);
        }
    }
    return anyOk;
}

- (BOOL)performQuickSwipeFromPoint:(CGPoint)startPt
                           toPoint:(CGPoint)endPt
                        durationMs:(NSInteger)durationMs {
    if (!_hidClient || !_fnDispatchEvent) return NO;

    int steps = 6;
    NSInteger totalMs = MAX(35, durationMs);
    useconds_t stepUs = (useconds_t)((totalMs * 1000) / steps);

    double sx = fmax(2.0, fmin(_logicalScreenSize.width - 2.0, startPt.x)) / _logicalScreenSize.width;
    double sy = fmax(2.0, fmin(_logicalScreenSize.height - 2.0, startPt.y)) / _logicalScreenSize.height;
    double ex = fmax(2.0, fmin(_logicalScreenSize.width - 2.0, endPt.x)) / _logicalScreenSize.width;
    double ey = fmax(2.0, fmin(_logicalScreenSize.height - 2.0, endPt.y)) / _logicalScreenSize.height;

    [self dispatchTouchMode:TouchPhaseDown normX:sx normY:sy];
    for (int i = 1; i <= steps; i++) {
        usleep(stepUs);
        double t = (double)i / (double)steps;
        double mx = sx + (ex - sx) * t;
        double my = sy + (ey - sy) * t;
        [self dispatchTouchMode:TouchPhaseMove normX:mx normY:my];
    }
    usleep(8000);
    [self dispatchTouchMode:TouchPhaseUp normX:ex normY:ey];
    return YES;
}

@end
