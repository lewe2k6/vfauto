#import "SecretConfigViewController.h"
#import "CoordinatePickerViewController.h"
#import "SharedConfig.h"
#import "PureQRCode.h"
#import <notify.h>

@implementation SecretConfigViewController {
    FilterConfig *_cfg;
    UIScrollView *_scrollView;
    UIStackView *_stackView;

    // Card 0: Live Status, Map Relay Status, Pause Countdown & Counters
    UILabel *_daemonStatusLabel;
    UILabel *_phaseLabel;
    UILabel *_lastMapRelayLabel;
    UIButton *_skipPauseBtn;
    UILabel *_statsLabel;

    // Card 1: Core Switches & Green Food Min Price
    UISwitch *_swMaster;
    UISwitch *_swSmartCool;
    UISwitch *_swAutoBike;
    UISwitch *_swRejectAllFood;
    UILabel  *_lblMinFoodPrice;
    UIView   *_priceControlRow;
    UISwitch *_swHaptic;
    UISwitch *_swDryRun;

    // Card 1B: Hanoi Food TTTM / Crowded Chain Blacklist & Distance (>3km) Filter
    UIStackView *_foodSmartFilterCardBody;
    UISwitch *_swBlockMall;
    UISwitch *_swBlockChains;
    UILabel  *_lblMaxMerchantOrders; UISlider *_slMaxMerchantOrders;
    UISwitch *_swAcceptLongDist;
    UILabel  *_lblMinFoodDistKm;     UISlider *_slMinFoodDistKm;
    UIView   *_distSliderWrap;

    // Card 2: 2-Min Pause & Kill/Relaunch Driver App
    UISwitch *_swPauseFood;
    UILabel  *_lblPauseSec;    UISlider *_slPauseSec;
    UISwitch *_swAutoKill;
    UILabel  *_lblRelaunchSec; UISlider *_slRelaunchSec;
    UILabel  *_lblDriverApp;

    // Card 3: Navigation Relay Bridge (iPhone 8 -> Second Phone)
    UILabel     *_lblGmapsStatus;
    UISwitch    *_swMapRelay;
    UISwitch    *_swMapReturn;
    UIImageView *_qrImageView;
    UILabel     *_lblMapTopic;
    NSString    *_lastRenderedQRTopic;
    NSTimeInterval _lastGmapsCheckEpoch;
    BOOL         _cachedGmapsInstalled;
    BOOL         _gmapsCheckInFlight;

    // Card 4: 4 Coordinates Calibration
    UISegmentedControl *_segCoordMode;
    UIStackView *_autoCoordGroup;
    UIStackView *_manualCoordGroup;

    UILabel *_lblCloseRatio;   UISlider *_slCloseRatio;
    UILabel *_lblCloseOffX;    UISlider *_slCloseOffX;
    UILabel *_lblCloseOffY;    UISlider *_slCloseOffY;
    UILabel *_lblAcceptOffX;   UISlider *_slAcceptOffX;
    UILabel *_lblAcceptOffY;   UISlider *_slAcceptOffY;
    UILabel *_lblOnlineOffX;   UISlider *_slOnlineOffX;
    UILabel *_lblOnlineOffY;   UISlider *_slOnlineOffY;

    UILabel *_lblManCloseX;    UISlider *_slManCloseX;
    UILabel *_lblManCloseY;    UISlider *_slManCloseY;
    UILabel *_lblManAcceptX;   UISlider *_slManAcceptX;
    UILabel *_lblManAcceptY;   UISlider *_slManAcceptY;
    UILabel *_lblManOfflineX;  UISlider *_slManOfflineX;
    UILabel *_lblManOfflineY;  UISlider *_slManOfflineY;
    UILabel *_lblManOnlineX;   UISlider *_slManOnlineX;
    UILabel *_lblManOnlineY;   UISlider *_slManOnlineY;

    // Card 5: Timing & Humanizer + Live Log
    UILabel *_lblTapRetries;   UISlider *_slTapRetries;
    UILabel *_lblScanMs;       UISlider *_slScanMs;
    UILabel *_lblAccMinMs;     UISlider *_slAccMinMs;
    UILabel *_lblAccMaxMs;     UISlider *_slAccMaxMs;
    UILabel *_lblRejMinMs;     UISlider *_slRejMinMs;
    UILabel *_lblRejMaxMs;     UISlider *_slRejMaxMs;
    UILabel *_lblJitter;       UISlider *_slJitter;
    UILabel *_lblHoldMin;      UISlider *_slHoldMin;
    UILabel *_lblHoldMax;      UISlider *_slHoldMax;
    UILabel *_lblCooldown;     UISlider *_slCooldown;

    UITextView *_logTextView;
    NSTimer *_refreshTimer;
    NSTimer *_sliderSaveTimer;
    BOOL _hasPendingSliderSave;
    NSTimeInterval _lastAutoHealEpoch;
    int _statsNotifyToken;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Tinh Chỉnh Lọc Đơn v5.0.1";
    self.view.backgroundColor = [UIColor colorWithRed:0.06 green:0.07 blue:0.09 alpha:1.0];

    UIBarButtonItem *closeItem = [[UIBarButtonItem alloc] initWithTitle:@"Đóng"
                                                                  style:UIBarButtonItemStyleDone
                                                                 target:self
                                                                 action:@selector(closePanel)];
    closeItem.tintColor = [UIColor systemTealColor];
    self.navigationItem.rightBarButtonItem = closeItem;

    upgradeSharedFilesProtectionNone();
    _cfg = [FilterConfig loadFromDisk];
    if (_cfg.masterEnabled) {
        _lastAutoHealEpoch = [[NSDate date] timeIntervalSince1970];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            startFilterDaemonIfNeeded();
        });
    }

    [self buildScrollLayout];
    [self syncUIFromConfig];
    [self refreshStatusAndLogs];

    __weak typeof(self) weakSelf = self;
    notify_register_dispatch(kNotifyStatsUpdated, &_statsNotifyToken, dispatch_get_main_queue(), ^(int token) {
        [weakSelf refreshStatusAndLogs];
    });

    _refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                     target:self
                                                   selector:@selector(refreshStatusAndLogs)
                                                   userInfo:nil
                                                    repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (_hasPendingSliderSave) {
        [_sliderSaveTimer invalidate];
        _sliderSaveTimer = nil;
        _hasPendingSliderSave = NO;
        [_cfg saveToDiskAndNotify:YES];
    }
    if (self.isBeingDismissed || self.navigationController.isBeingDismissed) {
        [_refreshTimer invalidate];
        _refreshTimer = nil;
        if (_statsNotifyToken != 0) {
            notify_cancel(_statsNotifyToken);
            _statsNotifyToken = 0;
        }
    }
}

- (void)closePanel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - UI Helpers

- (UIView *)makeCardWithTitle:(NSString *)title addTo:(UIStackView *)parent outBody:(UIStackView * __strong *)outBody {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [UIColor colorWithRed:0.12 green:0.13 blue:0.16 alpha:1.0];
    card.layer.cornerRadius = 14;

    UIStackView *vStack = [[UIStackView alloc] init];
    vStack.axis = UILayoutConstraintAxisVertical;
    vStack.spacing = 12;
    vStack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:vStack];

    [NSLayoutConstraint activateConstraints:@[
        [vStack.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [vStack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
        [vStack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [vStack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14]
    ]];

    if (title.length > 0) {
        UILabel *hdr = [[UILabel alloc] init];
        hdr.text = title.uppercaseString;
        hdr.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
        hdr.textColor = [UIColor colorWithRed:0.0 green:0.78 blue:0.72 alpha:1.0];
        [vStack addArrangedSubview:hdr];
    }

    [parent addArrangedSubview:card];
    if (outBody) *outBody = vStack;
    return card;
}

- (UISwitch *)addSwitchRowTo:(UIStackView *)stack title:(NSString *)title subtitle:(NSString *)sub action:(SEL)sel {
    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 8;

    UIStackView *txtStack = [[UIStackView alloc] init];
    txtStack.axis = UILayoutConstraintAxisVertical;
    txtStack.spacing = 2;

    UILabel *lbl = [[UILabel alloc] init];
    lbl.text = title;
    lbl.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightSemibold];
    lbl.textColor = [UIColor whiteColor];
    lbl.numberOfLines = 0;
    [txtStack addArrangedSubview:lbl];

    if (sub.length > 0) {
        UILabel *sLbl = [[UILabel alloc] init];
        sLbl.text = sub;
        sLbl.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];
        sLbl.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
        sLbl.numberOfLines = 0;
        [txtStack addArrangedSubview:sLbl];
    }

    UISwitch *sw = [[UISwitch alloc] init];
    sw.onTintColor = [UIColor colorWithRed:0.0 green:0.75 blue:0.68 alpha:1.0];
    [sw addTarget:self action:sel forControlEvents:UIControlEventValueChanged];

    [row addArrangedSubview:txtStack];
    [row addArrangedSubview:sw];
    [stack addArrangedSubview:row];
    return sw;
}

- (UISlider *)addSliderRowTo:(UIStackView *)stack
                         min:(float)minVal
                         max:(float)maxVal
                    outLabel:(UILabel * __strong *)outLbl
                      action:(SEL)sel {
    UIStackView *wrap = [[UIStackView alloc] init];
    wrap.axis = UILayoutConstraintAxisVertical;
    wrap.spacing = 4;

    UILabel *lbl = [[UILabel alloc] init];
    lbl.font = [UIFont monospacedDigitSystemFontOfSize:12.5 weight:UIFontWeightMedium];
    lbl.textColor = [UIColor colorWithWhite:0.90 alpha:1.0];
    lbl.numberOfLines = 0;
    [wrap addArrangedSubview:lbl];

    UISlider *sl = [[UISlider alloc] init];
    sl.minimumValue = minVal;
    sl.maximumValue = maxVal;
    sl.minimumTrackTintColor = [UIColor colorWithRed:0.0 green:0.75 blue:0.68 alpha:1.0];
    [sl addTarget:self action:sel forControlEvents:UIControlEventValueChanged];
    [wrap addArrangedSubview:sl];

    [stack addArrangedSubview:wrap];
    if (outLbl) *outLbl = lbl;
    return sl;
}

- (UIButton *)makeStepButton:(NSString *)title tag:(NSInteger)tag action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightBold];
    b.backgroundColor = [UIColor colorWithWhite:0.22 alpha:1.0];
    b.layer.cornerRadius = 8;
    b.tag = tag;
    [b.heightAnchor constraintEqualToConstant:36].active = YES;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)buildScrollLayout {
    _scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scrollView.alwaysBounceVertical = YES;
    [self.view addSubview:_scrollView];

    _stackView = [[UIStackView alloc] init];
    _stackView.axis = UILayoutConstraintAxisVertical;
    _stackView.spacing = 14;
    _stackView.translatesAutoresizingMaskIntoConstraints = NO;
    [_scrollView addSubview:_stackView];

    [NSLayoutConstraint activateConstraints:@[
        [_stackView.topAnchor constraintEqualToAnchor:_scrollView.topAnchor constant:14],
        [_stackView.bottomAnchor constraintEqualToAnchor:_scrollView.bottomAnchor constant:-32],
        [_stackView.leadingAnchor constraintEqualToAnchor:_scrollView.leadingAnchor constant:12],
        [_stackView.trailingAnchor constraintEqualToAnchor:_scrollView.trailingAnchor constant:-12],
        [_stackView.widthAnchor constraintEqualToAnchor:_scrollView.widthAnchor constant:-24]
    ]];

    // --- CARD 0: LIVE STATUS, MAP RELAY & COUNTDOWN ---
    UIStackView *statBody = nil;
    [self makeCardWithTitle:@"Trạng Thái Trực Tiếp & Cầu Nối Map" addTo:_stackView outBody:&statBody];

    _daemonStatusLabel = [[UILabel alloc] init];
    _daemonStatusLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightBold];
    [statBody addArrangedSubview:_daemonStatusLabel];

    _phaseLabel = [[UILabel alloc] init];
    _phaseLabel.font = [UIFont monospacedDigitSystemFontOfSize:12.5 weight:UIFontWeightSemibold];
    _phaseLabel.textColor = [UIColor systemYellowColor];
    _phaseLabel.numberOfLines = 0;
    [statBody addArrangedSubview:_phaseLabel];

    _skipPauseBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [_skipPauseBtn setTitle:@"Bỏ Qua Đếm Ngược Nghỉ — Bật Lại Ngay!" forState:UIControlStateNormal];
    [_skipPauseBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _skipPauseBtn.titleLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightBold];
    _skipPauseBtn.backgroundColor = [UIColor systemOrangeColor];
    _skipPauseBtn.layer.cornerRadius = 8;
    [_skipPauseBtn.heightAnchor constraintEqualToConstant:38].active = YES;
    _skipPauseBtn.hidden = YES;
    [_skipPauseBtn addTarget:self action:@selector(skipPauseTapped) forControlEvents:UIControlEventTouchUpInside];
    [statBody addArrangedSubview:_skipPauseBtn];

    _lastMapRelayLabel = [[UILabel alloc] init];
    _lastMapRelayLabel.font = [UIFont monospacedDigitSystemFontOfSize:11.8 weight:UIFontWeightMedium];
    _lastMapRelayLabel.textColor = [UIColor colorWithRed:0.35 green:0.92 blue:0.86 alpha:1.0];
    _lastMapRelayLabel.numberOfLines = 0;
    [statBody addArrangedSubview:_lastMapRelayLabel];

    UIStackView *statRow = [[UIStackView alloc] init];
    statRow.axis = UILayoutConstraintAxisHorizontal;
    statRow.alignment = UIStackViewAlignmentCenter;

    _statsLabel = [[UILabel alloc] init];
    _statsLabel.font = [UIFont monospacedDigitSystemFontOfSize:12.5 weight:UIFontWeightMedium];
    _statsLabel.textColor = [UIColor colorWithWhite:0.88 alpha:1.0];
    [statRow addArrangedSubview:_statsLabel];

    UIButton *resetStatBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [resetStatBtn setTitle:@"Reset số" forState:UIControlStateNormal];
    [resetStatBtn setTitleColor:[UIColor systemOrangeColor] forState:UIControlStateNormal];
    resetStatBtn.titleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
    [resetStatBtn addTarget:self action:@selector(resetStatsTapped) forControlEvents:UIControlEventTouchUpInside];
    [statRow addArrangedSubview:resetStatBtn];
    [statBody addArrangedSubview:statRow];

    UIStackView *actionRow = [[UIStackView alloc] init];
    actionRow.axis = UILayoutConstraintAxisHorizontal;
    actionRow.distribution = UIStackViewDistributionFillEqually;
    actionRow.spacing = 8;

    UIButton *diagBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [diagBtn setTitle:@"Test Quét Màn (4s)" forState:UIControlStateNormal];
    [diagBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    diagBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    diagBtn.backgroundColor = [UIColor colorWithRed:0.16 green:0.45 blue:0.82 alpha:1.0];
    diagBtn.layer.cornerRadius = 8;
    [diagBtn.heightAnchor constraintEqualToConstant:40].active = YES;
    [diagBtn addTarget:self action:@selector(diagCaptureTapped) forControlEvents:UIControlEventTouchUpInside];

    UIButton *restartDaemonBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [restartDaemonBtn setTitle:@"Làm Mới Lõi Ngầm" forState:UIControlStateNormal];
    [restartDaemonBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    restartDaemonBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    restartDaemonBtn.backgroundColor = [UIColor colorWithRed:0.0 green:0.58 blue:0.50 alpha:1.0];
    restartDaemonBtn.layer.cornerRadius = 8;
    [restartDaemonBtn.heightAnchor constraintEqualToConstant:40].active = YES;
    [restartDaemonBtn addTarget:self action:@selector(forceRestartDaemonTapped) forControlEvents:UIControlEventTouchUpInside];

    [actionRow addArrangedSubview:diagBtn];
    [actionRow addArrangedSubview:restartDaemonBtn];
    [statBody addArrangedSubview:actionRow];

    // --- CARD 1: FILTER & GREEN FOOD MIN PRICE ---
    UIStackView *sec1 = nil;
    [self makeCardWithTitle:@"1. Lọc Đơn, Hạ Nhiệt & Ngưỡng Giá Food" addTo:_stackView outBody:&sec1];

    _swMaster = [self addSwitchRowTo:sec1
                               title:@"Chạy Lõi Auto Bất Tử (Master)"
                            subtitle:@"Watchdog 2 tầng tự hồi sinh ngầm 24/7 trên iPhone 8 2GB"
                              action:@selector(masterSwitchChanged:)];

    _swSmartCool = [self addSwitchRowTo:sec1
                                  title:@"Chế độ Siêu Mát (Smart-Sleep Hạ Nhiệt)"
                               subtitle:@"Ngắt 100% quét khi đang mở Google Maps/khóa máy & chống gọi AI thừa"
                                 action:@selector(generalControlChanged)];

    _swAutoBike = [self addSwitchRowTo:sec1
                                 title:@"Tự động [Nhận] Bike, Express, Express 2H..."
                              subtitle:@"Đớp trọn mọi đơn chở khách & giao hàng (chỉ lọc riêng Green Food)"
                                action:@selector(generalControlChanged)];

    _swRejectAllFood = [self addSwitchRowTo:sec1
                                      title:@"Hủy sạch 100% Green Food (Mọi giá)"
                                   subtitle:@"Tắt mục này để nhận đơn Food từ mức giá bên dưới"
                                     action:@selector(generalControlChanged)];

    UIStackView *priceWrap = [[UIStackView alloc] init];
    priceWrap.axis = UILayoutConstraintAxisVertical;
    priceWrap.spacing = 8;

    _lblMinFoodPrice = [[UILabel alloc] init];
    _lblMinFoodPrice.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightBold];
    _lblMinFoodPrice.textColor = [UIColor systemGreenColor];
    _lblMinFoodPrice.numberOfLines = 0;
    _lblMinFoodPrice.userInteractionEnabled = YES;
    [_lblMinFoodPrice addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(promptExactFoodPrice)]];
    [priceWrap addArrangedSubview:_lblMinFoodPrice];

    UIStackView *btnRow = [[UIStackView alloc] init];
    btnRow.axis = UILayoutConstraintAxisHorizontal;
    btnRow.distribution = UIStackViewDistributionFillEqually;
    btnRow.spacing = 6;
    [btnRow addArrangedSubview:[self makeStepButton:@"-5k" tag:-5000 action:@selector(stepFoodPrice:)]];
    [btnRow addArrangedSubview:[self makeStepButton:@"-1k" tag:-1000 action:@selector(stepFoodPrice:)]];
    [btnRow addArrangedSubview:[self makeStepButton:@"+1k" tag:1000  action:@selector(stepFoodPrice:)]];
    [btnRow addArrangedSubview:[self makeStepButton:@"+5k" tag:5000  action:@selector(stepFoodPrice:)]];
    [btnRow addArrangedSubview:[self makeStepButton:@"Nhập" tag:0    action:@selector(promptExactFoodPrice)]];
    [priceWrap addArrangedSubview:btnRow];

    _priceControlRow = priceWrap;
    [sec1 addArrangedSubview:priceWrap];

    _swHaptic = [self addSwitchRowTo:sec1
                               title:@"Báo rung Haptic"
                            subtitle:@"Rung 1 nhịp khi hủy/bắn Map, rung 2 nhịp khi Nhận"
                              action:@selector(generalControlChanged)];

    _swDryRun = [self addSwitchRowTo:sec1
                               title:@"Chế độ Chạy Thử (Dry-Run)"
                            subtitle:@"Chỉ đọc chữ + ghi Log, KHÔNG chạm thật"
                              action:@selector(generalControlChanged)];

    // --- CARD 1B: HANOI GREEN FOOD TTTM/CHAIN BLACKLIST & >3KM DISTANCE ---
    UIStackView *sec1B = nil;
    [self makeCardWithTitle:@"1B. Chặn TTTM/Quán Đông 3 Sàn & Đo Km Food (>3km)" addTo:_stackView outBody:&sec1B];
    _foodSmartFilterCardBody = sec1B;

    _swBlockMall = [self addSwitchRowTo:sec1B
                                  title:@"Chặn cứng TTTM, Tầng Hầm & Gian Hàng"
                               subtitle:@"Điểm nhận trúng TTTM / Hầm B1-B2 / Kiosk (DB 74.496 quán Xanh-Shopee-Grab + Từ khóa, tự miễn trừ 'Đối diện/Cạnh') -> Bấm [X] 100%"
                                 action:@selector(generalControlChanged)];

    _swBlockChains = [self addSwitchRowTo:sec1B
                                    title:@"Chặn cứng Chuỗi Quán Đông Chờ Lâu"
                                 subtitle:@"Phê La, Chú Long, Katinat, Phúc Long, Lotteria, KFC, Pizza Home, Kaoya, Yu Tang, Cơm Sườn Đào Duy Từ... -> Bấm [X] 100%"
                                   action:@selector(generalControlChanged)];

    _slMaxMerchantOrders = [self addSliderRowTo:sec1B min:0.0f max:20000.0f outLabel:&_lblMaxMerchantOrders action:@selector(sliderChanged)];

    UIStackView *kwBtnRow = [[UIStackView alloc] init];
    kwBtnRow.axis = UILayoutConstraintAxisHorizontal;
    kwBtnRow.distribution = UIStackViewDistributionFillEqually;
    kwBtnRow.spacing = 8;

    UIButton *editMallKwBtn = [self makeStepButton:@"Sửa Từ Khóa TTTM" tag:1 action:@selector(openKeywordEditorTapped:)];
    editMallKwBtn.backgroundColor = [UIColor colorWithRed:0.18 green:0.32 blue:0.52 alpha:1.0];
    UIButton *editChainKwBtn = [self makeStepButton:@"Sửa Quán Đông" tag:2 action:@selector(openKeywordEditorTapped:)];
    editChainKwBtn.backgroundColor = [UIColor colorWithRed:0.42 green:0.24 blue:0.46 alpha:1.0];
    [kwBtnRow addArrangedSubview:editMallKwBtn];
    [kwBtnRow addArrangedSubview:editChainKwBtn];
    [sec1B addArrangedSubview:kwBtnRow];

    _swAcceptLongDist = [self addSwitchRowTo:sec1B
                                       title:@"Quán Sạch: Nhận Cả Khi Đường Giao > Km"
                                    subtitle:@"Thỏa Một Trong Hai: Giá >= Mức tối thiểu HOẶC Quãng đường Điểm nhận -> Điểm giao > ngưỡng km bên dưới"
                                      action:@selector(generalControlChanged)];

    _slMinFoodDistKm = [self addSliderRowTo:sec1B min:1.0f max:10.0f outLabel:&_lblMinFoodDistKm action:@selector(sliderChanged)];
    _distSliderWrap  = _slMinFoodDistKm.superview;

    // --- CARD 2: 2-MINUTE PAUSE & KILL/RELAUNCH DRIVER APP ---
    UIStackView *sec2 = nil;
    [self makeCardWithTitle:@"2. Nghỉ 2 Phút & Kill App Sau Khi [X] Food" addTo:_stackView outBody:&sec2];

    _swPauseFood = [self addSwitchRowTo:sec2
                                  title:@"Tắt nhận chuyến sau khi [X] đơn Food"
                               subtitle:@"Bấm nút tròn [⏻] nghỉ xả luồng Food rồi tự bật lại"
                                 action:@selector(generalControlChanged)];

    _slPauseSec = [self addSliderRowTo:sec2 min:30.0f max:600.0f outLabel:&_lblPauseSec action:@selector(sliderChanged)];

    _swAutoKill = [self addSwitchRowTo:sec2
                                 title:@"Tự động Kill & Mở lại App Tài Xế"
                              subtitle:@"Đóng sạch app xả RAM sau khi Offline, tự mở lại trước khi hết giờ (Tắt mục này nếu muốn tự tay vuốt Kill)"
                                action:@selector(generalControlChanged)];

    _slRelaunchSec = [self addSliderRowTo:sec2 min:8.0f max:35.0f outLabel:&_lblRelaunchSec action:@selector(sliderChanged)];

    _lblDriverApp = [[UILabel alloc] init];
    _lblDriverApp.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
    _lblDriverApp.textColor = [UIColor systemTealColor];
    _lblDriverApp.numberOfLines = 0;
    [sec2 addArrangedSubview:_lblDriverApp];

    UIStackView *appBtnRow = [[UIStackView alloc] init];
    appBtnRow.axis = UILayoutConstraintAxisHorizontal;
    appBtnRow.distribution = UIStackViewDistributionFillEqually;
    appBtnRow.spacing = 8;

    UIButton *pickAppBtn = [self makeStepButton:@"Chọn App Tài Xế" tag:0 action:@selector(pickDriverAppTapped)];
    UIButton *testKillBtn = [self makeStepButton:@"Test Kill & Mở Lại" tag:0 action:@selector(testKillAndRelaunchTapped)];
    testKillBtn.backgroundColor = [UIColor colorWithRed:0.45 green:0.20 blue:0.15 alpha:1.0];
    [appBtnRow addArrangedSubview:pickAppBtn];
    [appBtnRow addArrangedSubview:testKillBtn];
    [sec2 addArrangedSubview:appBtnRow];

    // --- CARD 3: NAVIGATION RELAY BRIDGE (IPHONE 8 -> SECOND PHONE) ---
    UIStackView *sec3 = nil;
    [self makeCardWithTitle:@"3. Bắn Định Vị Map Sang Máy Thứ 2 (0% Tốn RAM Máy 8)" addTo:_stackView outBody:&sec3];

    _lblGmapsStatus = [[UILabel alloc] init];
    _lblGmapsStatus.font = [UIFont systemFontOfSize:12.2 weight:UIFontWeightSemibold];
    _lblGmapsStatus.numberOfLines = 0;
    [sec3 addArrangedSubview:_lblGmapsStatus];

    _swMapRelay = [self addSwitchRowTo:sec3
                                 title:@"Bắt Nút 'Điều Hướng' -> Bắn Sang Máy Kia"
                              subtitle:@"Gỡ Google Maps trên iPhone 8: Bấm 'Điều hướng' trong Xanh SM là tọa độ vệ tinh bắn thẳng sang máy thứ 2"
                                action:@selector(generalControlChanged)];

    _swMapReturn = [self addSwitchRowTo:sec3
                                  title:@"Tự Quay Lại Xanh SM Ngay Lập Tức (0.08s)"
                               subtitle:@"Màn hình iPhone 8 đứng yên ở Xanh SM, không bị văng ra ngoài"
                                 action:@selector(generalControlChanged)];

    UIStackView *qrRow = [[UIStackView alloc] init];
    qrRow.axis = UILayoutConstraintAxisVertical;
    qrRow.alignment = UIStackViewAlignmentCenter;
    qrRow.spacing = 8;

    _qrImageView = [[UIImageView alloc] init];
    _qrImageView.backgroundColor = [UIColor whiteColor];
    _qrImageView.layer.cornerRadius = 12;
    _qrImageView.clipsToBounds = YES;
    _qrImageView.contentMode = UIViewContentModeScaleAspectFit;
    _qrImageView.layer.magnificationFilter = kCAFilterNearest;
    [_qrImageView.widthAnchor constraintEqualToConstant:168].active = YES;
    [_qrImageView.heightAnchor constraintEqualToConstant:168].active = YES;
    [qrRow addArrangedSubview:_qrImageView];

    _lblMapTopic = [[UILabel alloc] init];
    _lblMapTopic.font = [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightSemibold];
    _lblMapTopic.textColor = [UIColor colorWithWhite:0.90 alpha:1.0];
    _lblMapTopic.textAlignment = NSTextAlignmentCenter;
    _lblMapTopic.numberOfLines = 0;
    [qrRow addArrangedSubview:_lblMapTopic];
    [sec3 addArrangedSubview:qrRow];

    UIStackView *relayRow1 = [[UIStackView alloc] init];
    relayRow1.axis = UILayoutConstraintAxisHorizontal;
    relayRow1.distribution = UIStackViewDistributionFillEqually;
    relayRow1.spacing = 8;
    UIButton *copyLinkBtn = [self makeStepButton:@"Copy Link Màn Phụ" tag:0 action:@selector(copyMapViewerLinkTapped)];
    copyLinkBtn.backgroundColor = [UIColor colorWithRed:0.0 green:0.52 blue:0.46 alpha:1.0];
    UIButton *editTopicBtn = [self makeStepButton:@"Đổi Mã Kênh" tag:0 action:@selector(editMapTopicTapped)];
    editTopicBtn.backgroundColor = [UIColor colorWithRed:0.24 green:0.28 blue:0.38 alpha:1.0];
    [relayRow1 addArrangedSubview:copyLinkBtn];
    [relayRow1 addArrangedSubview:editTopicBtn];
    [sec3 addArrangedSubview:relayRow1];

    UIStackView *relayRow2 = [[UIStackView alloc] init];
    relayRow2.axis = UILayoutConstraintAxisHorizontal;
    relayRow2.distribution = UIStackViewDistributionFillEqually;
    relayRow2.spacing = 8;
    UIButton *testRelayBtn = [self makeStepButton:@"Bắn Thử Map Ngay" tag:0 action:@selector(testMapRelayTapped)];
    testRelayBtn.backgroundColor = [UIColor colorWithRed:0.14 green:0.44 blue:0.82 alpha:1.0];
    UIButton *clipRelayBtn = [self makeStepButton:@"Bắn Từ Clipboard" tag:0 action:@selector(relayClipboardTapped)];
    clipRelayBtn.backgroundColor = [UIColor colorWithRed:0.46 green:0.28 blue:0.56 alpha:1.0];
    [relayRow2 addArrangedSubview:testRelayBtn];
    [relayRow2 addArrangedSubview:clipRelayBtn];
    [sec3 addArrangedSubview:relayRow2];

    // --- CARD 4: 4 COORDINATES & SCREENSHOT PICKER ---
    UIStackView *sec4 = nil;
    [self makeCardWithTitle:@"4. Tinh Chỉnh 4 Tọa Độ & Kéo Hồng Tâm" addTo:_stackView outBody:&sec4];

    _segCoordMode = [[UISegmentedControl alloc] initWithItems:@[@"Bám Chữ + Bù Lệch", @"Tọa Độ Tĩnh / Ảnh"]];
    _segCoordMode.selectedSegmentTintColor = [UIColor colorWithRed:0.0 green:0.65 blue:0.60 alpha:1.0];
    [_segCoordMode setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor whiteColor]} forState:UIControlStateNormal];
    [_segCoordMode addTarget:self action:@selector(generalControlChanged) forControlEvents:UIControlEventValueChanged];
    [sec4 addArrangedSubview:_segCoordMode];

    UIButton *pickImgBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [pickImgBtn setTitle:@"Mở Ảnh Màn Hình Kéo 4 Hồng Tâm" forState:UIControlStateNormal];
    [pickImgBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    pickImgBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    pickImgBtn.backgroundColor = [UIColor colorWithRed:0.0 green:0.52 blue:0.85 alpha:1.0];
    pickImgBtn.layer.cornerRadius = 10;
    [pickImgBtn.heightAnchor constraintEqualToConstant:42].active = YES;
    [pickImgBtn addTarget:self action:@selector(openScreenshotPicker) forControlEvents:UIControlEventTouchUpInside];
    [sec4 addArrangedSubview:pickImgBtn];

    // Group A: Auto OCR + Offset (plus Offline Power X/Y since [⏻] is an icon)
    _autoCoordGroup = [[UIStackView alloc] init];
    _autoCoordGroup.axis = UILayoutConstraintAxisVertical;
    _autoCoordGroup.spacing = 10;
    _slCloseRatio = [self addSliderRowTo:_autoCoordGroup min:0.82f max:0.97f outLabel:&_lblCloseRatio action:@selector(sliderChanged)];
    _slCloseOffX  = [self addSliderRowTo:_autoCoordGroup min:-40.0f max:40.0f outLabel:&_lblCloseOffX action:@selector(sliderChanged)];
    _slCloseOffY  = [self addSliderRowTo:_autoCoordGroup min:-40.0f max:40.0f outLabel:&_lblCloseOffY action:@selector(sliderChanged)];
    _slAcceptOffX = [self addSliderRowTo:_autoCoordGroup min:-60.0f max:60.0f outLabel:&_lblAcceptOffX action:@selector(sliderChanged)];
    _slAcceptOffY = [self addSliderRowTo:_autoCoordGroup min:-40.0f max:40.0f outLabel:&_lblAcceptOffY action:@selector(sliderChanged)];
    _slOnlineOffX = [self addSliderRowTo:_autoCoordGroup min:-50.0f max:50.0f outLabel:&_lblOnlineOffX action:@selector(sliderChanged)];
    _slOnlineOffY = [self addSliderRowTo:_autoCoordGroup min:-40.0f max:40.0f outLabel:&_lblOnlineOffY action:@selector(sliderChanged)];
    [sec4 addArrangedSubview:_autoCoordGroup];

    // Group B: Manual Fixed X/Y for all 4 buttons
    _manualCoordGroup = [[UIStackView alloc] init];
    _manualCoordGroup.axis = UILayoutConstraintAxisVertical;
    _manualCoordGroup.spacing = 10;
    _slManCloseX   = [self addSliderRowTo:_manualCoordGroup min:10.0f max:365.0f outLabel:&_lblManCloseX action:@selector(sliderChanged)];
    _slManCloseY   = [self addSliderRowTo:_manualCoordGroup min:15.0f max:200.0f outLabel:&_lblManCloseY action:@selector(sliderChanged)];
    _slManAcceptX  = [self addSliderRowTo:_manualCoordGroup min:20.0f max:355.0f outLabel:&_lblManAcceptX action:@selector(sliderChanged)];
    _slManAcceptY  = [self addSliderRowTo:_manualCoordGroup min:450.0f max:662.0f outLabel:&_lblManAcceptY action:@selector(sliderChanged)];
    _slManOnlineX  = [self addSliderRowTo:_manualCoordGroup min:30.0f max:345.0f outLabel:&_lblManOnlineX action:@selector(sliderChanged)];
    _slManOnlineY  = [self addSliderRowTo:_manualCoordGroup min:180.0f max:500.0f outLabel:&_lblManOnlineY action:@selector(sliderChanged)];
    [sec4 addArrangedSubview:_manualCoordGroup];

    // Offline Power [⏻] is always icon-based, keep visible in both modes
    _slManOfflineX = [self addSliderRowTo:sec4 min:10.0f max:200.0f outLabel:&_lblManOfflineX action:@selector(sliderChanged)];
    _slManOfflineY = [self addSliderRowTo:sec4 min:300.0f max:600.0f outLabel:&_lblManOfflineY action:@selector(sliderChanged)];

    // --- CARD 5: TIMING, JITTER & LIVE LOG ---
    UIStackView *sec5 = nil;
    [self makeCardWithTitle:@"5. Chạm Bồi Kiểm Chứng, Delay & Nhật Ký" addTo:_stackView outBody:&sec5];

    _slTapRetries = [self addSliderRowTo:sec5 min:0.0f max:4.0f outLabel:&_lblTapRetries action:@selector(sliderChanged)];
    _slScanMs   = [self addSliderRowTo:sec5 min:150.0f  max:1500.0f outLabel:&_lblScanMs action:@selector(sliderChanged)];
    _slAccMinMs = [self addSliderRowTo:sec5 min:80.0f   max:2000.0f outLabel:&_lblAccMinMs action:@selector(sliderChanged)];
    _slAccMaxMs = [self addSliderRowTo:sec5 min:120.0f  max:3000.0f outLabel:&_lblAccMaxMs action:@selector(sliderChanged)];
    _slRejMinMs = [self addSliderRowTo:sec5 min:150.0f  max:3000.0f outLabel:&_lblRejMinMs action:@selector(sliderChanged)];
    _slRejMaxMs = [self addSliderRowTo:sec5 min:250.0f  max:4000.0f outLabel:&_lblRejMaxMs action:@selector(sliderChanged)];
    _slJitter   = [self addSliderRowTo:sec5 min:0.0f    max:18.0f   outLabel:&_lblJitter action:@selector(sliderChanged)];
    _slHoldMin  = [self addSliderRowTo:sec5 min:30.0f   max:120.0f  outLabel:&_lblHoldMin action:@selector(sliderChanged)];
    _slHoldMax  = [self addSliderRowTo:sec5 min:45.0f   max:180.0f  outLabel:&_lblHoldMax action:@selector(sliderChanged)];
    _slCooldown = [self addSliderRowTo:sec5 min:1000.0f max:6000.0f outLabel:&_lblCooldown action:@selector(sliderChanged)];

    _logTextView = [[UITextView alloc] init];
    _logTextView.editable = NO;
    _logTextView.backgroundColor = [UIColor colorWithWhite:0.05 alpha:1.0];
    _logTextView.textColor = [UIColor colorWithRed:0.45 green:0.95 blue:0.55 alpha:1.0];
    _logTextView.font = [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightRegular];
    _logTextView.layer.cornerRadius = 8;
    [_logTextView.heightAnchor constraintEqualToConstant:210].active = YES;
    [sec5 addArrangedSubview:_logTextView];

    UIButton *clearLogBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [clearLogBtn setTitle:@"Xóa sạch Nhật ký" forState:UIControlStateNormal];
    [clearLogBtn setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    [clearLogBtn addTarget:self action:@selector(clearLogsTapped) forControlEvents:UIControlEventTouchUpInside];
    [sec5 addArrangedSubview:clearLogBtn];
}

#pragma mark - Sync UI

- (NSString *)formatVND:(NSInteger)vnd {
    NSNumberFormatter *nf = [[NSNumberFormatter alloc] init];
    nf.numberStyle = NSNumberFormatterDecimalStyle;
    nf.groupingSeparator = @".";
    return [NSString stringWithFormat:@"%@đ", [nf stringFromNumber:@(vnd)]];
}

- (void)syncUIFromConfig {
    _swMaster.on        = _cfg.masterEnabled;
    _swSmartCool.on     = _cfg.smartCoolMode;
    _swAutoBike.on      = _cfg.autoAcceptBike;
    _swRejectAllFood.on = _cfg.rejectAllFood;
    _swHaptic.on        = _cfg.hapticEnabled;
    _swDryRun.on        = _cfg.dryRunMode;

    _swBlockMall.on          = _cfg.foodBlockMallAndBasement;
    _swBlockChains.on        = _cfg.foodBlockCrowdedChains;
    _slMaxMerchantOrders.value = (float)MIN(20000, MAX(0, _cfg.foodMaxMerchantOrders));
    _swAcceptLongDist.on     = _cfg.foodAcceptLongDistance;
    _slMinFoodDistKm.value   = (float)fmin(10.0, fmax(1.0, _cfg.minFoodDistanceKm));

    _swPauseFood.on     = _cfg.pauseAfterRejectFood;
    _slPauseSec.value   = (float)_cfg.pauseDurationSec;
    _swAutoKill.on      = _cfg.autoKillAndRelaunchApp;
    _slRelaunchSec.value= (float)_cfg.relaunchLeadSec;

    _swMapRelay.on      = _cfg.mapRelayEnabled;
    _swMapReturn.on     = _cfg.mapRelayReturnToDriver;

    _segCoordMode.selectedSegmentIndex = (_cfg.coordMode == CoordModeFixedManual) ? 1 : 0;

    _slCloseRatio.value = (float)_cfg.closeXRatio;
    _slCloseOffX.value  = (float)_cfg.closeOffsetX;
    _slCloseOffY.value  = (float)_cfg.closeOffsetY;
    _slAcceptOffX.value = (float)_cfg.acceptOffsetX;
    _slAcceptOffY.value = (float)_cfg.acceptOffsetY;
    _slOnlineOffX.value = (float)_cfg.onlineOffsetX;
    _slOnlineOffY.value = (float)_cfg.onlineOffsetY;

    _slManCloseX.value   = (float)_cfg.manualCloseX;
    _slManCloseY.value   = (float)_cfg.manualCloseY;
    _slManAcceptX.value  = (float)_cfg.manualAcceptX;
    _slManAcceptY.value  = (float)_cfg.manualAcceptY;
    _slManOfflineX.value = (float)_cfg.manualOfflineX;
    _slManOfflineY.value = (float)_cfg.manualOfflineY;
    _slManOnlineX.value  = (float)_cfg.manualOnlineX;
    _slManOnlineY.value  = (float)_cfg.manualOnlineY;

    _slTapRetries.value = (float)_cfg.tapVerifyRetries;
    _slScanMs.value   = (float)_cfg.scanIntervalMs;
    _slAccMinMs.value = (float)_cfg.acceptDelayMinMs;
    _slAccMaxMs.value = (float)_cfg.acceptDelayMaxMs;
    _slRejMinMs.value = (float)_cfg.rejectDelayMinMs;
    _slRejMaxMs.value = (float)_cfg.rejectDelayMaxMs;
    _slJitter.value   = (float)_cfg.jitterRadiusPt;
    _slHoldMin.value  = (float)_cfg.holdMinMs;
    _slHoldMax.value  = (float)_cfg.holdMaxMs;
    _slCooldown.value = (float)_cfg.cooldownMs;

    [self updateValueLabels];
}

- (void)renderMapRelayQRIfNeeded {
    NSString *topic = sanitizeMapRelayTopic(_cfg.mapRelayTopic);
    if (topic.length < 4) {
        topic = generateRandomMapRelayTopic();
        _cfg.mapRelayTopic = topic;
    } else if (![topic isEqualToString:_cfg.mapRelayTopic]) {
        _cfg.mapRelayTopic = topic;
    }
    NSString *viewerUrl = buildMapRelayViewerURLString(topic);
    _lblMapTopic.text = [NSString stringWithFormat:@"Mã kênh riêng: %@\nQuét QR bằng Cam máy thứ 2 để ghép đôi 1 lần", topic];

    if (_qrImageView.image && [_lastRenderedQRTopic isEqualToString:topic]) {
        return;
    }
    _lastRenderedQRTopic = [topic copy];

    const char *utf8 = [viewerUrl UTF8String];
    if (!utf8) return;
    int len = (int)strlen(utf8);
    uint8_t modules[37][37];
    memset(modules, 0, sizeof(modules));
    int dim = PureQR_EncodeUTF8((const uint8_t *)utf8, len, modules);
    if (dim <= 0) return;

    const int quiet = 3;
    const int scale = 8;
    const int pxSize = (dim + quiet * 2) * scale;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs) return;
    CGContextRef ctx = CGBitmapContextCreate(NULL,
                                             (size_t)pxSize,
                                             (size_t)pxSize,
                                             8,
                                             (size_t)(pxSize * 4),
                                             cs,
                                             (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return;

    CGContextSetRGBFillColor(ctx, 1.0, 1.0, 1.0, 1.0);
    CGContextFillRect(ctx, CGRectMake(0, 0, pxSize, pxSize));

    CGContextSetRGBFillColor(ctx, 0.0, 0.0, 0.0, 1.0);
    for (int r = 0; r < dim; r++) {
        CGFloat y = (CGFloat)(pxSize - (quiet + r + 1) * scale);
        for (int c = 0; c < dim; c++) {
            if (modules[r][c]) {
                CGFloat x = (CGFloat)((quiet + c) * scale);
                CGContextFillRect(ctx, CGRectMake(x, y, scale, scale));
            }
        }
    }

    CGImageRef cgImg = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (cgImg) {
        _qrImageView.image = [UIImage imageWithCGImage:cgImg];
        CGImageRelease(cgImg);
    }
}

- (void)updateValueLabels {
    _priceControlRow.alpha = _cfg.rejectAllFood ? 0.35 : 1.0;
    _priceControlRow.userInteractionEnabled = !_cfg.rejectAllFood;
    _foodSmartFilterCardBody.alpha = _cfg.rejectAllFood ? 0.35 : 1.0;
    _foodSmartFilterCardBody.userInteractionEnabled = !_cfg.rejectAllFood;
    _lblMinFoodPrice.text = [NSString stringWithFormat:@"Giá tối thiểu nhận Green Food: %@\n(Quán sạch: Giá >= mức này tự Nhận ngay 0ms; thấp hơn sẽ xét tiếp Km)",
                             [self formatVND:_cfg.minFoodPriceVND]];

    if (_cfg.foodMaxMerchantOrders <= 0) {
        _lblMaxMerchantOrders.text = @"Lọc Điểm Đông Liên Sàn (Xanh + Grab + Shopee): ĐANG TẮT (0)";
    } else {
        NSInteger v = _cfg.foodMaxMerchantOrders;
        NSInteger grabEq   = (NSInteger)llround((double)v / 3.2);
        NSInteger shopeeEq = (NSInteger)llround((double)v / 3.0);
        _lblMaxMerchantOrders.text = [NSString stringWithFormat:@"Chặn quán quá tải liên sàn: >= %ld điểm đông\n(~%ld đơn Xanh | ~%ld vote Grab | ~%ld điểm Shopee)",
                                      (long)v, (long)v, (long)grabEq, (long)shopeeEq];
    }

    _distSliderWrap.alpha = _cfg.foodAcceptLongDistance ? 1.0 : 0.35;
    _distSliderWrap.userInteractionEnabled = _cfg.foodAcceptLongDistance;
    _lblMinFoodDistKm.text = [NSString stringWithFormat:@"Ngưỡng khoảng cách Điểm nhận -> Điểm giao: > %.1f km\n(Đo xe máy Valhalla + 49.261 ghim Hà Nội Offline chống lag 4G)",
                              _cfg.minFoodDistanceKm];

    _lblPauseSec.text    = [NSString stringWithFormat:@"Thời gian tắt nhận chuyến: %ld giây (%.1f phút)",
                            (long)_cfg.pauseDurationSec, _cfg.pauseDurationSec / 60.0];
    _lblRelaunchSec.text = [NSString stringWithFormat:@"Mở lại App Tài xế sớm trước khi hết giờ: %ld giây",
                            (long)_cfg.relaunchLeadSec];
    _lblDriverApp.text   = [NSString stringWithFormat:@"App Tài xế mục tiêu: %@ (%@)",
                            _cfg.driverAppDisplayName.length ? _cfg.driverAppDisplayName : @"Chưa chọn",
                            _cfg.driverAppBundleID.length ? _cfg.driverAppBundleID : @"Tự động dò"];

    [self renderMapRelayQRIfNeeded];

    BOOL isManual = (_cfg.coordMode == CoordModeFixedManual);
    _autoCoordGroup.hidden   = isManual;
    _manualCoordGroup.hidden = !isManual;

    _lblCloseRatio.text = [NSString stringWithFormat:@"1. Tỉ lệ ngang nút [X]: %.1f%% (~%.0fpt)", _cfg.closeXRatio * 100.0, 375.0 * _cfg.closeXRatio];
    _lblCloseOffX.text  = [NSString stringWithFormat:@"1. Bù lệch ngang nút [X] (ΔX): %+.0f pt", _cfg.closeOffsetX];
    _lblCloseOffY.text  = [NSString stringWithFormat:@"1. Bù lệch dọc nút [X] (ΔY): %+.0f pt", _cfg.closeOffsetY];
    _lblAcceptOffX.text = [NSString stringWithFormat:@"2. Bù lệch ngang [Nhận chuyến] (ΔX): %+.0f pt", _cfg.acceptOffsetX];
    _lblAcceptOffY.text = [NSString stringWithFormat:@"2. Bù lệch dọc [Nhận chuyến] (ΔY): %+.0f pt", _cfg.acceptOffsetY];
    _lblOnlineOffX.text = [NSString stringWithFormat:@"4. Bù lệch ngang [Mở nhận chuyến] (ΔX): %+.0f pt", _cfg.onlineOffsetX];
    _lblOnlineOffY.text = [NSString stringWithFormat:@"4. Bù lệch dọc [Mở nhận chuyến] (ΔY): %+.0f pt", _cfg.onlineOffsetY];

    _lblManCloseX.text   = [NSString stringWithFormat:@"1. Tọa độ X nút [X]: %.0f pt", _cfg.manualCloseX];
    _lblManCloseY.text   = [NSString stringWithFormat:@"1. Tọa độ Y nút [X]: %.0f pt", _cfg.manualCloseY];
    _lblManAcceptX.text  = [NSString stringWithFormat:@"2. Tọa độ X [Nhận chuyến]: %.0f pt", _cfg.manualAcceptX];
    _lblManAcceptY.text  = [NSString stringWithFormat:@"2. Tọa độ Y [Nhận chuyến]: %.0f pt", _cfg.manualAcceptY];
    _lblManOnlineX.text  = [NSString stringWithFormat:@"4. Tọa độ X [Mở nhận chuyến]: %.0f pt", _cfg.manualOnlineX];
    _lblManOnlineY.text  = [NSString stringWithFormat:@"4. Tọa độ Y [Mở nhận chuyến]: %.0f pt", _cfg.manualOnlineY];

    _lblManOfflineX.text = [NSString stringWithFormat:@"3. Tọa độ X nút tròn [⏻ Tắt trực tuyến]: %.0f pt", _cfg.manualOfflineX];
    _lblManOfflineY.text = [NSString stringWithFormat:@"3. Tọa độ Y nút tròn [⏻ Tắt trực tuyến]: %.0f pt", _cfg.manualOfflineY];

    _lblTapRetries.text = [NSString stringWithFormat:@"Số lần chạm bồi kiểm chứng chống trượt đơn: %ld lần", (long)_cfg.tapVerifyRetries];
    _lblScanMs.text   = [NSString stringWithFormat:@"Chu kỳ quét màn hình: %ld ms", (long)_cfg.scanIntervalMs];
    _lblAccMinMs.text = [NSString stringWithFormat:@"Delay bấm [Nhận] Min: %ld ms", (long)_cfg.acceptDelayMinMs];
    _lblAccMaxMs.text = [NSString stringWithFormat:@"Delay bấm [Nhận] Max: %ld ms", (long)_cfg.acceptDelayMaxMs];
    _lblRejMinMs.text = [NSString stringWithFormat:@"Delay bấm [X] Min: %ld ms", (long)_cfg.rejectDelayMinMs];
    _lblRejMaxMs.text = [NSString stringWithFormat:@"Delay bấm [X] Max: %ld ms", (long)_cfg.rejectDelayMaxMs];
    _lblJitter.text   = [NSString stringWithFormat:@"Bán kính lệch ngón tay (Jitter): ±%.1f pt", _cfg.jitterRadiusPt];
    _lblHoldMin.text  = [NSString stringWithFormat:@"Nhấn giữ ngón tay Min: %ld ms", (long)_cfg.holdMinMs];
    _lblHoldMax.text  = [NSString stringWithFormat:@"Nhấn giữ ngón tay Max: %ld ms", (long)_cfg.holdMaxMs];
    _lblCooldown.text = [NSString stringWithFormat:@"Nghỉ sau khi bấm đơn (Cooldown): %.1f giây", _cfg.cooldownMs / 1000.0];
}

#pragma mark - Actions

- (void)masterSwitchChanged:(UISwitch *)sender {
    BOOL wantOn = sender.isOn;
    _cfg.masterEnabled = wantOn;
    [_cfg saveToDiskAndNotify:YES];
    sender.enabled = NO;
    _lastAutoHealEpoch = [[NSDate date] timeIntervalSince1970];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (wantOn) {
            BOOL ok = startFilterDaemonIfNeeded();
            dispatch_async(dispatch_get_main_queue(), ^{
                sender.enabled = YES;
                if (!ok) {
                    sender.on = NO;
                    self->_cfg.masterEnabled = NO;
                    [self->_cfg saveToDiskAndNotify:NO];
                }
                [self refreshStatusAndLogs];
            });
        } else {
            stopFilterDaemon();
            dispatch_async(dispatch_get_main_queue(), ^{
                sender.enabled = YES;
                [self refreshStatusAndLogs];
            });
        }
    });
}

- (void)generalControlChanged {
    _cfg.smartCoolMode          = _swSmartCool.isOn;
    _cfg.autoAcceptBike         = _swAutoBike.isOn;
    _cfg.rejectAllFood          = _swRejectAllFood.isOn;
    _cfg.foodBlockMallAndBasement = _swBlockMall.isOn;
    _cfg.foodBlockCrowdedChains   = _swBlockChains.isOn;
    _cfg.foodAcceptLongDistance   = _swAcceptLongDist.isOn;
    _cfg.hapticEnabled          = _swHaptic.isOn;
    _cfg.dryRunMode             = _swDryRun.isOn;
    _cfg.pauseAfterRejectFood   = _swPauseFood.isOn;
    _cfg.autoKillAndRelaunchApp = _swAutoKill.isOn;
    _cfg.mapRelayEnabled        = _swMapRelay.isOn;
    _cfg.mapRelayReturnToDriver = _swMapReturn.isOn;
    _cfg.coordMode              = (CoordMode)_segCoordMode.selectedSegmentIndex;

    [self updateValueLabels];
    [_cfg saveToDiskAndNotify:YES];
}

- (void)sliderChanged {
    _cfg.foodMaxMerchantOrders = (NSInteger)(roundf(_slMaxMerchantOrders.value / 500.0f) * 500);
    _cfg.minFoodDistanceKm     = roundf(_slMinFoodDistKm.value * 10.0f) / 10.0f;

    _cfg.pauseDurationSec = (NSInteger)(roundf(_slPauseSec.value / 10.0f) * 10);
    _cfg.relaunchLeadSec  = (NSInteger)roundf(_slRelaunchSec.value);

    _cfg.closeXRatio   = _slCloseRatio.value;
    _cfg.closeOffsetX  = roundf(_slCloseOffX.value);
    _cfg.closeOffsetY  = roundf(_slCloseOffY.value);
    _cfg.acceptOffsetX = roundf(_slAcceptOffX.value);
    _cfg.acceptOffsetY = roundf(_slAcceptOffY.value);
    _cfg.onlineOffsetX = roundf(_slOnlineOffX.value);
    _cfg.onlineOffsetY = roundf(_slOnlineOffY.value);

    _cfg.manualCloseX   = roundf(_slManCloseX.value);
    _cfg.manualCloseY   = roundf(_slManCloseY.value);
    _cfg.manualAcceptX  = roundf(_slManAcceptX.value);
    _cfg.manualAcceptY  = roundf(_slManAcceptY.value);
    _cfg.manualOfflineX = roundf(_slManOfflineX.value);
    _cfg.manualOfflineY = roundf(_slManOfflineY.value);
    _cfg.manualOnlineX  = roundf(_slManOnlineX.value);
    _cfg.manualOnlineY  = roundf(_slManOnlineY.value);

    _cfg.tapVerifyRetries = (NSInteger)roundf(_slTapRetries.value);
    _cfg.scanIntervalMs   = (NSInteger)(roundf(_slScanMs.value / 10.0f) * 10);
    _cfg.acceptDelayMinMs = (NSInteger)(roundf(_slAccMinMs.value / 10.0f) * 10);
    _cfg.acceptDelayMaxMs = MAX(_cfg.acceptDelayMinMs + 30, (NSInteger)(roundf(_slAccMaxMs.value / 10.0f) * 10));
    _cfg.rejectDelayMinMs = (NSInteger)(roundf(_slRejMinMs.value / 10.0f) * 10);
    _cfg.rejectDelayMaxMs = MAX(_cfg.rejectDelayMinMs + 30, (NSInteger)(roundf(_slRejMaxMs.value / 10.0f) * 10));
    _cfg.jitterRadiusPt   = roundf(_slJitter.value * 2.0f) / 2.0f;
    _cfg.holdMinMs        = (NSInteger)roundf(_slHoldMin.value);
    _cfg.holdMaxMs        = MAX(_cfg.holdMinMs + 10, (NSInteger)roundf(_slHoldMax.value));
    _cfg.cooldownMs       = (NSInteger)(roundf(_slCooldown.value / 100.0f) * 100);

    _slAccMaxMs.value = (float)_cfg.acceptDelayMaxMs;
    _slRejMaxMs.value = (float)_cfg.rejectDelayMaxMs;
    _slHoldMax.value  = (float)_cfg.holdMaxMs;

    [self updateValueLabels];
    _hasPendingSliderSave = YES;
    [_sliderSaveTimer invalidate];
    _sliderSaveTimer = [NSTimer scheduledTimerWithTimeInterval:0.18
                                                        target:self
                                                      selector:@selector(flushPendingSliderSave)
                                                      userInfo:nil
                                                       repeats:NO];
}

- (void)flushPendingSliderSave {
    _sliderSaveTimer = nil;
    if (_hasPendingSliderSave) {
        _hasPendingSliderSave = NO;
        [_cfg saveToDiskAndNotify:YES];
    }
}

- (void)stepFoodPrice:(UIButton *)sender {
    NSInteger next = _cfg.minFoodPriceVND + sender.tag;
    _cfg.minFoodPriceVND = MAX(5000, MIN(500000, next));
    [self updateValueLabels];
    [_cfg saveToDiskAndNotify:YES];
}

- (void)promptExactFoodPrice {
    if (_cfg.rejectAllFood) return;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Mức Giá Tối Thiểu Green Food"
                                                                message:@"Ví dụ gõ 25000 (hoặc gõ tắt 25): Đơn từ 25.000đ trở lên sẽ tự Nhận, dưới 25.000đ sẽ tự bấm X"
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.keyboardType = UIKeyboardTypeNumberPad;
        tf.text = [NSString stringWithFormat:@"%ld", (long)self->_cfg.minFoodPriceVND];
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Lưu" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSInteger val = [ac.textFields.firstObject.text integerValue];
        if (val > 0 && val < 1000) val *= 1000;
        if (val >= 5000 && val <= 1000000) {
            self->_cfg.minFoodPriceVND = val;
            [self updateValueLabels];
            [self->_cfg saveToDiskAndNotify:YES];
        }
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)openKeywordEditorTapped:(UIButton *)sender {
    BOOL isMall = (sender.tag == 1);
    UIViewController *editorVC = [[UIViewController alloc] init];
    editorVC.title = isMall ? @"Từ Khóa TTTM / Tầng Hầm" : @"Từ Khóa Chuỗi Quán Đông";
    editorVC.view.backgroundColor = [UIColor colorWithRed:0.08 green:0.09 blue:0.12 alpha:1.0];

    UILabel *hint = [[UILabel alloc] init];
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    hint.numberOfLines = 0;
    hint.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightRegular];
    hint.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
    hint.text = @"Ngăn cách các từ khóa bằng dấu phẩy (,). Không phân biệt chữ hoa/thường hay có dấu/không dấu. Chỉ quét trên Điểm nhận:";
    [editorVC.view addSubview:hint];

    UITextView *tv = [[UITextView alloc] init];
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    tv.backgroundColor = [UIColor colorWithRed:0.14 green:0.15 blue:0.19 alpha:1.0];
    tv.textColor = [UIColor whiteColor];
    tv.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
    tv.layer.cornerRadius = 10;
    tv.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tv.autocorrectionType = UITextAutocorrectionTypeNo;
    tv.text = isMall
        ? (_cfg.foodMallKeywords ?: kDefaultFoodMallKeywords)
        : (_cfg.foodChainKeywords ?: kDefaultFoodChainKeywords);
    [editorVC.view addSubview:tv];

    UIButton *resetDefaultBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    resetDefaultBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [resetDefaultBtn setTitle:@"Khôi Phục Danh Sách Gốc Mặc Định" forState:UIControlStateNormal];
    [resetDefaultBtn setTitleColor:[UIColor systemOrangeColor] forState:UIControlStateNormal];
    resetDefaultBtn.titleLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightBold];
    [editorVC.view addSubview:resetDefaultBtn];

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:editorVC];
    nav.navigationBar.barStyle = UIBarStyleBlack;
    nav.navigationBar.tintColor = [UIColor systemTealColor];

    __weak typeof(self) weakSelf = self;
    UIAction *cancelAct = [UIAction actionWithTitle:@"Hủy" image:nil identifier:nil handler:^(__kindof UIAction *action) {
        [nav dismissViewControllerAnimated:YES completion:nil];
    }];
    UIAction *saveAct = [UIAction actionWithTitle:@"Lưu" image:nil identifier:nil handler:^(__kindof UIAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) {
            NSString *cleaned = [tv.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (isMall) {
                strongSelf->_cfg.foodMallKeywords = cleaned;
            } else {
                strongSelf->_cfg.foodChainKeywords = cleaned;
            }
            [strongSelf->_cfg saveToDiskAndNotify:YES];
        }
        [nav dismissViewControllerAnimated:YES completion:nil];
    }];
    UIAction *resetAct = [UIAction actionWithTitle:@"Mặc định gốc" image:nil identifier:nil handler:^(__kindof UIAction *action) {
        tv.text = isMall ? kDefaultFoodMallKeywords : kDefaultFoodChainKeywords;
    }];
    UIAction *resetBtnAct = [UIAction actionWithHandler:^(__kindof UIAction *action) {
        tv.text = isMall ? kDefaultFoodMallKeywords : kDefaultFoodChainKeywords;
    }];
    UIAction *hideKbAct = [UIAction actionWithTitle:@"Ẩn bàn phím" image:nil identifier:nil handler:^(__kindof UIAction *action) {
        [tv resignFirstResponder];
    }];
    [resetDefaultBtn addAction:resetBtnAct forControlEvents:UIControlEventTouchUpInside];

    UIToolbar *kbBar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 375, 42)];
    kbBar.barStyle = UIBarStyleBlack;
    kbBar.tintColor = [UIColor systemTealColor];
    kbBar.items = @[
        [[UIBarButtonItem alloc] initWithPrimaryAction:resetAct],
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil],
        [[UIBarButtonItem alloc] initWithPrimaryAction:hideKbAct]
    ];
    tv.inputAccessoryView = kbBar;

    editorVC.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithPrimaryAction:cancelAct];
    editorVC.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithPrimaryAction:saveAct];

    UILayoutGuide *g = editorVC.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [hint.topAnchor constraintEqualToAnchor:g.topAnchor constant:10],
        [hint.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:14],
        [hint.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-14],
        [tv.topAnchor constraintEqualToAnchor:hint.bottomAnchor constant:8],
        [tv.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:14],
        [tv.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-14],
        [tv.heightAnchor constraintEqualToConstant:168],
        [resetDefaultBtn.topAnchor constraintEqualToAnchor:tv.bottomAnchor constant:10],
        [resetDefaultBtn.centerXAnchor constraintEqualToAnchor:g.centerXAnchor]
    ]];

    [self presentViewController:nav animated:YES completion:^{
        [tv becomeFirstResponder];
    }];
}

#pragma mark - Driver App Picker & Kill/Relaunch Test

- (void)pickDriverAppTapped {
    NSArray<InstalledAppInfo *> *apps = listInstalledUserApps();
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Chọn App Tài Xế Trên Máy"
                                                                   message:@"Chọn đúng ứng dụng Xanh SM Bác Tài để dùng cho tính năng Tự động Kill & Mở lại"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (InstalledAppInfo *app in apps) {
        NSString *title = [NSString stringWithFormat:@"%@ (%@)", app.displayName, app.bundleID];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            self->_cfg.driverAppBundleID    = app.bundleID;
            self->_cfg.driverAppExecName    = app.executableName;
            self->_cfg.driverAppDisplayName = app.displayName;
            [self updateValueLabels];
            [self->_cfg saveToDiskAndNotify:YES];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)testKillAndRelaunchTapped {
    NSString *bid  = _cfg.driverAppBundleID;
    NSString *exec = _cfg.driverAppExecName;
    NSString *name = _cfg.driverAppDisplayName ?: @"Xanh SM";
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL killed = killAppByBundleIDAndExec(bid, exec);
        appendDaemonLog(@"[TEST] %@ App Tài xế (%@), sẽ tự mở lại sau 3 giây...",
                        killed ? @"Đã Kill sạch" : @"Đã gửi lệnh đóng", name);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshStatusAndLogs];
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            BOOL launched = launchAppByBundleID(bid);
            appendDaemonLog(@"[TEST] %@ lại App Tài xế (%@).",
                            launched ? @"Đã tự mở" : @"Không mở được", name);
        });
    });
}

#pragma mark - Navigation Relay Bridge Actions (Card 3)

- (void)showQuickAlert:(NSString *)title message:(NSString *)msg {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                                message:msg
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)copyMapViewerLinkTapped {
    NSString *url = buildMapRelayViewerURLString(_cfg.mapRelayTopic);
    [UIPasteboard generalPasteboard].string = url;
    triggerHapticFeedback(NO);
    [self showQuickAlert:@"Đã Copy Link Màn Phụ"
                 message:[NSString stringWithFormat:@"Đã chép:\n%@\n\nDán link này vào trình duyệt trên máy thứ 2 (hoặc đưa Cam máy thứ 2 quét thẳng mã QR ở trên) là xong!", url]];
}

- (void)editMapTopicTapped {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Mã Kênh Bắn Map Riêng"
                                                                message:@"Đặt mã bí mật riêng (chữ, số, gạch ngang) hoặc bấm Tạo Mã Mới để đổi kênh khác:"
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.text = self->_cfg.mapRelayTopic;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Tạo Mã Ngẫu Nhiên" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        self->_cfg.mapRelayTopic = generateRandomMapRelayTopic();
        [self updateValueLabels];
        [self->_cfg saveToDiskAndNotify:YES];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Lưu Mã" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        self->_cfg.mapRelayTopic = sanitizeMapRelayTopic(ac.textFields.firstObject.text);
        [self updateValueLabels];
        [self->_cfg saveToDiskAndNotify:YES];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)testMapRelayTapped {
    triggerHapticFeedback(NO);
    __weak typeof(self) weakSelf = self;
    enqueueAndTriggerMapRelayFromURLString(@"comgooglemaps://?daddr=21.028511,105.804817&directionsmode=driving",
                                           @"TestUI",
                                           NO,
                                           ^(BOOL ok, NSString *detail) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf refreshStatusAndLogs];
        [strongSelf showQuickAlert:(ok ? @"Đã Bắn Thử Thành Công!" : @"Chưa Bắn Được Map")
                           message:(ok
                                    ? [NSString stringWithFormat:@"Tọa độ mẫu (%@) đã nổ sang kênh %@.\nNhìn sang màn máy thứ 2 kiểm tra Google Maps nhảy luôn!", detail ?: @"21.028511,105.804817", strongSelf->_cfg.mapRelayTopic]
                                    : [NSString stringWithFormat:@"Chi tiết: %@", detail ?: @"Kiểm tra lại kết nối mạng"])];
    });
}

- (void)relayClipboardTapped {
    NSString *clip = [[UIPasteboard generalPasteboard].string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (clip.length < 3) {
        [self showQuickAlert:@"Clipboard Đang Trống"
                     message:@"Hãy copy địa chỉ hoặc tọa độ trước rồi bấm nút này để bắn sang máy thứ 2."];
        return;
    }
    triggerHapticFeedback(NO);
    NSString *wrapped = clip;
    if ([clip rangeOfString:@"://"].location == NSNotFound) {
        NSString *enc = [clip stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: clip;
        wrapped = [NSString stringWithFormat:@"comgooglemaps://?daddr=%@&directionsmode=driving", enc];
    }
    __weak typeof(self) weakSelf = self;
    enqueueAndTriggerMapRelayFromURLString(wrapped, @"Clipboard", NO, ^(BOOL ok, NSString *detail) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf refreshStatusAndLogs];
        [strongSelf showQuickAlert:(ok ? @"Đã Bắn Từ Clipboard!" : @"Lỗi Bắn Clipboard")
                           message:(detail ?: clip)];
    });
}

#pragma mark - Screenshot Coordinate Picker (4 Pins)

- (void)openScreenshotPicker {
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    UIImage *img = info[UIImagePickerControllerOriginalImage];
    [picker dismissViewControllerAnimated:YES completion:^{
        if (!img) return;
        CoordinatePickerViewController *vc = [[CoordinatePickerViewController alloc] initWithScreenshot:img
                                                                                                 config:self->_cfg
                                                                                                 onSave:^(CGPoint closePt, CGPoint acceptPt, CGPoint offlinePt, CGPoint onlinePt) {
            self->_cfg.coordMode      = CoordModeFixedManual;
            self->_cfg.manualCloseX   = round(closePt.x);
            self->_cfg.manualCloseY   = round(closePt.y);
            self->_cfg.manualAcceptX  = round(acceptPt.x);
            self->_cfg.manualAcceptY  = round(acceptPt.y);
            self->_cfg.manualOfflineX = round(offlinePt.x);
            self->_cfg.manualOfflineY = round(offlinePt.y);
            self->_cfg.manualOnlineX  = round(onlinePt.x);
            self->_cfg.manualOnlineY  = round(onlinePt.y);
            [self syncUIFromConfig];
            [self->_cfg saveToDiskAndNotify:YES];
        }];
        [self presentViewController:vc animated:YES completion:nil];
    }];
}

#pragma mark - Live Status, Map Relay & Logs

- (void)skipPauseTapped {
    notify_post(kNotifySkipPause);
}

- (void)diagCaptureTapped {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (getRunningDaemonPID() <= 0) {
            startFilterDaemonIfNeeded();
        }
        notify_post(kNotifyDiagCapture);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshStatusAndLogs];
        });
    });
}

- (void)forceRestartDaemonTapped {
    _cfg.masterEnabled = YES;
    _swMaster.on = YES;
    [_cfg saveToDiskAndNotify:NO];
    _lastAutoHealEpoch = [[NSDate date] timeIntervalSince1970];
    triggerHapticFeedback(NO);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        forceRestartFilterDaemon();
        appendDaemonLog(@"[HỆ THỐNG] Đã khởi động làm mới sạch Lõi Ngầm v5.0.1!");
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshStatusAndLogs];
        });
    });
}

- (void)resetStatsTapped {
    RuntimeDaemonState *st = [RuntimeDaemonState loadState];
    st.statAcceptedCount = 0;
    st.statRejectedCount = 0;
    [st saveStateAndNotify:NO];
    notify_post(kNotifyResetCounters);
    [self refreshStatusAndLogs];
}

- (void)clearLogsTapped {
    clearDaemonLogs();
    [self refreshStatusAndLogs];
}

- (void)refreshStatusAndLogs {
    pid_t wkPid = getRunningDaemonPID();
    pid_t wdPid = getRunningWatchdogPID();
    RuntimeDaemonState *st = [RuntimeDaemonState loadState];
    double now = [[NSDate date] timeIntervalSince1970];

    BOOL heartbeatStale = (st.workerHeartbeatEpoch > 0.0 && fabs(now - st.workerHeartbeatEpoch) > 24.0);
    BOOL versionMismatch = (st.daemonVersion.length > 0 && ![st.daemonVersion isEqualToString:kCurrentDaemonVersion]);
    BOOL needsAutoHeal = (wkPid <= 0 || wdPid <= 0 || heartbeatStale || versionMismatch);

    if (_cfg.masterEnabled && needsAutoHeal && (now - _lastAutoHealEpoch) > 5.0) {
        _lastAutoHealEpoch = now;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            startFilterDaemonIfNeeded();
            dispatch_async(dispatch_get_main_queue(), ^{
                [self refreshStatusAndLogs];
            });
        });
    }

    if (wkPid > 0 && _cfg.masterEnabled && !heartbeatStale) {
        _daemonStatusLabel.text = [NSString stringWithFormat:@"● BẤT TỬ v5.0.1 (WD:%d | WK:%d)%@%@",
                                   wdPid, wkPid,
                                   _cfg.smartCoolMode ? @" [MÁT-2GB]" : @"",
                                   _cfg.dryRunMode ? @" [THỬ]" : @""];
        _daemonStatusLabel.textColor = [UIColor systemGreenColor];
    } else if (_cfg.masterEnabled) {
        _daemonStatusLabel.text = [NSString stringWithFormat:@"● ĐANG TỰ CHỮA LÀNH LÕI NGẦM v5.0.1 (WD:%d | WK:%d)...", wdPid, wkPid];
        _daemonStatusLabel.textColor = [UIColor systemYellowColor];
    } else {
        _daemonStatusLabel.text = @"○ LÕI NGẦM ĐANG TẮT";
        _daemonStatusLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    }

    if (st.pauseEndEpoch > now && (wkPid > 0 || wdPid > 0) && _cfg.masterEnabled) {
        int rem = (int)ceil(st.pauseEndEpoch - now);
        _phaseLabel.text = [NSString stringWithFormat:@"ĐANG NGHỈ XẢ ĐƠN FOOD — Tự bật lại sau: %02d:%02d", rem / 60, rem % 60];
        _skipPauseBtn.hidden = NO;
    } else {
        _phaseLabel.text = [NSString stringWithFormat:@"Trạng thái: %@", st.phaseDescription ?: @"Đang canh đơn"];
        _skipPauseBtn.hidden = YES;
    }

    if (st.lastRelayedEpoch > 0.0 && st.lastRelayedSummary.length > 0) {
        int ago = MAX(0, (int)llround(now - st.lastRelayedEpoch));
        NSString *agoStr = (ago < 60)
            ? [NSString stringWithFormat:@"%ds trước", ago]
            : [NSString stringWithFormat:@"%dp trước", ago / 60];
        _lastMapRelayLabel.text = [NSString stringWithFormat:@"Bắn Map gần nhất (%@): %@", agoStr, st.lastRelayedSummary];
        _lastMapRelayLabel.textColor = [UIColor colorWithRed:0.35 green:0.95 blue:0.78 alpha:1.0];
    } else {
        _lastMapRelayLabel.text = @"Bắn Map: Sẵn sàng hứng nút 'Điều hướng' từ Xanh SM";
        _lastMapRelayLabel.textColor = [UIColor colorWithWhite:0.72 alpha:1.0];
    }

    if (!_gmapsCheckInFlight && (_lastGmapsCheckEpoch == 0.0 || (now - _lastGmapsCheckEpoch) >= 5.0)) {
        _gmapsCheckInFlight = YES;
        _lastGmapsCheckEpoch = now;
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            BOOL installed = isGoogleMapsInstalledOnDevice();
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                strongSelf->_cachedGmapsInstalled = installed;
                strongSelf->_gmapsCheckInFlight = NO;
                if (installed) {
                    strongSelf->_lblGmapsStatus.text = @"PHÁT HIỆN MÁY NÀY VẪN CÒN APP GOOGLE MAPS!\nHãy xóa Google Maps trên chiếc iPhone 8 này để: (1) Nhẹ ~400MB RAM hết đơ Wi-Fi, (2) Khi bấm 'Điều hướng' trong Xanh SM thì iOS chuyển thẳng tọa độ qua Pin & Nhiệt Độ bắn sang máy thứ 2!";
                    strongSelf->_lblGmapsStatus.textColor = [UIColor systemOrangeColor];
                } else {
                    strongSelf->_lblGmapsStatus.text = @"CHUẨN BÀI: Máy này đã gỡ Google Maps — Bấm 'Điều hướng' trong Xanh SM sẽ bắn thẳng tọa độ sang máy thứ 2 trong 0.2s!";
                    strongSelf->_lblGmapsStatus.textColor = [UIColor systemGreenColor];
                }
            });
        });
    } else if (_lblGmapsStatus.text.length == 0) {
        _lblGmapsStatus.text = @"Đang kiểm tra trạng thái app Google Maps trên máy...";
        _lblGmapsStatus.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
    }

    _statsLabel.text = [NSString stringWithFormat:@"Đã nhận: %ld cuốc  |  Đã X Food: %ld đơn",
                        (long)st.statAcceptedCount, (long)st.statRejectedCount];

    NSString *logs = readDaemonLogs();
    if (![_logTextView.text isEqualToString:logs]) {
        _logTextView.text = logs;
        if (_logTextView.text.length > 10) {
            [_logTextView scrollRangeToVisible:NSMakeRange(_logTextView.text.length - 1, 1)];
        }
    }
}

@end
