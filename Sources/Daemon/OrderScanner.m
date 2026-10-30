#import "OrderScanner.h"
#import <Vision/Vision.h>

@implementation ScreenAnalysis
@end

@interface OCRTextBlock : NSObject
@property (nonatomic, copy) NSString *rawText;
@property (nonatomic, copy) NSString *normText;
@property (nonatomic, assign) CGRect uiRect;
@property (nonatomic, assign) CGPoint uiCenter;
@end

@implementation OCRTextBlock
@end

@implementation OrderScanner {
    NSRegularExpression *_thousandsFareRegex;
    NSRegularExpression *_plainFareRegex;
    NSRegularExpression *_bareThousandsRegex;
}

+ (instancetype)sharedScanner {
    static OrderScanner *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[OrderScanner alloc] init];
    });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _thousandsFareRegex = [NSRegularExpression regularExpressionWithPattern:@"(?:^|[^0-9])([1-9][0-9]{0,2})[., ]([0-9]{3})"
                                                                        options:0
                                                                          error:nil];
        _plainFareRegex = [NSRegularExpression regularExpressionWithPattern:@"\\b([1-9][0-9]{1,2}000)\\s*[dđ₫]"
                                                                    options:NSRegularExpressionCaseInsensitive
                                                                      error:nil];
        _bareThousandsRegex = [NSRegularExpression regularExpressionWithPattern:@"\\b([1-9][0-9]{1,2}000)\\b"
                                                                        options:0
                                                                          error:nil];
    }
    return self;
}

- (NSInteger)extractFareVNDFromString:(NSString *)str {
    if (!str || str.length < 4) return 0;

    NSString *norm = NormalizeVNText(str);
    if ([norm containsString:@"km"] ||
        [norm containsString:@"diem"] ||
        [norm containsString:@"phut"] ||
        [norm containsString:@"giay"]) {
        return 0;
    }

    NSTextCheckingResult *m = [_thousandsFareRegex firstMatchInString:str options:0 range:NSMakeRange(0, str.length)];
    if (m && m.numberOfRanges >= 3) {
        NSString *g1 = [str substringWithRange:[m rangeAtIndex:1]];
        NSString *g2 = [str substringWithRange:[m rangeAtIndex:2]];
        NSInteger val = [g1 integerValue] * 1000 + [g2 integerValue];
        if (val >= 5000 && val <= 2000000) {
            return val;
        }
    }

    NSTextCheckingResult *m2 = [_plainFareRegex firstMatchInString:str options:0 range:NSMakeRange(0, str.length)];
    if (m2 && m2.numberOfRanges >= 2) {
        NSInteger val = [[str substringWithRange:[m2 rangeAtIndex:1]] integerValue];
        if (val >= 5000 && val <= 2000000) {
            return val;
        }
    }

    NSTextCheckingResult *m3 = [_bareThousandsRegex firstMatchInString:str options:0 range:NSMakeRange(0, str.length)];
    if (m3 && m3.numberOfRanges >= 2) {
        NSInteger val = [[str substringWithRange:[m3 rangeAtIndex:1]] integerValue];
        if (val >= 8000 && val <= 999000) {
            return val;
        }
    }

    return 0;
}

- (CGPoint)computeClosePointWithHeaderBlock:(OCRTextBlock *)headerBlock
                               cuocPhiBlock:(OCRTextBlock *)cuocPhiBlock
                                 screenSize:(CGSize)screenSize
                                     config:(FilterConfig *)config {
    if (config.coordMode == CoordModeFixedManual) {
        return CGPointMake(config.manualCloseX, config.manualCloseY);
    }
    double anchorY = 52.0;
    if (headerBlock && headerBlock.uiCenter.y >= 24.0 && headerBlock.uiCenter.y <= 90.0) {
        anchorY = headerBlock.uiCenter.y;
    } else if (cuocPhiBlock) {
        anchorY = MAX(28.0, cuocPhiBlock.uiCenter.y - 49.0);
    }
    double x = (screenSize.width * config.closeXRatio) + config.closeOffsetX;
    double y = anchorY + config.closeOffsetY;
    return CGPointMake(x, y);
}

- (CGPoint)computeAcceptPointWithAcceptBlock:(OCRTextBlock *)acceptBlock
                                  screenSize:(CGSize)screenSize
                                      config:(FilterConfig *)config {
    if (config.coordMode == CoordModeFixedManual) {
        return CGPointMake(config.manualAcceptX, config.manualAcceptY);
    }
    double baseX = screenSize.width * 0.5;
    double baseY = acceptBlock ? acceptBlock.uiCenter.y : 640.0;
    return CGPointMake(baseX + config.acceptOffsetX, baseY + config.acceptOffsetY);
}

+ (BOOL)headerNormMatchesFood:(NSString *)hNorm {
    if (!hNorm || hNorm.length == 0) return NO;
    return ([hNorm containsString:@"food"] ||
            [hNorm containsString:@"f00d"] ||
            [hNorm containsString:@"fo0d"] ||
            [hNorm containsString:@"f0od"] ||
            [hNorm containsString:@"focd"] ||
            [hNorm containsString:@"foad"] ||
            [hNorm containsString:@"green fo"] ||
            [hNorm containsString:@"sm ngon"] ||
            [hNorm containsString:@"smngon"] ||
            [hNorm containsString:@"xanh ngon"] ||
            [hNorm containsString:@"do an"]);
}

+ (BOOL)headerNormMatchesNonFoodService:(NSString *)hNorm {
    if (!hNorm || hNorm.length == 0) return NO;
    return ([hNorm containsString:@"bike"] ||
            [hNorm containsString:@"b1ke"] ||
            [hNorm containsString:@"express"] ||
            [hNorm containsString:@"expres"] ||
            [hNorm containsString:@"expr"] ||
            [hNorm containsString:@"2h"] ||
            [hNorm containsString:@"4h"] ||
            [hNorm containsString:@"sieu toc"] ||
            [hNorm containsString:@"sieutoc"] ||
            [hNorm containsString:@"giao hang"] ||
            [hNorm containsString:@"giaohang"] ||
            [hNorm containsString:@"plus"] ||
            [hNorm containsString:@"car"] ||
            [hNorm containsString:@"luxury"] ||
            [hNorm containsString:@"taxi"]);
}

- (ScreenAnalysis *)analyzeScreenImage:(CIImage *)ciImage
                            screenSize:(CGSize)screenSize
                                config:(FilterConfig *)config
                       priceRetryCount:(NSInteger)retryCount {
    ScreenAnalysis *res = [[ScreenAnalysis alloc] init];
    res.offlinePowerPoint = CGPointMake(config.manualOfflineX, config.manualOfflineY);
    res.onlineStartPoint  = CGPointMake(config.manualOnlineX, config.manualOnlineY);
    res.navBluePoint      = CGPointMake(config.manualNavX, config.manualNavY);

    if (!ciImage) return res;

    __block NSMutableArray<OCRTextBlock *> *blocks = [NSMutableArray array];

    VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:^(VNRequest *request, NSError *error) {
        if (error) return;
        for (VNRecognizedTextObservation *obs in request.results) {
            VNRecognizedText *top = [[obs topCandidates:1] firstObject];
            if (!top || top.string.length == 0) continue;

            CGRect bb = obs.boundingBox;
            CGFloat uiX = bb.origin.x * screenSize.width;
            CGFloat uiW = bb.size.width * screenSize.width;
            CGFloat uiH = bb.size.height * screenSize.height;
            CGFloat uiY = (1.0 - (bb.origin.y + bb.size.height)) * screenSize.height;

            OCRTextBlock *blk = [[OCRTextBlock alloc] init];
            blk.rawText  = top.string;
            blk.normText = NormalizeVNText(top.string);
            blk.uiRect   = CGRectMake(uiX, uiY, uiW, uiH);
            blk.uiCenter = CGPointMake(uiX + uiW * 0.5, uiY + uiH * 0.5);
            [blocks addObject:blk];
        }
    }];

    req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    req.usesLanguageCorrection = NO;
    if (@available(iOS 16.0, *)) {
        req.recognitionLanguages = @[@"vi-VN", @"en-US"];
    } else {
        req.recognitionLanguages = @[@"en-US"];
    }

    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCIImage:ciImage options:@{}];
    [handler performRequests:@[req] error:nil];

    if (blocks.count == 0) {
        res.ocrBlockCount = 0;
        res.ocrSampleSummary = @"(Không đọc được chữ nào)";
        return res;
    }

    res.ocrBlockCount = blocks.count;
    NSMutableArray<NSString *> *previewArr = [NSMutableArray array];
    for (NSUInteger i = 0; i < MIN((NSUInteger)6, blocks.count); i++) {
        [previewArr addObject:blocks[i].rawText];
    }
    res.ocrSampleSummary = [previewArr componentsJoinedByString:@" | "];

    // 1. Scan all blocks once to classify screen markers
    OCRTextBlock *cuocPhiBlock       = nil;
    OCRTextBlock *acceptBlock        = nil;
    OCRTextBlock *moNhanChuyenBlock  = nil;
    OCRTextBlock *dangTrucTuyenBlk   = nil;
    OCRTextBlock *xacNhanHTBlk       = nil;
    OCRTextBlock *hanhKhachBlk       = nil;
    OCRTextBlock *dieuHuongBlk       = nil;
    OCRTextBlock *daDenDiemDonBlk    = nil;
    OCRTextBlock *hoanThanhChuyenBlk = nil;
    OCRTextBlock *confirmOfflineBlk  = nil;

    BOOL hasPassengerRoute = NO; // 'điểm đến' hoặc 'Insurance' (đặc quyền của Bike chở người)
    BOOL hasDeliveryRoute  = NO; // 'điểm nhận' hoặc 'điểm giao' (chung cho cả Express & Food)
    BOOL hasPaymentTag     = NO; // 'Tiền mặt' hoặc 'Thẻ/Ví'

    CGFloat kmLineY = screenSize.height * 0.42;

    for (OCRTextBlock *b in blocks) {
        NSString *t = b.normText;

        // Lobby & Payment markers
        if (!moNhanChuyenBlock && [t containsString:@"mo nhan chuyen"]) {
            if (b.uiCenter.y > screenSize.height * 0.25 && b.uiCenter.y < screenSize.height * 0.72) {
                moNhanChuyenBlock = b;
            }
        }
        if (!dangTrucTuyenBlk && b.uiCenter.y > screenSize.height * 0.55) {
            if ([t containsString:@"dang truc tuyen"] || [t containsString:@"truc tuyen"]) {
                dangTrucTuyenBlk = b;
            }
        }
        if (!xacNhanHTBlk && b.uiCenter.y > screenSize.height * 0.70) {
            if ([t containsString:@"xac nhan hoan thanh"]) {
                xacNhanHTBlk = b;
            }
        }

        if (!confirmOfflineBlk && b.uiCenter.y > screenSize.height * 0.35 && b.uiCenter.y < screenSize.height * 0.82) {
            if (([t isEqualToString:@"xac nhan"] || [t isEqualToString:@"dong y"] ||
                 [t containsString:@"tat truc tuyen"] || [t containsString:@"ngung nhan"]) &&
                ![t containsString:@"hoan thanh"]) {
                confirmOfflineBlk = b;
            }
        }

        // Active Trip markers ('Hành khách' + 'Điều hướng' + bottom stage button)
        if (!hanhKhachBlk && b.uiCenter.x < screenSize.width * 0.58 &&
            b.uiCenter.y > screenSize.height * 0.25 && b.uiCenter.y < screenSize.height * 0.70) {
            if ([t containsString:@"hanh khach"]) {
                hanhKhachBlk = b;
            }
        }
        if (!dieuHuongBlk && b.uiCenter.x > screenSize.width * 0.60 &&
            b.uiCenter.y > screenSize.height * 0.25 && b.uiCenter.y < screenSize.height * 0.70) {
            if ([t containsString:@"dieu huong"]) {
                dieuHuongBlk = b;
            }
        }
        if (!daDenDiemDonBlk && b.uiCenter.y > screenSize.height * 0.78) {
            if ([t containsString:@"da den diem don"] || [t containsString:@"den diem don"]) {
                daDenDiemDonBlk = b;
            }
        }
        if (!hoanThanhChuyenBlk && b.uiCenter.y > screenSize.height * 0.78) {
            if ([t containsString:@"hoan thanh chuyen"]) {
                hoanThanhChuyenBlk = b;
            }
        }

        // Order Popup core markers
        if (!cuocPhiBlock && b.uiCenter.y < screenSize.height * 0.45) {
            if ([t containsString:@"cuoc phi"] || [t containsString:@"cuocphi"]) {
                cuocPhiBlock = b;
            }
        }
        if (!acceptBlock && b.uiCenter.y > screenSize.height * 0.78) {
            if (([t containsString:@"nhan chuyen"] || [t containsString:@"nhanchuyen"]) &&
                ![t containsString:@"mo nhan"]) {
                acceptBlock = b;
            }
        }

        // Route & payment body markers (y < 0.52 * H)
        if (b.uiCenter.y > 60.0 && b.uiCenter.y < screenSize.height * 0.52) {
            if ([t containsString:@"diem den"] || [t containsString:@"insurance"]) {
                hasPassengerRoute = YES;
            }
            if ([t containsString:@"diem nhan"] || [t containsString:@"diem giao"]) {
                hasDeliveryRoute = YES;
            }
            if ([t containsString:@"tien mat"] || [t containsString:@"the/vi"] || [t containsString:@"the / vi"]) {
                hasPaymentTag = YES;
            }
            if ([t containsString:@"km"] && [t containsString:@"diem"]) {
                kmLineY = b.uiCenter.y;
            }
        }
    }

    // 2. Populate Lobby & Payment states
    res.isLobbyOnline          = (dangTrucTuyenBlk != nil);
    res.isLobbyOffline         = (moNhanChuyenBlock != nil);
    res.isPaymentConfirmScreen = (xacNhanHTBlk != nil);

    if (moNhanChuyenBlock && config.coordMode == CoordModeAutoOCRWithOffset) {
        res.onlineStartPoint = CGPointMake(moNhanChuyenBlock.uiCenter.x + config.onlineOffsetX,
                                           moNhanChuyenBlock.uiCenter.y + config.onlineOffsetY);
    }
    if (confirmOfflineBlk) {
        res.hasOfflineConfirmPopup = YES;
        res.confirmPopupPoint = confirmOfflineBlk.uiCenter;
    }

    // 3. Populate Active Trip states
    if (hanhKhachBlk && dieuHuongBlk) {
        res.hasPassengerAndNav = YES;
        res.isPickupStage      = (daDenDiemDonBlk != nil);
        res.isDropoffStage     = (hoanThanhChuyenBlk != nil);

        if (config.coordMode == CoordModeAutoOCRWithOffset) {
            res.navBluePoint = CGPointMake(dieuHuongBlk.uiCenter.x + config.navOffsetX,
                                           dieuHuongBlk.uiCenter.y + config.navOffsetY);
        } else {
            res.navBluePoint = CGPointMake(config.manualNavX, config.manualNavY);
        }
    }

    // 4. Inspect Service Header Bar ROI (strictly above 'Cước phí' / y = 20..92pt on iPhone 8)
    CGFloat headerMaxY = cuocPhiBlock
        ? MAX(66.0, cuocPhiBlock.uiCenter.y - 11.0)
        : (screenSize.height * 0.145);

    NSMutableArray<OCRTextBlock *> *headerBlocks = [NSMutableArray array];
    for (OCRTextBlock *b in blocks) {
        // Exclude top iOS status bar (y < 20pt: 'Google Maps 4G 11:29') and far-right [X] button
        if (b.uiCenter.y >= 21.0 && b.uiCenter.y <= headerMaxY && b.uiCenter.x < screenSize.width * 0.84) {
            [headerBlocks addObject:b];
        }
    }
    [headerBlocks sortUsingComparator:^NSComparisonResult(OCRTextBlock *a, OCRTextBlock *b) {
        if (a.uiCenter.x < b.uiCenter.x) return NSOrderedAscending;
        if (a.uiCenter.x > b.uiCenter.x) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    NSMutableArray<NSString *> *headerNormParts = [NSMutableArray array];
    NSMutableArray<NSString *> *headerRawParts  = [NSMutableArray array];
    OCRTextBlock *primaryHeaderBlk = headerBlocks.firstObject;
    for (OCRTextBlock *hb in headerBlocks) {
        [headerNormParts addObject:hb.normText];
        [headerRawParts addObject:hb.rawText];
    }
    NSString *joinedHeaderNorm = [headerNormParts componentsJoinedByString:@" "];
    NSString *joinedHeaderRaw  = [headerRawParts componentsJoinedByString:@" "];

    BOOL isHeaderFood    = [OrderScanner headerNormMatchesFood:joinedHeaderNorm];
    BOOL isHeaderNonFood = (!isHeaderFood && [OrderScanner headerNormMatchesNonFoodService:joinedHeaderNorm]);

    // 5. Banner-tolerant Order Popup check:
    // Bottom 'Nhận chuyến' + ANY body/header confirmation marker
    BOOL hasPopupEvidence = (cuocPhiBlock != nil ||
                             hasPassengerRoute ||
                             hasDeliveryRoute ||
                             hasPaymentTag ||
                             isHeaderFood ||
                             isHeaderNonFood);

    if (acceptBlock && hasPopupEvidence) {
        res.hasOrderPopup = YES;
        res.detectedServiceTitle = joinedHeaderRaw;

        // Helper to extract order fare from right half above route line
        CGFloat minFareY = cuocPhiBlock ? MAX(22.0, cuocPhiBlock.uiCenter.y - 55.0) : 55.0;
        CGFloat maxFareY = MIN(kmLineY - 5.0, cuocPhiBlock ? (cuocPhiBlock.uiCenter.y + 62.0) : (screenSize.height * 0.28));
        NSInteger detectedFare = 0;
        for (OCRTextBlock *b in blocks) {
            if (b.uiCenter.x >= screenSize.width * 0.38 &&
                b.uiCenter.y >= minFareY &&
                b.uiCenter.y <= maxFareY) {
                NSInteger fare = [self extractFareVNDFromString:b.rawText];
                if (fare > detectedFare) {
                    detectedFare = fare;
                }
            }
        }
        res.detectedPriceVND = detectedFare;

        // --- BRANCH A: CONFIRMED GREEN FOOD (Strictly Filter Price / Reject [X]) ---
        if (isHeaderFood) {
            res.isGreenFood = YES;

            if (config.rejectAllFood) {
                res.orderAction = OrderActionTapRejectX;
                res.orderTargetPoint = [self computeClosePointWithHeaderBlock:primaryHeaderBlk
                                                                 cuocPhiBlock:cuocPhiBlock
                                                                   screenSize:screenSize
                                                                       config:config];
                res.orderReason = @"Green Food (Chế độ Hủy sạch Food) -> BẤM [X]";
                return res;
            }

            if (detectedFare <= 0) {
                if (retryCount < 3) {
                    res.orderAction = OrderActionWaitRetryPrice;
                    res.orderReason = @"Đang lấy nét lại giá đơn Green Food...";
                    return res;
                } else {
                    res.orderAction = OrderActionTapRejectX;
                    res.orderTargetPoint = [self computeClosePointWithHeaderBlock:primaryHeaderBlk
                                                                     cuocPhiBlock:cuocPhiBlock
                                                                       screenSize:screenSize
                                                                           config:config];
                    res.orderReason = @"Green Food (Không rõ giá sau 3 nhịp) -> HỦY [X]";
                    return res;
                }
            }

            if (detectedFare >= config.minFoodPriceVND) {
                res.orderAction = OrderActionTapAccept;
                res.orderTargetPoint = [self computeAcceptPointWithAcceptBlock:acceptBlock
                                                                    screenSize:screenSize
                                                                        config:config];
                res.orderReason = [NSString stringWithFormat:@"Green Food %ldđ (>= %ldđ) -> ĐỚP ĐƠN!",
                                   (long)detectedFare, (long)config.minFoodPriceVND];
            } else {
                res.orderAction = OrderActionTapRejectX;
                res.orderTargetPoint = [self computeClosePointWithHeaderBlock:primaryHeaderBlk
                                                                 cuocPhiBlock:cuocPhiBlock
                                                                   screenSize:screenSize
                                                                       config:config];
                res.orderReason = [NSString stringWithFormat:@"Green Food %ldđ (< %ldđ) -> HỦY [X]",
                                   (long)detectedFare, (long)config.minFoodPriceVND];
            }
            return res;
        }

        // --- BRANCH B: CONFIRMED BIKE / EXPRESS / EXPRESS 2H (Immediate Accept) ---
        // Confirmed if header explicitly names Bike/Express/2H/etc., OR if passenger-only route ('điểm đến' / 'Insurance') is visible
        BOOL isConfirmedBikeByBody = (hasPassengerRoute && !hasDeliveryRoute);
        if (isHeaderNonFood || isConfirmedBikeByBody) {
            res.isGreenFood = NO;
            NSString *svcLabel = joinedHeaderRaw.length > 0
                ? joinedHeaderRaw
                : (isConfirmedBikeByBody ? @"Green Bike" : @"Bike/Express");

            if (!config.autoAcceptBike) {
                res.orderAction = OrderActionSkipDisabled;
                res.orderReason = [NSString stringWithFormat:@"%@ (Tự nhận đang TẮT)", svcLabel];
                return res;
            }

            res.orderAction = OrderActionTapAccept;
            res.orderTargetPoint = [self computeAcceptPointWithAcceptBlock:acceptBlock
                                                                screenSize:screenSize
                                                                    config:config];
            res.orderReason = (detectedFare > 0)
                ? [NSString stringWithFormat:@"%@ (%ldđ) -> NHẬN CHUYẾN", svcLabel, (long)detectedFare]
                : [NSString stringWithFormat:@"%@ -> NHẬN CHUYẾN", svcLabel];
            return res;
        }

        // --- BRANCH C: HEADER COVERED BY BANNER OR MID-TRANSITION (NEVER BLIND-ACCEPT!) ---
        res.isGreenFood = NO;
        if (retryCount < 6) {
            res.orderAction = OrderActionHeaderCovered;
            res.orderReason = @"Tiêu đề dịch vụ đang khuất (banner/chuyển cảnh) -> Chờ/hất banner đọc lại...";
            return res;
        } else {
            res.orderAction = OrderActionSkipDisabled;
            res.orderReason = @"[AN TOÀN] Tiêu đề đơn bị che khuất quá lâu -> Không bấm mù tránh nhầm Food!";
            return res;
        }
    }

    return res;
}

@end
