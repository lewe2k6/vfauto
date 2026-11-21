// C:/Users/Acer/.gemini/antigravity/scratch/pin-nhiet-do-ts/Sources/DashcamApp/TelegramUploader.m
// Context: Objective-C Implementation / Zero-RAM Disk-Streamed Telegram Uploader / iOS 12.0+ arm64

#import "TelegramUploader.h"
#import "DashcamConfig.h"
#import "RingStorageManager.h"
#import "NetworkClassifier.h"
#import "CoolCameraEngine.h"

static const int64_t kTelegramBotMaxFileBytes = 49LL * 1024LL * 1024LL; // Safe margin below 50 MB Bot API limit
static const int64_t kEmergencyLockedReserveBytes = 300LL * 1024LL * 1024LL; // +300 MB reserve for crash clips

@interface TelegramUploader () <NSURLSessionTaskDelegate, NSURLSessionDataDelegate> {
    dispatch_queue_t _workQueue;
    NSURLSession *_uploadSession;
    BOOL _running;
    BOOL _isUploading;
    double _backoffUntilEpoch;
    NSInteger _consecutiveFails;

    // Active upload tracking
    DashcamClipRecord *_activeClip;
    NSString *_activeMultipartPath;
    BOOL _activeUploadIsMetered;
    NSMutableData *_responseData;
    NSString *_lastStatusMessage;
    double _currentUploadProgress;
}
@end

@implementation TelegramUploader

+ (instancetype)sharedUploader {
    static TelegramUploader *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[TelegramUploader alloc] init];
    });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _workQueue = dispatch_queue_create("com.vn.cooldash6.uploader", DISPATCH_QUEUE_SERIAL);
        _lastStatusMessage = @"Sẵn sàng";

        NSURLSessionConfiguration *sc = [NSURLSessionConfiguration defaultSessionConfiguration];
        sc.timeoutIntervalForRequest  = 45.0;
        sc.timeoutIntervalForResource = 150.0;
        sc.HTTPMaximumConnectionsPerHost = 1;
        sc.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        _uploadSession = [NSURLSession sessionWithConfiguration:sc delegate:self delegateQueue:nil];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onNetworkChanged:)
                                                     name:kDashcamNetworkChangedNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_uploadSession invalidateAndCancel];
}

- (BOOL)isUploading { return _isUploading; }
- (NSString *)lastStatusMessage { return _lastStatusMessage ?: @""; }
- (double)currentUploadProgress { return _currentUploadProgress; }

- (void)onNetworkChanged:(NSNotification *)note {
    dispatch_async(_workQueue, ^{
        // Wake up immediately when signal returns or switches to Home Wi-Fi
        self->_backoffUntilEpoch = 0;
        self->_consecutiveFails  = 0;
        [self scheduleTickAfterSeconds:1.0];
    });
}

- (void)startWorker {
    dispatch_async(_workQueue, ^{
        if (self->_running) return;
        self->_running = YES;
        [[RingStorageManager sharedManager] resetStuckUploadingClips];
        [self scheduleTickAfterSeconds:2.0];
    });
}

- (void)stopWorker {
    dispatch_async(_workQueue, ^{
        self->_running = NO;
    });
}

- (void)triggerNow {
    dispatch_async(_workQueue, ^{
        if (!self->_running || self->_isUploading) return;
        self->_backoffUntilEpoch = 0;
        [self processNextClip];
    });
}

- (void)scheduleTickAfterSeconds:(double)sec {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC)), _workQueue, ^{
        if (self->_running && !self->_isUploading) {
            [self processNextClip];
        }
    });
}

- (void)processNextClip {
    if (!_running || _isUploading) return;

    DashcamConfig *cfg = [DashcamConfig sharedConfig];
    if (!cfg.enableTelegramUpload || !cfg.hasValidTelegramConfig) {
        _lastStatusMessage = @"Chưa cấu hình Telegram Bot";
        [self scheduleTickAfterSeconds:15.0];
        return;
    }

    // Pause uploads when phone is seriously overheating to protect hardware
    NSProcessInfoThermalState th = [CoolCameraEngine sharedEngine].lastThermalState;
    if (th == NSProcessInfoThermalStateSerious || th == NSProcessInfoThermalStateCritical) {
        _lastStatusMessage = @"Tạm dừng gửi (máy đang nóng)";
        [self scheduleTickAfterSeconds:20.0];
        return;
    }

    double now = [[NSDate date] timeIntervalSince1970];
    if (now < _backoffUntilEpoch) {
        [self scheduleTickAfterSeconds:MAX(2.0, _backoffUntilEpoch - now)];
        return;
    }

    [[NetworkClassifier sharedClassifier] refreshNow];
    DashcamNetMode netMode = [NetworkClassifier sharedClassifier].currentMode;
    if (netMode == DashcamNetModeOffline) {
        _lastStatusMessage = @"Mất mạng • Đợi sóng";
        [self scheduleTickAfterSeconds:15.0];
        return;
    }

    BOOL isMetered = (netMode != DashcamNetModeHomeUnlimited);
    RingStorageManager *store = [RingStorageManager sharedManager];
    int64_t todayMetered = [store todayMeteredBytesSent];
    int64_t limitBytes   = (int64_t)cfg.dailyMeteredLimitMB * 1024LL * 1024LL;

    BOOL allowRegular = YES;
    if (isMetered && todayMetered >= limitBytes) {
        allowRegular = NO;
        // Even for emergency locked clips, cap at limit + 300MB so cellular plan never explodes
        if (todayMetered >= (limitBytes + kEmergencyLockedReserveBytes)) {
            _lastStatusMessage = @"Chạm trần 4G hôm nay • Chờ Wi-Fi nhà";
            [self scheduleTickAfterSeconds:30.0];
            return;
        }
    }

    DashcamClipRecord *clip = [store nextPendingClipAllowRegular:allowRegular];
    if (!clip) {
        _lastStatusMessage = allowRegular ? @"Đã đồng bộ xong" : @"Chạm trần 4G • Chờ Wi-Fi nhà";
        [self scheduleTickAfterSeconds:10.0];
        return;
    }

    if (clip.sizeBytes > kTelegramBotMaxFileBytes) {
        // File exceeded Bot API 50MB hard cap; skip to avoid endless 413 retries
        [store markClip:clip.clipId status:ClipUploadFailed incrementRetry:YES];
        _lastStatusMessage = @"Bỏ qua clip > 49 MB (vượt giới hạn Bot)";
        [self scheduleTickAfterSeconds:2.0];
        return;
    }

    // Pre-Flight Health Probe (<1KB GET /getMe, 3s timeout) so we never burn 4G quota in dead tunnels!
    _isUploading = YES;
    _lastStatusMessage = @"Đang kiểm tra sóng...";
    [self runPreFlightProbeWithToken:cfg.telegramBotToken completion:^(BOOL alive) {
        dispatch_async(self->_workQueue, ^{
            if (!alive) {
                self->_isUploading = NO;
                self->_consecutiveFails++;
                double waitSec = MIN(120.0, 15.0 * (1 << MIN(3, self->_consecutiveFails - 1)));
                self->_backoffUntilEpoch = [[NSDate date] timeIntervalSince1970] + waitSec;
                self->_lastStatusMessage = [NSString stringWithFormat:@"Mạng yếu/Hầm • Thử lại sau %.0fs", waitSec];
                [self scheduleTickAfterSeconds:waitSec];
                return;
            }
            [self beginStreamUploadForClip:clip isMetered:isMetered];
        });
    }];
}

- (void)runPreFlightProbeWithToken:(NSString *)token completion:(void (^)(BOOL alive))completion {
    NSString *urlStr = [NSString stringWithFormat:@"https://api.telegram.org/bot%@/getMe", token];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    req.HTTPMethod = @"GET";
    req.timeoutInterval = 3.5;

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
                                                                 completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
        BOOL ok = (!err && http.statusCode == 200);
        if (completion) completion(ok);
    }];
    [task resume];
}

// Streams MP4 into a temporary multipart body file on disk -> ZERO RAM spike on 1GB iPhone 6!
- (NSString *)buildMultipartBodyFileForClip:(DashcamClipRecord *)clip
                                     chatId:(NSString *)chatId
                                   boundary:(NSString *)boundary {
    NSString *tmpPath = [[[RingStorageManager sharedManager] tempUploadDirectory]
                         stringByAppendingPathComponent:[NSString stringWithFormat:@"mp_%lld.bin", clip.clipId]];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:tmpPath error:nil];
    if (![fm createFileAtPath:tmpPath contents:nil attributes:nil]) {
        return nil;
    }

    NSFileHandle *outHandle = [NSFileHandle fileHandleForWritingAtPath:tmpPath];
    NSFileHandle *inHandle  = [NSFileHandle fileHandleForReadingAtPath:clip.fullPath];
    if (!outHandle || !inHandle) {
        if (outHandle) [outHandle closeFile];
        if (inHandle)  [inHandle closeFile];
        [fm removeItemAtPath:tmpPath error:nil];
        return nil;
    }

    NSMutableString *hdr = [NSMutableString string];
    [hdr appendFormat:@"--%@\r\nContent-Disposition: form-data; name=\"chat_id\"\r\n\r\n%@\r\n", boundary, chatId];
    [hdr appendFormat:@"--%@\r\nContent-Disposition: form-data; name=\"supports_streaming\"\r\n\r\ntrue\r\n", boundary];
    [hdr appendFormat:@"--%@\r\nContent-Disposition: form-data; name=\"width\"\r\n\r\n1280\r\n", boundary];
    [hdr appendFormat:@"--%@\r\nContent-Disposition: form-data; name=\"height\"\r\n\r\n720\r\n", boundary];
    [hdr appendFormat:@"--%@\r\nContent-Disposition: form-data; name=\"duration\"\r\n\r\n%ld\r\n", boundary, (long)clip.durationSec];
    if (clip.caption.length > 0) {
        [hdr appendFormat:@"--%@\r\nContent-Disposition: form-data; name=\"caption\"\r\n\r\n%@\r\n", boundary, clip.caption];
    }
    [hdr appendFormat:@"--%@\r\nContent-Disposition: form-data; name=\"video\"; filename=\"%@\"\r\nContent-Type: video/mp4\r\n\r\n",
     boundary, clip.filename];

    [outHandle writeData:[hdr dataUsingEncoding:NSUTF8StringEncoding]];

    // Copy MP4 in 256 KB chunks -> constant 256 KB RAM footprint
    @autoreleasepool {
        while (YES) {
            @autoreleasepool {
                NSData *chunk = [inHandle readDataOfLength:(256 * 1024)];
                if (!chunk || chunk.length == 0) break;
                [outHandle writeData:chunk];
            }
        }
    }

    NSString *footer = [NSString stringWithFormat:@"\r\n--%@--\r\n", boundary];
    [outHandle writeData:[footer dataUsingEncoding:NSUTF8StringEncoding]];

    [inHandle closeFile];
    [outHandle closeFile];
    return tmpPath;
}

- (void)beginStreamUploadForClip:(DashcamClipRecord *)clip isMetered:(BOOL)isMetered {
    DashcamConfig *cfg = [DashcamConfig sharedConfig];
    NSString *boundary = [NSString stringWithFormat:@"----CoolDash6%@", [NSUUID UUID].UUIDString];
    NSString *mpPath   = [self buildMultipartBodyFileForClip:clip chatId:cfg.telegramChatId boundary:boundary];
    if (!mpPath) {
        _isUploading = NO;
        _lastStatusMessage = @"Lỗi tạo file gửi";
        [self scheduleTickAfterSeconds:10.0];
        return;
    }

    [[RingStorageManager sharedManager] markClip:clip.clipId status:ClipUploadUploading incrementRetry:NO];
    _activeClip            = clip;
    _activeMultipartPath   = mpPath;
    _activeUploadIsMetered = isMetered;
    _responseData          = [NSMutableData data];
    _currentUploadProgress = 0.0;
    _lastStatusMessage     = [NSString stringWithFormat:@"Đang gửi %@...", clip.filename];

    NSString *urlStr = [NSString stringWithFormat:@"https://api.telegram.org/bot%@/sendVideo", cfg.telegramBotToken];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    req.HTTPMethod = @"POST";
    [req setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary] forHTTPHeaderField:@"Content-Type"];

    NSURLSessionUploadTask *task = [_uploadSession uploadTaskWithRequest:req fromFile:[NSURL fileURLWithPath:mpPath]];
    [task resume];
}

#pragma mark - NSURLSession Delegates

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
   didSendBodyData:(int64_t)bytesSent
    totalBytesSent:(int64_t)totalBytesSent
totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend {
    // Count ACTUAL wire bytes sent (even for failed/interrupted uploads) so 4GB Android plan is NEVER exceeded!
    if (bytesSent > 0) {
        [[RingStorageManager sharedManager] addUploadedBytes:bytesSent isMetered:_activeUploadIsMetered];
    }
    if (totalBytesExpectedToSend > 0) {
        _currentUploadProgress = (double)totalBytesSent / (double)totalBytesExpectedToSend;
    }
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    dispatch_async(_workQueue, ^{
        if (self->_responseData && data.length > 0 && self->_responseData.length < 32768) {
            [self->_responseData appendData:data];
        }
    });
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    dispatch_async(_workQueue, ^{
        // Always clean up temp multipart file immediately
        if (self->_activeMultipartPath.length > 0) {
            [[NSFileManager defaultManager] removeItemAtPath:self->_activeMultipartPath error:nil];
            self->_activeMultipartPath = nil;
        }

        DashcamClipRecord *clip = self->_activeClip;
        self->_activeClip = nil;
        self->_isUploading = NO;
        self->_currentUploadProgress = 0.0;

        NSHTTPURLResponse *http = (NSHTTPURLResponse *)task.response;
        NSInteger code = http ? http.statusCode : 0;

        if (!error && code == 200) {
            self->_consecutiveFails = 0;
            if (clip) {
                [[RingStorageManager sharedManager] markClip:clip.clipId status:ClipUploadDone incrementRetry:NO];
            }
            self->_lastStatusMessage = [NSString stringWithFormat:@"Đã gửi xong %@", clip.filename ?: @""];
            // Polite 4-second pacing between consecutive clips on Home Wi-Fi to avoid Telegram 429 FloodWait
            [self scheduleTickAfterSeconds:4.0];
            return;
        }

        // Handle Telegram 429 Too Many Requests (retry_after)
        double retryAfter = 0.0;
        if (code == 429 && self->_responseData.length > 0) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:self->_responseData options:0 error:nil];
            NSDictionary *params = [json isKindOfClass:[NSDictionary class]] ? json[@"parameters"] : nil;
            if ([params isKindOfClass:[NSDictionary class]] && params[@"retry_after"]) {
                retryAfter = [params[@"retry_after"] doubleValue] + 2.0;
            }
        }

        if (clip) {
            [[RingStorageManager sharedManager] markClip:clip.clipId status:ClipUploadFailed incrementRetry:YES];
        }
        self->_consecutiveFails++;
        double waitSec = (retryAfter > 0.0) ? retryAfter : MIN(120.0, 15.0 * (1 << MIN(3, self->_consecutiveFails - 1)));
        self->_backoffUntilEpoch = [[NSDate date] timeIntervalSince1970] + waitSec;
        self->_lastStatusMessage = [NSString stringWithFormat:@"Lỗi gửi (HTTP %ld) • Đợi %.0fs", (long)code, waitSec];
        [self scheduleTickAfterSeconds:waitSec];
    });
}

- (void)testBotConnectionWithCompletion:(void (^)(BOOL ok, NSString *message))completion {
    DashcamConfig *cfg = [DashcamConfig sharedConfig];
    if (!cfg.hasValidTelegramConfig) {
        if (completion) completion(NO, @"Thiếu Bot Token hoặc Chat ID.");
        return;
    }
    NSString *urlStr = [NSString stringWithFormat:@"https://api.telegram.org/bot%@/sendMessage", cfg.telegramBotToken];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 8.0;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSDictionary *payload = @{
        @"chat_id": cfg.telegramChatId,
        @"text": @"[CoolDash6] Kết nối Telegram thành công từ iPhone 6!"
    };
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];

    NSURLSessionDataTask *t = [[NSURLSession sharedSession] dataTaskWithRequest:req
                                                              completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
        BOOL ok = (!err && http.statusCode == 200);
        NSString *msg = ok ? @"Gửi tin nhắn test thành công!" :
            [NSString stringWithFormat:@"Thất bại (HTTP %ld): %@", (long)http.statusCode, err.localizedDescription ?: @"Kiểm tra lại Token/ChatID"];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(ok, msg);
        });
    }];
    [t resume];
}

@end
