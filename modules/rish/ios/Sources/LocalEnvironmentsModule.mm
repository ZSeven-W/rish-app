#import "RuntimeEnvironmentStore.h"
#import <RishNative/RishNativeModule.h>
#import <RishNative/RishUIKit.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static BOOL EnvironmentRequest(id request, NSArray *keys) {
  if (![request isKindOfClass:NSDictionary.class] || ![[NSSet setWithArray:[request allKeys]]
      isEqual:[NSSet setWithArray:[@[@"schema_version"] arrayByAddingObjectsFromArray:keys]]]) return NO;
  id version = request[@"schema_version"];
  return [version isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)version) != CFBooleanGetTypeID()
      && [version isEqual:@1];
}
static void EnvironmentReject(RishRejectBlock reject, NSError *error) {
  NSSet *codes = [NSSet setWithArray:@[@"E_ENV_BAD_ARGUMENTS",@"E_ENV_STORAGE",@"E_ENV_NOT_FOUND",@"E_ENV_NOT_INSTALLED",
      @"E_ENV_BUSY",@"E_ENV_IN_USE",@"E_ENV_LIMIT",@"E_ENV_PACKAGE_INVALID",@"E_ENV_PACKAGE_TOO_LARGE",
      @"E_ENV_INCOMPATIBLE",@"E_ENV_INTEGRITY",@"E_ENV_DISK_SPACE",@"E_ENV_DOWNLOAD",@"E_ENV_CANCELLED",
      @"E_ENV_CONFLICT",@"E_ENV_UNAVAILABLE"]];
  NSString *code = [error.domain isEqual:DSHRuntimeEnvironmentErrorDomain] ? error.userInfo[@"code"] : nil;
  if (![code isKindOfClass:NSString.class] || ![codes containsObject:code]) code = @"E_ENV_STORAGE";
  // Neither a provider URL nor a host pathname is ever included in bridge failures.
  reject(code, code, nil);
}

@interface DSHOwnedEnvironmentInstall : NSObject
@property(nonatomic, copy) NSString *token;
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL cancelled;
@property(nonatomic) BOOL settled;
@end
@implementation DSHOwnedEnvironmentInstall
@end

@interface LocalEnvironmentsModule : NSObject <RishNativeModule, UIDocumentPickerDelegate>
@property(nonatomic, copy) RishResolveBlock importResolve;
@property(nonatomic, copy) RishRejectBlock importReject;
@property(nonatomic, strong) UIDocumentPickerViewController *picker;
// Keep bounded completion tombstones so a late cleanup cannot reuse a task ID.
@property(nonatomic, strong) NSMutableDictionary<NSString *, DSHOwnedEnvironmentInstall *> *ownedInstalls;
@end

@implementation LocalEnvironmentsModule
RISH_NATIVE_MODULE(LocalEnvironments)
+ (BOOL)requiresMainQueueSetup { return NO; }
// Override only in native tests. Store calls must stay outside the module lock:
// beginInstallEnvironmentId may invoke its completion synchronously.
- (DSHRuntimeEnvironmentStore *)environmentStore { return DSHRuntimeEnvironmentStore.sharedStore; }

RISH_NATIVE_METHOD(listEnvironments, listEnvironmentsRequest:(id)request
    resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  if (!EnvironmentRequest(request, @[@"workspace_id"]) || (request[@"workspace_id"] != NSNull.null
      && !DSHEnvironmentValidWorkspaceId(request[@"workspace_id"]))) {
    EnvironmentReject(reject, DSHEnvironmentError(@"E_ENV_BAD_ARGUMENTS")); return;
  }
  NSError *error = nil;
  NSDictionary *result = [DSHRuntimeEnvironmentStore.sharedStore listEnvironmentsForWorkspaceId:
      request[@"workspace_id"] == NSNull.null ? nil : request[@"workspace_id"] error:&error];
  if (result) resolve(result); else EnvironmentReject(reject, error);
}
RISH_NATIVE_METHOD(selectEnvironment, selectEnvironmentRequest:(id)request
    resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  if (!EnvironmentRequest(request, @[@"workspace_id",@"environment_id"])) {
    EnvironmentReject(reject, DSHEnvironmentError(@"E_ENV_BAD_ARGUMENTS")); return;
  }
  NSError *error = nil;
  if ([DSHRuntimeEnvironmentStore.sharedStore selectEnvironmentId:request[@"environment_id"] workspaceId:request[@"workspace_id"] error:&error])
    resolve(@{@"schema_version":@1,@"status":@"selected"});
  else EnvironmentReject(reject, error);
}
RISH_NATIVE_METHOD(removeEnvironment, removeEnvironmentRequest:(id)request
    resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  if (!EnvironmentRequest(request, @[@"environment_id"])) {
    EnvironmentReject(reject, DSHEnvironmentError(@"E_ENV_BAD_ARGUMENTS")); return;
  }
  NSError *error = nil;
  if ([DSHRuntimeEnvironmentStore.sharedStore removeEnvironmentId:request[@"environment_id"] error:&error])
    resolve(@{@"schema_version":@1,@"status":@"removed"});
  else EnvironmentReject(reject, error);
}
RISH_NATIVE_METHOD(installEnvironment, installEnvironmentRequest:(id)request
    resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  if (!EnvironmentRequest(request, @[@"environment_id"]) || !DSHEnvironmentValidId(request[@"environment_id"])) {
    EnvironmentReject(reject, DSHEnvironmentError(@"E_ENV_BAD_ARGUMENTS")); return;
  }
  [DSHRuntimeEnvironmentStore.sharedStore installEnvironmentId:request[@"environment_id"] completion:^(NSDictionary *result, NSError *error) {
    if (result) resolve(result); else EnvironmentReject(reject, error);
  }];
}
RISH_NATIVE_METHOD(installEnvironmentOwned, installEnvironmentOwnedRequest:(id)request
    resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  if (!EnvironmentRequest(request, @[@"operation_id",@"environment_id"])
      || !DSHEnvironmentValidWorkspaceId(request[@"operation_id"])
      || !DSHEnvironmentValidId(request[@"environment_id"])) {
    EnvironmentReject(reject, DSHEnvironmentError(@"E_ENV_BAD_ARGUMENTS")); return;
  }
  NSString *operationId = request[@"operation_id"];
  DSHOwnedEnvironmentInstall *operation = nil;
  NSString *failure = nil;
  @synchronized (self) {
    if (!self.ownedInstalls) self.ownedInstalls = [NSMutableDictionary new];
    operation = self.ownedInstalls[operationId];
    if (operation.started) failure = @"E_ENV_CONFLICT";
    else if (!operation && self.ownedInstalls.count >= 256) failure = @"E_ENV_LIMIT";
    else {
      if (!operation) { operation = [DSHOwnedEnvironmentInstall new]; self.ownedInstalls[operationId] = operation; }
      operation.started = YES;
      if (operation.cancelled) { operation.settled = YES; failure = @"E_ENV_CANCELLED"; }
    }
  }
  if (failure) { EnvironmentReject(reject, DSHEnvironmentError(failure)); return; }
  DSHRuntimeEnvironmentStore *store = [self environmentStore];
  NSString *token = [store beginInstallEnvironmentId:request[@"environment_id"] completion:^(NSDictionary *result, NSError *error) {
    BOOL cancelled = NO;
    @synchronized (self) {
      operation.settled = YES; operation.token = nil; cancelled = operation.cancelled;
    }
    if (cancelled) EnvironmentReject(reject, DSHEnvironmentError(@"E_ENV_CANCELLED"));
    else if (result) resolve(result);
    else EnvironmentReject(reject, error);
  }];
  BOOL cancelToken = NO;
  @synchronized (self) {
    if (!operation.settled) { operation.token = token; cancelToken = operation.cancelled && token != nil; }
  }
  if (cancelToken) [store cancelInstallToken:token];
}
RISH_NATIVE_METHOD(cancelOwnedInstall, cancelOwnedInstallRequest:(id)request
    resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  if (!EnvironmentRequest(request, @[@"operation_id"]) || !DSHEnvironmentValidWorkspaceId(request[@"operation_id"])) {
    EnvironmentReject(reject, DSHEnvironmentError(@"E_ENV_BAD_ARGUMENTS")); return;
  }
  NSString *operationId = request[@"operation_id"], *token = nil;
  BOOL limited = NO, settled = NO;
  @synchronized (self) {
    if (!self.ownedInstalls) self.ownedInstalls = [NSMutableDictionary new];
    DSHOwnedEnvironmentInstall *operation = self.ownedInstalls[operationId];
    if (!operation && self.ownedInstalls.count >= 256) limited = YES;
    else {
      // Remember cancellation even when app UI delivers it before install.
      if (!operation) { operation = [DSHOwnedEnvironmentInstall new]; self.ownedInstalls[operationId] = operation; }
      settled = operation.settled;
      if (!settled) { operation.cancelled = YES; token = operation.token; }
    }
  }
  if (limited) { EnvironmentReject(reject, DSHEnvironmentError(@"E_ENV_LIMIT")); return; }
  if (token) [[self environmentStore] cancelInstallToken:token];
  resolve(@{@"schema_version":@1,@"status":settled ? @"idle" : @"cancelled"});
}
RISH_NATIVE_METHOD(downloadEnvironment, downloadEnvironmentRequest:(id)request
    resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  if (!EnvironmentRequest(request, @[@"url"]) || !DSHEnvironmentValidHTTPSURL(request[@"url"])) {
    EnvironmentReject(reject, DSHEnvironmentError(@"E_ENV_BAD_ARGUMENTS")); return;
  }
  [DSHRuntimeEnvironmentStore.sharedStore downloadURL:request[@"url"] completion:^(NSDictionary *result, NSError *error) {
    if (result) resolve(result); else EnvironmentReject(reject, error);
  }];
}
RISH_NATIVE_METHOD(cancelInstall, cancelInstallRequest:(id)request
    resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  if (!EnvironmentRequest(request, @[])) { EnvironmentReject(reject, DSHEnvironmentError(@"E_ENV_BAD_ARGUMENTS")); return; }
  resolve(@{@"schema_version":@1,@"status":[DSHRuntimeEnvironmentStore.sharedStore cancelInstall] ? @"cancelled" : @"idle"});
}
RISH_NATIVE_METHOD(importEnvironment, importEnvironmentResolver:(RishResolveBlock)resolve
    rejecter:(RishRejectBlock)reject) {
  dispatch_async(dispatch_get_main_queue(), ^{
    UIViewController *presenter = RishPresentedViewController();
    if (self.importResolve || self.picker || !presenter || presenter.isBeingDismissed || presenter.isBeingPresented) {
      EnvironmentReject(reject, DSHEnvironmentError(@"E_ENV_BUSY")); return;
    }
    self.importResolve = resolve; self.importReject = reject;
    // Read in place instead of asking the picker to copy a potentially large toolchain into its cache.
    self.picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:NO];
    self.picker.allowsMultipleSelection = NO; self.picker.delegate = self;
    [presenter presentViewController:self.picker animated:YES completion:nil];
  });
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
  if (controller != self.picker) return;
  RishResolveBlock resolve = self.importResolve;
  self.importResolve = nil; self.importReject = nil; self.picker = nil;
  if (resolve) resolve(NSNull.null);
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
  if (controller != self.picker) return;
  RishResolveBlock resolve = self.importResolve; RishRejectBlock reject = self.importReject;
  self.picker = nil;
  NSURL *url = urls.count == 1 ? urls.firstObject : nil;
  if (!url || ![url.pathExtension.lowercaseString isEqual:@"rishenv"]) {
    self.importResolve = nil; self.importReject = nil;
    EnvironmentReject(reject, DSHEnvironmentError(@"E_ENV_PACKAGE_INVALID")); return;
  }
  BOOL scoped = [url startAccessingSecurityScopedResource];
  [DSHRuntimeEnvironmentStore.sharedStore importPackageURL:url completion:^(NSDictionary *result, NSError *error) {
    if (scoped) [url stopAccessingSecurityScopedResource];
    dispatch_async(dispatch_get_main_queue(), ^{
      self.importResolve = nil; self.importReject = nil;
      if (result) resolve(result); else EnvironmentReject(reject, error);
    });
  }];
}
@end
