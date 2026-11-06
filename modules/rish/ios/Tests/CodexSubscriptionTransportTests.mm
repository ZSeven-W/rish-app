#import <XCTest/XCTest.h>

#import "../../../../modules/rish/ios/Sources/CodexSubscriptionTransport.h"

@interface SubscriptionFixtureAuth : DSHHarnessAuthService
@property(nonatomic, copy) NSDictionary *record;
@end
@implementation SubscriptionFixtureAuth
- (NSDictionary *)codexChatCredential { return self.record; }
@end

@interface CodexSubscriptionTransportTests : XCTestCase
@property(nonatomic, strong) CodexSubscriptionTransport *transport;
@end

@implementation CodexSubscriptionTransportTests

- (void)setUp {
  [super setUp];
  NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
  NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
  self.transport = [[CodexSubscriptionTransport alloc] initWithSession:session
                                                          uuidGenerator:nil
                                                         monotonicClock:nil];
  SubscriptionFixtureAuth *auth = [[SubscriptionFixtureAuth alloc] initWithBundle:NSBundle.mainBundle];
  auth.record = @{@"access_token":@"token", @"account_id":@"account-a"};
  self.transport.accountAuth = auth;
}

- (void)testAccountHeadersCannotReusePreviousIdentity {
  XCTAssertEqualObjects([self.transport providerHeadersWithCredential:@"token"][@"ChatGPT-Account-ID"], @"account-a");
  SubscriptionFixtureAuth *auth = (id)self.transport.accountAuth;
  auth.record = @{@"access_token":@"next-token", @"account_id":@"account-b"};
  XCTAssertEqual([self.transport providerHeadersWithCredential:@"token"].count, (NSUInteger)0);
  XCTAssertEqualObjects([self.transport providerHeadersWithCredential:@"next-token"][@"ChatGPT-Account-ID"], @"account-b");
}

- (void)testSubscriptionWireShapeAndIdentity {
  NSError *error = nil;
  NSDictionary *body = [self.transport providerRequestBodyForModel:@"gpt-5.6"
                                                         thinkingMode:@"off"
                                                             messages:@[@{ @"role": @"user", @"content": @"hello" }]
                                                                tools:@[] streaming:NO error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects([self.transport providerBaseURL].absoluteString,
                        @"https://chatgpt.com/backend-api/codex/responses");
  XCTAssertEqualObjects(body[@"stream"], @YES);
  XCTAssertEqualObjects(body[@"store"], @NO);
  XCTAssertEqualObjects(body[@"instructions"], @"");
  XCTAssertNil(body[@"max_output_tokens"]);
  XCTAssertEqualObjects(body[@"input"][0][@"content"][0][@"text"], @"hello");
  XCTAssertEqualObjects([self.transport providerHeadersWithCredential:@"token"][@"Authorization"],
                        @"Bearer token");
  XCTAssertEqualObjects([self.transport providerHeadersWithCredential:@"token"][@"Accept"],
                        @"text/event-stream");
  XCTAssertEqualObjects([self.transport providerHeadersWithCredential:@"token"][@"User-Agent"], @"Rish");
  XCTAssertEqualObjects([self.transport providerHeadersWithCredential:@"token"][@"originator"], @"rish");
}

- (void)testBuffersSSEUntilCompletedThenParsesTextAndToolCalls {
  NSString *sse = @"event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"ignored\"}\n\n"
                   "event: response.output_item.added\ndata: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"function_call\"}}\n\n"
                   "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"r1\",\"object\":\"response\",\"status\":\"completed\",\"model\":\"gpt-5.6\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]},{\"type\":\"function_call\",\"call_id\":\"c1\",\"name\":\"write_file\",\"arguments\":\"{}\"}]}}\n\n";
  NSError *error = nil;
  NSDictionary *result = [self.transport providerParseResponseData:[sse dataUsingEncoding:NSUTF8StringEncoding]
                                                     requestedModel:@"gpt-5.6" thinkingMode:@"off" error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"text"], @"done");
  XCTAssertEqualObjects(result[@"finish_reason"], @"tool_calls");
  XCTAssertEqualObjects(result[@"tool_calls"][0][@"id"], @"c1");
}

- (void)testRejectsMalformedOrIncompleteSSEAndNoAuthRecord {
  NSError *error = nil;
  XCTAssertNil([self.transport providerParseResponseData:[@"data: {bad}\n\n" dataUsingEncoding:NSUTF8StringEncoding]
                                           requestedModel:@"gpt-5.6" thinkingMode:@"off" error:&error]);
  XCTAssertNotNil(error);
  error = nil;
  XCTAssertNil([self.transport providerParseResponseData:[@"event: response.output_text.delta\ndata: {}\n\n" dataUsingEncoding:NSUTF8StringEncoding]
                                           requestedModel:@"gpt-5.6" thinkingMode:@"off" error:&error]);
  XCTAssertNotNil(error);
}

- (void)testMergesOutputItemDoneWhenCompletedEnvelopeHasNoOutput {
  NSString *sse = @"event: response.output_item.done\ndata: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"id\":\"m1\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}}\n\n"
                   "event: response.output_item.done\ndata: {\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{\"id\":\"f1\",\"type\":\"function_call\",\"call_id\":\"c1\",\"name\":\"write_file\",\"arguments\":\"{}\"}}\n\n"
                   "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"r2\",\"object\":\"response\",\"status\":\"completed\",\"model\":\"gpt-5.6\",\"output\":[]}}\n\n";
  NSError *error = nil;
  NSDictionary *result = [self.transport providerParseResponseData:[sse dataUsingEncoding:NSUTF8StringEncoding]
                                                     requestedModel:@"gpt-5.6" thinkingMode:@"off" error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"text"], @"done");
  XCTAssertEqualObjects(result[@"tool_calls"][0][@"id"], @"c1");
}

@end
