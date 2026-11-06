#import <XCTest/XCTest.h>

#import "RishGuestCgiFeature.h"

#import "../../../../modules/rish/ios/Sources/LegacyBoundProjectRootAccess.h"
#import "../../../../modules/rish/ios/Sources/AgentGitToolExecutor.h"
#import "../../../../modules/rish/ios/Sources/AgentRootResolver.h"
#import "../../../../modules/rish/ios/Sources/AgentNativeWAL.h"
#import "../../../../modules/rish/ios/Sources/AgentWorkspaceToolExecutor.h"

#include <fcntl.h>
#include <git2.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString *const DSHLegacyAdapterWorkspace =
    @"11111111-1111-4111-8111-111111111111";
static NSString *const DSHLegacyAdapterProject =
    @"22222222-2222-4222-8222-222222222222";
static NSString *const DSHLegacyAdapterOtherProject =
    @"33333333-3333-4333-8333-333333333333";
static NSString *const DSHLegacyAdapterOperation =
    @"44444444-4444-4444-8444-444444444444";

@interface LegacyBoundProjectRootAccessTests : XCTestCase
@property(nonatomic, strong) NSURL *baseURL;
@property(nonatomic, strong) NSURL *privateURL;
@property(nonatomic, strong) NSURL *documentsURL;
@property(nonatomic, strong) NSURL *projectsURL;
@property(nonatomic, strong) NSURL *repositoryURL;
@property(nonatomic, strong) DSHLocalWorkspaceAccess *workspaceAccess;
@property(nonatomic, strong) DSHLocalProjectAccess *projectAccess;
@property(nonatomic, strong) DSHLegacyBoundProjectRootAccess *adapter;
@property(nonatomic, copy) NSDictionary *boundRoot;
@property(nonatomic) BOOL driftLegacyEvidence;
@end

@implementation LegacyBoundProjectRootAccessTests

- (void)setUp {
  [super setUp];
  self.baseURL = [NSURL fileURLWithPath:[NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [@"legacy-bound-root-" stringByAppendingString:
              NSUUID.UUID.UUIDString.lowercaseString]] isDirectory:YES];
  self.privateURL = [self.baseURL URLByAppendingPathComponent:@"private"
                                                   isDirectory:YES];
  self.documentsURL = [self.baseURL URLByAppendingPathComponent:@"documents"
                                                     isDirectory:YES];
  self.projectsURL = [self.baseURL URLByAppendingPathComponent:@"projects"
                                                    isDirectory:YES];
  NSURL *projectURL = [self.projectsURL
      URLByAppendingPathComponent:DSHLegacyAdapterProject isDirectory:YES];
  self.repositoryURL = [projectURL URLByAppendingPathComponent:@"repo"
                                                    isDirectory:YES];
  for (NSURL *url in @[self.privateURL, self.documentsURL, self.repositoryURL]) {
    XCTAssertTrue(([NSFileManager.defaultManager createDirectoryAtURL:url
                                         withIntermediateDirectories:YES
                                                          attributes:@{
      NSFilePosixPermissions : @0700,
    } error:nil]));
  }
  NSDictionary *metadata = @{
    @"schema_version" : @1,
    @"name" : @"Legacy Adapter Fixture",
    @"created_at" : @"2026-09-01T00:00:00.000Z",
    @"updated_at" : @"2026-09-01T00:00:00.000Z",
    @"origin_url" : NSNull.null,
  };
  NSData *metadataData = [NSJSONSerialization dataWithJSONObject:metadata
                                                          options:0 error:nil];
  XCTAssertTrue([metadataData writeToURL:
      [projectURL URLByAppendingPathComponent:@"project.json"] atomically:YES]);
  XCTAssertTrue([[@"marker\n" dataUsingEncoding:NSUTF8StringEncoding]
      writeToURL:[self.repositoryURL URLByAppendingPathComponent:@"marker.txt"]
      atomically:YES]);
  XCTAssertGreaterThan(git_libgit2_init(), 0);
  git_repository *repository = nullptr;
  XCTAssertEqual(git_repository_init(&repository,
                                      self.repositoryURL.fileSystemRepresentation,
                                      0), 0);
  if (repository != nullptr) git_repository_free(repository);

  self.projectAccess = [[DSHLocalProjectAccess alloc]
      initWithProjectsRootURL:self.projectsURL hook:nil];
  __weak LegacyBoundProjectRootAccessTests *weakSelf = self;
  self.workspaceAccess = [[DSHLocalWorkspaceAccess alloc]
      initWithPrivateRootURL:self.privateURL
          documentsRootURL:self.documentsURL
      clock:^NSDate * { return [NSDate dateWithTimeIntervalSince1970:1788220800]; }
      UUIDGenerator:^NSString * { return DSHLegacyAdapterWorkspace; }
      legacyResolver:^BOOL(NSString *projectId, NSDictionary **evidence,
                           NSError **error) {
        LegacyBoundProjectRootAccessTests *strongSelf = weakSelf;
        NSDictionary *resolved = [strongSelf.projectAccess
            legacyWorkspaceBootstrapEvidenceForProjectId:projectId error:error];
        if (resolved == nil) return NO;
        if (strongSelf.driftLegacyEvidence) {
          NSMutableDictionary *drifted = [resolved mutableCopy];
          drifted[@"repository_inode_id"] = @"1";
          resolved = drifted;
        }
        if (evidence != nullptr) *evidence = resolved;
        return YES;
      }
      faultHook:nil];
  NSError *error = nil;
  NSDictionary *descriptor = [self.workspaceAccess
      bootstrapLegacyProjectId:DSHLegacyAdapterProject
                   operationId:DSHLegacyAdapterOperation
                         error:&error];
  XCTAssertNotNil(descriptor, @"%@", error);
  NSDictionary *authority = [self authorityObject];
  XCTAssertNotNil(authority);
  self.boundRoot = @{
    @"schema_version" : @1,
    @"kind" : @"project",
    @"workspace_id" : DSHLegacyAdapterWorkspace,
    @"workspace_binding_revision" : @1,
    @"project_id" : DSHLegacyAdapterProject,
    @"root_fingerprint_sha256" : authority[@"root_fingerprint_sha256"],
    @"capabilities" : @[
      @"file_read", @"file_write", @"git_status", @"git_commit", @"git_push",
    ],
  };
  self.adapter = [[DSHLegacyBoundProjectRootAccess alloc]
      initWithWorkspaceAccess:self.workspaceAccess
                 projectAccess:self.projectAccess];
}

- (void)tearDown {
  self.adapter = nil;
  self.workspaceAccess = nil;
  self.projectAccess = nil;
  [NSFileManager.defaultManager removeItemAtURL:self.baseURL error:nil];
  [super tearDown];
}

- (NSURL *)authorityURL {
  NSString *name = [NSString stringWithFormat:@"legacy-%@-r1.json",
                                               DSHLegacyAdapterWorkspace];
  return [[self.privateURL URLByAppendingPathComponent:@"workspace-bindings"
                                            isDirectory:YES]
      URLByAppendingPathComponent:name];
}

- (NSDictionary *)authorityObject {
  NSData *data = [NSData dataWithContentsOfURL:[self authorityURL]];
  return data == nil ? nil : [NSJSONSerialization JSONObjectWithData:data
                                                               options:0
                                                                 error:nil];
}

- (void)secureWriteJSONObject:(NSDictionary *)object toURL:(NSURL *)url {
  NSData *data = [NSJSONSerialization dataWithJSONObject:object
                                                  options:NSJSONWritingSortedKeys
                                                    error:nil];
  XCTAssertTrue([data writeToURL:url options:NSDataWritingAtomic error:nil]);
  XCTAssertTrue(([NSFileManager.defaultManager setAttributes:@{
    NSFilePosixPermissions : @0600,
    NSFileProtectionKey : NSFileProtectionComplete,
  } ofItemAtPath:url.path error:nil]));
  XCTAssertTrue([url setResourceValue:@YES
                               forKey:NSURLIsExcludedFromBackupKey error:nil]);
}

- (DSHLegacyBoundProjectRootDisposition)performRoot:(NSDictionary *)root
                                                mode:(DSHLegacyBoundProjectRootOperationMode)mode
                                               block:(DSHLegacyBoundProjectRootOperation)block
                                               error:(NSError **)error {
  return [self.adapter performRepositoryRootOperationForBoundRoot:root
                                                              mode:mode
                                                           timeout:1.0
                                                             block:block
                                                             error:error];
}

- (void)assertRootChanged:(NSError *)error {
  XCTAssertEqualObjects(error.domain,
                        DSHLegacyBoundProjectRootAccessErrorDomain);
  XCTAssertEqual(error.code,
                 DSHLegacyBoundProjectRootAccessErrorRootChanged);
}

- (void)testBootstrapLeaseReadsMarkerThroughBorrowedRepositoryDescriptor {
  __block NSString *marker = nil;
  NSError *error = nil;
  DSHLegacyBoundProjectRootDisposition result = [self performRoot:self.boundRoot
      mode:DSHLegacyBoundProjectRootOperationModeRead
      block:^BOOL(int descriptor, NSError **blockError) {
        int fd = openat(descriptor, "marker.txt", O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
        if (fd < 0) return NO;
        char bytes[16] = {};
        ssize_t count = read(fd, bytes, sizeof(bytes));
        close(fd);
        marker = count > 0 ? [[NSString alloc] initWithBytes:bytes
                                                    length:(NSUInteger)count
                                                  encoding:NSUTF8StringEncoding]
                           : nil;
        return marker != nil;
      } error:&error];
  XCTAssertEqual(result, DSHLegacyBoundProjectRootDispositionHandled);
  XCTAssertEqualObjects(marker, @"marker\n");
  XCTAssertNil(error);
}

- (void)testRevisionDriftFailsRootChangedWithoutRunningBlock {
  NSMutableDictionary *root = [self.boundRoot mutableCopy];
  root[@"workspace_binding_revision"] = @2;
  __block BOOL ran = NO;
  NSError *error = nil;
  XCTAssertEqual([self performRoot:root
      mode:DSHLegacyBoundProjectRootOperationModeRead
      block:^BOOL(__unused int fd, __unused NSError **e) { ran = YES; return YES; }
      error:&error], DSHLegacyBoundProjectRootDispositionFailed);
  XCTAssertFalse(ran);
  [self assertRootChanged:error];
}

- (void)testFingerprintDriftFailsRootChangedWithoutRunningBlock {
  NSMutableDictionary *root = [self.boundRoot mutableCopy];
  root[@"root_fingerprint_sha256"] = [@"f" stringByPaddingToLength:64
      withString:@"f" startingAtIndex:0];
  NSError *error = nil;
  XCTAssertEqual([self performRoot:root
      mode:DSHLegacyBoundProjectRootOperationModeRead
      block:^BOOL(__unused int fd, __unused NSError **e) { return YES; }
      error:&error], DSHLegacyBoundProjectRootDispositionFailed);
  [self assertRootChanged:error];
}

- (void)testProjectMismatchFailsConflict {
  NSMutableDictionary *root = [self.boundRoot mutableCopy];
  root[@"project_id"] = DSHLegacyAdapterOtherProject;
  NSError *error = nil;
  XCTAssertEqual([self performRoot:root
      mode:DSHLegacyBoundProjectRootOperationModeRead
      block:^BOOL(__unused int fd, __unused NSError **e) { return YES; }
      error:&error], DSHLegacyBoundProjectRootDispositionFailed);
  XCTAssertEqual(error.code, DSHLegacyBoundProjectRootAccessErrorConflict);
}

- (void)testRepositoryRootSwapInsideBlockFailsPostBlockIdentityProof {
  NSURL *oldURL = [self.repositoryURL.URLByDeletingLastPathComponent
      URLByAppendingPathComponent:@"repo-old" isDirectory:YES];
  NSError *error = nil;
  XCTAssertEqual([self performRoot:self.boundRoot
      mode:DSHLegacyBoundProjectRootOperationModeRead
      block:^BOOL(__unused int fd, __unused NSError **e) {
        XCTAssertEqual(rename(self.repositoryURL.fileSystemRepresentation,
                              oldURL.fileSystemRepresentation), 0);
        XCTAssertEqual(mkdir(self.repositoryURL.fileSystemRepresentation, 0700), 0);
        return YES;
      } error:&error], DSHLegacyBoundProjectRootDispositionFailed);
  [self assertRootChanged:error];
}

- (void)testPostBlockWorkspaceEvidenceDriftFailsRootChanged {
  NSError *error = nil;
  XCTAssertEqual([self performRoot:self.boundRoot
      mode:DSHLegacyBoundProjectRootOperationModeRead
      block:^BOOL(__unused int fd, __unused NSError **e) {
        self.driftLegacyEvidence = YES;
        return YES;
      } error:&error], DSHLegacyBoundProjectRootDispositionFailed);
  [self assertRootChanged:error];
}

- (void)testRawLegacyWorkspaceDescriptorRemainsRejectedAndBlockDoesNotRun {
  NSDictionary *raw = @{
    @"workspace_id" : DSHLegacyAdapterWorkspace,
    @"binding_revision" : @1,
    @"legacy_project_id" : DSHLegacyAdapterProject,
  };
  __block BOOL ran = NO;
  NSError *error = nil;
  XCTAssertEqual([self performRoot:raw
      mode:DSHLegacyBoundProjectRootOperationModeRead
      block:^BOOL(__unused int fd, __unused NSError **e) { ran = YES; return YES; }
      error:&error], DSHLegacyBoundProjectRootDispositionFailed);
  XCTAssertFalse(ran);
  XCTAssertEqual(error.code, DSHLegacyBoundProjectRootAccessErrorInvalid);
}

- (void)testWorkspaceOnlyRootIsRejected {
  NSMutableDictionary *root = [self.boundRoot mutableCopy];
  root[@"kind"] = @"workspace";
  root[@"project_id"] = NSNull.null;
  NSError *error = nil;
  XCTAssertEqual([self performRoot:root
      mode:DSHLegacyBoundProjectRootOperationModeRead
      block:^BOOL(__unused int fd, __unused NSError **e) { return YES; }
      error:&error], DSHLegacyBoundProjectRootDispositionFailed);
  XCTAssertEqual(error.code, DSHLegacyBoundProjectRootAccessErrorInvalid);
}

- (void)testModeRequiresItsBoundRootCapability {
  NSMutableDictionary *root = [self.boundRoot mutableCopy];
  root[@"capabilities"] = @[@"file_read"];
  NSError *error = nil;
  XCTAssertEqual([self performRoot:root
      mode:DSHLegacyBoundProjectRootOperationModeWrite
      block:^BOOL(__unused int fd, __unused NSError **e) { return YES; }
      error:&error], DSHLegacyBoundProjectRootDispositionFailed);
  XCTAssertEqual(error.code, DSHLegacyBoundProjectRootAccessErrorInvalid);
}

- (void)testGitWriteModeRequiresCommitCapabilityAndUsesWriteLease {
  NSMutableDictionary *root = [self.boundRoot mutableCopy];
  root[@"capabilities"] = @[@"file_read", @"git_status"];
  __block BOOL ran = NO;
  NSError *error = nil;
  XCTAssertEqual([self performRoot:root
      mode:DSHLegacyBoundProjectRootOperationModeGitWrite
      block:^BOOL(__unused int fd, __unused NSError **e) {
        ran = YES;
        return YES;
      } error:&error], DSHLegacyBoundProjectRootDispositionFailed);
  XCTAssertFalse(ran);
  XCTAssertEqual(error.code, DSHLegacyBoundProjectRootAccessErrorInvalid);
}

- (void)testAllClosedModesRunOnlyWithTheirBoundCapabilities {
  for (NSNumber *mode in @[
    @(DSHLegacyBoundProjectRootOperationModeRead),
    @(DSHLegacyBoundProjectRootOperationModeWrite),
    @(DSHLegacyBoundProjectRootOperationModeGitRead),
    @(DSHLegacyBoundProjectRootOperationModeGitWrite),
    @(DSHLegacyBoundProjectRootOperationModeProjectContext),
  ]) {
    __block BOOL ran = NO;
    NSError *error = nil;
    XCTAssertEqual([self performRoot:self.boundRoot
        mode:(DSHLegacyBoundProjectRootOperationMode)mode.integerValue
        block:^BOOL(__unused int fd, __unused NSError **e) {
          ran = YES;
          return YES;
        } error:&error], DSHLegacyBoundProjectRootDispositionHandled,
        @"mode=%@ error=%@", mode, error);
    XCTAssertTrue(ran);
  }
}

- (void)testAgentRevisionConflictDoesNotBecomeRootStale {
  DSHAgentRootResolver *resolver = [[DSHAgentRootResolver alloc]
      initWithWorkspaceAccess:self.workspaceAccess projectAccess:self.projectAccess];
  NSError *error = nil;
  NSDictionary *root = [resolver resolveRootForWorkspaceId:DSHLegacyAdapterWorkspace
      projectId:DSHLegacyAdapterProject bindingRevision:@1 error:&error];
  DSHAgentWorkspaceToolExecutor *executor =
      [[DSHAgentWorkspaceToolExecutor alloc] initWithRootResolver:resolver];
  NSDictionary *invalid = @{
    @"path": @"new-file.txt", @"content": @"test\n", @"expected_revision": @"null",
  };
  XCTAssertNil([executor prepareToolNamed:@"write_file" arguments:invalid root:root error:&error]);
  XCTAssertEqualObjects(error.domain, DSHAgentNativeStoreErrorDomain);
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorConflict);
  XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:
      [self.repositoryURL URLByAppendingPathComponent:@"new-file.txt"].path]);
  error = nil;
  XCTAssertTrue([resolver validateFrozenRoot:root error:&error]);
  NSMutableDictionary *valid = [invalid mutableCopy];
  valid[@"expected_revision"] = NSNull.null;
  XCTAssertNotNil([executor prepareToolNamed:@"write_file" arguments:valid root:root error:&error]);
  XCTAssertNil(error);
  [valid removeObjectForKey:@"expected_revision"];
  NSDictionary *prepared = [executor prepareToolNamed:@"write_file"
      arguments:valid root:root error:&error];
  XCTAssertNotNil(prepared, @"%@", error);
  XCTAssertEqualObjects(prepared[@"precondition"][@"prior"][@"kind"], @"absent");
  NSDictionary *written = [executor executeToolNamed:@"write_file" arguments:valid
      root:root precondition:prepared[@"precondition"] error:&error];
  XCTAssertEqualObjects(written[@"status"], @"ok", @"%@", error);
  error = nil;
  XCTAssertNil([executor prepareToolNamed:@"write_file" arguments:valid root:root error:&error]);
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorConflict);
  XCTAssertEqualObjects([NSString stringWithContentsOfURL:
      [self.repositoryURL URLByAppendingPathComponent:@"new-file.txt"]
      encoding:NSUTF8StringEncoding error:nil], @"test\n");
}

- (void)testVerifiedLegacyRootRunsFileWriteStatusAndCommitEndToEnd {
  DSHAgentRootResolver *resolver = [[DSHAgentRootResolver alloc]
      initWithWorkspaceAccess:self.workspaceAccess
                 projectAccess:self.projectAccess];
  NSError *error = nil;
  NSDictionary *root = [resolver
      resolveRootForWorkspaceId:DSHLegacyAdapterWorkspace
      projectId:DSHLegacyAdapterProject bindingRevision:@1 error:&error];
  NSMutableDictionary *expectedRoot = [self.boundRoot mutableCopy];
#if DSH_GUEST_CGI_AVAILABLE
  // The resolver advertises the optional host capability in debug/enabled
  // builds; the lower-level adapter fixture deliberately grants only Git/files.
  NSMutableArray *capabilities = [expectedRoot[@"capabilities"] mutableCopy];
  [capabilities insertObject:@"guest_service" atIndex:2];
  expectedRoot[@"capabilities"] = capabilities;
#endif
  XCTAssertEqualObjects(root, expectedRoot, @"%@", error);
  DSHLocalWorkspaceAuthorityMutationGuard *guard = [resolver
      acquireAuthorityMutationGuardForFrozenRoot:root error:&error];
  XCTAssertNotNil(guard, @"%@", error);
  XCTAssertTrue([resolver validateFrozenRoot:root
      authorityMutationGuard:guard error:&error], @"%@", error);
  guard = nil;
  DSHAgentRootFinalProof *finalProof = [resolver
      acquireFinalProofForFrozenRoot:root
      requiredCapabilities:[NSSet setWithArray:@[
        @"file_write", @"git_status", @"git_commit",
      ]]
      needsProjectLease:YES projectWriteAccess:YES error:&error];
  XCTAssertNotNil(finalProof, @"%@", error);
  finalProof = nil;
  XCTAssertNil([resolver acquireFinalProofForFrozenRoot:root
      requiredCapabilities:[NSSet setWithObject:@"git_push"]
      needsProjectLease:YES projectWriteAccess:YES error:&error]);
  XCTAssertNotNil(error);
  error = nil;

  DSHAgentWorkspaceToolExecutor *workspace =
      [[DSHAgentWorkspaceToolExecutor alloc] initWithRootResolver:resolver];
  NSDictionary *writeArguments = @{
    @"path" : @"agent-proof.txt",
    @"content" : @"legacy agent proof\n",
    @"expected_prior" : @{
      @"schema_version" : @1, @"kind" : @"absent",
    },
  };
  NSDictionary *writePrepared = [workspace prepareToolNamed:@"write_file"
      arguments:writeArguments root:root error:&error];
  XCTAssertNotNil(writePrepared, @"%@", error);
  NSDictionary *writeResult = [workspace executeToolNamed:@"write_file"
      arguments:writeArguments root:root
      precondition:writePrepared[@"precondition"] error:&error];
  XCTAssertEqualObjects(writeResult[@"status"], @"ok", @"%@", error);

  DSHAgentGitToolExecutor *git = [[DSHAgentGitToolExecutor alloc]
      initWithRootResolver:resolver];
  NSDictionary *statusPrepared = [git prepareToolNamed:@"git_status"
      arguments:@{} root:root error:&error];
  XCTAssertNotNil(statusPrepared, @"%@", error);
  NSDictionary *statusResult = [git executeToolNamed:@"git_status"
      arguments:@{} root:root precondition:statusPrepared[@"precondition"]
      error:&error];
  XCTAssertEqualObjects(statusResult[@"status"], @"ok", @"%@", error);

  NSDictionary *commitArguments = @{ @"message" : @"legacy agent proof" };
  NSDictionary *commitPrepared = [git prepareToolNamed:@"git_commit"
      arguments:commitArguments root:root error:&error];
  XCTAssertNotNil(commitPrepared, @"%@", error);
  NSDictionary *commitResult = [git executeToolNamed:@"git_commit"
      arguments:commitArguments root:root
      precondition:commitPrepared[@"precondition"] error:&error];
  XCTAssertEqualObjects(commitResult[@"status"], @"ok", @"%@", error);
  XCTAssertTrue([commitResult[@"settled_facts"][@"actual_commit_oid"] length] > 0);

  NSString *content = [NSString stringWithContentsOfURL:
      [self.repositoryURL URLByAppendingPathComponent:@"agent-proof.txt"]
      encoding:NSUTF8StringEncoding error:&error];
  XCTAssertEqualObjects(content, @"legacy agent proof\n");

  DSHLocalWorkspaceAccess *restartedAccess = [[DSHLocalWorkspaceAccess alloc]
      initWithPrivateRootURL:self.privateURL documentsRootURL:self.documentsURL
      clock:^NSDate * { return [NSDate dateWithTimeIntervalSince1970:1788220800]; }
      UUIDGenerator:^NSString * { return NSUUID.UUID.UUIDString.lowercaseString; }
      legacyResolver:^BOOL(NSString *projectId, NSDictionary **evidence,
                           NSError **resolverError) {
        NSDictionary *resolved = [self.projectAccess
            legacyWorkspaceBootstrapEvidenceForProjectId:projectId
                                                   error:resolverError];
        if (evidence != nullptr) *evidence = resolved;
        return resolved != nil;
      } faultHook:nil];
  DSHAgentRootResolver *restarted = [[DSHAgentRootResolver alloc]
      initWithWorkspaceAccess:restartedAccess projectAccess:self.projectAccess];
  NSDictionary *restartedRoot = [restarted
      resolveRootForWorkspaceId:DSHLegacyAdapterWorkspace
      projectId:DSHLegacyAdapterProject bindingRevision:@1 error:&error];
  XCTAssertEqualObjects(restartedRoot, root, @"%@", error);
  DSHAgentGitToolExecutor *restartedGit = [[DSHAgentGitToolExecutor alloc]
      initWithRootResolver:restarted];
  NSDictionary *restartedStatus = [restartedGit prepareToolNamed:@"git_status"
      arguments:@{} root:restartedRoot error:&error];
  XCTAssertNotNil(restartedStatus, @"%@", error);
}

- (void)testDocumentsOwnedRootReturnsNotHandledWithoutRunningBlock {
  NSURL *privateURL = [self.baseURL URLByAppendingPathComponent:@"owned-private"
                                                    isDirectory:YES];
  NSURL *documentsURL = [self.baseURL URLByAppendingPathComponent:@"owned-docs"
                                                      isDirectory:YES];
  for (NSURL *url in @[privateURL, documentsURL]) {
    XCTAssertTrue(([NSFileManager.defaultManager createDirectoryAtURL:url
                                         withIntermediateDirectories:YES
                                                          attributes:@{
      NSFilePosixPermissions : @0700,
    } error:nil]));
  }
  DSHLocalWorkspaceAccess *ownedAccess = [[DSHLocalWorkspaceAccess alloc]
      initWithPrivateRootURL:privateURL documentsRootURL:documentsURL
      clock:^NSDate * { return [NSDate dateWithTimeIntervalSince1970:1788220800]; }
      UUIDGenerator:^NSString * { return @"55555555-5555-4555-8555-555555555555"; }
      legacyResolver:^BOOL(__unused NSString *projectId,
                           NSDictionary **evidence, NSError **error) {
        if (evidence != nullptr) *evidence = nil;
        return NO;
      } faultHook:nil];
  NSError *error = nil;
  NSDictionary *descriptor = [ownedAccess
      createRishOwnedWorkspaceWithDisplayName:@"Owned"
                                  operationId:@"66666666-6666-4666-8666-666666666666"
                                        error:&error];
  XCTAssertNotNil(descriptor, @"%@", error);
  DSHLegacyBoundProjectRootAccess *adapter =
      [[DSHLegacyBoundProjectRootAccess alloc]
          initWithWorkspaceAccess:ownedAccess projectAccess:self.projectAccess];
  NSMutableDictionary *root = [self.boundRoot mutableCopy];
  root[@"workspace_id"] = descriptor[@"workspace_id"];
  root[@"root_fingerprint_sha256"] =
      @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  __block BOOL ran = NO;
  XCTAssertEqual([adapter performRepositoryRootOperationForBoundRoot:root
      mode:DSHLegacyBoundProjectRootOperationModeRead timeout:1
      block:^BOOL(__unused int fd, __unused NSError **e) { ran = YES; return YES; }
      error:&error], DSHLegacyBoundProjectRootDispositionNotHandled);
  XCTAssertFalse(ran);
  XCTAssertNil(error);
}

- (void)testSecurityScopedLocatorIsRejectedBeforeBlock {
  NSURL *registryURL = [[self.privateURL
      URLByAppendingPathComponent:@"local-workspaces" isDirectory:YES]
      URLByAppendingPathComponent:@"registry-v1.json"];
  NSDictionary *record = @{
    @"schema_version" : @1,
    @"workspace_id" : DSHLegacyAdapterWorkspace,
    @"display_name" : @"Granted",
    @"origin" : @"granted_folder",
    @"root_locator_kind" : @"security_scoped",
    @"location_class" : @"proven_local",
    @"owned_directory_name" : NSNull.null,
    @"legacy_project_id" : NSNull.null,
    @"binding_revision" : @1,
    @"created_at" : @"2026-09-01T00:00:00.000Z",
    @"last_opened_at" : @"2026-09-01T00:00:00.000Z",
  };
  [self secureWriteJSONObject:@{
    @"schema_version" : @1,
    @"generation" : @2,
    @"records" : @[record],
  } toURL:registryURL];
  __block BOOL ran = NO;
  NSError *error = nil;
  XCTAssertEqual([self performRoot:self.boundRoot
      mode:DSHLegacyBoundProjectRootOperationModeRead
      block:^BOOL(__unused int fd, __unused NSError **e) { ran = YES; return YES; }
      error:&error], DSHLegacyBoundProjectRootDispositionFailed);
  XCTAssertFalse(ran);
  XCTAssertEqual(error.code, DSHLegacyBoundProjectRootAccessErrorConflict);
}

- (void)testTimeoutIsBoundedBeforeAuthorityOrBlock {
  __block BOOL ran = NO;
  NSError *error = nil;
  XCTAssertEqual([self.adapter performRepositoryRootOperationForBoundRoot:self.boundRoot
      mode:DSHLegacyBoundProjectRootOperationModeRead timeout:31.0
      block:^BOOL(__unused int fd, __unused NSError **e) { ran = YES; return YES; }
      error:&error], DSHLegacyBoundProjectRootDispositionFailed);
  XCTAssertFalse(ran);
  XCTAssertEqual(error.code, DSHLegacyBoundProjectRootAccessErrorInvalid);
}

@end
