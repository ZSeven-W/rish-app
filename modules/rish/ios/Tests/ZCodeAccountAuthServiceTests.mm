#import <XCTest/XCTest.h>
#import "ZCodeAccountAuthService.h"

static NSString *ZCodeTestURL(NSString *provider) {
  return [provider isEqual:@"bigmodel"]
    ? @"https://bigmodel.cn/login?appId=test&redirect=https%3A%2F%2Fzcode.z.ai%2Fapi%2Fv1%2Foauth%2Fcli%2Fcallback%2Fbigmodel&state=test-state"
    : @"https://chat.z.ai/api/oauth/authorize?client_id=test&redirect_uri=https%3A%2F%2Fzcode.z.ai%2Fapi%2Fv1%2Foauth%2Fcli%2Fcallback%2Fzai&response_type=code&state=test-state";
}
@interface ZCodeAuthFixture : NSObject
@property(nonatomic, strong) RishZCodeAccountAuthService *service;
@property(nonatomic, strong) NSMutableArray<NSURLRequest *> *requests;
@property(nonatomic, strong) NSMutableArray *callbacks;
@property(nonatomic, strong) NSMutableDictionary *storage;
@property(nonatomic) NSUInteger writes;
@property(nonatomic) NSTimeInterval now;
- (void)reply:(NSUInteger)index data:(NSDictionary *)data;
@end
@implementation ZCodeAuthFixture
- (instancetype)init {
  if ((self = [super init])) {
    _requests = [NSMutableArray array]; _callbacks = [NSMutableArray array]; _storage = [NSMutableDictionary dictionary]; _now = 1000;
    __weak ZCodeAuthFixture *weakSelf = self;
    _service = [[RishZCodeAccountAuthService alloc] initWithRequest:^NSURLSessionDataTask *(NSURLRequest *request, void (^done)(NSHTTPURLResponse *, NSData *, NSError *)) {
      @synchronized(weakSelf) { [weakSelf.requests addObject:request]; [weakSelf.callbacks addObject:[done copy]]; } return nil;
    } read:^NSData *(NSString *provider, NSError **error) { @synchronized(weakSelf) { return weakSelf.storage[provider]; } }
      write:^BOOL(NSString *provider, NSData *data, NSError **error) { @synchronized(weakSelf) { weakSelf.writes++; if (data) weakSelf.storage[provider] = data; else [weakSelf.storage removeObjectForKey:provider]; } return YES; }
      clock:^NSTimeInterval { return weakSelf.now; }];
  }
  return self;
}
- (void)reply:(NSUInteger)index data:(NSDictionary *)data {
  void (^done)(NSHTTPURLResponse *, NSData *, NSError *) = self.callbacks[index];
  NSURL *url = self.requests[index].URL;
  done([[NSHTTPURLResponse alloc] initWithURL:url statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{}], [NSJSONSerialization dataWithJSONObject:@{ @"code": @0, @"data": data } options:0 error:nil], nil);
}
@end

@interface ZCodeAccountAuthServiceTests : XCTestCase
@end
@implementation ZCodeAccountAuthServiceTests
- (void)waitFor:(BOOL (^)(void))condition {
  NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(id value, NSDictionary *bindings) { return condition(); }];
  XCTNSPredicateExpectation *expectation = [[XCTNSPredicateExpectation alloc] initWithPredicate:predicate object:nil];
  XCTAssertEqual([XCTWaiter waitForExpectations:@[expectation] timeout:4], XCTWaiterResultCompleted);
}
- (void)initialize:(ZCodeAuthFixture *)fixture provider:(NSString *)provider {
  XCTestExpectation *started = [self expectationWithDescription:@"explicit init"];
  [fixture.service startForProvider:provider completion:^(NSDictionary *status) { XCTAssertEqualObjects(status[@"status"], @"pending"); [started fulfill]; }];
  [self waitFor:^{ return fixture.requests.count == 1; }];
  NSString *bearer = [fixture.requests[0] valueForHTTPHeaderField:@"Authorization"];
  XCTAssertEqual(bearer.length, 71U);
  XCTAssertTrue([[fixture.requests[0] valueForHTTPHeaderField:@"User-Agent"] hasPrefix:@"Rish/"]);
  [fixture reply:0 data:@{ @"flow_id": @"test-flow", @"authorize_url": ZCodeTestURL(provider), @"expires_at": @1200, @"poll_interval_sec": @1, @"poll_token": [bearer substringFromIndex:7] }];
  [self waitForExpectations:@[started] timeout:2];
}
- (NSDictionary *)readyFor:(NSString *)provider {
  return @{ @"status": @"ready", @"token": @"synthetic-zcode-token", @"user": @{ @"user_id": @"test-user", @"name": @"Test Account" }, provider: @{ @"access_token": @"synthetic-provider-token", @"refresh_token": @"synthetic-refresh-token" } };
}
- (void)testStatusDoesNotStartNetworkAndURLValidationIsExact {
  ZCodeAuthFixture *fixture = [ZCodeAuthFixture new];
  XCTAssertEqualObjects([fixture.service statusForProvider:@"bigmodel"][@"status"], @"signed_out");
  XCTAssertEqual(fixture.requests.count, 0U);
  for (NSString *provider in @[@"bigmodel", @"zai"]) {
    NSString *url = ZCodeTestURL(provider);
    XCTAssertTrue([RishZCodeAccountAuthService isSafeAuthorizeURL:url provider:provider]);
    for (NSString *invalid in @[[url stringByAppendingString:@"&state=duplicate"], [url stringByAppendingString:@"#fragment"], [url stringByReplacingOccurrencesOfString:@"https://" withString:@"http://"], [url stringByReplacingOccurrencesOfString:@"zcode.z.ai" withString:@"untrusted.invalid"], [url stringByReplacingOccurrencesOfString:@"https://" withString:@"https://user@"]]) {
      XCTAssertFalse([RishZCodeAccountAuthService isSafeAuthorizeURL:invalid provider:provider]);
    }
  }
}
- (void)testExplicitInitPollReadyPersistsOnlyNativeCredentials {
  ZCodeAuthFixture *fixture = [ZCodeAuthFixture new]; [self initialize:fixture provider:@"bigmodel"];
  XCTestExpectation *connected = [self expectationWithDescription:@"native browser completion signal"];
  fixture.service.onAccountConnected = ^(NSString *provider) {
    XCTAssertEqualObjects(provider, @"bigmodel"); [connected fulfill];
  };
  [self waitFor:^{ return fixture.requests.count == 2; }];
  XCTAssertTrue([[fixture.requests[1] valueForHTTPHeaderField:@"Authorization"] isEqual:[fixture.requests[0] valueForHTTPHeaderField:@"Authorization"]]);
  XCTAssertEqualObjects(fixture.requests[1].HTTPMethod, @"GET");
  [fixture reply:1 data:[self readyFor:@"bigmodel"]];
  [self waitFor:^{ return [[fixture.service statusForProvider:@"bigmodel"][@"status"] isEqual:@"signed_in"]; }];
  NSDictionary *status = [fixture.service statusForProvider:@"bigmodel"];
  XCTAssertEqual(status.count, 8U); XCTAssertEqualObjects(status[@"mode"], @"account_only");
  NSString *json = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:status options:0 error:nil] encoding:NSUTF8StringEncoding];
  XCTAssertFalse([json containsString:@"synthetic-"]); XCTAssertFalse([json containsString:@"test-flow"]);
  XCTAssertEqual(fixture.writes, 1U);
  [self waitForExpectations:@[connected] timeout:2];
}
- (void)testLogoutRemovesOnlyTheChosenAccount {
  ZCodeAuthFixture *fixture = [ZCodeAuthFixture new];
  NSDictionary *credential = @{@"schema_version":@1, @"provider":@"bigmodel",
    @"zcode_token":@"synthetic-zcode", @"provider_access_token":@"synthetic-access",
    @"account_label":@"Test Account"};
  fixture.storage[@"bigmodel"] = [NSJSONSerialization dataWithJSONObject:credential options:0 error:nil];
  fixture.storage[@"manual-key"] = [@"keep-manual" dataUsingEncoding:NSUTF8StringEncoding];
  XCTAssertEqualObjects([fixture.service statusForProvider:@"bigmodel"][@"status"], @"signed_in");
  XCTestExpectation *done = [self expectationWithDescription:@"logout"];
  [fixture.service logoutForProvider:@"bigmodel" completion:^(NSDictionary *status) {
    XCTAssertEqualObjects(status[@"status"], @"signed_out"); [done fulfill];
  }];
  [self waitForExpectations:@[done] timeout:2];
  XCTAssertNil(fixture.storage[@"bigmodel"]);
  XCTAssertNotNil(fixture.storage[@"manual-key"]);
  XCTAssertEqual(fixture.requests.count, 0U);
}

- (void)testReloginExistingAccountHasNullModeWhilePending {
  ZCodeAuthFixture *fixture = [ZCodeAuthFixture new];
  fixture.storage[@"bigmodel"] = [NSJSONSerialization dataWithJSONObject:@{ @"schema_version": @1, @"provider": @"bigmodel", @"zcode_token": @"synthetic-old-zcode", @"provider_access_token": @"synthetic-old-access", @"account_label": @"Old Account" } options:0 error:nil];
  XCTAssertEqualObjects([fixture.service statusForProvider:@"bigmodel"][@"status"], @"signed_in");
  [self initialize:fixture provider:@"bigmodel"];
  NSDictionary *pending = [fixture.service statusForProvider:@"bigmodel"];
  XCTAssertEqualObjects(pending[@"status"], @"pending"); XCTAssertEqualObjects(pending[@"mode"], NSNull.null);
  XCTestExpectation *cancelled = [self expectationWithDescription:@"cancel reauth"];
  [fixture.service cancelForProvider:@"bigmodel" completion:^(NSDictionary *status) { XCTAssertEqualObjects(status[@"status"], @"signed_in"); [cancelled fulfill]; }];
  [self waitForExpectations:@[cancelled] timeout:2];
}
- (void)testCancelBeforeReadyPreventsLateCredentialPersistence {
  ZCodeAuthFixture *fixture = [ZCodeAuthFixture new]; [self initialize:fixture provider:@"zai"];
  [self waitFor:^{ return fixture.requests.count == 2; }];
  XCTestExpectation *cancelled = [self expectationWithDescription:@"cancelled"];
  [fixture.service cancelForProvider:@"zai" completion:^(NSDictionary *status) { XCTAssertEqualObjects(status[@"status"], @"signed_out"); [cancelled fulfill]; }];
  [self waitForExpectations:@[cancelled] timeout:2];
  [fixture reply:1 data:[self readyFor:@"zai"]];
  XCTAssertEqualObjects([fixture.service statusForProvider:@"zai"][@"status"], @"signed_out"); XCTAssertEqual(fixture.writes, 0U);
}
- (void)testExpiryDoesNotRefreshOrPollAndUnsafeInitDoesNotPersist {
  ZCodeAuthFixture *fixture = [ZCodeAuthFixture new]; [self initialize:fixture provider:@"bigmodel"];
  fixture.now = 1201;
  XCTAssertEqualObjects([fixture.service statusForProvider:@"bigmodel"][@"status"], @"expired");
  XCTAssertEqual(fixture.requests.count, 1U); XCTAssertEqual(fixture.writes, 0U);
}
@end
