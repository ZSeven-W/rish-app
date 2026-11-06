#import "DSHTestProviderModelsFixture.h"
#import <XCTest/XCTest.h>

#import "../../../../modules/rish/ios/Sources/AgentPreparedAttemptStore.h"
#import "../../../../modules/rish/ios/Sources/AgentRootResolver.h"
#import "../../../../modules/rish/ios/Sources/AgentToolRegistry.h"
#import "AssistantTaskExecutor.h"

static NSString *const DSHPreparedTestWorkspace =
    @"11111111-1111-4111-8111-111111111111";
static NSString *const DSHPreparedTestProject =
    @"22222222-2222-4222-8222-222222222222";
static NSString *const DSHPreparedTestFingerprint =
    @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
static NSString *const DSHPreparedTestSessionSHA256 =
    @"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
static NSString *const DSHPreparedTestMessage =
    @"44444444-4444-4444-8444-444444444444";
static NSString *const DSHPreparedTestConversation =
    @"55555555-5555-4555-8555-555555555555";
static NSString *const DSHPreparedTestAttempt =
    @"66666666-6666-4666-8666-666666666666";
static NSString *const DSHPreparedTestOperation =
    @"77777777-7777-4777-8777-777777777777";
static NSString *const DSHPreparedTestOperationTwo =
    @"88888888-8888-4888-8888-888888888888";

@interface DSHPreparedTestGuard : DSHLocalWorkspaceAuthorityMutationGuard
@property(nonatomic, copy) dispatch_block_t onDealloc;
@end

@implementation DSHPreparedTestGuard
- (void)dealloc {
  if (self.onDealloc != nil) self.onDealloc();
}
@end

@interface DSHPreparedTestRootResolver : DSHAgentRootResolver
@property(nonatomic, copy) NSDictionary *currentRoot;
@property(nonatomic) BOOL rejectValidation;
@property(nonatomic) NSUInteger validationCount;
@property(nonatomic) BOOL authorityGuardHeld;
@property(nonatomic) BOOL rebindAttemptedWhileGuardHeld;
@end

@implementation DSHPreparedTestRootResolver

- (instancetype)initWithRoot:(NSDictionary *)root {
  self = [super initWithWorkspaceAccess:
      (DSHLocalWorkspaceAccess *)(id)NSNull.null projectAccess:nil];
  if (self != nil) _currentRoot = [root copy];
  return self;
}

- (NSDictionary *)resolveRootForWorkspaceId:(NSString *)workspaceId
                                    projectId:(NSString *)projectId
                              bindingRevision:(NSNumber *)bindingRevision
                                        error:(NSError **)error {
  if (error != nullptr) *error = nil;
  return self.currentRoot;
}

- (BOOL)validateFrozenRoot:(NSDictionary *)root error:(NSError **)error {
  self.validationCount += 1;
  if (self.rejectValidation || ![root isEqual:self.currentRoot]) {
    if (error != nullptr) *error = DSHAgentNativeStoreError(
        DSHAgentNativeStoreErrorOwnerLost);
    return NO;
  }
  if (error != nullptr) *error = nil;
  return YES;
}

- (DSHLocalWorkspaceAuthorityMutationGuard *)
    acquireAuthorityMutationGuardForFrozenRoot:(NSDictionary *)root
                                         error:(NSError **)error {
  if (error != nullptr) *error = nil;
  self.authorityGuardHeld = YES;
  DSHPreparedTestGuard *guard = [[DSHPreparedTestGuard alloc] init];
  __weak DSHPreparedTestRootResolver *weakSelf = self;
  guard.onDealloc = ^{
    weakSelf.authorityGuardHeld = NO;
  };
  return guard;
}

- (BOOL)validateFrozenRoot:(NSDictionary *)root
     authorityMutationGuard:(DSHLocalWorkspaceAuthorityMutationGuard *)guard
                      error:(NSError **)error {
  BOOL valid = [self validateFrozenRoot:root error:error];
  if (valid && self.authorityGuardHeld) {
    // Deterministic rebind seam: this probe is made after final proof while
    // the store still retains the native guard for its WAL transaction.
    self.rebindAttemptedWhileGuardHeld = YES;
  }
  return valid;
}

@end

@interface DSHPreparedTestSessionStore : DSHSessionSnapshotStore
@property(nonatomic, copy) NSDictionary *loadResult;
@end

@implementation DSHPreparedTestSessionStore

- (instancetype)initWithLoadResult:(NSDictionary *)loadResult {
  NSURL *root = [NSURL fileURLWithPath:[NSTemporaryDirectory()
      stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
  self = [super initWithRootURL:root];
  if (self != nil) _loadResult = [loadResult copy];
  return self;
}

- (NSDictionary *)loadSessionSnapshotWithError:(NSError **)error {
  if (error != nullptr) *error = nil;
  return self.loadResult;
}

@end

static NSString *DSHPreparedVisibleDigest(void) {
  return DSHAgentHJ(@"visible-history", @{
    @"messages" : @[
      @{
        @"role" : @"user",
        @"content" : @"hello",
        @"attachments" : @[],
      },
    ],
  }, nil);
}

static NSDictionary *DSHPreparedTestSession(BOOL project,
                                            NSString **contextDigestOut) {
  NSString *visibleDigest = DSHPreparedVisibleDigest();
  NSDictionary *message = @{
    @"id" : DSHPreparedTestMessage,
    @"role" : @"user",
    @"text" : @"hello",
    @"attachments" : @[],
  };
  NSDictionary *context = nil;
  if (project) {
    context = @{
      @"schema_version" : @1,
      @"runtime_context_id" : @"99999999-9999-4999-8999-999999999999",
      @"project_id" : DSHPreparedTestProject,
      @"snapshot_id" : @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      @"snapshot_sha256" : DSHPreparedTestSessionSHA256,
      @"source_fingerprint" : DSHPreparedTestFingerprint,
      @"context_bytes" : @4,
      @"consent_receipt_id" : @"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      @"provider" : @"deepseek",
      @"policy" : @"chat-read-v1",
      @"policy_version" : @"chat-read-v1.0.0",
    };
    if (contextDigestOut != nullptr) {
      *contextDigestOut = context[@"snapshot_sha256"];
    }
  } else if (contextDigestOut != nullptr) {
    *contextDigestOut = nil;
  }
  NSDictionary *attempt = @{
    @"attempt_id" : DSHPreparedTestAttempt,
    @"turn_id" : DSHPreparedTestAttempt,
    @"model_id" : @"deepseek-v4-flash",
    @"thinking_mode" : @"off",
    @"workspace_id" : project ? DSHPreparedTestWorkspace : NSNull.null,
    @"workspace_binding_revision" : project ? @7 : NSNull.null,
    @"context_project_id" : project ? DSHPreparedTestProject : NSNull.null,
    @"context_disposition" : project ? @"verified" : @"unbound",
    @"project_context" : context ?: NSNull.null,
    @"visible_message_ids" : @[ DSHPreparedTestMessage ],
    @"visible_history_sha256" : visibleDigest,
    @"journal_revision" : @0,
    @"agent" : NSNull.null,
  };
  NSDictionary *conversation = @{
    @"id" : DSHPreparedTestConversation,
    @"workspace_id" : project ? DSHPreparedTestWorkspace : NSNull.null,
    @"project_id" : project ? DSHPreparedTestProject : NSNull.null,
    @"messages" : @[ message ],
    @"attempts" : @[ attempt ],
  };
  return @{
    @"schema_version" : @9,
    @"conversations" : @[ conversation ],
  };
}

static NSDictionary *DSHPreparedTestRequest(BOOL project,
                                            BOOL schema3,
                                            NSString *operationId,
                                            NSString *sessionSHA256,
                                            NSString *contextSHA256) {
  id workspace = project ? DSHPreparedTestWorkspace : NSNull.null;
  id projectId = project ? DSHPreparedTestProject : NSNull.null;
  id revision = project ? @7 : NSNull.null;
  NSNumber *transport = schema3 ? @3 : @2;
  NSDictionary *checkpoint = @{
    @"schema_version" : @1,
    @"journal_revision" : @0,
    @"session_generation" : @3,
    @"session_sha256" : sessionSHA256,
  };
  return @{
    @"schema_version" : @2,
    @"operation_id" : operationId,
    @"controller_cas" : @{
      @"schema_version" : @1,
      @"conversation_id" : DSHPreparedTestConversation,
      @"task_id" : DSHPreparedTestAttempt,
      @"attempt_id" : DSHPreparedTestAttempt,
      @"expected_controller_generation" : @2,
      @"expected_journal_revision" : @0,
      @"expected_session_generation" : @3,
      @"expected_session_sha256" : sessionSHA256,
    },
    @"committed_checkpoint" : checkpoint,
    @"task_id" : DSHPreparedTestAttempt,
    @"conversation_id" : DSHPreparedTestConversation,
    @"attempt_id" : DSHPreparedTestAttempt,
    @"workspace_id" : workspace,
    @"project_id" : projectId,
    @"workspace_binding_revision" : revision,
    @"transport_schema_version" : transport,
    @"model" : @"deepseek-v4-flash",
    @"thinking_mode" : @"off",
    @"visible_message_ids" : @[ DSHPreparedTestMessage ],
    @"visible_history_sha256" : DSHPreparedVisibleDigest(),
    @"visible_message_count" : @1,
    @"project_context_sha256" : contextSHA256 ?: NSNull.null,
    @"registry_version" : @3,
    @"expected_policy_version" : NSNull.null,
    @"expected_transcript" : NSNull.null,
  };
}

static NSDictionary *DSHPreparedTestLoad(NSDictionary *session) {
  NSError *error = nil;
  NSData *json = DSHAgentCanonicalJSON(session, &error);
  NSString *sessionJSON = [[NSString alloc] initWithData:json
                                                encoding:NSUTF8StringEncoding];
  return @{
    @"schema_version" : @1,
    @"status" : @"present",
    @"snapshot" : @{
      @"schema_version" : @1,
      @"generation" : @3,
      @"session_sha256" : DSHPreparedTestSessionSHA256,
    },
    @"session_json" : sessionJSON,
  };
}

static DSHAgentNativeWAL *DSHPreparedTestWAL(NSURL **rootURLOut) {
  NSURL *root = [NSURL fileURLWithPath:[NSTemporaryDirectory()
      stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
  if (rootURLOut != nullptr) *rootURLOut = root;
  return [[DSHAgentNativeWAL alloc]
      initWithRootURL:root
      clock:^NSDate *{
        return [NSDate dateWithTimeIntervalSince1970:1700000000];
      }
      identifierGenerator:^NSString *{
        return @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
      }
      faultHook:nil];
}

static NSDictionary *DSHPreparedTestRoot(BOOL project,
                                         NSArray<NSString *> *capabilities) {
  return @{
    @"schema_version" : @1,
    @"kind" : project ? @"project" : @"workspace",
    @"workspace_id" : DSHPreparedTestWorkspace,
    @"workspace_binding_revision" : @7,
    @"project_id" : project ? DSHPreparedTestProject : NSNull.null,
    @"root_fingerprint_sha256" : DSHPreparedTestFingerprint,
    @"capabilities" : capabilities,
  };
}

static NSDictionary *DSHPreparedToolNamed(NSDictionary *registry, NSString *name) {
  for (NSDictionary *tool in registry[@"tools"])
    if ([tool[@"name"] isEqual:name]) return tool;
  return nil;
}

@interface DSHPreparedDeniedAssistant : DSHAssistantTaskExecutor
@property(nonatomic) NSUInteger authorizationCalls;
@end
@implementation DSHPreparedDeniedAssistant
- (NSDictionary *)assistantContextForConversation:(NSDictionary *)conversation
                                   registryVersion:(NSNumber *)registryVersion error:(NSError **)error {
  (void)conversation; (void)registryVersion;
  self.authorizationCalls += 1;
  DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorConflict);
  return nil;
}
@end

@interface AgentPreparedAttemptStoreTests : XCTestCase
@end

@implementation AgentPreparedAttemptStoreTests

- (void)setUp {
  [super setUp];
  XCTAssertTrue(DSHInstallTestProviderModels(self, @{@"dsh":@[@"deepseek-v4-flash"]},
      [NSSet setWithObject:@"deepseek-v4-flash"]));
}

- (void)testForgedAssistantRegistryFailsBeforeAuthorityOrToolExposure {
  DSHPreparedTestSessionStore *sessions = [[DSHPreparedTestSessionStore alloc]
      initWithLoadResult:DSHPreparedTestLoad(DSHPreparedTestSession(NO, nullptr))];
  DSHPreparedTestRootResolver *resolver = [[DSHPreparedTestRootResolver alloc]
      initWithRoot:DSHPreparedTestRoot(NO, @[@"file_read", @"file_write"])];
  NSURL *walRoot = nil;
  DSHAgentNativeWAL *wal = DSHPreparedTestWAL(&walRoot);
  DSHAgentPreparedAttemptStore *store = [[DSHAgentPreparedAttemptStore alloc]
      initWithWAL:wal rootResolver:resolver sessionSnapshotStore:sessions transcriptStore:nil];
  DSHPreparedDeniedAssistant *assistant = [[DSHPreparedDeniedAssistant alloc] initWithRootResolver:resolver];
  [store setValue:assistant forKey:@"assistantTaskExecutor"];
  NSMutableDictionary *request = [DSHPreparedTestRequest(NO, NO, DSHPreparedTestOperation,
      DSHPreparedTestSessionSHA256, nil) mutableCopy];
  request[@"registry_version"] = @5;
  // Round-trip to immutable JSON, just like the native entry point receives.
  NSDictionary *immutable = [NSJSONSerialization JSONObjectWithData:DSHAgentCanonicalJSON(request, nil)
      options:0 error:nil];
  NSDictionary *result = [store prepareAgentAttemptWithRequest:immutable error:nil];
  XCTAssertEqualObjects(result[@"status"], @"conflict");
  XCTAssertEqual(assistant.authorizationCalls, 1U);
  XCTAssertEqual(resolver.validationCount, 0U);
  XCTAssertEqual([[wal snapshotWithError:nil][@"authorities"] count], 0U);
  [NSFileManager.defaultManager removeItemAtURL:walRoot error:nil];
}

- (void)testWorkspaceRegistryFiltersGitAndKeepsStableDigest {
  NSDictionary *root = DSHPreparedTestRoot(
      NO, @[ @"file_read", @"file_write" ]);
  NSError *error = nil;
  DSHAgentToolRegistry *registry = [[DSHAgentToolRegistry alloc] init];
  NSDictionary *projection = [registry registryForRoot:root error:&error];
  XCTAssertNil(error);
  XCTAssertNotNil(projection);
  XCTAssertEqualObjects(projection[@"registry_version"], @4);
  XCTAssertEqualObjects(projection[@"toolset_sha256"], registry.toolsetSHA256);
  XCTAssertEqualObjects(
      [projection[@"tools"] valueForKey:@"name"],
      (@[ @"ask_user", @"list_dir", @"list_runtime_environments", @"read_file", @"write_file" ]));
  XCTAssertEqualObjects(DSHPreparedToolNamed(projection, @"ask_user")[@"access"], @"auto");
  XCTAssertEqualObjects(DSHPreparedToolNamed(projection, @"list_runtime_environments")[@"access"], @"auto");
  XCTAssertEqualObjects(DSHPreparedToolNamed(projection, @"write_file")[@"access"], @"conversation_confirm");
  XCTAssertTrue([registry validateToolsetSHA256:registry.toolsetSHA256 error:&error]);
  XCTAssertNil(error);

  NSDictionary *unknown = [registry descriptorForToolName:@"future_tool"
                                                      root:root
                                                     error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(unknown[@"access"], @"durable_deny");
  XCTAssertEqualObjects(unknown[@"safe_summary_key"], @"agent.unknown");
}

- (void)testProjectRegistryMapsAllFiveCapabilitiesToSixTools {
  NSDictionary *root = DSHPreparedTestRoot(
      YES, @[ @"file_read", @"file_write", @"git_status", @"git_commit",
              @"git_push" ]);
  NSError *error = nil;
  DSHAgentToolRegistry *registry = [[DSHAgentToolRegistry alloc] init];
  NSDictionary *projection = [registry registryForRoot:root error:&error];
  XCTAssertNil(error);
  // Keep the release-gate selector stable; current v4 adds questions alongside
  // the v3 environment listing while these five capabilities stay fixed.
  XCTAssertEqualObjects(projection[@"registry_version"], @4);
  XCTAssertEqualObjects([projection[@"tools"] valueForKey:@"name"],
                        (@[ @"ask_user", @"git_commit", @"git_push", @"git_status",
                            @"list_dir", @"list_runtime_environments", @"read_file", @"write_file" ]));
  XCTAssertEqualObjects(DSHPreparedToolNamed(projection, @"git_commit")[@"access"], @"conversation_confirm");
  XCTAssertEqualObjects(DSHPreparedToolNamed(projection, @"git_push")[@"access"], @"conversation_confirm");
  XCTAssertEqualObjects(DSHPreparedToolNamed(projection, @"git_status")[@"access"], @"auto");
  XCTAssertEqualObjects(DSHPreparedToolNamed(projection, @"list_runtime_environments")[@"access"], @"auto");
  NSDictionary *policy = [registry policyForRoot:root error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(policy[@"policy_version"], @"agent-v1");
  XCTAssertEqualObjects(policy[@"max_single_write_bytes"], @32768);
  XCTAssertEqualObjects(policy[@"max_batch_write_bytes"], @524288);
  XCTAssertEqualObjects(policy[@"max_attempt_write_bytes"], @4194304);
}

- (void)testWorkspaceRootRejectsGitCapabilityAndPreparedStoreRejectsOpenRecord {
  NSDictionary *invalidWorkspace = DSHPreparedTestRoot(
      NO, @[ @"file_read", @"git_status" ]);
  NSError *error = nil;
  XCTAssertFalse([DSHAgentRootResolver validateAgentRootProjection:
      invalidWorkspace error:&error]);
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorInvalidArgument);

  // Request validation happens before any dependency is touched.  This is a
  // useful guard for the no-bridge slice: a malformed/open record cannot make
  // the prepared authority service dereference a caller-owned object.
  // Use opaque sentinels because the invalid request must be rejected before
  // any dependency access; they are never dereferenced by this test.
  DSHAgentNativeWAL *walSentinel = (DSHAgentNativeWAL *)(id)NSNull.null;
  DSHAgentRootResolver *rootSentinel = (DSHAgentRootResolver *)(id)NSNull.null;
  DSHSessionSnapshotStore *sessionSentinel =
      (DSHSessionSnapshotStore *)(id)NSNull.null;
  DSHAgentPreparedAttemptStore *store =
      [[DSHAgentPreparedAttemptStore alloc]
          initWithWAL:walSentinel
          rootResolver:rootSentinel
          sessionSnapshotStore:sessionSentinel
          transcriptStore:nil];
  NSDictionary *malformedRequest = @{
    @"schema_version" : @2,
  };
  error = nil;
  NSDictionary *result = [store prepareAgentAttemptWithRequest:malformedRequest
                                                         error:&error];
  XCTAssertNil(result);
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorInvalidArgument);
}

- (void)testPrepareCommitsTranscriptAuthorityAndOperationAtomicallyAndReplays {
  NSDictionary *session = DSHPreparedTestSession(NO, nullptr);
  DSHPreparedTestSessionStore *sessionStore =
      [[DSHPreparedTestSessionStore alloc]
          initWithLoadResult:DSHPreparedTestLoad(session)];
  NSDictionary *root = DSHPreparedTestRoot(
      NO, @[ @"file_read", @"file_write" ]);
  DSHPreparedTestRootResolver *rootResolver =
      [[DSHPreparedTestRootResolver alloc] initWithRoot:root];
  NSURL *walRoot = nil;
  DSHAgentNativeWAL *wal = DSHPreparedTestWAL(&walRoot);
  DSHAgentPreparedAttemptStore *store =
      [[DSHAgentPreparedAttemptStore alloc]
          initWithWAL:wal
          rootResolver:rootResolver
          sessionSnapshotStore:sessionStore
          transcriptStore:nil];
  NSDictionary *request = DSHPreparedTestRequest(
      NO, NO, DSHPreparedTestOperation, DSHPreparedTestSessionSHA256, nil);
  NSError *error = nil;
  NSDictionary *first = [store prepareAgentAttemptWithRequest:request
                                                        error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(first[@"status"], @"prepared");
  XCTAssertEqualObjects(first[@"attempt"][@"phase"], @"ready_for_round");
  XCTAssertNil(first[@"attempt"][@"root"][@"path"]);
  XCTAssertNil(first[@"attempt"][@"transcript"][@"messages"]);

  NSDictionary *state = [wal snapshotWithError:&error];
  XCTAssertNil(error);
  XCTAssertEqual([(NSArray *)state[@"authorities"] count], (NSUInteger)1);
  XCTAssertEqual([(NSArray *)state[@"transcripts"] count], (NSUInteger)1);
  XCTAssertEqual([(NSArray *)state[@"operations"] count], (NSUInteger)1);
  XCTAssertEqual([(NSArray *)state[@"operation_results"] count], (NSUInteger)1);
  NSString *safeJSON = [[NSString alloc]
      initWithData:DSHAgentCanonicalJSON(first, &error)
           encoding:NSUTF8StringEncoding];
  XCTAssertNil(error);
  XCTAssertFalse([safeJSON containsString:@"content"]);
  XCTAssertFalse([safeJSON containsString:@"messages"]);
  XCTAssertFalse([safeJSON containsString:@"path"]);

  NSDictionary *replay = [store prepareAgentAttemptWithRequest:request
                                                          error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(replay[@"status"], @"already_prepared");
  XCTAssertEqualObjects(replay[@"attempt"][@"root"], first[@"attempt"][@"root"]);
  state = [wal snapshotWithError:&error];
  XCTAssertNil(error);
  XCTAssertEqual([(NSArray *)state[@"authorities"] count], (NSUInteger)1);
  XCTAssertEqual([(NSArray *)state[@"transcripts"] count], (NSUInteger)1);
  XCTAssertEqual([(NSArray *)state[@"operations"] count], (NSUInteger)1);
  // An exact replay returns the immutable operation result, but still proves
  // that the frozen root is current while holding the authority guard.
  XCTAssertEqual(rootResolver.validationCount, (NSUInteger)2);
  XCTAssertTrue(rootResolver.rebindAttemptedWhileGuardHeld);
  [NSFileManager.defaultManager removeItemAtURL:walRoot error:nil];
}

- (void)testPreparedAttemptReturnsClosedConflictsForCASCheckpointAndReplacement {
  NSDictionary *session = DSHPreparedTestSession(NO, nullptr);
  DSHPreparedTestSessionStore *sessionStore =
      [[DSHPreparedTestSessionStore alloc]
          initWithLoadResult:DSHPreparedTestLoad(session)];
  NSDictionary *root = DSHPreparedTestRoot(NO, @[ @"file_read" ]);
  DSHPreparedTestRootResolver *rootResolver =
      [[DSHPreparedTestRootResolver alloc] initWithRoot:root];
  NSURL *walRoot = nil;
  DSHAgentNativeWAL *wal = DSHPreparedTestWAL(&walRoot);
  DSHAgentPreparedAttemptStore *store =
      [[DSHAgentPreparedAttemptStore alloc]
          initWithWAL:wal
          rootResolver:rootResolver
          sessionSnapshotStore:sessionStore
          transcriptStore:nil];
  NSDictionary *request = DSHPreparedTestRequest(
      NO, NO, DSHPreparedTestOperation, DSHPreparedTestSessionSHA256, nil);
  NSError *error = nil;
  XCTAssertEqualObjects(
      [store prepareAgentAttemptWithRequest:request error:&error][@"status"],
      @"prepared");
  XCTAssertNil(error);

  NSMutableDictionary *badCheckpoint = [request mutableCopy];
  NSMutableDictionary *checkpoint =
      [request[@"committed_checkpoint"] mutableCopy];
  NSMutableDictionary *cas = [request[@"controller_cas"] mutableCopy];
  checkpoint[@"session_generation"] = @4;
  cas[@"expected_session_generation"] = @4;
  badCheckpoint[@"committed_checkpoint"] = checkpoint;
  badCheckpoint[@"controller_cas"] = cas;
  NSDictionary *checkpointConflict =
      [store prepareAgentAttemptWithRequest:badCheckpoint error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(checkpointConflict[@"status"], @"conflict");
  XCTAssertEqualObjects(checkpointConflict[@"failure_code"], @"E_AGENT_CONFLICT");
  XCTAssertEqualObjects(checkpointConflict[@"actual_session_generation"], @3);
  XCTAssertEqualObjects(checkpointConflict[@"actual_session_sha256"],
                        DSHPreparedTestSessionSHA256);
  XCTAssertEqual(checkpointConflict.count, (NSUInteger)12);

  NSMutableDictionary *badCAS = [request mutableCopy];
  NSMutableDictionary *casOnly = [request[@"controller_cas"] mutableCopy];
  casOnly[@"expected_journal_revision"] = @1;
  badCAS[@"controller_cas"] = casOnly;
  NSDictionary *casConflict = [store prepareAgentAttemptWithRequest:badCAS
                                                               error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(casConflict[@"status"], @"conflict");
  XCTAssertEqualObjects(casConflict[@"actual_journal_revision"], @0);
  XCTAssertEqualObjects(casConflict[@"expected_journal_revision"], @1);

  rootResolver.rejectValidation = YES;
  NSMutableDictionary *replacement = [request mutableCopy];
  replacement[@"operation_id"] = DSHPreparedTestOperationTwo;
  NSDictionary *rootConflict = [store prepareAgentAttemptWithRequest:replacement
                                                                error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(rootConflict[@"status"], @"conflict");
  XCTAssertEqualObjects(rootConflict[@"failure_code"], @"E_AGENT_ROOT_STALE");
  XCTAssertEqual(rootConflict.count, (NSUInteger)12);
  NSDictionary *state = [wal snapshotWithError:&error];
  XCTAssertNil(error);
  XCTAssertEqual([(NSArray *)state[@"authorities"] count], (NSUInteger)1);
  XCTAssertEqual([(NSArray *)state[@"transcripts"] count], (NSUInteger)1);
  XCTAssertEqual([(NSArray *)state[@"operations"] count], (NSUInteger)1);
  [NSFileManager.defaultManager removeItemAtURL:walRoot error:nil];
}

- (void)testDifferentOperationRequestCannotReplacePreparedAuthority {
  NSDictionary *session = DSHPreparedTestSession(NO, nullptr);
  DSHPreparedTestSessionStore *sessionStore =
      [[DSHPreparedTestSessionStore alloc]
          initWithLoadResult:DSHPreparedTestLoad(session)];
  DSHPreparedTestRootResolver *rootResolver =
      [[DSHPreparedTestRootResolver alloc]
          initWithRoot:DSHPreparedTestRoot(NO, @[ @"file_read" ])];
  NSURL *walRoot = nil;
  DSHAgentNativeWAL *wal = DSHPreparedTestWAL(&walRoot);
  DSHAgentPreparedAttemptStore *store =
      [[DSHAgentPreparedAttemptStore alloc]
          initWithWAL:wal
          rootResolver:rootResolver
          sessionSnapshotStore:sessionStore
          transcriptStore:nil];
  NSDictionary *request = DSHPreparedTestRequest(
      NO, NO, DSHPreparedTestOperation, DSHPreparedTestSessionSHA256, nil);
  NSError *error = nil;
  XCTAssertEqualObjects(
      [store prepareAgentAttemptWithRequest:request error:&error][@"status"],
      @"prepared");
  XCTAssertNil(error);

  NSMutableDictionary *changed = [request mutableCopy];
  changed[@"expected_policy_version"] = @"agent-v1";
  NSDictionary *conflict = [store prepareAgentAttemptWithRequest:changed
                                                            error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(conflict[@"status"], @"conflict");
  XCTAssertEqualObjects(conflict[@"failure_code"], @"E_AGENT_CONFLICT");
  NSDictionary *state = [wal snapshotWithError:&error];
  XCTAssertNil(error);
  XCTAssertEqual([(NSArray *)state[@"authorities"] count], (NSUInteger)1);
  XCTAssertEqual([(NSArray *)state[@"operations"] count], (NSUInteger)1);
  [NSFileManager.defaultManager removeItemAtURL:walRoot error:nil];
}

- (void)testSchema3CommittedProjectHistoryUsesTheSameFrozenRootPath {
  NSString *contextDigest = nil;
  NSDictionary *session = DSHPreparedTestSession(YES, &contextDigest);
  DSHPreparedTestSessionStore *sessionStore =
      [[DSHPreparedTestSessionStore alloc]
          initWithLoadResult:DSHPreparedTestLoad(session)];
  NSDictionary *root = DSHPreparedTestRoot(
      YES, @[ @"file_read", @"file_write", @"git_status", @"git_commit",
              @"git_push" ]);
  DSHPreparedTestRootResolver *rootResolver =
      [[DSHPreparedTestRootResolver alloc] initWithRoot:root];
  NSURL *walRoot = nil;
  DSHAgentNativeWAL *wal = DSHPreparedTestWAL(&walRoot);
  DSHAgentPreparedAttemptStore *store =
      [[DSHAgentPreparedAttemptStore alloc]
          initWithWAL:wal
          rootResolver:rootResolver
          sessionSnapshotStore:sessionStore
          transcriptStore:nil];
  NSDictionary *request = DSHPreparedTestRequest(
      YES, YES, DSHPreparedTestOperationTwo, DSHPreparedTestSessionSHA256,
      contextDigest);
  NSError *error = nil;
  NSDictionary *result = [store prepareAgentAttemptWithRequest:request
                                                          error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"prepared");
  XCTAssertEqualObjects(result[@"attempt"][@"root"][@"kind"], @"project");
  XCTAssertEqualObjects(result[@"attempt"][@"registry"][@"registry_version"], @3);
  XCTAssertEqualObjects([result[@"attempt"][@"registry"][@"tools"] valueForKey:@"name"],
      (@[@"git_commit", @"git_push", @"git_status", @"list_dir", @"list_runtime_environments", @"read_file", @"write_file"]));
  NSDictionary *authority = [store nativeAuthorityForTaskId:DSHPreparedTestAttempt
                                                   attemptId:DSHPreparedTestAttempt
                                                       error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(authority[@"transport_schema_version"], @3);
  XCTAssertEqualObjects(authority[@"project_context_sha256"], contextDigest);
  [NSFileManager.defaultManager removeItemAtURL:walRoot error:nil];
}

@end
