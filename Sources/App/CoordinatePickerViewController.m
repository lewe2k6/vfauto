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
    CGFloat boxSize = MAX(64.0, (jitter * 2.0) + 40.0);
    self = [super initWithFrame:CGRectMake(0, 0, boxSize, boxSize)];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        _titleText = [title copy];
        _themeColor = color;
        _jitterRadius = jitter;

        _badgeLabel = [[UILabel alloc] initWithFrame:CGRectMake(-28, -22, boxSize + 56, 19)];
        _badgeLabel.font = [UIFont monospacedDigitSystemFontOfSize:10.5 weight:UIFontWeightBold];
        _badgeLabel.textColor = [UIColor whiteColor];
        _badgeLabel.backgroundColor = [color colorWithAlphaComponent:0.90];
        _badgeLabel.textAlignment = NSTextAlignmentCenter;
        _badgeLabel.layer.cornerRadius = 5;
        _badgeLabel.layer.masksToBounds = YES;
        [self addSubview:_badgeLabel];
    }
    return self;
}

- (void)updateBadgeWithPoint:(CGPoint)pt {
    self.badgeLabel.text = [NSString stringWithFormat:@" %@ (%.0f,%.0f) ", self.titleText, pt.x, pt.y];
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGPoint c = CGPointMake(rect.size.width * 0.5, rect.size.height * 0.5);

    if (self.jitterRadius > 0.5) {
        CGRect jRect = CGRectMake(c.x - self.jitterRadius, c.y - self.jitterRadius,
                                  self.jitterRadius * 2.0, self.jitterRadius * 2.0);
        CGContextSetFillColorWithColor(ctx, [self.themeColor colorWithAlphaComponent:0.22].CGColor);
        CGContextFillEllipseInRect(ctx, jRect);
        CGContextSetStrokeColorWithColor(ctx, self.themeColor.CGColor);
        CGContextSetLineWidth(ctx, 1.4);
        CGContextStrokeEllipseInRect(ctx, jRect);
    }

    CGRect outer = CGRectMake(c.x - 14, c.y - 14, 28, 28);
    CGContextSetStrokeColorWithColor(ctx, self.themeColor.CGColor);
    CGContextSetLineWidth(ctx, 2.0);
    CGContextStrokeEllipseInRect(ctx, outer);

    CGContextMoveToPoint(ctx, c.x - 20, c.y);
    CGContextAddLineToPoint(ctx, c.x + 20, c.y);
    CGContextMoveToPoint(ctx, c.x, c.y - 20);
    CGContextAddLineToPoint(ctx, c.x, c.y + 20);
    CGContextStrokePath(ctx);

    CGContextSetFillColorWithColor(ctx, [UIColor whiteColor].CGColor);
    CGContextFillEllipseInRect(ctx, CGRectMake(c.x - 3, c.y - 3, 6, 6));
}

@end

@implementation CoordinatePickerViewController {
    UIImage *_screenshot;
    CGPoint _closePt, _acceptPt, _offlinePt, _onlinePt;
    CGFloat _jitterRadius;
    CoordPickerSaveAllBlock _onSave;

    CrosshairPinView *_pinClose;
    CrosshairPinView *_pinAccept;
    CrosshairPinView *_pinOffline;
    CrosshairPinView *_pinOnline;
}

- (instancetype)initWithScreenshot:(UIImage *)screenshot
                            config:(FilterConfig *)cfg
                            onSave:(CoordPickerSaveAllBlock)onSave {
    self = [super init];
    if (self) {
        _screenshot   = screenshot;
        _closePt      = CGPointMake(cfg.manualCloseX, cfg.manualCloseY);
        _acceptPt     = CGPointMake(cfg.manualAcceptX, cfg.manualAcceptY);
        _offlinePt    = CGPointMake(cfg.manualOfflineX, cfg.manualOfflineY);
        _onlinePt     = CGPointMake(cfg.manualOnlineX, cfg.manualOnlineY);
        _jitterRadius = cfg.jitterRadiusPt;
        _onSave       = [onSave copy];
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (CrosshairPinView *)spawnPin:(NSString *)title color:(UIColor *)color at:(CGPoint)pt {
    CrosshairPinView *p = [[CrosshairPinView alloc] initWithTitle:title color:color jitter:_jitterRadius];
    p.center = pt;
    if (pt.y < 36) {
        p.badgeLabel.frame = CGRectMake(-28, p.bounds.size.height + 2, p.bounds.size.width + 56, 19);
    }
    [p updateBadgeWithPoint:pt];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePinPan:)];
    [p addGestureRecognizer:pan];
    [self.view addSubview:p];
    return p;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    UIImageView *imgView = [[UIImageView alloc] initWithFrame:self.view.bounds];
    imgView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    imgView.contentMode = UIViewContentModeScaleToFill;
    imgView.image = _screenshot;
    [self.view addSubview:imgView];

    _pinClose   = [self spawnPin:@"1.Nút X"     color:[UIColor systemRedColor]    at:_closePt];
    _pinAccept  = [self spawnPin:@"2.Nhận"      color:[UIColor systemGreenColor]  at:_acceptPt];
    _pinOffline = [self spawnPin:@"3.Tắt ⏻"     color:[UIColor systemOrangeColor] at:_offlinePt];
    _pinOnline  = [self spawnPin:@"4.Mở nhận"   color:[UIColor systemPurpleColor] at:_onlinePt];

    UIView *hud = [[UIView alloc] initWithFrame:CGRectMake(20, 115, self.view.bounds.size.width - 40, 102)];
    hud.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.84];
    hud.layer.cornerRadius = 14;
    hud.layer.borderWidth = 1.0;
    hud.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.22].CGColor;

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(8, 8, hud.bounds.size.width - 16, 40)];
    hint.text = @"Kéo 4 hồng tâm đè khít lên từng nút tương ứng.\n(Hộp đen này kéo đi chỗ khác được)";
    hint.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightMedium];
    hint.textColor = [UIColor colorWithWhite:0.92 alpha:1.0];
    hint.numberOfLines = 2;
    hint.textAlignment = NSTextAlignmentCenter;
    [hud addSubview:hint];

    CGFloat btnW = (hud.bounds.size.width - 28) * 0.5;
    UIButton *cancelBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    cancelBtn.frame = CGRectMake(8, 54, btnW, 38);
    [cancelBtn setTitle:@"Hủy" forState:UIControlStateNormal];
    [cancelBtn setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    cancelBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    cancelBtn.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1.0];
    cancelBtn.layer.cornerRadius = 8;
    [cancelBtn addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];
    [hud addSubview:cancelBtn];

    UIButton *saveBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    saveBtn.frame = CGRectMake(18 + btnW, 54, btnW, 38);
    [saveBtn setTitle:@"Lưu Cả 4 Tọa Độ" forState:UIControlStateNormal];
    [saveBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    saveBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
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
    [self.view bringSubviewToFront:pin];
    CGPoint trans = [gr translationInView:self.view];
    CGFloat nx = MAX(4.0, MIN(self.view.bounds.size.width - 4.0, pin.center.x + trans.x));
    CGFloat ny = MAX(4.0, MIN(self.view.bounds.size.height - 4.0, pin.center.y + trans.y));
    pin.center = CGPointMake(nx, ny);
    [gr setTranslation:CGPointZero inView:self.view];

    if (ny < 36) {
        pin.badgeLabel.frame = CGRectMake(-28, pin.bounds.size.height + 2, pin.bounds.size.width + 56, 19);
    } else {
        pin.badgeLabel.frame = CGRectMake(-28, -22, pin.bounds.size.width + 56, 19);
    }
    [pin updateBadgeWithPoint:pin.center];

    if (pin == _pinClose)        _closePt   = pin.center;
    else if (pin == _pinAccept)  _acceptPt  = pin.center;
    else if (pin == _pinOffline) _offlinePt = pin.center;
    else if (pin == _pinOnline)  _onlinePt  = pin.center;
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
        _onSave(_closePt, _acceptPt, _offlinePt, _onlinePt);
    }
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
