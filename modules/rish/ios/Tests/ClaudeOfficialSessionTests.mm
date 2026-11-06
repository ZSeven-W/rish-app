#import <XCTest/XCTest.h>

#import "../../../../modules/rish/ios/Sources/ClaudeOfficialSession.h"

@interface DSHClaudeOfficialSession (DeadlineTest)
- (void)watchLoginSession:(NSString *)session generation:(NSUInteger)generation;
- (void)ingestLoginChunk:(NSData *)chunk;
- (void)freeGuest;
@end

// The tests below are pure-parser and injected-exchange only: they never run
// a real guest VM, never contact claude.ai, and never touch credentials.

static NSDictionary *TaggedExchange(NSDictionary *response,
                                    NSArray *events) {
  return @{
    @"protocol_version": @1,
    @"ok": @YES,
    @"exchange": @{ @"response": response, @"events": events },
  };
}

static NSDictionary *ExecStartedResponse(NSString *requestId) {
  return @{
    @"id": requestId,
    @"status": @"success",
    @"result": @{
      @"result_type": @"exec_started",
      @"result": @{ @"execution_id": @"exec-1", @"pid": @42 },
    },
  };
}

static NSDictionary *StreamEvent(NSString *base64, NSString *channel) {
  return @{
    @"sequence": @7,
    @"timestamp_ms": @1000,
    @"request_id": @"host-1",
    @"event_type": @"stream",
    @"event": @{
      @"execution_id": @"exec-1",
      @"channel": channel,
      @"stream_sequence": @1,
      @"data_base64": base64,
      @"eof": @NO,
    },
  };
}

static NSDictionary *ProcessExitedEvent(NSNumber *exitCode) {
  return @{
    @"sequence": @8,
    @"timestamp_ms": @2000,
    @"request_id": @"host-1",
    @"event_type": @"process_exited",
    @"event": @{ @"execution_id": @"exec-1", @"exit_code": exitCode, @"signal": [NSNull null] },
  };
}

static NSString *Base64Of(NSString *text) {
  return [[text dataUsingEncoding:NSUTF8StringEncoding]
      base64EncodedStringWithOptions:0];
}

static NSURL *TemporaryStorageDirectory(void) {
  NSURL *root = [NSURL
      fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                                  [NSString stringWithFormat:@"claude-official-%@",
                                                            NSUUID.UUID.UUIDString]]
               isDirectory:YES];
  [[NSFileManager defaultManager] createDirectoryAtURL:root
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];
  return root;
}

/// Minimal fake guest driven through the injected-exchange seam. It records
/// every request so protocol shape can be asserted, and answers ping polls
/// with queued stream/exit events per execution.
@interface DSHClaudeFakeGuest : NSObject
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *requests;
// Queue of per-ping event batches for the single active execution.
@property (nonatomic, strong) NSMutableArray<NSArray *> *pendingPings;
@property (nonatomic, copy) NSString *loginOutput;
@property (nonatomic, assign) NSInteger loginExitCode;
@property (nonatomic, copy) NSString *statusOutput;
@property (nonatomic, assign) NSInteger statusExitCode;
@property (nonatomic, assign) BOOL mountFails;
@property (nonatomic, assign) NSUInteger formatCalls;
@property (nonatomic, assign) NSUInteger configurationBackupCalls;
@property (nonatomic, copy) NSString *textOutput;
@property (nonatomic, assign) NSInteger textExitCode;
@property (nonatomic, copy) NSString *lastStdinBase64;
@property (nonatomic, assign) BOOL holdTextResult;
@property (nonatomic, assign) NSUInteger bootCalls;
@end

@implementation DSHClaudeFakeGuest

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _requests = [NSMutableArray array];
    _pendingPings = [NSMutableArray array];
    _loginOutput = @"";
    _statusOutput = @"{\"loggedIn\":false}";
    _statusExitCode = 0;
    _loginExitCode = 0;
    _textOutput = @"{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"session_id\":\"text-1\",\"model\":\"claude-haiku-4-5-20251001\",\"result\":\"hello\"}";
    _textExitCode = 0;
  }
  return self;
}

- (void)queuePings:(NSArray *)batches {
  [self.pendingPings addObjectsFromArray:batches];
}

- (NSDictionary *)exchangeForRequest:(NSDictionary *)request {
  [self.requests addObject:request];
  NSString *operation = request[@"operation"];
  NSDictionary *parameters = request[@"parameters"];
  if ([operation isEqualToString:@"ping"]) {
    NSArray *events = self.pendingPings.firstObject ?: @[];
    if (self.pendingPings.count > 0) [self.pendingPings removeObjectAtIndex:0];
    return TaggedExchange(
        @{ @"id": request[@"id"], @"status": @"success",
           @"result": @{@"result_type": @"pong", @"result": @{ @"nonce": @"bounded" }} },
        events);
  }
  if ([operation isEqualToString:@"exec"]) {
    NSString *argv = [parameters[@"argv"] componentsJoinedByString:@" "];
    if ([argv hasPrefix:@"mkfs.vfat"]) {
      self.formatCalls += 1;
      [self queuePings:@[ @[ ProcessExitedEvent(@0) ] ]];
    } else if ([argv containsString:@"mount -t vfat"]) {
      [self queuePings:@[ @[ ProcessExitedEvent(self.mountFails ? @1 : @0) ] ]];
    } else if ([argv hasSuffix:@"auth login --claudeai"]) {
      // Two-step: stream output first, exit on the next poll, so callers can
      // observe the waiting_for_browser phase deterministically.
      NSArray *first = self.loginOutput.length > 0
          ? @[ StreamEvent(Base64Of(self.loginOutput), @"stdout") ]
          : @[];
      [self queuePings:@[ first, @[ ProcessExitedEvent(@(self.loginExitCode)) ] ]];
    } else if ([argv containsString:@"&& mv \"$1\" \"$2\" && sync"]) {
      self.configurationBackupCalls += 1;
      self.loginOutput = @"";
      self.loginExitCode = 0;
      [self queuePings:@[ @[ ProcessExitedEvent(@0) ] ]];
    } else if ([argv hasSuffix:@"auth status --json"]) {
      [self queuePings:@[
        @[ StreamEvent(Base64Of(self.statusOutput), @"stdout"),
           ProcessExitedEvent(@(self.statusExitCode)) ]
      ]];
    } else if ([argv hasSuffix:@"claude --version"]) {
      [self queuePings:@[
        @[ StreamEvent(Base64Of(@"2.1.263 (Claude Code)\n"), @"stdout"),
           ProcessExitedEvent(@0) ]
      ]];
    } else if ([argv containsString:@" -p --safe-mode --output-format json --tools="]) {
      [self queuePings:@[]];
    } else if ([argv isEqualToString:@"sync"] || [argv hasSuffix:@"auth logout"]) {
      [self queuePings:@[ @[ ProcessExitedEvent(@0) ] ]];
    } else {
      return @{ @"protocol_version": @1, @"ok": @NO };
    }
    return TaggedExchange(ExecStartedResponse(request[@"id"]), @[]);
  }
  if ([operation isEqualToString:@"stream"]) {
    NSString *action = parameters[@"stream_action"];
    if ([action isEqualToString:@"write_stdin"]) {
      self.lastStdinBase64 = parameters[@"data_base64"];
    } else if ([action isEqualToString:@"close_stdin"]) {
      if (self.holdTextResult) {
        // Keep the execution pending until Cancel; queueing its result here
        // races the cancellation test and lets it finish before ownership is observed.
        return TaggedExchange(@{ @"id": request[@"id"], @"status": @"success", @"result": @{ @"result_type": @"stream_accepted", @"result": @{ @"execution_id": parameters[@"execution_id"] } } }, @[]);
      }
      return TaggedExchange(@{ @"id": request[@"id"], @"status": @"success",
                              @"result": @{ @"result_type": @"stream_accepted",
                                            @"result": @{ @"execution_id": parameters[@"execution_id"] } } },
                            @[StreamEvent(Base64Of(self.textOutput), @"stdout"), ProcessExitedEvent(@(self.textExitCode))]);
    }
    return TaggedExchange(
        @{ @"id": request[@"id"], @"status": @"success",
           @"result": @{@"result_type": @"stream_accepted",
           @"result": @{ @"execution_id": parameters[@"execution_id"] }} },
        @[]);
  }
  if ([operation isEqualToString:@"cancel"]) {
    [self.pendingPings removeAllObjects];
    [self queuePings:@[ @[ ProcessExitedEvent(@0) ] ]];
    return TaggedExchange(
        @{ @"id": request[@"id"], @"status": @"success",
           @"result": @{@"result_type": @"cancelled",
           @"result": @{ @"target_request_id": parameters[@"target_request_id"] }} },
        @[]);
  }
  return @{ @"protocol_version": @1, @"ok": @NO };
}

- (BOOL)boot:(NSDictionary *)request {
  [self.requests addObject:request];
  self.bootCalls += 1;
  return YES;
}

- (NSArray *)executedArgvLines {
  NSMutableArray *lines = [NSMutableArray array];
  for (NSDictionary *request in self.requests) {
    if (![request[@"operation"] isEqual:@"exec"]) continue;
    NSArray *argv = request[@"parameters"][@"argv"];
    if ([argv isKindOfClass:NSArray.class]) {
      [lines addObject:[argv componentsJoinedByString:@" "]];
    }
  }
  return lines;
}

@end

@interface ClaudeOfficialSessionTests : XCTestCase
@property(nonatomic, strong) NSMutableArray<DSHClaudeOfficialSession *> *injectedSessions;
@end

@implementation ClaudeOfficialSessionTests

- (void)setUp {
  [super setUp];
  self.injectedSessions = [NSMutableArray array];
}

- (void)tearDown {
  // Browser-output tests intentionally stop observing before their worker
  // finishes. Cancel and drain those native actors before the next test so a
  // real process-wide reservation is never bypassed or reset by the fixture.
  for (DSHClaudeOfficialSession *session in self.injectedSessions) {
    NSString *sessionId = [session valueForKey:@"activeSessionId"];
    if (sessionId.length) {
      XCTestExpectation *cancelled = [self expectationWithDescription:@"fixture login cancelled"];
      [session cancelSession:sessionId completion:^(__unused NSDictionary *status) { [cancelled fulfill]; }];
      [self waitForExpectations:@[cancelled] timeout:5];
    }
    XCTestExpectation *drained = [self expectationWithDescription:@"fixture guest released"];
    dispatch_queue_t worker = [session valueForKey:@"workerQueue"];
    dispatch_async(worker, ^{ [session freeGuest]; [drained fulfill]; });
    [self waitForExpectations:@[drained] timeout:5];
  }
  self.injectedSessions = nil;
  [super tearDown];
}

#pragma mark Pure parser: control exchange

- (void)testParseControlExchangeRejectsMalformedEnvelopes {
  XCTAssertEqualObjects([DSHClaudeOfficialSession parseControlExchange:nil], @{});
  XCTAssertEqualObjects([DSHClaudeOfficialSession
      parseControlExchange:(id)@[]], @{});
  // Wrong protocol version and ok=false must fail closed with no streams.
  NSDictionary *wrongVersion = [TaggedExchange(ExecStartedResponse(@"r1"), @[])
      mutableCopy];
  NSMutableDictionary *mutableWrong = [wrongVersion mutableCopy];
  mutableWrong[@"protocol_version"] = @2;
  NSDictionary *parsedWrong =
      [DSHClaudeOfficialSession parseControlExchange:mutableWrong];
  XCTAssertNil(parsedWrong[@"execution_id"]);
  NSDictionary *failed = [TaggedExchange(
      @{ @"id": @"r1", @"status": @"error",
         @"error": @{ @"code": @"internal", @"message": @"boom" } }, @[])
      mutableCopy];
  NSMutableDictionary *mutableFailed = [failed mutableCopy];
  mutableFailed[@"ok"] = @NO;
  NSDictionary *parsedFailed =
      [DSHClaudeOfficialSession parseControlExchange:mutableFailed];
  XCTAssertEqualObjects(parsedFailed[@"ok"], @NO);
  XCTAssertNil(parsedFailed[@"streams"]);
}

- (void)testParseControlExchangeReadsTaggedExecStartedStreamAndExit {
  NSDictionary *parsed = [DSHClaudeOfficialSession parseControlExchange:
      TaggedExchange(ExecStartedResponse(@"host-1"), @[
        StreamEvent(Base64Of(@"Visit https://claude.ai"), @"stdout"),
        ProcessExitedEvent(@0),
      ])];
  XCTAssertEqualObjects(parsed[@"execution_id"], @"exec-1");
  XCTAssertEqualObjects(parsed[@"request_id"], @"host-1");
  NSArray *streams = parsed[@"streams"];
  XCTAssertEqual(streams.count, (NSUInteger)1);
  XCTAssertEqualObjects([[NSString alloc] initWithData:streams[0]
                                               encoding:NSUTF8StringEncoding],
                        @"Visit https://claude.ai");
  XCTAssertEqualObjects(parsed[@"exited"], @0);
}

- (void)testParseControlExchangeRejectsNonProductionSketch {
  NSDictionary *parsed = [DSHClaudeOfficialSession parseControlExchange:@{
    @"protocol_version": @1,
    @"ok": @YES,
    @"exchange": @{
      @"response": @{
        @"id": @"r2",
        @"outcome": @{ @"status": @"success" },
        @"result": @{ @"result": @"exec_started", @"execution_id": @"exec-9" },
      },
      @"events": @[
        @{ @"sequence": @1,
           @"event": @{ @"event": @"stream", @"channel": @"stdout",
                        @"data_base64": Base64Of(@"x") } },
        @{ @"event": @{ @"event": @"process_exited", @"exit_code": @3 } },
      ],
    },
  }];
  XCTAssertEqualObjects(parsed, @{});
}

- (void)testParseControlExchangeDropsOversizedStreamEvents {
  NSMutableData *big = [NSMutableData dataWithLength:64 * 1024 + 1];
  NSString *encoded = [big base64EncodedStringWithOptions:0];
  NSDictionary *parsed = [DSHClaudeOfficialSession parseControlExchange:
      TaggedExchange(ExecStartedResponse(@"r"), @[
        StreamEvent(encoded, @"stdout"),
        ProcessExitedEvent(@0),
      ])];
  XCTAssertEqualObjects(parsed, @{});
}

- (void)testParseControlExchangeIgnoresInvalidBase64AndNonDictionaryEvents {
  NSDictionary *parsed = [DSHClaudeOfficialSession parseControlExchange:
      TaggedExchange(ExecStartedResponse(@"r"), @[
        @"not-a-dict",
        StreamEvent(@"!!!not-base64!!!", @"stdout"),
        // process_exited with a missing exit_code still counts as an exit.
        @{
          @"event_type": @"process_exited",
          @"event": @{ @"execution_id": @"exec-1" },
        },
      ])];
  XCTAssertEqualObjects(parsed, @{});
}

#pragma mark Pure parser: auth status and code validation

- (void)testAuthStatusRequiresClaudeSubscription {
  NSDictionary *subscription = [DSHClaudeOfficialSession authStatusFromGuestJSON:@{
    @"loggedIn": @YES,
    @"authMethod": @"claude.ai",
  }];
  XCTAssertTrue([subscription[@"subscription"] boolValue]);
  NSDictionary *apiKey = [DSHClaudeOfficialSession authStatusFromGuestJSON:@{
    @"loggedIn": @YES,
    @"authMethod": @"apiKey",
  }];
  XCTAssertFalse([apiKey[@"subscription"] boolValue]);
  NSDictionary *loggedOut = [DSHClaudeOfficialSession
      authStatusFromGuestJSON:@{ @"loggedIn": @NO }];
  XCTAssertFalse([loggedOut[@"subscription"] boolValue]);
  XCTAssertFalse([[DSHClaudeOfficialSession authStatusFromGuestJSON:nil]
      [@"subscription"] boolValue]);
  NSDictionary *snakeCase = [DSHClaudeOfficialSession authStatusFromGuestJSON:@{
    @"logged_in": @YES, @"auth_method": @"claude.ai subscription",
  }];
  XCTAssertTrue([snakeCase[@"subscription"] boolValue]);
}

- (void)testValidatedLoginCodeRejectsUnsafeInput {
  XCTAssertEqualObjects([DSHClaudeOfficialSession validatedLoginCode:@"ABCD-EFGH"],
                        @"ABCD-EFGH");
  XCTAssertEqualObjects(
      [DSHClaudeOfficialSession validatedLoginCode:@"0123456789"],
      @"0123456789");
  XCTAssertNil([DSHClaudeOfficialSession validatedLoginCode:@""]);
  XCTAssertNil([DSHClaudeOfficialSession validatedLoginCode:nil]);
  XCTAssertNil([DSHClaudeOfficialSession validatedLoginCode:(
      [NSString stringWithFormat:@"%C", (unichar)0x01])]);
  XCTAssertNil([DSHClaudeOfficialSession validatedLoginCode:@"AB\nCD"]);
  XCTAssertNil([DSHClaudeOfficialSession validatedLoginCode:@"AB CD\t"]);
  XCTAssertEqualObjects([DSHClaudeOfficialSession validatedLoginCode:@"yes; rm -rf /"],
                        @"yes; rm -rf /");
  XCTAssertNil([DSHClaudeOfficialSession validatedLoginCode:(
      [NSString stringWithFormat:@"AB%C CD", (unichar)0x7f])]);
  XCTAssertNil([DSHClaudeOfficialSession validatedLoginCode:@"ＡＢＣＤ"]);
  NSString *longCode =
      [@"" stringByPaddingToLength:2049 withString:@"A" startingAtIndex:0];
  XCTAssertNil([DSHClaudeOfficialSession validatedLoginCode:longCode]);
}

#pragma mark Status contract

- (void)testStatusReportsUnavailableWhenRuntimeMissing {
  DSHClaudeOfficialSession *session =
      [[DSHClaudeOfficialSession alloc] initWithKernelURL:nil
                                                initrdURL:nil
                                         storageDirectory:nil
                                                 version:@""];
  NSDictionary *status = session.status;
  XCTAssertEqualObjects(status[@"schema_version"], @1);
  XCTAssertEqualObjects(status[@"harness_id"], @"claude-code");
  XCTAssertEqualObjects(status[@"runtime"][@"kind"], @"official-cli");
  XCTAssertFalse([status[@"runtime"][@"available"] boolValue]);
  XCTAssertEqualObjects(status[@"status"], @"unavailable");
  XCTAssertEqualObjects(status[@"auth_method"], @"none");
  XCTAssertNil(status[@"login"]);
}

- (void)testStartLoginReportsUnavailableWithoutRuntime {
  DSHClaudeOfficialSession *session =
      [[DSHClaudeOfficialSession alloc] initWithKernelURL:nil
                                                initrdURL:nil
                                         storageDirectory:nil
                                                 version:@""];
  XCTestExpectation *expectation =
      [self expectationWithDescription:@"unavailable completion"];
  __block NSDictionary *received = nil;
  [session startLogin:^(NSDictionary *status) {
    received = status;
    [expectation fulfill];
  }];
  [self waitForExpectations:@[ expectation ] timeout:5];
  XCTAssertEqualObjects(received[@"status"], @"unavailable");
}

#pragma mark Session and input guards

- (DSHClaudeOfficialSession *)injectedSessionWithGuest:(DSHClaudeFakeGuest *)guest
                                          storage:(NSURL *)storage {
  DSHClaudeOfficialSession *session =
      [[DSHClaudeOfficialSession alloc] initWithKernelURL:
          [NSURL fileURLWithPath:@"/fake/kernel"]
                                                initrdURL:
          [NSURL fileURLWithPath:@"/fake/initrd"]
                                         storageDirectory:storage
                                                 version:@"1.2.3-test"];
  session.controlExchangeOverride = ^NSDictionary *(NSDictionary *request) {
    return [guest exchangeForRequest:request];
  };
  session.guestBootOverride = ^BOOL(NSDictionary *request) {
    return [guest boot:request];
  };
  [self.injectedSessions addObject:session];
  return session;
}

- (void)testSubmitCodeRejectsUnknownSessionWithoutTouchingGuest {
  DSHClaudeFakeGuest *guest = [DSHClaudeFakeGuest new];
  DSHClaudeOfficialSession *session =
      [self injectedSessionWithGuest:guest storage:TemporaryStorageDirectory()];
  XCTestExpectation *expectation =
      [self expectationWithDescription:@"submit rejected"];
  __block NSDictionary *received = nil;
  [session submitCode:@"ABCD-EFGH"
              session:@"00000000-0000-0000-0000-000000000000"
           completion:^(NSDictionary *status) {
             received = status;
             [expectation fulfill];
           }];
  [self waitForExpectations:@[ expectation ] timeout:5];
  XCTAssertEqualObjects(received[@"status"], @"error");
  XCTAssertEqualObjects(received[@"error_code"], @"E_CLAUDE_OFFICIAL_SESSION_NOT_FOUND");
  XCTAssertEqual(guest.requests.count, (NSUInteger)0);
}

- (void)testCancelSessionRejectsMalformedSessionId {
  DSHClaudeFakeGuest *guest = [DSHClaudeFakeGuest new];
  DSHClaudeOfficialSession *session =
      [self injectedSessionWithGuest:guest storage:TemporaryStorageDirectory()];
  XCTestExpectation *expectation =
      [self expectationWithDescription:@"cancel rejected"];
  __block NSDictionary *received = nil;
  [session cancelSession:@"" completion:^(NSDictionary *status) {
    received = status;
    [expectation fulfill];
  }];
  [self waitForExpectations:@[ expectation ] timeout:5];
  XCTAssertEqualObjects(received[@"error_code"],
                        @"E_CLAUDE_OFFICIAL_SESSION_INVALID");
  XCTAssertEqual(guest.requests.count, (NSUInteger)0);
}

#pragma mark Injected-exchange flows

- (void)pollUntil:(BOOL (^)(void))condition
         timeout:(NSTimeInterval)timeout
      description:(NSString *)description {
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  while ([deadline timeIntervalSinceNow] > 0) {
    if (condition()) return;
    [NSThread sleepForTimeInterval:0.05];
  }
  XCTFail(@"Timed out waiting for %@", description);
}

- (void)testDeadlineAndCancelRespondWhileControlQueueIsBlocked {
  DSHClaudeOfficialSession *session = [self injectedSessionWithGuest:[DSHClaudeFakeGuest new] storage:TemporaryStorageDirectory()];
  [session setValue:@"blocked" forKey:@"activeSessionId"];
  [session setValue:@1 forKey:@"generation"];
  [session setValue:@0 forKey:@"loginExpiresAt"];
  dispatch_queue_t queue = [session valueForKey:@"queue"];
  dispatch_semaphore_t release = dispatch_semaphore_create(0);
  dispatch_async(queue, ^{ dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER); });
  [session watchLoginSession:@"blocked" generation:1];
  [self pollUntil:^BOOL { return [session.status[@"error_code"] isEqual:@"E_CLAUDE_OFFICIAL_LOGIN_TIMEOUT"]; } timeout:3 description:@"independent deadline"];
  XCTAssertEqualObjects(session.status[@"runtime"][@"reason"], @"waiting_for_cleanup");
  dispatch_semaphore_signal(release);
}

- (void)testBrowserAuthorizationDoesNotInheritNearlyExpiredStartupDeadline {
  DSHClaudeOfficialSession *session = [self injectedSessionWithGuest:[DSHClaudeFakeGuest new] storage:TemporaryStorageDirectory()];
  [session setValue:@"slow-start" forKey:@"activeSessionId"];
  [session setValue:@"starting" forKey:@"activePhase"];
  [session setValue:@(NSDate.date.timeIntervalSince1970 + 2) forKey:@"loginExpiresAt"];
  [session ingestLoginChunk:[@"Visit https://claude.com/cai/oauth/authorize?code=true&state=fixture\n" dataUsingEncoding:NSUTF8StringEncoding]];
  NSDictionary *login = session.status[@"login"];
  XCTAssertEqualObjects(login[@"phase"], @"waiting_for_browser");
  XCTAssertGreaterThan([login[@"expires_at"] doubleValue] - NSDate.date.timeIntervalSince1970, 1700);
  [session ingestLoginChunk:[@"Waiting for authorization\n" dataUsingEncoding:NSUTF8StringEncoding]];
  XCTAssertEqualObjects(login[@"expires_at"], session.status[@"login"][@"expires_at"]);
}

- (void)testInjectedLoginReachesSignedInViaVerifiedSubscriptionOnly {
  NSURL *storage = TemporaryStorageDirectory();
  DSHClaudeFakeGuest *guest = [DSHClaudeFakeGuest new];
  guest.loginOutput =
      @"Visit https://claude.com/cai/oauth/authorize?code=true&state=abc123 to sign in.\n"
      @"One-time code:\nABCD-EFGH\n";
  guest.statusOutput = @"{\"loggedIn\":true,\"authMethod\":\"claude.ai\"}";
  DSHClaudeOfficialSession *session =
      [self injectedSessionWithGuest:guest storage:storage];

  XCTestExpectation *started = [self expectationWithDescription:@"login started"];
  __block NSString *sessionId = nil;
  [session startLogin:^(NSDictionary *status) {
    sessionId = status[@"login"][@"session_id"];
    XCTAssertEqualObjects(status[@"status"], @"authorizing");
    XCTAssertEqualObjects(status[@"login"][@"phase"], @"starting");
    [started fulfill];
  }];
  [self waitForExpectations:@[ started ] timeout:5];

  // The unmodified binary and original flags are used, unmodified protocol
  // shape is sent, and no host environment leaks into exec env.
  [self pollUntil:^BOOL {
    return [session.status[@"status"] isEqual:@"signed_in"];
  } timeout:10 description:@"signed_in"];
  NSArray *argvLines = [guest executedArgvLines];
  XCTAssertTrue([argvLines containsObject:
      @"/mnt/claude/cli/claude auth login --claudeai"]);
  XCTAssertTrue([argvLines containsObject:@"/mnt/claude/cli/claude auth status --json"]);
  XCTAssertTrue([argvLines containsObject:@"sync"]);
  XCTAssertTrue(session.shouldRestoreSavedSession);
  BOOL sawExec = NO;
  for (NSDictionary *request in guest.requests) {
    if (![request[@"operation"] isEqual:@"exec"]) continue;
    sawExec = YES;
    NSDictionary *parameters = request[@"parameters"];
    XCTAssertEqualObjects(parameters[@"cwd"], @"/");
    XCTAssertFalse([parameters[@"tty"] boolValue]);
    BOOL isLogin = [parameters[@"argv"] containsObject:@"login"];
    XCTAssertEqual([parameters[@"attach_stdin"] boolValue], isLogin);
    XCTAssertTrue([parameters[@"attach_stdout"] boolValue]);
    XCTAssertTrue([parameters[@"attach_stderr"] boolValue]);
    XCTAssertEqualObjects(parameters[@"timeout_ms"], @600000);
    NSDictionary *env = parameters[@"env"];
    if (![parameters[@"argv"][0] isEqual:@"/mnt/claude/cli/claude"]) continue;
    XCTAssertEqualObjects(env[@"HOME"], @"/mnt/claude/home");
    XCTAssertEqualObjects(env[@"CLAUDE_CONFIG_DIR"], @"/mnt/claude/home/.claude");
    XCTAssertEqualObjects(env[@"SIMDUTF_FORCE_IMPLEMENTATION"], @"westmere");
    XCTAssertEqualObjects(env[@"DISABLE_AUTOUPDATER"], @"1");
    for (NSString *key in env) {
      XCTAssertTrue([key isEqualToString:@"HOME"] ||
                    [key isEqualToString:@"CLAUDE_CONFIG_DIR"] ||
                    [key isEqualToString:@"SIMDUTF_FORCE_IMPLEMENTATION"] ||
                    [key isEqualToString:@"DISABLE_AUTOUPDATER"] ||
                    [key isEqualToString:@"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] ||
                    [key isEqualToString:@"PATH"]);
    }
  }
  XCTAssertTrue(sawExec);
  // Disk image created, sparse-sized, and mkfs ran exactly once.
  NSURL *disk = [storage URLByAppendingPathComponent:@"guest-home.img"];
  NSDictionary *attributes =
      [[NSFileManager defaultManager] attributesOfItemAtPath:disk.path error:nil];
  XCTAssertEqualObjects(attributes[NSFileSize], @(64 * 1024 * 1024));
  XCTAssertEqual(guest.formatCalls, (NSUInteger)1);
  XCTAssertEqualObjects(session.status[@"auth_method"], @"subscription");

  // Logout runs the official command and syncs, never deleting the disk.
  XCTestExpectation *loggedOut = [self expectationWithDescription:@"logout"];
  [session logout:^(NSDictionary *status) {
    XCTAssertEqualObjects(status[@"status"], @"signed_out");
    XCTAssertEqualObjects(status[@"auth_method"], @"none");
    [loggedOut fulfill];
  }];
  [self waitForExpectations:@[ loggedOut ] timeout:10];
  XCTAssertTrue([[guest executedArgvLines] containsObject:
      @"/mnt/claude/cli/claude auth logout"]);
  XCTAssertTrue([[NSFileManager defaultManager]
      fileExistsAtPath:[storage URLByAppendingPathComponent:@"guest-home.img"].path]);
}

- (void)testLoginWithoutSubscriptionVerificationNeverReportsSignedIn {
  // ProcessExited with exit 0 alone must be insufficient: the guest CLI
  // reports a non-subscription auth method, so the actor stays signed_out.
  DSHClaudeFakeGuest *guest = [DSHClaudeFakeGuest new];
  guest.loginExitCode = 0;
  guest.statusOutput = @"{\"loggedIn\":true,\"authMethod\":\"apiKey\"}";
  DSHClaudeOfficialSession *session =
      [self injectedSessionWithGuest:guest storage:TemporaryStorageDirectory()];
  XCTestExpectation *started = [self expectationWithDescription:@"login started"];
  [session startLogin:^(NSDictionary *status) {
    XCTAssertEqualObjects(status[@"status"], @"authorizing");
    [started fulfill];
  }];
  [self waitForExpectations:@[ started ] timeout:5];
  [self pollUntil:^BOOL {
    return [session.status[@"status"] isEqualToString:@"error"];
  } timeout:10 description:@"login failure"];
  XCTAssertEqualObjects(session.status[@"error_code"],
                        @"E_CLAUDE_OFFICIAL_LOGIN_FAILED");
}

- (void)testFailedLoginDiagnosticsRedactAuthorizationURL {
  NSURL *storage = TemporaryStorageDirectory();
  DSHClaudeFakeGuest *guest = [DSHClaudeFakeGuest new];
  guest.loginExitCode = 1;
  guest.loginOutput = @"Error: fetch failed https://claude.ai/oauth/authorize?state=private-fixture-state\n";
  DSHClaudeOfficialSession *session = [self injectedSessionWithGuest:guest storage:storage];
  XCTestExpectation *started = [self expectationWithDescription:@"diagnostic login"];
  [session startLogin:^(__unused NSDictionary *status) { [started fulfill]; }];
  [self waitForExpectations:@[started] timeout:5];
  [self pollUntil:^BOOL { return [session.status[@"status"] isEqual:@"error"]; } timeout:5 description:@"diagnostic failure"];
  NSString *log = [NSString stringWithContentsOfURL:[storage URLByAppendingPathComponent:@"diagnostics.json"] encoding:NSUTF8StringEncoding error:nil];
  XCTAssertTrue([log containsString:@"fetch failed"]);
  XCTAssertFalse([log containsString:@"private-fixture-state"]);
  XCTAssertTrue([log containsString:@"cli_exit"]);
}

- (void)testCorruptConfigurationIsBackedUpAndLoginRetried {
  DSHClaudeFakeGuest *guest = [DSHClaudeFakeGuest new];
  guest.loginExitCode = 1;
  guest.loginOutput = @"Claude configuration file at /mnt/claude/home/.claude/.claude.json is corrupted: JSON Parse error: Unexpected EOF";
  guest.statusOutput = @"{\"loggedIn\":true,\"authMethod\":\"claude.ai\"}";
  DSHClaudeOfficialSession *session = [self injectedSessionWithGuest:guest storage:TemporaryStorageDirectory()];
  XCTestExpectation *started = [self expectationWithDescription:@"repair login"];
  [session startLogin:^(__unused NSDictionary *status) { [started fulfill]; }];
  [self waitForExpectations:@[started] timeout:5];
  [self pollUntil:^BOOL { return [session.status[@"status"] isEqual:@"signed_in"]; } timeout:5 description:@"repaired configuration"];
  XCTAssertEqual(guest.configurationBackupCalls, 1u);
  XCTAssertEqual(guest.formatCalls, 1u);
}

- (void)testLoginCapturesOnlyTheAllowlistedVerificationURL {
  DSHClaudeFakeGuest *guest = [DSHClaudeFakeGuest new];
  guest.loginOutput =
      @"Visit https://claude.ai/oauth/authorize?state=abc&code_challenge=x or "
      @"https://evil.example/oauth/authorize?access_token=stolen";
  DSHClaudeOfficialSession *session =
      [self injectedSessionWithGuest:guest storage:TemporaryStorageDirectory()];
  XCTestExpectation *started = [self expectationWithDescription:@"login started"];
  [session startLogin:^(NSDictionary *status) { [started fulfill]; }];
  [self waitForExpectations:@[ started ] timeout:5];
  [self pollUntil:^BOOL {
    NSString *phase = session.status[@"login"][@"phase"];
    return [phase isEqualToString:@"waiting_for_browser"];
  } timeout:10 description:@"waiting_for_browser"];
  NSDictionary *login = session.status[@"login"];
  XCTAssertEqualObjects(login[@"verification_url"],
                        @"https://claude.ai/oauth/authorize?state=abc&code_challenge=x");
  // Bounded exposure: no output blob, no user_code passthrough here.
  XCTAssertNil(login[@"output"]);
  XCTAssertNil(login[@"user_code"]);
}

- (void)testLoginOutputCaptureIsBounded {
  DSHClaudeFakeGuest *guest = [DSHClaudeFakeGuest new];
  NSMutableString *huge = [NSMutableString string];
  while (huge.length < 200 * 1024) {
    [huge appendString:@"Visit https://claude.ai/oauth/authorize?state=abc "
                      @"fillerfillerfiller\n"];
  }
  guest.loginOutput = huge.copy;
  guest.statusOutput = @"{\"loggedIn\":true,\"authMethod\":\"claude.ai\"}";
  DSHClaudeOfficialSession *session =
      [self injectedSessionWithGuest:guest storage:TemporaryStorageDirectory()];
  XCTestExpectation *started = [self expectationWithDescription:@"login started"];
  [session startLogin:^(NSDictionary *status) { [started fulfill]; }];
  [self waitForExpectations:@[ started ] timeout:5];
  [self pollUntil:^BOOL {
    return [session.status[@"status"] isEqual:@"error"];
  } timeout:15 description:@"oversized output rejected"];
  XCTAssertEqualObjects(session.status[@"auth_method"], @"none");
  XCTAssertNil(session.status[@"login"]);
}

- (void)testExistingDiskMountFailureFailsClosedWithoutReformat {
  NSURL *storage = TemporaryStorageDirectory();
  NSURL *disk = [storage URLByAppendingPathComponent:@"guest-home.img"];
  // Pre-existing image bytes: must never be formatted or inspected.
  [[NSFileManager defaultManager] createFileAtPath:disk.path
                                          contents:[@"existing-image" dataUsingEncoding:NSUTF8StringEncoding]
                                        attributes:nil];
  DSHClaudeFakeGuest *guest = [DSHClaudeFakeGuest new];
  guest.mountFails = YES;
  DSHClaudeOfficialSession *session =
      [self injectedSessionWithGuest:guest storage:storage];
  XCTestExpectation *refreshed = [self expectationWithDescription:@"refresh"];
  [session refresh:^(NSDictionary *status) {
    XCTAssertEqualObjects(status[@"status"], @"error");
    XCTAssertEqualObjects(status[@"error_code"],
                          @"E_CLAUDE_OFFICIAL_DISK_MOUNT_FAILED");
    [refreshed fulfill];
  }];
  [self waitForExpectations:@[ refreshed ] timeout:10];
  XCTAssertEqual(guest.formatCalls, (NSUInteger)0);
  NSData *bytes = [NSData dataWithContentsOfURL:disk];
  XCTAssertEqualObjects(bytes, [@"existing-image" dataUsingEncoding:NSUTF8StringEncoding]);
}

- (void)testRefreshFailureDoesNotReportSignedOut {
  DSHClaudeFakeGuest *guest = [DSHClaudeFakeGuest new];
  DSHClaudeOfficialSession *session =
      [self injectedSessionWithGuest:guest storage:TemporaryStorageDirectory()];
  session.controlExchangeOverride = ^NSDictionary *(NSDictionary *request) {
    if ([request[@"operation"] isEqual:@"exec"] &&
        [[request[@"parameters"][@"argv"] componentsJoinedByString:@" "] hasSuffix:@"auth status --json"]) {
      return @{ @"protocol_version": @1, @"ok": @NO };
    }
    return [guest exchangeForRequest:request];
  };
  XCTestExpectation *done = [self expectationWithDescription:@"restore failure"];
  [session refresh:^(NSDictionary *status) {
    XCTAssertEqualObjects(status[@"status"], @"error");
    XCTAssertEqualObjects(status[@"error_code"], @"E_CLAUDE_OFFICIAL_LOGIN_TIMEOUT");
    [done fulfill];
  }];
  [self waitForExpectations:@[done] timeout:5];
}

- (void)testAnUnverifiedDiskDoesNotScheduleAutomaticRestore {
  NSURL *storage = TemporaryStorageDirectory();
  [NSFileManager.defaultManager createDirectoryAtURL:storage withIntermediateDirectories:YES attributes:nil error:nil];
  [NSData.data writeToURL:[storage URLByAppendingPathComponent:@"guest-home.img"] atomically:YES];
  DSHClaudeOfficialSession *session = [self injectedSessionWithGuest:[DSHClaudeFakeGuest new] storage:storage];
  XCTAssertFalse(session.shouldRestoreSavedSession);
  XCTAssertEqualObjects(session.status[@"status"], @"signed_out");
}

- (void)testRefreshReportsSignedOutWhenGuestIsNotLoggedIn {
  DSHClaudeFakeGuest *guest = [DSHClaudeFakeGuest new];
  guest.statusOutput = @"{\"loggedIn\":false}";
  DSHClaudeOfficialSession *session =
      [self injectedSessionWithGuest:guest storage:TemporaryStorageDirectory()];
  XCTAssertEqualObjects(session.status[@"status"], @"signed_out");
  XCTestExpectation *refreshed = [self expectationWithDescription:@"refresh"];
  __block NSDictionary *received = nil;
  [session refresh:^(NSDictionary *status) {
    received = status;
    [refreshed fulfill];
  }];
  [self waitForExpectations:@[ refreshed ] timeout:10];
  XCTAssertEqualObjects(received[@"status"], @"signed_out");
  XCTAssertEqualObjects(received[@"auth_method"], @"none");
  XCTAssertNil(received[@"login"]);
}

- (void)testCompleteTextRequestUsesOfficialCLIAndPrivateStdin {
  DSHClaudeFakeGuest *guest = [DSHClaudeFakeGuest new];
  DSHClaudeOfficialSession *session = [self injectedSessionWithGuest:guest storage:TemporaryStorageDirectory()];
  [session setValue:@YES forKey:@"signedIn"];
  XCTestExpectation *done = [self expectationWithDescription:@"text completion"];
  [session completeTextRequest:@{ @"request_id": @"req-1", @"model": @"claude-haiku-4-5-20251001", @"prompt": @"hello" }
                    completion:^(NSDictionary *result, NSString *errorCode) {
    XCTAssertNil(errorCode);
    XCTAssertEqualObjects(result[@"text"], @"hello");
  XCTAssertEqualObjects(result[@"model"], @"claude-haiku-4-5-20251001");
    [done fulfill];
  }];
  [self waitForExpectations:@[done] timeout:10];
  XCTAssertNotNil(guest.lastStdinBase64);
  XCTAssertTrue([[guest executedArgvLines] containsObject:@"/mnt/claude/cli/claude -p --safe-mode --output-format json --tools= --max-turns 1 --no-session-persistence --strict-mcp-config --mcp-config {\"mcpServers\":{}} --setting-sources= --settings {\"alwaysThinkingEnabled\":false} --model claude-haiku-4-5-20251001"]);
  for (NSString *line in [guest executedArgvLines]) XCTAssertFalse([line containsString:@"hello"]);
  BOOL sawTextExec = NO;
  for (NSDictionary *request in guest.requests) {
    if (![request[@"operation"] isEqual:@"exec"]) continue;
    NSDictionary *parameters = request[@"parameters"];
    if ([parameters[@"argv"] containsObject:@"-p"]) {
      sawTextExec = YES;
      XCTAssertEqualObjects(parameters[@"timeout_ms"], @1800000);
      XCTAssertTrue([parameters[@"attach_stdin"] boolValue]);
    } else {
      // Boot/auth/support commands keep the existing guest-clock bound.
      XCTAssertEqualObjects(parameters[@"timeout_ms"], @600000);
    }
  }
  XCTAssertTrue(sawTextExec);
}

- (void)testPrintModeFailureResultIsBoundedAndRedactedInDiagnostics {
  DSHClaudeFakeGuest *guest = [DSHClaudeFakeGuest new];
  NSString *token = @"sk-test_000000000000000000000000";
  NSString *message = [NSString stringWithFormat:@"API Error: denied %@ person@example.test https://example.test/token?value=private %@", token, [@"x " stringByPaddingToLength:600 withString:@"x " startingAtIndex:0]];
  NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"type":@"result", @"is_error":@YES, @"result":message, @"api_error_status":@403} options:0 error:nil];
  guest.textOutput = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  guest.textExitCode = 1;
  NSURL *storage = TemporaryStorageDirectory();
  DSHClaudeOfficialSession *session = [self injectedSessionWithGuest:guest storage:storage];
  [session setValue:@YES forKey:@"signedIn"];
  XCTestExpectation *done = [self expectationWithDescription:@"failed text"];
  [session completeTextRequest:@{@"request_id":@"req-error", @"model":@"claude-haiku-4-5-20251001", @"prompt":@"private prompt"}
      completion:^(NSDictionary *result, NSString *errorCode) {
        XCTAssertNil(result);
        XCTAssertEqualObjects(errorCode, @"E_CLAUDE_OFFICIAL_TEXT_FAILED");
        [done fulfill];
      }];
  [self waitForExpectations:@[done] timeout:10];
  NSData *record = [NSData dataWithContentsOfURL:[storage URLByAppendingPathComponent:@"diagnostics.json"]];
  NSArray *entries = [NSJSONSerialization JSONObjectWithData:record options:0 error:nil];
  NSDictionary *details = [entries lastObject][@"details"];
  XCTAssertEqualObjects(details[@"api_error_status"], @403);
  XCTAssertEqual([details[@"errors"] count], (NSUInteger)1);
  NSString *safe = [details[@"errors"] firstObject];
  XCTAssertTrue([safe hasPrefix:@"API Error: denied [redacted] [redacted] [redacted]"]);
  XCTAssertLessThanOrEqual(safe.length, (NSUInteger)400);
  NSString *encoded = [[NSString alloc] initWithData:record encoding:NSUTF8StringEncoding];
  for (NSString *privateValue in @[token, @"person@example.test", @"https://example.test", @"private prompt"]) XCTAssertFalse([encoded containsString:privateValue]);
}

- (void)testCompleteTextRequestCancellationOwnsGeneration {
  DSHClaudeFakeGuest *guest = [DSHClaudeFakeGuest new];
  guest.holdTextResult = YES;
  DSHClaudeOfficialSession *session = [self injectedSessionWithGuest:guest storage:TemporaryStorageDirectory()];
  [session setValue:@YES forKey:@"signedIn"];
  XCTestExpectation *done = [self expectationWithDescription:@"cancelled text completion"];
  [session completeTextRequest:@{ @"request_id": @"req-cancel", @"model": @"claude-haiku-4-5-20251001", @"prompt": @"secret" }
                    completion:^(NSDictionary *result, NSString *errorCode) {
    XCTAssertNil(result);
    XCTAssertEqualObjects(errorCode, @"E_CLAUDE_OFFICIAL_TEXT_CANCELLED");
    [done fulfill];
  }];
  [self pollUntil:^BOOL { return [session valueForKey:@"activeTextRequestId"] != nil; } timeout:5 description:@"text request ownership"];
  [session cancelTextRequest:@"req-cancel"];
  [self waitForExpectations:@[done] timeout:10];
}

- (void)testCompleteTextRequestCancelBeforeQueueRegistrationDoesNotLaunch {
  DSHClaudeFakeGuest *guest = [DSHClaudeFakeGuest new];
  DSHClaudeOfficialSession *session = [self injectedSessionWithGuest:guest storage:TemporaryStorageDirectory()];
  [session setValue:@YES forKey:@"signedIn"];
  [session cancelTextRequest:@"req-early"];
  XCTestExpectation *done = [self expectationWithDescription:@"early cancel"];
  [session completeTextRequest:@{ @"request_id": @"req-early", @"model": @"claude-haiku-4-5-20251001", @"prompt": @"secret" }
                    completion:^(NSDictionary *result, NSString *errorCode) {
    XCTAssertNil(result);
    XCTAssertEqualObjects(errorCode, @"E_CLAUDE_OFFICIAL_TEXT_CANCELLED");
    [done fulfill];
  }];
  [self waitForExpectations:@[done] timeout:5];
  XCTAssertEqual(guest.requests.count, (NSUInteger)0);
}

- (void)testCompleteTextRequestRequiresVerifiedSignIn {
  DSHClaudeFakeGuest *guest = [DSHClaudeFakeGuest new];
  DSHClaudeOfficialSession *session = [self injectedSessionWithGuest:guest storage:TemporaryStorageDirectory()];
  XCTestExpectation *done = [self expectationWithDescription:@"auth required"];
  [session completeTextRequest:@{ @"request_id": @"req-out", @"model": @"sonnet", @"prompt": @"secret" }
                    completion:^(NSDictionary *result, NSString *errorCode) {
    XCTAssertNil(result);
    XCTAssertEqualObjects(errorCode, @"E_CLAUDE_OFFICIAL_TEXT_AUTH_REQUIRED");
    [done fulfill];
  }];
  [self waitForExpectations:@[done] timeout:5];
  XCTAssertEqual(guest.requests.count, (NSUInteger)0);
}

- (void)testNormalizedTextResultRejectsNonTextAndNormalizesFragment {
  NSString *model = @"claude-haiku-4-5-20251001";
  XCTAssertNil(([DSHClaudeOfficialSession normalizedTextResultFromJSON:@{ @"type": @"result", @"subtype": @"success", @"is_error": @NO, @"result": @[] } model:model]));
  NSDictionary *result = [DSHClaudeOfficialSession normalizedTextResultFromJSON:@{ @"type": @"result", @"subtype": @"success", @"is_error": @NO, @"session_id": @"s1", @"model": model, @"result": @"ok", @"extra": @"private" } model:model];
  XCTAssertEqualObjects(result, (@{ @"provider_response_id": @"s1", @"model": model, @"text": @"ok", @"reasoning": @"", @"tool_calls": @[], @"finish_reason": @"stop" }));
  XCTAssertNil(([DSHClaudeOfficialSession normalizedTextResultFromJSON:@{ @"type": @"result", @"subtype": @"success", @"is_error": @YES, @"model": model, @"result": @"bad" } model:model]));
}

- (void)testSignalExitPreservesOutputAndIsNotAControlTimeout {
  NSMutableDictionary *event = [ProcessExitedEvent(@0) mutableCopy];
  NSMutableDictionary *payload = [event[@"event"] mutableCopy];
  payload[@"exit_code"] = NSNull.null;
  payload[@"signal"] = @9;
  event[@"event"] = payload;
  NSDictionary *parsed = [DSHClaudeOfficialSession parseControlExchange:TaggedExchange(
      ExecStartedResponse(@"signal-request"), @[StreamEvent(Base64Of(@"partial"), @"stderr"), event])];
  XCTAssertEqualObjects(parsed[@"exited"], @(-1));
  XCTAssertEqualObjects(parsed[@"signal"], @9);
  XCTAssertEqualObjects(parsed[@"stderr_streams"], (@[[@"partial" dataUsingEncoding:NSUTF8StringEncoding]]));
}

#pragma mark Warm guest retention

- (DSHClaudeOfficialSession *)signedInTextSessionWithGuest:(DSHClaudeFakeGuest *)guest {
  DSHClaudeOfficialSession *session = [self injectedSessionWithGuest:guest storage:TemporaryStorageDirectory()];
  [session setValue:@YES forKey:@"signedIn"];
  return session;
}

- (void)completeOneTextOnSession:(DSHClaudeOfficialSession *)session
                       requestId:(NSString *)requestId {
  XCTestExpectation *done = [self expectationWithDescription:requestId];
  [session completeTextRequest:@{ @"request_id": requestId, @"model": @"claude-haiku-4-5-20251001", @"prompt": @"hi" }
                    completion:^(NSDictionary *result, NSString *errorCode) {
    XCTAssertNil(errorCode);
    XCTAssertEqualObjects(result[@"text"], @"hello");
    [done fulfill];
  }];
  [self waitForExpectations:@[done] timeout:10];
}

- (void)testSuccessfulTextRetainsHealthyGuestForTheNextRequest {
  DSHClaudeFakeGuest *guest = [DSHClaudeFakeGuest new];
  DSHClaudeOfficialSession *session = [self signedInTextSessionWithGuest:guest];
  [self completeOneTextOnSession:session requestId:@"warm-1"];
  XCTAssertEqual(guest.bootCalls, (NSUInteger)1);
  [self completeOneTextOnSession:session requestId:@"warm-2"];
  // The second request reuses the still-healthy guest instead of rebooting.
  XCTAssertEqual(guest.bootCalls, (NSUInteger)1);
}

- (void)testFailedTextReleasesGuestSoTheNextRequestBootsFresh {
  DSHClaudeFakeGuest *guest = [DSHClaudeFakeGuest new];
  guest.textExitCode = 1;
  DSHClaudeOfficialSession *session = [self signedInTextSessionWithGuest:guest];
  XCTestExpectation *failed = [self expectationWithDescription:@"failed text"];
  [session completeTextRequest:@{ @"request_id": @"cold-1", @"model": @"claude-haiku-4-5-20251001", @"prompt": @"hi" }
                    completion:^(NSDictionary *result, NSString *errorCode) {
    XCTAssertNil(result);
    XCTAssertEqualObjects(errorCode, @"E_CLAUDE_OFFICIAL_TEXT_FAILED");
    [failed fulfill];
  }];
  [self waitForExpectations:@[failed] timeout:10];
  XCTAssertEqual(guest.bootCalls, (NSUInteger)1);
  guest.textExitCode = 0;
  [self completeOneTextOnSession:session requestId:@"cold-2"];
  XCTAssertEqual(guest.bootCalls, (NSUInteger)2);
}

- (void)testMemoryWarningEvictsIdleGuestBeforeTheNextRequest {
  DSHClaudeFakeGuest *guest = [DSHClaudeFakeGuest new];
  DSHClaudeOfficialSession *session = [self signedInTextSessionWithGuest:guest];
  [self completeOneTextOnSession:session requestId:@"press-1"];
  XCTAssertEqual(guest.bootCalls, (NSUInteger)1);
  // Eviction is dispatched on the same serial worker queue as the next text
  // request, so it deterministically runs before the following boot check.
  [NSNotificationCenter.defaultCenter postNotificationName:@"UIApplicationDidReceiveMemoryWarningNotification" object:nil];
  [self completeOneTextOnSession:session requestId:@"press-2"];
  XCTAssertEqual(guest.bootCalls, (NSUInteger)2);
}

- (void)testTextRequestsDoNotRunAnExtraStartupVersionProbe {
  DSHClaudeFakeGuest *guest = [DSHClaudeFakeGuest new];
  DSHClaudeOfficialSession *session = [self signedInTextSessionWithGuest:guest];
  [self completeOneTextOnSession:session requestId:@"probe-1"];
  [self completeOneTextOnSession:session requestId:@"probe-2"];
  NSUInteger versionExecs = 0;
  for (NSString *line in [guest executedArgvLines]) {
    if ([line hasSuffix:@"claude --version"]) versionExecs += 1;
  }
  XCTAssertEqual(versionExecs, (NSUInteger)0);
}

@end
