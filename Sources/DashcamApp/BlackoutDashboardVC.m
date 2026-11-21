// C:/Users/Acer/.gemini/antigravity/scratch/pin-nhiet-do-ts/Sources/DashcamApp/BlackoutDashboardVC.m
// Context: Objective-C Implementation / Zero-GPU Blackout Dashcam Cockpit UI / iOS 12.0+ arm64

#import "BlackoutDashboardVC.h"
#import "DashcamConfig.h"
#import "CoolCameraEngine.h"
#import "RingStorageManager.h"
#import "NetworkClassifier.h"
#import "TelemetryAndGSensor.h"
#import "TelegramUploader.h"
#import "SettingsVC.h"
#import <AVFoundation/AVFoundation.h>

@interface BlackoutDashboardVC () <CoolCameraEngineDelegate, TelemetryShockDelegate> {
    UIView *_previewBox;
    UILabel *_lblRecHeader;
    UILabel *_lblThermalAndProfile;
    UILabel *_lblStorageAndQuota;
    UILabel *_lblNetworkAndUpload;
    UIButton *_btnLockClip;
    UIButton *_btnToggleRec;
    UIButton *_btnPreview10s;
    UIButton *_btnSettings;

    NSTimer *_uiTimer;
    NSTimer *_blackoutTimer;
    BOOL _isBlackoutActive;
    CGFloat _savedBrightness;
}
@end

@implementation BlackoutDashboardVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    _savedBrightness = [UIScreen mainScreen].brightness;

    [CoolCameraEngine sharedEngine].delegate = self;
    [TelemetryAndGSensor sharedTelemetry].delegate = self;

    [self buildLayout];

    // Request Camera & Mic permissions cleanly on first launch
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
        if (!granted) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NetworkClassifier sharedClassifier] startMonitoring];
            [[TelemetryAndGSensor sharedTelemetry] start];
            [[TelegramUploader sharedUploader] startWorker];
            if ([DashcamConfig sharedConfig].autoRecordOnLaunch) {
                [[CoolCameraEngine sharedEngine] startRecording];
            }
            [self showPreviewForSeconds:10.0];
        });
    }];

    _uiTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                target:self
                                              selector:@selector(refreshDashboardTick)
                                              userInfo:nil
                                               repeats:YES];
}

- (void)dealloc {
    [_uiTimer invalidate];
    [_blackoutTimer invalidate];
}

- (void)buildLayout {
    CGFloat sw = self.view.bounds.size.width;
    CGFloat sh = self.view.bounds.size.height;

    // Preview container (detached completely in Blackout Mode for zero GPU heat)
    _previewBox = [[UIView alloc] initWithFrame:CGRectMake(0, 0, sw, sh * 0.42)];
    _previewBox.backgroundColor = [UIColor blackColor];
    _previewBox.clipsToBounds = YES;
    _previewBox.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:_previewBox];

    CGFloat topY = 28.0;
    _lblRecHeader = [[UILabel alloc] initWithFrame:CGRectMake(16, topY, sw - 32, 34)];
    _lblRecHeader.text = @"● CHỜ KHỞI ĐỘNG...";
    _lblRecHeader.textColor = [UIColor colorWithRed:1.0 green:0.28 blue:0.28 alpha:1.0];
    _lblRecHeader.font = [UIFont monospacedDigitSystemFontOfSize:22 weight:UIFontWeightBold];
    _lblRecHeader.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:_lblRecHeader];

    CGFloat infoY = sh * 0.44;
    _lblThermalAndProfile = [[UILabel alloc] initWithFrame:CGRectMake(16, infoY, sw - 32, 22)];
    _lblThermalAndProfile.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
    _lblThermalAndProfile.font = [UIFont systemFontOfSize:13];
    _lblThermalAndProfile.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:_lblThermalAndProfile];

    _lblStorageAndQuota = [[UILabel alloc] initWithFrame:CGRectMake(16, infoY + 26, sw - 32, 22)];
    _lblStorageAndQuota.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
    _lblStorageAndQuota.font = [UIFont systemFontOfSize:13];
    _lblStorageAndQuota.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:_lblStorageAndQuota];

    _lblNetworkAndUpload = [[UILabel alloc] initWithFrame:CGRectMake(16, infoY + 52, sw - 32, 40)];
    _lblNetworkAndUpload.numberOfLines = 2;
    _lblNetworkAndUpload.textColor = [UIColor colorWithRed:0.3 green:0.85 blue:0.75 alpha:1.0];
    _lblNetworkAndUpload.font = [UIFont systemFontOfSize:12];
    _lblNetworkAndUpload.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:_lblNetworkAndUpload];

    // Giant Red Lock Button (easy to hit with motorcycle gloves without looking)
    CGFloat lockY = sh - 190;
    _btnLockClip = [UIButton buttonWithType:UIButtonTypeSystem];
    _btnLockClip.frame = CGRectMake(16, lockY, sw - 32, 86);
    _btnLockClip.backgroundColor = [UIColor colorWithRed:0.55 green:0.08 blue:0.08 alpha:1.0];
    [_btnLockClip setTitle:@"KHÓA CLIP HIỆN TẠI (CHỐNG XÓA)" forState:UIControlStateNormal];
    [_btnLockClip setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _btnLockClip.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    _btnLockClip.layer.cornerRadius = 14;
    _btnLockClip.layer.borderWidth = 1.5;
    _btnLockClip.layer.borderColor = [UIColor colorWithRed:0.95 green:0.25 blue:0.25 alpha:0.7].CGColor;
    _btnLockClip.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    [_btnLockClip addTarget:self action:@selector(onTapLockClip) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_btnLockClip];

    // Bottom Row: Start/Stop | Preview 10s | Settings
    CGFloat rowY = sh - 86;
    CGFloat btnW = (sw - 48) / 3.0;

    _btnToggleRec = [self makeBottomBtn:@"DỪNG QUAY" x:16 y:rowY w:btnW bg:[UIColor colorWithWhite:0.16 alpha:1.0] sel:@selector(onTapToggleRec)];
    _btnPreview10s = [self makeBottomBtn:@"XEM CAM 10s" x:24 + btnW y:rowY w:btnW bg:[UIColor colorWithWhite:0.16 alpha:1.0] sel:@selector(onTapPreview10s)];
    _btnSettings = [self makeBottomBtn:@"CÀI ĐẶT" x:32 + btnW * 2 y:rowY w:btnW bg:[UIColor colorWithWhite:0.16 alpha:1.0] sel:@selector(onTapSettings)];

    [self.view addSubview:_btnToggleRec];
    [self.view addSubview:_btnPreview10s];
    [self.view addSubview:_btnSettings];
}

- (UIButton *)makeBottomBtn:(NSString *)title x:(CGFloat)x y:(CGFloat)y w:(CGFloat)w bg:(UIColor *)bg sel:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(x, y, w, 52);
    b.backgroundColor = bg;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor colorWithWhite:0.88 alpha:1.0] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    b.layer.cornerRadius = 10;
    b.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)showPreviewForSeconds:(double)sec {
    [_blackoutTimer invalidate];
    _isBlackoutActive = NO;
    [self restoreUserBrightness];
    [[CoolCameraEngine sharedEngine] attachPreviewToView:_previewBox];
    _previewBox.alpha = 1.0;

    _blackoutTimer = [NSTimer scheduledTimerWithTimeInterval:sec
                                                      target:self
                                                    selector:@selector(enterBlackoutMode)
                                                    userInfo:nil
                                                     repeats:NO];
}

- (void)enterBlackoutMode {
    [_blackoutTimer invalidate];
    _blackoutTimer = nil;
    _isBlackoutActive = YES;
    [[CoolCameraEngine sharedEngine] detachPreview];
    _previewBox.alpha = 0.0;

    // Dim LCD backlight to 2% to keep iPhone 6 super cool & save battery
    if ([UIScreen mainScreen].brightness > 0.05) {
        _savedBrightness = [UIScreen mainScreen].brightness;
    }
    [UIScreen mainScreen].brightness = 0.02;
}

- (void)restoreUserBrightness {
    if (_savedBrightness >= 0.05 && [UIScreen mainScreen].brightness < 0.05) {
        [UIScreen mainScreen].brightness = _savedBrightness;
    }
}

#pragma mark - Actions

- (void)onTapLockClip {
    [[CoolCameraEngine sharedEngine] lockCurrentSegment];
    _btnLockClip.backgroundColor = [UIColor colorWithRed:0.85 green:0.15 blue:0.15 alpha:1.0];
    [_btnLockClip setTitle:@"ĐÃ KHÓA CLIP NÀY!" forState:UIControlStateNormal];
}

- (void)onTapToggleRec {
    CoolCameraEngine *eng = [CoolCameraEngine sharedEngine];
    if (eng.isRecording) {
        [eng stopRecording];
        [_btnToggleRec setTitle:@"BẮT ĐẦU QUAY" forState:UIControlStateNormal];
        _lblRecHeader.text = @"■ ĐÃ DỪNG QUAY";
        _lblRecHeader.textColor = [UIColor lightGrayColor];
    } else {
        [eng startRecording];
        [_btnToggleRec setTitle:@"DỪNG QUAY" forState:UIControlStateNormal];
        [self showPreviewForSeconds:8.0];
    }
}

- (void)onTapPreview10s {
    if (_isBlackoutActive) {
        [self showPreviewForSeconds:10.0];
    } else {
        [self enterBlackoutMode];
    }
}

- (void)onTapSettings {
    [_blackoutTimer invalidate];
    [self restoreUserBrightness];
    SettingsVC *vc = [[SettingsVC alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.navigationBar.barStyle = UIBarStyleBlack;
    nav.navigationBar.tintColor = [UIColor colorWithRed:0.25 green:0.85 blue:0.75 alpha:1.0];
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Delegates & Timer

- (void)refreshDashboardTick {
    DashcamConfig *cfg = [DashcamConfig sharedConfig];
    CoolCameraEngine *eng = [CoolCameraEngine sharedEngine];
    RingStorageManager *st = [RingStorageManager sharedManager];
    NetworkClassifier *nc = [NetworkClassifier sharedClassifier];
    TelegramUploader *up = [TelegramUploader sharedUploader];
    TelemetryAndGSensor *tel = [TelemetryAndGSensor sharedTelemetry];

    if (eng.isRecording) {
        NSInteger el = eng.currentSegmentElapsedSec;
        NSInteger mm = el / 60;
        NSInteger ss = el % 60;
        _lblRecHeader.text = eng.currentSegmentLocked
            ? [NSString stringWithFormat:@"● REC %02ld:%02ld [KHÓA]", (long)mm, (long)ss]
            : [NSString stringWithFormat:@"● REC %02ld:%02ld  %.0f km/h", (long)mm, (long)ss, tel.currentSpeedKmh];
        _lblRecHeader.textColor = eng.currentSegmentLocked
            ? [UIColor colorWithRed:1.0 green:0.75 blue:0.15 alpha:1.0]
            : [UIColor colorWithRed:1.0 green:0.28 blue:0.28 alpha:1.0];
    }

    _lblThermalAndProfile.text = [NSString stringWithFormat:@"%@ | Nhiệt: %@%@",
                                  [cfg profileDisplayName],
                                  [eng thermalStateDisplayString],
                                  _isBlackoutActive ? @" | Màn Đen" : @""];

    double meteredGB = (double)[st todayMeteredBytesSent] / (1024.0 * 1024.0 * 1024.0);
    double limitGB   = (double)cfg.dailyMeteredLimitMB / 1024.0;
    _lblStorageAndQuota.text = [NSString stringWithFormat:@"Vòng: %.1f/%.0fGB (Trống %.1fGB) | 4G: %.2f/%.1fGB",
                                [st loopFolderSizeGB], cfg.maxLoopStorageGB, [st freeDiskSpaceGB],
                                meteredGB, limitGB];

    NSString *progStr = up.isUploading
        ? [NSString stringWithFormat:@" (%.0f%%)", up.currentUploadProgress * 100.0]
        : @"";
    _lblNetworkAndUpload.text = [NSString stringWithFormat:@"%@\nTelegram: %@%@ • Chờ: %ld clip",
                                 [nc modeDisplayString], up.lastStatusMessage, progStr, (long)[st pendingUploadCount]];
}

- (void)cameraEngineDidFinishClipAtPath:(NSString *)filePath
                             startEpoch:(double)startEpoch
                            durationSec:(NSInteger)durationSec
                               isLocked:(BOOL)isLocked {
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:nil];
    int64_t sz = [attrs fileSize];

    NSString *caption = [[TelemetryAndGSensor sharedTelemetry] buildCaptionForStartEpoch:startEpoch
                                                                             durationSec:durationSec
                                                                               sizeBytes:sz
                                                                                isLocked:isLocked];
    [[TelemetryAndGSensor sharedTelemetry] resetSegmentStats];
    [[RingStorageManager sharedManager] registerCompletedClipAtPath:filePath
                                                         startEpoch:startEpoch
                                                        durationSec:durationSec
                                                            caption:caption
                                                           isLocked:isLocked];

    // Reset Lock button visual state for next clip
    _btnLockClip.backgroundColor = [UIColor colorWithRed:0.55 green:0.08 blue:0.08 alpha:1.0];
    [_btnLockClip setTitle:@"KHÓA CLIP HIỆN TẠI (CHỐNG XÓA)" forState:UIControlStateNormal];

    [[TelegramUploader sharedUploader] triggerNow];
}

- (void)cameraEngineDidUpdateStatus:(NSString *)statusText
                   segmentElapsedSec:(NSInteger)elapsedSec
                        thermalLabel:(NSString *)thermalLabel {
    // Handled smoothly by 1Hz UI timer to keep main thread minimal
}

- (void)telemetryDidDetectShockWithPeakG:(double)peakG {
    [[CoolCameraEngine sharedEngine] lockCurrentSegment];
    _btnLockClip.backgroundColor = [UIColor colorWithRed:0.95 green:0.45 blue:0.05 alpha:1.0];
    [_btnLockClip setTitle:[NSString stringWithFormat:@"VA CHẠM %.1fG • ĐÃ TỰ KHÓA CLIP!", peakG] forState:UIControlStateNormal];
}

@end
