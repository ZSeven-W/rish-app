#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
#import <RishNative/RishNativeModule.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "../../../../modules/rish/ios/Sources/LocalProjectAccess.h"
#import "../../../../modules/rish/ios/Sources/LocalWorkspaceAccess.h"
#import "../../../../modules/rish/ios/Sources/DSHWorkspaceCanonical.h"

#include <git2.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

@interface LocalDocumentsModule : NSObject
@property(nonatomic, readonly) dispatch_queue_t documentQueue;
@end

@interface LocalDocumentsModule (DocumentsV2Testing)
- (void)presentImportPickerRequest:(id)request
                          resolver:(RishResolveBlock)resolve
                          rejecter:(RishRejectBlock)reject;
- (void)presentExportPickerRequest:(id)request
                           resolver:(RishResolveBlock)resolve
                           rejecter:(RishRejectBlock)reject;
- (void)queryOperationRequest:(id)request
                      resolver:(RishResolveBlock)resolve
                      rejecter:(RishRejectBlock)reject;
- (void)cleanupOperationRequest:(id)request
                       resolver:(RishResolveBlock)resolve
                       rejecter:(RishRejectBlock)reject;
- (BOOL)saveStagingJournal:(NSDictionary *)journal error:(NSError **)error;
- (NSArray<NSDictionary *> *)loadCommittedReceipts:(NSError **)error;
- (BOOL)saveCommittedReceipts:(NSArray<NSDictionary *> *)receipts error:(NSError **)error;
- (BOOL)archiveCommittedJournal:(NSDictionary *)journal error:(NSError **)error;
- (NSDictionary *)loadStagingJournal:(NSError **)error;
- (NSURL *)newStagingDirectory:(NSString *)prefix
                     operationId:(NSString *)operationId
                          error:(NSError **)error;
- (BOOL)reconcileJournal:(NSDictionary *)journal error:(NSError **)error;
- (BOOL)publishJournal:(NSDictionary *)journal
                  root:(NSDictionary *)root
               entries:(NSArray<NSDictionary *> **)entries
                 error:(NSError **)error;
- (void)retryOperationRequest:(id)request
                     resolver:(RishResolveBlock)resolve
                     rejecter:(RishRejectBlock)reject;
- (BOOL)claimPendingCallbackForController:(UIDocumentPickerViewController *)controller
                               generation:(NSUInteger)generation;
@end

@interface LocalDocumentsModuleV2Tests : XCTestCase
@property(nonatomic, strong) NSURL *privateRoot;
@property(nonatomic, strong) NSURL *documentsRoot;
@property(nonatomic, strong) DSHLocalWorkspaceAccess *access;
@property(nonatomic, strong) DSHLocalProjectAccess *projectAccess;
@property(nonatomic, strong) LocalDocumentsModule *module;
- (NSDictionary *)createProjectRootWithBindingProjectId:(NSString *)bindingProjectId
                                          driftOnResolve:(NSUInteger)driftOnResolve;
@end

static BOOL DSHTestWriteFile(NSURL *url, NSString *content) {
  NSData *data = [content dataUsingEncoding:NSUTF8StringEncoding];
  int descriptor = open(url.fileSystemRepresentation,
                        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (descriptor < 0) return NO;
  const uint8_t *bytes = (const uint8_t *)data.bytes;
  NSUInteger offset = 0;
  BOOL ok = YES;
  while (offset < data.length) {
    ssize_t amount = write(descriptor, bytes + offset, data.length - offset);
    if (amount < 0 && errno == EINTR) continue;
    if (amount <= 0) { ok = NO; break; }
    offset += (NSUInteger)amount;
  }
  ok = ok && fsync(descriptor) == 0 && close(descriptor) == 0;
  if (!ok) close(descriptor);
  return ok;
}

static NSDictionary *DSHTestStateRecord(NSString *name, struct stat state) {
  return @{
    @"name" : name,
    @"device_id" : [NSString stringWithFormat:@"%llu", (unsigned long long)state.st_dev],
    @"inode_id" : [NSString stringWithFormat:@"%llu", (unsigned long long)state.st_ino],
    @"mode" : [NSString stringWithFormat:@"%llu", (unsigned long long)state.st_mode],
    @"size" : [NSString stringWithFormat:@"%llu", (unsigned long long)state.st_size],
    @"mtime_sec" : [NSString stringWithFormat:@"%lld", (long long)state.st_mtimespec.tv_sec],
    @"mtime_nsec" : [NSString stringWithFormat:@"%lld", (long long)state.st_mtimespec.tv_nsec],
  };
}

static NSDictionary *DSHTestRoot(NSString *workspaceId,
                                 NSNumber *bindingRevision,
                                 id projectId) {
  return @{
    @"schema_version" : @1,
    @"workspace_id" : workspaceId,
    @"binding_revision" : bindingRevision,
    @"project_id" : projectId,
  };
}

static NSString *DSHTestDocumentDigest(NSString *kind,
                                        NSString *operationId,
                                        NSString *workspaceId,
                                        NSNumber *bindingRevision,
                                        id projectId,
                                        NSString *destinationPath,
                                        NSArray<NSString *> *sourcePaths) {
  NSDictionary *semanticRequest = @{
    @"domain" : @"rish.local-documents.request.v1",
    @"operation" : kind,
    @"operation_id" : operationId,
    @"root" : @{
      @"schema_version" : @1,
      @"workspace_id" : workspaceId,
      @"binding_revision" : bindingRevision,
      @"project_id" : projectId,
    },
    @"destination_path" : destinationPath ?: @"",
    @"source_paths" : sourcePaths ?: @[],
  };
  return DSHWorkspaceSHA256Hex(DSHWorkspaceCanonicalJSONData(semanticRequest, nil));
}

static NSDictionary *DSHTestLargeCommittedExport(NSString *operationId,
                                                 NSUInteger pathCount,
                                                 NSUInteger pathLength) {
  NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:pathCount];
  for (NSUInteger index = 0; index < pathCount; index += 1) {
    NSString *prefix = [NSString stringWithFormat:@"p%lu-", (unsigned long)index];
    NSUInteger remaining = pathLength > prefix.length ? pathLength - prefix.length : 1;
    NSMutableArray<NSString *> *components = [NSMutableArray array];
    NSUInteger firstLength = MIN((NSUInteger)240, remaining);
    [components addObject:[prefix stringByAppendingString:
        [@"x" stringByPaddingToLength:firstLength withString:@"x" startingAtIndex:0]]];
    remaining -= firstLength;
    while (remaining > 0) {
      NSUInteger componentLength = MIN((NSUInteger)240, remaining);
      [components addObject:[@"x" stringByPaddingToLength:componentLength
                                              withString:@"x"
                                         startingAtIndex:0]];
      remaining -= componentLength;
    }
    [paths addObject:[components componentsJoinedByString:@"/"]];
  }
  NSString *stagingName = [NSString stringWithFormat:@"export-%@", operationId];
  return @{
    @"schema_version" : @1,
    @"operation_id" : operationId,
    @"request_sha256" : DSHTestDocumentDigest(@"export", operationId,
                                                @"44444444-4444-4444-8444-444444444444", @1,
                                                [NSNull null], @"", paths),
    @"kind" : @"export",
    @"phase" : @"committed",
    @"workspace_id" : @"44444444-4444-4444-8444-444444444444",
    @"binding_revision" : @1,
    @"project_id" : [NSNull null],
    @"destination_path" : @"",
    @"source_paths" : paths,
    @"staging_name" : stagingName,
    @"entry_names" : @[],
    @"entry_states" : @[],
    @"created_at" : @"2026-08-31T00:00:00.000Z",
    @"updated_at" : @"2026-08-31T00:00:00.000Z",
  };
}

@implementation LocalDocumentsModuleV2Tests

- (void)setUp {
  [super setUp];
  NSString *suffix = NSUUID.UUID.UUIDString.lowercaseString;
  self.privateRoot = [NSURL fileURLWithPath:
      [NSTemporaryDirectory() stringByAppendingPathComponent:
          [NSString stringWithFormat:@"rish-documents-v2-private-%@", suffix]]
                                           isDirectory:YES];
  self.documentsRoot = [NSURL fileURLWithPath:
      [NSTemporaryDirectory() stringByAppendingPathComponent:
          [NSString stringWithFormat:@"rish-documents-v2-documents-%@", suffix]]
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
                  return @"44444444-4444-4444-8444-444444444444";
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
  Class moduleClass = NSClassFromString(@"LocalDocumentsModule");
  if (moduleClass == Nil) {
    XCTSkip(@"LocalDocumentsModule is not linked into this XCTest target");
  }
  self.module = [[moduleClass alloc] init];
  [self.module setValue:self.access forKey:@"access"];
}

- (void)tearDown {
  [NSFileManager.defaultManager removeItemAtURL:self.privateRoot error:nil];
  [NSFileManager.defaultManager removeItemAtURL:self.documentsRoot error:nil];
  [super tearDown];
}

- (void)awaitCall:(void (^)(RishResolveBlock resolve,
                            RishRejectBlock reject))call
    expectedValue:(NSDictionary *)expectedValue
     expectedCode:(NSString *)expectedCode {
  XCTestExpectation *finished = [self expectationWithDescription:@"document operation"];
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
    XCTAssertEqualObjects(value, expectedValue);
    XCTAssertNil(code);
  }
}

- (NSDictionary *)createWorkspaceRoot {
  NSError *error = nil;
  NSDictionary *descriptor = [self.access
      createRishOwnedWorkspaceWithDisplayName:@"Mixed Import"
                                  operationId:NSUUID.UUID.UUIDString.lowercaseString
                                        error:&error];
  XCTAssertNotNil(descriptor);
  XCTAssertNil(error);
  if (descriptor == nil) return nil;
  return @{
    @"schema_version" : @1,
    @"workspace_id" : descriptor[@"workspace_id"],
    @"binding_revision" : descriptor[@"binding_revision"],
    @"project_id" : [NSNull null],
  };
}

- (NSDictionary *)createProjectRootWithBindingProjectId:(NSString *)bindingProjectId
                                          driftOnResolve:(NSUInteger)driftOnResolve {
  NSDictionary *workspaceRoot = [self createWorkspaceRoot];
  if (workspaceRoot == nil) return nil;
  NSString *projectId = @"66666666-6666-4666-8666-666666666666";
  NSURL *gitURL = [[[self.privateRoot
      URLByAppendingPathComponent:@"workspace-gitdirs" isDirectory:YES]
      URLByAppendingPathComponent:workspaceRoot[@"workspace_id"] isDirectory:YES]
      URLByAppendingPathComponent:projectId isDirectory:YES];
  git_repository *repository = nullptr;
  git_repository_init_options options = GIT_REPOSITORY_INIT_OPTIONS_INIT;
  options.flags = GIT_REPOSITORY_INIT_BARE | GIT_REPOSITORY_INIT_MKPATH;
  options.mode = 0700;
  options.initial_head = "main";
  XCTAssertGreaterThan(git_libgit2_init(), 0);
  XCTAssertEqual(git_repository_init_ext(&repository,
                                         gitURL.fileSystemRepresentation,
                                         &options), 0);
  XCTAssertNotEqual(repository, nullptr);
  if (repository != nullptr) git_repository_free(repository);
  __block NSUInteger resolveCount = 0;
  self.projectAccess = [[DSHLocalProjectAccess alloc]
      initWithWorkspaceAccess:self.access
              bindingResolver:^NSDictionary *(NSDictionary *rootRef,
                                              NSString *rootFingerprint,
                                              NSError **resolverError) {
                (void)resolverError;
                resolveCount += 1;
                NSString *resolvedProjectId = bindingProjectId;
                if (driftOnResolve > 0 && resolveCount >= driftOnResolve) {
                  resolvedProjectId = @"77777777-7777-4777-8777-777777777777";
                }
                return @{
                  @"schema_version" : @2,
                  @"workspace_id" : rootRef[@"workspace_id"],
                  @"binding_revision" : rootRef[@"binding_revision"],
                  @"project_id" : resolvedProjectId,
                  @"display_name" : @"Documents V2 Project",
                  @"git_topology" : @"private_split_gitdir",
                  @"git_directory_url" : gitURL,
                  @"root_fingerprint_sha256" : rootFingerprint,
                };
              }
                          hook:nil];
  [self.module setValue:self.projectAccess forKey:@"projectAccess"];
  return @{
    @"schema_version" : @1,
    @"workspace_id" : workspaceRoot[@"workspace_id"],
    @"binding_revision" : workspaceRoot[@"binding_revision"],
    @"project_id" : projectId,
  };
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

- (void)testJournalQueryAndCleanupRequireExactRootAndOperationId {
  NSString *operationId = @"55555555-5555-4555-8555-555555555555";
  NSDictionary *root = DSHTestRoot(
      @"44444444-4444-4444-8444-444444444444", @1, [NSNull null]);
  NSDictionary *query = @{
    @"schema_version" : @1,
    @"operation_id" : operationId,
    @"root" : root,
  };
  [self awaitCall:^(RishResolveBlock resolve, RishRejectBlock reject) {
    [self.module queryOperationRequest:query resolver:resolve rejecter:reject];
  } expectedValue:@{
    @"schema_version" : @1,
    @"operation_id" : operationId,
    @"status" : @"not_started",
  } expectedCode:nil];
  NSDictionary *cleanup = @{
    @"schema_version" : @1,
    @"operation_id" : operationId,
    @"root" : root,
  };
  [self awaitCall:^(RishResolveBlock resolve, RishRejectBlock reject) {
    [self.module cleanupOperationRequest:cleanup resolver:resolve rejecter:reject];
  } expectedValue:@{
    @"schema_version" : @1,
    @"operation_id" : operationId,
    @"status" : @"cleaned",
  } expectedCode:nil];
}

- (void)testQueryAndCleanupAreExactRootScopedAndCannotDeleteWrongTuple {
  NSString *operationId = @"56565656-5656-4656-8656-565656565656";
  NSDictionary *receipt = DSHTestLargeCommittedExport(operationId, 1, 16);
  NSDictionary *correctRoot = DSHTestRoot(
      receipt[@"workspace_id"], receipt[@"binding_revision"],
      receipt[@"project_id"]);
  __block NSError *saveError = nil;
  dispatch_sync(self.module.documentQueue, ^{
    XCTAssertTrue([self.module saveCommittedReceipts:@[receipt]
                                                error:&saveError]);
  });
  XCTAssertNil(saveError);
  NSArray<NSDictionary *> *wrongRoots = @[
    DSHTestRoot(@"45454545-4545-4545-8545-454545454545", @1,
                [NSNull null]),
    DSHTestRoot(receipt[@"workspace_id"], @2, [NSNull null]),
    DSHTestRoot(receipt[@"workspace_id"], @1,
                @"67676767-6767-4767-8767-676767676767"),
  ];
  for (NSDictionary *wrongRoot in wrongRoots) {
    NSDictionary *request = @{
      @"schema_version" : @1,
      @"operation_id" : operationId,
      @"root" : wrongRoot,
    };
    [self awaitCall:^(RishResolveBlock resolve,
                      RishRejectBlock reject) {
      [self.module queryOperationRequest:request resolver:resolve rejecter:reject];
    } expectedValue:nil expectedCode:@"E_WORKSPACE_CONFLICT"];
    [self awaitCall:^(RishResolveBlock resolve,
                      RishRejectBlock reject) {
      [self.module cleanupOperationRequest:request resolver:resolve rejecter:reject];
    } expectedValue:nil expectedCode:@"E_WORKSPACE_CONFLICT"];
  }
  NSDictionary *correctRequest = @{
    @"schema_version" : @1,
    @"operation_id" : operationId,
    @"root" : correctRoot,
  };
  [self awaitCall:^(RishResolveBlock resolve,
                    RishRejectBlock reject) {
    [self.module queryOperationRequest:correctRequest resolver:resolve rejecter:reject];
  } expectedValue:@{
    @"schema_version" : @1,
    @"operation_id" : operationId,
    @"status" : @"committed",
  } expectedCode:nil];

  NSString *journalId = @"57575757-5757-4757-8757-575757575757";
  NSDictionary *journal = @{
    @"schema_version" : @1,
    @"operation_id" : journalId,
    @"request_sha256" : DSHTestDocumentDigest(
        @"import", journalId, correctRoot[@"workspace_id"],
        correctRoot[@"binding_revision"], correctRoot[@"project_id"], @"", @[]),
    @"kind" : @"import",
    @"phase" : @"prepared",
    @"workspace_id" : correctRoot[@"workspace_id"],
    @"binding_revision" : correctRoot[@"binding_revision"],
    @"project_id" : correctRoot[@"project_id"],
    @"destination_path" : @"",
    @"source_paths" : @[],
    @"staging_name" : @"import-57575757-5757-4757-8757-575757575757",
    @"entry_names" : @[],
    @"entry_states" : @[],
    @"created_at" : @"2026-08-31T00:00:00.000Z",
    @"updated_at" : @"2026-08-31T00:00:00.000Z",
  };
  dispatch_sync(self.module.documentQueue, ^{
    XCTAssertTrue([self.module saveStagingJournal:journal error:&saveError]);
  });
  XCTAssertNil(saveError);
  NSDictionary *wrongJournalRequest = @{
    @"schema_version" : @1,
    @"operation_id" : journalId,
    @"root" : wrongRoots.lastObject,
  };
  [self awaitCall:^(RishResolveBlock resolve,
                    RishRejectBlock reject) {
    [self.module cleanupOperationRequest:wrongJournalRequest
                                resolver:resolve rejecter:reject];
  } expectedValue:nil expectedCode:@"E_WORKSPACE_CONFLICT"];
  NSDictionary *correctJournalRequest = @{
    @"schema_version" : @1,
    @"operation_id" : journalId,
    @"root" : correctRoot,
  };
  [self awaitCall:^(RishResolveBlock resolve,
                    RishRejectBlock reject) {
    [self.module queryOperationRequest:correctJournalRequest
                              resolver:resolve rejecter:reject];
  } expectedValue:@{
    @"schema_version" : @1,
    @"operation_id" : journalId,
    @"status" : @"in_progress",
  } expectedCode:nil];
  [self awaitCall:^(RishResolveBlock resolve,
                    RishRejectBlock reject) {
    [self.module cleanupOperationRequest:correctJournalRequest
                                resolver:resolve rejecter:reject];
  } expectedValue:@{
    @"schema_version" : @1,
    @"operation_id" : journalId,
    @"status" : @"cleaned",
  } expectedCode:nil];
}

- (void)testCommittedJournalSurvivesLostResponseUntilExplicitCleanup {
  NSString *operationId = @"88888888-8888-4888-8888-888888888888";
  NSDictionary *journal = @{
    @"schema_version" : @1,
    @"operation_id" : operationId,
    @"request_sha256" : DSHTestDocumentDigest(@"import", operationId,
                                                @"44444444-4444-4444-8444-444444444444", @1,
                                                [NSNull null], @"", @[]),
    @"kind" : @"import",
    @"phase" : @"committed",
    @"workspace_id" : @"44444444-4444-4444-8444-444444444444",
    @"binding_revision" : @1,
    @"project_id" : [NSNull null],
    @"destination_path" : @"",
    @"source_paths" : @[],
    @"staging_name" : @"import-88888888-8888-4888-8888-888888888888",
    @"entry_names" : @[],
    @"entry_states" : @[],
    @"created_at" : @"2026-08-31T00:00:00.000Z",
    @"updated_at" : @"2026-08-31T00:00:00.123Z",
  };
  __block NSError *writeError = nil;
  __block BOOL acceptedFractional = NO;
  __block BOOL rejectedMissingFraction = NO;
  __block BOOL rejectedInvalidSeconds = NO;
  dispatch_sync(self.module.documentQueue, ^{
    acceptedFractional = [self.module saveStagingJournal:journal error:&writeError];
    NSMutableDictionary *missingFraction = [journal mutableCopy];
    missingFraction[@"updated_at"] = @"2026-08-31T00:00:00Z";
    rejectedMissingFraction = ![self.module saveStagingJournal:missingFraction error:&writeError];
    NSMutableDictionary *invalidSeconds = [journal mutableCopy];
    invalidSeconds[@"updated_at"] = @"2026-08-31T00:00:60.000Z";
    rejectedInvalidSeconds = ![self.module saveStagingJournal:invalidSeconds error:&writeError];
    writeError = nil;
  });
  XCTAssertTrue(acceptedFractional);
  XCTAssertTrue(rejectedMissingFraction);
  XCTAssertTrue(rejectedInvalidSeconds);
  XCTAssertNil(writeError);
  NSDictionary *query = @{
    @"schema_version" : @1,
    @"operation_id" : operationId,
    @"root" : DSHTestRoot(journal[@"workspace_id"],
                           journal[@"binding_revision"],
                           journal[@"project_id"]),
  };
  [self awaitCall:^(RishResolveBlock resolve, RishRejectBlock reject) {
    [self.module queryOperationRequest:query resolver:resolve rejecter:reject];
  } expectedValue:@{
    @"schema_version" : @1,
    @"operation_id" : operationId,
    @"status" : @"committed",
  } expectedCode:nil];
  [self awaitCall:^(RishResolveBlock resolve, RishRejectBlock reject) {
    [self.module cleanupOperationRequest:query resolver:resolve rejecter:reject];
  } expectedValue:@{
    @"schema_version" : @1,
    @"operation_id" : operationId,
    @"status" : @"cleaned",
  } expectedCode:nil];
}

- (void)testStagedCheckpointIsVisibleAfterJournalFsync {
  NSString *operationId = @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
  NSDictionary *journal = @{
    @"schema_version" : @1,
    @"operation_id" : operationId,
    @"request_sha256" : DSHTestDocumentDigest(@"import", operationId,
                                                @"44444444-4444-4444-8444-444444444444", @1,
                                                [NSNull null], @"", @[]),
    @"kind" : @"import",
    @"phase" : @"staged",
    @"workspace_id" : @"44444444-4444-4444-8444-444444444444",
    @"binding_revision" : @1,
    @"project_id" : [NSNull null],
    @"destination_path" : @"",
    @"source_paths" : @[],
    @"staging_name" : @"import-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    @"entry_names" : @[],
    @"entry_states" : @[],
    @"created_at" : @"2026-08-31T00:00:00.000Z",
    @"updated_at" : @"2026-08-31T00:00:00.000Z",
  };
  __block NSError *writeError = nil;
  dispatch_sync(self.module.documentQueue, ^{
    XCTAssertTrue([self.module saveStagingJournal:journal error:&writeError]);
  });
  XCTAssertNil(writeError);
  NSDictionary *query = @{
    @"schema_version" : @1,
    @"operation_id" : operationId,
    @"root" : DSHTestRoot(journal[@"workspace_id"],
                           journal[@"binding_revision"],
                           journal[@"project_id"]),
  };
  [self awaitCall:^(RishResolveBlock resolve, RishRejectBlock reject) {
    [self.module queryOperationRequest:query resolver:resolve rejecter:reject];
  } expectedValue:@{
    @"schema_version" : @1,
    @"operation_id" : operationId,
    @"status" : @"in_progress",
  } expectedCode:nil];
  [self awaitCall:^(RishResolveBlock resolve, RishRejectBlock reject) {
    [self.module cleanupOperationRequest:query resolver:resolve rejecter:reject];
  } expectedValue:@{
    @"schema_version" : @1,
    @"operation_id" : operationId,
    @"status" : @"cleaned",
  } expectedCode:nil];
}

- (void)testMixedImportJournalReconcilesAndCompletesRemainingPublish {
  NSDictionary *root = [self createWorkspaceRoot];
  if (root == nil) return;
  NSString *operationId = NSUUID.UUID.UUIDString.lowercaseString;
  __block NSURL *staging = nil;
  __block NSError *stageError = nil;
  dispatch_sync(self.module.documentQueue, ^{
    staging = [self.module newStagingDirectory:@"import"
                                    operationId:operationId
                                         error:&stageError];
  });
  XCTAssertNotNil(staging);
  XCTAssertNil(stageError);
  NSURL *workspace = [self ownedWorkspaceURL];
  NSURL *publishedURL = [workspace URLByAppendingPathComponent:@"published.txt"];
  NSURL *remainingURL = [staging URLByAppendingPathComponent:@"remaining.txt"];
  XCTAssertTrue(DSHTestWriteFile(publishedURL, @"already published"));
  XCTAssertTrue(DSHTestWriteFile(remainingURL, @"still staged"));
  struct stat publishedState = {}, remainingState = {};
  XCTAssertEqual(stat(publishedURL.fileSystemRepresentation, &publishedState), 0);
  XCTAssertEqual(stat(remainingURL.fileSystemRepresentation, &remainingState), 0);
  NSDictionary *journal = @{
    @"schema_version" : @1,
    @"operation_id" : operationId,
    @"request_sha256" : DSHTestDocumentDigest(@"import", operationId,
                                                root[@"workspace_id"], @1,
                                                root[@"project_id"], @"", @[]),
    @"kind" : @"import",
    @"phase" : @"publishing",
    @"workspace_id" : root[@"workspace_id"],
    @"binding_revision" : root[@"binding_revision"],
    @"project_id" : root[@"project_id"],
    @"destination_path" : @"",
    @"source_paths" : @[],
    @"staging_name" : staging.lastPathComponent,
    @"entry_names" : @[ @"published.txt", @"remaining.txt" ],
    @"entry_states" : @[
      DSHTestStateRecord(@"published.txt", publishedState),
      DSHTestStateRecord(@"remaining.txt", remainingState),
    ],
    @"created_at" : @"2026-08-31T00:00:00.000Z",
    @"updated_at" : @"2026-08-31T00:00:00.000Z",
  };
  __block NSError *reconcileError = nil;
  __block NSDictionary *reconciled = nil;
  dispatch_sync(self.module.documentQueue, ^{
    XCTAssertTrue([self.module saveStagingJournal:journal error:&reconcileError]);
    XCTAssertTrue([self.module reconcileJournal:journal error:&reconcileError]);
    reconciled = [self.module loadStagingJournal:&reconcileError];
  });
  XCTAssertNil(reconcileError);
  XCTAssertEqualObjects(reconciled[@"phase"], @"staged");
  NSDictionary *retryRequest = @{
    @"schema_version" : @1,
    @"operation_id" : operationId,
    @"root" : root,
  };
  [self awaitCall:^(RishResolveBlock resolve, RishRejectBlock reject) {
    [self.module retryOperationRequest:retryRequest resolver:resolve rejecter:reject];
  } expectedValue:@{
    @"schema_version" : @1,
    @"operation_id" : operationId,
    @"status" : @"committed",
  } expectedCode:nil];
  XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:publishedURL.path]);
  XCTAssertTrue([NSFileManager.defaultManager
                    fileExistsAtPath:[workspace URLByAppendingPathComponent:@"remaining.txt"].path]);
  XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:staging.path]);
  NSDictionary *query = @{
    @"schema_version" : @1,
    @"operation_id" : operationId,
    @"root" : root,
  };
  [self awaitCall:^(RishResolveBlock resolve, RishRejectBlock reject) {
    [self.module queryOperationRequest:query resolver:resolve rejecter:reject];
  } expectedValue:@{
    @"schema_version" : @1,
    @"operation_id" : operationId,
    @"status" : @"committed",
  } expectedCode:nil];
  [self awaitCall:^(RishResolveBlock resolve, RishRejectBlock reject) {
    [self.module cleanupOperationRequest:query resolver:resolve rejecter:reject];
  } expectedValue:@{
    @"schema_version" : @1,
    @"operation_id" : operationId,
    @"status" : @"cleaned",
  } expectedCode:nil];
}

- (void)testReceiptArchiveEvictsByBytesAndAllowsLaterOperation {
  NSDictionary *oldest = DSHTestLargeCommittedExport(
      @"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", 100, 255);
  NSDictionary *middle = DSHTestLargeCommittedExport(
      @"cccccccc-cccc-4ccc-8ccc-cccccccccccc", 100, 255);
  NSDictionary *newest = DSHTestLargeCommittedExport(
      @"dddddddd-dddd-4ddd-8ddd-dddddddddddd", 100, 255);
  __block NSError *error = nil;
  dispatch_sync(self.module.documentQueue, ^{
    BOOL saved = [self.module saveCommittedReceipts:@[oldest, middle] error:&error];
    XCTAssertTrue(saved);
    XCTAssertNil(error);
    BOOL archived = [self.module archiveCommittedJournal:newest error:&error];
    XCTAssertTrue(archived);
  });
  XCTAssertNil(error);
  __block NSArray<NSDictionary *> *receipts = nil;
  dispatch_sync(self.module.documentQueue, ^{
    receipts = [self.module loadCommittedReceipts:&error];
  });
  XCTAssertNil(error);
  NSMutableSet<NSString *> *operationIds = [NSMutableSet set];
  for (NSDictionary *receipt in receipts) [operationIds addObject:receipt[@"operation_id"]];
  XCTAssertFalse([operationIds containsObject:oldest[@"operation_id"]]);
  XCTAssertTrue([operationIds containsObject:middle[@"operation_id"]]);
  XCTAssertTrue([operationIds containsObject:newest[@"operation_id"]]);
  XCTAssertLessThanOrEqual(receipts.count, (NSUInteger)16);
  NSData *encoded = [NSJSONSerialization dataWithJSONObject:@{
    @"schema_version" : @1,
    @"receipts" : receipts,
  } options:NSJSONWritingSortedKeys error:nil];
  XCTAssertLessThanOrEqual(encoded.length, (NSUInteger)(64 * 1024));
  NSDictionary *huge = DSHTestLargeCommittedExport(
      @"ffffffff-ffff-4fff-8fff-ffffffffffff", 100, 1000);
  dispatch_sync(self.module.documentQueue, ^{
    XCTAssertTrue([self.module archiveCommittedJournal:huge error:&error]);
  });
  XCTAssertNil(error);
  dispatch_sync(self.module.documentQueue, ^{
    receipts = [self.module loadCommittedReceipts:&error];
  });
  XCTAssertNil(error);
  XCTAssertEqual(receipts.count, (NSUInteger)1);
  XCTAssertEqualObjects(receipts.firstObject[@"operation_id"], huge[@"operation_id"]);
  XCTAssertEqualObjects(receipts.firstObject[@"receipt_kind"], @"compact_terminal");
  NSDictionary *hugeCleanup = @{
    @"schema_version" : @1,
    @"operation_id" : huge[@"operation_id"],
    @"root" : DSHTestRoot(huge[@"workspace_id"],
                           huge[@"binding_revision"], huge[@"project_id"]),
  };
  [self awaitCall:^(RishResolveBlock resolve, RishRejectBlock reject) {
    [self.module cleanupOperationRequest:hugeCleanup resolver:resolve rejecter:reject];
  } expectedValue:@{
    @"schema_version" : @1,
    @"operation_id" : huge[@"operation_id"],
    @"status" : @"cleaned",
  } expectedCode:nil];
  NSString *laterOperationId = @"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  NSDictionary *laterJournal = @{
    @"schema_version" : @1,
    @"operation_id" : laterOperationId,
    @"request_sha256" : DSHTestDocumentDigest(@"import", laterOperationId,
                                                @"44444444-4444-4444-8444-444444444444", @1,
                                                [NSNull null], @"", @[]),
    @"kind" : @"import",
    @"phase" : @"prepared",
    @"workspace_id" : @"44444444-4444-4444-8444-444444444444",
    @"binding_revision" : @1,
    @"project_id" : [NSNull null],
    @"destination_path" : @"",
    @"source_paths" : @[],
    @"staging_name" : @"import-eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
    @"entry_names" : @[],
    @"entry_states" : @[],
    @"created_at" : @"2026-08-31T00:00:00.000Z",
    @"updated_at" : @"2026-08-31T00:00:00.000Z",
  };
  dispatch_sync(self.module.documentQueue, ^{
    XCTAssertTrue([self.module saveStagingJournal:laterJournal error:&error]);
  });
  XCTAssertNil(error);
  NSDictionary *cleanup = @{
    @"schema_version" : @1,
    @"operation_id" : laterOperationId,
    @"root" : DSHTestRoot(laterJournal[@"workspace_id"],
                           laterJournal[@"binding_revision"],
                           laterJournal[@"project_id"]),
  };
  [self awaitCall:^(RishResolveBlock resolve, RishRejectBlock reject) {
    [self.module cleanupOperationRequest:cleanup resolver:resolve rejecter:reject];
  } expectedValue:@{
    @"schema_version" : @1,
    @"operation_id" : laterOperationId,
    @"status" : @"cleaned",
  } expectedCode:nil];
}

- (void)testReplayRejectsSameOperationIdWhenExportPathsOrderOrCountChanges {
  NSDictionary *root = [self createWorkspaceRoot];
  if (root == nil) return;
  NSString *operationId = @"99999999-9999-4999-8999-999999999999";
  NSArray<NSString *> *originalPaths = @[ @"first.txt", @"second.txt" ];
  NSDictionary *journal = @{
    @"schema_version" : @1,
    @"operation_id" : operationId,
    @"request_sha256" : DSHTestDocumentDigest(@"export", operationId,
                                                root[@"workspace_id"], @1,
                                                root[@"project_id"], @"", originalPaths),
    @"kind" : @"export",
    @"phase" : @"committed",
    @"workspace_id" : root[@"workspace_id"],
    @"binding_revision" : root[@"binding_revision"],
    @"project_id" : root[@"project_id"],
    @"destination_path" : @"",
    @"source_paths" : originalPaths,
    @"staging_name" : [NSString stringWithFormat:@"export-%@", operationId],
    @"entry_names" : @[],
    @"entry_states" : @[],
    @"created_at" : @"2026-08-31T00:00:00.000Z",
    @"updated_at" : @"2026-08-31T00:00:00.000Z",
  };
  __block NSError *writeError = nil;
  dispatch_sync(self.module.documentQueue, ^{
    XCTAssertTrue([self.module saveStagingJournal:journal error:&writeError]);
  });
  XCTAssertNil(writeError);
  for (NSArray<NSString *> *replayedPaths in @[
    @[ @"second.txt", @"first.txt" ],
    @[ @"first.txt" ],
    @[ @"first.txt", @"second.txt", @"third.txt" ],
  ]) {
    NSDictionary *request = @{
      @"schema_version" : @1,
      @"root" : root,
      @"operation_id" : operationId,
      @"source_paths" : replayedPaths,
    };
    [self awaitCall:^(RishResolveBlock resolve, RishRejectBlock reject) {
      [self.module presentExportPickerRequest:request resolver:resolve rejecter:reject];
    } expectedValue:nil expectedCode:@"E_WORKSPACE_CONFLICT"];
  }
  NSDictionary *cleanup = @{
    @"schema_version" : @1,
    @"operation_id" : operationId,
    @"root" : root,
  };
  [self awaitCall:^(RishResolveBlock resolve, RishRejectBlock reject) {
    [self.module cleanupOperationRequest:cleanup resolver:resolve rejecter:reject];
  } expectedValue:@{
    @"schema_version" : @1,
    @"operation_id" : operationId,
    @"status" : @"cleaned",
  } expectedCode:nil];
}

- (void)testProjectBoundCommittedImportAndExportEchoExactRoot {
  NSDictionary *root = [self
      createProjectRootWithBindingProjectId:@"66666666-6666-4666-8666-666666666666"
                             driftOnResolve:0];
  if (root == nil) return;
  XCTAssertTrue(DSHTestWriteFile([[self ownedWorkspaceURL]
      URLByAppendingPathComponent:@"README.md"], @"project root"));
  NSString *importId = @"77777777-7777-4777-8777-777777777777";
  NSString *exportId = @"88888888-8888-4888-8888-888888888888";
  NSDictionary *importReceipt = @{
    @"schema_version" : @1,
    @"operation_id" : importId,
    @"request_sha256" : DSHTestDocumentDigest(
        @"import", importId, root[@"workspace_id"], root[@"binding_revision"],
        root[@"project_id"], @"", @[]),
    @"kind" : @"import",
    @"phase" : @"committed",
    @"workspace_id" : root[@"workspace_id"],
    @"binding_revision" : root[@"binding_revision"],
    @"project_id" : root[@"project_id"],
    @"destination_path" : @"",
    @"source_paths" : @[],
    @"staging_name" : @"import-77777777-7777-4777-8777-777777777777",
    @"entry_names" : @[],
    @"entry_states" : @[],
    @"created_at" : @"2026-08-31T00:00:00.000Z",
    @"updated_at" : @"2026-08-31T00:00:00.000Z",
  };
  NSArray *exportPaths = @[@"README.md"];
  NSDictionary *exportReceipt = @{
    @"schema_version" : @1,
    @"operation_id" : exportId,
    @"request_sha256" : DSHTestDocumentDigest(
        @"export", exportId, root[@"workspace_id"], root[@"binding_revision"],
        root[@"project_id"], @"", exportPaths),
    @"kind" : @"export",
    @"phase" : @"committed",
    @"workspace_id" : root[@"workspace_id"],
    @"binding_revision" : root[@"binding_revision"],
    @"project_id" : root[@"project_id"],
    @"destination_path" : @"",
    @"source_paths" : exportPaths,
    @"staging_name" : @"export-88888888-8888-4888-8888-888888888888",
    @"entry_names" : @[@"README.md"],
    @"entry_states" : @[],
    @"created_at" : @"2026-08-31T00:00:00.000Z",
    @"updated_at" : @"2026-08-31T00:00:00.000Z",
  };
  __block NSError *saveError = nil;
  NSArray<NSDictionary *> *receipts =
      [NSArray arrayWithObjects:importReceipt, exportReceipt, nil];
  dispatch_sync(self.module.documentQueue, ^{
    BOOL saved = [self.module saveCommittedReceipts:receipts error:&saveError];
    XCTAssertTrue(saved);
  });
  XCTAssertNil(saveError);

  NSDictionary *importRequest = @{
    @"schema_version" : @1,
    @"root" : root,
    @"operation_id" : importId,
    @"destination_path" : @"",
  };
  [self awaitCall:^(RishResolveBlock resolve, RishRejectBlock reject) {
    [self.module presentImportPickerRequest:importRequest resolver:resolve rejecter:reject];
  } expectedValue:@{
    @"schema_version" : @1,
    @"status" : @"imported",
    @"root" : root,
    @"operation_id" : importId,
    @"destination_path" : @"",
    @"entries" : @[],
  } expectedCode:nil];

  NSDictionary *exportRequest = @{
    @"schema_version" : @1,
    @"root" : root,
    @"operation_id" : exportId,
    @"source_paths" : exportPaths,
  };
  [self awaitCall:^(RishResolveBlock resolve, RishRejectBlock reject) {
    [self.module presentExportPickerRequest:exportRequest resolver:resolve rejecter:reject];
  } expectedValue:@{
    @"schema_version" : @1,
    @"status" : @"exported",
    @"root" : root,
    @"operation_id" : exportId,
    @"item_count" : @1,
  } expectedCode:nil];
}

- (void)testProjectBoundWrongProjectFailsBeforePicker {
  NSDictionary *wrongProjectRoot = [self
      createProjectRootWithBindingProjectId:@"99999999-9999-4999-8999-999999999999"
                             driftOnResolve:0];
  if (wrongProjectRoot == nil) return;
  NSDictionary *wrongRequest = @{
    @"schema_version" : @1,
    @"root" : wrongProjectRoot,
    @"operation_id" : @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    @"destination_path" : @"",
  };
  [self awaitCall:^(RishResolveBlock resolve, RishRejectBlock reject) {
    [self.module presentImportPickerRequest:wrongRequest resolver:resolve rejecter:reject];
  } expectedValue:nil expectedCode:@"E_WORKSPACE_ROOT_CHANGED"];
}

- (void)testProjectBoundStaleRevisionFailsBeforePicker {
  NSDictionary *staleRoot = [self
      createProjectRootWithBindingProjectId:@"66666666-6666-4666-8666-666666666666"
                             driftOnResolve:0];
  if (staleRoot == nil) return;
  NSMutableDictionary *stale = [staleRoot mutableCopy];
  stale[@"binding_revision"] = @2;
  NSDictionary *staleRequest = @{
    @"schema_version" : @1,
    @"root" : stale,
    @"operation_id" : @"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
    @"destination_path" : @"",
  };
  [self awaitCall:^(RishResolveBlock resolve, RishRejectBlock reject) {
    [self.module presentImportPickerRequest:staleRequest resolver:resolve rejecter:reject];
  } expectedValue:nil expectedCode:@"E_WORKSPACE_REVISION_STALE"];
}

- (void)testProjectRelationDriftAfterDestinationCheckFailsClosed {
  NSDictionary *root = [self
      createProjectRootWithBindingProjectId:@"66666666-6666-4666-8666-666666666666"
                             driftOnResolve:3];
  if (root == nil) return;
  NSDictionary *request = @{
    @"schema_version" : @1,
    @"root" : root,
    @"operation_id" : @"cccccccc-cccc-4ccc-8ccc-cccccccccccc",
    @"destination_path" : @"",
  };
  [self awaitCall:^(RishResolveBlock resolve, RishRejectBlock reject) {
    [self.module presentImportPickerRequest:request resolver:resolve rejecter:reject];
  } expectedValue:nil expectedCode:@"E_WORKSPACE_ROOT_CHANGED"];
}

- (void)testPickerControllerAndGenerationAreBoundExactlyOnce {
  UIDocumentPickerViewController *first = [[UIDocumentPickerViewController alloc]
      initForOpeningContentTypes:@[ UTTypeItem ] asCopy:YES];
  UIDocumentPickerViewController *second = [[UIDocumentPickerViewController alloc]
      initForOpeningContentTypes:@[ UTTypeItem ] asCopy:YES];
  [self.module setValue:@1 forKey:@"pendingMode"];
  [self.module setValue:@7 forKey:@"pendingGeneration"];
  [self.module setValue:first forKey:@"pendingController"];
  [self.module setValue:@NO forKey:@"pendingCallbackSettled"];
  XCTAssertFalse([self.module claimPendingCallbackForController:second generation:7]);
  XCTAssertFalse([self.module claimPendingCallbackForController:first generation:6]);
  XCTAssertTrue([self.module claimPendingCallbackForController:first generation:7]);
  XCTAssertFalse([self.module claimPendingCallbackForController:first generation:7]);
}

@end
