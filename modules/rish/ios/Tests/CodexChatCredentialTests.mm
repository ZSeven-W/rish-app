#import <XCTest/XCTest.h>
#import "HarnessAuthService.h"

@interface CodexChatCredentialTests : XCTestCase
@end

@implementation CodexChatCredentialTests

- (void)testCredentialParserReturnsOnlyNativeTransportFields {
  NSDictionary *json = @{ @"tokens": @{
    @"access_token": @"access.jwt",
    @"refresh_token": @"refresh.secret",
    @"id_token": @"eyJhbGciOiJub25lIn0.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjdC0xIn19.sig",
  }, @"untrusted": @"must not escape" };
  NSDictionary *credential = [DSHHarnessAuthService codexChatCredentialFromAuthJSON:json];
  XCTAssertEqualObjects(credential[@"access_token"], @"access.jwt");
  XCTAssertEqualObjects(credential[@"account_id"], @"acct-1");
  XCTAssertNil(credential[@"refresh_token"]);
  XCTAssertNil(credential[@"untrusted"]);
}

- (void)testCredentialParserRejectsIncompleteLogin {
  XCTAssertNil(([DSHHarnessAuthService codexChatCredentialFromAuthJSON:@{ @"tokens": @{ @"access_token": @"only" } }]));
  XCTAssertNil(([DSHHarnessAuthService codexChatCredentialFromAuthJSON:@{}]));
  XCTAssertNil(([DSHHarnessAuthService codexChatCredentialFromAuthJSON:@{ @"tokens": @[] }]));
  XCTAssertNil(([DSHHarnessAuthService codexChatCredentialFromAuthJSON:@{ @"tokens": @{ @"access_token": @[], @"refresh_token": @"r" } }]));
  XCTAssertNil(([DSHHarnessAuthService codexChatCredentialFromAuthJSON:@{ @"tokens": @{ @"access_token": @"a\n", @"refresh_token": @"r" }, @"account_id": @"acct" }]));
  XCTAssertNil(([DSHHarnessAuthService codexChatCredentialFromAuthJSON:@{ @"tokens": @{ @"access_token": @"a", @"refresh_token": @"r" }, @"account_id": @"acct\tbad" }]));
}

- (void)testMalformedJWTAndRawAuthShapesDoNotCrash {
  XCTAssertTrue([DSHHarnessAuthService codexAccessTokenNeedsRefresh:@".." now:nil]);
  XCTAssertTrue([DSHHarnessAuthService codexAccessTokenNeedsRefresh:@"a.b.c.d" now:nil]);
  XCTAssertNil(([DSHHarnessAuthService codexChatCredentialFromAuthJSON:(id)@[]]));
  XCTAssertNil(([DSHHarnessAuthService codexChatCredentialFromAuthJSON:@{ @"tokens": [NSNull null] }]));
}

- (void)testAccessTokenExpiryUsesBoundedRefreshWindow {
  NSString *header = @"eyJhbGciOiJub25lIn0";
  NSString *payload = @"eyJleHAiOjEwMDB9";
  NSString *jwt = [NSString stringWithFormat:@"%@.%@.sig", header, payload];
  XCTAssertTrue([DSHHarnessAuthService codexAccessTokenNeedsRefresh:jwt now:[NSDate dateWithTimeIntervalSince1970:950]]);
  XCTAssertFalse([DSHHarnessAuthService codexAccessTokenNeedsRefresh:jwt now:[NSDate dateWithTimeIntervalSince1970:900]]);
  XCTAssertTrue([DSHHarnessAuthService codexAccessTokenNeedsRefresh:@"malformed" now:[NSDate dateWithTimeIntervalSince1970:0]]);
}

@end
