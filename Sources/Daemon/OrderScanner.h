#ifndef OrderScanner_h
#define OrderScanner_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreImage/CoreImage.h>
#import "SharedConfig.h"

typedef NS_ENUM(NSInteger, OrderActionType) {
    OrderActionNone           = 0,
    OrderActionWaitRetryPrice = 1,
    OrderActionHeaderCovered  = 2,
    OrderActionSkipDisabled   = 3,
    OrderActionTapAccept      = 4,
    OrderActionTapRejectX     = 5
};

@interface ScreenAnalysis : NSObject

// 1. Order Popup State
@property (nonatomic, assign) BOOL hasOrderPopup;
@property (nonatomic, assign) OrderActionType orderAction;
@property (nonatomic, assign) BOOL isGreenFood;
@property (nonatomic, copy)   NSString *detectedServiceTitle;
@property (nonatomic, assign) NSInteger detectedPriceVND;
@property (nonatomic, assign) CGPoint orderTargetPoint;
@property (nonatomic, copy)   NSString *orderReason;

// 2. Lobby & Payment States
@property (nonatomic, assign) BOOL isLobbyOnline;          // 'Đang trực tuyến'
@property (nonatomic, assign) BOOL isLobbyOffline;         // 'Mở nhận chuyến'
@property (nonatomic, assign) BOOL isPaymentConfirmScreen; // 'Xác nhận hoàn thành'
@property (nonatomic, assign) BOOL hasOfflineConfirmPopup; // Hộp thoại hỏi xác nhận tắt trực tuyến
@property (nonatomic, assign) BOOL hasRejectConfirmPopup;  // Hộp thoại hỏi xác nhận từ chối chuyến (nếu có)

@property (nonatomic, assign) CGPoint offlinePowerPoint;   // (40, 455)
@property (nonatomic, assign) CGPoint onlineStartPoint;    // (187, 307) hoặc tâm chữ 'Mở nhận chuyến'
@property (nonatomic, assign) CGPoint confirmPopupPoint;
@property (nonatomic, assign) CGPoint rejectConfirmPoint;

// 3. Active Trip Navigation States
@property (nonatomic, assign) BOOL hasPassengerAndNav;     // Thấy cả 'Hành khách' + 'Điều hướng'
@property (nonatomic, assign) BOOL isPickupStage;          // Nút đáy 'Đã đến điểm đón'
@property (nonatomic, assign) BOOL isDropoffStage;         // Nút đáy 'Hoàn thành chuyến'
@property (nonatomic, assign) CGPoint navBluePoint;        // Nút tròn xanh dương [Map] (323, 278)

// 4. Live Diagnostic Info
@property (nonatomic, assign) NSInteger ocrBlockCount;
@property (nonatomic, copy)   NSString *ocrSampleSummary;

@end

@interface OrderScanner : NSObject

+ (instancetype)sharedScanner;

- (ScreenAnalysis *)analyzeScreenImage:(CIImage *)ciImage
                            screenSize:(CGSize)screenSize
                                config:(FilterConfig *)config
                       priceRetryCount:(NSInteger)retryCount;

@end

#endif /* OrderScanner_h */
