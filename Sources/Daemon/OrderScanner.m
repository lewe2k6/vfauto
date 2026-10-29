#import "OrderScanner.h"
#import <Vision/Vision.h>

@implementation ScanDecision
@end

@interface OCRTextBlock : NSObject
@property (nonatomic, copy) NSString *rawText;
@property (nonatomic, copy) NSString *normText;
@property (nonatomic, assign) CGRect uiRect;     // In top-left logical screen points (e.g. 375x667)
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
        // Matches e.g. "17.000", "25,500", "120.000" (even if trailing 'đ' is read as 'd'/'0'/'₫')
        _thousandsFareRegex = [NSRegularExpression regularExpressionWithPattern:@"(?:^|[^0-9])([0-9]{1,3})[., ]([0-9]{3})"
                                                                        options:0
                                                                          error:nil];
        // Fallback if price ever shown without dot: e.g. "25000đ" or "17000d"
        _plainFareRegex = [NSRegularExpression regularExpressionWithPattern:@"\\b([1-9][0-9]{1,2}000)\\s*[dđ₫]"
                                                                    options:NSRegularExpressionCaseInsensitive
                                                                      error:nil];
    }
    return self;
}

// Parses Vietnamese currency string into integer VND (returns 0 if not a valid fare)
- (NSInteger)extractFareVNDFromString:(NSString *)str {
    if (!str || str.length < 4) return 0;

    // Exclude strings that clearly belong to distance ("km", "diem nhan", "diem giao")
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

    // Mode 0: Auto OCR Anchor + Offset
    double anchorY = 52.0; // Fallback Y on iPhone 8
    if (foodBlock) {
        anchorY = foodBlock.uiCenter.y;
    } else if (cuocPhiBlock) {
        anchorY = MAX(28.0, cuocPhiBlock.uiCenter.y - 46.0);
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

    // Mode 0: Center horizontally on screen (or accept label center) + user offset
    double baseX = screenSize.width * 0.5;
    double baseY = acceptBlock ? acceptBlock.uiCenter.y : (screenSize.height - 42.0);
    return CGPointMake(baseX + config.acceptOffsetX, baseY + config.acceptOffsetY);
}

- (ScanDecision *)analyzeScreenImage:(CIImage *)ciImage
                          screenSize:(CGSize)screenSize
                              config:(FilterConfig *)config
                     priceRetryCount:(NSInteger)retryCount {
    ScanDecision *decision = [[ScanDecision alloc] init];
    decision.type = ScanDecisionNone;

    if (!ciImage) return decision;

    __block NSMutableArray<OCRTextBlock *> *blocks = [NSMutableArray array];

    VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:^(VNRequest *request, NSError *error) {
        if (error) return;
        for (VNRecognizedTextObservation *obs in request.results) {
            VNRecognizedText *top = [[obs topCandidates:1] firstObject];
            if (!top || top.string.length == 0) continue;

            // Convert Vision bottom-left [0..1] box to UIKit top-left logical points
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

    // Fast recognition reads Latin/VN text + digits on A11 in ~55ms without heavy NLP overhead
    req.recognitionLevel = VNRequestRecognitionLevelAccurate;
    req.usesLanguageCorrection = NO;
    if (@available(iOS 16.0, *)) {
        req.recognitionLanguages = @[@"vi-VN", @"en-US"];
    } else {
        req.recognitionLanguages = @[@"en-US"];
    }

    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCIImage:ciImage options:@{}];
    [handler performRequests:@[req] error:nil];

    if (blocks.count == 0) return decision;

    // --- CHỐT KHÓA 1: Phải thấy cả "Cước phí" (nửa trên) VÀ "Nhận chuyến" (nửa dưới) ---
    OCRTextBlock *cuocPhiBlock = nil;
    OCRTextBlock *acceptBlock  = nil;
    OCRTextBlock *foodBlock    = nil;
    CGFloat kmLineY = screenSize.height * 0.42;

    for (OCRTextBlock *b in blocks) {
        if (!cuocPhiBlock && b.uiCenter.y < screenSize.height * 0.48) {
            if ([b.normText containsString:@"cuoc phi"] || [b.normText containsString:@"cuocphi"]) {
                cuocPhiBlock = b;
            }
        }
        if (!acceptBlock && b.uiCenter.y > screenSize.height * 0.65) {
            if ([b.normText containsString:@"nhan chuyen"] || [b.normText containsString:@"nhanchuyen"]) {
                acceptBlock = b;
            }
        }
        if (!foodBlock && b.uiCenter.y < screenSize.height * 0.35) {
            if ([b.normText containsString:@"green food"] ||
                [b.normText containsString:@"greenfood"] ||
                [b.normText containsString:@"sm ngon"]) {
                foodBlock = b;
            }
        }
        if ([b.normText containsString:@"km"] && [b.normText containsString:@"diem"]) {
            kmLineY = b.uiCenter.y;
        }
    }

    if (!cuocPhiBlock || !acceptBlock) {
        // Không phải màn hình nổ cuốc -> đứng im tuyệt đối
        return decision;
    }

    // --- CHỐT KHÓA 2: Tách nhánh Đơn Bike/Khác vs Đơn Green Food ---
    if (!foodBlock) {
        decision.isGreenFood = NO;
        if (!config.autoAcceptBike) {
            decision.type = ScanDecisionSkipDisabled;
            decision.reasonSummary = @"Đơn Bike/Khác (Công tắc Tự nhận Bike đang TẮT)";
            return decision;
        }

        // Bóc thử giá đơn Bike để ghi vào Log cho đẹp (không bắt buộc)
        for (OCRTextBlock *b in blocks) {
            if (b.uiCenter.x > screenSize.width * 0.40 && b.uiCenter.y < kmLineY) {
                NSInteger p = [self extractFareVNDFromString:b.rawText];
                if (p > 0) { decision.detectedPriceVND = p; break; }
            }
        }

        decision.type = ScanDecisionTapAccept;
        decision.targetLogicalPoint = [self computeAcceptPointWithAcceptBlock:acceptBlock screenSize:screenSize config:config];
        if (decision.detectedPriceVND > 0) {
            decision.reasonSummary = [NSString stringWithFormat:@"Đơn Bike/Express (%ldđ) -> NHẬN CHUYẾN", (long)decision.detectedPriceVND];
        } else {
            decision.reasonSummary = @"Đơn Bike/Express -> NHẬN CHUYẾN";
        }
        return decision;
    }

    // --- CHỐT KHÓA 3: Xử lý đơn Green Food ---
    decision.isGreenFood = YES;

    if (config.rejectAllFood) {
        decision.type = ScanDecisionTapRejectX;
        decision.targetLogicalPoint = [self computeClosePointWithFoodBlock:foodBlock cuocPhiBlock:cuocPhiBlock screenSize:screenSize config:config];
        decision.reasonSummary = @"Green Food (Chế độ Hủy mọi đơn Food) -> BẤM [X]";
        return decision;
    }

    // Tìm số tiền cước phí nằm ở góc phải phía trên (x > 40% chiều ngang, ngang tầm chữ 'Cước phí', trên dòng km)
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

    // Nếu frame đầu số tiền bị mờ chưa đọc ra, cho phép đợi tối đa 2 nhịp (2 x 150ms) để đọc lại chắc chắn
    if (detectedFare <= 0) {
        if (retryCount < 2) {
            decision.type = ScanDecisionWaitRetryPrice;
            decision.reasonSummary = @"Thấy Green Food nhưng đang lấy nét lại giá tiền...";
            return decision;
        } else {
            // Hết 2 nhịp vẫn không đọc được giá -> An toàn nhất là bấm [X] hủy Food
            decision.type = ScanDecisionTapRejectX;
            decision.targetLogicalPoint = [self computeClosePointWithFoodBlock:foodBlock cuocPhiBlock:cuocPhiBlock screenSize:screenSize config:config];
            decision.reasonSummary = @"Green Food (Không rõ giá sau 2 nhịp) -> BẤM [X]";
            return decision;
        }
    }

    decision.detectedPriceVND = detectedFare;

    if (detectedFare >= config.minFoodPriceVND) {
        decision.type = ScanDecisionTapAccept;
        decision.targetLogicalPoint = [self computeAcceptPointWithAcceptBlock:acceptBlock screenSize:screenSize config:config];
        decision.reasonSummary = [NSString stringWithFormat:@"Green Food %ldđ (>= %ldđ) -> ĐỚP ĐƠN!",
                                  (long)detectedFare, (long)config.minFoodPriceVND];
    } else {
        decision.type = ScanDecisionTapRejectX;
        decision.targetLogicalPoint = [self computeClosePointWithFoodBlock:foodBlock cuocPhiBlock:cuocPhiBlock screenSize:screenSize config:config];
        decision.reasonSummary = [NSString stringWithFormat:@"Green Food %ldđ (< %ldđ) -> HỦY [X]",
                                  (long)detectedFare, (long)config.minFoodPriceVND];
    }

    return decision;
}

@end
