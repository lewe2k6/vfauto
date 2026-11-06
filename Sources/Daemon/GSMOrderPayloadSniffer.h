#ifndef GSMOrderPayloadSniffer_h
#define GSMOrderPayloadSniffer_h

#import <Foundation/Foundation.h>
#import "SharedConfig.h"

@interface GSMSniffedOrder : NSObject

@property (nonatomic, copy)   NSString *orderId;             // 26-char ULID (e.g. "01HJN66X4T48BY3M7NA34XZZJW")
@property (nonatomic, assign) BOOL isGreenFood;              // YES = Green Food; NO = Bike / Express / Ride
@property (nonatomic, assign) BOOL isBikeOrExpress;          // YES = Bike / Express / Express 2H / Taxi / Car
@property (nonatomic, assign) BOOL isGroupOrder;             // YES = MDModels.GroupOrder (Express 2H / Grouped Food)
@property (nonatomic, copy)   NSString *serviceTypeRaw;      // e.g. "EXPRESS-ONDEMAND", "FOOD-DELIVERY", "RIDE-TAXI"
@property (nonatomic, copy)   NSString *serviceDisplayName;  // e.g. "Green Bike", "Express", "Green Food"
@property (nonatomic, assign) NSInteger totalPayVND;         // Exact integer VND displayed on card (fee.total_pay / total_fee)
@property (nonatomic, assign) NSInteger totalFeeVND;         // fee.total_fee
@property (nonatomic, assign) NSInteger baseFeeVND;          // fee.fee_breakdown.base_fee
@property (nonatomic, assign) double serverDistanceKm;       // Top-level "distance" (km) from GSM backend

// Pickup ("PICK UP" in path[]) — 100% untruncated without "..."
@property (nonatomic, copy)   NSString *pickupName;          // Merchant or sender name
@property (nonatomic, copy)   NSString *pickupShortAddress;  // Landmark / building / shop title
@property (nonatomic, copy)   NSString *pickupFullAddress;   // Full street, ward, district address
@property (nonatomic, copy)   NSString *pickupNote;          // address_note
@property (nonatomic, assign) BOOL hasPickupCoords;
@property (nonatomic, assign) double pickupLat;
@property (nonatomic, assign) double pickupLng;

// Dropoff ("DROP OFF" in path[]) — 100% untruncated without "..."
@property (nonatomic, copy)   NSString *dropoffName;
@property (nonatomic, copy)   NSString *dropoffShortAddress;
@property (nonatomic, copy)   NSString *dropoffFullAddress;
@property (nonatomic, copy)   NSString *dropoffNote;
@property (nonatomic, assign) BOOL hasDropoffCoords;
@property (nonatomic, assign) double dropoffLat;
@property (nonatomic, assign) double dropoffLng;

@property (nonatomic, assign) double orderTimestampEpoch;    // Decoded from dispatch_time or ULID 48-bit ms timestamp
@property (nonatomic, assign) double sniffedAtEpoch;         // Local wall-clock time when first sniffed
@property (nonatomic, copy)   NSString *sniffSourceTag;      // "CacheWAL", "CacheDB", "FSCache", "RAMHeap"

@end

@interface GSMOrderPayloadSniffer : NSObject

+ (instancetype)sharedSniffer;

// Main entry point called ONLY when an Order Popup is visually present on screen.
// Performs 3-Lock Verification (Consumed Blacklist + Freshness Window + OCR Coherence Cross-Check).
- (GSMSniffedOrder *)sniffActiveOrderWithConfig:(FilterConfig *)config
                                   ocrPriceVND:(NSInteger)ocrPriceVND
                               isOCRHeaderFood:(BOOL)isOCRHeaderFood
                            isOCRHeaderNonFood:(BOOL)isOCRHeaderNonFood
                                    pickupText:(NSString *)pickupText
                                   dropoffText:(NSString *)dropoffText;

// Marks an orderId as already acted upon (Accepted or Rejected) so it can never match a future popup.
- (void)markOrderHandled:(NSString *)orderId;
- (BOOL)isOrderIdHandled:(NSString *)orderId;

// Fast (<0.15ms) pre-UI peek for OrderScanner's Dual-Strip Micro-OCR fast path.
// Returns a fresh, unhandled GSMSniffedOrder if one arrived within maxAgeSec (or is currently active in Preferences).
- (GSMSniffedOrder *)peekFreshUnverifiedOrderWithConfig:(FilterConfig *)config
                                              maxAgeSec:(double)maxAgeSec;

// Starts the 0%-CPU kernel kqueue (EVFILT_VNODE) 2-Phase monitor on Preferences & Cache.db-wal / fsCachedData.
// Phase 1 fires when a new ULID lands in vn.gsm.md.plist; Phase 2 fires when the full Order JSON lands in Cache.db-wal.
- (void)startRealtimeKernelMonitorWithConfigProvider:(FilterConfig *(^)(void))configProvider
                                        eventHandler:(void (^)(NSString *ambushULID, GSMSniffedOrder *preSniffedOrder))eventHandler;
- (void)stopRealtimeKernelMonitor;

// Exposed for unit/self-test verification of JSON parsing, raw buffer extraction, delta WAL reading & ULID decoding
+ (double)decodeULIDTimestampEpoch:(NSString *)ulid;
+ (GSMSniffedOrder *)parseOrderFromJSONDictionary:(NSDictionary *)rootDict
                                        sourceTag:(NSString *)sourceTag;
- (GSMSniffedOrder *)extractOrderAroundOffset:(size_t)hitOffset
                                     inBuffer:(const uint8_t *)buf
                                       length:(size_t)bufLen
                                    sourceTag:(NSString *)sourceTag;
- (void)scanFileTailAtPath:(NSString *)filePath
                 maxAgeSec:(double)maxAgeSec
                  nowEpoch:(double)now
               targetULIDs:(NSArray<NSString *> *)targetULIDs
                 sourceTag:(NSString *)sourceTag
            intoCandidates:(NSMutableArray<GSMSniffedOrder *> *)candidates;
- (void)cacheParsedOrder:(GSMSniffedOrder *)ord;

@end

#endif /* GSMOrderPayloadSniffer_h */
