#import <XCTest/XCTest.h>

#import "../../../../modules/rish/ios/Sources/SessionSnapshotStore.h"

typedef void (^DSHSessionResolve)(id value);
typedef void (^DSHSessionReject)(NSString *code, NSString *message,
                                 NSError *error);

@interface NSObject (DSHSessionSnapshotsModuleClassName)
+ (NSString *)moduleName;
@end

@protocol DSHSessionSnapshotsModuleTesting <NSObject>
- (instancetype)initWithStore:(DSHSessionSnapshotStore *)store;
- (nullable id)sessionCandidateDigest:(id)candidate;
- (void)loadSessionSnapshotWithResolver:(DSHSessionResolve)resolve
                               rejecter:(DSHSessionReject)reject;
- (void)casPersistSessionRequest:(id)request
                         resolver:(DSHSessionResolve)resolve
                         rejecter:(DSHSessionReject)reject;
- (void)querySessionCommitRequest:(id)request
                           resolver:(DSHSessionResolve)resolve
                           rejecter:(DSHSessionReject)reject;
- (void)persistSessionWithWorkspaceClearanceRequest:(id)request
                                           resolver:(DSHSessionResolve)resolve
                                           rejecter:(DSHSessionReject)reject;
- (void)queryWorkspaceClearanceRequest:(id)request
                               resolver:(DSHSessionResolve)resolve
                               rejecter:(DSHSessionReject)reject;
@property(nonatomic, readonly) DSHSessionSnapshotStore *store;
@property(nonatomic, readonly) DSHSessionWorkspaceCoordinator *coordinator;
@property(nonatomic, readonly) dispatch_queue_t operationQueue;
@end

@interface DSHRecordingSessionSnapshotStore : DSHSessionSnapshotStore
@property(nonatomic, strong) id receivedCASRequest;
@property(nonatomic, strong) id receivedQueryRequest;
@property(nonatomic, strong) id receivedClearanceRequest;
@property(nonatomic, strong) id receivedClearanceQueryRequest;
@property(nonatomic, strong) NSDictionary *loadResult;
@property(nonatomic, strong) NSDictionary *casResult;
@property(nonatomic, strong) NSDictionary *queryResult;
@property(nonatomic, strong) NSDictionary *clearanceResult;
@property(nonatomic, strong) NSDictionary *clearanceQueryResult;
@property(nonatomic, strong) NSError *injectedError;
@property(nonatomic) BOOL throwOnLoad;
@property(nonatomic) BOOL throwOnCAS;
@property(nonatomic) BOOL throwOnQuery;
@property(nonatomic) BOOL reenterCoordinatorOnLoad;
@property(nonatomic, strong) NSMutableArray<NSString *> *events;
@end

@implementation DSHRecordingSessionSnapshotStore

- (NSDictionary *)loadSessionSnapshotWithError:(NSError **)error {
  if (self.events != nil) [self.events addObject:@"load"];
  if (self.reenterCoordinatorOnLoad) {
    [self.coordinator performSync:^{
      [self.events addObject:@"reentrant"];
    }];
  }
  if (self.throwOnLoad) {
    @throw [NSException exceptionWithName:@"session-store-test"
                                   reason:@"private path must not escape"
                                 userInfo:nil];
  }
  if (self.injectedError != nil) {
    if (error != nil) *error = self.injectedError;
    return nil;
  }
  return self.loadResult;
}

- (NSDictionary *)casPersistSession:(NSDictionary *)request
                               error:(NSError **)error {
  self.receivedCASRequest = request;
  if (self.events != nil) [self.events addObject:@"cas"];
  if (self.throwOnCAS) {
    @throw [NSException exceptionWithName:@"session-store-test"
                                   reason:@"private path must not escape"
                                 userInfo:nil];
  }
  if (self.injectedError != nil) {
    if (error != nil) *error = self.injectedError;
    return nil;
  }
  return self.casResult;
}

- (NSDictionary *)querySessionCommit:(NSDictionary *)request
                                error:(NSError **)error {
  self.receivedQueryRequest = request;
  if (self.events != nil) [self.events addObject:@"query"];
  if (self.throwOnQuery) {
    @throw [NSException exceptionWithName:@"session-store-test"
                                   reason:@"private path must not escape"
                                 userInfo:nil];
  }
  if (self.injectedError != nil) {
    if (error != nil) *error = self.injectedError;
    return nil;
  }
  return self.queryResult;
}

- (NSDictionary *)persistSessionWithWorkspaceClearance:(NSDictionary *)request
                                                   error:(NSError **)error {
  (void)error;
  self.receivedClearanceRequest = request;
  return self.clearanceResult;
}

- (NSDictionary *)queryWorkspaceClearance:(NSDictionary *)request
                                      error:(NSError **)error {
  (void)error;
  self.receivedClearanceQueryRequest = request;
  return self.clearanceQueryResult;
}

@end

@interface DSHThrowingSessionDictionary : NSDictionary
@end

@implementation DSHThrowingSessionDictionary

- (NSUInteger)count {
  @throw [NSException exceptionWithName:@"hostile-result"
                                 reason:@"private path must not escape"
                               userInfo:nil];
}

- (NSArray *)allKeys {
  @throw [NSException exceptionWithName:@"hostile-result"
                                 reason:@"private path must not escape"
                               userInfo:nil];
}

@end

@interface DSHSingleReadSessionDictionary : NSDictionary
@property(nonatomic, strong) NSDictionary *backing;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *readCounts;
- (instancetype)initWithDictionary:(NSDictionary *)dictionary;
@end

@implementation DSHSingleReadSessionDictionary

- (instancetype)initWithDictionary:(NSDictionary *)dictionary {
  self = [super init];
  if (self != nil) {
    _backing = dictionary;
    _readCounts = [NSMutableDictionary dictionary];
  }
  return self;
}

- (NSUInteger)count {
  return self.backing.count;
}

- (NSArray *)allKeys {
  return self.backing.allKeys;
}

- (id)objectForKey:(id)key {
  NSString *name = [key isKindOfClass:NSString.class] ? key : @"<invalid>";
  NSUInteger count = self.readCounts[name].unsignedIntegerValue + 1;
  self.readCounts[name] = @(count);
  if (count > 1) {
    @throw [NSException exceptionWithName:@"session-result-reread"
                                   reason:@"result value was reread"
                                 userInfo:nil];
  }
  return self.backing[key];
}

@end

@interface SessionSnapshotsModuleTests : XCTestCase
@property(nonatomic, strong) NSURL *rootURL;
@property(nonatomic, strong) DSHSessionSnapshotStore *store;
@end

@implementation SessionSnapshotsModuleTests

static NSString *const DSHSessionModuleOperation =
    @"11111111-1111-4111-8111-111111111111";

- (void)setUp {
  [super setUp];
  NSString *name = [NSString stringWithFormat:
      @"rish-session-bridge-%@", NSUUID.UUID.UUIDString.lowercaseString];
  self.rootURL = [NSURL fileURLWithPath:
      [NSTemporaryDirectory() stringByAppendingPathComponent:name]
                              isDirectory:YES];
  self.store = [[DSHSessionSnapshotStore alloc]
      initWithRootURL:self.rootURL
           sessionURL:[self.rootURL URLByAppendingPathComponent:@"sessions.json"]
     launchInstanceId:@"22222222-2222-4222-8222-222222222222"
           coordinator:[DSHSessionWorkspaceCoordinator sharedCoordinator]
             faultHook:nil];
  XCTAssertNotNil(self.store);
}

- (void)tearDown {
  [NSFileManager.defaultManager removeItemAtURL:self.rootURL error:nil];
  [super tearDown];
}

- (id<DSHSessionSnapshotsModuleTesting>)moduleWithStore:
    (DSHSessionSnapshotStore *)store {
  Class cls = NSClassFromString(@"SessionSnapshotsModule");
  XCTAssertNotNil(cls);
  return [[(id)cls alloc] initWithStore:store];
}

- (NSDictionary *)sessionPreferences {
  return @{
    @"schema_version" : @1,
    @"theme_mode" : @"system",
    @"locale" : @"en-US",
    @"default_model" : @"deepseek-v4-flash",
    @"selected_harness_id" : @"dsh",
    @"thinking_mode" : @"off",
    @"tool_permission" : @"read-only",
    @"show_reasoning" : @NO,
    @"auto_expand_tools" : @NO,
    @"confirm_destructive_file_actions" : @YES,
    @"git_https_proxy_url" : NSNull.null,
  };
}

- (NSDictionary *)schema8MigratedCandidate {
  return @{
    @"schema_version" : @9,
    @"workspace_authority_outbox" : @[],
    @"agent_transcript_cleanup_outbox" : @[],
    @"project_context_destructive_epoch" : @0,
    @"project_context_destructive_transition" : NSNull.null,
    @"active_conversation_id" : NSNull.null,
    @"conversations" : @[],
    @"messages" : @[],
    @"session_events" : @[],
    @"preferences" : [self sessionPreferences],
  };
}

- (void)assertLoadResult:(NSDictionary *)result
          rejectsWithCode:(NSString *)expectedCode {
  DSHRecordingSessionSnapshotStore *store = [[DSHRecordingSessionSnapshotStore alloc]
      initWithRootURL:self.rootURL
           sessionURL:[self.rootURL URLByAppendingPathComponent:@"sessions.json"]
     launchInstanceId:@"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
           coordinator:[DSHSessionWorkspaceCoordinator sharedCoordinator]
             faultHook:nil];
  store.loadResult = result;
  id<DSHSessionSnapshotsModuleTesting> module = [self moduleWithStore:store];
  XCTestExpectation *rejected =
      [self expectationWithDescription:expectedCode];
  [module loadSessionSnapshotWithResolver:^(__unused id value) {
    XCTFail(@"malformed store result must not resolve");
    [rejected fulfill];
  } rejecter:^(NSString *code, NSString *message, NSError *error) {
    XCTAssertEqualObjects(code, expectedCode);
    XCTAssertEqualObjects(message, expectedCode);
    XCTAssertNil(error);
    [rejected fulfill];
  }];
  [self waitForExpectations:@[ rejected ] timeout:2];
}

- (void)testNativeModuleIsLinkedWithOnlyTheVersionedSurface {
  Class cls = NSClassFromString(@"SessionSnapshotsModule");
  XCTAssertNotNil(cls);
  NSString *moduleName = [cls moduleName];
  XCTAssertEqualObjects(moduleName, @"SessionSnapshots");
  XCTAssertTrue([cls instancesRespondToSelector:
      NSSelectorFromString(@"loadSessionSnapshotWithResolver:rejecter:")]);
  XCTAssertTrue([cls instancesRespondToSelector:
      NSSelectorFromString(@"casPersistSessionRequest:resolver:rejecter:")]);
  XCTAssertTrue([cls instancesRespondToSelector:
      NSSelectorFromString(@"querySessionCommitRequest:resolver:rejecter:")]);
  XCTAssertTrue([cls instancesRespondToSelector:NSSelectorFromString(
      @"persistSessionWithWorkspaceClearanceRequest:resolver:rejecter:")]);
  XCTAssertTrue([cls instancesRespondToSelector:NSSelectorFromString(
      @"queryWorkspaceClearanceRequest:resolver:rejecter:")]);
  // Synchronous digest fast path: exported with the blocking-sync macro, so
  // the selector carries only the candidate argument (self, _cmd, candidate).
  SEL digestSelector = NSSelectorFromString(@"sessionCandidateDigest:");
  XCTAssertTrue([cls instancesRespondToSelector:digestSelector]);
  XCTAssertEqual([[cls instanceMethodSignatureForSelector:digestSelector]
                      numberOfArguments], 3u);

  SEL loadSelector = NSSelectorFromString(
      @"loadSessionSnapshotWithResolver:rejecter:");
  SEL casSelector = NSSelectorFromString(
      @"casPersistSessionRequest:resolver:rejecter:");
  SEL querySelector = NSSelectorFromString(
      @"querySessionCommitRequest:resolver:rejecter:");
  XCTAssertEqual([[cls instanceMethodSignatureForSelector:loadSelector]
                      numberOfArguments], 4u);
  XCTAssertEqual([[cls instanceMethodSignatureForSelector:casSelector]
                      numberOfArguments], 5u);
  XCTAssertEqual([[cls instanceMethodSignatureForSelector:querySelector]
                      numberOfArguments], 5u);
  XCTAssertFalse([cls instancesRespondToSelector:
      NSSelectorFromString(@"persistSessionJSON:resolver:rejecter:")]);
  XCTAssertFalse([cls instancesRespondToSelector:
      NSSelectorFromString(@"loadSessionWithResolver:rejecter:")]);
  XCTAssertFalse([cls instancesRespondToSelector:
      NSSelectorFromString(@"casPersistSessionWithRequest:resolver:rejecter:")]);
}

- (void)testProductionInitializerUsesApplicationSupportSessionsURLAndSharedCoordinator {
  Class cls = NSClassFromString(@"SessionSnapshotsModule");
  id<DSHSessionSnapshotsModuleTesting> module = [[(id)cls alloc] init];
  NSError *error = nil;
  NSURL *support = [NSFileManager.defaultManager
      URLForDirectory:NSApplicationSupportDirectory
      inDomain:NSUserDomainMask
      appropriateForURL:nil
      create:NO
      error:&error];
  XCTAssertNil(error);
  XCTAssertNotNil(support);
  XCTAssertEqualObjects(module.store.rootURL,
                        [support URLByStandardizingPath]);
  XCTAssertEqualObjects(module.store.sessionURL.lastPathComponent, @"sessions.json");
  XCTAssertEqualObjects(module.store.sessionURL,
                        [support URLByAppendingPathComponent:@"sessions.json"]);
  XCTAssertEqual(module.coordinator,
                 [DSHSessionWorkspaceCoordinator sharedCoordinator]);
  XCTAssertEqual(module.store.coordinator,
                 [DSHSessionWorkspaceCoordinator sharedCoordinator]);
  XCTAssertEqual(module.operationQueue,
                 [DSHSessionWorkspaceCoordinator sharedQueue]);
  XCTAssertTrue(module.store.sessionURL.isFileURL);
}

- (void)testLoadAndQueryUseTheStoreAndPreserveVersionedResults {
  DSHRecordingSessionSnapshotStore *store = [[DSHRecordingSessionSnapshotStore alloc]
      initWithRootURL:self.rootURL
           sessionURL:[self.rootURL URLByAppendingPathComponent:@"sessions.json"]
     launchInstanceId:@"33333333-3333-4333-8333-333333333333"
           coordinator:[DSHSessionWorkspaceCoordinator sharedCoordinator]
             faultHook:nil];
  store.loadResult = @{
    @"schema_version" : @1,
    @"status" : @"legacy_present",
    @"legacy" : @{
      @"schema_version" : @1,
      @"legacy_bytes_sha256" :
          @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    },
    @"session_json" : @"{\"schema_version\":8}",
    @"writer_launch_instance_id" : @"33333333-3333-4333-8333-333333333333",
    @"current_launch_instance_id" : @"33333333-3333-4333-8333-333333333333",
  };
  store.queryResult = @{
    @"schema_version" : @1,
    @"status" : @"not_started",
  };
  id<DSHSessionSnapshotsModuleTesting> module = [self moduleWithStore:store];

  XCTestExpectation *loaded = [self expectationWithDescription:@"load"];
  [module loadSessionSnapshotWithResolver:^(NSDictionary *result) {
    XCTAssertEqualObjects(result, store.loadResult);
    [loaded fulfill];
  } rejecter:^(__unused NSString *code, __unused NSString *message,
              __unused NSError *error) {
    XCTFail(@"unexpected load rejection");
    [loaded fulfill];
  }];

  NSDictionary *queryRequest = @{
    @"schema_version" : @1,
    @"operation_id" : DSHSessionModuleOperation,
  };
  XCTestExpectation *queried = [self expectationWithDescription:@"query"];
  [module querySessionCommitRequest:queryRequest
      resolver:^(NSDictionary *result) {
        XCTAssertEqualObjects(result, store.queryResult);
        XCTAssertEqualObjects(store.receivedQueryRequest, queryRequest);
        XCTAssertNotEqual(store.receivedQueryRequest, queryRequest);
        [queried fulfill];
      }
      rejecter:^(__unused NSString *code, __unused NSString *message,
                 __unused NSError *error) {
        XCTFail(@"unexpected query rejection");
        [queried fulfill];
      }];
  [self waitForExpectations:@[ loaded, queried ] timeout:2];
}

- (void)testResolvedStoreResultIsFreshImmutableAndNeverRereadsSourceContainers {
  NSMutableDictionary *legacy = [@{
    @"schema_version" : @1,
    @"legacy_bytes_sha256" :
        @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  } mutableCopy];
  NSMutableDictionary *source = [@{
    @"schema_version" : @1,
    @"status" : @"legacy_present",
    @"legacy" : [[DSHSingleReadSessionDictionary alloc]
        initWithDictionary:legacy],
    @"session_json" : @"{\"schema_version\":8}",
    @"writer_launch_instance_id" : @"77777777-7777-4777-8777-777777777777",
    @"current_launch_instance_id" : @"77777777-7777-4777-8777-777777777777",
  } mutableCopy];
  DSHSingleReadSessionDictionary *result = [[DSHSingleReadSessionDictionary alloc]
      initWithDictionary:source];
  DSHRecordingSessionSnapshotStore *store = [[DSHRecordingSessionSnapshotStore alloc]
      initWithRootURL:self.rootURL
           sessionURL:[self.rootURL URLByAppendingPathComponent:@"sessions.json"]
     launchInstanceId:@"77777777-7777-4777-8777-777777777777"
           coordinator:[DSHSessionWorkspaceCoordinator sharedCoordinator]
             faultHook:nil];
  store.loadResult = result;
  id<DSHSessionSnapshotsModuleTesting> module = [self moduleWithStore:store];

  XCTestExpectation *resolved = [self expectationWithDescription:@"sanitized"];
  [module loadSessionSnapshotWithResolver:^(NSDictionary *value) {
    XCTAssertEqualObjects(value[@"status"], @"legacy_present");
    XCTAssertNotEqual(value, result);
    XCTAssertNotEqual(value[@"legacy"], result.backing[@"legacy"]);
    XCTAssertFalse([value isKindOfClass:NSMutableDictionary.class]);
    XCTAssertFalse([value[@"legacy"] isKindOfClass:NSMutableDictionary.class]);
    XCTAssertEqualObjects(value[@"legacy"][@"legacy_bytes_sha256"],
                          legacy[@"legacy_bytes_sha256"]);
    legacy[@"legacy_bytes_sha256"] =
        @"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    source[@"session_json"] = @"mutated-after-capture";
    XCTAssertEqualObjects(value[@"legacy"][@"legacy_bytes_sha256"],
                          @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    XCTAssertEqualObjects(value[@"session_json"], @"{\"schema_version\":8}");
    [resolved fulfill];
  } rejecter:^(__unused NSString *code, __unused NSString *message,
              __unused NSError *error) {
    XCTFail(@"unexpected result rejection");
    [resolved fulfill];
  }];
  [self waitForExpectations:@[ resolved ] timeout:2];
  XCTAssertEqual(result.readCounts[@"schema_version"].unsignedIntegerValue, 1u);
  XCTAssertEqual(result.readCounts[@"status"].unsignedIntegerValue, 1u);
  XCTAssertEqual(result.readCounts[@"legacy"].unsignedIntegerValue, 1u);
  XCTAssertEqual(result.readCounts[@"session_json"].unsignedIntegerValue, 1u);
}

- (void)testBridgeStoreIntegrationKeepsMissingAndQueryStatesDistinct {
  id<DSHSessionSnapshotsModuleTesting> module = [self moduleWithStore:self.store];

  XCTestExpectation *loaded = [self expectationWithDescription:@"missing"];
  [module loadSessionSnapshotWithResolver:^(NSDictionary *result) {
    XCTAssertEqualObjects(result, (@{
      @"schema_version" : @1,
      @"status" : @"missing",
      @"snapshot" : NSNull.null,
      @"session_json" : NSNull.null,
      @"writer_launch_instance_id" : NSNull.null,
      @"current_launch_instance_id" : self.store.launchInstanceId,
    }));
    [loaded fulfill];
  } rejecter:^(__unused NSString *code, __unused NSString *message,
              __unused NSError *error) {
    XCTFail(@"unexpected load rejection");
    [loaded fulfill];
  }];

  XCTestExpectation *queried = [self expectationWithDescription:@"not started"];
  [module querySessionCommitRequest:@{
      @"schema_version" : @1,
      @"operation_id" : DSHSessionModuleOperation,
  }
      resolver:^(NSDictionary *result) {
        XCTAssertEqualObjects(result, (@{
          @"schema_version" : @1,
          @"status" : @"not_started",
        }));
        [queried fulfill];
      }
      rejecter:^(__unused NSString *code, __unused NSString *message,
                 __unused NSError *error) {
        XCTFail(@"unexpected query rejection");
        [queried fulfill];
      }];
  [self waitForExpectations:@[ loaded, queried ] timeout:2];
}

- (void)testBridgeRunsOnTheSharedQueueInFIFOOrderAndAllowsReentrantStoreWork {
  DSHRecordingSessionSnapshotStore *store = [[DSHRecordingSessionSnapshotStore alloc]
      initWithRootURL:self.rootURL
           sessionURL:[self.rootURL URLByAppendingPathComponent:@"sessions.json"]
     launchInstanceId:@"88888888-8888-4888-8888-888888888888"
           coordinator:[DSHSessionWorkspaceCoordinator sharedCoordinator]
             faultHook:nil];
  store.events = [NSMutableArray array];
  store.reenterCoordinatorOnLoad = YES;
  store.loadResult = @{
    @"schema_version" : @1,
    @"status" : @"missing",
    @"snapshot" : NSNull.null,
    @"session_json" : NSNull.null,
    @"writer_launch_instance_id" : NSNull.null,
    @"current_launch_instance_id" : @"88888888-8888-4888-8888-888888888888",
  };
  store.queryResult = @{
    @"schema_version" : @1,
    @"status" : @"not_started",
  };
  id<DSHSessionSnapshotsModuleTesting> module = [self moduleWithStore:store];
  XCTAssertEqual(module.operationQueue,
                 [DSHSessionWorkspaceCoordinator sharedQueue]);

  XCTestExpectation *load = [self expectationWithDescription:@"load"];
  [module loadSessionSnapshotWithResolver:^(__unused id value) {
    [store.events addObject:@"resolve-load"];
    [load fulfill];
  } rejecter:^(__unused NSString *code, __unused NSString *message,
              __unused NSError *error) {
    XCTFail(@"unexpected load rejection");
    [load fulfill];
  }];
  XCTestExpectation *query = [self expectationWithDescription:@"query"];
  [module querySessionCommitRequest:@{
      @"schema_version" : @1,
      @"operation_id" : DSHSessionModuleOperation,
  }
      resolver:^(__unused id value) {
        [store.events addObject:@"resolve-query"];
        [query fulfill];
      }
      rejecter:^(__unused NSString *code, __unused NSString *message,
                 __unused NSError *error) {
        XCTFail(@"unexpected query rejection");
        [query fulfill];
      }];
  [self waitForExpectations:@[ load, query ] timeout:2];
  XCTAssertEqualObjects(store.events,
                        (@[ @"load", @"reentrant", @"resolve-load",
                            @"query", @"resolve-query" ]));
}

- (void)testRequestMethodsSynchronouslyCaptureRNMutableContainersBeforeQueueing {
  DSHRecordingSessionSnapshotStore *store = [[DSHRecordingSessionSnapshotStore alloc]
      initWithRootURL:self.rootURL
           sessionURL:[self.rootURL URLByAppendingPathComponent:@"sessions.json"]
     launchInstanceId:@"44444444-4444-4444-8444-444444444444"
           coordinator:[DSHSessionWorkspaceCoordinator sharedCoordinator]
             faultHook:nil];
  store.casResult = @{
    @"schema_version" : @1,
    @"status" : @"unknown",
    @"current" : @{
      @"schema_version" : @1,
      @"kind" : @"missing",
    },
  };
  store.queryResult = @{
    @"schema_version" : @1,
    @"status" : @"not_started",
  };
  store.clearanceResult = @{
    @"schema_version" : @1,
    @"status" : @"unknown",
    @"receipt" : NSNull.null,
  };
  store.clearanceQueryResult = @{
    @"schema_version" : @1,
    @"status" : @"not_started",
  };
  id<DSHSessionSnapshotsModuleTesting> module = [self moduleWithStore:store];
  NSString *legacyDigest =
      @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  NSString *candidateJSON = @"{ \"schema_version\" : 9 }";
  NSMutableDictionary *legacy = [@{
    @"schema_version" : @1,
    @"legacy_bytes_sha256" : legacyDigest,
  } mutableCopy];
  NSMutableDictionary *expected = [@{
    @"schema_version" : @1,
    @"kind" : @"legacy_present",
    @"legacy" : legacy,
  } mutableCopy];
  NSMutableDictionary *request = [@{
    @"schema_version" : @1,
    @"operation_id" : DSHSessionModuleOperation,
    @"expected" : expected,
    @"candidate_json" : candidateJSON,
  } mutableCopy];
  XCTestExpectation *cas = [self expectationWithDescription:@"cas"];
  [module casPersistSessionRequest:request
      resolver:^(__unused NSDictionary *result) {
        [cas fulfill];
      }
      rejecter:^(__unused NSString *code, __unused NSString *message,
                 __unused NSError *error) {
        XCTFail(@"unexpected CAS rejection");
        [cas fulfill];
      }];
  request[@"operation_id"] = @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
  request[@"candidate_json"] = @"mutated candidate";
  expected[@"kind"] = @"missing";
  [expected removeObjectForKey:@"legacy"];
  legacy[@"legacy_bytes_sha256"] =
      @"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

  NSMutableDictionary *queryRequest = [@{
    @"schema_version" : @1,
    @"operation_id" : DSHSessionModuleOperation,
  } mutableCopy];
  XCTestExpectation *query = [self expectationWithDescription:@"query"];
  [module querySessionCommitRequest:queryRequest
      resolver:^(__unused NSDictionary *result) {
        [query fulfill];
      }
      rejecter:^(__unused NSString *code, __unused NSString *message,
                 __unused NSError *error) {
        XCTFail(@"unexpected query rejection");
        [query fulfill];
      }];
  queryRequest[@"operation_id"] =
      @"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";

  NSMutableDictionary *operation = [@{
    @"schema_version" : @1,
    @"operation_id" : DSHSessionModuleOperation,
    @"action" : @"forget",
    @"workspace_id" : @"22222222-2222-4222-8222-222222222222",
    @"binding_revision" : @1,
    @"clearance_receipt_id" : @"33333333-3333-4333-8333-333333333333",
    @"created_at" : @"2026-08-30T00:00:00.000Z",
  } mutableCopy];
  NSMutableDictionary *clearanceRequest = [@{
    @"schema_version" : @1,
    @"candidate_json" : candidateJSON,
    @"operation" : operation,
  } mutableCopy];
  XCTestExpectation *clearance =
      [self expectationWithDescription:@"clearance"];
  [module persistSessionWithWorkspaceClearanceRequest:clearanceRequest
      resolver:^(__unused NSDictionary *result) {
        [clearance fulfill];
      }
      rejecter:^(__unused NSString *code, __unused NSString *message,
                 __unused NSError *error) {
        XCTFail(@"unexpected clearance rejection");
        [clearance fulfill];
      }];
  clearanceRequest[@"candidate_json"] = @"mutated candidate";
  operation[@"action"] = @"delete_owned";

  NSMutableDictionary *clearanceQueryRequest = [@{
    @"schema_version" : @1,
    @"operation_id" : DSHSessionModuleOperation,
  } mutableCopy];
  XCTestExpectation *clearanceQuery =
      [self expectationWithDescription:@"clearance query"];
  [module queryWorkspaceClearanceRequest:clearanceQueryRequest
      resolver:^(__unused NSDictionary *result) {
        [clearanceQuery fulfill];
      }
      rejecter:^(__unused NSString *code, __unused NSString *message,
                 __unused NSError *error) {
        XCTFail(@"unexpected clearance query rejection");
        [clearanceQuery fulfill];
      }];
  clearanceQueryRequest[@"operation_id"] =
      @"cccccccc-cccc-4ccc-8ccc-cccccccccccc";

  [self waitForExpectations:@[ cas, query, clearance, clearanceQuery ] timeout:2];

  NSDictionary *capturedCAS = store.receivedCASRequest;
  XCTAssertNotEqual(capturedCAS, request);
  XCTAssertEqual([capturedCAS copy], capturedCAS);
  XCTAssertEqual([capturedCAS[@"expected"] copy], capturedCAS[@"expected"]);
  XCTAssertEqual([capturedCAS[@"expected"][@"legacy"] copy],
                 capturedCAS[@"expected"][@"legacy"]);
  XCTAssertEqualObjects(capturedCAS[@"operation_id"],
                        DSHSessionModuleOperation);
  XCTAssertEqualObjects(capturedCAS[@"expected"][@"kind"],
                        @"legacy_present");
  XCTAssertEqualObjects(
      capturedCAS[@"expected"][@"legacy"][@"legacy_bytes_sha256"],
      legacyDigest);
  XCTAssertEqualObjects(capturedCAS[@"candidate_json"], candidateJSON);

  XCTAssertNotEqual(store.receivedQueryRequest, queryRequest);
  XCTAssertEqual([store.receivedQueryRequest copy],
                 store.receivedQueryRequest);
  XCTAssertEqualObjects(store.receivedQueryRequest[@"operation_id"],
                        DSHSessionModuleOperation);
  XCTAssertNotEqual(store.receivedClearanceRequest, clearanceRequest);
  XCTAssertEqual([store.receivedClearanceRequest copy],
                 store.receivedClearanceRequest);
  XCTAssertEqual([store.receivedClearanceRequest[@"operation"] copy],
                 store.receivedClearanceRequest[@"operation"]);
  XCTAssertEqualObjects(store.receivedClearanceRequest[@"candidate_json"],
                        candidateJSON);
  XCTAssertEqualObjects(store.receivedClearanceRequest[@"operation"][@"action"],
                        @"forget");
  XCTAssertNotEqual(store.receivedClearanceQueryRequest,
                    clearanceQueryRequest);
  XCTAssertEqual([store.receivedClearanceQueryRequest copy],
                 store.receivedClearanceQueryRequest);
  XCTAssertEqualObjects(
      store.receivedClearanceQueryRequest[@"operation_id"],
      DSHSessionModuleOperation);
}

- (void)testRealStoreCommitsSchema8MigrationAsV3AfterCallerMutation {
  NSError *error = nil;
  XCTAssertNotNil([self.store loadSessionSnapshotWithError:&error]);
  XCTAssertNil(error);

  NSDictionary *legacySession = @{
    @"schema_version" : @8,
    @"workspace_authority_outbox" : @[],
    @"project_context_destructive_epoch" : @0,
    @"project_context_destructive_transition" : NSNull.null,
    @"active_conversation_id" : NSNull.null,
    @"conversations" : @[],
    @"messages" : @[],
    @"preferences" : [self sessionPreferences],
  };
  NSDictionary *legacyEnvelope = @{
    @"schema_version" : @2,
    @"writer_launch_instance_id" :
        @"22222222-2222-4222-8222-222222222222",
    @"session" : legacySession,
  };
  NSData *legacyBytes = [NSJSONSerialization dataWithJSONObject:legacyEnvelope
                                                        options:0
                                                          error:&error];
  XCTAssertNotNil(legacyBytes);
  XCTAssertNil(error);
  XCTAssertTrue([legacyBytes writeToURL:self.store.sessionURL
                                options:NSDataWritingAtomic
                                  error:&error]);
  XCTAssertNil(error);
  XCTAssertTrue([NSFileManager.defaultManager
      setAttributes:@{ NSFilePosixPermissions : @0600 }
       ofItemAtPath:self.store.sessionURL.path
              error:&error]);
  XCTAssertNil(error);

  NSDictionary *loaded = [self.store loadSessionSnapshotWithError:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(loaded[@"status"], @"legacy_present");
  NSMutableDictionary *legacy = [loaded[@"legacy"] mutableCopy];
  NSMutableDictionary *expected = [@{
    @"schema_version" : @1,
    @"kind" : @"legacy_present",
    @"legacy" : legacy,
  } mutableCopy];
  NSDictionary *candidate = [self schema8MigratedCandidate];
  NSData *candidateBytes = [NSJSONSerialization dataWithJSONObject:candidate
                                                            options:0
                                                              error:&error];
  XCTAssertNotNil(candidateBytes);
  XCTAssertNil(error);
  NSString *candidateJSON = [[NSString alloc]
      initWithData:candidateBytes encoding:NSUTF8StringEncoding];
  XCTAssertNotNil(candidateJSON);
  NSMutableDictionary *request = [@{
    @"schema_version" : @1,
    @"operation_id" : DSHSessionModuleOperation,
    @"expected" : expected,
    @"candidate_json" : candidateJSON,
  } mutableCopy];

  id<DSHSessionSnapshotsModuleTesting> module = [self moduleWithStore:self.store];
  XCTestExpectation *committed = [self expectationWithDescription:@"committed"];
  [module casPersistSessionRequest:request
      resolver:^(NSDictionary *result) {
        XCTAssertEqualObjects(result[@"status"], @"committed");
        XCTAssertEqualObjects(result[@"snapshot"][@"generation"], @1);
        [committed fulfill];
      }
      rejecter:^(NSString *code, __unused NSString *message,
                 __unused NSError *innerError) {
        XCTFail(@"unexpected real-store CAS rejection: %@", code);
        [committed fulfill];
      }];
  request[@"operation_id"] =
      @"dddddddd-dddd-4ddd-8ddd-dddddddddddd";
  request[@"candidate_json"] = @"mutated after native call";
  expected[@"kind"] = @"missing";
  [expected removeObjectForKey:@"legacy"];
  legacy[@"legacy_bytes_sha256"] =
      @"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
  [self waitForExpectations:@[ committed ] timeout:2];

  NSData *publishedBytes = [NSData dataWithContentsOfURL:self.store.sessionURL];
  XCTAssertNotNil(publishedBytes);
  NSDictionary *published = [NSJSONSerialization JSONObjectWithData:publishedBytes
                                                              options:0
                                                                error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(published[@"schema_version"], @3);
  XCTAssertEqualObjects(published[@"session"], candidate);
  XCTAssertEqualObjects(published[@"recent_commits"][0][@"operation_id"],
                        DSHSessionModuleOperation);
}

- (void)testNonJSONRequestIsRejectedSynchronouslyBeforeStoreOrQueue {
  DSHRecordingSessionSnapshotStore *store = [[DSHRecordingSessionSnapshotStore alloc]
      initWithRootURL:self.rootURL
           sessionURL:[self.rootURL URLByAppendingPathComponent:@"sessions.json"]
     launchInstanceId:@"99999999-9999-4999-8999-999999999999"
           coordinator:[DSHSessionWorkspaceCoordinator sharedCoordinator]
             faultHook:nil];
  store.queryResult = @{
    @"schema_version" : @1,
    @"status" : @"not_started",
  };
  id<DSHSessionSnapshotsModuleTesting> module = [self moduleWithStore:store];
  id hostileRequest = [[DSHThrowingSessionDictionary alloc] init];
  __block BOOL rejectedSynchronously = NO;
  [module querySessionCommitRequest:hostileRequest
      resolver:^(__unused NSDictionary *result) {
        XCTFail(@"non-JSON request must not resolve");
      }
      rejecter:^(NSString *code, NSString *message, NSError *error) {
        XCTAssertEqualObjects(code, @"E_SESSION_INVALID");
        XCTAssertEqualObjects(message, code);
        XCTAssertNil(error);
        rejectedSynchronously = YES;
      }];
  XCTAssertTrue(rejectedSynchronously);
  XCTAssertNil(store.receivedQueryRequest);
}

- (void)testStoreErrorsAreStableAndValueFree {
  DSHRecordingSessionSnapshotStore *store = [[DSHRecordingSessionSnapshotStore alloc]
      initWithRootURL:self.rootURL
           sessionURL:[self.rootURL URLByAppendingPathComponent:@"sessions.json"]
     launchInstanceId:@"55555555-5555-4555-8555-555555555555"
           coordinator:[DSHSessionWorkspaceCoordinator sharedCoordinator]
             faultHook:nil];
  store.injectedError = [NSError errorWithDomain:DSHSessionSnapshotStoreErrorDomain
                                              code:DSHSessionSnapshotStoreErrorConflict
                                          userInfo:@{
                                            @"code" : @"E_SESSION_CONFLICT",
                                            @"path" : @"/private/secret",
                                          }];
  id<DSHSessionSnapshotsModuleTesting> module = [self moduleWithStore:store];
  XCTestExpectation *rejected = [self expectationWithDescription:@"rejected"];
  [module loadSessionSnapshotWithResolver:^(__unused id value) {
    XCTFail(@"must not resolve");
    [rejected fulfill];
  } rejecter:^(NSString *code, NSString *message, NSError *error) {
    XCTAssertEqualObjects(code, @"E_SESSION_CONFLICT");
    XCTAssertEqualObjects(message, code);
    XCTAssertNil(error);
    [rejected fulfill];
  }];
  [self waitForExpectations:@[ rejected ] timeout:2];
}

- (void)testMalformedStoreResultFailsClosedWithoutLeakingItsValues {
  DSHRecordingSessionSnapshotStore *store = [[DSHRecordingSessionSnapshotStore alloc]
      initWithRootURL:self.rootURL
           sessionURL:[self.rootURL URLByAppendingPathComponent:@"sessions.json"]
     launchInstanceId:@"66666666-6666-4666-8666-666666666666"
           coordinator:[DSHSessionWorkspaceCoordinator sharedCoordinator]
             faultHook:nil];
  store.queryResult = @{
    @"schema_version" : @1,
    @"status" : @"not_started",
    @"path" : @"/private/secret",
  };
  id<DSHSessionSnapshotsModuleTesting> module = [self moduleWithStore:store];
  XCTestExpectation *rejected = [self expectationWithDescription:@"rejected"];
  [module querySessionCommitRequest:@{
      @"schema_version" : @1,
      @"operation_id" : DSHSessionModuleOperation,
  }
      resolver:^(__unused id value) {
        XCTFail(@"must not resolve");
        [rejected fulfill];
      }
      rejecter:^(NSString *code, NSString *message, NSError *error) {
        XCTAssertEqualObjects(code, @"E_SESSION_INVALID");
        XCTAssertEqualObjects(message, code);
        XCTAssertNil(error);
        [rejected fulfill];
      }];
  [self waitForExpectations:@[ rejected ] timeout:2];
}

- (void)testMalformedStoreResultCodesMatchTheTypeScriptBoundary {
  [self assertLoadResult:@{
    @"schema_version" : @1,
    @"status" : @"missing",
    @"snapshot" : @{},
    @"session_json" : NSNull.null,
    @"writer_launch_instance_id" : NSNull.null,
    @"current_launch_instance_id" : @"99999999-9999-4999-8999-999999999999",
  }
          rejectsWithCode:@"E_SESSION_CORRUPT"];

  [self assertLoadResult:@{
    @"schema_version" : @2,
    @"status" : @"missing",
    @"snapshot" : NSNull.null,
    @"session_json" : NSNull.null,
    @"writer_launch_instance_id" : NSNull.null,
    @"current_launch_instance_id" : @"99999999-9999-4999-8999-999999999999",
  }
          rejectsWithCode:@"E_SESSION_PERSISTENCE"];

  [self assertLoadResult:@{
    @"schema_version" : @1,
    @"status" : @"legacy_present",
    @"legacy" : @{
      @"schema_version" : @1,
    },
    @"session_json" : @"{\"schema_version\":8}",
    @"writer_launch_instance_id" : @"99999999-9999-4999-8999-999999999999",
    @"current_launch_instance_id" : @"99999999-9999-4999-8999-999999999999",
  }
          rejectsWithCode:@"E_SESSION_INVALID"];

  // A load result without the launch instance ids (the pre-recovery store
  // shape) or with a malformed writer id never reaches JS.
  [self assertLoadResult:@{
    @"schema_version" : @1,
    @"status" : @"missing",
    @"snapshot" : NSNull.null,
    @"session_json" : NSNull.null,
  }
          rejectsWithCode:@"E_SESSION_INVALID"];
  [self assertLoadResult:@{
    @"schema_version" : @1,
    @"status" : @"present",
    @"snapshot" : @{
      @"schema_version" : @1,
      @"generation" : @1,
      @"session_sha256" :
          @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    },
    @"session_json" : @"{\"schema_version\":9}",
    @"writer_launch_instance_id" : @"not-a-launch-id",
    @"current_launch_instance_id" : @"99999999-9999-4999-8999-999999999999",
  }
          rejectsWithCode:@"E_SESSION_INVALID"];
  [self assertLoadResult:@{
    @"schema_version" : @1,
    @"status" : @"missing",
    @"snapshot" : NSNull.null,
    @"session_json" : NSNull.null,
    @"writer_launch_instance_id" : @"99999999-9999-4999-8999-999999999999",
    @"current_launch_instance_id" : @"99999999-9999-4999-8999-999999999999",
  }
          rejectsWithCode:@"E_SESSION_CORRUPT"];
}

- (void)testHostileStoreResultIsContainedAsAStableNativeFailure {
  DSHRecordingSessionSnapshotStore *store =
      [[DSHRecordingSessionSnapshotStore alloc]
          initWithRootURL:self.rootURL
               sessionURL:[self.rootURL URLByAppendingPathComponent:@"sessions.json"]
         launchInstanceId:@"dddddddd-dddd-4ddd-8ddd-dddddddddddd"
               coordinator:[DSHSessionWorkspaceCoordinator sharedCoordinator]
                 faultHook:nil];
  store.queryResult = (NSDictionary *)[[DSHThrowingSessionDictionary alloc] init];
  id<DSHSessionSnapshotsModuleTesting> module = [self moduleWithStore:store];
  XCTestExpectation *rejected =
      [self expectationWithDescription:@"hostile-result"];
  [module querySessionCommitRequest:@{
      @"schema_version" : @1,
      @"operation_id" : DSHSessionModuleOperation,
  }
      resolver:^(__unused id value) {
        XCTFail(@"hostile result must not resolve");
        [rejected fulfill];
      }
      rejecter:^(NSString *code, NSString *message, NSError *error) {
        XCTAssertEqualObjects(code, @"E_SESSION_NATIVE");
        XCTAssertEqualObjects(message, code);
        XCTAssertNil(error);
        [rejected fulfill];
      }];
  [self waitForExpectations:@[ rejected ] timeout:2];
}

- (void)testThrowingStoreAndNilResultWithoutErrorRemainValueFree {
  DSHRecordingSessionSnapshotStore *throwing =
      [[DSHRecordingSessionSnapshotStore alloc]
          initWithRootURL:self.rootURL
               sessionURL:[self.rootURL URLByAppendingPathComponent:@"sessions.json"]
         launchInstanceId:@"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
               coordinator:[DSHSessionWorkspaceCoordinator sharedCoordinator]
                 faultHook:nil];
  throwing.throwOnLoad = YES;
  id<DSHSessionSnapshotsModuleTesting> throwingModule =
      [self moduleWithStore:throwing];
  XCTestExpectation *thrown = [self expectationWithDescription:@"thrown"];
  [throwingModule loadSessionSnapshotWithResolver:^(__unused id value) {
    XCTFail(@"throwing store must not resolve");
    [thrown fulfill];
  } rejecter:^(NSString *code, NSString *message, NSError *error) {
    XCTAssertEqualObjects(code, @"E_SESSION_NATIVE");
    XCTAssertEqualObjects(message, code);
    XCTAssertNil(error);
    [thrown fulfill];
  }];
  [self waitForExpectations:@[ thrown ] timeout:2];

  [self assertLoadResult:nil rejectsWithCode:@"E_SESSION_PERSISTENCE"];

  id<DSHSessionSnapshotsModuleTesting> unavailable =
      [self moduleWithStore:nil];
  XCTestExpectation *unavailableExpectation =
      [self expectationWithDescription:@"unavailable"];
  [unavailable loadSessionSnapshotWithResolver:^(__unused id value) {
    XCTFail(@"missing store must not resolve");
    [unavailableExpectation fulfill];
  } rejecter:^(NSString *code, NSString *message, NSError *error) {
    XCTAssertEqualObjects(code, @"E_SESSION_STORAGE");
    XCTAssertEqualObjects(message, code);
    XCTAssertNil(error);
    [unavailableExpectation fulfill];
  }];
  [self waitForExpectations:@[ unavailableExpectation ] timeout:2];
}

- (void)testKnownResultStatesRejectFutureStatusesAndPreserveNoDowngrade {
  DSHRecordingSessionSnapshotStore *store = [[DSHRecordingSessionSnapshotStore alloc]
      initWithRootURL:self.rootURL
           sessionURL:[self.rootURL URLByAppendingPathComponent:@"sessions.json"]
     launchInstanceId:@"cccccccc-cccc-4ccc-8ccc-cccccccccccc"
           coordinator:[DSHSessionWorkspaceCoordinator sharedCoordinator]
             faultHook:nil];
  store.loadResult = @{
    @"schema_version" : @1,
    @"status" : @"future_status",
    @"session_json" : @"{\"schema_version\":9}",
  };
  id<DSHSessionSnapshotsModuleTesting> module = [self moduleWithStore:store];
  XCTestExpectation *rejected =
      [self expectationWithDescription:@"future status"];
  [module loadSessionSnapshotWithResolver:^(__unused id value) {
    XCTFail(@"future status must not resolve");
    [rejected fulfill];
  } rejecter:^(NSString *code, NSString *message, NSError *error) {
    XCTAssertEqualObjects(code, @"E_SESSION_PERSISTENCE");
    XCTAssertEqualObjects(message, code);
    XCTAssertNil(error);
    [rejected fulfill];
  }];
  [self waitForExpectations:@[ rejected ] timeout:2];
}

// Historical session digest parity constants over the same shared fixtures,
// recorded before the shell migration. Keep existing persisted digests stable.
static NSString *const DSHSessionDigestParityBeginRound =
    @"ec84b5ee47814d689598afd62c056940af2fdd723e951a094e71e00cd7eacd53";
static NSString *const DSHSessionDigestParityInterruptedRecovery =
    @"eca528ffb764538d2fffad800659dcdba44e1839a7c169be3a02a6ed707bcc60";

- (NSString *)sharedFixtureTextNamed:(NSString *)name {
  NSURL *url = [[NSBundle bundleForClass:self.class] URLForResource:name
                                                     withExtension:@"json"];
  XCTAssertNotNil(url, @"missing shared fixture %@", name);
  NSString *text = url == nil ? nil
      : [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding
                                     error:nil];
  XCTAssertNotNil(text);
  return text;
}

- (void)testSessionCandidateDigestMatchesJSAndCommittedSha256WithoutTouchingTheStore {
  id<DSHSessionSnapshotsModuleTesting> module = [self moduleWithStore:self.store];
  NSString *beginRound = [self sharedFixtureTextNamed:@"agent-begin-round-session"];
  NSString *recovery =
      [self sharedFixtureTextNamed:@"agent-interrupted-recovery-session"];

  // Pure: digesting must not create, lock or read the session file.
  XCTAssertEqualObjects([(id)module sessionCandidateDigest:beginRound],
                        DSHSessionDigestParityBeginRound);
  XCTAssertEqualObjects([(id)module sessionCandidateDigest:recovery],
                        DSHSessionDigestParityInterruptedRecovery);
  NSError *error = nil;
  NSDictionary *loaded = [self.store loadSessionSnapshotWithError:&error];
  XCTAssertEqualObjects(loaded[@"status"], @"missing");
  XCTAssertNil(error);

  // Same value the CAS path mints for that candidate.
  NSDictionary *committed = [self.store casPersistSession:@{
    @"schema_version" : @1,
    @"operation_id" : @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    @"expected" : @{ @"schema_version" : @1, @"kind" : @"missing" },
    @"candidate_json" : beginRound,
  } error:&error];
  XCTAssertEqualObjects(committed[@"status"], @"committed", @"%@", error);
  XCTAssertEqualObjects(committed[@"snapshot"][@"session_sha256"],
                        DSHSessionDigestParityBeginRound);

  // Formatting-insensitive (canonical JSON), content-sensitive.
  NSData *reparsed = [NSJSONSerialization
      dataWithJSONObject:[NSJSONSerialization JSONObjectWithData:
          [beginRound dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil]
                 options:NSJSONWritingPrettyPrinted error:nil];
  XCTAssertEqualObjects([(id)module sessionCandidateDigest:
      [[NSString alloc] initWithData:reparsed encoding:NSUTF8StringEncoding]],
                        DSHSessionDigestParityBeginRound);
  NSString *edited = [beginRound stringByReplacingOccurrencesOfString:@"\"schema_version\":9"
                                                            withString:@"\"schema_version\": 9"];
  XCTAssertEqualObjects([(id)module sessionCandidateDigest:edited],
                        DSHSessionDigestParityBeginRound);
  XCTAssertNotEqualObjects([(id)module sessionCandidateDigest:recovery],
                           DSHSessionDigestParityBeginRound);

  // Anything the CAS would refuse digests to nil: wrong type, empty, not an
  // object, not schema 9, malformed JSON.
  XCTAssertNil([(id)module sessionCandidateDigest:@42]);
  XCTAssertNil([(id)module sessionCandidateDigest:NSNull.null]);
  XCTAssertNil([(id)module sessionCandidateDigest:@""]);
  XCTAssertNil([(id)module sessionCandidateDigest:@"[]"]);
  XCTAssertNil([(id)module sessionCandidateDigest:@"{}"]);
  XCTAssertNil([(id)module sessionCandidateDigest:@"{\"schema_version\":8}"]);
  // Shallow by design (JS parity): a schema-9 object digests even when the CAS
  // would later refuse it; the CAS keeps the full validation.
  XCTAssertEqualObjects([(id)module sessionCandidateDigest:@"{\"schema_version\":9}"],
                        [(id)module sessionCandidateDigest:@"{ \"schema_version\" : 9 }"]);
  XCTAssertNotNil([(id)module sessionCandidateDigest:@"{\"schema_version\":9}"]);
  XCTAssertNil([(id)module sessionCandidateDigest:
      [beginRound stringByAppendingString:@"}"]]);
  XCTAssertNil([DSHSessionSnapshotStore candidateDigestForSessionJSON:
      [beginRound stringByReplacingOccurrencesOfString:@"\"schema_version\":9,"
                                            withString:@"\"schema_version\":10,"]]);
}

@end
