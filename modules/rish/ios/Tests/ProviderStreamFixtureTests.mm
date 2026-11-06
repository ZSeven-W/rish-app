#import <XCTest/XCTest.h>

#import "../../../../modules/rish/ios/Sources/ClaudeProviderTransport.h"
#import "../../../../modules/rish/ios/Sources/CodexProviderTransport.h"
#import "../../../../modules/rish/ios/Sources/DshProviderTransport.h"
#import "../../../../modules/rish/ios/Sources/RishHarnessCatalog.h"

/// Replays the recorded provider streams shared with jest
/// (__tests__/providerStreamFixtures.test.ts) through each native SSE parser.
/// Every provider must reduce its own wire dialect to the one delta
/// vocabulary the app consumes: {type: delta, content | reasoning |
/// finish_reason} and {type: done}. Cases marked `error` must fail closed
/// during appendBytes or finish instead of emitting a partial delta.
@interface ProviderStreamFixtureTests : XCTestCase
@end

@implementation ProviderStreamFixtureTests

- (NSDictionary *)fixtureNamed:(NSString *)name {
  NSURL *url = [[NSBundle bundleForClass:self.class]
      URLForResource:name withExtension:@"json"];
  XCTAssertNotNil(url, @"%@ fixture missing from the test bundle", name);
  if (url == nil) return nil;
  NSData *data = [NSData dataWithContentsOfURL:url];
  NSError *error = nil;
  id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
  XCTAssertNil(error);
  XCTAssertTrue([value isKindOfClass:NSDictionary.class]);
  return value;
}

- (void)replayFixture:(NSString *)name
            transport:(DSHCompletionProviderTransport *)transport
            harnessId:(NSString *)harnessId {
  NSDictionary *fixture = [self fixtureNamed:name];
  if (fixture == nil) return;
  XCTAssertEqualObjects(fixture[@"schema_version"], @1);
  XCTAssertEqualObjects(fixture[@"harness_id"], harnessId);
  XCTAssertEqualObjects(fixture[@"provider"], DSHProviderIdForHarnessId(harnessId));
  XCTAssertEqualObjects([transport providerHarnessId], harnessId);
  NSArray *cases = fixture[@"cases"];
  XCTAssertGreaterThan(cases.count, (NSUInteger)5);
  NSMutableSet *names = [NSMutableSet set];
  for (NSDictionary *entry in cases) {
    NSString *caseName = entry[@"name"];
    XCTAssertFalse([names containsObject:caseName], @"duplicate case %@", caseName);
    [names addObject:caseName];
    BOOL expectsError = [entry[@"error"] boolValue];
    id<DSHProviderStreamEventParsing> parser = [transport providerNewStreamEventParser];
    XCTAssertNotNil(parser);
    NSMutableArray *collected = [NSMutableArray array];
    NSError *error = nil;
    BOOL failed = NO;
    for (NSString *chunk in entry[@"chunks"]) {
      NSData *bytes = [chunk dataUsingEncoding:NSUTF8StringEncoding];
      NSArray *deltas = [parser appendBytes:(const uint8_t *)bytes.bytes
                                      length:bytes.length
                                       error:&error];
      if (deltas == nil) {
        failed = YES;
        break;
      }
      [collected addObjectsFromArray:deltas];
    }
    if (!failed) {
      NSArray *tail = [parser finish:&error];
      if (tail == nil) failed = YES;
      else [collected addObjectsFromArray:tail];
    }
    if (expectsError) {
      XCTAssertTrue(failed, @"%@/%@ should fail closed", name, caseName);
      XCTAssertNotNil(error, @"%@/%@ must report an error", name, caseName);
    } else {
      XCTAssertFalse(failed, @"%@/%@ failed: %@", name, caseName, error);
      XCTAssertEqualObjects(collected, entry[@"expected"], @"%@/%@", name, caseName);
    }
  }
  // The required coverage every provider dialect has to prove.
  for (NSString *required in @[ @"tool_call_round", @"truncated_tail",
                                @"event_split_across_chunks" ]) {
    XCTAssertTrue([names containsObject:required], @"%@ lacks %@", name, required);
  }
}

- (void)testDeepSeekStreamFixtureReplaysThroughDshParser {
  DshProviderTransport *transport = [[DshProviderTransport alloc]
      initWithSession:NSURLSession.sharedSession uuidGenerator:nil monotonicClock:nil];
  [self replayFixture:@"deepseek-stream-cases" transport:transport harnessId:@"dsh"];
}

- (void)testAnthropicStreamFixtureReplaysThroughClaudeParser {
  ClaudeProviderTransport *transport = [[ClaudeProviderTransport alloc]
      initWithSession:NSURLSession.sharedSession uuidGenerator:nil monotonicClock:nil];
  [self replayFixture:@"claude-stream-cases" transport:transport harnessId:@"claude-code"];
}

- (void)testOpenAIStreamFixtureReplaysThroughCodexParser {
  CodexProviderTransport *transport = [[CodexProviderTransport alloc]
      initWithSession:NSURLSession.sharedSession uuidGenerator:nil monotonicClock:nil];
  [self replayFixture:@"codex-stream-cases" transport:transport harnessId:@"codex"];
}

- (void)testGlmStreamFixtureReplaysThroughGlmParser {
  GlmProviderTransport *transport = [[GlmProviderTransport alloc]
      initWithSession:NSURLSession.sharedSession uuidGenerator:nil monotonicClock:nil];
  [self replayFixture:@"glm-stream-cases" transport:transport harnessId:@"glm"];
}

- (void)testCatalogAgreesOnProviderIdentity {
  XCTAssertEqualObjects(DSHHarnessIdForModel(@"deepseek-v4-flash"), @"dsh");
  XCTAssertEqualObjects(DSHHarnessIdForModel(@"claude-sonnet-5"), @"claude-code");
  XCTAssertEqualObjects(DSHHarnessIdForModel(@"claude-fable-5-1"), @"claude-code");
  XCTAssertEqualObjects(DSHHarnessIdForModel(@"gpt-5.6-nano"), @"codex");
  XCTAssertNil(DSHHarnessIdForModel(@"gpt-4"));
  XCTAssertNil(DSHHarnessIdForModel(@42));
  XCTAssertEqualObjects(DSHProviderIdForModel(@"claude-opus-5"), @"anthropic");
  XCTAssertEqualObjects(DSHProviderHostForModel(@"gpt-5.6"), @"api.openai.com");
  XCTAssertEqualObjects(DSHProviderHostForModel(@"deepseek-v4-pro"), @"api.deepseek.com");
  XCTAssertEqualObjects(DSHCredentialAccountForHarnessId(@"claude-code"), @"ANTHROPIC_API_KEY");
  XCTAssertEqualObjects(DSHCredentialAccountForHarnessId(@"codex"), @"OPENAI_API_KEY");
  XCTAssertEqualObjects(DSHCredentialAccountForHarnessId(@"dsh"), @"DEEPSEEK_API_KEY");
  XCTAssertNil(DSHCredentialAccountForHarnessId(@"rish-guest"));
  XCTAssertTrue(DSHHarnessIsProviderHost(@"api.anthropic.com"));
  XCTAssertFalse(DSHHarnessIsProviderHost(@"api.example.com"));
  XCTAssertEqual(DSHHarnessSupportedModels().count, (NSUInteger)12);
}

@end
