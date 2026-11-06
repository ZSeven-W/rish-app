#import <RishNative/RishNativeModule.h>
#import "RishGPUI-Swift.h"

@interface TaskExperienceModule : NSObject <RishNativeModule>
@end

@implementation TaskExperienceModule
RISH_NATIVE_MODULE(TaskExperience)
+ (BOOL)requiresMainQueueSetup { return YES; }
- (dispatch_queue_t)methodQueue { return dispatch_get_main_queue(); }
RISH_NATIVE_METHOD(handle, handleWithRequest:(NSDictionary *)request
    resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  if (![request isKindOfClass:NSDictionary.class]) {
    reject(@"task_experience_invalid", @"Invalid task request.", nil); return;
  }
  [RishTaskExperienceBridge handle:request completion:^(id value, NSError *error) {
    if (error) reject(@"task_experience_invalid", @"Task experience request could not be handled.", error);
    else resolve(value);
  }];
}
@end
