#import "MapRelayViewController.h"
#import "SharedConfig.h"
#import "PureQRCode.h"
#import <notify.h>

@implementation MapRelayViewController {
    FilterConfig *_cfg;
    UIScrollView *_scroll;
    UIStackView *_stack;

    UILabel *_lblStatusBanner;
    UILabel *_lblLastRelayed;

    UISwitch *_swMapRelay;
    UISwitch *_swReturnToDriver;
    UIButton *_btnPickDriverApp;

    UITextField *_tfTopic;
    UITextField *_tfBarkKey;
    UIButton *_btnAutoFetchBark;
    UILabel *_lblViewerURL;
    UIImageView *_qrImageView;

    UITextView *_logView;
    int _statsToken;
    NSTimer *_pollTimer;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Bắn Map Xanh SM -> Máy 2";
    self.view.backgroundColor = [UIColor colorWithRed:0.06 green:0.07 blue:0.09 alpha:1.0];

    _cfg = [FilterConfig loadFromDisk];
    if (_cfg.mapRelayTopic.length < 4) {
        _cfg.mapRelayTopic = generateRandomMapRelayTopic();
        [_cfg saveToDiskAndNotify:NO];
    }

    [self setupUI];
    [self loadConfigToUI];
    [self refreshLiveStatsAndLogs];

    __weak typeof(self) weakSelf = self;
    notify_register_dispatch(kNotifyStatsUpdated, &_statsToken, dispatch_get_main_queue(), ^(int token) {
        [weakSelf refreshLiveStatsAndLogs];
    });
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshLiveStatsAndLogs];
    if (!_pollTimer) {
        _pollTimer = [NSTimer scheduledTimerWithTimeInterval:2.5
                                                      target:self
                                                    selector:@selector(refreshLiveStatsAndLogs)
                                                    userInfo:nil
                                                     repeats:YES];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_pollTimer invalidate];
    _pollTimer = nil;
}

- (void)dealloc {
    if (_statsToken) notify_cancel(_statsToken);
    [_pollTimer invalidate];
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (UIView *)makeSectionCard:(NSString *)title subtitle:(NSString *)subtitle outStack:(UIStackView * __strong *)outSt {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [UIColor colorWithRed:0.12 green:0.13 blue:0.17 alpha:1.0];
    card.layer.cornerRadius = 14;
    card.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *st = [[UIStackView alloc] init];
    st.axis = UILayoutConstraintAxisVertical;
    st.spacing = 12;
    st.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:st];

    [NSLayoutConstraint activateConstraints:@[
        [st.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [st.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16],
        [st.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [st.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16]
    ]];

    UILabel *hdr = [[UILabel alloc] init];
    hdr.text = title;
    hdr.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    hdr.textColor = [UIColor colorWithRed:0.00 green:0.88 blue:0.75 alpha:1.0];
    hdr.numberOfLines = 0;
    [st addArrangedSubview:hdr];

    if (subtitle.length > 0) {
        UILabel *sub = [[UILabel alloc] init];
        sub.text = subtitle;
        sub.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        sub.textColor = [UIColor colorWithWhite:0.68 alpha:1.0];
        sub.numberOfLines = 0;
        [st addArrangedSubview:sub];
    }

    if (outSt) *outSt = st;
    return card;
}

- (UISwitch *)addSwitchRowTo:(UIStackView *)st title:(NSString *)title action:(SEL)act {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *lbl = [[UILabel alloc] init];
    lbl.text = title;
    lbl.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    lbl.textColor = [UIColor whiteColor];
    lbl.numberOfLines = 0;
    lbl.translatesAutoresizingMaskIntoConstraints = NO;

    UISwitch *sw = [[UISwitch alloc] init];
    sw.onTintColor = [UIColor colorWithRed:0.00 green:0.78 blue:0.65 alpha:1.0];
    sw.translatesAutoresizingMaskIntoConstraints = NO;
    [sw addTarget:self action:act forControlEvents:UIControlEventValueChanged];

    [row addSubview:lbl];
    [row addSubview:sw];

    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintGreaterThanOrEqualToConstant:38],
        [sw.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [sw.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [lbl.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [lbl.trailingAnchor constraintEqualToAnchor:sw.leadingAnchor constant:-12],
        [lbl.topAnchor constraintEqualToAnchor:row.topAnchor constant:4],
        [lbl.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-4]
    ]];

    [st addArrangedSubview:row];
    return sw;
}

- (void)setupUI {
    _scroll = [[UIScrollView alloc] init];
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:_scroll];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];

    _stack = [[UIStackView alloc] init];
    _stack.axis = UILayoutConstraintAxisVertical;
    _stack.spacing = 14;
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    [_scroll addSubview:_stack];

    [NSLayoutConstraint activateConstraints:@[
        [_stack.topAnchor constraintEqualToAnchor:_scroll.topAnchor constant:14],
        [_stack.bottomAnchor constraintEqualToAnchor:_scroll.bottomAnchor constant:-32],
        [_stack.leadingAnchor constraintEqualToAnchor:_scroll.leadingAnchor constant:14],
        [_stack.trailingAnchor constraintEqualToAnchor:_scroll.trailingAnchor constant:-14],
        [_stack.widthAnchor constraintEqualToAnchor:_scroll.widthAnchor constant:-28]
    ]];

    // 1. Live Status Banner
    UIStackView *stBanner = nil;
    UIView *bannerCard = [self makeSectionCard:@"TRẠNG THÁI CẦU NỐI BẮN MAP (iOS 15/16 TROLLSTORE)"
                                      subtitle:@"Bấm nút 'Điều hướng' trong Xanh SM -> Tự bắn tọa độ sang Máy 2 trong 0.2s rồi nhảy ngược về Xanh SM!"
                                      outStack:&stBanner];
    _lblStatusBanner = [[UILabel alloc] init];
    _lblStatusBanner.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightBold];
    _lblStatusBanner.textColor = [UIColor colorWithRed:0.20 green:0.95 blue:0.55 alpha:1.0];
    _lblStatusBanner.numberOfLines = 0;
    [stBanner addArrangedSubview:_lblStatusBanner];

    _lblLastRelayed = [[UILabel alloc] init];
    _lblLastRelayed.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _lblLastRelayed.textColor = [UIColor colorWithRed:0.40 green:0.85 blue:1.00 alpha:1.0];
    _lblLastRelayed.numberOfLines = 0;
    [stBanner addArrangedSubview:_lblLastRelayed];
    [_stack addArrangedSubview:bannerCard];

    // 2. Switches & Target Driver App
    UIStackView *stMain = nil;
    UIView *mainCard = [self makeSectionCard:@"1. CÔNG TẮC BẮT LINK & TỰ QUAY VỀ XANH SM"
                                    subtitle:@"Khi bật: App tự đón link comgooglemaps:// từ Xanh SM mà vẫn giữ nguyên icon Google Maps trên màn hình chính."
                                    outStack:&stMain];
    _swMapRelay = [self addSwitchRowTo:stMain
                                 title:@"BẬT Bắn Map tự động sang Máy 2"
                                action:@selector(switchChanged)];
    _swReturnToDriver = [self addSwitchRowTo:stMain
                                       title:@"Tự nhảy ngược về Xanh SM sau khi bắn (0.2s)"
                                      action:@selector(switchChanged)];

    _btnPickDriverApp = [UIButton buttonWithType:UIButtonTypeSystem];
    _btnPickDriverApp.backgroundColor = [UIColor colorWithRed:0.16 green:0.20 blue:0.28 alpha:1.0];
    [_btnPickDriverApp setTitleColor:[UIColor colorWithRed:0.35 green:0.85 blue:1.0 alpha:1.0] forState:UIControlStateNormal];
    _btnPickDriverApp.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    _btnPickDriverApp.layer.cornerRadius = 10;
    [_btnPickDriverApp.heightAnchor constraintEqualToConstant:40].active = YES;
    [_btnPickDriverApp addTarget:self action:@selector(pickDriverAppTapped) forControlEvents:UIControlEventTouchUpInside];
    [stMain addArrangedSubview:_btnPickDriverApp];
    [_stack addArrangedSubview:mainCard];

    // 3. Pairing QR & Bark Key
    UIStackView *stPair = nil;
    UIView *pairCard = [self makeSectionCard:@"2. MÃ KÊNH & GHÉP ĐÔI MÁY NHẬN MAP (iPHONE / ANDROID)"
                                    subtitle:@"• Máy nhận là iPhone: Tải app 'Bark' trên App Store -> Dán link Bark vào trang Web Map -> Bấm 'Tự Động Lấy Key Bark Từ Máy 2' bên dưới (nổ thông báo APNs 0.2s).\n• Máy nhận là Android: Quét QR mở Web Map (hoặc cài MacroDroid tự bung Google Maps)."
                                    outStack:&stPair];

    UIStackView *topicRow = [[UIStackView alloc] init];
    topicRow.axis = UILayoutConstraintAxisHorizontal;
    topicRow.spacing = 8;

    _tfTopic = [[UITextField alloc] init];
    _tfTopic.backgroundColor = [UIColor colorWithRed:0.07 green:0.08 blue:0.11 alpha:1.0];
    _tfTopic.textColor = [UIColor colorWithRed:0.25 green:0.95 blue:0.65 alpha:1.0];
    _tfTopic.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightBold];
    _tfTopic.layer.cornerRadius = 8;
    _tfTopic.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 10)];
    _tfTopic.leftViewMode = UITextFieldViewModeAlways;
    _tfTopic.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _tfTopic.autocorrectionType = UITextAutocorrectionTypeNo;
    _tfTopic.returnKeyType = UIReturnKeyDone;
    [_tfTopic.heightAnchor constraintEqualToConstant:38].active = YES;
    [_tfTopic addTarget:self action:@selector(topicEditingEnded) forControlEvents:UIControlEventEditingDidEnd];
    [_tfTopic addTarget:self action:@selector(topicEditingEnded) forControlEvents:UIControlEventEditingDidEndOnExit];

    UIButton *btnNewTopic = [UIButton buttonWithType:UIButtonTypeSystem];
    [btnNewTopic setTitle:@"Đổi mã" forState:UIControlStateNormal];
    [btnNewTopic setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btnNewTopic.backgroundColor = [UIColor colorWithRed:0.24 green:0.26 blue:0.34 alpha:1.0];
    btnNewTopic.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    btnNewTopic.layer.cornerRadius = 8;
    [btnNewTopic.widthAnchor constraintEqualToConstant:74].active = YES;
    [btnNewTopic addTarget:self action:@selector(regenerateTopicTapped) forControlEvents:UIControlEventTouchUpInside];

    [topicRow addArrangedSubview:_tfTopic];
    [topicRow addArrangedSubview:btnNewTopic];
    [stPair addArrangedSubview:topicRow];

    UILabel *lblBarkHdr = [[UILabel alloc] init];
    lblBarkHdr.text = @"Tăng tốc 0.2s cho iPhone nhận Map (App Bark - APNs):";
    lblBarkHdr.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    lblBarkHdr.textColor = [UIColor colorWithRed:1.00 green:0.78 blue:0.28 alpha:1.0];
    [stPair addArrangedSubview:lblBarkHdr];

    _tfBarkKey = [[UITextField alloc] init];
    _tfBarkKey.backgroundColor = [UIColor colorWithRed:0.07 green:0.08 blue:0.11 alpha:1.0];
    _tfBarkKey.textColor = [UIColor colorWithRed:1.00 green:0.86 blue:0.35 alpha:1.0];
    _tfBarkKey.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightBold];
    _tfBarkKey.layer.cornerRadius = 8;
    _tfBarkKey.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 10)];
    _tfBarkKey.leftViewMode = UITextFieldViewModeAlways;
    _tfBarkKey.clearButtonMode = UITextFieldViewModeWhileEditing;
    _tfBarkKey.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _tfBarkKey.autocorrectionType = UITextAutocorrectionTypeNo;
    _tfBarkKey.returnKeyType = UIReturnKeyDone;
    _tfBarkKey. attributedPlaceholder = [[NSAttributedString alloc]
        initWithString:@"Dán Key hoặc link https://api.day.app/KEY/..."
            attributes:@{ NSForegroundColorAttributeName: [UIColor colorWithWhite:0.42 alpha:1.0] }];
    [_tfBarkKey.heightAnchor constraintEqualToConstant:38].active = YES;
    [_tfBarkKey addTarget:self action:@selector(barkKeyEditingEnded) forControlEvents:UIControlEventEditingDidEnd];
    [_tfBarkKey addTarget:self action:@selector(barkKeyEditingEnded) forControlEvents:UIControlEventEditingDidEndOnExit];
    [stPair addArrangedSubview:_tfBarkKey];

    _btnAutoFetchBark = [UIButton buttonWithType:UIButtonTypeSystem];
    [_btnAutoFetchBark setTitle:@"Tự Động Lấy Key Bark Từ Máy 2 (1 Chạm)" forState:UIControlStateNormal];
    [_btnAutoFetchBark setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    _btnAutoFetchBark.backgroundColor = [UIColor colorWithRed:1.00 green:0.76 blue:0.22 alpha:1.0];
    _btnAutoFetchBark.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    _btnAutoFetchBark.layer.cornerRadius = 9;
    [_btnAutoFetchBark.heightAnchor constraintEqualToConstant:38].active = YES;
    [_btnAutoFetchBark addTarget:self action:@selector(autoFetchBarkKeyFromPeerTapped) forControlEvents:UIControlEventTouchUpInside];
    [stPair addArrangedSubview:_btnAutoFetchBark];

    UIView *qrWrap = [[UIView alloc] init];
    qrWrap.backgroundColor = [UIColor whiteColor];
    qrWrap.layer.cornerRadius = 12;
    qrWrap.translatesAutoresizingMaskIntoConstraints = NO;
    [qrWrap.heightAnchor constraintEqualToConstant:186].active = YES;

    _qrImageView = [[UIImageView alloc] init];
    _qrImageView.contentMode = UIViewContentModeScaleAspectFit;
    _qrImageView.translatesAutoresizingMaskIntoConstraints = NO;
    [qrWrap addSubview:_qrImageView];

    [NSLayoutConstraint activateConstraints:@[
        [_qrImageView.centerXAnchor constraintEqualToAnchor:qrWrap.centerXAnchor],
        [_qrImageView.centerYAnchor constraintEqualToAnchor:qrWrap.centerYAnchor],
        [_qrImageView.widthAnchor constraintEqualToConstant:166],
        [_qrImageView.heightAnchor constraintEqualToConstant:166]
    ]];
    [stPair addArrangedSubview:qrWrap];

    _lblViewerURL = [[UILabel alloc] init];
    _lblViewerURL.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _lblViewerURL.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
    _lblViewerURL.numberOfLines = 2;
    _lblViewerURL.textAlignment = NSTextAlignmentCenter;
    [stPair addArrangedSubview:_lblViewerURL];

    UIStackView *urlBtnRow = [[UIStackView alloc] init];
    urlBtnRow.axis = UILayoutConstraintAxisHorizontal;
    urlBtnRow.spacing = 8;
    urlBtnRow.distribution = UIStackViewDistributionFillEqually;

    UIButton *btnCopyLink = [UIButton buttonWithType:UIButtonTypeSystem];
    [btnCopyLink setTitle:@"Copy Link Máy 2" forState:UIControlStateNormal];
    [btnCopyLink setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btnCopyLink.backgroundColor = [UIColor colorWithRed:0.00 green:0.55 blue:0.85 alpha:1.0];
    btnCopyLink.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    btnCopyLink.layer.cornerRadius = 9;
    [btnCopyLink.heightAnchor constraintEqualToConstant:38].active = YES;
    [btnCopyLink addTarget:self action:@selector(copyViewerLinkTapped) forControlEvents:UIControlEventTouchUpInside];

    UIButton *btnTestRelay = [UIButton buttonWithType:UIButtonTypeSystem];
    [btnTestRelay setTitle:@"Bắn Thử Tọa Độ" forState:UIControlStateNormal];
    [btnTestRelay setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btnTestRelay.backgroundColor = [UIColor colorWithRed:0.00 green:0.70 blue:0.50 alpha:1.0];
    btnTestRelay.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    btnTestRelay.layer.cornerRadius = 9;
    [btnTestRelay.heightAnchor constraintEqualToConstant:38].active = YES;
    [btnTestRelay addTarget:self action:@selector(testMapRelayTapped) forControlEvents:UIControlEventTouchUpInside];

    [urlBtnRow addArrangedSubview:btnCopyLink];
    [urlBtnRow addArrangedSubview:btnTestRelay];
    [stPair addArrangedSubview:urlBtnRow];

    UIButton *btnOpenLocalMaps = [UIButton buttonWithType:UIButtonTypeSystem];
    [btnOpenLocalMaps setTitle:@"Mở Google Maps Gốc Trên Máy Này" forState:UIControlStateNormal];
    [btnOpenLocalMaps setTitleColor:[UIColor colorWithRed:0.35 green:0.88 blue:1.0 alpha:1.0] forState:UIControlStateNormal];
    btnOpenLocalMaps.backgroundColor = [UIColor colorWithRed:0.15 green:0.20 blue:0.28 alpha:1.0];
    btnOpenLocalMaps.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    btnOpenLocalMaps.layer.cornerRadius = 9;
    [btnOpenLocalMaps.heightAnchor constraintEqualToConstant:36].active = YES;
    [btnOpenLocalMaps addTarget:self action:@selector(openLocalGoogleMapsTapped) forControlEvents:UIControlEventTouchUpInside];
    [stPair addArrangedSubview:btnOpenLocalMaps];

    UIButton *btnRestoreGmaps = [UIButton buttonWithType:UIButtonTypeSystem];
    [btnRestoreGmaps setTitle:@"Khôi Phục Icon Google Maps Lên Màn Hình Chính" forState:UIControlStateNormal];
    [btnRestoreGmaps setTitleColor:[UIColor colorWithRed:1.00 green:0.82 blue:0.35 alpha:1.0] forState:UIControlStateNormal];
    btnRestoreGmaps.backgroundColor = [UIColor colorWithRed:0.24 green:0.20 blue:0.12 alpha:1.0];
    btnRestoreGmaps.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    btnRestoreGmaps.layer.cornerRadius = 9;
    [btnRestoreGmaps.heightAnchor constraintEqualToConstant:36].active = YES;
    [btnRestoreGmaps addTarget:self action:@selector(restoreGoogleMapsIconTapped) forControlEvents:UIControlEventTouchUpInside];
    [stPair addArrangedSubview:btnRestoreGmaps];

    [_stack addArrangedSubview:pairCard];

    // 4. Activity Log Card
    UIStackView *stLog = nil;
    UIView *logCard = [self makeSectionCard:@"3. NHẬT KÝ BẮN MAP TRỰC TIẾP"
                                   subtitle:nil
                                   outStack:&stLog];

    _logView = [[UITextView alloc] init];
    _logView.editable = NO;
    _logView.backgroundColor = [UIColor colorWithRed:0.05 green:0.06 blue:0.08 alpha:1.0];
    _logView.textColor = [UIColor colorWithRed:0.30 green:0.95 blue:0.55 alpha:1.0];
    _logView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _logView.layer.cornerRadius = 10;
    [_logView.heightAnchor constraintEqualToConstant:150].active = YES;
    [stLog addArrangedSubview:_logView];

    UIButton *btnClearLog = [UIButton buttonWithType:UIButtonTypeSystem];
    [btnClearLog setTitle:@"Xóa sạch Nhật ký" forState:UIControlStateNormal];
    [btnClearLog setTitleColor:[UIColor colorWithRed:1.0 green:0.42 blue:0.42 alpha:1.0] forState:UIControlStateNormal];
    btnClearLog.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [btnClearLog addTarget:self action:@selector(clearLogsTapped) forControlEvents:UIControlEventTouchUpInside];
    [stLog addArrangedSubview:btnClearLog];

    [_stack addArrangedSubview:logCard];
}

- (void)loadConfigToUI {
    _swMapRelay.on       = (_cfg.masterEnabled && _cfg.mapRelayEnabled);
    _swReturnToDriver.on = _cfg.mapRelayReturnToDriver;
    _tfTopic.text        = _cfg.mapRelayTopic;
    _tfBarkKey.text      = _cfg.mapRelayBarkKey ?: @"";
    [self updateDriverAppButtonTitle];
    [self refreshQRAndViewerURL];
}

- (void)updateDriverAppButtonTitle {
    NSString *title = nil;
    if (_cfg.driverAppBundleID.length > 0) {
        title = [NSString stringWithFormat:@"App Tài Xế: %@ (%@)",
                 _cfg.driverAppDisplayName ?: @"Xanh SM",
                 _cfg.driverAppBundleID];
    } else {
        InstalledAppInfo *det = autoDetectDriverApp();
        if (det) {
            title = [NSString stringWithFormat:@"App Tài Xế: Tự dò -> %@ (%@)", det.displayName, det.bundleID];
        } else {
            title = @"App Tài Xế: Tự động dò Xanh SM (Chạm để chọn)";
        }
    }
    [_btnPickDriverApp setTitle:title forState:UIControlStateNormal];
}

- (void)refreshQRAndViewerURL {
    NSString *urlStr = buildMapRelayViewerURLString(_cfg.mapRelayTopic);
    _lblViewerURL.text = urlStr;
    _qrImageView.image = generatePureQRImageForString(urlStr, 6.0);
}

- (void)switchChanged {
    BOOL relayOn = _swMapRelay.isOn;
    _cfg.masterEnabled          = relayOn;
    _cfg.mapRelayEnabled        = relayOn;
    _cfg.mapRelayReturnToDriver = _swReturnToDriver.isOn;
    [_cfg saveToDiskAndNotify:YES];
    [self refreshLiveStatsAndLogs];
}

- (void)topicEditingEnded {
    [_tfTopic resignFirstResponder];
    NSString *clean = sanitizeMapRelayTopic(_tfTopic.text);
    if (clean.length < 4) {
        clean = generateRandomMapRelayTopic();
    }
    _tfTopic.text = clean;
    _cfg.mapRelayTopic = clean;
    [_cfg saveToDiskAndNotify:YES];
    [self refreshQRAndViewerURL];
}

- (void)regenerateTopicTapped {
    NSString *newTopic = generateRandomMapRelayTopic();
    _tfTopic.text = newTopic;
    _cfg.mapRelayTopic = newTopic;
    [_cfg saveToDiskAndNotify:YES];
    [self refreshQRAndViewerURL];
}

- (void)barkKeyEditingEnded {
    [_tfBarkKey resignFirstResponder];
    NSString *cleanBark = sanitizeBarkKeyOrURL(_tfBarkKey.text);
    _tfBarkKey.text = cleanBark;
    _cfg.mapRelayBarkKey = cleanBark;
    [_cfg saveToDiskAndNotify:YES];
    [self refreshLiveStatsAndLogs];
}

- (void)autoFetchBarkKeyFromPeerTapped {
    [_tfBarkKey resignFirstResponder];
    [_tfTopic resignFirstResponder];
    NSString *topic = sanitizeMapRelayTopic(_cfg.mapRelayTopic);
    [_btnAutoFetchBark setTitle:@"Đang dò Key Bark trên kênh..." forState:UIControlStateNormal];
    _btnAutoFetchBark.enabled = NO;

    fetchBarkKeyFromNtfyTopicAsync(topic, ^(NSString *foundBarkKey, NSString *detail) {
        self->_btnAutoFetchBark.enabled = YES;
        [self->_btnAutoFetchBark setTitle:@"Tự Động Lấy Key Bark Từ Máy 2 (1 Chạm)" forState:UIControlStateNormal];
        if (foundBarkKey.length >= 6) {
            self->_tfBarkKey.text = foundBarkKey;
            self->_cfg.mapRelayBarkKey = foundBarkKey;
            [self->_cfg saveToDiskAndNotify:YES];
            [self refreshLiveStatsAndLogs];
        }
        UIAlertController *al = [UIAlertController alertControllerWithTitle:(foundBarkKey.length >= 6 ? @"Ghép Đôi Bark Thành Công!" : @"Chưa Tìm Thấy Key Bark")
                                                                    message:detail
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [al addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:al animated:YES completion:nil];
    });
}

- (void)copyViewerLinkTapped {
    NSString *urlStr = buildMapRelayViewerURLString(_cfg.mapRelayTopic);
    [UIPasteboard generalPasteboard].string = urlStr;
    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"Đã Copy Link Ghép Đôi Máy 2"
                                                                message:[NSString stringWithFormat:@"Đã chép:\n%@\n\nHãy gửi link này sang điện thoại thứ 2 (hoặc dùng Camera Máy 2 quét mã QR trên màn hình).", urlStr]
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:al animated:YES completion:nil];
}

- (void)testMapRelayTapped {
    [_tfBarkKey resignFirstResponder];
    [_tfTopic resignFirstResponder];
    NSString *cleanBark = sanitizeBarkKeyOrURL(_tfBarkKey.text);
    _tfBarkKey.text = cleanBark;
    _cfg.mapRelayBarkKey = cleanBark;
    [_cfg saveToDiskAndNotify:NO];

    dispatchMapRelayPayloadAsync(21.028511, 105.854444, YES, @"Hồ Hoàn Kiếm (Bắn Thử)", @"Test", _cfg, ^(BOOL ok, NSString *detail) {
        [self refreshLiveStatsAndLogs];
        UIAlertController *al = [UIAlertController alertControllerWithTitle:(ok ? @"Đã Bắn Thử Thành Công!" : @"Lỗi Bắn Map")
                                                                    message:(ok ? @"Đã bắn tọa độ thử sang Máy 2! Kiểm tra thông báo Bark / trang Web Map trên Máy 2." : @"Không gửi được qua mạng. Hãy kiểm tra kết nối 4G/Wi-Fi.")
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [al addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:al animated:YES completion:nil];
    });
}

- (void)openLocalGoogleMapsTapped {
    RuntimeDaemonState *st = [RuntimeDaemonState loadState];
    NSString *rawTarget = (st.lastRelayedSummary.length > 0) ? st.lastRelayedSummary : @"21.028511,105.854444";
    NSRange paren = [rawTarget rangeOfString:@" ("];
    if (paren.location != NSNotFound) {
        rawTarget = [rawTarget substringToIndex:paren.location];
    }
    forwardNavigationURLToLocalGoogleMaps(rawTarget);
}

- (void)restoreGoogleMapsIconTapped {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        BOOL ok = forceRestoreGoogleMapsIconNow();
        NSString *gmapsPath = findLocalGoogleMapsBundlePath();
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *al = [UIAlertController alertControllerWithTitle:(ok ? @"Đã Khôi Phục Icon Google Maps" : @"Không Tìm Thấy Google Maps")
                                                                        message:(ok ? [NSString stringWithFormat:@"Đã đăng ký lại Google Maps (%@) lên màn hình chính iPhone.", gmapsPath.lastPathComponent ?: @"Maps.app"]
                                                                                    : @"Không tìm thấy Google Maps trên máy. Hãy kiểm tra Google Maps trong App Store.")
                                                                 preferredStyle:UIAlertControllerStyleAlert];
            [al addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:al animated:YES completion:nil];
        });
    });
}

- (void)pickDriverAppTapped {
    NSArray<InstalledAppInfo *> *apps = listInstalledUserApps();
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Chọn App Tài Xế Để Tự Quay Về"
                                                                   message:@"Sau khi đón link Điều hướng và bắn sang Máy 2, app sẽ tự chuyển ngược về ứng dụng này."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Tự động dò Xanh SM Driver (Khuyên dùng)"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        self->_cfg.driverAppBundleID    = @"";
        self->_cfg.driverAppExecName    = @"";
        self->_cfg.driverAppDisplayName = @"Tự động dò Xanh SM";
        [self->_cfg saveToDiskAndNotify:YES];
        [self updateDriverAppButtonTitle];
    }]];

    for (InstalledAppInfo *app in apps) {
        NSString *title = [NSString stringWithFormat:@"%@ (%@)", app.displayName, app.bundleID];
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            self->_cfg.driverAppBundleID    = app.bundleID;
            self->_cfg.driverAppExecName    = app.executableName;
            self->_cfg.driverAppDisplayName = app.displayName;
            [self->_cfg saveToDiskAndNotify:YES];
            [self updateDriverAppButtonTitle];
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)clearLogsTapped {
    clearDaemonLogs();
    [self refreshLiveStatsAndLogs];
}

- (void)refreshLiveStatsAndLogs {
    RuntimeDaemonState *st = [RuntimeDaemonState loadState];
    BOOL relayOn = (_cfg.masterEnabled && _cfg.mapRelayEnabled);
    BOOL hasBark = (_cfg.mapRelayBarkKey.length >= 6);

    _lblStatusBanner.text = relayOn
        ? [NSString stringWithFormat:@"● ĐANG BẬT ĐÓN LINK ĐIỀU HƯỚNG (%@)",
           hasBark ? @"Bark APNs 0.2s + Ntfy" : @"Kênh Ntfy / Web Map"]
        : @"○ ĐANG TẮT BẮN MAP (Google Maps mở trực tiếp trên máy này)";
    _lblStatusBanner.textColor = relayOn
        ? [UIColor colorWithRed:0.20 green:0.95 blue:0.55 alpha:1.0]
        : [UIColor colorWithRed:1.00 green:0.55 blue:0.35 alpha:1.0];

    if (st.lastRelayedSummary.length > 0) {
        _lblLastRelayed.text = [NSString stringWithFormat:@"Vừa bắn gần nhất: %@", st.lastRelayedSummary];
    } else {
        _lblLastRelayed.text = @"Chưa có tọa độ nào được bắn trong phiên này.";
    }

    _logView.text = readDaemonLogs();
}

@end
