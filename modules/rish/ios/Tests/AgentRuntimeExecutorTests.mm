#import "AgentRuntimeExecutorTestSupport.h"
#import "DSHGuestRuntimeState.h"
#import "AgentToolRegistry.h"
#import "DSHAgentRuntimeToolInternals.h"
#include <fcntl.h>
#include <unistd.h>

@interface ARFailedServiceVM : DSHRuntimeServiceVM
@property(nonatomic, strong) NSError *startupError;
@end
@implementation ARFailedServiceVM
- (NSNumber *)serveLease:(DSHRuntimeEnvironmentLease *)lease snapshot:(DSHRuntimeWorkspaceSnapshot *)snapshot
                entryPath:(NSString *)entryPath args:(NSArray<NSString *> *)args guestPort:(NSUInteger)port
                    ready:(DSHRuntimeServiceReady)ready output:(DSHRuntimeProgramOutput)output error:(NSError **)error {
  (void)lease; (void)snapshot; (void)entryPath; (void)args; (void)port; (void)ready; (void)output;
  if (error) *error = self.startupError;
  return nil;
}
@end

@implementation ARTestResolver
- (instancetype)init { return [super initWithWorkspaceAccess:(id)NSNull.null projectAccess:nil]; }
- (NSDictionary *)resolveRootForWorkspaceId:(NSString *)workspaceId projectId:(NSString *)projectId
                            bindingRevision:(NSNumber *)revision error:(NSError **)error {
  (void)workspaceId; (void)projectId; (void)revision; (void)error; return self.root;
}
- (BOOL)validateFrozenRoot:(NSDictionary *)root error:(NSError **)error { (void)error; return [root isEqual:self.root]; }
- (BOOL)performOperationForFrozenRoot:(NSDictionary *)root mode:(DSHAgentRootOperationMode)mode
                              timeout:(NSTimeInterval)timeout block:(DSHAgentRootOperation)block error:(NSError **)error {
  (void)mode; (void)timeout;
  if (![self validateFrozenRoot:root error:error]) return NO;
  int fd = open(self.directory.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
  if (fd < 0) return NO; BOOL okay = block(fd, NULL, error); close(fd); return okay;
}
@end
@implementation ARTestLease
- (NSDictionary *)manifest { return self.testManifest; }
- (NSString *)environmentId { return self.testManifest[@"environment_id"]; }
@end
@implementation ARTestStore
- (NSDictionary *)listEnvironmentsForWorkspaceId:(NSString *)workspaceId error:(NSError **)error {
  (void)workspaceId; (void)error;
  return @{@"environments":@[@{@"environment_id":@"node-test", @"family":@"node", @"version":@"1",
      @"state":self.installed ? @"installed" : @"not_installed", @"total_bytes":@100}]};
}
- (NSDictionary *)manifestForEnvironmentId:(NSString *)identifier { return [identifier isEqual:@"node-test"] ? self.manifest : nil; }
- (NSDictionary *)catalogManifestForEnvironmentId:(NSString *)identifier { return [self manifestForEnvironmentId:identifier]; }
- (NSString *)beginInstallEnvironmentId:(NSString *)identifier completion:(DSHEnvironmentCompletion)completion {
  (void)identifier; self.installs++;
  if (self.cancelledBySettings) { completion(nil, DSHEnvironmentError(@"E_ENV_CANCELLED")); return nil; }
  if (self.pendingToken) { completion(nil, DSHEnvironmentError(@"E_ENV_BUSY")); return nil; }
  self.installed = YES; completion(@{@"environment_id":@"node-test", @"state":@"installed"}, nil); return nil;
}
- (BOOL)cancelInstallToken:(NSString *)token {
  if (![token isEqual:self.pendingToken]) return NO;
  self.pendingToken = nil; if (self.pendingCompletion) self.pendingCompletion(nil, DSHEnvironmentError(@"E_ENV_CANCELLED")); return YES;
}
- (DSHRuntimeEnvironmentLease *)acquireLeaseForEnvironmentId:(NSString *)identifier error:(NSError **)error {
  if (!self.installed || self.leases) { if (error) *error = DSHEnvironmentError(@"E_ENV_IN_USE"); return nil; }
  ARTestLease *lease = [[ARTestLease alloc] init]; lease.testManifest = [self manifestForEnvironmentId:identifier]; self.leases++; return lease;
}
- (void)releaseLease:(DSHRuntimeEnvironmentLease *)lease { (void)lease; self.releases++; self.leases--; }
- (BOOL)removeEnvironmentId:(NSString *)identifier error:(NSError **)error {
  (void)identifier;
  if (self.leases) { if (error) *error = DSHEnvironmentError(@"E_ENV_IN_USE"); return NO; }
  self.installed = NO; return YES;
}
@end
@implementation ARTestVM
- (instancetype)init {
  self = [super initWithBundle:NSBundle.mainBundle];
  if (self) { _began = dispatch_semaphore_create(0); _ended = dispatch_semaphore_create(0); }
  return self;
}
- (void)cancel { [super cancel]; dispatch_semaphore_signal(self.ended); }
- (NSNumber *)executeLease:(DSHRuntimeEnvironmentLease *)lease snapshot:(DSHRuntimeWorkspaceSnapshot *)snapshot
                 entryPath:(NSString *)entryPath args:(NSArray<NSString *> *)args started:(dispatch_block_t)started
                    output:(DSHRuntimeProgramOutput)output error:(NSError **)error {
  (void)lease; (void)snapshot; (void)entryPath; (void)args; (void)error;
  self.starts++; self.executedOnCoordinator = DSHSessionWorkspaceCoordinator.sharedCoordinator.isExecutingOnQueue;
  started(); dispatch_semaphore_signal(self.began);
  output(@"stdout", self.testOutput ?: [@"actual program output\n" dataUsingEncoding:NSUTF8StringEncoding]);
  output(@"stderr", self.testOutput ?: [@"compiler diagnostic\n" dataUsingEncoding:NSUTF8StringEncoding]);
  if (self.hold) dispatch_semaphore_wait(self.ended, DISPATCH_TIME_FOREVER);
  return self.cancelled ? nil : @(self.exitStatus);
}
@end
@implementation ARTestServiceVM
- (instancetype)init { self = [super initWithBundle:NSBundle.mainBundle];
  if (self) { _ended = dispatch_semaphore_create(0); _began = dispatch_semaphore_create(0); } return self; }
- (void)cancel { [super cancel]; dispatch_semaphore_signal(self.ended); }
- (NSNumber *)serveLease:(DSHRuntimeEnvironmentLease *)lease snapshot:(DSHRuntimeWorkspaceSnapshot *)snapshot
                entryPath:(NSString *)entryPath args:(NSArray<NSString *> *)args guestPort:(NSUInteger)port
                    ready:(DSHRuntimeServiceReady)ready output:(DSHRuntimeProgramOutput)output error:(NSError **)error {
  (void)lease; (void)snapshot; (void)entryPath; (void)args; (void)port; (void)output; (void)error;
  DSHGuestVMOwner *owner = [DSHGuestRuntimeState.sharedState acquireGuestOwner];
  if (!owner) return nil;
  self.starts++; [DSHGuestRuntimeState.sharedState setGuestRuntimeMounted:YES owner:owner];
  dispatch_semaphore_signal(self.began);
  if (!self.holdBeforeReady) ready([@"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK" dataUsingEncoding:NSUTF8StringEncoding]);
  dispatch_semaphore_wait(self.ended, DISPATCH_TIME_FOREVER);
  [DSHGuestRuntimeState.sharedState releaseGuestOwner:owner]; return nil;
}
@end

@implementation AgentRuntimeExecutorTests
- (void)setUp {
  [super setUp];
  self.directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
  [NSFileManager.defaultManager createDirectoryAtURL:self.directory withIntermediateDirectories:YES attributes:nil error:nil];
  [@"console.log(42)" writeToURL:[self.directory URLByAppendingPathComponent:@"main.js"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
  self.resolver = [[ARTestResolver alloc] init]; self.resolver.directory = self.directory;
  self.resolver.root = @{@"schema_version":@1,@"kind":@"workspace",
      @"workspace_id":@"11111111-1111-4111-8111-111111111111",@"workspace_binding_revision":@1,@"project_id":NSNull.null,
      @"root_fingerprint_sha256":@"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      @"capabilities":@[@"file_read",@"file_write",@"guest_service"]};
  self.store = [[ARTestStore alloc] init]; self.store.installed = YES;
  self.store.manifest = @{@"environment_id":@"node-test",@"family":@"node",@"version":@"1",
      @"disk_sha256":@"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"};
  self.workspace = [[DSHAgentWorkspaceToolExecutor alloc] initWithRootResolver:self.resolver];
  self.executor = [[DSHAgentRuntimeToolExecutor alloc] initWithResolver:self.resolver store:self.store];
  self.vm = [[ARTestVM alloc] init]; ARTestVM *vm = self.vm;
  self.executor.programFactory = ^{ return vm; };
}
- (void)tearDown {
  [self.vm cancel];
  [NSFileManager.defaultManager removeItemAtURL:self.directory error:nil]; [super tearDown];
}
- (NSDictionary *)owner:(NSString *)name arguments:(NSDictionary *)arguments attempt:(NSString *)attempt {
  NSData *json = DSHAgentCanonicalJSON(arguments, nil);
  return @{@"schema_version":@2, @"operation_id":NSUUID.UUID.UUIDString.lowercaseString,
      @"task_id":@"22222222-2222-4222-8222-222222222222", @"conversation_id":@"33333333-3333-4333-8333-333333333333",
      @"attempt_id":attempt, @"round_id":@"44444444-4444-4444-8444-444444444444", @"round_index":@0,
      @"call_index":@0, @"call_id":name, @"name":name, @"root":self.resolver.root,
      @"idempotency_key":@"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      @"arguments_sha256":DSHAgentArgumentsSHA256(name, [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding], nil)};
}
- (NSDictionary *)condition:(NSString *)name arguments:(NSDictionary *)arguments {
  NSDictionary *prepared = [self.executor prepareToolNamed:name arguments:arguments root:self.resolver.root];
  XCTAssertNotNil(prepared[@"precondition"], @"%@", prepared); return prepared[@"precondition"];
}
- (NSDictionary *)invoke:(NSString *)name arguments:(NSDictionary *)arguments owner:(NSDictionary *)owner {
  NSDictionary *condition = [self condition:name arguments:arguments];
  XCTAssertTrue([self.executor registerToolNamed:name arguments:arguments root:self.resolver.root owner:owner
      precondition:condition validator:^BOOL(BOOL required) { (void)required; return YES; }]);
  return [self.executor executeToolNamed:name arguments:arguments root:self.resolver.root owner:owner precondition:condition];
}
- (NSDictionary *)feedback:(NSDictionary *)effect {
  return [NSJSONSerialization JSONObjectWithData:[effect[@"feedback"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
}
- (void)testMissingPackageIsRepairableAndListingReflectsInstalledState {
  self.store.installed = NO;
  NSDictionary *args = @{@"environment_id":@"node-test",@"entry_path":@"main.js",@"args":@[]};
  NSDictionary *prepared = [self.executor prepareToolNamed:@"run_program" arguments:args root:self.resolver.root];
  XCTAssertEqualObjects(prepared[@"rejection"][@"reason"], @"environment_not_installed");
  XCTAssertEqual(self.store.installs, 0U); XCTAssertEqual(self.vm.starts, 0U);
  NSDictionary *owner = [self owner:@"list_runtime_environments" arguments:@{} attempt:NSUUID.UUID.UUIDString.lowercaseString];
  NSDictionary *effect = [self invoke:@"list_runtime_environments" arguments:@{} owner:owner];
  NSDictionary *item = [self feedback:effect][@"payload"][@"environments"][0];
  XCTAssertEqualObjects(item[@"installed"], @NO); XCTAssertEqualObjects(item[@"available"], @YES);
}
- (void)testSnapshotAndEnvironmentChangesCannotExecuteAndFailuresKeepDiagnostics {
  NSDictionary *args = @{@"environment_id":@"node-test",@"entry_path":@"main.js",@"args":@[]};
  NSDictionary *owner = [self owner:@"run_program" arguments:args attempt:NSUUID.UUID.UUIDString.lowercaseString];
  NSDictionary *condition = [self condition:@"run_program" arguments:args];
  [self.executor registerToolNamed:@"run_program" arguments:args root:self.resolver.root owner:owner precondition:condition validator:^BOOL(BOOL v) { return YES; }];
  [@"changed" writeToURL:[self.directory URLByAppendingPathComponent:@"main.js"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
  NSDictionary *effect = [self.executor executeToolNamed:@"run_program" arguments:args root:self.resolver.root owner:owner precondition:condition];
  XCTAssertEqualObjects([self feedback:effect][@"payload"][@"reason"], @"workspace_snapshot_changed"); XCTAssertEqual(self.vm.starts, 0U);
  NSDictionary *environmentOwner = [self owner:@"run_program" arguments:args attempt:NSUUID.UUID.UUIDString.lowercaseString];
  NSDictionary *environmentCondition = [self condition:@"run_program" arguments:args];
  [self.executor registerToolNamed:@"run_program" arguments:args root:self.resolver.root owner:environmentOwner precondition:environmentCondition validator:^BOOL(BOOL v) { return YES; }];
  NSDictionary *original = self.store.manifest;
  NSMutableDictionary *changed = [original mutableCopy];
  changed[@"disk_sha256"] = @"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
  self.store.manifest = changed;
  effect = [self.executor executeToolNamed:@"run_program" arguments:args root:self.resolver.root owner:environmentOwner precondition:environmentCondition];
  XCTAssertEqualObjects([self feedback:effect][@"payload"][@"reason"], @"installed_environment_changed"); XCTAssertEqual(self.vm.starts, 0U);
  self.store.manifest = original;
  self.vm.exitStatus = 7;
  NSDictionary *next = [self owner:@"run_program" arguments:args attempt:NSUUID.UUID.UUIDString.lowercaseString];
  effect = [self invoke:@"run_program" arguments:args owner:next];
  NSDictionary *payload = [self feedback:effect][@"payload"];
  XCTAssertEqualObjects(payload[@"exit_code"], @7); XCTAssertEqualObjects(payload[@"stdout"], @"actual program output\n");
  XCTAssertEqualObjects(payload[@"stderr"], @"compiler diagnostic\n"); XCTAssertEqual(self.store.leases, 0U);
}
- (void)testExactReplayUsesReceiptAndLostProcessRecoveryNeverRunsAgain {
  NSDictionary *args = @{@"environment_id":@"node-test",@"entry_path":@"main.js",@"args":@[]};
  NSDictionary *owner = [self owner:@"run_program" arguments:args attempt:NSUUID.UUID.UUIDString.lowercaseString];
  NSDictionary *condition = [self condition:@"run_program" arguments:args];
  NSDictionary *effect = [self invoke:@"run_program" arguments:args owner:owner];
  XCTAssertEqualObjects([self.executor executeToolNamed:@"run_program" arguments:args root:self.resolver.root owner:owner precondition:condition], effect);
  XCTAssertEqualObjects([self.executor recoverToolNamed:@"run_program" arguments:args root:self.resolver.root owner:owner precondition:condition][@"effect"], effect);
  DSHAgentRuntimeToolExecutor *lost = [[DSHAgentRuntimeToolExecutor alloc] initWithResolver:self.resolver store:self.store];
  XCTAssertEqualObjects([lost recoverToolNamed:@"run_program" arguments:args root:self.resolver.root owner:owner precondition:condition][@"status"], @"ambiguous");
  XCTAssertEqual(self.vm.starts, 1U);
}
- (void)testServiceFromPriorAttemptCanBeStoppedOnlyBySameConversationRoot {
  ARTestServiceVM *service = [[ARTestServiceVM alloc] init]; self.executor.serviceFactory = ^{ return service; };
  NSDictionary *args = @{@"environment_id":@"node-test",@"entry_path":@"main.js",@"args":@[],@"port":@3000};
  NSDictionary *owner = [self owner:@"start_runtime_service" arguments:args attempt:NSUUID.UUID.UUIDString.lowercaseString];
  NSDictionary *started = [self invoke:@"start_runtime_service" arguments:args owner:owner];
  XCTAssertEqualObjects(started[@"status"], @"ok"); XCTAssertEqual(self.store.leases, 1U);
  NSDictionary *registry = [[[DSHAgentToolRegistry alloc] init] registryForRoot:self.resolver.root error:nil];
  XCTAssertTrue([[registry[@"tools"] valueForKey:@"name"] containsObject:@"stop_runtime_service"]);
  NSError *error = nil; XCTAssertFalse([self.store removeEnvironmentId:@"node-test" error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_ENV_IN_USE");
  NSDictionary *stopArgs = @{@"service_id":[self feedback:started][@"payload"][@"service_id"]};
  NSMutableDictionary *wrong = [[self owner:@"stop_runtime_service" arguments:stopArgs attempt:NSUUID.UUID.UUIDString.lowercaseString] mutableCopy];
  wrong[@"conversation_id"] = NSUUID.UUID.UUIDString.lowercaseString;
  XCTAssertEqualObjects([self invoke:@"stop_runtime_service" arguments:stopArgs owner:wrong][@"status"], @"failed");
  XCTAssertFalse(service.cancelled);
  NSDictionary *next = [self owner:@"stop_runtime_service" arguments:stopArgs attempt:NSUUID.UUID.UUIDString.lowercaseString];
  XCTAssertEqualObjects([self invoke:@"stop_runtime_service" arguments:stopArgs owner:next][@"status"], @"ok");
  XCTAssertTrue(service.cancelled); XCTAssertEqual(self.store.leases, 0U); XCTAssertEqual(service.starts, 1U);
  DSHGuestVMOwner *available = [DSHGuestRuntimeState.sharedState acquireGuestOwner]; XCTAssertNotNil(available);
  if (available) [DSHGuestRuntimeState.sharedState releaseGuestOwner:available];
}
- (void)testManualInstallCancellationIsCancelledAndOtherDownloadTokenIsUntouched {
  self.store.installed = NO; self.store.cancelledBySettings = YES;
  NSDictionary *args = @{@"environment_id":@"node-test"};
  NSDictionary *owner = [self owner:@"install_runtime_environment" arguments:args attempt:NSUUID.UUID.UUIDString.lowercaseString];
  NSDictionary *effect = [self invoke:@"install_runtime_environment" arguments:args owner:owner];
  XCTAssertEqualObjects(effect[@"status"], @"cancelled");
  XCTAssertEqualObjects([self feedback:effect][@"payload"][@"failure_code"], @"E_AGENT_CANCELLED");
  self.store.cancelledBySettings = NO; self.store.pendingToken = @"manual-owned-download";
  owner = [self owner:@"install_runtime_environment" arguments:args attempt:NSUUID.UUID.UUIDString.lowercaseString];
  effect = [self invoke:@"install_runtime_environment" arguments:args owner:owner];
  XCTAssertEqualObjects(effect[@"status"], @"failed");
  [self.executor cancelAttempt:owner[@"attempt_id"]];
  XCTAssertEqualObjects(self.store.pendingToken, @"manual-owned-download");
}
- (void)testEncodedControlCharacterFeedbackStaysWithinCanonicalBudget {
  const uint8_t pattern[] = {0,1,2,3,4,5,6,7,27,'[','m',0xe4,0xb8,0xad};
  NSMutableData *data = [NSMutableData data];
  for (NSUInteger i = 0; i < 3000; i++) [data appendBytes:pattern length:sizeof(pattern)];
  self.vm.testOutput = data; self.vm.exitStatus = 7;
  NSDictionary *args = @{@"environment_id":@"node-test",@"entry_path":@"main.js",@"args":@[]};
  NSDictionary *effect = [self invoke:@"run_program" arguments:args
      owner:[self owner:@"run_program" arguments:args attempt:NSUUID.UUID.UUIDString.lowercaseString]];
  XCTAssertNotNil(effect); XCTAssertEqualObjects(effect[@"status"], @"failed");
  XCTAssertLessThanOrEqual([effect[@"feedback"] lengthOfBytesUsingEncoding:NSUTF8StringEncoding], 65536U);
  XCTAssertTrue(DSHAgentRuntimeContractValid(@"runtime_feedback", effect[@"feedback"]));
  NSDictionary *payload = [self feedback:effect][@"payload"];
  XCTAssertEqualObjects(payload[@"exit_code"], @7);
  XCTAssertEqualObjects(payload[@"failure_code"], @"E_AGENT_TOOL_FAILED");
  XCTAssertEqualObjects(payload[@"truncated"], @YES);
  XCTAssertTrue([payload[@"stdout"] containsString:@"中"]);
}
- (void)testActiveServiceCanStopAtUnconfirmedReceiptCapacity {
  ARTestServiceVM *service = [[ARTestServiceVM alloc] init]; self.executor.serviceFactory = ^{ return service; };
  NSDictionary *args = @{@"environment_id":@"node-test",@"entry_path":@"main.js",@"args":@[],@"port":@3000};
  NSDictionary *startOwner = [self owner:@"start_runtime_service" arguments:args attempt:NSUUID.UUID.UUIDString.lowercaseString];
  NSDictionary *started = [self invoke:@"start_runtime_service" arguments:args owner:startOwner];
  XCTAssertEqualObjects(started[@"status"], @"ok");
  NSDictionary *listCondition = [self condition:@"list_runtime_environments" arguments:@{}];
  NSDictionary *first = nil;
  for (NSUInteger index = 0; index < 511; index++) {
    NSDictionary *owner = [self owner:@"list_runtime_environments" arguments:@{} attempt:NSUUID.UUID.UUIDString.lowercaseString];
    if (!first) first = owner;
    XCTAssertTrue([self.executor registerToolNamed:@"list_runtime_environments" arguments:@{} root:self.resolver.root
        owner:owner precondition:listCondition validator:^BOOL(BOOL value) { return YES; }]);
  }
  XCTAssertEqual(self.executor.records.count, 512U);
  NSDictionary *effect = [self.executor executeToolNamed:@"list_runtime_environments" arguments:@{} root:self.resolver.root
      owner:first precondition:listCondition];
  XCTAssertEqualObjects([self.executor recoverToolNamed:@"list_runtime_environments" arguments:@{} root:self.resolver.root
      owner:first precondition:listCondition][@"effect"], effect);
  NSDictionary *stopArgs = @{@"service_id":[self feedback:started][@"payload"][@"service_id"]};
  NSDictionary *stopOwner = [self owner:@"stop_runtime_service" arguments:stopArgs attempt:NSUUID.UUID.UUIDString.lowercaseString];
  XCTAssertEqualObjects([self invoke:@"stop_runtime_service" arguments:stopArgs owner:stopOwner][@"status"], @"ok");
  XCTAssertTrue(service.cancelled); XCTAssertEqual(self.store.leases, 0U);
  XCTAssertEqual(self.executor.records.count, 513U);
  [self.executor acknowledgeSettlementOwner:first];
  XCTAssertEqual(self.executor.records.count, 512U);
  [self.executor acknowledgeSettlementOwner:stopOwner];
  [self.executor acknowledgeSettlementOwner:startOwner];
  XCTAssertEqual(self.executor.records.count, 510U);
}
- (void)testCompletedOperationReleasesValidatorButRetainsUnconfirmedReceipt {
  NSDictionary *args = @{@"environment_id":@"node-test",@"entry_path":@"main.js",@"args":@[]};
  NSDictionary *owner = [self owner:@"run_program" arguments:args attempt:NSUUID.UUID.UUIDString.lowercaseString];
  NSDictionary *condition = [self condition:@"run_program" arguments:args];
  __weak NSObject *weakValue;
  @autoreleasepool {
    NSObject *value = [[NSObject alloc] init]; weakValue = value;
    [self.executor registerToolNamed:@"run_program" arguments:args root:self.resolver.root owner:owner
        precondition:condition validator:^BOOL(BOOL required) { return value != nil; }];
  }
  XCTAssertNotNil(weakValue);
  NSDictionary *effect;
  @autoreleasepool {
    effect = [self.executor executeToolNamed:@"run_program" arguments:args root:self.resolver.root owner:owner precondition:condition];
  }
  XCTAssertNotNil(effect); XCTAssertNil(weakValue);
  XCTAssertEqual(self.executor.records.count, 1U);
  [self.executor acknowledgeSettlementOwner:owner]; XCTAssertEqual(self.executor.records.count, 0U);
}
- (void)testServiceInitializationFailureReleasesLeaseBeforeRetry {
  self.executor.serviceFactory = ^DSHRuntimeServiceVM *{
    @throw [NSException exceptionWithName:@"InjectedFailure" reason:nil userInfo:nil];
  };
  NSDictionary *args = @{@"environment_id":@"node-test",@"entry_path":@"main.js",@"args":@[],@"port":@3000};
  NSDictionary *effect = [self invoke:@"start_runtime_service" arguments:args
      owner:[self owner:@"start_runtime_service" arguments:args attempt:NSUUID.UUID.UUIDString.lowercaseString]];
  XCTAssertEqualObjects(effect[@"status"], @"failed");
  XCTAssertEqualObjects([self feedback:effect][@"payload"][@"reason"], @"service_initialization_failed");
  XCTAssertEqual(self.store.leases, 0U); XCTAssertEqual(self.store.releases, 1U);
  NSDictionary *run = @{@"environment_id":@"node-test",@"entry_path":@"main.js",@"args":@[]};
  effect = [self invoke:@"run_program" arguments:run
      owner:[self owner:@"run_program" arguments:run attempt:NSUUID.UUID.UUIDString.lowercaseString]];
  XCTAssertEqualObjects(effect[@"status"], @"ok"); XCTAssertEqual(self.store.leases, 0U);
}

- (void)testServiceVMTimeoutBeforeOuterDeadlineKeepsTimeoutReasonAndReleasesLease {
  ARFailedServiceVM *service = [[ARFailedServiceVM alloc] initWithBundle:NSBundle.mainBundle];
  service.startupError = DSHRuntimeProgramError(@"E_PROGRAM_TIMEOUT");
  self.executor.serviceFactory = ^{ return service; };
  NSDictionary *args = @{@"environment_id":@"node-test",@"entry_path":@"main.js",@"args":@[],@"port":@3000};
  NSTimeInterval began = NSProcessInfo.processInfo.systemUptime;
  NSDictionary *effect = [self invoke:@"start_runtime_service" arguments:args
      owner:[self owner:@"start_runtime_service" arguments:args attempt:NSUUID.UUID.UUIDString.lowercaseString]];
  XCTAssertLessThan(NSProcessInfo.processInfo.systemUptime - began, 5.0,
      @"The injected VM timeout returns before the outer startup wait can expire.");
  XCTAssertEqualObjects(effect[@"status"], @"failed");
  NSDictionary *payload = [self feedback:effect][@"payload"];
  XCTAssertEqualObjects(payload[@"failure_code"], @"E_AGENT_TOOL_FAILED");
  XCTAssertEqualObjects(payload[@"reason"], @"service_start_timed_out");
  XCTAssertEqualObjects(payload[@"exit_code"], NSNull.null);
  XCTAssertEqual(self.store.leases, 0U); XCTAssertEqual(self.store.releases, 1U);
}

- (void)testServiceTimeoutClassificationRequiresTrustedDomainAndCode {
  NSError *timeout = DSHRuntimeProgramError(@"E_PROGRAM_TIMEOUT");
  NSArray<NSError *> *failures = @[
    [NSError errorWithDomain:@"ForeignDomain" code:timeout.code userInfo:timeout.userInfo],
    [NSError errorWithDomain:timeout.domain code:timeout.code userInfo:@{
      @"code":@"E_PROGRAM_EXEC", NSLocalizedDescriptionKey:@"E_PROGRAM_TIMEOUT private diagnostic"}],
    DSHRuntimeProgramError(@"E_PROGRAM_ROOT_STALE"),
  ];
  NSDictionary *args = @{@"environment_id":@"node-test",@"entry_path":@"main.js",@"args":@[],@"port":@3000};
  for (NSError *failure in failures) {
    ARFailedServiceVM *service = [[ARFailedServiceVM alloc] initWithBundle:NSBundle.mainBundle];
    service.startupError = failure; self.executor.serviceFactory = ^{ return service; };
    NSDictionary *effect = [self invoke:@"start_runtime_service" arguments:args
        owner:[self owner:@"start_runtime_service" arguments:args attempt:NSUUID.UUID.UUIDString.lowercaseString]];
    XCTAssertEqualObjects(effect[@"status"], @"failed");
    XCTAssertEqualObjects([self feedback:effect][@"payload"][@"reason"], @"service_start_failed");
    XCTAssertFalse([effect[@"feedback"] containsString:@"private diagnostic"]);
    XCTAssertEqual(self.store.leases, 0U);
  }
}
@end
