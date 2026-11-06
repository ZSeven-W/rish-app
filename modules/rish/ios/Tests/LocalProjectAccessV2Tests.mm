#import <XCTest/XCTest.h>

#import "../../../../modules/rish/ios/Sources/LocalProjectAccess.h"
#import "../../../../modules/rish/ios/Sources/LocalProjectAccessInternals.h"
#import "../../../../modules/rish/ios/Sources/LocalWorkspaceAccess.h"

#include <git2.h>
#include <limits.h>
#include <sys/stat.h>
#include <unistd.h>

@interface LocalProjectAccessV2Tests : XCTestCase
@end

@implementation LocalProjectAccessV2Tests

- (NSDictionary *)rootWithProject:(id)project {
  return @{
    @"schema_version" : @1,
    @"workspace_id" : @"11111111-1111-4111-8111-111111111111",
    @"binding_revision" : @7,
    @"project_id" : project,
  };
}

- (NSURL *)makeLegacyFixtureWithProjectId:(NSString *)projectId
                                     hook:(DSHLocalProjectAccessHook)hook
                                   access:(DSHLocalProjectAccess **)accessOut
                               projectURL:(NSURL **)projectURLOut
                            repositoryURL:(NSURL **)repositoryURLOut {
  NSURL *baseURL = [NSURL fileURLWithPath:[NSTemporaryDirectory()
      stringByAppendingPathComponent:NSUUID.UUID.UUIDString.lowercaseString]
                                  isDirectory:YES];
  NSURL *projectsURL = [baseURL URLByAppendingPathComponent:@"projects"
                                                isDirectory:YES];
  NSURL *projectURL = [projectsURL URLByAppendingPathComponent:projectId
                                                   isDirectory:YES];
  NSURL *repositoryURL = [projectURL URLByAppendingPathComponent:@"repo"
                                                      isDirectory:YES];
  XCTAssertTrue([[NSFileManager defaultManager]
      createDirectoryAtURL:repositoryURL
      withIntermediateDirectories:YES
      attributes:@{NSFilePosixPermissions : @0700}
      error:nil]);
  NSDictionary *metadata = @{
    @"schema_version" : @1,
    @"name" : @"Legacy Evidence",
    @"created_at" : @"2026-08-31T12:00:00.000Z",
    @"updated_at" : @"2026-08-31T12:00:00.000Z",
    @"origin_url" : NSNull.null,
  };
  NSData *metadataData = [NSJSONSerialization dataWithJSONObject:metadata
                                                          options:0
                                                            error:nil];
  XCTAssertTrue([metadataData writeToURL:
      [projectURL URLByAppendingPathComponent:@"project.json"] atomically:YES]);
  XCTAssertGreaterThan(git_libgit2_init(), 0);
  git_repository *repository = nullptr;
  XCTAssertEqual(git_repository_init(&repository,
                                      repositoryURL.fileSystemRepresentation,
                                      0), 0);
  if (repository != nullptr) git_repository_free(repository);
  if (accessOut != nullptr) {
    *accessOut = [[DSHLocalProjectAccess alloc]
        initWithProjectsRootURL:projectsURL hook:hook];
  }
  if (projectURLOut != nullptr) *projectURLOut = projectURL;
  if (repositoryURLOut != nullptr) *repositoryURLOut = repositoryURL;
  return baseURL;
}

- (NSURL *)makePrivateSplitFixtureWithProjectId:(NSString *)projectId
                                      bindingProjectId:(NSString *)bindingProjectId
                                       workspaceAccess:(DSHLocalWorkspaceAccess **)accessOut
                                        projectAccess:(DSHLocalProjectAccess **)projectAccessOut
                                                  root:(NSDictionary **)rootOut
                                             rootURL:(NSURL **)rootURLOut
                                              gitURL:(NSURL **)gitURLOut {
  NSString *fixtureName = NSUUID.UUID.UUIDString.lowercaseString;
  NSURL *baseURL = [NSURL fileURLWithPath:
      [NSTemporaryDirectory() stringByAppendingPathComponent:fixtureName]
                                      isDirectory:YES];
  NSURL *privateRoot = [baseURL URLByAppendingPathComponent:@"private"
                                                 isDirectory:YES];
  NSURL *documentsRoot = [baseURL URLByAppendingPathComponent:@"documents"
                                                    isDirectory:YES];
  XCTAssertTrue([[NSFileManager defaultManager]
      createDirectoryAtURL:privateRoot
      withIntermediateDirectories:YES
      attributes:@{NSFilePosixPermissions : @0700}
      error:nil]);
  XCTAssertTrue([[NSFileManager defaultManager]
      createDirectoryAtURL:documentsRoot
      withIntermediateDirectories:YES
      attributes:@{NSFilePosixPermissions : @0700}
      error:nil]);

  NSString *workspaceId = NSUUID.UUID.UUIDString.lowercaseString;
  DSHLocalWorkspaceAccess *workspaceAccess = [[DSHLocalWorkspaceAccess alloc]
      initWithPrivateRootURL:privateRoot
            documentsRootURL:documentsRoot
                         clock:^NSDate * {
                           return [NSDate dateWithTimeIntervalSince1970:
                               1'777'777'777.125];
                         }
                UUIDGenerator:^NSString * {
                  return workspaceId;
                }
               legacyResolver:^BOOL(__unused NSString *legacyProjectId,
                                    NSDictionary **evidence,
                                    NSError **error) {
                 if (evidence != nil) *evidence = nil;
                 if (error != nil) {
                   *error = [NSError errorWithDomain:
                       DSHLocalWorkspaceAccessErrorDomain
                                                  code:DSHLocalWorkspaceAccessErrorUnavailable
                                              userInfo:@{}];
                 }
                 return NO;
               }
                     faultHook:nil];
  NSError *error = nil;
  XCTAssertTrue([workspaceAccess ensurePrivateLayoutWithError:&error], @"%@",
                error);
  NSDictionary *workspace = [workspaceAccess
      createRishOwnedWorkspaceWithDisplayName:@"V2 Native Fixture"
                                  operationId:NSUUID.UUID.UUIDString.lowercaseString
                                        error:&error];
  XCTAssertNotNil(workspace, @"%@", error);
  XCTAssertEqualObjects(workspace[@"workspace_id"], workspaceId);

  NSURL *rootURL = [[documentsRoot
      URLByAppendingPathComponent:@"Rish Workspaces" isDirectory:YES]
      URLByAppendingPathComponent:@"V2 Native Fixture" isDirectory:YES];
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:rootURL.path]);

  NSURL *gitURL = [[[privateRoot
      URLByAppendingPathComponent:@"workspace-gitdirs" isDirectory:YES]
      URLByAppendingPathComponent:workspaceId isDirectory:YES]
      URLByAppendingPathComponent:projectId isDirectory:YES];
  git_repository *repository = nullptr;
  git_repository_init_options options = GIT_REPOSITORY_INIT_OPTIONS_INIT;
  options.flags = GIT_REPOSITORY_INIT_BARE | GIT_REPOSITORY_INIT_MKPATH;
  options.mode = 0700;
  options.initial_head = "main";
  XCTAssertEqual(git_libgit2_init() > 0, YES);
  XCTAssertEqual(git_repository_init_ext(&repository,
                                         gitURL.fileSystemRepresentation,
                                         &options), 0);
  XCTAssertNotEqual(repository, nullptr);
  if (repository == nullptr) return nil;

  NSData *readmeData = [@"private split fixture\n"
      dataUsingEncoding:NSUTF8StringEncoding];
  XCTAssertTrue([readmeData writeToURL:
      [rootURL URLByAppendingPathComponent:@"README.md"] atomically:YES]);
  XCTAssertEqual(git_repository_set_workdir(repository,
                                             rootURL.fileSystemRepresentation,
                                             0), 0);
  git_index *index = nullptr;
  XCTAssertEqual(git_repository_index(&index, repository), 0);
  XCTAssertNotEqual(index, nullptr);
  if (index != nullptr) {
    XCTAssertEqual(git_index_add_bypath(index, "README.md"), 0);
    XCTAssertEqual(git_index_write(index), 0);
    git_oid treeOid = {};
    git_oid commitOid = {};
    git_tree *tree = nullptr;
    git_signature *signature = nullptr;
    XCTAssertEqual(git_index_write_tree(&treeOid, index), 0);
    XCTAssertEqual(git_tree_lookup(&tree, repository, &treeOid), 0);
    XCTAssertEqual(git_signature_new(&signature, "Rish V2 Test",
                                     "v2@example.invalid",
                                     1'777'777'777, 0), 0);
    XCTAssertEqual(git_commit_create(&commitOid, repository, "HEAD",
                                     signature, signature, "UTF-8", "fixture",
                                     tree, 0, nullptr), 0);
    if (signature != nullptr) git_signature_free(signature);
    if (tree != nullptr) git_tree_free(tree);
    git_index_free(index);
  }
  git_repository_free(repository);

  DSHLocalProjectWorkspaceBindingResolver resolver =
      ^NSDictionary *(NSDictionary *rootRef, NSString *rootFingerprint,
                      NSError **resolverError) {
        (void)resolverError;
        return @{
          @"schema_version" : @2,
          @"workspace_id" : rootRef[@"workspace_id"],
          @"binding_revision" : rootRef[@"binding_revision"],
          @"project_id" : bindingProjectId,
          @"display_name" : @"V2 Native Fixture",
          @"git_topology" : @"private_split_gitdir",
          @"git_directory_url" : gitURL,
          @"root_fingerprint_sha256" : rootFingerprint,
        };
      };
  DSHLocalProjectAccess *projectAccess = [[DSHLocalProjectAccess alloc]
      initWithWorkspaceAccess:workspaceAccess
              bindingResolver:resolver
                          hook:nil];
  NSDictionary *root = @{
    @"schema_version" : @1,
    @"workspace_id" : workspaceId,
    @"binding_revision" : @1,
    @"project_id" : projectId,
  };
  if (accessOut != nullptr) *accessOut = workspaceAccess;
  if (projectAccessOut != nullptr) *projectAccessOut = projectAccess;
  if (rootOut != nullptr) *rootOut = root;
  if (rootURLOut != nullptr) *rootURLOut = rootURL;
  if (gitURLOut != nullptr) *gitURLOut = gitURL;
  return baseURL;
}

- (void)removeAndReplaceDirectoryAtURL:(NSURL *)url {
  NSURL *oldURL = [url.URLByDeletingLastPathComponent
      URLByAppendingPathComponent:
          [url.lastPathComponent stringByAppendingString:@".old"]
                    isDirectory:YES];
  unlink(oldURL.fileSystemRepresentation);
  XCTAssertEqual(rename(url.fileSystemRepresentation, oldURL.fileSystemRepresentation),
                 0);
  XCTAssertEqual(mkdir(url.fileSystemRepresentation, 0700), 0);
}

- (void)testWorkspaceRootReferenceHasAnExactOpaqueShape {
  NSError *error = nil;
  XCTAssertTrue(DSHLocalProjectAccessValidateWorkspaceRootRefV1(
      [self rootWithProject:@"22222222-2222-4222-8222-222222222222"], YES,
      &error));
  XCTAssertNil(error);

  NSMutableDictionary *zeroRevision = [[self rootWithProject:
      @"22222222-2222-4222-8222-222222222222"] mutableCopy];
  zeroRevision[@"binding_revision"] = @0;
  for (NSDictionary *invalid in @[
    zeroRevision,
    @{ @"schema_version" : @1,
       @"workspace_id" : @"11111111-1111-4111-8111-111111111111",
       @"binding_revision" : @7,
       @"project_id" : @"22222222-2222-4222-8222-222222222222",
       @"root_path" : @"/private/should-not-cross-the-bridge" },
    [self rootWithProject:@"not-a-uuid"],
    [self rootWithProject:NSNull.null],
  ]) {
    error = nil;
    XCTAssertFalse(DSHLocalProjectAccessValidateWorkspaceRootRefV1(
        invalid, YES, &error));
    XCTAssertEqual(error.code, DSHLocalProjectAccessErrorInvalidIdentifier);
  }
}

- (void)testUnboundRootCannotBecomeAProjectLease {
  NSError *error = nil;
  XCTAssertFalse(DSHLocalProjectAccessValidateWorkspaceRootRefV1(
      [self rootWithProject:NSNull.null], YES, &error));
  XCTAssertEqual(error.code, DSHLocalProjectAccessErrorInvalidIdentifier);
}

- (void)testAuthorityIdentityFieldsRequireCanonicalDecimalValues {
  unsigned long long value = 0;
  XCTAssertTrue(DSHLocalProjectAccessParseCanonicalUInt64(
      @"18446744073709551615", &value));
  XCTAssertEqual(value, ULLONG_MAX);
  XCTAssertTrue(DSHLocalProjectAccessParseCanonicalUInt64(@"0", &value));
  XCTAssertEqual(value, (unsigned long long)0);
  XCTAssertTrue(DSHLocalProjectAccessParseCanonicalUInt64(@1, &value));
  XCTAssertEqual(value, (unsigned long long)1);
  XCTAssertFalse(DSHLocalProjectAccessParseCanonicalUInt64(nil, &value));
  for (id invalid in @[
    @"", @"01", @"+1", @"-1", @"1.0",
    @"18446744073709551616", @"184467440737095516150", @YES, @1.5
  ]) {
    value = 0;
    XCTAssertFalse(DSHLocalProjectAccessParseCanonicalUInt64(invalid, &value),
                   @"%@ must be rejected", invalid);
  }
}

- (void)testV2LeaseRequiresAnExplicitWorkspaceAccessResolver {
  DSHLocalProjectAccess *access =
      [[DSHLocalProjectAccess alloc] initWithProjectsRootURL:nil];
  NSError *error = nil;
  XCTAssertNil([access leaseWorkspaceRootRef:
                        [self rootWithProject:
                                  @"22222222-2222-4222-8222-222222222222"]
                                     mode:DSHLocalProjectAccessModeRead
                          includeMetadata:NO
                                  timeout:0
                                    error:&error]);
  XCTAssertEqual(error.code, DSHLocalProjectAccessErrorInvalidIdentifier);
}

- (void)testRealWorkspaceLeasePinsPrivateSplitGitAndObjects {
  DSHLocalWorkspaceAccess *workspaceAccess = nil;
  DSHLocalProjectAccess *projectAccess = nil;
  NSDictionary *root = nil;
  NSURL *rootURL = nil;
  NSURL *gitURL = nil;
  NSURL *baseURL = [self makePrivateSplitFixtureWithProjectId:
      @"22222222-2222-4222-8222-222222222222"
      bindingProjectId:@"22222222-2222-4222-8222-222222222222"
      workspaceAccess:&workspaceAccess
      projectAccess:&projectAccess
      root:&root
      rootURL:&rootURL
      gitURL:&gitURL];
  if (baseURL == nil) return;
  NSError *error = nil;
  DSHLocalProjectLease *lease = [projectAccess
      leaseWorkspaceRootRef:root
                       mode:DSHLocalProjectAccessModeRead
            includeMetadata:YES
                    timeout:1
                      error:&error];
  XCTAssertNotNil(lease, @"%@", error);
  XCTAssertEqualObjects(lease.workspaceId, root[@"workspace_id"]);
  XCTAssertEqual(lease.workspaceBindingRevision, (NSUInteger)1);
  XCTAssertEqualObjects(lease.projectId, root[@"project_id"]);
  XCTAssertEqualObjects(lease.gitTopology, @"private_split_gitdir");
  XCTAssertEqual(lease.workspaceRootDescriptor >= 0, YES);
  XCTAssertEqual(lease.gitDescriptor >= 0, YES);
  XCTAssertEqual(lease.objectsDescriptor >= 0, YES);
  XCTAssertEqual(git_repository_is_bare(lease.repository), 0);
  XCTAssertEqualObjects(
      [[NSString stringWithUTF8String:git_repository_workdir(lease.repository)]
          stringByStandardizingPath],
      rootURL.path.stringByStandardizingPath);
  XCTAssertEqualObjects(
      [[NSString stringWithUTF8String:git_repository_path(lease.repository)]
          stringByStandardizingPath],
      gitURL.path.stringByStandardizingPath);
  struct stat visibleGit = {};
  XCTAssertNotEqual(lstat([[rootURL URLByAppendingPathComponent:@".git"]
      fileSystemRepresentation], &visibleGit), 0);
  XCTAssertEqual(errno, ENOENT);
  XCTAssertTrue([projectAccess validateWorkspaceLeaseIdentity:lease
                                                     rootRef:root
                                                       error:&error], @"%@",
                error);
  NSString *rootFingerprint = [lease.rootFingerprintSHA256 copy];
  // Exercise the production native binding-file resolver as well as the
  // injected test resolver. Release the first lease before reacquiring the
  // authority's exclusive lock to publish the binding record.
  lease = nil;
  NSURL *bindingURL = [gitURL URLByAppendingPathComponent:@"binding-v2.json"
                                               isDirectory:NO];
  NSDictionary *bindingRecord = @{
    @"schema_version" : @2,
    @"workspace_id" : root[@"workspace_id"],
    @"binding_revision" : root[@"binding_revision"],
    @"project_id" : root[@"project_id"],
    @"display_name" : @"V2 Native Fixture",
    @"git_topology" : @"private_split_gitdir",
    @"git_directory_relative" : [NSString stringWithFormat:
        @"workspace-gitdirs/%@/%@", root[@"workspace_id"], root[@"project_id"]],
    @"root_fingerprint_sha256" : rootFingerprint,
  };
  NSData *bindingData = [NSJSONSerialization dataWithJSONObject:bindingRecord
                                                            options:0
                                                              error:&error];
  XCTAssertTrue([bindingData writeToURL:bindingURL atomically:YES], @"%@", error);
  XCTAssertTrue([[NSFileManager defaultManager]
      setAttributes:@{NSFilePosixPermissions : @0600}
             ofItemAtPath:bindingURL.path
                    error:&error], @"%@", error);
  DSHLocalProjectAccess *defaultProjectAccess = [[DSHLocalProjectAccess alloc]
      initWithWorkspaceAccess:workspaceAccess hook:nil];
  DSHLocalProjectLease *defaultLease = [defaultProjectAccess
      leaseWorkspaceRootRef:root
                       mode:DSHLocalProjectAccessModeRead
            includeMetadata:NO
                    timeout:1
                      error:&error];
  XCTAssertNotNil(defaultLease, @"%@", error);
  XCTAssertEqualObjects(defaultLease.gitTopology, @"private_split_gitdir");
  XCTAssertTrue([defaultProjectAccess validateWorkspaceLeaseIdentity:defaultLease
                                                             rootRef:root
                                                               error:&error],
                @"%@", error);
  [[NSFileManager defaultManager] removeItemAtURL:baseURL error:nil];
  (void)workspaceAccess;
}

- (void)testProjectBindingMismatchFailsBeforePrivateGitOpen {
  DSHLocalWorkspaceAccess *workspaceAccess = nil;
  DSHLocalProjectAccess *projectAccess = nil;
  NSDictionary *root = nil;
  NSURL *rootURL = nil;
  NSURL *gitURL = nil;
  NSURL *baseURL = [self makePrivateSplitFixtureWithProjectId:
      @"33333333-3333-4333-8333-333333333333"
      bindingProjectId:@"44444444-4444-4444-8444-444444444444"
      workspaceAccess:&workspaceAccess
      projectAccess:&projectAccess
      root:&root
      rootURL:&rootURL
      gitURL:&gitURL];
  if (baseURL == nil) return;
  __block BOOL openedGit = NO;
  projectAccess = [[DSHLocalProjectAccess alloc]
      initWithWorkspaceAccess:workspaceAccess
              bindingResolver:^NSDictionary *(NSDictionary *rootRef,
                                              NSString *rootFingerprint,
                                              NSError **error) {
                (void)error;
                return @{
                  @"schema_version" : @2,
                  @"workspace_id" : rootRef[@"workspace_id"],
                  @"binding_revision" : rootRef[@"binding_revision"],
                  @"project_id" : @"44444444-4444-4444-8444-444444444444",
                  @"display_name" : @"Mismatch",
                  @"git_topology" : @"private_split_gitdir",
                  @"git_directory_url" : gitURL,
                  @"root_fingerprint_sha256" : rootFingerprint,
                };
              }
                          hook:^(NSString *stage) {
                            if ([stage isEqual:@"after_workspace_git_open"]) {
                              openedGit = YES;
                            }
                          }];
  NSError *error = nil;
  XCTAssertNil([projectAccess leaseWorkspaceRootRef:root
                                                mode:DSHLocalProjectAccessModeRead
                                     includeMetadata:YES
                                             timeout:1
                                               error:&error]);
  XCTAssertFalse(openedGit);
  XCTAssertEqual(error.code, DSHLocalProjectAccessErrorMetadataInvalid);
  [[NSFileManager defaultManager] removeItemAtURL:baseURL error:nil];
  (void)rootURL;
}

- (void)testPrivateSplitLeaseRejectsVisibleGitAndRepoFallback {
  DSHLocalWorkspaceAccess *workspaceAccess = nil;
  DSHLocalProjectAccess *projectAccess = nil;
  NSDictionary *root = nil;
  NSURL *rootURL = nil;
  NSURL *gitURL = nil;
  NSURL *baseURL = [self makePrivateSplitFixtureWithProjectId:
      @"55555555-5555-4555-8555-555555555555"
      bindingProjectId:@"55555555-5555-4555-8555-555555555555"
      workspaceAccess:&workspaceAccess
      projectAccess:&projectAccess
      root:&root
      rootURL:&rootURL
      gitURL:&gitURL];
  if (baseURL == nil) return;
  NSURL *visibleGitURL = [rootURL URLByAppendingPathComponent:@".git"
                                                   isDirectory:YES];
  XCTAssertTrue([[NSFileManager defaultManager]
      createDirectoryAtURL:visibleGitURL
      withIntermediateDirectories:NO
      attributes:@{NSFilePosixPermissions : @0700}
      error:nil]);
  XCTAssertTrue([[NSFileManager defaultManager]
      createDirectoryAtURL:[rootURL URLByAppendingPathComponent:@"repo"
                                                    isDirectory:YES]
      withIntermediateDirectories:NO
      attributes:@{NSFilePosixPermissions : @0700}
      error:nil]);
  NSError *error = nil;
  XCTAssertNil([projectAccess leaseWorkspaceRootRef:root
                                                mode:DSHLocalProjectAccessModeRead
                                     includeMetadata:YES
                                             timeout:1
                                               error:&error]);
  XCTAssertEqual(error.code, DSHLocalProjectAccessErrorUnsafeStorage);
  [[NSFileManager defaultManager] removeItemAtURL:baseURL error:nil];
  (void)workspaceAccess;
  (void)gitURL;
}

- (void)testRootReplacementInvalidatesPinnedLease {
  DSHLocalWorkspaceAccess *workspaceAccess = nil;
  DSHLocalProjectAccess *projectAccess = nil;
  NSDictionary *root = nil;
  NSURL *rootURL = nil;
  NSURL *gitURL = nil;
  NSURL *baseURL = [self makePrivateSplitFixtureWithProjectId:
      @"66666666-6666-4666-8666-666666666666"
      bindingProjectId:@"66666666-6666-4666-8666-666666666666"
      workspaceAccess:&workspaceAccess
      projectAccess:&projectAccess
      root:&root
      rootURL:&rootURL
      gitURL:&gitURL];
  if (baseURL == nil) return;
  NSError *error = nil;
  DSHLocalProjectLease *lease = [projectAccess
      leaseWorkspaceRootRef:root
                       mode:DSHLocalProjectAccessModeRead
            includeMetadata:NO
                    timeout:1
                      error:&error];
  XCTAssertNotNil(lease, @"%@", error);
  [self removeAndReplaceDirectoryAtURL:rootURL];
  XCTAssertFalse([projectAccess validateWorkspaceLeaseIdentity:lease
                                                         rootRef:root
                                                           error:&error]);
  [[NSFileManager defaultManager] removeItemAtURL:baseURL error:nil];
  (void)workspaceAccess;
  (void)gitURL;
}

- (void)testObjectsReplacementInvalidatesPinnedLease {
  DSHLocalWorkspaceAccess *workspaceAccess = nil;
  DSHLocalProjectAccess *projectAccess = nil;
  NSDictionary *root = nil;
  NSURL *rootURL = nil;
  NSURL *gitURL = nil;
  NSURL *baseURL = [self makePrivateSplitFixtureWithProjectId:
      @"77777777-7777-4777-8777-777777777777"
      bindingProjectId:@"77777777-7777-4777-8777-777777777777"
      workspaceAccess:&workspaceAccess
      projectAccess:&projectAccess
      root:&root
      rootURL:&rootURL
      gitURL:&gitURL];
  if (baseURL == nil) return;
  NSError *error = nil;
  DSHLocalProjectLease *lease = [projectAccess
      leaseWorkspaceRootRef:root
                       mode:DSHLocalProjectAccessModeRead
            includeMetadata:NO
                    timeout:1
                      error:&error];
  XCTAssertNotNil(lease, @"%@", error);
  [self removeAndReplaceDirectoryAtURL:
      [gitURL URLByAppendingPathComponent:@"objects" isDirectory:YES]];
  XCTAssertFalse([projectAccess validateWorkspaceLeaseIdentity:lease
                                                         rootRef:root
                                                           error:&error]);
  [[NSFileManager defaultManager] removeItemAtURL:baseURL error:nil];
  (void)workspaceAccess;
  (void)rootURL;
}

- (void)testLegacyBootstrapEvidenceIsExactAndContainsNoLocator {
  NSString *projectId = @"88888888-8888-4888-8888-888888888888";
  DSHLocalProjectAccess *access = nil;
  NSURL *baseURL = [self makeLegacyFixtureWithProjectId:projectId
                                                   hook:nil
                                                 access:&access
                                             projectURL:nil
                                          repositoryURL:nil];
  NSError *error = nil;
  NSDictionary *evidence =
      [access legacyWorkspaceBootstrapEvidenceForProjectId:projectId
                                                     error:&error];
  XCTAssertNotNil(evidence, @"%@", error);
  NSSet *expectedKeys = [NSSet setWithArray:@[
    @"project_id", @"display_name", @"metadata_sha256", @"capabilities",
    @"projects_root_device_id", @"projects_root_inode_id",
    @"repository_device_id", @"repository_inode_id",
    @"git_device_id", @"git_inode_id"
  ]];
  XCTAssertEqualObjects([NSSet setWithArray:evidence.allKeys], expectedKeys);
  XCTAssertEqualObjects(evidence[@"project_id"], projectId);
  XCTAssertEqualObjects(evidence[@"display_name"], @"Legacy Evidence");
  XCTAssertEqual([evidence[@"metadata_sha256"] length], (NSUInteger)64);
  NSSet *expectedCapabilities = [NSSet setWithArray:@[
    @"read", @"write", @"git", @"project_context"
  ]];
  XCTAssertEqualObjects(evidence[@"capabilities"], expectedCapabilities);
  for (NSString *forbidden in @[
         @"path", @"url", @"root_url", @"repository_url", @"descriptor"
       ]) {
    XCTAssertNil(evidence[forbidden]);
  }
  [[NSFileManager defaultManager] removeItemAtURL:baseURL error:nil];
}

- (void)testLegacyBootstrapEvidenceRejectsMissingAndInvalidMetadata {
  NSString *projectId = @"99999999-9999-4999-8999-999999999999";
  DSHLocalProjectAccess *access = nil;
  NSURL *projectURL = nil;
  NSURL *baseURL = [self makeLegacyFixtureWithProjectId:projectId
                                                   hook:nil
                                                 access:&access
                                             projectURL:&projectURL
                                          repositoryURL:nil];
  NSURL *metadataURL = [projectURL URLByAppendingPathComponent:@"project.json"];
  XCTAssertTrue([[NSFileManager defaultManager] removeItemAtURL:metadataURL
                                                          error:nil]);
  NSError *error = nil;
  XCTAssertNil([access legacyWorkspaceBootstrapEvidenceForProjectId:projectId
                                                              error:&error]);
  XCTAssertEqual(error.code, DSHLocalProjectAccessErrorMetadataInvalid);
  XCTAssertFalse([error.localizedDescription containsString:baseURL.path]);

  XCTAssertTrue([[@"{}" dataUsingEncoding:NSUTF8StringEncoding]
      writeToURL:metadataURL atomically:YES]);
  error = nil;
  XCTAssertNil([access legacyWorkspaceBootstrapEvidenceForProjectId:projectId
                                                              error:&error]);
  XCTAssertEqual(error.code, DSHLocalProjectAccessErrorMetadataInvalid);
  XCTAssertFalse([error.localizedDescription containsString:baseURL.path]);
  [[NSFileManager defaultManager] removeItemAtURL:baseURL error:nil];
}

- (void)testLegacyBootstrapEvidenceRejectsMissingAndInvalidProject {
  NSString *projectId = @"9aaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
  DSHLocalProjectAccess *access = nil;
  NSURL *baseURL = [self makeLegacyFixtureWithProjectId:projectId
                                                   hook:nil
                                                 access:&access
                                             projectURL:nil
                                          repositoryURL:nil];
  NSError *error = nil;
  XCTAssertNil([access legacyWorkspaceBootstrapEvidenceForProjectId:@"invalid"
                                                              error:&error]);
  XCTAssertEqual(error.code, DSHLocalProjectAccessErrorInvalidIdentifier);
  XCTAssertFalse([error.localizedDescription containsString:baseURL.path]);

  error = nil;
  XCTAssertNil([access legacyWorkspaceBootstrapEvidenceForProjectId:
      @"9bbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb" error:&error]);
  XCTAssertEqual(error.code, DSHLocalProjectAccessErrorUnsafeStorage);
  XCTAssertFalse([error.localizedDescription containsString:baseURL.path]);
  [[NSFileManager defaultManager] removeItemAtURL:baseURL error:nil];
}

- (void)testLegacyBootstrapEvidenceRejectsSymlinkedRepository {
  NSString *projectId = @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
  DSHLocalProjectAccess *access = nil;
  NSURL *repositoryURL = nil;
  NSURL *baseURL = [self makeLegacyFixtureWithProjectId:projectId
                                                   hook:nil
                                                 access:&access
                                             projectURL:nil
                                          repositoryURL:&repositoryURL];
  NSURL *movedURL = [repositoryURL.URLByDeletingLastPathComponent
      URLByAppendingPathComponent:@"repo-real" isDirectory:YES];
  XCTAssertEqual(rename(repositoryURL.fileSystemRepresentation,
                        movedURL.fileSystemRepresentation), 0);
  XCTAssertEqual(symlink(movedURL.fileSystemRepresentation,
                         repositoryURL.fileSystemRepresentation), 0);
  NSError *error = nil;
  XCTAssertNil([access legacyWorkspaceBootstrapEvidenceForProjectId:projectId
                                                              error:&error]);
  XCTAssertEqual(error.code, DSHLocalProjectAccessErrorUnsafeStorage);
  XCTAssertFalse([error.localizedDescription containsString:baseURL.path]);
  [[NSFileManager defaultManager] removeItemAtURL:baseURL error:nil];
}

- (void)testLegacyBootstrapEvidenceHoldsTheProjectReadLock {
  NSString *projectId = @"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
  XCTestExpectation *started = [self expectationWithDescription:@"resolver started"];
  XCTestExpectation *prematureOpen =
      [self expectationWithDescription:@"must remain behind write lock"];
  prematureOpen.inverted = YES;
  XCTestExpectation *opened = [self expectationWithDescription:@"opened after unlock"];
  XCTestExpectation *finished = [self expectationWithDescription:@"evidence returned"];
  NSObject *phaseLock = [[NSObject alloc] init];
  __block BOOL writeLockReleased = NO;
  DSHLocalProjectAccess *access = nil;
  NSURL *baseURL = [self makeLegacyFixtureWithProjectId:projectId
      hook:^(NSString *stage) {
        if (![stage isEqual:@"after_root_open"]) return;
        @synchronized (phaseLock) {
          [writeLockReleased ? opened : prematureOpen fulfill];
        }
      }
      access:&access projectURL:nil repositoryURL:nil];
  NSError *error = nil;
  DSHLocalProjectLockToken *writeToken =
      [access lockProjectId:projectId mode:DSHLocalProjectAccessModeWrite
                      error:&error];
  XCTAssertNotNil(writeToken, @"%@", error);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    [started fulfill];
    NSError *backgroundError = nil;
    XCTAssertNotNil([access legacyWorkspaceBootstrapEvidenceForProjectId:projectId
                                                                    error:&backgroundError],
                    @"%@", backgroundError);
    [finished fulfill];
  });
  NSArray<XCTestExpectation *> *blockedPhase = @[started, prematureOpen];
  XCTWaiterResult blockedResult =
      [XCTWaiter waitForExpectations:blockedPhase timeout:0.1];
  XCTAssertEqual(blockedResult, XCTWaiterResultCompleted);
  @synchronized (phaseLock) {
    writeLockReleased = YES;
  }
  writeToken = nil;
  XCTAssertEqual([XCTWaiter waitForExpectations:@[opened] timeout:2.0],
                 XCTWaiterResultCompleted);
  XCTAssertEqual([XCTWaiter waitForExpectations:@[finished] timeout:2.0],
                 XCTWaiterResultCompleted);
  [[NSFileManager defaultManager] removeItemAtURL:baseURL error:nil];
}

- (void)assertLegacyBootstrapEvidenceRejectsSwapTarget:(NSString *)target {
  NSString *projectId = @"cccccccc-cccc-4ccc-8ccc-cccccccccccc";
  NSURL *projectURL = nil;
  NSURL *repositoryURL = nil;
  NSURL *baseURL = [self makeLegacyFixtureWithProjectId:projectId
                                                   hook:nil
                                                 access:nil
                                             projectURL:&projectURL
                                          repositoryURL:&repositoryURL];
  NSURL *projectsURL = projectURL.URLByDeletingLastPathComponent;
  NSURL *targetURL = [target isEqual:@"root"]
      ? projectsURL
      : ([target isEqual:@"repo"] ? repositoryURL
                                   : [repositoryURL
                                         URLByAppendingPathComponent:@".git"
                                                       isDirectory:YES]);
  XCTAssertTrue([[NSFileManager defaultManager]
      fileExistsAtPath:targetURL.path isDirectory:nil], @"%@", targetURL);
  NSURL *pinnedURL = [targetURL.URLByDeletingLastPathComponent
      URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.pinned-%@",
          targetURL.lastPathComponent, NSUUID.UUID.UUIDString.lowercaseString]
                    isDirectory:YES];
  __block BOOL swapAttempted = NO;
  __block int renameResult = INT_MIN;
  __block int renameErrno = 0;
  __block int mkdirResult = INT_MIN;
  __block int mkdirErrno = 0;
  DSHLocalProjectAccess *access = [[DSHLocalProjectAccess alloc]
      initWithProjectsRootURL:projectsURL
      hook:^(NSString *stage) {
        if (swapAttempted || ![stage isEqual:@"before_identity_recheck"]) return;
        swapAttempted = YES;
        renameResult = rename(targetURL.fileSystemRepresentation,
                              pinnedURL.fileSystemRepresentation);
        renameErrno = renameResult == 0 ? 0 : errno;
        if (renameResult == 0) {
          mkdirResult = mkdir(targetURL.fileSystemRepresentation, 0700);
          mkdirErrno = mkdirResult == 0 ? 0 : errno;
        }
      }];
  NSError *error = nil;
  NSDictionary *evidence =
      [access legacyWorkspaceBootstrapEvidenceForProjectId:projectId
                                                     error:&error];
  XCTAssertTrue(swapAttempted, @"%@ swap hook did not run", target);
  XCTAssertEqual(renameResult, 0, @"%@ rename errno=%d", target, renameErrno);
  XCTAssertEqual(mkdirResult, 0, @"%@ mkdir errno=%d", target, mkdirErrno);
  if (renameResult == 0 && mkdirResult == 0) {
    XCTAssertNil(evidence, @"%@ must reject", target);
    XCTAssertEqual(error.code, DSHLocalProjectAccessErrorUnsafeStorage);
    XCTAssertFalse([error.localizedDescription containsString:baseURL.path]);
  }
  [[NSFileManager defaultManager] removeItemAtURL:baseURL error:nil];
}

- (void)testLegacyBootstrapEvidenceRejectsProjectsRootSwap {
  [self assertLegacyBootstrapEvidenceRejectsSwapTarget:@"root"];
}

- (void)testLegacyBootstrapEvidenceRejectsRepositorySwap {
  [self assertLegacyBootstrapEvidenceRejectsSwapTarget:@"repo"];
}

- (void)testLegacyBootstrapEvidenceRejectsGitDirectorySwap {
  [self assertLegacyBootstrapEvidenceRejectsSwapTarget:@"git"];
}

@end
