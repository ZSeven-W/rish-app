#import <XCTest/XCTest.h>

#import "DSHTestHost.h"

#import "../../../../modules/rish/ios/Sources/LocalProjectAccess.h"
#import "../../../../modules/rish/ios/Sources/ProjectContextPolicy.h"
#import "../../../../modules/rish/ios/Sources/ProjectContextService.h"
#import "../../../../modules/rish/ios/Sources/ProjectContextStore.h"
#import "DSHTestStorageFixture.h"

#import "../../../../modules/rish/ios/Sources/DSHWorkspaceCanonical.h"

// The test target has no header search path into the core, so it is reached by
// relative path; the symbols come from the linked pod.
#include "../../../../modules/rish/core/include/rish_agent_core.h"

#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <git2.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// The reference id that names a project-context snapshot used to be derived in
// ProjectContextService.mm; it is the core's now. Nothing else pins that the
// two agree: the prepare/commit round trips are self-consistent, so changing
// the derivation's domain string changes every id and no existing test
// notices. Verified — that mutation left all 106 ProjectContextWorkspaceV2
// tests green.
//
// So this is a real parity test. The local function below is the original
// algorithm, transcribed from the ObjC as it stood, running against Foundation
// and CommonCrypto exactly as it did; the other side is the shared core. Same
// inputs, same id, or an existing snapshot on a device stops being findable.
static NSString *DSHOriginalReferenceId(NSDictionary *root,
                                        NSString *rootFingerprint,
                                        NSString *conversationId) {
  NSData *body = DSHWorkspaceCanonicalJSONData(@{
    @"root" : root,
    @"root_fingerprint_sha256" : rootFingerprint,
    @"conversation_id" : conversationId,
  }, nil);
  if (body == nil) return nil;
  NSData *domain = [@"rish.project-context-reference.v2\0"
      dataUsingEncoding:NSUTF8StringEncoding];
  NSMutableData *preimage = [NSMutableData dataWithData:domain];
  [preimage appendData:body];
  uint8_t digest[CC_SHA256_DIGEST_LENGTH] = {};
  CC_SHA256(preimage.bytes, (CC_LONG)preimage.length, digest);
  digest[6] = (uint8_t)((digest[6] & 0x0f) | 0x40);
  digest[8] = (uint8_t)((digest[8] & 0x3f) | 0x80);
  return [NSString stringWithFormat:
      @"%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
      digest[0], digest[1], digest[2], digest[3], digest[4], digest[5],
      digest[6], digest[7], digest[8], digest[9], digest[10], digest[11],
      digest[12], digest[13], digest[14], digest[15]];
}

static NSString *DSHCoreReferenceId(NSDictionary *root,
                                    NSString *rootFingerprint,
                                    NSString *conversationId) {
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:@{
    @"op" : @"reference_id",
    @"root" : root,
    @"root_fingerprint_sha256" : rootFingerprint,
    @"conversation_id" : conversationId,
  } options:0 error:nil];
  if (bytes == nil) return nil;
  char *raw = rish_agent_project_context_service_reduce(
      (const char *)bytes.bytes, bytes.length);
  if (raw == NULL) return nil;
  NSData *replyBytes = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  id reply = [NSJSONSerialization JSONObjectWithData:replyBytes options:0
                                                error:nil];
  id derived = [reply isKindOfClass:NSDictionary.class] ? reply[@"reference_id"]
                                                        : nil;
  return [derived isKindOfClass:NSString.class] ? derived : nil;
}

static NSString *const DSHFixtureProjectA =
    @"11111111-1111-4111-8111-111111111111";
static NSString *const DSHFixtureProjectB =
    @"22222222-2222-4222-8222-222222222222";
static NSString *const DSHFixtureConversation =
    @"33333333-3333-4333-8333-333333333333";
static NSString *const DSHFixtureConversationB =
    @"44444444-4444-4444-8444-444444444444";

static NSData *DSHData(NSString *value) {
  return [value dataUsingEncoding:NSUTF8StringEncoding];
}

static NSString *DSHOidString(const git_oid *oid) {
  char output[GIT_OID_SHA1_HEXSIZE + 1] = {};
  git_oid_tostr(output, sizeof(output), oid);
  return [NSString stringWithUTF8String:output];
}

static NSString *DSHSHA256Hex(NSData *data) {
  uint8_t digest[CC_SHA256_DIGEST_LENGTH] = {};
  CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  NSMutableString *hex =
      [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
  for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
    [hex appendFormat:@"%02x", digest[index]];
  }
  return hex;
}

@interface DSHProjectFixture : NSObject
@property(nonatomic, copy) NSString *projectId;
@property(nonatomic, strong) NSURL *projectURL;
@property(nonatomic, strong) NSURL *repositoryURL;
@property(nonatomic) git_repository *repository;
@end

@implementation DSHProjectFixture
- (void)dealloc {
  if (_repository != nullptr) git_repository_free(_repository);
}
@end

@interface DSHImmediateTimeoutProjectAccess : DSHLocalProjectAccess
@end

@interface LocalWorkspaceModule : NSObject
@end

@interface DSHInjectedWorkspaceModule : LocalWorkspaceModule
@property(nonatomic, strong) NSURL *injectedWorkspaceRoot;
@end

@implementation DSHInjectedWorkspaceModule
- (NSURL *)workspaceRoot:(NSError **)error {
  (void)error;
  return self.injectedWorkspaceRoot;
}
@end

@interface LocalWorkspaceModule (DSHProjectContextTests)
- (NSArray<NSString *> *)componentsForPath:(id)value
                                  allowRoot:(BOOL)allowRoot
                                      error:(NSError **)error;
- (int)openDirectoryComponents:(NSArray<NSString *> *)components
                       leaseSet:(DSHLocalProjectLeaseSet *)leaseSet
                          error:(NSError **)error;
- (int)openParentDirectoryForPath:(id)value
                             name:(NSString **)name
                     relativePath:(NSString **)relativePath
                         leaseSet:(DSHLocalProjectLeaseSet *)leaseSet
                            error:(NSError **)error;
- (void)readTextPath:(NSString *)path
             resolver:(void (^)(id result))resolve
             rejecter:(void (^)(NSString *code, NSString *message,
                                 NSError *error))reject;
- (void)writeTextPath:(NSString *)path
                content:(NSString *)content
             createOnly:(BOOL)createOnly
       expectedRevision:(id)expectedRevision
               resolver:(void (^)(id result))resolve
               rejecter:(void (^)(NSString *code, NSString *message,
                                   NSError *error))reject;
- (void)renameEntrySource:(NSString *)source
               destination:(NSString *)destination
                  resolver:(void (^)(id result))resolve
                  rejecter:(void (^)(NSString *code, NSString *message,
                                      NSError *error))reject;
- (void)executePortableToolName:(NSString *)tool
                             path:(NSString *)path
                          options:(id)options
                         resolver:(void (^)(id result))resolve
                         rejecter:(void (^)(NSString *code, NSString *message,
                                             NSError *error))reject;
@end

@interface LocalProjectsModule : NSObject
@end

@interface LocalProjectsModule (DSHProjectContextTests)
- (void)stageAllForProject:(id)projectId resolver:(void (^)(id))resolve rejecter:(void (^)(NSString *, NSString *, NSError *))reject;
- (NSDictionary *)diffForRepository:(git_repository *)repository projectId:(NSString *)projectId staged:(BOOL)staged contextLines:(NSUInteger)contextLines error:(NSError **)error;
- (void)diffPageForProject:(id)projectId staged:(BOOL)staged offset:(id)offset snapshot:(id)snapshot resolver:(void (^)(id))resolve rejecter:(void (^)(NSString *, NSString *, NSError *))reject;

- (void)startCloneURL:(id)url name:(id)name options:(id)options
    resolver:(void (^)(id))resolve rejecter:(void (^)(NSString *, NSString *, NSError *))reject;
- (void)cloneStatusForOperation:(id)operationId
    resolver:(void (^)(id))resolve rejecter:(void (^)(NSString *, NSString *, NSError *))reject;
- (void)cancelCloneOperation:(id)operationId
    resolver:(void (^)(id))resolve rejecter:(void (^)(NSString *, NSString *, NSError *))reject;

- (nullable NSURL *)createStagingDirectoryAtRoot:(NSURL *)root
                                        projectId:(NSString *)projectId
                                             error:(NSError **)error;
- (BOOL)writeMetadata:(NSDictionary *)metadata
    atProjectDirectory:(NSURL *)project
             projectId:(NSString *)projectId
            writeToken:(DSHLocalProjectLockToken *)writeToken
                 error:(NSError **)error;
- (BOOL)publishStagingDirectory:(NSURL *)staging
                         atRoot:(NSURL *)root
                      projectId:(NSString *)projectId
                          error:(NSError **)error;
- (BOOL)stagingEntryIsExactForProjectId:(NSString *)projectId
                                  error:(NSError **)error;
- (void)createProjectWithName:(id)nameValue
                     resolver:(void (^)(id result))resolve
                     rejecter:(void (^)(NSString *code, NSString *message,
                                         NSError *error))reject;
- (void)listWithResolver:(void (^)(id result))resolve
                 rejecter:(void (^)(NSString *code, NSString *message,
                                     NSError *error))reject;
- (void)clonePublicRepository:(id)urlValue
                         name:(id)nameValue
                      options:(id)optionsValue
                     resolver:(void (^)(id result))resolve
                     rejecter:(void (^)(NSString *code, NSString *message,
                                         NSError *error))reject;
- (void)pushProject:(id)projectIdValue
            options:(id)optionsValue
           resolver:(void (^)(id result))resolve
           rejecter:(void (^)(NSString *code, NSString *message,
                               NSError *error))reject;
- (BOOL)removePublishedOwnerMarkerAtDescriptor:(int)descriptor;
- (BOOL)syncPublishedRootDescriptor:(int)descriptor;
@end

@interface DSHRootSwappingLocalProjectsModule : LocalProjectsModule
@property(nonatomic, copy, nullable) void (^afterCreateStaging)(NSURL *staging);
@end

@implementation DSHRootSwappingLocalProjectsModule
- (NSURL *)createStagingDirectoryAtRoot:(NSURL *)root
                              projectId:(NSString *)projectId
                                   error:(NSError **)error {
  NSURL *staging = [super createStagingDirectoryAtRoot:root
                                              projectId:projectId
                                                   error:error];
  if (staging != nil && self.afterCreateStaging != nil) {
    self.afterCreateStaging(staging);
  }
  return staging;
}
@end

@interface DSHFailingPublishLocalProjectsModule : LocalProjectsModule
@property(nonatomic) NSUInteger extraStagingEntries;
@property(nonatomic) NSUInteger nestedFailureDepth;
@property(nonatomic) BOOL nestedFixtureCreated;
@end

@implementation DSHFailingPublishLocalProjectsModule
- (NSURL *)createStagingDirectoryAtRoot:(NSURL *)root
                              projectId:(NSString *)projectId
                                   error:(NSError **)error {
  NSURL *staging = [super createStagingDirectoryAtRoot:root
                                              projectId:projectId
                                                   error:error];
  for (NSUInteger index = 0; staging != nil &&
       index < self.extraStagingEntries; index++) {
    NSString *name = [NSString stringWithFormat:@"extra-%03lu.txt",
                                                (unsigned long)index];
    if (![DSHData(@"x") writeToURL:[staging URLByAppendingPathComponent:name]
                         atomically:YES]) {
      if (error != nil) {
        *error = [NSError errorWithDomain:@"LocalProjects"
                                     code:3098 userInfo:@{}];
      }
      return nil;
    }
  }
  return staging;
}
- (BOOL)publishStagingDirectory:(NSURL *)staging
                         atRoot:(NSURL *)root
                      projectId:(NSString *)projectId
                          error:(NSError **)error {
  if (self.nestedFailureDepth > 0) {
    NSURL *directory = [staging URLByAppendingPathComponent:@"repo"
                                                isDirectory:YES];
    BOOL created = YES;
    for (NSUInteger depth = 1; depth <= self.nestedFailureDepth; depth++) {
      directory = [directory URLByAppendingPathComponent:
          [NSString stringWithFormat:@"d%02lu", (unsigned long)depth]
                                             isDirectory:YES];
      created = created && [[NSFileManager defaultManager]
          createDirectoryAtURL:directory withIntermediateDirectories:NO
          attributes:@{NSFilePosixPermissions : @0700} error:nil];
    }
    created = created && [DSHData(@"depth boundary") writeToURL:
        [directory URLByAppendingPathComponent:@"file.txt"] atomically:YES];
    self.nestedFixtureCreated = created;
  }
  (void)root;
  (void)projectId;
  if (error != nil) {
    *error = [NSError errorWithDomain:@"LocalProjects"
                                 code:3099
                             userInfo:@{}];
  }
  return NO;
}
@end

@interface DSHUnavailableProjectAccess : DSHLocalProjectAccess
@end

@implementation DSHUnavailableProjectAccess
- (DSHLocalProjectsRootLease *)leaseProjectsRootCreatingIfNeeded:
    (__unused BOOL)create error:(NSError **)error {
  if (error != nil) {
    *error = [NSError errorWithDomain:DSHLocalProjectAccessErrorDomain
                                 code:DSHLocalProjectAccessErrorStorageUnavailable
                             userInfo:@{}];
  }
  return nil;
}
@end

@interface DSHPublishFaultLocalProjectsModule : LocalProjectsModule
@property(nonatomic) BOOL failMarkerRemoval;
@property(nonatomic) BOOL failPublishedRootSync;
@end

@implementation DSHPublishFaultLocalProjectsModule
- (BOOL)removePublishedOwnerMarkerAtDescriptor:(int)descriptor {
  if (self.failMarkerRemoval) return NO;
  return [super removePublishedOwnerMarkerAtDescriptor:descriptor];
}
- (BOOL)syncPublishedRootDescriptor:(int)descriptor {
  if (self.failPublishedRootSync) return NO;
  return [super syncPublishedRootDescriptor:descriptor];
}
@end

@interface DSHProjectContextStore (DSHProjectContextTests)
- (nullable NSData *)readProtectedFile:(NSURL *)url
                              maxLength:(NSUInteger)maxLength
                                  error:(NSError **)error;
- (BOOL)writeAccesses:(NSDictionary *)accesses error:(NSError **)error;
- (BOOL)writeReferences:(NSDictionary *)references error:(NSError **)error;
- (BOOL)writeReferences:(NSDictionary *)references
                 applied:(BOOL *)applied
                   error:(NSError **)error;
- (nullable NSDictionary *)accesses:(NSError **)error;
- (BOOL)publishImmutableData:(NSData *)data
                        toURL:(NSURL *)url
                        error:(NSError **)error;
- (BOOL)pruneUnreferencedSnapshotsExcept:(nullable NSString *)snapshotId
                                    error:(NSError **)error;
@end

@interface DSHFaultingProjectContextStore : DSHProjectContextStore
@property(nonatomic) BOOL failProtectedRead;
@property(nonatomic) BOOL failAccessWrite;
@property(nonatomic) BOOL failPrune;
@property(nonatomic) BOOL failReferenceWrite;
@property(nonatomic) BOOL failReferenceWriteAfterSuper;
@property(nonatomic) BOOL failObservationAfterReferenceWrite;
@property(nonatomic) BOOL failTargetedDiscard;
@property(nonatomic) BOOL failReceiptPublishAfterSuper;
@property(nonatomic, copy, nullable) void (^afterActiveSave)(void);
@property(nonatomic, copy, nullable) void (^afterTransactionReferenceClear)(void);
@property(nonatomic) BOOL failAfterTransactionReferenceClear;
@end

@implementation DSHFaultingProjectContextStore
- (NSData *)readProtectedFile:(NSURL *)url
                    maxLength:(NSUInteger)maxLength
                        error:(NSError **)error {
  if (self.failProtectedRead) {
    if (error != nil) {
      *error = [NSError errorWithDomain:DSHProjectContextStoreErrorDomain
                                   code:DSHProjectContextStoreErrorUnavailable
                               userInfo:@{}];
    }
    return nil;
  }
  return [super readProtectedFile:url maxLength:maxLength error:error];
}
- (BOOL)writeAccesses:(NSDictionary *)accesses error:(NSError **)error {
  if (self.failAccessWrite) {
    if (error != nil) {
      *error = [NSError errorWithDomain:DSHProjectContextStoreErrorDomain
                                   code:DSHProjectContextStoreErrorUnavailable
                               userInfo:@{}];
    }
    return NO;
  }
  return [super writeAccesses:accesses error:error];
}
- (BOOL)writeReferences:(NSDictionary *)references error:(NSError **)error {
  return [super writeReferences:references error:error];
}
- (BOOL)writeReferences:(NSDictionary *)references
                 applied:(BOOL *)applied
                   error:(NSError **)error {
  if (applied != nullptr) *applied = NO;
  if (self.failReferenceWrite) {
    if (error != nil) {
      *error = [NSError errorWithDomain:DSHProjectContextStoreErrorDomain
                                   code:DSHProjectContextStoreErrorUnavailable
                               userInfo:@{}];
    }
    return NO;
  }
  BOOL superApplied = NO;
  BOOL written = [super writeReferences:references
                                   applied:&superApplied error:error];
  if (applied != nullptr) *applied = superApplied;
  if (written && self.failReferenceWriteAfterSuper) {
    self.failReferenceWriteAfterSuper = NO;
    if (self.failObservationAfterReferenceWrite) {
      self.failProtectedRead = YES;
    }
    if (error != nil) {
      *error = [NSError errorWithDomain:DSHProjectContextStoreErrorDomain
                                   code:DSHProjectContextStoreErrorUnavailable
                               userInfo:@{}];
    }
    return NO;
  }
  return written;
}
- (BOOL)pruneUnreferencedSnapshotsExcept:(NSString *)snapshotId
                                    error:(NSError **)error {
  if (self.failPrune) {
    if (error != nil) {
      *error = [NSError errorWithDomain:DSHProjectContextStoreErrorDomain
                                   code:DSHProjectContextStoreErrorUnavailable
                               userInfo:@{}];
    }
    return NO;
  }
  return [super pruneUnreferencedSnapshotsExcept:snapshotId error:error];
}
- (BOOL)pruneWithProtectedSnapshotId:(NSString *)snapshotId
                                error:(NSError **)error {
  if (self.failPrune) {
    if (error != nil) {
      *error = [NSError errorWithDomain:DSHProjectContextStoreErrorDomain
                                   code:DSHProjectContextStoreErrorUnavailable
                               userInfo:@{}];
    }
    return NO;
  }
  return [super pruneWithProtectedSnapshotId:snapshotId error:error];
}
- (BOOL)discardSnapshotId:(NSString *)snapshotId error:(NSError **)error {
  if (self.failTargetedDiscard) {
    if (error != nil) {
      *error = [NSError errorWithDomain:DSHProjectContextStoreErrorDomain
                                   code:DSHProjectContextStoreErrorUnavailable
                               userInfo:@{
                                 NSLocalizedDescriptionKey :
                                     @"RAW_DISCARD_IO_SENTINEL"
                               }];
    }
    return NO;
  }
  return [super discardSnapshotId:snapshotId error:error];
}
- (BOOL)publishImmutableData:(NSData *)data
                        toURL:(NSURL *)url
                        error:(NSError **)error {
  BOOL published = [super publishImmutableData:data toURL:url error:error];
  if (published && self.failReceiptPublishAfterSuper &&
      [url.URLByDeletingLastPathComponent.lastPathComponent
          isEqual:@"consents"]) {
    if (error != nil) {
      *error = [NSError errorWithDomain:DSHProjectContextStoreErrorDomain
                                   code:DSHProjectContextStoreErrorUnavailable
                               userInfo:@{}];
    }
    return NO;
  }
  return published;
}
- (BOOL)saveEnvelope:(NSData *)envelope
             manifest:(NSDictionary *)manifest
      sourceDescriptor:(NSDictionary *)sourceDescriptor
           snapshotId:(NSString *)snapshotId
   activeReferenceKey:(NSString *)activeReferenceKey
                error:(NSError **)error {
  BOOL saved = [super saveEnvelope:envelope manifest:manifest
                  sourceDescriptor:sourceDescriptor snapshotId:snapshotId
                activeReferenceKey:activeReferenceKey error:error];
  if (saved && self.afterActiveSave != nil) self.afterActiveSave();
  return saved;
}
- (BOOL)clearReferenceKeyKeepingSnapshot:(NSString *)referenceKey
                                    error:(NSError **)error {
  BOOL cleared = [super clearReferenceKeyKeepingSnapshot:referenceKey
                                                   error:error];
  if (cleared && [referenceKey hasPrefix:@"txn:"] &&
      self.afterTransactionReferenceClear != nil) {
    self.afterTransactionReferenceClear();
  }
  return cleared && !([referenceKey hasPrefix:@"txn:"] &&
                      self.failAfterTransactionReferenceClear);
}
@end

@implementation DSHImmediateTimeoutProjectAccess
- (DSHLocalProjectLease *)leaseProjectId:(NSString *)projectId
                                     mode:(DSHLocalProjectAccessMode)mode
                          includeMetadata:(BOOL)includeMetadata
                                  timeout:(NSTimeInterval)timeout
                                    error:(NSError **)error {
  if (error != nil) {
    *error = [NSError errorWithDomain:DSHLocalProjectAccessErrorDomain
                                 code:DSHLocalProjectAccessErrorLockTimeout
                             userInfo:@{}];
  }
  return nil;
}
@end

@interface ProjectContextServiceTests : XCTestCase
@property(nonatomic, strong) NSURL *temporaryURL;
@property(nonatomic, strong) NSURL *projectsURL;
@property(nonatomic, strong) NSURL *storeURL;
@property(nonatomic, strong) NSDate *now;
@property(nonatomic) NSUInteger nextIdentifier;
@property(nonatomic, strong) DSHLocalProjectAccess *access;
@property(nonatomic, strong) DSHProjectContextStore *store;
@property(nonatomic, strong) DSHProjectContextService *service;
- (nullable NSDictionary *)listProjectsSynchronously:(LocalProjectsModule *)projects
                                             rejected:(BOOL *)rejected;
- (NSString *)pushRejectionCodeForOptions:(id)options
                                  message:(NSString **)message;
- (BOOL)requireGitResult:(int)result operation:(NSString *)operation;
- (BOOL)requirePointer:(const void *)pointer operation:(NSString *)operation;
- (void)addConflictAtPath:(NSString *)relativePath
          ancestorContent:(NSString *)ancestorContent
              oursContent:(NSString *)oursContent
            theirsContent:(NSString *)theirsContent
                  fixture:(DSHProjectFixture *)fixture;
@end

@implementation ProjectContextServiceTests

- (NSString *)pushRejectionCodeForOptions:(id)options
                                  message:(NSString **)message {
  LocalProjectsModule *projects =
      [[NSClassFromString(@"LocalProjectsModule") alloc] init];
  [projects setValue:self.access forKey:@"projectAccess"];
  XCTestExpectation *finished =
      [self expectationWithDescription:@"push rejects without network access"];
  __block NSString *rejectionCode = nil;
  __block NSString *rejectionMessage = nil;
  [projects pushProject:@"not-a-project-id"
      options:options
      resolver:^(__unused id result) { [finished fulfill]; }
      rejecter:^(NSString *code, NSString *rejectedMessage,
                 __unused NSError *error) {
        rejectionCode = code;
        rejectionMessage = rejectedMessage;
        [finished fulfill];
      }];
  [self waitForExpectations:@[finished] timeout:5.0];
  if (message != nullptr) *message = rejectionMessage;
  return rejectionCode;
}

- (BOOL)requireGitResult:(int)result operation:(NSString *)operation {
  if (result == 0) return YES;
  const git_error *lastError = git_error_last();
  NSString *detail = lastError == nullptr || lastError->message == nullptr
      ? @"no libgit2 error detail"
      : [NSString stringWithUTF8String:lastError->message];
  XCTFail(@"%@ failed with libgit2 result %d: %@", operation, result,
          detail ?: @"invalid libgit2 error detail");
  return NO;
}

- (BOOL)requirePointer:(const void *)pointer operation:(NSString *)operation {
  if (pointer != nullptr) return YES;
  XCTFail(@"%@ returned a null pointer", operation);
  return NO;
}

- (void)setUp {
  [super setUp];
  NSError *fixtureError = nil;
  self.temporaryURL = DSHCreateTestStorageFixtureRoot(
      @"ProjectContextServiceTests", &fixtureError);
  XCTAssertNotNil(self.temporaryURL, @"%@", fixtureError);
  if (self.temporaryURL == nil) return;
  self.projectsURL = [self.temporaryURL URLByAppendingPathComponent:@"projects"
                                                        isDirectory:YES];
  self.storeURL = [self.temporaryURL URLByAppendingPathComponent:@"context-store"
                                                     isDirectory:YES];
  XCTAssertTrue([[NSFileManager defaultManager]
      createDirectoryAtURL:self.projectsURL
      withIntermediateDirectories:YES
      attributes:@{NSFilePosixPermissions : @0700}
      error:&fixtureError], @"%@", fixtureError);
  self.now = [NSDate dateWithTimeIntervalSince1970:1'777'777'777.125];
  self.nextIdentifier = 0;
  self.access = [[DSHLocalProjectAccess alloc]
      initWithProjectsRootURL:self.projectsURL];
  __weak ProjectContextServiceTests *weakSelf = self;
  DSHProjectContextClock clock = ^NSDate *{
    return weakSelf.now;
  };
  DSHProjectContextIdentifierGenerator identifiers = ^NSString *{
    @synchronized(weakSelf) {
      weakSelf.nextIdentifier += 1;
      return [NSString stringWithFormat:@"aaaaaaaa-aaaa-4aaa-8aaa-%012lu",
                                        (unsigned long)weakSelf.nextIdentifier];
    }
  };
  self.store = [[DSHProjectContextStore alloc] initWithRootURL:self.storeURL
                                                capacityBytes:64 * 1024 * 1024
                                                        clock:clock
                                          identifierGenerator:identifiers];
  self.service = [[DSHProjectContextService alloc]
      initWithProjectAccess:self.access
                      store:self.store
                     policy:[[DSHProjectContextPolicy alloc] init]
                      clock:clock
        identifierGenerator:identifiers
                       hook:nil];
  XCTAssertNotNil(self.service);
}

- (void)tearDown {
  self.service = nil;
  self.store = nil;
  self.access = nil;
  if (self.temporaryURL != nil) {
    [[NSFileManager defaultManager] removeItemAtURL:self.temporaryURL error:nil];
  }
  [super tearDown];
}

- (NSDictionary *)listProjectsSynchronously:(LocalProjectsModule *)projects
                                    rejected:(BOOL *)rejected {
  XCTestExpectation *finished = [self expectationWithDescription:
      @"project list completes"];
  __block NSDictionary *result = nil;
  __block BOOL didReject = NO;
  [projects listWithResolver:^(NSDictionary *value) {
    result = value;
    [finished fulfill];
  } rejecter:^(__unused NSString *code, __unused NSString *message,
               __unused NSError *error) {
    didReject = YES;
    [finished fulfill];
  }];
  [self waitForExpectations:@[finished] timeout:5.0];
  if (rejected != nullptr) *rejected = didReject;
  return result;
}

- (DSHProjectFixture *)createProject:(NSString *)projectId
                                name:(NSString *)name
                         initialFile:(NSString *)relativePath
                             content:(NSString *)content
                              commit:(BOOL)commit {
  NSURL *projectURL = [self.projectsURL URLByAppendingPathComponent:projectId
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
    @"name" : name,
    @"created_at" : @"2026-05-03T03:22:57.125Z",
    @"updated_at" : @"2026-05-03T03:22:57.125Z",
    @"origin_url" : NSNull.null,
  };
  NSData *metadataData = [NSJSONSerialization dataWithJSONObject:metadata
                                                          options:NSJSONWritingSortedKeys
                                                            error:nil];
  XCTAssertTrue([metadataData writeToURL:[projectURL
      URLByAppendingPathComponent:@"project.json"] atomically:YES]);

  git_repository *repository = nullptr;
  int initResult = git_repository_init(&repository,
                                       repositoryURL.fileSystemRepresentation,
                                       0);
  if (![self requireGitResult:initResult operation:@"git_repository_init"] ||
      ![self requirePointer:repository operation:@"git_repository_init"]) {
    if (repository != nullptr) git_repository_free(repository);
    return nil;
  }
  DSHProjectFixture *fixture = [[DSHProjectFixture alloc] init];
  fixture.projectId = projectId;
  fixture.projectURL = projectURL;
  fixture.repositoryURL = repositoryURL;
  fixture.repository = repository;
  if (relativePath != nil) {
    [self writeString:content relativePath:relativePath fixture:fixture];
    [self addPathToIndex:relativePath fixture:fixture];
    if (commit) [self commitFixture:fixture message:@"initial"];
  }
  return fixture;
}

- (void)writeString:(NSString *)content
        relativePath:(NSString *)relativePath
             fixture:(DSHProjectFixture *)fixture {
  NSURL *url = [fixture.repositoryURL URLByAppendingPathComponent:relativePath];
  XCTAssertTrue([[NSFileManager defaultManager]
      createDirectoryAtURL:url.URLByDeletingLastPathComponent
      withIntermediateDirectories:YES
      attributes:nil
      error:nil]);
  XCTAssertTrue([DSHData(content) writeToURL:url atomically:YES]);
}

- (void)writeBytes:(NSData *)content
       relativePath:(NSString *)relativePath
            fixture:(DSHProjectFixture *)fixture {
  NSURL *url = [fixture.repositoryURL URLByAppendingPathComponent:relativePath];
  XCTAssertTrue([[NSFileManager defaultManager]
      createDirectoryAtURL:url.URLByDeletingLastPathComponent
      withIntermediateDirectories:YES
      attributes:nil
      error:nil]);
  XCTAssertTrue([content writeToURL:url atomically:YES]);
}

- (void)addPathToIndex:(NSString *)relativePath
                fixture:(DSHProjectFixture *)fixture {
  if (![self requirePointer:fixture.repository
                   operation:@"fixture repository for addPathToIndex"]) {
    return;
  }
  git_index *index = nullptr;
  int result = git_repository_index(&index, fixture.repository);
  if (![self requireGitResult:result operation:@"git_repository_index"] ||
      ![self requirePointer:index operation:@"git_repository_index"]) {
    if (index != nullptr) git_index_free(index);
    return;
  }
  result = git_index_add_bypath(index, relativePath.UTF8String);
  if (![self requireGitResult:result operation:@"git_index_add_bypath"]) {
    git_index_free(index);
    return;
  }
  result = git_index_write(index);
  if (![self requireGitResult:result operation:@"git_index_write"]) {
    git_index_free(index);
    return;
  }
  git_index_free(index);
}

- (void)removePathFromIndex:(NSString *)relativePath
                     fixture:(DSHProjectFixture *)fixture {
  if (![self requirePointer:fixture.repository
                   operation:@"fixture repository for removePathFromIndex"]) {
    return;
  }
  git_index *index = nullptr;
  int result = git_repository_index(&index, fixture.repository);
  if (![self requireGitResult:result operation:@"git_repository_index"] ||
      ![self requirePointer:index operation:@"git_repository_index"]) {
    if (index != nullptr) git_index_free(index);
    return;
  }
  result = git_index_remove_bypath(index, relativePath.UTF8String);
  if (![self requireGitResult:result operation:@"git_index_remove_bypath"]) {
    git_index_free(index);
    return;
  }
  result = git_index_write(index);
  if (![self requireGitResult:result operation:@"git_index_write"]) {
    git_index_free(index);
    return;
  }
  git_index_free(index);
}

- (void)addPathsToIndex:(NSArray<NSString *> *)relativePaths
                  fixture:(DSHProjectFixture *)fixture {
  if (![self requirePointer:fixture.repository
                   operation:@"fixture repository for addPathsToIndex"]) {
    return;
  }
  git_index *index = nullptr;
  int result = git_repository_index(&index, fixture.repository);
  if (![self requireGitResult:result operation:@"git_repository_index"] ||
      ![self requirePointer:index operation:@"git_repository_index"]) {
    if (index != nullptr) git_index_free(index);
    return;
  }
  for (NSString *relativePath in relativePaths) {
    result = git_index_add_bypath(index, relativePath.UTF8String);
    if (![self requireGitResult:result operation:@"git_index_add_bypath"]) {
      git_index_free(index);
      return;
    }
  }
  result = git_index_write(index);
  if (![self requireGitResult:result operation:@"git_index_write"]) {
    git_index_free(index);
    return;
  }
  git_index_free(index);
}

- (void)addConflictAtPath:(NSString *)relativePath
                   fixture:(DSHProjectFixture *)fixture {
  [self addConflictAtPath:relativePath
          ancestorContent:@"base\n"
              oursContent:@"ours\n"
            theirsContent:@"theirs\n"
                  fixture:fixture];
}

- (void)addConflictAtPath:(NSString *)relativePath
          ancestorContent:(NSString *)ancestorContent
              oursContent:(NSString *)oursContent
            theirsContent:(NSString *)theirsContent
                  fixture:(DSHProjectFixture *)fixture {
  if (![self requirePointer:fixture.repository
                   operation:@"fixture repository for addConflictAtPath"]) {
    return;
  }
  NSData *ancestorData = DSHData(ancestorContent);
  NSData *oursData = DSHData(oursContent);
  NSData *theirsData = DSHData(theirsContent);
  git_oid ancestorOid = {};
  git_oid oursOid = {};
  git_oid theirsOid = {};
  int result = git_blob_create_from_buffer(&ancestorOid, fixture.repository,
                                           ancestorData.bytes,
                                           ancestorData.length);
  if (![self requireGitResult:result operation:@"git_blob_create ancestor"]) {
    return;
  }
  result = git_blob_create_from_buffer(&oursOid, fixture.repository,
                                       oursData.bytes, oursData.length);
  if (![self requireGitResult:result operation:@"git_blob_create ours"]) {
    return;
  }
  result = git_blob_create_from_buffer(&theirsOid, fixture.repository,
                                       theirsData.bytes, theirsData.length);
  if (![self requireGitResult:result operation:@"git_blob_create theirs"]) {
    return;
  }
  git_index_entry ancestor = {};
  git_index_entry ours = {};
  git_index_entry theirs = {};
  ancestor.mode = GIT_FILEMODE_BLOB;
  ours.mode = GIT_FILEMODE_BLOB;
  theirs.mode = GIT_FILEMODE_BLOB;
  ancestor.id = ancestorOid;
  ours.id = oursOid;
  theirs.id = theirsOid;
  ancestor.path = relativePath.UTF8String;
  ours.path = relativePath.UTF8String;
  theirs.path = relativePath.UTF8String;
  git_index *index = nullptr;
  result = git_repository_index(&index, fixture.repository);
  if (![self requireGitResult:result operation:@"git_repository_index"] ||
      ![self requirePointer:index operation:@"git_repository_index"]) {
    if (index != nullptr) git_index_free(index);
    return;
  }
  result = git_index_conflict_add(index, &ancestor, &ours, &theirs);
  if (![self requireGitResult:result operation:@"git_index_conflict_add"]) {
    git_index_free(index);
    return;
  }
  result = git_index_write(index);
  if (![self requireGitResult:result operation:@"git_index_write"]) {
    git_index_free(index);
    return;
  }
  git_index_free(index);
  [self writeString:[NSString stringWithFormat:
      @"<<<<<<< ours\n%@=======\n%@>>>>>>> theirs\n", oursContent,
      theirsContent]
       relativePath:relativePath
            fixture:fixture];
}

- (NSString *)recursiveProjectDigest:(DSHProjectFixture *)fixture {
  NSDirectoryEnumerator<NSURL *> *enumerator = [[NSFileManager defaultManager]
      enumeratorAtURL:fixture.projectURL
      includingPropertiesForKeys:@[
        NSURLIsDirectoryKey, NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey,
        NSURLFileSizeKey, NSURLContentModificationDateKey, NSURLCreationDateKey,
        NSURLFileResourceIdentifierKey, NSURLFileSecurityKey
      ]
      options:0
      errorHandler:^BOOL(__unused NSURL *url, __unused NSError *error) {
        return NO;
      }];
  NSMutableArray<NSString *> *rows = [NSMutableArray array];
  for (NSURL *url in enumerator) {
    NSString *relative = [url.path substringFromIndex:fixture.projectURL.path.length + 1];
    struct stat metadata = {};
    XCTAssertEqual(lstat(url.fileSystemRepresentation, &metadata), 0);
    NSMutableString *row = [NSMutableString stringWithFormat:
        @"%lu:%@:%o:%llu:%llu:%llu:%lld:%lld.%09ld:%lld.%09ld",
        (unsigned long)[relative lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
        relative, metadata.st_mode, (unsigned long long)metadata.st_dev,
        (unsigned long long)metadata.st_ino, (unsigned long long)metadata.st_nlink,
        (long long)metadata.st_size, (long long)metadata.st_mtimespec.tv_sec,
        metadata.st_mtimespec.tv_nsec, (long long)metadata.st_ctimespec.tv_sec,
        metadata.st_ctimespec.tv_nsec];
    if (S_ISREG(metadata.st_mode)) {
      NSData *data = [NSData dataWithContentsOfURL:url];
      [row appendFormat:@":%@", DSHSHA256Hex(data ?: NSData.data)];
    } else if (S_ISLNK(metadata.st_mode)) {
      char target[PATH_MAX + 1] = {};
      ssize_t length = readlink(url.fileSystemRepresentation, target, PATH_MAX);
      NSData *data = length < 0 ? NSData.data
                                : [NSData dataWithBytes:target length:(NSUInteger)length];
      [row appendFormat:@":%@", DSHSHA256Hex(data)];
    }
    [rows addObject:row];
  }
  [rows sortUsingSelector:@selector(compare:)];
  return DSHSHA256Hex(DSHData([rows componentsJoinedByString:@"\n"]));
}

- (NSString *)commitFixture:(DSHProjectFixture *)fixture
                     message:(NSString *)message {
  git_index *index = nullptr;
  git_tree *tree = nullptr;
  git_commit *parent = nullptr;
  git_reference *head = nullptr;
  git_signature *signature = nullptr;
  git_oid treeOid = {};
  git_oid commitOid = {};
  if (![self requirePointer:fixture.repository
                   operation:@"fixture repository for commitFixture"]) {
    return nil;
  }
  @try {
    int result = git_repository_index(&index, fixture.repository);
    if (![self requireGitResult:result operation:@"git_repository_index"] ||
        ![self requirePointer:index operation:@"git_repository_index"]) {
      return nil;
    }
    result = git_index_write_tree(&treeOid, index);
    if (![self requireGitResult:result operation:@"git_index_write_tree"]) {
      return nil;
    }
    result = git_tree_lookup(&tree, fixture.repository, &treeOid);
    if (![self requireGitResult:result operation:@"git_tree_lookup"] ||
        ![self requirePointer:tree operation:@"git_tree_lookup"]) {
      return nil;
    }
    int headResult = git_repository_head(&head, fixture.repository);
    if (headResult == 0) {
      if (![self requirePointer:head operation:@"git_repository_head"] ||
          ![self requirePointer:git_reference_target(head)
                       operation:@"git_reference_target"]) {
        return nil;
      }
      result = git_commit_lookup(&parent, fixture.repository,
                                 git_reference_target(head));
      if (![self requireGitResult:result operation:@"git_commit_lookup"] ||
          ![self requirePointer:parent operation:@"git_commit_lookup"]) {
        return nil;
      }
    } else if (headResult != GIT_EUNBORNBRANCH &&
               headResult != GIT_ENOTFOUND) {
      [self requireGitResult:headResult operation:@"git_repository_head"];
      return nil;
    }
    result = git_signature_new(&signature, "Rish Test",
                               "rish-test@example.invalid", 1'777'777'777,
                               0);
    if (![self requireGitResult:result operation:@"git_signature_new"] ||
        ![self requirePointer:signature operation:@"git_signature_new"]) {
      return nil;
    }
    const git_commit *parents[] = {parent};
    result = git_commit_create(&commitOid, fixture.repository, "HEAD",
                               signature, signature, "UTF-8",
                               message.UTF8String, tree,
                               parent == nullptr ? 0 : 1, parents);
    if (![self requireGitResult:result operation:@"git_commit_create"]) {
      return nil;
    }
    NSString *oid = DSHOidString(&commitOid);
    if (oid == nil) XCTFail(@"git_commit_create produced an invalid OID");
    return oid;
  } @finally {
    if (signature != nullptr) git_signature_free(signature);
    if (head != nullptr) git_reference_free(head);
    if (parent != nullptr) git_commit_free(parent);
    if (tree != nullptr) git_tree_free(tree);
    if (index != nullptr) git_index_free(index);
  }
}

- (NSDictionary *)selectionForFixture:(DSHProjectFixture *)fixture
                                 paths:(NSArray<NSString *> *)paths {
  return @{
    @"schema_version" : @1,
    @"project_id" : fixture.projectId,
    @"conversation_id" : DSHFixtureConversation,
    @"provider" : @"deepseek",
    @"model" : @"deepseek-v4-flash",
    @"policy" : @"chat-read-v1",
    @"selected_paths" : paths,
  };
}

- (NSDictionary *)requestBindForManifest:(NSDictionary *)manifest {
  NSDictionary *stored = [self.store loadSnapshotId:manifest[@"snapshot_id"]
                                                error:nil];
  NSString *conversationId =
      stored[@"source_descriptor"][@"conversation_id"] ?:
      DSHFixtureConversation;
  return @{
    @"schema_version" : @1,
    @"conversation_id" : conversationId,
    @"project_id" : manifest[@"project_id"],
    @"provider" : @"deepseek",
    @"model" : @"deepseek-v4-flash",
    @"policy" : @"chat-read-v1",
  };
}

- (NSData *)confirmedEnvelopeForManifest:(NSDictionary *)manifest
                                   error:(NSError **)error {
  NSDictionary *consent =
      [self.service confirmSnapshotId:manifest[@"snapshot_id"] error:error];
  if (consent == nil) return nil;
  return [self.service verifiedEnvelopeForSnapshotId:manifest[@"snapshot_id"]
                                  consentReceiptId:consent[@"consent_receipt_id"]
                                       requestBind:[self requestBindForManifest:manifest]
                                           receipt:nil
                                             error:error];
}

- (void)testPrepareReturnsManifestWithoutRawContent {
  NSString *sentinel = @"SAFE_RAW_SENTINEL_4F20A1";
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"Sources/Main.swift"
                                          content:sentinel
                                           commit:YES];
  NSError *error = nil;
  NSDictionary *manifest = [self.service
      prepareSelection:[self selectionForFixture:fixture
                                           paths:@[@"Sources/Main.swift"]]
                   error:&error];
  XCTAssertNotNil(manifest);
  XCTAssertNil(error);
  XCTAssertEqualObjects(manifest[@"project_id"], fixture.projectId);
  XCTAssertEqualObjects(manifest[@"policy_version"],
                        DSHProjectContextPolicyVersion);
  XCTAssertEqualObjects(manifest[@"provider_host"], @"api.deepseek.com");
  XCTAssertEqualObjects(manifest[@"included"][0][@"path"],
                        @"Sources/Main.swift");
  XCTAssertNil(manifest[@"content"]);
  XCTAssertFalse([[NSString alloc]
      initWithData:[NSJSONSerialization dataWithJSONObject:manifest
                                                   options:0
                                                     error:nil]
          encoding:NSUTF8StringEncoding]
      .length == 0);
  NSString *serialized = [[NSString alloc]
      initWithData:[NSJSONSerialization dataWithJSONObject:manifest
                                                   options:0
                                                     error:nil]
          encoding:NSUTF8StringEncoding];
  XCTAssertEqual([serialized rangeOfString:sentinel].location, NSNotFound);
}

- (void)testConfirmBindsExactSnapshotDigest {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"README.md"
                                          content:@"immutable digest\n"
                                           commit:YES];
  NSError *error = nil;
  NSDictionary *manifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error];
  NSDictionary *consent =
      [self.service confirmSnapshotId:manifest[@"snapshot_id"] error:&error];
  XCTAssertNotNil(consent);
  XCTAssertEqualObjects(consent[@"snapshot_id"], manifest[@"snapshot_id"]);
  XCTAssertEqualObjects(consent[@"snapshot_sha256"],
                        manifest[@"snapshot_sha256"]);
  XCTAssertEqualObjects(consent[@"schema_version"], @1);
  XCTAssertNotNil(consent[@"confirmed_at"]);
  NSDictionary *inspection =
      [self.service inspectSnapshotId:manifest[@"snapshot_id"] error:&error];
  XCTAssertEqualObjects(inspection[@"state"], @"confirmed");
}

- (void)testSelectedTrackedDiffUsesCompleteHunks {
  NSMutableString *initial = [NSMutableString string];
  for (NSUInteger index = 0; index < 40; index++) {
    [initial appendFormat:@"line-%02lu original\n", (unsigned long)index];
  }
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"notes.txt"
                                          content:initial
                                           commit:YES];
  NSMutableString *changed = [initial mutableCopy];
  [changed replaceOccurrencesOfString:@"line-03 original"
                            withString:@"line-03 STAGED_COMPLETE_HUNK"
                               options:0
                                 range:NSMakeRange(0, changed.length)];
  [self writeString:changed relativePath:@"notes.txt" fixture:fixture];
  [self addPathToIndex:@"notes.txt" fixture:fixture];
  [changed replaceOccurrencesOfString:@"line-35 original"
                            withString:@"line-35 WORKTREE_COMPLETE_HUNK"
                               options:0
                                 range:NSMakeRange(0, changed.length)];
  [self writeString:changed relativePath:@"notes.txt" fixture:fixture];

  NSError *error = nil;
  NSDictionary *manifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"notes.txt"]]
                   error:&error];
  NSData *envelope = [self confirmedEnvelopeForManifest:manifest error:&error];
  NSString *text = [[NSString alloc] initWithData:envelope
                                         encoding:NSUTF8StringEncoding];
  XCTAssertNotNil(text);
  XCTAssertTrue([text containsString:@"STAGED_COMPLETE_HUNK"]);
  XCTAssertTrue([text containsString:@"WORKTREE_COMPLETE_HUNK"]);
  NSArray *sources = [manifest[@"included"] valueForKey:@"source"];
  XCTAssertTrue([sources containsObject:@"staged_diff"]);
  XCTAssertTrue([sources containsObject:@"worktree_diff"]);
}

- (void)testUntrackedContentNeverEntersSnapshot {
  NSString *untrackedSecret = @"UNTRACKED_MUST_NEVER_ENTER_42A9";
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"README.md"
                                          content:@"tracked safe\n"
                                           commit:YES];
  [self writeString:untrackedSecret
       relativePath:@"untracked.txt"
            fixture:fixture];
  NSError *error = nil;
  NSDictionary *manifest = [self.service
      prepareSelection:[self selectionForFixture:fixture
                                           paths:@[@"README.md", @"untracked.txt"]]
                   error:&error];
  NSData *envelope = [self confirmedEnvelopeForManifest:manifest error:&error];
  NSString *text = [[NSString alloc] initWithData:envelope
                                         encoding:NSUTF8StringEncoding];
  XCTAssertFalse([text containsString:untrackedSecret]);
  NSPredicate *predicate = [NSPredicate
      predicateWithFormat:@"path == %@ AND reason == %@", @"untracked.txt",
                          DSHProjectContextOmissionReasonNotTracked];
  XCTAssertEqual([manifest[@"omitted"] filteredArrayUsingPredicate:predicate].count,
                 (NSUInteger)1);
}

- (void)testMissingWorktreeAndIndexOnlyPathsNeverDiscloseBlobOrPatchBytes {
  NSString *committedSentinel = @"MISSING_WORKTREE_BLOB_MUST_NOT_LEAK_91A2";
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"missing.txt"
                                          content:committedSentinel
                                           commit:YES];
  XCTAssertTrue([[NSFileManager defaultManager]
      removeItemAtURL:[fixture.repositoryURL
                          URLByAppendingPathComponent:@"missing.txt"]
                error:nil]);
  NSError *error = nil;
  NSDictionary *manifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"missing.txt"]]
                   error:&error];
  XCTAssertNotNil(manifest);
  NSDictionary *stored = [self.store loadSnapshotId:manifest[@"snapshot_id"]
                                               error:&error];
  NSString *envelope = [[NSString alloc] initWithData:stored[@"envelope"]
                                              encoding:NSUTF8StringEncoding];
  XCTAssertFalse([envelope containsString:committedSentinel]);
  XCTAssertEqual([manifest[@"included"] count], (NSUInteger)0);

  DSHProjectFixture *unborn = [self createProject:DSHFixtureProjectB
                                             name:@"Beta"
                                      initialFile:@"index-only.txt"
                                          content:@"INDEX_ONLY_STAGED_MUST_NOT_LEAK_7C4E"
                                           commit:NO];
  XCTAssertTrue([[NSFileManager defaultManager]
      removeItemAtURL:[unborn.repositoryURL
                          URLByAppendingPathComponent:@"index-only.txt"]
                error:nil]);
  NSDictionary *unbornManifest = [self.service
      prepareSelection:[self selectionForFixture:unborn
                                           paths:@[@"index-only.txt"]]
                   error:&error];
  NSDictionary *unbornStored =
      [self.store loadSnapshotId:unbornManifest[@"snapshot_id"] error:&error];
  NSString *unbornEnvelope = [[NSString alloc]
      initWithData:unbornStored[@"envelope"]
          encoding:NSUTF8StringEncoding];
  XCTAssertFalse([unbornEnvelope containsString:@"INDEX_ONLY_STAGED_MUST_NOT_LEAK_7C4E"]);
  XCTAssertEqual([unbornManifest[@"included"] count], (NSUInteger)0);
}

- (void)testSupersededAndClearedSnapshotsCannotConfirmOrReplayWithoutRetryRef {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"README.md"
                                          content:@"first active\n"
                                           commit:YES];
  [self writeString:@"second active\n"
       relativePath:@"SECOND.md"
            fixture:fixture];
  [self addPathToIndex:@"SECOND.md" fixture:fixture];
  [self commitFixture:fixture message:@"second file"];
  NSError *error = nil;
  NSDictionary *first = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error];
  NSDictionary *firstConsent =
      [self.service confirmSnapshotId:first[@"snapshot_id"] error:&error];
  XCTAssertNotNil(firstConsent);
  NSDictionary *second = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"SECOND.md"]]
                   error:&error];
  error = nil;
  XCTAssertNil([self.service confirmSnapshotId:first[@"snapshot_id"] error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextServiceErrorConsent);
  error = nil;
  XCTAssertNil([self.service
      verifiedEnvelopeForSnapshotId:first[@"snapshot_id"]
                    consentReceiptId:firstConsent[@"consent_receipt_id"]
                         requestBind:[self requestBindForManifest:first]
                             receipt:nil
                               error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextServiceErrorSnapshotMissing);

  NSDictionary *secondConsent =
      [self.service confirmSnapshotId:second[@"snapshot_id"] error:&error];
  XCTAssertNotNil(secondConsent);
  XCTAssertTrue([self.store setReferenceKey:@"retry:attempt-1"
                                  snapshotId:second[@"snapshot_id"]
                                       error:&error]);
  NSDictionary *third = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error];
  XCTAssertNotNil([self.service
      verifiedEnvelopeForSnapshotId:second[@"snapshot_id"]
                    consentReceiptId:secondConsent[@"consent_receipt_id"]
                         requestBind:[self requestBindForManifest:second]
                             receipt:nil
                               error:&error]);
  XCTAssertTrue([self.store clearReferenceKey:@"retry:attempt-1" error:&error]);
  error = nil;
  XCTAssertNil([self.service
      verifiedEnvelopeForSnapshotId:second[@"snapshot_id"]
                    consentReceiptId:secondConsent[@"consent_receipt_id"]
                         requestBind:[self requestBindForManifest:second]
                             receipt:nil
                               error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextServiceErrorSnapshotMissing);
  XCTAssertTrue([self.store
      abortPrepareTransactionForSnapshotId:third[@"snapshot_id"]
                           activeReferenceKey:
                               [@"active:" stringByAppendingString:
                                    DSHFixtureConversation]
                                        error:&error]);
  error = nil;
  XCTAssertNil([self.service confirmSnapshotId:third[@"snapshot_id"] error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextServiceErrorConsent);
}

- (void)testPolicyContentAndFilesystemHazardsAreOmittedWithoutLeakingBytes {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"README.md"
                                          content:@"safe root\n"
                                           commit:YES];
  [self writeString:@"PASSWORD_SHOULD_NOT_LEAK"
       relativePath:@".env.production"
            fixture:fixture];
  const unsigned char invalid[] = {0xc3, 0x28};
  [self writeBytes:[NSData dataWithBytes:invalid length:sizeof(invalid)]
      relativePath:@"invalid.txt"
           fixture:fixture];
  const unsigned char binary[] = {'a', 0, 'b'};
  [self writeBytes:[NSData dataWithBytes:binary length:sizeof(binary)]
      relativePath:@"binary.txt"
           fixture:fixture];
  [self writeString:@"hardlink payload\n"
       relativePath:@"hard-source.txt"
            fixture:fixture];
  NSURL *hardSource =
      [fixture.repositoryURL URLByAppendingPathComponent:@"hard-source.txt"];
  NSURL *hardTarget =
      [fixture.repositoryURL URLByAppendingPathComponent:@"hard-target.txt"];
  XCTAssertEqual(link(hardSource.fileSystemRepresentation,
                      hardTarget.fileSystemRepresentation),
                 0);
  NSURL *symlinkURL =
      [fixture.repositoryURL URLByAppendingPathComponent:@"linked.txt"];
  XCTAssertEqual(symlink("README.md", symlinkURL.fileSystemRepresentation), 0);
  NSArray *paths = @[
    @".env.production", @"invalid.txt", @"binary.txt", @"hard-source.txt",
    @"hard-target.txt", @"linked.txt"
  ];
  [self addPathsToIndex:paths fixture:fixture];
  [self commitFixture:fixture message:@"hazards"];

  NSError *error = nil;
  NSDictionary *manifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:paths]
                   error:&error];
  XCTAssertNotNil(manifest);
  XCTAssertEqual([manifest[@"included"] count], (NSUInteger)0);
  XCTAssertEqual([manifest[@"omitted"] count], paths.count);
  NSString *serialized = [[NSString alloc]
      initWithData:[NSJSONSerialization dataWithJSONObject:manifest
                                                   options:0
                                                     error:nil]
          encoding:NSUTF8StringEncoding];
  XCTAssertFalse([serialized containsString:@"PASSWORD_SHOULD_NOT_LEAK"]);
  XCTAssertFalse([serialized containsString:@"hardlink payload"]);
}

- (void)testIgnoredPathsAreNotCandidatesOrSnapshotContent {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@".gitignore"
                                          content:@"ignored.txt\n"
                                           commit:YES];
  [self writeString:@"IGNORED_CONTENT_SENTINEL"
       relativePath:@"ignored.txt"
            fixture:fixture];
  NSError *error = nil;
  NSDictionary *page = [self.service listCandidatesForProjectId:fixture.projectId
                                                           query:@""
                                                          cursor:nil
                                                           error:&error];
  NSArray *candidatePaths = [page[@"candidates"] valueForKey:@"path"];
  XCTAssertFalse([candidatePaths containsObject:@"ignored.txt"]);
  NSDictionary *manifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"ignored.txt"]]
                   error:&error];
  NSData *envelope = [self confirmedEnvelopeForManifest:manifest error:&error];
  XCTAssertFalse([[[NSString alloc] initWithData:envelope
                                        encoding:NSUTF8StringEncoding]
      containsString:@"IGNORED_CONTENT_SENTINEL"]);
}

- (void)testCandidateListingUsesDescriptorStatForLiveEligibility {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"Sources/Big.swift"
                                          content:@"small\n"
                                           commit:NO];
  [self writeString:@"link base\n" relativePath:@"Sources/Link.swift"
            fixture:fixture];
  [self writeString:@"hard base\n" relativePath:@"Sources/Hard.swift"
            fixture:fixture];
  [self addPathsToIndex:@[@"Sources/Link.swift", @"Sources/Hard.swift"]
                  fixture:fixture];
  [self commitFixture:fixture message:@"candidate metadata"];
  NSMutableData *large = [NSMutableData
      dataWithLength:DSHProjectContextMaxFileBytes + 1];
  [self writeBytes:large relativePath:@"Sources/Big.swift" fixture:fixture];
  NSURL *linkURL = [fixture.repositoryURL
      URLByAppendingPathComponent:@"Sources/Link.swift"];
  XCTAssertTrue([[NSFileManager defaultManager] removeItemAtURL:linkURL error:nil]);
  XCTAssertEqual(symlink("Hard.swift", linkURL.fileSystemRepresentation), 0);
  NSURL *hardURL = [fixture.repositoryURL
      URLByAppendingPathComponent:@"Sources/Hard.swift"];
  NSURL *hardAlias = [fixture.projectURL URLByAppendingPathComponent:@"hard-alias"];
  XCTAssertEqual(link(hardURL.fileSystemRepresentation,
                      hardAlias.fileSystemRepresentation),
                 0);
  NSError *error = nil;
  NSDictionary *page = [self.service listCandidatesForProjectId:fixture.projectId
                                                           query:@""
                                                          cursor:nil
                                                           error:&error];
  XCTAssertNotNil(page);
  NSMutableDictionary<NSString *, NSDictionary *> *byPath =
      [NSMutableDictionary dictionary];
  for (NSDictionary *candidate in page[@"candidates"]) {
    byPath[candidate[@"path"]] = candidate;
  }
  XCTAssertEqual([byPath[@"Sources/Big.swift"][@"size"] unsignedIntegerValue],
                 DSHProjectContextMaxFileBytes + 1);
  XCTAssertFalse([byPath[@"Sources/Big.swift"][@"eligible"] boolValue]);
  XCTAssertEqualObjects(byPath[@"Sources/Big.swift"][@"omission_reason"],
                        DSHProjectContextOmissionReasonBudgetExceeded);
  for (NSString *path in @[@"Sources/Link.swift", @"Sources/Hard.swift"]) {
    XCTAssertFalse([byPath[path][@"eligible"] boolValue]);
    XCTAssertEqualObjects(byPath[path][@"omission_reason"],
                          DSHProjectContextOmissionReasonPolicy);
  }
}

- (void)testDirectorySelectionReportsEveryTrackedIneligibleDescendant {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"src/Allowed.swift"
                                          content:@"let allowed = true\n"
                                           commit:NO];
  [self writeString:@"TOKEN=placeholder\n" relativePath:@"src/.env.local"
            fixture:fixture];
  [self writeString:@"{}\n" relativePath:@"src/package-lock.json"
            fixture:fixture];
  [self writeString:@"generated\n" relativePath:@"src/vendor/Generated.swift"
            fixture:fixture];
  [self writeBytes:[NSMutableData
      dataWithLength:DSHProjectContextMaxFileBytes + 1]
       relativePath:@"src/Large.swift" fixture:fixture];
  NSURL *linkURL = [fixture.repositoryURL
      URLByAppendingPathComponent:@"src/Link.swift"];
  XCTAssertEqual(symlink("Allowed.swift", linkURL.fileSystemRepresentation), 0);
  NSArray<NSString *> *tracked = @[
    @"src/.env.local", @"src/package-lock.json",
    @"src/vendor/Generated.swift", @"src/Large.swift", @"src/Link.swift"
  ];
  [self addPathsToIndex:tracked fixture:fixture];
  [self commitFixture:fixture message:@"directory omissions"];
  [self writeString:@"untracked\n" relativePath:@"src/Untracked.swift"
            fixture:fixture];
  NSError *error = nil;
  NSDictionary *manifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"src"]]
                   error:&error];
  XCTAssertNotNil(manifest);
  NSArray *includedPaths = [manifest[@"included"] valueForKey:@"path"];
  XCTAssertTrue([includedPaths containsObject:@"src/Allowed.swift"]);
  XCTAssertFalse([includedPaths containsObject:@"src/Untracked.swift"]);
  NSMutableDictionary<NSString *, NSString *> *reasons =
      [NSMutableDictionary dictionary];
  for (NSDictionary *omission in manifest[@"omitted"]) {
    reasons[omission[@"path"]] = omission[@"reason"];
  }
  XCTAssertEqualObjects(reasons[@"src/.env.local"],
                        DSHProjectContextOmissionReasonSecretPath);
  XCTAssertEqualObjects(reasons[@"src/package-lock.json"],
                        DSHProjectContextOmissionReasonLockfile);
  XCTAssertEqualObjects(reasons[@"src/vendor/Generated.swift"],
                        DSHProjectContextOmissionReasonGenerated);
  XCTAssertEqualObjects(reasons[@"src/Large.swift"],
                        DSHProjectContextOmissionReasonBudgetExceeded);
  XCTAssertEqualObjects(reasons[@"src/Link.swift"],
                        DSHProjectContextOmissionReasonPolicy);
  XCTAssertNil(reasons[@"src"]);
  XCTAssertNil(reasons[@"src/Untracked.swift"]);
}

- (void)testDeniedSideOfRenameNeverLeaksFromCompletePatch {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@".env.secret"
                                          content:@"rename-safe-looking-value\n"
                                           commit:YES];
  NSURL *oldURL =
      [fixture.repositoryURL URLByAppendingPathComponent:@".env.secret"];
  NSURL *newURL =
      [fixture.repositoryURL URLByAppendingPathComponent:@"Sources/Public.swift"];
  XCTAssertTrue([[NSFileManager defaultManager]
      createDirectoryAtURL:newURL.URLByDeletingLastPathComponent
      withIntermediateDirectories:YES
      attributes:nil
      error:nil]);
  XCTAssertEqual(rename(oldURL.fileSystemRepresentation,
                        newURL.fileSystemRepresentation),
                 0);
  [self removePathFromIndex:@".env.secret" fixture:fixture];
  [self addPathToIndex:@"Sources/Public.swift" fixture:fixture];
  NSError *error = nil;
  NSDictionary *manifest = [self.service
      prepareSelection:[self selectionForFixture:fixture
                                           paths:@[@"Sources/Public.swift"]]
                   error:&error];
  NSData *envelope = [self confirmedEnvelopeForManifest:manifest error:&error];
  NSString *manifestText = [[NSString alloc]
      initWithData:[NSJSONSerialization dataWithJSONObject:manifest
                                                   options:0
                                                     error:nil]
          encoding:NSUTF8StringEncoding];
  NSString *envelopeText = [[NSString alloc] initWithData:envelope
                                                  encoding:NSUTF8StringEncoding];
  XCTAssertFalse([manifestText containsString:@".env.secret"]);
  XCTAssertFalse([envelopeText containsString:@".env.secret"]);
}

- (void)testConflictIsFingerprintableButContentIsOmitted {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"conflict.txt"
                                          content:@"base\n"
                                           commit:YES];
  NSString *firstOursToken = @"OURS_CONTENT_MUST_STAY_PRIVATE_41A7";
  NSString *firstTheirsToken = @"THEIRS_CONTENT_MUST_STAY_PRIVATE_52B8";
  NSString *firstOurs = [firstOursToken stringByAppendingString:@"\n"];
  NSString *firstTheirs = [firstTheirsToken stringByAppendingString:@"\n"];
  [self addConflictAtPath:@"conflict.txt"
          ancestorContent:@"base\n"
              oursContent:firstOurs
            theirsContent:firstTheirs
                  fixture:fixture];
  NSError *error = nil;
  NSDictionary *first = [self.service
      prepareSelection:[self selectionForFixture:fixture
                                           paths:@[@"conflict.txt"]]
                   error:&error];
  XCTAssertNotNil(first);
  XCTAssertNil(error);
  if (first == nil) return;
  NSPredicate *lowercaseSHA256 =
      [NSPredicate predicateWithFormat:@"SELF MATCHES %@", @"^[0-9a-f]{64}$"];
  XCTAssertTrue([lowercaseSHA256 evaluateWithObject:first[@"source_fingerprint"]]);
  XCTAssertTrue([first[@"conflicted"] boolValue]);
  XCTAssertEqualObjects(first[@"omitted"][0][@"path"], @"conflict.txt");
  XCTAssertEqualObjects(first[@"omitted"][0][@"reason"],
                        DSHProjectContextOmissionReasonPolicy);
  XCTAssertEqual([first[@"included"] count], (NSUInteger)0);

  NSDictionary *firstStored =
      [self.store loadSnapshotId:first[@"snapshot_id"] error:&error];
  NSData *firstManifestData =
      [NSJSONSerialization dataWithJSONObject:first options:NSJSONWritingSortedKeys
                                         error:&error];
  NSString *firstManifestText = [[NSString alloc] initWithData:firstManifestData
                                                       encoding:NSUTF8StringEncoding];
  NSString *firstEnvelopeText = [[NSString alloc]
      initWithData:firstStored[@"envelope"] encoding:NSUTF8StringEncoding];
  XCTAssertNotNil(firstEnvelopeText);
  XCTAssertFalse([firstManifestText containsString:firstOursToken]);
  XCTAssertFalse([firstManifestText containsString:firstTheirsToken]);
  XCTAssertFalse([firstEnvelopeText containsString:firstOursToken]);
  XCTAssertFalse([firstEnvelopeText containsString:firstTheirsToken]);

  error = nil;
  NSDictionary *unchanged = [self.service
      prepareSelection:[self selectionForFixture:fixture
                                           paths:@[@"conflict.txt"]]
                   error:&error];
  XCTAssertNotNil(unchanged);
  XCTAssertNil(error);
  XCTAssertEqualObjects(unchanged[@"source_fingerprint"],
                        first[@"source_fingerprint"]);

  NSString *changedOursToken = @"CHANGED_OURS_MUST_STAY_PRIVATE_63C9";
  NSString *changedOurs = [changedOursToken stringByAppendingString:@"\n"];
  [self addConflictAtPath:@"conflict.txt"
          ancestorContent:@"base\n"
              oursContent:changedOurs
            theirsContent:firstTheirs
                  fixture:fixture];
  error = nil;
  NSDictionary *oursChanged = [self.service
      prepareSelection:[self selectionForFixture:fixture
                                           paths:@[@"conflict.txt"]]
                   error:&error];
  XCTAssertNotNil(oursChanged);
  XCTAssertNil(error);
  if (oursChanged == nil) return;
  XCTAssertTrue([lowercaseSHA256
      evaluateWithObject:oursChanged[@"source_fingerprint"]]);
  XCTAssertNotEqualObjects(oursChanged[@"source_fingerprint"],
                           first[@"source_fingerprint"]);

  NSString *changedTheirsToken = @"CHANGED_THEIRS_MUST_STAY_PRIVATE_74DA";
  NSString *changedTheirs =
      [changedTheirsToken stringByAppendingString:@"\n"];
  [self addConflictAtPath:@"conflict.txt"
          ancestorContent:@"base\n"
              oursContent:changedOurs
            theirsContent:changedTheirs
                  fixture:fixture];
  error = nil;
  NSDictionary *theirsChanged = [self.service
      prepareSelection:[self selectionForFixture:fixture
                                           paths:@[@"conflict.txt"]]
                   error:&error];
  XCTAssertNotNil(theirsChanged);
  XCTAssertNil(error);
  if (theirsChanged == nil) return;
  XCTAssertTrue([lowercaseSHA256
      evaluateWithObject:theirsChanged[@"source_fingerprint"]]);
  XCTAssertNotEqualObjects(theirsChanged[@"source_fingerprint"],
                           oursChanged[@"source_fingerprint"]);
  XCTAssertEqual([theirsChanged[@"included"] count], (NSUInteger)0);
  XCTAssertEqualObjects(theirsChanged[@"omitted"][0][@"path"],
                        @"conflict.txt");
  XCTAssertEqualObjects(theirsChanged[@"omitted"][0][@"reason"],
                        DSHProjectContextOmissionReasonPolicy);
  NSDictionary *changedStored =
      [self.store loadSnapshotId:theirsChanged[@"snapshot_id"] error:&error];
  NSData *changedManifestData =
      [NSJSONSerialization dataWithJSONObject:theirsChanged
                                      options:NSJSONWritingSortedKeys
                                        error:&error];
  NSString *changedManifestText = [[NSString alloc]
      initWithData:changedManifestData encoding:NSUTF8StringEncoding];
  NSString *changedEnvelopeText = [[NSString alloc]
      initWithData:changedStored[@"envelope"] encoding:NSUTF8StringEncoding];
  XCTAssertNotNil(changedEnvelopeText);
  for (NSString *token in @[ firstOursToken, firstTheirsToken,
                              changedOursToken, changedTheirsToken ]) {
    XCTAssertFalse([changedManifestText containsString:token]);
    XCTAssertFalse([changedEnvelopeText containsString:token]);
  }
}

- (void)testUnbornHeadIncludesCompleteStagedAddition {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"new.txt"
                                          content:@"UNBORN_STAGED_COMPLETE\n"
                                           commit:NO];
  NSError *error = nil;
  NSDictionary *manifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"new.txt"]]
                   error:&error];
  XCTAssertEqualObjects(manifest[@"head_oid"], NSNull.null);
  NSArray *sources = [manifest[@"included"] valueForKey:@"source"];
  XCTAssertTrue([sources containsObject:@"staged_diff"]);
  NSString *envelope = [[NSString alloc]
      initWithData:[self confirmedEnvelopeForManifest:manifest error:&error]
          encoding:NSUTF8StringEncoding];
  XCTAssertTrue([envelope containsString:@"UNBORN_STAGED_COMPLETE"]);
}

- (void)testFileByteBoundaryIncludes65536AndOmits65537WithoutReadingPastLimit {
  NSMutableData *atLimit = [NSMutableData
      dataWithLength:DSHProjectContextMaxFileBytes];
  memset(atLimit.mutableBytes, 'a', atLimit.length);
  NSMutableData *overLimit = [atLimit mutableCopy];
  const uint8_t extra = 'b';
  [overLimit appendBytes:&extra length:1];
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:nil
                                          content:nil
                                           commit:NO];
  [self writeBytes:atLimit relativePath:@"at-limit.txt" fixture:fixture];
  [self writeBytes:overLimit relativePath:@"over-limit.txt" fixture:fixture];
  [self addPathsToIndex:@[@"at-limit.txt", @"over-limit.txt"] fixture:fixture];
  [self commitFixture:fixture message:@"boundaries"];
  NSError *error = nil;
  NSDictionary *manifest = [self.service
      prepareSelection:[self selectionForFixture:fixture
                                           paths:@[@"at-limit.txt", @"over-limit.txt"]]
                   error:&error];
  NSPredicate *included = [NSPredicate predicateWithFormat:@"path == %@ AND bytes == %lu",
                                                       @"at-limit.txt",
                                                       (unsigned long)DSHProjectContextMaxFileBytes];
  XCTAssertEqual([manifest[@"included"] filteredArrayUsingPredicate:included].count,
                 (NSUInteger)1);
  NSPredicate *omitted = [NSPredicate
      predicateWithFormat:@"path == %@ AND reason == %@", @"over-limit.txt",
                          DSHProjectContextOmissionReasonBudgetExceeded];
  XCTAssertEqual([manifest[@"omitted"] filteredArrayUsingPredicate:omitted].count,
                 (NSUInteger)1);
}

- (void)testFileCountAndContextBudgetsUseWholeBlocksAndCeilingTokenEstimate {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:nil
                                          content:nil
                                           commit:NO];
  NSMutableArray<NSString *> *paths = [NSMutableArray array];
  NSString *large = [@"x" stringByPaddingToLength:9000
                                       withString:@"x"
                                  startingAtIndex:0];
  for (NSUInteger index = 0; index < DSHProjectContextMaxFiles + 1; index++) {
    NSString *path = [NSString stringWithFormat:@"src/file-%02lu.txt",
                                                (unsigned long)index];
    [paths addObject:path];
    [self writeString:large relativePath:path fixture:fixture];
  }
  [self addPathsToIndex:paths fixture:fixture];
  [self commitFixture:fixture message:@"many files"];
  NSError *error = nil;
  NSDictionary *manifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:paths]
                   error:&error];
  XCTAssertLessThanOrEqual([manifest[@"included"] count],
                           DSHProjectContextMaxFiles);
  XCTAssertLessThanOrEqual([manifest[@"context_bytes"] unsignedIntegerValue],
                           DSHProjectContextMaxContextBytes);
  NSUInteger bytes = [manifest[@"context_bytes"] unsignedIntegerValue];
  XCTAssertEqual([manifest[@"estimated_tokens"] unsignedIntegerValue],
                 (bytes + 3) / 4);
  XCTAssertGreaterThan([manifest[@"omitted"] count], (NSUInteger)0);
}

- (void)testChangedPathBudgetAllows100AndRejects101 {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:nil
                                          content:nil
                                           commit:NO];
  NSMutableArray<NSString *> *paths = [NSMutableArray array];
  for (NSUInteger index = 0; index < DSHProjectContextMaxChangedPaths + 1; index++) {
    NSString *path = [NSString stringWithFormat:@"src/change-%03lu.txt",
                                                (unsigned long)index];
    [paths addObject:path];
    [self writeString:@"before\n" relativePath:path fixture:fixture];
  }
  [self addPathsToIndex:paths fixture:fixture];
  [self commitFixture:fixture message:@"changes"];
  for (NSString *path in paths) {
    [self writeString:@"after\n" relativePath:path fixture:fixture];
  }
  NSError *error = nil;
  XCTAssertNil([self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[]]
                   error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextServiceErrorBudgetExceeded);

  NSString *last = paths.lastObject;
  [self writeString:@"before\n" relativePath:last fixture:fixture];
  error = nil;
  XCTAssertNotNil([self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[]]
                   error:&error]);
  XCTAssertNil(error);
}

- (void)testCandidateEntryBoundaryAllows5000AndRejects5001BeforePaging {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:nil
                                          content:nil
                                           commit:NO];
  NSURL *sourceURL = [fixture.repositoryURL
      URLByAppendingPathComponent:@"src"
                      isDirectory:YES];
  XCTAssertTrue([[NSFileManager defaultManager]
      createDirectoryAtURL:sourceURL
      withIntermediateDirectories:YES
      attributes:nil
      error:nil]);
  git_index *index = nullptr;
  XCTAssertEqual(git_repository_index(&index, fixture.repository), 0);
  NSData *oneByte = DSHData(@"x");
  for (NSUInteger item = 0; item < DSHProjectContextMaxEntries; item++) {
    NSString *path = [NSString stringWithFormat:@"src/f-%04lu.txt",
                                                (unsigned long)item];
    XCTAssertTrue([oneByte
        writeToURL:[fixture.repositoryURL URLByAppendingPathComponent:path]
        atomically:YES]);
    XCTAssertEqual(git_index_add_bypath(index, path.UTF8String), 0);
  }
  XCTAssertEqual(git_index_write(index), 0);
  git_index_free(index);
  [self commitFixture:fixture message:@"five thousand"];
  NSError *error = nil;
  NSDictionary *page = [self.service listCandidatesForProjectId:fixture.projectId
                                                           query:@""
                                                          cursor:nil
                                                           error:&error];
  XCTAssertNotNil(page);
  XCTAssertNil(error);
  XCTAssertEqual([page[@"candidates"] count], (NSUInteger)100);
  XCTAssertNotNil(page[@"next_cursor"]);

  NSString *overflowPath = @"src/f-5000.txt";
  XCTAssertTrue([oneByte
      writeToURL:[fixture.repositoryURL URLByAppendingPathComponent:overflowPath]
      atomically:YES]);
  [self addPathToIndex:overflowPath fixture:fixture];
  error = nil;
  XCTAssertNil([self.service listCandidatesForProjectId:fixture.projectId
                                                   query:@""
                                                  cursor:nil
                                                   error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextServiceErrorBudgetExceeded);
}

- (void)testCandidateCursorStalesWhenSymbolicHeadChangesAtSameCommit {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:nil
                                          content:nil
                                           commit:NO];
  NSMutableArray<NSString *> *paths = [NSMutableArray array];
  for (NSUInteger index = 0;
       index < DSHProjectContextMaxCandidatePageSize + 1; index++) {
    NSString *path = [NSString stringWithFormat:@"src/cursor-%03lu.swift",
                                                (unsigned long)index];
    [paths addObject:path];
    [self writeString:@"let value = 1\n" relativePath:path fixture:fixture];
  }
  [self addPathsToIndex:paths fixture:fixture];
  [self commitFixture:fixture message:@"cursor base"];
  NSError *error = nil;
  NSDictionary *first = [self.service
      listCandidatesForProjectId:fixture.projectId query:@"" cursor:nil
                           error:&error];
  XCTAssertNotNil(first[@"next_cursor"]);

  git_reference *head = nullptr;
  git_reference *sameTip = nullptr;
  XCTAssertEqual(git_repository_head(&head, fixture.repository), 0);
  const git_oid *target = git_reference_target(head);
  XCTAssertNotEqual(target, nullptr);
  XCTAssertEqual(git_reference_create(&sameTip, fixture.repository,
                                      "refs/heads/same-tip", target, 0,
                                      "candidate cursor branch"), 0);
  if (sameTip != nullptr) git_reference_free(sameTip);
  if (head != nullptr) git_reference_free(head);
  XCTAssertEqual(git_repository_set_head(fixture.repository,
                                         "refs/heads/same-tip"), 0);

  error = nil;
  XCTAssertNil([self.service
      listCandidatesForProjectId:fixture.projectId query:@""
                           cursor:first[@"next_cursor"] error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextServiceErrorChanged);
}

- (void)testCandidateGitStateReportsExecutableModeChangeAsUnstaged {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"script.sh"
                                          content:@"#!/bin/sh\n"
                                           commit:YES];
  git_config *config = nullptr;
  XCTAssertEqual(git_repository_config(&config, fixture.repository), 0);
  XCTAssertEqual(git_config_set_bool(config, "core.filemode", 1), 0);
  git_config_free(config);
  NSURL *script = [fixture.repositoryURL URLByAppendingPathComponent:@"script.sh"];
  XCTAssertEqual(chmod(script.fileSystemRepresentation, 0755), 0);

  NSError *error = nil;
  NSDictionary *page = [self.service
      listCandidatesForProjectId:fixture.projectId query:@"script.sh"
                           cursor:nil error:&error];
  XCTAssertNil(error);
  XCTAssertEqual([page[@"candidates"] count], (NSUInteger)1);
  XCTAssertEqualObjects(page[@"candidates"][0][@"git_state"], @"unstaged");
}

- (void)testCandidateListingFailsClosedForRealInvalidUTF8IndexPath {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:nil
                                          content:nil
                                           commit:NO];
  XCTAssertNotNil(fixture);
  if (fixture == nil) return;
  const char invalidPath[] = {'s', 'r', 'c', '/', (char)0xff,
                              (char)0xfe, '.', 'm', 'd', '\0'};
  int repositoryFD = -1;
  int rawFileFD = -1;
  git_index *index = nullptr;
  @try {
    repositoryFD = open(fixture.repositoryURL.fileSystemRepresentation,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    XCTAssertGreaterThanOrEqual(repositoryFD, 0);
    if (repositoryFD < 0) return;
    int directoryResult = mkdirat(repositoryFD, "src", 0700);
    XCTAssertTrue(directoryResult == 0 || errno == EEXIST);
    if (directoryResult != 0 && errno != EEXIST) return;
    rawFileFD = openat(repositoryFD, invalidPath,
                       O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                       0600);
    if (rawFileFD < 0) {
      int rawOpenError = errno;
      // APFS rejects non-UTF-8 directory entries at the syscall boundary.
      // Keep the raw index fixture below so the service still receives the
      // exact bytes; filesystems that permit them also exercise live cleanup.
      XCTAssertEqual(rawOpenError, EILSEQ);
    } else {
      const uint8_t contents = 'x';
      ssize_t written = write(rawFileFD, &contents, sizeof(contents));
      XCTAssertEqual(written, (ssize_t)sizeof(contents));
      if (written != (ssize_t)sizeof(contents)) return;
      int syncResult = fsync(rawFileFD);
      XCTAssertEqual(syncResult, 0);
      if (syncResult != 0) return;
      close(rawFileFD);
      rawFileFD = -1;
    }

    int result = git_repository_index(&index, fixture.repository);
    if (![self requireGitResult:result operation:@"git_repository_index"] ||
        ![self requirePointer:index operation:@"git_repository_index"]) {
      return;
    }
    git_index_entry entry = {};
    entry.path = invalidPath;
    entry.mode = GIT_FILEMODE_BLOB;
    entry.file_size = 1;
    result = git_blob_create_from_buffer(&entry.id, fixture.repository, "x", 1);
    if (![self requireGitResult:result operation:@"git_blob_create invalid path"])
      return;
    result = git_index_add(index, &entry);
    if (![self requireGitResult:result operation:@"git_index_add invalid path"])
      return;
    result = git_index_write(index);
    if (![self requireGitResult:result operation:@"git_index_write invalid path"])
      return;
    result = git_index_read(index, 1);
    if (![self requireGitResult:result operation:@"git_index_read invalid path"])
      return;
    BOOL foundExactBytes = NO;
    for (size_t item = 0; item < git_index_entrycount(index); item++) {
      const git_index_entry *stored = git_index_get_byindex(index, item);
      if (stored != nullptr && stored->path != nullptr &&
          memcmp(stored->path, invalidPath, sizeof(invalidPath)) == 0) {
        foundExactBytes = YES;
        break;
      }
    }
    XCTAssertTrue(foundExactBytes);
    git_index_free(index);
    index = nullptr;

    NSError *firstError = nil;
    __block NSDictionary *firstPage = nil;
    XCTAssertNoThrow(firstPage = [self.service
        listCandidatesForProjectId:fixture.projectId query:@"" cursor:nil
                             error:&firstError]);
    XCTAssertNil(firstPage);
    XCTAssertEqualObjects(firstError.domain,
                          DSHProjectContextServiceErrorDomain);
    XCTAssertEqual(firstError.code, DSHProjectContextServiceErrorIntegrity);
    XCTAssertFalse([firstError.localizedDescription containsString:@"src"]);

    NSError *secondError = nil;
    __block NSDictionary *secondPage = nil;
    XCTAssertNoThrow(secondPage = [self.service
        listCandidatesForProjectId:fixture.projectId query:@"" cursor:nil
                             error:&secondError]);
    XCTAssertNil(secondPage);
    XCTAssertEqualObjects(secondError.domain,
                          DSHProjectContextServiceErrorDomain);
    XCTAssertEqual(secondError.code, DSHProjectContextServiceErrorIntegrity);
    XCTAssertEqualObjects(secondError.domain, firstError.domain);
    XCTAssertEqual(secondError.code, firstError.code);
    XCTAssertEqualObjects(secondError.localizedDescription,
                          firstError.localizedDescription);

    NSData *errorBytes = [[NSString stringWithFormat:@"%@", firstError]
        dataUsingEncoding:NSUTF8StringEncoding];
    NSData *rawPathBytes = [NSData dataWithBytes:invalidPath
                                           length:sizeof(invalidPath) - 1];
    NSData *pathPrefix = [@"src/" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange fullRange = NSMakeRange(0, errorBytes.length);
    XCTAssertEqual([errorBytes rangeOfData:rawPathBytes options:0 range:fullRange].location,
                   NSNotFound);
    XCTAssertEqual([errorBytes rangeOfData:pathPrefix options:0 range:fullRange].location,
                   NSNotFound);
  } @finally {
    if (index != nullptr) git_index_free(index);
    if (rawFileFD >= 0) close(rawFileFD);
    if (repositoryFD >= 0) {
      unlinkat(repositoryFD, invalidPath, 0);
      unlinkat(repositoryFD, "src", AT_REMOVEDIR);
      close(repositoryFD);
    }
  }
}

- (void)testDiffBudgetIncludesOnlyWholePatchesAndNeverTruncatesAt128KiB {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:nil
                                          content:nil
                                           commit:NO];
  NSMutableArray<NSString *> *paths = [NSMutableArray array];
  for (NSUInteger file = 0; file < 3; file++) {
    NSString *path = [NSString stringWithFormat:@"src/large-%lu.txt",
                                                (unsigned long)file];
    [paths addObject:path];
    NSMutableString *before = [NSMutableString string];
    for (NSUInteger line = 0; line < 1800; line++) {
      [before appendFormat:@"f%lu-before-%04lu-aaaaaaaaaaaaaaaa\n",
                           (unsigned long)file, (unsigned long)line];
    }
    [self writeString:before relativePath:path fixture:fixture];
  }
  [self addPathsToIndex:paths fixture:fixture];
  [self commitFixture:fixture message:@"large base"];
  for (NSUInteger file = 0; file < paths.count; file++) {
    NSMutableString *after = [NSMutableString string];
    for (NSUInteger line = 0; line < 1800; line++) {
      [after appendFormat:@"f%lu-after-%04lu-bbbbbbbbbbbbbbbb\n",
                          (unsigned long)file, (unsigned long)line];
    }
    [after appendFormat:@"TAIL_SENTINEL_FILE_%lu\n", (unsigned long)file];
    [self writeString:after relativePath:paths[file] fixture:fixture];
  }
  NSError *error = nil;
  NSDictionary *manifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:paths]
                   error:&error];
  XCTAssertNotNil(manifest);
  NSUInteger totalDiffBytes = 0;
  for (NSDictionary *entry in manifest[@"included"]) {
    if (![entry[@"source"] isEqual:@"tracked_file"]) {
      totalDiffBytes += [entry[@"bytes"] unsignedIntegerValue];
    }
  }
  XCTAssertLessThanOrEqual(totalDiffBytes, DSHProjectContextMaxDiffBytes);
  NSPredicate *budget = [NSPredicate
      predicateWithFormat:@"reason == %@",
                          DSHProjectContextOmissionReasonBudgetExceeded];
  XCTAssertGreaterThan([manifest[@"omitted"] filteredArrayUsingPredicate:budget].count,
                       (NSUInteger)0);
  NSDictionary *stored = [self.store loadSnapshotId:manifest[@"snapshot_id"]
                                               error:&error];
  NSString *envelope = [[NSString alloc] initWithData:stored[@"envelope"]
                                              encoding:NSUTF8StringEncoding];
  for (NSDictionary *entry in manifest[@"included"]) {
    if (![entry[@"source"] isEqual:@"tracked_file"]) {
      NSString *path = entry[@"path"];
      NSUInteger index = [paths indexOfObject:path];
      XCTAssertNotEqual(index, NSNotFound);
      NSString *tail = [NSString stringWithFormat:@"TAIL_SENTINEL_FILE_%lu",
                                                   (unsigned long)index];
      XCTAssertTrue([envelope containsString:tail]);
    }
  }
}

- (void)testPrepareDeadlineAllowsExactlyTwoSecondsAndRejectsNextMillisecond {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"README.md"
                                          content:@"deadline\n"
                                           commit:YES];
  NSDate *base = self.now;
  __block NSDate *clockNow = base;
  __block BOOL advance = NO;
  DSHProjectContextService *(^makeService)(NSTimeInterval) =
      ^DSHProjectContextService *(NSTimeInterval elapsed) {
        clockNow = base;
        advance = NO;
        return [[DSHProjectContextService alloc]
            initWithProjectAccess:self.access
                            store:self.store
                           policy:[[DSHProjectContextPolicy alloc] init]
                            clock:^NSDate *{ return clockNow; }
              identifierGenerator:^NSString *{
                self.nextIdentifier += 1;
                return [NSString stringWithFormat:@"cccccccc-cccc-4ccc-8ccc-%012lu",
                                                  (unsigned long)self.nextIdentifier];
              }
                             hook:^(NSString *stage, __unused NSString *path) {
                               if (!advance &&
                                   [stage isEqual:@"before_fingerprint_recheck"]) {
                                 advance = YES;
                                 clockNow = [base dateByAddingTimeInterval:elapsed];
                               }
                             }];
      };
  NSError *error = nil;
  XCTAssertNotNil([makeService(2.0)
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error]);
  XCTAssertNil(error);
  error = nil;
  XCTAssertNil([makeService(2.001)
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextServiceErrorTimeout);
}

- (void)testTamperedSnapshotFailsIntegrityAndRestartRestoresUntamperedSnapshot {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"README.md"
                                          content:@"restart safe\n"
                                           commit:YES];
  NSError *error = nil;
  NSDictionary *manifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error];
  XCTAssertNotNil([self.service confirmSnapshotId:manifest[@"snapshot_id"]
                                          error:&error]);
  DSHProjectContextStore *restoredStore = [[DSHProjectContextStore alloc]
      initWithRootURL:self.storeURL
      capacityBytes:64 * 1024 * 1024
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  XCTAssertNotNil([restoredStore loadSnapshotId:manifest[@"snapshot_id"] error:&error]);
  NSURL *envelopeURL = [restoredStore fileURLsForSnapshotId:manifest[@"snapshot_id"]
                                                     error:&error].firstObject;
  NSMutableData *tampered =
      [[NSData dataWithContentsOfURL:envelopeURL] mutableCopy];
  uint8_t *bytes = static_cast<uint8_t *>(tampered.mutableBytes);
  bytes[tampered.length / 2] ^= 0x01;
  XCTAssertTrue([tampered writeToURL:envelopeURL atomically:NO]);
  chmod(envelopeURL.fileSystemRepresentation, 0600);
  error = nil;
  XCTAssertNil([restoredStore loadSnapshotId:manifest[@"snapshot_id"] error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextStoreErrorIntegrity);
}

- (void)testTamperedSnapshotRecordCannotRetargetProjectOrConsentBinding {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"README.md"
                                          content:@"record binding\n"
                                           commit:YES];
  NSError *error = nil;
  NSDictionary *manifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error];
  NSArray<NSURL *> *files = [self.store fileURLsForSnapshotId:manifest[@"snapshot_id"]
                                                       error:&error];
  NSURL *recordURL = nil;
  for (NSURL *url in files) {
    if ([url.pathExtension isEqual:@"json"]) recordURL = url;
  }
  NSMutableDictionary *record = [[NSJSONSerialization
      JSONObjectWithData:[NSData dataWithContentsOfURL:recordURL]
                 options:NSJSONReadingMutableContainers
                   error:nil] mutableCopy];
  record[@"source_descriptor"][@"project_id"] = DSHFixtureProjectB;
  NSData *retargeted = [NSJSONSerialization dataWithJSONObject:record
                                                       options:NSJSONWritingSortedKeys
                                                         error:nil];
  XCTAssertTrue([retargeted writeToURL:recordURL atomically:NO]);
  chmod(recordURL.fileSystemRepresentation, 0600);
  error = nil;
  XCTAssertNil([self.store loadSnapshotId:manifest[@"snapshot_id"] error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextStoreErrorIntegrity);
}

- (void)testSnapshotRecordRejectsFractionalEnvelopeLengthEvenWithValidRecordHash {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"README.md"
                                          content:@"numeric schema\n"
                                           commit:YES];
  NSError *error = nil;
  NSDictionary *manifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error];
  NSURL *recordURL = nil;
  for (NSURL *url in [self.store fileURLsForSnapshotId:manifest[@"snapshot_id"]
                                                    error:&error]) {
    if ([url.pathExtension isEqual:@"json"]) recordURL = url;
  }
  NSMutableDictionary *record = [[NSJSONSerialization
      JSONObjectWithData:[NSData dataWithContentsOfURL:recordURL]
                 options:NSJSONReadingMutableContainers
                   error:nil] mutableCopy];
  record[@"envelope_bytes"] =
      @([record[@"envelope_bytes"] doubleValue] + 0.5);
  [record removeObjectForKey:@"record_sha256"];
  NSData *core = [NSJSONSerialization dataWithJSONObject:record
                                                 options:NSJSONWritingSortedKeys
                                                   error:nil];
  record[@"record_sha256"] = DSHSHA256Hex(core);
  NSData *data = [NSJSONSerialization dataWithJSONObject:record
                                                  options:NSJSONWritingSortedKeys
                                                    error:nil];
  XCTAssertTrue([data writeToURL:recordURL atomically:NO]);
  chmod(recordURL.fileSystemRepresentation, 0600);
  error = nil;
  XCTAssertNil([self.store loadSnapshotId:manifest[@"snapshot_id"] error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextStoreErrorIntegrity);
}

- (void)testTamperedConsentReceiptFailsItsOwnIntegrityHash {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"README.md"
                                          content:@"consent integrity\n"
                                           commit:YES];
  NSError *error = nil;
  NSDictionary *manifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error];
  NSDictionary *consent =
      [self.service confirmSnapshotId:manifest[@"snapshot_id"] error:&error];
  NSURL *consentURL = nil;
  for (NSURL *url in [self.store fileURLsForSnapshotId:manifest[@"snapshot_id"]
                                                    error:&error]) {
    if ([url.URLByDeletingLastPathComponent.lastPathComponent
            isEqual:@"consents"]) {
      consentURL = url;
    }
  }
  XCTAssertNotNil(consentURL);
  NSMutableDictionary *receipt = [[NSJSONSerialization
      JSONObjectWithData:[NSData dataWithContentsOfURL:consentURL]
                 options:NSJSONReadingMutableContainers
                   error:nil] mutableCopy];
  receipt[@"snapshot_id"] = DSHFixtureProjectB;
  NSData *data = [NSJSONSerialization dataWithJSONObject:receipt
                                                  options:NSJSONWritingSortedKeys
                                                    error:nil];
  XCTAssertTrue([data writeToURL:consentURL atomically:NO]);
  chmod(consentURL.fileSystemRepresentation, 0600);
  error = nil;
  XCTAssertNil([self.store loadConsentReceiptId:consent[@"consent_receipt_id"]
                                         error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextStoreErrorIntegrity);
}

- (void)testDeterministicTOCTOUReplacementFailsClosedWithoutSleeps {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"README.md"
                                          content:@"original inode\n"
                                           commit:YES];
  __block BOOL replaced = NO;
  DSHProjectContextService *service = [[DSHProjectContextService alloc]
      initWithProjectAccess:self.access
                      store:self.store
                     policy:[[DSHProjectContextPolicy alloc] init]
                      clock:^NSDate *{ return self.now; }
        identifierGenerator:^NSString *{
          self.nextIdentifier += 1;
          return [NSString stringWithFormat:@"bbbbbbbb-bbbb-4bbb-8bbb-%012lu",
                                            (unsigned long)self.nextIdentifier];
        }
                       hook:^(NSString *stage, NSString *path) {
                         if (!replaced && [stage isEqual:@"after_file_open"] &&
                             [path isEqual:@"README.md"]) {
                           replaced = YES;
                           NSURL *replacement = [fixture.repositoryURL
                               URLByAppendingPathComponent:@"replacement.tmp"];
                           [DSHData(@"replacement inode\n") writeToURL:replacement
                                                             atomically:YES];
                           rename(replacement.fileSystemRepresentation,
                                  [fixture.repositoryURL
                                      URLByAppendingPathComponent:@"README.md"]
                                      .fileSystemRepresentation);
                         }
                       }];
  NSError *error = nil;
  XCTAssertNil([service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error]);
  XCTAssertTrue(replaced);
  XCTAssertEqual(error.code, DSHProjectContextServiceErrorChanged);
}

- (void)testFileChangeMarksSnapshotStale {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"README.md"
                                          content:@"version one\n"
                                           commit:YES];
  NSError *error = nil;
  NSDictionary *manifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error];
  NSDictionary *consent =
      [self.service confirmSnapshotId:manifest[@"snapshot_id"] error:&error];
  [self writeString:@"version two\n"
       relativePath:@"README.md"
            fixture:fixture];
  NSDictionary *inspection =
      [self.service inspectSnapshotId:manifest[@"snapshot_id"] error:&error];
  XCTAssertEqualObjects(inspection[@"state"], @"stale");
  NSData *envelope = [self.service
      verifiedEnvelopeForSnapshotId:manifest[@"snapshot_id"]
                    consentReceiptId:consent[@"consent_receipt_id"]
                         requestBind:[self requestBindForManifest:manifest]
                             receipt:nil
                               error:&error];
  XCTAssertNil(envelope);
  XCTAssertEqualObjects(error.domain, DSHProjectContextServiceErrorDomain);
  XCTAssertEqual(error.code, DSHProjectContextServiceErrorChanged);
}

- (void)testHeadAndIndexChangeMarkSnapshotStale {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"README.md"
                                          content:@"head one\n"
                                           commit:YES];
  NSError *error = nil;
  NSDictionary *headManifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error];
  [self writeString:@"head two\n" relativePath:@"README.md" fixture:fixture];
  [self addPathToIndex:@"README.md" fixture:fixture];
  [self commitFixture:fixture message:@"head changed"];
  XCTAssertEqualObjects([self.service inspectSnapshotId:headManifest[@"snapshot_id"]
                                                       error:&error][@"state"],
                        @"stale");

  NSDictionary *indexManifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error];
  [self writeString:@"index changed\n"
       relativePath:@"README.md"
            fixture:fixture];
  [self addPathToIndex:@"README.md" fixture:fixture];
  XCTAssertEqualObjects([self.service inspectSnapshotId:indexManifest[@"snapshot_id"]
                                                       error:&error][@"state"],
                        @"stale");
}

- (void)testProjectMetadataAndOmittedHardlinkIdentityChangesMarkSnapshotStale {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"hard.txt"
                                          content:@"same tracked bytes\n"
                                           commit:YES];
  NSURL *tracked = [fixture.repositoryURL URLByAppendingPathComponent:@"hard.txt"];
  NSURL *outsideAlias = [fixture.projectURL URLByAppendingPathComponent:@"outside-alias"];
  XCTAssertEqual(link(tracked.fileSystemRepresentation,
                      outsideAlias.fileSystemRepresentation),
                 0);
  NSError *error = nil;
  NSDictionary *hardlinkManifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"hard.txt"]]
                   error:&error];
  XCTAssertNotNil(hardlinkManifest);
  XCTAssertEqualObjects(hardlinkManifest[@"omitted"][0][@"reason"],
                        DSHProjectContextOmissionReasonPolicy);
  XCTAssertEqual(unlink(outsideAlias.fileSystemRepresentation), 0);
  XCTAssertEqualObjects([self.service
      inspectSnapshotId:hardlinkManifest[@"snapshot_id"] error:&error][@"state"],
                        @"stale");

  NSDictionary *metadataManifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"hard.txt"]]
                   error:&error];
  DSHLocalProjectLease *writeLease = [self.access
      leaseProjectId:fixture.projectId mode:DSHLocalProjectAccessModeWrite
      includeMetadata:NO timeout:0 error:&error];
  XCTAssertNotNil(writeLease, @"%@", error);
  NSDictionary *metadata = @{
    @"schema_version" : @1,
    @"name" : @"Metadata Changed",
    @"created_at" : @"2026-05-03T03:22:57.125Z",
    @"updated_at" : @"2026-05-05T03:22:57.125Z",
    @"origin_url" : NSNull.null,
  };
  error = nil;
  XCTAssertTrue([self.access writeProjectMetadataRecord:metadata
                                                  lease:writeLease error:&error],
                @"%@", error);
  writeLease = nil;
  XCTAssertEqualObjects([self.service
      inspectSnapshotId:metadataManifest[@"snapshot_id"] error:&error][@"state"],
                        @"stale");

  NSDictionary *recreationManifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"hard.txt"]]
                   error:&error];
  XCTAssertNotNil(recreationManifest);
  struct stat repositoryBefore = {};
  struct stat projectBefore = {};
  XCTAssertEqual(stat(fixture.repositoryURL.fileSystemRepresentation,
                      &repositoryBefore),
                 0);
  XCTAssertEqual(stat(fixture.projectURL.fileSystemRepresentation,
                      &projectBefore),
                 0);
  NSURL *oldProjectURL = [self.projectsURL
      URLByAppendingPathComponent:[fixture.projectId stringByAppendingString:@"-old"]
                      isDirectory:YES];
  XCTAssertEqual(rename(fixture.projectURL.fileSystemRepresentation,
                        oldProjectURL.fileSystemRepresentation),
                 0);
  XCTAssertTrue([[NSFileManager defaultManager]
      createDirectoryAtURL:fixture.projectURL
      withIntermediateDirectories:NO
      attributes:@{NSFilePosixPermissions : @0700}
      error:&error]);
  NSURL *oldRepositoryURL =
      [oldProjectURL URLByAppendingPathComponent:@"repo" isDirectory:YES];
  XCTAssertEqual(rename(oldRepositoryURL.fileSystemRepresentation,
                        fixture.repositoryURL.fileSystemRepresentation),
                 0);
  NSData *metadataBytes = [NSData dataWithContentsOfURL:
      [oldProjectURL URLByAppendingPathComponent:@"project.json"]];
  XCTAssertNotNil(metadataBytes);
  XCTAssertTrue([metadataBytes
      writeToURL:[fixture.projectURL URLByAppendingPathComponent:@"project.json"]
         options:NSDataWritingAtomic
           error:&error]);
  struct stat repositoryAfter = {};
  struct stat projectAfter = {};
  XCTAssertEqual(stat(fixture.repositoryURL.fileSystemRepresentation,
                      &repositoryAfter),
                 0);
  XCTAssertEqual(stat(fixture.projectURL.fileSystemRepresentation,
                      &projectAfter),
                 0);
  XCTAssertEqual(repositoryAfter.st_dev, repositoryBefore.st_dev);
  XCTAssertEqual(repositoryAfter.st_ino, repositoryBefore.st_ino);
  XCTAssertNotEqual(projectAfter.st_ino, projectBefore.st_ino);
  XCTAssertEqualObjects([self.service
      inspectSnapshotId:recreationManifest[@"snapshot_id"] error:&error][@"state"],
                        @"stale");
}

- (void)testDirectorySelectionExpandsTrackedSafeFilesAndEnvelopeStatusIsRedacted {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"src/A.swift"
                                          content:@"let a = 1\n"
                                           commit:YES];
  [self writeString:@"let b = 1\n" relativePath:@"src/B.swift" fixture:fixture];
  [self writeString:@"rename payload\n" relativePath:@"src/.env.secret" fixture:fixture];
  [self addPathsToIndex:@[@"src/B.swift", @"src/.env.secret"] fixture:fixture];
  [self commitFixture:fixture message:@"directory files"];
  NSError *error = nil;
  NSDictionary *baselineManifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"src"]]
                   error:&error];
  XCTAssertNotNil(baselineManifest, @"baseline: %@", error);
  [self writeString:@"let b = 2\n" relativePath:@"src/B.swift" fixture:fixture];
  error = nil;
  NSDictionary *worktreeManifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"src"]]
                   error:&error];
  XCTAssertNotNil(worktreeManifest, @"worktree: %@", error);
  NSURL *oldURL = [fixture.repositoryURL URLByAppendingPathComponent:@"src/.env.secret"];
  NSURL *newURL = [fixture.repositoryURL URLByAppendingPathComponent:@"src/Public.swift"];
  XCTAssertEqual(rename(oldURL.fileSystemRepresentation, newURL.fileSystemRepresentation), 0);
  [self removePathFromIndex:@"src/.env.secret" fixture:fixture];
  [self addPathToIndex:@"src/Public.swift" fixture:fixture];
  [self writeString:@"UNTRACKED_DIRECTORY_SENTINEL"
       relativePath:@"src/untracked.swift" fixture:fixture];
  error = nil;
  NSDictionary *manifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"src"]]
                   error:&error];
  XCTAssertNotNil(manifest, @"%@", error);
  NSArray *includedPaths = [manifest[@"included"] valueForKey:@"path"];
  XCTAssertTrue([includedPaths containsObject:@"src/A.swift"]);
  XCTAssertTrue([includedPaths containsObject:@"src/B.swift"]);
  XCTAssertFalse([includedPaths containsObject:@"src/untracked.swift"]);
  NSDictionary *stored = [self.store loadSnapshotId:manifest[@"snapshot_id"] error:&error];
  NSString *envelope = [[NSString alloc] initWithData:stored[@"envelope"]
                                              encoding:NSUTF8StringEncoding];
  XCTAssertTrue([envelope containsString:@"tracked_status"]);
  XCTAssertTrue([envelope containsString:@"src/B.swift"]);
  XCTAssertFalse([envelope containsString:@"src/.env.secret"]);
  XCTAssertFalse([envelope containsString:@"UNTRACKED_DIRECTORY_SENTINEL"]);
}

- (NSURL *)looseObjectURLForOid:(const git_oid *)oid fixture:(DSHProjectFixture *)fixture {
  NSString *hex = DSHOidString(oid);
  return [[fixture.repositoryURL URLByAppendingPathComponent:@".git/objects"]
      URLByAppendingPathComponent:[NSString stringWithFormat:@"%@/%@",
          [hex substringToIndex:2], [hex substringFromIndex:2]]];
}

- (void)testMissingGitCommitOrSelectedBlobObjectFailsClosed {
  DSHProjectFixture *commitFixture = [self createProject:DSHFixtureProjectA
                                                   name:@"Alpha"
                                            initialFile:@"README.md"
                                                content:@"commit object\n"
                                                 commit:YES];
  git_reference *head = nullptr;
  XCTAssertEqual(git_repository_head(&head, commitFixture.repository), 0);
  NSURL *commitObject = [self looseObjectURLForOid:git_reference_target(head)
                                           fixture:commitFixture];
  git_reference_free(head);
  XCTAssertEqual(unlink(commitObject.fileSystemRepresentation), 0);
  NSError *error = nil;
  XCTAssertNil([self.service
      prepareSelection:[self selectionForFixture:commitFixture paths:@[@"README.md"]]
                   error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextServiceErrorIntegrity);

  DSHProjectFixture *blobFixture = [self createProject:DSHFixtureProjectB
                                                 name:@"Beta"
                                          initialFile:@"README.md"
                                              content:@"blob object\n"
                                               commit:YES];
  git_index *index = nullptr;
  XCTAssertEqual(git_repository_index(&index, blobFixture.repository), 0);
  const git_index_entry *entry = git_index_get_bypath(index, "README.md", 0);
  git_oid blobOid = entry->id;
  git_index_free(index);
  NSURL *blobObject = [self looseObjectURLForOid:&blobOid fixture:blobFixture];
  XCTAssertEqual(unlink(blobObject.fileSystemRepresentation), 0);
  error = nil;
  XCTAssertNil([self.service
      prepareSelection:[self selectionForFixture:blobFixture paths:@[@"README.md"]]
                   error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextServiceErrorIntegrity);
}

- (void)testOmittedTrackedObservationsStaleForUnsafeAncestorBinaryAndFileLimit {
  DSHProjectFixture *binary = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"image.png"
                                          content:@"BASE"
                                           commit:YES];
  [self writeString:@"AAAA" relativePath:@"image.png" fixture:binary];
  NSError *error = nil;
  NSDictionary *binaryManifest = [self.service
      prepareSelection:[self selectionForFixture:binary paths:@[@"image.png"]]
                   error:&error];
  XCTAssertNotNil(binaryManifest);
  [self writeString:@"BBBB" relativePath:@"image.png" fixture:binary];
  XCTAssertEqualObjects([self.service
      inspectSnapshotId:binaryManifest[@"snapshot_id"] error:&error][@"state"],
                        @"stale");

  DSHProjectFixture *unsafe = [self createProject:DSHFixtureProjectB
                                             name:@"Beta"
                                      initialFile:@"dir/file.txt"
                                          content:@"tracked\n"
                                           commit:YES];
  NSURL *realDirectory =
      [unsafe.repositoryURL URLByAppendingPathComponent:@"dir-real"];
  NSURL *directory = [unsafe.repositoryURL URLByAppendingPathComponent:@"dir"];
  XCTAssertEqual(rename(directory.fileSystemRepresentation,
                        realDirectory.fileSystemRepresentation),
                 0);
  for (NSString *name in @[@"alt-a", @"alt-b"]) {
    NSURL *alternate = [unsafe.repositoryURL URLByAppendingPathComponent:name];
    XCTAssertTrue([[NSFileManager defaultManager]
        createDirectoryAtURL:alternate withIntermediateDirectories:NO
        attributes:@{NSFilePosixPermissions : @0700} error:&error]);
    XCTAssertTrue([DSHData(@"alternate\n") writeToURL:
        [alternate URLByAppendingPathComponent:@"file.txt"] atomically:YES]);
  }
  XCTAssertEqual(symlink("alt-a", directory.fileSystemRepresentation), 0);
  NSDictionary *unsafeManifest = [self.service
      prepareSelection:[self selectionForFixture:unsafe paths:@[@"dir/file.txt"]]
                   error:&error];
  XCTAssertNotNil(unsafeManifest);
  XCTAssertEqual(unlink(directory.fileSystemRepresentation), 0);
  XCTAssertEqual(symlink("alt-b", directory.fileSystemRepresentation), 0);
  XCTAssertEqualObjects([self.service
      inspectSnapshotId:unsafeManifest[@"snapshot_id"] error:&error][@"state"],
                        @"stale");

  // A fresh project ID avoids the intentionally unsafe worktree above.
  git_repository_free(unsafe.repository);
  unsafe.repository = nullptr;
  [[NSFileManager defaultManager] removeItemAtURL:unsafe.projectURL error:nil];
  DSHProjectFixture *limited = [self createProject:DSHFixtureProjectB
                                              name:@"Limit"
                                       initialFile:@"f00.txt"
                                           content:@"base\n"
                                            commit:YES];
  NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithObject:@"f00.txt"];
  for (NSUInteger index = 1; index <= DSHProjectContextMaxFiles; index++) {
    NSString *path = [NSString stringWithFormat:@"f%02lu.txt", (unsigned long)index];
    [paths addObject:path];
    [self writeString:@"base\n" relativePath:path fixture:limited];
  }
  [self addPathsToIndex:[paths subarrayWithRange:NSMakeRange(1, paths.count - 1)]
                  fixture:limited];
  [self commitFixture:limited message:@"file limit fixture"];
  NSString *limitedPath = paths.lastObject;
  [self writeString:@"AAAA\n" relativePath:limitedPath fixture:limited];
  NSDictionary *limitedManifest = [self.service
      prepareSelection:[self selectionForFixture:limited paths:paths]
                   error:&error];
  XCTAssertNotNil(limitedManifest);
  XCTAssertTrue([[limitedManifest[@"omitted"] valueForKey:@"path"]
      containsObject:limitedPath]);
  [self writeString:@"BBBB\n" relativePath:limitedPath fixture:limited];
  XCTAssertEqualObjects([self.service
      inspectSnapshotId:limitedManifest[@"snapshot_id"] error:&error][@"state"],
                        @"stale");
}

- (void)testAuthorizationClearDuringLiveVerifyBlocksSendAndConfirm {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"README.md"
                                          content:@"authorization race\n"
                                           commit:YES];
  NSError *error = nil;
  NSDictionary *manifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error];
  NSDictionary *consent =
      [self.service confirmSnapshotId:manifest[@"snapshot_id"] error:&error];
  NSDictionary *requestBind = [self requestBindForManifest:manifest];
  NSString *active = [@"active:" stringByAppendingString:DSHFixtureConversation];
  __block BOOL cleared = NO;
  DSHProjectContextService *clearingService = [[DSHProjectContextService alloc]
      initWithProjectAccess:self.access store:self.store
      policy:[[DSHProjectContextPolicy alloc] init]
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }
      hook:^(NSString *stage, __unused NSString *path) {
        if (!cleared && [stage isEqual:@"before_fingerprint_recheck"]) {
          cleared = YES;
          [self.store clearReferenceKey:active error:nil];
        }
      }];
  XCTAssertNil([clearingService
      verifiedEnvelopeForSnapshotId:manifest[@"snapshot_id"]
                    consentReceiptId:consent[@"consent_receipt_id"]
                         requestBind:requestBind receipt:nil error:&error]);
  XCTAssertTrue(cleared);
  XCTAssertEqual(error.code, DSHProjectContextServiceErrorConsent);

  NSDictionary *confirmManifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error];
  cleared = NO;
  XCTAssertNotNil([clearingService confirmSnapshotId:confirmManifest[@"snapshot_id"]
                                                error:&error]);
  XCTAssertTrue(cleared);
  XCTAssertNil([self.store snapshotIdForReferenceKey:
      [@"txn:prepare:" stringByAppendingString:DSHFixtureConversation]
                                               error:nil]);
}

- (void)testPostSaveDeadlineRollbackPreservesPreviousActiveSnapshot {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"README.md"
                                          content:@"deadline old\n"
                                           commit:YES];
  NSError *error = nil;
  NSDictionary *oldManifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error];
  XCTAssertNotNil([self.service confirmSnapshotId:oldManifest[@"snapshot_id"]
                                          error:&error]);
  NSString *active = [@"active:" stringByAppendingString:DSHFixtureConversation];
  __block BOOL expired = NO;
  DSHFaultingProjectContextStore *deadlineStore =
      [[DSHFaultingProjectContextStore alloc]
          initWithRootURL:self.storeURL capacityBytes:64 * 1024 * 1024
          clock:^NSDate *{ return self.now; }
          identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  deadlineStore.afterActiveSave = ^{ expired = YES; };
  DSHProjectContextService *deadlineService = [[DSHProjectContextService alloc]
      initWithProjectAccess:self.access store:deadlineStore
      policy:[[DSHProjectContextPolicy alloc] init]
      clock:^NSDate *{
        return expired ? [self.now dateByAddingTimeInterval:10] : self.now;
      }
      identifierGenerator:^NSString *{
        return @"bbbbbbbb-bbbb-4bbb-8bbb-000000000001";
      }
      hook:nil];
  [self writeString:@"deadline new\n" relativePath:@"README.md" fixture:fixture];
  XCTAssertNil([deadlineService
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error]);
  XCTAssertTrue(expired);
  XCTAssertEqual(error.code, DSHProjectContextServiceErrorTimeout);
  XCTAssertEqualObjects([deadlineStore snapshotIdForReferenceKey:active error:&error],
                        oldManifest[@"snapshot_id"]);
  XCTAssertNotNil([deadlineStore loadSnapshotId:oldManifest[@"snapshot_id"]
                                          error:&error]);
  NSString *transaction = [@"txn:prepare:"
      stringByAppendingString:DSHFixtureConversation];
  XCTAssertNil([deadlineStore snapshotIdForReferenceKey:transaction error:&error]);
  DSHProjectContextStore *restarted = [[DSHProjectContextStore alloc]
      initWithRootURL:self.storeURL capacityBytes:64 * 1024 * 1024
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  [restarted snapshotIdForReferenceKey:active error:&error];
  XCTAssertNil([restarted loadSnapshotId:
      @"bbbbbbbb-bbbb-4bbb-8bbb-000000000001" error:nil]);
}

- (void)testRestartRollsBackUnfinishedPrepareTransaction {
  NSURL *root = [self.temporaryURL URLByAppendingPathComponent:@"txn-restart"];
  DSHProjectContextStore *store = [[DSHProjectContextStore alloc]
      initWithRootURL:root capacityBytes:64 * 1024 * 1024
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  NSData *oldPayload = [NSMutableData dataWithLength:300];
  NSData *newPayload = [NSMutableData dataWithLength:301];
  NSDictionary *oldManifest = @{
    @"schema_version" : @1,
    @"snapshot_sha256" : DSHSHA256Hex(oldPayload),
    @"source_fingerprint" : @"txn-old",
  };
  NSDictionary *newManifest = @{
    @"schema_version" : @1,
    @"snapshot_sha256" : DSHSHA256Hex(newPayload),
    @"source_fingerprint" : @"txn-new",
  };
  NSString *oldId = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000761";
  NSString *newId = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000762";
  NSString *active = @"active:33333333-3333-4333-8333-333333333333";
  NSString *transaction = [@"txn:prepare:"
      stringByAppendingString:DSHFixtureConversation];
  NSError *error = nil;
  XCTAssertTrue([store saveEnvelope:oldPayload manifest:oldManifest
                    sourceDescriptor:@{@"project_id" : DSHFixtureProjectA}
                         snapshotId:oldId activeReferenceKey:active error:&error]);
  XCTAssertTrue([store beginPrepareTransactionWithEnvelope:newPayload
      manifest:newManifest sourceDescriptor:@{@"project_id" : DSHFixtureProjectA}
      snapshotId:newId activeReferenceKey:active error:&error]);
  DSHProjectContextStore *restarted = [[DSHProjectContextStore alloc]
      initWithRootURL:root capacityBytes:64 * 1024 * 1024
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  XCTAssertEqualObjects([restarted snapshotIdForReferenceKey:active error:&error],
                        oldId);
  XCTAssertNil([restarted snapshotIdForReferenceKey:transaction error:&error]);
  XCTAssertNotNil([restarted loadSnapshotId:oldId error:&error]);
  XCTAssertNil([restarted loadSnapshotId:newId error:nil]);

  NSURL *corruptRoot = [self.temporaryURL
      URLByAppendingPathComponent:@"txn-corrupt-restart"];
  DSHProjectContextStore *corruptStore = [[DSHProjectContextStore alloc]
      initWithRootURL:corruptRoot capacityBytes:64 * 1024 * 1024
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  XCTAssertTrue([corruptStore saveEnvelope:oldPayload manifest:oldManifest
                           sourceDescriptor:@{@"project_id" : DSHFixtureProjectA}
                                snapshotId:oldId activeReferenceKey:active error:&error]);
  XCTAssertTrue([corruptStore beginPrepareTransactionWithEnvelope:newPayload
      manifest:newManifest sourceDescriptor:@{@"project_id" : DSHFixtureProjectA}
      snapshotId:newId activeReferenceKey:active error:&error]);
  NSURL *newEnvelopeURL = nil;
  for (NSURL *url in [corruptStore fileURLsForSnapshotId:newId error:&error]) {
    if ([url.pathExtension isEqual:@"envelope"]) newEnvelopeURL = url;
  }
  XCTAssertNotNil(newEnvelopeURL);
  XCTAssertEqual(unlink(newEnvelopeURL.fileSystemRepresentation), 0);
  DSHProjectContextStore *corruptRestart = [[DSHProjectContextStore alloc]
      initWithRootURL:corruptRoot capacityBytes:64 * 1024 * 1024
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  XCTAssertEqualObjects([corruptRestart snapshotIdForReferenceKey:active
                                                            error:&error], oldId);
  XCTAssertNil([corruptRestart snapshotIdForReferenceKey:transaction error:&error]);
  XCTAssertNotNil([corruptRestart loadSnapshotId:oldId error:&error]);
  XCTAssertNil([corruptRestart loadSnapshotId:newId error:nil]);
}

- (void)testRestartPreservesOldWhenCrashPrecedesActiveSwap {
  NSURL *root = [self.temporaryURL
      URLByAppendingPathComponent:@"txn-crash-before-active-swap"];
  DSHProjectContextStore *store = [[DSHProjectContextStore alloc]
      initWithRootURL:root capacityBytes:64 * 1024 * 1024
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  NSData *oldPayload = [NSMutableData dataWithLength:240];
  NSString *oldId = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000763";
  NSString *active = @"active:33333333-3333-4333-8333-333333333333";
  NSString *transaction = [@"txn:prepare:"
      stringByAppendingString:DSHFixtureConversation];
  NSDictionary *oldManifest = @{
    @"schema_version" : @1,
    @"snapshot_sha256" : DSHSHA256Hex(oldPayload),
    @"source_fingerprint" : @"txn-crash-old",
  };
  NSError *error = nil;
  XCTAssertTrue([store saveEnvelope:oldPayload manifest:oldManifest
                    sourceDescriptor:@{@"project_id" : DSHFixtureProjectA}
                         snapshotId:oldId activeReferenceKey:active error:&error]);
  NSDictionary *crashReferences = @{active : oldId, transaction : oldId};
  XCTAssertTrue([store writeReferences:crashReferences error:&error]);

  DSHProjectContextStore *restarted = [[DSHProjectContextStore alloc]
      initWithRootURL:root capacityBytes:64 * 1024 * 1024
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  XCTAssertEqualObjects([restarted snapshotIdForReferenceKey:active error:&error],
                        oldId);
  XCTAssertNil([restarted snapshotIdForReferenceKey:transaction error:&error]);
  XCTAssertNotNil([restarted loadSnapshotId:oldId error:&error]);
}

- (void)testReservedNoPriorSentinelCannotBeSnapshotOrActiveReference {
  NSURL *root = [self.temporaryURL
      URLByAppendingPathComponent:@"txn-reserved-sentinel"];
  DSHProjectContextStore *store = [[DSHProjectContextStore alloc]
      initWithRootURL:root capacityBytes:64 * 1024 * 1024
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  NSData *payload = [NSMutableData dataWithLength:220];
  NSString *sentinel = @"00000000-0000-0000-0000-000000000000";
  NSString *active = @"active:33333333-3333-4333-8333-333333333333";
  NSDictionary *manifest = @{
    @"schema_version" : @1,
    @"snapshot_sha256" : DSHSHA256Hex(payload),
    @"source_fingerprint" : @"reserved-sentinel",
  };
  NSError *error = nil;
  XCTAssertFalse([store saveEnvelope:payload manifest:manifest
                     sourceDescriptor:@{@"project_id" : DSHFixtureProjectA}
                          snapshotId:sentinel error:&error]);
  NSDictionary *invalidActive = @{active : sentinel};
  XCTAssertFalse([store writeReferences:invalidActive error:&error]);
}

- (void)testPreparedTransactionRejectsDirectTxnClearAndRollbackDiscard {
  NSURL *root = [self.temporaryURL
      URLByAppendingPathComponent:@"txn-direct-mutation"];
  DSHProjectContextStore *store = [[DSHProjectContextStore alloc]
      initWithRootURL:root capacityBytes:64 * 1024 * 1024
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  NSData *oldPayload = [NSMutableData dataWithLength:250];
  NSData *newPayload = [NSMutableData dataWithLength:251];
  NSString *oldId = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000764";
  NSString *newId = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000765";
  NSString *active = @"active:33333333-3333-4333-8333-333333333333";
  NSString *transaction = [@"txn:prepare:"
      stringByAppendingString:DSHFixtureConversation];
  NSDictionary *oldManifest = @{
    @"schema_version" : @1, @"snapshot_sha256" : DSHSHA256Hex(oldPayload),
    @"source_fingerprint" : @"txn-direct-old",
  };
  NSDictionary *newManifest = @{
    @"schema_version" : @1, @"snapshot_sha256" : DSHSHA256Hex(newPayload),
    @"source_fingerprint" : @"txn-direct-new",
  };
  NSError *error = nil;
  XCTAssertTrue([store saveEnvelope:oldPayload manifest:oldManifest
                    sourceDescriptor:@{@"project_id" : DSHFixtureProjectA}
                         snapshotId:oldId activeReferenceKey:active error:&error]);
  XCTAssertTrue([store beginPrepareTransactionWithEnvelope:newPayload
      manifest:newManifest sourceDescriptor:@{@"project_id" : DSHFixtureProjectA}
      snapshotId:newId activeReferenceKey:active error:&error]);
  XCTAssertFalse([store clearReferenceKey:transaction error:&error]);
  XCTAssertFalse([store clearReferenceKeyKeepingSnapshot:transaction error:&error]);
  XCTAssertFalse([store discardSnapshotId:oldId error:&error]);
  XCTAssertEqualObjects([store snapshotIdForReferenceKey:active error:&error],
                        newId);
  XCTAssertEqualObjects([store snapshotIdForReferenceKey:transaction error:&error],
                        oldId);
  XCTAssertNotNil([store loadSnapshotId:oldId error:&error]);
  XCTAssertNotNil([store loadSnapshotId:newId error:&error]);
}

- (void)testTerminalAbortAndConfirmImmediatelyCollectOnlyUnreferencedArtifacts {
  NSURL *root = [self.temporaryURL
      URLByAppendingPathComponent:@"txn-terminal-collection"];
  DSHProjectContextStore *store = [[DSHProjectContextStore alloc]
      initWithRootURL:root capacityBytes:64 * 1024 * 1024
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  NSData *payload = [NSMutableData dataWithLength:360];
  NSString *active = @"active:33333333-3333-4333-8333-333333333333";
  NSString *oldId = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000767";
  NSString *abortedId = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000768";
  NSString *protectedAbortId = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000769";
  NSString *confirmedId = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000770";
  NSString *replacementId = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000773";
  NSDictionary *(^manifest)(NSString *) = ^NSDictionary *(NSString *fingerprint) {
    return @{
      @"schema_version" : @1,
      @"snapshot_sha256" : DSHSHA256Hex(payload),
      @"source_fingerprint" : fingerprint,
    };
  };
  NSDictionary *source = @{@"project_id" : DSHFixtureProjectA};
  NSError *error = nil;
  XCTAssertTrue([store saveEnvelope:payload manifest:manifest(@"terminal-old")
                    sourceDescriptor:source snapshotId:oldId
                    activeReferenceKey:active error:&error]);

  XCTAssertTrue([store beginPrepareTransactionWithEnvelope:payload
      manifest:manifest(@"terminal-abort") sourceDescriptor:source
      snapshotId:abortedId activeReferenceKey:active error:&error]);
  XCTAssertTrue([store abortPrepareTransactionForSnapshotId:abortedId
                                          activeReferenceKey:active
                                                       error:&error]);
  XCTAssertNil([store loadSnapshotId:abortedId error:nil]);
  XCTAssertNotNil([store loadSnapshotId:oldId error:&error]);

  XCTAssertTrue([store beginPrepareTransactionWithEnvelope:payload
      manifest:manifest(@"terminal-protected-abort") sourceDescriptor:source
      snapshotId:protectedAbortId activeReferenceKey:active error:&error]);
  XCTAssertTrue([store setReferenceKey:@"retry:protected-abort"
                             snapshotId:protectedAbortId error:&error]);
  XCTAssertTrue([store abortPrepareTransactionForSnapshotId:protectedAbortId
                                          activeReferenceKey:active
                                                       error:&error]);
  XCTAssertNotNil([store loadSnapshotId:protectedAbortId error:&error]);
  XCTAssertTrue([store clearReferenceKey:@"retry:protected-abort" error:&error]);

  XCTAssertTrue([store beginPrepareTransactionWithEnvelope:payload
      manifest:manifest(@"terminal-confirm") sourceDescriptor:source
      snapshotId:confirmedId activeReferenceKey:active error:&error]);
  XCTAssertNotNil([store commitPrepareTransactionForSnapshotId:confirmedId
      activeReferenceKey:active snapshotDigest:DSHSHA256Hex(payload)
      error:&error]);
  XCTAssertNil([store loadSnapshotId:oldId error:nil]);
  XCTAssertNotNil([store loadSnapshotId:confirmedId error:&error]);

  XCTAssertTrue([store setReferenceKey:@"retry:protected-superseded"
                             snapshotId:confirmedId error:&error]);
  XCTAssertTrue([store beginPrepareTransactionWithEnvelope:payload
      manifest:manifest(@"terminal-replacement") sourceDescriptor:source
      snapshotId:replacementId activeReferenceKey:active error:&error]);
  XCTAssertNotNil([store commitPrepareTransactionForSnapshotId:replacementId
      activeReferenceKey:active snapshotDigest:DSHSHA256Hex(payload)
      error:&error]);
  XCTAssertNotNil([store loadSnapshotId:confirmedId error:&error]);
  XCTAssertNotNil([store loadSnapshotId:replacementId error:&error]);
}

- (void)testProjectedCommitCapacityReclaimsOldBeforeReceiptLimit {
  NSData *oldPayload = [NSMutableData dataWithLength:900];
  NSData *newPayload = [NSMutableData dataWithLength:920];
  NSString *oldId = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000774";
  NSString *newId = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000775";
  NSString *receiptId = @"dddddddd-dddd-4ddd-8ddd-000000000775";
  NSString *active = @"active:33333333-3333-4333-8333-333333333333";
  NSString *transaction = @"txn:prepare:33333333-3333-4333-8333-333333333333";
  NSDictionary *oldManifest = @{
    @"schema_version" : @1, @"snapshot_sha256" : DSHSHA256Hex(oldPayload),
    @"source_fingerprint" : @"projected-old",
  };
  NSDictionary *newManifest = @{
    @"schema_version" : @1, @"snapshot_sha256" : DSHSHA256Hex(newPayload),
    @"source_fingerprint" : @"projected-new",
  };
  NSDictionary *source = @{@"project_id" : DSHFixtureProjectA};
  NSError *error = nil;

  NSURL *measurementRoot = [self.temporaryURL
      URLByAppendingPathComponent:@"projected-receipt-measurement"];
  DSHProjectContextStore *measurement = [[DSHProjectContextStore alloc]
      initWithRootURL:measurementRoot capacityBytes:64 * 1024 * 1024
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return receiptId; }];
  XCTAssertTrue([measurement saveEnvelope:newPayload manifest:newManifest
                          sourceDescriptor:source snapshotId:newId error:&error]);
  XCTAssertTrue([measurement setReferenceKey:@"retry:measurement"
                                   snapshotId:newId error:&error]);
  NSDictionary *measuredReceipt = [measurement saveConsentForSnapshotId:newId
      snapshotDigest:newManifest[@"snapshot_sha256"] error:&error];
  XCTAssertNotNil(measuredReceipt);
  NSUInteger receiptBytes = 0;
  for (NSURL *url in [measurement fileURLsForSnapshotId:newId error:&error]) {
    if ([url.URLByDeletingLastPathComponent.lastPathComponent
            isEqual:@"consents"]) {
      NSNumber *size = nil;
      [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
      receiptBytes += size.unsignedIntegerValue;
    }
  }
  XCTAssertGreaterThan(receiptBytes, (NSUInteger)0);

  NSURL *probeRoot = [self.temporaryURL
      URLByAppendingPathComponent:@"projected-commit-probe"];
  DSHProjectContextStore *probe = [[DSHProjectContextStore alloc]
      initWithRootURL:probeRoot capacityBytes:64 * 1024 * 1024
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return receiptId; }];
  XCTAssertTrue([probe saveEnvelope:oldPayload manifest:oldManifest
                    sourceDescriptor:source snapshotId:oldId
                    activeReferenceKey:active error:&error]);
  XCTAssertTrue([probe beginPrepareTransactionWithEnvelope:newPayload
      manifest:newManifest sourceDescriptor:source snapshotId:newId
      activeReferenceKey:active error:&error]);
  NSUInteger preparedBytes = [self recursiveBytesAtURL:probeRoot];
  NSUInteger oldArtifactBytes = 0;
  for (NSURL *url in [probe fileURLsForSnapshotId:oldId error:&error]) {
    NSNumber *size = nil;
    [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    oldArtifactBytes += size.unsignedIntegerValue;
  }
  NSNumber *referenceSize = nil;
  [[probeRoot URLByAppendingPathComponent:@"references.json"]
      getResourceValue:&referenceSize forKey:NSURLFileSizeKey error:nil];
  NSData *projectedReferenceData = [NSJSONSerialization
      dataWithJSONObject:@{active : newId}
                 options:NSJSONWritingSortedKeys error:nil];
  NSUInteger referenceSavings = referenceSize.unsignedIntegerValue -
      projectedReferenceData.length;
  NSUInteger capacity = preparedBytes + receiptBytes - referenceSavings - 1;
  NSUInteger projectedUpperBound = preparedBytes - oldArtifactBytes -
      referenceSavings + receiptBytes;
  XCTAssertLessThanOrEqual(projectedUpperBound, capacity);
  XCTAssertGreaterThan(preparedBytes + receiptBytes, capacity);

  NSURL *root = [self.temporaryURL
      URLByAppendingPathComponent:@"projected-commit-tight"];
  DSHProjectContextStore *tight = [[DSHProjectContextStore alloc]
      initWithRootURL:root capacityBytes:capacity
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return receiptId; }];
  XCTAssertTrue([tight saveEnvelope:oldPayload manifest:oldManifest
                    sourceDescriptor:source snapshotId:oldId
                    activeReferenceKey:active error:&error]);
  XCTAssertTrue([tight beginPrepareTransactionWithEnvelope:newPayload
      manifest:newManifest sourceDescriptor:source snapshotId:newId
      activeReferenceKey:active error:&error]);
  XCTAssertLessThanOrEqual([self recursiveBytesAtURL:root], capacity);
  XCTAssertNotNil([tight commitPrepareTransactionForSnapshotId:newId
      activeReferenceKey:active snapshotDigest:newManifest[@"snapshot_sha256"]
      error:&error]);
  XCTAssertNil([tight snapshotIdForReferenceKey:transaction error:&error]);
  XCTAssertNil([tight loadSnapshotId:oldId error:nil]);
  XCTAssertNotNil([tight loadSnapshotId:newId error:&error]);
  XCTAssertLessThanOrEqual([self recursiveBytesAtURL:root], capacity);
}

- (void)testProjectedCommitReferenceFailureKeepsPreparedStateRecoverable {
  NSURL *root = [self.temporaryURL
      URLByAppendingPathComponent:@"projected-commit-fault"];
  NSString *oldId = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000776";
  NSString *newId = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000777";
  NSString *active = @"active:33333333-3333-4333-8333-333333333333";
  NSString *transaction = @"txn:prepare:33333333-3333-4333-8333-333333333333";
  NSData *payload = [NSMutableData dataWithLength:500];
  NSDictionary *oldManifest = @{
    @"schema_version" : @1, @"snapshot_sha256" : DSHSHA256Hex(payload),
    @"source_fingerprint" : @"projected-fault-old",
  };
  NSDictionary *newManifest = @{
    @"schema_version" : @1, @"snapshot_sha256" : DSHSHA256Hex(payload),
    @"source_fingerprint" : @"projected-fault-new",
  };
  NSDictionary *source = @{@"project_id" : DSHFixtureProjectA};
  NSError *error = nil;
  DSHFaultingProjectContextStore *faulting =
      [[DSHFaultingProjectContextStore alloc]
      initWithRootURL:root capacityBytes:64 * 1024 * 1024
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{
        return @"dddddddd-dddd-4ddd-8ddd-000000000777";
      }];
  XCTAssertTrue([faulting saveEnvelope:payload manifest:oldManifest
                    sourceDescriptor:source snapshotId:oldId
                    activeReferenceKey:active error:&error]);
  XCTAssertTrue([faulting beginPrepareTransactionWithEnvelope:payload
      manifest:newManifest sourceDescriptor:source snapshotId:newId
      activeReferenceKey:active error:&error]);
  NSUInteger before = [self recursiveBytesAtURL:root];
  faulting.failReferenceWrite = YES;
  XCTAssertNil([faulting commitPrepareTransactionForSnapshotId:newId
      activeReferenceKey:active snapshotDigest:newManifest[@"snapshot_sha256"]
      error:&error]);
  faulting.failReferenceWrite = NO;
  XCTAssertEqualObjects([faulting snapshotIdForReferenceKey:active error:&error],
                        newId);
  XCTAssertEqualObjects([faulting snapshotIdForReferenceKey:transaction error:&error],
                        oldId);
  XCTAssertNotNil([faulting loadSnapshotId:oldId error:&error]);
  XCTAssertNotNil([faulting loadSnapshotId:newId error:&error]);
  XCTAssertEqual([self recursiveBytesAtURL:root], before);
}

- (void)testCleanupFailureDefersReconciliationWithoutUndoingTransaction {
  NSData *payload = [NSMutableData dataWithLength:600];
  NSDictionary *source = @{@"project_id" : DSHFixtureProjectA};
  NSString *active = @"active:33333333-3333-4333-8333-333333333333";
  NSString *transaction = @"txn:prepare:33333333-3333-4333-8333-333333333333";
  NSDictionary *(^manifest)(NSString *) = ^NSDictionary *(NSString *fingerprint) {
    return @{
      @"schema_version" : @1,
      @"snapshot_sha256" : DSHSHA256Hex(payload),
      @"source_fingerprint" : fingerprint,
    };
  };
  NSError *error = nil;

  NSURL *abortRoot = [self.temporaryURL
      URLByAppendingPathComponent:@"cleanup-failure-abort"];
  DSHFaultingProjectContextStore *abortStore =
      [[DSHFaultingProjectContextStore alloc]
          initWithRootURL:abortRoot capacityBytes:64 * 1024 * 1024
          clock:^NSDate *{ return self.now; }
          identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  NSString *abortOld = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000778";
  NSString *abortNew = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000779";
  XCTAssertTrue([abortStore saveEnvelope:payload
      manifest:manifest(@"cleanup-abort-old") sourceDescriptor:source
      snapshotId:abortOld activeReferenceKey:active error:&error]);
  XCTAssertTrue([abortStore beginPrepareTransactionWithEnvelope:payload
      manifest:manifest(@"cleanup-abort-new") sourceDescriptor:source
      snapshotId:abortNew activeReferenceKey:active error:&error]);
  abortStore.failTargetedDiscard = YES;
  XCTAssertTrue([abortStore abortPrepareTransactionForSnapshotId:abortNew
                                               activeReferenceKey:active
                                                            error:&error]);
  NSDictionary *abortReferences = [NSJSONSerialization JSONObjectWithData:
      [NSData dataWithContentsOfURL:
          [abortRoot URLByAppendingPathComponent:@"references.json"]]
      options:0 error:nil];
  XCTAssertEqualObjects(abortReferences[active], abortOld);
  XCTAssertNil(abortReferences[transaction]);
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:
      [[abortRoot URLByAppendingPathComponent:@"snapshots"]
          URLByAppendingPathComponent:[abortNew stringByAppendingString:@".json"]].path]);
  abortStore.failTargetedDiscard = NO;
  XCTAssertEqualObjects([abortStore snapshotIdForReferenceKey:active error:&error],
                        abortOld);
  XCTAssertNil([abortStore loadSnapshotId:abortNew error:nil]);

  NSURL *commitRoot = [self.temporaryURL
      URLByAppendingPathComponent:@"cleanup-failure-commit"];
  DSHFaultingProjectContextStore *commitStore =
      [[DSHFaultingProjectContextStore alloc]
          initWithRootURL:commitRoot capacityBytes:64 * 1024 * 1024
          clock:^NSDate *{ return self.now; }
          identifierGenerator:^NSString *{
            return @"dddddddd-dddd-4ddd-8ddd-000000000781";
          }];
  NSString *commitOld = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000780";
  NSString *commitNew = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000781";
  XCTAssertTrue([commitStore saveEnvelope:payload
      manifest:manifest(@"cleanup-commit-old") sourceDescriptor:source
      snapshotId:commitOld activeReferenceKey:active error:&error]);
  XCTAssertTrue([commitStore beginPrepareTransactionWithEnvelope:payload
      manifest:manifest(@"cleanup-commit-new") sourceDescriptor:source
      snapshotId:commitNew activeReferenceKey:active error:&error]);
  commitStore.failTargetedDiscard = YES;
  XCTAssertNotNil([commitStore commitPrepareTransactionForSnapshotId:commitNew
      activeReferenceKey:active snapshotDigest:DSHSHA256Hex(payload)
      error:&error]);
  NSDictionary *commitReferences = [NSJSONSerialization JSONObjectWithData:
      [NSData dataWithContentsOfURL:
          [commitRoot URLByAppendingPathComponent:@"references.json"]]
      options:0 error:nil];
  XCTAssertEqualObjects(commitReferences[active], commitNew);
  XCTAssertNil(commitReferences[transaction]);
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:
      [[commitRoot URLByAppendingPathComponent:@"snapshots"]
          URLByAppendingPathComponent:[commitOld stringByAppendingString:@".json"]].path]);
  NSUInteger physicalWithOrphan = [self recursiveBytesAtURL:commitRoot];
  [commitStore setValue:@(physicalWithOrphan - 1) forKey:@"capacityBytes"];
  commitStore.failTargetedDiscard = NO;
  commitStore.failProtectedRead = YES;
  error = nil;
  XCTAssertNil([commitStore snapshotIdForReferenceKey:active error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextStoreErrorUnavailable);
  commitStore.failProtectedRead = NO;
  XCTAssertEqualObjects([commitStore snapshotIdForReferenceKey:active error:&error],
                        commitNew);
  XCTAssertNil([commitStore loadSnapshotId:commitOld error:nil]);
  XCTAssertLessThanOrEqual([self recursiveBytesAtURL:commitRoot],
                          physicalWithOrphan - 1);
}

- (void)testPartialReceiptPublishForcesNextOperationReconciliation {
  NSURL *root = [self.temporaryURL
      URLByAppendingPathComponent:@"partial-receipt-publish"];
  DSHFaultingProjectContextStore *store =
      [[DSHFaultingProjectContextStore alloc]
          initWithRootURL:root capacityBytes:64 * 1024 * 1024
          clock:^NSDate *{ return self.now; }
          identifierGenerator:^NSString *{
            return @"dddddddd-dddd-4ddd-8ddd-000000000784";
          }];
  NSData *payload = [NSMutableData dataWithLength:520];
  NSString *oldId = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000783";
  NSString *newId = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000784";
  NSString *active = @"active:33333333-3333-4333-8333-333333333333";
  NSString *transaction = @"txn:prepare:33333333-3333-4333-8333-333333333333";
  NSDictionary *oldManifest = @{
    @"schema_version" : @1, @"snapshot_sha256" : DSHSHA256Hex(payload),
    @"source_fingerprint" : @"partial-receipt-old",
  };
  NSDictionary *newManifest = @{
    @"schema_version" : @1, @"snapshot_sha256" : DSHSHA256Hex(payload),
    @"source_fingerprint" : @"partial-receipt-new",
  };
  NSDictionary *source = @{@"project_id" : DSHFixtureProjectA};
  NSError *error = nil;
  XCTAssertTrue([store saveEnvelope:payload manifest:oldManifest
                    sourceDescriptor:source snapshotId:oldId
                    activeReferenceKey:active error:&error]);
  XCTAssertTrue([store beginPrepareTransactionWithEnvelope:payload
      manifest:newManifest sourceDescriptor:source snapshotId:newId
      activeReferenceKey:active error:&error]);
  store.failReceiptPublishAfterSuper = YES;
  XCTAssertNil([store commitPrepareTransactionForSnapshotId:newId
      activeReferenceKey:active snapshotDigest:DSHSHA256Hex(payload)
      error:&error]);
  store.failReceiptPublishAfterSuper = NO;
  NSDictionary *references = [NSJSONSerialization JSONObjectWithData:
      [NSData dataWithContentsOfURL:
          [root URLByAppendingPathComponent:@"references.json"]]
      options:0 error:nil];
  XCTAssertEqualObjects(references[active], newId);
  XCTAssertEqualObjects(references[transaction], oldId);
  NSArray *consentsBefore = [[NSFileManager defaultManager]
      contentsOfDirectoryAtPath:
          [root URLByAppendingPathComponent:@"consents"].path error:nil];
  XCTAssertEqual(consentsBefore.count, (NSUInteger)1);

  XCTAssertEqualObjects([store snapshotIdForReferenceKey:active error:&error],
                        oldId);
  XCTAssertNil([store snapshotIdForReferenceKey:transaction error:&error]);
  XCTAssertNil([store loadSnapshotId:newId error:nil]);
  NSArray *consentsAfter = [[NSFileManager defaultManager]
      contentsOfDirectoryAtPath:
          [root URLByAppendingPathComponent:@"consents"].path error:nil];
  XCTAssertEqual(consentsAfter.count, (NSUInteger)0);
}

- (void)testCommitPreservesReceiptWhenReferenceRenameAppliedButFinalWriteFails {
  NSURL *root = [self.temporaryURL
      URLByAppendingPathComponent:@"late-reference-commit"];
  DSHFaultingProjectContextStore *store =
      [[DSHFaultingProjectContextStore alloc]
          initWithRootURL:root capacityBytes:64 * 1024 * 1024
          clock:^NSDate *{ return self.now; }
          identifierGenerator:^NSString *{
            return @"dddddddd-dddd-4ddd-8ddd-000000000786";
          }];
  NSData *payload = [NSMutableData dataWithLength:540];
  NSString *oldId = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000785";
  NSString *newId = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000786";
  NSString *active = @"active:33333333-3333-4333-8333-333333333333";
  NSString *transaction = @"txn:prepare:33333333-3333-4333-8333-333333333333";
  NSDictionary *oldManifest = @{
    @"schema_version" : @1, @"snapshot_sha256" : DSHSHA256Hex(payload),
    @"source_fingerprint" : @"late-reference-old",
  };
  NSDictionary *newManifest = @{
    @"schema_version" : @1, @"snapshot_sha256" : DSHSHA256Hex(payload),
    @"source_fingerprint" : @"late-reference-new",
  };
  NSDictionary *source = @{@"project_id" : DSHFixtureProjectA};
  NSError *error = nil;
  XCTAssertTrue([store saveEnvelope:payload manifest:oldManifest
                    sourceDescriptor:source snapshotId:oldId
                    activeReferenceKey:active error:&error]);
  XCTAssertTrue([store beginPrepareTransactionWithEnvelope:payload
      manifest:newManifest sourceDescriptor:source snapshotId:newId
      activeReferenceKey:active error:&error]);
  store.failReferenceWriteAfterSuper = YES;
  store.failObservationAfterReferenceWrite = YES;
  XCTAssertNil([store commitPrepareTransactionForSnapshotId:newId
      activeReferenceKey:active snapshotDigest:DSHSHA256Hex(payload)
      error:&error]);
  NSDictionary *references = [NSJSONSerialization JSONObjectWithData:
      [NSData dataWithContentsOfURL:
          [root URLByAppendingPathComponent:@"references.json"]]
      options:0 error:nil];
  XCTAssertEqualObjects(references[active], newId);
  XCTAssertNil(references[transaction]);
  NSArray *consents = [[NSFileManager defaultManager]
      contentsOfDirectoryAtPath:
          [root URLByAppendingPathComponent:@"consents"].path error:nil];
  XCTAssertEqual(consents.count, (NSUInteger)1);

  error = nil;
  XCTAssertNil([store snapshotIdForReferenceKey:active error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextStoreErrorUnavailable);
  store.failProtectedRead = NO;
  XCTAssertEqualObjects([store snapshotIdForReferenceKey:active error:&error],
                        newId);
  XCTAssertNil([store loadSnapshotId:oldId error:nil]);
  XCTAssertNotNil([store loadSnapshotId:newId error:&error]);
  NSArray *finalConsents = [[NSFileManager defaultManager]
      contentsOfDirectoryAtPath:
          [root URLByAppendingPathComponent:@"consents"].path error:nil];
  XCTAssertEqual(finalConsents.count, (NSUInteger)1);
}

- (void)testAbortReconcilesWhenRestoredReferenceRenameAppliedButWriteFails {
  NSURL *root = [self.temporaryURL
      URLByAppendingPathComponent:@"late-reference-abort"];
  DSHFaultingProjectContextStore *store =
      [[DSHFaultingProjectContextStore alloc]
          initWithRootURL:root capacityBytes:64 * 1024 * 1024
          clock:^NSDate *{ return self.now; }
          identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  NSData *payload = [NSMutableData dataWithLength:560];
  NSString *oldId = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000787";
  NSString *newId = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000788";
  NSString *active = @"active:33333333-3333-4333-8333-333333333333";
  NSString *transaction = @"txn:prepare:33333333-3333-4333-8333-333333333333";
  NSDictionary *oldManifest = @{
    @"schema_version" : @1, @"snapshot_sha256" : DSHSHA256Hex(payload),
    @"source_fingerprint" : @"late-abort-old",
  };
  NSDictionary *newManifest = @{
    @"schema_version" : @1, @"snapshot_sha256" : DSHSHA256Hex(payload),
    @"source_fingerprint" : @"late-abort-new",
  };
  NSDictionary *source = @{@"project_id" : DSHFixtureProjectA};
  NSError *error = nil;
  XCTAssertTrue([store saveEnvelope:payload manifest:oldManifest
                    sourceDescriptor:source snapshotId:oldId
                    activeReferenceKey:active error:&error]);
  XCTAssertTrue([store beginPrepareTransactionWithEnvelope:payload
      manifest:newManifest sourceDescriptor:source snapshotId:newId
      activeReferenceKey:active error:&error]);
  store.failReferenceWriteAfterSuper = YES;
  XCTAssertFalse([store abortPrepareTransactionForSnapshotId:newId
                                           activeReferenceKey:active
                                                        error:&error]);
  NSDictionary *references = [NSJSONSerialization JSONObjectWithData:
      [NSData dataWithContentsOfURL:
          [root URLByAppendingPathComponent:@"references.json"]]
      options:0 error:nil];
  XCTAssertEqualObjects(references[active], oldId);
  XCTAssertNil(references[transaction]);
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:
      [[root URLByAppendingPathComponent:@"snapshots"]
          URLByAppendingPathComponent:[newId stringByAppendingString:@".json"]].path]);

  XCTAssertEqualObjects([store snapshotIdForReferenceKey:active error:&error],
                        oldId);
  XCTAssertNil([store loadSnapshotId:newId error:nil]);
  XCTAssertNotNil([store loadSnapshotId:oldId error:&error]);
}

- (void)testDiscardPreparedNewAtomicallyRestoresOldAndDeletesNew {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"README.md"
                                          content:@"discard old\n"
                                           commit:YES];
  NSError *error = nil;
  NSDictionary *oldManifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error];
  XCTAssertNotNil([self.service confirmSnapshotId:oldManifest[@"snapshot_id"]
                                          error:&error]);
  [self writeString:@"discard prepared new\n"
      relativePath:@"README.md" fixture:fixture];
  NSDictionary *newManifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error];
  NSString *active = [@"active:"
      stringByAppendingString:DSHFixtureConversation];
  NSString *transaction = [@"txn:prepare:"
      stringByAppendingString:DSHFixtureConversation];
  XCTAssertTrue([self.service discardSnapshotId:newManifest[@"snapshot_id"]
                                          error:&error]);
  XCTAssertEqualObjects([self.store snapshotIdForReferenceKey:active error:&error],
                        oldManifest[@"snapshot_id"]);
  XCTAssertNil([self.store snapshotIdForReferenceKey:transaction error:&error]);
  XCTAssertNotNil([self.store loadSnapshotId:oldManifest[@"snapshot_id"]
                                        error:&error]);
  XCTAssertNil([self.store loadSnapshotId:newManifest[@"snapshot_id"] error:nil]);
}

- (void)testDiscardSnapshotIsIdempotent {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"README.md"
                                          content:@"idempotent discard\n"
                                           commit:YES];
  NSError *error = nil;
  NSDictionary *manifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error];
  XCTAssertNotNil(manifest);
  XCTAssertNotNil([self.service confirmSnapshotId:manifest[@"snapshot_id"]
                                          error:&error]);
  XCTAssertNil(error);

  XCTAssertTrue([self.service discardSnapshotId:manifest[@"snapshot_id"]
                                         error:&error]);
  XCTAssertNil(error);
  error = nil;
  XCTAssertTrue([self.service discardSnapshotId:manifest[@"snapshot_id"]
                                         error:&error]);
  XCTAssertNil(error);
}

- (void)testDiscardRejectsInvalidIdentifierAndStableStorageFailure {
  NSError *error = nil;
  XCTAssertFalse([self.service discardSnapshotId:@"not-a-canonical-uuid"
                                           error:&error]);
  XCTAssertEqualObjects(error.domain, DSHProjectContextServiceErrorDomain);
  XCTAssertEqual(error.code, DSHProjectContextServiceErrorStorage);

  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"README.md"
                                          content:@"discard io failure\n"
                                           commit:YES];
  NSURL *faultRoot =
      [self.temporaryURL URLByAppendingPathComponent:@"discard-io-fault"];
  DSHFaultingProjectContextStore *faulting =
      [[DSHFaultingProjectContextStore alloc]
          initWithRootURL:faultRoot
            capacityBytes:64 * 1024 * 1024
                    clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{
        return NSUUID.UUID.UUIDString.lowercaseString;
      }];
  DSHProjectContextService *service = [[DSHProjectContextService alloc]
      initWithProjectAccess:self.access
                      store:faulting
                     policy:[[DSHProjectContextPolicy alloc] init]
                      clock:^NSDate *{ return self.now; }
        identifierGenerator:^NSString *{
          return NSUUID.UUID.UUIDString.lowercaseString;
        }
                       hook:nil];
  error = nil;
  NSDictionary *manifest = [service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error];
  XCTAssertNotNil(manifest);
  XCTAssertNil(error);

  faulting.failTargetedDiscard = YES;
  XCTAssertFalse([service discardSnapshotId:manifest[@"snapshot_id"]
                                      error:&error]);
  XCTAssertEqualObjects(error.domain, DSHProjectContextServiceErrorDomain);
  XCTAssertEqual(error.code, DSHProjectContextServiceErrorStorage);
  XCTAssertEqualObjects(error.localizedDescription,
                        @"Project context storage is unavailable.");
  XCTAssertEqual([error.localizedDescription rangeOfString:
      @"RAW_DISCARD_IO_SENTINEL"].location, NSNotFound);
  error = nil;
  XCTAssertNotNil([faulting loadSnapshotId:manifest[@"snapshot_id"]
                                        error:&error]);
  XCTAssertNil(error);
  faulting.failTargetedDiscard = NO;
  error = nil;
  XCTAssertTrue([service discardSnapshotId:manifest[@"snapshot_id"]
                                     error:&error]);
  XCTAssertNil(error);
  XCTAssertNil([faulting loadSnapshotId:manifest[@"snapshot_id"] error:nil]);
}

- (void)testDiscardCleansPartialSnapshotResidualsOnRetry {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"README.md"
                                          content:@"partial discard\n"
                                           commit:YES];
  NSError *error = nil;
  NSDictionary *manifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error];
  NSDictionary *consent =
      [self.service confirmSnapshotId:manifest[@"snapshot_id"] error:&error];
  XCTAssertNotNil(consent);

  NSMutableDictionary *otherSelection =
      [[self selectionForFixture:fixture paths:@[@"README.md"]] mutableCopy];
  otherSelection[@"conversation_id"] = DSHFixtureConversationB;
  NSDictionary *otherManifest =
      [self.service prepareSelection:otherSelection error:&error];
  NSDictionary *otherConsent =
      [self.service confirmSnapshotId:otherManifest[@"snapshot_id"] error:&error];
  XCTAssertNotNil(otherConsent);

  XCTAssertNotNil([self.store loadSnapshotId:manifest[@"snapshot_id"]
                                        error:&error]);
  XCTAssertNotNil([self.store loadSnapshotId:otherManifest[@"snapshot_id"]
                                        error:&error]);
  NSArray<NSURL *> *files =
      [self.store fileURLsForSnapshotId:manifest[@"snapshot_id"] error:&error];
  NSArray<NSURL *> *otherFiles =
      [self.store fileURLsForSnapshotId:otherManifest[@"snapshot_id"]
                                  error:&error];
  XCTAssertGreaterThanOrEqual(files.count, (NSUInteger)3);
  XCTAssertGreaterThanOrEqual(otherFiles.count, (NSUInteger)3);
  XCTAssertNotNil([self.store accesses:&error][manifest[@"snapshot_id"]]);
  XCTAssertNotNil(
      [self.store accesses:&error][otherManifest[@"snapshot_id"]]);
  NSString *active =
      [@"active:" stringByAppendingString:DSHFixtureConversation];
  NSString *otherActive =
      [@"active:" stringByAppendingString:DSHFixtureConversationB];
  XCTAssertEqualObjects([self.store snapshotIdForReferenceKey:active
                                                        error:&error],
                        manifest[@"snapshot_id"]);
  XCTAssertEqualObjects([self.store snapshotIdForReferenceKey:otherActive
                                                        error:&error],
                        otherManifest[@"snapshot_id"]);

  NSURL *envelopeURL = [files filteredArrayUsingPredicate:
      [NSPredicate predicateWithBlock:^BOOL(NSURL *url,
                                            __unused NSDictionary *bindings) {
        return [url.pathExtension isEqual:@"envelope"];
      }]].firstObject;
  NSURL *recordURL = [files filteredArrayUsingPredicate:
      [NSPredicate predicateWithBlock:^BOOL(NSURL *url,
                                            __unused NSDictionary *bindings) {
        return [url.pathExtension isEqual:@"json"] &&
            [url.URLByDeletingLastPathComponent.lastPathComponent
                isEqual:@"snapshots"];
      }]].firstObject;
  NSURL *consentURL = [files filteredArrayUsingPredicate:
      [NSPredicate predicateWithBlock:^BOOL(NSURL *url,
                                            __unused NSDictionary *bindings) {
        return [url.URLByDeletingLastPathComponent.lastPathComponent
            isEqual:@"consents"];
      }]].firstObject;
  XCTAssertNotNil(envelopeURL);
  XCTAssertNotNil(recordURL);
  XCTAssertNotNil(consentURL);
  XCTAssertTrue([[NSFileManager defaultManager]
      removeItemAtURL:envelopeURL error:&error]);
  XCTAssertNil(error);
  XCTAssertTrue([[NSFileManager defaultManager]
      createDirectoryAtURL:envelopeURL withIntermediateDirectories:NO
      attributes:@{NSFilePosixPermissions : @0700} error:&error]);
  XCTAssertNil(error);
  error = nil;
  XCTAssertFalse([self.service discardSnapshotId:manifest[@"snapshot_id"]
                                          error:&error]);
  XCTAssertEqualObjects(error.domain, DSHProjectContextServiceErrorDomain);
  XCTAssertEqual(error.code, DSHProjectContextServiceErrorStorage);
  XCTAssertTrue([[NSFileManager defaultManager]
      fileExistsAtPath:envelopeURL.path]);
  XCTAssertFalse([[NSFileManager defaultManager]
      fileExistsAtPath:recordURL.path]);
  XCTAssertFalse([[NSFileManager defaultManager]
      fileExistsAtPath:consentURL.path]);
  XCTAssertNil([self.store snapshotIdForReferenceKey:active error:nil]);
  XCTAssertNil([self.store accesses:nil][manifest[@"snapshot_id"]]);

  for (NSURL *url in otherFiles) {
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:url.path]);
  }
  XCTAssertEqualObjects([self.store snapshotIdForReferenceKey:otherActive
                                                        error:&error],
                        otherManifest[@"snapshot_id"]);
  XCTAssertNotNil(
      [self.store accesses:&error][otherManifest[@"snapshot_id"]]);
  XCTAssertNotNil([self.store loadConsentReceiptId:
      otherConsent[@"consent_receipt_id"] error:&error]);

  error = nil;
  XCTAssertTrue([[NSFileManager defaultManager]
      removeItemAtURL:envelopeURL error:&error]);
  XCTAssertNil(error);
  error = nil;
  XCTAssertTrue([self.service discardSnapshotId:manifest[@"snapshot_id"]
                                         error:&error]);
  XCTAssertNil(error);

  for (NSURL *url in files) {
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:url.path]);
  }
  XCTAssertNil([self.store snapshotIdForReferenceKey:active error:&error]);
  XCTAssertNil([self.store accesses:&error][manifest[@"snapshot_id"]]);
  XCTAssertNil([self.store loadConsentReceiptId:
      consent[@"consent_receipt_id"] error:&error]);
  for (NSURL *url in otherFiles) {
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:url.path]);
  }
  XCTAssertEqualObjects([self.store snapshotIdForReferenceKey:otherActive
                                                        error:&error],
                        otherManifest[@"snapshot_id"]);
  XCTAssertNotNil(
      [self.store accesses:&error][otherManifest[@"snapshot_id"]]);
  XCTAssertNotNil([self.store loadConsentReceiptId:
      otherConsent[@"consent_receipt_id"] error:&error]);
}

- (void)testCommitReferenceFailureDoesNotExposeConsentOrConfirmedState {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"README.md"
                                          content:@"commit failure\n"
                                           commit:YES];
  DSHFaultingProjectContextStore *faulting =
      [[DSHFaultingProjectContextStore alloc]
          initWithRootURL:self.storeURL capacityBytes:64 * 1024 * 1024
          clock:^NSDate *{ return self.now; }
          identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  DSHProjectContextService *service = [[DSHProjectContextService alloc]
      initWithProjectAccess:self.access store:faulting
      policy:[[DSHProjectContextPolicy alloc] init]
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{
        return @"bbbbbbbb-bbbb-4bbb-8bbb-000000000766";
      }
      hook:nil];
  NSError *error = nil;
  NSDictionary *manifest = [service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error];
  faulting.failReferenceWrite = YES;
  XCTAssertNil([service confirmSnapshotId:manifest[@"snapshot_id"] error:&error]);
  faulting.failReferenceWrite = NO;
  XCTAssertEqual(error.code, DSHProjectContextServiceErrorStorage);
  NSString *transaction = [@"txn:prepare:"
      stringByAppendingString:DSHFixtureConversation];
  XCTAssertNotNil([faulting snapshotIdForReferenceKey:transaction error:&error]);
  XCTAssertEqualObjects([service inspectSnapshotId:manifest[@"snapshot_id"]
                                            error:&error][@"state"], @"prepared");
  NSPredicate *consentFiles = [NSPredicate predicateWithBlock:
      ^BOOL(NSURL *url, __unused NSDictionary *bindings) {
        return [url.URLByDeletingLastPathComponent.lastPathComponent
            isEqual:@"consents"];
      }];
  XCTAssertEqual([[faulting fileURLsForSnapshotId:manifest[@"snapshot_id"]
                                           error:&error]
      filteredArrayUsingPredicate:consentFiles].count, (NSUInteger)0);
}

- (void)testPrepareTransactionPersistsUntilConfirmAndAbortFailureIsRecoverable {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"README.md"
                                          content:@"durable prepare\n"
                                           commit:YES];
  NSError *error = nil;
  NSDictionary *manifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error];
  NSString *active = [@"active:" stringByAppendingString:DSHFixtureConversation];
  NSString *transaction = [@"txn:prepare:"
      stringByAppendingString:DSHFixtureConversation];
  XCTAssertEqualObjects([self.store snapshotIdForReferenceKey:active error:&error],
                        manifest[@"snapshot_id"]);
  XCTAssertEqualObjects([self.store snapshotIdForReferenceKey:transaction
                                                         error:&error],
                        @"00000000-0000-0000-0000-000000000000");
  XCTAssertNotNil([self.service confirmSnapshotId:manifest[@"snapshot_id"]
                                          error:&error]);
  XCTAssertNil([self.store snapshotIdForReferenceKey:transaction error:&error]);
  XCTAssertEqualObjects([self.store snapshotIdForReferenceKey:active error:&error],
                        manifest[@"snapshot_id"]);

  NSURL *faultRoot = [self.temporaryURL URLByAppendingPathComponent:@"txn-abort"];
  DSHFaultingProjectContextStore *faulting = [[DSHFaultingProjectContextStore alloc]
      initWithRootURL:faultRoot capacityBytes:64 * 1024 * 1024
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  NSData *oldData = [NSMutableData dataWithLength:200];
  NSData *newData = [NSMutableData dataWithLength:201];
  NSDictionary *oldRecord = @{
    @"schema_version" : @1, @"snapshot_sha256" : DSHSHA256Hex(oldData),
    @"source_fingerprint" : @"abort-old",
  };
  NSDictionary *newRecord = @{
    @"schema_version" : @1, @"snapshot_sha256" : DSHSHA256Hex(newData),
    @"source_fingerprint" : @"abort-new",
  };
  NSString *oldId = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000771";
  NSString *newId = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000772";
  XCTAssertTrue([faulting saveEnvelope:oldData manifest:oldRecord
                       sourceDescriptor:@{@"project_id" : DSHFixtureProjectA}
                            snapshotId:oldId activeReferenceKey:active error:&error]);
  XCTAssertTrue([faulting beginPrepareTransactionWithEnvelope:newData
      manifest:newRecord sourceDescriptor:@{@"project_id" : DSHFixtureProjectA}
      snapshotId:newId activeReferenceKey:active error:&error]);
  faulting.failReferenceWrite = YES;
  XCTAssertFalse([faulting abortPrepareTransactionForSnapshotId:newId
                                             activeReferenceKey:active error:&error]);
  faulting.failReferenceWrite = NO;
  XCTAssertEqualObjects([faulting snapshotIdForReferenceKey:active error:&error],
                        newId);
  XCTAssertEqualObjects([faulting snapshotIdForReferenceKey:transaction
                                                         error:&error], oldId);
  XCTAssertNotNil([faulting loadSnapshotId:oldId error:&error]);
  XCTAssertNotNil([faulting loadSnapshotId:newId error:&error]);
}

- (void)testRestartDeletesValidUnreferencedSnapshotBelowCapacity {
  NSURL *root = [self.temporaryURL URLByAppendingPathComponent:@"orphan-restart"];
  DSHProjectContextStore *store = [[DSHProjectContextStore alloc]
      initWithRootURL:root capacityBytes:64 * 1024 * 1024
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  NSData *payload = [NSMutableData dataWithLength:300];
  NSString *snapshotId = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000781";
  NSDictionary *manifest = @{
    @"schema_version" : @1, @"snapshot_sha256" : DSHSHA256Hex(payload),
    @"source_fingerprint" : @"orphan",
  };
  NSError *error = nil;
  XCTAssertTrue([store saveEnvelope:payload manifest:manifest
                    sourceDescriptor:@{@"project_id" : DSHFixtureProjectA}
                         snapshotId:snapshotId error:&error]);
  XCTAssertNotNil([store loadSnapshotId:snapshotId error:&error]);
  DSHProjectContextStore *restarted = [[DSHProjectContextStore alloc]
      initWithRootURL:root capacityBytes:64 * 1024 * 1024
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  [restarted snapshotIdForReferenceKey:@"retry:none" error:&error];
  XCTAssertNil([restarted loadSnapshotId:snapshotId error:nil]);
}

- (void)testPrepareReturnsWithDurableTransactionAndNoPostDeadlineCleanup {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"README.md"
                                          content:@"stable old\n"
                                           commit:YES];
  NSError *error = nil;
  NSDictionary *oldManifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error];
  XCTAssertNotNil([self.service confirmSnapshotId:oldManifest[@"snapshot_id"]
                                          error:&error]);
  NSString *active = [@"active:" stringByAppendingString:DSHFixtureConversation];
  NSString *transaction = [@"txn:prepare:"
      stringByAppendingString:DSHFixtureConversation];
  __block BOOL expired = NO;
  DSHFaultingProjectContextStore *faulting = [[DSHFaultingProjectContextStore alloc]
      initWithRootURL:self.storeURL capacityBytes:64 * 1024 * 1024
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  faulting.afterTransactionReferenceClear = ^{ expired = YES; };
  DSHProjectContextService *deadlineService = [[DSHProjectContextService alloc]
      initWithProjectAccess:self.access store:faulting
      policy:[[DSHProjectContextPolicy alloc] init]
      clock:^NSDate *{ return expired
          ? [self.now dateByAddingTimeInterval:10] : self.now; }
      identifierGenerator:^NSString *{
        return @"bbbbbbbb-bbbb-4bbb-8bbb-000000000011";
      }
      hook:nil];
  [self writeString:@"prepared new\n" relativePath:@"README.md" fixture:fixture];
  NSDictionary *prepared = [deadlineService
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error];
  XCTAssertNotNil(prepared);
  XCTAssertFalse(expired);
  XCTAssertEqualObjects([faulting snapshotIdForReferenceKey:active error:&error],
                        prepared[@"snapshot_id"]);
  XCTAssertEqualObjects([faulting snapshotIdForReferenceKey:transaction error:&error],
                        oldManifest[@"snapshot_id"]);
}

- (void)testFinalAuthorizationRechecksConsentAndHoldsProjectReadLease {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"README.md"
                                          content:@"final authorization\n"
                                           commit:YES];
  NSError *error = nil;
  NSDictionary *manifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error];
  NSDictionary *consent =
      [self.service confirmSnapshotId:manifest[@"snapshot_id"] error:&error];
  NSDictionary *requestBind = [self requestBindForManifest:manifest];
  __block BOOL writeAcquired = NO;
  DSHProjectContextService *leaseService = [[DSHProjectContextService alloc]
      initWithProjectAccess:self.access store:self.store
      policy:[[DSHProjectContextPolicy alloc] init]
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }
      hook:^(NSString *stage, __unused NSString *path) {
        if ([stage isEqual:@"before_authorization_complete"]) {
          DSHLocalProjectLease *writer = [self.access
              leaseProjectId:fixture.projectId
                        mode:DSHLocalProjectAccessModeWrite
             includeMetadata:NO timeout:0 error:nil];
          writeAcquired = writer != nil;
          if (writer != nil) {
            [self writeString:@"mutated in gap\n"
                 relativePath:@"README.md" fixture:fixture];
          }
        }
      }];
  XCTAssertNotNil([leaseService
      verifiedEnvelopeForSnapshotId:manifest[@"snapshot_id"]
                    consentReceiptId:consent[@"consent_receipt_id"]
                         requestBind:requestBind receipt:nil error:&error]);
  XCTAssertFalse(writeAcquired);

  NSDictionary *nextManifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error];
  NSDictionary *nextConsent =
      [self.service confirmSnapshotId:nextManifest[@"snapshot_id"] error:&error];
  NSURL *consentURL = nil;
  for (NSURL *url in [self.store fileURLsForSnapshotId:nextManifest[@"snapshot_id"]
                                                    error:&error]) {
    if ([url.lastPathComponent hasPrefix:nextConsent[@"consent_receipt_id"]]) {
      consentURL = url;
    }
  }
  XCTAssertNotNil(consentURL);
  __block BOOL removedConsent = NO;
  DSHProjectContextService *consentService = [[DSHProjectContextService alloc]
      initWithProjectAccess:self.access store:self.store
      policy:[[DSHProjectContextPolicy alloc] init]
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }
      hook:^(NSString *stage, __unused NSString *path) {
        if (!removedConsent && [stage isEqual:@"before_fingerprint_recheck"]) {
          removedConsent = unlink(consentURL.fileSystemRepresentation) == 0;
        }
      }];
  XCTAssertNil([consentService
      verifiedEnvelopeForSnapshotId:nextManifest[@"snapshot_id"]
                    consentReceiptId:nextConsent[@"consent_receipt_id"]
                         requestBind:[self requestBindForManifest:nextManifest]
                             receipt:nil error:&error]);
  XCTAssertTrue(removedConsent);
  XCTAssertEqual(error.code, DSHProjectContextServiceErrorConsent);
}

- (void)testMalformedConsentFailsClosedAndReconcilesWithoutException {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"README.md"
                                          content:@"malformed consent\n"
                                           commit:YES];
  NSError *error = nil;
  NSDictionary *manifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error];
  NSDictionary *consent =
      [self.service confirmSnapshotId:manifest[@"snapshot_id"] error:&error];
  NSURL *consentURL = nil;
  for (NSURL *url in [self.store fileURLsForSnapshotId:manifest[@"snapshot_id"]
                                                    error:&error]) {
    if ([url.URLByDeletingLastPathComponent.lastPathComponent
            isEqual:@"consents"]) consentURL = url;
  }
  XCTAssertNotNil(consentURL);
  XCTAssertTrue([DSHData(@"[]") writeToURL:consentURL atomically:NO]);
  chmod(consentURL.fileSystemRepresentation, 0600);
  __block NSDictionary *loaded = nil;
  XCTAssertNoThrow(loaded = [self.store
      loadConsentReceiptId:consent[@"consent_receipt_id"] error:&error]);
  XCTAssertNil(loaded);
  XCTAssertEqual(error.code, DSHProjectContextStoreErrorIntegrity);
  __block NSArray<NSURL *> *snapshotFiles = nil;
  XCTAssertNoThrow(snapshotFiles = [self.store
      fileURLsForSnapshotId:manifest[@"snapshot_id"] error:&error]);
  XCTAssertGreaterThanOrEqual(snapshotFiles.count, (NSUInteger)2);
  DSHProjectContextStore *restarted = [[DSHProjectContextStore alloc]
      initWithRootURL:self.storeURL capacityBytes:64 * 1024 * 1024
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  [restarted snapshotIdForReferenceKey:
      [@"active:" stringByAppendingString:DSHFixtureConversation] error:&error];
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:consentURL.path]);
}

- (void)testSnapshotFilesUseCompleteProtectionAndNoBackup {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"README.md"
                                          content:@"protected\n"
                                           commit:YES];
  NSError *error = nil;
  NSDictionary *manifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error];
  NSArray<NSURL *> *files =
      [self.store fileURLsForSnapshotId:manifest[@"snapshot_id"] error:&error];
  XCTAssertGreaterThanOrEqual(files.count, (NSUInteger)2);
  for (NSURL *url in files) {
    NSDictionary *attributes = [[NSFileManager defaultManager]
        attributesOfItemAtPath:url.path
                         error:&error];
    XCTAssertEqual([attributes[NSFilePosixPermissions] unsignedShortValue], 0600);
    if (DSHTestHostIsSimulator()) {
      // CoreSimulator may not report a protection class; enforce it only
      // when the filesystem exposes one.
      if (attributes[NSFileProtectionKey] != nil) {
        XCTAssertEqualObjects(attributes[NSFileProtectionKey], NSFileProtectionComplete);
      }
    } else {
      XCTAssertEqualObjects(attributes[NSFileProtectionKey], NSFileProtectionComplete);
    }
    NSNumber *excluded = nil;
    XCTAssertTrue([url getResourceValue:&excluded
                                 forKey:NSURLIsExcludedFromBackupKey
                                  error:&error]);
    XCTAssertTrue(excluded.boolValue);
  }
}

- (void)testStoreHardensOnlyItsOwnDirectoriesAndLeavesParentPermissionsUntouched {
  chmod(self.temporaryURL.fileSystemRepresentation, 0755);
  struct stat before = {};
  XCTAssertEqual(lstat(self.temporaryURL.fileSystemRepresentation, &before), 0);
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"README.md"
                                          content:@"parent mode\n"
                                           commit:YES];
  NSError *error = nil;
  XCTAssertNotNil([self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error]);
  struct stat after = {};
  XCTAssertEqual(lstat(self.temporaryURL.fileSystemRepresentation, &after), 0);
  XCTAssertEqual(after.st_mode & 0777, before.st_mode & 0777);
  struct stat store = {};
  XCTAssertEqual(lstat(self.storeURL.fileSystemRepresentation, &store), 0);
  XCTAssertEqual(store.st_mode & 0777, 0700);
}

- (void)testCanonicalResolverRejectsUnknownProjectMetadataKeys {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"README.md"
                                          content:@"metadata\n"
                                           commit:YES];
  NSURL *metadataURL =
      [fixture.projectURL URLByAppendingPathComponent:@"project.json"];
  NSMutableDictionary *metadata = [[NSJSONSerialization
      JSONObjectWithData:[NSData dataWithContentsOfURL:metadataURL]
                 options:NSJSONReadingMutableContainers
                   error:nil] mutableCopy];
  [metadata removeObjectForKey:@"origin_url"];
  metadata[@"unexpected"] = @"value";
  NSData *data = [NSJSONSerialization dataWithJSONObject:metadata
                                                  options:NSJSONWritingSortedKeys
                                                    error:nil];
  XCTAssertTrue([data writeToURL:metadataURL atomically:YES]);
  NSError *error = nil;
  XCTAssertNil([self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextServiceErrorProjectUnavailable);
}

- (void)testCanonicalProjectMetadataReadWriteIsDescriptorRelativeExactAndDurable {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"README.md"
                                          content:@"metadata io\n"
                                           commit:YES];
  NSError *error = nil;
  DSHLocalProjectLease *lease = [self.access
      leaseProjectId:fixture.projectId
                mode:DSHLocalProjectAccessModeWrite
     includeMetadata:NO timeout:0 error:&error];
  XCTAssertNotNil(lease);
  NSDictionary *record = @{
    @"schema_version" : @1,
    @"name" : @"Renamed",
    @"created_at" : @"2026-05-03T03:22:57.125Z",
    @"updated_at" : @"2026-05-04T03:22:57.125Z",
    @"origin_url" : NSNull.null,
  };
  XCTAssertTrue([self.access writeProjectMetadataRecord:record
                                                  lease:lease
                                                  error:&error]);
  NSDictionary *read = [self.access readProjectMetadataFromLease:lease
                                                            error:&error];
  XCTAssertEqualObjects(read[@"name"], @"Renamed");
  XCTAssertEqualObjects(read[@"id"], fixture.projectId);
  struct stat metadata = {};
  XCTAssertEqual(fstatat(lease.projectDescriptor, "project.json", &metadata,
                         AT_SYMLINK_NOFOLLOW),
                 0);
  XCTAssertTrue(S_ISREG(metadata.st_mode));
  XCTAssertEqual(metadata.st_mode & 0777, 0600);
  struct stat temporary = {};
  XCTAssertNotEqual(fstatat(lease.projectDescriptor, ".project-json.tmp",
                            &temporary, AT_SYMLINK_NOFOLLOW),
                    0);
  NSMutableDictionary *invalid = [record mutableCopy];
  invalid[@"unexpected"] = @1;
  XCTAssertFalse([self.access writeProjectMetadataRecord:invalid
                                                   lease:lease
                                                   error:&error]);
  XCTAssertEqual(error.code, DSHLocalProjectAccessErrorMetadataInvalid);
}

- (void)testStoreRetainsRetryReferenceAndPrunesUnreferencedLRU {
  self.store = [[DSHProjectContextStore alloc]
      initWithRootURL:self.storeURL
      capacityBytes:3600
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  NSData *payload = [NSMutableData dataWithLength:700];
  NSDictionary *baseManifest = @{
    @"schema_version" : @1,
    @"snapshot_sha256" : DSHSHA256Hex(payload),
    @"source_fingerprint" : @"fingerprint",
  };
  NSError *error = nil;
  XCTAssertTrue([self.store saveEnvelope:payload
                                manifest:baseManifest
                         sourceDescriptor:@{@"project_id" : DSHFixtureProjectA}
                              snapshotId:@"aaaaaaaa-aaaa-4aaa-8aaa-000000000101"
                                   error:&error]);
  XCTAssertTrue([self.store setReferenceKey:@"retry:attempt-1"
                                  snapshotId:@"aaaaaaaa-aaaa-4aaa-8aaa-000000000101"
                                       error:&error]);
  self.now = [self.now dateByAddingTimeInterval:1];
  XCTAssertTrue([self.store saveEnvelope:payload
                                manifest:baseManifest
                         sourceDescriptor:@{@"project_id" : DSHFixtureProjectA}
                              snapshotId:@"aaaaaaaa-aaaa-4aaa-8aaa-000000000102"
                                   error:&error]);
  self.now = [self.now dateByAddingTimeInterval:1];
  XCTAssertTrue([self.store saveEnvelope:payload
                                manifest:baseManifest
                         sourceDescriptor:@{@"project_id" : DSHFixtureProjectA}
                              snapshotId:@"aaaaaaaa-aaaa-4aaa-8aaa-000000000103"
                                   error:&error]);
  XCTAssertNotNil([self.store loadSnapshotId:@"aaaaaaaa-aaaa-4aaa-8aaa-000000000101"
                                       error:&error]);
  XCTAssertNil([self.store loadSnapshotId:@"aaaaaaaa-aaaa-4aaa-8aaa-000000000102"
                                     error:nil]);
  XCTAssertNotNil([self.store loadSnapshotId:@"aaaaaaaa-aaaa-4aaa-8aaa-000000000103"
                                       error:&error]);
}

- (void)testAtomicActiveReferenceReplacementLetsSupersededSnapshotPrune {
  self.store = [[DSHProjectContextStore alloc]
      initWithRootURL:self.storeURL
      capacityBytes:1800
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  NSData *payload = [NSMutableData dataWithLength:600];
  NSDictionary *manifest = @{
    @"schema_version" : @1,
    @"snapshot_sha256" : DSHSHA256Hex(payload),
    @"source_fingerprint" : @"fingerprint",
  };
  NSError *error = nil;
  NSString *first = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000201";
  NSString *second = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000202";
  NSString *reference = @"active:33333333-3333-4333-8333-333333333333";
  XCTAssertTrue([self.store saveEnvelope:payload
                                manifest:manifest
                         sourceDescriptor:@{@"project_id" : DSHFixtureProjectA}
                              snapshotId:first
                      activeReferenceKey:reference
                                   error:&error]);
  self.now = [self.now dateByAddingTimeInterval:1];
  XCTAssertTrue([self.store saveEnvelope:payload
                                manifest:manifest
                         sourceDescriptor:@{@"project_id" : DSHFixtureProjectA}
                              snapshotId:second
                      activeReferenceKey:reference
                                   error:&error]);
  XCTAssertNil([self.store loadSnapshotId:first error:nil]);
  XCTAssertNotNil([self.store loadSnapshotId:second error:&error]);
  XCTAssertEqualObjects([self.store snapshotIdForReferenceKey:reference error:&error],
                        second);
}

- (void)testFailedActiveReplacementKeepsOldSnapshotAndReferenceAcrossRestart {
  self.store = [[DSHProjectContextStore alloc]
      initWithRootURL:self.storeURL
      capacityBytes:1900
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  NSString *reference = @"active:33333333-3333-4333-8333-333333333333";
  NSString *oldId = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000211";
  NSString *newId = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000212";
  NSData *oldEnvelope = [NSMutableData dataWithLength:400];
  NSDictionary *oldManifest = @{
    @"schema_version" : @1,
    @"snapshot_sha256" : DSHSHA256Hex(oldEnvelope),
    @"source_fingerprint" : @"old-fingerprint",
  };
  NSError *error = nil;
  XCTAssertTrue([self.store saveEnvelope:oldEnvelope
                                manifest:oldManifest
                         sourceDescriptor:@{@"project_id" : DSHFixtureProjectA}
                              snapshotId:oldId
                      activeReferenceKey:reference
                                   error:&error]);
  NSData *newEnvelope = [NSMutableData dataWithLength:2200];
  NSDictionary *newManifest = @{
    @"schema_version" : @1,
    @"snapshot_sha256" : DSHSHA256Hex(newEnvelope),
    @"source_fingerprint" : @"new-fingerprint",
  };
  XCTAssertFalse([self.store saveEnvelope:newEnvelope
                                 manifest:newManifest
                          sourceDescriptor:@{@"project_id" : DSHFixtureProjectA}
                               snapshotId:newId
                       activeReferenceKey:reference
                                    error:&error]);
  XCTAssertEqualObjects([self.store snapshotIdForReferenceKey:reference error:&error],
                        oldId);
  XCTAssertNotNil([self.store loadSnapshotId:oldId error:&error]);
  XCTAssertNil([self.store loadSnapshotId:newId error:nil]);

  DSHProjectContextStore *restarted = [[DSHProjectContextStore alloc]
      initWithRootURL:self.storeURL
      capacityBytes:1900
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  XCTAssertEqualObjects([restarted snapshotIdForReferenceKey:reference error:&error],
                        oldId);
  XCTAssertNotNil([restarted loadSnapshotId:oldId error:&error]);
}

- (void)testVerifiedEnvelopeDataIsImmutableCopy {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"README.md"
                                          content:@"immutable return\n"
                                           commit:YES];
  NSError *error = nil;
  NSDictionary *manifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error];
  NSDictionary *snapshot = [self.store loadSnapshotId:manifest[@"snapshot_id"]
                                               error:&error];
  XCTAssertFalse([snapshot[@"envelope"] isKindOfClass:NSMutableData.class]);
  NSDictionary *consent =
      [self.service confirmSnapshotId:manifest[@"snapshot_id"] error:&error];
  NSData *verified = [self.service
      verifiedEnvelopeForSnapshotId:manifest[@"snapshot_id"]
                    consentReceiptId:consent[@"consent_receipt_id"]
                         requestBind:[self requestBindForManifest:manifest]
                             receipt:nil
                               error:&error];
  XCTAssertFalse([verified isKindOfClass:NSMutableData.class]);
  XCTAssertEqualObjects(DSHSHA256Hex(verified), manifest[@"snapshot_sha256"]);
}

- (void)testSnapshotRecordRemainsImmutableWhilePersistentLRUTouchUpdates {
  self.store = [[DSHProjectContextStore alloc]
      initWithRootURL:self.storeURL
      capacityBytes:3600
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  NSData *payload = [NSMutableData dataWithLength:700];
  NSDictionary *manifest = @{
    @"schema_version" : @1,
    @"snapshot_sha256" : DSHSHA256Hex(payload),
    @"source_fingerprint" : @"fingerprint",
  };
  NSString *first = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000301";
  NSString *second = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000302";
  NSString *third = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000303";
  NSError *error = nil;
  XCTAssertTrue([self.store saveEnvelope:payload manifest:manifest
                         sourceDescriptor:@{@"project_id" : DSHFixtureProjectA}
                              snapshotId:first error:&error]);
  self.now = [self.now dateByAddingTimeInterval:1];
  XCTAssertTrue([self.store saveEnvelope:payload manifest:manifest
                         sourceDescriptor:@{@"project_id" : DSHFixtureProjectA}
                              snapshotId:second error:&error]);
  NSArray<NSURL *> *files = [self.store fileURLsForSnapshotId:first error:&error];
  NSURL *recordURL = nil;
  for (NSURL *url in files) {
    if ([url.pathExtension isEqual:@"json"]) recordURL = url;
  }
  XCTAssertNotNil(recordURL);
  NSData *recordBefore = [NSData dataWithContentsOfURL:recordURL];
  struct stat statBefore = {};
  XCTAssertEqual(lstat(recordURL.fileSystemRepresentation, &statBefore), 0);
  self.now = [self.now dateByAddingTimeInterval:1];
  XCTAssertNotNil([self.store loadSnapshotId:first error:&error]);
  NSData *recordAfter = [NSData dataWithContentsOfURL:recordURL];
  struct stat statAfter = {};
  XCTAssertEqual(lstat(recordURL.fileSystemRepresentation, &statAfter), 0);
  XCTAssertEqualObjects(recordAfter, recordBefore);
  XCTAssertEqual(statAfter.st_ino, statBefore.st_ino);
  XCTAssertEqual(statAfter.st_mtimespec.tv_sec, statBefore.st_mtimespec.tv_sec);
  XCTAssertEqual(statAfter.st_mtimespec.tv_nsec, statBefore.st_mtimespec.tv_nsec);

  self.now = [self.now dateByAddingTimeInterval:1];
  XCTAssertTrue([self.store saveEnvelope:payload manifest:manifest
                         sourceDescriptor:@{@"project_id" : DSHFixtureProjectA}
                              snapshotId:third error:&error]);
  XCTAssertNotNil([self.store loadSnapshotId:first error:&error]);
  XCTAssertNil([self.store loadSnapshotId:second error:nil]);
  XCTAssertNotNil([self.store loadSnapshotId:third error:&error]);
}

- (NSUInteger)recursiveBytesAtURL:(NSURL *)root {
  NSUInteger total = 0;
  NSDirectoryEnumerator<NSURL *> *enumerator = [[NSFileManager defaultManager]
      enumeratorAtURL:root
      includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLFileSizeKey]
      options:0
      errorHandler:nil];
  for (NSURL *url in enumerator) {
    NSNumber *regular = nil;
    NSNumber *size = nil;
    [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
    [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    if (regular.boolValue) total += size.unsignedIntegerValue;
  }
  return total;
}

- (void)testFailedConsentCapacityDoesNotLeaveOrphanReceipt {
  NSData *payload = [NSMutableData dataWithLength:600];
  NSString *snapshotId = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000401";
  NSDictionary *manifest = @{
    @"schema_version" : @1,
    @"snapshot_sha256" : DSHSHA256Hex(payload),
    @"source_fingerprint" : @"fingerprint",
  };
  NSError *error = nil;
  XCTAssertTrue([self.store saveEnvelope:payload manifest:manifest
                         sourceDescriptor:@{@"project_id" : DSHFixtureProjectA}
                              snapshotId:snapshotId error:&error]);
  XCTAssertTrue([self.store setReferenceKey:@"retry:consent-capacity"
                                  snapshotId:snapshotId error:&error]);
  NSUInteger beforeBytes = [self recursiveBytesAtURL:self.storeURL];
  NSArray<NSURL *> *beforeFiles = [self.store fileURLsForSnapshotId:snapshotId
                                                             error:&error];
  DSHProjectContextStore *tightStore = [[DSHProjectContextStore alloc]
      initWithRootURL:self.storeURL
      capacityBytes:beforeBytes + 16
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{
        return @"dddddddd-dddd-4ddd-8ddd-000000000001";
      }];
  XCTAssertNil([tightStore saveConsentForSnapshotId:snapshotId
                                      snapshotDigest:manifest[@"snapshot_sha256"]
                                               error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextStoreErrorCapacity);
  NSArray<NSURL *> *afterFiles = [tightStore fileURLsForSnapshotId:snapshotId
                                                            error:nil];
  XCTAssertEqual(afterFiles.count, beforeFiles.count);
  XCTAssertEqual([self recursiveBytesAtURL:self.storeURL], beforeBytes);
}

- (void)testClearingLastReferencePrunesUnderCapacityButRetryKeepsSnapshot {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"README.md"
                                          content:@"reference lifecycle\n"
                                           commit:YES];
  NSError *error = nil;
  NSDictionary *manifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error];
  XCTAssertNotNil([self.service confirmSnapshotId:manifest[@"snapshot_id"]
                                          error:&error]);
  NSString *snapshotId = manifest[@"snapshot_id"];
  NSString *active = [@"active:" stringByAppendingString:DSHFixtureConversation];
  XCTAssertTrue([self.store setReferenceKey:@"retry:lifecycle"
                                  snapshotId:snapshotId error:&error]);
  XCTAssertTrue([self.store clearReferenceKey:active error:&error]);
  XCTAssertNotNil([self.store loadSnapshotId:snapshotId error:&error]);
  XCTAssertTrue([self.store clearReferenceKey:@"retry:lifecycle" error:&error]);
  XCTAssertNil([self.store loadSnapshotId:snapshotId error:nil]);
  XCTAssertNil([self.store snapshotIdForReferenceKey:active error:&error]);
}

- (void)testCorruptSnapshotDiscardRemovesArtifactsReferencesAndPersists {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"README.md"
                                          content:@"corrupt discard\n"
                                           commit:YES];
  NSError *error = nil;
  NSDictionary *manifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error];
  NSString *snapshotId = manifest[@"snapshot_id"];
  NSArray<NSURL *> *files = [self.store fileURLsForSnapshotId:snapshotId error:&error];
  NSURL *recordURL = nil;
  NSURL *envelopeURL = nil;
  for (NSURL *url in files) {
    if ([url.pathExtension isEqual:@"json"] &&
        [url.URLByDeletingLastPathComponent.lastPathComponent
            isEqual:@"snapshots"]) recordURL = url;
    if ([url.pathExtension isEqual:@"envelope"]) envelopeURL = url;
  }
  XCTAssertTrue([DSHData(@"{}") writeToURL:recordURL atomically:NO]);
  chmod(recordURL.fileSystemRepresentation, 0600);
  XCTAssertTrue([self.store discardSnapshotId:snapshotId error:&error]);
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:recordURL.path]);
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:envelopeURL.path]);
  NSString *active = [@"active:" stringByAppendingString:DSHFixtureConversation];
  XCTAssertNil([self.store snapshotIdForReferenceKey:active error:&error]);
  DSHProjectContextStore *restarted = [[DSHProjectContextStore alloc]
      initWithRootURL:self.storeURL capacityBytes:64 * 1024 * 1024
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  XCTAssertNil([restarted loadSnapshotId:snapshotId error:nil]);
}

- (void)testReferenceGrowthPreflightsCapacityAndRollsBack {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"README.md"
                                          content:@"reference cap\n"
                                           commit:YES];
  NSError *error = nil;
  NSDictionary *manifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error];
  XCTAssertNotNil([self.service confirmSnapshotId:manifest[@"snapshot_id"]
                                          error:&error]);
  NSUInteger before = [self recursiveBytesAtURL:self.storeURL];
  DSHProjectContextStore *tight = [[DSHProjectContextStore alloc]
      initWithRootURL:self.storeURL capacityBytes:before + 16
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  NSString *largeKey = [@"retry:" stringByPaddingToLength:250
                                               withString:@"x"
                                          startingAtIndex:0];
  XCTAssertFalse([tight setReferenceKey:largeKey
                              snapshotId:manifest[@"snapshot_id"]
                                   error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextStoreErrorCapacity);
  XCTAssertNil([tight snapshotIdForReferenceKey:largeKey error:&error]);
  XCTAssertEqual([self recursiveBytesAtURL:self.storeURL], before);
}

- (void)testActiveSaveCountsReferenceAndProtectedReplacementCapacity {
  NSData *payload = [NSMutableData dataWithLength:400];
  NSDictionary *manifest = @{
    @"schema_version" : @1,
    @"snapshot_sha256" : DSHSHA256Hex(payload),
    @"source_fingerprint" : @"capacity-fingerprint",
  };
  NSString *snapshotId = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000701";
  NSString *reference = @"active:33333333-3333-4333-8333-333333333333";
  NSURL *probeURL = [self.temporaryURL URLByAppendingPathComponent:@"cap-probe"];
  DSHProjectContextStore *probe = [[DSHProjectContextStore alloc]
      initWithRootURL:probeURL capacityBytes:64 * 1024 * 1024
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  NSError *error = nil;
  XCTAssertTrue([probe saveEnvelope:payload manifest:manifest
                    sourceDescriptor:@{@"project_id" : DSHFixtureProjectA}
                         snapshotId:snapshotId error:&error]);
  NSUInteger snapshotBytes = [self recursiveBytesAtURL:probeURL];
  NSNumber *emptyReferenceSize = nil;
  [[probeURL URLByAppendingPathComponent:@"references.json"]
      getResourceValue:&emptyReferenceSize forKey:NSURLFileSizeKey error:nil];
  NSData *referenceData = [NSJSONSerialization dataWithJSONObject:
      @{reference : snapshotId} options:NSJSONWritingSortedKeys error:nil];
  NSURL *tightURL = [self.temporaryURL URLByAppendingPathComponent:@"cap-tight"];
  DSHProjectContextStore *tight = [[DSHProjectContextStore alloc]
      initWithRootURL:tightURL
      capacityBytes:snapshotBytes - emptyReferenceSize.unsignedIntegerValue +
          referenceData.length - 1
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  XCTAssertFalse([tight saveEnvelope:payload manifest:manifest
                      sourceDescriptor:@{@"project_id" : DSHFixtureProjectA}
                           snapshotId:snapshotId activeReferenceKey:reference
                                error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextStoreErrorCapacity);
  XCTAssertNil([tight snapshotIdForReferenceKey:reference error:nil]);
  XCTAssertNil([tight loadSnapshotId:snapshotId error:nil]);

  NSURL *protectedURL =
      [self.temporaryURL URLByAppendingPathComponent:@"cap-protected"];
  DSHProjectContextStore *large = [[DSHProjectContextStore alloc]
      initWithRootURL:protectedURL capacityBytes:64 * 1024 * 1024
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  NSString *oldId = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000711";
  NSString *newId = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000712";
  XCTAssertTrue([large saveEnvelope:payload manifest:manifest
                    sourceDescriptor:@{@"project_id" : DSHFixtureProjectA}
                         snapshotId:oldId activeReferenceKey:reference error:&error]);
  XCTAssertTrue([large setReferenceKey:@"retry:protected-old"
                             snapshotId:oldId error:&error]);
  NSUInteger protectedBefore = [self recursiveBytesAtURL:protectedURL];
  DSHProjectContextStore *protectedTight = [[DSHProjectContextStore alloc]
      initWithRootURL:protectedURL capacityBytes:protectedBefore + 64
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  XCTAssertFalse([protectedTight saveEnvelope:payload manifest:manifest
                              sourceDescriptor:@{@"project_id" : DSHFixtureProjectA}
                                   snapshotId:newId activeReferenceKey:reference
                                        error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextStoreErrorCapacity);
  XCTAssertEqualObjects([protectedTight snapshotIdForReferenceKey:reference
                                                             error:&error],
                        oldId);
  XCTAssertNotNil([protectedTight loadSnapshotId:oldId error:&error]);
  XCTAssertNil([protectedTight loadSnapshotId:newId error:nil]);
}

- (void)testActiveReplacementPruneFailureRollsBackOldSnapshot {
  NSURL *root = [self.temporaryURL URLByAppendingPathComponent:@"prune-failure"];
  DSHFaultingProjectContextStore *store =
      [[DSHFaultingProjectContextStore alloc]
          initWithRootURL:root capacityBytes:64 * 1024 * 1024
          clock:^NSDate *{ return self.now; }
          identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  NSData *payload = [NSMutableData dataWithLength:400];
  NSDictionary *manifest = @{
    @"schema_version" : @1,
    @"snapshot_sha256" : DSHSHA256Hex(payload),
    @"source_fingerprint" : @"prune-fingerprint",
  };
  NSString *reference = @"active:33333333-3333-4333-8333-333333333333";
  NSString *oldId = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000721";
  NSString *newId = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000722";
  NSError *error = nil;
  XCTAssertTrue([store saveEnvelope:payload manifest:manifest
                    sourceDescriptor:@{@"project_id" : DSHFixtureProjectA}
                         snapshotId:oldId activeReferenceKey:reference error:&error]);
  store.failPrune = YES;
  XCTAssertFalse([store saveEnvelope:payload manifest:manifest
                     sourceDescriptor:@{@"project_id" : DSHFixtureProjectA}
                          snapshotId:newId activeReferenceKey:reference error:&error]);
  XCTAssertEqualObjects([store snapshotIdForReferenceKey:reference error:&error],
                        oldId);
  XCTAssertNotNil([store loadSnapshotId:oldId error:&error]);
  XCTAssertNil([store loadSnapshotId:newId error:nil]);
}

- (void)testStartupReconciliationPrunesOverCapacityAndPreservesUnavailableData {
  NSURL *pruneRoot = [self.temporaryURL URLByAppendingPathComponent:@"restart-prune"];
  DSHProjectContextStore *large = [[DSHProjectContextStore alloc]
      initWithRootURL:pruneRoot capacityBytes:64 * 1024 * 1024
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  NSData *payload = [NSMutableData dataWithLength:500];
  NSDictionary *manifest = @{
    @"schema_version" : @1,
    @"snapshot_sha256" : DSHSHA256Hex(payload),
    @"source_fingerprint" : @"restart-fingerprint",
  };
  NSString *oldId = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000731";
  NSString *newId = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000732";
  NSError *error = nil;
  XCTAssertTrue([large saveEnvelope:payload manifest:manifest
                    sourceDescriptor:@{@"project_id" : DSHFixtureProjectA}
                         snapshotId:oldId error:&error]);
  self.now = [self.now dateByAddingTimeInterval:1];
  XCTAssertTrue([large saveEnvelope:payload manifest:manifest
                    sourceDescriptor:@{@"project_id" : DSHFixtureProjectA}
                         snapshotId:newId error:&error]);
  XCTAssertTrue([large setReferenceKey:@"retry:restart-new"
                              snapshotId:newId error:&error]);
  NSUInteger total = [self recursiveBytesAtURL:pruneRoot];
  NSUInteger oldBytes = 0;
  for (NSURL *url in [large fileURLsForSnapshotId:oldId error:&error]) {
    NSNumber *size = nil;
    [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    oldBytes += size.unsignedIntegerValue;
  }
  NSUInteger capacity = total - oldBytes + 16;
  DSHProjectContextStore *restarted = [[DSHProjectContextStore alloc]
      initWithRootURL:pruneRoot capacityBytes:capacity
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  [restarted snapshotIdForReferenceKey:@"retry:none" error:&error];
  XCTAssertLessThanOrEqual([self recursiveBytesAtURL:pruneRoot], capacity);
  XCTAssertNil([restarted loadSnapshotId:oldId error:nil]);
  XCTAssertNotNil([restarted loadSnapshotId:newId error:&error]);

  NSURL *unavailableRoot =
      [self.temporaryURL URLByAppendingPathComponent:@"restart-unavailable"];
  DSHProjectContextStore *original = [[DSHProjectContextStore alloc]
      initWithRootURL:unavailableRoot capacityBytes:64 * 1024 * 1024
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  NSString *snapshotId = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000741";
  NSString *reference = @"active:33333333-3333-4333-8333-333333333333";
  XCTAssertTrue([original saveEnvelope:payload manifest:manifest
                       sourceDescriptor:@{@"project_id" : DSHFixtureProjectA}
                            snapshotId:snapshotId activeReferenceKey:reference
                                 error:&error]);
  NSArray<NSURL *> *files = [original fileURLsForSnapshotId:snapshotId error:&error];
  NSData *referencesBefore = [NSData dataWithContentsOfURL:
      [unavailableRoot URLByAppendingPathComponent:@"references.json"]];
  DSHFaultingProjectContextStore *unavailable =
      [[DSHFaultingProjectContextStore alloc]
          initWithRootURL:unavailableRoot capacityBytes:64 * 1024 * 1024
          clock:^NSDate *{ return self.now; }
          identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  unavailable.failProtectedRead = YES;
  error = nil;
  XCTAssertNil([unavailable snapshotIdForReferenceKey:reference error:&error]);
  XCTAssertEqual(error.code, DSHProjectContextStoreErrorUnavailable);
  for (NSURL *url in files) {
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:url.path]);
  }
  XCTAssertEqualObjects([NSData dataWithContentsOfURL:
      [unavailableRoot URLByAppendingPathComponent:@"references.json"]],
                        referencesBefore);
}

- (void)testRestartWithLowerCapacityPreservesReferencedSnapshotAndAllowsClear {
  NSURL *root = [self.temporaryURL URLByAppendingPathComponent:@"restart-lower-cap"];
  DSHProjectContextStore *large = [[DSHProjectContextStore alloc]
      initWithRootURL:root capacityBytes:64 * 1024 * 1024
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  NSData *payload = [NSMutableData dataWithLength:2000];
  NSDictionary *manifest = @{
    @"schema_version" : @1,
    @"snapshot_sha256" : DSHSHA256Hex(payload),
    @"source_fingerprint" : @"lower-cap-fingerprint",
  };
  NSString *snapshotId = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000745";
  NSString *reference = @"active:33333333-3333-4333-8333-333333333333";
  NSError *error = nil;
  XCTAssertTrue([large saveEnvelope:payload manifest:manifest
                    sourceDescriptor:@{@"project_id" : DSHFixtureProjectA}
                         snapshotId:snapshotId activeReferenceKey:reference
                              error:&error]);
  DSHProjectContextStore *small = [[DSHProjectContextStore alloc]
      initWithRootURL:root capacityBytes:1000
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  XCTAssertEqualObjects([small snapshotIdForReferenceKey:reference error:&error],
                        snapshotId);
  XCTAssertNotNil([small loadSnapshotId:snapshotId error:&error]);
  XCTAssertTrue([small clearReferenceKey:reference error:&error]);
  XCTAssertNil([small snapshotIdForReferenceKey:reference error:&error]);
  XCTAssertNil([small loadSnapshotId:snapshotId error:nil]);
  XCTAssertLessThanOrEqual([self recursiveBytesAtURL:root], (NSUInteger)1000);
}

- (void)testClearReferencePersistFailureDoesNotCreateDanglingReference {
  NSURL *root = [self.temporaryURL URLByAppendingPathComponent:@"clear-rollback"];
  DSHProjectContextStore *original = [[DSHProjectContextStore alloc]
      initWithRootURL:root capacityBytes:64 * 1024 * 1024
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  NSData *payload = [NSMutableData dataWithLength:400];
  NSDictionary *manifest = @{
    @"schema_version" : @1,
    @"snapshot_sha256" : DSHSHA256Hex(payload),
    @"source_fingerprint" : @"clear-fingerprint",
  };
  NSString *snapshotId = @"aaaaaaaa-aaaa-4aaa-8aaa-000000000751";
  NSString *reference = @"active:33333333-3333-4333-8333-333333333333";
  NSError *error = nil;
  XCTAssertTrue([original saveEnvelope:payload manifest:manifest
                       sourceDescriptor:@{@"project_id" : DSHFixtureProjectA}
                            snapshotId:snapshotId activeReferenceKey:reference
                                 error:&error]);
  DSHFaultingProjectContextStore *faulting =
      [[DSHFaultingProjectContextStore alloc]
          initWithRootURL:root capacityBytes:64 * 1024 * 1024
          clock:^NSDate *{ return self.now; }
          identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  XCTAssertEqualObjects([faulting snapshotIdForReferenceKey:reference error:&error],
                        snapshotId);
  faulting.failAccessWrite = YES;
  XCTAssertFalse([faulting clearReferenceKey:reference error:&error]);
  XCTAssertEqualObjects([faulting snapshotIdForReferenceKey:reference error:&error],
                        snapshotId);
  faulting.failAccessWrite = NO;
  XCTAssertNotNil([faulting loadSnapshotId:snapshotId error:&error]);
}

- (void)testStartupReconciliationRemovesCrashArtifactsAndOrphanConsent {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"README.md"
                                          content:@"reconcile\n"
                                           commit:YES];
  NSError *error = nil;
  NSDictionary *manifest = [self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error];
  [self.service confirmSnapshotId:manifest[@"snapshot_id"] error:&error];
  NSURL *snapshotsURL = [self.storeURL URLByAppendingPathComponent:@"snapshots"];
  NSURL *tempURL = [snapshotsURL URLByAppendingPathComponent:@".crash.tmp"];
  NSURL *envelopeOnly = [snapshotsURL URLByAppendingPathComponent:
      @"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee.envelope"];
  NSURL *corruptRecord = [snapshotsURL URLByAppendingPathComponent:
      @"ffffffff-ffff-4fff-8fff-ffffffffffff.json"];
  for (NSURL *url in @[tempURL, envelopeOnly, corruptRecord]) {
    XCTAssertTrue([DSHData(@"orphan") writeToURL:url atomically:YES]);
    chmod(url.fileSystemRepresentation, 0600);
  }
  NSArray<NSURL *> *files = [self.store
      fileURLsForSnapshotId:manifest[@"snapshot_id"] error:&error];
  NSURL *orphanConsent = nil;
  for (NSURL *url in files) {
    if ([url.URLByDeletingLastPathComponent.lastPathComponent
            isEqual:@"consents"]) {
      orphanConsent = url;
    } else {
      unlink(url.fileSystemRepresentation);
    }
  }
  XCTAssertNotNil(orphanConsent);
  DSHProjectContextStore *restarted = [[DSHProjectContextStore alloc]
      initWithRootURL:self.storeURL capacityBytes:64 * 1024 * 1024
      clock:^NSDate *{ return self.now; }
      identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }];
  [restarted snapshotIdForReferenceKey:
      [@"active:" stringByAppendingString:DSHFixtureConversation] error:nil];
  for (NSURL *url in @[tempURL, envelopeOnly, corruptRecord, orphanConsent]) {
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:url.path]);
  }
}

- (void)testConcurrentProjectsNeverMixSnapshots {
  DSHProjectFixture *alpha = [self createProject:DSHFixtureProjectA
                                           name:@"Alpha"
                                    initialFile:@"README.md"
                                        content:@"ALPHA_ONLY_7B3E\n"
                                         commit:YES];
  DSHProjectFixture *beta = [self createProject:DSHFixtureProjectB
                                          name:@"Beta"
                                   initialFile:@"README.md"
                                       content:@"BETA_ONLY_19C4\n"
                                        commit:YES];
  dispatch_group_t group = dispatch_group_create();
  dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
  __block NSDictionary *alphaManifest = nil;
  __block NSDictionary *betaManifest = nil;
  dispatch_group_async(group, queue, ^{
    alphaManifest = [self.service
        prepareSelection:[self selectionForFixture:alpha paths:@[@"README.md"]]
                     error:nil];
  });
  dispatch_group_async(group, queue, ^{
    NSMutableDictionary *selection =
        [[self selectionForFixture:beta paths:@[@"README.md"]] mutableCopy];
    selection[@"conversation_id"] = DSHFixtureConversationB;
    betaManifest = [self.service
        prepareSelection:selection
                     error:nil];
  });
  XCTAssertEqual(dispatch_group_wait(group,
                                     dispatch_time(DISPATCH_TIME_NOW,
                                                   5 * NSEC_PER_SEC)),
                 0L);
  XCTAssertNotNil(alphaManifest);
  XCTAssertNotNil(betaManifest);
  XCTAssertEqualObjects([self.store snapshotIdForReferenceKey:
      [@"active:" stringByAppendingString:DSHFixtureConversation] error:nil],
                        alphaManifest[@"snapshot_id"]);
  XCTAssertEqualObjects([self.store snapshotIdForReferenceKey:
      [@"active:" stringByAppendingString:DSHFixtureConversationB] error:nil],
                        betaManifest[@"snapshot_id"]);
  NSError *alphaError = nil;
  NSError *betaError = nil;
  NSString *alphaEnvelope = [[NSString alloc]
      initWithData:[self confirmedEnvelopeForManifest:alphaManifest
                                                 error:&alphaError]
          encoding:NSUTF8StringEncoding];
  NSString *betaEnvelope = [[NSString alloc]
      initWithData:[self confirmedEnvelopeForManifest:betaManifest
                                                 error:&betaError]
          encoding:NSUTF8StringEncoding];
  XCTAssertNotNil(alphaEnvelope, @"%@", alphaError);
  XCTAssertNotNil(betaEnvelope, @"%@", betaError);
  XCTAssertTrue([alphaEnvelope containsString:@"ALPHA_ONLY_7B3E"]);
  XCTAssertFalse([alphaEnvelope containsString:@"BETA_ONLY_19C4"]);
  XCTAssertTrue([betaEnvelope containsString:@"BETA_ONLY_19C4"]);
  XCTAssertFalse([betaEnvelope containsString:@"ALPHA_ONLY_7B3E"]);
}

- (void)testProjectAccessReadLeasesShareWriteExcludesAndProjectsDoNotMixLocks {
  DSHProjectFixture *alpha = [self createProject:DSHFixtureProjectA
                                           name:@"Alpha"
                                    initialFile:@"README.md"
                                        content:@"alpha\n"
                                         commit:YES];
  [self createProject:DSHFixtureProjectB
                 name:@"Beta"
          initialFile:@"README.md"
              content:@"beta\n"
               commit:YES];
  NSError *error = nil;
  DSHLocalProjectLease *readOne = [self.access
      leaseProjectId:alpha.projectId
                mode:DSHLocalProjectAccessModeRead
     includeMetadata:NO
             timeout:0
               error:&error];
  XCTAssertNotNil(readOne);
  DSHLocalProjectLease *readTwo = [self.access
      leaseProjectId:alpha.projectId
                mode:DSHLocalProjectAccessModeRead
     includeMetadata:NO
             timeout:0
               error:&error];
  XCTAssertNotNil(readTwo);
  XCTAssertNil([self.access
      leaseProjectId:alpha.projectId
                mode:DSHLocalProjectAccessModeWrite
     includeMetadata:NO
             timeout:0
               error:&error]);
  XCTAssertEqual(error.code, DSHLocalProjectAccessErrorLockTimeout);
  error = nil;
  XCTAssertNotNil([self.access
      leaseProjectId:DSHFixtureProjectB
                mode:DSHLocalProjectAccessModeWrite
     includeMetadata:NO
             timeout:0
               error:&error]);
  XCTAssertNil(error);
}

- (void)testWorkspaceProjectPathsUseSameOrderedReadWriteLeasesAsContext {
  [self createProject:DSHFixtureProjectA name:@"Alpha"
          initialFile:@"README.md" content:@"alpha\n" commit:YES];
  [self createProject:DSHFixtureProjectB name:@"Beta"
          initialFile:@"README.md" content:@"beta\n" commit:YES];
  NSString *alphaPath = [NSString stringWithFormat:@"projects/%@/repo/README.md",
                                                   DSHFixtureProjectA];
  NSString *betaPath = [NSString stringWithFormat:@"projects/%@/repo/README.md",
                                                  DSHFixtureProjectB];
  NSError *error = nil;
  XCTAssertEqualObjects([DSHLocalProjectAccess projectIdForWorkspacePath:alphaPath
                                                                    error:&error],
                        DSHFixtureProjectA);
  NSString *uppercasePath = @"projects/AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA/repo/x";
  XCTAssertNil([DSHLocalProjectAccess projectIdForWorkspacePath:uppercasePath
                                                           error:&error]);
  XCTAssertEqual(error.code, DSHLocalProjectAccessErrorInvalidIdentifier);

  @autoreleasepool {
    DSHLocalProjectLeaseSet *workspaceWrite = [self.access
        leaseWorkspaceReadPaths:@[]
                      writePaths:@[alphaPath]
                         timeout:0
                           error:&error];
    XCTAssertNotNil(workspaceWrite);
    XCTAssertNil([self.access leaseProjectId:DSHFixtureProjectA
                                        mode:DSHLocalProjectAccessModeRead
                             includeMetadata:NO timeout:0 error:&error]);
    XCTAssertEqual(error.code, DSHLocalProjectAccessErrorLockTimeout);
    DSHLocalProjectLease *betaRead =
        [self.access leaseProjectId:DSHFixtureProjectB
                               mode:DSHLocalProjectAccessModeRead
                    includeMetadata:NO timeout:0 error:&error];
    XCTAssertNotNil(betaRead);
  }
  DSHLocalProjectLease *alphaRead =
      [self.access leaseProjectId:DSHFixtureProjectA
                             mode:DSHLocalProjectAccessModeRead
                  includeMetadata:NO timeout:0 error:&error];
  XCTAssertNotNil(alphaRead);
  alphaRead = nil;

  DSHLocalProjectLeaseSet *ordered = [self.access
      leaseWorkspaceReadPaths:@[alphaPath, alphaPath]
                    writePaths:@[betaPath]
                       timeout:0
                         error:&error];
  XCTAssertNotNil(ordered);
  XCTAssertNotNil([ordered leaseForProjectId:DSHFixtureProjectA]);
  XCTAssertNotNil([ordered leaseForProjectId:DSHFixtureProjectB]);
}

- (void)testLegacyWorkspaceProjectPathAuthorityIsNotExposed {
  LocalWorkspaceModule *workspace =
      [[NSClassFromString(@"LocalWorkspaceModule") alloc] init];
  XCTAssertNotNil(workspace);
  XCTAssertFalse([workspace respondsToSelector:
      @selector(componentsForPath:allowRoot:error:)]);
  XCTAssertFalse([workspace respondsToSelector:
      @selector(openParentDirectoryForPath:name:relativePath:leaseSet:error:)]);
  XCTAssertFalse([workspace respondsToSelector:
      @selector(openDirectoryComponents:leaseSet:error:)]);
}

- (void)testProjectRootTraversalRejectsIntermediateWorkspaceSwap {
  NSURL *support = [self.temporaryURL
      URLByAppendingPathComponent:@"descriptor-root/support" isDirectory:YES];
  NSURL *workspace = [support URLByAppendingPathComponent:@"workspace"
                                               isDirectory:YES];
  NSURL *projects = [workspace URLByAppendingPathComponent:@"projects"
                                                isDirectory:YES];
  XCTAssertTrue([[NSFileManager defaultManager]
      createDirectoryAtURL:projects withIntermediateDirectories:YES
      attributes:@{NSFilePosixPermissions : @0700} error:nil]);
  NSURL *originalProjects = self.projectsURL;
  self.projectsURL = projects;
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Anchored"
                                      initialFile:@"README.md"
                                          content:@"root anchor\n"
                                           commit:YES];
  self.projectsURL = originalProjects;
  __block BOOL swapped = NO;
  DSHLocalProjectAccess *swappingAccess = [[DSHLocalProjectAccess alloc]
      initWithProjectsRootURL:projects
                         hook:^(NSString *stage) {
        if (swapped || ![stage isEqual:@"before_projects_root_final_open"]) {
          return;
        }
        swapped = YES;
        NSURL *pinned = [support URLByAppendingPathComponent:@"workspace-pinned"
                                                 isDirectory:YES];
        rename(workspace.fileSystemRepresentation, pinned.fileSystemRepresentation);
        [[NSFileManager defaultManager]
            createDirectoryAtURL:projects withIntermediateDirectories:YES
            attributes:@{NSFilePosixPermissions : @0700} error:nil];
      }];
  NSError *error = nil;
  XCTAssertNil([swappingAccess leaseProjectId:fixture.projectId
                                         mode:DSHLocalProjectAccessModeRead
                              includeMetadata:NO timeout:0 error:&error]);
  XCTAssertTrue(swapped);
  XCTAssertNotNil(error);
}

- (void)testLegacyWorkspaceProjectFileAndToolBridgeIsNotExposed {
  DSHInjectedWorkspaceModule *workspace =
      [[DSHInjectedWorkspaceModule alloc] init];
  XCTAssertNotNil(workspace);
  XCTAssertFalse([workspace respondsToSelector:
      @selector(readTextPath:resolver:rejecter:)]);
  XCTAssertFalse([workspace respondsToSelector:
      @selector(writeTextPath:content:createOnly:expectedRevision:resolver:rejecter:)]);
  XCTAssertFalse([workspace respondsToSelector:
      @selector(renameEntrySource:destination:resolver:rejecter:)]);
  XCTAssertFalse([workspace respondsToSelector:
      @selector(executePortableToolName:path:options:resolver:rejecter:)]);
}

- (void)testFreshInstallProjectListReturnsEmptyWithoutCreatingRoot {
  NSURL *missingRoot = [self.temporaryURL
      URLByAppendingPathComponent:@"fresh/workspace/projects" isDirectory:YES];
  DSHLocalProjectAccess *access = [[DSHLocalProjectAccess alloc]
      initWithProjectsRootURL:missingRoot hook:nil];
  LocalProjectsModule *projects =
      [[NSClassFromString(@"LocalProjectsModule") alloc] init];
  [projects setValue:access forKey:@"projectAccess"];
  XCTestExpectation *finished = [self expectationWithDescription:
      @"fresh project list"];
  __block NSDictionary *result = nil;
  __block BOOL rejected = NO;
  [projects listWithResolver:^(NSDictionary *value) {
    result = value;
    [finished fulfill];
  } rejecter:^(__unused NSString *code, __unused NSString *message,
               __unused NSError *error) {
    rejected = YES;
    [finished fulfill];
  }];
  [self waitForExpectations:@[finished] timeout:5.0];
  XCTAssertFalse(rejected);
  XCTAssertEqualObjects(result[@"schema_version"], @1);
  XCTAssertEqual([result[@"projects"] count], (NSUInteger)0);
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:missingRoot.path]);

  NSURL *target = [self.temporaryURL
      URLByAppendingPathComponent:@"fresh-target" isDirectory:YES];
  XCTAssertTrue([[NSFileManager defaultManager]
      createDirectoryAtURL:target withIntermediateDirectories:YES
      attributes:@{NSFilePosixPermissions : @0700} error:nil]);
  NSURL *sentinel = [target URLByAppendingPathComponent:@"sentinel.txt"];
  XCTAssertTrue([DSHData(@"survive") writeToURL:sentinel atomically:YES]);
  XCTAssertTrue([[NSFileManager defaultManager]
      createDirectoryAtURL:missingRoot.URLByDeletingLastPathComponent
      withIntermediateDirectories:YES
      attributes:@{NSFilePosixPermissions : @0700} error:nil]);
  XCTAssertEqual(symlink(target.fileSystemRepresentation,
                         missingRoot.fileSystemRepresentation), 0);
  DSHLocalProjectAccess *unsafeAccess = [[DSHLocalProjectAccess alloc]
      initWithProjectsRootURL:missingRoot hook:nil];
  LocalProjectsModule *unsafeProjects =
      [[NSClassFromString(@"LocalProjectsModule") alloc] init];
  [unsafeProjects setValue:unsafeAccess forKey:@"projectAccess"];
  XCTestExpectation *unsafeFinished = [self expectationWithDescription:
      @"unsafe root list rejects"];
  __block BOOL unsafeRejected = NO;
  [unsafeProjects listWithResolver:^(__unused id value) {
    [unsafeFinished fulfill];
  } rejecter:^(__unused NSString *code, __unused NSString *message,
               __unused NSError *error) {
    unsafeRejected = YES;
    [unsafeFinished fulfill];
  }];
  [self waitForExpectations:@[unsafeFinished] timeout:5.0];
  XCTAssertTrue(unsafeRejected);
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:sentinel.path]);

  DSHUnavailableProjectAccess *unavailableAccess =
      [[DSHUnavailableProjectAccess alloc]
          initWithProjectsRootURL:self.projectsURL];
  LocalProjectsModule *unavailableProjects =
      [[NSClassFromString(@"LocalProjectsModule") alloc] init];
  [unavailableProjects setValue:unavailableAccess forKey:@"projectAccess"];
  BOOL unavailableRejected = NO;
  NSDictionary *unavailableResult = [self
      listProjectsSynchronously:unavailableProjects
                       rejected:&unavailableRejected];
  XCTAssertTrue(unavailableRejected);
  XCTAssertNil(unavailableResult);
}

- (void)testFailedCreatesDoNotLeakAndListReconcilesOnlyOwnedOrphans {
  DSHFailingPublishLocalProjectsModule *projects =
      [[DSHFailingPublishLocalProjectsModule alloc] init];
  [projects setValue:self.access forKey:@"projectAccess"];
  for (NSUInteger attempt = 0; attempt < 3; attempt++) {
    XCTestExpectation *failed = [self expectationWithDescription:
        [NSString stringWithFormat:@"failed create %lu", (unsigned long)attempt]];
    __block BOOL rejected = NO;
    [projects createProjectWithName:@"Failure"
        resolver:^(__unused id value) { [failed fulfill]; }
        rejecter:^(__unused NSString *code, __unused NSString *message,
                   __unused NSError *error) {
          rejected = YES;
          [failed fulfill];
        }];
    [self waitForExpectations:@[failed] timeout:5.0];
    XCTAssertTrue(rejected);
  }
  NSArray<NSString *> *afterFailures = [[NSFileManager defaultManager]
      contentsOfDirectoryAtPath:self.projectsURL.path error:nil];
  NSPredicate *stagingLeak = [NSPredicate predicateWithBlock:
      ^BOOL(NSString *name, __unused NSDictionary *bindings) {
        return [name hasPrefix:@".staging-"] || [name hasPrefix:@".orphan-"];
      }];
  XCTAssertEqual([afterFailures filteredArrayUsingPredicate:stagingLeak].count,
                 (NSUInteger)0);

  NSString *ownedToken = @"eeeeeeee-eeee-4eee-8eee-000000000001";
  NSURL *owned = [self.projectsURL URLByAppendingPathComponent:
      [@".orphan-" stringByAppendingString:ownedToken] isDirectory:YES];
  XCTAssertTrue([[NSFileManager defaultManager]
      createDirectoryAtURL:owned withIntermediateDirectories:NO
      attributes:@{NSFilePosixPermissions : @0700} error:nil]);
  NSDictionary *marker = @{
    @"schema_version" : @1,
    @"project_id" : DSHFixtureProjectA,
    @"cleanup_token" : ownedToken,
  };
  NSData *markerData = [NSJSONSerialization dataWithJSONObject:marker
      options:NSJSONWritingSortedKeys error:nil];
  NSURL *markerURL = [owned URLByAppendingPathComponent:
      @".rish-staging-owner.json"];
  XCTAssertTrue([markerData writeToURL:markerURL atomically:YES]);
  XCTAssertEqual(chmod(markerURL.fileSystemRepresentation, 0600), 0);
  XCTAssertTrue([DSHData(@"owned") writeToURL:
      [owned URLByAppendingPathComponent:@"payload.txt"] atomically:YES]);

  NSURL *foreign = [self.projectsURL URLByAppendingPathComponent:
      @".orphan-eeeeeeee-eeee-4eee-8eee-000000000002" isDirectory:YES];
  XCTAssertTrue([[NSFileManager defaultManager]
      createDirectoryAtURL:foreign withIntermediateDirectories:NO
      attributes:@{NSFilePosixPermissions : @0700} error:nil]);
  NSURL *foreignSentinel = [foreign URLByAppendingPathComponent:@"sentinel.txt"];
  XCTAssertTrue([DSHData(@"foreign") writeToURL:foreignSentinel atomically:YES]);
  NSURL *outside = [self.temporaryURL
      URLByAppendingPathComponent:@"outside-orphan" isDirectory:YES];
  XCTAssertTrue([[NSFileManager defaultManager]
      createDirectoryAtURL:outside withIntermediateDirectories:YES
      attributes:@{NSFilePosixPermissions : @0700} error:nil]);
  NSURL *outsideSentinel = [outside URLByAppendingPathComponent:@"sentinel.txt"];
  XCTAssertTrue([DSHData(@"outside") writeToURL:outsideSentinel atomically:YES]);
  NSURL *orphanSymlink = [self.projectsURL URLByAppendingPathComponent:
      @".orphan-eeeeeeee-eeee-4eee-8eee-000000000003"];
  XCTAssertEqual(symlink(outside.fileSystemRepresentation,
                         orphanSymlink.fileSystemRepresentation), 0);

  XCTestExpectation *listed = [self expectationWithDescription:
      @"orphan reconciliation"];
  __block BOOL listRejected = NO;
  [projects listWithResolver:^(__unused id value) {
    [listed fulfill];
  } rejecter:^(__unused NSString *code, __unused NSString *message,
               __unused NSError *error) {
    listRejected = YES;
    [listed fulfill];
  }];
  [self waitForExpectations:@[listed] timeout:5.0];
  XCTAssertFalse(listRejected);
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:owned.path]);
  XCTAssertTrue([[NSFileManager defaultManager]
      fileExistsAtPath:foreignSentinel.path]);
  XCTAssertTrue([[NSFileManager defaultManager]
      fileExistsAtPath:outsideSentinel.path]);
  struct stat symlinkMetadata = {};
  XCTAssertEqual(lstat(orphanSymlink.fileSystemRepresentation,
                       &symlinkMetadata), 0);
  XCTAssertTrue(S_ISLNK(symlinkMetadata.st_mode));

  LocalProjectsModule *normalProjects =
      [[NSClassFromString(@"LocalProjectsModule") alloc] init];
  [normalProjects setValue:self.access forKey:@"projectAccess"];
  XCTestExpectation *created = [self expectationWithDescription:
      @"normal create still publishes"];
  __block NSDictionary *createdProject = nil;
  __block BOOL createRejected = NO;
  [normalProjects createProjectWithName:@"Published"
      resolver:^(NSDictionary *value) {
        createdProject = value;
        [created fulfill];
      }
      rejecter:^(__unused NSString *code, __unused NSString *message,
                 __unused NSError *error) {
        createRejected = YES;
        [created fulfill];
      }];
  [self waitForExpectations:@[created] timeout:5.0];
  XCTAssertFalse(createRejected);
  NSString *publishedId = createdProject[@"id"];
  XCTAssertTrue([DSHLocalProjectAccess isCanonicalProjectId:publishedId]);
  NSURL *publishedDirectory = [self.projectsURL
      URLByAppendingPathComponent:publishedId isDirectory:YES];
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:
      [publishedDirectory URLByAppendingPathComponent:@"repo/.git"
                                         isDirectory:YES].path]);
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:
      [publishedDirectory URLByAppendingPathComponent:
          @".rish-staging-owner.json"].path]);
}

- (void)testOrphanReconciliationUsesSharedBudgetAndNeverBlocksListing {
  LocalProjectsModule *projects =
      [[NSClassFromString(@"LocalProjectsModule") alloc] init];
  [projects setValue:self.access forKey:@"projectAccess"];
  NSURL *(^makeOwnedOrphan)(NSString *) = ^NSURL *(NSString *token) {
    NSURL *orphan = [self.projectsURL URLByAppendingPathComponent:
        [@".orphan-" stringByAppendingString:token] isDirectory:YES];
    XCTAssertTrue([[NSFileManager defaultManager]
        createDirectoryAtURL:orphan withIntermediateDirectories:NO
        attributes:@{NSFilePosixPermissions : @0700} error:nil]);
    NSData *marker = [NSJSONSerialization dataWithJSONObject:@{
      @"schema_version" : @1,
      @"project_id" : DSHFixtureProjectA,
      @"cleanup_token" : token,
    } options:NSJSONWritingSortedKeys error:nil];
    NSURL *markerURL = [orphan URLByAppendingPathComponent:
        @".rish-staging-owner.json"];
    XCTAssertTrue([marker writeToURL:markerURL atomically:YES]);
    XCTAssertEqual(chmod(markerURL.fileSystemRepresentation, 0600), 0);
    return orphan;
  };

  NSURL *blocked = makeOwnedOrphan(
      @"eeeeeeee-eeee-4eee-8eee-000000000010");
  NSURL *fifo = [blocked URLByAppendingPathComponent:@"blocked.fifo"];
  XCTAssertEqual(mkfifo(fifo.fileSystemRepresentation, 0600), 0);
  BOOL rejected = NO;
  NSDictionary *result = [self listProjectsSynchronously:projects
                                                 rejected:&rejected];
  XCTAssertFalse(rejected);
  XCTAssertEqualObjects(result[@"schema_version"], @1);
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:blocked.path]);
  XCTAssertTrue([[NSFileManager defaultManager] removeItemAtURL:blocked
                                                          error:nil]);

  NSURL *large = makeOwnedOrphan(
      @"eeeeeeee-eeee-4eee-8eee-000000000011");
  for (NSUInteger index = 0; index < 300; index++) {
    NSString *name = [NSString stringWithFormat:@"entry-%03lu.txt",
                                                (unsigned long)index];
    XCTAssertTrue([DSHData(@"x") writeToURL:
        [large URLByAppendingPathComponent:name] atomically:YES]);
  }
  rejected = NO;
  result = [self listProjectsSynchronously:projects rejected:&rejected];
  XCTAssertFalse(rejected);
  XCTAssertNotNil(result);
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:large.path]);
  for (NSUInteger pass = 0; pass < 10 &&
       [[NSFileManager defaultManager] fileExistsAtPath:large.path]; pass++) {
    rejected = NO;
    XCTAssertNotNil([self listProjectsSynchronously:projects
                                               rejected:&rejected]);
    XCTAssertFalse(rejected);
  }
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:large.path]);
}

- (void)testFailedLargeCreateQuarantinesWithinBudgetAndReconcilesProgressively {
  DSHFailingPublishLocalProjectsModule *projects =
      [[DSHFailingPublishLocalProjectsModule alloc] init];
  projects.extraStagingEntries = 300;
  [projects setValue:self.access forKey:@"projectAccess"];
  XCTestExpectation *finished = [self expectationWithDescription:
      @"large failed create rejects after bounded quarantine"];
  __block BOOL rejected = NO;
  [projects createProjectWithName:@"Large failure"
      resolver:^(__unused id value) { [finished fulfill]; }
      rejecter:^(__unused NSString *code, __unused NSString *message,
                 __unused NSError *error) {
        rejected = YES;
        [finished fulfill];
      }];
  [self waitForExpectations:@[finished] timeout:5.0];
  XCTAssertTrue(rejected);
  NSArray<NSString *> *names = [[NSFileManager defaultManager]
      contentsOfDirectoryAtPath:self.projectsURL.path error:nil];
  NSPredicate *staging = [NSPredicate predicateWithBlock:
      ^BOOL(NSString *name, __unused NSDictionary *bindings) {
        return [name hasPrefix:@".staging-"];
      }];
  NSPredicate *orphan = [NSPredicate predicateWithBlock:
      ^BOOL(NSString *name, __unused NSDictionary *bindings) {
        return [name hasPrefix:@".orphan-"];
      }];
  XCTAssertEqual([names filteredArrayUsingPredicate:staging].count,
                 (NSUInteger)0);
  XCTAssertEqual([names filteredArrayUsingPredicate:orphan].count,
                 (NSUInteger)1);
  for (NSUInteger pass = 0; pass < 10; pass++) {
    names = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:self.projectsURL.path error:nil];
    if ([names filteredArrayUsingPredicate:orphan].count == 0) break;
    BOOL listRejected = NO;
    XCTAssertNotNil([self listProjectsSynchronously:projects
                                            rejected:&listRejected]);
    XCTAssertFalse(listRejected);
  }
  names = [[NSFileManager defaultManager]
      contentsOfDirectoryAtPath:self.projectsURL.path error:nil];
  XCTAssertEqual([names filteredArrayUsingPredicate:orphan].count,
                 (NSUInteger)0);
}

- (void)testFailedPublishCleanupAccountsForStagingWrapperAtDepth64 {
  DSHFailingPublishLocalProjectsModule *projects =
      [[DSHFailingPublishLocalProjectsModule alloc] init];
  projects.extraStagingEntries = 200;
  projects.nestedFailureDepth = 64;
  [projects setValue:self.access forKey:@"projectAccess"];
  XCTestExpectation *finished = [self expectationWithDescription:
      @"depth-64 failed publish rejects"];
  __block BOOL rejected = NO;
  [projects createProjectWithName:@"Depth boundary"
      resolver:^(__unused id value) { [finished fulfill]; }
      rejecter:^(__unused NSString *code, __unused NSString *message,
                 __unused NSError *error) {
        rejected = YES;
        [finished fulfill];
      }];
  [self waitForExpectations:@[finished] timeout:5.0];
  XCTAssertTrue(rejected);
  XCTAssertTrue(projects.nestedFixtureCreated);
  NSPredicate *orphan = [NSPredicate predicateWithBlock:
      ^BOOL(NSString *name, __unused NSDictionary *bindings) {
        return [name hasPrefix:@".orphan-"];
      }];
  NSArray<NSString *> *names = [[NSFileManager defaultManager]
      contentsOfDirectoryAtPath:self.projectsURL.path error:nil];
  XCTAssertEqual([names filteredArrayUsingPredicate:orphan].count,
                 (NSUInteger)1);
  for (NSUInteger pass = 0; pass < 12; pass++) {
    names = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:self.projectsURL.path error:nil];
    if ([names filteredArrayUsingPredicate:orphan].count == 0) break;
    BOOL listRejected = NO;
    XCTAssertNotNil([self listProjectsSynchronously:projects
                                            rejected:&listRejected]);
    XCTAssertFalse(listRejected);
  }
  names = [[NSFileManager defaultManager]
      contentsOfDirectoryAtPath:self.projectsURL.path error:nil];
  XCTAssertEqual([names filteredArrayUsingPredicate:orphan].count,
                 (NSUInteger)0);
}

- (void)testProjectMetadataWriterRequiresWriteLeaseCapability {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"README.md"
                                          content:@"metadata capability\n"
                                           commit:YES];
  XCTAssertFalse([self.access respondsToSelector:NSSelectorFromString(
      @"writeProjectMetadataRecord:projectDescriptor:error:")]);
  NSError *error = nil;
  DSHLocalProjectLease *readLease = [self.access
      leaseProjectId:fixture.projectId mode:DSHLocalProjectAccessModeRead
      includeMetadata:NO timeout:0 error:&error];
  XCTAssertNotNil(readLease);
  NSDictionary *record = @{
    @"schema_version" : @1,
    @"name" : @"Write Lease Only",
    @"created_at" : @"2026-05-03T03:22:57.125Z",
    @"updated_at" : @"2026-05-04T03:22:57.125Z",
    @"origin_url" : NSNull.null,
  };
  XCTAssertFalse([self.access writeProjectMetadataRecord:record
                                                    lease:readLease
                                                    error:&error]);
  XCTAssertEqual(error.code, DSHLocalProjectAccessErrorUnsafeStorage);
}

- (void)testProjectPublishRejectsStagingVnodeReplacement {
  LocalProjectsModule *projects =
      [[NSClassFromString(@"LocalProjectsModule") alloc] init];
  XCTAssertNotNil(projects);
  [projects setValue:self.access forKey:@"projectAccess"];
  NSError *error = nil;
  DSHLocalProjectLockToken *writeToken = [self.access
      lockProjectId:DSHFixtureProjectA
               mode:DSHLocalProjectAccessModeWrite error:&error];
  XCTAssertNotNil(writeToken);
  NSURL *staging = [projects createStagingDirectoryAtRoot:self.projectsURL
                                                projectId:DSHFixtureProjectA
                                                     error:&error];
  XCTAssertNotNil(staging);
  XCTAssertTrue([[NSFileManager defaultManager]
      createDirectoryAtURL:[staging URLByAppendingPathComponent:@"repo"]
      withIntermediateDirectories:NO
      attributes:@{NSFilePosixPermissions : @0700} error:&error]);
  NSDictionary *metadata = @{
    @"schema_version" : @1,
    @"name" : @"Pinned Staging",
    @"created_at" : @"2026-05-03T03:22:57.125Z",
    @"updated_at" : @"2026-05-04T03:22:57.125Z",
    @"origin_url" : NSNull.null,
  };
  XCTAssertTrue([projects writeMetadata:metadata
                     atProjectDirectory:staging projectId:DSHFixtureProjectA
                              writeToken:writeToken error:&error]);
  NSURL *pinned = [self.projectsURL
      URLByAppendingPathComponent:@".staging-pinned" isDirectory:YES];
  XCTAssertEqual(rename(staging.fileSystemRepresentation,
                        pinned.fileSystemRepresentation),
                 0);
  XCTAssertTrue([[NSFileManager defaultManager]
      createDirectoryAtURL:staging withIntermediateDirectories:NO
      attributes:@{NSFilePosixPermissions : @0700} error:&error]);
  XCTAssertTrue([[NSFileManager defaultManager]
      createDirectoryAtURL:[staging URLByAppendingPathComponent:@"repo"]
      withIntermediateDirectories:NO
      attributes:@{NSFilePosixPermissions : @0700} error:&error]);
  XCTAssertTrue([DSHData(@"{}") writeToURL:
      [staging URLByAppendingPathComponent:@"project.json"] atomically:YES]);
  XCTAssertFalse([projects publishStagingDirectory:staging
                                            atRoot:self.projectsURL
                                         projectId:DSHFixtureProjectA
                                             error:&error]);
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:
      [self.projectsURL URLByAppendingPathComponent:DSHFixtureProjectA].path]);
}

- (void)testProjectPublishRejectsNonExactEntryForCanonicalStagingName {
  LocalProjectsModule *projects =
      [[NSClassFromString(@"LocalProjectsModule") alloc] init];
  [projects setValue:self.access forKey:@"projectAccess"];
  NSError *error = nil;
  DSHLocalProjectLockToken *writeToken = [self.access
      lockProjectId:DSHFixtureProjectA mode:DSHLocalProjectAccessModeWrite
      error:&error];
  NSURL *staging = [projects createStagingDirectoryAtRoot:self.projectsURL
                                                projectId:DSHFixtureProjectA
                                                     error:&error];
  XCTAssertNotNil(staging);
  XCTAssertTrue([[NSFileManager defaultManager]
      createDirectoryAtURL:[staging URLByAppendingPathComponent:@"repo"]
      withIntermediateDirectories:NO
      attributes:@{NSFilePosixPermissions : @0700} error:&error]);
  NSDictionary *metadata = @{
    @"schema_version" : @1, @"name" : @"Alias Staging",
    @"created_at" : @"2026-05-03T03:22:57.125Z",
    @"updated_at" : @"2026-05-04T03:22:57.125Z",
    @"origin_url" : NSNull.null,
  };
  XCTAssertTrue([projects writeMetadata:metadata
                     atProjectDirectory:staging projectId:DSHFixtureProjectA
                              writeToken:writeToken error:&error]);
  NSURL *alias = [self.projectsURL URLByAppendingPathComponent:
      [@".STAGING-" stringByAppendingString:DSHFixtureProjectA]
                                                isDirectory:YES];
  XCTAssertEqual(rename(staging.fileSystemRepresentation,
                        alias.fileSystemRepresentation), 0);
  NSArray<NSString *> *names = [[NSFileManager defaultManager]
      contentsOfDirectoryAtPath:self.projectsURL.path error:&error];
  XCTAssertTrue([names containsObject:alias.lastPathComponent]);
  XCTAssertTrue([projects respondsToSelector:
      @selector(stagingEntryIsExactForProjectId:error:)]);
  if ([projects respondsToSelector:
          @selector(stagingEntryIsExactForProjectId:error:)]) {
    XCTAssertFalse([projects stagingEntryIsExactForProjectId:DSHFixtureProjectA
                                                       error:&error]);
  }
  XCTAssertFalse([projects publishStagingDirectory:staging
                                            atRoot:self.projectsURL
                                         projectId:DSHFixtureProjectA
                                             error:&error]);
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:
      [self.projectsURL URLByAppendingPathComponent:DSHFixtureProjectA].path]);
}

- (void)testProjectCreateRootSwapNeverWritesOrDeletesReplacementTree {
  DSHRootSwappingLocalProjectsModule *projects =
      [[DSHRootSwappingLocalProjectsModule alloc] init];
  [projects setValue:self.access forKey:@"projectAccess"];
  NSURL *pinnedRoot = [self.temporaryURL
      URLByAppendingPathComponent:@"projects-pinned-create" isDirectory:YES];
  __block NSURL *replacementStaging = nil;
  __block NSURL *replacementSentinel = nil;
  projects.afterCreateStaging = ^(NSURL *staging) {
    XCTAssertEqual(rename(self.projectsURL.fileSystemRepresentation,
                          pinnedRoot.fileSystemRepresentation), 0);
    XCTAssertTrue([[NSFileManager defaultManager]
        createDirectoryAtURL:self.projectsURL withIntermediateDirectories:NO
        attributes:@{NSFilePosixPermissions : @0700} error:nil]);
    replacementStaging = [self.projectsURL
        URLByAppendingPathComponent:staging.lastPathComponent isDirectory:YES];
    XCTAssertTrue([[NSFileManager defaultManager]
        createDirectoryAtURL:replacementStaging withIntermediateDirectories:NO
        attributes:@{NSFilePosixPermissions : @0700} error:nil]);
    replacementSentinel = [replacementStaging
        URLByAppendingPathComponent:@"replacement-sentinel.txt"];
    XCTAssertTrue([DSHData(@"replacement must survive")
        writeToURL:replacementSentinel atomically:YES]);
  };
  XCTestExpectation *finished = [self expectationWithDescription:
      @"root-swapped create rejects"];
  __block BOOL rejected = NO;
  [projects createProjectWithName:@"Swapped"
      resolver:^(__unused id result) { [finished fulfill]; }
      rejecter:^(__unused NSString *code, __unused NSString *message,
                 __unused NSError *error) {
        rejected = YES;
        [finished fulfill];
      }];
  [self waitForExpectations:@[finished] timeout:5.0];
  XCTAssertTrue(rejected);
  XCTAssertTrue([[NSFileManager defaultManager]
      fileExistsAtPath:replacementSentinel.path]);
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:
      [replacementStaging URLByAppendingPathComponent:@"repo"].path]);
  NSArray<NSString *> *oldRootNames = [[NSFileManager defaultManager]
      contentsOfDirectoryAtPath:pinnedRoot.path error:nil];
  NSPredicate *publishedProject = [NSPredicate predicateWithBlock:
      ^BOOL(NSString *name, __unused NSDictionary *bindings) {
        return [DSHLocalProjectAccess isCanonicalProjectId:name];
      }];
  XCTAssertEqual([oldRootNames filteredArrayUsingPredicate:publishedProject].count,
                 (NSUInteger)0);

  NSURL *replacementRoot = [self.temporaryURL
      URLByAppendingPathComponent:@"projects-replacement-create"
                      isDirectory:YES];
  XCTAssertEqual(rename(self.projectsURL.fileSystemRepresentation,
                        replacementRoot.fileSystemRepresentation), 0);
  XCTAssertEqual(rename(pinnedRoot.fileSystemRepresentation,
                        self.projectsURL.fileSystemRepresentation), 0);
  LocalProjectsModule *reconciler =
      [[NSClassFromString(@"LocalProjectsModule") alloc] init];
  [reconciler setValue:self.access forKey:@"projectAccess"];
  BOOL listRejected = NO;
  XCTAssertNotNil([self listProjectsSynchronously:reconciler
                                          rejected:&listRejected]);
  XCTAssertFalse(listRejected);
  NSArray<NSString *> *restoredNames = [[NSFileManager defaultManager]
      contentsOfDirectoryAtPath:self.projectsURL.path error:nil];
  XCTAssertEqual([restoredNames filteredArrayUsingPredicate:
      [NSPredicate predicateWithBlock:
          ^BOOL(NSString *name, __unused NSDictionary *bindings) {
            return [name hasPrefix:@".staging-"];
          }]].count, (NSUInteger)0);
  NSURL *movedReplacementSentinel = [[replacementRoot
      URLByAppendingPathComponent:replacementStaging.lastPathComponent
                      isDirectory:YES]
      URLByAppendingPathComponent:replacementSentinel.lastPathComponent];
  XCTAssertTrue([[NSFileManager defaultManager]
      fileExistsAtPath:movedReplacementSentinel.path]);
}

- (void)testGitTransportProxyValidationRejectsUnsafeExplicitValues {
  NSString *oversized = [@"http://localhost:8080/" stringByPaddingToLength:2049
      withString:@"x" startingAtIndex:0];
  NSArray *invalidOptions = @[
    @"http://localhost:8080/",
    @{ @"httpsProxyUrl" : @42 },
    @{ @"httpsProxyUrl" : @" http://localhost:8080/" },
    @{ @"httpsProxyUrl" : @"http://localhost:8080/ " },
    @{ @"httpsProxyUrl" : @"http://local\nhost:8080/" },
    @{ @"httpsProxyUrl" : oversized },
    @{ @"httpsProxyUrl" : @"ftp://localhost:8080/" },
    @{ @"httpsProxyUrl" : @"http://localhost/" },
    @{ @"httpsProxyUrl" : @"http://localhost:0/" },
    @{ @"httpsProxyUrl" : @"http://localhost:65536/" },
    @{ @"httpsProxyUrl" : @"http://localhost:8080/git" },
    @{ @"httpsProxyUrl" : @"http://user@localhost:8080/" },
    @{ @"httpsProxyUrl" : @"http://localhost:8080/?token=secret" },
    @{ @"httpsProxyUrl" : @"http://localhost:8080/#fragment" },
    @{ @"httpsProxyUrl" : @"http://:8080/" },
  ];
  for (id options in invalidOptions) {
    NSString *message = nil;
    XCTAssertEqualObjects([self pushRejectionCodeForOptions:options
                                                    message:&message],
                          @"validation");
    XCTAssertTrue([message hasPrefix:@"HTTPS proxy"]);
    XCTAssertFalse([message containsString:@"token=secret"]);
  }
}

- (void)testGitTransportProxyValidationAllowsDirectPrivateAndLoopbackEndpoints {
  NSArray *acceptedOptions = @[
    @{},
    @{ @"httpsProxyUrl" : NSNull.null },
    @{ @"httpsProxyUrl" : @"" },
    @{ @"httpsProxyUrl" : @"http://127.0.0.1:8080" },
    @{ @"httpsProxyUrl" : @"http://localhost:7890/" },
    @{ @"httpsProxyUrl" : @"https://10.0.0.2:443/" },
    @{ @"httpsProxyUrl" : @"https://[::1]:8443" },
  ];
  for (id options in acceptedOptions) {
    NSString *message = nil;
    XCTAssertEqualObjects([self pushRejectionCodeForOptions:options
                                                    message:&message],
                          @"project");
    XCTAssertFalse([message hasPrefix:@"HTTPS proxy"]);
  }
}

// Explicitly gated UI fixture: production create/stage APIs, app process only.
- (void)testPrepareVisibleDiffReviewFixture {
  NSString *name = NSProcessInfo.processInfo.environment[@"DSH_DIFF_UI_FIXTURE_NAME"];
  if (![name isEqual:@"UX04-review-0906"]) { XCTSkip(@"UI fixture was not requested"); return; }
  LocalProjectsModule *module = [[LocalProjectsModule alloc] init];
  XCTestExpectation *created = [self expectationWithDescription:@"create UI review fixture"];
  __block NSDictionary *project = nil;
  [module createProjectWithName:name resolver:^(id result) { project = result; [created fulfill]; }
    rejecter:^(NSString *code, NSString *message, __unused NSError *error) {
      XCTFail(@"UI fixture creation failed: %@ %@", code, message); [created fulfill];
    }];
  [self waitForExpectations:@[created] timeout:10];
  if (project == nil) return;
  DSHLocalProjectAccess *access = [DSHLocalProjectAccess sharedAccess];
  __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *lease =
    [access leaseProjectId:project[@"id"] mode:DSHLocalProjectAccessModeWrite includeMetadata:NO error:nil];
  XCTAssertNotNil(lease);
  if (lease == nil) return;
  NSURL *file = [lease.repositoryURL URLByAppendingPathComponent:@"00-review.txt"];
  XCTAssertTrue([DSHData(@"index-only-v1\n") writeToURL:file atomically:YES]);
  NSMutableString *large = [NSMutableString string];
  for (NSUInteger i = 0; i < 60000; i++) [large appendFormat:@"line-%05lu 中文分页内容\n", (unsigned long)i];
  XCTAssertTrue([DSHData(large) writeToURL:[lease.repositoryURL URLByAppendingPathComponent:@"large-review.txt"] atomically:YES]);
  lease = nil;
  XCTestExpectation *staged = [self expectationWithDescription:@"stage UI fixture"];
  [module stageAllForProject:project[@"id"] resolver:^(__unused id result) { [staged fulfill]; }
    rejecter:^(NSString *code, NSString *message, __unused NSError *error) {
      XCTFail(@"UI fixture stage failed: %@ %@", code, message); [staged fulfill];
    }];
  [self waitForExpectations:@[staged] timeout:10];
  lease = [access leaseProjectId:project[@"id"] mode:DSHLocalProjectAccessModeWrite includeMetadata:NO error:nil];
  XCTAssertNotNil(lease);
  if (lease == nil) return;
  XCTAssertTrue([DSHData(@"worktree-only-v2\n") writeToURL:
    [lease.repositoryURL URLByAppendingPathComponent:@"00-review.txt"] atomically:YES]);
  lease = nil;
  NSLog(@"DIFF_UI_FIXTURE: %@", project);
}

- (NSDictionary *)reviewPage:(LocalProjectsModule *)module staged:(BOOL)staged
                       offset:(NSUInteger)offset snapshot:(NSString *)snapshot code:(NSString **)code {
  XCTestExpectation *done = [self expectationWithDescription:@"diff review page"];
  __block NSDictionary *value = nil;
  __block NSString *failure = nil;
  [module diffPageForProject:DSHFixtureProjectA staged:staged offset:@(offset)
    snapshot:snapshot ?: NSNull.null resolver:^(id result) { value = result; [done fulfill]; }
    rejecter:^(NSString *result, __unused NSString *message, __unused NSError *error) { failure = result; [done fulfill]; }];
  [self waitForExpectations:@[done] timeout:10];
  if (code != nil) *code = failure;
  return value;
}

- (void)testDiffReviewSeparatesIndexAndWorktreeAfterReopen {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA name:@"review"
    initialFile:@"README.md" content:@"base\n" commit:YES];
  [self writeString:@"index-only\n" relativePath:@"README.md" fixture:fixture];
  [self addPathToIndex:@"README.md" fixture:fixture];
  [self writeString:@"worktree-only\n" relativePath:@"README.md" fixture:fixture];
  for (NSUInteger reopen = 0; reopen < 2; reopen++) {
    LocalProjectsModule *module = [[LocalProjectsModule alloc] init];
    [module setValue:self.access forKey:@"projectAccess"];
    NSDictionary *staged = [self reviewPage:module staged:YES offset:0 snapshot:nil code:nil];
    NSDictionary *unstaged = [self reviewPage:module staged:NO offset:0 snapshot:nil code:nil];
    XCTAssertTrue([staged[@"patch"] containsString:@"+index-only"]);
    XCTAssertFalse([staged[@"patch"] containsString:@"worktree-only"]);
    XCTAssertTrue([unstaged[@"patch"] containsString:@"-index-only"]);
    XCTAssertTrue([unstaged[@"patch"] containsString:@"+worktree-only"]);
    XCTAssertNotEqualObjects(staged[@"snapshot_id"], unstaged[@"snapshot_id"]);
  }
}

- (void)testDiffReviewPagesCoverTruncatedUTF8PatchAndRejectChangedSnapshot {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA name:@"pages"
    initialFile:@"large.txt" content:@"base\n" commit:YES];
  NSMutableString *content = [NSMutableString string];
  for (NSUInteger i = 0; i < 55000; i++) [content appendFormat:@"%06lu 中文内容-review\n", (unsigned long)i];
  [content appendString:@"END-OF-REVIEW\n"];
  [self writeString:content relativePath:@"large.txt" fixture:fixture];
  [self addPathToIndex:@"large.txt" fixture:fixture];
  LocalProjectsModule *module = [[LocalProjectsModule alloc] init];
  [module setValue:self.access forKey:@"projectAccess"];
  NSDictionary *preview = [module diffForRepository:fixture.repository projectId:DSHFixtureProjectA
    staged:YES contextLines:3 error:nil];
  XCTAssertEqualObjects(preview[@"truncated"], @YES);
  NSMutableString *joined = [NSMutableString string];
  NSUInteger offset = 0;
  NSString *snapshot = nil;
  NSUInteger pages = 0;
  do {
    NSDictionary *page = [self reviewPage:module staged:YES offset:offset snapshot:snapshot code:nil];
    XCTAssertNotNil(page);
    if (page == nil) return;
    XCTAssertLessThanOrEqual([page[@"patch"] lengthOfBytesUsingEncoding:NSUTF8StringEncoding], (NSUInteger)65536);
    [joined appendString:page[@"patch"]];
    snapshot = page[@"snapshot_id"];
    pages++;
    if (page[@"next_offset"] == NSNull.null) break;
    XCTAssertGreaterThan([page[@"next_offset"] unsignedIntegerValue], offset);
    offset = [page[@"next_offset"] unsignedIntegerValue];
  } while (pages < 100);
  XCTAssertGreaterThan(pages, (NSUInteger)16);
  XCTAssertTrue([joined hasPrefix:preview[@"patch"]]);
  XCTAssertTrue([joined hasSuffix:@"+END-OF-REVIEW\n"]);
  NSArray *lines = [joined componentsSeparatedByString:@"\n"];
  NSUInteger added = 0;
  for (NSString *line in lines) if ([line hasPrefix:@"+"] && ![line hasPrefix:@"+++"]) added++;
  XCTAssertEqual(added, (NSUInteger)55001);
  [self writeString:@"new index version\n" relativePath:@"large.txt" fixture:fixture];
  [self addPathToIndex:@"large.txt" fixture:fixture];
  NSString *code = nil;
  XCTAssertNil([self reviewPage:module staged:YES offset:65536 snapshot:snapshot code:&code]);
  XCTAssertEqualObjects(code, @"diff_changed");
}

- (void)testDiffReviewDisclosesBinaryOmissionAndValidatesCursor {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA name:@"binary"
    initialFile:@"README.md" content:@"base\n" commit:YES];
  const char bytes[] = {0, 1, 2, 3};
  [self writeBytes:[NSData dataWithBytes:bytes length:sizeof(bytes)] relativePath:@"binary.bin" fixture:fixture];
  [self addPathToIndex:@"binary.bin" fixture:fixture];
  LocalProjectsModule *module = [[LocalProjectsModule alloc] init];
  [module setValue:self.access forKey:@"projectAccess"];
  NSDictionary *page = [self reviewPage:module staged:YES offset:0 snapshot:nil code:nil];
  XCTAssertTrue([page[@"omitted_paths"] containsObject:@"binary.bin"]);
  NSString *code = nil;
  XCTAssertNil([self reviewPage:module staged:YES offset:1 snapshot:nil code:&code]);
  XCTAssertEqualObjects(code, @"validation");
}

- (NSDictionary *)cloneSnapshot:(LocalProjectsModule *)module {
  __block NSDictionary *snapshot = nil;
  [module cloneStatusForOperation:NSNull.null resolver:^(id result) {
    snapshot = result == NSNull.null ? nil : result;
  } rejecter:^(NSString *code, __unused NSString *message, __unused NSError *error) {
    XCTFail(@"Unexpected clone status rejection: %@", code);
  }];
  return snapshot;
}

- (void)testCloneCancellationWhileQueuedIsQueryableAndNeverStartsNetwork {
  LocalProjectsModule *module = [[LocalProjectsModule alloc] init];
  [module setValue:self.access forKey:@"projectAccess"];
  dispatch_queue_t queue = [module valueForKey:@"projectQueue"];
  dispatch_semaphore_t release = dispatch_semaphore_create(0);
  dispatch_async(queue, ^{ dispatch_semaphore_wait(release,
      dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)); });
  __block NSDictionary *started = nil;
  [module startCloneURL:@"https://example.com/queued.git" name:@"queued" options:@{}
    resolver:^(id result) { started = result; }
    rejecter:^(NSString *code, __unused NSString *message, __unused NSError *error) {
      XCTFail(@"Unexpected start rejection: %@", code);
    }];
  XCTAssertEqualObjects(started[@"phase"], @"queued");
  __block NSString *secondCode = nil;
  [module startCloneURL:@"https://example.com/second.git" name:@"second" options:@{}
    resolver:^(__unused id result) { XCTFail(@"Concurrent clone accepted"); }
    rejecter:^(NSString *code, __unused NSString *message, __unused NSError *error) { secondCode = code; }];
  XCTAssertEqualObjects(secondCode, @"busy");
  [module cancelCloneOperation:started[@"operation_id"] resolver:^(id result) {
    XCTAssertEqualObjects(result[@"cancel_requested"], @YES);
    XCTAssertEqualObjects(result[@"phase"], @"queued");
  } rejecter:^(__unused NSString *code, __unused NSString *message, __unused NSError *error) { XCTFail(@"Cancel rejected"); }];
  XCTAssertEqualObjects([self cloneSnapshot:module][@"operation_id"], started[@"operation_id"]);
  dispatch_semaphore_signal(release);
  dispatch_sync(queue, ^{});
  NSDictionary *terminal = [self cloneSnapshot:module];
  XCTAssertEqualObjects(terminal[@"phase"], @"cancelled");
  XCTAssertEqualObjects(terminal[@"project"], NSNull.null);
  NSArray *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:self.projectsURL.path error:nil];
  XCTAssertEqual(entries.count, (NSUInteger)0);
}

- (void)testCloneCancellationAfterStagingCleansUpWithoutPublishing {
  LocalProjectsModule *module = [[LocalProjectsModule alloc] init];
  [module setValue:self.access forKey:@"projectAccess"];
  __weak LocalProjectsModule *weakModule = module;
  __block BOOL sawStaging = NO;
  [module setValue:^(NSString *phase) {
    if (![phase isEqual:@"before_transfer"]) return;
    sawStaging = [NSFileManager.defaultManager contentsOfDirectoryAtPath:self.projectsURL.path error:nil].count > 0;
    NSDictionary *operation = [self cloneSnapshot:weakModule];
    [weakModule cancelCloneOperation:operation[@"operation_id"] resolver:^(__unused id result) {}
      rejecter:^(__unused NSString *code, __unused NSString *message, __unused NSError *error) { XCTFail(@"Cancel rejected"); }];
  } forKey:@"clonePhaseHook"];
  [module startCloneURL:@"https://example.com/staging.git" name:@"staging" options:@{}
    resolver:^(__unused id result) {} rejecter:^(__unused NSString *code, __unused NSString *message, __unused NSError *error) { XCTFail(@"Start rejected"); }];
  dispatch_sync((dispatch_queue_t)[module valueForKey:@"projectQueue"], ^{});
  XCTAssertTrue(sawStaging);
  XCTAssertEqualObjects([self cloneSnapshot:module][@"phase"], @"cancelled");
  NSArray *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:self.projectsURL.path error:nil];
  XCTAssertEqual(entries.count, (NSUInteger)0);
}

- (void)testCloneRejectsUnknownCancellationAndInvalidRequests {
  LocalProjectsModule *module = [[LocalProjectsModule alloc] init];
  __block NSString *code = nil;
  [module cancelCloneOperation:@"unknown" resolver:^(__unused id result) { XCTFail(@"Unknown cancellation accepted"); }
    rejecter:^(NSString *value, __unused NSString *message, __unused NSError *error) { code = value; }];
  XCTAssertEqualObjects(code, @"state");
  [module startCloneURL:@"https://secret@example.com/repo.git" name:@"invalid" options:@{}
    resolver:^(__unused id result) { XCTFail(@"Invalid request accepted"); }
    rejecter:^(NSString *value, NSString *message, __unused NSError *error) {
      code = value; XCTAssertFalse([message containsString:@"secret"]);
    }];
  XCTAssertEqualObjects(code, @"validation");
  XCTAssertNil([self cloneSnapshot:module]);
}

- (void)testCloneRootSwapLeavesOnlyRecoverableOwnedStaging {
  DSHRootSwappingLocalProjectsModule *projects =
      [[DSHRootSwappingLocalProjectsModule alloc] init];
  [projects setValue:self.access forKey:@"projectAccess"];
  NSURL *pinnedRoot = [self.temporaryURL
      URLByAppendingPathComponent:@"projects-pinned-clone" isDirectory:YES];
  __block NSURL *replacementStaging = nil;
  __block NSURL *replacementSentinel = nil;
  projects.afterCreateStaging = ^(NSURL *staging) {
    XCTAssertEqual(rename(self.projectsURL.fileSystemRepresentation,
                          pinnedRoot.fileSystemRepresentation), 0);
    XCTAssertTrue([[NSFileManager defaultManager]
        createDirectoryAtURL:self.projectsURL withIntermediateDirectories:NO
        attributes:@{NSFilePosixPermissions : @0700} error:nil]);
    replacementStaging = [self.projectsURL
        URLByAppendingPathComponent:staging.lastPathComponent isDirectory:YES];
    XCTAssertTrue([[NSFileManager defaultManager]
        createDirectoryAtURL:replacementStaging withIntermediateDirectories:NO
        attributes:@{NSFilePosixPermissions : @0700} error:nil]);
    replacementSentinel = [replacementStaging
        URLByAppendingPathComponent:@"replacement-clone-sentinel.txt"];
    XCTAssertTrue([DSHData(@"replacement must survive")
        writeToURL:replacementSentinel atomically:YES]);
  };
  XCTestExpectation *finished = [self expectationWithDescription:
      @"root-swapped clone rejects before network"];
  __block BOOL rejected = NO;
  [projects clonePublicRepository:@"https://example.com/repository.git"
      name:@"Swapped clone"
      options:@{}
      resolver:^(__unused id result) { [finished fulfill]; }
      rejecter:^(__unused NSString *code, __unused NSString *message,
                 __unused NSError *error) {
        rejected = YES;
        [finished fulfill];
      }];
  [self waitForExpectations:@[finished] timeout:5.0];
  XCTAssertTrue(rejected);
  XCTAssertTrue([[NSFileManager defaultManager]
      fileExistsAtPath:replacementSentinel.path]);

  NSURL *replacementRoot = [self.temporaryURL
      URLByAppendingPathComponent:@"projects-replacement-clone"
                      isDirectory:YES];
  XCTAssertEqual(rename(self.projectsURL.fileSystemRepresentation,
                        replacementRoot.fileSystemRepresentation), 0);
  XCTAssertEqual(rename(pinnedRoot.fileSystemRepresentation,
                        self.projectsURL.fileSystemRepresentation), 0);
  LocalProjectsModule *reconciler =
      [[NSClassFromString(@"LocalProjectsModule") alloc] init];
  [reconciler setValue:self.access forKey:@"projectAccess"];
  BOOL listRejected = NO;
  XCTAssertNotNil([self listProjectsSynchronously:reconciler
                                          rejected:&listRejected]);
  XCTAssertFalse(listRejected);
  NSArray<NSString *> *restoredNames = [[NSFileManager defaultManager]
      contentsOfDirectoryAtPath:self.projectsURL.path error:nil];
  XCTAssertEqual([restoredNames filteredArrayUsingPredicate:
      [NSPredicate predicateWithBlock:
          ^BOOL(NSString *name, __unused NSDictionary *bindings) {
            return [name hasPrefix:@".staging-"];
          }]].count, (NSUInteger)0);
  NSURL *movedSentinel = [[replacementRoot
      URLByAppendingPathComponent:replacementStaging.lastPathComponent
                      isDirectory:YES]
      URLByAppendingPathComponent:replacementSentinel.lastPathComponent];
  XCTAssertTrue([[NSFileManager defaultManager]
      fileExistsAtPath:movedSentinel.path]);
}

- (void)testPublishedMarkerCleanupIsRecoverableAfterCommit {
  DSHPublishFaultLocalProjectsModule *projects =
      [[DSHPublishFaultLocalProjectsModule alloc] init];
  [projects setValue:self.access forKey:@"projectAccess"];
  projects.failMarkerRemoval = YES;
  XCTestExpectation *finished = [self expectationWithDescription:
      @"publish commits before marker housekeeping"];
  __block NSDictionary *createdProject = nil;
  __block BOOL rejected = NO;
  [projects createProjectWithName:@"Recoverable marker"
      resolver:^(NSDictionary *value) {
        createdProject = value;
        [finished fulfill];
      }
      rejecter:^(__unused NSString *code, __unused NSString *message,
                 __unused NSError *error) {
        rejected = YES;
        [finished fulfill];
      }];
  [self waitForExpectations:@[finished] timeout:5.0];
  XCTAssertFalse(rejected);
  NSString *projectId = createdProject[@"id"];
  NSURL *marker = [[self.projectsURL
      URLByAppendingPathComponent:projectId isDirectory:YES]
      URLByAppendingPathComponent:@".rish-staging-owner.json"];
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:marker.path]);

  LocalProjectsModule *reconciler =
      [[NSClassFromString(@"LocalProjectsModule") alloc] init];
  [reconciler setValue:self.access forKey:@"projectAccess"];
  BOOL listRejected = NO;
  NSDictionary *listed = [self listProjectsSynchronously:reconciler
                                                 rejected:&listRejected];
  XCTAssertFalse(listRejected);
  XCTAssertEqual([listed[@"projects"] count], (NSUInteger)1);
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:marker.path]);
}

- (void)testPublishedRootSyncFailureRollsBackWithoutGhostProject {
  DSHPublishFaultLocalProjectsModule *projects =
      [[DSHPublishFaultLocalProjectsModule alloc] init];
  [projects setValue:self.access forKey:@"projectAccess"];
  projects.failPublishedRootSync = YES;
  XCTestExpectation *finished = [self expectationWithDescription:
      @"publish root sync failure rejects"];
  __block BOOL rejected = NO;
  [projects createProjectWithName:@"Undurable"
      resolver:^(__unused id value) { [finished fulfill]; }
      rejecter:^(__unused NSString *code, __unused NSString *message,
                 __unused NSError *error) {
        rejected = YES;
        [finished fulfill];
      }];
  [self waitForExpectations:@[finished] timeout:5.0];
  XCTAssertTrue(rejected);
  NSArray<NSString *> *names = [[NSFileManager defaultManager]
      contentsOfDirectoryAtPath:self.projectsURL.path error:nil];
  NSPredicate *leaked = [NSPredicate predicateWithBlock:
      ^BOOL(NSString *name, __unused NSDictionary *bindings) {
        return [name hasPrefix:@".staging-"] ||
            [name hasPrefix:@".orphan-"] ||
            [DSHLocalProjectAccess isCanonicalProjectId:name];
      }];
  XCTAssertEqual([names filteredArrayUsingPredicate:leaked].count,
                 (NSUInteger)0);
}

- (void)testMalformedTopLevelProjectMetadataFailsClosedWithoutException {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"README.md"
                                          content:@"malformed metadata\n"
                                           commit:YES];
  NSURL *metadataURL =
      [fixture.projectURL URLByAppendingPathComponent:@"project.json"];
  for (NSData *malformed in @[DSHData(@"[]"), DSHData(@"1\n")]) {
    XCTAssertTrue([malformed writeToURL:metadataURL atomically:YES]);
    __block DSHLocalProjectLease *lease = nil;
    __block NSError *error = nil;
    XCTAssertNoThrow(lease = [self.access
        leaseProjectId:fixture.projectId
                  mode:DSHLocalProjectAccessModeRead
       includeMetadata:YES
               timeout:0
                 error:&error]);
    XCTAssertNil(lease);
    XCTAssertEqualObjects(error.domain, DSHLocalProjectAccessErrorDomain);
    XCTAssertEqual(error.code, DSHLocalProjectAccessErrorMetadataInvalid);
  }
}

- (void)testRepositoryLeaseRejectsCommonDirAlternatesAndPersistentGitOrRootSwaps {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"README.md"
                                          content:@"identity\n"
                                           commit:YES];
  NSURL *gitURL = [fixture.repositoryURL URLByAppendingPathComponent:@".git"
                                                        isDirectory:YES];
  NSURL *alternates = [gitURL
      URLByAppendingPathComponent:@"objects/info/alternates"];
  XCTAssertTrue([DSHData(@"../../outside/objects\n") writeToURL:alternates
                                                   atomically:YES]);
  NSError *error = nil;
  XCTAssertNil([self.access leaseProjectId:fixture.projectId
                                      mode:DSHLocalProjectAccessModeRead
                           includeMetadata:NO timeout:0 error:&error]);
  XCTAssertTrue([[NSFileManager defaultManager] removeItemAtURL:alternates
                                                          error:nil]);
  NSURL *commonDir = [gitURL URLByAppendingPathComponent:@"commondir"];
  XCTAssertTrue([DSHData(@"../external-git\n") writeToURL:commonDir atomically:YES]);
  XCTAssertNil([self.access leaseProjectId:fixture.projectId
                                      mode:DSHLocalProjectAccessModeRead
                           includeMetadata:NO timeout:0 error:&error]);
  XCTAssertTrue([[NSFileManager defaultManager] removeItemAtURL:commonDir
                                                          error:nil]);

  __block BOOL swappedGit = NO;
  DSHLocalProjectAccess *gitSwapAccess = [[DSHLocalProjectAccess alloc]
      initWithProjectsRootURL:self.projectsURL
                         hook:^(NSString *stage) {
                           if (!swappedGit && [stage isEqual:@"before_libgit_open"]) {
                             swappedGit = YES;
                             NSURL *pinned = [fixture.repositoryURL
                                 URLByAppendingPathComponent:@".git-pinned"];
                             rename(gitURL.fileSystemRepresentation,
                                    pinned.fileSystemRepresentation);
                             symlink(".git-pinned", gitURL.fileSystemRepresentation);
                           }
                         }];
  XCTAssertNil([gitSwapAccess leaseProjectId:fixture.projectId
                                        mode:DSHLocalProjectAccessModeRead
                             includeMetadata:NO timeout:0 error:&error]);
  XCTAssertTrue(swappedGit);

  // A separate project avoids relying on the previous .git swap topology.
  fixture = [self createProject:DSHFixtureProjectB name:@"Beta"
                    initialFile:@"README.md" content:@"root identity\n" commit:YES];
  __block BOOL swappedRoot = NO;
  DSHLocalProjectAccess *rootSwapAccess = [[DSHLocalProjectAccess alloc]
      initWithProjectsRootURL:self.projectsURL
                         hook:^(NSString *stage) {
                           if (!swappedRoot && [stage isEqual:@"before_libgit_open"]) {
                             swappedRoot = YES;
                             NSURL *pinned = [self.temporaryURL
                                 URLByAppendingPathComponent:@"projects-pinned"];
                             rename(self.projectsURL.fileSystemRepresentation,
                                    pinned.fileSystemRepresentation);
                             symlink("projects-pinned",
                                     self.projectsURL.fileSystemRepresentation);
                           }
                         }];
  XCTAssertNil([rootSwapAccess leaseProjectId:fixture.projectId
                                         mode:DSHLocalProjectAccessModeRead
                              includeMetadata:NO timeout:0 error:&error]);
  XCTAssertTrue(swappedRoot);
}

- (void)testProjectLockTimeoutMapsToStablePreparationTimeout {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"README.md"
                                          content:@"locked\n"
                                           commit:YES];
  DSHProjectContextService *service = [[DSHProjectContextService alloc]
      initWithProjectAccess:[[DSHImmediateTimeoutProjectAccess alloc]
                                initWithProjectsRootURL:self.projectsURL]
                      store:self.store
                     policy:[[DSHProjectContextPolicy alloc] init]
                      clock:^NSDate *{ return self.now; }
        identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }
                       hook:nil];
  NSError *error = nil;
  XCTAssertNil([service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error]);
  XCTAssertEqualObjects(error.domain, DSHProjectContextServiceErrorDomain);
  XCTAssertEqual(error.code, DSHProjectContextServiceErrorTimeout);
}

- (NSDictionary *)repositoryState:(DSHProjectFixture *)fixture {
  git_index *index = nullptr;
  git_reference *head = nullptr;
  git_repository_index(&index, fixture.repository);
  const git_oid *indexOid = index == nullptr ? nullptr : git_index_checksum(index);
  int headResult = git_repository_head(&head, fixture.repository);
  NSString *headOid = headResult == 0 ? DSHOidString(git_reference_target(head)) : @"unborn";
  NSData *indexBytes = [NSData dataWithContentsOfURL:
      [fixture.repositoryURL URLByAppendingPathComponent:@".git/index"]];
  NSData *metadata = [NSData dataWithContentsOfURL:
      [fixture.projectURL URLByAppendingPathComponent:@"project.json"]];
  NSData *worktree = [NSData dataWithContentsOfURL:
      [fixture.repositoryURL URLByAppendingPathComponent:@"README.md"]];
  NSDictionary *state = @{
    @"head" : headOid ?: @"none",
    @"index_oid" : indexOid == nullptr ? @"none" : DSHOidString(indexOid),
    @"index" : indexBytes ?: NSData.data,
    @"metadata" : metadata ?: NSData.data,
    @"worktree" : worktree ?: NSData.data,
  };
  if (head != nullptr) git_reference_free(head);
  if (index != nullptr) git_index_free(index);
  return state;
}

- (void)testPrepareDoesNotMutateWorktreeOrGitState {
  DSHProjectFixture *fixture = [self createProject:DSHFixtureProjectA
                                             name:@"Alpha"
                                      initialFile:@"README.md"
                                          content:@"unchanged state\n"
                                           commit:YES];
  NSDictionary *before = [self repositoryState:fixture];
  NSString *recursiveBefore = [self recursiveProjectDigest:fixture];
  NSError *error = nil;
  XCTAssertNotNil([self.service
      prepareSelection:[self selectionForFixture:fixture paths:@[@"README.md"]]
                   error:&error]);
  XCTAssertNil(error);
  XCTAssertEqualObjects([self repositoryState:fixture], before);
  XCTAssertEqualObjects([self recursiveProjectDigest:fixture], recursiveBefore);
}


// Same tuple through both implementations, for a spread of inputs. An id that
// differed would make every snapshot already on a device unfindable.
//
// This is load-bearing, and it is known to be: it was written while a core
// built with a changed derivation domain was still staged, and it failed on
// all twelve tuples. The 106 ProjectContextWorkspaceV2 round trips passed
// against that same core, because a round trip writes and reads with whatever
// derivation it has — self-consistency is not parity.
- (void)testReferenceIdMatchesTheOriginalDerivation {
  NSArray<NSString *> *workspaces = @[
    @"11111111-1111-4111-8111-111111111111",
    @"22222222-2222-4222-8222-222222222222",
  ];
  NSArray *projects = @[
    @"33333333-3333-4333-8333-333333333333",
    NSNull.null,
  ];
  NSArray<NSNumber *> *revisions = @[@1, @7, @4503599627370495];
  NSString *conversation = @"44444444-4444-4444-8444-444444444444";
  NSString *fingerprint =
      @"abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
  NSUInteger compared = 0;
  for (NSString *workspace in workspaces) {
    for (id project in projects) {
      for (NSNumber *revision in revisions) {
        NSDictionary *root = @{
          @"schema_version" : @1,
          @"workspace_id" : workspace,
          @"binding_revision" : revision,
          @"project_id" : project,
        };
        NSString *original =
            DSHOriginalReferenceId(root, fingerprint, conversation);
        NSString *core = DSHCoreReferenceId(root, fingerprint, conversation);
        XCTAssertNotNil(original, @"%@", root);
        XCTAssertEqualObjects(core, original, @"%@", root);
        compared += 1;
      }
    }
  }
  XCTAssertEqual(compared, (NSUInteger)12);
}


@end
