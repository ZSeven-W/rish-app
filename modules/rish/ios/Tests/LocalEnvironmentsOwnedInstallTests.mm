#import <XCTest/XCTest.h>
#import <RishNative/RishNativeModule.h>
#import "RuntimeEnvironmentStore.h"

@interface LocalEnvironmentsModule : NSObject
- (DSHRuntimeEnvironmentStore *)environmentStore;
- (void)installEnvironmentOwnedRequest:(id)request resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject;
- (void)cancelOwnedInstallRequest:(id)request resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject;
@end

@interface OwnedInstallTestStore : NSObject
@property(nonatomic, copy) NSString *(^beginBlock)(NSString *, DSHEnvironmentCompletion);
@property(nonatomic, strong) NSMutableArray<NSString *> *cancelledTokens;
@property(nonatomic) NSUInteger beginCount;
@end
@implementation OwnedInstallTestStore
- (instancetype)init { if ((self = [super init])) self.cancelledTokens = [NSMutableArray new]; return self; }
- (NSString *)beginInstallEnvironmentId:(NSString *)environmentId completion:(DSHEnvironmentCompletion)completion {
  self.beginCount += 1; return self.beginBlock(environmentId, completion);
}
- (BOOL)cancelInstallToken:(NSString *)token { [self.cancelledTokens addObject:token]; return YES; }
@end

@interface OwnedInstallTestModule : LocalEnvironmentsModule
@property(nonatomic, strong) OwnedInstallTestStore *testStore;
@end
@implementation OwnedInstallTestModule
- (DSHRuntimeEnvironmentStore *)environmentStore { return (DSHRuntimeEnvironmentStore *)self.testStore; }
@end

@interface LocalEnvironmentsOwnedInstallTests : XCTestCase
@property(nonatomic, strong) OwnedInstallTestModule *module;
@property(nonatomic, strong) OwnedInstallTestStore *store;
@end

@implementation LocalEnvironmentsOwnedInstallTests
- (void)setUp {
  [super setUp]; self.store = [OwnedInstallTestStore new]; self.module = [OwnedInstallTestModule new]; self.module.testStore = self.store;
}
- (NSDictionary *)request:(NSString *)operationId {
  return @{@"schema_version":@1, @"operation_id":operationId, @"environment_id":@"python-test"};
}
- (NSDictionary *)cancel:(NSString *)operationId {
  __block NSDictionary *result = nil;
  [self.module cancelOwnedInstallRequest:@{@"schema_version":@1, @"operation_id":operationId}
      resolver:^(id value) { result = value; }
      rejecter:^(NSString *code, NSString *message, NSError *error) { XCTFail(@"unexpected %@", code); }];
  return result;
}
- (void)testCancelBeforeInstallNeverCallsTheStore {
  NSString *operationId = NSUUID.UUID.UUIDString.lowercaseString;
  XCTAssertEqualObjects([self cancel:operationId][@"status"], @"cancelled");
  __block NSString *failure = nil;
  [self.module installEnvironmentOwnedRequest:[self request:operationId]
      resolver:^(id result) { XCTFail(@"cancelled operation resolved"); }
      rejecter:^(NSString *code, NSString *message, NSError *error) { failure = code; }];
  XCTAssertEqualObjects(failure, @"E_ENV_CANCELLED");
  XCTAssertEqual(self.store.beginCount, 0u); XCTAssertEqual(self.store.cancelledTokens.count, 0u);
}
- (void)testCancellationBeforeTheStoreReturnsItsTokenReachesOnlyThatToken {
  NSString *operationId = NSUUID.UUID.UUIDString.lowercaseString;
  __weak LocalEnvironmentsOwnedInstallTests *weakSelf = self;
  __block DSHEnvironmentCompletion completion = nil;
  self.store.beginBlock = ^NSString *(NSString *environmentId, DSHEnvironmentCompletion callback) {
    completion = callback;
    XCTAssertEqualObjects([weakSelf cancel:operationId][@"status"], @"cancelled");
    return @"manual-token";
  };
  __block NSString *failure = nil;
  [self.module installEnvironmentOwnedRequest:[self request:operationId]
      resolver:^(id result) { XCTFail(@"cancelled operation resolved"); }
      rejecter:^(NSString *code, NSString *message, NSError *error) { failure = code; }];
  XCTAssertEqualObjects(self.store.cancelledTokens, (@[@"manual-token"]));
  completion(nil, DSHEnvironmentError(@"E_ENV_CANCELLED"));
  XCTAssertEqualObjects(failure, @"E_ENV_CANCELLED");
}
- (void)testSynchronousAlreadyInstalledCompletionDoesNotRetainOrCancelAToken {
  NSDictionary *installed = @{@"schema_version":@1,@"environment_id":@"python-test",@"state":@"installed"};
  self.store.beginBlock = ^NSString *(NSString *environmentId, DSHEnvironmentCompletion callback) { callback(installed, nil); return nil; };
  NSString *operationId = NSUUID.UUID.UUIDString.lowercaseString;
  __block id result = nil;
  [self.module installEnvironmentOwnedRequest:[self request:operationId]
      resolver:^(id value) { result = value; }
      rejecter:^(NSString *code, NSString *message, NSError *error) { XCTFail(@"unexpected %@", code); }];
  XCTAssertEqualObjects(result, installed);
  XCTAssertEqualObjects([self cancel:operationId][@"status"], @"idle");
  XCTAssertEqual(self.store.cancelledTokens.count, 0u);
}
- (void)testBusyRefusalCleanupCannotCancelAnAgentDownload {
  self.store.beginBlock = ^NSString *(NSString *environmentId, DSHEnvironmentCompletion callback) {
    callback(nil, DSHEnvironmentError(@"E_ENV_BUSY")); return nil;
  };
  NSString *operationId = NSUUID.UUID.UUIDString.lowercaseString;
  __block NSString *failure = nil;
  [self.module installEnvironmentOwnedRequest:[self request:operationId]
      resolver:^(id result) { XCTFail(@"busy operation resolved"); }
      rejecter:^(NSString *code, NSString *message, NSError *error) { failure = code; }];
  XCTAssertEqualObjects(failure, @"E_ENV_BUSY");
  XCTAssertEqualObjects([self cancel:operationId][@"status"], @"idle");
  XCTAssertEqual(self.store.cancelledTokens.count, 0u);
}
- (void)testOldCleanupCannotCancelANewerManualInstallation {
  __block DSHEnvironmentCompletion oldCompletion = nil;
  self.store.beginBlock = ^NSString *(NSString *environmentId, DSHEnvironmentCompletion callback) { oldCompletion = callback; return @"old-token"; };
  NSString *oldId = NSUUID.UUID.UUIDString.lowercaseString, *newId = NSUUID.UUID.UUIDString.lowercaseString;
  [self.module installEnvironmentOwnedRequest:[self request:oldId] resolver:^(id result) {}
      rejecter:^(NSString *code, NSString *message, NSError *error) { XCTFail(@"unexpected %@", code); }];
  oldCompletion(@{@"state":@"installed"}, nil);
  self.store.beginBlock = ^NSString *(NSString *environmentId, DSHEnvironmentCompletion callback) { return @"new-token"; };
  [self.module installEnvironmentOwnedRequest:[self request:newId] resolver:^(id result) {}
      rejecter:^(NSString *code, NSString *message, NSError *error) { XCTFail(@"unexpected %@", code); }];
  XCTAssertEqualObjects([self cancel:oldId][@"status"], @"idle");
  XCTAssertEqual(self.store.cancelledTokens.count, 0u);
  XCTAssertEqualObjects([self cancel:newId][@"status"], @"cancelled");
  XCTAssertEqualObjects(self.store.cancelledTokens, (@[@"new-token"]));
}
- (void)testOperationIdsCannotBeReusedEvenAfterSynchronousCompletion {
  self.store.beginBlock = ^NSString *(NSString *environmentId, DSHEnvironmentCompletion callback) { callback(@{@"state":@"installed"}, nil); return nil; };
  NSString *operationId = NSUUID.UUID.UUIDString.lowercaseString;
  [self.module installEnvironmentOwnedRequest:[self request:operationId] resolver:^(id result) {}
      rejecter:^(NSString *code, NSString *message, NSError *error) { XCTFail(@"unexpected %@", code); }];
  __block NSString *failure = nil;
  [self.module installEnvironmentOwnedRequest:[self request:operationId] resolver:^(id result) { XCTFail(@"reused operation resolved"); }
      rejecter:^(NSString *code, NSString *message, NSError *error) { failure = code; }];
  XCTAssertEqualObjects(failure, @"E_ENV_CONFLICT"); XCTAssertEqual(self.store.beginCount, 1u);
}
- (void)testOperationHistoryIsBoundedAndRejectsOverflow {
  for (NSUInteger index = 0; index < 256; index++) [self cancel:NSUUID.UUID.UUIDString.lowercaseString];
  __block NSString *failure = nil;
  [self.module installEnvironmentOwnedRequest:[self request:NSUUID.UUID.UUIDString.lowercaseString]
      resolver:^(id result) { XCTFail(@"overflow resolved"); }
      rejecter:^(NSString *code, NSString *message, NSError *error) { failure = code; }];
  XCTAssertEqualObjects(failure, @"E_ENV_LIMIT"); XCTAssertEqual(self.store.beginCount, 0u);
}
@end
