#import "GSMOrderPayloadSniffer.h"
#import <CoreFoundation/CoreFoundation.h>
#import <mach/mach.h>
#import <dlfcn.h>
#import <sys/event.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <pthread.h>
#import <signal.h>
#import <dirent.h>
#import <fcntl.h>
#import <unistd.h>
#import <stdlib.h>
#import <string.h>
#import <math.h>

#ifndef O_EVTONLY
#define O_EVTONLY 0x8000
#endif

typedef kern_return_t (*task_for_pid_f)(
    mach_port_name_t target_tport,
    int pid,
    mach_port_name_t *t
);

typedef kern_return_t (*mach_vm_region_recurse_f)(
    vm_map_read_t target_task,
    mach_vm_address_t *address,
    mach_vm_size_t *size,
    natural_t *nesting_depth,
    vm_region_recurse_info_t info,
    mach_msg_type_number_t *infoCnt
);

typedef kern_return_t (*mach_vm_read_overwrite_f)(
    vm_map_read_t target_task,
    mach_vm_address_t address,
    mach_vm_size_t size,
    mach_vm_address_t data,
    mach_vm_size_t *outsize
);

@implementation GSMSniffedOrder
@end

#pragma mark - Low-Level C Helpers (ULID & Fast Byte Search)

static inline int crockfordBase32Value(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'z') c = (char)(c - 'a' + 'A');
    switch (c) {
        case 'A': return 10;
        case 'B': return 11;
        case 'C': return 12;
        case 'D': return 13;
        case 'E': return 14;
        case 'F': return 15;
        case 'G': return 16;
        case 'H': return 17;
        case 'J': return 18;
        case 'K': return 19;
        case 'M': return 20;
        case 'N': return 21;
        case 'P': return 22;
        case 'Q': return 23;
        case 'R': return 24;
        case 'S': return 25;
        case 'T': return 26;
        case 'V': return 27;
        case 'W': return 28;
        case 'X': return 29;
        case 'Y': return 30;
        case 'Z': return 31;
        default:  return -1;
    }
}

static BOOL isValidGSMOrderULIDCBytes(const char *s, size_t len) {
    if (!s || len != 26) return NO;
    // GSM order ULIDs always start with "01" (timestamps from 2020..2038)
    if (s[0] != '0' || s[1] != '1') return NO;
    for (size_t i = 0; i < 26; i++) {
        if (crockfordBase32Value(s[i]) < 0) return NO;
    }
    return YES;
}

static BOOL isValidGSMOrderULIDString(NSString *str) {
    if (![str isKindOfClass:[NSString class]] || str.length != 26) return NO;
    const char *c = [str UTF8String];
    if (!c) return NO;
    return isValidGSMOrderULIDCBytes(c, strlen(c));
}

static inline BOOL isLikelyJSONTextByte(uint8_t b) {
    // Valid UTF-8 JSON bytes: printable ASCII, tab/CR/LF, or UTF-8 multi-byte sequence (0x80..0xF4)
    return (b >= 0x20 && b <= 0x7E) || b == '\n' || b == '\r' || b == '\t' || (b >= 0x80 && b <= 0xF4);
}

#define kHeapScanChunkBytes   (64 * 1024)
#define kHeapScanOverlap      (8 * 1024)
#define kMaxOrderJSONBytes    (48 * 1024)
#define kMaxDiskTailReadBytes (256 * 1024)

@implementation GSMOrderPayloadSniffer {
    NSLock *_lock;
    NSString *_cachedContainerPath;
    NSString *_cachedPrefsPlistPath;
    NSString *_cachedCacheDirPath;
    double _lastContainerLookupEpoch;

    NSMutableSet<NSString *> *_handledOrderIds;
    NSMutableArray<NSString *> *_handledOrderQueue;
    NSMutableDictionary<NSString *, GSMSniffedOrder *> *_parsedOrderCache;
    NSMutableArray<NSString *> *_parsedOrderLRU;
    NSMutableDictionary<NSString *, NSString *> *_fileStatCache;
    NSMutableDictionary<NSString *, NSNumber *> *_fileLastSizeMap;

    GSMSniffedOrder *_latestSniffedOrder;
    NSString *_lastNotifiedAmbushULID;
    NSString *_lastNotifiedOrderJSONId;
    double _lastHeapScanEpoch;
    double _lastDeepDirScanEpoch;
    pid_t _cachedDriverPid;
    pid_t _deniedTaskForPid;
    double _lastPidLookupEpoch;
    uint8_t *_reusableScanBuf;
    uint8_t *_reusableFileBuf;

    volatile BOOL _kqueueMonitorRunning;
    int _kqueueFd;
}

+ (instancetype)sharedSniffer {
    static GSMOrderPayloadSniffer *sInst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sInst = [[GSMOrderPayloadSniffer alloc] init];
    });
    return sInst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock               = [[NSLock alloc] init];
        _handledOrderIds    = [NSMutableSet setWithCapacity:40];
        _handledOrderQueue  = [NSMutableArray arrayWithCapacity:40];
        _parsedOrderCache   = [NSMutableDictionary dictionaryWithCapacity:24];
        _parsedOrderLRU     = [NSMutableArray arrayWithCapacity:24];
        _fileStatCache      = [NSMutableDictionary dictionaryWithCapacity:128];
        _fileLastSizeMap    = [NSMutableDictionary dictionaryWithCapacity:64];
        _deniedTaskForPid   = 0;
        _reusableScanBuf    = (uint8_t *)malloc(kHeapScanChunkBytes + kHeapScanOverlap + 64);
        _reusableFileBuf    = (uint8_t *)malloc(kMaxDiskTailReadBytes + 64);
        _kqueueMonitorRunning = NO;
        _kqueueFd           = -1;
    }
    return self;
}

- (void)dealloc {
    [self stopRealtimeKernelMonitor];
    if (_reusableScanBuf) {
        free(_reusableScanBuf);
        _reusableScanBuf = NULL;
    }
    if (_reusableFileBuf) {
        free(_reusableFileBuf);
        _reusableFileBuf = NULL;
    }
}

#pragma mark - ULID Timestamp & JSON Parser

+ (double)decodeULIDTimestampEpoch:(NSString *)ulid {
    if (!isValidGSMOrderULIDString(ulid)) return 0.0;
    const char *c = [ulid UTF8String];
    uint64_t ms = 0;
    for (int i = 0; i < 10; i++) {
        int v = crockfordBase32Value(c[i]);
        if (v < 0) return 0.0;
        ms = (ms << 5) | (uint64_t)v;
    }
    double sec = (double)ms / 1000.0;
    // Sanity range: 2023-01-01 (1672531200) .. 2036-01-01 (2082758400)
    if (sec < 1672531200.0 || sec > 2082758400.0) return 0.0;
    return sec;
}

+ (NSInteger)extractFareIntegerFromValue:(id)val {
    if (!val || val == [NSNull null]) return 0;
    if ([val isKindOfClass:[NSNumber class]]) {
        double d = [(NSNumber *)val doubleValue];
        if (d >= 1000.0 && d <= 5000000.0) {
            return (NSInteger)llround(d);
        }
        return 0;
    }
    if ([val isKindOfClass:[NSString class]]) {
        NSString *s = (NSString *)val;
        NSMutableString *digits = [NSMutableString stringWithCapacity:s.length];
        for (NSUInteger i = 0; i < s.length; i++) {
            unichar ch = [s characterAtIndex:i];
            if (ch >= '0' && ch <= '9') {
                [digits appendFormat:@"%C", ch];
            }
        }
        if (digits.length >= 4 && digits.length <= 7) {
            NSInteger v = [digits integerValue];
            if (v >= 1000 && v <= 5000000) return v;
        }
    }
    return 0;
}

+ (GSMSniffedOrder *)parseOrderFromJSONDictionary:(NSDictionary *)rootDict
                                        sourceTag:(NSString *)sourceTag {
    if (![rootDict isKindOfClass:[NSDictionary class]]) return nil;

    NSDictionary *d = rootDict;
    if ([rootDict[@"data"] isKindOfClass:[NSDictionary class]]) {
        NSDictionary *inner = (NSDictionary *)rootDict[@"data"];
        if (inner[@"id"] || inner[@"path"] || inner[@"service"] ||
            inner[@"orders"] || inner[@"group_data"] || inner[@"groupData"] ||
            inner[@"shuttle_path"] || inner[@"shuttlePath"] || inner[@"fee_data"] || inner[@"feeData"]) {
            d = inner;
        }
    }

    // Support MDModels.GroupOrder (Express 2H / Grouped Food: group_data, orders[], fee_data, shuttle_path[])
    NSDictionary *groupDataDict = [d[@"group_data"] isKindOfClass:[NSDictionary class]]
        ? d[@"group_data"]
        : ([d[@"groupData"] isKindOfClass:[NSDictionary class]] ? d[@"groupData"] : nil);
    NSArray *ordersArr = [d[@"orders"] isKindOfClass:[NSArray class]] ? d[@"orders"] : nil;
    if (!ordersArr && groupDataDict && [groupDataDict[@"orders"] isKindOfClass:[NSArray class]]) {
        ordersArr = groupDataDict[@"orders"];
    }
    NSDictionary *firstSubOrder = (ordersArr.count > 0 && [ordersArr.firstObject isKindOfClass:[NSDictionary class]])
        ? (NSDictionary *)ordersArr.firstObject
        : nil;
    NSDictionary *lastSubOrder = (ordersArr.count > 0 && [ordersArr.lastObject isKindOfClass:[NSDictionary class]])
        ? (NSDictionary *)ordersArr.lastObject
        : firstSubOrder;
    BOOL isGroup = (groupDataDict != nil || ordersArr.count > 0 ||
                    [d[@"shuttle_path"] isKindOfClass:[NSArray class]] ||
                    [d[@"shuttlePath"] isKindOfClass:[NSArray class]] ||
                    ([d[@"is_group_order"] respondsToSelector:@selector(boolValue)] && [d[@"is_group_order"] boolValue]));

    NSString *orderId = [d[@"id"] isKindOfClass:[NSString class]] ? d[@"id"] : nil;
    if (!isValidGSMOrderULIDString(orderId) && [d[@"order_id"] isKindOfClass:[NSString class]]) {
        orderId = d[@"order_id"];
    }
    if (!isValidGSMOrderULIDString(orderId) && groupDataDict) {
        if ([groupDataDict[@"id"] isKindOfClass:[NSString class]]) orderId = groupDataDict[@"id"];
        else if ([groupDataDict[@"group_id"] isKindOfClass:[NSString class]]) orderId = groupDataDict[@"group_id"];
    }
    if (!isValidGSMOrderULIDString(orderId) && firstSubOrder) {
        if ([firstSubOrder[@"id"] isKindOfClass:[NSString class]]) orderId = firstSubOrder[@"id"];
    }
    if (!isValidGSMOrderULIDString(orderId)) {
        return nil;
    }

    NSDictionary *serviceDict = [d[@"service"] isKindOfClass:[NSDictionary class]] ? d[@"service"] : nil;
    if (!serviceDict && groupDataDict && [groupDataDict[@"service"] isKindOfClass:[NSDictionary class]]) {
        serviceDict = groupDataDict[@"service"];
    }
    if (!serviceDict && firstSubOrder && [firstSubOrder[@"service"] isKindOfClass:[NSDictionary class]]) {
        serviceDict = firstSubOrder[@"service"];
    }

    NSArray *pathArr = [d[@"path"] isKindOfClass:[NSArray class]] ? d[@"path"] : nil;
    if (!pathArr && [d[@"shuttle_path"] isKindOfClass:[NSArray class]]) {
        pathArr = d[@"shuttle_path"];
    }
    if (!pathArr && [d[@"shuttlePath"] isKindOfClass:[NSArray class]]) {
        pathArr = d[@"shuttlePath"];
    }
    if (!pathArr && groupDataDict) {
        if ([groupDataDict[@"shuttle_path"] isKindOfClass:[NSArray class]]) pathArr = groupDataDict[@"shuttle_path"];
        else if ([groupDataDict[@"shuttlePath"] isKindOfClass:[NSArray class]]) pathArr = groupDataDict[@"shuttlePath"];
        else if ([groupDataDict[@"path"] isKindOfClass:[NSArray class]]) pathArr = groupDataDict[@"path"];
    }
    if ((!pathArr || pathArr.count == 0) && firstSubOrder) {
        NSMutableArray *combinedSubPath = [NSMutableArray arrayWithCapacity:4];
        NSArray *firstPath = [firstSubOrder[@"path"] isKindOfClass:[NSArray class]] ? firstSubOrder[@"path"] : nil;
        if (firstPath.count > 0) {
            [combinedSubPath addObject:firstPath.firstObject];
        }
        NSArray *lastPath = [lastSubOrder[@"path"] isKindOfClass:[NSArray class]] ? lastSubOrder[@"path"] : nil;
        if (lastPath.count > 1) {
            [combinedSubPath addObject:lastPath.lastObject];
        } else if (firstPath.count > 1) {
            [combinedSubPath addObject:firstPath.lastObject];
        }
        if (combinedSubPath.count > 0) {
            pathArr = combinedSubPath;
        }
    }

    NSDictionary *feeDict = [d[@"fee"] isKindOfClass:[NSDictionary class]] ? d[@"fee"] : nil;
    if (!feeDict && [d[@"fee_data"] isKindOfClass:[NSArray class]] == NO && [d[@"fee_data"] isKindOfClass:[NSDictionary class]]) {
        feeDict = d[@"fee_data"];
    }
    if (!feeDict && [d[@"feeData"] isKindOfClass:[NSDictionary class]]) {
        feeDict = d[@"feeData"];
    }
    if (!feeDict && groupDataDict) {
        if ([groupDataDict[@"fee"] isKindOfClass:[NSDictionary class]]) feeDict = groupDataDict[@"fee"];
        else if ([groupDataDict[@"fee_data"] isKindOfClass:[NSDictionary class]]) feeDict = groupDataDict[@"fee_data"];
        else if ([groupDataDict[@"feeData"] isKindOfClass:[NSDictionary class]]) feeDict = groupDataDict[@"feeData"];
    }
    if (!feeDict && firstSubOrder && [firstSubOrder[@"fee"] isKindOfClass:[NSDictionary class]]) {
        feeDict = firstSubOrder[@"fee"];
    }

    // Must be an actual Order / GroupOrder object (not a bare Path stop or sub-object)
    if (!serviceDict && !pathArr && !feeDict && !ordersArr) {
        return nil;
    }

    GSMSniffedOrder *ord = [[GSMSniffedOrder alloc] init];
    ord.orderId          = orderId;
    ord.isGroupOrder     = isGroup;
    ord.sniffSourceTag   = sourceTag ?: @"JSON";
    ord.sniffedAtEpoch   = [[NSDate date] timeIntervalSince1970];

    // 1. Classify Service Type (Bike / Express vs Green Food)
    // CRITICAL: Check service.service_type & service.display_name FIRST!
    // (In Express orders, express_detail.package_types can contain {"id":"food","title":"Thức ăn"},
    // which is still an EXPRESS-ONDEMAND order, NOT a Green Food restaurant order!)
    NSString *svcTypeRaw = [serviceDict[@"service_type"] isKindOfClass:[NSString class]] ? serviceDict[@"service_type"] : @"";
    NSString *svcDispRaw = [serviceDict[@"display_name"] isKindOfClass:[NSString class]] ? serviceDict[@"display_name"] : @"";
    if (svcTypeRaw.length == 0 && [d[@"service_type"] isKindOfClass:[NSString class]]) {
        svcTypeRaw = d[@"service_type"];
    }
    if (svcTypeRaw.length == 0 && groupDataDict && [groupDataDict[@"service_type"] isKindOfClass:[NSString class]]) {
        svcTypeRaw = groupDataDict[@"service_type"];
    }
    if (svcDispRaw.length == 0 && groupDataDict && [groupDataDict[@"display_name"] isKindOfClass:[NSString class]]) {
        svcDispRaw = groupDataDict[@"display_name"];
    }
    ord.serviceTypeRaw     = svcTypeRaw;
    ord.serviceDisplayName = svcDispRaw;

    NSString *normType = NormalizeVNText(svcTypeRaw);
    NSString *normDisp = NormalizeVNText(svcDispRaw);

    BOOL explicitNonFood = ([normType containsString:@"express"] ||
                            [normType containsString:@"bike"] ||
                            [normType containsString:@"ride"] ||
                            [normType containsString:@"taxi"] ||
                            [normType containsString:@"car"] ||
                            [normType containsString:@"shuttle"] ||
                            [normType containsString:@"share"] ||
                            [normType containsString:@"truck"] ||
                            [normDisp containsString:@"bike"] ||
                            [normDisp containsString:@"express"] ||
                            [normDisp containsString:@"sieu toc"] ||
                            [normDisp containsString:@"giao hang"] ||
                            [normDisp containsString:@"taxi"] ||
                            [normDisp containsString:@"car"]);

    BOOL hasFoodDetailObj = ([d[@"food_detail"] isKindOfClass:[NSDictionary class]] && [(NSDictionary *)d[@"food_detail"] count] > 0) ||
                            ([d[@"food_fee"] isKindOfClass:[NSDictionary class]] && [(NSDictionary *)d[@"food_fee"] count] > 0) ||
                            ([d[@"is_food_delivery"] respondsToSelector:@selector(boolValue)] && [d[@"is_food_delivery"] boolValue]) ||
                            (firstSubOrder && [firstSubOrder[@"food_detail"] isKindOfClass:[NSDictionary class]] && [(NSDictionary *)firstSubOrder[@"food_detail"] count] > 0);

    BOOL explicitFood = ([normType containsString:@"food"] ||
                         [normDisp containsString:@"food"] ||
                         [normDisp containsString:@"xanh ngon"] ||
                         [normDisp containsString:@"sm ngon"] ||
                         [normDisp containsString:@"do an"] ||
                         (!explicitNonFood && hasFoodDetailObj));

    if (explicitFood) {
        ord.isGreenFood     = YES;
        ord.isBikeOrExpress = NO;
        if (ord.serviceDisplayName.length == 0) ord.serviceDisplayName = @"Green Food";
    } else if (explicitNonFood) {
        ord.isGreenFood     = NO;
        ord.isBikeOrExpress = YES;
        if (ord.serviceDisplayName.length == 0) {
            ord.serviceDisplayName = [normType containsString:@"express"] ? @"Green Express" : @"Green Bike";
        }
    } else {
        // Unknown service_type -> require either food_detail or path inspection
        ord.isGreenFood     = hasFoodDetailObj;
        ord.isBikeOrExpress = !hasFoodDetailObj && (svcTypeRaw.length > 0 || svcDispRaw.length > 0 || isGroup);
        if (ord.isBikeOrExpress && ord.serviceDisplayName.length == 0) {
            ord.serviceDisplayName = isGroup ? @"Express Ghép" : @"Green Bike";
        }
    }

    // 2. Extract Exact Fare VND
    NSInteger totalPay = [self extractFareIntegerFromValue:feeDict[@"total_pay"]];
    NSInteger totalFee = [self extractFareIntegerFromValue:feeDict[@"total_fee"]];
    NSDictionary *fb   = [feeDict[@"fee_breakdown"] isKindOfClass:[NSDictionary class]] ? feeDict[@"fee_breakdown"] : nil;
    NSInteger baseFee  = [self extractFareIntegerFromValue:fb[@"base_fee"]];
    if (totalPay <= 0) totalPay = [self extractFareIntegerFromValue:feeDict[@"total_pay_display"]];
    if (totalPay <= 0) totalPay = [self extractFareIntegerFromValue:feeDict[@"display"]];
    if (totalPay <= 0) totalPay = [self extractFareIntegerFromValue:feeDict[@"driver_receive"]];
    if (totalPay <= 0) totalPay = [self extractFareIntegerFromValue:feeDict[@"amount"]];
    if (totalPay <= 0) totalPay = [self extractFareIntegerFromValue:d[@"total_pay"]];
    if (totalFee <= 0) totalFee = [self extractFareIntegerFromValue:feeDict[@"total_fee_display"]];

    if (totalPay <= 0 && totalFee <= 0 && ordersArr.count > 0) {
        NSInteger sumPay = 0;
        for (id subItem in ordersArr) {
            if (![subItem isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *subFee = [subItem[@"fee"] isKindOfClass:[NSDictionary class]] ? subItem[@"fee"] : nil;
            NSInteger sp = [self extractFareIntegerFromValue:subFee[@"total_pay"]];
            if (sp <= 0) sp = [self extractFareIntegerFromValue:subFee[@"total_fee"]];
            if (sp >= 1000) sumPay += sp;
        }
        if (sumPay >= 5000) {
            totalPay = sumPay;
        }
    }

    ord.totalPayVND = (totalPay >= 5000) ? totalPay : ((totalFee >= 5000) ? totalFee : baseFee);
    ord.totalFeeVND = (totalFee >= 5000) ? totalFee : ord.totalPayVND;
    ord.baseFeeVND  = (baseFee >= 5000)  ? baseFee  : ord.totalPayVND;

    // 3. Extract Distance (km)
    id distVal = d[@"distance"];
    if (!distVal && [d[@"trip_data"] isKindOfClass:[NSDictionary class]]) {
        distVal = d[@"trip_data"][@"distance"];
    }
    if (!distVal && groupDataDict) {
        distVal = groupDataDict[@"distance"] ?: groupDataDict[@"total_distance"];
    }
    if ([distVal respondsToSelector:@selector(doubleValue)]) {
        double km = [distVal doubleValue];
        if (km > 0.02 && km < 200.0) {
            ord.serverDistanceKm = km;
        }
    } else if (ordersArr.count > 0) {
        double sumKm = 0.0;
        for (id subItem in ordersArr) {
            if ([subItem isKindOfClass:[NSDictionary class]] && [subItem[@"distance"] respondsToSelector:@selector(doubleValue)]) {
                double skm = [subItem[@"distance"] doubleValue];
                if (skm > 0.01 && skm < 100.0) sumKm += skm;
            }
        }
        if (sumKm > 0.02 && sumKm < 200.0) {
            ord.serverDistanceKm = sumKm;
        }
    }

    // 4. Extract Pickup & Dropoff Stops from path[] / shuttle_path[]
    if (pathArr.count > 0) {
        BOOL foundPickup  = NO;
        BOOL foundDropoff = NO;
        for (id item in pathArr) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *p = (NSDictionary *)item;
            NSString *pType = [p[@"type"] isKindOfClass:[NSString class]] ? [p[@"type"] uppercaseString] : @"";
            NSString *name  = [p[@"name"] isKindOfClass:[NSString class]] ? p[@"name"] : @"";
            NSString *sAddr = [p[@"short_address"] isKindOfClass:[NSString class]] ? p[@"short_address"] : @"";
            NSString *fAddr = [p[@"address"] isKindOfClass:[NSString class]] ? p[@"address"] : @"";
            NSString *note  = [p[@"address_note"] isKindOfClass:[NSString class]] ? p[@"address_note"] : @"";

            double lat = [p[@"latitude"] respondsToSelector:@selector(doubleValue)] ? [p[@"latitude"] doubleValue] : 0.0;
            double lng = [p[@"longitude"] respondsToSelector:@selector(doubleValue)] ? [p[@"longitude"] doubleValue] : 0.0;
            BOOL validCoord = (lat >= 8.0 && lat <= 24.0 && lng >= 102.0 && lng <= 110.5);

            if (!foundPickup && ([pType containsString:@"PICK"] || (!foundPickup && ![pType containsString:@"DROP"] && ![pType containsString:@"END"]))) {
                foundPickup            = YES;
                ord.pickupName         = name;
                ord.pickupShortAddress = sAddr;
                ord.pickupFullAddress  = fAddr;
                ord.pickupNote         = note;
                if (validCoord) {
                    ord.hasPickupCoords = YES;
                    ord.pickupLat       = lat;
                    ord.pickupLng       = lng;
                }
            } else if ([pType containsString:@"DROP"] || [pType containsString:@"END"] || (foundPickup && (sAddr.length > 0 || fAddr.length > 0 || validCoord))) {
                // For GroupOrder shuttle_path with multiple stops, keep updating Dropoff to the final destination stop
                if (!foundDropoff || isGroup) {
                    foundDropoff            = YES;
                    ord.dropoffName         = name;
                    ord.dropoffShortAddress = sAddr;
                    ord.dropoffFullAddress  = fAddr;
                    ord.dropoffNote         = note;
                    if (validCoord) {
                        ord.hasDropoffCoords = YES;
                        ord.dropoffLat       = lat;
                        ord.dropoffLng       = lng;
                    }
                }
            }
        }
    }

    // 4B. Aggregate ALL Delivery Notes (address_note, note, instructions[]) and Stop Addresses across Single & GroupOrder sub-orders!
    // CRITICAL: In MDModels.GroupOrder (Express 2H / SameDay), group_data.shuttle_path[] omits address_note;
    // the actual "TX đến Nhà Thuốc Long Châu..." note is stored inside orders[k].path[i].address_note!
    NSMutableArray<NSString *> *noteParts = [NSMutableArray arrayWithCapacity:6];
    NSMutableArray<NSString *> *addrParts = [NSMutableArray arrayWithCapacity:8];

    void (^appendUniqueStr)(NSMutableArray<NSString *> *, id) = ^(NSMutableArray<NSString *> *arr, id rawVal) {
        if (![rawVal isKindOfClass:[NSString class]]) return;
        NSString *trimmed = [(NSString *)rawVal stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length > 0 && ![arr containsObject:trimmed]) {
            [arr addObject:trimmed];
        }
    };

    void (^collectStopsBlock)(id) = ^(id maybeStops) {
        if (![maybeStops isKindOfClass:[NSArray class]]) return;
        for (id stopObj in (NSArray *)maybeStops) {
            if (![stopObj isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *sp = (NSDictionary *)stopObj;
            NSString *spType = [sp[@"type"] isKindOfClass:[NSString class]] ? [sp[@"type"] uppercaseString] : @"";
            NSString *spNote = [sp[@"address_note"] isKindOfClass:[NSString class]] ? sp[@"address_note"] : ([sp[@"note"] isKindOfClass:[NSString class]] ? sp[@"note"] : @"");
            appendUniqueStr(noteParts, spNote);
            appendUniqueStr(noteParts, sp[@"note"]);
            appendUniqueStr(noteParts, sp[@"delivery_note"]);
            appendUniqueStr(noteParts, sp[@"sender_note"]);
            appendUniqueStr(noteParts, sp[@"recipient_note"]);
            appendUniqueStr(noteParts, sp[@"partner_note"]);
            appendUniqueStr(noteParts, sp[@"remark"]);
            if (spNote.length > 0) {
                if (ord.pickupNote.length == 0 && ([spType containsString:@"PICK"] || ord.dropoffNote.length == 0)) {
                    ord.pickupNote = spNote;
                } else if (ord.dropoffNote.length == 0 && ([spType containsString:@"DROP"] || [spType containsString:@"END"] || [spType containsString:@"RETURN"])) {
                    ord.dropoffNote = spNote;
                }
            }
            appendUniqueStr(addrParts, sp[@"name"]);
            appendUniqueStr(addrParts, sp[@"short_address"]);
            appendUniqueStr(addrParts, sp[@"address"]);
        }
    };

    void (^collectInstructionsBlock)(id) = ^(id maybeInst) {
        if (![maybeInst isKindOfClass:[NSArray class]]) return;
        for (id instObj in (NSArray *)maybeInst) {
            if ([instObj isKindOfClass:[NSString class]]) {
                appendUniqueStr(noteParts, instObj);
            } else if ([instObj isKindOfClass:[NSDictionary class]]) {
                NSDictionary *instDict = (NSDictionary *)instObj;
                appendUniqueStr(noteParts, instDict[@"note"]);
                id contentVal = instDict[@"content"];
                if ([contentVal isKindOfClass:[NSString class]]) {
                    appendUniqueStr(noteParts, contentVal);
                } else if ([contentVal isKindOfClass:[NSArray class]]) {
                    for (id cLine in (NSArray *)contentVal) {
                        appendUniqueStr(noteParts, cLine);
                    }
                }
            }
        }
    };

    collectStopsBlock(d[@"path"]);
    collectStopsBlock(d[@"shuttle_path"]);
    collectStopsBlock(d[@"shuttlePath"]);
    if (groupDataDict) {
        collectStopsBlock(groupDataDict[@"path"]);
        collectStopsBlock(groupDataDict[@"shuttle_path"]);
        collectStopsBlock(groupDataDict[@"shuttlePath"]);
        appendUniqueStr(noteParts, groupDataDict[@"note"]);
        appendUniqueStr(noteParts, groupDataDict[@"address_note"]);
        collectInstructionsBlock(groupDataDict[@"instructions"]);
    }
    appendUniqueStr(noteParts, d[@"note"]);
    appendUniqueStr(noteParts, d[@"address_note"]);
    collectInstructionsBlock(d[@"instructions"]);

    if ([d[@"express_detail"] isKindOfClass:[NSDictionary class]]) {
        NSDictionary *expDet = d[@"express_detail"];
        appendUniqueStr(noteParts, expDet[@"note"]);
        appendUniqueStr(noteParts, expDet[@"address_note"]);
        collectInstructionsBlock(expDet[@"instructions"]);
    }

    NSMutableArray<NSString *> *subIds = [NSMutableArray arrayWithCapacity:4];
    if (ordersArr.count > 0) {
        for (id subObj in ordersArr) {
            if (![subObj isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *subOrd = (NSDictionary *)subObj;
            NSString *sid = [subOrd[@"id"] isKindOfClass:[NSString class]] ? subOrd[@"id"] : ([subOrd[@"order_id"] isKindOfClass:[NSString class]] ? subOrd[@"order_id"] : nil);
            if (isValidGSMOrderULIDString(sid) && ![sid isEqualToString:orderId] && ![subIds containsObject:sid]) {
                [subIds addObject:sid];
            }
            collectStopsBlock(subOrd[@"path"]);
            collectStopsBlock(subOrd[@"shuttle_path"]);
            appendUniqueStr(noteParts, subOrd[@"note"]);
            appendUniqueStr(noteParts, subOrd[@"address_note"]);
            appendUniqueStr(noteParts, subOrd[@"delivery_note"]);
            appendUniqueStr(noteParts, subOrd[@"partner_note"]);
            appendUniqueStr(noteParts, subOrd[@"remark"]);
            collectInstructionsBlock(subOrd[@"instructions"]);
            if ([subOrd[@"express_detail"] isKindOfClass:[NSDictionary class]]) {
                NSDictionary *subExp = subOrd[@"express_detail"];
                appendUniqueStr(noteParts, subExp[@"note"]);
                appendUniqueStr(noteParts, subExp[@"address_note"]);
                appendUniqueStr(noteParts, subExp[@"delivery_note"]);
                collectInstructionsBlock(subExp[@"instructions"]);
            }
        }
    }
    if (subIds.count > 0) {
        ord.subOrderIds = [subIds copy];
    }

    ord.allNotesCombined     = (noteParts.count > 0) ? [noteParts componentsJoinedByString:@" | "] : @"";
    ord.allAddressesCombined = (addrParts.count > 0) ? [addrParts componentsJoinedByString:@" | "] : @"";

    // 5. Extract Order Timestamp (dispatch_time / order_time / create_time / ULID 48-bit ms timestamp)
    double ts = 0.0;
    for (NSString *tKey in @[@"dispatch_time", @"order_time", @"create_time"]) {
        id tv = d[tKey];
        if ([tv respondsToSelector:@selector(doubleValue)]) {
            double v = [tv doubleValue];
            if (v > 1000000000000.0) v /= 1000.0; // convert ms to sec if needed
            if (v >= 1672531200.0 && v <= 2082758400.0 && v > ts) {
                ts = v;
            }
        }
    }
    double ulidTs = [self decodeULIDTimestampEpoch:orderId];
    if (ulidTs > ts) {
        ts = ulidTs;
    }
    ord.orderTimestampEpoch = (ts > 0.0) ? ts : ord.sniffedAtEpoch;

    return ord;
}

#pragma mark - Balanced JSON Slice Extractor from Raw Buffer

- (GSMSniffedOrder *)extractOrderAroundOffset:(size_t)hitOffset
                                     inBuffer:(const uint8_t *)buf
                                       length:(size_t)bufLen
                                    sourceTag:(NSString *)sourceTag {
    if (!buf || bufLen < 40 || hitOffset >= bufLen) return nil;

    // Walk backward from hitOffset up to 24 KB while bytes look like valid UTF-8 JSON text
    // (24 KB ensures multi-order GroupOrder payloads are always captured from their outermost '{'!)
    size_t minScan = (hitOffset > 24576) ? (hitOffset - 24576) : 0;
    size_t textStart = hitOffset;
    while (textStart > minScan && isLikelyJSONTextByte(buf[textStart - 1])) {
        textStart--;
    }

    // Collect candidate '{' positions between textStart and hitOffset
    // Check outermost '{' first so {"data":{"id":...}} or {"id":...} is captured whole
    for (size_t pos = textStart; pos <= hitOffset; pos++) {
        if (buf[pos] != '{') continue;

        // Quick lookahead: after '{' and optional whitespace, must be '"'
        size_t look = pos + 1;
        while (look < bufLen && (buf[look] == ' ' || buf[look] == '\n' || buf[look] == '\r' || buf[look] == '\t')) {
            look++;
        }
        if (look >= bufLen || buf[look] != '"') continue;

        // Walk forward with string-aware brace counting
        int depth = 0;
        BOOL inString = NO;
        BOOL escaped  = NO;
        size_t maxEnd = MIN(bufLen, pos + kMaxOrderJSONBytes);
        size_t endPos = 0;

        for (size_t cur = pos; cur < maxEnd; cur++) {
            uint8_t c = buf[cur];
            if (!isLikelyJSONTextByte(c)) break;

            if (inString) {
                if (escaped) {
                    escaped = NO;
                } else if (c == '\\') {
                    escaped = YES;
                } else if (c == '"') {
                    inString = NO;
                }
            } else {
                if (c == '"') {
                    inString = YES;
                } else if (c == '{') {
                    depth++;
                } else if (c == '}') {
                    depth--;
                    if (depth == 0) {
                        endPos = cur;
                        break;
                    }
                }
            }
        }

        if (endPos > pos && endPos < hitOffset) {
            // Preceding sibling JSON object finished before hitOffset -> skip past it in O(1)!
            pos = endPos;
            continue;
        }

        if (endPos >= hitOffset && (endPos - pos) >= 48) {
            size_t sliceLen = endPos - pos + 1;
            const uint8_t *slicePtr = buf + pos;

            // Fast check: slice must contain "id" and ("path" or "service" or "fee" or "orders" or "shuttle_path" or "fee_data")
            if (memmem(slicePtr, sliceLen, "\"id\"", 4) != NULL &&
                (memmem(slicePtr, sliceLen, "\"path\"", 6) != NULL ||
                 memmem(slicePtr, sliceLen, "\"service\"", 9) != NULL ||
                 memmem(slicePtr, sliceLen, "\"fee\"", 5) != NULL ||
                 memmem(slicePtr, sliceLen, "\"orders\"", 8) != NULL ||
                 memmem(slicePtr, sliceLen, "\"shuttle_path\"", 14) != NULL ||
                 memmem(slicePtr, sliceLen, "\"fee_data\"", 10) != NULL)) {
                NSData *jsonData = [NSData dataWithBytesNoCopy:(void *)slicePtr length:sliceLen freeWhenDone:NO];
                NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
                if ([dict isKindOfClass:[NSDictionary class]]) {
                    GSMSniffedOrder *ord = [GSMOrderPayloadSniffer parseOrderFromJSONDictionary:dict sourceTag:sourceTag];
                    if (ord && ord.orderId.length == 26) {
                        return ord;
                    }
                }
            }
        }
    }

    return nil;
}

#pragma mark - Container, Preferences & Cache.db Discovery

- (void)performWithRootPrivileges:(void (^)(void))block {
    if (!block) return;
    uid_t prevEuid = geteuid();
    BOOL elevated = NO;
    if (prevEuid != 0 && getuid() == 0) {
        if (seteuid(0) == 0) {
            elevated = YES;
        }
    }
    @try {
        block();
    } @finally {
        if (elevated) {
            seteuid(prevEuid);
        }
    }
}

- (void)ensureGSMContainerPathsResolvedWithConfig:(FilterConfig *)config {
    double now = [[NSDate date] timeIntervalSince1970];
    if (_cachedContainerPath.length > 0 && (now - _lastContainerLookupEpoch) < 60.0) {
        if (access([_cachedContainerPath fileSystemRepresentation], F_OK) == 0) {
            return;
        }
    }
    _lastContainerLookupEpoch = now;

    void (^resolveBlock)(void) = ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dataRoot = @"/var/mobile/Containers/Data/Application";
        NSArray<NSString *> *uuids = [fm contentsOfDirectoryAtPath:dataRoot error:nil];
        if (uuids.count == 0) return;

        NSArray<NSString *> *candidateBids = @[
            @"vn.gsm.md",
            @"vn.gsm.driver",
            (config.driverAppBundleID.length > 0 ? config.driverAppBundleID : @"vn.gsm.md")
        ];

        // Pass 1 (0.1ms): Direct O(1) stat check for Library/Preferences/vn.gsm.md.plist or Library/Caches/vn.gsm.md
        for (NSString *u in uuids) {
            NSString *contDir = [dataRoot stringByAppendingPathComponent:u];
            for (NSString *bid in candidateBids) {
                NSString *prefCand = [contDir stringByAppendingPathComponent:[NSString stringWithFormat:@"Library/Preferences/%@.plist", bid]];
                NSString *cacheCand = [contDir stringByAppendingPathComponent:[NSString stringWithFormat:@"Library/Caches/%@", bid]];
                if (access([prefCand fileSystemRepresentation], F_OK) == 0 ||
                    access([cacheCand fileSystemRepresentation], F_OK) == 0) {
                    self->_cachedContainerPath  = contDir;
                    self->_cachedPrefsPlistPath = prefCand;
                    self->_cachedCacheDirPath   = cacheCand;
                    return;
                }
            }
        }

        // Pass 2: Fallback check via .com.apple.mobile_container_manager.metadata.plist
        for (NSString *u in uuids) {
            NSString *contDir = [dataRoot stringByAppendingPathComponent:u];
            NSString *metaPath = [contDir stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
            NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:metaPath];
            NSString *ident = [meta[@"MCMMetadataIdentifier"] isKindOfClass:[NSString class]] ? meta[@"MCMMetadataIdentifier"] : @"";
            if (ident.length == 0) continue;
            for (NSString *bid in candidateBids) {
                if ([ident caseInsensitiveCompare:bid] == NSOrderedSame) {
                    self->_cachedContainerPath  = contDir;
                    self->_cachedPrefsPlistPath = [contDir stringByAppendingPathComponent:[NSString stringWithFormat:@"Library/Preferences/%@.plist", ident]];
                    self->_cachedCacheDirPath   = [contDir stringByAppendingPathComponent:[NSString stringWithFormat:@"Library/Caches/%@", ident]];
                    return;
                }
            }
        }
    };

    // Try directly as mobile (euid 501) first so process-wide euid stays untouched; only elevate if needed
    resolveBlock();
    if (_cachedContainerPath.length == 0) {
        [self performWithRootPrivileges:resolveBlock];
    }
}

- (void)collectULIDsRecursivelyFromObject:(id)obj intoArray:(NSMutableArray<NSString *> *)outArr {
    if (!obj || !outArr) return;
    if ([obj isKindOfClass:[NSString class]]) {
        NSString *s = (NSString *)obj;
        if (isValidGSMOrderULIDString(s)) {
            if (![outArr containsObject:s]) {
                [outArr addObject:s];
            }
        } else if (s.length > 26 && s.length < 4096) {
            const char *c = [s UTF8String];
            if (c) {
                size_t len = strlen(c);
                for (size_t i = 0; i + 26 <= len; i++) {
                    if (c[i] == '0' && c[i + 1] == '1' && isValidGSMOrderULIDCBytes(c + i, 26)) {
                        NSString *u = [[NSString alloc] initWithBytes:(c + i) length:26 encoding:NSASCIIStringEncoding];
                        if (u && ![outArr containsObject:u]) {
                            [outArr addObject:u];
                        }
                        i += 25;
                    }
                }
            }
        }
    } else if ([obj isKindOfClass:[NSArray class]]) {
        // Traverse from last to first so newest appended orderId comes first!
        NSArray *arr = (NSArray *)obj;
        for (NSInteger i = (NSInteger)arr.count - 1; i >= 0; i--) {
            [self collectULIDsRecursivelyFromObject:arr[(NSUInteger)i] intoArray:outArr];
        }
    } else if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)obj;
        // Prioritize known MDStorage keys first
        NSArray<NSString *> *priorityKeys = @[
            @"tripRequestOngoingHandler",
            @"tripRequestOrderHandled",
            @"rideConnectingOrderID",
            @"handleRideConnectingOrderID",
            @"ordersHandled",
            @"cacheOrdersHandled",
            @"alreadyAcceptOrders"
        ];
        for (NSString *pk in priorityKeys) {
            if (dict[pk]) {
                [self collectULIDsRecursivelyFromObject:dict[pk] intoArray:outArr];
            }
        }
        for (NSString *k in dict) {
            if (![priorityKeys containsObject:k]) {
                [self collectULIDsRecursivelyFromObject:dict[k] intoArray:outArr];
            }
        }
    } else if ([obj isKindOfClass:[NSData class]]) {
        NSData *d = (NSData *)obj;
        if (d.length >= 26 && d.length <= 16384) {
            id subPlist = [NSPropertyListSerialization propertyListWithData:d options:NSPropertyListImmutable format:NULL error:nil];
            if (subPlist) {
                [self collectULIDsRecursivelyFromObject:subPlist intoArray:outArr];
            } else {
                NSString *utf8 = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
                if (utf8) {
                    [self collectULIDsRecursivelyFromObject:utf8 intoArray:outArr];
                }
            }
        }
    }
}

- (NSArray<NSString *> *)readActiveOrderULIDsFromPreferencesWithConfig:(FilterConfig *)config {
    NSMutableArray<NSString *> *ulids = [NSMutableArray arrayWithCapacity:8];

    // 1. Live in-memory cfprefsd query (0.02ms, works even before plist flushes to disk)
    @try {
        CFArrayRef keyList = CFPreferencesCopyKeyList(CFSTR("vn.gsm.md"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        if (keyList) {
            CFDictionaryRef allPrefs = CFPreferencesCopyMultiple(keyList, CFSTR("vn.gsm.md"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
            CFRelease(keyList);
            if (allPrefs) {
                NSDictionary *nsPrefs = (__bridge_transfer NSDictionary *)allPrefs;
                [self collectULIDsRecursivelyFromObject:nsPrefs intoArray:ulids];
            }
        }
    } @catch (NSException *ex) {}

    // 2. Direct disk read of Library/Preferences/vn.gsm.md.plist
    [self ensureGSMContainerPathsResolvedWithConfig:config];
    if (_cachedPrefsPlistPath.length > 0) {
        NSData *plistData = [NSData dataWithContentsOfFile:_cachedPrefsPlistPath options:NSDataReadingUncached error:nil];
        if (plistData.length > 0) {
            id plistObj = [NSPropertyListSerialization propertyListWithData:plistData options:NSPropertyListImmutable format:NULL error:nil];
            if (plistObj) {
                [self collectULIDsRecursivelyFromObject:plistObj intoArray:ulids];
            }
        }
    }

    // Filter out already-handled orderIds and sort newest ULID first (lexicographical ULID order == chronological order!)
    NSMutableArray<NSString *> *fresh = [NSMutableArray arrayWithCapacity:ulids.count];
    double now = [[NSDate date] timeIntervalSince1970];
    for (NSString *u in ulids) {
        if ([_handledOrderIds containsObject:u]) continue;
        double ulidEpoch = [GSMOrderPayloadSniffer decodeULIDTimestampEpoch:u];
        // Ignore ancient ULIDs older than 5 minutes stored in historical ordersHandled
        if (ulidEpoch > 0.0 && (now - ulidEpoch) > 300.0) continue;
        [fresh addObject:u];
    }

    [fresh sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [b compare:a]; // Descending: newest ULID timestamp first
    }];
    return fresh;
}

#pragma mark - Layer 1: Disk Cache Scanner (Cache.db-wal, Cache.db, fsCachedData)

- (void)scanRawBuffer:(const uint8_t *)buf
               length:(size_t)len
         targetULIDs:(NSArray<NSString *> *)targetULIDs
            sourceTag:(NSString *)sourceTag
       intoCandidates:(NSMutableArray<GSMSniffedOrder *> *)candidates {
    if (!buf || len < 60 || !candidates) return;

    // 1A. Search for specific active ULIDs first (O(N) memmem, <0.1ms)
    for (NSString *ulid in targetULIDs) {
        if (_parsedOrderCache[ulid]) {
            if (![candidates containsObject:_parsedOrderCache[ulid]]) {
                [candidates addObject:_parsedOrderCache[ulid]];
            }
            continue;
        }
        const char *needle = [ulid UTF8String];
        if (!needle) continue;
        size_t needleLen = 26;
        const uint8_t *cur = buf;
        size_t rem = len;
        while (rem >= needleLen) {
            const uint8_t *hit = (const uint8_t *)memmem(cur, rem, needle, needleLen);
            if (!hit) break;
            size_t hitOff = (size_t)(hit - buf);
            GSMSniffedOrder *ord = [self extractOrderAroundOffset:hitOff inBuffer:buf length:len sourceTag:sourceTag];
            if (ord && ![_handledOrderIds containsObject:ord.orderId]) {
                [self cacheParsedOrder:ord];
                [candidates addObject:ord];
                break;
            }
            size_t adv = (size_t)(hit - cur) + needleLen;
            cur += adv;
            rem -= adv;
        }
    }

    // 1B. Also scan for any recent JSON containing "fee_breakdown", "service_type", "shuttle_path", or "fee_data" (in case plist hasn't flushed ULID yet)
    static const char *kAnchors[4] = {
        "\"fee_breakdown\"",
        "\"service_type\"",
        "\"shuttle_path\"",
        "\"fee_data\""
    };
    static const size_t kAnchorLens[4] = { 15, 14, 14, 10 };

    for (int a = 0; a < 4; a++) {
        const char *needle = kAnchors[a];
        size_t needleLen   = kAnchorLens[a];
        const uint8_t *cur = buf;
        size_t rem         = len;
        int hitsChecked    = 0;

        while (rem >= needleLen && hitsChecked < 24) {
            const uint8_t *hit = (const uint8_t *)memmem(cur, rem, needle, needleLen);
            if (!hit) break;
            hitsChecked++;
            size_t hitOff = (size_t)(hit - buf);
            GSMSniffedOrder *ord = [self extractOrderAroundOffset:hitOff inBuffer:buf length:len sourceTag:sourceTag];
            if (ord && ![_handledOrderIds containsObject:ord.orderId]) {
                [self cacheParsedOrder:ord];
                BOOL exists = NO;
                for (GSMSniffedOrder * existing in candidates) {
                    if ([existing.orderId isEqualToString:ord.orderId]) {
                        exists = YES;
                        break;
                    }
                }
                if (!exists) {
                    [candidates addObject:ord];
                }
            }
            size_t adv = (size_t)(hit - cur) + needleLen;
            cur += adv;
            rem -= adv;
        }
    }
}

- (void)scanFileTailAtPath:(NSString *)filePath
                 maxAgeSec:(double)maxAgeSec
                  nowEpoch:(double)now
               targetULIDs:(NSArray<NSString *> *)targetULIDs
                 sourceTag:(NSString *)sourceTag
            intoCandidates:(NSMutableArray<GSMSniffedOrder *> *)candidates {
    const char *cPath = [filePath fileSystemRepresentation];
    if (!cPath) return;
    struct stat st;
    if (stat(cPath, &st) != 0 || !S_ISREG(st.st_mode)) return;
    if (st.st_size < 64) return;
    if (maxAgeSec > 0.0 && (now - (double)st.st_mtimespec.tv_sec) > maxAgeSec) return;

    // Fast Stat Fingerprint Check (0.002ms):
    // If file mtime + size + active ULID list haven't changed since last check, skip open/pread/memmem completely!
    NSString *firstUlid = targetULIDs.firstObject ?: @"";
    NSString *statSig = [NSString stringWithFormat:@"%ld:%ld:%lld:%@",
                         (long)st.st_mtimespec.tv_sec,
                         (long)st.st_mtimespec.tv_nsec,
                         (long long)st.st_size,
                         firstUlid];
    NSString *prevSig = _fileStatCache[filePath];
    if (prevSig && [prevSig isEqualToString:statSig]) {
        return;
    }
    if (_fileStatCache.count >= 160) {
        [_fileStatCache removeAllObjects];
    }
    _fileStatCache[filePath] = statSig;

    NSNumber *prevSizeNum = _fileLastSizeMap[filePath];
    off_t prevSize = prevSizeNum ? (off_t)[prevSizeNum longLongValue] : 0;
    if (_fileLastSizeMap.count >= 160) {
        [_fileLastSizeMap removeAllObjects];
    }
    _fileLastSizeMap[filePath] = @(st.st_size);

    int fd = open(cPath, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return;

    size_t maxRead = kMaxDiskTailReadBytes; // 256 KB
    uint8_t *buf = _reusableFileBuf ?: (uint8_t *)malloc(maxRead);
    if (buf) {
        NSUInteger beforeCount = candidates.count;
        BOOL matchedTarget = NO;

        // 1. Delta-Offset Fast Read (<0.05ms):
        // When the file grew by <= 224KB since last scan, read ONLY the newly appended bytes (+32KB overlap) first!
        if (prevSize > 0 && st.st_size > prevSize && (st.st_size - prevSize) < (off_t)(maxRead - 32768)) {
            off_t deltaStart = (prevSize > 32768) ? (prevSize - 32768) : 0;
            size_t deltaLen = (size_t)(st.st_size - deltaStart);
            if (deltaLen > maxRead) deltaLen = maxRead;
            ssize_t dn = pread(fd, buf, deltaLen, deltaStart);
            if (dn > 64) {
                [self scanRawBuffer:buf length:(size_t)dn targetULIDs:targetULIDs sourceTag:sourceTag intoCandidates:candidates];
                if (firstUlid.length == 26 && _parsedOrderCache[firstUlid] != nil) {
                    matchedTarget = YES;
                } else if (firstUlid.length == 0 && candidates.count > beforeCount) {
                    matchedTarget = YES;
                }
            }
        }

        // 2. Tail 256KB Read:
        if (!matchedTarget) {
            size_t readLen = ((size_t)st.st_size > maxRead) ? maxRead : (size_t)st.st_size;
            off_t startOff = ((size_t)st.st_size > maxRead) ? (st.st_size - (off_t)maxRead) : 0;
            ssize_t n = pread(fd, buf, readLen, startOff);
            if (n > 64) {
                [self scanRawBuffer:buf length:(size_t)n targetULIDs:targetULIDs sourceTag:sourceTag intoCandidates:candidates];
                if (firstUlid.length == 26 && _parsedOrderCache[firstUlid] != nil) {
                    matchedTarget = YES;
                } else if (firstUlid.length == 0 && candidates.count > beforeCount) {
                    matchedTarget = YES;
                }
            }
        }

        // 3. SQLite WAL Checkpoint Wrap-Around Head Read:
        // When SQLite checkpoints Cache.db-wal, the file size stays >256KB on disk while new frames wrap around to offset 32 (Head)!
        if (!matchedTarget && (size_t)st.st_size > maxRead) {
            size_t headLen = MIN(maxRead, (size_t)st.st_size);
            ssize_t hn = pread(fd, buf, headLen, 0);
            if (hn > 64) {
                [self scanRawBuffer:buf length:(size_t)hn targetULIDs:targetULIDs sourceTag:sourceTag intoCandidates:candidates];
            }
        }

        if (buf != _reusableFileBuf) {
            free(buf);
        }
    }
    close(fd);
}

- (void)scanRecentFilesInDirectory:(NSString *)dirPath
                         maxAgeSec:(double)maxAgeSec
                          maxDepth:(int)maxDepth
                          nowEpoch:(double)now
                       targetULIDs:(NSArray<NSString *> *)targetULIDs
                         sourceTag:(NSString *)sourceTag
                    intoCandidates:(NSMutableArray<GSMSniffedOrder *> *)candidates {
    const char *dirC = [dirPath fileSystemRepresentation];
    if (!dirC) return;
    DIR *dir = opendir(dirC);
    if (!dir) return;

    struct dirent *ent = NULL;
    while ((ent = readdir(dir)) != NULL) {
        if (ent->d_name[0] == '.') continue;
        NSString *name = [NSString stringWithUTF8String:ent->d_name];
        if (!name) continue;
        NSString *fullPath = [dirPath stringByAppendingPathComponent:name];
        struct stat st;
        if (stat([fullPath fileSystemRepresentation], &st) != 0) continue;

        if (S_ISDIR(st.st_mode)) {
            if (maxDepth > 0) {
                [self scanRecentFilesInDirectory:fullPath
                                       maxAgeSec:maxAgeSec
                                        maxDepth:(maxDepth - 1)
                                        nowEpoch:now
                                     targetULIDs:targetULIDs
                                       sourceTag:sourceTag
                                  intoCandidates:candidates];
            }
        } else if (S_ISREG(st.st_mode)) {
            if (st.st_size >= 64 && (now - (double)st.st_mtimespec.tv_sec) <= maxAgeSec) {
                [self scanFileTailAtPath:fullPath
                               maxAgeSec:maxAgeSec
                                nowEpoch:now
                             targetULIDs:targetULIDs
                               sourceTag:sourceTag
                          intoCandidates:candidates];
            }
        }
    }
    closedir(dir);
}

- (void)scanDiskCachesWithConfig:(FilterConfig *)config
                     targetULIDs:(NSArray<NSString *> *)targetULIDs
                  intoCandidates:(NSMutableArray<GSMSniffedOrder *> *)candidates {
    // Seed candidates with any already-parsed orders in memory so _fileStatCache skips never hide cached orders
    for (NSString *uid in _parsedOrderLRU) {
        GSMSniffedOrder *cachedOrd = _parsedOrderCache[uid];
        if (cachedOrd && ![_handledOrderIds containsObject:cachedOrd.orderId] && ![candidates containsObject:cachedOrd]) {
            [candidates addObject:cachedOrd];
        }
    }

    [self ensureGSMContainerPathsResolvedWithConfig:config];
    if (_cachedContainerPath.length == 0 && _cachedCacheDirPath.length == 0) return;

    void (^scanDiskBlock)(void) = ^{
        double now = [[NSDate date] timeIntervalSince1970];

        // 1. Scan Cache.db-wal & Cache.db & fsCachedData in Library/Caches/vn.gsm.md
        if (self->_cachedCacheDirPath.length > 0) {
            double dbMaxAge = (targetULIDs.count > 0) ? 300.0 : 120.0;
            [self scanFileTailAtPath:[self->_cachedCacheDirPath stringByAppendingPathComponent:@"Cache.db-wal"]
                           maxAgeSec:dbMaxAge
                            nowEpoch:now
                         targetULIDs:targetULIDs
                           sourceTag:@"CacheWAL"
                      intoCandidates:candidates];
            [self scanFileTailAtPath:[self->_cachedCacheDirPath stringByAppendingPathComponent:@"Cache.db"]
                           maxAgeSec:dbMaxAge
                            nowEpoch:now
                         targetULIDs:targetULIDs
                           sourceTag:@"CacheDB"
                      intoCandidates:candidates];
            [self scanRecentFilesInDirectory:[self->_cachedCacheDirPath stringByAppendingPathComponent:@"fsCachedData"]
                                   maxAgeSec:60.0
                                    maxDepth:0
                                    nowEpoch:now
                                 targetULIDs:targetULIDs
                                   sourceTag:@"FSCache"
                              intoCandidates:candidates];
        }

        // 2. Scan broader container dirs at most once every 0.8s (only if primary CacheWAL/FSCache didn't already match active ULID)
        BOOL alreadyHasTarget = (targetULIDs.count > 0 && self->_parsedOrderCache[targetULIDs.firstObject] != nil);
        if (!alreadyHasTarget && self->_cachedContainerPath.length > 0 && (now - self->_lastDeepDirScanEpoch) >= 0.80) {
            self->_lastDeepDirScanEpoch = now;
            NSArray<NSArray<NSString *> *> *containerDirs = @[
                @[ [self->_cachedContainerPath stringByAppendingPathComponent:@"Library/Caches"],              @"LibCache" ],
                @[ [self->_cachedContainerPath stringByAppendingPathComponent:@"Documents"],                   @"Docs"     ],
                @[ [self->_cachedContainerPath stringByAppendingPathComponent:@"Library/Application Support"], @"AppSupp"  ],
                @[ [self->_cachedContainerPath stringByAppendingPathComponent:@"tmp"],                         @"Tmp"      ]
            ];
            for (NSArray<NSString *> *dEntry in containerDirs) {
                [self scanRecentFilesInDirectory:dEntry[0]
                                       maxAgeSec:60.0
                                        maxDepth:1
                                        nowEpoch:now
                                     targetULIDs:targetULIDs
                                       sourceTag:dEntry[1]
                                  intoCandidates:candidates];
            }
        }
        if (candidates.count == 0) {
            [self->_fileStatCache removeAllObjects];
        }
    };

    NSString *probePath = _cachedContainerPath.length > 0 ? _cachedContainerPath : _cachedCacheDirPath;
    if (probePath.length > 0 && access([probePath fileSystemRepresentation], R_OK) == 0) {
        scanDiskBlock();
    } else {
        [self performWithRootPrivileges:scanDiskBlock];
    }
}

#pragma mark - Layer 2: Passive Mach VM Heap Reader (Opportunistic via dlsym when kernel permits)

- (pid_t)findRunningDriverPIDWithConfig:(FilterConfig *)config {
    double now = [[NSDate date] timeIntervalSince1970];
    if (_cachedDriverPid > 1 && (now - _lastPidLookupEpoch) < 2.0) {
        if (kill(_cachedDriverPid, 0) == 0) {
            return _cachedDriverPid;
        }
    }
    _lastPidLookupEpoch = now;

    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0 || len == 0) return 0;

    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(len);
    if (!procs) return 0;

    pid_t foundPid = 0;
    NSString *cfgExec = config.driverAppExecName.length > 0 ? config.driverAppExecName : @"Driver";
    const char *cfgExecC = [cfgExec UTF8String];

    if (sysctl(mib, 4, procs, &len, NULL, 0) == 0) {
        size_t count = len / sizeof(struct kinfo_proc);
        for (size_t i = 0; i < count; i++) {
            pid_t p = procs[i].kp_proc.p_pid;
            if (p <= 1) continue;
            const char *comm = procs[i].kp_proc.p_comm;
            if (strcmp(comm, "Driver") == 0 ||
                (cfgExecC && strncmp(comm, cfgExecC, 15) == 0)) {
                foundPid = p;
                break;
            }
        }
    }
    free(procs);
    _cachedDriverPid = foundPid;
    return foundPid;
}

- (void)scanDriverProcessHeapWithConfig:(FilterConfig *)config
                            targetULIDs:(NSArray<NSString *> *)targetULIDs
                         intoCandidates:(NSMutableArray<GSMSniffedOrder *> *)candidates {
    if (!_reusableScanBuf) return;

    static task_for_pid_f sTaskForPid = NULL;
    static mach_vm_region_recurse_f sVmRegionRecurse = NULL;
    static mach_vm_read_overwrite_f sVmReadOverwrite = NULL;
    static dispatch_once_t sMachSymOnce;
    dispatch_once(&sMachSymOnce, ^{
        sTaskForPid      = (task_for_pid_f)dlsym(RTLD_DEFAULT, "task_for_pid");
        sVmRegionRecurse = (mach_vm_region_recurse_f)dlsym(RTLD_DEFAULT, "mach_vm_region_recurse");
        sVmReadOverwrite = (mach_vm_read_overwrite_f)dlsym(RTLD_DEFAULT, "mach_vm_read_overwrite");
    });
    if (!sTaskForPid || !sVmRegionRecurse || !sVmReadOverwrite) return;

    double now = [[NSDate date] timeIntervalSince1970];
    // Throttle full heap scan to at most once every 140ms to keep CPU/thermal impact at ~0%
    if ((now - _lastHeapScanEpoch) < 0.14) return;
    _lastHeapScanEpoch = now;

    pid_t driverPid = [self findRunningDriverPIDWithConfig:config];
    if (driverPid <= 1 || driverPid == _deniedTaskForPid) return;

    // Acquire Mach task port right; if kernel denies task_for_pid for this PID (standard non-jailbroken TrollStore),
    // cache _deniedTaskForPid = driverPid so we NEVER waste syscalls or euid switches on this PID again!
    __block mach_port_t task = MACH_PORT_NULL;
    kern_return_t kr = sTaskForPid(mach_task_self(), driverPid, &task);
    if (kr != KERN_SUCCESS || !MACH_PORT_VALID(task)) {
        [self performWithRootPrivileges:^{
            sTaskForPid(mach_task_self(), driverPid, &task);
        }];
    }
    if (!MACH_PORT_VALID(task)) {
        _deniedTaskForPid = driverPid;
        return;
    }

    @try {
        mach_vm_address_t addr = 0;
        mach_vm_size_t size    = 0;
        natural_t depth        = 0;
        size_t totalBytesScanned = 0;
        const size_t kMaxHeapScanPerTick = 28 * 1024 * 1024; // Cap to 28 MB of active MALLOC heap per scan (~2-5ms)

        while (totalBytesScanned < kMaxHeapScanPerTick) {
            vm_region_submap_info_data_64_t info;
            mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
            kr = sVmRegionRecurse(task, &addr, &size, &depth, (vm_region_recurse_info_t)&info, &count);
            if (kr != KERN_SUCCESS) break;

            if (info.is_submap) {
                depth++;
                continue;
            }

            mach_vm_address_t regionStart = addr;
            mach_vm_size_t regionSize     = size;
            addr += size;

            // Stop before shared dyld system cache (0x180000000+)
            if (regionStart >= 0x180000000ULL) break;

            // Skip unpopulated virtual reservations (0 resident pages in RAM)
            if (info.pages_resident == 0) {
                continue;
            }

            // Only inspect readable + writable, non-executable user heap/data regions (<= 16 MB each)
            BOOL isRWData = ((info.protection & VM_PROT_READ) != 0) &&
                            ((info.protection & VM_PROT_WRITE) != 0) &&
                            ((info.protection & VM_PROT_EXECUTE) == 0);
            if (!isRWData || regionSize < 4096 || regionSize > (16 * 1024 * 1024)) {
                continue;
            }

            // Only scan MALLOC / Foundation / anonymous heap tags where Swift/ObjC JSON buffers reside
            unsigned int tag = info.user_tag;
            BOOL isHeapTag = (tag == 0 ||
                              tag == VM_MEMORY_MALLOC ||
                              tag == VM_MEMORY_MALLOC_SMALL ||
                              tag == VM_MEMORY_MALLOC_LARGE ||
                              tag == VM_MEMORY_MALLOC_HUGE ||
                              tag == VM_MEMORY_MALLOC_TINY ||
                              tag == VM_MEMORY_MALLOC_LARGE_REUSABLE ||
                              tag == VM_MEMORY_MALLOC_LARGE_REUSED ||
                              tag == VM_MEMORY_MALLOC_NANO ||
                              tag == VM_MEMORY_MALLOC_MEDIUM ||
                              tag == VM_MEMORY_FOUNDATION ||
                              tag == 40);
            if (!isHeapTag) {
                continue;
            }

            // Read region in 64KB chunks with 8KB overlap so JSON spanning chunk boundaries is never split
            mach_vm_address_t curOffset = 0;
            while (curOffset < regionSize && totalBytesScanned < kMaxHeapScanPerTick) {
                mach_vm_size_t toRead = MIN((mach_vm_size_t)(kHeapScanChunkBytes + kHeapScanOverlap),
                                            regionSize - curOffset);
                if (toRead < 64) break;

                mach_vm_size_t outSize = 0;
                kern_return_t rkr = sVmReadOverwrite(task,
                                                     regionStart + curOffset,
                                                     toRead,
                                                     (mach_vm_address_t)self->_reusableScanBuf,
                                                     &outSize);
                if (rkr == KERN_SUCCESS && outSize >= 64) {
                    totalBytesScanned += (size_t)outSize;
                    [self scanRawBuffer:self->_reusableScanBuf
                                 length:(size_t)outSize
                            targetULIDs:targetULIDs
                              sourceTag:@"RAMHeap"
                         intoCandidates:candidates];
                    if (targetULIDs.count > 0 && candidates.count > 0) {
                        // Found exact target ULID in heap -> stop early!
                        for (GSMSniffedOrder *c in candidates) {
                            if ([c.orderId isEqualToString:targetULIDs.firstObject]) {
                                return;
                            }
                        }
                    }
                }
                if (curOffset + kHeapScanChunkBytes >= regionSize) break;
                curOffset += kHeapScanChunkBytes;
            }
        }
    } @finally {
        mach_port_deallocate(mach_task_self(), task);
    }
}

#pragma mark - Caching & 3-Lock Verification

- (void)cacheParsedOrder:(GSMSniffedOrder *)ord {
    if (!ord || ord.orderId.length != 26) return;
    if (!_parsedOrderCache[ord.orderId]) {
        if (_parsedOrderLRU.count >= 24) {
            NSString *oldest = _parsedOrderLRU.firstObject;
            if (oldest) {
                GSMSniffedOrder *oldOrd = _parsedOrderCache[oldest];
                for (NSString *sid in oldOrd.subOrderIds) {
                    if (_parsedOrderCache[sid] == oldOrd) {
                        [_parsedOrderCache removeObjectForKey:sid];
                    }
                }
                [_parsedOrderCache removeObjectForKey:oldest];
                [_parsedOrderLRU removeObjectAtIndex:0];
            }
        }
        [_parsedOrderLRU addObject:ord.orderId];
    }
    _parsedOrderCache[ord.orderId] = ord;
    for (NSString *sid in ord.subOrderIds) {
        if (sid.length == 26) {
            _parsedOrderCache[sid] = ord;
        }
    }
    _latestSniffedOrder = ord;
}

- (void)addSingleIdToHandledSet:(NSString *)uid {
    if (!uid || uid.length == 0) return;
    if (![_handledOrderIds containsObject:uid]) {
        if (_handledOrderQueue.count >= 48) {
            NSString *oldest = _handledOrderQueue.firstObject;
            if (oldest) {
                [_handledOrderIds removeObject:oldest];
                [_handledOrderQueue removeObjectAtIndex:0];
            }
        }
        [_handledOrderIds addObject:uid];
        [_handledOrderQueue addObject:uid];
    }
}

- (void)markOrderHandled:(NSString *)orderId {
    if (!orderId || orderId.length == 0) return;
    [_lock lock];
    GSMSniffedOrder *cached = _parsedOrderCache[orderId];
    [self addSingleIdToHandledSet:orderId];
    if (cached) {
        if (cached.orderId.length == 26) {
            [self addSingleIdToHandledSet:cached.orderId];
        }
        for (NSString *sid in cached.subOrderIds) {
            [self addSingleIdToHandledSet:sid];
        }
    }
    if (_latestSniffedOrder &&
        ([_latestSniffedOrder.orderId isEqualToString:orderId] ||
         [_latestSniffedOrder.subOrderIds containsObject:orderId])) {
        _latestSniffedOrder = nil;
    }
    [_lock unlock];
}

- (BOOL)isOrderIdHandled:(NSString *)orderId {
    if (!orderId || orderId.length == 0) return NO;
    [_lock lock];
    BOOL handled = [_handledOrderIds containsObject:orderId];
    [_lock unlock];
    return handled;
}

- (GSMSniffedOrder *)peekFreshUnverifiedOrderWithConfig:(FilterConfig *)config
                                              maxAgeSec:(double)maxAgeSec {
    [_lock lock];
    @try {
        double now = [[NSDate date] timeIntervalSince1970];
        double effectiveMaxAge = (maxAgeSec > 0.0) ? maxAgeSec : 7.5;
        NSArray<NSString *> *activeULIDs = [self readActiveOrderULIDsFromPreferencesWithConfig:config];

        // 1. Check in-memory cached order first
        if (_latestSniffedOrder &&
            _latestSniffedOrder.orderId.length == 26 &&
            ![_handledOrderIds containsObject:_latestSniffedOrder.orderId]) {
            BOOL isInActivePrefs = [activeULIDs containsObject:_latestSniffedOrder.orderId];
            if (!isInActivePrefs && _latestSniffedOrder.subOrderIds.count > 0) {
                for (NSString *sid in _latestSniffedOrder.subOrderIds) {
                    if ([activeULIDs containsObject:sid]) {
                        isInActivePrefs = YES;
                        break;
                    }
                }
            }
            double orderAge = (_latestSniffedOrder.orderTimestampEpoch > 0.0) ? fabs(now - _latestSniffedOrder.orderTimestampEpoch) : fabs(now - _latestSniffedOrder.sniffedAtEpoch);
            double sniffAge = fabs(now - _latestSniffedOrder.sniffedAtEpoch);
            double effectiveAge = MIN(orderAge, sniffAge);
            BOOL matchesFirstActive = (activeULIDs.count == 0 ||
                                       [activeULIDs.firstObject isEqualToString:_latestSniffedOrder.orderId] ||
                                       (_latestSniffedOrder.subOrderIds.count > 0 && [_latestSniffedOrder.subOrderIds containsObject:activeULIDs.firstObject]));
            if ((isInActivePrefs || effectiveAge <= effectiveMaxAge) && matchesFirstActive) {
                return _latestSniffedOrder;
            }
        }

        // 2. Scan disk caches (Delta-Offset + Head/Tail WAL Reader)
        NSMutableArray<GSMSniffedOrder *> *candidates = [NSMutableArray arrayWithCapacity:6];
        [self scanDiskCachesWithConfig:config targetULIDs:activeULIDs intoCandidates:candidates];

        [candidates sortUsingComparator:^NSComparisonResult(GSMSniffedOrder *a, GSMSniffedOrder *b) {
            return [b.orderId compare:a.orderId];
        }];

        for (GSMSniffedOrder *cand in candidates) {
            if (!cand || cand.orderId.length != 26) continue;
            if ([_handledOrderIds containsObject:cand.orderId]) continue;
            BOOL isInActivePrefs = [activeULIDs containsObject:cand.orderId];
            double orderAge = (cand.orderTimestampEpoch > 0.0) ? fabs(now - cand.orderTimestampEpoch) : fabs(now - cand.sniffedAtEpoch);
            double sniffAge = fabs(now - cand.sniffedAtEpoch);
            double effectiveAge = MIN(orderAge, sniffAge);
            if (isInActivePrefs || effectiveAge <= effectiveMaxAge) {
                _latestSniffedOrder = cand;
                return cand;
            }
        }
        return nil;
    } @catch (NSException *ex) {
        return nil;
    } @finally {
        [_lock unlock];
    }
}

#pragma mark - 2-Phase Kernel kqueue VNODE Monitor (0% Idle CPU, <0.2ms Wakeup)

- (void)startRealtimeKernelMonitorWithConfigProvider:(FilterConfig *(^)(void))configProvider
                                        eventHandler:(void (^)(NSString *ambushULID, GSMSniffedOrder *sniffedOrder))eventHandler {
    if (!configProvider || !eventHandler) return;
    [_lock lock];
    if (_kqueueMonitorRunning) {
        [_lock unlock];
        return;
    }
    _kqueueMonitorRunning = YES;
    [_lock unlock];

    FilterConfig *(^cfgCopy)(void) = [configProvider copy];
    void (^evtCopy)(NSString *, GSMSniffedOrder *) = [eventHandler copy];

    dispatch_queue_t kqQueue = dispatch_queue_create("com.shadow.pind.kqueue_sniffer", DISPATCH_QUEUE_SERIAL);
    dispatch_async(kqQueue, ^{
        int kq = kqueue();
        if (kq < 0) {
            [self->_lock lock];
            self->_kqueueMonitorRunning = NO;
            [self->_lock unlock];
            return;
        }
        [self->_lock lock];
        self->_kqueueFd = kq;
        [self->_lock unlock];

        int watchedFds[5] = { -1, -1, -1, -1, -1 };
        NSString *watchedPaths[5] = { nil, nil, nil, nil, nil };

        while (YES) {
            @autoreleasepool {
                [self->_lock lock];
                BOOL keepRunning = self->_kqueueMonitorRunning;
                [self->_lock unlock];
                if (!keepRunning) break;

                FilterConfig *cfg = cfgCopy();
                if (!cfg || !cfg.masterEnabled) {
                    for (int i = 0; i < 5; i++) {
                        if (watchedFds[i] >= 0) {
                            close(watchedFds[i]);
                            watchedFds[i] = -1;
                        }
                        watchedPaths[i] = nil;
                    }
                    usleep(500 * 1000);
                    continue;
                }

                [self->_lock lock];
                [self ensureGSMContainerPathsResolvedWithConfig:cfg];
                NSString *contPath  = self->_cachedContainerPath;
                NSString *prefsFile = self->_cachedPrefsPlistPath;
                NSString *cacheDir  = self->_cachedCacheDirPath;
                [self->_lock unlock];

                if (contPath.length == 0 && cacheDir.length == 0) {
                    usleep(800 * 1000);
                    continue;
                }

                NSString *prefsDir = prefsFile.length > 0 ? [prefsFile stringByDeletingLastPathComponent] : [contPath stringByAppendingPathComponent:@"Library/Preferences"];
                NSString *walFile  = cacheDir.length > 0 ? [cacheDir stringByAppendingPathComponent:@"Cache.db-wal"] : @"";
                NSString *fsDir    = cacheDir.length > 0 ? [cacheDir stringByAppendingPathComponent:@"fsCachedData"] : @"";

                NSArray<NSString *> *desiredPaths = @[
                    prefsDir ?: @"",
                    prefsFile ?: @"",
                    cacheDir ?: @"",
                    walFile ?: @"",
                    fsDir ?: @""
                ];

                // Ensure EVFILT_VNODE watches are registered for all existing target files/dirs
                for (int i = 0; i < 5; i++) {
                    NSString *p = desiredPaths[i];
                    if (p.length == 0) continue;
                    if (watchedFds[i] >= 0 && watchedPaths[i] && [watchedPaths[i] isEqualToString:p]) {
                        continue;
                    }
                    if (watchedFds[i] >= 0) {
                        close(watchedFds[i]);
                        watchedFds[i] = -1;
                        watchedPaths[i] = nil;
                    }

                    __block int fd = open([p fileSystemRepresentation], O_EVTONLY | O_CLOEXEC);
                    if (fd < 0) {
                        [self performWithRootPrivileges:^{
                            fd = open([p fileSystemRepresentation], O_EVTONLY | O_CLOEXEC);
                        }];
                    }
                    if (fd >= 0) {
                        struct kevent kev;
                        EV_SET(&kev,
                               fd,
                               EVFILT_VNODE,
                               EV_ADD | EV_ENABLE | EV_CLEAR,
                               NOTE_WRITE | NOTE_EXTEND | NOTE_ATTRIB | NOTE_RENAME | NOTE_DELETE | NOTE_REVOKE,
                               0,
                               (void *)(intptr_t)i);
                        if (kevent(kq, &kev, 1, NULL, 0, NULL) == 0) {
                            watchedFds[i] = fd;
                            watchedPaths[i] = p;
                        } else {
                            close(fd);
                        }
                    }
                }

                struct kevent events[8];
                struct timespec timeout;
                timeout.tv_sec = 1;
                timeout.tv_nsec = 200000000L; // 1.2s periodic refresh in case new files (e.g. Cache.db-wal) appear

                int nev = kevent(kq, NULL, 0, events, 8, &timeout);
                if (nev < 0) {
                    if (errno == EINTR) continue;
                    break;
                }
                if (nev == 0) {
                    continue;
                }

                // Re-open any rotated/deleted vnode immediately
                for (int e = 0; e < nev; e++) {
                    int idx = (int)(intptr_t)events[e].udata;
                    if (idx >= 0 && idx < 5 &&
                        (events[e].fflags & (NOTE_DELETE | NOTE_RENAME | NOTE_REVOKE)) != 0) {
                        if (watchedFds[idx] >= 0) {
                            close(watchedFds[idx]);
                            watchedFds[idx] = -1;
                            watchedPaths[idx] = nil;
                        }
                    }
                }

                // Phase 1 & Phase 2 Check upon VNODE write/extend/rename
                NSString *ambushToFire = nil;
                GSMSniffedOrder *orderToFire = nil;

                [self->_lock lock];
                @try {
                    double now = [[NSDate date] timeIntervalSince1970];
                    NSArray<NSString *> *activeULIDs = [self readActiveOrderULIDsFromPreferencesWithConfig:cfg];
                    NSString *newestULID = activeULIDs.firstObject;

                    // Phase 1: New ULID detected in Preferences!
                    if (newestULID.length == 26 &&
                        ![self->_handledOrderIds containsObject:newestULID] &&
                        ![newestULID isEqualToString:self->_lastNotifiedAmbushULID]) {
                        double ulidEpoch = [GSMOrderPayloadSniffer decodeULIDTimestampEpoch:newestULID];
                        if (ulidEpoch <= 0.0 || fabs(now - ulidEpoch) <= 20.0) {
                            self->_lastNotifiedAmbushULID = newestULID;
                            ambushToFire = newestULID;
                        }
                    }

                    // Phase 2: Check Disk Caches for full Order / GroupOrder JSON
                    NSMutableArray<GSMSniffedOrder *> *candidates = [NSMutableArray arrayWithCapacity:6];
                    [self scanDiskCachesWithConfig:cfg targetULIDs:activeULIDs intoCandidates:candidates];
                    [candidates sortUsingComparator:^NSComparisonResult(GSMSniffedOrder *a, GSMSniffedOrder *b) {
                        return [b.orderId compare:a.orderId];
                    }];

                    for (GSMSniffedOrder *cand in candidates) {
                        if (!cand || cand.orderId.length != 26) continue;
                        if ([self->_handledOrderIds containsObject:cand.orderId]) continue;
                        BOOL isInActivePrefs = [activeULIDs containsObject:cand.orderId];
                        double orderAge = (cand.orderTimestampEpoch > 0.0) ? fabs(now - cand.orderTimestampEpoch) : fabs(now - cand.sniffedAtEpoch);
                        double sniffAge = fabs(now - cand.sniffedAtEpoch);
                        double effectiveAge = MIN(orderAge, sniffAge);
                        if (isInActivePrefs || effectiveAge <= 10.0) {
                            self->_latestSniffedOrder = cand;
                            if (![cand.orderId isEqualToString:self->_lastNotifiedOrderJSONId]) {
                                self->_lastNotifiedOrderJSONId = cand.orderId;
                                orderToFire = cand;
                                if (!ambushToFire) {
                                    ambushToFire = cand.orderId;
                                }
                            }
                            break;
                        }
                    }
                } @catch (NSException *ex) {
                } @finally {
                    [self->_lock unlock];
                }

                if (ambushToFire || orderToFire) {
                    evtCopy(ambushToFire, orderToFire);
                }
            }
        }

        for (int i = 0; i < 5; i++) {
            if (watchedFds[i] >= 0) {
                close(watchedFds[i]);
                watchedFds[i] = -1;
            }
            watchedPaths[i] = nil;
        }
        [self->_lock lock];
        if (self->_kqueueFd >= 0) {
            close(self->_kqueueFd);
            self->_kqueueFd = -1;
        }
        self->_kqueueMonitorRunning = NO;
        [self->_lock unlock];
    });
}

- (void)stopRealtimeKernelMonitor {
    [_lock lock];
    _kqueueMonitorRunning = NO;
    if (_kqueueFd >= 0) {
        close(_kqueueFd);
        _kqueueFd = -1;
    }
    [_lock unlock];
}

- (BOOL)ocrText:(NSString *)ocrRaw sharesMeaningfulTokensWithPayloadStrings:(NSArray<NSString *> *)payloadStrings {
    NSString *normOCR = NormalizeVNText(ocrRaw ?: @"");
    if (normOCR.length < 5) return YES; // OCR text too short/unloaded -> do not reject

    NSMutableString *combinedPayload = [NSMutableString stringWithCapacity:128];
    for (NSString *ps in payloadStrings) {
        if ([ps isKindOfClass:[NSString class]] && ps.length > 0) {
            [combinedPayload appendFormat:@" %@", NormalizeVNText(ps)];
        }
    }
    if (combinedPayload.length < 4) return YES;

    // Extract alphanumeric tokens of length >= 3 from OCR text
    NSArray<NSString *> *parts = [normOCR componentsSeparatedByCharactersInSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]];
    NSInteger checkedTokens = 0;
    NSInteger matchedTokens = 0;

    for (NSString *tok in parts) {
        if (tok.length < 3) continue;
        // Skip generic UI words
        if ([tok isEqualToString:@"diem"] ||
            [tok isEqualToString:@"nhan"] ||
            [tok isEqualToString:@"giao"] ||
            [tok isEqualToString:@"hang"] ||
            [tok isEqualToString:@"khach"] ||
            [tok isEqualToString:@"don"] ||
            [tok isEqualToString:@"den"] ||
            [tok isEqualToString:@"viet"] ||
            [tok isEqualToString:@"nam"]) {
            continue;
        }
        checkedTokens++;
        if ([combinedPayload containsString:tok]) {
            matchedTokens++;
        }
    }

    if (checkedTokens == 0) return YES;
    return (matchedTokens >= 1);
}

- (BOOL)candidateOrder:(GSMSniffedOrder *)cand
     passesThreeLocksWithActiveULIDs:(NSArray<NSString *> *)activeULIDs
                         ocrPriceVND:(NSInteger)ocrPriceVND
                     isOCRHeaderFood:(BOOL)isOCRHeaderFood
                  isOCRHeaderNonFood:(BOOL)isOCRHeaderNonFood
                          pickupText:(NSString *)pickupText
                         dropoffText:(NSString *)dropoffText
                            nowEpoch:(double)now {
    if (!cand || cand.orderId.length != 26) return NO;

    // LOCK 1: Consumed / Handled Order Blacklist (including GroupOrder child ULIDs)
    if ([_handledOrderIds containsObject:cand.orderId]) {
        return NO;
    }
    for (NSString *sid in cand.subOrderIds) {
        if ([_handledOrderIds containsObject:sid]) {
            return NO;
        }
    }

    // LOCK 2: Freshness Window (Up to 45s so tapping a push banner from Home Screen 5-15s later works 100%!)
    BOOL isInActivePrefs = [activeULIDs containsObject:cand.orderId];
    if (!isInActivePrefs && cand.subOrderIds.count > 0) {
        for (NSString *sid in cand.subOrderIds) {
            if ([activeULIDs containsObject:sid]) {
                isInActivePrefs = YES;
                break;
            }
        }
    }
    double orderAge = (cand.orderTimestampEpoch > 0.0) ? fabs(now - cand.orderTimestampEpoch) : fabs(now - cand.sniffedAtEpoch);
    double sniffAge = fabs(now - cand.sniffedAtEpoch);
    double effectiveAge = MIN(orderAge, sniffAge);
    if (!isInActivePrefs && effectiveAge > 45.0) {
        return NO;
    }

    // LOCK 3: Visual OCR Coherence Cross-Check (Never override visible screen with a conflicting stale order!)
    // 3A. Service class conflict check
    if (isOCRHeaderFood && !cand.isGreenFood) {
        return NO;
    }
    if (isOCRHeaderNonFood && cand.isGreenFood) {
        return NO;
    }

    // 3B. Address token coherence check
    BOOL hasOCRPickup  = (pickupText.length >= 6);
    BOOL hasOCRDropoff = (dropoffText.length >= 6);
    BOOL pickupCoherent = [self ocrText:pickupText
      sharesMeaningfulTokensWithPayloadStrings:@[
          cand.pickupShortAddress ?: @"",
          cand.pickupName ?: @"",
          cand.pickupFullAddress ?: @"",
          cand.pickupNote ?: @"",
          cand.allAddressesCombined ?: @"",
          cand.allNotesCombined ?: @""
      ]];
    BOOL dropoffCoherent = [self ocrText:dropoffText
       sharesMeaningfulTokensWithPayloadStrings:@[
           cand.dropoffShortAddress ?: @"",
           cand.dropoffName ?: @"",
           cand.dropoffFullAddress ?: @"",
           cand.dropoffNote ?: @"",
           cand.allAddressesCombined ?: @"",
           cand.allNotesCombined ?: @""
       ]];

    if (hasOCRPickup && !pickupCoherent) {
        return NO;
    }
    if (!hasOCRPickup && hasOCRDropoff && !dropoffCoherent) {
        return NO;
    }

    // 3C. Price coherence check
    if (ocrPriceVND >= 8000 && cand.totalPayVND >= 8000) {
        BOOL exactPriceMatch = (ocrPriceVND == cand.totalPayVND ||
                                ocrPriceVND == cand.totalFeeVND ||
                                ocrPriceVND == cand.baseFeeVND);
        if (!exactPriceMatch) {
            // Only allow payload price to override OCR price if pickup/dropoff text is ALREADY confirmed matching on screen
            // (e.g. when OCR blurred "17.000đ" into "77.000đ" on the exact same restaurant address!)
            BOOL addressConfirmedOnScreen = (hasOCRPickup && pickupCoherent) || (hasOCRDropoff && dropoffCoherent);
            if (!addressConfirmedOnScreen) {
                return NO;
            }
        }
    }

    // 3D. If NO OCR text at all is visible yet (neither header, price, nor address),
    // require the payload to be either the active tripRequestOngoingHandler ULID or < 12 seconds old.
    if (!isOCRHeaderFood && !isOCRHeaderNonFood && ocrPriceVND <= 0 && !hasOCRPickup && !hasOCRDropoff) {
        if (!isInActivePrefs && effectiveAge > 12.0) {
            return NO;
        }
    }

    return YES;
}

- (GSMSniffedOrder *)sniffActiveOrderWithConfig:(FilterConfig *)config
                                   ocrPriceVND:(NSInteger)ocrPriceVND
                               isOCRHeaderFood:(BOOL)isOCRHeaderFood
                            isOCRHeaderNonFood:(BOOL)isOCRHeaderNonFood
                                    pickupText:(NSString *)pickupText
                                   dropoffText:(NSString *)dropoffText {
    [_lock lock];
    @try {
        double now = [[NSDate date] timeIntervalSince1970];
        NSArray<NSString *> *activeULIDs = [self readActiveOrderULIDsFromPreferencesWithConfig:config];

        // Fast Check 0: Does our in-memory cached order already match?
        if (_latestSniffedOrder &&
            (activeULIDs.count == 0 ||
             [activeULIDs.firstObject isEqualToString:_latestSniffedOrder.orderId] ||
             (_latestSniffedOrder.subOrderIds.count > 0 && [_latestSniffedOrder.subOrderIds containsObject:activeULIDs.firstObject]))) {
            if ([self candidateOrder:_latestSniffedOrder
                 passesThreeLocksWithActiveULIDs:activeULIDs
                                     ocrPriceVND:ocrPriceVND
                                 isOCRHeaderFood:isOCRHeaderFood
                              isOCRHeaderNonFood:isOCRHeaderNonFood
                                      pickupText:pickupText
                                     dropoffText:dropoffText
                                        nowEpoch:now]) {
                return _latestSniffedOrder;
            }
        }

        NSMutableArray<GSMSniffedOrder *> *candidates = [NSMutableArray arrayWithCapacity:6];

        // Layer 1: Scan Disk Caches (Cache.db-wal, Cache.db, fsCachedData) — <0.4ms
        [self scanDiskCachesWithConfig:config targetULIDs:activeULIDs intoCandidates:candidates];

        // Check if Layer 1 found a valid candidate passing all 3 locks
        [candidates sortUsingComparator:^NSComparisonResult(GSMSniffedOrder *a, GSMSniffedOrder *b) {
            return [b.orderId compare:a.orderId]; // Newest ULID first
        }];
        for (GSMSniffedOrder *cand in candidates) {
            if ([self candidateOrder:cand
                 passesThreeLocksWithActiveULIDs:activeULIDs
                                     ocrPriceVND:ocrPriceVND
                                 isOCRHeaderFood:isOCRHeaderFood
                              isOCRHeaderNonFood:isOCRHeaderNonFood
                                      pickupText:pickupText
                                     dropoffText:dropoffText
                                        nowEpoch:now]) {
                _latestSniffedOrder = cand;
                return cand;
            }
        }

        // Layer 2: Passive Mach VM Heap Reader on Driver process (if Layer 1 missed) — <8ms
        [self scanDriverProcessHeapWithConfig:config targetULIDs:activeULIDs intoCandidates:candidates];

        [candidates sortUsingComparator:^NSComparisonResult(GSMSniffedOrder *a, GSMSniffedOrder *b) {
            return [b.orderId compare:a.orderId];
        }];
        for (GSMSniffedOrder *cand in candidates) {
            if ([self candidateOrder:cand
                 passesThreeLocksWithActiveULIDs:activeULIDs
                                     ocrPriceVND:ocrPriceVND
                                 isOCRHeaderFood:isOCRHeaderFood
                              isOCRHeaderNonFood:isOCRHeaderNonFood
                                      pickupText:pickupText
                                     dropoffText:dropoffText
                                        nowEpoch:now]) {
                _latestSniffedOrder = cand;
                return cand;
            }
        }

        return nil;
    } @catch (NSException *ex) {
        return nil;
    } @finally {
        [_lock unlock];
    }
}

@end
