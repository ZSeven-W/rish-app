#import <Foundation/Foundation.h>
#import <RishNative/RishNativeModule.h>

@interface ShellAssistantModule : NSObject <RishNativeModule>
- (instancetype)initWithDirectory:(NSURL *)directory;
- (void)storageWithResolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject;
- (void)pickAvatarWithRequest:(NSDictionary *)request resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject;
@end
