#import <XCTest/XCTest.h>

#import "AgentNativeWAL.h"
#import "AgentToolBatchService.h"
#import "AgentTranscriptStore.h"
#import "AgentWorkspaceToolExecutor.h"
#import "DSHCompletionV2.h"

// Reuse the existing real workspace and durable batch fixture without adding
// more unrelated helpers to the large AgentToolEffectsTests implementation.
@interface AgentToolEffectsTests : XCTestCase
@property(nonatomic, strong) NSURL *rootURL;
@property(nonatomic, strong) DSHAgentNativeWAL *wal;
@property(nonatomic, strong) DSHAgentTranscriptStore *transcripts;
- (NSDictionary *)realWorkspaceServiceFixtureForRawCalls:(NSArray<NSDictionary *> *)calls;
- (NSDictionary *)feedbackObject:(NSDictionary *)effect;
@end

@interface AgentToolEffectsTests (WriteRevision)
@end

@implementation AgentToolEffectsTests (WriteRevision)

- (NSDictionary *)writeRevisionRunRepairNamed:(NSString *)name
                                    arguments:(NSDictionary *)arguments
                                      callID:(NSString *)callID
                                       round:(NSUInteger)round
                                     fixture:(NSDictionary *)fixture
                                  transcript:(NSDictionary **)transcript {
  NSString *code = nil;
  NSString *reason = nil;
  XCTAssertTrue(DSHAgentToolArgumentsAccepted(name, arguments, &code, &reason),
                @"%@ / %@", code, reason);
  NSError *error = nil;
  NSData *bytes = DSHAgentCanonicalJSON(arguments, &error);
  NSString *json = [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
  *transcript = [self.transcripts appendAssistantMessage:@{
    @"schema_version":@1, @"role":@"assistant", @"round_index":@(round),
    @"content":@"", @"reasoning_content":@"", @"tool_calls":@[@{
      @"schema_version":@1, @"call_id":callID, @"name":name, @"arguments_json":json,
    }],
  } expectedTranscript:*transcript root:fixture[@"root"]
      attemptId:fixture[@"attempt"] error:&error];
  XCTAssertNotNil(*transcript, @"%@", error);
  XCTAssertNil(error);
  if (*transcript == nil) return nil;

  DSHAgentWorkspaceToolExecutor *executor = fixture[@"workspace_executor"];
  NSDictionary *prepared = [executor prepareToolNamed:name arguments:arguments
      root:fixture[@"root"] error:&error];
  XCTAssertNotNil(prepared, @"%@", error);
  XCTAssertNil(error);
  if (prepared == nil) return nil;
  NSDictionary *effect = [executor executeToolNamed:name arguments:arguments
      root:fixture[@"root"] precondition:prepared[@"precondition"] error:&error];
  XCTAssertNotNil(effect, @"%@", error);
  XCTAssertNil(error);
  XCTAssertEqualObjects(effect[@"status"], @"ok");
  if (effect == nil) return nil;
  *transcript = [self.transcripts appendToolMessage:@{
    @"schema_version":@1, @"role":@"tool", @"round_index":@(round),
    @"call_id":callID, @"content":effect[@"feedback"], @"truncated":@NO,
  } expectedTranscript:*transcript root:fixture[@"root"]
      attemptId:fixture[@"attempt"] error:&error];
  XCTAssertNotNil(*transcript, @"%@", error);
  XCTAssertNil(error);
  return [self feedbackObject:effect][@"payload"];
}

- (void)testPlaceholderWriteRevisionsSettleThenRepairCreateReadAndUpdate {
  NSMutableArray *rawCalls = [NSMutableArray array];
  for (NSString *placeholder in @[@"null", @"undefined"]) {
    NSDictionary *arguments = @{@"path":@"repair.txt", @"content":@"bad",
                                @"expected_revision":placeholder};
    NSString *json = [[NSString alloc] initWithData:DSHAgentCanonicalJSON(arguments, nil)
                                         encoding:NSUTF8StringEncoding];
    // Durable call identity still accepts the historical argument object.
    XCTAssertNotNil(DSHAgentArgumentsSHA256(@"write_file", json, nil));
    NSString *code = nil;
    NSString *reason = nil;
    XCTAssertFalse(DSHAgentToolArgumentsAccepted(@"write_file", arguments, &code, &reason));
    XCTAssertEqualObjects(code, @"E_AGENT_BAD_ARGUMENTS");
    XCTAssertEqualObjects(reason,
        @"expected_revision_must_be_json_null_or_a_read_file_revision");
    [rawCalls addObject:@{@"schema_version":@1,
      @"call_id":[@"bad-" stringByAppendingString:placeholder],
      @"name":@"write_file", @"arguments_json":json}];
  }
  NSDictionary *fixture = [self realWorkspaceServiceFixtureForRawCalls:rawCalls];
  XCTAssertNotNil(fixture);
  if (fixture == nil) return;
  NSError *error = nil;
  NSDictionary *result = [fixture[@"batch_service"]
      prepareAgentToolBatchWithRequest:fixture[@"batch_request"] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"prepared", @"%@", result);
  if (![result[@"status"] isEqual:@"prepared"]) return;
  XCTAssertEqualObjects(result[@"receipt"][@"effect_gate"], @"not_applicable");
  for (NSDictionary *call in result[@"receipt"][@"calls"]) {
    XCTAssertEqualObjects(call[@"execution_status"], @"failed");
    XCTAssertEqualObjects(call[@"receipt"][@"failure_code"], @"E_AGENT_BAD_ARGUMENTS");
    XCTAssertEqualObjects(call[@"receipt"][@"outcome"], @"failed");
  }
  NSDictionary *state = [self.wal snapshotWithError:&error];
  XCTAssertNil(error);
  XCTAssertEqual([state[@"ledger"] count], 0U);
  XCTAssertEqualObjects(state[@"authorities"][0][@"state"], @"prepared");
  XCTAssertEqualObjects(state[@"authorities"][0][@"reserved_write_bytes"], @0);
  NSURL *file = [self.rootURL URLByAppendingPathComponent:
      @"ServiceDocuments/Rish Workspaces/Service/repair.txt"];
  XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:file.path]);

  // Reopen the actual protected WAL before fixing the call. Strict admission
  // of a new call must not make old rejected arguments/transcripts unreadable.
  DSHAgentNativeWAL *reopened = [[DSHAgentNativeWAL alloc] initWithRootURL:self.rootURL
      clock:^NSDate * { return [NSDate dateWithTimeIntervalSince1970:1788134400]; }
      identifierGenerator:^NSString * { return @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"; }
      faultHook:nil];
  XCTAssertNotNil([reopened snapshotWithError:&error]);
  XCTAssertNil(error);
  self.wal = reopened;
  self.transcripts = [[DSHAgentTranscriptStore alloc] initWithWAL:reopened];
  NSDictionary *transcript = result[@"receipt"][@"transcript"];
  NSArray *messages = [self.transcripts nativeMessagesForTranscriptWithRequest:@{
    @"schema_version":@1, @"attempt_id":fixture[@"attempt"], @"root":fixture[@"root"],
    @"transcript":transcript,
  } error:&error];
  XCTAssertNil(error);
  XCTAssertEqual(messages.count, 3U);
  XCTAssertTrue([messages.lastObject[@"content"] containsString:
      @"expected_revision_must_be_json_null_or_a_read_file_revision"]);
  for (NSUInteger index = 0; index < 2; ++index) {
    NSDictionary *arguments = DSHAgentParseArgumentsJSON(
        messages[0][@"tool_calls"][index][@"arguments_json"], &error);
    XCTAssertEqualObjects(arguments[@"expected_revision"], (@[@"null", @"undefined"][index]));
  }

  // The model can correct an omitted revision to create-only JSON null. The
  // following calls use the same native root, attempt, and reopened transcript.
  NSDictionary *normalized = DSHCompletionNormalizeToolCalls(@[@{
    @"id":@"repair-create", @"name":@"write_file",
    @"arguments":@"{\"path\":\"repair.txt\",\"content\":\"created\\n\"}",
  }]).firstObject;
  NSDictionary *create = DSHAgentParseArgumentsJSON(normalized[@"arguments"], &error);
  XCTAssertEqualObjects(create[@"expected_revision"], NSNull.null);
  NSDictionary *created = [self writeRevisionRunRepairNamed:@"write_file"
      arguments:create callID:@"repair-create" round:1 fixture:fixture transcript:&transcript];
  XCTAssertNotNil(created);
  NSDictionary *read = [self writeRevisionRunRepairNamed:@"read_file"
      arguments:@{@"path":@"repair.txt"} callID:@"repair-read" round:2
      fixture:fixture transcript:&transcript];
  XCTAssertEqualObjects(read[@"content"], @"created\n");
  NSString *revision = read[@"revision"];
  XCTAssertTrue([revision isKindOfClass:NSString.class]);
  XCTAssertEqual([revision componentsSeparatedByString:@":"].count, 5U);
  if (revision == nil) return;
  NSDictionary *updated = [self writeRevisionRunRepairNamed:@"write_file"
      arguments:@{@"path":@"repair.txt", @"content":@"updated\n", @"expected_revision":revision}
      callID:@"repair-update" round:3 fixture:fixture transcript:&transcript];
  XCTAssertNotNil(updated);
  XCTAssertEqualObjects([NSData dataWithContentsOfURL:file],
                        [@"updated\n" dataUsingEncoding:NSUTF8StringEncoding]);
  messages = [self.transcripts nativeMessagesForTranscriptWithRequest:@{
    @"schema_version":@1, @"attempt_id":fixture[@"attempt"], @"root":fixture[@"root"],
    @"transcript":transcript,
  } error:&error];
  XCTAssertNil(error);
  XCTAssertEqual(messages.count, 9U);
  XCTAssertEqualObjects([self.wal snapshotWithError:&error][@"authorities"][0][@"state"], @"prepared");
}

@end
