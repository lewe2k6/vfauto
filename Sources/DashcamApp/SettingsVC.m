// C:/Users/Acer/.gemini/antigravity/scratch/pin-nhiet-do-ts/Sources/DashcamApp/SettingsVC.m
// Context: Objective-C Implementation / CoolDash6 Settings UI / iOS 12.0+ arm64

#import "SettingsVC.h"
#import "DashcamConfig.h"
#import "NetworkClassifier.h"
#import "RingStorageManager.h"
#import "TelegramUploader.h"

@interface SettingsVC () <UITextFieldDelegate> {
    UIScrollView *_scroll;
    UITextField *_tfToken;
    UITextField *_tfChatId;
    UITextField *_tfDailyMB;
    UISegmentedControl *_segProfile;
    UISwitch *_swAudio;
    UISwitch *_swGPS;
    UISwitch *_swAutoRec;
    UISwitch *_swUpload;
    UILabel *_lblHomeWifi;
    UILabel *_lblCurrentWifi;
    UILabel *_lblStats;
}
@end

@implementation SettingsVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
    self.title = @"Cài đặt CoolDash6";

    UIBarButtonItem *closeBtn = [[UIBarButtonItem alloc] initWithTitle:@"Xong"
                                                                 style:UIBarButtonItemStyleDone
                                                                target:self
                                                                action:@selector(onSaveAndClose)];
    self.navigationItem.rightBarButtonItem = closeBtn;

    [self buildUI];
    [self populateFromConfig];
}

- (UITextField *)makeTextFieldWithPlaceholder:(NSString *)ph y:(CGFloat)y w:(CGFloat)w {
    UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(16, y, w, 40)];
    tf.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
    tf.textColor = [UIColor whiteColor];
    tf.font = [UIFont systemFontOfSize:14];
    tf.layer.cornerRadius = 8;
    tf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 40)];
    tf.leftViewMode = UITextFieldViewModeAlways;
    tf.autocorrectionType = UITextAutocorrectionTypeNo;
    tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tf.attributedPlaceholder = [[NSAttributedString alloc] initWithString:ph
                                                               attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:0.5 alpha:1.0]}];
    tf.delegate = self;
    return tf;
}

- (UILabel *)makeSectionLabel:(NSString *)text y:(CGFloat)y w:(CGFloat)w {
    UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(16, y, w, 22)];
    lb.text = text;
    lb.textColor = [UIColor colorWithRed:0.25 green:0.85 blue:0.75 alpha:1.0];
    lb.font = [UIFont boldSystemFontOfSize:13];
    return lb;
}

- (UISwitch *)addToggleRow:(NSString *)title y:(CGFloat)y w:(CGFloat)w {
    UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(16, y + 4, w - 65, 24)];
    lb.text = title;
    lb.textColor = [UIColor whiteColor];
    lb.font = [UIFont systemFontOfSize:14];
    [_scroll addSubview:lb];

    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(16 + w - 52, y, 51, 31)];
    sw.onTintColor = [UIColor colorWithRed:0.15 green:0.75 blue:0.65 alpha:1.0];
    [_scroll addSubview:sw];
    return sw;
}

- (UIButton *)makeButton:(NSString *)title color:(UIColor *)bg y:(CGFloat)y w:(CGFloat)w action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(16, y, w, 42);
    b.backgroundColor = bg;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    b.layer.cornerRadius = 8;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)buildUI {
    CGFloat sw = self.view.bounds.size.width;
    CGFloat sh = self.view.bounds.size.height;
    CGFloat w  = sw - 32;

    _scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 0, sw, sh)];
    _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:_scroll];

    CGFloat y = 16;

    // 1. Profile
    [_scroll addSubview:[self makeSectionLabel:@"CHẾ ĐỘ QUAY H.264 PHẦN CỨNG (A8)" y:y w:w]];
    y += 26;
    _segProfile = [[UISegmentedControl alloc] initWithItems:@[@"Eco 5p (1.15Mbps)", @"Nét 3p (1.9Mbps)"]];
    _segProfile.frame = CGRectMake(16, y, w, 34);
    _segProfile.tintColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.7 alpha:1.0];
    [_scroll addSubview:_segProfile];
    y += 48;

    // 2. Toggles
    _swAudio   = [self addToggleRow:@"Ghi âm Mono 32kbps (lưu đối thoại)" y:y w:w]; y += 42;
    _swGPS     = [self addToggleRow:@"Ghi tốc độ & tọa độ GPS lên Caption" y:y w:w]; y += 42;
    _swAutoRec = [self addToggleRow:@"Tự động quay ngay khi mở app" y:y w:w]; y += 42;
    _swUpload  = [self addToggleRow:@"Bật tự động đồng bộ lên Telegram" y:y w:w]; y += 50;

    // 3. Telegram Config
    [_scroll addSubview:[self makeSectionLabel:@"TELEGRAM PRIVATE CHANNEL (BOT API < 50MB)" y:y w:w]];
    y += 26;
    _tfToken = [self makeTextFieldWithPlaceholder:@"Bot Token (vd: 123456:ABC-DEF...)" y:y w:w];
    [_scroll addSubview:_tfToken];
    y += 48;

    _tfChatId = [self makeTextFieldWithPlaceholder:@"Chat ID kênh riêng (vd: -1001234567890)" y:y w:w];
    [_scroll addSubview:_tfChatId];
    y += 48;

    [_scroll addSubview:[self makeButton:@"Gửi tin nhắn test Telegram"
                                   color:[UIColor colorWithRed:0.15 green:0.45 blue:0.75 alpha:1.0]
                                       y:y w:w action:@selector(onTestTelegram)]];
    y += 56;

    // 4. Metered Hotspot vs Home Wi-Fi
    [_scroll addSubview:[self makeSectionLabel:@"PHÂN BIỆT HOTSPOT ANDROID & WI-FI NHÀ" y:y w:w]];
    y += 26;

    _lblCurrentWifi = [[UILabel alloc] initWithFrame:CGRectMake(16, y, w, 20)];
    _lblCurrentWifi.textColor = [UIColor colorWithWhite:0.78 alpha:1.0];
    _lblCurrentWifi.font = [UIFont systemFontOfSize:13];
    [_scroll addSubview:_lblCurrentWifi];
    y += 24;

    _lblHomeWifi = [[UILabel alloc] initWithFrame:CGRectMake(16, y, w, 20)];
    _lblHomeWifi.textColor = [UIColor colorWithRed:0.35 green:0.9 blue:0.5 alpha:1.0];
    _lblHomeWifi.font = [UIFont boldSystemFontOfSize:13];
    [_scroll addSubview:_lblHomeWifi];
    y += 28;

    [_scroll addSubview:[self makeButton:@"Lưu Wi-Fi hiện tại là Wi-Fi Nhà (Xả Unlimited)"
                                   color:[UIColor colorWithRed:0.12 green:0.55 blue:0.35 alpha:1.0]
                                       y:y w:w action:@selector(onSaveCurrentAsHomeWifi)]];
    y += 52;

    UILabel *lbQuota = [[UILabel alloc] initWithFrame:CGRectMake(16, y + 8, w - 110, 22)];
    lbQuota.text = @"Trần data Hotspot/4G mỗi ngày (MB):";
    lbQuota.textColor = [UIColor whiteColor];
    lbQuota.font = [UIFont systemFontOfSize:13];
    [_scroll addSubview:lbQuota];

    _tfDailyMB = [self makeTextFieldWithPlaceholder:@"3500" y:y w:96];
    _tfDailyMB.frame = CGRectMake(16 + w - 96, y, 96, 38);
    _tfDailyMB.keyboardType = UIKeyboardTypeNumberPad;
    _tfDailyMB.textAlignment = NSTextAlignmentCenter;
    [_scroll addSubview:_tfDailyMB];
    y += 50;

    // 5. Storage & Quota stats
    _lblStats = [[UILabel alloc] initWithFrame:CGRectMake(16, y, w, 72)];
    _lblStats.numberOfLines = 4;
    _lblStats.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    _lblStats.font = [UIFont systemFontOfSize:12];
    [_scroll addSubview:_lblStats];
    y += 82;

    [_scroll addSubview:[self makeButton:@"Reset bộ đếm 4G hôm nay về 0 MB"
                                   color:[UIColor colorWithWhite:0.25 alpha:1.0]
                                       y:y w:w action:@selector(onResetQuota)]];
    y += 64;

    _scroll.contentSize = CGSizeMake(sw, y);
}

- (void)populateFromConfig {
    DashcamConfig *cfg = [DashcamConfig sharedConfig];
    _segProfile.selectedSegmentIndex = (cfg.profileMode == DashcamProfileSharp3Min) ? 1 : 0;
    _swAudio.on   = cfg.recordAudio;
    _swGPS.on     = cfg.enableGPS;
    _swAutoRec.on = cfg.autoRecordOnLaunch;
    _swUpload.on  = cfg.enableTelegramUpload;
    _tfToken.text = cfg.telegramBotToken;
    _tfChatId.text = cfg.telegramChatId;
    _tfDailyMB.text = [NSString stringWithFormat:@"%ld", (long)cfg.dailyMeteredLimitMB];
    [self refreshLabels];
}

- (void)refreshLabels {
    [[NetworkClassifier sharedClassifier] refreshNow];
    NetworkClassifier *nc = [NetworkClassifier sharedClassifier];
    DashcamConfig *cfg = [DashcamConfig sharedConfig];

    _lblCurrentWifi.text = [NSString stringWithFormat:@"Mạng hiện tại: %@ (%@)",
                            nc.currentSSID.length > 0 ? nc.currentSSID : @"Không đọc được SSID",
                            nc.currentBSSID.length > 0 ? nc.currentBSSID : @"--"];
    _lblHomeWifi.text = [NSString stringWithFormat:@"Wi-Fi Nhà đã lưu: %@",
                         cfg.homeWifiSSID.length > 0 ? cfg.homeWifiSSID : @"Chưa lưu (mọi mạng đều giới hạn 4G)"];

    RingStorageManager *st = [RingStorageManager sharedManager];
    double meteredMB = (double)[st todayMeteredBytesSent] / (1024.0 * 1024.0);
    double homeMB    = (double)[st todayHomeBytesSent] / (1024.0 * 1024.0);
    _lblStats.text = [NSString stringWithFormat:
                      @"Trống hệ thống: %.2f GB | Vòng lặp: %.2f / %.0f GB | Đã khóa: %.2f / %.0f GB\n"
                      @"Đã đẩy Hotspot hôm nay: %.1f / %ld MB | Wi-Fi nhà: %.1f MB\n"
                      @"Đang chờ gửi: %ld clip (Khóa: %ld)",
                      [st freeDiskSpaceGB], [st loopFolderSizeGB], cfg.maxLoopStorageGB,
                      [st lockedFolderSizeGB], cfg.maxLockedStorageGB,
                      meteredMB, (long)cfg.dailyMeteredLimitMB, homeMB,
                      (long)[st pendingUploadCount], (long)[st pendingLockedCount]];
}

- (void)applyFieldsToConfig {
    DashcamConfig *cfg = [DashcamConfig sharedConfig];
    cfg.profileMode = (_segProfile.selectedSegmentIndex == 1) ? DashcamProfileSharp3Min : DashcamProfileEco5Min;
    cfg.recordAudio = _swAudio.on;
    cfg.enableGPS   = _swGPS.on;
    cfg.autoRecordOnLaunch   = _swAutoRec.on;
    cfg.enableTelegramUpload = _swUpload.on;
    cfg.telegramBotToken = [_tfToken.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    cfg.telegramChatId   = [_tfChatId.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    NSInteger mb = [_tfDailyMB.text integerValue];
    if (mb >= 100 && mb <= 50000) cfg.dailyMeteredLimitMB = mb;
    [cfg save];
}

- (void)onSaveCurrentAsHomeWifi {
    [[NetworkClassifier sharedClassifier] refreshNow];
    NetworkClassifier *nc = [NetworkClassifier sharedClassifier];
    if (nc.currentSSID.length == 0) {
        [self showAlert:@"Không đọc được tên Wi-Fi"
                message:@"Hãy bật Vị trí (Location) cho CoolDash6 và kết nối vào Wi-Fi nhà trước khi bấm nút này."];
        return;
    }
    DashcamConfig *cfg = [DashcamConfig sharedConfig];
    cfg.homeWifiSSID  = nc.currentSSID;
    cfg.homeWifiBSSID = nc.currentBSSID;
    [cfg save];
    [[NetworkClassifier sharedClassifier] refreshNow];
    [self refreshLabels];
    [self showAlert:@"Đã lưu Wi-Fi Nhà"
            message:[NSString stringWithFormat:@"Wi-Fi '%@' sẽ được xả clip không giới hạn. Mọi Wi-Fi/Hotspot khác vẫn khóa trần %ld MB/ngày.",
                     cfg.homeWifiSSID, (long)cfg.dailyMeteredLimitMB]];
}

- (void)onTestTelegram {
    [self applyFieldsToConfig];
    [[TelegramUploader sharedUploader] testBotConnectionWithCompletion:^(BOOL ok, NSString *message) {
        [self showAlert:(ok ? @"Thành công" : @"Lỗi kết nối") message:message];
    }];
}

- (void)onResetQuota {
    [[RingStorageManager sharedManager] resetTodayQuota];
    [self refreshLabels];
}

- (void)onSaveAndClose {
    [self applyFieldsToConfig];
    [[NetworkClassifier sharedClassifier] refreshNow];
    [[TelegramUploader sharedUploader] triggerNow];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)showAlert:(NSString *)title message:(NSString *)msg {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

@end
