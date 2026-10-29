#import "StealthBatteryViewController.h"
#import "SecretConfigViewController.h"
#import "SharedConfig.h"
#import <AudioToolbox/AudioToolbox.h>
#import <mach/mach.h>

@implementation StealthBatteryViewController {
    UILabel *_percentLabel;
    UILabel *_stateLabel;
    UILabel *_thermalLabel;
    UILabel *_ramLabel;
    UILabel *_uptimeLabel;
    NSTimer *_hwTimer;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.07 green:0.08 blue:0.10 alpha:1.0];
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;

    [self buildDisguiseUI];
    [self refreshHardwareMetrics];

    _hwTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                target:self
                                              selector:@selector(refreshHardwareMetrics)
                                              userInfo:nil
                                               repeats:YES];
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (UIView *)makeMetricCardWithTitle:(NSString *)title valueLabel:(UILabel **)outLbl {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [UIColor colorWithRed:0.13 green:0.14 blue:0.18 alpha:1.0];
    card.layer.cornerRadius = 14;

    UILabel *t = [[UILabel alloc] init];
    t.text = title;
    t.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    t.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
    t.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *v = [[UILabel alloc] init];
    v.font = [UIFont monospacedDigitSystemFontOfSize:18 weight:UIFontWeightBold];
    v.textColor = [UIColor whiteColor];
    v.translatesAutoresizingMaskIntoConstraints = NO;

    [card addSubview:t];
    [card addSubview:v];

    [NSLayoutConstraint activateConstraints:@[
        [card.heightAnchor constraintEqualToConstant:72],
        [t.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [t.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [v.topAnchor constraintEqualToAnchor:t.bottomAnchor constant:6],
        [v.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16]
    ]];

    if (outLbl) *outLbl = v;
    return card;
}

- (void)buildDisguiseUI {
    UIStackView *root = [[UIStackView alloc] init];
    root.axis = UILayoutConstraintAxisVertical;
    root.spacing = 16;
    root.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:root];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [root.topAnchor constraintEqualToAnchor:safe.topAnchor constant:20],
        [root.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [root.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20]
    ]];

    // SECRET GATE HEADER: Long-press 2.0s on "Trạng thái Pin" opens hidden config!
    UILabel *header = [[UILabel alloc] init];
    header.text = @"Trạng thái Pin";
    header.font = [UIFont systemFontOfSize:26 weight:UIFontWeightHeavy];
    header.textColor = [UIColor whiteColor];
    header.userInteractionEnabled = YES;

    UILongPressGestureRecognizer *secretHold = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleSecretGate:)];
    secretHold.minimumPressDuration = 2.0;
    [header addGestureRecognizer:secretHold];
    [root addArrangedSubview:header];

    // Big Battery Ring / Hero Card
    UIView *hero = [[UIView alloc] init];
    hero.backgroundColor = [UIColor colorWithRed:0.11 green:0.16 blue:0.14 alpha:1.0];
    hero.layer.cornerRadius = 18;
    hero.layer.borderWidth = 1.0;
    hero.layer.borderColor = [[UIColor systemGreenColor] colorWithAlphaComponent:0.35].CGColor;
    [hero.heightAnchor constraintEqualToConstant:150].active = YES;

    _percentLabel = [[UILabel alloc] init];
    _percentLabel.font = [UIFont monospacedDigitSystemFontOfSize:54 weight:UIFontWeightBold];
    _percentLabel.textColor = [UIColor systemGreenColor];
    _percentLabel.textAlignment = NSTextAlignmentCenter;
    _percentLabel.translatesAutoresizingMaskIntoConstraints = NO;

    _stateLabel = [[UILabel alloc] init];
    _stateLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    _stateLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    _stateLabel.textAlignment = NSTextAlignmentCenter;
    _stateLabel.translatesAutoresizingMaskIntoConstraints = NO;

    [hero addSubview:_percentLabel];
    [hero addSubview:_stateLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_percentLabel.centerXAnchor constraintEqualToAnchor:hero.centerXAnchor],
        [_percentLabel.topAnchor constraintEqualToAnchor:hero.topAnchor constant:28],
        [_stateLabel.centerXAnchor constraintEqualToAnchor:hero.centerXAnchor],
        [_stateLabel.topAnchor constraintEqualToAnchor:_percentLabel.bottomAnchor constant:8]
    ]];
    [root addArrangedSubview:hero];

    [root addArrangedSubview:[self makeMetricCardWithTitle:@"Nhiệt độ thân máy ước tính" valueLabel:&_thermalLabel]];
    [root addArrangedSubview:[self makeMetricCardWithTitle:@"Bộ nhớ RAM khả dụng" valueLabel:&_ramLabel]];
    [root addArrangedSubview:[self makeMetricCardWithTitle:@"Thời gian hoạt động hệ thống" valueLabel:&_uptimeLabel]];
}

- (void)refreshHardwareMetrics {
    float lvl = [UIDevice currentDevice].batteryLevel;
    int pct = (lvl < 0) ? 100 : (int)roundf(lvl * 100.0f);
    _percentLabel.text = [NSString stringWithFormat:@"%d%%", pct];

    UIDeviceBatteryState st = [UIDevice currentDevice].batteryState;
    switch (st) {
        case UIDeviceBatteryStateCharging: _stateLabel.text = @"Đang sạc điện"; break;
        case UIDeviceBatteryStateFull:     _stateLabel.text = @"Đã sạc đầy 100%"; break;
        default:                           _stateLabel.text = @"Đang dùng Pin (Ổn định)"; break;
    }

    NSProcessInfoThermalState ts = [NSProcessInfo processInfo].thermalState;
    switch (ts) {
        case NSProcessInfoThermalStateNominal:  _thermalLabel.text = @"33.4 °C — Mát mẻ"; _thermalLabel.textColor = [UIColor systemGreenColor]; break;
        case NSProcessInfoThermalStateFair:     _thermalLabel.text = @"37.8 °C — Bình thường"; _thermalLabel.textColor = [UIColor systemYellowColor]; break;
        case NSProcessInfoThermalStateSerious:  _thermalLabel.text = @"41.6 °C — Máy ấm"; _thermalLabel.textColor = [UIColor systemOrangeColor]; break;
        case NSProcessInfoThermalStateCritical: _thermalLabel.text = @"45.2 °C — Quá nhiệt!"; _thermalLabel.textColor = [UIColor systemRedColor]; break;
    }

    // Real Mach VM RAM query
    mach_port_t hostPort = mach_host_self();
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    vm_size_t pageSize = 4096;
    host_page_size(hostPort, &pageSize);
    vm_statistics64_data_t vmStat;
    if (host_statistics64(hostPort, HOST_VM_INFO64, (host_info64_t)&vmStat, &count) == KERN_SUCCESS) {
        uint64_t freeMB = ((uint64_t)(vmStat.free_count + vmStat.inactive_count) * pageSize) / (1024 * 1024);
        uint64_t totalMB = [NSProcessInfo processInfo].physicalMemory / (1024 * 1024);
        _ramLabel.text = [NSString stringWithFormat:@"Trống %llu MB / %llu MB", freeMB, totalMB];
    } else {
        _ramLabel.text = @"Trống 512 MB / 2048 MB";
    }

    NSTimeInterval up = [NSProcessInfo processInfo].systemUptime;
    int hrs = (int)(up / 3600);
    int mins = ((int)up % 3600) / 60;
    _uptimeLabel.text = [NSString stringWithFormat:@"%d giờ %d phút", hrs, mins];
}

- (void)handleSecretGate:(UILongPressGestureRecognizer *)gr {
    if (gr.state == UIGestureRecognizerStateBegan) {
        AudioServicesPlaySystemSound(1519);
        SecretConfigViewController *cfgVC = [[SecretConfigViewController alloc] init];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:cfgVC];
        nav.navigationBar.barStyle = UIBarStyleBlack;
        nav.modalPresentationStyle = UIModalPresentationFullScreen;
        [self presentViewController:nav animated:YES completion:nil];
    }
}

@end
