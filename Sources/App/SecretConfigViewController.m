#import "SecretConfigViewController.h"
#import "CoordinatePickerViewController.h"
#import "SharedConfig.h"
#import <notify.h>

@implementation SecretConfigViewController {
    FilterConfig *_cfg;
    UIScrollView *_scrollView;
    UIStackView *_stackView;

    // Card 0: Live Status, Nav Locks, Pause Countdown & Counters
    UILabel *_daemonStatusLabel;
    UILabel *_phaseLabel;
    UILabel *_navLockLabel;
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

    // Card 2: 2-Min Pause & Kill/Relaunch Driver App
    UISwitch *_swPauseFood;
    UILabel  *_lblPauseSec;    UISlider *_slPauseSec;
    UISwitch *_swAutoKill;
    UILabel  *_lblRelaunchSec; UISlider *_slRelaunchSec;
    UILabel  *_lblDriverApp;

    // Card 3: Auto-Tap Blue Navigation (Pickup & Dropoff)
    UISwitch *_swNavPickup;
    UISwitch *_swNavDropoff;
    UILabel  *_lblNavTaps;     UISlider *_slNavTaps;
    UILabel  *_lblNavGapMs;    UISlider *_slNavGapMs;
    UILabel  *_lblNavSettleMs; UISlider *_slNavSettleMs;

    // Card 4: 5 Coordinates Calibration
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
    UILabel *_lblNavOffX;      UISlider *_slNavOffX;
    UILabel *_lblNavOffY;      UISlider *_slNavOffY;

    UILabel *_lblManCloseX;    UISlider *_slManCloseX;
    UILabel *_lblManCloseY;    UISlider *_slManCloseY;
    UILabel *_lblManAcceptX;   UISlider *_slManAcceptX;
    UILabel *_lblManAcceptY;   UISlider *_slManAcceptY;
    UILabel *_lblManOfflineX;  UISlider *_slManOfflineX;
    UILabel *_lblManOfflineY;  UISlider *_slManOfflineY;
    UILabel *_lblManOnlineX;   UISlider *_slManOnlineX;
    UILabel *_lblManOnlineY;   UISlider *_slManOnlineY;
    UILabel *_lblManNavX;      UISlider *_slManNavX;
    UILabel *_lblManNavY;      UISlider *_slManNavY;

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
    int _statsNotifyToken;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Tinh Chỉnh Lọc Đơn v4.0";
    self.view.backgroundColor = [UIColor colorWithRed:0.06 green:0.07 blue:0.09 alpha:1.0];

    UIBarButtonItem *closeItem = [[UIBarButtonItem alloc] initWithTitle:@"Đóng"
                                                                  style:UIBarButtonItemStyleDone
                                                                 target:self
                                                                 action:@selector(closePanel)];
    closeItem.tintColor = [UIColor systemTealColor];
    self.navigationItem.rightBarButtonItem = closeItem;

    _cfg = [FilterConfig loadFromDisk];
    if (_cfg.masterEnabled) {
        startFilterDaemonIfNeeded();
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

    // --- CARD 0: LIVE STATUS, NAV LOCKS & COUNTDOWN ---
    UIStackView *statBody = nil;
    [self makeCardWithTitle:@"Trạng Thái Trực Tiếp & Khóa Điều Hướng" addTo:_stackView outBody:&statBody];

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

    UIStackView *navLockRow = [[UIStackView alloc] init];
    navLockRow.axis = UILayoutConstraintAxisHorizontal;
    navLockRow.alignment = UIStackViewAlignmentCenter;

    _navLockLabel = [[UILabel alloc] init];
    _navLockLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
    _navLockLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    _navLockLabel.numberOfLines = 0;
    [navLockRow addArrangedSubview:_navLockLabel];

    UIButton *resetNavBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [resetNavBtn setTitle:@"Mở khóa Map" forState:UIControlStateNormal];
    [resetNavBtn setTitleColor:[UIColor systemTealColor] forState:UIControlStateNormal];
    resetNavBtn.titleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightBold];
    [resetNavBtn addTarget:self action:@selector(resetNavLocksTapped) forControlEvents:UIControlEventTouchUpInside];
    [navLockRow addArrangedSubview:resetNavBtn];
    [statBody addArrangedSubview:navLockRow];

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

    UIButton *diagBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [diagBtn setTitle:@"Test Quét Màn & Đọc Chữ (Sau 4 Giây)" forState:UIControlStateNormal];
    [diagBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    diagBtn.titleLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightBold];
    diagBtn.backgroundColor = [UIColor colorWithRed:0.16 green:0.45 blue:0.82 alpha:1.0];
    diagBtn.layer.cornerRadius = 8;
    [diagBtn.heightAnchor constraintEqualToConstant:40].active = YES;
    [diagBtn addTarget:self action:@selector(diagCaptureTapped) forControlEvents:UIControlEventTouchUpInside];
    [statBody addArrangedSubview:diagBtn];

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
                            subtitle:@"Rung 1 nhịp khi hủy/tap Map, rung 2 nhịp khi Nhận"
                              action:@selector(generalControlChanged)];

    _swDryRun = [self addSwitchRowTo:sec1
                               title:@"Chế độ Chạy Thử (Dry-Run)"
                            subtitle:@"Chỉ đọc chữ + ghi Log, KHÔNG chạm thật"
                              action:@selector(generalControlChanged)];

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

    // --- CARD 3: AUTO-TAP BLUE NAVIGATION BUTTON (ANTI-LOOP) ---
    UIStackView *sec3 = nil;
    [self makeCardWithTitle:@"3. Auto Tap Nút Xanh Điều Hướng (Chống Lặp)" addTo:_stackView outBody:&sec3];

    _swNavPickup = [self addSwitchRowTo:sec3
                                  title:@"Auto tap Map khi tới màn 'Đã đến điểm đón'"
                               subtitle:@"Chỉ bấm 1 lần duy nhất ở Pha Đón khách"
                                 action:@selector(generalControlChanged)];

    _swNavDropoff = [self addSwitchRowTo:sec3
                                   title:@"Auto tap Map khi tới màn 'Hoàn thành chuyến'"
                                subtitle:@"Chỉ bấm 1 lần duy nhất ở Pha Trả khách (Tự mở khóa khi hiện 'Xác nhận hoàn thành' hoặc về sảnh chờ)"
                                  action:@selector(generalControlChanged)];

    _slNavTaps     = [self addSliderRowTo:sec3 min:1.0f   max:5.0f    outLabel:&_lblNavTaps     action:@selector(sliderChanged)];
    _slNavGapMs    = [self addSliderRowTo:sec3 min:100.0f max:350.0f  outLabel:&_lblNavGapMs    action:@selector(sliderChanged)];
    _slNavSettleMs = [self addSliderRowTo:sec3 min:300.0f max:2000.0f outLabel:&_lblNavSettleMs action:@selector(sliderChanged)];

    // --- CARD 4: 5 COORDINATES & SCREENSHOT PICKER ---
    UIStackView *sec4 = nil;
    [self makeCardWithTitle:@"4. Tinh Chỉnh 5 Tọa Độ & Kéo Hồng Tâm" addTo:_stackView outBody:&sec4];

    _segCoordMode = [[UISegmentedControl alloc] initWithItems:@[@"Bám Chữ + Bù Lệch", @"Tọa Độ Tĩnh / Ảnh"]];
    _segCoordMode.selectedSegmentTintColor = [UIColor colorWithRed:0.0 green:0.65 blue:0.60 alpha:1.0];
    [_segCoordMode setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor whiteColor]} forState:UIControlStateNormal];
    [_segCoordMode addTarget:self action:@selector(generalControlChanged) forControlEvents:UIControlEventValueChanged];
    [sec4 addArrangedSubview:_segCoordMode];

    UIButton *pickImgBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [pickImgBtn setTitle:@"Mở Ảnh Màn Hình Kéo 5 Hồng Tâm" forState:UIControlStateNormal];
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
    _slNavOffX    = [self addSliderRowTo:_autoCoordGroup min:-40.0f max:40.0f outLabel:&_lblNavOffX action:@selector(sliderChanged)];
    _slNavOffY    = [self addSliderRowTo:_autoCoordGroup min:-60.0f max:10.0f outLabel:&_lblNavOffY action:@selector(sliderChanged)];
    [sec4 addArrangedSubview:_autoCoordGroup];

    // Group B: Manual Fixed X/Y for all 5 buttons
    _manualCoordGroup = [[UIStackView alloc] init];
    _manualCoordGroup.axis = UILayoutConstraintAxisVertical;
    _manualCoordGroup.spacing = 10;
    _slManCloseX   = [self addSliderRowTo:_manualCoordGroup min:10.0f max:365.0f outLabel:&_lblManCloseX action:@selector(sliderChanged)];
    _slManCloseY   = [self addSliderRowTo:_manualCoordGroup min:15.0f max:200.0f outLabel:&_lblManCloseY action:@selector(sliderChanged)];
    _slManAcceptX  = [self addSliderRowTo:_manualCoordGroup min:20.0f max:355.0f outLabel:&_lblManAcceptX action:@selector(sliderChanged)];
    _slManAcceptY  = [self addSliderRowTo:_manualCoordGroup min:450.0f max:662.0f outLabel:&_lblManAcceptY action:@selector(sliderChanged)];
    _slManOnlineX  = [self addSliderRowTo:_manualCoordGroup min:30.0f max:345.0f outLabel:&_lblManOnlineX action:@selector(sliderChanged)];
    _slManOnlineY  = [self addSliderRowTo:_manualCoordGroup min:180.0f max:500.0f outLabel:&_lblManOnlineY action:@selector(sliderChanged)];
    _slManNavX     = [self addSliderRowTo:_manualCoordGroup min:150.0f max:365.0f outLabel:&_lblManNavX action:@selector(sliderChanged)];
    _slManNavY     = [self addSliderRowTo:_manualCoordGroup min:150.0f max:500.0f outLabel:&_lblManNavY action:@selector(sliderChanged)];
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

    _swPauseFood.on     = _cfg.pauseAfterRejectFood;
    _slPauseSec.value   = (float)_cfg.pauseDurationSec;
    _swAutoKill.on      = _cfg.autoKillAndRelaunchApp;
    _slRelaunchSec.value= (float)_cfg.relaunchLeadSec;

    _swNavPickup.on     = _cfg.autoNavPickup;
    _swNavDropoff.on    = _cfg.autoNavDropoff;
    _slNavTaps.value    = (float)_cfg.navTapCount;
    _slNavGapMs.value   = (float)_cfg.navTapIntervalMs;
    _slNavSettleMs.value= (float)_cfg.navSettleDelayMs;

    _segCoordMode.selectedSegmentIndex = _cfg.coordMode;

    _slCloseRatio.value = (float)_cfg.closeXRatio;
    _slCloseOffX.value  = (float)_cfg.closeOffsetX;
    _slCloseOffY.value  = (float)_cfg.closeOffsetY;
    _slAcceptOffX.value = (float)_cfg.acceptOffsetX;
    _slAcceptOffY.value = (float)_cfg.acceptOffsetY;
    _slOnlineOffX.value = (float)_cfg.onlineOffsetX;
    _slOnlineOffY.value = (float)_cfg.onlineOffsetY;
    _slNavOffX.value    = (float)_cfg.navOffsetX;
    _slNavOffY.value    = (float)_cfg.navOffsetY;

    _slManCloseX.value   = (float)_cfg.manualCloseX;
    _slManCloseY.value   = (float)_cfg.manualCloseY;
    _slManAcceptX.value  = (float)_cfg.manualAcceptX;
    _slManAcceptY.value  = (float)_cfg.manualAcceptY;
    _slManOfflineX.value = (float)_cfg.manualOfflineX;
    _slManOfflineY.value = (float)_cfg.manualOfflineY;
    _slManOnlineX.value  = (float)_cfg.manualOnlineX;
    _slManOnlineY.value  = (float)_cfg.manualOnlineY;
    _slManNavX.value     = (float)_cfg.manualNavX;
    _slManNavY.value     = (float)_cfg.manualNavY;

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

- (void)updateValueLabels {
    _priceControlRow.alpha = _cfg.rejectAllFood ? 0.35 : 1.0;
    _priceControlRow.userInteractionEnabled = !_cfg.rejectAllFood;
    _lblMinFoodPrice.text = [NSString stringWithFormat:@"Giá tối thiểu nhận Green Food: %@\n(Từ mức này trở lên tự Nhận, thấp hơn tự bấm X)",
                             [self formatVND:_cfg.minFoodPriceVND]];

    _lblPauseSec.text    = [NSString stringWithFormat:@"Thời gian tắt nhận chuyến: %ld giây (%.1f phút)",
                            (long)_cfg.pauseDurationSec, _cfg.pauseDurationSec / 60.0];
    _lblRelaunchSec.text = [NSString stringWithFormat:@"Mở lại App Tài xế sớm trước khi hết giờ: %ld giây",
                            (long)_cfg.relaunchLeadSec];
    _lblDriverApp.text   = [NSString stringWithFormat:@"App Tài xế mục tiêu: %@ (%@)",
                            _cfg.driverAppDisplayName.length ? _cfg.driverAppDisplayName : @"Chưa chọn",
                            _cfg.driverAppBundleID.length ? _cfg.driverAppBundleID : @"Tự động dò"];

    _lblNavTaps.text     = [NSString stringWithFormat:@"Số lần tap liên tiếp vào nút xanh Điều hướng: %ld lần", (long)_cfg.navTapCount];
    _lblNavGapMs.text    = [NSString stringWithFormat:@"Khoảng cách giữa các nhịp tap Map: %ld ms", (long)_cfg.navTapIntervalMs];
    _lblNavSettleMs.text = [NSString stringWithFormat:@"Chờ thẻ khách đứng yên trước khi tap Map: %ld ms", (long)_cfg.navSettleDelayMs];

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
    _lblNavOffX.text    = [NSString stringWithFormat:@"5. Bù lệch ngang nút xanh [➤ Map] (ΔX): %+.0f pt", _cfg.navOffsetX];
    _lblNavOffY.text    = [NSString stringWithFormat:@"5. Khoảng cách dọc nút xanh so với chữ 'Điều hướng': %+.0f pt", _cfg.navOffsetY];

    _lblManCloseX.text   = [NSString stringWithFormat:@"1. Tọa độ X nút [X]: %.0f pt", _cfg.manualCloseX];
    _lblManCloseY.text   = [NSString stringWithFormat:@"1. Tọa độ Y nút [X]: %.0f pt", _cfg.manualCloseY];
    _lblManAcceptX.text  = [NSString stringWithFormat:@"2. Tọa độ X [Nhận chuyến]: %.0f pt", _cfg.manualAcceptX];
    _lblManAcceptY.text  = [NSString stringWithFormat:@"2. Tọa độ Y [Nhận chuyến]: %.0f pt", _cfg.manualAcceptY];
    _lblManOnlineX.text  = [NSString stringWithFormat:@"4. Tọa độ X [Mở nhận chuyến]: %.0f pt", _cfg.manualOnlineX];
    _lblManOnlineY.text  = [NSString stringWithFormat:@"4. Tọa độ Y [Mở nhận chuyến]: %.0f pt", _cfg.manualOnlineY];
    _lblManNavX.text     = [NSString stringWithFormat:@"5. Tọa độ X nút xanh [➤ Map]: %.0f pt", _cfg.manualNavX];
    _lblManNavY.text     = [NSString stringWithFormat:@"5. Tọa độ Y nút xanh [➤ Map]: %.0f pt", _cfg.manualNavY];

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
    _cfg.masterEnabled = sender.isOn;
    [_cfg saveToDiskAndNotify:YES];

    if (_cfg.masterEnabled) {
        BOOL ok = startFilterDaemonIfNeeded();
        if (!ok) {
            sender.on = NO;
            _cfg.masterEnabled = NO;
            [_cfg saveToDiskAndNotify:NO];
        }
    } else {
        stopFilterDaemon();
    }
    [self refreshStatusAndLogs];
}

- (void)generalControlChanged {
    _cfg.smartCoolMode          = _swSmartCool.isOn;
    _cfg.autoAcceptBike         = _swAutoBike.isOn;
    _cfg.rejectAllFood          = _swRejectAllFood.isOn;
    _cfg.hapticEnabled          = _swHaptic.isOn;
    _cfg.dryRunMode             = _swDryRun.isOn;
    _cfg.pauseAfterRejectFood   = _swPauseFood.isOn;
    _cfg.autoKillAndRelaunchApp = _swAutoKill.isOn;
    _cfg.autoNavPickup          = _swNavPickup.isOn;
    _cfg.autoNavDropoff         = _swNavDropoff.isOn;
    _cfg.coordMode              = (CoordMode)_segCoordMode.selectedSegmentIndex;

    [self updateValueLabels];
    [_cfg saveToDiskAndNotify:YES];
}

- (void)sliderChanged {
    _cfg.pauseDurationSec = (NSInteger)(roundf(_slPauseSec.value / 10.0f) * 10);
    _cfg.relaunchLeadSec  = (NSInteger)roundf(_slRelaunchSec.value);

    _cfg.navTapCount      = (NSInteger)roundf(_slNavTaps.value);
    _cfg.navTapIntervalMs = (NSInteger)(roundf(_slNavGapMs.value / 10.0f) * 10);
    _cfg.navSettleDelayMs = (NSInteger)(roundf(_slNavSettleMs.value / 50.0f) * 50);

    _cfg.closeXRatio   = _slCloseRatio.value;
    _cfg.closeOffsetX  = roundf(_slCloseOffX.value);
    _cfg.closeOffsetY  = roundf(_slCloseOffY.value);
    _cfg.acceptOffsetX = roundf(_slAcceptOffX.value);
    _cfg.acceptOffsetY = roundf(_slAcceptOffY.value);
    _cfg.onlineOffsetX = roundf(_slOnlineOffX.value);
    _cfg.onlineOffsetY = roundf(_slOnlineOffY.value);
    _cfg.navOffsetX    = roundf(_slNavOffX.value);
    _cfg.navOffsetY    = roundf(_slNavOffY.value);

    _cfg.manualCloseX   = roundf(_slManCloseX.value);
    _cfg.manualCloseY   = roundf(_slManCloseY.value);
    _cfg.manualAcceptX  = roundf(_slManAcceptX.value);
    _cfg.manualAcceptY  = roundf(_slManAcceptY.value);
    _cfg.manualOfflineX = roundf(_slManOfflineX.value);
    _cfg.manualOfflineY = roundf(_slManOfflineY.value);
    _cfg.manualOnlineX  = roundf(_slManOnlineX.value);
    _cfg.manualOnlineY  = roundf(_slManOnlineY.value);
    _cfg.manualNavX     = roundf(_slManNavX.value);
    _cfg.manualNavY     = roundf(_slManNavY.value);

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
    [_cfg saveToDiskAndNotify:YES];
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
    killAppByBundleIDAndExec(_cfg.driverAppBundleID, _cfg.driverAppExecName);
    appendDaemonLog(@"[TEST] Đã đóng App Tài xế (%@), sẽ tự mở lại sau 3 giây...", _cfg.driverAppDisplayName);
    [self refreshStatusAndLogs];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        launchAppByBundleID(self->_cfg.driverAppBundleID);
    });
}

#pragma mark - Screenshot Coordinate Picker (5 Pins)

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
                                                                                                 onSave:^(CGPoint closePt, CGPoint acceptPt, CGPoint offlinePt, CGPoint onlinePt, CGPoint navPt) {
            self->_cfg.coordMode      = CoordModeFixedManual;
            self->_cfg.manualCloseX   = round(closePt.x);
            self->_cfg.manualCloseY   = round(closePt.y);
            self->_cfg.manualAcceptX  = round(acceptPt.x);
            self->_cfg.manualAcceptY  = round(acceptPt.y);
            self->_cfg.manualOfflineX = round(offlinePt.x);
            self->_cfg.manualOfflineY = round(offlinePt.y);
            self->_cfg.manualOnlineX  = round(onlinePt.x);
            self->_cfg.manualOnlineY  = round(onlinePt.y);
            self->_cfg.manualNavX     = round(navPt.x);
            self->_cfg.manualNavY     = round(navPt.y);
            [self syncUIFromConfig];
            [self->_cfg saveToDiskAndNotify:YES];
        }];
        [self presentViewController:vc animated:YES completion:nil];
    }];
}

#pragma mark - Live Status, Nav Locks & Logs

- (void)skipPauseTapped {
    notify_post(kNotifySkipPause);
}

- (void)diagCaptureTapped {
    if (getRunningDaemonPID() <= 0) {
        startFilterDaemonIfNeeded();
    }
    notify_post(kNotifyDiagCapture);
    [self refreshStatusAndLogs];
}

- (void)resetNavLocksTapped {
    RuntimeDaemonState *st = [RuntimeDaemonState loadState];
    st.navPickupLocked  = NO;
    st.navDropoffLocked = NO;
    [st saveStateAndNotify:NO];
    notify_post(kNotifyResetNavLocks);
    [self refreshStatusAndLogs];
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

    if ((wkPid > 0 || wdPid > 0) && _cfg.masterEnabled) {
        _daemonStatusLabel.text = [NSString stringWithFormat:@"● BẤT TỬ v4.0 (WD:%d | WK:%d)%@%@",
                                   wdPid, wkPid,
                                   _cfg.smartCoolMode ? @" [MÁT]" : @"",
                                   _cfg.dryRunMode ? @" [THỬ]" : @""];
        _daemonStatusLabel.textColor = [UIColor systemGreenColor];
    } else {
        _daemonStatusLabel.text = @"○ LÕI NGẦM ĐANG TẮT";
        _daemonStatusLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    }

    double now = [[NSDate date] timeIntervalSince1970];
    if (st.pauseEndEpoch > now && (wkPid > 0 || wdPid > 0) && _cfg.masterEnabled) {
        int rem = (int)ceil(st.pauseEndEpoch - now);
        _phaseLabel.text = [NSString stringWithFormat:@"⏳ ĐANG NGHỈ XẢ ĐƠN FOOD — Tự bật lại sau: %02d:%02d", rem / 60, rem % 60];
        _skipPauseBtn.hidden = NO;
    } else {
        _phaseLabel.text = [NSString stringWithFormat:@"Trạng thái: %@", st.phaseDescription ?: @"Đang canh đơn"];
        _skipPauseBtn.hidden = YES;
    }

    _navLockLabel.text = [NSString stringWithFormat:@"Chốt Map: Đón [%@] | Trả [%@]",
                          st.navPickupLocked ? @"ĐÃ KHÓA" : @"MỞ",
                          st.navDropoffLocked ? @"ĐÃ KHÓA" : @"MỞ"];

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
