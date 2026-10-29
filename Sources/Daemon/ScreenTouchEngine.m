#import "ScreenTouchEngine.h"
#import "SharedConfig.h"
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <math.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

typedef double IOHIDFloat;
typedef uint32_t IOOptionBits;
typedef CFTypeRef IOHIDEventRef;
typedef CFTypeRef IOHIDEventSystemClientRef;
typedef CFTypeRef IOHIDServiceClientRef;

typedef IOSurfaceRef (*IOSurfaceCreate_f)(CFDictionaryRef properties);
typedef kern_return_t (*IOSurfaceLock_f)(IOSurfaceRef buffer, uint32_t options, uint32_t *seed);
typedef kern_return_t (*IOSurfaceUnlock_f)(IOSurfaceRef buffer, uint32_t options, uint32_t *seed);
typedef void *(*IOSurfaceGetBaseAddress_f)(IOSurfaceRef buffer);
typedef size_t (*IOSurfaceGetAllocSize_f)(IOSurfaceRef buffer);
#define kIOSurfaceLockReadOnlyFlag 0x00000001

typedef void (*CARenderServerRenderDisplay_f)(kern_return_t, CFStringRef, IOSurfaceRef, int, int);

typedef IOHIDEventSystemClientRef (*IOHIDEventSystemClientCreate_f)(CFAllocatorRef);
typedef void (*IOHIDEventSystemClientSetMatching_f)(IOHIDEventSystemClientRef, CFDictionaryRef);
typedef CFArrayRef (*IOHIDEventSystemClientCopyServices_f)(IOHIDEventSystemClientRef);
typedef CFTypeRef (*IOHIDServiceClientGetRegistryID_f)(IOHIDServiceClientRef);
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

#define kHIDTransducerHand              3
#define kHIDDigitizerRange              (1 << 0)
#define kHIDDigitizerTouch              (1 << 1)
#define kHIDDigitizerPosition           (1 << 2)
#define kHIDFieldDigitizerIsIntegrated  0xB0019

@implementation ScreenTouchEngine {
    IOSurfaceCreate_f _fnSurfaceCreate;
    IOSurfaceLock_f _fnSurfaceLock;
    IOSurfaceUnlock_f _fnSurfaceUnlock;
    IOSurfaceGetBaseAddress_f _fnSurfaceBaseAddr;
    IOSurfaceGetAllocSize_f _fnSurfaceAllocSize;

    CARenderServerRenderDisplay_f _fnRenderDisplay;
    IOHIDEventSystemClientCreate_f _fnClientCreate;
    IOHIDEventSystemClientSetMatching_f _fnClientSetMatching;
    IOHIDEventSystemClientCopyServices_f _fnClientCopyServices;
    IOHIDServiceClientGetRegistryID_f _fnServiceGetRegID;
    IOHIDEventSystemClientDispatchEvent_f _fnDispatchEvent;
    IOHIDEventCreateDigitizerEvent_f _fnCreateDigitizer;
    IOHIDEventCreateDigitizerFingerEvent_f _fnCreateFinger;
    IOHIDEventAppendEvent_f _fnAppendEvent;
    IOHIDEventSetSenderID_f _fnSetSenderID;
    IOHIDEventSetIntegerValue_f _fnSetIntVal;

    IOHIDEventSystemClientRef _hidClient;
    uint64_t _digitizerSenderID;
    IOSurfaceRef _captureSurface;
    NSString *_activeDisplayName;
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
        _logicalScreenSize = CGSizeMake(kDefaultScreenW, kDefaultScreenH);
        _screenScale = 2.0;

        // Dynamically query CADisplay.mainDisplay physical pixel size if available
        Class caDispCls = NSClassFromString(@"CADisplay");
        if (caDispCls && [caDispCls respondsToSelector:NSSelectorFromString(@"mainDisplay")]) {
            id mainDisp = [caDispCls valueForKey:@"mainDisplay"];
            if (mainDisp) {
                NSValue *boundsVal = [mainDisp valueForKey:@"bounds"];
                if (boundsVal && strcmp([boundsVal objCType], @encode(CGRect)) == 0) {
                    CGRect pxBounds = CGRectZero;
                    [boundsVal getValue:&pxBounds];
                    if (pxBounds.size.width >= 640 && pxBounds.size.height >= 1136) {
                        if ((int)pxBounds.size.width == 750 && (int)pxBounds.size.height == 1334) {
                            _logicalScreenSize = CGSizeMake(375.0, 667.0);
                            _screenScale = 2.0;
                        } else if ((int)pxBounds.size.width == 1242 || (int)pxBounds.size.width == 1170 || (int)pxBounds.size.width == 1125) {
                            _screenScale = 3.0;
                            _logicalScreenSize = CGSizeMake(pxBounds.size.width / 3.0, pxBounds.size.height / 3.0);
                        }
                    }
                }
            }
        }

        [self resolveSymbols];
        [self setupDigitizerSender];
        [self setupCaptureSurface];
    }
    return self;
}

- (void)resolveSymbols {
    void *iosf = dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_LAZY);
    if (iosf) {
        _fnSurfaceCreate    = (IOSurfaceCreate_f)dlsym(iosf, "IOSurfaceCreate");
        _fnSurfaceLock      = (IOSurfaceLock_f)dlsym(iosf, "IOSurfaceLock");
        _fnSurfaceUnlock    = (IOSurfaceUnlock_f)dlsym(iosf, "IOSurfaceUnlock");
        _fnSurfaceBaseAddr  = (IOSurfaceGetBaseAddress_f)dlsym(iosf, "IOSurfaceGetBaseAddress");
        _fnSurfaceAllocSize = (IOSurfaceGetAllocSize_f)dlsym(iosf, "IOSurfaceGetAllocSize");
    }

    void *qc = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY);
    if (qc) {
        _fnRenderDisplay = (CARenderServerRenderDisplay_f)dlsym(qc, "CARenderServerRenderDisplay");
    }

    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (iokit) {
        _fnClientCreate       = (IOHIDEventSystemClientCreate_f)dlsym(iokit, "IOHIDEventSystemClientCreate");
        _fnClientSetMatching  = (IOHIDEventSystemClientSetMatching_f)dlsym(iokit, "IOHIDEventSystemClientSetMatching");
        _fnClientCopyServices = (IOHIDEventSystemClientCopyServices_f)dlsym(iokit, "IOHIDEventSystemClientCopyServices");
        _fnServiceGetRegID    = (IOHIDServiceClientGetRegistryID_f)dlsym(iokit, "IOHIDServiceClientGetRegistryID");
        _fnDispatchEvent      = (IOHIDEventSystemClientDispatchEvent_f)dlsym(iokit, "IOHIDEventSystemClientDispatchEvent");
        _fnCreateDigitizer    = (IOHIDEventCreateDigitizerEvent_f)dlsym(iokit, "IOHIDEventCreateDigitizerEvent");
        _fnCreateFinger       = (IOHIDEventCreateDigitizerFingerEvent_f)dlsym(iokit, "IOHIDEventCreateDigitizerFingerEvent");
        _fnAppendEvent        = (IOHIDEventAppendEvent_f)dlsym(iokit, "IOHIDEventAppendEvent");
        _fnSetSenderID        = (IOHIDEventSetSenderID_f)dlsym(iokit, "IOHIDEventSetSenderID");
        _fnSetIntVal          = (IOHIDEventSetIntegerValue_f)dlsym(iokit, "IOHIDEventSetIntegerValue");
    }
}

- (void)setupDigitizerSender {
    _digitizerSenderID = 0x8000000817319372ULL;
    if (!_fnClientCreate) return;

    _hidClient = _fnClientCreate(kCFAllocatorDefault);
    if (!_hidClient || !_fnClientCopyServices || !_fnServiceGetRegID) return;

    if (_fnClientSetMatching) {
        NSDictionary *match = @{ @"PrimaryUsagePage": @(0x0D), @"PrimaryUsage": @(0x04) };
        _fnClientSetMatching(_hidClient, (__bridge CFDictionaryRef)match);
    }

    CFArrayRef services = _fnClientCopyServices(_hidClient);
    if (services) {
        CFIndex count = CFArrayGetCount(services);
        for (CFIndex i = 0; i < count; i++) {
            IOHIDServiceClientRef svc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
            CFTypeRef regObj = _fnServiceGetRegID(svc);
            if (regObj && CFGetTypeID(regObj) == CFNumberGetTypeID()) {
                uint64_t sid = 0;
                CFNumberGetValue((CFNumberRef)regObj, kCFNumberSInt64Type, &sid);
                if (sid != 0) {
                    _digitizerSenderID = sid;
                    break;
                }
            }
        }
        CFRelease(services);
    }
}

- (void)setupCaptureSurface {
    if (!_fnSurfaceCreate) return;
    size_t pixelW = (size_t)(_logicalScreenSize.width * _screenScale);
    size_t pixelH = (size_t)(_logicalScreenSize.height * _screenScale);
    size_t bytesPerElement = 4;
    size_t bytesPerRow = ((pixelW * bytesPerElement + 63) & ~63);
    size_t allocSize = bytesPerRow * pixelH;

    NSDictionary *props = @{
        @"IOSurfaceIsGlobal":        @YES,
        @"IOSurfaceWidth":           @(pixelW),
        @"IOSurfaceHeight":          @(pixelH),
        @"IOSurfaceBytesPerElement": @(bytesPerElement),
        @"IOSurfaceBytesPerRow":     @(bytesPerRow),
        @"IOSurfaceAllocSize":       @(allocSize),
        @"IOSurfacePixelFormat":     @(0x42475241)
    };

    _captureSurface = _fnSurfaceCreate((__bridge CFDictionaryRef)props);
    _activeDisplayName = @"LCD";
}

- (BOOL)surfaceHasNonZeroContent:(IOSurfaceRef)surface {
    if (!surface || !_fnSurfaceLock || !_fnSurfaceUnlock || !_fnSurfaceBaseAddr || !_fnSurfaceAllocSize) return NO;
    _fnSurfaceLock(surface, kIOSurfaceLockReadOnlyFlag, NULL);
    const uint32_t *pixels = (const uint32_t *)_fnSurfaceBaseAddr(surface);
    size_t totalBytes = _fnSurfaceAllocSize(surface);
    size_t count = totalBytes / sizeof(uint32_t);
    BOOL nonZero = NO;
    if (pixels && count > 1000) {
        size_t step = count / 33;
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
    if (!_fnRenderDisplay || !_captureSurface || !_fnSurfaceLock || !_fnSurfaceUnlock) return nil;

    _fnSurfaceLock(_captureSurface, 0, NULL);
    _fnRenderDisplay(0, (__bridge CFStringRef)_activeDisplayName, _captureSurface, 0, 0);
    _fnSurfaceUnlock(_captureSurface, 0, NULL);

    if (![self surfaceHasNonZeroContent:_captureSurface]) {
        NSArray<NSString *> *fallbacks = @[@"Main", @"TVOut"];
        for (NSString *alt in fallbacks) {
            _fnSurfaceLock(_captureSurface, 0, NULL);
            _fnRenderDisplay(0, (__bridge CFStringRef)alt, _captureSurface, 0, 0);
            _fnSurfaceUnlock(_captureSurface, 0, NULL);
            if ([self surfaceHasNonZeroContent:_captureSurface]) {
                _activeDisplayName = alt;
                break;
            }
        }
        if (![self surfaceHasNonZeroContent:_captureSurface]) {
            _fnSurfaceLock(_captureSurface, 0, NULL);
            _fnRenderDisplay(0, NULL, _captureSurface, 0, 0);
            _fnSurfaceUnlock(_captureSurface, 0, NULL);
        }
    }

    return [CIImage imageWithIOSurface:_captureSurface];
}

- (void)dispatchTouchPhase:(BOOL)isDown normX:(double)nx normY:(double)ny {
    if (!_hidClient || !_fnCreateDigitizer || !_fnCreateFinger || !_fnAppendEvent || !_fnDispatchEvent) return;

    uint64_t now = mach_absolute_time();
    uint32_t parentMask = kHIDDigitizerRange | kHIDDigitizerTouch;
    uint32_t childMask  = isDown ? (kHIDDigitizerRange | kHIDDigitizerTouch | kHIDDigitizerPosition)
                                 : (kHIDDigitizerRange | kHIDDigitizerTouch);

    IOHIDEventRef parent = _fnCreateDigitizer(
        kCFAllocatorDefault, now, kHIDTransducerHand,
        0, 0, parentMask, 0,
        nx, ny, 0.0, isDown ? 1.0 : 0.0, 0.0,
        isDown ? 1 : 0, isDown ? 1 : 0, 0
    );
    if (!parent) return;

    IOHIDEventRef child = _fnCreateFinger(
        kCFAllocatorDefault, now, 1, 2,
        childMask, nx, ny, 0.0,
        isDown ? 1.0 : 0.0, 0.0,
        isDown ? 1 : 0, isDown ? 1 : 0, 0
    );

    if (child) {
        _fnAppendEvent(parent, child, 0);
        CFRelease(child);
    }

    if (_fnSetIntVal) {
        _fnSetIntVal(parent, kHIDFieldDigitizerIsIntegrated, 1);
    }
    if (_fnSetSenderID) {
        _fnSetSenderID(parent, _digitizerSenderID);
    }

    _fnDispatchEvent(_hidClient, parent);
    CFRelease(parent);
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

- (void)dealloc {
    if (_captureSurface) CFRelease((CFTypeRef)_captureSurface);
    if (_hidClient) CFRelease(_hidClient);
}

@end
