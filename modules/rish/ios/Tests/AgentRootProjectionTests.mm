#import <XCTest/XCTest.h>

#import "../../../../modules/rish/ios/Sources/AgentNativeWAL.h"
#import "../../../../modules/rish/ios/Sources/AgentRootResolver.h"

/// Pins the frozen root projection against the rule as it stood before it
/// moved into the shared core (`DSHAgentRootProjectionShape` /
/// `DSHAgentRootCapabilityArray` at 65fa32f). Every expectation here is read
/// off that implementation, not off the port, so this fails if the port
/// drifted rather than agreeing with itself.
///
/// A root decides which tools a conversation is offered and which grants a
/// lease must require, so a capability that appears or disappears here is a
/// capability difference, not a formatting one.
@interface AgentRootProjectionTests : XCTestCase
@end

@implementation AgentRootProjectionTests

// Both carry hex letters on purpose: a UUID of digits alone cannot show
// whether the canonical-spelling rule is applied at all.
static NSString *const kWorkspace = @"a1b2c3d4-1111-4111-8111-1111abcd1111";
static NSString *const kProject = @"b2c3d4e5-2222-4222-8222-2222abcd2222";

- (NSMutableDictionary *)workspaceRoot {
  return [@{
    @"schema_version" : @1,
    @"kind" : @"workspace",
    @"workspace_id" : kWorkspace,
    @"workspace_binding_revision" : @7,
    @"project_id" : NSNull.null,
    @"root_fingerprint_sha256" : [@"" stringByPaddingToLength:64
                                                   withString:@"c"
                                              startingAtIndex:0],
    @"capabilities" : @[ @"file_read", @"file_write" ],
  } mutableCopy];
}

- (NSMutableDictionary *)projectRoot {
  NSMutableDictionary *root = [self workspaceRoot];
  root[@"kind"] = @"project";
  root[@"project_id"] = kProject;
  root[@"capabilities"] = @[ @"file_read", @"file_write", @"git_status",
                             @"git_commit", @"git_push" ];
  return root;
}

- (BOOL)accepts:(NSDictionary *)root {
  NSError *error = nil;
  BOOL valid = [DSHAgentRootResolver validateAgentRootProjection:
      [root copy] error:&error];
  if (!valid) {
    XCTAssertNotNil(error, @"a refusal must name a reason");
    XCTAssertEqual(error.code, DSHAgentNativeStoreErrorInvalidArgument);
  }
  return valid;
}

- (void)testTheTwoWellFormedRootsAreAccepted {
  XCTAssertTrue([self accepts:[self workspaceRoot]]);
  XCTAssertTrue([self accepts:[self projectRoot]]);
}

- (void)testTheSevenKeysAreExact {
  for (NSString *key in @[ @"schema_version", @"kind", @"workspace_id",
                           @"workspace_binding_revision", @"project_id",
                           @"root_fingerprint_sha256", @"capabilities" ]) {
    NSMutableDictionary *root = [self workspaceRoot];
    [root removeObjectForKey:key];
    XCTAssertFalse([self accepts:root], @"missing %@", key);
  }
  NSMutableDictionary *extra = [self workspaceRoot];
  extra[@"path"] = @"/tmp";
  XCTAssertFalse([self accepts:extra], @"an eighth key");
}

/// `DSHAgentSafeInteger(..., NO)` refused zero, so a binding revision starts
/// at one. A root that claimed revision zero would compare equal to a root
/// whose binding had never been recorded.
- (void)testABindingRevisionIsAPositiveSafeInteger {
  NSMutableDictionary *root = [self workspaceRoot];
  root[@"workspace_binding_revision"] = @0;
  XCTAssertFalse([self accepts:root], @"zero");
  root[@"workspace_binding_revision"] = @(-1);
  XCTAssertFalse([self accepts:root], @"negative");
  root[@"workspace_binding_revision"] = @"7";
  XCTAssertFalse([self accepts:root], @"a string");
  root[@"workspace_binding_revision"] = @(9007199254740992.0);
  XCTAssertFalse([self accepts:root], @"past the safe range");
  root[@"workspace_binding_revision"] = @9007199254740991;
  XCTAssertTrue([self accepts:root], @"the largest safe revision");
}

- (void)testSchemaVersionIsExactlyOne {
  NSMutableDictionary *root = [self workspaceRoot];
  for (id version in @[ @0, @2, @"1", NSNull.null ]) {
    root[@"schema_version"] = version;
    XCTAssertFalse([self accepts:root], @"%@", version);
  }
}

- (void)testKindAndProjectIdentityAgree {
  NSMutableDictionary *workspace = [self workspaceRoot];
  workspace[@"project_id"] = kProject;
  XCTAssertFalse([self accepts:workspace], @"a workspace naming a project");
  NSMutableDictionary *project = [self projectRoot];
  project[@"project_id"] = NSNull.null;
  XCTAssertFalse([self accepts:project], @"a project naming none");
  project[@"project_id"] = @"not-a-uuid";
  XCTAssertFalse([self accepts:project], @"a project id that is not a uuid");
  NSMutableDictionary *other = [self workspaceRoot];
  other[@"kind"] = @"folder";
  XCTAssertFalse([self accepts:other], @"a third kind");
}

/// The identifiers are canonical: an uppercase UUID is a different spelling of
/// the same workspace, and two spellings would be two roots.
- (void)testIdentifiersAreCanonical {
  NSMutableDictionary *root = [self workspaceRoot];
  root[@"workspace_id"] = kWorkspace.uppercaseString;
  XCTAssertFalse([self accepts:root], @"an uppercase workspace id");
  root = [self workspaceRoot];
  root[@"root_fingerprint_sha256"] =
      [[@"" stringByPaddingToLength:64 withString:@"C" startingAtIndex:0] copy];
  XCTAssertFalse([self accepts:root], @"an uppercase fingerprint");
  root[@"root_fingerprint_sha256"] =
      [@"" stringByPaddingToLength:63 withString:@"c" startingAtIndex:0];
  XCTAssertFalse([self accepts:root], @"a short fingerprint");
}

- (void)testACapabilityListIsBoundedKnownAndWithoutRepeats {
  NSMutableDictionary *root = [self projectRoot];
  root[@"capabilities"] = @[ @"file_read", @"file_read" ];
  XCTAssertFalse([self accepts:root], @"a repeat");
  root[@"capabilities"] = @[ @"file_delete" ];
  XCTAssertFalse([self accepts:root], @"an unknown capability");
  root[@"capabilities"] = @[ @"file_read", @"file_write", @"git_status",
                             @"git_commit", @"git_push", @"guest_service",
                             @"file_read" ];
  XCTAssertFalse([self accepts:root], @"seven entries");
  root[@"capabilities"] = @[ @"file_read", @"file_write", @"git_status",
                             @"git_commit", @"git_push", @"guest_service" ];
  XCTAssertTrue([self accepts:root], @"six is the widest root there is");
  root[@"capabilities"] = @[];
  XCTAssertTrue([self accepts:root], @"a root that can do nothing is still a root");
  root[@"capabilities"] = @[ @1 ];
  XCTAssertFalse([self accepts:root], @"a capability that is not a string");
}

/// A workspace root has no repository, so it may not name a Git capability
/// even though the capability itself is a known one.
- (void)testAWorkspaceRootMayNotNameAGitCapability {
  for (NSString *capability in @[ @"git_status", @"git_commit", @"git_push" ]) {
    NSMutableDictionary *root = [self workspaceRoot];
    root[@"capabilities"] = @[ @"file_read", capability ];
    XCTAssertFalse([self accepts:root], @"%@", capability);
  }
  NSMutableDictionary *project = [self projectRoot];
  XCTAssertTrue([self accepts:project], @"a project root may");
}

- (void)testSomethingThatIsNotARootIsRefusedRatherThanCrashing {
  XCTAssertFalse([self accepts:@{}]);
  NSError *error = nil;
  XCTAssertFalse([DSHAgentRootResolver validateAgentRootProjection:
      (NSDictionary *)(id)@[] error:&error]);
  XCTAssertFalse([DSHAgentRootResolver validateAgentRootProjection:
      (NSDictionary *)(id)NSNull.null error:&error]);
  XCTAssertFalse([DSHAgentRootResolver validateAgentRootProjection:nil
                                                             error:&error]);
}

@end
