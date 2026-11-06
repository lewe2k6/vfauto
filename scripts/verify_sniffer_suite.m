#import <Foundation/Foundation.h>
#import "SharedConfig.h"
#import "GSMOrderPayloadSniffer.h"
#import "HanoiFoodFilterEngine.h"
#import "OrderScanner.h"
#import "StealthStatusPillHUD.h"

@implementation FilterConfig
- (instancetype)init {
    self = [super init];
    if (self) {
        _masterEnabled              = YES;
        _autoAcceptBike             = YES;
        _expressBlockLongChau       = YES;
        _expressBlockedNoteKeywords = kDefaultExpressBlockedNotes;
        _rejectAllFood              = NO;
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

        // ---------------------------------------------------------------------
        // TEST 9: StealthStatusPillHUD — iPhone 8 (375x667pt) Zero-Collision Geometry & Retina Bitmap Rendering
        // ---------------------------------------------------------------------
        CGSize ip8Screen = CGSizeMake(375.0, 667.0);
        CGRect compactRect = [StealthStatusPillHUD logicalFrameForCompact:YES screenSize:ip8Screen];
        CGRect toastRect   = [StealthStatusPillHUD logicalFrameForCompact:NO  screenSize:ip8Screen];

        // 9A: Compact pill sits in empty iPhone 8 Status Bar corridor x=215..307, y=2..18pt
        ASSERT_TRUE(CGRectGetMinX(compactRect) >= 214.0 && CGRectGetMaxX(compactRect) <= 308.0,
                    "Compact pill X=[%.1f..%.1f] must clear iOS clock (<=212pt) and GPS/Battery (>=310pt)",
                    CGRectGetMinX(compactRect), CGRectGetMaxX(compactRect));
        ASSERT_TRUE(CGRectGetMinY(compactRect) >= 1.5 && CGRectGetMaxY(compactRect) <= 19.0,
                    "Compact pill Y=[%.1f..%.1f] must stay inside top 20pt iOS Status Bar and >=16pt above ScreenTouchEngine sensors (y>=34pt)",
                    CGRectGetMinY(compactRect), CGRectGetMaxY(compactRect));
        CGFloat compactCenterY = CGRectGetMidY(compactRect);
        ASSERT_TRUE(compactCenterY < 21.0,
                    "Compact pill centerY=%.2f must be strictly below OrderScanner 21.0pt Status Bar OCR cutoff",
                    compactCenterY);

        // 9B: Expanded 2.5s Toast pill sits in x=138..307, y=1.8..18.3pt
        ASSERT_TRUE(CGRectGetMinX(toastRect) >= 137.0 && CGRectGetMaxX(toastRect) <= 308.0,
                    "Toast pill X=[%.1f..%.1f] must clear left 'Google Maps 4G' (<=136pt) and right GPS/Battery (>=310pt)",
                    CGRectGetMinX(toastRect), CGRectGetMaxX(toastRect));
        ASSERT_TRUE(CGRectGetMaxY(toastRect) < 20.0 && CGRectGetMidY(toastRect) < 21.0,
                    "Toast pill Y=[%.1f..%.1f] must never touch Xanh SM header/buttons (y>=24pt) or OrderPopup [X] at (342, 52)",
                    CGRectGetMinY(toastRect), CGRectGetMaxY(toastRect));

        // 9C: Retina @2x CoreGraphics + CoreText capsule bitmap rendering
        CGImageRef imgCompact = [StealthStatusPillHUD createPillBitmapWithText:@"CANH 12/4"
                                                                     isCompact:YES
                                                                         bgRed:0.05 bgGreen:0.08 bgBlue:0.11 bgAlpha:0.88
                                                                     borderRed:0.00 borderGreen:0.88 borderBlue:0.48
                                                                        dotRed:0.00 dotGreen:0.92 dotBlue:0.48
                                                                         scale:2.0];
        ASSERT_TRUE(imgCompact != NULL && CGImageGetWidth(imgCompact) == 184 && CGImageGetHeight(imgCompact) == 32,
                    "Compact @2x bitmap must render at 184x32px");
        if (imgCompact) CGImageRelease(imgCompact);

        CGImageRef imgToast = [StealthStatusPillHUD createPillBitmapWithText:@"HỦY Food 17k • 1.9km"
                                                                   isCompact:NO
                                                                       bgRed:0.42 bgGreen:0.09 bgBlue:0.07 bgAlpha:0.94
                                                                   borderRed:1.00 borderGreen:0.32 borderBlue:0.32
                                                                      dotRed:1.00 dotGreen:0.40 dotBlue:0.35
                                                                       scale:2.0];
        ASSERT_TRUE(imgToast != NULL && CGImageGetWidth(imgToast) == 338 && CGImageGetHeight(imgToast) == 33,
                    "Toast @2x bitmap must render at 338x33px with auto-shrinking Vietnamese text");
        if (imgToast) CGImageRelease(imgToast);

        // ---------------------------------------------------------------------
        // TEST 10: iPhone 8 Performance & Zero-4G Offline Hanoi Distance Routing
        // When sniffedOrder is nil (pure OCR fallback) and both addresses are in Hanoi Offline DB (123,757 coords),
        // distance must compute in < 20ms with 0 Byte 4G!
        // ---------------------------------------------------------------------
        CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
        FoodFilterEvaluation *evOfflineLong = [foodEngine evaluateGreenFoodWithFare:17000
                                                                        pickupTitle:@"Bún Bò Huế 65"
                                                                     pickupSubtitle:@"65 Đường Láng, Đống Đa, Hà Nội"
                                                                       dropoffTitle:@"85 Xuân Thủy"
                                                                    dropoffSubtitle:@"85 Xuân Thủy, Cầu Giấy, Hà Nội"
                                                                       sniffedOrder:nil
                                                                             config:cfg
                                                                         retryCount:0];
        double elapsedOfflineMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
        ASSERT_TRUE(evOfflineLong.decision == FoodFilterDecisionAccept && evOfflineLong.estimatedDistanceKm > 3.5,
                    "Offline Hanoi distance (65 Đường Láng -> 85 Xuân Thủy) must exceed 3.5km and ACCEPT (got %.2fkm)",
                    evOfflineLong.estimatedDistanceKm);
        ASSERT_TRUE(elapsedOfflineMs < 25.0,
                    "Zero-4G Offline Hanoi distance must complete in < 25ms without any HTTP call (took %.2fms)",
                    elapsedOfflineMs);

        // ---------------------------------------------------------------------
        // TEST 11: v5.4.0 Regression Guards — Food Pause 'NGHỈ 120s' & Active Trip 'TRONG CUỐC' Pill Rendering
        // ---------------------------------------------------------------------
        ASSERT_TRUE([kCurrentDaemonVersion isEqualToString:@"5.4.0"],
                    "kCurrentDaemonVersion must be 5.4.0 (got %s)", [kCurrentDaemonVersion UTF8String]);
        CGImageRef imgPause = [StealthStatusPillHUD createPillBitmapWithText:@"NGHỈ 120s"
                                                                   isCompact:YES
                                                                       bgRed:0.15 bgGreen:0.10 bgBlue:0.03 bgAlpha:0.91
                                                                   borderRed:1.00 borderGreen:0.70 borderBlue:0.00
                                                                      dotRed:1.00 dotGreen:0.75 dotBlue:0.05
                                                                       scale:2.0];
        ASSERT_TRUE(imgPause != NULL && CGImageGetWidth(imgPause) == 184 && CGImageGetHeight(imgPause) == 32,
                    "Food Pause 'NGHỈ 120s' compact @2x pill must render cleanly at 184x32px");
        if (imgPause) CGImageRelease(imgPause);

        CGImageRef imgTrip = [StealthStatusPillHUD createPillBitmapWithText:@"TRONG CUỐC"
                                                                  isCompact:YES
                                                                      bgRed:0.05 bgGreen:0.10 bgBlue:0.18 bgAlpha:0.88
                                                                  borderRed:0.16 borderGreen:0.71 borderBlue:0.96
                                                                     dotRed:0.16 dotGreen:0.75 dotBlue:1.00
                                                                      scale:2.0];
        ASSERT_TRUE(imgTrip != NULL && CGImageGetWidth(imgTrip) == 184 && CGImageGetHeight(imgTrip) == 32,
                    "Active Trip 'TRONG CUỐC' compact @2x pill must render cleanly at 184x32px");
        if (imgTrip) CGImageRelease(imgTrip);

        // ---------------------------------------------------------------------
        // TEST 12: v5.3.0 MDModels.GroupOrder (group_data, orders[], fee_data, shuttle_path[])
        // ---------------------------------------------------------------------
        NSDictionary *groupOrderJson = @{
            @"group_data": @{
                @"id": @"01HKCAB44HEK87D5KXJCFGBMW7",
                @"distance": @(4.85),
                @"fee_data": @{
                    @"total_pay": @(34000),
                    @"total_fee": @(34000),
                    @"fee_breakdown": @{ @"base_fee": @(34000) }
                },
                @"shuttle_path": @[
                    @{
                        @"type": @"PICK UP",
                        @"name": @"Cơm Thố Bách Khoa",
                        @"short_address": @"112 Tạ Quang Bửu",
                        @"address": @"112 Tạ Quang Bửu, Bách Khoa, Hai Bà Trưng, Hà Nội",
                        @"latitude": @(21.0042),
                        @"longitude": @(105.8468)
                    },
                    @{
                        @"type": @"DROP OFF",
                        @"name": @"Khach A",
                        @"short_address": @"88 Láng Hạ",
                        @"address": @"88 Láng Hạ, Đống Đa, Hà Nội",
                        @"latitude": @(21.0168),
                        @"longitude": @(105.8124)
                    }
                ],
                @"orders": @[
                    @{
                        @"id": @"01HKCAB44HEK87D5KXJCFGBMW8",
                        @"service": @{
                            @"display_name": @"Green Food Ghép",
                            @"service_type": @"FOOD-DELIVERY"
                        }
                    }
                ]
            }
        };
        GSMSniffedOrder *grpOrd = [GSMOrderPayloadSniffer parseOrderFromJSONDictionary:groupOrderJson sourceTag:@"GroupWAL"];
        ASSERT_TRUE(grpOrd != nil && grpOrd.isGroupOrder == YES, "MDModels.GroupOrder must parse with isGroupOrder == YES");
        ASSERT_TRUE([grpOrd.orderId isEqualToString:@"01HKCAB44HEK87D5KXJCFGBMW7"], "GroupOrder top-level ULID must match");
        ASSERT_TRUE(grpOrd.isGreenFood == YES && grpOrd.totalPayVND == 34000, "GroupOrder Food classification & 34k fee_data must match");
        ASSERT_TRUE([grpOrd.pickupName isEqualToString:@"Cơm Thố Bách Khoa"] && [grpOrd.dropoffShortAddress isEqualToString:@"88 Láng Hạ"],
                    "GroupOrder shuttle_path pickup & dropoff must extract cleanly");

        // ---------------------------------------------------------------------
        // TEST 13: v5.3.0 Delta-Offset + SQLite WAL Checkpoint Head Wrap-Around Reader
        // ---------------------------------------------------------------------
        NSString *tmpWalPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"test_gsm_cache.db-wal"];
        NSMutableData *walData = [NSMutableData dataWithLength:320 * 1024]; // 320 KB (> 256 KB tail window)
        memset(walData.mutableBytes, 'A', walData.length);
        // Simulate SQLite WAL wrapping around to offset 64 (near head of 320KB file) after a checkpoint:
        NSString *headOrderStr = @"{\"id\":\"01HKCAB44HEK87D5KXJCFGBMW5\",\"distance\":3.7,\"fee_data\":{\"total_pay\":29000},"
                                 @"\"service\":{\"display_name\":\"Green Bike\",\"service_type\":\"BIKE\"},"
                                 @"\"shuttle_path\":[{\"type\":\"PICK UP\",\"short_address\":\"100 Kim Mã\",\"address\":\"100 Kim Mã, Ba Đình, Hà Nội\"},"
                                 @"{\"type\":\"DROP OFF\",\"short_address\":\"200 Cầu Giấy\",\"address\":\"200 Cầu Giấy, Hà Nội\"}]}";
        NSData *headJsonBytes = [headOrderStr dataUsingEncoding:NSUTF8StringEncoding];
        [walData replaceBytesInRange:NSMakeRange(64, headJsonBytes.length) withBytes:headJsonBytes.bytes];
        [walData writeToFile:tmpWalPath atomically:YES];

        NSMutableArray<GSMSniffedOrder *> *walCands = [NSMutableArray array];
        [sniffer scanFileTailAtPath:tmpWalPath
                          maxAgeSec:60.0
                           nowEpoch:[[NSDate date] timeIntervalSince1970]
                        targetULIDs:@[@"01HKCAB44HEK87D5KXJCFGBMW5"]
                          sourceTag:@"CacheWAL"
                     intoCandidates:walCands];
        ASSERT_TRUE(walCands.count == 1 && [walCands.firstObject.orderId isEqualToString:@"01HKCAB44HEK87D5KXJCFGBMW5"],
                    "Head/Tail WAL Reader must find wrapped-around order at offset 64 of a 320KB WAL file");

        // Now simulate Delta-Offset append of a new order at the end of the 320KB WAL file:
        NSString *tailOrderStr = @"   {\"id\":\"01HKCAB44HEK87D5KXJCFGBMW6\",\"distance\":2.4,\"fee\":{\"total_pay\":22000},"
                                 @"\"service\":{\"display_name\":\"Giao Hàng\",\"service_type\":\"EXPRESS-ONDEMAND\"},"
                                 @"\"path\":[{\"type\":\"PICK UP\",\"short_address\":\"15 Xuân Thủy\"},{\"type\":\"DROP OFF\",\"short_address\":\"80 Duy Tân\"}]}";
        [walData appendData:[tailOrderStr dataUsingEncoding:NSUTF8StringEncoding]];
        [walData writeToFile:tmpWalPath atomically:YES];

        NSMutableArray<GSMSniffedOrder *> *deltaCands = [NSMutableArray array];
        [sniffer scanFileTailAtPath:tmpWalPath
                          maxAgeSec:60.0
                           nowEpoch:[[NSDate date] timeIntervalSince1970]
                        targetULIDs:@[@"01HKCAB44HEK87D5KXJCFGBMW6"]
                          sourceTag:@"CacheWAL"
                     intoCandidates:deltaCands];
        ASSERT_TRUE(deltaCands.count == 1 && [deltaCands.firstObject.orderId isEqualToString:@"01HKCAB44HEK87D5KXJCFGBMW6"],
                    "Delta-Offset Reader must read newly appended bytes at tail of WAL file in <0.05ms");
        [[NSFileManager defaultManager] removeItemAtPath:tmpWalPath error:nil];

        // ---------------------------------------------------------------------
        // TEST 14: v5.4.0 Express Long Châu Note Blocker ("TX đến Nhà Thuốc Long Châu")
        // - 14A: Single Express order with "TX đến Nhà Thuốc Long Châu vui lòng..." in address_note -> REJECT
        // - 14B: GroupOrder (Express 2H) where shuttle_path omits address_note and orders[1].path[0].address_note has "TX đến Nhà Thuốc Long Châu..." -> REJECT
        // - 14C: Normal Express order where pickupName/short_address is "Nhà thuốc FPT Long Châu" but address_note is normal -> MUST NOT REJECT (0% false positive!)
        // ---------------------------------------------------------------------
        OrderScanner *scanner = [OrderScanner sharedScanner];

        NSDictionary *longChauSingleJson = @{
            @"id": @"01HKCAB44HEK87D5KXJCFGBMW9",
            @"distance": @(2.80),
            @"fee": @{ @"total_pay": @(24000) },
            @"service": @{ @"display_name": @"Siêu tốc", @"service_type": @"EXPRESS-ONDEMAND" },
            @"path": @[
                @{
                    @"type": @"PICK UP",
                    @"name": @"Cửa hàng 125",
                    @"short_address": @"125 Thái Hà",
                    @"address": @"125 Thái Hà, Trung Liệt, Đống Đa, Hà Nội",
                    @"address_note": @"TX đến Nhà Thuốc Long Châu vui lòng đọc mã đơn hàng cho dược sĩ, không ứng tiền"
                },
                @{
                    @"type": @"DROP OFF",
                    @"name": @"Anh Minh",
                    @"short_address": @"88 Láng Hạ",
                    @"address": @"88 Láng Hạ, Đống Đa, Hà Nội",
                    @"address_note": @"Gọi khách trước 5 phút"
                }
            ]
        };
        GSMSniffedOrder *lcSingleOrd = [GSMOrderPayloadSniffer parseOrderFromJSONDictionary:longChauSingleJson sourceTag:@"TestLC1"];
        NSString *matchedLC1 = [scanner matchedBlockedExpressNoteInSniffedOrder:lcSingleOrd config:cfg];
        ASSERT_TRUE(matchedLC1 != nil && [matchedLC1 isEqualToString:@"TX đến Nhà Thuốc Long Châu"],
                    "Single Express order with 'TX đến Nhà Thuốc Long Châu vui lòng...' in address_note must match blocked note");

        NSDictionary *longChauGroupJson = @{
            @"group_data": @{
                @"id": @"01HKCAB44HEK87D5KXJCFGBMX0",
                @"distance": @(5.20),
                @"fee_data": @{ @"total_pay": @(38000) },
                @"shuttle_path": @[
                    @{
                        @"type": @"PICK UP",
                        @"short_address": @"104 Nguyễn Văn Cừ",
                        @"address": @"104 Nguyễn Văn Cừ, Long Biên, Hà Nội"
                    },
                    @{
                        @"type": @"DROP OFF",
                        @"short_address": @"25 Lý Thường Kiệt",
                        @"address": @"25 Lý Thường Kiệt, Hoàn Kiếm, Hà Nội"
                    }
                ],
                @"orders": @[
                    @{
                        @"id": @"01HKCAB44HEK87D5KXJCFGBMX1",
                        @"service": @{ @"display_name": @"Express 2H", @"service_type": @"EXPRESS-SAMEDAY" },
                        @"path": @[
                            @{
                                @"type": @"PICK UP",
                                @"short_address": @"104 Nguyễn Văn Cừ",
                                @"address_note": @"Gửi đồ bình thường"
                            }
                        ]
                    },
                    @{
                        @"id": @"01HKCAB44HEK87D5KXJCFGBMX2",
                        @"service": @{ @"display_name": @"Express 2H", @"service_type": @"EXPRESS-SAMEDAY" },
                        @"path": @[
                            @{
                                @"type": @"PICK UP",
                                @"short_address": @"210 Ngọc Lâm",
                                @"address_note": @"TX đến Nhà Thuốc Long Châu nhận túi thuốc niêm phong"
                            }
                        ]
                    }
                ]
            }
        };
        GSMSniffedOrder *lcGroupOrd = [GSMOrderPayloadSniffer parseOrderFromJSONDictionary:longChauGroupJson sourceTag:@"TestLC2"];
        NSString *matchedLC2 = [scanner matchedBlockedExpressNoteInSniffedOrder:lcGroupOrd config:cfg];
        ASSERT_TRUE(matchedLC2 != nil && [matchedLC2 isEqualToString:@"TX đến Nhà Thuốc Long Châu"],
                    "GroupOrder Express 2H with 'TX đến Nhà Thuốc Long Châu...' nested inside orders[1].path[0].address_note must match");

        NSDictionary *normalNearLongChauJson = @{
            @"id": @"01HKCAB44HEK87D5KXJCFGBMX3",
            @"distance": @(3.40),
            @"fee": @{ @"total_pay": @(26000) },
            @"service": @{ @"display_name": @"Siêu tốc", @"service_type": @"EXPRESS-ONDEMAND" },
            @"path": @[
                @{
                    @"type": @"PICK UP",
                    @"name": @"Nhà Thuốc Long Châu - 125 Thái Hà",
                    @"short_address": @"Nhà Thuốc FPT Long Châu",
                    @"address": @"125 Thái Hà, Đống Đa, Hà Nội",
                    @"address_note": @"Mình đứng ở cửa nhà thuốc, tới nơi gọi số 0912345678 nhé"
                },
                @{
                    @"type": @"DROP OFF",
                    @"name": @"Chị Lan Long Châu",
                    @"short_address": @"45 Chùa Bộc",
                    @"address": @"45 Chùa Bộc, Đống Đa, Hà Nội",
                    @"address_note": @"Giao tận tay tại sảnh"
                }
            ]
        };
        GSMSniffedOrder *normalNearLCOrd = [GSMOrderPayloadSniffer parseOrderFromJSONDictionary:normalNearLongChauJson sourceTag:@"TestLC3"];
        NSString *matchedLC3 = [scanner matchedBlockedExpressNoteInSniffedOrder:normalNearLCOrd config:cfg];
        ASSERT_TRUE(matchedLC3 == nil,
                    "Normal Express order with 'Nhà Thuốc Long Châu' in pickupName/short_address/dropoffName but NOT 'TX đến Nhà Thuốc Long Châu' in address_note must NEVER be falsely rejected");

        printf("==> Verification Suite Complete: %d passed, %d failed.\n", gPasses, gFailures);
        return (gFailures == 0) ? 0 : 1;
    }
}
