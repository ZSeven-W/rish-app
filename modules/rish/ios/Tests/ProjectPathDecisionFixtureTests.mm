#import <XCTest/XCTest.h>

#import "../../../../modules/rish/ios/Sources/ProjectContextPolicy.h"

/// Freezes the path policy's decisions so another host can be held to them.
///
/// The tables are the core's. What can differ between hosts is the work done
/// before the core is asked: NFC normalization, Unicode case folding,
/// Foundation's extension and stem rules, the structural refusals. Those are
/// exactly the cases recorded here, and the non-ASCII ones are the point.
///
/// A case whose decision is still `PENDING` fails with a `RECORD` line that
/// carries what this host decided, so the fixture can be filled in from the
/// host that has shipped rather than from a guess.
@interface ProjectPathDecisionFixtureTests : XCTestCase
@end

@implementation ProjectPathDecisionFixtureTests

- (void)testPathDecisionsAreFrozen {
  NSURL *url = [[NSBundle bundleForClass:self.class]
      URLForResource:@"project-path-decisions" withExtension:@"json"];
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
    DSHProjectContextPathDecision *decision =
        [policy decisionForRelativePath:entry[@"path"]];
    NSDictionary *actual = @{
      @"normalized_path" : decision.normalizedPath ?: @"",
      @"eligible" : @(decision.isEligible),
      @"omission_reason" : decision.omissionReason ?: NSNull.null,
    };
    if ([entry[@"decision"] isEqual:@"PENDING"]) {
      NSData *bytes = [NSJSONSerialization dataWithJSONObject:@{@"name" : name, @"decision" : actual}
                                                      options:NSJSONWritingSortedKeys error:nil];
      XCTFail(@"RECORD %@", [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding]);
      continue;
    }
    XCTAssertEqualObjects(actual, entry[@"decision"], @"%@", name);
  }
}

@end
