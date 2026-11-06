#import "AgentToolBatchService.h"

#import "AgentExecutionLedger.h"
#import "AgentGitToolExecutor.h"
#import "AgentNativeWAL.h"
#import "AgentPreparedAttemptStore.h"
#import "AgentTranscriptStore.h"
#import "AgentWorkspaceToolExecutor.h"
#import "AssistantTaskExecutor.h"
#import "DSHAgentGuestCgiToolExecutor.h"
#import "DSHAgentRuntimeToolExecutor.h"

#include "rish_agent_core.h"
#include <os/log.h>

// Every decision of this service lives in the shared core
// (modules/rish/core, `rish_agent_tool_batch_reduce`): request shapes, the
// preparation gate, the per-call analysis, the executor outcome mapping, the
// final authority check, the ledger-failure rejection and the approval
// binding checks. This side owns the WAL operation relation, the committed
// session load, the root proofs, the executors' preparation probes and the
// denied-approval transaction, and hands the core what it observed.

static NSDictionary *DSHAgentBatchReduce(NSString *op,
                                         NSDictionary *fields,
                                         NSError **error) {
  NSMutableDictionary *envelope = [fields mutableCopy];
  envelope[@"op"] = op;
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:envelope options:0 error:nil];
  if (bytes == nil) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  char *raw = rish_agent_tool_batch_reduce((const char *)bytes.bytes, bytes.length);
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

static id DSHAgentBatchValue(id value) {
  return value ?: NSNull.null;
}

static NSDictionary *DSHAgentBatchRound(NSDictionary *state,
                                         NSDictionary *request) {
  for (NSDictionary *round in state[@"rounds"]) {
    NSDictionary *locator = round[@"locator"];
    if ([locator[@"task_id"] isEqual:request[@"task_id"]] &&
        [locator[@"attempt_id"] isEqual:request[@"attempt_id"]] &&
        [locator[@"round_id"] isEqual:request[@"round_id"]] &&
        [locator[@"round_index"] isEqual:request[@"round_index"]]) {
      return round;
    }
  }
  return nil;
}

static NSDictionary *DSHAgentBatchAuthority(NSDictionary *state,
                                             NSDictionary *request) {
  for (NSDictionary *candidate in state[@"authorities"]) {
    if ([candidate[@"task_id"] isEqual:request[@"task_id"]] &&
        [candidate[@"attempt_id"] isEqual:request[@"attempt_id"]]) {
      return candidate;
    }
  }
  return nil;
}

static NSDictionary *DSHAgentBatchSafeResult(NSString *kind,
                                              NSDictionary *result) {
  return @{ @"schema_version" : @2, @"result_kind" : kind,
            @"result" : result };
}

// Commits a core-built rejection (`prepare_agent_tool_batch`) and returns it.
static NSDictionary *DSHAgentBatchCommitRejected(
    DSHAgentNativeWAL *wal,
    NSDictionary *request,
    NSDictionary *started,
    NSDictionary *rejected,
    NSError **error) {
  if (![rejected isKindOfClass:NSDictionary.class]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  if (error != nullptr) *error = nil;
  NSDictionary *commit = DSHAgentNativeWALCommitOperation(
      wal, request[@"operation_id"], started[@"request_sha256"],
      request[@"task_id"], request[@"attempt_id"], @"rejected", @"rejected",
      @{ @"schema_version" : @2, @"kind" : @"none" }, nil,
      DSHAgentBatchSafeResult(@"prepare_agent_tool_batch", rejected), error);
  return commit == nil ? nil : commit[@"result"][@"result"];
}

// Commits a core-built approval conflict (`bind_agent_approval`) and returns it.
static NSDictionary *DSHAgentBatchCommitApprovalConflict(
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
      DSHAgentBatchSafeResult(@"bind_agent_approval", conflict), error);
  return commit == nil ? nil : commit[@"result"][@"result"];
}

static NSDictionary *DSHAgentBatchHistoricalOperationResult(
    DSHAgentNativeWAL *wal,
    NSString *kind,
    NSDictionary *request,
    BOOL *terminalOut,
    NSError **error) {
  if (terminalOut != nullptr) *terminalOut = NO;
  NSString *requestSHA = DSHAgentHJ(@"agent-operation-request", @{
    @"operation_kind" : kind, @"request" : request,
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
        [snapshot[@"operation_kind"] isEqual:kind]) {
      if (terminalOut != nullptr) *terminalOut = YES;
      return snapshot[@"result"][@"result"];
    }
  }
  if (terminalOut != nullptr) *terminalOut = YES;
  DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
  return nil;
}

static NSDictionary *DSHAgentBatchCommittedSession(
    DSHAgentPreparedAttemptStore *preparedStore,
    NSDictionary *request,
    NSError **error) {
  NSDictionary *loaded = [preparedStore.sessionSnapshotStore
      loadSessionSnapshotWithError:error];
  NSDictionary *expected = request[@"committed_checkpoint"];
  if (![loaded[@"status"] isEqualToString:@"present"] ||
      ![loaded[@"snapshot"][@"generation"]
          isEqual:expected[@"session_generation"]] ||
      ![loaded[@"snapshot"][@"session_sha256"]
          isEqual:expected[@"session_sha256"]] ||
      ![loaded[@"session_json"] isKindOfClass:NSString.class]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorConflict);
    return nil;
  }
  NSData *bytes = [loaded[@"session_json"] dataUsingEncoding:NSUTF8StringEncoding];
  id session = bytes == nil ? nil
      : [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
  if (![session isKindOfClass:NSDictionary.class]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  return session;
}

// The committed session's conversation for the request, nil when absent.
static NSDictionary *DSHAgentBatchConversation(NSDictionary *session,
                                                NSDictionary *request) {
  for (NSDictionary *conversation in session[@"conversations"]) {
    if (![conversation isKindOfClass:NSDictionary.class]) continue;
    if ([(conversation[@"id"] ?: conversation[@"conversation_id"])
            isEqual:request[@"conversation_id"]]) {
      return conversation;
    }
  }
  return nil;
}

@interface DSHAgentToolBatchService ()
@property(nonatomic, strong, readwrite) DSHAgentNativeWAL *wal;
@property(nonatomic, strong, readwrite) DSHAgentExecutionLedger *ledger;
@property(nonatomic, strong, readwrite) DSHAgentPreparedAttemptStore *preparedStore;
@property(nonatomic, strong, readwrite) DSHAgentTranscriptStore *transcripts;
@property(nonatomic, strong) DSHAgentWorkspaceToolExecutor *workspaceExecutor;
@property(nonatomic, strong) DSHAgentGitToolExecutor *gitExecutor;
- (nullable NSDictionary *)prepareAgentToolBatchLockedWithRequest:
    (NSDictionary *)request error:(NSError **)error;
@end

@implementation DSHAgentToolBatchService

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
  }
  return self;
}

- (NSDictionary *)prepareAgentToolBatchWithRequest:(NSDictionary *)request
                                              error:(NSError **)error {
  __block NSDictionary *result = nil;
  BOOL completed = [self.preparedStore.sessionSnapshotStore.coordinator
      performSyncWithError:^BOOL(NSError **transactionError) {
        result = [self prepareAgentToolBatchLockedWithRequest:request
                                                       error:transactionError];
        return result != nil;
      }
      error:error];
  return completed ? result : nil;
}

// Runs the executors' preparation probes the core asked for, in call order,
// stopping at the first failure that is not an argument refusal (the core
// maps that failure to a whole-batch rejection). Each outcome is
// {prepared} | {error: <native code>} | null.
- (NSArray *)executorOutcomesForCalls:(NSArray *)calls
                                 root:(NSDictionary *)root
                              request:(NSDictionary *)request
                         conversation:(NSDictionary *)conversation
                      registryVersion:(NSNumber *)registryVersion {
  NSMutableArray *outcomes = [NSMutableArray arrayWithCapacity:calls.count];
  BOOL stopped = NO;
  for (NSDictionary *call in calls) {
    NSString *executor = [call[@"executor"] isKindOfClass:NSString.class]
        ? call[@"executor"] : nil;
    NSDictionary *arguments = [call[@"arguments"] isKindOfClass:NSDictionary.class]
        ? call[@"arguments"] : nil;
    if (stopped || executor == nil || arguments == nil) {
      [outcomes addObject:NSNull.null];
      continue;
    }
    NSString *name = call[@"name"];
    NSError *prepareError = nil;
    NSDictionary *prepared = nil;
    if ([executor isEqualToString:@"assistant"]) {
      prepared = [self.preparedStore.assistantTaskExecutor prepareToolNamed:name
          arguments:arguments conversation:conversation request:request
          registryVersion:registryVersion error:&prepareError];
    } else if ([executor isEqualToString:@"workspace"]) {
      prepared = [self.workspaceExecutor prepareToolNamed:name
                                                 arguments:arguments
                                                      root:root
                                                     error:&prepareError];
    } else if ([executor isEqualToString:@"runtime"]) {
      NSDictionary *outcome = [[DSHAgentRuntimeToolExecutor executorForWorkspaceExecutor:self.workspaceExecutor]
          prepareToolNamed:name arguments:arguments root:root];
      if ([outcome[@"rejection"] isKindOfClass:NSDictionary.class]) {
        [outcomes addObject:outcome]; continue;
      }
      prepared = outcome;
    } else if ([executor isEqualToString:@"guest"]) {
      NSDictionary *condition = [[DSHAgentGuestCgiToolExecutor
          executorForWorkspaceExecutor:self.workspaceExecutor]
          prepareToolNamed:name arguments:arguments root:root error:&prepareError];
      if (condition != nil) {
        prepared = @{ @"precondition" : condition, @"reserved_write_bytes" : @0 };
      }
    } else {
      prepared = [self.gitExecutor prepareToolNamed:name
                                           arguments:arguments
                                                root:root
                                               error:&prepareError];
    }
    if (prepared != nil) {
      [outcomes addObject:@{ @"prepared" : prepared }];
      continue;
    }
    NSInteger code = prepareError != nil ? prepareError.code : 0;
    [outcomes addObject:@{ @"error" : @(code) }];
    if (code != DSHAgentNativeStoreErrorInvalidArgument) stopped = YES;
  }
  return [outcomes copy];
}

- (NSDictionary *)prepareAgentToolBatchLockedWithRequest:(NSDictionary *)request
                                                    error:(NSError **)error {
  if (![request isKindOfClass:NSDictionary.class] ||
      DSHAgentBatchReduce(@"prepare_request", @{ @"request" : request }, error) == nil) {
    if (error != nullptr && *error == nil) {
      DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    }
    return nil;
  }
  BOOL historicalTerminal = NO;
  NSDictionary *historical = DSHAgentBatchHistoricalOperationResult(
      self.wal, @"prepare_agent_tool_batch", request, &historicalTerminal, error);
  if (historicalTerminal) return historical;
  NSDictionary *state = [self.wal snapshotWithError:error];
  if (state == nil) return nil;
  NSDictionary *authority = DSHAgentBatchAuthority(state, request);
  NSDictionary *round = DSHAgentBatchRound(state, request);
  NSDictionary *started = DSHAgentNativeWALStartOperation(
      self.wal, @"prepare_agent_tool_batch", request,
      request[@"task_id"], request[@"attempt_id"],
      authority[@"authority_revision"] ?: @0, error);
  if (started == nil) return nil;
  if ([started[@"status"] isEqualToString:@"replayed"] &&
      started[@"result"] != NSNull.null) return started[@"result"][@"result"];
  NSDictionary *committedSession = DSHAgentBatchCommittedSession(
      self.preparedStore, request, error);
  BOOL rootValid = committedSession != nil &&
      [self.preparedStore validatePreparedRoot:request[@"root"]
                                        taskId:request[@"task_id"]
                                     attemptId:request[@"attempt_id"]
                                          error:error];
  NSDictionary *gate = DSHAgentBatchReduce(@"prepare_gate", @{
    @"request" : request,
    @"authority" : DSHAgentBatchValue(authority),
    @"round" : DSHAgentBatchValue(round),
    @"session_ok" : @(committedSession != nil),
    @"root_ok" : @(rootValid),
  }, error);
  if (gate == nil) return nil;
  if (gate[@"reject"] != nil) {
    return DSHAgentBatchCommitRejected(self.wal, request, started, gate[@"reject"], error);
  }

  NSArray *messages = [self.transcripts nativeMessagesForTranscriptWithRequest:@{
    @"schema_version" : @1, @"attempt_id" : request[@"attempt_id"],
    @"root" : request[@"root"], @"transcript" : request[@"transcript"],
  } error:error];
  NSDictionary *conversation = DSHAgentBatchConversation(committedSession, request);
  NSArray *grants = [conversation[@"agent_grants"] isKindOfClass:NSArray.class]
      ? conversation[@"agent_grants"] : @[];
  NSDictionary *analysis = DSHAgentBatchReduce(@"prepare_calls", @{
    @"request" : request, @"round" : round, @"authority" : authority,
    @"messages" : DSHAgentBatchValue(messages), @"grants" : grants,
  }, error);
  if (analysis == nil) return nil;
  if (analysis[@"reject"] != nil) {
    return DSHAgentBatchCommitRejected(self.wal, request, started, analysis[@"reject"], error);
  }
  NSArray *calls = [analysis[@"calls"] isKindOfClass:NSArray.class] ? analysis[@"calls"] : @[];
  NSArray *outcomes = [self executorOutcomesForCalls:calls root:request[@"root"]
      request:request conversation:conversation registryVersion:authority[@"registry"][@"registry_version"]];
  NSDictionary *finish = DSHAgentBatchReduce(@"prepare_finish", @{
    @"request" : request, @"calls" : calls, @"outcomes" : outcomes,
  }, error);
  if (finish == nil) return nil;
  if (finish[@"reject"] != nil) {
    return DSHAgentBatchCommitRejected(self.wal, request, started, finish[@"reject"], error);
  }
  NSArray *preparedCalls = [finish[@"prepared_calls"] isKindOfClass:NSArray.class]
      ? finish[@"prepared_calls"] : @[];
  BOOL mutationBatch = [finish[@"mutation_batch"] isEqual:@YES];
  NSString *lateFailure = nil;
  if (DSHAgentBatchCommittedSession(self.preparedStore, request, error) == nil) {
    lateFailure = @"E_AGENT_CONFLICT";
  } else if (![self.preparedStore validatePreparedRoot:request[@"root"]
                                                taskId:request[@"task_id"]
                                             attemptId:request[@"attempt_id"]
                                                  error:error]) {
    lateFailure = @"E_AGENT_ROOT_STALE";
  }
  NSMutableSet<NSString *> *finalCapabilities = [NSMutableSet set];
  for (id capability in finish[@"capabilities"]) {
    if ([capability isKindOfClass:NSString.class]) [finalCapabilities addObject:capability];
  }
  __attribute__((objc_precise_lifetime)) DSHAgentRootFinalProof *finalProof =
      lateFailure != nil ? nil : [self.preparedStore.rootResolver
          acquireFinalProofForFrozenRoot:request[@"root"]
          requiredCapabilities:finalCapabilities
          needsProjectLease:[finish[@"needs_project_lease"] isEqual:@YES]
          projectWriteAccess:[finish[@"needs_project_write_lease"] isEqual:@YES]
          error:error];
  if (lateFailure == nil && finalProof == nil) lateFailure = @"E_AGENT_ROOT_STALE";
  if (lateFailure != nil) {
    NSDictionary *rejected = DSHAgentBatchReduce(@"rejected", @{
      @"request" : request, @"failure_code" : lateFailure,
      @"mutation_batch" : @(mutationBatch), @"retry_advice" : @"requery",
    }, error);
    if (rejected == nil) return nil;
    return DSHAgentBatchCommitRejected(self.wal, request, started, rejected[@"rejected"], error);
  }
  NSDictionary *finalAuthority = [self.preparedStore
      nativeAuthorityForTaskId:request[@"task_id"]
                     attemptId:request[@"attempt_id"] error:error];
  NSDictionary *final = DSHAgentBatchReduce(@"prepare_final", @{
    @"request" : request, @"authority" : authority,
    @"final_authority" : DSHAgentBatchValue(finalAuthority),
    @"started_authority_revision" : DSHAgentBatchValue(started[@"record"][@"authority_revision"]),
    @"request_sha256" : DSHAgentBatchValue(started[@"request_sha256"]),
    @"prepared_calls" : preparedCalls, @"mutation_batch" : @(mutationBatch),
  }, error);
  if (final == nil) return nil;
  if (final[@"reject"] != nil) {
    return DSHAgentBatchCommitRejected(self.wal, request, started, final[@"reject"], error);
  }
  NSDictionary *prepared = [self.ledger prepareAgentToolBatchWithRequest:final[@"internal"]
                                                                    error:error];
  if (prepared == nil) {
    // The committed rejection keeps only a failure code, and several store
    // reasons share one. Record the reason here or it is unrecoverable from a
    // device that has already failed. `reported` separates a store that said
    // Unavailable from one that said nothing and was assumed to mean it.
    BOOL reported = error != nullptr && *error != nil;
    NSInteger nativeCode = reported ? (*error).code : DSHAgentNativeStoreErrorUnavailable;
    os_log(OS_LOG_DEFAULT,
           "agent_batch_ledger_refused store_code=%{public}ld reported=%{public}d",
           (long)nativeCode, reported ? 1 : 0);
    NSDictionary *failure = DSHAgentBatchReduce(@"prepare_ledger_failure", @{
      @"request" : request, @"native_code" : @(nativeCode),
      @"prepared_calls" : preparedCalls,
    }, error);
    if (failure == nil) return nil;
    return DSHAgentBatchCommitRejected(self.wal, request, started, failure[@"rejected"], error);
  }
  NSDictionary *operationResult = prepared[@"operation_result"];
  if (![operationResult isKindOfClass:NSDictionary.class]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  return operationResult;
}

- (NSDictionary *)bindAgentApprovalWithRequest:(NSDictionary *)request
                                           error:(NSError **)error {
  NSDictionary *shape = [request isKindOfClass:NSDictionary.class]
      ? DSHAgentBatchReduce(@"bind_request", @{ @"request" : request }, error) : nil;
  if (shape == nil) {
    if (error != nullptr && *error == nil) {
      DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    }
    return nil;
  }
  /* Exact relationship failures are committed below after the native
     operation relation is started, so they replay as immutable conflicts. */
  BOOL tokenRelationValid = [shape[@"token_relation_valid"] isEqual:@YES];
  BOOL historicalTerminal = NO;
  NSDictionary *historical = DSHAgentBatchHistoricalOperationResult(
      self.wal, @"bind_agent_approval", request, &historicalTerminal, error);
  if (historicalTerminal) return historical;
  NSDictionary *state = [self.wal snapshotWithError:error];
  NSDictionary *authority = DSHAgentBatchAuthority(state, request);
  NSDictionary *started = DSHAgentNativeWALStartOperation(
      self.wal, @"bind_agent_approval", request, request[@"task_id"],
      request[@"attempt_id"], authority[@"authority_revision"] ?: @0, error);
  if (started == nil) return nil;
  if ([started[@"status"] isEqualToString:@"replayed"] &&
      started[@"result"] != NSNull.null) return started[@"result"][@"result"];
  NSDictionary *session = tokenRelationValid
      ? DSHAgentBatchCommittedSession(self.preparedStore, request, nullptr) : nil;
  NSDictionary *conversation = DSHAgentBatchConversation(session, request);
  NSArray *events = [session[@"session_events"] isKindOfClass:NSArray.class]
      ? session[@"session_events"] : @[];
  BOOL rootValid = authority != nil &&
      [self.preparedStore validatePreparedRoot:authority[@"root"]
                                        taskId:request[@"task_id"]
                                     attemptId:request[@"attempt_id"]
                                          error:nullptr];
  BOOL sessionValidAfter = session != nil &&
      DSHAgentBatchCommittedSession(self.preparedStore, request, nullptr) != nil;
  NSDictionary *check = DSHAgentBatchReduce(@"bind_check", @{
    @"request" : request,
    @"token_relation_valid" : @(tokenRelationValid),
    @"conversation" : DSHAgentBatchValue(conversation),
    @"events" : events,
    @"operation_results" : DSHAgentBatchValue(state[@"operation_results"]),
    @"authority" : DSHAgentBatchValue(authority),
    @"batches" : DSHAgentBatchValue(state[@"batches"]),
    @"ledger" : DSHAgentBatchValue(state[@"ledger"]),
    @"root_ok" : @(rootValid),
    @"session_ok_after" : @(sessionValidAfter),
  }, error);
  if (check == nil) return nil;
  if (check[@"conflict"] != nil) {
    return DSHAgentBatchCommitApprovalConflict(
        self.wal, request, started, check[@"conflict"], error);
  }
  NSDictionary *proceed = check[@"proceed"];
  NSDictionary *result = proceed[@"result"];
  NSDictionary *resultRef = proceed[@"result_ref"];
  if (![proceed isKindOfClass:NSDictionary.class] ||
      ![result isKindOfClass:NSDictionary.class] ||
      ![resultRef isKindOfClass:NSDictionary.class]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  if ([proceed[@"denied_fresh"] isEqual:@YES]) {
    // A fresh user denial is a settled tool result, not a bare decision:
    // native appends the exact protected denial feedback, settles the
    // never-dispatched intent row with a denied receipt, advances the
    // authority transcript, and commits the bind operation result in ONE
    // WAL transaction.  Replays and kills can never re-run an effect or
    // lose the denial.
    NSString *feedbackJSON = proceed[@"feedback_json"];
    NSDictionary *intentLocator = proceed[@"intent_locator"];
    if (![feedbackJSON isKindOfClass:NSString.class] ||
        ![intentLocator isKindOfClass:NSDictionary.class]) {
      DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
      return nil;
    }
    NSDictionary *policy = authority[@"policy"];
    NSNumber *reserved = authority[@"reserved_write_bytes"];
    __block NSDictionary *deniedResult = nil;
    __block NSDictionary *deniedCommit = nil;
    BOOL committed = [self.wal performAtomicTransaction:^BOOL(
        NSMutableDictionary *state, NSError **mutationError) {
      // Revalidate the essential authority relation inside the transaction:
      // the settled row must still be the exact prepared intent.
      NSDictionary *liveAuthority = DSHAgentBatchAuthority(state, request);
      if (liveAuthority == nil ||
          ![liveAuthority[@"root"] isEqual:authority[@"root"]] ||
          ![liveAuthority[@"policy"] isEqual:policy] ||
          ![liveAuthority[@"reserved_write_bytes"] isEqual:reserved]) {
        DSHSetAgentNativeStoreError(mutationError,
                                    DSHAgentNativeStoreErrorConflict);
        return NO;
      }
      NSDictionary *settlement = [self.ledger
          settleDeniedApprovalInState:state locator:intentLocator
          root:authority[@"root"]
          expectedTranscript:liveAuthority[@"transcript"]
          policy:policy expectedReservedWriteBytes:reserved
          feedbackJSON:feedbackJSON timestamp:[self.wal currentTimestamp]
          error:mutationError];
      if (settlement == nil) return NO;
      NSMutableDictionary *settled = [result mutableCopy];
      settled[@"receipt"] = DSHAgentBatchValue(settlement[@"receipt"]);
      settled[@"transcript"] = DSHAgentBatchValue(settlement[@"transcript"]);
      NSDictionary *commit = DSHAgentNativeWALCommitOperationInState(
          state, self.wal, request[@"operation_id"],
          started[@"request_sha256"], request[@"task_id"],
          request[@"attempt_id"], @"committed", @"bound", resultRef,
          request[@"batch_revision"],
          DSHAgentBatchSafeResult(@"bind_agent_approval", [settled copy]),
          mutationError);
      if (commit == nil) return NO;
      deniedResult = [settled copy];
      deniedCommit = commit;
      return YES;
    } error:error];
    if (!committed) return nil;
    if (deniedCommit != nil &&
        [deniedCommit[@"result"] isKindOfClass:NSDictionary.class] &&
        [deniedCommit[@"result"][@"result"] isKindOfClass:NSDictionary.class]) {
      return deniedCommit[@"result"][@"result"];
    }
    return deniedResult;
  }
  NSDictionary *commit = DSHAgentNativeWALCommitOperation(
      self.wal, request[@"operation_id"], started[@"request_sha256"],
      request[@"task_id"], request[@"attempt_id"], @"committed", result[@"status"],
      resultRef, request[@"batch_revision"],
      DSHAgentBatchSafeResult(@"bind_agent_approval", result), error);
  return commit == nil ? nil : commit[@"result"][@"result"];
}

@end
