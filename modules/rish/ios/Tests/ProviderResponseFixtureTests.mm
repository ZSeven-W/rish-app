#import <XCTest/XCTest.h>

#import "../../../../modules/rish/ios/Sources/ClaudeProviderTransport.h"
#import "../../../../modules/rish/ios/Sources/CodexProviderTransport.h"
#import "../../../../modules/rish/ios/Sources/DshProviderTransport.h"

/// Freezes what each host must read back out of a provider's reply.
///
/// Every dialect reduces to one vocabulary -- text, reasoning, tool calls and
/// a finish reason -- and the reduction is where a host can quietly lose a
/// tool call or mislabel a refusal. A case that records `failure_code`
/// instead of `parsed` must be refused with that code: reading a reply that
/// should have been refused is the worse failure of the two, because the
/// round settles on it.
@interface ProviderResponseFixtureTests : XCTestCase
@end

@implementation ProviderResponseFixtureTests

- (NSDictionary *)fixtureNamed:(NSString *)name {
  NSURL *url = [[NSBundle bundleForClass:self.class]
      URLForResource:name withExtension:@"json"];
  XCTAssertNotNil(url, @"%@ fixture missing from the test bundle", name);
  if (url == nil) return nil;
  id value = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:url]
                                             options:0 error:nil];
  XCTAssertTrue([value isKindOfClass:NSDictionary.class]);
  return value;
}

- (DSHCompletionProviderTransport *)transportNamed:(NSString *)name {
  if ([name isEqualToString:@"claude-code"]) {
    return [[ClaudeProviderTransport alloc] init];
  }
  if ([name isEqualToString:@"codex"]) {
    return [[CodexProviderTransport alloc] init];
  }
  return [[DshProviderTransport alloc] init];
}

- (void)replayFixture:(NSString *)name {
  NSDictionary *fixture = [self fixtureNamed:name];
  if (fixture == nil) return;
  XCTAssertEqualObjects(fixture[@"schema_version"], @1);
  NSArray *cases = fixture[@"cases"];
  XCTAssertGreaterThan(cases.count, (NSUInteger)3);
  NSMutableSet *names = [NSMutableSet set];
  for (NSDictionary *entry in cases) {
    NSString *caseName = entry[@"name"];
    XCTAssertFalse([names containsObject:caseName], @"duplicate case %@", caseName);
    [names addObject:caseName];
    NSData *data = [NSJSONSerialization dataWithJSONObject:entry[@"response"]
                                                   options:0 error:nil];
    XCTAssertNotNil(data, @"%@", caseName);
    NSError *error = nil;
    NSDictionary *parsed = [[self transportNamed:entry[@"transport"]]
        providerParseResponseData:data
                   requestedModel:entry[@"requested_model"]
                     thinkingMode:entry[@"thinking_mode"]
                            error:&error];
    if (entry[@"failure_code"] != nil) {
      XCTAssertNil(parsed, @"%@ should have been refused", caseName);
      XCTAssertEqualObjects(error.localizedDescription, entry[@"failure_code"],
                            @"%@ refusal", caseName);
      continue;
    }
    XCTAssertNil(error, @"%@: %@", caseName, error);
    XCTAssertEqualObjects(parsed, entry[@"parsed"], @"%@ parsed", caseName);
  }
}

- (void)testAnthropicResponsesAreFrozen {
  [self replayFixture:@"anthropic-response-cases"];
}

- (void)testOpenAIResponsesAreFrozen {
  [self replayFixture:@"openai-response-cases"];
}

@end
