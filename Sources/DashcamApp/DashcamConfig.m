// C:/Users/Acer/.gemini/antigravity/scratch/pin-nhiet-do-ts/Sources/DashcamApp/DashcamConfig.m
// Context: Objective-C Implementation / CoolDash6 / iOS 12.0+ arm64 / iPhone 6 (A8)

#import "DashcamConfig.h"

static NSString *const kKeyBotToken      = @"cd6_bot_token";
static NSString *const kKeyChatId        = @"cd6_chat_id";
static NSString *const kKeyHomeSSID      = @"cd6_home_ssid";
static NSString *const kKeyHomeBSSID     = @"cd6_home_bssid";
static NSString *const kKeyProfileMode   = @"cd6_profile_mode";
static NSString *const kKeyRecordAudio   = @"cd6_record_audio";
static NSString *const kKeyEnableGPS     = @"cd6_enable_gps";
static NSString *const kKeyAutoRecord    = @"cd6_auto_record";
static NSString *const kKeyEnableUpload  = @"cd6_enable_upload";
static NSString *const kKeyMeteredMB     = @"cd6_metered_limit_mb";
static NSString *const kKeyMaxLoopGB     = @"cd6_max_loop_gb";
static NSString *const kKeyMaxLockedGB   = @"cd6_max_locked_gb";
static NSString *const kKeyMinFreeGB     = @"cd6_min_free_gb";
static NSString *const kKeyGSensorG      = @"cd6_gsensor_g";

@implementation DashcamConfig

+ (instancetype)sharedConfig {
    static DashcamConfig *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[DashcamConfig alloc] init];
        [inst load];
    });
    return inst;
}

- (void)load {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    _telegramBotToken    = [ud stringForKey:kKeyBotToken] ?: @"";
    _telegramChatId      = [ud stringForKey:kKeyChatId] ?: @"";
    _homeWifiSSID        = [ud stringForKey:kKeyHomeSSID] ?: @"";
    _homeWifiBSSID       = [ud stringForKey:kKeyHomeBSSID] ?: @"";

    _profileMode         = ([ud objectForKey:kKeyProfileMode] != nil)
                           ? [ud integerForKey:kKeyProfileMode]
                           : DashcamProfileEco5Min;
    _recordAudio         = ([ud objectForKey:kKeyRecordAudio] != nil) ? [ud boolForKey:kKeyRecordAudio] : YES;
    _enableGPS           = ([ud objectForKey:kKeyEnableGPS] != nil) ? [ud boolForKey:kKeyEnableGPS] : YES;
    _autoRecordOnLaunch  = ([ud objectForKey:kKeyAutoRecord] != nil) ? [ud boolForKey:kKeyAutoRecord] : YES;
    _enableTelegramUpload= ([ud objectForKey:kKeyEnableUpload] != nil) ? [ud boolForKey:kKeyEnableUpload] : YES;

    NSInteger mb         = [ud integerForKey:kKeyMeteredMB];
    _dailyMeteredLimitMB = (mb >= 100 && mb <= 50000) ? mb : 3500;

    double loopGB        = [ud doubleForKey:kKeyMaxLoopGB];
    _maxLoopStorageGB    = (loopGB >= 2.0 && loopGB <= 100.0) ? loopGB : 30.0;

    double lockGB        = [ud doubleForKey:kKeyMaxLockedGB];
    _maxLockedStorageGB  = (lockGB >= 1.0 && lockGB <= 30.0) ? lockGB : 6.0;

    double freeGB        = [ud doubleForKey:kKeyMinFreeGB];
    _minFreeSpaceGB      = (freeGB >= 1.5 && freeGB <= 20.0) ? freeGB : 4.0;

    double gTh           = [ud doubleForKey:kKeyGSensorG];
    _gSensorThresholdG   = (gTh >= 1.5 && gTh <= 6.0) ? gTh : 2.8;
}

- (void)save {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setObject:(_telegramBotToken ?: @"") forKey:kKeyBotToken];
    [ud setObject:(_telegramChatId ?: @"") forKey:kKeyChatId];
    [ud setObject:(_homeWifiSSID ?: @"") forKey:kKeyHomeSSID];
    [ud setObject:(_homeWifiBSSID ?: @"") forKey:kKeyHomeBSSID];
    [ud setInteger:_profileMode forKey:kKeyProfileMode];
    [ud setBool:_recordAudio forKey:kKeyRecordAudio];
    [ud setBool:_enableGPS forKey:kKeyEnableGPS];
    [ud setBool:_autoRecordOnLaunch forKey:kKeyAutoRecord];
    [ud setBool:_enableTelegramUpload forKey:kKeyEnableUpload];
    [ud setInteger:_dailyMeteredLimitMB forKey:kKeyMeteredMB];
    [ud setDouble:_maxLoopStorageGB forKey:kKeyMaxLoopGB];
    [ud setDouble:_maxLockedStorageGB forKey:kKeyMaxLockedGB];
    [ud setDouble:_minFreeSpaceGB forKey:kKeyMinFreeGB];
    [ud setDouble:_gSensorThresholdG forKey:kKeyGSensorG];
    [ud synchronize];
}

- (NSInteger)segmentDurationSeconds {
    return (_profileMode == DashcamProfileSharp3Min) ? 180 : 300;
}

- (NSInteger)targetFPS {
    return (_profileMode == DashcamProfileSharp3Min) ? 24 : 20;
}

- (NSInteger)videoBitrateBps {
    return (_profileMode == DashcamProfileSharp3Min) ? 1900000 : 1150000;
}

- (NSString *)profileDisplayName {
    return (_profileMode == DashcamProfileSharp3Min) ? @"720p24 • 3p (Nét)" : @"720p20 • 5p (Eco)";
}

- (BOOL)hasValidTelegramConfig {
    NSString *tok = [_telegramBotToken stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *cid = [_telegramChatId stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return (tok.length > 15 && cid.length > 3);
}

@end
