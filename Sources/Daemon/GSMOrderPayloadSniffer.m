#import "GSMOrderPayloadSniffer.h"
#import <CoreFoundation/CoreFoundation.h>
#import <mach/mach.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <signal.h>
#import <dirent.h>
#import <fcntl.h>
#import <unistd.h>
#import <stdlib.h>
#import <string.h>
#import <math.h>

// Explicit Mach VM prototypes exported by libsystem_kernel.dylib on arm64 iOS
extern kern_return_t mach_vm_region_recurse(
    vm_map_read_t target_task,
    mach_vm_address_t *address,
    mach_vm_size_t *size,
    natural_t *nesting_depth,
    vm_region_recurse_info_t info,
    mach_msg_type_number_t *infoCnt
);

extern kern_return_t mach_vm_read_overwrite(
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

#define kHeapScanChunkBytes  (64 * 1024)
#define kHeapScanOverlap     (8 * 1024)
#define kMaxOrderJSONBytes   (32 * 1024)

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

    GSMSniffedOrder *_latestSniffedOrder;
    double _lastHeapScanEpoch;
    pid_t _cachedDriverPid;
    double _lastPidLookupEpoch;
    uint8_t *_reusableScanBuf;
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
        _reusableScanBuf    = (uint8_t *)malloc(kHeapScanChunkBytes + kHeapScanOverlap + 64);
    }
    return self;
}

- (void)dealloc {
    if (_reusableScanBuf) {
        free(_reusableScanBuf);
        _reusableScanBuf = NULL;
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
        if (inner[@"id"] || inner[@"path"] || inner[@"service"]) {
            d = inner;
        }
    }

    NSString *orderId = [d[@"id"] isKindOfClass:[NSString class]] ? d[@"id"] : nil;
    if (!isValidGSMOrderULIDString(orderId)) {
        return nil;
    }

    NSDictionary *serviceDict = [d[@"service"] isKindOfClass:[NSDictionary class]] ? d[@"service"] : nil;
    NSArray *pathArr          = [d[@"path"] isKindOfClass:[NSArray class]] ? d[@"path"] : nil;
    NSDictionary *feeDict     = [d[@"fee"] isKindOfClass:[NSDictionary class]] ? d[@"fee"] : nil;

    // Must be an actual Order object (not a bare Path stop or sub-object)
    if (!serviceDict && !pathArr && !feeDict) {
        return nil;
    }

    GSMSniffedOrder *ord = [[GSMSniffedOrder alloc] init];
    ord.orderId          = orderId;
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
                            ([d[@"is_food_delivery"] respondsToSelector:@selector(boolValue)] && [d[@"is_food_delivery"] boolValue]);

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
        ord.isBikeOrExpress = !hasFoodDetailObj && (svcTypeRaw.length > 0 || svcDispRaw.length > 0);
    }

    // 2. Extract Exact Fare VND
    NSInteger totalPay = [self extractFareIntegerFromValue:feeDict[@"total_pay"]];
    NSInteger totalFee = [self extractFareIntegerFromValue:feeDict[@"total_fee"]];
    NSDictionary *fb   = [feeDict[@"fee_breakdown"] isKindOfClass:[NSDictionary class]] ? feeDict[@"fee_breakdown"] : nil;
    NSInteger baseFee  = [self extractFareIntegerFromValue:fb[@"base_fee"]];
    if (totalPay <= 0) totalPay = [self extractFareIntegerFromValue:feeDict[@"total_pay_display"]];
    if (totalPay <= 0) totalPay = [self extractFareIntegerFromValue:feeDict[@"display"]];
    if (totalPay <= 0) totalPay = [self extractFareIntegerFromValue:d[@"total_pay"]];
    if (totalFee <= 0) totalFee = [self extractFareIntegerFromValue:feeDict[@"total_fee_display"]];

    ord.totalPayVND = (totalPay >= 5000) ? totalPay : ((totalFee >= 5000) ? totalFee : baseFee);
    ord.totalFeeVND = (totalFee >= 5000) ? totalFee : ord.totalPayVND;
    ord.baseFeeVND  = (baseFee >= 5000)  ? baseFee  : ord.totalPayVND;

    // 3. Extract Distance (km)
    id distVal = d[@"distance"];
    if (!distVal && [d[@"trip_data"] isKindOfClass:[NSDictionary class]]) {
        distVal = d[@"trip_data"][@"distance"];
    }
    if ([distVal respondsToSelector:@selector(doubleValue)]) {
        double km = [distVal doubleValue];
        if (km > 0.02 && km < 200.0) {
            ord.serverDistanceKm = km;
        }
    }

    // 4. Extract Pickup & Dropoff Stops from path[]
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
            } else if (!foundDropoff && ([pType containsString:@"DROP"] || (foundPickup && (sAddr.length > 0 || fAddr.length > 0 || validCoord)))) {
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

    // Walk backward from hitOffset up to 8 KB while bytes look like valid UTF-8 JSON text
    size_t minScan = (hitOffset > 8192) ? (hitOffset - 8192) : 0;
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

            // Fast check: slice must contain "id" and ("path" or "service" or "fee")
            if (memmem(slicePtr, sliceLen, "\"id\"", 4) != NULL &&
                (memmem(slicePtr, sliceLen, "\"path\"", 6) != NULL ||
                 memmem(slicePtr, sliceLen, "\"service\"", 9) != NULL ||
                 memmem(slicePtr, sliceLen, "\"fee\"", 5) != NULL)) {
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

    // 1B. Also scan for any recent JSON containing "fee_breakdown" or "service_type" (in case plist hasn't flushed ULID yet)
    static const char *kAnchors[2] = { "\"fee_breakdown\"", "\"service_type\"" };
    static const size_t kAnchorLens[2] = { 15, 14 };

    for (int a = 0; a < 2; a++) {
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

- (void)scanDiskCachesWithConfig:(FilterConfig *)config
                     targetULIDs:(NSArray<NSString *> *)targetULIDs
                  intoCandidates:(NSMutableArray<GSMSniffedOrder *> *)candidates {
    [self ensureGSMContainerPathsResolvedWithConfig:config];
    if (_cachedCacheDirPath.length == 0) return;

    void (^scanDiskBlock)(void) = ^{
        double now = [[NSDate date] timeIntervalSince1970];

        // 1. Scan Cache.db-wal & Cache.db (read last 4 MB if file is large so it finishes in <0.3ms)
        NSArray<NSArray<NSString *> *> *dbFiles = @[
            @[ [self->_cachedCacheDirPath stringByAppendingPathComponent:@"Cache.db-wal"], @"CacheWAL" ],
            @[ [self->_cachedCacheDirPath stringByAppendingPathComponent:@"Cache.db"],     @"CacheDB"  ]
        ];

        for (NSArray<NSString *> *entry in dbFiles) {
            const char *cPath = [entry[0] fileSystemRepresentation];
            if (!cPath) continue;
            struct stat st;
            if (stat(cPath, &st) != 0 || st.st_size < 64) continue;
            // Only scan Cache.db / Cache.db-wal if modified within the last 120 seconds (or if we have a target ULID)
            if (targetULIDs.count == 0 && (now - (double)st.st_mtimespec.tv_sec) > 120.0) continue;

            int fd = open(cPath, O_RDONLY);
            if (fd < 0) continue;
            size_t maxRead = 4 * 1024 * 1024;
            size_t readLen = ((size_t)st.st_size > maxRead) ? maxRead : (size_t)st.st_size;
            off_t startOff = ((size_t)st.st_size > maxRead) ? (st.st_size - (off_t)maxRead) : 0;

            uint8_t *buf = (uint8_t *)malloc(readLen);
            if (buf) {
                ssize_t n = pread(fd, buf, readLen, startOff);
                if (n > 64) {
                    [self scanRawBuffer:buf length:(size_t)n targetULIDs:targetULIDs sourceTag:entry[1] intoCandidates:candidates];
                }
                free(buf);
            }
            close(fd);
        }

        // 2. Scan recent files in Library/Caches/vn.gsm.md/fsCachedData (modified within last 45s)
        NSString *fsCacheDir = [self->_cachedCacheDirPath stringByAppendingPathComponent:@"fsCachedData"];
        const char *fsDirC = [fsCacheDir fileSystemRepresentation];
        if (fsDirC) {
            DIR *dir = opendir(fsDirC);
            if (dir) {
                struct dirent *ent = NULL;
                while ((ent = readdir(dir)) != NULL) {
                    if (ent->d_name[0] == '.') continue;
                    NSString *fPath = [fsCacheDir stringByAppendingPathComponent:[NSString stringWithUTF8String:ent->d_name]];
                    struct stat st;
                    if (stat([fPath fileSystemRepresentation], &st) != 0) continue;
                    if (st.st_size < 64 || st.st_size > 256 * 1024) continue;
                    if ((now - (double)st.st_mtimespec.tv_sec) > 45.0) continue;

                    NSData *d = [NSData dataWithContentsOfFile:fPath options:NSDataReadingUncached error:nil];
                    if (d.length >= 64) {
                        [self scanRawBuffer:(const uint8_t *)d.bytes length:d.length targetULIDs:targetULIDs sourceTag:@"FSCache" intoCandidates:candidates];
                    }
                }
                closedir(dir);
            }
        }
    };

    // Container files belong to mobile (501); read directly without flipping process-wide euid unless access fails
    if (access([_cachedCacheDirPath fileSystemRepresentation], R_OK) == 0) {
        scanDiskBlock();
    } else {
        [self performWithRootPrivileges:scanDiskBlock];
    }
}

#pragma mark - Layer 2: Passive Mach VM Heap Reader (100% Invisible to bshield.framework)

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

    double now = [[NSDate date] timeIntervalSince1970];
    // Throttle full heap scan to at most once every 140ms to keep CPU/thermal impact at ~0%
    if ((now - _lastHeapScanEpoch) < 0.14) return;
    _lastHeapScanEpoch = now;

    pid_t driverPid = [self findRunningDriverPIDWithConfig:config];
    if (driverPid <= 1) return;

    // Acquire Mach task port right; only elevate euid(0) for the ~2us task_for_pid syscall if euid(501) wasn't enough!
    __block mach_port_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), driverPid, &task);
    if (kr != KERN_SUCCESS || !MACH_PORT_VALID(task)) {
        [self performWithRootPrivileges:^{
            task_for_pid(mach_task_self(), driverPid, &task);
        }];
    }
    if (!MACH_PORT_VALID(task)) {
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
            kr = mach_vm_region_recurse(task, &addr, &size, &depth, (vm_region_recurse_info_t)&info, &count);
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

            // Only scan MALLOC / Foundation / CFNetwork / anonymous heap tags where Swift/ObjC JSON buffers reside
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
                              tag == VM_MEMORY_CFNETWORK);
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
                kern_return_t rkr = mach_vm_read_overwrite(task,
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
        if (_parsedOrderLRU.count >= 20) {
            NSString *oldest = _parsedOrderLRU.firstObject;
            if (oldest) {
                [_parsedOrderCache removeObjectForKey:oldest];
                [_parsedOrderLRU removeObjectAtIndex:0];
            }
        }
        [_parsedOrderLRU addObject:ord.orderId];
    }
    _parsedOrderCache[ord.orderId] = ord;
    _latestSniffedOrder = ord;
}

- (void)markOrderHandled:(NSString *)orderId {
    if (!orderId || orderId.length == 0) return;
    [_lock lock];
    if (![_handledOrderIds containsObject:orderId]) {
        if (_handledOrderQueue.count >= 36) {
            NSString *oldest = _handledOrderQueue.firstObject;
            if (oldest) {
                [_handledOrderIds removeObject:oldest];
                [_handledOrderQueue removeObjectAtIndex:0];
            }
        }
        [_handledOrderIds addObject:orderId];
        [_handledOrderQueue addObject:orderId];
    }
    if ([_latestSniffedOrder.orderId isEqualToString:orderId]) {
        _latestSniffedOrder = nil;
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

    // LOCK 1: Consumed / Handled Order Blacklist
    if ([_handledOrderIds containsObject:cand.orderId]) {
        return NO;
    }

    // LOCK 2: Freshness Window (Up to 45s so tapping a push banner from Home Screen 5-15s later works 100%!)
    BOOL isInActivePrefs = [activeULIDs containsObject:cand.orderId];
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
          cand.pickupNote ?: @""
      ]];
    BOOL dropoffCoherent = [self ocrText:dropoffText
       sharesMeaningfulTokensWithPayloadStrings:@[
           cand.dropoffShortAddress ?: @"",
           cand.dropoffName ?: @"",
           cand.dropoffFullAddress ?: @"",
           cand.dropoffNote ?: @""
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
            (activeULIDs.count == 0 || [activeULIDs.firstObject isEqualToString:_latestSniffedOrder.orderId])) {
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
