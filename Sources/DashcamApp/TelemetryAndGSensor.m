// C:/Users/Acer/.gemini/antigravity/scratch/pin-nhiet-do-ts/Sources/DashcamApp/TelemetryAndGSensor.m
// Context: Objective-C Implementation / Low-Power GPS & 20Hz G-Sensor / iOS 12.0+ arm64

#import "TelemetryAndGSensor.h"
#import "DashcamConfig.h"
#import <CoreLocation/CoreLocation.h>
#import <CoreMotion/CoreMotion.h>
#import <math.h>

@interface TelemetryAndGSensor () <CLLocationManagerDelegate> {
    CLLocationManager *_locMgr;
    CMMotionManager *_motionMgr;
    NSOperationQueue *_motionQueue;
    double _lastShockEpoch;
    NSDateFormatter *_capDateFmt;
    NSDateFormatter *_capTimeFmt;
}
@end

@implementation TelemetryAndGSensor

+ (instancetype)sharedTelemetry {
    static TelemetryAndGSensor *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[TelemetryAndGSensor alloc] init];
    });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _motionMgr = [[CMMotionManager alloc] init];
        _motionQueue = [[NSOperationQueue alloc] init];
        _motionQueue.maxConcurrentOperationCount = 1;

        _capDateFmt = [[NSDateFormatter alloc] init];
        _capDateFmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        _capDateFmt.dateFormat = @"yyyy-MM-dd HH:mm";

        _capTimeFmt = [[NSDateFormatter alloc] init];
        _capTimeFmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        _capTimeFmt.dateFormat = @"HH:mm";
    }
    return self;
}

- (void)start {
    DashcamConfig *cfg = [DashcamConfig sharedConfig];

    // 1. Low-Power GPS (10m accuracy saves ~60% GPS heat vs BestForNavigation)
    if (cfg.enableGPS) {
        if (!_locMgr) {
            _locMgr = [[CLLocationManager alloc] init];
            _locMgr.delegate = self;
            _locMgr.desiredAccuracy = kCLLocationAccuracyNearestTenMeters;
            _locMgr.distanceFilter = 15.0; // Only wake every 15m moved
            _locMgr.pausesLocationUpdatesAutomatically = NO;
        }
        CLAuthorizationStatus st = [CLLocationManager authorizationStatus];
        if (st == kCLAuthorizationStatusNotDetermined) {
            [_locMgr requestWhenInUseAuthorization];
        }
        [_locMgr startUpdatingLocation];
    }

    // 2. 20Hz G-Sensor Accelerometer
    if (_motionMgr.isAccelerometerAvailable && !_motionMgr.isAccelerometerActive) {
        _motionMgr.accelerometerUpdateInterval = 0.05; // 20 Hz
        __weak typeof(self) weakSelf = self;
        [_motionMgr startAccelerometerUpdatesToQueue:_motionQueue
                                         withHandler:^(CMAccelerometerData *data, NSError *error) {
            if (!data || error) return;
            double ax = data.acceleration.x;
            double ay = data.acceleration.y;
            double az = data.acceleration.z;
            double magG = sqrt(ax * ax + ay * ay + az * az);
            __strong typeof(weakSelf) s = weakSelf;
            if (!s) return;
            if (magG > s->_segmentPeakG) {
                s->_segmentPeakG = magG;
            }
            double threshold = [DashcamConfig sharedConfig].gSensorThresholdG;
            double now = [[NSDate date] timeIntervalSince1970];
            if (magG >= threshold && (now - s->_lastShockEpoch) >= 15.0) {
                s->_lastShockEpoch = now;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if ([s.delegate respondsToSelector:@selector(telemetryDidDetectShockWithPeakG:)]) {
                        [s.delegate telemetryDidDetectShockWithPeakG:magG];
                    }
                });
            }
        }];
    }
}

- (void)stop {
    if (_locMgr) {
        [_locMgr stopUpdatingLocation];
    }
    if (_motionMgr.isAccelerometerActive) {
        [_motionMgr stopAccelerometerUpdates];
    }
}

- (void)resetSegmentStats {
    _segmentMaxSpeedKmh = 0.0;
    _segmentPeakG = 1.0;
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    CLLocation *loc = locations.lastObject;
    if (!loc || loc.horizontalAccuracy < 0 || loc.horizontalAccuracy > 150.0) return;
    _lastLat = loc.coordinate.latitude;
    _lastLng = loc.coordinate.longitude;
    _hasValidGPS = YES;
    double spd = (loc.speed >= 0) ? (loc.speed * 3.6) : 0.0;
    _currentSpeedKmh = spd;
    if (spd > _segmentMaxSpeedKmh) {
        _segmentMaxSpeedKmh = spd;
    }
}

- (NSString *)buildCaptionForStartEpoch:(double)startEpoch
                            durationSec:(NSInteger)durationSec
                              sizeBytes:(int64_t)sizeBytes
                               isLocked:(BOOL)isLocked {
    NSDate *startDt = [NSDate dateWithTimeIntervalSince1970:startEpoch];
    NSDate *endDt   = [NSDate dateWithTimeIntervalSince1970:(startEpoch + durationSec)];
    NSString *sStr  = [_capDateFmt stringFromDate:startDt];
    NSString *eStr  = [_capTimeFmt stringFromDate:endDt];
    double mb = (double)sizeBytes / (1024.0 * 1024.0);

    NSMutableString *cap = [NSMutableString string];
    if (isLocked) {
        [cap appendString:@"[LOCKED] "];
    }
    [cap appendFormat:@"%@-%@ | %.1f MB", sStr, eStr, mb];
    if (_segmentMaxSpeedKmh > 1.0) {
        [cap appendFormat:@" | Max %.0f km/h", _segmentMaxSpeedKmh];
    }
    if (_segmentPeakG >= 2.2) {
        [cap appendFormat:@" | %.1fG", _segmentPeakG];
    }
    if (_hasValidGPS) {
        [cap appendFormat:@" | %.5f,%.5f", _lastLat, _lastLng];
    }
    return cap;
}

@end
