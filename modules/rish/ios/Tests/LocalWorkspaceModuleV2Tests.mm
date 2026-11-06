#import <XCTest/XCTest.h>
#import <RishNative/RishNativeModule.h>
#import "DSHTestStorageFixture.h"

#import "../../../../modules/rish/ios/Sources/LocalProjectAccess.h"
#import "../../../../modules/rish/ios/Sources/LocalWorkspaceAccess.h"

#include <git2.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

@interface LocalWorkspaceModule : NSObject
@end

@interface LocalDocumentsModule : NSObject
- (instancetype)initWithSupportURL:(NSURL *)support legacyProjectAccess:(DSHLocalProjectAccess *)legacyAccess;
- (BOOL)performRoot:(NSDictionary *)root capabilities:(NSSet<NSString *> *)capabilities
  block:(BOOL (^)(int, NSError **))block error:(NSError **)error;
@end

@interface LocalWorkspaceModule (FilesV2Testing)
- (instancetype)initWithSupportURL:(NSURL *)support legacyProjectAccess:(DSHLocalProjectAccess *)legacyAccess;
- (void)capabilitiesWithResolver:(RishResolveBlock)resolve
                        rejecter:(RishRejectBlock)reject;
- (void)listV2Request:(id)request
             resolver:(RishResolveBlock)resolve
             rejecter:(RishRejectBlock)reject;
- (void)readV2Request:(id)request
             resolver:(RishResolveBlock)resolve
             rejecter:(RishRejectBlock)reject;
- (void)writeV2Request:(id)request
              resolver:(RishResolveBlock)resolve
              rejecter:(RishRejectBlock)reject;
- (void)renameEntryV2Request:(id)request
                    resolver:(RishResolveBlock)resolve
                    rejecter:(RishRejectBlock)reject;
- (void)trashEntryV2Request:(id)request
                   resolver:(RishResolveBlock)resolve
                   rejecter:(RishRejectBlock)reject;
- (void)listTrashV2Request:(id)request
                  resolver:(RishResolveBlock)resolve
                  rejecter:(RishRejectBlock)reject;
- (void)restoreFromTrashV2Request:(id)request
                          resolver:(RishResolveBlock)resolve
                          rejecter:(RishRejectBlock)reject;
@end

@interface LocalWorkspaceModuleV2Tests : XCTestCase
@property(nonatomic, strong) NSURL *privateRoot;
@property(nonatomic, strong) NSURL *documentsRoot;
@property(nonatomic, strong) DSHLocalWorkspaceAccess *access;
@property(nonatomic, strong) DSHLocalProjectAccess *projectAccess;
@property(nonatomic, strong) LocalWorkspaceModule *module;
@property(nonatomic, copy) NSDictionary *root;
@property(nonatomic, copy) NSDictionary *projectRoot;
@property(nonatomic, strong) NSURL *projectGitURL;
- (DSHLocalProjectAccess *)projectAccessWithBindingProjectId:(NSString *)bindingProjectId
                                               driftOnResolve:(NSUInteger)driftOnResolve;
@end

@implementation LocalWorkspaceModuleV2Tests

- (void)setUp {
  [super setUp];
  NSString *suffix = NSUUID.UUID.UUIDString.lowercaseString;
  self.privateRoot = [NSURL fileURLWithPath:
      [NSTemporaryDirectory() stringByAppendingPathComponent:
          [NSString stringWithFormat:@"rish-files-v2-private-%@", suffix]]
                                           isDirectory:YES];
  self.documentsRoot = [NSURL fileURLWithPath:
      [NSTemporaryDirectory() stringByAppendingPathComponent:
          [NSString stringWithFormat:@"rish-files-v2-documents-%@", suffix]]
                                             isDirectory:YES];
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:self.privateRoot
                                         withIntermediateDirectories:YES
                                                          attributes:nil
                                                               error:nil]);
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:self.documentsRoot
                                         withIntermediateDirectories:YES
                                                          attributes:nil
                                                               error:nil]);
  self.access = [[DSHLocalWorkspaceAccess alloc]
      initWithPrivateRootURL:self.privateRoot
           documentsRootURL:self.documentsRoot
                        clock:^NSDate *{ return NSDate.date; }
                UUIDGenerator:^NSString *{
                  return @"11111111-1111-4111-8111-111111111111";
                }
                legacyResolver:^BOOL(NSString *projectId,
                                     NSDictionary **evidence,
                                     NSError **error) {
                  (void)projectId;
                  if (evidence != nil) *evidence = nil;
                  if (error != nil) *error = [NSError errorWithDomain:@"test"
                                                                    code:1
                                                                userInfo:nil];
                  return NO;
                }
                      faultHook:nil];
  NSError *error = nil;
  XCTAssertTrue([self.access ensurePrivateLayoutWithError:&error]);
  NSDictionary *descriptor = [self.access
      createRishOwnedWorkspaceWithDisplayName:@"Files V2"
                                  operationId:@"22222222-2222-4222-8222-222222222222"
                                        error:&error];
  XCTAssertNotNil(descriptor);
  XCTAssertNil(error);
  self.root = @{
    @"schema_version" : @1,
    @"workspace_id" : descriptor[@"workspace_id"],
    @"binding_revision" : descriptor[@"binding_revision"],
    @"project_id" : [NSNull null],
  };
  Class moduleClass = NSClassFromString(@"LocalWorkspaceModule");
  if (moduleClass == Nil) {
    XCTSkip(@"LocalWorkspaceModule is not linked into this XCTest target");
  }
  self.module = [[moduleClass alloc] init];
  [self.module setValue:self.access forKey:@"access"];
  NSString *projectId = @"33333333-3333-4333-8333-333333333333";
  self.projectRoot = @{
    @"schema_version" : @1,
    @"workspace_id" : self.root[@"workspace_id"],
    @"binding_revision" : self.root[@"binding_revision"],
    @"project_id" : projectId,
  };
  self.projectGitURL = [[[self.privateRoot
      URLByAppendingPathComponent:@"workspace-gitdirs" isDirectory:YES]
      URLByAppendingPathComponent:self.root[@"workspace_id"] isDirectory:YES]
      URLByAppendingPathComponent:projectId isDirectory:YES];
  git_repository *repository = nullptr;
  git_repository_init_options options = GIT_REPOSITORY_INIT_OPTIONS_INIT;
  options.flags = GIT_REPOSITORY_INIT_BARE | GIT_REPOSITORY_INIT_MKPATH;
  options.mode = 0700;
  options.initial_head = "main";
  XCTAssertGreaterThan(git_libgit2_init(), 0);
  XCTAssertEqual(git_repository_init_ext(&repository,
                                         self.projectGitURL.fileSystemRepresentation,
                                         &options), 0);
  XCTAssertNotEqual(repository, nullptr);
  if (repository != nullptr) git_repository_free(repository);
  self.projectAccess = [self projectAccessWithBindingProjectId:projectId
                                               driftOnResolve:0];
  [self.module setValue:self.projectAccess forKey:@"projectAccess"];
}

- (void)tearDown {
  [NSFileManager.defaultManager removeItemAtURL:self.privateRoot error:nil];
  [NSFileManager.defaultManager removeItemAtURL:self.documentsRoot error:nil];
  [super tearDown];
}

- (id)awaitCall:(void (^)(RishResolveBlock resolve,
                          RishRejectBlock reject))call
    expectedCode:(NSString *)expectedCode {
  XCTestExpectation *finished = [self expectationWithDescription:@"native call"];
  __block id value = nil;
  __block NSString *code = nil;
  call(^(id result) {
    value = result;
    [finished fulfill];
  }, ^(NSString *rejectedCode, NSString *message, NSError *error) {
    (void)message; (void)error;
    code = [rejectedCode copy];
    [finished fulfill];
  });
  [self waitForExpectationsWithTimeout:5 handler:nil];
  if (expectedCode != nil) {
    XCTAssertNil(value);
    XCTAssertEqualObjects(code, expectedCode);
  } else {
    XCTAssertNotNil(value);
    XCTAssertNil(code);
  }
  return value;
}

- (NSURL *)ownedWorkspaceURL {
  NSURL *container = [self.documentsRoot URLByAppendingPathComponent:@"Rish Workspaces"
                                                            isDirectory:YES];
  NSArray<NSURL *> *items = [NSFileManager.defaultManager
      contentsOfDirectoryAtURL:container
      includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                         options:NSDirectoryEnumerationSkipsHiddenFiles
                           error:nil];
  return items.firstObject;
}

- (DSHLocalProjectAccess *)projectAccessWithBindingProjectId:(NSString *)bindingProjectId
                                               driftOnResolve:(NSUInteger)driftOnResolve {
  __block NSUInteger resolveCount = 0;
  NSURL *gitURL = self.projectGitURL;
  return [[DSHLocalProjectAccess alloc]
      initWithWorkspaceAccess:self.access
              bindingResolver:^NSDictionary *(NSDictionary *rootRef,
                                              NSString *rootFingerprint,
                                              NSError **resolverError) {
                (void)resolverError;
                resolveCount += 1;
                NSString *resolvedProjectId = bindingProjectId;
                if (driftOnResolve > 0 && resolveCount >= driftOnResolve) {
                  resolvedProjectId = @"44444444-4444-4444-8444-444444444444";
                }
                return @{
                  @"schema_version" : @2,
                  @"workspace_id" : rootRef[@"workspace_id"],
                  @"binding_revision" : rootRef[@"binding_revision"],
                  @"project_id" : resolvedProjectId,
                  @"display_name" : @"Files V2",
                  @"git_topology" : @"private_split_gitdir",
                  @"git_directory_url" : gitURL,
                  @"root_fingerprint_sha256" : rootFingerprint,
                };
              }
                          hook:nil];
}

- (NSDictionary *)trashNote {
  NSDictionary *writeRequest = @{
    @"schema_version" : @1,
    @"root" : self.root,
    @"path" : @"note.md",
    @"content" : @"hello",
    @"expected_revision" : [NSNull null],
    @"create_only" : @YES,
  };
  [self awaitCall:^(RishResolveBlock resolve, RishRejectBlock reject) {
    [self.module writeV2Request:writeRequest resolver:resolve rejecter:reject];
  } expectedCode:nil];
  NSDictionary *trashRequest = @{
    @"schema_version" : @1,
    @"root" : self.root,
    @"path" : @"note.md",
  };
  return [self awaitCall:^(RishResolveBlock resolve, RishRejectBlock reject) {
    [self.module trashEntryV2Request:trashRequest resolver:resolve rejecter:reject];
  } expectedCode:nil];
}

- (void)testV2LeaseCapabilitiesWriteReadAndStaleRevision {
  id capabilities = [self awaitCall:^(RishResolveBlock resolve,
                                      RishRejectBlock reject) {
    [self.module capabilitiesWithResolver:resolve rejecter:reject];
  } expectedCode:nil];
  XCTAssertEqualObjects(capabilities[@"root"], @"workspace");
  NSDictionary *request = @{
    @"schema_version" : @1,
    @"root" : self.root,
    @"path" : @"note.md",
    @"content" : @"hello",
    @"expected_revision" : [NSNull null],
    @"create_only" : @YES,
  };
  NSDictionary *written = [self awaitCall:^(RishResolveBlock resolve,
                                            RishRejectBlock reject) {
    [self.module writeV2Request:request resolver:resolve rejecter:reject];
  } expectedCode:nil];
  XCTAssertEqualObjects(written[@"root"], self.root);
  NSDictionary *file = written[@"file"];
  XCTAssertEqualObjects(file[@"path"], @"note.md");
  NSDictionary *readRequest = @{
    @"schema_version" : @1,
    @"root" : self.root,
    @"path" : @"note.md",
    @"max_bytes" : @1024,
  };
  NSDictionary *read = [self awaitCall:^(RishResolveBlock resolve,
                                         RishRejectBlock reject) {
    [self.module readV2Request:readRequest resolver:resolve rejecter:reject];
  } expectedCode:nil];
  XCTAssertEqualObjects(read[@"content"], @"hello");
  NSDictionary *stale = @{
    @"schema_version" : @1,
    @"root" : self.root,
    @"path" : @"note.md",
    @"content" : @"stale",
    @"expected_revision" : @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    @"create_only" : @NO,
  };
  [self awaitCall:^(RishResolveBlock resolve, RishRejectBlock reject) {
    [self.module writeV2Request:stale resolver:resolve rejecter:reject];
  } expectedCode:@"E_WORKSPACE_CONFLICT"];
}

- (void)testProjectBoundExactRootWritesAndEchoesTheSameTuple {
  NSDictionary *request = @{
    @"schema_version" : @1,
    @"root" : self.projectRoot,
    @"path" : @"project-note.md",
    @"content" : @"project exact root",
    @"expected_revision" : [NSNull null],
    @"create_only" : @YES,
  };
  NSDictionary *written = [self awaitCall:^(RishResolveBlock resolve,
                                             RishRejectBlock reject) {
    [self.module writeV2Request:request resolver:resolve rejecter:reject];
  } expectedCode:nil];
  XCTAssertEqualObjects(written[@"root"], self.projectRoot);
  XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:
      [[self ownedWorkspaceURL] URLByAppendingPathComponent:@"project-note.md"].path]);
}

- (void)testProjectBoundWrongProjectAndStaleRevisionFailClosed {
  NSMutableDictionary *wrongProject = [self.projectRoot mutableCopy];
  wrongProject[@"project_id"] = @"55555555-5555-4555-8555-555555555555";
  NSDictionary *wrongRequest = @{
    @"schema_version" : @1,
    @"root" : wrongProject,
    @"path" : @"never-opened.md",
    @"max_bytes" : @1024,
  };
  [self awaitCall:^(RishResolveBlock resolve, RishRejectBlock reject) {
    [self.module readV2Request:wrongRequest resolver:resolve rejecter:reject];
  } expectedCode:@"E_WORKSPACE_ROOT_CHANGED"];

  NSMutableDictionary *stale = [self.projectRoot mutableCopy];
  stale[@"binding_revision"] = @2;
  NSDictionary *staleRequest = @{
    @"schema_version" : @1,
    @"root" : stale,
    @"path" : @"never-opened.md",
    @"max_bytes" : @1024,
  };
  [self awaitCall:^(RishResolveBlock resolve, RishRejectBlock reject) {
    [self.module readV2Request:staleRequest resolver:resolve rejecter:reject];
  } expectedCode:@"E_WORKSPACE_REVISION_STALE"];
}

- (void)testProjectRelationDriftAfterFilesystemBlockFailsClosed {
  DSHLocalProjectAccess *drifting = [self
      projectAccessWithBindingProjectId:self.projectRoot[@"project_id"]
                         driftOnResolve:3];
  [self.module setValue:drifting forKey:@"projectAccess"];
  NSDictionary *request = @{
    @"schema_version" : @1,
    @"root" : self.projectRoot,
    @"path" : @"",
    @"max_entries" : @10,
  };
  [self awaitCall:^(RishResolveBlock resolve, RishRejectBlock reject) {
    [self.module listV2Request:request resolver:resolve rejecter:reject];
  } expectedCode:@"E_WORKSPACE_ROOT_CHANGED"];
}

- (void)testLegacyProjectBoundListReadAndWriteUseRepositoryRoot {
  NSURL *base = [NSURL fileURLWithPath:[NSTemporaryDirectory()
      stringByAppendingPathComponent:[@"files-legacy-" stringByAppendingString:
          NSUUID.UUID.UUIDString.lowercaseString]] isDirectory:YES];
  NSURL *privateURL = [base URLByAppendingPathComponent:@"private" isDirectory:YES];
  NSURL *documents = [base URLByAppendingPathComponent:@"documents" isDirectory:YES];
  NSURL *projects = [base URLByAppendingPathComponent:@"projects" isDirectory:YES];
  NSString *projectId = @"66666666-6666-4666-8666-666666666666";
  NSURL *project = [projects URLByAppendingPathComponent:projectId isDirectory:YES];
  NSURL *repositoryURL = [project URLByAppendingPathComponent:@"repo" isDirectory:YES];
  for (NSURL *url in @[privateURL, documents, repositoryURL]) {
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:url
                                         withIntermediateDirectories:YES
                                                          attributes:@{NSFilePosixPermissions : @0700}
                                                               error:nil]);
  }
  NSData *metadata = [NSJSONSerialization dataWithJSONObject:@{
    @"schema_version" : @1, @"name" : @"Legacy Files",
    @"created_at" : @"2026-09-01T00:00:00.000Z",
    @"updated_at" : @"2026-09-01T00:00:00.000Z",
    @"origin_url" : NSNull.null,
  } options:0 error:nil];
  XCTAssertTrue([metadata writeToURL:[project URLByAppendingPathComponent:@"project.json"]
                            atomically:YES]);
  XCTAssertTrue([[@"legacy readme\n" dataUsingEncoding:NSUTF8StringEncoding]
      writeToURL:[repositoryURL URLByAppendingPathComponent:@"README.md"]
      atomically:YES]);
  git_repository *repository = nullptr;
  XCTAssertEqual(git_repository_init(&repository,
                                      repositoryURL.fileSystemRepresentation, 0), 0);
  if (repository != nullptr) git_repository_free(repository);
  DSHLocalProjectAccess *legacyProjectAccess = [[DSHLocalProjectAccess alloc]
      initWithProjectsRootURL:projects hook:nil];
  NSString *workspaceId = @"77777777-7777-4777-8777-777777777777";
  DSHLocalWorkspaceAccess *legacyWorkspaceAccess = [[DSHLocalWorkspaceAccess alloc]
      initWithPrivateRootURL:privateURL documentsRootURL:documents
      clock:^NSDate *{ return NSDate.date; }
      UUIDGenerator:^NSString *{ return workspaceId; }
      legacyResolver:^BOOL(NSString *resolvedProjectId, NSDictionary **evidence,
                           NSError **resolverError) {
        NSDictionary *resolved = [legacyProjectAccess
            legacyWorkspaceBootstrapEvidenceForProjectId:resolvedProjectId
                                                     error:resolverError];
        if (evidence != nil) *evidence = resolved;
        return resolved != nil;
      } faultHook:nil];
  NSError *error = nil;
  XCTAssertNotNil([legacyWorkspaceAccess bootstrapLegacyProjectId:projectId
      operationId:@"88888888-8888-4888-8888-888888888888" error:&error], @"%@", error);
  NSDictionary *root = @{
    @"schema_version" : @1, @"workspace_id" : workspaceId,
    @"binding_revision" : @1, @"project_id" : projectId,
  };
  [self.module setValue:legacyWorkspaceAccess forKey:@"access"];
  [self.module setValue:legacyProjectAccess forKey:@"projectAccess"];
  NSDictionary *listed = [self awaitCall:^(RishResolveBlock resolve,
                                            RishRejectBlock reject) {
    [self.module listV2Request:@{@"schema_version" : @1, @"root" : root,
      @"path" : @"", @"max_entries" : @10} resolver:resolve rejecter:reject];
  } expectedCode:nil];
  XCTAssertTrue([[listed[@"entries"] valueForKey:@"name"] containsObject:@"README.md"]);
  NSDictionary *read = [self awaitCall:^(RishResolveBlock resolve,
                                          RishRejectBlock reject) {
    [self.module readV2Request:@{@"schema_version" : @1, @"root" : root,
      @"path" : @"README.md", @"max_bytes" : @1024}
                      resolver:resolve rejecter:reject];
  } expectedCode:nil];
  XCTAssertEqualObjects(read[@"content"], @"legacy readme\n");
  [self awaitCall:^(RishResolveBlock resolve, RishRejectBlock reject) {
    [self.module writeV2Request:@{@"schema_version" : @1, @"root" : root,
      @"path" : @"temp.txt", @"content" : @"legacy write",
      @"expected_revision" : NSNull.null, @"create_only" : @YES}
                       resolver:resolve rejecter:reject];
  } expectedCode:nil];
  XCTAssertEqualObjects([NSString stringWithContentsOfURL:
      [repositoryURL URLByAppendingPathComponent:@"temp.txt"]
                                         encoding:NSUTF8StringEncoding error:nil],
                        @"legacy write");
  [NSFileManager.defaultManager removeItemAtURL:base error:nil];
}

- (void)testHardlinkIsRejectedAndRenameUsesExclusiveNameCAS {
  NSString *workspacePath = self.ownedWorkspaceURL.path;
  NSString *notePath = [workspacePath stringByAppendingPathComponent:@"note.md"];
  NSString *linkPath = [workspacePath stringByAppendingPathComponent:@"note-link.md"];
  NSDictionary *writeRequest = @{
    @"schema_version" : @1,
    @"root" : self.root,
    @"path" : @"note.md",
    @"content" : @"hello",
    @"expected_revision" : [NSNull null],
    @"create_only" : @YES,
  };
  [self awaitCall:^(RishResolveBlock resolve, RishRejectBlock reject) {
    [self.module writeV2Request:writeRequest resolver:resolve rejecter:reject];
  } expectedCode:nil];
  XCTAssertEqual(link(notePath.fileSystemRepresentation, linkPath.fileSystemRepresentation), 0);
  NSDictionary *readRequest = @{
    @"schema_version" : @1,
    @"root" : self.root,
    @"path" : @"note.md",
    @"max_bytes" : @1024,
  };
  [self awaitCall:^(RishResolveBlock resolve, RishRejectBlock reject) {
    [self.module readV2Request:readRequest resolver:resolve rejecter:reject];
  } expectedCode:@"E_WORKSPACE_IO"];
  NSDictionary *renameRequest = @{
    @"schema_version" : @1,
    @"root" : self.root,
    @"source_path" : @"note.md",
    @"destination_path" : @"note-link.md",
  };
  [self awaitCall:^(RishResolveBlock resolve, RishRejectBlock reject) {
    [self.module renameEntryV2Request:renameRequest resolver:resolve rejecter:reject];
  } expectedCode:@"E_WORKSPACE_CONFLICT"];
}

- (void)testTrashRestoreRoundTripUsesDescriptorBoundPayload {
  NSDictionary *writeRequest = @{
    @"schema_version" : @1,
    @"root" : self.root,
    @"path" : @"note.md",
    @"content" : @"hello",
    @"expected_revision" : [NSNull null],
    @"create_only" : @YES,
  };
  [self awaitCall:^(RishResolveBlock resolve, RishRejectBlock reject) {
    [self.module writeV2Request:writeRequest resolver:resolve rejecter:reject];
  } expectedCode:nil];
  NSDictionary *trashRequest = @{
    @"schema_version" : @1,
    @"root" : self.root,
    @"path" : @"note.md",
  };
  NSDictionary *trash = [self awaitCall:^(RishResolveBlock resolve,
                                          RishRejectBlock reject) {
    [self.module trashEntryV2Request:trashRequest resolver:resolve rejecter:reject];
  } expectedCode:nil];
  NSString *trashId = trash[@"receipt"][@"trash_id"];
  XCTAssertTrue([trashId isKindOfClass:NSString.class]);
  NSDictionary *restoreRequest = @{
    @"schema_version" : @1,
    @"root" : self.root,
    @"trash_id" : trashId,
    @"destination_path" : [NSNull null],
  };
  NSDictionary *restored = [self awaitCall:^(RishResolveBlock resolve,
                                             RishRejectBlock reject) {
    [self.module restoreFromTrashV2Request:restoreRequest resolver:resolve rejecter:reject];
  } expectedCode:nil];
  XCTAssertEqualObjects(restored[@"entry"][@"path"], @"note.md");
}

- (void)testRootReplacementFailsClosedBeforeOpenAndLeavesRollbackTarget {
  NSDictionary *writeRequest = @{
    @"schema_version" : @1,
    @"root" : self.root,
    @"path" : @"note.md",
    @"content" : @"hello",
    @"expected_revision" : [NSNull null],
    @"create_only" : @YES,
  };
  [self awaitCall:^(RishResolveBlock resolve, RishRejectBlock reject) {
    [self.module writeV2Request:writeRequest resolver:resolve rejecter:reject];
  } expectedCode:nil];
  NSURL *workspace = self.ownedWorkspaceURL;
  NSURL *replacement = [workspace.URLByDeletingLastPathComponent
      URLByAppendingPathComponent:[workspace.lastPathComponent stringByAppendingString:@"-rollback"]
                       isDirectory:YES];
  XCTAssertEqual(rename(workspace.fileSystemRepresentation,
                        replacement.fileSystemRepresentation), 0);
  XCTAssertEqual(mkdir(workspace.fileSystemRepresentation, 0700), 0);
  NSDictionary *readRequest = @{
    @"schema_version" : @1,
    @"root" : self.root,
    @"path" : @"note.md",
    @"max_bytes" : @1024,
  };
  [self awaitCall:^(RishResolveBlock resolve, RishRejectBlock reject) {
    [self.module readV2Request:readRequest resolver:resolve rejecter:reject];
  } expectedCode:@"E_WORKSPACE_ROOT_CHANGED"];
  XCTAssertEqual(rmdir(workspace.fileSystemRepresentation), 0);
  XCTAssertEqual(rename(replacement.fileSystemRepresentation,
                        workspace.fileSystemRepresentation), 0);
}

- (void)testRestoreMetadataUnlinkFailureRollsBackWithReadableReceipt {
  NSDictionary *trash = [self trashNote];
  NSString *trashId = trash[@"receipt"][@"trash_id"];
  [self.module setValue:^BOOL(NSString *stage) {
    return [stage isEqual:@"restore_metadata_unlink"];
  } forKey:@"filesV2FaultHook"];
  NSDictionary *restoreRequest = @{
    @"schema_version" : @1,
    @"root" : self.root,
    @"trash_id" : trashId,
    @"destination_path" : [NSNull null],
  };
  [self awaitCall:^(RishResolveBlock resolve, RishRejectBlock reject) {
    [self.module restoreFromTrashV2Request:restoreRequest resolver:resolve rejecter:reject];
  } expectedCode:@"E_WORKSPACE_IO"];
  [self.module setValue:nil forKey:@"filesV2FaultHook"];
  NSURL *record = [[self.ownedWorkspaceURL URLByAppendingPathComponent:@".trash"
                                                        isDirectory:YES]
      URLByAppendingPathComponent:trashId isDirectory:YES];
  XCTAssertTrue([NSFileManager.defaultManager
                    fileExistsAtPath:[record URLByAppendingPathComponent:@"payload"].path]);
  XCTAssertTrue([NSFileManager.defaultManager
                    fileExistsAtPath:[record URLByAppendingPathComponent:@"metadata.json"].path] ||
                [NSFileManager.defaultManager
                    fileExistsAtPath:[record URLByAppendingPathComponent:@"metadata.recovery.json"].path]);
  NSDictionary *listRequest = @{
    @"schema_version" : @1,
    @"root" : self.root,
    @"max_entries" : @10,
  };
  NSDictionary *listed = [self awaitCall:^(RishResolveBlock resolve, RishRejectBlock reject) {
    [self.module listTrashV2Request:listRequest resolver:resolve rejecter:reject];
  } expectedCode:nil];
  NSArray *listedEntries = listed[@"entries"];
  XCTAssertEqualObjects(listed[@"invalid_record_count"], @0);
  XCTAssertEqual(listedEntries.count, (NSUInteger)1);
  [self awaitCall:^(RishResolveBlock resolve, RishRejectBlock reject) {
    [self.module restoreFromTrashV2Request:restoreRequest resolver:resolve rejecter:reject];
  } expectedCode:nil];
}

- (void)testRestoreMetadataFsyncFailureRecreatesReadableReceipt {
  NSDictionary *trash = [self trashNote];
  NSString *trashId = trash[@"receipt"][@"trash_id"];
  [self.module setValue:^BOOL(NSString *stage) {
    return [stage isEqual:@"restore_metadata_fsync"];
  } forKey:@"filesV2FaultHook"];
  NSDictionary *restoreRequest = @{
    @"schema_version" : @1,
    @"root" : self.root,
    @"trash_id" : trashId,
    @"destination_path" : [NSNull null],
  };
  [self awaitCall:^(RishResolveBlock resolve, RishRejectBlock reject) {
    [self.module restoreFromTrashV2Request:restoreRequest resolver:resolve rejecter:reject];
  } expectedCode:@"E_WORKSPACE_IO"];
  [self.module setValue:nil forKey:@"filesV2FaultHook"];
  NSURL *record = [[self.ownedWorkspaceURL URLByAppendingPathComponent:@".trash"
                                                        isDirectory:YES]
      URLByAppendingPathComponent:trashId isDirectory:YES];
  XCTAssertTrue([NSFileManager.defaultManager
                    fileExistsAtPath:[record URLByAppendingPathComponent:@"payload"].path]);
  XCTAssertTrue([NSFileManager.defaultManager
                    fileExistsAtPath:[record URLByAppendingPathComponent:@"metadata.json"].path] ||
                [NSFileManager.defaultManager
                    fileExistsAtPath:[record URLByAppendingPathComponent:@"metadata.recovery.json"].path]);
  NSDictionary *listRequest = @{
    @"schema_version" : @1,
    @"root" : self.root,
    @"max_entries" : @10,
  };
  NSDictionary *listed = [self awaitCall:^(RishResolveBlock resolve, RishRejectBlock reject) {
    [self.module listTrashV2Request:listRequest resolver:resolve rejecter:reject];
  } expectedCode:nil];
  NSArray *listedEntries = listed[@"entries"];
  XCTAssertEqualObjects(listed[@"invalid_record_count"], @0);
  XCTAssertEqual(listedEntries.count, (NSUInteger)1);
  [self awaitCall:^(RishResolveBlock resolve, RishRejectBlock reject) {
    [self.module restoreFromTrashV2Request:restoreRequest resolver:resolve rejecter:reject];
  } expectedCode:nil];
}


- (void)testProductionFilesAndDocumentsInitializersResolveBootstrappedLegacyProject {
  NSURL *base = DSHCreateTestStorageFixtureRoot(@"FilesLegacyInitialization", nil);
  XCTAssertNotNil(base);
  if (base == nil) return;
  NSURL *support = [base URLByAppendingPathComponent:@"private" isDirectory:YES];
  NSURL *projectsURL = [base URLByAppendingPathComponent:@"projects" isDirectory:YES];
  NSString *projectId = NSUUID.UUID.UUIDString.lowercaseString;
  NSURL *projectURL = [projectsURL URLByAppendingPathComponent:projectId isDirectory:YES];
  NSURL *repoURL = [projectURL URLByAppendingPathComponent:@"repo" isDirectory:YES];
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:support withIntermediateDirectories:YES attributes:nil error:nil]);
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:repoURL withIntermediateDirectories:YES attributes:nil error:nil]);
  NSDictionary *metadata = @{ @"schema_version": @1, @"name": @"Files root fixture",
    @"created_at": @"2026-09-06T00:00:00.000Z", @"updated_at": @"2026-09-06T00:00:00.000Z", @"origin_url": NSNull.null };
  XCTAssertTrue([[NSJSONSerialization dataWithJSONObject:metadata options:0 error:nil]
    writeToURL:[projectURL URLByAppendingPathComponent:@"project.json"] atomically:YES]);
  XCTAssertTrue([[@"fixture-content\n" dataUsingEncoding:NSUTF8StringEncoding]
    writeToURL:[repoURL URLByAppendingPathComponent:@"marker.txt"] atomically:YES]);
  git_repository *repository = nullptr;
  XCTAssertGreaterThan(git_libgit2_init(), 0);
  XCTAssertEqual(git_repository_init(&repository, repoURL.fileSystemRepresentation, 0), 0);
  if (repository != nullptr) git_repository_free(repository);
  DSHLocalProjectAccess *legacy = [[DSHLocalProjectAccess alloc] initWithProjectsRootURL:projectsURL];
  LocalWorkspaceModule *files = [[LocalWorkspaceModule alloc] initWithSupportURL:support legacyProjectAccess:legacy];
  DSHLocalWorkspaceAccess *registry = [files valueForKey:@"access"];
  NSError *error = nil;
  NSDictionary *workspace = [registry bootstrapLegacyProjectId:projectId operationId:NSUUID.UUID.UUIDString.lowercaseString error:&error];
  XCTAssertNotNil(workspace, @"%@", error);
  if (workspace != nil) {
    NSDictionary *root = @{ @"schema_version": @1, @"workspace_id": workspace[@"workspace_id"],
      @"binding_revision": workspace[@"binding_revision"], @"project_id": projectId };
    NSDictionary *listing = [self awaitCall:^(RishResolveBlock resolve, RishRejectBlock reject) {
      [files listV2Request:@{ @"schema_version": @1, @"root": root, @"path": @"", @"max_entries": @100 }
        resolver:resolve rejecter:reject];
    } expectedCode:nil];
    XCTAssertTrue([[listing[@"entries"] valueForKey:@"name"] containsObject:@"marker.txt"]);
    LocalDocumentsModule *documents = [[LocalDocumentsModule alloc] initWithSupportURL:support legacyProjectAccess:legacy];
    dispatch_sync((dispatch_queue_t)[documents valueForKey:@"documentQueue"], ^{});
    __block NSString *readback = nil;
    BOOL readSucceeded = [documents performRoot:root capabilities:[NSSet setWithObject:@"read"]
      block:^BOOL(int descriptor, __unused NSError **blockError) {
        int fd = openat(descriptor, "marker.txt", O_RDONLY | O_NOFOLLOW);
        if (fd < 0) return NO;
        char data[64] = {}; ssize_t count = read(fd, data, sizeof(data)); close(fd);
        if (count < 0) return NO;
        readback = [[NSString alloc] initWithBytes:data length:(NSUInteger)count encoding:NSUTF8StringEncoding];
        return YES;
      } error:&error];
    XCTAssertTrue(readSucceeded, @"%@", error);
    XCTAssertEqualObjects(readback, @"fixture-content\n");
  }
  [NSFileManager.defaultManager removeItemAtURL:base error:nil];
}

@end
