#import "RishGuestCgiFeature.h"
#import "AgentToolExecutionService.h"

#import "AgentExecutionLedger.h"
#import "AgentGitToolExecutor.h"
#import "AgentNativeWAL.h"
#import "AgentPreparedAttemptStore.h"
#import "AgentTranscriptStore.h"
#import "AgentWorkspaceToolExecutor.h"
#import "AssistantTaskExecutor.h"
#import "DSHAgentGuestCgiToolExecutor.h"
#import "DSHAgentRuntimeToolExecutor.h"
#import "AgentRuntimeToolContracts.h"
#import "SessionWorkspaceCoordinator.h"
#import "DSHGitPushSupport.h"

#include "rish_agent_core.h"

// Every decision of this service lives in the shared core
// (modules/rish/core, `rish_agent_tool_execution_reduce`): the request shape,
// the committed-session relation, the pre-execution checks over the WAL
// views, the ledger CAS and result shapes, the settlement of an executor's
// effect and the recovery settlement. This side owns the WAL operation
// relation, the session load, the root proofs, liveness, the executors and
// the ledger calls, and hands the core what it observed.

static NSDictionary *DSHAgentExecutionReduce(NSString *op,
                                             NSDictionary *fields,
                                             NSError **error) {
  NSMutableDictionary *envelope = [fields mutableCopy];
  envelope[@"op"] = op;
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:envelope options:0 error:nil];
  if (bytes == nil) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  char *raw = rish_agent_tool_execution_reduce((const char *)bytes.bytes, bytes.length);
  if (raw == NULL) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  NSData *replyBytes = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  id reply = [NSJSONSerialization JSONObjectWithData:replyBytes options:0 error:nil];
  if (![reply isKindOfClass:NSDictionary.class]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  if (![reply[@"ok"] isEqual:@YES]) {
    NSInteger code = [reply[@"error"] isKindOfClass:NSNumber.class]
        ? [reply[@"error"] integerValue] : DSHAgentNativeStoreErrorCorrupt;
    if (code < DSHAgentNativeStoreErrorInvalidArgument ||
        code > DSHAgentNativeStoreErrorPersistence) {
      code = DSHAgentNativeStoreErrorCorrupt;
    }
    DSHSetAgentNativeStoreError(error, (DSHAgentNativeStoreErrorCode)code);
    return nil;
  }
  return reply;
}

static id DSHAgentExecutionValue(id value) {
  return value ?: NSNull.null;
}

/// Stable in-memory key for the cancellation token of one execution row.
static NSString *DSHAgentExecutionLocatorKey(NSDictionary *locator) {
  if (![locator isKindOfClass:NSDictionary.class]) return @"";
  return [NSString stringWithFormat:@"%@|%@|%@|%@|%@|%@",
      locator[@"task_id"], locator[@"attempt_id"], locator[@"round_id"],
      locator[@"round_index"], locator[@"call_index"], locator[@"call_id"]];
}

// The committed session's conversation for the request when the loaded
// snapshot matches the request's checkpoint; nil otherwise.
static NSDictionary *DSHAgentExecutionCommittedConversation(
    DSHAgentPreparedAttemptStore *preparedStore,
    NSDictionary *request) {
  NSDictionary *loaded = [preparedStore.sessionSnapshotStore
      loadSessionSnapshotWithError:nil];
  NSDictionary *expected = request[@"committed_checkpoint"];
  if (![loaded[@"status"] isEqualToString:@"present"] ||
      ![loaded[@"snapshot"][@"generation"]
          isEqual:expected[@"session_generation"]] ||
      ![loaded[@"snapshot"][@"session_sha256"]
          isEqual:expected[@"session_sha256"]] ||
      ![loaded[@"session_json"] isKindOfClass:NSString.class]) {
    return nil;
  }
  NSData *bytes = [loaded[@"session_json"] dataUsingEncoding:NSUTF8StringEncoding];
  id session = bytes == nil ? nil
      : [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
  if (![session isKindOfClass:NSDictionary.class]) return nil;
  for (NSDictionary *conversation in session[@"conversations"]) {
    if (![conversation isKindOfClass:NSDictionary.class]) continue;
    if ([(conversation[@"id"] ?: conversation[@"conversation_id"])
            isEqual:request[@"conversation_id"]]) {
      return conversation;
    }
  }
  return nil;
}

// `DSHAgentExecutionValidateCommittedSession`: the core's relation check
// over the committed conversation. Sets Conflict on failure like before.
static BOOL DSHAgentExecutionValidateCommittedSession(
    DSHAgentPreparedAttemptStore *preparedStore,
    NSDictionary *request,
    BOOL requireExecutionIntent,
    NSError **error) {
  NSDictionary *conversation =
      DSHAgentExecutionCommittedConversation(preparedStore, request);
  NSDictionary *reply = DSHAgentExecutionReduce(@"session_matches", @{
    @"request" : request,
    @"conversation" : DSHAgentExecutionValue(conversation),
    @"require_execution_intent" : @(requireExecutionIntent),
  }, nil);
  if (![reply[@"matches"] isEqual:@YES]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorConflict);
    return NO;
  }
  return YES;
}

// Long runtime operations survive harmless session-generation changes, but
// never a selection/root change or replacement of the committed call intent.
static BOOL DSHAgentRuntimeCurrentBinding(DSHAgentPreparedAttemptStore *preparedStore,
    NSDictionary *request, BOOL executionIntentRequired) {
  NSDictionary *loaded = [preparedStore.sessionSnapshotStore loadSessionSnapshotWithError:nil];
  NSData *bytes = [loaded[@"session_json"] isKindOfClass:NSString.class]
      ? [loaded[@"session_json"] dataUsingEncoding:NSUTF8StringEncoding] : nil;
  NSDictionary *session = bytes ? [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil] : nil;
  if (![session isKindOfClass:NSDictionary.class] ||
      ![session[@"active_conversation_id"] isEqual:request[@"conversation_id"]]) return NO;
  for (NSDictionary *conversation in session[@"conversations"]) {
    if (![(conversation[@"id"] ?: conversation[@"conversation_id"]) isEqual:request[@"conversation_id"]]) continue;
    NSDictionary *binding = conversation[@"workspace_binding"], *root = request[@"root"];
    if (![binding isKindOfClass:NSDictionary.class] || ![binding[@"workspace_id"] isEqual:root[@"workspace_id"]] ||
        ![binding[@"binding_revision"] isEqual:root[@"workspace_binding_revision"]] ||
        ![binding[@"project_id"] isEqual:root[@"project_id"]]) return NO;
    if (!executionIntentRequired) return YES;
    return [DSHAgentExecutionReduce(@"session_matches", @{@"request":request, @"conversation":conversation,
        @"require_execution_intent":@YES}, nil)[@"matches"] isEqual:@YES];
  }
  return NO;
}

static NSDictionary *DSHAgentExecutionWrappedResult(NSDictionary *result) {
  return @{ @"schema_version" : @2, @"result_kind" : @"execute_agent_tool",
            @"result" : result };
}

// Commits a core-built conflict result and returns it.
static NSDictionary *DSHAgentExecutionCommitConflict(
    DSHAgentNativeWAL *wal,
    NSDictionary *request,
    NSDictionary *started,
    NSDictionary *conflict,
    NSError **error) {
  if (![conflict isKindOfClass:NSDictionary.class]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  if (error != nullptr) *error = nil;
  NSDictionary *commit = DSHAgentNativeWALCommitOperation(
      wal, request[@"operation_id"], started[@"request_sha256"],
      request[@"task_id"], request[@"attempt_id"], @"conflict", @"conflict",
      @{ @"schema_version" : @2, @"kind" : @"none" }, nil,
      DSHAgentExecutionWrappedResult(conflict), error);
  return commit == nil ? nil : commit[@"result"][@"result"];
}

// Builds and commits the conflict for `failureCode` against `row`.
static NSDictionary *DSHAgentExecutionConflict(
    DSHAgentNativeWAL *wal,
    NSDictionary *request,
    NSDictionary *started,
    NSDictionary *row,
    NSString *failureCode,
    NSError **error) {
  NSDictionary *reply = DSHAgentExecutionReduce(@"conflict", @{
    @"request" : request, @"row" : DSHAgentExecutionValue(row),
    @"failure_code" : failureCode,
  }, error);
  if (reply == nil) return nil;
  return DSHAgentExecutionCommitConflict(wal, request, started, reply[@"result"], error);
}

static NSDictionary *DSHAgentExecutionActiveResult(
    NSDictionary *request,
    NSDictionary *row,
    NSString *status,
    BOOL effectMayHaveOccurred) {
  NSDictionary *reply = DSHAgentExecutionReduce(@"active_result", @{
    @"request" : request, @"row" : DSHAgentExecutionValue(row),
    @"status" : status ?: @"running",
    @"effect_may_have_occurred" : @(effectMayHaveOccurred),
  }, nil);
  return reply[@"result"];
}

static NSDictionary *DSHAgentExecutionHistoricalResult(
    DSHAgentNativeWAL *wal,
    NSDictionary *request,
    BOOL *terminalOut,
    NSError **error) {
  if (terminalOut != nullptr) *terminalOut = NO;
  NSString *requestSHA = DSHAgentHJ(@"agent-operation-request", @{
    @"operation_kind" : @"execute_agent_tool", @"request" : request,
  }, error);
  if (requestSHA == nil) return nil;
  NSDictionary *query = DSHAgentNativeWALQueryOperation(
      wal, request[@"operation_id"], requestSHA, request[@"task_id"],
      request[@"attempt_id"], error);
  if ([query[@"status"] isEqualToString:@"not_started"] ||
      ([query[@"status"] isEqualToString:@"found"] &&
       [query[@"record"][@"state"] isEqualToString:@"started"])) return nil;
  if (![query[@"status"] isEqualToString:@"found"]) {
    if (terminalOut != nullptr) *terminalOut = YES;
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorConflict);
    return nil;
  }
  NSDictionary *state = [wal snapshotWithError:error];
  for (NSDictionary *snapshot in state[@"operation_results"]) {
    if ([snapshot[@"operation_id"] isEqual:request[@"operation_id"]] &&
        [snapshot[@"operation_kind"] isEqualToString:@"execute_agent_tool"]) {
      if (terminalOut != nullptr) *terminalOut = YES;
      return snapshot[@"result"][@"result"];
    }
  }
  if (terminalOut != nullptr) *terminalOut = YES;
  DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
  return nil;
}

@interface DSHAgentToolExecutionService ()
@property(nonatomic, strong) DSHAgentNativeWAL *wal;
@property(nonatomic, strong) DSHAgentExecutionLedger *ledger;
@property(nonatomic, strong) DSHAgentPreparedAttemptStore *preparedStore;
@property(nonatomic, strong) DSHAgentTranscriptStore *transcripts;
@property(nonatomic, strong) DSHAgentWorkspaceToolExecutor *workspaceExecutor;
@property(nonatomic, strong) DSHAgentGitToolExecutor *gitExecutor;
@property(nonatomic, strong) NSMutableDictionary<NSString *, DSHGitPushCancelToken *> *pushCancelTokens;
@end

@implementation DSHAgentToolExecutionService

- (instancetype)initWithWAL:(DSHAgentNativeWAL *)wal
                      ledger:(DSHAgentExecutionLedger *)ledger
               preparedStore:(DSHAgentPreparedAttemptStore *)preparedStore
                 transcripts:(DSHAgentTranscriptStore *)transcripts
           workspaceExecutor:(DSHAgentWorkspaceToolExecutor *)workspaceExecutor
                 gitExecutor:(DSHAgentGitToolExecutor *)gitExecutor {
  self = [super init];
  if (self) {
    _wal = wal;
    _ledger = ledger;
    _preparedStore = preparedStore;
    _transcripts = transcripts;
    _workspaceExecutor = workspaceExecutor;
    _gitExecutor = gitExecutor;
    _pushCancelTokens = [NSMutableDictionary dictionary];
  }
  return self;
}

- (BOOL)validateExecuteRequest:(NSDictionary *)request error:(NSError **)error {
  if (![request isKindOfClass:NSDictionary.class]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return NO;
  }
  return DSHAgentExecutionReduce(@"request", @{ @"request" : request }, error) != nil;
}

- (NSDictionary *)executionRowInState:(NSDictionary *)state
                              request:(NSDictionary *)request {
  NSDictionary *reply = DSHAgentExecutionReduce(@"row", @{
    @"request" : request, @"ledger" : DSHAgentExecutionValue(state[@"ledger"]),
  }, nil);
  return [reply[@"row"] isKindOfClass:NSDictionary.class] ? reply[@"row"] : nil;
}

- (NSArray *)nativeMessagesForRequest:(NSDictionary *)request error:(NSError **)error {
  return [self.transcripts nativeMessagesForTranscriptWithRequest:@{
    @"schema_version" : @1, @"attempt_id" : request[@"attempt_id"],
    @"root" : request[@"root"], @"transcript" : request[@"transcript"],
  } error:error];
}

- (NSDictionary *)beginAgentToolWithRequest:(NSDictionary *)request
                                         error:(NSError **)error {
  if (![self validateExecuteRequest:request error:error]) return nil;
  BOOL historicalTerminal = NO;
  NSDictionary *historical = DSHAgentExecutionHistoricalResult(
      self.wal, request, &historicalTerminal, error);
  if (historicalTerminal) {
    if (historical && DSHAgentIsRuntimeTool(request[@"name"]))
      [[DSHAgentRuntimeToolExecutor existingExecutorForWorkspaceExecutor:self.workspaceExecutor] acknowledgeSettlementOwner:request];
    return historical;
  }
  NSDictionary *state = [self.wal snapshotWithError:error];
  if (state == nil) return nil;
  NSDictionary *authority = nil;
  for (NSDictionary *candidate in state[@"authorities"]) {
    if ([candidate[@"task_id"] isEqual:request[@"task_id"]] &&
        [candidate[@"attempt_id"] isEqual:request[@"attempt_id"]]) {
      authority = candidate;
      break;
    }
  }
  NSDictionary *row = [self executionRowInState:state request:request];
  if ([request[@"name"] isEqual:@"ask_user"] &&
      DSHAgentExecutionReduce(@"question_response", @{@"request":request,
        @"row":row ?: NSNull.null}, error) == nil) return nil;
  // A same-operation replay must use the authority revision frozen on the
  // durable operation record. The first execution may legitimately advance
  // the live authority while claiming its native owner; using that newer
  // revision here would make an exact lost-response replay conflict with its
  // own started record. StartOperation still verifies the complete request
  // digest, task, attempt, kind, and stored revision.
  NSNumber *operationAuthorityRevision = authority[@"authority_revision"] ?: @0;
  for (NSDictionary *operation in state[@"operations"]) {
    if ([operation[@"operation_id"] isEqual:request[@"operation_id"]]) {
      operationAuthorityRevision = operation[@"authority_revision"];
      break;
    }
  }
  NSDictionary *started = DSHAgentNativeWALStartOperation(
      self.wal, @"execute_agent_tool", request, request[@"task_id"],
      request[@"attempt_id"], operationAuthorityRevision, error);
  if (started == nil) return nil;
  if ([started[@"status"] isEqualToString:@"replayed"] &&
      started[@"result"] != NSNull.null) return started[@"result"][@"result"];
  NSDictionary *conversation =
      DSHAgentExecutionCommittedConversation(self.preparedStore, request);
  BOOL rootValid = conversation != nil &&
      [self.preparedStore validatePreparedRoot:request[@"root"]
                                        taskId:request[@"task_id"]
                                     attemptId:request[@"attempt_id"]
                                          error:nullptr];
  NSString *dispatch = nil;
  BOOL ownerAlive = NO;
  if ([row[@"state"] isEqualToString:@"running"] ||
      [row[@"state"] isEqualToString:@"cancel_requested"]) {
    dispatch = [self.wal dispatchStateForKind:@"execution"
                                       locator:row[@"locator"] error:nil];
    NSDictionary *owner = row[@"owner"];
    ownerAlive = [owner isKindOfClass:NSDictionary.class] &&
        [self.wal isNativeTaskAlive:owner[@"native_task_id"]
                            launchId:owner[@"launch_id"]];
  }
  NSDictionary *precheck = DSHAgentExecutionReduce(@"precheck", @{
    @"request" : request,
    @"authority" : DSHAgentExecutionValue(authority),
    @"batches" : DSHAgentExecutionValue(state[@"batches"]),
    @"ledger" : DSHAgentExecutionValue(state[@"ledger"]),
    @"operation_results" : DSHAgentExecutionValue(state[@"operation_results"]),
    @"conversation" : DSHAgentExecutionValue(conversation),
    @"root_ok" : @(rootValid),
    @"dispatch_state" : DSHAgentExecutionValue(dispatch),
    @"owner_alive" : @(ownerAlive),
  }, error);
  if (precheck == nil) return nil;
  if (precheck[@"conflict"] != nil) {
    return DSHAgentExecutionCommitConflict(
        self.wal, request, started, precheck[@"conflict"], error);
  }
  if ([precheck[@"commit"] isKindOfClass:NSDictionary.class]) {
    NSDictionary *replay = precheck[@"commit"];
    NSDictionary *result = replay[@"result"];
    NSDictionary *commit = DSHAgentNativeWALCommitOperation(
        self.wal, request[@"operation_id"], started[@"request_sha256"],
        request[@"task_id"], request[@"attempt_id"], @"committed",
        result[@"status"], replay[@"result_ref"], replay[@"revision"],
        DSHAgentExecutionWrappedResult(result), error);
    return commit == nil ? nil : commit[@"result"][@"result"];
  }
  if ([precheck[@"result"] isKindOfClass:NSDictionary.class]) {
    return precheck[@"result"];
  }
  if (![precheck[@"proceed"] isEqual:@YES]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  NSArray *messages = [self nativeMessagesForRequest:request error:error];
  NSDictionary *parsed = DSHAgentExecutionReduce(@"arguments", @{
    @"request" : request, @"messages" : DSHAgentExecutionValue(messages),
  }, error);
  NSDictionary *arguments = [parsed[@"arguments"] isKindOfClass:NSDictionary.class]
      ? parsed[@"arguments"] : nil;
  if (arguments == nil) {
    return DSHAgentExecutionConflict(
        self.wal, request, started, row, @"E_AGENT_TRANSCRIPT", error);
  }
  if (!DSHAgentExecutionValidateCommittedSession(
          self.preparedStore, request, YES, error)) {
    return DSHAgentExecutionConflict(
        self.wal, request, started, row, @"E_AGENT_CONFLICT", error);
  }
  if ([request[@"name"] isEqual:@"ask_user"]) {
    NSDictionary *plan = DSHAgentExecutionReduce(@"question_settlement", @{
      @"request":request, @"row":row, @"arguments":arguments,
      @"request_sha256":started[@"request_sha256"],
    }, error);
    if (plan == nil) return nil;
    // No native owner or running state: the answer, receipt and transcript
    // commit atomically. A lost response replays this same operation result.
    NSDictionary *settled = [self.ledger settleAgentExecutionWithCAS:plan[@"cas"]
      patch:plan[@"patch"] message:plan[@"message"] operation:plan[@"operation"] error:error];
    return settled[@"operation_result"];
  }
  NSDictionary *gateRequest = DSHAgentExecutionReduce(@"effect_gate", @{ @"request" : request }, error);
  if (gateRequest == nil) return nil;
  if ([gateRequest[@"needed"] isEqual:@YES]) {
    NSDictionary *gate = [self.ledger
        openAgentWriteBatchEffectGateWithRequest:gateRequest[@"request"] error:error];
    if (gate == nil) {
      return DSHAgentExecutionConflict(
          self.wal, request, started, row, @"E_AGENT_APPROVAL", error);
    }
  }
  NSString *nativeTaskID = NSUUID.UUID.UUIDString.lowercaseString;
  if (![self.wal registerNativeTaskId:nativeTaskID error:error]) return nil;
  NSDictionary *owner = @{
    @"schema_version" : @1, @"task_id" : request[@"task_id"],
    @"launch_id" : self.wal.launchId,
    @"native_task_id" : nativeTaskID, @"owner_generation" : @1,
    @"heartbeat_at" : [self.wal currentTimestamp],
  };
  NSDictionary *claimed = [self.ledger
      claimAgentExecutionWithLocator:row[@"locator"]
      expectedRowRevision:request[@"expected_execution_revision"]
      owner:owner error:error];
  row = claimed[@"row"];
  if (![claimed[@"ok"] boolValue] || row == nil ||
      ![row[@"state"] isEqualToString:@"running"] ||
      ![row[@"owner"] isEqual:owner]) {
    [self.wal unregisterNativeTaskId:nativeTaskID error:nil];
    if ([row[@"state"] isEqualToString:@"running"] ||
        [row[@"state"] isEqualToString:@"cancel_requested"]) {
      NSString *dispatchState = [self.wal dispatchStateForKind:@"execution"
                                                        locator:row[@"locator"] error:nil];
      return DSHAgentExecutionActiveResult(
          request, row, row[@"state"], [dispatchState isEqualToString:@"dispatched"]);
    }
    return DSHAgentExecutionConflict(
        self.wal, request, started, row, @"E_AGENT_CONFLICT", error);
  }
  NSDictionary *runningCAS = DSHAgentExecutionReduce(@"execution_cas", @{
    @"request" : request, @"row" : row, @"state" : @"running",
  }, error);
  if (runningCAS == nil) {
    [self.wal unregisterNativeTaskId:nativeTaskID error:nil];
    return nil;
  }
  NSDictionary *dispatched = [self.ledger markAgentExecutionDispatchedWithCAS:
      runningCAS[@"cas"] error:error];
  row = dispatched[@"row"];
  if (![dispatched[@"status"] isEqualToString:@"dispatched"] || row == nil) {
    [self.wal unregisterNativeTaskId:nativeTaskID error:nil];
    if (row != nil &&
        [[self.wal dispatchStateForKind:@"execution" locator:row[@"locator"]
                                  error:nil] isEqualToString:@"dispatched"]) {
      return DSHAgentExecutionActiveResult(request, row, row[@"state"], YES);
    }
    return DSHAgentExecutionConflict(
        self.wal, request, started, row, @"E_AGENT_CONFLICT", error);
  }
  if (DSHAgentIsRuntimeTool(request[@"name"])) {
    DSHAgentPreparedAttemptStore *prepared = self.preparedStore;
    BOOL registered = [[DSHAgentRuntimeToolExecutor executorForWorkspaceExecutor:self.workspaceExecutor]
        registerToolNamed:request[@"name"] arguments:arguments root:request[@"root"] owner:request
        precondition:row[@"precondition"] validator:^BOOL(BOOL execution) {
          return DSHAgentRuntimeCurrentBinding(prepared, request, execution);
        }];
    if (!registered) {
      [self.wal unregisterNativeTaskId:nativeTaskID error:nil];
      return DSHAgentExecutionConflict(self.wal, request, started, row, @"E_AGENT_CONFLICT", error);
    }
  }
  return @{@"_native_execution_context":@YES, @"request":request, @"arguments":arguments,
      @"row":row, @"started":started, @"native_task_id":nativeTaskID};
}

- (NSDictionary *)executeAgentToolWithRequest:(NSDictionary *)request error:(NSError **)error {
  __block NSDictionary *context = nil;
  BOOL beganOkay = [self.preparedStore.sessionSnapshotStore.coordinator performSyncWithError:^BOOL(NSError **inner) {
    context = [self beginAgentToolWithRequest:request error:inner];
    return context != nil;
  } error:error];
  if (!beganOkay || ![context[@"_native_execution_context"] isEqual:@YES]) return context;
  NSDictionary *arguments = context[@"arguments"], *row = context[@"row"];
  NSDate *began = NSDate.date;
  NSDictionary *effect = nil;
  if (DSHAgentIsAssistantTaskTool(request[@"name"])) {
    // Re-load under the session coordinator after approval/claim/dispatch.
    // The helper then holds the workspace proof across the Rust transaction.
    __block NSDictionary *assistantEffect = nil;
    NSError *assistantError = nil;
    [self.preparedStore.sessionSnapshotStore.coordinator performSyncWithError:^BOOL(NSError **inner) {
      NSDictionary *conversation = DSHAgentExecutionCommittedConversation(self.preparedStore, request);
      NSDictionary *authority = [self.preparedStore nativeAuthorityForTaskId:request[@"task_id"]
          attemptId:request[@"attempt_id"] error:inner];
      if (conversation == nil || ![self.preparedStore validatePreparedRoot:request[@"root"]
          taskId:request[@"task_id"] attemptId:request[@"attempt_id"] error:inner]) return NO;
      assistantEffect = [self.preparedStore.assistantTaskExecutor executeToolNamed:request[@"name"]
          arguments:arguments conversation:conversation request:request locator:row[@"locator"]
          precondition:row[@"precondition"] registryVersion:authority[@"registry"][@"registry_version"]
          error:inner];
      return assistantEffect != nil;
    } error:&assistantError];
    effect = assistantEffect;
    if (effect == nil) {
      BOOL noEffect = [assistantError.domain isEqual:DSHAgentNativeStoreErrorDomain] &&
          (assistantError.code == DSHAgentNativeStoreErrorInvalidArgument ||
           assistantError.code == DSHAgentNativeStoreErrorConflict ||
           assistantError.code == DSHAgentNativeStoreErrorNotFound ||
           assistantError.code == DSHAgentNativeStoreErrorCapacity ||
           assistantError.code == DSHAgentNativeStoreErrorOwnerLost);
      if (noEffect) {
        NSString *code = assistantError.code == DSHAgentNativeStoreErrorInvalidArgument
            ? @"E_AGENT_BAD_ARGUMENTS" : assistantError.code == DSHAgentNativeStoreErrorNotFound
            ? @"E_AGENT_NOT_FOUND" : @"E_AGENT_CONFLICT";
        effect = DSHAgentExecutionReduce(@"assistant_failure",
            @{@"request":request, @"failure_code":code}, nil)[@"effect"];
      } else {
        // An unavailable response does not prove that the atomic Rust task and
        // receipt transaction failed. Keep the dispatched row recoverable;
        // recovery must inspect that receipt before any terminal settlement.
        [self.wal unregisterNativeTaskId:context[@"native_task_id"] error:nil];
        if (error != nullptr) *error = nil;
        return DSHAgentExecutionActiveResult(request, row, @"ambiguous", YES);
      }
    }
  } else if ([request[@"name"] isEqualToString:@"list_dir"] ||
      [request[@"name"] isEqualToString:@"read_file"] ||
      [request[@"name"] isEqualToString:@"write_file"]) {
    effect = [self.workspaceExecutor executeToolNamed:request[@"name"]
                                             arguments:arguments
                                                  root:request[@"root"]
                                          precondition:row[@"precondition"]
                                                 error:error];
  } else if (DSHAgentIsRuntimeTool(request[@"name"])) {
    effect = [[DSHAgentRuntimeToolExecutor executorForWorkspaceExecutor:self.workspaceExecutor]
        executeToolNamed:request[@"name"] arguments:arguments root:request[@"root"] owner:request
        precondition:row[@"precondition"]];
  } else if ([request[@"name"] hasSuffix:@"_guest_cgi"]) {
#if DSH_GUEST_CGI_AVAILABLE
    effect = [[DSHAgentGuestCgiToolExecutor executorForWorkspaceExecutor:self.workspaceExecutor] executeSynchronouslyToolNamed:request[@"name"] arguments:arguments root:request[@"root"] owner:request precondition:row[@"precondition"]];
#endif
  } else {
    // git_push registers a cancellation token under the same locator identity
    // as the ledger row, so the coordinator's cancel path can interrupt the
    // bounded network phase cooperatively.
    DSHGitPushCancelToken *cancelToken = nil;
    NSString *locatorKey = nil;
    if ([request[@"name"] isEqualToString:@"git_push"]) {
      cancelToken = [[DSHGitPushCancelToken alloc] init];
      locatorKey = DSHAgentExecutionLocatorKey(row[@"locator"]);
      @synchronized (self) {
        self.pushCancelTokens[locatorKey] = cancelToken;
      }
    }
    effect = [self.gitExecutor executeToolNamed:request[@"name"]
                                      arguments:arguments
                                           root:request[@"root"]
                                   precondition:row[@"precondition"]
                                    cancelToken:cancelToken
                                           error:error];
    if (locatorKey != nil) {
      @synchronized (self) {
        if (self.pushCancelTokens[locatorKey] == cancelToken) {
          [self.pushCancelTokens removeObjectForKey:locatorKey];
        }
      }
    }
  }
  __block NSDictionary *result = nil;
  NSDictionary *finishedEffect = effect;
  [self.preparedStore.sessionSnapshotStore.coordinator performSyncWithError:^BOOL(NSError **inner) {
    result = [self finishAgentToolContext:context effect:finishedEffect began:began error:inner];
    return result != nil;
  } error:error];
  return result;
}

- (NSDictionary *)finishAgentToolContext:(NSDictionary *)context effect:(NSDictionary *)initialEffect
                                  began:(NSDate *)began error:(NSError **)error {
  NSDictionary *request = context[@"request"], *started = context[@"started"];
  NSDictionary *row = context[@"row"];
  NSString *nativeTaskID = context[@"native_task_id"];
  NSDictionary *effect = initialEffect;
  if (DSHAgentIsRuntimeTool(request[@"name"])) {
    NSDictionary *latest = [self executionRowInState:[self.wal snapshotWithError:nil] request:request];
    BOOL sameOwner = latest != nil && [latest[@"locator"] isEqual:row[@"locator"]];
    for (NSString *key in @[@"task_id", @"launch_id", @"native_task_id", @"owner_generation"])
      sameOwner &= [latest[@"owner"][key] isEqual:row[@"owner"][key]];
    if (!sameOwner) {
      [[DSHAgentRuntimeToolExecutor executorForWorkspaceExecutor:self.workspaceExecutor] cancelAttempt:request[@"attempt_id"]];
      [self.wal unregisterNativeTaskId:nativeTaskID error:nil];
      return DSHAgentExecutionActiveResult(request, latest ?: row, @"ambiguous", YES);
    }
    row = latest;
    if ([row[@"state"] isEqual:@"cancel_requested"]) {
      NSData *bytes = DSHAgentCanonicalJSON(@{@"schema_version":@1, @"name":request[@"name"],
          @"outcome":@"cancelled", @"payload":@{@"schema_version":@1, @"failure_code":@"E_AGENT_CANCELLED",
            @"reason":@"runtime_cancelled"}}, nil);
      effect = @{@"schema_version":@1, @"status":@"cancelled",
          @"feedback":[[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding],
          @"settled_facts":NSNull.null, @"truncated":@NO,
          @"effect_may_have_occurred":initialEffect[@"effect_may_have_occurred"] ?: @YES};
    }
  }
  if (([request[@"name"] hasSuffix:@"_guest_cgi"] || DSHAgentIsRuntimeTool(request[@"name"])) &&
      !(DSHAgentIsRuntimeTool(request[@"name"]) && [effect[@"status"] isEqual:@"cancelled"]) &&
      !(DSHAgentIsRuntimeTool(request[@"name"])
        ? DSHAgentRuntimeCurrentBinding(self.preparedStore, request, YES)
        : DSHAgentExecutionValidateCommittedSession(self.preparedStore, request, YES, nil))) {
    if (DSHAgentIsRuntimeTool(request[@"name"])) {
      [[DSHAgentRuntimeToolExecutor executorForWorkspaceExecutor:self.workspaceExecutor] cancelAttempt:request[@"attempt_id"]];
    } else [[DSHAgentGuestCgiToolExecutor executorForWorkspaceExecutor:self.workspaceExecutor] cancelAttempt:request[@"attempt_id"]];
    NSDictionary *ambiguous = DSHAgentExecutionReduce(@"ambiguous_effect", @{ @"request" : request }, nil);
    effect = ambiguous[@"effect"];
  }
  if (effect == nil) {
    if (error != nullptr) *error = nil;
    NSDictionary *failure = DSHAgentExecutionReduce(@"generic_failure", @{ @"request" : request }, error);
    effect = failure[@"effect"];
  }
  if (![effect isKindOfClass:NSDictionary.class]) {
    [self.wal unregisterNativeTaskId:nativeTaskID error:nil];
    return nil;
  }
  NSUInteger duration = (NSUInteger)(-1000.0 * [began timeIntervalSinceNow]);
  NSDictionary *plan = DSHAgentExecutionReduce(@"settlement", @{
    @"request" : request, @"row" : row, @"effect" : effect,
    @"request_sha256" : DSHAgentExecutionValue(started[@"request_sha256"]),
    @"duration_ms" : @(duration),
  }, error);
  if (plan == nil) {
    [self.wal unregisterNativeTaskId:nativeTaskID error:nil];
    return nil;
  }
  NSDictionary *settled = [self.ledger settleAgentExecutionWithCAS:plan[@"cas"]
                                                              patch:plan[@"patch"]
                                                            message:plan[@"message"]
                                                          operation:plan[@"operation"]
                                                              error:error];
  [self.wal unregisterNativeTaskId:nativeTaskID error:nil];
  NSDictionary *settledRow = settled[@"row"];
  if (settledRow == nil) {
    NSDictionary *failed = DSHAgentExecutionReduce(@"settle_failed", @{
      @"request" : request, @"row" : row, @"plan" : plan, @"effect" : effect,
    }, nil);
    return failed[@"result"];
  }
  NSDictionary *operationResult = settled[@"operation_result"];
  if (![operationResult isKindOfClass:NSDictionary.class]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  if (DSHAgentIsRuntimeTool(request[@"name"]))
    [[DSHAgentRuntimeToolExecutor existingExecutorForWorkspaceExecutor:self.workspaceExecutor] acknowledgeSettlementOwner:request];
  return operationResult;
}

- (NSDictionary *)recoverAgentToolWithRequest:(NSDictionary *)request
                                         error:(NSError **)error {
  if (![self validateExecuteRequest:request error:error]) return nil;
  BOOL historicalTerminal = NO;
  NSDictionary *historical = DSHAgentExecutionHistoricalResult(
      self.wal, request, &historicalTerminal, error);
  if (historicalTerminal) {
    if (historical && DSHAgentIsRuntimeTool(request[@"name"]))
      [[DSHAgentRuntimeToolExecutor existingExecutorForWorkspaceExecutor:self.workspaceExecutor] acknowledgeSettlementOwner:request];
    return historical;
  }
  if (!DSHAgentExecutionValidateCommittedSession(
          self.preparedStore, request, NO, error)) return nil;
  if (![self.preparedStore validatePreparedRoot:request[@"root"]
                                         taskId:request[@"task_id"]
                                      attemptId:request[@"attempt_id"]
                                           error:error]) return nil;
  NSDictionary *state = [self.wal snapshotWithError:error];
  NSDictionary *row = state == nil ? nil : [self executionRowInState:state request:request];
  if (row == nil) return @{ @"schema_version" : @2, @"status" : @"not_started" };
  if ([row[@"state"] isEqualToString:@"settled"] ||
      [row[@"state"] isEqualToString:@"cancelled"] ||
      [row[@"state"] isEqualToString:@"ambiguous"]) {
    NSDictionary *safe = DSHAgentExecutionReduce(@"safe_result", @{
      @"request" : request, @"row" : row,
    }, error);
    return safe[@"result"];
  }
  if ([request[@"name"] isEqual:@"ask_user"] && [row[@"state"] isEqual:@"intent"]) {
    return DSHAgentExecutionReduce(@"active_result", @{@"request":request, @"row":row,
      @"status":@"intent", @"effect_may_have_occurred":@NO}, error)[@"result"];
  }
  NSArray *messages = [self nativeMessagesForRequest:request error:error];
  NSDictionary *parsed = DSHAgentExecutionReduce(@"recover_arguments", @{
    @"request" : request, @"messages" : DSHAgentExecutionValue(messages),
  }, error);
  NSDictionary *arguments = [parsed[@"arguments"] isKindOfClass:NSDictionary.class]
      ? parsed[@"arguments"] : nil;
  if (arguments == nil) {
    if (error != nullptr && *error == nil) {
      DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    }
    return nil;
  }
  NSDictionary *recovered = nil;
  if (DSHAgentIsAssistantTaskTool(request[@"name"])) {
    __block NSDictionary *assistantRecovery = nil;
    [self.preparedStore.sessionSnapshotStore.coordinator performSyncWithError:^BOOL(NSError **inner) {
      NSDictionary *conversation = DSHAgentExecutionCommittedConversation(self.preparedStore, request);
      NSDictionary *authority = [self.preparedStore nativeAuthorityForTaskId:request[@"task_id"]
          attemptId:request[@"attempt_id"] error:inner];
      if (conversation == nil || ![self.preparedStore validatePreparedRoot:request[@"root"]
          taskId:request[@"task_id"] attemptId:request[@"attempt_id"] error:inner]) return NO;
      assistantRecovery = [self.preparedStore.assistantTaskExecutor recoverToolNamed:request[@"name"]
          arguments:arguments conversation:conversation request:request locator:row[@"locator"]
          precondition:row[@"precondition"] registryVersion:authority[@"registry"][@"registry_version"]
          error:inner];
      return assistantRecovery != nil;
    } error:error];
    recovered = assistantRecovery;
  } else if ([request[@"name"] isEqualToString:@"list_dir"] ||
      [request[@"name"] isEqualToString:@"read_file"] ||
      [request[@"name"] isEqualToString:@"write_file"]) {
    recovered = [self.workspaceExecutor recoverToolNamed:request[@"name"]
                                                 arguments:arguments
                                                      root:request[@"root"]
                                              precondition:row[@"precondition"]
                                                     error:error];
  } else if (DSHAgentIsRuntimeTool(request[@"name"])) {
    recovered = [[DSHAgentRuntimeToolExecutor executorForWorkspaceExecutor:self.workspaceExecutor]
        recoverToolNamed:request[@"name"] arguments:arguments root:request[@"root"] owner:request
        precondition:row[@"precondition"]];
  } else if ([request[@"name"] hasSuffix:@"_guest_cgi"]) {
    // Process-owned services are never replayed during recovery.
    recovered = @{ @"schema_version": @1, @"status": @"ambiguous" };
  } else {
    recovered = [self.gitExecutor recoverToolNamed:request[@"name"]
                                           arguments:arguments
                                                root:request[@"root"]
                                        precondition:row[@"precondition"]
                                               error:error];
  }
  if (recovered == nil) return nil;
  NSDictionary *plan = DSHAgentExecutionReduce(@"recover", @{
    @"request" : request, @"row" : row, @"recovered" : recovered,
  }, error);
  if (plan == nil) return nil;
  NSDictionary *settle = plan[@"settle"];
  if ([settle isKindOfClass:NSDictionary.class]) {
    NSDictionary *settled = [self.ledger settleAgentExecutionWithCAS:settle[@"cas"]
                                                                patch:settle[@"patch"]
                                                              message:settle[@"message"]
                                                            operation:settle[@"operation"]
                                                                error:error];
    if (settled[@"row"] == nil) return nil;
    if ([settled[@"operation_result"] isKindOfClass:NSDictionary.class] && DSHAgentIsRuntimeTool(request[@"name"]))
      [[DSHAgentRuntimeToolExecutor existingExecutorForWorkspaceExecutor:self.workspaceExecutor] acknowledgeSettlementOwner:request];
    return settled[@"operation_result"];
  }
  return plan[@"result"];
}

- (void)requestCancelForExecutionLocator:(NSDictionary *)locator {
  if (![locator isKindOfClass:NSDictionary.class]) return;
  NSString *locatorKey = DSHAgentExecutionLocatorKey(locator);
  DSHGitPushCancelToken *token = nil;
  @synchronized (self) {
    token = self.pushCancelTokens[locatorKey];
  }
  [token cancel];
  [[DSHAgentRuntimeToolExecutor existingExecutorForWorkspaceExecutor:self.workspaceExecutor] cancelLocator:locator];
  [[DSHAgentGuestCgiToolExecutor executorForWorkspaceExecutor:self.workspaceExecutor] cancelAttempt:locator[@"attempt_id"]];
}

- (void)signalRuntimeCancellationRequest:(NSDictionary *)request {
  [[DSHAgentRuntimeToolExecutor existingExecutorForWorkspaceExecutor:self.workspaceExecutor] signalCancelRequest:request];
}
- (void)cancelRuntimeWork {
  [[DSHAgentRuntimeToolExecutor existingExecutorForWorkspaceExecutor:self.workspaceExecutor] cancelAll];
}

@end
