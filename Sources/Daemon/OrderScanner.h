#ifndef OrderScanner_h
#define OrderScanner_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreImage/CoreImage.h>
#import "SharedConfig.h"

typedef NS_ENUM(NSInteger, ScanDecisionType) {
    ScanDecisionNone            = 0, // Không có bảng nổ đơn trên màn hình
    ScanDecisionWaitRetryPrice  = 1, // Thấy Green Food nhưng số tiền đang nhòe, chờ quét lại 1 nhịp
    ScanDecisionSkipDisabled    = 2, // Có đơn Bike nhưng công tắc Tự nhận Bike đang TẮT
    ScanDecisionTapAccept       = 3, // Bấm [Nhận chuyến] (Bike hoặc Green Food >= giá tối thiểu)
    ScanDecisionTapRejectX      = 4  // Bấm [X] (Green Food < giá tối thiểu hoặc chế độ hủy mọi Food)
};

@interface ScanDecision : NSObject
@property (nonatomic, assign) ScanDecisionType type;
@property (nonatomic, assign) BOOL isGreenFood;
@property (nonatomic, assign) NSInteger detectedPriceVND; // 0 nếu chưa đọc / không cần đọc
@property (nonatomic, assign) CGPoint targetLogicalPoint; // Tọa độ mục tiêu trước khi cộng Jitter
@property (nonatomic, copy)   NSString *reasonSummary;
@end

@interface OrderScanner : NSObject

+ (instancetype)sharedScanner;

- (ScanDecision *)analyzeScreenImage:(CIImage *)ciImage
                          screenSize:(CGSize)screenSize
                              config:(FilterConfig *)config
                     priceRetryCount:(NSInteger)retryCount;

@end

#endif /* OrderScanner_h */
