#import "ShellRuntimeEnginesModule.h"
#import "RishRuntimeEngineDownloads.h"

@interface ShellRuntimeEnginesModule ()
@property(nonatomic, strong) id<RishRuntimeEngineDownloadBackend> downloads;
@end

@implementation ShellRuntimeEnginesModule
RISH_NATIVE_MODULE(ShellRuntimeEngines)
+ (BOOL)requiresMainQueueSetup { return NO; }
- (instancetype)init {
  return [self initWithDownloads:(id<RishRuntimeEngineDownloadBackend>)[RishRuntimeEngineDownloads shared]];
}
- (instancetype)initWithDownloads:(id<RishRuntimeEngineDownloadBackend>)downloads {
  if ((self = [super init])) _downloads = downloads;
  return self;
}
RISH_NATIVE_METHOD(catalog, catalogWithResolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  NSMutableArray *engines = [NSMutableArray arrayWithObject:@{@"id": @"pi",
      @"installation": @{@"state": @"builtin", @"version": NSNull.null,
        @"download_supported": @NO, @"integrity": @"builtin"},
      @"execution": @{@"state": @"ready"},
      @"authentication": @{@"supported": @NO, @"source_selection": @NO,
        @"authorization_browser": @NO, @"native_code_entry": @NO,
        @"provider_selection": @NO}}];
  for (NSString *engineID in @[@"dsh", @"claude-code", @"codex", @"zcode"]) {
    BOOL harness = [engineID isEqual:@"claude-code"] || [engineID isEqual:@"codex"];
    BOOL zcode = [engineID isEqual:@"zcode"];
    BOOL authentication = harness || zcode;
    // An installed artifact and a working assistant adapter are separate facts.
    // None of these CLI engines currently has a shell execution adapter.
    [engines addObject:@{@"id": engineID,
        @"installation": [self.downloads installationForEngine:engineID],
        @"authentication": @{@"supported": @(authentication),
          @"source_selection": @(authentication), @"authorization_browser": @(authentication),
          @"native_code_entry": @(harness), @"provider_selection": @(zcode)},
        @"execution": @{@"state": @"unavailable", @"reason_code": @"cli_adapter_unavailable"}}];
  }
  resolve(@{@"schema_version": @1, @"engines": engines});
}
RISH_NATIVE_METHOD(install, installWithRequest:(NSDictionary *)request
    resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  if (![request isKindOfClass:NSDictionary.class]) {
    reject(@"runtime_engine_invalid_request", @"Choose a runtime engine download from an explicit user action.", nil); return;
  }
  id schema = request[@"schema_version"];
  id initiated = request[@"userInitiated"];
  NSString *engineID = request[@"engine_id"];
  BOOL valid = [request isKindOfClass:NSDictionary.class] && request.count == 3 &&
      [schema isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)schema) != CFBooleanGetTypeID() &&
      !CFNumberIsFloatType((__bridge CFNumberRef)schema) &&
      [schema isEqual:@1] && [initiated isKindOfClass:NSNumber.class] &&
      CFGetTypeID((__bridge CFTypeRef)initiated) == CFBooleanGetTypeID() && [initiated boolValue] &&
      [engineID isKindOfClass:NSString.class] && [@[@"dsh", @"claude-code", @"codex", @"zcode"] containsObject:engineID];
  if (!valid) {
    reject(@"runtime_engine_invalid_request", @"Choose a runtime engine download from an explicit user action.", nil); return;
  }
  if (![[self.downloads installationForEngine:engineID][@"download_supported"] boolValue]) {
    reject(@"runtime_engine_installer_unavailable", @"This runtime engine has no installer on this device.", nil); return;
  }
  [self.downloads installEngine:engineID];
  [self catalogWithResolver:resolve rejecter:reject];
}
@end
