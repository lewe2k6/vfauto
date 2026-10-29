#import "SecretConfigViewController.h"
#import "CoordinatePickerViewController.h"
#import "SharedConfig.h"
#import <notify.h>

@implementation SecretConfigViewController {
    FilterConfig *_cfg;
    UIScrollView *_scrollView;
    UIStackView *_stackView;

    // Status & Counters
    UILabel *_daemonStatusLabel;
    UILabel *_statsLabel;

    // Section 1: Switches & Price
    UISwitch *_swMaster;
    UISwitch *_swAutoBike;
    UISwitch *_swRejectAllFood;
    UILabel  *_lblMinFoodPrice;
    UIView   *_priceControlRow;
    UISwitch *_swHaptic;
    UISwitch *_swDryRun;

    // Section 2: Coordinates
    UISegmentedControl *_segCoordMode;
    UIStackView *_autoCoordGroup;
    UIStackView *_manualCoordGroup;

    UILabel *_lblCloseRatio;   UISlider *_slCloseRatio;
    UILabel *_lblCloseOffX;    UISlider *_slCloseOffX;
    UILabel *_lblCloseOffY;    UISlider *_slCloseOffY;
    UILabel *_lblAcceptOffX;   UISlider *_slAcceptOffX;
    UILabel *_lblAcceptOffY;   UISlider *_slAcceptOffY;

    UILabel *_lblManCloseX;    UISlider *_slManCloseX;
    UILabel *_lblManCloseY;    UISlider *_slManCloseY;
    UILabel *_lblManAcceptX;   UISlider *_slManAcceptX;
    UILabel *_lblManAcceptY;   UISlider *_slManAcceptY;

    // Section 3: Timing & Humanizer
    UILabel *_lblScanMs;       UISlider *_slScanMs;
    UILabel *_lblAccMinMs;     UISlider *_slAccMinMs;
    UILabel *_lblAccMaxMs;     UISlider *_slAccMaxMs;
    UILabel *_lblRejMinMs;     UISlider *_slRejMinMs;
    UILabel *_lblRejMaxMs;     UISlider *_slRejMaxMs;
    UILabel *_lblJitter;       UISlider *_slJitter;
    UILabel *_lblHoldMin;      UISlider *_slHoldMin;
    UILabel *_lblHoldMax;      UISlider *_slHoldMax;
    UILabel *_lblCooldown;     UISlider *_slCooldown;

    // Section 4: Logs
    UITextView *_logTextView;
    NSTimer *_refreshTimer;
    int _statsNotifyToken;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Tinh Chỉnh Lọc Đơn";
    self.view.backgroundColor = [UIColor colorWithRed:0.06 green:0.07 blue:0.09 alpha:1.0];

    UIBarButtonItem *closeItem = [[UIBarButtonItem alloc] initWithTitle:@"Đóng"
                                                                  style:UIBarButtonItemStyleDone
                                                                 target:self
                                                                 action:@selector(closePanel)];
    closeItem.tintColor = [UIColor systemTealColor];
    self.navigationItem.rightBarButtonItem = closeItem;

    _cfg = [FilterConfig loadFromDisk];

    [self buildScrollLayout];
    [self syncUIFromConfig];
    [self refreshStatusAndLogs];

    __weak typeof(self) weakSelf = self;
    notify_register_dispatch(kNotifyStatsUpdated, &_statsNotifyToken, dispatch_get_main_queue(), ^(int token) {
        [weakSelf reloadCountersFromDisk];
    });

    _refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.5
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

#pragma mark - UI Builders

- (UIView *)makeCardWithTitle:(NSString *)title addTo:(UIStackView *)parent outBody:(UIStackView **)outBody {
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
    lbl.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    lbl.textColor = [UIColor whiteColor];
    lbl.numberOfLines = 0;
    [txtStack addArrangedSubview:lbl];

    if (sub.length > 0) {
        UILabel *sLbl = [[UILabel alloc] init];
        sLbl.text = sub;
        sLbl.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
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
                    outLabel:(UILabel **)outLbl
                      action:(SEL)sel {
    UIStackView *wrap = [[UIStackView alloc] init];
    wrap.axis = UILayoutConstraintAxisVertical;
    wrap.spacing = 4;

    UILabel *lbl = [[UILabel alloc] init];
    lbl.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];
    lbl.textColor = [UIColor colorWithWhite:0.90 alpha:1.0];
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
        [_stackView.bottomAnchor constraintEqualToAnchor:_scrollView.bottomAnchor constant:-30],
        [_stackView.leadingAnchor constraintEqualToAnchor:_scrollView.leadingAnchor constant:12],
        [_stackView.trailingAnchor constraintEqualToAnchor:_scrollView.trailingAnchor constant:-12],
        [_stackView.widthAnchor constraintEqualToAnchor:_scrollView.widthAnchor constant:-24]
    ]];

    // --- CARD 0: STATUS & DAILY COUNTERS ---
    UIStackView *statBody = nil;
    [self makeCardWithTitle:@"Trạng Thái Lõi Ngầm & Thống Kê Ca" addTo:_stackView outBody:&statBody];

    _daemonStatusLabel = [[UILabel alloc] init];
    _daemonStatusLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightBold];
    _daemonStatusLabel.textColor = [UIColor systemYellowColor];
    [statBody addArrangedSubview:_daemonStatusLabel];

    UIStackView *statRow = [[UIStackView alloc] init];
    statRow.axis = UILayoutConstraintAxisHorizontal;
    statRow.alignment = UIStackViewAlignmentCenter;

    _statsLabel = [[UILabel alloc] init];
    _statsLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];
    _statsLabel.textColor = [UIColor colorWithWhite:0.88 alpha:1.0];
    [statRow addArrangedSubview:_statsLabel];

    UIButton *resetStatBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [resetStatBtn setTitle:@"Reset số" forState:UIControlStateNormal];
    [resetStatBtn setTitleColor:[UIColor systemOrangeColor] forState:UIControlStateNormal];
    resetStatBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [resetStatBtn addTarget:self action:@selector(resetStatsTapped) forControlEvents:UIControlEventTouchUpInside];
    [statRow addArrangedSubview:resetStatBtn];
    [statBody addArrangedSubview:statRow];

    // --- CARD 1: TACTICAL SWITCHES & GREEN FOOD MIN PRICE ---
    UIStackView *sec1 = nil;
    [self makeCardWithTitle:@"1. Công Tắc Lọc Đơn & Ngưỡng Giá Green Food" addTo:_stackView outBody:&sec1];

    _swMaster = [self addSwitchRowTo:sec1
                               title:@"Chạy Lõi Auto Ngầm (Master)"
                            subtitle:@"Bật xong vuốt tắt app này đi lõi vẫn chạy ngầm"
                              action:@selector(masterSwitchChanged:)];

    _swAutoBike = [self addSwitchRowTo:sec1
                                 title:@"Tự động [Nhận] chuyến Bike / Khác"
                              subtitle:@"Đớp ngay các đơn không phải Green Food"
                                action:@selector(generalControlChanged)];

    _swRejectAllFood = [self addSwitchRowTo:sec1
                                      title:@"Hủy sạch 100% Green Food (Mọi mức giá)"
                                   subtitle:@"Tắt mục này để lọc theo mức giá tối thiểu bên dưới"
                                     action:@selector(generalControlChanged)];

    // Green Food Min Price Widget
    UIStackView *priceWrap = [[UIStackView alloc] init];
    priceWrap.axis = UILayoutConstraintAxisVertical;
    priceWrap.spacing = 8;

    _lblMinFoodPrice = [[UILabel alloc] init];
    _lblMinFoodPrice.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightBold];
    _lblMinFoodPrice.textColor = [UIColor systemGreenColor];
    _lblMinFoodPrice.userInteractionEnabled = YES;
    UITapGestureRecognizer *tapPrice = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(promptExactFoodPrice)];
    [_lblMinFoodPrice addGestureRecognizer:tapPrice];
    [priceWrap addArrangedSubview:_lblMinFoodPrice];

    UIStackView *btnRow = [[UIStackView alloc] init];
    btnRow.axis = UILayoutConstraintAxisHorizontal;
    btnRow.distribution = UIStackViewDistributionFillEqually;
    btnRow.spacing = 6;
    [btnRow addArrangedSubview:[self makeStepButton:@"-5k" tag:-5000 action:@selector(stepFoodPrice:)]];
    [btnRow addArrangedSubview:[self makeStepButton:@"-1k" tag:-1000 action:@selector(stepFoodPrice:)]];
    [btnRow addArrangedSubview:[self makeStepButton:@"+1k" tag:1000  action:@selector(stepFoodPrice:)]];
    [btnRow addArrangedSubview:[self makeStepButton:@"+5k" tag:5000  action:@selector(stepFoodPrice:)]];
    [btnRow addArrangedSubview:[self makeStepButton:@"Nhập số" tag:0 action:@selector(promptExactFoodPrice)]];
    [priceWrap addArrangedSubview:btnRow];

    _priceControlRow = priceWrap;
    [sec1 addArrangedSubview:priceWrap];

    _swHaptic = [self addSwitchRowTo:sec1
                               title:@"Báo rung Haptic khi xử lý đơn"
                            subtitle:@"Rung 1 nhịp khi hủy [X], rung 2 nhịp khi [Nhận]"
                              action:@selector(generalControlChanged)];

    _swDryRun = [self addSwitchRowTo:sec1
                               title:@"Chế độ Chạy Thử (Dry-Run)"
                            subtitle:@"Chỉ đọc giá + báo rung + ghi Log, KHÔNG chạm thật"
                              action:@selector(generalControlChanged)];

    // --- CARD 2: COORDINATE CALIBRATION ---
    UIStackView *sec2 = nil;
    [self makeCardWithTitle:@"2. Tinh Chỉnh Tọa Độ Nút [X] & [Nhận]" addTo:_stackView outBody:&sec2];

    _segCoordMode = [[UISegmentedControl alloc] initWithItems:@[@"Bám Chữ + Bù Lệch", @"Tọa Độ Tĩnh / Ảnh"]];
    _segCoordMode.selectedSegmentTintColor = [UIColor colorWithRed:0.0 green:0.65 blue:0.60 alpha:1.0];
    [_segCoordMode setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor whiteColor]} forState:UIControlStateNormal];
    [_segCoordMode addTarget:self action:@selector(generalControlChanged) forControlEvents:UIControlEventValueChanged];
    [sec2 addArrangedSubview:_segCoordMode];

    // Group A: Auto OCR + Offset
    _autoCoordGroup = [[UIStackView alloc] init];
    _autoCoordGroup.axis = UILayoutConstraintAxisVertical;
    _autoCoordGroup.spacing = 10;
    _slCloseRatio  = [self addSliderRowTo:_autoCoordGroup min:0.80f max:0.98f outLabel:&_lblCloseRatio action:@selector(sliderChanged)];
    _slCloseOffX   = [self addSliderRowTo:_autoCoordGroup min:-50.0f max:50.0f outLabel:&_lblCloseOffX action:@selector(sliderChanged)];
    _slCloseOffY   = [self addSliderRowTo:_autoCoordGroup min:-50.0f max:50.0f outLabel:&_lblCloseOffY action:@selector(sliderChanged)];
    _slAcceptOffX  = [self addSliderRowTo:_autoCoordGroup min:-80.0f max:80.0f outLabel:&_lblAcceptOffX action:@selector(sliderChanged)];
    _slAcceptOffY  = [self addSliderRowTo:_autoCoordGroup min:-50.0f max:50.0f outLabel:&_lblAcceptOffY action:@selector(sliderChanged)];
    [sec2 addArrangedSubview:_autoCoordGroup];

    // Group B: Fixed Manual + Visual Screenshot Picker
    _manualCoordGroup = [[UIStackView alloc] init];
    _manualCoordGroup.axis = UILayoutConstraintAxisVertical;
    _manualCoordGroup.spacing = 10;

    UIButton *pickImgBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [pickImgBtn setTitle:@"Mở Ảnh Màn Hình Để Kéo Hồng Tâm" forState:UIControlStateNormal];
    [pickImgBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    pickImgBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    pickImgBtn.backgroundColor = [UIColor colorWithRed:0.0 green:0.55 blue:0.85 alpha:1.0];
    pickImgBtn.layer.cornerRadius = 10;
    [pickImgBtn.heightAnchor constraintEqualToConstant:42].active = YES;
    [pickImgBtn addTarget:self action:@selector(openScreenshotPicker) forControlEvents:UIControlEventTouchUpInside];
    [_manualCoordGroup addArrangedSubview:pickImgBtn];

    _slManCloseX   = [self addSliderRowTo:_manualCoordGroup min:10.0f max:365.0f outLabel:&_lblManCloseX action:@selector(sliderChanged)];
    _slManCloseY   = [self addSliderRowTo:_manualCoordGroup min:15.0f max:300.0f outLabel:&_lblManCloseY action:@selector(sliderChanged)];
    _slManAcceptX  = [self addSliderRowTo:_manualCoordGroup min:20.0f max:355.0f outLabel:&_lblManAcceptX action:@selector(sliderChanged)];
    _slManAcceptY  = [self addSliderRowTo:_manualCoordGroup min:400.0f max:660.0f outLabel:&_lblManAcceptY action:@selector(sliderChanged)];
    [sec2 addArrangedSubview:_manualCoordGroup];

    // --- CARD 3: RANDOM DELAY & HUMANIZER ---
    UIStackView *sec3 = nil;
    [self makeCardWithTitle:@"3. Random Delay & Giả Lập Ngón Tay" addTo:_stackView outBody:&sec3];

    _slScanMs   = [self addSliderRowTo:sec3 min:150.0f max:1500.0f outLabel:&_lblScanMs action:@selector(sliderChanged)];
    _slAccMinMs = [self addSliderRowTo:sec3 min:80.0f  max:2000.0f outLabel:&_lblAccMinMs action:@selector(sliderChanged)];
    _slAccMaxMs = [self addSliderRowTo:sec3 min:120.0f max:3000.0f outLabel:&_lblAccMaxMs action:@selector(sliderChanged)];
    _slRejMinMs = [self addSliderRowTo:sec3 min:150.0f max:3000.0f outLabel:&_lblRejMinMs action:@selector(sliderChanged)];
    _slRejMaxMs = [self addSliderRowTo:sec3 min:250.0f max:4000.0f outLabel:&_lblRejMaxMs action:@selector(sliderChanged)];
    _slJitter   = [self addSliderRowTo:sec3 min:0.0f   max:20.0f   outLabel:&_lblJitter action:@selector(sliderChanged)];
    _slHoldMin  = [self addSliderRowTo:sec3 min:30.0f  max:120.0f  outLabel:&_lblHoldMin action:@selector(sliderChanged)];
    _slHoldMax  = [self addSliderRowTo:sec3 min:45.0f  max:180.0f  outLabel:&_lblHoldMax action:@selector(sliderChanged)];
    _slCooldown = [self addSliderRowTo:sec3 min:1000.0f max:6000.0f outLabel:&_lblCooldown action:@selector(sliderChanged)];

    // --- CARD 4: LIVE LOG ---
    UIStackView *sec4 = nil;
    [self makeCardWithTitle:@"4. Nhật Ký Xử Lý Trực Tiếp (Live Log)" addTo:_stackView outBody:&sec4];

    _logTextView = [[UITextView alloc] init];
    _logTextView.editable = NO;
    _logTextView.backgroundColor = [UIColor colorWithWhite:0.05 alpha:1.0];
    _logTextView.textColor = [UIColor colorWithRed:0.45 green:0.95 blue:0.55 alpha:1.0];
    _logTextView.font = [UIFont monospacedSystemFontOfSize:11.5 weight:UIFontWeightRegular];
    _logTextView.layer.cornerRadius = 8;
    [_logTextView.heightAnchor constraintEqualToConstant:190].active = YES;
    [sec4 addArrangedSubview:_logTextView];

    UIButton *clearLogBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [clearLogBtn setTitle:@"Xóa sạch Nhật ký" forState:UIControlStateNormal];
    [clearLogBtn setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    [clearLogBtn addTarget:self action:@selector(clearLogsTapped) forControlEvents:UIControlEventTouchUpInside];
    [sec4 addArrangedSubview:clearLogBtn];
}

#pragma mark - State Sync

- (NSString *)formatVND:(NSInteger)vnd {
    NSNumberFormatter *nf = [[NSNumberFormatter alloc] init];
    nf.numberStyle = NSNumberFormatterDecimalStyle;
    nf.groupingSeparator = @".";
    return [NSString stringWithFormat:@"%@đ", [nf stringFromNumber:@(vnd)]];
}

- (void)syncUIFromConfig {
    _swMaster.on        = _cfg.masterEnabled;
    _swAutoBike.on      = _cfg.autoAcceptBike;
    _swRejectAllFood.on = _cfg.rejectAllFood;
    _swHaptic.on        = _cfg.hapticEnabled;
    _swDryRun.on        = _cfg.dryRunMode;

    _segCoordMode.selectedSegmentIndex = _cfg.coordMode;

    _slCloseRatio.value = (float)_cfg.closeXRatio;
    _slCloseOffX.value  = (float)_cfg.closeOffsetX;
    _slCloseOffY.value  = (float)_cfg.closeOffsetY;
    _slAcceptOffX.value = (float)_cfg.acceptOffsetX;
    _slAcceptOffY.value = (float)_cfg.acceptOffsetY;

    _slManCloseX.value  = (float)_cfg.manualCloseX;
    _slManCloseY.value  = (float)_cfg.manualCloseY;
    _slManAcceptX.value = (float)_cfg.manualAcceptX;
    _slManAcceptY.value = (float)_cfg.manualAcceptY;

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
    _priceControlRow.alpha = _cfg.rejectAllFood ? 0.38 : 1.0;
    _priceControlRow.userInteractionEnabled = !_cfg.rejectAllFood;
    _lblMinFoodPrice.text = [NSString stringWithFormat:@"Giá tối thiểu nhận Green Food: %@ (Dưới mức này bấm X)",
                             [self formatVND:_cfg.minFoodPriceVND]];

    BOOL isManual = (_cfg.coordMode == CoordModeFixedManual);
    _autoCoordGroup.hidden   = isManual;
    _manualCoordGroup.hidden = !isManual;

    _lblCloseRatio.text = [NSString stringWithFormat:@"Vị trí ngang nút [X]: %.1f%% màn hình (~%.0fpt)",
                           _cfg.closeXRatio * 100.0, 375.0 * _cfg.closeXRatio];
    _lblCloseOffX.text  = [NSString stringWithFormat:@"Bù lệch ngang nút [X] (ΔX): %+.0f pt", _cfg.closeOffsetX];
    _lblCloseOffY.text  = [NSString stringWithFormat:@"Bù lệch dọc nút [X] (ΔY): %+.0f pt", _cfg.closeOffsetY];
    _lblAcceptOffX.text = [NSString stringWithFormat:@"Bù lệch ngang nút [Nhận] (ΔX): %+.0f pt", _cfg.acceptOffsetX];
    _lblAcceptOffY.text = [NSString stringWithFormat:@"Bù lệch dọc nút [Nhận] (ΔY): %+.0f pt", _cfg.acceptOffsetY];

    _lblManCloseX.text  = [NSString stringWithFormat:@"Tọa độ X nút [X]: %.0f pt", _cfg.manualCloseX];
    _lblManCloseY.text  = [NSString stringWithFormat:@"Tọa độ Y nút [X]: %.0f pt", _cfg.manualCloseY];
    _lblManAcceptX.text = [NSString stringWithFormat:@"Tọa độ X nút [Nhận]: %.0f pt", _cfg.manualAcceptX];
    _lblManAcceptY.text = [NSString stringWithFormat:@"Tọa độ Y nút [Nhận]: %.0f pt", _cfg.manualAcceptY];

    _lblScanMs.text   = [NSString stringWithFormat:@"Chu kỳ quét màn hình: %ld ms", (long)_cfg.scanIntervalMs];
    _lblAccMinMs.text = [NSString stringWithFormat:@"Delay bấm [Nhận] Tối thiểu: %ld ms", (long)_cfg.acceptDelayMinMs];
    _lblAccMaxMs.text = [NSString stringWithFormat:@"Delay bấm [Nhận] Tối đa: %ld ms", (long)_cfg.acceptDelayMaxMs];
    _lblRejMinMs.text = [NSString stringWithFormat:@"Delay bấm [X] Tối thiểu: %ld ms", (long)_cfg.rejectDelayMinMs];
    _lblRejMaxMs.text = [NSString stringWithFormat:@"Delay bấm [X] Tối đa: %ld ms", (long)_cfg.rejectDelayMaxMs];
    _lblJitter.text   = [NSString stringWithFormat:@"Bán kính lệch ngón tay (Jitter): ±%.1f pt", _cfg.jitterRadiusPt];
    _lblHoldMin.text  = [NSString stringWithFormat:@"Nhấn giữ ngón tay Min: %ld ms", (long)_cfg.holdMinMs];
    _lblHoldMax.text  = [NSString stringWithFormat:@"Nhấn giữ ngón tay Max: %ld ms", (long)_cfg.holdMaxMs];
    _lblCooldown.text = [NSString stringWithFormat:@"Nghỉ sau khi bấm (Cooldown): %.1f giây", _cfg.cooldownMs / 1000.0];
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
    _cfg.autoAcceptBike = _swAutoBike.isOn;
    _cfg.rejectAllFood  = _swRejectAllFood.isOn;
    _cfg.hapticEnabled  = _swHaptic.isOn;
    _cfg.dryRunMode     = _swDryRun.isOn;
    _cfg.coordMode      = (CoordMode)_segCoordMode.selectedSegmentIndex;

    [self updateValueLabels];
    [_cfg saveToDiskAndNotify:YES];
}

- (void)sliderChanged {
    _cfg.closeXRatio   = _slCloseRatio.value;
    _cfg.closeOffsetX  = roundf(_slCloseOffX.value);
    _cfg.closeOffsetY  = roundf(_slCloseOffY.value);
    _cfg.acceptOffsetX = roundf(_slAcceptOffX.value);
    _cfg.acceptOffsetY = roundf(_slAcceptOffY.value);

    _cfg.manualCloseX  = roundf(_slManCloseX.value);
    _cfg.manualCloseY  = roundf(_slManCloseY.value);
    _cfg.manualAcceptX = roundf(_slManAcceptX.value);
    _cfg.manualAcceptY = roundf(_slManAcceptY.value);

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
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Nhập Giá Tối Thiểu Green Food"
                                                                message:@"Ví dụ nhập 25000 (Đơn từ 25.000đ trở lên sẽ tự Nhận, dưới 25.000đ sẽ tự bấm X)"
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.keyboardType = UIKeyboardTypeNumberPad;
        tf.text = [NSString stringWithFormat:@"%ld", (long)self->_cfg.minFoodPriceVND];
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Lưu" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSInteger val = [ac.textFields.firstObject.text integerValue];
        if (val > 0 && val < 1000) val *= 1000; // Nếu gõ tắt "25" tự hiểu là 25.000đ!
        if (val >= 5000 && val <= 1000000) {
            self->_cfg.minFoodPriceVND = val;
            [self updateValueLabels];
            [self->_cfg saveToDiskAndNotify:YES];
        }
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark - Visual Screenshot Coordinate Picker

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
        CGPoint curClose  = CGPointMake(self->_cfg.manualCloseX, self->_cfg.manualCloseY);
        CGPoint curAccept = CGPointMake(self->_cfg.manualAcceptX, self->_cfg.manualAcceptY);

        CoordinatePickerViewController *vc = [[CoordinatePickerViewController alloc] initWithScreenshot:img
                                                                                              closePoint:curClose
                                                                                             acceptPoint:curAccept
                                                                                            jitterRadius:self->_cfg.jitterRadiusPt
                                                                                                  onSave:^(CGPoint newClose, CGPoint newAccept) {
            self->_cfg.coordMode     = CoordModeFixedManual;
            self->_cfg.manualCloseX  = round(newClose.x);
            self->_cfg.manualCloseY  = round(newClose.y);
            self->_cfg.manualAcceptX = round(newAccept.x);
            self->_cfg.manualAcceptY = round(newAccept.y);
            [self syncUIFromConfig];
            [self->_cfg saveToDiskAndNotify:YES];
        }];
        [self presentViewController:vc animated:YES completion:nil];
    }];
}

#pragma mark - Counters & Logs

- (void)reloadCountersFromDisk {
    FilterConfig *disk = [FilterConfig loadFromDisk];
    _cfg.statAcceptedCount = disk.statAcceptedCount;
    _cfg.statRejectedCount = disk.statRejectedCount;
    [self refreshStatusAndLogs];
}

- (void)refreshStatusAndLogs {
    pid_t pid = getRunningDaemonPID();
    if (pid > 0 && _cfg.masterEnabled) {
        _daemonStatusLabel.text = [NSString stringWithFormat:@"● ĐANG CHẠY NGẦM (PID: %d)%@",
                                   pid, _cfg.dryRunMode ? @" [CHẾ ĐỘ THỬ]" : @""];
        _daemonStatusLabel.textColor = [UIColor systemGreenColor];
    } else {
        _daemonStatusLabel.text = @"○ LÕI NGẦM ĐANG TẮT";
        _daemonStatusLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    }

    _statsLabel.text = [NSString stringWithFormat:@"Đã nhận: %ld chuyến  |  Đã X Food: %ld đơn",
                        (long)_cfg.statAcceptedCount, (long)_cfg.statRejectedCount];

    NSString *logs = readDaemonLogs();
    if (![_logTextView.text isEqualToString:logs]) {
        _logTextView.text = logs;
        if (_logTextView.text.length > 10) {
            NSRange bottom = NSMakeRange(_logTextView.text.length - 1, 1);
            [_logTextView scrollRangeToVisible:bottom];
        }
    }
}

- (void)resetStatsTapped {
    [_cfg resetDailyStats];
    [self refreshStatusAndLogs];
}

- (void)clearLogsTapped {
    clearDaemonLogs();
    [self refreshStatusAndLogs];
}

@end
