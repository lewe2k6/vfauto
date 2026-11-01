#import "HanoiFoodFilterEngine.h"
#import <mach-o/dyld.h>
#import <zlib.h>
#import <math.h>
#import <stdlib.h>
#import <string.h>

#define kHashTableBuckets 32768U
#define kHashTableMask    (kHashTableBuckets - 1U)

typedef struct {
    float lat;
    float lng;
    int32_t orderCount;
    int16_t ngoNum;
    int16_t houseNum;
    uint8_t isMallFlag;
    uint8_t reserved[3];
    const char *mcName;
    const char *fullLabel;
    const char *newLabel;
    const char *addrDiff;
    const char *streetKey;
    const char *adminKey;
} HanoiMerchantRow;

typedef struct {
    float lat;
    float lng;
    const char *wardName;
} HanoiWardRow;

@implementation FoodFilterEvaluation
@end

static uint64_t fnv1aHashCString(const char *s) {
    uint64_t h = 14695981039346656037ULL;
    if (!s) return h;
    const unsigned char *p = (const unsigned char *)s;
    while (*p) {
        h ^= (uint64_t)(*p++);
        h *= 1099511628211ULL;
    }
    return h;
}

static double haversineDistanceKm(double lat1, double lon1, double lat2, double lon2) {
    const double R = 6371.0;
    double p1 = lat1 * (M_PI / 180.0);
    double p2 = lat2 * (M_PI / 180.0);
    double dp = (lat2 - lat1) * (M_PI / 180.0);
    double dl = (lon2 - lon1) * (M_PI / 180.0);
    double s1 = sin(dp * 0.5);
    double s2 = sin(dl * 0.5);
    double a  = s1 * s1 + cos(p1) * cos(p2) * s2 * s2;
    if (a > 1.0) a = 1.0;
    if (a < 0.0) a = 0.0;
    return 2.0 * R * asin(sqrt(a));
}

static double hanoiRedRiverChannelLng(double lat) {
    if (lat >= 21.090) {
        return 105.818 - (lat - 21.090) * 1.72;
    } else if (lat >= 21.045) {
        return 105.862 - (lat - 21.045) * 0.98;
    } else if (lat >= 21.005) {
        return 105.905 - (lat - 21.005) * 1.07;
    }
    return 105.905 + (21.005 - lat) * 0.22;
}

static BOOL crossesHanoiRedRiver(double latA, double lngA, double latB, double lngB) {
    double sideA = lngA - hanoiRedRiverChannelLng(latA);
    double sideB = lngB - hanoiRedRiverChannelLng(latB);
    return ((sideA * sideB) < 0.0);
}

static double estimateHanoiMotorbikeRoadKmOffline(double latA, double lngA, double latB, double lngB) {
    double airKm = haversineDistanceKm(latA, lngA, latB, lngB);
    if (crossesHanoiRedRiver(latA, lngA, latB, lngB)) {
        return fmax(airKm * 1.55, airKm + 1.15);
    }
    return airKm * 1.33;
}

static inline BOOL isAsciiWordChar(unichar c) {
    return ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'));
}

static BOOL containsNormalizedPhraseOnWordBoundary(NSString *haystack, NSString *needle) {
    if (!haystack || !needle || needle.length == 0 || haystack.length < needle.length) return NO;
    NSUInteger hLen = haystack.length;
    NSUInteger nLen = needle.length;
    NSRange searchRange = NSMakeRange(0, hLen);

    while (searchRange.length >= nLen) {
        NSRange r = [haystack rangeOfString:needle options:0 range:searchRange];
        if (r.location == NSNotFound) return NO;

        BOOL leftOk = (r.location == 0) || !isAsciiWordChar([haystack characterAtIndex:r.location - 1]);
        NSUInteger endIdx = r.location + r.length;
        BOOL rightOk = (endIdx >= hLen) || !isAsciiWordChar([haystack characterAtIndex:endIdx]);

        // Allow plural/possessive suffix on brands like "mcdonald" -> "mcdonalds" or "4p" -> "4ps"
        if (!rightOk && endIdx < hLen && [haystack characterAtIndex:endIdx] == 's') {
            rightOk = (endIdx + 1 >= hLen) || !isAsciiWordChar([haystack characterAtIndex:endIdx + 1]);
        }

        if (leftOk && rightOk) {
            return YES;
        }
        NSUInteger nextStart = r.location + 1;
        searchRange = NSMakeRange(nextStart, hLen - nextStart);
    }
    return NO;
}

@implementation HanoiFoodFilterEngine {
    char *_arena;
    size_t _arenaSize;
    HanoiMerchantRow *_merchants;
    int32_t _merchantCount;
    HanoiWardRow *_wards;
    int32_t _wardCount;

    // Hash table 1: Separate collision-free bucket arrays for fullLabel, newLabel, addrDiff
    int32_t *_flBuckets;
    int32_t *_nlBuckets;
    int32_t *_adBuckets;
    int32_t *_labelNextFL;
    int32_t *_labelNextNL;
    int32_t *_labelNextAD;

    // Hash table 2: Street key lookup (streetKey -> merchant idx chain)
    int32_t *_streetBuckets;
    int32_t *_streetNext;

    NSRegularExpression *_structuralMallRegex;
    NSRegularExpression *_ngoStreetRegex;
    NSRegularExpression *_numStreetRegex;
    NSRegularExpression *_plainStreetRegex;
    NSRegularExpression *_firstNumberRegex;
    NSRegularExpression *_leadingDotNoiseRegex;

    NSString *_cachedMallKwRaw;
    NSArray<NSString *> *_cachedMallKwNormList;
    NSString *_cachedChainKwRaw;
    NSArray<NSString *> *_cachedChainKwNormList;

    NSURLSession *_fastNetSession;
    NSLock *_cacheLock;
    NSMutableDictionary<NSString *, NSValue *> *_geocodeCache;
    NSMutableArray<NSString *> *_geocodeLRU;
    NSMutableDictionary<NSString *, NSNumber *> *_routeDistCache;
    NSMutableArray<NSString *> *_routeSourceKeys;
    NSMutableDictionary<NSString *, NSString *> *_routeSourceTagCache;

    // Circuit breaker when 4G is completely dead: avoid hitting network for 6s after consecutive timeouts
    double _netCooldownUntilEpoch;
    int _consecutiveNetTimeouts;
}

+ (instancetype)sharedEngine {
    static HanoiFoodFilterEngine *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[HanoiFoodFilterEngine alloc] init];
    });
    return inst;
}

- (NSInteger)loadedMerchantCount {
    return (NSInteger)_merchantCount;
}

- (BOOL)isIndexReady {
    return (_merchantCount > 0 && _merchants != NULL);
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _arena         = NULL;
        _arenaSize     = 0;
        _merchants     = NULL;
        _merchantCount = 0;
        _wards         = NULL;
        _wardCount     = 0;

        _cacheLock           = [[NSLock alloc] init];
        _geocodeCache        = [NSMutableDictionary dictionaryWithCapacity:260];
        _geocodeLRU          = [NSMutableArray arrayWithCapacity:260];
        _routeDistCache      = [NSMutableDictionary dictionaryWithCapacity:260];
        _routeSourceKeys     = [NSMutableArray arrayWithCapacity:260];
        _routeSourceTagCache = [NSMutableDictionary dictionaryWithCapacity:260];

        _netCooldownUntilEpoch  = 0.0;
        _consecutiveNetTimeouts = 0;

        _structuralMallRegex = [NSRegularExpression regularExpressionWithPattern:
            @"\\b(tang\\s*ham|ham\\s*b[1-4]|b[1-3]\\s*-\\s*[a-z0-9]|l[1-6]\\s*-\\s*[0-9a-z]|lo\\s*l[1-6]|lo\\s*b[1-3]|tang\\s*l[1-6]|gian\\s*hang|kiosk|food\\s*court|goods\\s*court)\\b"
            options:0 error:nil];

        _ngoStreetRegex = [NSRegularExpression regularExpressionWithPattern:
            @"\\b(?:ngo|ng)\\s+(\\d+)[a-z]?\\s+(?:duong\\s+|pho\\s+|p\\s+)?([a-z][a-z0-9\\s]{2,32})$"
            options:0 error:nil];

        _numStreetRegex = [NSRegularExpression regularExpressionWithPattern:
            @"^(?:so\\s+|sn\\s+)?(\\d+)[a-z]?(?:/\\d+[a-z]?)?\\s+(?:duong\\s+|pho\\s+|p\\s+)?([a-z][a-z0-9\\s]{2,32})$"
            options:0 error:nil];

        _plainStreetRegex = [NSRegularExpression regularExpressionWithPattern:
            @"\\b(?:duong|pho)\\s+([a-z][a-z0-9\\s]{2,32})$"
            options:0 error:nil];

        _firstNumberRegex = [NSRegularExpression regularExpressionWithPattern:
            @"\\b(\\d{1,4})\\b"
            options:0 error:nil];

        _leadingDotNoiseRegex = [NSRegularExpression regularExpressionWithPattern:
            @"^[oO•●◉\\-]+\\s+"
            options:0 error:nil];

        NSURLSessionConfiguration *sc = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        sc.timeoutIntervalForRequest  = 0.78;
        sc.timeoutIntervalForResource = 0.85;
        sc.waitsForConnectivity       = NO; // Crucial for weak 4G: NEVER stall waiting for radio!
        sc.HTTPMaximumConnectionsPerHost = 2;
        _fastNetSession = [NSURLSession sessionWithConfiguration:sc];

        [self loadEmbeddedHanoiIndex];
    }
    return self;
}

- (void)dealloc {
    if (_arena) free(_arena);
    if (_merchants) free(_merchants);
    if (_wards) free(_wards);
    if (_flBuckets) free(_flBuckets);
    if (_nlBuckets) free(_nlBuckets);
    if (_adBuckets) free(_adBuckets);
    if (_labelNextFL) free(_labelNextFL);
    if (_labelNextNL) free(_labelNextNL);
    if (_labelNextAD) free(_labelNextAD);
    if (_streetBuckets) free(_streetBuckets);
    if (_streetNext) free(_streetNext);
}

#pragma mark - Embedded Zlib Index Loader (17,014 Hanoi Merchants)

- (NSString *)locateIndexFilePath {
    char execBuf[2048];
    uint32_t bufSize = sizeof(execBuf);
    if (_NSGetExecutablePath(execBuf, &bufSize) == 0) {
        char realBuf[PATH_MAX];
        const char *resolved = realpath(execBuf, realBuf) ? realBuf : execBuf;
        NSString *execPath = [NSString stringWithUTF8String:resolved];
        NSString *dir = [execPath stringByDeletingLastPathComponent];
        NSString *cand = [dir stringByAppendingPathComponent:@"hanoi_food_index.zlib"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:cand]) {
            return cand;
        }
    }
    NSString *bundleRes = [[NSBundle mainBundle] pathForResource:@"hanoi_food_index" ofType:@"zlib"];
    if (bundleRes && [[NSFileManager defaultManager] fileExistsAtPath:bundleRes]) {
        return bundleRes;
    }
    return nil;
}

- (void)loadEmbeddedHanoiIndex {
    NSString *zlibPath = [self locateIndexFilePath];
    if (!zlibPath) return;

    NSData *compData = [NSData dataWithContentsOfFile:zlibPath options:NSDataReadingUncached error:nil];
    if (!compData || compData.length < 64) return;

    size_t cap = compData.length * 7;
    if (cap < 5 * 1024 * 1024) cap = 5 * 1024 * 1024;
    char *outBuf = (char *)malloc(cap);
    if (!outBuf) return;

    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    strm.next_in  = (Bytef *)compData.bytes;
    strm.avail_in = (uInt)compData.length;

    if (inflateInit(&strm) != Z_OK) {
        free(outBuf);
        return;
    }

    int ret = Z_OK;
    while (ret == Z_OK) {
        if (strm.total_out + 65536 > cap) {
            size_t newCap = cap + (2 * 1024 * 1024);
            char *grown = (char *)realloc(outBuf, newCap);
            if (!grown) {
                inflateEnd(&strm);
                free(outBuf);
                return;
            }
            outBuf = grown;
            cap = newCap;
        }
        strm.next_out  = (Bytef *)(outBuf + strm.total_out);
        strm.avail_out = (uInt)(cap - strm.total_out - 1);
        ret = inflate(&strm, Z_NO_FLUSH);
    }

    size_t outLen = strm.total_out;
    inflateEnd(&strm);
    compData = nil; // Release compressed buffer immediately

    if (ret != Z_STREAM_END || outLen < 32) {
        free(outBuf);
        return;
    }

    char *trimmed = (char *)realloc(outBuf, outLen + 1);
    _arena = trimmed ? trimmed : outBuf;
    _arena[outLen] = '\0';
    _arenaSize = outLen;

    // Parse header: HANOI_FOOD_INDEX_V1 \t <merchantCount> \t <wardCount>
    char *cursor = _arena;
    char *firstNL = strchr(cursor, '\n');
    if (!firstNL) return;
    *firstNL = '\0';

    if (strncmp(cursor, "HANOI_FOOD_INDEX_V1\t", 20) != 0) return;
    int expectedMerchants = 0, expectedWards = 0;
    sscanf(cursor + 20, "%d\t%d", &expectedMerchants, &expectedWards);
    if (expectedMerchants <= 0 || expectedMerchants > 200000) return;

    _merchants     = (HanoiMerchantRow *)calloc((size_t)expectedMerchants, sizeof(HanoiMerchantRow));
    _wards         = expectedWards > 0 ? (HanoiWardRow *)calloc((size_t)expectedWards, sizeof(HanoiWardRow)) : NULL;
    _flBuckets     = (int32_t *)malloc(kHashTableBuckets * sizeof(int32_t));
    _nlBuckets     = (int32_t *)malloc(kHashTableBuckets * sizeof(int32_t));
    _adBuckets     = (int32_t *)malloc(kHashTableBuckets * sizeof(int32_t));
    _streetBuckets = (int32_t *)malloc(kHashTableBuckets * sizeof(int32_t));
    _labelNextFL   = (int32_t *)malloc((size_t)expectedMerchants * sizeof(int32_t));
    _labelNextNL   = (int32_t *)malloc((size_t)expectedMerchants * sizeof(int32_t));
    _labelNextAD   = (int32_t *)malloc((size_t)expectedMerchants * sizeof(int32_t));
    _streetNext    = (int32_t *)malloc((size_t)expectedMerchants * sizeof(int32_t));

    if (!_merchants || !_flBuckets || !_nlBuckets || !_adBuckets || !_streetBuckets ||
        !_labelNextFL || !_labelNextNL || !_labelNextAD || !_streetNext) {
        return;
    }

    for (uint32_t b = 0; b < kHashTableBuckets; b++) {
        _flBuckets[b]     = -1;
        _nlBuckets[b]     = -1;
        _adBuckets[b]     = -1;
        _streetBuckets[b] = -1;
    }

    cursor = firstNL + 1;
    int32_t mIdx = 0;
    int32_t wIdx = 0;

    while (*cursor != '\0') {
        char *nl = strchr(cursor, '\n');
        if (nl) {
            if (nl > cursor && *(nl - 1) == '\r') *(nl - 1) = '\0';
            *nl = '\0';
        }

        if (cursor[0] == '@' && cursor[1] == 'W' && cursor[2] == '\t') {
            if (_wards && wIdx < expectedWards) {
                char *p1 = cursor + 3;
                char *t1 = strchr(p1, '\t');
                if (t1) {
                    *t1 = '\0';
                    char *p2 = t1 + 1;
                    char *t2 = strchr(p2, '\t');
                    if (t2) {
                        *t2 = '\0';
                        char *p3 = t2 + 1;
                        _wards[wIdx].lat      = strtof(p1, NULL);
                        _wards[wIdx].lng      = strtof(p2, NULL);
                        _wards[wIdx].wardName = p3;
                        wIdx++;
                    }
                }
            }
        } else if (mIdx < expectedMerchants) {
            // 12 tab-separated columns:
            // 0:lat 1:lng 2:oc 3:mall 4:mcName 5:fullLabel 6:newLabel 7:addrDiff 8:streetKey 9:ngoNum 10:houseNum 11:adminKey
            char *cols[12];
            int colCnt = 0;
            char *seg = cursor;
            while (colCnt < 12) {
                cols[colCnt++] = seg;
                if (colCnt == 12) break;
                char *tab = strchr(seg, '\t');
                if (!tab) break;
                *tab = '\0';
                seg = tab + 1;
            }

            if (colCnt == 12) {
                HanoiMerchantRow *row = &_merchants[mIdx];
                row->lat        = strtof(cols[0], NULL);
                row->lng        = strtof(cols[1], NULL);
                row->orderCount = (int32_t)atoi(cols[2]);
                row->isMallFlag = (uint8_t)atoi(cols[3]);
                row->mcName     = cols[4];
                row->fullLabel  = cols[5];
                row->newLabel   = cols[6];
                row->addrDiff   = cols[7];
                row->streetKey  = cols[8];
                row->ngoNum     = (int16_t)atoi(cols[9]);
                row->houseNum   = (int16_t)atoi(cols[10]);
                row->adminKey   = cols[11];

                _labelNextFL[mIdx] = -1;
                _labelNextNL[mIdx] = -1;
                _labelNextAD[mIdx] = -1;
                _streetNext[mIdx]  = -1;

                if (row->fullLabel[0] != '\0') {
                    uint32_t b = (uint32_t)(fnv1aHashCString(row->fullLabel) & kHashTableMask);
                    _labelNextFL[mIdx] = _flBuckets[b];
                    _flBuckets[b]      = mIdx;
                }
                if (row->newLabel[0] != '\0') {
                    uint32_t b = (uint32_t)(fnv1aHashCString(row->newLabel) & kHashTableMask);
                    _labelNextNL[mIdx] = _nlBuckets[b];
                    _nlBuckets[b]      = mIdx;
                }
                if (row->addrDiff[0] != '\0') {
                    uint32_t b = (uint32_t)(fnv1aHashCString(row->addrDiff) & kHashTableMask);
                    _labelNextAD[mIdx] = _adBuckets[b];
                    _adBuckets[b]      = mIdx;
                }
                if (row->streetKey[0] != '\0') {
                    uint32_t b = (uint32_t)(fnv1aHashCString(row->streetKey) & kHashTableMask);
                    _streetNext[mIdx] = _streetBuckets[b];
                    _streetBuckets[b] = mIdx;
                }

                mIdx++;
            }
        }

        if (!nl) break;
        cursor = nl + 1;
    }

    _merchantCount = mIdx;
    _wardCount     = wIdx;
}

#pragma mark - Text Cleaning & Keyword Lists

- (NSString *)stripLeadingDotArtifact:(NSString *)raw {
    if (!raw || raw.length == 0) return @"";
    NSString *trimmed = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (_leadingDotNoiseRegex && trimmed.length > 2) {
        trimmed = [_leadingDotNoiseRegex stringByReplacingMatchesInString:trimmed
                                                                  options:0
                                                                    range:NSMakeRange(0, trimmed.length)
                                                             withTemplate:@""];
    }
    return trimmed;
}

- (NSString *)cleanLookupKeyFromString:(NSString *)str {
    if (!str || str.length == 0) return @"";
    NSString *s = NormalizeVNText([self stripLeadingDotArtifact:str]);
    NSMutableString *clean = [NSMutableString stringWithCapacity:s.length];
    BOOL prevSpace = YES;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) {
            [clean appendFormat:@"%C", c];
            prevSpace = NO;
        } else if (!prevSpace) {
            [clean appendString:@" "];
            prevSpace = YES;
        }
    }
    NSString *res = [clean stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSArray<NSString *> *stripSuffixes = @[
        @" thanh pho ha noi viet nam",
        @" thanh pho ha noi vnm",
        @" thanh pho ha noi vietnam",
        @" tp ha noi viet nam",
        @" tp ha noi 10000 vietnam",
        @" tp ha noi 100000 vietnam",
        @" thanh pho ha noi",
        @" tp ha noi",
        @" ha noi viet nam",
        @" viet nam",
        @" vietnam",
        @" vnm"
    ];
    BOOL changed = YES;
    while (changed) {
        changed = NO;
        for (NSString *suf in stripSuffixes) {
            if ([res hasSuffix:suf] && res.length > suf.length + 4) {
                res = [[res substringToIndex:res.length - suf.length]
                       stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                changed = YES;
            }
        }
    }
    return res;
}

- (NSArray<NSString *> *)normalizedKeywordArrayFromCSV:(NSString *)csv
                                             cachedRaw:(NSString * __strong *)ioCachedRaw
                                            cachedList:(NSArray<NSString *> * __strong *)ioCachedList {
    NSString *safeCSV = csv ?: @"";
    [_cacheLock lock];
    if (*ioCachedRaw && [*ioCachedRaw isEqualToString:safeCSV] && *ioCachedList) {
        NSArray<NSString *> *ret = *ioCachedList;
        [_cacheLock unlock];
        return ret;
    }
    [_cacheLock unlock];

    NSCharacterSet *sep = [NSCharacterSet characterSetWithCharactersInString:@",\n;|"];
    NSArray<NSString *> *parts = [safeCSV componentsSeparatedByCharactersInSet:sep];
    NSMutableArray<NSString *> *normArr = [NSMutableArray arrayWithCapacity:parts.count];
    for (NSString *raw in parts) {
        NSString *n = [self cleanLookupKeyFromString:raw];
        if (n.length >= 2) {
            [normArr addObject:n];
        }
    }

    [_cacheLock lock];
    *ioCachedRaw  = [safeCSV copy];
    *ioCachedList = [normArr copy];
    [_cacheLock unlock];
    return normArr;
}

- (NSString *)firstMatchingKeywordInText:(NSString *)cleanText fromKeywords:(NSArray<NSString *> *)keywords {
    if (!cleanText || cleanText.length < 2 || keywords.count == 0) return nil;
    for (NSString *kw in keywords) {
        if (containsNormalizedPhraseOnWordBoundary(cleanText, kw)) {
            return kw;
        }
    }
    return nil;
}

#pragma mark - Fast Merchant Lookup in 17,014-Store Index

- (void)collectExactLabelMatchesForKey:(NSString *)cleanKey into:(NSMutableIndexSet *)idxSet {
    if (!_merchants || _merchantCount <= 0 || !cleanKey || cleanKey.length < 6) return;
    if ([cleanKey isEqualToString:@"unknown"]) return;
    const char *ck = [cleanKey UTF8String];
    if (!ck) return;

    uint32_t b = (uint32_t)(fnv1aHashCString(ck) & kHashTableMask);

    for (int32_t cur = _flBuckets[b]; cur >= 0 && cur < _merchantCount; cur = _labelNextFL[cur]) {
        if (strcmp(_merchants[cur].fullLabel, ck) == 0) {
            [idxSet addIndex:(NSUInteger)cur];
        }
    }
    for (int32_t cur = _nlBuckets[b]; cur >= 0 && cur < _merchantCount; cur = _labelNextNL[cur]) {
        if (strcmp(_merchants[cur].newLabel, ck) == 0) {
            [idxSet addIndex:(NSUInteger)cur];
        }
    }
    for (int32_t cur = _adBuckets[b]; cur >= 0 && cur < _merchantCount; cur = _labelNextAD[cur]) {
        if (strcmp(_merchants[cur].addrDiff, ck) == 0) {
            [idxSet addIndex:(NSUInteger)cur];
        }
    }
    // Also check if `ck` is the pure address suffix of `fullLabel` (when popup omits merchant prefix)
    if (idxSet.count == 0 && strlen(ck) >= 16) {
        size_t ckLen = strlen(ck);
        for (int32_t i = 0; i < _merchantCount; i++) {
            const char *fl = _merchants[i].fullLabel;
            size_t flLen = strlen(fl);
            if (flLen > ckLen + 2 && strcmp(fl + (flLen - ckLen), ck) == 0 && fl[flLen - ckLen - 1] == ' ') {
                [idxSet addIndex:(NSUInteger)i];
            }
        }
    }
}

- (BOOL)rawSegmentLooksLikePureStreetPrefix:(NSString *)rawSeg cleanSeg:(NSString *)cleanSeg {
    if (!rawSeg || !cleanSeg || cleanSeg.length == 0) return YES;
    NSString *rl = [[self stripLeadingDotArtifact:rawSeg] lowercaseString];
    if ([rl hasPrefix:@"ngõ "] || [rl hasPrefix:@"ngách "] || [rl hasPrefix:@"hẻm "] ||
        [rl hasPrefix:@"đường "] || [rl hasPrefix:@"phố "] || [rl hasPrefix:@"số "] ||
        [cleanSeg hasPrefix:@"ngo "] || [cleanSeg hasPrefix:@"duong "]) {
        return YES;
    }
    if ([_firstNumberRegex firstMatchInString:cleanSeg options:0 range:NSMakeRange(0, MIN((NSUInteger)5, cleanSeg.length))] != nil) {
        return YES;
    }
    return NO;
}

- (NSString *)stripShopPrefixBeforeFirstCommaIfNeeded:(NSString *)rawText {
    if (!rawText || rawText.length < 10) return nil;
    NSRange commaRange = [rawText rangeOfString:@","];
    if (commaRange.location == NSNotFound || commaRange.location + 2 >= rawText.length) {
        return nil;
    }
    NSString *rawFirst = [rawText substringToIndex:commaRange.location];
    NSString *firstSeg = [self cleanLookupKeyFromString:rawFirst];
    // Distinguish "Phở ..." (shop name!) from "Phố ..." (street!) using accented rawFirst!
    if (firstSeg.length >= 2 && ![self rawSegmentLooksLikePureStreetPrefix:rawFirst cleanSeg:firstSeg]) {
        NSString *tail = [rawText substringFromIndex:commaRange.location + 1];
        NSString *cleanTail = [self cleanLookupKeyFromString:tail];
        if (cleanTail.length >= 8) {
            return cleanTail;
        }
    }
    return nil;
}

- (NSIndexSet *)lookupCandidateMerchantsForTitle:(NSString *)titleKey
                                        subtitle:(NSString *)subKey
                                        rawTitle:(NSString *)rawTitle
                                     rawSubtitle:(NSString *)rawSubtitle {
    NSMutableIndexSet *matches = [NSMutableIndexSet indexSet];
    if (!_merchants || _merchantCount <= 0) return matches;

    [self collectExactLabelMatchesForKey:subKey into:matches];
    [self collectExactLabelMatchesForKey:titleKey into:matches];

    // Also try comma-stripped pure address tail when popup prepends Shop Name before comma while DB full_label stores pure street address!
    if (matches.count == 0) {
        NSString *subTail = [self stripShopPrefixBeforeFirstCommaIfNeeded:rawSubtitle];
        if (subTail) [self collectExactLabelMatchesForKey:subTail into:matches];
        if (matches.count == 0) {
            NSString *titTail = [self stripShopPrefixBeforeFirstCommaIfNeeded:rawTitle];
            if (titTail) [self collectExactLabelMatchesForKey:titTail into:matches];
        }
    }

    // Fuzzy substring fallback if Vision OCR dropped/garbled 1 char on a >= 18-char label
    if (matches.count == 0) {
        NSString *probe = (subKey.length >= 16) ? subKey : titleKey;
        if (probe.length >= 16) {
            const char *cProbe = [probe UTF8String];
            size_t pLen = strlen(cProbe);
            // Use middle slice to tolerate minor OCR noise at very start/end
            char midSlice[64];
            size_t sliceOff = (pLen > 28) ? 4 : 0;
            size_t sliceLen = (pLen - sliceOff > 36) ? 36 : (pLen - sliceOff);
            memcpy(midSlice, cProbe + sliceOff, sliceLen);
            midSlice[sliceLen] = '\0';

            if (sliceLen >= 14) {
                for (int32_t i = 0; i < _merchantCount; i++) {
                    const HanoiMerchantRow *r = &_merchants[i];
                    if ((r->fullLabel[0] != '\0' && strstr(r->fullLabel, midSlice) != NULL) ||
                        (r->newLabel[0]  != '\0' && strstr(r->newLabel, midSlice)  != NULL)) {
                        [matches addIndex:(NSUInteger)i];
                        if (matches.count >= 6) break;
                    }
                }
            }
        }
    }

    // If multiple merchants share the same address (e.g. ghost kitchen), disambiguate using titleKey if shop name is present
    if (matches.count > 1 && titleKey.length >= 4) {
        NSMutableIndexSet *narrowed = [NSMutableIndexSet indexSet];
        [matches enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
            const char *mn = self->_merchants[idx].mcName;
            if (mn && mn[0] != '\0') {
                NSString *mcStr = [NSString stringWithUTF8String:mn];
                NSArray<NSString *> *words = [mcStr componentsSeparatedByString:@" "];
                if (words.count >= 2) {
                    NSString *brand2 = [NSString stringWithFormat:@"%@ %@", words[0], words[1]];
                    if ([titleKey containsString:brand2] || [mcStr containsString:titleKey]) {
                        [narrowed addIndex:idx];
                    }
                } else if (words.count == 1 && [words[0] length] >= 3 && containsNormalizedPhraseOnWordBoundary(titleKey, words[0])) {
                    [narrowed addIndex:idx];
                }
            }
        }];
        if (narrowed.count > 0) {
            return narrowed;
        }
    }

    return matches;
}

#pragma mark - Offline Hanoi Street / Alley / Ward Coordinate Interpolator (0.15ms, 0 Bytes Network)

- (BOOL)offlineInterpolateHanoiAddress:(NSString *)rawAddress
                             titleHint:(NSString *)rawTitle
                                outLat:(double *)outLat
                                outLng:(double *)outLng {
    if (!_merchants || _merchantCount <= 0) return NO;

    NSString *primary = (rawAddress.length >= 6) ? rawAddress : rawTitle;
    if (!primary || primary.length < 4) return NO;

    // 1. Direct exact label lookup first (0.02ms, 0.1m precision)
    NSString *cleanSub = [self cleanLookupKeyFromString:rawAddress];
    NSString *cleanTit = [self cleanLookupKeyFromString:rawTitle];
    NSMutableIndexSet *exact = [NSMutableIndexSet indexSet];
    [self collectExactLabelMatchesForKey:cleanSub into:exact];
    if (exact.count == 0) {
        [self collectExactLabelMatchesForKey:cleanTit into:exact];
    }
    if (exact.count > 0) {
        NSUInteger firstIdx = exact.firstIndex;
        *outLat = (double)_merchants[firstIdx].lat;
        *outLng = (double)_merchants[firstIdx].lng;
        return YES;
    }

    // 2. Parse comma segments to extract streetKey, ngoNum, houseNum, and admin ward/district tokens
    NSArray<NSString *> *rawSegs = [primary componentsSeparatedByString:@","];
    NSMutableArray<NSString *> *normSegs = [NSMutableArray arrayWithCapacity:rawSegs.count];
    for (NSString *sg in rawSegs) {
        NSString *ns = [self cleanLookupKeyFromString:sg];
        if (ns.length > 0) [normSegs addObject:ns];
    }
    if (normSegs.count == 0) return NO;

    NSMutableArray<NSString *> *adminHints = [NSMutableArray array];
    NSMutableArray<NSString *> *wardFullHints = [NSMutableArray array];
    for (NSUInteger i = 1; i < normSegs.count; i++) {
        NSString *sg = normSegs[i];
        if ([sg hasPrefix:@"phuong "] || [sg hasPrefix:@"xa "] || [sg hasPrefix:@"thi tran "] ||
            [sg hasPrefix:@"khu do thi "] || [sg hasPrefix:@"vinhomes "]) {
            [wardFullHints addObject:sg];
        }
        NSString *stripped = sg;
        for (NSString *pfx in @[@"phuong ", @"quan ", @"huyen ", @"thi tran ", @"xa ", @"p ", @"q "]) {
            if ([stripped hasPrefix:pfx]) {
                stripped = [stripped substringFromIndex:pfx.length];
                break;
            }
        }
        if (stripped.length >= 2) {
            [adminHints addObject:stripped];
        }
    }

    NSString *cand = normSegs[0];
    if (normSegs.count >= 2 &&
        ![cand containsString:@"duong "] &&
        ![cand containsString:@"pho "] &&
        ![cand containsString:@"ngo "] &&
        [_firstNumberRegex firstMatchInString:cand options:0 range:NSMakeRange(0, cand.length)] == nil) {
        cand = normSegs[1];
    }

    NSString *streetName = nil;
    int targetNgo   = 0;
    int targetHouse = 0;

    NSTextCheckingResult *mNgo = [_ngoStreetRegex firstMatchInString:cand options:0 range:NSMakeRange(0, cand.length)];
    if (mNgo && mNgo.numberOfRanges >= 3) {
        targetNgo  = [[cand substringWithRange:[mNgo rangeAtIndex:1]] intValue];
        streetName = [cand substringWithRange:[mNgo rangeAtIndex:2]];
        NSString *prefix = [cand substringToIndex:mNgo.range.location];
        NSTextCheckingResult *mh = [_firstNumberRegex firstMatchInString:prefix options:0 range:NSMakeRange(0, prefix.length)];
        if (mh) targetHouse = [[prefix substringWithRange:[mh rangeAtIndex:1]] intValue];
    } else {
        NSTextCheckingResult *mNum = [_numStreetRegex firstMatchInString:cand options:0 range:NSMakeRange(0, cand.length)];
        if (mNum && mNum.numberOfRanges >= 3) {
            targetHouse = [[cand substringWithRange:[mNum rangeAtIndex:1]] intValue];
            streetName  = [cand substringWithRange:[mNum rangeAtIndex:2]];
        } else {
            NSTextCheckingResult *mPl = [_plainStreetRegex firstMatchInString:cand options:0 range:NSMakeRange(0, cand.length)];
            if (mPl && mPl.numberOfRanges >= 2) {
                streetName = [cand substringWithRange:[mPl rangeAtIndex:1]];
                NSString *prefix = [cand substringToIndex:mPl.range.location];
                NSTextCheckingResult *mh = [_firstNumberRegex firstMatchInString:prefix options:0 range:NSMakeRange(0, prefix.length)];
                if (mh) targetHouse = [[prefix substringWithRange:[mh rangeAtIndex:1]] intValue];
            }
        }
    }

    // If Dropoff title had a leading house number (e.g. "59 Ngõ 123 Phố Trung Kính") while subtitle omitted "59", recover it!
    if (targetHouse == 0 && cleanTit.length > 0) {
        NSTextCheckingResult *mt = [_firstNumberRegex firstMatchInString:cleanTit options:0 range:NSMakeRange(0, cleanTit.length)];
        if (mt && mt.range.location <= 4) {
            int numFromTitle = [[cleanTit substringWithRange:[mt rangeAtIndex:1]] intValue];
            if (numFromTitle > 0 && numFromTitle != targetNgo) {
                targetHouse = numFromTitle;
            }
        }
    }

    if (streetName.length >= 2) {
        for (NSString *pfx in @[@"duong ", @"pho ", @"p "]) {
            if ([streetName hasPrefix:pfx]) {
                streetName = [streetName substringFromIndex:pfx.length];
                break;
            }
        }
        streetName = [streetName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }

    // 3. O(1) Street Hash Lookup + House/Alley Interpolation
    if (streetName.length >= 2 && _streetBuckets) {
        const char *cSt = [streetName UTF8String];
        uint32_t b = (uint32_t)(fnv1aHashCString(cSt) & kHashTableMask);
        int32_t cur = _streetBuckets[b];

        int32_t allCands[256];
        int32_t admCands[256];
        int allCnt = 0, admCnt = 0;

        int guard = 0;
        while (cur >= 0 && cur < _merchantCount && guard < 8192) {
            guard++;
            const HanoiMerchantRow *r = &_merchants[cur];
            if (strcmp(r->streetKey, cSt) == 0) {
                if (allCnt < 256) allCands[allCnt++] = cur;
                if (adminHints.count > 0 && r->adminKey[0] != '\0') {
                    NSString *rAdm = [NSString stringWithUTF8String:r->adminKey];
                    for (NSString *ah in adminHints) {
                        if ([rAdm containsString:ah]) {
                            if (admCnt < 256) admCands[admCnt++] = cur;
                            break;
                        }
                    }
                }
            }
            cur = _streetNext[cur];
        }

        int32_t *pool = (admCnt > 0) ? admCands : allCands;
        int poolCnt   = (admCnt > 0) ? admCnt   : allCnt;

        if (poolCnt > 0) {
            // Find up to 3 closest points by alley or house number
            int32_t bestIdx[3]  = { pool[0], -1, -1 };
            int bestDiff[3]     = { 999999, 999999, 999999 };

            for (int i = 0; i < poolCnt; i++) {
                int32_t idx = pool[i];
                const HanoiMerchantRow *r = &_merchants[idx];
                int diff = 50000;

                if (targetNgo > 0) {
                    if (r->ngoNum == targetNgo) {
                        diff = (targetHouse > 0 && r->houseNum > 0) ? abs((int)r->houseNum - targetHouse) : 0;
                    } else if (r->ngoNum > 0 || r->houseNum > 0) {
                        int refNum = (r->ngoNum > 0) ? (int)r->ngoNum : (int)r->houseNum;
                        diff = 500 + abs(refNum - targetNgo);
                    }
                } else if (targetHouse > 0) {
                    if (r->ngoNum == 0 && r->houseNum > 0) {
                        diff = abs((int)r->houseNum - targetHouse);
                    } else if (r->ngoNum > 0) {
                        diff = 400 + abs((int)r->ngoNum - targetHouse);
                    }
                } else {
                    diff = i;
                }

                for (int slot = 0; slot < 3; slot++) {
                    if (diff < bestDiff[slot]) {
                        for (int s = 2; s > slot; s--) {
                            bestDiff[s] = bestDiff[s - 1];
                            bestIdx[s]  = bestIdx[s - 1];
                        }
                        bestDiff[slot] = diff;
                        bestIdx[slot]  = idx;
                        break;
                    }
                }
            }

            double baseLat = (double)_merchants[bestIdx[0]].lat;
            double baseLng = (double)_merchants[bestIdx[0]].lng;
            double sumLat  = baseLat;
            double sumLng  = baseLng;
            int used = 1;

            for (int slot = 1; slot < 3; slot++) {
                if (bestIdx[slot] >= 0 && bestDiff[slot] <= bestDiff[0] + 45) {
                    double cLat = (double)_merchants[bestIdx[slot]].lat;
                    double cLng = (double)_merchants[bestIdx[slot]].lng;
                    if (haversineDistanceKm(baseLat, baseLng, cLat, cLng) <= 1.1) {
                        sumLat += cLat;
                        sumLng += cLng;
                        used++;
                    }
                }
            }

            *outLat = sumLat / (double)used;
            *outLng = sumLng / (double)used;
            return YES;
        }
    }

    // 4. Ward / KĐT Centroid Fallback (covers 100% of Vinhomes Ocean Park / Smart City / unnumbered Hanoi zones)
    if (_wards && _wardCount > 0 && wardFullHints.count > 0) {
        for (NSString *wh in wardFullHints) {
            const char *cWh = [wh UTF8String];
            if (!cWh) continue;
            for (int32_t w = 0; w < _wardCount; w++) {
                if (strcmp(_wards[w].wardName, cWh) == 0) {
                    *outLat = (double)_wards[w].lat;
                    *outLng = (double)_wards[w].lng;
                    return YES;
                }
            }
        }
    }

    return NO;
}

#pragma mark - Fast Timeout-Capped Online Geocoding & Valhalla Motorbike Routing (Weak-4G Safe)

- (BOOL)isNetworkTemporarilyTripped {
    double now = [[NSDate date] timeIntervalSince1970];
    return (now < _netCooldownUntilEpoch);
}

- (void)recordNetworkOutcome:(BOOL)succeeded {
    if (succeeded) {
        _consecutiveNetTimeouts = 0;
        _netCooldownUntilEpoch  = 0.0;
    } else {
        _consecutiveNetTimeouts++;
        if (_consecutiveNetTimeouts >= 2) {
            // 4G is congested -> trip circuit breaker for 6s so Driver App gets 100% bandwidth
            _netCooldownUntilEpoch = [[NSDate date] timeIntervalSince1970] + 6.0;
        }
    }
}

- (NSData *)performFastRequest:(NSURLRequest *)req timeoutMs:(NSInteger)timeoutMs {
    if (!req || !_fastNetSession || [self isNetworkTemporarilyTripped]) return nil;

    __block NSData *respData = nil;
    __block NSInteger statusCode = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    NSURLSessionDataTask *task = [_fastNetSession dataTaskWithRequest:req
                                                    completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && [response isKindOfClass:[NSHTTPURLResponse class]]) {
            statusCode = [(NSHTTPURLResponse *)response statusCode];
            if (statusCode >= 200 && statusCode < 300) {
                respData = data;
            }
        }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];

    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeoutMs * (int64_t)NSEC_PER_MSEC);
    long waited = dispatch_semaphore_wait(sem, deadline);
    if (waited != 0) {
        // Hard cutoff: cancel immediately to free radio bandwidth for Xanh SM Driver!
        [task cancel];
        [self recordNetworkOutcome:NO];
        return nil;
    }

    [self recordNetworkOutcome:(respData != nil)];
    return respData;
}

- (NSString *)buildCleanDropoffQueryFromTitle:(NSString *)rawTitle subtitle:(NSString *)rawSubtitle {
    NSString *tit = [self stripLeadingDotArtifact:rawTitle];
    NSString *sub = [self stripLeadingDotArtifact:rawSubtitle];
    if (sub.length == 0) return tit ?: @"";
    if (tit.length == 0) return sub;

    // Check if subtitle already begins with a house/building number (e.g. "82 Đường Quán Thánh...")
    NSString *normSub = NormalizeVNText(sub);
    NSString *normTit = NormalizeVNText(tit);
    NSTextCheckingResult *subNum = [_firstNumberRegex firstMatchInString:normSub options:0 range:NSMakeRange(0, MIN((NSUInteger)8, normSub.length))];
    if (subNum && subNum.range.location <= 3) {
        return sub;
    }

    // Check if title begins with a house number missing from subtitle (e.g. Title="59 Ngõ 123...", Subtitle="Ngõ 123 Đường Trung Kính...")
    NSTextCheckingResult *titNum = [_firstNumberRegex firstMatchInString:normTit options:0 range:NSMakeRange(0, MIN((NSUInteger)10, normTit.length))];
    if (titNum && titNum.range.location <= 4) {
        NSString *houseTok = [tit substringWithRange:[titNum rangeAtIndex:1]];
        if (![normSub hasPrefix:houseTok]) {
            return [NSString stringWithFormat:@"%@ %@", houseTok, sub];
        }
    }

    return sub;
}

- (BOOL)geocodeHanoiAddressOnline:(NSString *)queryStr
                           outLat:(double *)outLat
                           outLng:(double *)outLng {
    if (!queryStr || queryStr.length < 5) return NO;
    NSString *cacheKey = [self cleanLookupKeyFromString:queryStr];
    if (cacheKey.length < 4) return NO;

    [_cacheLock lock];
    NSValue *cachedVal = _geocodeCache[cacheKey];
    [_cacheLock unlock];
    if (cachedVal) {
        CGPoint pt = [cachedVal CGPointValue];
        *outLat = (double)pt.x;
        *outLng = (double)pt.y;
        return YES;
    }

    if ([self isNetworkTemporarilyTripped]) return NO;

    NSString *fullQ = [queryStr.lowercaseString containsString:@"hà nội"] || [queryStr.lowercaseString containsString:@"ha noi"]
        ? queryStr
        : [NSString stringWithFormat:@"%@, Hà Nội, Việt Nam", queryStr];

    NSString *escaped = [fullQ stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    if (!escaped) return NO;

    NSString *urlStr = [NSString stringWithFormat:
        @"https://geocode.arcgis.com/arcgis/rest/services/World/GeocodeServer/findAddressCandidates"
        @"?SingleLine=%@&countryCode=VNM&searchExtent=105.25,20.55,106.15,21.42&maxLocations=1&f=json",
        escaped];

    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return NO;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:0.65];
    [req setValue:@"Mozilla/5.0" forHTTPHeaderField:@"User-Agent"];

    NSData *data = [self performFastRequest:req timeoutMs:650];
    if (!data) return NO;

    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return NO;

    NSArray *cands = json[@"candidates"];
    if (![cands isKindOfClass:[NSArray class]] || cands.count == 0) return NO;

    NSDictionary *top = cands.firstObject;
    double score = [top[@"score"] doubleValue];
    NSDictionary *loc = top[@"location"];
    if (score < 76.0 || ![loc isKindOfClass:[NSDictionary class]]) return NO;

    double lat = [loc[@"y"] doubleValue];
    double lng = [loc[@"x"] doubleValue];
    if (lat < 20.50 || lat > 21.48 || lng < 105.20 || lng > 106.20) return NO;

    *outLat = lat;
    *outLng = lng;

    [_cacheLock lock];
    if (_geocodeLRU.count >= 256) {
        NSString *oldest = _geocodeLRU.firstObject;
        if (oldest) {
            [_geocodeCache removeObjectForKey:oldest];
            [_geocodeLRU removeObjectAtIndex:0];
        }
    }
    _geocodeCache[cacheKey] = [NSValue valueWithCGPoint:CGPointMake((CGFloat)lat, (CGFloat)lng)];
    [_geocodeLRU addObject:cacheKey];
    [_cacheLock unlock];

    return YES;
}

- (BOOL)queryValhallaMotorScooterKmFromLat:(double)latA lng:(double)lngA
                                     toLat:(double)latB lng:(double)lngB
                                     outKm:(double *)outKm {
    if ([self isNetworkTemporarilyTripped]) return NO;

    NSURL *url = [NSURL URLWithString:@"https://valhalla1.openstreetmap.de/route"];
    if (!url) return NO;

    NSDictionary *payload = @{
        @"locations": @[
            @{ @"lat": @(latA), @"lon": @(lngA) },
            @{ @"lat": @(latB), @"lon": @(lngB) }
        ],
        @"costing": @"motor_scooter",
        @"costing_options": @{
            @"motor_scooter": @{
                @"use_highways": @(0.0), // Motorbikes banned from elevated Vành đai 3 / expressways
                @"use_tolls":    @(0.0),
                @"use_primary":  @(0.8)
            }
        },
        @"units": @"kilometers"
    };

    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!body) return NO;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:0.75];
    req.HTTPMethod = @"POST";
    req.HTTPBody   = body;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"Mozilla/5.0"      forHTTPHeaderField:@"User-Agent"];

    NSData *resp = [self performFastRequest:req timeoutMs:750];
    if (!resp) return NO;

    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:resp options:0 error:nil];
    NSDictionary *trip = [json isKindOfClass:[NSDictionary class]] ? json[@"trip"] : nil;
    NSDictionary *sum  = [trip isKindOfClass:[NSDictionary class]] ? trip[@"summary"] : nil;
    if (![sum isKindOfClass:[NSDictionary class]] || !sum[@"length"]) return NO;

    double km = [sum[@"length"] doubleValue];
    if (km <= 0.01 || km > 150.0) return NO;

    *outKm = km;
    return YES;
}

- (BOOL)queryOSRMFallbackKmFromLat:(double)latA lng:(double)lngA
                             toLat:(double)latB lng:(double)lngB
                             outKm:(double *)outKm {
    if ([self isNetworkTemporarilyTripped]) return NO;

    NSString *urlStr = [NSString stringWithFormat:
        @"https://routing.openstreetmap.de/routed-car/route/v1/driving/%.5f,%.5f;%.5f,%.5f?overview=false",
        lngA, latA, lngB, latB];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return NO;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:0.55];
    [req setValue:@"Mozilla/5.0" forHTTPHeaderField:@"User-Agent"];

    NSData *resp = [self performFastRequest:req timeoutMs:550];
    if (!resp) return NO;

    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:resp options:0 error:nil];
    NSArray *routes = [json isKindOfClass:[NSDictionary class]] ? json[@"routes"] : nil;
    NSDictionary *first = ([routes isKindOfClass:[NSArray class]] && routes.count > 0) ? routes.firstObject : nil;
    if (![first isKindOfClass:[NSDictionary class]] || !first[@"distance"]) return NO;

    double meters = [first[@"distance"] doubleValue];
    if (meters <= 10.0 || meters > 150000.0) return NO;

    *outKm = meters / 1000.0;
    return YES;
}

- (BOOL)computeMotorbikeDistanceKmForPickupTitle:(NSString *)pickupTitle
                                  pickupSubtitle:(NSString *)pickupSubtitle
                                  matchedIndices:(NSIndexSet *)matchedMerchants
                                    dropoffTitle:(NSString *)dropoffTitle
                                 dropoffSubtitle:(NSString *)dropoffSubtitle
                                     thresholdKm:(double)thresholdKm
                                           outKm:(double *)outKm
                                       outSource:(NSString * __strong *)outSource {
    NSString *pKey = [self cleanLookupKeyFromString:(pickupSubtitle.length > 0 ? pickupSubtitle : pickupTitle)];
    NSString *dQuery = [self buildCleanDropoffQueryFromTitle:dropoffTitle subtitle:dropoffSubtitle];
    NSString *dKey = [self cleanLookupKeyFromString:dQuery];
    if (pKey.length < 4 || dKey.length < 4) return NO;

    NSString *pairCacheKey = [NSString stringWithFormat:@"%@||%@", pKey, dKey];
    [_cacheLock lock];
    NSNumber *cachedDist = _routeDistCache[pairCacheKey];
    NSString *cachedTag  = _routeSourceTagCache[pairCacheKey];
    [_cacheLock unlock];
    if (cachedDist) {
        *outKm = [cachedDist doubleValue];
        if (outSource) *outSource = cachedTag ?: @"Cache";
        return YES;
    }

    // 1. Resolve Pickup (latA, lngA) — 99%+ instant 0.1ms hit from HanoiFoodIndex!
    double latA = 0.0, lngA = 0.0;
    BOOL hasPickupCoord = NO;
    if (matchedMerchants.count > 0 && _merchants) {
        NSUInteger idx = matchedMerchants.firstIndex;
        latA = (double)_merchants[idx].lat;
        lngA = (double)_merchants[idx].lng;
        hasPickupCoord = YES;
    }
    if (!hasPickupCoord) {
        hasPickupCoord = [self offlineInterpolateHanoiAddress:pickupSubtitle
                                                    titleHint:pickupTitle
                                                       outLat:&latA
                                                       outLng:&lngA];
    }
    if (!hasPickupCoord) {
        NSString *pQuery = (pickupSubtitle.length >= 6) ? pickupSubtitle : pickupTitle;
        hasPickupCoord = [self geocodeHanoiAddressOnline:pQuery outLat:&latA outLng:&lngA];
    }
    if (!hasPickupCoord) return NO;

    // 2. Resolve Offline Dropoff (offLatB, offLngB) first in 0.1ms!
    double offLatB = 0.0, offLngB = 0.0;
    BOOL hasOfflineDrop = [self offlineInterpolateHanoiAddress:dropoffSubtitle
                                                     titleHint:dropoffTitle
                                                        outLat:&offLatB
                                                        outLng:&offLngB];

    // Zero-Network Fast Cutoffs when Offline DB already proves > threshold or << threshold!
    if (hasOfflineDrop) {
        double offAirKm = haversineDistanceKm(latA, lngA, offLatB, offLngB);
        BOOL riverCross = crossesHanoiRedRiver(latA, lngA, offLatB, offLngB);

        if (offAirKm >= thresholdKm * 1.16) {
            // Even with 350m offline margin, road distance (>= 1.25 * airKm) is guaranteed > thresholdKm!
            double fastKm = estimateHanoiMotorbikeRoadKmOffline(latA, lngA, offLatB, offLngB);
            *outKm = fastKm;
            if (outSource) *outSource = @"FastAir+";
            [self cacheRouteDistance:fastKm source:@"FastAir+" forKey:pairCacheKey];
            return YES;
        }
        if (!riverCross && offAirKm <= thresholdKm * 0.42) {
            // e.g. airKm <= 1.26km on same side of river -> road ~1.65km, guaranteed <= 3.0km!
            double fastKm = estimateHanoiMotorbikeRoadKmOffline(latA, lngA, offLatB, offLngB);
            *outKm = fastKm;
            if (outSource) *outSource = @"FastAir-";
            [self cacheRouteDistance:fastKm source:@"FastAir-" forKey:pairCacheKey];
            return YES;
        }
    }

    // 3. Borderline zone (~1.3km .. 3.5km air): Refine Dropoff via ArcGIS (<= 650ms) with instant Offline fallback
    double latB = offLatB, lngB = offLngB;
    BOOL hasOnlineDrop = [self geocodeHanoiAddressOnline:dQuery outLat:&latB outLng:&lngB];
    if (!hasOnlineDrop && !hasOfflineDrop) {
        return NO;
    }

    // Re-check exact air-distance geometry after exact geocoding
    double exactAirKm = haversineDistanceKm(latA, lngA, latB, lngB);
    if (hasOnlineDrop && exactAirKm >= thresholdKm * 1.02) {
        double roadEst = estimateHanoiMotorbikeRoadKmOffline(latA, lngA, latB, lngB);
        *outKm = fmax(exactAirKm * 1.05, roadEst);
        if (outSource) *outSource = @"GeoAir+";
        [self cacheRouteDistance:*outKm source:@"GeoAir+" forKey:pairCacheKey];
        return YES;
    }
    if (hasOnlineDrop && !crossesHanoiRedRiver(latA, lngA, latB, lngB) && exactAirKm <= thresholdKm * 0.54) {
        double roadEst = estimateHanoiMotorbikeRoadKmOffline(latA, lngA, latB, lngB);
        *outKm = roadEst;
        if (outSource) *outSource = @"GeoAir-";
        [self cacheRouteDistance:*outKm source:@"GeoAir-" forKey:pairCacheKey];
        return YES;
    }

    // 4. Query Valhalla motor_scooter (avoids Vành đai 3 elevated & highways; respects Hanoi 1-way & alleys)
    double routedKm = 0.0;
    if ([self queryValhallaMotorScooterKmFromLat:latA lng:lngA toLat:latB lng:lngB outKm:&routedKm]) {
        *outKm = routedKm;
        if (outSource) *outSource = @"Valhalla";
        [self cacheRouteDistance:routedKm source:@"Valhalla" forKey:pairCacheKey];
        return YES;
    }

    if ([self queryOSRMFallbackKmFromLat:latA lng:lngA toLat:latB lng:lngB outKm:&routedKm]) {
        *outKm = routedKm;
        if (outSource) *outSource = @"OSRM";
        [self cacheRouteDistance:routedKm source:@"OSRM" forKey:pairCacheKey];
        return YES;
    }

    // 5. Weak/Dead 4G Fallback: Instant Offline Hanoi Motorbike Road Model (zero stall!)
    double offlineKm = estimateHanoiMotorbikeRoadKmOffline(latA, lngA, latB, lngB);
    *outKm = offlineKm;
    if (outSource) *outSource = @"OfflineHN";
    [self cacheRouteDistance:offlineKm source:@"OfflineHN" forKey:pairCacheKey];
    return YES;
}

- (void)cacheRouteDistance:(double)km source:(NSString *)src forKey:(NSString *)key {
    if (!key) return;
    [_cacheLock lock];
    if (_routeSourceKeys.count >= 256) {
        NSString *oldest = _routeSourceKeys.firstObject;
        if (oldest) {
            [_routeDistCache removeObjectForKey:oldest];
            [_routeSourceTagCache removeObjectForKey:oldest];
            [_routeSourceKeys removeObjectAtIndex:0];
        }
    }
    _routeDistCache[key]      = @(km);
    _routeSourceTagCache[key] = src ?: @"Offline";
    [_routeSourceKeys addObject:key];
    [_cacheLock unlock];
}

#pragma mark - Master Two-Gate Green Food Evaluator

- (FoodFilterEvaluation *)evaluateGreenFoodWithFare:(NSInteger)detectedFareVND
                                        pickupTitle:(NSString *)pickupTitle
                                     pickupSubtitle:(NSString *)pickupSubtitle
                                       dropoffTitle:(NSString *)dropoffTitle
                                    dropoffSubtitle:(NSString *)dropoffSubtitle
                                             config:(FilterConfig *)config
                                         retryCount:(NSInteger)retryCount {
    FoodFilterEvaluation *ev = [[FoodFilterEvaluation alloc] init];
    ev.estimatedDistanceKm = 0.0;
    ev.distanceSourceTag   = @"";
    ev.matchedOrderCount   = 0;

    NSString *cleanPickupTitle = [self cleanLookupKeyFromString:pickupTitle];
    NSString *cleanPickupSub   = [self cleanLookupKeyFromString:pickupSubtitle];
    NSString *combinedPickup   = [NSString stringWithFormat:@"%@ %@", cleanPickupTitle ?: @"", cleanPickupSub ?: @""];
    combinedPickup = [combinedPickup stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

    // WEAK-4G SKELETON GUARD:
    // If Green Food header is visible, wait up to 6 frames (~700ms) if Pickup text hasn't rendered yet!
    BOOL needsPickupCheck = (config.foodBlockMallAndBasement ||
                             config.foodBlockCrowdedChains ||
                             config.foodMaxMerchantOrders > 0 ||
                             config.foodAcceptLongDistance);
    if (needsPickupCheck && combinedPickup.length < 6) {
        if (retryCount < 6) {
            ev.decision = FoodFilterDecisionWaitTextLoading;
            ev.reasonSummary = @"Đang chờ load chữ Điểm nhận Green Food (Chống lag 4G)...";
            return ev;
        }
    }

    // Detect whether popup explicitly showed a shop name in pickupTitle vs hiding merchant name behind a bare street address
    BOOL popupShowsExplicitShopName = ([self stripShopPrefixBeforeFirstCommaIfNeeded:pickupTitle] != nil);
    if (!popupShowsExplicitShopName && cleanPickupTitle.length >= 4 && cleanPickupSub.length >= 6) {
        if (![cleanPickupTitle isEqualToString:cleanPickupSub] && ![cleanPickupSub hasPrefix:cleanPickupTitle]) {
            if (![self rawSegmentLooksLikePureStreetPrefix:pickupTitle cleanSeg:cleanPickupTitle]) {
                popupShowsExplicitShopName = YES;
            }
        }
    }

    // Lookup merchant in 17,014-store Hanoi offline DB (0.2ms)
    NSIndexSet *matchedIdxs = [self lookupCandidateMerchantsForTitle:cleanPickupTitle
                                                            subtitle:cleanPickupSub
                                                            rawTitle:pickupTitle
                                                         rawSubtitle:pickupSubtitle];
    BOOL singleExactMerchant = (matchedIdxs.count == 1);
    BOOL hiddenNameAddressMatch = (!popupShowsExplicitShopName && matchedIdxs.count >= 1 && matchedIdxs.count <= 4);
    BOOL allCandidatesMall   = (matchedIdxs.count > 0);
    int32_t minCandOrders    = INT32_MAX;
    int32_t maxCandOrders    = 0;
    NSString *unmaskedName   = nil;

    if (matchedIdxs.count > 0 && _merchants) {
        NSUInteger cur = matchedIdxs.firstIndex;
        while (cur != NSNotFound) {
            const HanoiMerchantRow *r = &_merchants[cur];
            if (r->isMallFlag == 0) allCandidatesMall = NO;
            if (r->orderCount < minCandOrders) minCandOrders = r->orderCount;
            if (r->orderCount > maxCandOrders) maxCandOrders = r->orderCount;
            if (!unmaskedName && r->mcName[0] != '\0') {
                unmaskedName = [NSString stringWithUTF8String:r->mcName];
            }
            cur = [matchedIdxs indexGreaterThanIndex:cur];
        }
        ev.matchedMerchantName = unmaskedName;
        ev.matchedOrderCount   = (singleExactMerchant || hiddenNameAddressMatch) ? maxCandOrders : minCandOrders;
    }

    // Text corpus for Gate 1: OCR Pickup text + Unmasked DB merchant name (ONLY when popup hid merchant name behind bare street address, or DB mcName matches the visible shop prefix!)
    NSMutableString *gate1Corpus = [NSMutableString stringWithString:(combinedPickup ?: @"")];
    BOOL dbMatchesVisibleShop = NO;
    if (popupShowsExplicitShopName && singleExactMerchant && unmaskedName.length > 0) {
        NSArray<NSString *> *mcWords = [unmaskedName componentsSeparatedByString:@" "];
        if (mcWords.count >= 2) {
            NSString *b2 = [NSString stringWithFormat:@"%@ %@", mcWords[0], mcWords[1]];
            dbMatchesVisibleShop = [cleanPickupTitle containsString:b2];
        } else if (mcWords.count == 1 && [mcWords[0] length] >= 3) {
            dbMatchesVisibleShop = containsNormalizedPhraseOnWordBoundary(cleanPickupTitle, mcWords[0]);
        }
    }
    if (!popupShowsExplicitShopName && hiddenNameAddressMatch && _merchants) {
        NSUInteger cur = matchedIdxs.firstIndex;
        while (cur != NSNotFound) {
            const char *mn = _merchants[cur].mcName;
            if (mn && mn[0] != '\0') {
                [gate1Corpus appendFormat:@" %s", mn];
            }
            cur = [matchedIdxs indexGreaterThanIndex:cur];
        }
    } else if (dbMatchesVisibleShop && unmaskedName.length > 0) {
        [gate1Corpus appendFormat:@" %@", unmaskedName];
    }

    // =========================================================================
    // GATE 1: HARD-REJECT [X] TTTM / BASEMENT / CROWDED CHAINS / HIGH VOLUME
    // (Option A — Applies strictly to Điểm Nhận regardless of price or distance)
    // =========================================================================
    if (config.foodBlockMallAndBasement && gate1Corpus.length >= 3) {
        NSArray<NSString *> *mallKws = [self normalizedKeywordArrayFromCSV:(config.foodMallKeywords ?: kDefaultFoodMallKeywords)
                                                                 cachedRaw:&_cachedMallKwRaw
                                                                cachedList:&_cachedMallKwNormList];
        NSString *hitMallKw = [self firstMatchingKeywordInText:gate1Corpus fromKeywords:mallKws];
        if (hitMallKw) {
            ev.decision = FoodFilterDecisionRejectHard;
            ev.reasonSummary = [NSString stringWithFormat:@"Green Food TTTM/Hầm ('%@') -> HỦY CỨNG [X]", hitMallKw];
            return ev;
        }

        if (_structuralMallRegex &&
            [_structuralMallRegex firstMatchInString:combinedPickup options:0 range:NSMakeRange(0, combinedPickup.length)] != nil) {
            ev.decision = FoodFilterDecisionRejectHard;
            ev.reasonSummary = @"Green Food Hầm/Gian hàng TTTM -> HỦY CỨNG [X]";
            return ev;
        }

        if (mallKws.count > 0 && matchedIdxs.count > 0 && allCandidatesMall) {
            ev.decision = FoodFilterDecisionRejectHard;
            ev.reasonSummary = @"Green Food Điểm nhận thuộc TTTM/Tầng hầm (DB Hà Nội) -> HỦY CỨNG [X]";
            return ev;
        }
    }

    if (config.foodBlockCrowdedChains && gate1Corpus.length >= 3) {
        NSArray<NSString *> *chainKws = [self normalizedKeywordArrayFromCSV:(config.foodChainKeywords ?: kDefaultFoodChainKeywords)
                                                                  cachedRaw:&_cachedChainKwRaw
                                                                 cachedList:&_cachedChainKwNormList];
        NSString *hitChainKw = [self firstMatchingKeywordInText:gate1Corpus fromKeywords:chainKws];
        if (!hitChainKw && !popupShowsExplicitShopName && matchedIdxs.count > 1 && _merchants && chainKws.count > 0) {
            // If multiple duplicate DB listings exist at the exact same address and ALL of them belong to crowded chains -> block 100%!
            BOOL allMatchChains = YES;
            NSString *commonChainHit = nil;
            NSUInteger cur = matchedIdxs.firstIndex;
            while (cur != NSNotFound) {
                const char *mn = _merchants[cur].mcName;
                NSString *candMc = (mn && mn[0] != '\0') ? [NSString stringWithUTF8String:mn] : @"";
                NSString *candHit = [self firstMatchingKeywordInText:candMc fromKeywords:chainKws];
                if (!candHit) {
                    allMatchChains = NO;
                    break;
                }
                if (!commonChainHit) commonChainHit = candHit;
                cur = [matchedIdxs indexGreaterThanIndex:cur];
            }
            if (allMatchChains && commonChainHit) {
                hitChainKw = commonChainHit;
            }
        }
        if (hitChainKw) {
            ev.decision = FoodFilterDecisionRejectHard;
            ev.reasonSummary = [NSString stringWithFormat:@"Green Food Quán đông chờ lâu ('%@') -> HỦY CỨNG [X]", hitChainKw];
            return ev;
        }
    }

    if (config.foodMaxMerchantOrders > 0 && matchedIdxs.count > 0) {
        BOOL canTrustOrderCount = (!popupShowsExplicitShopName && (singleExactMerchant || hiddenNameAddressMatch)) ||
                                  (popupShowsExplicitShopName && dbMatchesVisibleShop);
        if (canTrustOrderCount) {
            NSInteger effectiveOrders = (singleExactMerchant || hiddenNameAddressMatch) ? (NSInteger)maxCandOrders : (NSInteger)minCandOrders;
            if (effectiveOrders >= config.foodMaxMerchantOrders) {
                ev.decision = FoodFilterDecisionRejectHard;
                ev.reasonSummary = [NSString stringWithFormat:@"Green Food Quán quá tải (%ld đơn >= %ld) -> HỦY CỨNG [X]",
                                    (long)effectiveOrders, (long)config.foodMaxMerchantOrders];
                return ev;
            }
        }
    }

    // =========================================================================
    // GATE 2: CLEAN SHOP — EITHER-OR (Price >= minFoodPriceVND OR Distance > minFoodDistanceKm)
    // =========================================================================
    // Fast Path 2A (0ms, zero network): Price already satisfies minFoodPriceVND!
    if (detectedFareVND >= config.minFoodPriceVND) {
        ev.decision = FoodFilterDecisionAccept;
        ev.reasonSummary = [NSString stringWithFormat:@"Green Food Quán sạch %ldđ (>= %ldđ) -> ĐỚP ĐƠN!",
                            (long)detectedFareVND, (long)config.minFoodPriceVND];
        return ev;
    }

    // Fast Path 2B: Distance rescue disabled -> reject low fare immediately
    if (!config.foodAcceptLongDistance) {
        ev.decision = FoodFilterDecisionRejectLowShort;
        ev.reasonSummary = [NSString stringWithFormat:@"Green Food %ldđ (< %ldđ) -> HỦY [X]",
                            (long)detectedFareVND, (long)config.minFoodPriceVND];
        return ev;
    }

    // Weak-4G Skeleton Guard on Dropoff text when we actually need distance measurement!
    NSString *cleanDropCheck = [self cleanLookupKeyFromString:(dropoffSubtitle.length > 0 ? dropoffSubtitle : dropoffTitle)];
    if (cleanDropCheck.length < 6) {
        if (retryCount < 6) {
            ev.decision = FoodFilterDecisionWaitTextLoading;
            ev.reasonSummary = @"Đang chờ load chữ Điểm giao để đo km (Chống lag 4G)...";
            return ev;
        } else {
            ev.decision = FoodFilterDecisionRejectLowShort;
            ev.reasonSummary = [NSString stringWithFormat:@"Green Food %ldđ (Không rõ Điểm giao sau 6 nhịp) -> HỦY [X]",
                                (long)detectedFareVND];
            return ev;
        }
    }

    double distKm = 0.0;
    NSString *distSrc = @"";
    BOOL gotDist = [self computeMotorbikeDistanceKmForPickupTitle:pickupTitle
                                                   pickupSubtitle:pickupSubtitle
                                                   matchedIndices:matchedIdxs
                                                     dropoffTitle:dropoffTitle
                                                  dropoffSubtitle:dropoffSubtitle
                                                      thresholdKm:config.minFoodDistanceKm
                                                            outKm:&distKm
                                                        outSource:&distSrc];
    ev.estimatedDistanceKm = distKm;
    ev.distanceSourceTag   = distSrc ?: @"";

    if (gotDist && distKm > config.minFoodDistanceKm) {
        ev.decision = FoodFilterDecisionAccept;
        ev.reasonSummary = [NSString stringWithFormat:@"Green Food Quán sạch %.2fkm (> %.1fkm, %ldđ, %@) -> ĐỚP ĐƠN!",
                            distKm, config.minFoodDistanceKm, (long)detectedFareVND, distSrc ?: @"Map"];
        return ev;
    }

    ev.decision = FoodFilterDecisionRejectLowShort;
    if (gotDist) {
        ev.reasonSummary = [NSString stringWithFormat:@"Green Food %ldđ & %.2fkm (<= %.1fkm, %@) -> HỦY [X]",
                            (long)detectedFareVND, distKm, config.minFoodDistanceKm, distSrc ?: @"Map"];
    } else {
        ev.reasonSummary = [NSString stringWithFormat:@"Green Food %ldđ (< %ldđ, chưa rõ tọa độ giao) -> HỦY [X]",
                            (long)detectedFareVND, (long)config.minFoodPriceVND];
    }
    return ev;
}

@end
