#import "DSHTestProviderModelsFixture.h"
#import <XCTest/XCTest.h>
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>

#include <sys/stat.h>

// The host application keeps its symbol table for simulator builds, so the
// completionV2 helpers resolve from the linked pod like every other native
// symbol.
#import "../../../../modules/rish/ios/Sources/DSHCompletionV2.h"
#import "../../../../modules/rish/ios/Sources/ModelTransitionProof.h"

@interface CompletionV2Tests : XCTestCase
@end

// Production-private test seam: it still runs a real NSURLSession and a real
// NSURLProtocol, but makes UUIDs, the monotonic clock, and the credential
// deterministic without touching Keychain.
@interface LocalRuntimeModule : NSObject
- (instancetype)initForCompletionV2TestingWithConfiguration:
    (NSURLSessionConfiguration *)configuration
    credential:(NSString *)credential
    uuidGenerator:(NSString *(^)(void))uuidGenerator
    monotonicClock:(NSTimeInterval (^)(void))monotonicClock;
- (void)completeV2EnvelopeJSON:(NSString *)envelopeJSON
                      resolver:(void (^)(id result))resolve
                      rejecter:(void (^)(NSString *code, NSString *message,
                                         NSError *error))reject;
- (void)completeModel:(NSString *)model
              history:(NSArray *)history
            requestId:(NSString *)requestId
         thinkingMode:(NSString *)thinkingMode
             resolver:(void (^)(id result))resolve
             rejecter:(void (^)(NSString *code, NSString *message,
                                NSError *error))reject;
- (void)cancelCompletionRequestId:(NSString *)requestId
                         resolver:(void (^)(id result))resolve
                         rejecter:(void (^)(NSString *code, NSString *message,
                                            NSError *error))reject;
- (NSURL *)resolvedSandboxRootURLForWorkspace:(NSURL *)workspace
                                         error:(NSError **)error;
@end

@interface DSHTestLocalRuntimeModule : LocalRuntimeModule
@end

@implementation DSHTestLocalRuntimeModule

- (NSURL *)applicationSupportURL:(NSError **)error {
  NSURL *root = [[NSURL fileURLWithPath:NSTemporaryDirectory()
                            isDirectory:YES]
      URLByAppendingPathComponent:@"rish-completion-v2-tests"
                       isDirectory:YES];
  if (![[NSFileManager defaultManager] createDirectoryAtURL:root
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:error]) {
    return nil;
  }
  return root;
}

- (OSStatus)credentialLookupStatus {
  return errSecItemNotFound;
}

@end

typedef void (^DSHProtocolHandler)(NSURLProtocol *protocol,
                                   NSURLRequest *request);

@interface DSHCompletionURLProtocol : NSURLProtocol
+ (void)setHandler:(DSHProtocolHandler)handler;
+ (void)reset;
+ (NSUInteger)unexpectedHostHits;
@end

@implementation DSHCompletionURLProtocol

static DSHProtocolHandler DSHCompletionURLProtocolHandler = nil;
static NSUInteger DSHCompletionUnexpectedHostHits = 0;

+ (void)setHandler:(DSHProtocolHandler)handler {
  @synchronized (self) {
    DSHCompletionURLProtocolHandler = [handler copy];
  }
}

+ (void)reset {
  @synchronized (self) {
    DSHCompletionURLProtocolHandler = nil;
    DSHCompletionUnexpectedHostHits = 0;
  }
}

+ (NSUInteger)unexpectedHostHits {
  @synchronized (self) {
    return DSHCompletionUnexpectedHostHits;
  }
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
  NSString *scheme = request.URL.scheme.lowercaseString;
  return [scheme isEqualToString:@"http"] ||
      [scheme isEqualToString:@"https"];
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
  return request;
}

- (void)startLoading {
  if (![self.request.URL.host isEqualToString:@"api.deepseek.com"]) {
    @synchronized (self.class) {
      DSHCompletionUnexpectedHostHits += 1;
    }
    NSError *error = [NSError errorWithDomain:@"DSHCompletionTestNetworkBlocked"
        code:1 userInfo:@{NSLocalizedDescriptionKey:
            @"Unexpected test network destination was blocked"}];
    [self.client URLProtocol:self didFailWithError:error];
    return;
  }
  DSHProtocolHandler handler = nil;
  @synchronized (self.class) {
    handler = [DSHCompletionURLProtocolHandler copy];
  }
  if (handler != nil) {
    handler(self, self.request);
  } else {
    NSError *error = [NSError errorWithDomain:@"DSHCompletionTestNetworkBlocked"
        code:2 userInfo:@{NSLocalizedDescriptionKey:
            @"Unconfigured test network request was blocked"}];
    [self.client URLProtocol:self didFailWithError:error];
  }
}

- (void)stopLoading {}

@end

@implementation CompletionV2Tests

- (void)setUp {
  [super setUp];
  XCTAssertTrue(DSHInstallTestProviderModels(self, @{@"dsh":@[@"deepseek-v4-flash", @"deepseek-v4-pro"]},
      [NSSet setWithObject:@"deepseek-v4-flash"]));
}

static NSString *DSHTestSHA256(NSData *data) {
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  NSMutableString *hex =
      [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
  for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index += 1) {
    [hex appendFormat:@"%02x", digest[index]];
  }
  return hex;
}

static NSData *DSHTestRequestBody(NSURLRequest *request) {
  if (request.HTTPBody != nil) return request.HTTPBody;
  NSInputStream *stream = request.HTTPBodyStream;
  if (stream == nil) return nil;
  NSMutableData *data = [NSMutableData data];
  [stream open];
  uint8_t buffer[4096];
  while (stream.hasBytesAvailable) {
    NSInteger count = [stream read:buffer maxLength:sizeof(buffer)];
    if (count < 0) {
      [stream close];
      return nil;
    }
    if (count == 0) break;
    [data appendBytes:buffer length:(NSUInteger)count];
  }
  [stream close];
  return data;
}

- (void)tearDown {
  [DSHCompletionURLProtocol reset];
  [super tearDown];
}

- (void)testSandboxRootResolutionReturnsPhysicalDirectoryForSymlinkAlias {
  NSFileManager *manager = NSFileManager.defaultManager;
  NSURL *root = [manager.temporaryDirectory
      URLByAppendingPathComponent:NSUUID.UUID.UUIDString
                      isDirectory:YES];
  NSURL *target = [root URLByAppendingPathComponent:@"physical" isDirectory:YES];
  NSURL *alias = [root URLByAppendingPathComponent:@"alias" isDirectory:YES];
  NSError *error = nil;
  XCTAssertTrue([manager createDirectoryAtURL:target
                  withIntermediateDirectories:YES
                                   attributes:nil
                                        error:&error]);
  XCTAssertNil(error);
  XCTAssertTrue([manager createSymbolicLinkAtPath:alias.path
                              withDestinationPath:target.path
                                             error:&error]);
  XCTAssertNil(error);

  LocalRuntimeModule *module = [DSHTestLocalRuntimeModule new];
  NSURL *resolved = [module resolvedSandboxRootURLForWorkspace:alias
                                                          error:&error];
  XCTAssertNotNil(resolved);
  XCTAssertNil(error);
  struct stat targetStat = {};
  struct stat resolvedStat = {};
  struct stat linkStat = {};
  XCTAssertEqual(stat(target.fileSystemRepresentation, &targetStat), 0);
  XCTAssertEqual(stat(resolved.fileSystemRepresentation, &resolvedStat), 0);
  XCTAssertEqual(lstat(resolved.fileSystemRepresentation, &linkStat), 0);
  XCTAssertEqual(targetStat.st_dev, resolvedStat.st_dev);
  XCTAssertEqual(targetStat.st_ino, resolvedStat.st_ino);
  XCTAssertFalse(S_ISLNK(linkStat.st_mode));
  [manager removeItemAtURL:root error:nil];
}

- (void)testSandboxRootResolutionFailsClosedForMissingPath {
  NSURL *missing = [NSFileManager.defaultManager.temporaryDirectory
      URLByAppendingPathComponent:NSUUID.UUID.UUIDString
                      isDirectory:YES];
  NSError *error = nil;
  LocalRuntimeModule *module = [DSHTestLocalRuntimeModule new];
  XCTAssertNil([module resolvedSandboxRootURLForWorkspace:missing error:&error]);
  XCTAssertEqualObjects(error.domain, @"LocalRuntime");
  XCTAssertEqual(error.code, 1001);
}

- (void)testSandboxRootResolutionPreservesUnicodeFilesystemIdentity {
  NSFileManager *manager = NSFileManager.defaultManager;
  NSURL *root = [manager.temporaryDirectory
      URLByAppendingPathComponent:NSUUID.UUID.UUIDString
                      isDirectory:YES];
  NSURL *workspace = [root URLByAppendingPathComponent:@"测试-é-🚀"
                                           isDirectory:YES];
  NSError *error = nil;
  XCTAssertTrue([manager createDirectoryAtURL:workspace
                  withIntermediateDirectories:YES
                                   attributes:nil
                                        error:&error]);
  XCTAssertNil(error);
  LocalRuntimeModule *module = [DSHTestLocalRuntimeModule new];
  NSURL *resolved = [module resolvedSandboxRootURLForWorkspace:workspace
                                                          error:&error];
  XCTAssertNotNil(resolved);
  XCTAssertNil(error);
  struct stat workspaceStat = {};
  struct stat resolvedStat = {};
  XCTAssertEqual(stat(workspace.fileSystemRepresentation, &workspaceStat), 0);
  XCTAssertEqual(stat(resolved.fileSystemRepresentation, &resolvedStat), 0);
  XCTAssertEqual(workspaceStat.st_dev, resolvedStat.st_dev);
  XCTAssertEqual(workspaceStat.st_ino, resolvedStat.st_ino);
  [manager removeItemAtURL:root error:nil];
}

- (NSDictionary *)validSchema2Tool {
  return @{
    @"type": @"function",
    @"function": @{
      @"name": @"read_file",
      @"description": @"Read a bounded file",
      @"parameters": @{
        @"type": @"object",
        @"properties": @{
          @"path": @{@"type": @"string"},
        },
      },
    },
  };
}

- (NSDictionary *)validSchema2Envelope {
  return @{
    @"schema_version": @2,
    @"turn_id": @"11111111-1111-4111-8111-111111111111",
    @"attempt_id": @"22222222-2222-4222-8222-222222222222",
    @"round_id": @"33333333-3333-4333-8333-333333333333",
    @"round_index": @0,
    @"model": @"deepseek-v4-flash",
    @"thinking_mode": @"high",
    @"visible_history": @[
      @{@"role": @"user", @"content": @"request-sentinel",
        @"attachments": @[]},
    ],
    @"round_transcript": @[],
    @"tools": @[[self validSchema2Tool]],
    @"project_context": NSNull.null,
  };
}

- (NSDictionary *)validTranscriptAssistant {
  return @{
    @"role": @"assistant",
    @"content": @"",
    @"reasoning_content": @"reasoning-sentinel",
    @"tool_calls": @[
      @{
        @"id": @"call_1",
        @"type": @"function",
        @"function": @{
          @"name": @"read_file",
          @"arguments": @"{\"path\":\"README.md\"}",
        },
      },
    ],
  };
}

- (NSDictionary *)validTranscriptTool {
  return @{
    @"role": @"tool",
    @"tool_call_id": @"call_1",
    @"content": @"tool-result-sentinel",
  };
}

- (NSString *)jsonString:(id)object {
  NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0
                                                   error:nil];
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

- (NSDictionary *)providerSuccessWithFinish:(NSString *)finish
                                        text:(NSString *)text
                                   reasoning:(NSString *)reasoning
                                   toolCalls:(NSArray *)toolCalls {
  NSMutableDictionary *message = [@{
    @"role": @"assistant",
    @"content": text,
  } mutableCopy];
  if (reasoning != nil) message[@"reasoning_content"] = reasoning;
  if (toolCalls != nil) message[@"tool_calls"] = toolCalls;
  return @{
    @"id": @"resp_123",
    @"model": @"deepseek-v4-flash",
    @"choices": @[
      @{@"finish_reason": finish, @"message": message},
    ],
  };
}

- (void)respondFromProtocol:(NSURLProtocol *)protocol
                    request:(NSURLRequest *)request
                       json:(NSDictionary *)json
                     status:(NSInteger)status {
  NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc]
      initWithURL:request.URL
       statusCode:status
      HTTPVersion:@"HTTP/1.1"
     headerFields:@{@"Content-Type": @"application/json"}];
  NSData *data = [NSJSONSerialization dataWithJSONObject:json options:0
                                                   error:nil];
  [protocol.client URLProtocol:protocol
            didReceiveResponse:response
            cacheStoragePolicy:NSURLCacheStorageNotAllowed];
  [protocol.client URLProtocol:protocol didLoadData:data];
  [protocol.client URLProtocolDidFinishLoading:protocol];
}

- (LocalRuntimeModule *)testModuleWithUUIDs:(NSArray<NSString *> *)uuids
                                       times:(NSArray<NSNumber *> *)times {
  NSURLSessionConfiguration *configuration =
      NSURLSessionConfiguration.ephemeralSessionConfiguration;
  configuration.protocolClasses = @[DSHCompletionURLProtocol.class];
  __block NSUInteger uuidIndex = 0;
  __block NSUInteger timeIndex = 0;
  return [[DSHTestLocalRuntimeModule alloc]
      initForCompletionV2TestingWithConfiguration:configuration
      credential:@"test-credential-not-a-secret"
      uuidGenerator:^NSString *{
        NSUInteger index = MIN(uuidIndex, uuids.count - 1);
        uuidIndex += 1;
        return uuids[index];
      }
      monotonicClock:^NSTimeInterval {
        NSUInteger index = MIN(timeIndex, times.count - 1);
        timeIndex += 1;
        return times[index].doubleValue;
      }];
}

#pragma mark - Strict schema 2 envelope and transcript RED

- (void)testSchema2BaselineRoutesPastLegacySchemaOneGate {
  NSURLSessionConfiguration *configuration =
      NSURLSessionConfiguration.ephemeralSessionConfiguration;
  configuration.protocolClasses = @[DSHCompletionURLProtocol.class];
  LocalRuntimeModule *module = [[DSHTestLocalRuntimeModule alloc]
      initForCompletionV2TestingWithConfiguration:configuration
      credential:@""
      uuidGenerator:^NSString *{
        return @"44444444-4444-4444-8444-444444444444";
      }
      monotonicClock:^NSTimeInterval { return 10.0; }];
  __block NSString *rejectionCode = nil;
  [module completeV2EnvelopeJSON:[self jsonString:[self validSchema2Envelope]]
      resolver:^(__unused id value) { XCTFail(@"credential is intentionally absent"); }
      rejecter:^(NSString *code, __unused NSString *message,
                 __unused NSError *error) {
        rejectionCode = code;
      }];
  XCTAssertEqualObjects(rejectionCode,
                        @"E_COMPLETION_CREDENTIAL_UNAVAILABLE");
}

- (void)testCompleteV2RawEnvelopeFailsClosedForNilEmptyAndOversizeInputs {
  LocalRuntimeModule *module = [self testModuleWithUUIDs:@[
    @"44444444-4444-4444-8444-444444444444",
  ] times:@[@10.0]];
  NSString *(^invoke)(id) = ^NSString *(id raw) {
    __block NSString *code = nil;
    @try {
      [module completeV2EnvelopeJSON:(NSString *)raw
          resolver:^(__unused id value) { XCTFail(@"must not resolve"); }
          rejecter:^(NSString *value, __unused NSString *message,
                     __unused NSError *error) { code = value; }];
    } @catch (NSException *exception) {
      XCTFail(@"must fail closed, not throw: %@", exception.name);
    }
    return code;
  };
  XCTAssertEqualObjects(invoke(nil), @"E_COMPLETION_SCHEMA");
  XCTAssertEqualObjects(invoke(NSNull.null), @"E_COMPLETION_SCHEMA");
  XCTAssertEqualObjects(invoke(@""), @"E_COMPLETION_SCHEMA");

  @autoreleasepool {
    NSUInteger cap = 40 * 1024 * 1024;
    NSString *atCap = [@"" stringByPaddingToLength:cap
                                          withString:@" "
                                     startingAtIndex:0];
    XCTAssertEqualObjects(invoke(atCap), @"E_COMPLETION_SCHEMA");
    NSString *overCap = [atCap stringByAppendingString:@" "];
    XCTAssertEqualObjects(invoke(overCap),
                          @"E_COMPLETION_BODY_TOO_LARGE");
  }
}

- (void)testURLProtocolClaimsEveryHTTPFamilyRequest {
  NSURLRequest *expected = [NSURLRequest requestWithURL:
      [NSURL URLWithString:@"https://api.deepseek.com/chat/completions"]];
  NSURLRequest *unexpectedHTTPS = [NSURLRequest requestWithURL:
      [NSURL URLWithString:@"https://unexpected.invalid/path"]];
  NSURLRequest *unexpectedHTTP = [NSURLRequest requestWithURL:
      [NSURL URLWithString:@"http://unexpected.invalid/path"]];
  XCTAssertTrue([DSHCompletionURLProtocol canInitWithRequest:expected]);
  XCTAssertTrue([DSHCompletionURLProtocol canInitWithRequest:unexpectedHTTPS]);
  XCTAssertTrue([DSHCompletionURLProtocol canInitWithRequest:unexpectedHTTP]);

  [DSHCompletionURLProtocol reset];
  NSURLSessionConfiguration *configuration =
      NSURLSessionConfiguration.ephemeralSessionConfiguration;
  configuration.protocolClasses = @[DSHCompletionURLProtocol.class];
  NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
  XCTestExpectation *blocked = [self expectationWithDescription:@"blocked"];
  NSURLSessionDataTask *task = [session dataTaskWithRequest:unexpectedHTTPS
      completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    XCTAssertNil(data);
    XCTAssertNil(response);
    XCTAssertEqualObjects(error.domain, @"DSHCompletionTestNetworkBlocked");
    [blocked fulfill];
  }];
  [task resume];
  [self waitForExpectations:@[blocked] timeout:3];
  [session finishTasksAndInvalidate];
}

- (void)testSchema2RequiresExactRootAndNullProjectContext {
  NSError *error = nil;
  NSDictionary *valid = DSHCompletionEnvelopeSchema2FromDictionary(
      [self validSchema2Envelope], &error);
  XCTAssertNotNil(valid);
  XCTAssertNil(error);
  NSSet *expectedRootKeys = [NSSet setWithArray:@[
    @"schema_version", @"harness_id", @"turn_id", @"attempt_id", @"round_id",
    @"round_index", @"model", @"thinking_mode", @"visible_history",
    @"round_transcript", @"tools", @"project_context",
  ]];
  XCTAssertEqualObjects([NSSet setWithArray:valid.allKeys],
                        expectedRootKeys);

  NSMutableDictionary *extra = [[self validSchema2Envelope] mutableCopy];
  extra[@"request-sentinel"] = @"must-not-cross";
  error = nil;
  XCTAssertNil(DSHCompletionEnvelopeSchema2FromDictionary(extra, &error));
  XCTAssertEqualObjects(error.localizedDescription, @"E_COMPLETION_SCHEMA");
  XCTAssertFalse([error.description containsString:@"must-not-cross"]);

  NSMutableDictionary *context = [[self validSchema2Envelope] mutableCopy];
  context[@"project_context"] = @{@"raw": @"project-sentinel"};
  error = nil;
  XCTAssertNil(DSHCompletionEnvelopeSchema2FromDictionary(context, &error));
  XCTAssertEqualObjects(error.localizedDescription,
                        @"E_COMPLETION_CONTEXT_UNSUPPORTED");

  NSMutableDictionary *missingAttachments =
      [[self validSchema2Envelope] mutableCopy];
  missingAttachments[@"visible_history"] =
      @[@{@"role": @"user", @"content": @"hello"}];
  error = nil;
  XCTAssertNil(DSHCompletionEnvelopeSchema2FromDictionary(
      missingAttachments, &error));
  XCTAssertEqualObjects(error.localizedDescription, @"E_COMPLETION_HISTORY");
}

- (void)testSchema2RejectsFloatNegativeZeroAndHighPrecisionNumbers {
  NSArray *invalidRoundIndices = @[
    @1.0,
    @(-0.0),
    [NSDecimalNumber decimalNumberWithString:@"1.00000000000000000001"],
  ];
  for (NSNumber *number in invalidRoundIndices) {
    NSMutableDictionary *envelope = [[self validSchema2Envelope] mutableCopy];
    envelope[@"round_index"] = number;
    NSError *error = nil;
    XCTAssertNil(DSHCompletionEnvelopeSchema2FromDictionary(envelope, &error));
    XCTAssertEqualObjects(error.localizedDescription, @"E_COMPLETION_ROUND");
  }

  NSMutableDictionary *floatSchema = [[self validSchema2Envelope] mutableCopy];
  floatSchema[@"schema_version"] = @2.0;
  NSError *error = nil;
  XCTAssertNil(DSHCompletionEnvelopeSchema2FromDictionary(floatSchema, &error));
  XCTAssertEqualObjects(error.localizedDescription, @"E_COMPLETION_SCHEMA");

  NSMutableDictionary *floatAttachment = [[self validSchema2Envelope] mutableCopy];
  floatAttachment[@"visible_history"] = @[@{
    @"role": @"user",
    @"content": @"x",
    @"attachments": @[@{
      @"schema_version": @1,
      @"id": @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      @"kind": @"text",
      @"name": @"a.txt",
      @"mime_type": @"text/plain",
      @"size": @1.0,
    }],
  }];
  error = nil;
  XCTAssertNil(DSHCompletionEnvelopeSchema2FromDictionary(
      floatAttachment, &error));
  XCTAssertEqualObjects(error.localizedDescription, @"E_COMPLETION_HISTORY");
}

- (void)testRoundZeroRequiresEmptyTranscriptAndRoundIndexMatchesGroups {
  NSError *error = nil;
  XCTAssertNotNil(DSHCompletionRoundTranscriptSchema2FromArray(
      @[], 0, @"high", &error));
  XCTAssertNil(error);

  error = nil;
  XCTAssertNil(DSHCompletionRoundTranscriptSchema2FromArray(
      @[[self validTranscriptAssistant], [self validTranscriptTool]],
      0, @"high", &error));
  XCTAssertEqualObjects(error.localizedDescription, @"E_COMPLETION_TRANSCRIPT");

  error = nil;
  XCTAssertNil(DSHCompletionRoundTranscriptSchema2FromArray(
      @[], 1, @"high", &error));
  XCTAssertEqualObjects(error.localizedDescription, @"E_COMPLETION_TRANSCRIPT");
}

- (void)testValidTranscriptProjectsAssistantReasoningAndOrderedToolMessagesExactly {
  NSArray *source = @[[self validTranscriptAssistant], [self validTranscriptTool]];
  NSError *error = nil;
  NSArray *validated = DSHCompletionRoundTranscriptSchema2FromArray(
      source, 1, @"high", &error);
  XCTAssertNil(error);
  XCTAssertEqualObjects(validated, source);
  XCTAssertEqualObjects(validated[0][@"reasoning_content"],
                        @"reasoning-sentinel");
  XCTAssertEqualObjects(validated[1][@"content"], @"tool-result-sentinel");
}

- (void)testTranscriptRejectsOrphanDuplicateMismatchedAndForbiddenRoles {
  NSArray *badTranscripts = @[
    @[[self validTranscriptTool]],
    @[[self validTranscriptAssistant],
      @{@"role": @"tool", @"tool_call_id": @"wrong",
        @"content": @"x"}],
    @[[self validTranscriptAssistant], [self validTranscriptTool],
      [self validTranscriptAssistant], [self validTranscriptTool]],
    @[@{@"role": @"user", @"content": @"forbidden",
        @"attachments": @[]}],
  ];
  for (NSUInteger index = 0; index < badTranscripts.count; index += 1) {
    NSInteger rounds = index == 2 ? 2 : 1;
    NSError *error = nil;
    XCTAssertNil(DSHCompletionRoundTranscriptSchema2FromArray(
        badTranscripts[index], rounds, @"high", &error), @"%lu",
        (unsigned long)index);
    XCTAssertEqualObjects(error.localizedDescription,
                          @"E_COMPLETION_TRANSCRIPT");
  }
}

- (void)testSchema2ToolsRequireExactProviderNativeShape {
  NSError *error = nil;
  NSArray *valid = DSHCompletionProviderToolsSchema2FromArray(
      @[[self validSchema2Tool]], &error);
  XCTAssertNotNil(valid);
  XCTAssertNil(error);
  XCTAssertEqualObjects(valid, @[[self validSchema2Tool]]);

  NSMutableDictionary *outerExtra = [[self validSchema2Tool] mutableCopy];
  outerExtra[@"extra"] = @"sentinel";
  NSMutableDictionary *innerExtra = [[self validSchema2Tool] mutableCopy];
  NSMutableDictionary *inner = [innerExtra[@"function"] mutableCopy];
  inner[@"extra"] = @YES;
  innerExtra[@"function"] = inner;
  NSMutableDictionary *missingDescription = [[self validSchema2Tool] mutableCopy];
  inner = [missingDescription[@"function"] mutableCopy];
  [inner removeObjectForKey:@"description"];
  missingDescription[@"function"] = inner;
  for (NSDictionary *tool in @[outerExtra, innerExtra, missingDescription]) {
    error = nil;
    XCTAssertNil(DSHCompletionProviderToolsSchema2FromArray(@[tool], &error));
    XCTAssertEqualObjects(error.localizedDescription, @"E_COMPLETION_TOOLS");
  }
}

- (void)testSchema2ToolParametersEnforceDepthAndNodeBudgetsBeforeSerialization {
  id depth64 = @{};
  for (NSUInteger index = 0; index < 64; index += 1) {
    depth64 = @{@"x": depth64};
  }
  NSMutableDictionary *atDepth = [[self validSchema2Tool] mutableCopy];
  NSMutableDictionary *function = [atDepth[@"function"] mutableCopy];
  function[@"parameters"] = depth64;
  atDepth[@"function"] = function;
  NSError *error = nil;
  XCTAssertNotNil(DSHCompletionProviderToolsSchema2FromArray(@[atDepth], &error));
  XCTAssertNil(error);

  NSMutableDictionary *depth65 = [@{@"x": depth64} mutableCopy];
  NSMutableDictionary *tooDeep = [[self validSchema2Tool] mutableCopy];
  function = [tooDeep[@"function"] mutableCopy];
  function[@"parameters"] = depth65;
  tooDeep[@"function"] = function;
  error = nil;
  XCTAssertNil(DSHCompletionProviderToolsSchema2FromArray(@[tooDeep], &error));
  XCTAssertEqualObjects(error.localizedDescription, @"E_COMPLETION_TOOLS");

  NSMutableArray *acceptedNodes = [NSMutableArray arrayWithCapacity:1022];
  for (NSUInteger index = 0; index < 1022; index += 1) {
    [acceptedNodes addObject:NSNull.null];
  }
  NSMutableDictionary *atNodes = [[self validSchema2Tool] mutableCopy];
  function = [atNodes[@"function"] mutableCopy];
  function[@"parameters"] = @{@"x": acceptedNodes};
  atNodes[@"function"] = function;
  error = nil;
  XCTAssertNotNil(DSHCompletionProviderToolsSchema2FromArray(@[atNodes], &error));
  XCTAssertNil(error);

  NSMutableArray *rejectedNodes = [acceptedNodes mutableCopy];
  [rejectedNodes addObject:NSNull.null];
  NSMutableDictionary *tooManyNodes = [[self validSchema2Tool] mutableCopy];
  function = [tooManyNodes[@"function"] mutableCopy];
  function[@"parameters"] = @{@"x": rejectedNodes};
  tooManyNodes[@"function"] = function;
  error = nil;
  XCTAssertNil(DSHCompletionProviderToolsSchema2FromArray(
      @[tooManyNodes], &error));
  XCTAssertEqualObjects(error.localizedDescription, @"E_COMPLETION_TOOLS");
}

#pragma mark - Strict schema 2 response RED

- (void)testToolRequestsReserveEnoughOutputForFileContents {
  NSArray *messages = @[@{@"role":@"user", @"content":@"Create a mobile HTML page."}];
  NSArray *tools = @[[self validSchema2Tool]];
  NSDictionary *off = DSHCompletionRequestBodyV2(@"deepseek-v4-flash", @"off", messages, tools);
  NSDictionary *high = DSHCompletionRequestBodyV2(@"deepseek-v4-flash", @"high", messages, tools);
  XCTAssertEqualObjects(off[@"max_tokens"], @8192);
  XCTAssertEqualObjects(off[@"thinking"], (@{@"type":@"disabled"}));
  XCTAssertEqualObjects(high[@"max_tokens"], @16384);
  XCTAssertEqualObjects(high[@"reasoning_effort"], @"high");
}

- (void)testLengthLimitedToolArgumentsReportOutputLimitWithoutExecution {
  NSArray *calls = @[@{@"id":@"call-partial", @"type":@"function",
    @"function":@{@"name":@"write_file", @"arguments":@"{\"path\":\"index.html\",\"content\":\"<!doctype html>"}}];
  for (id content in @[@"", NSNull.null]) {
    NSDictionary *payload = @{@"id":@"response-length", @"model":@"deepseek-v4-flash",
      @"choices":@[@{@"finish_reason":@"length", @"message":@{@"role":@"assistant", @"content":content, @"tool_calls":calls}}]};
    NSError *error = nil;
    XCTAssertNil(DSHParseCompletionResponseSchema2(payload, @"deepseek-v4-flash", @"off", &error));
    XCTAssertEqualObjects(error.localizedDescription, @"E_COMPLETION_LENGTH");
  }
}

- (void)testFinishReasonAndToolCallsAreBidirectionallyRelated {
  NSArray *toolCalls = @[@{
    @"id": @"call_1", @"type": @"function",
    @"function": @{@"name": @"read_file", @"arguments": @"{}"},
  }];
  NSArray *invalid = @[
    [self providerSuccessWithFinish:@"tool_calls" text:@"" reasoning:@"r"
                          toolCalls:@[]],
    [self providerSuccessWithFinish:@"stop" text:@"done" reasoning:@""
                          toolCalls:toolCalls],
    [self providerSuccessWithFinish:@"length" text:@"" reasoning:@""
                          toolCalls:nil],
  ];
  for (NSDictionary *payload in invalid) {
    NSError *error = nil;
    XCTAssertNil(DSHParseCompletionResponseSchema2(
        payload, @"deepseek-v4-flash", @"high", &error));
    XCTAssertEqualObjects(error.localizedDescription,
                          @"E_COMPLETION_FINISH_RELATION");
  }

  NSError *error = nil;
  NSDictionary *filtered = DSHParseCompletionResponseSchema2(
      [self providerSuccessWithFinish:@"content_filter" text:@""
                             reasoning:@"" toolCalls:nil],
      @"deepseek-v4-flash", @"high", &error);
  XCTAssertNotNil(filtered);
  XCTAssertNil(error);
}

- (void)testContentEncodedFunctionCallIsStrictlyProjectedAsToolCall {
  NSString *encoded = @"{\"type\":\"function_call\",\"function\":\"write_file\",\"parameters\":{\"path\":\"proof.md\",\"content\":\"proof\"}}";
  NSError *error = nil;
  NSDictionary *parsed = DSHParseCompletionResponseSchema2(
      [self providerSuccessWithFinish:@"tool_calls" text:encoded reasoning:nil
                            toolCalls:nil],
      @"deepseek-v4-flash", @"high", &error);
  XCTAssertNotNil(parsed, @"%@", error);
  XCTAssertNil(error);
  XCTAssertEqualObjects(parsed[@"finish_reason"], @"tool_calls");
  XCTAssertEqualObjects(parsed[@"text"], @"");
  NSArray *expectedCalls = @[@{
    @"id" : @"compat:resp_123",
    @"name" : @"write_file",
    @"arguments" : @"{\"content\":\"proof\",\"expected_revision\":null,\"path\":\"proof.md\"}",
  }];
  XCTAssertEqualObjects(parsed[@"tool_calls"], expectedCalls);

  NSString *shortEncoded = @"{\"name\":\"write_file\",\"arguments\":{\"path\":\"proof.md\",\"content\":\"proof\"}}";
  parsed = DSHParseCompletionResponseSchema2(
      [self providerSuccessWithFinish:@"stop" text:shortEncoded reasoning:nil
                            toolCalls:nil],
      @"deepseek-v4-flash", @"high", &error);
  XCTAssertEqualObjects(parsed[@"finish_reason"], @"tool_calls");
  XCTAssertEqualObjects(parsed[@"tool_calls"], expectedCalls);

  NSArray *nativeCalls = @[@{
    @"id" : @"native-call", @"type" : @"function", @"index" : @0,
    @"function" : @{
      @"name" : @"write_file",
      @"arguments" : @"{\"path\":\"proof.md\",\"content\":\"proof\"}",
    },
  }];
  parsed = DSHParseCompletionResponseSchema2(
      [self providerSuccessWithFinish:@"tool_calls" text:@"" reasoning:@"r"
                            toolCalls:nativeCalls],
      @"deepseek-v4-flash", @"high", &error);
  XCTAssertEqualObjects(parsed[@"tool_calls"][0][@"arguments"],
      @"{\"content\":\"proof\",\"expected_revision\":null,\"path\":\"proof.md\"}");
  XCTAssertFalse([[(NSDictionary *)parsed[@"tool_calls"][0] allKeys]
      containsObject:@"index"]);

  for (NSDictionary *invalidCall in @[
    @{
      @"id" : @"wrong-index", @"type" : @"function", @"index" : @1,
      @"function" : @{
        @"name" : @"write_file", @"arguments" : @"{}",
      },
    },
    @{
      @"id" : @"fractional-index", @"type" : @"function", @"index" : @0.5,
      @"function" : @{
        @"name" : @"write_file", @"arguments" : @"{}",
      },
    },
    @{
      @"id" : @"extra-key", @"type" : @"function", @"index" : @0,
      @"function" : @{
        @"name" : @"write_file", @"arguments" : @"{}",
      },
      @"extra" : @YES,
    },
  ]) {
    error = nil;
    XCTAssertNil(DSHParseCompletionResponseSchema2(
        [self providerSuccessWithFinish:@"tool_calls" text:@"" reasoning:@"r"
                              toolCalls:@[invalidCall]],
        @"deepseek-v4-flash", @"high", &error));
    XCTAssertEqualObjects(error.localizedDescription,
                          @"E_COMPLETION_TOOL_CALL_INVALID");
  }

  NSArray *extraNativeCalls = @[@{
    @"id" : @"native-extra", @"type" : @"function",
    @"function" : @{
      @"name" : @"write_file",
      @"arguments" : @"{\"path\":\"proof.md\",\"content\":\"proof\",\"extra\":true}",
    },
  }];
  parsed = DSHParseCompletionResponseSchema2(
      [self providerSuccessWithFinish:@"tool_calls" text:@"" reasoning:@"r"
                            toolCalls:extraNativeCalls],
      @"deepseek-v4-flash", @"high", &error);
  XCTAssertEqualObjects(parsed[@"tool_calls"][0][@"arguments"],
      @"{\"path\":\"proof.md\",\"content\":\"proof\",\"extra\":true}");

  NSArray *malformedNativeCalls = @[@{
    @"id" : @"native-malformed", @"type" : @"function",
    @"function" : @{
      @"name" : @"write_file", @"arguments" : @"{not-json",
    },
  }];
  parsed = DSHParseCompletionResponseSchema2(
      [self providerSuccessWithFinish:@"tool_calls" text:@"" reasoning:@"r"
                            toolCalls:malformedNativeCalls],
      @"deepseek-v4-flash", @"high", &error);
  XCTAssertEqualObjects(parsed[@"tool_calls"][0][@"arguments"], @"{not-json");

  NSString *extra = @"{\"type\":\"function_call\",\"function\":\"write_file\",\"parameters\":{},\"extra\":true}";
  parsed = DSHParseCompletionResponseSchema2(
      [self providerSuccessWithFinish:@"stop" text:extra reasoning:@""
                            toolCalls:nil],
      @"deepseek-v4-flash", @"high", &error);
  XCTAssertEqualObjects(parsed[@"finish_reason"], @"stop");
  XCTAssertEqual([parsed[@"tool_calls"] count], 0u);
  XCTAssertEqualObjects(parsed[@"text"], extra);
}

- (void)testProviderResponseIdIsMandatoryAndStrict {
  NSArray *invalidIds = @[NSNull.null, @"", @"bad id", @"bad/value"];
  for (id identifier in invalidIds) {
    NSMutableDictionary *payload = [[self providerSuccessWithFinish:@"stop"
        text:@"ok" reasoning:@"" toolCalls:nil] mutableCopy];
    if (identifier == NSNull.null) {
      [payload removeObjectForKey:@"id"];
    } else {
      payload[@"id"] = identifier;
    }
    NSError *error = nil;
    XCTAssertNil(DSHParseCompletionResponseSchema2(
        payload, @"deepseek-v4-flash", @"high", &error));
    XCTAssertEqualObjects(error.localizedDescription,
                          @"E_COMPLETION_PROVIDER_RESPONSE_ID");
  }
}

- (void)testResponseModelIsMandatoryAndMustEqualRequestedModel {
  NSMutableDictionary *missing = [[self providerSuccessWithFinish:@"stop"
      text:@"ok" reasoning:@"" toolCalls:nil] mutableCopy];
  [missing removeObjectForKey:@"model"];
  NSError *error = nil;
  XCTAssertNil(DSHParseCompletionResponseSchema2(
      missing, @"deepseek-v4-flash", @"high", &error));
  XCTAssertEqualObjects(error.localizedDescription,
                        @"E_COMPLETION_RESPONSE_MODEL");

  NSMutableDictionary *mismatch = [missing mutableCopy];
  mismatch[@"model"] = @"deepseek-v4-pro";
  error = nil;
  XCTAssertNil(DSHParseCompletionResponseSchema2(
      mismatch, @"deepseek-v4-flash", @"high", &error));
  XCTAssertEqualObjects(error.localizedDescription,
                        @"E_COMPLETION_MODEL_MISMATCH");
}

- (void)testSchema2NullableToolContentPreservesStrictResponseContract {
 NSDictionary *call = @{ @"id": @"call_cgi", @"type": @"function", @"function": @{ @"name": @"start_guest_cgi", @"arguments": @"{}" } };
 for (NSString *mode in @[@"off", @"high"]) {
   NSDictionary *message = @{ @"role": @"assistant", @"content": NSNull.null, @"reasoning_content": [mode isEqual:@"off"] ? (id)NSNull.null : @"Plan", @"tool_calls": @[call] };
   NSDictionary *payload = @{ @"id": @"response_nullable", @"model": @"deepseek-v4-flash", @"choices": @[@{ @"finish_reason": @"tool_calls", @"message": message }] };
   NSError *error = nil;
   NSDictionary *result = DSHParseCompletionResponseSchema2(payload, @"deepseek-v4-flash", mode, &error);
   XCTAssertNil(error); XCTAssertEqualObjects(result[@"text"], @""); XCTAssertEqual([result[@"tool_calls"] count], 1U);
   for (NSUInteger variant = 0; variant < 6; variant++) {
     NSMutableDictionary *badMessage = [message mutableCopy];
     NSString *finish = @"tool_calls";
     if (variant == 0) [badMessage removeObjectForKey:@"content"];
     if (variant == 1) badMessage[@"content"] = @42;
     if (variant == 2) badMessage[@"content"] = @{};
     if (variant == 3) badMessage[@"tool_calls"] = @[];
     if (variant == 4) finish = @"stop";
     if (variant == 5) badMessage[@"tool_calls"] = @[@{ @"id": @"call_bad" }];
     NSDictionary *invalid = @{ @"id": @"response_nullable", @"model": @"deepseek-v4-flash", @"choices": @[@{ @"finish_reason": finish, @"message": badMessage }] };
     XCTAssertNil(DSHParseCompletionResponseSchema2(invalid, @"deepseek-v4-flash", mode, &error));
   }
   NSMutableDictionary *missingReasoning = [message mutableCopy]; missingReasoning[@"reasoning_content"] = NSNull.null;
   NSDictionary *reasoningPayload = @{ @"id": @"response_nullable", @"model": @"deepseek-v4-flash", @"choices": @[@{ @"finish_reason": @"tool_calls", @"message": missingReasoning }] };
   NSDictionary *reasoningResult = DSHParseCompletionResponseSchema2(reasoningPayload, @"deepseek-v4-flash", mode, &error);
   if ([mode isEqual:@"off"]) XCTAssertNotNil(reasoningResult); else XCTAssertNil(reasoningResult);
 }
}

- (void)testResponseMessageMustBeAssistantRole {
  for (id role in @[NSNull.null, @"tool", @"user"]) {
    NSMutableDictionary *payload = [[self providerSuccessWithFinish:@"stop"
        text:@"ok" reasoning:@"" toolCalls:nil] mutableCopy];
    NSMutableDictionary *choice = [payload[@"choices"][0] mutableCopy];
    NSMutableDictionary *message = [choice[@"message"] mutableCopy];
    if (role == NSNull.null) {
      [message removeObjectForKey:@"role"];
    } else {
      message[@"role"] = role;
    }
    choice[@"message"] = message;
    payload[@"choices"] = @[choice];
    NSError *error = nil;
    XCTAssertNil(DSHParseCompletionResponseSchema2(
        payload, @"deepseek-v4-flash", @"high", &error));
    XCTAssertEqualObjects(error.localizedDescription,
                          @"E_COMPLETION_EMPTY_RESPONSE");
  }
}

#pragma mark - Real NSURLSession / NSURLProtocol schema 2 RED

- (void)testCapturedHTTPBodyIsSortedAndAllThreeDigestsMatchExactBytes {
  XCTestExpectation *finished = [self expectationWithDescription:@"completion"];
  NSMutableDictionary *envelope = [[self validSchema2Envelope] mutableCopy];
  envelope[@"round_index"] = @1;
  envelope[@"round_transcript"] =
      @[[self validTranscriptAssistant], [self validTranscriptTool]];
  __block NSData *capturedBody = nil;
  __block NSDictionary *result = nil;
  __weak CompletionV2Tests *weakSelf = self;
  [DSHCompletionURLProtocol setHandler:^(NSURLProtocol *protocol,
                                         NSURLRequest *request) {
    capturedBody = DSHTestRequestBody(request);
    [weakSelf respondFromProtocol:protocol request:request
                            json:[weakSelf providerSuccessWithFinish:@"stop"
                                text:@"done" reasoning:@"real-reasoning"
                                toolCalls:nil]
                          status:200];
  }];
  LocalRuntimeModule *module = [self testModuleWithUUIDs:@[
    @"44444444-4444-4444-8444-444444444444",
  ] times:@[@10.0, @10.25]];
  [module completeV2EnvelopeJSON:[self jsonString:envelope]
      resolver:^(id value) {
        result = value;
        [finished fulfill];
      }
      rejecter:^(NSString *code, NSString *message, NSError *error) {
        XCTFail(@"unexpected %@ %@ %@", code, message, error);
        [finished fulfill];
      }];
  [self waitForExpectations:@[finished] timeout:3];

  NSDictionary *body = [NSJSONSerialization JSONObjectWithData:capturedBody
      options:0 error:nil];
  NSData *sorted = [NSJSONSerialization dataWithJSONObject:body
      options:NSJSONWritingSortedKeys error:nil];
  XCTAssertEqualObjects(capturedBody, sorted);
  NSData *visibleData = [NSJSONSerialization dataWithJSONObject:
      envelope[@"visible_history"]
      options:NSJSONWritingSortedKeys error:nil];
  NSData *modelInputData = [NSJSONSerialization dataWithJSONObject:body[@"messages"]
      options:NSJSONWritingSortedKeys error:nil];
  XCTAssertEqualObjects(result[@"visible_history_sha256"],
                        DSHTestSHA256(visibleData));
  XCTAssertEqualObjects(result[@"model_input_sha256"],
                        DSHTestSHA256(modelInputData));
  XCTAssertEqualObjects(result[@"request_body_sha256"],
                        DSHTestSHA256(capturedBody));
  NSArray *sentMessages = body[@"messages"];
  XCTAssertEqual(sentMessages.count, 3u);
  XCTAssertEqualObjects(sentMessages[0],
      (@{@"role": @"user", @"content": @"request-sentinel"}));
  XCTAssertEqualObjects(sentMessages[1], [self validTranscriptAssistant]);
  XCTAssertEqualObjects(sentMessages[2], [self validTranscriptTool]);
  XCTAssertNil(body[@"tool_choice"]);
  NSString *bodyText = [[NSString alloc] initWithData:capturedBody
                                              encoding:NSUTF8StringEncoding];
  XCTAssertFalse([bodyText containsString:
      @"44444444-4444-4444-8444-444444444444"]);
}

- (void)testSuccessReturnsExactSchemaAndNativeProviderRequestCorrelation {
  XCTestExpectation *finished = [self expectationWithDescription:@"completion"];
  __weak CompletionV2Tests *weakSelf = self;
  [DSHCompletionURLProtocol setHandler:^(NSURLProtocol *protocol,
                                         NSURLRequest *request) {
    [weakSelf respondFromProtocol:protocol request:request
                            json:[weakSelf providerSuccessWithFinish:@"stop"
                                text:@"done" reasoning:@"real-reasoning"
                                toolCalls:nil]
                          status:200];
  }];
  LocalRuntimeModule *module = [self testModuleWithUUIDs:@[
    @"44444444-4444-4444-8444-444444444444",
  ] times:@[@10.0, @10.25]];
  [module completeV2EnvelopeJSON:[self jsonString:[self validSchema2Envelope]]
      resolver:^(NSDictionary *result) {
        NSSet *expected = [NSSet setWithArray:@[
          @"schema_version", @"harness_id", @"turn_id", @"attempt_id", @"round_id",
          @"round_index", @"provider_request_id", @"provider_response_id",
          @"requested_model", @"model", @"thinking_mode", @"text",
          @"reasoning", @"tool_calls", @"finish_reason", @"latency_ms",
          @"visible_history_sha256", @"model_input_sha256",
          @"request_body_sha256", @"project_context_receipt",
        ]];
        XCTAssertEqualObjects([NSSet setWithArray:result.allKeys], expected);
        XCTAssertEqualObjects(result[@"schema_version"], @2);
        XCTAssertEqualObjects(result[@"provider_request_id"],
                              @"44444444-4444-4444-8444-444444444444");
        XCTAssertEqualObjects(result[@"provider_response_id"], @"resp_123");
        XCTAssertEqualObjects(result[@"reasoning"], @"real-reasoning");
        XCTAssertEqualObjects(result[@"latency_ms"], @250);
        XCTAssertEqualObjects(result[@"project_context_receipt"], NSNull.null);
        [finished fulfill];
      }
      rejecter:^(NSString *code, NSString *message, NSError *error) {
        XCTFail(@"unexpected %@ %@ %@", code, message, error);
        [finished fulfill];
      }];
  [self waitForExpectations:@[finished] timeout:3];
}

- (void)testSecondActiveRoundReturnsBusyWithoutCancellingFirst {
  XCTestExpectation *started = [self expectationWithDescription:@"first started"];
  XCTestExpectation *busy = [self expectationWithDescription:@"second busy"];
  XCTestExpectation *cancelled = [self expectationWithDescription:@"first cancelled"];
  [DSHCompletionURLProtocol setHandler:^(NSURLProtocol *protocol,
                                         NSURLRequest *request) {
    [started fulfill];
  }];
  LocalRuntimeModule *module = [self testModuleWithUUIDs:@[
    @"44444444-4444-4444-8444-444444444444",
  ] times:@[@10.0]];
  NSDictionary *first = [self validSchema2Envelope];
  [module completeV2EnvelopeJSON:[self jsonString:first]
      resolver:^(__unused id value) { XCTFail(@"must not resolve"); }
      rejecter:^(NSString *code, __unused NSString *message,
                 __unused NSError *error) {
        XCTAssertEqualObjects(code, @"E_COMPLETION_CANCELLED");
        [cancelled fulfill];
      }];
  [self waitForExpectations:@[started] timeout:3];

  NSMutableDictionary *second = [first mutableCopy];
  second[@"round_id"] = @"55555555-5555-4555-8555-555555555555";
  [module completeV2EnvelopeJSON:[self jsonString:second]
      resolver:^(__unused id value) { XCTFail(@"must not resolve"); }
      rejecter:^(NSString *code, NSString *message, NSError *error) {
        XCTAssertEqualObjects(code, @"E_COMPLETION_BUSY");
        XCTAssertEqualObjects(message, @"E_COMPLETION_BUSY");
        XCTAssertNil(error);
        [busy fulfill];
      }];
  [self waitForExpectations:@[busy] timeout:3];
  [module cancelCompletionRequestId:first[@"round_id"]
      resolver:^(NSDictionary *value) {
        XCTAssertEqualObjects(value, (@{@"status": @"cancelled"}));
      }
      rejecter:^(__unused NSString *code, __unused NSString *message,
                 __unused NSError *error) {}];
  [self waitForExpectations:@[cancelled] timeout:3];
}

- (void)testSchema1AndSchema2AreMutuallyBusyWithoutCancellingTheOwner {
  NSDictionary *schema1Envelope = @{
    @"schema_version": @1,
    @"model": @"deepseek-v4-flash",
    @"request_id": @"66666666-6666-4666-8666-666666666666",
    @"thinking_mode": @"off",
    @"history": @[@{@"role": @"user", @"content": @"hello"}],
    @"tools": @[],
  };

  XCTestExpectation *schema1Started =
      [self expectationWithDescription:@"schema1 started"];
  XCTestExpectation *schema1Cancelled =
      [self expectationWithDescription:@"schema1 cancelled"];
  [DSHCompletionURLProtocol setHandler:^(__unused NSURLProtocol *protocol,
                                         __unused NSURLRequest *request) {
    [schema1Started fulfill];
  }];
  LocalRuntimeModule *schema1Owner = [self testModuleWithUUIDs:@[
    @"44444444-4444-4444-8444-444444444444",
  ] times:@[@10.0]];
  [schema1Owner completeV2EnvelopeJSON:[self jsonString:schema1Envelope]
      resolver:^(__unused id value) { XCTFail(@"must not resolve"); }
      rejecter:^(NSString *code, __unused NSString *message,
                 __unused NSError *error) {
        XCTAssertEqualObjects(code, @"cancelled");
        [schema1Cancelled fulfill];
      }];
  [self waitForExpectations:@[schema1Started] timeout:3];
  __block NSString *schema2BusyCode = nil;
  [schema1Owner completeV2EnvelopeJSON:
      [self jsonString:[self validSchema2Envelope]]
      resolver:^(__unused id value) { XCTFail(@"must not resolve"); }
      rejecter:^(NSString *code, __unused NSString *message,
                 __unused NSError *error) { schema2BusyCode = code; }];
  XCTAssertEqualObjects(schema2BusyCode, @"E_COMPLETION_BUSY");
  [schema1Owner cancelCompletionRequestId:schema1Envelope[@"request_id"]
      resolver:^(NSDictionary *value) {
        XCTAssertEqualObjects(value, (@{@"status": @"cancelled"}));
      }
      rejecter:^(__unused NSString *code, __unused NSString *message,
                 __unused NSError *error) {}];
  [self waitForExpectations:@[schema1Cancelled] timeout:3];

  XCTestExpectation *schema2Started =
      [self expectationWithDescription:@"schema2 started"];
  XCTestExpectation *schema2Cancelled =
      [self expectationWithDescription:@"schema2 cancelled"];
  [DSHCompletionURLProtocol setHandler:^(__unused NSURLProtocol *protocol,
                                         __unused NSURLRequest *request) {
    [schema2Started fulfill];
  }];
  LocalRuntimeModule *schema2Owner = [self testModuleWithUUIDs:@[
    @"44444444-4444-4444-8444-444444444444",
  ] times:@[@10.0]];
  NSDictionary *schema2Envelope = [self validSchema2Envelope];
  [schema2Owner completeV2EnvelopeJSON:[self jsonString:schema2Envelope]
      resolver:^(__unused id value) { XCTFail(@"must not resolve"); }
      rejecter:^(NSString *code, __unused NSString *message,
                 __unused NSError *error) {
        XCTAssertEqualObjects(code, @"E_COMPLETION_CANCELLED");
        [schema2Cancelled fulfill];
      }];
  [self waitForExpectations:@[schema2Started] timeout:3];
  NSMutableDictionary *secondSchema1 = [schema1Envelope mutableCopy];
  secondSchema1[@"request_id"] =
      @"77777777-7777-4777-8777-777777777777";
  __block NSString *schema1BusyCode = nil;
  [schema2Owner completeV2EnvelopeJSON:[self jsonString:secondSchema1]
      resolver:^(__unused id value) { XCTFail(@"must not resolve"); }
      rejecter:^(NSString *code, __unused NSString *message,
                 __unused NSError *error) { schema1BusyCode = code; }];
  XCTAssertEqualObjects(schema1BusyCode, @"E_COMPLETION_BUSY");
  [schema2Owner cancelCompletionRequestId:schema2Envelope[@"round_id"]
      resolver:^(NSDictionary *value) {
        XCTAssertEqualObjects(value, (@{@"status": @"cancelled"}));
      }
      rejecter:^(__unused NSString *code, __unused NSString *message,
                 __unused NSError *error) {}];
  [self waitForExpectations:@[schema2Cancelled] timeout:3];
}

- (void)testBusySchema1CallsDoNotAccumulateSuspendedTasksOrSecrets {
  XCTestExpectation *started = [self expectationWithDescription:@"owner started"];
  XCTestExpectation *cancelled = [self expectationWithDescription:@"owner cancelled"];
  [DSHCompletionURLProtocol setHandler:^(__unused NSURLProtocol *protocol,
                                         __unused NSURLRequest *request) {
    [started fulfill];
  }];
  LocalRuntimeModule *module = [self testModuleWithUUIDs:@[
    @"44444444-4444-4444-8444-444444444444",
  ] times:@[@10.0]];
  NSDictionary *schema2Envelope = [self validSchema2Envelope];
  [module completeV2EnvelopeJSON:[self jsonString:schema2Envelope]
      resolver:^(__unused id value) { XCTFail(@"must not resolve"); }
      rejecter:^(NSString *code, __unused NSString *message,
                 __unused NSError *error) {
        XCTAssertEqualObjects(code, @"E_COMPLETION_CANCELLED");
        [cancelled fulfill];
      }];
  [self waitForExpectations:@[started] timeout:3];

  for (NSUInteger index = 0; index < 5; index += 1) {
    NSDictionary *schema1 = @{
      @"schema_version": @1,
      @"model": @"deepseek-v4-flash",
      @"request_id": [NSString stringWithFormat:
          @"%08lx-8888-4888-8888-888888888888", (unsigned long)index],
      @"thinking_mode": @"off",
      @"history": @[@{@"role": @"user", @"content": @"secret-sentinel"}],
      @"tools": @[],
    };
    __block NSString *busyCode = nil;
    [module completeV2EnvelopeJSON:[self jsonString:schema1]
        resolver:^(__unused id value) { XCTFail(@"must not resolve"); }
        rejecter:^(NSString *code, __unused NSString *message,
                   __unused NSError *error) { busyCode = code; }];
    XCTAssertEqualObjects(busyCode, @"E_COMPLETION_BUSY");
  }
  XCTestExpectation *taskCount = [self expectationWithDescription:@"task count"];
  NSURLSession *session = [module valueForKey:@"modelSession"];
  [session getAllTasksWithCompletionHandler:^(NSArray<__kindof NSURLSessionTask *> *tasks) {
    XCTAssertEqual(tasks.count, 1u);
    [taskCount fulfill];
  }];
  [self waitForExpectations:@[taskCount] timeout:3];
  [module cancelCompletionRequestId:schema2Envelope[@"round_id"]
      resolver:^(NSDictionary *value) {
        XCTAssertEqualObjects(value, (@{@"status": @"cancelled"}));
      }
      rejecter:^(__unused NSString *code, __unused NSString *message,
                 __unused NSError *error) {}];
  [self waitForExpectations:@[cancelled] timeout:3];
}

- (void)testCancelMatchesRoundIdAndStaleCancelCannotAffectActiveRound {
  XCTestExpectation *started = [self expectationWithDescription:@"started"];
  XCTestExpectation *completionCancelled =
      [self expectationWithDescription:@"completion cancelled"];
  [DSHCompletionURLProtocol setHandler:^(NSURLProtocol *protocol,
                                         NSURLRequest *request) {
    [started fulfill];
  }];
  LocalRuntimeModule *module = [self testModuleWithUUIDs:@[
    @"44444444-4444-4444-8444-444444444444",
  ] times:@[@10.0]];
  NSDictionary *envelope = [self validSchema2Envelope];
  [module completeV2EnvelopeJSON:[self jsonString:envelope]
      resolver:^(__unused id value) { XCTFail(@"must not resolve"); }
      rejecter:^(NSString *code, NSString *message, NSError *error) {
        XCTAssertEqualObjects(code, @"E_COMPLETION_CANCELLED");
        XCTAssertEqualObjects(message, @"E_COMPLETION_CANCELLED");
        XCTAssertNil(error);
        [completionCancelled fulfill];
      }];
  [self waitForExpectations:@[started] timeout:3];
  __block NSDictionary *staleResult = nil;
  [module cancelCompletionRequestId:
      @"55555555-5555-4555-8555-555555555555"
      resolver:^(NSDictionary *value) { staleResult = value; }
      rejecter:^(__unused NSString *code, __unused NSString *message,
                 __unused NSError *error) {}];
  XCTAssertEqualObjects(staleResult, (@{@"status": @"stale"}));
  [module cancelCompletionRequestId:envelope[@"round_id"]
      resolver:^(NSDictionary *value) {
        XCTAssertEqualObjects(value, (@{@"status": @"cancelled"}));
      }
      rejecter:^(__unused NSString *code, __unused NSString *message,
                 __unused NSError *error) {}];
  [self waitForExpectations:@[completionCancelled] timeout:3];
}

- (void)testRedirectIsCancelledAndDestinationIsNeverLoaded {
  XCTestExpectation *rejected = [self expectationWithDescription:@"redirect rejected"];
  __block NSUInteger destinationHits = 0;
  [DSHCompletionURLProtocol setHandler:^(NSURLProtocol *protocol,
                                         NSURLRequest *request) {
    if ([request.URL.path isEqualToString:@"/redirect-target"]) {
      destinationHits += 1;
      return;
    }
    NSURL *destination = [NSURL URLWithString:
        @"https://api.deepseek.com/redirect-target"];
    NSMutableURLRequest *redirectRequest =
        [NSMutableURLRequest requestWithURL:destination];
    NSHTTPURLResponse *redirectResponse = [[NSHTTPURLResponse alloc]
        initWithURL:request.URL statusCode:302 HTTPVersion:@"HTTP/1.1"
        headerFields:@{@"Location": destination.absoluteString}];
    [protocol.client URLProtocol:protocol
        wasRedirectedToRequest:redirectRequest
              redirectResponse:redirectResponse];
    [protocol.client URLProtocolDidFinishLoading:protocol];
  }];
  LocalRuntimeModule *module = [self testModuleWithUUIDs:@[
    @"44444444-4444-4444-8444-444444444444",
  ] times:@[@10.0]];
  [module completeV2EnvelopeJSON:[self jsonString:[self validSchema2Envelope]]
      resolver:^(__unused id value) { XCTFail(@"must not resolve"); }
      rejecter:^(NSString *code, NSString *message, NSError *error) {
        XCTAssertEqualObjects(code, @"E_COMPLETION_REDIRECT");
        XCTAssertEqualObjects(message, @"E_COMPLETION_REDIRECT");
        XCTAssertNil(error);
        [rejected fulfill];
      }];
  [self waitForExpectations:@[rejected] timeout:3];
  XCTAssertEqual(destinationHits, 0u);
}

- (void)testCancelledSchema2TaskStillRejectsCrossHostRedirectBeforeTaskCancel {
  XCTestExpectation *started = [self expectationWithDescription:@"started"];
  XCTestExpectation *clearedBeforeCancel =
      [self expectationWithDescription:@"cleared before cancel"];
  XCTestExpectation *redirectDecided =
      [self expectationWithDescription:@"redirect decided"];
  XCTestExpectation *completionCancelled =
      [self expectationWithDescription:@"completion cancelled"];
  XCTestExpectation *cancelResolved =
      [self expectationWithDescription:@"cancel resolved"];
  dispatch_semaphore_t allowRedirect = dispatch_semaphore_create(0);
  dispatch_semaphore_t allowTaskCancel = dispatch_semaphore_create(0);
  __block BOOL redirectWasRejected = NO;
  __block NSUInteger settlementCount = 0;

  [DSHCompletionURLProtocol setHandler:^(NSURLProtocol *protocol,
                                         NSURLRequest *request) {
    [started fulfill];
    long gate = dispatch_semaphore_wait(
        allowRedirect, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
    XCTAssertEqual(gate, 0l);
    NSURL *destination = [NSURL URLWithString:
        @"https://cross-host.invalid/schema2-must-not-follow"];
    NSMutableURLRequest *redirectRequest =
        [NSMutableURLRequest requestWithURL:destination];
    NSHTTPURLResponse *redirectResponse = [[NSHTTPURLResponse alloc]
        initWithURL:request.URL statusCode:307 HTTPVersion:@"HTTP/1.1"
        headerFields:@{@"Location": destination.absoluteString}];
    [protocol.client URLProtocol:protocol
        wasRedirectedToRequest:redirectRequest
              redirectResponse:redirectResponse];
    [protocol.client URLProtocolDidFinishLoading:protocol];
  }];
  LocalRuntimeModule *module = [self testModuleWithUUIDs:@[
    @"44444444-4444-4444-8444-444444444444",
  ] times:@[@10.0]];
  void (^beforeCancel)(void) = ^{
    [clearedBeforeCancel fulfill];
    long gate = dispatch_semaphore_wait(
        allowTaskCancel, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
    XCTAssertEqual(gate, 0l);
  };
  void (^redirectDecision)(BOOL) = ^(BOOL rejected) {
    redirectWasRejected = rejected;
    [redirectDecided fulfill];
  };
  [module setValue:[beforeCancel copy]
            forKey:@"completionV2BeforeTaskCancelForTesting"];
  [module setValue:[redirectDecision copy]
            forKey:@"completionV2RedirectDecisionForTesting"];

  NSDictionary *envelope = [self validSchema2Envelope];
  [module completeV2EnvelopeJSON:[self jsonString:envelope]
      resolver:^(__unused id value) {
        @synchronized (module) { settlementCount += 1; }
        XCTFail(@"cancelled completion must not resolve");
      }
      rejecter:^(NSString *code, NSString *message, NSError *error) {
        @synchronized (module) { settlementCount += 1; }
        XCTAssertEqualObjects(code, @"E_COMPLETION_CANCELLED");
        XCTAssertEqualObjects(message, @"E_COMPLETION_CANCELLED");
        XCTAssertNil(error);
        [completionCancelled fulfill];
      }];
  [self waitForExpectations:@[started] timeout:3];

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    [module cancelCompletionRequestId:envelope[@"round_id"]
        resolver:^(NSDictionary *value) {
          XCTAssertEqualObjects(value, (@{@"status": @"cancelled"}));
          [cancelResolved fulfill];
        }
        rejecter:^(__unused NSString *code, __unused NSString *message,
                   __unused NSError *error) {}];
  });
  [self waitForExpectations:@[clearedBeforeCancel] timeout:3];
  dispatch_semaphore_signal(allowRedirect);
  [self waitForExpectations:@[redirectDecided] timeout:3];
  XCTAssertTrue(redirectWasRejected);
  dispatch_semaphore_signal(allowTaskCancel);
  [self waitForExpectations:@[completionCancelled, cancelResolved] timeout:3];
  XCTAssertEqual(settlementCount, 1u);
  XCTAssertEqual([DSHCompletionURLProtocol unexpectedHostHits], 0u);
}

- (void)testAllFailuresAreValueFreeWithRequestAndResponseSentinels {
  XCTestExpectation *rejected = [self expectationWithDescription:@"rejected"];
  [DSHCompletionURLProtocol setHandler:^(NSURLProtocol *protocol,
                                         NSURLRequest *request) {
    NSDictionary *body = @{
      @"error": @{
        @"message": @"provider-response-sentinel authorization-sentinel",
      },
    };
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc]
        initWithURL:request.URL statusCode:429 HTTPVersion:@"HTTP/1.1"
        headerFields:nil];
    NSData *data = [NSJSONSerialization dataWithJSONObject:body options:0
                                                     error:nil];
    [protocol.client URLProtocol:protocol didReceiveResponse:response
              cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [protocol.client URLProtocol:protocol didLoadData:data];
    [protocol.client URLProtocolDidFinishLoading:protocol];
  }];
  LocalRuntimeModule *module = [self testModuleWithUUIDs:@[
    @"44444444-4444-4444-8444-444444444444",
  ] times:@[@10.0]];
  [module completeV2EnvelopeJSON:[self jsonString:[self validSchema2Envelope]]
      resolver:^(__unused id value) { XCTFail(@"must not resolve"); }
      rejecter:^(NSString *code, NSString *message, NSError *error) {
        // 429 is reported as its own stable code; still value-free.
        XCTAssertEqualObjects(code, @"E_COMPLETION_HTTP_429");
        XCTAssertEqualObjects(message, @"E_COMPLETION_HTTP_429");
        XCTAssertNil(error);
        NSString *description = [NSString stringWithFormat:@"%@ %@ %@",
            code, message, error];
        XCTAssertFalse([description containsString:@"request-sentinel"]);
        XCTAssertFalse([description containsString:@"provider-response-sentinel"]);
        XCTAssertFalse([description containsString:@"authorization-sentinel"]);
        [rejected fulfill];
  }];
  [self waitForExpectations:@[rejected] timeout:3];

  NSMutableDictionary *invalidProvider =
      [[self providerSuccessWithFinish:@"stop" text:@"ok" reasoning:@""
                             toolCalls:nil] mutableCopy];
  invalidProvider[@"id"] = @"provider-response-sentinel/secret";
  NSError *parseError = nil;
  XCTAssertNil(DSHParseCompletionResponseSchema2(
      invalidProvider, @"deepseek-v4-flash", @"high", &parseError));
  XCTAssertEqualObjects(parseError.localizedDescription,
                        @"E_COMPLETION_PROVIDER_RESPONSE_ID");
  XCTAssertFalse([parseError.description
      containsString:@"provider-response-sentinel"]);

  XCTestExpectation *transportRejected =
      [self expectationWithDescription:@"transport rejected"];
  [DSHCompletionURLProtocol setHandler:^(NSURLProtocol *protocol,
                                         __unused NSURLRequest *request) {
    NSError *sentinel = [NSError errorWithDomain:@"transport-sentinel-domain"
        code:99 userInfo:@{NSLocalizedDescriptionKey:
            @"transport-response-sentinel secret"}];
    [protocol.client URLProtocol:protocol didFailWithError:sentinel];
  }];
  LocalRuntimeModule *transportModule = [self testModuleWithUUIDs:@[
    @"55555555-5555-4555-8555-555555555555",
  ] times:@[@20.0]];
  [transportModule completeV2EnvelopeJSON:
      [self jsonString:[self validSchema2Envelope]]
      resolver:^(__unused id value) { XCTFail(@"must not resolve"); }
      rejecter:^(NSString *code, NSString *message, NSError *error) {
        XCTAssertEqualObjects(code, @"E_COMPLETION_TRANSPORT");
        XCTAssertEqualObjects(message, @"E_COMPLETION_TRANSPORT");
        XCTAssertNil(error);
        NSString *description = [NSString stringWithFormat:@"%@ %@ %@",
            code, message, error];
        XCTAssertFalse([description containsString:@"transport-sentinel"]);
        XCTAssertFalse([description containsString:@"secret"]);
        [transportRejected fulfill];
      }];
  [self waitForExpectations:@[transportRejected] timeout:3];
}

- (void)testSchema1CompleteV2AndLegacyCompleteRemainCompatible {
  XCTestExpectation *schema1 = [self expectationWithDescription:@"schema1"];
  XCTestExpectation *legacy = [self expectationWithDescription:@"legacy"];
  __weak CompletionV2Tests *weakSelf = self;
  [DSHCompletionURLProtocol setHandler:^(NSURLProtocol *protocol,
                                         NSURLRequest *request) {
    [weakSelf respondFromProtocol:protocol request:request json:@{
      @"id": @"legacy-response",
      @"model": @"deepseek-v4-flash",
      @"choices": @[@{
        @"finish_reason": @"stop",
        @"message": @{@"content": @"legacy-ok"},
      }],
    } status:200];
  }];
  LocalRuntimeModule *module = [self testModuleWithUUIDs:@[
    @"44444444-4444-4444-8444-444444444444",
  ] times:@[@10.0]];
  NSDictionary *schema1Envelope = @{
    @"schema_version": @1,
    @"model": @"deepseek-v4-flash",
    @"request_id": @"66666666-6666-4666-8666-666666666666",
    @"thinking_mode": @"off",
    @"history": @[@{@"role": @"user", @"content": @"hello"}],
    @"tools": @[],
  };
  [module completeV2EnvelopeJSON:[self jsonString:schema1Envelope]
      resolver:^(NSDictionary *value) {
        XCTAssertEqualObjects(value[@"schema_version"], @1);
        XCTAssertEqualObjects(value[@"text"], @"legacy-ok");
        [schema1 fulfill];
      }
      rejecter:^(NSString *code, NSString *message, NSError *error) {
        XCTFail(@"schema1 %@ %@ %@", code, message, error);
        [schema1 fulfill];
      }];
  [self waitForExpectations:@[schema1] timeout:3];

  [module completeModel:@"deepseek-v4-flash"
      history:@[@{@"role": @"user", @"content": @"hello"}]
      requestId:@"77777777-7777-4777-8777-777777777777"
      thinkingMode:@"off"
      resolver:^(NSDictionary *value) {
        XCTAssertEqualObjects(value[@"text"], @"legacy-ok");
        [legacy fulfill];
      }
      rejecter:^(NSString *code, NSString *message, NSError *error) {
        XCTFail(@"legacy %@ %@ %@", code, message, error);
        [legacy fulfill];
      }];
  [self waitForExpectations:@[legacy] timeout:3];
}

- (void)testSchema1RedirectStillFollowsAndCompletes {
  XCTestExpectation *resolved = [self expectationWithDescription:@"resolved"];
  __block NSUInteger destinationHits = 0;
  __weak CompletionV2Tests *weakSelf = self;
  [DSHCompletionURLProtocol setHandler:^(NSURLProtocol *protocol,
                                         NSURLRequest *request) {
    if ([request.URL.path isEqualToString:@"/legacy-target"]) {
      destinationHits += 1;
      [weakSelf respondFromProtocol:protocol request:request json:@{
        @"id": @"legacy-response",
        @"model": @"deepseek-v4-flash",
        @"choices": @[@{
          @"finish_reason": @"stop",
          @"message": @{@"role": @"assistant", @"content": @"legacy-ok"},
        }],
      } status:200];
      return;
    }
    NSURL *destination = [NSURL URLWithString:
        @"https://api.deepseek.com/legacy-target"];
    NSMutableURLRequest *redirectRequest =
        [NSMutableURLRequest requestWithURL:destination];
    NSHTTPURLResponse *redirectResponse = [[NSHTTPURLResponse alloc]
        initWithURL:request.URL statusCode:307 HTTPVersion:@"HTTP/1.1"
        headerFields:@{@"Location": destination.absoluteString}];
    [protocol.client URLProtocol:protocol
        wasRedirectedToRequest:redirectRequest
              redirectResponse:redirectResponse];
    [protocol.client URLProtocolDidFinishLoading:protocol];
  }];
  LocalRuntimeModule *module = [self testModuleWithUUIDs:@[
    @"44444444-4444-4444-8444-444444444444",
  ] times:@[@10.0]];
  NSDictionary *schema1 = @{
    @"schema_version": @1,
    @"model": @"deepseek-v4-flash",
    @"request_id": @"99999999-9999-4999-8999-999999999999",
    @"thinking_mode": @"off",
    @"history": @[@{@"role": @"user", @"content": @"hello"}],
    @"tools": @[],
  };
  [module completeV2EnvelopeJSON:[self jsonString:schema1]
      resolver:^(NSDictionary *value) {
        XCTAssertEqualObjects(value[@"text"], @"legacy-ok");
        [resolved fulfill];
      }
      rejecter:^(NSString *code, NSString *message, NSError *error) {
        XCTFail(@"unexpected %@ %@ %@", code, message, error);
        [resolved fulfill];
      }];
  [self waitForExpectations:@[resolved] timeout:3];
  XCTAssertEqual(destinationHits, 1u);
}

#pragma mark - Redacted model transition proof

- (NSDictionary *)validModelTransition {
  return @{
    @"conversation_id": @"conversation-opaque-123",
    @"from_model": @"deepseek-v4-flash",
    @"to_model": @"deepseek-v4-pro",
    @"source": @"composer_picker",
    @"request_epoch": @7,
    @"request_state": @"idle",
    @"attachment_busy": @NO,
    @"draft_image_count": @0,
    @"history_image_count": @1,
  };
}

- (void)testModelTransitionProofRedactsConversationAndHasExactPersistedKeys {
  NSError *error = nil;
  NSDictionary *row = DSHValidatedModelTransitionProofRow(
      [self validModelTransition], @"2026-08-28T00:00:00.000Z", &error);
  XCTAssertNil(error);
  XCTAssertNotNil(row);
  NSSet *actualKeys = [NSSet setWithArray:row.allKeys];
  NSArray *expectedKeyList = @[
    @"conversation_id_sha256", @"from_model", @"to_model", @"source",
    @"request_epoch", @"request_state", @"attachment_busy",
    @"draft_image_count", @"history_image_count", @"recorded_at",
  ];
  NSSet *expectedKeys = [NSSet setWithArray:expectedKeyList];
  XCTAssertEqualObjects(actualKeys, expectedKeys);
  NSString *digest = row[@"conversation_id_sha256"];
  XCTAssertEqual(digest.length, 64u);
  XCTAssertNotEqualObjects(digest, @"conversation-opaque-123");
  NSRange digestRange = [digest rangeOfString:@"^[0-9a-f]{64}$"
                                      options:NSRegularExpressionSearch];
  XCTAssertNotEqual(digestRange.location, NSNotFound);
  XCTAssertFalse([[row description] containsString:@"conversation-opaque-123"]);
}

- (void)testModelTransitionProofRejectsUnknownMissingAndMalformedFields {
  NSMutableDictionary *extra = [[self validModelTransition] mutableCopy];
  extra[@"message"] = @"must never cross the boundary";
  NSError *error = nil;
  XCTAssertNil(DSHValidatedModelTransitionProofRow(
      extra, @"2026-08-28T00:00:00.000Z", &error));
  XCTAssertNotNil(error);

  NSMutableDictionary *missing = [[self validModelTransition] mutableCopy];
  [missing removeObjectForKey:@"source"];
  error = nil;
  XCTAssertNil(DSHValidatedModelTransitionProofRow(
      missing, @"2026-08-28T00:00:00.000Z", &error));

  // The native JSON bridge may decode an integral number through an NSNumber whose
  // storage is floating-point; mathematical integers remain valid.
  NSMutableDictionary *bridgedInteger = [[self validModelTransition] mutableCopy];
  bridgedInteger[@"request_epoch"] = @1.0;
  error = nil;
  XCTAssertNotNil(DSHValidatedModelTransitionProofRow(
      bridgedInteger, @"2026-08-28T00:00:00.000Z", &error));
  XCTAssertNil(error);

  NSArray<NSDictionary *> *invalid = @[
    @{ @"source": @"attachment_result" },
    @{ @"from_model": @"unknown-model" },
    @{ @"to_model": @"unknown-model" },
    @{ @"request_state": @"complete" },
    @{ @"request_epoch": @YES },
    @{ @"request_epoch": @1.5 },
    @{ @"request_epoch": @2147483648LL },
    @{ @"attachment_busy": @1 },
    @{ @"draft_image_count": @25 },
    @{ @"history_image_count": @100001 },
    @{ @"conversation_id": [@"x" stringByPaddingToLength:257
                                                 withString:@"x"
                                            startingAtIndex:0] },
  ];
  for (NSDictionary *patch in invalid) {
    NSMutableDictionary *entry = [[self validModelTransition] mutableCopy];
    [entry addEntriesFromDictionary:patch];
    error = nil;
    XCTAssertNil(DSHValidatedModelTransitionProofRow(
        entry, @"2026-08-28T00:00:00.000Z", &error), @"%@", patch);
    XCTAssertNotNil(error);
  }
}

- (void)testModelTransitionTraceIsBoundedAndSurvivesBaseProofRewrites {
  NSError *error = nil;
  NSDictionary *row = DSHValidatedModelTransitionProofRow(
      [self validModelTransition], @"2026-08-28T00:00:00.000Z", &error);
  XCTAssertNotNil(row);
  NSDictionary *trace = nil;
  for (NSUInteger index = 0;
       index < DSHMaximumModelTransitionTraceEntries + 4;
       index += 1) {
    trace = DSHModelTransitionTraceByAppendingRow(
        trace, row, @"2026-08-28T00:00:00.000Z");
  }
  NSArray *entries = trace[@"entries"];
  XCTAssertEqual(entries.count, DSHMaximumModelTransitionTraceEntries);
  XCTAssertEqualObjects(trace[@"entry_count"],
                        @(DSHMaximumModelTransitionTraceEntries));
  NSSet *traceKeys = [NSSet setWithArray:trace.allKeys];
  NSSet *expectedTraceKeys = [NSSet setWithArray:
      @[ @"recorded_at", @"entry_count", @"entries" ]];
  XCTAssertEqualObjects(traceKeys, expectedTraceKeys);

  NSDictionary *agent = @{
    @"recorded_at": @"2026-08-28T00:00:00.000Z",
    @"entry_count": @1,
    @"entries": @[ @{
      @"name": @"read_file",
      @"arguments_sha256": @"sha1:0123abcd",
      @"outcome": @"ok",
      @"recorded_at": @"2026-08-28T00:00:00.000Z",
    } ],
  };
  NSMutableDictionary *rewritten = [@{ @"schema_version": @2 } mutableCopy];
  DSHPreserveRuntimeProofTraces(
      @{ @"agent_tool_trace": agent, @"model_transition_trace": trace },
      rewritten);
  XCTAssertEqualObjects(rewritten[@"agent_tool_trace"], agent);
  XCTAssertEqualObjects(rewritten[@"model_transition_trace"], trace);

  NSDictionary *emptyModelTrace = @{
    @"recorded_at": @"2026-08-28T00:00:00.000Z",
    @"entry_count": @0,
    @"entries": @[],
  };
  NSMutableDictionary *emptyRewrite = [NSMutableDictionary dictionary];
  DSHPreserveRuntimeProofTraces(
      @{ @"model_transition_trace": emptyModelTrace }, emptyRewrite);
  XCTAssertEqualObjects(emptyRewrite[@"model_transition_trace"],
                        emptyModelTrace);

  NSMutableDictionary *unsafeAgent = [agent mutableCopy];
  unsafeAgent[@"message"] = @"raw content must not survive";
  NSMutableDictionary *unsafeRewrite = [NSMutableDictionary dictionary];
  DSHPreserveRuntimeProofTraces(
      @{ @"agent_tool_trace": unsafeAgent }, unsafeRewrite);
  XCTAssertNil(unsafeRewrite[@"agent_tool_trace"]);

  NSMutableDictionary *unsafeDigestAgent = [agent mutableCopy];
  unsafeDigestAgent[@"entries"] = @[ @{
    @"name": @"read_file",
    @"arguments_sha256": @"raw/path/or/message",
    @"outcome": @"ok",
    @"recorded_at": @"2026-08-28T00:00:00.000Z",
  } ];
  NSMutableDictionary *unsafeDigestRewrite = [NSMutableDictionary dictionary];
  DSHPreserveRuntimeProofTraces(
      @{ @"agent_tool_trace": unsafeDigestAgent }, unsafeDigestRewrite);
  XCTAssertNil(unsafeDigestRewrite[@"agent_tool_trace"]);

  NSMutableDictionary *oversizedTrace = [trace mutableCopy];
  oversizedTrace[@"recorded_at"] =
      [@"x" stringByPaddingToLength:65 withString:@"x" startingAtIndex:0];
  NSMutableDictionary *oversizedRewrite = [NSMutableDictionary dictionary];
  DSHPreserveRuntimeProofTraces(
      @{ @"model_transition_trace": oversizedTrace }, oversizedRewrite);
  XCTAssertNil(oversizedRewrite[@"model_transition_trace"]);
}

#pragma mark - Tools validation

- (NSDictionary *)validTool {
  return @{
    @"type": @"function",
    @"name": @"git_commit",
    @"description": @"Commit staged work",
    @"parameters": @{@"type": @"object", @"properties": @{}},
  };
}

- (void)testAcceptsAWellFormedToolAndPreservesFields {
  NSError *error = nil;
  NSArray *tools = DSHCompletionToolsV2FromArray(@[ [self validTool] ], &error);
  XCTAssertNil(error);
  XCTAssertEqual(tools.count, 1u);
  XCTAssertEqualObjects(
      tools.firstObject[@"function"][@"name"], @"git_commit");
  XCTAssertEqualObjects(tools.firstObject[@"type"], @"function");
}

- (void)testOmittedToolTypeDefaultsToFunction {
  NSError *error = nil;
  NSMutableDictionary *tool = [[self validTool] mutableCopy];
  [tool removeObjectForKey:@"type"];
  NSArray *tools = DSHCompletionToolsV2FromArray(@[ tool ], &error);
  XCTAssertNil(error);
  XCTAssertEqualObjects(tools.firstObject[@"type"], @"function");
}

- (void)testRejectsMoreThanTheMaximumToolCount {
  NSMutableArray *tools = [NSMutableArray array];
  for (NSUInteger i = 0; i < DSHCompletionV2MaxToolCount + 1; ++i) {
    NSMutableDictionary *tool = [[self validTool] mutableCopy];
    tool[@"name"] = [NSString stringWithFormat:@"tool_%lu", (unsigned long)i];
    [tools addObject:tool];
  }
  NSError *error = nil;
  XCTAssertNil(DSHCompletionToolsV2FromArray(tools, &error));
  XCTAssertNotNil(error);
}

- (void)testRejectsInvalidToolNames {
  for (NSString *bad in @[ @"", @"has space", @"dot.name", @" slash/", @"工具",
                           [@"x" stringByPaddingToLength:65 withString:@"a"
                                                startingAtIndex:0] ]) {
    NSMutableDictionary *tool = [[self validTool] mutableCopy];
    tool[@"name"] = bad;
    NSError *error = nil;
    XCTAssertNil(DSHCompletionToolsV2FromArray(@[ tool ], &error),
                 "expected rejection for %@", bad);
    XCTAssertNotNil(error);
  }
}

- (void)testRejectsNonFunctionTypeAndBadParameters {
  NSMutableDictionary *tool = [[self validTool] mutableCopy];
  tool[@"type"] = @"web_search";
  NSError *error = nil;
  XCTAssertNil(DSHCompletionToolsV2FromArray(@[ tool ], &error));

  NSMutableDictionary *badParams = [[self validTool] mutableCopy];
  badParams[@"parameters"] = @"not-an-object";
  error = nil;
  XCTAssertNil(DSHCompletionToolsV2FromArray(@[ badParams ], &error));
  XCTAssertNotNil(error);
}

- (void)testRejectsOversizedSchemaAndDescription {
  NSMutableDictionary *tool = [[self validTool] mutableCopy];
  NSString *big = [@"" stringByPaddingToLength:(DSHCompletionV2MaxToolSchemaBytes + 64)
                                    withString:@"a" startingAtIndex:0];
  tool[@"parameters"] = @{@"marker": big};
  NSError *error = nil;
  XCTAssertNil(DSHCompletionToolsV2FromArray(@[ tool ], &error));

  NSMutableDictionary *longDescription = [[self validTool] mutableCopy];
  longDescription[@"description"] =
      [@"" stringByPaddingToLength:(DSHCompletionV2MaxToolDescriptionLength + 1)
                         withString:@"d" startingAtIndex:0];
  error = nil;
  XCTAssertNil(DSHCompletionToolsV2FromArray(@[ longDescription ], &error));
  XCTAssertNotNil(error);
}

#pragma mark - Request body

- (void)testBodyContainsToolsOnlyWhenProvided {
  NSDictionary *withoutTools = DSHCompletionRequestBodyV2(
      @"deepseek-v4-flash", @"high",
      @[ @{@"role": @"user", @"content": @"hi"} ], nil);
  XCTAssertEqualObjects(withoutTools[@"model"], @"deepseek-v4-flash");
  XCTAssertFalse([withoutTools.allKeys containsObject:@"tools"]);
  XCTAssertEqualObjects(withoutTools[@"thinking"], @{@"type": @"enabled"});
  XCTAssertEqualObjects(withoutTools[@"reasoning_effort"], @"high");

  NSDictionary *withTools = DSHCompletionRequestBodyV2(
      @"deepseek-v4-flash", @"off",
      @[ @{@"role": @"user", @"content": @"hi"} ],
      DSHCompletionToolsV2FromArray(@[ [self validTool] ], nil));
  XCTAssertEqual(((NSArray *)withTools[@"tools"]).count, 1u);
  XCTAssertEqualObjects(withoutTools[@"stream"], @NO);
  XCTAssertNil(withTools[@"reasoning_effort"]);
}

#pragma mark - Response parsing

- (void)testParsesPlainTextStopResponse {
  NSDictionary *decoded = @{
    @"choices": @[ @{
      @"finish_reason": @"stop",
      @"message": @{@"role": @"assistant", @"content": @"Hello"},
    } ],
  };
  NSError *error = nil;
  NSDictionary *result = DSHParseCompletionResponseV2(decoded, &error);
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"text"], @"Hello");
  XCTAssertEqualObjects(result[@"finish_reason"], @"stop");
  XCTAssertEqual(((NSArray *)result[@"tool_calls"]).count, 0u);
}

- (void)testParsesToolCallsWithEmptyContent {
  NSDictionary *decoded = @{
    @"choices": @[ @{
      @"finish_reason": @"tool_calls",
      @"message": @{
        @"role": @"assistant",
        @"content": [NSNull null],
        @"tool_calls": @[
          @{
            @"id": @"call_1",
            @"type": @"function",
            @"function": @{@"name": @"write_file",
                           @"arguments": @"{\"path\":\"a.md\",\"content\":\"x\"}"},
          },
          @{
            @"id": @"call_2",
            @"type": @"function",
            @"function": @{@"name": @"git_commit", @"arguments": @"{}"},
          },
        ],
      },
    } ],
  };
  NSError *error = nil;
  NSDictionary *result = DSHParseCompletionResponseV2(decoded, &error);
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"text"], @"");
  XCTAssertEqualObjects(result[@"finish_reason"], @"tool_calls");
  XCTAssertEqual(((NSArray *)result[@"tool_calls"]).count, 2u);
  XCTAssertEqualObjects(result[@"tool_calls"][0][@"name"], @"write_file");
  XCTAssertEqualObjects(result[@"tool_calls"][0][@"id"], @"call_1");
  XCTAssertTrue([result[@"tool_calls"][0][@"arguments"]
      hasPrefix:@"{\"path\""]);
  XCTAssertEqualObjects(result[@"tool_calls"][1][@"name"], @"git_commit");
}

- (void)testFailsClosedOnMalformedToolCalls {
  NSDictionary *missingId = @{
    @"choices": @[ @{
      @"finish_reason": @"tool_calls",
      @"message": @{@"tool_calls": @[ @{
        @"function": @{@"name": @"x", @"arguments": @"{}"},
      } ]},
    } ],
  };
  NSError *error = nil;
  XCTAssertNil(DSHParseCompletionResponseV2(missingId, &error));
  XCTAssertNotNil(error);

  NSDictionary *argumentsNotString = @{
    @"choices": @[ @{
      @"finish_reason": @"tool_calls",
      @"message": @{@"tool_calls": @{
        @"id": @"c1",
        @"function": @{@"name": @"x", @"arguments": @{}},
      } },
    } ],
  };
  error = nil;
  XCTAssertNil(DSHParseCompletionResponseV2(argumentsNotString, &error));
  XCTAssertNotNil(error);
}

- (void)testFailsClosedOnEmptyChoicesAndMissingStructure {
  NSError *error = nil;
  XCTAssertNil(DSHParseCompletionResponseV2(@{}, &error));
  XCTAssertNotNil(error);

  error = nil;
  XCTAssertNil(DSHParseCompletionResponseV2(
      @{ @"choices": @[] }, &error));
  XCTAssertNotNil(error);

  // Empty assistant content with no tool calls is an invalid loop response
  // rather than a silently-empty success.
  error = nil;
  XCTAssertNil(DSHParseCompletionResponseV2(@{
    @"choices": @[ @{ @"finish_reason": @"stop",
                      @"message": @{@"content": @" "} } ],
  }, &error));
  XCTAssertNotNil(error);
}

@end
