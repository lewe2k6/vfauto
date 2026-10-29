#ifndef CoordinatePickerViewController_h
#define CoordinatePickerViewController_h

#import <UIKit/UIKit.h>
#import "SharedConfig.h"

typedef void (^CoordPickerSaveAllBlock)(CGPoint closePt,
                                        CGPoint acceptPt,
                                        CGPoint offlinePt,
                                        CGPoint onlinePt,
                                        CGPoint navPt);

@interface CoordinatePickerViewController : UIViewController

- (instancetype)initWithScreenshot:(UIImage *)screenshot
                            config:(FilterConfig *)cfg
                            onSave:(CoordPickerSaveAllBlock)onSave;

@end

#endif /* CoordinatePickerViewController_h */
