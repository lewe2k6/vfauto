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
#define kIOHIDDigitizerTransducerTypeHand           3
#define kIOHIDDigitizerEventRange                   (1 << 0)
#define kIOHIDDigitizerEventTouch                   (1 << 1)
#define kIOHIDDigitizerEventPosition                (1 << 2)
#define kIOHIDDigitizerEventIdentity                (1 << 5)

#define kIOHIDEventFieldIsBuiltIn                   4
#define kIOHIDEventFieldDigitizerMajorRadius        0xB0014
#define kIOHIDEventFieldDigitizerMinorRadius        0xB0015
#define kIOHIDEventFieldDigitizerIsDisplayIntegrated 0xB0019

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
        _logicalScreenSize    = CGSizeMake(kDefaultScreenW, kDefaultScreenH);
        _screenScale          = 2.0;
        _lastCaptureHadPixels = NO;

        // Detect exact physical pixel resolution via _unjailedReferenceBoundsInPixels or CADisplay
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

- (void)setupCaptureSurfaces {
    if (!_fnSurfaceCreate) return;

    int pixelW = (int)round(_logicalScreenSize.width * _screenScale);
    int pixelH = (int)round(_logicalScreenSize.height * _screenScale);
    int bytesPerElement = 4;
    size_t rawRow = (size_t)(pixelW * bytesPerElement);
    size_t bytesPerRow = _fnSurfaceAlign
        ? _fnSurfaceAlign(CFSTR("IOSurfaceBytesPerRow"), rawRow)
        : ((rawRow + 63) & ~((size_t)63));
    if (bytesPerRow < rawRow) {
        bytesPerRow = ((rawRow + 63) & ~((size_t)63));
    }
    size_t allocSize = bytesPerRow * (size_t)pixelH;

    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CFPropertyListRef csProp = cs ? CGColorSpaceCopyPropertyList(cs) : NULL;
    if (cs) CGColorSpaceRelease(cs);

    NSMutableDictionary *props = [@{
        @"IOSurfaceBytesPerElement": @(bytesPerElement),
        @"IOSurfaceBytesPerRow":     @(bytesPerRow),
        @"IOSurfaceWidth":           @(pixelW),
        @"IOSurfaceHeight":          @(pixelH),
        @"IOSurfacePixelFormat":     @(0x42475241), // 'BGRA' / 'ARGB'
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

- (BOOL)surfaceHasNonZeroContent:(IOSurfaceRef)surface {
    if (!surface || !_fnSurfaceLock || !_fnSurfaceUnlock || !_fnSurfaceBaseAddr || !_fnSurfaceAllocSize) return NO;
    _fnSurfaceLock(surface, kIOSurfaceLockReadOnlyFlag, NULL);
    const uint32_t *pixels = (const uint32_t *)_fnSurfaceBaseAddr(surface);
    size_t totalBytes = _fnSurfaceAllocSize(surface);
    size_t count = totalBytes / sizeof(uint32_t);
    BOOL nonZero = NO;
    if (pixels && count > 1000) {
        size_t step = count / 97;
        if (step == 0) step = 1;
        for (size_t i = step; i < count; i += step) {
            if ((pixels[i] & 0x00FFFFFF) != 0) {
                nonZero = YES;
                break;
            }
        }
    }
    _fnSurfaceUnlock(surface, kIOSurfaceLockReadOnlyFlag, NULL);
    return nonZero;
}

- (CIImage *)captureScreenCIImage {
    if (!_fnRenderDisplay || !_srcSurface) {
        _lastCaptureHadPixels = NO;
        return nil;
    }

    // 1. Primary path (exact TrollVNC iOS 16 pipeline): CARenderServerRenderDisplay -> IOSurfaceAcceleratorTransferSurface
    _fnRenderDisplay(0, CFSTR("LCD"), _srcSurface, 0, 0);

    IOSurfaceRef activeSurface = _srcSurface;
    if (_accelerator && _fnAccTransfer && _dstSurface) {
        kern_return_t kr = _fnAccTransfer(_accelerator, _srcSurface, _dstSurface, NULL, NULL, NULL, NULL);
        if (kr == KERN_SUCCESS && [self surfaceHasNonZeroContent:_dstSurface]) {
            activeSurface = _dstSurface;
        }
    }

    BOOL hasPixels = [self surfaceHasNonZeroContent:activeSurface];
    if (!hasPixels && activeSurface != _srcSurface && [self surfaceHasNonZeroContent:_srcSurface]) {
        activeSurface = _srcSurface;
        hasPixels = YES;
    }

    // Fallback display name if LCD returned empty
    if (!hasPixels) {
        _fnRenderDisplay(0, NULL, _srcSurface, 0, 0);
        if ([self surfaceHasNonZeroContent:_srcSurface]) {
            activeSurface = _srcSurface;
            hasPixels = YES;
        }
    }

    _lastCaptureHadPixels = hasPixels;
    if (!hasPixels) {
        return nil;
    }

    return [CIImage imageWithIOSurface:activeSurface];
}

- (void)dispatchTouchPhase:(BOOL)isDown normX:(double)nx normY:(double)ny {
    if (!_hidClient || !_fnCreateDigitizer || !_fnCreateFinger || !_fnAppendEvent || !_fnDispatchEvent) return;

    dispatch_sync(_hidQueue, ^{
        uint64_t now = mach_absolute_time();
        uint32_t eventMask = kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventIdentity;

        // Parent Hand collection event (exact STHIDEventGenerator iOS 16 layout)
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

        // Child Finger event
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
            // Verified iOS 15 - iOS 26 digitizer SenderID used by TrollVNC
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

    [self dispatchTouchPhase:YES normX:nx normY:ny];
    usleep(holdMs * 1000);
    [self dispatchTouchPhase:NO normX:nx normY:ny];

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

@end
