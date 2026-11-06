#import <XCTest/XCTest.h>

#import "../../../../modules/rish/ios/Sources/ProjectContextPolicy.h"

/// Freezes the credential scanner's decisions so the shared core and the
/// other host can be held to them.
///
/// The scanner shipped here first, written over `unichar`s with Foundation's
/// character sets and ICU's regular expressions. The port in the core walks
/// UTF-16 code units and matches the four expressions by hand; whether it
/// says the same thing about the same bytes is exactly what this fixture
/// records. A case whose decision is still `PENDING` fails with a `RECORD`
/// line carrying what this host decided, so the fixture is filled in from the
/// host that has shipped rather than from a guess.
@interface ProjectSecretDecisionFixtureTests : XCTestCase
@end

@implementation ProjectSecretDecisionFixtureTests

- (void)testSecretDecisionsAreFrozen {
  NSURL *url = [[NSBundle bundleForClass:self.class]
      URLForResource:@"project-secret-decisions" withExtension:@"json"];
  XCTAssertNotNil(url);
  if (url == nil) return;
  NSDictionary *fixture = [NSJSONSerialization
      JSONObjectWithData:[NSData dataWithContentsOfURL:url] options:0 error:nil];
  XCTAssertEqualObjects(fixture[@"schema_version"], @1);
  DSHProjectContextPolicy *policy = [[DSHProjectContextPolicy alloc] init];
  NSMutableSet *names = [NSMutableSet set];
  for (NSDictionary *entry in fixture[@"cases"]) {
    NSString *name = entry[@"name"];
    XCTAssertFalse([names containsObject:name], @"duplicate case %@", name);
    [names addObject:name];
    NSData *bytes = [entry[@"text"] dataUsingEncoding:NSUTF8StringEncoding];
    DSHProjectContextSecretDecision *decision = [policy secretDecisionForData:bytes];
    NSDictionary *actual = @{
      @"suspected_secret" : @(decision.suspectedSecret),
      @"omission_reason" : decision.omissionReason ?: NSNull.null,
    };
    if ([entry[@"decision"] isEqual:@"PENDING"]) {
      NSData *record = [NSJSONSerialization
          dataWithJSONObject:@{@"name" : name, @"decision" : actual}
                     options:NSJSONWritingSortedKeys error:nil];
      XCTFail(@"RECORD %@", [[NSString alloc] initWithData:record encoding:NSUTF8StringEncoding]);
      continue;
    }
    XCTAssertEqualObjects(actual, entry[@"decision"], @"%@", name);
  }
}

@end
