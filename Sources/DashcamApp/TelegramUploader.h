// C:/Users/Acer/.gemini/antigravity/scratch/pin-nhiet-do-ts/Sources/DashcamApp/TelegramUploader.h
// Context: Objective-C Header / Zero-RAM Disk-Streamed Telegram Uploader / iOS 12.0+ arm64

#import <Foundation/Foundation.h>

@interface TelegramUploader : NSObject

@property (nonatomic, readonly) BOOL isUploading;
@property (nonatomic, readonly, copy) NSString *lastStatusMessage;
@property (nonatomic, readonly) double currentUploadProgress; // 0.0 .. 1.0

+ (instancetype)sharedUploader;

- (void)startWorker;
- (void)stopWorker;
- (void)triggerNow;

// Quick connectivity & credential test for Settings screen
- (void)testBotConnectionWithCompletion:(void (^)(BOOL ok, NSString *message))completion;

@end
