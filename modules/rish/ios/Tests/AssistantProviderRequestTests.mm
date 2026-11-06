#import "DSHTestProviderModelsFixture.h"
#import <XCTest/XCTest.h>
#import "AgentProviderRoundService.h"
#import "AgentProviderRoundServiceInternals.h"
#import "AssistantTaskExecutor.h"
#import "DshProviderTransport.h"
#import "DSHWorkspaceCanonical.h"

// Existing Foundation fixtures provide native root routing and the local HTTP
// protocol; preparation, WAL, journal, transport and reply parsing stay real.
@interface DSHPreparedTestRootResolver : DSHAgentRootResolver
- (instancetype)initWithRoot:(NSDictionary *)root;
@end
@interface DSHPreparedTestSessionStore : DSHSessionSnapshotStore
- (instancetype)initWithLoadResult:(NSDictionary *)load;
@end
@interface DSHProviderURLProtocol : NSURLProtocol
+ (void)setHandler:(void (^)(NSURLProtocol *, NSURLRequest *))handler;
+ (void)reset;
+ (NSUInteger)requestCount;
@end
@interface DSHProviderURLSessionDelegate : NSObject <NSURLSessionTaskDelegate>
@property(nonatomic, weak) DSHCompletionProviderTransport *transport;
@end

@interface AssistantProviderStore : DSHAssistantTaskExecutor
@property(nonatomic, strong) NSURL *fixtureDirectory;
@end
@implementation AssistantProviderStore
- (NSURL *)privateDirectory { return self.fixtureDirectory; }
@end

/// Capture the real transport inputs, then invoke the unchanged HTTP path.
@interface AssistantProviderCapture : DshProviderTransport
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *captures;
@end
@implementation AssistantProviderCapture
- (NSURLSessionDataTask *)startRequestWithSchemaVersion:(NSInteger)schemaVersion
    roundId:(NSString *)roundId generation:(NSUInteger)generation
    credentialGeneration:(NSUInteger)credentialGeneration providerRequestId:(NSString *)providerRequestId
    credential:(NSString *)credential requestedModel:(NSString *)requestedModel thinkingMode:(NSString *)thinkingMode
    credentialGenerationIsCurrent:(DSHCompletionProviderTransportCredentialGenerationIsCurrentBlock)generationCheck
    startedAt:(NSTimeInterval)startedAt bodyData:(NSData *)bodyData visibleHistory:(NSArray *)visibleHistory
    modelInput:(NSArray *)modelInput bindTask:(DSHCompletionProviderTransportBindTaskBlock)bindTask
    claimRound:(DSHCompletionProviderTransportClaimRoundBlock)claimRound
    markRedirected:(DSHCompletionProviderTransportMarkRedirectedBlock)markRedirected
    redirectDecision:(DSHCompletionProviderTransportRedirectDecisionBlock)redirectDecision
    completion:(DSHCompletionProviderTransportCompletionBlock)completion {
  if (self.captures == nil) self.captures = [NSMutableArray array];
  [self.captures addObject:@{@"body":bodyData, @"model_input":[modelInput copy]}];
  return [super startRequestWithSchemaVersion:schemaVersion roundId:roundId generation:generation
      credentialGeneration:credentialGeneration providerRequestId:providerRequestId credential:credential
      requestedModel:requestedModel thinkingMode:thinkingMode credentialGenerationIsCurrent:generationCheck
      startedAt:startedAt bodyData:bodyData visibleHistory:visibleHistory modelInput:modelInput
      bindTask:bindTask claimRound:claimRound markRedirected:markRedirected
      redirectDecision:redirectDecision completion:completion];
}
@end

static NSData *AssistantProviderWireBody(NSURLRequest *request) {
  if (request.HTTPBody != nil) return request.HTTPBody;
  NSInputStream *stream = request.HTTPBodyStream;
  if (stream == nil) return nil;
  NSMutableData *bytes = [NSMutableData data];
  uint8_t buffer[4096];
  [stream open];
  while (YES) {
    NSInteger length = [stream read:buffer maxLength:sizeof(buffer)];
    if (length < 0) { [stream close]; return nil; }
    if (length == 0) break;
    [bytes appendBytes:buffer length:(NSUInteger)length];
  }
  [stream close];
  return bytes;
}

@interface AssistantProviderRequestTests : XCTestCase
@property(nonatomic, strong) NSURL *directory;
@property(nonatomic, strong) NSURLSession *session;
@end

@implementation AssistantProviderRequestTests
- (void)setUp {
  [super setUp];
  XCTAssertTrue(DSHInstallTestProviderModels(self, @{@"dsh":@[@"deepseek-v4-flash"]},
      [NSSet setWithObject:@"deepseek-v4-flash"]));
  [DSHProviderURLProtocol reset];
  self.directory = [[NSURL fileURLWithPath:[NSTemporaryDirectory()
      stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES] URLByResolvingSymlinksInPath];
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:self.directory
      withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil]);
}
- (void)tearDown {
  [self.session invalidateAndCancel];
  [DSHProviderURLProtocol reset];
  [NSFileManager.defaultManager removeItemAtURL:self.directory error:nil];
  [super tearDown];
}

- (void)assertAssistantToolsInBody:(NSDictionary *)body {
  NSArray *names = @[@"list_assistant_tasks", @"create_assistant_task", @"update_assistant_task",
      @"search_assistant_memory", @"remember_assistant_memory", @"forget_assistant_memory"];
  NSMutableDictionary *functions = [NSMutableDictionary dictionary];
  for (NSDictionary *tool in body[@"tools"]) {
    XCTAssertEqualObjects(tool[@"type"], @"function");
    functions[tool[@"function"][@"name"]] = tool[@"function"];
  }
  for (NSString *name in names) {
    NSDictionary *tool = functions[name], *schema = tool[@"parameters"];
    XCTAssertNotNil(tool, @"missing %@", name);
    XCTAssertGreaterThan([tool[@"description"] length], 12U);
    XCTAssertFalse([tool[@"description"] hasPrefix:@"agent."]);
    XCTAssertEqualObjects(schema[@"type"], @"object");
    XCTAssertEqualObjects(schema[@"additionalProperties"], @NO);
    XCTAssertNil(schema[@"properties"][@"model_id"]);
    XCTAssertNil(schema[@"properties"][@"workspace_id"]);
    XCTAssertNil(schema[@"properties"][@"path"]);
    XCTAssertNil(schema[@"properties"][@"credential"]);
  }
  XCTAssertEqualObjects(functions[@"create_assistant_task"][@"parameters"][@"required"], (@[@"title", @"instructions"]));
  XCTAssertEqualObjects(functions[@"update_assistant_task"][@"parameters"][@"required"], @[@"task_id"]);
  XCTAssertEqualObjects(functions[@"forget_assistant_memory"][@"parameters"][@"required"], @[@"memory_id"]);
  XCTAssertNotNil(functions[@"search_assistant_memory"][@"parameters"][@"properties"][@"query"]);
  XCTAssertNotNil(functions[@"remember_assistant_memory"][@"parameters"][@"properties"][@"content"]);
  XCTAssertNil(functions[@"write_file"]); // Private metadata writes do not enable workspace writes.
}

- (void)testReadonlyV5RequestFreezesSoulAndHashesRealBodyAcrossRetry {
  NSString *conversationID = @"22222222-2222-4222-8222-222222222222";
  NSString *attemptID = @"44444444-4444-4444-8444-444444444444";
  NSString *messageID = @"88888888-8888-4888-8888-888888888888";
  NSString *workspaceID = @"11111111-1111-4111-8111-111111111111";
  NSString *projectID = @"99999999-9999-4999-8999-999999999999";
  NSString *contextSHA = [@"c" stringByPaddingToLength:64 withString:@"c" startingAtIndex:0];
  NSString *sessionSHA = [@"d" stringByPaddingToLength:64 withString:@"d" startingAtIndex:0];
  NSString *fingerprint = [@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0];
  NSString *oldSoul = @"FROZEN_SOUL: propose concrete next actions.";
  NSString *newSoul = @"LIVE_SOUL: this changed after preparation.";
  NSString *projectText = @"PROJECT_CONTEXT_MARKER";
  NSArray *history = @[@{@"role":@"user", @"content":@"Remember to check this project", @"attachments":@[]}];
  NSString *visibleSHA = DSHAgentHJ(@"visible-history", @{@"messages":history}, nil);
  NSDictionary *root = @{@"schema_version":@1, @"kind":@"project", @"workspace_id":workspaceID,
      @"workspace_binding_revision":@7, @"project_id":projectID, @"root_fingerprint_sha256":fingerprint,
      @"capabilities":@[@"file_read"]};
  NSDictionary *context = @{@"schema_version":@1,
      @"runtime_context_id":@"abababab-abab-4bab-8bab-abababababab", @"project_id":projectID,
      @"snapshot_id":@"bcbcbcbc-bcbc-4cbc-8cbc-bcbcbcbcbcbc", @"snapshot_sha256":contextSHA,
      @"source_fingerprint":fingerprint, @"context_bytes":@([projectText lengthOfBytesUsingEncoding:NSUTF8StringEncoding]),
      @"consent_receipt_id":@"cdcdcdcd-cdcd-4dcd-8dcd-cdcdcdcdcdcd", @"provider":@"deepseek",
      @"policy":@"chat-read-v1", @"policy_version":@"chat-read-v1.0.0"};
  NSDictionary *attempt = @{@"attempt_id":attemptID, @"turn_id":attemptID,
      @"model_id":@"deepseek-v4-flash", @"thinking_mode":@"off", @"workspace_id":workspaceID,
      @"workspace_binding_revision":@7, @"context_project_id":projectID,
      @"context_disposition":@"verified", @"project_context":context, @"visible_message_ids":@[messageID],
      @"visible_history_sha256":visibleSHA, @"journal_revision":@0, @"agent":NSNull.null};
  NSDictionary *conversation = @{@"id":conversationID, @"workspace_id":workspaceID, @"project_id":projectID,
      @"messages":@[@{@"id":messageID, @"role":@"user", @"text":history[0][@"content"], @"attachments":@[]}],
      @"attempts":@[attempt]};
  NSDictionary *sessionObject = @{@"schema_version":@9, @"conversations":@[conversation]};
  NSDictionary *load = @{@"schema_version":@1, @"status":@"present",
      @"snapshot":@{@"schema_version":@1, @"generation":@3, @"session_sha256":sessionSHA},
      @"session_json":[[NSString alloc] initWithData:DSHAgentCanonicalJSON(sessionObject, nil) encoding:NSUTF8StringEncoding]};
  DSHPreparedTestSessionStore *sessions = [[DSHPreparedTestSessionStore alloc] initWithLoadResult:load];
  DSHPreparedTestRootResolver *resolver = [[DSHPreparedTestRootResolver alloc] initWithRoot:root];
  DSHAgentNativeWAL *wal = [[DSHAgentNativeWAL alloc]
      initWithRootURL:[self.directory URLByAppendingPathComponent:@"wal" isDirectory:YES]
      clock:^NSDate *{ return [NSDate dateWithTimeIntervalSince1970:1700000000]; }
      identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; } faultHook:nil];
  DSHAgentTranscriptStore *transcripts = [[DSHAgentTranscriptStore alloc] initWithWAL:wal];
  DSHAgentPreparedAttemptStore *prepared = [[DSHAgentPreparedAttemptStore alloc]
      initWithWAL:wal rootResolver:resolver sessionSnapshotStore:sessions transcriptStore:transcripts];
  NSURL *privateStore = [self.directory URLByAppendingPathComponent:@"assistant" isDirectory:YES];
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:privateStore withIntermediateDirectories:YES
      attributes:@{NSFilePosixPermissions:@0700} error:nil]);
  NSDictionary *profile = @{@"name":@"Frozen Assistant", @"notes":@"Prefer short replies", @"soul":oldSoul};
  NSMutableDictionary *storeState = [@{@"schema_version":@1, @"revision":@0, @"profile":profile,
      @"conversation_id":conversationID, @"tasks":@[], @"clock_high_water_ms":@0} mutableCopy];
  NSURL *storeFile = [privateStore URLByAppendingPathComponent:@"assistant-v1.json"];
  XCTAssertTrue([DSHAgentCanonicalJSON(storeState, nil) writeToURL:storeFile atomically:YES]);
  AssistantProviderStore *assistant = [[AssistantProviderStore alloc] initWithRootResolver:resolver];
  assistant.fixtureDirectory = privateStore;
  [prepared setValue:assistant forKey:@"assistantTaskExecutor"];
  NSDictionary *checkpoint = @{@"schema_version":@1, @"journal_revision":@0,
      @"session_generation":@3, @"session_sha256":sessionSHA};
  NSDictionary *cas = @{@"schema_version":@1, @"conversation_id":conversationID,
      @"task_id":attemptID, @"attempt_id":attemptID, @"expected_controller_generation":@2,
      @"expected_journal_revision":@0, @"expected_session_generation":@3, @"expected_session_sha256":sessionSHA};
  NSDictionary *prepareRequest = @{@"schema_version":@2,
      @"operation_id":@"77777777-7777-4777-8777-777777777777", @"controller_cas":cas,
      @"committed_checkpoint":checkpoint, @"task_id":attemptID, @"conversation_id":conversationID,
      @"attempt_id":attemptID, @"workspace_id":workspaceID, @"project_id":projectID,
      @"workspace_binding_revision":@7, @"transport_schema_version":@3, @"model":@"deepseek-v4-flash",
      @"thinking_mode":@"off", @"visible_message_ids":@[messageID], @"visible_history_sha256":visibleSHA,
      @"visible_message_count":@1, @"project_context_sha256":contextSHA, @"registry_version":@5,
      @"expected_policy_version":NSNull.null, @"expected_transcript":NSNull.null};
  NSError *error = nil;
  NSDictionary *preparedResult = [prepared prepareAgentAttemptWithRequest:prepareRequest error:&error];
  XCTAssertNil(error); XCTAssertEqualObjects(preparedResult[@"status"], @"prepared");
  if (![preparedResult[@"status"] isEqual:@"prepared"]) return;
  NSDictionary *authority = [prepared nativeAuthorityForTaskId:attemptID attemptId:attemptID error:&error];
  XCTAssertEqualObjects(authority[@"assistant_context"][@"soul"], oldSoul);

  NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
  configuration.protocolClasses = @[DSHProviderURLProtocol.class];
  DSHProviderURLSessionDelegate *delegate = [DSHProviderURLSessionDelegate new];
  self.session = [NSURLSession sessionWithConfiguration:configuration delegate:delegate delegateQueue:nil];
  AssistantProviderCapture *transport = [[AssistantProviderCapture alloc] initWithSession:self.session
      uuidGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }
      monotonicClock:^NSTimeInterval { return 3.0; }];
  delegate.transport = transport;
  __block NSUInteger sends = 0;
  NSMutableArray<NSData *> *wireBodies = [NSMutableArray array];
  [DSHProviderURLProtocol setHandler:^(NSURLProtocol *protocol, NSURLRequest *request) {
    sends += 1;
    NSData *wireBody = AssistantProviderWireBody(request);
    XCTAssertNotNil(wireBody);
    if (wireBody) [wireBodies addObject:wireBody];
    NSDictionary *payload = sends == 1 ? @{@"error":@{@"message":@"Fixture rate limit"}}
        : @{@"id":@"assistant-tools-reply", @"model":@"deepseek-v4-flash",
            @"choices":@[@{@"finish_reason":@"tool_calls", @"message":@{@"role":@"assistant",
              @"content":NSNull.null, @"tool_calls":@[@{@"id":@"create-follow-up", @"type":@"function",
                @"function":@{@"name":@"create_assistant_task",
                  @"arguments":@"{\"title\":\"Follow up\",\"instructions\":\"Check the project\"}"}}]}}]};
    NSData *responseBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:request.URL
        statusCode:sends == 1 ? 429 : 200 HTTPVersion:@"HTTP/1.1"
        headerFields:@{@"Content-Type":@"application/json"}];
    [protocol.client URLProtocol:protocol didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [protocol.client URLProtocol:protocol didLoadData:responseBody];
    [protocol.client URLProtocolDidFinishLoading:protocol];
  }];
  DSHAgentRoundJournal *rounds = [[DSHAgentRoundJournal alloc] initWithWAL:wal];
  DSHAgentProviderRoundService *service = [[DSHAgentProviderRoundService alloc] initWithWAL:wal
      preparedStore:prepared transcripts:transcripts rounds:rounds transport:transport
      credentialProvider:^NSString *(NSString *harness, NSUInteger *generation) {
        (void)harness; if (generation) *generation = 7; return @"isolated-fixture-credential";
      } visibleHistoryProvider:^NSArray *(NSDictionary *nativeAuthority, NSError **inner) {
        (void)nativeAuthority; (void)inner; return history;
      } contextReceiptProvider:^NSDictionary *(NSDictionary *nativeAuthority, NSError **inner) {
        (void)nativeAuthority; (void)inner;
        return @{@"project_context_sha256":contextSHA,
          @"receipt":@{@"schema_version":@1, @"snapshot_id":context[@"snapshot_id"],
            @"snapshot_sha256":contextSHA, @"source_fingerprint":fingerprint,
            @"context_bytes":context[@"context_bytes"], @"verified_at":@"2023-11-14T22:13:20.000Z"},
          @"messages":@[@{@"role":@"system", @"content":projectText, @"attachments":@[]}]};
      }];
  NSMutableDictionary *request = [@{@"schema_version":@2,
      @"operation_id":@"55555555-5555-4555-8555-555555555555", @"controller_cas":cas,
      @"committed_checkpoint":checkpoint, @"task_id":attemptID, @"conversation_id":conversationID,
      @"attempt_id":attemptID, @"round_id":@"33333333-3333-4333-8333-333333333333",
      @"round_index":@0, @"launch_attempt":@1, @"expected_round_revision":@0,
      @"transport_schema_version":@3, @"model":@"deepseek-v4-flash", @"thinking_mode":@"off",
      @"visible_history_sha256":visibleSHA, @"visible_message_count":@1,
      @"project_context_sha256":contextSHA, @"transcript":authority[@"transcript"], @"root":root,
      @"registry_version":@5, @"toolset_sha256":authority[@"registry"][@"toolset_sha256"]} mutableCopy];
  NSDictionary *failed = [service completeAgentRoundV2WithRequest:request error:&error];
  XCTAssertNil(error); XCTAssertEqualObjects(failed[@"status"], @"failed_retryable", @"%@", failed);
  NSDictionary *failedRow = [wal snapshotWithError:nil][@"rounds"][0];
  XCTAssertEqualObjects(failedRow[@"state"], @"failed_retryable");
  if (![failedRow[@"state"] isEqual:@"failed_retryable"]) return;

  // Simulate an independent manual profile edit in this isolated store. A
  // fresh native authorization sees it, while this prepared attempt stays old.
  storeState[@"revision"] = @1;
  storeState[@"profile"] = @{@"name":@"Live Assistant", @"notes":@"New notes", @"soul":newSoul};
  XCTAssertTrue([DSHAgentCanonicalJSON(storeState, nil) writeToURL:storeFile atomically:YES]);
  XCTAssertEqualObjects([assistant assistantContextForConversation:conversation registryVersion:@5 error:&error][@"soul"], newSoul);
  request[@"operation_id"] = @"66666666-6666-4666-8666-666666666666";
  request[@"expected_round_revision"] = failedRow[@"row_revision"];
  request[@"launch_attempt"] = @([failedRow[@"launch_attempt"] unsignedIntegerValue] + 1);
  NSDictionary *result = [service retryFailedAgentRoundV2WithRequest:request error:&error];
  XCTAssertNil(error); XCTAssertEqualObjects(result[@"status"], @"completed", @"%@", result);
  XCTAssertEqualObjects(result[@"outcome"][@"kind"], @"tool_batch");
  XCTAssertEqualObjects(result[@"outcome"][@"calls"][0][@"name"], @"create_assistant_task");
  XCTAssertEqualObjects(result[@"outcome"][@"calls"][0][@"access"], @"conversation_confirm");
  XCTAssertEqual(transport.captures.count, 2U); XCTAssertEqual(wireBodies.count, 2U);
  if (transport.captures.count != 2 || wireBodies.count != 2) return;
  for (NSUInteger index = 0; index < 2; index += 1) {
    NSDictionary *capture = transport.captures[index];
    NSDictionary *body = [NSJSONSerialization JSONObjectWithData:wireBodies[index] options:0 error:nil];
    XCTAssertEqualObjects(capture[@"body"], wireBodies[index]);
    [self assertAssistantToolsInBody:body];
    NSArray *input = capture[@"model_input"];
    XCTAssertEqualObjects(input[0][@"role"], @"system");
    XCTAssertTrue([input[0][@"content"] containsString:oldSoul]);
    XCTAssertTrue([input[0][@"content"] containsString:@"Frozen Assistant"]);
    XCTAssertFalse([input[0][@"content"] containsString:newSoul]);
    XCTAssertEqualObjects(input[1][@"content"], projectText);
    XCTAssertEqualObjects(input[2][@"content"], history[0][@"content"]);
    XCTAssertEqualObjects(body[@"messages"][0][@"content"], input[0][@"content"]);
  }
  NSDictionary *receipt = result[@"outcome"][@"completion_receipt"];
  NSDictionary *last = transport.captures.lastObject;
  XCTAssertEqualObjects(receipt[@"model_input_sha256"], DSHProviderJSONSHA256(last[@"model_input"], nil));
  XCTAssertEqualObjects(receipt[@"request_body_sha256"], DSHWorkspaceSHA256Hex(wireBodies.lastObject));
  NSMutableArray *withoutSoul = [last[@"model_input"] mutableCopy]; [withoutSoul removeObjectAtIndex:0];
  XCTAssertNotEqualObjects(receipt[@"model_input_sha256"], DSHProviderJSONSHA256(withoutSoul, nil));
  XCTAssertEqualObjects([prepared nativeAuthorityForTaskId:attemptID attemptId:attemptID error:nil][@"assistant_context"], authority[@"assistant_context"]);
  NSDictionary *replay = [service retryFailedAgentRoundV2WithRequest:request error:&error];
  XCTAssertNil(error); XCTAssertEqualObjects(replay, result);
  XCTAssertEqual([DSHProviderURLProtocol requestCount], 2U);
}
@end
