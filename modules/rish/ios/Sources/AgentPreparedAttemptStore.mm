#import "AgentPreparedAttemptStore.h"
#import "RishHarnessCatalog.h"
#import "AssistantTaskExecutor.h"

#import "DSHWorkspaceCanonical.h"

#include "rish_agent_core.h"

// Every decision of this store lives in the shared core (modules/rish/core,
// `rish_agent_prepared_attempt_reduce`): the request shape, the
// committed-session relation with its visible-history digest, the observed
// safe values and conflict result, the projections, and the whole prepare
// transaction as a change set. This side owns the session load, the root
// resolver, the tool registry, the workspace authority guard and the WAL
// transaction, and hands the core what it observed.

static void DSHSetPreparedError(NSError **error,
                                DSHAgentNativeStoreErrorCode code) {
  if (error != nullptr) *error = DSHAgentNativeStoreError(code);
}

static id DSHPreparedValue(id value) {
  return value ?: NSNull.null;
}

static NSDictionary *DSHPreparedReduce(NSString *op,
                                       NSDictionary *fields,
                                       NSData *sessionJSON,
                                       NSError **error) {
  NSMutableDictionary *envelope = [fields mutableCopy];
  envelope[@"op"] = op;
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:envelope options:0 error:nil];
  if (bytes == nil) {
    DSHSetPreparedError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  char *raw = rish_agent_prepared_attempt_reduce(
      (const char *)bytes.bytes, bytes.length,
      (const uint8_t *)sessionJSON.bytes, sessionJSON.length);
  if (raw == NULL) {
    DSHSetPreparedError(error, DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  NSData *replyBytes = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  id reply = [NSJSONSerialization JSONObjectWithData:replyBytes options:0 error:nil];
  if (![reply isKindOfClass:NSDictionary.class]) {
    DSHSetPreparedError(error, DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  if (![reply[@"ok"] isEqual:@YES]) {
    NSInteger code = [reply[@"error"] isKindOfClass:NSNumber.class]
        ? [reply[@"error"] integerValue] : DSHAgentNativeStoreErrorCorrupt;
    if (code < DSHAgentNativeStoreErrorInvalidArgument ||
        code > DSHAgentNativeStoreErrorPersistence) {
      code = DSHAgentNativeStoreErrorCorrupt;
    }
    DSHSetPreparedError(error, (DSHAgentNativeStoreErrorCode)code);
    return nil;
  }
  return reply;
}

// The committed session's conversation for the request, and the snapshot
// the load reported. `conversationOut` stays nil when the load is not a
// present schema-9 snapshot or the conversation is absent.
static BOOL DSHPreparedLoadConversation(NSDictionary *load,
                                        NSDictionary *request,
                                        NSDictionary **conversationOut) {
  if (conversationOut != nullptr) *conversationOut = nil;
  if (![load[@"session_json"] isKindOfClass:NSString.class]) return NO;
  NSData *sessionJSON = [load[@"session_json"] dataUsingEncoding:NSUTF8StringEncoding];
  if (sessionJSON.length == 0) return NO;
  NSDictionary *reply = DSHPreparedReduce(
      @"session", @{ @"request" : request }, sessionJSON, nullptr);
  if (reply == nil) return NO;
  id conversation = reply[@"conversation"];
  if ([conversation isKindOfClass:NSDictionary.class] && conversationOut != nullptr) {
    *conversationOut = conversation;
  }
  return YES;
}

static NSDictionary *DSHPreparedObserved(NSDictionary *request,
                                         NSDictionary *load,
                                         NSDictionary *conversation) {
  NSDictionary *reply = DSHPreparedReduce(@"observed", @{
    @"request" : request,
    @"snapshot" : DSHPreparedValue([load[@"snapshot"] isKindOfClass:NSDictionary.class]
                                       ? load[@"snapshot"] : nil),
    @"conversation" : DSHPreparedValue(conversation),
  }, nil, nullptr);
  return reply[@"observed"];
}

static NSDictionary *DSHPreparedConflict(NSDictionary *request,
                                         NSString *failureCode,
                                         NSDictionary *observed) {
  NSDictionary *reply = DSHPreparedReduce(@"conflict", @{
    @"request" : request, @"failure_code" : failureCode,
    @"observed" : DSHPreparedValue(observed) ,
  }, nil, nullptr);
  return reply[@"result"];
}

@interface DSHAgentPreparedAttemptStore ()
@property(nonatomic, strong, readwrite) DSHAgentNativeWAL *wal;
@property(nonatomic, strong, readwrite) DSHAgentRootResolver *rootResolver;
@property(nonatomic, strong, readwrite) DSHAgentToolRegistry *toolRegistry;
@property(nonatomic, strong, readwrite) DSHSessionSnapshotStore *sessionSnapshotStore;
@property(nonatomic, strong, readwrite) DSHAgentTranscriptStore *transcriptStore;
@property(nonatomic, strong, readwrite) DSHAssistantTaskExecutor *assistantTaskExecutor;
@end

@implementation DSHAgentPreparedAttemptStore

- (instancetype)initWithWAL:(DSHAgentNativeWAL *)wal
              rootResolver:(DSHAgentRootResolver *)rootResolver
        sessionSnapshotStore:(DSHSessionSnapshotStore *)sessionSnapshotStore
             transcriptStore:(DSHAgentTranscriptStore *)transcriptStore {
  self = [super init];
  if (self != nil) {
    _wal = wal;
    _rootResolver = rootResolver;
    _toolRegistry = [[DSHAgentToolRegistry alloc] init];
    _sessionSnapshotStore = sessionSnapshotStore;
    _transcriptStore = transcriptStore ?: [[DSHAgentTranscriptStore alloc]
        initWithWAL:wal];
    _assistantTaskExecutor = [[DSHAssistantTaskExecutor alloc] initWithRootResolver:rootResolver];
  }
  return self;
}

- (nullable NSDictionary *)prepareAgentAttemptWithRequest:(NSDictionary *)request
                                                    error:(NSError **)error {
  if (!DSHAgentIsImmutableFoundationJSON(request)) {
    DSHSetPreparedError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  NSDictionary *shape = DSHPreparedReduce(@"request", @{
    @"request" : request,
    @"model_supported" : @([DSHHarnessSupportedModels() containsObject:request[@"model"]]),
    @"harness_id" : DSHPreparedValue(DSHHarnessIdForModel(request[@"model"])),
  }, nil, nullptr);
  if (shape == nil) {
    if (error != nullptr && *error == nil) {
      DSHSetPreparedError(error, DSHAgentNativeStoreErrorInvalidArgument);
    }
    return nil;
  }
  NSDictionary *checkpoint = request[@"committed_checkpoint"];
  if (![shape[@"checkpoint_relation"] isEqual:@YES]) {
    // The controller CAS is a complete assertion over the Store checkpoint;
    // treating a disagreement as a normal malformed request would make it
    // impossible for a caller to recover with the closed conflict union.
    NSDictionary *casLoad = [self.sessionSnapshotStore
        loadSessionSnapshotWithError:nullptr];
    NSDictionary *casConversation = nil;
    DSHPreparedLoadConversation(casLoad, request, &casConversation);
    if (error != nullptr) *error = nil;
    return DSHPreparedConflict(request, @"E_AGENT_CONFLICT",
                               DSHPreparedObserved(request, casLoad, casConversation));
  }
  NSError *sessionError = nil;
  NSDictionary *load = [self.sessionSnapshotStore loadSessionSnapshotWithError:
      &sessionError];
  if (![load[@"status"] isEqualToString:@"present"] ||
      ![load[@"snapshot"] isKindOfClass:NSDictionary.class]) {
    // Missing, legacy, or protected storage is not an observed checkpoint
    // mismatch; it remains a stable transcript/native failure.
    if (error != nullptr) *error = sessionError ?: DSHAgentNativeStoreError(
        DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  NSDictionary *loadedSnapshot = load[@"snapshot"];
  NSDictionary *conversation = nil;
  BOOL sessionParsed = DSHPreparedLoadConversation(load, request, &conversation);
  if (![loadedSnapshot[@"generation"] isEqual:checkpoint[@"session_generation"]] ||
      ![loadedSnapshot[@"session_sha256"] isEqual:checkpoint[@"session_sha256"]]) {
    if (error != nullptr) *error = nil;
    return DSHPreparedConflict(request, @"E_AGENT_CONFLICT",
                               DSHPreparedObserved(request, load, conversation));
  }
  if (![loadedSnapshot[@"schema_version"] isEqual:@1] || !sessionParsed) {
    DSHSetPreparedError(error, sessionParsed
        ? DSHAgentNativeStoreErrorConflict : DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  NSDictionary *observed = DSHPreparedObserved(request, load, conversation);
  NSDictionary *matches = DSHPreparedReduce(@"session_matches", @{
    @"request" : request, @"conversation" : DSHPreparedValue(conversation),
  }, nil, nullptr);
  if (![matches[@"matches"] isEqual:@YES]) {
    if (error != nullptr) *error = nil;
    return DSHPreparedConflict(request, @"E_AGENT_CONFLICT", observed);
  }
  // Registry v5 is an app-private assistant capability. A request flag or a
  // forged conversation identifier is insufficient: compare the committed
  // conversation with the durable Rust AssistantStore before exposure.
  NSDictionary *assistantContext = nil;
  if ([request[@"registry_version"] isEqual:@5]) {
    assistantContext = [self.assistantTaskExecutor assistantContextForConversation:conversation
        registryVersion:request[@"registry_version"] error:nil];
    if (assistantContext == nil) {
      if (error != nullptr) *error = nil;
      return DSHPreparedConflict(request, @"E_AGENT_CONFLICT", observed);
    }
  }
  NSString *workspaceId = request[@"workspace_id"] == NSNull.null
      ? nil : request[@"workspace_id"];
  NSString *projectId = request[@"project_id"] == NSNull.null
      ? nil : request[@"project_id"];
  NSNumber *revision = request[@"workspace_binding_revision"] == NSNull.null
      ? nil : request[@"workspace_binding_revision"];

  NSError *rootError = nil;
  NSDictionary *root = [self.rootResolver resolveRootForWorkspaceId:workspaceId
                                                            projectId:projectId
                                                      bindingRevision:revision
                                                                error:&rootError];
  if (root == nil && (workspaceId != nil || projectId != nil || revision != nil)) {
    if (error != nullptr) *error = nil;
    return DSHPreparedConflict(request, @"E_AGENT_ROOT_STALE", observed);
  }

  NSError *registryError = nil;
  NSDictionary *registry = root == nil
      ? @{ @"schema_version" : @2, @"registry_version" : @2,
           @"toolset_sha256" : self.toolRegistry.toolsetSHA256, @"tools" : @[] }
      : [self.toolRegistry registryForRoot:root version:request[@"registry_version"] error:&registryError];
  NSDictionary *policy = root == nil
      ? nil : [self.toolRegistry policyForRoot:root error:&registryError];
  if ((root != nil && (registry == nil || policy == nil)) ||
      !DSHAgentCanonicalSHA256(registry[@"toolset_sha256"])) {
    if (error != nullptr) *error = nil;
    return DSHPreparedConflict(request, @"E_AGENT_CONFLICT", observed);
  }
  NSError *requestError = nil;
  NSString *requestSHA = DSHAgentHJ(@"agent-operation-request", @{
    @"operation_kind" : @"prepare_agent_attempt",
    @"request" : request,
  }, &requestError);
  if (requestSHA == nil) {
    if (error != nullptr) *error = requestError;
    return nil;
  }

  // Hold the existing workspace authority lock for the final proof and for
  // the entire WAL transaction.  The WAL lock alone cannot exclude a
  // concurrent workspace rebind; this guard is deliberately kept alive with
  // precise ARC lifetime until after performAtomicTransaction returns.
  __attribute__((objc_precise_lifetime))
  DSHLocalWorkspaceAuthorityMutationGuard *authorityGuard = nil;
  if (root != nil) {
    NSError *authorityGuardError = nil;
    authorityGuard = [self.rootResolver
        acquireAuthorityMutationGuardForFrozenRoot:root
                                             error:&authorityGuardError];
    if (authorityGuard == nil ||
        ![self.rootResolver validateFrozenRoot:root
                         authorityMutationGuard:authorityGuard
                                          error:&authorityGuardError]) {
      if (error != nullptr) *error = nil;
      return DSHPreparedConflict(request, @"E_AGENT_ROOT_STALE", observed);
    }
  }

  __block NSDictionary *publicResult = nil;
  __block BOOL conflicted = NO;
  NSError *transactionError = nil;
  BOOL transaction = [self.wal performAtomicTransaction:^BOOL(
      NSMutableDictionary *state, NSError **mutationError) {
    NSMutableArray *operations = [state[@"operations"] mutableCopy];
    NSMutableArray *operationResults = [state[@"operation_results"] mutableCopy];
    NSMutableArray *authorities = [state[@"authorities"] mutableCopy];
    NSMutableArray *transcripts = [state[@"transcripts"] mutableCopy];
    if (operations == nil || operationResults == nil || authorities == nil ||
        transcripts == nil) {
      DSHSetPreparedError(mutationError, DSHAgentNativeStoreErrorCorrupt);
      return NO;
    }
    // Fresh transcript identities and clock readings are host facts; the
    // core picks the first unused candidate exactly as the native row
    // builder did.
    NSMutableArray<NSString *> *transcriptRefs = [NSMutableArray array];
    for (NSUInteger index = 0; index < 16; index += 1) {
      [transcriptRefs addObject:NSUUID.UUID.UUIDString.lowercaseString];
    }
    // Four readings in the order the native row builders took them:
    // transcript row, authority created_at, authority updated_at, snapshot.
    NSArray *timestamps = @[
      [self.wal currentTimestamp], [self.wal currentTimestamp],
      [self.wal currentTimestamp], [self.wal currentTimestamp],
    ];
    NSError *reduceError = nil;
    NSMutableDictionary *facts = [@{
      @"request" : request,
      @"request_sha256" : requestSHA,
      @"root" : DSHPreparedValue(root),
      @"policy" : DSHPreparedValue(policy),
      @"registry" : registry,
      @"toolset_sha256" : DSHPreparedValue(registry[@"toolset_sha256"]),
      @"operations" : operations,
      @"operation_results" : operationResults,
      @"authorities" : authorities,
      @"transcripts" : transcripts,
      @"transcript_refs" : transcriptRefs,
      @"timestamps" : timestamps,
    } mutableCopy];
    if (assistantContext != nil) facts[@"assistant_context"] = assistantContext;
    NSDictionary *outcome = DSHPreparedReduce(@"transaction", facts, nil, &reduceError);
    if (outcome == nil) {
      if (mutationError != nullptr) *mutationError = reduceError;
      if (reduceError.code == DSHAgentNativeStoreErrorConflict) conflicted = YES;
      return NO;
    }
    NSString *kind = outcome[@"outcome"];
    if ([kind isEqualToString:@"conflict"]) {
      conflicted = YES;
      DSHSetPreparedError(mutationError, DSHAgentNativeStoreErrorConflict);
      return NO;
    }
    if ([kind isEqualToString:@"replay"]) {
      publicResult = outcome[@"result"];
      // A replay publishes the stored result without changing the state.
      return NO;
    }
    // Retiring a model cannot invalidate an already stored operation result.
    // Only a fresh preparation requires a currently enabled provider model.
    if (!DSHHarnessModelIsExecutable(request[@"model"])) {
      DSHSetPreparedError(mutationError, DSHAgentNativeStoreErrorInvalidArgument);
      return NO;
    }
    if (![kind isEqualToString:@"commit"] ||
        ![outcome[@"operation"] isKindOfClass:NSDictionary.class] ||
        ![outcome[@"operation_result"] isKindOfClass:NSDictionary.class] ||
        ![outcome[@"result"] isKindOfClass:NSDictionary.class]) {
      DSHSetPreparedError(mutationError, DSHAgentNativeStoreErrorCorrupt);
      return NO;
    }
    if ([outcome[@"transcript"] isKindOfClass:NSDictionary.class]) {
      [transcripts addObject:outcome[@"transcript"]];
    }
    if ([outcome[@"authority"] isKindOfClass:NSDictionary.class]) {
      [authorities addObject:outcome[@"authority"]];
    }
    [operations addObject:outcome[@"operation"]];
    [operationResults addObject:outcome[@"operation_result"]];
    state[@"operations"] = operations;
    state[@"operation_results"] = operationResults;
    state[@"authorities"] = authorities;
    state[@"transcripts"] = transcripts;
    publicResult = outcome[@"result"];
    return YES;
  } error:&transactionError];
  // Keep the precise-lifetime guard live through result publication as well;
  // this statement also documents that the WAL transaction ran under it.
  (void)authorityGuard;
  if (!transaction && publicResult == nil) {
    if (conflicted || transactionError.code == DSHAgentNativeStoreErrorConflict) {
      if (error != nullptr) *error = nil;
      return DSHPreparedConflict(request, @"E_AGENT_CONFLICT", observed);
    }
    if (error != nullptr) *error = transactionError ?: DSHAgentNativeStoreError(
        DSHAgentNativeStoreErrorPersistence);
    return nil;
  }
  return publicResult;
}

- (nullable NSDictionary *)nativeAuthorityForTaskId:(NSString *)taskId
                                          attemptId:(NSString *)attemptId
                                              error:(NSError **)error {
  if (!DSHAgentCanonicalUUID(taskId) || !DSHAgentCanonicalUUID(attemptId)) {
    DSHSetPreparedError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  NSDictionary *state = [self.wal snapshotWithError:error];
  if (state == nil) return nil;
  for (NSDictionary *authority in state[@"authorities"]) {
    if ([authority[@"task_id"] isEqual:taskId] &&
        [authority[@"attempt_id"] isEqual:attemptId]) return authority;
  }
  DSHSetPreparedError(error, DSHAgentNativeStoreErrorNotFound);
  return nil;
}

- (nullable NSDictionary *)preparedAttemptForTaskId:(NSString *)taskId
                                          attemptId:(NSString *)attemptId
                                              error:(NSError **)error {
  NSDictionary *authority = [self nativeAuthorityForTaskId:taskId
                                                   attemptId:attemptId
                                                       error:error];
  if (authority == nil) return nil;
  NSDictionary *reply = DSHPreparedReduce(@"projection", @{
    @"request" : @{}, @"authority" : authority,
    @"controller_generation" : @0, @"journal_revision" : @0,
  }, nil, error);
  return reply[@"projection"];
}

- (BOOL)validatePreparedRoot:(NSDictionary *)root
                      taskId:(NSString *)taskId
                   attemptId:(NSString *)attemptId
                        error:(NSError **)error {
  if (!DSHAgentCanonicalUUID(taskId) || !DSHAgentCanonicalUUID(attemptId)) {
    DSHSetPreparedError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return NO;
  }
  NSDictionary *authority = [self nativeAuthorityForTaskId:taskId
                                                   attemptId:attemptId
                                                       error:error];
  if (authority == nil) return NO;
  if (![authority[@"root"] isEqual:root] ||
      ![self.rootResolver validateFrozenRoot:root error:error]) {
    DSHSetPreparedError(error, DSHAgentNativeStoreErrorOwnerLost);
    return NO;
  }
  return YES;
}

@end
