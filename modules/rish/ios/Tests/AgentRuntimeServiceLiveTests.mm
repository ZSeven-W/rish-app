#import <XCTest/XCTest.h>
#import "AgentRuntimeServiceLiveFixture.h"
#import "AgentRootResolver.h"
#import "AgentRuntimeToolContracts.h"
#import "DSHAgentRuntimeToolExecutor.h"
#import "DSHGuestRuntimeState.h"
#import "DSHTestStorageFixture.h"
#import "LocalGuestModule.h"
#import "RuntimeProgramServiceVM.h"
#import "RuntimeServiceDiagnosticVM.h"
#include <arpa/inet.h>
#include <poll.h>
#include <sys/socket.h>

// Opt-in integration gate: actual release packages, Documents workspace,
// language VM, guest HTTP server, native loopback proxy and cross-attempt stop.
@interface AgentRuntimeServiceLiveTests : XCTestCase
@property(nonatomic, strong) NSURL *fixtureRoot;
@property(nonatomic, strong) NSURL *packageDirectory;
@property(nonatomic, strong) NSURL *sourceDirectory;
@property(nonatomic, copy) NSDictionary *packages;
@property(nonatomic, strong) DSHLocalWorkspaceAccess *workspaces;
@property(nonatomic, strong) DSHAgentRootResolver *resolver;
@property(nonatomic, strong) DSHRuntimeEnvironmentStore *store;
@property(nonatomic, strong) DSHAgentRuntimeToolExecutor *executor;
@property(nonatomic, copy) NSDictionary *root;
@property(nonatomic, copy) NSString *conversationId;
@property(nonatomic, copy) NSString *environmentId;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *owners;
@property(nonatomic) BOOL importing;
@property(nonatomic) BOOL executing;
@end

@implementation AgentRuntimeServiceLiveTests
- (void)setUp {
  [super setUp]; self.continueAfterFailure = NO; self.executionTimeAllowance = 1900;
  NSDictionary *environment = NSProcessInfo.processInfo.environment;
  XCTSkipIf(![environment[@"RISH_RUNTIME_SERVICES_LIVE"] isEqual:@"1"],
      @"Enable RISH_RUNTIME_SERVICES_LIVE=1 for the independent six-language HTTP gate.");
  for (NSString *key in @[@"RISH_RUNTIME_ENVIRONMENTS_FIXTURE_DIR", @"RISH_RUNTIME_SERVICES_SOURCE_DIR"]) {
    NSString *path = environment[key];
    XCTAssertTrue([path isKindOfClass:NSString.class] && [path hasPrefix:@"/"] && ![path containsString:@"\0"], @"%@ must be an absolute native fixture path.", key);
  }
  self.packageDirectory = [NSURL fileURLWithPath:environment[@"RISH_RUNTIME_ENVIRONMENTS_FIXTURE_DIR"] isDirectory:YES];
  self.sourceDirectory = [NSURL fileURLWithPath:environment[@"RISH_RUNTIME_SERVICES_SOURCE_DIR"] isDirectory:YES];
  NSError *error = nil;
  self.packages = DSHServiceLivePackages(self.packageDirectory, &error);
  XCTAssertNotNil(self.packages, @"%@", error);
  self.fixtureRoot = DSHCreateTestStorageFixtureRoot(@"AgentRuntimeServiceLiveTests", &error);
  XCTAssertNotNil(self.fixtureRoot, @"%@", error);
  NSURL *documents = [self.fixtureRoot URLByAppendingPathComponent:@"Documents" isDirectory:YES];
  NSURL *privateRoot = [self.fixtureRoot URLByAppendingPathComponent:@"private" isDirectory:YES];
  for (NSURL *url in @[documents, privateRoot])
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:url withIntermediateDirectories:NO
        attributes:@{NSFilePosixPermissions:@0700} error:&error]);
  self.workspaces = [[DSHLocalWorkspaceAccess alloc] initWithPrivateRootURL:privateRoot
      documentsRootURL:documents clock:^{ return NSDate.date; }
      UUIDGenerator:^{ return NSUUID.UUID.UUIDString.lowercaseString; }
      legacyResolver:^BOOL(NSString *projectId, NSDictionary **evidence, NSError **inner) {
        (void)projectId; (void)evidence; (void)inner; return NO;
      } faultHook:nil];
  NSDictionary *created = [self.workspaces createRishOwnedWorkspaceWithDisplayName:@"Real agent HTTP service"
      operationId:NSUUID.UUID.UUIDString.lowercaseString error:&error];
  XCTAssertNotNil(created, @"%@", error);
  self.resolver = [[DSHAgentRootResolver alloc] initWithWorkspaceAccess:self.workspaces
      projectAccess:[[DSHLocalProjectAccess alloc] initWithWorkspaceAccess:self.workspaces hook:nil]];
  self.root = [self.resolver resolveRootForWorkspaceId:created[@"workspace_id"] projectId:nil
      bindingRevision:created[@"binding_revision"] error:&error];
  XCTAssertNotNil(self.root, @"%@", error);
  XCTAssertTrue([self.root[@"capabilities"] containsObject:@"guest_service"]);
  self.store = [[DSHRuntimeEnvironmentStore alloc]
      initWithRootURL:[self.fixtureRoot URLByAppendingPathComponent:@"environments" isDirectory:YES]
      catalog:@{@"schema_version":@1, @"environments":@[]} kernelSHA256:DSHGuestKernelSha256];
  self.executor = [[DSHAgentRuntimeToolExecutor alloc] initWithResolver:self.resolver store:self.store];
  if ([environment[@"RISH_RUNTIME_STAGE_DIAGNOSTICS"] isEqual:@"1"]) {
    self.executor.serviceFactory = ^{ return [[DSHRuntimeServiceDiagnosticVM alloc] initWithBundle:NSBundle.mainBundle]; };
  }
  self.conversationId = NSUUID.UUID.UUIDString.lowercaseString;
  self.owners = [NSMutableArray array];
}

- (void)tearDown {
  // A failed test still cancels its registered native owner and waits for the
  // actual VM/importer to finish before touching its private environment disk.
  for (NSDictionary *owner in self.owners) [self.executor cancelLocator:owner];
  BOOL importing; @synchronized (self) { importing = self.importing; }
  if (importing) [self.store cancelInstall];
  BOOL released = self.fixtureRoot == nil;
  NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 60;
  while (!released && NSProcessInfo.processInfo.systemUptime < deadline) {
    BOOL busy; @synchronized (self) { busy = self.importing || self.executing; }
    if (!busy) {
      DSHGuestVMOwner *owner = [DSHGuestRuntimeState.sharedState acquireGuestOwner];
      if (owner) { released = [DSHGuestRuntimeState.sharedState releaseGuestOwner:owner]; break; }
    }
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
  }
  if (released && self.environmentId) released = [self.store removeEnvironmentId:self.environmentId error:nil];
  XCTAssertTrue(released, @"Preserving fixture: live VM/importer or immutable environment lease did not release.");
  if (released && self.fixtureRoot)
    XCTAssertTrue([NSFileManager.defaultManager removeItemAtURL:self.fixtureRoot error:nil]);
  [super tearDown];
}

- (void)installFamily:(NSString *)family {
  NSDictionary *record = self.packages[family];
  NSURL *package = [self.packageDirectory URLByAppendingPathComponent:record[@"file"]];
  NSError *error = nil;
  XCTAssertTrue(DSHServiceLiveVerifyPackage(package, record, &error), @"%@", error);
  XCTestExpectation *done = [self expectationWithDescription:[@"import " stringByAppendingString:family]];
  __block NSDictionary *installed; __block NSError *failure;
  @synchronized (self) { self.importing = YES; }
  [self.store importPackageURL:package completion:^(NSDictionary *descriptor, NSError *importError) {
    installed = descriptor; failure = importError;
    @synchronized (self) { self.importing = NO; } [done fulfill];
  }];
  [self waitForExpectations:@[done] timeout:180];
  XCTAssertNil(failure, @"%@", failure); XCTAssertNotNil(installed);
  XCTAssertEqualObjects(installed[@"environment_id"], record[@"environment_id"]);
  XCTAssertEqualObjects(installed[@"family"], family);
  XCTAssertEqualObjects(installed[@"state"], @"installed");
  self.environmentId = installed[@"environment_id"];
  XCTAssertTrue(DSHServiceLiveVerifyPackage(package, record, &error), @"Import changed package bytes: %@", error);
}

- (void)source:(NSData *)expected entry:(NSString *)entry write:(BOOL)writeFile {
  NSError *error = nil;
  BOOL result = [self.workspaces performCoordinatedWorkspaceOperationForId:self.root[@"workspace_id"]
      expectedBindingRevision:[self.root[@"workspace_binding_revision"] unsignedIntegerValue]
      requiredCapabilities:writeFile ? [NSSet setWithObjects:@"read", @"write", nil] : [NSSet setWithObject:@"read"]
      block:^BOOL(int root, NSError **inner) {
        (void)inner;
        int fd = openat(root, entry.fileSystemRepresentation, O_NOFOLLOW | O_CLOEXEC |
            (writeFile ? O_WRONLY | O_CREAT | O_EXCL : O_RDONLY), 0600);
        if (fd < 0) return NO;
        struct stat status = {};
        BOOL okay = fstat(fd, &status) == 0 && S_ISREG(status.st_mode) &&
            (writeFile || status.st_size == (off_t)expected.length);
        NSMutableData *actual = [NSMutableData dataWithLength:expected.length];
        NSUInteger offset = 0;
        while (okay && offset < expected.length) {
          ssize_t count = writeFile ? write(fd, (const uint8_t *)expected.bytes + offset, expected.length - offset) :
              read(fd, (uint8_t *)actual.mutableBytes + offset, actual.length - offset);
          if (count < 0 && errno == EINTR) continue;
          if (count <= 0) { okay = NO; break; } offset += (NSUInteger)count;
        }
        okay = okay && (writeFile ? fsync(fd) == 0 : [actual isEqualToData:expected]);
        if (close(fd) != 0) okay = NO; return okay;
      } error:&error];
  XCTAssertTrue(result, @"Workspace source %@ failed: %@", writeFile ? @"write" : @"preservation proof", error);
}

- (NSDictionary *)newOwner {
  NSDictionary *owner = @{@"task_id":NSUUID.UUID.UUIDString.lowercaseString,
      @"conversation_id":self.conversationId, @"attempt_id":NSUUID.UUID.UUIDString.lowercaseString,
      @"round_id":NSUUID.UUID.UUIDString.lowercaseString, @"round_index":@0, @"call_index":@0,
      @"call_id":[@"service_" stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString],
      @"idempotency_key":[[@"a" stringByPaddingToLength:32 withString:@"a" startingAtIndex:0]
          stringByAppendingString:[NSUUID.UUID.UUIDString.lowercaseString stringByReplacingOccurrencesOfString:@"-" withString:@""]]};
  [self.owners addObject:owner]; return owner;
}

- (NSDictionary *)execute:(NSString *)name arguments:(NSDictionary *)arguments owner:(NSDictionary *)owner
                   timeout:(NSTimeInterval)timeout {
  NSDictionary *prepared = [self.executor prepareToolNamed:name arguments:arguments root:self.root];
  XCTAssertNil(prepared[@"rejection"], @"Runtime preparation failed: %@", prepared);
  NSDictionary *precondition = prepared[@"precondition"];
  XCTAssertNotNil(precondition);
  XCTAssertTrue(DSHAgentRuntimeContractValid(@"runtime_precondition", precondition));
  XCTAssertTrue([self.executor registerToolNamed:name arguments:arguments root:self.root owner:owner
      precondition:precondition validator:^BOOL(BOOL executionRequired) {
        (void)executionRequired; return YES; // Immutable native test owner; resolver proof remains real.
      }]);
  XCTestExpectation *done = [self expectationWithDescription:name];
  __block NSDictionary *effect;
  @synchronized (self) { self.executing = YES; }
  NSTimeInterval began = NSProcessInfo.processInfo.systemUptime;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    effect = [self.executor executeToolNamed:name arguments:arguments root:self.root owner:owner precondition:precondition];
    @synchronized (self) { self.executing = NO; } [done fulfill];
  });
  [self waitForExpectations:@[done] timeout:timeout];
  NSLog(@"RISH_RUNTIME_SERVICE_LIVE %@ %@ %.3fs", self.environmentId, name,
      NSProcessInfo.processInfo.systemUptime - began);
  XCTAssertNotNil(effect);
  XCTAssertTrue(DSHAgentRuntimeContractValid(@"runtime_feedback", effect[@"feedback"]));
  NSData *bytes = [effect[@"feedback"] dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *feedback = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
  XCTAssertEqualObjects(feedback[@"name"], name);
  XCTAssertEqualObjects(feedback[@"outcome"], @"ok", @"%@", feedback);
  XCTAssertTrue(DSHAgentRuntimeContractValid(@"runtime_facts_match", @{
      @"row":@{@"name":name, @"arguments_sha256":precondition[@"arguments_sha256"], @"precondition":precondition},
      @"feedback":feedback, @"facts":effect[@"settled_facts"]}));
  return feedback[@"payload"];
}

- (NSDictionary *)requestURL:(NSURL *)url method:(NSString *)method body:(NSData *)body
                      cookie:(NSString *)cookie response:(NSHTTPURLResponse **)response {
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
      cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:45];
  request.HTTPMethod = method; request.HTTPBody = body;
  [request setValue:[NSString stringWithFormat:@"http://127.0.0.1:%@", url.port] forHTTPHeaderField:@"Origin"];
  if (cookie) [request setValue:cookie forHTTPHeaderField:@"Cookie"];
  if (body) [request setValue:@"text/plain; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
  NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
  config.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever; config.HTTPShouldSetCookies = NO;
  NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
  XCTestExpectation *done = [self expectationWithDescription:[method stringByAppendingString:url.path]];
  __block NSData *received; __block NSURLResponse *reply; __block NSError *failure;
  [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *result, NSError *error) {
    received = data; reply = result; failure = error; [done fulfill];
  }] resume];
  [self waitForExpectations:@[done] timeout:50]; [session finishTasksAndInvalidate];
  XCTAssertNil(failure, @"Real HTTP failed: %@", failure);
  XCTAssertTrue([reply isKindOfClass:NSHTTPURLResponse.class]);
  NSHTTPURLResponse *http = (NSHTTPURLResponse *)reply;
  XCTAssertEqual(http.statusCode, 200); XCTAssertEqualObjects(http.MIMEType, @"application/json");
  XCTAssertTrue(received.length > 0 && received.length <= 65536);
  NSDictionary *json = [NSJSONSerialization JSONObjectWithData:received options:0 error:&failure];
  XCTAssertNil(failure); XCTAssertTrue(DSHServiceLiveExactKeys(json, @[@"family", @"method", @"path", @"body", @"count"]));
  XCTAssertTrue([json[@"count"] isKindOfClass:NSNumber.class] &&
      CFGetTypeID((__bridge CFTypeRef)json[@"count"]) != CFBooleanGetTypeID());
  if (response) *response = http; return json;
}

- (BOOL)portClosed:(NSUInteger)port {
  int fd = socket(AF_INET, SOCK_STREAM, 0); if (fd < 0) return NO;
  fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
  struct sockaddr_in address = {}; address.sin_family = AF_INET; address.sin_port = htons((uint16_t)port);
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  int result = connect(fd, (struct sockaddr *)&address, sizeof(address)), code = errno;
  if (result < 0 && code == EINPROGRESS) {
    struct pollfd event = {fd, POLLOUT, 0};
    if (poll(&event, 1, 1000) > 0) { socklen_t size = sizeof(code); getsockopt(fd, SOL_SOCKET, SO_ERROR, &code, &size); }
  }
  close(fd); return result < 0 && code == ECONNREFUSED;
}

- (void)runFamily:(NSString *)family entry:(NSString *)entry {
  [self installFamily:family];
  NSData *source = DSHEnvironmentReadSmallFile([self.sourceDirectory URLByAppendingPathComponent:entry], 32768);
  XCTAssertNotNil(source, @"Missing stdlib HTTP source for %@.", family);
  [self source:source entry:entry write:YES];
  NSDictionary *startOwner = [self newOwner];
  NSDictionary *started = [self execute:@"start_runtime_service"
      arguments:@{@"environment_id":self.environmentId, @"entry_path":entry, @"args":@[@"8080"], @"port":@8080}
      owner:startOwner timeout:200 + [DSHRuntimeProgramVM executionTimeoutMillisecondsForFamily:family entryPath:entry] / 1000.0];
  XCTAssertEqualObjects(started[@"environment_id"], self.environmentId);
  XCTAssertEqualObjects(started[@"status"], @"running");
  NSURL *base = [NSURL URLWithString:started[@"url"]];
  XCTAssertEqualObjects(base.host, @"127.0.0.1"); XCTAssertEqualObjects(base.scheme, @"http");
  NSString *query = [NSString stringWithFormat:@"inspect?token=%@&family=%@", NSUUID.UUID.UUIDString.lowercaseString, family];
  NSHTTPURLResponse *getResponse;
  NSDictionary *first = [self requestURL:[NSURL URLWithString:query relativeToURL:base].absoluteURL
      method:@"GET" body:nil cookie:nil response:&getResponse];
  XCTAssertEqualObjects(first[@"family"], family); XCTAssertEqualObjects(first[@"method"], @"GET");
  XCTAssertEqualObjects(first[@"path"], [@"/" stringByAppendingString:query]); XCTAssertEqualObjects(first[@"body"], @"");
  NSArray *cookies = [NSHTTPCookie cookiesWithResponseHeaderFields:getResponse.allHeaderFields forURL:base];
  XCTAssertEqual(cookies.count, 1);
  NSString *cookie = [NSHTTPCookie requestHeaderFieldsWithCookies:cookies][@"Cookie"];
  XCTAssertTrue(cookie.length > 0);
  NSString *body = [NSString stringWithFormat:@"真实 %@ payload %@\n\"quoted\" \\ path", family, NSUUID.UUID.UUIDString.lowercaseString];
  NSDictionary *second = [self requestURL:[NSURL URLWithString:@"submit?round=two" relativeToURL:base].absoluteURL
      method:@"POST" body:[body dataUsingEncoding:NSUTF8StringEncoding] cookie:cookie response:nil];
  XCTAssertEqualObjects(second[@"family"], family); XCTAssertEqualObjects(second[@"method"], @"POST");
  XCTAssertEqualObjects(second[@"path"], @"/submit?round=two"); XCTAssertEqualObjects(second[@"body"], body);
  XCTAssertGreaterThan([first[@"count"] unsignedLongLongValue], 0ULL);
  XCTAssertEqual([second[@"count"] unsignedLongLongValue], [first[@"count"] unsignedLongLongValue] + 1);
  NSDictionary *stopOwner = [self newOwner];
  XCTAssertNotEqualObjects(stopOwner[@"attempt_id"], startOwner[@"attempt_id"]);
  XCTAssertEqualObjects(stopOwner[@"conversation_id"], startOwner[@"conversation_id"]);
  NSDictionary *stopped = [self execute:@"stop_runtime_service" arguments:@{@"service_id":started[@"service_id"]}
      owner:stopOwner timeout:65];
  XCTAssertEqualObjects(stopped[@"status"], @"stopped"); XCTAssertEqualObjects(stopped[@"service_id"], started[@"service_id"]);
  XCTAssertTrue([self portClosed:base.port.unsignedIntegerValue], @"Stopped native listener still accepts TCP.");
  DSHGuestVMOwner *owner = [DSHGuestRuntimeState.sharedState acquireGuestOwner];
  XCTAssertNotNil(owner, @"Service stop must release the process-wide VM owner.");
  if (owner) XCTAssertTrue([DSHGuestRuntimeState.sharedState releaseGuestOwner:owner]);
  [self source:source entry:entry write:NO];
  XCTAssertEqualObjects(DSHEnvironmentReadSmallFile([self.sourceDirectory URLByAppendingPathComponent:entry], 32768), source);
  NSDictionary *record = self.packages[family];
  XCTAssertTrue(DSHServiceLiveVerifyPackage([self.packageDirectory URLByAppendingPathComponent:record[@"file"]], record, nil));
}
- (void)testPythonAgentRuntimeServiceServesAndStops { [self runFamily:@"python" entry:@"python.py"]; }
- (void)testJavaAgentRuntimeServiceServesAndStops { [self runFamily:@"java" entry:@"Main.java"]; }
- (void)testGoAgentRuntimeServiceServesAndStops { [self runFamily:@"go" entry:@"go.go"]; }
- (void)testRustAgentRuntimeServiceServesAndStops { [self runFamily:@"rust" entry:@"rust.rs"]; }
- (void)testBunAgentRuntimeServiceServesAndStops { [self runFamily:@"bun" entry:@"bun.js"]; }
- (void)testNodeAgentRuntimeServiceServesAndStops { [self runFamily:@"node" entry:@"node.js"]; }
@end
