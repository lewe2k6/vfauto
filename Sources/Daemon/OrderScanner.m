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
        _thousandsFareRegex = [NSRegularExpression regularExpressionWithPattern:@"(?:^|[^0-9])([0-9]{1,3})[., ]([0-9]{3})"
                                                                        options:0
                                                                          error:nil];
        _plainFareRegex = [NSRegularExpression regularExpressionWithPattern:@"\\b([1-9][0-9]{1,2}000)\\s*[dđ₫]"
                                                                    options:NSRegularExpressionCaseInsensitive
                                                                      error:nil];
    }
    return self;
}

- (NSInteger)extractFareVNDFromString:(NSString *)str {
    if (!str || str.length < 4) return 0;

    NSString *norm = NormalizeVNText(str);
    if ([norm containsString:@"km"] || [norm containsString:@"diem"]) {
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

    return 0;
}

- (CGPoint)computeClosePointWithFoodBlock:(OCRTextBlock *)foodBlock
                            cuocPhiBlock:(OCRTextBlock *)cuocPhiBlock
                              screenSize:(CGSize)screenSize
                                  config:(FilterConfig *)config {
    if (config.coordMode == CoordModeFixedManual) {
        return CGPointMake(config.manualCloseX, config.manualCloseY);
    }
    double anchorY = 52.0;
    if (foodBlock) {
        anchorY = foodBlock.uiCenter.y;
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

    req.recognitionLevel = VNRequestRecognitionLevelAccurate;
    req.usesLanguageCorrection = NO;
    if (@available(iOS 16.0, *)) {
        req.recognitionLanguages = @[@"vi-VN", @"en-US"];
    } else {
        req.recognitionLanguages = @[@"en-US"];
    }

    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCIImage:ciImage options:@{}];
    [handler performRequests:@[req] error:nil];

    if (blocks.count == 0) return res;

    // Scan all blocks once to classify screen markers
    OCRTextBlock *cuocPhiBlock      = nil;
    OCRTextBlock *acceptBlock       = nil;
    OCRTextBlock *foodBlock         = nil;
    OCRTextBlock *moNhanChuyenBlock = nil;
    OCRTextBlock *dangTrucTuyenBlk  = nil;
    OCRTextBlock *xacNhanHTBlk      = nil;
    OCRTextBlock *hanhKhachBlk      = nil;
    OCRTextBlock *dieuHuongBlk      = nil;
    OCRTextBlock *daDenDiemDonBlk   = nil;
    OCRTextBlock *hoanThanhChuyenBlk= nil;
    OCRTextBlock *confirmOfflineBlk = nil;

    CGFloat kmLineY = screenSize.height * 0.45;

    for (OCRTextBlock *b in blocks) {
        NSString *t = b.normText;

        // 1. Lobby & Payment markers
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

        // Possible confirmation modal when turning offline ("Đồng ý" / "Xác nhận" / "Tắt trực tuyến")
        if (!confirmOfflineBlk && b.uiCenter.y > screenSize.height * 0.35 && b.uiCenter.y < screenSize.height * 0.82) {
            if (([t isEqualToString:@"xac nhan"] || [t isEqualToString:@"dong y"] ||
                 [t containsString:@"tat truc tuyen"] || [t containsString:@"ngung nhan"]) &&
                ![t containsString:@"hoan thanh"]) {
                confirmOfflineBlk = b;
            }
        }

        // 2. Active Trip markers ('Hành khách' + 'Điều hướng' + bottom stage button)
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

        // 3. Order Popup markers
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
        if (!foodBlock && b.uiCenter.y < screenSize.height * 0.30) {
            if ([t containsString:@"green food"] ||
                [t containsString:@"greenfood"] ||
                [t containsString:@"sm ngon"]) {
                foodBlock = b;
            }
        }
        if ([t containsString:@"km"] && [t containsString:@"diem"]) {
            kmLineY = b.uiCenter.y;
        }
    }

    // Populate Lobby & Payment states
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

    // Populate Active Trip states
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

    // Populate Order Popup state
    if (cuocPhiBlock && acceptBlock) {
        res.hasOrderPopup = YES;

        if (!foodBlock) {
            res.isGreenFood = NO;
            if (!config.autoAcceptBike) {
                res.orderAction = OrderActionSkipDisabled;
                res.orderReason = @"Đơn Bike/Khác (Tự nhận đang TẮT)";
                return res;
            }

            for (OCRTextBlock *b in blocks) {
                if (b.uiCenter.x > screenSize.width * 0.40 && b.uiCenter.y < kmLineY) {
                    NSInteger p = [self extractFareVNDFromString:b.rawText];
                    if (p > 0) { res.detectedPriceVND = p; break; }
                }
            }

            res.orderAction = OrderActionTapAccept;
            res.orderTargetPoint = [self computeAcceptPointWithAcceptBlock:acceptBlock screenSize:screenSize config:config];
            res.orderReason = (res.detectedPriceVND > 0)
                ? [NSString stringWithFormat:@"Green Bike (%ldđ) -> NHẬN CHUYẾN", (long)res.detectedPriceVND]
                : @"Green Bike/Khác -> NHẬN CHUYẾN";
            return res;
        }

        // Green Food branch
        res.isGreenFood = YES;
        if (config.rejectAllFood) {
            res.orderAction = OrderActionTapRejectX;
            res.orderTargetPoint = [self computeClosePointWithFoodBlock:foodBlock cuocPhiBlock:cuocPhiBlock screenSize:screenSize config:config];
            res.orderReason = @"Green Food (Chế độ Hủy sạch Food) -> BẤM [X]";
            return res;
        }

        NSInteger detectedFare = 0;
        CGFloat minFareY = MAX(15.0, cuocPhiBlock.uiCenter.y - 60.0);
        CGFloat maxFareY = MIN(kmLineY + 10.0, cuocPhiBlock.uiCenter.y + 65.0);

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

        if (detectedFare <= 0) {
            if (retryCount < 2) {
                res.orderAction = OrderActionWaitRetryPrice;
                res.orderReason = @"Đang lấy nét lại giá đơn Green Food...";
                return res;
            } else {
                res.orderAction = OrderActionTapRejectX;
                res.orderTargetPoint = [self computeClosePointWithFoodBlock:foodBlock cuocPhiBlock:cuocPhiBlock screenSize:screenSize config:config];
                res.orderReason = @"Green Food (Không rõ giá) -> HỦY [X]";
                return res;
            }
        }

        res.detectedPriceVND = detectedFare;
        if (detectedFare >= config.minFoodPriceVND) {
            res.orderAction = OrderActionTapAccept;
            res.orderTargetPoint = [self computeAcceptPointWithAcceptBlock:acceptBlock screenSize:screenSize config:config];
            res.orderReason = [NSString stringWithFormat:@"Green Food %ldđ (>= %ldđ) -> ĐỚP ĐƠN!",
                               (long)detectedFare, (long)config.minFoodPriceVND];
        } else {
            res.orderAction = OrderActionTapRejectX;
            res.orderTargetPoint = [self computeClosePointWithFoodBlock:foodBlock cuocPhiBlock:cuocPhiBlock screenSize:screenSize config:config];
            res.orderReason = [NSString stringWithFormat:@"Green Food %ldđ (< %ldđ) -> HỦY [X]",
                               (long)detectedFare, (long)config.minFoodPriceVND];
        }
    }

    return res;
}

@end
