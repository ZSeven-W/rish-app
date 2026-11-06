#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>

#import "../../../../modules/rish/ios/Sources/HarnessAuthService.h"
#import "../../../../modules/rish/ios/Sources/RishConversationBrowser.h"

@interface DSHHarnessAuthService (StreamTest)
- (void)receiveStreamEvent:(const char *)event length:(size_t)length;
@end

@interface RishDeviceAuthorizationController : UIViewController
- (instancetype)initWithURL:(NSURL *)url code:(NSString *)code;
- (void)copyDeviceCode;
@end

@interface HarnessAuthServiceTests : XCTestCase
@end

@implementation HarnessAuthServiceTests

- (void)testClaudeSessionAccessorDoesNotRecursivelyReadItself {
  DSHHarnessAuthService *service = [[DSHHarnessAuthService alloc] initWithBundle:[NSBundle bundleForClass:self.class]];
  XCTAssertNil([service claudeOfficialSession]);
  XCTAssertNil([service claudeOfficialSession]);
}

- (void)testAuthorizationHeaderCopiesNineCharactersAndRendersCompactly {
  RishDeviceAuthorizationController *controller = [[RishDeviceAuthorizationController alloc]
      initWithURL:[NSURL URLWithString:@"https://auth.openai.com/codex/device"] code:@"5KPR-SX4XH"];
  [controller loadViewIfNeeded];
  controller.view.frame = CGRectMake(0, 0, 390, 844);
  [controller.view setNeedsLayout];
  [controller.view layoutIfNeeded];
  [controller copyDeviceCode];
  XCTAssertEqualObjects(UIPasteboard.generalPasteboard.string, @"5KPRSX4XH");
  XCTAssertEqual(UIPasteboard.generalPasteboard.string.length, (NSUInteger)9);
  UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:controller.view.bounds.size];
  UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
    [controller.view.layer renderInContext:context.CGContext];
  }];
  NSString *path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"auth-header-preview.png"];
  XCTAssertTrue([UIImagePNGRepresentation(image) writeToFile:path atomically:YES]);
}

- (void)testPasteableDeviceCodeContainsExactlyNineAsciiCharacters {
  XCTAssertEqualObjects([DSHHarnessAuthService pasteableDeviceCode:@"5KPR-SX4XH"], @"5KPRSX4XH");
  XCTAssertEqualObjects([DSHHarnessAuthService pasteableDeviceCode:@" 5kpr–sx4xh\n"], @"5KPRSX4XH");
  XCTAssertNil([DSHHarnessAuthService pasteableDeviceCode:@"ABCD-EFGH"]);
  XCTAssertNil([DSHHarnessAuthService pasteableDeviceCode:@"5KPR/SX4XH"]);
  XCTAssertNil([DSHHarnessAuthService pasteableDeviceCode:@"５KPR-SX4XH"]);
}

- (void)testCodexNativeAuthIsAvailableWhileUninstalledClaudeCLIIsUnavailable {
  DSHHarnessAuthService *service = [[DSHHarnessAuthService alloc]
      initWithBundle:NSBundle.mainBundle];
  for (NSString *harnessId in @[ @"codex", @"claude-code" ]) {
    NSDictionary *status = [service statusForHarnessId:harnessId];
    XCTAssertEqualObjects(status[@"schema_version"], @1);
    XCTAssertEqualObjects(status[@"harness_id"], harnessId);
    XCTAssertEqualObjects(status[@"runtime"][ @"kind"], @"official-cli");
    BOOL nativeAuth = [harnessId isEqualToString:@"codex"];
    XCTAssertEqual([status[@"runtime"][ @"available"] boolValue], nativeAuth);
    XCTAssertEqualObjects(status[@"status"], nativeAuth ? @"signed_out" : @"unavailable");
    XCTAssertEqualObjects(status[@"auth_method"], @"none");
    XCTAssertNil(status[@"account"]);
    XCTAssertNil(status[@"login"]);
  }
}

- (void)testInvalidHarnessIsRejectedBySafeOutputParser {
  XCTAssertEqualObjects(
      [DSHHarnessAuthService safeLoginFieldsFromOfficialOutput:
          @"https://auth.openai.com/codex/device\nABCD-EFGH"
          harnessId:@"deepseek"], @{});
}

- (void)testSafeOutputParserStripsQueryAndIgnoresUntrustedUrls {
  NSString *output =
      @"Continue at https://evil.example/codex/device?token=secret\n"
       "Open https://auth.openai.com/codex/device\n"
       "User code: abcd-efgh\n";
  NSDictionary *fields = [DSHHarnessAuthService
      safeLoginFieldsFromOfficialOutput:output harnessId:@"codex"];
  XCTAssertEqualObjects(fields[@"verification_url"],
                        @"https://auth.openai.com/codex/device");
  XCTAssertEqualObjects(fields[@"user_code"], @"ABCD-EFGH");
}

- (void)testClaudeParserOnlyAcceptsClaudeOauthOrigin {
  NSDictionary *fields = [DSHHarnessAuthService
      safeLoginFieldsFromOfficialOutput:
          @"Open https://claude.ai/oauth/authorize?state=secret&client_id=rish\n"
           "Device code: WXYZ-1234"
          harnessId:@"claude-code"];
  XCTAssertEqualObjects(fields[@"verification_url"],
                        @"https://claude.ai/oauth/authorize?state=secret&client_id=rish");
  XCTAssertEqualObjects(fields[@"user_code"], @"WXYZ-1234");
}

- (void)testParserRejectsNonDefaultPortsAndBearerLikeQueryFields {
  NSDictionary *fields = [DSHHarnessAuthService
      safeLoginFieldsFromOfficialOutput:
          @"https://claude.ai:8443/oauth/authorize?state=s\n"
           "https://claude.ai/oauth/authorize?access_token=secret"
          harnessId:@"claude-code"];
  XCTAssertEqualObjects(fields, (@{}));
}

- (void)testCodexAppServerDeviceCodeKeepsOnlyDisplayFields {
  NSString *output =
      @"{\"id\":\"login-id-secret\",\"result\":{"
       "\"verificationUrl\":\"https://auth.openai.com/codex/device?state=secret\","
       "\"userCode\":\"QWER-1234\",\"accessToken\":\"secret\"}}";
  NSDictionary *fields = [DSHHarnessAuthService
      safeLoginFieldsFromOfficialOutput:output harnessId:@"codex"];
  XCTAssertEqualObjects(fields, (@{
    @"user_code": @"QWER-1234",
  }));
}

- (void)testAppServerParserIgnoresUntypedDisplayFields {
  NSString *output =
      @"{\"result\":{\"verificationUrl\":123,\"userCode\":false}}";
  XCTAssertEqualObjects([DSHHarnessAuthService
      safeLoginFieldsFromOfficialOutput:output harnessId:@"codex"], @{});
}

- (void)testParserDoesNotReinterpretJsonContainersOrPartialObjects {
  for (NSString *output in @[@"[{\"userCode\":\"ABCD-EFGH\"}]", @"{\"userCode\":false", @"null"]) {
    XCTAssertEqualObjects([DSHHarnessAuthService safeLoginFieldsFromOfficialOutput:output harnessId:@"codex"], @{});
  }
}

- (void)testOfficialOneTimeCodePromptWithTerminalColors {
  NSString *output = @"Open https://auth.openai.com/codex/device\n2. Enter this one-time code (expires in 15 minutes)\n\n\033[32mABCD-EFGH\033[0m\n";
  NSDictionary *fields = [DSHHarnessAuthService safeLoginFieldsFromOfficialOutput:output harnessId:@"codex"];
  XCTAssertEqualObjects(fields[@"user_code"], @"ABCD-EFGH");
  XCTAssertEqualObjects(fields[@"verification_url"], @"https://auth.openai.com/codex/device");
}

- (void)testDeviceCodeSurvivesSplitOutputAndIgnoresCancelledGeneration {
  DSHHarnessAuthService *service = [[DSHHarnessAuthService alloc] initWithBundle:NSBundle.mainBundle];
  [service setValue:@"fixture-session" forKey:@"activeSessionId"];
  [service setValue:@1 forKey:@"generation"];
  [service setValue:@1 forKey:@"streamGeneration"];
  for (NSString *part in @[@"2. Enter this one-time ", @"code (expires in 15 minutes)\n\nABCD-", @"EFGH\n"]) {
    NSDictionary *event = @{@"protocol_version":@1, @"event":@"output", @"data_base64":[[part dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0]};
    NSData *data = [NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
    [service receiveStreamEvent:(const char *)data.bytes length:data.length];
  }
  XCTAssertEqualObjects([service valueForKey:@"activeUserCode"], @"ABCD-EFGH");
  [service setValue:nil forKey:@"activeUserCode"];
  [service setValue:@2 forKey:@"generation"];
  NSDictionary *late = @{@"protocol_version":@1, @"event":@"output", @"data_base64":[[@"User code: LATE-CODE\n" dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0]};
  NSData *data = [NSJSONSerialization dataWithJSONObject:late options:0 error:nil];
  [service receiveStreamEvent:(const char *)data.bytes length:data.length];
  XCTAssertNil([service valueForKey:@"activeUserCode"]);
}

- (void)testConversationBrowserAcceptsOnlyVersionedWebTargets {
  for (NSString *address in @[@"http://localhost:8000/index.html", @"http://127.0.0.1:65016/?mode=preview#items", @"https://example.com/docs"]) {
    NSURL *url = [RishConversationBrowser URLForRequest:@{@"schema_version":@1, @"url":address}];
    XCTAssertEqualObjects(url.absoluteString, address);
  }
  for (NSString *address in @[@"javascript:alert(1)", @"file:///tmp/index.html", @"data:text/html,test", @"mailto:test@example.com", @"https://", @"https://user:secret@example.com", @"http://localhost:99999/", @"https://example.com\\x", @"https://example.com/\n"]) {
    XCTAssertNil(([RishConversationBrowser URLForRequest:@{@"schema_version":@1, @"url":address}]));
  }
  XCTAssertNil(([RishConversationBrowser URLForRequest:@{@"schema_version":@2, @"url":@"https://example.com"}]));
  XCTAssertNil(([RishConversationBrowser URLForRequest:@{@"schema_version":@YES, @"url":@"https://example.com"}]));
  XCTAssertNil(([RishConversationBrowser URLForRequest:@{@"schema_version":@1, @"url":@"https://example.com", @"extra":@YES}]));
}

- (void)testClaudeAuthorizationRequestCodeSwitchIsNotAToken {
  NSString *url = @"https://claude.ai/oauth/authorize?code=true&state=fixture";
  NSDictionary *valid = [DSHHarnessAuthService safeLoginFieldsFromOfficialOutput:url harnessId:@"claude-code"];
  XCTAssertEqualObjects(valid[@"verification_url"], url);
  for (NSString *invalid in @[@"https://claude.ai/oauth/authorize?code=secret", @"https://claude.ai/oauth/authorize?code=true&code=true", @"https://claude.ai/oauth/callback?code=true"]) {
    NSDictionary *result = [DSHHarnessAuthService safeLoginFieldsFromOfficialOutput:invalid harnessId:@"claude-code"];
    XCTAssertNil(result[@"verification_url"]);
  }
}
@end
