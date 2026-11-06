#import <XCTest/XCTest.h>

#import "../../../../modules/rish/ios/Sources/DSHCompletionV2.h"
#import "../../../../modules/rish/ios/Sources/AgentTranscriptStore.h"

@interface CompletionWriteRevisionTests : XCTestCase
@end

@implementation CompletionWriteRevisionTests

- (NSString *)json:(id)value {
  NSError *error = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:value
      options:NSJSONWritingSortedKeys error:&error];
  XCTAssertNotNil(data);
  XCTAssertNil(error);
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

- (NSDictionary *)parameters:(NSString *)arguments {
  NSError *error = nil;
  id value = [NSJSONSerialization JSONObjectWithData:
      [arguments dataUsingEncoding:NSUTF8StringEncoding] options:0 error:&error];
  XCTAssertNil(error);
  XCTAssertTrue([value isKindOfClass:NSDictionary.class]);
  return value;
}

- (NSDictionary *)call:(NSString *)arguments {
  return @{@"id": @"write-1", @"name": @"write_file", @"arguments": arguments};
}

- (NSDictionary *)responseWithArguments:(NSString *)arguments {
  return @{
    @"id": @"response-write", @"model": @"deepseek-v4-flash",
    @"choices": @[@{
      @"finish_reason": @"tool_calls",
      @"message": @{
        @"role": @"assistant", @"content": NSNull.null,
        @"reasoning_content": @"write the requested file",
        @"tool_calls": @[@{
          @"id": @"write-1", @"type": @"function",
          @"function": @{@"name": @"write_file", @"arguments": arguments},
        }],
      },
    }],
  };
}

- (NSArray *)explicitRevisionValues {
  // Keep the real read_file token format as well as malformed argument types.
  return @[NSNull.null, @"null", @"undefined", @"", @"NULL", @42, @NO,
           @[], @{}, @"16777234:4295181341:42:1789459200:123456789"];
}

- (void)testNormalizeOmittedWriteRevisionAddsJSONNullWithoutMutatingInput {
  NSString *arguments = @"{\"path\":\"目录/hello.py\",\"content\":\"print(42)\\n\"}";
  NSDictionary *call = [self call:arguments];
  NSArray *normalized = DSHCompletionNormalizeToolCalls(@[call]);
  XCTAssertEqual(normalized.count, 1U);
  XCTAssertEqualObjects(normalized[0][@"id"], @"write-1");
  XCTAssertEqualObjects(normalized[0][@"name"], @"write_file");
  NSDictionary *parameters = [self parameters:normalized[0][@"arguments"]];
  XCTAssertEqualObjects(parameters[@"expected_revision"], NSNull.null);
  XCTAssertEqualObjects(parameters[@"path"], @"目录/hello.py");
  XCTAssertEqualObjects(parameters[@"content"], @"print(42)\n");
  XCTAssertEqualObjects(call[@"arguments"], arguments);
  XCTAssertNil([self parameters:arguments][@"expected_revision"]);
  XCTAssertEqualObjects(DSHCompletionNormalizeToolCalls(normalized), normalized);
}

- (void)testNormalizeExplicitWriteRevisionsPreservesTypeAndOriginalBytes {
  for (id revision in [self explicitRevisionValues]) {
    NSString *arguments = [NSString stringWithFormat:@"  %@\n", [self json:@{
      @"path": @"hello.py", @"content": @"print(42)",
      @"expected_revision": revision,
    }]];
    NSDictionary *call = [self call:arguments];
    NSArray *normalized = DSHCompletionNormalizeToolCalls(@[call]);
    XCTAssertEqualObjects(normalized, @[call], @"%@", revision);
    XCTAssertEqualObjects([self parameters:normalized[0][@"arguments"]]
        [@"expected_revision"], revision);
  }
}

- (void)testNormalizeLeavesMalformedAndExtraWriteArgumentsForToolFeedback {
  NSArray *argumentsList = @[
    @"{not-json", @"[]", @"null", @"{}",
    @"{\"path\":\"hello.py\"}",
    @"{\"path\":\"hello.py\",\"content\":null}",
    @"{\"path\":\"hello.py\",\"content\":\"42\",\"extra\":true}",
  ];
  for (NSString *arguments in argumentsList) {
    NSDictionary *call = [self call:arguments];
    XCTAssertEqualObjects(DSHCompletionNormalizeToolCalls(@[call]), @[call]);
  }
}

- (void)testProviderResponseDefaultsOnlyOmittedWriteRevision {
  NSMutableArray *argumentsList = [NSMutableArray arrayWithObject:
      @"{\"path\":\"hello.py\",\"content\":\"print(42)\"}"];
  for (id revision in [self explicitRevisionValues]) {
    [argumentsList addObject:[self json:@{
      @"path": @"hello.py", @"content": @"print(42)",
      @"expected_revision": revision,
    }]];
  }
  [argumentsList addObject:@"{not-json"];
  for (NSString *arguments in argumentsList) {
    NSError *error = nil;
    NSDictionary *parsed = DSHParseCompletionResponseSchema2(
        [self responseWithArguments:arguments], @"deepseek-v4-flash", @"high", &error);
    XCTAssertNotNil(parsed, @"%@", error);
    XCTAssertNil(error);
    XCTAssertEqualObjects(parsed[@"tool_calls"],
        DSHCompletionNormalizeToolCalls(@[[self call:arguments]]));
  }
}

- (void)testCompatibilityResponsePreservesExplicitRevisionValues {
  for (id revision in [self explicitRevisionValues]) {
    NSDictionary *parameters = @{
      @"path": @"hello.py", @"content": @"print(42)",
      @"expected_revision": revision,
    };
    for (NSDictionary *encoded in @[
      @{@"type": @"function_call", @"function": @"write_file", @"parameters": parameters},
      @{@"name": @"write_file", @"arguments": parameters},
    ]) {
      NSDictionary *response = @{
        @"id": @"response-write", @"model": @"deepseek-v4-flash",
        @"choices": @[@{
          @"finish_reason": @"stop",
          @"message": @{@"role": @"assistant", @"content": [self json:encoded]},
        }],
      };
      NSError *error = nil;
      NSDictionary *parsed = DSHParseCompletionResponseSchema2(
          response, @"deepseek-v4-flash", @"off", &error);
      XCTAssertNotNil(parsed, @"%@", error);
      XCTAssertNil(error);
      XCTAssertEqualObjects(parsed[@"finish_reason"], @"tool_calls");
      XCTAssertEqual([parsed[@"tool_calls"] count], 1U);
      XCTAssertEqualObjects([self parameters:parsed[@"tool_calls"][0][@"arguments"]],
          parameters);
    }
  }
}

- (void)testRoundTranscriptReloadPreservesBadRevisionCallsAndTheirFeedback {
  for (NSString *revision in @[@"null", @"undefined",
      @"16777234:4295181341:42:1789459200:123456789"]) {
    NSString *arguments = [self json:@{
      @"path": @"hello.py", @"content": @"print(42)", @"expected_revision": revision,
    }];
    // Historic conflicts must load too; only a newly prepared call uses the
    // corrected bad-arguments feedback. History parsing does not retry it.
    for (NSString *code in @[@"E_AGENT_CONFLICT", @"E_AGENT_BAD_ARGUMENTS"]) {
      NSArray *transcript = @[
        @{@"role": @"assistant", @"content": @"", @"reasoning_content": @"write",
          @"tool_calls": @[@{
            @"id": @"write-1", @"type": @"function",
            @"function": @{@"name": @"write_file", @"arguments": arguments},
          }]},
        @{@"role": @"tool", @"tool_call_id": @"write-1",
          @"content": [self json:@{@"failure_code": code}]},
      ];
      NSData *persisted = [[self json:transcript] dataUsingEncoding:NSUTF8StringEncoding];
      NSError *error = nil;
      NSArray *reloaded = [NSJSONSerialization JSONObjectWithData:persisted options:0 error:&error];
      XCTAssertNil(error);
      NSArray *validated = DSHCompletionRoundTranscriptSchema2FromArray(
          reloaded, 1, @"high", &error);
      XCTAssertNil(error);
      XCTAssertEqualObjects(validated, transcript);
      XCTAssertEqualObjects(validated[0][@"tool_calls"][0][@"function"][@"arguments"],
          arguments);
    }
  }
}

- (void)testProtectedTranscriptReopensWithPlaceholderAndOpaqueWriteRevisions {
  NSURL *directory = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
      URLByAppendingPathComponent:[@"rish-write-revision-"
          stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString]
      isDirectory:YES];
  DSHAgentNativeWAL *(^openWAL)(void) = ^{
    return [[DSHAgentNativeWAL alloc] initWithRootURL:directory
      clock:^NSDate * { return [NSDate dateWithTimeIntervalSince1970:1789459200]; }
      identifierGenerator:^NSString * { return NSUUID.UUID.UUIDString.lowercaseString; }
      faultHook:nil];
  };
  NSDictionary *root = @{
    @"schema_version": @1, @"kind": @"workspace",
    @"workspace_id": @"11111111-1111-4111-8111-111111111111",
    @"workspace_binding_revision": @1, @"project_id": NSNull.null,
    @"root_fingerprint_sha256": @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    @"capabilities": @[@"file_read", @"file_write"],
  };
  NSString *attempt = @"22222222-2222-4222-8222-222222222222";
  @try {
    NSError *error = nil;
    DSHAgentTranscriptStore *store = [[DSHAgentTranscriptStore alloc] initWithWAL:openWAL()];
    NSDictionary *reference = [store createAgentTranscriptWithRequest:@{
      @"schema_version": @1, @"root": root, @"attempt_id": attempt,
    } error:&error];
    XCTAssertNotNil(reference, @"%@", error);
    XCTAssertNil(error);
    NSMutableArray *calls = [NSMutableArray array];
    NSArray *revisions = @[NSNull.null, @"null", @"undefined",
                          @"16777234:4295181341:42:1789459200:123456789"];
    for (id revision in revisions) {
      [calls addObject:@{
        @"schema_version": @1,
        @"call_id": [NSString stringWithFormat:@"write-%lu", (unsigned long)calls.count],
        @"name": @"write_file",
        @"arguments_json": [self json:@{
          @"path": @"hello.py", @"content": @"print(42)", @"expected_revision": revision,
        }],
      }];
    }
    NSDictionary *message = @{
      @"schema_version": @1, @"role": @"assistant", @"round_index": @0,
      @"content": @"", @"reasoning_content": @"write", @"tool_calls": calls,
    };
    reference = [store appendAssistantMessage:message expectedTranscript:reference
        root:root attemptId:attempt error:&error];
    XCTAssertNotNil(reference, @"%@", error);
    XCTAssertNil(error);
    if (reference == nil) return;
    DSHAgentTranscriptStore *reopened = [[DSHAgentTranscriptStore alloc] initWithWAL:openWAL()];
    NSArray *messages = [reopened nativeMessagesForTranscriptWithRequest:@{
      @"schema_version": @1, @"root": root, @"attempt_id": attempt, @"transcript": reference,
    } error:&error];
    XCTAssertNil(error);
    XCTAssertEqualObjects(messages, @[message]);
  } @finally {
    [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
  }
}

@end
