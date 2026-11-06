#import <UIKit/UIKit.h>

/// Edits an in-memory copy. The caller owns revision checks and filesystem writes.
@interface RishFileEditorController : UIViewController
    <UITextViewDelegate, UIAdaptivePresentationControllerDelegate>
@property(nonatomic, copy) NSDictionary<NSString *, id> *options;
@property(nonatomic, copy) void (^finish)(id value);
@end
