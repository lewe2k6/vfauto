// C:/Users/Acer/.gemini/antigravity/scratch/pin-nhiet-do-ts/Sources/DashcamApp/RingStorageManager.h
// Context: Objective-C Header / SQLite WAL Ring Buffer & Daily Quota / iOS 12.0+ arm64

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, ClipUploadStatus) {
    ClipUploadPending   = 0,
    ClipUploadUploading = 1,
    ClipUploadDone      = 2,
    ClipUploadFailed    = 3
};

@interface DashcamClipRecord : NSObject
@property (nonatomic, assign) int64_t clipId;
@property (nonatomic, copy)   NSString *filename;
@property (nonatomic, copy)   NSString *fullPath;
@property (nonatomic, copy)   NSString *caption;
@property (nonatomic, assign) double startEpoch;
@property (nonatomic, assign) NSInteger durationSec;
@property (nonatomic, assign) int64_t sizeBytes;
@property (nonatomic, assign) BOOL isLocked;
@property (nonatomic, assign) ClipUploadStatus uploadStatus;
@property (nonatomic, assign) NSInteger retryCount;
@end

@interface RingStorageManager : NSObject

+ (instancetype)sharedManager;

- (NSString *)loopDirectory;
- (NSString *)lockedDirectory;
- (NSString *)tempUploadDirectory;

// Prepare a new clip output path & enforce free space + ring limits atomically
- (NSString *)allocateNextClipPathForStartDate:(NSDate *)startDate;
- (void)ensureSafeFreeSpace;

// Register completed clip in SQLite queue
- (DashcamClipRecord *)registerCompletedClipAtPath:(NSString *)filePath
                                        startEpoch:(double)startEpoch
                                       durationSec:(NSInteger)durationSec
                                           caption:(NSString *)caption
                                          isLocked:(BOOL)isLocked;

// Lock the most recently registered clip (for G-Sensor / manual lock)
- (BOOL)promoteClipToLockedByPath:(NSString *)filePath;
- (BOOL)lockMostRecentLoopClip;

// Upload Queue Operations
- (DashcamClipRecord *)nextPendingClipAllowRegular:(BOOL)allowRegular;
- (void)markClip:(int64_t)clipId status:(ClipUploadStatus)status incrementRetry:(BOOL)incRetry;
- (void)resetStuckUploadingClips;
- (NSInteger)pendingUploadCount;
- (NSInteger)pendingLockedCount;

// Daily Metered Quota (YYYY-MM-DD local time)
- (void)addUploadedBytes:(int64_t)bytes isMetered:(BOOL)isMetered;
- (int64_t)todayMeteredBytesSent;
- (int64_t)todayHomeBytesSent;
- (void)resetTodayQuota;

// Storage Stats
- (double)freeDiskSpaceGB;
- (double)loopFolderSizeGB;
- (double)lockedFolderSizeGB;

@end
