#import <UIKit/UIKit.h>

/// A single-line naming surface. The multiline chat composer is independent.
@interface RishNameController : UIViewController
    <UITextFieldDelegate, UIAdaptivePresentationControllerDelegate>
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *options;
@property(nonatomic, copy) void (^finish)(id value);
- (void)preparePresentation;
@end
