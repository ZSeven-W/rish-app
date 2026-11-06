#import <Foundation/Foundation.h>
#import <RishNative/RishNativeModule.h>

/// The existing workspace service remains the sole filesystem authority.
@protocol RishDefaultWorkspaceBackend <NSObject>
- (void)createWorkspaceRequest:(id)request resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject;
- (void)resolveWorkspaceRequest:(id)request resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject;
@end

@interface ShellWorkspaceModule : NSObject <RishNativeModule>
// Dependency injection keeps host regressions away from application data.
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults
    backend:(id<RishDefaultWorkspaceBackend>)backend clock:(NSDate *(^)(void))clock;
- (void)ensureDefaultWithOptions:(NSDictionary *)options
    resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject;
@end
