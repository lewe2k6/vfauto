// C:/Users/Acer/.gemini/antigravity/scratch/pin-nhiet-do-ts/Sources/DashcamApp/CoolCameraEngine.m
// Context: Objective-C Implementation / Hardware H.264 Dual-Writer Ping-Pong Engine / iOS 12.0+ arm64

#import "CoolCameraEngine.h"
#import "DashcamConfig.h"
#import "RingStorageManager.h"
#import <VideoToolbox/VideoToolbox.h>

@interface CoolWriterSlot : NSObject
@property (nonatomic, strong) AVAssetWriter *writer;
@property (nonatomic, strong) AVAssetWriterInput *videoInput;
@property (nonatomic, strong) AVAssetWriterInput *audioInput;
@property (nonatomic, copy)   NSString *filePath;
@property (nonatomic, assign) double startWallEpoch;
@property (nonatomic, assign) CMTime firstVideoPTS;
@property (nonatomic, assign) BOOL sessionStarted;
@property (nonatomic, assign) BOOL isLocked;
@end

@implementation CoolWriterSlot
- (instancetype)init {
    self = [super init];
    if (self) {
        _firstVideoPTS = kCMTimeInvalid;
    }
    return self;
}
@end

@interface CoolCameraEngine () <AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate> {
    AVCaptureSession *_session;
    AVCaptureDevice *_videoDevice;
    AVCaptureVideoPreviewLayer *_previewLayer;
    dispatch_queue_t _captureQueue;
    dispatch_queue_t _finalizeQueue;

    CoolWriterSlot *_activeSlot;
    CoolWriterSlot *_standbySlot;

    BOOL _isRecording;
    NSInteger _segmentDurationSec;
    NSInteger _currentElapsedSec;
    double _lastThermalCheckEpoch;
    NSProcessInfoThermalState _thermalState;
    int _effectiveBitrateBps;
    int _effectiveWidth;
    int _effectiveHeight;
    int _effectiveFPS;
}
@end

@implementation CoolCameraEngine

+ (instancetype)sharedEngine {
    static CoolCameraEngine *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[CoolCameraEngine alloc] init];
    });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        dispatch_queue_attr_t hiAttr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
        _captureQueue  = dispatch_queue_create("com.vn.cooldash6.capture", hiAttr);
        _finalizeQueue = dispatch_queue_create("com.vn.cooldash6.finalize", DISPATCH_QUEUE_SERIAL);
        _thermalState  = [NSProcessInfo processInfo].thermalState;
        _effectiveWidth  = 1280;
        _effectiveHeight = 720;
        _effectiveFPS    = 20;
        _effectiveBitrateBps = 1150000;
    }
    return self;
}

- (BOOL)isRecording { return _isRecording; }
- (BOOL)currentSegmentLocked { return _activeSlot ? _activeSlot.isLocked : NO; }
- (NSInteger)currentSegmentElapsedSec { return _currentElapsedSec; }
- (NSProcessInfoThermalState)lastThermalState { return _thermalState; }

- (NSString *)thermalStateDisplayString {
    switch (_thermalState) {
        case NSProcessInfoThermalStateNominal:  return @"Mát (Nominal)";
        case NSProcessInfoThermalStateFair:     return @"Ấm nhẹ (Fair)";
        case NSProcessInfoThermalStateSerious:  return @"Nóng • Hạ tải 540p";
        case NSProcessInfoThermalStateCritical: return @"Rất nóng • Hạ 480p";
        default: return @"Mát";
    }
}

- (void)refreshThermalPolicy {
    _thermalState = [NSProcessInfo processInfo].thermalState;
    DashcamConfig *cfg = [DashcamConfig sharedConfig];
    if (_thermalState == NSProcessInfoThermalStateCritical) {
        _effectiveWidth      = 854;
        _effectiveHeight     = 480;
        _effectiveFPS        = 12;
        _effectiveBitrateBps = 550000;
    } else if (_thermalState == NSProcessInfoThermalStateSerious) {
        _effectiveWidth      = 960;
        _effectiveHeight     = 540;
        _effectiveFPS        = 15;
        _effectiveBitrateBps = 800000;
    } else {
        _effectiveWidth      = 1280;
        _effectiveHeight     = 720;
        _effectiveFPS        = (int)[cfg targetFPS];
        _effectiveBitrateBps = (int)[cfg videoBitrateBps];
    }
}

- (BOOL)setupCaptureSessionIfNeeded {
    if (_session) return YES;

    _session = [[AVCaptureSession alloc] init];
    [_session beginConfiguration];
    if ([_session canSetSessionPreset:AVCaptureSessionPreset1280x720]) {
        _session.sessionPreset = AVCaptureSessionPreset1280x720;
    }

    // 1. Rear Camera (Single ISP channel on A8)
    _videoDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if (!_videoDevice) {
        [_session commitConfiguration];
        _session = nil;
        return NO;
    }

    NSError *err = nil;
    AVCaptureDeviceInput *videoInput = [AVCaptureDeviceInput deviceInputWithDevice:_videoDevice error:&err];
    if (!videoInput || err || ![_session canAddInput:videoInput]) {
        [_session commitConfiguration];
        _session = nil;
        return NO;
    }
    [_session addInput:videoInput];

    // Lock Rear Camera for Cool & Vibration-Resistant Motorcycle Dashcam:
    // - Lock FPS to 20 or 24fps
    // - Lock Focus near infinity (0.85) so VCM autofocus motor doesn't hunt/heat on bumps
    if ([_videoDevice lockForConfiguration:&err]) {
        CMTime frameDur = CMTimeMake(1, (int32_t)_effectiveFPS);
        for (AVFrameRateRange *range in _videoDevice.activeFormat.videoSupportedFrameRateRanges) {
            if (_effectiveFPS >= range.minFrameRate && _effectiveFPS <= range.maxFrameRate) {
                _videoDevice.activeVideoMinFrameDuration = frameDur;
                _videoDevice.activeVideoMaxFrameDuration = frameDur;
                break;
            }
        }
        if ([_videoDevice isLockingFocusWithCustomLensPositionSupported]) {
            [_videoDevice setFocusModeLockedWithLensPosition:0.85f completionHandler:nil];
        } else if ([_videoDevice isFocusModeSupported:AVCaptureFocusModeLocked]) {
            _videoDevice.focusMode = AVCaptureFocusModeLocked;
        }
        if ([_videoDevice isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) {
            _videoDevice.exposureMode = AVCaptureExposureModeContinuousAutoExposure;
        }
        if ([_videoDevice isLowLightBoostSupported]) {
            _videoDevice.automaticallyEnablesLowLightBoostWhenAvailable = YES;
        }
        [_videoDevice unlockForConfiguration];
    }

    AVCaptureVideoDataOutput *videoOutput = [[AVCaptureVideoDataOutput alloc] init];
    videoOutput.alwaysDiscardsLateVideoFrames = YES;
    videoOutput.videoSettings = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    };
    [videoOutput setSampleBufferDelegate:self queue:_captureQueue];
    if ([_session canAddOutput:videoOutput]) {
        [_session addOutput:videoOutput];
        AVCaptureConnection *conn = [videoOutput connectionWithMediaType:AVMediaTypeVideo];
        if (conn.isVideoStabilizationSupported) {
            conn.preferredVideoStabilizationMode = AVCaptureVideoStabilizationModeOff; // Prevent heat & jello on handlebars
        }
        if (conn.isVideoOrientationSupported) {
            conn.videoOrientation = AVCaptureVideoOrientationLandscapeRight;
        }
    }

    // 2. Optional Lightweight Mono Audio
    if ([DashcamConfig sharedConfig].recordAudio) {
        AVCaptureDevice *audioDev = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
        if (audioDev) {
            AVCaptureDeviceInput *audioIn = [AVCaptureDeviceInput deviceInputWithDevice:audioDev error:nil];
            if (audioIn && [_session canAddInput:audioIn]) {
                [_session addInput:audioIn];
                AVCaptureAudioDataOutput *audioOut = [[AVCaptureAudioDataOutput alloc] init];
                [audioOut setSampleBufferDelegate:self queue:_captureQueue];
                if ([_session canAddOutput:audioOut]) {
                    [_session addOutput:audioOut];
                }
            }
        }
    }

    [_session commitConfiguration];
    return YES;
}

- (CoolWriterSlot *)createWriterSlot {
    NSDate *now = [NSDate date];
    NSString *path = [[RingStorageManager sharedManager] allocateNextClipPathForStartDate:now];
    NSURL *url = [NSURL fileURLWithPath:path];

    NSError *err = nil;
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:url fileType:AVFileTypeMPEG4 error:&err];
    if (!writer || err) return nil;

    // CRITICAL: Flush MP4 moof/mdat fragments every 5 seconds -> crash/power-loss proof!
    writer.movieFragmentInterval = CMTimeMake(5, 1);
    writer.shouldOptimizeForNetworkUse = NO; // Fragmented MP4 is already streamable

    NSDictionary *compressionProps = @{
        AVVideoAverageBitRateKey: @(_effectiveBitrateBps),
        AVVideoMaxKeyFrameIntervalKey: @(_effectiveFPS * 2),
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        AVVideoAllowFrameReorderingKey: @NO // Lower latency & lower RAM on A8
    };
    NSDictionary *videoSettings = @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(_effectiveWidth),
        AVVideoHeightKey: @(_effectiveHeight),
        AVVideoCompressionPropertiesKey: compressionProps
    };

    AVAssetWriterInput *vIn = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
    vIn.expectsMediaDataInRealTime = YES;
    if (![writer canAddInput:vIn]) return nil;
    [writer addInput:vIn];

    AVAssetWriterInput *aIn = nil;
    if ([DashcamConfig sharedConfig].recordAudio) {
        NSDictionary *audioSettings = @{
            AVFormatIDKey: @(kAudioFormatMPEG4AAC),
            AVNumberOfChannelsKey: @(1),
            AVSampleRateKey: @(16000),
            AVEncoderBitRateKey: @(32000)
        };
        aIn = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:audioSettings];
        aIn.expectsMediaDataInRealTime = YES;
        if ([writer canAddInput:aIn]) {
            [writer addInput:aIn];
        } else {
            aIn = nil;
        }
    }

    if (![writer startWriting]) return nil;

    CoolWriterSlot *slot = [[CoolWriterSlot alloc] init];
    slot.writer         = writer;
    slot.videoInput     = vIn;
    slot.audioInput     = aIn;
    slot.filePath       = path;
    slot.startWallEpoch = [now timeIntervalSince1970];
    return slot;
}

- (void)finalizeSlot:(CoolWriterSlot *)slot {
    if (!slot || !slot.writer) return;
    double startEp = slot.startWallEpoch;
    NSInteger dur  = (NSInteger)MAX(1, round([[NSDate date] timeIntervalSince1970] - startEp));
    NSString *path = slot.filePath;
    BOOL locked    = slot.isLocked;

    dispatch_async(_finalizeQueue, ^{
        if (slot.writer.status == AVAssetWriterStatusWriting) {
            [slot.videoInput markAsFinished];
            if (slot.audioInput) [slot.audioInput markAsFinished];
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            [slot.writer finishWritingWithCompletionHandler:^{
                dispatch_semaphore_signal(sem);
            }];
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)));
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.delegate respondsToSelector:@selector(cameraEngineDidFinishClipAtPath:startEpoch:durationSec:isLocked:)]) {
                [self.delegate cameraEngineDidFinishClipAtPath:path startEpoch:startEp durationSec:dur isLocked:locked];
            }
        });
    });
}

- (void)attachPreviewToView:(UIView *)containerView {
    if (!containerView) return;
    dispatch_async(_captureQueue, ^{
        if (!self->_session) {
            [self refreshThermalPolicy];
            [self setupCaptureSessionIfNeeded];
        }
        AVCaptureSession *sess = self->_session;
        if (!sess) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self->_previewLayer) {
                self->_previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:sess];
                self->_previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
            }
            self->_previewLayer.frame = containerView.bounds;
            if (self->_previewLayer.connection.isVideoOrientationSupported) {
                self->_previewLayer.connection.videoOrientation = AVCaptureVideoOrientationPortrait;
            }
            self->_previewLayer.connection.enabled = YES;
            if (self->_previewLayer.superlayer != containerView.layer) {
                [self->_previewLayer removeFromSuperlayer];
                [containerView.layer insertSublayer:self->_previewLayer atIndex:0];
            }
        });
    });
}

- (void)detachPreview {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_previewLayer) {
            self->_previewLayer.connection.enabled = NO;
            [self->_previewLayer removeFromSuperlayer];
            self->_previewLayer = nil;
        }
    });
}

- (void)startRecording {
    dispatch_async(_captureQueue, ^{
        if (self->_isRecording) return;
        [self refreshThermalPolicy];
        self->_segmentDurationSec = [[DashcamConfig sharedConfig] segmentDurationSeconds];
        if (![self setupCaptureSessionIfNeeded]) return;
        if (!self->_session.isRunning) {
            [self->_session startRunning];
        }
        self->_activeSlot  = [self createWriterSlot];
        self->_standbySlot = nil;
        self->_currentElapsedSec = 0;
        self->_isRecording = (self->_activeSlot != nil);
    });
}

- (void)stopRecording {
    dispatch_async(_captureQueue, ^{
        if (!self->_isRecording) return;
        self->_isRecording = NO;
        CoolWriterSlot *oldActive  = self->_activeSlot;
        CoolWriterSlot *oldStandby = self->_standbySlot;
        self->_activeSlot  = nil;
        self->_standbySlot = nil;
        self->_currentElapsedSec = 0;

        if (oldActive) [self finalizeSlot:oldActive];
        if (oldStandby) {
            [oldStandby.writer cancelWriting];
            [[NSFileManager defaultManager] removeItemAtPath:oldStandby.filePath error:nil];
        }
        if (self->_session.isRunning) {
            [self->_session stopRunning];
        }
    });
}

- (void)lockCurrentSegment {
    dispatch_async(_captureQueue, ^{
        if (self->_activeSlot) {
            self->_activeSlot.isLocked = YES;
            // If shock/tap occurred within first 15s of a new clip, also lock the previous clip!
            if (self->_currentElapsedSec <= 15) {
                [[RingStorageManager sharedManager] lockMostRecentLoopClip];
            }
        }
    });
}

#pragma mark - AVCaptureSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    if (!_isRecording || !CMSampleBufferDataIsReady(sampleBuffer)) return;

    BOOL isVideo = [output isKindOfClass:[AVCaptureVideoDataOutput class]];
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);

    if (isVideo) {
        double now = [[NSDate date] timeIntervalSince1970];
        if (now - _lastThermalCheckEpoch >= 10.0) {
            _lastThermalCheckEpoch = now;
            [self refreshThermalPolicy];
        }

        if (!_activeSlot) {
            _activeSlot = [self createWriterSlot];
            if (!_activeSlot) return;
        }

        if (!_activeSlot.sessionStarted) {
            [_activeSlot.writer startSessionAtSourceTime:pts];
            _activeSlot.firstVideoPTS = pts;
            _activeSlot.startWallEpoch = now;
            _activeSlot.sessionStarted = YES;
        }

        double elapsed = CMTimeGetSeconds(CMTimeSubtract(pts, _activeSlot.firstVideoPTS));
        NSInteger elapsedInt = (NSInteger)MAX(0, floor(elapsed));
        if (elapsedInt != _currentElapsedSec) {
            _currentElapsedSec = elapsedInt;
            NSString *tLabel = [self thermalStateDisplayString];
            NSString *stTxt  = _activeSlot.isLocked ? @"ĐANG QUAY [ĐÃ KHÓA]" : @"ĐANG QUAY";
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([self.delegate respondsToSelector:@selector(cameraEngineDidUpdateStatus:segmentElapsedSec:thermalLabel:)]) {
                    [self.delegate cameraEngineDidUpdateStatus:stTxt segmentElapsedSec:elapsedInt thermalLabel:tLabel];
                }
            });
        }

        // Pre-warm standby writer 3 seconds before cut for 0-frame-loss handover
        if (!_standbySlot && elapsed >= (_segmentDurationSec - 3.0)) {
            _standbySlot = [self createWriterSlot];
        }

        // Seamless Ping-Pong rotation at segment boundary
        if (elapsed >= _segmentDurationSec) {
            CoolWriterSlot *finished = _activeSlot;
            _activeSlot = _standbySlot ?: [self createWriterSlot];
            _standbySlot = nil;
            _currentElapsedSec = 0;

            if (_activeSlot) {
                [_activeSlot.writer startSessionAtSourceTime:pts];
                _activeSlot.firstVideoPTS = pts;
                _activeSlot.startWallEpoch = now;
                _activeSlot.sessionStarted = YES;
            }
            [self finalizeSlot:finished];
        }

        if (_activeSlot && _activeSlot.sessionStarted && _activeSlot.videoInput.isReadyForMoreMediaData) {
            [_activeSlot.videoInput appendSampleBuffer:sampleBuffer];
        }
    } else {
        // Audio buffer
        if (_activeSlot && _activeSlot.sessionStarted && _activeSlot.audioInput && _activeSlot.audioInput.isReadyForMoreMediaData) {
            [_activeSlot.audioInput appendSampleBuffer:sampleBuffer];
        }
    }
}

@end
