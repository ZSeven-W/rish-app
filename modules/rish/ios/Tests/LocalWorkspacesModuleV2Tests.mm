#import <XCTest/XCTest.h>
#import <RishNative/RishNativeModule.h>

#import "../../../../modules/rish/ios/Sources/LocalWorkspaceAccess.h"

#include <unistd.h>

@interface LocalWorkspacesModule : NSObject
@end

@interface LocalWorkspacesModule (LegacyBootstrapV2Testing)
- (void)bootstrapLegacyProjectRequest:(id)request
                              resolver:(RishResolveBlock)resolve
                              rejecter:(RishRejectBlock)reject;
@end

@interface LocalWorkspacesBootstrapFakeAccess : NSObject
@property(nonatomic, copy) NSDictionary *descriptor;
@property(nonatomic, strong) NSError *failure;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *calls;
@property(nonatomic) NSUInteger activeCalls;
@property(nonatomic) NSUInteger maximumActiveCalls;
@property(nonatomic) useconds_t delayMicroseconds;
@end

@implementation LocalWorkspacesBootstrapFakeAccess

- (instancetype)init {
  self = [super init];
  if (self != nil) _calls = [NSMutableArray array];
  return self;
}

- (NSDictionary *)bootstrapLegacyProjectId:(NSString *)projectId
                                operationId:(NSString *)operationId
                                      error:(NSError **)error {
  @synchronized(self) {
    [self.calls addObject:@{
      @"project_id" : [projectId copy],
      @"operation_id" : [operationId copy],
    }];
    self.activeCalls += 1;
    self.maximumActiveCalls = MAX(self.maximumActiveCalls, self.activeCalls);
  }
  if (self.delayMicroseconds > 0) usleep(self.delayMicroseconds);
  @synchronized(self) {
    self.activeCalls -= 1;
  }
  if (self.failure != nil) {
    if (error != nil) *error = self.failure;
    return nil;
  }
  return self.descriptor;
}

@end


@interface LocalWorkspacesModuleV2Tests : XCTestCase
@property(nonatomic, strong) LocalWorkspacesModule *module;
@property(nonatomic, strong) LocalWorkspacesBootstrapFakeAccess *access;
@end

@implementation LocalWorkspacesModuleV2Tests

static NSString *const LWProjectId =
    @"11111111-1111-4111-8111-111111111111";
static NSString *const LWOperationId =
    @"22222222-2222-4222-8222-222222222222";

- (void)setUp {
  [super setUp];
  Class moduleClass = NSClassFromString(@"LocalWorkspacesModule");
  if (moduleClass == Nil) {
    XCTSkip(@"LocalWorkspacesModule is not linked into this XCTest target");
  }
  self.module = [[moduleClass alloc] init];
  self.access = [[LocalWorkspacesBootstrapFakeAccess alloc] init];
  self.access.descriptor = [self descriptor];
  [self.module setValue:self.access forKey:@"access"];
}

- (NSDictionary *)descriptor {
  return @{
    @"schema_version" : @2,
    @"workspace_id" : @"33333333-3333-4333-8333-333333333333",
    @"display_name" : @"Legacy Workspace",
    @"origin" : @"legacy_app_owned",
    @"status" : @"ok",
    @"binding_revision" : @1,
    @"capabilities" : @{
      @"read" : @YES,
      @"write" : @YES,
      @"git" : @YES,
      @"project_context" : @YES,
      @"files_visible" : @NO,
    },
    @"created_at" : @"2026-09-01T00:00:00.000Z",
    @"last_opened_at" : @"2026-09-01T00:00:00.000Z",
  };
}

- (NSDictionary *)request {
  return @{
    @"schema_version" : @1,
    @"project_id" : LWProjectId,
    @"operation_id" : LWOperationId,
  };
}

- (id)awaitRequest:(id)request
       expectedCode:(NSString *)expectedCode
            message:(NSString **)messageOut
              error:(NSError **)nativeErrorOut {
  XCTestExpectation *finished = [self expectationWithDescription:@"bridge result"];
  __block id result = nil;
  __block NSString *code = nil;
  __block NSString *message = nil;
  __block NSError *nativeError = nil;
  [self.module bootstrapLegacyProjectRequest:request
      resolver:^(id value) {
        result = value;
        [finished fulfill];
      }
      rejecter:^(NSString *rejectedCode, NSString *rejectedMessage,
                 NSError *rejectedError) {
        code = [rejectedCode copy];
        message = [rejectedMessage copy];
        nativeError = rejectedError;
        [finished fulfill];
      }];
  [self waitForExpectationsWithTimeout:5 handler:nil];
  if (messageOut != nil) *messageOut = message;
  if (nativeErrorOut != nil) *nativeErrorOut = nativeError;
  if (expectedCode == nil) {
    XCTAssertNotNil(result);
    XCTAssertNil(code);
  } else {
    XCTAssertNil(result);
    XCTAssertEqualObjects(code, expectedCode);
  }
  return result;
}

- (void)testBootstrapAcceptsExactSchemaOneUUIDRequest {
  XCTAssertNotNil([self awaitRequest:[self request]
                         expectedCode:nil message:nil error:nil]);
  XCTAssertEqual(self.access.calls.count, 1u);
}

- (void)testBootstrapRejectsExtraRequestKey {
  NSMutableDictionary *extra = [[self request] mutableCopy];
  extra[@"path"] = @"/private/secret";
  [self awaitRequest:extra expectedCode:@"E_WORKSPACE_INVALID"
             message:nil error:nil];
  XCTAssertEqual(self.access.calls.count, 0u);
}

- (void)testBootstrapRejectsMissingRequestKey {
  NSMutableDictionary *missing = [[self request] mutableCopy];
  [missing removeObjectForKey:@"operation_id"];
  [self awaitRequest:missing expectedCode:@"E_WORKSPACE_INVALID"
             message:nil error:nil];
  XCTAssertEqual(self.access.calls.count, 0u);
}

- (void)testBootstrapRejectsWrongSchema {
  NSMutableDictionary *wrongSchema = [[self request] mutableCopy];
  wrongSchema[@"schema_version"] = @2;
  [self awaitRequest:wrongSchema expectedCode:@"E_WORKSPACE_INVALID"
             message:nil error:nil];
  XCTAssertEqual(self.access.calls.count, 0u);
}

- (void)testBootstrapRejectsNonCanonicalProjectAndOperationUUIDs {
  NSMutableDictionary *badProject = [[self request] mutableCopy];
  badProject[@"project_id"] =
      @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa".uppercaseString;
  [self awaitRequest:badProject expectedCode:@"E_WORKSPACE_INVALID"
             message:nil error:nil];
  NSMutableDictionary *badOperation = [[self request] mutableCopy];
  badOperation[@"operation_id"] = @"not-a-uuid";
  [self awaitRequest:badOperation expectedCode:@"E_WORKSPACE_INVALID"
             message:nil error:nil];
  XCTAssertEqual(self.access.calls.count, 0u);
}

- (void)testBootstrapSnapshotsMutableRequestBeforeAsyncDispatch {
  dispatch_queue_t queue = [self.module valueForKey:@"workspaceQueue"];
  dispatch_semaphore_t blocked = dispatch_semaphore_create(0);
  dispatch_async(queue, ^{
    dispatch_semaphore_wait(blocked,
        dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
  });
  NSMutableString *projectId = [LWProjectId mutableCopy];
  NSMutableString *operationId = [LWOperationId mutableCopy];
  NSMutableDictionary *request = [@{
    @"schema_version" : @1,
    @"project_id" : projectId,
    @"operation_id" : operationId,
  } mutableCopy];
  XCTestExpectation *finished = [self expectationWithDescription:@"snapshot"];
  [self.module bootstrapLegacyProjectRequest:request resolver:^(__unused id value) {
    [finished fulfill];
  } rejecter:^(__unused NSString *code, __unused NSString *message,
               __unused NSError *error) {
    XCTFail(@"snapshot request rejected");
    [finished fulfill];
  }];
  [projectId setString:@"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"];
  [operationId setString:@"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"];
  request[@"path"] = @"/mutated/after-call";
  dispatch_semaphore_signal(blocked);
  [self waitForExpectationsWithTimeout:5 handler:nil];
  XCTAssertEqualObjects(self.access.calls.firstObject[@"project_id"], LWProjectId);
  XCTAssertEqualObjects(self.access.calls.firstObject[@"operation_id"], LWOperationId);
}

- (void)testBootstrapRunsCoreCallsOnOneSerialQueue {
  self.access.delayMicroseconds = 50000;
  XCTestExpectation *first = [self expectationWithDescription:@"first"];
  XCTestExpectation *second = [self expectationWithDescription:@"second"];
  [self.module bootstrapLegacyProjectRequest:[self request]
      resolver:^(__unused id value) { [first fulfill]; }
      rejecter:^(__unused NSString *code, __unused NSString *message,
                 __unused NSError *error) { [first fulfill]; }];
  NSMutableDictionary *secondRequest = [[self request] mutableCopy];
  secondRequest[@"operation_id"] =
      @"44444444-4444-4444-8444-444444444444";
  [self.module bootstrapLegacyProjectRequest:secondRequest
      resolver:^(__unused id value) { [second fulfill]; }
      rejecter:^(__unused NSString *code, __unused NSString *message,
                 __unused NSError *error) { [second fulfill]; }];
  [self waitForExpectationsWithTimeout:5 handler:nil];
  XCTAssertEqual(self.access.maximumActiveCalls, 1u);
  XCTAssertEqual(self.access.calls.count, 2u);
}

- (void)testBootstrapReplayReturnsStableSafeDescriptor {
  NSDictionary *first = [self awaitRequest:[self request]
                               expectedCode:nil message:nil error:nil];
  NSDictionary *second = [self awaitRequest:[self request]
                                expectedCode:nil message:nil error:nil];
  XCTAssertEqualObjects(first, second);
  XCTAssertEqualObjects(self.access.calls[0], self.access.calls[1]);
}

- (void)testBootstrapProjectsExactDescriptorAndDropsPrivateFields {
  NSMutableDictionary *leaky = [[self descriptor] mutableCopy];
  leaky[@"path"] = @"/private/var/mobile/Containers/secret";
  leaky[@"root_url"] = @"file:///private/secret";
  leaky[@"bookmark"] = @"opaque-secret";
  leaky[@"name"] = @"wrong-alias";
  self.access.descriptor = leaky;
  NSDictionary *result = [self awaitRequest:[self request]
                                expectedCode:nil message:nil error:nil];
  NSSet *expectedKeys = [NSSet setWithArray:@[
    @"schema_version", @"workspace_id", @"display_name", @"origin",
    @"status", @"binding_revision", @"capabilities", @"created_at",
    @"last_opened_at",
  ]];
  XCTAssertEqualObjects([NSSet setWithArray:result.allKeys], expectedKeys);
  XCTAssertNil(result[@"path"]);
  XCTAssertNil(result[@"root_url"]);
  XCTAssertNil(result[@"bookmark"]);
  XCTAssertNil(result[@"name"]);
}

- (void)testBootstrapRejectsInvalidCoreDescriptorWithoutLeakingIt {
  NSMutableDictionary *invalid = [[self descriptor] mutableCopy];
  [invalid removeObjectForKey:@"workspace_id"];
  invalid[@"path"] = @"/private/secret";
  self.access.descriptor = invalid;
  NSString *message = nil;
  NSError *nativeError = nil;
  [self awaitRequest:[self request] expectedCode:@"E_WORKSPACE_UNAVAILABLE"
             message:&message error:&nativeError];
  XCTAssertEqualObjects(message, @"Workspace is unavailable.");
  XCTAssertNil(nativeError);
  XCTAssertFalse([message containsString:@"private"]);
}

- (void)testBootstrapSanitizesCoreErrorsToStableCodeAndMessage {
  self.access.failure = [NSError errorWithDomain:@"private.native"
      code:91
      userInfo:@{
        @"code" : @"E_WORKSPACE_NOT_FOUND",
        NSLocalizedDescriptionKey : @"secret /private/container/path",
      }];
  NSString *message = nil;
  NSError *nativeError = nil;
  [self awaitRequest:[self request] expectedCode:@"E_WORKSPACE_NOT_FOUND"
             message:&message error:&nativeError];
  XCTAssertEqualObjects(message, @"Workspace is not available.");
  XCTAssertNil(nativeError);

  self.access.failure = [NSError errorWithDomain:@"private.native"
      code:92
      userInfo:@{
        @"code" : @"E_PRIVATE_PATH_FAILURE",
        NSLocalizedDescriptionKey : @"secret /private/container/path",
      }];
  [self awaitRequest:[self request] expectedCode:@"E_WORKSPACE_UNAVAILABLE"
             message:&message error:&nativeError];
  XCTAssertEqualObjects(message, @"Workspace is unavailable.");
  XCTAssertNil(nativeError);
}

@end
