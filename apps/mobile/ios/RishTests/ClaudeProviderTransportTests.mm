#import "../../../../modules/rish/ios/Sources/ConfiguredProviderTransport.h"
#import "../../../../modules/rish/ios/Sources/ProviderConfiguration.h"
#import <XCTest/XCTest.h>

#import "../../../../modules/rish/ios/Sources/ClaudeProviderTransport.h"
#import "../../../../modules/rish/ios/Sources/DSHCompletionV2.h"
#import "../../../../modules/rish/ios/Sources/RishHarnessCatalog.h"

@interface ClaudeTransportURLProtocol : NSURLProtocol
+ (void)setHandler:(void (^)(NSURLProtocol *, NSURLRequest *))handler;
+ (void)reset;
+ (NSUInteger)requestCount;
@end

@implementation ClaudeTransportURLProtocol

static void (^ClaudeTransportHandler)(NSURLProtocol *, NSURLRequest *);
static NSUInteger ClaudeTransportRequestCount = 0;

+ (void)setHandler:(void (^)(NSURLProtocol *, NSURLRequest *))handler {
  @synchronized (self) { ClaudeTransportHandler = [handler copy]; }
}

+ (void)reset {
  @synchronized (self) {
    ClaudeTransportHandler = nil;
    ClaudeTransportRequestCount = 0;
  }
}

+ (NSUInteger)requestCount {
  @synchronized (self) { return ClaudeTransportRequestCount; }
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
  @synchronized (self.class) {
    ClaudeTransportRequestCount += 1;
    handler = [ClaudeTransportHandler copy];
  }
  if (handler != nil) {
    handler(self, self.request);
    return;
  }
  [self.client URLProtocol:self didFailWithError:
      [NSError errorWithDomain:@"ClaudeTransportTests" code:1 userInfo:nil]];
}

- (void)stopLoading {}

@end

/// Forwards the session's data callbacks to the transport so streamed
/// rounds settle the same way they do behind LocalRuntimeModule.
@interface ClaudeStreamingSessionDelegate : NSObject <NSURLSessionDataDelegate>
@property(nonatomic, weak) DSHCompletionProviderTransport *transport;
@end
@implementation ClaudeStreamingSessionDelegate
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

@interface ClaudeProviderTransportTests : XCTestCase
@property(nonatomic, strong) ClaudeStreamingSessionDelegate *streamingDelegate;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) ClaudeProviderTransport *transport;
@end

@implementation ClaudeProviderTransportTests

- (void)setUp {
  [super setUp];
  [ClaudeTransportURLProtocol reset];
  NSURLSessionConfiguration *configuration =
      NSURLSessionConfiguration.ephemeralSessionConfiguration;
  configuration.protocolClasses = @[ClaudeTransportURLProtocol.class];
  self.streamingDelegate = [[ClaudeStreamingSessionDelegate alloc] init];
  self.session = [NSURLSession sessionWithConfiguration:configuration
                                                delegate:self.streamingDelegate
                                           delegateQueue:nil];
  self.transport = [[ClaudeProviderTransport alloc]
      initWithSession:self.session uuidGenerator:nil monotonicClock:nil];
  self.streamingDelegate.transport = self.transport;
}

- (void)tearDown {
  [self.session invalidateAndCancel];
  self.transport = nil;
  self.session = nil;
  [ClaudeTransportURLProtocol reset];
  [super tearDown];
}

- (NSData *)jsonData:(id)value {
  return [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
}

- (void)respond:(NSURLProtocol *)protocol
        request:(NSURLRequest *)request
           data:(NSData *)data
         status:(NSInteger)status {
  NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc]
      initWithURL:request.URL statusCode:status HTTPVersion:@"HTTP/1.1"
     headerFields:@{ @"Content-Type": @"application/json" }];
  [protocol.client URLProtocol:protocol didReceiveResponse:response
            cacheStoragePolicy:NSURLCacheStorageNotAllowed];
  if (data.length > 0) [protocol.client URLProtocol:protocol didLoadData:data];
  [protocol.client URLProtocolDidFinishLoading:protocol];
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

- (void)testHeadersCarryApiKeyAndAnthropicVersion {
  XCTAssertEqualObjects([self.transport providerBaseURL].absoluteString,
                        @"https://api.anthropic.com/v1/messages");
  NSDictionary *headers = [self.transport providerHeadersWithCredential:@"sk-ant-test"];
  XCTAssertEqualObjects(headers[@"x-api-key"], @"sk-ant-test");
  XCTAssertEqualObjects(headers[@"anthropic-version"], @"2023-06-01");
  XCTAssertNil(headers[@"Authorization"]);
  XCTAssertEqualObjects([self.transport providerHarnessId], @"claude-code");
  XCTAssertTrue([self.transport providerSupportsModel:@"claude-fable-5-1"]);
  XCTAssertFalse([self.transport providerSupportsModel:@"gpt-5.6"]);
  XCTAssertFalse([self.transport providerSupportsModel:@"deepseek-v4-flash"]);
}

// GLM rides the Claude dialect over Zhipu's Anthropic-compatible endpoint. It is a
// distinct catalog entry, not a base-URL override: provider_host is recorded
// in consent manifests, proof and snapshots and compared by equality, so the
// host that served a round must be a fixed catalog fact.
- (void)testGlmTransportTargetsBigmodelWithTheClaudeDialect {
  GlmProviderTransport *glm = [[GlmProviderTransport alloc]
      initWithSession:self.session uuidGenerator:nil monotonicClock:nil];
  XCTAssertEqualObjects([glm providerBaseURL].absoluteString,
                        @"https://open.bigmodel.cn/api/anthropic/v1/messages");
  NSDictionary *headers = [glm providerHeadersWithCredential:@"id.secret"];
  XCTAssertEqualObjects(headers[@"x-api-key"], @"id.secret");
  XCTAssertEqualObjects(headers[@"anthropic-version"], @"2023-06-01");
  XCTAssertNil(headers[@"Authorization"]);
  XCTAssertEqualObjects([glm providerHarnessId], @"glm");
  XCTAssertTrue([glm providerSupportsModel:@"GLM-5.3"]);
  XCTAssertTrue([glm providerSupportsModel:@"GLM-5.3-Flash"]);
  XCTAssertFalse([glm providerSupportsModel:@"claude-fable-5-1"]);
  XCTAssertFalse([glm providerSupportsModel:@"deepseek-v4-flash"]);
  XCTAssertFalse([self.transport providerSupportsModel:@"GLM-5.3"]);

  // Catalog facts the evidence layer will record for a GLM round.
  XCTAssertEqualObjects(DSHHarnessIdForModel(@"GLM-5.3-Flash"), @"glm");
  XCTAssertEqualObjects(DSHProviderIdForHarnessId(@"glm"), @"bigmodel");
  XCTAssertEqualObjects(DSHProviderHostForModel(@"GLM-5.3"), @"open.bigmodel.cn");
  XCTAssertTrue(DSHHarnessIsProviderHost(@"open.bigmodel.cn"));
  XCTAssertEqualObjects(DSHCredentialAccountForHarnessId(@"glm"), @"BIGMODEL_API_KEY");
  XCTAssertTrue(DSHHarnessIsCredentialAccount(@"BIGMODEL_API_KEY"));

  // Thinking uses the classic enabled + budget_tokens form; off sends nothing.
  NSArray *messages = @[ @{ @"role": @"user", @"content": @"hello" } ];
  NSError *error = nil;
  NSDictionary *max = [glm providerRequestBodyForModel:@"GLM-5.3" thinkingMode:@"max"
      messages:messages tools:@[] streaming:NO error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(max[@"model"], @"GLM-5.3");
  NSDictionary *expectedThinking = @{ @"type": @"enabled", @"budget_tokens": @16000 };
  XCTAssertEqualObjects(max[@"thinking"], expectedThinking);
  XCTAssertNil(max[@"output_config"]);
  NSDictionary *off = [glm providerRequestBodyForModel:@"GLM-5.3-Flash" thinkingMode:@"off"
      messages:messages tools:@[] streaming:YES error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(off[@"model"], @"GLM-5.3-Flash");
  XCTAssertEqualObjects(off[@"stream"], @YES);
  XCTAssertNil(off[@"thinking"]);
  XCTAssertNil(off[@"output_config"]);
}

- (void)testAdaptiveFamilyMapsThinkingModesWithoutBudgetTokens {
  NSArray *messages = @[
    @{ @"role": @"system", @"content": @"system policy" },
    @{ @"role": @"user", @"content": @"hello" },
  ];
  NSArray *tools = @[@{ @"type": @"function", @"function": @{
    @"name": @"write_file", @"description": @"Writes a file",
    @"parameters": @{ @"type": @"object" } } }];
  for (NSString *model in @[ @"claude-sonnet-5", @"claude-opus-5" ]) {
    NSDictionary *max = [self bodyForModel:model thinking:@"max"
                                  messages:messages tools:tools];
    XCTAssertEqualObjects(max[@"model"], model);
    XCTAssertEqualObjects(max[@"stream"], @NO);
    XCTAssertEqualObjects(max[@"thinking"], (@{ @"type": @"adaptive",
                                                 @"display": @"summarized" }));
    XCTAssertEqualObjects(max[@"output_config"], @{ @"effort": @"max" });
    XCTAssertEqualObjects(max[@"max_tokens"], @16384);
    XCTAssertNil(max[@"thinking"][@"budget_tokens"]);
    XCTAssertEqualObjects(max[@"system"], (@[ @{ @"type": @"text",
                                                  @"text": @"system policy" } ]));
    XCTAssertEqual([max[@"messages"] count], 1u);
    NSDictionary *tool = [max[@"tools"] firstObject];
    XCTAssertEqualObjects(tool[@"name"], @"write_file");
    XCTAssertEqualObjects(tool[@"description"], @"Writes a file");
    XCTAssertEqualObjects(tool[@"input_schema"][@"type"], @"object");
    XCTAssertNil(tool[@"parameters"]);

    NSDictionary *high = [self bodyForModel:model thinking:@"high"
                                   messages:messages tools:@[]];
    XCTAssertEqualObjects(high[@"output_config"], @{ @"effort": @"high" });
    XCTAssertNil(high[@"tools"]);

    NSDictionary *off = [self bodyForModel:model thinking:@"off"
                                  messages:messages tools:@[]];
    XCTAssertEqualObjects(off[@"thinking"], @{ @"type": @"disabled" });
    XCTAssertNil(off[@"output_config"]);
    XCTAssertEqualObjects(off[@"max_tokens"], @8192);
  }
}

- (void)testAlwaysOnFamilyNeverDisablesThinking {
  NSArray *messages = @[ @{ @"role": @"user", @"content": @"hello" } ];
  NSDictionary *off = [self bodyForModel:@"claude-fable-5-1" thinking:@"off"
                                messages:messages tools:@[]];
  XCTAssertNil(off[@"thinking"]);
  XCTAssertEqualObjects(off[@"output_config"], @{ @"effort": @"low" });
  XCTAssertEqualObjects(off[@"max_tokens"], @8192);
  NSDictionary *high = [self bodyForModel:@"claude-fable-5-1" thinking:@"high"
                                 messages:messages tools:@[]];
  XCTAssertEqualObjects(high[@"thinking"][@"type"], @"adaptive");
  XCTAssertEqualObjects(high[@"thinking"][@"display"], @"summarized");
  XCTAssertEqualObjects(high[@"output_config"], @{ @"effort": @"high" });
  XCTAssertEqualObjects(high[@"max_tokens"], @16384);
}

- (void)testBudgetFamilyUsesBudgetTokensAndSkipsThinkingOnToolContinuation {
  NSArray *fresh = @[ @{ @"role": @"user", @"content": @"hello" } ];
  NSDictionary *high = [self bodyForModel:@"claude-haiku-4-5-20251001" thinking:@"high"
                                 messages:fresh tools:@[]];
  XCTAssertEqualObjects(high[@"thinking"], (@{ @"type": @"enabled",
                                                @"budget_tokens": @4096 }));
  XCTAssertEqualObjects(high[@"max_tokens"], @(4096 + 8192));
  XCTAssertNil(high[@"output_config"]);
  NSDictionary *max = [self bodyForModel:@"claude-haiku-4-5-20251001" thinking:@"max"
                                messages:fresh tools:@[]];
  XCTAssertEqualObjects(max[@"thinking"][@"budget_tokens"], @16000);
  XCTAssertEqualObjects(max[@"max_tokens"], @(16000 + 8192));
  NSDictionary *off = [self bodyForModel:@"claude-haiku-4-5-20251001" thinking:@"off"
                                messages:fresh tools:@[]];
  XCTAssertNil(off[@"thinking"]);
  XCTAssertEqualObjects(off[@"max_tokens"], @8192);

  // A continuation round replays a tool_use turn whose thinking block (and
  // signature) the closed transcript never carried; thinking stays off.
  NSArray *continuation = @[
    @{ @"role": @"user", @"content": @"write it" },
    @{ @"role": @"assistant", @"content": @"", @"reasoning_content": @"plan",
       @"tool_calls": @[ @{ @"id": @"toolu_1", @"type": @"function",
         @"function": @{ @"name": @"write_file",
                         @"arguments": @"{\"path\":\"a.txt\",\"content\":\"x\"}" } } ] },
    @{ @"role": @"tool", @"tool_call_id": @"toolu_1", @"content": @"ok" },
  ];
  NSDictionary *round2 = [self bodyForModel:@"claude-haiku-4-5-20251001" thinking:@"high"
                                   messages:continuation tools:@[]];
  XCTAssertNil(round2[@"thinking"]);
  XCTAssertEqualObjects(round2[@"max_tokens"], @8192);
  // The adaptive family keeps thinking on for the same continuation.
  NSDictionary *sonnet = [self bodyForModel:@"claude-sonnet-5" thinking:@"high"
                                   messages:continuation tools:@[]];
  XCTAssertEqualObjects(sonnet[@"thinking"][@"type"], @"adaptive");
}

- (void)testTranscriptConvertsToolRoundsWithoutReplayingReasoning {
  NSArray *messages = @[
    @{ @"role": @"user", @"content": @"write both" },
    @{ @"role": @"assistant", @"content": @"On it.", @"reasoning_content": @"secret plan",
       @"tool_calls": @[
         @{ @"id": @"toolu_1", @"type": @"function",
            @"function": @{ @"name": @"write_file", @"arguments": @"{\"path\":\"a.txt\"}" } },
         @{ @"id": @"toolu_2", @"type": @"function",
            @"function": @{ @"name": @"read_file", @"arguments": @"{\"path\":\"b.txt\"}" } },
       ] },
    @{ @"role": @"tool", @"tool_call_id": @"toolu_1", @"content": @"written" },
    @{ @"role": @"tool", @"tool_call_id": @"toolu_2", @"content": @"file contents" },
    @{ @"role": @"assistant", @"content": @"", @"reasoning_content": @"only thoughts",
       @"tool_calls": @[] },
  ];
  NSDictionary *body = [self bodyForModel:@"claude-opus-5" thinking:@"high"
                                 messages:messages tools:@[]];
  NSArray *converted = body[@"messages"];
  XCTAssertEqual([converted count], 4u);
  XCTAssertEqualObjects(converted[0][@"role"], @"user");
  XCTAssertEqualObjects(converted[1][@"role"], @"assistant");
  NSArray *assistantBlocks = converted[1][@"content"];
  XCTAssertEqual([assistantBlocks count], 3u);
  XCTAssertEqualObjects(assistantBlocks[0], (@{ @"type": @"text", @"text": @"On it." }));
  XCTAssertEqualObjects(assistantBlocks[1][@"type"], @"tool_use");
  XCTAssertEqualObjects(assistantBlocks[1][@"id"], @"toolu_1");
  XCTAssertEqualObjects(assistantBlocks[1][@"name"], @"write_file");
  XCTAssertEqualObjects(assistantBlocks[1][@"input"], @{ @"path": @"a.txt" });
  XCTAssertEqualObjects(assistantBlocks[2][@"id"], @"toolu_2");
  for (NSDictionary *block in assistantBlocks) {
    XCTAssertFalse([block[@"type"] isEqual:@"thinking"], @"reasoning must not be replayed");
  }
  // Both tool results answer one assistant turn inside a single user turn.
  XCTAssertEqualObjects(converted[2][@"role"], @"user");
  NSArray *results = converted[2][@"content"];
  XCTAssertEqual([results count], 2u);
  XCTAssertEqualObjects(results[0], (@{ @"type": @"tool_result",
                                        @"tool_use_id": @"toolu_1",
                                        @"content": @"written" }));
  XCTAssertEqualObjects(results[1][@"tool_use_id"], @"toolu_2");
  // A reasoning-only assistant turn keeps its slot with placeholder text.
  XCTAssertEqualObjects(converted[3][@"role"], @"assistant");
  XCTAssertEqualObjects(converted[3][@"content"][0][@"type"], @"text");
  XCTAssertEqual([converted[3][@"content"] count], 1u);
}

- (void)testRejectsForeignModelsAndMalformedTranscripts {
  NSError *error = nil;
  XCTAssertNil(([self.transport providerRequestBodyForModel:@"gpt-5.6" thinkingMode:@"off"
      messages:@[ @{ @"role": @"user", @"content": @"x" } ] tools:@[] streaming:NO error:&error]));
  XCTAssertEqualObjects(error.localizedDescription, @"E_COMPLETION_MODEL");
  error = nil;
  XCTAssertNil(([self.transport providerRequestBodyForModel:@"claude-sonnet-5" thinkingMode:@"off"
      messages:@[ @{ @"role": @"assistant", @"tool_calls": @[ @{ @"id": @"x" } ] } ]
      tools:@[] streaming:NO error:&error]));
  XCTAssertEqualObjects(error.localizedDescription, @"E_COMPLETION_TRANSCRIPT");
  error = nil;
  XCTAssertNil(([self.transport providerRequestBodyForModel:@"claude-sonnet-5" thinkingMode:@"off"
      messages:@[ @{ @"role": @"user", @"content": @"x" } ]
      tools:@[ @{ @"type": @"function", @"function": @{ @"name": @"broken" } } ]
      streaming:NO error:&error]));
  XCTAssertEqualObjects(error.localizedDescription, @"E_COMPLETION_TOOLS");
}

- (NSDictionary *)parse:(NSDictionary *)payload model:(NSString *)model error:(NSError **)error {
  return [self.transport providerParseResponseData:[self jsonData:payload]
                                    requestedModel:model thinkingMode:@"high" error:error];
}

- (void)testClaudeModelIdentityRetainsAbsentExactAndSnapshotEchoRules {
  for (id echo in @[ NSNull.null, @"claude-sonnet-5", @"claude-sonnet-5-20260415" ]) {
    NSMutableDictionary *payload = [@{
      @"id": @"msg-claude-identity",
      @"content": @[ @{ @"type": @"text", @"text": @"answer" } ],
      @"stop_reason": @"end_turn",
    } mutableCopy];
    if (echo != NSNull.null) payload[@"model"] = echo;
    NSError *error = nil;
    NSDictionary *parsed = [self parse:payload model:@"claude-sonnet-5" error:&error];
    XCTAssertNil(error);
    XCTAssertEqualObjects(parsed[@"model"], @"claude-sonnet-5");
  }
  XCTAssertFalse([self.transport providerReportedModel:@"CLAUDE-SONNET-5"
                                matchesRequestedModel:@"claude-sonnet-5"]);
}

- (void)testGlmResponseIdentityAcceptsOnlyExactModelWithASCIICaseDifferences {
  GlmProviderTransport *glm = [[GlmProviderTransport alloc]
      initWithSession:self.session uuidGenerator:nil monotonicClock:nil];
  for (NSString *model in @[ @"GLM-5.3", @"GLM-5.3-Flash" ]) {
    for (NSString *echo in @[ model, model.lowercaseString, model.uppercaseString ]) {
      NSError *error = nil;
      NSDictionary *parsed = [glm providerParseResponseData:[self jsonData:@{
        @"id": @"msg-glm-identity", @"model": echo,
        @"content": @[ @{ @"type": @"text", @"text": @"answer" } ],
        @"stop_reason": @"end_turn",
      }] requestedModel:model thinkingMode:@"high" error:&error];
      XCTAssertNil(error, @"%@ echoed as %@", model, echo);
      XCTAssertEqualObjects(parsed[@"model"], model);
      XCTAssertEqualObjects(parsed[@"text"], @"answer");
    }
  }
}

- (void)testGlmResponseIdentityRejectsWrongModelsSuffixesMissingAndNonASCIIEchoes {
  GlmProviderTransport *glm = [[GlmProviderTransport alloc]
      initWithSession:self.session uuidGenerator:nil monotonicClock:nil];
  for (NSString *model in @[ @"GLM-5.3", @"GLM-5.3-Flash" ]) {
    NSString *otherVariant = [model isEqualToString:@"GLM-5.3"]
        ? @"glm-5.3-flash" : @"glm-5.3";
    NSArray *invalidEchoes = @[
      NSNull.null, @"", @42, otherVariant, @"glm-5.2", @"claude-sonnet-5",
      [model stringByAppendingString:@"-20260906"],
      [model stringByAppendingString:@"-anything"],
      [model stringByAppendingString:@" "],
      [model stringByReplacingOccurrencesOfString:@"GLM" withString:@"ＧＬＭ"],
      [model stringByReplacingOccurrencesOfString:@"-" withString:@"−"],
      @"glm-5.3-flaſh",
    ];
    for (id echo in invalidEchoes) {
      NSMutableDictionary *payload = [@{
        @"id": @"msg-glm-rejected", @"model": echo,
        @"content": @[ @{ @"type": @"text", @"text": @"answer" } ],
        @"stop_reason": @"end_turn",
      } mutableCopy];
      NSError *error = nil;
      XCTAssertNil([glm providerParseResponseData:[self jsonData:payload]
          requestedModel:model thinkingMode:@"high" error:&error], @"%@ / %@", model, echo);
      XCTAssertEqualObjects(error.localizedDescription, @"E_COMPLETION_MODEL_MISMATCH");
      if (echo == NSNull.null) {
        [payload removeObjectForKey:@"model"];
        error = nil;
        XCTAssertNil([glm providerParseResponseData:[self jsonData:payload]
            requestedModel:model thinkingMode:@"high" error:&error]);
        XCTAssertEqualObjects(error.localizedDescription, @"E_COMPLETION_MODEL_MISMATCH");
      }
    }
  }
}

- (void)testParsesContentBlocksAndMapsStopReasons {
  NSError *error = nil;
  NSDictionary *parsed = [self parse:@{
    @"id": @"msg_123", @"type": @"message", @"role": @"assistant",
    @"model": @"claude-sonnet-5-20260415",
    @"content": @[
      @{ @"type": @"thinking", @"thinking": @"reasoned", @"signature": @"sig" },
      @{ @"type": @"redacted_thinking", @"data": @"opaque" },
      @{ @"type": @"text", @"text": @"done" },
    ],
    @"stop_reason": @"end_turn", @"stop_sequence": NSNull.null,
    @"usage": @{ @"input_tokens": @10, @"output_tokens": @5 },
  } model:@"claude-sonnet-5" error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(parsed[@"provider_response_id"], @"msg_123");
  XCTAssertEqualObjects(parsed[@"model"], @"claude-sonnet-5",
                        @"a dated snapshot of the requested alias counts as the requested model");
  XCTAssertEqualObjects(parsed[@"text"], @"done");
  XCTAssertEqualObjects(parsed[@"reasoning"], @"reasoned");
  XCTAssertEqualObjects(parsed[@"finish_reason"], @"stop");
  XCTAssertEqualObjects(parsed[@"tool_calls"], @[]);

  parsed = [self parse:@{
    @"id": @"msg_456", @"model": @"claude-sonnet-5",
    @"content": @[
      @{ @"type": @"text", @"text": @"Listing." },
      @{ @"type": @"tool_use", @"id": @"toolu_9", @"name": @"list_dir", @"input": @{ @"path": @"." } },
    ],
    @"stop_reason": @"tool_use",
  } model:@"claude-sonnet-5" error:&error];
  XCTAssertEqualObjects(parsed[@"finish_reason"], @"tool_calls");
  XCTAssertEqualObjects(parsed[@"tool_calls"], (@[ @{ @"id": @"toolu_9", @"name": @"list_dir",
                                                      @"arguments": @"{\"path\":\".\"}" } ]));

  parsed = [self parse:@{ @"id": @"msg_789", @"model": @"claude-haiku-4-5-20251001",
    @"content": @[ @{ @"type": @"text", @"text": @"partial" } ], @"stop_reason": @"max_tokens" }
    model:@"claude-haiku-4-5-20251001" error:&error];
  XCTAssertEqualObjects(parsed[@"finish_reason"], @"length");

  parsed = [self parse:@{ @"id": @"msg_r", @"model": @"claude-fable-5-1", @"content": @[],
    @"stop_reason": @"refusal", @"stop_details": @{ @"type": @"refusal", @"category": @"cyber" } }
    model:@"claude-fable-5-1" error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(parsed[@"finish_reason"], @"content_filter");
  XCTAssertEqualObjects(parsed[@"text"], @"");

  parsed = [self parse:@{ @"id": @"msg_p", @"model": @"claude-opus-5",
    @"content": @[ @{ @"type": @"text", @"text": @"still going" } ], @"stop_reason": @"pause_turn" }
    model:@"claude-opus-5" error:&error];
  XCTAssertEqualObjects(parsed[@"finish_reason"], @"stop");
}

- (void)testParserFailsClosedOnMismatchesAndProviderErrors {
  NSError *error = nil;
  XCTAssertNil(([self parse:@{ @"id": @"m", @"model": @"claude-opus-5",
    @"content": @[ @{ @"type": @"text", @"text": @"x" } ], @"stop_reason": @"end_turn" }
    model:@"claude-sonnet-5" error:&error]));
  XCTAssertEqualObjects(error.localizedDescription, @"E_COMPLETION_MODEL_MISMATCH");
  error = nil;
  XCTAssertNil(([self parse:@{ @"type": @"error",
    @"error": @{ @"type": @"rate_limit_error", @"message": @"slow down" } }
    model:@"claude-sonnet-5" error:&error]));
  XCTAssertEqualObjects(error.localizedDescription, @"E_COMPLETION_RESPONSE_JSON");
  error = nil;
  XCTAssertNil(([self parse:@{ @"model": @"claude-sonnet-5",
    @"content": @[ @{ @"type": @"text", @"text": @"x" } ], @"stop_reason": @"end_turn" }
    model:@"claude-sonnet-5" error:&error]));
  XCTAssertEqualObjects(error.localizedDescription, @"E_COMPLETION_PROVIDER_RESPONSE_ID");
  error = nil;
  XCTAssertNil(([self parse:@{ @"id": @"m", @"model": @"claude-sonnet-5",
    @"content": @[ @{ @"type": @"text", @"text": @"x" } ], @"stop_reason": @"tool_use" }
    model:@"claude-sonnet-5" error:&error]));
  XCTAssertEqualObjects(error.localizedDescription, @"E_COMPLETION_FINISH_RELATION");
  error = nil;
  XCTAssertNil(([self parse:@{ @"id": @"m", @"model": @"claude-sonnet-5",
    @"content": @[ @{ @"type": @"tool_use", @"id": @"t", @"name": @"x" } ],
    @"stop_reason": @"tool_use" } model:@"claude-sonnet-5" error:&error]));
  XCTAssertEqualObjects(error.localizedDescription, @"E_COMPLETION_TOOL_CALL_INVALID");
  error = nil;
  XCTAssertNil(([self parse:@{ @"id": @"m", @"model": @"claude-sonnet-5",
    @"content": @[], @"stop_reason": @"end_turn" } model:@"claude-sonnet-5" error:&error]));
  XCTAssertEqualObjects(error.localizedDescription, @"E_COMPLETION_EMPTY_RESPONSE");
  error = nil;
  XCTAssertNil(([self parse:@{ @"id": @"m", @"model": @"claude-sonnet-5",
    @"content": @[ @{ @"type": @"text", @"text": @"x" } ], @"stop_reason": @"future_reason" }
    model:@"claude-sonnet-5" error:&error]));
  XCTAssertEqualObjects(error.localizedDescription, @"E_COMPLETION_FINISH_RELATION");
}

- (void)testHTTPStatusMappingNamesRateLimitsAndBadCredentials {
  XCTAssertEqualObjects([self.transport providerErrorCodeForHTTPStatus:401 data:nil],
                        @"E_COMPLETION_CREDENTIAL_UNAVAILABLE");
  XCTAssertEqualObjects([self.transport providerErrorCodeForHTTPStatus:403 data:nil],
                        @"E_COMPLETION_CREDENTIAL_UNAVAILABLE");
  XCTAssertEqualObjects([self.transport providerErrorCodeForHTTPStatus:429 data:nil],
                        @"E_COMPLETION_HTTP_429");
  XCTAssertEqualObjects([self.transport providerErrorCodeForHTTPStatus:529 data:nil],
                        @"E_COMPLETION_HTTP_429");
  XCTAssertEqualObjects([self.transport providerErrorCodeForHTTPStatus:500 data:nil],
                        @"E_COMPLETION_HTTP_STATUS");
  XCTAssertEqualObjects([self.transport providerErrorCodeForHTTPStatus:400 data:nil],
                        @"E_COMPLETION_HTTP_STATUS");
}

- (void)startRoundExpectingResult:(NSDictionary **)result errorCode:(NSString **)errorCode {
  [self startRoundWithTransport:self.transport model:@"claude-sonnet-5"
      schemaVersion:2 result:result errorCode:errorCode];
}

- (void)startRoundWithTransport:(DSHCompletionProviderTransport *)transport
                         model:(NSString *)model
                 schemaVersion:(NSInteger)schemaVersion
                        result:(NSDictionary **)result
                     errorCode:(NSString **)errorCode {
  NSString *roundId = @"33333333-3333-4333-8333-333333333333";
  NSString *providerId = @"44444444-4444-4444-8444-444444444444";
  NSData *body = [self jsonData:@{ @"model": model }];
  __block NSDictionary *value = nil;
  __block NSString *code = nil;
  XCTestExpectation *done = [self expectationWithDescription:@"round"];
  [transport startRequestWithSchemaVersion:schemaVersion roundId:roundId generation:1
      credentialGeneration:1 providerRequestId:providerId
      credential:@"sk-ant-test" requestedModel:model
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

- (void)testRoundTripThroughStubServerCarriesHarnessIdAndHeaders {
  __block NSDictionary *captured = nil;
  [ClaudeTransportURLProtocol setHandler:^(NSURLProtocol *protocol, NSURLRequest *request) {
    captured = request.allHTTPHeaderFields;
    [self respond:protocol request:request data:[self jsonData:@{
      @"id": @"msg-round", @"model": @"claude-sonnet-5",
      @"content": @[ @{ @"type": @"text", @"text": @"answer" } ],
      @"stop_reason": @"end_turn",
    }] status:200];
  }];
  NSDictionary *result = nil;
  NSString *errorCode = nil;
  [self startRoundExpectingResult:&result errorCode:&errorCode];
  XCTAssertNil(errorCode);
  XCTAssertEqualObjects(result[@"harness_id"], @"claude-code");
  XCTAssertEqualObjects(result[@"text"], @"answer");
  XCTAssertEqualObjects(result[@"requested_model"], @"claude-sonnet-5");
  XCTAssertEqualObjects(captured[@"x-api-key"], @"sk-ant-test");
  XCTAssertEqualObjects(captured[@"anthropic-version"], @"2023-06-01");
  XCTAssertEqual([ClaudeTransportURLProtocol requestCount], 1u);
}

- (void)testGlmStrictRoundsKeepCanonicalModelAndHarnessAfterLowercaseEcho {
  GlmProviderTransport *glm = [[GlmProviderTransport alloc]
      initWithSession:self.session uuidGenerator:nil monotonicClock:nil];
  for (NSNumber *schemaVersion in @[ @2, @3 ]) {
    for (NSString *model in @[ @"GLM-5.3", @"GLM-5.3-Flash" ]) {
      [ClaudeTransportURLProtocol setHandler:^(NSURLProtocol *protocol, NSURLRequest *request) {
        XCTAssertEqualObjects(request.URL.host, @"open.bigmodel.cn");
        [self respond:protocol request:request data:[self jsonData:@{
          @"id": @"msg-glm-round", @"model": model.lowercaseString,
          @"content": @[ @{ @"type": @"text", @"text": @"answer" } ],
          @"stop_reason": @"end_turn",
        }] status:200];
      }];
      NSDictionary *result = nil;
      NSString *errorCode = nil;
      [self startRoundWithTransport:glm model:model schemaVersion:schemaVersion.integerValue
          result:&result errorCode:&errorCode];
      XCTAssertNil(errorCode);
      XCTAssertNotNil(result);
      XCTAssertEqualObjects(result[@"harness_id"], @"glm");
      XCTAssertEqualObjects(result[@"requested_model"], model);
      XCTAssertEqualObjects(result[@"model"], model);
      XCTAssertEqualObjects(result[@"provider_request_id"], @"44444444-4444-4444-8444-444444444444");
      XCTAssertEqualObjects(result[@"provider_response_id"], @"msg-glm-round");
    }
  }
  XCTAssertEqual([ClaudeTransportURLProtocol requestCount], 4u);
}

- (void)testGlmStrictRoundRejectsCrossProviderResponseIdentity {
  GlmProviderTransport *glm = [[GlmProviderTransport alloc]
      initWithSession:self.session uuidGenerator:nil monotonicClock:nil];
  [ClaudeTransportURLProtocol setHandler:^(NSURLProtocol *protocol, NSURLRequest *request) {
    [self respond:protocol request:request data:[self jsonData:@{
      @"id": @"msg-wrong-provider", @"model": @"claude-sonnet-5",
      @"content": @[ @{ @"type": @"text", @"text": @"answer" } ],
      @"stop_reason": @"end_turn",
    }] status:200];
  }];
  NSDictionary *result = nil;
  NSString *errorCode = nil;
  [self startRoundWithTransport:glm model:@"GLM-5.3-Flash" schemaVersion:2
      result:&result errorCode:&errorCode];
  XCTAssertNil(result);
  XCTAssertEqualObjects(errorCode, @"E_COMPLETION_MODEL_MISMATCH");
}

- (void)testRateLimitedRoundSurfacesStableCodeWithoutBody {
  [ClaudeTransportURLProtocol setHandler:^(NSURLProtocol *protocol, NSURLRequest *request) {
    [self respond:protocol request:request data:[self jsonData:@{
      @"type": @"error", @"error": @{ @"type": @"rate_limit_error", @"message": @"secret" } }]
      status:429];
  }];
  NSDictionary *result = nil;
  NSString *errorCode = nil;
  [self startRoundExpectingResult:&result errorCode:&errorCode];
  XCTAssertNil(result);
  XCTAssertEqualObjects(errorCode, @"E_COMPLETION_HTTP_429");
}

- (void)testStreamingParserEmitsTextThinkingAndFinishDeltas {
  id<DSHProviderStreamEventParsing> parser = [self.transport providerNewStreamEventParser];
  NSData *chunk = [@"event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"hel\"}}\n\n"
      dataUsingEncoding:NSUTF8StringEncoding];
  NSError *error = nil;
  NSArray *deltas = [parser appendBytes:(const uint8_t *)chunk.bytes length:chunk.length error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(deltas, (@[ @{ @"type": @"delta", @"content": @"hel" } ]));
  NSData *thinking = [@"event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"plan\"}}\n\n"
      dataUsingEncoding:NSUTF8StringEncoding];
  deltas = [parser appendBytes:(const uint8_t *)thinking.bytes length:thinking.length error:&error];
  XCTAssertEqualObjects(deltas, (@[ @{ @"type": @"delta", @"reasoning": @"plan" } ]));
  NSData *stop = [@"event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"refusal\"}}\n\n"
      dataUsingEncoding:NSUTF8StringEncoding];
  deltas = [parser appendBytes:(const uint8_t *)stop.bytes length:stop.length error:&error];
  XCTAssertEqualObjects(deltas, (@[ @{ @"type": @"delta", @"finish_reason": @"content_filter" } ]));
  XCTAssertEqualObjects([parser finish:&error], @[]);
  XCTAssertNil(error);
}


- (NSDictionary *)customConfiguration:(NSString *)protocol endpoint:(NSString *)endpoint {
  return @{@"schema_version": @1, @"harness_id": @"claude-code", @"name": @"Test relay",
    @"protocol": protocol, @"endpoint_url": endpoint, @"auth_type": @"bearer",
    @"send_reasoning": @NO, @"model_mappings": @{@"claude-sonnet-5": @"relay-model"}};
}

- (void)testCustomProviderConfigurationRejectsUnsafeEndpointsAndKeepsRestartState {
  NSString *suite = [@"custom-provider-" stringByAppendingString:NSUUID.UUID.UUIDString];
  NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
  DSHProviderConfigurationStore *store = [[DSHProviderConfigurationStore alloc] initWithDefaults:defaults];
  NSDictionary *configuration = [store saveConfiguration:[self customConfiguration:@"messages" endpoint:@"https://relay.example/v1"] error:nil];
  XCTAssertEqualObjects(configuration[@"endpoint_url"], @"https://relay.example/v1/messages");
  DSHProviderConfigurationStore *restarted = [[DSHProviderConfigurationStore alloc] initWithDefaults:defaults];
  XCTAssertEqualObjects([restarted configurationForHarness:@"claude-code"], configuration);
  for (NSString *url in @[@"http://relay.example", @"https://key@relay.example", @"https://relay.example?key=secret", @"https://relay.example/#secret"]) {
    XCTAssertNil(DSHNormalizeProviderConfiguration([self customConfiguration:@"messages" endpoint:url]));
  }
  XCTAssertNotNil(DSHNormalizeProviderConfiguration([self customConfiguration:@"chat-completions" endpoint:@"http://127.0.0.1:9999/v1"]));
  XCTAssertNotNil(DSHNormalizeProviderConfiguration([self customConfiguration:@"messages" endpoint:@"http://[::1]:9999/v1"]));
  XCTAssertEqualObjects(DSHNormalizeProviderEndpoint(@"https://relay.example/v1/responses", @"chat-completions"), @"https://relay.example/v1/chat/completions");
  NSMutableDictionary *full = [[self customConfiguration:@"messages" endpoint:@"https://relay.example/custom/endpoint"] mutableCopy];
  full[@"full_url"] = @YES;
  NSDictionary *normalizedFull = DSHNormalizeProviderConfiguration(full);
  XCTAssertEqualObjects(normalizedFull[@"endpoint_url"], full[@"endpoint_url"]);
  XCTAssertTrue(DSHValidateProviderBinding(DSHProviderBindingFromConfiguration(normalizedFull, @"claude-sonnet-5"), @"claude-sonnet-5"));
  NSMutableDictionary *withSecret = [[self customConfiguration:@"messages" endpoint:@"https://relay.example"] mutableCopy];
  withSecret[@"api_key"] = @"must-never-persist";
  XCTAssertNil(DSHNormalizeProviderConfiguration(withSecret));
  XCTAssertEqualObjects([store resetHarness:@"claude-code"][@"official"], @YES);
  [defaults removePersistentDomainForName:suite];
}

- (void)testCustomProvidersRouteAllThreeProtocolsAndRecordTheRealTarget {
  for (NSString *protocol in @[@"messages", @"responses", @"chat-completions"]) {
    [ClaudeTransportURLProtocol reset];
    NSString *suite = [@"custom-wire-" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    DSHProviderConfigurationStore *store = [[DSHProviderConfigurationStore alloc] initWithDefaults:defaults];
    [store saveConfiguration:[self customConfiguration:protocol endpoint:@"https://relay.example/v1"] error:nil];
    DSHConfiguredProviderTransport *transport = [[DSHConfiguredProviderTransport alloc]
        initWithHarness:@"claude-code" session:self.session uuidGenerator:nil monotonicClock:nil store:store];
    NSDictionary *binding = [transport providerConfigurationForModel:@"claude-sonnet-5"];
    XCTAssertTrue(DSHValidateProviderBinding(binding, @"claude-sonnet-5"));
    XCTAssertEqualObjects(binding[@"model_id"], @"relay-model");
    [ClaudeTransportURLProtocol setHandler:^(NSURLProtocol *p, NSURLRequest *request) {
      XCTAssertEqualObjects(request.URL.host, @"relay.example");
      XCTAssertNotNil([request valueForHTTPHeaderField:@"Authorization"]);
      NSDictionary *payload = nil;
      if ([protocol isEqual:@"messages"]) {
        XCTAssertEqualObjects(request.URL.path, @"/v1/messages");
        payload = @{@"id": @"response-custom", @"model": @"relay-model", @"content": @[@{@"type": @"text", @"text": @"answer"}], @"stop_reason": @"end_turn"};
      } else if ([protocol isEqual:@"responses"]) {
        XCTAssertEqualObjects(request.URL.path, @"/v1/responses");
        payload = @{@"id": @"response-custom", @"model": @"relay-model", @"status": @"completed", @"output": @[@{@"type": @"message", @"role": @"assistant", @"content": @[@{@"type": @"output_text", @"text": @"answer"}]}]};
      } else {
        XCTAssertEqualObjects(request.URL.path, @"/v1/chat/completions");
        payload = @{@"id": @"response-custom", @"model": @"relay-model", @"choices": @[@{@"finish_reason": @"stop", @"message": @{@"role": @"assistant", @"content": @"answer"}}]};
      }
      [self respond:p request:request data:[self jsonData:payload] status:200];
    }];
    NSDictionary *result = nil; NSString *errorCode = nil;
    [self startRoundWithTransport:transport model:@"claude-sonnet-5" schemaVersion:2 result:&result errorCode:&errorCode];
    XCTAssertNil(errorCode, @"%@", protocol);
    XCTAssertEqualObjects(result[@"model"], @"claude-sonnet-5");
    XCTAssertEqualObjects(result[@"provider_configuration"], binding);
    [defaults removePersistentDomainForName:suite];
  }
}

// A relay the person configured answers for the model they chose under
// whatever name it uses. Refusing every name but the exact one made custom
// relays fail after the answer arrived -- "only Claude works" (2026-09-24).
- (void)testCustomProvidersAcceptWhateverNameTheRelayReportsButRecordTheChosenModel {
  for (NSString *protocol in @[@"messages", @"responses", @"chat-completions"]) {
    for (id reported in @[@"deepseek-chat", @"relay-model-2025-01-01", NSNull.null, @"<absent>", @7]) {
      [ClaudeTransportURLProtocol reset];
      NSString *suite = [@"custom-alias-" stringByAppendingString:NSUUID.UUID.UUIDString];
      NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
      DSHProviderConfigurationStore *store = [[DSHProviderConfigurationStore alloc] initWithDefaults:defaults];
      [store saveConfiguration:[self customConfiguration:protocol endpoint:@"https://relay.example/v1"] error:nil];
      DSHConfiguredProviderTransport *transport = [[DSHConfiguredProviderTransport alloc]
          initWithHarness:@"claude-code" session:self.session uuidGenerator:nil monotonicClock:nil store:store];
      [ClaudeTransportURLProtocol setHandler:^(NSURLProtocol *p, NSURLRequest *request) {
        NSMutableDictionary *payload = nil;
        if ([protocol isEqual:@"messages"]) {
          payload = [@{@"id": @"response-alias", @"content": @[@{@"type": @"text", @"text": @"answer"}], @"stop_reason": @"end_turn"} mutableCopy];
        } else if ([protocol isEqual:@"responses"]) {
          payload = [@{@"id": @"response-alias", @"status": @"completed", @"output": @[@{@"type": @"message", @"role": @"assistant", @"content": @[@{@"type": @"output_text", @"text": @"answer"}]}]} mutableCopy];
        } else {
          payload = [@{@"id": @"response-alias", @"choices": @[@{@"finish_reason": @"stop", @"message": @{@"role": @"assistant", @"content": @"answer"}}]} mutableCopy];
        }
        if (![reported isEqual:@"<absent>"]) payload[@"model"] = reported;
        [self respond:p request:request data:[self jsonData:payload] status:200];
      }];
      NSDictionary *result = nil; NSString *errorCode = nil;
      [self startRoundWithTransport:transport model:@"claude-sonnet-5" schemaVersion:2 result:&result errorCode:&errorCode];
      if ([reported isKindOfClass:NSNumber.class]) {
        // Not a name at all: still refused.
        XCTAssertEqualObjects(errorCode, @"E_COMPLETION_MODEL_MISMATCH", @"%@ %@", protocol, reported);
      } else {
        XCTAssertNil(errorCode, @"%@ %@", protocol, reported);
        XCTAssertEqualObjects(result[@"model"], @"claude-sonnet-5", @"%@ %@", protocol, reported);
      }
      [defaults removePersistentDomainForName:suite];
    }
  }
}

// DeepSeek and GLM through a relay, on every protocol: the testers asked
// for all four harnesses, not only Claude Code and Codex (2026-09-24).
- (void)testDshAndGlmGoThroughARelayOnEveryProtocol {
  NSDictionary *models = @{@"dsh": @"deepseek-v4-flash", @"glm": @"GLM-5.3"};
  for (NSString *harness in models) {
    NSString *model = models[harness];
    for (NSString *protocol in @[@"messages", @"responses", @"chat-completions"]) {
      [ClaudeTransportURLProtocol reset];
      NSString *suite = [@"custom-other-" stringByAppendingString:NSUUID.UUID.UUIDString];
      NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
      DSHProviderConfigurationStore *store = [[DSHProviderConfigurationStore alloc] initWithDefaults:defaults];
      XCTAssertEqualObjects([store configurationForHarness:harness][@"official"], @YES, @"%@", harness);
      NSDictionary *saved = [store saveConfiguration:@{@"schema_version": @1, @"harness_id": harness, @"name": @"Relay",
          @"protocol": protocol, @"endpoint_url": @"https://relay.example/v1", @"auth_type": @"bearer",
          @"send_reasoning": @NO, @"model_mappings": @{model: @"relay-model"}} error:nil];
      XCTAssertNotNil(saved, @"%@ %@", harness, protocol);
      DSHConfiguredProviderTransport *transport = [[DSHConfiguredProviderTransport alloc]
          initWithHarness:harness session:self.session uuidGenerator:nil monotonicClock:nil store:store];
      NSDictionary *binding = [transport providerConfigurationForModel:model];
      XCTAssertTrue(DSHValidateProviderBinding(binding, model), @"%@ %@", harness, protocol);
      // The body the relay receives: the mapped model, and no reasoning
      // settings, since this relay was told not to receive them.
      NSError *bodyError = nil;
      NSDictionary *body = [transport providerRequestBodyForModel:model thinkingMode:@"high"
          messages:@[@{@"role": @"user", @"content": @"hi"}] tools:@[] streaming:NO error:&bodyError];
      XCTAssertNil(bodyError, @"%@ %@", harness, protocol);
      XCTAssertEqualObjects(body[@"model"], @"relay-model", @"%@ %@", harness, protocol);
      XCTAssertNil(body[@"thinking"], @"%@ %@", harness, protocol);
      XCTAssertNil(body[@"reasoning_effort"], @"%@ %@", harness, protocol);
      [ClaudeTransportURLProtocol setHandler:^(NSURLProtocol *p, NSURLRequest *request) {
        XCTAssertEqualObjects(request.URL.host, @"relay.example");
        NSDictionary *payload = [protocol isEqual:@"messages"]
            ? @{@"id": @"r", @"model": @"relay-model", @"content": @[@{@"type": @"text", @"text": @"answer"}], @"stop_reason": @"end_turn"}
            : ([protocol isEqual:@"responses"]
               ? @{@"id": @"r", @"model": @"relay-model", @"status": @"completed", @"output": @[@{@"type": @"message", @"role": @"assistant", @"content": @[@{@"type": @"output_text", @"text": @"answer"}]}]}
               : @{@"id": @"r", @"model": @"relay-model", @"choices": @[@{@"finish_reason": @"stop", @"message": @{@"role": @"assistant", @"content": @"answer"}}]});
        [self respond:p request:request data:[self jsonData:payload] status:200];
      }];
      NSDictionary *result = nil; NSString *errorCode = nil;
      [self startRoundWithTransport:transport model:model schemaVersion:2 result:&result errorCode:&errorCode];
      XCTAssertNil(errorCode, @"%@ %@", harness, protocol);
      XCTAssertEqualObjects(result[@"text"], @"answer", @"%@ %@", harness, protocol);
      XCTAssertEqualObjects(result[@"model"], model, @"%@ %@", harness, protocol);
      XCTAssertEqualObjects(result[@"provider_configuration"], binding, @"%@ %@", harness, protocol);
      [defaults removePersistentDomainForName:suite];
    }
  }
}

- (void)testDshAndGlmRelayKeysHaveTheirOwnNamespace {
  DSHProviderConfigurationStore *store = DSHProviderConfigurationStore.sharedStore;
  NSDictionary *slots = @{@"dsh": @"DEEPSEEK_API_KEY", @"glm": @"BIGMODEL_API_KEY"};
  NSDictionary *models = @{@"dsh": @"deepseek-v4-flash", @"glm": @"GLM-5.3"};
  for (NSString *harness in slots) {
    NSDictionary *original = [store configurationForHarness:harness];
    @try {
      XCTAssertFalse(DSHHarnessUsesCustomProvider(harness));
      XCTAssertEqualObjects(DSHEffectiveCredentialAccount(slots[harness]), slots[harness]);
      [store saveConfiguration:@{@"schema_version": @1, @"harness_id": harness, @"name": @"Relay",
          @"protocol": @"chat-completions", @"endpoint_url": @"https://relay.example/v1", @"auth_type": @"bearer",
          @"send_reasoning": @NO, @"model_mappings": @{}} error:nil];
      XCTAssertTrue(DSHHarnessUsesCustomProvider(harness));
      NSString *account = DSHEffectiveCredentialAccount(slots[harness]);
      NSString *prefix = [NSString stringWithFormat:@"CUSTOM_PROVIDER_%@_", harness];
      BOOL namespaced = [account hasPrefix:prefix];
      XCTAssertTrue(namespaced, @"%@", account);
      XCTAssertNotNil(DSHProviderBindingForModel(models[harness]));
      [store resetHarness:harness];
      XCTAssertEqualObjects(DSHEffectiveCredentialAccount(slots[harness]), slots[harness]);
      XCTAssertNil(DSHProviderBindingForModel(models[harness]));
    } @finally {
      if ([original[@"official"] boolValue]) [store resetHarness:harness];
      else [store saveConfiguration:original error:nil];
    }
  }
}

// A relay that sends no response id, or one a receipt cannot hold, is
// answered under an id of ours rather than refused after the reply arrived.
- (void)testARelayResponseIdThatCannotBeKeptIsReplaced {
  NSString *longId = [@"" stringByPaddingToLength:200 withString:@"x" startingAtIndex:0];
  for (NSString *protocol in @[@"messages", @"responses", @"chat-completions"]) {
    for (id sent in @[@"<absent>", @"chatcmpl/with spaces", longId, @7, @"kept-id"]) {
      [ClaudeTransportURLProtocol reset];
      NSString *suite = [@"custom-id-" stringByAppendingString:NSUUID.UUID.UUIDString];
      NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
      DSHProviderConfigurationStore *store = [[DSHProviderConfigurationStore alloc] initWithDefaults:defaults];
      [store saveConfiguration:[self customConfiguration:protocol endpoint:@"https://relay.example/v1"] error:nil];
      DSHConfiguredProviderTransport *transport = [[DSHConfiguredProviderTransport alloc]
          initWithHarness:@"claude-code" session:self.session uuidGenerator:nil monotonicClock:nil store:store];
      [ClaudeTransportURLProtocol setHandler:^(NSURLProtocol *p, NSURLRequest *request) {
        NSMutableDictionary *payload = [protocol isEqual:@"messages"]
            ? [@{@"model": @"relay-model", @"content": @[@{@"type": @"text", @"text": @"answer"}], @"stop_reason": @"end_turn"} mutableCopy]
            : ([protocol isEqual:@"responses"]
               ? [@{@"model": @"relay-model", @"status": @"completed", @"output": @[@{@"type": @"message", @"role": @"assistant", @"content": @[@{@"type": @"output_text", @"text": @"answer"}]}]} mutableCopy]
               : [@{@"model": @"relay-model", @"choices": @[@{@"finish_reason": @"stop", @"message": @{@"role": @"assistant", @"content": @"answer"}}]} mutableCopy]);
        if (![sent isEqual:@"<absent>"]) payload[@"id"] = sent;
        [self respond:p request:request data:[self jsonData:payload] status:200];
      }];
      NSDictionary *result = nil; NSString *errorCode = nil;
      [self startRoundWithTransport:transport model:@"claude-sonnet-5" schemaVersion:2 result:&result errorCode:&errorCode];
      XCTAssertNil(errorCode, @"%@ %@", protocol, sent);
      NSString *kept = result[@"provider_response_id"];
      if ([sent isEqual:@"kept-id"]) {
        XCTAssertEqualObjects(kept, @"kept-id", @"%@", protocol);
      } else {
        BOOL replaced = [kept hasPrefix:@"rish-"];
        XCTAssertTrue(replaced, @"%@ %@ -> %@", protocol, sent, kept);
      }
      [defaults removePersistentDomainForName:suite];
    }
  }
}

- (void)testChangingCustomProviderRejectsTheOldInFlightResponse {
  NSString *suite = [@"custom-race-" stringByAppendingString:NSUUID.UUID.UUIDString];
  NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
  DSHProviderConfigurationStore *store = [[DSHProviderConfigurationStore alloc] initWithDefaults:defaults];
  [store saveConfiguration:[self customConfiguration:@"messages" endpoint:@"https://first.example"] error:nil];
  DSHConfiguredProviderTransport *transport = [[DSHConfiguredProviderTransport alloc]
      initWithHarness:@"claude-code" session:self.session uuidGenerator:nil monotonicClock:nil store:store];
  [ClaudeTransportURLProtocol setHandler:^(NSURLProtocol *p, NSURLRequest *request) {
    XCTAssertEqualObjects(request.URL.host, @"first.example");
    [store saveConfiguration:[self customConfiguration:@"messages" endpoint:@"https://second.example"] error:nil];
    [self respond:p request:request data:[self jsonData:@{@"id": @"stale-response", @"model": @"relay-model",
      @"content": @[@{@"type": @"text", @"text": @"must-not-appear"}], @"stop_reason": @"end_turn"}] status:200];
  }];
  NSDictionary *result = nil; NSString *errorCode = nil;
  [self startRoundWithTransport:transport model:@"claude-sonnet-5" schemaVersion:2 result:&result errorCode:&errorCode];
  XCTAssertNil(result);
  XCTAssertEqualObjects(errorCode, @"E_COMPLETION_CREDENTIAL_CHANGED");
  XCTAssertEqual([ClaudeTransportURLProtocol requestCount], 1u);
  [defaults removePersistentDomainForName:suite];
}

- (void)testCustomProviderCredentialNamespacesAreEndpointSpecific {
  DSHProviderConfigurationStore *store = DSHProviderConfigurationStore.sharedStore;
  NSDictionary *original = [store configurationForHarness:@"claude-code"];
  @try {
    [store saveConfiguration:[self customConfiguration:@"messages" endpoint:@"https://one.example"] error:nil];
    NSString *one = DSHEffectiveCredentialAccount(@"ANTHROPIC_API_KEY");
    XCTAssertNotEqualObjects(one, @"ANTHROPIC_API_KEY");
    [store saveConfiguration:[self customConfiguration:@"messages" endpoint:@"https://two.example"] error:nil];
    XCTAssertNotEqualObjects(DSHEffectiveCredentialAccount(@"ANTHROPIC_API_KEY"), one);
    [store resetHarness:@"claude-code"];
    XCTAssertEqualObjects(DSHEffectiveCredentialAccount(@"ANTHROPIC_API_KEY"), @"ANTHROPIC_API_KEY");
  } @finally {
    if ([original[@"official"] boolValue]) [store resetHarness:@"claude-code"];
    else [store saveConfiguration:original error:nil];
  }
}

#pragma mark - Streamed rounds

- (void)respondSSE:(NSURLProtocol *)protocol request:(NSURLRequest *)request chunks:(NSArray<NSString *> *)chunks {
  NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc]
      initWithURL:request.URL statusCode:200 HTTPVersion:@"HTTP/1.1"
     headerFields:@{ @"Content-Type": @"text/event-stream" }];
  [protocol.client URLProtocol:protocol didReceiveResponse:response
            cacheStoragePolicy:NSURLCacheStorageNotAllowed];
  for (NSString *chunk in chunks) {
    [protocol.client URLProtocol:protocol didLoadData:[chunk dataUsingEncoding:NSUTF8StringEncoding]];
  }
  [protocol.client URLProtocolDidFinishLoading:protocol];
}

- (void)startStreamedRoundWithTransport:(DSHCompletionProviderTransport *)transport
                                  model:(NSString *)model
                                preview:(DSHCompletionProviderTransportPreviewBlock)preview
                                 result:(NSDictionary **)result
                              errorCode:(NSString **)errorCode {
  __block NSDictionary *value = nil;
  __block NSString *code = nil;
  XCTestExpectation *done = [self expectationWithDescription:@"streamed round"];
  id<DSHCompletionExecution> execution = [transport
      startStreamingExecutionWithSchemaVersion:2
      roundId:@"33333333-3333-4333-8333-333333333333" generation:1 credentialGeneration:1
      providerRequestId:@"44444444-4444-4444-8444-444444444444"
      credential:@"sk-ant-test" requestedModel:model thinkingMode:@"high"
      credentialGenerationIsCurrent:^BOOL(__unused NSUInteger g) { return YES; }
      startedAt:1.0 bodyData:[self jsonData:@{ @"model": model, @"stream": @YES }]
      visibleHistory:@[] modelInput:@[] preview:preview
      bindExecution:^BOOL(id<DSHCompletionExecution> candidate) { return candidate != nil; }
      claimRound:^BOOL(__unused BOOL *redirected) { return YES; }
      markRedirected:nil redirectDecision:nil
      completion:^(NSDictionary *v, NSString *c) { value = v; code = c; [done fulfill]; }];
  XCTAssertNotNil(execution);
  [self waitForExpectations:@[done] timeout:5];
  if (result != NULL) *result = value;
  if (errorCode != NULL) *errorCode = code;
}

- (NSArray<NSString *> *)streamedToolRoundChunksForModel:(NSString *)model {
  return @[
    [NSString stringWithFormat:@"event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_stream\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"%@\",\"content\":[]}}\n\n", model],
    @"event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}\n\n"
    @"event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"Plan it.\"}}\n\n",
    @"event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n"
    @"event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"Writing.\"}}\n\n",
    @"event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_stream\",\"name\":\"write_file\",\"input\":{}}}\n\n"
    @"event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\": \\\"notes.md\\\",\"}}\n\n",
    @"event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\" \\\"content\\\": \\\"hi\\\"}\"}}\n\n"
    @"event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":2}\n\n",
    @"event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":12}}\n\n"
    @"event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
  ];
}

- (void)testStreamedClaudeRoundAssemblesToolUseAndPreviewsFragments {
  [ClaudeTransportURLProtocol setHandler:^(NSURLProtocol *protocol, NSURLRequest *request) {
    XCTAssertEqualObjects([request valueForHTTPHeaderField:@"Accept"], @"text/event-stream");
    [self respondSSE:protocol request:request chunks:[self streamedToolRoundChunksForModel:@"claude-sonnet-5"]];
  }];
  NSMutableArray<NSDictionary *> *previews = [NSMutableArray array];
  NSDictionary *result = nil;
  NSString *errorCode = nil;
  [self startStreamedRoundWithTransport:self.transport model:@"claude-sonnet-5"
      preview:^(NSDictionary *delta) { @synchronized (previews) { [previews addObject:delta]; } }
      result:&result errorCode:&errorCode];
  XCTAssertNil(errorCode);
  XCTAssertEqualObjects(result[@"provider_response_id"], @"msg_stream");
  XCTAssertEqualObjects(result[@"harness_id"], @"claude-code");
  XCTAssertEqualObjects(result[@"text"], @"Writing.");
  XCTAssertEqualObjects(result[@"reasoning"], @"Plan it.");
  XCTAssertEqualObjects(result[@"finish_reason"], @"tool_calls");
  XCTAssertEqual([result[@"tool_calls"] count], 1u);
  XCTAssertEqualObjects(result[@"tool_calls"][0][@"id"], @"toolu_stream");
  XCTAssertEqualObjects(result[@"tool_calls"][0][@"name"], @"write_file");
  NSDictionary *arguments = [NSJSONSerialization JSONObjectWithData:
      [result[@"tool_calls"][0][@"arguments"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
  // write_file arguments may gain create-only normalization keys; the
  // streamed values themselves must survive untouched.
  XCTAssertEqualObjects(arguments[@"path"], @"notes.md");
  XCTAssertEqualObjects(arguments[@"content"], @"hi");
  NSMutableString *argumentFragments = [NSMutableString string];
  NSString *previewedName = nil;
  @synchronized (previews) {
    for (NSDictionary *delta in previews) {
      for (NSDictionary *fragment in delta[@"tool_calls"] ?: @[]) {
        XCTAssertEqualObjects(fragment[@"index"], @2);
        if (fragment[@"name"]) previewedName = fragment[@"name"];
        if (fragment[@"arguments"]) [argumentFragments appendString:fragment[@"arguments"]];
      }
    }
  }
  XCTAssertEqualObjects(previewedName, @"write_file");
  XCTAssertEqualObjects(argumentFragments, @"{\"path\": \"notes.md\", \"content\": \"hi\"}");
  XCTAssertFalse([self.transport hasActiveRequests]);
}

- (void)testStreamedClaudeRoundCutBeforeMessageDeltaIsRejected {
  [ClaudeTransportURLProtocol setHandler:^(NSURLProtocol *protocol, NSURLRequest *request) {
    [self respondSSE:protocol request:request chunks:@[
      @"event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_cut\",\"model\":\"claude-sonnet-5\"}}\n\n",
      @"event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"half\"}}\n\n",
    ]];
  }];
  NSDictionary *result = nil;
  NSString *errorCode = nil;
  [self startStreamedRoundWithTransport:self.transport model:@"claude-sonnet-5" preview:nil
                                 result:&result errorCode:&errorCode];
  XCTAssertNil(result);
  XCTAssertEqualObjects(errorCode, @"E_COMPLETION_FINISH_RELATION");
}

- (void)testStreamedGlmRoundKeepsTheStrictModelEcho {
  GlmProviderTransport *glm = [[GlmProviderTransport alloc]
      initWithSession:self.session uuidGenerator:nil monotonicClock:nil];
  self.streamingDelegate.transport = glm;
  XCTAssertTrue([glm providerSupportsStreamingRounds]);
  [ClaudeTransportURLProtocol setHandler:^(NSURLProtocol *protocol, NSURLRequest *request) {
    [self respondSSE:protocol request:request chunks:[self streamedToolRoundChunksForModel:@"glm-5.3"]];
  }];
  NSDictionary *result = nil;
  NSString *errorCode = nil;
  [self startStreamedRoundWithTransport:glm model:@"GLM-5.3" preview:nil
                                 result:&result errorCode:&errorCode];
  XCTAssertNil(errorCode);
  XCTAssertEqualObjects(result[@"harness_id"], @"glm");
  XCTAssertEqualObjects(result[@"model"], @"GLM-5.3");
  XCTAssertEqualObjects(result[@"finish_reason"], @"tool_calls");
}

@end
