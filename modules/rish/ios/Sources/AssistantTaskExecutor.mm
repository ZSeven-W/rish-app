#import "AssistantTaskExecutor.h"
#import "AgentNativeWAL.h"
#import "AgentRootResolver.h"
#include <sys/stat.h>

// Optional only for native test hosts that do not link GPUI. Missing Rust
// authority fails closed; there is deliberately no Objective-C store fallback.
extern "C" char *rish_gpui_assistant_store_json(const char *, const uint8_t *, size_t)
    __attribute__((weak_import));
extern "C" void rish_gpui_assistant_store_free(char *)
    __attribute__((weak_import));

BOOL DSHAgentIsAssistantTaskTool(NSString *name) {
  return [name isEqual:@"list_assistant_tasks"] ||
      [name isEqual:@"create_assistant_task"] ||
      [name isEqual:@"update_assistant_task"] ||
      [name isEqual:@"search_assistant_memory"] ||
      [name isEqual:@"remember_assistant_memory"] ||
      [name isEqual:@"forget_assistant_memory"];
}

BOOL DSHAgentIsAssistantMutationTool(NSString *name) {
  return [name isEqual:@"create_assistant_task"] || [name isEqual:@"update_assistant_task"] ||
      [name isEqual:@"remember_assistant_memory"] || [name isEqual:@"forget_assistant_memory"];
}

@interface DSHAssistantTaskExecutor ()
@property(nonatomic, strong) DSHAgentRootResolver *rootResolver;
@end

@implementation DSHAssistantTaskExecutor

- (instancetype)initWithRootResolver:(DSHAgentRootResolver *)rootResolver {
  self = [super init];
  if (self) _rootResolver = rootResolver;
  return self;
}

// This root is the same app-private location used by ShellAssistantModule.
// No request, conversation, workspace or model field participates in its path.
- (NSURL *)privateDirectory {
  NSURL *base = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory
      inDomain:NSUserDomainMask appropriateForURL:nil create:NO error:nil];
  NSURL *directory = [base URLByAppendingPathComponent:@"Assistant-v1" isDirectory:YES];
  struct stat metadata = {};
  if (directory == nil || lstat(directory.fileSystemRepresentation, &metadata) != 0 ||
      !S_ISDIR(metadata.st_mode) || (metadata.st_mode & 0777) != 0700) return nil;
  return directory.URLByResolvingSymlinksInPath;
}

- (NSDictionary *)invokeStore:(NSDictionary *)fields error:(NSError **)error {
  NSURL *directory = [self privateDirectory];
  if (!directory.isFileURL || !directory.path.isAbsolutePath ||
      rish_gpui_assistant_store_json == NULL ||
      rish_gpui_assistant_store_free == NULL) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorUnavailable);
    return nil;
  }
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:fields options:0 error:error];
  if (bytes == nil) return nil;
  char *raw = rish_gpui_assistant_store_json(directory.fileSystemRepresentation,
      (const uint8_t *)bytes.bytes, bytes.length);
  if (raw == NULL) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorUnavailable);
    return nil;
  }
  NSData *replyBytes = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_gpui_assistant_store_free(raw);
  id reply = [NSJSONSerialization JSONObjectWithData:replyBytes options:0 error:nil];
  if (![reply isKindOfClass:NSDictionary.class] || ![reply[@"ok"] isEqual:@YES]) {
    NSInteger code = [reply isKindOfClass:NSDictionary.class] &&
        [reply[@"error"] isKindOfClass:NSNumber.class] ? [reply[@"error"] integerValue] : 0;
    if ([reply isKindOfClass:NSDictionary.class] && [reply[@"error"] isKindOfClass:NSString.class]) {
      NSDictionary *codes = @{@"E_AGENT_BAD_ARGUMENTS":@(DSHAgentNativeStoreErrorInvalidArgument),
          @"E_AGENT_CONFLICT":@(DSHAgentNativeStoreErrorConflict),
          @"E_AGENT_NOT_FOUND":@(DSHAgentNativeStoreErrorNotFound),
          @"E_AGENT_PERSISTENCE":@(DSHAgentNativeStoreErrorPersistence)};
      code = [codes[reply[@"error"]] integerValue];
    }
    if (code < DSHAgentNativeStoreErrorInvalidArgument || code > DSHAgentNativeStoreErrorPersistence)
      code = DSHAgentNativeStoreErrorConflict;
    DSHSetAgentNativeStoreError(error, (DSHAgentNativeStoreErrorCode)code);
    return nil;
  }
  return reply[@"result"];
}

- (NSDictionary *)authorizationForConversation:(NSDictionary *)conversation
                                registryVersion:(NSNumber *)registryVersion error:(NSError **)error {
  NSString *identifier = [conversation isKindOfClass:NSDictionary.class]
      ? conversation[@"id"] ?: conversation[@"conversation_id"] : nil;
  if (![registryVersion isEqual:@5] || ![identifier isKindOfClass:NSString.class] ||
      identifier.length == 0) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorConflict);
    return nil;
  }
  NSDictionary *reply = [self invokeStore:@{@"action":@"authorize",
      @"conversation_id":identifier} error:error];
  if (![reply[@"authorized"] isEqual:@YES]) {
    if (error != nullptr && *error == nil)
      DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorConflict);
    return nil;
  }
  return reply;
}

- (BOOL)authorizeConversation:(NSDictionary *)conversation
              registryVersion:(NSNumber *)registryVersion error:(NSError **)error {
  return [self authorizationForConversation:conversation registryVersion:registryVersion error:error] != nil;
}

- (NSDictionary *)assistantContextForConversation:(NSDictionary *)conversation
                                   registryVersion:(NSNumber *)registryVersion error:(NSError **)error {
  NSDictionary *reply = [self authorizationForConversation:conversation registryVersion:registryVersion error:error];
  NSString *identifier = [conversation isKindOfClass:NSDictionary.class]
      ? conversation[@"id"] ?: conversation[@"conversation_id"] : nil;
  NSDictionary *context = reply[@"assistant_context"];
  // A group member has its own immutable execution conversation. Freeze only
  // that lane's persona, never a cached or currently selected Bot's profile.
  if (![context isKindOfClass:NSDictionary.class] ||
      ![context[@"conversation_id"] isEqual:identifier]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorConflict);
    return nil;
  }
  return [context copy];
}

- (NSDictionary *)contextForConversation:(NSDictionary *)conversation
                                 request:(NSDictionary *)request error:(NSError **)error {
  NSDictionary *binding = conversation[@"workspace_binding"], *root = request[@"root"];
  NSString *model = conversation[@"model_id"];
  if (![binding isKindOfClass:NSDictionary.class] || ![root isKindOfClass:NSDictionary.class] ||
      ![model isKindOfClass:NSString.class] || model.length == 0 ||
      ![binding[@"workspace_id"] isEqual:root[@"workspace_id"]] ||
      ![binding[@"binding_revision"] isEqual:root[@"workspace_binding_revision"]] ||
      ![binding[@"project_id"] isEqual:root[@"project_id"]] ||
      ![root[@"capabilities"] containsObject:@"file_read"] ||
      ![self.rootResolver validateFrozenRoot:root error:error]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorConflict);
    return nil;
  }
  NSDictionary *resolved = [self.rootResolver.workspaceAccess
      resolveWorkspaceId:binding[@"workspace_id"] expectedBindingRevision:binding[@"binding_revision"]
      requiredCapabilities:@[@"read"] error:error];
  NSDictionary *descriptor = resolved[@"workspace"];
  if (![descriptor isKindOfClass:NSDictionary.class] ||
      ![descriptor[@"workspace_id"] isEqual:binding[@"workspace_id"]] ||
      ![descriptor[@"binding_revision"] isEqual:binding[@"binding_revision"]]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorConflict);
    return nil;
  }
  return @{@"conversation_id":request[@"conversation_id"], @"model_id":model,
      @"workspace_binding":binding, @"workspace_descriptor":descriptor};
}

- (NSDictionary *)callStore:(NSString *)operation name:(NSString *)name
                  arguments:(NSDictionary *)arguments conversation:(NSDictionary *)conversation
                    request:(NSDictionary *)request locator:(NSDictionary *)locator
               precondition:(NSDictionary *)precondition registryVersion:(NSNumber *)registryVersion
                      error:(NSError **)error {
  NSString *identifier = [conversation isKindOfClass:NSDictionary.class]
      ? conversation[@"id"] ?: conversation[@"conversation_id"] : nil;
  if (!DSHAgentIsAssistantTaskTool(name) || ![identifier isEqual:request[@"conversation_id"]] ||
      ![self authorizeConversation:conversation registryVersion:registryVersion error:error]) {
    if (error != nullptr && *error == nil)
      DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorConflict);
    return nil;
  }
  NSDictionary *context = [self contextForConversation:conversation request:request error:error];
  NSData *argumentsBytes = DSHAgentCanonicalJSON(arguments, error);
  NSString *argumentsJSON = argumentsBytes == nil ? nil
      : [[NSString alloc] initWithData:argumentsBytes encoding:NSUTF8StringEncoding];
  NSString *digest = argumentsJSON == nil ? nil : DSHAgentArgumentsSHA256(name, argumentsJSON, error);
  if (context == nil || digest == nil ||
      (request[@"arguments_sha256"] != nil && ![digest isEqual:request[@"arguments_sha256"]]) ||
      (precondition != nil && (![digest isEqual:precondition[@"arguments_sha256"]] ||
       ![name isEqual:precondition[@"kind"]] ||
       ![identifier isEqual:precondition[@"conversation_id"]]))) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorConflict);
    return nil;
  }
  NSMutableDictionary *fields = [@{@"action":operation, @"name":name,
      @"conversation_id":identifier, @"arguments":arguments, @"arguments_sha256":digest,
      @"context":context} mutableCopy];
  if (locator != nil) fields[@"locator"] = locator;
  if (precondition != nil) fields[@"expected_revision"] = precondition[@"expected_store_revision"];
  if ([operation isEqual:@"apply"]) fields[@"now_ms"] = @((uint64_t)(NSDate.date.timeIntervalSince1970 * 1000));
  // Descriptor resolution above takes the workspace lock internally. Acquire
  // the final guard afterwards and retain it until the Rust effect/receipt is
  // committed, so rebinding cannot race the trusted context.
  __attribute__((objc_precise_lifetime)) DSHLocalWorkspaceAuthorityMutationGuard *guard =
      [self.rootResolver acquireAuthorityMutationGuardForFrozenRoot:request[@"root"] error:error];
  if (guard == nil || ![self.rootResolver validateFrozenRoot:request[@"root"]
      authorityMutationGuard:guard error:error]) return nil;
  return [self invokeStore:fields error:error];
}

- (NSDictionary *)prepareToolNamed:(NSString *)name arguments:(NSDictionary *)arguments
                      conversation:(NSDictionary *)conversation request:(NSDictionary *)request
                   registryVersion:(NSNumber *)registryVersion error:(NSError **)error {
  NSDictionary *condition = [self callStore:@"prepare" name:name arguments:arguments conversation:conversation
      request:request locator:nil precondition:nil registryVersion:registryVersion error:error];
  return condition == nil ? nil : @{@"schema_version":@1, @"precondition":condition,
      @"reserved_write_bytes":@0};
}

- (NSDictionary *)executeToolNamed:(NSString *)name arguments:(NSDictionary *)arguments
                      conversation:(NSDictionary *)conversation request:(NSDictionary *)request
                           locator:(NSDictionary *)locator precondition:(NSDictionary *)precondition
                   registryVersion:(NSNumber *)registryVersion error:(NSError **)error {
  return [self callStore:@"apply" name:name arguments:arguments conversation:conversation
      request:request locator:locator precondition:precondition registryVersion:registryVersion error:error];
}

- (NSDictionary *)recoverToolNamed:(NSString *)name arguments:(NSDictionary *)arguments
                      conversation:(NSDictionary *)conversation request:(NSDictionary *)request
                           locator:(NSDictionary *)locator precondition:(NSDictionary *)precondition
                   registryVersion:(NSNumber *)registryVersion error:(NSError **)error {
  id effect = [self callStore:@"recover" name:name arguments:arguments conversation:conversation
      request:request locator:locator precondition:precondition registryVersion:registryVersion error:error];
  if (effect == nil) return nil;
  return [effect isKindOfClass:NSDictionary.class] ? @{@"status":@"settled", @"effect":effect}
      : @{@"status":@"not_dispatched"};
}

@end
