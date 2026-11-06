#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <RishNative/RishNativeModule.h>

#ifdef __cplusplus
extern "C" {
#endif
BOOL ShellAssistantAvatarRequestValid(id request);
#ifdef __cplusplus
}
#endif

@interface ShellAssistantAvatarPicker : NSObject
@property(nonatomic, readonly) BOOL busy;
- (void)presentFrom:(UIViewController *)presenter
         directory:(NSURL *)directory
           resolve:(RishResolveBlock)resolve
            reject:(RishRejectBlock)reject;
@end
