#import <XCTest/XCTest.h>
#import "DSHTestStorageFixture.h"
#import "AgentWorkspaceParent.h"
#import "AgentWorkspaceToolExecutor.h"
#import "AgentWorkspaceReadTools.h"
#import "AgentNativeWAL.h"
#import "AgentRootResolver.h"
#import "LocalWorkspaceAccess.h"

#include <fcntl.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

@interface DSHReadOnlyCreatedParent : DSHAgentWorkspaceParentCreation
@end
@implementation DSHReadOnlyCreatedParent
- (BOOL)openParentWithError:(NSError **)error {
  if (![super openParentWithError:error]) return NO;
  int parent = [self duplicateParentDescriptor];
  BOOL changed = parent >= 0 && fchmod(parent, 0500) == 0;
  if (parent >= 0) close(parent);
  return changed;
}
@end

@interface DSHParentWriteFailureExecutor : DSHAgentWorkspaceToolExecutor
@end
@implementation DSHParentWriteFailureExecutor
- (DSHAgentWorkspaceParentCreation *)parentCreationForRoot:(int)rootDescriptor
                                               components:(NSArray<NSString *> *)components
                                                     plan:(NSDictionary *)plan {
  return [[DSHReadOnlyCreatedParent alloc] initWithRootDescriptor:rootDescriptor
      components:components plan:plan];
}
@end

// Produce only the current entry; a million-entry case never allocates or
// scans a million names. The executor's descriptor loop must stop itself.
@interface DSHSyntheticDirectoryExecutor : DSHAgentWorkspaceToolExecutor {
  struct dirent _entry;
}
@property(nonatomic) NSUInteger entryCount;
@property(nonatomic) NSUInteger readCalls;
@property(nonatomic) NSUInteger statCalls;
@property(nonatomic) NSUInteger unnamedIndex;
@property(nonatomic) BOOL hiddenFirst;
@property(nonatomic) int statError;
@property(nonatomic) int successfulStatErrno;
@property(nonatomic) int endReadError;
@end
@implementation DSHSyntheticDirectoryExecutor
- (instancetype)initWithRootResolver:(DSHAgentRootResolver *)resolver {
  self = [super initWithRootResolver:resolver];
  if (self) _unnamedIndex = NSNotFound;
  return self;
}
- (struct dirent *)nextEntryInDirectory:(__unused DIR *)directory {
  NSUInteger index = self.readCalls++;
  memset(&_entry, 0, sizeof(_entry));
  if (self.hiddenFirst && index == 0) {
    strlcpy(_entry.d_name, ".staging-disappeared", sizeof(_entry.d_name));
    return &_entry;
  }
  if (self.hiddenFirst) index--;
  if (index >= self.entryCount) {
    if (self.endReadError != 0) errno = self.endReadError;
    return nullptr;
  }
  if (index == self.unnamedIndex) {
    _entry.d_name[0] = (char)0xff;
  } else {
    snprintf(_entry.d_name, sizeof(_entry.d_name), "f%08lu", (unsigned long)index);
  }
  return &_entry;
}
- (int)statEntryNamed:(__unused const char *)name
           directory:(__unused int)descriptor
            metadata:(struct stat *)metadata {
  self.statCalls++;
  if (self.statError != 0) { errno = self.statError; return -1; }
  memset(metadata, 0, sizeof(*metadata));
  metadata->st_mode = S_IFREG | 0600;
  metadata->st_nlink = 1;
  metadata->st_dev = 1;
  metadata->st_ino = self.readCalls;
  metadata->st_mtimespec.tv_sec = 1;
  errno = self.successfulStatErrno;
  return 0;
}
@end

@interface AgentWorkspaceParentTests : XCTestCase
@property(nonatomic, strong) NSURL *fixture;
@property(nonatomic, strong) NSURL *workspaceURL;
@property(nonatomic, strong) DSHLocalWorkspaceAccess *access;
@property(nonatomic, strong) DSHAgentRootResolver *resolver;
@property(nonatomic, strong) DSHAgentWorkspaceToolExecutor *executor;
@property(nonatomic, copy) NSDictionary *root;
@end

@implementation AgentWorkspaceParentTests
- (void)setUp {
  [super setUp];
  NSError *error = nil;
  self.fixture = DSHCreateTestStorageFixtureRoot(@"agent-parent-write", &error);
  XCTAssertNotNil(self.fixture, @"%@", error);
  NSURL *documents = [self.fixture URLByAppendingPathComponent:@"Documents"];
  NSURL *privateRoot = [self.fixture URLByAppendingPathComponent:@"Private"];
  for (NSURL *url in @[documents, privateRoot]) {
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:url
        withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:&error], @"%@", error);
  }
  self.access = [[DSHLocalWorkspaceAccess alloc] initWithPrivateRootURL:privateRoot
      documentsRootURL:documents clock:^NSDate *{ return NSDate.date; }
      UUIDGenerator:^NSString *{ return @"11111111-1111-4111-8111-111111111111"; }
      legacyResolver:^BOOL(__unused NSString *project, __unused NSDictionary **evidence,
                            __unused NSError **failure) { return NO; } faultHook:nil];
  XCTAssertTrue([self.access ensurePrivateLayoutWithError:&error], @"%@", error);
  NSDictionary *workspace = [self.access createRishOwnedWorkspaceWithDisplayName:@"Parent Writes"
      operationId:@"22222222-2222-4222-8222-222222222222" error:&error];
  XCTAssertNotNil(workspace, @"%@", error);
  self.workspaceURL = [[documents URLByAppendingPathComponent:@"Rish Workspaces"]
      URLByAppendingPathComponent:@"Parent Writes"];
  self.resolver = [[DSHAgentRootResolver alloc] initWithWorkspaceAccess:self.access projectAccess:nil];
  self.root = [self.resolver resolveRootForWorkspaceId:workspace[@"workspace_id"]
      projectId:nil bindingRevision:workspace[@"binding_revision"] error:&error];
  XCTAssertNotNil(self.root, @"%@", error);
  self.executor = [[DSHAgentWorkspaceToolExecutor alloc] initWithRootResolver:self.resolver];
}
- (void)tearDown {
  self.executor = nil; self.resolver = nil; self.access = nil;
  if (self.fixture != nil) [NSFileManager.defaultManager removeItemAtURL:self.fixture error:nil];
  [super tearDown];
}
- (NSURL *)path:(NSString *)path { return [self.workspaceURL URLByAppendingPathComponent:path]; }
- (NSDictionary *)arguments:(NSString *)path {
  return @{@"path": path, @"content": @"export default '目录写入';\n"};
}
- (NSDictionary *)prepare:(NSString *)path {
  NSError *error = nil;
  NSDictionary *prepared = [self.executor prepareToolNamed:@"write_file"
      arguments:[self arguments:path] root:self.root error:&error];
  XCTAssertNotNil(prepared, @"%@", error); XCTAssertNil(error);
  return prepared;
}
- (NSDictionary *)execute:(NSString *)path prepared:(NSDictionary *)prepared {
  NSError *error = nil;
  NSDictionary *result = [self.executor executeToolNamed:@"write_file" arguments:[self arguments:path]
      root:self.root precondition:prepared[@"precondition"] error:&error];
  XCTAssertNotNil(result, @"%@", error); XCTAssertNil(error);
  return result;
}
- (NSDictionary *)recover:(NSString *)path prepared:(NSDictionary *)prepared {
  NSError *error = nil;
  NSDictionary *result = [self.executor recoverToolNamed:@"write_file" arguments:[self arguments:path]
      root:self.root precondition:prepared[@"precondition"] error:&error];
  XCTAssertNotNil(result, @"%@", error); XCTAssertNil(error);
  return result;
}
- (void)testPrepareIsReadOnlyAndApprovedWriteCreatesNestedParents {
  NSString *path = @"src/routes/index.js";
  NSDictionary *prepared = [self prepare:path];
  XCTAssertEqualObjects(prepared[@"precondition"][@"schema_version"], @3);
  XCTAssertEqualObjects(prepared[@"precondition"][@"parent_plan"][@"ancestor_depth"], @0);
  XCTAssertEqual([prepared[@"precondition"][@"parent_plan"][@"missing_parent_path_sha256"] count], 2U);
  XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[self path:@"src"].path]);
  XCTAssertEqualObjects([self recover:path prepared:prepared][@"status"], @"not_dispatched");
  XCTAssertEqualObjects([self execute:path prepared:prepared][@"status"], @"ok");
  XCTAssertEqualObjects([NSString stringWithContentsOfURL:[self path:path]
      encoding:NSUTF8StringEncoding error:nil], [self arguments:path][@"content"]);
  XCTAssertEqualObjects([self recover:path prepared:prepared][@"status"], @"settled");
}
- (void)testTwoPreparedWritesCanShareMissingParents {
  NSDictionary *first = [self prepare:@"src/routes/a.js"];
  NSDictionary *second = [self prepare:@"src/routes/b.js"];
  XCTAssertEqualObjects(first[@"precondition"][@"parent_plan"], second[@"precondition"][@"parent_plan"]);
  XCTAssertEqualObjects([self execute:@"src/routes/a.js" prepared:first][@"status"], @"ok");
  XCTAssertEqualObjects([self execute:@"src/routes/b.js" prepared:second][@"status"], @"ok");
  XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:[self path:@"src/routes/a.js"].path]);
}
- (void)testSymlinkAfterPreparationCannotEscapeOrCreateOutsideRoot {
  NSDictionary *prepared = [self prepare:@"src/routes/a.js"];
  NSURL *outside = [self.fixture URLByAppendingPathComponent:@"outside"];
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:outside
      withIntermediateDirectories:NO attributes:nil error:nil]);
  XCTAssertEqual(symlink(outside.fileSystemRepresentation, [self path:@"src"].fileSystemRepresentation), 0);
  XCTAssertEqualObjects([self execute:@"src/routes/a.js" prepared:prepared][@"status"], @"failed");
  XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:
      [outside URLByAppendingPathComponent:@"routes"].path]);
  XCTAssertEqualObjects([self recover:@"src/routes/a.js" prepared:prepared][@"status"], @"ambiguous");
  NSError *error = nil;
  XCTAssertNil([self.executor prepareToolNamed:@"write_file" arguments:[self arguments:@"src/other.js"]
      root:self.root error:&error]);
  XCTAssertNotNil(error);
}
- (void)testReplacedExistingAncestorRejectsPlanWithoutCreatingDirectories {
  XCTAssertEqual(mkdir([self path:@"src"].fileSystemRepresentation, 0700), 0);
  NSDictionary *prepared = [self prepare:@"src/routes/a.js"];
  XCTAssertEqualObjects(prepared[@"precondition"][@"parent_plan"][@"ancestor_depth"], @1);
  XCTAssertEqual(rename([self path:@"src"].fileSystemRepresentation,
      [self path:@"src-old"].fileSystemRepresentation), 0);
  XCTAssertEqual(mkdir([self path:@"src"].fileSystemRepresentation, 0700), 0);
  XCTAssertEqualObjects([self execute:@"src/routes/a.js" prepared:prepared][@"status"], @"failed");
  XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[self path:@"src/routes"].path]);
  XCTAssertEqualObjects([self recover:@"src/routes/a.js" prepared:prepared][@"status"], @"ambiguous");
}
- (void)testSchema2DoesNotRecreateAParentRemovedAfterPreparation {
  XCTAssertEqual(mkdir([self path:@"src"].fileSystemRepresentation, 0700), 0);
  NSDictionary *prepared = [self prepare:@"src/a.js"];
  XCTAssertEqualObjects(prepared[@"precondition"][@"schema_version"], @2);
  XCTAssertEqual(rmdir([self path:@"src"].fileSystemRepresentation), 0);
  NSError *error = nil;
  XCTAssertNil([self.executor executeToolNamed:@"write_file" arguments:[self arguments:@"src/a.js"]
      root:self.root precondition:prepared[@"precondition"] error:&error]);
  XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[self path:@"src"].path]);
}
- (DSHAgentWorkspaceParentCreation *)createParents:(NSString *)path prepared:(NSDictionary *)prepared {
  int root = open(self.workspaceURL.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
  XCTAssertGreaterThanOrEqual(root, 0);
  DSHAgentWorkspaceParentCreation *creation = [[DSHAgentWorkspaceParentCreation alloc]
      initWithRootDescriptor:root components:[path componentsSeparatedByString:@"/"]
      plan:prepared[@"precondition"][@"parent_plan"]];
  close(root);
  NSError *error = nil;
  XCTAssertTrue([creation openParentWithError:&error], @"%@", error);
  return creation;
}
- (void)testCrashAfterMkdirWithoutFileRemainsAmbiguousAndRecoveryIsReadOnly {
  NSString *path = @"src/routes/a.js";
  NSDictionary *prepared = [self prepare:path];
  // Dropping descriptor ownership without cleanup models termination between
  // directory creation and file installation. Recovery may not erase it.
  DSHAgentWorkspaceParentCreation *creation = [self createParents:path prepared:prepared];
  creation = nil;
  XCTAssertNil(creation);
  XCTAssertEqualObjects([self recover:path prepared:prepared][@"status"], @"ambiguous");
  XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:[self path:@"src/routes"].path]);
  XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[self path:path].path]);
}
- (void)testCleanupRemovesOnlyOwnedEmptyDirectoriesAndPreservesExistingParent {
  XCTAssertEqual(mkdir([self path:@"src"].fileSystemRepresentation, 0700), 0);
  NSDictionary *prepared = [self prepare:@"src/routes/deep/a.js"];
  DSHAgentWorkspaceParentCreation *creation = [self createParents:@"src/routes/deep/a.js" prepared:prepared];
  XCTAssertTrue([creation removeCreatedDirectoriesWithError:nil]);
  XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[self path:@"src/routes"].path]);
  XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:[self path:@"src"].path]);
}
- (void)testWriteFailureCleansTheDirectoriesItCreated {
  NSDictionary *prepared = [self prepare:@"src/routes/a.js"];
  // Actual filesystem permissions reject the file creation after mkdir.
  // Preparation, ownership, file I/O, and rollback still use production code.
  self.executor = [[DSHParentWriteFailureExecutor alloc] initWithRootResolver:self.resolver];
  NSDictionary *result = [self execute:@"src/routes/a.js" prepared:prepared];
  XCTAssertEqualObjects(result[@"status"], @"failed");
  XCTAssertEqualObjects(result[@"effect_may_have_occurred"], @NO);
  XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[self path:@"src"].path]);
}
- (void)testTamperedParentPlanCannotCreateDirectories {
  NSDictionary *prepared = [self prepare:@"src/routes/a.js"];
  NSMutableDictionary *condition = [prepared[@"precondition"] mutableCopy];
  NSMutableDictionary *plan = [condition[@"parent_plan"] mutableCopy];
  plan[@"missing_parent_path_sha256"] = @[
    @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    @"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  ];
  condition[@"parent_plan"] = plan;
  NSError *error = nil;
  XCTAssertNil([self.executor executeToolNamed:@"write_file" arguments:[self arguments:@"src/routes/a.js"]
      root:self.root precondition:condition error:&error]);
  XCTAssertNotNil(error);
  XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[self path:@"src"].path]);
}
- (void)testCleanupPreservesNonEmptyOrReplacedDirectories {
  NSDictionary *prepared = [self prepare:@"src/routes/a.js"];
  DSHAgentWorkspaceParentCreation *creation = [self createParents:@"src/routes/a.js" prepared:prepared];
  NSData *foreign = [@"other writer" dataUsingEncoding:NSUTF8StringEncoding];
  XCTAssertTrue([foreign writeToURL:[self path:@"src/routes/keep.txt"] atomically:YES]);
  XCTAssertFalse([creation removeCreatedDirectoriesWithError:nil]);
  XCTAssertEqualObjects([NSData dataWithContentsOfURL:[self path:@"src/routes/keep.txt"]], foreign);

  NSDictionary *other = [self prepare:@"other/deep/a.js"];
  DSHAgentWorkspaceParentCreation *replaced = [self createParents:@"other/deep/a.js" prepared:other];
  XCTAssertEqual(rename([self path:@"other"].fileSystemRepresentation,
      [self path:@"other-old"].fileSystemRepresentation), 0);
  XCTAssertEqual(mkdir([self path:@"other"].fileSystemRepresentation, 0700), 0);
  XCTAssertFalse([replaced removeCreatedDirectoriesWithError:nil]);
  XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:[self path:@"other"].path]);
}
- (void)testExistingFileCompareAndSwapIsUnchanged {
  NSURL *file = [self path:@"existing.js"];
  XCTAssertTrue([@"original" writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:nil]);
  NSError *error = nil;
  NSDictionary *read = [self.executor prepareToolNamed:@"read_file" arguments:@{@"path": @"existing.js"}
      root:self.root error:&error];
  NSDictionary *args = @{@"path": @"existing.js", @"content": @"replacement",
      @"expected_revision": read[@"precondition"][@"source_revision"]};
  NSDictionary *prepared = [self.executor prepareToolNamed:@"write_file" arguments:args root:self.root error:&error];
  XCTAssertEqualObjects(prepared[@"precondition"][@"schema_version"], @2);
  XCTAssertTrue([@"changed by another writer" writeToURL:file atomically:YES
      encoding:NSUTF8StringEncoding error:nil]);
  NSDictionary *result = [self.executor executeToolNamed:@"write_file" arguments:args
      root:self.root precondition:prepared[@"precondition"] error:&error];
  XCTAssertEqualObjects(result[@"status"], @"failed");
  XCTAssertEqualObjects([NSString stringWithContentsOfURL:file encoding:NSUTF8StringEncoding error:nil],
      @"changed by another writer");
}
- (DSHSyntheticDirectoryExecutor *)syntheticDirectory {
  return [[DSHSyntheticDirectoryExecutor alloc] initWithRootResolver:self.resolver];
}
- (BOOL)listSyntheticDirectory:(DSHSyntheticDirectoryExecutor *)executor
                         error:(NSError **)error {
  int descriptor = open(self.workspaceURL.fileSystemRepresentation, O_RDONLY | O_DIRECTORY);
  XCTAssertGreaterThanOrEqual(descriptor, 0);
  if (descriptor < 0) return NO;
  NSArray *entries = nil;
  NSString *fingerprint = nil;
  BOOL listed = [executor entryListForDirectoryDescriptor:descriptor
      entries:&entries fingerprint:&fingerprint error:error];
  close(descriptor);
  if (listed) {
    XCTAssertEqual(entries.count, executor.entryCount);
    XCTAssertEqual(fingerprint.length, 64U);
  }
  return listed;
}
- (void)testDirectoryListingStopsAtTheFirstEntryBeyondCapacityBeforeStat {
  DSHSyntheticDirectoryExecutor *executor = [self syntheticDirectory];
  executor.entryCount = 1000000;
  NSError *error = nil;
  XCTAssertFalse([self listSyntheticDirectory:executor error:&error]);
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorCapacity);
  XCTAssertEqual(executor.readCalls, 1001U);
  XCTAssertEqual(executor.statCalls, 1000U);
}
- (void)testDirectoryStatFailureIsImmediateConflictRatherThanTrailingErrno {
  DSHSyntheticDirectoryExecutor *executor = [self syntheticDirectory];
  executor.entryCount = 1000000;
  executor.statError = ENOENT;
  NSError *error = nil;
  XCTAssertFalse([self listSyntheticDirectory:executor error:&error]);
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorConflict);
  XCTAssertEqual(executor.readCalls, 1U);
  XCTAssertEqual(executor.statCalls, 1U);
}
- (void)testDisappearingHiddenDirectoryEntryIsNeverStatted {
  DSHSyntheticDirectoryExecutor *executor = [self syntheticDirectory];
  executor.hiddenFirst = YES;
  executor.statError = ENOENT;
  NSError *error = nil;
  XCTAssertTrue([self listSyntheticDirectory:executor error:&error], @"%@", error);
  XCTAssertNil(error);
  XCTAssertEqual(executor.readCalls, 2U);
  XCTAssertEqual(executor.statCalls, 0U);
}
- (void)testDirectoryEOFDoesNotInheritErrnoFromAnEarlierSuccessfulCall {
  DSHSyntheticDirectoryExecutor *executor = [self syntheticDirectory];
  executor.entryCount = 1;
  executor.successfulStatErrno = EACCES;
  NSError *error = nil;
  XCTAssertTrue([self listSyntheticDirectory:executor error:&error], @"%@", error);
  XCTAssertNil(error);
  XCTAssertEqual(executor.readCalls, 2U);
  XCTAssertEqual(executor.statCalls, 1U);
}
- (void)testActualDirectoryReadErrorStillReportsUnavailable {
  DSHSyntheticDirectoryExecutor *executor = [self syntheticDirectory];
  executor.endReadError = EIO;
  NSError *error = nil;
  XCTAssertFalse([self listSyntheticDirectory:executor error:&error]);
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorUnavailable);
  XCTAssertEqual(executor.readCalls, 1U);
  XCTAssertEqual(executor.statCalls, 0U);
}
- (void)testUndecodableDirectoryNamePrecedesCapacityWithoutStat {
  DSHSyntheticDirectoryExecutor *executor = [self syntheticDirectory];
  executor.entryCount = 1001;
  executor.unnamedIndex = 1000;
  NSError *error = nil;
  XCTAssertFalse([self listSyntheticDirectory:executor error:&error]);
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorInvalidArgument);
  XCTAssertEqual(executor.readCalls, 1001U);
  XCTAssertEqual(executor.statCalls, 1000U);
}
- (void)testWorkspacePathsRejectControlAndFormatScalarsThroughSharedCore {
  for (NSNumber *value in @[@0x00ad, @0x200b, @0x202e, @0xfeff, @0x110bd, @0xe0001, @0xe0020]) {
    uint32_t scalar = value.unsignedIntValue;
    NSString *character = [[NSString alloc] initWithBytes:&scalar length:sizeof(scalar)
        encoding:NSUTF32LittleEndianStringEncoding];
    XCTAssertNotEqual([character rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location,
        NSNotFound, @"U+%X", scalar);
    XCTAssertNil(DSHAgentWorkspacePathComponents([NSString stringWithFormat:@"src/a%@b.txt", character], NO));
  }
  XCTAssertNotNil(DSHAgentWorkspacePathComponents(@"src/中文😀.txt", NO));
}
@end
