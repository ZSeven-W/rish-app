#import "AgentRuntimeExecutorTestSupport.h"
#import "AgentRuntimeCoordinator.h"
#import "AgentToolExecutionService.h"
#import "AgentExecutionLedger.h"
#import "AgentTranscriptStore.h"
#import <objc/message.h>

@interface NSObject (ARPublicModule)
- (instancetype)initWithCoordinator:(id<DSHAgentRuntimeCoordinating>)coordinator;
@end

/// The public Module and real runtime executor/cancellation proof are used;
/// only the durable coordinator fixture and slow VM are substituted here.
@interface ARSignalExecution : DSHAgentToolExecutionService
@property(nonatomic, strong) DSHAgentRuntimeToolExecutor *runtime;
@end
@implementation ARSignalExecution
- (void)signalRuntimeCancellationRequest:(NSDictionary *)request { [self.runtime signalCancelRequest:request]; }
@end
@interface ARPublicCoordinator : DSHAgentRuntimeCoordinator
@property(nonatomic, strong) DSHAgentRuntimeToolExecutor *runtime;
@property(nonatomic, copy) NSDictionary *arguments;
@property(nonatomic, copy) NSDictionary *condition;
@property(nonatomic) BOOL effectWasOnCoordinator;
@property(nonatomic) BOOL cancellationWasOnCoordinator;
@end
@implementation ARPublicCoordinator
- (NSDictionary *)executeAgentTool:(NSDictionary *)request error:(NSError **)error {
  (void)error;
  __block BOOL registered = NO;
  DSHSessionWorkspacePerformSync(^{
    registered = [self.runtime registerToolNamed:request[@"name"] arguments:self.arguments root:request[@"root"]
        owner:request precondition:self.condition validator:^BOOL(BOOL required) { return YES; }];
  });
  if (!registered) return @{@"status":@"conflict"};
  self.effectWasOnCoordinator = DSHSessionWorkspaceCoordinator.sharedCoordinator.isExecutingOnQueue;
  return [self.runtime executeToolNamed:request[@"name"] arguments:self.arguments root:request[@"root"]
      owner:request precondition:self.condition];
}
- (NSDictionary *)cancelAgentAttempt:(NSDictionary *)request error:(NSError **)error {
  (void)request; (void)error;
  self.cancellationWasOnCoordinator = DSHSessionWorkspaceCoordinator.sharedCoordinator.isExecutingOnQueue;
  return @{@"schema_version":@2,@"status":@"cancel_requested"};
}
@end

@interface AgentRuntimeExecutorTests (PublicCancel)
- (void)assertPublicCancellationOf:(NSString *)name;
@end
@implementation AgentRuntimeExecutorTests (PublicCancel)
- (void)assertPublicCancellationOf:(NSString *)name {
  BOOL service = [name isEqual:@"start_runtime_service"];
  NSMutableDictionary *arguments = [@{@"environment_id":@"node-test",@"entry_path":@"main.js",@"args":@[]} mutableCopy];
  if (service) arguments[@"port"] = @3000;
  NSDictionary *owner = [self owner:name arguments:arguments attempt:NSUUID.UUID.UUIDString.lowercaseString];
  NSDictionary *condition = [self condition:name arguments:arguments];
  self.vm.hold = YES;
  ARTestServiceVM *serviceVM = [[ARTestServiceVM alloc] init]; serviceVM.holdBeforeReady = YES;
  self.executor.serviceFactory = ^{ return serviceVM; };
  DSHAgentNativeWAL *wal = [[DSHAgentNativeWAL alloc] initWithRootURL:self.directory
      clock:^{ return NSDate.date; } identifierGenerator:^{ return NSUUID.UUID.UUIDString.lowercaseString; } faultHook:nil];
  DSHAgentTranscriptStore *transcripts = [[DSHAgentTranscriptStore alloc] initWithWAL:wal];
  DSHAgentExecutionLedger *ledger = [[DSHAgentExecutionLedger alloc] initWithWAL:wal];
  ARSignalExecution *execution = [[ARSignalExecution alloc] initWithWAL:wal ledger:ledger
      preparedStore:(id)NSNull.null transcripts:transcripts workspaceExecutor:self.workspace gitExecutor:(id)NSNull.null];
  execution.runtime = self.executor;
  ARPublicCoordinator *coordinator = [[ARPublicCoordinator alloc] initForRecoveryTestingWithWAL:wal
      preparedStore:(id)NSNull.null roundService:(id)NSNull.null executionService:execution transcripts:transcripts ledger:ledger];
  coordinator.runtime = self.executor; coordinator.arguments = arguments; coordinator.condition = condition;
  NSObject *module = [[NSClassFromString(@"AgentRuntimeModule") alloc] initWithCoordinator:coordinator];
  XCTAssertNotNil(module);
  typedef void (^Resolve)(id);
  typedef void (^Reject)(NSString *, NSString *, NSError *);
  typedef void (*Invoke)(id, SEL, id, Resolve, Reject);
  Invoke invoke = (Invoke)objc_msgSend;
  XCTestExpectation *finished = [self expectationWithDescription:@"public runtime execution ended"];
  invoke(module, NSSelectorFromString(@"executeAgentToolRequest:resolver:rejecter:"), owner,
      ^(id result) { XCTAssertEqualObjects(result[@"status"], @"cancelled"); [finished fulfill]; },
      ^(NSString *code, NSString *message, NSError *error) { (void)message; (void)error; XCTFail(@"%@", code); [finished fulfill]; });
  dispatch_semaphore_t began = service ? serviceVM.began : self.vm.began;
  XCTAssertEqual(dispatch_semaphore_wait(began, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)), 0L);
  XCTAssertFalse(coordinator.effectWasOnCoordinator);
  dispatch_semaphore_t entered = dispatch_semaphore_create(0), release = dispatch_semaphore_create(0);
  [DSHSessionWorkspaceCoordinator.sharedCoordinator performAsync:^{
    dispatch_semaphore_signal(entered); dispatch_semaphore_wait(release, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
  }];
  XCTAssertEqual(dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)), 0L);
  NSMutableDictionary *target = [@{@"schema_version":@2,@"kind":@"tool"} mutableCopy];
  for (NSString *field in @[@"task_id",@"attempt_id",@"round_id",@"round_index",@"call_index",@"call_id",@"idempotency_key"])
    target[field] = owner[field];
  NSDictionary *cancel = @{@"schema_version":@2,@"operation_id":NSUUID.UUID.UUIDString.lowercaseString,@"target":target,
      @"root":owner[@"root"], @"controller_cas":@{@"conversation_id":owner[@"conversation_id"],
        @"schema_version":@1,@"task_id":owner[@"task_id"],@"attempt_id":owner[@"attempt_id"],
        @"expected_controller_generation":@1,@"expected_journal_revision":@1,@"expected_session_generation":@1,
        @"expected_session_sha256":@"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"},
      @"committed_checkpoint":@{@"schema_version":@1,@"journal_revision":@1,@"session_generation":@1,
        @"session_sha256":@"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"},
      @"expected_round_revision":NSNull.null,@"expected_execution_revision":@1,
      @"expected_transcript":@{@"schema_version":@1,@"transcript_ref":NSUUID.UUID.UUIDString.lowercaseString,
        @"generation":@0,@"transcript_sha256":@"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",@"transcript_bytes":@0},
      @"cancel_token":@{@"schema_version":@2,@"issuer":@"completion_controller",
        @"task_id":owner[@"task_id"],@"attempt_id":owner[@"attempt_id"],@"source_event_id":NSUUID.UUID.UUIDString.lowercaseString,
        @"token":NSUUID.UUID.UUIDString.lowercaseString,@"expected_phase":@"execution_intent",@"reason_code":@"E_AGENT_CANCELLED"}};
  NSMutableDictionary *wrong = [cancel mutableCopy];
  NSMutableDictionary *wrongRoot = [owner[@"root"] mutableCopy]; wrongRoot[@"workspace_binding_revision"] = @99; wrong[@"root"] = wrongRoot;
  XCTestExpectation *wrongDone = [self expectationWithDescription:@"mismatched hint queued"];
  invoke(module, NSSelectorFromString(@"cancelAgentAttemptRequest:resolver:rejecter:"), wrong,
      ^(id result) { (void)result; [wrongDone fulfill]; },
      ^(NSString *code, NSString *message, NSError *error) { (void)code; (void)message; (void)error; [wrongDone fulfill]; });
  XCTAssertFalse(service ? serviceVM.cancelled : self.vm.cancelled);
  XCTestExpectation *cancelDone = [self expectationWithDescription:@"public cancellation committed"];
  invoke(module, NSSelectorFromString(@"cancelAgentAttemptRequest:resolver:rejecter:"), cancel,
      ^(id result) { XCTAssertEqualObjects(result[@"status"], @"cancel_requested"); [cancelDone fulfill]; },
      ^(NSString *code, NSString *message, NSError *error) { (void)message; (void)error; XCTFail(@"%@", code); [cancelDone fulfill]; });
  // The same real public Module call signals the registered VM while its
  // coordinator is deliberately unavailable. It cannot depend on the CAS.
  XCTAssertTrue(service ? serviceVM.cancelled : self.vm.cancelled);
  dispatch_semaphore_signal(release);
  [self waitForExpectations:@[finished, wrongDone, cancelDone] timeout:3];
  XCTAssertTrue(coordinator.cancellationWasOnCoordinator);
  XCTAssertEqual(self.store.leases, 0U);
}
- (void)testPublicModuleCancelsLongRuntimeProgramBeforeCoordinatorCAS {
  [self assertPublicCancellationOf:@"run_program"];
}
- (void)testPublicModuleCancelsServiceStartupBeforeCoordinatorCAS {
  [self assertPublicCancellationOf:@"start_runtime_service"];
}
@end
