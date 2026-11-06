#import <XCTest/XCTest.h>

#import "ZCodeAccountAuthService.h"
#import "ZCodePlanResolver.h"
#import "ClaudeProviderTransport.h"

@interface ZCodePlanFakeAuth : RishZCodeAccountAuthService
@property(nonatomic, copy) NSDictionary *credential;
@end
@implementation ZCodePlanFakeAuth
- (NSDictionary *)nativeCredentialForProvider:(NSString *)provider error:(NSError **)error {
  (void)provider; (void)error; return self.credential;
}
@end

@interface ZCodeFakeSelection : RishGlmCredentialSelection
@property(nonatomic, copy) NSDictionary *value;
@end
@implementation ZCodeFakeSelection
- (NSDictionary *)read { return self.value ?: @{@"schema_version":@1, @"source":@"api_key"}; }
- (BOOL)write:(NSDictionary *)value error:(NSError **)error { self.value = value; return YES; }
@end

static NSDictionary *ZCodePlanJSONResponse(NSDictionary *json) {
  return @{ @"response" : [NSHTTPURLResponse.alloc initWithURL:[NSURL URLWithString:@"https://test.invalid"] statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:nil],
            @"data" : [NSJSONSerialization dataWithJSONObject:json options:0 error:nil] };
}

@interface ZCodePlanResolverTests : XCTestCase
@end

@implementation ZCodePlanResolverTests

- (void)testSubscriptionSelectionIsBoundToAccountAndNeverFallsBack {
  ZCodeFakeSelection *selection = [ZCodeFakeSelection new];
  ZCodePlanFakeAuth *auth = [ZCodePlanFakeAuth new];
  auth.credential = @{@"provider":@"bigmodel", @"user_id":@"first-account"};
  XCTAssertEqualObjects(selection.source, @"api_key");
  XCTAssertTrue([selection selectProviderPending:@"bigmodel" error:nil]);
  XCTAssertNil([selection credentialWithAccountAuth:auth]);
  XCTAssertEqualObjects(selection.source, @"bigmodel");
  NSDictionary *plan = @{@"provider":@"bigmodel", @"credential":@"fixture.secret"};
  XCTAssertTrue([selection selectPlan:plan account:auth.credential error:nil]);
  XCTAssertEqualObjects([selection credentialWithAccountAuth:auth], @"fixture.secret");
  auth.credential = @{@"provider":@"bigmodel", @"user_id":@"other-account"};
  XCTAssertNil([selection credentialWithAccountAuth:auth]);
  [selection clearCredentialForProvider:@"bigmodel"];
  XCTAssertEqualObjects(selection.source, @"bigmodel");
  XCTAssertNil(selection.value[@"credential"]);
  XCTAssertTrue([selection selectAPIKey:nil]);
  XCTAssertEqualObjects(selection.source, @"api_key");
}

- (void)testExpiredVerificationBlocksSubscriptionCredential {
  ZCodeFakeSelection *selection = [ZCodeFakeSelection new];
  selection.value = @{@"schema_version":@1, @"source":@"zai", @"credential":@"fixture.secret",
    @"account_id":@"account", @"verified_until":@1};
  ZCodePlanFakeAuth *auth = [ZCodePlanFakeAuth new];
  auth.credential = @{@"provider":@"zai", @"user_id":@"account"};
  XCTAssertNil([selection credentialWithAccountAuth:auth]);
  XCTAssertEqualObjects(selection.source, @"zai");
}

- (void)testTrialSelectionIsAccountBoundAndKeepsAllowedModels {
  ZCodeFakeSelection *selection = [ZCodeFakeSelection new];
  ZCodePlanFakeAuth *auth = [ZCodePlanFakeAuth new];
  auth.credential = @{ @"provider": @"bigmodel", @"user_id": @"trial-user" };
  XCTAssertTrue([selection selectTrialPending:@"bigmodel" error:nil]);
  NSDictionary *plan = @{ @"provider": @"bigmodel", @"credential": @"jwt",
    @"credential_source": @"trial", @"allowed_models": @[ @"GLM-5.3" ] };
  XCTAssertTrue([selection selectPlan:plan account:auth.credential error:nil]);
  XCTAssertEqualObjects(selection.source, @"bigmodel_trial");
  XCTAssertEqualObjects(selection.allowedModels, (@[ @"GLM-5.3" ]));
  XCTAssertEqualObjects([selection credentialWithAccountAuth:auth], @"jwt");
  auth.credential = @{ @"provider": @"bigmodel", @"user_id": @"other" };
  XCTAssertNil([selection credentialWithAccountAuth:auth]);
}

- (void)testTrialResolverAcceptsLinkedBalancesAndProjectsSafeStatus {
  ZCodePlanFakeAuth *auth = [ZCodePlanFakeAuth new];
  auth.credential = @{ @"provider": @"bigmodel", @"user_id": @"trial-user", @"zcode_token": @"jwt" };
  RishZCodePlanRequest request = ^NSURLSessionDataTask *(NSURLRequest *req, void (^done)(NSHTTPURLResponse *, NSData *, NSError *)) {
    XCTAssertEqualObjects(req.URL.path, @"/api/v1/zcode-plan/billing/balance");
    NSDictionary *json = @{ @"code": @0, @"data": @{
      @"plans": @[ @{ @"plan_id": @"expired-start-plan", @"status": @"active", @"expires_at": @900 }, @{ @"plan_id": @"start-plan", @"name": @"Start Plan", @"status": @"active", @"expires_at": @1700 } ],
      @"balances": @[
        @{ @"plan_id": @"other", @"remaining_units": @99 },
        @{ @"plan_id": @"start-plan", @"remaining_units": @3, @"expires_at": @1800,
           @"capabilities": @[ @"model:GLM-5.3", @"model:GLM-5.3-Flash" ] }
      ]
    }};
    NSDictionary *reply = ZCodePlanJSONResponse(json); done(reply[@"response"], reply[@"data"], nil); return nil;
  };
  RishZCodePlanResolver *resolver = [[RishZCodePlanResolver alloc] initWithAccountAuth:auth request:request clock:^NSTimeInterval { return 1000; }];
  XCTestExpectation *done = [self expectationWithDescription:@"trial positive"];
  [resolver resolveTrialForProvider:@"bigmodel" completion:^(NSDictionary *result, NSError *error) {
    XCTAssertNil(error); XCTAssertEqualObjects(result[@"credential"], @"jwt");
    XCTAssertEqualObjects(result[@"endpoint_url"], @"https://zcode.z.ai/api/v1/zcode-plan/anthropic");
    XCTAssertEqualObjects(result[@"allowed_models"], (@[ @"glm-5.3", @"glm-5.3-flash" ]));
    XCTAssertEqualObjects(result[@"expires_at"], @1700);
    [done fulfill];
  }];
  [self waitForExpectations:@[done] timeout:2];
  XCTAssertNil([resolver statusForProvider:@"bigmodel"][@"credential"]);
  XCTAssertEqualObjects([resolver statusForProvider:@"bigmodel"][@"credential_source"], @"trial");
}

- (void)testTrialResolverRejectsMalformedEmptyExpiredZeroAndMismatchedBalances {
  NSArray *fixtures = @[
    @{ @"plans": NSNull.null, @"balances": @"malformed" },
    @{ @"plans": @[], @"balances": @[] },
    @{ @"plans": @[ @{ @"plan_id": @"start-plan", @"status": @"active" } ], @"balances": @[ @{ @"plan_id": @"start-plan", @"remaining_units": @0 } ] },
    @{ @"plans": @[ @{ @"plan_id": @"start-plan", @"status": @"active" } ], @"balances": @[ @{ @"plan_id": @"start-plan", @"remaining_units": @2, @"expires_at": @900 } ] },
    @{ @"plans": @[ @{ @"plan_id": @"other", @"status": @"active" } ], @"balances": @[ @{ @"plan_id": @"start-plan", @"remaining_units": @2 } ] }
  ];
  NSMutableArray *expanded = [fixtures mutableCopy];
  for (id units in @[@0, @YES, @"2junk", @"NaN", NSNull.null])
    [expanded addObject:@{@"plans":@[@{@"plan_id":@"start-plan", @"status":@"active"}],
      @"balances":@[@{@"plan_id":@"start-plan", @"remaining_units":units, @"capabilities":@[@"model:GLM-5.3"]}]}];
  for (NSDictionary *fixture in expanded) {
    ZCodePlanFakeAuth *auth = [ZCodePlanFakeAuth new];
    auth.credential = @{ @"provider": @"bigmodel", @"user_id": @"trial-user", @"zcode_token": @"jwt" };
    RishZCodePlanRequest request = ^NSURLSessionDataTask *(NSURLRequest *req, void (^done)(NSHTTPURLResponse *, NSData *, NSError *)) {
      NSDictionary *reply = ZCodePlanJSONResponse(@{ @"code": @0, @"data": fixture }); done(reply[@"response"], reply[@"data"], nil); return nil;
    };
    RishZCodePlanResolver *resolver = [[RishZCodePlanResolver alloc] initWithAccountAuth:auth request:request clock:^NSTimeInterval { return 1000; }];
    XCTestExpectation *done = [self expectationWithDescription:@"trial rejected"];
    [resolver resolveTrialForProvider:@"bigmodel" completion:^(NSDictionary *result, NSError *error) {
      XCTAssertNil(result); XCTAssertEqualObjects(error.localizedDescription, @"E_ZCODE_TRIAL_UNAVAILABLE"); [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:2];
  }
}

- (void)testTrialResolverRejectsAccountChangeDuringBalanceLookup {
  ZCodePlanFakeAuth *auth = [ZCodePlanFakeAuth new];
  auth.credential = @{ @"provider": @"bigmodel", @"user_id": @"first", @"zcode_token": @"jwt" };
  RishZCodePlanRequest request = ^NSURLSessionDataTask *(NSURLRequest *req, void (^done)(NSHTTPURLResponse *, NSData *, NSError *)) {
    auth.credential = @{ @"provider": @"bigmodel", @"user_id": @"second", @"zcode_token": @"other" };
    NSDictionary *reply = ZCodePlanJSONResponse(@{ @"code": @0, @"data": @{
      @"plans": @[ @{ @"plan_id": @"start-plan", @"status": @"active" } ],
      @"balances": @[ @{ @"plan_id": @"start-plan", @"remaining_units": @2, @"capabilities": @[ @"model:GLM-5.3" ] } ]
    }}); done(reply[@"response"], reply[@"data"], nil); return nil;
  };
  RishZCodePlanResolver *resolver = [[RishZCodePlanResolver alloc] initWithAccountAuth:auth request:request clock:^NSTimeInterval { return 1000; }];
  XCTestExpectation *done = [self expectationWithDescription:@"trial account race"];
  [resolver resolveTrialForProvider:@"bigmodel" completion:^(NSDictionary *result, NSError *error) {
    XCTAssertNil(result); XCTAssertEqualObjects(error.localizedDescription, @"E_ZCODE_PLAN_ACCOUNT_CHANGED"); [done fulfill];
  }];
  [self waitForExpectations:@[done] timeout:2];
}

- (void)testBigModelExistingCodingPlanKeyIsResolvedWithoutCreating {
  ZCodePlanFakeAuth *auth = [ZCodePlanFakeAuth new];
  auth.credential = @{ @"schema_version": @1, @"provider": @"bigmodel", @"zcode_token": @"business", @"provider_access_token": @"oauth", @"provider_refresh_token": NSNull.null, @"user_id": @"user", @"account_label": @"test" };
  NSMutableArray<NSURLRequest *> *requests = [NSMutableArray array];
  RishZCodePlanRequest request = ^NSURLSessionDataTask *(NSURLRequest *urlRequest, void (^done)(NSHTTPURLResponse *, NSData *, NSError *)) {
    [requests addObject:urlRequest];
    NSString *path = urlRequest.URL.path;
    NSDictionary *json = [path hasSuffix:@"getCustomerInfo"] ? @{ @"code": @0, @"data": @{ @"organizations": @[@{ @"organizationId": @"org-default", @"isDefault": @YES, @"projects": @[@{ @"projectId": @"team", @"projectType": @"2" }, @{ @"projectId": @"project-default", @"isDefault": @YES }] }] } } :
      ([path hasSuffix:@"/api_keys"] ? @{ @"code": @0, @"data": @[@{ @"name": @"zcode-api-key", @"apiKey": @"key-id" }] } :
       ([path hasSuffix:@"/copy/key-id"] ? @{ @"code": @0, @"data": @{ @"secretKey": @"resolved-secret" } } :
        @{ @"code": @0, @"success": @YES, @"data": @[@{ @"productName": @"Coding Plan", @"status": @"VALID", @"inCurrentPeriod": @YES }] }));
    NSDictionary *reply = ZCodePlanJSONResponse(json); done(reply[@"response"], reply[@"data"], nil); return nil;
  };
  RishZCodePlanResolver *resolver = [[RishZCodePlanResolver alloc] initWithAccountAuth:auth request:request clock:^NSTimeInterval { return 1000; }];
  XCTestExpectation *expectation = [self expectationWithDescription:@"resolve bigmodel plan"];
  __block NSDictionary *result = nil; __block NSError *failure = nil;
  [resolver resolveCodingPlanForProvider:@"bigmodel" completion:^(NSDictionary *value, NSError *error) { result = value; failure = error; [expectation fulfill]; }];
  [self waitForExpectations:@[expectation] timeout:2];
  XCTAssertNil(failure); XCTAssertEqualObjects(result[@"credential"], @"key-id.resolved-secret");
  XCTAssertEqualObjects(result[@"credential_source"], @"coding_plan");
  XCTAssertEqualObjects(result[@"organization_id"], @"org-default"); XCTAssertEqualObjects(result[@"project_id"], @"project-default");
  XCTAssertEqualObjects(result[@"endpoint_url"], @"https://open.bigmodel.cn/api/anthropic/v1/messages");
  XCTAssertEqual(requests.count, (NSUInteger)4);
  XCTAssertTrue([requests[0].URL.host isEqualToString:@"bigmodel.cn"]);
}

- (void)testMissingExistingKeyIsUnavailableAndDoesNotFallback {
  ZCodePlanFakeAuth *auth = [ZCodePlanFakeAuth new];
  auth.credential = @{ @"schema_version": @1, @"provider": @"bigmodel", @"zcode_token": @"business", @"provider_access_token": @"oauth", @"provider_refresh_token": NSNull.null, @"user_id": @"user", @"account_label": @"test" };
  RishZCodePlanRequest request = ^NSURLSessionDataTask *(NSURLRequest *urlRequest, void (^done)(NSHTTPURLResponse *, NSData *, NSError *)) {
    NSString *path = urlRequest.URL.path;
    NSDictionary *json = [path hasSuffix:@"getCustomerInfo"] ? @{ @"code": @0, @"data": @{ @"organizations": @[@{ @"organizationId": @"org", @"projects": @[@{ @"projectId": @"project" }] }] } } :
      ([path hasSuffix:@"/api_keys"] ? @{ @"code": @0, @"data": @[@{ @"name": @"manual-key", @"apiKey": @"manual" }] } : @{ @"code": @0, @"data": @{ @"secretKey": @"unused" } });
    NSDictionary *reply = ZCodePlanJSONResponse(json); done(reply[@"response"], reply[@"data"], nil); return nil;
  };
  RishZCodePlanResolver *resolver = [[RishZCodePlanResolver alloc] initWithAccountAuth:auth request:request clock:^NSTimeInterval { return 1000; }];
  XCTestExpectation *expectation = [self expectationWithDescription:@"missing plan"];
  __block NSDictionary *result = nil; __block NSError *failure = nil;
  [resolver resolveCodingPlanForProvider:@"bigmodel" completion:^(NSDictionary *value, NSError *error) { result = value; failure = error; [expectation fulfill]; }];
  [self waitForExpectations:@[expectation] timeout:2];
  XCTAssertNil(result); XCTAssertEqualObjects(failure.localizedDescription, @"E_ZCODE_PLAN_KEY_UNAVAILABLE");
  XCTAssertEqualObjects([resolver statusForProvider:@"bigmodel"][@"status"], @"unavailable");
}

- (void)testExistingKeyWithoutEntitlementDoesNotBecomeActive {
  ZCodePlanFakeAuth *auth = [ZCodePlanFakeAuth new];
  auth.credential = @{ @"provider": @"bigmodel", @"zcode_token": @"business", @"provider_access_token": @"oauth", @"account_label": @"test" };
  NSMutableArray<NSURLRequest *> *requests = [NSMutableArray array];
  RishZCodePlanRequest request = ^NSURLSessionDataTask *(NSURLRequest *req, void (^done)(NSHTTPURLResponse *, NSData *, NSError *)) {
    [requests addObject:req];
    NSString *path = req.URL.path;
    id data = [path hasSuffix:@"getCustomerInfo"] ? (id)@{ @"organizations": @[@{ @"organizationId": @"org", @"projects": @[@{ @"projectId": @"project" }] }] } :
      [path hasSuffix:@"/api_keys"] ? (id)@[@{ @"name": @"zcode-api-key", @"apiKey": @"key" }] :
      [path hasSuffix:@"/copy/key"] ? (id)@{ @"secretKey": @"secret" } : (id)@[];
    NSDictionary *reply = ZCodePlanJSONResponse(@{ @"code": @200, @"data": data });
    done(reply[@"response"], reply[@"data"], nil); return nil;
  };
  RishZCodePlanResolver *resolver = [[RishZCodePlanResolver alloc] initWithAccountAuth:auth request:request clock:^NSTimeInterval { return 1000; }];
  XCTestExpectation *done = [self expectationWithDescription:@"no entitlement"];
  [resolver resolveCodingPlanForProvider:@"bigmodel" completion:^(NSDictionary *result, NSError *error) {
    XCTAssertNil(result);
    XCTAssertEqualObjects(error.localizedDescription, @"E_ZCODE_PLAN_UNAVAILABLE");
    [done fulfill];
  }];
  [self waitForExpectations:@[done] timeout:2];
  XCTAssertEqual(requests.count, (NSUInteger)4);
  XCTAssertEqualObjects([requests.lastObject valueForHTTPHeaderField:@"Authorization"], @"key.secret");
  for (NSURLRequest *req in requests) XCTAssertEqualObjects(req.HTTPMethod, @"GET");
}

- (void)testZaiExchangesOAuthAccessAndUsesBearerBusinessAuth {
  ZCodePlanFakeAuth *auth = [ZCodePlanFakeAuth new];
  auth.credential = @{ @"schema_version": @1, @"provider": @"zai", @"zcode_token": @"business", @"provider_access_token": @"oauth", @"provider_refresh_token": NSNull.null, @"user_id": @"user", @"account_label": @"test" };
  NSMutableArray<NSURLRequest *> *requests = [NSMutableArray array];
  RishZCodePlanRequest request = ^NSURLSessionDataTask *(NSURLRequest *urlRequest, void (^done)(NSHTTPURLResponse *, NSData *, NSError *)) {
    [requests addObject:urlRequest]; NSString *path = urlRequest.URL.path;
    NSDictionary *json = [path isEqual:@"/api/auth/z/login"] ? @{ @"code": @0, @"data": @{ @"access_token": @"zai-business", @"expires_in": @3600 } } :
      ([path hasSuffix:@"getCustomerInfo"] ? @{ @"code": @0, @"data": @{ @"organizations": @[@{ @"organizationId": @"org", @"projects": @[@{ @"projectId": @"project" }] }] } } :
       ([path hasSuffix:@"/api_keys"] ? @{ @"code": @0, @"data": @[@{ @"name": @"zcode-api-key", @"apiKey": @"key" }] } :
        ([path hasSuffix:@"/copy/key"] ? @{ @"code": @0, @"data": @{ @"secretKey": @"secret" } } : @{ @"code": @0, @"success": @YES, @"data": @[@{ @"productId": @"coding", @"status": @"VALID" }] })));
    NSDictionary *reply = ZCodePlanJSONResponse(json); done(reply[@"response"], reply[@"data"], nil); return nil;
  };
  RishZCodePlanResolver *resolver = [[RishZCodePlanResolver alloc] initWithAccountAuth:auth request:request clock:^NSTimeInterval { return 1000; }];
  XCTestExpectation *expectation = [self expectationWithDescription:@"resolve zai plan"];
  __block NSDictionary *result = nil; __block NSError *failure = nil;
  [resolver resolveCodingPlanForProvider:@"zai" completion:^(NSDictionary *value, NSError *error) { result = value; failure = error; [expectation fulfill]; }];
  [self waitForExpectations:@[expectation] timeout:2];
  XCTAssertNil(failure); XCTAssertEqualObjects(result[@"credential"], @"key.secret");
  XCTAssertEqualObjects(result[@"endpoint_url"], @"https://api.z.ai/api/anthropic/v1/messages");
  XCTAssertEqualObjects([requests[1] valueForHTTPHeaderField:@"Authorization"], @"Bearer zai-business");
}

- (void)testGlmTransportProviderSelectionDoesNotFallbackAcrossSources {
  XCTAssertEqualObjects([GlmProviderTransport endpointForZCodeProvider:@"bigmodel"].absoluteString,
                        @"https://open.bigmodel.cn/api/anthropic/v1/messages");
  XCTAssertEqualObjects([GlmProviderTransport endpointForZCodeProvider:@"zai"].absoluteString,
                        @"https://api.z.ai/api/anthropic/v1/messages");
  XCTAssertNil([GlmProviderTransport endpointForZCodeProvider:@"claude-code"]);
  XCTAssertEqualObjects([GlmProviderTransport headersForZCodeCredential:@"resolved-secret"][@"x-api-key"], @"resolved-secret");
  XCTAssertTrue([GlmProviderTransport headersForZCodeCredential:@""] .count == 0);
  GlmProviderTransport *trial = [GlmProviderTransport new];
  trial.accountProvider = @"bigmodel_trial";
  XCTAssertFalse([trial providerSupportsModel:@"GLM-5.3"]);
  trial.trialAllowedModels = @[ @"GLM-5.3" ];
  XCTAssertTrue([trial providerSupportsModel:@"GLM-5.3"]);
  XCTAssertFalse([trial providerSupportsModel:@"GLM-4.5"]);
  XCTAssertEqualObjects([trial providerHeadersWithCredential:@"jwt"][@"Authorization"], @"Bearer jwt");
}

@end
