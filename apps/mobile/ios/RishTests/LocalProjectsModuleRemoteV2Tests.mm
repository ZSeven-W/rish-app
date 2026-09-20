// The remote half of the V2 Git bridge on a workspace project: origin set
// and read back by root, a credential provisioned through the native prompt
// seam and reported as status only, cleared again, and a push that refuses
// what it cannot prove before it connects. No network; the wire is covered
// by GitPushG2Tests through scripts/g2-acceptance.rb.

#import "LocalProjectsModuleV2TestSupport.h"
#import "../../../../modules/rish/ios/Sources/DSHGitPushSupport.h"
#include <git2.h>

typedef void (^RV2Resolve)(id result);
typedef void (^RV2Reject)(NSString *code, NSString *message, NSError *error);

@interface LocalProjectsModule (RemoteV2Testing)
- (void)setRemoteV2Request:(id)request resolver:(RV2Resolve)resolve rejecter:(RV2Reject)reject;
- (void)remoteV2Request:(id)request resolver:(RV2Resolve)resolve rejecter:(RV2Reject)reject;
- (void)credentialStatusV2Request:(id)request resolver:(RV2Resolve)resolve rejecter:(RV2Reject)reject;
- (void)presentCredentialPromptV2Request:(id)request resolver:(RV2Resolve)resolve rejecter:(RV2Reject)reject;
- (void)clearCredentialV2Request:(id)request resolver:(RV2Resolve)resolve rejecter:(RV2Reject)reject;
- (void)pushV2Request:(id)request resolver:(RV2Resolve)resolve rejecter:(RV2Reject)reject;
- (void)cancelPushV2Request:(id)request resolver:(RV2Resolve)resolve rejecter:(RV2Reject)reject;
- (void)statusV2Request:(id)request resolver:(RV2Resolve)resolve rejecter:(RV2Reject)reject;
- (void)fetchV2Request:(id)request resolver:(RV2Resolve)resolve rejecter:(RV2Reject)reject;
- (void)pullFastForwardV2Request:(id)request resolver:(RV2Resolve)resolve rejecter:(RV2Reject)reject;
@end

@interface LocalProjectsModuleRemoteV2Tests : XCTestCase
@property(nonatomic, strong) NSURL *privateRoot;
@property(nonatomic, strong) NSURL *documentsRoot;
@property(nonatomic, strong) DSHLocalWorkspaceAccess *workspaceAccess;
@property(nonatomic, strong) DSHLocalProjectAccess *projectAccess;
@property(nonatomic, strong, nullable) LocalProjectsModule *module;
@property(nonatomic, copy) NSDictionary *projectRoot;
@end

@implementation LocalProjectsModuleRemoteV2Tests

// The same real workspace/project fixture LocalProjectsModuleV2Tests builds,
// with a project attached so every call here has a root to name.
- (void)setUp {
  [super setUp];
  NSString *suffix = NSUUID.UUID.UUIDString.lowercaseString;
  self.privateRoot = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
      [NSString stringWithFormat:@"rish-remote-private-%@", suffix]] isDirectory:YES];
  self.documentsRoot = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
      [NSString stringWithFormat:@"rish-remote-documents-%@", suffix]] isDirectory:YES];
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:self.privateRoot
                                       withIntermediateDirectories:YES attributes:nil error:nil]);
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:self.documentsRoot
                                       withIntermediateDirectories:YES attributes:nil error:nil]);
  NSString *workspaceId = @"11111111-1111-4111-8111-111111111111";
  self.workspaceAccess = [[DSHLocalWorkspaceAccess alloc]
      initWithPrivateRootURL:self.privateRoot
            documentsRootURL:self.documentsRoot
                       clock:^NSDate *{ return NSDate.date; }
               UUIDGenerator:^NSString *{ return workspaceId; }
              legacyResolver:^BOOL(__unused NSString *projectId, NSDictionary **evidence, NSError **error) {
                if (evidence != nil) *evidence = nil;
                if (error != nil) *error = [NSError errorWithDomain:@"test" code:1 userInfo:nil];
                return NO;
              }
                   faultHook:nil];
  NSError *error = nil;
  XCTAssertTrue([self.workspaceAccess ensurePrivateLayoutWithError:&error], @"%@", error);
  NSDictionary *workspace = [self.workspaceAccess
      createRishOwnedWorkspaceWithDisplayName:@"Remote Fixture"
                                  operationId:@"22222222-2222-4222-8222-222222222222"
                                        error:&error];
  XCTAssertNotNil(workspace, @"%@", error);
  self.projectAccess = [[DSHLocalProjectAccess alloc] initWithWorkspaceAccess:self.workspaceAccess hook:nil];
  Class moduleClass = NSClassFromString(@"LocalProjectsModule");
  if (moduleClass == Nil) XCTSkip(@"LocalProjectsModule is not linked into this XCTest target");
  self.module = [[moduleClass alloc] init];
  [self.module setValue:self.workspaceAccess forKey:@"workspaceAccessV2"];
  [self.module setValue:self.projectAccess forKey:@"projectAccessV2"];
  [self.module setValue:nil forKey:@"v2AttachStartupError"];
  [self.module setValue:nil forKey:@"credentialPromptHook"];
  NSDictionary *root = @{
    @"schema_version" : @1,
    @"workspace_id" : workspace[@"workspace_id"],
    @"binding_revision" : workspace[@"binding_revision"],
    @"project_id" : NSNull.null,
  };
  // The attach's leases must be gone before the first write lease below:
  // on the test thread the pool drains only when the test ends.
  NSMutableDictionary *projectRoot = [root mutableCopy];
  @autoreleasepool {
    NSDictionary *attached = [self.module v2AttachWorkspaceProject:@{
      @"schema_version" : @1,
      @"operation_id" : @"33333333-3333-4333-8333-333333333333",
      @"root" : root,
      @"mode" : @"init",
    } error:&error];
    XCTAssertNotNil(attached, @"%@", error);
    projectRoot[@"project_id"] = [attached[@"project"][@"project_id"] copy];
  }
  self.projectRoot = projectRoot;
}

- (void)tearDown {
  if (self.projectRoot != nil) {
    (void)DSHGitDeleteCredentialForScope(self.projectRoot[@"project_id"], @"github.com", nil);
  }
  self.module = nil;
  [NSFileManager.defaultManager removeItemAtURL:self.privateRoot error:nil];
  [NSFileManager.defaultManager removeItemAtURL:self.documentsRoot error:nil];
  [super tearDown];
}

/// Runs one bridge method synchronously; the resolved value, or nil with the
/// rejection code in `codeOut`.
- (id)bridge:(void (^)(RV2Resolve resolve, RV2Reject reject))operation code:(NSString **)codeOut {
  return [self bridge:operation code:codeOut step:@"bridge call"];
}

- (id)bridge:(void (^)(RV2Resolve resolve, RV2Reject reject))operation code:(NSString **)codeOut step:(NSString *)step {
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  __block id resolved = nil;
  __block NSString *code = nil;
  operation(^(id result) { resolved = result; dispatch_semaphore_signal(done); },
            ^(NSString *rejectCode, __unused NSString *message, __unused NSError *error) {
              code = rejectCode; dispatch_semaphore_signal(done);
            });
  XCTAssertEqual(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)), 0L,
                 @"%@ did not settle", step);
  if (codeOut != nil) *codeOut = code;
  return resolved;
}

- (NSDictionary *)request {
  return @{ @"schema_version" : @1, @"root" : self.projectRoot };
}

- (NSDictionary *)requestWith:(NSDictionary *)fields {
  NSMutableDictionary *request = [[self request] mutableCopy];
  [request addEntriesFromDictionary:fields];
  return request;
}

- (void)testOriginIsJudgedSetAndReadBackByRoot {
  NSString *code = nil;
  NSDictionary *none = [self bridge:^(RV2Resolve resolve, RV2Reject reject) {
    [self.module remoteV2Request:[self request] resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertNotNil(none, @"%@", code);
  XCTAssertEqualObjects(none[@"url"], NSNull.null);
  XCTAssertEqualObjects(none[@"host"], NSNull.null);
  XCTAssertEqualObjects(none[@"root"], self.projectRoot);

  for (NSString *bad in @[ @"ftp://example.com/x.git", @"https://user:pw@example.com/x.git",
                           @"https://example.com/x.git?y=1", @"http://example.com/x.git",
                           @"https://localhost/x.git", @"https://example.com:8443/x.git" ]) {
    id rejected = [self bridge:^(RV2Resolve resolve, RV2Reject reject) {
      [self.module setRemoteV2Request:[self requestWith:@{ @"url" : bad }] resolver:resolve rejecter:reject];
    } code:&code];
    XCTAssertNil(rejected, @"%@", bad);
    XCTAssertEqualObjects(code, @"E_PROJECT_REQUEST_INVALID", @"%@", bad);
  }

  NSDictionary *set = [self bridge:^(RV2Resolve resolve, RV2Reject reject) {
    [self.module setRemoteV2Request:[self requestWith:@{ @"url" : @"HTTPS://GitHub.com/example/demo.git" }]
                           resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertNotNil(set, @"%@", code);
  XCTAssertEqualObjects(set[@"url"], @"https://github.com/example/demo.git");
  XCTAssertEqualObjects(set[@"host"], @"github.com");
  XCTAssertEqualObjects(set[@"remote"], @"origin");
  XCTAssertEqualObjects(set[@"schema_version"], @2);

  NSDictionary *read = [self bridge:^(RV2Resolve resolve, RV2Reject reject) {
    [self.module remoteV2Request:[self request] resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertEqualObjects(read[@"url"], @"https://github.com/example/demo.git");

  // A private literal over plain http is the local test remote.
  NSDictionary *lan = [self bridge:^(RV2Resolve resolve, RV2Reject reject) {
    [self.module setRemoteV2Request:[self requestWith:@{ @"url" : @"http://127.0.0.1:8765/target.git" }]
                           resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertEqualObjects(lan[@"url"], @"http://127.0.0.1:8765/target.git");
  XCTAssertEqualObjects(lan[@"host"], @"127.0.0.1");
}

- (void)testCredentialIsProvisionedNativelyScopedToTheHostAndNeverEchoed {
  NSString *code = nil;
  id noOrigin = [self bridge:^(RV2Resolve resolve, RV2Reject reject) {
    [self.module credentialStatusV2Request:[self request] resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertNil(noOrigin);
  XCTAssertEqualObjects(code, @"E_WORKSPACE_CONFIRMATION");  // 3112: no origin yet

  [self bridge:^(RV2Resolve resolve, RV2Reject reject) {
    [self.module setRemoteV2Request:[self requestWith:@{ @"url" : @"https://github.com/example/demo.git" }]
                           resolver:resolve rejecter:reject];
  } code:&code];
  NSDictionary *absent = [self bridge:^(RV2Resolve resolve, RV2Reject reject) {
    [self.module credentialStatusV2Request:[self request] resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertNotNil(absent, @"%@", code);
  XCTAssertEqualObjects(absent[@"configured"], @NO);
  XCTAssertEqualObjects(absent[@"host"], @"github.com");
  XCTAssertNil(absent[@"expires_at"]);

  // The prompt seam: what the dialog would have collected.
  NSMutableDictionary *seen = [NSMutableDictionary dictionary];
  id hook = ^(NSString *host, BOOL chinese, BOOL plaintext,
              void (^completion)(NSString *, NSString *, NSInteger, NSString *)) {
    seen[@"host"] = host; seen[@"chinese"] = @(chinese); seen[@"plaintext"] = @(plaintext);
    completion(@"octocat", @"ghp_secret", DSHGitCredentialExpiryOneHour, nil);
  };
  [self.module setValue:hook forKey:@"credentialPromptHook"];
  NSDictionary *provisioned = [self bridge:^(RV2Resolve resolve, RV2Reject reject) {
    [self.module presentCredentialPromptV2Request:[self requestWith:@{ @"locale" : @"zh-CN" }]
                                         resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertNotNil(provisioned, @"%@", code);
  XCTAssertEqualObjects(seen[@"host"], @"github.com");
  XCTAssertEqualObjects(seen[@"chinese"], @YES);
  XCTAssertEqualObjects(seen[@"plaintext"], @NO);
  XCTAssertEqualObjects(provisioned[@"configured"], @YES);
  XCTAssertEqualObjects(provisioned[@"expiry_seconds"], @(DSHGitCredentialExpiryOneHour));
  XCTAssertEqualObjects(provisioned[@"root"], self.projectRoot);
  XCTAssertNil(provisioned[@"username"]);
  XCTAssertNil(provisioned[@"token"]);

  // Cancelling the prompt is a refusal with the cancelled code, not a status.
  id cancelling = ^(__unused NSString *host, __unused BOOL chinese, __unused BOOL plaintext,
                    void (^completion)(NSString *, NSString *, NSInteger, NSString *)) {
    completion(nil, nil, 0, @"cancelled");
  };
  [self.module setValue:cancelling forKey:@"credentialPromptHook"];
  id cancelled = [self bridge:^(RV2Resolve resolve, RV2Reject reject) {
    [self.module presentCredentialPromptV2Request:[self requestWith:@{ @"locale" : @"en" }]
                                         resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertNil(cancelled);
  XCTAssertEqualObjects(code, @"E_PROJECT_CANCELLED");
  id badLocale = [self bridge:^(RV2Resolve resolve, RV2Reject reject) {
    [self.module presentCredentialPromptV2Request:[self requestWith:@{ @"locale" : @"fr" }]
                                         resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertNil(badLocale);
  XCTAssertEqualObjects(code, @"E_PROJECT_REQUEST_INVALID");

  NSDictionary *cleared = [self bridge:^(RV2Resolve resolve, RV2Reject reject) {
    [self.module clearCredentialV2Request:[self request] resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertNotNil(cleared, @"%@", code);
  XCTAssertEqualObjects(cleared[@"configured"], @NO);
  XCTAssertNil(DSHGitCredentialForScope(self.projectRoot[@"project_id"], @"github.com", nil));
}

- (void)testPushRefusesWhatItCannotProveBeforeItConnectsAndCancelAnswersByRoot {
  NSString *code = nil;
  NSString *operationId = @"44444444-4444-4444-8444-444444444444";
  NSDictionary *push = [self requestWith:@{
    @"operation_id" : operationId, @"remote" : @"origin",
    @"expected_local_oid" : [@"" stringByPaddingToLength:40 withString:@"a" startingAtIndex:0],
    @"credential_reference" : @"panel", @"https_proxy_url" : NSNull.null,
  }];
  // Unborn HEAD: nothing to push, refused as a changed head.
  id unborn = [self bridge:^(RV2Resolve resolve, RV2Reject reject) {
    [self.module pushV2Request:push resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertNil(unborn);
  XCTAssertEqualObjects(code, @"E_PROJECT_CONFLICT");  // 3110

  NSDictionary *idle = [self bridge:^(RV2Resolve resolve, RV2Reject reject) {
    [self.module cancelPushV2Request:[self requestWith:@{ @"operation_id" : operationId }]
                            resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertNotNil(idle, @"%@", code);
  XCTAssertEqualObjects(idle[@"status"], @"not_running");
  XCTAssertEqualObjects(idle[@"operation_id"], operationId);
  XCTAssertEqualObjects(idle[@"root"], self.projectRoot);
  id badCancel = [self bridge:^(RV2Resolve resolve, RV2Reject reject) {
    [self.module cancelPushV2Request:[self requestWith:@{ @"operation_id" : @"nope" }]
                            resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertNil(badCancel);
  XCTAssertEqualObjects(code, @"E_PROJECT_REQUEST_INVALID");
}


// MARK: - fetch and fast-forward

/// One commit of `path` = `content` on HEAD of `repository`; the new oid.
static NSString *RV2Commit(git_repository *repository, NSString *path, NSString *content, NSString *message) {
  NSString *workdir = [NSString stringWithUTF8String:git_repository_workdir(repository)];
  NSString *file = [workdir stringByAppendingPathComponent:path];
  [[content dataUsingEncoding:NSUTF8StringEncoding] writeToFile:file atomically:YES];
  git_index *index = nullptr;
  git_oid treeId = {}, commitId = {};
  git_tree *tree = nullptr;
  git_signature *who = nullptr;
  git_reference *head = nullptr;
  git_commit *parent = nullptr;
  int code = git_repository_index(&index, repository);
  if (code == 0) code = git_index_add_bypath(index, path.UTF8String);
  if (code == 0) code = git_index_write(index);
  if (code == 0) code = git_index_write_tree(&treeId, index);
  if (code == 0) code = git_tree_lookup(&tree, repository, &treeId);
  if (code == 0) code = git_signature_new(&who, "Rish", "rish@example.invalid", 1700000000, 0);
  if (code == 0 && git_repository_head(&head, repository) == 0 && head != nullptr) {
    code = git_commit_lookup(&parent, repository, git_reference_target(head));
  }
  const git_commit *parents[1] = { parent };
  if (code == 0) {
    code = git_commit_create(&commitId, repository, "HEAD", who, who, "UTF-8", message.UTF8String, tree,
                             parent == nullptr ? 0 : 1, parent == nullptr ? nullptr : parents);
  }
  NSString *oid = code == 0 ? [NSString stringWithUTF8String:({ char b[41] = {}; git_oid_tostr(b, sizeof b, &commitId); b; })] : nil;
  if (parent != nullptr) git_commit_free(parent);
  if (head != nullptr) git_reference_free(head);
  if (who != nullptr) git_signature_free(who);
  if (tree != nullptr) git_tree_free(tree);
  if (index != nullptr) git_index_free(index);
  return oid;
}

/// `git push origin main` over the local transport, no credential.
static BOOL RV2PushMain(git_repository *repository) {
  git_remote *remote = nullptr;
  if (git_remote_lookup(&remote, repository, "origin") != 0) return NO;
  char *spec = const_cast<char *>("refs/heads/main:refs/heads/main");
  git_strarray refspecs = { &spec, 1 };
  git_push_options options = GIT_PUSH_OPTIONS_INIT;
  const int code = git_remote_push(remote, &refspecs, &options);
  git_remote_free(remote);
  return code == 0;
}

- (void)testFetchAndFastForwardMoveTheBranchOnlyWhenThatIsSafe {
  NSError *error = nil;
  NSString *code = nil;
  NSString *scratch = [NSTemporaryDirectory() stringByAppendingPathComponent:
      [NSString stringWithFormat:@"rish-ff-%@", NSUUID.UUID.UUIDString.lowercaseString]];
  NSString *barePath = [scratch stringByAppendingPathComponent:@"origin.git"];
  NSString *peerPath = [scratch stringByAppendingPathComponent:@"peer"];
  // A bare origin whose HEAD names `main`, so a clone of it lands on the
  // branch the project pushes.
  git_repository *bare = nullptr;
  git_repository_init_options bareOptions = GIT_REPOSITORY_INIT_OPTIONS_INIT;
  bareOptions.flags = GIT_REPOSITORY_INIT_BARE | GIT_REPOSITORY_INIT_MKPATH;
  bareOptions.initial_head = "main";
  XCTAssertEqual(git_repository_init_ext(&bare, barePath.UTF8String, &bareOptions), 0);
  git_repository_free(bare);

  // The project: origin is the bare path, one commit pushed there.
  NSString *first = nil;
  @autoreleasepool {
    __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *lease = [self.projectAccess
        leaseWorkspaceRootRef:self.projectRoot mode:DSHLocalProjectAccessModeWrite includeMetadata:NO timeout:1 error:&error];
    XCTAssertNotNil(lease, @"%@", error);
    git_remote *remote = nullptr;
    XCTAssertEqual(git_remote_create(&remote, lease.repository, "origin", barePath.UTF8String), 0);
    git_remote_free(remote);
    first = RV2Commit(lease.repository, @"shared.txt", @"one\n", @"first");
    XCTAssertNotNil(first);
    XCTAssertTrue(RV2PushMain(lease.repository));
  }
  // libgit2's push over the local transport updates the tracking reference
  // itself, so the branch is already at the tip it just pushed: nothing to do.
  NSDictionary *early = [self bridge:^(RV2Resolve resolve, RV2Reject reject) {
    [self.module pullFastForwardV2Request:[self requestWith:@{ @"expected_head_oid" : first }] resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertNotNil(early, @"%@", code);
  XCTAssertEqualObjects(early[@"updated"], @NO);
  XCTAssertEqualObjects(early[@"oid"], first);

  // A peer clones the origin and moves the branch on.
  git_repository *peer = nullptr;
  XCTAssertEqual(git_clone(&peer, barePath.UTF8String, peerPath.UTF8String, nullptr), 0);
  NSString *second = RV2Commit(peer, @"shared.txt", @"two\n", @"second");
  XCTAssertNotNil(second);
  XCTAssertTrue(RV2PushMain(peer));
  git_repository_free(peer);

  NSDictionary *fetched = [self bridge:^(RV2Resolve resolve, RV2Reject reject) {
    [self.module fetchV2Request:[self requestWith:@{
      @"operation_id" : @"44444444-4444-4444-8444-444444444444", @"remote" : @"origin" }] resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertNotNil(fetched, @"%@", code);
  XCTAssertEqualObjects(fetched[@"branch"], @"main");
  XCTAssertEqualObjects(fetched[@"remote_oid"], second);
  XCTAssertEqualObjects(fetched[@"ahead"], @0);
  XCTAssertEqualObjects(fetched[@"behind"], @1);
  XCTAssertEqualObjects(fetched[@"root"], self.projectRoot);

  // A changed tracked file is the person's: refused before anything moves.
  NSString *workspaceFile = nil;
  @autoreleasepool {
    __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *lease = [self.projectAccess
        leaseWorkspaceRootRef:self.projectRoot mode:DSHLocalProjectAccessModeWrite includeMetadata:NO timeout:1 error:&error];
    workspaceFile = [[NSString stringWithUTF8String:git_repository_workdir(lease.repository)] stringByAppendingPathComponent:@"shared.txt"];
  }
  [[@"mine\n" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:workspaceFile atomically:YES];
  id dirty = [self bridge:^(RV2Resolve resolve, RV2Reject reject) {
    [self.module pullFastForwardV2Request:[self requestWith:@{ @"expected_head_oid" : first }] resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertNil(dirty);
  XCTAssertEqualObjects(code, @"E_PROJECT_CONFLICT");
  [[@"one\n" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:workspaceFile atomically:YES];
  id stale = [self bridge:^(RV2Resolve resolve, RV2Reject reject) {
    [self.module pullFastForwardV2Request:[self requestWith:@{ @"expected_head_oid" : second }] resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertNil(stale);
  XCTAssertEqualObjects(code, @"E_PROJECT_CONFLICT");  // HEAD is `first`, not `second`

  NSDictionary *pulled = [self bridge:^(RV2Resolve resolve, RV2Reject reject) {
    [self.module pullFastForwardV2Request:[self requestWith:@{ @"expected_head_oid" : first }] resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertNotNil(pulled, @"%@", code);
  XCTAssertEqualObjects(pulled[@"updated"], @YES);
  XCTAssertEqualObjects(pulled[@"oid"], second);
  XCTAssertEqualObjects(pulled[@"previous_oid"], first);
  XCTAssertEqualObjects([NSString stringWithContentsOfFile:workspaceFile encoding:NSUTF8StringEncoding error:nil], @"two\n");
  NSDictionary *again = [self bridge:^(RV2Resolve resolve, RV2Reject reject) {
    [self.module pullFastForwardV2Request:[self requestWith:@{ @"expected_head_oid" : second }] resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertEqualObjects(again[@"updated"], @NO);

  // Both sides move: diverged, refused as non-fast-forward.
  @autoreleasepool {
    __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *lease = [self.projectAccess
        leaseWorkspaceRootRef:self.projectRoot mode:DSHLocalProjectAccessModeWrite includeMetadata:NO timeout:1 error:&error];
    XCTAssertNotNil(RV2Commit(lease.repository, @"local.txt", @"local\n", @"local third"));
  }
  XCTAssertEqual(git_repository_open(&peer, peerPath.UTF8String), 0);
  XCTAssertNotNil(RV2Commit(peer, @"shared.txt", @"three\n", @"peer third"));
  XCTAssertTrue(RV2PushMain(peer));
  git_repository_free(peer);
  NSDictionary *diverged = [self bridge:^(RV2Resolve resolve, RV2Reject reject) {
    [self.module fetchV2Request:[self requestWith:@{
      @"operation_id" : @"55555555-5555-4555-8555-555555555555", @"remote" : @"origin" }] resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertEqualObjects(diverged[@"ahead"], @1);
  XCTAssertEqualObjects(diverged[@"behind"], @1);
  NSString *localHead = nil;
  @autoreleasepool {
    __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *lease = [self.projectAccess
        leaseWorkspaceRootRef:self.projectRoot mode:DSHLocalProjectAccessModeRead includeMetadata:NO timeout:1 error:&error];
    git_reference *head = nullptr;
    XCTAssertEqual(git_repository_head(&head, lease.repository), 0);
    char b[41] = {}; git_oid_tostr(b, sizeof b, git_reference_target(head)); localHead = [NSString stringWithUTF8String:b];
    git_reference_free(head);
  }
  id refused = [self bridge:^(RV2Resolve resolve, RV2Reject reject) {
    [self.module pullFastForwardV2Request:[self requestWith:@{ @"expected_head_oid" : localHead }] resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertNil(refused);
  XCTAssertEqualObjects(code, @"E_PROJECT_NON_FAST_FORWARD");
  [NSFileManager.defaultManager removeItemAtPath:scratch error:nil];
}

@end
