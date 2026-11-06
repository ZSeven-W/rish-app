#import <Foundation/Foundation.h>
#import <RishNative/RishNativeModule.h>

@protocol RishRuntimeEngineDownloadBackend <NSObject>
- (NSDictionary *)installationForEngine:(NSString *)engineID;
- (void)installEngine:(NSString *)engineID;
- (void)cancelEngine:(NSString *)engineID;
@end

@interface ShellRuntimeEnginesModule : NSObject <RishNativeModule>
- (instancetype)initWithDownloads:(id<RishRuntimeEngineDownloadBackend>)downloads;
- (void)catalogWithResolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject;
- (void)cancelWithRequest:(NSDictionary *)request resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject;
- (void)installWithRequest:(NSDictionary *)request resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject;
@end
