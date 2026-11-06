#import <XCTest/XCTest.h>

#import <CommonCrypto/CommonDigest.h>

#import "../../../../modules/rish/ios/Sources/ClaudeProviderTransport.h"
#import "../../../../modules/rish/ios/Sources/CodexProviderTransport.h"
#import "../../../../modules/rish/ios/Sources/DshProviderTransport.h"
#import "../../../../modules/rish/ios/Sources/DSHCompletionProviderTransport.h"

/// Freezes the request body each harness builds for a given round.
///
/// A round's receipt binds two digests that are not this project's canonical
/// JSON: the provider input digest is `NSJSONWritingSortedKeys`, and the
/// request body digest binds the exact bytes that were sent. Moving the
/// encoding anywhere -- into the shared core, or into another host -- must
/// not change either, so both are recorded here before anything moves.
///
/// The fixture is shared: Android replays it through its own transport and
/// jest owns the contract of the fixture itself, so no host can widen what
/// goes out without the other two saying so.
@interface ProviderRequestFixtureTests : XCTestCase
@end

@implementation ProviderRequestFixtureTests

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

/// The digest a receipt binds: sorted-key JSON, not canonical JSON.
- (NSString *)digestOf:(NSDictionary *)body {
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:body
                                                  options:NSJSONWritingSortedKeys
                                                    error:nil];
  XCTAssertNotNil(bytes);
  unsigned char hash[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, hash);
  NSMutableString *hex = [NSMutableString stringWithCapacity:64];
  for (int index = 0; index < CC_SHA256_DIGEST_LENGTH; index += 1) {
    [hex appendFormat:@"%02x", hash[index]];
  }
  return [hex copy];
}

/// The transport a case names, or the fixture's own when it names none.
- (DSHCompletionProviderTransport *)transportNamed:(NSString *)name
                                           fallback:(DSHCompletionProviderTransport *)fallback {
  if ([name isEqualToString:@"claude-code"]) {
    return [[ClaudeProviderTransport alloc] init];
  }
  if ([name isEqualToString:@"glm"]) {
    return [[GlmProviderTransport alloc] init];
  }
  if ([name isEqualToString:@"codex"]) {
    return [[CodexProviderTransport alloc] init];
  }
  return fallback;
}

- (void)replayFixture:(NSString *)name
            transport:(DSHCompletionProviderTransport *)transport {
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
    NSError *error = nil;
    NSDictionary *body = [[self transportNamed:entry[@"transport"] fallback:transport]
        providerRequestBodyForModel:entry[@"model"]
                       thinkingMode:entry[@"thinking_mode"]
                           messages:entry[@"messages"]
                              tools:entry[@"tools"]
                          streaming:[entry[@"streaming"] boolValue]
                              error:&error];
    XCTAssertNil(error, @"%@", caseName);
    XCTAssertEqualObjects(body, entry[@"body"], @"%@ body", caseName);
    XCTAssertEqualObjects([self digestOf:body], entry[@"body_sha256"],
                          @"%@ digest", caseName);
  }
}

- (void)testDeepSeekRequestBodiesAreFrozen {
  [self replayFixture:@"deepseek-request-cases"
            transport:[[DshProviderTransport alloc] init]];
}

- (void)testAnthropicRequestBodiesAreFrozen {
  [self replayFixture:@"anthropic-request-cases"
            transport:[[ClaudeProviderTransport alloc] init]];
}

- (void)testOpenAIResponsesRequestBodiesAreFrozen {
  [self replayFixture:@"openai-request-cases"
            transport:[[CodexProviderTransport alloc] init]];
}

@end
