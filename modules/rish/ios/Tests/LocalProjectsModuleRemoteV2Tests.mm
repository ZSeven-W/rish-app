// The remote half of the V2 Git bridge on a workspace project: origin set
// and read back by root, a credential provisioned through the native prompt
// seam and reported as status only, cleared again, and a push that refuses
// what it cannot prove before it connects. No network; the wire is covered
// by GitPushG2Tests through scripts/g2-acceptance.rb.

#import "LocalProjectsModuleV2TestSupport.h"
#import "../../../../modules/rish/ios/Sources/DSHGitPushSupport.h"
#include <git2.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>

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
- (void)pushReceiptsV2Request:(id)request resolver:(RV2Resolve)resolve rejecter:(RV2Reject)reject;
- (void)pullFastForwardV2Request:(id)request resolver:(RV2Resolve)resolve rejecter:(RV2Reject)reject;
- (void)mergeRemoteV2Request:(id)request resolver:(RV2Resolve)resolve rejecter:(RV2Reject)reject;
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
  // Generous: the proxy tests reach github.com, which from here has taken
  // over thirty seconds for one small fetch. A call that works settles long
  // before this; only a hang waits it out.
  XCTAssertEqual(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC)), 0L,
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
      @"operation_id" : @"44444444-4444-4444-8444-444444444444", @"remote" : @"origin", @"https_proxy_url" : NSNull.null }] resolver:resolve rejecter:reject];
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
      @"operation_id" : @"55555555-5555-4555-8555-555555555555", @"remote" : @"origin", @"https_proxy_url" : NSNull.null }] resolver:resolve rejecter:reject];
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


// A fast-forward never overwrites a file the person keeps out of Git.
//
// GIT_CHECKOUT_SAFE protects tracked changes and untracked files but not
// ignored ones: if the incoming commit starts tracking a path ignored here,
// the checkout wrote straight over it, and nothing in the cleanliness check
// saw it because status does not list ignored files. Reproduced on Android
// first, where the pull answered `updated` over the person's own file.
- (void)testAFastForwardNeverOverwritesAnIgnoredLocalFile {
  NSError *error = nil;
  NSString *code = nil;
  NSString *scratch = [NSTemporaryDirectory() stringByAppendingPathComponent:
      [NSString stringWithFormat:@"rish-ffi-%@", NSUUID.UUID.UUIDString.lowercaseString]];
  NSString *barePath = [scratch stringByAppendingPathComponent:@"origin.git"];
  NSString *peerPath = [scratch stringByAppendingPathComponent:@"peer"];
  git_repository *bare = nullptr;
  git_repository_init_options bareOptions = GIT_REPOSITORY_INIT_OPTIONS_INIT;
  bareOptions.flags = GIT_REPOSITORY_INIT_BARE | GIT_REPOSITORY_INIT_MKPATH;
  bareOptions.initial_head = "main";
  XCTAssertEqual(git_repository_init_ext(&bare, barePath.UTF8String, &bareOptions), 0);
  git_repository_free(bare);

  // The project ignores local.cfg, and keeps one of its own.
  NSString *ignoring = nil;
  NSString *localFile = nil;
  @autoreleasepool {
    __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *lease = [self.projectAccess
        leaseWorkspaceRootRef:self.projectRoot mode:DSHLocalProjectAccessModeWrite includeMetadata:NO timeout:1 error:&error];
    XCTAssertNotNil(lease, @"%@", error);
    git_remote *remote = nullptr;
    XCTAssertEqual(git_remote_create(&remote, lease.repository, "origin", barePath.UTF8String), 0);
    git_remote_free(remote);
    ignoring = RV2Commit(lease.repository, @".gitignore", @"local.cfg\n", @"ignore local.cfg");
    XCTAssertNotNil(ignoring);
    XCTAssertTrue(RV2PushMain(lease.repository));
    localFile = [[NSString stringWithUTF8String:git_repository_workdir(lease.repository)]
        stringByAppendingPathComponent:@"local.cfg"];
  }
  [[@"mine\n" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:localFile atomically:YES];

  // A peer starts tracking the very path the project ignores.
  git_repository *peer = nullptr;
  XCTAssertEqual(git_clone(&peer, barePath.UTF8String, peerPath.UTF8String, nullptr), 0);
  XCTAssertNotNil(RV2Commit(peer, @"local.cfg", @"theirs\n", @"track local.cfg"));
  XCTAssertTrue(RV2PushMain(peer));
  git_repository_free(peer);

  NSDictionary *fetched = [self bridge:^(RV2Resolve resolve, RV2Reject reject) {
    [self.module fetchV2Request:[self requestWith:@{
      @"operation_id" : @"66666666-6666-4666-8666-666666666666", @"remote" : @"origin", @"https_proxy_url" : NSNull.null }] resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertEqualObjects(fetched[@"behind"], @1, @"%@", code);

  id pulled = [self bridge:^(RV2Resolve resolve, RV2Reject reject) {
    [self.module pullFastForwardV2Request:[self requestWith:@{ @"expected_head_oid" : ignoring }] resolver:resolve rejecter:reject];
  } code:&code];
  // Refused, and the person's file is exactly as they left it.
  XCTAssertNil(pulled);
  XCTAssertEqualObjects(code, @"E_PROJECT_CONFLICT");
  XCTAssertEqualObjects([NSString stringWithContentsOfFile:localFile encoding:NSUTF8StringEncoding error:nil], @"mine\n");
  [NSFileManager.defaultManager removeItemAtPath:scratch error:nil];
}

- (void)testPushReceiptsAreReadByRootAndSanitized {
  NSString *code = nil;
  NSDictionary *none = [self bridge:^(RV2Resolve resolve, RV2Reject reject) {
    [self.module pushReceiptsV2Request:[self request] resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertNotNil(none, @"%@", code);
  XCTAssertEqualObjects(none[@"receipts"], @[]);
  XCTAssertEqualObjects(none[@"root"], self.projectRoot);
  NSError *error = nil;
  @autoreleasepool {
    __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *lease = [self.projectAccess
        leaseWorkspaceRootRef:self.projectRoot mode:DSHLocalProjectAccessModeWrite includeMetadata:NO timeout:1 error:&error];
    XCTAssertNotNil(lease, @"%@", error);
    NSString *a = [@"" stringByPaddingToLength:40 withString:@"a" startingAtIndex:0];
    NSString *b = [@"" stringByPaddingToLength:40 withString:@"b" startingAtIndex:0];
    XCTAssertTrue(DSHGitPushRecordReceipt(lease.gitDescriptor, self.projectRoot[@"project_id"],
        DSHGitPushReceipt(@"github.com", @"main", a, b, @"2026-09-21T00:00:00.000Z"), &error), @"%@", error);
  }
  NSDictionary *one = [self bridge:^(RV2Resolve resolve, RV2Reject reject) {
    [self.module pushReceiptsV2Request:[self request] resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertNotNil(one, @"%@", code);
  NSArray *receipts = one[@"receipts"];
  XCTAssertEqual(receipts.count, 1u);
  XCTAssertEqualObjects(receipts[0][@"host"], @"github.com");
  XCTAssertEqualObjects(receipts[0][@"branch"], @"main");
  XCTAssertEqualObjects([[receipts[0] allKeys] sortedArrayUsingSelector:@selector(compare:)],
      (@[@"branch", @"host", @"local_oid", @"pushed_at", @"remote", @"remote_oid", @"schema_version"]));
}

// ---------------------------------------------------------------------------
// Merge after divergence. The merge itself is the shared C++ Android runs
// too (modules/rish/shared/git); these pin what iOS wraps around it: the
// lease, the journal in the private gitdir, recovery and the codes.

static NSString *RV2Hex(const git_oid *oid) {
  char b[41] = {};
  git_oid_tostr(b, sizeof b, oid);
  return [NSString stringWithUTF8String:b];
}

/// Builds a branch that has diverged from its upstream and fetches, so the
/// tracking ref is what a person would have reviewed. Answers ours, theirs
/// and the scratch directory. `peerFirst` runs in the peer before its commit.
- (NSDictionary *)divergedWithMine:(NSArray<NSString *> *)mine
                            theirs:(NSArray<NSString *> *)theirs
                         peerFirst:(void (^)(git_repository *peer))peerFirst {
  NSError *error = nil;
  NSString *code = nil;
  NSString *scratch = [NSTemporaryDirectory() stringByAppendingPathComponent:
      [NSString stringWithFormat:@"rish-merge-%@", NSUUID.UUID.UUIDString.lowercaseString]];
  NSString *barePath = [scratch stringByAppendingPathComponent:@"origin.git"];
  NSString *peerPath = [scratch stringByAppendingPathComponent:@"peer"];
  git_repository *bare = nullptr;
  git_repository_init_options bareOptions = GIT_REPOSITORY_INIT_OPTIONS_INIT;
  bareOptions.flags = GIT_REPOSITORY_INIT_BARE | GIT_REPOSITORY_INIT_MKPATH;
  bareOptions.initial_head = "main";
  XCTAssertEqual(git_repository_init_ext(&bare, barePath.UTF8String, &bareOptions), 0);
  git_repository_free(bare);
  @autoreleasepool {
    __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *lease = [self.projectAccess
        leaseWorkspaceRootRef:self.projectRoot mode:DSHLocalProjectAccessModeWrite includeMetadata:NO timeout:1 error:&error];
    XCTAssertNotNil(lease, @"%@", error);
    git_remote *remote = nullptr;
    XCTAssertEqual(git_remote_create(&remote, lease.repository, "origin", barePath.UTF8String), 0);
    git_remote_free(remote);
    XCTAssertNotNil(RV2Commit(lease.repository, @"shared.txt", @"base\n", @"base"));
    XCTAssertTrue(RV2PushMain(lease.repository));
  }
  git_repository *peer = nullptr;
  XCTAssertEqual(git_clone(&peer, barePath.UTF8String, peerPath.UTF8String, nullptr), 0);
  if (peerFirst != nil) peerFirst(peer);
  NSString *theirsOid = RV2Commit(peer, theirs[0], theirs[1], @"theirs");
  XCTAssertNotNil(theirsOid);
  XCTAssertTrue(RV2PushMain(peer));
  git_repository_free(peer);
  NSString *oursOid = nil;
  @autoreleasepool {
    __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *lease = [self.projectAccess
        leaseWorkspaceRootRef:self.projectRoot mode:DSHLocalProjectAccessModeWrite includeMetadata:NO timeout:1 error:&error];
    oursOid = RV2Commit(lease.repository, mine[0], mine[1], @"mine");
  }
  XCTAssertNotNil(oursOid);
  NSDictionary *fetched = [self bridge:^(RV2Resolve resolve, RV2Reject reject) {
    [self.module fetchV2Request:[self requestWith:@{
      @"operation_id" : NSUUID.UUID.UUIDString.lowercaseString, @"remote" : @"origin", @"https_proxy_url" : NSNull.null }] resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertEqualObjects(fetched[@"ahead"], @1, @"%@", code);
  XCTAssertEqualObjects(fetched[@"remote_oid"], theirsOid);
  return @{ @"ours" : oursOid ?: @"", @"theirs" : theirsOid ?: @"", @"scratch" : scratch };
}

- (NSDictionary *)mergeRequestOurs:(NSString *)ours theirs:(NSString *)theirs {
  return [self requestWith:@{
    @"operation_id" : NSUUID.UUID.UUIDString.lowercaseString, @"expected_branch" : @"main",
    @"expected_head_oid" : ours, @"expected_remote_oid" : theirs,
    @"author_name" : @"Rish Bot", @"author_email" : @"rish@example.invalid",
  }];
}

- (id)merge:(NSDictionary *)request code:(NSString **)code {
  return [self bridge:^(RV2Resolve resolve, RV2Reject reject) {
    [self.module mergeRemoteV2Request:request resolver:resolve rejecter:reject];
  } code:code step:@"merge"];
}

/// HEAD's oid, its parents, the workdir, and whether a journal or MERGE_HEAD exists.
- (NSDictionary *)repositoryFacts {
  NSError *error = nil;
  NSMutableDictionary *facts = [NSMutableDictionary dictionary];
  @autoreleasepool {
    __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *lease = [self.projectAccess
        leaseWorkspaceRootRef:self.projectRoot mode:DSHLocalProjectAccessModeRead includeMetadata:NO timeout:1 error:&error];
    XCTAssertNotNil(lease, @"%@", error);
    git_reference *head = nullptr;
    git_commit *commit = nullptr;
    if (git_repository_head(&head, lease.repository) == 0 &&
        git_commit_lookup(&commit, lease.repository, git_reference_target(head)) == 0) {
      facts[@"head"] = RV2Hex(git_reference_target(head));
      NSMutableArray *parents = [NSMutableArray array];
      for (unsigned int at = 0; at < git_commit_parentcount(commit); at += 1) {
        [parents addObject:RV2Hex(git_commit_parent_id(commit, at))];
      }
      facts[@"parents"] = parents;
    }
    if (commit != nullptr) git_commit_free(commit);
    if (head != nullptr) git_reference_free(head);
    facts[@"workdir"] = [NSString stringWithUTF8String:git_repository_workdir(lease.repository)];
    facts[@"journal"] = @(faccessat(lease.gitDescriptor, "rish-merge.json", F_OK, 0) == 0);
    facts[@"merge_head"] = @(faccessat(lease.gitDescriptor, "MERGE_HEAD", F_OK, 0) == 0);
    git_status_options options = GIT_STATUS_OPTIONS_INIT;
    options.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR;
    git_status_list *list = nullptr;
    size_t changed = 0;
    if (git_status_list_new(&list, lease.repository, &options) == 0) {
      for (size_t at = 0; at < git_status_list_entrycount(list); at += 1) {
        if ((git_status_byindex(list, at)->status & ~GIT_STATUS_WT_NEW) != 0) changed += 1;
      }
      git_status_list_free(list);
    }
    facts[@"changed"] = @(changed);
  }
  return facts;
}

- (NSString *)workFile:(NSString *)name {
  NSString *path = [[self repositoryFacts][@"workdir"] stringByAppendingPathComponent:name];
  return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
}

- (void)testACleanDivergenceIsMergedWithTheBranchFirstAndTheUpstreamSecond {
  NSDictionary *d = [self divergedWithMine:@[@"mine.txt", @"mine\n"] theirs:@[@"theirs.txt", @"theirs\n"] peerFirst:nil];
  NSString *code = nil;
  NSDictionary *merged = [self merge:[self mergeRequestOurs:d[@"ours"] theirs:d[@"theirs"]] code:&code];
  XCTAssertEqualObjects(merged[@"outcome"], @"merged", @"%@", code);
  XCTAssertEqualObjects(merged[@"previous_oid"], d[@"ours"]);
  XCTAssertEqualObjects(merged[@"branch"], @"main");
  XCTAssertEqualObjects(merged[@"root"], self.projectRoot);
  NSDictionary *facts = [self repositoryFacts];
  XCTAssertEqualObjects(facts[@"head"], merged[@"oid"]);
  XCTAssertEqualObjects(facts[@"parents"], (@[d[@"ours"], d[@"theirs"]]));
  XCTAssertEqualObjects(facts[@"journal"], @NO);
  XCTAssertEqualObjects(facts[@"changed"], @0);
  XCTAssertEqualObjects([self workFile:@"mine.txt"], @"mine\n");
  XCTAssertEqualObjects([self workFile:@"theirs.txt"], @"theirs\n");
  [NSFileManager.defaultManager removeItemAtPath:d[@"scratch"] error:nil];
}

// The same change on both sides leaves the merge's tree equal to ours; it
// is still a merge, not an interruption.
- (void)testTheSameChangeOnBothSidesIsMergedNotMistakenForAnInterruption {
  NSDictionary *d = [self divergedWithMine:@[@"same.txt", @"same\n"] theirs:@[@"same.txt", @"same\n"] peerFirst:nil];
  NSString *code = nil;
  NSDictionary *merged = [self merge:[self mergeRequestOurs:d[@"ours"] theirs:d[@"theirs"]] code:&code];
  XCTAssertEqualObjects(merged[@"outcome"], @"merged", @"%@", code);
  NSDictionary *facts = [self repositoryFacts];
  XCTAssertEqualObjects(facts[@"parents"], (@[d[@"ours"], d[@"theirs"]]));
  XCTAssertEqualObjects(facts[@"journal"], @NO);
  [NSFileManager.defaultManager removeItemAtPath:d[@"scratch"] error:nil];
}

- (void)testAConflictIsAnsweredWithItsPathsAndWritesNothing {
  NSDictionary *d = [self divergedWithMine:@[@"shared.txt", @"mine\n"] theirs:@[@"shared.txt", @"theirs\n"] peerFirst:nil];
  NSString *code = nil;
  NSDictionary *answer = [self merge:[self mergeRequestOurs:d[@"ours"] theirs:d[@"theirs"]] code:&code];
  XCTAssertEqualObjects(answer[@"outcome"], @"conflicts", @"%@", code);
  XCTAssertEqualObjects(answer[@"oid"], d[@"ours"]);
  NSDictionary *conflict = [answer[@"conflicts"] firstObject];
  XCTAssertEqualObjects(conflict[@"ours"], @"shared.txt");
  XCTAssertEqualObjects(conflict[@"theirs"], @"shared.txt");
  NSDictionary *facts = [self repositoryFacts];
  XCTAssertEqualObjects(facts[@"head"], d[@"ours"]);
  XCTAssertEqualObjects(facts[@"merge_head"], @NO);
  XCTAssertEqualObjects(facts[@"journal"], @NO);
  XCTAssertEqualObjects(facts[@"changed"], @0);
  XCTAssertEqualObjects([self workFile:@"shared.txt"], @"mine\n");
  [NSFileManager.defaultManager removeItemAtPath:d[@"scratch"] error:nil];
}

- (void)testAnIgnoredFileInTheWayIsReportedAndKept {
  NSDictionary *d = [self divergedWithMine:@[@".gitignore", @"local.cfg\n"] theirs:@[@"local.cfg", @"theirs\n"] peerFirst:nil];
  NSString *local = [[self repositoryFacts][@"workdir"] stringByAppendingPathComponent:@"local.cfg"];
  [[@"mine\n" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:local atomically:YES];
  NSString *code = nil;
  NSDictionary *answer = [self merge:[self mergeRequestOurs:d[@"ours"] theirs:d[@"theirs"]] code:&code];
  XCTAssertEqualObjects(answer[@"outcome"], @"obstructed", @"%@", code);
  XCTAssertEqualObjects(answer[@"paths"], (@[@"local.cfg"]));
  XCTAssertEqualObjects([NSString stringWithContentsOfFile:local encoding:NSUTF8StringEncoding error:nil], @"mine\n");
  XCTAssertEqualObjects([self repositoryFacts][@"head"], d[@"ours"]);
  [NSFileManager.defaultManager removeItemAtPath:d[@"scratch"] error:nil];
}

- (void)testWhatThePersonDidNotReviewIsRefused {
  NSDictionary *d = [self divergedWithMine:@[@"mine.txt", @"mine\n"] theirs:@[@"theirs.txt", @"theirs\n"] peerFirst:nil];
  NSString *elsewhere = [@"" stringByPaddingToLength:40 withString:@"0" startingAtIndex:0];
  NSString *code = nil;
  XCTAssertNil([self merge:[self mergeRequestOurs:elsewhere theirs:d[@"theirs"]] code:&code]);
  XCTAssertEqualObjects(code, @"E_PROJECT_CONFLICT");
  XCTAssertNil([self merge:[self mergeRequestOurs:d[@"ours"] theirs:elsewhere] code:&code]);
  XCTAssertEqualObjects(code, @"E_WORKSPACE_CONFIRMATION");
  NSMutableDictionary *other = [[self mergeRequestOurs:d[@"ours"] theirs:d[@"theirs"]] mutableCopy];
  other[@"expected_branch"] = @"feature";
  XCTAssertNil([self merge:other code:&code]);
  XCTAssertEqualObjects(code, @"E_PROJECT_CONFLICT");
  for (NSDictionary *change in @[
         @{ @"author_name" : @" Rish" }, @{ @"author_name" : @"Rish <bot>" }, @{ @"author_email" : @"rish" },
         @{ @"expected_branch" : @"refs/heads/main" }, @{ @"expected_head_oid" : @"abc" }, @{ @"force" : @YES },
       ]) {
    NSMutableDictionary *bad = [[self mergeRequestOurs:d[@"ours"] theirs:d[@"theirs"]] mutableCopy];
    [bad addEntriesFromDictionary:change];
    XCTAssertNil([self merge:bad code:&code]);
    XCTAssertEqualObjects(code, @"E_PROJECT_REQUEST_INVALID", @"%@", change);
  }
  XCTAssertEqualObjects([self repositoryFacts][@"head"], d[@"ours"]);
  [NSFileManager.defaultManager removeItemAtPath:d[@"scratch"] error:nil];
}

- (void)testAFilteredPathIsRefusedAsUnsupported {
  NSDictionary *d = [self divergedWithMine:@[@"mine.txt", @"mine\n"]
                                    theirs:@[@"data.bin", @"version https://git-lfs.github.com/spec/v1\n"]
                                 peerFirst:^(git_repository *peer) {
    XCTAssertNotNil(RV2Commit(peer, @".gitattributes", @"*.bin filter=lfs diff=lfs merge=lfs\n", @"lfs"));
  }];
  NSString *code = nil;
  XCTAssertNil([self merge:[self mergeRequestOurs:d[@"ours"] theirs:d[@"theirs"]] code:&code]);
  XCTAssertEqualObjects(code, @"E_PROJECT_MERGE_UNSUPPORTED");
  XCTAssertNil([self workFile:@"data.bin"]);
  [NSFileManager.defaultManager removeItemAtPath:d[@"scratch"] error:nil];
}

/// Writes a journal as the merge would have before it was interrupted.
- (void)writeJournal:(NSData *)data {
  NSError *error = nil;
  @autoreleasepool {
    __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *lease = [self.projectAccess
        leaseWorkspaceRootRef:self.projectRoot mode:DSHLocalProjectAccessModeWrite includeMetadata:NO timeout:1 error:&error];
    int descriptor = openat(lease.gitDescriptor, "rish-merge.json", O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    XCTAssertGreaterThanOrEqual(descriptor, 0);
    XCTAssertEqual(write(descriptor, data.bytes, data.length), (ssize_t)data.length);
    close(descriptor);
  }
}

// Interrupted after the checkout but before the branch moved: the files and
// the index are the merge, HEAD is still ours. The next merge finishes it.
// A journal that cannot be read, or a state it does not describe, is kept
// and refused -- never reset.
- (void)testRecoveryFinishesAnInterruptedMoveAndKeepsWhatItCannotRead {
  NSDictionary *d = [self divergedWithMine:@[@"mine.txt", @"mine\n"] theirs:@[@"theirs.txt", @"theirs\n"] peerFirst:nil];
  NSString *code = nil;
  NSDictionary *merged = [self merge:[self mergeRequestOurs:d[@"ours"] theirs:d[@"theirs"]] code:&code];
  XCTAssertEqualObjects(merged[@"outcome"], @"merged", @"%@", code);
  NSString *mergeOid = merged[@"oid"];
  NSError *error = nil;
  @autoreleasepool {
    __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *lease = [self.projectAccess
        leaseWorkspaceRootRef:self.projectRoot mode:DSHLocalProjectAccessModeWrite includeMetadata:NO timeout:1 error:&error];
    git_reference *head = nullptr;
    git_reference *moved = nullptr;
    git_oid ours;
    XCTAssertEqual(git_oid_fromstr(&ours, [d[@"ours"] UTF8String]), 0);
    XCTAssertEqual(git_repository_head(&head, lease.repository), 0);
    XCTAssertEqual(git_reference_set_target(&moved, head, &ours, "test: interrupted"), 0);
    git_reference_free(moved);
    git_reference_free(head);
  }
  NSDictionary *journal = @{
    @"schema_version" : @1, @"operation_id" : NSUUID.UUID.UUIDString.lowercaseString, @"branch" : @"main",
    @"ours" : d[@"ours"], @"theirs" : d[@"theirs"], @"merge_oid" : mergeOid, @"tree_oid" : mergeOid,
    @"phase" : @"applying", @"created_at" : @"2026-09-23T00:00:00.000Z",
  };
  [self writeJournal:[NSJSONSerialization dataWithJSONObject:journal options:0 error:nil]];
  // Recovery runs first, so the branch is the merge again, and the request
  // -- made against the merge -- finds nothing left to do.
  NSDictionary *after = [self merge:[self mergeRequestOurs:mergeOid theirs:d[@"theirs"]] code:&code];
  XCTAssertEqualObjects(after[@"outcome"], @"up_to_date", @"%@", code);
  XCTAssertEqualObjects([self repositoryFacts][@"head"], mergeOid);
  XCTAssertEqualObjects([self repositoryFacts][@"journal"], @NO);

  [self writeJournal:[@"not json" dataUsingEncoding:NSUTF8StringEncoding]];
  XCTAssertNil([self merge:[self mergeRequestOurs:mergeOid theirs:d[@"theirs"]] code:&code]);
  XCTAssertEqualObjects(code, @"E_PROJECT_RECOVERY_REQUIRED");
  XCTAssertEqualObjects([self repositoryFacts][@"journal"], @YES);

  // A journal naming commits the branch is at neither of.
  NSMutableDictionary *foreign = [journal mutableCopy];
  foreign[@"ours"] = d[@"theirs"];
  foreign[@"merge_oid"] = d[@"ours"];
  [self writeJournal:[NSJSONSerialization dataWithJSONObject:foreign options:0 error:nil]];
  XCTAssertNil([self merge:[self mergeRequestOurs:mergeOid theirs:d[@"theirs"]] code:&code]);
  XCTAssertEqualObjects(code, @"E_PROJECT_RECOVERY_REQUIRED");
  XCTAssertEqualObjects([self repositoryFacts][@"head"], mergeOid);
  XCTAssertEqualObjects([self repositoryFacts][@"journal"], @YES);
  [NSFileManager.defaultManager removeItemAtPath:d[@"scratch"] error:nil];
}

// ---------------------------------------------------------------------------
// The person's HTTPS proxy on fetch. Every connection goes through it, never
// around it; the positive leg runs against scripts/git-test-proxy.py, which
// counts every CONNECT (TEST_RUNNER_RISH_PROXY_BASE=http://127.0.0.1:N/).

/// One control request to the test proxy over a raw socket, its JSON body.
static NSDictionary *RV2ProxyControl(NSString *base, NSString *method, NSString *path) {
  NSURLComponents *url = [NSURLComponents componentsWithString:base];
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return nil;
  struct sockaddr_in address = {};
  address.sin_family = AF_INET;
  address.sin_port = htons((uint16_t)url.port.integerValue);
  inet_pton(AF_INET, url.host.UTF8String, &address.sin_addr);
  NSMutableData *reply = [NSMutableData data];
  if (connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0) {
    NSString *request = [NSString stringWithFormat:@"%@ %@ HTTP/1.1\r\nHost: proxy\r\nContent-Length: 0\r\n\r\n", method, path];
    const char *bytes = request.UTF8String;
    (void)write(fd, bytes, strlen(bytes));
    char buffer[4096];
    ssize_t count = 0;
    while ((count = read(fd, buffer, sizeof(buffer))) > 0) [reply appendBytes:buffer length:(NSUInteger)count];
  }
  close(fd);
  NSString *text = [[NSString alloc] initWithData:reply encoding:NSUTF8StringEncoding];
  NSRange split = [text rangeOfString:@"\r\n\r\n"];
  if (split.location == NSNotFound) return nil;
  NSData *body = [[text substringFromIndex:NSMaxRange(split)] dataUsingEncoding:NSUTF8StringEncoding];
  id value = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
  return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

- (NSDictionary *)fetchWithProxy:(id)proxy code:(NSString **)code {
  return [self bridge:^(RV2Resolve resolve, RV2Reject reject) {
    [self.module fetchV2Request:[self requestWith:@{
      @"operation_id" : NSUUID.UUID.UUIDString.lowercaseString, @"remote" : @"origin", @"https_proxy_url" : proxy,
    }] resolver:resolve rejecter:reject];
  } code:code];
}

- (void)testAFetchProxyIsJudgedAndNeverUsedForARemoteItCannotCarry {
  NSError *error = nil;
  NSString *code = nil;
  NSString *scratch = [NSTemporaryDirectory() stringByAppendingPathComponent:
      [NSString stringWithFormat:@"rish-proxy-%@", NSUUID.UUID.UUIDString.lowercaseString]];
  NSString *barePath = [scratch stringByAppendingPathComponent:@"origin.git"];
  git_repository *bare = nullptr;
  git_repository_init_options bareOptions = GIT_REPOSITORY_INIT_OPTIONS_INIT;
  bareOptions.flags = GIT_REPOSITORY_INIT_BARE | GIT_REPOSITORY_INIT_MKPATH;
  XCTAssertEqual(git_repository_init_ext(&bare, barePath.UTF8String, &bareOptions), 0);
  git_repository_free(bare);
  @autoreleasepool {
    __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *lease = [self.projectAccess
        leaseWorkspaceRootRef:self.projectRoot mode:DSHLocalProjectAccessModeWrite includeMetadata:NO timeout:1 error:&error];
    XCTAssertNotNil(lease, @"%@", error);
    git_remote *remote = nullptr;
    XCTAssertEqual(git_remote_create(&remote, lease.repository, "origin", barePath.UTF8String), 0);
    git_remote_free(remote);
    XCTAssertNotNil(RV2Commit(lease.repository, @"a.txt", @"a\n", @"first"));
  }
  for (NSString *bad in @[ @"proxy:3128", @"http://proxy.example.com", @"ftp://proxy.example.com:21",
                           @"http://u:p@proxy.example.com:8080", @"http://proxy.example.com:8080/x" ]) {
    XCTAssertNil([self fetchWithProxy:bad code:&code], @"%@", bad);
    XCTAssertEqualObjects(code, @"E_PROJECT_REQUEST_INVALID", @"%@", bad);
  }
  // A local-path origin (as a plain http or SSH one) would not go through an
  // HTTP proxy at all; with one set it is refused rather than fetched around it.
  XCTAssertNil([self fetchWithProxy:@"http://127.0.0.1:3128" code:&code]);
  XCTAssertEqualObjects(code, @"E_PROJECT_REQUEST_INVALID");
  // Without a proxy the same fetch works.
  XCTAssertNotNil([self fetchWithProxy:NSNull.null code:&code], @"%@", code);
  [NSFileManager.defaultManager removeItemAtPath:scratch error:nil];
}

- (void)testAFetchGoesThroughTheProxyAndNeverAroundIt {
  NSString *proxy = NSProcessInfo.processInfo.environment[@"RISH_PROXY_BASE"];
  if (proxy.length == 0) XCTSkip(@"no test proxy: set TEST_RUNNER_RISH_PROXY_BASE");
  if (RV2ProxyControl(proxy, @"POST", @"/__rish_mode?mode=tunnel") == nil) XCTSkip(@"the test proxy does not answer");
  NSString *code = nil;
  NSDictionary *set = [self bridge:^(RV2Resolve resolve, RV2Reject reject) {
    [self.module setRemoteV2Request:[self requestWith:@{ @"url" : @"https://github.com/octocat/Hello-World.git" }]
                           resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertNotNil(set, @"%@", code);
  @autoreleasepool {
    NSError *error = nil;
    __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *lease = [self.projectAccess
        leaseWorkspaceRootRef:self.projectRoot mode:DSHLocalProjectAccessModeWrite includeMetadata:NO timeout:1 error:&error];
    XCTAssertNotNil(RV2Commit(lease.repository, @"a.txt", @"a\n", @"first"));
  }
  NSInteger (^tunnels)(void) = ^NSInteger {
    return [RV2ProxyControl(proxy, @"GET", @"/__rish_stats")[@"connects"][@"github.com:443"] integerValue];
  };
  // A direct fetch first: GitHub is reachable, so what follows is about the proxy.
  if ([self fetchWithProxy:NSNull.null code:&code] == nil) XCTSkip(@"github.com is not reachable: %@", code);
  NSInteger before = tunnels();
  NSDictionary *fetched = [self fetchWithProxy:proxy code:&code];
  XCTAssertNotNil(fetched, @"%@", code);
  XCTAssertGreaterThan(tunnels(), before, @"the fetch did not go through the proxy");

  // Refused by the proxy: the fetch fails, and does not go around it -- a
  // direct fetch of this public repository would have succeeded.
  RV2ProxyControl(proxy, @"POST", @"/__rish_mode?mode=refuse");
  NSInteger refusedBefore = [RV2ProxyControl(proxy, @"GET", @"/__rish_stats")[@"refused"] integerValue];
  NSInteger tunnelsBefore = tunnels();
  XCTAssertNil([self fetchWithProxy:proxy code:&code]);
  RV2ProxyControl(proxy, @"POST", @"/__rish_mode?mode=tunnel");
  // Said as the proxy's failure, not a generic one.
  XCTAssertEqualObjects(code, @"E_PROJECT_PROXY");
  XCTAssertGreaterThan([RV2ProxyControl(proxy, @"GET", @"/__rish_stats")[@"refused"] integerValue], refusedBefore);
  XCTAssertEqual(tunnels(), tunnelsBefore);
  // A proxy nothing listens on is the proxy's failure too.
  XCTAssertNil([self fetchWithProxy:@"http://127.0.0.1:1/" code:&code]);
  XCTAssertEqualObjects(code, @"E_PROJECT_PROXY");
}

@end
