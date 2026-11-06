#import <UIKit/UIKit.h>
#import <RishNative/RishNativeModule.h>

@interface RishInlineComposer : NSObject <UITextViewDelegate>
// A root provider permits offscreen regressions without starting GPUI or a
// workspace service. Production borrows the pinned GPUI view controller.
- (instancetype)initWithRootProvider:(UIView *(^)(void))provider;
- (void)sync:(NSDictionary *)options resolve:(RishResolveBlock)resolve reject:(RishRejectBlock)reject;
- (void)wait:(NSDictionary *)options resolve:(RishResolveBlock)resolve reject:(RishRejectBlock)reject;
- (void)snapshot:(NSDictionary *)options resolve:(RishResolveBlock)resolve reject:(RishRejectBlock)reject;
- (void)close:(NSDictionary *)options resolve:(RishResolveBlock)resolve reject:(RishRejectBlock)reject;
- (void)clearIfUnchanged:(NSDictionary *)options resolve:(RishResolveBlock)resolve reject:(RishRejectBlock)reject;
- (void)obscure;
@end
