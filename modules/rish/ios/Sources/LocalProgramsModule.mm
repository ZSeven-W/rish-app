#import <Foundation/Foundation.h>
#import <RishNative/RishNativeModule.h>
#import "RuntimeProgramService.h"
#import "RuntimeWorkspaceSnapshot.h"

@interface LocalProgramsModule : NSObject <RishNativeModule>
@end
@implementation LocalProgramsModule
RISH_NATIVE_MODULE(LocalPrograms)
+ (BOOL)requiresMainQueueSetup { return NO; }
- (void)deliver:(NSDictionary *)result error:(NSError *)error resolve:(RishResolveBlock)resolve
        reject:(RishRejectBlock)reject {
  if (result) { resolve(result); return; }
  NSString *code = [error.domain isEqual:DSHRuntimeProgramErrorDomain]
      ? DSHRuntimeProgramError(error.userInfo[@"code"]).userInfo[@"code"] : @"E_PROGRAM_NATIVE";
  reject(code, code, nil);
}
RISH_NATIVE_METHOD(startProgram, startProgram:(id)request resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSError *error = nil;
  NSDictionary *result = [DSHRuntimeProgramService.sharedService startRequest:request error:&error];
  [self deliver:result error:error resolve:resolve reject:reject];
}
RISH_NATIVE_METHOD(programStatus, programStatus:(id)request resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSError *error = nil;
  NSDictionary *result = [DSHRuntimeProgramService.sharedService statusRequest:request error:&error];
  [self deliver:result error:error resolve:resolve reject:reject];
}
RISH_NATIVE_METHOD(stopProgram, stopProgram:(id)request resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSError *error = nil;
  NSDictionary *result = [DSHRuntimeProgramService.sharedService stopRequest:request error:&error];
  [self deliver:result error:error resolve:resolve reject:reject];
}
@end
