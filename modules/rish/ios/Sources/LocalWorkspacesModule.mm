#import <Foundation/Foundation.h>
#import <RishNative/RishNativeModule.h>

#import "LocalProjectAccess.h"
#import "LocalWorkspaceAccess.h"

#include <CoreFoundation/CoreFoundation.h>
#include <math.h>

static const unsigned long long LWMaxSafeInteger = 9007199254740991ULL;

static BOOL LWIsBooleanNumber(id value) {
  return [value isKindOfClass:NSNumber.class] &&
         CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static BOOL LWIsSchemaVersionOne(id value) {
  return [value isKindOfClass:NSNumber.class] &&
         !LWIsBooleanNumber(value) && [value isEqual:@1];
}

static BOOL LWIsSafeRevision(id value, BOOL allowNull) {
  if (allowNull && value == NSNull.null) return YES;
  if (![value isKindOfClass:NSNumber.class] || LWIsBooleanNumber(value)) {
    return NO;
  }
  double number = [value doubleValue];
  return isfinite(number) && floor(number) == number && number >= 1.0 &&
         number <= (double)LWMaxSafeInteger &&
         !(number == 0.0 && signbit(number));
}

static BOOL LWIsCanonicalUUID(id value) {
  if (![value isKindOfClass:NSString.class]) return NO;
  NSString *string = value;
  NSRegularExpression *expression = [NSRegularExpression
      regularExpressionWithPattern:
          @"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
                             options:0
                               error:nil];
  NSRange full = NSMakeRange(0, string.length);
  if ([expression firstMatchInString:string options:0 range:full] == nil) {
    return NO;
  }
  NSUUID *UUID = [[NSUUID alloc] initWithUUIDString:string];
  return UUID != nil && [UUID.UUIDString.lowercaseString isEqual:string];
}

static BOOL LWIsBoundedDisplayName(id value) {
  if (![value isKindOfClass:NSString.class]) return NO;
  NSString *name = value;
  NSData *bytes = [name dataUsingEncoding:NSUTF8StringEncoding
                     allowLossyConversion:NO];
  NSString *normalized = [name precomposedStringWithCanonicalMapping];
  NSString *trimmed = [name
      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  return bytes != nil && bytes.length > 0 && bytes.length <= 120 &&
         [normalized isEqual:name] && [trimmed isEqual:name] &&
         [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet]
                 .location == NSNotFound &&
         [name rangeOfString:@"/"].location == NSNotFound &&
         [name rangeOfString:@"\\"].location == NSNotFound &&
         [name rangeOfString:@":"].location == NSNotFound &&
         [name rangeOfString:@"\0"].location == NSNotFound &&
         ![name hasPrefix:@"."];
}

static BOOL LWHasExactKeys(NSDictionary *value,
                           NSArray<NSString *> *keys) {
  if (![value isKindOfClass:NSDictionary.class] || value.count != keys.count) {
    return NO;
  }
  NSSet *expected = [NSSet setWithArray:keys];
  for (id key in value) {
    if (![key isKindOfClass:NSString.class] || ![expected containsObject:key]) {
      return NO;
    }
  }
  return YES;
}

static BOOL LWHasCanonicalCapabilities(id value) {
  if (![value isKindOfClass:NSArray.class] || [(NSArray *)value count] > 4) {
    return NO;
  }
  NSArray *order = @[@"read", @"write", @"git", @"project_context"];
  NSInteger previous = -1;
  NSMutableSet *seen = [NSMutableSet set];
  for (id item in value) {
    if (![item isKindOfClass:NSString.class] || [seen containsObject:item]) {
      return NO;
    }
    NSUInteger index = [order indexOfObject:item];
    if (index == NSNotFound || (NSInteger)index <= previous) return NO;
    previous = (NSInteger)index;
    [seen addObject:item];
  }
  return YES;
}

static NSError *LWInvalidError(void) {
  return [NSError errorWithDomain:DSHLocalWorkspaceAccessErrorDomain
                              code:DSHLocalWorkspaceAccessErrorInvalid
                          userInfo:@{
                            @"code" : @"E_WORKSPACE_INVALID",
                            NSLocalizedDescriptionKey :
                                @"Workspace request is invalid.",
                          }];
}

static NSError *LWUnavailableError(void) {
  return [NSError errorWithDomain:DSHLocalWorkspaceAccessErrorDomain
                              code:DSHLocalWorkspaceAccessErrorUnavailable
                          userInfo:@{
                            @"code" : @"E_WORKSPACE_UNAVAILABLE",
                            NSLocalizedDescriptionKey :
                                @"Workspace operation is unavailable.",
                          }];
}

static NSString *LWStableMessage(NSString *code);

static BOOL LWIsBoolean(id value) {
  return [value isKindOfClass:NSNumber.class] && LWIsBooleanNumber(value);
}

static BOOL LWIsCanonicalTimestamp(id value) {
  if (![value isKindOfClass:NSString.class]) return NO;
  NSString *timestamp = value;
  return timestamp.length == 24 &&
      [timestamp rangeOfString:
          @"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$"
                         options:NSRegularExpressionSearch].location == 0;
}

static NSDictionary *LWSafeWorkspaceDescriptor(id value) {
  if (![value isKindOfClass:NSDictionary.class]) return nil;
  NSDictionary *descriptor = value;
  NSDictionary *capabilities =
      [descriptor[@"capabilities"] isKindOfClass:NSDictionary.class]
          ? descriptor[@"capabilities"]
          : nil;
  NSArray<NSString *> *capabilityKeys = @[
    @"read", @"write", @"git", @"project_context", @"files_visible"
  ];
  NSArray<NSString *> *origins = @[
    @"rish_created", @"imported", @"granted_folder", @"legacy_app_owned"
  ];
  NSArray<NSString *> *statuses = @[
    @"ok", @"stale", @"revoked", @"unavailable", @"not_downloaded"
  ];
  if (![descriptor[@"schema_version"] isEqual:@2] ||
      !LWIsCanonicalUUID(descriptor[@"workspace_id"]) ||
      !LWIsBoundedDisplayName(descriptor[@"display_name"]) ||
      ![origins containsObject:descriptor[@"origin"]] ||
      ![statuses containsObject:descriptor[@"status"]] ||
      !LWIsSafeRevision(descriptor[@"binding_revision"], NO) ||
      !LWHasExactKeys(capabilities, capabilityKeys) ||
      !LWIsCanonicalTimestamp(descriptor[@"created_at"]) ||
      !LWIsCanonicalTimestamp(descriptor[@"last_opened_at"])) {
    return nil;
  }
  for (NSString *key in capabilityKeys) {
    if (!LWIsBoolean(capabilities[key])) return nil;
  }
  if (![descriptor[@"status"] isEqual:@"ok"] &&
      ([capabilities[@"read"] boolValue] ||
       [capabilities[@"write"] boolValue] ||
       [capabilities[@"git"] boolValue] ||
       [capabilities[@"project_context"] boolValue])) {
    return nil;
  }
  return @{
    @"schema_version" : @2,
    @"workspace_id" : [descriptor[@"workspace_id"] copy],
    @"display_name" : [descriptor[@"display_name"] copy],
    @"origin" : [descriptor[@"origin"] copy],
    @"status" : [descriptor[@"status"] copy],
    @"binding_revision" : descriptor[@"binding_revision"],
    @"capabilities" : @{
      @"read" : capabilities[@"read"],
      @"write" : capabilities[@"write"],
      @"git" : capabilities[@"git"],
      @"project_context" : capabilities[@"project_context"],
      @"files_visible" : capabilities[@"files_visible"],
    },
    @"created_at" : [descriptor[@"created_at"] copy],
    @"last_opened_at" : [descriptor[@"last_opened_at"] copy],
  };
}

@interface LocalWorkspacesModule : NSObject <RishNativeModule>
@property(nonatomic, strong) dispatch_queue_t workspaceQueue;
@property(nonatomic, strong) DSHLocalWorkspaceAccess *access;
@end

@implementation LocalWorkspacesModule

RISH_NATIVE_MODULE(LocalWorkspaces)

+ (BOOL)requiresMainQueueSetup {
  return NO;
}

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _workspaceQueue = dispatch_queue_create(
        "dev.zseven.rish.local-workspaces", DISPATCH_QUEUE_SERIAL);
    NSError *error = nil;
    NSURL *support = [[NSFileManager defaultManager]
        URLForDirectory:NSApplicationSupportDirectory
        inDomain:NSUserDomainMask
        appropriateForURL:nil
        create:YES
        error:&error];
    if (support != nil) {
      _access = [[DSHLocalWorkspaceAccess alloc]
          initWithPrivateRootURL:support
          clock:^NSDate *{
            return NSDate.date;
          }
          UUIDGenerator:^NSString *{
            return NSUUID.UUID.UUIDString.lowercaseString;
          }
          legacyResolver:^BOOL(
              NSString *projectId,
              NSDictionary *__autoreleasing *evidence,
              NSError *__autoreleasing *resolverError) {
            NSError *projectError = nil;
            NSDictionary *resolved = [[DSHLocalProjectAccess sharedAccess]
                legacyWorkspaceBootstrapEvidenceForProjectId:projectId
                                                       error:&projectError];
            if (resolved == nil) {
              if (resolverError != nil) *resolverError = projectError;
              return NO;
            }
            if (evidence != nil) *evidence = [resolved copy];
            return YES;
          }
          faultHook:nil];
    }
  }
  return self;
}

- (void)reject:(RishRejectBlock)reject error:(NSError *)error {
  if (error == nil) error = LWUnavailableError();
  NSString *code = error.userInfo[@"code"];
  NSString *message = [code isKindOfClass:NSString.class]
      ? LWStableMessage(code)
      : @"Workspace operation is unavailable.";
  if (![code isKindOfClass:NSString.class] ||
      [message isEqual:@"Workspace operation is unavailable."]) {
    code = @"E_WORKSPACE_UNAVAILABLE";
    message = LWStableMessage(code);
  }
  reject(code, message, nil);
}

- (void)rejectInvalid:(RishRejectBlock)reject {
  [self reject:reject error:LWInvalidError()];
}

- (void)rejectUnavailable:(RishRejectBlock)reject {
  [self reject:reject error:LWUnavailableError()];
}

- (void)dispatchInvalid:(RishRejectBlock)reject {
  dispatch_async(self.workspaceQueue, ^{
    [self rejectInvalid:reject];
  });
}

static NSString *LWStableMessage(NSString *code) {
  NSDictionary<NSString *, NSString *> *messages = @{
    @"E_WORKSPACE_INVALID" : @"Workspace request is invalid.",
    @"E_WORKSPACE_NOT_FOUND" : @"Workspace is not available.",
    @"E_WORKSPACE_BUSY" : @"Workspace storage is busy.",
    @"E_WORKSPACE_PICKER_BUSY" : @"Another workspace picker operation is active.",
    @"E_WORKSPACE_SELECTION_EXPIRED" : @"Workspace picker selection has expired.",
    @"E_WORKSPACE_REVISION_STALE" : @"Workspace binding is stale.",
    @"E_WORKSPACE_REVISION_OVERFLOW" : @"Workspace binding cannot be advanced.",
    @"E_WORKSPACE_STATUS_STALE" : @"Workspace authority is stale.",
    @"E_WORKSPACE_REVOKED" : @"Workspace authority was revoked.",
    @"E_WORKSPACE_UNAVAILABLE" : @"Workspace is unavailable.",
    @"E_WORKSPACE_NOT_DOWNLOADED" : @"Workspace content is not downloaded.",
    @"E_WORKSPACE_IMPORT_REQUIRED" : @"Workspace import is required.",
    @"E_WORKSPACE_CAPABILITY" : @"Workspace capability is unavailable.",
    @"E_WORKSPACE_ROOT_CHANGED" : @"Workspace root changed.",
    @"E_WORKSPACE_REFERENCED" : @"Workspace is still referenced.",
    @"E_WORKSPACE_CONFIRMATION" : @"Workspace confirmation is invalid.",
    @"E_WORKSPACE_CONFLICT" : @"Workspace storage changed concurrently.",
    @"E_WORKSPACE_PERSISTENCE" : @"Workspace storage is invalid.",
    @"E_WORKSPACE_IO" : @"Workspace operation failed.",
  };
  return messages[code] ?: @"Workspace operation is unavailable.";
}

RISH_NATIVE_METHOD(list,
                 listWithResolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  dispatch_async(self.workspaceQueue, ^{
    NSError *error = nil;
    if (self.access == nil || ![self.access ensurePrivateLayoutWithError:&error]) {
      [self reject:reject error:error];
      return;
    }
    NSArray<NSDictionary *> *workspaces =
        [self.access listWorkspaceMetadataWithError:&error];
    if (workspaces == nil) {
      [self reject:reject error:error];
      return;
    }
    resolve(@{ @"schema_version" : @1, @"workspaces" : workspaces });
  });
}

RISH_NATIVE_METHOD(create,
                 createWorkspaceRequest:(id)requestValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSDictionary *request = [requestValue isKindOfClass:NSDictionary.class]
      ? requestValue
      : nil;
  if (!LWHasExactKeys(request,
                      @[@"schema_version", @"display_name", @"operation_id"]) ||
      !LWIsSchemaVersionOne(request[@"schema_version"]) ||
      !LWIsBoundedDisplayName(request[@"display_name"]) ||
      !LWIsCanonicalUUID(request[@"operation_id"])) {
    [self dispatchInvalid:reject];
    return;
  }
  dispatch_async(self.workspaceQueue, ^{
    NSError *error = nil;
    NSDictionary *descriptor =
        [self.access createRishOwnedWorkspaceWithDisplayName:request[@"display_name"]
                                                   operationId:request[@"operation_id"]
                                                         error:&error];
    if (descriptor == nil) {
      [self reject:reject error:error];
      return;
    }
    resolve(descriptor);
  });
}

RISH_NATIVE_METHOD(bootstrapLegacyProject,
                 bootstrapLegacyProjectRequest:(id)requestValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSDictionary *request = [requestValue isKindOfClass:NSDictionary.class]
      ? requestValue
      : nil;
  if (!LWHasExactKeys(request,
                      @[@"schema_version", @"project_id", @"operation_id"]) ||
      !LWIsSchemaVersionOne(request[@"schema_version"]) ||
      !LWIsCanonicalUUID(request[@"project_id"]) ||
      !LWIsCanonicalUUID(request[@"operation_id"])) {
    [self dispatchInvalid:reject];
    return;
  }
  NSString *projectId = [request[@"project_id"] copy];
  NSString *operationId = [request[@"operation_id"] copy];
  dispatch_async(self.workspaceQueue, ^{
    NSError *error = nil;
    NSDictionary *descriptor = [self.access
        bootstrapLegacyProjectId:projectId
                     operationId:operationId
                           error:&error];
    if (descriptor == nil) {
      [self reject:reject error:error];
      return;
    }
    NSDictionary *safeDescriptor = LWSafeWorkspaceDescriptor(descriptor);
    if (safeDescriptor == nil) {
      [self rejectUnavailable:reject];
      return;
    }
    resolve(safeDescriptor);
  });
}

RISH_NATIVE_METHOD(presentFolderPicker,
                 presentFolderPickerRequest:(id)requestValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSDictionary *request = [requestValue isKindOfClass:NSDictionary.class]
      ? requestValue
      : nil;
  NSString *mode = request[@"mode"];
  if (!LWHasExactKeys(request,
                      @[@"schema_version", @"operation_id", @"mode"]) ||
      !LWIsSchemaVersionOne(request[@"schema_version"]) ||
      !LWIsCanonicalUUID(request[@"operation_id"]) ||
      (![mode isEqual:@"grant_or_import"] && ![mode isEqual:@"import_only"])) {
    [self dispatchInvalid:reject];
    return;
  }
  (void)resolve;
  [self rejectUnavailable:reject];
}

RISH_NATIVE_METHOD(importSelection,
                 importSelectionRequest:(id)requestValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSDictionary *request = [requestValue isKindOfClass:NSDictionary.class]
      ? requestValue
      : nil;
  if (!LWHasExactKeys(request,
                      @[@"schema_version", @"selection_id", @"operation_id"]) ||
      !LWIsSchemaVersionOne(request[@"schema_version"]) ||
      !LWIsCanonicalUUID(request[@"selection_id"]) ||
      !LWIsCanonicalUUID(request[@"operation_id"])) {
    [self dispatchInvalid:reject];
    return;
  }
  (void)resolve;
  [self rejectUnavailable:reject];
}

RISH_NATIVE_METHOD(cancelSelection,
                 cancelSelectionRequest:(id)requestValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSDictionary *request = [requestValue isKindOfClass:NSDictionary.class]
      ? requestValue
      : nil;
  if (!LWHasExactKeys(request, @[@"schema_version", @"selection_id"]) ||
      !LWIsSchemaVersionOne(request[@"schema_version"]) ||
      !LWIsCanonicalUUID(request[@"selection_id"])) {
    [self dispatchInvalid:reject];
    return;
  }
  (void)resolve;
  [self rejectUnavailable:reject];
}

RISH_NATIVE_METHOD(presentRegrantPicker,
                 presentRegrantPickerRequest:(id)requestValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSDictionary *request = [requestValue isKindOfClass:NSDictionary.class]
      ? requestValue
      : nil;
  if (!LWHasExactKeys(request, @[
        @"schema_version", @"workspace_id", @"expected_binding_revision",
        @"operation_id",
      ]) ||
      !LWIsSchemaVersionOne(request[@"schema_version"]) ||
      !LWIsCanonicalUUID(request[@"workspace_id"]) ||
      !LWIsSafeRevision(request[@"expected_binding_revision"], NO) ||
      !LWIsCanonicalUUID(request[@"operation_id"])) {
    [self dispatchInvalid:reject];
    return;
  }
  (void)resolve;
  [self rejectUnavailable:reject];
}

RISH_NATIVE_METHOD(completeRegrant,
                 completeRegrantRequest:(id)requestValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSDictionary *request = [requestValue isKindOfClass:NSDictionary.class]
      ? requestValue
      : nil;
  if (!LWHasExactKeys(request, @[
        @"schema_version", @"workspace_id", @"expected_binding_revision",
        @"selection_id", @"operation_id",
      ]) ||
      !LWIsSchemaVersionOne(request[@"schema_version"]) ||
      !LWIsCanonicalUUID(request[@"workspace_id"]) ||
      !LWIsSafeRevision(request[@"expected_binding_revision"], NO) ||
      !LWIsCanonicalUUID(request[@"selection_id"]) ||
      !LWIsCanonicalUUID(request[@"operation_id"])) {
    [self dispatchInvalid:reject];
    return;
  }
  (void)resolve;
  [self rejectUnavailable:reject];
}

RISH_NATIVE_METHOD(resolve,
                 resolveWorkspaceRequest:(id)requestValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSDictionary *request = [requestValue isKindOfClass:NSDictionary.class]
      ? requestValue
      : nil;
  id revision = request[@"expected_binding_revision"];
  if (!LWHasExactKeys(request, @[
        @"schema_version", @"workspace_id", @"expected_binding_revision",
        @"required_capabilities",
      ]) ||
      !LWIsSchemaVersionOne(request[@"schema_version"]) ||
      !LWIsCanonicalUUID(request[@"workspace_id"]) ||
      !LWIsSafeRevision(revision, YES) ||
      !LWHasCanonicalCapabilities(request[@"required_capabilities"])) {
    [self dispatchInvalid:reject];
    return;
  }
  dispatch_async(self.workspaceQueue, ^{
    NSError *error = nil;
    NSDictionary *result = [self.access
        resolveWorkspaceId:request[@"workspace_id"]
        expectedBindingRevision:revision == NSNull.null ? nil : revision
        requiredCapabilities:request[@"required_capabilities"]
        error:&error];
    if (result == nil) {
      [self reject:reject error:error];
      return;
    }
    resolve(result);
  });
}

RISH_NATIVE_METHOD(forget,
                 forgetWorkspaceRequest:(id)requestValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSDictionary *request = [requestValue isKindOfClass:NSDictionary.class]
      ? requestValue
      : nil;
  if (!LWHasExactKeys(request, @[
        @"schema_version", @"workspace_id", @"expected_binding_revision",
        @"operation_id", @"clearance_receipt_id",
      ]) ||
      !LWIsSchemaVersionOne(request[@"schema_version"]) ||
      !LWIsCanonicalUUID(request[@"workspace_id"]) ||
      !LWIsSafeRevision(request[@"expected_binding_revision"], NO) ||
      !LWIsCanonicalUUID(request[@"operation_id"]) ||
      !LWIsCanonicalUUID(request[@"clearance_receipt_id"])) {
    [self dispatchInvalid:reject];
    return;
  }
  dispatch_async(self.workspaceQueue, ^{
    NSError *error = nil;
    NSDictionary *result = [self.access
        forgetWorkspaceId:request[@"workspace_id"]
        expectedBindingRevision:request[@"expected_binding_revision"]
        operationId:request[@"operation_id"]
        clearanceReceiptId:request[@"clearance_receipt_id"]
        error:&error];
    if (result == nil) {
      [self reject:reject error:error];
      return;
    }
    resolve(result);
  });
}

RISH_NATIVE_METHOD(prepareDeleteOwnedContent,
                 prepareDeleteOwnedContentRequest:(id)requestValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSDictionary *request = [requestValue isKindOfClass:NSDictionary.class]
      ? requestValue
      : nil;
  if (!LWHasExactKeys(request, @[
        @"schema_version", @"workspace_id", @"expected_binding_revision",
        @"clearance_receipt_id",
      ]) ||
      !LWIsSchemaVersionOne(request[@"schema_version"]) ||
      !LWIsCanonicalUUID(request[@"workspace_id"]) ||
      !LWIsSafeRevision(request[@"expected_binding_revision"], NO) ||
      !LWIsCanonicalUUID(request[@"clearance_receipt_id"])) {
    [self dispatchInvalid:reject];
    return;
  }
  dispatch_async(self.workspaceQueue, ^{
    NSError *error = nil;
    NSDictionary *result = [self.access
        prepareDeleteOwnedContentForWorkspaceId:request[@"workspace_id"]
        expectedBindingRevision:request[@"expected_binding_revision"]
        clearanceReceiptId:request[@"clearance_receipt_id"]
        error:&error];
    if (result == nil) {
      [self reject:reject error:error];
      return;
    }
    resolve(result);
  });
}

RISH_NATIVE_METHOD(deleteOwnedContent,
                 deleteOwnedContentRequest:(id)requestValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSDictionary *request = [requestValue isKindOfClass:NSDictionary.class]
      ? requestValue
      : nil;
  if (!LWHasExactKeys(request, @[
        @"schema_version", @"workspace_id", @"expected_binding_revision",
        @"operation_id", @"clearance_receipt_id", @"confirmation_id",
      ]) ||
      !LWIsSchemaVersionOne(request[@"schema_version"]) ||
      !LWIsCanonicalUUID(request[@"workspace_id"]) ||
      !LWIsSafeRevision(request[@"expected_binding_revision"], NO) ||
      !LWIsCanonicalUUID(request[@"operation_id"]) ||
      !LWIsCanonicalUUID(request[@"clearance_receipt_id"]) ||
      !LWIsCanonicalUUID(request[@"confirmation_id"])) {
    [self dispatchInvalid:reject];
    return;
  }
  dispatch_async(self.workspaceQueue, ^{
    NSError *error = nil;
    NSDictionary *result = [self.access
        deleteOwnedContentForWorkspaceId:request[@"workspace_id"]
        expectedBindingRevision:request[@"expected_binding_revision"]
        operationId:request[@"operation_id"]
        clearanceReceiptId:request[@"clearance_receipt_id"]
        confirmationId:request[@"confirmation_id"]
        error:&error];
    if (result == nil) {
      [self reject:reject error:error];
      return;
    }
    resolve(result);
  });
}

RISH_NATIVE_METHOD(queryOperation,
                 queryOperationRequest:(id)requestValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSDictionary *request = [requestValue isKindOfClass:NSDictionary.class]
      ? requestValue
      : nil;
  if (!LWHasExactKeys(request, @[@"schema_version", @"operation_id"]) ||
      !LWIsSchemaVersionOne(request[@"schema_version"]) ||
      !LWIsCanonicalUUID(request[@"operation_id"])) {
    [self dispatchInvalid:reject];
    return;
  }
  dispatch_async(self.workspaceQueue, ^{
    NSError *error = nil;
    NSDictionary *result = [self.access queryOperationId:request[@"operation_id"]
                                                   error:&error];
    if (result == nil) {
      [self reject:reject error:error];
      return;
    }
    resolve(result);
  });
}

RISH_NATIVE_METHOD(cancelPicker,
                 cancelPickerRequest:(id)requestValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSDictionary *request = [requestValue isKindOfClass:NSDictionary.class]
      ? requestValue
      : nil;
  if (!LWHasExactKeys(request, @[@"schema_version", @"operation_id"]) ||
      !LWIsSchemaVersionOne(request[@"schema_version"]) ||
      !LWIsCanonicalUUID(request[@"operation_id"])) {
    [self dispatchInvalid:reject];
    return;
  }
  (void)resolve;
  [self rejectUnavailable:reject];
}

@end
