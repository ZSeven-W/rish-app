#import <XCTest/XCTest.h>

#import "../../../../modules/rish/ios/Sources/AgentExecutionLedger.h"
#import "../../../../modules/rish/ios/Sources/AgentGitToolExecutor.h"
#import "../../../../modules/rish/ios/Sources/DSHGitPushSupport.h"
#import "../../../../modules/rish/ios/Sources/AgentNativeWAL.h"
#import "../../../../modules/rish/ios/Sources/AgentPreparedAttemptStore.h"
#import "../../../../modules/rish/ios/Sources/AgentRootResolver.h"
#import "../../../../modules/rish/ios/Sources/AgentToolBatchService.h"
#import "../../../../modules/rish/ios/Sources/AgentToolExecutionService.h"
#import "../../../../modules/rish/ios/Sources/AgentToolRegistry.h"
#import "../../../../modules/rish/ios/Sources/AgentTranscriptStore.h"
#import "../../../../modules/rish/ios/Sources/AgentWorkspaceToolExecutor.h"
#import "../../../../modules/rish/ios/Sources/LocalProjectAccess.h"
#import "../../../../modules/rish/ios/Sources/LocalWorkspaceAccess.h"

#include <git2.h>
#include <unistd.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#import "../../../../modules/rish/ios/Sources/DSHAgentGuestCgiToolExecutor.h"
#import "../../../../modules/rish/ios/Sources/DSHCompletionV2.h"
#import "../../../../modules/rish/ios/Sources/AgentProviderRoundServiceInternals.h"
#import "../../../../modules/rish/ios/Sources/RishGuestCgiService.h"

@interface AgentEffectsCgiService : RishGuestCgiService
@property(nonatomic) NSUInteger starts;
@end
@implementation AgentEffectsCgiService
- (void)start:(NSDictionary *)request resolve:(RishGuestCgiResolve)resolve reject:(RishGuestCgiReject)reject {
  self.starts++;
  resolve(@{ @"service_id": @"11111111-1111-4111-8111-111111111111", @"url": @"http://127.0.0.1:12345/" });
}
@end

@interface AgentEffectsAuthorityGuard : DSHLocalWorkspaceAuthorityMutationGuard
@property(nonatomic, copy) dispatch_block_t onRelease;
@end

@implementation AgentEffectsAuthorityGuard
- (void)dealloc {
  if (self.onRelease != nil) self.onRelease();
}
@end

@interface AgentEffectsRootResolver : DSHAgentRootResolver
@property(nonatomic, copy) NSDictionary *frozenRoot;
@property(nonatomic) BOOL rejectRoot;
@property(nonatomic) BOOL guardAlive;
@property(nonatomic) NSUInteger guardValidationCount;
@end

/// Real executor tests use the production legacy project lease implementation
/// over temporary repositories.  Only root routing is substituted; Git
/// preparation, commit, push, callback handling, and recovery remain the
/// concrete DSHAgentGitToolExecutor implementation.
@interface AgentEffectsProjectLeaseResolver : DSHAgentRootResolver
@property(nonatomic, strong) DSHLocalProjectAccess *fixtureProjectAccess;
@property(nonatomic, copy) NSDictionary *fixtureRoot;
@property(nonatomic, copy) NSString *fixtureProjectID;
- (instancetype)initWithProjectAccess:(DSHLocalProjectAccess *)projectAccess
                                  root:(NSDictionary *)root;
@end

@implementation AgentEffectsProjectLeaseResolver
- (instancetype)initWithProjectAccess:(DSHLocalProjectAccess *)projectAccess
                                  root:(NSDictionary *)root {
  self = [super initWithWorkspaceAccess:
      (DSHLocalWorkspaceAccess *)(id)NSNull.null projectAccess:projectAccess];
  if (self != nil) {
    _fixtureProjectAccess = projectAccess;
    _fixtureRoot = [root copy];
    _fixtureProjectID = [root[@"project_id"] copy];
  }
  return self;
}
- (BOOL)validateFrozenRoot:(NSDictionary *)root error:(NSError **)error {
  if ([root isEqual:self.fixtureRoot]) return YES;
  DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorOwnerLost);
  return NO;
}
- (DSHLocalProjectLease *)projectLeaseForFrozenRoot:(NSDictionary *)root
                                               mode:(DSHLocalProjectAccessMode)mode
                                            timeout:(NSTimeInterval)timeout
                                              error:(NSError **)error {
  if (![self validateFrozenRoot:root error:error]) return nil;
  return [self.fixtureProjectAccess leaseProjectId:self.fixtureProjectID
                                              mode:mode
                                   includeMetadata:NO
                                           timeout:timeout
                                             error:error];
}
@end

@implementation AgentEffectsRootResolver
- (instancetype)initWithRoot:(NSDictionary *)root {
  self = [super initWithWorkspaceAccess:(DSHLocalWorkspaceAccess *)(id)NSNull.null
                           projectAccess:nil];
  if (self != nil) _frozenRoot = [root copy];
  return self;
}
- (BOOL)validateFrozenRoot:(NSDictionary *)root error:(NSError **)error {
  BOOL valid = !self.rejectRoot && [root isEqual:self.frozenRoot];
  if (!valid && error != nullptr) {
    *error = DSHAgentNativeStoreError(DSHAgentNativeStoreErrorOwnerLost);
  }
  return valid;
}
- (DSHLocalWorkspaceAuthorityMutationGuard *)
    acquireAuthorityMutationGuardForFrozenRoot:(NSDictionary *)root
                                         error:(NSError **)error {
  if (![self validateFrozenRoot:root error:error]) return nil;
  if (self.guardAlive) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorConflict);
    return nil;
  }
  self.guardAlive = YES;
  AgentEffectsAuthorityGuard *guard = [[AgentEffectsAuthorityGuard alloc] init];
  __weak AgentEffectsRootResolver *weakSelf = self;
  guard.onRelease = ^{
    weakSelf.guardAlive = NO;
  };
  return guard;
}
- (BOOL)validateFrozenRoot:(NSDictionary *)root
     authorityMutationGuard:(DSHLocalWorkspaceAuthorityMutationGuard *)guard
                      error:(NSError **)error {
  if (![guard isKindOfClass:AgentEffectsAuthorityGuard.class]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return NO;
  }
  if (!self.guardAlive) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorOwnerLost);
    return NO;
  }
  self.guardValidationCount += 1;
  return [self validateFrozenRoot:root error:error];
}
- (DSHLocalWorkspaceLease *)workspaceLeaseForFrozenRoot:(NSDictionary *)root
                           requiredWorkspaceCapabilities:(NSSet<NSString *> *)capabilities
                                                    error:(NSError **)error {
  (void)capabilities;
  return [self validateFrozenRoot:root error:error]
      ? (DSHLocalWorkspaceLease *)(id)NSNull.null : nil;
}
- (DSHLocalProjectLease *)projectLeaseForFrozenRoot:(NSDictionary *)root
                                               mode:(DSHLocalProjectAccessMode)mode
                                            timeout:(NSTimeInterval)timeout
                                              error:(NSError **)error {
  (void)mode; (void)timeout;
  return [self validateFrozenRoot:root error:error]
      ? (DSHLocalProjectLease *)(id)NSNull.null : nil;
}
@end

@interface AgentEffectsSessionStore : DSHSessionSnapshotStore
@property(nonatomic, copy) NSDictionary *fakeLoadResult;
@end

@implementation AgentEffectsSessionStore
- (instancetype)initWithLoadResult:(NSDictionary *)loadResult {
  NSURL *root = [NSURL fileURLWithPath:[NSTemporaryDirectory()
      stringByAppendingPathComponent:NSUUID.UUID.UUIDString.lowercaseString]];
  self = [super initWithRootURL:root];
  if (self != nil) _fakeLoadResult = [loadResult copy];
  return self;
}
- (NSDictionary *)loadSessionSnapshotWithError:(NSError **)error {
  if (error != nullptr) *error = nil;
  return self.fakeLoadResult;
}
@end

@interface AgentEffectsPreparedStore : DSHAgentPreparedAttemptStore
@property(nonatomic, copy) NSDictionary *authorityOverride;
@end

@implementation AgentEffectsPreparedStore
- (NSDictionary *)nativeAuthorityForTaskId:(NSString *)taskId
                                  attemptId:(NSString *)attemptId
                                      error:(NSError **)error {
  if (self.authorityOverride != nil) {
    if (error != nullptr) *error = nil;
    return self.authorityOverride;
  }
  return [super nativeAuthorityForTaskId:taskId attemptId:attemptId error:error];
}
@end

@interface AgentEffectsWorkspaceExecutor : DSHAgentWorkspaceToolExecutor
@property(nonatomic) NSUInteger effectCount;
@property(nonatomic) DSHAgentNativeStoreErrorCode prepareFailureCode;
@end

@implementation AgentEffectsWorkspaceExecutor
- (NSDictionary *)prepareToolNamed:(NSString *)name arguments:(NSDictionary *)arguments
                               root:(NSDictionary *)root error:(NSError **)error {
  (void)root;
  if (self.prepareFailureCode != 0) {
    DSHSetAgentNativeStoreError(error, self.prepareFailureCode);
    return nil;
  }
  if ([name isEqualToString:@"write_file"]) {
    NSData *path = [arguments[@"path"] dataUsingEncoding:NSUTF8StringEncoding];
    NSData *content = [arguments[@"content"] dataUsingEncoding:NSUTF8StringEncoding];
    return @{
      @"schema_version" : @1,
      @"precondition" : @{
        @"schema_version" : @2, @"kind" : @"write_file",
        @"relative_path_sha256" : DSHAgentHB(@"relative-path", path, error),
        @"prior" : arguments[@"expected_prior"] ?: @{
          @"schema_version" : @1, @"kind" : @"absent",
        },
        @"content_sha256" : DSHAgentHB(@"file-content", content, error),
        @"content_bytes" : @(content.length),
      },
      @"reserved_write_bytes" : @(content.length),
    };
  }
  if ([name isEqualToString:@"read_file"]) {
    return @{ @"schema_version" : @1,
              @"precondition" : @{ @"schema_version" : @1,
                                    @"kind" : @"read_file",
                                    @"source_revision" : @"r1" },
              @"reserved_write_bytes" : @0 };
  }
  return @{ @"schema_version" : @1,
            @"precondition" : @{ @"schema_version" : @1,
                                  @"kind" : @"list_dir",
                                  @"directory_fingerprint_sha256" :
                                      @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
            @"reserved_write_bytes" : @0 };
}
@end

@interface AgentEffectsGitExecutor : DSHAgentGitToolExecutor
@property(nonatomic) NSUInteger effectCount;
@property(nonatomic, copy) dispatch_block_t onPrepare;
@end

@implementation AgentEffectsGitExecutor
- (NSDictionary *)prepareToolNamed:(NSString *)name arguments:(NSDictionary *)arguments
                               root:(NSDictionary *)root error:(NSError **)error {
  (void)root;
  if (self.onPrepare != nil) self.onPrepare();
  if ([name isEqualToString:@"git_push"]) {
    return @{ @"schema_version" : @1,
              @"precondition" : @{ @"schema_version" : @1,
                @"kind" : @"git_push", @"remote" : @"origin",
                @"remote_ref" : @"refs/heads/main",
                @"pre_remote_oid" : NSNull.null,
                @"target_oid" : @"cccccccccccccccccccccccccccccccccccccccc" },
              @"reserved_write_bytes" : @0 };
  }
  NSData *message = [arguments[@"message"] dataUsingEncoding:NSUTF8StringEncoding];
  NSString *messageSHA = DSHAgentHB(@"commit-message", message, error);
  NSDictionary *identity = @{ @"schema_version" : @1,
    @"name" : @"Rish Agent", @"email" : @"agent@rish.local",
    @"timestamp_seconds" : @1, @"timezone_offset" : @"+0000" };
  return @{ @"schema_version" : @1,
            @"precondition" : @{ @"schema_version" : @2,
              @"kind" : @"git_commit", @"object_format" : @"sha1",
              @"pre_head_oid" : NSNull.null, @"ordered_parent_oids" : @[],
              @"staged_index_sha256" :
                  @"1111111111111111111111111111111111111111111111111111111111111111",
              @"tree_oid" : @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              @"author" : identity, @"committer" : identity,
              @"message_blob_ref" : messageSHA, @"message_sha256" : messageSHA,
              @"message_bytes" : @(message.length), @"encoding_header" : @"UTF-8",
              @"signature_policy" : @"unsigned", @"extra_headers" : @[],
              @"stage_all" : @YES, @"commit_payload_sha256" :
                  @"2222222222222222222222222222222222222222222222222222222222222222",
              @"expected_commit_oid" : @"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" },
            @"reserved_write_bytes" : @0 };
}
- (NSDictionary *)executeToolNamed:(NSString *)name arguments:(NSDictionary *)arguments
                               root:(NSDictionary *)root
                       precondition:(NSDictionary *)precondition
                              error:(NSError **)error {
  (void)arguments; (void)root; (void)error;
  self.effectCount += 1;
  NSDictionary *payload = [name isEqualToString:@"git_push"]
      ? @{ @"schema_version" : @1, @"remote" : @"origin",
           @"remote_ref" : precondition[@"remote_ref"],
           @"pushed_oid" : precondition[@"target_oid"] }
      : @{ @"schema_version" : @1,
           @"commit_oid" : precondition[@"expected_commit_oid"],
           @"tree_oid" : precondition[@"tree_oid"] };
  NSDictionary *feedback = @{ @"schema_version" : @1, @"name" : name,
                               @"outcome" : @"ok", @"payload" : payload };
  NSData *bytes = DSHAgentCanonicalJSON(feedback, nil);
  NSString *string = [[NSString alloc] initWithData:bytes
                                           encoding:NSUTF8StringEncoding];
  NSDictionary *facts = [name isEqualToString:@"git_push"]
      ? @{ @"schema_version" : @1, @"kind" : @"git_push",
           @"actual_remote_oid" : precondition[@"target_oid"] }
      : @{ @"schema_version" : @1, @"kind" : @"git_commit",
           @"actual_commit_oid" : precondition[@"expected_commit_oid"] };
  return @{ @"schema_version" : @1, @"status" : @"ok",
            @"feedback" : string, @"settled_facts" : facts,
            @"truncated" : @NO, @"effect_may_have_occurred" : @YES };
}
- (NSDictionary *)recoverToolNamed:(NSString *)name arguments:(NSDictionary *)arguments
                               root:(NSDictionary *)root
                       precondition:(NSDictionary *)precondition
                              error:(NSError **)error {
  (void)arguments; (void)root; (void)error;
  if ([name isEqualToString:@"git_push"]) {
    return @{ @"schema_version" : @1, @"status" : @"settled",
              @"actual_remote_oid" : precondition[@"target_oid"] };
  }
  return @{ @"schema_version" : @1, @"status" : @"settled",
            @"actual_commit_oid" : precondition[@"expected_commit_oid"] };
}
@end

@interface AgentToolEffectsTests : XCTestCase
@property(nonatomic, strong) NSURL *rootURL;
@property(nonatomic, strong) DSHAgentNativeWAL *wal;
@property(nonatomic, strong) DSHAgentTranscriptStore *transcripts;
@property(nonatomic, strong) DSHAgentExecutionLedger *ledger;
@end

@implementation AgentToolEffectsTests

- (void)setUp {
  [super setUp];
  self.rootURL = [NSURL fileURLWithPath:[NSTemporaryDirectory()
      stringByAppendingPathComponent:[@"rish-agent-effects-"
          stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString]]
                                isDirectory:YES];
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:self.rootURL
                                         withIntermediateDirectories:YES
                                                          attributes:nil
                                                               error:nil]);
  self.wal = [[DSHAgentNativeWAL alloc]
      initWithRootURL:self.rootURL
      clock:^NSDate * { return [NSDate dateWithTimeIntervalSince1970:1788134400]; }
      identifierGenerator:^NSString * {
        return @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
      }
      faultHook:nil];
  self.transcripts = [[DSHAgentTranscriptStore alloc] initWithWAL:self.wal];
  self.ledger = [[DSHAgentExecutionLedger alloc] initWithWAL:self.wal];
}

- (void)tearDown {
  [NSFileManager.defaultManager removeItemAtURL:self.rootURL error:nil];
  [super tearDown];
}

- (void)resetStoresWithFaultHook:(DSHAgentNativeWALFaultHook)faultHook
                              name:(NSString *)name {
  NSURL *root = [self.rootURL URLByAppendingPathComponent:name isDirectory:YES];
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:root
                                         withIntermediateDirectories:YES
                                                          attributes:@{NSFilePosixPermissions : @0700}
                                                               error:nil]);
  self.wal = [[DSHAgentNativeWAL alloc]
      initWithRootURL:root
      clock:^NSDate * { return [NSDate dateWithTimeIntervalSince1970:1788134400]; }
      identifierGenerator:^NSString * {
        return @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
      }
      faultHook:faultHook];
  self.transcripts = [[DSHAgentTranscriptStore alloc] initWithWAL:self.wal];
  self.ledger = [[DSHAgentExecutionLedger alloc] initWithWAL:self.wal];
}

- (NSDictionary *)rootWithCapabilities:(NSArray<NSString *> *)capabilities {
  return @{
    @"schema_version" : @1, @"kind" : @"workspace",
    @"workspace_id" : @"11111111-1111-4111-8111-111111111111",
    @"workspace_binding_revision" : @1, @"project_id" : NSNull.null,
    @"root_fingerprint_sha256" :
        @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    @"capabilities" : capabilities,
  };
}

- (NSDictionary *)projectRootWithCapabilities:(NSArray<NSString *> *)capabilities {
  NSMutableDictionary *root = [[self rootWithCapabilities:capabilities] mutableCopy];
  root[@"kind"] = @"project";
  root[@"project_id"] = @"99999999-9999-4999-8999-999999999999";
  return root;
}

- (BOOL)writeFixtureFileNamed:(NSString *)name
                       content:(NSString *)content
                 repositoryURL:(NSURL *)repositoryURL {
  NSError *error = nil;
  BOOL wrote = [[content dataUsingEncoding:NSUTF8StringEncoding]
      writeToURL:[repositoryURL URLByAppendingPathComponent:name]
         options:NSDataWritingAtomic
           error:&error];
  XCTAssertTrue(wrote, @"fixture write failed: %@", error);
  return wrote;
}

- (NSString *)createFixtureCommitInRepository:(git_repository *)repository
                                        parent:(NSString *)parent
                                       message:(NSString *)message
                               updateMainBranch:(BOOL)updateMainBranch
                              timestampSeconds:(git_time_t)timestampSeconds {
  git_index *index = nullptr;
  git_tree *tree = nullptr;
  git_commit *parentCommit = nullptr;
  git_signature *signature = nullptr;
  git_oid treeOID = {};
  git_oid parentOID = {};
  git_oid commitOID = {};
  int resultCode = git_repository_index(&index, repository);
  if (resultCode == 0) resultCode = git_index_read(index, 1);
  if (resultCode == 0) {
    resultCode = git_index_add_all(index, nullptr, GIT_INDEX_ADD_DEFAULT,
                                   nullptr, nullptr);
  }
  if (resultCode == 0) {
    resultCode = git_index_update_all(index, nullptr, nullptr, nullptr);
  }
  if (resultCode == 0) resultCode = git_index_write(index);
  if (resultCode == 0) {
    resultCode = git_index_write_tree_to(&treeOID, index, repository);
  }
  if (resultCode == 0) resultCode = git_tree_lookup(&tree, repository, &treeOID);
  if (resultCode == 0 && parent != nil) {
    resultCode = git_oid_fromstr(&parentOID, parent.UTF8String);
    if (resultCode == 0) {
      resultCode = git_commit_lookup(&parentCommit, repository, &parentOID);
    }
  }
  if (resultCode == 0) {
    resultCode = git_signature_new(&signature, "Fixture", "fixture@rish.local",
                                   timestampSeconds, 0);
  }
  const git_commit *parents[] = { parentCommit };
  if (resultCode == 0) {
    resultCode = git_commit_create(
        &commitOID, repository,
        updateMainBranch ? "refs/heads/main" : nullptr,
        signature, signature, "UTF-8", message.UTF8String, tree,
        parentCommit == nullptr ? 0 : 1,
        parentCommit == nullptr ? nullptr : parents);
  }
  if (signature != nullptr) git_signature_free(signature);
  if (parentCommit != nullptr) git_commit_free(parentCommit);
  if (tree != nullptr) git_tree_free(tree);
  if (index != nullptr) git_index_free(index);
  XCTAssertEqual(resultCode, 0, @"fixture commit failed: %d", resultCode);
  if (resultCode != 0) return nil;
  char oid[41] = {};
  git_oid_tostr(oid, sizeof(oid), &commitOID);
  return [NSString stringWithUTF8String:oid];
}

- (NSString *)referenceOIDNamed:(NSString *)referenceName
                 repositoryURL:(NSURL *)repositoryURL {
  git_repository *repository = nullptr;
  git_oid oid = {};
  int resultCode = git_repository_open(&repository,
                                        repositoryURL.fileSystemRepresentation);
  if (resultCode == 0) {
    resultCode = git_reference_name_to_id(&oid, repository,
                                          referenceName.UTF8String);
  }
  if (repository != nullptr) git_repository_free(repository);
  if (resultCode != 0) return nil;
  char value[41] = {};
  git_oid_tostr(value, sizeof(value), &oid);
  return [NSString stringWithUTF8String:value];
}

- (NSDictionary *)realGitExecutorFixtureNamed:(NSString *)name
                                      projectID:(NSString *)projectID {
  NSURL *fixtureRoot = [self.rootURL URLByAppendingPathComponent:name
                                                      isDirectory:YES];
  NSURL *projectsURL = [fixtureRoot URLByAppendingPathComponent:@"projects"
                                                     isDirectory:YES];
  NSURL *projectURL = [projectsURL URLByAppendingPathComponent:projectID
                                                   isDirectory:YES];
  NSURL *repositoryURL = [projectURL URLByAppendingPathComponent:@"repo"
                                                      isDirectory:YES];
  NSURL *originURL = [fixtureRoot URLByAppendingPathComponent:@"origin.git"
                                                    isDirectory:YES];
  NSError *error = nil;
  XCTAssertTrue([NSFileManager.defaultManager
      createDirectoryAtURL:repositoryURL
      withIntermediateDirectories:YES
      attributes:@{ NSFilePosixPermissions : @0700 }
      error:&error]);
  XCTAssertNil(error);
  DSHLocalProjectAccess *projectAccess = [[DSHLocalProjectAccess alloc]
      initWithProjectsRootURL:projectsURL];
  git_repository *repository = nullptr;
  git_repository *origin = nullptr;
  XCTAssertEqual(git_repository_init(&repository,
                                     repositoryURL.fileSystemRepresentation, 0),
                 0);
  XCTAssertNotEqual(repository, nullptr);
  XCTAssertEqual(git_repository_init(&origin,
                                     originURL.fileSystemRepresentation, 1),
                 0);
  XCTAssertNotEqual(origin, nullptr);
  if (repository == nullptr || origin == nullptr) {
    if (repository != nullptr) git_repository_free(repository);
    if (origin != nullptr) git_repository_free(origin);
    return nil;
  }
  XCTAssertEqual(git_repository_set_head(repository, "refs/heads/main"), 0);
  XCTAssertTrue([self writeFixtureFileNamed:@"README.md" content:@"base\n"
                              repositoryURL:repositoryURL]);
  NSString *baseOID = [self createFixtureCommitInRepository:repository
                                                     parent:nil
                                                    message:@"base"
                                            updateMainBranch:YES
                                           timestampSeconds:1];
  git_remote *remote = nullptr;
  int resultCode = git_remote_create(&remote, repository, "origin",
                                     originURL.fileSystemRepresentation);
  git_push_options seedOptions = {};
  if (resultCode == 0) {
    resultCode = git_push_options_init(&seedOptions, GIT_PUSH_OPTIONS_VERSION);
  }
  seedOptions.proxy_opts.type = GIT_PROXY_NONE;
  seedOptions.follow_redirects = GIT_REMOTE_REDIRECT_NONE;
  char seedRefspec[] = "refs/heads/main:refs/heads/main";
  char *seedValues[] = { seedRefspec };
  git_strarray seedRefs = { seedValues, 1 };
  if (resultCode == 0) {
    resultCode = git_remote_push(remote, &seedRefs, &seedOptions);
  }
  XCTAssertEqual(resultCode, 0, @"origin seed failed: %d", resultCode);
  if (remote != nullptr) git_remote_free(remote);
  git_repository_free(origin);
  git_repository_free(repository);
  if (baseOID == nil || resultCode != 0) return nil;

  NSDictionary *root = @{
    @"schema_version" : @1, @"kind" : @"project",
    @"workspace_id" : @"11111111-1111-4111-8111-111111111111",
    @"workspace_binding_revision" : @1, @"project_id" : projectID,
    @"root_fingerprint_sha256" :
        @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    @"capabilities" : @[@"git_status", @"git_commit", @"git_push"],
  };
  AgentEffectsProjectLeaseResolver *resolver =
      [[AgentEffectsProjectLeaseResolver alloc]
          initWithProjectAccess:projectAccess root:root];
  DSHAgentGitToolExecutor *executor = [[DSHAgentGitToolExecutor alloc]
      initWithRootResolver:resolver];
  return @{ @"executor" : executor, @"resolver" : resolver,
            @"root" : root, @"repository_url" : repositoryURL,
            @"origin_url" : originURL, @"base_oid" : baseOID };
}

- (NSDictionary *)feedbackObject:(NSDictionary *)effect {
  NSError *error = nil;
  NSData *data = [effect[@"feedback"] dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *feedback = data == nil ? nil :
      [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
  XCTAssertNotNil(feedback);
  XCTAssertNil(error);
  return feedback;
}

- (NSDictionary *)policyWithBatch:(NSUInteger)batch attempt:(NSUInteger)attempt {
  return @{
    @"schema_version" : @1, @"policy_version" : @"agent-v1",
    @"max_single_write_bytes" : @32768,
    @"max_batch_write_bytes" : @(batch),
    @"max_attempt_write_bytes" : @(attempt),
  };
}

- (NSDictionary *)loadResultForSession:(NSDictionary *)session
                              generation:(NSNumber *)generation
                                  digest:(NSString *)digest {
  NSData *bytes = DSHAgentCanonicalJSON(session, nil);
  return @{ @"schema_version" : @1, @"status" : @"present",
            @"snapshot" : @{ @"schema_version" : @1,
                              @"generation" : generation,
                              @"session_sha256" : digest },
            @"session_json" : [[NSString alloc] initWithData:bytes
                                                     encoding:NSUTF8StringEncoding] };
}

- (NSDictionary *)serviceFixtureForRawCalls:(NSArray<NSDictionary *> *)rawCalls {
  return [self serviceFixtureForRawCalls:rawCalls root:nil workspaceExecutor:nil];
}

/// Builds the batch service over a real owned workspace and the production
/// workspace executor, so the approval preview the executor computes is the
/// one the ledger validates.  Returns nil (after failing the test) when the
/// workspace cannot be created.
- (NSDictionary *)realWorkspaceServiceFixtureForRawCalls:
    (NSArray<NSDictionary *> *)rawCalls {
  NSURL *privateRoot = [self.rootURL URLByAppendingPathComponent:@"service-private"
                                                     isDirectory:YES];
  NSURL *documents = [self.rootURL URLByAppendingPathComponent:@"ServiceDocuments"
                                                   isDirectory:YES];
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:privateRoot
                                         withIntermediateDirectories:YES
                                                          attributes:@{NSFilePosixPermissions : @0700}
                                                               error:nil]);
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:documents
                                         withIntermediateDirectories:YES
                                                          attributes:nil
                                                               error:nil]);
  DSHLocalWorkspaceAccess *access = [[DSHLocalWorkspaceAccess alloc]
      initWithPrivateRootURL:privateRoot
      documentsRootURL:documents
      clock:^NSDate * { return [NSDate dateWithTimeIntervalSince1970:1788134400]; }
      UUIDGenerator:^NSString * {
        return @"55555555-5555-4555-8555-555555555557";
      }
      legacyResolver:^BOOL(NSString *projectId, NSDictionary **evidence,
                           NSError **error) {
        (void)projectId;
        if (evidence != nil) *evidence = nil;
        (void)error;
        return NO;
      }
      faultHook:nil];
  NSError *error = nil;
  XCTAssertTrue([access ensurePrivateLayoutWithError:&error]);
  XCTAssertNil(error);
  NSDictionary *created = [access createRishOwnedWorkspaceWithDisplayName:@"Service"
      operationId:@"66666666-6666-4666-8666-666666666668" error:&error];
  XCTAssertNotNil(created);
  XCTAssertNil(error);
  if (created == nil) return nil;
  DSHAgentRootResolver *resolver = [[DSHAgentRootResolver alloc]
      initWithWorkspaceAccess:access projectAccess:nil];
  NSDictionary *root = [resolver resolveRootForWorkspaceId:created[@"workspace_id"]
      projectId:nil bindingRevision:created[@"binding_revision"] error:&error];
  XCTAssertNotNil(root);
  XCTAssertNil(error);
  if (root == nil) return nil;
  DSHAgentWorkspaceToolExecutor *executor =
      [[DSHAgentWorkspaceToolExecutor alloc] initWithRootResolver:resolver];
  return [self serviceFixtureForRawCalls:rawCalls root:root
                       workspaceExecutor:executor];
}

- (NSDictionary *)serviceFixtureForRawCalls:(NSArray<NSDictionary *> *)rawCalls
                                       root:(NSDictionary *)explicitRoot
                          workspaceExecutor:
                              (DSHAgentWorkspaceToolExecutor *)explicitExecutor {
  NSString *task = @"10101010-1010-4010-8010-101010101010";
  NSString *attempt = @"20202020-2020-4020-8020-202020202020";
  NSString *conversation = @"30303030-3030-4030-8030-303030303030";
  NSString *roundID = @"40404040-4040-4040-8040-404040404040";
  NSString *authorityOperation = @"50505050-5050-4050-8050-505050505050";
  NSString *sessionDigest =
      @"abababababababababababababababababababababababababababababababab";
  NSMutableSet *capabilities = [NSMutableSet set];
  for (NSDictionary *call in rawCalls) {
    NSString *name = call[@"name"];
    if ([name isEqualToString:@"write_file"]) [capabilities addObject:@"file_write"];
    if ([name isEqualToString:@"read_file"] || [name isEqualToString:@"list_dir"])
      [capabilities addObject:@"file_read"];
    if ([name hasPrefix:@"git_"]) [capabilities addObject:name];
  }
  NSDictionary *root = explicitRoot ?: [self projectRootWithCapabilities:
      [[capabilities allObjects] sortedArrayUsingSelector:@selector(compare:)]];
  NSError *error = nil;
  NSDictionary *before = [self.transcripts createAgentTranscriptWithRequest:@{
    @"schema_version" : @1, @"attempt_id" : attempt, @"root" : root,
  } error:&error];
  XCTAssertNotNil(before);
  NSMutableArray *assistantCalls = [NSMutableArray arrayWithCapacity:rawCalls.count];
  for (NSDictionary *raw in rawCalls) {
    [assistantCalls addObject:@{ @"schema_version" : @1,
      @"call_id" : raw[@"call_id"], @"name" : raw[@"name"],
      @"arguments_json" : raw[@"arguments_json"] }];
  }
  NSDictionary *after = [self.transcripts appendAssistantMessage:@{
    @"schema_version" : @1, @"role" : @"assistant", @"round_index" : @0,
    @"content" : @"", @"reasoning_content" : @"", @"tool_calls" : assistantCalls,
  } expectedTranscript:before root:root attemptId:attempt error:&error];
  XCTAssertNotNil(after);
  DSHAgentToolRegistry *toolRegistry = [[DSHAgentToolRegistry alloc] init];
  NSDictionary *registry = [toolRegistry registryForRoot:root error:&error];
  NSDictionary *policy = [toolRegistry policyForRoot:root error:&error];
  NSString *now = [self.wal currentTimestamp];
  NSDictionary *authority = @{
    @"schema_version" : @2, @"task_id" : task,
    @"conversation_id" : conversation, @"attempt_id" : attempt,
    @"root" : root, @"policy" : policy, @"registry" : registry,
    @"transport_schema_version" : @2, @"model" : @"deepseek-v4-flash",
    @"thinking_mode" : @"off", @"visible_message_ids" : @[],
    @"visible_history_sha256" :
        @"cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd",
    @"visible_message_count" : @0, @"project_context_sha256" : NSNull.null,
    @"transcript" : after, @"reserved_write_bytes" : @0,
    @"authority_revision" : @1, @"state" : @"prepared",
    @"cleanup_id" : NSNull.null, @"created_at" : now, @"updated_at" : now,
  };
  NSDictionary *authorityRequest = @{
    @"schema_version" : @2, @"operation_id" : authorityOperation,
    @"task_id" : task, @"conversation_id" : conversation,
    @"attempt_id" : attempt,
  };
  NSDictionary *authoritySafe = @{
    @"schema_version" : @2, @"result_kind" : @"prepare_agent_attempt",
    @"result" : @{ @"schema_version" : @2, @"status" : @"prepared",
                    @"operation_id" : authorityOperation },
  };
  XCTAssertNotNil(DSHAgentNativeWALPrepareAuthorityOperation(
      self.wal, authority, authorityRequest, authoritySafe, &error));

  NSMutableArray *presentations = [NSMutableArray array];
  for (NSUInteger index = 0; index < rawCalls.count; index += 1) {
    NSDictionary *raw = rawCalls[index];
    NSDictionary *descriptor = [toolRegistry descriptorForToolName:raw[@"name"]
                                                               root:root error:&error];
    [presentations addObject:@{
      @"schema_version" : @3, @"call_index" : @(index),
      @"call_id" : raw[@"call_id"], @"name" : raw[@"name"],
      @"arguments_sha256" : raw[@"arguments_sha256"] ?:
          DSHAgentArgumentsSHA256(raw[@"name"], raw[@"arguments_json"], &error),
      @"safe_summary_key" : descriptor[@"safe_summary_key"],
      @"access" : descriptor[@"access"], @"approval_state" : @"deferred",
    }];
  }
  NSDictionary *roundLocator = @{
    @"schema_version" : @1, @"task_id" : task, @"attempt_id" : attempt,
    @"round_id" : roundID, @"round_index" : @0,
  };
  NSDictionary *completionReceipt = @{
    @"schema_version" : @1, @"transport_schema_version" : @2,
    @"turn_id" : task, @"attempt_id" : attempt, @"round_id" : roundID,
    @"round_index" : @0, @"provider_request_id" : @"req-1",
    @"provider_response_id" : @"res-1",
    @"requested_model" : @"deepseek-v4-flash",
    @"model" : @"deepseek-v4-flash", @"thinking_mode" : @"off",
    @"finish_reason" : @"tool_calls", @"latency_ms" : @1,
    @"visible_history_sha256" : authority[@"visible_history_sha256"],
    @"model_input_sha256" :
        @"dededededededededededededededededededededededededededededededede",
    @"request_body_sha256" :
        @"efefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefef",
    @"project_context_receipt" : NSNull.null,
  };
  NSDictionary *round = @{
    @"schema_version" : @3, @"locator" : roundLocator, @"row_revision" : @1,
    @"root_fingerprint_sha256" : root[@"root_fingerprint_sha256"],
    @"binding_revision" : root[@"workspace_binding_revision"],
    @"request_sha256" :
        @"1212121212121212121212121212121212121212121212121212121212121212",
    @"transcript_before" : before, @"launch_attempt" : @1,
    @"state" : @"completed", @"owner" : NSNull.null,
    @"failure_code" : NSNull.null, @"completion_receipt" : completionReceipt,
    @"transcript_after" : after, @"calls" : presentations,
    @"batch_class" : @"executable",
    @"executable_call_count" : @(rawCalls.count), @"denied_call_count" : @0,
    @"terminal_kind" : @"tool_batch", @"created_at" : now, @"updated_at" : now,
  };
  BOOL roundCommitted = [self.wal performAtomicTransaction:^BOOL(
      NSMutableDictionary *state, NSError **mutationError) {
    (void)mutationError;
    NSMutableArray *rounds = [state[@"rounds"] mutableCopy];
    [rounds addObject:round];
    NSMutableArray *dispatch = [state[@"dispatch"] mutableCopy];
    [dispatch addObject:@{ @"schema_version" : @1, @"kind" : @"round",
                           @"locator" : roundLocator,
                           @"dispatch_state" : @"dispatched" }];
    state[@"rounds"] = rounds;
    state[@"dispatch"] = dispatch;
    return YES;
  } error:&error];
  XCTAssertTrue(roundCommitted);

  NSDictionary *baseSession = @{
    @"schema_version" : @9,
    @"conversations" : @[@{ @"id" : conversation, @"agent_grants" : @[],
      @"attempts" : @[@{ @"attempt_id" : attempt, @"journal_revision" : @1,
                          @"agent" : NSNull.null }] }],
    @"session_events" : @[],
  };
  AgentEffectsSessionStore *sessionStore = [[AgentEffectsSessionStore alloc]
      initWithLoadResult:[self loadResultForSession:baseSession generation:@3
                                             digest:sessionDigest]];
  AgentEffectsRootResolver *resolver = [[AgentEffectsRootResolver alloc]
      initWithRoot:root];
  AgentEffectsPreparedStore *preparedStore = [[AgentEffectsPreparedStore alloc]
      initWithWAL:self.wal rootResolver:resolver sessionSnapshotStore:sessionStore
      transcriptStore:self.transcripts];
  DSHAgentWorkspaceToolExecutor *workspace = explicitExecutor ?:
      [[AgentEffectsWorkspaceExecutor alloc] initWithRootResolver:resolver];
  AgentEffectsGitExecutor *git = [[AgentEffectsGitExecutor alloc]
      initWithRootResolver:resolver];
  DSHAgentToolBatchService *batchService = [[DSHAgentToolBatchService alloc]
      initWithWAL:self.wal ledger:self.ledger preparedStore:preparedStore
      transcripts:self.transcripts workspaceExecutor:workspace gitExecutor:git];
  NSDictionary *checkpoint = @{ @"schema_version" : @1, @"journal_revision" : @1,
    @"session_generation" : @3, @"session_sha256" : sessionDigest };
  NSDictionary *controller = @{ @"schema_version" : @1,
    @"conversation_id" : conversation, @"task_id" : task,
    @"attempt_id" : attempt, @"expected_controller_generation" : @1,
    @"expected_journal_revision" : @1, @"expected_session_generation" : @3,
    @"expected_session_sha256" : sessionDigest };
  NSDictionary *batchRequest = @{ @"schema_version" : @2,
    @"operation_id" : @"60606060-6060-4060-8060-606060606060",
    @"controller_cas" : controller, @"committed_checkpoint" : checkpoint,
    @"task_id" : task, @"conversation_id" : conversation,
    @"attempt_id" : attempt, @"round_id" : roundID, @"round_index" : @0,
    @"expected_round_revision" : @1, @"transcript" : after, @"root" : root,
    @"registry_version" : @1, @"toolset_sha256" : registry[@"toolset_sha256"],
    @"policy_version" : @"agent-v1", @"expected_batch_revision" : @0,
    @"expected_reserved_write_bytes" : @0 };
  return @{ @"root" : root, @"task" : task, @"attempt" : attempt,
            @"conversation" : conversation, @"round_id" : roundID,
            @"transcript" : after, @"transcript_before" : before,
            @"registry" : registry,
            @"session_store" : sessionStore, @"prepared_store" : preparedStore,
            @"resolver" : resolver, @"workspace_executor" : workspace,
            @"git_executor" : git, @"batch_service" : batchService,
            @"batch_request" : batchRequest, @"controller" : controller,
            @"checkpoint" : checkpoint };
}

- (NSDictionary *)transcriptForRoot:(NSDictionary *)root {
  NSError *error = nil;
  NSDictionary *transcript = [self.transcripts createAgentTranscriptWithRequest:@{
    @"schema_version" : @1,
    @"attempt_id" : @"22222222-2222-4222-8222-222222222222",
    @"root" : root,
  } error:&error];
  XCTAssertNotNil(transcript);
  XCTAssertNil(error);
  return transcript;
}

- (NSDictionary *)batchRequestWithRoot:(NSDictionary *)root
                              transcript:(NSDictionary *)transcript
                                   calls:(NSArray<NSDictionary *> *)calls
                                  policy:(NSDictionary *)policy
                              roundIndex:(NSUInteger)roundIndex {
  return @{
    @"schema_version" : @2,
    @"task_id" : @"33333333-3333-4333-8333-333333333333",
    @"attempt_id" : @"22222222-2222-4222-8222-222222222222",
    @"round_id" : @"44444444-4444-4444-8444-444444444444",
    @"round_index" : @(roundIndex), @"round_revision" : @1,
    @"root" : root, @"transcript" : transcript, @"policy" : policy,
    @"expected_batch_revision" : @0,
    @"expected_reserved_write_bytes" : @0, @"calls" : calls,
  };
}

- (NSDictionary *)readCallAtIndex:(NSUInteger)index
                              name:(NSString *)name
                         arguments:(NSString *)arguments
                      precondition:(NSDictionary *)precondition {
  NSError *error = nil;
  NSString *digest = DSHAgentArgumentsSHA256(name, arguments, &error);
  XCTAssertNotNil(digest);
  XCTAssertNil(error);
  return @{
    @"call_index" : @(index),
    @"call_id" : [NSString stringWithFormat:@"call_%lu", (unsigned long)index],
    @"name" : name, @"arguments_json" : arguments,
    @"arguments_sha256" : digest,
    @"safe_summary_key" : [@"agent." stringByAppendingString:name],
    @"access" : @"auto", @"precondition" : precondition,
    @"reserved_write_bytes" : @0,
  };
}

- (void)testWholeReadOnlyBatchCreatesOrderedIntentsWithoutWriteReservation {
  NSDictionary *root = [self rootWithCapabilities:@[@"file_read"]];
  NSDictionary *transcript = [self transcriptForRoot:root];
  NSArray *calls = @[
    [self readCallAtIndex:0 name:@"list_dir" arguments:@"{}"
             precondition:@{
               @"schema_version" : @1, @"kind" : @"list_dir",
               @"directory_fingerprint_sha256" :
                   @"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
             }],
    [self readCallAtIndex:1 name:@"read_file"
                arguments:@"{\"path\":\"README.md\"}"
             precondition:@{
               @"schema_version" : @1, @"kind" : @"read_file",
               @"source_revision" : @"1:2:3:4:5",
             }],
  ];
  NSError *error = nil;
  NSDictionary *result = [self.ledger prepareAgentToolBatchWithRequest:
      [self batchRequestWithRoot:root transcript:transcript calls:calls
                           policy:[self policyWithBatch:32768 attempt:65536]
                       roundIndex:0] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"prepared");
  XCTAssertEqualObjects(result[@"batch_kind"], @"read_only_batch");
  XCTAssertEqualObjects(result[@"manifest_sha256"], NSNull.null);
  XCTAssertEqualObjects(result[@"effect_gate"], @"not_applicable");
  XCTAssertEqualObjects(result[@"reserved_write_bytes"], @0);
  XCTAssertEqual([result[@"calls"] count], 2U);

  NSDictionary *snapshot = [self.wal snapshotWithError:&error];
  XCTAssertNil(error);
  XCTAssertEqual([snapshot[@"ledger"] count], 2U);
  XCTAssertEqual([snapshot[@"batches"] count], 1U);
  XCTAssertEqual([snapshot[@"reservations"] count], 0U);
  XCTAssertEqualObjects(snapshot[@"batches"][0][@"schema_version"], @2);
  XCTAssertEqualObjects(snapshot[@"batches"][0][@"kind"], @"read_only_batch");
}

- (void)testBatchAuthorityFollowsLatestCommittedBatchWithoutAssumingMonotonicity {
  NSDictionary *root = [self projectRootWithCapabilities:@[
    @"file_read", @"file_write",
  ]];
  NSDictionary *transcript = [self transcriptForRoot:root];
  NSDictionary *policy = [self policyWithBatch:32768 attempt:65536];
  NSError *error = nil;

  NSMutableDictionary *first = [[self batchRequestWithRoot:root
      transcript:transcript
      calls:@[[self writeCallAtIndex:0 path:@"first.txt" content:@"hello"]]
      policy:policy roundIndex:0] mutableCopy];
  NSDictionary *firstResult = [self.ledger
      prepareAgentToolBatchWithRequest:first error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(firstResult[@"status"], @"prepared");
  XCTAssertEqualObjects(firstResult[@"batch_kind"], @"write_batch");
  XCTAssertEqualObjects(firstResult[@"batch_revision"], @1);
  XCTAssertEqualObjects(firstResult[@"reserved_write_bytes"], @5);

  NSDictionary *readCall = [self readCallAtIndex:0 name:@"read_file"
      arguments:@"{\"path\":\"first.txt\"}"
      precondition:@{ @"schema_version" : @1, @"kind" : @"read_file",
                      @"source_revision" : @"r1" }];
  NSMutableDictionary *second = [[self batchRequestWithRoot:root
      transcript:transcript calls:@[readCall] policy:policy roundIndex:1]
      mutableCopy];
  second[@"round_id"] = @"55555555-5555-4555-8555-555555555555";
  second[@"round_revision"] = @7;
  second[@"expected_reserved_write_bytes"] = @5;

  NSMutableDictionary *stale = [second mutableCopy];
  stale[@"expected_batch_revision"] = @0;
  XCTAssertNil([self.ledger prepareAgentToolBatchWithRequest:stale error:&error]);
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorConflict);
  NSDictionary *afterStale = [self.wal snapshotWithError:nil];
  XCTAssertEqual([afterStale[@"batches"] count], 1U);
  XCTAssertEqual([afterStale[@"ledger"] count], 1U);

  error = nil;
  NSMutableDictionary *wrong = [second mutableCopy];
  wrong[@"expected_batch_revision"] = @2;
  XCTAssertNil([self.ledger prepareAgentToolBatchWithRequest:wrong error:&error]);
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorConflict);
  NSDictionary *afterWrong = [self.wal snapshotWithError:nil];
  XCTAssertEqual([afterWrong[@"batches"] count], 1U);
  XCTAssertEqual([afterWrong[@"ledger"] count], 1U);

  error = nil;
  second[@"expected_batch_revision"] = @1;
  NSDictionary *secondResult = [self.ledger
      prepareAgentToolBatchWithRequest:second error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(secondResult[@"status"], @"prepared");
  XCTAssertEqualObjects(secondResult[@"batch_kind"], @"read_only_batch");
  XCTAssertEqualObjects(secondResult[@"batch_revision"], @7);
  XCTAssertEqualObjects(secondResult[@"reserved_write_bytes"], @5);

  // The next mutation consumes the latest opaque authority (7), but its own
  // reservation revision is 2. This intentionally demonstrates why max() or
  // an increment assumption would reject a valid later round.
  NSMutableDictionary *third = [[self batchRequestWithRoot:root
      transcript:transcript
      calls:@[[self writeCallAtIndex:0 path:@"second.txt" content:@"world"]]
      policy:policy roundIndex:2] mutableCopy];
  third[@"round_id"] = @"66666666-6666-4666-8666-666666666666";
  third[@"expected_batch_revision"] = @7;
  third[@"expected_reserved_write_bytes"] = @5;
  NSDictionary *thirdResult = [self.ledger
      prepareAgentToolBatchWithRequest:third error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(thirdResult[@"status"], @"prepared");
  XCTAssertEqualObjects(thirdResult[@"batch_kind"], @"write_batch");
  XCTAssertEqualObjects(thirdResult[@"batch_revision"], @2);
  XCTAssertEqualObjects(thirdResult[@"reserved_write_bytes"], @10);
}

- (NSDictionary *)writeCallAtIndex:(NSUInteger)index
                               path:(NSString *)path
                            content:(NSString *)content {
  NSDictionary *argumentsObject = @{
    @"path" : path, @"content" : content,
    @"expected_prior" : @{ @"schema_version" : @1, @"kind" : @"absent" },
  };
  NSError *error = nil;
  NSData *argumentsBytes = DSHAgentCanonicalJSON(argumentsObject, &error);
  NSString *arguments = [[NSString alloc] initWithData:argumentsBytes
                                               encoding:NSUTF8StringEncoding];
  NSData *pathBytes = [path dataUsingEncoding:NSUTF8StringEncoding];
  NSData *contentBytes = [content dataUsingEncoding:NSUTF8StringEncoding];
  NSString *pathDigest = DSHAgentHB(@"relative-path", pathBytes, &error);
  NSString *contentDigest = DSHAgentHB(@"file-content", contentBytes, &error);
  NSString *argumentsDigest = DSHAgentArgumentsSHA256(@"write_file", arguments,
                                                       &error);
  XCTAssertNil(error);
  return @{
    @"call_index" : @(index),
    @"call_id" : [NSString stringWithFormat:@"write_%lu", (unsigned long)index],
    @"name" : @"write_file", @"arguments_json" : arguments,
    @"arguments_sha256" : argumentsDigest,
    @"safe_summary_key" : @"agent.write_file",
    @"access" : @"conversation_confirm",
    @"precondition" : @{
      @"schema_version" : @2, @"kind" : @"write_file",
      @"relative_path_sha256" : pathDigest,
      @"prior" : argumentsObject[@"expected_prior"],
      @"content_sha256" : contentDigest,
      @"content_bytes" : @(contentBytes.length),
    },
    @"reserved_write_bytes" : @(contentBytes.length),
  };
}

- (NSDictionary *)gitCommitCallAtIndex:(NSUInteger)index {
  NSError *error = nil;
  NSString *arguments = @"{\"message\":\"m\"}";
  NSData *message = [@"m" dataUsingEncoding:NSUTF8StringEncoding];
  NSString *messageSHA = DSHAgentHB(@"commit-message", message, &error);
  NSDictionary *identity = @{
    @"schema_version" : @1, @"name" : @"Rish Agent",
    @"email" : @"agent@rish.local", @"timestamp_seconds" : @1,
    @"timezone_offset" : @"+0000",
  };
  return @{
    @"call_index" : @(index),
    @"call_id" : [NSString stringWithFormat:@"commit_%lu", (unsigned long)index],
    @"name" : @"git_commit", @"arguments_json" : arguments,
    @"arguments_sha256" : DSHAgentArgumentsSHA256(@"git_commit", arguments, &error),
    @"safe_summary_key" : @"agent.git_commit",
    @"access" : @"conversation_confirm",
    @"precondition" : @{
      @"schema_version" : @2, @"kind" : @"git_commit",
      @"object_format" : @"sha1", @"pre_head_oid" : NSNull.null,
      @"ordered_parent_oids" : @[],
      @"staged_index_sha256" :
          @"1111111111111111111111111111111111111111111111111111111111111111",
      @"tree_oid" : @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      @"author" : identity, @"committer" : identity,
      @"message_blob_ref" : messageSHA, @"message_sha256" : messageSHA,
      @"message_bytes" : @1, @"encoding_header" : @"UTF-8",
      @"signature_policy" : @"unsigned", @"extra_headers" : @[],
      @"stage_all" : @YES,
      @"commit_payload_sha256" :
          @"2222222222222222222222222222222222222222222222222222222222222222",
      @"expected_commit_oid" : @"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    },
    @"reserved_write_bytes" : @0,
  };
}

- (NSDictionary *)gitPushCallAtIndex:(NSUInteger)index {
  NSError *error = nil;
  return @{
    @"call_index" : @(index),
    @"call_id" : [NSString stringWithFormat:@"push_%lu", (unsigned long)index],
    @"name" : @"git_push", @"arguments_json" : @"{}",
    @"arguments_sha256" : DSHAgentArgumentsSHA256(@"git_push", @"{}", &error),
    @"safe_summary_key" : @"agent.git_push", @"access" : @"conversation_confirm",
    @"precondition" : @{
      @"schema_version" : @1, @"kind" : @"git_push", @"remote" : @"origin",
      @"remote_ref" : @"refs/heads/main", @"pre_remote_oid" : NSNull.null,
      @"target_oid" : @"cccccccccccccccccccccccccccccccccccccccc",
    },
    @"reserved_write_bytes" : @0,
  };
}

- (void)testGitOnlyAndMixedMutationBatchesUseOneClosedGate {
  NSDictionary *root = [self projectRootWithCapabilities:@[
    @"file_read", @"file_write", @"git_commit", @"git_push",
  ]];
  NSDictionary *transcript = [self transcriptForRoot:root];
  NSError *error = nil;
  NSDictionary *gitOnly = [self.ledger prepareAgentToolBatchWithRequest:
      [self batchRequestWithRoot:root transcript:transcript
                           calls:@[[self gitCommitCallAtIndex:0]]
                          policy:[self policyWithBatch:32768 attempt:65536]
                      roundIndex:0] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(gitOnly[@"batch_kind"], @"write_batch");
  XCTAssertEqualObjects(gitOnly[@"batch_new_write_bytes"], @0);
  XCTAssertEqualObjects(gitOnly[@"reserved_write_bytes"], @0);
  XCTAssertEqualObjects(gitOnly[@"batch_revision"], @1);
  XCTAssertEqualObjects(gitOnly[@"effect_gate"], @"closed");
  NSDictionary *snapshot = [self.wal snapshotWithError:&error];
  NSDictionary *gitBatch = snapshot[@"batches"][0];
  XCTAssertEqualObjects(gitBatch[@"manifest_calls"][0][@"mutation_kind"],
                        @"git_commit");
  XCTAssertEqualObjects(gitBatch[@"manifest_calls"][0][@"content_bytes"], @0);
  XCTAssertNotNil(gitBatch[@"manifest_calls"][0][@"precondition_sha256"]);
  XCTAssertEqualObjects(snapshot[@"reservations"][0][@"reservation_version"], @1);
  XCTAssertEqual([snapshot[@"reservations"][0][@"keys"] count], 0U);

  // A fresh attempt exercises original call order: read, Git mutation, file mutation.
  NSDictionary *root2 = [self projectRootWithCapabilities:@[
    @"file_read", @"file_write", @"git_push",
  ]];
  NSMutableDictionary *root2Mutable = [root2 mutableCopy];
  root2Mutable[@"root_fingerprint_sha256"] =
      @"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
  NSDictionary *transcript2 = [self.transcripts createAgentTranscriptWithRequest:@{
    @"schema_version" : @1,
    @"attempt_id" : @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    @"root" : root2Mutable,
  } error:&error];
  NSArray *mixedCalls = @[
    [self readCallAtIndex:0 name:@"read_file"
                arguments:@"{\"path\":\"README.md\"}"
             precondition:@{ @"schema_version" : @1, @"kind" : @"read_file",
                              @"source_revision" : @"r1" }],
    [self gitPushCallAtIndex:1],
    [self writeCallAtIndex:2 path:@"a.txt" content:@"hello"],
  ];
  NSMutableDictionary *mixedRequest = [[self batchRequestWithRoot:root2Mutable
      transcript:transcript2 calls:mixedCalls
      policy:[self policyWithBatch:32768 attempt:65536] roundIndex:1] mutableCopy];
  mixedRequest[@"attempt_id"] = @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
  mixedRequest[@"task_id"] = @"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  mixedRequest[@"round_id"] = @"ffffffff-ffff-4fff-8fff-ffffffffffff";
  NSDictionary *mixed = [self.ledger prepareAgentToolBatchWithRequest:mixedRequest
                                                                 error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(mixed[@"batch_kind"], @"write_batch");
  snapshot = [self.wal snapshotWithError:&error];
  NSDictionary *mixedBatch = snapshot[@"batches"][1];
  XCTAssertEqualObjects([mixedBatch[@"manifest_calls"] valueForKey:@"mutation_kind"],
                        (@[@"git_push", @"file_write"]));
  XCTAssertEqualObjects(
      [mixedBatch[@"manifest_calls"] valueForKeyPath:@"locator.call_index"],
      (@[@1, @2]));
  XCTAssertEqualObjects(mixedBatch[@"reservation_delta_bytes"], @5);
  XCTAssertEqualObjects(mixedBatch[@"effect_gate"], @"closed");
}

- (void)testAuthorityAdvanceRejectsFullRootWithUnboundCapabilityBits {
  NSDictionary *rawCommit = @{ @"schema_version" : @1,
    @"call_id" : @"commit-call", @"name" : @"git_commit",
    @"arguments_json" : @"{\"message\":\"m\"}" };
  NSDictionary *fixture = [self serviceFixtureForRawCalls:@[rawCommit]];
  NSError *error = nil;
  NSDictionary *before = [self.wal snapshotWithError:&error];
  XCTAssertNil(error);
  NSDictionary *authority = before[@"authorities"][0];
  XCTAssertEqualObjects(authority[@"authority_revision"], @1);

  // Preserve the fingerprint and binding revision while changing one full-root
  // authority bit.  A full root is an exact projection; it must not fall back
  // to the two-field private root expectation accepted by ledger row CAS.
  NSMutableDictionary *tamperedRoot = [fixture[@"root"] mutableCopy];
  tamperedRoot[@"capabilities"] = @[@"file_read", @"git_commit"];
  NSDictionary *request = @{
    @"schema_version" : @2,
    @"task_id" : fixture[@"task"],
    @"attempt_id" : fixture[@"attempt"],
    @"round_id" : fixture[@"round_id"],
    @"round_index" : @0,
    @"round_revision" : @1,
    @"root" : tamperedRoot,
    @"transcript" : fixture[@"transcript"],
    @"policy" : authority[@"policy"],
    @"expected_batch_revision" : @0,
    @"expected_reserved_write_bytes" : @0,
    @"calls" : @[[self gitCommitCallAtIndex:0]],
  };
  NSDictionary *result = [self.ledger prepareAgentToolBatchWithRequest:request
                                                                  error:&error];
  XCTAssertNil(result);
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorConflict);
  NSDictionary *after = [self.wal snapshotWithError:nil];
  XCTAssertEqual([after[@"batches"] count], 0U);
  XCTAssertEqual([after[@"ledger"] count], 0U);
  XCTAssertEqualObjects(after[@"authorities"][0][@"authority_revision"], @1);
  XCTAssertEqualObjects(after[@"authorities"][0][@"root"], fixture[@"root"]);
}

- (void)testStartedBatchReplayHoldsFinalGuardAndAdvancesExactAuthorityFieldsOnce {
  __block BOOL captureGuardStages = NO;
  __block BOOL sawResultCommitWithGuard = NO;
  __block BOOL sawWALPrepareWithGuard = NO;
  __block AgentEffectsRootResolver *observedResolver = nil;
  [self resetStoresWithFaultHook:^BOOL(NSString *stage) {
    if (captureGuardStages && observedResolver.guardAlive) {
      if ([stage isEqualToString:@"wal.operation.before_result_commit"]) {
        sawResultCommitWithGuard = YES;
      }
      if ([stage isEqualToString:@"wal.before_prepare"]) {
        sawWALPrepareWithGuard = YES;
      }
    }
    return YES;
  } name:@"authority-guard-runtime"];

  NSDictionary *rawCommit = @{ @"schema_version" : @1,
    @"call_id" : @"commit-call", @"name" : @"git_commit",
    @"arguments_json" : @"{\"message\":\"m\"}" };
  NSDictionary *fixture = [self serviceFixtureForRawCalls:@[rawCommit]];
  observedResolver = fixture[@"resolver"];
  NSDictionary *before = [self.wal snapshotWithError:nil];
  NSDictionary *beforeAuthority = before[@"authorities"][0];
  NSDictionary *request = fixture[@"batch_request"];
  NSError *error = nil;
  NSDictionary *started = DSHAgentNativeWALStartOperation(
      self.wal, @"prepare_agent_tool_batch", request, fixture[@"task"],
      fixture[@"attempt"], beforeAuthority[@"authority_revision"], &error);
  XCTAssertNil(error);
  XCTAssertEqualObjects(started[@"status"], @"started");

  captureGuardStages = YES;
  NSDictionary *prepared = [fixture[@"batch_service"]
      prepareAgentToolBatchWithRequest:request error:&error];
  captureGuardStages = NO;
  XCTAssertNil(error);
  XCTAssertEqualObjects(prepared[@"status"], @"prepared");
  XCTAssertTrue(sawResultCommitWithGuard);
  XCTAssertTrue(sawWALPrepareWithGuard);
  XCTAssertGreaterThan(observedResolver.guardValidationCount, 0U);
  XCTAssertFalse(observedResolver.guardAlive);

  NSDictionary *after = [self.wal snapshotWithError:&error];
  XCTAssertNil(error);
  NSDictionary *afterAuthority = after[@"authorities"][0];
  XCTAssertEqualObjects(afterAuthority[@"authority_revision"], @2);
  XCTAssertEqualObjects(afterAuthority[@"root"], beforeAuthority[@"root"]);
  XCTAssertEqualObjects(afterAuthority[@"policy"], beforeAuthority[@"policy"]);
  XCTAssertEqualObjects(afterAuthority[@"registry"], beforeAuthority[@"registry"]);
  XCTAssertEqualObjects(afterAuthority[@"reserved_write_bytes"], @0);
  XCTAssertEqualObjects(afterAuthority[@"transcript"], prepared[@"receipt"][@"transcript"]);
  NSDictionary *operation = [after[@"operations"] filteredArrayUsingPredicate:
      [NSPredicate predicateWithFormat:@"operation_id == %@", request[@"operation_id"]]]
      .firstObject;
  XCTAssertEqualObjects(operation[@"state"], @"committed");
  XCTAssertEqualObjects(operation[@"authority_revision"], @1);

  NSUInteger guardValidations = observedResolver.guardValidationCount;
  observedResolver.rejectRoot = YES;
  NSDictionary *replayed = [fixture[@"batch_service"]
      prepareAgentToolBatchWithRequest:request error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(replayed, prepared);
  XCTAssertEqual(observedResolver.guardValidationCount, guardValidations);
  NSDictionary *replayState = [self.wal snapshotWithError:nil];
  XCTAssertEqualObjects(replayState[@"authorities"][0], afterAuthority);
  XCTAssertEqual([replayState[@"batches"] count], 1U);
  XCTAssertEqual([replayState[@"ledger"] count], 1U);
}

- (void)testBatchFinalAuthorityAcceptsSameTranscriptRefAdvancingGeneration {
  NSDictionary *rawRead = @{ @"schema_version" : @1,
    @"call_id" : @"read-call", @"name" : @"read_file",
    @"arguments_json" : @"{\"path\":\"README.md\"}" };
  NSDictionary *fixture = [self serviceFixtureForRawCalls:@[rawRead]];
  AgentEffectsPreparedStore *preparedStore = fixture[@"prepared_store"];
  NSMutableDictionary *authority =
      [[self.wal snapshotWithError:nil][@"authorities"][0] mutableCopy];
  authority[@"transcript"] = fixture[@"transcript_before"];
  NSError *error = nil;
  XCTAssertTrue([self.wal performAtomicTransaction:^BOOL(
      NSMutableDictionary *state, NSError **mutationError) {
    (void)mutationError;
    NSMutableArray *authorities = [state[@"authorities"] mutableCopy];
    authorities[0] = [authority copy];
    state[@"authorities"] = authorities;
    return YES;
  } error:&error]);
  XCTAssertNil(error);
  preparedStore.authorityOverride = [authority copy];
  NSDictionary *result = [fixture[@"batch_service"]
      prepareAgentToolBatchWithRequest:fixture[@"batch_request"] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"prepared");
  NSDictionary *afterAuthority =
      [self.wal snapshotWithError:nil][@"authorities"][0];
  XCTAssertEqualObjects(afterAuthority[@"transcript"], fixture[@"transcript"]);
  XCTAssertEqualObjects(afterAuthority[@"authority_revision"], @2);
}

- (void)testBatchFinalAuthorityRejectsInvalidTranscriptRelations {
  NSArray<NSString *> *cases = @[
    @"different-ref", @"downgrade", @"same-generation-sha",
    @"same-generation-bytes",
  ];
  for (NSUInteger index = 0; index < cases.count; index += 1) {
    [self resetStoresWithFaultHook:nil
                             name:[@"transcript-relation-"
                                 stringByAppendingString:cases[index]]];
    NSDictionary *rawRead = @{ @"schema_version" : @1,
      @"call_id" : @"read-call", @"name" : @"read_file",
      @"arguments_json" : @"{\"path\":\"README.md\"}" };
    NSDictionary *fixture = [self serviceFixtureForRawCalls:@[rawRead]];
    AgentEffectsPreparedStore *preparedStore = fixture[@"prepared_store"];
    NSMutableDictionary *authority =
        [[self.wal snapshotWithError:nil][@"authorities"][0] mutableCopy];
    NSMutableDictionary *transcript = [fixture[@"transcript"] mutableCopy];
    if ([cases[index] isEqualToString:@"different-ref"]) {
      transcript[@"transcript_ref"] =
          @"99999999-9999-4999-8999-999999999999";
    } else if ([cases[index] isEqualToString:@"downgrade"]) {
      transcript[@"generation"] =
          @([fixture[@"transcript"][@"generation"] unsignedIntegerValue] + 1);
    } else if ([cases[index] isEqualToString:@"same-generation-sha"]) {
      transcript[@"transcript_sha256"] =
          @"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
    } else {
      transcript[@"transcript_bytes"] =
          @([fixture[@"transcript"][@"transcript_bytes"] unsignedIntegerValue] + 1);
    }
    authority[@"transcript"] = [transcript copy];
    preparedStore.authorityOverride = [authority copy];
    NSError *error = nil;
    NSDictionary *result = [fixture[@"batch_service"]
        prepareAgentToolBatchWithRequest:fixture[@"batch_request"] error:&error];
    XCTAssertNil(error, @"case=%@", cases[index]);
    XCTAssertEqualObjects(result[@"status"], @"rejected", @"case=%@", cases[index]);
    XCTAssertEqualObjects(result[@"failure_code"], @"E_AGENT_CONFLICT",
                          @"case=%@", cases[index]);
  }
}

- (void)testBatchApprovalTamperAndExecutionReplayAreClosed {
  NSDictionary *rawCommit = @{ @"schema_version" : @1,
    @"call_id" : @"commit-call", @"name" : @"git_commit",
    @"arguments_json" : @"{\"message\":\"m\"}" };
  NSDictionary *fixture = [self serviceFixtureForRawCalls:@[rawCommit]];
  DSHAgentToolBatchService *batchService = fixture[@"batch_service"];
  NSError *error = nil;
  NSDictionary *prepared = [batchService
      prepareAgentToolBatchWithRequest:fixture[@"batch_request"] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(prepared[@"status"], @"prepared", @"%@", prepared);
  if (![prepared[@"status"] isEqualToString:@"prepared"]) return;
  NSDictionary *receipt = prepared[@"receipt"];
  XCTAssertEqualObjects(receipt[@"batch_kind"], @"write_batch");
  XCTAssertEqualObjects(receipt[@"batch_new_write_bytes"], @0);
  XCTAssertEqualObjects(receipt[@"effect_gate"], @"closed");
  NSDictionary *call = receipt[@"calls"][0];
  NSDictionary *token = call[@"approval_token"];
  XCTAssertNotNil(token);
  NSDictionary *state = [self.wal snapshotWithError:&error];
  XCTAssertEqual([state[@"batches"] count], 1U);
  XCTAssertEqual([state[@"operation_results"] count], 2U); // authority + batch

  NSString *approvalReference = @"71717171-7171-4171-8171-717171717171";
  NSMutableDictionary *persistedCall = [@{
    @"schema_version" : @3, @"call_id" : call[@"call_id"],
    @"call_index" : call[@"call_index"], @"name" : call[@"name"],
    @"arguments_sha256" : call[@"arguments_sha256"],
    @"safe_summary_key" : call[@"safe_summary_key"], @"access" : call[@"access"],
    @"approval_token" : token[@"token"], @"approval_decision" : @"allow_once",
    @"approval_reference" : approvalReference,
    @"idempotency_key" : call[@"idempotency_key"],
    @"native_row_revision" : call[@"native_row_revision"],
    @"receipt" : NSNull.null,
  } mutableCopy];
  NSDictionary *agent = @{ @"schema_version" : @3,
    @"phase" : @"execution_intent", @"root" : fixture[@"root"],
    @"transcript" : receipt[@"transcript"],
    @"round_lineage" : @{ @"round_id" : fixture[@"round_id"],
                           @"round_index" : @0 },
    @"batch" : @[persistedCall] };
  NSDictionary *session = @{ @"schema_version" : @9,
    @"conversations" : @[@{ @"id" : fixture[@"conversation"],
      @"agent_grants" : @[],
      @"attempts" : @[@{ @"attempt_id" : fixture[@"attempt"],
        @"journal_revision" : @1, @"agent" : agent }] }],
    @"session_events" : @[@{
      @"schema_version" : @2, @"event_id" : approvalReference,
      @"attempt_id" : fixture[@"attempt"], @"seq" : @1,
      @"kind" : @"approval", @"round_index" : @0,
      @"call_id" : call[@"call_id"], @"status" : @"approval",
      @"safe_summary_key" : call[@"safe_summary_key"],
      @"arguments_sha256" : call[@"arguments_sha256"],
      @"result_sha256" : NSNull.null,
      @"approval_reference" : approvalReference,
      @"failure_code" : NSNull.null,
      @"created_at" : @"2026-08-31T00:00:00.000Z",
    }],
  };
  AgentEffectsSessionStore *sessionStore = fixture[@"session_store"];
  sessionStore.fakeLoadResult = [self loadResultForSession:session generation:@3
      digest:fixture[@"checkpoint"][@"session_sha256"]];
  NSDictionary *baseBind = @{ @"schema_version" : @2,
    @"operation_id" : @"72727272-7272-4272-8272-727272727272",
    @"controller_cas" : fixture[@"controller"],
    @"committed_checkpoint" : fixture[@"checkpoint"],
    @"task_id" : fixture[@"task"], @"conversation_id" : fixture[@"conversation"],
    @"attempt_id" : fixture[@"attempt"], @"round_id" : fixture[@"round_id"],
    @"round_index" : @0, @"manifest_sha256" : receipt[@"manifest_sha256"],
    @"batch_revision" : receipt[@"batch_revision"], @"call_index" : @0,
    @"call_id" : call[@"call_id"], @"token" : token,
    @"decision" : @"allow_once", @"deny_message" : NSNull.null };
  NSArray<NSDictionary *> *tamperedTokens = @[
    ({ NSMutableDictionary *v = [token mutableCopy];
       v[@"token"] = @"91919191-9191-4191-8191-919191919191"; v; }),
    ({ NSMutableDictionary *v = [token mutableCopy];
       v[@"root_fingerprint_sha256"] =
         @"9090909090909090909090909090909090909090909090909090909090909090"; v; }),
    ({ NSMutableDictionary *v = [token mutableCopy]; v[@"binding_revision"] = @999; v; }),
    ({ NSMutableDictionary *v = [token mutableCopy];
       v[@"round_id"] = @"92929292-9292-4292-8292-929292929292"; v; }),
    ({ NSMutableDictionary *v = [token mutableCopy]; v[@"round_index"] = @1; v; }),
    ({ NSMutableDictionary *v = [token mutableCopy]; v[@"batch_revision"] = @999; v; }),
    ({ NSMutableDictionary *v = [token mutableCopy]; v[@"call_id"] = @"other-call";
       v[@"batch_call_ids"] = @[@"other-call"]; v; }),
    ({ NSMutableDictionary *v = [token mutableCopy]; v[@"arguments_sha256"] =
         @"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
       v[@"batch_arguments_sha256"] = @[
         @"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"]; v; }),
    ({ NSMutableDictionary *v = [token mutableCopy]; v[@"manifest_sha256"] =
         @"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"; v; }),
    ({ NSMutableDictionary *v = [token mutableCopy]; v[@"idempotency_key"] =
         @"1212121212121212121212121212121212121212121212121212121212121212"; v; }),
    ({ NSMutableDictionary *v = [token mutableCopy]; v[@"name"] = @"write_file"; v; }),
    ({ NSMutableDictionary *v = [token mutableCopy]; v[@"name"] = @"git_push";
       v[@"access"] = @"confirm_once";
       v[@"allowed_decisions"] = @[@"denied", @"allow_once", @"allow_conversation", @"cancelled"]; v; }),
    ({ NSMutableDictionary *v = [token mutableCopy];
       NSString *other = @"93939393-9393-4393-8393-939393939393";
       v[@"task_id"] = other;
       NSMutableDictionary *cas = [v[@"controller_cas"] mutableCopy];
       cas[@"task_id"] = other; v[@"controller_cas"] = cas; v; }),
    ({ NSMutableDictionary *v = [token mutableCopy];
       NSMutableDictionary *cas = [v[@"controller_cas"] mutableCopy];
       cas[@"expected_controller_generation"] = @999; v[@"controller_cas"] = cas; v; }),
  ];
  for (NSUInteger index = 0; index < tamperedTokens.count; index += 1) {
    NSMutableDictionary *request = [baseBind mutableCopy];
    request[@"operation_id"] = [NSString stringWithFormat:
        @"73737373-7373-4373-8373-%012lu", (unsigned long)(index + 1)];
    request[@"token"] = tamperedTokens[index];
    error = nil;
    NSDictionary *conflict = [batchService bindAgentApprovalWithRequest:request
                                                                   error:&error];
    XCTAssertNil(error);
    XCTAssertEqualObjects(conflict[@"status"], @"conflict");
    XCTAssertEqualObjects(conflict[@"failure_code"], @"E_AGENT_APPROVAL");
  }
  error = nil;
  NSDictionary *bound = [batchService bindAgentApprovalWithRequest:baseBind
                                                              error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(bound[@"status"], @"bound");
  XCTAssertEqualObjects(bound[@"approval_reference"], approvalReference);

  AgentEffectsGitExecutor *git = fixture[@"git_executor"];
  DSHAgentToolExecutionService *execution = [[DSHAgentToolExecutionService alloc]
      initWithWAL:self.wal ledger:self.ledger
      preparedStore:fixture[@"prepared_store"] transcripts:self.transcripts
      workspaceExecutor:fixture[@"workspace_executor"] gitExecutor:git];
  NSDictionary *executeRequest = @{ @"schema_version" : @2,
    @"operation_id" : @"74747474-7474-4474-8474-747474747474",
    @"controller_cas" : fixture[@"controller"],
    @"committed_checkpoint" : fixture[@"checkpoint"],
    @"task_id" : fixture[@"task"], @"conversation_id" : fixture[@"conversation"],
    @"attempt_id" : fixture[@"attempt"], @"round_id" : fixture[@"round_id"],
    @"round_index" : @0, @"batch_kind" : @"write_batch",
    @"manifest_sha256" : receipt[@"manifest_sha256"],
    @"expected_batch_revision" : receipt[@"batch_revision"],
    @"call_index" : @0, @"call_id" : call[@"call_id"],
    @"name" : call[@"name"], @"arguments_sha256" : call[@"arguments_sha256"],
    @"idempotency_key" : call[@"idempotency_key"],
    @"expected_execution_revision" : call[@"native_row_revision"],
    @"transcript" : receipt[@"transcript"], @"root" : fixture[@"root"],
    @"approval_reference" : approvalReference };
  NSDictionary *executed = [execution executeAgentToolWithRequest:executeRequest
                                                             error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(executed[@"status"], @"completed");
  XCTAssertEqual(git.effectCount, 1U);
  NSDictionary *replayed = [execution executeAgentToolWithRequest:executeRequest
                                                             error:&error];
  XCTAssertEqualObjects(replayed, executed);
  XCTAssertEqual(git.effectCount, 1U);
}

- (void)testBatchOperationResultFaultRollsBackWholeMutationBatch {
  __block BOOL failCompoundCommit = NO;
  [self resetStoresWithFaultHook:^BOOL(NSString *stage) {
    return !(failCompoundCommit &&
             [stage isEqualToString:@"wal.operation.before_result_commit"]);
  } name:@"batch-fault"];
  NSDictionary *rawCommit = @{ @"schema_version" : @1,
    @"call_id" : @"commit-call", @"name" : @"git_commit",
    @"arguments_json" : @"{\"message\":\"m\"}" };
  NSDictionary *fixture = [self serviceFixtureForRawCalls:@[rawCommit]];
  failCompoundCommit = YES;
  NSError *error = nil;
  NSDictionary *result = [fixture[@"batch_service"]
      prepareAgentToolBatchWithRequest:fixture[@"batch_request"] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"rejected");
  XCTAssertEqualObjects(result[@"failure_code"], @"E_AGENT_LEDGER");
  NSDictionary *state = [self.wal snapshotWithError:&error];
  XCTAssertEqual([state[@"batches"] count], 0U);
  XCTAssertEqual([state[@"ledger"] count], 0U);
  XCTAssertEqual([state[@"denied_calls"] count], 0U);
  XCTAssertEqualObjects(state[@"authorities"][0][@"authority_revision"], @1);
  NSDictionary *operation = [state[@"operations"] filteredArrayUsingPredicate:
      [NSPredicate predicateWithFormat:@"operation_kind == %@",
       @"prepare_agent_tool_batch"]].firstObject;
  XCTAssertEqualObjects(operation[@"state"], @"rejected");
}

- (void)testMidPreflightRebindRejectsWithoutManifestOrIntent {
  NSDictionary *rawCommit = @{ @"schema_version" : @1,
    @"call_id" : @"commit-call", @"name" : @"git_commit",
    @"arguments_json" : @"{\"message\":\"m\"}" };
  NSDictionary *fixture = [self serviceFixtureForRawCalls:@[rawCommit]];
  AgentEffectsRootResolver *resolver = fixture[@"resolver"];
  AgentEffectsGitExecutor *git = fixture[@"git_executor"];
  git.onPrepare = ^{ resolver.rejectRoot = YES; };
  NSError *error = nil;
  NSDictionary *result = [fixture[@"batch_service"]
      prepareAgentToolBatchWithRequest:fixture[@"batch_request"] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"rejected");
  XCTAssertEqualObjects(result[@"failure_code"], @"E_AGENT_ROOT_STALE");
  NSDictionary *state = [self.wal snapshotWithError:&error];
  XCTAssertEqual([state[@"batches"] count], 0U);
  XCTAssertEqual([state[@"ledger"] count], 0U);
  XCTAssertEqualObjects(state[@"authorities"][0][@"authority_revision"], @1);
}

- (void)testBatchPreflightHoldsSessionWorkspaceCoordinatorUntilCommit {
  NSDictionary *rawCommit = @{ @"schema_version" : @1,
    @"call_id" : @"commit-call", @"name" : @"git_commit",
    @"arguments_json" : @"{\"message\":\"m\"}" };
  NSDictionary *fixture = [self serviceFixtureForRawCalls:@[rawCommit]];
  DSHSessionWorkspaceCoordinator *coordinator =
      [fixture[@"session_store"] coordinator];
  AgentEffectsGitExecutor *git = fixture[@"git_executor"];
  dispatch_semaphore_t contenderStarted = dispatch_semaphore_create(0);
  dispatch_semaphore_t contenderFinished = dispatch_semaphore_create(0);
  __block BOOL contenderRan = NO;
  git.onPrepare = ^{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      dispatch_semaphore_signal(contenderStarted);
      [coordinator performSync:^{ contenderRan = YES; }];
      dispatch_semaphore_signal(contenderFinished);
    });
    XCTAssertEqual(dispatch_semaphore_wait(
        contenderStarted, dispatch_time(DISPATCH_TIME_NOW,
                                        (int64_t)(NSEC_PER_SEC))), 0L);
    XCTAssertNotEqual(dispatch_semaphore_wait(
        contenderFinished, dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(50 * NSEC_PER_MSEC))), 0L);
  };

  NSError *error = nil;
  NSDictionary *result = [fixture[@"batch_service"]
      prepareAgentToolBatchWithRequest:fixture[@"batch_request"] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"prepared", @"%@", result);
  XCTAssertEqual(dispatch_semaphore_wait(
      contenderFinished, dispatch_time(DISPATCH_TIME_NOW,
                                       (int64_t)(NSEC_PER_SEC))), 0L);
  XCTAssertTrue(contenderRan);
}

- (void)testBatchPreparationIsReentrantOnSessionWorkspaceCoordinator {
  NSDictionary *rawCommit = @{ @"schema_version" : @1,
    @"call_id" : @"commit-call", @"name" : @"git_commit",
    @"arguments_json" : @"{\"message\":\"m\"}" };
  NSDictionary *fixture = [self serviceFixtureForRawCalls:@[rawCommit]];
  DSHSessionWorkspaceCoordinator *coordinator =
      [fixture[@"session_store"] coordinator];
  __block NSError *error = nil;
  __block NSDictionary *result = nil;
  [coordinator performSync:^{
    result = [fixture[@"batch_service"]
        prepareAgentToolBatchWithRequest:fixture[@"batch_request"] error:&error];
  }];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"prepared", @"%@", result);
}

- (void)testBadPathPreflightReturnsImmutableClosedRejection {
  NSDictionary *rawRead = @{ @"schema_version" : @1,
    @"call_id" : @"read-call", @"name" : @"read_file",
    @"arguments_json" : @"{\"path\":\"../secret\"}",
    @"arguments_sha256" :
        @"3434343434343434343434343434343434343434343434343434343434343434" };
  NSDictionary *fixture = [self serviceFixtureForRawCalls:@[rawRead]];
  NSError *error = nil;
  NSDictionary *result = [fixture[@"batch_service"]
      prepareAgentToolBatchWithRequest:fixture[@"batch_request"] error:&error];
  XCTAssertNil(error);
  // The fixture's arguments digest does not match the raw arguments: an
  // identity mismatch is never reinterpreted as a model mistake, so the
  // batch stays a closed rejection (refused arguments with a matching
  // digest settle instead; see the next test).
  XCTAssertEqualObjects(result[@"status"], @"rejected");
  XCTAssertEqualObjects(result[@"failure_code"], @"E_AGENT_BAD_PATH");
  XCTAssertEqualObjects(result[@"effect_dispatched"], @NO);
  NSDictionary *state = [self.wal snapshotWithError:&error];
  XCTAssertEqual([state[@"batches"] count], 0U);
  XCTAssertEqual([state[@"ledger"] count], 0U);
  NSDictionary *operation = [state[@"operations"] filteredArrayUsingPredicate:
      [NSPredicate predicateWithFormat:@"operation_kind == %@",
       @"prepare_agent_tool_batch"]].firstObject;
  XCTAssertEqualObjects(operation[@"state"], @"rejected");
}

- (void)testRefusedArgumentsSettleEveryCallAsFailedFeedbackForTheNextRound {
  NSDictionary *rawRead = @{ @"schema_version" : @1,
    @"call_id" : @"read-good", @"name" : @"read_file",
    @"arguments_json" : @"{\"path\":\"README.md\"}" };
  NSDictionary *rawBad = @{ @"schema_version" : @1,
    @"call_id" : @"read-bad", @"name" : @"read_file",
    @"arguments_json" : @"{\"path\":\"/workspace/README.md\"}" };
  NSDictionary *fixture = [self serviceFixtureForRawCalls:@[rawRead, rawBad]];
  NSError *error = nil;
  NSDictionary *transcriptBefore = fixture[@"batch_request"][@"transcript"];
  NSDictionary *result = [fixture[@"batch_service"]
      prepareAgentToolBatchWithRequest:fixture[@"batch_request"] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"prepared", @"%@", result);
  NSArray *calls = result[@"receipt"][@"calls"];
  XCTAssertEqual(calls.count, 2U);
  // The refused call carries its own reason; its valid sibling is not run
  // either and says so, so the next round reconsiders the batch as a unit.
  XCTAssertEqualObjects(calls[1][@"receipt"][@"failure_code"], @"E_AGENT_BAD_PATH");
  XCTAssertEqualObjects(calls[0][@"receipt"][@"failure_code"], @"E_AGENT_BAD_PATH");
  XCTAssertEqualObjects(calls[0][@"execution_status"], @"failed");
  XCTAssertNotEqualObjects(calls[0][@"idempotency_key"], NSNull.null);
  for (NSDictionary *call in calls) {
    XCTAssertEqualObjects(call[@"receipt"][@"outcome"], @"failed");
    XCTAssertEqualObjects(call[@"receipt"][@"duration_ms"], @0);
    XCTAssertEqualObjects(call[@"receipt"][@"approval_reference"], NSNull.null);
    XCTAssertEqualObjects(call[@"native_row_revision"], @1);
    XCTAssertEqualObjects(call[@"execution_revision"], @1);
  }
  NSDictionary *state = [self.wal snapshotWithError:&error];
  XCTAssertEqual([state[@"ledger"] count], 0U);
  XCTAssertEqual([state[@"batches"] count], 1U);
  NSArray *rejectedRows = state[@"denied_calls"];
  XCTAssertEqual(rejectedRows.count, 2U);
  XCTAssertEqualObjects(rejectedRows[0][@"feedback"][@"payload"][@"reason"],
                        @"not_executed_because_another_call_was_rejected");
  XCTAssertEqualObjects(rejectedRows[1][@"feedback"][@"payload"][@"reason"],
                        @"path_must_be_relative_to_workspace_root");
  // The transcript advanced by one tool message per call, in call order.
  NSDictionary *transcriptAfter = result[@"receipt"][@"transcript"];
  XCTAssertEqual([transcriptAfter[@"generation"] unsignedIntegerValue],
                 [transcriptBefore[@"generation"] unsignedIntegerValue] + 2);
  NSDictionary *transcriptRow = nil;
  for (NSDictionary *candidate in state[@"transcripts"]) {
    if ([candidate[@"transcript_ref"] isEqual:transcriptAfter[@"transcript_ref"]]) transcriptRow = candidate;
  }
  NSArray *messages = transcriptRow[@"messages"];
  XCTAssertTrue(messages.count >= 2);
  NSDictionary *lastMessage = messages.lastObject;
  XCTAssertEqualObjects(lastMessage[@"role"], @"tool");
  XCTAssertEqualObjects(lastMessage[@"call_id"], @"read-bad");
  XCTAssertTrue([lastMessage[@"content"] containsString:@"\"outcome\":\"failed\""]);
  XCTAssertTrue([lastMessage[@"content"] containsString:@"path_must_be_relative_to_workspace_root"]);
  XCTAssertFalse([lastMessage[@"content"] containsString:@"/workspace/README.md"]);
  // Replaying the same operation returns the settlements without appending.
  NSDictionary *replay = [fixture[@"batch_service"]
      prepareAgentToolBatchWithRequest:fixture[@"batch_request"] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(replay[@"receipt"][@"calls"][1][@"receipt"],
                        calls[1][@"receipt"]);
  XCTAssertEqual([[self.wal snapshotWithError:&error][@"denied_calls"] count], 2U);
}

- (void)testExistingFileWithAbsentWritePreconditionIsARequeryableConflict {
  NSDictionary *rawWrite = @{
    @"schema_version" : @1,
    @"call_id" : @"write-existing-call",
    @"name" : @"write_file",
    @"arguments_json" :
        @"{\"content\":\"provider smoke 0903\",\"expected_revision\":null,\"path\":\"SMOKE-1.md\"}",
  };
  NSDictionary *fixture = [self serviceFixtureForRawCalls:@[rawWrite]];
  AgentEffectsWorkspaceExecutor *workspace = fixture[@"workspace_executor"];
  // The concrete workspace executor returns Conflict for this exact shape
  // when SMOKE-1.md already exists. Exercise the batch-service translation
  // without weakening any of its authority or transcript checks.
  workspace.prepareFailureCode = DSHAgentNativeStoreErrorConflict;

  NSError *error = nil;
  NSDictionary *result = [fixture[@"batch_service"]
      prepareAgentToolBatchWithRequest:fixture[@"batch_request"] error:&error];

  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"rejected");
  XCTAssertEqualObjects(result[@"failure_code"], @"E_AGENT_CONFLICT");
  XCTAssertEqualObjects(result[@"retry_advice"], @"requery");
  XCTAssertEqualObjects(result[@"effect_gate"], @"closed");
  XCTAssertEqualObjects(result[@"effect_dispatched"], @NO);
  NSDictionary *state = [self.wal snapshotWithError:&error];
  XCTAssertNil(error);
  XCTAssertEqual([state[@"batches"] count], 0U);
  XCTAssertEqual([state[@"ledger"] count], 0U);
}

- (void)testWorkspaceUnavailablePreflightRetainsCapabilityRejection {
  NSDictionary *rawRead = @{
    @"schema_version" : @1,
    @"call_id" : @"read-unavailable-call",
    @"name" : @"read_file",
    @"arguments_json" : @"{\"path\":\"README.md\"}",
  };
  NSDictionary *fixture = [self serviceFixtureForRawCalls:@[rawRead]];
  AgentEffectsWorkspaceExecutor *workspace = fixture[@"workspace_executor"];
  workspace.prepareFailureCode = DSHAgentNativeStoreErrorUnavailable;

  NSError *error = nil;
  NSDictionary *result = [fixture[@"batch_service"]
      prepareAgentToolBatchWithRequest:fixture[@"batch_request"] error:&error];

  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"rejected");
  XCTAssertEqualObjects(result[@"failure_code"], @"E_AGENT_CAPABILITY");
  XCTAssertEqualObjects(result[@"retry_advice"], @"none");
  XCTAssertEqualObjects(result[@"effect_gate"], @"not_applicable");
  XCTAssertEqualObjects(result[@"effect_dispatched"], @NO);
}

- (void)testSettlementFaultOwnerLossReplayAndRecoveryNeverDuplicateGitEffect {
  __block BOOL failCompoundCommit = NO;
  [self resetStoresWithFaultHook:^BOOL(NSString *stage) {
    return !(failCompoundCommit &&
             [stage isEqualToString:@"wal.operation.before_result_commit"]);
  } name:@"settlement-fault"];
  NSDictionary *rawCommit = @{ @"schema_version" : @1,
    @"call_id" : @"commit-call", @"name" : @"git_commit",
    @"arguments_json" : @"{\"message\":\"m\"}" };
  NSDictionary *fixture = [self serviceFixtureForRawCalls:@[rawCommit]];
  NSString *grantID = @"81818181-8181-4181-8181-818181818181";
  NSDictionary *grant = @{ @"schema_version" : @2, @"grant_id" : grantID,
    @"conversation_id" : fixture[@"conversation"],
    @"workspace_id" : fixture[@"root"][@"workspace_id"],
    @"project_id" : fixture[@"root"][@"project_id"],
    @"binding_revision" : fixture[@"root"][@"workspace_binding_revision"],
    @"root_fingerprint_sha256" : fixture[@"root"][@"root_fingerprint_sha256"],
    @"tool_family" : @"git_commit", @"registry_version" : @1,
    @"policy_version" : @"agent-v1",
    @"issued_for" : @{ @"schema_version" : @1,
                        @"task_id" : fixture[@"task"],
                        @"attempt_id" : fixture[@"attempt"] },
    @"created_at" : @"2026-08-31T00:00:00.000Z" };
  NSDictionary *grantSession = @{ @"schema_version" : @9,
    @"conversations" : @[@{ @"id" : fixture[@"conversation"],
      @"agent_grants" : @[grant],
      @"attempts" : @[@{ @"attempt_id" : fixture[@"attempt"],
        @"journal_revision" : @1, @"agent" : NSNull.null }] }],
    @"session_events" : @[] };
  AgentEffectsSessionStore *sessionStore = fixture[@"session_store"];
  sessionStore.fakeLoadResult = [self loadResultForSession:grantSession generation:@3
      digest:fixture[@"checkpoint"][@"session_sha256"]];
  NSError *error = nil;
  NSDictionary *prepared = [fixture[@"batch_service"]
      prepareAgentToolBatchWithRequest:fixture[@"batch_request"] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(prepared[@"status"], @"prepared", @"%@", prepared);
  if (![prepared[@"status"] isEqualToString:@"prepared"]) return;
  NSDictionary *receipt = prepared[@"receipt"];
  NSDictionary *call = receipt[@"calls"][0];
  XCTAssertEqualObjects(call[@"approval_state"], @"bound");
  XCTAssertEqualObjects(call[@"approval_reference"], grantID);
  NSDictionary *journalCall = @{ @"schema_version" : @3,
    @"call_id" : call[@"call_id"], @"call_index" : @0, @"name" : call[@"name"],
    @"arguments_sha256" : call[@"arguments_sha256"],
    @"safe_summary_key" : call[@"safe_summary_key"], @"access" : call[@"access"],
    @"approval_token" : NSNull.null, @"approval_decision" : @"allow_conversation",
    @"approval_reference" : grantID, @"idempotency_key" : call[@"idempotency_key"],
    @"native_row_revision" : call[@"native_row_revision"], @"receipt" : NSNull.null };
  NSDictionary *executionSession = @{ @"schema_version" : @9,
    @"conversations" : @[@{ @"id" : fixture[@"conversation"],
      @"agent_grants" : @[grant],
      @"attempts" : @[@{ @"attempt_id" : fixture[@"attempt"],
        @"journal_revision" : @1,
        @"agent" : @{ @"phase" : @"execution_intent",
          @"root" : fixture[@"root"], @"transcript" : receipt[@"transcript"],
          @"round_lineage" : @{ @"round_id" : fixture[@"round_id"],
                                 @"round_index" : @0 },
          @"batch" : @[journalCall] } }] }], @"session_events" : @[] };
  sessionStore.fakeLoadResult = [self loadResultForSession:executionSession generation:@3
      digest:fixture[@"checkpoint"][@"session_sha256"]];
  AgentEffectsGitExecutor *git = fixture[@"git_executor"];
  DSHAgentToolExecutionService *execution = [[DSHAgentToolExecutionService alloc]
      initWithWAL:self.wal ledger:self.ledger
      preparedStore:fixture[@"prepared_store"] transcripts:self.transcripts
      workspaceExecutor:fixture[@"workspace_executor"] gitExecutor:git];
  NSDictionary *request = @{ @"schema_version" : @2,
    @"operation_id" : @"82828282-8282-4282-8282-828282828282",
    @"controller_cas" : fixture[@"controller"],
    @"committed_checkpoint" : fixture[@"checkpoint"],
    @"task_id" : fixture[@"task"], @"conversation_id" : fixture[@"conversation"],
    @"attempt_id" : fixture[@"attempt"], @"round_id" : fixture[@"round_id"],
    @"round_index" : @0, @"batch_kind" : @"write_batch",
    @"manifest_sha256" : receipt[@"manifest_sha256"],
    @"expected_batch_revision" : receipt[@"batch_revision"],
    @"call_index" : @0, @"call_id" : call[@"call_id"], @"name" : call[@"name"],
    @"arguments_sha256" : call[@"arguments_sha256"],
    @"idempotency_key" : call[@"idempotency_key"],
    @"expected_execution_revision" : call[@"native_row_revision"],
    @"transcript" : receipt[@"transcript"], @"root" : fixture[@"root"],
    @"approval_reference" : grantID };
  failCompoundCommit = YES;
  NSDictionary *lost = [execution executeAgentToolWithRequest:request error:&error];
  XCTAssertEqualObjects(lost[@"status"], @"ambiguous");
  XCTAssertEqual(git.effectCount, 1U);
  NSDictionary *lostState = [self.wal snapshotWithError:&error];
  NSDictionary *lostOperation = [lostState[@"operations"]
      filteredArrayUsingPredicate:[NSPredicate
          predicateWithFormat:@"operation_id == %@", request[@"operation_id"]]]
      .firstObject;
  NSDictionary *lostRow = [lostState[@"ledger"]
      filteredArrayUsingPredicate:[NSPredicate
          predicateWithFormat:@"locator.call_id == %@", request[@"call_id"]]]
      .firstObject;
  XCTAssertEqualObjects(lostOperation[@"state"], @"started");
  XCTAssertEqualObjects(lostRow[@"state"], @"running");
  XCTAssertEqualObjects([self.wal dispatchStateForKind:@"execution"
                                               locator:lostRow[@"locator"]
                                                 error:&error], @"dispatched");
  XCTAssertFalse([self.wal isNativeTaskAlive:lostRow[@"owner"][@"native_task_id"]
                                      launchId:lostRow[@"owner"][@"launch_id"]]);
  error = nil;
  NSDictionary *replay = [execution executeAgentToolWithRequest:request error:&error];
  XCTAssertEqualObjects(replay[@"status"], @"ambiguous", @"%@", error);
  XCTAssertEqual(git.effectCount, 1U);
  failCompoundCommit = NO;
  NSDictionary *recovered = [execution recoverAgentToolWithRequest:request error:&error];
  XCTAssertEqualObjects(recovered[@"status"], @"completed");
  XCTAssertEqual(git.effectCount, 1U);
  NSDictionary *finalReplay = [execution executeAgentToolWithRequest:request error:&error];
  XCTAssertEqualObjects(finalReplay, recovered);
  XCTAssertEqual(git.effectCount, 1U);
}

- (void)testWriteBatchCapacityFailureIsAtomicAndExactReplayIsIdempotent {
  NSDictionary *root = [self rootWithCapabilities:@[@"file_write"]];
  NSDictionary *transcript = [self transcriptForRoot:root];
  NSString *large = [@"x" stringByPaddingToLength:20000
                                        withString:@"x" startingAtIndex:0];
  NSArray *over = @[
    [self writeCallAtIndex:0 path:@"a.txt" content:large],
    [self writeCallAtIndex:1 path:@"b.txt" content:large],
  ];
  NSError *error = nil;
  XCTAssertNil([self.ledger prepareAgentToolBatchWithRequest:
      [self batchRequestWithRoot:root transcript:transcript calls:over
                           policy:[self policyWithBatch:32768 attempt:65536]
                       roundIndex:0] error:&error]);
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorCapacity);
  NSDictionary *snapshot = [self.wal snapshotWithError:nil];
  XCTAssertEqual([snapshot[@"ledger"] count], 0U);
  XCTAssertEqual([snapshot[@"batches"] count], 0U);
  XCTAssertEqual([snapshot[@"reservations"] count], 0U);

  error = nil;
  NSArray *one = @[[self writeCallAtIndex:0 path:@"a.txt" content:@"hello"]];
  NSDictionary *request = [self batchRequestWithRoot:root transcript:transcript
                                                calls:one
                                               policy:[self policyWithBatch:32768
                                                                      attempt:65536]
                                           roundIndex:0];
  NSDictionary *first = [self.ledger prepareAgentToolBatchWithRequest:request
                                                                 error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(first[@"status"], @"prepared");
  XCTAssertEqualObjects(first[@"batch_kind"], @"write_batch");
  XCTAssertEqualObjects(first[@"batch_new_write_bytes"], @5);
  NSDictionary *replay = [self.ledger prepareAgentToolBatchWithRequest:request
                                                                  error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(replay[@"status"], @"already_prepared");
  snapshot = [self.wal snapshotWithError:nil];
  XCTAssertEqual([snapshot[@"ledger"] count], 1U);
  XCTAssertEqual([snapshot[@"batches"] count], 1U);
  XCTAssertEqualObjects(snapshot[@"reservations"][0][@"reserved_write_bytes"], @5);
}

- (void)testDurableDeniedOnlyBatchHasNoExecutionRowOrIdempotencyKey {
  NSDictionary *root = [self rootWithCapabilities:@[@"file_read"]];
  NSDictionary *transcript = [self transcriptForRoot:root];
  NSError *error = nil;
  NSString *argumentsSHA = DSHAgentArgumentsSHA256(@"unknown_tool", @"{}",
                                                    &error);
  NSDictionary *call = @{
    @"call_index" : @0, @"call_id" : @"denied_0",
    @"name" : @"unknown_tool", @"arguments_json" : @"{}",
    @"arguments_sha256" : argumentsSHA,
    @"safe_summary_key" : @"agent.unknown", @"access" : @"durable_deny",
    @"precondition" : NSNull.null, @"reserved_write_bytes" : @0,
  };
  NSDictionary *result = [self.ledger prepareAgentToolBatchWithRequest:
      [self batchRequestWithRoot:root transcript:transcript calls:@[call]
                           policy:[self policyWithBatch:32768 attempt:65536]
                       roundIndex:0] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"batch_kind"], @"read_only_batch");
  XCTAssertEqualObjects(result[@"calls"][0][@"execution_status"], @"denied");
  XCTAssertEqualObjects(result[@"calls"][0][@"idempotency_key"], NSNull.null);
  XCTAssertEqualObjects(result[@"calls"][0][@"receipt"][@"outcome"], @"denied");
  XCTAssertEqualObjects(result[@"calls"][0][@"receipt"][@"failure_code"],
                        @"E_AGENT_UNKNOWN_TOOL");
  NSDictionary *snapshot = [self.wal snapshotWithError:nil];
  XCTAssertEqual([snapshot[@"ledger"] count], 0U);
  XCTAssertEqual([snapshot[@"dispatch"] count], 0U);
  XCTAssertEqual([snapshot[@"denied_calls"] count], 1U);
  XCTAssertEqualObjects(snapshot[@"transcripts"][0][@"generation"], @1);
}

- (void)testRealGitExecutorPushesToBareOriginOnlyAfterOneAcceptedRefStatus {
  NSDictionary *fixture = [self realGitExecutorFixtureNamed:@"push-success"
      projectID:@"91919191-9191-4191-8191-919191919191"];
  XCTAssertNotNil(fixture);
  if (fixture == nil) return;
  git_repository *repository = nullptr;
  XCTAssertEqual(git_repository_open(&repository,
      [fixture[@"repository_url"] fileSystemRepresentation]), 0);
  XCTAssertNotEqual(repository, nullptr);
  if (repository == nullptr) return;
  XCTAssertTrue([self writeFixtureFileNamed:@"success.txt" content:@"ok\n"
                              repositoryURL:fixture[@"repository_url"]]);
  NSString *targetOID = [self createFixtureCommitInRepository:repository
      parent:fixture[@"base_oid"] message:@"success"
      updateMainBranch:YES timestampSeconds:2];
  git_repository_free(repository);
  XCTAssertNotNil(targetOID);

  DSHAgentGitToolExecutor *executor = fixture[@"executor"];
  NSError *error = nil;
  NSDictionary *prepared = [executor prepareToolNamed:@"git_push"
      arguments:@{} root:fixture[@"root"] error:&error];
  XCTAssertNotNil(prepared);
  XCTAssertNil(error);
  XCTAssertEqualObjects(prepared[@"precondition"][@"pre_remote_oid"],
                        fixture[@"base_oid"]);
  XCTAssertEqualObjects(prepared[@"precondition"][@"target_oid"], targetOID);
  NSDictionary *effect = [executor executeToolNamed:@"git_push"
      arguments:@{} root:fixture[@"root"]
      precondition:prepared[@"precondition"] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(effect[@"status"], @"ok");
  XCTAssertEqualObjects([self feedbackObject:effect][@"outcome"], @"ok");
  XCTAssertEqualObjects([self referenceOIDNamed:@"refs/heads/main"
      repositoryURL:fixture[@"origin_url"]], targetOID);
  XCTAssertEqualObjects([self referenceOIDNamed:@"refs/remotes/origin/main"
      repositoryURL:fixture[@"repository_url"]], targetOID);
}

- (void)testRealGitExecutorTreatsBareOriginRefRejectionAsSanitizedFailure {
  NSDictionary *fixture = [self realGitExecutorFixtureNamed:@"push-rejected"
      projectID:@"92929292-9292-4292-8292-929292929292"];
  XCTAssertNotNil(fixture);
  if (fixture == nil) return;
  git_repository *repository = nullptr;
  XCTAssertEqual(git_repository_open(&repository,
      [fixture[@"repository_url"] fileSystemRepresentation]), 0);
  XCTAssertNotEqual(repository, nullptr);
  if (repository == nullptr) return;
  XCTAssertTrue([self writeFixtureFileNamed:@"rejected.txt" content:@"reject\n"
                              repositoryURL:fixture[@"repository_url"]]);
  NSString *targetOID = [self createFixtureCommitInRepository:repository
      parent:fixture[@"base_oid"] message:@"rejected"
      updateMainBranch:YES timestampSeconds:2];
  git_repository_free(repository);
  XCTAssertNotNil(targetOID);

  DSHAgentGitToolExecutor *executor = fixture[@"executor"];
  NSError *error = nil;
  NSDictionary *prepared = [executor prepareToolNamed:@"git_push"
      arguments:@{} root:fixture[@"root"] error:&error];
  XCTAssertNotNil(prepared);
  XCTAssertNil(error);
  NSURL *lockURL = [fixture[@"origin_url"]
      URLByAppendingPathComponent:@"refs/heads/main.lock"];
  XCTAssertTrue([[@"held" dataUsingEncoding:NSUTF8StringEncoding]
      writeToURL:lockURL options:0 error:&error]);
  XCTAssertNil(error);
  NSDictionary *effect = [executor executeToolNamed:@"git_push"
      arguments:@{} root:fixture[@"root"]
      precondition:prepared[@"precondition"] error:&error];
  [NSFileManager.defaultManager removeItemAtURL:lockURL error:nil];
  XCTAssertNil(error);
  XCTAssertEqualObjects(effect[@"status"], @"failed");
  XCTAssertEqualObjects(effect[@"effect_may_have_occurred"], @NO);
  NSDictionary *feedback = [self feedbackObject:effect];
  XCTAssertEqualObjects(feedback, (@{
    @"schema_version" : @1, @"name" : @"git_push", @"outcome" : @"failed",
    @"payload" : @{ @"schema_version" : @1,
                       @"failure_code" : @"E_AGENT_TOOL_FAILED",
                       @"reason" : @"rejected" },
  }));
  XCTAssertFalse([effect[@"feedback"] containsString:@"lock"]);
  XCTAssertFalse([effect[@"feedback"] containsString:
      [fixture[@"origin_url"] path]]);
  XCTAssertEqualObjects([self referenceOIDNamed:@"refs/heads/main"
      repositoryURL:fixture[@"origin_url"]], fixture[@"base_oid"]);
  XCTAssertNotEqualObjects([self referenceOIDNamed:@"refs/remotes/origin/main"
      repositoryURL:fixture[@"repository_url"]], targetOID);
}

- (void)testRealGitExecutorCommitUsesExpectedOldOIDReferenceCAS {
  NSDictionary *fixture = [self realGitExecutorFixtureNamed:@"commit-cas"
      projectID:@"93939393-9393-4393-8393-939393939393"];
  XCTAssertNotNil(fixture);
  if (fixture == nil) return;
  XCTAssertTrue([self writeFixtureFileNamed:@"agent.txt" content:@"agent\n"
                              repositoryURL:fixture[@"repository_url"]]);
  DSHAgentGitToolExecutor *executor = fixture[@"executor"];
  NSDictionary *arguments = @{ @"message" : @"agent commit" };
  NSError *error = nil;
  NSDictionary *prepared = [executor prepareToolNamed:@"git_commit"
      arguments:arguments root:fixture[@"root"] error:&error];
  XCTAssertNotNil(prepared);
  XCTAssertNil(error);
  XCTAssertEqualObjects(prepared[@"precondition"][@"pre_head_oid"],
                        fixture[@"base_oid"]);

  // Preserve the prepared index/tree while moving the branch to a competing
  // commit.  Execution can create its deterministic object, but the final
  // expected-old-OID transaction must not overwrite this concurrent ref.
  git_repository *repository = nullptr;
  XCTAssertEqual(git_repository_open(&repository,
      [fixture[@"repository_url"] fileSystemRepresentation]), 0);
  XCTAssertNotEqual(repository, nullptr);
  if (repository == nullptr) return;
  NSString *concurrentOID = [self createFixtureCommitInRepository:repository
      parent:fixture[@"base_oid"] message:@"concurrent"
      updateMainBranch:YES timestampSeconds:3];
  git_repository_free(repository);
  XCTAssertNotNil(concurrentOID);
  NSDictionary *effect = [executor executeToolNamed:@"git_commit"
      arguments:arguments root:fixture[@"root"]
      precondition:prepared[@"precondition"] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(effect[@"status"], @"failed");
  XCTAssertEqualObjects(effect[@"effect_may_have_occurred"], @NO);
  XCTAssertEqualObjects([self feedbackObject:effect][@"payload"]
                        [@"failure_code"], @"E_AGENT_CONFLICT");
  XCTAssertEqualObjects([self referenceOIDNamed:@"refs/heads/main"
      repositoryURL:fixture[@"repository_url"]], concurrentOID);
  XCTAssertNotEqualObjects(concurrentOID,
                           prepared[@"precondition"][@"expected_commit_oid"]);
}

- (void)testRealGitExecutorSuccessfulCommitPublishesTheCommittedIndex {
  NSDictionary *fixture = [self realGitExecutorFixtureNamed:@"commit-clean-index"
      projectID:@"94949494-9494-4494-8494-949494949494"];
  XCTAssertNotNil(fixture);
  if (fixture == nil) return;
  XCTAssertTrue([self writeFixtureFileNamed:@"agent.txt" content:@"agent\n"
                              repositoryURL:fixture[@"repository_url"]]);
  DSHAgentGitToolExecutor *executor = fixture[@"executor"];
  NSDictionary *arguments = @{ @"message" : @"agent commit" };
  NSError *error = nil;
  NSDictionary *prepared = [executor prepareToolNamed:@"git_commit"
      arguments:arguments root:fixture[@"root"] error:&error];
  XCTAssertNotNil(prepared);
  XCTAssertNil(error);
  NSDictionary *effect = [executor executeToolNamed:@"git_commit"
      arguments:arguments root:fixture[@"root"]
      precondition:prepared[@"precondition"] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(effect[@"status"], @"ok");
  XCTAssertEqualObjects([self referenceOIDNamed:@"refs/heads/main"
      repositoryURL:fixture[@"repository_url"]],
      prepared[@"precondition"][@"expected_commit_oid"]);

  NSDictionary *statusPrepared = [executor prepareToolNamed:@"git_status"
      arguments:@{} root:fixture[@"root"] error:&error];
  XCTAssertNotNil(statusPrepared);
  NSDictionary *statusEffect = [executor executeToolNamed:@"git_status"
      arguments:@{} root:fixture[@"root"]
      precondition:statusPrepared[@"precondition"] error:&error];
  XCTAssertNil(error);
  NSDictionary *payload = [self feedbackObject:statusEffect][@"payload"];
  XCTAssertEqualObjects(payload[@"clean"], @YES);
  XCTAssertEqualObjects(payload[@"entry_count"], @0);
}

- (void)testWorkspaceExecutorUsesFrozenRootLeaseAndRecoversWriteByBytes {
  NSURL *privateRoot = [self.rootURL URLByAppendingPathComponent:@"workspace-private"
                                                     isDirectory:YES];
  NSURL *documents = [self.rootURL URLByAppendingPathComponent:@"Documents"
                                                   isDirectory:YES];
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:privateRoot
                                         withIntermediateDirectories:YES
                                                          attributes:@{NSFilePosixPermissions : @0700}
                                                               error:nil]);
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:documents
                                         withIntermediateDirectories:YES
                                                          attributes:nil
                                                               error:nil]);
  DSHLocalWorkspaceAccess *access = [[DSHLocalWorkspaceAccess alloc]
      initWithPrivateRootURL:privateRoot
      documentsRootURL:documents
      clock:^NSDate * { return [NSDate dateWithTimeIntervalSince1970:1788134400]; }
      UUIDGenerator:^NSString * {
        return @"55555555-5555-4555-8555-555555555555";
      }
      legacyResolver:^BOOL(NSString *projectId, NSDictionary **evidence,
                           NSError **error) {
        (void)projectId;
        if (evidence != nil) *evidence = nil;
        (void)error;
        return NO;
      }
      faultHook:nil];
  NSError *error = nil;
  XCTAssertTrue([access ensurePrivateLayoutWithError:&error]);
  XCTAssertNil(error);
  NSDictionary *created = [access createRishOwnedWorkspaceWithDisplayName:@"Agent"
      operationId:@"66666666-6666-4666-8666-666666666666" error:&error];
  XCTAssertNotNil(created);
  XCTAssertNil(error);
  DSHAgentRootResolver *resolver = [[DSHAgentRootResolver alloc]
      initWithWorkspaceAccess:access projectAccess:nil];
  DSHAgentWorkspaceToolExecutor *executor =
      [[DSHAgentWorkspaceToolExecutor alloc] initWithRootResolver:resolver];
  NSDictionary *writeRoot = [resolver resolveRootForWorkspaceId:created[@"workspace_id"]
      projectId:nil bindingRevision:created[@"binding_revision"] error:&error];
  XCTAssertNotNil(writeRoot);
  XCTAssertNil(error);
  NSDictionary *arguments = @{
    @"path" : @"proof.txt", @"content" : @"proof",
    @"expected_prior" : @{ @"schema_version" : @1, @"kind" : @"absent" },
  };
  NSDictionary *prepared = [executor prepareToolNamed:@"write_file"
                                             arguments:arguments root:writeRoot
                                                  error:&error];
  XCTAssertNotNil(prepared);
  XCTAssertNil(error);
  NSDictionary *effect = [executor executeToolNamed:@"write_file"
                                          arguments:arguments root:writeRoot
                                       precondition:prepared[@"precondition"]
                                               error:&error];
  XCTAssertEqualObjects(effect[@"status"], @"ok");
  XCTAssertNil(error);
  NSDictionary *conflictingPrepare = [executor prepareToolNamed:@"write_file"
      arguments:arguments root:writeRoot error:&error];
  XCTAssertNil(conflictingPrepare);
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorConflict);
  error = nil;
  NSDictionary *recovered = [executor recoverToolNamed:@"write_file"
                                             arguments:arguments root:writeRoot
                                          precondition:prepared[@"precondition"]
                                                  error:&error];
  XCTAssertEqualObjects(recovered[@"status"], @"settled");

  NSDictionary *readPrepared = [executor prepareToolNamed:@"read_file"
      arguments:@{ @"path" : @"proof.txt" } root:writeRoot error:&error];
  NSDictionary *read = [executor executeToolNamed:@"read_file"
      arguments:@{ @"path" : @"proof.txt" } root:writeRoot
      precondition:readPrepared[@"precondition"] error:&error];
  NSData *feedbackBytes = [read[@"feedback"] dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *feedback = [NSJSONSerialization JSONObjectWithData:feedbackBytes
                                                            options:0 error:&error];
  XCTAssertEqualObjects(feedback[@"payload"][@"content"], @"proof");
  XCTAssertNil(error);
  NSString *proofSHA = @"c1cda26362828b69266512052b97cb3729e3b052e4ade47c0a1e3383defe73c7";
  XCTAssertEqualObjects(feedback[@"payload"][@"sha256"], proofSHA);
  NSDictionary *writeFeedback = [NSJSONSerialization JSONObjectWithData:[effect[@"feedback"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
  XCTAssertEqualObjects(writeFeedback[@"payload"][@"sha256"], proofSHA);
  NSURL *container = [documents URLByAppendingPathComponent:@"Rish Workspaces" isDirectory:YES];
  NSArray<NSURL *> *workspaceDirs = [NSFileManager.defaultManager contentsOfDirectoryAtURL:container includingPropertiesForKeys:nil options:0 error:nil];
  XCTAssertEqual(workspaceDirs.count, 1U);
  if (workspaceDirs.count != 1) return;
  NSString *large = [@"a" stringByPaddingToLength:70 * 1024 withString:@"a" startingAtIndex:0];
  XCTAssertTrue([large writeToURL:[workspaceDirs.firstObject URLByAppendingPathComponent:@"large.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
  NSDictionary *largeArgs = @{ @"path": @"large.txt" };
  NSDictionary *largePrepared = [executor prepareToolNamed:@"read_file" arguments:largeArgs root:writeRoot error:nil];
  NSDictionary *largeEffect = [executor executeToolNamed:@"read_file" arguments:largeArgs root:writeRoot precondition:largePrepared[@"precondition"] error:nil];
  NSDictionary *largeFeedback = [NSJSONSerialization JSONObjectWithData:[largeEffect[@"feedback"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
  XCTAssertEqualObjects(largeFeedback[@"payload"][@"truncated"], @YES);
  XCTAssertNil(largeFeedback[@"payload"][@"sha256"]);
}

- (void)testWorkspaceExecutorListDirHidesReservedNativeEntries {
  // Real-device finding: list_dir("") leaked the reserved `.trash` directory.
  // The entry list must hide the same reserved names the local-workspace path
  // validator hides (.git, .trash, .staging-*, .rish-write-* case-folded)
  // while ordinary dotfiles stay visible.
  NSURL *privateRoot = [self.rootURL URLByAppendingPathComponent:@"listdir-private"
                                                     isDirectory:YES];
  NSURL *documents = [self.rootURL URLByAppendingPathComponent:@"listdir-documents"
                                                   isDirectory:YES];
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:privateRoot
                                         withIntermediateDirectories:YES
                                                          attributes:@{NSFilePosixPermissions : @0700}
                                                               error:nil]);
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:documents
                                         withIntermediateDirectories:YES
                                                          attributes:nil
                                                               error:nil]);
  DSHLocalWorkspaceAccess *access = [[DSHLocalWorkspaceAccess alloc]
      initWithPrivateRootURL:privateRoot
      documentsRootURL:documents
      clock:^NSDate * { return [NSDate dateWithTimeIntervalSince1970:1788134400]; }
      UUIDGenerator:^NSString * {
        return @"55555555-5555-4555-8555-555555555556";
      }
      legacyResolver:^BOOL(NSString *projectId, NSDictionary **evidence,
                           NSError **error) {
        (void)projectId;
        if (evidence != nil) *evidence = nil;
        (void)error;
        return NO;
      }
      faultHook:nil];
  NSError *error = nil;
  XCTAssertTrue([access ensurePrivateLayoutWithError:&error]);
  XCTAssertNil(error);
  NSDictionary *created = [access createRishOwnedWorkspaceWithDisplayName:@"Listdir"
      operationId:@"66666666-6666-4666-8666-666666666667" error:&error];
  XCTAssertNotNil(created);
  XCTAssertNil(error);
  if (created == nil) return;
  DSHAgentRootResolver *resolver = [[DSHAgentRootResolver alloc]
      initWithWorkspaceAccess:access projectAccess:nil];
  DSHAgentWorkspaceToolExecutor *executor =
      [[DSHAgentWorkspaceToolExecutor alloc] initWithRootResolver:resolver];
  NSDictionary *root = [resolver resolveRootForWorkspaceId:created[@"workspace_id"]
      projectId:nil bindingRevision:created[@"binding_revision"] error:&error];
  XCTAssertNotNil(root);
  XCTAssertNil(error);
  if (root == nil) return;

  // Locate the single owned workspace directory and seed reserved entries.
  NSURL *container = [documents URLByAppendingPathComponent:@"Rish Workspaces"
                                                isDirectory:YES];
  NSArray<NSURL *> *workspaceDirs = [NSFileManager.defaultManager
      contentsOfDirectoryAtURL:container
      includingPropertiesForKeys:nil options:0 error:nil];
  XCTAssertEqual(workspaceDirs.count, 1);
  if (workspaceDirs.count != 1) return;
  NSURL *workspaceURL = workspaceDirs.firstObject;
  NSArray<NSString *> *reserved = @[
    @".GIT", @".TRASH", @".STAGING-tmp", @".RISH-WRITE-x",
  ];
  for (NSString *name in reserved) {
    NSURL *url = [workspaceURL URLByAppendingPathComponent:name isDirectory:YES];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:url
                                           withIntermediateDirectories:YES
                                                            attributes:nil
                                                                 error:nil]);
  }
  for (NSString *name in @[ @".gitignore", @"notes.txt" ]) {
    NSURL *url = [workspaceURL URLByAppendingPathComponent:name isDirectory:NO];
    XCTAssertTrue([@"seed\n" writeToURL:url atomically:YES
                              encoding:NSUTF8StringEncoding error:nil]);
  }

  NSDictionary *prepared = [executor prepareToolNamed:@"list_dir"
                                             arguments:@{} root:root error:&error];
  XCTAssertNotNil(prepared);
  XCTAssertNil(error);
  if (prepared == nil) return;
  NSDictionary *effect = [executor executeToolNamed:@"list_dir"
                                           arguments:@{} root:root
                                        precondition:prepared[@"precondition"]
                                               error:&error];
  XCTAssertEqualObjects(effect[@"status"], @"ok");
  XCTAssertNil(error);
  NSData *feedbackBytes = [effect[@"feedback"] dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *feedback = [NSJSONSerialization JSONObjectWithData:feedbackBytes
                                                            options:0 error:&error];
  XCTAssertNil(error);
  NSArray<NSDictionary *> *entries = feedback[@"payload"][@"entries"];
  XCTAssertNotNil(entries);
  if (entries == nil) return;
  NSMutableSet<NSString *> *names = [NSMutableSet set];
  for (NSDictionary *entry in entries) {
    [names addObject:entry[@"name"]];
  }
  XCTAssertTrue([names containsObject:@"notes.txt"]);
  XCTAssertTrue([names containsObject:@".gitignore"]);
  for (NSString *name in names) {
    NSString *folded = name.lowercaseString;
    XCTAssertFalse([folded isEqual:@".git"] || [folded isEqual:@".trash"] ||
        [folded hasPrefix:@".staging-"] || [folded hasPrefix:@".rish-write-"],
        @"reserved native entry %@ leaked into list_dir", name);
  }
}

- (NSDictionary *)persistedCallForProjection:(NSDictionary *)call
                                    decision:(NSString *)decision
                                   reference:(id)reference {
  NSDictionary *token = call[@"approval_token"];
  BOOL allowed = [decision hasPrefix:@"allow_"];
  return @{ @"schema_version" : @3, @"call_id" : call[@"call_id"],
    @"call_index" : call[@"call_index"], @"name" : call[@"name"],
    @"arguments_sha256" : call[@"arguments_sha256"],
    @"safe_summary_key" : call[@"safe_summary_key"], @"access" : call[@"access"],
    @"approval_token" : allowed && [token isKindOfClass:NSDictionary.class]
        ? token[@"token"] : NSNull.null,
    @"approval_decision" : decision,
    @"approval_reference" : reference ?: NSNull.null,
    @"idempotency_key" : call[@"idempotency_key"],
    @"native_row_revision" : call[@"native_row_revision"],
    @"receipt" : NSNull.null };
}

- (NSDictionary *)persistedCallForProjection:(NSDictionary *)call
                                    decision:(NSString *)decision
                                   reference:(id)reference
                                     receipt:(NSDictionary *)receipt
                                 rowRevision:(NSNumber *)rowRevision {
  NSMutableDictionary *persisted = [[self persistedCallForProjection:call
      decision:decision reference:reference] mutableCopy];
  persisted[@"receipt"] = receipt ?: NSNull.null;
  persisted[@"native_row_revision"] = rowRevision;
  return persisted;
}

- (NSDictionary *)approvalEventForCall:(NSDictionary *)call
                               attempt:(NSString *)attempt
                               eventId:(NSString *)eventId
                                   seq:(NSNumber *)seq {
  // The JS decide_approval preflight marker: its reference is its own id for
  // every decision; an allowed bind later returns that id as the approval
  // reference while a denial keeps the call reference null.
  return @{ @"schema_version" : @2, @"event_id" : eventId,
    @"attempt_id" : attempt, @"seq" : seq, @"kind" : @"approval",
    @"round_index" : @0, @"call_id" : call[@"call_id"],
    @"status" : @"approval", @"safe_summary_key" : call[@"safe_summary_key"],
    @"arguments_sha256" : call[@"arguments_sha256"],
    @"result_sha256" : NSNull.null, @"approval_reference" : eventId,
    @"failure_code" : NSNull.null,
    @"created_at" : @"2026-08-31T00:00:00.000Z" };
}

- (NSDictionary *)bindRequestForFixture:(NSDictionary *)fixture
                                 receipt:(NSDictionary *)receipt
                                    call:(NSDictionary *)call
                             operationId:(NSString *)operationId
                                decision:(NSString *)decision
                             denyMessage:(id)denyMessage {
  return @{ @"schema_version" : @2, @"operation_id" : operationId,
    @"controller_cas" : fixture[@"controller"],
    @"committed_checkpoint" : fixture[@"checkpoint"],
    @"task_id" : fixture[@"task"], @"conversation_id" : fixture[@"conversation"],
    @"attempt_id" : fixture[@"attempt"], @"round_id" : fixture[@"round_id"],
    @"round_index" : @0, @"manifest_sha256" : receipt[@"manifest_sha256"],
    @"batch_revision" : receipt[@"batch_revision"],
    @"call_index" : call[@"call_index"], @"call_id" : call[@"call_id"],
    @"token" : call[@"approval_token"], @"decision" : decision,
    @"deny_message" : denyMessage ?: NSNull.null };
}

- (NSDictionary *)executeRequestForFixture:(NSDictionary *)fixture
                                    receipt:(NSDictionary *)receipt
                                       call:(NSDictionary *)call
                                operationId:(NSString *)operationId
                          approvalReference:(id)approvalReference {
  return @{ @"schema_version" : @2, @"operation_id" : operationId,
    @"controller_cas" : fixture[@"controller"],
    @"committed_checkpoint" : fixture[@"checkpoint"],
    @"task_id" : fixture[@"task"], @"conversation_id" : fixture[@"conversation"],
    @"attempt_id" : fixture[@"attempt"], @"round_id" : fixture[@"round_id"],
    @"round_index" : @0, @"batch_kind" : @"write_batch",
    @"manifest_sha256" : receipt[@"manifest_sha256"],
    @"expected_batch_revision" : receipt[@"batch_revision"],
    @"call_index" : call[@"call_index"], @"call_id" : call[@"call_id"],
    @"name" : call[@"name"], @"arguments_sha256" : call[@"arguments_sha256"],
    @"idempotency_key" : call[@"idempotency_key"],
    @"expected_execution_revision" : call[@"native_row_revision"],
    @"transcript" : receipt[@"transcript"], @"root" : fixture[@"root"],
    @"approval_reference" : approvalReference ?: NSNull.null };
}

- (NSDictionary *)sessionForFixture:(NSDictionary *)fixture
                              phase:(NSString *)phase
                         transcript:(NSDictionary *)transcript
                              calls:(NSArray<NSDictionary *> *)calls
                             events:(NSArray<NSDictionary *> *)events
                             grants:(NSArray<NSDictionary *> *)grants {
  return @{ @"schema_version" : @9,
    @"conversations" : @[@{ @"id" : fixture[@"conversation"],
      @"agent_grants" : grants,
      @"attempts" : @[@{ @"attempt_id" : fixture[@"attempt"],
        @"journal_revision" : @1,
        @"agent" : @{ @"schema_version" : @3, @"phase" : phase,
          @"root" : fixture[@"root"], @"transcript" : transcript,
          @"round_lineage" : @{ @"round_id" : fixture[@"round_id"],
                                 @"round_index" : @0 },
          @"batch" : calls } }] }],
    @"session_events" : events };
}

- (void)testGuestCgiRealBatchApprovalExecutionAndReplay {
 NSString *sha = @"c1cda26362828b69266512052b97cb3729e3b052e4ade47c0a1e3383defe73c7";
 NSDictionary *args = @{ @"index_path": @"index.html", @"index_sha256": sha, @"backend_path": @"backend.sh", @"backend_sha256": sha, @"initial_data_path": NSNull.null, @"initial_data_sha256": NSNull.null };
 NSString *json = [[NSString alloc] initWithData:DSHAgentCanonicalJSON(args, nil) encoding:NSUTF8StringEncoding];
 NSError *parseError = nil;
 NSDictionary *providerResponse = @{ @"id": @"response-cgi", @"model": @"deepseek-v4-flash", @"choices": @[@{ @"finish_reason": @"tool_calls", @"message": @{ @"role": @"assistant", @"content": NSNull.null, @"reasoning_content": @"Start the approved demo.", @"tool_calls": @[@{ @"id": @"start-cgi", @"type": @"function", @"function": @{ @"name": @"start_guest_cgi", @"arguments": json } }] } }] };
 NSDictionary *parsed = DSHParseCompletionResponseSchema2(providerResponse, @"deepseek-v4-flash", @"high", &parseError);
 XCTAssertNotNil(parsed); XCTAssertNil(parseError); if (!parsed) return;
 NSDictionary *parsedCall = DSHCompletionNormalizeToolCalls(parsed[@"tool_calls"])[0];
 NSDictionary *message = DSHProviderNativeToCompletionMessage(@{ @"schema_version": @1, @"role": @"assistant", @"round_index": @0, @"content": parsed[@"text"], @"reasoning_content": parsed[@"reasoning"], @"tool_calls": @[@{ @"call_id": parsedCall[@"id"], @"name": parsedCall[@"name"], @"arguments": parsedCall[@"arguments"] }] }, &parseError);
 XCTAssertNotNil(message); XCTAssertNil(parseError); if (!message) return;
 NSDictionary *raw = message[@"tool_calls"][0];
 NSDictionary *fixture = [self realWorkspaceServiceFixtureForRawCalls:@[raw]];
 XCTAssertNotNil(fixture); if (!fixture) return;
 DSHAgentWorkspaceToolExecutor *workspace = fixture[@"workspace_executor"];
 for (NSString *path in @[@"index.html", @"backend.sh"]) {
   NSDictionary *write = @{ @"path": path, @"content": @"proof", @"expected_prior": @{ @"schema_version": @1, @"kind": @"absent" } };
   NSDictionary *pre = [workspace prepareToolNamed:@"write_file" arguments:write root:fixture[@"root"] error:nil];
   XCTAssertNotNil(pre);
   NSDictionary *effect = [workspace executeToolNamed:@"write_file" arguments:write root:fixture[@"root"] precondition:pre[@"precondition"] error:nil];
   XCTAssertEqualObjects(effect[@"status"], @"ok");
 }
 AgentEffectsCgiService *service = [AgentEffectsCgiService new];
 DSHAgentGuestCgiToolExecutor *adapter = [DSHAgentGuestCgiToolExecutor executorForWorkspaceExecutor:workspace];
 [adapter setValue:service forKey:@"service"];
 NSError *error = nil;
 DSHAgentToolBatchService *batch = fixture[@"batch_service"];
 NSMutableDictionary *batchRequest = [fixture[@"batch_request"] mutableCopy]; batchRequest[@"registry_version"] = fixture[@"registry"][@"registry_version"];
 NSDictionary *prepared = [batch prepareAgentToolBatchWithRequest:batchRequest error:&error];
 XCTAssertNil(error); XCTAssertEqualObjects(prepared[@"status"], @"prepared");
 if (![prepared[@"status"] isEqual:@"prepared"]) return;
 NSDictionary *receipt = prepared[@"receipt"], *call = receipt[@"calls"][0];
 XCTAssertEqualObjects(receipt[@"effect_gate"], @"closed");
 XCTAssertEqualObjects(call[@"approval_state"], @"pending");
 XCTAssertEqualObjects(call[@"approval_preview"][@"paths"], (@[@"index.html", @"backend.sh"]));
 XCTAssertEqualObjects(call[@"approval_token"][@"registry_version"], fixture[@"registry"][@"registry_version"]);
 XCTAssertEqual(service.starts, 0U);
 NSString *marker = @"91919191-9191-4191-8191-919191919191";
 NSArray *calls = @[[self persistedCallForProjection:call decision:@"allow_once" reference:marker]];
 NSArray *events = @[[self approvalEventForCall:call attempt:fixture[@"attempt"] eventId:marker seq:@1]];
 AgentEffectsSessionStore *sessions = fixture[@"session_store"];
 sessions.fakeLoadResult = [self loadResultForSession:[self sessionForFixture:fixture phase:@"approval_pending" transcript:receipt[@"transcript"] calls:calls events:events grants:@[]] generation:@3 digest:fixture[@"checkpoint"][@"session_sha256"]];
 NSDictionary *bound = [batch bindAgentApprovalWithRequest:[self bindRequestForFixture:fixture receipt:receipt call:call operationId:marker decision:@"allow_once" denyMessage:nil] error:&error];
 XCTAssertNil(error); XCTAssertEqualObjects(bound[@"status"], @"bound");
 XCTAssertEqual(service.starts, 0U);
 sessions.fakeLoadResult = [self loadResultForSession:[self sessionForFixture:fixture phase:@"execution_intent" transcript:receipt[@"transcript"] calls:calls events:events grants:@[]] generation:@3 digest:fixture[@"checkpoint"][@"session_sha256"]];
 DSHAgentToolExecutionService *execution = [[DSHAgentToolExecutionService alloc] initWithWAL:self.wal ledger:self.ledger preparedStore:fixture[@"prepared_store"] transcripts:self.transcripts workspaceExecutor:workspace gitExecutor:fixture[@"git_executor"]];
 NSDictionary *request = [self executeRequestForFixture:fixture receipt:receipt call:call operationId:@"92929292-9292-4292-8292-929292929292" approvalReference:marker];
 XCTestExpectation *done = [self expectationWithDescription:@"CGI effect and replay"];
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
   NSError *executeError = nil;
   NSDictionary *result = [execution executeAgentToolWithRequest:request error:&executeError];
   XCTAssertNil(executeError); XCTAssertEqualObjects(result[@"status"], @"completed");
   NSDictionary *replayed = [execution executeAgentToolWithRequest:request error:&executeError];
   XCTAssertNil(executeError); XCTAssertEqualObjects(replayed, result);
   [done fulfill];
 });
 [self waitForExpectations:@[done] timeout:10];
 XCTAssertEqual(service.starts, 1U);
}

- (void)testExecutionSkipsNullApprovalReceiptsBeforeItsPreparedBatch {
  NSDictionary *rawWrite = @{ @"schema_version" : @1,
    @"call_id" : @"write-after-approval", @"name" : @"write_file",
    @"arguments_json" :
        @"{\"path\":\"AFTER.md\",\"content\":\"after\\n\",\"expected_revision\":null}" };
  NSDictionary *fixture = [self realWorkspaceServiceFixtureForRawCalls:@[rawWrite]];
  if (fixture == nil) return;
  NSError *error = nil;
  DSHAgentToolBatchService *batchService = fixture[@"batch_service"];
  NSDictionary *prepared = [batchService
      prepareAgentToolBatchWithRequest:fixture[@"batch_request"] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(prepared[@"status"], @"prepared");
  if (![prepared[@"status"] isEqual:@"prepared"]) return;
  NSDictionary *receipt = prepared[@"receipt"];
  NSDictionary *call = receipt[@"calls"][0];
  NSString *marker = @"91919191-9191-4191-8191-919191919191";
  NSArray *calls = @[[self persistedCallForProjection:call
      decision:@"allow_once" reference:marker]];
  NSArray *events = @[[self approvalEventForCall:call attempt:fixture[@"attempt"]
      eventId:marker seq:@1]];
  AgentEffectsSessionStore *sessions = fixture[@"session_store"];
  sessions.fakeLoadResult = [self loadResultForSession:
      [self sessionForFixture:fixture phase:@"approval_pending"
          transcript:receipt[@"transcript"] calls:calls events:events grants:@[]]
      generation:@3 digest:fixture[@"checkpoint"][@"session_sha256"]];
  NSDictionary *bound = [batchService bindAgentApprovalWithRequest:
      [self bindRequestForFixture:fixture receipt:receipt call:call
          operationId:marker decision:@"allow_once" denyMessage:nil] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(bound[@"status"], @"bound");
  XCTAssertEqualObjects(bound[@"receipt"], NSNull.null);

  // The WAL contains multiple result variants. A legal approval result can
  // precede the batch being looked up, as it does for later rounds/attempts.
  // Reorder real committed rows without changing their shape or authority.
  XCTAssertTrue([self.wal performAtomicTransaction:^BOOL(
      NSMutableDictionary *state, NSError **mutationError) {
    (void)mutationError;
    NSMutableArray *results = [state[@"operation_results"] mutableCopy];
    NSUInteger index = [results indexOfObjectPassingTest:
        ^BOOL(NSDictionary *result, NSUInteger idx, BOOL *stop) {
          (void)idx; (void)stop;
          return [result[@"operation_id"] isEqual:marker];
        }];
    if (index == NSNotFound) return NO;
    NSDictionary *approval = results[index];
    [results removeObjectAtIndex:index];
    [results insertObject:approval atIndex:0];
    state[@"operation_results"] = results;
    return YES;
  } error:&error]);
  XCTAssertNil(error);
  sessions.fakeLoadResult = [self loadResultForSession:
      [self sessionForFixture:fixture phase:@"execution_intent"
          transcript:receipt[@"transcript"] calls:calls events:events grants:@[]]
      generation:@3 digest:fixture[@"checkpoint"][@"session_sha256"]];
  DSHAgentToolExecutionService *execution = [[DSHAgentToolExecutionService alloc]
      initWithWAL:self.wal ledger:self.ledger
      preparedStore:fixture[@"prepared_store"] transcripts:self.transcripts
      workspaceExecutor:fixture[@"workspace_executor"] gitExecutor:fixture[@"git_executor"]];
  NSDictionary *request = [self executeRequestForFixture:fixture receipt:receipt
      call:call operationId:@"92929292-9292-4292-8292-929292929292"
      approvalReference:marker];
  NSDictionary *executed = nil;
  XCTAssertNoThrow(executed = [execution executeAgentToolWithRequest:request error:&error]);
  XCTAssertNil(error);
  XCTAssertEqualObjects(executed[@"status"], @"completed");
  if (executed == nil) return;
  NSURL *file = [self.rootURL URLByAppendingPathComponent:
      @"ServiceDocuments/Rish Workspaces/Service/AFTER.md"];
  XCTAssertEqualObjects([NSData dataWithContentsOfURL:file],
                       [@"after\n" dataUsingEncoding:NSUTF8StringEncoding]);
  NSDictionary *replayed = [execution executeAgentToolWithRequest:request error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(replayed, executed);
  NSArray *operations = [self.wal snapshotWithError:&error][@"operations"];
  NSArray *executes = [operations filteredArrayUsingPredicate:
      [NSPredicate predicateWithFormat:@"operation_kind == %@", @"execute_agent_tool"]];
  XCTAssertEqual(executes.count, 1U);
  XCTAssertEqualObjects(executes[0][@"state"], @"committed");
}

// Helper: create `content` at `path` through the executor and answer the
// revision a following write must expect.
- (NSString *)effectsWriteFile:(NSString *)path
                       content:(NSString *)content
                       fixture:(NSDictionary *)fixture
                      revision:(NSString *)expectedRevision {
  DSHAgentWorkspaceToolExecutor *workspace = fixture[@"workspace_executor"];
  NSDictionary *write = @{ @"path" : path, @"content" : content,
    @"expected_revision" : expectedRevision ?: NSNull.null };
  NSError *error = nil;
  NSDictionary *prepared = [workspace prepareToolNamed:@"write_file"
      arguments:write root:fixture[@"root"] error:&error];
  XCTAssertNil(error);
  XCTAssertNotNil(prepared);
  if (prepared == nil) return nil;
  XCTAssertEqualObjects([workspace executeToolNamed:@"write_file"
      arguments:write root:fixture[@"root"]
      precondition:prepared[@"precondition"] error:&error][@"status"], @"ok");
  XCTAssertNil(error);
  NSDictionary *read = [workspace prepareToolNamed:@"read_file"
      arguments:@{ @"path" : path } root:fixture[@"root"] error:&error];
  XCTAssertNil(error);
  return read[@"precondition"][@"source_revision"];
}

- (NSDictionary *)effectsRealWorkspaceFixture {
  // Only the root and the executor are used by the preview tests; the batch
  // request still needs a well-formed call, so it gets a trivial one.
  return [self realWorkspaceServiceFixtureForRawCalls:@[@{
    @"schema_version" : @1, @"call_id" : @"unused", @"name" : @"list_dir",
    @"arguments_json" : @"{\"path\":null}" }]];
}

// The approval preview's byte budget is in UTF-8 bytes, and the clip that
// enforces it used to be taken with -substringToIndex:, which counts UTF-16
// units.  For CJK text the two disagree by a factor of three, so a preview of
// 4,500 UTF-8 bytes is only 1,500 UTF-16 units and clipping it at index 2,048
// raised NSRangeException — taking the process down at the exact moment the
// human was being asked to approve a write.
- (void)testAWideCharacterPreviewIsClippedByBytesAndDoesNotRaise {
  NSDictionary *fixture = [self effectsRealWorkspaceFixture];
  XCTAssertNotNil(fixture);
  if (fixture == nil) return;
  NSMutableString *prior = [NSMutableString string];
  NSMutableString *next = [NSMutableString string];
  // Wide enough that the 24-line hunk cap still leaves a preview over the
  // 4,096-byte budget, while staying well under 2,048 UTF-16 units — the
  // exact gap the old clip fell through.
  NSString *tail = @"一直写下去一直写下去一直写下去一直写下去一直写下去";
  for (NSUInteger index = 0; index < 60; index += 1) {
    [prior appendFormat:@"旧的内容第%lu行%@\n", (unsigned long)index, tail];
    [next appendFormat:@"新的内容第%lu行%@\n", (unsigned long)index, tail];
  }
  NSString *revision = [self effectsWriteFile:@"CJK.md" content:prior
                                      fixture:fixture revision:nil];
  XCTAssertNotNil(revision);
  if (revision == nil) return;

  DSHAgentWorkspaceToolExecutor *workspace = fixture[@"workspace_executor"];
  NSError *error = nil;
  NSDictionary *prepared = [workspace prepareToolNamed:@"write_file"
      arguments:@{ @"path" : @"CJK.md", @"content" : next,
                   @"expected_revision" : revision }
      root:fixture[@"root"] error:&error];
  XCTAssertNil(error);
  XCTAssertNotNil(prepared);
  if (prepared == nil) return;
  NSDictionary *preview = prepared[@"approval_preview"];
  NSString *diff = preview[@"diff_preview"];
  XCTAssertTrue([diff isKindOfClass:NSString.class], @"%@", preview);
  if (![diff isKindOfClass:NSString.class]) return;
  // Clipped by bytes, on a character boundary, and honestly marked.
  XCTAssertLessThanOrEqual(
      [diff lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
      (NSUInteger)(4096 / 2) + 4);
  XCTAssertTrue([diff hasSuffix:@"\n…"], @"%@", diff);
  XCTAssertEqualObjects(preview[@"diff_truncated"], @YES);
  // A clip that split a multi-byte sequence would not round-trip.
  XCTAssertEqualObjects([[NSString alloc]
      initWithData:[diff dataUsingEncoding:NSUTF8StringEncoding]
          encoding:NSUTF8StringEncoding], diff);
}

// A file longer than the 2,000-line diff bound is compared only up to that
// line.  The helper recorded that, then overwrote the flag with whether the
// *hunk* had been truncated on the way out — so a 2,500-line file with one
// changed line in the first 2,000 was presented as a complete preview, and
// any change past line 2,000 was approved unseen.
- (void)testAPreviewCutAtTheLineBoundStaysMarkedTruncated {
  NSDictionary *fixture = [self effectsRealWorkspaceFixture];
  XCTAssertNotNil(fixture);
  if (fixture == nil) return;
  NSMutableString *prior = [NSMutableString string];
  for (NSUInteger index = 0; index < 2500; index += 1) {
    [prior appendFormat:@"line %04lu\n", (unsigned long)index];
  }
  NSMutableString *next = [prior mutableCopy];
  // One changed line well inside the bound, so the hunk itself is one line.
  [next replaceOccurrencesOfString:@"line 0005\n" withString:@"LINE 0005\n"
                           options:0 range:NSMakeRange(0, next.length)];
  NSString *revision = [self effectsWriteFile:@"WIDE.md" content:prior
                                      fixture:fixture revision:nil];
  XCTAssertNotNil(revision);
  if (revision == nil) return;

  DSHAgentWorkspaceToolExecutor *workspace = fixture[@"workspace_executor"];
  NSError *error = nil;
  NSDictionary *prepared = [workspace prepareToolNamed:@"write_file"
      arguments:@{ @"path" : @"WIDE.md", @"content" : next,
                   @"expected_revision" : revision }
      root:fixture[@"root"] error:&error];
  XCTAssertNil(error);
  XCTAssertNotNil(prepared);
  if (prepared == nil) return;
  NSDictionary *preview = prepared[@"approval_preview"];
  // The hunk is one line, so nothing on the way out would raise the flag;
  // only the line bound did, and it must survive.
  XCTAssertTrue([preview[@"diff_preview"] containsString:@"-line 0005"],
                @"%@", preview[@"diff_preview"]);
  XCTAssertEqualObjects(preview[@"diff_truncated"], @YES, @"%@", preview);
}

// Device evidence (2026-09-04): the executor previewed a new-file write with
// `prior = {schema_version, kind: absent}` while the ledger required the
// prior to carry `bytes` as well, so every first write into a workspace was
// rejected as E_AGENT_BAD_ARGUMENTS before approval.  This drives the real
// executor through the batch service so the two sides cannot drift apart
// again.
- (void)testBatchServiceAcceptsTheExecutorPreviewForANewFile {
  NSDictionary *rawWrite = @{ @"schema_version" : @1,
    @"call_id" : @"write-new", @"name" : @"write_file",
    @"arguments_json" :
        @"{\"path\":\"RF4-A.md\",\"content\":\"one\\n\",\"expected_revision\":null}" };
  NSDictionary *fixture = [self realWorkspaceServiceFixtureForRawCalls:@[rawWrite]];
  if (fixture == nil) return;
  DSHAgentToolBatchService *batchService = fixture[@"batch_service"];
  NSError *error = nil;
  NSDictionary *prepared = [batchService
      prepareAgentToolBatchWithRequest:fixture[@"batch_request"] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(prepared[@"status"], @"prepared", @"%@", prepared);
  if (![prepared[@"status"] isEqualToString:@"prepared"]) return;
  NSDictionary *call = prepared[@"receipt"][@"calls"][0];
  NSDictionary *preview = call[@"approval_preview"];
  XCTAssertEqualObjects(preview[@"kind"], @"write_file");
  XCTAssertEqualObjects(preview[@"paths"], @[@"RF4-A.md"]);
  XCTAssertEqualObjects(preview[@"content_bytes"], @4);
  NSDictionary *expectedPrior = @{ @"schema_version" : @1, @"kind" : @"absent",
                                   @"bytes" : NSNull.null };
  XCTAssertEqualObjects(preview[@"prior"], expectedPrior);
  XCTAssertEqualObjects(preview[@"diff_preview"], NSNull.null);
}

// Device evidence (2026-09-04): listing the workspace root previewed
// `paths = [""]`, which the ledger rejects because a preview path must be a
// non-empty relative path.  The root lists as no path at all, and a bare "."
// names the same root so a model's first instinct is not an E_AGENT_BAD_PATH.
- (void)testBatchServiceAcceptsTheExecutorPreviewForTheWorkspaceRoot {
  NSDictionary *rawEmpty = @{ @"schema_version" : @1,
    @"call_id" : @"list-root", @"name" : @"list_dir",
    @"arguments_json" : @"{\"path\":\"\"}" };
  NSDictionary *rawDot = @{ @"schema_version" : @1,
    @"call_id" : @"list-dot", @"name" : @"list_dir",
    @"arguments_json" : @"{\"path\":\".\"}" };
  NSDictionary *fixture =
      [self realWorkspaceServiceFixtureForRawCalls:@[rawEmpty, rawDot]];
  if (fixture == nil) return;
  DSHAgentToolBatchService *batchService = fixture[@"batch_service"];
  NSError *error = nil;
  NSDictionary *prepared = [batchService
      prepareAgentToolBatchWithRequest:fixture[@"batch_request"] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(prepared[@"status"], @"prepared", @"%@", prepared);
  if (![prepared[@"status"] isEqualToString:@"prepared"]) return;
  NSArray *calls = prepared[@"receipt"][@"calls"];
  XCTAssertEqual(calls.count, 2U);
  for (NSDictionary *call in calls) {
    NSDictionary *preview = call[@"approval_preview"];
    XCTAssertEqualObjects(preview[@"kind"], @"list_dir", @"%@", call);
    XCTAssertEqualObjects(preview[@"paths"], @[], @"%@", call);
    XCTAssertEqualObjects(preview[@"prior"], NSNull.null);
    XCTAssertEqualObjects(preview[@"content_bytes"], NSNull.null);
  }
}

- (void)testUserDenialBindSettlesDeniedReceiptAndProtectedFeedbackOnce {
  NSDictionary *rawCommit = @{ @"schema_version" : @1,
    @"call_id" : @"commit-call", @"name" : @"git_commit",
    @"arguments_json" : @"{\"message\":\"m\"}" };
  NSDictionary *fixture = [self serviceFixtureForRawCalls:@[rawCommit]];
  DSHAgentToolBatchService *batchService = fixture[@"batch_service"];
  NSError *error = nil;
  NSDictionary *prepared = [batchService
      prepareAgentToolBatchWithRequest:fixture[@"batch_request"] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(prepared[@"status"], @"prepared", @"%@", prepared);
  if (![prepared[@"status"] isEqualToString:@"prepared"]) return;
  NSDictionary *receipt = prepared[@"receipt"];
  NSDictionary *call = receipt[@"calls"][0];
  XCTAssertEqualObjects(call[@"approval_preview"][@"kind"], @"git_commit");
  XCTAssertEqualObjects(call[@"approval_preview"][@"paths"], @[]);

  // The Store committed the denial preflight: decision denied, token and
  // reference null, one decide_approval marker event.
  NSString *marker = @"75757575-7575-4575-8575-757575757575";
  NSDictionary *session = [self sessionForFixture:fixture
      phase:@"approval_pending" transcript:receipt[@"transcript"]
      calls:@[[self persistedCallForProjection:call decision:@"denied"
                                     reference:nil]]
      events:@[[self approvalEventForCall:call attempt:fixture[@"attempt"]
                                  eventId:marker seq:@1]]
      grants:@[]];
  AgentEffectsSessionStore *sessionStore = fixture[@"session_store"];
  sessionStore.fakeLoadResult = [self loadResultForSession:session generation:@3
      digest:fixture[@"checkpoint"][@"session_sha256"]];
  NSDictionary *request = [self bindRequestForFixture:fixture receipt:receipt
      call:call operationId:marker decision:@"denied"
      denyMessage:@"no commits today"];
  NSDictionary *bound = [batchService bindAgentApprovalWithRequest:request
                                                              error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(bound[@"status"], @"bound", @"%@", bound);
  if (![bound[@"status"] isEqualToString:@"bound"]) return;
  XCTAssertEqualObjects(bound[@"decision"], @"denied");
  XCTAssertEqualObjects(bound[@"approval_reference"], NSNull.null);
  XCTAssertEqualObjects(bound[@"grant"], NSNull.null);
  NSDictionary *deniedReceipt = bound[@"receipt"];
  XCTAssertEqualObjects(deniedReceipt[@"outcome"], @"denied");
  XCTAssertEqualObjects(deniedReceipt[@"failure_code"], @"E_AGENT_DENIED_BY_USER");
  XCTAssertEqualObjects(deniedReceipt[@"call_id"], call[@"call_id"]);
  XCTAssertEqualObjects(deniedReceipt[@"name"], @"git_commit");
  XCTAssertEqualObjects(deniedReceipt[@"arguments_sha256"],
                        call[@"arguments_sha256"]);
  XCTAssertEqualObjects(deniedReceipt[@"approval_reference"], NSNull.null);
  NSDictionary *settledTranscript = bound[@"transcript"];
  XCTAssertEqualObjects(settledTranscript[@"transcript_ref"],
                        receipt[@"transcript"][@"transcript_ref"]);
  XCTAssertEqual([settledTranscript[@"generation"] unsignedIntegerValue],
                 [receipt[@"transcript"][@"generation"] unsignedIntegerValue] + 1);

  // The WAL settled the never-dispatched intent row and appended exactly one
  // protected tool message carrying the bounded user message.
  NSDictionary *state = [self.wal snapshotWithError:&error];
  NSDictionary *row = [state[@"ledger"]
      filteredArrayUsingPredicate:[NSPredicate
          predicateWithFormat:@"locator.call_id == %@", call[@"call_id"]]]
      .firstObject;
  XCTAssertEqualObjects(row[@"state"], @"settled");
  XCTAssertEqualObjects(row[@"row_revision"], @2);
  XCTAssertEqualObjects(row[@"receipt"], deniedReceipt);
  XCTAssertEqualObjects(row[@"transcript_after"], settledTranscript);
  XCTAssertEqualObjects(row[@"settled_facts"], NSNull.null);
  XCTAssertEqualObjects([self.wal dispatchStateForKind:@"execution"
                                               locator:row[@"locator"]
                                                 error:&error], @"not_dispatched");
  NSDictionary *transcript = [state[@"transcripts"]
      filteredArrayUsingPredicate:[NSPredicate
          predicateWithFormat:@"transcript_ref == %@",
          settledTranscript[@"transcript_ref"]]].firstObject;
  XCTAssertEqualObjects(transcript[@"generation"], settledTranscript[@"generation"]);
  NSDictionary *message = [transcript[@"messages"] lastObject];
  XCTAssertEqualObjects(message[@"role"], @"tool");
  XCTAssertEqualObjects(message[@"call_id"], call[@"call_id"]);
  NSDictionary *feedback = [NSJSONSerialization JSONObjectWithData:
      [message[@"content"] dataUsingEncoding:NSUTF8StringEncoding]
      options:0 error:&error];
  XCTAssertEqualObjects(feedback[@"outcome"], @"denied");
  XCTAssertEqualObjects(feedback[@"name"], @"git_commit");
  XCTAssertEqualObjects(feedback[@"payload"][@"failure_code"],
                        @"E_AGENT_DENIED_BY_USER");
  XCTAssertEqualObjects(feedback[@"payload"][@"user_message"], @"no commits today");
  NSDictionary *authority = [state[@"authorities"]
      filteredArrayUsingPredicate:[NSPredicate
          predicateWithFormat:@"attempt_id == %@", fixture[@"attempt"]]]
      .firstObject;
  XCTAssertEqualObjects(authority[@"transcript"], settledTranscript);

  // Replaying the exact bind is idempotent: same settlement, no new message.
  NSDictionary *replayed = [batchService bindAgentApprovalWithRequest:request
                                                                 error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(replayed, bound);
  NSDictionary *replayState = [self.wal snapshotWithError:&error];
  NSDictionary *replayTranscript = [replayState[@"transcripts"]
      filteredArrayUsingPredicate:[NSPredicate
          predicateWithFormat:@"transcript_ref == %@",
          settledTranscript[@"transcript_ref"]]].firstObject;
  XCTAssertEqual([replayTranscript[@"messages"] count],
                 [transcript[@"messages"] count]);

  // A different decision for the same call is a conflict with zero effect.
  NSMutableDictionary *flipped = [request mutableCopy];
  flipped[@"operation_id"] = @"76767676-7676-4676-8676-767676767676";
  flipped[@"decision"] = @"allow_once";
  flipped[@"deny_message"] = NSNull.null;
  NSDictionary *conflict = [batchService bindAgentApprovalWithRequest:flipped
                                                                 error:&error];
  XCTAssertEqualObjects(conflict[@"status"], @"conflict", @"%@", conflict);

  // The denied call can never execute, even from a session that claims an
  // execution intent for it: no bind or grant ever authorised it.
  sessionStore.fakeLoadResult = [self loadResultForSession:
      [self sessionForFixture:fixture phase:@"execution_intent"
          transcript:receipt[@"transcript"]
          calls:@[[self persistedCallForProjection:call decision:@"denied"
                      reference:nil receipt:deniedReceipt rowRevision:@2]]
          events:@[] grants:@[]] generation:@3
      digest:fixture[@"checkpoint"][@"session_sha256"]];
  AgentEffectsGitExecutor *git = fixture[@"git_executor"];
  DSHAgentToolExecutionService *execution = [[DSHAgentToolExecutionService alloc]
      initWithWAL:self.wal ledger:self.ledger
      preparedStore:fixture[@"prepared_store"] transcripts:self.transcripts
      workspaceExecutor:fixture[@"workspace_executor"] gitExecutor:git];
  NSMutableDictionary *deniedExecute = [[self executeRequestForFixture:fixture
      receipt:receipt call:call
      operationId:@"77777777-7777-4777-8777-777777777777"
      approvalReference:nil] mutableCopy];
  deniedExecute[@"expected_execution_revision"] = @2;
  NSDictionary *executed = [execution executeAgentToolWithRequest:deniedExecute
                                                             error:&error];
  XCTAssertEqualObjects(executed[@"status"], @"conflict", @"%@", executed);
  XCTAssertEqualObjects(executed[@"failure_code"], @"E_AGENT_APPROVAL");
  XCTAssertEqual(git.effectCount, 0U);
}

- (void)testBatchDecisionsAreCheckpointedBeforeAnyEffectAndDeniedCallNeverRuns {
  NSDictionary *firstCommit = @{ @"schema_version" : @1,
    @"call_id" : @"commit-one", @"name" : @"git_commit",
    @"arguments_json" : @"{\"message\":\"one\"}" };
  NSDictionary *secondCommit = @{ @"schema_version" : @1,
    @"call_id" : @"commit-two", @"name" : @"git_commit",
    @"arguments_json" : @"{\"message\":\"two\"}" };
  NSDictionary *fixture = [self serviceFixtureForRawCalls:@[firstCommit,
                                                            secondCommit]];
  DSHAgentToolBatchService *batchService = fixture[@"batch_service"];
  NSError *error = nil;
  NSDictionary *prepared = [batchService
      prepareAgentToolBatchWithRequest:fixture[@"batch_request"] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(prepared[@"status"], @"prepared", @"%@", prepared);
  if (![prepared[@"status"] isEqualToString:@"prepared"]) return;
  NSDictionary *receipt = prepared[@"receipt"];
  XCTAssertEqualObjects(receipt[@"effect_gate"], @"closed");
  NSDictionary *first = receipt[@"calls"][0];
  NSDictionary *second = receipt[@"calls"][1];
  XCTAssertEqualObjects(first[@"approval_state"], @"pending");
  XCTAssertEqualObjects(second[@"approval_state"], @"pending");
  AgentEffectsSessionStore *sessionStore = fixture[@"session_store"];
  AgentEffectsGitExecutor *git = fixture[@"git_executor"];
  DSHAgentToolExecutionService *execution = [[DSHAgentToolExecutionService alloc]
      initWithWAL:self.wal ledger:self.ledger
      preparedStore:fixture[@"prepared_store"] transcripts:self.transcripts
      workspaceExecutor:fixture[@"workspace_executor"] gitExecutor:git];

  // Decision 1 of 2 checkpointed and bound: allow_once for the first call.
  NSString *firstMarker = @"78787878-7878-4878-8878-787878787878";
  NSDictionary *firstSession = [self sessionForFixture:fixture
      phase:@"approval_pending" transcript:receipt[@"transcript"]
      calls:@[[self persistedCallForProjection:first decision:@"allow_once"
                                     reference:firstMarker],
              [self persistedCallForProjection:second decision:@"pending"
                                     reference:nil]]
      events:@[[self approvalEventForCall:first attempt:fixture[@"attempt"]
                                  eventId:firstMarker seq:@1]]
      grants:@[]];
  sessionStore.fakeLoadResult = [self loadResultForSession:firstSession generation:@3
      digest:fixture[@"checkpoint"][@"session_sha256"]];
  NSDictionary *firstBound = [batchService bindAgentApprovalWithRequest:
      [self bindRequestForFixture:fixture receipt:receipt call:first
          operationId:firstMarker decision:@"allow_once" denyMessage:nil]
      error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(firstBound[@"status"], @"bound", @"%@", firstBound);
  XCTAssertEqualObjects(firstBound[@"approval_reference"], firstMarker);
  XCTAssertEqualObjects(firstBound[@"receipt"], NSNull.null);
  XCTAssertEqualObjects(firstBound[@"transcript"], NSNull.null);

  // The gate stays closed while the second decision is not checkpointed:
  // even with an execution intent persisted for the bound first call, the
  // batch effect gate refuses to open.
  sessionStore.fakeLoadResult = [self loadResultForSession:
      [self sessionForFixture:fixture phase:@"execution_intent"
          transcript:receipt[@"transcript"]
          calls:@[[self persistedCallForProjection:first decision:@"allow_once"
                                         reference:firstMarker],
                  [self persistedCallForProjection:second decision:@"pending"
                                         reference:nil]]
          events:@[[self approvalEventForCall:first attempt:fixture[@"attempt"]
                                      eventId:firstMarker seq:@1]]
          grants:@[]] generation:@3
      digest:fixture[@"checkpoint"][@"session_sha256"]];
  NSDictionary *early = [execution executeAgentToolWithRequest:
      [self executeRequestForFixture:fixture receipt:receipt call:first
          operationId:@"79797979-7979-4979-8979-797979797979"
          approvalReference:firstMarker] error:&error];
  XCTAssertNotEqualObjects(early[@"status"], @"completed", @"%@", early);
  XCTAssertNotEqualObjects(early[@"failure_code"], @"E_AGENT_ROOT_STALE", @"%@", early);
  XCTAssertEqual(git.effectCount, 0U);

  // Decision 2 of 2 checkpointed and bound: the second call is denied.
  NSString *secondMarker = @"80808080-8080-4080-8080-808080808080";
  NSDictionary *secondSession = [self sessionForFixture:fixture
      phase:@"approval_pending" transcript:receipt[@"transcript"]
      calls:@[[self persistedCallForProjection:first decision:@"allow_once"
                                     reference:firstMarker],
              [self persistedCallForProjection:second decision:@"denied"
                                     reference:nil]]
      events:@[[self approvalEventForCall:first attempt:fixture[@"attempt"]
                                  eventId:firstMarker seq:@1],
               [self approvalEventForCall:second attempt:fixture[@"attempt"]
                                  eventId:secondMarker seq:@2]]
      grants:@[]];
  sessionStore.fakeLoadResult = [self loadResultForSession:secondSession generation:@3
      digest:fixture[@"checkpoint"][@"session_sha256"]];
  NSDictionary *secondBound = [batchService bindAgentApprovalWithRequest:
      [self bindRequestForFixture:fixture receipt:receipt call:second
          operationId:secondMarker decision:@"denied"
          denyMessage:@"only one commit"] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(secondBound[@"status"], @"bound", @"%@", secondBound);
  XCTAssertEqualObjects(secondBound[@"receipt"][@"outcome"], @"denied");
  XCTAssertEqual(git.effectCount, 0U);

  // Both decisions are durable: the allowed call runs exactly once, the
  // denied call never runs, and replay is idempotent.
  NSArray *settledCalls = @[
    [self persistedCallForProjection:first decision:@"allow_once"
                           reference:firstMarker],
    [self persistedCallForProjection:second decision:@"denied" reference:nil
                             receipt:secondBound[@"receipt"] rowRevision:@2],
  ];
  sessionStore.fakeLoadResult = [self loadResultForSession:
      [self sessionForFixture:fixture phase:@"execution_intent"
          transcript:secondBound[@"transcript"] calls:settledCalls
          events:@[] grants:@[]] generation:@3
      digest:fixture[@"checkpoint"][@"session_sha256"]];
  NSMutableDictionary *firstExecute = [[self executeRequestForFixture:fixture
      receipt:receipt call:first
      operationId:@"81818181-8181-4181-8181-818181818182"
      approvalReference:firstMarker] mutableCopy];
  // The denial advanced the authority transcript; execution starts from it.
  firstExecute[@"transcript"] = secondBound[@"transcript"];
  NSDictionary *executed = [execution executeAgentToolWithRequest:firstExecute
                                                             error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(executed[@"status"], @"completed", @"%@", executed);
  XCTAssertEqual(git.effectCount, 1U);
  NSMutableDictionary *deniedExecute = [[self executeRequestForFixture:fixture
      receipt:receipt call:second
      operationId:@"82828282-8282-4282-8282-828282828283"
      approvalReference:nil] mutableCopy];
  deniedExecute[@"expected_execution_revision"] = @2;
  deniedExecute[@"transcript"] = executed[@"transcript"];
  NSDictionary *deniedRun = [execution executeAgentToolWithRequest:deniedExecute
                                                             error:&error];
  XCTAssertNotEqualObjects(deniedRun[@"status"], @"completed", @"%@", deniedRun);
  XCTAssertEqual(git.effectCount, 1U);
  NSDictionary *replayed = [execution executeAgentToolWithRequest:firstExecute
                                                             error:&error];
  XCTAssertEqualObjects(replayed, executed);
  XCTAssertEqual(git.effectCount, 1U);

  // The recovered batch projection replays both persisted decisions.
  NSDictionary *state = [self.wal snapshotWithError:&error];
  NSDictionary *deniedRow = [state[@"ledger"]
      filteredArrayUsingPredicate:[NSPredicate
          predicateWithFormat:@"locator.call_id == %@", second[@"call_id"]]]
      .firstObject;
  XCTAssertEqualObjects(deniedRow[@"state"], @"settled");
  XCTAssertEqualObjects(deniedRow[@"receipt"][@"outcome"], @"denied");
  XCTAssertEqualObjects([self.wal dispatchStateForKind:@"execution"
                                               locator:deniedRow[@"locator"]
                                                 error:&error], @"not_dispatched");
}

- (void)testRevokedGrantBlocksGrantBoundExecutionUntilRegranted {
  NSDictionary *rawCommit = @{ @"schema_version" : @1,
    @"call_id" : @"commit-call", @"name" : @"git_commit",
    @"arguments_json" : @"{\"message\":\"m\"}" };
  NSDictionary *fixture = [self serviceFixtureForRawCalls:@[rawCommit]];
  NSString *grantID = @"83838383-8383-4383-8383-838383838383";
  NSDictionary *grant = @{ @"schema_version" : @2, @"grant_id" : grantID,
    @"conversation_id" : fixture[@"conversation"],
    @"workspace_id" : fixture[@"root"][@"workspace_id"],
    @"project_id" : fixture[@"root"][@"project_id"],
    @"binding_revision" : fixture[@"root"][@"workspace_binding_revision"],
    @"root_fingerprint_sha256" : fixture[@"root"][@"root_fingerprint_sha256"],
    @"tool_family" : @"git_commit", @"registry_version" : @1,
    @"policy_version" : @"agent-v1",
    @"issued_for" : @{ @"schema_version" : @1,
                        @"task_id" : fixture[@"task"],
                        @"attempt_id" : fixture[@"attempt"] },
    @"created_at" : @"2026-08-31T00:00:00.000Z" };
  AgentEffectsSessionStore *sessionStore = fixture[@"session_store"];
  sessionStore.fakeLoadResult = [self loadResultForSession:@{
      @"schema_version" : @9,
      @"conversations" : @[@{ @"id" : fixture[@"conversation"],
        @"agent_grants" : @[grant],
        @"attempts" : @[@{ @"attempt_id" : fixture[@"attempt"],
          @"journal_revision" : @1, @"agent" : NSNull.null }] }],
      @"session_events" : @[] } generation:@3
      digest:fixture[@"checkpoint"][@"session_sha256"]];
  NSError *error = nil;
  NSDictionary *prepared = [fixture[@"batch_service"]
      prepareAgentToolBatchWithRequest:fixture[@"batch_request"] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(prepared[@"status"], @"prepared", @"%@", prepared);
  if (![prepared[@"status"] isEqualToString:@"prepared"]) return;
  NSDictionary *receipt = prepared[@"receipt"];
  NSDictionary *call = receipt[@"calls"][0];
  XCTAssertEqualObjects(call[@"approval_state"], @"bound");
  XCTAssertEqualObjects(call[@"approval_reference"], grantID);
  NSDictionary *journalCall = [self persistedCallForProjection:call
      decision:@"allow_conversation" reference:grantID];

  // The user revoked the grant as a persisted checkpoint before execution:
  // the grant-bound call fails closed with zero effect.
  sessionStore.fakeLoadResult = [self loadResultForSession:
      [self sessionForFixture:fixture phase:@"execution_intent"
          transcript:receipt[@"transcript"] calls:@[journalCall] events:@[]
          grants:@[]] generation:@3
      digest:fixture[@"checkpoint"][@"session_sha256"]];
  AgentEffectsGitExecutor *git = fixture[@"git_executor"];
  DSHAgentToolExecutionService *execution = [[DSHAgentToolExecutionService alloc]
      initWithWAL:self.wal ledger:self.ledger
      preparedStore:fixture[@"prepared_store"] transcripts:self.transcripts
      workspaceExecutor:fixture[@"workspace_executor"] gitExecutor:git];
  NSDictionary *revokedRequest = [self executeRequestForFixture:fixture
      receipt:receipt call:call
      operationId:@"84848484-8484-4484-8484-848484848484"
      approvalReference:grantID];
  NSDictionary *blocked = [execution executeAgentToolWithRequest:revokedRequest
                                                            error:&error];
  XCTAssertEqualObjects(blocked[@"status"], @"conflict", @"%@", blocked);
  XCTAssertEqualObjects(blocked[@"failure_code"], @"E_AGENT_APPROVAL");
  XCTAssertEqual(git.effectCount, 0U);
  // Replaying the blocked operation stays blocked.
  NSDictionary *blockedReplay = [execution executeAgentToolWithRequest:revokedRequest
                                                                  error:&error];
  XCTAssertEqualObjects(blockedReplay[@"status"], @"conflict");
  XCTAssertEqual(git.effectCount, 0U);

  // A grant present again in the committed session re-opens execution for a
  // fresh operation, exactly once.
  sessionStore.fakeLoadResult = [self loadResultForSession:
      [self sessionForFixture:fixture phase:@"execution_intent"
          transcript:receipt[@"transcript"] calls:@[journalCall] events:@[]
          grants:@[grant]] generation:@3
      digest:fixture[@"checkpoint"][@"session_sha256"]];
  NSDictionary *regrantedRequest = [self executeRequestForFixture:fixture
      receipt:receipt call:call
      operationId:@"85858585-8585-4585-8585-858585858585"
      approvalReference:grantID];
  NSDictionary *executed = [execution executeAgentToolWithRequest:regrantedRequest
                                                             error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(executed[@"status"], @"completed", @"%@", executed);
  XCTAssertEqual(git.effectCount, 1U);
  NSDictionary *replayed = [execution executeAgentToolWithRequest:regrantedRequest
                                                             error:&error];
  XCTAssertEqualObjects(replayed, executed);
  XCTAssertEqual(git.effectCount, 1U);
}

- (void)testNonDirectoryParentRejectsWholeWriteBatchWithoutPartialEffects {
  NSDictionary *rawIndex = @{
    @"schema_version" : @1,
    @"call_id" : @"write-index",
    @"name" : @"write_file",
    @"arguments_json" :
        @"{\"path\":\"public/index.html\",\"content\":\"<h1>Rish</h1>\",\"expected_revision\":null}",
  };
  NSDictionary *rawHello = @{
    @"schema_version" : @1,
    @"call_id" : @"write-hello",
    @"name" : @"write_file",
    @"arguments_json" :
        @"{\"path\":\"hello.txt\",\"content\":\"hello\",\"expected_revision\":null}",
  };
  NSDictionary *fixture = [self realWorkspaceServiceFixtureForRawCalls:
      @[rawIndex, rawHello]];
  if (fixture == nil) return;

  DSHAgentWorkspaceToolExecutor *executor = fixture[@"workspace_executor"];
  NSDictionary *root = fixture[@"root"];
  NSError *error = nil;
  for (NSDictionary *arguments in @[
      @{@"path" : @"server.js", @"content" : @"module.exports = {};\n",
        @"expected_revision" : NSNull.null},
      @{@"path" : @"data.json", @"content" : @"{\"ok\":true}\n",
        @"expected_revision" : NSNull.null},
      @{@"path" : @"public", @"content" : @"keep this existing file\n",
        @"expected_revision" : NSNull.null},
  ]) {
    NSDictionary *prepared = [executor prepareToolNamed:@"write_file"
                                             arguments:arguments
                                                  root:root
                                                 error:&error];
    XCTAssertNotNil(prepared, @"seed preflight failed: %@", error);
    XCTAssertNil(error);
    NSDictionary *effect = [executor executeToolNamed:@"write_file"
                                             arguments:arguments
                                                  root:root
                                           precondition:prepared[@"precondition"]
                                                 error:&error];
    XCTAssertEqualObjects(effect[@"status"], @"ok", @"seed write failed: %@", error);
    XCTAssertNil(error);
  }

  NSDictionary *result = [fixture[@"batch_service"]
      prepareAgentToolBatchWithRequest:fixture[@"batch_request"] error:&error];
  XCTAssertNil(error);
  // Missing directories can now be created after approval. An existing file
  // cannot become a directory: refuse the entire batch without touching its
  // valid sibling or replacing the existing parent.
  XCTAssertEqualObjects(result[@"status"], @"prepared", @"%@", result);
  XCTAssertEqualObjects(result[@"receipt"][@"calls"][0][@"receipt"][@"failure_code"], @"E_AGENT_BAD_PATH");
  XCTAssertEqualObjects(result[@"receipt"][@"calls"][1][@"receipt"][@"outcome"], @"failed");
  XCTAssertEqualObjects(result[@"receipt"][@"effect_gate"], @"not_applicable");
  XCTAssertEqual([[self.wal snapshotWithError:&error][@"ledger"] count], 0U);

  NSURL *workspace = [self.rootURL
      URLByAppendingPathComponent:@"ServiceDocuments/Rish Workspaces/Service"
                        isDirectory:YES];
  XCTAssertEqualObjects([NSData dataWithContentsOfURL:
      [workspace URLByAppendingPathComponent:@"server.js"]],
      [@"module.exports = {};\n" dataUsingEncoding:NSUTF8StringEncoding]);
  XCTAssertEqualObjects([NSData dataWithContentsOfURL:
      [workspace URLByAppendingPathComponent:@"data.json"]],
      [@"{\"ok\":true}\n" dataUsingEncoding:NSUTF8StringEncoding]);
  XCTAssertNil([NSData dataWithContentsOfURL:
      [workspace URLByAppendingPathComponent:@"hello.txt"]]);
  XCTAssertEqualObjects([NSData dataWithContentsOfURL:
      [workspace URLByAppendingPathComponent:@"public"]],
      [@"keep this existing file\n" dataUsingEncoding:NSUTF8StringEncoding]);
}

- (void)testOpenParentPermissionAndSymlinkFailuresStayBadPath {
  NSDictionary *rawRead = @{
    @"schema_version" : @1,
    @"call_id" : @"read-parent-failure",
    @"name" : @"read_file",
    @"arguments_json" : @"{\"path\":\"blocked/file.txt\"}",
  };
  NSDictionary *fixture = [self realWorkspaceServiceFixtureForRawCalls:@[rawRead]];
  if (fixture == nil) return;
  DSHAgentWorkspaceToolExecutor *executor = fixture[@"workspace_executor"];
  NSDictionary *root = fixture[@"root"];
  NSURL *workspace = [self.rootURL
      URLByAppendingPathComponent:@"ServiceDocuments/Rish Workspaces/Service"
                        isDirectory:YES];
  NSURL *blocked = [workspace URLByAppendingPathComponent:@"blocked" isDirectory:YES];
  NSURL *safe = [workspace URLByAppendingPathComponent:@"safe" isDirectory:YES];
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:blocked
                                    withIntermediateDirectories:YES
                                                     attributes:nil error:nil]);
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:safe
                                    withIntermediateDirectories:YES
                                                     attributes:nil error:nil]);
  NSURL *link = [workspace URLByAppendingPathComponent:@"linked" isDirectory:YES];
  XCTAssertTrue([[NSFileManager defaultManager] createSymbolicLinkAtURL:link
                                                   withDestinationURL:safe
                                                                  error:nil]);
  XCTAssertTrue([NSFileManager.defaultManager setAttributes:
      @{NSFilePosixPermissions : @0000} ofItemAtPath:blocked.path error:nil]);

  NSError *error = nil;
  NSDictionary *permissionFailure = [executor prepareToolNamed:@"read_file"
      arguments:@{@"path" : @"blocked/file.txt"} root:root error:&error];
  XCTAssertNil(permissionFailure);
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorInvalidArgument);
  error = nil;
  NSDictionary *symlinkFailure = [executor prepareToolNamed:@"read_file"
      arguments:@{@"path" : @"linked/file.txt"} root:root error:&error];
  XCTAssertNil(symlinkFailure);
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorInvalidArgument);
  [NSFileManager.defaultManager setAttributes:
      @{NSFilePosixPermissions : @0700} ofItemAtPath:blocked.path error:nil];
}

/// One control request to scripts/git-test-proxy.py over a raw socket.
static NSDictionary *AgentEffectsProxyControl(NSString *base, NSString *method, NSString *path) {
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
    (void)write(fd, request.UTF8String, strlen(request.UTF8String));
    char buffer[4096];
    ssize_t count = 0;
    while ((count = read(fd, buffer, sizeof(buffer))) > 0) [reply appendBytes:buffer length:(NSUInteger)count];
  }
  close(fd);
  NSString *text = [[NSString alloc] initWithData:reply encoding:NSUTF8StringEncoding];
  NSRange split = [text rangeOfString:@"\r\n\r\n"];
  if (split.location == NSNotFound) return nil;
  id value = [NSJSONSerialization JSONObjectWithData:[[text substringFromIndex:NSMaxRange(split)]
      dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
  return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

// The agent's remote traffic goes through the person's proxy, as the
// panel's does (TEST_RUNNER_RISH_PROXY_BASE=http://127.0.0.1:N/; start the
// proxy with --upstream where github.com needs one). A proxy that refuses
// the tunnel is not gone around, and a plain-http origin with a proxy is
// refused before any connection.
- (void)testTheAgentsRemoteTrafficGoesThroughTheProxy {
  NSString *proxy = NSProcessInfo.processInfo.environment[@"RISH_PROXY_BASE"];
  if (proxy.length == 0) XCTSkip(@"no test proxy: set TEST_RUNNER_RISH_PROXY_BASE");
  if (AgentEffectsProxyControl(proxy, @"POST", @"/__rish_mode?mode=tunnel") == nil) {
    XCTSkip(@"the test proxy does not answer");
  }
  NSDictionary *fixture = [self realGitExecutorFixtureNamed:@"agent-proxy"
      projectID:@"77777777-7777-4777-8777-777777777771"];
  XCTAssertNotNil(fixture);
  if (fixture == nil) return;
  git_repository *repository = nullptr;
  XCTAssertEqual(git_repository_open(&repository,
      [fixture[@"repository_url"] fileSystemRepresentation]), 0);
  XCTAssertEqual(git_remote_set_url(repository, "origin",
      "https://github.com/octocat/Hello-World.git"), 0);
  DSHAgentGitToolExecutor *executor = fixture[@"executor"];
  executor.proxyProvider = ^NSString * { return proxy; };
  NSInteger (^tunnels)(void) = ^NSInteger {
    return [AgentEffectsProxyControl(proxy, @"GET", @"/__rish_stats")[@"connects"][@"github.com:443"] integerValue];
  };
  // Preparing asks the remote what it holds -- through the proxy.
  NSInteger before = tunnels();
  NSError *error = nil;
  NSDictionary *prepared = [executor prepareToolNamed:@"git_push" arguments:@{}
      root:fixture[@"root"] error:&error];
  XCTAssertNotNil(prepared, @"%@", error);
  XCTAssertGreaterThan(tunnels(), before, @"the probe did not go through the proxy");
  NSDictionary *precondition = prepared[@"precondition"];
  // Recovery asks the same way.
  NSInteger beforeRecovery = tunnels();
  NSDictionary *recovered = [executor recoverToolNamed:@"git_push" arguments:@{}
      root:fixture[@"root"] precondition:precondition error:&error];
  XCTAssertEqualObjects(recovered[@"status"], @"not_dispatched", @"%@", error);
  XCTAssertGreaterThan(tunnels(), beforeRecovery, @"recovery did not go through the proxy");
  // A proxy that refuses the tunnel is not gone around.
  AgentEffectsProxyControl(proxy, @"POST", @"/__rish_mode?mode=refuse");
  NSInteger refusedBefore = [AgentEffectsProxyControl(proxy, @"GET", @"/__rish_stats")[@"refused"] integerValue];
  error = nil;
  XCTAssertNil([executor prepareToolNamed:@"git_push" arguments:@{} root:fixture[@"root"] error:&error]);
  XCTAssertGreaterThan([AgentEffectsProxyControl(proxy, @"GET", @"/__rish_stats")[@"refused"] integerValue], refusedBefore);
  AgentEffectsProxyControl(proxy, @"POST", @"/__rish_mode?mode=tunnel");
  // A plain-http origin with a proxy: refused before any connection.
  XCTAssertEqual(git_remote_set_url(repository, "origin", "http://127.0.0.1:1/demo.git"), 0);
  git_repository_free(repository);
  error = nil;
  XCTAssertNil([executor prepareToolNamed:@"git_push" arguments:@{} root:fixture[@"root"] error:&error]);
  NSDictionary *pushed = [executor executeToolNamed:@"git_push" arguments:@{}
      root:fixture[@"root"] precondition:precondition error:&error];
  XCTAssertEqualObjects([self feedbackObject:pushed][@"payload"][@"reason"], @"origin_unsafe");
}

// The agent's proxy is the one the committed session holds, in the one
// spelling libgit2 is handed; nothing committed, or no proxy, is none.
- (void)testTheCommittedSessionsProxyIsTheAgentsProxy {
  NSDictionary *(^loaded)(id) = ^NSDictionary *(id proxy) {
    NSMutableDictionary *preferences = [@{ @"schema_version" : @1 } mutableCopy];
    if (proxy != nil) preferences[@"git_https_proxy_url"] = proxy;
    NSData *json = [NSJSONSerialization dataWithJSONObject:@{ @"preferences" : preferences } options:0 error:nil];
    return @{ @"status" : @"present",
              @"session_json" : [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] };
  };
  XCTAssertEqualObjects(DSHCommittedGitProxyURL(loaded(@"http://127.0.0.1:7897")), @"http://127.0.0.1:7897/");
  XCTAssertEqualObjects(DSHCommittedGitProxyURL(loaded(@"HTTPS://Proxy.Example:443/")), @"https://proxy.example:443/");
  XCTAssertNil(DSHCommittedGitProxyURL(loaded(nil)));
  XCTAssertNil(DSHCommittedGitProxyURL(loaded(NSNull.null)));
  XCTAssertNil(DSHCommittedGitProxyURL(loaded(@"proxy:3128")));
  XCTAssertNil(DSHCommittedGitProxyURL(@{ @"status" : @"missing", @"session_json" : NSNull.null }));
  XCTAssertNil(DSHCommittedGitProxyURL(nil));
}

@end
