#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import "AgentExecutionLedger.h"
#import "AgentGitToolExecutor.h"
#import "AgentPreparedAttemptStore.h"
#import "AgentRootResolver.h"
#import "AgentToolBatchService.h"
#import "AgentToolRegistry.h"
#import "AgentTranscriptStore.h"
#import "AgentWorkspaceToolExecutor.h"

// Shared real-WAL fixture. Keeping this construction separate lets the new
// assistant cases extend authority versions without growing the legacy suite.
@interface AgentToolEffectsTests : XCTestCase
@property(nonatomic, strong) DSHAgentNativeWAL *wal;
@property(nonatomic, strong) DSHAgentTranscriptStore *transcripts;
@property(nonatomic, strong) DSHAgentExecutionLedger *ledger;
- (NSDictionary *)projectRootWithCapabilities:(NSArray *)capabilities;
- (NSDictionary *)loadResultForSession:(NSDictionary *)session generation:(NSNumber *)generation digest:(NSString *)digest;
@end
@interface AgentToolEffectsTests (SharedFixture)
@property(nonatomic, strong) NSNumber *assistantRegistryVersion;
@end
@interface AgentEffectsRootResolver : DSHAgentRootResolver
- (instancetype)initWithRoot:(NSDictionary *)root;
@end
@interface AgentEffectsSessionStore : DSHSessionSnapshotStore
- (instancetype)initWithLoadResult:(NSDictionary *)load;
@end
@interface AgentEffectsPreparedStore : DSHAgentPreparedAttemptStore
@end
@interface AgentEffectsWorkspaceExecutor : DSHAgentWorkspaceToolExecutor
@end
@interface AgentEffectsGitExecutor : DSHAgentGitToolExecutor
@end

@interface AssistantFixtureRootResolver : AgentEffectsRootResolver
@property(nonatomic, copy) NSSet<NSString *> *lastRequiredCapabilities;
@property(nonatomic) NSUInteger projectWriteLeaseCount;
@end
@implementation AssistantFixtureRootResolver
- (DSHLocalWorkspaceLease *)workspaceLeaseForFrozenRoot:(NSDictionary *)root
    requiredWorkspaceCapabilities:(NSSet<NSString *> *)capabilities error:(NSError **)error {
  self.lastRequiredCapabilities = capabilities;
  return [super workspaceLeaseForFrozenRoot:root requiredWorkspaceCapabilities:capabilities error:error];
}
- (DSHLocalProjectLease *)projectLeaseForFrozenRoot:(NSDictionary *)root
    mode:(DSHLocalProjectAccessMode)mode timeout:(NSTimeInterval)timeout error:(NSError **)error {
  if (mode == DSHLocalProjectAccessModeWrite) self.projectWriteLeaseCount += 1;
  return [super projectLeaseForFrozenRoot:root mode:mode timeout:timeout error:error];
}
@end

static char AssistantFixtureRegistryKey;
@implementation AgentToolEffectsTests (SharedFixture)
- (NSNumber *)assistantRegistryVersion { return objc_getAssociatedObject(self, &AssistantFixtureRegistryKey); }
- (void)setAssistantRegistryVersion:(NSNumber *)version {
  objc_setAssociatedObject(self, &AssistantFixtureRegistryKey, version, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSDictionary *)serviceFixtureForRawCalls:(NSArray<NSDictionary *> *)rawCalls
                                       root:(NSDictionary *)explicitRoot
                          workspaceExecutor:
                              (DSHAgentWorkspaceToolExecutor *)explicitExecutor {
  NSString *task = @"10101010-1010-4010-8010-101010101010";
  NSString *attempt = @"20202020-2020-4020-8020-202020202020";
  NSString *conversation = @"30303030-3030-4030-8030-303030303030";
  NSString *roundID = @"40404040-4040-4040-8040-404040404040";
  NSString *authorityOperation = @"50505050-5050-4050-8050-505050505050";
  NSString *sessionDigest =
      @"abababababababababababababababababababababababababababababababab";
  NSMutableSet *capabilities = [NSMutableSet set];
  for (NSDictionary *call in rawCalls) {
    NSString *name = call[@"name"];
    if ([name isEqualToString:@"write_file"]) [capabilities addObject:@"file_write"];
    if ([name isEqualToString:@"read_file"] || [name isEqualToString:@"list_dir"])
      [capabilities addObject:@"file_read"];
    if ([name hasPrefix:@"git_"]) [capabilities addObject:name];
    if ([name isEqual:@"list_assistant_tasks"] || [name isEqual:@"search_assistant_memory"])
      [capabilities addObject:@"file_read"];
    if ([name isEqual:@"create_assistant_task"] || [name isEqual:@"update_assistant_task"] ||
        [name isEqual:@"remember_assistant_memory"] || [name isEqual:@"forget_assistant_memory"])
      [capabilities addObject:@"file_read"];
  }
  NSDictionary *root = explicitRoot ?: [self projectRootWithCapabilities:
      [[capabilities allObjects] sortedArrayUsingSelector:@selector(compare:)]];
  NSError *error = nil;
  NSDictionary *before = [self.transcripts createAgentTranscriptWithRequest:@{
    @"schema_version" : @1, @"attempt_id" : attempt, @"root" : root,
  } error:&error];
  XCTAssertNotNil(before);
  NSMutableArray *assistantCalls = [NSMutableArray arrayWithCapacity:rawCalls.count];
  for (NSDictionary *raw in rawCalls) {
    [assistantCalls addObject:@{ @"schema_version" : @1,
      @"call_id" : raw[@"call_id"], @"name" : raw[@"name"],
      @"arguments_json" : raw[@"arguments_json"] }];
  }
  NSDictionary *after = [self.transcripts appendAssistantMessage:@{
    @"schema_version" : @1, @"role" : @"assistant", @"round_index" : @0,
    @"content" : @"", @"reasoning_content" : @"", @"tool_calls" : assistantCalls,
  } expectedTranscript:before root:root attemptId:attempt error:&error];
  XCTAssertNotNil(after);
  DSHAgentToolRegistry *toolRegistry = [[DSHAgentToolRegistry alloc] init];
  NSDictionary *registry = self.assistantRegistryVersion == nil
      ? [toolRegistry registryForRoot:root error:&error]
      : [toolRegistry registryForRoot:root version:self.assistantRegistryVersion error:&error];
  NSDictionary *policy = [toolRegistry policyForRoot:root error:&error];
  NSString *now = [self.wal currentTimestamp];
  NSMutableDictionary *authority = [@{
    @"schema_version" : @2, @"task_id" : task,
    @"conversation_id" : conversation, @"attempt_id" : attempt,
    @"root" : root, @"policy" : policy, @"registry" : registry,
    @"transport_schema_version" : @2, @"model" : @"deepseek-v4-flash",
    @"thinking_mode" : @"off", @"visible_message_ids" : @[],
    @"visible_history_sha256" :
        @"cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd",
    @"visible_message_count" : @0, @"project_context_sha256" : NSNull.null,
    @"transcript" : after, @"reserved_write_bytes" : @0,
    @"authority_revision" : @1, @"state" : @"prepared",
    @"cleanup_id" : NSNull.null, @"created_at" : now, @"updated_at" : now,
  } mutableCopy];
  if ([self.assistantRegistryVersion isEqual:@5]) {
    authority[@"assistant_context"] = @{@"schema_version":@1, @"conversation_id":conversation,
        @"profile_revision":@0, @"name":@"Assistant", @"notes":@"Native ledger test", @"soul":@"Be concise."};
  }
  NSDictionary *authorityRequest = @{
    @"schema_version" : @2, @"operation_id" : authorityOperation,
    @"task_id" : task, @"conversation_id" : conversation,
    @"attempt_id" : attempt,
  };
  NSDictionary *authoritySafe = @{
    @"schema_version" : @2, @"result_kind" : @"prepare_agent_attempt",
    @"result" : @{ @"schema_version" : @2, @"status" : @"prepared",
                    @"operation_id" : authorityOperation },
  };
  XCTAssertNotNil(DSHAgentNativeWALPrepareAuthorityOperation(
      self.wal, authority, authorityRequest, authoritySafe, &error));

  NSMutableArray *presentations = [NSMutableArray array];
  NSUInteger deniedCallCount = 0;
  for (NSUInteger index = 0; index < rawCalls.count; index += 1) {
    NSDictionary *raw = rawCalls[index];
    NSDictionary *descriptor = [toolRegistry descriptorForToolName:raw[@"name"]
        root:root registry:registry error:&error];
    BOOL denied = [descriptor[@"access"] isEqual:@"durable_deny"];
    if (denied) deniedCallCount += 1;
    [presentations addObject:@{
      @"schema_version" : @3, @"call_index" : @(index),
      @"call_id" : raw[@"call_id"], @"name" : raw[@"name"],
      @"arguments_sha256" : raw[@"arguments_sha256"] ?:
          DSHAgentArgumentsSHA256(raw[@"name"], raw[@"arguments_json"], &error),
      @"safe_summary_key" : descriptor[@"safe_summary_key"],
      @"access" : descriptor[@"access"], @"approval_state" : denied ? @"durable_denied" : @"deferred",
    }];
  }
  NSDictionary *roundLocator = @{
    @"schema_version" : @1, @"task_id" : task, @"attempt_id" : attempt,
    @"round_id" : roundID, @"round_index" : @0,
  };
  NSDictionary *completionReceipt = @{
    @"schema_version" : @1, @"transport_schema_version" : @2,
    @"turn_id" : task, @"attempt_id" : attempt, @"round_id" : roundID,
    @"round_index" : @0, @"provider_request_id" : @"req-1",
    @"provider_response_id" : @"res-1",
    @"requested_model" : @"deepseek-v4-flash",
    @"model" : @"deepseek-v4-flash", @"thinking_mode" : @"off",
    @"finish_reason" : @"tool_calls", @"latency_ms" : @1,
    @"visible_history_sha256" : authority[@"visible_history_sha256"],
    @"model_input_sha256" :
        @"dededededededededededededededededededededededededededededededede",
    @"request_body_sha256" :
        @"efefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefef",
    @"project_context_receipt" : NSNull.null,
  };
  NSDictionary *round = @{
    @"schema_version" : @3, @"locator" : roundLocator, @"row_revision" : @1,
    @"root_fingerprint_sha256" : root[@"root_fingerprint_sha256"],
    @"binding_revision" : root[@"workspace_binding_revision"],
    @"request_sha256" :
        @"1212121212121212121212121212121212121212121212121212121212121212",
    @"transcript_before" : before, @"launch_attempt" : @1,
    @"state" : @"completed", @"owner" : NSNull.null,
    @"failure_code" : NSNull.null, @"completion_receipt" : completionReceipt,
    @"transcript_after" : after, @"calls" : presentations,
    @"batch_class" : deniedCallCount == 0 ? @"executable"
        : deniedCallCount == rawCalls.count ? @"denied_only" : @"mixed",
    @"executable_call_count" : @(rawCalls.count - deniedCallCount), @"denied_call_count" : @(deniedCallCount),
    @"terminal_kind" : @"tool_batch", @"created_at" : now, @"updated_at" : now,
  };
  BOOL roundCommitted = [self.wal performAtomicTransaction:^BOOL(
      NSMutableDictionary *state, NSError **mutationError) {
    (void)mutationError;
    NSMutableArray *rounds = [state[@"rounds"] mutableCopy];
    [rounds addObject:round];
    NSMutableArray *dispatch = [state[@"dispatch"] mutableCopy];
    [dispatch addObject:@{ @"schema_version" : @1, @"kind" : @"round",
                           @"locator" : roundLocator,
                           @"dispatch_state" : @"dispatched" }];
    state[@"rounds"] = rounds;
    state[@"dispatch"] = dispatch;
    return YES;
  } error:&error];
  XCTAssertTrue(roundCommitted);

  NSDictionary *baseSession = @{
    @"schema_version" : @9,
    @"conversations" : @[@{ @"id" : conversation, @"agent_grants" : @[],
      @"attempts" : @[@{ @"attempt_id" : attempt, @"journal_revision" : @1,
                          @"agent" : NSNull.null }] }],
    @"session_events" : @[],
  };
  AgentEffectsSessionStore *sessionStore = [[AgentEffectsSessionStore alloc]
      initWithLoadResult:[self loadResultForSession:baseSession generation:@3
                                             digest:sessionDigest]];
  AgentEffectsRootResolver *resolver = [[(self.assistantRegistryVersion == nil ? AgentEffectsRootResolver.class
          : AssistantFixtureRootResolver.class) alloc] initWithRoot:root];
  AgentEffectsPreparedStore *preparedStore = [[AgentEffectsPreparedStore alloc]
      initWithWAL:self.wal rootResolver:resolver sessionSnapshotStore:sessionStore
      transcriptStore:self.transcripts];
  DSHAgentWorkspaceToolExecutor *workspace = explicitExecutor ?:
      [[AgentEffectsWorkspaceExecutor alloc] initWithRootResolver:resolver];
  AgentEffectsGitExecutor *git = [[AgentEffectsGitExecutor alloc]
      initWithRootResolver:resolver];
  DSHAgentToolBatchService *batchService = [[DSHAgentToolBatchService alloc]
      initWithWAL:self.wal ledger:self.ledger preparedStore:preparedStore
      transcripts:self.transcripts workspaceExecutor:workspace gitExecutor:git];
  NSDictionary *checkpoint = @{ @"schema_version" : @1, @"journal_revision" : @1,
    @"session_generation" : @3, @"session_sha256" : sessionDigest };
  NSDictionary *controller = @{ @"schema_version" : @1,
    @"conversation_id" : conversation, @"task_id" : task,
    @"attempt_id" : attempt, @"expected_controller_generation" : @1,
    @"expected_journal_revision" : @1, @"expected_session_generation" : @3,
    @"expected_session_sha256" : sessionDigest };
  NSDictionary *batchRequest = @{ @"schema_version" : @2,
    @"operation_id" : @"60606060-6060-4060-8060-606060606060",
    @"controller_cas" : controller, @"committed_checkpoint" : checkpoint,
    @"task_id" : task, @"conversation_id" : conversation,
    @"attempt_id" : attempt, @"round_id" : roundID, @"round_index" : @0,
    @"expected_round_revision" : @1, @"transcript" : after, @"root" : root,
    @"registry_version" : self.assistantRegistryVersion ?: @1,
    @"toolset_sha256" : registry[@"toolset_sha256"],
    @"policy_version" : @"agent-v1", @"expected_batch_revision" : @0,
    @"expected_reserved_write_bytes" : @0 };
  return @{ @"root" : root, @"task" : task, @"attempt" : attempt,
            @"conversation" : conversation, @"round_id" : roundID,
            @"transcript" : after, @"transcript_before" : before,
            @"registry" : registry,
            @"session_store" : sessionStore, @"prepared_store" : preparedStore,
            @"resolver" : resolver, @"workspace_executor" : workspace,
            @"git_executor" : git, @"batch_service" : batchService,
            @"batch_request" : batchRequest, @"controller" : controller,
            @"checkpoint" : checkpoint };
}

@end
