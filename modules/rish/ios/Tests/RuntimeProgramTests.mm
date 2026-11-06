#import <XCTest/XCTest.h>
#import "RuntimeProgramService.h"
#import "RuntimeProgramServiceVM.h"
#import "RuntimeWorkspaceSnapshot.h"
#import "RuntimeEnvironmentStore.h"
#import "AgentRootResolver.h"
#import "SessionWorkspaceCoordinator.h"
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString *const Workspace = @"11111111-1111-4111-8111-111111111111";
static NSString *const Operation = @"22222222-2222-4222-8222-222222222222";

@interface DSHProgramTestResolver : DSHAgentRootResolver
- (instancetype)init;
@property(nonatomic, strong) NSURL *directory;
@property(nonatomic) BOOL stale;
@property(nonatomic) BOOL observedCoordinator;
@property(nonatomic) NSUInteger resolutions;
@end
@implementation DSHProgramTestResolver
- (instancetype)init { return [super initWithWorkspaceAccess:(id)NSNull.null projectAccess:nil]; }
- (NSDictionary *)resolveRootForWorkspaceId:(NSString *)workspaceId projectId:(NSString *)projectId
                            bindingRevision:(NSNumber *)bindingRevision error:(NSError **)error {
  (void)error;
  self.resolutions++;
  self.observedCoordinator = DSHSessionWorkspaceCoordinator.sharedCoordinator.isExecutingOnQueue;
  return @{@"schema_version":@1, @"kind":@"workspace", @"workspace_id":workspaceId,
    @"workspace_binding_revision":bindingRevision, @"project_id":projectId ?: NSNull.null,
    @"root_fingerprint_sha256":@"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    @"capabilities":@[@"file_read", @"file_write"]};
}
- (BOOL)validateFrozenRoot:(NSDictionary *)root error:(NSError **)error {
  (void)root; (void)error; return !self.stale;
}
- (BOOL)performOperationForFrozenRoot:(NSDictionary *)root mode:(DSHAgentRootOperationMode)mode
                              timeout:(NSTimeInterval)timeout block:(DSHAgentRootOperation)block error:(NSError **)error {
  (void)root; (void)mode; (void)timeout;
  int fd = open(self.directory.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (fd < 0) return NO;
  BOOL result = block(fd, NULL, error); close(fd); return result;
}
@end

@interface DSHProgramTestLease : DSHRuntimeEnvironmentLease
@end
@implementation DSHProgramTestLease
- (NSString *)environmentId { return @"python-test"; }
- (NSDictionary *)manifest { return @{@"family":@"python", @"minimum_memory_mib":@256}; }
- (NSURL *)diskURL { return [NSURL fileURLWithPath:@"/native-only/private.ext4"]; }
@end

@interface DSHProgramTestStore : DSHRuntimeEnvironmentStore
@property(nonatomic) NSUInteger acquisitions;
@property(nonatomic) NSUInteger releases;
@property(nonatomic) BOOL coordinatorDuringLease;
@property(nonatomic, copy) dispatch_block_t onAcquire;
@end
@implementation DSHProgramTestStore
- (DSHRuntimeEnvironmentLease *)acquireLeaseForEnvironmentId:(NSString *)identifier error:(NSError **)error {
  (void)identifier; (void)error;
  self.acquisitions++;
  self.coordinatorDuringLease = DSHSessionWorkspaceCoordinator.sharedCoordinator.isExecutingOnQueue;
  if (self.onAcquire) self.onAcquire();
  return [[DSHProgramTestLease alloc] init];
}
- (void)releaseLease:(DSHRuntimeEnvironmentLease *)lease { (void)lease; self.releases++; }
@end

@interface DSHProgramTestVM : DSHRuntimeProgramVM
@property(nonatomic, strong) dispatch_semaphore_t began;
@property(nonatomic, strong) dispatch_semaphore_t finish;
@property(nonatomic) BOOL blockUntilCancelled;
@property(nonatomic) BOOL emitExcess;
@property(nonatomic) BOOL emitBinary;
@property(nonatomic) BOOL throwPrivate;
@property(nonatomic) BOOL coordinatorDuringBoot;
@property(nonatomic) NSUInteger executions;
@property(nonatomic, copy) NSArray *receivedArgs;
@end
@implementation DSHProgramTestVM
- (instancetype)init {
  self = [super initWithBundle:NSBundle.mainBundle];
  if (self) { _began = dispatch_semaphore_create(0); _finish = dispatch_semaphore_create(0); }
  return self;
}
- (void)cancel { [super cancel]; dispatch_semaphore_signal(self.finish); }
- (NSNumber *)executeLease:(DSHRuntimeEnvironmentLease *)lease snapshot:(DSHRuntimeWorkspaceSnapshot *)snapshot
                 entryPath:(NSString *)entryPath args:(NSArray<NSString *> *)args
                   started:(dispatch_block_t)started output:(DSHRuntimeProgramOutput)output error:(NSError **)error {
  (void)lease; (void)snapshot; (void)entryPath; (void)error;
  self.executions++; self.receivedArgs = args;
  self.coordinatorDuringBoot = DSHSessionWorkspaceCoordinator.sharedCoordinator.isExecutingOnQueue;
  started(); dispatch_semaphore_signal(self.began);
  if (self.throwPrivate) [NSException raise:@"private" format:@"/private/secret credential"];
  if (self.emitExcess) {
    NSMutableData *bytes = [NSMutableData dataWithLength:300000];
    memset(bytes.mutableBytes, self.emitBinary ? 0xff : 'x', bytes.length);
    output(@"stdout", bytes); output(@"stderr", bytes);
  } else {
    NSData *text = [@"你好 literal $()\n" dataUsingEncoding:NSUTF8StringEncoding];
    output(@"stdout", [text subdataWithRange:NSMakeRange(0, 1)]);
    output(@"stdout", [text subdataWithRange:NSMakeRange(1, text.length - 1)]);
  }
  if (self.blockUntilCancelled) dispatch_semaphore_wait(self.finish, DISPATCH_TIME_FOREVER);
  return self.cancelled ? nil : @7;
}
@end

@interface RuntimeProgramTests : XCTestCase
@property(nonatomic, strong) NSURL *directory;
@property(nonatomic, strong) DSHProgramTestResolver *resolver;
@property(nonatomic, strong) DSHProgramTestStore *store;
@property(nonatomic, strong) DSHProgramTestVM *vm;
@property(nonatomic, strong) DSHRuntimeProgramService *service;
@end
@implementation RuntimeProgramTests
- (void)setUp {
  [super setUp];
  self.directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:self.directory withIntermediateDirectories:NO attributes:nil error:nil]);
  XCTAssertTrue([@"print('hello')\n" writeToURL:[self.directory URLByAppendingPathComponent:@"main.py"]
      atomically:YES encoding:NSUTF8StringEncoding error:nil]);
  self.resolver = [[DSHProgramTestResolver alloc] init]; self.resolver.directory = self.directory;
  self.store = [[DSHProgramTestStore alloc] init]; self.vm = [[DSHProgramTestVM alloc] init];
  DSHProgramTestVM *vm = self.vm;
  self.service = [[DSHRuntimeProgramService alloc] initWithResolver:self.resolver store:self.store vmFactory:^{ return vm; }];
}
- (void)tearDown {
  [self.service cancelForBackground];
  [NSFileManager.defaultManager removeItemAtURL:self.directory error:nil];
  [super tearDown];
}
- (NSDictionary *)root {
  return @{@"schema_version":@1, @"workspace_id":Workspace, @"binding_revision":@1, @"project_id":NSNull.null};
}
- (NSDictionary *)request {
  return @{@"schema_version":@1, @"operation_id":Operation, @"root":[self root],
      @"environment_id":@"python-test", @"entry_path":@"main.py", @"args":@[@"", @"$(touch /tmp/nope)", @"' quoted"]};
}
- (NSDictionary *)locator:(NSDictionary *)receipt { return @{@"schema_version":@1, @"run_id":receipt[@"run_id"]}; }
- (NSDictionary *)waitForTerminal:(NSDictionary *)receipt {
  for (NSUInteger i = 0; i < 300; i++) {
    NSDictionary *state = [self.service statusRequest:[self locator:receipt] error:nil];
    if ([@[@"completed", @"failed", @"cancelled"] containsObject:state[@"status"]]) return state;
    [NSThread sleepForTimeInterval:0.01];
  }
  XCTFail(@"Program did not settle"); return nil;
}
- (void)testSnapshotUsesExactDescriptorRootAndPreservesLiteralFileBytes {
  NSString *name = @"' $(touch nope).py";
  NSData *bytes = [NSData dataWithBytes:"\0\1\2" length:3];
  XCTAssertTrue([bytes writeToURL:[self.directory URLByAppendingPathComponent:name] atomically:YES]);
  DSHRuntimeWorkspaceSnapshot *snapshot = [DSHRuntimeWorkspaceSnapshot captureRoot:[self root]
      entryPath:name resolver:self.resolver error:nil];
  XCTAssertNotNil(snapshot); XCTAssertEqual(snapshot.entries.count, 2U);
  XCTAssertTrue(self.resolver.observedCoordinator);
  XCTAssertEqualObjects(snapshot.entries.firstObject[@"path"], name);
  XCTAssertEqualObjects(snapshot.entries.firstObject[@"data"], bytes);
}
- (void)testSnapshotRejectsSymlinkAndStaleRootWithoutFollowingTarget {
  NSURL *link = [self.directory URLByAppendingPathComponent:@"link.py"];
  XCTAssertEqual(symlink("/private/secret", link.fileSystemRepresentation), 0);
  NSError *error = nil;
  XCTAssertNil([DSHRuntimeWorkspaceSnapshot captureRoot:[self root] entryPath:@"main.py" resolver:self.resolver error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_PROGRAM_UNSAFE_PATH");
  XCTAssertEqual(unlink(link.fileSystemRepresentation), 0);
  self.resolver.stale = YES;
  XCTAssertNil([DSHRuntimeWorkspaceSnapshot captureRoot:[self root] entryPath:@"main.py" resolver:self.resolver error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_PROGRAM_ROOT_STALE");
}
- (void)testSnapshotEnforcesFileSizeCountAndExcludesCaches {
  NSURL *large = [self.directory URLByAppendingPathComponent:@"large.py"];
  int fd = open(large.fileSystemRepresentation, O_CREAT | O_WRONLY, 0600);
  XCTAssertEqual(ftruncate(fd, 2 * 1024 * 1024 + 1), 0); close(fd);
  NSError *error = nil;
  XCTAssertNil([DSHRuntimeWorkspaceSnapshot captureRoot:[self root] entryPath:@"main.py" resolver:self.resolver error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_PROGRAM_SNAPSHOT_LIMIT");
  XCTAssertEqual(unlink(large.fileSystemRepresentation), 0);
  NSURL *cache = [self.directory URLByAppendingPathComponent:@"node_modules"];
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:cache withIntermediateDirectories:NO attributes:nil error:nil]);
  XCTAssertEqual(symlink("/private/secret", [cache URLByAppendingPathComponent:@"ignored"].fileSystemRepresentation), 0);
  XCTAssertNotNil([DSHRuntimeWorkspaceSnapshot captureRoot:[self root] entryPath:@"main.py" resolver:self.resolver error:nil]);
  for (NSUInteger i = 0; i < 256; i++) {
    NSString *name = [NSString stringWithFormat:@"f%lu", (unsigned long)i];
    XCTAssertTrue([NSData.data writeToURL:[self.directory URLByAppendingPathComponent:name] atomically:YES]);
  }
  XCTAssertNil([DSHRuntimeWorkspaceSnapshot captureRoot:[self root] entryPath:@"main.py" resolver:self.resolver error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_PROGRAM_SNAPSHOT_LIMIT");
}
- (void)testStartDeduplicatesAndLiteralArgsReachWorkerOutsideCoordinator {
  self.vm.blockUntilCancelled = YES;
  NSDictionary *started = [self.service startRequest:[self request] error:nil];
  XCTAssertEqualObjects(started[@"status"], @"starting");
  XCTAssertEqual(dispatch_semaphore_wait(self.vm.began, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)), 0L);
  XCTAssertEqualObjects([self.service startRequest:[self request] error:nil][@"run_id"], started[@"run_id"]);
  NSMutableDictionary *changed = [[self request] mutableCopy]; changed[@"args"] = @[];
  NSError *error = nil;
  XCTAssertNil([self.service startRequest:changed error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_PROGRAM_OPERATION_CONFLICT");
  changed[@"operation_id"] = NSUUID.UUID.UUIDString.lowercaseString;
  XCTAssertNil([self.service startRequest:changed error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_PROGRAM_BUSY");
  XCTAssertEqualObjects(self.vm.receivedArgs, [self request][@"args"]);
  XCTAssertFalse(self.vm.coordinatorDuringBoot); XCTAssertFalse(self.store.coordinatorDuringLease);
  XCTAssertEqual(self.vm.executions, 1U);
  [self.service stopRequest:[self locator:started] error:nil];
  NSDictionary *done = [self waitForTerminal:started];
  XCTAssertEqualObjects(done[@"status"], @"cancelled"); XCTAssertEqual(self.store.releases, 1U);
  XCTAssertEqualObjects(done[@"stdout"], @"你好 literal $()\n");
}
- (void)testSnapshotRejectsTotalBudgetAndHardlinkedFiles {
  NSURL *link = [self.directory URLByAppendingPathComponent:@"hard.py"];
  XCTAssertEqual(linkat(AT_FDCWD, [self.directory URLByAppendingPathComponent:@"main.py"].fileSystemRepresentation,
      AT_FDCWD, link.fileSystemRepresentation, 0), 0);
  NSError *error = nil;
  XCTAssertNil([DSHRuntimeWorkspaceSnapshot captureRoot:[self root] entryPath:@"main.py" resolver:self.resolver error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_PROGRAM_UNSAFE_PATH");
  XCTAssertEqual(unlink(link.fileSystemRepresentation), 0);
  for (NSUInteger i = 0; i < 8; i++) {
    NSString *name = [NSString stringWithFormat:@"payload%lu", (unsigned long)i];
    int fd = open([self.directory URLByAppendingPathComponent:name].fileSystemRepresentation,
        O_CREAT | O_WRONLY, 0600);
    XCTAssertEqual(ftruncate(fd, 2 * 1024 * 1024), 0); close(fd);
  }
  XCTAssertNil([DSHRuntimeWorkspaceSnapshot captureRoot:[self root] entryPath:@"main.py" resolver:self.resolver error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_PROGRAM_SNAPSHOT_LIMIT");
}
- (void)testForegroundRunCancellationDoesNotReportStoppedBeforeWorkerReturns {
  self.vm.blockUntilCancelled = YES;
  NSDictionary *started = [self.service startRequest:[self request] error:nil];
  XCTAssertEqual(dispatch_semaphore_wait(self.vm.began, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)), 0L);
  [self.service cancelForBackground];
  XCTAssertTrue(self.vm.cancelled);
  XCTAssertEqualObjects([self waitForTerminal:started][@"status"], @"cancelled");
  XCTAssertEqual(self.store.releases, 1U);
}
- (void)testOutputIsBoundedAndNonzeroProcessExitIsCompleted {
  self.vm.emitExcess = YES;
  NSDictionary *done = [self waitForTerminal:[self.service startRequest:[self request] error:nil]];
  XCTAssertEqualObjects(done[@"status"], @"completed"); XCTAssertEqualObjects(done[@"exit_code"], @7);
  XCTAssertEqual([done[@"stdout"] lengthOfBytesUsingEncoding:NSUTF8StringEncoding], 262144U);
  XCTAssertEqual([done[@"stderr"] lengthOfBytesUsingEncoding:NSUTF8StringEncoding], 262144U);
  XCTAssertEqualObjects(done[@"stdout_truncated"], @YES); XCTAssertEqualObjects(done[@"stderr_truncated"], @YES);
  XCTAssertEqualObjects(done[@"error_code"], NSNull.null);
  XCTAssertFalse([[done description] containsString:@"private.ext4"]);
}
- (void)testRootIsRevalidatedAfterSlowEnvironmentCopyBeforeBoot {
  DSHProgramTestResolver *resolver = self.resolver;
  self.store.onAcquire = ^{ resolver.stale = YES; };
  NSDictionary *done = [self waitForTerminal:[self.service startRequest:[self request] error:nil]];
  XCTAssertEqualObjects(done[@"error_code"], @"E_PROGRAM_ROOT_STALE");
  XCTAssertEqual(self.vm.executions, 0U); XCTAssertEqual(self.store.releases, 1U);
}
- (void)testInvalidUTF8OutputReplacementAlsoHonorsBridgeByteBudget {
  self.vm.emitExcess = YES; self.vm.emitBinary = YES;
  NSDictionary *done = [self waitForTerminal:[self.service startRequest:[self request] error:nil]];
  XCTAssertEqualObjects(done[@"status"], @"completed");
  XCTAssertLessThanOrEqual([done[@"stdout"] lengthOfBytesUsingEncoding:NSUTF8StringEncoding], 262144U);
  XCTAssertLessThanOrEqual([done[@"stderr"] lengthOfBytesUsingEncoding:NSUTF8StringEncoding], 262144U);
  XCTAssertEqualObjects(done[@"stdout_truncated"], @YES);
}
- (void)testNativeExceptionAndInvalidRequestsDoNotLeakPrivateDetails {
  NSMutableDictionary *bad = [[self request] mutableCopy]; bad[@"entry_path"] = @"../secret";
  NSError *error = nil;
  XCTAssertNil([self.service startRequest:bad error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_PROGRAM_INVALID_REQUEST");
  XCTAssertEqual(self.resolver.resolutions, 0U);
  self.vm.throwPrivate = YES;
  NSDictionary *done = [self waitForTerminal:[self.service startRequest:[self request] error:nil]];
  XCTAssertEqualObjects(done[@"error_code"], @"E_PROGRAM_NATIVE");
  XCTAssertFalse([[done description] containsString:@"credential"]);
  XCTAssertEqual(self.store.releases, 1U);
}
- (void)testSixFamilyCommandsKeepUserInputOutsideShellProgram {
  NSString *entry = @"a ' $(touch nope).py";
  NSArray *args = @[@"", @"; rm -rf /", @"$HOME", @"'quoted'"];
  for (NSString *family in @[@"python", @"java", @"go", @"rust", @"bun", @"node"]) {
    NSArray *command = [DSHRuntimeProgramVM commandForFamily:family entryPath:entry args:args];
    XCTAssertNotNil(command);
    XCTAssertEqualObjects(command[7], [@"/workspace/" stringByAppendingString:entry]);
    XCTAssertEqualObjects([command subarrayWithRange:NSMakeRange(8, args.count)], args);
    XCTAssertFalse([command[5] containsString:entry]);
    XCTAssertTrue([command[5] containsString:@"\"$@\""]);
    XCTAssertFalse([command[5] containsString:@"SIMDUTF_FORCE_IMPLEMENTATION"]);
  }
}
- (void)testBunCompatibilityIsBoundToAuditedDiskAndKeepsLiteralArgv {
  NSString *digest = @"099fce34488a9e225ca59c4ae60c206a180495a648b20f82ccf4ffdae5ea2271";
  NSString *entry = @"src/' $(touch nope).js";
  NSArray *args = @[@"; echo nope", @"$HOME"];
  for (NSString *family in @[@"bun", @"node", @"python", @"java", @"go", @"rust"]) {
    for (NSString *disk in @[digest, [@"0" stringByPaddingToLength:64 withString:@"0" startingAtIndex:0]]) {
      NSArray *command = [DSHRuntimeProgramVM commandForManifest:
          @{@"family":family, @"disk_sha256":disk} entryPath:entry args:args];
      XCTAssertNotNil(command);
      XCTAssertEqual([command[5] containsString:@"export SIMDUTF_FORCE_IMPLEMENTATION=westmere; "],
          [family isEqual:@"bun"] && [disk isEqual:digest]);
      XCTAssertFalse([command[5] containsString:entry]);
      XCTAssertEqualObjects(command[7], [@"/workspace/" stringByAppendingString:entry]);
      XCTAssertEqualObjects([command subarrayWithRange:NSMakeRange(8, args.count)], args);
    }
  }
  XCTAssertNil([DSHRuntimeProgramVM commandForManifest:@{} entryPath:entry args:args]);
  XCTAssertNil(([DSHRuntimeProgramVM commandForManifest:@{@"family":@"bun", @"disk_sha256":digest}
      entryPath:@"../escape.js" args:args]));
}
- (void)testLeadingDashEntryNeverBecomesAnInterpreterOption {
  for (NSString *family in @[@"python", @"java", @"go", @"rust", @"bun", @"node"]) {
    for (NSString *entry in @[@"-c", @"-p", @"-x.go", @"-x.rs"]) {
      NSArray *command = [DSHRuntimeProgramVM commandForFamily:family entryPath:entry args:@[@"literal"]];
      XCTAssertEqualObjects(command[7], [@"/workspace/" stringByAppendingString:entry]);
      XCTAssertEqualObjects(command.lastObject, @"literal");
    }
  }
}
- (void)testExecutionTimeoutExtendsOnlyCompilingLaunchersAndValidatedJavaSource {
  NSArray<NSArray *> *cases = @[
    @[@"java", @"Main.java", @1800000],
    @[@"java", @"Main.JAVA", @1800000],
    @[@"java", @"src/Main.Java", @1800000],
    @[@"java", @"main.jar", @600000],
    @[@"java", @"main.JAR", @600000],
    @[@"java", @"Main.java.jar", @600000],
    @[@"java", @"Main.class", @600000],
    @[@"java", @"Main", @600000],
    @[@"java", @"Main.java ", @600000],
    @[@"java", @"src.java/Main", @600000],
    @[@"java", @"../Main.java", @600000],
    @[@"java", @"/Main.java", @600000],
    @[@"java", @"", @600000],
    @[@"python", @"Main.java", @600000],
    @[@"node", @"Main.JAVA", @600000],
    @[@"bun", @"Main.java", @600000],
    @[@"unknown", @"Main.java", @600000],
    @[@"JAVA", @"Main.java", @600000],
    // Their launchers always compile, so the entry cannot shorten the bound.
    @[@"go", @"main.go", @1800000],
    @[@"go", @"Main.java", @1800000],
    @[@"go", @"", @1800000],
    @[@"rust", @"main.rs", @1800000],
    @[@"rust", @"Main.java", @1800000],
    @[@"GO", @"main.go", @600000],
    @[@"Rust", @"main.rs", @600000],
  ];
  for (NSArray *testCase in cases) {
    NSUInteger timeout = [DSHRuntimeProgramVM executionTimeoutMillisecondsForFamily:testCase[0]
        entryPath:testCase[1]];
    XCTAssertEqual(timeout, [testCase[2] unsignedIntegerValue], @"%@", testCase);
    XCTAssertGreaterThanOrEqual(timeout, 600000U);
    XCTAssertLessThanOrEqual(timeout, 1800000U);
  }
}
@end
