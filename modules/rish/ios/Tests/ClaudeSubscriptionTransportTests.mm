#import <XCTest/XCTest.h>
#import <CommonCrypto/CommonDigest.h>
#import "../../../../modules/rish/ios/Sources/ClaudeSubscriptionTransport.h"
#import "../../../../modules/rish/ios/Sources/ClaudeOfficialSession.h"

@interface DSHTextSessionStub : DSHClaudeOfficialSession
@property(nonatomic, copy) NSDictionary *testStatus;
@property(nonatomic, copy) NSDictionary *received;
@property(nonatomic, copy) NSString *cancelled;
@property(nonatomic, copy) void (^pending)(NSDictionary *, NSString *);
@end
@implementation DSHTextSessionStub
- (NSDictionary *)status { return self.testStatus ?: @{}; }
- (void)completeTextRequest:(NSDictionary *)request completion:(void (^)(NSDictionary *, NSString *))completion { self.received = request; self.pending = completion; }
- (void)cancelTextRequest:(NSString *)requestId { self.cancelled = requestId; }
@end
@interface ClaudeSubscriptionTransportTests : XCTestCase
@end
@implementation ClaudeSubscriptionTransportTests
- (DSHTextSessionStub *)session {
  DSHTextSessionStub *session = [[DSHTextSessionStub alloc] initWithKernelURL:nil initrdURL:nil storageDirectory:nil version:@"test"];
  session.testStatus = @{@"status":@"signed_in", @"auth_method":@"subscription", @"runtime":@{@"available":@YES}};
  return session;
}
- (void)testReadinessNeverAcceptsCredentialOrSavedHint {
  DSHTextSessionStub *session = [self session];
  DSHClaudeSubscriptionTransport *transport = [[DSHClaudeSubscriptionTransport alloc] initWithOfficialSession:session];
  XCTAssertTrue([transport isReadyWithCredential:nil]);
  XCTAssertFalse(transport.supportsTools);
  XCTAssertEqual(transport.executionTimeoutInterval, 900);
  session.testStatus = @{@"status":@"signed_out", @"auth_method":@"subscription", @"runtime":@{@"available":@YES}};
  XCTAssertFalse([transport isReadyWithCredential:@"irrelevant"]);
}
- (void)testCanonicalBodyUsesActualStdinAndCLIArguments {
  DSHClaudeSubscriptionTransport *transport = [[DSHClaudeSubscriptionTransport alloc] initWithOfficialSession:[self session]];
  NSError *error = nil;
  NSDictionary *body = [transport providerRequestBodyForModel:@"claude-haiku-4-5-20251001" thinkingMode:@"off" messages:@[@{@"role":@"user", @"content":@"hello", @"attachments":@[]}] tools:@[] streaming:NO error:&error];
  XCTAssertNotNil(body);
  XCTAssertNil(error);
  XCTAssertEqualObjects(body[@"arguments"], [DSHClaudeOfficialSession textArgumentsForModel:@"claude-haiku-4-5-20251001"]);
  XCTAssertTrue([body[@"prompt"] hasPrefix:@"Continue the supplied conversation and answer its last user message."]);
  NSString *history = [body[@"prompt"] componentsSeparatedByString:@"Conversation history JSON:\n"].lastObject;
  NSArray *stdinMessages = [NSJSONSerialization JSONObjectWithData:[history dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
  XCTAssertEqualObjects(stdinMessages[0][@"content"], @"hello");
  XCTAssertNil(body[@"messages"]);
}
- (void)testAttachmentsFailBeforeExecution {
  DSHTextSessionStub *session = [self session];
  DSHClaudeSubscriptionTransport *transport = [[DSHClaudeSubscriptionTransport alloc] initWithOfficialSession:session];
  NSError *error = nil;
  NSArray *messages = @[@{@"role":@"user", @"content":@"hello", @"attachments":@[@{}]}];
  NSDictionary *body = [transport providerRequestBodyForModel:@"claude-haiku-4-5-20251001" thinkingMode:@"off" messages:messages tools:@[] streaming:NO error:&error];
  XCTAssertNil(body);
  XCTAssertEqualObjects(error.localizedDescription, @"E_CLAUDE_ATTACHMENTS_UNSUPPORTED");
  XCTAssertNil(session.received);
}
- (void)testCancellationSuppressesLateCompletionAndPreservesGenerationFence {
  DSHTextSessionStub *session = [self session];
  DSHClaudeSubscriptionTransport *transport = [[DSHClaudeSubscriptionTransport alloc] initWithOfficialSession:session];
  NSArray *messages = @[@{@"role":@"user", @"content":@"hello"}];
  NSDictionary *body = [transport providerRequestBodyForModel:@"claude-haiku-4-5-20251001" thinkingMode:@"off" messages:messages tools:@[] streaming:NO error:nil];
  NSData *data = [NSJSONSerialization dataWithJSONObject:body options:NSJSONWritingSortedKeys error:nil];
  __block NSUInteger completed = 0;
  id<DSHCompletionExecution> execution = [transport startExecutionWithSchemaVersion:3
    roundId:@"round" generation:1 credentialGeneration:4 providerRequestId:@"request"
    credential:nil requestedModel:@"claude-haiku-4-5-20251001" thinkingMode:@"off"
    credentialGenerationIsCurrent:^BOOL(NSUInteger value) { return value == 4; }
    startedAt:NSProcessInfo.processInfo.systemUptime bodyData:data visibleHistory:messages modelInput:messages
    bindExecution:^BOOL(id<DSHCompletionExecution> candidate) { return candidate != nil; }
    claimRound:^BOOL(BOOL *redirected) { return YES; } markRedirected:nil redirectDecision:nil
    completion:^(NSDictionary *result, NSString *code) { completed++; }];
  XCTAssertNotNil(execution);
  XCTAssertEqualObjects(session.received[@"prompt"], body[@"prompt"]);
  XCTAssertTrue(transport.hasActiveRequests);
  [execution cancel];
  XCTAssertEqualObjects(session.cancelled, @"request");
  XCTAssertFalse(transport.hasActiveRequests);
  session.pending(nil, @"late");
  XCTAssertEqual(completed, 0u);
}
- (void)testHistoricalToolsRemainQuotedContextAndDigestMatchesActualPrefixedInput {
  DSHTextSessionStub *session = [self session];
  DSHClaudeSubscriptionTransport *transport = [[DSHClaudeSubscriptionTransport alloc] initWithOfficialSession:session];
  NSDictionary *call = @{@"id":@"old-call", @"type":@"function", @"function":@{@"name":@"list_dir", @"arguments":@"{}"}};
  NSArray *messages = @[
    @{@"role":@"assistant", @"content":NSNull.null, @"tool_calls":@[call]},
    @{@"role":@"tool", @"content":@"README.md", @"tool_call_id":@"old-call", @"name":@"list_dir"},
    @{@"role":@"user", @"content":@"What did you find?"}];
  NSError *error = nil;
  NSDictionary *body = [transport providerRequestBodyForModel:@"claude-haiku-4-5-20251001" thinkingMode:@"off" messages:messages tools:@[] streaming:NO error:&error];
  XCTAssertNotNil(body); XCTAssertNil(error);
  NSString *history = [body[@"prompt"] componentsSeparatedByString:@"Conversation history JSON:\n"].lastObject;
  NSArray *quoted = [NSJSONSerialization JSONObjectWithData:[history dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
  XCTAssertEqualObjects(quoted, messages);
  NSData *data = [NSJSONSerialization dataWithJSONObject:body options:NSJSONWritingSortedKeys error:nil];
  unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  NSMutableString *expectedDigest = [NSMutableString string];
  for (NSUInteger i=0; i<sizeof(digest); i++) [expectedDigest appendFormat:@"%02x", digest[i]];
  __block NSDictionary *receipt = nil;
  [transport startExecutionWithSchemaVersion:3 roundId:@"round" generation:1 credentialGeneration:4 providerRequestId:@"request"
    credential:nil requestedModel:@"claude-haiku-4-5-20251001" thinkingMode:@"off"
    credentialGenerationIsCurrent:^BOOL(NSUInteger value) { return value == 4; }
    startedAt:NSProcessInfo.processInfo.systemUptime bodyData:data visibleHistory:messages modelInput:messages
    bindExecution:^BOOL(id<DSHCompletionExecution> candidate) { return candidate != nil; }
    claimRound:^BOOL(BOOL *redirected) { return YES; } markRedirected:nil redirectDecision:nil
    completion:^(NSDictionary *result, NSString *code) { receipt = result; }];
  XCTAssertEqualObjects(session.received[@"prompt"], body[@"prompt"]);
  session.pending(@{@"provider_response_id":@"response", @"model":@"claude-haiku-4-5-20251001", @"text":@"README.md", @"reasoning":NSNull.null, @"tool_calls":@[], @"finish_reason":@"stop"}, nil);
  XCTAssertEqualObjects(receipt[@"request_body_sha256"], expectedDigest);
  XCTAssertEqual([receipt[@"tool_calls"] count], 0u);
}
- (void)testThinkingModeBindsActualCLISettingsAndRejectsUnknownMode {
  DSHClaudeSubscriptionTransport *transport = [[DSHClaudeSubscriptionTransport alloc] initWithOfficialSession:[self session]];
  NSArray *messages = @[@{@"role":@"user", @"content":@"hello"}];
  for (NSString *mode in @[@"off", @"low", @"medium", @"high", @"max"]) {
    NSDictionary *body = [transport providerRequestBodyForModel:@"claude-haiku-4-5-20251001" thinkingMode:mode messages:messages tools:@[] streaming:NO error:nil];
    XCTAssertEqualObjects(body[@"thinking_mode"], mode);
    NSArray *args = body[@"arguments"];
    XCTAssertTrue([args containsObject:@"--settings"]);
    XCTAssertEqual([args containsObject:@"--effort"], ![mode isEqual:@"off"]);
    NSUInteger settings = [args indexOfObject:@"--settings"];
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:[args[settings + 1] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    XCTAssertEqual([json[@"alwaysThinkingEnabled"] boolValue], ![mode isEqual:@"off"]);
  }
  NSError *error = nil;
  XCTAssertNil([transport providerRequestBodyForModel:@"claude-haiku-4-5-20251001" thinkingMode:@"ultra" messages:messages tools:@[] streaming:NO error:&error]);
  XCTAssertEqualObjects(error.localizedDescription, @"E_CLAUDE_THINKING_MODE");
}
- (void)testLocalTimeoutBecomesCanonicalValueFreeCompletionTimeout {
  DSHTextSessionStub *session = [self session];
  DSHClaudeSubscriptionTransport *transport = [[DSHClaudeSubscriptionTransport alloc] initWithOfficialSession:session];
  NSArray *messages = @[@{@"role":@"user", @"content":@"private prompt"}];
  NSDictionary *body = [transport providerRequestBodyForModel:@"claude-haiku-4-5-20251001" thinkingMode:@"off" messages:messages tools:@[] streaming:NO error:nil];
  NSData *data = [NSJSONSerialization dataWithJSONObject:body options:NSJSONWritingSortedKeys error:nil];
  __block NSString *receivedCode = nil;
  __block NSDictionary *receivedResult = nil;
  [transport startExecutionWithSchemaVersion:3 roundId:@"round" generation:1 credentialGeneration:4 providerRequestId:@"request"
    credential:nil requestedModel:@"claude-haiku-4-5-20251001" thinkingMode:@"off"
    credentialGenerationIsCurrent:^BOOL(NSUInteger value) { return value == 4; }
    startedAt:NSProcessInfo.processInfo.systemUptime bodyData:data visibleHistory:messages modelInput:messages
    bindExecution:^BOOL(id<DSHCompletionExecution> candidate) { return candidate != nil; }
    claimRound:^BOOL(BOOL *redirected) { return YES; } markRedirected:nil redirectDecision:nil
    completion:^(NSDictionary *result, NSString *code) { receivedResult = result; receivedCode = code; }];
  session.pending(nil, @"E_CLAUDE_OFFICIAL_TEXT_TIMEOUT");
  XCTAssertNil(receivedResult);
  XCTAssertEqualObjects(receivedCode, @"E_COMPLETION_TIMEOUT");
  XCTAssertFalse(transport.hasActiveRequests);
}
@end
