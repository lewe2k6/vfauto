#import "OrderScanner.h"
#import "HanoiFoodFilterEngine.h"
#import "GSMOrderPayloadSniffer.h"
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

@interface OCRMergedRouteLine : NSObject
@property (nonatomic, copy) NSString *rawText;
@property (nonatomic, copy) NSString *normText;
@property (nonatomic, assign) CGFloat minY;
@property (nonatomic, assign) CGFloat maxY;
@property (nonatomic, assign) CGFloat centerY;
@end

@implementation OCRMergedRouteLine
@end

@interface PreEvaluatedOrderEntry : NSObject
@property (nonatomic, copy)   NSString *orderId;
@property (nonatomic, strong) GSMSniffedOrder *sniffedOrder;
@property (nonatomic, assign) BOOL isGreenFood;
@property (nonatomic, assign) OrderActionType orderAction;
@property (nonatomic, copy)   NSString *orderReason;
@property (nonatomic, assign) double estimatedDistanceKm;
@property (nonatomic, copy)   NSString *pickupTitle;
@property (nonatomic, copy)   NSString *pickupSubtitle;
@property (nonatomic, copy)   NSString *dropoffTitle;
@property (nonatomic, copy)   NSString *dropoffSubtitle;
@property (nonatomic, copy)   NSString *orderFingerprint;
@property (nonatomic, copy)   NSString *configSignature;
@end

@implementation PreEvaluatedOrderEntry
@end

@implementation OrderScanner {
    CIContext *_ciContext;
    NSRegularExpression *_thousandsFareRegex;
    NSRegularExpression *_plainFareRegex;
    NSRegularExpression *_bareThousandsRegex;
    NSRegularExpression *_nonFoodHeaderRegex;
    NSRegularExpression *_foodHeaderRegex;
    NSRegularExpression *_foodPickupHintRegex;
    NSLock *_preEvalLock;
    NSMutableDictionary<NSString *, PreEvaluatedOrderEntry *> *_preEvalCache;
    NSMutableArray<NSString *> *_preEvalLRU;
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
        _ciContext = [CIContext contextWithOptions:@{
            kCIContextCacheIntermediates: @NO,
            kCIContextUseSoftwareRenderer: @NO
        }];
        _preEvalLock  = [[NSLock alloc] init];
        _preEvalCache = [[NSMutableDictionary alloc] initWithCapacity:16];
        _preEvalLRU   = [[NSMutableArray alloc] initWithCapacity:16];
        _thousandsFareRegex = [NSRegularExpression regularExpressionWithPattern:@"(?:^|[^0-9])([1-9][0-9]{0,2})[., ]([0-9]{3})"
                                                                        options:0
                                                                          error:nil];
        _plainFareRegex = [NSRegularExpression regularExpressionWithPattern:@"\\b([1-9][0-9]{1,2}000)\\s*[dđ₫]"
                                                                    options:NSRegularExpressionCaseInsensitive
                                                                      error:nil];
        _bareThousandsRegex = [NSRegularExpression regularExpressionWithPattern:@"\\b([1-9][0-9]{1,2}000)\\b"
                                                                        options:0
                                                                          error:nil];
        _foodHeaderRegex = [NSRegularExpression regularExpressionWithPattern:
            @"\\b(green\\s*f[o0]{1,2}d|greenf[o0]{1,2}d|xanh\\s*f[o0]{1,2}d|sm\\s*f[o0]{1,2}d|f[o0]{2}d|focd|foad|sm\\s*ngon|smngon|xanh\\s*ngon|do\\s*an|giao\\s*do\\s*an)\\b|green\\s*fo"
                                                                     options:0
                                                                       error:nil];
        _nonFoodHeaderRegex = [NSRegularExpression regularExpressionWithPattern:
            @"\\b(green\\s*bike|greenbike|xanh\\s*sm\\s*bike|xanh\\s*bike|sm\\s*bike|bike\\s*plus|bike|b1ke|blke|tiet\\s*kiem|tietkiem|uu\\s*tien|uutien|cho\\s*khach|xe\\s*may|green\\s*express|greenexpress|xanh\\s*express|sm\\s*express|express|expres|expre|2h|4h|sieu\\s*toc|sieutoc|giao\\s*hang|giaohang|gui\\s*hang|guihang|dong\\s*gia|donggia|don\\s*ghep|donghep|chuyen\\s*ghep|chuyenghep|green\\s*car|greencar|taxi)\\b"
                                                                        options:0
                                                                          error:nil];
        _foodPickupHintRegex = [NSRegularExpression regularExpressionWithPattern:
            @"\\b(bun\\s+|pho\\s+|com\\s+|tra\\s+sua|tra\\s+chanh|tra\\s+dao|ca\\s+phe|cafe|coffee|quan\\s+|nha\\s+hang|bep\\s+|tiem\\s+|banh\\s+mi|banh\\s+cuon|banh\\s+ga|banh\\s+trang|lau\\s+|nuong\\s+|ga\\s+ran|chao\\s+|mien\\s+|mi\\s+cay|mi\\s+tron|xoi\\s+|che\\s+|pizza|burger|chicken|mixue|highlands|starbucks|kfc|lotteria|jollibee|mcdonald|phuc\\s+long|phe\\s+la|katinat|gong\\s+cha|tocotoco|dookki|haidilao|gogi|manwah|kichi|marukame)\\b"
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
    if (headerBlock && headerBlock.uiCenter.y >= 24.0 && headerBlock.uiCenter.y <= screenSize.height * 0.42) {
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

- (BOOL)headerNormMatchesFood:(NSString *)hNorm {
    if (!hNorm || hNorm.length == 0 || !_foodHeaderRegex) return NO;
    return ([_foodHeaderRegex firstMatchInString:hNorm options:0 range:NSMakeRange(0, hNorm.length)] != nil);
}

- (BOOL)headerNormMatchesNonFoodService:(NSString *)hNorm {
    if (!hNorm || hNorm.length == 0 || !_nonFoodHeaderRegex) return NO;
    // Guard against in-trip collapsible header "Điểm giao hàng v Mở rộng" / "Điểm nhận hàng v Mở rộng" matching "giao hang"
    if ([hNorm containsString:@"diem giao"] ||
        [hNorm containsString:@"diemgiao"] ||
        [hNorm containsString:@"diem nhan"] ||
        [hNorm containsString:@"diemnhan"] ||
        [hNorm containsString:@"diem don"] ||
        [hNorm containsString:@"diem den"] ||
        [hNorm containsString:@"mo rong"] ||
        [hNorm containsString:@"morong"] ||
        [hNorm containsString:@"thu gon"] ||
        [hNorm containsString:@"thugon"]) {
        return NO;
    }
    return ([_nonFoodHeaderRegex firstMatchInString:hNorm options:0 range:NSMakeRange(0, hNorm.length)] != nil);
}

- (void)splitStopLines:(NSArray<OCRMergedRouteLine *> *)lines
              outTitle:(NSString * __strong *)outTitle
           outSubtitle:(NSString * __strong *)outSubtitle {
    if (!lines || lines.count == 0) {
        if (outTitle) *outTitle = @"";
        if (outSubtitle) *outSubtitle = @"";
        return;
    }
    if (lines.count == 1) {
        if (outTitle) *outTitle = lines[0].rawText ?: @"";
        if (outSubtitle) *outSubtitle = lines[0].rawText ?: @"";
        return;
    }

    NSUInteger splitIdx = NSNotFound;
    for (NSUInteger i = 1; i < lines.count; i++) {
        OCRMergedRouteLine *prev = lines[i - 1];
        OCRMergedRouteLine *cur  = lines[i];
        CGFloat vGap = cur.minY - prev.maxY;
        BOOL prevEndsCountry = ([prev.normText hasSuffix:@"viet nam"] ||
                                [prev.normText hasSuffix:@"vietnam"] ||
                                [prev.normText hasSuffix:@"vnm"]);
        if (vGap >= 9.5 || prevEndsCountry) {
            splitIdx = i;
            break;
        }
    }

    if (splitIdx == NSNotFound) {
        NSMutableArray<NSString *> *allRaw = [NSMutableArray arrayWithCapacity:lines.count];
        for (OCRMergedRouteLine *ln in lines) {
            [allRaw addObject:ln.rawText];
        }
        NSString *joined = [allRaw componentsJoinedByString:@" "];
        if (outTitle) *outTitle = joined;
        if (outSubtitle) *outSubtitle = joined;
        return;
    }

    NSMutableArray<NSString *> *titleParts = [NSMutableArray arrayWithCapacity:splitIdx];
    NSMutableArray<NSString *> *subParts   = [NSMutableArray arrayWithCapacity:lines.count - splitIdx];
    for (NSUInteger i = 0; i < lines.count; i++) {
        if (i < splitIdx) {
            [titleParts addObject:lines[i].rawText];
        } else {
            [subParts addObject:lines[i].rawText];
        }
    }
    if (outTitle) *outTitle = [titleParts componentsJoinedByString:@" "];
    if (outSubtitle) *outSubtitle = [subParts componentsJoinedByString:@" "];
}

- (NSString *)buildOrderFingerprintForFood:(BOOL)isFood
                                  priceVND:(NSInteger)priceVND
                               pickupTitle:(NSString *)pickupTitle
                              dropoffTitle:(NSString *)dropoffTitle {
    NSString *normP = NormalizeVNText(pickupTitle ?: @"");
    NSString *normD = NormalizeVNText(dropoffTitle ?: @"");
    NSMutableString *alnumP = [NSMutableString stringWithCapacity:38];
    for (NSUInteger i = 0; i < normP.length && alnumP.length < 34; i++) {
        unichar c = [normP characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) {
            [alnumP appendFormat:@"%C", c];
        }
    }
    NSMutableString *alnumD = [NSMutableString stringWithCapacity:16];
    for (NSUInteger i = 0; i < normD.length && alnumD.length < 14; i++) {
        unichar c = [normD characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) {
            [alnumD appendFormat:@"%C", c];
        }
    }
    NSString *comb = (alnumD.length > 0)
        ? [NSString stringWithFormat:@"%@_%@", alnumP, alnumD]
        : alnumP;
    return [NSString stringWithFormat:@"%@|%ld|%@", isFood ? @"FOOD" : @"RIDE", (long)priceVND, comb];
}

- (NSArray<OCRTextBlock *> *)buildRowMergedBlocksFrom:(NSArray<OCRTextBlock *> *)rawBlocks {
    if (rawBlocks.count < 2) return @[];
    NSArray<OCRTextBlock *> *sorted = [rawBlocks sortedArrayUsingComparator:^NSComparisonResult(OCRTextBlock *a, OCRTextBlock *b) {
        if (fabs(a.uiCenter.y - b.uiCenter.y) <= 8.0) {
            if (a.uiRect.origin.x < b.uiRect.origin.x) return NSOrderedAscending;
            if (a.uiRect.origin.x > b.uiRect.origin.x) return NSOrderedDescending;
            return NSOrderedSame;
        }
        return (a.uiCenter.y < b.uiCenter.y) ? NSOrderedAscending : NSOrderedDescending;
    }];

    NSMutableArray<OCRTextBlock *> *merged = [NSMutableArray array];
    OCRTextBlock *acc = nil;
    BOOL accMerged = NO;

    for (OCRTextBlock *b in sorted) {
        if (acc &&
            fabs(b.uiCenter.y - acc.uiCenter.y) <= 8.0 &&
            (CGRectGetMinX(b.uiRect) - CGRectGetMaxX(acc.uiRect)) <= 46.0) {
            CGRect uRect = CGRectUnion(acc.uiRect, b.uiRect);
            acc.rawText  = [NSString stringWithFormat:@"%@ %@", acc.rawText ?: @"", b.rawText ?: @""];
            acc.normText = [NSString stringWithFormat:@"%@ %@", acc.normText ?: @"", b.normText ?: @""];
            acc.uiRect   = uRect;
            acc.uiCenter = CGPointMake(CGRectGetMidX(uRect), CGRectGetMidY(uRect));
            accMerged    = YES;
        } else {
            if (acc && accMerged) {
                [merged addObject:acc];
            }
            acc = [[OCRTextBlock alloc] init];
            acc.rawText  = b.rawText;
            acc.normText = b.normText;
            acc.uiRect   = b.uiRect;
            acc.uiCenter = b.uiCenter;
            accMerged    = NO;
        }
    }
    if (acc && accMerged) {
        [merged addObject:acc];
    }
    return merged;
}

#pragma mark - Pre-Evaluation Decision Cache & Dual-Strip Micro-OCR (~15ms, 5 Anti-Mis-Tap Locks)

- (NSString *)configSignatureForConfig:(FilterConfig *)config {
    if (!config) return @"nil";
    return [NSString stringWithFormat:@"%d|%d|%lu|%d|%ld|%d|%d|%ld|%d|%.2f|%lu|%lu",
            config.autoAcceptBike ? 1 : 0,
            config.expressBlockLongChau ? 1 : 0,
            (unsigned long)(config.expressBlockedNoteKeywords.hash),
            config.rejectAllFood ? 1 : 0,
            (long)config.minFoodPriceVND,
            config.foodBlockMallAndBasement ? 1 : 0,
            config.foodBlockCrowdedChains ? 1 : 0,
            (long)config.foodMaxMerchantOrders,
            config.foodAcceptLongDistance ? 1 : 0,
            config.minFoodDistanceKm,
            (unsigned long)(config.foodMallKeywords.hash),
            (unsigned long)(config.foodChainKeywords.hash)];
}

- (NSString *)matchedBlockedExpressNoteInSniffedOrder:(GSMSniffedOrder *)sniffed
                                               config:(FilterConfig *)config {
    if (!sniffed || !config || !config.expressBlockLongChau) return nil;

    // STRICT RULE: ONLY inspect delivery note fields (allNotesCombined, pickupNote, dropoffNote).
    // NEVER inspect pickupName, pickupShortAddress, pickupFullAddress, or dropoffName to avoid false positives!
    NSMutableString *rawNotes = [NSMutableString stringWithCapacity:128];
    if (sniffed.allNotesCombined.length > 0) {
        [rawNotes appendString:sniffed.allNotesCombined];
    }
    if (sniffed.pickupNote.length > 0) {
        if (rawNotes.length > 0) [rawNotes appendString:@" | "];
        [rawNotes appendString:sniffed.pickupNote];
    }
    if (sniffed.dropoffNote.length > 0) {
        if (rawNotes.length > 0) [rawNotes appendString:@" | "];
        [rawNotes appendString:sniffed.dropoffNote];
    }
    if (rawNotes.length == 0) return nil;

    NSString *normNotes = NormalizeVNText(rawNotes);
    if (normNotes.length < 3) return nil;

    NSString *kwSource = (config.expressBlockedNoteKeywords.length > 0)
        ? config.expressBlockedNoteKeywords
        : kDefaultExpressBlockedNotes;
    NSCharacterSet *sepSet = [NSCharacterSet characterSetWithCharactersInString:@",;\n"];
    NSArray<NSString *> *parts = [kwSource componentsSeparatedByCharactersInSet:sepSet];

    for (NSString *rawPart in parts) {
        NSString *trimmed = [rawPart stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length < 3) continue;
        NSString *normKw = NormalizeVNText(trimmed);
        if (normKw.length >= 3 && [normNotes containsString:normKw]) {
            if ([normKw isEqualToString:@"tx den nha thuoc long chau"]) {
                return @"TX đến Nhà Thuốc Long Châu";
            }
            return trimmed;
        }
    }
    return nil;
}

- (PreEvaluatedOrderEntry *)evaluateOrFetchCachedOrder:(GSMSniffedOrder *)sniffed
                                            withConfig:(FilterConfig *)config {
    if (!sniffed || sniffed.orderId.length != 26 || !config) return nil;
    if (!sniffed.isGreenFood && !sniffed.isBikeOrExpress) return nil;

    NSString *cfgSig = [self configSignatureForConfig:config];
    [_preEvalLock lock];
    PreEvaluatedOrderEntry *cached = _preEvalCache[sniffed.orderId];
    if (cached && [cached.configSignature isEqualToString:cfgSig]) {
        [_preEvalLock unlock];
        return cached;
    }
    [_preEvalLock unlock];

    NSString *sName  = sniffed.pickupName ?: @"";
    NSString *sShort = sniffed.pickupShortAddress ?: @"";
    NSString *pTit = (sName.length > 0 && sShort.length > 0 && ![sShort.lowercaseString containsString:sName.lowercaseString])
        ? [NSString stringWithFormat:@"%@ - %@", sName, sShort]
        : (sShort.length > 0 ? sShort : sName);
    NSString *pSub = sniffed.pickupFullAddress ?: pTit;
    NSString *dTit = sniffed.dropoffShortAddress ?: (sniffed.dropoffName ?: @"");
    NSString *dSub = sniffed.dropoffFullAddress ?: dTit;

    NSInteger fare = sniffed.totalPayVND;
    PreEvaluatedOrderEntry *entry = [[PreEvaluatedOrderEntry alloc] init];
    entry.orderId          = sniffed.orderId;
    entry.sniffedOrder     = sniffed;
    entry.isGreenFood      = sniffed.isGreenFood;
    entry.pickupTitle      = pTit ?: @"";
    entry.pickupSubtitle   = pSub ?: @"";
    entry.dropoffTitle     = dTit ?: @"";
    entry.dropoffSubtitle  = dSub ?: @"";
    entry.configSignature  = cfgSig;

    NSString *baseFp = [self buildOrderFingerprintForFood:sniffed.isGreenFood
                                                 priceVND:fare
                                              pickupTitle:(pTit.length > 0 ? pTit : pSub)
                                             dropoffTitle:(dTit.length > 0 ? dTit : dSub)];
    entry.orderFingerprint = [NSString stringWithFormat:@"%@_%@", baseFp, sniffed.orderId];

    if (sniffed.isGreenFood) {
        if (config.rejectAllFood) {
            entry.orderAction = OrderActionTapRejectX;
            entry.orderReason = @"Green Food (Chế độ Hủy sạch Food) -> BẤM [X]";
        } else if (fare <= 0) {
            // Require valid fare to pre-evaluate Food
            return nil;
        } else {
            FoodFilterEvaluation *eval = [[HanoiFoodFilterEngine sharedEngine] evaluateGreenFoodWithFare:fare
                                                                                             pickupTitle:entry.pickupTitle
                                                                                          pickupSubtitle:entry.pickupSubtitle
                                                                                            dropoffTitle:entry.dropoffTitle
                                                                                         dropoffSubtitle:entry.dropoffSubtitle
                                                                                            sniffedOrder:sniffed
                                                                                                  config:config
                                                                                              retryCount:3];
            if (!eval || eval.decision == FoodFilterDecisionWaitTextLoading) {
                return nil;
            }
            entry.estimatedDistanceKm = eval.estimatedDistanceKm;
            entry.orderAction = (eval.decision == FoodFilterDecisionAccept) ? OrderActionTapAccept : OrderActionTapRejectX;
            entry.orderReason = eval.reasonSummary;
        }
    } else {
        NSString *svcLabel = sniffed.serviceDisplayName.length > 0 ? sniffed.serviceDisplayName : @"Bike/Express";
        NSString *blockedNoteKw = [self matchedBlockedExpressNoteInSniffedOrder:sniffed config:config];
        if (blockedNoteKw.length > 0) {
            entry.orderAction = OrderActionTapRejectX;
            entry.orderReason = (fare > 0)
                ? [NSString stringWithFormat:@"%@ (%ldđ - Ghi chú cấm: '%@') -> BẤM [X]", svcLabel, (long)fare, blockedNoteKw]
                : [NSString stringWithFormat:@"%@ (Ghi chú cấm: '%@') -> BẤM [X]", svcLabel, blockedNoteKw];
        } else if (!config.autoAcceptBike) {
            entry.orderAction = OrderActionSkipDisabled;
            entry.orderReason = [NSString stringWithFormat:@"%@ (Tự nhận đang TẮT)", svcLabel];
        } else {
            entry.orderAction = OrderActionTapAccept;
            entry.orderReason = (fare > 0)
                ? [NSString stringWithFormat:@"%@ (%ldđ) -> NHẬN CHUYẾN", svcLabel, (long)fare]
                : [NSString stringWithFormat:@"%@ -> NHẬN CHUYẾN", svcLabel];
        }
    }

    [_preEvalLock lock];
    if (!_preEvalCache[sniffed.orderId]) {
        if (_preEvalLRU.count >= 16) {
            NSString *oldest = _preEvalLRU.firstObject;
            if (oldest) {
                [_preEvalCache removeObjectForKey:oldest];
                [_preEvalLRU removeObjectAtIndex:0];
            }
        }
        [_preEvalLRU addObject:sniffed.orderId];
    }
    _preEvalCache[sniffed.orderId] = entry;
    [_preEvalLock unlock];

    return entry;
}

- (void)preEvaluateSniffedOrder:(GSMSniffedOrder *)sniffedOrder
                     withConfig:(FilterConfig *)config {
    [self evaluateOrFetchCachedOrder:sniffedOrder withConfig:config];
}

- (ScreenAnalysis *)tryFastMicroStripAnalysisOnImage:(CIImage *)ciImage
                                          screenSize:(CGSize)screenSize
                                    hasBottomTealBar:(BOOL)hasBottomTealBar
                                   hasTopWhiteHeader:(BOOL)hasTopWhiteHeader
                                  headerIconWarmFood:(BOOL)headerIconWarmFood
                                  headerIconCoolRide:(BOOL)headerIconCoolRide
                                 hasLobbyPowerButton:(BOOL)hasLobbyPowerButton
                                              config:(FilterConfig *)config {
    if (!ciImage || !config) return nil;

    // LOCK 2 (Pixel Sensor Dual-Lock):
    // Both bottom teal bar (y ~ 640pt) AND top white card header (y ~ 52pt) must be simultaneously present!
    // This guarantees FittedSheets.SheetViewController has finished sliding all the way up to y=52pt AND is not covered by a banner.
    if (!hasBottomTealBar || !hasTopWhiteHeader) {
        return nil;
    }

    // LOCK 3 (Anti-Lobby Lock):
    // Lobby [Power] circle at (40, 455) must be covered by the order sheet.
    if (hasLobbyPowerButton) {
        return nil;
    }

    // LOCK 1 (Fresh Unhandled ULID Payload Lock):
    GSMSniffedOrder *freshOrder = [[GSMOrderPayloadSniffer sharedSniffer] peekFreshUnverifiedOrderWithConfig:config maxAgeSec:7.5];
    if (!freshOrder || freshOrder.orderId.length != 26) {
        return nil;
    }
    if ([[GSMOrderPayloadSniffer sharedSniffer] isOrderIdHandled:freshOrder.orderId]) {
        return nil;
    }
    if (!freshOrder.isGreenFood && !freshOrder.isBikeOrExpress) {
        return nil;
    }

    // LOCK 4 (Chromatic Service Icon Lock at (18..54, 34..70)):
    // Never allow a Food payload if the screen icon is pure Cool Cyan (Bike/Express), or vice-versa!
    if (freshOrder.isGreenFood && headerIconCoolRide) {
        return nil;
    }
    if (freshOrder.isBikeOrExpress && headerIconWarmFood) {
        return nil;
    }

    PreEvaluatedOrderEntry *preEval = [self evaluateOrFetchCachedOrder:freshOrder withConfig:config];
    if (!preEval || preEval.orderAction == OrderActionNone) {
        return nil;
    }

    // LOCK 5 (Dual-Strip Micro-OCR ~15ms):
    // Stitch Top Header Strip (uiY = 20..140pt, height 120pt) directly onto Bottom Button Strip (uiY = 582..H, height 85pt)
    // with ZERO vertical gap so Vision only processes a 375x205pt image (~30% of screen area) in a single ~15ms pass!
    CGRect extent = ciImage.extent;
    if (extent.size.width < 100.0 || extent.size.height < 200.0 || screenSize.width < 100.0 || screenSize.height < 400.0) {
        return nil;
    }

    CGFloat topStripMinUIY = 20.0;
    CGFloat topStripMaxUIY = 140.0;
    CGFloat topStripUIH    = topStripMaxUIY - topStripMinUIY; // 120pt
    CGFloat botStripMinUIY = MAX(topStripMaxUIY + 40.0, screenSize.height - 85.0); // 582pt on 667pt screen
    CGFloat botStripUIH    = screenSize.height - botStripMinUIY; // 85pt
    CGFloat totalStripUIH  = topStripUIH + botStripUIH; // 205pt

    CGFloat scaleY = extent.size.height / screenSize.height;

    CGRect ciBotRect = CGRectMake(extent.origin.x,
                                  extent.origin.y,
                                  extent.size.width,
                                  botStripUIH * scaleY);
    CGRect ciTopRect = CGRectMake(extent.origin.x,
                                  extent.origin.y + (screenSize.height - topStripMaxUIY) * scaleY,
                                  extent.size.width,
                                  topStripUIH * scaleY);

    CIImage *botCrop = [[ciImage imageByCroppingToRect:ciBotRect]
        imageByApplyingTransform:CGAffineTransformMakeTranslation(-ciBotRect.origin.x, -ciBotRect.origin.y)];
    CIImage *topCrop = [[ciImage imageByCroppingToRect:ciTopRect]
        imageByApplyingTransform:CGAffineTransformMakeTranslation(-ciTopRect.origin.x, -ciTopRect.origin.y + (botStripUIH * scaleY))];
    CIImage *compositeStrip = [topCrop imageByCompositingOverImage:botCrop];

    __block NSMutableArray<OCRTextBlock *> *stripBlocks = [NSMutableArray arrayWithCapacity:12];

    @autoreleasepool {
        VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:^(VNRequest *request, NSError *error) {
            if (error) return;
            for (VNRecognizedTextObservation *obs in request.results) {
                VNRecognizedText *top = [[obs topCandidates:1] firstObject];
                if (!top || top.string.length == 0) continue;

                CGRect bb = obs.boundingBox;
                CGFloat uiX = bb.origin.x * screenSize.width;
                CGFloat uiW = bb.size.width * screenSize.width;
                CGFloat stripUIH = bb.size.height * totalStripUIH;
                CGFloat stripUIY = (1.0 - (bb.origin.y + bb.size.height)) * totalStripUIH;
                CGFloat stripCenterY = stripUIY + stripUIH * 0.5;

                // Map stitched strip coordinate back to exact full-screen UI Y coordinate:
                CGFloat fullUIY = (stripCenterY < topStripUIH)
                    ? (topStripMinUIY + stripUIY)
                    : (botStripMinUIY + (stripUIY - topStripUIH));
                CGFloat fullCenterY = fullUIY + stripUIH * 0.5;

                // Ignore iOS status bar (< 21pt)
                if (fullCenterY < MAX(21.0, screenSize.height * 0.0315)) {
                    continue;
                }

                OCRTextBlock *blk = [[OCRTextBlock alloc] init];
                blk.rawText  = top.string;
                blk.normText = NormalizeVNText(top.string);
                blk.uiRect   = CGRectMake(uiX, fullUIY, uiW, stripUIH);
                blk.uiCenter = CGPointMake(uiX + uiW * 0.5, fullCenterY);
                [stripBlocks addObject:blk];
            }
        }];

        req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
        req.usesLanguageCorrection = NO;
        if (@available(iOS 16.0, *)) {
            req.recognitionLanguages = @[@"vi-VN", @"en-US"];
        } else {
            req.recognitionLanguages = @[@"en-US"];
        }

        NSDictionary *vnOpts = _ciContext ? @{ VNImageOptionCIContext: _ciContext } : @{};
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCIImage:compositeStrip options:vnOpts];
        [handler performRequests:@[req] error:nil];
    }

    if (stripBlocks.count == 0) {
        return nil;
    }

    NSArray<OCRTextBlock *> *rowMerged = [self buildRowMergedBlocksFrom:stripBlocks];
    NSMutableArray<OCRTextBlock *> *scanBlocks = [NSMutableArray arrayWithCapacity:(stripBlocks.count + rowMerged.count)];
    [scanBlocks addObjectsFromArray:rowMerged];
    [scanBlocks addObjectsFromArray:stripBlocks];

    OCRTextBlock *acceptBlock  = nil;
    OCRTextBlock *cuocPhiBlock = nil;

    for (OCRTextBlock *b in scanBlocks) {
        NSString *t = b.normText;

        // Hard guard: reject immediately if any Active Trip, Lobby, or Collapsible Stop header appears in either strip!
        if ([t containsString:@"mo nhan chuyen"] ||
            [t containsString:@"dang truc tuyen"] ||
            [t containsString:@"xac nhan hoan thanh"] ||
            [t containsString:@"diem giao"] ||
            [t containsString:@"diem nhan"] ||
            [t containsString:@"diem don"] ||
            [t containsString:@"diem den"] ||
            [t containsString:@"mo rong"] ||
            [t containsString:@"thu gon"] ||
            [t containsString:@"da den diem"] ||
            [t containsString:@"da den quan"] ||
            [t containsString:@"da lay hang"] ||
            [t containsString:@"bat dau giao"] ||
            [t containsString:@"bat dau chuyen"] ||
            [t containsString:@"hoan thanh chuyen"] ||
            [t containsString:@"hoan thanh don"] ||
            [t containsString:@"giao hang thanh cong"] ||
            [t containsString:@"chup anh"] ||
            [t containsString:@"huy chuyen"] ||
            [t containsString:@"huy don"]) {
            return nil;
        }

        if (!cuocPhiBlock && b.uiCenter.y < topStripMaxUIY) {
            if ([t containsString:@"cuoc phi"] || [t containsString:@"cuocphi"]) {
                cuocPhiBlock = b;
            }
        }

        if (!acceptBlock && b.uiCenter.y > screenSize.height * 0.82) {
            BOOL isNotLobbyOrStop = (![t containsString:@"mo nhan"] &&
                                     ![t containsString:@"tat nhan"] &&
                                     ![t containsString:@"ngung nhan"] &&
                                     ![t containsString:@"da nhan"] &&
                                     ![t containsString:@"xac nhan"] &&
                                     ![t containsString:@"nhan hang"] &&
                                     ![t containsString:@"da den"] &&
                                     ![t containsString:@"bat dau"] &&
                                     ![t containsString:@"giao hang"] &&
                                     ![t containsString:@"lay hang"] &&
                                     ![t containsString:@"hoan thanh"] &&
                                     ![t containsString:@"chuyen cua toi"]);
            if (isNotLobbyOrStop &&
                ([t containsString:@"nhan chuyen"] ||
                 [t containsString:@"nhanchuyen"] ||
                 [t containsString:@"nhan chuven"] ||
                 [t containsString:@"nhan chuy"] ||
                 [t containsString:@"nhan don"] ||
                 [t containsString:@"nhandon"] ||
                 [t containsString:@"nhan ngay"] ||
                 [t containsString:@"nhanngay"] ||
                 [t containsString:@"chap nhan"] ||
                 [t containsString:@"chapnhan"])) {
                acceptBlock = b;
            }
        }
    }

    // Bottom button MUST explicitly read "Nhận chuyến" (never partial guess in micro-strip mode!)
    if (!acceptBlock) {
        return nil;
    }

    // Inspect Top Header Strip blocks (y = 20..92pt)
    CGFloat headerMaxY = cuocPhiBlock ? MAX(68.0, cuocPhiBlock.uiCenter.y - 10.0) : 92.0;
    NSMutableArray<OCRTextBlock *> *headerBlocks = [NSMutableArray array];
    NSInteger stripFare = 0;

    for (OCRTextBlock *b in stripBlocks) {
        if (b.uiCenter.y >= 20.0 && b.uiCenter.y <= headerMaxY && b.uiCenter.x < screenSize.width * 0.84) {
            [headerBlocks addObject:b];
        }
        if (b.uiCenter.y >= 22.0 && b.uiCenter.y <= topStripMaxUIY && b.uiCenter.x >= screenSize.width * 0.38) {
            NSInteger f = [self extractFareVNDFromString:b.rawText];
            if (f > stripFare) {
                stripFare = f;
            }
        }
    }

    [headerBlocks sortUsingComparator:^NSComparisonResult(OCRTextBlock *a, OCRTextBlock *b) {
        if (a.uiCenter.x < b.uiCenter.x) return NSOrderedAscending;
        if (a.uiCenter.x > b.uiCenter.x) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    NSMutableArray<NSString *> *headerNormParts = [NSMutableArray array];
    NSMutableArray<NSString *> *headerRawParts  = [NSMutableArray array];
    OCRTextBlock *foodAnchorBlk = nil;
    for (OCRTextBlock *hb in headerBlocks) {
        [headerNormParts addObject:hb.normText];
        [headerRawParts addObject:hb.rawText];
        if (!foodAnchorBlk && ([self headerNormMatchesFood:hb.normText] || [hb.normText containsString:@"green"])) {
            foodAnchorBlk = hb;
        }
    }
    if (!foodAnchorBlk) {
        foodAnchorBlk = headerBlocks.lastObject;
    }

    NSString *joinedHeaderNorm = [headerNormParts componentsJoinedByString:@" "];
    NSString *joinedHeaderRaw  = [headerRawParts componentsJoinedByString:@" "];
    BOOL isStripHeaderFood     = [self headerNormMatchesFood:joinedHeaderNorm];
    BOOL isStripHeaderNonFood  = (!isStripHeaderFood && [self headerNormMatchesNonFoodService:joinedHeaderNorm]);

    // Require positive top-card header evidence ("Green Food"/"Bike"/"Express" OR "Cước phí" + matching chromatic icon)
    if (freshOrder.isGreenFood) {
        if (isStripHeaderNonFood) return nil;
        if (!isStripHeaderFood && !(headerIconWarmFood && cuocPhiBlock != nil)) {
            return nil;
        }
    } else if (freshOrder.isBikeOrExpress) {
        if (isStripHeaderFood) return nil;
        if (!isStripHeaderNonFood && !(headerIconCoolRide && cuocPhiBlock != nil)) {
            return nil;
        }
    }

    // If top strip OCR also read a fare, verify it matches one of the payload's fee fields (totalPay, totalFee, or baseFee)
    if (stripFare >= 8000 && freshOrder.totalPayVND >= 8000) {
        if (stripFare != freshOrder.totalPayVND &&
            stripFare != freshOrder.totalFeeVND &&
            stripFare != freshOrder.baseFeeVND) {
            return nil;
        }
    }

    // All 5 Anti-Mis-Tap Locks PASSED! Construct ScreenAnalysis in ~15ms:
    ScreenAnalysis *res = [[ScreenAnalysis alloc] init];
    res.offlinePowerPoint      = CGPointMake(config.manualOfflineX, config.manualOfflineY);
    res.onlineStartPoint       = CGPointMake(config.manualOnlineX, config.manualOnlineY);
    res.hasOrderPopup          = YES;
    res.isGreenFood            = freshOrder.isGreenFood;
    res.sniffedOrderId         = freshOrder.orderId;
    res.priceVerifiedByPayload = YES;
    res.detectedPriceVND       = freshOrder.totalPayVND;
    res.detectedServiceTitle   = joinedHeaderRaw.length > 0 ? joinedHeaderRaw : (freshOrder.serviceDisplayName ?: @"");
    res.pickupTitle            = preEval.pickupTitle;
    res.pickupSubtitle         = preEval.pickupSubtitle;
    res.dropoffTitle           = preEval.dropoffTitle;
    res.dropoffSubtitle        = preEval.dropoffSubtitle;
    res.estimatedDistanceKm    = preEval.estimatedDistanceKm;
    res.orderFingerprint       = preEval.orderFingerprint;
    res.orderAction            = preEval.orderAction;
    res.orderReason            = [NSString stringWithFormat:@"[⚡SNIPE] %@", preEval.orderReason ?: @""];
    res.ocrBlockCount          = stripBlocks.count;

    NSMutableArray<NSString *> *previewArr = [NSMutableArray array];
    for (NSUInteger i = 0; i < MIN((NSUInteger)6, stripBlocks.count); i++) {
        [previewArr addObject:stripBlocks[i].rawText];
    }
    res.ocrSampleSummary = [previewArr componentsJoinedByString:@" | "];

    if (preEval.orderAction == OrderActionTapAccept) {
        res.orderTargetPoint = [self computeAcceptPointWithAcceptBlock:acceptBlock
                                                            screenSize:screenSize
                                                                config:config];
    } else if (preEval.orderAction == OrderActionTapRejectX) {
        res.orderTargetPoint = [self computeClosePointWithHeaderBlock:foodAnchorBlk
                                                         cuocPhiBlock:cuocPhiBlock
                                                           screenSize:screenSize
                                                               config:config];
    }

    return res;
}

- (ScreenAnalysis *)analyzeScreenImage:(CIImage *)ciImage
                            screenSize:(CGSize)screenSize
                                config:(FilterConfig *)config
                       priceRetryCount:(NSInteger)retryCount {
    return [self analyzeScreenImage:ciImage
                         screenSize:screenSize
                         yellowDotY:0.0
                   hasBottomTealBar:NO
                  hasTopWhiteHeader:NO
                 headerIconWarmFood:NO
                 headerIconCoolRide:NO
                hasLobbyPowerButton:NO
                             config:config
                    priceRetryCount:retryCount];
}

- (ScreenAnalysis *)analyzeScreenImage:(CIImage *)ciImage
                            screenSize:(CGSize)screenSize
                            yellowDotY:(double)yellowDotY
                                config:(FilterConfig *)config
                       priceRetryCount:(NSInteger)retryCount {
    return [self analyzeScreenImage:ciImage
                         screenSize:screenSize
                         yellowDotY:yellowDotY
                   hasBottomTealBar:NO
                  hasTopWhiteHeader:NO
                 headerIconWarmFood:NO
                 headerIconCoolRide:NO
                hasLobbyPowerButton:NO
                             config:config
                    priceRetryCount:retryCount];
}

- (ScreenAnalysis *)analyzeScreenImage:(CIImage *)ciImage
                            screenSize:(CGSize)screenSize
                            yellowDotY:(double)yellowDotY
                      hasBottomTealBar:(BOOL)hasBottomTealBar
                     hasTopWhiteHeader:(BOOL)hasTopWhiteHeader
                    headerIconWarmFood:(BOOL)headerIconWarmFood
                    headerIconCoolRide:(BOOL)headerIconCoolRide
                                config:(FilterConfig *)config
                       priceRetryCount:(NSInteger)retryCount {
    return [self analyzeScreenImage:ciImage
                         screenSize:screenSize
                         yellowDotY:yellowDotY
                   hasBottomTealBar:hasBottomTealBar
                  hasTopWhiteHeader:hasTopWhiteHeader
                 headerIconWarmFood:headerIconWarmFood
                 headerIconCoolRide:headerIconCoolRide
                hasLobbyPowerButton:NO
                             config:config
                    priceRetryCount:retryCount];
}

- (ScreenAnalysis *)analyzeScreenImage:(CIImage *)ciImage
                            screenSize:(CGSize)screenSize
                            yellowDotY:(double)yellowDotY
                      hasBottomTealBar:(BOOL)hasBottomTealBar
                     hasTopWhiteHeader:(BOOL)hasTopWhiteHeader
                    headerIconWarmFood:(BOOL)headerIconWarmFood
                    headerIconCoolRide:(BOOL)headerIconCoolRide
                   hasLobbyPowerButton:(BOOL)hasLobbyPowerButton
                                config:(FilterConfig *)config
                       priceRetryCount:(NSInteger)retryCount {
    ScreenAnalysis *res = [[ScreenAnalysis alloc] init];
    res.offlinePowerPoint = CGPointMake(config.manualOfflineX, config.manualOfflineY);
    res.onlineStartPoint  = CGPointMake(config.manualOnlineX, config.manualOnlineY);

    if (!ciImage) return res;

    // Fast Path (~15ms): Dual-Strip Micro-OCR + 5 Anti-Mis-Tap Locks when fresh payload is ready!
    // Automatically falls back to Full-Screen OCR below in the same cycle if any of the 5 locks fails.
    ScreenAnalysis *fastRes = [self tryFastMicroStripAnalysisOnImage:ciImage
                                                          screenSize:screenSize
                                                    hasBottomTealBar:hasBottomTealBar
                                                   hasTopWhiteHeader:hasTopWhiteHeader
                                                  headerIconWarmFood:headerIconWarmFood
                                                  headerIconCoolRide:headerIconCoolRide
                                                 hasLobbyPowerButton:hasLobbyPowerButton
                                                              config:config];
    if (fastRes) {
        return fastRes;
    }

    __block NSMutableArray<OCRTextBlock *> *blocks = [NSMutableArray array];

    @autoreleasepool {
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
                CGFloat centerY = uiY + uiH * 0.5;

                // Ignore top iOS Status Bar strip (y < 21pt on iPhone 8 375x667) so carrier/clock/StealthStatusPillHUD text is 100% invisible to OCR
                if (centerY < MAX(21.0, screenSize.height * 0.0315)) {
                    continue;
                }

                OCRTextBlock *blk = [[OCRTextBlock alloc] init];
                blk.rawText  = top.string;
                blk.normText = NormalizeVNText(top.string);
                blk.uiRect   = CGRectMake(uiX, uiY, uiW, uiH);
                blk.uiCenter = CGPointMake(uiX + uiW * 0.5, centerY);
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

        NSDictionary *vnOpts = _ciContext ? @{ VNImageOptionCIContext: _ciContext } : @{};
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCIImage:ciImage options:vnOpts];
        [handler performRequests:@[req] error:nil];
    }

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
    OCRTextBlock *rejectConfirmBlk   = nil;
    OCRTextBlock *kmSummaryBlk       = nil;

    BOOL hasPassengerRoute = NO; // 'điểm đến' hoặc 'Insurance' (đặc quyền của Bike chở người)
    BOOL hasDeliveryRoute  = NO; // 'điểm nhận' hoặc 'điểm giao' (chung cho cả Express & Food)
    BOOL hasPaymentTag     = NO; // 'Tiền mặt' hoặc 'Thẻ/Ví'
    BOOL hasAnyTripBottomBtn = NO; // 'Đã đến điểm...', 'Đã lấy hàng', 'Hoàn thành...' (Bike + Express + Food -> bảo vệ nối chuyến)
    BOOL hasTripActorLabel   = NO; // 'Hành khách', 'Người gửi', 'Người nhận', 'Khách hàng'
    BOOL hasDeliveryTripOnly = NO; // Dấu hiệu chuyến giao hàng Express / Express 2H / Food -> CHẶN bấm nút Điều hướng!
    BOOL hasNhanTinBtn     = NO;
    BOOL hasGoiDienBtn     = NO;
    BOOL hasBottomSheetTxt = NO; // 'Bạn đã lái xe liên tục', '0.0/8', '/8 tiếng', 'Trung tâm an toàn'...
    BOOL hasLobbyCardTxt   = NO; // 'Số dư ví', 'Green Now', 'Chuyến của tôi', 'Mua xe VinFast'

    // Build row-merged blocks so animated countdown bars splitting 'Nhận' | 'chuyến' (or '1 điểm' | 'đến') are ALWAYS joined cleanly!
    NSArray<OCRTextBlock *> *rowMergedBlocks = [self buildRowMergedBlocksFrom:blocks];
    NSMutableArray<OCRTextBlock *> *scanBlocks = [NSMutableArray arrayWithCapacity:(blocks.count + rowMergedBlocks.count)];
    [scanBlocks addObjectsFromArray:rowMergedBlocks]; // Check merged full phrases first so centerX/centerY spans the whole button!
    [scanBlocks addObjectsFromArray:blocks];

    CGFloat kmLineY = screenSize.height * 0.42;
    OCRTextBlock *bottomPartialAcceptBlk = nil;

    for (OCRTextBlock *b in scanBlocks) {
        NSString *t = b.normText;

        // Lobby & Payment markers
        if (!moNhanChuyenBlock && [t containsString:@"mo nhan chuyen"]) {
            if (b.uiCenter.y > screenSize.height * 0.25 && b.uiCenter.y < screenSize.height * 0.72) {
                moNhanChuyenBlock = b;
            }
        }
        if (!dangTrucTuyenBlk && b.uiCenter.y > screenSize.height * 0.55) {
            if ([t containsString:@"dang truc tuyen"]) {
                dangTrucTuyenBlk = b;
            }
        }
        if (!xacNhanHTBlk && b.uiCenter.y > screenSize.height * 0.70) {
            if ([t containsString:@"xac nhan hoan thanh"]) {
                xacNhanHTBlk = b;
            }
        }
        if (b.uiCenter.y > screenSize.height * 0.45) {
            if ([t containsString:@"so du vi"] ||
                [t containsString:@"green now"] ||
                [t containsString:@"chuyen cua toi"] ||
                [t containsString:@"mua xe vinfast"] ||
                [t containsString:@"diem den yeu thich"]) {
                hasLobbyCardTxt = YES;
            }
        }
        if (b.uiCenter.y > screenSize.height * 0.48) {
            if ([t containsString:@"lai xe lien tuc"] ||
                [t containsString:@"/8 tieng"] ||
                [t containsString:@"/ 8 tieng"] ||
                ([t containsString:@"tieng"] && [t containsString:@"phut"]) ||
                (b.uiCenter.y > screenSize.height * 0.55 && [b.rawText containsString:@"/8"] && b.rawText.length <= 12) ||
                [t containsString:@"trung tam an toan"] ||
                [t containsString:@"ho tro khan cap"] ||
                [t containsString:@"chia se hanh trinh"]) {
                hasBottomSheetTxt = YES;
            }
        }

        if (b.uiCenter.y > screenSize.height * 0.35 && b.uiCenter.y < screenSize.height * 0.85 &&
            t.length <= 22 &&
            ![b.rawText containsString:@"?"] &&
            ![t containsString:@"ban co"] &&
            ![t containsString:@"muon"] &&
            ![t containsString:@"hoan thanh"] &&
            ![t containsString:@"mo nhan"]) {
            if ([t isEqualToString:@"xac nhan"] ||
                [t isEqualToString:@"dong y"] ||
                [t isEqualToString:@"tat nhan chuyen"] ||
                [t isEqualToString:@"tat truc tuyen"] ||
                [t isEqualToString:@"ngung nhan chuyen"] ||
                [t isEqualToString:@"ngung truc tuyen"] ||
                [t isEqualToString:@"tam nghi"] ||
                [t hasPrefix:@"dong y "] ||
                [t hasPrefix:@"xac nhan "]) {
                if (!confirmOfflineBlk || b.uiCenter.y >= confirmOfflineBlk.uiCenter.y) {
                    confirmOfflineBlk = b;
                }
            }
        }

        if (b.uiCenter.y > screenSize.height * 0.38 && b.uiCenter.y < screenSize.height * 0.85 &&
            t.length <= 22 &&
            ![b.rawText containsString:@"?"] &&
            ![t containsString:@"ban co"] &&
            ![t containsString:@"muon"]) {
            if ([t isEqualToString:@"tu choi"] ||
                [t isEqualToString:@"xac nhan tu choi"] ||
                [t isEqualToString:@"xac nhan"] ||
                [t isEqualToString:@"dong y"]) {
                if (!rejectConfirmBlk || b.uiCenter.y >= rejectConfirmBlk.uiCenter.y) {
                    rejectConfirmBlk = b;
                }
            }
        }

        // Active Trip markers:
        // - Auto-Tap Blue 'Điều hướng' (hasPassengerAndNav) CHỈ kích hoạt cho chuyến Bike CHỞ KHÁCH ('Hành khách' + 'Đã đến điểm đón' / 'Hoàn thành chuyến', KHÔNG có nhãn giao hàng Express/Food)
        // - Bảo vệ nối chuyến (isAnyActiveTripScreen) vẫn nhận diện đủ cả Bike + Express + Express 2H + Food để không bao giờ tắt nhầm app khi đang chạy đơn!
        if (b.uiCenter.x < screenSize.width * 0.62 &&
            b.uiCenter.y > screenSize.height * 0.16 && b.uiCenter.y < screenSize.height * 0.78) {
            if ([t containsString:@"hanh khach"]) {
                if (!hanhKhachBlk) hanhKhachBlk = b;
                hasTripActorLabel = YES;
            } else if ([t containsString:@"nguoi gui"] ||
                       [t containsString:@"nguoi nhan"]) {
                hasTripActorLabel = YES;
                hasDeliveryTripOnly = YES;
            }
        }
        if (b.uiCenter.y > screenSize.height * 0.05 && b.uiCenter.y < screenSize.height * 0.96) {
            if ([t containsString:@"nguoi gui"] ||
                [t containsString:@"nguoi nhan"] ||
                [t containsString:@"diem giao hang"] ||
                [t containsString:@"diem nhan hang"] ||
                ([t containsString:@"diem giao"] && ([t containsString:@"mo rong"] || [t containsString:@"morong"])) ||
                ([t containsString:@"diem nhan"] && ([t containsString:@"mo rong"] || [t containsString:@"morong"])) ||
                [t containsString:@"da den diem nhan"] ||
                [t containsString:@"den diem nhan"] ||
                [t containsString:@"da den diem lay"] ||
                [t containsString:@"da lay hang"] ||
                [t containsString:@"bat dau giao"] ||
                [t containsString:@"da den diem giao"] ||
                [t containsString:@"den diem giao"] ||
                [t containsString:@"giao hang thanh cong"] ||
                [t containsString:@"xac nhan giao"] ||
                [t containsString:@"hoan thanh don"] ||
                [t containsString:@"da den quan"] ||
                [t containsString:@"da den nha hang"]) {
                hasDeliveryTripOnly = YES;
            }
        }
        if (!dieuHuongBlk && b.uiCenter.x > screenSize.width * 0.52 &&
            b.uiCenter.y > screenSize.height * 0.16 && b.uiCenter.y < screenSize.height * 0.80) {
            if ([t containsString:@"dieu huong"] || [t containsString:@"dieuhuong"]) {
                dieuHuongBlk = b;
            }
        }
        if (!daDenDiemDonBlk && b.uiCenter.y > screenSize.height * 0.72) {
            if ([t containsString:@"da den diem don"] ||
                [t containsString:@"den diem don"]) {
                daDenDiemDonBlk = b;
            }
        }
        if (!hoanThanhChuyenBlk && b.uiCenter.y > screenSize.height * 0.72) {
            if ([t containsString:@"hoan thanh chuyen"]) {
                hoanThanhChuyenBlk = b;
            }
        }
        if (b.uiCenter.y > screenSize.height * 0.72) {
            if ([t containsString:@"da den diem"] ||
                [t containsString:@"da den quan"] ||
                [t containsString:@"da den nha hang"] ||
                [t containsString:@"don khach"] ||
                [t containsString:@"bat dau chuyen"] ||
                [t containsString:@"da lay hang"] ||
                [t containsString:@"bat dau giao"] ||
                [t containsString:@"hoan thanh chuyen"] ||
                [t containsString:@"hoan thanh don"] ||
                [t containsString:@"giao hang thanh cong"] ||
                [t containsString:@"xac nhan giao"] ||
                [t containsString:@"chup anh"] ||
                [t containsString:@"cap nhat"] ||
                [t containsString:@"lien he"] ||
                [t containsString:@"huy don"] ||
                [t containsString:@"huy chuyen"]) {
                hasAnyTripBottomBtn = YES;
            }
        }
        if (b.uiCenter.y > screenSize.height * 0.60) {
            if ([t containsString:@"nhan tin"]) hasNhanTinBtn = YES;
            if ([t containsString:@"goi dien"]) hasGoiDienBtn = YES;
        }

        // Order Popup core markers
        if (!cuocPhiBlock && b.uiCenter.y < screenSize.height * 0.48) {
            if ([t containsString:@"cuoc phi"] || [t containsString:@"cuocphi"]) {
                cuocPhiBlock = b;
            }
        }
        if (!acceptBlock && b.uiCenter.y > screenSize.height * 0.82) {
            BOOL isNotLobbyOrStop = (![t containsString:@"mo nhan"] &&
                                     ![t containsString:@"tat nhan"] &&
                                     ![t containsString:@"ngung nhan"] &&
                                     ![t containsString:@"da nhan"] &&
                                     ![t containsString:@"xac nhan"] &&
                                     ![t containsString:@"nhan hang"] &&
                                     ![t containsString:@"diem nhan"] &&
                                     ![t containsString:@"da den"] &&
                                     ![t containsString:@"bat dau"] &&
                                     ![t containsString:@"giao hang"] &&
                                     ![t containsString:@"lay hang"] &&
                                     ![t containsString:@"huy chuyen"] &&
                                     ![t containsString:@"hoan thanh"] &&
                                     ![t containsString:@"chuyen cua toi"]);
            if (isNotLobbyOrStop &&
                ([t containsString:@"nhan chuyen"] ||
                 [t containsString:@"nhanchuyen"] ||
                 [t containsString:@"nhan chuven"] ||
                 [t containsString:@"nhan chuy"] ||
                 [t containsString:@"nhan don"] ||
                 [t containsString:@"nhandon"] ||
                 [t containsString:@"nhan ngay"] ||
                 [t containsString:@"nhanngay"] ||
                 [t containsString:@"chap nhan"] ||
                 [t containsString:@"chapnhan"])) {
                acceptBlock = b;
            } else if (!bottomPartialAcceptBlk &&
                       isNotLobbyOrStop &&
                       b.uiCenter.y > screenSize.height * 0.88 &&
                       b.uiCenter.x > screenSize.width * 0.25 &&
                       b.uiCenter.x < screenSize.width * 0.75 &&
                       ([t isEqualToString:@"nhan"] ||
                        [t hasPrefix:@"nhan "] ||
                        [t isEqualToString:@"chuyen"] ||
                        [t hasPrefix:@"chuyen ("])) {
                bottomPartialAcceptBlk = b;
            }
        }

        // Route & payment body markers (y < 0.68 * H so surge/bonus banners or chained sheets never push markers out of bounds!)
        if (b.uiCenter.y > 55.0 && b.uiCenter.y < screenSize.height * 0.68) {
            if ([t containsString:@"diem den"] ||
                [t containsString:@"diemden"] ||
                [t containsString:@"diem don"] ||
                [t containsString:@"diemdon"] ||
                [t containsString:@"insurance"] ||
                [t containsString:@"bao hiem"]) {
                hasPassengerRoute = YES;
            }
            if ([t containsString:@"diem nhan"] ||
                [t containsString:@"diemnhan"] ||
                [t containsString:@"diem giao"] ||
                [t containsString:@"diemgiao"]) {
                hasDeliveryRoute = YES;
            }
            if ([t containsString:@"tien mat"] || [t containsString:@"the/vi"] || [t containsString:@"the / vi"]) {
                hasPaymentTag = YES;
            }
            if ([t containsString:@"km"] && ([t containsString:@"diem"] || [t containsString:@"1 "])) {
                if (!kmSummaryBlk) {
                    kmLineY = b.uiCenter.y;
                    kmSummaryBlk = b;
                }
            }
        }
    }

    // If countdown sweep split 'Nhận' | 'chuyến (5)' and only half was recognized on an actual Order Popup
    // (STRICTLY guarded against active delivery/passenger trip screens — NEVER synthesize a fake acceptBlock without OCR text!):
    if (!acceptBlock &&
        bottomPartialAcceptBlk != nil &&
        !daDenDiemDonBlk &&
        !hoanThanhChuyenBlk &&
        !hasAnyTripBottomBtn &&
        !hasDeliveryTripOnly &&
        !hasTripActorLabel &&
        !hanhKhachBlk &&
        !dieuHuongBlk &&
        !moNhanChuyenBlock &&
        !dangTrucTuyenBlk &&
        !hasLobbyCardTxt &&
        !(hasNhanTinBtn && hasGoiDienBtn) &&
        cuocPhiBlock != nil &&
        (hasPassengerRoute || hasDeliveryRoute || hasPaymentTag)) {
        acceptBlock = bottomPartialAcceptBlk;
    }

    // 2. Populate Active Trip state first so Lobby check never conflicts with an Active Trip (chained-order safety!)
    res.isAnyActiveTripScreen = (!acceptBlock &&
                                 (hanhKhachBlk != nil ||
                                  dieuHuongBlk != nil ||
                                  daDenDiemDonBlk != nil ||
                                  hoanThanhChuyenBlk != nil ||
                                  hasTripActorLabel ||
                                  hasDeliveryTripOnly ||
                                  hasAnyTripBottomBtn ||
                                  (hasNhanTinBtn && hasGoiDienBtn)));

    // 3. Populate Lobby & Payment states (strictly guarded against active trip / order popup)
    res.isLobbyOnline          = (dangTrucTuyenBlk != nil && !res.isAnyActiveTripScreen && !acceptBlock);
    res.isLobbyOffline         = (moNhanChuyenBlock != nil && !res.isAnyActiveTripScreen && !acceptBlock);
    res.isPaymentConfirmScreen = (xacNhanHTBlk != nil);

    if (moNhanChuyenBlock && config.coordMode == CoordModeAutoOCRWithOffset) {
        res.onlineStartPoint = CGPointMake(moNhanChuyenBlock.uiCenter.x + config.onlineOffsetX,
                                           moNhanChuyenBlock.uiCenter.y + config.onlineOffsetY);
    }
    if (confirmOfflineBlk) {
        res.hasOfflineConfirmPopup = YES;
        res.confirmPopupPoint = confirmOfflineBlk.uiCenter;
    }
    if (rejectConfirmBlk) {
        res.hasRejectConfirmPopup = YES;
        res.rejectConfirmPoint = rejectConfirmBlk.uiCenter;
    }
    res.hasBlockingBottomSheet = (hasBottomSheetTxt &&
                                  !acceptBlock &&
                                  !res.isAnyActiveTripScreen &&
                                  !res.isPaymentConfirmScreen &&
                                  !res.hasOfflineConfirmPopup &&
                                  !res.hasRejectConfirmPopup);
    res.hasAnyLobbyMarker = (res.isLobbyOnline ||
                             res.isLobbyOffline ||
                             res.hasBlockingBottomSheet ||
                             (!acceptBlock && hasLobbyCardTxt));

    // 4. Inspect Service Header Bar ROI (adaptive window strictly above 'Cước phí' so mid-sheet / bonus cards work cleanly)
    CGFloat headerMinY = cuocPhiBlock
        ? MAX(20.0, cuocPhiBlock.uiCenter.y - 92.0)
        : 20.0;
    CGFloat headerMaxY = cuocPhiBlock
        ? MAX(68.0, cuocPhiBlock.uiCenter.y - 10.0)
        : (screenSize.height * 0.21);

    NSMutableArray<OCRTextBlock *> *headerBlocks = [NSMutableArray array];
    for (OCRTextBlock *b in blocks) {
        // Exclude top iOS status bar (y < 20pt: 'Google Maps 4G 11:29') and far-right [X] button
        if (b.uiCenter.y >= headerMinY && b.uiCenter.y <= headerMaxY && b.uiCenter.x < screenSize.width * 0.84) {
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
    OCRTextBlock *foodAnchorBlk = nil;
    for (OCRTextBlock *hb in headerBlocks) {
        [headerNormParts addObject:hb.normText];
        [headerRawParts addObject:hb.rawText];
        if (!foodAnchorBlk && ([self headerNormMatchesFood:hb.normText] || [hb.normText containsString:@"green"])) {
            foodAnchorBlk = hb;
        }
    }
    if (!foodAnchorBlk) {
        foodAnchorBlk = headerBlocks.lastObject;
    }
    NSString *joinedHeaderNorm = [headerNormParts componentsJoinedByString:@" "];
    NSString *joinedHeaderRaw  = [headerRawParts componentsJoinedByString:@" "];

    BOOL isHeaderFood    = [self headerNormMatchesFood:joinedHeaderNorm];
    BOOL isHeaderNonFood = (!isHeaderFood && [self headerNormMatchesNonFoodService:joinedHeaderNorm]);

    // Fuse top-left service icon color sensor when header bar is uncovered at y~52pt:
    if (!isHeaderFood && !isHeaderNonFood && hasTopWhiteHeader) {
        if (headerIconWarmFood && !hasPassengerRoute) {
            isHeaderFood = YES;
        } else if (headerIconCoolRide) {
            isHeaderNonFood = YES;
        }
    }

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

        // Extract Pickup (Black ◉) & Dropoff (Yellow ◉) text lines cleanly
        CGFloat routeTopY = kmSummaryBlk
            ? (CGRectGetMaxY(kmSummaryBlk.uiRect) + 8.0)
            : MAX(195.0, maxFareY + 18.0);
        CGFloat routeBotY = CGRectGetMinY(acceptBlock.uiRect) - 18.0;

        NSMutableArray<OCRTextBlock *> *rawRouteBlocks = [NSMutableArray array];
        for (OCRTextBlock *b in blocks) {
            if (b.uiCenter.y < routeTopY || b.uiCenter.y > routeBotY) continue;
            if (CGRectGetMaxX(b.uiRect) < 52.0) continue; // Ignore standalone ◉ ring OCR noise at x~26pt
            NSString *nt = b.normText;
            if ([nt isEqualToString:@"insurance"] ||
                [nt isEqualToString:@"tien mat"] ||
                [nt isEqualToString:@"the/vi"] ||
                [nt isEqualToString:@"the / vi"]) {
                continue;
            }
            if ([nt containsString:@"km"] && [nt containsString:@"diem"]) continue;
            [rawRouteBlocks addObject:b];
        }

        [rawRouteBlocks sortUsingComparator:^NSComparisonResult(OCRTextBlock *a, OCRTextBlock *b) {
            if (fabs(a.uiCenter.y - b.uiCenter.y) <= 6.5) {
                if (a.uiRect.origin.x < b.uiRect.origin.x) return NSOrderedAscending;
                if (a.uiRect.origin.x > b.uiRect.origin.x) return NSOrderedDescending;
                return NSOrderedSame;
            }
            return (a.uiCenter.y < b.uiCenter.y) ? NSOrderedAscending : NSOrderedDescending;
        }];

        // Merge horizontal segments on the same visual text row (|ΔcenterY| <= 6.5pt)
        NSMutableArray<OCRMergedRouteLine *> *mergedLines = [NSMutableArray array];
        for (OCRTextBlock *b in rawRouteBlocks) {
            OCRMergedRouteLine *lastLn = mergedLines.lastObject;
            if (lastLn && fabs(b.uiCenter.y - lastLn.centerY) <= 6.5) {
                lastLn.rawText  = [NSString stringWithFormat:@"%@ %@", lastLn.rawText, b.rawText];
                lastLn.normText = [NSString stringWithFormat:@"%@ %@", lastLn.normText, b.normText];
                lastLn.minY     = MIN(lastLn.minY, CGRectGetMinY(b.uiRect));
                lastLn.maxY     = MAX(lastLn.maxY, CGRectGetMaxY(b.uiRect));
                lastLn.centerY  = (lastLn.minY + lastLn.maxY) * 0.5;
            } else {
                OCRMergedRouteLine *ln = [[OCRMergedRouteLine alloc] init];
                ln.rawText  = b.rawText ?: @"";
                ln.normText = b.normText ?: @"";
                ln.minY     = CGRectGetMinY(b.uiRect);
                ln.maxY     = CGRectGetMaxY(b.uiRect);
                ln.centerY  = b.uiCenter.y;
                [mergedLines addObject:ln];
            }
        }

        NSMutableArray<OCRMergedRouteLine *> *pickupLines  = [NSMutableArray array];
        NSMutableArray<OCRMergedRouteLine *> *dropoffLines = [NSMutableArray array];

        if (yellowDotY > routeTopY + 12.0 && yellowDotY < routeBotY) {
            CGFloat splitY = (CGFloat)yellowDotY - 14.0;
            for (OCRMergedRouteLine *ln in mergedLines) {
                if (ln.centerY < splitY) {
                    [pickupLines addObject:ln];
                } else {
                    [dropoffLines addObject:ln];
                }
            }
        }

        // Fallback split by largest vertical inter-stop gap (~27pt vs <=15pt) if yellow ring was outside/uncaptured
        if ((pickupLines.count == 0 || dropoffLines.count == 0) && mergedLines.count >= 2) {
            CGFloat bestGap = -1.0;
            NSUInteger bestIdx = NSNotFound;
            for (NSUInteger i = 1; i < mergedLines.count; i++) {
                CGFloat g = mergedLines[i].minY - mergedLines[i - 1].maxY;
                if (g > bestGap) {
                    bestGap = g;
                    bestIdx = i;
                }
            }
            if (bestIdx != NSNotFound && bestGap >= 16.0) {
                [pickupLines removeAllObjects];
                [dropoffLines removeAllObjects];
                for (NSUInteger i = 0; i < mergedLines.count; i++) {
                    if (i < bestIdx) [pickupLines addObject:mergedLines[i]];
                    else [dropoffLines addObject:mergedLines[i]];
                }
            } else if (pickupLines.count == 0 && dropoffLines.count > 0) {
                // Only one block present -> treat as pickup
                [pickupLines addObjectsFromArray:dropoffLines];
                [dropoffLines removeAllObjects];
            }
        }

        NSString *pTit = @"", *pSub = @"", *dTit = @"", *dSub = @"";
        [self splitStopLines:pickupLines outTitle:&pTit outSubtitle:&pSub];
        [self splitStopLines:dropoffLines outTitle:&dTit outSubtitle:&dSub];
        res.pickupTitle     = pTit;
        res.pickupSubtitle  = pSub;
        res.dropoffTitle    = dTit;
        res.dropoffSubtitle = dSub;

        // Fuse live GSMOrderPayloadSniffer (3-Lock verified against visible OCR text):
        // - Unmasks banner-covered headers (Bike/Express vs Green Food) in 0ms
        // - Restores 100% untruncated Pickup/Dropoff addresses (no "..." cutoff)
        // - Provides exact digital VND fare & GPS coordinates
        NSString *ocrPickupCombined = (pTit.length > 0 && pSub.length > 0 && ![pTit isEqualToString:pSub])
            ? [NSString stringWithFormat:@"%@ %@", pTit, pSub]
            : (pTit.length > 0 ? pTit : pSub);
        NSString *ocrDropoffCombined = (dTit.length > 0 && dSub.length > 0 && ![dTit isEqualToString:dSub])
            ? [NSString stringWithFormat:@"%@ %@", dTit, dSub]
            : (dTit.length > 0 ? dTit : dSub);

        BOOL isConfirmedBikeByBodyPre = (hasPassengerRoute && !hasDeliveryRoute);
        GSMSniffedOrder *sniffed = [[GSMOrderPayloadSniffer sharedSniffer]
            sniffActiveOrderWithConfig:config
                           ocrPriceVND:detectedFare
                       isOCRHeaderFood:isHeaderFood
                    isOCRHeaderNonFood:(isHeaderNonFood || isConfirmedBikeByBodyPre)
                            pickupText:ocrPickupCombined
                           dropoffText:ocrDropoffCombined];

        // If top header bar (y ~ 52pt where [X] lives) is covered by an iOS notification banner,
        // neither the white header pixel sensor (hasTopWhiteHeader) nor the 'Green Food' header text anchor (foodAnchorBlk) is visible!
        BOOL headerWasCoveredByBanner = (!hasTopWhiteHeader && foodAnchorBlk == nil);

        if (sniffed) {
            res.sniffedOrderId = sniffed.orderId;
            if (!isHeaderFood && !isHeaderNonFood) {
                if (sniffed.isGreenFood) {
                    isHeaderFood = YES;
                } else if (sniffed.isBikeOrExpress) {
                    isHeaderNonFood = YES;
                }
            }
            if (res.detectedServiceTitle.length == 0 && sniffed.serviceDisplayName.length > 0) {
                res.detectedServiceTitle = sniffed.serviceDisplayName;
                joinedHeaderRaw          = sniffed.serviceDisplayName;
            }
            if (sniffed.totalPayVND >= 5000) {
                detectedFare               = sniffed.totalPayVND;
                res.detectedPriceVND       = detectedFare;
                res.priceVerifiedByPayload = YES;
            }
            if (sniffed.pickupShortAddress.length > 0 || sniffed.pickupName.length > 0) {
                NSString *sName  = sniffed.pickupName ?: @"";
                NSString *sShort = sniffed.pickupShortAddress ?: @"";
                pTit = (sName.length > 0 && sShort.length > 0 && ![sShort.lowercaseString containsString:sName.lowercaseString])
                    ? [NSString stringWithFormat:@"%@ - %@", sName, sShort]
                    : (sShort.length > 0 ? sShort : sName);
                res.pickupTitle = pTit;
            }
            if (sniffed.pickupFullAddress.length > 0) {
                pSub = sniffed.pickupFullAddress;
                res.pickupSubtitle = pSub;
            }
            if (sniffed.dropoffShortAddress.length > 0) {
                dTit = sniffed.dropoffShortAddress;
                res.dropoffTitle = dTit;
            }
            if (sniffed.dropoffFullAddress.length > 0) {
                dSub = sniffed.dropoffFullAddress;
                res.dropoffSubtitle = dSub;
            }
        }

        // If top header text was covered by a persistent banner even after swipe, check if Pickup Title is clearly a Food restaurant:
        if (!isHeaderFood && !isHeaderNonFood && !hasPassengerRoute && retryCount >= 3) {
            NSString *normPickCheck = NormalizeVNText(pTit ?: @"");
            if (normPickCheck.length >= 4 && _foodPickupHintRegex &&
                [_foodPickupHintRegex firstMatchInString:normPickCheck options:0 range:NSMakeRange(0, normPickCheck.length)] != nil) {
                isHeaderFood = YES;
            } else if (hasTopWhiteHeader && !headerIconWarmFood) {
                // Header bar at y=52pt is 100% uncovered white (no banner!), icon is NOT warm food, and title is NOT Food -> new non-food service!
                isHeaderNonFood = YES;
            }
        }

        // --- BRANCH A: CONFIRMED GREEN FOOD (2-Gate Hanoi Filter: TTTM/Chain Blacklist + Price OR >3km) ---
        if (isHeaderFood) {
            res.isGreenFood = YES;
            NSString *baseFp = [self buildOrderFingerprintForFood:YES
                                                         priceVND:detectedFare
                                                      pickupTitle:(pTit.length > 0 ? pTit : pSub)
                                                     dropoffTitle:(dTit.length > 0 ? dTit : dSub)];
            res.orderFingerprint = (sniffed.orderId.length == 26)
                ? [NSString stringWithFormat:@"%@_%@", baseFp, sniffed.orderId]
                : baseFp;

            if (config.rejectAllFood) {
                if (headerWasCoveredByBanner && retryCount < 4) {
                    res.orderAction = OrderActionHeaderCovered;
                    res.orderReason = @"Green Food cần bấm [X] nhưng Banner đang che góc trên -> Vuốt hất Banner trước...";
                    return res;
                }
                res.orderAction = OrderActionTapRejectX;
                res.orderTargetPoint = [self computeClosePointWithHeaderBlock:foodAnchorBlk
                                                                 cuocPhiBlock:cuocPhiBlock
                                                                   screenSize:screenSize
                                                                       config:config];
                res.orderReason = @"Green Food (Chế độ Hủy sạch Food) -> BẤM [X]";
                return res;
            }

            if (detectedFare <= 0) {
                if (retryCount < 6) {
                    res.orderAction = OrderActionWaitRetryPrice;
                    res.orderReason = @"Đang chờ load giá đơn Green Food (Chống lag 4G)...";
                    return res;
                } else {
                    if (headerWasCoveredByBanner && retryCount < 4) {
                        res.orderAction = OrderActionHeaderCovered;
                        res.orderReason = @"Green Food cần bấm [X] nhưng Banner đang che góc trên -> Vuốt hất Banner trước...";
                        return res;
                    }
                    res.orderAction = OrderActionTapRejectX;
                    res.orderTargetPoint = [self computeClosePointWithHeaderBlock:foodAnchorBlk
                                                                     cuocPhiBlock:cuocPhiBlock
                                                                       screenSize:screenSize
                                                                           config:config];
                    res.orderReason = @"Green Food (Không rõ giá sau 6 nhịp) -> HỦY [X]";
                    return res;
                }
            }

            FoodFilterEvaluation *eval = [[HanoiFoodFilterEngine sharedEngine] evaluateGreenFoodWithFare:detectedFare
                                                                                             pickupTitle:pTit
                                                                                          pickupSubtitle:pSub
                                                                                            dropoffTitle:dTit
                                                                                         dropoffSubtitle:dSub
                                                                                            sniffedOrder:sniffed
                                                                                                  config:config
                                                                                              retryCount:retryCount];
            res.estimatedDistanceKm = eval.estimatedDistanceKm;

            if (eval.decision == FoodFilterDecisionWaitTextLoading) {
                res.orderAction = OrderActionWaitRetryPrice;
                res.orderReason = eval.reasonSummary ?: @"Đang chờ load địa chỉ Green Food...";
                return res;
            }

            if (eval.decision == FoodFilterDecisionAccept) {
                // Bottom [Nhận chuyến] button (y ~ 640pt) is NEVER covered by a top banner -> tap immediately!
                res.orderAction = OrderActionTapAccept;
                res.orderTargetPoint = [self computeAcceptPointWithAcceptBlock:acceptBlock
                                                                    screenSize:screenSize
                                                                        config:config];
                res.orderReason = eval.reasonSummary;
            } else {
                // Top-right [X] button (y ~ 52pt): if a notification banner is covering the top header bar, swipe it away first!
                if (headerWasCoveredByBanner && retryCount < 4) {
                    res.orderAction = OrderActionHeaderCovered;
                    res.orderReason = [NSString stringWithFormat:@"%@ (Banner đang che nút [X] -> Vuốt hất Banner trước!)",
                                       eval.reasonSummary ?: @"Hủy Food"];
                    return res;
                }
                res.orderAction = OrderActionTapRejectX;
                res.orderTargetPoint = [self computeClosePointWithHeaderBlock:foodAnchorBlk
                                                                 cuocPhiBlock:cuocPhiBlock
                                                                   screenSize:screenSize
                                                                       config:config];
                res.orderReason = eval.reasonSummary;
            }
            return res;
        }

        // --- BRANCH B: CONFIRMED BIKE / EXPRESS / EXPRESS 2H ---
        // Confirmed if header/payload explicitly names Bike/Express/2H/etc., OR if passenger-only route ('điểm đến' / 'Insurance') is visible
        BOOL isConfirmedBikeByBody = (hasPassengerRoute && !hasDeliveryRoute);
        if (isHeaderNonFood || isConfirmedBikeByBody) {
            res.isGreenFood = NO;
            NSString *baseFp = [self buildOrderFingerprintForFood:NO
                                                         priceVND:detectedFare
                                                      pickupTitle:(pTit.length > 0 ? pTit : pSub)
                                                     dropoffTitle:(dTit.length > 0 ? dTit : dSub)];
            res.orderFingerprint = (sniffed.orderId.length == 26)
                ? [NSString stringWithFormat:@"%@_%@", baseFp, sniffed.orderId]
                : baseFp;
            NSString *svcLabel = joinedHeaderRaw.length > 0
                ? joinedHeaderRaw
                : (isConfirmedBikeByBody ? @"Green Bike" : @"Bike/Express");

            // Check Express Blocked Delivery Note ("TX đến Nhà Thuốc Long Châu") ONLY in JSON note fields!
            if (config.expressBlockLongChau) {
                NSString *blockedNoteKw = [self matchedBlockedExpressNoteInSniffedOrder:sniffed config:config];
                if (blockedNoteKw.length > 0) {
                    if (headerWasCoveredByBanner && retryCount < 4) {
                        res.orderAction = OrderActionHeaderCovered;
                        res.orderReason = [NSString stringWithFormat:@"%@ dính ghi chú cấm ('%@') nhưng Banner đang che nút [X] -> Vuốt hất Banner trước...",
                                           svcLabel, blockedNoteKw];
                        return res;
                    }
                    res.orderAction = OrderActionTapRejectX;
                    res.orderTargetPoint = [self computeClosePointWithHeaderBlock:foodAnchorBlk
                                                                     cuocPhiBlock:cuocPhiBlock
                                                                       screenSize:screenSize
                                                                           config:config];
                    res.orderReason = (detectedFare > 0)
                        ? [NSString stringWithFormat:@"%@ (%ldđ - Ghi chú cấm: '%@') -> BẤM [X]", svcLabel, (long)detectedFare, blockedNoteKw]
                        : [NSString stringWithFormat:@"%@ (Ghi chú cấm: '%@') -> BẤM [X]", svcLabel, blockedNoteKw];
                    return res;
                }

                // If this is an Express / Delivery popup (NOT passenger Bike) and JSON payload hasn't flushed at frame 0-1,
                // wait up to 2 fast ticks (~220ms) so Cache.db-wal / fsCachedData can confirm address_note before tapping [Nhận]!
                BOOL isExpressDeliveryOnScreen = (!isConfirmedBikeByBody &&
                                                  (hasDeliveryRoute ||
                                                   [joinedHeaderNorm containsString:@"express"] ||
                                                   [joinedHeaderNorm containsString:@"expres"] ||
                                                   [joinedHeaderNorm containsString:@"expre"] ||
                                                   [joinedHeaderNorm containsString:@"giao hang"] ||
                                                   [joinedHeaderNorm containsString:@"giaohang"] ||
                                                   [joinedHeaderNorm containsString:@"gui hang"] ||
                                                   [joinedHeaderNorm containsString:@"guihang"] ||
                                                   [joinedHeaderNorm containsString:@"sieu toc"] ||
                                                   [joinedHeaderNorm containsString:@"sieutoc"] ||
                                                   [joinedHeaderNorm containsString:@"2h"] ||
                                                   [joinedHeaderNorm containsString:@"4h"] ||
                                                   [joinedHeaderNorm containsString:@"don ghep"] ||
                                                   [joinedHeaderNorm containsString:@"donghep"] ||
                                                   [joinedHeaderNorm containsString:@"chuyen ghep"] ||
                                                   [joinedHeaderNorm containsString:@"dong gia"]));
                if (!sniffed && isExpressDeliveryOnScreen && retryCount < 2) {
                    res.orderAction = OrderActionWaitRetryPrice;
                    res.orderReason = @"Đang đọc ghi chú ngầm đơn Express (Kiểm tra 'TX đến Nhà Thuốc Long Châu')...";
                    return res;
                }
            }

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
