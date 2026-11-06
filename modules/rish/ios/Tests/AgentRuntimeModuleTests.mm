#import "DSHTestProviderModelsFixture.h"
#import <XCTest/XCTest.h>
#import <RishNative/RishNativeModule.h>
#import "../../../../apps/gpui/ios/Sources/RishGPUIExports.h"

#import "../../../../modules/rish/ios/Sources/AgentNativeWAL.h"
#import "../../../../modules/rish/ios/Sources/AgentRuntimeCoordinator.h"
#import "../../../../modules/rish/ios/Sources/AgentExecutionLedger.h"
#import "../../../../modules/rish/ios/Sources/AgentGitToolExecutor.h"
#import "../../../../modules/rish/ios/Sources/AgentPreparedAttemptStore.h"
#import "../../../../modules/rish/ios/Sources/AgentProviderRoundService.h"
#import "../../../../modules/rish/ios/Sources/AgentRootResolver.h"
#import "../../../../modules/rish/ios/Sources/AgentRoundJournal.h"
#import "../../../../modules/rish/ios/Sources/AgentToolBatchService.h"
#import "../../../../modules/rish/ios/Sources/AgentToolExecutionService.h"
#import "../../../../modules/rish/ios/Sources/AgentTranscriptStore.h"
#import "../../../../modules/rish/ios/Sources/AgentWorkspaceToolExecutor.h"
#import "../../../../modules/rish/ios/Sources/DSHCompletionProviderTransport.h"
#import "../../../../modules/rish/ios/Sources/DshProviderTransport.h"
#import "../../../../modules/rish/ios/Sources/SessionSnapshotStore.h"

#import "../../../../modules/rish/ios/Sources/SessionWorkspaceCoordinator.h"

#import <objc/message.h>
#import <objc/runtime.h>

typedef void (^DSHRuntimeResolve)(id value);
typedef void (^DSHRuntimeReject)(NSString *code, NSString *message,
                                 NSError *error);

@interface NSObject (DSHRuntimeModuleContract)
+ (NSString *)moduleName;
- (instancetype)initWithCoordinator:(id<DSHAgentRuntimeCoordinating>)coordinator;
@end

@interface DSHRecordingRuntimeCoordinator : NSObject
    <DSHAgentRuntimeCoordinating>
@property(nonatomic, getter=isAvailable) BOOL available;
@property(nonatomic, copy) NSString *method;
@property(nonatomic, copy) NSDictionary *request;
@property(nonatomic, copy) NSDictionary *result;
@property(nonatomic, strong) NSError *error;
@property(nonatomic) NSUInteger callCount;
@property(nonatomic) BOOL throwsPrivateException;
@end

@implementation DSHRecordingRuntimeCoordinator

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _available = YES;
    _result = @{ @"schema_version" : @2, @"status" : @"ok" };
  }
  return self;
}

- (NSDictionary *)record:(NSString *)method request:(NSDictionary *)request
                    error:(NSError **)error {
  if (self.throwsPrivateException) {
    @throw [NSException exceptionWithName:@"PrivateException"
                                  reason:@"private path or credential"
                                userInfo:nil];
  }
  self.method = method;
  self.request = request;
  self.callCount += 1;
  if (self.error != nil) {
    if (error != nullptr) *error = self.error;
    return nil;
  }
  return self.result;
}

#define DSH_RECORD(selector) \
  - (NSDictionary *)selector:(NSDictionary *)request error:(NSError **)error { \
    return [self record:@#selector request:request error:error]; \
  }

DSH_RECORD(prepareAgentAttempt)
DSH_RECORD(completeAgentRoundV2)
DSH_RECORD(prepareAgentToolBatch)
DSH_RECORD(bindAgentApproval)
DSH_RECORD(executeAgentTool)
DSH_RECORD(cancelAgentAttempt)
DSH_RECORD(readAgentRoundPresentations)
DSH_RECORD(queryAgentAttempt)
DSH_RECORD(queryAgentTool)
DSH_RECORD(recoverAgentAttempt)
DSH_RECORD(finalizeAgentAttempt)
DSH_RECORD(discardAgentAttempt)
DSH_RECORD(interruptAgentAttempt)
DSH_RECORD(queryAgentCleanup)

#undef DSH_RECORD

@end

@interface DSHWaitingRuntimeCoordinator : DSHRecordingRuntimeCoordinator
@property(nonatomic, strong) dispatch_semaphore_t releaseProvider;
@property(nonatomic, copy) dispatch_block_t providerStarted;
@property(nonatomic) BOOL providerOnTransactionQueue;
@property(nonatomic) BOOL queryOnTransactionQueue;
@property(nonatomic) BOOL cancelOnTransactionQueue;
@end
@implementation DSHWaitingRuntimeCoordinator
- (NSDictionary *)completeAgentRoundV2:(NSDictionary *)request error:(NSError **)error {
  self.providerOnTransactionQueue = DSHSessionWorkspaceCoordinator.sharedCoordinator.isExecutingOnQueue;
  if (self.providerStarted) self.providerStarted();
  dispatch_semaphore_wait(self.releaseProvider,
      dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
  return @{ @"status" : @"finished" };
}
- (NSDictionary *)recoverAgentAttempt:(NSDictionary *)request error:(NSError **)error {
  return [self completeAgentRoundV2:request error:error];
}
- (NSDictionary *)queryAgentAttempt:(NSDictionary *)request error:(NSError **)error {
  self.queryOnTransactionQueue = DSHSessionWorkspaceCoordinator.sharedCoordinator.isExecutingOnQueue;
  return @{ @"status" : @"in_flight" };
}
- (NSDictionary *)cancelAgentAttempt:(NSDictionary *)request error:(NSError **)error {
  self.cancelOnTransactionQueue = DSHSessionWorkspaceCoordinator.sharedCoordinator.isExecutingOnQueue;
  dispatch_semaphore_signal(self.releaseProvider);
  return @{ @"status" : @"cancel_requested" };
}
@end

@interface DSHRecoveryWAL : DSHAgentNativeWAL
@property(nonatomic, copy) NSDictionary *recoveryState;
@end
@implementation DSHRecoveryWAL
- (NSDictionary *)snapshotWithError:(NSError **)error {
  if (error != nullptr) *error = nil;
  return self.recoveryState;
}
- (BOOL)performAtomicTransaction:(DSHAgentNativeWALMutation)mutation
                           error:(NSError **)error {
  NSMutableDictionary *candidate = [self.recoveryState mutableCopy];
  if (candidate[@"operations"] == nil) candidate[@"operations"] = @[];
  if (candidate[@"operation_results"] == nil) {
    candidate[@"operation_results"] = @[];
  }
  BOOL committed = mutation(candidate, error);
  if (committed) self.recoveryState = [candidate copy];
  return committed;
}
- (BOOL)reconcileOwnerLossWithError:(NSError **)error {
  if (error != nullptr) *error = nil;
  return YES;
}
@end

@interface DSHRecoveryPreparedStore : DSHAgentPreparedAttemptStore
@property(nonatomic, copy) NSDictionary *recoveryAuthority;
@property(nonatomic, copy) NSDictionary *preparedProjection;
@end
@implementation DSHRecoveryPreparedStore
- (NSDictionary *)nativeAuthorityForTaskId:(NSString *)taskId
                                  attemptId:(NSString *)attemptId
                                      error:(NSError **)error {
  (void)taskId; (void)attemptId;
  if (error != nullptr) *error = nil;
  return self.recoveryAuthority;
}
- (NSDictionary *)preparedAttemptForTaskId:(NSString *)taskId
                                  attemptId:(NSString *)attemptId
                                      error:(NSError **)error {
  (void)taskId; (void)attemptId;
  if (error != nullptr) *error = nil;
  return self.preparedProjection;
}
- (BOOL)validatePreparedRoot:(NSDictionary *)root taskId:(NSString *)taskId
                   attemptId:(NSString *)attemptId error:(NSError **)error {
  (void)root; (void)taskId; (void)attemptId;
  if (error != nullptr) *error = nil;
  return YES;
}
@end

@interface DSHRecoverySessionStore : DSHSessionSnapshotStore
@property(nonatomic, copy) NSDictionary *recoveryLoad;
@end
@implementation DSHRecoverySessionStore
- (NSDictionary *)loadSessionSnapshotWithError:(NSError **)error {
  if (error != nullptr) *error = nil;
  return self.recoveryLoad;
}
@end

@interface DSHRecordingRoundRecoveryService : DSHAgentProviderRoundService
@property(nonatomic, copy) NSDictionary *recoveryResult;
@property(nonatomic, copy) NSDictionary *receivedRecoveryRequest;
@property(nonatomic, copy) NSDictionary *retryResult;
@property(nonatomic) BOOL retryOnTransactionQueue;
@property(nonatomic, copy) NSDictionary *receivedRetryRequest;
@end
@implementation DSHRecordingRoundRecoveryService
- (NSDictionary *)recoverAgentRoundWithRequest:(NSDictionary *)request
                                          error:(NSError **)error {
  self.receivedRecoveryRequest = request;
  if (error != nullptr) *error = nil;
  return self.recoveryResult;
}
- (NSDictionary *)retryFailedAgentRoundV2WithRequest:(NSDictionary *)request
                                                error:(NSError **)error {
  self.retryOnTransactionQueue = DSHSessionWorkspaceCoordinator.sharedCoordinator.isExecutingOnQueue;
  self.receivedRetryRequest = request;
  if (error != nullptr) *error = nil;
  return self.retryResult;
}
@end

@interface DSHRecordingToolRecoveryService : DSHAgentToolExecutionService
@property(nonatomic, copy) NSDictionary *recoveryResult;
@property(nonatomic, copy) NSDictionary *receivedRecoveryRequest;
@end
@implementation DSHRecordingToolRecoveryService
- (NSDictionary *)recoverAgentToolWithRequest:(NSDictionary *)request
                                         error:(NSError **)error {
  self.receivedRecoveryRequest = request;
  if (error != nullptr) *error = nil;
  if ([@[@"completed", @"failed", @"denied", @"cancelled", @"ambiguous"]
          containsObject:self.recoveryResult[@"status"]]) {
    NSMutableDictionary *result = [self.recoveryResult mutableCopy];
    result[@"operation_id"] = request[@"operation_id"];
    result[@"result_execution_revision"] =
        request[@"expected_execution_revision"];
    return [result copy];
  }
  return self.recoveryResult;
}
@end

@interface DSHRecordingQueryLedger : DSHAgentExecutionLedger
@property(nonatomic, copy) NSDictionary *queryResult;
@property(nonatomic, copy) NSDictionary *receivedRootExpectation;
@end
@implementation DSHRecordingQueryLedger
- (NSDictionary *)queryAgentExecutionWithLocator:(NSDictionary *)locator
                                expectedTranscript:(NSDictionary *)transcript
                                               root:(NSDictionary *)root
                                             error:(NSError **)error {
  (void)locator; (void)transcript;
  self.receivedRootExpectation = root;
  if (error != nullptr) *error = nil;
  return self.queryResult;
}
@end

@interface DSHEvidenceRootResolver : DSHAgentRootResolver
@property(nonatomic, copy) NSDictionary *currentRoot;
@end
@implementation DSHEvidenceRootResolver
- (instancetype)initWithRoot:(NSDictionary *)root {
  self = [super initWithWorkspaceAccess:
      (DSHLocalWorkspaceAccess *)(id)NSNull.null projectAccess:nil];
  if (self != nil) _currentRoot = [root copy];
  return self;
}
- (NSDictionary *)resolveRootForWorkspaceId:(NSString *)workspaceId
                                    projectId:(NSString *)projectId
                              bindingRevision:(NSNumber *)bindingRevision
                                        error:(NSError **)error {
  (void)workspaceId; (void)projectId; (void)bindingRevision;
  if (error != nullptr) *error = nil;
  return self.currentRoot;
}
- (BOOL)validateFrozenRoot:(NSDictionary *)root error:(NSError **)error {
  if (error != nullptr) *error = nil;
  return [root isEqual:self.currentRoot];
}
- (DSHLocalWorkspaceAuthorityMutationGuard *)
    acquireAuthorityMutationGuardForFrozenRoot:(NSDictionary *)root
                                         error:(NSError **)error {
  (void)root;
  if (error != nullptr) *error = nil;
  return [[DSHLocalWorkspaceAuthorityMutationGuard alloc] init];
}
- (BOOL)validateFrozenRoot:(NSDictionary *)root
     authorityMutationGuard:(DSHLocalWorkspaceAuthorityMutationGuard *)guard
                      error:(NSError **)error {
  (void)guard;
  return [self validateFrozenRoot:root error:error];
}
@end

@interface DSHRecoveryRuntimeCoordinator : DSHAgentRuntimeCoordinator
@property(nonatomic, copy) NSDictionary *attemptQueryResult;
@end
@implementation DSHRecoveryRuntimeCoordinator
- (NSDictionary *)queryAgentAttempt:(NSDictionary *)request
                               error:(NSError **)error {
  (void)request;
  if (error != nullptr) *error = nil;
  return self.attemptQueryResult;
}
@end

@interface AgentRuntimeModuleTests : XCTestCase
@property(nonatomic, strong) NSURL *rootURL;
@end

@implementation AgentRuntimeModuleTests

- (void)setUp {
  [super setUp];
  XCTAssertTrue(DSHInstallTestProviderModels(self, @{@"dsh":@[@"deepseek-v4-flash"]},
      [NSSet setWithObject:@"deepseek-v4-flash"]));
  self.rootURL = [NSURL fileURLWithPath:[NSTemporaryDirectory()
      stringByAppendingPathComponent:NSUUID.UUID.UUIDString.lowercaseString]
                                isDirectory:YES];
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:self.rootURL
      withIntermediateDirectories:YES attributes:nil error:nil]);
}

- (void)tearDown {
  [NSFileManager.defaultManager removeItemAtURL:self.rootURL error:nil];
  [super tearDown];
}

- (Class)moduleClass {
  Class cls = NSClassFromString(@"AgentRuntimeModule");
  XCTAssertNotNil(cls);
  return cls;
}

- (id)moduleWithCoordinator:(DSHRecordingRuntimeCoordinator *)coordinator {
  return [[(id)[self moduleClass] alloc] initWithCoordinator:coordinator];
}

- (NSArray<NSString *> *)exportedNativeNames {
  NSMutableArray *names = [NSMutableArray array];
  for (const RishExport &entry : RishExports) {
    if (![entry.module isEqual:@"AgentRuntime"]) continue;
    XCTAssertTrue([[self moduleClass]
        instancesRespondToSelector:NSSelectorFromString(entry.selector)]);
    [names addObject:entry.name];
  }
  return [names sortedArrayUsingSelector:@selector(compare:)];
}

- (void)invokeModule:(id)module selector:(SEL)selector request:(id)request
              resolve:(DSHRuntimeResolve)resolve reject:(DSHRuntimeReject)reject {
  using Function = void (*)(id, SEL, id, DSHRuntimeResolve, DSHRuntimeReject);
  Function function = reinterpret_cast<Function>(objc_msgSend);
  function(module, selector, request, resolve, reject);
}

- (void)testProviderWaitDoesNotBlockSerializedQueryAndCancel {
  for (NSString *selectorName in @[@"completeAgentRoundV2Request:resolver:rejecter:",
                                    @"recoverAgentAttemptRequest:resolver:rejecter:"]) {
  DSHWaitingRuntimeCoordinator *coordinator = [[DSHWaitingRuntimeCoordinator alloc] init];
  coordinator.releaseProvider = dispatch_semaphore_create(0);
  XCTestExpectation *started = [self expectationWithDescription:@"provider started"];
  coordinator.providerStarted = ^{ [started fulfill]; };
  id module = [self moduleWithCoordinator:coordinator];
  XCTestExpectation *finished = [self expectationWithDescription:@"round returned"];
  DSHRuntimeReject reject = ^(NSString *code, NSString *message, NSError *error) {
    XCTFail(@"unexpected rejection %@", code);
  };
  [self invokeModule:module selector:NSSelectorFromString(selectorName)
      request:@{ @"action" : @"retry_failed_round" } resolve:^(id value) { [finished fulfill]; } reject:reject];
  [self waitForExpectations:@[started] timeout:2];
  XCTestExpectation *queried = [self expectationWithDescription:@"query responsive"];
  XCTestExpectation *cancelled = [self expectationWithDescription:@"cancel responsive"];
  [self invokeModule:module selector:NSSelectorFromString(@"queryAgentAttemptRequest:resolver:rejecter:")
      request:@{} resolve:^(id value) {
        XCTAssertEqualObjects(value[@"status"], @"in_flight");
        [queried fulfill];
      } reject:reject];
  [self invokeModule:module selector:NSSelectorFromString(@"cancelAgentAttemptRequest:resolver:rejecter:")
      request:@{} resolve:^(id value) { [cancelled fulfill]; } reject:reject];
  [self waitForExpectations:@[queried, cancelled, finished] timeout:2];
  XCTAssertFalse(coordinator.providerOnTransactionQueue);
  XCTAssertTrue(coordinator.queryOnTransactionQueue);
  XCTAssertTrue(coordinator.cancelOnTransactionQueue);
  }
}

- (void)testExportsAuthorityAndReadOnlyPresentationSelectorsWithoutLegacySurface {
  XCTAssertEqualObjects([[self moduleClass] moduleName], @"AgentRuntime");
  NSArray *expected = [@[
    @"bind_agent_approval", @"cancel_agent_attempt", @"complete_agent_round_v2",
    @"discard_agent_attempt", @"execute_agent_tool", @"finalize_agent_attempt",
    @"interrupt_agent_attempt", @"prepare_agent_attempt",
    @"prepare_agent_tool_batch", @"query_agent_attempt",
    @"query_agent_cleanup", @"query_agent_tool", @"read_agent_round_presentations", @"recover_agent_attempt",
  ] sortedArrayUsingSelector:@selector(compare:)];
  XCTAssertEqualObjects([self exportedNativeNames], expected);
  id module = [self moduleWithCoordinator:[[DSHRecordingRuntimeCoordinator alloc] init]];
  for (NSString *legacy in @[
    @"createAgentTranscriptRequest:resolver:rejecter:",
    @"validateAgentTranscriptRequest:resolver:rejecter:",
    @"createAgentRoundRequest:resolver:rejecter:",
    @"claimAgentRoundRequest:resolver:rejecter:",
    @"casAgentRoundRequest:resolver:rejecter:",
    @"claimAgentExecutionRequest:resolver:rejecter:",
    @"casAgentExecutionRequest:resolver:rejecter:",
    @"reserveWriteBytesRequest:resolver:rejecter:",
    @"openAgentWriteBatchEffectGateRequest:resolver:rejecter:",
    @"reconcileAgentExecutionRequest:resolver:rejecter:",
  ]) {
    XCTAssertFalse([module respondsToSelector:NSSelectorFromString(legacy)]);
  }
}

- (void)testAllSelectorsMapToOneCoordinatorAndSnapshotRequest {
  NSArray<NSArray<NSString *> *> *bindings = @[
    @[@"prepareAgentAttemptRequest:resolver:rejecter:", @"prepareAgentAttempt"],
    @[@"completeAgentRoundV2Request:resolver:rejecter:", @"completeAgentRoundV2"],
    @[@"prepareAgentToolBatchRequest:resolver:rejecter:", @"prepareAgentToolBatch"],
    @[@"bindAgentApprovalRequest:resolver:rejecter:", @"bindAgentApproval"],
    @[@"executeAgentToolRequest:resolver:rejecter:", @"executeAgentTool"],
    @[@"cancelAgentAttemptRequest:resolver:rejecter:", @"cancelAgentAttempt"],
    @[@"readAgentRoundPresentationsRequest:resolver:rejecter:", @"readAgentRoundPresentations"],
    @[@"queryAgentAttemptRequest:resolver:rejecter:", @"queryAgentAttempt"],
    @[@"queryAgentToolRequest:resolver:rejecter:", @"queryAgentTool"],
    @[@"recoverAgentAttemptRequest:resolver:rejecter:", @"recoverAgentAttempt"],
    @[@"finalizeAgentAttemptRequest:resolver:rejecter:", @"finalizeAgentAttempt"],
    @[@"discardAgentAttemptRequest:resolver:rejecter:", @"discardAgentAttempt"],
    @[@"interruptAgentAttemptRequest:resolver:rejecter:", @"interruptAgentAttempt"],
    @[@"queryAgentCleanupRequest:resolver:rejecter:", @"queryAgentCleanup"],
  ];
  DSHRecordingRuntimeCoordinator *coordinator =
      [[DSHRecordingRuntimeCoordinator alloc] init];
  id module = [self moduleWithCoordinator:coordinator];
  for (NSArray<NSString *> *binding in bindings) {
    XCTestExpectation *done = [self expectationWithDescription:binding[1]];
    NSMutableDictionary *request = [@{ @"schema_version" : @2,
                                       @"marker" : binding[1] } mutableCopy];
    [self invokeModule:module selector:NSSelectorFromString(binding[0])
        request:request resolve:^(id value) {
          XCTAssertEqualObjects(value, coordinator.result);
          XCTAssertEqualObjects(coordinator.method, binding[1]);
          XCTAssertEqualObjects(coordinator.request[@"marker"], binding[1]);
          XCTAssertFalse(coordinator.request == request);
          [done fulfill];
        } reject:^(NSString *code, NSString *message, NSError *error) {
          XCTFail(@"unexpected rejection %@ %@ %@", code, message, error);
          [done fulfill];
        }];
    request[@"marker"] = @"mutated-after-call";
    [self waitForExpectations:@[done] timeout:2];
  }
  XCTAssertEqual(coordinator.callCount, bindings.count);
}

- (void)testInvalidBridgeValueAndUnavailableCoordinatorFailClosed {
  DSHRecordingRuntimeCoordinator *coordinator =
      [[DSHRecordingRuntimeCoordinator alloc] init];
  id module = [self moduleWithCoordinator:coordinator];
  XCTestExpectation *bad = [self expectationWithDescription:@"bad"];
  [self invokeModule:module
      selector:NSSelectorFromString(@"prepareAgentAttemptRequest:resolver:rejecter:")
      request:@[@1] resolve:^(__unused id value) { XCTFail(@"resolved"); }
      reject:^(NSString *code, __unused NSString *message,
               __unused NSError *error) {
        XCTAssertEqualObjects(code, @"E_AGENT_BAD_ARGUMENTS");
        [bad fulfill];
      }];
  [self waitForExpectations:@[bad] timeout:2];
  XCTAssertEqual(coordinator.callCount, 0U);

  coordinator.available = NO;
  XCTestExpectation *unavailable = [self expectationWithDescription:@"unavailable"];
  [self invokeModule:module
      selector:NSSelectorFromString(@"queryAgentCleanupRequest:resolver:rejecter:")
      request:@{ @"schema_version" : @2 }
      resolve:^(__unused id value) { XCTFail(@"resolved"); }
      reject:^(NSString *code, __unused NSString *message,
               __unused NSError *error) {
        XCTAssertEqualObjects(code, @"E_AGENT_NATIVE");
        [unavailable fulfill];
      }];
  [self waitForExpectations:@[unavailable] timeout:2];
}

- (void)testNativeErrorsMapToClosedCodeWithoutLeakingDescription {
  DSHRecordingRuntimeCoordinator *coordinator =
      [[DSHRecordingRuntimeCoordinator alloc] init];
  coordinator.error = DSHAgentNativeStoreError(
      DSHAgentNativeStoreErrorOwnerLost);
  id module = [self moduleWithCoordinator:coordinator];
  XCTestExpectation *done = [self expectationWithDescription:@"rejected"];
  [self invokeModule:module
      selector:NSSelectorFromString(@"executeAgentToolRequest:resolver:rejecter:")
      request:@{ @"schema_version" : @2 }
      resolve:^(__unused id value) { XCTFail(@"resolved"); }
      reject:^(NSString *code, NSString *message, NSError *error) {
        XCTAssertEqualObjects(code, @"E_AGENT_EXECUTION_AMBIGUOUS");
        XCTAssertEqualObjects(message, code);
        XCTAssertNil(error);
        [done fulfill];
      }];
  [self waitForExpectations:@[done] timeout:2];
}

- (void)testRoundPersistenceDiagnosticsExposeOnlyFixedOperationAndKind {
  for (NSString *kind in @[@"persistence", @"unavailable", @"exception", @"unknown"]) {
    DSHRecordingRuntimeCoordinator *coordinator = [[DSHRecordingRuntimeCoordinator alloc] init];
    coordinator.throwsPrivateException = [kind isEqual:@"exception"];
    coordinator.error = [kind isEqual:@"unknown"]
        ? [NSError errorWithDomain:@"private native domain" code:99
                          userInfo:@{NSLocalizedDescriptionKey: @"private path or credential"}]
        : DSHAgentNativeStoreError([kind isEqual:@"unavailable"]
            ? DSHAgentNativeStoreErrorUnavailable : DSHAgentNativeStoreErrorPersistence);
    id module = [self moduleWithCoordinator:coordinator];
    XCTestExpectation *done = [self expectationWithDescription:kind];
    [self invokeModule:module
        selector:NSSelectorFromString(@"completeAgentRoundV2Request:resolver:rejecter:")
        request:@{@"schema_version": @2}
        resolve:^(__unused id value) { XCTFail(@"resolved"); }
        reject:^(NSString *code, NSString *message, NSError *error) {
          XCTAssertEqualObjects(code, @"E_AGENT_PERSISTENCE");
          NSString *expectedMessage = [NSString stringWithFormat:
              @"E_AGENT_PERSISTENCE\nagent_runtime/v1 operation=complete_agent_round_v2 kind=%@", kind];
          XCTAssertEqualObjects(message, expectedMessage);
          XCTAssertNil(error);
          [done fulfill];
        }];
    [self waitForExpectations:@[done] timeout:2];
  }
}

- (void)testContextStorageErrorKeepsItsDomainAndDoesNotLeakDescription {
  DSHRecordingRuntimeCoordinator *coordinator = [[DSHRecordingRuntimeCoordinator alloc] init];
  coordinator.error = [NSError errorWithDomain:@"dev.zseven.rish.project-context-service" code:6
      userInfo:@{NSLocalizedDescriptionKey: @"private context path"}];
  id module = [self moduleWithCoordinator:coordinator];
  XCTestExpectation *done = [self expectationWithDescription:@"context rejected"];
  [self invokeModule:module selector:NSSelectorFromString(@"completeAgentRoundV2Request:resolver:rejecter:")
      request:@{@"schema_version": @2} resolve:^(__unused id value) { XCTFail(@"resolved"); }
      reject:^(NSString *code, NSString *message, NSError *error) {
        XCTAssertEqualObjects(code, @"E_CONTEXT_STORAGE");
        XCTAssertEqualObjects(message, code);
        XCTAssertNil(error);
        [done fulfill];
      }];
  [self waitForExpectations:@[done] timeout:2];
}

- (void)testToolDefinitionValidationErrorsAreBadArgumentsWithoutLeakingDescription {
  for (NSNumber *nativeCode in @[@2001, @2002, @2003, @2004, @2005, @2006, @2007, @2008]) {
    DSHRecordingRuntimeCoordinator *coordinator = [[DSHRecordingRuntimeCoordinator alloc] init];
    coordinator.error = [NSError errorWithDomain:@"DSHCompletionV2Error"
        code:nativeCode.integerValue
        userInfo:@{NSLocalizedDescriptionKey: @"private tool description or path"}];
    id module = [self moduleWithCoordinator:coordinator];
    XCTestExpectation *done = [self expectationWithDescription:nativeCode.stringValue];
    [self invokeModule:module
        selector:NSSelectorFromString(@"completeAgentRoundV2Request:resolver:rejecter:")
        request:@{@"schema_version": @2}
        resolve:^(__unused id value) { XCTFail(@"resolved"); }
        reject:^(NSString *code, NSString *message, NSError *error) {
          XCTAssertEqualObjects(code, @"E_AGENT_BAD_ARGUMENTS");
          XCTAssertEqualObjects(message, code);
          XCTAssertNil(error);
          [done fulfill];
        }];
    [self waitForExpectations:@[done] timeout:2];
  }
}

- (void)testToolDefinitionMappingDoesNotClaimOtherDomainsOrResponseErrors {
  NSArray *cases = @[
    @{@"domain": @"other native domain", @"code": @2006},
    @{@"domain": @"DSHCompletionV2Error", @"code": @2009},
    @{@"domain": @"DSHCompletionV2Error", @"code": @2106},
  ];
  for (NSDictionary *testCase in cases) {
    DSHRecordingRuntimeCoordinator *coordinator = [[DSHRecordingRuntimeCoordinator alloc] init];
    coordinator.error = [NSError errorWithDomain:testCase[@"domain"]
        code:[testCase[@"code"] integerValue]
        userInfo:@{NSLocalizedDescriptionKey: @"private response or path"}];
    id module = [self moduleWithCoordinator:coordinator];
    XCTestExpectation *done = [self expectationWithDescription:@"unclassified error"];
    [self invokeModule:module
        selector:NSSelectorFromString(@"completeAgentRoundV2Request:resolver:rejecter:")
        request:@{@"schema_version": @2}
        resolve:^(__unused id value) { XCTFail(@"resolved"); }
        reject:^(NSString *code, NSString *message, NSError *error) {
          XCTAssertEqualObjects(code, @"E_AGENT_PERSISTENCE");
          XCTAssertEqualObjects(message,
              @"E_AGENT_PERSISTENCE\nagent_runtime/v1 operation=complete_agent_round_v2 kind=unknown");
          XCTAssertNil(error);
          [done fulfill];
        }];
    [self waitForExpectations:@[done] timeout:2];
  }
}

- (void)testCoordinatorRequiresOneWALDomainAndAllHighLevelServices {
  DSHAgentNativeWAL *wal = [[DSHAgentNativeWAL alloc]
      initWithRootURL:self.rootURL clock:^NSDate * { return NSDate.date; }
      identifierGenerator:^NSString * {
        return @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
      } faultHook:nil];
  DSHAgentTranscriptStore *transcripts = [[DSHAgentTranscriptStore alloc]
      initWithWAL:wal];
  DSHAgentRoundJournal *rounds = [[DSHAgentRoundJournal alloc] initWithWAL:wal];
  DSHAgentExecutionLedger *ledger = [[DSHAgentExecutionLedger alloc]
      initWithWAL:wal];
  DSHAgentRootResolver *resolver = [[DSHAgentRootResolver alloc]
      initWithWorkspaceAccess:(DSHLocalWorkspaceAccess *)(id)NSNull.null
      projectAccess:nil];
  DSHSessionSnapshotStore *sessions = [[DSHSessionSnapshotStore alloc]
      initWithRootURL:[self.rootURL URLByAppendingPathComponent:@"sessions"]];
  DSHAgentPreparedAttemptStore *prepared = [[DSHAgentPreparedAttemptStore alloc]
      initWithWAL:wal rootResolver:resolver sessionSnapshotStore:sessions
      transcriptStore:transcripts];
  NSURLSession *session = [NSURLSession sessionWithConfiguration:
      NSURLSessionConfiguration.ephemeralSessionConfiguration];
  DSHCompletionProviderTransport *transport =
      [[DshProviderTransport alloc] initWithSession:session
          uuidGenerator:nil monotonicClock:nil];
  DSHAgentProviderRoundService *roundService = [[DSHAgentProviderRoundService alloc]
      initWithWAL:wal preparedStore:prepared transcripts:transcripts
      rounds:rounds transport:transport
      credentialProvider:^NSString *(NSString *harnessId, NSUInteger *generation) {
        if (generation != nullptr) *generation = 1;
        return @"test-credential";
      }
      visibleHistoryProvider:^NSArray *(NSDictionary *authority,
                                        NSError **error) {
        (void)authority; (void)error;
        return @[];
      }
      contextReceiptProvider:^NSDictionary *(NSDictionary *authority,
                                              NSError **error) {
        (void)authority; (void)error;
        return @{ @"receipt" : @{}, @"messages" : @[] };
      }];
  DSHAgentWorkspaceToolExecutor *workspace = [[DSHAgentWorkspaceToolExecutor alloc]
      initWithRootResolver:resolver];
  DSHAgentGitToolExecutor *git = [[DSHAgentGitToolExecutor alloc]
      initWithRootResolver:resolver];
  DSHAgentToolBatchService *batch = [[DSHAgentToolBatchService alloc]
      initWithWAL:wal ledger:ledger preparedStore:prepared
      transcripts:transcripts workspaceExecutor:workspace gitExecutor:git];
  DSHAgentToolExecutionService *execution = [[DSHAgentToolExecutionService alloc]
      initWithWAL:wal ledger:ledger preparedStore:prepared
      transcripts:transcripts workspaceExecutor:workspace gitExecutor:git];
  DSHAgentRuntimeCoordinator *coordinator = [[DSHAgentRuntimeCoordinator alloc]
      initWithWAL:wal preparedStore:prepared roundService:roundService
      batchService:batch executionService:execution transcripts:transcripts
      rounds:rounds ledger:ledger];
  XCTAssertNotNil(coordinator);
  XCTAssertTrue(coordinator.isAvailable);

  NSURL *splitURL = [self.rootURL URLByAppendingPathComponent:@"split"];
  DSHAgentNativeWAL *splitWAL = [[DSHAgentNativeWAL alloc]
      initWithRootURL:splitURL clock:^NSDate * { return NSDate.date; }
      identifierGenerator:^NSString * {
        return @"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
      } faultHook:nil];
  DSHAgentExecutionLedger *splitLedger = [[DSHAgentExecutionLedger alloc]
      initWithWAL:splitWAL];
  XCTAssertNil([[DSHAgentRuntimeCoordinator alloc]
      initWithWAL:wal preparedStore:prepared roundService:roundService
      batchService:batch executionService:execution transcripts:transcripts
      rounds:rounds ledger:splitLedger]);
  [session invalidateAndCancel];
}

- (NSDictionary *)recoveryControllerCAS {
  return @{ @"schema_version" : @1,
    @"conversation_id" : @"11111111-1111-4111-8111-111111111111",
    @"task_id" : @"22222222-2222-4222-8222-222222222222",
    @"attempt_id" : @"33333333-3333-4333-8333-333333333333",
    @"expected_controller_generation" : @1,
    @"expected_journal_revision" : @1,
    @"expected_session_generation" : @1,
    @"expected_session_sha256" :
        @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" };
}

- (NSDictionary *)recoveryCheckpoint {
  return @{ @"schema_version" : @1, @"journal_revision" : @1,
    @"session_generation" : @1, @"session_sha256" :
        @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" };
}

- (NSDictionary *)recoveryTranscript {
  return @{ @"schema_version" : @1,
    @"transcript_ref" : @"44444444-4444-4444-8444-444444444444",
    @"generation" : @1, @"transcript_sha256" :
        @"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    @"transcript_bytes" : @128 };
}

- (NSDictionary *)recoveryRoot {
  return @{ @"schema_version" : @1, @"kind" : @"workspace",
    @"workspace_id" : @"55555555-5555-4555-8555-555555555555",
    @"workspace_binding_revision" : @1, @"project_id" : NSNull.null,
    @"root_fingerprint_sha256" :
        @"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    @"capabilities" : @[@"file_read"] };
}

- (NSDictionary *)recoveryCancelRequestWithOperationId:(NSString *)operationId {
  return @{ @"schema_version" : @2, @"operation_id" : operationId,
    @"controller_cas" : [self recoveryControllerCAS],
    @"committed_checkpoint" : [self recoveryCheckpoint],
    @"target" : @{ @"schema_version" : @2, @"kind" : @"attempt",
      @"task_id" : @"22222222-2222-4222-8222-222222222222",
      @"attempt_id" : @"33333333-3333-4333-8333-333333333333" },
    @"cancel_token" : @{ @"schema_version" : @2,
      @"issuer" : @"completion_controller",
      @"source_event_id" : @"dddddddd-dddd-4ddd-8ddd-dddddddddddd",
      @"token" : @"dddddddd-dddd-4ddd-8ddd-dddddddddddd",
      @"task_id" : @"22222222-2222-4222-8222-222222222222",
      @"attempt_id" : @"33333333-3333-4333-8333-333333333333",
      @"expected_phase" : @"round_in_flight",
      @"reason_code" : @"E_AGENT_CANCELLED" },
    @"expected_round_revision" : NSNull.null,
    @"expected_execution_revision" : NSNull.null,
    @"expected_transcript" : [self recoveryTranscript],
    @"root" : [self recoveryRoot] };
}

- (NSDictionary *)recoveryToolLocator {
  return @{ @"schema_version" : @2,
    @"task_id" : @"22222222-2222-4222-8222-222222222222",
    @"attempt_id" : @"33333333-3333-4333-8333-333333333333",
    @"round_id" : @"77777777-7777-4777-8777-777777777777",
    @"round_index" : @0, @"call_index" : @0, @"call_id" : @"call-0",
    @"idempotency_key" :
        @"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd" };
}

- (NSDictionary *)recoveryQueryToolRequestWithRevision:(NSNumber *)revision {
  NSDictionary *locator = [self recoveryToolLocator];
  return @{ @"schema_version" : @2,
    @"controller_cas" : [self recoveryControllerCAS],
    @"task_id" : locator[@"task_id"],
    @"conversation_id" : @"11111111-1111-4111-8111-111111111111",
    @"attempt_id" : locator[@"attempt_id"], @"round_id" : locator[@"round_id"],
    @"round_index" : locator[@"round_index"],
    @"call_index" : locator[@"call_index"], @"call_id" : locator[@"call_id"],
    @"idempotency_key" : locator[@"idempotency_key"],
    @"expected_execution_revision" : revision,
    @"expected_transcript" : [self recoveryTranscript],
    @"expected_root_fingerprint_sha256" :
        [self recoveryRoot][@"root_fingerprint_sha256"],
    @"expected_workspace_binding_revision" : @1 };
}

- (NSDictionary *)recoveryQueryAttemptRequest {
  return @{ @"schema_version" : @2,
    @"controller_cas" : [self recoveryControllerCAS],
    @"task_id" : @"22222222-2222-4222-8222-222222222222",
    @"conversation_id" : @"11111111-1111-4111-8111-111111111111",
    @"attempt_id" : @"33333333-3333-4333-8333-333333333333",
    @"expected_journal_revision" : @1, @"expected_session_generation" : @1,
    @"expected_session_sha256" :
        @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    @"expected_transcript" : [self recoveryTranscript],
    @"expected_root_fingerprint_sha256" :
        [self recoveryRoot][@"root_fingerprint_sha256"],
    @"expected_workspace_binding_revision" : @1 };
}

- (void)testRoundPresentationReadIsOwnerBoundAndDoesNotRecover {
  DSHRecoveryWAL *wal = [[DSHRecoveryWAL alloc] initWithRootURL:self.rootURL clock:nil identifierGenerator:nil faultHook:nil];
  wal.recoveryState = @{ @"transcripts": @[], @"rounds": @[] };
  DSHRecoveryRuntimeCoordinator *coordinator = [self recoveryCoordinatorWithWAL:wal roundService:nil executionService:nil];
  NSDictionary *before = wal.recoveryState;
  NSDictionary *request = @{ @"schema_version": @1, @"conversation_id": @"11111111-1111-4111-8111-111111111111", @"attempt_id": @"33333333-3333-4333-8333-333333333333" };
  NSError *error = nil;
  NSDictionary *result = [coordinator readAgentRoundPresentations:request error:&error];
  XCTAssertNil(error); XCTAssertEqualObjects(result[@"rounds"], @[]);
  XCTAssertEqualObjects(wal.recoveryState, before);
  NSMutableDictionary *foreign = [request mutableCopy]; foreign[@"conversation_id"] = @"55555555-5555-4555-8555-555555555555";
  XCTAssertNil([coordinator readAgentRoundPresentations:foreign error:&error]);
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorNotFound);
  XCTAssertEqualObjects(wal.recoveryState, before);
}

- (DSHRecoveryRuntimeCoordinator *)recoveryCoordinatorWithWAL:
    (DSHRecoveryWAL *)wal
    roundService:(DSHRecordingRoundRecoveryService **)roundOut
    executionService:(DSHRecordingToolRecoveryService **)executionOut {
  DSHAgentTranscriptStore *transcripts = [[DSHAgentTranscriptStore alloc]
      initWithWAL:wal];
  DSHAgentExecutionLedger *ledger = [[DSHAgentExecutionLedger alloc]
      initWithWAL:wal];
  DSHRecoverySessionStore *sessionStore = [[DSHRecoverySessionStore alloc]
      initWithRootURL:[self.rootURL URLByAppendingPathComponent:@"recovery-session"]];
  NSDictionary *session = @{ @"schema_version" : @9,
    @"agent_transcript_cleanup_outbox" : @[@{
      @"schema_version" : @1,
      @"cleanup_id" : @"13131313-1313-4313-8313-131313131313",
      @"conversation_id" : @"11111111-1111-4111-8111-111111111111",
      @"task_id" : @"22222222-2222-4222-8222-222222222222",
      @"attempt_id" : @"33333333-3333-4333-8333-333333333333",
      @"transcript_ref" : @"44444444-4444-4444-8444-444444444444",
      @"transcript_sha256" :
          @"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      @"reason" : @"completed", @"created_at" : @"2026-08-31T00:00:00.000Z"
    }],
    @"conversations" : @[@{
    @"id" : @"11111111-1111-4111-8111-111111111111",
    @"attempts" : @[@{ @"attempt_id" : @"33333333-3333-4333-8333-333333333333",
      @"turn_id" : @"22222222-2222-4222-8222-222222222222",
      @"journal_revision" : @1,
      @"agent" : @{ @"controller_generation" : @1,
                      @"phase" : @"round_in_flight",
                      // A query proves the exact committed journal handle;
                      // the recovery mock must carry it just like production.
                      @"transcript" : [self recoveryTranscript] } }] }],
    @"session_events" : @[@{ @"schema_version" : @2,
      @"event_id" : @"dddddddd-dddd-4ddd-8ddd-dddddddddddd", @"seq" : @0,
      @"attempt_id" : @"33333333-3333-4333-8333-333333333333",
      @"kind" : @"cancel", @"status" : @"cancelled",
      @"safe_summary_key" : NSNull.null,
      @"arguments_sha256" : NSNull.null, @"result_sha256" : NSNull.null,
      @"approval_reference" : @"dddddddd-dddd-4ddd-8ddd-dddddddddddd",
      @"failure_code" : @"E_AGENT_CANCELLED",
      @"round_index" : NSNull.null, @"call_id" : NSNull.null,
      @"created_at" : @"2026-08-31T00:00:00.000Z" }] };
  NSData *sessionBytes = [NSJSONSerialization dataWithJSONObject:session
      options:NSJSONWritingSortedKeys error:nil];
  sessionStore.recoveryLoad = @{ @"status" : @"present",
    @"snapshot" : @{ @"generation" : @1, @"session_sha256" :
        @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
    @"session_json" : [[NSString alloc] initWithData:sessionBytes
                                               encoding:NSUTF8StringEncoding] };
  DSHRecoveryPreparedStore *prepared = [[DSHRecoveryPreparedStore alloc]
      initWithWAL:wal
      rootResolver:(DSHAgentRootResolver *)(id)NSNull.null
      sessionSnapshotStore:sessionStore
      transcriptStore:transcripts];
  prepared.recoveryAuthority = @{ @"authority_revision" : @1,
    @"conversation_id" : @"11111111-1111-4111-8111-111111111111",
    @"state" : @"prepared", @"cleanup_id" : NSNull.null,
    @"root" : [self recoveryRoot], @"transcript" : [self recoveryTranscript],
    @"transport_schema_version" : @2, @"model" : @"deepseek-v4-flash",
    @"thinking_mode" : @"off", @"visible_history_sha256" :
        @"abababababababababababababababababababababababababababababababab",
    @"visible_message_count" : @0, @"project_context_sha256" : NSNull.null,
    @"registry" : @{ @"registry_version" : @1, @"toolset_sha256" :
        @"cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd" } };
  prepared.preparedProjection = @{ @"task_id" : @"22222222-2222-4222-8222-222222222222",
    @"conversation_id" : @"11111111-1111-4111-8111-111111111111",
    @"attempt_id" : @"33333333-3333-4333-8333-333333333333",
    @"transcript" : [self recoveryTranscript], @"root" : [self recoveryRoot],
    @"journal_revision" : @1 };
  DSHAgentRoundJournal *rounds = [[DSHAgentRoundJournal alloc] initWithWAL:wal];
  DSHRecordingRoundRecoveryService *round =
      [[DSHRecordingRoundRecoveryService alloc]
          initWithWAL:wal preparedStore:prepared
          transcripts:transcripts rounds:rounds
          transport:(DSHCompletionProviderTransport *)(id)NSNull.null
          credentialProvider:nil visibleHistoryProvider:nil
          contextReceiptProvider:nil];
  DSHRecordingToolRecoveryService *execution =
      [[DSHRecordingToolRecoveryService alloc]
          initWithWAL:wal ledger:ledger
          preparedStore:prepared
          transcripts:transcripts
          workspaceExecutor:(DSHAgentWorkspaceToolExecutor *)(id)NSNull.null
          gitExecutor:(DSHAgentGitToolExecutor *)(id)NSNull.null];
  DSHRecoveryRuntimeCoordinator *coordinator =
      [[DSHRecoveryRuntimeCoordinator alloc]
          initForRecoveryTestingWithWAL:wal
          preparedStore:prepared
          roundService:round executionService:execution
          transcripts:transcripts ledger:ledger];
  coordinator.attemptQueryResult = @{ @"schema_version" : @2,
    @"status" : @"active", @"attempt" : @{
      @"task_id" : @"22222222-2222-4222-8222-222222222222",
      @"attempt_id" : @"33333333-3333-4333-8333-333333333333" } };
  if (roundOut != nullptr) *roundOut = round;
  if (executionOut != nullptr) *executionOut = execution;
  return coordinator;
}

- (void)testRoundRecoveryUsesNativeStateAndReturnsCompletedProjection {
  DSHRecoveryWAL *wal = [[DSHRecoveryWAL alloc]
      initWithRootURL:[self.rootURL URLByAppendingPathComponent:@"round-recovery"]
      clock:^NSDate * { return NSDate.date; }
      identifierGenerator:^NSString * {
        return @"66666666-6666-4666-8666-666666666666";
      } faultHook:nil];
  wal.recoveryState = @{ @"ledger" : @[], @"batches" : @[],
                         @"operation_results" : @[] };
  DSHRecordingRoundRecoveryService *round = nil;
  DSHRecoveryRuntimeCoordinator *coordinator =
      [self recoveryCoordinatorWithWAL:wal roundService:&round
          executionService:nullptr];
  NSDictionary *completed = @{ @"schema_version" : @2, @"kind" : @"final",
    @"task_id" : @"22222222-2222-4222-8222-222222222222",
    @"attempt_id" : @"33333333-3333-4333-8333-333333333333",
    @"round_id" : @"77777777-7777-4777-8777-777777777777",
    @"round_index" : @0, @"result_round_revision" : @4 };
  round.recoveryResult = @{ @"schema_version" : @2, @"status" : @"completed",
    @"result_round_revision" : @4, @"completed_round" : completed };
  NSError *error = nil;
  NSDictionary *result = [coordinator recoverAgentAttempt:@{
    @"schema_version" : @2,
    @"operation_id" : @"88888888-8888-4888-8888-888888888888",
    @"controller_cas" : [self recoveryControllerCAS],
    @"committed_checkpoint" : [self recoveryCheckpoint],
    @"target" : @{ @"schema_version" : @2, @"kind" : @"round",
      @"task_id" : @"22222222-2222-4222-8222-222222222222",
      @"attempt_id" : @"33333333-3333-4333-8333-333333333333",
      @"round_id" : @"77777777-7777-4777-8777-777777777777",
      @"round_index" : @0 },
    @"action" : @"reconcile", @"expected_round_revision" : @4,
    @"expected_execution_revision" : NSNull.null,
    @"expected_transcript" : [self recoveryTranscript],
    @"root" : [self recoveryRoot] } error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(round.receivedRecoveryRequest[@"expected_round_revision"], @4);
  XCTAssertEqualObjects(result[@"status"], @"resumed");
  XCTAssertEqualObjects(result[@"next_action"], @"persist_final");
  XCTAssertEqualObjects(result[@"completed_round"], completed);
}

- (void)testRetryFailedRoundUsesSameLineageAndLaunchAttemptPlusOne {
  DSHRecoveryWAL *wal = [[DSHRecoveryWAL alloc]
      initWithRootURL:[self.rootURL URLByAppendingPathComponent:@"round-retry"]
      clock:^NSDate * { return NSDate.date; }
      identifierGenerator:^NSString * {
        return @"16161616-1616-4616-8616-161616161616";
      } faultHook:nil];
  NSDictionary *locator = @{ @"schema_version" : @2,
    @"task_id" : @"22222222-2222-4222-8222-222222222222",
    @"attempt_id" : @"33333333-3333-4333-8333-333333333333",
    @"round_id" : @"77777777-7777-4777-8777-777777777777",
    @"round_index" : @0 };
  wal.recoveryState = @{ @"ledger" : @[], @"batches" : @[],
    @"operations" : @[], @"operation_results" : @[],
    @"rounds" : @[@{ @"locator" : locator, @"state" : @"failed_retryable",
                       @"row_revision" : @4, @"launch_attempt" : @1 }] };
  DSHRecordingRoundRecoveryService *round = nil;
  DSHRecoveryRuntimeCoordinator *coordinator =
      [self recoveryCoordinatorWithWAL:wal roundService:&round
          executionService:nullptr];
  round.recoveryResult = @{ @"schema_version" : @2,
    @"status" : @"failed_retryable", @"result_round_revision" : @4 };
  round.retryResult = @{ @"schema_version" : @2,
    @"status" : @"failed_retryable", @"result_round_revision" : @5 };
  NSError *error = nil;
  NSDictionary *result = [coordinator recoverAgentAttempt:@{
    @"schema_version" : @2,
    @"operation_id" : @"17171717-1717-4717-8717-171717171717",
    @"controller_cas" : [self recoveryControllerCAS],
    @"committed_checkpoint" : [self recoveryCheckpoint],
    @"target" : @{ @"schema_version" : @2, @"kind" : @"round",
      @"task_id" : locator[@"task_id"], @"attempt_id" : locator[@"attempt_id"],
      @"round_id" : locator[@"round_id"], @"round_index" : @0 },
    @"action" : @"retry_failed_round", @"expected_round_revision" : @4,
    @"expected_execution_revision" : NSNull.null,
    @"expected_transcript" : [self recoveryTranscript],
    @"root" : [self recoveryRoot] } error:&error];
  XCTAssertNil(error);
  XCTAssertFalse(round.retryOnTransactionQueue);
  XCTAssertEqualObjects(round.receivedRetryRequest[@"round_id"],
                        locator[@"round_id"]);
  XCTAssertEqualObjects(round.receivedRetryRequest[@"launch_attempt"], @2);
  XCTAssertEqualObjects(round.receivedRetryRequest[@"expected_round_revision"], @4);
  XCTAssertEqualObjects(result[@"status"], @"retryable");
  XCTAssertEqualObjects(result[@"next_action"], @"retry_same_round");
}

- (void)testToolRecoveryCallsExecutionServiceWithFrozenBatchFacts {
  DSHRecoveryWAL *wal = [[DSHRecoveryWAL alloc]
      initWithRootURL:[self.rootURL URLByAppendingPathComponent:@"tool-recovery"]
      clock:^NSDate * { return NSDate.date; }
      identifierGenerator:^NSString * {
        return @"99999999-9999-4999-8999-999999999999";
      } faultHook:nil];
  NSString *key = @"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
  NSDictionary *locator = @{ @"schema_version" : @2,
    @"task_id" : @"22222222-2222-4222-8222-222222222222",
    @"attempt_id" : @"33333333-3333-4333-8333-333333333333",
    @"round_id" : @"77777777-7777-4777-8777-777777777777",
    @"round_index" : @0, @"call_index" : @0, @"call_id" : @"call-0",
    @"idempotency_key" : key };
  NSDictionary *batch = @{ @"task_id" : locator[@"task_id"],
    @"attempt_id" : locator[@"attempt_id"], @"round_id" : locator[@"round_id"],
    @"round_index" : @0, @"kind" : @"read_only_batch", @"batch_revision" : @1,
    @"manifest_sha256" : NSNull.null };
  wal.recoveryState = @{ @"ledger" : @[@{ @"locator" : locator,
      @"row_revision" : @2,
      @"name" : @"read_file", @"arguments_sha256" :
          @"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" }],
    @"batches" : @[batch], @"operation_results" : @[@{
      @"result" : @{ @"result_kind" : @"prepare_agent_tool_batch",
        @"result" : @{ @"receipt" : @{
        @"task_id" : locator[@"task_id"], @"attempt_id" : locator[@"attempt_id"],
        @"round_id" : locator[@"round_id"], @"batch_revision" : @1,
        @"calls" : @[@{ @"call_index" : @0, @"call_id" : @"call-0",
                          @"approval_reference" : NSNull.null }] } } } } ] };
  DSHRecordingToolRecoveryService *execution = nil;
  DSHRecoveryRuntimeCoordinator *coordinator =
      [self recoveryCoordinatorWithWAL:wal roundService:nullptr
          executionService:&execution];
  execution.recoveryResult = @{ @"schema_version" : @2,
                                 @"status" : @"completed" };
  NSString *recoverOperationId = @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
  NSError *error = nil;
  NSDictionary *result = [coordinator recoverAgentAttempt:@{
    @"schema_version" : @2,
    @"operation_id" : recoverOperationId,
    @"controller_cas" : [self recoveryControllerCAS],
    @"committed_checkpoint" : [self recoveryCheckpoint],
    @"target" : @{ @"schema_version" : @2, @"kind" : @"tool",
      @"task_id" : locator[@"task_id"], @"attempt_id" : locator[@"attempt_id"],
      @"round_id" : locator[@"round_id"], @"round_index" : @0,
      @"call_index" : @0, @"call_id" : @"call-0", @"idempotency_key" : key },
    @"action" : @"reconcile", @"expected_round_revision" : NSNull.null,
    @"expected_execution_revision" : @2,
    @"expected_transcript" : [self recoveryTranscript],
    @"root" : [self recoveryRoot] } error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(execution.receivedRecoveryRequest[@"name"], @"read_file");
  XCTAssertEqualObjects(execution.receivedRecoveryRequest[@"batch_kind"],
                        @"read_only_batch");
  XCTAssertEqualObjects(execution.receivedRecoveryRequest
      [@"expected_execution_revision"], @2);
  XCTAssertNotEqualObjects(execution.receivedRecoveryRequest[@"operation_id"],
                           recoverOperationId);
  XCTAssertEqualObjects(result[@"status"], @"resumed");
  XCTAssertEqualObjects(result[@"next_action"], @"persist_tool_result");
  XCTAssertEqualObjects(result[@"completed_round"], NSNull.null);
  NSPredicate *toolOperations = [NSPredicate predicateWithBlock:
      ^BOOL(NSDictionary *operation, NSDictionary *bindings) {
    (void)bindings;
    return [operation[@"operation_kind"] isEqualToString:@"execute_agent_tool"];
  }];
  NSArray *children = [wal.recoveryState[@"operations"]
      filteredArrayUsingPredicate:toolOperations];
  XCTAssertEqual(children.count, 1U);
  XCTAssertEqualObjects(children[0][@"state"], @"committed");
}

- (void)testCancelAttemptCommitsAndReplaysOneImmutableOperation {
  DSHRecoveryWAL *wal = [[DSHRecoveryWAL alloc]
      initWithRootURL:[self.rootURL URLByAppendingPathComponent:@"cancel-replay"]
      clock:^NSDate * { return NSDate.date; }
      identifierGenerator:^NSString * {
        return @"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
      } faultHook:nil];
  wal.recoveryState = @{ @"ledger" : @[], @"rounds" : @[], @"batches" : @[],
    @"operations" : @[], @"operation_results" : @[] };
  DSHRecoveryRuntimeCoordinator *coordinator =
      [self recoveryCoordinatorWithWAL:wal roundService:nullptr
          executionService:nullptr];
  NSDictionary *request = [self recoveryCancelRequestWithOperationId:
      @"cccccccc-cccc-4ccc-8ccc-cccccccccccc"];
  NSError *error = nil;
  NSDictionary *first = [coordinator cancelAgentAttempt:request error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(first[@"status"], @"unknown");
  DSHRecoverySessionStore *sessionStore =
      (DSHRecoverySessionStore *)coordinator.preparedStore.sessionSnapshotStore;
  sessionStore.recoveryLoad = @{ @"status" : @"missing" };
  NSDictionary *replay = [coordinator cancelAgentAttempt:request error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(replay, first);
  XCTAssertEqual([wal.recoveryState[@"operations"] count], 1U);
  XCTAssertEqual([wal.recoveryState[@"operation_results"] count], 1U);
}

- (void)testCancelPreparedAttemptWithoutRoundCommitsAndReplays {
  DSHRecoveryWAL *wal = [[DSHRecoveryWAL alloc]
      initWithRootURL:[self.rootURL URLByAppendingPathComponent:@"cancel-unstarted"]
      clock:^NSDate * { return NSDate.date; }
      identifierGenerator:^NSString * { return @"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"; }
      faultHook:nil];
  wal.recoveryState = @{ @"ledger": @[], @"rounds": @[], @"batches": @[],
    @"operations": @[], @"operation_results": @[] };
  DSHRecoveryRuntimeCoordinator *coordinator = [self recoveryCoordinatorWithWAL:wal
      roundService:nullptr executionService:nullptr];
  DSHRecoverySessionStore *store = (DSHRecoverySessionStore *)coordinator.preparedStore.sessionSnapshotStore;
  NSMutableDictionary *load = [store.recoveryLoad mutableCopy];
  NSData *bytes = [load[@"session_json"] dataUsingEncoding:NSUTF8StringEncoding];
  NSMutableDictionary *session = [NSJSONSerialization JSONObjectWithData:bytes
      options:NSJSONReadingMutableContainers error:nil];
  session[@"conversations"][0][@"attempts"][0][@"agent"][@"phase"] = @"ready_for_round";
  load[@"session_json"] = [[NSString alloc] initWithData:
      [NSJSONSerialization dataWithJSONObject:session options:NSJSONWritingSortedKeys error:nil]
      encoding:NSUTF8StringEncoding];
  store.recoveryLoad = load;
  NSMutableDictionary *request = [[self recoveryCancelRequestWithOperationId:
      @"cccccccc-cccc-4ccc-8ccc-cccccccccccc"] mutableCopy];
  NSMutableDictionary *token = [request[@"cancel_token"] mutableCopy];
  token[@"expected_phase"] = @"ready_for_round";
  request[@"cancel_token"] = token;
  NSError *error = nil;
  NSDictionary *result = [coordinator cancelAgentAttempt:request error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"cancelled");
  XCTAssertEqualObjects(result[@"result_round_revision"], NSNull.null);
  XCTAssertEqualObjects(result[@"effect_may_have_occurred"], @NO);
  store.recoveryLoad = @{ @"status": @"missing" };
  XCTAssertEqualObjects([coordinator cancelAgentAttempt:request error:&error], result);
  XCTAssertNil(error);
  XCTAssertEqual([wal.recoveryState[@"operations"] count], 1U);
  XCTAssertEqual([wal.recoveryState[@"rounds"] count], 0U);
}

- (void)testCancelAttemptRejectsUnboundSchemaNineSourceProofs {
  DSHRecoveryWAL *wal = [[DSHRecoveryWAL alloc]
      initWithRootURL:[self.rootURL URLByAppendingPathComponent:@"cancel-source-proof"]
      clock:^NSDate * { return NSDate.date; }
      identifierGenerator:^NSString * {
        return @"23232323-2323-4323-8323-232323232323";
      } faultHook:nil];
  wal.recoveryState = @{ @"ledger" : @[], @"rounds" : @[], @"batches" : @[],
    @"operations" : @[], @"operation_results" : @[] };
  DSHRecoveryRuntimeCoordinator *coordinator =
      [self recoveryCoordinatorWithWAL:wal roundService:nullptr
          executionService:nullptr];
  NSArray<NSString *> *operationIds = @[
    @"24242424-2424-4424-8424-242424242424",
    @"25252525-2525-4525-8525-252525252525",
    @"26262626-2626-4626-8626-262626262626",
    @"27272727-2727-4727-8727-272727272727",
  ];
  for (NSUInteger index = 0; index < operationIds.count; index += 1) {
    NSMutableDictionary *request = [[self
        recoveryCancelRequestWithOperationId:operationIds[index]] mutableCopy];
    NSMutableDictionary *token = [request[@"cancel_token"] mutableCopy];
    if (index == 0) {
      token[@"source_event_id"] = @"28282828-2828-4828-8828-282828282828";
      token[@"token"] = token[@"source_event_id"];
    } else if (index == 1) {
      token[@"expected_phase"] = @"approval_pending";
    } else if (index == 2) {
      token[@"reason_code"] = @"E_AGENT_ROOT_STALE";
    } else {
      request[@"target"] = @{ @"schema_version" : @2, @"kind" : @"round",
        @"task_id" : token[@"task_id"], @"attempt_id" : token[@"attempt_id"],
        @"round_id" : @"77777777-7777-4777-8777-777777777777",
        @"round_index" : @0 };
      request[@"expected_round_revision"] = @1;
    }
    request[@"cancel_token"] = [token copy];
    NSError *error = nil;
    NSDictionary *result = [coordinator cancelAgentAttempt:[request copy]
                                                       error:&error];
    XCTAssertNil(error);
    XCTAssertEqualObjects(result[@"status"], @"conflict");
    XCTAssertEqualObjects(result[@"failure_code"], @"E_AGENT_CANCELLED");
    XCTAssertEqual([wal.recoveryState[@"operations"] count], 0U);
  }
}

- (void)testQueriesUseActualSessionControllerAndExactRootExpectation {
  DSHRecoveryWAL *wal = [[DSHRecoveryWAL alloc]
      initWithRootURL:[self.rootURL URLByAppendingPathComponent:@"query-proof"]
      clock:^NSDate * { return NSDate.date; }
      identifierGenerator:^NSString * {
        return @"ffffffff-ffff-4fff-8fff-ffffffffffff";
      } faultHook:nil];
  wal.recoveryState = @{ @"rounds" : @[], @"batches" : @[],
    @"authorities" : @[], @"ledger" : @[], @"operations" : @[],
    @"operation_results" : @[] };
  DSHRecoveryRuntimeCoordinator *fixture =
      [self recoveryCoordinatorWithWAL:wal roundService:nullptr
          executionService:nullptr];
  DSHRecordingQueryLedger *queryLedger = [[DSHRecordingQueryLedger alloc]
      initWithWAL:wal];
  NSDictionary *locator = [self recoveryToolLocator];
  queryLedger.queryResult = @{ @"status" : @"intent", @"row" : @{
    @"locator" : locator, @"row_revision" : @2, @"name" : @"read_file",
    @"arguments_sha256" :
        @"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    @"state" : @"intent", @"transcript_before" : [self recoveryTranscript],
    @"transcript_after" : NSNull.null, @"receipt" : NSNull.null } };
  DSHAgentRuntimeCoordinator *coordinator = [[DSHAgentRuntimeCoordinator alloc]
      initForRecoveryTestingWithWAL:wal preparedStore:fixture.preparedStore
      roundService:fixture.roundService executionService:fixture.executionService
      transcripts:fixture.transcripts ledger:queryLedger];
  NSError *error = nil;
  NSDictionary *attemptRequest = @{
    @"schema_version" : @2, @"controller_cas" : [self recoveryControllerCAS],
    @"task_id" : locator[@"task_id"],
    @"conversation_id" : @"11111111-1111-4111-8111-111111111111",
    @"attempt_id" : locator[@"attempt_id"], @"expected_journal_revision" : @1,
    @"expected_session_generation" : @1, @"expected_session_sha256" :
        @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    @"expected_transcript" : [self recoveryTranscript],
    @"expected_root_fingerprint_sha256" : [self recoveryRoot][@"root_fingerprint_sha256"],
    @"expected_workspace_binding_revision" : @1 };
  NSDictionary *attemptResult = [coordinator queryAgentAttempt:attemptRequest error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(attemptResult[@"attempt"][@"controller_generation"], @1);
  NSMutableDictionary *forgedQuery = [attemptRequest mutableCopy];
  NSMutableDictionary *forgedTranscript = [[self recoveryTranscript] mutableCopy];
  forgedTranscript[@"transcript_sha256"] =
      @"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
  forgedQuery[@"expected_transcript"] = [forgedTranscript copy];
  NSDictionary *forgedResult = [coordinator queryAgentAttempt:forgedQuery error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(forgedResult[@"status"], @"conflict");

  NSDictionary *toolResult = [coordinator queryAgentTool:@{
    @"schema_version" : @2, @"controller_cas" : [self recoveryControllerCAS],
    @"task_id" : locator[@"task_id"],
    @"conversation_id" : @"11111111-1111-4111-8111-111111111111",
    @"attempt_id" : locator[@"attempt_id"], @"round_id" : locator[@"round_id"],
    @"round_index" : @0, @"call_index" : @0, @"call_id" : @"call-0",
    @"idempotency_key" : locator[@"idempotency_key"],
    @"expected_execution_revision" : @2,
    @"expected_transcript" : [self recoveryTranscript],
    @"expected_root_fingerprint_sha256" : [self recoveryRoot][@"root_fingerprint_sha256"],
    @"expected_workspace_binding_revision" : @1 } error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(toolResult[@"status"], @"intent");
  XCTAssertEqualObjects(queryLedger.receivedRootExpectation, (@{
    @"schema_version" : @1,
    @"root_fingerprint_sha256" : [self recoveryRoot][@"root_fingerprint_sha256"],
    @"binding_revision" : @1 }));

  DSHRecoverySessionStore *sessionStore =
      (DSHRecoverySessionStore *)fixture.preparedStore.sessionSnapshotStore;
  NSMutableDictionary *load = [sessionStore.recoveryLoad mutableCopy];
  NSDictionary *changedSession = @{ @"schema_version" : @9,
    @"conversations" : @[@{
    @"id" : @"11111111-1111-4111-8111-111111111111",
    @"attempts" : @[@{ @"attempt_id" : locator[@"attempt_id"],
      @"turn_id" : locator[@"task_id"], @"journal_revision" : @1,
      @"agent" : @{ @"controller_generation" : @2 } }] }],
    @"session_events" : @[] };
  load[@"session_json"] = [[NSString alloc] initWithData:
      [NSJSONSerialization dataWithJSONObject:changedSession
          options:NSJSONWritingSortedKeys error:nil]
      encoding:NSUTF8StringEncoding];
  sessionStore.recoveryLoad = load;
  NSDictionary *conflict = [coordinator queryAgentAttempt:@{
    @"schema_version" : @2, @"controller_cas" : [self recoveryControllerCAS],
    @"task_id" : locator[@"task_id"],
    @"conversation_id" : @"11111111-1111-4111-8111-111111111111",
    @"attempt_id" : locator[@"attempt_id"], @"expected_journal_revision" : @1,
    @"expected_session_generation" : @1, @"expected_session_sha256" :
        @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    @"expected_transcript" : [self recoveryTranscript],
    @"expected_root_fingerprint_sha256" : [self recoveryRoot][@"root_fingerprint_sha256"],
    @"expected_workspace_binding_revision" : @1 } error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(conflict[@"status"], @"conflict");
}

- (void)testQueryToolPositiveRevisionAbsentReturnsClosedConflict {
  DSHRecoveryWAL *wal = [[DSHRecoveryWAL alloc]
      initWithRootURL:[self.rootURL URLByAppendingPathComponent:@"query-absent"]
      clock:^NSDate * { return NSDate.date; }
      identifierGenerator:^NSString * {
        return @"29292929-2929-4929-8929-292929292929";
      } faultHook:nil];
  wal.recoveryState = @{ @"rounds" : @[], @"batches" : @[],
    @"authorities" : @[], @"ledger" : @[], @"operations" : @[],
    @"operation_results" : @[] };
  DSHRecoveryRuntimeCoordinator *coordinator =
      [self recoveryCoordinatorWithWAL:wal roundService:nullptr
          executionService:nullptr];
  NSError *error = nil;
  NSDictionary *positive = [coordinator queryAgentTool:
      [self recoveryQueryToolRequestWithRevision:@2] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(positive[@"status"], @"conflict");
  XCTAssertEqualObjects(positive[@"failure_code"], @"E_AGENT_CONFLICT");
  XCTAssertEqualObjects(positive[@"expected_execution_revision"], @2);
  XCTAssertEqualObjects(positive[@"actual_execution_revision"], @0);

  NSDictionary *zero = [coordinator queryAgentTool:
      [self recoveryQueryToolRequestWithRevision:@0] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(zero, (@{ @"schema_version" : @2,
                                  @"status" : @"not_started" }));
}

- (void)testQueryToolLedgerCASMismatchReturnsClosedConflict {
  DSHRecoveryWAL *wal = [[DSHRecoveryWAL alloc]
      initWithRootURL:[self.rootURL URLByAppendingPathComponent:@"query-cas"]
      clock:^NSDate * { return NSDate.date; }
      identifierGenerator:^NSString * {
        return @"30303030-3030-4030-8030-303030303030";
      } faultHook:nil];
  NSDictionary *locator = [self recoveryToolLocator];
  wal.recoveryState = @{ @"rounds" : @[], @"batches" : @[],
    @"authorities" : @[], @"operations" : @[], @"operation_results" : @[],
    @"ledger" : @[@{ @"locator" : locator, @"row_revision" : @3,
      @"root_fingerprint_sha256" :
          @"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
      @"binding_revision" : @1,
      @"transcript_before" : [self recoveryTranscript] }] };
  DSHRecoveryRuntimeCoordinator *coordinator =
      [self recoveryCoordinatorWithWAL:wal roundService:nullptr
          executionService:nullptr];
  NSError *error = nil;
  NSDictionary *rootConflict = [coordinator queryAgentTool:
      [self recoveryQueryToolRequestWithRevision:@3] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(rootConflict[@"status"], @"conflict");
  XCTAssertEqualObjects(rootConflict[@"failure_code"], @"E_AGENT_ROOT_STALE");
  XCTAssertEqualObjects(rootConflict[@"actual_execution_revision"], @3);

  NSMutableDictionary *wrongTranscript = [[self recoveryTranscript] mutableCopy];
  wrongTranscript[@"transcript_sha256"] =
      @"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
  NSMutableDictionary *state = [wal.recoveryState mutableCopy];
  state[@"ledger"] = @[@{ @"locator" : locator, @"row_revision" : @4,
    @"root_fingerprint_sha256" : [self recoveryRoot][@"root_fingerprint_sha256"],
    @"binding_revision" : @1,
    @"transcript_before" : [wrongTranscript copy] }];
  wal.recoveryState = [state copy];
  NSDictionary *transcriptConflict = [coordinator queryAgentTool:
      [self recoveryQueryToolRequestWithRevision:@4] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(transcriptConflict[@"status"], @"conflict");
  XCTAssertEqualObjects(transcriptConflict[@"failure_code"],
                        @"E_AGENT_TRANSCRIPT");
  XCTAssertEqualObjects(transcriptConflict[@"actual_execution_revision"], @4);
}

- (void)testQueryAttemptRootConflictUsesActualSessionRevision {
  DSHRecoveryWAL *wal = [[DSHRecoveryWAL alloc]
      initWithRootURL:[self.rootURL URLByAppendingPathComponent:@"query-attempt-root"]
      clock:^NSDate * { return NSDate.date; }
      identifierGenerator:^NSString * {
        return @"33333333-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
      } faultHook:nil];
  wal.recoveryState = @{ @"rounds" : @[], @"batches" : @[],
    @"authorities" : @[], @"ledger" : @[], @"operations" : @[],
    @"operation_results" : @[] };
  DSHRecoveryRuntimeCoordinator *fixture =
      [self recoveryCoordinatorWithWAL:wal roundService:nullptr
          executionService:nullptr];
  DSHAgentRuntimeCoordinator *coordinator = [[DSHAgentRuntimeCoordinator alloc]
      initForRecoveryTestingWithWAL:wal preparedStore:fixture.preparedStore
      roundService:fixture.roundService executionService:fixture.executionService
      transcripts:fixture.transcripts ledger:fixture.ledger];
  DSHRecoveryPreparedStore *prepared =
      (DSHRecoveryPreparedStore *)coordinator.preparedStore;
  NSMutableDictionary *projection = [prepared.preparedProjection mutableCopy];
  NSMutableDictionary *wrongRoot = [[self recoveryRoot] mutableCopy];
  wrongRoot[@"root_fingerprint_sha256"] =
      @"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
  projection[@"root"] = [wrongRoot copy];
  projection[@"journal_revision"] = @99;
  prepared.preparedProjection = [projection copy];

  NSError *error = nil;
  NSDictionary *result = [coordinator queryAgentAttempt:
      [self recoveryQueryAttemptRequest] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"conflict");
  XCTAssertEqualObjects(result[@"failure_code"], @"E_AGENT_ROOT_STALE");
  XCTAssertEqualObjects(result[@"expected_journal_revision"], @1);
  XCTAssertEqualObjects(result[@"actual_journal_revision"], @1);
  XCTAssertEqualObjects(result[@"actual_session_generation"], @1);
}

- (void)testFinalizeAndDiscardAtomicallyTransitionAndPreserveReplayEvidence {
  DSHRecoveryWAL *wal = [[DSHRecoveryWAL alloc]
      initWithRootURL:[self.rootURL URLByAppendingPathComponent:@"finalize-discard"]
      clock:^NSDate * { return NSDate.date; }
      identifierGenerator:^NSString * {
        return @"12121212-1212-4212-8212-121212121212";
      } faultHook:nil];
  NSDictionary *authority = @{ @"task_id" : @"22222222-2222-4222-8222-222222222222",
    @"conversation_id" : @"11111111-1111-4111-8111-111111111111",
    @"attempt_id" : @"33333333-3333-4333-8333-333333333333",
    @"root" : [self recoveryRoot], @"transcript" : [self recoveryTranscript],
    @"state" : @"prepared", @"cleanup_id" : NSNull.null,
    @"authority_revision" : @1, @"updated_at" : @"2026-08-31T00:00:00.000Z" };
  NSDictionary *transcriptRow = @{
    @"transcript_ref" : [self recoveryTranscript][@"transcript_ref"],
    @"attempt_id" : authority[@"attempt_id"],
    @"transcript_sha256" : [self recoveryTranscript][@"transcript_sha256"],
    @"state" : @"open", @"retention_until" : NSNull.null,
    @"updated_at" : @"2026-08-31T00:00:00.000Z" };
  wal.recoveryState = @{ @"authorities" : @[authority],
    @"transcripts" : @[transcriptRow], @"cleanup" : @[], @"rounds" : @[],
    @"ledger" : @[], @"reservations" : @[], @"batches" : @[],
    @"denied_calls" : @[], @"dispatch" : @[], @"operations" : @[],
    @"operation_results" : @[] };
  DSHRecoveryRuntimeCoordinator *fixture =
      [self recoveryCoordinatorWithWAL:wal roundService:nullptr
          executionService:nullptr];
  DSHAgentRuntimeCoordinator *coordinator = [[DSHAgentRuntimeCoordinator alloc]
      initForRecoveryTestingWithWAL:wal preparedStore:fixture.preparedStore
      roundService:fixture.roundService executionService:fixture.executionService
      transcripts:fixture.transcripts ledger:fixture.ledger];
  NSString *cleanupId = @"13131313-1313-4313-8313-131313131313";
  NSDictionary *finalizeRequest = @{ @"schema_version" : @2,
    @"operation_id" : @"14141414-1414-4414-8414-141414141414",
    @"controller_cas" : [self recoveryControllerCAS],
    @"committed_checkpoint" : [self recoveryCheckpoint],
    @"task_id" : authority[@"task_id"],
    @"conversation_id" : authority[@"conversation_id"],
    @"attempt_id" : authority[@"attempt_id"], @"terminal_reason" : @"completed",
    @"cleanup_id" : cleanupId, @"transcript" : [self recoveryTranscript],
    @"root" : [self recoveryRoot] };
  NSError *error = nil;
  NSDictionary *finalized = [coordinator finalizeAgentAttempt:finalizeRequest
                                                          error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(finalized[@"status"], @"terminal");
  XCTAssertEqualObjects(wal.recoveryState[@"authorities"][0][@"state"],
                        @"cleanup_pending");
  XCTAssertEqualObjects(wal.recoveryState[@"cleanup"][0][@"status"], @"pending");
  XCTAssertEqual([wal.recoveryState[@"operations"] count], 1U);
  NSNumber *terminalRevision =
      wal.recoveryState[@"authorities"][0][@"authority_revision"];
  DSHRecoveryPreparedStore *prepared =
      (DSHRecoveryPreparedStore *)fixture.preparedStore;
  prepared.recoveryAuthority = wal.recoveryState[@"authorities"][0];
  NSMutableDictionary *secondFinalizeRequest = [finalizeRequest mutableCopy];
  secondFinalizeRequest[@"operation_id"] =
      @"18181818-1818-4818-8818-181818181818";
  NSDictionary *alreadyTerminal = [coordinator
      finalizeAgentAttempt:[secondFinalizeRequest copy] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(alreadyTerminal[@"status"], @"already_terminal");
  XCTAssertEqualObjects(
      wal.recoveryState[@"authorities"][0][@"authority_revision"],
      terminalRevision);
  XCTAssertEqual([wal.recoveryState[@"operations"] count], 2U);

  NSDictionary *discardRequest = @{ @"schema_version" : @2,
    @"operation_id" : @"15151515-1515-4515-8515-151515151515",
    @"cleanup_id" : cleanupId, @"task_id" : authority[@"task_id"],
    @"conversation_id" : authority[@"conversation_id"],
    @"attempt_id" : authority[@"attempt_id"],
    @"transcript_ref" : [self recoveryTranscript][@"transcript_ref"],
    @"transcript_sha256" : [self recoveryTranscript][@"transcript_sha256"] };
  NSDictionary *discarded = [coordinator discardAgentAttempt:discardRequest
                                                        error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(discarded[@"status"], @"discarded");
  XCTAssertEqual([wal.recoveryState[@"authorities"] count], 0U);
  XCTAssertEqual([wal.recoveryState[@"transcripts"] count], 0U);
  XCTAssertEqualObjects(wal.recoveryState[@"cleanup"][0][@"status"],
                        @"discarded");
  XCTAssertEqual([wal.recoveryState[@"operations"] count], 1U);
  XCTAssertEqualObjects(wal.recoveryState[@"operations"][0][@"operation_id"],
                        discardRequest[@"operation_id"]);
  NSDictionary *replay = [coordinator discardAgentAttempt:discardRequest
                                                     error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(replay, discarded);

  NSMutableDictionary *missingRequest = [discardRequest mutableCopy];
  missingRequest[@"operation_id"] =
      @"19191919-1919-4919-8919-191919191919";
  NSDictionary *alreadyMissing = [coordinator
      discardAgentAttempt:[missingRequest copy] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(alreadyMissing[@"status"], @"already_missing");
  XCTAssertEqual([wal.recoveryState[@"operations"] count], 2U);
  NSDictionary *missingReplay = [coordinator
      discardAgentAttempt:[missingRequest copy] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(missingReplay, alreadyMissing);
}

- (void)testFinalizeAcceptsTranscriptAdvanceProvenByLatestCompletedFinalRound {
  DSHRecoveryWAL *wal = [[DSHRecoveryWAL alloc]
      initWithRootURL:[self.rootURL URLByAppendingPathComponent:@"final-round-advance"]
      clock:^NSDate * { return NSDate.date; }
      identifierGenerator:^NSString * {
        return @"41414141-4141-4141-8141-414141414141";
      } faultHook:nil];
  NSMutableDictionary *before = [[self recoveryTranscript] mutableCopy];
  before[@"generation"] = @4;
  before[@"transcript_sha256"] =
      @"4444444444444444444444444444444444444444444444444444444444444444";
  before[@"transcript_bytes"] = @1756;
  NSMutableDictionary *after = [[self recoveryTranscript] mutableCopy];
  after[@"generation"] = @5;
  after[@"transcript_sha256"] =
      @"5555555555555555555555555555555555555555555555555555555555555555";
  after[@"transcript_bytes"] = @2015;
  NSDictionary *authority = @{
    @"task_id" : @"22222222-2222-4222-8222-222222222222",
    @"conversation_id" : @"11111111-1111-4111-8111-111111111111",
    @"attempt_id" : @"33333333-3333-4333-8333-333333333333",
    @"root" : [self recoveryRoot], @"transcript" : [before copy],
    @"state" : @"prepared", @"cleanup_id" : NSNull.null,
    @"authority_revision" : @9,
    @"updated_at" : @"2026-08-31T00:00:00.000Z"
  };
  NSDictionary *round = @{
    @"locator" : @{ @"schema_version" : @1,
      @"task_id" : authority[@"task_id"], @"attempt_id" : authority[@"attempt_id"],
      @"round_id" : @"42424242-4242-4242-8242-424242424242",
      @"round_index" : @2 },
    @"state" : @"completed", @"terminal_kind" : @"final",
    @"completion_receipt" : @{ @"finish_reason" : @"stop" },
    @"transcript_before" : [before copy], @"transcript_after" : [after copy]
  };
  wal.recoveryState = @{ @"authorities" : @[authority],
    @"transcripts" : @[@{ @"transcript_ref" : after[@"transcript_ref"],
      @"attempt_id" : authority[@"attempt_id"],
      @"transcript_sha256" : after[@"transcript_sha256"],
      @"state" : @"open", @"retention_until" : NSNull.null,
      @"updated_at" : @"2026-08-31T00:00:00.000Z" }],
    @"cleanup" : @[], @"rounds" : @[round], @"ledger" : @[],
    @"reservations" : @[], @"batches" : @[], @"denied_calls" : @[],
    @"dispatch" : @[], @"operations" : @[], @"operation_results" : @[] };
  DSHRecoveryRuntimeCoordinator *coordinator =
      [self recoveryCoordinatorWithWAL:wal roundService:nullptr
          executionService:nullptr];
  DSHRecoveryPreparedStore *prepared =
      (DSHRecoveryPreparedStore *)coordinator.preparedStore;
  prepared.recoveryAuthority = authority;
  NSString *cleanupId = @"43434343-4343-4343-8343-434343434343";
  NSDictionary *request = @{ @"schema_version" : @2,
    @"operation_id" : @"44444444-4444-4444-8444-444444444444",
    @"controller_cas" : [self recoveryControllerCAS],
    @"committed_checkpoint" : [self recoveryCheckpoint],
    @"task_id" : authority[@"task_id"],
    @"conversation_id" : authority[@"conversation_id"],
    @"attempt_id" : authority[@"attempt_id"], @"terminal_reason" : @"completed",
    @"cleanup_id" : cleanupId, @"transcript" : [after copy],
    @"root" : [self recoveryRoot] };
  NSError *error = nil;
  NSDictionary *started = DSHAgentNativeWALStartOperation(
      wal, @"finalize_agent_attempt", request, authority[@"task_id"],
      authority[@"attempt_id"], authority[@"authority_revision"], &error);
  XCTAssertNil(error);
  XCTAssertEqualObjects(started[@"status"], @"started");
  XCTAssertEqualObjects(wal.recoveryState[@"operations"][0][@"state"], @"started");
  NSDictionary *finalized = [coordinator finalizeAgentAttempt:request error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(finalized[@"status"], @"terminal");
  XCTAssertEqualObjects(wal.recoveryState[@"authorities"][0][@"transcript"], after);
  XCTAssertEqualObjects(wal.recoveryState[@"authorities"][0][@"state"],
                        @"cleanup_pending");
  XCTAssertEqualObjects(wal.recoveryState[@"operations"][0][@"state"], @"committed");
  NSDictionary *replay = [coordinator finalizeAgentAttempt:request error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(replay, finalized);

  prepared.recoveryAuthority = wal.recoveryState[@"authorities"][0];
  NSDictionary *discarded = [coordinator discardAgentAttempt:@{
    @"schema_version" : @2,
    @"operation_id" : @"45454545-4545-4545-8545-454545454545",
    @"cleanup_id" : cleanupId, @"task_id" : authority[@"task_id"],
    @"conversation_id" : authority[@"conversation_id"],
    @"attempt_id" : authority[@"attempt_id"],
    @"transcript_ref" : after[@"transcript_ref"],
    @"transcript_sha256" : after[@"transcript_sha256"]
  } error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(discarded[@"status"], @"discarded");
  XCTAssertEqual([wal.recoveryState[@"authorities"] count], 0U);
  XCTAssertEqual([wal.recoveryState[@"transcripts"] count], 0U);
}

- (void)testFinalizeRejectsUnprovenTranscriptAndTerminalizesConflictForReplay {
  DSHRecoveryWAL *wal = [[DSHRecoveryWAL alloc]
      initWithRootURL:[self.rootURL URLByAppendingPathComponent:@"unproven-final"]
      clock:^NSDate * { return NSDate.date; }
      identifierGenerator:^NSString * {
        return @"46464646-4646-4646-8646-464646464646";
      } faultHook:nil];
  NSMutableDictionary *before = [[self recoveryTranscript] mutableCopy];
  before[@"generation"] = @4;
  before[@"transcript_sha256"] =
      @"4444444444444444444444444444444444444444444444444444444444444444";
  NSMutableDictionary *after = [[self recoveryTranscript] mutableCopy];
  after[@"generation"] = @5;
  after[@"transcript_sha256"] =
      @"5555555555555555555555555555555555555555555555555555555555555555";
  NSDictionary *authority = @{
    @"task_id" : @"22222222-2222-4222-8222-222222222222",
    @"conversation_id" : @"11111111-1111-4111-8111-111111111111",
    @"attempt_id" : @"33333333-3333-4333-8333-333333333333",
    @"root" : [self recoveryRoot], @"transcript" : [before copy],
    @"state" : @"prepared", @"cleanup_id" : NSNull.null,
    @"authority_revision" : @9,
    @"updated_at" : @"2026-08-31T00:00:00.000Z"
  };
  wal.recoveryState = @{ @"authorities" : @[authority],
    @"transcripts" : @[@{ @"transcript_ref" : after[@"transcript_ref"],
      @"attempt_id" : authority[@"attempt_id"],
      @"transcript_sha256" : after[@"transcript_sha256"], @"state" : @"open" }],
    @"cleanup" : @[], @"rounds" : @[@{
      @"locator" : @{ @"task_id" : authority[@"task_id"],
        @"attempt_id" : authority[@"attempt_id"], @"round_index" : @2 },
      @"state" : @"completed", @"terminal_kind" : @"tool_batch",
      @"completion_receipt" : @{ @"finish_reason" : @"tool_calls" },
      @"transcript_before" : [before copy], @"transcript_after" : [after copy] }],
    @"ledger" : @[], @"reservations" : @[], @"batches" : @[],
    @"denied_calls" : @[], @"dispatch" : @[], @"operations" : @[],
    @"operation_results" : @[] };
  DSHRecoveryRuntimeCoordinator *coordinator =
      [self recoveryCoordinatorWithWAL:wal roundService:nullptr
          executionService:nullptr];
  ((DSHRecoveryPreparedStore *)coordinator.preparedStore).recoveryAuthority =
      authority;
  NSDictionary *request = @{ @"schema_version" : @2,
    @"operation_id" : @"47474747-4747-4747-8747-474747474747",
    @"controller_cas" : [self recoveryControllerCAS],
    @"committed_checkpoint" : [self recoveryCheckpoint],
    @"task_id" : authority[@"task_id"],
    @"conversation_id" : authority[@"conversation_id"],
    @"attempt_id" : authority[@"attempt_id"], @"terminal_reason" : @"completed",
    @"cleanup_id" : @"48484848-4848-4848-8848-484848484848",
    @"transcript" : [after copy], @"root" : [self recoveryRoot] };
  NSError *error = nil;
  NSDictionary *conflict = [coordinator finalizeAgentAttempt:request error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(conflict[@"status"], @"conflict");
  XCTAssertEqualObjects(conflict[@"failure_code"], @"E_AGENT_CONFLICT");
  XCTAssertEqualObjects(wal.recoveryState[@"operations"][0][@"state"], @"conflict");
  XCTAssertEqualObjects(wal.recoveryState[@"authorities"][0][@"transcript"], before);
  XCTAssertEqual([wal.recoveryState[@"cleanup"] count], 0U);
  NSDictionary *replay = [coordinator finalizeAgentAttempt:request error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(replay, conflict);
  XCTAssertEqualObjects(wal.recoveryState[@"operations"][0][@"state"], @"conflict");
}

- (void)testFinalizeAcceptsFailedTranscriptAdvanceProvenByBlockedRound {
  DSHRecoveryWAL *wal = [[DSHRecoveryWAL alloc]
      initWithRootURL:[self.rootURL URLByAppendingPathComponent:@"blocked-round"]
      clock:^NSDate * { return NSDate.date; }
      identifierGenerator:^NSString * {
        return @"49494949-4949-4949-8949-494949494949";
      } faultHook:nil];
  NSMutableDictionary *before = [[self recoveryTranscript] mutableCopy];
  before[@"generation"] = @7;
  before[@"transcript_sha256"] =
      @"7777777777777777777777777777777777777777777777777777777777777777";
  NSMutableDictionary *after = [[self recoveryTranscript] mutableCopy];
  after[@"generation"] = @8;
  after[@"transcript_sha256"] =
      @"8888888888888888888888888888888888888888888888888888888888888888";
  NSDictionary *authority = @{
    @"task_id" : @"22222222-2222-4222-8222-222222222222",
    @"conversation_id" : @"11111111-1111-4111-8111-111111111111",
    @"attempt_id" : @"33333333-3333-4333-8333-333333333333",
    @"root" : [self recoveryRoot], @"transcript" : [before copy],
    @"state" : @"prepared", @"cleanup_id" : NSNull.null,
    @"authority_revision" : @3,
    @"updated_at" : @"2026-08-31T00:00:00.000Z"
  };
  wal.recoveryState = @{ @"authorities" : @[authority],
    @"transcripts" : @[@{ @"transcript_ref" : after[@"transcript_ref"],
      @"attempt_id" : authority[@"attempt_id"],
      @"transcript_sha256" : after[@"transcript_sha256"], @"state" : @"open" }],
    @"cleanup" : @[], @"rounds" : @[@{
      @"locator" : @{ @"task_id" : authority[@"task_id"],
        @"attempt_id" : authority[@"attempt_id"], @"round_index" : @4 },
      @"state" : @"completed", @"terminal_kind" : @"blocked",
      @"completion_receipt" : @{ @"finish_reason" : @"length" },
      @"transcript_before" : [before copy], @"transcript_after" : [after copy] }],
    @"ledger" : @[], @"reservations" : @[], @"batches" : @[],
    @"denied_calls" : @[], @"dispatch" : @[], @"operations" : @[],
    @"operation_results" : @[] };
  DSHRecoveryRuntimeCoordinator *coordinator =
      [self recoveryCoordinatorWithWAL:wal roundService:nullptr
          executionService:nullptr];
  ((DSHRecoveryPreparedStore *)coordinator.preparedStore).recoveryAuthority =
      authority;
  NSDictionary *request = @{ @"schema_version" : @2,
    @"operation_id" : @"50505050-5050-4050-8050-505050505050",
    @"controller_cas" : [self recoveryControllerCAS],
    @"committed_checkpoint" : [self recoveryCheckpoint],
    @"task_id" : authority[@"task_id"],
    @"conversation_id" : authority[@"conversation_id"],
    @"attempt_id" : authority[@"attempt_id"], @"terminal_reason" : @"failed",
    @"cleanup_id" : @"51515151-5151-4151-8151-515151515151",
    @"transcript" : [after copy], @"root" : [self recoveryRoot] };
  NSError *error = nil;
  NSDictionary *finalized = [coordinator finalizeAgentAttempt:request error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(finalized[@"status"], @"terminal");
  XCTAssertEqualObjects(wal.recoveryState[@"authorities"][0][@"transcript"], after);
  XCTAssertEqualObjects(wal.recoveryState[@"cleanup"][0][@"reason"], @"failed");
  XCTAssertEqualObjects(wal.recoveryState[@"operations"][0][@"state"], @"committed");
}

- (void)testDiscardAlreadyMissingWithMissingSessionFailsClosedWithoutException {
  DSHRecoveryWAL *wal = [[DSHRecoveryWAL alloc]
      initWithRootURL:[self.rootURL URLByAppendingPathComponent:@"discard-missing-session"]
      clock:^NSDate * { return NSDate.date; }
      identifierGenerator:^NSString * {
        return @"31313131-3131-4131-8131-313131313131";
      } faultHook:nil];
  NSDictionary *cleanup = @{ @"schema_version" : @1,
    @"cleanup_id" : @"13131313-1313-4313-8313-131313131313",
    @"attempt_id" : @"33333333-3333-4333-8333-333333333333",
    @"transcript_ref" : [self recoveryTranscript][@"transcript_ref"],
    @"transcript_sha256" : [self recoveryTranscript][@"transcript_sha256"],
    @"cleanup_owner" : @"22222222-2222-4222-8222-222222222222",
    @"reason" : @"completed", @"created_at" : @"2026-08-31T00:00:00.000Z",
    @"status" : @"discarded" };
  wal.recoveryState = @{ @"authorities" : @[], @"cleanup" : @[cleanup],
    @"transcripts" : @[], @"rounds" : @[], @"ledger" : @[],
    @"reservations" : @[], @"batches" : @[], @"denied_calls" : @[],
    @"dispatch" : @[], @"operations" : @[], @"operation_results" : @[] };
  DSHRecoveryRuntimeCoordinator *coordinator =
      [self recoveryCoordinatorWithWAL:wal roundService:nullptr
          executionService:nullptr];
  DSHRecoverySessionStore *sessionStore =
      (DSHRecoverySessionStore *)coordinator.preparedStore.sessionSnapshotStore;
  sessionStore.recoveryLoad = @{ @"status" : @"missing",
                                 @"session_json" : NSNull.null };
  NSError *error = nil;
  NSDictionary *result = [coordinator discardAgentAttempt:@{
    @"schema_version" : @2,
    @"operation_id" : @"32323232-3232-4232-8232-323232323232",
    @"cleanup_id" : cleanup[@"cleanup_id"],
    @"task_id" : cleanup[@"cleanup_owner"],
    @"conversation_id" : @"11111111-1111-4111-8111-111111111111",
    @"attempt_id" : cleanup[@"attempt_id"],
    @"transcript_ref" : cleanup[@"transcript_ref"],
    @"transcript_sha256" : cleanup[@"transcript_sha256"]
  } error:&error];
  XCTAssertNil(result);
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorConflict);
  XCTAssertEqual([wal.recoveryState[@"operations"] count], 0U);
}

- (NSDictionary *)interruptSessionLoadWithStatus:(NSString *)status
                                    failureCode:(id)failureCode
                                          agent:(id)agent
                                         reason:(NSString *)reason {
  NSDictionary *attemptAgent = agent == NSNull.null ? NSNull.null : @{
    @"controller_generation" : @1,
    @"phase" : @"approval_pending",
    @"transcript" : [self recoveryTranscript],
  };
  NSMutableDictionary *attempt = [@{
    @"attempt_id" : @"33333333-3333-4333-8333-333333333333",
    @"turn_id" : @"22222222-2222-4222-8222-222222222222",
    @"journal_revision" : @1,
    @"status" : status,
    @"agent" : attemptAgent,
  } mutableCopy];
  if (failureCode != nil) attempt[@"failure_code"] = failureCode;
  NSDictionary *session = @{ @"schema_version" : @9,
    @"agent_transcript_cleanup_outbox" : @[@{
      @"schema_version" : @1,
      @"cleanup_id" : @"13131313-1313-4313-8313-131313131313",
      @"conversation_id" : @"11111111-1111-4111-8111-111111111111",
      @"task_id" : @"22222222-2222-4222-8222-222222222222",
      @"attempt_id" : @"33333333-3333-4333-8333-333333333333",
      @"transcript_ref" : [self recoveryTranscript][@"transcript_ref"],
      @"transcript_sha256" : [self recoveryTranscript][@"transcript_sha256"],
      @"reason" : reason, @"created_at" : @"2026-08-31T00:00:00.000Z"
    }],
    @"conversations" : @[@{
      @"id" : @"11111111-1111-4111-8111-111111111111",
      @"attempts" : @[attempt]
    }],
  };
  NSData *sessionBytes = [NSJSONSerialization dataWithJSONObject:session
      options:NSJSONWritingSortedKeys error:nil];
  return @{ @"status" : @"present",
    @"snapshot" : @{ @"generation" : @1, @"session_sha256" :
        @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
    @"session_json" : [[NSString alloc] initWithData:sessionBytes
                                               encoding:NSUTF8StringEncoding] };
}

- (NSDictionary *)interruptRequestWithOperationId:(NSString *)operationId {
  return @{ @"schema_version" : @2, @"operation_id" : operationId,
    @"cleanup_id" : @"13131313-1313-4313-8313-131313131313",
    @"task_id" : @"22222222-2222-4222-8222-222222222222",
    @"conversation_id" : @"11111111-1111-4111-8111-111111111111",
    @"attempt_id" : @"33333333-3333-4333-8333-333333333333",
    @"transcript_ref" : [self recoveryTranscript][@"transcript_ref"],
    @"transcript_sha256" : [self recoveryTranscript][@"transcript_sha256"],
    @"reason" : @"failed",
    @"expected_session_generation" : @1,
    @"expected_session_sha256" :
        @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" };
}

- (void)testInterruptDiscardsStaleApprovalAttemptAndReleasesReservations {
  DSHRecoveryWAL *wal = [[DSHRecoveryWAL alloc]
      initWithRootURL:[self.rootURL URLByAppendingPathComponent:@"interrupt-stale"]
      clock:^NSDate * { return NSDate.date; }
      identifierGenerator:^NSString * {
        return @"51515151-5151-4151-8151-515151515151";
      } faultHook:nil];
  NSDictionary *authority = @{ @"task_id" : @"22222222-2222-4222-8222-222222222222",
    @"conversation_id" : @"11111111-1111-4111-8111-111111111111",
    @"attempt_id" : @"33333333-3333-4333-8333-333333333333",
    @"root" : [self recoveryRoot], @"transcript" : [self recoveryTranscript],
    @"state" : @"prepared", @"cleanup_id" : NSNull.null,
    @"authority_revision" : @2, @"updated_at" : @"2026-08-31T00:00:00.000Z" };
  NSDictionary *transcriptRow = @{
    @"transcript_ref" : [self recoveryTranscript][@"transcript_ref"],
    @"attempt_id" : authority[@"attempt_id"],
    @"transcript_sha256" : [self recoveryTranscript][@"transcript_sha256"],
    @"state" : @"open", @"retention_until" : NSNull.null,
    @"updated_at" : @"2026-08-31T00:00:00.000Z" };
  NSDictionary *round = @{
    @"locator" : @{ @"schema_version" : @1,
      @"task_id" : authority[@"task_id"], @"attempt_id" : authority[@"attempt_id"],
      @"round_id" : @"77777777-7777-4777-8777-777777777777",
      @"round_index" : @0 },
    @"state" : @"completed" };
  NSDictionary *intentLocator = [self recoveryToolLocator];
  NSDictionary *intentRow = @{ @"schema_version" : @2,
    @"locator" : intentLocator, @"row_revision" : @1, @"state" : @"intent",
    @"root_fingerprint_sha256" : [self recoveryRoot][@"root_fingerprint_sha256"],
    @"binding_revision" : @1, @"transcript_before" : [self recoveryTranscript],
    @"name" : @"write_file", @"arguments_sha256" :
        @"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
    @"precondition" : @{ @"kind" : @"write_file" },
    @"reserved_write_bytes" : @3, @"owner" : NSNull.null,
    @"settled_facts" : NSNull.null, @"transcript_after" : NSNull.null,
    @"receipt" : NSNull.null };
  NSDictionary *dispatchNotDispatched = @{ @"schema_version" : @1,
    @"kind" : @"execution", @"locator" : intentLocator,
    @"dispatch_state" : @"not_dispatched" };
  NSDictionary *reservation = @{ @"schema_version" : @1,
    @"task_id" : authority[@"task_id"], @"attempt_id" : authority[@"attempt_id"],
    @"root_fingerprint_sha256" : [self recoveryRoot][@"root_fingerprint_sha256"],
    @"binding_revision" : @1,
    @"policy" : @{ @"schema_version" : @1, @"policy_version" : @"agent-v1",
      @"max_single_write_bytes" : @32768, @"max_batch_write_bytes" : @524288,
      @"max_attempt_write_bytes" : @4194304 },
    @"reserved_write_bytes" : @3, @"reservation_version" : @1,
    @"keys" : @[@{ @"idempotency_key" : intentLocator[@"idempotency_key"],
      @"relative_path_sha256" :
          @"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
      @"content_sha256" :
          @"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
      @"content_bytes" : @3, @"state" : @"active" }] };
  NSDictionary *batch = @{ @"schema_version" : @2,
    @"kind" : @"write_batch", @"task_id" : authority[@"task_id"],
    @"attempt_id" : authority[@"attempt_id"],
    @"root_fingerprint_sha256" : [self recoveryRoot][@"root_fingerprint_sha256"],
    @"binding_revision" : @1, @"round_id" : round[@"locator"][@"round_id"],
    @"round_index" : @0, @"batch_revision" : @1,
    @"manifest_sha256" :
        @"abababababababababababababababababababababababababababababababab",
    @"manifest_calls" : @[],
    @"write_keys" : @[intentLocator[@"idempotency_key"]],
    @"reserved_write_bytes" : @3, @"reservation_delta_bytes" : @3,
    @"attempt_reserved_write_bytes" : @3, @"reservation_version" : @1,
    @"effect_gate" : @"closed", @"created_at" : @"2026-08-31T00:00:00.000Z",
    @"updated_at" : @"2026-08-31T00:00:00.000Z" };
  wal.recoveryState = @{ @"authorities" : @[authority],
    @"transcripts" : @[transcriptRow], @"cleanup" : @[], @"rounds" : @[round],
    @"ledger" : @[intentRow], @"reservations" : @[reservation],
    @"batches" : @[batch], @"denied_calls" : @[],
    @"dispatch" : @[dispatchNotDispatched], @"operations" : @[],
    @"operation_results" : @[] };
  DSHRecoveryRuntimeCoordinator *coordinator =
      [self recoveryCoordinatorWithWAL:wal roundService:nullptr
          executionService:nullptr];
  DSHRecoverySessionStore *sessionStore =
      (DSHRecoverySessionStore *)coordinator.preparedStore.sessionSnapshotStore;
  sessionStore.recoveryLoad = [self interruptSessionLoadWithStatus:@"failed"
      failureCode:@"E_ATTEMPT_INTERRUPTED"
            agent:@{ @"controller_generation" : @1,
                     @"phase" : @"approval_pending",
                     @"transcript" : [self recoveryTranscript] }
           reason:@"failed"];
  NSError *error = nil;
  NSDictionary *request = [self interruptRequestWithOperationId:
      @"61616161-6161-4161-8161-616161616161"];
  NSDictionary *result = [coordinator interruptAgentAttempt:request error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"discarded");
  XCTAssertEqual([wal.recoveryState[@"authorities"] count], 0U);
  XCTAssertEqual([wal.recoveryState[@"transcripts"] count], 0U);
  XCTAssertEqual([wal.recoveryState[@"rounds"] count], 0U);
  XCTAssertEqual([wal.recoveryState[@"ledger"] count], 0U);
  XCTAssertEqual([wal.recoveryState[@"reservations"] count], 0U);
  XCTAssertEqual([wal.recoveryState[@"batches"] count], 0U);
  XCTAssertEqual([wal.recoveryState[@"dispatch"] count], 0U);
  XCTAssertEqual([wal.recoveryState[@"cleanup"] count], 1U);
  XCTAssertEqualObjects(wal.recoveryState[@"cleanup"][0][@"status"], @"discarded");
  XCTAssertEqualObjects(wal.recoveryState[@"cleanup"][0][@"reason"], @"failed");
  XCTAssertEqual([wal.recoveryState[@"operations"] count], 1U);
  // The interruption operation is committed and idempotent for retries.
  NSDictionary *replay = [coordinator interruptAgentAttempt:request error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(replay, result);
  XCTAssertEqual([wal.recoveryState[@"operations"] count], 1U);
}

- (void)testInterruptRejectsDispatchedIntentRowAndPreservesEvidence {
  DSHRecoveryWAL *wal = [[DSHRecoveryWAL alloc]
      initWithRootURL:[self.rootURL URLByAppendingPathComponent:@"interrupt-dispatched"]
      clock:^NSDate * { return NSDate.date; }
      identifierGenerator:^NSString * {
        return @"62626262-6262-4262-8262-626262626262";
      } faultHook:nil];
  NSDictionary *authority = @{ @"task_id" : @"22222222-2222-4222-8222-222222222222",
    @"conversation_id" : @"11111111-1111-4111-8111-111111111111",
    @"attempt_id" : @"33333333-3333-4333-8333-333333333333",
    @"root" : [self recoveryRoot], @"transcript" : [self recoveryTranscript],
    @"state" : @"prepared", @"cleanup_id" : NSNull.null,
    @"authority_revision" : @2 };
  NSDictionary *intentLocator = [self recoveryToolLocator];
  NSDictionary *intentRow = @{ @"schema_version" : @2,
    @"locator" : intentLocator, @"row_revision" : @1, @"state" : @"intent",
    @"root_fingerprint_sha256" : [self recoveryRoot][@"root_fingerprint_sha256"],
    @"binding_revision" : @1, @"transcript_before" : [self recoveryTranscript],
    @"name" : @"write_file", @"arguments_sha256" :
        @"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
    @"precondition" : @{ @"kind" : @"write_file" },
    @"reserved_write_bytes" : @3, @"owner" : NSNull.null,
    @"settled_facts" : NSNull.null, @"transcript_after" : NSNull.null,
    @"receipt" : NSNull.null };
  NSDictionary *dispatchDispatched = @{ @"schema_version" : @1,
    @"kind" : @"execution", @"locator" : intentLocator,
    @"dispatch_state" : @"dispatched" };
  wal.recoveryState = @{ @"authorities" : @[authority],
    @"transcripts" : @[@{ @"attempt_id" : authority[@"attempt_id"],
      @"transcript_ref" : [self recoveryTranscript][@"transcript_ref"],
      @"transcript_sha256" : [self recoveryTranscript][@"transcript_sha256"],
      @"state" : @"open" }],
    @"cleanup" : @[], @"rounds" : @[], @"ledger" : @[intentRow],
    @"reservations" : @[], @"batches" : @[], @"denied_calls" : @[],
    @"dispatch" : @[dispatchDispatched], @"operations" : @[],
    @"operation_results" : @[] };
  DSHRecoveryRuntimeCoordinator *coordinator =
      [self recoveryCoordinatorWithWAL:wal roundService:nullptr
          executionService:nullptr];
  DSHRecoverySessionStore *sessionStore =
      (DSHRecoverySessionStore *)coordinator.preparedStore.sessionSnapshotStore;
  sessionStore.recoveryLoad = [self interruptSessionLoadWithStatus:@"failed"
      failureCode:@"E_ATTEMPT_INTERRUPTED"
            agent:@{ @"controller_generation" : @1,
                     @"phase" : @"execution_intent",
                     @"transcript" : [self recoveryTranscript] }
           reason:@"failed"];
  NSError *error = nil;
  NSDictionary *result = [coordinator interruptAgentAttempt:
      [self interruptRequestWithOperationId:
          @"63636363-6363-4363-8363-636363636363"] error:&error];
  XCTAssertNil(result);
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorConflict);
  XCTAssertEqual([wal.recoveryState[@"ledger"] count], 1U);
  XCTAssertEqual([wal.recoveryState[@"dispatch"] count], 1U);
  XCTAssertEqual([wal.recoveryState[@"authorities"] count], 1U);
}

// The round below carries no owner field, so nothing proves its writer let it
// go and the discard fails closed.  A round the owner sweep has released is
// covered by testInterruptDiscardsAnAbandonedAmbiguousRound.
- (void)testInterruptRejectsAnUnreleasedAmbiguousRoundAndNonTerminalSessionAttempt {
  DSHRecoveryWAL *wal = [[DSHRecoveryWAL alloc]
      initWithRootURL:[self.rootURL URLByAppendingPathComponent:@"interrupt-guards"]
      clock:^NSDate * { return NSDate.date; }
      identifierGenerator:^NSString * {
        return @"64646464-6464-4464-8464-646464646464";
      } faultHook:nil];
  NSDictionary *authority = @{ @"task_id" : @"22222222-2222-4222-8222-222222222222",
    @"conversation_id" : @"11111111-1111-4111-8111-111111111111",
    @"attempt_id" : @"33333333-3333-4333-8333-333333333333",
    @"root" : [self recoveryRoot], @"transcript" : [self recoveryTranscript],
    @"state" : @"prepared", @"cleanup_id" : NSNull.null,
    @"authority_revision" : @2 };
  NSDictionary *ambiguousRound = @{
    @"locator" : @{ @"schema_version" : @1,
      @"task_id" : authority[@"task_id"], @"attempt_id" : authority[@"attempt_id"],
      @"round_id" : @"77777777-7777-4777-8777-777777777777",
      @"round_index" : @0 },
    @"state" : @"ambiguous" };
  wal.recoveryState = @{ @"authorities" : @[authority],
    @"transcripts" : @[@{ @"attempt_id" : authority[@"attempt_id"],
      @"transcript_ref" : [self recoveryTranscript][@"transcript_ref"],
      @"transcript_sha256" : [self recoveryTranscript][@"transcript_sha256"],
      @"state" : @"open" }],
    @"cleanup" : @[], @"rounds" : @[ambiguousRound], @"ledger" : @[],
    @"reservations" : @[], @"batches" : @[], @"denied_calls" : @[],
    @"dispatch" : @[], @"operations" : @[], @"operation_results" : @[] };
  DSHRecoveryRuntimeCoordinator *coordinator =
      [self recoveryCoordinatorWithWAL:wal roundService:nullptr
          executionService:nullptr];
  DSHRecoverySessionStore *sessionStore =
      (DSHRecoverySessionStore *)coordinator.preparedStore.sessionSnapshotStore;
  sessionStore.recoveryLoad = [self interruptSessionLoadWithStatus:@"failed"
      failureCode:@"E_ATTEMPT_INTERRUPTED"
            agent:@{ @"controller_generation" : @1,
                     @"phase" : @"round_in_flight",
                     @"transcript" : [self recoveryTranscript] }
           reason:@"failed"];
  NSError *error = nil;
  NSDictionary *result = [coordinator interruptAgentAttempt:
      [self interruptRequestWithOperationId:
          @"65656565-6565-4565-8565-656565656565"] error:&error];
  XCTAssertNil(result);
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorConflict);
  XCTAssertEqual([wal.recoveryState[@"authorities"] count], 1U);
  XCTAssertEqual([wal.recoveryState[@"rounds"] count], 1U);

  // A session attempt that is still non-terminal is never interruptible.
  wal.recoveryState = @{ @"authorities" : @[authority],
    @"transcripts" : @[@{ @"attempt_id" : authority[@"attempt_id"],
      @"transcript_ref" : [self recoveryTranscript][@"transcript_ref"],
      @"transcript_sha256" : [self recoveryTranscript][@"transcript_sha256"],
      @"state" : @"open" }],
    @"cleanup" : @[], @"rounds" : @[], @"ledger" : @[],
    @"reservations" : @[], @"batches" : @[], @"denied_calls" : @[],
    @"dispatch" : @[], @"operations" : @[], @"operation_results" : @[] };
  sessionStore.recoveryLoad = [self interruptSessionLoadWithStatus:@"prepared"
      failureCode:nil agent:NSNull.null reason:@"failed"];
  error = nil;
  result = [coordinator interruptAgentAttempt:
      [self interruptRequestWithOperationId:
          @"66666666-6666-4666-8666-666666666666"] error:&error];
  XCTAssertNil(result);
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorConflict);
  XCTAssertEqual([wal.recoveryState[@"authorities"] count], 1U);
  XCTAssertEqual([wal.recoveryState[@"operations"] count], 0U);
}

// Device evidence (2026-09-04): nine attempts whose writer died with an
// ambiguous complete_agent_round_v2 operation, plus one whose finalize was
// started and never committed, pinned ten cleanup entries across ten launches.
// Each launch's interrupt refused them because of the unsettled operation and
// then left its own started operation behind, so the pile only grew.  An
// unsettled operation that never reaches the workspace is residue, not proof
// of an effect, and the discard takes it with everything else.
- (void)testInterruptDiscardsUnsettledWALOnlyOperationsLeftByADeadWriter {
  DSHRecoveryWAL *wal = [[DSHRecoveryWAL alloc]
      initWithRootURL:[self.rootURL URLByAppendingPathComponent:@"interrupt-unsettled"]
      clock:^NSDate * { return NSDate.date; }
      identifierGenerator:^NSString * {
        return @"67676767-6767-4767-8767-676767676767";
      } faultHook:nil];
  NSDictionary *authority = @{ @"task_id" : @"22222222-2222-4222-8222-222222222222",
    @"conversation_id" : @"11111111-1111-4111-8111-111111111111",
    @"attempt_id" : @"33333333-3333-4333-8333-333333333333",
    @"root" : [self recoveryRoot], @"transcript" : [self recoveryTranscript],
    @"state" : @"prepared", @"cleanup_id" : NSNull.null,
    @"authority_revision" : @2 };
  NSDictionary *ambiguousRound = @{
    @"attempt_id" : authority[@"attempt_id"], @"task_id" : authority[@"task_id"],
    @"operation_id" : @"68686868-6868-4868-8868-686868686868",
    @"operation_kind" : @"complete_agent_round_v2", @"state" : @"ambiguous" };
  NSDictionary *startedFinalize = @{
    @"attempt_id" : authority[@"attempt_id"], @"task_id" : authority[@"task_id"],
    @"operation_id" : @"69696969-6969-4969-8969-696969696969",
    @"operation_kind" : @"finalize_agent_attempt", @"state" : @"started" };
  NSDictionary *earlierInterrupt = @{
    @"attempt_id" : authority[@"attempt_id"], @"task_id" : authority[@"task_id"],
    @"operation_id" : @"70707070-7070-4070-8070-707070707070",
    @"operation_kind" : @"interrupt_agent_attempt", @"state" : @"started" };
  NSDictionary *transcriptRow = @{ @"attempt_id" : authority[@"attempt_id"],
    @"transcript_ref" : [self recoveryTranscript][@"transcript_ref"],
    @"transcript_sha256" : [self recoveryTranscript][@"transcript_sha256"],
    @"state" : @"open" };
  wal.recoveryState = @{ @"authorities" : @[authority],
    @"transcripts" : @[transcriptRow],
    @"cleanup" : @[], @"rounds" : @[], @"ledger" : @[],
    @"reservations" : @[], @"batches" : @[], @"denied_calls" : @[],
    @"dispatch" : @[],
    @"operations" : @[ambiguousRound, startedFinalize, earlierInterrupt],
    @"operation_results" : @[] };
  DSHRecoveryRuntimeCoordinator *coordinator =
      [self recoveryCoordinatorWithWAL:wal roundService:nullptr
          executionService:nullptr];
  DSHRecoverySessionStore *sessionStore =
      (DSHRecoverySessionStore *)coordinator.preparedStore.sessionSnapshotStore;
  sessionStore.recoveryLoad = [self interruptSessionLoadWithStatus:@"failed"
      failureCode:@"E_ATTEMPT_INTERRUPTED"
            agent:@{ @"controller_generation" : @1,
                     @"phase" : @"round_in_flight",
                     @"transcript" : [self recoveryTranscript] }
           reason:@"failed"];
  NSError *error = nil;
  NSDictionary *request = [self interruptRequestWithOperationId:
      @"71717171-7171-4171-8171-717171717171"];
  NSDictionary *result = [coordinator interruptAgentAttempt:request error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"discarded");
  XCTAssertEqual([wal.recoveryState[@"authorities"] count], 0U);
  XCTAssertEqual([wal.recoveryState[@"transcripts"] count], 0U);
  XCTAssertEqual([wal.recoveryState[@"cleanup"] count], 1U);
  XCTAssertEqualObjects(wal.recoveryState[@"cleanup"][0][@"status"], @"discarded");
  // Only this interrupt's own committed operation survives.
  NSArray *operations = wal.recoveryState[@"operations"];
  XCTAssertEqual(operations.count, 1U);
  XCTAssertEqualObjects(operations.firstObject[@"operation_id"],
                        request[@"operation_id"]);
  XCTAssertEqualObjects(operations.firstObject[@"state"], @"committed");
}

- (void)testInterruptStillRefusesAnUnsettledToolExecution {
  DSHRecoveryWAL *wal = [[DSHRecoveryWAL alloc]
      initWithRootURL:[self.rootURL URLByAppendingPathComponent:@"interrupt-execute"]
      clock:^NSDate * { return NSDate.date; }
      identifierGenerator:^NSString * {
        return @"72727272-7272-4272-8272-727272727272";
      } faultHook:nil];
  NSDictionary *authority = @{ @"task_id" : @"22222222-2222-4222-8222-222222222222",
    @"conversation_id" : @"11111111-1111-4111-8111-111111111111",
    @"attempt_id" : @"33333333-3333-4333-8333-333333333333",
    @"root" : [self recoveryRoot], @"transcript" : [self recoveryTranscript],
    @"state" : @"prepared", @"cleanup_id" : NSNull.null,
    @"authority_revision" : @2 };
  NSDictionary *startedExecute = @{
    @"attempt_id" : authority[@"attempt_id"], @"task_id" : authority[@"task_id"],
    @"operation_id" : @"73737373-7373-4373-8373-737373737373",
    @"operation_kind" : @"execute_agent_tool", @"state" : @"started" };
  NSDictionary *transcriptRow = @{ @"attempt_id" : authority[@"attempt_id"],
    @"transcript_ref" : [self recoveryTranscript][@"transcript_ref"],
    @"transcript_sha256" : [self recoveryTranscript][@"transcript_sha256"],
    @"state" : @"open" };
  wal.recoveryState = @{ @"authorities" : @[authority],
    @"transcripts" : @[transcriptRow],
    @"cleanup" : @[], @"rounds" : @[], @"ledger" : @[],
    @"reservations" : @[], @"batches" : @[], @"denied_calls" : @[],
    @"dispatch" : @[], @"operations" : @[startedExecute],
    @"operation_results" : @[] };
  DSHRecoveryRuntimeCoordinator *coordinator =
      [self recoveryCoordinatorWithWAL:wal roundService:nullptr
          executionService:nullptr];
  DSHRecoverySessionStore *sessionStore =
      (DSHRecoverySessionStore *)coordinator.preparedStore.sessionSnapshotStore;
  sessionStore.recoveryLoad = [self interruptSessionLoadWithStatus:@"failed"
      failureCode:@"E_ATTEMPT_INTERRUPTED"
            agent:@{ @"controller_generation" : @1,
                     @"phase" : @"round_in_flight",
                     @"transcript" : [self recoveryTranscript] }
           reason:@"failed"];
  NSError *error = nil;
  NSDictionary *result = [coordinator interruptAgentAttempt:
      [self interruptRequestWithOperationId:
          @"74747474-7474-4174-8174-747474747474"] error:&error];
  XCTAssertNil(result);
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorConflict);
  XCTAssertEqual([wal.recoveryState[@"authorities"] count], 1U);
  XCTAssertEqual([wal.recoveryState[@"transcripts"] count], 1U);
}

// Device evidence (2026-09-04, second round): after the operation fix drained
// the reservation and the newest attempt, nine cleanup entries and nine
// authorities still survived every launch.  Each of those attempts had one
// round the WAL's owner sweep had already retired to ambiguous with a
// released owner and E_AGENT_ROUND_AMBIGUOUS, and the round check ran before
// the relaxed operation check and refused the discard outright.  A round is a
// provider call: it reaches no workspace and no git remote, and once its
// writer has released it there is no outcome left to wait for.
- (void)testInterruptDiscardsAnAbandonedAmbiguousRound {
  DSHRecoveryWAL *wal = [[DSHRecoveryWAL alloc]
      initWithRootURL:[self.rootURL URLByAppendingPathComponent:@"interrupt-round"]
      clock:^NSDate * { return NSDate.date; }
      identifierGenerator:^NSString * {
        return @"75757575-7575-4575-8575-757575757575";
      } faultHook:nil];
  NSDictionary *authority = @{ @"task_id" : @"22222222-2222-4222-8222-222222222222",
    @"conversation_id" : @"11111111-1111-4111-8111-111111111111",
    @"attempt_id" : @"33333333-3333-4333-8333-333333333333",
    @"root" : [self recoveryRoot], @"transcript" : [self recoveryTranscript],
    @"state" : @"prepared", @"cleanup_id" : NSNull.null,
    @"authority_revision" : @2 };
  NSDictionary *roundLocator = @{ @"schema_version" : @1,
    @"task_id" : authority[@"task_id"], @"attempt_id" : authority[@"attempt_id"],
    @"round_id" : @"77777777-7777-4777-8777-777777777777",
    @"round_index" : @0 };
  NSDictionary *sweptRound = @{ @"locator" : roundLocator,
    @"state" : @"ambiguous", @"owner" : NSNull.null,
    @"failure_code" : @"E_AGENT_ROUND_AMBIGUOUS" };
  NSDictionary *transcriptRow = @{ @"attempt_id" : authority[@"attempt_id"],
    @"transcript_ref" : [self recoveryTranscript][@"transcript_ref"],
    @"transcript_sha256" : [self recoveryTranscript][@"transcript_sha256"],
    @"state" : @"open" };
  wal.recoveryState = @{ @"authorities" : @[authority],
    @"transcripts" : @[transcriptRow],
    @"cleanup" : @[], @"rounds" : @[sweptRound], @"ledger" : @[],
    @"reservations" : @[], @"batches" : @[], @"denied_calls" : @[],
    @"dispatch" : @[], @"operations" : @[], @"operation_results" : @[] };
  DSHRecoveryRuntimeCoordinator *coordinator =
      [self recoveryCoordinatorWithWAL:wal roundService:nullptr
          executionService:nullptr];
  DSHRecoverySessionStore *sessionStore =
      (DSHRecoverySessionStore *)coordinator.preparedStore.sessionSnapshotStore;
  sessionStore.recoveryLoad = [self interruptSessionLoadWithStatus:@"failed"
      failureCode:@"E_ATTEMPT_INTERRUPTED"
            agent:@{ @"controller_generation" : @1,
                     @"phase" : @"round_in_flight",
                     @"transcript" : [self recoveryTranscript] }
           reason:@"failed"];
  NSError *error = nil;
  NSDictionary *result = [coordinator interruptAgentAttempt:
      [self interruptRequestWithOperationId:
          @"76767676-7676-4676-8676-767676767676"] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"discarded");
  XCTAssertEqual([wal.recoveryState[@"rounds"] count], 0U);
  XCTAssertEqual([wal.recoveryState[@"authorities"] count], 0U);
  XCTAssertEqual([wal.recoveryState[@"transcripts"] count], 0U);
  XCTAssertEqual([wal.recoveryState[@"cleanup"] count], 1U);
  NSString *cleanupStatus = wal.recoveryState[@"cleanup"][0][@"status"];
  XCTAssertEqualObjects(cleanupStatus, @"discarded");
}

// A round whose writer still holds it may yet report an outcome, and an
// in-flight round is a live one whatever its owner field says.  Neither is
// residue, so both keep failing closed.
- (void)testInterruptStillRefusesARoundThatIsOwnedOrInFlight {
  NSDictionary *authority = @{ @"task_id" : @"22222222-2222-4222-8222-222222222222",
    @"conversation_id" : @"11111111-1111-4111-8111-111111111111",
    @"attempt_id" : @"33333333-3333-4333-8333-333333333333",
    @"root" : [self recoveryRoot], @"transcript" : [self recoveryTranscript],
    @"state" : @"prepared", @"cleanup_id" : NSNull.null,
    @"authority_revision" : @2 };
  NSDictionary *roundLocator = @{ @"schema_version" : @1,
    @"task_id" : authority[@"task_id"], @"attempt_id" : authority[@"attempt_id"],
    @"round_id" : @"77777777-7777-4777-8777-777777777777",
    @"round_index" : @0 };
  NSDictionary *owner = @{
    @"native_task_id" : @"78787878-7878-4878-8878-787878787878",
    @"launch_id" : @"79797979-7979-4979-8979-797979797979" };
  NSDictionary *ownedRound = @{ @"locator" : roundLocator,
    @"state" : @"ambiguous", @"owner" : owner };
  NSDictionary *inFlightRound = @{ @"locator" : roundLocator,
    @"state" : @"in_flight", @"owner" : NSNull.null };
  NSDictionary *transcriptRow = @{ @"attempt_id" : authority[@"attempt_id"],
    @"transcript_ref" : [self recoveryTranscript][@"transcript_ref"],
    @"transcript_sha256" : [self recoveryTranscript][@"transcript_sha256"],
    @"state" : @"open" };
  NSArray *rounds = @[ownedRound, inFlightRound];
  for (NSUInteger index = 0; index < rounds.count; index += 1) {
    NSString *directory = [NSString stringWithFormat:@"interrupt-round-live-%lu",
                                                     (unsigned long)index];
    DSHRecoveryWAL *wal = [[DSHRecoveryWAL alloc]
        initWithRootURL:[self.rootURL URLByAppendingPathComponent:directory]
        clock:^NSDate * { return NSDate.date; }
        identifierGenerator:^NSString * {
          return @"80808080-8080-4080-8080-808080808080";
        } faultHook:nil];
    wal.recoveryState = @{ @"authorities" : @[authority],
      @"transcripts" : @[transcriptRow],
      @"cleanup" : @[], @"rounds" : @[rounds[index]], @"ledger" : @[],
      @"reservations" : @[], @"batches" : @[], @"denied_calls" : @[],
      @"dispatch" : @[], @"operations" : @[], @"operation_results" : @[] };
    DSHRecoveryRuntimeCoordinator *coordinator =
        [self recoveryCoordinatorWithWAL:wal roundService:nullptr
            executionService:nullptr];
    DSHRecoverySessionStore *sessionStore =
        (DSHRecoverySessionStore *)coordinator.preparedStore.sessionSnapshotStore;
    sessionStore.recoveryLoad = [self interruptSessionLoadWithStatus:@"failed"
        failureCode:@"E_ATTEMPT_INTERRUPTED"
              agent:@{ @"controller_generation" : @1,
                       @"phase" : @"round_in_flight",
                       @"transcript" : [self recoveryTranscript] }
             reason:@"failed"];
    NSError *error = nil;
    NSString *operationId = [NSString stringWithFormat:
        @"8181818%lu-8181-4181-8181-818181818181", (unsigned long)index];
    NSDictionary *result = [coordinator interruptAgentAttempt:
        [self interruptRequestWithOperationId:operationId] error:&error];
    XCTAssertNil(result);
    XCTAssertEqual(error.code, DSHAgentNativeStoreErrorConflict);
    XCTAssertEqual([wal.recoveryState[@"rounds"] count], 1U);
    XCTAssertEqual([wal.recoveryState[@"authorities"] count], 1U);
  }
}

- (void)testInterruptAlreadyMissingRequiresDiscardedCleanupRow {
  DSHRecoveryWAL *wal = [[DSHRecoveryWAL alloc]
      initWithRootURL:[self.rootURL URLByAppendingPathComponent:@"interrupt-missing"]
      clock:^NSDate * { return NSDate.date; }
      identifierGenerator:^NSString * {
        return @"67676767-6767-4767-8767-676767676767";
      } faultHook:nil];
  NSDictionary *cleanup = @{ @"schema_version" : @1,
    @"cleanup_id" : @"13131313-1313-4313-8313-131313131313",
    @"attempt_id" : @"33333333-3333-4333-8333-333333333333",
    @"transcript_ref" : [self recoveryTranscript][@"transcript_ref"],
    @"transcript_sha256" : [self recoveryTranscript][@"transcript_sha256"],
    @"cleanup_owner" : @"22222222-2222-4222-8222-222222222222",
    @"reason" : @"failed", @"created_at" : @"2026-08-31T00:00:00.000Z",
    @"status" : @"discarded" };
  wal.recoveryState = @{ @"authorities" : @[], @"cleanup" : @[cleanup],
    @"transcripts" : @[], @"rounds" : @[], @"ledger" : @[],
    @"reservations" : @[], @"batches" : @[], @"denied_calls" : @[],
    @"dispatch" : @[], @"operations" : @[], @"operation_results" : @[] };
  DSHRecoveryRuntimeCoordinator *coordinator =
      [self recoveryCoordinatorWithWAL:wal roundService:nullptr
          executionService:nullptr];
  DSHRecoverySessionStore *sessionStore =
      (DSHRecoverySessionStore *)coordinator.preparedStore.sessionSnapshotStore;
  sessionStore.recoveryLoad = [self interruptSessionLoadWithStatus:@"failed"
      failureCode:@"E_ATTEMPT_INTERRUPTED"
            agent:@{ @"controller_generation" : @1,
                     @"phase" : @"approval_pending",
                     @"transcript" : [self recoveryTranscript] }
           reason:@"failed"];
  NSError *error = nil;
  NSDictionary *request = [self interruptRequestWithOperationId:
      @"68686868-6868-4868-8868-686868686868"];
  NSDictionary *result = [coordinator interruptAgentAttempt:request error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"already_missing");
  NSDictionary *replay = [coordinator interruptAgentAttempt:request error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(replay, result);

  // Without the exact discarded cleanup proof the gap cannot be closed.
  sessionStore.recoveryLoad = @{ @"status" : @"missing",
                                 @"session_json" : NSNull.null };
  error = nil;
  result = [coordinator interruptAgentAttempt:
      [self interruptRequestWithOperationId:
          @"69696969-6969-4969-8969-696969696969"] error:&error];
  XCTAssertNil(result);
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorConflict);
}

- (NSData *)bundleFixtureBytesNamed:(NSString *)name {
  NSURL *url = [[NSBundle bundleForClass:self.class]
      URLForResource:name withExtension:@"json"];
  XCTAssertNotNil(url);
  return url == nil ? nil : [NSData dataWithContentsOfURL:url options:0
                                                     error:nil];
}

- (NSMutableDictionary *)mutableJSONCopyOfDictionary:(NSDictionary *)source {
  NSError *error = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:source
                                                 options:0
                                                   error:&error];
  XCTAssertNotNil(data);
  XCTAssertNil(error);
  id value = data == nil ? nil : [NSJSONSerialization
      JSONObjectWithData:data
                 options:NSJSONReadingMutableContainers
                   error:&error];
  XCTAssertTrue([value isKindOfClass:NSMutableDictionary.class]);
  return [value isKindOfClass:NSMutableDictionary.class] ? value : nil;
}

/// Evidence harness: the real pulled device files
/// (27-scenario-a4-persistence-block): the schema-9 session envelope written
/// by launch fdefd001-889c-460d-9886-afd3886fc7f5 and the agent WAL with
/// intent rows, closed write batches, and active reservations.  The session
/// store is constructed with a different launch id, modelling the relaunch
/// that must interrupt every non-terminal attempt.  Returns nil when the
/// bundle fixtures cannot be staged.
- (NSDictionary *)evidenceHarnessNamed:(NSString *)name {
  NSData *envelopeBytes = [self bundleFixtureBytesNamed:
      @"scenario-a4-session-envelope"];
  NSData *walBytes = [self bundleFixtureBytesNamed:@"scenario-a4-wal"];
  XCTAssertNotNil(envelopeBytes);
  XCTAssertNotNil(walBytes);
  if (envelopeBytes == nil || walBytes == nil) return nil;

  NSURL *sessionRoot = [self.rootURL
      URLByAppendingPathComponent:[name stringByAppendingString:@"-session"]
                      isDirectory:YES];
  NSURL *sessionURL = [sessionRoot URLByAppendingPathComponent:@"sessions.json"];
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:sessionRoot
      withIntermediateDirectories:YES
      attributes:@{ NSFilePosixPermissions : @0700 } error:nil]);
  XCTAssertTrue([envelopeBytes writeToURL:sessionURL
                                 options:NSDataWritingAtomic error:nil]);
  // Stage the pulled file exactly as the shipped store would have left it:
  // private mode, first-unlock protection, excluded from backup.
  XCTAssertTrue(([NSFileManager.defaultManager
      setAttributes:@{ NSFilePosixPermissions : @0600 }
       ofItemAtPath:sessionURL.path error:nil]));
#if TARGET_OS_SIMULATOR
  (void)[sessionURL setResourceValue:
      NSURLFileProtectionCompleteUntilFirstUserAuthentication
                              forKey:NSURLFileProtectionKey error:nil];
  (void)[sessionURL setResourceValue:@YES
                              forKey:NSURLIsExcludedFromBackupKey error:nil];
#else
  XCTAssertTrue(([NSFileManager.defaultManager
      setAttributes:@{ NSFileProtectionKey :
          NSFileProtectionCompleteUntilFirstUserAuthentication }
       ofItemAtPath:sessionURL.path error:nil]));
  XCTAssertTrue([sessionURL setResourceValue:@YES
                                      forKey:NSURLIsExcludedFromBackupKey
                                       error:nil]);
#endif

  // The device pull skipped the hidden commit-tombstone ledger next to
  // sessions.json; the store refuses to advance a generation it cannot prove
  // against that ledger, so stage a minimal valid ledger at the pulled
  // generation with the same protection.
  NSDictionary *pulledEnvelope = [NSJSONSerialization JSONObjectWithData:envelopeBytes
      options:0 error:nil];
  XCTAssertTrue([pulledEnvelope isKindOfClass:NSDictionary.class]);
  NSString *tombstones = [NSString stringWithFormat:
      @"{\"generation\":%@,\"operation_ids\":[],\"schema_version\":1}",
      pulledEnvelope[@"generation"]];
  NSURL *tombstoneURL = [sessionRoot
      URLByAppendingPathComponent:@".sessions.commit-tombstones"];
  XCTAssertTrue([[tombstones dataUsingEncoding:NSUTF8StringEncoding]
      writeToURL:tombstoneURL options:NSDataWritingAtomic error:nil]);
  XCTAssertTrue(([NSFileManager.defaultManager
      setAttributes:@{ NSFilePosixPermissions : @0600 }
       ofItemAtPath:tombstoneURL.path error:nil]));
#if TARGET_OS_SIMULATOR
  (void)[tombstoneURL setResourceValue:
      NSURLFileProtectionCompleteUntilFirstUserAuthentication
                                forKey:NSURLFileProtectionKey error:nil];
  (void)[tombstoneURL setResourceValue:@YES
                                forKey:NSURLIsExcludedFromBackupKey error:nil];
#else
  XCTAssertTrue(([NSFileManager.defaultManager
      setAttributes:@{ NSFileProtectionKey :
          NSFileProtectionCompleteUntilFirstUserAuthentication }
       ofItemAtPath:tombstoneURL.path error:nil]));
  XCTAssertTrue([tombstoneURL setResourceValue:@YES
                                        forKey:NSURLIsExcludedFromBackupKey
                                         error:nil]);
#endif

  NSURL *walRoot = [self.rootURL
      URLByAppendingPathComponent:[name stringByAppendingString:@"-wal"]
                      isDirectory:YES];
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:walRoot
      withIntermediateDirectories:YES
      attributes:@{ NSFilePosixPermissions : @0700 } error:nil]);
  NSURL *walURL = [walRoot URLByAppendingPathComponent:@"agent-native-wal-v1.json"];
  XCTAssertTrue([walBytes writeToURL:walURL options:NSDataWritingAtomic
                               error:nil]);
  XCTAssertTrue(([NSFileManager.defaultManager
      setAttributes:@{ NSFilePosixPermissions : @0600 }
       ofItemAtPath:walURL.path error:nil]));

  NSString *relaunchId = @"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  DSHSessionSnapshotStore *sessions = [[DSHSessionSnapshotStore alloc]
      initWithRootURL:sessionRoot
           sessionURL:sessionURL
      launchInstanceId:relaunchId
            coordinator:nil
              faultHook:nil];
  XCTAssertNotNil(sessions);
  NSError *loadError = nil;
  NSDictionary *loaded = [sessions loadSessionSnapshotWithError:&loadError];
  XCTAssertNil(loadError);
  XCTAssertEqualObjects(loaded[@"status"], @"present");
  XCTAssertEqualObjects(loaded[@"writer_launch_instance_id"],
      @"fdefd001-889c-460d-9886-afd3886fc7f5");
  XCTAssertEqualObjects(loaded[@"current_launch_instance_id"], relaunchId);
  if (![loaded[@"status"] isEqualToString:@"present"]) return nil;

  DSHAgentNativeWAL *wal = [[DSHAgentNativeWAL alloc]
      initWithRootURL:walRoot clock:^NSDate * { return NSDate.date; }
      identifierGenerator:^NSString * {
        return @"fcfcfcfc-fcfc-4fcf-8fcf-fcfcfcfcfcfc";
      } faultHook:nil];
  XCTAssertNotNil(wal);
  NSError *walError = nil;
  NSDictionary *walSnapshot = [wal snapshotWithError:&walError];
  XCTAssertNil(walError);
  XCTAssertNotNil(walSnapshot);
  if (walSnapshot == nil) return nil;
  // The pulled WAL must contain the exact zombie residue: intent rows,
  // active reservations, and prepared authorities.
  NSUInteger intents = 0;
  for (NSDictionary *row in walSnapshot[@"ledger"]) {
    if ([row[@"state"] isEqualToString:@"intent"]) intents += 1;
  }
  XCTAssertGreaterThanOrEqual(intents, 3U);
  XCTAssertGreaterThanOrEqual([(NSArray *)walSnapshot[@"reservations"] count], 5U);
  XCTAssertGreaterThanOrEqual([(NSArray *)walSnapshot[@"authorities"] count], 30U);

  NSDictionary *evidenceRoot = @{ @"schema_version" : @1,
    @"kind" : @"workspace",
    @"workspace_id" : @"87640873-d08d-4a24-a326-78d72cdd2ec7",
    @"workspace_binding_revision" : @1, @"project_id" : NSNull.null,
    @"root_fingerprint_sha256" :
        @"2ad14e4ca2468f0c719104f4a7128ec68dc0890f04f88a6be183ecfb380cfa72",
    @"capabilities" : @[@"file_read", @"file_write"] };
  DSHEvidenceRootResolver *resolver = [[DSHEvidenceRootResolver alloc]
      initWithRoot:evidenceRoot];
  DSHAgentTranscriptStore *transcripts = [[DSHAgentTranscriptStore alloc]
      initWithWAL:wal];
  DSHAgentPreparedAttemptStore *prepared = [[DSHAgentPreparedAttemptStore alloc]
      initWithWAL:wal rootResolver:resolver sessionSnapshotStore:sessions
      transcriptStore:transcripts];
  DSHAgentExecutionLedger *ledger = [[DSHAgentExecutionLedger alloc]
      initWithWAL:wal];
  DSHAgentRuntimeCoordinator *coordinator = [[DSHAgentRuntimeCoordinator alloc]
      initForRecoveryTestingWithWAL:wal preparedStore:prepared
      roundService:(DSHAgentProviderRoundService *)(id)NSNull.null
      executionService:(DSHAgentToolExecutionService *)(id)NSNull.null
      transcripts:transcripts ledger:ledger];
  XCTAssertNotNil(coordinator);
  NSDictionary *envelope = [NSJSONSerialization JSONObjectWithData:envelopeBytes
      options:0 error:nil];
  XCTAssertTrue([envelope isKindOfClass:NSDictionary.class]);
  return @{ @"wal" : wal, @"sessions" : sessions, @"prepared" : prepared,
            @"coordinator" : coordinator, @"envelope" : envelope };
}

/// The exact prepare request the device issued for the fresh attempt in the
/// Smoke conversation (a DIFFERENT conversation bound to the same workspace
/// as the approval-pending zombie).
- (NSDictionary *)evidenceFreshPrepareRequestWithOperationId:(NSString *)operationId
                                                   attemptId:(NSString *)newAttempt
                                           sessionGeneration:(NSNumber *)sessionGeneration
                                               sessionSHA256:(NSString *)sessionSHA256 {
  NSString *newConversation = @"db9c06db-7880-4ba0-8fae-54a230584e3f";
  NSString *newTask = @"af0322f0-abc4-461c-a298-7ae81bc7ae98";
  NSArray *visibleIds = @[
    @"17f69ddf-c2dc-4b6f-b3ed-404a4c22c600",
    @"06c9a91f-fbbe-490a-a4d4-42971afc59a8",
    @"0c481945-b3db-44b7-9113-b3f70aa77149",
  ];
  NSArray *visibleMessages = @[
    @{ @"role" : @"user",
       @"content" : @"Use write_file to write SMOKE-2.md with exact content "
                     @"“provider smoke 0903”; then use read_file to read it "
                     @"back and confirm the exact content; finally reply in "
                     @"one sentence summarizing what you did.",
       @"attachments" : @[] },
    @{ @"role" : @"assistant",
       @"content" : @"I wrote the file SMOKE-2.md with the exact content "
                     @"\"provider smoke 0903\" and then read it back, "
                     @"confirming it contains exactly that content.",
       @"attachments" : @[] },
    @{ @"role" : @"user",
       @"content" : @"Reate three new files LOCK-A4-1.md, LOCK-A4-2.md, and "
                     @"LOCK-A4-3.md with exact contents one, two, and three "
                     @"respectively. Use write_file.",
       @"attachments" : @[] },
  ];
  NSString *visibleDigest = DSHAgentHJ(@"visible-history",
      @{ @"messages" : visibleMessages }, nil);
  XCTAssertNotNil(visibleDigest);
  return @{
    @"schema_version" : @2,
    @"operation_id" : operationId,
    @"controller_cas" : @{ @"schema_version" : @1,
      @"conversation_id" : newConversation,
      @"task_id" : newTask,
      @"attempt_id" : newAttempt,
      @"expected_controller_generation" : @0,
      @"expected_journal_revision" : @0,
      @"expected_session_generation" : sessionGeneration,
      @"expected_session_sha256" : sessionSHA256 },
    @"committed_checkpoint" : @{ @"schema_version" : @1,
      @"journal_revision" : @0,
      @"session_generation" : sessionGeneration,
      @"session_sha256" : sessionSHA256 },
    @"task_id" : newTask,
    @"conversation_id" : newConversation,
    @"attempt_id" : newAttempt,
    @"workspace_id" : @"87640873-d08d-4a24-a326-78d72cdd2ec7",
    @"project_id" : NSNull.null,
    @"workspace_binding_revision" : @1,
    @"transport_schema_version" : @2,
    @"model" : @"deepseek-v4-flash",
    @"thinking_mode" : @"high",
    @"visible_message_ids" : visibleIds,
    @"visible_history_sha256" : visibleDigest,
    @"visible_message_count" : @3,
    @"project_context_sha256" : NSNull.null,
    @"registry_version" : @1,
    @"expected_policy_version" : @"agent-v1",
    @"expected_transcript" : NSNull.null,
  };
}

/// Commits a shared JS parity fixture over the present snapshot, modelling
/// the launch-time CAS migration.  Returns the committed snapshot ref.
- (NSDictionary *)evidenceCommitFixtureNamed:(NSString *)name
                                    sessions:(DSHSessionSnapshotStore *)sessions
                                 operationId:(NSString *)operationId
                            expectedSnapshot:(NSDictionary *)expectedSnapshot {
  NSData *bytes = [self bundleFixtureBytesNamed:name];
  XCTAssertNotNil(bytes);
  if (bytes == nil) return nil;
  NSString *candidate = [[[NSString alloc] initWithData:bytes
      encoding:NSUTF8StringEncoding]
      stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
  NSError *casError = nil;
  NSDictionary *cas = [sessions casPersistSession:@{
    @"schema_version" : @1,
    @"operation_id" : operationId,
    @"expected" : @{ @"schema_version" : @1, @"kind" : @"present",
                     @"snapshot" : expectedSnapshot },
    @"candidate_json" : candidate,
  } error:&casError];
  XCTAssertNil(casError);
  XCTAssertEqualObjects(cas[@"status"], @"committed");
  return [cas[@"status"] isEqualToString:@"committed"] ? cas[@"snapshot"] : nil;
}

- (NSUInteger)evidenceResidueForAttempt:(NSString *)attemptId
                                   wal:(DSHAgentNativeWAL *)wal {
  NSError *walError = nil;
  NSDictionary *walSnapshot = [wal snapshotWithError:&walError];
  XCTAssertNil(walError);
  NSUInteger residue = 0;
  for (NSDictionary *row in walSnapshot[@"authorities"]) {
    if ([row[@"attempt_id"] isEqual:attemptId]) residue += 1;
  }
  for (NSDictionary *row in walSnapshot[@"transcripts"]) {
    if ([row[@"attempt_id"] isEqual:attemptId]) residue += 1;
  }
  for (NSDictionary *row in walSnapshot[@"ledger"]) {
    if ([row[@"locator"][@"attempt_id"] isEqual:attemptId]) residue += 1;
  }
  for (NSDictionary *row in walSnapshot[@"reservations"]) {
    if ([row[@"attempt_id"] isEqual:attemptId]) residue += 1;
  }
  for (NSDictionary *row in walSnapshot[@"batches"]) {
    if ([row[@"attempt_id"] isEqual:attemptId]) residue += 1;
  }
  for (NSDictionary *row in walSnapshot[@"dispatch"]) {
    if ([row[@"locator"][@"attempt_id"] isEqual:attemptId]) residue += 1;
  }
  return residue;
}

- (void)testEvidenceUntouchedResidueDoesNotBlockFreshPrepareInOtherConversation {
  // Root-cause pin for the device E_AGENT_PERSISTENCE: against the pulled WAL
  // (37 prepared authorities, active write reservations, never-dispatched
  // intent rows, one finalize operation left in started) and the pulled
  // session, the exact fresh prepare the device issued for the Smoke
  // conversation commits.  The stale residue therefore does not block new
  // attempts at the WAL/session layer; interruption recovery still discards
  // it so no reservation or intent can outlive its dead writer.
  NSDictionary *harness = [self evidenceHarnessNamed:@"evidence-untouched"];
  if (harness == nil) return;
  DSHAgentNativeWAL *wal = harness[@"wal"];
  DSHAgentPreparedAttemptStore *prepared = harness[@"prepared"];
  NSDictionary *envelope = harness[@"envelope"];
  NSError *prepareError = nil;
  NSDictionary *result = [prepared prepareAgentAttemptWithRequest:
      [self evidenceFreshPrepareRequestWithOperationId:
          @"fafafafa-fafa-4faf-8faf-fafafafafafa"
          attemptId:@"3c9ff09d-7002-44b8-a41d-c60fd8a435a9"
          sessionGeneration:envelope[@"generation"]
          sessionSHA256:envelope[@"session_sha256"]]
      error:&prepareError];
  XCTAssertNil(prepareError);
  XCTAssertEqualObjects(result[@"status"], @"prepared");
  NSError *walError = nil;
  NSDictionary *walSnapshot = [wal snapshotWithError:&walError];
  XCTAssertNil(walError);
  XCTAssertEqualObjects(walSnapshot[@"generation"], @496);
  XCTAssertEqual([(NSArray *)walSnapshot[@"authorities"] count], 38U);
  // The zombie's residue is untouched by an unrelated prepare.
  XCTAssertGreaterThan([self evidenceResidueForAttempt:
      @"b766c10b-4e61-449c-a30d-2a0b3f0041bb" wal:wal], 0U);
}

- (void)testEvidenceScenarioStaleAttemptsInterruptedThenFreshAttemptPrepares {
  NSDictionary *harness = [self evidenceHarnessNamed:@"evidence"];
  if (harness == nil) return;
  DSHAgentNativeWAL *wal = harness[@"wal"];
  DSHSessionSnapshotStore *sessions = harness[@"sessions"];
  DSHAgentPreparedAttemptStore *prepared = harness[@"prepared"];
  DSHAgentRuntimeCoordinator *coordinator = harness[@"coordinator"];
  NSDictionary *envelope = harness[@"envelope"];

  // 1. Launch-time CAS migration: the JS-recovered session (every
  //    non-terminal attempt failed/E_ATTEMPT_INTERRUPTED with derived
  //    cleanup entries) commits over the pulled snapshot.
  NSDictionary *recoveredSnapshot = [self
      evidenceCommitFixtureNamed:@"agent-interrupted-recovery-session"
                        sessions:sessions
                     operationId:@"fdfdfdfd-fdfd-4fdf-8fdf-fdfdfdfdfdfd"
                expectedSnapshot:@{ @"schema_version" : @1,
                  @"generation" : envelope[@"generation"],
                  @"session_sha256" : envelope[@"session_sha256"] }];
  if (recoveredSnapshot == nil) return;
  XCTAssertEqualObjects(recoveredSnapshot[@"generation"],
      @([envelope[@"generation"] unsignedIntegerValue] + 1));

  // 2. The derived cleanup entry for the approval-pending zombie (b766c10b:
  //    three intent write_file rows, a closed write batch, an 11-byte
  //    reservation) comes from the committed session itself.
  NSData *recoveredBytes = [self bundleFixtureBytesNamed:
      @"agent-interrupted-recovery-session"];
  NSDictionary *recovered = [NSJSONSerialization JSONObjectWithData:recoveredBytes
      options:0 error:nil];
  NSString *approvalAttempt = @"b766c10b-4e61-449c-a30d-2a0b3f0041bb";
  NSDictionary *entry = nil;
  for (NSDictionary *candidate in recovered[@"agent_transcript_cleanup_outbox"]) {
    if ([candidate[@"attempt_id"] isEqual:approvalAttempt]) entry = candidate;
  }
  XCTAssertNotNil(entry);
  if (entry == nil) return;
  XCTAssertEqualObjects(entry[@"reason"], @"failed");
  XCTAssertEqualObjects(entry[@"transcript_ref"],
      @"9ac4118f-8cce-46e9-bdf4-96922b0b061f");
  XCTAssertGreaterThan([self evidenceResidueForAttempt:approvalAttempt wal:wal], 0U);

  // 3. The launch drain interrupts the zombie through the coordinator proof
  //    gate bound to the committed recovered snapshot.
  NSDictionary *interruptRequest = @{
    @"schema_version" : @2,
    @"operation_id" : @"fbfbfbfb-fbfb-4fbf-8fbf-fbfbfbfbfbfb",
    @"cleanup_id" : entry[@"cleanup_id"],
    @"task_id" : entry[@"task_id"],
    @"conversation_id" : entry[@"conversation_id"],
    @"attempt_id" : approvalAttempt,
    @"transcript_ref" : entry[@"transcript_ref"],
    @"transcript_sha256" : entry[@"transcript_sha256"],
    @"reason" : @"failed",
    @"expected_session_generation" : recoveredSnapshot[@"generation"],
    @"expected_session_sha256" : recoveredSnapshot[@"session_sha256"],
  };
  NSError *interruptError = nil;
  NSDictionary *interrupted = [coordinator interruptAgentAttempt:interruptRequest
                                                            error:&interruptError];
  XCTAssertNil(interruptError);
  XCTAssertEqualObjects(interrupted[@"status"], @"discarded");
  // Authority, transcript, intent rows, reservation, batch, and dispatch rows
  // are gone: nothing of the zombie can ever replay.
  XCTAssertEqual([self evidenceResidueForAttempt:approvalAttempt wal:wal], 0U);
  NSError *walError = nil;
  NSDictionary *walSnapshot = [wal snapshotWithError:&walError];
  XCTAssertNil(walError);
  NSDictionary *cleanupRow = nil;
  for (NSDictionary *row in walSnapshot[@"cleanup"]) {
    if ([row[@"cleanup_id"] isEqual:entry[@"cleanup_id"]]) cleanupRow = row;
  }
  XCTAssertEqualObjects(cleanupRow[@"status"], @"discarded");
  XCTAssertEqualObjects(cleanupRow[@"reason"], @"failed");
  // Replay of the same operation is idempotent.
  NSDictionary *replay = [coordinator interruptAgentAttempt:interruptRequest
                                                       error:&interruptError];
  XCTAssertNil(interruptError);
  XCTAssertEqualObjects(replay, interrupted);

  // 4. Retry in the Smoke conversation (a DIFFERENT conversation bound to
  //    the same workspace) persists a fresh attempt in the same turn; the
  //    native store commits that session and the fresh prepare succeeds
  //    against it (the operation that failed with E_AGENT_PERSISTENCE on
  //    the device).
  NSDictionary *retrySnapshot = [self
      evidenceCommitFixtureNamed:@"agent-interrupted-retry-session"
                        sessions:sessions
                     operationId:@"fefefefe-fefe-4fef-8fef-fefefefefefe"
                expectedSnapshot:recoveredSnapshot];
  if (retrySnapshot == nil) return;
  NSError *prepareError = nil;
  NSDictionary *preparedResult = [prepared prepareAgentAttemptWithRequest:
      [self evidenceFreshPrepareRequestWithOperationId:
          @"fafafafa-fafa-4faf-8faf-fafafafafafa"
          attemptId:@"9e4fadc3-606e-4019-923c-e970f4bd6c25"
          sessionGeneration:retrySnapshot[@"generation"]
          sessionSHA256:retrySnapshot[@"session_sha256"]]
      error:&prepareError];
  XCTAssertNil(prepareError);
  XCTAssertNotNil(preparedResult);
  XCTAssertEqualObjects(preparedResult[@"status"], @"prepared");
}

- (void)testDiscardRejectsAndPreservesUnresolvedOperationEvidence {
  DSHRecoveryWAL *wal = [[DSHRecoveryWAL alloc]
      initWithRootURL:[self.rootURL URLByAppendingPathComponent:@"discard-unresolved"]
      clock:^NSDate * { return NSDate.date; }
      identifierGenerator:^NSString * {
        return @"20202020-2020-4020-8020-202020202020";
      } faultHook:nil];
  NSDictionary *authority = @{ @"task_id" : @"22222222-2222-4222-8222-222222222222",
    @"conversation_id" : @"11111111-1111-4111-8111-111111111111",
    @"attempt_id" : @"33333333-3333-4333-8333-333333333333",
    @"root" : [self recoveryRoot], @"transcript" : [self recoveryTranscript],
    @"state" : @"cleanup_pending",
    @"cleanup_id" : @"13131313-1313-4313-8313-131313131313",
    @"authority_revision" : @2 };
  NSDictionary *cleanup = @{ @"schema_version" : @1,
    @"cleanup_id" : authority[@"cleanup_id"],
    @"attempt_id" : authority[@"attempt_id"],
    @"transcript_ref" : [self recoveryTranscript][@"transcript_ref"],
    @"transcript_sha256" : [self recoveryTranscript][@"transcript_sha256"],
    @"cleanup_owner" : authority[@"task_id"], @"reason" : @"completed",
    @"created_at" : @"2026-08-31T00:00:00.000Z", @"status" : @"pending" };
  NSString *unresolvedId = @"21212121-2121-4121-8121-212121212121";
  wal.recoveryState = @{ @"authorities" : @[authority], @"cleanup" : @[cleanup],
    @"transcripts" : @[@{ @"attempt_id" : authority[@"attempt_id"],
      @"transcript_ref" : [self recoveryTranscript][@"transcript_ref"],
      @"transcript_sha256" : [self recoveryTranscript][@"transcript_sha256"],
      @"state" : @"terminal" }],
    @"rounds" : @[], @"ledger" : @[], @"reservations" : @[], @"batches" : @[],
    @"denied_calls" : @[], @"dispatch" : @[],
    @"operations" : @[@{ @"operation_id" : unresolvedId,
      @"attempt_id" : authority[@"attempt_id"], @"state" : @"unknown" }],
    @"operation_results" : @[@{ @"operation_id" : unresolvedId,
      @"marker" : @"must-survive" }] };
  DSHRecoveryRuntimeCoordinator *fixture =
      [self recoveryCoordinatorWithWAL:wal roundService:nullptr
          executionService:nullptr];
  NSError *error = nil;
  NSDictionary *result = [fixture discardAgentAttempt:@{
    @"schema_version" : @2,
    @"operation_id" : @"22222222-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    @"cleanup_id" : authority[@"cleanup_id"], @"task_id" : authority[@"task_id"],
    @"conversation_id" : authority[@"conversation_id"],
    @"attempt_id" : authority[@"attempt_id"],
    @"transcript_ref" : [self recoveryTranscript][@"transcript_ref"],
    @"transcript_sha256" : [self recoveryTranscript][@"transcript_sha256"]
  } error:&error];
  XCTAssertNil(result);
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorConflict);
  NSPredicate *unresolved = [NSPredicate predicateWithBlock:
      ^BOOL(NSDictionary *operation, NSDictionary *bindings) {
    (void)bindings;
    return [operation[@"operation_id"] isEqual:unresolvedId];
  }];
  XCTAssertEqual([wal.recoveryState[@"operations"]
      filteredArrayUsingPredicate:unresolved].count, 1U);
  XCTAssertEqualObjects(wal.recoveryState[@"operation_results"][0][@"marker"],
                        @"must-survive");
  XCTAssertEqual([wal.recoveryState[@"authorities"] count], 1U);
}

@end
