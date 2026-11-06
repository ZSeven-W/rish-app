#import <XCTest/XCTest.h>
#import <objc/message.h>
#import "DSHTestStorageFixture.h"
#import "AgentRuntimeCoordinator.h"
#import "AgentExecutionLedger.h"
#import "AgentGitToolExecutor.h"
#import "AgentPreparedAttemptStore.h"
#import "AgentProviderRoundService.h"
#import "AgentRootResolver.h"
#import "AgentRoundJournal.h"
#import "AgentToolBatchService.h"
#import "AgentToolExecutionService.h"
#import "AgentTranscriptStore.h"
#import "AgentWorkspaceToolExecutor.h"
#import "DshProviderTransport.h"
#import "SessionSnapshotStore.h"
#import "RishGPUIExports.h"
#import "RishHarnessCatalog.h"

// The HTTP driver runs the actual shared Rust ShellState. It never invents
// native results, CAS proofs, tool receipts, or session journal transitions.
// A private URLProtocol redirects only this test transport to the loopback
// fixture provider; it strips Authorization rather than forwarding any key.
static NSURL *RishShellProviderURL;
@interface RishShellContractProviderProtocol : NSURLProtocol
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic, strong) NSURLSession *session;
@end
@implementation RishShellContractProviderProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
  return [request.URL.scheme isEqual:@"https"];
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
  NSData *body = self.request.HTTPBody;
  if (!body && self.request.HTTPBodyStream) {
    NSInputStream *input = self.request.HTTPBodyStream;
    NSMutableData *bytes = [NSMutableData data]; [input open];
    uint8_t buffer[4096]; NSInteger n;
    while ((n = [input read:buffer maxLength:sizeof buffer]) > 0 && bytes.length <= 8 * 1024 * 1024)
      [bytes appendBytes:buffer length:(NSUInteger)n];
    [input close]; body = bytes;
  }
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:RishShellProviderURL];
  request.HTTPMethod = @"POST"; request.HTTPBody = body;
  [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
  config.connectionProxyDictionary = @{}; config.timeoutIntervalForRequest = 15;
  config.protocolClasses = @[];
  self.session = [NSURLSession sessionWithConfiguration:config];
  self.task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *reply, NSError *error) {
    if (error) [self.client URLProtocol:self didFailWithError:error];
    else {
      NSHTTPURLResponse *http = (NSHTTPURLResponse *)reply;
      NSHTTPURLResponse *adapted = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
          statusCode:http.statusCode HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type":@"application/json"}];
      [self.client URLProtocol:self didReceiveResponse:adapted cacheStoragePolicy:NSURLCacheStorageNotAllowed];
      [self.client URLProtocol:self didLoadData:data];
      [self.client URLProtocolDidFinishLoading:self];
    }
    [self.session finishTasksAndInvalidate];
  }];
  [self.task resume];
}
- (void)stopLoading { [self.task cancel]; [self.session invalidateAndCancel]; }
@end

@interface NSObject (RishShellContractModule)
- (instancetype)initWithCoordinator:(id<DSHAgentRuntimeCoordinating>)coordinator;
@end

@interface ShellAgentNativeContractTests : XCTestCase
@property(nonatomic, strong) NSURL *baseURL;
@property(nonatomic, strong) NSURL *fixture;
@property(nonatomic, strong) DSHLocalWorkspaceAccess *workspaces;
@property(nonatomic, strong) DSHSessionSnapshotStore *sessions;
@property(nonatomic, strong) DSHAgentRuntimeCoordinator *coordinator;
@property(nonatomic, strong) NSURLSession *transportSession;
@property(nonatomic, strong) id module;
@property(nonatomic, copy) NSDictionary *workspace;
@property(nonatomic, copy) NSDictionary *root;
@property(nonatomic, copy) NSDictionary *state;
@property(nonatomic, copy) NSString *caseID;
@property(nonatomic, copy) NSString *scenario;
@property(nonatomic, strong) id previousProviderModels;
@property(nonatomic) BOOL installedProviderModelFixture;
@end

@implementation ShellAgentNativeContractTests
- (void)setUp {
  [super setUp]; self.continueAfterFailure = NO;
  NSString *base = NSProcessInfo.processInfo.environment[@"RISH_SHELL_AGENT_HARNESS_URL"];
  XCTSkipIf(base.length == 0, @"Opt-in: run scripts/native-tests/test-shell-agent-ios.sh.");
  // This opt-in suite runs only in an isolated test simulator. A successful
  // fixture chooses its model explicitly; production starts with no choices.
  self.previousProviderModels = [NSUserDefaults.standardUserDefaults objectForKey:@"RishProviderModelsV1"];
  NSMutableArray *providers = [NSMutableArray array];
  for (NSString *harness in @[@"dsh", @"claude-code", @"codex", @"glm"]) {
    NSArray *models = [harness isEqual:@"dsh"] ? @[@{@"id":@"deepseek-v4-flash", @"name":@"Native contract fixture", @"supports_images":@NO}] : @[];
    [providers addObject:@{@"harness_id":harness, @"models":models, @"retired_models":@[]}];
  }
  [NSUserDefaults.standardUserDefaults setObject:@{@"schema_version":@1, @"revision":@0, @"providers":providers} forKey:@"RishProviderModelsV1"];
  self.installedProviderModelFixture = YES;
  XCTAssertTrue(DSHHarnessModelIsExecutable(@"deepseek-v4-flash"));
  self.baseURL = [NSURL URLWithString:base];
  XCTAssertEqualObjects(self.baseURL.host, @"127.0.0.1");
  XCTAssertEqualObjects(self.baseURL.scheme, @"http");
  XCTAssertNotNil(self.baseURL.port);
  self.caseID = NSUUID.UUID.UUIDString.lowercaseString;
  RishShellProviderURL = [self.baseURL URLByAppendingPathComponent:
      [self.caseID stringByAppendingString:@"/provider"]];
  NSError *error = nil;
  self.fixture = DSHCreateTestStorageFixtureRoot(@"ShellAgentNativeContractTests", &error);
  XCTAssertNotNil(self.fixture, @"%@", error);
  NSURL *documents = [self.fixture URLByAppendingPathComponent:@"Documents" isDirectory:YES];
  NSURL *privateRoot = [self.fixture URLByAppendingPathComponent:@"workspaces" isDirectory:YES];
  for (NSURL *url in @[documents, privateRoot])
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:url withIntermediateDirectories:NO
        attributes:@{NSFilePosixPermissions:@0700} error:&error], @"%@", error);
  self.workspaces = [[DSHLocalWorkspaceAccess alloc] initWithPrivateRootURL:privateRoot documentsRootURL:documents
      clock:^{return NSDate.date;} UUIDGenerator:^{return NSUUID.UUID.UUIDString.lowercaseString;}
      legacyResolver:^BOOL(NSString *project, NSDictionary **evidence, NSError **failure) {
        (void)project; (void)evidence; (void)failure; return NO;
      } faultHook:nil];
  self.workspace = [self.workspaces createRishOwnedWorkspaceWithDisplayName:@"Shell contract fixture"
      operationId:NSUUID.UUID.UUIDString.lowercaseString error:&error];
  XCTAssertNotNil(self.workspace, @"%@", error);
  DSHAgentRootResolver *resolver = [[DSHAgentRootResolver alloc] initWithWorkspaceAccess:self.workspaces projectAccess:nil];
  self.root = [resolver resolveRootForWorkspaceId:self.workspace[@"workspace_id"] projectId:nil
      bindingRevision:self.workspace[@"binding_revision"] error:&error];
  XCTAssertNotNil(self.root, @"%@", error);
  self.sessions = [[DSHSessionSnapshotStore alloc] initWithRootURL:
      [self.fixture URLByAppendingPathComponent:@"sessions" isDirectory:YES]];
  DSHAgentNativeWAL *wal = [[DSHAgentNativeWAL alloc] initWithRootURL:
      [self.fixture URLByAppendingPathComponent:@"agent" isDirectory:YES]
      clock:^{return NSDate.date;} identifierGenerator:^{return NSUUID.UUID.UUIDString.lowercaseString;} faultHook:nil];
  DSHAgentTranscriptStore *transcripts = [[DSHAgentTranscriptStore alloc] initWithWAL:wal];
  DSHAgentPreparedAttemptStore *prepared = [[DSHAgentPreparedAttemptStore alloc] initWithWAL:wal
      rootResolver:resolver sessionSnapshotStore:self.sessions transcriptStore:transcripts];
  DSHAgentRoundJournal *rounds = [[DSHAgentRoundJournal alloc] initWithWAL:wal];
  DSHAgentExecutionLedger *ledger = [[DSHAgentExecutionLedger alloc] initWithWAL:wal];
  NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
  config.protocolClasses = @[RishShellContractProviderProtocol.class];
  self.transportSession = [NSURLSession sessionWithConfiguration:config];
  DshProviderTransport *transport = [[DshProviderTransport alloc] initWithSession:self.transportSession
      uuidGenerator:^{return NSUUID.UUID.UUIDString.lowercaseString;}
      monotonicClock:^{return NSProcessInfo.processInfo.systemUptime;}];
  __weak ShellAgentNativeContractTests *weakSelf = self;
  DSHAgentProviderRoundService *roundService = [[DSHAgentProviderRoundService alloc]
      initWithWAL:wal preparedStore:prepared transcripts:transcripts rounds:rounds transport:transport
      credentialProvider:^NSString *(NSString *harness, NSUInteger *generation) {
        (void)harness; if (generation) *generation = 1;
        return [weakSelf.scenario isEqual:@"missing-credential"] ? nil : @"synthetic-contract-only";
      } visibleHistoryProvider:^NSArray *(NSDictionary *authority, NSError **failure) {
        NSDictionary *load = [weakSelf.sessions loadSessionSnapshotWithError:failure];
        NSData *bytes = [load[@"session_json"] dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *session = bytes ? [NSJSONSerialization JSONObjectWithData:bytes options:0 error:failure] : nil;
        for (NSDictionary *conversation in session[@"conversations"]) {
          if (![conversation[@"id"] isEqual:authority[@"conversation_id"]]) continue;
          NSMutableArray *visible = [NSMutableArray array];
          for (NSString *identifier in authority[@"visible_message_ids"]) {
            NSDictionary *message = nil;
            for (NSDictionary *candidate in conversation[@"messages"])
              if ([candidate[@"id"] isEqual:identifier]) { message = candidate; break; }
            if (!message) return nil;
            [visible addObject:@{@"role":message[@"role"], @"content":message[@"text"], @"attachments":message[@"attachments"]}];
          }
          return visible;
        }
        return nil;
      } contextReceiptProvider:^NSDictionary *(NSDictionary *authority, NSError **failure) {
        // These cases deliberately use an unbound schema-2 workspace. A
        // schema-3 request must fail rather than invent a project consent.
        (void)authority; (void)failure; return nil;
      }];
  DSHAgentWorkspaceToolExecutor *files = [[DSHAgentWorkspaceToolExecutor alloc] initWithRootResolver:resolver];
  DSHAgentGitToolExecutor *git = [[DSHAgentGitToolExecutor alloc] initWithRootResolver:resolver];
  DSHAgentToolBatchService *batch = [[DSHAgentToolBatchService alloc] initWithWAL:wal ledger:ledger
      preparedStore:prepared transcripts:transcripts workspaceExecutor:files gitExecutor:git];
  DSHAgentToolExecutionService *execution = [[DSHAgentToolExecutionService alloc] initWithWAL:wal ledger:ledger
      preparedStore:prepared transcripts:transcripts workspaceExecutor:files gitExecutor:git];
  self.coordinator = [[DSHAgentRuntimeCoordinator alloc] initWithWAL:wal preparedStore:prepared roundService:roundService
      batchService:batch executionService:execution transcripts:transcripts rounds:rounds ledger:ledger];
  XCTAssertTrue(self.coordinator.available);
  self.module = [[NSClassFromString(@"AgentRuntimeModule") alloc] initWithCoordinator:self.coordinator];
  XCTAssertNotNil(self.module);
  [self writeFixture:@"notes.txt" text:@"shell-native-contract-marker\n中文原始内容\n"];
}

- (void)tearDown {
  [self.coordinator.executionService cancelRuntimeWork];
  [self.transportSession invalidateAndCancel]; self.module = nil; self.coordinator = nil;
  if (self.fixture) [NSFileManager.defaultManager removeItemAtURL:self.fixture error:nil];
  if (self.installedProviderModelFixture) {
    if (self.previousProviderModels) [NSUserDefaults.standardUserDefaults setObject:self.previousProviderModels forKey:@"RishProviderModelsV1"];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:@"RishProviderModelsV1"];
  }
  RishShellProviderURL = nil; [super tearDown];
}

- (void)writeFixture:(NSString *)path text:(NSString *)text {
  NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding]; NSError *error = nil;
  BOOL okay = [self.workspaces performCoordinatedWorkspaceOperationForId:self.root[@"workspace_id"]
      expectedBindingRevision:[self.root[@"workspace_binding_revision"] unsignedIntegerValue]
      requiredCapabilities:[NSSet setWithObjects:@"read",@"write",nil] block:^BOOL(int root, NSError **inner) {
    (void)inner; int fd = openat(root,path.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
    if (fd < 0) return NO; BOOL written = write(fd,data.bytes,data.length) == (ssize_t)data.length;
    written = fsync(fd) == 0 && written; close(fd); return written;
  } error:&error];
  XCTAssertTrue(okay, @"%@", error);
}
- (NSData *)readFixture:(NSString *)path {
  __block NSData *data = nil; NSError *error = nil;
  BOOL okay = [self.workspaces performCoordinatedWorkspaceOperationForId:self.root[@"workspace_id"]
      expectedBindingRevision:[self.root[@"workspace_binding_revision"] unsignedIntegerValue]
      requiredCapabilities:[NSSet setWithObject:@"read"] block:^BOOL(int root, NSError **inner) {
    (void)inner; int fd = openat(root,path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW);
    if (fd < 0) return errno == ENOENT;
    uint8_t bytes[8192]; ssize_t n = read(fd,bytes,sizeof bytes); close(fd);
    if (n < 0) return NO; data = [NSData dataWithBytes:bytes length:(NSUInteger)n]; return YES;
  } error:&error];
  XCTAssertTrue(okay,@"%@",error); return data;
}
- (NSDictionary *)step:(NSDictionary *)body {
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[self.baseURL URLByAppendingPathComponent:
      [self.caseID stringByAppendingString:@"/step"]]];
  request.HTTPMethod = @"POST"; request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
  [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
  config.connectionProxyDictionary = @{}; config.timeoutIntervalForRequest = 15;
  NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
  XCTestExpectation *done = [self expectationWithDescription:@"shared Rust controller step"];
  __block NSDictionary *answer; __block NSError *failure;
  [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    (void)response; failure = error;
    answer = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&failure] : nil; [done fulfill];
  }] resume];
  [self waitForExpectations:@[done] timeout:20]; [session finishTasksAndInvalidate];
  if (![answer[@"ok"] isEqual:@YES]) {
    // Retain only this isolated synthetic fixture, before tearDown removes it.
    // This lets a native/controller mismatch be checked against the real WAL.
    NSDictionary *diagnostic = @{@"controller_request":body,@"controller_result":answer ?: @{},
        @"session_snapshot":[self.sessions loadSessionSnapshotWithError:nil] ?: @{},
        @"native_wal":[self.coordinator.wal snapshotWithError:nil] ?: @{}};
    NSData *data = [NSJSONSerialization dataWithJSONObject:diagnostic options:NSJSONWritingPrettyPrinted error:nil];
    if (data) {
      XCTAttachment *attachment = [XCTAttachment attachmentWithData:data uniformTypeIdentifier:@"public.json"];
      attachment.name = @"shell-native-contract-failure.json";
      attachment.lifetime = XCTAttachmentLifetimeKeepAlways; [self addAttachment:attachment];
    }
  }
  XCTAssertNil(failure); XCTAssertEqualObjects(answer[@"ok"], @YES, @"Rust step %@: %@", body[@"action"], answer);
  self.state = answer; return answer;
}
- (id)invoke:(NSDictionary *)command {
  NSError *error = nil;
  if ([command[@"module"] isEqual:@"SessionSnapshots"]) {
    id result;
    if ([command[@"method"] isEqual:@"casPersistSession"])
      result = [self.sessions casPersistSessionWithRequest:command[@"args"][0] error:&error];
    else if ([command[@"method"] isEqual:@"querySessionCommit"])
      result = [self.sessions querySessionCommitWithRequest:command[@"args"][0] error:&error];
    else XCTFail(@"Unexpected store command %@",command[@"method"]);
    XCTAssertNil(error,@"Store %@: %@",command[@"method"],error); XCTAssertNotNil(result); return result;
  }
  XCTAssertEqualObjects(command[@"module"], @"AgentRuntime");
  SEL selector = NULL;
  for (const RishExport &entry : RishExports)
    if ([entry.module isEqual:command[@"module"]] && [entry.name isEqual:command[@"method"]])
      selector = NSSelectorFromString(entry.selector);
  XCTAssertTrue(selector != NULL); XCTAssertTrue([self.module respondsToSelector:selector]);
  XCTestExpectation *done = [self expectationWithDescription:command[@"method"]];
  __block id answer; __block NSString *failure;
  using Invoke = void (*)(id,SEL,id,id,id);
  ((Invoke)objc_msgSend)(self.module,selector,command[@"args"][0],^(id value) {
    answer = value; [done fulfill];
  },^(NSString *code, NSString *message, NSError *nativeError) {
    (void)message; (void)nativeError; failure = code; [done fulfill];
  });
  [self waitForExpectations:@[done] timeout:35];
  if (failure) {
    [self step:@{@"action":@"capture_native_failure",@"code":failure,@"command":command,
        @"session_snapshot":[self.sessions loadSessionSnapshotWithError:nil] ?: @{},
        @"native_wal":[self.coordinator.wal snapshotWithError:nil] ?: @{}}];
  }
  XCTAssertNil(failure,@"Facade %@ rejected: %@",command[@"method"],failure); XCTAssertNotNil(answer);
  return answer;
}
- (void)beginNativeCommand:(NSDictionary *)command completion:(void (^)(id, NSString *))completion {
  XCTAssertEqualObjects(command[@"module"], @"AgentRuntime");
  SEL selector = NULL;
  for (const RishExport &entry : RishExports)
    if ([entry.module isEqual:command[@"module"]] && [entry.name isEqual:command[@"method"]])
      selector = NSSelectorFromString(entry.selector);
  XCTAssertTrue(selector != NULL); XCTAssertTrue([self.module respondsToSelector:selector]);
  using Invoke = void (*)(id,SEL,id,id,id);
  ((Invoke)objc_msgSend)(self.module,selector,command[@"args"][0],^(id value) {
    completion(value,nil);
  },^(NSString *code, NSString *message, NSError *nativeError) {
    (void)message; (void)nativeError; completion(nil,code);
  });
}
- (void)pumpUntil:(NSString *)method {
  for (NSUInteger count = 0; count < 160; count++) {
    id command = self.state[@"command"];
    if (command == NSNull.null || (method && [command[@"method"] isEqual:method])) return;
    NSLog(@"SHELL_AGENT_CONTRACT %@",command[@"method"]);
    id result = [self invoke:command];
    [self step:@{@"action":@"reply",@"command":command,@"value":result}];
  }
  XCTFail(@"Controller exceeded 160 native transitions");
}
- (void)begin:(NSString *)scenario {
  self.scenario = scenario;
  if ([scenario isEqual:@"unavailable-transport"]) {
    self.coordinator.roundService.transportResolver = ^DSHCompletionProviderTransport *(NSString *harness) {
      (void)harness; return nil;
    };
  }
  NSDictionary *workspace = @{@"schema_version":@2,@"workspace_id":self.workspace[@"workspace_id"],
      @"binding_revision":self.workspace[@"binding_revision"],@"display_name":@"Contract workspace",@"status":@"ok",
      @"capabilities":@{@"read":@YES,@"write":@YES,@"git":@YES}};
  [self step:@{@"action":@"reset",@"scenario":scenario,@"workspace":workspace,
      @"snapshot":[self.sessions loadSessionSnapshotWithError:nil]}];
  [self pumpUntil:nil];
  [self step:@{@"action":@"send",@"text":@"验证当前工作空间的测试文件。"}];
}
- (void)assertCompleted {
  XCTAssertEqual(self.state[@"command"],NSNull.null);
  NSDictionary *conversation = self.state[@"session"][@"conversations"][0];
  XCTAssertEqualObjects(conversation[@"attempts"][0][@"status"],@"completed");
  XCTAssertEqualObjects([conversation[@"messages"] lastObject][@"role"],@"assistant");
  XCTAssertEqualObjects(self.state[@"provider_calls"],@2);
  XCTAssertEqualObjects(self.state[@"feedback_seen"],@YES);
  XCTAssertTrue([self.state[@"commands"] containsObject:@"AgentRuntime.finalize_agent_attempt"]);
  XCTAssertTrue([self.state[@"commands"] containsObject:@"AgentRuntime.discard_agent_attempt"]);
  NSDictionary *load = [self.sessions loadSessionSnapshotWithError:nil];
  NSDictionary *persisted = [NSJSONSerialization JSONObjectWithData:[load[@"session_json"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
  XCTAssertEqualObjects(persisted,self.state[@"session"]);
  XCTAssertEqualObjects([self readFixture:@"notes.txt"],[@"shell-native-contract-marker\n中文原始内容\n" dataUsingEncoding:NSUTF8StringEncoding]);
}
- (void)testSharedShellReadsRealFileThenPersistsAnswerAndCleanup {
  [self begin:@"read"]; [self pumpUntil:nil]; [self assertCompleted];
  XCTAssertNil([self readFixture:@"created.txt"]);
}
- (void)testSharedShellQueriesLostUserCASBeforeDispatchingProvider {
  [self begin:@"read"];
  NSDictionary *command = self.state[@"command"];
  XCTAssertEqualObjects(command[@"method"],@"casPersistSession");
  [self invoke:command]; // The store committed; the UI did not receive its proof.
  [self step:@{@"action":@"lose_cas_reply"}];
  XCTAssertEqualObjects(self.state[@"provider_calls"],@0);
  XCTAssertEqualObjects(self.state[@"command"][@"method"],@"querySessionCommit");
  [self pumpUntil:nil]; [self assertCompleted];
}
- (void)testSharedShellWaitsForApprovalThenWritesAndFinalizes {
  [self begin:@"write"]; [self pumpUntil:nil];
  XCTAssertEqualObjects(self.state[@"view"][@"approval"][@"name"],@"write_file");
  XCTAssertNil([self readFixture:@"created.txt"]); XCTAssertEqualObjects(self.state[@"provider_calls"],@1);
  [self step:@{@"action":@"approve",@"decision":@"allow_once"}]; [self pumpUntil:nil]; [self assertCompleted];
  XCTAssertEqualObjects([self readFixture:@"created.txt"],[@"来自共享 Rust 控制器\n" dataUsingEncoding:NSUTF8StringEncoding]);
}
- (void)testSharedShellDenialBecomesNativeFeedbackWithoutWriting {
  [self begin:@"deny"]; [self pumpUntil:nil]; XCTAssertNil([self readFixture:@"created.txt"]);
  [self step:@{@"action":@"approve",@"decision":@"denied",@"message":@"测试拒绝，不要修改文件。"}];
  [self pumpUntil:nil]; [self assertCompleted]; XCTAssertNil([self readFixture:@"created.txt"]);
}
- (void)testSharedShellCancelsWaitingApprovalWithoutDispatchingWrite {
  [self begin:@"cancel"]; [self pumpUntil:nil];
  [self step:@{@"action":@"cancel"}]; [self pumpUntil:nil];
  XCTAssertNil([self readFixture:@"created.txt"]); XCTAssertEqualObjects(self.state[@"provider_calls"],@1);
  NSDictionary *attempt = self.state[@"session"][@"conversations"][0][@"attempts"][0];
  XCTAssertEqualObjects(attempt[@"status"],@"cancelled");
}
- (void)testSharedShellCancelsInFlightProviderAndIgnoresLateCallback {
  [self begin:@"cancel-provider"]; [self pumpUntil:@"complete_agent_round_v2"];
  NSDictionary *round = self.state[@"command"];
  XCTAssertEqualObjects(round[@"method"],@"complete_agent_round_v2");
  XCTestExpectation *settled = [self expectationWithDescription:@"cancelled native provider callback"];
  __block id lateValue = nil; __block NSString *lateFailure = nil;
  [self beginNativeCommand:round completion:^(id value, NSString *failure) {
    lateValue = value; lateFailure = failure; [settled fulfill];
  }];
  // The loopback server acknowledges receipt before cancellation. Its reply
  // stays held while the real facade commits cancellation and cleanup.
  [self step:@{@"action":@"wait_for_provider"}];
  XCTAssertEqualObjects(self.state[@"provider_calls"],@1);
  [self step:@{@"action":@"cancel"}]; [self pumpUntil:nil];
  NSDictionary *cancelledSession = self.state[@"session"];
  NSDictionary *conversation = cancelledSession[@"conversations"][0];
  XCTAssertEqualObjects(conversation[@"attempts"][0][@"status"],@"cancelled");
  XCTAssertEqualObjects(conversation[@"attempts"][0][@"agent"][@"round_lineage"][@"status"],@"ambiguous");
  XCTAssertEqual([conversation[@"messages"] count],1U);
  XCTAssertEqualObjects(conversation[@"messages"][0][@"role"],@"user");
  XCTAssertEqual([cancelledSession[@"agent_transcript_cleanup_outbox"] count],0U);
  XCTAssertTrue([self.state[@"commands"] containsObject:@"AgentRuntime.interrupt_agent_attempt"]);
  XCTAssertFalse([self.state[@"commands"] containsObject:@"AgentRuntime.execute_agent_tool"]);
  [self step:@{@"action":@"release_provider"}];
  [self waitForExpectations:@[settled] timeout:10];
  XCTAssertTrue(lateValue != nil || lateFailure != nil);
  NSMutableDictionary *callback = [@{@"action":@"late_reply",@"command":round} mutableCopy];
  if (lateFailure) callback[@"failure"] = lateFailure; else callback[@"value"] = lateValue;
  [self step:callback];
  XCTAssertEqualObjects(self.state[@"session"],cancelledSession);
  XCTAssertEqualObjects(self.state[@"ignored_late_replies"],@1);
  XCTAssertEqualObjects(self.state[@"provider_calls"],@1);
  XCTAssertEqual(self.state[@"command"],NSNull.null);
  NSPredicate *roundCommands = [NSPredicate predicateWithFormat:@"SELF == %@",@"AgentRuntime.complete_agent_round_v2"];
  XCTAssertEqual([[self.state[@"commands"] filteredArrayUsingPredicate:roundCommands] count],1U);
  NSDictionary *load = [self.sessions loadSessionSnapshotWithError:nil];
  NSDictionary *persisted = [NSJSONSerialization JSONObjectWithData:
      [load[@"session_json"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
  XCTAssertEqualObjects(persisted,cancelledSession);
  NSError *walError = nil;
  NSDictionary *wal = [self.coordinator.wal snapshotWithError:&walError];
  XCTAssertNil(walError); XCTAssertNotNil(wal);
  for (NSString *key in @[@"authorities",@"transcripts",@"rounds",@"ledger",@"reservations",@"batches",@"dispatch"])
    XCTAssertEqual([wal[key] count],0U,@"Native cleanup left %@",key);
  XCTAssertEqual([wal[@"cleanup"] count],1U);
  XCTAssertEqualObjects(wal[@"cleanup"][0][@"status"],@"discarded");
  XCTAssertNil([self readFixture:@"created.txt"]);
}
- (void)testSharedShellRestoresDurableStopAfterLostPreflightFailure {
  [self begin:@"missing-credential"]; [self pumpUntil:@"complete_agent_round_v2"];
  NSDictionary *round = self.state[@"command"];
  NSDictionary *lostReply = [self invoke:round];
  XCTAssertEqualObjects(lostReply[@"status"],@"failed_retryable");
  XCTAssertEqualObjects(lostReply[@"failure_code"],@"E_AGENT_PROVIDER_CREDENTIAL");
  // Native has settled before dispatch, but the controller still has its old
  // in-flight journal. Persist Stop, then lose the process before native cancel.
  [self step:@{@"action":@"cancel"}]; [self pumpUntil:@"cancel_agent_attempt"];
  XCTAssertEqualObjects(self.state[@"command"][@"method"],@"cancel_agent_attempt");
  NSPredicate *stopEvents = [NSPredicate predicateWithFormat:@"kind == %@",@"cancel"];
  XCTAssertEqual([[self.state[@"session"][@"session_events"] filteredArrayUsingPredicate:stopEvents] count],1U);
  [self step:@{@"action":@"restart",@"snapshot":[self.sessions loadSessionSnapshotWithError:nil]}];
  [self pumpUntil:nil];
  NSDictionary *cancelledSession = self.state[@"session"];
  NSDictionary *conversation = cancelledSession[@"conversations"][0];
  XCTAssertEqualObjects(conversation[@"attempts"][0][@"status"],@"cancelled");
  XCTAssertEqual([conversation[@"messages"] count],1U);
  XCTAssertEqualObjects(conversation[@"messages"][0][@"role"],@"user");
  XCTAssertEqualObjects(self.state[@"provider_calls"],@0);
  XCTAssertEqual([cancelledSession[@"agent_transcript_cleanup_outbox"] count],0U);
  for (NSString *method in @[@"query_agent_attempt",@"recover_agent_attempt",@"finalize_agent_attempt",@"discard_agent_attempt"])
    XCTAssertTrue([self.state[@"commands"] containsObject:[@"AgentRuntime." stringByAppendingString:method]]);
  NSPredicate *roundCommands = [NSPredicate predicateWithFormat:@"SELF == %@",@"AgentRuntime.complete_agent_round_v2"];
  XCTAssertEqual([[self.state[@"commands"] filteredArrayUsingPredicate:roundCommands] count],1U);
  [self step:@{@"action":@"late_reply",@"command":round,@"value":lostReply}];
  XCTAssertEqualObjects(self.state[@"ignored_late_replies"],@1);
  XCTAssertEqualObjects(self.state[@"session"],cancelledSession);
  XCTAssertEqual(self.state[@"command"],NSNull.null);
  NSDictionary *load = [self.sessions loadSessionSnapshotWithError:nil];
  NSDictionary *persisted = [NSJSONSerialization JSONObjectWithData:
      [load[@"session_json"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
  XCTAssertEqualObjects(persisted,cancelledSession);
  NSError *walError = nil;
  NSDictionary *wal = [self.coordinator.wal snapshotWithError:&walError];
  XCTAssertNil(walError); XCTAssertNotNil(wal);
  for (NSString *key in @[@"authorities",@"transcripts",@"rounds",@"ledger",@"reservations",@"batches",@"dispatch"])
    XCTAssertEqual([wal[key] count],0U,@"Native cleanup left %@",key);
  XCTAssertEqual([wal[@"cleanup"] count],1U);
  XCTAssertEqualObjects(wal[@"cleanup"][0][@"status"],@"discarded");
  XCTAssertNil([self readFixture:@"created.txt"]);
}
- (void)testSharedShellRecreatesControllerAndRecoversPendingApproval {
  [self begin:@"recover"]; [self pumpUntil:nil];
  [self step:@{@"action":@"restart",@"snapshot":[self.sessions loadSessionSnapshotWithError:nil]}];
  [self pumpUntil:nil]; XCTAssertNil([self readFixture:@"created.txt"]);
  XCTAssertEqualObjects(self.state[@"view"][@"approval"][@"name"],@"write_file");
  [self step:@{@"action":@"approve",@"decision":@"allow_once"}]; [self pumpUntil:nil]; [self assertCompleted];
}
- (void)testSharedShellRecoversLostWriteReplyWithoutReexecuting {
  [self begin:@"write"]; [self pumpUntil:nil];
  [self step:@{@"action":@"approve",@"decision":@"allow_once"}]; [self pumpUntil:@"execute_agent_tool"];
  NSDictionary *command = self.state[@"command"]; XCTAssertEqualObjects(command[@"method"],@"execute_agent_tool");
  [self invoke:command]; // Native has executed and committed, UI loses only the reply.
  NSData *written = [self readFixture:@"created.txt"]; XCTAssertNotNil(written);
  [self step:@{@"action":@"failure",@"code":@"E_TEST_REPLY_LOST"}];
  [self step:@{@"action":@"recover"}]; [self pumpUntil:nil]; [self assertCompleted];
  XCTAssertEqualObjects([self readFixture:@"created.txt"],written);
  NSPredicate *executes = [NSPredicate predicateWithFormat:@"SELF == %@",@"AgentRuntime.execute_agent_tool"];
  XCTAssertEqual([[self.state[@"commands"] filteredArrayUsingPredicate:executes] count],1U);
}
- (void)testSharedShellQuestionAnswerIsCommittedBeforeContinuation {
  [self begin:@"question"]; [self pumpUntil:nil];
  NSDictionary *question = self.state[@"view"][@"question"];
  XCTAssertEqualObjects(question[@"input_mode"],@"options"); XCTAssertEqualObjects(self.state[@"provider_calls"],@1);
  [self step:@{@"action":@"answer",@"call_id":question[@"call_id"],@"answer":@"blue"}];
  [self pumpUntil:nil]; [self assertCompleted]; XCTAssertNil([self readFixture:@"created.txt"]);
}
- (void)assertDefinitePreDispatchFailure:(NSString *)code {
  XCTAssertEqual(self.state[@"command"],NSNull.null);
  NSDictionary *conversation = self.state[@"session"][@"conversations"][0];
  NSDictionary *attempt = conversation[@"attempts"][0];
  XCTAssertEqualObjects(attempt[@"status"],@"failed");
  XCTAssertEqualObjects(attempt[@"failure_code"],code);
  XCTAssertEqualObjects(self.state[@"view"][@"recoverable"],@NO);
  XCTAssertEqualObjects(self.state[@"provider_calls"],@0);
  XCTAssertEqual([conversation[@"messages"] count],1U);
  XCTAssertFalse([self.state[@"commands"] containsObject:@"AgentRuntime.execute_agent_tool"]);
  XCTAssertFalse([self.state[@"commands"] containsObject:@"AgentRuntime.recover_agent_attempt"]);
  XCTAssertTrue([self.state[@"commands"] containsObject:@"AgentRuntime.finalize_agent_attempt"]);
  XCTAssertTrue([self.state[@"commands"] containsObject:@"AgentRuntime.discard_agent_attempt"]);
  XCTAssertEqual([self.state[@"session"][@"agent_transcript_cleanup_outbox"] count],0U);
  XCTAssertNil([self readFixture:@"created.txt"]);
}
- (void)testSharedShellMissingCredentialFailsBeforeDispatchAndCleansUp {
  [self begin:@"missing-credential"]; [self pumpUntil:nil];
  [self assertDefinitePreDispatchFailure:@"E_AGENT_PROVIDER_CREDENTIAL"];
}
- (void)testSharedShellUnavailableTransportFailsBeforeDispatchAndCleansUp {
  [self begin:@"unavailable-transport"]; [self pumpUntil:nil];
  [self assertDefinitePreDispatchFailure:@"E_AGENT_CAPABILITY"];
}
@end
