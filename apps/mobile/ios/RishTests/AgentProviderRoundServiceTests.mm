#import "../../../../modules/rish/ios/Sources/SessionWorkspaceCoordinator.h"
#import "../../../../modules/rish/ios/Sources/ConfiguredProviderTransport.h"
#import "../../../../modules/rish/ios/Sources/ProviderConfiguration.h"
#import <XCTest/XCTest.h>

#import "../../../../modules/rish/ios/Sources/AgentProviderRoundService.h"
#import "../../../../modules/rish/ios/Sources/DshProviderTransport.h"
#import "../../../../modules/rish/ios/Sources/ClaudeProviderTransport.h"
#import "../../../../modules/rish/ios/Sources/CodexProviderTransport.h"
#import "../../../../modules/rish/ios/Sources/AgentProviderRoundServiceInternals.h"
#import "../../../../modules/rish/ios/Sources/DSHCompletionV2.h"
#import "../../../../modules/rish/ios/Sources/DSHWorkspaceCanonical.h"

typedef void (^DSHProviderURLProtocolHandler)(NSURLProtocol *protocol,
                                              NSURLRequest *request);

static NSData *DSHProviderCapturedRequestBody(NSURLRequest *request) {
  if (request.HTTPBody != nil) return request.HTTPBody;
  NSInputStream *stream = request.HTTPBodyStream;
  if (stream == nil) return nil;
  NSMutableData *data = [NSMutableData data];
  uint8_t buffer[4096];
  [stream open];
  while (YES) {
    NSInteger count = [stream read:buffer maxLength:sizeof(buffer)];
    if (count < 0) {
      [stream close];
      return nil;
    }
    if (count == 0) break;
    [data appendBytes:buffer length:(NSUInteger)count];
  }
  [stream close];
  return [data copy];
}

@interface DSHProviderURLProtocol : NSURLProtocol
+ (void)setHandler:(DSHProviderURLProtocolHandler)handler;
+ (void)reset;
+ (NSUInteger)requestCount;
@end

@implementation DSHProviderURLProtocol
static DSHProviderURLProtocolHandler DSHProviderHandler;
static NSUInteger DSHProviderRequestCount;
+ (void)setHandler:(DSHProviderURLProtocolHandler)handler {
  @synchronized(self) { DSHProviderHandler = [handler copy]; }
}
+ (void)reset {
  @synchronized(self) { DSHProviderHandler = nil; DSHProviderRequestCount = 0; }
}
+ (NSUInteger)requestCount {
  @synchronized(self) { return DSHProviderRequestCount; }
}
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
  return [request.URL.scheme.lowercaseString isEqualToString:@"https"];
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
  DSHProviderURLProtocolHandler handler = nil;
  @synchronized(self.class) {
    DSHProviderRequestCount += 1;
    handler = [DSHProviderHandler copy];
  }
  if (handler != nil) {
    handler(self, self.request);
  } else {
    [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:@"provider-smoke"
                                                                        code:1
                                                                    userInfo:nil]];
  }
}
- (void)stopLoading {}
@end

@interface DSHProviderURLSessionDelegate : NSObject <NSURLSessionTaskDelegate>
@property(nonatomic, weak) DSHCompletionProviderTransport *transport;
@end

@implementation DSHProviderURLSessionDelegate
- (void)URLSession:(__unused NSURLSession *)session
              task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(__unused NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
  [self.transport handleHTTPRedirectionForTask:task
                                     newRequest:request
                              completionHandler:completionHandler];
}
@end

static NSString *const DSHProviderSmokeTask =
    @"11111111-1111-4111-8111-111111111111";
static NSString *const DSHProviderSmokeConversation =
    @"22222222-2222-4222-8222-222222222222";
static NSString *const DSHProviderSmokeRound =
    @"33333333-3333-4333-8333-333333333333";
static NSString *const DSHProviderSmokeAttempt =
    @"44444444-4444-4444-8444-444444444444";
static NSString *const DSHProviderSmokeOperation =
    @"55555555-5555-4555-8555-555555555555";
static NSString *const DSHProviderSmokeRootDigest =
    @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
static NSString *const DSHProviderSmokeTranscriptDigest =
    @"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
static NSString *const DSHProviderSmokeSessionDigest =
    @"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
static NSString *const DSHProviderSmokeDigest =
    @"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";

@interface DSHProviderSmokePreparedStore : DSHAgentPreparedAttemptStore
@property(nonatomic, copy) NSDictionary *authority;
@property(nonatomic, copy) NSDictionary *root;
@end

@implementation DSHProviderSmokePreparedStore
- (instancetype)initWithAuthority:(NSDictionary *)authority
                              root:(NSDictionary *)root
                               wal:(DSHAgentNativeWAL *)wal {
  self = [super initWithWAL:wal
               rootResolver:(DSHAgentRootResolver *)(id)NSNull.null
         sessionSnapshotStore:(DSHSessionSnapshotStore *)(id)NSNull.null
              transcriptStore:nil];
  if (self != nil) {
    _authority = [authority copy];
    _root = [root copy];
  }
  return self;
}
- (NSDictionary *)nativeAuthorityForTaskId:(NSString *)taskId
                                  attemptId:(NSString *)attemptId
                                      error:(NSError **)error {
  if (error != nullptr) *error = nil;
  return self.authority;
}
- (BOOL)validatePreparedRoot:(NSDictionary *)root
                      taskId:(NSString *)taskId
                   attemptId:(NSString *)attemptId
                        error:(NSError **)error {
  if (error != nullptr) *error = nil;
  return [root isEqual:self.root];
}
@end

@interface DSHProviderSmokeTranscriptStore : DSHAgentTranscriptStore
@property(nonatomic, copy) NSArray *messages;
@end

@implementation DSHProviderSmokeTranscriptStore
- (instancetype)initWithMessages:(NSArray *)messages wal:(DSHAgentNativeWAL *)wal {
  self = [super initWithWAL:wal];
  if (self != nil) _messages = [messages copy];
  return self;
}
- (NSArray *)nativeMessagesForTranscriptWithRequest:(NSDictionary *)request
                                               error:(NSError **)error {
  if (error != nullptr) *error = nil;
  return self.messages;
}
@end

@interface DSHProviderSmokeRoundJournal : DSHAgentRoundJournal
@property(nonatomic, copy) NSDictionary *row;
@property(nonatomic) NSUInteger createCount;
@property(nonatomic) NSUInteger dispatchCount;
@property(nonatomic) NSUInteger completeCount;
@property(nonatomic) NSUInteger reconcileCount;
@property(nonatomic, copy) NSDictionary *providerTranscript;
@property(nonatomic, copy) NSArray *completedMessages;
@property(nonatomic) BOOL reconcileToFailedRetryable;
@property(nonatomic) BOOL failNextWALTransactionAfterComplete;
@end

@interface DSHProviderCommitFailingWAL : DSHAgentNativeWAL
@property(nonatomic) BOOL failNextTransaction;
@end

@implementation DSHProviderCommitFailingWAL
- (BOOL)performAtomicTransaction:(DSHAgentNativeWALMutation)mutation
                           error:(NSError **)error {
  if (self.failNextTransaction) {
    self.failNextTransaction = NO;
    if (error != nullptr) *error = DSHAgentNativeStoreError(
        DSHAgentNativeStoreErrorPersistence);
    return NO;
  }
  return [super performAtomicTransaction:mutation error:error];
}
@end

@implementation DSHProviderSmokeRoundJournal
- (instancetype)initWithRow:(NSDictionary *)row wal:(DSHAgentNativeWAL *)wal {
  self = [super initWithWAL:wal];
  if (self != nil) _row = [row copy];
  return self;
}
- (NSDictionary *)createAgentRoundV3WithInsertCAS:(NSDictionary *)insertCAS
                                  exactRoundStart:(NSDictionary *)round
                                            error:(NSError **)error {
  if (error != nullptr) *error = nil;
  self.createCount += 1;
  self.row = [round copy];
  return @{ @"schema_version" : @3, @"status" : @"inserted", @"row" : self.row };
}
- (NSDictionary *)markAgentRoundV3DispatchedWithCAS:(NSDictionary *)cas
                                               error:(NSError **)error {
  if (error != nullptr) *error = nil;
  self.dispatchCount += 1;
  NSMutableDictionary *row = [self.row mutableCopy];
  row[@"row_revision"] = @2;
  self.row = row;
  return @{ @"schema_version" : @3, @"status" : @"dispatched", @"row" : self.row };
}
- (NSDictionary *)completeAgentRoundV3WithLocator:(NSDictionary *)locator
                                      expectedCAS:(NSDictionary *)cas
                                         messages:(NSArray *)messages
                                completionReceipt:(NSDictionary *)receipt
                                     terminalKind:(NSString *)terminalKind
                                           calls:(NSArray *)calls
                                            root:(NSDictionary *)root
                                            error:(NSError **)error {
  if (error != nullptr) *error = nil;
  self.completeCount += 1;
  self.completedMessages = [messages copy];
  NSMutableDictionary *row = [self.row mutableCopy];
  row[@"row_revision"] = @3;
  row[@"state"] = @"completed";
  row[@"owner"] = NSNull.null;
  row[@"completion_receipt"] = receipt;
  row[@"transcript_after"] = self.providerTranscript;
  row[@"terminal_kind"] = terminalKind;
  row[@"calls"] = calls;
  row[@"batch_class"] = calls.count == 0 ? NSNull.null : @"executable";
  row[@"executable_call_count"] = @(calls.count);
  row[@"denied_call_count"] = @0;
  row[@"failure_code"] = NSNull.null;
  self.row = row;
  if (self.failNextWALTransactionAfterComplete &&
      [self.wal isKindOfClass:DSHProviderCommitFailingWAL.class]) {
    ((DSHProviderCommitFailingWAL *)self.wal).failNextTransaction = YES;
    self.failNextWALTransactionAfterComplete = NO;
  }
  return @{ @"schema_version" : @3, @"status" : @"completed",
            @"row" : self.row, @"transcript" : self.providerTranscript };
}
- (NSDictionary *)queryAgentRoundV3WithLocator:(NSDictionary *)locator
                                          error:(NSError **)error {
  if (error != nullptr) *error = nil;
  return @{ @"schema_version" : @3, @"status" : self.row[@"state"] ?: @"in_flight",
            @"row" : self.row };
}
- (NSDictionary *)reconcileAgentRoundV3OwnerLossWithLocator:(NSDictionary *)locator
                                                  expectedCAS:(NSDictionary *)cas
                                                         error:(NSError **)error {
  if (error != nullptr) *error = nil;
  self.reconcileCount += 1;
  NSMutableDictionary *row = [self.row mutableCopy];
  row[@"row_revision"] = @3;
  row[@"state"] = self.reconcileToFailedRetryable
      ? @"failed_retryable" : @"ambiguous";
  row[@"owner"] = NSNull.null;
  row[@"failure_code"] = self.reconcileToFailedRetryable
      ? @"E_AGENT_PERSISTENCE" : @"E_AGENT_ROUND_AMBIGUOUS";
  row[@"completion_receipt"] = NSNull.null;
  row[@"transcript_after"] = NSNull.null;
  row[@"terminal_kind"] = NSNull.null;
  self.row = row;
  return @{ @"schema_version" : @3, @"status" : @"ambiguous", @"row" : self.row };
}
- (NSDictionary *)cancelAgentRoundV3WithCAS:(NSDictionary *)cas
                                       error:(NSError **)error {
  if (error != nullptr) *error = nil;
  NSMutableDictionary *row = [self.row mutableCopy];
  row[@"row_revision"] = @2;
  row[@"state"] = @"cancel_requested";
  self.row = row;
  return @{ @"schema_version" : @3, @"status" : @"cancel_requested", @"row" : self.row };
}
@end

@interface DSHProviderSmokeTransport : DshProviderTransport
@property(nonatomic, copy) NSDictionary *result;
@property(nonatomic, copy) void (^pendingCompletion)(NSDictionary *, NSString *);
@property(nonatomic) NSUInteger startCount;
@property(nonatomic, copy) NSData *lastBodyData;
@property(nonatomic, copy) NSArray *lastModelInput;
@property(nonatomic) BOOL holdResponse;
@property(nonatomic, copy) dispatch_block_t responseHeld;
@property(nonatomic, copy) NSDictionary *heldResult;
@property(nonatomic) BOOL rejectCredentialGeneration;
@property(nonatomic) BOOL bindAndReturnTask;
@property(nonatomic) BOOL deferBind;
@property(nonatomic, copy) DSHCompletionProviderTransportBindTaskBlock deferredBind;
@property(nonatomic, strong) NSURLSessionDataTask *deferredTask;
@property(nonatomic) NSUInteger cancelCount;
@end

@implementation DSHProviderSmokeTransport
- (instancetype)initWithResult:(NSDictionary *)result {
  NSURLSessionConfiguration *configuration =
      NSURLSessionConfiguration.ephemeralSessionConfiguration;
  NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
  self = [super initWithSession:session
                  uuidGenerator:^NSString *{
                    return @"66666666-6666-4666-8666-666666666666";
                  }
                   monotonicClock:^NSTimeInterval {
                     return 2.0;
                   }];
  if (self != nil) _result = [result copy];
  return self;
}
- (NSURLSessionDataTask *)startRequestWithSchemaVersion:(NSInteger)schemaVersion
                                                 roundId:(NSString *)roundId
                                               generation:(NSUInteger)generation
                                     credentialGeneration:(NSUInteger)credentialGeneration
                                              providerRequestId:(NSString *)providerRequestId
                                                    credential:(NSString *)credential
                                                requestedModel:(NSString *)requestedModel
                                                 thinkingMode:(NSString *)thinkingMode
                                  credentialGenerationIsCurrent:(DSHCompletionProviderTransportCredentialGenerationIsCurrentBlock)generationCheck
                                                     startedAt:(NSTimeInterval)startedAt
                                                      bodyData:(NSData *)bodyData
                                                  visibleHistory:(NSArray *)visibleHistory
                                                      modelInput:(NSArray *)modelInput
                                                        bindTask:(DSHCompletionProviderTransportBindTaskBlock)bindTask
                                                      claimRound:(DSHCompletionProviderTransportClaimRoundBlock)claimRound
                                                   markRedirected:(DSHCompletionProviderTransportMarkRedirectedBlock)markRedirected
                                                redirectDecision:(DSHCompletionProviderTransportRedirectDecisionBlock)redirectDecision
                                                      completion:(DSHCompletionProviderTransportCompletionBlock)completion {
  (void)schemaVersion; (void)roundId; (void)generation; (void)credentialGeneration;
  (void)providerRequestId; (void)credential; (void)requestedModel;
  (void)thinkingMode; (void)startedAt; (void)visibleHistory; (void)bindTask;
  (void)claimRound; (void)markRedirected; (void)redirectDecision;
  self.startCount += 1;
  self.lastBodyData = bodyData;
  self.lastModelInput = [modelInput copy];
  if (self.deferBind) {
    self.deferredBind = [bindTask copy];
    self.deferredTask = [[NSURLSession sharedSession]
        dataTaskWithURL:[NSURL URLWithString:@"https://example.invalid/deferred"]];
    return nil;
  }
  if (self.bindAndReturnTask) {
    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithURL:[NSURL URLWithString:@"https://example.invalid/bound"]];
    BOOL bound = bindTask != nil && bindTask(task);
    if (!bound) return nil;
    NSMutableDictionary *result = [self.result mutableCopy];
    result[@"visible_history_sha256"] = DSHWorkspaceSHA256Hex(
        [NSJSONSerialization dataWithJSONObject:visibleHistory options:NSJSONWritingSortedKeys error:nil]);
    result[@"model_input_sha256"] = DSHWorkspaceSHA256Hex(
        [NSJSONSerialization dataWithJSONObject:modelInput options:NSJSONWritingSortedKeys error:nil]);
    result[@"request_body_sha256"] = DSHWorkspaceSHA256Hex(bodyData);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
      completion([result copy], nil);
    });
    return task;
  }
  if (self.rejectCredentialGeneration ||
      (generationCheck != nil && !generationCheck(7))) {
    completion(nil, @"E_COMPLETION_CREDENTIAL_CHANGED");
  } else if (self.holdResponse) {
    NSMutableDictionary *held = [self.result mutableCopy];
    held[@"visible_history_sha256"] = DSHWorkspaceSHA256Hex(
        [NSJSONSerialization dataWithJSONObject:visibleHistory options:NSJSONWritingSortedKeys error:nil]);
    held[@"model_input_sha256"] = DSHWorkspaceSHA256Hex(
        [NSJSONSerialization dataWithJSONObject:modelInput options:NSJSONWritingSortedKeys error:nil]);
    held[@"request_body_sha256"] = DSHWorkspaceSHA256Hex(bodyData);
    self.heldResult = held;
    self.pendingCompletion = [completion copy];
    if (self.responseHeld) self.responseHeld();
  } else {
    NSError *digestError = nil;
    NSData *visibleBytes = [NSJSONSerialization dataWithJSONObject:visibleHistory
                                                               options:NSJSONWritingSortedKeys
                                                                 error:&digestError];
    NSData *modelBytes = [NSJSONSerialization dataWithJSONObject:modelInput
                                                             options:NSJSONWritingSortedKeys
                                                               error:&digestError];
    NSMutableDictionary *result = [self.result mutableCopy];
    result[@"visible_history_sha256"] = DSHWorkspaceSHA256Hex(visibleBytes);
    result[@"model_input_sha256"] = DSHWorkspaceSHA256Hex(modelBytes);
    result[@"request_body_sha256"] = DSHWorkspaceSHA256Hex(bodyData);
    completion([result copy], nil);
  }
  return nil;
}
- (void)cancelTask:(NSURLSessionDataTask *)task {
  self.cancelCount += 1;
  [task cancel];
}
@end

static NSDictionary *DSHProviderSmokeRoot(void) {
  return @{
    @"schema_version" : @1,
    @"kind" : @"workspace",
    @"workspace_id" : @"77777777-7777-4777-8777-777777777777",
    @"workspace_binding_revision" : @7,
    @"project_id" : NSNull.null,
    @"root_fingerprint_sha256" : DSHProviderSmokeRootDigest,
    @"capabilities" : @[ @"file_read", @"file_write" ],
  };
}

static NSDictionary *DSHProviderSmokeTranscript(void) {
  return @{
    @"schema_version" : @1,
    @"transcript_ref" : @"88888888-8888-4888-8888-888888888888",
    @"generation" : @0,
    @"transcript_sha256" : DSHProviderSmokeTranscriptDigest,
    @"transcript_bytes" : @1,
  };
}

// The conversation the smoke fixture's round is about. A test that needs a
// different one -- an attachment, say -- sets this before building its
// fixture and clears it after, so the digest the request carries and the
// history the service reads can never drift apart.
static NSArray *DSHProviderSmokeHistoryOverride = nil;

static NSArray *DSHProviderSmokeHistory(void) {
  return DSHProviderSmokeHistoryOverride
      ?: @[ @{ @"role" : @"user", @"content" : @"hello" } ];
}

static NSString *DSHProviderSmokeVisibleDigest(void) {
  return DSHAgentHJ(@"visible-history", @{
    @"messages" : DSHProviderSmokeHistory(),
  }, nil);
}

static NSDictionary *DSHProviderSmokeAuthority(NSDictionary *root,
                                               NSDictionary *transcript,
                                               NSDictionary *registry) {
  return @{
    @"task_id" : DSHProviderSmokeTask,
    @"conversation_id" : DSHProviderSmokeConversation,
    @"attempt_id" : DSHProviderSmokeAttempt,
    @"root" : root,
    @"transcript" : transcript,
    @"registry" : registry,
    @"transport_schema_version" : @2,
    @"authority_revision" : @1,
    @"model" : @"deepseek-v4-flash",
    @"thinking_mode" : @"off",
    @"visible_history_sha256" : DSHProviderSmokeVisibleDigest(),
    @"visible_message_count" : @1,
    @"project_context_sha256" : NSNull.null,
  };
}

static NSDictionary *DSHProviderSmokeRequest(NSDictionary *root,
                                             NSDictionary *transcript,
                                             NSString *toolsetSHA256,
                                             NSString *operationId) {
  NSDictionary *checkpoint = @{
    @"schema_version" : @1,
    @"journal_revision" : @0,
    @"session_generation" : @3,
    @"session_sha256" : DSHProviderSmokeSessionDigest,
  };
  return @{
    @"schema_version" : @2,
    @"operation_id" : operationId,
    @"controller_cas" : @{
      @"schema_version" : @1,
      @"conversation_id" : DSHProviderSmokeConversation,
      @"task_id" : DSHProviderSmokeTask,
      @"attempt_id" : DSHProviderSmokeAttempt,
      @"expected_controller_generation" : @2,
      @"expected_journal_revision" : @0,
      @"expected_session_generation" : @3,
      @"expected_session_sha256" : DSHProviderSmokeSessionDigest,
    },
    @"committed_checkpoint" : checkpoint,
    @"task_id" : DSHProviderSmokeTask,
    @"conversation_id" : DSHProviderSmokeConversation,
    @"attempt_id" : DSHProviderSmokeAttempt,
    @"round_id" : DSHProviderSmokeRound,
    @"round_index" : @0,
    @"launch_attempt" : @1,
    @"expected_round_revision" : @0,
    @"transport_schema_version" : @2,
    @"model" : @"deepseek-v4-flash",
    @"thinking_mode" : @"off",
    @"visible_history_sha256" : DSHProviderSmokeVisibleDigest(),
    @"visible_message_count" : @1,
    @"project_context_sha256" : NSNull.null,
    @"transcript" : transcript,
    @"root" : root,
    @"registry_version" : @3, // This helper creates fresh iOS authorities.
    @"toolset_sha256" : toolsetSHA256,
  };
}

static NSDictionary *DSHProviderSmokeQueryRequest(NSDictionary *root,
                                                  NSDictionary *transcript,
                                                  NSUInteger revision,
                                                  BOOL cancellation) {
  NSMutableDictionary *request = [@{
    @"schema_version" : @2,
    @"task_id" : DSHProviderSmokeTask,
    @"attempt_id" : DSHProviderSmokeAttempt,
    @"round_id" : DSHProviderSmokeRound,
    @"round_index" : @0,
    @"expected_round_revision" : @(revision),
    @"transcript" : transcript,
    @"root" : root,
  } mutableCopy];
  if (cancellation) request[@"cancel_token"] = @"99999999-9999-4999-8999-999999999999";
  return [request copy];
}

/// Streams a scripted round: previews a few deltas, then settles one result
/// whose digests match the dispatched body, like the HTTP transport would.
@interface DSHProviderStreamingSmokeExecution : NSObject <DSHCompletionExecution>
@property(nonatomic) NSUInteger cancelCount;
@end
@implementation DSHProviderStreamingSmokeExecution
- (void)cancel { self.cancelCount += 1; }
@end

@interface DSHProviderStreamingSmokeTransport : DSHProviderSmokeTransport
@property(nonatomic) NSUInteger streamingStarts;
@property(nonatomic, copy) NSArray<NSDictionary *> *scriptedDeltas;
@property(nonatomic) BOOL supportsStreaming;
@end
@implementation DSHProviderStreamingSmokeTransport
- (BOOL)providerSupportsStreamingRounds { return self.supportsStreaming; }
- (id<DSHCompletionExecution>)startStreamingExecutionWithSchemaVersion:(NSInteger)schemaVersion
                                                               roundId:(NSString *)roundId
                                                            generation:(NSUInteger)generation
                                                  credentialGeneration:(NSUInteger)credentialGeneration
                                                     providerRequestId:(NSString *)providerRequestId
                                                            credential:(NSString *)credential
                                                        requestedModel:(NSString *)requestedModel
                                                          thinkingMode:(NSString *)thinkingMode
                                         credentialGenerationIsCurrent:(DSHCompletionProviderTransportCredentialGenerationIsCurrentBlock)credentialGenerationIsCurrent
                                                             startedAt:(NSTimeInterval)startedAt
                                                              bodyData:(NSData *)bodyData
                                                        visibleHistory:(NSArray *)visibleHistory
                                                            modelInput:(NSArray *)modelInput
                                                               preview:(DSHCompletionProviderTransportPreviewBlock)preview
                                                         bindExecution:(DSHCompletionProviderTransportBindExecutionBlock)bindExecution
                                                            claimRound:(DSHCompletionProviderTransportClaimRoundBlock)claimRound
                                                        markRedirected:(DSHCompletionProviderTransportMarkRedirectedBlock)markRedirected
                                                      redirectDecision:(DSHCompletionProviderTransportRedirectDecisionBlock)redirectDecision
                                                            completion:(DSHCompletionProviderTransportCompletionBlock)completion {
  if (!self.supportsStreaming) {
    return [super startStreamingExecutionWithSchemaVersion:schemaVersion roundId:roundId
        generation:generation credentialGeneration:credentialGeneration
        providerRequestId:providerRequestId credential:credential
        requestedModel:requestedModel thinkingMode:thinkingMode
        credentialGenerationIsCurrent:credentialGenerationIsCurrent startedAt:startedAt
        bodyData:bodyData visibleHistory:visibleHistory modelInput:modelInput
        preview:preview bindExecution:bindExecution claimRound:claimRound
        markRedirected:markRedirected redirectDecision:redirectDecision
        completion:completion];
  }
  (void)schemaVersion; (void)roundId; (void)generation; (void)credentialGeneration;
  (void)providerRequestId; (void)credential; (void)requestedModel; (void)thinkingMode;
  (void)credentialGenerationIsCurrent; (void)startedAt; (void)claimRound;
  (void)markRedirected; (void)redirectDecision;
  self.startCount += 1;
  self.streamingStarts += 1;
  self.lastBodyData = bodyData;
  self.lastModelInput = [modelInput copy];
  DSHProviderStreamingSmokeExecution *execution = [DSHProviderStreamingSmokeExecution new];
  if (bindExecution == nil || !bindExecution(execution)) return nil;
  NSMutableDictionary *result = [self.result mutableCopy];
  result[@"visible_history_sha256"] = DSHWorkspaceSHA256Hex(
      [NSJSONSerialization dataWithJSONObject:visibleHistory options:NSJSONWritingSortedKeys error:nil]);
  result[@"model_input_sha256"] = DSHWorkspaceSHA256Hex(
      [NSJSONSerialization dataWithJSONObject:modelInput options:NSJSONWritingSortedKeys error:nil]);
  result[@"request_body_sha256"] = DSHWorkspaceSHA256Hex(bodyData);
  NSArray *deltas = [self.scriptedDeltas copy];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
    for (NSDictionary *delta in deltas) {
      if (preview != nil) preview(delta);
    }
    completion([result copy], nil);
  });
  return execution;
}
@end

@interface DSHProviderSmokeFixture : NSObject
@property(nonatomic, strong) DSHAgentNativeWAL *wal;
@property(nonatomic, strong) DSHProviderSmokePreparedStore *prepared;
@property(nonatomic, strong) DSHProviderSmokeTranscriptStore *transcripts;
@property(nonatomic, strong) DSHProviderSmokeRoundJournal *rounds;
@property(nonatomic, strong) DSHProviderSmokeTransport *transport;
@property(nonatomic, strong) DSHAgentProviderRoundService *service;
@property(nonatomic, copy) NSDictionary *root;
@property(nonatomic, copy) NSDictionary *transcript;
@property(nonatomic, copy) NSDictionary *request;
@property(nonatomic, strong) NSURL *walRoot;
@property(nonatomic) BOOL historyAvailable;
@property(nonatomic) BOOL credentialAvailable;
@property(nonatomic) NSUInteger credentialGeneration;
@property(nonatomic) NSUInteger historyCalls;
@property(nonatomic) NSUInteger credentialCalls;
- (instancetype)initWithFaultingCommit:(BOOL)faultingCommit;
@end

@implementation DSHProviderSmokeFixture
- (instancetype)initWithFaultingCommit:(BOOL)faultingCommit {
  self = [super init];
  if (self != nil) {
    _root = DSHProviderSmokeRoot();
    _transcript = DSHProviderSmokeTranscript();
    _historyAvailable = YES;
    _credentialAvailable = YES;
    _credentialGeneration = 7;
    NSError *registryError = nil;
    DSHAgentToolRegistry *registry = [[DSHAgentToolRegistry alloc] init];
    NSDictionary *registryProjection = [registry registryForRoot:_root
                                                             error:&registryError];
    NSURL *walRoot = [NSURL fileURLWithPath:[NSTemporaryDirectory()
        stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    _walRoot = walRoot;
    Class walClass = faultingCommit ? DSHProviderCommitFailingWAL.class
                                    : DSHAgentNativeWAL.class;
    _wal = [[walClass alloc]
        initWithRootURL:walRoot
        clock:^NSDate *{
          return [NSDate dateWithTimeIntervalSince1970:1700000000];
        }
        identifierGenerator:^NSString *{
          return @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
        }
        faultHook:nil];
    NSDictionary *authority = DSHProviderSmokeAuthority(_root, _transcript,
                                                        registryProjection);
    _prepared = [[DSHProviderSmokePreparedStore alloc]
        initWithAuthority:authority root:_root wal:_wal];
    _transcripts = [[DSHProviderSmokeTranscriptStore alloc]
        initWithMessages:@[] wal:_wal];
    _rounds = [[DSHProviderSmokeRoundJournal alloc] initWithRow:@{} wal:_wal];
    _rounds.providerTranscript = _transcript;
    _transport = [[DSHProviderSmokeTransport alloc]
        initWithResult:@{
          @"provider_request_id" : @"66666666-6666-4666-8666-666666666666",
          @"provider_response_id" : @"response-1",
          @"requested_model" : @"deepseek-v4-flash",
          @"model" : @"deepseek-v4-flash",
          @"thinking_mode" : @"off",
          @"text" : @"done",
          @"reasoning" : @"",
          @"tool_calls" : @[],
          @"finish_reason" : @"stop",
          @"latency_ms" : @1,
          @"visible_history_sha256" : DSHProviderSmokeDigest,
          @"model_input_sha256" : DSHProviderSmokeDigest,
          @"request_body_sha256" : DSHProviderSmokeDigest,
        }];
    _request = DSHProviderSmokeRequest(
        _root, _transcript, registryProjection[@"toolset_sha256"],
        DSHProviderSmokeOperation);
    __weak DSHProviderSmokeFixture *weakSelf = self;
    _service = [[DSHAgentProviderRoundService alloc]
        initWithWAL:_wal
        preparedStore:_prepared
        transcripts:_transcripts
        rounds:_rounds
        transport:_transport
        credentialProvider:^NSString *(NSString *harnessId, NSUInteger *generation) {
          weakSelf.credentialCalls += 1;
          if (!weakSelf.credentialAvailable) return nil;
          if (generation != nullptr) *generation = weakSelf.credentialGeneration;
          return @"credential";
        }
        visibleHistoryProvider:^NSArray *(NSDictionary *authority, NSError **error) {
          (void)authority; if (error != nullptr) *error = nil;
          weakSelf.historyCalls += 1;
          if (!weakSelf.historyAvailable) return nil;
          return DSHProviderSmokeHistory();
        }];
  }
  return self;
}
- (instancetype)init {
  return [self initWithFaultingCommit:NO];
}
- (void)dealloc {
  [NSFileManager.defaultManager removeItemAtURL:_walRoot error:nil];
}
@end

@interface AgentProviderRoundServiceTests : XCTestCase
@end

@implementation AgentProviderRoundServiceTests

- (DSHAgentProviderRoundService *)streamingServiceForFixture:(DSHProviderSmokeFixture *)fixture
                                                   transport:(DSHProviderStreamingSmokeTransport *)transport {
  __weak DSHProviderSmokeFixture *weakFixture = fixture;
  return [[DSHAgentProviderRoundService alloc]
      initWithWAL:fixture.wal
      preparedStore:fixture.prepared
      transcripts:fixture.transcripts
      rounds:fixture.rounds
      transport:transport
      credentialProvider:^NSString *(__unused NSString *harnessId, NSUInteger *generation) {
        if (generation != nullptr) *generation = weakFixture.credentialGeneration;
        return @"credential";
      }
      visibleHistoryProvider:^NSArray *(__unused NSDictionary *authority, NSError **error) {
        if (error != nullptr) *error = nil;
        return @[ @{ @"role" : @"user", @"content" : @"hello" } ];
      }];
}

- (DSHProviderStreamingSmokeTransport *)streamingTransportWithResult:(NSDictionary *)result {
  DSHProviderStreamingSmokeTransport *transport =
      [[DSHProviderStreamingSmokeTransport alloc] initWithResult:result];
  transport.supportsStreaming = YES;
  transport.scriptedDeltas = @[
    @{ @"type" : @"delta", @"reasoning" : @"th" },
    @{ @"type" : @"delta", @"reasoning" : @"ink" },
    @{ @"type" : @"delta", @"content" : @"do" },
    @{ @"type" : @"delta", @"content" : @"ne", @"finish_reason" : @"stop" },
  ];
  return transport;
}

// An image attached to an Agent turn reaches the provider as its own bytes.
//
// The round service used to hand the visible history straight to the
// request builder, which reads a message's `content` and ignores its
// `attachments`: the model was asked about a picture it was never shown. The
// chat path has always projected attachments; the Agent path now calls the
// same projection. What is asserted is the bytes, because a check that only
// found an image part would pass over an empty one.
- (void)testAnImageAttachedToAnAgentTurnReachesTheProviderAsItsOwnBytes {
  const uint8_t bytes[] = {0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02};
  NSData *png = [NSData dataWithBytes:bytes length:sizeof(bytes)];
  NSDictionary *reference = @{
    @"schema_version" : @1,
    @"id" : @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    @"kind" : @"image",
    @"name" : @"probe.png",
    @"mime_type" : @"image/png",
    @"size" : @(png.length),
  };
  DSHProviderSmokeHistoryOverride = @[ @{
    @"role" : @"user", @"content" : @"what is this", @"attachments" : @[ reference ],
  } ];
  @try {
    DSHProviderSmokeFixture *fixture = [[DSHProviderSmokeFixture alloc] init];
    fixture.service.attachmentResolver =
        ^NSDictionary *(__unused id value, NSData **payload, NSDictionary **manifest,
                        NSError **error) {
          if (error != nullptr) *error = nil;
          if (payload != nullptr) *payload = png;
          if (manifest != nullptr) {
            *manifest = @{ @"mime_type" : @"image/png", @"size" : @(png.length) };
          }
          return reference;
        };
    NSError *error = nil;
    (void)[fixture.service completeAgentRoundV2WithRequest:fixture.request error:&error];

    XCTAssertEqual(fixture.transport.startCount, (NSUInteger)1);
    NSString *expectedURL = [NSString stringWithFormat:@"data:image/png;base64,%@",
                             [png base64EncodedStringWithOptions:0]];
    NSDictionary *userTurn = nil;
    for (NSDictionary *message in fixture.transport.lastModelInput) {
      if ([message[@"role"] isEqual:@"user"]) userTurn = message;
    }
    NSArray *parts = userTurn[@"content"];
    XCTAssertTrue([parts isKindOfClass:NSArray.class], @"%@", userTurn);
    NSString *url = nil;
    for (NSDictionary *part in parts) {
      if ([part[@"type"] isEqual:@"image_url"]) url = part[@"image_url"][@"url"];
    }
    XCTAssertEqualObjects(url, expectedURL);
    // And the body the provider would receive carries it too, rather than
    // the app's own `attachments` metadata.
    NSString *body = [[NSString alloc] initWithData:fixture.transport.lastBodyData
                                           encoding:NSUTF8StringEncoding];
    XCTAssertTrue([body containsString:[png base64EncodedStringWithOptions:0]], @"%@", body);
    XCTAssertFalse([body containsString:@"\"attachments\""], @"%@", body);
  } @finally {
    DSHProviderSmokeHistoryOverride = nil;
  }
}

// An attachment this path cannot carry fails the round before anything is
// sent, as a capability refusal the person can act on -- not an ambiguity,
// because nothing was dispatched, and not a silent drop, because the model
// would then answer about a file it never received.
- (void)testAnAttachmentThatCannotBeCarriedIsRefusedBeforeDispatch {
  NSDictionary *reference = @{
    @"schema_version" : @1,
    @"id" : @"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
    @"kind" : @"image",
    @"name" : @"gone.png",
    @"mime_type" : @"image/png",
    @"size" : @3,
  };
  DSHProviderSmokeHistoryOverride = @[ @{
    @"role" : @"user", @"content" : @"what is this", @"attachments" : @[ reference ],
  } ];
  @try {
    DSHProviderSmokeFixture *fixture = [[DSHProviderSmokeFixture alloc] init];
    fixture.service.attachmentResolver =
        ^NSDictionary *(__unused id value, __unused NSData **payload,
                        __unused NSDictionary **manifest, NSError **error) {
          if (error != nullptr) {
            *error = [NSError errorWithDomain:@"test" code:1 userInfo:nil];
          }
          return nil;
        };
    NSError *error = nil;
    NSDictionary *result =
        [fixture.service completeAgentRoundV2WithRequest:fixture.request error:&error];
    XCTAssertNil(result);
    XCTAssertEqualObjects(error.userInfo[@"code"], @"E_AGENT_CAPABILITY");
    XCTAssertEqual(fixture.transport.startCount, (NSUInteger)0,
                   @"nothing may be sent for a request that cannot be carried");
  } @finally {
    DSHProviderSmokeHistoryOverride = nil;
  }
}

- (void)testStreamedRoundPublishesOrderedPreviewEventsAndOneValidatedEnd {
  DSHProviderSmokeFixture *fixture = [[DSHProviderSmokeFixture alloc] init];
  DSHProviderStreamingSmokeTransport *transport =
      [self streamingTransportWithResult:fixture.transport.result];
  DSHAgentProviderRoundService *service =
      [self streamingServiceForFixture:fixture transport:transport];
  NSMutableArray<NSDictionary *> *events = [NSMutableArray array];
  XCTestExpectation *ended = [self expectationWithDescription:@"end event"];
  service.previewSink = ^(NSDictionary *event) {
    @synchronized (events) { [events addObject:event]; }
    if ([event[@"kind"] isEqual:@"end"]) [ended fulfill];
  };
  NSError *error = nil;
  NSDictionary *result = [service completeAgentRoundV2WithRequest:fixture.request error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"completed");
  XCTAssertEqualObjects(result[@"outcome"][@"kind"], @"final");
  [self waitForExpectations:@[ ended ] timeout:5];

  XCTAssertEqual(transport.streamingStarts, (NSUInteger)1);
  NSDictionary *body = [NSJSONSerialization JSONObjectWithData:transport.lastBodyData
                                                        options:0 error:nil];
  XCTAssertEqualObjects(body[@"stream"], @YES);

  NSArray<NSDictionary *> *snapshot = nil;
  @synchronized (events) { snapshot = [events copy]; }
  XCTAssertTrue(snapshot.count >= 2);
  NSMutableString *text = [NSMutableString string];
  NSMutableString *reasoning = [NSMutableString string];
  NSUInteger expectedSeq = 1;
  for (NSDictionary *event in snapshot) {
    XCTAssertEqualObjects(event[@"schema_version"], @1);
    XCTAssertEqualObjects(event[@"seq"], @(expectedSeq));
    expectedSeq += 1;
    XCTAssertEqualObjects(event[@"task_id"], fixture.request[@"task_id"]);
    XCTAssertEqualObjects(event[@"attempt_id"], fixture.request[@"attempt_id"]);
    XCTAssertEqualObjects(event[@"round_id"], fixture.request[@"round_id"]);
    XCTAssertEqualObjects(event[@"round_index"], fixture.request[@"round_index"]);
    XCTAssertEqualObjects(event[@"operation_id"], fixture.request[@"operation_id"]);
    XCTAssertEqualObjects(event[@"provider_request_id"],
                          @"66666666-6666-4666-8666-666666666666");
    XCTAssertEqualObjects(event[@"harness_id"], @"dsh");
    if ([event[@"kind"] isEqual:@"delta"]) {
      if (event[@"text"]) [text appendString:event[@"text"]];
      if (event[@"reasoning"]) [reasoning appendString:event[@"reasoning"]];
    }
  }
  XCTAssertEqualObjects(text, @"done");
  XCTAssertEqualObjects(reasoning, @"think");
  NSDictionary *last = snapshot.lastObject;
  XCTAssertEqualObjects(last[@"kind"], @"end");
  XCTAssertEqualObjects(last[@"status"], @"validated");
  XCTAssertEqualObjects(last[@"truncated"], @NO);
  XCTAssertNil(last[@"failure_code"]);
  for (NSDictionary *event in [snapshot subarrayWithRange:NSMakeRange(0, snapshot.count - 1)]) {
    XCTAssertEqualObjects(event[@"kind"], @"delta");
  }
  NSString *lastFinish = nil;
  for (NSDictionary *event in snapshot) if (event[@"finish_reason"]) lastFinish = event[@"finish_reason"];
  XCTAssertEqualObjects(lastFinish, @"stop");
  [NSFileManager.defaultManager removeItemAtURL:fixture.walRoot error:nil];
}

- (void)testStreamedRoundEndsFailedWhenTheResultDoesNotValidate {
  DSHProviderSmokeFixture *fixture = [[DSHProviderSmokeFixture alloc] init];
  NSMutableDictionary *mismatched = [fixture.transport.result mutableCopy];
  mismatched[@"provider_request_id"] = @"77777777-7777-4777-8777-777777777777";
  DSHProviderStreamingSmokeTransport *transport =
      [self streamingTransportWithResult:mismatched];
  DSHAgentProviderRoundService *service =
      [self streamingServiceForFixture:fixture transport:transport];
  NSMutableArray<NSDictionary *> *events = [NSMutableArray array];
  XCTestExpectation *ended = [self expectationWithDescription:@"end event"];
  service.previewSink = ^(NSDictionary *event) {
    @synchronized (events) { [events addObject:event]; }
    if ([event[@"kind"] isEqual:@"end"]) [ended fulfill];
  };
  NSError *error = nil;
  NSDictionary *result = [service completeAgentRoundV2WithRequest:fixture.request error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"ambiguous");
  [self waitForExpectations:@[ ended ] timeout:5];
  NSDictionary *last = nil;
  @synchronized (events) { last = events.lastObject; }
  XCTAssertEqualObjects(last[@"kind"], @"end");
  XCTAssertEqualObjects(last[@"status"], @"failed");
  XCTAssertTrue([last[@"failure_code"] isKindOfClass:NSString.class]);
  [NSFileManager.defaultManager removeItemAtURL:fixture.walRoot error:nil];
}

- (void)testPreviewSinkWithoutStreamingTransportKeepsTheSingleShotRound {
  DSHProviderSmokeFixture *fixture = [[DSHProviderSmokeFixture alloc] init];
  DSHProviderStreamingSmokeTransport *transport =
      [self streamingTransportWithResult:fixture.transport.result];
  transport.supportsStreaming = NO;
  DSHAgentProviderRoundService *service =
      [self streamingServiceForFixture:fixture transport:transport];
  __block NSUInteger delivered = 0;
  service.previewSink = ^(__unused NSDictionary *event) { delivered += 1; };
  NSError *error = nil;
  NSDictionary *result = [service completeAgentRoundV2WithRequest:fixture.request error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"completed");
  XCTAssertEqual(transport.streamingStarts, (NSUInteger)0);
  XCTAssertEqual(transport.startCount, (NSUInteger)1);
  NSDictionary *body = [NSJSONSerialization JSONObjectWithData:transport.lastBodyData
                                                        options:0 error:nil];
  XCTAssertEqualObjects(body[@"stream"], @NO);
  XCTAssertEqual(delivered, (NSUInteger)0);
  [NSFileManager.defaultManager removeItemAtURL:fixture.walRoot error:nil];
}

- (void)testTransportResolverIsConsultedForEachRoundSelection {
  NSURLSession *session = [NSURLSession sessionWithConfiguration:
      NSURLSessionConfiguration.ephemeralSessionConfiguration];
  CodexProviderTransport *subscriptionLikeTransport =
      [[CodexProviderTransport alloc] initWithSession:session
                                         uuidGenerator:^NSString *{
                                           return @"66666666-6666-4666-8666-666666666666";
                                         }
                                         monotonicClock:^NSTimeInterval {
                                           return 1.0;
                                         }];
  DSHAgentProviderRoundService *service =
      [[DSHAgentProviderRoundService alloc]
          initWithWAL:(DSHAgentNativeWAL *)(id)NSNull.null
          preparedStore:(DSHAgentPreparedAttemptStore *)(id)NSNull.null
          transcripts:(DSHAgentTranscriptStore *)(id)NSNull.null
          rounds:(DSHAgentRoundJournal *)(id)NSNull.null
          transport:(DSHCompletionProviderTransport *)(id)NSNull.null];
  __block NSUInteger resolverCalls = 0;
  service.transportResolver = ^DSHCompletionProviderTransport *(NSString *harnessId) {
    resolverCalls += 1;
    XCTAssertEqualObjects(harnessId, @"codex");
    return subscriptionLikeTransport;
  };
  NSDictionary *request = @{
    @"harness_id" : @"codex",
    @"model" : @"gpt-5.6",
  };
  XCTAssertEqual([service transportForRequest:request], subscriptionLikeTransport);
  XCTAssertEqual([service transportForRequest:request], subscriptionLikeTransport);
  XCTAssertEqual(resolverCalls, (NSUInteger)2);
}

- (void)testConfiguredResolverNilFailsClosedWithoutStaticFallback {
  NSURLSession *session = [NSURLSession sessionWithConfiguration:
      NSURLSessionConfiguration.ephemeralSessionConfiguration];
  CodexProviderTransport *staticTransport =
      [[CodexProviderTransport alloc] initWithSession:session
                                         uuidGenerator:nil
                                         monotonicClock:nil];
  DSHAgentProviderRoundService *service =
      [[DSHAgentProviderRoundService alloc]
          initWithWAL:(DSHAgentNativeWAL *)(id)NSNull.null
          preparedStore:(DSHAgentPreparedAttemptStore *)(id)NSNull.null
          transcripts:(DSHAgentTranscriptStore *)(id)NSNull.null
          rounds:(DSHAgentRoundJournal *)(id)NSNull.null
          transport:(DSHCompletionProviderTransport *)(id)NSNull.null
          claudeTransport:nil codexTransport:staticTransport glmTransport:nil
          credentialProvider:nil visibleHistoryProvider:nil contextReceiptProvider:nil];
  service.transportResolver = ^DSHCompletionProviderTransport *(__unused NSString *harnessId) {
    return nil;
  };
  NSDictionary *request = @{ @"harness_id" : @"codex", @"model" : @"gpt-5.6" };
  XCTAssertNil([service transportForRequest:request]);
}

- (void)testSynchronousBoundTaskReturnedByTransportIsNotCancelled {
  DSHProviderSmokeFixture *fixture = [[DSHProviderSmokeFixture alloc] init];
  fixture.transport.bindAndReturnTask = YES;
  NSDictionary *result = [fixture.service completeAgentRoundV2WithRequest:
      fixture.request error:nil];
  XCTAssertEqualObjects(result[@"status"], @"completed");
  XCTAssertEqual(fixture.transport.cancelCount, (NSUInteger)0);
}

- (void)testProviderRoundServiceRejectsMalformedOpenRequestBeforeDependencies {
  // The malformed request is rejected before any native dependency is read;
  // opaque sentinels therefore cannot be dereferenced by this contract test.
  DSHAgentProviderRoundService *service =
      [[DSHAgentProviderRoundService alloc]
          initWithWAL:(DSHAgentNativeWAL *)(id)NSNull.null
          preparedStore:(DSHAgentPreparedAttemptStore *)(id)NSNull.null
          transcripts:(DSHAgentTranscriptStore *)(id)NSNull.null
          rounds:(DSHAgentRoundJournal *)(id)NSNull.null
          transport:(DSHCompletionProviderTransport *)(id)NSNull.null];
  NSError *error = nil;
  NSDictionary *result = [service completeAgentRoundV2WithRequest:@{}
                                                              error:&error];
  XCTAssertNil(result);
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorInvalidArgument);
}

- (void)testFourHarnessToolRoundsKeepCredentialEndpointBodyAndReceiptIdentity {
  NSArray *cases = @[
    @[ @"dsh", @"deepseek-v4-flash", @"api.deepseek.com", @"/chat/completions" ],
    @[ @"claude-code", @"claude-sonnet-5", @"api.anthropic.com", @"/v1/messages" ],
    @[ @"codex", @"gpt-5.6", @"api.openai.com", @"/v1/responses" ],
    @[ @"glm", @"GLM-5.3", @"open.bigmodel.cn", @"/api/anthropic/v1/messages" ],
  ];
  for (NSArray *entry in cases) {
    [DSHProviderURLProtocol reset];
    NSString *harnessId = entry[0];
    NSString *model = entry[1];
    NSString *credential = [@"synthetic-credential-" stringByAppendingString:harnessId];
    BOOL anthropicDialect = [harnessId isEqual:@"claude-code"] || [harnessId isEqual:@"glm"];
    DSHProviderSmokeFixture *fixture = [[DSHProviderSmokeFixture alloc] init];
    NSMutableDictionary *authority = [fixture.prepared.authority mutableCopy];
    authority[@"model"] = model;
    fixture.prepared.authority = authority;
    NSMutableDictionary *request = [fixture.request mutableCopy];
    request[@"model"] = model;
    request[@"harness_id"] = harnessId;
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.protocolClasses = @[ DSHProviderURLProtocol.class ];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    NSString *(^uuid)(void) = ^NSString *{ return @"66666666-6666-4666-8666-666666666666"; };
    NSTimeInterval (^clock)(void) = ^NSTimeInterval { return 3.0; };
    DshProviderTransport *dsh = [[DshProviderTransport alloc]
        initWithSession:session uuidGenerator:uuid monotonicClock:clock];
    ClaudeProviderTransport *claude = [[ClaudeProviderTransport alloc]
        initWithSession:session uuidGenerator:uuid monotonicClock:clock];
    CodexProviderTransport *codex = [[CodexProviderTransport alloc]
        initWithSession:session uuidGenerator:uuid monotonicClock:clock];
    GlmProviderTransport *glm = [[GlmProviderTransport alloc]
        initWithSession:session uuidGenerator:uuid monotonicClock:clock];
    __block NSUInteger credentialCalls = 0;
    DSHAgentProviderRoundService *service = [[DSHAgentProviderRoundService alloc]
        initWithWAL:fixture.wal preparedStore:fixture.prepared
        transcripts:fixture.transcripts rounds:fixture.rounds
        transport:dsh claudeTransport:claude codexTransport:codex glmTransport:glm
        credentialProvider:^NSString *(NSString *requestedHarness, NSUInteger *generation) {
          credentialCalls += 1;
          XCTAssertEqualObjects(requestedHarness, harnessId);
          if (generation != nullptr) *generation = 7;
          return credential;
        }
        visibleHistoryProvider:^NSArray *(NSDictionary *nativeAuthority, NSError **error) {
          if (error != nullptr) *error = nil;
          return @[ @{ @"role" : @"user", @"content" : @"hello" } ];
        }
        contextReceiptProvider:nil];
    [DSHProviderURLProtocol setHandler:^(NSURLProtocol *protocol, NSURLRequest *httpRequest) {
      XCTAssertEqualObjects(httpRequest.URL.host, entry[2]);
      XCTAssertEqualObjects(httpRequest.URL.path, entry[3]);
      XCTAssertEqualObjects(httpRequest.HTTPMethod, @"POST");
      NSDictionary *body = [NSJSONSerialization JSONObjectWithData:
          DSHProviderCapturedRequestBody(httpRequest) options:0 error:nil];
      XCTAssertEqualObjects(body[@"model"], model);
      XCTAssertEqualObjects(body[@"stream"], @NO);
      NSDictionary *readTool = nil;
      for (NSDictionary *tool in body[@"tools"]) {
        NSString *name = tool[@"name"] ?: tool[@"function"][@"name"];
        if ([name isEqual:@"read_file"]) readTool = tool;
      }
      XCTAssertNotNil(readTool);
      NSDictionary *payload = nil;
      if (anthropicDialect) {
        XCTAssertEqualObjects([httpRequest valueForHTTPHeaderField:@"x-api-key"], credential);
        XCTAssertNil([httpRequest valueForHTTPHeaderField:@"Authorization"]);
        XCTAssertEqualObjects([httpRequest valueForHTTPHeaderField:@"anthropic-version"], @"2023-06-01");
        XCTAssertEqualObjects(body[@"messages"][0][@"content"][0][@"type"], @"text");
        XCTAssertNotNil(readTool[@"input_schema"]);
        XCTAssertNil(readTool[@"function"]);
        payload = @{
          @"id" : @"fixture-response", @"type" : @"message", @"role" : @"assistant",
          @"model" : [harnessId isEqual:@"glm"] ? model.lowercaseString : model,
          @"content" : @[ @{ @"type" : @"tool_use", @"id" : @"call_fixture",
                            @"name" : @"read_file", @"input" : @{ @"path" : @"README.md" } } ],
          @"stop_reason" : @"tool_use", @"stop_sequence" : NSNull.null,
        };
      } else {
        XCTAssertEqualObjects([httpRequest valueForHTTPHeaderField:@"Authorization"],
                              [@"Bearer " stringByAppendingString:credential]);
        XCTAssertNil([httpRequest valueForHTTPHeaderField:@"x-api-key"]);
        if ([harnessId isEqual:@"codex"]) {
          XCTAssertEqualObjects(body[@"store"], @NO);
          XCTAssertNotNil(body[@"input"]);
          XCTAssertNil(body[@"messages"]);
          XCTAssertNotNil(readTool[@"parameters"]);
          payload = @{ @"id" : @"fixture-response", @"object" : @"response",
            @"status" : @"completed", @"model" : model,
            @"output" : @[ @{ @"type" : @"function_call", @"id" : @"fc_fixture",
              @"call_id" : @"call_fixture", @"name" : @"read_file",
              @"arguments" : @"{\"path\":\"README.md\"}" } ] };
        } else {
          XCTAssertEqualObjects(body[@"messages"][0][@"content"], @"hello");
          XCTAssertNotNil(readTool[@"function"][@"parameters"]);
          payload = @{ @"id" : @"fixture-response", @"model" : model,
            @"choices" : @[ @{ @"finish_reason" : @"tool_calls", @"message" : @{
              @"role" : @"assistant", @"content" : @"", @"reasoning_content" : @"",
              @"tool_calls" : @[ @{ @"id" : @"call_fixture", @"type" : @"function",
                @"function" : @{ @"name" : @"read_file",
                  @"arguments" : @"{\"path\":\"README.md\"}" } } ] } } ] };
        }
      }
      NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
      NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc]
          initWithURL:httpRequest.URL statusCode:200 HTTPVersion:@"HTTP/1.1"
          headerFields:@{ @"Content-Type" : @"application/json" }];
      [protocol.client URLProtocol:protocol didReceiveResponse:response
               cacheStoragePolicy:NSURLCacheStorageNotAllowed];
      [protocol.client URLProtocol:protocol didLoadData:data];
      [protocol.client URLProtocolDidFinishLoading:protocol];
    }];
    NSError *error = nil;
    NSDictionary *result = [service completeAgentRoundV2WithRequest:request error:&error];
    XCTAssertNil(error, @"%@", harnessId);
    XCTAssertEqualObjects(result[@"status"], @"completed", @"%@", harnessId);
    XCTAssertEqualObjects(result[@"outcome"][@"kind"], @"tool_batch");
    XCTAssertEqualObjects(result[@"outcome"][@"calls"][0][@"name"], @"read_file");
    NSDictionary *receipt = result[@"outcome"][@"completion_receipt"];
    XCTAssertEqualObjects(receipt[@"harness_id"], harnessId);
    XCTAssertEqualObjects(receipt[@"model"], model);
    XCTAssertEqualObjects(receipt[@"requested_model"], model);
    XCTAssertTrue(credentialCalls > 0);
    XCTAssertEqual([DSHProviderURLProtocol requestCount], (NSUInteger)1);
    XCTAssertEqual(fixture.rounds.completeCount, (NSUInteger)1);
    [session invalidateAndCancel];
    [DSHProviderURLProtocol reset];
  }
}

- (void)testInvalidOrUnwiredHarnessNeverReadsCredentialsOrDispatches {
  NSArray *cases = @[
    @{ @"harness" : @"future-provider", @"model" : @"deepseek-v4-flash" },
    @{ @"harness" : NSNull.null, @"model" : @"deepseek-v4-flash" },
    @{ @"harness" : @"dsh", @"model" : @"GLM-5.3" },
    @{ @"harness" : @"glm", @"model" : @"deepseek-v4-flash" },
    @{ @"harness" : @"glm", @"model" : @"GLM-5.3" },
    @{ @"harness" : @"glm", @"model" : @"GLM-5.3", @"wrong_transport" : @YES },
    @{ @"model" : @"GLM-5.3" },
  ];
  for (NSDictionary *entry in cases) {
    DSHProviderSmokeFixture *fixture = [[DSHProviderSmokeFixture alloc] init];
    NSMutableDictionary *request = [fixture.request mutableCopy];
    request[@"model"] = entry[@"model"];
    if (entry[@"harness"] != nil) request[@"harness_id"] = entry[@"harness"];
    NSMutableDictionary *authority = [fixture.prepared.authority mutableCopy];
    authority[@"model"] = entry[@"model"];
    fixture.prepared.authority = authority;
    __block NSUInteger credentialCalls = 0;
    __block NSUInteger historyCalls = 0;
    DSHAgentProviderRoundService *service = [[DSHAgentProviderRoundService alloc]
        initWithWAL:fixture.wal preparedStore:fixture.prepared
        transcripts:fixture.transcripts rounds:fixture.rounds
        transport:fixture.transport claudeTransport:nil codexTransport:nil
        glmTransport:[entry[@"wrong_transport"] boolValue] ? fixture.transport : nil
        credentialProvider:^NSString *(NSString *harness, NSUInteger *generation) {
          credentialCalls += 1;
          return @"synthetic-must-not-be-read";
        }
        visibleHistoryProvider:^NSArray *(NSDictionary *nativeAuthority, NSError **error) {
          historyCalls += 1;
          return @[];
        }
        contextReceiptProvider:nil];
    XCTAssertNil([service transportForRequest:request]);
    NSError *error = nil;
    XCTAssertNil([service completeAgentRoundV2WithRequest:request error:&error]);
    XCTAssertNotNil(error);
    XCTAssertEqual(credentialCalls, (NSUInteger)0);
    XCTAssertEqual(historyCalls, (NSUInteger)0);
    XCTAssertEqual(fixture.transport.startCount, (NSUInteger)0);
    XCTAssertEqual(fixture.rounds.createCount, (NSUInteger)0);
    XCTAssertEqual(fixture.rounds.dispatchCount, (NSUInteger)0);
  }
}

- (void)testURLProtocolBodyAndDigestEvidenceArriveAfterBoundTransportContext {
  [DSHProviderURLProtocol reset];
  NSURLSessionConfiguration *configuration =
      NSURLSessionConfiguration.ephemeralSessionConfiguration;
  configuration.protocolClasses = @[ DSHProviderURLProtocol.class ];
  DSHProviderURLSessionDelegate *delegate =
      [[DSHProviderURLSessionDelegate alloc] init];
  NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration
                                                          delegate:delegate
                                                     delegateQueue:nil];
  DSHCompletionProviderTransport *transport =
      [[DshProviderTransport alloc]
          initWithSession:session
          uuidGenerator:^NSString *{
            return @"66666666-6666-4666-8666-666666666666";
          }
          monotonicClock:^NSTimeInterval {
            return 3.0;
          }];
  delegate.transport = transport;
  NSArray *messages = @[ @{ @"role" : @"user", @"content" : @"hello" } ];
  NSDictionary *body = @{
    @"model" : @"deepseek-v4-flash",
    @"stream" : @NO,
    @"thinking" : @{ @"type" : @"disabled" },
    @"max_tokens" : @1024,
    @"messages" : messages,
  };
  NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body
                                                       options:NSJSONWritingSortedKeys
                                                         error:nil];
  NSString *visibleDigest = DSHWorkspaceSHA256Hex(
      [NSJSONSerialization dataWithJSONObject:messages
                                       options:NSJSONWritingSortedKeys
                                         error:nil]);
  XCTestExpectation *finished = [self expectationWithDescription:@"provider URLProtocol"];
  [DSHProviderURLProtocol setHandler:^(NSURLProtocol *protocol,
                                        NSURLRequest *request) {
    XCTAssertEqualObjects(request.HTTPMethod, @"POST");
    XCTAssertEqualObjects([request valueForHTTPHeaderField:@"Authorization"],
                          @"Bearer credential");
    NSData *capturedBody = DSHProviderCapturedRequestBody(request);
    XCTAssertEqualObjects(capturedBody, bodyData);
    XCTAssertTrue([[[NSString alloc] initWithData:capturedBody
                                            encoding:NSUTF8StringEncoding]
                   hasPrefix:@"{\"max_tokens\""]);
    NSDictionary *payload = @{
      @"id" : @"response-1",
      @"model" : @"deepseek-v4-flash",
      @"choices" : @[@{
        @"finish_reason" : @"stop",
        @"message" : @{
          @"role" : @"assistant",
          @"content" : @"done",
          @"reasoning_content" : @"",
        },
      }],
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload
                                                     options:0
                                                       error:nil];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc]
        initWithURL:request.URL statusCode:200 HTTPVersion:@"HTTP/1.1"
        headerFields:@{ @"Content-Type" : @"application/json" }];
    [protocol.client URLProtocol:protocol didReceiveResponse:response
             cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [protocol.client URLProtocol:protocol didLoadData:data];
    [protocol.client URLProtocolDidFinishLoading:protocol];
  }];
  NSURLSessionDataTask *task = [transport
      startRequestWithSchemaVersion:2
                              roundId:DSHProviderSmokeRound
                            generation:1
                  credentialGeneration:7
                   providerRequestId:@"66666666-6666-4666-8666-666666666666"
                         credential:@"credential"
                     requestedModel:@"deepseek-v4-flash"
                      thinkingMode:@"off"
       credentialGenerationIsCurrent:^BOOL(NSUInteger generation) {
         return generation == 7;
       }
                            startedAt:2.0
                           bodyData:bodyData
                       visibleHistory:messages
                           modelInput:messages
                             bindTask:^BOOL(NSURLSessionDataTask *candidate) {
                               return [transport handlesTask:candidate];
                             }
                           claimRound:^BOOL(__unused BOOL *redirected) {
                             return YES;
                           }
                        markRedirected:nil
                     redirectDecision:nil
                          completion:^(NSDictionary *result, NSString *errorCode) {
                            XCTAssertNil(errorCode);
                            XCTAssertEqualObjects(result[@"visible_history_sha256"], visibleDigest);
                            XCTAssertEqualObjects(result[@"model_input_sha256"], visibleDigest);
                            XCTAssertEqualObjects(result[@"request_body_sha256"],
                                                  DSHWorkspaceSHA256Hex(bodyData));
                            [finished fulfill];
                          }];
  XCTAssertNotNil(task);
  [self waitForExpectations:@[ finished ] timeout:3.0];
  XCTAssertEqual([DSHProviderURLProtocol requestCount], (NSUInteger)1);
  [session invalidateAndCancel];
  [DSHProviderURLProtocol reset];
}

- (void)testProviderServiceAndJournalExposeOnlyNativeRoundCompositionSelectors {
  XCTAssertTrue([DSHAgentProviderRoundService
      instancesRespondToSelector:@selector(completeAgentRoundV2WithRequest:error:)]);
  XCTAssertTrue([DSHAgentProviderRoundService
      instancesRespondToSelector:@selector(retryFailedAgentRoundV2WithRequest:error:)]);
  XCTAssertTrue([DSHAgentProviderRoundService
      instancesRespondToSelector:@selector(queryAgentRoundWithRequest:error:)]);
  XCTAssertTrue([DSHAgentProviderRoundService
      instancesRespondToSelector:@selector(recoverAgentRoundWithRequest:error:)]);
  XCTAssertTrue([DSHAgentProviderRoundService
      instancesRespondToSelector:@selector(cancelAgentRoundWithRequest:error:)]);
  XCTAssertTrue([DSHAgentRoundJournal
      instancesRespondToSelector:@selector(createAgentRoundV3WithInsertCAS:
                                          exactRoundStart:error:)]);
  XCTAssertTrue([DSHAgentRoundJournal
      instancesRespondToSelector:@selector(markAgentRoundV3DispatchedWithCAS:
                                          error:)]);
  XCTAssertTrue([DSHAgentRoundJournal
      instancesRespondToSelector:@selector(completeAgentRoundV3WithLocator:
                                          expectedCAS:messages:
                                          completionReceipt:terminalKind:calls:root:error:)]);
  XCTAssertTrue([DSHAgentRoundJournal
      instancesRespondToSelector:@selector(cancelAgentRoundV3WithCAS:error:)]);
  XCTAssertTrue([DSHAgentRoundJournal
      instancesRespondToSelector:@selector(queryAgentRoundV3WithLocator:error:)]);
  XCTAssertTrue([DSHAgentRoundJournal
      instancesRespondToSelector:@selector(reconcileAgentRoundV3OwnerLossWithLocator:
                                          expectedCAS:error:)]);
}

- (void)testNativeRoundServiceResultVocabularyDoesNotNameRawPayloadFields {
  NSArray<NSString *> *forbidden = @[
    @"arguments_json", @"raw_arguments", @"raw_result", @"tool_feedback",
    @"messages", @"native_envelope", @"precondition", @"settled_facts",
    @"patch", @"owner", @"path", @"content",
  ];
  NSArray<NSString *> *safeResultKeys = @[
    @"schema_version", @"status", @"operation_id", @"task_id",
    @"attempt_id", @"round_id", @"round_index", @"launch_attempt",
    @"result_round_revision", @"transcript", @"outcome",
  ];
  for (NSString *key in safeResultKeys) {
    XCTAssertFalse([forbidden containsObject:key]);
  }
}

- (void)testRuntimeRoundWritesBeforeTransportAndExactReplaySkipsDependencies {
  DSHProviderSmokeFixture *fixture = [[DSHProviderSmokeFixture alloc] init];
  NSError *error = nil;
  NSDictionary *first = [fixture.service completeAgentRoundV2WithRequest:fixture.request
                                                                     error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(first[@"status"], @"completed");
  XCTAssertEqual(fixture.rounds.createCount, (NSUInteger)1);
  XCTAssertEqual(fixture.rounds.dispatchCount, (NSUInteger)1);
  XCTAssertEqual(fixture.rounds.completeCount, (NSUInteger)1);
  XCTAssertEqual(fixture.transport.startCount, (NSUInteger)1);
  XCTAssertTrue(fixture.historyCalls > 0);
  NSDictionary *body = [NSJSONSerialization JSONObjectWithData:fixture.transport.lastBodyData
                                                        options:0
                                                          error:&error];
  XCTAssertNil(error);
  XCTAssertTrue([fixture.transport.lastBodyData length] > 0);
  XCTAssertTrue([[[NSString alloc] initWithData:fixture.transport.lastBodyData
                                        encoding:NSUTF8StringEncoding]
      hasPrefix:@"{\"max_tokens\""]);
  NSDictionary *bodyTool = body[@"tools"][0];
  XCTAssertEqualObjects(bodyTool[@"type"], @"function");
  XCTAssertTrue([bodyTool[@"function"] isKindOfClass:NSDictionary.class]);
  XCTAssertEqualObjects(bodyTool[@"function"][@"name"], @"list_dir");
  XCTAssertEqualObjects(fixture.transport.lastModelInput,
                        (@[ @{ @"role" : @"user", @"content" : @"hello" } ]));
  XCTAssertEqualObjects(first[@"outcome"][@"completion_receipt"][@"task_id"],
                        DSHProviderSmokeTask);

  fixture.historyAvailable = NO;
  fixture.credentialAvailable = NO;
  NSDictionary *replay = [fixture.service completeAgentRoundV2WithRequest:fixture.request
                                                                      error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(replay[@"status"], @"completed");
  XCTAssertEqual(fixture.transport.startCount, (NSUInteger)1);
  XCTAssertEqual(fixture.rounds.completeCount, (NSUInteger)1);
  [NSFileManager.defaultManager removeItemAtURL:fixture.walRoot error:nil];
}

- (void)testCancelSignalsPendingCallbackAndStaleSelectorConflicts {
  DSHProviderSmokeFixture *fixture = [[DSHProviderSmokeFixture alloc] init];
  fixture.transport.holdResponse = YES;
  dispatch_semaphore_t completed = dispatch_semaphore_create(0);
  __block NSDictionary *roundResult = nil;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
    NSError *error = nil;
    roundResult = [fixture.service completeAgentRoundV2WithRequest:fixture.request
                                                              error:&error];
    XCTAssertNil(error);
    dispatch_semaphore_signal(completed);
  });
  NSDate *waitUntil = [NSDate dateWithTimeIntervalSinceNow:2.0];
  while (fixture.transport.startCount == 0 &&
         [waitUntil timeIntervalSinceNow] > 0) {
    [[NSRunLoop currentRunLoop] runUntilDate:
        [NSDate dateWithTimeIntervalSinceNow:0.01]];
  }
  XCTAssertEqual(fixture.transport.startCount, (NSUInteger)1);
  NSDictionary *cancelRequest = DSHProviderSmokeQueryRequest(
      fixture.root, fixture.transcript, 2, YES);
  NSTimeInterval started = CFAbsoluteTimeGetCurrent();
  NSError *cancelError = nil;
  __block NSDictionary *cancel = nil;
  __block NSError *serializedCancelError = nil;
  DSHSessionWorkspacePerformSync(^{
    NSDictionary *query = [fixture.service queryAgentRoundWithRequest:
        DSHProviderSmokeQueryRequest(fixture.root, fixture.transcript, 2, NO) error:nil];
    XCTAssertEqualObjects(query[@"status"], @"in_flight");
    cancel = [fixture.service cancelAgentRoundWithRequest:cancelRequest error:&serializedCancelError];
  });
  cancelError = serializedCancelError;
  XCTAssertNil(cancelError);
  XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - started, 2.0);
  XCTAssertEqualObjects(cancel[@"status"], @"cancel_requested");
  XCTAssertEqual(dispatch_semaphore_wait(completed,
                                         dispatch_time(DISPATCH_TIME_NOW,
                                                       2 * NSEC_PER_SEC)), 0);
  XCTAssertEqualObjects(roundResult[@"status"], @"ambiguous");
  void (^lateCompletion)(NSDictionary *, NSString *) = fixture.transport.pendingCompletion;
  if (lateCompletion != nil) {
    lateCompletion(fixture.transport.heldResult, nil);
  }
  XCTAssertEqualObjects(roundResult[@"status"], @"ambiguous");

  XCTAssertEqual(fixture.rounds.completeCount, (NSUInteger)0);

  NSDictionary *stale = DSHProviderSmokeQueryRequest(
      fixture.root, fixture.transcript, 1, NO);
  NSDictionary *staleResult = [fixture.service queryAgentRoundWithRequest:stale
                                                                      error:&cancelError];
  XCTAssertNil(cancelError);
  XCTAssertEqualObjects(staleResult[@"status"], @"conflict");
  [NSFileManager.defaultManager removeItemAtURL:fixture.walRoot error:nil];
}

- (void)testSuccessfulLateProviderResultCannotApplyAfterSourceOrAuthorityChange {
  for (NSString *change in @[@"transport", @"credential", @"authority"]) {
    DSHProviderSmokeFixture *fixture = [[DSHProviderSmokeFixture alloc] init];
    fixture.transport.holdResponse = YES;
    __block DSHCompletionProviderTransport *current = fixture.transport;
    fixture.service.transportResolver = ^DSHCompletionProviderTransport *(NSString *harnessId) {
      return current;
    };
    XCTestExpectation *started = [self expectationWithDescription:@"response held"];
    fixture.transport.responseHeld = ^{ [started fulfill]; };
    XCTestExpectation *finished = [self expectationWithDescription:@"late response rejected"];
    __block NSDictionary *result = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
      result = [fixture.service completeAgentRoundV2WithRequest:fixture.request error:nil];
      [finished fulfill];
    });
    [self waitForExpectations:@[started] timeout:2];
    DSHSessionWorkspacePerformSync(^{
      if ([change isEqual:@"transport"]) current = nil;
      else if ([change isEqual:@"credential"]) fixture.credentialGeneration += 1;
      else {
        NSMutableDictionary *authority = [fixture.prepared.authority mutableCopy];
        authority[@"authority_revision"] = @999;
        fixture.prepared.authority = authority;
      }
      if (fixture.transport.pendingCompletion)
        fixture.transport.pendingCompletion(fixture.transport.heldResult, nil);
    });
    [self waitForExpectations:@[finished] timeout:2];
    XCTAssertNotEqualObjects(result[@"status"], @"completed", @"%@", change);
    XCTAssertEqual(fixture.rounds.completeCount, (NSUInteger)0, @"%@", change);
    XCTAssertEqual(fixture.transport.startCount, (NSUInteger)1);
  }
}

- (void)testAsyncBoundTaskUsesOriginalTransportAfterResolverSourceSwitch {
  DSHProviderSmokeFixture *fixture = [[DSHProviderSmokeFixture alloc] init];
  fixture.transport.deferBind = YES;
  __block DSHCompletionProviderTransport *current = fixture.transport;
  fixture.service.transportResolver = ^DSHCompletionProviderTransport *(__unused NSString *harnessId) {
    return current;
  };
  dispatch_semaphore_t completed = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
    [fixture.service completeAgentRoundV2WithRequest:fixture.request error:nil];
    dispatch_semaphore_signal(completed);
  });
  NSDate *waitUntil = [NSDate dateWithTimeIntervalSinceNow:2.0];
  while (fixture.transport.deferredTask == nil && [waitUntil timeIntervalSinceNow] > 0) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  }
  XCTAssertNotNil(fixture.transport.deferredTask);
  XCTAssertNotNil(fixture.transport.deferredBind);
  if (fixture.transport.deferredBind == nil) {
    XCTFail(@"transport did not capture bind callback");
    return;
  }
  XCTAssertTrue(fixture.transport.deferredBind(fixture.transport.deferredTask));
  current = nil;
  NSDictionary *cancelRequest = DSHProviderSmokeQueryRequest(
      fixture.root, fixture.transcript, 2, YES);
  [fixture.service cancelAgentRoundWithRequest:cancelRequest error:nil];
  XCTAssertEqual(fixture.transport.cancelCount, (NSUInteger)1);
  XCTAssertFalse(fixture.transport.deferredBind(fixture.transport.deferredTask));
  XCTAssertEqual(dispatch_semaphore_wait(completed,
      dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)), 0);

  DSHProviderSmokeFixture *beforeBind = [[DSHProviderSmokeFixture alloc] init];
  beforeBind.transport.deferBind = YES;
  dispatch_semaphore_t waiting = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
    [beforeBind.service completeAgentRoundV2WithRequest:beforeBind.request error:nil];
    dispatch_semaphore_signal(waiting);
  });
  waitUntil = [NSDate dateWithTimeIntervalSinceNow:2.0];
  while (beforeBind.transport.deferredTask == nil && [waitUntil timeIntervalSinceNow] > 0) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  }
  XCTAssertNotNil(beforeBind.transport.deferredBind);
  if (beforeBind.transport.deferredBind == nil) {
    XCTFail(@"transport did not capture pre-cancel bind callback");
    return;
  }
  NSDictionary *beforeCancel = DSHProviderSmokeQueryRequest(
      beforeBind.root, beforeBind.transcript, 2, YES);
  [beforeBind.service cancelAgentRoundWithRequest:beforeCancel error:nil];
  XCTAssertEqual(beforeBind.transport.cancelCount, (NSUInteger)0);
  XCTAssertFalse(beforeBind.transport.deferredBind(beforeBind.transport.deferredTask));
  XCTAssertEqual(dispatch_semaphore_wait(waiting,
      dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)), 0);
}

- (void)testProviderErrorMatrixKeepsStableClosedCodes {
  XCTAssertEqualObjects(DSHProviderFailureCode(@"E_COMPLETION_LENGTH", NO),
                        @"E_COMPLETION_LENGTH");
  XCTAssertEqualObjects(DSHProviderFailureCode(@"E_AGENT_CANCELLED", NO),
                        @"E_AGENT_CANCELLED");
  XCTAssertEqualObjects(DSHProviderFailureCode(@"E_COMPLETION_REDIRECT", NO),
                        @"E_AGENT_CONFLICT");
  XCTAssertEqualObjects(DSHProviderFailureCode(@"E_COMPLETION_HTTP_STATUS", NO),
                        @"E_AGENT_TOOL_FAILED");
  XCTAssertEqualObjects(DSHProviderFailureCode(@"E_COMPLETION_RESPONSE_JSON", NO),
                        @"E_AGENT_TRANSCRIPT");
  XCTAssertEqualObjects(DSHProviderFailureCode(@"E_COMPLETION_TRANSPORT", NO),
                        @"E_AGENT_ROUND_AMBIGUOUS");
  XCTAssertEqualObjects(DSHProviderFailureCode(nil, YES), @"E_AGENT_TRANSCRIPT");
  for (NSString *code in @[@"E_COMPLETION_RESPONSE_MODEL", @"E_COMPLETION_MODEL_MISMATCH", @"E_COMPLETION_PROVIDER_RESPONSE_ID"]) {
    XCTAssertEqualObjects(DSHProviderFailureCode(code, NO), @"E_AGENT_TRANSCRIPT");
  }
}

- (void)testCompatWriteDefaultsCreateOnlyRevisionAndCompletesToolBatch {
  DSHProviderSmokeFixture *fixture = [[DSHProviderSmokeFixture alloc] init];
  XCTAssertEqualObjects(fixture.prepared.authority[@"registry"][@"registry_version"], @3);
  XCTAssertEqualObjects(fixture.request[@"registry_version"], fixture.prepared.authority[@"registry"][@"registry_version"]);
  NSString *encoded = @"{\"name\":\"write_file\",\"arguments\":{\"path\":\"RISH_HARNESS_PROOF_20260901.md\",\"content\":\"Rish real-device harness proof.\"}}";
  NSError *error = nil;
  NSDictionary *parsed = DSHParseCompletionResponseSchema2(@{
    @"id" : @"response-compat",
    @"model" : @"deepseek-v4-flash",
    @"choices" : @[@{
      @"finish_reason" : @"stop",
      @"message" : @{ @"role" : @"assistant", @"content" : encoded },
    }],
  }, @"deepseek-v4-flash", @"off", &error);
  XCTAssertNotNil(parsed, @"%@", error);
  XCTAssertNil(error);
  XCTAssertEqualObjects(parsed[@"finish_reason"], @"tool_calls");
  NSDictionary *call = parsed[@"tool_calls"][0];
  XCTAssertTrue(DSHProviderOpaqueId(call[@"id"]));
  XCTAssertNotNil([fixture.prepared.toolRegistry
      descriptorForToolName:call[@"name"] root:fixture.root error:&error]);
  XCTAssertNil(error);
  XCTAssertEqualObjects(call[@"arguments"],
      @"{\"content\":\"Rish real-device harness proof.\",\"expected_revision\":null,\"path\":\"RISH_HARNESS_PROOF_20260901.md\"}");
  XCTAssertNotNil(DSHAgentArgumentsSHA256(call[@"name"], call[@"arguments"],
                                          &error));
  XCTAssertNil(error);

  NSMutableDictionary *provider = [parsed mutableCopy];
  provider[@"provider_request_id"] =
      @"66666666-6666-4666-8666-666666666666";
  provider[@"requested_model"] = @"deepseek-v4-flash";
  provider[@"thinking_mode"] = @"off";
  provider[@"latency_ms"] = @1;
  provider[@"visible_history_sha256"] = DSHProviderSmokeDigest;
  provider[@"model_input_sha256"] = DSHProviderSmokeDigest;
  provider[@"request_body_sha256"] = DSHProviderSmokeDigest;
  fixture.transport.result = [provider copy];
  error = nil;
  NSDictionary *result = [fixture.service
      completeAgentRoundV2WithRequest:fixture.request error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"completed");
  XCTAssertEqualObjects(result[@"outcome"][@"kind"], @"tool_batch");
  XCTAssertEqual(fixture.rounds.completeCount, (NSUInteger)1);
  XCTAssertEqualObjects(fixture.rounds.completedMessages[0][@"tool_calls"][0]
                             [@"arguments_json"],
                        call[@"arguments"]);
  NSDictionary *body = [NSJSONSerialization
      JSONObjectWithData:fixture.transport.lastBodyData options:0 error:&error];
  XCTAssertNil(error);
  NSDictionary *writeFunction = nil;
  for (NSDictionary *tool in body[@"tools"]) {
    if ([tool[@"function"][@"name"] isEqualToString:@"write_file"]) {
      writeFunction = tool[@"function"];
      break;
    }
  }
  XCTAssertNotNil(writeFunction);
  XCTAssertTrue([writeFunction[@"description"] containsString:@"omit expected_revision or pass JSON null"]);
  XCTAssertTrue([writeFunction[@"description"] containsString:@"asserts the file does not exist"]);
  XCTAssertTrue([writeFunction[@"description"] containsString:@"exact revision"]);
  XCTAssertEqualObjects(writeFunction[@"parameters"][@"properties"]
                             [@"expected_revision"][@"type"],
                        (@[@"string", @"null"]));
  XCTAssertFalse([writeFunction[@"parameters"][@"required"]
      containsObject:@"expected_revision"]);
  NSDictionary *state = [fixture.wal snapshotWithError:nil];
  XCTAssertEqualObjects(state[@"operations"][0][@"state"], @"committed");
}

- (void)testFrozenLegacyRegistryKeepsOriginalProviderWriteSchemas {
  DSHProviderSmokeFixture *fixture = [[DSHProviderSmokeFixture alloc] init];
  NSArray *cases = @[
    @{@"version":@1, @"digest":@"89e677a4e537ca45b7f4ac300cb0ba110d9ca9717e872d522e1b0c2036fc00cb", @"type":@"string", @"required":@NO},
    @{@"version":@1, @"digest":@"6ac56c1bdcf7619b062a4d93eac9886cd68dc352a36cd8573e35ba749edde5b9", @"type":@"string", @"required":@YES},
    @{@"version":@1, @"digest":@"e12ce6ea32bb3f634151a2c886deb5b409362c773893e8a29c27923f578a7098", @"type":@[@"string", @"null"], @"required":@YES},
    @{@"version":@2, @"digest":@"62e426ffac0cc058b8affcbc8744549eeb91bc9a99923bb1982ec42c47e8a60c", @"type":@"string", @"required":@NO},
    @{@"version":@2, @"digest":@"bbdeb99de07223175703fb9748e16444f1f89e0b072283d030be9017c2fdebd4", @"type":@"string", @"required":@NO},
  ];
  NSMutableArray *safeTools = [NSMutableArray array];
  for (NSDictionary *tool in fixture.prepared.authority[@"registry"][@"tools"])
    if ([@[@"list_dir", @"read_file", @"write_file"] containsObject:tool[@"name"]]) [safeTools addObject:tool];
  for (NSDictionary *history in cases) {
    NSDictionary *legacy = DSHAgentImmutableJSONCopy(@{@"schema_version":@2,
      @"registry_version":history[@"version"], @"toolset_sha256":history[@"digest"], @"tools":[safeTools copy]}, nil);
    NSError *error = nil;
    XCTAssertTrue([DSHAgentToolRegistry validateRegistryProjection:legacy root:fixture.root error:&error]);
    XCTAssertNil(error);
    NSMutableDictionary *authority = [fixture.prepared.authority mutableCopy]; authority[@"registry"] = legacy;
    NSArray *providerTools = DSHProviderToolsForAuthority([authority copy], fixture.prepared.toolRegistry, &error);
    XCTAssertNotNil(providerTools); XCTAssertNil(error); XCTAssertEqual(providerTools.count, 3U);
    NSDictionary *writeFunction = nil;
    for (NSDictionary *tool in providerTools)
      if ([tool[@"function"][@"name"] isEqual:@"write_file"]) writeFunction = tool[@"function"];
    XCTAssertNotNil(writeFunction);
    XCTAssertEqualObjects(writeFunction[@"parameters"][@"properties"][@"expected_revision"][@"type"], history[@"type"]);
    XCTAssertEqual([writeFunction[@"parameters"][@"required"] containsObject:@"expected_revision"], [history[@"required"] boolValue]);
    XCTAssertFalse([[providerTools valueForKeyPath:@"function.name"] containsObject:@"list_runtime_environments"]);

    // A complete legacy request, not just a standalone descriptor lookup,
    // must send the old table even though this registry instance defaults v3.
    DSHProviderSmokeFixture *legacyFixture = [[DSHProviderSmokeFixture alloc] init];
    legacyFixture.prepared.authority = [authority copy];
    NSMutableDictionary *legacyRequest = [legacyFixture.request mutableCopy];
    legacyRequest[@"registry_version"] = history[@"version"];
    legacyRequest[@"toolset_sha256"] = history[@"digest"];
    NSDictionary *result = [legacyFixture.service completeAgentRoundV2WithRequest:[legacyRequest copy] error:&error];
    XCTAssertNil(error); XCTAssertEqualObjects(result[@"status"], @"completed");
    XCTAssertEqual(legacyFixture.transport.startCount, 1U);
    NSDictionary *body = [NSJSONSerialization JSONObjectWithData:legacyFixture.transport.lastBodyData options:0 error:&error];
    XCTAssertNil(error); XCTAssertEqualObjects(body[@"tools"], providerTools);
    [NSFileManager.defaultManager removeItemAtURL:legacyFixture.walRoot error:nil];
  }
  [NSFileManager.defaultManager removeItemAtURL:fixture.walRoot error:nil];
}

- (void)testProviderRejectsWrongRegistryVersionBeforeDispatchEvenWithMatchingDigest {
  for (NSNumber *wrongVersion in @[@1, @2]) {
    DSHProviderSmokeFixture *fixture = [[DSHProviderSmokeFixture alloc] init];
    NSMutableDictionary *request = [fixture.request mutableCopy]; request[@"registry_version"] = wrongVersion;
    XCTAssertEqualObjects(request[@"toolset_sha256"], fixture.prepared.authority[@"registry"][@"toolset_sha256"]);
    NSError *error = nil;
    NSDictionary *result = [fixture.service completeAgentRoundV2WithRequest:[request copy] error:&error];
    XCTAssertNil(error); XCTAssertEqualObjects(result[@"status"], @"conflict");
    XCTAssertEqualObjects(result[@"failure_code"], @"E_AGENT_CONFLICT");
    XCTAssertEqual(fixture.transport.startCount, 0U); XCTAssertEqual(fixture.rounds.createCount, 0U);
    [NSFileManager.defaultManager removeItemAtURL:fixture.walRoot error:nil];
  }
}

- (void)testProviderReceiptCorrelationMustMatchTheReservedRequest {
  DSHProviderSmokeFixture *fixture = [[DSHProviderSmokeFixture alloc] init];
  NSMutableDictionary *result = [fixture.transport.result mutableCopy];
  result[@"provider_request_id"] = @"77777777-7777-4777-8777-777777777777";
  result[@"requested_model"] = @"deepseek-v4-pro";
  result[@"model"] = @"deepseek-v4-pro";
  result[@"thinking_mode"] = @"max";
  fixture.transport.result = [result copy];
  NSError *error = nil;
  NSDictionary *output = [fixture.service completeAgentRoundV2WithRequest:fixture.request
                                                                       error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(output[@"status"], @"ambiguous");
  XCTAssertEqualObjects(output[@"failure_code"], @"E_AGENT_TRANSCRIPT");
  XCTAssertEqual(fixture.rounds.completeCount, (NSUInteger)0);
  [NSFileManager.defaultManager removeItemAtURL:fixture.walRoot error:nil];
}

- (void)testCredentialGenerationChangeSettlesWithoutWaitingForTimeout {
  DSHProviderSmokeFixture *fixture = [[DSHProviderSmokeFixture alloc] init];
  fixture.transport.rejectCredentialGeneration = YES;
  NSTimeInterval started = CFAbsoluteTimeGetCurrent();
  NSError *error = nil;
  NSDictionary *result = [fixture.service completeAgentRoundV2WithRequest:fixture.request
                                                                      error:&error];
  XCTAssertNil(error);
  XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - started, 2.0);
  XCTAssertEqualObjects(result[@"status"], @"ambiguous");
  XCTAssertEqual(fixture.transport.startCount, (NSUInteger)1);
  [NSFileManager.defaultManager removeItemAtURL:fixture.walRoot error:nil];
}

- (void)testCredentialUnavailableAfterRoundStartCommitsSafeAmbiguousOperation {
  DSHProviderSmokeFixture *fixture = [[DSHProviderSmokeFixture alloc] init];
  fixture.credentialAvailable = NO;
  NSError *error = nil;
  NSDictionary *result = [fixture.service completeAgentRoundV2WithRequest:fixture.request
                                                                     error:&error];
  XCTAssertNil(result);
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorUnavailable);
  error = nil;
  NSDictionary *state = [fixture.wal snapshotWithError:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(state[@"operations"][0][@"state"], @"ambiguous");
  fixture.credentialAvailable = YES;
  NSDictionary *replay = [fixture.service completeAgentRoundV2WithRequest:fixture.request
                                                                      error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(replay[@"status"], @"ambiguous");
  XCTAssertEqual(fixture.transport.startCount, (NSUInteger)0);
  [NSFileManager.defaultManager removeItemAtURL:fixture.walRoot error:nil];
}

- (void)testOwnerLossPreservesRetryableAndAmbiguousOutcomes {
  DSHProviderSmokeFixture *fixture = [[DSHProviderSmokeFixture alloc] init];
  NSDictionary *locator = @{
    @"schema_version" : @1,
    @"task_id" : DSHProviderSmokeTask,
    @"attempt_id" : DSHProviderSmokeAttempt,
    @"round_id" : DSHProviderSmokeRound,
    @"round_index" : @0,
  };
  NSDictionary *owner = @{
    @"schema_version" : @1,
    @"task_id" : DSHProviderSmokeTask,
    @"launch_id" : @"99999999-9999-4999-8999-999999999999",
    @"native_task_id" : @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    @"owner_generation" : @1,
    @"heartbeat_at" : @"2023-11-14T22:13:20.000Z",
  };
  fixture.rounds.row = @{
    @"schema_version" : @3,
    @"locator" : locator,
    @"row_revision" : @1,
    @"root_fingerprint_sha256" : DSHProviderSmokeRootDigest,
    @"binding_revision" : @7,
    @"request_sha256" : DSHProviderSmokeDigest,
    @"transcript_before" : fixture.transcript,
    @"launch_attempt" : @1,
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
    @"created_at" : @"2023-11-14T22:13:20.000Z",
    @"updated_at" : @"2023-11-14T22:13:20.000Z",
  };
  fixture.rounds.reconcileToFailedRetryable = YES;
  NSError *error = nil;
  NSDictionary *request = DSHProviderSmokeQueryRequest(
      fixture.root, fixture.transcript, 1, NO);
  NSDictionary *retryable = [fixture.service recoverAgentRoundWithRequest:request
                                                                        error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(retryable[@"status"], @"failed_retryable");
  XCTAssertEqual(fixture.rounds.reconcileCount, (NSUInteger)1);
  XCTAssertEqualObjects(retryable[@"failure_code"], @"E_AGENT_PERSISTENCE");
  [NSFileManager.defaultManager removeItemAtURL:fixture.walRoot error:nil];
}

- (void)testRecoverCompletedRoundReturnsExactRedactedProjection {
  DSHProviderSmokeFixture *fixture = [[DSHProviderSmokeFixture alloc] init];
  NSError *error = nil;
  NSDictionary *completed = [fixture.service
      completeAgentRoundV2WithRequest:fixture.request error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(completed[@"status"], @"completed");
  fixture.transcripts.messages = @[
    @{
      @"schema_version" : @1,
      @"role" : @"assistant",
      @"round_index" : @0,
      @"content" : @"done",
      @"reasoning_content" : @"",
      @"tool_calls" : @[],
    },
  ];
  NSDictionary *selector = DSHProviderSmokeQueryRequest(
      fixture.root, fixture.transcript, 3, NO);
  NSDictionary *recovered = [fixture.service recoverAgentRoundWithRequest:selector
                                                                       error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(recovered[@"status"], @"completed");
  NSDictionary *round = recovered[@"completed_round"];
  XCTAssertEqualObjects(round[@"text"], @"done");
  XCTAssertEqualObjects(round[@"schema_version"], @2);
  XCTAssertEqual([round[@"assistant_text_sha256"] length], (NSUInteger)64);
  XCTAssertEqual([round[@"reasoning_text_sha256"] length], (NSUInteger)64);
  XCTAssertEqualObjects(round[@"transcript"], fixture.transcript);
  XCTAssertNil(round[@"content"]);
  XCTAssertNil(round[@"arguments_json"]);
  [NSFileManager.defaultManager removeItemAtURL:fixture.walRoot error:nil];
}

- (void)testSchema3ContextIsOrderedBeforeUserAndReceiptIsRedacted {
  DSHProviderSmokeFixture *fixture = [[DSHProviderSmokeFixture alloc] init];
  NSDictionary *projectRoot = @{
    @"schema_version" : @1,
    @"kind" : @"project",
    @"workspace_id" : @"77777777-7777-4777-8777-777777777777",
    @"workspace_binding_revision" : @7,
    @"project_id" : @"99999999-9999-4999-8999-999999999999",
    @"root_fingerprint_sha256" : DSHProviderSmokeRootDigest,
    @"capabilities" : @[ @"file_read", @"file_write", @"git_status",
                          @"git_commit", @"git_push" ],
  };
  DSHAgentToolRegistry *registry = [[DSHAgentToolRegistry alloc] init];
  NSError *registryError = nil;
  NSDictionary *projectRegistry = [registry registryForRoot:projectRoot
                                                       error:&registryError];
  XCTAssertNil(registryError);
  fixture.root = projectRoot;
  fixture.prepared.root = projectRoot;
  NSMutableDictionary *authority = [fixture.prepared.authority mutableCopy];
  authority[@"root"] = projectRoot;
  authority[@"registry"] = projectRegistry;
  NSString *contextDigest = DSHAgentHJ(@"project-context", @{
    @"schema_version" : @1,
    @"project_id" : projectRoot[@"project_id"],
    @"context_bytes" : @16,
  }, nil);
  authority[@"transport_schema_version"] = @3;
  authority[@"project_context_sha256"] = contextDigest;
  fixture.prepared.authority = authority;
  NSMutableDictionary *request = [fixture.request mutableCopy];
  request[@"operation_id"] = @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
  request[@"transport_schema_version"] = @3;
  request[@"project_context_sha256"] = contextDigest;
  request[@"root"] = projectRoot;
  fixture.request = [request copy];
  NSDictionary *contextReceipt = @{
    @"schema_version" : @1,
    @"snapshot_id" : @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    @"snapshot_sha256" : DSHProviderSmokeSessionDigest,
    @"source_fingerprint" : DSHProviderSmokeRootDigest,
    @"context_bytes" : @16,
    @"verified_at" : @"2023-11-14T22:13:20.000Z",
  };
  fixture.service = [[DSHAgentProviderRoundService alloc]
      initWithWAL:fixture.wal
      preparedStore:fixture.prepared
      transcripts:fixture.transcripts
      rounds:fixture.rounds
      transport:fixture.transport
      credentialProvider:^NSString *(NSString *harnessId, NSUInteger *generation) {
        if (generation != nullptr) *generation = 7;
        return @"credential";
      }
      visibleHistoryProvider:^NSArray *(NSDictionary *nativeAuthority, NSError **error) {
        (void)nativeAuthority;
        if (error != nullptr) *error = nil;
        return @[ @{ @"role" : @"user", @"content" : @"hello" } ];
      }
      contextReceiptProvider:^NSDictionary *(NSDictionary *nativeAuthority, NSError **error) {
        (void)nativeAuthority;
        if (error != nullptr) *error = nil;
        return @{
          @"project_context_sha256" : contextDigest,
          @"receipt" : contextReceipt,
          @"messages" : @[
            @{ @"role" : @"system", @"content" : @"verified context",
               @"attachments" : @[] },
          ],
        };
      }];
  NSError *error = nil;
  NSDictionary *result = [fixture.service completeAgentRoundV2WithRequest:fixture.request
                                                                      error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"completed");
  NSDictionary *body = [NSJSONSerialization JSONObjectWithData:fixture.transport.lastBodyData
                                                        options:0
                                                          error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(body[@"messages"][0][@"role"], @"system");
  XCTAssertEqualObjects(body[@"messages"][1][@"role"], @"user");
  XCTAssertEqualObjects(result[@"outcome"][@"completion_receipt"][@"project_context_receipt"],
                        contextReceipt);
  XCTAssertEqualObjects(result[@"outcome"][@"completion_receipt"][@"task_id"],
                        DSHProviderSmokeTask);
  [NSFileManager.defaultManager removeItemAtURL:fixture.walRoot error:nil];
}

- (void)testSchema3CannotCrossAnExplicitWithoutContextAuthority {
  DSHProviderSmokeFixture *fixture = [[DSHProviderSmokeFixture alloc] init];
  NSDictionary *contextReceipt = @{
    @"schema_version" : @1,
    @"snapshot_id" : @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    @"snapshot_sha256" : DSHProviderSmokeSessionDigest,
    @"source_fingerprint" : DSHProviderSmokeRootDigest,
    @"context_bytes" : @7,
    @"verified_at" : @"2023-11-14T22:13:20.000Z",
  };
  NSMutableDictionary *request = [fixture.request mutableCopy];
  request[@"transport_schema_version"] = @3;
  request[@"project_context_sha256"] = DSHProviderSmokeDigest;
  fixture.service = [[DSHAgentProviderRoundService alloc]
      initWithWAL:fixture.wal
      preparedStore:fixture.prepared
      transcripts:fixture.transcripts
      rounds:fixture.rounds
      transport:fixture.transport
      credentialProvider:^NSString *(NSString *harnessId, NSUInteger *generation) {
        if (generation != nullptr) *generation = 7;
        return @"credential";
      }
      visibleHistoryProvider:^NSArray *(NSDictionary *authority, NSError **error) {
        if (error != nullptr) *error = nil;
        return @[ @{ @"role" : @"user", @"content" : @"hello" } ];
      }
      contextReceiptProvider:^NSDictionary *(NSDictionary *authority, NSError **error) {
        if (error != nullptr) *error = nil;
        return @{
          @"project_context_sha256" : DSHProviderSmokeDigest,
          @"receipt" : contextReceipt,
          @"messages" : @[
            @{ @"role" : @"system", @"content" : @"context",
               @"attachments" : @[] },
          ],
        };
      }];
  NSError *error = nil;
  NSDictionary *result = [fixture.service completeAgentRoundV2WithRequest:[request copy]
                                                                      error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"conflict");
  XCTAssertEqualObjects(result[@"failure_code"], @"E_AGENT_CONFLICT");
  XCTAssertEqual(fixture.transport.startCount, (NSUInteger)0);
  [NSFileManager.defaultManager removeItemAtURL:fixture.walRoot error:nil];
}

- (void)testMissingContextBundlePreservesStorageFailure {
  NSError *original = [NSError errorWithDomain:@"dev.zseven.rish.project-context-service" code:6 userInfo:nil];
  NSError *error = original;
  NSDictionary *receipt = nil;
  NSArray *messages = nil;
  XCTAssertFalse(DSHProviderContextBundle(nil, DSHProviderSmokeDigest, &receipt, &messages, &error));
  XCTAssertEqual(error, original);
  XCTAssertNil(receipt);
  XCTAssertNil(messages);
}

- (void)testSchema3ContextBundleDigestMustMatchFrozenRequest {
  NSDictionary *receipt = @{
    @"schema_version" : @1,
    @"snapshot_id" : @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    @"snapshot_sha256" : DSHProviderSmokeSessionDigest,
    @"source_fingerprint" : DSHProviderSmokeRootDigest,
    @"context_bytes" : @7,
    @"verified_at" : @"2023-11-14T22:13:20.000Z",
  };
  NSDictionary *bundle = @{
    @"project_context_sha256" : DSHProviderSmokeDigest,
    @"receipt" : receipt,
    @"messages" : @[
      @{ @"role" : @"system", @"content" : @"context",
         @"attachments" : @[] },
    ],
  };
  NSDictionary *ignoredReceipt = nil;
  NSArray *ignoredMessages = nil;
  NSError *error = nil;
  XCTAssertFalse(DSHProviderContextBundle(
      bundle, @"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
      &ignoredReceipt, &ignoredMessages, &error));
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorConflict);
  XCTAssertNil(ignoredReceipt);
  XCTAssertNil(ignoredMessages);
}

- (void)testStartedOperationRecoversCompletedRoundWithoutAnotherHTTPRequest {
  DSHProviderSmokeFixture *fixture =
      [[DSHProviderSmokeFixture alloc] initWithFaultingCommit:YES];
  fixture.rounds.failNextWALTransactionAfterComplete = YES;
  NSError *error = nil;
  NSDictionary *first = [fixture.service completeAgentRoundV2WithRequest:fixture.request
                                                                     error:&error];
  XCTAssertNil(first);
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorPersistence);
  error = nil;
  NSDictionary *state = [fixture.wal snapshotWithError:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(state[@"operations"][0][@"state"], @"started");
  XCTAssertEqualObjects(fixture.rounds.row[@"state"], @"completed");

  fixture.transcripts.messages = @[
    @{
      @"schema_version" : @1,
      @"role" : @"assistant",
      @"round_index" : @0,
      @"content" : @"done",
      @"reasoning_content" : @"",
      @"tool_calls" : @[],
    },
  ];
  fixture.historyAvailable = NO;
  fixture.credentialAvailable = NO;
  NSDictionary *recovered = [fixture.service completeAgentRoundV2WithRequest:fixture.request
                                                                         error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(recovered[@"status"], @"completed");
  XCTAssertEqualObjects(recovered[@"outcome"][ @"text"], @"done");
  XCTAssertEqual(fixture.transport.startCount, (NSUInteger)1);
  state = [fixture.wal snapshotWithError:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(state[@"operations"][0][@"state"], @"committed");
  [NSFileManager.defaultManager removeItemAtURL:fixture.walRoot error:nil];
}

- (void)testRealWALJournalTransportAndTranscriptComposeOneRoundEndToEnd {
  [DSHProviderURLProtocol reset];
  NSURL *walRoot = [NSURL fileURLWithPath:[NSTemporaryDirectory()
      stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
  DSHAgentNativeWAL *wal = [[DSHAgentNativeWAL alloc]
      initWithRootURL:walRoot
      clock:^NSDate *{
        return [NSDate dateWithTimeIntervalSince1970:1700000000];
      }
      identifierGenerator:^NSString *{
        return @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
      }
      faultHook:nil];
  NSError *error = nil;
  NSDictionary *root = DSHProviderSmokeRoot();
  DSHAgentTranscriptStore *transcripts = [[DSHAgentTranscriptStore alloc]
      initWithWAL:wal];
  NSDictionary *transcript = [transcripts
      createAgentTranscriptWithRequest:@{
        @"schema_version" : @1,
        @"attempt_id" : DSHProviderSmokeAttempt,
        @"root" : root,
      }
      error:&error];
  XCTAssertNotNil(transcript);
  XCTAssertNil(error);
  DSHAgentToolRegistry *registry = [[DSHAgentToolRegistry alloc] init];
  NSDictionary *registryProjection = [registry registryForRoot:root error:&error];
  XCTAssertNotNil(registryProjection);
  XCTAssertNil(error);
  NSDictionary *authority = DSHProviderSmokeAuthority(root, transcript,
                                                      registryProjection);
  DSHProviderSmokePreparedStore *prepared =
      [[DSHProviderSmokePreparedStore alloc] initWithAuthority:authority
                                                           root:root
                                                            wal:wal];
  DSHAgentRoundJournal *rounds = [[DSHAgentRoundJournal alloc] initWithWAL:wal];
  NSURLSessionConfiguration *configuration =
      NSURLSessionConfiguration.ephemeralSessionConfiguration;
  configuration.protocolClasses = @[ DSHProviderURLProtocol.class ];
  DSHProviderURLSessionDelegate *delegate =
      [[DSHProviderURLSessionDelegate alloc] init];
  NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration
                                                          delegate:delegate
                                                     delegateQueue:nil];
  DSHCompletionProviderTransport *transport =
      [[DshProviderTransport alloc]
          initWithSession:session
          uuidGenerator:^NSString *{
            return @"66666666-6666-4666-8666-666666666666";
          }
          monotonicClock:^NSTimeInterval {
            return 3.0;
          }];
  delegate.transport = transport;
  [DSHProviderURLProtocol setHandler:^(NSURLProtocol *protocol,
                                        NSURLRequest *request) {
    XCTAssertEqualObjects(request.HTTPMethod, @"POST");
    XCTAssertEqualObjects([request valueForHTTPHeaderField:@"Authorization"],
                          @"Bearer credential");
    NSDictionary *requestBody = [NSJSONSerialization
        JSONObjectWithData:DSHProviderCapturedRequestBody(request)
                   options:0
                     error:nil];
    XCTAssertEqualObjects(requestBody[@"model"], @"deepseek-v4-flash");
    XCTAssertEqualObjects(requestBody[@"messages"][0][@"role"], @"user");
    XCTAssertTrue([requestBody[@"tools"] isKindOfClass:NSArray.class]);
    NSDictionary *payload = @{
      @"id" : @"response-1",
      @"model" : @"deepseek-v4-flash",
      @"choices" : @[@{
        @"finish_reason" : @"stop",
        @"message" : @{
          @"role" : @"assistant",
          @"content" : @"done",
          @"reasoning_content" : @"",
        },
      }],
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload
                                                     options:0
                                                       error:nil];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc]
        initWithURL:request.URL statusCode:200 HTTPVersion:@"HTTP/1.1"
        headerFields:@{ @"Content-Type" : @"application/json" }];
    [protocol.client URLProtocol:protocol didReceiveResponse:response
             cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [protocol.client URLProtocol:protocol didLoadData:data];
    [protocol.client URLProtocolDidFinishLoading:protocol];
  }];
  DSHAgentProviderRoundService *service =
      [[DSHAgentProviderRoundService alloc]
          initWithWAL:wal
          preparedStore:prepared
          transcripts:transcripts
          rounds:rounds
          transport:transport
          credentialProvider:^NSString *(NSString *harnessId, NSUInteger *generation) {
            if (generation != nullptr) *generation = 7;
            return @"credential";
          }
          visibleHistoryProvider:^NSArray *(NSDictionary *nativeAuthority,
                                             NSError **historyError) {
            if (historyError != nullptr) *historyError = nil;
            return @[ @{ @"role" : @"user", @"content" : @"hello" } ];
          }];
  NSDictionary *request = DSHProviderSmokeRequest(
      root, transcript, registryProjection[@"toolset_sha256"],
      DSHProviderSmokeOperation);
  NSDictionary *result = [service completeAgentRoundV2WithRequest:request
                                                             error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"completed");
  XCTAssertEqual([DSHProviderURLProtocol requestCount], (NSUInteger)1);
  NSDictionary *state = [wal snapshotWithError:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(state[@"operations"][0][@"state"], @"committed");
  XCTAssertEqualObjects(state[@"rounds"][0][@"state"], @"completed");
  XCTAssertEqual([(NSArray *)state[@"transcripts"][0][@"messages"] count],
                 (NSUInteger)1);

  DSHAgentProviderRoundService *replayService =
      [[DSHAgentProviderRoundService alloc]
          initWithWAL:wal
          preparedStore:prepared
          transcripts:transcripts
          rounds:rounds
          transport:transport];
  NSDictionary *replay = [replayService completeAgentRoundV2WithRequest:request
                                                                     error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(replay, result);
  XCTAssertEqual([DSHProviderURLProtocol requestCount], (NSUInteger)1);
  [session invalidateAndCancel];
  [NSFileManager.defaultManager removeItemAtURL:walRoot error:nil];
  [DSHProviderURLProtocol reset];
}

- (void)testClaudeCodeToolRoundComposesThroughTheProviderAgnosticService {
  [DSHProviderURLProtocol reset];
  NSURL *walRoot = [NSURL fileURLWithPath:[NSTemporaryDirectory()
      stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
  DSHAgentNativeWAL *wal = [[DSHAgentNativeWAL alloc]
      initWithRootURL:walRoot
      clock:^NSDate *{
        return [NSDate dateWithTimeIntervalSince1970:1700000000];
      }
      identifierGenerator:^NSString *{
        return @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
      }
      faultHook:nil];
  NSError *error = nil;
  NSDictionary *root = DSHProviderSmokeRoot();
  DSHAgentTranscriptStore *transcripts = [[DSHAgentTranscriptStore alloc]
      initWithWAL:wal];
  NSDictionary *transcript = [transcripts
      createAgentTranscriptWithRequest:@{
        @"schema_version" : @1,
        @"attempt_id" : DSHProviderSmokeAttempt,
        @"root" : root,
      }
      error:&error];
  XCTAssertNotNil(transcript);
  DSHAgentToolRegistry *registry = [[DSHAgentToolRegistry alloc] init];
  NSDictionary *registryProjection = [registry registryForRoot:root error:&error];
  XCTAssertNotNil(registryProjection);
  NSMutableDictionary *authority = [DSHProviderSmokeAuthority(
      root, transcript, registryProjection) mutableCopy];
  authority[@"model"] = @"claude-sonnet-5";
  DSHProviderSmokePreparedStore *prepared =
      [[DSHProviderSmokePreparedStore alloc] initWithAuthority:authority
                                                           root:root
                                                            wal:wal];
  DSHAgentRoundJournal *rounds = [[DSHAgentRoundJournal alloc] initWithWAL:wal];
  NSURLSessionConfiguration *configuration =
      NSURLSessionConfiguration.ephemeralSessionConfiguration;
  configuration.protocolClasses = @[ DSHProviderURLProtocol.class ];
  DSHProviderURLSessionDelegate *delegate =
      [[DSHProviderURLSessionDelegate alloc] init];
  NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration
                                                          delegate:delegate
                                                     delegateQueue:nil];
  NSString *(^uuid)(void) = ^NSString *{
    return @"66666666-6666-4666-8666-666666666666";
  };
  NSTimeInterval (^clock)(void) = ^NSTimeInterval { return 3.0; };
  DshProviderTransport *dsh = [[DshProviderTransport alloc]
      initWithSession:session uuidGenerator:uuid monotonicClock:clock];
  ClaudeProviderTransport *claude = [[ClaudeProviderTransport alloc]
      initWithSession:session uuidGenerator:uuid monotonicClock:clock];
  delegate.transport = claude;
  __block NSDictionary *requestBody = nil;
  __block NSDictionary *requestHeaders = nil;
  __block NSURL *requestURL = nil;
  [DSHProviderURLProtocol setHandler:^(NSURLProtocol *protocol,
                                        NSURLRequest *request) {
    requestURL = request.URL;
    requestHeaders = request.allHTTPHeaderFields;
    requestBody = [NSJSONSerialization
        JSONObjectWithData:DSHProviderCapturedRequestBody(request)
                   options:0
                     error:nil];
    NSDictionary *payload = @{
      @"id" : @"msg_claude_round",
      @"type" : @"message",
      @"role" : @"assistant",
      @"model" : @"claude-sonnet-5",
      @"content" : @[
        @{ @"type" : @"text", @"text" : @"Writing the proof." },
        @{ @"type" : @"tool_use", @"id" : @"toolu_01", @"name" : @"write_file",
           @"input" : @{ @"path" : @"RISH_HARNESS_PROOF_20260901.md",
                         @"content" : @"Rish real-device harness proof." } },
      ],
      @"stop_reason" : @"tool_use",
      @"stop_sequence" : NSNull.null,
      @"usage" : @{ @"input_tokens" : @20, @"output_tokens" : @30 },
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload
                                                     options:0
                                                       error:nil];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc]
        initWithURL:request.URL statusCode:200 HTTPVersion:@"HTTP/1.1"
        headerFields:@{ @"Content-Type" : @"application/json" }];
    [protocol.client URLProtocol:protocol didReceiveResponse:response
             cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [protocol.client URLProtocol:protocol didLoadData:data];
    [protocol.client URLProtocolDidFinishLoading:protocol];
  }];
  __block NSString *credentialHarness = nil;
  DSHAgentProviderRoundService *service =
      [[DSHAgentProviderRoundService alloc]
          initWithWAL:wal
          preparedStore:prepared
          transcripts:transcripts
          rounds:rounds
          transport:dsh
          claudeTransport:claude
          codexTransport:nil
          credentialProvider:^NSString *(NSString *harnessId, NSUInteger *generation) {
            credentialHarness = harnessId;
            if (generation != nullptr) *generation = 7;
            return @"sk-ant-credential";
          }
          visibleHistoryProvider:^NSArray *(NSDictionary *nativeAuthority,
                                             NSError **historyError) {
            if (historyError != nullptr) *historyError = nil;
            return @[ @{ @"role" : @"user", @"content" : @"hello" } ];
          }
          contextReceiptProvider:nil];
  NSMutableDictionary *request = [DSHProviderSmokeRequest(
      root, transcript, registryProjection[@"toolset_sha256"],
      DSHProviderSmokeOperation) mutableCopy];
  request[@"model"] = @"claude-sonnet-5";
  request[@"harness_id"] = @"claude-code";
  NSDictionary *result = [service completeAgentRoundV2WithRequest:request
                                                             error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"completed");
  XCTAssertEqual([DSHProviderURLProtocol requestCount], (NSUInteger)1);
  // The Anthropic dialect went over the wire with the shared tool registry.
  XCTAssertEqualObjects(credentialHarness, @"claude-code");
  XCTAssertEqualObjects(requestURL.host, @"api.anthropic.com");
  XCTAssertEqualObjects(requestHeaders[@"x-api-key"], @"sk-ant-credential");
  XCTAssertEqualObjects(requestHeaders[@"anthropic-version"], @"2023-06-01");
  XCTAssertNil(requestHeaders[@"Authorization"]);
  XCTAssertEqualObjects(requestBody[@"model"], @"claude-sonnet-5");
  XCTAssertEqualObjects(requestBody[@"thinking"], @{ @"type" : @"disabled" });
  XCTAssertEqualObjects(requestBody[@"messages"][0][@"role"], @"user");
  XCTAssertEqualObjects(requestBody[@"messages"][0][@"content"][0][@"type"], @"text");
  NSDictionary *writeTool = nil;
  for (NSDictionary *tool in requestBody[@"tools"]) {
    if ([tool[@"name"] isEqualToString:@"write_file"]) writeTool = tool;
  }
  XCTAssertNotNil(writeTool);
  XCTAssertNotNil(writeTool[@"input_schema"][@"properties"][@"expected_revision"]);
  XCTAssertNil(writeTool[@"function"], @"Anthropic tools are flat, not OpenAI-wrapped");
  // The round result is the same provider-agnostic tool batch DSH produces.
  NSDictionary *outcome = result[@"outcome"];
  XCTAssertEqualObjects(outcome[@"kind"], @"tool_batch");
  XCTAssertEqualObjects(outcome[@"finish_reason"], @"tool_calls");
  XCTAssertEqualObjects(outcome[@"calls"][0][@"name"], @"write_file");
  XCTAssertEqualObjects(outcome[@"calls"][0][@"call_id"], @"toolu_01");
  NSDictionary *receipt = outcome[@"completion_receipt"];
  XCTAssertEqualObjects(receipt[@"harness_id"], @"claude-code");
  XCTAssertEqualObjects(receipt[@"model"], @"claude-sonnet-5");
  XCTAssertEqualObjects(receipt[@"requested_model"], @"claude-sonnet-5");
  XCTAssertEqualObjects(receipt[@"provider_response_id"], @"msg_claude_round");
  NSDictionary *state = [wal snapshotWithError:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(state[@"operations"][0][@"state"], @"committed");
  XCTAssertEqualObjects(state[@"rounds"][0][@"state"], @"completed");
  NSArray *messages = state[@"transcripts"][0][@"messages"];
  XCTAssertEqual(messages.count, (NSUInteger)1);
  XCTAssertEqualObjects(messages[0][@"tool_calls"][0][@"name"], @"write_file");
  XCTAssertEqualObjects(messages[0][@"tool_calls"][0][@"arguments_json"],
      @"{\"content\":\"Rish real-device harness proof.\",\"expected_revision\":null,\"path\":\"RISH_HARNESS_PROOF_20260901.md\"}");
  [session invalidateAndCancel];
  [NSFileManager.defaultManager removeItemAtURL:walRoot error:nil];
  [DSHProviderURLProtocol reset];
}

- (void)testRetryFailedRoundClaimsExistingRowAndNeverCreatesAnotherRound {
  NSURL *walRoot = [NSURL fileURLWithPath:[NSTemporaryDirectory()
      stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
  DSHAgentNativeWAL *wal = [[DSHAgentNativeWAL alloc]
      initWithRootURL:walRoot
      clock:^NSDate *{
        return [NSDate dateWithTimeIntervalSince1970:1700000000];
      }
      identifierGenerator:^NSString *{
        return @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
      }
      faultHook:nil];
  NSError *error = nil;
  NSDictionary *root = DSHProviderSmokeRoot();
  DSHAgentTranscriptStore *transcripts = [[DSHAgentTranscriptStore alloc]
      initWithWAL:wal];
  NSDictionary *transcript = [transcripts
      createAgentTranscriptWithRequest:@{
        @"schema_version" : @1,
        @"attempt_id" : DSHProviderSmokeAttempt,
        @"root" : root,
      }
      error:&error];
  XCTAssertNotNil(transcript);
  XCTAssertNil(error);
  DSHAgentToolRegistry *registry = [[DSHAgentToolRegistry alloc] init];
  NSDictionary *registryProjection = [registry registryForRoot:root error:&error];
  XCTAssertNotNil(registryProjection);
  XCTAssertNil(error);
  NSDictionary *authority = DSHProviderSmokeAuthority(root, transcript,
                                                      registryProjection);
  DSHProviderSmokePreparedStore *prepared =
      [[DSHProviderSmokePreparedStore alloc] initWithAuthority:authority
                                                           root:root
                                                            wal:wal];
  DSHAgentRoundJournal *rounds = [[DSHAgentRoundJournal alloc] initWithWAL:wal];
  DSHProviderSmokeTransport *transport = [[DSHProviderSmokeTransport alloc]
      initWithResult:@{
        @"provider_request_id" : @"66666666-6666-4666-8666-666666666666",
        @"provider_response_id" : @"response-retry",
        @"requested_model" : @"deepseek-v4-flash",
        @"model" : @"deepseek-v4-flash",
        @"thinking_mode" : @"off",
        @"text" : @"retried",
        @"reasoning" : @"",
        @"tool_calls" : @[],
        @"finish_reason" : @"stop",
        @"latency_ms" : @1,
        @"visible_history_sha256" : DSHProviderSmokeDigest,
        @"model_input_sha256" : DSHProviderSmokeDigest,
        @"request_body_sha256" : DSHProviderSmokeDigest,
      }];
  DSHAgentProviderRoundService *service =
      [[DSHAgentProviderRoundService alloc]
          initWithWAL:wal
          preparedStore:prepared
          transcripts:transcripts
          rounds:rounds
          transport:transport
          credentialProvider:^NSString *(NSString *harnessId, NSUInteger *generation) {
            if (generation != nullptr) *generation = 7;
            return @"credential";
          }
          visibleHistoryProvider:^NSArray *(NSDictionary *nativeAuthority,
                                             NSError **historyError) {
            if (historyError != nullptr) *historyError = nil;
            return @[ @{ @"role" : @"user", @"content" : @"hello" } ];
          }];
  NSMutableDictionary *request = [DSHProviderSmokeRequest(
      root, transcript, registryProjection[@"toolset_sha256"],
      @"99999999-9999-4999-8999-999999999999") mutableCopy];
  request[@"expected_round_revision"] = @1;
  request[@"launch_attempt"] = @2;
  NSString *requestSHA = DSHAgentHJ(@"agent-operation-request", @{
    @"operation_kind" : @"complete_agent_round_v2",
    @"request" : request,
  }, &error);
  XCTAssertNotNil(requestSHA);
  XCTAssertNil(error);
  NSDictionary *locator = DSHProviderRoundLocator(request);
  NSDictionary *failed = @{
    @"schema_version" : @3,
    @"locator" : locator,
    @"row_revision" : @1,
    @"root_fingerprint_sha256" : root[@"root_fingerprint_sha256"],
    @"binding_revision" : @7,
    @"request_sha256" : requestSHA,
    @"transcript_before" : transcript,
    @"launch_attempt" : @1,
    @"state" : @"failed_retryable",
    @"owner" : NSNull.null,
    @"failure_code" : @"E_AGENT_PERSISTENCE",
    @"completion_receipt" : NSNull.null,
    @"transcript_after" : NSNull.null,
    @"calls" : @[],
    @"batch_class" : NSNull.null,
    @"executable_call_count" : @0,
    @"denied_call_count" : @0,
    @"terminal_kind" : NSNull.null,
    @"created_at" : wal.currentTimestamp,
    @"updated_at" : wal.currentTimestamp,
  };
  BOOL inserted = [wal performAtomicTransaction:^BOOL(
      NSMutableDictionary *state, NSError **mutationError) {
    NSMutableArray *roundRows = [state[@"rounds"] mutableCopy];
    NSMutableArray *dispatch = [state[@"dispatch"] mutableCopy];
    [roundRows addObject:failed];
    [dispatch addObject:@{
      @"schema_version" : @1,
      @"kind" : @"round",
      @"locator" : locator,
      @"dispatch_state" : @"not_dispatched",
    }];
    state[@"rounds"] = roundRows;
    state[@"dispatch"] = dispatch;
    return YES;
  } error:&error];
  XCTAssertTrue(inserted);
  XCTAssertNil(error);

  NSDictionary *result = [service retryFailedAgentRoundV2WithRequest:request
                                                                  error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"completed");
  XCTAssertEqual(transport.startCount, (NSUInteger)1);
  NSDictionary *state = [wal snapshotWithError:&error];
  XCTAssertNil(error);
  XCTAssertEqual([(NSArray *)state[@"rounds"] count], (NSUInteger)1);
  NSDictionary *round = state[@"rounds"][0];
  XCTAssertEqualObjects(round[@"state"], @"completed");
  XCTAssertEqualObjects(round[@"launch_attempt"], @2);
  XCTAssertEqualObjects(round[@"row_revision"], @4);
  XCTAssertEqualObjects(state[@"dispatch"][0][@"dispatch_state"], @"dispatched");
  [NSFileManager.defaultManager removeItemAtURL:walRoot error:nil];
}

- (void)testRoundV3ClaimAdvancesRevisionAndRequiresRetryableState {
  NSURL *walRoot = [NSURL fileURLWithPath:[NSTemporaryDirectory()
      stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
  DSHAgentNativeWAL *wal = [[DSHAgentNativeWAL alloc]
      initWithRootURL:walRoot
      clock:^NSDate *{
        return [NSDate dateWithTimeIntervalSince1970:1700000000];
      }
      identifierGenerator:^NSString *{
        return @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
      }
      faultHook:nil];
  NSError *error = nil;
  NSDictionary *root = DSHProviderSmokeRoot();
  DSHAgentTranscriptStore *transcripts = [[DSHAgentTranscriptStore alloc]
      initWithWAL:wal];
  NSDictionary *transcript = [transcripts
      createAgentTranscriptWithRequest:@{
        @"schema_version" : @1,
        @"attempt_id" : DSHProviderSmokeAttempt,
        @"root" : root,
      }
      error:&error];
  XCTAssertNotNil(transcript);
  NSDictionary *locator = @{
    @"schema_version" : @1,
    @"task_id" : DSHProviderSmokeTask,
    @"attempt_id" : DSHProviderSmokeAttempt,
    @"round_id" : DSHProviderSmokeRound,
    @"round_index" : @0,
  };
  NSDictionary *row = @{
    @"schema_version" : @3,
    @"locator" : locator,
    @"row_revision" : @1,
    @"root_fingerprint_sha256" : root[@"root_fingerprint_sha256"],
    @"binding_revision" : @7,
    @"request_sha256" : DSHProviderSmokeDigest,
    @"transcript_before" : transcript,
    @"launch_attempt" : @1,
    @"state" : @"failed_retryable",
    @"owner" : NSNull.null,
    @"failure_code" : @"E_AGENT_PERSISTENCE",
    @"completion_receipt" : NSNull.null,
    @"transcript_after" : NSNull.null,
    @"calls" : @[],
    @"batch_class" : NSNull.null,
    @"executable_call_count" : @0,
    @"denied_call_count" : @0,
    @"terminal_kind" : NSNull.null,
    @"created_at" : wal.currentTimestamp,
    @"updated_at" : wal.currentTimestamp,
  };
  BOOL inserted = [wal performAtomicTransaction:^BOOL(
      NSMutableDictionary *state, NSError **mutationError) {
    NSMutableArray *roundRows = [state[@"rounds"] mutableCopy];
    NSMutableArray *dispatch = [state[@"dispatch"] mutableCopy];
    [roundRows addObject:row];
    [dispatch addObject:@{
      @"schema_version" : @1,
      @"kind" : @"round",
      @"locator" : locator,
      @"dispatch_state" : @"not_dispatched",
    }];
    state[@"rounds"] = roundRows;
    state[@"dispatch"] = dispatch;
    return YES;
  } error:&error];
  XCTAssertTrue(inserted);
  XCTAssertNil(error);
  NSString *nativeTaskId = @"99999999-9999-4999-8999-999999999999";
  XCTAssertTrue([wal registerNativeTaskId:nativeTaskId error:&error]);
  NSDictionary *owner = @{
    @"schema_version" : @1,
    @"task_id" : DSHProviderSmokeTask,
    @"launch_id" : wal.launchId,
    @"native_task_id" : nativeTaskId,
    @"owner_generation" : @1,
    @"heartbeat_at" : wal.currentTimestamp,
  };
  DSHAgentRoundJournal *journal = [[DSHAgentRoundJournal alloc] initWithWAL:wal];
  NSDictionary *claimed = [journal claimAgentRoundV3WithLocator:locator
                                               expectedRowRevision:@1
                                                              owner:owner
                                                              error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(claimed[@"row"][@"row_revision"], @2);
  XCTAssertEqualObjects(claimed[@"row"][@"state"], @"in_flight");
  XCTAssertEqualObjects(claimed[@"row"][@"launch_attempt"], @2);
  XCTAssertEqualObjects(claimed[@"row"][@"owner"], owner);
  XCTAssertTrue([wal unregisterNativeTaskId:nativeTaskId error:&error]);
  [NSFileManager.defaultManager removeItemAtURL:walRoot error:nil];
}

- (void)testRoundV3CancelBeforeDispatchCannotBecomeRetryable {
  NSURL *walRoot = [NSURL fileURLWithPath:[NSTemporaryDirectory()
      stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
  DSHAgentNativeWAL *wal = [[DSHAgentNativeWAL alloc]
      initWithRootURL:walRoot
      clock:^NSDate *{
        return [NSDate dateWithTimeIntervalSince1970:1700000000];
      }
      identifierGenerator:^NSString *{
        return @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
      }
      faultHook:nil];
  NSError *error = nil;
  NSDictionary *root = DSHProviderSmokeRoot();
  DSHAgentTranscriptStore *transcripts = [[DSHAgentTranscriptStore alloc]
      initWithWAL:wal];
  NSDictionary *transcript = [transcripts
      createAgentTranscriptWithRequest:@{
        @"schema_version" : @1,
        @"attempt_id" : DSHProviderSmokeAttempt,
        @"root" : root,
      }
      error:&error];
  NSDictionary *locator = @{
    @"schema_version" : @1,
    @"task_id" : DSHProviderSmokeTask,
    @"attempt_id" : DSHProviderSmokeAttempt,
    @"round_id" : DSHProviderSmokeRound,
    @"round_index" : @0,
  };
  NSDictionary *deadOwner = @{
    @"schema_version" : @1,
    @"task_id" : DSHProviderSmokeTask,
    @"launch_id" : wal.launchId,
    @"native_task_id" : @"99999999-9999-4999-8999-999999999999",
    @"owner_generation" : @1,
    @"heartbeat_at" : wal.currentTimestamp,
  };
  NSDictionary *row = @{
    @"schema_version" : @3,
    @"locator" : locator,
    @"row_revision" : @1,
    @"root_fingerprint_sha256" : root[@"root_fingerprint_sha256"],
    @"binding_revision" : @7,
    @"request_sha256" : DSHProviderSmokeDigest,
    @"transcript_before" : transcript,
    @"launch_attempt" : @1,
    @"state" : @"cancel_requested",
    @"owner" : deadOwner,
    @"failure_code" : NSNull.null,
    @"completion_receipt" : NSNull.null,
    @"transcript_after" : NSNull.null,
    @"calls" : @[],
    @"batch_class" : NSNull.null,
    @"executable_call_count" : @0,
    @"denied_call_count" : @0,
    @"terminal_kind" : NSNull.null,
    @"created_at" : wal.currentTimestamp,
    @"updated_at" : wal.currentTimestamp,
  };
  BOOL inserted = [wal performAtomicTransaction:^BOOL(
      NSMutableDictionary *state, NSError **mutationError) {
    NSMutableArray *roundRows = [state[@"rounds"] mutableCopy];
    NSMutableArray *dispatch = [state[@"dispatch"] mutableCopy];
    [roundRows addObject:row];
    [dispatch addObject:@{
      @"schema_version" : @1,
      @"kind" : @"round",
      @"locator" : locator,
      @"dispatch_state" : @"not_dispatched",
    }];
    state[@"rounds"] = roundRows;
    state[@"dispatch"] = dispatch;
    return YES;
  } error:&error];
  XCTAssertTrue(inserted);
  XCTAssertNil(error);
  DSHAgentRoundJournal *journal = [[DSHAgentRoundJournal alloc] initWithWAL:wal];
  NSDictionary *cas = DSHProviderRoundCASForRow(row);
  NSDictionary *reconciled = [journal
      reconcileAgentRoundV3OwnerLossWithLocator:locator
                                      expectedCAS:cas
                                             error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(reconciled[@"row"][@"state"], @"cancelled");
  XCTAssertEqualObjects(reconciled[@"row"][@"failure_code"],
                        @"E_AGENT_CANCELLED");
  [NSFileManager.defaultManager removeItemAtURL:walRoot error:nil];
}


- (void)testCustomProviderIdentitySurvivesNativeRoundAndOperationReplay {
  DSHProviderSmokeFixture *fixture = [[DSHProviderSmokeFixture alloc] init];
  NSMutableDictionary *authority = [fixture.prepared.authority mutableCopy]; authority[@"model"] = @"claude-sonnet-5";
  fixture.prepared.authority = authority;
  NSString *suite = [@"custom-round-" stringByAppendingString:NSUUID.UUID.UUIDString];
  NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
  DSHProviderConfigurationStore *profiles = [[DSHProviderConfigurationStore alloc] initWithDefaults:defaults];
  [profiles saveConfiguration:@{@"schema_version": @1, @"harness_id": @"claude-code", @"name": @"Relay",
      @"endpoint_url": @"https://relay.example/v1/messages", @"protocol": @"messages", @"auth_type": @"bearer",
      @"send_reasoning": @NO, @"model_mappings": @{@"claude-sonnet-5": @"relay-model"}} error:nil];
  NSURLSessionConfiguration *sessionConfiguration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
  sessionConfiguration.protocolClasses = @[DSHProviderURLProtocol.class];
  NSURLSession *session = [NSURLSession sessionWithConfiguration:sessionConfiguration];
  DSHConfiguredProviderTransport *transport = [[DSHConfiguredProviderTransport alloc] initWithHarness:@"claude-code"
      session:session uuidGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }
      monotonicClock:nil store:profiles];
  DSHAgentProviderRoundService *service = [[DSHAgentProviderRoundService alloc]
      initWithWAL:fixture.wal preparedStore:fixture.prepared transcripts:fixture.transcripts rounds:fixture.rounds
      transport:fixture.transport claudeTransport:transport codexTransport:nil glmTransport:nil
      credentialProvider:^NSString *(NSString *harness, NSUInteger *generation) {
        XCTAssertEqualObjects(harness, @"claude-code"); if (generation) *generation = 1; return @"synthetic-relay-key";
      } visibleHistoryProvider:^NSArray *(NSDictionary *value, NSError **error) {
        return @[@{@"role": @"user", @"content": @"hello"}];
      } contextReceiptProvider:nil];
  [DSHProviderURLProtocol setHandler:^(NSURLProtocol *p, NSURLRequest *request) {
    XCTAssertEqualObjects(request.URL.host, @"relay.example");
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"id": @"custom-round-response", @"model": @"relay-model",
      @"content": @[@{@"type": @"text", @"text": @"answer"}], @"stop_reason": @"end_turn"} options:0 error:nil];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type": @"application/json"}];
    [p.client URLProtocol:p didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [p.client URLProtocol:p didLoadData:data]; [p.client URLProtocolDidFinishLoading:p];
  }];
  NSMutableDictionary *request = [fixture.request mutableCopy]; request[@"model"] = @"claude-sonnet-5"; request[@"harness_id"] = @"claude-code";
  NSError *error = nil;
  NSDictionary *result = [service completeAgentRoundV2WithRequest:request error:&error];
  XCTAssertNotNil(result, @"%@", error);
  NSDictionary *binding = result[@"outcome"][@"completion_receipt"][@"provider_configuration"];
  XCTAssertEqualObjects(binding[@"model_id"], @"relay-model");
  XCTAssertTrue(DSHValidateProviderBinding(binding, @"claude-sonnet-5"));
  NSDictionary *replayed = [service completeAgentRoundV2WithRequest:request error:&error];
  XCTAssertEqualObjects(replayed, result);
  XCTAssertEqual([DSHProviderURLProtocol requestCount], 1u);
  [session invalidateAndCancel]; [defaults removePersistentDomainForName:suite];
}

// The older "real WAL" smoke test substitutes prepared authority. This case
// exercises the actual first-send storage graph, including the session proof
// the production prepared store reads before and after each WAL operation.
- (void)testFreshWorkspaceSessionCASPreparesAndCompletesRealStoredAgentRound {
  [self runFreshWorkspaceRoundFailingWALWrite:0];
}

- (void)testFreshWorkspaceRoundCreationFailureDoesNotDispatchProvider {
  [self runFreshWorkspaceRoundFailingWALWrite:2];
}

- (void)runFreshWorkspaceRoundFailingWALWrite:(NSUInteger)failedWrite {
  [DSHProviderURLProtocol reset];
  NSURL *testRoot = [NSURL fileURLWithPath:[NSTemporaryDirectory()
      stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
  NSURLSession *session = nil;
  @try {
    NSURL *documents = [testRoot URLByAppendingPathComponent:@"Documents" isDirectory:YES];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:documents
        withIntermediateDirectories:YES attributes:nil error:nil]);
    NSURL *privateRoot = [testRoot URLByAppendingPathComponent:@"workspaces" isDirectory:YES];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:privateRoot
        withIntermediateDirectories:YES attributes:@{ NSFilePosixPermissions : @0700 } error:nil]);
    DSHLocalWorkspaceAccess *workspaces = [[DSHLocalWorkspaceAccess alloc]
        initWithPrivateRootURL:privateRoot
        documentsRootURL:documents clock:^NSDate * { return NSDate.date; }
        UUIDGenerator:^NSString * { return NSUUID.UUID.UUIDString.lowercaseString; }
        legacyResolver:^BOOL(__unused NSString *projectId, __unused NSDictionary **evidence,
                              __unused NSError **error) { return NO; } faultHook:nil];
    NSError *error = nil;
    XCTAssertTrue([workspaces ensurePrivateLayoutWithError:&error], @"workspace layout: %@", error);
    XCTAssertNil(error);
    NSDictionary *workspace = [workspaces createRishOwnedWorkspaceWithDisplayName:@"demo"
        operationId:NSUUID.UUID.UUIDString.lowercaseString error:&error];
    XCTAssertNotNil(workspace, @"create workspace: %@", error);
    if (workspace == nil) return;
    DSHAgentRootResolver *resolver = [[DSHAgentRootResolver alloc]
        initWithWorkspaceAccess:workspaces projectAccess:nil];
    NSDictionary *root = [resolver resolveRootForWorkspaceId:workspace[@"workspace_id"]
        projectId:nil bindingRevision:workspace[@"binding_revision"] error:&error];
    XCTAssertNotNil(root, @"resolve workspace: %@", error);
    if (root == nil) return;
    // Query the compiled native registry: the Pods target and this XCTest
    // target need not receive the same preprocessor feature definitions.
    DSHAgentToolRegistry *nativeRegistry = [[DSHAgentToolRegistry alloc] init];
    BOOL guestToolsAvailable = [nativeRegistry nativeDescriptorForToolName:@"start_guest_cgi"
        error:nil] != nil;
    if (guestToolsAvailable) {
      XCTAssertTrue([root[@"capabilities"] containsObject:@"guest_service"]);
    }

    DSHSessionSnapshotStore *sessions = [[DSHSessionSnapshotStore alloc]
        initWithRootURL:[testRoot URLByAppendingPathComponent:@"sessions"]];
    __block NSUInteger writesUntilFault = 0;
    __block NSUInteger injectedFailures = 0;
    DSHAgentNativeWAL *wal = [[DSHAgentNativeWAL alloc]
        initWithRootURL:[testRoot URLByAppendingPathComponent:@"agent"]
        clock:^NSDate * { return NSDate.date; }
        identifierGenerator:^NSString * { return NSUUID.UUID.UUIDString.lowercaseString; }
        faultHook:^BOOL(NSString *stage) {
          if (writesUntilFault > 0 && [stage isEqualToString:@"wal.before_prepare"] &&
              --writesUntilFault == 0) {
            injectedFailures += 1;
            return NO;
          }
          return YES;
        }];
    DSHAgentTranscriptStore *transcripts = [[DSHAgentTranscriptStore alloc] initWithWAL:wal];
    DSHAgentPreparedAttemptStore *prepared = [[DSHAgentPreparedAttemptStore alloc]
        initWithWAL:wal rootResolver:resolver sessionSnapshotStore:sessions transcriptStore:transcripts];
    DSHAgentRoundJournal *rounds = [[DSHAgentRoundJournal alloc] initWithWAL:wal];
    NSURL *fixtureURL = [[NSBundle bundleForClass:self.class]
        URLForResource:@"agent-begin-round-session" withExtension:@"json"];
    XCTAssertNotNil(fixtureURL);
    if (fixtureURL == nil) return;
    NSMutableDictionary *candidate = [NSJSONSerialization JSONObjectWithData:
        [NSData dataWithContentsOfURL:fixtureURL] options:NSJSONReadingMutableContainers error:&error];
    XCTAssertNotNil(candidate);
    if (candidate == nil) return;
    NSMutableDictionary *conversation = candidate[@"conversations"][0];
    NSMutableDictionary *attempt = conversation[@"attempts"][0];
    NSMutableDictionary *journal = [attempt[@"agent"] mutableCopy];
    NSArray *beginEvents = [candidate[@"session_events"] copy];
    NSString *prepareOperation = beginEvents[0][@"event_id"];
    NSString *roundOperation = beginEvents[1][@"event_id"];
    NSString *roundId = journal[@"round_lineage"][@"round_id"];
    NSArray *visible = @[@{ @"role" : @"user", @"content" : @"测试", @"attachments" : @[] }];
    NSString *visibleDigest = DSHAgentHJ(@"visible-history", @{ @"messages" : visible }, nil);
    for (NSMutableDictionary *message in conversation[@"messages"]) message[@"text"] = @"测试";
    for (NSMutableDictionary *message in candidate[@"messages"]) message[@"text"] = @"测试";
    conversation[@"title"] = @"测试";
    conversation[@"project_id"] = NSNull.null;
    conversation[@"project_context"] = NSNull.null;
    conversation[@"runtime_context_id"] = NSNull.null;
    conversation[@"workspace_id"] = workspace[@"workspace_id"];
    conversation[@"workspace_binding"] = @{
      @"schema_version" : @1, @"workspace_id" : workspace[@"workspace_id"],
      @"binding_revision" : workspace[@"binding_revision"], @"project_id" : NSNull.null,
    };
    attempt[@"workspace_id"] = workspace[@"workspace_id"];
    attempt[@"workspace_binding_revision"] = workspace[@"binding_revision"];
    attempt[@"context_disposition"] = @"unbound";
    attempt[@"context_project_id"] = NSNull.null;
    attempt[@"project_context"] = NSNull.null;
    attempt[@"status"] = @"prepared";
    attempt[@"visible_history_sha256"] = NSNull.null;
    attempt[@"active_round"] = NSNull.null;
    attempt[@"journal_revision"] = @0;
    attempt[@"agent"] = NSNull.null;
    candidate[@"session_events"] = @[];

    // Snapshot bridge inputs and outputs are immutable Foundation JSON. Round
    // trip every request as the RN bridge does instead of passing test-owned
    // NSMutableDictionary instances into strict native request validators.
    NSDictionary *(^immutable)(NSDictionary *) = ^NSDictionary *(NSDictionary *value) {
      NSData *bytes = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
      return [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
    };
    __block NSDictionary *snapshot = nil;
    BOOL (^commitCandidate)(void) = ^BOOL {
      NSError *commitError = nil;
      NSString *json = [[NSString alloc] initWithData:
          [NSJSONSerialization dataWithJSONObject:candidate options:0 error:&commitError]
          encoding:NSUTF8StringEncoding];
      NSDictionary *expected = snapshot == nil
          ? @{ @"schema_version" : @1, @"kind" : @"missing" }
          : @{ @"schema_version" : @1, @"kind" : @"present", @"snapshot" : snapshot };
      NSDictionary *result = [sessions casPersistSessionWithRequest:immutable(@{
        @"schema_version" : @1, @"operation_id" : NSUUID.UUID.UUIDString.lowercaseString,
        @"expected" : expected, @"candidate_json" : json,
      }) error:&commitError];
      XCTAssertNil(commitError, @"session checkpoint: %@", commitError);
      XCTAssertEqualObjects(result[@"status"], @"committed");
      snapshot = result[@"snapshot"];
      return snapshot != nil;
    };
    NSDictionary *(^cas)(NSNumber *, NSNumber *) = ^NSDictionary *(NSNumber *generation, NSNumber *revision) {
      return @{ @"schema_version" : @1, @"conversation_id" : conversation[@"id"],
        @"task_id" : attempt[@"turn_id"], @"attempt_id" : attempt[@"attempt_id"],
        @"expected_controller_generation" : generation, @"expected_journal_revision" : revision,
        @"expected_session_generation" : snapshot[@"generation"],
        @"expected_session_sha256" : snapshot[@"session_sha256"] };
    };
    NSDictionary *(^checkpoint)(NSNumber *) = ^NSDictionary *(NSNumber *revision) {
      return @{ @"schema_version" : @1, @"journal_revision" : revision,
        @"session_generation" : snapshot[@"generation"], @"session_sha256" : snapshot[@"session_sha256"] };
    };
    if (!commitCandidate()) return;
    NSDictionary *preparedResult = [prepared prepareAgentAttemptWithRequest:immutable(@{
      @"schema_version" : @2, @"operation_id" : prepareOperation,
      @"controller_cas" : cas(@0, @0), @"committed_checkpoint" : checkpoint(@0),
      @"task_id" : attempt[@"turn_id"], @"conversation_id" : conversation[@"id"],
      @"attempt_id" : attempt[@"attempt_id"], @"workspace_id" : workspace[@"workspace_id"],
      @"project_id" : NSNull.null, @"workspace_binding_revision" : workspace[@"binding_revision"],
      @"transport_schema_version" : @2, @"harness_id" : @"dsh", @"model" : @"deepseek-v4-flash",
      @"thinking_mode" : @"high", @"visible_message_ids" : attempt[@"visible_message_ids"],
      @"visible_history_sha256" : visibleDigest, @"visible_message_count" : @1,
      @"project_context_sha256" : NSNull.null, @"registry_version" : @3,
      @"expected_policy_version" : NSNull.null, @"expected_transcript" : NSNull.null,
    }) error:&error];
    XCTAssertNil(error, @"prepare agent: %@", error);
    XCTAssertEqualObjects(preparedResult[@"status"], @"prepared");
    NSDictionary *projection = preparedResult[@"attempt"];
    if (projection == nil) return;
    if (guestToolsAvailable) {
      XCTAssertTrue([projection[@"root"][@"capabilities"] containsObject:@"guest_service"]);
      NSArray *names = [projection[@"registry"][@"tools"] valueForKey:@"name"];
      XCTAssertTrue([names containsObject:@"start_guest_cgi"]);
      XCTAssertTrue([names containsObject:@"stop_guest_cgi"]);
    }
    journal[@"phase"] = projection[@"phase"];
    journal[@"controller_generation"] = projection[@"controller_generation"];
    journal[@"policy"] = projection[@"policy"];
    journal[@"root"] = projection[@"root"];
    journal[@"tool_registry_version"] = projection[@"registry"][@"registry_version"];
    journal[@"toolset_sha256"] = projection[@"registry"][@"toolset_sha256"];
    journal[@"transcript"] = projection[@"transcript"];
    journal[@"round_lineage"] = NSNull.null;
    attempt[@"agent"] = journal;
    attempt[@"visible_history_sha256"] = visibleDigest;
    attempt[@"journal_revision"] = @1;
    candidate[@"session_events"] = @[beginEvents[0]];
    if (!commitCandidate()) return;

    journal[@"phase"] = @"round_in_flight";
    journal[@"controller_generation"] = @1;
    journal[@"round_lineage"] = @{ @"schema_version" : @2, @"round_id" : roundId,
      @"round_index" : @0, @"launch_attempt" : @1, @"status" : @"active", @"native_row_revision" : NSNull.null };
    attempt[@"status"] = @"sending";
    attempt[@"journal_revision"] = @2;
    attempt[@"active_round"] = @{ @"round_id" : roundId, @"round_index" : @0 };
    candidate[@"session_events"] = beginEvents;
    if (!commitCandidate()) return;
    XCTAssertEqualObjects(snapshot[@"generation"], @3);

    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.protocolClasses = @[DSHProviderURLProtocol.class];
    session = [NSURLSession sessionWithConfiguration:configuration];
    DshProviderTransport *transport = [[DshProviderTransport alloc] initWithSession:session
        uuidGenerator:^NSString * { return NSUUID.UUID.UUIDString.lowercaseString; }
        monotonicClock:^NSTimeInterval { return NSProcessInfo.processInfo.systemUptime; }];
    [DSHProviderURLProtocol setHandler:^(NSURLProtocol *protocol, NSURLRequest *request) {
      NSDictionary *body = [NSJSONSerialization JSONObjectWithData:
          DSHProviderCapturedRequestBody(request) options:0 error:nil];
      XCTAssertEqualObjects(body[@"messages"][0][@"content"], @"测试");
      if (guestToolsAvailable) {
        NSArray *toolNames = [body[@"tools"] valueForKeyPath:@"function.name"];
        XCTAssertTrue([toolNames containsObject:@"start_guest_cgi"]);
        XCTAssertTrue([toolNames containsObject:@"stop_guest_cgi"]);
      }
      NSData *data = [NSJSONSerialization dataWithJSONObject:@{
        @"id" : @"first-send-response", @"model" : @"deepseek-v4-flash",
        @"choices" : @[@{ @"finish_reason" : @"stop", @"message" : @{
          @"role" : @"assistant", @"content" : @"测试成功", @"reasoning_content" : @"" } }],
      } options:0 error:nil];
      NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:request.URL
          statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{ @"Content-Type" : @"application/json" }];
      [protocol.client URLProtocol:protocol didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
      [protocol.client URLProtocol:protocol didLoadData:data];
      [protocol.client URLProtocolDidFinishLoading:protocol];
    }];
    DSHAgentProviderRoundService *service = [[DSHAgentProviderRoundService alloc]
        initWithWAL:wal preparedStore:prepared transcripts:transcripts rounds:rounds transport:transport
        credentialProvider:^NSString *(__unused NSString *harness, NSUInteger *generation) {
          if (generation != nullptr) *generation = 7;
          return @"test-credential";
        } visibleHistoryProvider:^NSArray *(__unused NSDictionary *authority, __unused NSError **historyError) {
          return visible;
        }];
    NSDictionary *request = immutable(@{
      @"schema_version" : @2, @"operation_id" : roundOperation,
      @"controller_cas" : cas(@1, @2), @"committed_checkpoint" : checkpoint(@2),
      @"task_id" : attempt[@"turn_id"], @"conversation_id" : conversation[@"id"],
      @"attempt_id" : attempt[@"attempt_id"], @"round_id" : roundId, @"round_index" : @0,
      @"launch_attempt" : @1, @"expected_round_revision" : @0,
      @"transport_schema_version" : @2, @"harness_id" : @"dsh", @"model" : @"deepseek-v4-flash",
      @"thinking_mode" : @"high", @"visible_history_sha256" : visibleDigest, @"visible_message_count" : @1,
      @"project_context_sha256" : NSNull.null, @"transcript" : projection[@"transcript"],
      @"root" : root, @"registry_version" : projection[@"registry"][@"registry_version"],
      @"toolset_sha256" : projection[@"registry"][@"toolset_sha256"],
    });
    // After preparation the first WAL write records the operation, and the
    // second inserts the round. Fail only that round write, before any rename.
    writesUntilFault = failedWrite;
    NSDictionary *result = [service completeAgentRoundV2WithRequest:request error:&error];
    if (failedWrite > 0) {
      XCTAssertEqual(injectedFailures, 1U);
      XCTAssertNil(result);
      XCTAssertEqual(error.code, DSHAgentNativeStoreErrorPersistence);
      XCTAssertEqual([DSHProviderURLProtocol requestCount], 0U,
          @"an uncommitted round cannot dispatch the provider");
      error = nil;
      NSDictionary *durable = [wal snapshotWithError:&error];
      XCTAssertNotNil(durable, @"previous WAL remains readable: %@", error);
      XCTAssertNil(error);
      XCTAssertEqual([(NSArray *)durable[@"rounds"] count], 0U);
      XCTAssertEqual([(NSArray *)durable[@"transcripts"][0][@"messages"] count], 0U);
      return;
    }
    XCTAssertNil(error, @"complete first round: %@", error);
    XCTAssertEqualObjects(result[@"status"], @"completed");
    if (![result[@"status"] isEqualToString:@"completed"]) return;
    XCTAssertEqualObjects(result[@"outcome"][@"text"], @"测试成功");
    XCTAssertEqual([DSHProviderURLProtocol requestCount], 1U);
    NSDictionary *stored = [wal snapshotWithError:&error];
    XCTAssertNil(error);
    XCTAssertEqualObjects([(NSArray *)stored[@"rounds"] firstObject][@"state"], @"completed");
    XCTAssertEqual([(NSArray *)stored[@"transcripts"][0][@"messages"] count], 1U);
    XCTAssertEqualObjects([service completeAgentRoundV2WithRequest:request error:&error], result);
    XCTAssertEqual([DSHProviderURLProtocol requestCount], 1U, @"replay must not send a second request");
  } @finally {
    [session invalidateAndCancel];
    [DSHProviderURLProtocol reset];
    [NSFileManager.defaultManager removeItemAtURL:testRoot error:nil];
  }
}

// Both insert and dispatch produce an in-memory result before the enclosing
// WAL rename. A failed write must never publish that result as durable proof.
- (void)testRoundV3RejectsCreateAndDispatchWhenRealWALWriteFails {
  NSURL *walRoot = [NSURL fileURLWithPath:[NSTemporaryDirectory()
      stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
  __block BOOL failNextWrite = NO;
  __block NSUInteger injectedFailures = 0;
  DSHAgentNativeWAL *wal = [[DSHAgentNativeWAL alloc]
      initWithRootURL:walRoot clock:^NSDate * { return NSDate.date; }
      identifierGenerator:^NSString * { return NSUUID.UUID.UUIDString.lowercaseString; }
      faultHook:^BOOL(NSString *stage) {
        if (failNextWrite && [stage isEqualToString:@"wal.before_prepare"]) {
          failNextWrite = NO;
          injectedFailures += 1;
          return NO;
        }
        return YES;
      }];
  @try {
    NSError *error = nil;
    NSDictionary *root = DSHProviderSmokeRoot();
    DSHAgentTranscriptStore *transcripts = [[DSHAgentTranscriptStore alloc] initWithWAL:wal];
    NSDictionary *transcript = [transcripts createAgentTranscriptWithRequest:@{
      @"schema_version" : @1, @"attempt_id" : DSHProviderSmokeAttempt, @"root" : root,
    } error:&error];
    XCTAssertNotNil(transcript, @"%@", error);
    if (transcript == nil) return;
    NSString *nativeTaskId = NSUUID.UUID.UUIDString.lowercaseString;
    XCTAssertTrue([wal registerNativeTaskId:nativeTaskId error:&error]);
    NSDictionary *locator = @{ @"schema_version" : @1, @"task_id" : DSHProviderSmokeTask,
      @"attempt_id" : DSHProviderSmokeAttempt, @"round_id" : DSHProviderSmokeRound, @"round_index" : @0 };
    NSDictionary *owner = @{ @"schema_version" : @1, @"task_id" : DSHProviderSmokeTask,
      @"launch_id" : wal.launchId, @"native_task_id" : nativeTaskId, @"owner_generation" : @1,
      @"heartbeat_at" : wal.currentTimestamp };
    NSDictionary *row = @{ @"schema_version" : @3, @"locator" : locator, @"row_revision" : @1,
      @"root_fingerprint_sha256" : root[@"root_fingerprint_sha256"], @"binding_revision" : @7,
      @"request_sha256" : DSHProviderSmokeDigest, @"transcript_before" : transcript,
      @"launch_attempt" : @1, @"state" : @"in_flight", @"owner" : owner,
      @"failure_code" : NSNull.null, @"completion_receipt" : NSNull.null,
      @"transcript_after" : NSNull.null, @"calls" : @[], @"batch_class" : NSNull.null,
      @"executable_call_count" : @0, @"denied_call_count" : @0, @"terminal_kind" : NSNull.null,
      @"created_at" : wal.currentTimestamp, @"updated_at" : wal.currentTimestamp };
    NSDictionary *insert = @{ @"schema_version" : @1, @"locator" : locator, @"expected_absent" : @YES,
      @"expected_transcript_generation" : transcript[@"generation"],
      @"expected_transcript_sha256" : transcript[@"transcript_sha256"],
      @"expected_root_fingerprint_sha256" : root[@"root_fingerprint_sha256"],
      @"expected_binding_revision" : @7 };
    DSHAgentRoundJournal *rounds = [[DSHAgentRoundJournal alloc] initWithWAL:wal];
    NSDictionary *beforeInsert = [wal snapshotWithError:&error];
    XCTAssertNotNil(beforeInsert);
    failNextWrite = YES;
    NSDictionary *failedInsert = [rounds createAgentRoundV3WithInsertCAS:insert exactRoundStart:row error:&error];
    XCTAssertNil(failedInsert, @"an uncommitted round must not be reported as inserted");
    XCTAssertEqual(error.code, DSHAgentNativeStoreErrorPersistence);
    XCTAssertEqual(injectedFailures, 1U);
    error = nil;
    XCTAssertEqualObjects([wal snapshotWithError:&error], beforeInsert);
    XCTAssertNil(error, @"previous WAL must remain readable");
    NSDictionary *inserted = [rounds createAgentRoundV3WithInsertCAS:insert exactRoundStart:row error:&error];
    XCTAssertNil(error);
    XCTAssertEqualObjects(inserted[@"status"], @"inserted");
    if (inserted == nil) return;

    NSDictionary *dispatchCAS = DSHProviderRoundCASForRow(inserted[@"row"]);
    NSDictionary *beforeDispatch = [wal snapshotWithError:&error];
    failNextWrite = YES;
    NSDictionary *failedDispatch = [rounds markAgentRoundV3DispatchedWithCAS:dispatchCAS error:&error];
    XCTAssertNil(failedDispatch, @"an uncommitted dispatch must not permit HTTP dispatch");
    XCTAssertEqual(error.code, DSHAgentNativeStoreErrorPersistence);
    XCTAssertEqual(injectedFailures, 2U);
    error = nil;
    XCTAssertEqualObjects([wal snapshotWithError:&error], beforeDispatch);
    XCTAssertNil(error);
    XCTAssertEqualObjects([wal dispatchStateForKind:@"round" locator:locator error:&error], @"not_dispatched");
    NSDictionary *dispatched = [rounds markAgentRoundV3DispatchedWithCAS:dispatchCAS error:&error];
    XCTAssertNil(error);
    XCTAssertNotNil(dispatched);
    XCTAssertEqualObjects([wal dispatchStateForKind:@"round" locator:locator error:&error], @"dispatched");
    XCTAssertTrue([wal unregisterNativeTaskId:nativeTaskId error:&error]);
  } @finally {
    [NSFileManager.defaultManager removeItemAtURL:walRoot error:nil];
  }
}
@end
