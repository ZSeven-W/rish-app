#import <XCTest/XCTest.h>
#import <objc/message.h>
#import "AgentRuntimeCoordinator.h"
#import "LocalWorkspaceAccess.h"
#import "SessionSnapshotStore.h"
#import "RishGPUIExports.h"

// Reuse the real, private native fixture and loopback provider transport. This
// class adds only adapter calls missing from the older single-shell driver.
@interface ShellAgentNativeContractTests : XCTestCase
@property(nonatomic, strong) DSHLocalWorkspaceAccess *workspaces;
@property(nonatomic, strong) DSHSessionSnapshotStore *sessions;
@property(nonatomic, strong) DSHAgentRuntimeCoordinator *coordinator;
@property(nonatomic, copy) NSDictionary *workspace;
@property(nonatomic, copy) NSDictionary *state;
@property(nonatomic, copy) NSString *scenario;
- (NSDictionary *)step:(NSDictionary *)body;
- (id)invoke:(NSDictionary *)command;
- (NSData *)readFixture:(NSString *)path;
@end

@interface AssistantActorNativeTests : ShellAgentNativeContractTests
@property(nonatomic, strong) id workspaceModule;
@property(nonatomic, strong) id experienceModule;
@end

@implementation AssistantActorNativeTests
+ (NSArray<NSInvocation *> *)testInvocations {
  // Do not repeat the twelve inherited tests under another test-class name.
  NSPredicate *own = [NSPredicate predicateWithBlock:^BOOL(NSInvocation *invocation, NSDictionary *bindings) {
    (void)bindings;
    return [NSStringFromSelector(invocation.selector) hasPrefix:@"testProcessAssistant"];
  }];
  return [[super testInvocations] filteredArrayUsingPredicate:own];
}
- (void)setUp {
  [super setUp];
  self.workspaceModule = [NSClassFromString(@"LocalWorkspacesModule") new];
  [self.workspaceModule setValue:self.workspaces forKey:@"access"];
  self.experienceModule = [NSClassFromString(@"TaskExperienceModule") new];
  XCTAssertNotNil(self.workspaceModule); XCTAssertNotNil(self.experienceModule);
}
- (id)invoke:(NSDictionary *)command {
  NSString *name = command[@"module"];
  if (![name isEqual:@"TaskExperience"] && ![name isEqual:@"LocalWorkspaces"])
    return [super invoke:command];
  id module = [name isEqual:@"TaskExperience"] ? self.experienceModule : self.workspaceModule;
  SEL selector = NULL;
  for (const RishExport &entry : RishExports)
    if ([entry.module isEqual:name] && [entry.name isEqual:command[@"method"]]) selector = NSSelectorFromString(entry.selector);
  XCTAssertTrue(selector != NULL); XCTAssertTrue([module respondsToSelector:selector]);
  XCTestExpectation *done = [self expectationWithDescription:command[@"method"]];
  __block id answer; __block NSString *failure;
  using Invoke = void (*)(id,SEL,id,id,id);
  ((Invoke)objc_msgSend)(module,selector,command[@"args"][0],^(id value) {
    answer = value; [done fulfill];
  },^(NSString *code, NSString *message, NSError *error) {
    (void)message; (void)error; failure = code; [done fulfill];
  });
  [self waitForExpectations:@[done] timeout:15];
  XCTAssertNil(failure, @"Native %@ failed: %@", name, failure); XCTAssertNotNil(answer);
  return answer;
}
- (NSDictionary *)task {
  for (NSDictionary *task in self.state[@"store"][@"tasks"])
    if ([task[@"id"] isEqual:self.state[@"task_id"]]) return task;
  return nil;
}
- (void)pumpActorUntil:(BOOL (^)(void))ready {
  for (NSUInteger count = 0; count < 200; count++) {
    NSDictionary *command = self.state[@"command"];
    if ((id)command != NSNull.null && command != nil) {
      id requestID = self.state[@"request_id"];
      id value = [self invoke:command];
      [self step:@{@"action":@"reply", @"request_id":requestID, @"value":value}];
    } else if (ready()) {
      XCTAssertEqualObjects(self.state[@"errors"], @[]);
      XCTAssertEqualObjects(self.state[@"store"], self.state[@"durable_store"]);
      return;
    } else {
      [self step:@{@"action":@"poll"}];
    }
  }
  XCTFail(@"Process actor did not settle: %@", self.state);
}
- (NSDictionary *)persistedSession {
  NSDictionary *loaded = [self.sessions loadSessionSnapshotWithError:nil];
  return [NSJSONSerialization JSONObjectWithData:[loaded[@"session_json"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
}
- (void)runScenario:(NSString *)scenario expecting:(NSString *)status {
  self.scenario = scenario;
  [self step:@{@"action":@"create", @"scenario":scenario}];
  XCTAssertEqualObjects([self task][@"last_run"], NSNull.null);
  [self step:@{@"action":@"run"}];
  XCTAssertEqualObjects([self task][@"pending_manual"], @YES);
  XCTAssertEqualObjects([self task][@"last_run"], NSNull.null);
  XCTAssertEqualObjects(self.state[@"owns_writer"], @NO);
  // Only explicit handoff transfers the idle session to the production actor.
  [self step:@{@"action":@"grant", @"snapshot":[self.sessions loadSessionSnapshotWithError:nil]}];
  [self pumpActorUntil:^BOOL {
    return [[self task][@"last_run"][@"status"] isEqual:status] && [self.state[@"owns_writer"] isEqual:@NO];
  }];
  NSDictionary *task = [self task], *run = task[@"last_run"];
  XCTAssertEqualObjects(run[@"snapshot"][@"name"], @"本机契约助手");
  XCTAssertEqualObjects(run[@"snapshot"][@"notes"], @"本机契约备注必须进入模型上下文。");
  NSDictionary *persisted = [self persistedSession];
  XCTAssertEqualObjects(persisted, self.state[@"session"]);
  XCTAssertEqualObjects(persisted[@"agent_transcript_cleanup_outbox"], @[]);
  NSDictionary *conversation;
  for (NSDictionary *candidate in persisted[@"conversations"])
    if ([candidate[@"id"] isEqual:task[@"conversation_id"]]) conversation = candidate;
  XCTAssertNotNil(conversation);
  XCTAssertEqualObjects(conversation[@"title"], task[@"title"]);
  XCTAssertEqualObjects(conversation[@"title_source"], @"manual");
  NSDictionary *attempt = conversation[@"attempts"][0];
  XCTAssertEqualObjects(attempt[@"attempt_id"], run[@"ids"][@"attempt_id"]);
  XCTAssertEqualObjects(attempt[@"turn_id"], run[@"ids"][@"turn_id"]);
  XCTAssertEqualObjects(attempt[@"status"], status);
  XCTAssertEqualObjects(conversation[@"messages"][0][@"id"], run[@"ids"][@"user_message_id"]);
  if ([status isEqual:@"completed"]) {
    XCTAssertEqualObjects(self.state[@"provider_calls"], @2);
    XCTAssertEqualObjects(self.state[@"feedback_seen"], @YES);
    NSDictionary *last = [conversation[@"messages"] lastObject];
    XCTAssertEqualObjects(last[@"id"], run[@"ids"][@"assistant_message_id"]);
    XCTAssertEqualObjects(last[@"role"], @"assistant");
    XCTAssertEqualObjects(run[@"result_summary"], last[@"text"]);
  } else {
    XCTAssertEqualObjects(run[@"failure_code"], @"E_AGENT_PROVIDER_CREDENTIAL");
    XCTAssertEqualObjects(attempt[@"failure_code"], @"E_AGENT_PROVIDER_CREDENTIAL");
    XCTAssertEqualObjects(self.state[@"provider_calls"], @0);
    XCTAssertEqual([conversation[@"messages"] count], 1U);
  }
  XCTAssertEqualObjects([self readFixture:@"notes.txt"], [@"shell-native-contract-marker\n中文原始内容\n" dataUsingEncoding:NSUTF8StringEncoding]);
  XCTAssertNil([self readFixture:@"created.txt"]);
  NSData *evidence = [NSJSONSerialization dataWithJSONObject:self.state options:NSJSONWritingPrettyPrinted error:nil];
  XCTAttachment *attachment = [XCTAttachment attachmentWithData:evidence uniformTypeIdentifier:@"public.json"];
  attachment.name = [@"assistant-actor-" stringByAppendingString:scenario];
  attachment.lifetime = XCTAttachmentLifetimeKeepAlways; [self addAttachment:attachment];
}
- (void)testProcessAssistantReadsRealFileThenPersistsMissingCredentialFailure {
  NSDictionary *workspace = @{@"schema_version":@2,@"workspace_id":self.workspace[@"workspace_id"],
      @"binding_revision":self.workspace[@"binding_revision"],@"display_name":@"Actor contract workspace",@"status":@"ok",
      @"capabilities":@{@"read":@YES,@"write":@YES,@"git":@YES}};
  [self step:@{@"action":@"reset", @"workspace":workspace}];
  [self pumpActorUntil:^BOOL { return [self.state[@"store"][@"revision"] isEqual:@1]; }];
  [self runScenario:@"read" expecting:@"completed"];
  [self runScenario:@"missing-credential" expecting:@"failed"];
  XCTAssertEqual([self.state[@"store"][@"tasks"] count], 2U);
}
@end
