#import <XCTest/XCTest.h>

#import "AgentPolicyService.h"
#import "AgentNativeWAL.h"
#import "AgentRootResolver.h"
#import "AgentToolRegistry.h"
#import "SessionWorkspaceCoordinator.h"
#import "DSHTestStorageFixture.h"

static NSString *const DSHPolicyWorkspace = @"11111111-1111-4111-8111-111111111111";
static NSString *const DSHPolicyProject = @"22222222-2222-4222-8222-222222222222";
static NSString *const DSHPolicyFingerprint =
    @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

@interface DSHPolicyTestRootResolver : DSHAgentRootResolver
- (instancetype)init;
@property(nonatomic, copy) NSDictionary *currentRoot;
@property(nonatomic, strong) NSError *failure;
@property(nonatomic) BOOL failFinalValidation;
@property(nonatomic) BOOL throwPrivateException;
@property(nonatomic) BOOL observedCoordinator;
@property(nonatomic) NSUInteger resolutions;
@property(nonatomic) NSUInteger validations;
@end

@implementation DSHPolicyTestRootResolver
- (instancetype)init {
  return [super initWithWorkspaceAccess:(id)NSNull.null projectAccess:nil];
}
- (NSDictionary *)resolveRootForWorkspaceId:(NSString *)workspaceId
                                projectId:(NSString *)projectId
                          bindingRevision:(NSNumber *)bindingRevision
                                    error:(NSError **)error {
  (void)workspaceId; (void)projectId; (void)bindingRevision;
  self.resolutions += 1;
  self.observedCoordinator = DSHSessionWorkspaceCoordinator.sharedCoordinator.isExecutingOnQueue;
  if (self.throwPrivateException) {
    [NSException raise:@"private-key" format:@"/private/secret credential must not escape"];
  }
  if (self.failure != nil) {
    if (error != nullptr) *error = self.failure;
    return nil;
  }
  return self.currentRoot;
}
- (BOOL)validateFrozenRoot:(NSDictionary *)root error:(NSError **)error {
  self.validations += 1;
  if (self.failFinalValidation || ![root isEqual:self.currentRoot]) {
    if (error != nullptr) *error = DSHAgentNativeStoreError(DSHAgentNativeStoreErrorOwnerLost);
    return NO;
  }
  return YES;
}
@end

@interface AgentPolicyTests : XCTestCase
@property(nonatomic, strong) NSURL *fixture;
@end

@implementation AgentPolicyTests

- (void)tearDown {
  if (self.fixture != nil) [NSFileManager.defaultManager removeItemAtURL:self.fixture error:nil];
  [super tearDown];
}

- (NSDictionary *)request {
  return @{
    @"schema_version": @1, @"workspace_id": DSHPolicyWorkspace,
    @"workspace_binding_revision": @1, @"project_id": NSNull.null,
  };
}

- (DSHPolicyTestRootResolver *)resolver {
  DSHPolicyTestRootResolver *resolver = [[DSHPolicyTestRootResolver alloc] init];
  resolver.currentRoot = @{
    @"schema_version": @1, @"kind": @"workspace", @"workspace_id": DSHPolicyWorkspace,
    @"workspace_binding_revision": @1, @"project_id": NSNull.null,
    @"root_fingerprint_sha256": DSHPolicyFingerprint,
    @"capabilities": @[@"file_read", @"file_write"],
  };
  return resolver;
}

- (DSHAgentPolicyService *)serviceWithResolver:(DSHAgentRootResolver *)resolver {
  return [[DSHAgentPolicyService alloc] initWithRootResolver:resolver
      registry:[[DSHAgentToolRegistry alloc] init]
      coordinator:DSHSessionWorkspaceCoordinator.sharedCoordinator];
}

- (void)assertSafeProjection:(NSDictionary *)result {
  NSSet *expectedKeys = [NSSet setWithArray:@[
    @"schema_version", @"workspace_id", @"workspace_binding_revision", @"project_id",
    @"registry_version", @"root_fingerprint_sha256", @"policy_version",
    @"capabilities", @"tools", @"budget",
  ]];
  XCTAssertEqualObjects([NSSet setWithArray:result.allKeys], expectedKeys);
  XCTAssertEqualObjects(result[@"policy_version"], @"agent-v1");
  XCTAssertEqualObjects(result[@"budget"], (@{
    @"max_single_write_bytes": @32768, @"max_batch_write_bytes": @524288,
    @"max_attempt_write_bytes": @4194304,
  }));
  for (NSDictionary *tool in result[@"tools"]) {
    XCTAssertEqualObjects([NSSet setWithArray:tool.allKeys],
        ([NSSet setWithArray:@[@"name", @"access"]]));
    XCTAssertTrue(([@[@"auto", @"conversation_confirm"] containsObject:tool[@"access"]]));
  }
}

- (void)testDescribeReturnsOnlyCurrentSafePolicyWithoutAttemptOrCredentials {
  DSHPolicyTestRootResolver *resolver = [self resolver];
  NSError *error = nil;
  NSDictionary *result = [[self serviceWithResolver:resolver] describeRequest:[self request] error:&error];
  XCTAssertNotNil(result); XCTAssertNil(error);
  [self assertSafeProjection:result];
  XCTAssertEqualObjects(result[@"root_fingerprint_sha256"], DSHPolicyFingerprint);
  // Current v4 policy includes the safe question tool. Installing/running a
  // runtime still requires guest_service, which this root does not have.
  XCTAssertEqualObjects(result[@"tools"], (@[
    @{@"name": @"ask_user", @"access": @"auto"},
    @{@"name": @"list_dir", @"access": @"auto"},
    @{@"name": @"list_runtime_environments", @"access": @"auto"},
    @{@"name": @"read_file", @"access": @"auto"},
    @{@"name": @"write_file", @"access": @"conversation_confirm"},
  ]));
  XCTAssertTrue(resolver.observedCoordinator);
  XCTAssertEqual(resolver.resolutions, 1U);
  XCTAssertEqual(resolver.validations, 1U);
}

- (void)testDescribeRejectsMalformedRequestsBeforeResolvingNativeRoot {
  DSHPolicyTestRootResolver *resolver = [self resolver];
  DSHAgentPolicyService *service = [self serviceWithResolver:resolver];
  NSMutableArray *invalid = [NSMutableArray arrayWithArray:@[NSNull.null, @[], @{}]];
  NSArray *mutations = @[
    @{@"schema_version": @YES}, @{@"schema_version": @2},
    @{@"workspace_id": @"not-a-workspace"}, @{@"workspace_id": NSNull.null},
    @{@"workspace_binding_revision": @0}, @{@"workspace_binding_revision": @YES},
    @{@"workspace_binding_revision": @1.5}, @{@"workspace_binding_revision": @(9007199254740992ULL)},
    @{@"project_id": @"/private/project"}, @{@"path": @"/private/secret"},
  ];
  for (NSDictionary *mutation in mutations) {
    NSMutableDictionary *request = [[self request] mutableCopy];
    [request addEntriesFromDictionary:mutation];
    [invalid addObject:request];
  }
  NSMutableDictionary *missing = [[self request] mutableCopy];
  [missing removeObjectForKey:@"project_id"];
  [invalid addObject:missing];
  for (id request in invalid) {
    NSError *error = nil;
    XCTAssertNil([service describeRequest:request error:&error]);
    XCTAssertEqualObjects(error.domain, DSHAgentPolicyErrorDomain);
    XCTAssertEqualObjects(error.userInfo[@"code"], @"E_AGENT_BAD_ARGUMENTS");
    XCTAssertNil(error.userInfo[NSUnderlyingErrorKey]);
  }
  XCTAssertEqual(resolver.resolutions, 0U);
}

- (void)testDescribeRevalidatesBindingAndDoesNotSubstituteAnotherRoot {
  DSHPolicyTestRootResolver *resolver = [self resolver];
  DSHAgentPolicyService *service = [self serviceWithResolver:resolver];
  resolver.failFinalValidation = YES;
  NSError *error = nil;
  XCTAssertNil([service describeRequest:[self request] error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_AGENT_ROOT_STALE");
  resolver.failFinalValidation = NO;
  NSMutableDictionary *changed = [resolver.currentRoot mutableCopy];
  changed[@"workspace_binding_revision"] = @2;
  resolver.currentRoot = changed;
  error = nil;
  XCTAssertNil([service describeRequest:[self request] error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_AGENT_ROOT_STALE");
}

- (void)testDescribeRejectsUnknownNativeErrorsAndExceptionsWithoutDetails {
  DSHPolicyTestRootResolver *resolver = [self resolver];
  DSHAgentPolicyService *service = [self serviceWithResolver:resolver];
  resolver.failure = [NSError errorWithDomain:@"private-provider" code:123 userInfo:@{
    NSLocalizedDescriptionKey: @"/private/secret key-value",
    @"code": @"E_AGENT_ROOT_STALE",
  }];
  for (NSUInteger index = 0; index < 2; index++) {
    NSError *error = nil;
    XCTAssertNil([service describeRequest:[self request] error:&error]);
    XCTAssertEqualObjects(error.domain, DSHAgentPolicyErrorDomain);
    XCTAssertEqualObjects(error.userInfo, (@{
      @"code": @"E_AGENT_NATIVE", NSLocalizedDescriptionKey: @"Agent policy is unavailable.",
    }));
    resolver.failure = nil;
    resolver.throwPrivateException = YES;
  }
}

- (void)testDescribeProjectRegistryUsesNativeCapabilityFilter {
  DSHPolicyTestRootResolver *resolver = [self resolver];
  NSMutableDictionary *root = [resolver.currentRoot mutableCopy];
  root[@"kind"] = @"project";
  root[@"project_id"] = DSHPolicyProject;
  root[@"capabilities"] = @[@"file_read", @"file_write", @"git_status", @"git_commit", @"git_push"];
  resolver.currentRoot = root;
  NSMutableDictionary *request = [[self request] mutableCopy];
  request[@"project_id"] = DSHPolicyProject;
  NSError *error = nil;
  NSDictionary *result = [[self serviceWithResolver:resolver] describeRequest:request error:&error];
  XCTAssertNotNil(result); XCTAssertNil(error);
  [self assertSafeProjection:result];
  XCTAssertTrue(([result[@"tools"] containsObject:@{@"name": @"git_status", @"access": @"auto"}]));
  XCTAssertTrue(([result[@"tools"] containsObject:@{@"name": @"git_commit", @"access": @"conversation_confirm"}]));
  XCTAssertTrue(([result[@"tools"] containsObject:@{@"name": @"git_push", @"access": @"conversation_confirm"}]));
}

- (void)testDescribeRealWorkspaceKeepsRegistryAndChatStorageUntouched {
  NSError *error = nil;
  self.fixture = DSHCreateTestStorageFixtureRoot(@"AgentPolicyTests", &error);
  XCTAssertNotNil(self.fixture, @"%@", error);
  if (self.fixture == nil) return;
  NSURL *privateRoot = [self.fixture URLByAppendingPathComponent:@"private" isDirectory:YES];
  NSURL *documents = [self.fixture URLByAppendingPathComponent:@"Documents" isDirectory:YES];
  for (NSURL *directory in @[privateRoot, documents]) {
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:directory
        withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:&error]);
  }
  DSHLocalWorkspaceAccess *workspace = [[DSHLocalWorkspaceAccess alloc]
      initWithPrivateRootURL:privateRoot documentsRootURL:documents
      clock:^NSDate * { return [NSDate dateWithTimeIntervalSince1970:1787961600]; }
      UUIDGenerator:^NSString * { return DSHPolicyWorkspace; }
      legacyResolver:^BOOL(NSString *projectId, NSDictionary **evidence, NSError **inner) {
        (void)projectId; (void)evidence; (void)inner; return NO;
      } faultHook:nil];
  XCTAssertNotNil([workspace createRishOwnedWorkspaceWithDisplayName:@"Policy Fixture"
      operationId:@"33333333-3333-4333-8333-333333333333" error:&error], @"%@", error);
  NSURL *registryURL = [privateRoot URLByAppendingPathComponent:@"local-workspaces/registry-v1.json"];
  NSData *before = [NSData dataWithContentsOfURL:registryURL];
  XCTAssertNotNil(before);
  DSHAgentRootResolver *resolver = [[DSHAgentRootResolver alloc]
      initWithWorkspaceAccess:workspace projectAccess:[[DSHLocalProjectAccess alloc]
          initWithWorkspaceAccess:workspace hook:nil]];
  DSHAgentPolicyService *service = [self serviceWithResolver:resolver];
  NSDictionary *result = [service describeRequest:[self request] error:&error];
  XCTAssertNotNil(result, @"%@", error); XCTAssertNil(error);
  [self assertSafeProjection:result];
  XCTAssertTrue([result[@"capabilities"] containsObject:@"file_write"]);
  XCTAssertEqualObjects([service describeRequest:[self request] error:&error], result);
  NSMutableDictionary *stale = [[self request] mutableCopy];
  stale[@"workspace_binding_revision"] = @2;
  XCTAssertNil([service describeRequest:stale error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_AGENT_ROOT_STALE");
  XCTAssertEqualObjects([NSData dataWithContentsOfURL:registryURL], before);
  for (NSString *name in @[@"agent-runtime", @"sessions.json"]) {
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:
        [privateRoot URLByAppendingPathComponent:name].path]);
  }
}

@end
