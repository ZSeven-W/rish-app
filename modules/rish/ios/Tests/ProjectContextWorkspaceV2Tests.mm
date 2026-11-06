#import "../../../../modules/rish/ios/Sources/ProviderConfiguration.h"
#import <XCTest/XCTest.h>

#import "../../../../modules/rish/ios/Sources/ProjectContextPolicy.h"
#import "../../../../modules/rish/ios/Sources/ProjectContextService.h"
#import "../../../../modules/rish/ios/Sources/ProjectContextStore.h"
#import "../../../../modules/rish/ios/Sources/LocalWorkspaceAccess.h"

#include <git2.h>
#include <sys/stat.h>
#include <unistd.h>

@interface NSObject (CustomProviderContextModuleTesting)
- (instancetype)initWithService:(DSHProjectContextService *)service operationQueue:(dispatch_queue_t)queue maxPending:(NSUInteger)pending;
- (void)prepareCandidateV2Request:(id)request resolver:(void (^)(id))resolve rejecter:(void (^)(NSString *, NSString *, NSError *))reject;
@end

@interface ProjectContextWorkspaceV2Tests : XCTestCase
@property(nonatomic, strong) DSHProjectContextService *service;
@property(nonatomic, strong) DSHProjectContextStore *store;
@property(nonatomic, strong) NSURL *rootURL;
@end

@implementation ProjectContextWorkspaceV2Tests

- (void)setUp {
  [super setUp];
  self.rootURL = [NSURL fileURLWithPath:
      [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
                                      isDirectory:YES];
  self.store = [[DSHProjectContextStore alloc]
      initWithRootURL:self.rootURL
       capacityBytes:64 * 1024 * 1024
               clock:^NSDate *{
                 return NSDate.date;
               }
 identifierGenerator:^NSString *{
                 return @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
               }];
  self.service = [[DSHProjectContextService alloc]
      initWithProjectAccess:[[DSHLocalProjectAccess alloc]
                                initWithProjectsRootURL:nil]
             workspaceAccess:nil
                       store:self.store
                      policy:[[DSHProjectContextPolicy alloc] init]
                       clock:^NSDate *{
                         return NSDate.date;
                       }
         identifierGenerator:^NSString *{
           return @"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
         }
                        hook:nil];
}

- (void)tearDown {
  self.service = nil;
  self.store = nil;
  [[NSFileManager defaultManager] removeItemAtURL:self.rootURL error:nil];
  self.rootURL = nil;
  [super tearDown];
}

- (NSDictionary *)root {
  return @{
    @"schema_version" : @1,
    @"workspace_id" : @"11111111-1111-4111-8111-111111111111",
    @"binding_revision" : @1,
    @"project_id" : @"22222222-2222-4222-8222-222222222222",
  };
}

- (NSURL *)makePrivateSplitFixtureWithProjectId:(NSString *)projectId
                                      bindingProjectId:(NSString *)bindingProjectId
                                       workspaceAccess:(DSHLocalWorkspaceAccess **)accessOut
                                        projectAccess:(DSHLocalProjectAccess **)projectAccessOut
                                                  root:(NSDictionary **)rootOut
                                             rootURL:(NSURL **)rootURLOut
                                              gitURL:(NSURL **)gitURLOut {
  NSURL *baseURL = [NSURL fileURLWithPath:
      [NSTemporaryDirectory() stringByAppendingPathComponent:
          NSUUID.UUID.UUIDString.lowercaseString]
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
      createRishOwnedWorkspaceWithDisplayName:@"V2 Context Fixture"
                                  operationId:NSUUID.UUID.UUIDString.lowercaseString
                                        error:&error];
  XCTAssertNotNil(workspace, @"%@", error);
  NSURL *rootURL = [[[documentsRoot
      URLByAppendingPathComponent:@"Rish Workspaces" isDirectory:YES]
      URLByAppendingPathComponent:@"V2 Context Fixture" isDirectory:YES]
      URLByStandardizingPath];
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
  XCTAssertGreaterThan(git_libgit2_init(), 0);
  XCTAssertEqual(git_repository_init_ext(&repository,
                                         gitURL.fileSystemRepresentation,
                                         &options), 0);
  XCTAssertNotEqual(repository, nullptr);
  if (repository == nullptr) return nil;
  NSData *readmeData = [@"context fixture\n"
      dataUsingEncoding:NSUTF8StringEncoding];
  XCTAssertTrue([readmeData writeToURL:
      [rootURL URLByAppendingPathComponent:@"README.md"] atomically:YES]);
  XCTAssertEqual(git_repository_set_workdir(repository,
                                             rootURL.fileSystemRepresentation,
                                             0), 0);
  git_index *index = nullptr;
  XCTAssertEqual(git_repository_index(&index, repository), 0);
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
          @"display_name" : @"V2 Context Fixture",
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

- (DSHProjectContextStore *)storeAtURL:(NSURL *)url {
  __block NSUInteger identifierCount = 0;
  DSHProjectContextClock clock = ^NSDate * {
    return [NSDate dateWithTimeIntervalSince1970:1'777'777'777.125];
  };
  DSHProjectContextIdentifierGenerator generator = ^NSString * {
    NSUInteger next = ++identifierCount;
    return [NSString stringWithFormat:
        @"aaaaaaaa-aaaa-4aaa-8aaa-%012lu", (unsigned long)next];
  };
  return [[DSHProjectContextStore alloc]
      initWithRootURL:url
       capacityBytes:64 * 1024 * 1024
               clock:clock
 identifierGenerator:generator];
}

- (void)replaceDirectoryAtURL:(NSURL *)url {
  NSURL *oldURL = [url.URLByDeletingLastPathComponent
      URLByAppendingPathComponent:
          [url.lastPathComponent stringByAppendingString:@".old"]
                    isDirectory:YES];
  unlink(oldURL.fileSystemRepresentation);
  XCTAssertEqual(rename(url.fileSystemRepresentation, oldURL.fileSystemRepresentation),
                 0);
  XCTAssertEqual(mkdir(url.fileSystemRepresentation, 0700), 0);
}

- (DSHProjectContextService *)serviceWithProjectAccess:(DSHLocalProjectAccess *)projectAccess
                                       workspaceAccess:(DSHLocalWorkspaceAccess *)workspaceAccess
                                                 store:(DSHProjectContextStore *)store
                                                  hook:(DSHProjectContextServiceHook)hook
                                                prefix:(NSString *)prefix {
  __block NSUInteger identifierCount = 0;
  DSHProjectContextIdentifierGenerator generator = ^NSString * {
    NSUInteger next = ++identifierCount;
    return [NSString stringWithFormat:
        @"%@-aaaa-4aaa-8aaa-%012lu", prefix, (unsigned long)next];
  };
  DSHProjectContextClock clock = ^NSDate * {
    return [NSDate dateWithTimeIntervalSince1970:1'777'777'777.125];
  };
  return [[DSHProjectContextService alloc]
      initWithProjectAccess:projectAccess
             workspaceAccess:workspaceAccess
                       store:store
                      policy:[[DSHProjectContextPolicy alloc] init]
                       clock:clock
         identifierGenerator:generator
                        hook:hook];
}

- (NSDictionary *)storedReferencesAtStore:(DSHProjectContextStore *)store {
  NSData *data = [NSData dataWithContentsOfURL:
      [store.rootURL URLByAppendingPathComponent:@"references.json"]];
  if (data == nil) return @{};
  NSDictionary *references = [NSJSONSerialization JSONObjectWithData:data
                                                               options:0
                                                                 error:nil];
  return [references isKindOfClass:NSDictionary.class] ? references : @{};
}

- (void)testV2PreparationFailsClosedWithoutWorkspaceLeaseResolver {
  NSDictionary *request = @{
    @"schema_version" : @2,
    @"root" : [self root],
    @"conversation_id" : @"33333333-3333-4333-8333-333333333333",
    @"model_id" : @"deepseek-v4-flash",
    @"policy" : @"chat-read-v1",
    @"selected_paths" : @[],
  };
  NSError *error = nil;
  XCTAssertNil([self.service prepareCandidateV2:request error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextServiceErrorInvalidArgument);
}

- (void)testSharedProductionServiceOwnsARealWorkspaceAccess {
  DSHProjectContextService *shared = DSHSharedProjectContextService();
  XCTAssertNotNil(shared);
  XCTAssertNotNil([shared valueForKey:@"workspaceAccess"]);
}

- (void)testV2RequestsRejectProjectOnlyAndPathBearingAuthorityObjects {
  NSDictionary *badRoot = @{
    @"schema_version" : @1,
    @"workspace_id" : @"11111111-1111-4111-8111-111111111111",
    @"binding_revision" : @1,
    @"project_id" : @"22222222-2222-4222-8222-222222222222",
    @"root_path" : @"/private/not-authority",
  };
  NSDictionary *request = @{
    @"schema_version" : @1,
    @"root" : badRoot,
    @"query" : @"",
    @"cursor" : NSNull.null,
  };
  NSError *error = nil;
  XCTAssertNil([self.service listCandidatesV2:request error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextServiceErrorInvalidArgument);
  error = nil;
  NSDictionary *invalidDiscardRequest = @{
    @"schema_version" : @2,
    @"snapshot_id" : @"33333333-3333-4333-8333-333333333333",
    @"root" : badRoot,
  };
  XCTAssertNil([self.service discardSnapshotV2:invalidDiscardRequest
                                         error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextServiceErrorInvalidArgument);
}

- (void)testFrozenAgentContextPreservesBytesAfterWriteAndRejectsChangedRootOrConsent {
  DSHLocalWorkspaceAccess *workspaceAccess = nil;
  DSHLocalProjectAccess *projectAccess = nil;
  NSDictionary *root = nil;
  NSURL *workspaceRootURL = nil;
  NSURL *gitURL = nil;
  NSURL *baseURL = [self makePrivateSplitFixtureWithProjectId:
      @"33333333-3333-4333-8333-333333333333"
      bindingProjectId:@"33333333-3333-4333-8333-333333333333"
      workspaceAccess:&workspaceAccess projectAccess:&projectAccess
      root:&root rootURL:&workspaceRootURL gitURL:&gitURL];
  DSHProjectContextStore *store = [self storeAtURL:
      [baseURL URLByAppendingPathComponent:@"store" isDirectory:YES]];
  DSHProjectContextService *service = [self serviceWithProjectAccess:projectAccess
      workspaceAccess:workspaceAccess store:store hook:nil prefix:@"cccccccc"];
  NSString *conversation = @"44444444-4444-4444-8444-444444444444";
  NSError *error = nil;
  NSDictionary *manifest = [service prepareCandidateV2WithRoot:root
      conversationId:conversation modelId:@"deepseek-v4-flash" policy:@"chat-read-v1"
      selectedPaths:@[@"README.md"] error:&error];
  NSDictionary *consent = [service confirmSnapshotV2Id:manifest[@"snapshot_id"]
      root:root error:&error];
  XCTAssertNotNil(consent, @"%@", error);
  NSDictionary *request = @{
    @"schema_version": @2, @"snapshot_id": manifest[@"snapshot_id"],
    @"consent_receipt_id": consent[@"consent_receipt_id"], @"root": root,
    @"conversation_id": conversation, @"model_id": @"deepseek-v4-flash",
    @"policy": @"chat-read-v1",
  };
  NSData *original = [service verifiedEnvelopeV2:request receipt:nil error:&error];
  XCTAssertNotNil(original, @"%@", error);
  XCTAssertTrue([[@"Changed by approved Agent tool\n" dataUsingEncoding:NSUTF8StringEncoding]
      writeToURL:[workspaceRootURL URLByAppendingPathComponent:@"README.md"] atomically:YES]);
  error = nil;
  XCTAssertNil([service verifiedEnvelopeV2:request receipt:nil error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextServiceErrorChanged);
  error = nil;
  NSDictionary *receipt = nil;
  NSData *continued = [service verifiedFrozenEnvelopeV2:request receipt:&receipt error:&error];
  XCTAssertEqualObjects(continued, original, @"%@", error);
  XCTAssertEqualObjects(receipt[@"snapshot_sha256"], manifest[@"snapshot_sha256"]);
  NSMutableDictionary *wrongConsent = [request mutableCopy];
  wrongConsent[@"consent_receipt_id"] = @"99999999-9999-4999-8999-999999999999";
  XCTAssertNil([service verifiedFrozenEnvelopeV2:wrongConsent receipt:nil error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextServiceErrorConsent);
  [self replaceDirectoryAtURL:workspaceRootURL];
  error = nil;
  XCTAssertNil([service verifiedFrozenEnvelopeV2:request receipt:nil error:&error]);
  XCTAssertNotNil(error);
  [[NSFileManager defaultManager] removeItemAtURL:baseURL error:nil];
  (void)gitURL;
}

- (void)testRealV2SnapshotConsentInspectAndVerifiedSendLifecycle {
  DSHLocalWorkspaceAccess *workspaceAccess = nil;
  DSHLocalProjectAccess *projectAccess = nil;
  NSDictionary *root = nil;
  NSURL *workspaceRootURL = nil;
  NSURL *gitURL = nil;
  NSURL *baseURL = [self makePrivateSplitFixtureWithProjectId:
      @"33333333-3333-4333-8333-333333333333"
      bindingProjectId:@"33333333-3333-4333-8333-333333333333"
      workspaceAccess:&workspaceAccess
      projectAccess:&projectAccess
      root:&root
      rootURL:&workspaceRootURL
      gitURL:&gitURL];
  if (baseURL == nil) return;
  DSHProjectContextStore *store = [self storeAtURL:
      [baseURL URLByAppendingPathComponent:@"store" isDirectory:YES]];
  DSHProjectContextService *service = [self
      serviceWithProjectAccess:projectAccess
                workspaceAccess:workspaceAccess
                          store:store
                           hook:nil
                         prefix:@"bbbbbbbb"];
  NSError *error = nil;
  NSDictionary *list = [service listCandidatesV2:@{
    @"schema_version" : @1,
    @"root" : root,
    @"query" : @"",
    @"cursor" : NSNull.null,
  } error:&error];
  XCTAssertNotNil(list, @"%@", error);
  XCTAssertEqualObjects(list[@"root"], root);
  XCTAssertEqualObjects(list[@"project"][@"git_topology"],
                        @"private_split_gitdir");
  XCTAssertGreaterThanOrEqual([list[@"candidates"] count], (NSUInteger)1);

  NSString *conversation = @"44444444-4444-4444-8444-444444444444";
  NSDictionary *manifest = [service
      prepareCandidateV2WithRoot:root
                   conversationId:conversation
                          modelId:@"deepseek-v4-flash"
                           policy:@"chat-read-v1"
                    selectedPaths:@[@"README.md"]
                            error:&error];
  XCTAssertNotNil(manifest, @"%@", error);
  XCTAssertEqualObjects(manifest[@"root"], root);
  XCTAssertEqualObjects(manifest[@"project"][ @"git_topology"],
                        @"private_split_gitdir");
  XCTAssertEqualObjects(manifest[@"project_id"], root[@"project_id"]);
  NSDictionary *storedSnapshot = [store loadSnapshotId:manifest[@"snapshot_id"]
                                                  error:&error];
  XCTAssertNotNil(storedSnapshot, @"%@", error);
  for (NSString *key in @[
    @"root_device", @"root_inode", @"repository_device",
    @"repository_inode", @"git_device", @"git_inode",
    @"objects_device", @"objects_inode"
  ]) {
    XCTAssertTrue([storedSnapshot[@"source_descriptor"][key]
        isKindOfClass:NSString.class], @"%@ must round-trip as a string", key);
  }

  NSDictionary *consent = [service confirmSnapshotV2Id:manifest[@"snapshot_id"]
                                                   root:root
                                                  error:&error];
  XCTAssertNotNil(consent, @"%@", error);
  XCTAssertEqualObjects(consent[@"root"], root);
  XCTAssertNotNil(consent[@"consent_receipt_id"]);
  NSDictionary *inspection = [service
      inspectSnapshotV2Id:manifest[@"snapshot_id"] root:root error:&error];
  XCTAssertEqualObjects(inspection[@"state"], @"confirmed");

  NSDictionary *verifiedReceipt = nil;
  NSData *envelope = [service
      verifiedEnvelopeV2ForSnapshotId:manifest[@"snapshot_id"]
                     consentReceiptId:consent[@"consent_receipt_id"]
                                  root:root
                        conversationId:conversation
                               modelId:@"deepseek-v4-flash"
                                policy:@"chat-read-v1"
                               receipt:&verifiedReceipt
                                 error:&error];
  XCTAssertNotNil(envelope, @"%@", error);
  XCTAssertNotNil(verifiedReceipt);
  XCTAssertEqualObjects(verifiedReceipt[@"root"], root);
  NSString *wire = [[NSString alloc] initWithData:envelope
                                           encoding:NSUTF8StringEncoding];
  XCTAssertTrue([wire hasPrefix:@"RISH-PROJECT-CONTEXT/2\n"]);
  NSString *receiptJSON = [[NSString alloc]
      initWithData:[NSJSONSerialization dataWithJSONObject:verifiedReceipt
                                                    options:0
                                                      error:nil]
           encoding:NSUTF8StringEncoding];
  XCTAssertFalse([receiptJSON containsString:workspaceRootURL.path]);
  XCTAssertFalse([receiptJSON containsString:gitURL.path]);
  NSDictionary *discard = [service
      discardSnapshotV2Id:manifest[@"snapshot_id"]
                     root:root
                    error:&error];
  XCTAssertNotNil(discard, @"%@", error);
  XCTAssertEqualObjects(discard[@"status"], @"discarded");
  XCTAssertEqualObjects(discard[@"root"], root);
  XCTAssertNil([store loadSnapshotId:manifest[@"snapshot_id"] error:nil]);
  error = nil;
  XCTAssertNil([service inspectSnapshotV2Id:manifest[@"snapshot_id"]
                                      root:root
                                     error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextServiceErrorSnapshotMissing);
  [[NSFileManager defaultManager] removeItemAtURL:baseURL error:nil];
}

- (void)testSameConversationAcrossWorkspacesKeepsIndependentSnapshots {
  NSString *projectId = @"55555555-5555-4555-8555-555555555555";
  DSHLocalWorkspaceAccess *workspaceAccessOne = nil;
  DSHLocalProjectAccess *projectAccessOne = nil;
  NSDictionary *rootOne = nil;
  NSURL *rootURLOne = nil;
  NSURL *gitURLOne = nil;
  NSURL *baseURLOne = [self makePrivateSplitFixtureWithProjectId:projectId
      bindingProjectId:projectId
      workspaceAccess:&workspaceAccessOne
      projectAccess:&projectAccessOne
      root:&rootOne
      rootURL:&rootURLOne
      gitURL:&gitURLOne];
  DSHLocalWorkspaceAccess *workspaceAccessTwo = nil;
  DSHLocalProjectAccess *projectAccessTwo = nil;
  NSDictionary *rootTwo = nil;
  NSURL *rootURLTwo = nil;
  NSURL *gitURLTwo = nil;
  NSURL *baseURLTwo = [self makePrivateSplitFixtureWithProjectId:projectId
      bindingProjectId:projectId
      workspaceAccess:&workspaceAccessTwo
      projectAccess:&projectAccessTwo
      root:&rootTwo
      rootURL:&rootURLTwo
      gitURL:&gitURLTwo];
  if (baseURLOne == nil || baseURLTwo == nil) return;
  XCTAssertFalse([rootOne[@"workspace_id"] isEqual:rootTwo[@"workspace_id"]]);
  NSURL *storeURL = [baseURLOne URLByAppendingPathComponent:@"shared-store"
                                                   isDirectory:YES];
  DSHProjectContextStore *store = [self storeAtURL:storeURL];
  DSHProjectContextService *serviceOne = [self
      serviceWithProjectAccess:projectAccessOne
                workspaceAccess:workspaceAccessOne
                          store:store
                           hook:nil
                         prefix:@"bbbbbbbb"];
  DSHProjectContextService *serviceTwo = [self
      serviceWithProjectAccess:projectAccessTwo
                workspaceAccess:workspaceAccessTwo
                          store:store
                           hook:nil
                         prefix:@"cccccccc"];
  NSString *conversation = @"66666666-6666-4666-8666-666666666666";
  NSError *error = nil;
  NSDictionary *first = [serviceOne
      prepareCandidateV2WithRoot:rootOne
                   conversationId:conversation
                          modelId:@"deepseek-v4-flash"
                           policy:@"chat-read-v1"
                    selectedPaths:@[@"README.md"]
                            error:&error];
  XCTAssertNotNil(first, @"%@", error);
  NSDictionary *second = [serviceTwo
      prepareCandidateV2WithRoot:rootTwo
                   conversationId:conversation
                          modelId:@"deepseek-v4-flash"
                           policy:@"chat-read-v1"
                    selectedPaths:@[@"README.md"]
                            error:&error];
  XCTAssertNotNil(second, @"%@", error);
  XCTAssertFalse([first[@"snapshot_id"] isEqual:second[@"snapshot_id"]]);
  XCTAssertNotNil([store loadSnapshotId:first[@"snapshot_id"] error:&error]);
  XCTAssertNotNil([store loadSnapshotId:second[@"snapshot_id"] error:&error]);
  NSDictionary *references = [self storedReferencesAtStore:store];
  NSPredicate *active = [NSPredicate predicateWithBlock:
      ^BOOL(NSString *key, NSDictionary *bindings) {
        (void)bindings;
        return [key hasPrefix:@"active:"];
      }];
  XCTAssertEqual([references.allKeys filteredArrayUsingPredicate:active].count,
                 (NSUInteger)2);
  NSDictionary *firstInspection = [serviceOne
      inspectSnapshotV2Id:first[@"snapshot_id"] root:rootOne error:&error];
  XCTAssertEqualObjects(firstInspection[@"state"], @"prepared");
  error = nil;
  XCTAssertNil([serviceOne discardSnapshotV2Id:first[@"snapshot_id"]
                                          root:rootTwo
                                         error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextServiceErrorChanged);
  XCTAssertNotNil([store loadSnapshotId:first[@"snapshot_id"] error:&error]);
  NSDictionary *discarded = [serviceOne
      discardSnapshotV2Id:first[@"snapshot_id"]
                     root:rootOne
                    error:&error];
  XCTAssertNotNil(discarded, @"%@", error);
  XCTAssertEqualObjects(discarded[@"status"], @"discarded");
  XCTAssertNil([store loadSnapshotId:first[@"snapshot_id"] error:nil]);
  NSDictionary *secondInspection = [serviceTwo
      inspectSnapshotV2Id:second[@"snapshot_id"] root:rootTwo error:&error];
  XCTAssertEqualObjects(secondInspection[@"state"], @"prepared");
  XCTAssertNotNil([store loadSnapshotId:second[@"snapshot_id"] error:&error]);
  XCTAssertEqual([[self storedReferencesAtStore:store].allKeys
                     filteredArrayUsingPredicate:active].count,
                 (NSUInteger)1);
  [[NSFileManager defaultManager] removeItemAtURL:baseURLOne error:nil];
  [[NSFileManager defaultManager] removeItemAtURL:baseURLTwo error:nil];
  (void)rootURLOne;
  (void)rootURLTwo;
  (void)gitURLOne;
  (void)gitURLTwo;
}

- (void)testPrepareCasRaceRevalidatesRootAndAbortsTransaction {
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
  DSHProjectContextStore *store = [self storeAtURL:
      [baseURL URLByAppendingPathComponent:@"store" isDirectory:YES]];
  __block BOOL replaced = NO;
  DSHProjectContextService *service = [self
      serviceWithProjectAccess:projectAccess
                workspaceAccess:workspaceAccess
                          store:store
                           hook:^(NSString *stage, __unused NSString *path) {
                             if (!replaced && [stage isEqual:@"after_v2_store_cas"]) {
                               replaced = YES;
                               [self replaceDirectoryAtURL:rootURL];
                             }
                           }
                         prefix:@"dddddddd"];
  NSError *error = nil;
  NSDictionary *manifest = [service
      prepareCandidateV2WithRoot:root
                   conversationId:@"88888888-8888-4888-8888-888888888888"
                          modelId:@"deepseek-v4-flash"
                           policy:@"chat-read-v1"
                    selectedPaths:@[@"README.md"]
                            error:&error];
  XCTAssertNil(manifest);
  XCTAssertTrue(replaced);
  XCTAssertEqual(error.code, DSHProjectContextServiceErrorChanged);
  NSURL *snapshotsURL = [store.rootURL URLByAppendingPathComponent:@"snapshots"
                                                          isDirectory:YES];
  NSArray *snapshots = [[NSFileManager defaultManager]
      contentsOfDirectoryAtURL:snapshotsURL
      includingPropertiesForKeys:nil
                         options:NSDirectoryEnumerationSkipsHiddenFiles
                           error:nil];
  XCTAssertEqual(snapshots.count, (NSUInteger)0);
  [[NSFileManager defaultManager] removeItemAtURL:baseURL error:nil];
  (void)gitURL;
}

- (void)testVerifiedSendTerminalRecheckRejectsRootReplacement {
  DSHLocalWorkspaceAccess *workspaceAccess = nil;
  DSHLocalProjectAccess *projectAccess = nil;
  NSDictionary *root = nil;
  NSURL *rootURL = nil;
  NSURL *gitURL = nil;
  NSURL *baseURL = [self makePrivateSplitFixtureWithProjectId:
      @"99999999-9999-4999-8999-999999999999"
      bindingProjectId:@"99999999-9999-4999-8999-999999999999"
      workspaceAccess:&workspaceAccess
      projectAccess:&projectAccess
      root:&root
      rootURL:&rootURL
      gitURL:&gitURL];
  if (baseURL == nil) return;
  DSHProjectContextStore *store = [self storeAtURL:
      [baseURL URLByAppendingPathComponent:@"store" isDirectory:YES]];
  __block BOOL replaceOnTerminal = NO;
  DSHProjectContextService *service = [self
      serviceWithProjectAccess:projectAccess
                workspaceAccess:workspaceAccess
                          store:store
                           hook:^(NSString *stage, __unused NSString *path) {
                             if (replaceOnTerminal &&
                                 [stage isEqual:@"after_v2_authorization_complete"]) {
                               replaceOnTerminal = NO;
                               [self replaceDirectoryAtURL:rootURL];
                             }
                           }
                         prefix:@"eeeeeeee"];
  NSError *error = nil;
  NSString *conversation = @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
  NSDictionary *manifest = [service
      prepareCandidateV2WithRoot:root
                   conversationId:conversation
                          modelId:@"deepseek-v4-flash"
                           policy:@"chat-read-v1"
                    selectedPaths:@[@"README.md"]
                            error:&error];
  XCTAssertNotNil(manifest, @"%@", error);
  NSDictionary *consent = [service confirmSnapshotV2Id:manifest[@"snapshot_id"]
                                                   root:root
                                                  error:&error];
  XCTAssertNotNil(consent, @"%@", error);
  replaceOnTerminal = YES;
  NSDictionary *receipt = nil;
  NSData *verified = [service
      verifiedEnvelopeV2ForSnapshotId:manifest[@"snapshot_id"]
                     consentReceiptId:consent[@"consent_receipt_id"]
                                  root:root
                        conversationId:conversation
                               modelId:@"deepseek-v4-flash"
                                policy:@"chat-read-v1"
                               receipt:&receipt
                                 error:&error];
  XCTAssertNil(verified);
  XCTAssertNil(receipt);
  XCTAssertEqual(error.code, DSHProjectContextServiceErrorChanged);
  [[NSFileManager defaultManager] removeItemAtURL:baseURL error:nil];
  (void)gitURL;
}

- (void)testDiscardV2TerminalRecheckRejectsRootReplacement {
  DSHLocalWorkspaceAccess *workspaceAccess = nil;
  DSHLocalProjectAccess *projectAccess = nil;
  NSDictionary *root = nil;
  NSURL *rootURL = nil;
  NSURL *gitURL = nil;
  NSURL *baseURL = [self makePrivateSplitFixtureWithProjectId:
      @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
      bindingProjectId:@"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
      workspaceAccess:&workspaceAccess
      projectAccess:&projectAccess
      root:&root
      rootURL:&rootURL
      gitURL:&gitURL];
  if (baseURL == nil) return;
  DSHProjectContextStore *store = [self storeAtURL:
      [baseURL URLByAppendingPathComponent:@"store" isDirectory:YES]];
  __block BOOL replaceOnDiscard = NO;
  DSHProjectContextService *service = [self
      serviceWithProjectAccess:projectAccess
                workspaceAccess:workspaceAccess
                          store:store
                           hook:^(NSString *stage, __unused NSString *path) {
                             if (replaceOnDiscard &&
                                 [stage isEqual:@"after_v2_discard"]) {
                               replaceOnDiscard = NO;
                               [self replaceDirectoryAtURL:rootURL];
                             }
                           }
                         prefix:@"ffffffff"];
  NSError *error = nil;
  NSDictionary *manifest = [service
      prepareCandidateV2WithRoot:root
                   conversationId:@"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
                          modelId:@"deepseek-v4-flash"
                           policy:@"chat-read-v1"
                    selectedPaths:@[@"README.md"]
                            error:&error];
  XCTAssertNotNil(manifest, @"%@", error);
  replaceOnDiscard = YES;
  NSDictionary *discard = [service
      discardSnapshotV2Id:manifest[@"snapshot_id"]
                     root:root
                    error:&error];
  XCTAssertNil(discard);
  XCTAssertEqual(error.code, DSHProjectContextServiceErrorChanged);
  XCTAssertNil([store loadSnapshotId:manifest[@"snapshot_id"] error:nil]);
  [[NSFileManager defaultManager] removeItemAtURL:baseURL error:nil];
  (void)gitURL;
}

- (void)testLegacyProjectCandidatesPrepareAndConsentUseBorrowedRepositoryFD {
  NSURL *base = [NSURL fileURLWithPath:[NSTemporaryDirectory()
      stringByAppendingPathComponent:[@"context-legacy-" stringByAppendingString:
          NSUUID.UUID.UUIDString.lowercaseString]] isDirectory:YES];
  NSURL *privateURL = [base URLByAppendingPathComponent:@"private" isDirectory:YES];
  NSURL *documents = [base URLByAppendingPathComponent:@"documents" isDirectory:YES];
  NSURL *projects = [base URLByAppendingPathComponent:@"projects" isDirectory:YES];
  NSString *projectId = @"12121212-1212-4212-8212-121212121212";
  NSURL *project = [projects URLByAppendingPathComponent:projectId isDirectory:YES];
  NSURL *repositoryURL = [project URLByAppendingPathComponent:@"repo" isDirectory:YES];
  for (NSURL *url in @[privateURL, documents, repositoryURL]) {
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:url
                                         withIntermediateDirectories:YES
                                                          attributes:@{NSFilePosixPermissions : @0700}
                                                               error:nil]);
  }
  NSData *metadata = [NSJSONSerialization dataWithJSONObject:@{
    @"schema_version" : @1, @"name" : @"Legacy Context",
    @"created_at" : @"2026-09-01T00:00:00.000Z",
    @"updated_at" : @"2026-09-01T00:00:00.000Z",
    @"origin_url" : NSNull.null,
  } options:0 error:nil];
  XCTAssertTrue([metadata writeToURL:[project URLByAppendingPathComponent:@"project.json"]
                            atomically:YES]);
  XCTAssertTrue([[@"legacy context\n" dataUsingEncoding:NSUTF8StringEncoding]
      writeToURL:[repositoryURL URLByAppendingPathComponent:@"README.md"]
      atomically:YES]);
  XCTAssertGreaterThan(git_libgit2_init(), 0);
  git_repository *repository = nullptr;
  XCTAssertEqual(git_repository_init(&repository,
                                      repositoryURL.fileSystemRepresentation, 0), 0);
  git_index *index = nullptr;
  XCTAssertEqual(git_repository_index(&index, repository), 0);
  XCTAssertEqual(git_index_add_bypath(index, "README.md"), 0);
  XCTAssertEqual(git_index_write(index), 0);
  git_oid treeOid = {}, commitOid = {};
  git_tree *tree = nullptr;
  git_signature *signature = nullptr;
  XCTAssertEqual(git_index_write_tree(&treeOid, index), 0);
  XCTAssertEqual(git_tree_lookup(&tree, repository, &treeOid), 0);
  XCTAssertEqual(git_signature_new(&signature, "Legacy", "legacy@example.invalid",
                                   1'788'220'800, 0), 0);
  XCTAssertEqual(git_commit_create(&commitOid, repository, "HEAD", signature,
      signature, "UTF-8", "fixture", tree, 0, nullptr), 0);
  if (signature != nullptr) git_signature_free(signature);
  if (tree != nullptr) git_tree_free(tree);
  if (index != nullptr) git_index_free(index);
  if (repository != nullptr) git_repository_free(repository);

  DSHLocalProjectAccess *projectAccess = [[DSHLocalProjectAccess alloc]
      initWithProjectsRootURL:projects hook:nil];
  __block BOOL drift = NO;
  NSString *workspaceId = @"34343434-3434-4434-8434-343434343434";
  DSHLocalWorkspaceAccess *workspaceAccess = [[DSHLocalWorkspaceAccess alloc]
      initWithPrivateRootURL:privateURL documentsRootURL:documents
      clock:^NSDate *{ return NSDate.date; }
      UUIDGenerator:^NSString *{ return workspaceId; }
      legacyResolver:^BOOL(NSString *resolvedProjectId, NSDictionary **evidence,
                           NSError **resolverError) {
        NSDictionary *resolved = [projectAccess
            legacyWorkspaceBootstrapEvidenceForProjectId:resolvedProjectId
                                                     error:resolverError];
        if (resolved != nil && drift) {
          NSMutableDictionary *changed = [resolved mutableCopy];
          changed[@"repository_inode_id"] = @"1";
          resolved = changed;
        }
        if (evidence != nil) *evidence = resolved;
        return resolved != nil;
      } faultHook:nil];
  NSError *error = nil;
  XCTAssertNotNil([workspaceAccess bootstrapLegacyProjectId:projectId
      operationId:@"56565656-5656-4656-8656-565656565656" error:&error], @"%@", error);
  NSDictionary *root = @{
    @"schema_version" : @1, @"workspace_id" : workspaceId,
    @"binding_revision" : @1, @"project_id" : projectId,
  };
  DSHProjectContextStore *store = [self storeAtURL:
      [base URLByAppendingPathComponent:@"store" isDirectory:YES]];
  DSHProjectContextService *service = [self serviceWithProjectAccess:projectAccess
      workspaceAccess:workspaceAccess store:store hook:nil prefix:@"78787878"];
  NSDictionary *list = [service listCandidatesV2ForRoot:root query:@""
      cursor:nil error:&error];
  XCTAssertNotNil(list, @"%@", error);
  XCTAssertEqualObjects(list[@"project"][@"git_topology"],
                        @"legacy_embedded");
  XCTAssertTrue([[list[@"candidates"] valueForKey:@"path"]
      containsObject:@"README.md"]);
  NSDictionary *manifest = [service prepareCandidateV2WithRoot:root
      conversationId:@"90909090-9090-4090-8090-909090909090"
      modelId:@"deepseek-v4-flash" policy:@"chat-read-v1"
      selectedPaths:@[@"README.md"] error:&error];
  XCTAssertNotNil(manifest, @"%@", error);
  XCTAssertEqualObjects(manifest[@"project"][@"git_topology"],
                        @"legacy_embedded");
  NSDictionary *consent = [service confirmSnapshotV2Id:manifest[@"snapshot_id"]
      root:root error:&error];
  XCTAssertNotNil(consent, @"%@", error);
  drift = YES;
  error = nil;
  XCTAssertNil([service inspectSnapshotV2Id:manifest[@"snapshot_id"]
                                      root:root error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextServiceErrorChanged);
  [NSFileManager.defaultManager removeItemAtURL:base error:nil];
}


- (void)testCustomProviderSnapshotBindsEndpointAndRejectsSameHostPathSwitch {
  DSHLocalWorkspaceAccess *workspaceAccess = nil;
  DSHLocalProjectAccess *projectAccess = nil;
  NSDictionary *root = nil; NSURL *workspaceRoot = nil; NSURL *gitURL = nil;
  NSURL *base = [self makePrivateSplitFixtureWithProjectId:@"33333333-3333-4333-8333-333333333333"
      bindingProjectId:@"33333333-3333-4333-8333-333333333333" workspaceAccess:&workspaceAccess
      projectAccess:&projectAccess root:&root rootURL:&workspaceRoot gitURL:&gitURL];
  DSHProviderConfigurationStore *profiles = DSHProviderConfigurationStore.sharedStore;
  NSDictionary *original = [profiles configurationForHarness:@"claude-code"];
  @try {
    NSDictionary *configuration = @{@"schema_version": @1, @"harness_id": @"claude-code", @"name": @"Relay",
      @"endpoint_url": @"https://relay.example/v1/messages", @"protocol": @"messages", @"auth_type": @"bearer",
      @"send_reasoning": @NO, @"model_mappings": @{@"claude-sonnet-5": @"relay-sonnet"}};
    [profiles saveConfiguration:configuration error:nil];
    DSHProjectContextStore *store = [self storeAtURL:[base URLByAppendingPathComponent:@"store" isDirectory:YES]];
    DSHProjectContextService *service = [self serviceWithProjectAccess:projectAccess workspaceAccess:workspaceAccess
        store:store hook:nil prefix:@"cccccccc"];
    NSError *error = nil;
    NSString *conversation = @"44444444-4444-4444-8444-444444444444";
    id module = [[NSClassFromString(@"LocalProjectContextModule") alloc] initWithService:service
        operationQueue:dispatch_queue_create("custom-context-test", DISPATCH_QUEUE_SERIAL) maxPending:16];
    __block NSDictionary *manifest = nil;
    XCTestExpectation *prepared = [self expectationWithDescription:@"custom provider native bridge"];
    [module prepareCandidateV2Request:@{@"schema_version": @2, @"root": root, @"conversation_id": conversation,
      @"model_id": @"claude-sonnet-5", @"policy": @"chat-read-v1", @"selected_paths": @[@"README.md"]}
      resolver:^(id value) { manifest = value; [prepared fulfill]; }
      rejecter:^(NSString *code, NSString *message, NSError *failure) { XCTFail(@"%@", code); [prepared fulfill]; }];
    [self waitForExpectations:@[prepared] timeout:5];
    XCTAssertNotNil(manifest, @"%@", error);
    XCTAssertEqualObjects(manifest[@"provider_configuration"][@"model_id"], @"relay-sonnet");
    NSDictionary *consent = [service confirmSnapshotV2Id:manifest[@"snapshot_id"] root:root error:&error];
    NSDictionary *request = @{@"schema_version": @2, @"snapshot_id": manifest[@"snapshot_id"],
      @"consent_receipt_id": consent[@"consent_receipt_id"], @"root": root, @"conversation_id": conversation,
      @"model_id": @"claude-sonnet-5", @"policy": @"chat-read-v1"};
    NSData *bytes = [service verifiedFrozenEnvelopeV2:request receipt:nil error:&error];
    XCTAssertNotNil(bytes, @"%@", error);
    NSString *text = [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
    XCTAssertTrue([text containsString:@"relay.example"]);
    XCTAssertTrue([text containsString:@"relay-sonnet"]);
    NSMutableDictionary *changed = [configuration mutableCopy]; changed[@"endpoint_url"] = @"https://relay.example/other/v1/messages";
    [profiles saveConfiguration:changed error:nil];
    error = nil;
    XCTAssertNil([service verifiedFrozenEnvelopeV2:request receipt:nil error:&error]);
    XCTAssertEqual(error.code, DSHProjectContextServiceErrorChanged);
    [profiles resetHarness:@"claude-code"];
    error = nil;
    XCTAssertNil([service verifiedEnvelopeV2:request receipt:nil error:&error]);
    XCTAssertEqual(error.code, DSHProjectContextServiceErrorChanged);
  } @finally {
    if ([original[@"official"] boolValue]) [profiles resetHarness:@"claude-code"];
    else [profiles saveConfiguration:original error:nil];
    [NSFileManager.defaultManager removeItemAtURL:base error:nil];
  }
}
@end
