#import <XCTest/XCTest.h>
#import "../../../../modules/rish/ios/Sources/DSHCompletionV2.h"

@interface CompletionResponseParityTests : XCTestCase
@end

@implementation CompletionResponseParityTests

- (id)decode:(NSString *)json {
  NSError *error = nil;
  id value = [NSJSONSerialization JSONObjectWithData:
      [json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:&error];
  XCTAssertNil(error);
  XCTAssertNotNil(value);
  return value;
}

- (NSString *)sorted:(id)value {
  NSError *error = nil;
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:value
      options:NSJSONWritingSortedKeys error:&error];
  XCTAssertNil(error);
  return [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
}

- (NSDictionary *)prose:(NSString *)text {
  return @{@"id": @"response-1", @"model": @"deepseek-v4-flash", @"choices": @[
    @{@"finish_reason": @"stop", @"message": @{@"role": @"assistant", @"content": text}}]};
}

- (NSDictionary *)parse:(NSDictionary *)response error:(NSError **)error {
  return DSHParseCompletionResponseSchema2(response, @"deepseek-v4-flash", @"off", error);
}

- (NSDictionary *)numberedResponse:(NSString *)indexJSON {
  // This must pass through the real Foundation JSON decoder. Constructing an
  // NSNumber literal would miss the wire 0.0/0e0 representation regression.
  return [self decode:[NSString stringWithFormat:
    @"{\"id\":\"response-1\",\"model\":\"deepseek-v4-flash\",\"choices\":[{"
     "\"finish_reason\":\"tool_calls\",\"message\":{\"role\":\"assistant\",\"content\":null,"
     "\"tool_calls\":[{\"id\":\"c1\",\"type\":\"function\",\"index\":%@,"
     "\"function\":{\"name\":\"read_file\",\"arguments\":\"{}\"}}]}}]}", indexJSON]];
}

- (void)testRealJSONFloatingCallIndicesRemainRejectedAfterBridgeEncoding {
  for (NSString *literal in @[@"0.0", @"0e0", @"0E+0", @"-0.0", @"0.5",
      @"true", @"false", @"null", @"\"0\"", @"-1", @"1", @"16",
      @"18446744073709551615"]) {
    NSError *error = nil;
    NSDictionary *parsed = [self parse:[self numberedResponse:literal] error:&error];
    XCTAssertNil(parsed, @"%@", literal);
    XCTAssertEqualObjects(error.localizedDescription, @"E_COMPLETION_TOOL_CALL_INVALID", @"%@", literal);
  }
  NSError *error = nil;
  XCTAssertNotNil([self parse:[self numberedResponse:@"0"] error:&error]);
  XCTAssertNil(error);
}

- (void)testProviderCannotInjectBridgeStorageFacts {
  NSMutableDictionary *response = [[self numberedResponse:@"0.0"] mutableCopy];
  response[@"call_index_storage"] = @[@"signed"];
  response[@"projection_contract"] = @"foundation-json-v1";
  response[@"json_results"] = @[];
  NSError *error = nil;
  XCTAssertNil([self parse:response error:&error]);
  XCTAssertEqualObjects(error.localizedDescription, @"E_COMPLETION_TOOL_CALL_INVALID");
}

- (void)testFoundationWhitespaceOnlyReplyRemainsEmpty {
  NSArray<NSNumber *> *scalars = @[@9, @10, @11, @12, @13, @32, @0x85, @0xA0,
      @0x1680, @0x2000, @0x2001, @0x2002, @0x2003, @0x2004, @0x2005, @0x2006,
      @0x2007, @0x2008, @0x2009, @0x200A, @0x200B, @0x2028, @0x2029, @0x202F,
      @0x205F, @0x3000];
  for (NSNumber *number in scalars) {
    unichar scalar = number.unsignedShortValue;
    NSString *text = [NSString stringWithCharacters:&scalar length:1];
    XCTAssertEqual([text stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet].length, 0U, @"%@", number);
    NSError *error = nil;
    XCTAssertNil([self parse:[self prose:text] error:&error], @"%@", number);
    XCTAssertEqualObjects(error.localizedDescription, @"E_COMPLETION_FINISH_RELATION");
  }
}

- (void)testZeroWidthSpaceWrappedCompatibilityCallUsesOldWriter {
  NSString *source = @"\u200B {\"name\":\"read_file\",\"arguments\":{\"path\":\"a/b\"}} \u200B";
  NSError *error = nil;
  NSDictionary *parsed = [self parse:[self prose:source] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(parsed[@"finish_reason"], @"tool_calls");
  XCTAssertEqualObjects(parsed[@"tool_calls"][0][@"arguments"], [self sorted:@{@"path": @"a/b"}]);
}

- (void)testCompatibilityProjectionPreservesFoundationSlashNumberAndKeySpelling {
  NSString *parametersJSON = @"{\"a2\":\"/目录/😀\",\"a10\":1e20,\"z\":[-0.0,"
      "0.000001,1e-7,9007199254740993,0.1234567890123456789],\"a1\":{\"/\":true}}";
  NSDictionary *parameters = [self decode:parametersJSON];
  NSString *expected = [self sorted:parameters];
  for (NSString *source in @[
      [NSString stringWithFormat:@"{\"name\":\"inspect_git_repo\",\"arguments\":%@}", parametersJSON],
      [NSString stringWithFormat:@"{\"type\":\"function_call\",\"function\":\"inspect_git_repo\",\"parameters\":%@}", parametersJSON]]) {
    NSError *error = nil;
    NSDictionary *parsed = [self parse:[self prose:source] error:&error];
    XCTAssertNil(error);
    XCTAssertEqualObjects(parsed[@"tool_calls"][0][@"arguments"], expected);
  }
}

- (void)testCompatibilityWriterByteLimitIncludesEscapedSlashes {
  for (NSUInteger length = 32760; length <= 32761; length++) {
    NSString *content = [@"" stringByPaddingToLength:length - 2 withString:@"x" startingAtIndex:0];
    NSDictionary *parameters = @{@"x": [content stringByAppendingString:@"/"]};
    NSString *expected = [self sorted:parameters];
    // NSJSONWritingSortedKeys escapes the final slash: the exact bound is on
    // these writer bytes, not the shorter JCS representation.
    XCTAssertEqual([expected lengthOfBytesUsingEncoding:NSUTF8StringEncoding], length + 8);
    NSString *source = [self sorted:@{@"name": @"read_file", @"arguments": parameters}];
    NSError *error = nil;
    NSDictionary *parsed = [self parse:[self prose:source] error:&error];
    XCTAssertNil(error);
    NSArray *calls = parsed[@"tool_calls"];
    if (length == 32760) {
      XCTAssertEqual(calls.count, 1U);
      XCTAssertEqualObjects(calls[0][@"arguments"], expected);
    } else {
      XCTAssertEqual(calls.count, 0U);
      XCTAssertEqualObjects(parsed[@"text"], source);
    }
  }
}

- (void)testExplicitArgumentsKeepExactBytesAndCreateOnlyUsesSameWriter {
  NSArray *argumentsList = @[
    @" { \"path\":\"a/b\", \"content\":\"/😀\", \"expected_revision\": null } \n",
    @"{\"path\":\"a/b\",\"content\":\"/😀\"}",
    @"{\"path\":\"\",\"content\":\"\"}",
  ];
  for (NSString *arguments in argumentsList) {
    NSDictionary *call = @{@"id": @"c1", @"name": @"write_file", @"arguments": arguments};
    NSDictionary *response = @{@"id": @"response-1", @"model": @"deepseek-v4-flash",
      @"choices": @[@{@"finish_reason": @"tool_calls", @"message": @{
        @"role": @"assistant", @"content": NSNull.null,
        @"tool_calls": @[@{@"id": @"c1", @"type": @"function", @"function": @{
          @"name": @"write_file", @"arguments": arguments}}]}}]};
    NSError *error = nil;
    NSDictionary *parsed = [self parse:response error:&error];
    XCTAssertNil(error);
    XCTAssertEqualObjects(parsed[@"tool_calls"], DSHCompletionNormalizeToolCalls(@[call]));
    if ([arguments containsString:@"expected_revision"]) {
      XCTAssertEqualObjects(parsed[@"tool_calls"][0][@"arguments"], arguments);
    }
  }
}

- (void)testSixteenWriteCallsCompleteWithinBoundedProjectionPhases {
  NSMutableArray *calls = [NSMutableArray array];
  NSMutableArray *expectedCalls = [NSMutableArray array];
  NSString *content = [@"" stringByPaddingToLength:16340 withString:@"/" startingAtIndex:0];
  for (NSUInteger index = 0; index < 16; index++) {
    NSString *identifier = [NSString stringWithFormat:@"c%lu", (unsigned long)index];
    NSString *arguments = [self sorted:@{
      @"path": [NSString stringWithFormat:@"dir/%lu", (unsigned long)index], @"content": content}];
    XCTAssertGreaterThan([arguments lengthOfBytesUsingEncoding:NSUTF8StringEncoding], 32700U);
    XCTAssertLessThan([arguments lengthOfBytesUsingEncoding:NSUTF8StringEncoding], 32768U);
    [calls addObject:@{@"id": identifier, @"type": @"function", @"index": @(index),
      @"function": @{@"name": @"write_file", @"arguments": arguments}}];
    [expectedCalls addObject:@{@"id": identifier, @"name": @"write_file", @"arguments": arguments}];
  }
  NSDictionary *response = @{@"id": @"response-1", @"model": @"deepseek-v4-flash",
    @"choices": @[@{@"finish_reason": @"tool_calls", @"message": @{
      @"role": @"assistant", @"content": NSNull.null, @"tool_calls": calls}}]};
  NSError *error = nil;
  NSDictionary *parsed = [self parse:response error:&error];
  XCTAssertNil(error);
  XCTAssertEqual([parsed[@"tool_calls"] count], 16U);
  XCTAssertEqualObjects(parsed[@"tool_calls"], DSHCompletionNormalizeToolCalls(expectedCalls));
  for (NSDictionary *call in parsed[@"tool_calls"]) {
    XCTAssertEqualObjects([self decode:call[@"arguments"]][@"expected_revision"], NSNull.null);
  }
}

@end
