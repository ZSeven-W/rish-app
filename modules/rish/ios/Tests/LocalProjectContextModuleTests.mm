#import <XCTest/XCTest.h>

#import "../../../../modules/rish/ios/Sources/ProjectContextService.h"

#include <math.h>

typedef void (^DSHPCResolve)(id value);
typedef void (^DSHPCReject)(NSString *code, NSString *message, NSError *error);

@protocol DSHLocalProjectContextModuleTesting <NSObject>
- (instancetype)initWithService:(DSHProjectContextService *)service
                   operationQueue:(dispatch_queue_t)operationQueue
                       maxPending:(NSUInteger)maxPending;
- (void)listProjectContextCandidates:(id)projectId
                                query:(id)query
                               cursor:(id)cursor
                             resolver:(DSHPCResolve)resolve
                             rejecter:(DSHPCReject)reject;
- (void)prepareProjectContext:(id)selection
                      resolver:(DSHPCResolve)resolve
                      rejecter:(DSHPCReject)reject;
- (void)confirmProjectContext:(id)snapshotId
                      resolver:(DSHPCResolve)resolve
                      rejecter:(DSHPCReject)reject;
- (void)inspectProjectContext:(id)snapshotId
                      resolver:(DSHPCResolve)resolve
                      rejecter:(DSHPCReject)reject;
- (void)discardProjectContext:(id)snapshotId
                      resolver:(DSHPCResolve)resolve
                      rejecter:(DSHPCReject)reject;
- (void)invalidate;
@end

@interface DSHFailingProjectContextStore : DSHProjectContextStore
@property(nonatomic) DSHProjectContextStoreErrorCode injectedCode;
@end

@implementation DSHFailingProjectContextStore
- (NSDictionary *)loadSnapshotId:(NSString *)snapshotId error:(NSError **)error {
  (void)snapshotId;
  if (error != nil) {
    *error = [NSError errorWithDomain:DSHProjectContextStoreErrorDomain
                                 code:self.injectedCode userInfo:@{}];
  }
  return nil;
}
- (BOOL)discardSnapshotId:(NSString *)snapshotId error:(NSError **)error {
  (void)snapshotId;
  if (error != nil) {
    *error = [NSError errorWithDomain:DSHProjectContextStoreErrorDomain
                                 code:self.injectedCode userInfo:@{}];
  }
  return NO;
}
@end

@interface DSHFakeProjectContextService : DSHProjectContextService
@property(nonatomic, strong) NSDictionary *listResult;
@property(nonatomic, strong) NSDictionary *prepareResult;
@property(nonatomic, strong) NSDictionary *confirmResult;
@property(nonatomic, strong) NSDictionary *inspectResult;
@property(nonatomic) BOOL discardResult;
@property(nonatomic) DSHProjectContextServiceErrorCode failureCode;
@property(nonatomic, strong) NSError *foreignError;
@property(nonatomic, strong) NSException *exception;
@property(nonatomic, copy) void (^beforeOperation)(NSString *name);
@property(nonatomic, strong) NSMutableArray<NSString *> *events;
@property(nonatomic, strong) NSDictionary *capturedSelection;
@property(nonatomic) NSUInteger listCalls;
@property(nonatomic) NSUInteger prepareCalls;
@property(nonatomic) NSUInteger confirmCalls;
@property(nonatomic) NSUInteger inspectCalls;
@property(nonatomic) NSUInteger discardCalls;
@end

@implementation DSHFakeProjectContextService

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _events = [NSMutableArray array];
    _discardResult = YES;
  }
  return self;
}

- (id)finish:(NSString *)name result:(id)result error:(NSError **)error {
  @synchronized (self) {
    [self.events addObject:name];
  }
  if (self.beforeOperation != nil) self.beforeOperation(name);
  if (self.exception != nil) @throw self.exception;
  if (self.foreignError != nil) {
    if (error != nil) *error = self.foreignError;
    return nil;
  }
  if (self.failureCode != 0) {
    if (error != nil) {
      *error = [NSError errorWithDomain:DSHProjectContextServiceErrorDomain
                                   code:self.failureCode userInfo:@{}];
    }
    return nil;
  }
  return result;
}

- (NSDictionary *)listCandidatesForProjectId:(NSString *)projectId
                                         query:(NSString *)query
                                        cursor:(NSString *)cursor
                                         error:(NSError **)error {
  self.listCalls += 1;
  return [self finish:@"list" result:self.listResult error:error];
}

- (NSDictionary *)prepareSelection:(NSDictionary *)selection
                              error:(NSError **)error {
  self.prepareCalls += 1;
  self.capturedSelection = selection;
  return [self finish:@"prepare" result:self.prepareResult error:error];
}

- (NSDictionary *)confirmSnapshotId:(NSString *)snapshotId
                               error:(NSError **)error {
  self.confirmCalls += 1;
  return [self finish:@"confirm" result:self.confirmResult error:error];
}

- (NSDictionary *)inspectSnapshotId:(NSString *)snapshotId
                               error:(NSError **)error {
  self.inspectCalls += 1;
  return [self finish:@"inspect" result:self.inspectResult error:error];
}

- (BOOL)discardSnapshotId:(NSString *)snapshotId error:(NSError **)error {
  self.discardCalls += 1;
  id value = [self finish:@"discard"
                    result:self.discardResult ? @YES : nil error:error];
  return [value isEqual:@YES];
}

@end

@interface DSHThrowingDictionary : NSDictionary
@property(nonatomic) NSUInteger fakeCount;
- (instancetype)initWithCount:(NSUInteger)count;
@end

@implementation DSHThrowingDictionary
- (instancetype)initWithCount:(NSUInteger)count {
  self = [super init];
  if (self != nil) _fakeCount = count;
  return self;
}
- (NSUInteger)count { return self.fakeCount; }
- (NSEnumerator *)keyEnumerator {
  @throw [NSException exceptionWithName:@"container-sentinel"
                                 reason:@"secret" userInfo:nil];
}
- (id)objectForKey:(id)key {
  (void)key;
  @throw [NSException exceptionWithName:@"container-sentinel"
                                 reason:@"secret" userInfo:nil];
}
@end

@interface LocalProjectContextModuleTests : XCTestCase
@end

@implementation LocalProjectContextModuleTests

static NSString *const DSHProjectId =
    @"11111111-1111-4111-8111-111111111111";
static NSString *const DSHConversationId =
    @"22222222-2222-4222-8222-222222222222";
static NSString *const DSHSnapshotId =
    @"33333333-3333-4333-8333-333333333333";
static NSString *const DSHConsentId =
    @"44444444-4444-4444-8444-444444444444";

- (NSDictionary *)selection {
  return @{
    @"schema_version": @1,
    @"project_id": DSHProjectId,
    @"conversation_id": DSHConversationId,
    @"provider": @"deepseek",
    @"model": @"deepseek-v4-flash",
    @"policy": @"chat-read-v1",
    @"selected_paths": @[@"src/z.ts", @"README.md"],
  };
}

- (NSDictionary *)manifest {
  NSString *digest = [@"" stringByPaddingToLength:64
                                         withString:@"a" startingAtIndex:0];
  NSString *head = [@"" stringByPaddingToLength:40
                                       withString:@"b" startingAtIndex:0];
  return @{
    @"schema_version": @1,
    @"snapshot_id": DSHSnapshotId,
    @"project_id": DSHProjectId,
    @"project_name": @"Fixture",
    @"branch": @"main",
    @"head_oid": head,
    @"clean": @YES,
    @"conflicted": @NO,
    @"captured_at": @"2026-08-28T00:00:00.000Z",
    @"policy_version": @"chat-read-v1.0.0",
    @"provider_host": @"api.deepseek.com",
    @"model": @"deepseek-v4-flash",
    @"included": @[@{
      @"path": @"README.md", @"source": @"tracked_file", @"bytes": @12,
      @"sha256": digest,
    }],
    @"omitted": @[@{@"path": @".env", @"reason": @"secret_path"}],
    @"context_bytes": @20,
    @"estimated_tokens": @5,
    @"snapshot_sha256": digest,
    @"source_fingerprint": digest,
  };
}

- (NSDictionary *)candidatePage {
  NSString *revision = [@"" stringByPaddingToLength:64
                                           withString:@"c" startingAtIndex:0];
  return @{
    @"schema_version": @1,
    @"project_id": DSHProjectId,
    @"candidates": @[@{
      @"path": @"README.md", @"size": @12, @"revision": revision,
      @"git_state": @"unchanged", @"eligible": @YES,
      @"omission_reason": NSNull.null,
    }],
    @"next_cursor": NSNull.null,
  };
}

- (NSDictionary *)consent {
  NSString *digest = [@"" stringByPaddingToLength:64
                                         withString:@"a" startingAtIndex:0];
  return @{
    @"schema_version": @1,
    @"consent_receipt_id": DSHConsentId,
    @"snapshot_id": DSHSnapshotId,
    @"snapshot_sha256": digest,
    @"confirmed_at": @"2026-08-28T00:00:01.000Z",
  };
}

- (DSHFakeProjectContextService *)fakeService {
  DSHFakeProjectContextService *service =
      [[DSHFakeProjectContextService alloc] init];
  service.listResult = [self candidatePage];
  service.prepareResult = [self manifest];
  service.confirmResult = [self consent];
  NSMutableDictionary *inspection = [[self manifest] mutableCopy];
  inspection[@"state"] = @"confirmed";
  service.inspectResult = inspection;
  return service;
}

- (id<DSHLocalProjectContextModuleTesting>)moduleWithService:
    (DSHProjectContextService *)service maxPending:(NSUInteger)maxPending {
  Class cls = NSClassFromString(@"LocalProjectContextModule");
  XCTAssertNotNil(cls);
  return [[(id)cls alloc]
      initWithService:service
       operationQueue:dispatch_queue_create(
           "dev.zseven.rish.project-context-tests", DISPATCH_QUEUE_SERIAL)
           maxPending:maxPending];
}

- (void)testLocalProjectContextNativeModuleIsLinked {
  Class moduleClass = NSClassFromString(@"LocalProjectContextModule");
  XCTAssertNotNil(moduleClass);
  XCTAssertTrue([moduleClass instancesRespondToSelector:
      NSSelectorFromString(@"listProjectContextCandidates:query:cursor:resolver:rejecter:")]);
}

- (void)testMalformedInputRejectsSynchronouslyWithoutCallingService {
  DSHFakeProjectContextService *service = [self fakeService];
  id<DSHLocalProjectContextModuleTesting> module =
      [self moduleWithService:service maxPending:16];
  NSMutableDictionary *bad = [[self selection] mutableCopy];
  bad[@"raw_content"] = @"request-sentinel";
  __block NSString *code = nil;
  [module prepareProjectContext:bad resolver:^(__unused id value) {
    XCTFail(@"must not resolve");
  } rejecter:^(NSString *value, NSString *message, NSError *error) {
    code = value;
    XCTAssertEqualObjects(message, value);
    XCTAssertNil(error);
  }];
  XCTAssertEqualObjects(code, @"E_CONTEXT_REQUEST_INVALID");
  XCTAssertEqual(service.prepareCalls, 0u);
}

- (void)testRawNativeTypesRejectSynchronouslyWithoutServiceCalls {
  for (id raw in @[@1, @YES, @[], NSNull.null]) {
    DSHFakeProjectContextService *service = [self fakeService];
    id<DSHLocalProjectContextModuleTesting> module =
        [self moduleWithService:service maxPending:16];
    DSHPCResolve resolve = ^(__unused id value) { XCTFail(@"must not resolve"); };
    DSHPCReject reject = ^(NSString *code, NSString *message, NSError *error) {
      XCTAssertEqualObjects(code, @"E_CONTEXT_REQUEST_INVALID");
      XCTAssertEqualObjects(message, code);
      XCTAssertNil(error);
    };
    [module listProjectContextCandidates:raw query:@"" cursor:nil
                                resolver:resolve rejecter:reject];
    [module prepareProjectContext:raw resolver:resolve rejecter:reject];
    [module confirmProjectContext:raw resolver:resolve rejecter:reject];
    [module inspectProjectContext:raw resolver:resolve rejecter:reject];
    [module discardProjectContext:raw resolver:resolve rejecter:reject];
    XCTAssertEqual(service.listCalls, 0u);
    XCTAssertEqual(service.prepareCalls, 0u);
    XCTAssertEqual(service.confirmCalls, 0u);
    XCTAssertEqual(service.inspectCalls, 0u);
    XCTAssertEqual(service.discardCalls, 0u);
  }
}

- (void)testHostileInputAndResultContainersMapToNativeWithoutLeaking {
  DSHFakeProjectContextService *service = [self fakeService];
  id<DSHLocalProjectContextModuleTesting> module =
      [self moduleWithService:service maxPending:16];
  __block NSString *inputCode = nil;
  [module prepareProjectContext:(NSDictionary *)[[DSHThrowingDictionary alloc]
                                      initWithCount:7]
      resolver:^(__unused id value) { XCTFail(@"must not resolve"); }
      rejecter:^(NSString *code, NSString *message, NSError *error) {
        inputCode = code;
        XCTAssertEqualObjects(message, code);
        XCTAssertNil(error);
      }];
  XCTAssertEqualObjects(inputCode, @"E_CONTEXT_NATIVE");
  XCTAssertEqual(service.prepareCalls, 0u);

  service.prepareResult = (NSDictionary *)[[DSHThrowingDictionary alloc]
      initWithCount:18];
  XCTestExpectation *rejected = [self expectationWithDescription:@"result"];
  [module prepareProjectContext:[self selection]
      resolver:^(__unused id value) { XCTFail(@"must not resolve"); }
      rejecter:^(NSString *code, NSString *message, NSError *error) {
        XCTAssertEqualObjects(code, @"E_CONTEXT_NATIVE");
        XCTAssertEqualObjects(message, code);
        XCTAssertNil(error);
        [rejected fulfill];
      }];
  [self waitForExpectations:@[rejected] timeout:1];
}

- (void)testStrictNumbersPathsAndGitBranchFailClosed {
  DSHFakeProjectContextService *integralFloatService = [self fakeService];
  id<DSHLocalProjectContextModuleTesting> integralFloatModule =
      [self moduleWithService:integralFloatService maxPending:16];
  NSMutableDictionary *integralFloat = [[self selection] mutableCopy];
  integralFloat[@"schema_version"] = @1.0;
  XCTestExpectation *integralAccepted =
      [self expectationWithDescription:@"integral float accepted"];
  [integralFloatModule prepareProjectContext:integralFloat
      resolver:^(__unused id value) { [integralAccepted fulfill]; }
      rejecter:^(__unused NSString *code, __unused NSString *message,
                 __unused NSError *error) {
        XCTFail(@"bridged integral JS number must be accepted");
        [integralAccepted fulfill];
      }];
  [self waitForExpectations:@[integralAccepted] timeout:1];
  XCTAssertEqual(integralFloatService.prepareCalls, 1u);

  NSArray *badNumbers = @[
    @(-0.0), @1.5, @(NAN), @YES,
    [NSDecimalNumber decimalNumberWithString:@"1.00000000000000000001"],
  ];
  for (NSNumber *number in badNumbers) {
    DSHFakeProjectContextService *service = [self fakeService];
    id<DSHLocalProjectContextModuleTesting> module =
        [self moduleWithService:service maxPending:16];
    NSMutableDictionary *bad = [[self selection] mutableCopy];
    bad[@"schema_version"] = number;
    XCTestExpectation *rejected = [self expectationWithDescription:@"number"];
    [module prepareProjectContext:bad resolver:^(__unused id value) {
      XCTFail(@"must not resolve");
    } rejecter:^(NSString *code, __unused NSString *message,
                 __unused NSError *error) {
      XCTAssertEqualObjects(code, @"E_CONTEXT_REQUEST_INVALID");
      [rejected fulfill];
    }];
    [self waitForExpectations:@[rejected] timeout:1];
    XCTAssertEqual(service.prepareCalls, 0u);
  }

  unichar highSurrogate = 0xD800;
  NSString *invalidUTF16 = [NSString stringWithCharacters:&highSurrogate length:1];
  for (NSString *path in @[@"line\nbreak", @"../escape", @"a\\b",
                            @"/absolute", invalidUTF16]) {
    DSHFakeProjectContextService *service = [self fakeService];
    id<DSHLocalProjectContextModuleTesting> module =
        [self moduleWithService:service maxPending:16];
    NSMutableDictionary *bad = [[self selection] mutableCopy];
    bad[@"selected_paths"] = @[path];
    __block NSString *code = nil;
    [module prepareProjectContext:bad resolver:^(__unused id value) {
      XCTFail(@"must not resolve");
    } rejecter:^(NSString *value, __unused NSString *message,
                 __unused NSError *error) { code = value; }];
    XCTAssertEqualObjects(code, @"E_CONTEXT_REQUEST_INVALID");
    XCTAssertEqual(service.prepareCalls, 0u);
  }

  NSMutableDictionary *badBranch = [[self manifest] mutableCopy];
  badBranch[@"branch"] = @"bad..branch";
  NSMutableDictionary *atBranch = [[self manifest] mutableCopy];
  atBranch[@"branch"] = @"@";
  NSMutableDictionary *controlName = [[self manifest] mutableCopy];
  controlName[@"project_name"] = @"bad\nname";
  NSMutableDictionary *absoluteName = [[self manifest] mutableCopy];
  absoluteName[@"project_name"] = @"/private/raw-path-sentinel";
  NSMutableDictionary *backslashName = [[self manifest] mutableCopy];
  backslashName[@"project_name"] = @"raw\\path-sentinel";
  NSMutableDictionary *whitespaceName = [[self manifest] mutableCopy];
  whitespaceName[@"project_name"] = @"   ";
  NSMutableDictionary *paddedName = [[self manifest] mutableCopy];
  paddedName[@"project_name"] = @" Fixture ";
  NSMutableDictionary *negativeZeroIncluded = [[self manifest] mutableCopy];
  NSMutableDictionary *included =
      [negativeZeroIncluded[@"included"][0] mutableCopy];
  included[@"bytes"] = @(-0.0);
  negativeZeroIncluded[@"included"] = @[included];
  NSMutableDictionary *negativeZeroContext = [[self manifest] mutableCopy];
  negativeZeroContext[@"context_bytes"] = @(-0.0);
  for (NSDictionary *badManifest in @[
      badBranch, atBranch, controlName, absoluteName, backslashName,
      whitespaceName, paddedName, negativeZeroIncluded, negativeZeroContext]) {
    DSHFakeProjectContextService *service = [self fakeService];
    service.prepareResult = badManifest;
    id<DSHLocalProjectContextModuleTesting> module =
        [self moduleWithService:service maxPending:16];
    XCTestExpectation *rejected = [self expectationWithDescription:@"manifest"];
    [module prepareProjectContext:[self selection]
        resolver:^(__unused id value) { XCTFail(@"must not resolve"); }
        rejecter:^(NSString *code, __unused NSString *message,
                   __unused NSError *error) {
          XCTAssertEqualObjects(code, @"E_CONTEXT_RESULT_INVALID");
          [rejected fulfill];
        }];
    [self waitForExpectations:@[rejected] timeout:1];
  }
  DSHFakeProjectContextService *candidateService = [self fakeService];
  NSMutableDictionary *badPage = [[self candidatePage] mutableCopy];
  NSMutableDictionary *badCandidate = [badPage[@"candidates"][0] mutableCopy];
  badCandidate[@"size"] = @(-0.0);
  badPage[@"candidates"] = @[badCandidate];
  candidateService.listResult = badPage;
  id<DSHLocalProjectContextModuleTesting> candidateModule =
      [self moduleWithService:candidateService maxPending:16];
  XCTestExpectation *candidateRejected =
      [self expectationWithDescription:@"candidate"];
  [candidateModule listProjectContextCandidates:DSHProjectId query:@"" cursor:nil
      resolver:^(__unused id value) { XCTFail(@"must not resolve"); }
      rejecter:^(NSString *code, __unused NSString *message,
                 __unused NSError *error) {
        XCTAssertEqualObjects(code, @"E_CONTEXT_RESULT_INVALID");
        [candidateRejected fulfill];
      }];
  [self waitForExpectations:@[candidateRejected] timeout:1];
}

- (void)testHappyPathProjectsExactFreshMetadataOnlyResults {
  DSHFakeProjectContextService *service = [self fakeService];
  id<DSHLocalProjectContextModuleTesting> module =
      [self moduleWithService:service maxPending:16];
  XCTestExpectation *list = [self expectationWithDescription:@"list"];
  [module listProjectContextCandidates:DSHProjectId query:@"" cursor:nil
      resolver:^(NSDictionary *value) {
        XCTAssertEqualObjects(value, [self candidatePage]);
        XCTAssertNotEqual(value, service.listResult);
        [list fulfill];
      } rejecter:^(__unused NSString *code, __unused NSString *message,
                   __unused NSError *error) { XCTFail(@"unexpected reject"); }];
  XCTestExpectation *prepare = [self expectationWithDescription:@"prepare"];
  [module prepareProjectContext:[self selection] resolver:^(NSDictionary *value) {
    XCTAssertEqual(value.count, 18u);
    XCTAssertNil(value[@"content"]);
    XCTAssertNil(value[@"envelope"]);
    [prepare fulfill];
  } rejecter:^(__unused NSString *code, __unused NSString *message,
               __unused NSError *error) { XCTFail(@"unexpected reject"); }];
  XCTestExpectation *confirm = [self expectationWithDescription:@"confirm"];
  [module confirmProjectContext:DSHSnapshotId resolver:^(NSDictionary *value) {
    XCTAssertEqualObjects(value, [self consent]);
    [confirm fulfill];
  } rejecter:^(__unused NSString *code, __unused NSString *message,
               __unused NSError *error) { XCTFail(@"unexpected reject"); }];
  XCTestExpectation *inspect = [self expectationWithDescription:@"inspect"];
  [module inspectProjectContext:DSHSnapshotId resolver:^(NSDictionary *value) {
    NSSet *expectedKeys = [NSSet setWithArray:
        @[@"schema_version", @"state", @"manifest"]];
    XCTAssertEqualObjects([NSSet setWithArray:value.allKeys],
                          expectedKeys);
    XCTAssertEqualObjects(value[@"state"], @"confirmed");
    [inspect fulfill];
  } rejecter:^(__unused NSString *code, __unused NSString *message,
               __unused NSError *error) { XCTFail(@"unexpected reject"); }];
  XCTestExpectation *discard = [self expectationWithDescription:@"discard"];
  [module discardProjectContext:DSHSnapshotId resolver:^(NSDictionary *value) {
    XCTAssertEqualObjects(value,
                          (@{@"schema_version": @1, @"status": @"discarded"}));
    [discard fulfill];
  } rejecter:^(__unused NSString *code, __unused NSString *message,
               __unused NSError *error) { XCTFail(@"unexpected reject"); }];
  [self waitForExpectations:@[list, prepare, confirm, inspect, discard] timeout:3];
}

- (void)testSelectionIsFrozenSortedAndCallerMutationCannotCrossQueue {
  DSHFakeProjectContextService *service = [self fakeService];
  dispatch_semaphore_t gate = dispatch_semaphore_create(0);
  service.beforeOperation = ^(NSString *name) {
    if ([name isEqual:@"prepare"]) {
      dispatch_semaphore_wait(gate,
          dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    }
  };
  id<DSHLocalProjectContextModuleTesting> module =
      [self moduleWithService:service maxPending:16];
  NSMutableDictionary *selection = [[self selection] mutableCopy];
  NSMutableArray *paths = [selection[@"selected_paths"] mutableCopy];
  selection[@"selected_paths"] = paths;
  XCTestExpectation *done = [self expectationWithDescription:@"done"];
  [module prepareProjectContext:selection resolver:^(__unused id value) {
    [done fulfill];
  } rejecter:^(__unused NSString *code, __unused NSString *message,
               __unused NSError *error) { XCTFail(@"unexpected reject"); }];
  [paths replaceObjectAtIndex:0 withObject:@"mutated-secret"];
  selection[@"model"] = @"deepseek-v4-pro";
  dispatch_semaphore_signal(gate);
  [self waitForExpectations:@[done] timeout:3];
  XCTAssertEqualObjects(service.capturedSelection[@"selected_paths"],
                        (@[@"README.md", @"src/z.ts"]));
  XCTAssertEqualObjects(service.capturedSelection[@"model"],
                        @"deepseek-v4-flash");
}

- (void)testServiceErrorsExceptionsAndRawSentinelsAreValueFree {
  NSArray<NSDictionary *> *cases = @[
    @{@"service": @(DSHProjectContextServiceErrorInvalidArgument),
      @"bridge": @"E_CONTEXT_REQUEST_INVALID"},
    @{@"service": @(DSHProjectContextServiceErrorProjectUnavailable),
      @"bridge": @"E_PROJECT_NOT_FOUND"},
    @{@"service": @(DSHProjectContextServiceErrorChanged),
      @"bridge": @"E_CONTEXT_CHANGED"},
    @{@"service": @(DSHProjectContextServiceErrorSecret),
      @"bridge": @"E_CONTEXT_SECRET"},
    @{@"service": @(DSHProjectContextServiceErrorBudgetExceeded),
      @"bridge": @"E_CONTEXT_BUDGET"},
    @{@"service": @(DSHProjectContextServiceErrorStorage),
      @"bridge": @"E_CONTEXT_STORAGE"},
    @{@"service": @(DSHProjectContextServiceErrorTimeout),
      @"bridge": @"E_CONTEXT_TIMEOUT"},
    @{@"service": @(DSHProjectContextServiceErrorConsent),
      @"bridge": @"E_CONTEXT_CONSENT_INVALID"},
    @{@"service": @(DSHProjectContextServiceErrorIntegrity),
      @"bridge": @"E_CONTEXT_INTEGRITY"},
    @{@"service": @(DSHProjectContextServiceErrorSnapshotMissing),
      @"bridge": @"E_CONTEXT_SNAPSHOT_MISSING"},
  ];
  for (NSDictionary *row in cases) {
    DSHFakeProjectContextService *service = [self fakeService];
    service.failureCode = (DSHProjectContextServiceErrorCode)
        [row[@"service"] integerValue];
    id<DSHLocalProjectContextModuleTesting> module =
        [self moduleWithService:service maxPending:16];
    XCTestExpectation *rejected = [self expectationWithDescription:@"error"];
    [module inspectProjectContext:DSHSnapshotId
        resolver:^(__unused id value) { XCTFail(@"must not resolve"); }
        rejecter:^(NSString *code, NSString *message, NSError *error) {
          XCTAssertEqualObjects(code, row[@"bridge"]);
          XCTAssertEqualObjects(message, code);
          XCTAssertNil(error);
          [rejected fulfill];
        }];
    [self waitForExpectations:@[rejected] timeout:1];
  }

  DSHFakeProjectContextService *throwing = [self fakeService];
  throwing.exception = [NSException exceptionWithName:@"raw-exception-sentinel"
                                               reason:@"secret" userInfo:nil];
  id<DSHLocalProjectContextModuleTesting> module =
      [self moduleWithService:throwing maxPending:16];
  XCTestExpectation *exception = [self expectationWithDescription:@"exception"];
  [module inspectProjectContext:DSHSnapshotId resolver:^(__unused id value) {
    XCTFail(@"must not resolve");
  } rejecter:^(NSString *code, __unused NSString *message,
               __unused NSError *error) {
    XCTAssertEqualObjects(code, @"E_CONTEXT_NATIVE");
    [exception fulfill];
  }];
  [self waitForExpectations:@[exception] timeout:1];

  DSHFakeProjectContextService *foreign = [self fakeService];
  foreign.foreignError = [NSError errorWithDomain:@"foreign-secret-domain"
                                              code:99 userInfo:@{
    NSLocalizedDescriptionKey: @"foreign-secret-message",
  }];
  module = [self moduleWithService:foreign maxPending:16];
  XCTestExpectation *foreignRejected =
      [self expectationWithDescription:@"foreign"];
  [module inspectProjectContext:DSHSnapshotId resolver:^(__unused id value) {
    XCTFail(@"must not resolve");
  } rejecter:^(NSString *code, NSString *message, NSError *error) {
    XCTAssertEqualObjects(code, @"E_CONTEXT_NATIVE");
    XCTAssertEqualObjects(message, code);
    XCTAssertNil(error);
    [foreignRejected fulfill];
  }];
  [self waitForExpectations:@[foreignRejected] timeout:1];

  NSDictionary *rawFields = @{
    @"content": @"raw-content-sentinel",
    @"absolute_path": @"/private/raw-path-sentinel",
    @"source_descriptor": @{@"device": @1},
    @"envelope": [@"raw-envelope-sentinel"
        dataUsingEncoding:NSUTF8StringEncoding],
  };
  for (NSString *key in rawFields) {
    DSHFakeProjectContextService *raw = [self fakeService];
    NSMutableDictionary *manifest = [[self manifest] mutableCopy];
    manifest[key] = rawFields[key];
    raw.prepareResult = manifest;
    module = [self moduleWithService:raw maxPending:16];
    XCTestExpectation *invalid = [self expectationWithDescription:@"invalid"];
    [module prepareProjectContext:[self selection] resolver:^(__unused id value) {
      XCTFail(@"must not resolve");
    } rejecter:^(NSString *code, NSString *message, NSError *error) {
      XCTAssertEqualObjects(code, @"E_CONTEXT_RESULT_INVALID");
      XCTAssertEqualObjects(message, code);
      XCTAssertNil(error);
      [invalid fulfill];
    }];
    [self waitForExpectations:@[invalid] timeout:1];
  }
}

- (void)testServicePreservesSnapshotMissingIntegrityAndStorageFailures {
  NSArray<NSDictionary *> *cases = @[
    @{@"store": @(DSHProjectContextStoreErrorNotFound),
      @"service": @(DSHProjectContextServiceErrorSnapshotMissing)},
    @{@"store": @(DSHProjectContextStoreErrorIntegrity),
      @"service": @(DSHProjectContextServiceErrorIntegrity)},
    @{@"store": @(DSHProjectContextStoreErrorUnavailable),
      @"service": @(DSHProjectContextServiceErrorStorage)},
  ];
  for (NSDictionary *row in cases) {
    DSHFailingProjectContextStore *store =
        [[DSHFailingProjectContextStore alloc] init];
    store.injectedCode = (DSHProjectContextStoreErrorCode)
        [row[@"store"] integerValue];
    DSHProjectContextService *service = [[DSHProjectContextService alloc]
        initWithProjectAccess:DSHLocalProjectAccess.sharedAccess
                      store:store
                     policy:[[DSHProjectContextPolicy alloc] init]
                      clock:^NSDate *{ return NSDate.date; }
        identifierGenerator:^NSString *{ return DSHSnapshotId; }
                       hook:nil];
    NSError *inspectError = nil;
    XCTAssertNil([service inspectSnapshotId:DSHSnapshotId error:&inspectError]);
    XCTAssertEqual(inspectError.code, [row[@"service"] integerValue]);
    NSError *discardError = nil;
    XCTAssertFalse([service discardSnapshotId:DSHSnapshotId
                                         error:&discardError]);
    XCTAssertEqual(discardError.code, [row[@"service"] integerValue]);
  }
}

- (void)testFIFOBackpressureAndInvalidateCancelQueuedAndActiveExactlyOnce {
  DSHFakeProjectContextService *service = [self fakeService];
  dispatch_semaphore_t activeGate = dispatch_semaphore_create(0);
  XCTestExpectation *activeStarted = [self expectationWithDescription:@"active"];
  service.beforeOperation = ^(NSString *name) {
    if ([name isEqual:@"list"]) {
      [activeStarted fulfill];
      dispatch_semaphore_wait(activeGate,
          dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
    }
  };
  id<DSHLocalProjectContextModuleTesting> module =
      [self moduleWithService:service maxPending:2];
  XCTestExpectation *firstCancelled = [self expectationWithDescription:@"first"];
  XCTestExpectation *secondCancelled = [self expectationWithDescription:@"second"];
  __block NSUInteger settlements = 0;
  [module listProjectContextCandidates:DSHProjectId query:@"" cursor:nil
      resolver:^(__unused id value) { XCTFail(@"must not resolve"); }
      rejecter:^(NSString *code, __unused NSString *message,
                 __unused NSError *error) {
        @synchronized (service) { settlements += 1; }
        XCTAssertEqualObjects(code, @"E_CONTEXT_CANCELLED");
        [firstCancelled fulfill];
      }];
  [self waitForExpectations:@[activeStarted] timeout:1];
  [module inspectProjectContext:DSHSnapshotId
      resolver:^(__unused id value) { XCTFail(@"must not resolve"); }
      rejecter:^(NSString *code, __unused NSString *message,
                 __unused NSError *error) {
        @synchronized (service) { settlements += 1; }
        XCTAssertEqualObjects(code, @"E_CONTEXT_CANCELLED");
        [secondCancelled fulfill];
      }];
  __block NSString *busyCode = nil;
  [module confirmProjectContext:DSHSnapshotId resolver:^(__unused id value) {
    XCTFail(@"must not resolve");
  } rejecter:^(NSString *code, __unused NSString *message,
               __unused NSError *error) { busyCode = code; }];
  XCTAssertEqualObjects(busyCode, @"E_CONTEXT_BUSY");
  [module invalidate];
  dispatch_semaphore_signal(activeGate);
  [self waitForExpectations:@[firstCancelled, secondCancelled] timeout:3];
  XCTAssertEqual(settlements, 2u);
  XCTAssertEqual(service.inspectCalls, 0u);
  __block NSString *afterInvalidation = nil;
  [module inspectProjectContext:DSHSnapshotId resolver:^(__unused id value) {
    XCTFail(@"must not resolve");
  } rejecter:^(NSString *code, __unused NSString *message,
               __unused NSError *error) { afterInvalidation = code; }];
  XCTAssertEqualObjects(afterInvalidation, @"E_CONTEXT_CANCELLED");
}

- (void)testSuccessfulOperationsExecuteFIFOOnTheInjectedSerialQueue {
  DSHFakeProjectContextService *service = [self fakeService];
  dispatch_semaphore_t gate = dispatch_semaphore_create(0);
  XCTestExpectation *firstStarted = [self expectationWithDescription:@"started"];
  service.beforeOperation = ^(NSString *name) {
    if ([name isEqual:@"list"]) {
      [firstStarted fulfill];
      dispatch_semaphore_wait(gate,
          dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    }
  };
  id<DSHLocalProjectContextModuleTesting> module =
      [self moduleWithService:service maxPending:16];
  XCTestExpectation *listed = [self expectationWithDescription:@"listed"];
  XCTestExpectation *inspected = [self expectationWithDescription:@"inspected"];
  [module listProjectContextCandidates:DSHProjectId query:@"" cursor:nil
      resolver:^(__unused id value) { [listed fulfill]; }
      rejecter:^(__unused NSString *code, __unused NSString *message,
                 __unused NSError *error) { XCTFail(@"list rejected"); }];
  [self waitForExpectations:@[firstStarted] timeout:1];
  [module inspectProjectContext:DSHSnapshotId
      resolver:^(__unused id value) { [inspected fulfill]; }
      rejecter:^(__unused NSString *code, __unused NSString *message,
                 __unused NSError *error) { XCTFail(@"inspect rejected"); }];
  dispatch_semaphore_signal(gate);
  [self waitForExpectations:@[listed, inspected] timeout:3];
  XCTAssertEqualObjects(service.events, (@[@"list", @"inspect"]));
}

- (void)testBusyRejectionRunsOutsideModuleLocksAndAllowsReentrantInvalidate {
  DSHFakeProjectContextService *service = [self fakeService];
  dispatch_semaphore_t operationGate = dispatch_semaphore_create(0);
  XCTestExpectation *started = [self expectationWithDescription:@"started"];
  service.beforeOperation = ^(NSString *name) {
    if ([name isEqual:@"list"]) {
      [started fulfill];
      dispatch_semaphore_wait(operationGate,
          dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
    }
  };
  id<DSHLocalProjectContextModuleTesting> module =
      [self moduleWithService:service maxPending:1];
  XCTestExpectation *cancelled = [self expectationWithDescription:@"cancelled"];
  [module listProjectContextCandidates:DSHProjectId query:@"" cursor:nil
      resolver:^(__unused id value) { XCTFail(@"must cancel"); }
      rejecter:^(NSString *code, __unused NSString *message,
                 __unused NSError *error) {
        XCTAssertEqualObjects(code, @"E_CONTEXT_CANCELLED");
        [cancelled fulfill];
      }];
  [self waitForExpectations:@[started] timeout:1];
  __block NSString *busyCode = nil;
  [module inspectProjectContext:DSHSnapshotId
      resolver:^(__unused id value) { XCTFail(@"must not resolve"); }
      rejecter:^(NSString *code, __unused NSString *message,
                 __unused NSError *error) {
        busyCode = code;
        dispatch_semaphore_t reentrant = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
          [module invalidate];
          dispatch_semaphore_signal(reentrant);
        });
        long result = dispatch_semaphore_wait(
            reentrant, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
        XCTAssertEqual(result, 0l);
      }];
  XCTAssertEqualObjects(busyCode, @"E_CONTEXT_BUSY");
  dispatch_semaphore_signal(operationGate);
  [self waitForExpectations:@[cancelled] timeout:3];
}

- (void)testProductionModulesShareOneGlobalPendingCapAndReleaseAfterInvalidate {
  Class cls = NSClassFromString(@"LocalProjectContextModule");
  id<DSHLocalProjectContextModuleTesting> first = [[cls alloc] init];
  id<DSHLocalProjectContextModuleTesting> second = [[cls alloc] init];
  DSHFakeProjectContextService *service = [self fakeService];
  [(id)first setValue:service forKey:@"service"];
  [(id)second setValue:service forKey:@"service"];
  dispatch_semaphore_t gate = dispatch_semaphore_create(0);
  XCTestExpectation *started = [self expectationWithDescription:@"started"];
  __block BOOL didBlock = NO;
  NSObject *blockLock = [[NSObject alloc] init];
  service.beforeOperation = ^(NSString *name) {
    @synchronized (blockLock) {
      if (didBlock) return;
      didBlock = YES;
    }
    [started fulfill];
    dispatch_semaphore_wait(gate,
        dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
  };
  NSMutableArray<XCTestExpectation *> *settled = [NSMutableArray array];
  for (NSUInteger index = 0; index < 16; index += 1) {
    XCTestExpectation *expectation = [self expectationWithDescription:
        [NSString stringWithFormat:@"settled-%lu", (unsigned long)index]];
    [settled addObject:expectation];
    id<DSHLocalProjectContextModuleTesting> owner =
        index % 2 == 0 ? first : second;
    [owner listProjectContextCandidates:DSHProjectId query:@"" cursor:nil
        resolver:^(__unused id value) {
          if (owner == first) XCTFail(@"invalidated owner must cancel");
          [expectation fulfill];
        } rejecter:^(NSString *code, __unused NSString *message,
                     __unused NSError *error) {
          if (owner == first) {
            XCTAssertEqualObjects(code, @"E_CONTEXT_CANCELLED");
          } else {
            XCTFail(@"live owner rejected: %@", code);
          }
          [expectation fulfill];
        }];
  }
  [self waitForExpectations:@[started] timeout:1];
  __block NSString *busyCode = nil;
  [second inspectProjectContext:DSHSnapshotId
      resolver:^(__unused id value) { XCTFail(@"cap+1 must not resolve"); }
      rejecter:^(NSString *code, __unused NSString *message,
                 __unused NSError *error) { busyCode = code; }];
  XCTAssertEqualObjects(busyCode, @"E_CONTEXT_BUSY");
  [first invalidate];
  dispatch_semaphore_signal(gate);
  [self waitForExpectations:settled timeout:5];
  XCTestExpectation *released = [self expectationWithDescription:@"released"];
  [second inspectProjectContext:DSHSnapshotId
      resolver:^(__unused id value) { [released fulfill]; }
      rejecter:^(__unused NSString *code, __unused NSString *message,
                 __unused NSError *error) { XCTFail(@"slot was not released"); }];
  [self waitForExpectations:@[released] timeout:2];
  [second invalidate];
}

- (void)testProductionModulesShareOneProcessService {
  Class cls = NSClassFromString(@"LocalProjectContextModule");
  id first = [[cls alloc] init];
  id second = [[cls alloc] init];
  XCTAssertEqual([first valueForKey:@"service"],
                 [second valueForKey:@"service"]);
  XCTAssertEqual([first valueForKey:@"service"],
                 DSHSharedProjectContextService());
  XCTAssertEqual([first valueForKey:@"operationQueue"],
                 [second valueForKey:@"operationQueue"]);
  XCTAssertEqualObjects([first valueForKey:@"maxPending"], @16);
}

- (void)testRealTemporaryLifecycleIsMetadataOnlyAndCursorIsQueryBound {
  NSURL *temporary = [NSURL fileURLWithPath:[NSTemporaryDirectory()
      stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
                                      isDirectory:YES];
  NSURL *projects = [temporary URLByAppendingPathComponent:@"projects"
                                                isDirectory:YES];
  NSURL *storeURL = [temporary URLByAppendingPathComponent:@"store"
                                                isDirectory:YES];
  NSString *projectId = @"55555555-5555-4555-8555-555555555555";
  NSURL *project = [projects URLByAppendingPathComponent:projectId
                                             isDirectory:YES];
  NSURL *repositoryURL = [project URLByAppendingPathComponent:@"repo"
                                                   isDirectory:YES];
  git_repository *repository = nullptr;
  BOOL gitInitialized = NO;
  @try {
    XCTAssertTrue([[NSFileManager defaultManager]
        createDirectoryAtURL:repositoryURL
        withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions: @0700}
        error:nil]);
    NSDictionary *metadata = @{
      @"schema_version": @1,
      @"name": @"Bridge Fixture",
      @"created_at": @"2026-08-28T00:00:00.000Z",
      @"updated_at": @"2026-08-28T00:00:00.000Z",
      @"origin_url": NSNull.null,
    };
    NSData *metadataData = [NSJSONSerialization dataWithJSONObject:metadata
        options:NSJSONWritingSortedKeys error:nil];
    XCTAssertTrue([metadataData writeToURL:
        [project URLByAppendingPathComponent:@"project.json"] atomically:YES]);
    XCTAssertGreaterThanOrEqual(git_libgit2_init(), 1);
    gitInitialized = YES;
    XCTAssertEqual(git_repository_init(
        &repository, repositoryURL.fileSystemRepresentation, 0), 0);
    XCTAssertNotEqual(repository, nullptr);
    if (repository == nullptr) return;

    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    [paths addObject:@"README.md"];
    [paths addObject:@".env"];
    for (NSUInteger index = 0; index < 101; index += 1) {
      [paths addObject:[NSString stringWithFormat:@"f%03lu.txt",
                                                  (unsigned long)index]];
    }
    for (NSString *path in paths) {
      NSString *content = [path isEqual:@".env"]
          ? @"API_KEY=REAL_TEMP_SECRET_SENTINEL\n"
          : [NSString stringWithFormat:@"safe %@\n", path];
      NSData *data = [content dataUsingEncoding:NSUTF8StringEncoding];
      XCTAssertTrue([data writeToURL:
          [repositoryURL URLByAppendingPathComponent:path] atomically:YES]);
    }
    git_index *index = nullptr;
    XCTAssertEqual(git_repository_index(&index, repository), 0);
    XCTAssertNotEqual(index, nullptr);
    for (NSString *path in paths) {
      XCTAssertEqual(git_index_add_bypath(index, path.UTF8String), 0);
    }
    XCTAssertEqual(git_index_write(index), 0);
    git_index_free(index);

    NSDate *now = [NSDate dateWithTimeIntervalSince1970:1'777'777'777.125];
    __block NSUInteger nextId = 0;
    DSHProjectContextIdentifierGenerator identifiers = ^NSString *{
      @synchronized (temporary) {
        nextId += 1;
        return [NSString stringWithFormat:
            @"aaaaaaaa-aaaa-4aaa-8aaa-%012lu", (unsigned long)nextId];
      }
    };
    DSHProjectContextClock clock = ^NSDate *{ return now; };
    DSHProjectContextStore *store = [[DSHProjectContextStore alloc]
        initWithRootURL:storeURL capacityBytes:64 * 1024 * 1024
                  clock:clock identifierGenerator:identifiers];
    DSHProjectContextService *service = [[DSHProjectContextService alloc]
        initWithProjectAccess:[[DSHLocalProjectAccess alloc]
                                  initWithProjectsRootURL:projects]
                      store:store
                     policy:[[DSHProjectContextPolicy alloc] init]
                      clock:clock
        identifierGenerator:identifiers
                       hook:nil];
    id<DSHLocalProjectContextModuleTesting> module =
        [self moduleWithService:service maxPending:16];

    XCTestExpectation *listed = [self expectationWithDescription:@"listed"];
    __block NSString *cursor = nil;
    [module listProjectContextCandidates:projectId query:@"" cursor:nil
        resolver:^(NSDictionary *value) {
          XCTAssertEqual([value[@"candidates"] count], 100u);
          cursor = value[@"next_cursor"];
          XCTAssertEqual(cursor.length, 98u);
          NSString *json = [[NSString alloc] initWithData:
              [NSJSONSerialization dataWithJSONObject:value options:0 error:nil]
              encoding:NSUTF8StringEncoding];
          XCTAssertFalse([json containsString:@"REAL_TEMP_SECRET_SENTINEL"]);
          XCTAssertFalse([json containsString:temporary.path]);
          [listed fulfill];
        } rejecter:^(__unused NSString *code, __unused NSString *message,
                     __unused NSError *error) { XCTFail(@"list rejected"); }];
    [self waitForExpectations:@[listed] timeout:5];

    XCTestExpectation *secondPage =
        [self expectationWithDescription:@"second page"];
    [module listProjectContextCandidates:projectId query:@"" cursor:cursor
        resolver:^(NSDictionary *value) {
          XCTAssertEqual([value[@"candidates"] count], 3u);
          XCTAssertEqualObjects(value[@"next_cursor"], NSNull.null);
          [secondPage fulfill];
        } rejecter:^(__unused NSString *code, __unused NSString *message,
                     __unused NSError *error) {
          XCTFail(@"same-query cursor rejected");
          [secondPage fulfill];
        }];
    [self waitForExpectations:@[secondPage] timeout:5];

    XCTestExpectation *cursorRejected =
        [self expectationWithDescription:@"cursor rejected"];
    [module listProjectContextCandidates:projectId query:@"README" cursor:cursor
        resolver:^(__unused id value) { XCTFail(@"stale cursor resolved"); }
        rejecter:^(NSString *code, __unused NSString *message,
                   __unused NSError *error) {
          XCTAssertEqualObjects(code, @"E_CONTEXT_REQUEST_INVALID");
          [cursorRejected fulfill];
    }];
    [self waitForExpectations:@[cursorRejected] timeout:5];

    NSString *changedPath = @"cursor-change.txt";
    NSData *changedData = [@"changed\n" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertTrue([changedData writeToURL:
        [repositoryURL URLByAppendingPathComponent:changedPath] atomically:YES]);
    git_index *changedIndex = nullptr;
    XCTAssertEqual(git_repository_index(&changedIndex, repository), 0);
    XCTAssertEqual(git_index_add_bypath(changedIndex, changedPath.UTF8String), 0);
    XCTAssertEqual(git_index_write(changedIndex), 0);
    git_index_free(changedIndex);
    [paths addObject:changedPath];
    XCTestExpectation *staleCursor =
        [self expectationWithDescription:@"stale cursor"];
    [module listProjectContextCandidates:projectId query:@"" cursor:cursor
        resolver:^(__unused id value) { XCTFail(@"stale cursor resolved"); }
        rejecter:^(NSString *code, __unused NSString *message,
                   __unused NSError *error) {
          XCTAssertEqualObjects(code, @"E_CONTEXT_CHANGED");
          [staleCursor fulfill];
        }];
    [self waitForExpectations:@[staleCursor] timeout:5];

    git_index *commitIndex = nullptr;
    git_tree *tree = nullptr;
    git_signature *signature = nullptr;
    git_oid treeOid = {};
    git_oid commitOid = {};
    XCTAssertEqual(git_repository_index(&commitIndex, repository), 0);
    XCTAssertEqual(git_index_write_tree(&treeOid, commitIndex), 0);
    XCTAssertEqual(git_tree_lookup(&tree, repository, &treeOid), 0);
    XCTAssertEqual(git_signature_new(&signature, "Rish Bridge Test",
                                     "bridge@example.invalid",
                                     1'777'777'777, 0), 0);
    XCTAssertEqual(git_commit_create(&commitOid, repository, "HEAD", signature,
                                     signature, "UTF-8", "fixture", tree,
                                     0, nullptr), 0);
    if (signature != nullptr) git_signature_free(signature);
    if (tree != nullptr) git_tree_free(tree);
    if (commitIndex != nullptr) git_index_free(commitIndex);

    NSDictionary *selection = @{
      @"schema_version": @1,
      @"project_id": projectId,
      @"conversation_id": DSHConversationId,
      @"provider": @"deepseek",
      @"model": @"deepseek-v4-flash",
      @"policy": @"chat-read-v1",
      @"selected_paths": @[@"README.md", @".env"],
    };
    XCTestExpectation *prepared = [self expectationWithDescription:@"prepared"];
    __block NSDictionary *manifest = nil;
    [module prepareProjectContext:selection resolver:^(NSDictionary *value) {
      manifest = value;
      XCTAssertEqual([value[@"included"] count], 1u);
      XCTAssertEqualObjects(value[@"included"][0][@"path"], @"README.md");
      XCTAssertEqualObjects(value[@"omitted"][0][@"path"], @".env");
      NSString *json = [[NSString alloc] initWithData:
          [NSJSONSerialization dataWithJSONObject:value options:0 error:nil]
          encoding:NSUTF8StringEncoding];
      XCTAssertFalse([json containsString:@"REAL_TEMP_SECRET_SENTINEL"]);
      XCTAssertFalse([json containsString:temporary.path]);
      [prepared fulfill];
    } rejecter:^(NSString *code, __unused NSString *message,
                 __unused NSError *error) {
      XCTFail(@"prepare rejected: %@", code);
      [prepared fulfill];
    }];
    [self waitForExpectations:@[prepared] timeout:5];
    if (manifest == nil) return;

    XCTestExpectation *confirmed = [self expectationWithDescription:@"confirmed"];
    [module confirmProjectContext:manifest[@"snapshot_id"]
        resolver:^(NSDictionary *value) {
          XCTAssertEqualObjects(value[@"snapshot_id"], manifest[@"snapshot_id"]);
          [confirmed fulfill];
        } rejecter:^(NSString *code, __unused NSString *message,
                     __unused NSError *error) {
          XCTFail(@"confirm rejected: %@", code);
          [confirmed fulfill];
        }];
    [self waitForExpectations:@[confirmed] timeout:5];

    XCTestExpectation *inspected = [self expectationWithDescription:@"inspected"];
    [module inspectProjectContext:manifest[@"snapshot_id"]
        resolver:^(NSDictionary *value) {
          XCTAssertEqualObjects(value[@"state"], @"confirmed");
          [inspected fulfill];
        } rejecter:^(NSString *code, __unused NSString *message,
                     __unused NSError *error) {
          XCTFail(@"inspect rejected: %@", code);
          [inspected fulfill];
        }];
    [self waitForExpectations:@[inspected] timeout:5];

    XCTestExpectation *discarded = [self expectationWithDescription:@"discarded"];
    [module discardProjectContext:manifest[@"snapshot_id"]
        resolver:^(__unused NSDictionary *value) { [discarded fulfill]; }
        rejecter:^(NSString *code, __unused NSString *message,
                   __unused NSError *error) {
          XCTFail(@"discard rejected: %@", code);
          [discarded fulfill];
        }];
    [self waitForExpectations:@[discarded] timeout:5];

    XCTestExpectation *missing = [self expectationWithDescription:@"missing"];
    [module inspectProjectContext:manifest[@"snapshot_id"]
        resolver:^(__unused id value) { XCTFail(@"missing snapshot resolved"); }
        rejecter:^(NSString *code, __unused NSString *message,
                   __unused NSError *error) {
          XCTAssertEqualObjects(code, @"E_CONTEXT_SNAPSHOT_MISSING");
          [missing fulfill];
        }];
    [self waitForExpectations:@[missing] timeout:5];
  } @finally {
    if (repository != nullptr) git_repository_free(repository);
    if (gitInitialized) git_libgit2_shutdown();
    [[NSFileManager defaultManager] removeItemAtURL:temporary error:nil];
  }
}

@end
