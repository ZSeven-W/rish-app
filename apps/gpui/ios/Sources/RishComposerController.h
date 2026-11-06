#import <UIKit/UIKit.h>

/// Native IME buffer for the existing ShellInput.edit contract. The caller
/// receives only the final committed text, or NSNull when editing is cancelled.
@interface RishComposerController : UIViewController
    <UITextViewDelegate, UIAdaptivePresentationControllerDelegate>
@property(nonatomic, copy) NSString *initialText;
@property(nonatomic, copy) void (^finish)(id);
@end
