#ifndef CoordinatePickerViewController_h
#define CoordinatePickerViewController_h

#import <UIKit/UIKit.h>
#import "SharedConfig.h"

typedef void (^CoordPickerSaveBlock)(CGPoint closePt, CGPoint acceptPt);

@interface CoordinatePickerViewController : UIViewController

- (instancetype)initWithScreenshot:(UIImage *)screenshot
                         closePoint:(CGPoint)closePt
                        acceptPoint:(CGPoint)acceptPt
                       jitterRadius:(CGFloat)jitterRadius
                             onSave:(CoordPickerSaveBlock)onSave;

@end

#endif /* CoordinatePickerViewController_h */
