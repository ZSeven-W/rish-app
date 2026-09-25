#import "AgentProviderRoundService.h"
#import "AgentProviderRoundServiceInternals.h"
#import "AgentToolRegistry.h"
#import "DSHCompletionV2.h"
#import "DSHWorkspaceCanonical.h"
#import "LocalAttachmentStore.h"
#import "RishHarnessCatalog.h"
#import "SessionWorkspaceCoordinator.h"

#import <os/log.h>

// Authority preparation and result application share the workspace transaction
// queue. The continuation between them owns only the provider wait.
static NSDictionary *DSHProviderSerializedResult(NSDictionary *(^operation)(void)) {
  __block NSDictionary *result = nil;
  DSHSessionWorkspacePerformSync(^{ result = operation(); });
  return result;
}

static const NSUInteger DSHAgentRoundPreviewBudgetBytes = 256 * 1024;
static const NSUInteger DSHAgentRoundPreviewFlushBytes = 32 * 1024;
static const int64_t DSHAgentRoundPreviewCoalesceNanoseconds = 50 * NSEC_PER_MSEC;

/// Coalesces transport deltas of one round into ordered preview events.
/// All state lives on a private serial queue; the sink is invoked from it.
@interface DSHAgentRoundPreviewPublisher : NSObject
@property(nonatomic, copy) DSHAgentProviderRoundPreviewSink sink;
@property(nonatomic, copy) NSDictionary *correlation;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) NSMutableString *pendingText;
@property(nonatomic, strong) NSMutableString *pendingReasoning;
@property(nonatomic, strong) NSMutableArray<NSMutableDictionary *> *pendingCalls;
@property(nonatomic, copy, nullable) NSString *pendingFinish;
@property(nonatomic) NSUInteger pendingBytes;
@property(nonatomic) NSUInteger emittedBytes;
@property(nonatomic) NSUInteger seq;
@property(nonatomic) BOOL scheduled;
@property(nonatomic) BOOL truncated;
@property(nonatomic) BOOL finished;
@end

@implementation DSHAgentRoundPreviewPublisher

- (instancetype)initWithSink:(DSHAgentProviderRoundPreviewSink)sink
                 correlation:(NSDictionary *)correlation {
  self = [super init];
  if (self != nil) {
    _sink = [sink copy];
    _correlation = [correlation copy];
    _queue = dispatch_queue_create("tech.zseven.rish.agent-round-preview",
                                   DISPATCH_QUEUE_SERIAL);
    _pendingText = [NSMutableString string];
    _pendingReasoning = [NSMutableString string];
    _pendingCalls = [NSMutableArray array];
  }
  return self;
}

- (void)emitLocked:(NSDictionary *)fields {
  self.seq += 1;
  NSMutableDictionary *event = [self.correlation mutableCopy];
  event[@"schema_version"] = @1;
  event[@"seq"] = @(self.seq);
  [event addEntriesFromDictionary:fields];
  @try {
    if (self.sink != nil) self.sink([event copy]);
  } @catch (__unused NSException *exception) {
  }
}

- (void)flushLocked {
  if (self.pendingText.length == 0 && self.pendingReasoning.length == 0 &&
      self.pendingCalls.count == 0 && self.pendingFinish == nil) return;
  NSMutableDictionary *fields = [NSMutableDictionary dictionary];
  fields[@"kind"] = @"delta";
  if (self.pendingText.length > 0) fields[@"text"] = [self.pendingText copy];
  if (self.pendingReasoning.length > 0) {
    fields[@"reasoning"] = [self.pendingReasoning copy];
  }
  if (self.pendingCalls.count > 0) {
    NSMutableArray *calls = [NSMutableArray arrayWithCapacity:self.pendingCalls.count];
    for (NSMutableDictionary *call in self.pendingCalls) {
      NSMutableDictionary *fragment = [call mutableCopy];
      NSString *arguments = call[@"arguments"];
      if (arguments.length == 0) [fragment removeObjectForKey:@"arguments"];
      else fragment[@"arguments"] = [arguments copy];
      [calls addObject:[fragment copy]];
    }
    fields[@"tool_calls"] = [calls copy];
  }
  if (self.pendingFinish != nil) fields[@"finish_reason"] = self.pendingFinish;
  [self emitLocked:fields];
  self.emittedBytes += self.pendingBytes;
  self.pendingBytes = 0;
  self.pendingText = [NSMutableString string];
  self.pendingReasoning = [NSMutableString string];
  self.pendingCalls = [NSMutableArray array];
  self.pendingFinish = nil;
}

- (void)appendDelta:(NSDictionary *)delta {
  if (![delta isKindOfClass:NSDictionary.class]) return;
  dispatch_async(self.queue, ^{
    if (self.finished || self.truncated) return;
    NSString *text = [delta[@"content"] isKindOfClass:NSString.class] ? delta[@"content"] : nil;
    NSString *reasoning = [delta[@"reasoning"] isKindOfClass:NSString.class] ? delta[@"reasoning"] : nil;
    NSArray *fragments = [delta[@"tool_calls"] isKindOfClass:NSArray.class] ? delta[@"tool_calls"] : @[];
    NSUInteger bytes = [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] +
        [reasoning lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    for (NSDictionary *fragment in fragments) {
      if ([fragment[@"arguments"] isKindOfClass:NSString.class]) {
        bytes += [fragment[@"arguments"] lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
      }
    }
    if (self.emittedBytes + self.pendingBytes + bytes > DSHAgentRoundPreviewBudgetBytes) {
      // Beyond the preview budget the round keeps validating natively; the
      // end event tells JS the preview stopped short.
      self.truncated = YES;
      [self flushLocked];
      return;
    }
    self.pendingBytes += bytes;
    if (text != nil) [self.pendingText appendString:text];
    if (reasoning != nil) [self.pendingReasoning appendString:reasoning];
    for (NSDictionary *fragment in fragments) {
      if (![fragment isKindOfClass:NSDictionary.class] ||
          ![fragment[@"index"] isKindOfClass:NSNumber.class]) continue;
      NSMutableDictionary *last = self.pendingCalls.lastObject;
      BOOL continues = last != nil && [last[@"index"] isEqual:fragment[@"index"]] &&
          fragment[@"id"] == nil && fragment[@"name"] == nil;
      if (continues) {
        if ([fragment[@"arguments"] isKindOfClass:NSString.class]) {
          last[@"arguments"] = [(last[@"arguments"] ?: @"") stringByAppendingString:fragment[@"arguments"]];
        }
        continue;
      }
      NSMutableDictionary *call = [NSMutableDictionary dictionary];
      call[@"index"] = fragment[@"index"];
      if ([fragment[@"id"] isKindOfClass:NSString.class]) call[@"id"] = fragment[@"id"];
      if ([fragment[@"name"] isKindOfClass:NSString.class]) call[@"name"] = fragment[@"name"];
      if ([fragment[@"arguments"] isKindOfClass:NSString.class]) call[@"arguments"] = fragment[@"arguments"];
      [self.pendingCalls addObject:call];
    }
    if ([delta[@"finish_reason"] isKindOfClass:NSString.class]) {
      self.pendingFinish = delta[@"finish_reason"];
    }
    if (self.pendingBytes >= DSHAgentRoundPreviewFlushBytes) {
      [self flushLocked];
      return;
    }
    if (self.scheduled) return;
    self.scheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, DSHAgentRoundPreviewCoalesceNanoseconds),
                   self.queue, ^{
      self.scheduled = NO;
      if (!self.finished) [self flushLocked];
    });
  });
}

- (void)finishWithStatus:(NSString *)status failureCode:(NSString *)failureCode {
  [self finishWithStatus:status failureCode:failureCode httpStatus:0];
}

- (void)finishWithStatus:(NSString *)status failureCode:(NSString *)failureCode httpStatus:(NSInteger)httpStatus {
  dispatch_sync(self.queue, ^{
    if (self.finished) return;
    [self flushLocked];
    self.finished = YES;
    os_log(OS_LOG_DEFAULT,
           "agent_round_preview status=%{public}@ events=%{public}lu bytes=%{public}lu truncated=%{public}d",
           status ?: @"failed", (unsigned long)self.seq, (unsigned long)self.emittedBytes, self.truncated);
    NSMutableDictionary *fields = [NSMutableDictionary dictionary];
    fields[@"kind"] = @"end";
    fields[@"status"] = status ?: @"failed";
    if ([failureCode isKindOfClass:NSString.class] && failureCode.length > 0) {
      fields[@"failure_code"] = failureCode;
    }
    if (httpStatus >= 100 && httpStatus <= 599) fields[@"http_status"] = @(httpStatus);
    fields[@"truncated"] = @(self.truncated);
    [self emitLocked:fields];
  });
}

@end

@interface DSHAgentProviderRoundService ()
@property(nonatomic, strong, readwrite) DSHAgentNativeWAL *wal;
@property(nonatomic, strong, readwrite) DSHAgentPreparedAttemptStore *preparedStore;
@property(nonatomic, strong, readwrite) DSHAgentTranscriptStore *transcripts;
@property(nonatomic, strong, readwrite) DSHAgentRoundJournal *rounds;
@property(nonatomic, strong, readwrite) DSHCompletionProviderTransport *transport;
@property(nonatomic, strong, readwrite) DSHCompletionProviderTransport *claudeTransport;
@property(nonatomic, strong, readwrite) DSHCompletionProviderTransport *codexTransport;
@property(nonatomic, strong, readwrite) DSHCompletionProviderTransport *glmTransport;
@property(nonatomic, copy) DSHAgentProviderRoundCredentialProvider credentialProvider;
@property(nonatomic, copy) DSHAgentProviderRoundVisibleHistoryProvider visibleHistoryProvider;
@property(nonatomic, copy) DSHAgentProviderRoundContextReceiptProvider contextReceiptProvider;
@property(nonatomic, strong) NSMutableDictionary<NSString *, DSHAgentProviderRoundContext *> *contexts;
@property(nonatomic, strong) NSMutableDictionary<NSString *, DSHCompletionProviderTransport *> *contextTransports;
- (nullable NSDictionary *)commitStartedOperationForRequest:(NSDictionary *)request
                                                 requestSHA:(NSString *)requestSHA
                                                       row:(nullable NSDictionary *)row
                                                     status:(NSString *)status
                                              failureCode:(NSString *)failureCode
                                                     error:(NSError **)error;
- (nullable NSDictionary *)roundProjectionForCompletedRow:(NSDictionary *)row
                                                   request:(NSDictionary *)request
                                                    error:(NSError **)error;
- (nullable NSDictionary *)publicResultForCompletedRow:(NSDictionary *)row
                                                request:(NSDictionary *)request
                                                 error:(NSError **)error;
- (nullable NSDictionary *)completeAgentRoundV2WithRequest:(NSDictionary *)rawRequest
                                                     error:(NSError **)error
                                         retryFailedRound:(BOOL)retryFailedRound;
@end
@implementation DSHAgentProviderRoundService
- (instancetype)initWithWAL:(DSHAgentNativeWAL *)wal
               preparedStore:(DSHAgentPreparedAttemptStore *)preparedStore
                  transcripts:(DSHAgentTranscriptStore *)transcripts
                       rounds:(DSHAgentRoundJournal *)rounds
                    transport:(DSHCompletionProviderTransport *)transport {
  return [self initWithWAL:wal
              preparedStore:preparedStore
                 transcripts:transcripts
                      rounds:rounds
                   transport:transport
            claudeTransport:nil
             codexTransport:nil
        credentialProvider:nil
     visibleHistoryProvider:nil
      contextReceiptProvider:nil];
}
- (instancetype)initWithWAL:(DSHAgentNativeWAL *)wal
                preparedStore:(DSHAgentPreparedAttemptStore *)preparedStore
                   transcripts:(DSHAgentTranscriptStore *)transcripts
                        rounds:(DSHAgentRoundJournal *)rounds
                     transport:(DSHCompletionProviderTransport *)transport
          credentialProvider:(DSHAgentProviderRoundCredentialProvider)credentialProvider
       visibleHistoryProvider:(DSHAgentProviderRoundVisibleHistoryProvider)visibleHistoryProvider {
  return [self initWithWAL:wal
              preparedStore:preparedStore
                 transcripts:transcripts
                      rounds:rounds
                   transport:transport
            claudeTransport:nil
             codexTransport:nil
        credentialProvider:credentialProvider
     visibleHistoryProvider:visibleHistoryProvider
      contextReceiptProvider:nil];
}
- (instancetype)initWithWAL:(DSHAgentNativeWAL *)wal
                preparedStore:(DSHAgentPreparedAttemptStore *)preparedStore
                   transcripts:(DSHAgentTranscriptStore *)transcripts
                        rounds:(DSHAgentRoundJournal *)rounds
                     transport:(DSHCompletionProviderTransport *)transport
          credentialProvider:(DSHAgentProviderRoundCredentialProvider)credentialProvider
       visibleHistoryProvider:(DSHAgentProviderRoundVisibleHistoryProvider)visibleHistoryProvider
       contextReceiptProvider:(DSHAgentProviderRoundContextReceiptProvider)contextReceiptProvider {
  return [self initWithWAL:wal
              preparedStore:preparedStore
                 transcripts:transcripts
                      rounds:rounds
                   transport:transport
            claudeTransport:nil
             codexTransport:nil
        credentialProvider:credentialProvider
     visibleHistoryProvider:visibleHistoryProvider
      contextReceiptProvider:contextReceiptProvider];
}

- (instancetype)initWithWAL:(DSHAgentNativeWAL *)wal
                preparedStore:(DSHAgentPreparedAttemptStore *)preparedStore
                   transcripts:(DSHAgentTranscriptStore *)transcripts
                        rounds:(DSHAgentRoundJournal *)rounds
                     transport:(DSHCompletionProviderTransport *)transport
              claudeTransport:(DSHCompletionProviderTransport *)claudeTransport
               codexTransport:(DSHCompletionProviderTransport *)codexTransport
          credentialProvider:(DSHAgentProviderRoundCredentialProvider)credentialProvider
       visibleHistoryProvider:(DSHAgentProviderRoundVisibleHistoryProvider)visibleHistoryProvider
       contextReceiptProvider:(DSHAgentProviderRoundContextReceiptProvider)contextReceiptProvider {
  return [self initWithWAL:wal
              preparedStore:preparedStore
                 transcripts:transcripts
                      rounds:rounds
                   transport:transport
            claudeTransport:claudeTransport
             codexTransport:codexTransport
               glmTransport:nil
        credentialProvider:credentialProvider
     visibleHistoryProvider:visibleHistoryProvider
      contextReceiptProvider:contextReceiptProvider];
}

- (instancetype)initWithWAL:(DSHAgentNativeWAL *)wal
                preparedStore:(DSHAgentPreparedAttemptStore *)preparedStore
                   transcripts:(DSHAgentTranscriptStore *)transcripts
                        rounds:(DSHAgentRoundJournal *)rounds
                     transport:(DSHCompletionProviderTransport *)transport
              claudeTransport:(DSHCompletionProviderTransport *)claudeTransport
               codexTransport:(DSHCompletionProviderTransport *)codexTransport
                 glmTransport:(DSHCompletionProviderTransport *)glmTransport
          credentialProvider:(DSHAgentProviderRoundCredentialProvider)credentialProvider
       visibleHistoryProvider:(DSHAgentProviderRoundVisibleHistoryProvider)visibleHistoryProvider
       contextReceiptProvider:(DSHAgentProviderRoundContextReceiptProvider)contextReceiptProvider {
  self = [super init];
  if (self != nil) {
    _wal = wal;
    _preparedStore = preparedStore;
    _transcripts = transcripts;
    _rounds = rounds;
    _transport = transport;
    _claudeTransport = claudeTransport;
    _codexTransport = codexTransport;
    _glmTransport = glmTransport;
    _credentialProvider = [credentialProvider copy];
    _visibleHistoryProvider = [visibleHistoryProvider copy];
    _attachmentResolver = DSHDefaultAttachmentResolver();
    _contextReceiptProvider = [contextReceiptProvider copy];
    _contexts = [NSMutableDictionary dictionary];
    _contextTransports = [NSMutableDictionary dictionary];
  }
  return self;
}

- (nullable DSHCompletionProviderTransport *)transportForRequest:(NSDictionary *)request {
  id rawHarness = request[@"harness_id"];
  if (rawHarness != nil && ![rawHarness isKindOfClass:NSString.class]) return nil;
  NSString *harnessId = rawHarness ?: @"dsh";
  if (![DSHHarnessIdForModel(request[@"model"]) isEqual:harnessId]) return nil;
  DSHCompletionProviderTransport *selected = self.transportResolver == nil
      ? nil : self.transportResolver(harnessId);
  if (self.transportResolver == nil) {
    if ([harnessId isEqualToString:@"dsh"]) selected = self.transport;
    else if ([harnessId isEqualToString:@"claude-code"]) selected = self.claudeTransport;
    else if ([harnessId isEqualToString:@"codex"]) selected = self.codexTransport;
    else if ([harnessId isEqualToString:@"glm"]) selected = self.glmTransport;
  }
  if (selected == nil ||
      ![[selected providerHarnessId] isEqual:harnessId] ||
      ![selected providerSupportsModel:request[@"model"]]) return nil;
  return selected;
}

- (nullable NSDictionary *)commitStartedOperationForRequest:(NSDictionary *)request
                                                 requestSHA:(NSString *)requestSHA
                                                       row:(nullable NSDictionary *)row
                                                     status:(NSString *)status
                                              failureCode:(NSString *)failureCode
                                                     error:(NSError **)error {
  NSDictionary *commit = DSHProviderStartedOperationCommit(request, requestSHA,
                                                            row, status,
                                                            failureCode);
  if (commit == nil) {
    DSHSetProviderError(error, DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  id revision = commit[@"result_revision"];
  return DSHAgentNativeWALCommitOperation(
      self.wal, commit[@"operation_id"], commit[@"request_sha256"],
      commit[@"task_id"], commit[@"attempt_id"], commit[@"terminal_state"],
      commit[@"result_status"], commit[@"result_ref"],
      revision == NSNull.null ? nil : revision, commit[@"safe_result"], error);
}

- (nullable NSDictionary *)publicResultForCompletedRow:(NSDictionary *)row
                                                request:(NSDictionary *)request
                                                 error:(NSError **)error {
  NSDictionary *round = [self roundProjectionForCompletedRow:row
                                                       request:request
                                                        error:error];
  if (round == nil) return nil;
  NSDictionary *result = DSHProviderPublicResult(request, row, round);
  if (result == nil) DSHSetProviderError(error, DSHAgentNativeStoreErrorCorrupt);
  return result;
}

- (nullable NSDictionary *)roundProjectionForCompletedRow:(NSDictionary *)row
                                                   request:(NSDictionary *)request
                                                    error:(NSError **)error {
  NSDictionary *after = row[@"transcript_after"];
  if (![after isKindOfClass:NSDictionary.class] || self.transcripts == nil) {
    DSHSetProviderError(error, DSHAgentNativeStoreErrorConflict);
    return nil;
  }
  NSArray *messages = [self.transcripts
      nativeMessagesForTranscriptWithRequest:@{
        @"schema_version" : @1,
        @"attempt_id" : request[@"attempt_id"],
        @"root" : request[@"root"],
        @"transcript" : after,
      }
      error:error];
  if (messages == nil) return nil;
  return DSHProviderRecoveredRoundProjection(row, request, messages, error);
}

- (nullable NSDictionary *)completeAgentRoundV2WithRequest:(NSDictionary *)rawRequest
                                                     error:(NSError **)error {
  return [self completeAgentRoundV2WithRequest:rawRequest
                                          error:error
                              retryFailedRound:NO];
}

- (nullable NSDictionary *)retryFailedAgentRoundV2WithRequest:(NSDictionary *)rawRequest
                                                         error:(NSError **)error {
  return [self completeAgentRoundV2WithRequest:rawRequest
                                          error:error
                              retryFailedRound:YES];
}

- (nullable NSDictionary *)completeAgentRoundV2WithRequest:(NSDictionary *)rawRequest
                                                     error:(NSError **)error
                                         retryFailedRound:(BOOL)retryFailedRound {
  __block NSDictionary *(^awaitProvider)(void) = nil;
  NSDictionary *preparedResult = DSHProviderSerializedResult(^NSDictionary *{
  NSError *requestError = nil;
  NSDictionary *request = DSHProviderRoundRequestCopy(rawRequest, &requestError);
  if (request == nil || ![DSHAgentRootResolver
                             validateAgentRootProjection:request[@"root"]
                                                    error:&requestError]) {
    if (error != nullptr) *error = requestError ?: DSHAgentNativeStoreError(
        DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  // Operation replay is deliberately resolved before touching the injected
  // history provider, protected transcript, credential provider, or body
  // builder. A started record may be promoted only when the journal and
  // protected transcript prove a completed round; otherwise it remains an
  // unknown recovery case and is never treated as provider success.
  __block NSError *operationError = nil;
  NSString *requestSHA = DSHAgentHJ(@"agent-operation-request", @{
    @"operation_kind" : @"complete_agent_round_v2",
    @"request" : request,
  }, &operationError);
  if (requestSHA == nil) {
    if (error != nullptr) *error = operationError;
    return nil;
  }
  NSDictionary *operationQuery = DSHAgentNativeWALQueryOperation(
      self.wal, request[@"operation_id"], requestSHA, request[@"task_id"],
      request[@"attempt_id"], &operationError);
  if (operationQuery == nil) {
    if (error != nullptr) *error = operationError;
    return nil;
  }
  if ([operationQuery[@"status"] isEqualToString:@"conflict"]) {
    if (error != nullptr) *error = nil;
    return DSHProviderConflictResult(
        request[@"operation_id"], @"E_AGENT_CONFLICT", request,
        request[@"expected_round_revision"], @"in_flight", request[@"transcript"]);
  }
  if ([operationQuery[@"status"] isEqualToString:@"found"] &&
      [operationQuery[@"record"][@"state"] isEqualToString:@"started"]) {
    NSDictionary *roundQuery = self.rounds == nil ? nil :
        [self.rounds queryAgentRoundV3WithLocator:DSHProviderRoundLocator(request)
                                             error:nil];
    NSDictionary *roundRow = roundQuery[@"row"];
    if ([roundRow[@"state"] isEqualToString:@"completed"]) {
      NSError *recoveryError = nil;
      NSDictionary *recovered = [self publicResultForCompletedRow:roundRow
                                                           request:request
                                                              error:&recoveryError];
      if (recovered != nil) {
        NSDictionary *safeResult = DSHProviderOperationSafeResult(recovered);
        NSDictionary *resultRef = @{
          @"schema_version" : @2, @"kind" : @"round",
          @"task_id" : request[@"task_id"],
          @"attempt_id" : request[@"attempt_id"],
          @"round_id" : request[@"round_id"],
          @"round_index" : request[@"round_index"],
          @"round_revision" : roundRow[@"row_revision"],
        };
        NSDictionary *committed = DSHAgentNativeWALCommitOperation(
            self.wal, request[@"operation_id"], requestSHA,
            request[@"task_id"], request[@"attempt_id"], @"committed",
            @"completed", resultRef, roundRow[@"row_revision"], safeResult,
            &recoveryError);
        if (committed != nil) {
          if (error != nullptr) *error = nil;
          return recovered;
        }
      }
    }
    BOOL ownerAlive = [roundRow[@"owner"] isKindOfClass:NSDictionary.class] &&
        [self.wal isNativeTaskAlive:roundRow[@"owner"][@"native_task_id"]
                             launchId:roundRow[@"owner"][@"launch_id"]];
    BOOL knownTerminalRow = [roundRow[@"state"] isEqualToString:@"failed_retryable"] ||
        [roundRow[@"state"] isEqualToString:@"cancelled"] ||
        [roundRow[@"state"] isEqualToString:@"unknown"] ||
        [roundRow[@"state"] isEqualToString:@"ambiguous"] ||
        ([roundRow[@"state"] isEqualToString:@"completed"] && !ownerAlive);
    if (knownTerminalRow) {
      NSString *operationStatus = [roundRow[@"state"] isEqualToString:@"ambiguous"]
          ? @"ambiguous" : @"unknown";
      NSString *failureCode = [roundRow[@"state"] isEqualToString:@"cancelled"]
          ? @"E_AGENT_CANCELLED"
          : ([roundRow[@"state"] isEqualToString:@"failed_retryable"] ||
             [roundRow[@"state"] isEqualToString:@"unknown"]
                 ? @"E_AGENT_PERSISTENCE" : @"E_AGENT_ROUND_AMBIGUOUS");
      NSError *commitError = nil;
      NSDictionary *committed = [self
          commitStartedOperationForRequest:request
                               requestSHA:requestSHA
                                     row:roundRow
                                   status:operationStatus
                            failureCode:failureCode
                                   error:&commitError];
      if (committed != nil) {
        if (error != nullptr) *error = nil;
        return DSHProviderRoundResultForRow(
            request, roundRow, operationStatus, failureCode);
      }
    }
    if (error != nullptr) *error = nil;
    return DSHProviderUnknownResult(
        request, @"unknown", [request[@"expected_round_revision"] unsignedIntegerValue],
        @"E_AGENT_ROUND_AMBIGUOUS");
  }
  if ([operationQuery[@"status"] isEqualToString:@"found"]) {
    NSError *replayError = nil;
    NSDictionary *replayEnvelope = DSHAgentNativeWALStartOperation(
        self.wal, @"complete_agent_round_v2", request, request[@"task_id"],
        request[@"attempt_id"], operationQuery[@"record"][@"authority_revision"],
        &replayError);
    NSDictionary *safeEnvelope = replayEnvelope[@"result"];
    NSDictionary *replayed = [safeEnvelope isKindOfClass:NSDictionary.class]
        ? safeEnvelope[@"result"] : nil;
    if ([replayEnvelope[@"status"] isEqualToString:@"replayed"] &&
        [replayed isKindOfClass:NSDictionary.class]) {
      if (error != nullptr) *error = nil;
      return replayed;
    }
    if (error != nullptr) *error = replayError ?: DSHAgentNativeStoreError(
        DSHAgentNativeStoreErrorPersistence);
    return nil;
  }
  NSError *authorityError = nil;
  NSDictionary *authority = [self.preparedStore nativeAuthorityForTaskId:
      request[@"task_id"] attemptId:request[@"attempt_id"] error:&authorityError];
  if (authority == nil ||
      ![authority[@"task_id"] isEqual:request[@"task_id"]] ||
      ![authority[@"conversation_id"] isEqual:request[@"conversation_id"]] ||
      ![authority[@"attempt_id"] isEqual:request[@"attempt_id"]] ||
      ![authority[@"root"] isEqual:request[@"root"]] ||
      ![authority[@"transcript"] isEqual:request[@"transcript"]] ||
      ![authority[@"transport_schema_version"]
          isEqual:request[@"transport_schema_version"]] ||
      ![authority[@"project_context_sha256"]
          isEqual:request[@"project_context_sha256"]] ||
      ![authority[@"registry"][@"registry_version"]
          isEqual:request[@"registry_version"]] ||
      ![authority[@"registry"][@"toolset_sha256"]
          isEqual:request[@"toolset_sha256"]] ||
      ![authority[@"model"] isEqual:request[@"model"]] ||
      ![authority[@"thinking_mode"] isEqual:request[@"thinking_mode"]] ||
      ![authority[@"visible_history_sha256"]
          isEqual:request[@"visible_history_sha256"]] ||
      ![authority[@"visible_message_count"]
          isEqual:request[@"visible_message_count"]]) {
    if (error != nullptr) *error = nil;
    return DSHProviderConflictResult(
        request[@"operation_id"], @"E_AGENT_CONFLICT", request,
        request[@"expected_round_revision"], @"in_flight", request[@"transcript"]);
  }
  NSError *rootError = nil;
  if (![self.preparedStore validatePreparedRoot:request[@"root"]
                                         taskId:request[@"task_id"]
                                      attemptId:request[@"attempt_id"]
                                           error:&rootError]) {
    if (error != nullptr) *error = nil;
    return DSHProviderConflictResult(
        request[@"operation_id"], @"E_AGENT_ROOT_STALE", request,
        request[@"expected_round_revision"], @"in_flight", request[@"transcript"]);
  }
  NSDictionary *contextReceipt = nil;
  NSArray *contextMessages = @[];
  if ([request[@"transport_schema_version"] isEqual:@3]) {
    NSError *contextError = nil;
    NSDictionary *contextBundle = nil;
    @try {
      contextBundle = self.contextReceiptProvider == nil
          ? nil : self.contextReceiptProvider(authority, &contextError);
    } @catch (__unused NSException *exception) {
      contextReceipt = nil;
    }
    if (!DSHProviderContextBundle(contextBundle,
                                  request[@"project_context_sha256"],
                                  &contextReceipt, &contextMessages,
                                  &contextError)) {
      if (error != nullptr) *error = contextError ?: DSHAgentNativeStoreError(
          DSHAgentNativeStoreErrorConflict);
      return nil;
    }
  }
  NSDictionary *operationStart = DSHAgentNativeWALStartOperation(
      self.wal, @"complete_agent_round_v2", request, request[@"task_id"],
      request[@"attempt_id"], authority[@"authority_revision"], &operationError);
  if (operationStart == nil) {
    if (error != nullptr) *error = operationError;
    return nil;
  }
  if ([operationStart[@"status"] isEqualToString:@"replayed"]) {
    NSDictionary *safeEnvelope = operationStart[@"result"];
    NSDictionary *replayed = [safeEnvelope isKindOfClass:NSDictionary.class]
        ? safeEnvelope[@"result"] : nil;
    if ([replayed isKindOfClass:NSDictionary.class]) {
      if (error != nullptr) *error = nil;
      return replayed;
    }
    DSHSetProviderError(error, DSHAgentNativeStoreErrorPersistence);
    return nil;
  }
  NSString *harnessId = [request[@"harness_id"] isKindOfClass:NSString.class]
      ? request[@"harness_id"] : @"dsh";
  DSHCompletionProviderTransport *providerTransport =
      [self transportForRequest:request];
  if (self.visibleHistoryProvider == nil || providerTransport == nil ||
      self.rounds == nil || self.transcripts == nil) {
    NSError *commitError = nil;
    if ([self commitStartedOperationForRequest:request
                                     requestSHA:requestSHA
                                           row:nil
                                         status:@"ambiguous"
                                  failureCode:@"E_AGENT_PERSISTENCE"
                                         error:&commitError] == nil) {
      DSHSetProviderError(error, DSHAgentNativeStoreErrorPersistence);
      return nil;
    }
    DSHSetProviderError(error, DSHAgentNativeStoreErrorUnavailable);
    return nil;
  }
  NSError *historyError = nil;
  NSArray *visibleHistory = nil;
  @try {
    visibleHistory = self.visibleHistoryProvider(authority, &historyError);
  } @catch (__unused NSException *exception) {
    visibleHistory = nil;
  }
  if (![visibleHistory isKindOfClass:NSArray.class]) {
    NSError *commitError = nil;
    if ([self commitStartedOperationForRequest:request
                                     requestSHA:requestSHA
                                           row:nil
                                         status:@"ambiguous"
                                  failureCode:@"E_AGENT_PERSISTENCE"
                                         error:&commitError] == nil) {
      if (error != nullptr) *error = commitError ?: DSHAgentNativeStoreError(
          DSHAgentNativeStoreErrorPersistence);
      return nil;
    }
    if (error != nullptr) *error = historyError ?: DSHAgentNativeStoreError(
        DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  NSError *visibleDigestError = nil;
  NSString *visibleHistoryDigest = DSHAgentHJ(
      @"visible-history", @{ @"messages" : visibleHistory }, &visibleDigestError);
  if (visibleHistoryDigest == nil ||
      ![visibleHistoryDigest isEqual:request[@"visible_history_sha256"]] ||
      ![visibleHistoryDigest isEqual:authority[@"visible_history_sha256"]]) {
    NSError *commitError = nil;
    if ([self commitStartedOperationForRequest:request
                                     requestSHA:requestSHA
                                           row:nil
                                         status:@"conflict"
                                  failureCode:@"E_AGENT_CONFLICT"
                                         error:&commitError] == nil) {
      if (error != nullptr) *error = commitError ?: DSHAgentNativeStoreError(
          DSHAgentNativeStoreErrorPersistence);
      return nil;
    }
    if (error != nullptr) *error = nil;
    return DSHProviderConflictResult(
        request[@"operation_id"], @"E_AGENT_CONFLICT", request,
        request[@"expected_round_revision"], @"in_flight", request[@"transcript"]);
  }
  NSError *transcriptError = nil;
  NSArray *nativeMessages = [self.transcripts
      nativeMessagesForTranscriptWithRequest:@{
        @"schema_version" : @1,
        @"attempt_id" : request[@"attempt_id"],
        @"root" : request[@"root"],
        @"transcript" : request[@"transcript"],
      }
      error:&transcriptError];
  if (nativeMessages == nil) {
    NSError *commitError = nil;
    if ([self commitStartedOperationForRequest:request
                                     requestSHA:requestSHA
                                           row:nil
                                         status:@"ambiguous"
                                  failureCode:@"E_AGENT_TRANSCRIPT"
                                         error:&commitError] == nil) {
      if (error != nullptr) *error = commitError ?: DSHAgentNativeStoreError(
          DSHAgentNativeStoreErrorPersistence);
      return nil;
    }
    if (error != nullptr) *error = transcriptError ?: DSHAgentNativeStoreError(
        DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  NSArray *priorTranscript = DSHProviderTranscriptForBody(
      nativeMessages, [request[@"round_index"] unsignedIntegerValue],
      request[@"thinking_mode"], &transcriptError);
  if (priorTranscript == nil) {
    NSError *commitError = nil;
    if ([self commitStartedOperationForRequest:request
                                     requestSHA:requestSHA
                                           row:nil
                                         status:@"ambiguous"
                                  failureCode:@"E_AGENT_TRANSCRIPT"
                                         error:&commitError] == nil) {
      if (error != nullptr) *error = commitError ?: DSHAgentNativeStoreError(
          DSHAgentNativeStoreErrorPersistence);
      return nil;
    }
    if (error != nullptr) *error = transcriptError ?: DSHAgentNativeStoreError(
        DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  // What the model is shown of the conversation, with each attachment turned
  // into what it actually carries. The visible history holds references only
  // -- that is what the transcript keeps and what its digest above binds --
  // and the request builder reads a message's `content` and ignores its
  // `attachments`, so passing the history straight through dropped every
  // image attached to an Agent turn and the model answered about a picture
  // it was never shown. The chat path has always projected; this is the
  // same projection, not a second one.
  NSError *attachmentError = nil;
  NSArray *projectedHistory = DSHProjectHistoryAttachments(
      visibleHistory, request[@"model"], self.attachmentResolver,
      &attachmentError);
  if (projectedHistory == nil) {
    // Nothing has been claimed or dispatched yet -- on this platform the
    // round row is created further down -- so this is a refusal and not an
    // ambiguity: the request never left the device, and it will not succeed
    // unchanged. The operation record says `rejected`, which is the one
    // honest word the log has for a request refused before it existed; the
    // cause travels as a code the bridge reports verbatim, so the person is
    // told what to change.
    //
    // Known gap, shared with every other failure above this point: the
    // controller's round-result vocabulary has no `rejected`, so a replay of
    // this exact operation would not validate there. The live answer below
    // is what a person sees.
    NSError *commitError = nil;
    if ([self commitStartedOperationForRequest:request
                                     requestSHA:requestSHA
                                           row:nil
                                         status:@"rejected"
                                  failureCode:@"E_AGENT_CAPABILITY"
                                         error:&commitError] == nil) {
      if (error != nullptr) *error = commitError ?: DSHAgentNativeStoreError(
          DSHAgentNativeStoreErrorPersistence);
      return nil;
    }
    if (error != nullptr) {
      NSError *base = DSHAgentNativeStoreError(DSHAgentNativeStoreErrorInvalidArgument);
      NSMutableDictionary *info = [base.userInfo mutableCopy] ?: [NSMutableDictionary dictionary];
      info[@"code"] = @"E_AGENT_CAPABILITY";
      *error = [NSError errorWithDomain:base.domain code:base.code userInfo:info];
    }
    return nil;
  }
  NSMutableArray *messages = [NSMutableArray arrayWithArray:contextMessages];
  [messages addObjectsFromArray:projectedHistory];
  [messages addObjectsFromArray:priorTranscript];
  NSError *toolsError = nil;
  NSArray *tools = ![providerTransport supportsTools] ? @[] : DSHProviderToolsForAuthority(
      authority, self.preparedStore.toolRegistry, &toolsError);
  NSError *bodyBuildError = nil;
  DSHAgentProviderRoundPreviewSink previewSink = self.previewSink;
  BOOL streamRound = previewSink != nil &&
      [providerTransport providerSupportsStreamingRounds];
  NSDictionary *body = tools == nil ? nil : [providerTransport
      providerRequestBodyForModel:request[@"model"]
                     thinkingMode:request[@"thinking_mode"]
                         messages:messages
                            tools:tools
                        streaming:streamRound
                            error:&bodyBuildError];
  if (body == nil && bodyBuildError != nil) toolsError = bodyBuildError;
  NSData *bodyData = body == nil ? nil : [NSJSONSerialization
      dataWithJSONObject:body options:NSJSONWritingSortedKeys error:&toolsError];
  if (bodyData == nil || bodyData.length == 0 || bodyData.length > 40 * 1024 * 1024) {
    NSError *commitError = nil;
    if ([self commitStartedOperationForRequest:request
                                     requestSHA:requestSHA
                                           row:nil
                                         status:@"ambiguous"
                                  failureCode:@"E_AGENT_TRANSCRIPT"
                                         error:&commitError] == nil) {
      if (error != nullptr) *error = commitError ?: DSHAgentNativeStoreError(
          DSHAgentNativeStoreErrorPersistence);
      return nil;
    }
    if (error != nullptr) *error = toolsError ?: DSHAgentNativeStoreError(
        DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  // The provider transport hashes the model-input array it receives.  Pass
  // the actual provider messages (visible history plus protected prior tool
  // rounds), never a metadata-only surrogate.
  NSArray *modelInput = [messages copy];
  NSString *actualVisibleTransportDigest = DSHProviderJSONSHA256(
      visibleHistory, &toolsError);
  NSString *actualModelInputDigest = DSHProviderJSONSHA256(modelInput, &toolsError);
  NSString *actualBodyDigest = DSHWorkspaceSHA256Hex(bodyData);
  if (!DSHProviderDigest(actualVisibleTransportDigest) ||
      !DSHProviderDigest(actualModelInputDigest) ||
      !DSHProviderDigest(actualBodyDigest)) {
    NSError *commitError = nil;
    if ([self commitStartedOperationForRequest:request
                                     requestSHA:requestSHA
                                           row:nil
                                         status:@"ambiguous"
                                  failureCode:@"E_AGENT_TRANSCRIPT"
                                         error:&commitError] == nil) {
      if (error != nullptr) *error = commitError ?: DSHAgentNativeStoreError(
          DSHAgentNativeStoreErrorPersistence);
      return nil;
    }
    if (error != nullptr) *error = toolsError ?: DSHAgentNativeStoreError(
        DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  NSDictionary *locator = DSHProviderRoundLocator(request);
  NSDictionary *retryRow = nil;
  if (retryFailedRound) {
    NSDictionary *retryQuery = [self.rounds
        queryAgentRoundV3WithLocator:locator error:&operationError];
    retryRow = retryQuery[@"row"];
    NSUInteger previousLaunchAttempt = [retryRow[@"launch_attempt"] unsignedIntegerValue];
    BOOL retryShape = [retryRow isKindOfClass:NSDictionary.class] &&
        [retryRow[@"state"] isEqualToString:@"failed_retryable"] &&
        [retryRow[@"row_revision"] isEqual:request[@"expected_round_revision"]] &&
        previousLaunchAttempt < 8 &&
        [request[@"launch_attempt"] unsignedIntegerValue] ==
            previousLaunchAttempt + 1;
    if (!retryShape) {
      NSDictionary *conflict = DSHProviderConflictResult(
          request[@"operation_id"], @"E_AGENT_CONFLICT", request,
          retryRow[@"row_revision"] ?: @0,
          retryRow[@"state"] ?: @"unknown",
          (id)retryRow[@"transcript_after"] == NSNull.null
              ? retryRow[@"transcript_before"] : retryRow[@"transcript_after"]);
      NSError *commitError = nil;
      if ([self commitStartedOperationForRequest:request
                                       requestSHA:requestSHA
                                             row:retryRow
                                           status:@"conflict"
                                    failureCode:@"E_AGENT_CONFLICT"
                                           error:&commitError] == nil) {
        if (error != nullptr) *error = commitError ?: DSHAgentNativeStoreError(
            DSHAgentNativeStoreErrorPersistence);
        return nil;
      }
      if (error != nullptr) *error = nil;
      return conflict;
    }
  }
  NSString *nativeTaskId = NSUUID.UUID.UUIDString.lowercaseString;
  if (![self.wal registerNativeTaskId:nativeTaskId error:&operationError]) {
    NSError *commitError = nil;
    (void)[self commitStartedOperationForRequest:request
                                        requestSHA:requestSHA
                                              row:nil
                                            status:@"ambiguous"
                                     failureCode:@"E_AGENT_PERSISTENCE"
                                            error:&commitError];
    if (error != nullptr) *error = operationError;
    return nil;
  }
  NSDictionary *owner = DSHProviderOwner(self.wal, request[@"task_id"], nativeTaskId);
  NSDictionary *persistedRow = nil;
  if (retryFailedRound) {
    NSDictionary *claimed = [self.rounds
        claimAgentRoundV3WithLocator:locator
                 expectedRowRevision:retryRow[@"row_revision"]
                                owner:owner
                                error:&operationError];
    if (claimed == nil) {
      NSError *commitError = nil;
      NSString *status = operationError.code == DSHAgentNativeStoreErrorConflict
          ? @"conflict" : @"ambiguous";
      NSString *failure = [status isEqualToString:@"conflict"]
          ? @"E_AGENT_CONFLICT" : @"E_AGENT_PERSISTENCE";
      (void)[self commitStartedOperationForRequest:request
                                          requestSHA:requestSHA
                                                row:[status isEqualToString:@"conflict"]
                                                    ? retryRow : nil
                                              status:status
                                       failureCode:failure
                                              error:&commitError];
      [self.wal unregisterNativeTaskId:nativeTaskId error:nil];
      if ([status isEqualToString:@"conflict"]) {
        if (error != nullptr) *error = nil;
        return DSHProviderConflictResult(
            request[@"operation_id"], failure, request,
            retryRow[@"row_revision"] ?: @0,
            retryRow[@"state"] ?: @"unknown",
            (id)retryRow[@"transcript_after"] == NSNull.null
                ? retryRow[@"transcript_before"] : retryRow[@"transcript_after"]);
      }
      if (error != nullptr) *error = operationError ?: DSHAgentNativeStoreError(
          DSHAgentNativeStoreErrorPersistence);
      return nil;
    }
    persistedRow = claimed[@"row"];
  } else {
    NSString *now = self.wal.currentTimestamp;
    NSDictionary *round = @{
      @"schema_version" : @3,
      @"locator" : locator,
      @"row_revision" : @1,
      @"root_fingerprint_sha256" : request[@"root"][@"root_fingerprint_sha256"],
      @"binding_revision" : request[@"root"][@"workspace_binding_revision"],
      @"request_sha256" : requestSHA,
      @"transcript_before" : request[@"transcript"],
      @"launch_attempt" : request[@"launch_attempt"],
      @"state" : @"in_flight",
      @"owner" : owner,
      @"failure_code" : NSNull.null,
      @"completion_receipt" : NSNull.null,
      @"transcript_after" : NSNull.null,
      @"calls" : @[],
      @"batch_class" : NSNull.null,
      @"executable_call_count" : @0,
      @"denied_call_count" : @0,
      @"terminal_kind" : NSNull.null,
      @"created_at" : now,
      @"updated_at" : now,
    };
    NSDictionary *insertCAS = @{
      @"schema_version" : @1,
      @"locator" : locator,
      @"expected_absent" : @YES,
      @"expected_transcript_generation" : request[@"transcript"][@"generation"],
      @"expected_transcript_sha256" : request[@"transcript"][@"transcript_sha256"],
      @"expected_root_fingerprint_sha256" : request[@"root"][@"root_fingerprint_sha256"],
      @"expected_binding_revision" : request[@"root"][@"workspace_binding_revision"],
    };
    NSDictionary *created = [self.rounds createAgentRoundV3WithInsertCAS:insertCAS
                                                            exactRoundStart:round
                                                                      error:&operationError];
    if (created == nil) {
      NSError *commitError = nil;
      (void)[self commitStartedOperationForRequest:request
                                          requestSHA:requestSHA
                                                row:nil
                                              status:@"ambiguous"
                                       failureCode:@"E_AGENT_PERSISTENCE"
                                              error:&commitError];
      [self.wal unregisterNativeTaskId:nativeTaskId error:nil];
      if (error != nullptr) *error = operationError;
      return nil;
    }
    persistedRow = created[@"row"];
  }
  NSDictionary *dispatchCAS = DSHProviderRoundCASForRow(persistedRow);
  NSError *credentialError = nil;
  NSUInteger credentialGeneration = 0;
  NSString *credential = nil;
  BOOL transportCurrent = YES;
  if (self.transportResolver != nil) {
    @try {
      transportCurrent = self.transportResolver(harnessId) == providerTransport;
    } @catch (__unused NSException *exception) {
      transportCurrent = NO;
    }
  }
  @try {
    credential = transportCurrent && self.credentialProvider != nil
        ? self.credentialProvider(harnessId, &credentialGeneration) : nil;
  } @catch (__unused NSException *exception) {
    credential = nil;
  }
  if (!transportCurrent || ![providerTransport isReadyWithCredential:credential]) {
    // No provider request was dispatched; proof-gated cancellation is safe.
    NSDictionary *cancelled = [self.rounds cancelAgentRoundV3WithCAS:dispatchCAS
                                                                  error:&credentialError];
    NSError *commitError = nil;
    NSDictionary *row = cancelled[@"row"] ?: persistedRow;
    if ([self commitStartedOperationForRequest:request
                                     requestSHA:requestSHA
                                           row:row
                                         status:@"ambiguous"
                                  failureCode:@"E_AGENT_PERSISTENCE"
                                         error:&commitError] == nil &&
        credentialError == nil) {
      credentialError = commitError;
    }
    [self.wal unregisterNativeTaskId:nativeTaskId error:nil];
    if (error != nullptr) *error = credentialError ?: DSHAgentNativeStoreError(
        DSHAgentNativeStoreErrorUnavailable);
    return nil;
  }
  NSString *providerRequestErrorCode = nil;
  NSString *providerRequestId = [providerTransport nextProviderRequestId:
      &providerRequestErrorCode];
  if (providerRequestId == nil) {
    NSError *commitError = nil;
    (void)[self commitStartedOperationForRequest:request
                                        requestSHA:requestSHA
                                              row:persistedRow
                                            status:@"ambiguous"
                                     failureCode:@"E_AGENT_PERSISTENCE"
                                            error:&commitError];
    [self.wal unregisterNativeTaskId:nativeTaskId error:nil];
    if (error != nullptr) *error = DSHAgentNativeStoreError(
        DSHAgentNativeStoreErrorPersistence);
    return nil;
  }
  NSDictionary *dispatched = [self.rounds markAgentRoundV3DispatchedWithCAS:
      dispatchCAS error:&operationError];
  if (dispatched == nil) {
    NSError *commitError = nil;
    (void)[self commitStartedOperationForRequest:request
                                        requestSHA:requestSHA
                                              row:persistedRow
                                            status:@"ambiguous"
                                     failureCode:@"E_AGENT_PERSISTENCE"
                                            error:&commitError];
    [self.wal unregisterNativeTaskId:nativeTaskId error:nil];
    if (error != nullptr) *error = operationError;
    return nil;
  }
  NSDictionary *activeCAS = DSHProviderRoundCASForRow(dispatched[@"row"]);
  dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
  NSString *contextKey = DSHProviderLocatorKey(locator);
  DSHAgentProviderRoundContext *context = [[DSHAgentProviderRoundContext alloc] init];
  context.nativeTaskId = nativeTaskId;
  context.locator = locator;
  context.cas = activeCAS;
  context.semaphore = semaphore;
  if (contextKey != nil) @synchronized (self) {
    self.contexts[contextKey] = context;
    self.contextTransports[contextKey] = providerTransport;
  }
  BOOL (^sourceIsCurrent)(NSUInteger) = ^BOOL(NSUInteger expectedGeneration) {
         if (self.transportResolver != nil) {
           @try {
             if (self.transportResolver(harnessId) != providerTransport) return NO;
           } @catch (__unused NSException *exception) {
             return NO;
           }
         }
         NSUInteger currentGeneration = 0;
         NSString *currentCredential = nil;
         @try {
           currentCredential = self.credentialProvider == nil
               ? nil : self.credentialProvider(harnessId, &currentGeneration);
         } @catch (__unused NSException *exception) {
           currentCredential = nil;
         }
         return [providerTransport isReadyWithCredential:currentCredential] && currentGeneration == expectedGeneration;
       };
  os_log(OS_LOG_DEFAULT, "agent_round_dispatch harness=%{public}@ streaming=%{public}d sink=%{public}d",
         harnessId, streamRound, previewSink != nil);
  DSHAgentRoundPreviewPublisher *previewPublisher = !streamRound ? nil :
      [[DSHAgentRoundPreviewPublisher alloc]
          initWithSink:previewSink
           correlation:@{
             @"task_id" : request[@"task_id"],
             @"attempt_id" : request[@"attempt_id"],
             @"round_id" : request[@"round_id"],
             @"round_index" : request[@"round_index"],
             @"operation_id" : request[@"operation_id"] ?: @"",
             @"provider_request_id" : providerRequestId,
             @"harness_id" : harnessId,
           }];
  awaitProvider = ^NSDictionary *{
  __block BOOL redirected = NO;
  DSHCompletionProviderTransportBindExecutionBlock bindExecution =
      ^BOOL(id<DSHCompletionExecution> candidate) {
                             if (candidate == nil) return NO;
                             @synchronized (context) {
                               if (context.finished) return NO;
                               context.task = candidate;
                             }
                             return YES;
                           };
  DSHCompletionProviderTransportClaimRoundBlock claimRound = ^BOOL(BOOL *redirectedOut) {
                             NSDictionary *roundQuery = [self.rounds
                                 queryAgentRoundV3WithLocator:locator error:nil];
                             NSDictionary *currentRow = roundQuery[@"row"];
                             NSDictionary *currentOwner = currentRow[@"owner"];
                             BOOL ownerMatches = [currentOwner isKindOfClass:NSDictionary.class] &&
                                 [currentOwner[@"task_id"] isEqual:request[@"task_id"]] &&
                                 [currentOwner[@"launch_id"] isEqual:self.wal.launchId] &&
                                 [currentOwner[@"native_task_id"] isEqual:nativeTaskId] &&
                                 [currentOwner[@"owner_generation"] isEqual:@1] &&
                                 [self.wal isNativeTaskAlive:nativeTaskId
                                                     launchId:self.wal.launchId];
                             BOOL stateCurrent = [currentRow[@"state"] isEqualToString:@"in_flight"] ||
                                 [currentRow[@"state"] isEqualToString:@"cancel_requested"];
                             BOOL revisionCurrent = [currentRow[@"row_revision"]
                                 isEqual:activeCAS[@"expected_row_revision"]];
                             if (redirectedOut != nullptr) *redirectedOut = redirected;
                             return currentRow != nil && ownerMatches && stateCurrent &&
                                 revisionCurrent;
                           };
  DSHCompletionProviderTransportMarkRedirectedBlock markRedirected =
      ^(NSURLSessionDataTask * __unused candidate) {
                          redirected = YES;
                          @synchronized (context) { context.redirected = YES; }
                        };
  DSHCompletionProviderTransportRedirectDecisionBlock redirectDecision = ^(BOOL rejected) {
                       @synchronized (context) { context.redirectRejected = rejected; }
                     };
  DSHCompletionProviderTransportCompletionBlock completion =
      ^(NSDictionary *result, NSString *errorCode) {
                            DSHProviderFinishContext(context, result, errorCode);
                          };
  NSInteger transportSchema = [request[@"transport_schema_version"] integerValue];
  NSTimeInterval startedAt = NSProcessInfo.processInfo.systemUptime;
  id<DSHCompletionExecution> task = previewPublisher != nil
      ? [providerTransport
            startStreamingExecutionWithSchemaVersion:transportSchema
                                             roundId:request[@"round_id"]
                                          generation:1
                                credentialGeneration:credentialGeneration
                                   providerRequestId:providerRequestId
                                          credential:credential
                                      requestedModel:request[@"model"]
                                        thinkingMode:request[@"thinking_mode"]
                       credentialGenerationIsCurrent:sourceIsCurrent
                                           startedAt:startedAt
                                            bodyData:bodyData
                                      visibleHistory:visibleHistory
                                          modelInput:modelInput
                                             preview:^(NSDictionary *delta) {
                                               [previewPublisher appendDelta:delta];
                                             }
                                       bindExecution:bindExecution
                                          claimRound:claimRound
                                      markRedirected:markRedirected
                                    redirectDecision:redirectDecision
                                          completion:completion]
      : [providerTransport
            startExecutionWithSchemaVersion:transportSchema
                                    roundId:request[@"round_id"]
                                 generation:1
                       credentialGeneration:credentialGeneration
                          providerRequestId:providerRequestId
                                 credential:credential
                             requestedModel:request[@"model"]
                               thinkingMode:request[@"thinking_mode"]
              credentialGenerationIsCurrent:sourceIsCurrent
                                  startedAt:startedAt
                                   bodyData:bodyData
                             visibleHistory:visibleHistory
                                 modelInput:modelInput
                              bindExecution:bindExecution
                                 claimRound:claimRound
                             markRedirected:markRedirected
                           redirectDecision:redirectDecision
                                 completion:completion];
  if (task != nil) {
    BOOL shouldCancel = NO;
    @synchronized (context) {
      if (!context.finished && context.task == nil) {
        context.task = task;
      } else if (context.finished || context.task != task) {
        shouldCancel = YES;
      }
    }
    if (shouldCancel) [task cancel];
  }
  NSTimeInterval waitStarted = NSProcessInfo.processInfo.systemUptime;
  NSTimeInterval executionTimeout = [providerTransport executionTimeoutInterval];
  if (!isfinite(executionTimeout) || executionTimeout <= 0) executionTimeout = 120;
  executionTimeout = MIN(executionTimeout, 900);
  dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(executionTimeout * NSEC_PER_SEC));
  BOOL signaled = dispatch_semaphore_wait(semaphore, deadline) == 0;
#if DEBUG
  if (!signaled) {
    NSTimeInterval waitFinished = NSProcessInfo.processInfo.systemUptime;
    NSInteger elapsedMs = (NSInteger)floor(MAX(0, waitFinished - waitStarted) * 1000.0 + 0.000001);
    // The transport callback owns request-level diagnostics. This branch is
    // only the bounded round wait timeout, so it emits one value-free marker
    // and never duplicates provider response/error text.
    os_log_info(OS_LOG_DEFAULT,
                "agent_round phase=agent_wait harness=%{public}@ schema=%{public}ld elapsed_ms=%{public}ld error_kind=timeout error_code=0 http_status=-1 callback_signaled=false",
                harnessId, [request[@"transport_schema_version"] longValue], elapsedMs);
  }
#endif
  if (!signaled) {
    id<DSHCompletionExecution> taskToCancel = nil;
    @synchronized (context) {
      if (!context.finished) {
        context.finished = YES;
        context.providerErrorCode = @"E_COMPLETION_TIMEOUT";
      }
      taskToCancel = context.task;
    }
    if (taskToCancel != nil) [taskToCancel cancel];
  }
  return DSHProviderSerializedResult(^NSDictionary *{
  if (contextKey != nil) @synchronized (self) {
    [self.contexts removeObjectForKey:contextKey];
    [self.contextTransports removeObjectForKey:contextKey];
  }
  [self.wal unregisterNativeTaskId:nativeTaskId error:nil];
  NSDictionary *providerResult = nil;
  NSString *providerErrorCode = nil;
  @synchronized (context) {
    providerResult = [context.providerResult copy];
    providerErrorCode = [context.providerErrorCode copy];
  }
  NSDictionary *latestRoundQuery = [self.rounds queryAgentRoundV3WithLocator:
      locator error:nil];
  NSDictionary *latestRow = latestRoundQuery[@"row"];
  NSDictionary *effectiveCAS = [latestRow isKindOfClass:NSDictionary.class]
      ? DSHProviderRoundCASForRow(latestRow) : activeCAS;
  // Recheck the dispatch owner and source after the asynchronous gap. Never
  // adopt a newer row CAS to apply an old callback after cancellation/switch.
  BOOL dispatchStillCurrent = [latestRow[@"state"] isEqual:@"in_flight"] &&
      [DSHProviderRoundCASForRow(latestRow) isEqual:activeCAS];
  NSDictionary *currentAuthority = [self.preparedStore nativeAuthorityForTaskId:
      request[@"task_id"] attemptId:request[@"attempt_id"] error:nil];
  BOOL authorityStillCurrent = [currentAuthority isEqual:authority] &&
      [self.preparedStore validatePreparedRoot:request[@"root"]
          taskId:request[@"task_id"] attemptId:request[@"attempt_id"] error:nil];
  if (providerErrorCode == nil &&
      (!dispatchStillCurrent || !authorityStillCurrent ||
       !sourceIsCurrent(credentialGeneration))) {
    providerErrorCode = !dispatchStillCurrent ? @"E_AGENT_CANCELLED" :
        (!authorityStillCurrent ? @"E_AGENT_ROOT_STALE" :
                                  @"E_COMPLETION_CREDENTIAL_CHANGED");
  }
  BOOL providerCorrelationMatches = providerResult != nil &&
      [(providerResult[@"harness_id"] ?: @"dsh") isEqual:harnessId] &&
      DSHProviderResultMatchesRequest(providerResult, request, providerRequestId);
  BOOL providerDigestsMatch = providerResult != nil &&
      [providerResult[@"visible_history_sha256"] isEqual:actualVisibleTransportDigest] &&
      [providerResult[@"model_input_sha256"] isEqual:actualModelInputDigest] &&
      [providerResult[@"request_body_sha256"] isEqual:actualBodyDigest];
  if (!signaled || providerResult == nil || providerErrorCode != nil ||
      !providerCorrelationMatches || !providerDigestsMatch) {
    // The transport's own code, as Android sends it: what the provider said
    // (E_COMPLETION_HTTP_STATUS and its status) is what the notice explains,
    // where the round's code alone says only that the round is ambiguous.
    NSInteger refusalStatus = [providerTransport takeRefusalHTTPStatusForProviderRequestId:providerRequestId];
    [previewPublisher finishWithStatus:@"failed"
                           failureCode:providerErrorCode ?: DSHProviderFailureCode(
                               providerErrorCode,
                               providerResult != nil &&
                                   (!providerDigestsMatch || !providerCorrelationMatches))
                            httpStatus:refusalStatus];
    NSSet *knownProviderErrors = [NSSet setWithArray:@[@"E_COMPLETION_RESPONSE_MODEL", @"E_COMPLETION_MODEL_MISMATCH", @"E_COMPLETION_PROVIDER_RESPONSE_ID", @"E_COMPLETION_RESPONSE_JSON", @"E_COMPLETION_EMPTY_RESPONSE", @"E_COMPLETION_TOOL_CALL_INVALID", @"E_COMPLETION_FINISH_RELATION", @"E_COMPLETION_HTTP_STATUS", @"E_COMPLETION_HTTP_429", @"E_COMPLETION_CREDENTIAL_CHANGED", @"E_COMPLETION_REDIRECT", @"E_AGENT_CANCELLED"]];
    NSString *safeProviderError = providerErrorCode == nil ? @"none" : ([knownProviderErrors containsObject:providerErrorCode] ? providerErrorCode : @"other");
    os_log_error(OS_LOG_DEFAULT, "agent_round_validation signaled=%{public}d result_present=%{public}d provider_error=%{public}@ correlation_matches=%{public}d digests_match=%{public}d", signaled, providerResult != nil, safeProviderError, providerCorrelationMatches, providerDigestsMatch);

    NSDictionary *reconciled = [self.rounds reconcileAgentRoundV3OwnerLossWithLocator:
        locator expectedCAS:effectiveCAS error:&operationError];
    NSDictionary *row = reconciled[@"row"] ?: persistedRow;
    BOOL digestMismatch = providerResult != nil &&
        (!providerDigestsMatch || !providerCorrelationMatches);
    NSDictionary *unknown = DSHProviderRoundResultForRow(
        request, row, @"ambiguous",
        DSHProviderFailureCode(providerErrorCode, digestMismatch));
    NSDictionary *safeResult = DSHProviderOperationSafeResult(unknown);
    NSDictionary *resultRef = @{
      @"schema_version" : @2, @"kind" : @"round",
      @"task_id" : request[@"task_id"], @"attempt_id" : request[@"attempt_id"],
      @"round_id" : request[@"round_id"], @"round_index" : request[@"round_index"],
      @"round_revision" : row[@"row_revision"] ?: @1,
    };
    NSDictionary *operationCommit = DSHAgentNativeWALCommitOperation(
        self.wal, request[@"operation_id"], requestSHA,
        request[@"task_id"], request[@"attempt_id"], @"ambiguous", @"ambiguous",
        resultRef, row[@"row_revision"] ?: @1, safeResult, &operationError);
    if (operationCommit == nil) {
      if (error != nullptr) *error = operationError ?: DSHAgentNativeStoreError(
          DSHAgentNativeStoreErrorPersistence);
      return nil;
    }
    if (error != nullptr) *error = nil;
    return unknown;
  }
  [previewPublisher finishWithStatus:@"validated" failureCode:nil];
  NSString *finishReason = providerResult[@"finish_reason"];
  NSArray *providerCalls = [providerResult[@"tool_calls"] isKindOfClass:NSArray.class]
      ? providerResult[@"tool_calls"] : @[];
  NSMutableArray *nativeCalls = [NSMutableArray array];
  NSMutableArray *presentations = [NSMutableArray array];
  for (NSUInteger index = 0; index < providerCalls.count; index += 1) {
    if (![providerCalls[index] isKindOfClass:NSDictionary.class]) {
      NSError *commitError = nil;
      NSDictionary *row = [self.rounds
          queryAgentRoundV3WithLocator:locator error:nil][@"row"];
      (void)[self commitStartedOperationForRequest:request
                                          requestSHA:requestSHA
                                                row:row
                                              status:@"ambiguous"
                                       failureCode:@"E_AGENT_TRANSCRIPT"
                                              error:&commitError];
      DSHSetProviderError(error, DSHAgentNativeStoreErrorInvalidArgument);
      return nil;
    }
    NSDictionary *call = providerCalls[index];
    NSString *name = call[@"name"];
    NSString *arguments = call[@"arguments"];
    if (!DSHProviderOpaqueId(call[@"id"]) ||
        !DSHAgentBoundedUTF8String(name, 64, NO, nullptr) ||
        !DSHAgentBoundedUTF8String(arguments, DSHCompletionV2MaxArgumentsBytes,
                                   NO, nullptr)) {
      NSError *commitError = nil;
      NSDictionary *row = [self.rounds
          queryAgentRoundV3WithLocator:locator error:nil][@"row"];
      (void)[self commitStartedOperationForRequest:request
                                          requestSHA:requestSHA
                                                row:row
                                              status:@"ambiguous"
                                       failureCode:@"E_AGENT_TRANSCRIPT"
                                              error:&commitError];
      DSHSetProviderError(error, DSHAgentNativeStoreErrorInvalidArgument);
      return nil;
    }
    NSError *argumentError = nil;
    NSString *argumentsSHA = DSHAgentArgumentsSHA256(name, arguments, &argumentError);
    NSDictionary *presentation = [self.preparedStore.toolRegistry
        descriptorForToolName:name root:request[@"root"]
        registry:authority[@"registry"]
        error:&argumentError];
    if (argumentsSHA == nil || presentation == nil) {
      NSError *commitError = nil;
      NSDictionary *row = [self.rounds
          queryAgentRoundV3WithLocator:locator error:nil][@"row"];
      (void)[self commitStartedOperationForRequest:request
                                          requestSHA:requestSHA
                                                row:row
                                              status:@"ambiguous"
                                       failureCode:@"E_AGENT_TRANSCRIPT"
                                              error:&commitError];
      DSHSetProviderError(error, DSHAgentNativeStoreErrorInvalidArgument);
      return nil;
    }
    [nativeCalls addObject:@{
      @"schema_version" : @3,
      @"call_index" : @(index),
      @"call_id" : call[@"id"],
      @"name" : name,
      @"arguments_sha256" : argumentsSHA,
      @"safe_summary_key" : presentation[@"safe_summary_key"],
      @"access" : presentation[@"access"],
      @"approval_state" : [presentation[@"access"] isEqualToString:@"durable_deny"]
          ? @"durable_denied" : @"deferred",
    }];
    [presentations addObject:@{
      @"call_id" : call[@"id"],
      @"name" : name,
      @"arguments" : arguments,
    }];
  }
  NSDictionary *providerMessage = @{
    @"schema_version" : @1,
    @"role" : @"assistant",
    @"round_index" : request[@"round_index"],
    @"content" : providerResult[@"text"] ?: @"",
    @"reasoning_content" : providerResult[@"reasoning"] ?: @"",
    @"tool_calls" : [presentations copy],
  };
  NSError *messageError = nil;
  NSDictionary *nativeMessage = DSHProviderNativeToCompletionMessage(
      providerMessage, &messageError);
  if (nativeMessage == nil) {
    NSError *commitError = nil;
    NSDictionary *row = [self.rounds
        queryAgentRoundV3WithLocator:locator error:nil][@"row"];
    (void)[self commitStartedOperationForRequest:request
                                        requestSHA:requestSHA
                                              row:row
                                            status:@"ambiguous"
                                     failureCode:@"E_AGENT_TRANSCRIPT"
                                            error:&commitError];
    if (error != nullptr) *error = messageError ?: DSHAgentNativeStoreError(
        DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  NSDictionary *nativeReceipt = @{
    @"schema_version" : @1,
    @"transport_schema_version" : request[@"transport_schema_version"],
    @"turn_id" : request[@"task_id"],
    @"attempt_id" : request[@"attempt_id"],
    @"round_id" : request[@"round_id"],
    @"round_index" : request[@"round_index"],
    @"harness_id" : [providerResult[@"harness_id"] isKindOfClass:NSString.class]
        ? providerResult[@"harness_id"]
        : ([request[@"harness_id"] isKindOfClass:NSString.class]
            ? request[@"harness_id"] : @"dsh"),
    @"provider_request_id" : providerRequestId,
    @"provider_response_id" : providerResult[@"provider_response_id"],
    @"requested_model" : request[@"model"],
    @"model" : request[@"model"],
    @"thinking_mode" : request[@"thinking_mode"],
    @"finish_reason" : finishReason,
    @"latency_ms" : providerResult[@"latency_ms"] ?: @0,
    @"visible_history_sha256" : providerResult[@"visible_history_sha256"] ?: request[@"visible_history_sha256"],
    @"model_input_sha256" : providerResult[@"model_input_sha256"],
    @"request_body_sha256" : providerResult[@"request_body_sha256"],
    @"project_context_receipt" : contextReceipt ?: NSNull.null,
  };
  if (providerResult[@"provider_configuration"] != nil) {
    NSMutableDictionary *boundReceipt = [nativeReceipt mutableCopy];
    boundReceipt[@"provider_configuration"] = providerResult[@"provider_configuration"];
    nativeReceipt = boundReceipt;
  }
  NSString *terminalKind = [finishReason isEqualToString:@"stop"] ? @"final" :
      ([finishReason isEqualToString:@"tool_calls"] ? @"tool_batch" : @"blocked");
  NSDictionary *completed = [self.rounds completeAgentRoundV3WithLocator:locator
                                                                expectedCAS:effectiveCAS
                                                                   messages:@[ nativeMessage ]
                                                          completionReceipt:nativeReceipt
                                                               terminalKind:terminalKind
                                                                     calls:nativeCalls
                                                                      root:request[@"root"]
                                                                      error:&operationError];
  if (completed == nil) {
    NSError *commitError = nil;
    NSDictionary *row = [self.rounds
        queryAgentRoundV3WithLocator:locator error:nil][@"row"];
    (void)[self commitStartedOperationForRequest:request
                                        requestSHA:requestSHA
                                              row:row
                                            status:@"ambiguous"
                                     failureCode:@"E_AGENT_PERSISTENCE"
                                            error:&commitError];
    if (error != nullptr) *error = operationError;
    return nil;
  }
  // Presentation retention is best effort and independent of authority.
  // Only the already validated, successfully committed assistant is copied.
  @try {
    [self.preparedStore.sessionSnapshotStore.coordinator performSync:^{
      NSDictionary *loaded = [self.preparedStore.sessionSnapshotStore loadSessionSnapshotWithError:nil];
      NSData *sessionBytes = [loaded[@"session_json"] isKindOfClass:NSString.class] ? [loaded[@"session_json"] dataUsingEncoding:NSUTF8StringEncoding] : nil;
      NSDictionary *session = sessionBytes ? [NSJSONSerialization JSONObjectWithData:sessionBytes options:0 error:nil] : nil;
      BOOL ownsAttempt = NO;
      for (NSDictionary *conversation in session[@"conversations"]) {
        if (![conversation[@"id"] isEqual:request[@"conversation_id"]]) continue;
        for (NSDictionary *attempt in conversation[@"attempts"]) if ([attempt[@"attempt_id"] isEqual:request[@"attempt_id"]]) ownsAttempt = YES;
      }
      if (ownsAttempt) [self.transcripts cacheRoundPresentationForRequest:request message:nativeMessage kind:terminalKind];
    }];
  } @catch (__unused NSException *exception) {}
  NSDictionary *after = completed[@"transcript"];
  NSDictionary *publicReceipt = DSHProviderPublicReceipt(providerResult, request,
                                                          providerRequestId,
                                                          contextReceipt);
  NSDictionary *outcome = nil;
  if ([finishReason isEqualToString:@"stop"]) {
    outcome = @{
      @"schema_version" : @3, @"kind" : @"final", @"finish_reason" : @"stop",
      @"completion_receipt" : publicReceipt, @"transcript" : after,
      @"text" : providerResult[@"text"] ?: @"", @"reasoning" : providerResult[@"reasoning"] ?: @"",
    };
  } else if ([finishReason isEqualToString:@"tool_calls"]) {
    NSUInteger denied = 0;
    for (NSDictionary *call in nativeCalls) {
      if ([call[@"access"] isEqualToString:@"durable_deny"]) denied += 1;
    }
    outcome = @{
      @"schema_version" : @3, @"kind" : @"tool_batch", @"finish_reason" : @"tool_calls",
      @"completion_receipt" : publicReceipt, @"transcript" : after,
      @"calls" : [nativeCalls copy],
      @"batch_class" : denied == 0 ? @"executable" : denied == nativeCalls.count ? @"denied_only" : @"mixed",
      @"executable_call_count" : @(nativeCalls.count - denied),
      @"denied_call_count" : @(denied),
      @"reasoning" : providerResult[@"reasoning"] ?: @"",
    };
  } else {
    NSString *failure = [finishReason isEqualToString:@"length"]
        ? @"E_COMPLETION_LENGTH" : @"E_COMPLETION_CONTENT_FILTER";
    outcome = @{
      @"schema_version" : @3, @"kind" : @"blocked", @"finish_reason" : finishReason,
      @"completion_receipt" : publicReceipt, @"transcript" : after,
      @"failure_code" : failure,
    };
  }
  NSDictionary *publicResult = @{
    @"schema_version" : @2,
    @"status" : @"completed",
    @"operation_id" : request[@"operation_id"],
    @"task_id" : request[@"task_id"],
    @"attempt_id" : request[@"attempt_id"],
    @"round_id" : request[@"round_id"],
    @"round_index" : request[@"round_index"],
    @"launch_attempt" : request[@"launch_attempt"],
    @"result_round_revision" : completed[@"row"][@"row_revision"],
    @"transcript" : after,
    @"outcome" : outcome,
  };
  NSDictionary *safeResult = DSHProviderOperationSafeResult(publicResult);
  NSDictionary *resultRef = @{
    @"schema_version" : @2, @"kind" : @"round",
    @"task_id" : request[@"task_id"], @"attempt_id" : request[@"attempt_id"],
    @"round_id" : request[@"round_id"], @"round_index" : request[@"round_index"],
    @"round_revision" : completed[@"row"][@"row_revision"],
  };
  NSDictionary *committed = DSHAgentNativeWALCommitOperation(
      self.wal, request[@"operation_id"], requestSHA, request[@"task_id"],
      request[@"attempt_id"], @"committed", @"completed", resultRef,
      completed[@"row"][@"row_revision"], safeResult, &operationError);
  if (committed == nil) {
    if (error != nullptr) *error = operationError ?: DSHAgentNativeStoreError(
        DSHAgentNativeStoreErrorPersistence);
    return nil;
  }
  if (error != nullptr) *error = nil;
  return publicResult;
  });
  };
  return nil;
  });
  return awaitProvider == nil ? preparedResult : awaitProvider();
}
- (nullable NSDictionary *)queryAgentRoundWithRequest:(NSDictionary *)request
                                                error:(NSError **)error {
  NSError *requestError = nil;
  if (!DSHProviderSelectorRequest(request, NO, YES, &requestError)) {
    if (error != nullptr) *error = requestError;
    return nil;
  }
  NSError *rootError = nil;
  if (self.preparedStore == nil ||
      ![self.preparedStore validatePreparedRoot:request[@"root"]
                                         taskId:request[@"task_id"]
                                      attemptId:request[@"attempt_id"]
                                           error:&rootError]) {
    if (error != nullptr) *error = nil;
    return DSHProviderSelectorConflict(request, @{
      @"row_revision" : request[@"expected_round_revision"],
      @"state" : @"unknown",
      @"transcript_before" : request[@"transcript"],
    }, @"E_AGENT_ROOT_STALE");
  }
  NSDictionary *locator = DSHProviderRoundLocator(request);
  NSDictionary *result = [self.rounds queryAgentRoundV3WithLocator:locator error:error];
  if (result == nil) return nil;
  NSDictionary *row = result[@"row"];
  if (![row isKindOfClass:NSDictionary.class]) {
    if (![request[@"expected_round_revision"] isEqual:@0]) {
      if (error != nullptr) *error = nil;
      return DSHProviderSelectorConflict(request, @{
        @"row_revision" : @0, @"state" : @"unknown",
        @"transcript_before" : request[@"transcript"],
      }, @"E_AGENT_CONFLICT");
    }
    return @{ @"schema_version" : @2, @"status" : @"not_started" };
  }
  if (!DSHProviderSelectorMatchesRow(request, row)) {
    if (error != nullptr) *error = nil;
    return DSHProviderSelectorConflict(request, row, @"E_AGENT_CONFLICT");
  }
  NSString *status = row[@"state"];
  if ([status isEqualToString:@"completed"]) {
    NSMutableDictionary *queryResult = [DSHProviderQueryResultForRow(
        request, row, @"completed", nil) mutableCopy];
    NSDictionary *projection = [self roundProjectionForCompletedRow:row
                                                            request:request
                                                             error:nil];
    if (projection != nil) queryResult[@"completed_round"] = projection;
    return [queryResult copy];
  }
  NSDictionary *failure = DSHProviderRoundFailureCode(@"query", status);
  return DSHProviderQueryResultForRow(request, row, status,
      failure[@"code"] == NSNull.null ? nil : failure[@"code"]);
}
- (nullable NSDictionary *)recoverAgentRoundWithRequest:(NSDictionary *)request
                                                   error:(NSError **)error {
  NSError *requestError = nil;
  if (!DSHProviderSelectorRequest(request, NO, NO, &requestError)) {
    if (error != nullptr) *error = requestError;
    return nil;
  }
  NSError *rootError = nil;
  if (self.preparedStore == nil ||
      ![self.preparedStore validatePreparedRoot:request[@"root"]
                                         taskId:request[@"task_id"]
                                      attemptId:request[@"attempt_id"]
                                           error:&rootError]) {
    if (error != nullptr) *error = nil;
    return DSHProviderSelectorConflict(request, @{
      @"row_revision" : request[@"expected_round_revision"],
      @"state" : @"unknown",
      @"transcript_before" : request[@"transcript"],
    }, @"E_AGENT_ROOT_STALE");
  }
  NSDictionary *locator = DSHProviderRoundLocator(request);
  NSDictionary *query = [self.rounds queryAgentRoundV3WithLocator:locator error:error];
  NSDictionary *row = query[@"row"];
  if (![row isKindOfClass:NSDictionary.class]) return query;
  if (!DSHProviderSelectorMatchesRow(request, row)) {
    if (error != nullptr) *error = nil;
    return DSHProviderSelectorConflict(request, row, @"E_AGENT_CONFLICT");
  }
  NSDictionary *owner = row[@"owner"];
  if ((id)owner == NSNull.null) {
    NSString *state = row[@"state"];
    NSDictionary *ownerless = DSHProviderRoundFailureCode(@"ownerless", state);
    if ([ownerless[@"reportable"] isEqual:@YES]) {
      NSString *failure = ownerless[@"code"] == NSNull.null ? nil : ownerless[@"code"];
      NSMutableDictionary *result = [DSHProviderQueryResultForRow(
          request, row, state, failure) mutableCopy];
      if ([state isEqualToString:@"completed"]) {
        NSDictionary *projection = [self roundProjectionForCompletedRow:row
                                                                request:request
                                                                 error:nil];
        if (projection != nil) result[@"completed_round"] = projection;
      }
      return [result copy];
    }
    DSHSetProviderError(error, DSHAgentNativeStoreErrorConflict);
    return nil;
  }
  if ([self.wal isNativeTaskAlive:owner[@"native_task_id"]
                          launchId:owner[@"launch_id"]]) {
    return DSHProviderQueryResultForRow(request, row, @"in_flight", nil);
  }
  NSDictionary *cas = DSHProviderRoundCASForRow(row);
  NSDictionary *reconciled = [self.rounds
      reconcileAgentRoundV3OwnerLossWithLocator:locator expectedCAS:cas error:error];
  NSDictionary *reconciledRow = reconciled[@"row"] ?: row;
  NSString *status = reconciledRow[@"state"];
  return DSHProviderQueryResultForRow(
      request, reconciledRow, status,
      DSHProviderRoundFailureCode(@"reconciled", status)[@"code"]);
}
- (nullable NSDictionary *)cancelAgentRoundWithRequest:(NSDictionary *)request
                                                  error:(NSError **)error {
  NSError *requestError = nil;
  if (!DSHProviderSelectorRequest(request, YES, NO, &requestError)) {
    if (error != nullptr) *error = requestError;
    return nil;
  }
  NSError *rootError = nil;
  if (self.preparedStore == nil ||
      ![self.preparedStore validatePreparedRoot:request[@"root"]
                                         taskId:request[@"task_id"]
                                      attemptId:request[@"attempt_id"]
                                           error:&rootError]) {
    if (error != nullptr) *error = nil;
    return DSHProviderSelectorConflict(request, @{
      @"row_revision" : request[@"expected_round_revision"],
      @"state" : @"unknown",
      @"transcript_before" : request[@"transcript"],
    }, @"E_AGENT_ROOT_STALE");
  }
  NSDictionary *locator = DSHProviderRoundLocator(request);
  NSDictionary *query = [self.rounds queryAgentRoundV3WithLocator:locator error:error];
  NSDictionary *row = query[@"row"];
  if (![row isKindOfClass:NSDictionary.class]) return query;
  if (!DSHProviderSelectorMatchesRow(request, row)) {
    if (error != nullptr) *error = nil;
    return DSHProviderSelectorConflict(request, row, @"E_AGENT_CONFLICT");
  }
  NSDictionary *cas = DSHProviderRoundCASForRow(row);
  NSString *key = DSHProviderLocatorKey(locator);
  DSHAgentProviderRoundContext *context = nil;
  if (key != nil) @synchronized (self) { context = self.contexts[key]; }
  if (context != nil) {
    id<DSHCompletionExecution> task = nil;
    BOOL signal = NO;
    @synchronized (context) {
      if (!context.finished) {
        context.finished = YES;
        context.providerErrorCode = @"E_AGENT_CANCELLED";
        signal = YES;
      }
      task = context.task;
    }
    if (task != nil) {
      [task cancel];
    }
    if (signal && context.semaphore != nil) dispatch_semaphore_signal(context.semaphore);
  }
  NSDictionary *cancelled = [self.rounds cancelAgentRoundV3WithCAS:cas error:error];
  NSDictionary *cancelledRow = cancelled[@"row"] ?: row;
  NSString *status = cancelledRow[@"state"];
  NSDictionary *cancelledFailure = DSHProviderRoundFailureCode(@"cancelled",
                                                                status);
  return DSHProviderQueryResultForRow(
      request, cancelledRow, status,
      cancelledFailure[@"code"] == NSNull.null ? nil : cancelledFailure[@"code"]);
}
@end
