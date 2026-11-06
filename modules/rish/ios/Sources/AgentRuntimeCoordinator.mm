#import "AgentRuntimeCoordinator.h"

#import "AgentExecutionLedger.h"
#import "AgentNativeWAL.h"
#import "AgentPreparedAttemptStore.h"
#import "AgentProviderRoundService.h"
#import "AgentRoundJournal.h"
#import "AgentToolBatchService.h"
#import "AgentToolExecutionService.h"
#import "AgentTranscriptStore.h"
#import "SessionWorkspaceCoordinator.h"

@interface DSHAgentProviderRoundService (DSHRuntimeAvailability)
@property(nonatomic, copy, readonly)
    DSHAgentProviderRoundCredentialProvider credentialProvider;
@property(nonatomic, copy, readonly)
    DSHAgentProviderRoundVisibleHistoryProvider visibleHistoryProvider;
@property(nonatomic, copy, readonly)
    DSHAgentProviderRoundContextReceiptProvider contextReceiptProvider;
@end

@interface DSHAgentToolExecutionService (DSHRuntimeAvailability)
@property(nonatomic, strong, readonly) DSHAgentNativeWAL *wal;
@property(nonatomic, strong, readonly) DSHAgentExecutionLedger *ledger;
@property(nonatomic, strong, readonly) DSHAgentPreparedAttemptStore *preparedStore;
@property(nonatomic, strong, readonly) DSHAgentTranscriptStore *transcripts;
@end

#include "rish_agent_core.h"

// Every rule below lives in the shared core (modules/rish/core,
// `rish_agent_runtime_reduce`). This side keeps the stores, the transactions
// and the executors: it loads the session snapshot and the WAL state, calls
// the typed services, and hands their answers back as facts.
static NSDictionary *DSHRuntimeReduce(NSDictionary *envelope) {
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:envelope options:0
                                                    error:nil];
  if (bytes == nil) return nil;
  char *raw = rish_agent_runtime_reduce((const char *)bytes.bytes, bytes.length);
  if (raw == NULL) return nil;
  NSData *replyBytes = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  id reply = [NSJSONSerialization JSONObjectWithData:replyBytes options:0
                                               error:nil];
  if (![reply isKindOfClass:NSDictionary.class]) return nil;
  return reply;
}

/// Runs one core decision and maps a refusal onto the store error vocabulary.
static NSDictionary *DSHRuntimeDecide(NSDictionary *envelope, NSError **error) {
  NSDictionary *reply = DSHRuntimeReduce(envelope);
  if (reply == nil) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  if (![reply[@"ok"] isEqual:@YES]) {
    DSHSetAgentNativeStoreError(
        error, (DSHAgentNativeStoreErrorCode)[reply[@"error"] integerValue]);
    return nil;
  }
  return reply;
}

/// The committed session as a parsed object. `present` distinguishes a
/// snapshot that could not be read at all from one that read but did not
/// parse; the callers map those two differently.
static NSDictionary *DSHRuntimeLoadSession(
    DSHAgentPreparedAttemptStore *preparedStore,
    NSDictionary *__strong *facts,
    BOOL *present,
    NSError **error) {
  if (present != nullptr) *present = NO;
  NSDictionary *loaded = [preparedStore.sessionSnapshotStore
      loadSessionSnapshotWithError:error];
  id sessionJSON = loaded[@"session_json"];
  if (![loaded[@"status"] isEqualToString:@"present"] ||
      ![loaded[@"snapshot"] isKindOfClass:NSDictionary.class] ||
      ![sessionJSON isKindOfClass:NSString.class]) {
    return nil;
  }
  if (present != nullptr) *present = YES;
  if (facts != nullptr) {
    *facts = @{
      @"session_generation" : loaded[@"snapshot"][@"generation"] ?: NSNull.null,
      @"session_sha256" : loaded[@"snapshot"][@"session_sha256"] ?: NSNull.null,
    };
  }
  NSData *bytes = [sessionJSON dataUsingEncoding:NSUTF8StringEncoding];
  id session = bytes == nil ? nil :
      [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
  return [session isKindOfClass:NSDictionary.class] ? session : nil;
}

static NSDictionary *DSHRuntimeSessionProof(
    DSHAgentPreparedAttemptStore *preparedStore,
    NSString *conversationId,
    NSString *taskId,
    NSString *attemptId,
    NSNumber *expectedControllerGeneration,
    NSNumber *expectedJournalRevision,
    NSNumber *expectedSessionGeneration,
    NSString *expectedSessionSHA256,
    NSError **error) {
  NSDictionary *facts = nil;
  BOOL present = NO;
  NSDictionary *session = DSHRuntimeLoadSession(preparedStore, &facts, &present,
                                                error);
  if (!present) {
    if (error != nullptr && *error == nil) {
      DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorPersistence);
    }
    return nil;
  }
  if (session == nil) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  NSDictionary *reply = DSHRuntimeDecide(@{
    @"op" : @"session_proof",
    @"session" : session,
    @"facts" : facts,
    @"request" : @{
      @"conversation_id" : conversationId ?: NSNull.null,
      @"task_id" : taskId ?: NSNull.null,
      @"attempt_id" : attemptId ?: NSNull.null,
      @"expected_controller_generation" :
          expectedControllerGeneration ?: NSNull.null,
      @"expected_journal_revision" : expectedJournalRevision ?: NSNull.null,
      @"expected_session_generation" : expectedSessionGeneration ?: NSNull.null,
      @"expected_session_sha256" : expectedSessionSHA256 ?: NSNull.null,
    },
  }, error);
  if (reply == nil) return nil;
  NSMutableDictionary *proof = [reply[@"proof"] mutableCopy];
  proof[@"session"] = session;
  return proof;
}

static BOOL DSHRuntimeCancelSourceProof(NSDictionary *session,
                                        NSDictionary *request,
                                        NSError **error) {
  NSDictionary *reply = DSHRuntimeReduce(@{
    @"op" : @"cancel_source_proof",
    @"session" : session ?: NSNull.null,
    @"request" : request ?: NSNull.null,
  });
  if ([reply[@"proves"] isEqual:@YES]) return YES;
  DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorConflict);
  return NO;
}

static BOOL DSHRuntimeCleanupOutboxProof(
    DSHAgentPreparedAttemptStore *preparedStore,
    NSDictionary *request,
    NSError **error) {
  NSDictionary *session = DSHRuntimeLoadSession(preparedStore, nullptr, nullptr,
                                                error);
  NSDictionary *reply = session == nil ? nil : DSHRuntimeReduce(@{
    @"op" : @"cleanup_outbox_proof",
    @"session" : session,
    @"request" : request ?: NSNull.null,
  });
  if ([reply[@"proves"] isEqual:@YES]) return YES;
  DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorConflict);
  return NO;
}

static NSString *DSHRuntimeChildOperationID(NSString *operationId,
                                            NSString *purpose,
                                            NSError **error) {
  NSDictionary *reply = DSHRuntimeDecide(@{
    @"op" : @"child_operation_id",
    @"purpose" : purpose ?: NSNull.null,
    @"request" : @{ @"operation_id" : operationId ?: NSNull.null },
  }, error);
  return reply[@"operation_id"];
}

/// Commits the operation the core decided, inside the caller's transaction so
/// the WAL's fault hook still speaks where it always did.
static NSDictionary *DSHRuntimeCommitInState(NSMutableDictionary *state,
                                             DSHAgentNativeWAL *wal,
                                             NSDictionary *commit,
                                             NSError **error) {
  id revision = commit[@"result_revision"];
  return DSHAgentNativeWALCommitOperationInState(
      state, wal, commit[@"operation_id"], commit[@"request_sha256"],
      commit[@"task_id"], commit[@"attempt_id"], commit[@"terminal_state"],
      commit[@"result_status"], commit[@"result_ref"],
      revision == NSNull.null ? nil : revision, commit[@"safe_result"], error);
}

/// The same commit, in a transaction of its own.
static NSDictionary *DSHRuntimeCommitAlone(DSHAgentNativeWAL *wal,
                                           NSDictionary *commit,
                                           NSError **error) {
  id revision = commit[@"result_revision"];
  NSDictionary *committed = DSHAgentNativeWALCommitOperation(
      wal, commit[@"operation_id"], commit[@"request_sha256"],
      commit[@"task_id"], commit[@"attempt_id"], commit[@"terminal_state"],
      commit[@"result_status"], commit[@"result_ref"],
      revision == NSNull.null ? nil : revision, commit[@"safe_result"], error);
  return committed == nil ? nil : committed[@"result"][@"result"];
}

/// Applies the top-level arrays the core decided to replace.
static void DSHRuntimeApplyChanges(NSMutableDictionary *state,
                                   NSDictionary *changes) {
  for (NSString *key in changes) state[key] = changes[key];
}

static NSString *DSHRuntimeOperationRequestSHA(NSString *operationKind,
                                               NSDictionary *request,
                                               NSError **error) {
  return DSHAgentHJ(@"agent-operation-request", @{
    @"operation_kind" : operationKind, @"request" : request,
  }, error);
}

/// The replay a command returns when its operation is already terminal.
static NSDictionary *DSHRuntimeReplayTerminalOperation(
    DSHAgentNativeWAL *wal, NSString *operationKind, NSDictionary *request,
    NSDictionary *operationQuery, NSError **error) {
  NSDictionary *replay = DSHAgentNativeWALStartOperation(
      wal, operationKind, request, request[@"task_id"], request[@"attempt_id"],
      operationQuery[@"record"][@"authority_revision"], error);
  return [replay[@"status"] isEqualToString:@"replayed"]
      ? replay[@"result"][@"result"] : nil;
}

/// Closes a command whose durable residue is already gone.
static NSDictionary *DSHRuntimeCommitAlreadyMissing(
    DSHAgentNativeWAL *wal, NSDictionary *request, NSString *operationKind,
    NSDictionary *operationQuery, NSError **error) {
  NSNumber *authorityRevision =
      [operationQuery[@"status"] isEqualToString:@"found"]
      ? operationQuery[@"record"][@"authority_revision"] : @0;
  NSDictionary *started = DSHAgentNativeWALStartOperation(
      wal, operationKind, request, request[@"task_id"], request[@"attempt_id"],
      authorityRevision, error);
  if ([started[@"status"] isEqualToString:@"replayed"]) {
    return started[@"result"][@"result"];
  }
  if (started == nil) return nil;
  NSDictionary *decided = DSHRuntimeDecide(@{
    @"op" : @"already_missing", @"kind" : operationKind,
    @"request" : request, @"started" : started,
  }, error);
  if (decided == nil) return nil;
  NSDictionary *committed = DSHRuntimeCommitAlone(wal, decided[@"commit"], error);
  return committed == nil ? nil : decided[@"output"];
}

/// The residue discard shared by discard (after a committed finalize) and
/// interrupt (a dead writer's still-prepared authority).
static NSDictionary *DSHRuntimeSettleResidue(DSHAgentNativeWAL *wal,
                                             DSHAgentPreparedAttemptStore *preparedStore,
                                             NSDictionary *request,
                                             NSString *operationKind,
                                             NSString *authorityKind,
                                             NSArray<NSString *> *options,
                                             NSDictionary *operationQuery,
                                             NSError **error) {
  NSDictionary *stateBefore = [wal snapshotWithError:error];
  if (stateBefore == nil) return nil;
  NSDictionary *authority = DSHRuntimeDecide(@{
    @"op" : @"settle_authority_state", @"kind" : authorityKind,
    @"state" : stateBefore, @"request" : request,
  }, error);
  if (authority == nil) return nil;
  if (authority[@"authority"] == NSNull.null) {
    NSDictionary *closes = DSHRuntimeReduce(@{
      @"op" : @"exact_discarded_cleanup",
      @"state" : stateBefore, @"request" : request,
    });
    BOOL outboxProves = [operationKind isEqualToString:@"discard_agent_attempt"]
        ? DSHRuntimeCleanupOutboxProof(preparedStore, request, error) : YES;
    if (![closes[@"proves"] isEqual:@YES] || !outboxProves) {
      DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorConflict);
      return nil;
    }
    return DSHRuntimeCommitAlreadyMissing(wal, request, operationKind,
                                          operationQuery, error);
  }
  if (![authority[@"settles"] isEqual:@YES]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorConflict);
    return nil;
  }
  NSNumber *authorityRevision =
      [operationQuery[@"status"] isEqualToString:@"found"]
      ? operationQuery[@"record"][@"authority_revision"]
      : authority[@"authority"][@"authority_revision"];
  NSDictionary *started = DSHAgentNativeWALStartOperation(
      wal, operationKind, request, request[@"task_id"], request[@"attempt_id"],
      authorityRevision, error);
  if (started == nil) return nil;
  __block NSDictionary *output = nil;
  BOOL committed = [wal performAtomicTransaction:^BOOL(
      NSMutableDictionary *state, NSError **mutationError) {
    NSDictionary *current = DSHRuntimeDecide(@{
      @"op" : @"settle_authority_state", @"kind" : authorityKind,
      @"state" : state, @"request" : request,
    }, mutationError);
    if (![current[@"settles"] isEqual:@YES]) {
      DSHSetAgentNativeStoreError(mutationError,
                                  DSHAgentNativeStoreErrorConflict);
      return NO;
    }
    NSDictionary *decided = DSHRuntimeDecide(@{
      @"op" : @"residue_discard", @"kind" : operationKind,
      @"options" : options, @"state" : state, @"request" : request,
      @"started" : started, @"timestamp" : [wal currentTimestamp],
    }, mutationError);
    if (decided == nil) return NO;
    if (![decided[@"result"] isEqualToString:@"settle"]) {
      DSHSetAgentNativeStoreError(
          mutationError,
          (DSHAgentNativeStoreErrorCode)[decided[@"error"] integerValue]);
      return NO;
    }
    DSHRuntimeApplyChanges(state, decided[@"changes"]);
    if (DSHRuntimeCommitInState(state, wal, decided[@"commit"],
                                 mutationError) == nil) {
      return NO;
    }
    output = decided[@"output"];
    return YES;
  } error:error];
  return committed ? output : nil;
}

static NSDictionary *DSHRuntimeSerializedResult(NSDictionary *(^operation)(void)) {
  __block NSDictionary *result = nil;
  DSHSessionWorkspacePerformSync(^{ result = operation(); });
  return result;
}

static NSDictionary *DSHRuntimeRequest(id request, NSArray<NSString *> *keys,
                                       NSError **error) {
  NSDictionary *copy = DSHAgentImmutableJSONCopy(request, error);
  if (![copy isKindOfClass:NSDictionary.class] ||
      !DSHAgentExactDictionaryKeys(copy, keys) ||
      ![copy[@"schema_version"] isEqual:@2]) {
    DSHSetAgentNativeStoreError(error,
                                DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  return copy;
}

static NSDictionary *DSHRuntimeExecutionCAS(NSDictionary *row) {
  NSDictionary *owner = row[@"owner"];
  BOOL owned = [owner isKindOfClass:NSDictionary.class];
  return @{
    @"schema_version" : @2,
    @"locator" : row[@"locator"],
    @"expected_row_revision" : row[@"row_revision"],
    @"expected_state" : row[@"state"],
    @"expected_owner_generation" : owned
        ? owner[@"owner_generation"] : NSNull.null,
    @"expected_launch_id" : owned ? owner[@"launch_id"] : NSNull.null,
    @"expected_native_task_id" : owned
        ? owner[@"native_task_id"] : NSNull.null,
    @"expected_transcript_generation" :
        row[@"transcript_before"][@"generation"],
    @"expected_transcript_sha256" :
        row[@"transcript_before"][@"transcript_sha256"],
    @"expected_root_fingerprint_sha256" :
        row[@"root_fingerprint_sha256"],
    @"expected_binding_revision" : row[@"binding_revision"],
  };
}

static NSDictionary *DSHRuntimeCommitRecoveryResult(
    DSHAgentNativeWAL *wal,
    NSDictionary *request,
    NSDictionary *started,
    NSDictionary *result,
    NSError **error) {
  NSDictionary *state = [wal snapshotWithError:error];
  if (state == nil) return nil;
  NSDictionary *decided = DSHRuntimeDecide(@{
    @"op" : @"recovery_commit", @"state" : state, @"request" : request,
    @"started" : started, @"settled" : result,
  }, error);
  if (decided == nil) return nil;
  return DSHRuntimeCommitAlone(wal, decided[@"commit"], error);
}

@interface DSHAgentRuntimeCoordinator ()
@property(nonatomic, readwrite, getter=isAvailable) BOOL available;
@property(nonatomic, strong, readwrite) DSHAgentNativeWAL *wal;
@property(nonatomic, strong, readwrite) DSHAgentPreparedAttemptStore *preparedStore;
@property(nonatomic, strong, readwrite) DSHAgentProviderRoundService *roundService;
@property(nonatomic, strong, readwrite) DSHAgentToolBatchService *batchService;
@property(nonatomic, strong, readwrite) DSHAgentToolExecutionService *executionService;
@property(nonatomic, strong, readwrite) DSHAgentTranscriptStore *transcripts;
@property(nonatomic, strong, readwrite) DSHAgentRoundJournal *rounds;
@property(nonatomic, strong, readwrite) DSHAgentExecutionLedger *ledger;
@end

@implementation DSHAgentRuntimeCoordinator

- (instancetype)initWithWAL:(DSHAgentNativeWAL *)wal
               preparedStore:(DSHAgentPreparedAttemptStore *)preparedStore
                roundService:(DSHAgentProviderRoundService *)roundService
                 batchService:(DSHAgentToolBatchService *)batchService
             executionService:(DSHAgentToolExecutionService *)executionService
                  transcripts:(DSHAgentTranscriptStore *)transcripts
                       rounds:(DSHAgentRoundJournal *)rounds
                       ledger:(DSHAgentExecutionLedger *)ledger {
  self = [super init];
  if (self != nil) {
    BOOL oneWAL = wal != nil && preparedStore.wal == wal &&
        roundService.wal == wal && batchService.wal == wal &&
        executionService.wal == wal && transcripts.wal == wal &&
        rounds.wal == wal && ledger.wal == wal &&
        roundService.preparedStore == preparedStore &&
        roundService.transcripts == transcripts && roundService.rounds == rounds &&
        batchService.preparedStore == preparedStore && batchService.ledger == ledger &&
        batchService.transcripts == transcripts &&
        executionService.preparedStore == preparedStore &&
        executionService.ledger == ledger &&
        executionService.transcripts == transcripts;
    BOOL providerReady = roundService.transport != nil &&
        roundService.credentialProvider != nil &&
        roundService.visibleHistoryProvider != nil &&
        roundService.contextReceiptProvider != nil;
    if (!oneWAL || !providerReady) return nil;
    _wal = wal;
    _preparedStore = preparedStore;
    _roundService = roundService;
    _batchService = batchService;
    _executionService = executionService;
    _transcripts = transcripts;
    _rounds = rounds;
    _ledger = ledger;
    _available = YES;
  }
  return self;
}

- (instancetype)initForRecoveryTestingWithWAL:(DSHAgentNativeWAL *)wal
                                  preparedStore:(DSHAgentPreparedAttemptStore *)preparedStore
                                   roundService:(DSHAgentProviderRoundService *)roundService
                               executionService:(DSHAgentToolExecutionService *)executionService
                                    transcripts:(DSHAgentTranscriptStore *)transcripts
                                         ledger:(DSHAgentExecutionLedger *)ledger {
  self = [super init];
  if (self != nil) {
    if (wal == nil || preparedStore == nil || roundService == nil ||
        executionService == nil || transcripts.wal != wal || ledger.wal != wal) {
      return nil;
    }
    _wal = wal;
    _preparedStore = preparedStore;
    _roundService = roundService;
    _executionService = executionService;
    _transcripts = transcripts;
    _ledger = ledger;
    _available = YES;
  }
  return self;
}

- (NSDictionary *)prepareAgentAttempt:(NSDictionary *)request
                                  error:(NSError **)error {
  return [self.preparedStore prepareAgentAttemptWithRequest:request error:error];
}

- (NSDictionary *)completeAgentRoundV2:(NSDictionary *)request
                                    error:(NSError **)error {
  return [self.roundService completeAgentRoundV2WithRequest:request error:error];
}

- (NSDictionary *)prepareAgentToolBatch:(NSDictionary *)request
                                    error:(NSError **)error {
  return [self.batchService prepareAgentToolBatchWithRequest:request error:error];
}

- (NSDictionary *)bindAgentApproval:(NSDictionary *)request
                                error:(NSError **)error {
  return [self.batchService bindAgentApprovalWithRequest:request error:error];
}

- (NSDictionary *)executeAgentTool:(NSDictionary *)request
                               error:(NSError **)error {
  return [self.executionService executeAgentToolWithRequest:request error:error];
}

- (NSDictionary *)queryAgentTool:(NSDictionary *)rawRequest
                             error:(NSError **)error {
  NSDictionary *request = DSHAgentImmutableJSONCopy(rawRequest, error);
  NSDictionary *shape = request == nil ? nil : DSHRuntimeDecide(@{
    @"op" : @"query_tool_request", @"request" : request,
  }, error);
  if (shape == nil) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  NSDictionary *locator = shape[@"locator"];
  NSDictionary *controllerCAS = request[@"controller_cas"];
  NSDictionary *proof = DSHRuntimeSessionProof(
      self.preparedStore, request[@"conversation_id"], request[@"task_id"],
      request[@"attempt_id"],
      controllerCAS[@"expected_controller_generation"],
      controllerCAS[@"expected_journal_revision"],
      controllerCAS[@"expected_session_generation"],
      controllerCAS[@"expected_session_sha256"], error);
  if (proof == nil) return nil;
  if (![proof[@"matches"] boolValue]) {
    NSDictionary *state = [self.wal snapshotWithError:error];
    if (state == nil) return nil;
    if (error != nullptr) *error = nil;
    return DSHRuntimeDecide(@{
      @"op" : @"query_tool_session_conflict",
      @"state" : state, @"request" : request,
    }, error)[@"output"];
  }
  NSError *ledgerError = nil;
  NSDictionary *queried = [self.ledger queryAgentExecutionWithLocator:locator
      expectedTranscript:request[@"expected_transcript"] root:@{
        @"schema_version" : @1,
        @"root_fingerprint_sha256" : request[@"expected_root_fingerprint_sha256"],
        @"binding_revision" : request[@"expected_workspace_binding_revision"],
      } error:&ledgerError];
  if (queried == nil) {
    if (ledgerError.code != DSHAgentNativeStoreErrorConflict) {
      if (error != nullptr) *error = ledgerError;
      return nil;
    }
    NSDictionary *state = [self.wal snapshotWithError:error];
    if (state == nil) return nil;
    if (error != nullptr) *error = nil;
    return DSHRuntimeDecide(@{
      @"op" : @"query_tool_ledger_conflict",
      @"state" : state, @"request" : request,
    }, error)[@"output"];
  }
  return DSHRuntimeDecide(@{
    @"op" : @"query_tool_result",
    @"queried" : queried, @"request" : request,
  }, error)[@"output"];
}

- (NSDictionary *)readAgentRoundPresentations:(NSDictionary *)request
                                          error:(NSError **)error {
  if (DSHRuntimeDecide(@{
        @"op" : @"presentations_request", @"request" : request ?: NSNull.null,
      }, error) == nil) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  BOOL present = NO;
  NSDictionary *session = DSHRuntimeLoadSession(self.preparedStore, nullptr,
                                                 &present, error);
  if (!present || session == nil) {
    if (error != nullptr && *error == nil) {
      DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorUnavailable);
    }
    return nil;
  }
  NSDictionary *owns = DSHRuntimeReduce(@{
    @"op" : @"session_owns_attempt",
    @"session" : session, @"request" : request,
  });
  if (![owns[@"owns"] isEqual:@YES]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorNotFound);
    return nil;
  }
  return [self.transcripts roundPresentationsForConversation:request[@"conversation_id"]
                                                      attempt:request[@"attempt_id"]
                                                        error:error];
}

- (NSDictionary *)queryAgentAttempt:(NSDictionary *)rawRequest
                                error:(NSError **)error {
  NSDictionary *request = DSHAgentImmutableJSONCopy(rawRequest, error);
  if (request == nil || DSHRuntimeDecide(@{
        @"op" : @"query_attempt_request", @"request" : request,
      }, error) == nil) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  NSDictionary *controllerCAS = request[@"controller_cas"];
  NSDictionary *proof = DSHRuntimeSessionProof(
      self.preparedStore, request[@"conversation_id"], request[@"task_id"],
      request[@"attempt_id"],
      controllerCAS[@"expected_controller_generation"],
      controllerCAS[@"expected_journal_revision"],
      controllerCAS[@"expected_session_generation"],
      controllerCAS[@"expected_session_sha256"], error);
  if (proof == nil) return nil;
  NSDictionary *sessionConflict = DSHRuntimeDecide(@{
    @"op" : @"query_attempt_session_conflict",
    @"request" : request, @"proof" : proof,
  }, error)[@"output"];
  if ([sessionConflict isKindOfClass:NSDictionary.class]) {
    if (error != nullptr) *error = nil;
    return sessionConflict;
  }
  NSError *authorityError = nil;
  NSDictionary *base = [self.preparedStore preparedAttemptForTaskId:request[@"task_id"]
      attemptId:request[@"attempt_id"] error:&authorityError];
  if (base == nil) {
    if (authorityError.code == DSHAgentNativeStoreErrorNotFound) {
      if (error != nullptr) *error = nil;
      return @{ @"schema_version" : @2, @"status" : @"not_found",
                @"failure_code" : @"E_AGENT_NOT_FOUND" };
    }
    if (error != nullptr) *error = authorityError;
    return nil;
  }
  NSDictionary *state = [self.wal snapshotWithError:error];
  if (state == nil) return nil;
  NSDictionary *baseConflict = DSHRuntimeDecide(@{
    @"op" : @"query_attempt_base_conflict",
    @"request" : request, @"proof" : proof, @"base" : base, @"state":state,
  }, error)[@"output"];
  if ([baseConflict isKindOfClass:NSDictionary.class]) return baseConflict;
  return DSHRuntimeDecide(@{
    @"op" : @"query_attempt_projection",
    @"request" : request, @"proof" : proof, @"base" : base, @"state" : state,
  }, error)[@"output"];
}

- (NSDictionary *)cancelAgentAttempt:(NSDictionary *)rawRequest
                                 error:(NSError **)error {
  NSDictionary *request = DSHAgentImmutableJSONCopy(rawRequest, error);
  if (request == nil || DSHRuntimeDecide(@{
        @"op" : @"target_request", @"kind" : @"cancel", @"request" : request,
      }, error) == nil) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  NSDictionary *target = request[@"target"];
  NSDictionary *controllerCAS = request[@"controller_cas"];
  NSString *requestSHA = DSHRuntimeOperationRequestSHA(@"cancel_agent_attempt",
                                                       request, error);
  NSDictionary *operationQuery = requestSHA == nil ? nil :
      DSHAgentNativeWALQueryOperation(self.wal, request[@"operation_id"],
          requestSHA, target[@"task_id"], target[@"attempt_id"], error);
  if (operationQuery == nil) return nil;
  BOOL operationFound = [operationQuery[@"status"] isEqualToString:@"found"];
  if (operationFound &&
      ![operationQuery[@"record"][@"state"] isEqualToString:@"started"]) {
    NSDictionary *replay = DSHAgentNativeWALStartTargetOperation(
        self.wal, @"cancel_agent_attempt", request, target,
        target[@"task_id"], target[@"attempt_id"],
        operationQuery[@"record"][@"authority_revision"], error);
    return [replay[@"status"] isEqualToString:@"replayed"]
        ? replay[@"result"][@"result"] : nil;
  }
  NSDictionary *checkpoint = request[@"committed_checkpoint"];
  NSDictionary *sourceProof = DSHRuntimeSessionProof(
      self.preparedStore, controllerCAS[@"conversation_id"],
      target[@"task_id"], target[@"attempt_id"],
      controllerCAS[@"expected_controller_generation"],
      controllerCAS[@"expected_journal_revision"],
      checkpoint[@"session_generation"], checkpoint[@"session_sha256"], error);
  if (sourceProof == nil) return nil;
  NSDictionary *(^conflict)(NSString *) = ^NSDictionary *(NSString *failureCode) {
    NSError *decideError = nil;
    return DSHRuntimeDecide(@{
      @"op" : @"target_conflict", @"failure_code" : failureCode,
      @"request" : request, @"proof" : sourceProof,
    }, &decideError)[@"output"];
  };
  if (![sourceProof[@"matches"] boolValue]) {
    if (error != nullptr) *error = nil;
    return conflict(@"E_AGENT_CONFLICT");
  }
  if (!DSHRuntimeCancelSourceProof(sourceProof[@"session"], request, error)) {
    if (error != nullptr) *error = nil;
    return conflict(@"E_AGENT_CANCELLED");
  }
  if (![self.preparedStore validatePreparedRoot:request[@"root"]
      taskId:target[@"task_id"] attemptId:target[@"attempt_id"] error:error]) {
    return conflict(@"E_AGENT_ROOT_STALE");
  }
  NSDictionary *authority = [self.preparedStore
      nativeAuthorityForTaskId:target[@"task_id"]
                     attemptId:target[@"attempt_id"] error:error];
  if (authority == nil) return nil;
  NSDictionary *started = DSHAgentNativeWALStartTargetOperation(
      self.wal, @"cancel_agent_attempt", request, target,
      target[@"task_id"], target[@"attempt_id"],
      operationFound ? operationQuery[@"record"][@"authority_revision"]
                     : authority[@"authority_revision"], error);
  if ([started[@"status"] isEqualToString:@"replayed"]) {
    return started[@"result"][@"result"];
  }
  if (started == nil) return nil;
  NSDictionary *(^settle)(NSDictionary *) = ^NSDictionary *(NSDictionary *result) {
    NSDictionary *decided = DSHRuntimeDecide(@{
      @"op" : @"cancel_commit", @"request" : request, @"started" : started,
      @"settled" : result,
    }, error);
    if (decided == nil) return nil;
    return DSHRuntimeCommitAlone(self.wal, decided[@"commit"], error);
  };
  NSDictionary *state = [self.wal snapshotWithError:error];
  if (state == nil) return nil;
  NSDictionary *plan = DSHRuntimeDecide(@{
    @"op" : @"cancel_plan", @"state" : state, @"request" : request,
  }, error);
  if (plan == nil) return nil;
  NSString *kind = plan[@"plan"];
  if ([kind isEqualToString:@"round"]) {
    NSDictionary *roundTarget = plan[@"round_target"];
    NSDictionary *cancelled = [self.roundService cancelAgentRoundWithRequest:@{
      @"schema_version" : @2, @"task_id" : target[@"task_id"],
      @"attempt_id" : target[@"attempt_id"],
      @"round_id" : roundTarget[@"round_id"],
      @"round_index" : roundTarget[@"round_index"],
      @"expected_round_revision" : plan[@"expected_round_revision"],
      @"transcript" : request[@"expected_transcript"], @"root" : request[@"root"],
      @"cancel_token" : request[@"cancel_token"][@"token"],
    } error:error];
    if (cancelled == nil) return nil;
    NSDictionary *result = DSHRuntimeDecide(@{
      @"op" : @"cancel_round_result", @"request" : request,
      @"cancelled" : cancelled, @"proof" : sourceProof,
    }, error)[@"output"];
    return result == nil ? nil : settle(result);
  }
  if ([kind isEqualToString:@"idle_attempt"]) {
    // Close every never-dispatched intent through the normal ledger CAS.
    // Leaving intent rows live would make final discard correctly refuse.
    NSMutableDictionary *settledPlan = [plan mutableCopy];
    for (NSDictionary *pending in plan[@"rows"]) {
      NSDictionary *closed = [self.ledger cancelAgentExecutionWithCAS:DSHRuntimeExecutionCAS(pending)
          patch:@{ @"state" : @"cancelled" } error:error];
      if (closed == nil) return nil;
      if ([closed[@"row"][@"transcript_after"] isKindOfClass:NSDictionary.class]) {
        settledPlan[@"transcript"] = closed[@"row"][@"transcript_after"];
      }
    }
    NSDictionary *result = DSHRuntimeDecide(@{
      @"op" : @"cancel_idle_attempt_result", @"request" : request, @"plan" : settledPlan,
    }, error)[@"output"];
    return result == nil ? nil : settle(result);
  }
  if ([kind isEqualToString:@"never_started"]) {
    NSDictionary *result = DSHRuntimeDecide(@{
      @"op" : @"cancel_never_started_result", @"request" : request,
    }, error)[@"output"];
    return result == nil ? nil : settle(result);
  }
  if ([kind isEqualToString:@"not_found"]) {
    NSDictionary *result = DSHRuntimeDecide(@{
      @"op" : @"cancel_not_found_result", @"request" : request,
    }, error)[@"output"];
    return result == nil ? nil : settle(result);
  }
  NSDictionary *row = plan[@"row"];
  NSString *rowState = plan[@"state"];
  NSDictionary *updated = nil;
  if ([rowState isEqualToString:@"intent"] ||
      [rowState isEqualToString:@"cancel_requested"]) {
    updated = [self.ledger cancelAgentExecutionWithCAS:DSHRuntimeExecutionCAS(row)
        patch:@{ @"state" : @"cancelled" } error:error][@"row"];
  } else if ([rowState isEqualToString:@"running"]) {
    // Interrupt an in-flight bounded git_push network phase cooperatively.
    [self.executionService requestCancelForExecutionLocator:row[@"locator"]];
    updated = [self.ledger casAgentExecutionWithCAS:DSHRuntimeExecutionCAS(row)
        patch:@{ @"state" : @"cancel_requested" } error:error][@"row"];
  } else {
    return settle(conflict(@"E_AGENT_CANCELLED"));
  }
  if (updated == nil) return nil;
  BOOL dispatched = [[self.wal dispatchStateForKind:@"execution"
                                             locator:updated[@"locator"]
                                               error:nil]
      isEqualToString:@"dispatched"];
  NSDictionary *result = DSHRuntimeDecide(@{
    @"op" : @"cancel_row_result", @"request" : request, @"updated" : updated,
    @"dispatched" : @(dispatched),
  }, error)[@"output"];
  return result == nil ? nil : settle(result);
}

- (NSDictionary *)recoverAgentAttempt:(NSDictionary *)rawRequest
                                  error:(NSError **)error {
  __block NSDictionary *(^awaitRetry)(void) = nil;
  NSDictionary *preparedResult = DSHRuntimeSerializedResult(^NSDictionary *{
  NSDictionary *request = DSHAgentImmutableJSONCopy(rawRequest, error);
  if (request == nil || DSHRuntimeDecide(@{
        @"op" : @"target_request", @"kind" : @"recover", @"request" : request,
      }, error) == nil) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  NSDictionary *target = request[@"target"];
  NSDictionary *controllerCAS = request[@"controller_cas"];
  NSDictionary *checkpoint = request[@"committed_checkpoint"];
  NSString *requestSHA = DSHRuntimeOperationRequestSHA(@"recover_agent_attempt",
                                                       request, error);
  NSDictionary *operationQuery = requestSHA == nil ? nil :
      DSHAgentNativeWALQueryOperation(self.wal, request[@"operation_id"],
          requestSHA, target[@"task_id"], target[@"attempt_id"], error);
  if (operationQuery == nil) return nil;
  BOOL operationFound = [operationQuery[@"status"] isEqualToString:@"found"];
  if (operationFound &&
      ![operationQuery[@"record"][@"state"] isEqualToString:@"started"]) {
    NSDictionary *replay = DSHAgentNativeWALStartTargetOperation(
        self.wal, @"recover_agent_attempt", request, target,
        target[@"task_id"], target[@"attempt_id"],
        operationQuery[@"record"][@"authority_revision"], error);
    return [replay[@"status"] isEqualToString:@"replayed"]
        ? replay[@"result"][@"result"] : nil;
  }
  NSDictionary *sourceProof = DSHRuntimeSessionProof(
      self.preparedStore, controllerCAS[@"conversation_id"],
      target[@"task_id"], target[@"attempt_id"],
      controllerCAS[@"expected_controller_generation"],
      controllerCAS[@"expected_journal_revision"],
      checkpoint[@"session_generation"], checkpoint[@"session_sha256"], error);
  if (sourceProof == nil) return nil;
  NSDictionary *(^conflictWithJournal)(NSString *, id) =
      ^NSDictionary *(NSString *failureCode, id actualJournalRevision) {
    NSMutableDictionary *envelope = [@{
      @"op" : @"target_conflict", @"failure_code" : failureCode,
      @"request" : request, @"proof" : sourceProof, @"with_target" : @NO,
    } mutableCopy];
    if (actualJournalRevision != nil) {
      envelope[@"actual_journal_revision"] = actualJournalRevision;
    }
    NSError *decideError = nil;
    return DSHRuntimeDecide(envelope, &decideError)[@"output"];
  };
  NSDictionary *(^conflict)(NSString *) = ^NSDictionary *(NSString *failureCode) {
    return conflictWithJournal(failureCode, nil);
  };
  if (![sourceProof[@"matches"] boolValue]) {
    if (error != nullptr) *error = nil;
    return conflict(@"E_AGENT_CONFLICT");
  }
  NSDictionary *(^queryAttempt)(NSError **) = ^NSDictionary *(NSError **queryError) {
    return [self queryAgentAttempt:@{
      @"schema_version" : @2, @"controller_cas" : controllerCAS,
      @"task_id" : target[@"task_id"],
      @"conversation_id" : controllerCAS[@"conversation_id"],
      @"attempt_id" : target[@"attempt_id"],
      @"expected_journal_revision" : controllerCAS[@"expected_journal_revision"],
      @"expected_session_generation" : checkpoint[@"session_generation"],
      @"expected_session_sha256" : checkpoint[@"session_sha256"],
      @"expected_transcript" : request[@"expected_transcript"],
      @"expected_root_fingerprint_sha256" : request[@"root"][@"root_fingerprint_sha256"],
      @"expected_workspace_binding_revision" : request[@"root"][@"workspace_binding_revision"],
    } error:queryError];
  };
  NSDictionary *attemptQuery = queryAttempt(error);
  if (attemptQuery == nil) return nil;
  if ([attemptQuery[@"status"] isEqualToString:@"conflict"]) {
    return conflictWithJournal(attemptQuery[@"failure_code"],
                               attemptQuery[@"actual_journal_revision"]);
  }
  NSDictionary *authority = [self.preparedStore
      nativeAuthorityForTaskId:target[@"task_id"]
                     attemptId:target[@"attempt_id"] error:error];
  if (authority == nil) return nil;
  NSDictionary *started = DSHAgentNativeWALStartTargetOperation(
      self.wal, @"recover_agent_attempt", request, target,
      target[@"task_id"], target[@"attempt_id"],
      operationFound ? operationQuery[@"record"][@"authority_revision"]
                     : authority[@"authority_revision"], error);
  if ([started[@"status"] isEqualToString:@"replayed"]) {
    return started[@"result"][@"result"];
  }
  if (started == nil) return nil;
  NSDictionary *(^commitRecovery)(NSDictionary *) =
      ^NSDictionary *(NSDictionary *result) {
    return DSHRuntimeCommitRecoveryResult(self.wal, request, started, result,
                                          error);
  };
  // Every branch ends the same way: ask the attempt query what the attempt
  // looks like now, and commit that beside whatever the branch concluded.
  NSDictionary *(^finishRecovery)(NSDictionary *) =
      ^NSDictionary *(NSDictionary *settled) {
    NSDictionary *attemptQuery = queryAttempt(error);
    if (![attemptQuery[@"attempt"] isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *result = DSHRuntimeDecide(@{
      @"op" : @"recover_result", @"request" : request,
      @"attempt" : attemptQuery[@"attempt"], @"settled" : settled,
    }, error)[@"output"];
    return result == nil ? nil : commitRecovery(result);
  };
  __block NSDictionary *settled = DSHRuntimeDecide(@{
    @"op" : @"recover_initial_outcome", @"attempt_query" : attemptQuery,
  }, error)[@"settled"];
  if (settled == nil) return nil;
  NSString *kind = target[@"kind"];
  if ([kind isEqualToString:@"round"]) {
    NSDictionary *roundRecovery = [self.roundService recoverAgentRoundWithRequest:@{
      @"schema_version" : @2, @"task_id" : target[@"task_id"],
      @"attempt_id" : target[@"attempt_id"], @"round_id" : target[@"round_id"],
      @"round_index" : target[@"round_index"],
      @"expected_round_revision" : request[@"expected_round_revision"],
      @"transcript" : request[@"expected_transcript"], @"root" : request[@"root"],
    } error:error];
    if (roundRecovery == nil) return nil;
    if ([roundRecovery[@"status"] isEqualToString:@"conflict"]) {
      return commitRecovery(
          conflict(roundRecovery[@"failure_code"] ?: @"E_AGENT_CONFLICT"));
    }
    if ([request[@"action"] isEqualToString:@"retry_failed_round"]) {
      NSDictionary *allowed = DSHRuntimeDecide(@{
        @"op" : @"recover_retry_allowed", @"request" : request,
        @"recovery" : roundRecovery,
      }, error);
      if (allowed == nil) return nil;
      if (![allowed[@"allowed"] isEqual:@YES]) {
        return commitRecovery(conflict(@"E_AGENT_CONFLICT"));
      }
      NSDictionary *state = [self.wal snapshotWithError:error];
      if (state == nil) return nil;
      NSDictionary *launch = DSHRuntimeDecide(@{
        @"op" : @"recover_retry_launch_attempt", @"state" : state,
        @"request" : request,
      }, error);
      if (launch == nil) return nil;
      NSString *childOperation = DSHRuntimeChildOperationID(
          request[@"operation_id"], @"retry-round", error);
      if (childOperation == nil) return nil;
      NSDictionary *retryRequest = DSHRuntimeDecide(@{
        @"op" : @"recover_retry_request", @"request" : request,
        @"authority" : authority, @"launch_attempt" : launch[@"launch_attempt"],
        @"child_operation_id" : childOperation,
      }, error)[@"request"];
      if (retryRequest == nil) return nil;
      // Only the provider continuation leaves the serialized recovery authority.
      awaitRetry = ^NSDictionary *{
      NSDictionary *retried = [self.roundService retryFailedAgentRoundV2WithRequest:
          retryRequest error:error];
      return DSHRuntimeSerializedResult(^NSDictionary *{
      if (retried == nil) return nil;
      if ([retried[@"status"] isEqualToString:@"conflict"]) {
        return commitRecovery(
            conflict(retried[@"failure_code"] ?: @"E_AGENT_CONFLICT"));
      }
      NSDictionary *afterRetry = nil;
      if ([retried[@"status"] isEqualToString:@"completed"]) {
        afterRetry = [self.roundService recoverAgentRoundWithRequest:@{
          @"schema_version" : @2, @"task_id" : target[@"task_id"],
          @"attempt_id" : target[@"attempt_id"], @"round_id" : target[@"round_id"],
          @"round_index" : target[@"round_index"],
          @"expected_round_revision" : retried[@"result_round_revision"],
          @"transcript" : request[@"expected_transcript"], @"root" : request[@"root"],
        } error:error];
      }
      NSDictionary *retryOutcome = DSHRuntimeDecide(@{
        @"op" : @"recover_retry_outcome", @"retried" : retried,
        @"after_retry" : afterRetry ?: NSNull.null,
      }, error)[@"settled"];
      return retryOutcome == nil ? nil : finishRecovery(retryOutcome);
      });
      };
      return nil;
    }
    NSDictionary *roundOutcome = DSHRuntimeDecide(@{
      @"op" : @"recover_round_outcome", @"recovery" : roundRecovery,
    }, error)[@"settled"];
    if (roundOutcome == nil) return nil;
    if (roundOutcome != (id)NSNull.null) settled = roundOutcome;
  } else if ([kind isEqualToString:@"tool"]) {
    NSDictionary *state = [self.wal snapshotWithError:error];
    if (state == nil) return nil;
    NSString *toolOperationId = DSHRuntimeChildOperationID(
        request[@"operation_id"], @"recover-tool", error);
    if (toolOperationId == nil) return nil;
    NSDictionary *plan = DSHRuntimeDecide(@{
      @"op" : @"recover_tool_plan", @"state" : state, @"request" : request,
      @"authority" : authority, @"child_operation_id" : toolOperationId,
    }, error);
    if (plan == nil) return nil;
    NSDictionary *toolRequest = plan[@"tool_request"];
    NSDictionary *toolStarted = DSHAgentNativeWALStartOperation(
        self.wal, @"execute_agent_tool", toolRequest, target[@"task_id"],
        target[@"attempt_id"], plan[@"authority_revision"], error);
    if (toolStarted == nil) return nil;
    NSDictionary *toolRecovery = [self.executionService
        recoverAgentToolWithRequest:toolRequest error:error];
    if (toolRecovery == nil) return nil;
    NSDictionary *toolOutcome = DSHRuntimeDecide(@{
      @"op" : @"recover_tool_outcome", @"recovery" : toolRecovery,
    }, error);
    if (toolOutcome == nil) return nil;
    if ([toolOutcome[@"terminal"] isEqual:@YES]) {
      NSDictionary *commit = DSHRuntimeDecide(@{
        @"op" : @"recover_tool_commit", @"request" : request,
        @"started" : toolStarted, @"recovery" : toolRecovery,
        @"child_operation_id" : toolOperationId,
      }, error)[@"commit"];
      if (commit == nil) return nil;
      NSDictionary *toolQuery = DSHAgentNativeWALQueryOperation(
          self.wal, toolOperationId, toolStarted[@"request_sha256"],
          target[@"task_id"], target[@"attempt_id"], error);
      if (toolQuery == nil) return nil;
      if ([toolQuery[@"record"][@"state"] isEqualToString:@"started"]) {
        NSDictionary *committedTool = DSHRuntimeCommitAlone(self.wal, commit, error);
        if (committedTool == nil) return nil;
        toolRecovery = committedTool;
      } else {
        // The child operation already settled: the recovery has to agree with
        // the answer that was committed then, not overwrite it.
        NSDictionary *replayedTool = DSHAgentNativeWALStartOperation(
            self.wal, @"execute_agent_tool", toolRequest, target[@"task_id"],
            target[@"attempt_id"], toolQuery[@"record"][@"authority_revision"],
            error);
        NSDictionary *historicalTool = replayedTool[@"result"][@"result"];
        if (![replayedTool[@"status"] isEqualToString:@"replayed"] ||
            ![historicalTool isEqual:toolRecovery]) {
          DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorConflict);
          return nil;
        }
        toolRecovery = historicalTool;
      }
    }
    if ([toolRecovery[@"status"] isEqualToString:@"conflict"]) {
      return commitRecovery(
          conflict(toolRecovery[@"failure_code"] ?: @"E_AGENT_CONFLICT"));
    }
    settled = DSHRuntimeDecide(@{
      @"op" : @"recover_tool_outcome", @"recovery" : toolRecovery,
    }, error)[@"settled"];
    if (settled == nil) return nil;
  }
  return finishRecovery(settled);
  });
  return awaitRetry == nil ? preparedResult : awaitRetry();
}

- (NSDictionary *)finalizeAgentAttempt:(NSDictionary *)rawRequest
                                   error:(NSError **)error {
  NSDictionary *request = DSHAgentImmutableJSONCopy(rawRequest, error);
  if (request == nil || DSHRuntimeDecide(@{
        @"op" : @"settle_request", @"kind" : @"finalize", @"request" : request,
      }, error) == nil) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  NSString *requestSHA = DSHRuntimeOperationRequestSHA(@"finalize_agent_attempt",
                                                       request, error);
  NSDictionary *operationQuery = requestSHA == nil ? nil :
      DSHAgentNativeWALQueryOperation(self.wal, request[@"operation_id"],
          requestSHA, request[@"task_id"], request[@"attempt_id"], error);
  if (operationQuery == nil) return nil;
  BOOL operationFound = [operationQuery[@"status"] isEqualToString:@"found"];
  if (operationFound &&
      ![operationQuery[@"record"][@"state"] isEqualToString:@"started"]) {
    return DSHRuntimeReplayTerminalOperation(self.wal, @"finalize_agent_attempt",
                                             request, operationQuery, error);
  }
  NSDictionary *checkpoint = request[@"committed_checkpoint"];
  NSDictionary *sourceProof = DSHRuntimeSessionProof(
      self.preparedStore, request[@"conversation_id"], request[@"task_id"],
      request[@"attempt_id"],
      request[@"controller_cas"][@"expected_controller_generation"],
      request[@"controller_cas"][@"expected_journal_revision"],
      checkpoint[@"session_generation"], checkpoint[@"session_sha256"], error);
  if (sourceProof == nil) return nil;
  // A refused finalize still commits its conflict, so a retry sees the same
  // answer instead of racing again — but only once the operation exists.
  NSDictionary *(^refuse)(NSString *) = ^NSDictionary *(NSString *failureCode) {
    if (!operationFound) {
      return @{ @"schema_version" : @2, @"status" : @"conflict",
        @"operation_id" : request[@"operation_id"],
        @"failure_code" : failureCode };
    }
    NSError *commitError = nil;
    NSDictionary *decided = DSHRuntimeDecide(@{
      @"op" : @"finalize_conflict", @"failure_code" : failureCode,
      @"request" : request,
      @"started" : @{ @"request_sha256" :
          operationQuery[@"record"][@"request_sha256"] ?: NSNull.null },
    }, &commitError);
    if (decided == nil) return nil;
    return DSHRuntimeCommitAlone(self.wal, decided[@"commit"], &commitError)
        == nil ? nil : decided[@"output"];
  };
  if (![sourceProof[@"matches"] boolValue]) {
    if (error != nullptr) *error = nil;
    return refuse(@"E_AGENT_CONFLICT");
  }
  if (![self.preparedStore validatePreparedRoot:request[@"root"]
      taskId:request[@"task_id"] attemptId:request[@"attempt_id"] error:error]) {
    if (operationFound && error != nullptr) *error = nil;
    return refuse(@"E_AGENT_ROOT_STALE");
  }
  NSDictionary *authority = [self.preparedStore
      nativeAuthorityForTaskId:request[@"task_id"]
                     attemptId:request[@"attempt_id"] error:error];
  if (authority == nil) return nil;
  NSDictionary *started = DSHAgentNativeWALStartOperation(
      self.wal, @"finalize_agent_attempt", request, request[@"task_id"],
      request[@"attempt_id"],
      operationFound ? operationQuery[@"record"][@"authority_revision"]
                     : authority[@"authority_revision"], error);
  if ([started[@"status"] isEqualToString:@"replayed"]) {
    return started[@"result"][@"result"];
  }
  if (started == nil) return nil;
  __block NSDictionary *output = nil;
  NSError *transactionError = nil;
  BOOL committed = [self.wal performAtomicTransaction:^BOOL(
      NSMutableDictionary *state, NSError **mutationError) {
    NSDictionary *decided = DSHRuntimeDecide(@{
      @"op" : @"finalize_transaction", @"state" : state, @"request" : request,
      @"started" : started, @"timestamp" : [self.wal currentTimestamp],
      @"retention_until" :
          [self.wal currentTimestampAddingInterval:7 * 24 * 60 * 60],
    }, mutationError);
    if (decided == nil) return NO;
    if (![decided[@"result"] isEqualToString:@"settle"]) {
      DSHSetAgentNativeStoreError(
          mutationError,
          (DSHAgentNativeStoreErrorCode)[decided[@"error"] integerValue]);
      return NO;
    }
    DSHRuntimeApplyChanges(state, decided[@"changes"]);
    if (DSHRuntimeCommitInState(state, self.wal, decided[@"commit"],
                                 mutationError) == nil) {
      return NO;
    }
    output = decided[@"output"];
    return YES;
  } error:&transactionError];
  if (committed) {
    if (error != nullptr) *error = nil;
    return output;
  }
  if (transactionError.code == DSHAgentNativeStoreErrorConflict) {
    NSError *commitError = nil;
    NSDictionary *decided = DSHRuntimeDecide(@{
      @"op" : @"finalize_conflict", @"failure_code" : @"E_AGENT_CONFLICT",
      @"request" : request, @"started" : started,
    }, &commitError);
    NSDictionary *conflict = decided == nil ? nil :
        (DSHRuntimeCommitAlone(self.wal, decided[@"commit"], &commitError) == nil
            ? nil : decided[@"output"]);
    if (conflict != nil) {
      if (error != nullptr) *error = nil;
      return conflict;
    }
    if (error != nullptr) *error = commitError ?: transactionError;
    return nil;
  }
  if (error != nullptr) *error = transactionError;
  return nil;
}

- (NSDictionary *)discardAgentAttempt:(NSDictionary *)rawRequest
                                  error:(NSError **)error {
  NSDictionary *request = DSHAgentImmutableJSONCopy(rawRequest, error);
  if (request == nil || DSHRuntimeDecide(@{
        @"op" : @"settle_request", @"kind" : @"discard", @"request" : request,
      }, error) == nil) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  NSString *requestSHA = DSHRuntimeOperationRequestSHA(@"discard_agent_attempt",
                                                       request, error);
  NSDictionary *operationQuery = requestSHA == nil ? nil :
      DSHAgentNativeWALQueryOperation(self.wal, request[@"operation_id"],
          requestSHA, request[@"task_id"], request[@"attempt_id"], error);
  if (operationQuery == nil) return nil;
  if ([operationQuery[@"status"] isEqualToString:@"found"] &&
      ![operationQuery[@"record"][@"state"] isEqualToString:@"started"]) {
    return DSHRuntimeReplayTerminalOperation(self.wal, @"discard_agent_attempt",
                                             request, operationQuery, error);
  }
  return DSHRuntimeSettleResidue(self.wal, self.preparedStore, request,
                                 @"discard_agent_attempt", @"discard", @[],
                                 operationQuery, error);
}

- (NSDictionary *)interruptAgentAttempt:(NSDictionary *)rawRequest
                                    error:(NSError **)error {
  NSDictionary *request = DSHAgentImmutableJSONCopy(rawRequest, error);
  if (request == nil || DSHRuntimeDecide(@{
        @"op" : @"settle_request", @"kind" : @"interrupt", @"request" : request,
      }, error) == nil) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  BOOL present = NO;
  NSDictionary *facts = nil;
  NSDictionary *session = DSHRuntimeLoadSession(self.preparedStore, &facts,
                                                 &present, error);
  NSDictionary *proves = session == nil ? nil : DSHRuntimeReduce(@{
    @"op" : @"interruption_proof", @"session" : session, @"facts" : facts,
    @"request" : request,
  });
  if (![proves[@"proves"] isEqual:@YES]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorConflict);
    return nil;
  }
  NSString *requestSHA = DSHRuntimeOperationRequestSHA(@"interrupt_agent_attempt",
                                                       request, error);
  NSDictionary *operationQuery = requestSHA == nil ? nil :
      DSHAgentNativeWALQueryOperation(self.wal, request[@"operation_id"],
          requestSHA, request[@"task_id"], request[@"attempt_id"], error);
  if (operationQuery == nil) return nil;
  if ([operationQuery[@"status"] isEqualToString:@"found"] &&
      ![operationQuery[@"record"][@"state"] isEqualToString:@"started"]) {
    return DSHRuntimeReplayTerminalOperation(self.wal, @"interrupt_agent_attempt",
                                             request, operationQuery, error);
  }
  return DSHRuntimeSettleResidue(
      self.wal, self.preparedStore, request, @"interrupt_agent_attempt",
      @"interrupt",
      @[ @"undispatched_intents", @"create_cleanup_row", @"unsettled_rounds" ],
      operationQuery, error);
}

- (NSDictionary *)queryAgentCleanup:(NSDictionary *)rawRequest
                                error:(NSError **)error {
  NSDictionary *request = DSHRuntimeRequest(rawRequest,
      @[@"schema_version", @"cleanup_id"], error);
  if (request == nil) return nil;
  NSDictionary *result = [self.transcripts queryAgentTranscriptCleanupWithRequest:@{
    @"schema_version" : @1, @"cleanup_id" : request[@"cleanup_id"],
  } error:error];
  return result == nil ? nil : @{ @"schema_version" : @2,
    @"status" : result[@"status"], @"cleanup_id" : request[@"cleanup_id"] };
}

@end
