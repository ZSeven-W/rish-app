#import <XCTest/XCTest.h>
#import "AgentRootResolver.h"
#import "DSHGuestRuntimeState.h"
#import "DSHTestStorageFixture.h"
#import "LocalGuestModule.h"
#import "RuntimeEnvironmentStore.h"
#import "RuntimeProgramService.h"
#import "RuntimeProgramServiceVM.h"
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

// Release gate: real package verification/import, Documents-owned authority,
// interpreter boot, chroot execution and cancellation. No fake native backend.
// CI enables this explicitly and requires all six cases to pass, not skip.
static NSArray<NSString *> *LiveFamilies(void) {
  return @[@"python", @"java", @"go", @"rust", @"bun", @"node"];
}

static BOOL ExactKeys(id value, NSArray<NSString *> *keys) {
  return [value isKindOfClass:NSDictionary.class] && [value count] == keys.count &&
      [[NSSet setWithArray:[value allKeys]] isEqualToSet:[NSSet setWithArray:keys]];
}

static BOOL PositiveSize(id value) {
  return [value isKindOfClass:NSNumber.class] &&
      CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
      [value unsignedLongLongValue] > 0 && [value unsignedLongLongValue] <= 768ULL * 1024 * 1024 &&
      [value doubleValue] == (double)[value unsignedLongLongValue];
}

static BOOL SafeFilename(id value) {
  if (![value isKindOfClass:NSString.class]) return NO;
  NSRange match = [value rangeOfString:@"^[A-Za-z0-9][A-Za-z0-9._-]{0,159}\\.rishenv$"
      options:NSRegularExpressionSearch];
  return match.location == 0 && match.length == [value length];
}

static BOOL Terminal(NSDictionary *receipt) {
  return [@[@"completed", @"failed", @"cancelled"] containsObject:receipt[@"status"]];
}

@interface RuntimeEnvironmentLiveTests : XCTestCase
@property(nonatomic, strong) NSURL *fixtureRoot;
@property(nonatomic, strong) NSURL *packageDirectory;
@property(nonatomic, copy) NSDictionary<NSString *, NSDictionary *> *packages;
@property(nonatomic, strong) DSHLocalWorkspaceAccess *workspaces;
@property(nonatomic, strong) DSHAgentRootResolver *resolver;
@property(nonatomic, strong) DSHRuntimeEnvironmentStore *store;
@property(nonatomic, strong) DSHRuntimeProgramService *programs;
@property(nonatomic, copy) NSDictionary *rootRef;
@property(nonatomic, copy) NSDictionary *runLocator;
@property(nonatomic, copy) NSString *environmentId;
@property(nonatomic) BOOL importing;
@end

@implementation RuntimeEnvironmentLiveTests
- (void)setUp {
  [super setUp];
  self.continueAfterFailure = NO;
  self.executionTimeAllowance = 1900;
  NSDictionary *environment = NSProcessInfo.processInfo.environment;
  XCTSkipIf(![environment[@"RISH_RUNTIME_ENVIRONMENTS_LIVE"] isEqual:@"1"],
      @"Enable RISH_RUNTIME_ENVIRONMENTS_LIVE=1 for the real language execution gate.");
  NSString *directory = environment[@"RISH_RUNTIME_ENVIRONMENTS_FIXTURE_DIR"];
  XCTAssertTrue([directory isKindOfClass:NSString.class] && [directory hasPrefix:@"/"] &&
      ![directory containsString:@"\0"], @"Live fixture directory must be an absolute native path.");
  self.packageDirectory = [NSURL fileURLWithPath:directory isDirectory:YES];
  struct stat status = {};
  XCTAssertEqual(lstat(self.packageDirectory.fileSystemRepresentation, &status), 0);
  XCTAssertTrue(S_ISDIR(status.st_mode) && !S_ISLNK(status.st_mode));
  NSURL *manifestURL = [self.packageDirectory URLByAppendingPathComponent:@"fixture.json"];
  NSData *data = DSHEnvironmentReadSmallFile(manifestURL, 65536);
  XCTAssertNotNil(data, @"Opt-in execution requires fixture.json.");
  NSDictionary *fixture = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  XCTAssertTrue(ExactKeys(fixture, @[@"schema_version", @"packages"]));
  XCTAssertTrue([fixture[@"schema_version"] isKindOfClass:NSNumber.class] &&
      CFGetTypeID((__bridge CFTypeRef)fixture[@"schema_version"]) != CFBooleanGetTypeID() &&
      [fixture[@"schema_version"] isEqual:@1]);
  NSArray *records = fixture[@"packages"];
  XCTAssertTrue([records isKindOfClass:NSArray.class] && records.count == LiveFamilies().count,
      @"All six language records are required when the live gate is enabled.");
  NSMutableDictionary *packages = [NSMutableDictionary dictionary];
  NSMutableSet *ids = [NSMutableSet set], *files = [NSMutableSet set];
  for (NSDictionary *record in records) {
    XCTAssertTrue(ExactKeys(record, @[@"family", @"file", @"environment_id", @"package_sha256", @"package_bytes"]));
    XCTAssertTrue([LiveFamilies() containsObject:record[@"family"]]);
    XCTAssertNil(packages[record[@"family"]], @"Duplicate language fixture.");
    XCTAssertTrue(SafeFilename(record[@"file"]));
    XCTAssertTrue(DSHEnvironmentValidId(record[@"environment_id"]));
    XCTAssertTrue(PositiveSize(record[@"package_bytes"]));
    NSString *digest = record[@"package_sha256"];
    XCTAssertTrue([digest isKindOfClass:NSString.class] && digest.length == 64 &&
        [digest rangeOfString:@"^[0-9a-f]{64}$" options:NSRegularExpressionSearch].location != NSNotFound);
    XCTAssertFalse([ids containsObject:record[@"environment_id"]]);
    XCTAssertFalse([files containsObject:record[@"file"]]);
    [ids addObject:record[@"environment_id"]]; [files addObject:record[@"file"]];
    packages[record[@"family"]] = record;
  }
  XCTAssertEqualObjects([NSSet setWithArray:packages.allKeys], [NSSet setWithArray:LiveFamilies()]);
  self.packages = packages;
  NSError *error = nil;
  self.fixtureRoot = DSHCreateTestStorageFixtureRoot(@"RuntimeEnvironmentLiveTests", &error);
  XCTAssertNotNil(self.fixtureRoot, @"%@", error);
  NSURL *documents = [self.fixtureRoot URLByAppendingPathComponent:@"Documents" isDirectory:YES];
  NSURL *privateRoot = [self.fixtureRoot URLByAppendingPathComponent:@"private" isDirectory:YES];
  for (NSURL *url in @[documents, privateRoot])
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:url
        withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:&error]);
  self.workspaces = [[DSHLocalWorkspaceAccess alloc] initWithPrivateRootURL:privateRoot
      documentsRootURL:documents clock:^{ return NSDate.date; }
      UUIDGenerator:^{ return NSUUID.UUID.UUIDString.lowercaseString; }
      legacyResolver:^BOOL(NSString *projectId, NSDictionary **evidence, NSError **inner) {
        (void)projectId; (void)evidence; (void)inner; return NO;
      } faultHook:nil];
  NSDictionary *created = [self.workspaces createRishOwnedWorkspaceWithDisplayName:@"Language execution fixture"
      operationId:NSUUID.UUID.UUIDString.lowercaseString error:&error];
  XCTAssertNotNil(created, @"%@", error);
  self.rootRef = @{@"schema_version":@1, @"workspace_id":created[@"workspace_id"],
      @"binding_revision":created[@"binding_revision"], @"project_id":NSNull.null};
  self.resolver = [[DSHAgentRootResolver alloc] initWithWorkspaceAccess:self.workspaces
      projectAccess:[[DSHLocalProjectAccess alloc] initWithWorkspaceAccess:self.workspaces hook:nil]];
  self.store = [[DSHRuntimeEnvironmentStore alloc]
      initWithRootURL:[self.fixtureRoot URLByAppendingPathComponent:@"environments" isDirectory:YES]
      catalog:@{@"schema_version":@1, @"environments":@[]} kernelSHA256:DSHGuestKernelSha256];
  self.programs = [[DSHRuntimeProgramService alloc] initWithResolver:self.resolver store:self.store
      vmFactory:^{ return [[DSHRuntimeProgramVM alloc] initWithBundle:NSBundle.mainBundle]; }];
}

- (void)tearDown {
  // Never remove a disk while its VM/importer could still be using it. Failed
  // cleanup preserves only this test's private fixture and fails the gate.
  BOOL mayRemove = YES;
  if (self.runLocator != nil && self.programs != nil) {
    NSDictionary *receipt = [self.programs statusRequest:self.runLocator error:nil];
    if (!Terminal(receipt)) {
      [self.programs stopRequest:self.runLocator error:nil];
      NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 60;
      do {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        receipt = [self.programs statusRequest:self.runLocator error:nil];
      } while (!Terminal(receipt) && NSProcessInfo.processInfo.systemUptime < deadline);
      mayRemove = Terminal(receipt);
      XCTAssertTrue(mayRemove, @"Cancelled VM must settle before fixture deletion.");
    }
  }
  BOOL pending = NO;
  @synchronized (self) { pending = self.importing; }
  if (pending) {
    [self.store cancelInstall];
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 60;
    do {
      [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
      @synchronized (self) { pending = self.importing; }
    } while (pending && NSProcessInfo.processInfo.systemUptime < deadline);
    if (pending) mayRemove = NO;
    XCTAssertFalse(pending, @"Cancelled importer must settle before fixture deletion.");
  }
  if (mayRemove && self.fixtureRoot) {
    if (self.environmentId) XCTAssertTrue([self.store removeEnvironmentId:self.environmentId error:nil]);
    XCTAssertTrue([NSFileManager.defaultManager removeItemAtURL:self.fixtureRoot error:nil]);
  }
  [super tearDown];
}

- (void)installFamily:(NSString *)family {
  NSDictionary *record = self.packages[family];
  XCTAssertNotNil(record);
  NSURL *url = [self.packageDirectory URLByAppendingPathComponent:record[@"file"]];
  struct stat info = {};
  XCTAssertEqual(lstat(url.fileSystemRepresentation, &info), 0, @"Missing package for %@.", family);
  XCTAssertTrue(S_ISREG(info.st_mode) && !S_ISLNK(info.st_mode));
  XCTAssertEqual((uint64_t)info.st_size, [record[@"package_bytes"] unsignedLongLongValue]);
  XCTAssertEqualObjects(DSHEnvironmentHashFile(url, [record[@"package_bytes"] unsignedLongLongValue], nil),
      record[@"package_sha256"], @"Package bytes must match the release fixture before import.");
  XCTestExpectation *finished = [self expectationWithDescription:[@"import " stringByAppendingString:family]];
  __block NSDictionary *installed = nil;
  __block NSError *importError = nil;
  @synchronized (self) { self.importing = YES; }
  [self.store importPackageURL:url completion:^(NSDictionary *descriptor, NSError *error) {
    installed = descriptor;
    importError = error;
    @synchronized (self) { self.importing = NO; }
    [finished fulfill];
  }];
  [self waitForExpectations:@[finished] timeout:180];
  XCTAssertNil(importError, @"%@", importError); XCTAssertNotNil(installed);
  XCTAssertEqualObjects(installed[@"family"], family);
  XCTAssertEqualObjects(installed[@"state"], @"installed");
  XCTAssertEqualObjects(installed[@"environment_id"], record[@"environment_id"]);
  self.environmentId = installed[@"environment_id"];
  XCTAssertEqualObjects(DSHEnvironmentHashFile(url, [record[@"package_bytes"] unsignedLongLongValue], nil),
      record[@"package_sha256"], @"Import must not modify the downloaded package.");
}

- (void)writeSource:(NSData *)bytes entry:(NSString *)entry {
  NSError *error = nil;
  BOOL wrote = [self.workspaces performCoordinatedWorkspaceOperationForId:self.rootRef[@"workspace_id"]
      expectedBindingRevision:[self.rootRef[@"binding_revision"] unsignedIntegerValue]
      requiredCapabilities:[NSSet setWithObjects:@"read", @"write", nil]
      block:^BOOL(int root, NSError **inner) {
        (void)inner;
        int fd = openat(root, entry.fileSystemRepresentation,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (fd < 0) return NO;
        NSUInteger offset = 0;
        while (offset < bytes.length) {
          ssize_t count = write(fd, (const uint8_t *)bytes.bytes + offset, bytes.length - offset);
          if (count < 0 && errno == EINTR) continue;
          if (count <= 0) break;
          offset += (NSUInteger)count;
        }
        BOOL okay = offset == bytes.length && fsync(fd) == 0;
        if (close(fd) != 0) okay = NO;
        return okay;
      } error:&error];
  XCTAssertTrue(wrote, @"%@", error);
}

- (void)assertHostSource:(NSData *)expected entry:(NSString *)entry {
  NSError *error = nil;
  BOOL same = [self.workspaces performCoordinatedWorkspaceOperationForId:self.rootRef[@"workspace_id"]
      expectedBindingRevision:[self.rootRef[@"binding_revision"] unsignedIntegerValue]
      requiredCapabilities:[NSSet setWithObject:@"read"] block:^BOOL(int root, NSError **inner) {
        (void)inner;
        int fd = openat(root, entry.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        if (fd < 0) return NO;
        struct stat info = {};
        BOOL okay = fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_size == (off_t)expected.length;
        NSMutableData *actual = [NSMutableData dataWithLength:expected.length];
        NSUInteger offset = 0;
        while (okay && offset < actual.length) {
          ssize_t count = read(fd, (uint8_t *)actual.mutableBytes + offset, actual.length - offset);
          if (count < 0 && errno == EINTR) continue;
          if (count <= 0) { okay = NO; break; }
          offset += (NSUInteger)count;
        }
        close(fd); return okay && [actual isEqual:expected];
      } error:&error];
  XCTAssertTrue(same, @"Guest execution must preserve host source bytes: %@", error);
}

- (void)startEntry:(NSString *)entry {
  [self startEntry:entry args:@[@"6"]];
}

- (void)startEntry:(NSString *)entry args:(NSArray<NSString *> *)args {
  NSError *error = nil;
  NSDictionary *receipt = [self.programs startRequest:@{
      @"schema_version":@1, @"operation_id":NSUUID.UUID.UUIDString.lowercaseString,
      @"root":self.rootRef, @"environment_id":self.environmentId, @"entry_path":entry, @"args":args,
    } error:&error];
  XCTAssertNotNil(receipt, @"%@", error);
  self.runLocator = @{@"schema_version":@1, @"run_id":receipt[@"run_id"]};
}

- (NSDictionary *)waitForMarker:(NSString *)marker requireTerminal:(BOOL)terminal
                         family:(NSString *)family entry:(NSString *)entry {
  NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
  NSTimeInterval timeout = 200.0 + [DSHRuntimeProgramVM
      executionTimeoutMillisecondsForFamily:family entryPath:entry] / 1000.0;
  NSTimeInterval deadline = started + timeout;
  NSString *lastStatus = nil;
  NSDictionary *receipt = nil;
  do {
    receipt = [self.programs statusRequest:self.runLocator error:nil];
    if (![lastStatus isEqual:receipt[@"status"]]) {
      lastStatus = receipt[@"status"];
      NSLog(@"RISH_RUNTIME_LIVE %@ %@ after %.3fs", self.environmentId, lastStatus,
          NSProcessInfo.processInfo.systemUptime - started);
    }
    if (Terminal(receipt)) break;
    if (!terminal && [receipt[@"stdout"] containsString:marker]) return receipt;
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
  } while (NSProcessInfo.processInfo.systemUptime < deadline);
  XCTAssertTrue(Terminal(receipt), @"Program exceeded its %.0f-second boot/execution limit.", timeout);
  XCTAssertEqualObjects(receipt[@"status"], @"completed", @"%@", receipt);
  XCTAssertEqualObjects(receipt[@"exit_code"], @0, @"%@", receipt);
  XCTAssertEqualObjects(receipt[@"error_code"], NSNull.null);
  XCTAssertTrue([receipt[@"stdout"] containsString:marker], @"%@", receipt);
  return receipt;
}

- (void)runFamily:(NSString *)family entry:(NSString *)entry source:(NSString *)source marker:(NSString *)marker {
  [self installFamily:family];
  NSData *bytes = [source dataUsingEncoding:NSUTF8StringEncoding];
  [self writeSource:bytes entry:entry];
  [self startEntry:entry];
  [self waitForMarker:marker requireTerminal:YES family:family entry:entry];
  [self assertHostSource:bytes entry:entry];
}

- (void)testPythonEnvironmentExecutesAndReallyStopsInfiniteProgram {
  [self runFamily:@"python" entry:@"main.py"
      source:@"import sys\nprint('RISH_PYTHON_LIVE_OK', int(sys.argv[1])*7, flush=True)\n"
      marker:@"RISH_PYTHON_LIVE_OK 42"];
  NSData *loop = [@"print('RISH_PYTHON_READY', flush=True)\nwhile True:\n    pass\n"
      dataUsingEncoding:NSUTF8StringEncoding];
  [self writeSource:loop entry:@"stop.py"];
  [self startEntry:@"stop.py"];
  NSDictionary *ready = [self waitForMarker:@"RISH_PYTHON_READY" requireTerminal:NO
      family:@"python" entry:@"stop.py"];
  XCTAssertEqualObjects(ready[@"status"], @"running");
  NSDictionary *stop = [self.programs stopRequest:self.runLocator error:nil];
  XCTAssertEqualObjects(stop[@"status"], @"stopping");
  NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 30;
  NSDictionary *done = nil;
  do {
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    done = [self.programs statusRequest:self.runLocator error:nil];
  } while (!Terminal(done) && NSProcessInfo.processInfo.systemUptime < deadline);
  XCTAssertEqualObjects(done[@"status"], @"cancelled", @"Stop must interrupt the real interpreter: %@", done);
  XCTAssertEqualObjects(done[@"exit_code"], NSNull.null);
  DSHGuestVMOwner *owner = [DSHGuestRuntimeState.sharedState acquireGuestOwner];
  XCTAssertNotNil(owner, @"The stopped VM must have released its process-wide owner.");
  if (owner) [DSHGuestRuntimeState.sharedState releaseGuestOwner:owner];
  [self assertHostSource:loop entry:@"stop.py"];
}
- (void)testJavaEnvironmentExecutesWorkspaceSource {
  [self runFamily:@"java" entry:@"Main.java"
      source:@"class Main { public static void main(String[] a) { System.out.println(\"RISH_JAVA_LIVE_OK \" + Integer.parseInt(a[0])*7); } }\n"
      marker:@"RISH_JAVA_LIVE_OK 42"];
}
- (void)testGoEnvironmentCompilesAndExecutesWorkspaceSource {
  [self installFamily:@"go"];
  NSData *source = [@"package main\nimport (\"fmt\"; \"os\"; \"strconv\"; \"strings\")\nfunc main(){ n,e:=strconv.Atoi(strings.TrimSuffix(os.Args[1],\".go\")); if e!=nil { panic(e) }; fmt.Printf(\"RISH_GO_LIVE_OK %d\\n\",n*7) }\n"
      dataUsingEncoding:NSUTF8StringEncoding];
  [self writeSource:source entry:@"main.go"];
  // No 6.go exists. Treating this program argument as a compiler input fails.
  [self startEntry:@"main.go" args:@[@"6.go"]];
  [self waitForMarker:@"RISH_GO_LIVE_OK 42" requireTerminal:YES family:@"go" entry:@"main.go"];
  [self assertHostSource:source entry:@"main.go"];
}
- (void)testRustEnvironmentCompilesAndExecutesWorkspaceSource {
  [self runFamily:@"rust" entry:@"main.rs"
      source:@"fn main(){let n:i32=std::env::args().nth(1).unwrap().parse().unwrap(); println!(\"RISH_RUST_LIVE_OK {}\",n*7);}\n"
      marker:@"RISH_RUST_LIVE_OK 42"];
}
- (void)testBunEnvironmentExecutesWorkspaceSource {
  [self runFamily:@"bun" entry:@"main.js"
      source:@"console.log('RISH_BUN_LIVE_OK '+(Number(process.argv[2])*7));\n"
      marker:@"RISH_BUN_LIVE_OK 42"];
}
- (void)testNodeEnvironmentExecutesWorkspaceSource {
  [self runFamily:@"node" entry:@"main.js"
      source:@"console.log('RISH_NODE_LIVE_OK '+(Number(process.argv[2])*7));\n"
      marker:@"RISH_NODE_LIVE_OK 42"];
}
@end
