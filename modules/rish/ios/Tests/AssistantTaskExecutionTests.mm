#import <XCTest/XCTest.h>
#import "AssistantTaskExecutor.h"
#import "AgentExecutionLedger.h"
#import "AgentPreparedAttemptStore.h"
#import "AgentToolBatchService.h"
#import "AgentToolExecutionService.h"
#import "AgentWorkspaceToolExecutor.h"

// The existing native fixture owns real WAL/transcript/approval services.
// Reuse those helpers without subclassing (which would rerun every base test).
@interface AgentToolEffectsTests : XCTestCase
@property(nonatomic, strong) DSHAgentNativeWAL *wal;
@property(nonatomic, strong) DSHAgentTranscriptStore *transcripts;
@property(nonatomic, strong) DSHAgentExecutionLedger *ledger;
@property(nonatomic, strong) NSNumber *assistantRegistryVersion;
@property(nonatomic, strong) NSURL *rootURL;
- (NSDictionary *)serviceFixtureForRawCalls:(NSArray *)calls;
- (NSDictionary *)serviceFixtureForRawCalls:(NSArray *)calls root:(NSDictionary *)root
                         workspaceExecutor:(DSHAgentWorkspaceToolExecutor *)executor;
- (NSDictionary *)rootWithCapabilities:(NSArray *)capabilities;
- (NSDictionary *)realWorkspaceServiceFixtureForRawCalls:(NSArray *)calls;
- (void)resetStoresWithFaultHook:(DSHAgentNativeWALFaultHook)faultHook name:(NSString *)name;
- (NSDictionary *)loadResultForSession:(NSDictionary *)session generation:(NSNumber *)generation digest:(NSString *)digest;
- (NSDictionary *)persistedCallForProjection:(NSDictionary *)call decision:(NSString *)decision reference:(id)reference;
- (NSDictionary *)approvalEventForCall:(NSDictionary *)call attempt:(NSString *)attempt eventId:(NSString *)eventId seq:(NSNumber *)seq;
- (NSDictionary *)bindRequestForFixture:(NSDictionary *)fixture receipt:(NSDictionary *)receipt call:(NSDictionary *)call
    operationId:(NSString *)operationId decision:(NSString *)decision denyMessage:(id)denyMessage;
- (NSDictionary *)executeRequestForFixture:(NSDictionary *)fixture receipt:(NSDictionary *)receipt call:(NSDictionary *)call
    operationId:(NSString *)operationId approvalReference:(id)reference;
- (NSDictionary *)sessionForFixture:(NSDictionary *)fixture phase:(NSString *)phase transcript:(NSDictionary *)transcript
    calls:(NSArray *)calls events:(NSArray *)events grants:(NSArray *)grants;
@end

@interface DSHAssistantTaskExecutor (NativeTestSeams)
- (id)invokeStore:(NSDictionary *)request error:(NSError **)error;
- (NSDictionary *)contextForConversation:(NSDictionary *)conversation request:(NSDictionary *)request error:(NSError **)error;
- (NSURL *)privateDirectory;
@end

/// Only the directory and response-loss seam are substituted. Every store
/// operation uses the production C ABI and Rust AssistantStore implementation.
@interface AssistantTaskRealStoreExecutor : DSHAssistantTaskExecutor
@property(nonatomic, strong) NSURL *fixtureDirectory;
@property(nonatomic) BOOL dropNextApplyReply;
@end
@implementation AssistantTaskRealStoreExecutor
- (NSURL *)privateDirectory { return self.fixtureDirectory; }
- (id)invokeStore:(NSDictionary *)request error:(NSError **)error {
  id result = [super invokeStore:request error:error];
  if (self.dropNextApplyReply && [request[@"action"] isEqual:@"apply"] && result != nil) {
    self.dropNextApplyReply = NO;
    return nil;
  }
  return result;
}
@end

/// A native authority fixture with only file_read. The Rust store remains real;
/// this boundary records and refuses any request for workspace write access.
@interface AssistantReadOnlyWorkspace : DSHLocalWorkspaceAccess
@property(nonatomic, copy) NSDictionary *metadata;
@property(nonatomic) NSUInteger deniedWriteProbes;
@end
@implementation AssistantReadOnlyWorkspace
- (NSDictionary *)resolveWorkspaceId:(NSString *)workspaceId expectedBindingRevision:(NSNumber *)revision
                 requiredCapabilities:(NSArray *)capabilities error:(NSError **)error {
  if ([capabilities containsObject:@"write"]) self.deniedWriteProbes += 1;
  if (![capabilities isEqual:@[@"read"]] || ![workspaceId isEqual:self.metadata[@"workspace_id"]] ||
      ![revision isEqual:self.metadata[@"binding_revision"]]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorConflict); return nil;
  }
  return @{@"workspace":self.metadata};
}
@end

@interface AssistantReadOnlyResolver : DSHAgentRootResolver
@property(nonatomic, copy) NSDictionary *readRoot;
@end
@implementation AssistantReadOnlyResolver
- (BOOL)validateFrozenRoot:(NSDictionary *)root error:(NSError **)error {
  if ([root isEqual:self.readRoot]) return YES;
  DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorConflict); return NO;
}
- (DSHLocalWorkspaceAuthorityMutationGuard *)acquireAuthorityMutationGuardForFrozenRoot:(NSDictionary *)root error:(NSError **)error {
  return [self validateFrozenRoot:root error:error] ? [DSHLocalWorkspaceAuthorityMutationGuard new] : nil;
}
- (BOOL)validateFrozenRoot:(NSDictionary *)root authorityMutationGuard:(DSHLocalWorkspaceAuthorityMutationGuard *)guard error:(NSError **)error {
  return guard != nil && [self validateFrozenRoot:root error:error];
}
@end

@interface AssistantTaskLedgerProbe : DSHAssistantTaskExecutor
@property(nonatomic, copy) NSString *authorizedID;
@property(nonatomic) NSUInteger storeCalls;
@property(nonatomic) NSUInteger effects;
@property(nonatomic) BOOL loseReply;
@property(nonatomic) BOOL rejectApply;
@property(nonatomic, copy) NSDictionary *receiptEffect;
@end

@implementation AssistantTaskLedgerProbe
- (NSDictionary *)contextForConversation:(NSDictionary *)conversation request:(NSDictionary *)request error:(NSError **)error {
  (void)conversation; (void)error;
  return @{@"conversation_id":request[@"conversation_id"], @"model_id":@"deepseek-v4-flash",
      @"workspace_binding":@{}, @"workspace_descriptor":@{}};
}
- (id)invokeStore:(NSDictionary *)request error:(NSError **)error {
  (void)error;
  self.storeCalls += 1;
  NSString *action = request[@"action"];
  if ([action isEqual:@"authorize"])
    return @{@"authorized":@([request[@"conversation_id"] isEqual:self.authorizedID])};
  if ([action isEqual:@"prepare"])
    return @{@"schema_version":@1, @"kind":request[@"name"],
        @"conversation_id":request[@"conversation_id"], @"arguments_sha256":request[@"arguments_sha256"],
        @"expected_store_revision":@0};
  if ([action isEqual:@"recover"]) return self.receiptEffect ?: (id)NSNull.null;
  if (![action isEqual:@"apply"]) return nil;
  if (self.rejectApply) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorConflict);
    return nil;
  }
  self.effects += 1;
  NSDictionary *payload = @{@"schema_version":@1,
      @"task_id":@"a0a0a0a0-a0a0-40a0-80a0-a0a0a0a0a0a0", @"store_revision":@1};
  NSDictionary *feedback = @{@"schema_version":@1, @"name":request[@"name"],
      @"outcome":@"ok", @"payload":payload};
  self.receiptEffect = @{@"schema_version":@1, @"status":@"ok", @"truncated":@NO,
      @"effect_may_have_occurred":@YES,
      @"feedback":[[NSString alloc] initWithData:DSHAgentCanonicalJSON(feedback, nil) encoding:NSUTF8StringEncoding],
      @"settled_facts":@{@"schema_version":@1, @"kind":request[@"name"],
        @"conversation_id":request[@"conversation_id"], @"arguments_sha256":request[@"arguments_sha256"],
        @"locator_sha256":DSHAgentHJ(@"assistant-tool-locator", request[@"locator"], nil),
        @"store_revision":@1, @"payload_sha256":DSHAgentHJ(@"assistant-tool-payload", payload, nil)}};
  if (self.loseReply) { self.loseReply = NO; return nil; }
  return self.receiptEffect;
}
@end

@implementation AgentToolEffectsTests (AssistantTasks)

- (NSDictionary *)assistantTaskFixture {
  NSDictionary *fixture = [self serviceFixtureForRawCalls:@[@{
      @"schema_version":@1, @"call_id":@"assistant-create", @"name":@"create_assistant_task",
      @"arguments_json":@"{\"title\":\"Follow up\",\"instructions\":\"Check the project\"}"}]];
  AssistantTaskLedgerProbe *probe = [[AssistantTaskLedgerProbe alloc] initWithRootResolver:fixture[@"resolver"]];
  probe.authorizedID = fixture[@"conversation"];
  [fixture[@"prepared_store"] setValue:probe forKey:@"assistantTaskExecutor"];
  NSMutableDictionary *result = [fixture mutableCopy]; result[@"assistant_probe"] = probe;
  return result;
}

- (NSDictionary *)assistantCommitDecision:(NSString *)decision fixture:(NSDictionary *)fixture receipt:(NSDictionary *)receipt {
  NSDictionary *call = receipt[@"calls"][0];
  NSString *marker = @"71717171-7171-4171-8171-717171717171";
  BOOL allowed = [decision hasPrefix:@"allow_"];
  NSArray *calls = @[[self persistedCallForProjection:call decision:decision reference:allowed ? marker : nil]];
  NSArray *events = @[[self approvalEventForCall:call attempt:fixture[@"attempt"] eventId:marker seq:@1]];
  NSArray *grants = @[];
  if ([decision isEqual:@"allow_conversation"]) {
    NSDictionary *root = fixture[@"root"];
    grants = @[@{@"schema_version":@2, @"grant_id":@"83838383-8383-4383-8383-838383838383",
        @"conversation_id":fixture[@"conversation"], @"workspace_id":root[@"workspace_id"],
        @"project_id":root[@"project_id"], @"binding_revision":root[@"workspace_binding_revision"],
        @"root_fingerprint_sha256":root[@"root_fingerprint_sha256"], @"tool_family":@"assistant_metadata",
        @"registry_version":@5, @"policy_version":@"agent-v1",
        @"issued_for":@{@"schema_version":@1, @"task_id":fixture[@"task"], @"attempt_id":fixture[@"attempt"]},
        @"created_at":@"2026-08-31T00:00:00.000Z"}];
  }
  NSDictionary *session = [self sessionForFixture:fixture phase:@"approval_pending"
      transcript:receipt[@"transcript"] calls:calls events:events grants:grants];
  [fixture[@"session_store"] setValue:[self loadResultForSession:session generation:@3
      digest:fixture[@"checkpoint"][@"session_sha256"]] forKey:@"fakeLoadResult"];
  NSError *error = nil;
  NSDictionary *bound = [fixture[@"batch_service"] bindAgentApprovalWithRequest:
      [self bindRequestForFixture:fixture receipt:receipt call:call operationId:marker
          decision:decision denyMessage:allowed ? nil : @"Do not create this task"] error:&error];
  XCTAssertNil(error); XCTAssertEqualObjects(bound[@"status"], @"bound");
  session = [self sessionForFixture:fixture phase:@"execution_intent"
      transcript:receipt[@"transcript"] calls:calls events:events grants:grants];
  [fixture[@"session_store"] setValue:[self loadResultForSession:session generation:@3
      digest:fixture[@"checkpoint"][@"session_sha256"]] forKey:@"fakeLoadResult"];
  return [self executeRequestForFixture:fixture receipt:receipt call:call
      operationId:@"74747474-7474-4474-8474-747474747474" approvalReference:allowed ? marker : nil];
}

- (DSHAgentToolExecutionService *)assistantExecutionForFixture:(NSDictionary *)fixture {
  return [[DSHAgentToolExecutionService alloc] initWithWAL:self.wal ledger:self.ledger
      preparedStore:fixture[@"prepared_store"] transcripts:self.transcripts
      workspaceExecutor:fixture[@"workspace_executor"] gitExecutor:fixture[@"git_executor"]];
}

- (void)testAssistantTaskOrdinaryRegistryDeniesBeforePrivateStore {
  self.assistantRegistryVersion = @4;
  NSDictionary *fixture = [self assistantTaskFixture];
  NSDictionary *result = [fixture[@"batch_service"] prepareAgentToolBatchWithRequest:fixture[@"batch_request"] error:nil];
  XCTAssertTrue(![result[@"status"] isEqual:@"prepared"] ||
      [result[@"receipt"][@"calls"][0][@"execution_status"] isEqual:@"denied"]);
  AssistantTaskLedgerProbe *probe = fixture[@"assistant_probe"];
  XCTAssertEqual(probe.storeCalls, 0U); XCTAssertEqual(probe.effects, 0U);
}

- (void)testAssistantTaskForgedConversationFailsNativeScope {
  self.assistantRegistryVersion = @5;
  NSDictionary *fixture = [self assistantTaskFixture];
  AssistantTaskLedgerProbe *probe = fixture[@"assistant_probe"];
  probe.authorizedID = @"ffffffff-ffff-4fff-8fff-ffffffffffff";
  NSDictionary *result = [fixture[@"batch_service"] prepareAgentToolBatchWithRequest:fixture[@"batch_request"] error:nil];
  XCTAssertNotEqualObjects(result[@"status"], @"prepared");
  XCTAssertEqual(probe.effects, 0U);
}

- (void)testAssistantTaskApprovedEffectSettlesAndReplaysOnce {
  self.assistantRegistryVersion = @5;
  NSDictionary *fixture = [self assistantTaskFixture];
  NSDictionary *prepared = [fixture[@"batch_service"] prepareAgentToolBatchWithRequest:fixture[@"batch_request"] error:nil];
  XCTAssertEqualObjects(prepared[@"status"], @"prepared", @"%@", prepared);
  if (![prepared[@"status"] isEqual:@"prepared"]) return;
  NSDictionary *request = [self assistantCommitDecision:@"allow_once" fixture:fixture receipt:prepared[@"receipt"]];
  DSHAgentToolExecutionService *execution = [self assistantExecutionForFixture:fixture];
  NSDictionary *result = [execution executeAgentToolWithRequest:request error:nil];
  XCTAssertEqualObjects(result[@"status"], @"completed", @"%@", result);
  XCTAssertEqualObjects([execution executeAgentToolWithRequest:request error:nil], result);
  AssistantTaskLedgerProbe *probe = fixture[@"assistant_probe"];
  XCTAssertEqual(probe.effects, 1U);
}

- (void)testAssistantTaskDeniedApprovalNeverDispatchesEffect {
  self.assistantRegistryVersion = @5;
  NSDictionary *fixture = [self assistantTaskFixture];
  NSDictionary *prepared = [fixture[@"batch_service"] prepareAgentToolBatchWithRequest:fixture[@"batch_request"] error:nil];
  XCTAssertEqualObjects(prepared[@"status"], @"prepared", @"%@", prepared);
  if (![prepared[@"status"] isEqual:@"prepared"]) return;
  NSDictionary *request = [self assistantCommitDecision:@"denied" fixture:fixture receipt:prepared[@"receipt"]];
  NSDictionary *result = [[self assistantExecutionForFixture:fixture] executeAgentToolWithRequest:request error:nil];
  XCTAssertNotEqualObjects(result[@"status"], @"completed");
  AssistantTaskLedgerProbe *probe = fixture[@"assistant_probe"];
  XCTAssertEqual(probe.effects, 0U);
  NSDictionary *row = [self.wal snapshotWithError:nil][@"ledger"][0];
  XCTAssertEqualObjects(row[@"receipt"][@"outcome"], @"denied");
  XCTAssertEqualObjects([self.wal dispatchStateForKind:@"execution" locator:row[@"locator"] error:nil], @"not_dispatched");
}

- (void)testAssistantTaskLostStoreReplyRecoversReceiptWithoutSecondEffect {
  self.assistantRegistryVersion = @5;
  NSDictionary *fixture = [self assistantTaskFixture];
  NSDictionary *prepared = [fixture[@"batch_service"] prepareAgentToolBatchWithRequest:fixture[@"batch_request"] error:nil];
  XCTAssertEqualObjects(prepared[@"status"], @"prepared", @"%@", prepared);
  if (![prepared[@"status"] isEqual:@"prepared"]) return;
  NSDictionary *request = [self assistantCommitDecision:@"allow_once" fixture:fixture receipt:prepared[@"receipt"]];
  AssistantTaskLedgerProbe *probe = fixture[@"assistant_probe"]; probe.loseReply = YES;
  DSHAgentToolExecutionService *execution = [self assistantExecutionForFixture:fixture];
  NSDictionary *first = [execution executeAgentToolWithRequest:request error:nil];
  XCTAssertEqualObjects(first[@"status"], @"ambiguous");
  NSDictionary *recovered = [execution recoverAgentToolWithRequest:request error:nil];
  XCTAssertEqualObjects(recovered[@"status"], @"completed", @"%@", recovered);
  XCTAssertEqualObjects([execution executeAgentToolWithRequest:request error:nil], recovered);
  XCTAssertEqual(probe.effects, 1U);
}

- (void)testAssistantTaskRevisionConflictSettlesDefiniteNoEffect {
  self.assistantRegistryVersion = @5;
  NSDictionary *fixture = [self assistantTaskFixture];
  NSDictionary *prepared = [fixture[@"batch_service"] prepareAgentToolBatchWithRequest:fixture[@"batch_request"] error:nil];
  XCTAssertEqualObjects(prepared[@"status"], @"prepared", @"%@", prepared);
  if (![prepared[@"status"] isEqual:@"prepared"]) return;
  NSDictionary *request = [self assistantCommitDecision:@"allow_once" fixture:fixture receipt:prepared[@"receipt"]];
  AssistantTaskLedgerProbe *probe = fixture[@"assistant_probe"]; probe.rejectApply = YES;
  NSDictionary *result = [[self assistantExecutionForFixture:fixture] executeAgentToolWithRequest:request error:nil];
  XCTAssertEqualObjects(result[@"status"], @"failed", @"%@", result);
  XCTAssertEqualObjects(result[@"effect_may_have_occurred"], @NO);
  XCTAssertEqualObjects(result[@"receipt"][@"failure_code"], @"E_AGENT_CONFLICT");
  XCTAssertEqual(probe.effects, 0U);
  XCTAssertEqualObjects([self.wal snapshotWithError:nil][@"ledger"][0][@"state"], @"settled");
}

- (void)assistantSetCommittedContext:(NSDictionary *)fixture {
  NSDictionary *load = [fixture[@"session_store"] valueForKey:@"fakeLoadResult"];
  NSMutableDictionary *session = [NSJSONSerialization JSONObjectWithData:
      [load[@"session_json"] dataUsingEncoding:NSUTF8StringEncoding]
      options:NSJSONReadingMutableContainers error:nil];
  NSMutableDictionary *conversation = session[@"conversations"][0];
  conversation[@"model_id"] = @"deepseek-v4-flash";
  conversation[@"workspace_binding"] = @{@"workspace_id":fixture[@"root"][@"workspace_id"],
      @"binding_revision":fixture[@"root"][@"workspace_binding_revision"],
      @"project_id":fixture[@"root"][@"project_id"]};
  [fixture[@"session_store"] setValue:[self loadResultForSession:session generation:@3
      digest:fixture[@"checkpoint"][@"session_sha256"]] forKey:@"fakeLoadResult"];
}

- (NSDictionary *)assistantSnapshotAt:(NSURL *)directory {
  NSData *data = [NSData dataWithContentsOfURL:[directory URLByAppendingPathComponent:@"assistant-v1.json"]];
  return data == nil ? nil : [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}

- (void)testAssistantMetadataApprovalOnReadOnlyRootCannotAuthorizeFileWrite {
  self.assistantRegistryVersion = @5;
  NSDictionary *root = [self rootWithCapabilities:@[@"file_read"]];
  NSDictionary *fixture = [self serviceFixtureForRawCalls:@[@{@"schema_version":@1,
      @"call_id":@"private-task", @"name":@"create_assistant_task",
      @"arguments_json":@"{\"title\":\"Read only follow up\",\"instructions\":\"Summarize changes\"}"}]
      root:root workspaceExecutor:nil];
  NSURL *directory = [[self.rootURL URLByAppendingPathComponent:@"ReadOnlyAssistant" isDirectory:YES] URLByResolvingSymlinksInPath];
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES
      attributes:@{NSFilePosixPermissions:@0700} error:nil]);
  NSDictionary *seed = @{@"schema_version":@1, @"revision":@0,
      @"profile":@{@"name":@"Read only assistant", @"notes":@"", @"soul":@"Be concise."},
      @"conversation_id":fixture[@"conversation"], @"tasks":@[], @"clock_high_water_ms":@0};
  XCTAssertTrue([DSHAgentCanonicalJSON(seed, nil) writeToURL:[directory URLByAppendingPathComponent:@"assistant-v1.json"] atomically:YES]);
  AssistantReadOnlyWorkspace *workspace = [[AssistantReadOnlyWorkspace alloc] initWithPrivateRootURL:directory
      clock:^NSDate *{ return NSDate.date; } UUIDGenerator:^NSString *{ return NSUUID.UUID.UUIDString; }
      legacyResolver:^BOOL(NSString *project, NSDictionary **evidence, NSError **error) {
        (void)project; (void)evidence; (void)error; return NO;
      } faultHook:nil];
  workspace.metadata = @{@"workspace_id":root[@"workspace_id"], @"binding_revision":root[@"workspace_binding_revision"],
      @"display_name":@"Read only workspace", @"capabilities":@[@"file_read"]};
  AssistantReadOnlyResolver *resolver = [[AssistantReadOnlyResolver alloc] initWithWorkspaceAccess:workspace projectAccess:nil];
  resolver.readRoot = root;
  AssistantTaskRealStoreExecutor *assistant = [[AssistantTaskRealStoreExecutor alloc] initWithRootResolver:resolver];
  assistant.fixtureDirectory = directory;
  [fixture[@"prepared_store"] setValue:assistant forKey:@"assistantTaskExecutor"];
  [self assistantSetCommittedContext:fixture];
  NSError *error = nil;
  NSDictionary *prepared = [fixture[@"batch_service"] prepareAgentToolBatchWithRequest:fixture[@"batch_request"] error:&error];
  XCTAssertNil(error); XCTAssertEqualObjects(prepared[@"status"], @"prepared", @"%@", prepared);
  if (![prepared[@"status"] isEqual:@"prepared"]) return;
  NSDictionary *call = prepared[@"receipt"][@"calls"][0], *preview = call[@"approval_preview"];
  XCTAssertEqualObjects(preview[@"title"], @"Read only follow up");
  XCTAssertEqualObjects(preview[@"content_preview"], @"Summarize changes");
  XCTAssertNil(preview[@"paths"]);
  XCTAssertEqualObjects([fixture[@"resolver"] valueForKey:@"lastRequiredCapabilities"], [NSSet setWithObject:@"file_read"]);
  XCTAssertEqualObjects([fixture[@"resolver"] valueForKey:@"projectWriteLeaseCount"], @0);
  NSDictionary *request = [self assistantCommitDecision:@"allow_conversation" fixture:fixture receipt:prepared[@"receipt"]];
  [self assistantSetCommittedContext:fixture];
  NSDictionary *grant = nil;
  for (NSDictionary *operation in [self.wal snapshotWithError:nil][@"operation_results"])
    if ([operation[@"operation_kind"] isEqual:@"bind_agent_approval"]) grant = operation[@"result"][@"result"][@"grant"];
  XCTAssertEqualObjects(grant[@"tool_family"], @"assistant_metadata");
  NSDictionary *result = [[self assistantExecutionForFixture:fixture] executeAgentToolWithRequest:request error:&error];
  XCTAssertNil(error); XCTAssertEqualObjects(result[@"status"], @"completed", @"%@", result);
  XCTAssertEqual([[self assistantSnapshotAt:directory][@"tasks"] count], 1U);
  XCTAssertEqual(workspace.deniedWriteProbes, 0U);

  [self resetStoresWithFaultHook:nil name:@"read-only-file-denial"];
  NSDictionary *fileFixture = [self serviceFixtureForRawCalls:@[@{@"schema_version":@1,
      @"call_id":@"forged-file-write", @"name":@"write_file",
      @"arguments_json":@"{\"path\":\"forbidden.txt\",\"content\":\"no\",\"expected_revision\":null}"}]
      root:root workspaceExecutor:nil];
  NSDictionary *load = [fileFixture[@"session_store"] valueForKey:@"fakeLoadResult"];
  NSMutableDictionary *session = [NSJSONSerialization JSONObjectWithData:[load[@"session_json"] dataUsingEncoding:NSUTF8StringEncoding]
      options:NSJSONReadingMutableContainers error:nil];
  if ([grant isKindOfClass:NSDictionary.class]) session[@"conversations"][0][@"agent_grants"] = @[grant];
  [fileFixture[@"session_store"] setValue:[self loadResultForSession:session generation:@3
      digest:fileFixture[@"checkpoint"][@"session_sha256"]] forKey:@"fakeLoadResult"];
  NSDictionary *denied = [fileFixture[@"batch_service"] prepareAgentToolBatchWithRequest:fileFixture[@"batch_request"] error:&error];
  XCTAssertNil(error);
  XCTAssertTrue(![denied[@"status"] isEqual:@"prepared"] ||
      [denied[@"receipt"][@"calls"][0][@"execution_status"] isEqual:@"denied"]);
  XCTAssertEqual([[self.wal snapshotWithError:nil][@"ledger"] count], 0U);
  XCTAssertEqualObjects([fileFixture[@"workspace_executor"] valueForKey:@"effectCount"], @0);
}

- (void)testAssistantTaskRealRustStoreCreateRecoverUpdateListThroughNativeLedger {
  self.assistantRegistryVersion = @5;
  NSURL *directory = [[self.rootURL URLByAppendingPathComponent:@"RustAssistant" isDirectory:YES]
      URLByResolvingSymlinksInPath];
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:directory
      withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil]);
  NSDictionary *seed = @{@"schema_version":@1, @"revision":@0,
      @"profile":@{@"name":@"Native Assistant", @"notes":@"Keep project follow ups concise.", @"soul":@"Be concise."},
      @"conversation_id":@"30303030-3030-4030-8030-303030303030", @"tasks":@[],
      @"tool_receipts":@[], @"clock_high_water_ms":@0};
  XCTAssertTrue([DSHAgentCanonicalJSON(seed, nil) writeToURL:
      [directory URLByAppendingPathComponent:@"assistant-v1.json"] atomically:YES]);
  NSString *createdID = nil;
  NSString *memoryID = nil;
  NSArray *names = @[@"create_assistant_task", @"update_assistant_task", @"list_assistant_tasks",
      @"remember_assistant_memory", @"search_assistant_memory", @"forget_assistant_memory"];
  NSArray *revisions = @[@1, @2, @2, @3, @3, @4];
  for (NSUInteger stage = 0; stage < names.count; stage += 1) {
    if (stage > 0) [self resetStoresWithFaultHook:nil name:[NSString stringWithFormat:@"assistant-real-%lu", (unsigned long)stage]];
    NSString *name = names[stage];
    NSDictionary *arguments = stage == 0 ? @{@"title":@"Project follow up", @"instructions":@"Inspect project changes"}
        : stage == 1 ? @{@"task_id":createdID, @"title":@"Updated follow up", @"paused":@YES}
        : stage == 3 ? @{@"title":@"Report style", @"content":@"Use concise bullet points.", @"kind":@"preference"}
        : stage == 4 ? @{@"query":@"concise", @"limit":@5}
        : stage == 5 ? @{@"memory_id":memoryID} : @{};
    NSString *argumentsJSON = [[NSString alloc] initWithData:DSHAgentCanonicalJSON(arguments, nil)
        encoding:NSUTF8StringEncoding];
    NSDictionary *fixture = [self realWorkspaceServiceFixtureForRawCalls:@[@{
        @"schema_version":@1, @"call_id":name, @"name":name, @"arguments_json":argumentsJSON}]];
    XCTAssertNotNil(fixture); if (fixture == nil) return;
    DSHAgentWorkspaceToolExecutor *workspace = fixture[@"workspace_executor"];
    AssistantTaskRealStoreExecutor *assistant = [[AssistantTaskRealStoreExecutor alloc]
        initWithRootResolver:workspace.rootResolver];
    assistant.fixtureDirectory = directory;
    [fixture[@"prepared_store"] setValue:assistant forKey:@"assistantTaskExecutor"];
    [self assistantSetCommittedContext:fixture];
    NSError *error = nil;
    NSDictionary *prepared = [fixture[@"batch_service"] prepareAgentToolBatchWithRequest:fixture[@"batch_request"] error:&error];
    XCTAssertNil(error); XCTAssertEqualObjects(prepared[@"status"], @"prepared", @"%@", prepared);
    if (![prepared[@"status"] isEqual:@"prepared"]) return;
    NSDictionary *receipt = prepared[@"receipt"], *call = receipt[@"calls"][0];
    NSDictionary *request = nil;
    if (DSHAgentIsAssistantMutationTool(name)) {
      request = [self assistantCommitDecision:@"allow_once" fixture:fixture receipt:receipt];
    } else {
      NSDictionary *session = [self sessionForFixture:fixture phase:@"execution_intent"
          transcript:receipt[@"transcript"] calls:@[[self persistedCallForProjection:call
            decision:@"auto" reference:nil]] events:@[] grants:@[]];
      [fixture[@"session_store"] setValue:[self loadResultForSession:session generation:@3
          digest:fixture[@"checkpoint"][@"session_sha256"]] forKey:@"fakeLoadResult"];
      NSMutableDictionary *readRequest = [[self executeRequestForFixture:fixture receipt:receipt call:call
          operationId:@"74747474-7474-4474-8474-747474747474" approvalReference:nil] mutableCopy];
      readRequest[@"batch_kind"] = receipt[@"batch_kind"];
      request = readRequest;
    }
    [self assistantSetCommittedContext:fixture];
    DSHAgentToolExecutionService *execution = [self assistantExecutionForFixture:fixture];
    assistant.dropNextApplyReply = stage == 0;
    NSDictionary *result = [execution executeAgentToolWithRequest:request error:&error];
    if (stage == 0) {
      XCTAssertEqualObjects(result[@"status"], @"ambiguous");
      // Recreate every WAL view with a new process-launch identity. Bootstrap
      // must preserve the dispatched mutation until the Rust receipt query.
      self.wal = [[DSHAgentNativeWAL alloc] initWithRootURL:self.wal.rootURL
          clock:^NSDate *{ return [NSDate dateWithTimeIntervalSince1970:1788134400]; }
          identifierGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; } faultHook:nil];
      XCTAssertTrue([self.wal ensureStorageWithError:&error]);
      NSDictionary *orphan = [self.wal snapshotWithError:nil][@"ledger"][0];
      XCTAssertEqualObjects(orphan[@"state"], @"running");
      XCTAssertEqualObjects(orphan[@"receipt"], NSNull.null);
      self.transcripts = [[DSHAgentTranscriptStore alloc] initWithWAL:self.wal];
      self.ledger = [[DSHAgentExecutionLedger alloc] initWithWAL:self.wal];
      DSHAgentPreparedAttemptStore *restored = [[DSHAgentPreparedAttemptStore alloc]
          initWithWAL:self.wal rootResolver:fixture[@"resolver"]
          sessionSnapshotStore:fixture[@"session_store"] transcriptStore:self.transcripts];
      [restored setValue:assistant forKey:@"assistantTaskExecutor"];
      execution = [[DSHAgentToolExecutionService alloc] initWithWAL:self.wal ledger:self.ledger
          preparedStore:restored transcripts:self.transcripts workspaceExecutor:workspace
          gitExecutor:fixture[@"git_executor"]];
      result = [execution recoverAgentToolWithRequest:request error:&error];
    }
    XCTAssertNil(error); XCTAssertEqualObjects(result[@"status"], @"completed", @"%@", result);
    if (![result[@"status"] isEqual:@"completed"]) return;
    NSDictionary *snapshot = [self assistantSnapshotAt:directory];
    XCTAssertEqual([snapshot[@"tasks"] count], 1U);
    XCTAssertEqualObjects(snapshot[@"revision"], revisions[stage]);
    XCTAssertEqual([snapshot[@"tool_receipts"] count], [revisions[stage] unsignedIntegerValue]);
    NSDictionary *task = snapshot[@"tasks"][0];
    if (stage == 0) createdID = task[@"id"];
    XCTAssertEqualObjects(task[@"model_id"], @"deepseek-v4-flash");
    XCTAssertEqualObjects(task[@"workspace_binding"][@"workspace_id"], fixture[@"root"][@"workspace_id"]);
    if (stage > 0) {
      XCTAssertEqualObjects(task[@"title"], @"Updated follow up");
      XCTAssertEqualObjects(task[@"enabled"], @NO);
    }
    if (stage == 3 || stage == 4) {
      XCTAssertEqual([snapshot[@"memories"] count], 1U);
      NSDictionary *memory = snapshot[@"memories"][0];
      memoryID = memory[@"id"];
      XCTAssertEqualObjects(memory[@"source_conversation_id"], fixture[@"conversation"]);
      XCTAssertEqualObjects(memory[@"content"], @"Use concise bullet points.");
    }
    if (stage == 5) XCTAssertEqual([snapshot[@"memories"] count], 0U);
    XCTAssertEqualObjects(snapshot[@"profile"], seed[@"profile"]);
    XCTAssertEqualObjects([execution executeAgentToolWithRequest:request error:nil], result);
    XCTAssertEqualObjects([self assistantSnapshotAt:directory], snapshot);
    NSDictionary *row = [self.wal snapshotWithError:nil][@"ledger"][0];
    XCTAssertEqualObjects(row[@"state"], @"settled");
    XCTAssertEqualObjects(row[@"settled_facts"][@"kind"], name);
  }
}
@end
