#import "CoordinatePickerViewController.h"

@interface CrosshairPinView : UIView
@property (nonatomic, copy) NSString *titleText;
@property (nonatomic, strong) UIColor *themeColor;
@property (nonatomic, assign) CGFloat jitterRadius;
@property (nonatomic, strong) UILabel *badgeLabel;
- (void)updateBadgeWithPoint:(CGPoint)pt;
@end

@implementation CrosshairPinView

- (instancetype)initWithTitle:(NSString *)title color:(UIColor *)color jitter:(CGFloat)jitter {
    CGFloat boxSize = MAX(68.0, (jitter * 2.0) + 44.0);
    self = [super initWithFrame:CGRectMake(0, 0, boxSize, boxSize)];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        _titleText = [title copy];
        _themeColor = color;
        _jitterRadius = jitter;

        _badgeLabel = [[UILabel alloc] initWithFrame:CGRectMake(-28, -24, boxSize + 56, 20)];
        _badgeLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightBold];
        _badgeLabel.textColor = [UIColor whiteColor];
        _badgeLabel.backgroundColor = [color colorWithAlphaComponent:0.88];
        _badgeLabel.textAlignment = NSTextAlignmentCenter;
        _badgeLabel.layer.cornerRadius = 6;
        _badgeLabel.layer.masksToBounds = YES;
        [self addSubview:_badgeLabel];
    }
    return self;
}

- (void)updateBadgeWithPoint:(CGPoint)pt {
    self.badgeLabel.text = [NSString stringWithFormat:@" %@ (%.0f, %.0f) ", self.titleText, pt.x, pt.y];
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGPoint c = CGPointMake(rect.size.width * 0.5, rect.size.height * 0.5);

    // Translucent Jitter Circle
    if (self.jitterRadius > 0.5) {
        CGRect jRect = CGRectMake(c.x - self.jitterRadius, c.y - self.jitterRadius,
                                  self.jitterRadius * 2.0, self.jitterRadius * 2.0);
        CGContextSetFillColorWithColor(ctx, [self.themeColor colorWithAlphaComponent:0.22].CGColor);
        CGContextFillEllipseInRect(ctx, jRect);
        CGContextSetStrokeColorWithColor(ctx, self.themeColor.CGColor);
        CGContextSetLineWidth(ctx, 1.5);
        CGContextStrokeEllipseInRect(ctx, jRect);
    }

    // Outer target ring
    CGRect outer = CGRectMake(c.x - 15, c.y - 15, 30, 30);
    CGContextSetStrokeColorWithColor(ctx, self.themeColor.CGColor);
    CGContextSetLineWidth(ctx, 2.2);
    CGContextStrokeEllipseInRect(ctx, outer);

    // Crosshair lines
    CGContextMoveToPoint(ctx, c.x - 22, c.y);
    CGContextAddLineToPoint(ctx, c.x + 22, c.y);
    CGContextMoveToPoint(ctx, c.x, c.y - 22);
    CGContextAddLineToPoint(ctx, c.x, c.y + 22);
    CGContextStrokePath(ctx);

    // Exact center dot
    CGContextSetFillColorWithColor(ctx, [UIColor whiteColor].CGColor);
    CGContextFillEllipseInRect(ctx, CGRectMake(c.x - 3, c.y - 3, 6, 6));
}

@end

@implementation CoordinatePickerViewController {
    UIImage *_screenshot;
    CGPoint _closePt;
    CGPoint _acceptPt;
    CGFloat _jitterRadius;
    CoordPickerSaveBlock _onSave;

    CrosshairPinView *_closePin;
    CrosshairPinView *_acceptPin;
}

- (instancetype)initWithScreenshot:(UIImage *)screenshot
                         closePoint:(CGPoint)closePt
                        acceptPoint:(CGPoint)acceptPt
                       jitterRadius:(CGFloat)jitterRadius
                             onSave:(CoordPickerSaveBlock)onSave {
    self = [super init];
    if (self) {
        _screenshot = screenshot;
        _closePt = closePt;
        _acceptPt = acceptPt;
        _jitterRadius = jitterRadius;
        _onSave = [onSave copy];
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    // 1:1 Screenshot Background
    UIImageView *imgView = [[UIImageView alloc] initWithFrame:self.view.bounds];
    imgView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    imgView.contentMode = UIViewContentModeScaleToFill;
    if (_screenshot) {
        imgView.image = _screenshot;
    }
    [self.view addSubview:imgView];

    // Red Pin for [X]
    _closePin = [[CrosshairPinView alloc] initWithTitle:@"Nút X"
                                                  color:[UIColor systemRedColor]
                                                 jitter:_jitterRadius];
    _closePin.center = _closePt;
    // Flip badge below pin if near very top edge so it stays visible
    if (_closePt.y < 36) {
        _closePin.badgeLabel.frame = CGRectMake(-28, _closePin.bounds.size.height + 2, _closePin.bounds.size.width + 56, 20);
    }
    [_closePin updateBadgeWithPoint:_closePt];
    UIPanGestureRecognizer *panClose = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePinPan:)];
    [_closePin addGestureRecognizer:panClose];
    [self.view addSubview:_closePin];

    // Teal/Green Pin for [Nhận chuyến]
    _acceptPin = [[CrosshairPinView alloc] initWithTitle:@"Nhận"
                                                   color:[UIColor colorWithRed:0.0 green:0.68 blue:0.65 alpha:1.0]
                                                  jitter:_jitterRadius];
    _acceptPin.center = _acceptPt;
    [_acceptPin updateBadgeWithPoint:_acceptPt];
    UIPanGestureRecognizer *panAccept = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePinPan:)];
    [_acceptPin addGestureRecognizer:panAccept];
    [self.view addSubview:_acceptPin];

    // Floating Control Panel placed right in middle of screen (never covers top [X] or bottom [Nhận])
    UIView *hud = [[UIView alloc] initWithFrame:CGRectMake(24, (self.view.bounds.size.height - 108) * 0.5, self.view.bounds.size.width - 48, 108)];
    hud.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.82];
    hud.layer.cornerRadius = 14;
    hud.layer.borderWidth = 1.0;
    hud.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.2].CGColor;

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(10, 8, hud.bounds.size.width - 20, 42)];
    hint.text = @"Kéo 2 hồng tâm ĐỎ [X] và XANH [Nhận] đặt đè khít lên nút trên ảnh.\n(Khung mờ này kéo đi chỗ khác được)";
    hint.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    hint.textColor = [UIColor colorWithWhite:0.92 alpha:1.0];
    hint.numberOfLines = 2;
    hint.textAlignment = NSTextAlignmentCenter;
    [hud addSubview:hint];

    CGFloat btnW = (hud.bounds.size.width - 30) * 0.5;
    UIButton *cancelBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    cancelBtn.frame = CGRectMake(10, 58, btnW, 38);
    [cancelBtn setTitle:@"Hủy" forState:UIControlStateNormal];
    [cancelBtn setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    cancelBtn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    cancelBtn.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1.0];
    cancelBtn.layer.cornerRadius = 8;
    [cancelBtn addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];
    [hud addSubview:cancelBtn];

    UIButton *saveBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    saveBtn.frame = CGRectMake(20 + btnW, 58, btnW, 38);
    [saveBtn setTitle:@"Lưu Tọa Độ" forState:UIControlStateNormal];
    [saveBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    saveBtn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    saveBtn.backgroundColor = [UIColor systemGreenColor];
    saveBtn.layer.cornerRadius = 8;
    [saveBtn addTarget:self action:@selector(saveTapped) forControlEvents:UIControlEventTouchUpInside];
    [hud addSubview:saveBtn];

    UIPanGestureRecognizer *hudPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleHudPan:)];
    [hud addGestureRecognizer:hudPan];
    [self.view addSubview:hud];
}

- (void)handlePinPan:(UIPanGestureRecognizer *)gr {
    CrosshairPinView *pin = (CrosshairPinView *)gr.view;
    CGPoint trans = [gr translationInView:self.view];
    CGFloat nx = MAX(4.0, MIN(self.view.bounds.size.width - 4.0, pin.center.x + trans.x));
    CGFloat ny = MAX(4.0, MIN(self.view.bounds.size.height - 4.0, pin.center.y + trans.y));
    pin.center = CGPointMake(nx, ny);
    [gr setTranslation:CGPointZero inView:self.view];

    if (ny < 36) {
        pin.badgeLabel.frame = CGRectMake(-28, pin.bounds.size.height + 2, pin.bounds.size.width + 56, 20);
    } else {
        pin.badgeLabel.frame = CGRectMake(-28, -24, pin.bounds.size.width + 56, 20);
    }

    [pin updateBadgeWithPoint:pin.center];
    if (pin == _closePin) {
        _closePt = pin.center;
    } else {
        _acceptPt = pin.center;
    }
}

- (void)handleHudPan:(UIPanGestureRecognizer *)gr {
    UIView *v = gr.view;
    CGPoint trans = [gr translationInView:self.view];
    v.center = CGPointMake(v.center.x + trans.x, v.center.y + trans.y);
    [gr setTranslation:CGPointZero inView:self.view];
}

- (void)cancelTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)saveTapped {
    if (_onSave) {
        _onSave(_closePt, _acceptPt);
    }
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
