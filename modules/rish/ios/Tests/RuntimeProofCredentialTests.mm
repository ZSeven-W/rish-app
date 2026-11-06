#import <XCTest/XCTest.h>
#import <Security/Security.h>

@interface LocalRuntimeModule : NSObject
- (instancetype)initForCompletionV2TestingWithConfiguration:
    (NSURLSessionConfiguration *)configuration
    credential:(NSString *)credential
    uuidGenerator:(NSString *(^)(void))uuidGenerator
    monotonicClock:(NSTimeInterval (^)(void))monotonicClock;
- (void)bootstrapWithResolver:(void (^)(id result))resolve
                      rejecter:(void (^)(NSString *code, NSString *message,
                                         NSError *error))reject;
- (void)bootstrapForHarnessId:(NSString *)harnessId
                     resolver:(void (^)(id result))resolve
                      rejecter:(void (^)(NSString *code, NSString *message,
                                         NSError *error))reject;
@end

@interface DSHProofCredentialTestModule : LocalRuntimeModule
@property(nonatomic, copy) NSDictionary<NSString *, NSNumber *> *credentialStatuses;
@property(nonatomic, copy) NSString *testRoot;
@end

@implementation DSHProofCredentialTestModule

- (NSURL *)applicationSupportURL:(NSError **)error {
  (void)error;
  if (self.testRoot == nil) {
    self.testRoot = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:
            @"rish-runtime-proof-%@", NSUUID.UUID.UUIDString]];
  }
  NSURL *url = [NSURL fileURLWithPath:self.testRoot isDirectory:YES];
  [[NSFileManager defaultManager] createDirectoryAtURL:url
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:error];
  return url;
}

- (OSStatus)credentialLookupStatus {
  return [self credentialLookupStatusForAccount:@"DEEPSEEK_API_KEY"];
}

- (OSStatus)credentialLookupStatusForAccount:(NSString *)account {
  return [self.credentialStatuses[account] boolValue]
      ? errSecSuccess : errSecItemNotFound;
}

- (NSDictionary *)runRishProbe:(NSError **)error {
  (void)error;
  return @{
    @"protocol_version": @1,
    @"path": @"portable_applet",
    @"program": @"sha256sum",
    @"exit_code": @0,
  };
}

@end

@interface RuntimeProofCredentialTests : XCTestCase
@end

@implementation RuntimeProofCredentialTests

- (DSHProofCredentialTestModule *)moduleWithStatuses:(NSDictionary *)statuses {
  DSHProofCredentialTestModule *module =
      [[DSHProofCredentialTestModule alloc]
          initForCompletionV2TestingWithConfiguration:
              [NSURLSessionConfiguration ephemeralSessionConfiguration]
          credential:nil
          uuidGenerator:nil
          monotonicClock:nil];
  module.credentialStatuses = statuses;
  return module;
}

- (NSDictionary *)bootstrapHarness:(NSString *)harness
                            module:(DSHProofCredentialTestModule *)module
                              code:(NSString **)code {
  __block NSDictionary *result = nil;
  __block NSString *rejection = nil;
  dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
  [module bootstrapForHarnessId:harness
                        resolver:^(id value) {
                          result = [value isKindOfClass:NSDictionary.class]
                              ? value : nil;
                          dispatch_semaphore_signal(semaphore);
                        }
                        rejecter:^(NSString *rejectCode, NSString *message,
                                   NSError *error) {
                          (void)message;
                          (void)error;
                          rejection = rejectCode;
                          dispatch_semaphore_signal(semaphore);
                        }];
  XCTAssertEqual(dispatch_semaphore_wait(
                     semaphore,
                     dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)), 0);
  if (code != NULL) *code = rejection;
  return result;
}

- (void)testGlmOnlyBootstrapChecksBigModelSlot {
  DSHProofCredentialTestModule *module =
      [self moduleWithStatuses:@{@"BIGMODEL_API_KEY": @YES}];
  NSString *code = nil;
  NSDictionary *result = [self bootstrapHarness:@"glm" module:module code:&code];
  XCTAssertNil(code);
  XCTAssertEqualObjects(result[@"proof"][@"active_harness"], @"glm");
  XCTAssertEqualObjects(result[@"proof"][@"checks"][@"credential_in_keychain"], @YES);

  code = nil;
  XCTAssertNil([self bootstrapHarness:@"dsh" module:module code:&code]);
  XCTAssertEqualObjects(code, @"credential");
}

- (void)testDshOnlyBootstrapDoesNotVerifyGlm {
  DSHProofCredentialTestModule *module =
      [self moduleWithStatuses:@{@"DEEPSEEK_API_KEY": @YES}];
  NSString *code = nil;
  NSDictionary *result = [self bootstrapHarness:@"dsh" module:module code:&code];
  XCTAssertNil(code);
  XCTAssertEqualObjects(result[@"proof"][@"active_harness"], @"dsh");

  code = nil;
  XCTAssertNil([self bootstrapHarness:@"glm" module:module code:&code]);
  XCTAssertEqualObjects(code, @"credential");
}

- (void)testSwitchingHarnessDropsPreviousModelEvidence {
  DSHProofCredentialTestModule *module =
      [self moduleWithStatuses:@{@"DEEPSEEK_API_KEY": @YES,
                                 @"BIGMODEL_API_KEY": @YES}];
  NSError *error = nil;
  NSURL *root = [module applicationSupportURL:&error];
  XCTAssertNil(error);
  NSDictionary *oldProof = @{
    @"schema_version": @2,
    @"active_harness": @"dsh",
    @"model_response": @{
      @"harness_id": @"dsh",
      @"launch_instance_id": @"old-launch",
    },
    @"session_persisted": @{@"writer_launch_instance_id": @"old-launch"},
    @"session_restore": @{@"restore_launch_instance_id": @"old-launch"},
  };
  NSData *data = [NSJSONSerialization dataWithJSONObject:oldProof options:0 error:&error];
  XCTAssertNil(error);
  XCTAssertTrue([data writeToURL:[root URLByAppendingPathComponent:@"runtime-proof.json"]
                         options:NSDataWritingAtomic error:&error]);

  NSString *code = nil;
  NSDictionary *result = [self bootstrapHarness:@"glm" module:module code:&code];
  XCTAssertNil(code);
  NSDictionary *proof = result[@"proof"];
  XCTAssertEqualObjects(proof[@"active_harness"], @"glm");
  XCTAssertEqualObjects(proof[@"checks"][@"model_response_received"], @NO);
  XCTAssertNil(proof[@"model_response"]);
  XCTAssertNil(proof[@"session_persisted"]);
  XCTAssertNil(proof[@"session_restore"]);
}

- (void)testLegacyGlmResponseWithoutHarnessDoesNotPassAsDsh {
  DSHProofCredentialTestModule *module =
      [self moduleWithStatuses:@{@"DEEPSEEK_API_KEY": @YES}];
  NSError *error = nil;
  NSURL *root = [module applicationSupportURL:&error];
  XCTAssertNil(error);
  NSDictionary *oldProof = @{
    @"schema_version": @2,
    @"active_harness": @"dsh",
    @"model_response": @{
      @"model": @"GLM-5.3",
      @"launch_instance_id": @"old-launch",
    },
  };
  NSData *data = [NSJSONSerialization dataWithJSONObject:oldProof options:0 error:&error];
  XCTAssertNil(error);
  XCTAssertTrue([data writeToURL:[root URLByAppendingPathComponent:@"runtime-proof.json"]
                         options:NSDataWritingAtomic error:&error]);

  NSString *code = nil;
  NSDictionary *result = [self bootstrapHarness:@"dsh" module:module code:&code];
  XCTAssertNil(code);
  XCTAssertEqualObjects(result[@"proof"][@"active_harness"], @"dsh");
  XCTAssertEqualObjects(result[@"proof"][@"checks"][@"model_response_received"], @NO);
  XCTAssertNil(result[@"proof"][@"model_response"]);
}

@end
