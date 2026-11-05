#import <Foundation/Foundation.h>
#import "SharedConfig.h"
#import "GSMOrderPayloadSniffer.h"
#import "HanoiFoodFilterEngine.h"

@implementation FilterConfig
- (instancetype)init {
    self = [super init];
    if (self) {
        _masterEnabled             = YES;
        _autoAcceptBike            = YES;
        _rejectAllFood             = NO;
        _minFoodPriceVND           = 25000;
        _foodBlockMallAndBasement  = YES;
        _foodBlockCrowdedChains    = YES;
        _foodMaxMerchantOrders     = 8000;
        _foodMallKeywords          = kDefaultFoodMallKeywords;
        _foodChainKeywords         = kDefaultFoodChainKeywords;
        _foodAcceptLongDistance    = YES;
        _minFoodDistanceKm         = 3.0;
    }
    return self;
}
+ (instancetype)loadFromDisk {
    return [[FilterConfig alloc] init];
}
- (void)saveToDiskAndNotify:(BOOL)sendNotify {}
@end

static int gFailures = 0;
static int gPasses   = 0;

#define ASSERT_TRUE(cond, msg, ...) do { \
    if (!(cond)) { \
        fprintf(stderr, "❌ [FAIL] Line %d: " msg "\n", __LINE__, ##__VA_ARGS__); \
        gFailures++; \
    } else { \
        gPasses++; \
    } \
} while (0)

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        printf("==> Running GSMOrderPayloadSniffer & HanoiFoodFilterEngine Verification Suite...\n");

        FilterConfig *cfg = [[FilterConfig alloc] init];
        GSMOrderPayloadSniffer *sniffer = [GSMOrderPayloadSniffer sharedSniffer];
        HanoiFoodFilterEngine *foodEngine = [HanoiFoodFilterEngine sharedEngine];

        printf("    Loaded Hanoi Offline DB: %ld merchants, %ld street pins (ready=%d)\n",
               (long)foodEngine.loadedMerchantCount,
               (long)foodEngine.loadedStreetPinCount,
               foodEngine.isIndexReady ? 1 : 0);
        ASSERT_TRUE(foodEngine.isIndexReady && foodEngine.loadedMerchantCount > 15000,
                    "Hanoi offline food index must load >15,000 merchants");

        // ---------------------------------------------------------------------
        // TEST 1: ULID 48-bit Timestamp Decoder
        // ---------------------------------------------------------------------
        double ts = [GSMOrderPayloadSniffer decodeULIDTimestampEpoch:@"01HJN66X4T48BY3M7NA34XZZJW"];
        ASSERT_TRUE(fabs(ts - 1703665693.850) < 0.001, "ULID timestamp expected 1703665693.850, got %.3f", ts);

        // ---------------------------------------------------------------------
        // TEST 2: Real GSM Express Order with package_types [{"id":"food"}]
        // Must NEVER be misclassified as Green Food!
        // ---------------------------------------------------------------------
        NSDictionary *expressJson = @{
            @"id": @"01HJN66X4T48BY3M7NA34XZZJW",
            @"distance": @(23.581494),
            @"express_detail": @{
                @"package_types": @[
                    @{ @"id": @"food", @"title": @"Thức ăn" }
                ]
            },
            @"fee": @{
                @"total_pay": @(11000),
                @"total_fee": @(11000),
                @"display": @"11.000đ",
                @"fee_breakdown": @{ @"base_fee": @(11000) }
            },
            @"service": @{
                @"display_name": @"Giao Hàng",
                @"service_type": @"EXPRESS-ONDEMAND"
            },
            @"path": @[
                @{
                    @"type": @"PICK UP",
                    @"name": @"An Nguyen",
                    @"short_address": @"Vincom Plaza Long Biên",
                    @"address": @"P. Chu Huy Mân, Phúc Lợi, Long Biên, Hà Nội",
                    @"latitude": @(21.04968),
                    @"longitude": @(105.917003)
                },
                @{
                    @"type": @"DROP OFF",
                    @"name": @"Binh Le",
                    @"short_address": @"Ga Hà Nội",
                    @"address": @"120 Đ. Lê Duẩn, Văn Miếu, Hoàn Kiếm, Hà Nội",
                    @"latitude": @(21.023944),
                    @"longitude": @(105.840557)
                }
            ]
        };
        GSMSniffedOrder *expOrd = [GSMOrderPayloadSniffer parseOrderFromJSONDictionary:expressJson sourceTag:@"Test"];
        ASSERT_TRUE(expOrd != nil, "Express order must parse");
        ASSERT_TRUE(expOrd.isBikeOrExpress == YES && expOrd.isGreenFood == NO,
                    "EXPRESS-ONDEMAND with food package_type must be Bike/Express (NOT Green Food!)");
        ASSERT_TRUE(expOrd.totalPayVND == 11000, "Express totalPayVND must be 11000");

        // ---------------------------------------------------------------------
        // TEST 3: Raw Dirty Buffer Extraction with Preceding Sibling JSON
        // ---------------------------------------------------------------------
        NSString *rawStream = @"SQLITE_WAL_HEADER\x00\x01{\"other\":\"sibling\",\"nested\":{\"a\":1}}   "
                              @"{\"data\":{\"id\":\"01HKCAB44HEK87D5KXJCFGBMW9\",\"distance\":\"4.65\","
                              @"\"fee\":{\"total_pay\":18000,\"fee_breakdown\":{\"base_fee\":18000}},"
                              @"\"service\":{\"display_name\":\"Green Food\",\"service_type\":\"FOOD-DELIVERY\"},"
                              @"\"path\":[{\"type\":\"PICK UP\",\"name\":\"Bún Bò Huế 65\",\"short_address\":\"65 Đường Láng\","
                              @"\"address\":\"65 Đường Láng, Ngã Tư Sở, Đống Đa, Hà Nội\",\"latitude\":21.0038,\"longitude\":105.8188},"
                              @"{\"type\":\"DROP OFF\",\"short_address\":\"120 Lê Duẩn\",\"address\":\"120 Lê Duẩn, Hoàn Kiếm, Hà Nội\","
                              @"\"latitude\":21.0239,\"longitude\":105.8405}]}}\x00TRAILING_GARBAGE";
        NSData *streamData = [rawStream dataUsingEncoding:NSUTF8StringEncoding];
        const uint8_t *bytes = (const uint8_t *)streamData.bytes;
        const uint8_t *hitPtr = (const uint8_t *)memmem(bytes, streamData.length, "\"fee_breakdown\"", 15);
        ASSERT_TRUE(hitPtr != NULL, "Must locate fee_breakdown in raw stream");
        GSMSniffedOrder *extracted = [sniffer extractOrderAroundOffset:(size_t)(hitPtr - bytes)
                                                              inBuffer:bytes
                                                                length:streamData.length
                                                             sourceTag:@"CacheWAL"];
        ASSERT_TRUE(extracted != nil, "Must extract balanced order JSON from dirty buffer");
        ASSERT_TRUE([extracted.orderId isEqualToString:@"01HKCAB44HEK87D5KXJCFGBMW9"], "Extracted ULID must match");
        ASSERT_TRUE(extracted.isGreenFood == YES && extracted.isBikeOrExpress == NO, "Must classify FOOD-DELIVERY as Green Food");
        ASSERT_TRUE(extracted.totalPayVND == 18000, "Extracted totalPayVND must be 18000");
        ASSERT_TRUE(fabs(extracted.serverDistanceKm - 4.65) < 0.001, "Extracted serverDistanceKm must be 4.65");

        // ---------------------------------------------------------------------
        // TEST 4: Gate 1 — Screen Truncated "..." Mall Address vs Full Payload
        // ---------------------------------------------------------------------
        NSDictionary *mallFoodJson = @{
            @"id": @"01HKCAB44HEK87D5KXJCFGBMW1",
            @"distance": @(5.2),
            @"fee": @{ @"total_pay": @(32000) },
            @"service": @{ @"display_name": @"Green Food", @"service_type": @"FOOD-DELIVERY" },
            @"path": @[
                @{
                    @"type": @"PICK UP",
                    @"name": @"Quán Ăn Ngon",
                    @"short_address": @"Tầng hầm B1, Vincom Center Bà Triệu",
                    @"address": @"191 Bà Triệu, Lê Đại Hành, Hai Bà Trưng, Hà Nội",
                    @"latitude": @(21.0112),
                    @"longitude": @(105.8497)
                },
                @{
                    @"type": @"DROP OFF",
                    @"short_address": @"85 Xuân Thủy",
                    @"address": @"85 Xuân Thủy, Dịch Vọng Hậu, Cầu Giấy, Hà Nội",
                    @"latitude": @(21.0368),
                    @"longitude": @(105.7848)
                }
            ]
        };
        GSMSniffedOrder *mallOrd = [GSMOrderPayloadSniffer parseOrderFromJSONDictionary:mallFoodJson sourceTag:@"Test"];
        // Simulate screen OCR where "Vincom Center Bà Triệu" was truncated to "Quán Ăn Ngon..."
        FoodFilterEvaluation *evMall = [foodEngine evaluateGreenFoodWithFare:32000
                                                                 pickupTitle:@"Quán Ăn Ngon..."
                                                              pickupSubtitle:@"Số 191..."
                                                                dropoffTitle:@"85 Xuân Thủy"
                                                             dropoffSubtitle:@"Cầu Giấy, Hà Nội"
                                                                sniffedOrder:mallOrd
                                                                      config:cfg
                                                                  retryCount:1];
        ASSERT_TRUE(evMall.decision == FoodFilterDecisionRejectHard,
                    "Untruncated Mall/Basement in payload must trigger Gate 1 Hard Reject even when OCR text was truncated with '...'");

        // ---------------------------------------------------------------------
        // TEST 5: Gate 2A — Clean Shop with Price >= minFoodPriceVND (28k >= 25k)
        // Must ACCEPT immediately WITHOUT measuring or rejecting by short distance (1.1km)!
        // ---------------------------------------------------------------------
        NSDictionary *highPriceShortFoodJson = @{
            @"id": @"01HKCAB44HEK87D5KXJCFGBMW2",
            @"distance": @(1.10), // Short distance 1.1km, but price is 28,000 >= 25,000!
            @"fee": @{ @"total_pay": @(28000) },
            @"service": @{ @"display_name": @"Green Food", @"service_type": @"FOOD-DELIVERY" },
            @"path": @[
                @{
                    @"type": @"PICK UP",
                    @"name": @"Phở Bò Gia Truyền Nam Định",
                    @"short_address": @"102 Thái Thịnh",
                    @"address": @"102 Thái Thịnh, Ngã Tư Sở, Đống Đa, Hà Nội",
                    @"latitude": @(21.0075),
                    @"longitude": @(105.8195)
                },
                @{
                    @"type": @"DROP OFF",
                    @"short_address": @"45 Thái Hà",
                    @"address": @"45 Thái Hà, Trung Liệt, Đống Đa, Hà Nội",
                    @"latitude": @(21.0115),
                    @"longitude": @(105.8215)
                }
            ]
        };
        GSMSniffedOrder *highPriceOrd = [GSMOrderPayloadSniffer parseOrderFromJSONDictionary:highPriceShortFoodJson sourceTag:@"Test"];
        FoodFilterEvaluation *evHighPrice = [foodEngine evaluateGreenFoodWithFare:28000
                                                                      pickupTitle:@"Phở Bò Gia Truyền..."
                                                                   pickupSubtitle:@"102 Thái Thịnh..."
                                                                     dropoffTitle:@"45 Thái Hà"
                                                                  dropoffSubtitle:@"Đống Đa"
                                                                     sniffedOrder:highPriceOrd
                                                                           config:cfg
                                                                       retryCount:1];
        ASSERT_TRUE(evHighPrice.decision == FoodFilterDecisionAccept,
                    "Clean Food with Price >= minFoodPriceVND (28k >= 25k) must ACCEPT immediately even if distance is 1.1km");
        ASSERT_TRUE(evHighPrice.estimatedDistanceKm == 0.0,
                    "When Price >= minFoodPriceVND, engine must NOT measure distance (got %.2fkm)", evHighPrice.estimatedDistanceKm);

        // ---------------------------------------------------------------------
        // TEST 6: Gate 2B — Clean Shop with Price < minFoodPriceVND (15k < 25k) & Short Distance (1.6km <= 3.0km)
        // Must measure distance and REJECT!
        // ---------------------------------------------------------------------
        NSDictionary *lowPriceShortFoodJson = @{
            @"id": @"01HKCAB44HEK87D5KXJCFGBMW3",
            @"distance": @(1.60),
            @"fee": @{ @"total_pay": @(15000) },
            @"service": @{ @"display_name": @"Green Food", @"service_type": @"FOOD-DELIVERY" },
            @"path": @[
                @{
                    @"type": @"PICK UP",
                    @"name": @"Bún Riêu Cua Tóp Mỡ",
                    @"short_address": @"102 Thái Thịnh",
                    @"address": @"102 Thái Thịnh, Ngã Tư Sở, Đống Đa, Hà Nội",
                    @"latitude": @(21.0075),
                    @"longitude": @(105.8195)
                },
                @{
                    @"type": @"DROP OFF",
                    @"short_address": @"45 Thái Hà",
                    @"address": @"45 Thái Hà, Trung Liệt, Đống Đa, Hà Nội",
                    @"latitude": @(21.0115),
                    @"longitude": @(105.8215)
                }
            ]
        };
        GSMSniffedOrder *lowShortOrd = [GSMOrderPayloadSniffer parseOrderFromJSONDictionary:lowPriceShortFoodJson sourceTag:@"Test"];
        FoodFilterEvaluation *evLowShort = [foodEngine evaluateGreenFoodWithFare:15000
                                                                     pickupTitle:@"Bún Riêu Cua..."
                                                                  pickupSubtitle:@"102 Thái Thịnh"
                                                                    dropoffTitle:@"45 Thái Hà"
                                                                 dropoffSubtitle:@"Đống Đa"
                                                                    sniffedOrder:lowShortOrd
                                                                          config:cfg
                                                                      retryCount:1];
        ASSERT_TRUE(evLowShort.decision == FoodFilterDecisionRejectLowShort,
                    "Clean Food with Price < 25k (15k) and Distance 1.6km <= 3.0km must REJECT");
        ASSERT_TRUE(fabs(evLowShort.estimatedDistanceKm - 1.60) < 0.01,
                    "Must measure exact 1.60km distance from payload when Price < minFoodPriceVND");

        // ---------------------------------------------------------------------
        // TEST 7: Gate 2C — Clean Shop with Price < minFoodPriceVND (16k < 25k) & Long Distance (4.5km > 3.0km)
        // Even when Dropoff OCR text on screen hasn't loaded yet, payload distance rescues it in 0ms!
        // ---------------------------------------------------------------------
        NSDictionary *lowPriceLongFoodJson = @{
            @"id": @"01HKCAB44HEK87D5KXJCFGBMW4",
            @"distance": @(4.50),
            @"fee": @{ @"total_pay": @(16000) },
            @"service": @{ @"display_name": @"Green Food", @"service_type": @"FOOD-DELIVERY" },
            @"path": @[
                @{
                    @"type": @"PICK UP",
                    @"name": @"Bún Đậu Mắm Tôm Cô Tuyết",
                    @"short_address": @"102 Thái Thịnh",
                    @"address": @"102 Thái Thịnh, Ngã Tư Sở, Đống Đa, Hà Nội",
                    @"latitude": @(21.0075),
                    @"longitude": @(105.8195)
                },
                @{
                    @"type": @"DROP OFF",
                    @"short_address": @"120 Lê Duẩn",
                    @"address": @"120 Lê Duẩn, Văn Miếu, Hoàn Kiếm, Hà Nội",
                    @"latitude": @(21.023944),
                    @"longitude": @(105.840557)
                }
            ]
        };
        GSMSniffedOrder *lowLongOrd = [GSMOrderPayloadSniffer parseOrderFromJSONDictionary:lowPriceLongFoodJson sourceTag:@"Test"];
        FoodFilterEvaluation *evLowLong = [foodEngine evaluateGreenFoodWithFare:16000
                                                                    pickupTitle:@"Bún Đậu Mắm Tôm..."
                                                                 pickupSubtitle:@"102 Thái Thịnh"
                                                                   dropoffTitle:@"" // Even if OCR dropoff is blank/truncated!
                                                                dropoffSubtitle:@""
                                                                   sniffedOrder:lowLongOrd
                                                                         config:cfg
                                                                     retryCount:0];
        ASSERT_TRUE(evLowLong.decision == FoodFilterDecisionAccept,
                    "Clean Food with Price < 25k (16k) and Payload Distance 4.50km > 3.0km must ACCEPT in 0ms");

        // ---------------------------------------------------------------------
        // TEST 8: 3-Lock Verification — Home Screen Banner Delay (8s old), Motion Blur Correction & Stale Rejection
        // ---------------------------------------------------------------------
        double now = [[NSDate date] timeIntervalSince1970];
        lowShortOrd.orderTimestampEpoch = now - 8.5; // User saw banner on Home Screen and tapped 8.5s later
        lowShortOrd.sniffedAtEpoch      = now - 8.5;
        [sniffer cacheParsedOrder:lowShortOrd];

        // 8A: Matching address + OCR motion blur (15,000đ misread as 75,000đ by OCR) -> Must match and return 15,000đ!
        GSMSniffedOrder *matchedBlur = [sniffer sniffActiveOrderWithConfig:cfg
                                                               ocrPriceVND:75000
                                                           isOCRHeaderFood:YES
                                                        isOCRHeaderNonFood:NO
                                                                pickupText:@"Bún Riêu Cua 102 Thái Thịnh"
                                                               dropoffText:@"45 Thái Hà"];
        ASSERT_TRUE(matchedBlur != nil && matchedBlur.totalPayVND == 15000,
                    "When pickup address matches on screen, sniffer must match and correct OCR motion-blurred fare 75k -> 15k");

        // 8B: Conflicting new popup on screen ("85 Xuân Thủy, Cầu Giấy", 29,000đ) -> Lock 3 MUST reject stale 102 Thái Thịnh order!
        GSMSniffedOrder *conflictOrd = [sniffer sniffActiveOrderWithConfig:cfg
                                                               ocrPriceVND:29000
                                                           isOCRHeaderFood:YES
                                                        isOCRHeaderNonFood:NO
                                                                pickupText:@"Bánh Mì Chảo 85 Xuân Thủy Cầu Giấy"
                                                               dropoffText:@"144 Xuân Thủy"];
        ASSERT_TRUE(conflictOrd == nil,
                    "Lock 3 must reject cached order when visible OCR address conflicts");

        // 8C: Lock 1 (markOrderHandled:) permanently locks out handled orderId
        [sniffer markOrderHandled:lowShortOrd.orderId];
        GSMSniffedOrder *afterHandled = [sniffer sniffActiveOrderWithConfig:cfg
                                                                ocrPriceVND:15000
                                                            isOCRHeaderFood:YES
                                                         isOCRHeaderNonFood:NO
                                                                 pickupText:@"Bún Riêu Cua 102 Thái Thịnh"
                                                                dropoffText:@"45 Thái Hà"];
        ASSERT_TRUE(afterHandled == nil,
                    "Lock 1 must never return an orderId after markOrderHandled: is called");

        printf("==> Verification Suite Complete: %d passed, %d failed.\n", gPasses, gFailures);
        return (gFailures == 0) ? 0 : 1;
    }
}
