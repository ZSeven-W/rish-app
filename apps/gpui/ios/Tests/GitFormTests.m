#import <XCTest/XCTest.h>
#import "RishGitFormController.h"
#import "RishGitFormValidation.h"

@interface RishGitFormController (Tests)
- (void)updateValidation;
- (void)submit;
- (void)settleCancellation;
@end

@interface RishGitFormTests : XCTestCase
@end

@implementation RishGitFormTests

- (NSMutableDictionary *)options:(NSString *)kind {
  NSMutableArray *fields = [NSMutableArray array];
  NSArray *keys = [kind isEqual:@"commit"] ? @[@"message", @"author_name", @"author_email"] : @[@"url"];
  for (NSString *key in keys) [fields addObject:@{
    @"key": key, @"label": key, @"placeholder": key, @"value": @"",
  }];
  return [@{
    @"kind": kind, @"appearance": @"light", @"title": @"Git",
    @"submit_label": @"保存", @"cancel_label": @"取消", @"fields": fields,
    @"hint": @"Git 信息", @"invalid_message": @"请检查输入",
  } mutableCopy];
}

- (NSMutableDictionary *)commit {
  return [@{@"message": @"修复问题", @"author_name": @"Rish User", @"author_email": @"user@example.com"} mutableCopy];
}

- (NSString *)repeat:(NSString *)unit count:(NSUInteger)count {
  NSMutableString *text = [NSMutableString string];
  for (NSUInteger index = 0; index < count; ++index) [text appendString:unit];
  return text;
}

- (void)testOptionsHaveOnlyReviewedNonSecretFields {
  for (NSString *kind in @[@"commit", @"remote"]) {
    NSMutableDictionary *options = [self options:kind];
    XCTAssertTrue(RishGitFormOptionsAreValid(options));
    options[@"appearance"] = @"dark";
    XCTAssertTrue(RishGitFormOptionsAreValid(options));
    for (NSString *key in [options allKeys]) {
      NSMutableDictionary *missing = [options mutableCopy];
      [missing removeObjectForKey:key];
      XCTAssertFalse(RishGitFormOptionsAreValid(missing));
    }
    options[@"token"] = @"must never appear";
    XCTAssertFalse(RishGitFormOptionsAreValid(options));
  }
  for (id invalid in @[NSNull.null, @42, @[], @{}, @"commit"])
    XCTAssertFalse(RishGitFormOptionsAreValid(invalid));
  for (NSString *key in @[@"kind", @"appearance", @"title", @"submit_label", @"cancel_label", @"hint", @"invalid_message"]) {
    NSMutableDictionary *options = [self options:@"commit"];
    options[key] = @42;
    XCTAssertFalse(RishGitFormOptionsAreValid(options));
  }
  NSMutableDictionary *options = [self options:@"commit"];
  options[@"fields"] = @[@{@"key": @"token", @"label": @"Token", @"placeholder": @"", @"value": @""}];
  XCTAssertFalse(RishGitFormOptionsAreValid(options));
  for (NSString *key in @[@"key", @"label", @"placeholder", @"value"]) {
    options = [self options:@"remote"];
    NSMutableDictionary *field = [options[@"fields"][0] mutableCopy];
    field[key] = NSNull.null;
    options[@"fields"] = @[field];
    XCTAssertFalse(RishGitFormOptionsAreValid(options));
  }
  options = [self options:@"commit"];
  options[@"fields"] = [options[@"fields"] reverseObjectEnumerator].allObjects;
  XCTAssertFalse(RishGitFormOptionsAreValid(options));
}

- (void)testCommitNormalizationAndByteBoundaries {
  NSMutableDictionary *values = [self commit];
  values[@"message"] = @" \u3000Cafe\u0301 ";
  values[@"author_name"] = @"  用户  ";
  values[@"author_email"] = @" user@example.com ";
  NSDictionary *normalized = RishGitFormValues(@"commit", values);
  XCTAssertEqualObjects(normalized, (@{@"message": @"Café", @"author_name": @"用户", @"author_email": @"user@example.com"}));
  for (NSArray *boundary in @[@[@"message", @"é", @250], @[@"author_name", @"界", @40]]) {
    values = [self commit];
    values[boundary[0]] = [self repeat:boundary[1] count:[boundary[2] unsignedIntegerValue]];
    XCTAssertNotNil(RishGitFormValues(@"commit", values));
    values[boundary[0]] = [values[boundary[0]] stringByAppendingString:@"a"];
    XCTAssertNil(RishGitFormValues(@"commit", values));
  }
  values = [self commit];
  values[@"author_email"] = [[self repeat:@"a" count:252] stringByAppendingString:@"@b"];
  XCTAssertNotNil(RishGitFormValues(@"commit", values));
  values[@"author_email"] = [values[@"author_email"] stringByAppendingString:@"b"];
  XCTAssertNil(RishGitFormValues(@"commit", values));
  values = [self commit];
  values[@"author_name"] = [self repeat:@"e\u0301" count:60];
  XCTAssertNotNil(RishGitFormValues(@"commit", values), @"Normalize before counting UTF8 bytes");
}

- (void)testCommitRejectsInvalidIdentityAndCompositionCharacters {
  for (NSString *key in @[@"message", @"author_name", @"author_email"]) {
    for (NSString *invalid in @[@"", @"   ", @"a\nb", @"a\rb", @"a\u2028b", @"a\u2029b", @"a\u200bb", @"a\u200db",
                                 [NSString stringWithFormat:@"a%Cb", (unichar)0x0085]]) {
      NSMutableDictionary *values = [self commit];
      values[key] = invalid;
      XCTAssertNil(RishGitFormValues(@"commit", values), @"%@ must reject invalid values", key);
    }
    unichar malformed[] = {'a', 0xd800, 'b'};
    NSMutableDictionary *values = [self commit];
    values[key] = [NSString stringWithCharacters:malformed length:3];
    XCTAssertNil(RishGitFormValues(@"commit", values));
  }
  for (NSString *invalid in @[@"user", @"@host", @"user@", @"user@@host", @"u ser@host", @"u<ser@host", @"user@ho>st"]) {
    NSMutableDictionary *values = [self commit];
    values[@"author_email"] = invalid;
    XCTAssertNil(RishGitFormValues(@"commit", values));
  }
  NSMutableDictionary *values = [self commit];
  values[@"author_name"] = @"Name <address>";
  XCTAssertNil(RishGitFormValues(@"commit", values));
  values = [self commit];
  values[@"token"] = @"must never cross bridge";
  XCTAssertNil(RishGitFormValues(@"commit", values));
}

- (void)testRemoteUsesRealTransportPolicyAndNeverReturnsCredentials {
  for (NSString *valid in @[@"https://github.com/org/repo.git", @"https://example.com:443/repo",
                             @"http://localhost:8080/repo", @"http://127.0.0.1/repo",
                             @"http://192.168.1.2:8080/repo", @"http://[::1]/repo",
                             @"http://[fd00::1]:8080/repo", @"https://github.com/repo%20name"]) {
    XCTAssertEqualObjects(RishGitFormValues(@"remote", @{@"url": valid}), (@{@"url": valid}));
  }
  XCTAssertEqualObjects(RishGitFormValues(@"remote", @{@"url": @"  https://github.com/org/repo.git  "}),
                        (@{@"url": @"https://github.com/org/repo.git"}));
  for (NSString *invalid in @[@"", @"git@github.com:org/repo.git", @"file:///tmp/repo", @"https://github.com/",
                              @"https://token@github.com/org/repo", @"https://user:secret@github.com/repo",
                              @"https://github.com/repo?token=x", @"https://github.com/repo#part",
                              @"https://github.com/a/../repo", @"https://github.com/%2e/repo",
                              @"https://github.com/repo%0a", @"https://github.com/repo%00",
                              @"https://github.com/re po",
                              @"http://example.com/repo", @"https://127.0.0.1/repo", @"https://[::1]/repo",
                              @"https://localhost/repo", @"https://server.local/repo", @"https://github.com:8443/repo"]) {
    XCTAssertNil(RishGitFormValues(@"remote", @{@"url": invalid}), @"Unexpected accepted remote %@", invalid);
  }
  NSString *prefix = @"https://github.com/";
  NSString *exact = [prefix stringByAppendingString:[self repeat:@"a" count:2048 - prefix.length]];
  XCTAssertNotNil(RishGitFormValues(@"remote", @{@"url": exact}));
  XCTAssertNil(RishGitFormValues(@"remote", @{@"url": [exact stringByAppendingString:@"a"]}));
  XCTAssertNil(RishGitFormValues(@"remote", @{@"url": @"https://github.com/repo", @"token": @"secret"}));
}

- (void)testFormHasOpaqueConstrainedViewportAndNonemptyValidation {
  RishGitFormController *controller = [RishGitFormController new];
  controller.options = [self options:@"commit"];
  controller.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
  [controller loadViewIfNeeded];
  controller.view.frame = CGRectMake(0, 0, 402, 874);
  [controller.view.keyboardLayoutGuide removeAllTrackedConstraints];
  [controller.view layoutIfNeeded];
  UIScrollView *scroll = [controller valueForKey:@"scroll"];
  NSArray<UITextField *> *editors = [controller valueForKey:@"editors"];
  UIButton *submit = [controller valueForKey:@"submitButton"];
  XCTAssertTrue(controller.view.opaque);
  XCTAssertEqual(CGColorGetAlpha(controller.view.layer.backgroundColor), 1);
  XCTAssertGreaterThan(scroll.bounds.size.height, 600);
  XCTAssertFalse(scroll.hasAmbiguousLayout);
  XCTAssertEqual(editors.count, 3u);
  XCTAssertFalse(submit.enabled);
  NSDictionary *values = [self commit];
  NSArray *keys = @[@"message", @"author_name", @"author_email"];
  for (NSUInteger index = 0; index < editors.count; ++index) {
    XCTAssertGreaterThanOrEqual(editors[index].superview.bounds.size.height, 54);
    editors[index].text = values[keys[index]];
  }
  [controller updateValidation];
  XCTAssertTrue(submit.enabled);
  controller.view.frame = CGRectMake(0, 0, 874, 320);
  [controller.view setNeedsLayout];
  [controller.view layoutIfNeeded];
  XCTAssertGreaterThan(scroll.bounds.size.height, 200);
  XCTAssertFalse(scroll.hasAmbiguousLayout);
  XCTAssertLessThanOrEqual(editors.firstObject.superview.bounds.size.width, 640);
  CGFloat fontSize = editors.firstObject.font.pointSize;
  for (NSValue *size in @[[NSValue valueWithCGSize:CGSizeMake(320, 640)],
                         [NSValue valueWithCGSize:CGSizeMake(768, 1024)],
                         [NSValue valueWithCGSize:CGSizeMake(1366, 1024)]]) {
    controller.view.frame = (CGRect){CGPointZero, size.CGSizeValue};
    [controller.view setNeedsLayout];
    [controller.view layoutIfNeeded];
    XCTAssertGreaterThan(scroll.bounds.size.height, 200);
    XCTAssertFalse(scroll.hasAmbiguousLayout);
    XCTAssertLessThanOrEqual(editors.firstObject.superview.bounds.size.width, 640);
    XCTAssertEqual(editors.firstObject.font.pointSize, fontSize);
    XCTAssertGreaterThanOrEqual(submit.bounds.size.height, 44);
    CGRect submitFrame = [submit convertRect:submit.bounds toView:controller.view];
    XCTAssertTrue(CGRectContainsRect(CGRectInset(controller.view.bounds, -0.5, -0.5), submitFrame));
  }
  XCTAssertEqualWithAccuracy(editors.firstObject.superview.bounds.size.width, 640, 1);
  CGFloat initialHeight = scroll.bounds.size.height;
  NSLayoutConstraint *keyboard = [scroll.bottomAnchor constraintEqualToAnchor:controller.view.bottomAnchor constant:-320];
  keyboard.active = YES;
  [controller.view layoutIfNeeded];
  XCTAssertGreaterThan(scroll.bounds.size.height, 200);
  XCTAssertLessThan(scroll.bounds.size.height, initialHeight);
  XCTAssertFalse(scroll.hasAmbiguousLayout);
  keyboard.active = NO;
  [controller.view layoutIfNeeded];
  XCTAssertEqualWithAccuracy(scroll.bounds.size.height, initialHeight, 1);
  __block NSUInteger settlements = 0;
  controller.finish = ^(id result) { ++settlements; XCTAssertEqualObjects(result, NSNull.null); };
  [controller settleCancellation];
  [controller settleCancellation];
  XCTAssertEqual(settlements, 1u);
}
@end
