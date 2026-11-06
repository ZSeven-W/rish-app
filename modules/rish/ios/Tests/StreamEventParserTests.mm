#import <XCTest/XCTest.h>

#import "../../../../modules/rish/ios/Sources/DSHStreamEvents.h"
#import "../../../../modules/rish/ios/Sources/ClaudeProviderTransport.h"
#import "../../../../modules/rish/ios/Sources/CodexProviderTransport.h"

@interface StreamEventParserTests : XCTestCase
@end

@implementation StreamEventParserTests

- (DSHStreamEventParser *)parser {
  return [[DSHStreamEventParser alloc] init];
}

- (NSString *)contentDeltaJson:(NSString *)text {
  return [NSString stringWithFormat:
      @"data: {\"choices\":[{\"delta\":{\"content\":\"%@\"}}]}\n\n", text];
}

- (NSString *)reasoningDeltaJson:(NSString *)text {
  return [NSString stringWithFormat:
      @"data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"%@\"}}]}\n\n",
      text];
}

- (void)testParsesContentDeltasSplitAcrossChunkBoundaries {
  DSHStreamEventParser *parser = [self parser];
  // One event split into three raw chunks (mid-header, mid-JSON, mid-CRLF).
  NSString *full = [self contentDeltaJson:@"Hello"];
  NSArray<NSString *> *pieces = @[
    [full substringToIndex:9],
    [full substringWithRange:NSMakeRange(9, 21)],
    [full substringFromIndex:30],
  ];
  NSMutableArray<NSDictionary *> *collected = [NSMutableArray array];
  for (NSString *piece in pieces) {
    const char *c = piece.UTF8String;
    NSError *error = nil;
    NSArray *deltas = [parser appendBytes:(const uint8_t *)c
                                    length:strlen(c) error:&error];
    XCTAssertNil(error);
    [collected addObjectsFromArray:deltas];
  }
  XCTAssertEqual(collected.count, 1u);
  XCTAssertEqualObjects(collected.firstObject[@"type"], @"delta");
  XCTAssertEqualObjects(collected.firstObject[@"content"], @"Hello");
}

- (void)testParsesReasoningAndFinishInOneEvent {
  DSHStreamEventParser *parser = [self parser];
  NSString *event =
      @"data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"thinking\"},"
      @"\"finish_reason\":\"stop\"}]}\n\n";
  const char *c = event.UTF8String;
  NSError *error = nil;
  NSArray *deltas = [parser appendBytes:(const uint8_t *)c length:strlen(c)
                                  error:&error];
  XCTAssertNil(error);
  XCTAssertEqual(deltas.count, 1u);
  XCTAssertEqualObjects(deltas.firstObject[@"reasoning"], @"thinking");
  XCTAssertEqualObjects(deltas.firstObject[@"finish_reason"], @"stop");
}

- (void)testDoneSentinelAndCommentsAreHandled {
  DSHStreamEventParser *parser = [self parser];
  NSString *stream = [NSString stringWithFormat:
      @": keep-alive\n\n%@data: [DONE]\n\n", [self contentDeltaJson:@"x"]];
  const char *c = stream.UTF8String;
  NSError *error = nil;
  NSArray *deltas = [parser appendBytes:(const uint8_t *)c length:strlen(c)
                                  error:&error];
  XCTAssertNil(error);
  XCTAssertEqual(deltas.count, 2u);
  XCTAssertEqualObjects(deltas.firstObject[@"content"], @"x");
  XCTAssertEqualObjects(deltas.lastObject[@"type"], @"done");
}

- (void)testTwoCompleteEventsOnConsecutiveDataLinesAreTwoEvents {
  DSHStreamEventParser *parser = [self parser];
  // Two whole events on consecutive data: lines, with no blank line between
  // them. This parser used to join them per the SSE spec and fail closed on
  // the invalid JSON that made; the shared core reads each one as soon as it
  // is whole, which is what every provider this app speaks to sends and what
  // Android always did. A well-formed stream is no longer thrown away for
  // want of a blank line.
  NSString *stream =
      @"data: {\"choices\":[{\"delta\":{\"content\":\"a\"}}]}\n"
      @"data: {\"choices\":[{\"delta\":{\"content\":\"b\"}}]}\n\n";
  const char *c = stream.UTF8String;
  NSError *error = nil;
  NSArray *deltas = [parser appendBytes:(const uint8_t *)c length:strlen(c)
                                  error:&error];
  XCTAssertNil(error);
  XCTAssertEqual(deltas.count, 2u);
  XCTAssertEqualObjects(deltas.firstObject[@"content"], @"a");
  XCTAssertEqualObjects(deltas.lastObject[@"content"], @"b");
}

- (void)testAnEventSpelledAcrossDataLinesIsStillJoined {
  DSHStreamEventParser *parser = [self parser];
  // And the spec's own case still works: one event whose JSON is split
  // across two data: lines is joined, because neither half is whole on its
  // own and the blank line ends it.
  NSString *stream =
      @"data: {\"choices\":[{\"delta\":\n"
      @"data: {\"content\":\"joined\"}}]}\n\n";
  const char *c = stream.UTF8String;
  NSError *error = nil;
  NSArray *deltas = [parser appendBytes:(const uint8_t *)c length:strlen(c)
                                  error:&error];
  XCTAssertNil(error);
  XCTAssertEqual(deltas.count, 1u);
  XCTAssertEqualObjects(deltas.firstObject[@"content"], @"joined");
}

- (void)testFinishFlushesATrailingUnterminatedEvent {
  DSHStreamEventParser *parser = [self parser];
  NSString *truncated =
      @"data: {\"choices\":[{\"delta\":{\"content\":\"tail\"}}]}";
  const char *c = truncated.UTF8String;
  NSError *error = nil;
  NSArray *first = [parser appendBytes:(const uint8_t *)c length:strlen(c)
                                 error:&error];
  XCTAssertNil(error);
  XCTAssertEqual(first.count, 0u);
  NSArray *flushed = [parser finish:&error];
  XCTAssertNil(error);
  XCTAssertEqual(flushed.count, 1u);
  XCTAssertEqualObjects(flushed.firstObject[@"content"], @"tail");
  // Second finish fails closed.
  error = nil;
  XCTAssertNil([parser finish:&error]);
  XCTAssertNotNil(error);
}

- (void)testCRLFTransportsAreNormalized {
  DSHStreamEventParser *parser = [self parser];
  NSString *crlf = [self contentDeltaJson:@"crlf"];
  crlf = [crlf stringByReplacingOccurrencesOfString:@"\n"
                                         withString:@"\r\n"];
  const char *c = crlf.UTF8String;
  NSError *error = nil;
  NSArray *deltas = [parser appendBytes:(const uint8_t *)c length:strlen(c)
                                  error:&error];
  XCTAssertNil(error);
  XCTAssertEqual(deltas.count, 1u);
  XCTAssertEqualObjects(deltas.firstObject[@"content"], @"crlf");
}

- (void)testOversizedLinesFailClosed {
  DSHStreamEventParser *parser = [self parser];
  NSMutableString *big = [NSMutableString stringWithString:@"data: "];
  while (big.length < DSHStreamMaxLineBytes + 16) {
    [big appendString:@"a"];
  }
  const char *c = big.UTF8String;
  NSError *error = nil;
  XCTAssertNil([parser appendBytes:(const uint8_t *)c length:strlen(c)
                             error:&error]);
  XCTAssertNotNil(error);
}

- (void)testChunksWithoutChoicesAreNoOps {
  DSHStreamEventParser *parser = [self parser];
  NSString *stream = @"data: {\"id\":\"x\",\"usage\":{\"total_tokens\":1}}\n\n";
  const char *c = stream.UTF8String;
  NSError *error = nil;
  NSArray *deltas = [parser appendBytes:(const uint8_t *)c length:strlen(c)
                                  error:&error];
  XCTAssertNil(error);
  XCTAssertEqual(deltas.count, 0u);
}


- (void)testLinesThatNeverBecomeAnEventFailClosed {
  DSHStreamEventParser *parser = [self parser];
  // Lines that never add up to an event must not grow the buffer without
  // bound. The cap is on what is *accumulating*: a line that is already a
  // whole event is read and never accumulates, so the fragments here are
  // deliberately half of one.
  NSMutableString *stream = [NSMutableString string];
  for (NSInteger index = 0;
      index < DSHStreamMaxBufferedLines + 2; index += 1) {
    [stream appendFormat:@"data: {\"line\":%ld,\n", (long)index];
  }
  const char *c = stream.UTF8String;
  NSError *error = nil;
  XCTAssertNil([parser appendBytes:(const uint8_t *)c length:strlen(c)
                              error:&error]);
  XCTAssertNotNil(error);
  XCTAssertEqualObjects(error.domain, DSHStreamEventErrorDomain);
  XCTAssertEqual(error.code, 2105);
}

- (void)testManyWholeEventsInOneReadAreAllRead {
  DSHStreamEventParser *parser = [self parser];
  // The same count of lines, each one a whole event: nothing accumulates,
  // so there is no cap to reach and every one of them is read.
  NSMutableString *stream = [NSMutableString string];
  for (NSInteger index = 0;
      index < DSHStreamMaxBufferedLines + 2; index += 1) {
    [stream appendFormat:
        @"data: {\"choices\":[{\"delta\":{\"content\":\"%ld\"}}]}\n", (long)index];
  }
  const char *c = stream.UTF8String;
  NSError *error = nil;
  NSArray *deltas = [parser appendBytes:(const uint8_t *)c length:strlen(c)
                                  error:&error];
  XCTAssertNil(error);
  XCTAssertEqual(deltas.count, (NSUInteger)(DSHStreamMaxBufferedLines + 2));
}

- (void)testInvalidUTF8LineFailsClosedInsteadOfEndingTheEvent {
  DSHStreamEventParser *parser = [self parser];
  // 0xFF is never valid UTF-8; it must error out rather than being
  // mistaken for a blank line (nil string) that terminates the event.
  const uint8_t bytes[] = {'d', 'a', 't', 'a', ':', ' ', 0xFF, 0xFE, '\n', '\n'};
  NSError *error = nil;
  XCTAssertNil([parser appendBytes:bytes length:sizeof(bytes) error:&error]);
  XCTAssertNotNil(error);
  XCTAssertEqual(error.code, 2101);
}

- (void)testFinishFailsClosedOnUndecodableTrailingBytes {
  DSHStreamEventParser *parser = [self parser];
  // Trailing bytes without a newline that are not valid UTF-8 must error
  // instead of being silently dropped.
  const uint8_t bytes[] = {'d', 'a', 't', 'a', ':', ' ', 0xC3};
  NSError *error = nil;
  XCTAssertEqual([parser appendBytes:bytes length:sizeof(bytes) error:&error].count,
                 0u);
  XCTAssertNil(error);
  error = nil;
  XCTAssertNil([parser finish:&error]);
  XCTAssertNotNil(error);
  XCTAssertEqual(error.code, 2101);
}

- (void)testBlankDataKeepAliveIsANoOp {
  DSHStreamEventParser *parser = [self parser];
  NSString *stream = @"data: \n\ndata: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n";
  const char *c = stream.UTF8String;
  NSError *error = nil;
  NSArray *deltas = [parser appendBytes:(const uint8_t *)c length:strlen(c)
                                  error:&error];
  XCTAssertNil(error);
  XCTAssertEqual(deltas.count, 1u);
  XCTAssertEqualObjects(deltas.firstObject[@"content"], @"x");
}

- (void)testResetAllowsReuse {
  DSHStreamEventParser *parser = [self parser];
  NSString *event = [self contentDeltaJson:@"one"];
  const char *c = event.UTF8String;
  NSError *error = nil;
  NSArray *first = [parser appendBytes:(const uint8_t *)c length:strlen(c)
                                 error:&error];
  XCTAssertEqual(first.count, 1u);
  [parser reset];
  NSArray *second = [parser appendBytes:(const uint8_t *)c length:strlen(c)
                                  error:&error];
  XCTAssertEqual(second.count, 1u);
  XCTAssertEqualObjects(second.firstObject[@"content"], @"one");
}

// Appends one delta to the assembler, asserting it is accepted cleanly.
- (void)appendDelta:(DSHStreamDelta *)delta
       toAssembler:(DSHStreamResponseAssembler *)assembler {
  NSError *error = nil;
  XCTAssertTrue([assembler appendDelta:delta error:&error]);
  XCTAssertNil(error);
}

- (void)testToolCallFragmentsAcrossChunksCarryIdNameThenArgumentsOnly {
  DSHStreamEventParser *parser = [self parser];
  // The first fragment opens the call; later fragments stream argument bytes.
  NSString *first =
      @"data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,"
      @"\"id\":\"call_1\",\"type\":\"function\",\"function\":"
      @"{\"name\":\"read_file\",\"arguments\":\"\"}}]}}]}\n\n";
  NSString *second =
      @"data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,"
      @"\"function\":{\"arguments\":\"{\\\"pa\"}}]}}]}\n\n";
  NSString *third =
      @"data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,"
      @"\"function\":{\"arguments\":\"th\\\":1}\"}}]}}]}\n\n";
  NSMutableArray<NSDictionary *> *deltas = [NSMutableArray array];
  for (NSString *chunk in @[ first, second, third ]) {
    const char *c = chunk.UTF8String;
    NSError *error = nil;
    NSArray *batch = [parser appendBytes:(const uint8_t *)c length:strlen(c)
                                   error:&error];
    XCTAssertNil(error);
    XCTAssertEqual(batch.count, 1u);
    [deltas addObjectsFromArray:batch];
  }
  XCTAssertEqual(deltas.count, 3u);

  NSDictionary *opening = deltas[0][@"tool_calls"][0];
  XCTAssertEqualObjects(opening[@"index"], @0);
  XCTAssertEqualObjects(opening[@"id"], @"call_1");
  XCTAssertEqualObjects(opening[@"name"], @"read_file");
  // The empty arguments string is dropped; only index/id/name survive.
  XCTAssertNil(opening[@"arguments"]);

  NSDictionary *middle = deltas[1][@"tool_calls"][0];
  XCTAssertEqualObjects(middle[@"index"], @0);
  XCTAssertEqualObjects(middle[@"arguments"], @"{\"pa");
  XCTAssertNil(middle[@"id"]);
  XCTAssertNil(middle[@"name"]);

  NSDictionary *closing = deltas[2][@"tool_calls"][0];
  XCTAssertEqualObjects(closing[@"index"], @0);
  XCTAssertEqualObjects(closing[@"arguments"], @"th\":1}");
  XCTAssertNil(closing[@"id"]);
  XCTAssertNil(closing[@"name"]);
}

- (void)testParallelToolCallsInOneChunkAreKeptInOrder {
  DSHStreamEventParser *parser = [self parser];
  NSString *stream =
      @"data: {\"choices\":[{\"delta\":{\"tool_calls\":["
      @"{\"index\":0,\"id\":\"call_a\",\"function\":"
      @"{\"name\":\"alpha\",\"arguments\":\"{\\\"x\\\":\"}},"
      @"{\"index\":1,\"id\":\"call_b\",\"function\":{\"name\":\"beta\"}}"
      @"]}}]}\n\n";
  const char *c = stream.UTF8String;
  NSError *error = nil;
  NSArray *deltas = [parser appendBytes:(const uint8_t *)c length:strlen(c)
                                  error:&error];
  XCTAssertNil(error);
  XCTAssertEqual(deltas.count, 1u);
  NSArray *fragments = deltas[0][@"tool_calls"];
  XCTAssertEqual(fragments.count, 2u);
  XCTAssertEqualObjects(fragments[0][@"index"], @0);
  XCTAssertEqualObjects(fragments[0][@"id"], @"call_a");
  XCTAssertEqualObjects(fragments[0][@"name"], @"alpha");
  XCTAssertEqualObjects(fragments[0][@"arguments"], @"{\"x\":");
  XCTAssertEqualObjects(fragments[1][@"index"], @1);
  XCTAssertEqualObjects(fragments[1][@"id"], @"call_b");
  XCTAssertEqualObjects(fragments[1][@"name"], @"beta");
  XCTAssertNil(fragments[1][@"arguments"]);
}

- (void)testUnusableToolCallFragmentsFailClosedWith2106 {
  // Boolean index, fractional index, index 16, non-array tool_calls.
  NSString *booleanIndex =
      @"data: {\"choices\":[{\"delta\":{\"tool_calls\":"
      @"[{\"index\":true,\"id\":\"c\",\"function\":{\"name\":\"f\"}}]}}]}\n\n";
  NSString *fractionalIndex =
      @"data: {\"choices\":[{\"delta\":{\"tool_calls\":"
      @"[{\"index\":1.5,\"id\":\"c\",\"function\":{\"name\":\"f\"}}]}}]}\n\n";
  NSString *outOfRangeIndex =
      @"data: {\"choices\":[{\"delta\":{\"tool_calls\":"
      @"[{\"index\":16,\"id\":\"c\",\"function\":{\"name\":\"f\"}}]}}]}\n\n";
  NSString *nonArrayToolCalls =
      @"data: {\"choices\":[{\"delta\":"
      @"{\"tool_calls\":{\"index\":0,\"id\":\"c\"}}}]}\n\n";
  for (NSString *stream in @[ booleanIndex, fractionalIndex,
                              outOfRangeIndex, nonArrayToolCalls ]) {
    DSHStreamEventParser *parser = [self parser];
    const char *c = stream.UTF8String;
    NSError *error = nil;
    XCTAssertNil([parser appendBytes:(const uint8_t *)c length:strlen(c)
                               error:&error]);
    XCTAssertNotNil(error);
    XCTAssertEqual(error.domain, DSHStreamEventErrorDomain);
    XCTAssertEqual(error.code, 2106);
  }
}

- (void)testStreamedIdentityIsCapturedFromFirstChunkAndClearedByReset {
  DSHStreamEventParser *parser = [self parser];
  // The initial role-only chunk yields no delta, yet carries identity.
  NSString *roleChunk =
      @"data: {\"id\":\"chatcmpl-1\",\"model\":\"deepseek-v4-flash\","
      @"\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"\"}}]}\n\n";
  const char *c = roleChunk.UTF8String;
  NSError *error = nil;
  NSArray *deltas = [parser appendBytes:(const uint8_t *)c length:strlen(c)
                                  error:&error];
  XCTAssertNil(error);
  XCTAssertEqual(deltas.count, 0u);
  XCTAssertEqualObjects(parser.streamedResponseId, @"chatcmpl-1");
  XCTAssertEqualObjects(parser.streamedModel, @"deepseek-v4-flash");

  NSString *laterChunk =
      @"data: {\"id\":\"chatcmpl-2\",\"model\":\"deepseek-v4-other\","
      @"\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n";
  c = laterChunk.UTF8String;
  error = nil;
  deltas = [parser appendBytes:(const uint8_t *)c length:strlen(c)
                        error:&error];
  XCTAssertNil(error);
  XCTAssertEqual(deltas.count, 1u);
  // First non-empty identity wins; a later chunk does not overwrite it.
  XCTAssertEqualObjects(parser.streamedResponseId, @"chatcmpl-1");
  XCTAssertEqualObjects(parser.streamedModel, @"deepseek-v4-flash");

  [parser reset];
  XCTAssertNil(parser.streamedResponseId);
  XCTAssertNil(parser.streamedModel);
}

- (void)testAssemblerBuildsTextOnlyResponseWithReasoningWhenThinkingOn {
  DSHStreamResponseAssembler *assembler =
      [[DSHStreamResponseAssembler alloc] initWithThinkingMode:@"on"
                                                 maximumBytes:1024];
  [assembler noteResponseId:@"chatcmpl-9" model:@"deepseek-v4-flash"];
  [self appendDelta:@{@"type" : @"delta", @"reasoning" : @"Let me think. "}
      toAssembler:assembler];
  [self appendDelta:@{@"type" : @"delta", @"reasoning" : @"Beams."}
      toAssembler:assembler];
  [self appendDelta:@{@"type" : @"delta", @"content" : @"Hello "}
      toAssembler:assembler];
  [self appendDelta:@{@"type" : @"delta", @"content" : @"world."}
      toAssembler:assembler];
  [self appendDelta:@{@"type" : @"delta", @"finish_reason" : @"stop"}
      toAssembler:assembler];

  NSDictionary *response = assembler.responseObject;
  XCTAssertEqualObjects(response[@"id"], @"chatcmpl-9");
  XCTAssertEqualObjects(response[@"object"], @"chat.completion");
  XCTAssertEqualObjects(response[@"model"], @"deepseek-v4-flash");
  NSDictionary *choice = response[@"choices"][0];
  XCTAssertEqualObjects(choice[@"index"], @0);
  XCTAssertEqualObjects(choice[@"finish_reason"], @"stop");
  NSDictionary *message = choice[@"message"];
  XCTAssertEqualObjects(message[@"role"], @"assistant");
  XCTAssertEqualObjects(message[@"content"], @"Hello world.");
  XCTAssertEqualObjects(message[@"reasoning_content"], @"Let me think. Beams.");
  XCTAssertNil(message[@"tool_calls"]);
}

- (void)testAssemblerToolOnlyStreamYieldsNullContentAndFunctionCalls {
  DSHStreamResponseAssembler *assembler =
      [[DSHStreamResponseAssembler alloc] initWithThinkingMode:@"off"
                                                 maximumBytes:1024];
  [self appendDelta:@{@"type" : @"delta",
                      @"tool_calls" : @[@{@"index" : @0, @"id" : @"call_1",
                                          @"name" : @"read_file",
                                          @"arguments" : @"{\"pa"}]}
      toAssembler:assembler];
  [self appendDelta:@{@"type" : @"delta",
                      @"tool_calls" : @[@{@"index" : @0,
                                          @"arguments" : @"th\":1}"}]}
      toAssembler:assembler];
  [self appendDelta:@{@"type" : @"delta", @"finish_reason" : @"tool_calls"}
      toAssembler:assembler];

  NSDictionary *response = assembler.responseObject;
  XCTAssertEqualObjects(response[@"choices"][0][@"finish_reason"],
                        @"tool_calls");
  NSDictionary *message = response[@"choices"][0][@"message"];
  // A tool-only turn mirrors the single-shot shape: null content, and no
  // reasoning key because thinking is off and none was streamed.
  XCTAssertEqualObjects(message[@"content"], NSNull.null);
  XCTAssertNil(message[@"reasoning_content"]);
  NSArray *toolCalls = message[@"tool_calls"];
  XCTAssertEqual(toolCalls.count, 1u);
  XCTAssertEqualObjects(toolCalls[0][@"id"], @"call_1");
  XCTAssertEqualObjects(toolCalls[0][@"type"], @"function");
  XCTAssertEqualObjects(toolCalls[0][@"function"][@"name"], @"read_file");
  XCTAssertEqualObjects(toolCalls[0][@"function"][@"arguments"],
                        @"{\"path\":1}");
}

- (void)testAssemblerIncludesEmptyReasoningForToolCallsWhenThinkingOn {
  DSHStreamResponseAssembler *assembler =
      [[DSHStreamResponseAssembler alloc] initWithThinkingMode:@"on"
                                                 maximumBytes:1024];
  [self appendDelta:@{@"type" : @"delta",
                      @"tool_calls" : @[@{@"index" : @0, @"id" : @"call_1",
                                          @"name" : @"read_file",
                                          @"arguments" : @"{}"}]}
      toAssembler:assembler];
  NSDictionary *message = assembler.responseObject[@"choices"][0][@"message"];
  // No reasoning deltas arrived, but thinking is on → present and empty.
  XCTAssertEqualObjects(message[@"reasoning_content"], @"");
}

- (void)testAssemblerSortsToolCallsByIndexAndKeepsFirstId {
  DSHStreamResponseAssembler *assembler =
      [[DSHStreamResponseAssembler alloc] initWithThinkingMode:@"off"
                                                 maximumBytes:1024];
  // Index 1 opens before index 0; the response must still list 0 first.
  [self appendDelta:@{@"type" : @"delta",
                      @"tool_calls" : @[@{@"index" : @1, @"id" : @"call_b",
                                          @"name" : @"beta",
                                          @"arguments" : @"B1"}]}
      toAssembler:assembler];
  [self appendDelta:@{@"type" : @"delta",
                      @"tool_calls" : @[@{@"index" : @0, @"id" : @"call_a",
                                          @"name" : @"alpha",
                                          @"arguments" : @"A"}]}
      toAssembler:assembler];
  // A repeated id with a different value must not replace the first one.
  [self appendDelta:@{@"type" : @"delta",
                      @"tool_calls" : @[@{@"index" : @1, @"id" : @"call_z",
                                          @"arguments" : @"B2"}]}
      toAssembler:assembler];
  NSDictionary *message = assembler.responseObject[@"choices"][0][@"message"];
  NSArray *toolCalls = message[@"tool_calls"];
  XCTAssertEqual(toolCalls.count, 2u);
  XCTAssertEqualObjects(toolCalls[0][@"id"], @"call_a");
  XCTAssertEqualObjects(toolCalls[0][@"function"][@"name"], @"alpha");
  XCTAssertEqualObjects(toolCalls[0][@"function"][@"arguments"], @"A");
  XCTAssertEqualObjects(toolCalls[1][@"id"], @"call_b");
  XCTAssertEqualObjects(toolCalls[1][@"function"][@"name"], @"beta");
  XCTAssertEqualObjects(toolCalls[1][@"function"][@"arguments"], @"B1B2");
}

- (void)testAssemblerEnforcesTheByteBudgetWith2201 {
  DSHStreamResponseAssembler *assembler =
      [[DSHStreamResponseAssembler alloc] initWithThinkingMode:@"off"
                                                 maximumBytes:10];
  NSError *error = nil;
  // The delta is bound to a local: a multi-pair @{...} literal cannot be
  // inlined into an XCTAssert macro argument (the preprocessor splits it at
  // the comma, which only parentheses protect).
  DSHStreamDelta *oversized = @{@"type" : @"delta", @"content" : @"aaaaaaaaaaa"};
  XCTAssertFalse([assembler appendDelta:oversized error:&error]);
  XCTAssertNotNil(error);
  XCTAssertEqual(error.domain, DSHStreamAssemblerErrorDomain);
  XCTAssertEqual(error.code, 2201);
  XCTAssertEqual(assembler.accumulatedBytes, 0u);

  // Filling the budget across deltas fails on the overflowing delta only,
  // and the bytes of the rejected delta are not charged.
  DSHStreamResponseAssembler *stepped =
      [[DSHStreamResponseAssembler alloc] initWithThinkingMode:@"off"
                                                 maximumBytes:10];
  DSHStreamDelta *sixBytes = @{@"type" : @"delta", @"content" : @"aaaaaa"};
  DSHStreamDelta *fiveBytes = @{@"type" : @"delta", @"content" : @"bbbbb"};
  error = nil;
  XCTAssertTrue([stepped appendDelta:sixBytes error:&error]);
  XCTAssertNil(error);
  XCTAssertEqual(stepped.accumulatedBytes, 6u);
  error = nil;
  XCTAssertFalse([stepped appendDelta:fiveBytes error:&error]);
  XCTAssertNotNil(error);
  XCTAssertEqual(error.code, 2201);
  XCTAssertEqual(stepped.accumulatedBytes, 6u);
}

- (void)testAssemblerRejectsASeventeenthDistinctToolIndexWith2202 {
  DSHStreamResponseAssembler *assembler =
      [[DSHStreamResponseAssembler alloc] initWithThinkingMode:@"off"
                                                 maximumBytes:1024];
  for (NSInteger index = 0; index < 16; index += 1) {
    [self appendDelta:@{@"type" : @"delta",
                        @"tool_calls" : @[@{@"index" : @(index),
                                            @"id" : @"call",
                                            @"name" : @"tool",
                                            @"arguments" : @"{}"}]}
        toAssembler:assembler];
  }
  NSError *error = nil;
  DSHStreamDelta *seventeenth =
      @{@"type" : @"delta",
        @"tool_calls" : @[@{@"index" : @16, @"id" : @"call", @"name" : @"tool",
                            @"arguments" : @"{}"}]};
  XCTAssertFalse([assembler appendDelta:seventeenth error:&error]);
  XCTAssertNotNil(error);
  XCTAssertEqual(error.domain, DSHStreamAssemblerErrorDomain);
  XCTAssertEqual(error.code, 2202);
}

- (void)testAssemblerEmptyResponseHasNullIdentityAndEmptyContent {
  DSHStreamResponseAssembler *assembler =
      [[DSHStreamResponseAssembler alloc] initWithThinkingMode:@"off"
                                                 maximumBytes:16];
  NSDictionary *response = assembler.responseObject;
  XCTAssertEqualObjects(response[@"id"], NSNull.null);
  XCTAssertEqualObjects(response[@"model"], NSNull.null);
  XCTAssertEqualObjects(response[@"object"], @"chat.completion");
  NSDictionary *choice = response[@"choices"][0];
  XCTAssertEqualObjects(choice[@"finish_reason"], NSNull.null);
  NSDictionary *message = choice[@"message"];
  XCTAssertEqualObjects(message[@"role"], @"assistant");
  // No tool calls → content stays the empty string, not null.
  XCTAssertEqualObjects(message[@"content"], @"");
  XCTAssertNil(message[@"tool_calls"]);
  XCTAssertNil(message[@"reasoning_content"]);
}

- (void)testAssemblerIgnoresNonDeltaDictionaries {
  DSHStreamResponseAssembler *assembler =
      [[DSHStreamResponseAssembler alloc] initWithThinkingMode:@"off"
                                                 maximumBytes:16];
  NSError *error = nil;
  XCTAssertTrue([assembler appendDelta:@{@"type" : @"done"} error:&error]);
  XCTAssertNil(error);
  XCTAssertEqual(assembler.accumulatedBytes, 0u);
  NSDictionary *message = assembler.responseObject[@"choices"][0][@"message"];
  XCTAssertEqualObjects(message[@"content"], @"");
  XCTAssertNil(message[@"tool_calls"]);
}

// Claude (Anthropic Messages) and Codex (OpenAI Responses) streamed dialects.

- (ClaudeProviderTransport *)claudeTransport {
  return [[ClaudeProviderTransport alloc] initWithSession:nil
                                            uuidGenerator:nil
                                           monotonicClock:nil];
}

- (CodexProviderTransport *)codexTransport {
  return [[CodexProviderTransport alloc] initWithSession:nil
                                            uuidGenerator:nil
                                           monotonicClock:nil];
}

// Feeds one raw SSE chunk through a dialect parser, asserting a clean parse.
- (NSArray<NSDictionary *> *)feedChunk:(NSString *)chunk
                             toParser:(id<DSHProviderStreamEventParsing>)parser {
  const char *c = chunk.UTF8String;
  NSError *error = nil;
  NSArray<NSDictionary<NSString *, id> *> *deltas =
      [parser appendBytes:(const uint8_t *)c length:strlen(c) error:&error];
  XCTAssertNil(error);
  return deltas;
}

// Applies one parsed delta to a dialect assembler, asserting acceptance.
- (void)applyDelta:(DSHStreamDelta *)delta
      toAssembler:(id<DSHProviderStreamResponseAssembling>)assembler {
  NSError *error = nil;
  XCTAssertTrue([assembler appendDelta:delta error:&error]);
  XCTAssertNil(error);
}

- (void)testClaudeMessageStartSetsIdentityWithoutDeltaAndResetClearsIt {
  ClaudeStreamEventParser *parser = [[ClaudeStreamEventParser alloc] init];
  NSString *messageStart =
      @"event: message_start\n"
      @"data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_01\","
      @"\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-sonnet-5\","
      @"\"content\":[],\"stop_reason\":null,"
      @"\"usage\":{\"input_tokens\":12,\"output_tokens\":1}}}\n\n";
  NSArray<NSDictionary *> *deltas = [self feedChunk:messageStart toParser:parser];
  XCTAssertEqual(deltas.count, 0u);
  XCTAssertEqualObjects(parser.streamedResponseId, @"msg_01");
  XCTAssertEqualObjects(parser.streamedModel, @"claude-sonnet-5");

  // A later message_start must not overwrite the first-seen identity.
  NSString *laterStart =
      @"event: message_start\n"
      @"data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_02\","
      @"\"model\":\"claude-opus-5\"}}\n\n";
  deltas = [self feedChunk:laterStart toParser:parser];
  XCTAssertEqual(deltas.count, 0u);
  XCTAssertEqualObjects(parser.streamedResponseId, @"msg_01");
  XCTAssertEqualObjects(parser.streamedModel, @"claude-sonnet-5");

  [parser reset];
  XCTAssertNil(parser.streamedResponseId);
  XCTAssertNil(parser.streamedModel);
}

- (void)testClaudeToolUseBlocksStreamIdNameThenArgumentFragments {
  ClaudeStreamEventParser *parser = [[ClaudeStreamEventParser alloc] init];
  NSString *stream =
      @"event: content_block_start\n"
      @"data: {\"type\":\"content_block_start\",\"index\":1,"
      @"\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_01\","
      @"\"name\":\"write_file\",\"input\":{}}}\n\n"
      @"event: content_block_delta\n"
      @"data: {\"type\":\"content_block_delta\",\"index\":1,"
      @"\"delta\":{\"type\":\"input_json_delta\","
      @"\"partial_json\":\"{\\\"path\\\": \\\"notes.md\\\",\"}}\n\n"
      @"event: content_block_delta\n"
      @"data: {\"type\":\"content_block_delta\",\"index\":1,"
      @"\"delta\":{\"type\":\"input_json_delta\","
      @"\"partial_json\":\" \\\"content\\\": \\\"hi\\\"}\"}}\n\n"
      // A text block opening is not a tool fragment and stays silent.
      @"event: content_block_start\n"
      @"data: {\"type\":\"content_block_start\",\"index\":0,"
      @"\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n";
  NSArray<NSDictionary *> *deltas = [self feedChunk:stream toParser:parser];
  XCTAssertEqual(deltas.count, 3u);

  NSDictionary *opening = deltas[0][@"tool_calls"][0];
  XCTAssertEqualObjects(opening[@"index"], @1);
  XCTAssertEqualObjects(opening[@"id"], @"toolu_01");
  XCTAssertEqualObjects(opening[@"name"], @"write_file");
  XCTAssertNil(opening[@"arguments"]);

  NSDictionary *middle = deltas[1][@"tool_calls"][0];
  XCTAssertEqualObjects(middle[@"index"], @1);
  XCTAssertEqualObjects(middle[@"arguments"], @"{\"path\": \"notes.md\",");
  XCTAssertNil(middle[@"id"]);
  XCTAssertNil(middle[@"name"]);

  NSDictionary *closing = deltas[2][@"tool_calls"][0];
  XCTAssertEqualObjects(closing[@"index"], @1);
  XCTAssertEqualObjects(closing[@"arguments"], @" \"content\": \"hi\"}");
  XCTAssertNil(closing[@"id"]);
  XCTAssertNil(closing[@"name"]);
}

- (void)testClaudeUnusableToolFragmentsFailClosedWith2308 {
  NSString *missingId =
      @"event: content_block_start\n"
      @"data: {\"type\":\"content_block_start\",\"index\":1,"
      @"\"content_block\":{\"type\":\"tool_use\",\"name\":\"write_file\","
      @"\"input\":{}}}\n\n";
  NSString *missingIndex =
      @"event: content_block_delta\n"
      @"data: {\"type\":\"content_block_delta\","
      @"\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n";
  for (NSString *stream in @[ missingId, missingIndex ]) {
    ClaudeStreamEventParser *parser = [[ClaudeStreamEventParser alloc] init];
    const char *c = stream.UTF8String;
    NSError *error = nil;
    XCTAssertNil([parser appendBytes:(const uint8_t *)c length:strlen(c)
                               error:&error]);
    XCTAssertNotNil(error);
    XCTAssertEqualObjects(error.domain, @"ClaudeTransportError");
    XCTAssertEqual(error.code, 2308);
  }
}

- (void)testCodexCreatedSetsIdentityAndFunctionCallItemsStreamFragments {
  CodexStreamEventParser *parser = [[CodexStreamEventParser alloc] init];
  NSString *stream =
      @"event: response.created\n"
      @"data: {\"type\":\"response.created\",\"sequence_number\":0,"
      @"\"response\":{\"id\":\"resp_01\",\"object\":\"response\","
      @"\"status\":\"in_progress\",\"model\":\"gpt-5.6\",\"output\":[]}}\n\n"
      @"event: response.output_item.added\n"
      @"data: {\"type\":\"response.output_item.added\",\"sequence_number\":1,"
      @"\"output_index\":0,\"item\":{\"id\":\"fc_01\",\"type\":\"function_call\","
      @"\"status\":\"in_progress\",\"call_id\":\"call_01\","
      @"\"name\":\"write_file\",\"arguments\":\"\"}}\n\n"
      // A message item is not a tool fragment and stays silent.
      @"event: response.output_item.added\n"
      @"data: {\"type\":\"response.output_item.added\",\"sequence_number\":2,"
      @"\"output_index\":1,\"item\":{\"id\":\"msg_01\",\"type\":\"message\","
      @"\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n\n"
      @"event: response.function_call_arguments.delta\n"
      @"data: {\"type\":\"response.function_call_arguments.delta\","
      @"\"sequence_number\":3,\"item_id\":\"fc_01\",\"output_index\":0,"
      @"\"delta\":\"{\\\"path\\\":\\\"notes.md\\\",\"}\n\n"
      @"event: response.function_call_arguments.delta\n"
      @"data: {\"type\":\"response.function_call_arguments.delta\","
      @"\"sequence_number\":4,\"item_id\":\"fc_01\",\"output_index\":0,"
      @"\"delta\":\"\\\"content\\\":\\\"hi\\\"}\"}\n\n"
      // The .done event is terminal, not a delta source.
      @"event: response.function_call_arguments.done\n"
      @"data: {\"type\":\"response.function_call_arguments.done\","
      @"\"sequence_number\":5,\"item_id\":\"fc_01\",\"output_index\":0,"
      @"\"arguments\":\"{\\\"path\\\":\\\"notes.md\\\",\\\"content\\\":\\\"hi\\\"}\"}\n\n";
  NSArray<NSDictionary *> *deltas = [self feedChunk:stream toParser:parser];
  XCTAssertEqual(deltas.count, 3u);
  XCTAssertEqualObjects(parser.streamedResponseId, @"resp_01");
  XCTAssertEqualObjects(parser.streamedModel, @"gpt-5.6");

  NSDictionary *opening = deltas[0][@"tool_calls"][0];
  XCTAssertEqualObjects(opening[@"index"], @0);
  XCTAssertEqualObjects(opening[@"id"], @"call_01");
  XCTAssertEqualObjects(opening[@"name"], @"write_file");
  XCTAssertNil(opening[@"arguments"]);

  NSDictionary *middle = deltas[1][@"tool_calls"][0];
  XCTAssertEqualObjects(middle[@"index"], @0);
  XCTAssertEqualObjects(middle[@"arguments"], @"{\"path\":\"notes.md\",");
  XCTAssertNil(middle[@"id"]);
  XCTAssertNil(middle[@"name"]);

  NSDictionary *closing = deltas[2][@"tool_calls"][0];
  XCTAssertEqualObjects(closing[@"index"], @0);
  XCTAssertEqualObjects(closing[@"arguments"], @"\"content\":\"hi\"}");
  XCTAssertNil(closing[@"id"]);
  XCTAssertNil(closing[@"name"]);
}

- (void)testCodexFunctionCallItemWithoutCallIdFailsClosedWith3308 {
  CodexStreamEventParser *parser = [[CodexStreamEventParser alloc] init];
  NSString *stream =
      @"event: response.output_item.added\n"
      @"data: {\"type\":\"response.output_item.added\",\"sequence_number\":1,"
      @"\"output_index\":0,\"item\":{\"id\":\"fc_01\",\"type\":\"function_call\","
      @"\"status\":\"in_progress\",\"name\":\"write_file\",\"arguments\":\"\"}}\n\n";
  const char *c = stream.UTF8String;
  NSError *error = nil;
  XCTAssertNil([parser appendBytes:(const uint8_t *)c length:strlen(c)
                             error:&error]);
  XCTAssertNotNil(error);
  XCTAssertEqualObjects(error.domain, @"CodexTransportError");
  XCTAssertEqual(error.code, 3308);
}

- (void)testClaudeAssemblerBuildsMessagesShapeWithThinkingTextAndEndTurn {
  ClaudeProviderTransport *transport = [self claudeTransport];
  id<DSHProviderStreamResponseAssembling> assembler =
      [transport providerNewStreamResponseAssemblerWithThinkingMode:@"off"
                                                      maximumBytes:1024];
  [assembler noteResponseId:@"msg_01" model:@"claude-sonnet-5"];
  [self applyDelta:@{@"type" : @"delta", @"reasoning" : @"pondering"}
      toAssembler:assembler];
  [self applyDelta:@{@"type" : @"delta", @"content" : @"the answer"}
      toAssembler:assembler];
  [self applyDelta:@{@"type" : @"delta", @"finish_reason" : @"stop"}
      toAssembler:assembler];

  NSDictionary *response = assembler.responseObject;
  XCTAssertEqualObjects(response[@"type"], @"message");
  XCTAssertEqualObjects(response[@"role"], @"assistant");
  XCTAssertEqualObjects(response[@"id"], @"msg_01");
  XCTAssertEqualObjects(response[@"model"], @"claude-sonnet-5");
  XCTAssertEqualObjects(response[@"stop_reason"], @"end_turn");
  NSArray *content = response[@"content"];
  XCTAssertEqual(content.count, 2u);
  XCTAssertEqualObjects(content[0][@"type"], @"thinking");
  XCTAssertEqualObjects(content[0][@"thinking"], @"pondering");
  XCTAssertEqualObjects(content[1][@"type"], @"text");
  XCTAssertEqualObjects(content[1][@"text"], @"the answer");
}

- (void)testClaudeAssemblerToolRoundBuildsOneToolUseBlockWithParsedInput {
  ClaudeProviderTransport *transport = [self claudeTransport];
  id<DSHProviderStreamResponseAssembling> assembler =
      [transport providerNewStreamResponseAssemblerWithThinkingMode:@"off"
                                                      maximumBytes:1024];
  [self applyDelta:@{@"type" : @"delta",
                     @"tool_calls" : @[@{@"index" : @1, @"id" : @"toolu_01",
                                         @"name" : @"write_file"}]}
      toAssembler:assembler];
  [self applyDelta:@{@"type" : @"delta",
                     @"tool_calls" : @[@{@"index" : @1,
                                         @"arguments" : @"{\"path\": \"notes.md\", "}]}
      toAssembler:assembler];
  [self applyDelta:@{@"type" : @"delta",
                     @"tool_calls" : @[@{@"index" : @1,
                                         @"arguments" : @"\"content\": \"hi\"}"}]}
      toAssembler:assembler];
  [self applyDelta:@{@"type" : @"delta", @"finish_reason" : @"tool_calls"}
      toAssembler:assembler];

  NSDictionary *response = assembler.responseObject;
  XCTAssertEqualObjects(response[@"stop_reason"], @"tool_use");
  NSArray *content = response[@"content"];
  // Empty streamed text omits the text block; only the tool_use remains.
  XCTAssertEqual(content.count, 1u);
  NSDictionary *block = content[0];
  XCTAssertEqualObjects(block[@"type"], @"tool_use");
  XCTAssertEqualObjects(block[@"id"], @"toolu_01");
  XCTAssertEqualObjects(block[@"name"], @"write_file");
  NSDictionary *expectedInput = @{@"path" : @"notes.md", @"content" : @"hi"};
  XCTAssertEqualObjects(block[@"input"], expectedInput);
}

- (void)testClaudeAssemblerMapsUnparsableInputAndFinishReasonStops {
  ClaudeProviderTransport *transport = [self claudeTransport];
  // Unparsable arguments degrade input to NSNull, and a stream with no
  // finish is marked stream_incomplete for the response parser to reject.
  id<DSHProviderStreamResponseAssembling> broken =
      [transport providerNewStreamResponseAssemblerWithThinkingMode:@"off"
                                                      maximumBytes:1024];
  [self applyDelta:@{@"type" : @"delta",
                     @"tool_calls" : @[@{@"index" : @0, @"id" : @"toolu_02",
                                         @"name" : @"read_file",
                                         @"arguments" : @"{not json"}]}
      toAssembler:broken];
  NSDictionary *response = broken.responseObject;
  XCTAssertEqualObjects(response[@"stop_reason"], @"stream_incomplete");
  XCTAssertEqualObjects(response[@"content"][0][@"type"], @"tool_use");
  XCTAssertEqualObjects(response[@"content"][0][@"input"], NSNull.null);

  id<DSHProviderStreamResponseAssembling> truncated =
      [transport providerNewStreamResponseAssemblerWithThinkingMode:@"off"
                                                      maximumBytes:1024];
  [self applyDelta:@{@"type" : @"delta", @"finish_reason" : @"length"}
      toAssembler:truncated];
  XCTAssertEqualObjects(truncated.responseObject[@"stop_reason"], @"max_tokens");

  id<DSHProviderStreamResponseAssembling> refused =
      [transport providerNewStreamResponseAssemblerWithThinkingMode:@"off"
                                                      maximumBytes:1024];
  [self applyDelta:@{@"type" : @"delta", @"finish_reason" : @"content_filter"}
      toAssembler:refused];
  XCTAssertEqualObjects(refused.responseObject[@"stop_reason"], @"refusal");
}

- (void)testCodexAssemblerBuildsResponsesShapeWithReasoningSummaryAndText {
  CodexProviderTransport *transport = [self codexTransport];
  id<DSHProviderStreamResponseAssembling> assembler =
      [transport providerNewStreamResponseAssemblerWithThinkingMode:@"off"
                                                      maximumBytes:1024];
  [assembler noteResponseId:@"resp_09" model:@"gpt-5.6"];
  [self applyDelta:@{@"type" : @"delta", @"reasoning" : @"idea"}
      toAssembler:assembler];
  [self applyDelta:@{@"type" : @"delta", @"content" : @"answer"}
      toAssembler:assembler];
  [self applyDelta:@{@"type" : @"delta", @"finish_reason" : @"stop"}
      toAssembler:assembler];

  NSDictionary *response = assembler.responseObject;
  XCTAssertEqualObjects(response[@"object"], @"response");
  XCTAssertEqualObjects(response[@"id"], @"resp_09");
  XCTAssertEqualObjects(response[@"model"], @"gpt-5.6");
  XCTAssertEqualObjects(response[@"status"], @"completed");
  XCTAssertNil(response[@"incomplete_details"]);
  NSArray *output = response[@"output"];
  XCTAssertEqual(output.count, 2u);
  NSDictionary *reasoning = output[0];
  XCTAssertEqualObjects(reasoning[@"type"], @"reasoning");
  NSArray *summary = reasoning[@"summary"];
  XCTAssertEqual(summary.count, 1u);
  XCTAssertEqualObjects(summary[0][@"type"], @"summary_text");
  XCTAssertEqualObjects(summary[0][@"text"], @"idea");
  NSDictionary *message = output[1];
  XCTAssertEqualObjects(message[@"type"], @"message");
  XCTAssertEqualObjects(message[@"role"], @"assistant");
  NSArray *messageContent = message[@"content"];
  XCTAssertEqual(messageContent.count, 1u);
  XCTAssertEqualObjects(messageContent[0][@"type"], @"output_text");
  XCTAssertEqualObjects(messageContent[0][@"text"], @"answer");
}

- (void)testCodexAssemblerToolRoundBuildsFunctionCallItemWithJoinedArguments {
  CodexProviderTransport *transport = [self codexTransport];
  id<DSHProviderStreamResponseAssembling> assembler =
      [transport providerNewStreamResponseAssemblerWithThinkingMode:@"off"
                                                      maximumBytes:1024];
  [self applyDelta:@{@"type" : @"delta",
                     @"tool_calls" : @[@{@"index" : @0, @"id" : @"call_01",
                                         @"name" : @"write_file"}]}
      toAssembler:assembler];
  [self applyDelta:@{@"type" : @"delta",
                     @"tool_calls" : @[@{@"index" : @0,
                                         @"arguments" : @"{\"path\":\"notes.md\","}]}
      toAssembler:assembler];
  [self applyDelta:@{@"type" : @"delta",
                     @"tool_calls" : @[@{@"index" : @0,
                                         @"arguments" : @"\"content\":\"hi\"}"}]}
      toAssembler:assembler];
  [self applyDelta:@{@"type" : @"delta", @"finish_reason" : @"tool_calls"}
      toAssembler:assembler];

  NSDictionary *response = assembler.responseObject;
  XCTAssertEqualObjects(response[@"status"], @"completed");
  NSArray *output = response[@"output"];
  XCTAssertEqual(output.count, 1u);
  NSDictionary *item = output[0];
  XCTAssertEqualObjects(item[@"type"], @"function_call");
  XCTAssertEqualObjects(item[@"call_id"], @"call_01");
  XCTAssertEqualObjects(item[@"name"], @"write_file");
  XCTAssertEqualObjects(item[@"arguments"],
                        @"{\"path\":\"notes.md\",\"content\":\"hi\"}");
}

- (void)testCodexAssemblerMapsFinishReasonsToStatuses {
  CodexProviderTransport *transport = [self codexTransport];
  id<DSHProviderStreamResponseAssembling> truncated =
      [transport providerNewStreamResponseAssemblerWithThinkingMode:@"off"
                                                      maximumBytes:1024];
  [self applyDelta:@{@"type" : @"delta", @"finish_reason" : @"length"}
      toAssembler:truncated];
  NSDictionary *response = truncated.responseObject;
  XCTAssertEqualObjects(response[@"status"], @"incomplete");
  XCTAssertEqualObjects(response[@"incomplete_details"][@"reason"],
                        @"max_output_tokens");

  id<DSHProviderStreamResponseAssembling> refused =
      [transport providerNewStreamResponseAssemblerWithThinkingMode:@"off"
                                                      maximumBytes:1024];
  [self applyDelta:@{@"type" : @"delta", @"finish_reason" : @"content_filter"}
      toAssembler:refused];
  response = refused.responseObject;
  XCTAssertEqualObjects(response[@"status"], @"incomplete");
  XCTAssertEqualObjects(response[@"incomplete_details"][@"reason"],
                        @"content_filter");

  // No terminal event yet: the mid-stream snapshot stays in_progress.
  id<DSHProviderStreamResponseAssembling> open =
      [transport providerNewStreamResponseAssemblerWithThinkingMode:@"off"
                                                      maximumBytes:1024];
  [self applyDelta:@{@"type" : @"delta", @"content" : @"partial"}
      toAssembler:open];
  response = open.responseObject;
  XCTAssertEqualObjects(response[@"status"], @"in_progress");
  XCTAssertNil(response[@"incomplete_details"]);
}

- (void)testClaudeStreamedToolRoundSurvivesTheResponseParser {
  ClaudeProviderTransport *transport = [self claudeTransport];
  ClaudeStreamEventParser *parser = [[ClaudeStreamEventParser alloc] init];
  // The fixture round carries no identity; a message_start ahead of it does.
  NSString *messageStart =
      @"event: message_start\n"
      @"data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_01\","
      @"\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-sonnet-5\","
      @"\"content\":[],\"stop_reason\":null}}\n\n";
  NSString *fixture =
      @"event: content_block_start\n"
      @"data: {\"type\":\"content_block_start\",\"index\":0,"
      @"\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n"
      @"event: content_block_delta\n"
      @"data: {\"type\":\"content_block_delta\",\"index\":0,"
      @"\"delta\":{\"type\":\"text_delta\",\"text\":\"Writing the file.\"}}\n\n"
      @"event: content_block_start\n"
      @"data: {\"type\":\"content_block_start\",\"index\":1,"
      @"\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_01\","
      @"\"name\":\"write_file\",\"input\":{}}}\n\n"
      @"event: content_block_delta\n"
      @"data: {\"type\":\"content_block_delta\",\"index\":1,"
      @"\"delta\":{\"type\":\"input_json_delta\","
      @"\"partial_json\":\"{\\\"path\\\": \\\"notes.md\\\",\"}}\n\n"
      @"event: content_block_delta\n"
      @"data: {\"type\":\"content_block_delta\",\"index\":1,"
      @"\"delta\":{\"type\":\"input_json_delta\","
      @"\"partial_json\":\" \\\"content\\\": \\\"hi\\\"}\"}}\n\n"
      @"event: content_block_stop\n"
      @"data: {\"type\":\"content_block_stop\",\"index\":1}\n\n"
      @"event: message_delta\n"
      @"data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\","
      @"\"stop_sequence\":null},\"usage\":{\"output_tokens\":40}}\n\n"
      @"event: message_stop\n"
      @"data: {\"type\":\"message_stop\"}\n\n";
  NSMutableArray<NSDictionary *> *deltas = [NSMutableArray array];
  [deltas addObjectsFromArray:[self feedChunk:messageStart toParser:parser]];
  [deltas addObjectsFromArray:[self feedChunk:fixture toParser:parser]];
  NSError *error = nil;
  [deltas addObjectsFromArray:[parser finish:&error]];
  XCTAssertNil(error);
  XCTAssertEqual(deltas.count, 6u);

  id<DSHProviderStreamResponseAssembling> assembler =
      [transport providerNewStreamResponseAssemblerWithThinkingMode:@"off"
                                                      maximumBytes:1024];
  [assembler noteResponseId:parser.streamedResponseId
                       model:parser.streamedModel];
  for (NSDictionary *delta in deltas) {
    [self applyDelta:delta toAssembler:assembler];
  }
  NSData *data = [NSJSONSerialization dataWithJSONObject:assembler.responseObject
                                                options:0 error:&error];
  XCTAssertNotNil(data);
  XCTAssertNil(error);
  NSDictionary *fragment = [transport providerParseResponseData:data
                                                   requestedModel:@"claude-sonnet-5"
                                                     thinkingMode:@"off"
                                                           error:&error];
  XCTAssertNotNil(fragment);
  XCTAssertNil(error);
  XCTAssertEqualObjects(fragment[@"provider_response_id"], @"msg_01");
  XCTAssertEqualObjects(fragment[@"finish_reason"], @"tool_calls");
  NSArray *toolCalls = fragment[@"tool_calls"];
  XCTAssertEqual(toolCalls.count, 1u);
  XCTAssertEqualObjects(toolCalls[0][@"id"], @"toolu_01");
  XCTAssertEqualObjects(toolCalls[0][@"name"], @"write_file");
  // The tool input survives as canonical JSON: decode both sides to compare.
  NSData *expectedData = [NSJSONSerialization
      dataWithJSONObject:@{@"path" : @"notes.md", @"content" : @"hi"}
                  options:0 error:nil];
  id streamed = [NSJSONSerialization JSONObjectWithData:
      [toolCalls[0][@"arguments"] dataUsingEncoding:NSUTF8StringEncoding]
                                                options:0 error:nil];
  id expected = [NSJSONSerialization JSONObjectWithData:expectedData
                                                options:0 error:nil];
  XCTAssertEqualObjects(streamed, expected);
}

- (void)testCodexStreamedToolRoundSurvivesTheResponseParser {
  CodexProviderTransport *transport = [self codexTransport];
  CodexStreamEventParser *parser = [[CodexStreamEventParser alloc] init];
  NSString *fixture =
      @"event: response.output_item.added\n"
      @"data: {\"type\":\"response.output_item.added\",\"sequence_number\":1,"
      @"\"output_index\":0,\"item\":{\"id\":\"fc_01\",\"type\":\"function_call\","
      @"\"status\":\"in_progress\",\"call_id\":\"call_01\","
      @"\"name\":\"write_file\",\"arguments\":\"\"}}\n\n"
      @"event: response.function_call_arguments.delta\n"
      @"data: {\"type\":\"response.function_call_arguments.delta\","
      @"\"sequence_number\":2,\"item_id\":\"fc_01\",\"output_index\":0,"
      @"\"delta\":\"{\\\"path\\\":\\\"notes.md\\\",\"}\n\n"
      @"event: response.function_call_arguments.delta\n"
      @"data: {\"type\":\"response.function_call_arguments.delta\","
      @"\"sequence_number\":3,\"item_id\":\"fc_01\",\"output_index\":0,"
      @"\"delta\":\"\\\"content\\\":\\\"hi\\\"}\"}\n\n"
      @"event: response.function_call_arguments.done\n"
      @"data: {\"type\":\"response.function_call_arguments.done\","
      @"\"sequence_number\":4,\"item_id\":\"fc_01\",\"output_index\":0,"
      @"\"arguments\":\"{\\\"path\\\":\\\"notes.md\\\",\\\"content\\\":\\\"hi\\\"}\"}\n\n"
      @"event: response.completed\n"
      @"data: {\"type\":\"response.completed\",\"sequence_number\":5,"
      @"\"response\":{\"id\":\"resp_03\",\"object\":\"response\","
      @"\"status\":\"completed\",\"model\":\"gpt-5.6\",\"output\":[{\"id\":\"fc_01\","
      @"\"type\":\"function_call\",\"status\":\"completed\",\"call_id\":\"call_01\","
      @"\"name\":\"write_file\",\"arguments\":\"{\\\"path\\\":\\\"notes.md\\\","
      @"\\\"content\\\":\\\"hi\\\"}\"}]}}\n\n";
  NSMutableArray<NSDictionary *> *deltas = [NSMutableArray array];
  [deltas addObjectsFromArray:[self feedChunk:fixture toParser:parser]];
  NSError *error = nil;
  [deltas addObjectsFromArray:[parser finish:&error]];
  XCTAssertNil(error);
  XCTAssertEqual(deltas.count, 4u);
  XCTAssertEqualObjects(parser.streamedResponseId, @"resp_03");
  XCTAssertEqualObjects(parser.streamedModel, @"gpt-5.6");

  id<DSHProviderStreamResponseAssembling> assembler =
      [transport providerNewStreamResponseAssemblerWithThinkingMode:@"off"
                                                      maximumBytes:1024];
  [assembler noteResponseId:parser.streamedResponseId
                       model:parser.streamedModel];
  for (NSDictionary *delta in deltas) {
    [self applyDelta:delta toAssembler:assembler];
  }
  NSData *data = [NSJSONSerialization dataWithJSONObject:assembler.responseObject
                                                options:0 error:&error];
  XCTAssertNotNil(data);
  XCTAssertNil(error);
  NSDictionary *fragment = [transport providerParseResponseData:data
                                                   requestedModel:@"gpt-5.6"
                                                     thinkingMode:@"off"
                                                           error:&error];
  XCTAssertNotNil(fragment);
  XCTAssertNil(error);
  XCTAssertEqualObjects(fragment[@"provider_response_id"], @"resp_03");
  XCTAssertEqualObjects(fragment[@"finish_reason"], @"tool_calls");
  NSArray *toolCalls = fragment[@"tool_calls"];
  XCTAssertEqual(toolCalls.count, 1u);
  XCTAssertEqualObjects(toolCalls[0][@"id"], @"call_01");
  XCTAssertEqualObjects(toolCalls[0][@"name"], @"write_file");
  XCTAssertEqualObjects(toolCalls[0][@"arguments"],
                        @"{\"path\":\"notes.md\",\"content\":\"hi\"}");
}

@end
