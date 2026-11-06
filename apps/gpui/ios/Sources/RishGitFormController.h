#import <UIKit/UIKit.h>

/// Commit identity and remote URL only. Credentials use the separate Keychain prompt.
@interface RishGitFormController : UIViewController
    <UITextFieldDelegate, UIAdaptivePresentationControllerDelegate>
@property(nonatomic, copy) NSDictionary *options;
@property(nonatomic, copy) void (^finish)(id value);
@end
