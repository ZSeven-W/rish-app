#import <XCTest/XCTest.h>
#import <CommonCrypto/CommonDigest.h>
#import "../../../../modules/rish/ios/Sources/AgentNativeWAL.h"
#import "../../../../modules/rish/ios/Sources/DSHAgentGuestCgiToolExecutor.h"
#import "../../../../modules/rish/ios/Sources/RishGuestCgiService.h"

@interface AgentCgiRecordingService : RishGuestCgiService
@property(nonatomic) NSUInteger starts;
@property(nonatomic) NSUInteger stops;
@property(nonatomic, copy) NSString *currentServiceId;
@property(nonatomic) BOOL stopping;
@end
@implementation AgentCgiRecordingService
- (void)start:(NSDictionary *)request resolve:(RishGuestCgiResolve)resolve reject:(RishGuestCgiReject)reject {
  self.starts++;
  self.currentServiceId = NSUUID.UUID.UUIDString.lowercaseString;
  resolve(@{ @"service_id": self.currentServiceId, @"url": @"http://127.0.0.1:12345/", @"status": @"running" });
}
- (void)stop:(NSString *)serviceId resolve:(RishGuestCgiResolve)resolve reject:(RishGuestCgiReject)reject {
  self.stops++; self.currentServiceId = nil; self.stopping = NO; resolve(@{ @"status": @"stopped" });
}
- (NSDictionary *)status {
  return self.currentServiceId ? @{ @"state": self.stopping ? @"stopping" : @"running", @"service_id": self.currentServiceId } : @{ @"state": @"idle" };
}
@end
static NSString *AgentCgiHash(NSData *data) {
  unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  NSMutableString *result = [NSMutableString string];
  for (NSUInteger i = 0; i < sizeof(digest); i++) [result appendFormat:@"%02x", digest[i]];
  return result;
}
@interface AgentGuestCgiAdapterTests : XCTestCase
@end
@implementation AgentGuestCgiAdapterTests
- (NSDictionary *)root { return @{ @"capabilities": @[ @"guest_service" ], @"root_fingerprint_sha256": [@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0] }; }
- (NSDictionary *)owner { return @{ @"conversation_id": @"22222222-2222-4222-8222-222222222222", @"attempt_id": @"33333333-3333-4333-8333-333333333333", @"round_id": @"44444444-4444-4444-8444-444444444444" }; }
- (NSDictionary *)args { NSString *hash = AgentCgiHash([@"hello" dataUsingEncoding:NSUTF8StringEncoding]); return @{ @"index_path": @"demo/index.html", @"index_sha256": hash, @"backend_path": @"demo/backend.sh", @"backend_sha256": hash, @"initial_data_path": NSNull.null, @"initial_data_sha256": NSNull.null }; }
- (DSHAgentGuestCgiToolExecutor *)adapter:(AgentCgiRecordingService *)service mismatched:(BOOL)mismatch {
 return [[DSHAgentGuestCgiToolExecutor alloc] initWithService:service fileReader:^(NSString *path, NSDictionary *root, NSUInteger max, void (^done)(NSData *, NSString *, NSError *)) { done([(mismatch ? @"changed" : @"hello") dataUsingEncoding:NSUTF8StringEncoding], @"r1", nil); }];
}
- (NSDictionary *)invokeTool:(NSString *)name args:(NSDictionary *)args adapter:(DSHAgentGuestCgiToolExecutor *)adapter error:(NSError **)error {
 __block NSDictionary *value = nil; __block NSError *failure = nil;
 XCTestExpectation *done = [self expectationWithDescription:@"adapter lifecycle operation"];
 NSDictionary *pre = [adapter prepareToolNamed:name arguments:args root:self.root error:nil];
 [adapter executeToolNamed:name arguments:args root:self.root owner:self.owner precondition:pre completion:^(NSDictionary *result, NSError *executionError) { value = result; failure = executionError; [done fulfill]; }];
 [self waitForExpectations:@[done] timeout:2];
 if (error) *error = failure;
 return value;
}
- (void)testExpiryAllowsExplicitRestartButStaleStopCannotStopReplacement {
 AgentCgiRecordingService *service = [AgentCgiRecordingService new];
 DSHAgentGuestCgiToolExecutor *adapter = [self adapter:service mismatched:NO];
 NSError *error = nil;
 NSDictionary *first = [self invokeTool:@"start_guest_cgi" args:self.args adapter:adapter error:&error];
 XCTAssertNil(error); XCTAssertEqual(service.starts, 1U);
 service.stopping = YES;
 XCTAssertNil([self invokeTool:@"start_guest_cgi" args:self.args adapter:adapter error:&error]);
 XCTAssertNotNil(error); XCTAssertEqual(service.starts, 1U);
 // The mechanism has now completed its own preview-expiry cleanup.
 service.currentServiceId = nil; service.stopping = NO;
 NSDictionary *replacement = [self invokeTool:@"start_guest_cgi" args:self.args adapter:adapter error:&error];
 XCTAssertNil(error); XCTAssertEqual(service.starts, 2U);
 XCTAssertNotEqualObjects(first[@"service_id"], replacement[@"service_id"]);
 XCTAssertNil([self invokeTool:@"stop_guest_cgi" args:@{ @"service_id": first[@"service_id"] } adapter:adapter error:&error]);
 XCTAssertNotNil(error); XCTAssertEqual(service.stops, 0U);
 XCTAssertEqualObjects(service.currentServiceId, replacement[@"service_id"]);
 NSDictionary *stopped = [self invokeTool:@"stop_guest_cgi" args:@{ @"service_id": replacement[@"service_id"] } adapter:adapter error:&error];
 XCTAssertNil(error); XCTAssertEqualObjects(stopped[@"status"], @"stopped"); XCTAssertEqual(service.stops, 1U);
}
- (void)testOwnerStopAfterExpiryReportsStoppedWithoutRepeatingMechanismStop {
 AgentCgiRecordingService *service = [AgentCgiRecordingService new];
 DSHAgentGuestCgiToolExecutor *adapter = [self adapter:service mismatched:NO];
 NSError *error = nil;
 NSDictionary *first = [self invokeTool:@"start_guest_cgi" args:self.args adapter:adapter error:&error];
 XCTAssertNil(error);
 service.currentServiceId = nil;
 NSDictionary *stopped = [self invokeTool:@"stop_guest_cgi" args:@{ @"service_id": first[@"service_id"] } adapter:adapter error:&error];
 XCTAssertNil(error); XCTAssertEqualObjects(stopped[@"status"], @"stopped"); XCTAssertEqual(service.stops, 0U);
 XCTAssertNotNil([self invokeTool:@"start_guest_cgi" args:self.args adapter:adapter error:&error]);
 XCTAssertNil(error); XCTAssertEqual(service.starts, 2U);
}

- (void)testCapabilityDeniedAndTamperedPreconditionNeverStart {
 AgentCgiRecordingService *service = [AgentCgiRecordingService new]; DSHAgentGuestCgiToolExecutor *adapter = [self adapter:service mismatched:NO];
 NSMutableDictionary *root = [self.root mutableCopy]; root[@"capabilities"] = @[];
 XCTAssertNil([adapter prepareToolNamed:@"start_guest_cgi" arguments:self.args root:root error:nil]);
 XCTestExpectation *done = [self expectationWithDescription:@"tampered"];
 [adapter executeToolNamed:@"start_guest_cgi" arguments:self.args root:self.root owner:self.owner precondition:@{} completion:^(NSDictionary *result, NSError *error) { XCTAssertNil(result); XCTAssertNotNil(error); [done fulfill]; }];
 [self waitForExpectations:@[done] timeout:2]; XCTAssertEqual(service.starts, 0U);
}
- (void)testDigestMismatchNeverStarts {
 AgentCgiRecordingService *service = [AgentCgiRecordingService new]; DSHAgentGuestCgiToolExecutor *adapter = [self adapter:service mismatched:YES];
 NSDictionary *args = [self args]; NSDictionary *prepared = [adapter prepareToolNamed:@"start_guest_cgi" arguments:args root:self.root error:nil];
 XCTestExpectation *done = [self expectationWithDescription:@"denied"];
 [adapter executeToolNamed:@"start_guest_cgi" arguments:args root:self.root owner:self.owner precondition:prepared completion:^(NSDictionary *result, NSError *error) { XCTAssertNil(result); XCTAssertNotNil(error); [done fulfill]; }];
 [self waitForExpectations:@[done] timeout:2]; XCTAssertEqual(service.starts, 0U);
}
- (void)testStartThenStopFromLaterAttemptAndRound {
 AgentCgiRecordingService *service = [AgentCgiRecordingService new]; DSHAgentGuestCgiToolExecutor *adapter = [self adapter:service mismatched:NO];
 NSDictionary *args = self.args; XCTestExpectation *done = [self expectationWithDescription:@"lifecycle"];
 [adapter executeToolNamed:@"start_guest_cgi" arguments:args root:self.root owner:self.owner precondition:[adapter prepareToolNamed:@"start_guest_cgi" arguments:args root:self.root error:nil] completion:^(NSDictionary *result, NSError *error) {
   XCTAssertNil(error); XCTAssertEqualObjects(result[@"status"], @"running");
   NSMutableDictionary *owner = [self.owner mutableCopy]; owner[@"attempt_id"] = @"55555555-5555-4555-8555-555555555555"; owner[@"round_id"] = @"66666666-6666-4666-8666-666666666666";
   NSDictionary *stop = @{ @"service_id": result[@"service_id"] };
   [adapter executeToolNamed:@"stop_guest_cgi" arguments:stop root:self.root owner:owner precondition:[adapter prepareToolNamed:@"stop_guest_cgi" arguments:stop root:self.root error:nil] completion:^(NSDictionary *stopped, NSError *stopError) { XCTAssertNil(stopError); XCTAssertEqualObjects(stopped[@"status"], @"stopped"); [done fulfill]; }];
 }];
 [self waitForExpectations:@[done] timeout:2]; XCTAssertEqual(service.starts, 1U); XCTAssertEqual(service.stops, 1U);
}
- (void)testFileFeedbackSHAIsOptionalAndCannotClaimTruncatedContent {
 NSString *hash = AgentCgiHash([@"proof" dataUsingEncoding:NSUTF8StringEncoding]);
 for (NSString *name in @[@"read_file", @"write_file"]) {
   NSMutableDictionary *payload = [@{ @"schema_version": @1, @"revision": @"r1" } mutableCopy];
   if ([name isEqual:@"read_file"]) { payload[@"content"] = @"proof"; payload[@"truncated"] = @NO; }
   else payload[@"bytes"] = @5;
   for (NSUInteger pass = 0; pass < 2; pass++) {
     if (pass) payload[@"sha256"] = hash;
     NSData *json = DSHAgentCanonicalJSON(@{ @"schema_version": @1, @"name": name, @"outcome": @"ok", @"payload": payload }, nil);
     XCTAssertTrue(DSHAgentValidateNativeToolFeedbackString([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding], nil));
   }
   if ([name isEqual:@"read_file"]) {
     payload[@"truncated"] = @YES;
     NSData *json = DSHAgentCanonicalJSON(@{ @"schema_version": @1, @"name": name, @"outcome": @"ok", @"payload": payload }, nil);
     XCTAssertFalse(DSHAgentValidateNativeToolFeedbackString([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding], nil));
   }
 }
}
- (void)testWALFeedbackAcceptsOnlyExactLoopbackResult {
 NSMutableDictionary *payload = [@{ @"schema_version": @1, @"status": @"running", @"service_id": @"11111111-1111-4111-8111-111111111111", @"url": @"http://127.0.0.1:12345/" } mutableCopy];
 for (NSString *url in @[@"http://127.0.0.1:12345/", @"http://example.com:12345/", @"http://user@127.0.0.1:12345/", @"http://127.0.0.1:12345/?secret=value"]) {
   payload[@"url"] = url;
   NSData *json = DSHAgentCanonicalJSON(@{ @"schema_version": @1, @"name": @"start_guest_cgi", @"outcome": @"ok", @"payload": payload }, nil);
   BOOL valid = DSHAgentValidateNativeToolFeedbackString([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding], nil);
   XCTAssertEqual(valid, [url isEqual:@"http://127.0.0.1:12345/"]);
 }
}
- (void)testCancelledAttemptNeverStarts {
 AgentCgiRecordingService *service = [AgentCgiRecordingService new]; DSHAgentGuestCgiToolExecutor *adapter = [self adapter:service mismatched:NO];
 [adapter cancelAttempt:self.owner[@"attempt_id"]];
 XCTestExpectation *done = [self expectationWithDescription:@"cancelled"];
 [adapter executeToolNamed:@"start_guest_cgi" arguments:self.args root:self.root owner:self.owner precondition:[adapter prepareToolNamed:@"start_guest_cgi" arguments:self.args root:self.root error:nil] completion:^(NSDictionary *result, NSError *error) { XCTAssertNil(result); XCTAssertNotNil(error); [done fulfill]; }];
 [self waitForExpectations:@[done] timeout:2]; XCTAssertEqual(service.starts, 0U);
}
- (void)testRestartDoesNotRecreateService {
 AgentCgiRecordingService *service = [AgentCgiRecordingService new]; DSHAgentGuestCgiToolExecutor *adapter = [self adapter:service mismatched:NO];
 NSDictionary *args = @{ @"service_id": @"11111111-1111-4111-8111-111111111111" }; XCTestExpectation *done = [self expectationWithDescription:@"unknown old service"];
 [adapter executeToolNamed:@"stop_guest_cgi" arguments:args root:self.root owner:self.owner precondition:[adapter prepareToolNamed:@"stop_guest_cgi" arguments:args root:self.root error:nil] completion:^(NSDictionary *result, NSError *error) { XCTAssertNil(result); XCTAssertNotNil(error); [done fulfill]; }];
 [self waitForExpectations:@[done] timeout:2]; XCTAssertEqual(service.starts, 0U); XCTAssertEqual(service.stops, 0U);
}
@end
