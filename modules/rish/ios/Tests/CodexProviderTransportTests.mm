#import <XCTest/XCTest.h>

#import "../../../../modules/rish/ios/Sources/CodexProviderTransport.h"
#import "../../../../modules/rish/ios/Sources/RishHarnessCatalog.h"

@interface CodexTransportURLProtocol : NSURLProtocol
+ (void)setHandler:(void (^)(NSURLProtocol *, NSURLRequest *))handler;
+ (void)reset;
@end

@implementation CodexTransportURLProtocol

static void (^CodexTransportHandler)(NSURLProtocol *, NSURLRequest *);

+ (void)setHandler:(void (^)(NSURLProtocol *, NSURLRequest *))handler {
  @synchronized (self) { CodexTransportHandler = [handler copy]; }
}

+ (void)reset {
  @synchronized (self) { CodexTransportHandler = nil; }
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
  NSString *scheme = request.URL.scheme.lowercaseString;
  return [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
  return request;
}

- (void)startLoading {
  void (^handler)(NSURLProtocol *, NSURLRequest *) = nil;
  @synchronized (self.class) { handler = [CodexTransportHandler copy]; }
  if (handler != nil) {
    handler(self, self.request);
    return;
  }
  [self.client URLProtocol:self didFailWithError:
      [NSError errorWithDomain:@"CodexTransportTests" code:1 userInfo:nil]];
}

- (void)stopLoading {}

@end

/// Forwards the session's data callbacks to the transport so streamed
/// rounds settle the same way they do behind LocalRuntimeModule.
@interface CodexStreamingSessionDelegate : NSObject <NSURLSessionDataDelegate>
@property(nonatomic, weak) DSHCompletionProviderTransport *transport;
@end
@implementation CodexStreamingSessionDelegate
- (void)URLSession:(__unused NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
  if ([self.transport handlesTask:dataTask]) [self.transport streamingTask:dataTask didReceiveResponse:response];
  completionHandler(NSURLSessionResponseAllow);
}
- (void)URLSession:(__unused NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
  if ([self.transport handlesTask:dataTask]) [self.transport streamingTask:dataTask didReceiveData:data];
}
- (void)URLSession:(__unused NSURLSession *)session task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
  if ([self.transport handlesTask:task]) [self.transport streamingTask:task didCompleteWithError:error];
}
@end

@interface CodexProviderTransportTests : XCTestCase
@property(nonatomic, strong) CodexStreamingSessionDelegate *streamingDelegate;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) CodexProviderTransport *transport;
@end

@implementation CodexProviderTransportTests

- (void)setUp {
  [super setUp];
  [CodexTransportURLProtocol reset];
  NSURLSessionConfiguration *configuration =
      NSURLSessionConfiguration.ephemeralSessionConfiguration;
  configuration.protocolClasses = @[CodexTransportURLProtocol.class];
  self.streamingDelegate = [[CodexStreamingSessionDelegate alloc] init];
  self.session = [NSURLSession sessionWithConfiguration:configuration
                                                delegate:self.streamingDelegate
                                           delegateQueue:nil];
  self.transport = [[CodexProviderTransport alloc]
      initWithSession:self.session uuidGenerator:nil monotonicClock:nil];
  self.streamingDelegate.transport = self.transport;
}

- (void)tearDown {
  [self.session invalidateAndCancel];
  self.transport = nil;
  self.session = nil;
  [CodexTransportURLProtocol reset];
  [super tearDown];
}

- (NSData *)jsonData:(id)value {
  return [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
}

- (NSDictionary *)bodyForModel:(NSString *)model
                       thinking:(NSString *)mode
                       messages:(NSArray *)messages
                          tools:(NSArray *)tools {
  NSError *error = nil;
  NSDictionary *body = [self.transport providerRequestBodyForModel:model
      thinkingMode:mode messages:messages tools:tools streaming:NO error:&error];
  XCTAssertNotNil(body, @"%@ %@: %@", model, mode, error);
  return body;
}

- (void)testHeadersAndCatalog {
  XCTAssertEqualObjects([self.transport providerBaseURL].absoluteString,
                        @"https://api.openai.com/v1/responses");
  NSDictionary *headers = [self.transport providerHeadersWithCredential:@"sk-test"];
  XCTAssertEqualObjects(headers[@"Authorization"], @"Bearer sk-test");
  XCTAssertNil(headers[@"x-api-key"]);
  XCTAssertEqualObjects([self.transport providerHarnessId], @"codex");
  XCTAssertTrue([self.transport providerSupportsModel:@"gpt-5.6-mini"]);
  XCTAssertFalse([self.transport providerSupportsModel:@"claude-sonnet-5"]);
}

- (void)testBuildsResponsesBodyWithReasoningInstructionsAndNonStrictTools {
  NSArray *messages = @[
    @{ @"role": @"system", @"content": @"be terse" },
    @{ @"role": @"system", @"content": @"RISH-PROJECT-CONTEXT policy" },
    @{ @"role": @"user", @"content": @"hello" },
  ];
  NSArray *tools = @[@{ @"type": @"function", @"function": @{
    @"name": @"write_file", @"description": @"Writes a file",
    @"parameters": @{ @"type": @"object", @"properties": @{} } } }];
  NSDictionary *high = [self bodyForModel:@"gpt-5.6" thinking:@"high"
                                 messages:messages tools:tools];
  XCTAssertEqualObjects(high[@"model"], @"gpt-5.6");
  XCTAssertEqualObjects(high[@"stream"], @NO);
  XCTAssertEqualObjects(high[@"store"], @NO);
  XCTAssertEqualObjects(high[@"max_output_tokens"], @16384);
  XCTAssertEqualObjects(high[@"instructions"], @"be terse\n\nRISH-PROJECT-CONTEXT policy");
  XCTAssertEqualObjects(high[@"reasoning"], (@{ @"effort": @"high", @"summary": @"auto" }));
  NSDictionary *tool = [high[@"tools"] firstObject];
  XCTAssertEqualObjects(tool[@"type"], @"function");
  XCTAssertEqualObjects(tool[@"name"], @"write_file");
  XCTAssertEqualObjects(tool[@"strict"], @NO);
  XCTAssertEqualObjects(tool[@"parameters"][@"type"], @"object");
  XCTAssertEqualObjects(high[@"input"], (@[ @{ @"type": @"message", @"role": @"user",
      @"content": @[ @{ @"type": @"input_text", @"text": @"hello" } ] } ]));

  NSDictionary *max = [self bodyForModel:@"gpt-5.6-nano" thinking:@"max"
                                messages:messages tools:@[]];
  XCTAssertEqualObjects(max[@"reasoning"], (@{ @"effort": @"high", @"summary": @"detailed" }));
  XCTAssertNil(max[@"tools"]);

  NSDictionary *off = [self bodyForModel:@"gpt-5.6-mini" thinking:@"off"
                                messages:messages tools:@[]];
  XCTAssertNil(off[@"reasoning"]);
  XCTAssertEqualObjects(off[@"max_output_tokens"], @8192);
}

- (void)testTranscriptConvertsToolRoundsWithoutReplayingReasoning {
  NSArray *messages = @[
    @{ @"role": @"user", @"content": @"write both" },
    @{ @"role": @"assistant", @"content": @"On it.", @"reasoning_content": @"secret plan",
       @"tool_calls": @[
         @{ @"id": @"call_1", @"type": @"function",
            @"function": @{ @"name": @"write_file", @"arguments": @"{\"path\":\"a.txt\"}" } },
         @{ @"id": @"call_2", @"type": @"function",
            @"function": @{ @"name": @"read_file", @"arguments": @"{\"path\":\"b.txt\"}" } },
       ] },
    @{ @"role": @"tool", @"tool_call_id": @"call_1", @"content": @"written" },
    @{ @"role": @"tool", @"tool_call_id": @"call_2", @"content": @"file contents" },
    @{ @"role": @"assistant", @"content": @"", @"reasoning_content": @"only thoughts",
       @"tool_calls": @[] },
  ];
  NSDictionary *body = [self bodyForModel:@"gpt-5.6" thinking:@"high"
                                 messages:messages tools:@[]];
  NSArray *input = body[@"input"];
  XCTAssertEqual([input count], 6u);
  XCTAssertEqualObjects(input[0][@"role"], @"user");
  XCTAssertEqualObjects(input[1], (@{ @"type": @"message", @"role": @"assistant",
      @"content": @[ @{ @"type": @"output_text", @"text": @"On it." } ] }));
  XCTAssertEqualObjects(input[2], (@{ @"type": @"function_call", @"call_id": @"call_1",
      @"name": @"write_file", @"arguments": @"{\"path\":\"a.txt\"}" }));
  XCTAssertNil(input[2][@"id"], @"server item ids are never fabricated");
  XCTAssertEqualObjects(input[3][@"call_id"], @"call_2");
  XCTAssertEqualObjects(input[4], (@{ @"type": @"function_call_output",
      @"call_id": @"call_1", @"output": @"written" }));
  XCTAssertEqualObjects(input[5][@"call_id"], @"call_2");
  for (NSDictionary *item in input) {
    XCTAssertFalse([item[@"type"] isEqual:@"reasoning"], @"reasoning must not be replayed");
  }
}

- (void)testRejectsForeignModelsAndMalformedTranscripts {
  NSError *error = nil;
  XCTAssertNil(([self.transport providerRequestBodyForModel:@"claude-sonnet-5" thinkingMode:@"off"
      messages:@[ @{ @"role": @"user", @"content": @"x" } ] tools:@[] streaming:NO error:&error]));
  XCTAssertEqualObjects(error.localizedDescription, @"E_COMPLETION_MODEL");
  error = nil;
  XCTAssertNil(([self.transport providerRequestBodyForModel:@"gpt-5.6" thinkingMode:@"off"
      messages:@[ @{ @"role": @"tool", @"content": @"missing call id" } ]
      tools:@[] streaming:NO error:&error]));
  XCTAssertEqualObjects(error.localizedDescription, @"E_COMPLETION_TRANSCRIPT");
}

- (NSDictionary *)parse:(NSDictionary *)payload model:(NSString *)model error:(NSError **)error {
  return [self.transport providerParseResponseData:[self jsonData:payload]
                                    requestedModel:model thinkingMode:@"high" error:error];
}

- (NSDictionary *)responseWithOutput:(NSArray *)output status:(NSString *)status {
  return @{ @"id": @"resp_1", @"object": @"response", @"status": status,
            @"error": NSNull.null, @"incomplete_details": NSNull.null,
            @"model": @"gpt-5.6-2026-06-01", @"output": output,
            @"usage": @{ @"input_tokens": @10, @"output_tokens": @5 } };
}

- (void)testParsesOutputItemsAndMapsStatuses {
  NSError *error = nil;
  NSDictionary *parsed = [self parse:[self responseWithOutput:@[
      @{ @"id": @"rs_1", @"type": @"reasoning",
         @"summary": @[ @{ @"type": @"summary_text", @"text": @"first" },
                        @{ @"type": @"summary_text", @"text": @"second" } ] },
      @{ @"id": @"msg_1", @"type": @"message", @"role": @"assistant", @"status": @"completed",
         @"content": @[ @{ @"type": @"output_text", @"text": @"done", @"annotations": @[] } ] },
    ] status:@"completed"] model:@"gpt-5.6" error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(parsed[@"provider_response_id"], @"resp_1");
  XCTAssertEqualObjects(parsed[@"model"], @"gpt-5.6",
                        @"a dated snapshot of the requested model counts as the requested model");
  XCTAssertEqualObjects(parsed[@"text"], @"done");
  XCTAssertEqualObjects(parsed[@"reasoning"], @"first\n\nsecond");
  XCTAssertEqualObjects(parsed[@"finish_reason"], @"stop");
  XCTAssertEqualObjects(parsed[@"tool_calls"], @[]);

  parsed = [self parse:[self responseWithOutput:@[
      @{ @"id": @"fc_1", @"type": @"function_call", @"status": @"completed",
         @"call_id": @"call_9", @"name": @"list_dir", @"arguments": @"{\"path\":\".\"}" },
    ] status:@"completed"] model:@"gpt-5.6" error:&error];
  XCTAssertEqualObjects(parsed[@"finish_reason"], @"tool_calls");
  XCTAssertEqualObjects(parsed[@"tool_calls"], (@[ @{ @"id": @"call_9", @"name": @"list_dir",
                                                      @"arguments": @"{\"path\":\".\"}" } ]));

  NSMutableDictionary *incomplete = [[self responseWithOutput:@[
      @{ @"id": @"msg_1", @"type": @"message", @"role": @"assistant",
         @"content": @[ @{ @"type": @"output_text", @"text": @"partial" } ] } ]
      status:@"incomplete"] mutableCopy];
  incomplete[@"incomplete_details"] = @{ @"reason": @"max_output_tokens" };
  parsed = [self parse:incomplete model:@"gpt-5.6" error:&error];
  XCTAssertEqualObjects(parsed[@"finish_reason"], @"length");
  incomplete[@"incomplete_details"] = @{ @"reason": @"content_filter" };
  parsed = [self parse:incomplete model:@"gpt-5.6" error:&error];
  XCTAssertEqualObjects(parsed[@"finish_reason"], @"content_filter");
}

- (void)testParserFailsClosedOnMismatchesAndProviderErrors {
  NSError *error = nil;
  XCTAssertNil(([self parse:[self responseWithOutput:@[ @{ @"type": @"message", @"role": @"assistant",
      @"content": @[ @{ @"type": @"output_text", @"text": @"x" } ] } ] status:@"completed"]
      model:@"gpt-5.6-mini" error:&error]));
  XCTAssertEqualObjects(error.localizedDescription, @"E_COMPLETION_MODEL_MISMATCH");
  error = nil;
  NSMutableDictionary *failed = [[self responseWithOutput:@[] status:@"failed"] mutableCopy];
  failed[@"error"] = @{ @"code": @"rate_limit_exceeded", @"message": @"secret" };
  XCTAssertNil(([self parse:failed model:@"gpt-5.6" error:&error]));
  XCTAssertEqualObjects(error.localizedDescription, @"E_COMPLETION_RESPONSE_JSON");
  error = nil;
  XCTAssertNil(([self parse:@{ @"error": @{ @"message": @"invalid_api_key" } }
                     model:@"gpt-5.6" error:&error]));
  XCTAssertEqualObjects(error.localizedDescription, @"E_COMPLETION_RESPONSE_JSON");
  error = nil;
  XCTAssertNil(([self parse:[self responseWithOutput:@[] status:@"queued"]
                     model:@"gpt-5.6" error:&error]));
  XCTAssertEqualObjects(error.localizedDescription, @"E_COMPLETION_FINISH_RELATION");
  error = nil;
  XCTAssertNil(([self parse:[self responseWithOutput:@[] status:@"completed"]
                     model:@"gpt-5.6" error:&error]));
  XCTAssertEqualObjects(error.localizedDescription, @"E_COMPLETION_EMPTY_RESPONSE");
  error = nil;
  XCTAssertNil(([self parse:[self responseWithOutput:@[ @{ @"type": @"function_call",
      @"call_id": @"c", @"name": @"x" } ] status:@"completed"] model:@"gpt-5.6" error:&error]));
  XCTAssertEqualObjects(error.localizedDescription, @"E_COMPLETION_TOOL_CALL_INVALID");
}

- (void)testHTTPStatusMappingNamesRateLimitsAndBadCredentials {
  XCTAssertEqualObjects([self.transport providerErrorCodeForHTTPStatus:401 data:nil],
                        @"E_COMPLETION_CREDENTIAL_UNAVAILABLE");
  XCTAssertEqualObjects([self.transport providerErrorCodeForHTTPStatus:429 data:nil],
                        @"E_COMPLETION_HTTP_429");
  XCTAssertEqualObjects([self.transport providerErrorCodeForHTTPStatus:503 data:nil],
                        @"E_COMPLETION_HTTP_STATUS");
}

- (void)startRoundExpectingResult:(NSDictionary **)result errorCode:(NSString **)errorCode {
  NSString *roundId = @"33333333-3333-4333-8333-333333333333";
  NSString *providerId = @"44444444-4444-4444-8444-444444444444";
  NSData *body = [self jsonData:@{ @"model": @"gpt-5.6" }];
  __block NSDictionary *value = nil;
  __block NSString *code = nil;
  XCTestExpectation *done = [self expectationWithDescription:@"round"];
  [self.transport startRequestWithSchemaVersion:2 roundId:roundId generation:1
      credentialGeneration:1 providerRequestId:providerId
      credential:@"sk-test" requestedModel:@"gpt-5.6"
      thinkingMode:@"off" credentialGenerationIsCurrent:^BOOL(__unused NSUInteger g) { return YES; }
      startedAt:1.0 bodyData:body visibleHistory:@[] modelInput:@[]
      bindTask:^BOOL(__unused NSURLSessionDataTask *t) { return YES; }
      claimRound:^BOOL(__unused BOOL *redirected) { return YES; }
      markRedirected:nil redirectDecision:nil
      completion:^(NSDictionary *v, NSString *c) {
        value = v; code = c; [done fulfill];
      }];
  [self waitForExpectations:@[done] timeout:5];
  if (result != NULL) *result = value;
  if (errorCode != NULL) *errorCode = code;
}

- (void)testRoundTripThroughStubServerCarriesHarnessIdAndBearerHeader {
  __block NSDictionary *captured = nil;
  [CodexTransportURLProtocol setHandler:^(NSURLProtocol *protocol, NSURLRequest *request) {
    captured = request.allHTTPHeaderFields;
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc]
        initWithURL:request.URL statusCode:200 HTTPVersion:@"HTTP/1.1"
       headerFields:@{ @"Content-Type": @"application/json" }];
    [protocol.client URLProtocol:protocol didReceiveResponse:response
              cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [protocol.client URLProtocol:protocol didLoadData:[self jsonData:
        [self responseWithOutput:@[ @{ @"type": @"message", @"role": @"assistant",
            @"content": @[ @{ @"type": @"output_text", @"text": @"answer" } ] } ]
                          status:@"completed"]]];
    [protocol.client URLProtocolDidFinishLoading:protocol];
  }];
  NSDictionary *result = nil;
  NSString *errorCode = nil;
  [self startRoundExpectingResult:&result errorCode:&errorCode];
  XCTAssertNil(errorCode);
  XCTAssertEqualObjects(result[@"harness_id"], @"codex");
  XCTAssertEqualObjects(result[@"text"], @"answer");
  XCTAssertEqualObjects(captured[@"Authorization"], @"Bearer sk-test");
}

- (void)testRateLimitedRoundSurfacesStableCodeWithoutBody {
  [CodexTransportURLProtocol setHandler:^(NSURLProtocol *protocol, NSURLRequest *request) {
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc]
        initWithURL:request.URL statusCode:429 HTTPVersion:@"HTTP/1.1"
       headerFields:@{ @"Content-Type": @"application/json", @"retry-after": @"20" }];
    [protocol.client URLProtocol:protocol didReceiveResponse:response
              cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [protocol.client URLProtocol:protocol didLoadData:[self jsonData:
        @{ @"error": @{ @"code": @"rate_limit_exceeded", @"message": @"secret" } }]];
    [protocol.client URLProtocolDidFinishLoading:protocol];
  }];
  NSDictionary *result = nil;
  NSString *errorCode = nil;
  [self startRoundExpectingResult:&result errorCode:&errorCode];
  XCTAssertNil(result);
  XCTAssertEqualObjects(errorCode, @"E_COMPLETION_HTTP_429");
}

- (void)testStreamingParserEmitsDeltasAndCompletedFinish {
  id<DSHProviderStreamEventParsing> parser = [self.transport providerNewStreamEventParser];
  NSData *chunk = [@"event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"hel\"}\n\n"
      dataUsingEncoding:NSUTF8StringEncoding];
  NSError *error = nil;
  NSArray *deltas = [parser appendBytes:(const uint8_t *)chunk.bytes length:chunk.length error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(deltas, (@[ @{ @"type": @"delta", @"content": @"hel" } ]));
  NSData *reasoning = [@"event: response.reasoning_summary_text.delta\ndata: {\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"idea\"}\n\n"
      dataUsingEncoding:NSUTF8StringEncoding];
  deltas = [parser appendBytes:(const uint8_t *)reasoning.bytes length:reasoning.length error:&error];
  XCTAssertEqualObjects(deltas, (@[ @{ @"type": @"delta", @"reasoning": @"idea" } ]));
  NSData *completed = [@"event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"c\",\"name\":\"f\",\"arguments\":\"{}\"}]}}\n\n"
      dataUsingEncoding:NSUTF8StringEncoding];
  deltas = [parser appendBytes:(const uint8_t *)completed.bytes length:completed.length error:&error];
  XCTAssertEqualObjects(deltas, (@[ @{ @"type": @"delta", @"finish_reason": @"tool_calls" } ]));
  XCTAssertEqualObjects([parser finish:&error], @[]);
  XCTAssertNil(error);
}

#pragma mark - Streamed rounds

- (void)testStreamedCodexRoundAssemblesFunctionCallsAndPreviewsFragments {
  [CodexTransportURLProtocol setHandler:^(NSURLProtocol *protocol, NSURLRequest *request) {
    XCTAssertEqualObjects([request valueForHTTPHeaderField:@"Accept"], @"text/event-stream");
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc]
        initWithURL:request.URL statusCode:200 HTTPVersion:@"HTTP/1.1"
       headerFields:@{ @"Content-Type": @"text/event-stream" }];
    [protocol.client URLProtocol:protocol didReceiveResponse:response
              cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    for (NSString *chunk in @[
      @"event: response.created\ndata: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_stream\",\"object\":\"response\",\"model\":\"gpt-5.6\",\"status\":\"in_progress\",\"output\":[]}}\n\n",
      @"event: response.reasoning_summary_text.delta\ndata: {\"type\":\"response.reasoning_summary_text.delta\",\"output_index\":0,\"delta\":\"Plan it.\"}\n\n"
      @"event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"output_index\":1,\"delta\":\"Writing.\"}\n\n",
      @"event: response.output_item.added\ndata: {\"type\":\"response.output_item.added\",\"output_index\":2,\"item\":{\"id\":\"fc_stream\",\"type\":\"function_call\",\"status\":\"in_progress\",\"call_id\":\"call_stream\",\"name\":\"write_file\",\"arguments\":\"\"}}\n\n"
      @"event: response.function_call_arguments.delta\ndata: {\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"fc_stream\",\"output_index\":2,\"delta\":\"{\\\"path\\\":\\\"notes.md\\\",\"}\n\n",
      @"event: response.function_call_arguments.delta\ndata: {\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"fc_stream\",\"output_index\":2,\"delta\":\"\\\"content\\\":\\\"hi\\\"}\"}\n\n"
      @"event: response.function_call_arguments.done\ndata: {\"type\":\"response.function_call_arguments.done\",\"item_id\":\"fc_stream\",\"output_index\":2,\"arguments\":\"{\\\"path\\\":\\\"notes.md\\\",\\\"content\\\":\\\"hi\\\"}\"}\n\n",
      @"event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_stream\",\"object\":\"response\",\"model\":\"gpt-5.6\",\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"call_stream\",\"name\":\"write_file\",\"arguments\":\"{}\"}]}}\n\n",
    ]) {
      [protocol.client URLProtocol:protocol didLoadData:[chunk dataUsingEncoding:NSUTF8StringEncoding]];
    }
    [protocol.client URLProtocolDidFinishLoading:protocol];
  }];
  NSMutableArray<NSDictionary *> *previews = [NSMutableArray array];
  __block NSDictionary *result = nil;
  __block NSString *errorCode = nil;
  XCTestExpectation *done = [self expectationWithDescription:@"streamed round"];
  id<DSHCompletionExecution> execution = [self.transport
      startStreamingExecutionWithSchemaVersion:2
      roundId:@"33333333-3333-4333-8333-333333333333" generation:1 credentialGeneration:1
      providerRequestId:@"44444444-4444-4444-8444-444444444444"
      credential:@"sk-test" requestedModel:@"gpt-5.6" thinkingMode:@"high"
      credentialGenerationIsCurrent:^BOOL(__unused NSUInteger g) { return YES; }
      startedAt:1.0 bodyData:[self jsonData:@{ @"model": @"gpt-5.6", @"stream": @YES }]
      visibleHistory:@[] modelInput:@[]
      preview:^(NSDictionary *delta) { @synchronized (previews) { [previews addObject:delta]; } }
      bindExecution:^BOOL(id<DSHCompletionExecution> candidate) { return candidate != nil; }
      claimRound:^BOOL(__unused BOOL *redirected) { return YES; }
      markRedirected:nil redirectDecision:nil
      completion:^(NSDictionary *v, NSString *c) { result = v; errorCode = c; [done fulfill]; }];
  XCTAssertNotNil(execution);
  [self waitForExpectations:@[done] timeout:5];
  XCTAssertNil(errorCode);
  XCTAssertEqualObjects(result[@"provider_response_id"], @"resp_stream");
  XCTAssertEqualObjects(result[@"harness_id"], @"codex");
  XCTAssertEqualObjects(result[@"text"], @"Writing.");
  XCTAssertEqualObjects(result[@"reasoning"], @"Plan it.");
  XCTAssertEqualObjects(result[@"finish_reason"], @"tool_calls");
  XCTAssertEqual([result[@"tool_calls"] count], 1u);
  XCTAssertEqualObjects(result[@"tool_calls"][0][@"id"], @"call_stream");
  XCTAssertEqualObjects(result[@"tool_calls"][0][@"name"], @"write_file");
  NSDictionary *arguments = [NSJSONSerialization JSONObjectWithData:
      [result[@"tool_calls"][0][@"arguments"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
  XCTAssertEqualObjects(arguments[@"path"], @"notes.md");
  XCTAssertEqualObjects(arguments[@"content"], @"hi");
  NSMutableString *argumentFragments = [NSMutableString string];
  @synchronized (previews) {
    for (NSDictionary *delta in previews) {
      for (NSDictionary *fragment in delta[@"tool_calls"] ?: @[]) {
        XCTAssertEqualObjects(fragment[@"index"], @2);
        if (fragment[@"arguments"]) [argumentFragments appendString:fragment[@"arguments"]];
      }
    }
  }
  XCTAssertEqualObjects(argumentFragments, @"{\"path\":\"notes.md\",\"content\":\"hi\"}");
  XCTAssertFalse([self.transport hasActiveRequests]);
}

@end
