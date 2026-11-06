#import "LocalProjectsModuleV2TestSupport.h"

#import "../../../../modules/rish/ios/Sources/DSHGitSSHSupport.h"
#import "../../../../modules/rish/ios/Sources/AgentPolicyService.h"
#import "../../../../modules/rish/ios/Sources/AgentRootResolver.h"
#import "../../../../modules/rish/ios/Sources/AgentToolRegistry.h"
#import "../../../../modules/rish/ios/Sources/SessionWorkspaceCoordinator.h"

#include <git2.h>
#include <sys/stat.h>
#include <unistd.h>

@implementation LocalProjectsModuleV2Tests

- (void)setUp {
  [super setUp];
  NSString *suffix = NSUUID.UUID.UUIDString.lowercaseString;
  self.privateRoot = [NSURL fileURLWithPath:
      [NSTemporaryDirectory() stringByAppendingPathComponent:
          [NSString stringWithFormat:@"rish-attach-private-%@", suffix]]
                                      isDirectory:YES];
  self.documentsRoot = [NSURL fileURLWithPath:
      [NSTemporaryDirectory() stringByAppendingPathComponent:
          [NSString stringWithFormat:@"rish-attach-documents-%@", suffix]]
                                        isDirectory:YES];
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:self.privateRoot
                                      withIntermediateDirectories:YES
                                                       attributes:nil error:nil]);
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:self.documentsRoot
                                      withIntermediateDirectories:YES
                                                       attributes:nil error:nil]);
  NSString *workspaceId = @"11111111-1111-4111-8111-111111111111";
  self.workspaceAccess = [[DSHLocalWorkspaceAccess alloc]
      initWithPrivateRootURL:self.privateRoot
            documentsRootURL:self.documentsRoot
                         clock:^NSDate *{ return NSDate.date; }
                UUIDGenerator:^NSString *{ return workspaceId; }
                legacyResolver:^BOOL(__unused NSString *projectId,
                                     NSDictionary **evidence,
                                     NSError **error) {
                  if (evidence != nil) *evidence = nil;
                  if (error != nil) *error = [NSError errorWithDomain:@"test"
                                                                    code:1
                                                                userInfo:nil];
                  return NO;
                }
                      faultHook:nil];
  NSError *error = nil;
  XCTAssertTrue([self.workspaceAccess ensurePrivateLayoutWithError:&error], @"%@", error);
  NSDictionary *workspace = [self.workspaceAccess
      createRishOwnedWorkspaceWithDisplayName:@"Attach Fixture"
                                  operationId:@"22222222-2222-4222-8222-222222222222"
                                        error:&error];
  XCTAssertNotNil(workspace, @"%@", error);
  self.root = @{
    @"schema_version" : @1,
    @"workspace_id" : workspace[@"workspace_id"],
    @"binding_revision" : workspace[@"binding_revision"],
    @"project_id" : [NSNull null],
  };
  self.projectAccess = [[DSHLocalProjectAccess alloc]
      initWithWorkspaceAccess:self.workspaceAccess hook:nil];
  Class moduleClass = NSClassFromString(@"LocalProjectsModule");
  if (moduleClass == Nil) {
    XCTSkip(@"LocalProjectsModule is not linked into this XCTest target");
  }
  self.module = [[moduleClass alloc] init];
  [self.module setValue:self.workspaceAccess forKey:@"workspaceAccessV2"];
  [self.module setValue:self.projectAccess forKey:@"projectAccessV2"];
  [self.module setValue:nil forKey:@"v2AttachStartupError"];
}

- (void)tearDown {
  self.module = nil;
  [NSFileManager.defaultManager removeItemAtURL:self.privateRoot error:nil];
  [NSFileManager.defaultManager removeItemAtURL:self.documentsRoot error:nil];
  [NSFileManager.defaultManager removeItemAtURL:self.legacyBaseRoot error:nil];
  [super tearDown];
}

- (NSDictionary *)attachWithRoot:(NSDictionary *)root error:(NSError **)error {
  return [self.module v2AttachWorkspaceProject:@{
    @"schema_version" : @1,
    @"operation_id" : @"33333333-3333-4333-8333-333333333333",
    @"root" : root,
    @"mode" : @"init",
  } error:error];
}

- (NSURL *)workspaceGitRoot {
  return [[[self.privateRoot
      URLByAppendingPathComponent:@"workspace-gitdirs" isDirectory:YES]
      URLByAppendingPathComponent:self.root[@"workspace_id"] isDirectory:YES]
      URLByStandardizingPath];
}

- (NSArray<NSURL *> *)attachPendingEntries {
  NSError *error = nil;
  NSArray<NSURL *> *entries = [NSFileManager.defaultManager
      contentsOfDirectoryAtURL:self.workspaceGitRoot
      includingPropertiesForKeys:nil options:0 error:&error];
  if (entries == nil && [error.domain isEqual:NSCocoaErrorDomain] &&
      error.code == NSFileReadNoSuchFileError) return @[];
  XCTAssertNotNil(entries, @"%@", error);
  NSPredicate *pending = [NSPredicate predicateWithBlock:
      ^BOOL(NSURL *url, __unused NSDictionary *bindings) {
        return [url.lastPathComponent hasPrefix:@".rish-attach-"];
      }];
  return [entries filteredArrayUsingPredicate:pending];
}

- (LocalProjectsModule *)restartedModule {
  Class moduleClass = NSClassFromString(@"LocalProjectsModule");
  LocalProjectsModule *module = [[moduleClass alloc] init];
  [module setValue:self.workspaceAccess forKey:@"workspaceAccessV2"];
  [module setValue:self.projectAccess forKey:@"projectAccessV2"];
  [module setValue:nil forKey:@"v2AttachStartupError"];
  return module;
}

- (NSDictionary *)installLegacyLookupFixture {
  NSString *projectId = @"55555555-5555-4555-8555-555555555555";
  self.legacyBaseRoot = [NSURL fileURLWithPath:
      [NSTemporaryDirectory() stringByAppendingPathComponent:
          NSUUID.UUID.UUIDString.lowercaseString]
                                      isDirectory:YES];
  NSURL *projectsRoot = [self.legacyBaseRoot
      URLByAppendingPathComponent:@"projects" isDirectory:YES];
  NSURL *projectRoot = [projectsRoot
      URLByAppendingPathComponent:projectId isDirectory:YES];
  NSURL *repositoryRoot = [projectRoot
      URLByAppendingPathComponent:@"repo" isDirectory:YES];
  XCTAssertTrue([NSFileManager.defaultManager
      createDirectoryAtURL:repositoryRoot
      withIntermediateDirectories:YES
      attributes:@{NSFilePosixPermissions : @0700} error:nil]);
  NSDictionary *metadata = @{
    @"schema_version" : @1,
    @"name" : @"Legacy Lookup",
    @"created_at" : @"2026-09-01T00:00:00.000Z",
    @"updated_at" : @"2026-09-01T00:00:00.000Z",
    @"origin_url" : NSNull.null,
  };
  NSData *metadataData = [NSJSONSerialization dataWithJSONObject:metadata
                                                          options:0 error:nil];
  XCTAssertTrue([metadataData writeToURL:
      [projectRoot URLByAppendingPathComponent:@"project.json"]
                              atomically:YES]);
  XCTAssertGreaterThan(git_libgit2_init(), 0);
  git_repository *repository = nullptr;
  XCTAssertEqual(git_repository_init(&repository,
                                      repositoryRoot.fileSystemRepresentation,
                                      0), 0);
  if (repository != nullptr) git_repository_free(repository);

  DSHLocalProjectAccess *legacyAccess = [[DSHLocalProjectAccess alloc]
      initWithProjectsRootURL:projectsRoot hook:nil];
  LocalProjectsModule *module = [[LocalProjectsModule alloc]
      initWithSupportURL:self.privateRoot projectAccess:legacyAccess];
  DSHLocalWorkspaceAccess *legacyWorkspaceAccess =
      [module valueForKey:@"workspaceAccessV2"];
  NSError *error = nil;
  XCTAssertTrue([legacyWorkspaceAccess ensurePrivateLayoutWithError:&error],
                @"%@", error);
  NSDictionary *workspace = [legacyWorkspaceAccess
      bootstrapLegacyProjectId:projectId
                   operationId:@"77777777-7777-4777-8777-777777777777"
                         error:&error];
  XCTAssertNotNil(workspace, @"%@", error);
  self.workspaceAccess = legacyWorkspaceAccess;
  self.projectAccess = legacyAccess;
  self.module = module;
  self.root = @{
    @"schema_version" : @1,
    @"workspace_id" : workspace[@"workspace_id"],
    @"binding_revision" : workspace[@"binding_revision"],
    @"project_id" : NSNull.null,
  };
  return @{ @"project_id" : projectId, @"project_root" : projectRoot };
}

- (void)testProductionResolverUnavailableIsSanitized {
  NSURL *missingProjectsRoot = [self.privateRoot
      URLByAppendingPathComponent:@"missing-projects" isDirectory:YES];
  DSHLocalProjectAccess *missingAccess = [[DSHLocalProjectAccess alloc]
      initWithProjectsRootURL:missingProjectsRoot hook:nil];
  LocalProjectsModule *module = [[LocalProjectsModule alloc]
      initWithSupportURL:self.privateRoot projectAccess:missingAccess];
  DSHLocalWorkspaceAccess *workspaceAccess =
      [module valueForKey:@"workspaceAccessV2"];
  NSError *error = nil;
  XCTAssertNil([workspaceAccess
      bootstrapLegacyProjectId:@"88888888-8888-4888-8888-888888888888"
                   operationId:@"99999999-9999-4999-8999-999999999999"
                         error:&error]);
  XCTAssertEqualObjects(error.domain, DSHLocalWorkspaceAccessErrorDomain);
  XCTAssertEqual(error.code, DSHLocalWorkspaceAccessErrorUnavailable);
  XCTAssertFalse([error.localizedDescription containsString:self.privateRoot.path]);
}

- (void)testLegacyWorkspaceLookupReturnsSafeAttachedProjectWithoutLeak {
  NSDictionary *fixture = [self installLegacyLookupFixture];
  NSURL *splitRoot = [[self.privateRoot
      URLByAppendingPathComponent:@"workspace-gitdirs" isDirectory:YES]
      URLByAppendingPathComponent:self.root[@"workspace_id"] isDirectory:YES];
  XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:splitRoot.path]);
  NSError *error = nil;
  NSDictionary *result = [self.module v2ProjectForWorkspace:self.root
                                                       error:&error];
  XCTAssertNotNil(result, @"%@", error);
  XCTAssertEqualObjects(result[@"status"], @"attached");
  NSDictionary *project = result[@"project"];
  NSSet *expectedProjectKeys = [NSSet setWithArray:@[
    @"schema_version", @"project_id", @"workspace_id",
    @"workspace_binding_revision", @"display_name", @"git_topology"
  ]];
  XCTAssertEqualObjects([NSSet setWithArray:project.allKeys],
                        expectedProjectKeys);
  XCTAssertEqualObjects(project[@"project_id"], fixture[@"project_id"]);
  XCTAssertEqualObjects(project[@"workspace_id"], self.root[@"workspace_id"]);
  XCTAssertEqualObjects(project[@"workspace_binding_revision"], @1);
  XCTAssertEqualObjects(project[@"display_name"], @"Legacy Lookup");
  XCTAssertEqualObjects(project[@"git_topology"], @"legacy_embedded");
  for (NSString *forbidden in @[@"path", @"url", @"metadata_sha256",
                                 @"descriptor", @"root_fingerprint_sha256"]) {
    XCTAssertNil(project[forbidden]);
  }
  XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:splitRoot.path]);
}

- (void)testLegacyWorkspaceLookupWrongRevisionIsStableConflict {
  [self installLegacyLookupFixture];
  NSMutableDictionary *wrongRevision = [self.root mutableCopy];
  wrongRevision[@"binding_revision"] = @2;
  NSError *error = nil;
  XCTAssertNil([self.module v2ProjectForWorkspace:wrongRevision error:&error]);
  XCTAssertEqualObjects(error.domain, @"LocalProjects");
  XCTAssertEqual(error.code, 3110);
}

- (void)testLegacyWorkspaceLookupIdentityDriftIsStableConflict {
  NSDictionary *fixture = [self installLegacyLookupFixture];
  NSURL *metadataURL = [fixture[@"project_root"]
      URLByAppendingPathComponent:@"project.json"];
  NSMutableDictionary *metadata = [[NSJSONSerialization JSONObjectWithData:
      [NSData dataWithContentsOfURL:metadataURL] options:0 error:nil]
      mutableCopy];
  metadata[@"name"] = @"Drifted Legacy Lookup";
  XCTAssertTrue([[NSJSONSerialization dataWithJSONObject:metadata options:0
                                                   error:nil]
      writeToURL:metadataURL atomically:YES]);
  NSError *error = nil;
  XCTAssertNil([self.module v2ProjectForWorkspace:self.root error:&error]);
  XCTAssertEqualObjects(error.domain, @"LocalProjects");
  XCTAssertEqual(error.code, 3110);
}

- (void)testOrdinaryWorkspaceWithoutSplitBindingRemainsNone {
  NSError *error = nil;
  NSDictionary *result = [self.module v2ProjectForWorkspace:self.root
                                                       error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result,
      (@{ @"schema_version" : @1, @"status" : @"none" }));
}

- (void)testRealAttachPublishesOnlyAfterProductionProjectLeaseVerification {
  NSError *error = nil;
  NSDictionary *result = [self attachWithRoot:self.root error:&error];
  XCTAssertNotNil(result, @"%@", error);
  XCTAssertEqualObjects(result[@"status"], @"attached");
  NSString *projectId = result[@"project"][@"project_id"];
  XCTAssertTrue([DSHLocalProjectAccess isCanonicalProjectId:projectId]);
  NSDictionary *projectRoot = @{
    @"schema_version" : @1,
    @"workspace_id" : self.root[@"workspace_id"],
    @"binding_revision" : self.root[@"binding_revision"],
    @"project_id" : projectId,
  };
  DSHLocalProjectLease *lease = [self.projectAccess
      leaseWorkspaceRootRef:projectRoot
                       mode:DSHLocalProjectAccessModeRead
            includeMetadata:YES
                    timeout:1
                      error:&error];
  XCTAssertNotNil(lease, @"%@", error);
  XCTAssertTrue([self.projectAccess validateWorkspaceLeaseIdentity:lease
                                                           rootRef:projectRoot
                                                             error:&error], @"%@", error);
}

- (void)testEnableGitPreservesExistingWorkspaceFilesAndPublishesNativeGitPolicy {
  NSURL *workspaceRoot = [[self.documentsRoot
      URLByAppendingPathComponent:@"Rish Workspaces" isDirectory:YES]
      URLByAppendingPathComponent:@"Attach Fixture" isDirectory:YES];
  NSURL *file = [workspaceRoot URLByAppendingPathComponent:@"demo.txt"];
  NSData *originalBytes = [@"Existing demo file.\n保留原文件。\n"
      dataUsingEncoding:NSUTF8StringEncoding];
  NSError *error = nil;
  XCTAssertTrue([originalBytes writeToURL:file options:NSDataWritingAtomic error:&error], @"%@", error);
  struct stat originalRoot = {};
  struct stat originalFile = {};
  XCTAssertEqual(stat(workspaceRoot.fileSystemRepresentation, &originalRoot), 0);
  XCTAssertEqual(stat(file.fileSystemRepresentation, &originalFile), 0);
  NSDictionary *before = [self.module v2ProjectForWorkspace:self.root error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(before[@"status"], @"none");

  // The real producer creates a private split gitdir and points its worktree
  // at the existing root. No mocked project/storage layer participates.
  NSDictionary *attached = [self attachWithRoot:self.root error:&error];
  XCTAssertNil(error, @"%@", error);
  XCTAssertEqualObjects(attached[@"status"], @"attached");
  if (attached == nil) return;
  NSString *projectId = attached[@"project"][@"project_id"];
  XCTAssertTrue([DSHLocalProjectAccess isCanonicalProjectId:projectId]);
  XCTAssertEqualObjects(attached[@"project"][@"workspace_id"], self.root[@"workspace_id"]);
  XCTAssertEqualObjects(attached[@"project"][@"workspace_binding_revision"], self.root[@"binding_revision"]);
  XCTAssertEqualObjects(attached[@"project"][@"git_topology"], @"private_split_gitdir");
  XCTAssertEqualObjects([NSData dataWithContentsOfURL:file], originalBytes);
  struct stat currentRoot = {};
  struct stat currentFile = {};
  XCTAssertEqual(stat(workspaceRoot.fileSystemRepresentation, &currentRoot), 0);
  XCTAssertEqual(stat(file.fileSystemRepresentation, &currentFile), 0);
  XCTAssertEqual(currentRoot.st_dev, originalRoot.st_dev);
  XCTAssertEqual(currentRoot.st_ino, originalRoot.st_ino);
  XCTAssertEqual(currentFile.st_dev, originalFile.st_dev);
  XCTAssertEqual(currentFile.st_ino, originalFile.st_ino);
  XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:
      [workspaceRoot URLByAppendingPathComponent:@".git"].path]);

  NSDictionary *lookup = [self.module v2ProjectForWorkspace:self.root error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(lookup[@"status"], @"attached");
  XCTAssertEqualObjects(lookup[@"project"][@"project_id"], projectId);
  NSDictionary *projectRoot = @{
    @"schema_version" : @1, @"workspace_id" : self.root[@"workspace_id"],
    @"binding_revision" : self.root[@"binding_revision"], @"project_id" : projectId,
  };
  __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *lease = [self.projectAccess
      leaseWorkspaceRootRef:projectRoot mode:DSHLocalProjectAccessModeRead
      includeMetadata:YES timeout:1 error:&error];
  XCTAssertNotNil(lease, @"%@", error);
  if (lease == nil) return;
  XCTAssertTrue([self.projectAccess validateWorkspaceLeaseIdentity:lease rootRef:projectRoot error:&error]);
  unsigned int fileStatus = GIT_STATUS_CURRENT;
  XCTAssertEqual(git_status_file(&fileStatus, lease.repository, "demo.txt"), 0);
  XCTAssertEqual(fileStatus, (unsigned int)GIT_STATUS_WT_NEW);
  // Policy resolves its own fresh production lease; do not retain the first
  // project lock across the second independently verified query.
  lease = nil;

  DSHAgentRootResolver *resolver = [[DSHAgentRootResolver alloc]
      initWithWorkspaceAccess:self.workspaceAccess projectAccess:self.projectAccess];
  NSDictionary *nativeRoot = [resolver resolveRootForWorkspaceId:self.root[@"workspace_id"]
      projectId:projectId bindingRevision:self.root[@"binding_revision"] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(nativeRoot[@"kind"], @"project");
  DSHAgentPolicyService *policy = [[DSHAgentPolicyService alloc]
      initWithRootResolver:resolver registry:[[DSHAgentToolRegistry alloc] init]
      coordinator:DSHSessionWorkspaceCoordinator.sharedCoordinator];
  NSDictionary *described = [policy describeRequest:@{
    @"schema_version" : @1, @"workspace_id" : self.root[@"workspace_id"],
    @"workspace_binding_revision" : self.root[@"binding_revision"], @"project_id" : projectId,
  } error:&error];
  XCTAssertNotNil(described, @"%@", error);
  XCTAssertNil(error);
  XCTAssertEqualObjects(described[@"workspace_id"], self.root[@"workspace_id"]);
  XCTAssertEqualObjects(described[@"project_id"], projectId);
  NSMutableDictionary *access = [NSMutableDictionary dictionary];
  for (NSDictionary *tool in described[@"tools"]) access[tool[@"name"]] = tool[@"access"];
  XCTAssertEqualObjects(access[@"git_status"], @"auto");
  XCTAssertEqualObjects(access[@"git_commit"], @"conversation_confirm");
  XCTAssertEqualObjects(access[@"git_push"], @"conversation_confirm");
  for (NSString *capability in @[@"git_status", @"git_commit", @"git_push"]) {
    XCTAssertTrue([described[@"capabilities"] containsObject:capability]);
  }
  // A second explicit enable from an older projectless chat finds the same
  // native project instead of creating a second repository or moving files.
  NSDictionary *again = [self.module v2AttachWorkspaceProject:@{
    @"schema_version" : @1, @"operation_id" : @"44444444-4444-4444-8444-444444444444",
    @"root" : self.root, @"mode" : @"init",
  } error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(again[@"status"], @"already_attached");
  XCTAssertEqualObjects(again[@"project"][@"project_id"], projectId);
  XCTAssertEqualObjects([NSData dataWithContentsOfURL:file], originalBytes);
}

- (void)testAttachRejectsWrongRevisionAndRelationWithoutPublication {
  NSError *error = nil;
  NSDictionary *wrongRevision = @{
    @"schema_version" : @1,
    @"workspace_id" : self.root[@"workspace_id"],
    @"binding_revision" : @2,
    @"project_id" : [NSNull null],
  };
  XCTAssertNil([self attachWithRoot:wrongRevision error:&error]);
  XCTAssertNotNil(error);
  error = nil;
  NSDictionary *wrongRelation = @{
    @"schema_version" : @1,
    @"workspace_id" : @"44444444-4444-4444-8444-444444444444",
    @"binding_revision" : @1,
    @"project_id" : [NSNull null],
  };
  XCTAssertNil([self attachWithRoot:wrongRelation error:&error]);
  XCTAssertNotNil(error);
}

- (void)testDocumentsRootPublishesAllNativeCapabilities {
  NSError *error = nil;
  NSDictionary *resolved = [self.workspaceAccess
      resolveWorkspaceId:self.root[@"workspace_id"]
      expectedBindingRevision:self.root[@"binding_revision"]
      requiredCapabilities:@[] error:&error];
  XCTAssertNotNil(resolved, @"%@", error);
  NSDictionary *capabilities = resolved[@"workspace"][@"capabilities"];
  XCTAssertEqualObjects(capabilities[@"read"], @YES);
  XCTAssertEqualObjects(capabilities[@"write"], @YES);
  XCTAssertEqualObjects(capabilities[@"git"], @YES);
  XCTAssertEqualObjects(capabilities[@"project_context"], @YES);
}

- (void)testSecurityScopedCapabilitiesStayReadWriteOnly {
  NSSet<NSString *> *securityScoped = [self.workspaceAccess
      operationalCapabilitiesForMetadataRecord:@{
        @"root_locator_kind" : @"security_scoped"
      }
                                    authority:@{}
                                       status:@"ok"];
  NSSet<NSString *> *expectedSecurityScoped =
      [NSSet setWithObjects:@"read", @"write", nil];
  XCTAssertEqualObjects(securityScoped, expectedSecurityScoped);
  NSSet<NSString *> *documents = [self.workspaceAccess
      operationalCapabilitiesForMetadataRecord:@{
        @"root_locator_kind" : @"documents_owned"
      }
                                    authority:@{}
                                       status:@"ok"];
  NSSet<NSString *> *expectedDocuments = [NSSet setWithObjects:
      @"read", @"write", @"git", @"project_context", nil];
  XCTAssertEqualObjects(documents, expectedDocuments);
}

- (void)testAttachFaultMatrixCleansEveryOwnedPhaseAndCanRetry {
  for (NSString *faultStage in @[
    @"after_attach_journal", @"after_attach_staging",
    @"after_attach_preflight", @"after_attach_publish",
    @"after_attach_terminal_validation"
  ]) {
    [self.module setValue:^BOOL(NSString *stage) {
      return [stage isEqualToString:faultStage];
    } forKey:@"v2AttachFaultHook"];
    NSError *error = nil;
    XCTAssertNil([self attachWithRoot:self.root error:&error], @"%@", faultStage);
    XCTAssertNotNil(error, @"%@", faultStage);
    [self.module setValue:nil forKey:@"v2AttachFaultHook"];
    error = nil;
    XCTAssertTrue([self.module
        v2ReconcileAttachStagingForWorkspaceId:self.root[@"workspace_id"]
                                          error:&error], @"%@ %@", faultStage, error);
    XCTAssertEqual(self.attachPendingEntries.count, (NSUInteger)0,
                   @"%@", faultStage);
  }
  NSError *error = nil;
  XCTAssertNotNil([self attachWithRoot:self.root error:&error], @"%@", error);
}

- (void)testStagingCreateFailureDurablyRemovesPreparedJournal {
  [self.module setValue:^BOOL(NSString *stage) {
    return [stage isEqualToString:@"attach_staging_create"];
  } forKey:@"v2AttachFaultHook"];
  NSError *error = nil;
  XCTAssertNil([self attachWithRoot:self.root error:&error]);
  XCTAssertNotNil(error);
  XCTAssertEqual(self.attachPendingEntries.count, (NSUInteger)0);
}

- (void)testEnumerationFailureStopsAttachBeforeMutation {
  [self.module setValue:^BOOL(NSString *stage) {
    return [stage isEqualToString:@"attach_reconcile_enumeration"];
  } forKey:@"v2AttachFaultHook"];
  NSError *error = nil;
  XCTAssertNil([self attachWithRoot:self.root error:&error]);
  XCTAssertNotNil(error);
  [self.module setValue:nil forKey:@"v2AttachFaultHook"];
  XCTAssertEqual(self.attachPendingEntries.count, (NSUInteger)0);
}

- (void)testCleanupFailureIsRecoveredByRestartBeforeRetry {
  [self.module setValue:^BOOL(NSString *stage) {
    return [stage isEqualToString:@"after_attach_journal"] ||
        [stage isEqualToString:@"attach_cleanup"];
  } forKey:@"v2AttachFaultHook"];
  NSError *error = nil;
  XCTAssertNil([self attachWithRoot:self.root error:&error]);
  XCTAssertNotNil(error);
  XCTAssertGreaterThan(self.attachPendingEntries.count, (NSUInteger)0);
  [self.module setValue:nil forKey:@"v2AttachFaultHook"];
  LocalProjectsModule *restarted = [self restartedModule];
  error = nil;
  XCTAssertTrue([restarted
      v2ReconcileAttachStagingForWorkspaceId:self.root[@"workspace_id"]
                                        error:&error], @"%@", error);
  XCTAssertEqual(self.attachPendingEntries.count, (NSUInteger)0);
  self.module = restarted;
  XCTAssertNotNil([self attachWithRoot:self.root error:&error], @"%@", error);
}

- (void)testPublishedCleanupFailureRestartPreservesVerifiedAttachment {
  [self.module setValue:^BOOL(NSString *stage) {
    return [stage isEqualToString:@"after_attach_publish"] ||
        [stage isEqualToString:@"attach_cleanup"];
  } forKey:@"v2AttachFaultHook"];
  NSError *error = nil;
  XCTAssertNil([self attachWithRoot:self.root error:&error]);
  XCTAssertNotNil(error);
  XCTAssertGreaterThan(self.attachPendingEntries.count, (NSUInteger)0);
  [self.module setValue:nil forKey:@"v2AttachFaultHook"];
  LocalProjectsModule *restarted = [self restartedModule];
  error = nil;
  XCTAssertTrue([restarted
      v2ReconcileAttachStagingForWorkspaceId:self.root[@"workspace_id"]
                                        error:&error], @"%@", error);
  XCTAssertEqual(self.attachPendingEntries.count, (NSUInteger)0);
  self.module = restarted;
  NSDictionary *result = [self attachWithRoot:self.root error:&error];
  XCTAssertNotNil(result, @"%@", error);
  XCTAssertEqualObjects(result[@"status"], @"already_attached");
}

- (void)testMalformedRestartJournalFailsClosed {
  XCTAssertTrue([NSFileManager.defaultManager
      createDirectoryAtURL:self.workspaceGitRoot
      withIntermediateDirectories:YES attributes:nil error:nil]);
  NSURL *journal = [self.workspaceGitRoot URLByAppendingPathComponent:
      @".rish-attach-78787878-7878-4787-8787-787878787878.journal"];
  XCTAssertTrue([[NSData dataWithBytes:"{}" length:2]
      writeToURL:journal options:NSDataWritingAtomic error:nil]);
  LocalProjectsModule *restarted = [self restartedModule];
  NSError *error = nil;
  XCTAssertFalse([restarted
      v2ReconcileAttachStagingForWorkspaceId:self.root[@"workspace_id"]
                                        error:&error]);
  XCTAssertNotNil(error);
  XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:journal.path]);
}

- (void)testExclusivePublishDoesNotOverwriteRenameCollision {
  __block NSURL *collision = nil;
  __block NSURL *marker = nil;
  NSString *operationId = @"33333333-3333-4333-8333-333333333333";
  NSURL *workspaceGitRoot = self.workspaceGitRoot;
  [self.module setValue:^BOOL(NSString *stage) {
    if (![stage isEqualToString:@"after_attach_preflight"] || collision != nil) {
      return NO;
    }
    NSURL *journalURL = [workspaceGitRoot URLByAppendingPathComponent:
        [NSString stringWithFormat:@".rish-attach-%@.journal", operationId]];
    NSDictionary *journal = [NSJSONSerialization JSONObjectWithData:
        [NSData dataWithContentsOfURL:journalURL] options:0 error:nil];
    collision = [workspaceGitRoot
        URLByAppendingPathComponent:journal[@"final_name"] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:collision
        withIntermediateDirectories:NO attributes:nil error:nil];
    marker = [collision URLByAppendingPathComponent:@"collision-marker"];
    [[NSData dataWithBytes:"keep" length:4] writeToURL:marker atomically:YES];
    return NO;
  } forKey:@"v2AttachFaultHook"];
  NSError *error = nil;
  XCTAssertNil([self attachWithRoot:self.root error:&error]);
  XCTAssertNotNil(error);
  XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:marker.path]);
  XCTAssertEqual(self.attachPendingEntries.count, (NSUInteger)0);
}

- (NSDictionary *)attachProjectRoot:(NSError **)error {
  NSDictionary *result = [self attachWithRoot:self.root error:error];
  NSString *projectId = result[@"project"][@"project_id"];
  return projectId == nil ? nil : @{
    @"schema_version" : @1,
    @"workspace_id" : self.root[@"workspace_id"],
    @"binding_revision" : self.root[@"binding_revision"],
    @"project_id" : projectId,
  };
}

- (void)testRootBindingAndGitDirectoryReplacementFailClosed {
  NSError *error = nil;
  NSDictionary *projectRoot = [self attachProjectRoot:&error];
  XCTAssertNotNil(projectRoot, @"%@", error);
  NSString *projectId = projectRoot[@"project_id"];
  NSURL *gitURL = [[[[self.privateRoot
      URLByAppendingPathComponent:@"workspace-gitdirs" isDirectory:YES]
      URLByAppendingPathComponent:self.root[@"workspace_id"] isDirectory:YES]
      URLByAppendingPathComponent:projectId isDirectory:YES] URLByStandardizingPath];
  NSURL *bindingURL = [gitURL URLByAppendingPathComponent:@"binding-v2.json"];
  NSMutableDictionary *binding = [[NSJSONSerialization
      JSONObjectWithData:[NSData dataWithContentsOfURL:bindingURL]
                 options:0 error:nil] mutableCopy];
  binding[@"project_id"] = @"44444444-4444-4444-8444-444444444444";
  XCTAssertTrue([[NSJSONSerialization dataWithJSONObject:binding options:0 error:nil]
      writeToURL:bindingURL atomically:YES]);
  XCTAssertNil([self.projectAccess leaseWorkspaceRootRef:projectRoot
                                                    mode:DSHLocalProjectAccessModeRead
                                         includeMetadata:YES timeout:1 error:&error]);
  XCTAssertNotNil(error);
}

- (void)testAlreadyAttachedRevalidatesTheProductionProjectLease {
  NSError *error = nil;
  NSDictionary *first = [self attachWithRoot:self.root error:&error];
  XCTAssertNotNil(first, @"%@", error);
  NSURL *workspaceRoot = [[self.documentsRoot
      URLByAppendingPathComponent:@"Rish Workspaces" isDirectory:YES]
      URLByAppendingPathComponent:@"Attach Fixture" isDirectory:YES];
  NSURL *replacement = [workspaceRoot.URLByDeletingLastPathComponent
      URLByAppendingPathComponent:@"Attach Fixture.old" isDirectory:YES];
  XCTAssertTrue(rename(workspaceRoot.fileSystemRepresentation,
                       replacement.fileSystemRepresentation) == 0);
  XCTAssertTrue(mkdir(workspaceRoot.fileSystemRepresentation, 0700) == 0);
  error = nil;
  XCTAssertNil([self attachWithRoot:self.root error:&error]);
  XCTAssertNotNil(error);
}

- (void)testSSHCloneFetchAndRestartWithHostKeyVerification {
  NSString *keyPath = NSProcessInfo.processInfo.environment[@"RISH_SSH_TEST_KEY_PATH"];
  NSString *knownHostsPath = NSProcessInfo.processInfo.environment[@"RISH_SSH_TEST_KNOWN_HOSTS_PATH"];
  if (keyPath.length == 0 || knownHostsPath.length == 0) {
    XCTSkip(@"set RISH_SSH_TEST_KEY_PATH and RISH_SSH_TEST_KNOWN_HOSTS_PATH for the authorized SSH proof");
  }
  NSData *keyData = [NSData dataWithContentsOfFile:keyPath options:NSDataReadingMappedIfSafe error:nil];
  NSData *knownHostsData = [NSData dataWithContentsOfFile:knownHostsPath options:NSDataReadingMappedIfSafe error:nil];
  NSString *privateKey = [[NSString alloc] initWithData:keyData encoding:NSUTF8StringEncoding];
  NSString *knownHosts = [[NSString alloc] initWithData:knownHostsData encoding:NSUTF8StringEncoding];
  keyData = nil;
  knownHostsData = nil;
  XCTAssertNotNil(privateKey);
  XCTAssertNotNil(knownHosts);
  NSError *error = nil;
  XCTAssertTrue(DSHGitSSHPrivateKeyIsSupported(privateKey, &error), @"key_error=%ld", (long)error.code);
  NSString *profileId = NSProcessInfo.processInfo.environment[@"RISH_SSH_TEST_PROFILE_ID"];
  if (profileId.length == 0)
    profileId = [NSString stringWithFormat:@"ssh-test-%@", NSUUID.UUID.UUIDString.lowercaseString];
  BOOL preserveProfile = NSProcessInfo.processInfo.environment[@"RISH_SSH_PRESERVE_PROFILE"] != nil;
  XCTAssertTrue(DSHGitSSHStoreCredentialForProfile(profileId, @"ssh.github.com", 443, @"git",
      privateKey, nil, nil, knownHosts, &error), @"store_error=%ld", (long)error.code);
  privateKey = nil;
  knownHosts = nil;

  NSURL *legacyRoot = [NSURL fileURLWithPath:
      [NSTemporaryDirectory() stringByAppendingPathComponent:
          [NSString stringWithFormat:@"rish-ssh-projects-%@", NSUUID.UUID.UUIDString.lowercaseString]]
      isDirectory:YES];
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:legacyRoot
      withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions : @0700} error:&error]);
  DSHLocalProjectAccess *legacyAccess = [[DSHLocalProjectAccess alloc]
      initWithProjectsRootURL:legacyRoot hook:nil];
  Class moduleClass = NSClassFromString(@"LocalProjectsModule");
  XCTAssertNotNil(moduleClass);
  LocalProjectsModule *module = [[moduleClass alloc]
      initWithSupportURL:legacyRoot projectAccess:legacyAccess];
  NSURL *remoteURL = [NSURL URLWithString:
      @"ssh://git@ssh.github.com:443/ZSeven-W/rish-app.git"];
  NSLog(@"ssh-proof clone_started");
  NSDictionary *metadata = nil;
  @autoreleasepool {
    metadata = [[module clonePublicRepositoryAtURL:remoteURL
        name:@"ssh-proof" proxyURL:nil operation:nil sshProfileId:profileId error:&error] copy];
  }
  NSLog(@"ssh-proof clone_returned metadata=%@", metadata != nil ? @"yes" : @"no");
  XCTAssertNotNil(metadata, @"clone_error=%ld", (long)error.code);
  NSString *projectId = metadata[@"id"];
  XCTAssertNotNil(projectId);
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  __block BOOL fetched = NO;
  NSLog(@"ssh-proof fetch_started");
  [module fetchForProject:projectId sshProfileId:profileId
      resolver:^(__unused id result) { fetched = YES; NSLog(@"ssh-proof fetch_returned ok"); dispatch_semaphore_signal(done); }
      rejecter:^(__unused NSString *code, __unused NSString *message, __unused NSError *fetchError) {
        NSLog(@"ssh-proof fetch_returned error");
        dispatch_semaphore_signal(done);
      }];
  XCTAssertEqual(dispatch_semaphore_wait(done,
      dispatch_time(DISPATCH_TIME_NOW, 180 * NSEC_PER_SEC)), 0);
  XCTAssertTrue(fetched);
  LocalProjectsModule *restarted = [[moduleClass alloc]
      initWithSupportURL:legacyRoot projectAccess:legacyAccess];
  [restarted setValue:legacyAccess forKey:@"projectAccess"];
  DSHLocalProjectLease *lease = [legacyAccess leaseProjectId:projectId
      mode:DSHLocalProjectAccessModeRead includeMetadata:YES error:&error];
  XCTAssertNotNil(lease);
  XCTAssertNotNil(restarted);
  dispatch_semaphore_t listedDone = dispatch_semaphore_create(0);
  __block BOOL listed = NO;
  [restarted listWithResolver:^(id result) {
    NSArray *projects = [result isKindOfClass:NSDictionary.class] ? result[@"projects"] : nil;
    listed = [projects isKindOfClass:NSArray.class] &&
        [projects indexOfObjectPassingTest:^BOOL(NSDictionary *project, __unused NSUInteger index, __unused BOOL *stop) {
          return [project isKindOfClass:NSDictionary.class] && [project[@"id"] isEqual:projectId];
        }] != NSNotFound;
    dispatch_semaphore_signal(listedDone);
  } rejecter:^(__unused NSString *code, __unused NSString *message, __unused NSError *listError) {
    dispatch_semaphore_signal(listedDone);
  }];
  XCTAssertEqual(dispatch_semaphore_wait(listedDone,
      dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)), 0);
  XCTAssertTrue(listed);
  NSLog(@"ssh-proof reopen_checked listed=%@", listed ? @"yes" : @"no");
  if (!preserveProfile)
    (void)DSHGitSSHDeleteCredentialForProfile(profileId, @"ssh.github.com", 443, @"git", nil);
  [NSFileManager.defaultManager removeItemAtURL:legacyRoot error:nil];
}

- (void)testSSHRejectsWrongKeyAndUnknownHostWithoutFallback {
  NSString *keyPath = NSProcessInfo.processInfo.environment[@"RISH_SSH_TEST_KEY_PATH"];
  NSString *knownHostsPath = NSProcessInfo.processInfo.environment[@"RISH_SSH_TEST_KNOWN_HOSTS_PATH"];
  if (keyPath.length == 0 || knownHostsPath.length == 0) {
    XCTSkip(@"set RISH_SSH_TEST_KEY_PATH and RISH_SSH_TEST_KNOWN_HOSTS_PATH for the authorized SSH proof");
  }
  NSString *privateKey = [[NSString alloc] initWithData:
      [NSData dataWithContentsOfFile:keyPath options:NSDataReadingMappedIfSafe error:nil]
      encoding:NSUTF8StringEncoding];
  NSString *knownHosts = [[NSString alloc] initWithData:
      [NSData dataWithContentsOfFile:knownHostsPath options:NSDataReadingMappedIfSafe error:nil]
      encoding:NSUTF8StringEncoding];
  XCTAssertNotNil(privateKey);
  XCTAssertNotNil(knownHosts);
  NSRange begin = [privateKey rangeOfString:@"-----BEGIN OPENSSH PRIVATE KEY-----"];
  NSUInteger mutate = begin.location == NSNotFound ? NSNotFound : begin.location + begin.length;
  while (mutate != NSNotFound && mutate < privateKey.length &&
         [[NSCharacterSet whitespaceAndNewlineCharacterSet]
             characterIsMember:[privateKey characterAtIndex:mutate]]) mutate += 1;
  XCTAssertNotEqual(mutate, (NSUInteger)NSNotFound);
  NSString *wrongKey = [privateKey stringByReplacingCharactersInRange:NSMakeRange(mutate, 1)
                                                              withString:@"A"];
  NSString *profileId = [NSString stringWithFormat:@"ssh-negative-%@", NSUUID.UUID.UUIDString.lowercaseString];
  NSError *error = nil;
  XCTAssertFalse(DSHGitSSHStoreCredentialForProfile(profileId, @"ssh.github.com", 443, @"git",
      wrongKey, nil, nil, knownHosts, &error));
  NSURL *root = [NSURL fileURLWithPath:
      [NSTemporaryDirectory() stringByAppendingPathComponent:
          [NSString stringWithFormat:@"rish-ssh-negative-%@", NSUUID.UUID.UUIDString.lowercaseString]]
      isDirectory:YES];
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:root
      withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions : @0700} error:&error]);
  (void)DSHGitSSHDeleteCredentialForProfile(profileId, @"ssh.github.com", 443, @"git", nil);

  NSMutableArray<NSString *> *withoutTarget = [NSMutableArray array];
  for (NSString *line in [knownHosts componentsSeparatedByCharactersInSet:
      NSCharacterSet.newlineCharacterSet]) {
    if (![line hasPrefix:@"[ssh.github.com]:443"]) [withoutTarget addObject:line];
  }
  NSString *unknownHosts = [withoutTarget componentsJoinedByString:@"\n"];
  NSString *unknownProfile = [NSString stringWithFormat:@"ssh-negative-host-%@", NSUUID.UUID.UUIDString.lowercaseString];
  XCTAssertTrue(DSHGitSSHStoreCredentialForProfile(unknownProfile, @"ssh.github.com", 443, @"git",
      privateKey, nil, nil, unknownHosts, &error));
  DSHLocalProjectAccess *access = [[DSHLocalProjectAccess alloc] initWithProjectsRootURL:root hook:nil];
  Class moduleClass = NSClassFromString(@"LocalProjectsModule");
  LocalProjectsModule *module = [[moduleClass alloc] initWithSupportURL:root projectAccess:access];
  NSURL *remoteURL = [NSURL URLWithString:@"ssh://git@ssh.github.com:443/ZSeven-W/rish-app.git"];
  NSDictionary *unknownHostProject = [module clonePublicRepositoryAtURL:remoteURL name:@"ssh-negative-host"
      proxyURL:nil operation:nil sshProfileId:unknownProfile error:&error];
  XCTAssertNil(unknownHostProject);
  (void)DSHGitSSHDeleteCredentialForProfile(unknownProfile, @"ssh.github.com", 443, @"git", nil);
  [NSFileManager.defaultManager removeItemAtURL:root error:nil];
}

- (void)testSSHCloneIntoNormalProjectRegistryForAuthorizedProfile {
  NSString *keyPath = NSProcessInfo.processInfo.environment[@"RISH_SSH_TEST_KEY_PATH"];
  NSString *knownHostsPath = NSProcessInfo.processInfo.environment[@"RISH_SSH_TEST_KNOWN_HOSTS_PATH"];
  if (keyPath.length == 0 || knownHostsPath.length == 0) {
    XCTSkip(@"set RISH_SSH_TEST_KEY_PATH and RISH_SSH_TEST_KNOWN_HOSTS_PATH for the authorized SSH proof");
  }
  NSString *privateKey = [[NSString alloc] initWithData:
      [NSData dataWithContentsOfFile:keyPath options:NSDataReadingMappedIfSafe error:nil]
      encoding:NSUTF8StringEncoding];
  NSString *knownHosts = [[NSString alloc] initWithData:
      [NSData dataWithContentsOfFile:knownHostsPath options:NSDataReadingMappedIfSafe error:nil]
      encoding:NSUTF8StringEncoding];
  NSString *profileId = @"rish-ssh-git@ssh.github.com-443";
  NSError *error = nil;
  XCTAssertTrue(DSHGitSSHStoreCredentialForProfile(profileId, @"ssh.github.com", 443, @"git",
      privateKey, nil, nil, knownHosts, &error));
  privateKey = nil;
  knownHosts = nil;
  Class moduleClass = NSClassFromString(@"LocalProjectsModule");
  LocalProjectsModule *module = [[moduleClass alloc] init];
  NSURL *remoteURL = [NSURL URLWithString:@"ssh://git@ssh.github.com:443/ZSeven-W/rish-app.git"];
  NSDictionary *metadata = [module clonePublicRepositoryAtURL:remoteURL
      name:@"SSH-Proof-20260909" proxyURL:nil operation:nil sshProfileId:profileId error:&error];
  XCTAssertNotNil(metadata, @"clone_error=%ld", (long)error.code);
  XCTAssertNotNil(metadata[@"id"]);
  XCTAssertEqualObjects(metadata[@"name"], @"SSH-Proof-20260909");
}

@end
