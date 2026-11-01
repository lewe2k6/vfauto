#ifndef HanoiFoodFilterEngine_h
#define HanoiFoodFilterEngine_h

#import <Foundation/Foundation.h>
#import "SharedConfig.h"

typedef NS_ENUM(NSInteger, FoodFilterDecisionType) {
    FoodFilterDecisionWaitTextLoading = 0, // Weak-4G skeleton card: text not rendered yet
    FoodFilterDecisionAccept          = 1, // Clean shop AND (Price >= min OR Distance > threshold)
    FoodFilterDecisionRejectHard      = 2, // Gate 1: Mall / Basement / Crowded Chain / High Order Count
    FoodFilterDecisionRejectLowShort  = 3  // Gate 2: Clean shop, Price < min AND Distance <= threshold
};

@interface FoodFilterEvaluation : NSObject
@property (nonatomic, assign) FoodFilterDecisionType decision;
@property (nonatomic, assign) double estimatedDistanceKm;   // > 0 if distance was evaluated
@property (nonatomic, copy)   NSString *distanceSourceTag;  // "Valhalla", "OSRM", "OfflineDB", "FastAir"
@property (nonatomic, copy)   NSString *matchedMerchantName;
@property (nonatomic, assign) NSInteger matchedOrderCount;
@property (nonatomic, copy)   NSString *reasonSummary;
@end

@interface HanoiFoodFilterEngine : NSObject

@property (nonatomic, readonly) NSInteger loadedMerchantCount;
@property (nonatomic, readonly) NSInteger loadedStreetPinCount;
@property (nonatomic, readonly) BOOL isIndexReady;

+ (instancetype)sharedEngine;

- (FoodFilterEvaluation *)evaluateGreenFoodWithFare:(NSInteger)detectedFareVND
                                        pickupTitle:(NSString *)pickupTitle
                                     pickupSubtitle:(NSString *)pickupSubtitle
                                       dropoffTitle:(NSString *)dropoffTitle
                                    dropoffSubtitle:(NSString *)dropoffSubtitle
                                             config:(FilterConfig *)config
                                         retryCount:(NSInteger)retryCount;

@end

#endif /* HanoiFoodFilterEngine_h */
