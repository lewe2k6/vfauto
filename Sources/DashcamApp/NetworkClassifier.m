// C:/Users/Acer/.gemini/antigravity/scratch/pin-nhiet-do-ts/Sources/DashcamApp/NetworkClassifier.m
// Context: Objective-C Implementation / Home Wi-Fi vs Android Hotspot Classifier / iOS 12.0+ arm64

#import "NetworkClassifier.h"
#import "DashcamConfig.h"
#import <SystemConfiguration/SystemConfiguration.h>
#import <SystemConfiguration/CaptiveNetwork.h>
#import <netinet/in.h>

NSString *const kDashcamNetworkChangedNotification = @"kDashcamNetworkChangedNotification";

@interface NetworkClassifier () {
    SCNetworkReachabilityRef _reachRef;
    DashcamNetMode _currentMode;
    NSString *_currentSSID;
    NSString *_currentBSSID;
}
@end

static void ReachabilityCallback(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags, void *info) {
    NetworkClassifier *cls = (__bridge NetworkClassifier *)info;
    dispatch_async(dispatch_get_main_queue(), ^{
        [cls refreshNow];
    });
}

@implementation NetworkClassifier

+ (instancetype)sharedClassifier {
    static NetworkClassifier *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[NetworkClassifier alloc] init];
    });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _currentMode  = DashcamNetModeOffline;
        _currentSSID  = @"";
        _currentBSSID = @"";
    }
    return self;
}

- (void)dealloc {
    [self stopMonitoring];
}

- (void)startMonitoring {
    if (_reachRef) return;
    struct sockaddr_in zeroAddr;
    bzero(&zeroAddr, sizeof(zeroAddr));
    zeroAddr.sin_len = sizeof(zeroAddr);
    zeroAddr.sin_family = AF_INET;

    _reachRef = SCNetworkReachabilityCreateWithAddress(kCFAllocatorDefault, (const struct sockaddr *)&zeroAddr);
    if (_reachRef) {
        SCNetworkReachabilityContext ctx = {0, (__bridge void *)self, NULL, NULL, NULL};
        if (SCNetworkReachabilitySetCallback(_reachRef, ReachabilityCallback, &ctx)) {
            SCNetworkReachabilityScheduleWithRunLoop(_reachRef, CFRunLoopGetMain(), kCFRunLoopCommonModes);
        }
    }
    [self refreshNow];
}

- (void)stopMonitoring {
    if (_reachRef) {
        SCNetworkReachabilityUnscheduleFromRunLoop(_reachRef, CFRunLoopGetMain(), kCFRunLoopCommonModes);
        CFRelease(_reachRef);
        _reachRef = NULL;
    }
}

- (void)readCurrentWifiSSID:(NSString **)outSSID bssid:(NSString **)outBSSID {
    NSString *ssid = @"";
    NSString *bssid = @"";
    CFArrayRef ifaces = CNCopySupportedInterfaces();
    if (ifaces) {
        CFIndex count = CFArrayGetCount(ifaces);
        for (CFIndex i = 0; i < count; i++) {
            CFStringRef ifName = (CFStringRef)CFArrayGetValueAtIndex(ifaces, i);
            CFDictionaryRef info = CNCopyCurrentNetworkInfo(ifName);
            if (info) {
                NSDictionary *dict = (__bridge_transfer NSDictionary *)info;
                NSString *s = dict[(NSString *)kCNNetworkInfoKeySSID];
                NSString *b = dict[(NSString *)kCNNetworkInfoKeyBSSID];
                if (s.length > 0) {
                    ssid = s;
                    bssid = b ?: @"";
                    break;
                }
            }
        }
        CFRelease(ifaces);
    }
    if (outSSID) *outSSID = ssid;
    if (outBSSID) *outBSSID = bssid;
}

- (void)refreshNow {
    SCNetworkReachabilityFlags flags = 0;
    BOOL reachable = NO;
    if (_reachRef && SCNetworkReachabilityGetFlags(_reachRef, &flags)) {
        BOOL isReach = (flags & kSCNetworkReachabilityFlagsReachable) != 0;
        BOOL needsConn = (flags & kSCNetworkReachabilityFlagsConnectionRequired) != 0;
        reachable = (isReach && !needsConn);
    }

    NSString *ssid = @"";
    NSString *bssid = @"";
    [self readCurrentWifiSSID:&ssid bssid:&bssid];
    _currentSSID  = ssid;
    _currentBSSID = bssid;

    DashcamNetMode newMode = DashcamNetModeOffline;
    if (reachable) {
        // SAFE DEFAULT: Every network (including Android Wi-Fi Hotspot) is METERED unless it matches Home Wi-Fi!
        newMode = DashcamNetModeMeteredHotspot;
        DashcamConfig *cfg = [DashcamConfig sharedConfig];
        BOOL matchSSID  = (cfg.homeWifiSSID.length > 0 && [ssid isEqualToString:cfg.homeWifiSSID]);
        BOOL matchBSSID = (cfg.homeWifiBSSID.length > 0 && bssid.length > 0 &&
                           [bssid.lowercaseString isEqualToString:cfg.homeWifiBSSID.lowercaseString]);
        if (matchBSSID || (matchSSID && cfg.homeWifiBSSID.length == 0)) {
            newMode = DashcamNetModeHomeUnlimited;
        }
    }

    BOOL changed = (newMode != _currentMode);
    _currentMode = newMode;
    if (changed) {
        [[NSNotificationCenter defaultCenter] postNotificationName:kDashcamNetworkChangedNotification object:self];
    }
}

- (NSString *)modeDisplayString {
    switch (_currentMode) {
        case DashcamNetModeHomeUnlimited:
            return [NSString stringWithFormat:@"Wi-Fi Nhà (%@) • Xả không giới hạn", _currentSSID.length > 0 ? _currentSSID : @"Home"];
        case DashcamNetModeMeteredHotspot:
            if (_currentSSID.length > 0) {
                return [NSString stringWithFormat:@"Hotspot (%@) • Giới hạn 4G", _currentSSID];
            }
            return @"Hotspot / 4G • Giới hạn data";
        default:
            return @"Mất mạng (Lưu cục bộ)";
    }
}

@end
