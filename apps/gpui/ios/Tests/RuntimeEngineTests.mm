#import <Foundation/Foundation.h>
#import "ShellRuntimeEnginesModule.h"
#import "RishRuntimeEngineDownloads.h"
#include <sys/stat.h>

// Exercise the actual URLSession delegate path with controllable task identity
// and delivery order, without release servers or background daemon timing.
@interface FixtureDownloadTask : NSURLSessionDownloadTask
@property(nonatomic, copy) NSString *fixtureDescription;
@property(nonatomic, strong) NSURLRequest *fixtureRequest;
@property(nonatomic, strong) NSHTTPURLResponse *fixtureResponse;
@property(nonatomic) NSURLSessionTaskState fixtureState;
@property(nonatomic) NSUInteger cancellations;
@property(nonatomic) NSUInteger resumes;
@end
@implementation FixtureDownloadTask
- (NSString *)taskDescription { return self.fixtureDescription; }
- (void)setTaskDescription:(NSString *)value { self.fixtureDescription = value; }
- (NSURLRequest *)originalRequest { return self.fixtureRequest; }
- (NSURLResponse *)response { return self.fixtureResponse; }
- (NSURLSessionTaskState)state { return self.fixtureState; }
- (void)cancel { self.cancellations++; self.fixtureState = NSURLSessionTaskStateCanceling; }
- (void)resume { self.resumes++; self.fixtureState = NSURLSessionTaskStateRunning; }
@end

static NSUInteger checks;
static void Check(BOOL condition, NSString *message) {
  ++checks;
  NSCAssert(condition, @"%@", message);
}
static NSDictionary *Catalog(ShellRuntimeEnginesModule *module) {
  __block NSDictionary *result;
  [module catalogWithResolver:^(id value) { result = value; }
      rejecter:^(NSString *code, NSString *message, NSError *error) { Check(NO, code); }];
  return result;
}
static NSDictionary *Row(NSDictionary *catalog, NSString *engineID) {
  for (NSDictionary *row in catalog[@"engines"]) if ([row[@"id"] isEqual:engineID]) return row;
  return nil;
}
static NSDictionary *Install(ShellRuntimeEnginesModule *module, id request, NSString *expectedError) {
  __block NSDictionary *result;
  __block NSString *failure;
  [module installWithRequest:request resolver:^(id value) { result = value; }
      rejecter:^(NSString *code, NSString *message, NSError *error) { failure = code; }];
  Check(expectedError ? [failure isEqual:expectedError] : result != nil, @"Install has the expected disposition");
  return result;
}
static NSDictionary *Request(NSString *engineID) {
  return @{@"schema_version": @1, @"engine_id": engineID, @"userInitiated": @YES};
}
static NSHTTPURLResponse *Response(NSInteger status) {
  return [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://fixtures.invalid/cli"]
      statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:@{}];
}
static NSURL *TempFile(NSURL *root, NSData *bytes) {
  NSURL *url = [root URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
  Check([bytes writeToURL:url atomically:YES], @"Fixture file is created");
  return url;
}
static FixtureDownloadTask *Task(RishRuntimeEngineDownloads *downloads, NSDictionary *descriptor) {
  #pragma clang diagnostic push
  #pragma clang diagnostic ignored "-Wdeprecated-declarations"
  FixtureDownloadTask *task = [FixtureDownloadTask new];
  #pragma clang diagnostic pop
  task.taskDescription = [NSString stringWithFormat:@"codex|%@|%@", [downloads attemptForEngine:@"codex"], descriptor[@"sha256"]];
  task.fixtureRequest = [NSURLRequest requestWithURL:[NSURL URLWithString:descriptor[@"url"]]];
  task.fixtureResponse = Response(200);
  task.fixtureState = NSURLSessionTaskStateSuspended;
  return task;
}
static NSDictionary *Cancel(ShellRuntimeEnginesModule *module, id request, NSString *expectedError) {
  __block NSDictionary *result;
  __block NSString *failure;
  [module cancelWithRequest:request resolver:^(id value) { result = value; }
      rejecter:^(NSString *code, NSString *message, NSError *error) { failure = code; }];
  Check(expectedError ? [failure isEqual:expectedError] : result != nil, @"Cancel has the expected disposition");
  return result;
}
static void TransferBudgetChecks(NSURL *root, NSDictionary *descriptor) {
  for (NSArray<NSNumber *> *budget in @[@[@1, @4], @[@4, @(-1)]]) {
    NSURL *directory = [root URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    RishRuntimeEngineDownloads *downloads = [[RishRuntimeEngineDownloads alloc] initWithDirectory:directory
        descriptors:@{@"codex": descriptor} starter:^(NSString *engine, NSURL *url) {}];
    [downloads installEngine:@"codex"];
    FixtureDownloadTask *task = Task(downloads, descriptor);
    [downloads beginRestoringTasks]; [downloads restoreTasks:@[task]];
    [downloads URLSession:NSURLSession.sharedSession downloadTask:task didWriteData:1
        totalBytesWritten:budget[0].longLongValue totalBytesExpectedToWrite:budget[1].longLongValue];
    Check(task.cancellations == 1 && [[downloads installationForEngine:@"codex"][@"error"] isEqual:@"download_integrity_failed"],
        @"A transfer exceeding the pinned size stops without waiting for all bytes");
    NSURL *late = TempFile(root, [@"abc" dataUsingEncoding:NSUTF8StringEncoding]);
    [downloads URLSession:NSURLSession.sharedSession downloadTask:task didFinishDownloadingToURL:late];
    Check(![NSFileManager.defaultManager fileExistsAtPath:late.path] && ![downloads verifiedArtifactForEngine:@"codex"],
        @"A rejected oversized transfer cannot install using a late success callback");
  }
}

static void LifecycleChecks(NSURL *root, NSDictionary *descriptor) {
  NSURL *cache = [root URLByAppendingPathComponent:@"lifecycle"];
  NSDictionary *descriptors = @{@"codex": descriptor};
  __block NSUInteger started = 0;
  void (^starter)(NSString *, NSURL *) = ^(NSString *engine, NSURL *url) { started++; };
  RishRuntimeEngineDownloads *(^load)(void) = ^{
    return [[RishRuntimeEngineDownloads alloc] initWithDirectory:cache descriptors:descriptors starter:starter];
  };
  NSData *good = [@"abc" dataUsingEncoding:NSUTF8StringEncoding];
  RishRuntimeEngineDownloads *downloads = load();
  ShellRuntimeEnginesModule *module = [[ShellRuntimeEnginesModule alloc] initWithDownloads:(id)downloads];
  for (id request in @[@{}, @[], Request(@"pi"),
      @{@"schema_version": @1, @"engine_id": @"codex", @"userInitiated": @NO},
      @{@"schema_version": @YES, @"engine_id": @"codex", @"userInitiated": @YES},
      @{@"schema_version": @1, @"engine_id": @"codex", @"userInitiated": @YES, @"attempt": @"forged"}])
    Cancel(module, request, @"runtime_engine_invalid_request");
  Cancel(module, Request(@"dsh"), @"runtime_engine_installer_unavailable");
  [downloads installEngine:@"codex"];
  FixtureDownloadTask *old = Task(downloads, descriptor);
  NSString *oldAttempt = [downloads attemptForEngine:@"codex"];
  Cancel(module, Request(@"codex"), nil);
  Check([[downloads installationForEngine:@"codex"][@"state"] isEqual:@"not_installed"], @"Cancel stops progress immediately");
  // Recreate the service before the cancelled daemon task disappears.
  downloads = load();
  [downloads beginRestoringTasks];
  [downloads restoreTasks:@[old]];
  Check(old.cancellations == 1 && old.resumes == 0, @"Durable cancellation cannot be resurrected on launch");
  [downloads installEngine:@"codex"];
  Check(![[downloads attemptForEngine:@"codex"] isEqual:oldAttempt], @"Retry has a fresh attempt identity");
  FixtureDownloadTask *current = Task(downloads, descriptor);
  NSURL *late = TempFile(root, good);
  [downloads URLSession:NSURLSession.sharedSession downloadTask:old didFinishDownloadingToURL:late];
  [downloads URLSession:NSURLSession.sharedSession task:old didCompleteWithError:[NSError errorWithDomain:@"fixture" code:1 userInfo:nil]];
  [downloads URLSession:NSURLSession.sharedSession downloadTask:old didWriteData:3 totalBytesWritten:3 totalBytesExpectedToWrite:3];
  Check(![NSFileManager.defaultManager fileExistsAtPath:late.path], @"Late completion temporary bytes are discarded");
  Check([downloads verifiedArtifactForEngine:@"codex"] == nil &&
      [[[downloads installationForEngine:@"codex"] objectForKey:@"progress"] isEqual:@0], @"Old success, error and progress cannot pollute retry");
  // A forged/stale artifact URL cannot use a valid attempt token.
  FixtureDownloadTask *wrongURL = Task(downloads, descriptor);
  wrongURL.fixtureRequest = [NSURLRequest requestWithURL:[NSURL URLWithString:@"https://wrong.invalid/artifact"]];
  [downloads URLSession:NSURLSession.sharedSession downloadTask:wrongURL didFinishDownloadingToURL:TempFile(root, good)];
  Check([downloads verifiedArtifactForEngine:@"codex"] == nil, @"Task original URL is part of artifact authority");
  downloads = load();
  [downloads beginRestoringTasks];
  [downloads installEngine:@"codex"];
  NSUInteger before = started;
  FixtureDownloadTask *duplicate = Task(downloads, descriptor);
  FixtureDownloadTask *cancelledBeforeRestore = Task(downloads, descriptor);
  [cancelledBeforeRestore cancel];
  [downloads URLSession:NSURLSession.sharedSession task:cancelledBeforeRestore didCompleteWithError:
      [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]];
  Check([[downloads installationForEngine:@"codex"][@"state"] isEqual:@"installing"],
      @"Early duplicate cancellation cannot seize recovery ownership");
  [downloads restoreTasks:@[current, wrongURL, duplicate]];
  [downloads URLSession:NSURLSession.sharedSession task:duplicate didCompleteWithError:[NSError errorWithDomain:@"cancelled duplicate" code:1 userInfo:nil]];
  Check([[downloads installationForEngine:@"codex"][@"state"] isEqual:@"installing"], @"Cancelled duplicate task cannot fail the accepted restored task");
  Check(started == before && current.resumes == 1 && wrongURL.cancellations == 1,
      @"Restore reattaches the exact task and does not duplicate it");
  [downloads URLSession:NSURLSession.sharedSession downloadTask:current didWriteData:1 totalBytesWritten:1 totalBytesExpectedToWrite:2];
  Check([[downloads installationForEngine:@"codex"][@"progress"] isEqual:@33], @"Progress uses the pinned artifact length");
  [downloads URLSession:NSURLSession.sharedSession downloadTask:current didWriteData:1 totalBytesWritten:2 totalBytesExpectedToWrite:-1];
  [downloads URLSession:NSURLSession.sharedSession downloadTask:current didWriteData:0 totalBytesWritten:1 totalBytesExpectedToWrite:3];
  Check([[downloads installationForEngine:@"codex"][@"progress"] isEqual:@66],
      @"Unknown HTTP length still advances progress and late callbacks do not roll it back");
  NSURL *journal = [cache URLByAppendingPathComponent:@".engine-download-state.json"];
  Check(chmod(journal.fileSystemRepresentation, 0000) == 0, @"Fixture blocks journal reads");
  RishRuntimeEngineDownloads *locked = load();
  [locked beginRestoringTasks];
  [locked restoreTasks:@[current]];
  Check(current.cancellations == 0 && ![[locked installationForEngine:@"codex"][@"download_supported"] boolValue],
      @"Unreadable journal defers restoration without cancelling system-owned work");
  [locked installEngine:@"codex"];
  Check(started == before, @"Unreadable journal cannot launch a conflicting attempt");
  NSURL *whileLocked = TempFile(root, good);
  [locked URLSession:NSURLSession.sharedSession downloadTask:current didFinishDownloadingToURL:whileLocked];
  Check(![NSFileManager.defaultManager fileExistsAtPath:whileLocked.path], @"Blocked completion leaves no dependency on system temporary URL");
  current.fixtureState = NSURLSessionTaskStateCompleted;
  locked = load();
  [locked beginRestoringTasks];
  [locked restoreTasks:@[current]];
  Check(chmod(journal.fileSystemRepresentation, 0600) == 0, @"Fixture unlocks journal");
  [locked retryDeferredRestoration];
  Check([[locked installationForEngine:@"codex"][@"download_supported"] boolValue],
      @"Protected data availability reconciles deferred system tasks");
  Check([locked verifiedArtifactForEngine:@"codex"] != nil,
      @"Completion during journal lock survives restart and is published after unlock");
  [NSFileManager.defaultManager removeItemAtURL:[locked verifiedArtifactForEngine:@"codex"] error:nil];
  downloads = locked;
  [downloads installEngine:@"codex"];
  current = Task(downloads, descriptor);
  [downloads beginRestoringTasks];
  [downloads restoreTasks:@[current]];
  [downloads cancelEngine:@"codex"];
  Check(current.cancellations == 1, @"Cancel stops the restored transport");
  before = started;
  // Install/cancel during asynchronous enumeration must not create an orphan.
  downloads = load();
  [downloads beginRestoringTasks];
  [downloads installEngine:@"codex"];
  Check(started == before, @"New install waits for restoration to settle");
  [downloads cancelEngine:@"codex"];
  [downloads restoreTasks:@[current]];
  Check(started == before, @"Cancel during restore suppresses queued start");
  [downloads beginRestoringTasks];
  [downloads installEngine:@"codex"];
  FixtureDownloadTask *queued = Task(downloads, descriptor);
  [downloads restoreTasks:@[]];
  Check(started == before + 1, @"Queued explicit retry starts exactly once after reconciliation");
  [downloads restoreTasks:@[]];
  Check(started == before + 1, @"Duplicate reconciliation callback cannot restart a transfer");
  [downloads URLSession:NSURLSession.sharedSession downloadTask:queued didFinishDownloadingToURL:TempFile(root, good)];
  NSURL *artifact = [downloads verifiedArtifactForEngine:@"codex"];
  Check(artifact != nil, @"Current completion publishes verified bytes");
  [downloads URLSession:NSURLSession.sharedSession task:queued didCompleteWithError:[NSError errorWithDomain:@"late" code:1 userInfo:nil]];
  [downloads URLSession:NSURLSession.sharedSession downloadTask:old didFinishDownloadingToURL:TempFile(root, [@"bad" dataUsingEncoding:NSUTF8StringEncoding])];
  Check([[NSData dataWithContentsOfURL:artifact] isEqual:good] && [downloads installationForEngine:@"codex"][@"error"] == nil,
      @"Late callbacks preserve verified artifact and terminal success");
  __block NSUInteger backgroundFinished = 0;
  [downloads handleBackgroundEventsWithCompletion:^{
    Check(NSThread.isMainThread, @"System background completion runs on main queue"); backgroundFinished++;
  }];
  Check(backgroundFinished == 0, @"Host completion waits for all delegate events");
  [downloads URLSessionDidFinishEventsForBackgroundURLSession:NSURLSession.sharedSession];
  [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
  Check(backgroundFinished == 1, @"Background completion is delivered once");
  // The session can flush immediately while the host is registering its callback.
  [downloads URLSessionDidFinishEventsForBackgroundURLSession:NSURLSession.sharedSession];
  [downloads handleBackgroundEventsWithCompletion:^{ backgroundFinished++; }];
  [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
  Check(backgroundFinished == 2, @"Early event drain cannot lose host completion");
  // Simulate a process exit after publishing the bytes but before saving terminal state.
  [NSFileManager.defaultManager removeItemAtURL:artifact error:nil];
  [downloads installEngine:@"codex"];
  FixtureDownloadTask *alreadyPublished = Task(downloads, descriptor);
  Check([good writeToURL:artifact atomically:YES], @"Verified bytes survive the interrupted journal write");
  downloads = load();
  [downloads beginRestoringTasks]; [downloads restoreTasks:@[alreadyPublished]];
  Check(alreadyPublished.cancellations == 1 && alreadyPublished.resumes == 0 &&
      [downloads verifiedArtifactForEngine:@"codex"] != nil, @"Restoration keeps verified bytes and cancels redundant transfers");
  // Lost system transfers become retryable after relaunch; errors persist.
  [NSFileManager.defaultManager removeItemAtURL:artifact error:nil];
  [downloads installEngine:@"codex"];
  downloads = load();
  [downloads beginRestoringTasks];
  [downloads restoreTasks:@[]];
  Check([[downloads installationForEngine:@"codex"][@"error"] isEqual:@"download_interrupted"], @"Lost transfer does not remain downloading forever");
  Check([[load() installationForEngine:@"codex"][@"error"] isEqual:@"download_interrupted"], @"Failure remains visible across relaunch");
  // Known corrupt cache is removed on explicit retry, unknown paths survive.
  NSURL *target = [cache URLByAppendingPathComponent:@"codex.bin"];
  [@"bad" writeToURL:target atomically:YES encoding:NSUTF8StringEncoding error:nil];
  [downloads installEngine:@"codex"];
  Check(![NSFileManager.defaultManager fileExistsAtPath:target.path], @"Retry removes corrupt regular artifact");
  [downloads cancelEngine:@"codex"];
  NSURL *sentinel = TempFile(root, good);
  [NSFileManager.defaultManager createSymbolicLinkAtURL:target withDestinationURL:sentinel error:nil];
  [downloads installEngine:@"codex"];
  Check([[NSData dataWithContentsOfURL:sentinel] isEqual:good] &&
      [[downloads installationForEngine:@"codex"][@"error"] isEqual:@"download_storage_unavailable"], @"Retry refuses symlink cache without touching destination");
}
int main(int argc, const char *argv[]) {
  @autoreleasepool {
    NSURL *root = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
        isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *directory = [root URLByAppendingPathComponent:@"cache" isDirectory:YES];
    NSDictionary *descriptor = @{@"version": @"fixture-1", @"file": @"codex.bin", @"size": @3,
        @"url": @"https://fixtures.invalid/codex", @"sha256": @"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"};
    NSMutableDictionary *claude = [descriptor mutableCopy];
    claude[@"file"] = @"claude.bin";
    __block NSUInteger started = 0;
    RishRuntimeEngineDownloads *downloads = [[RishRuntimeEngineDownloads alloc] initWithDirectory:directory
        descriptors:@{@"codex": descriptor, @"claude-code": claude}
        starter:^(NSString *engineID, NSURL *url) { ++started; }];
    ShellRuntimeEnginesModule *module = [[ShellRuntimeEnginesModule alloc]
        initWithDownloads:(id<RishRuntimeEngineDownloadBackend>)downloads];
    NSDictionary *catalog = Catalog(module);
    Check([catalog[@"schema_version"] isEqual:@1] && [catalog[@"engines"] count] == 5, @"Catalog contains all five peers");
    Check([Row(catalog, @"pi")[@"execution"][@"state"] isEqual:@"ready"], @"Pi is built in");
    Check(started == 0 && ![NSFileManager.defaultManager fileExistsAtPath:directory.path], @"Reading catalog has no install/storage side effect");
    for (NSString *engineID in @[@"dsh", @"claude-code", @"codex", @"zcode"]) {
      NSDictionary *row = Row(catalog, engineID);
      Check([row[@"execution"][@"state"] isEqual:@"unavailable"], @"CLI execution is unavailable");
      Check([row[@"execution"][@"reason_code"] isEqual:@"cli_adapter_unavailable"], @"CLI reason is independent of credentials");
      Check(row[@"account"] == nil && row[@"runtime"] == nil, @"Catalog has no auth account/runtime projection");
    }
    Check([Row(catalog, @"codex")[@"installation"][@"version"] isEqual:NSNull.null], @"An absent artifact has no installed version");
    for (NSString *engineID in @[@"dsh", @"zcode"]) {
      Check([Row(catalog, engineID)[@"installation"][@"download_supported"] isEqual:@NO], @"Unsupported installers have no button capability");
      Install(module, Request(engineID), @"runtime_engine_installer_unavailable");
    }
    for (id request in @[@{}, @[], NSNull.null, @{@"schema_version": @YES, @"engine_id": @"codex", @"userInitiated": @YES},
        @{@"schema_version": @1.0, @"engine_id": @"codex", @"userInitiated": @YES},
        @{@"schema_version": @1, @"engine_id": @"codex", @"userInitiated": @1},
        @{@"schema_version": @1, @"engine_id": @"codex", @"userInitiated": @NO}, Request(@"api-key"), Request(@"pi"),
        @{@"schema_version": @1, @"engine_id": @"codex", @"userInitiated": @YES, @"url": @"https://evil.invalid"}])
      Install(module, request, @"runtime_engine_invalid_request");
    Check(started == 0, @"Invalid/non-user requests never download");
    catalog = Install(module, Request(@"codex"), nil);
    Check([Row(catalog, @"codex")[@"installation"][@"state"] isEqual:@"installing"], @"Install returns current catalog immediately");
    Install(module, Request(@"codex"), nil);
    Check(started == 1, @"Concurrent/repeated install starts one transfer");
    [downloads recordProgress:0.42 forEngine:@"codex" attempt:[downloads attemptForEngine:@"codex"]];
    Check([[downloads installationForEngine:@"codex"][@"progress"] isEqual:@42], @"Progress uses percentage units");
    [downloads recordProgress:0.423 forEngine:@"codex" attempt:[downloads attemptForEngine:@"codex"]];
    NSDictionary *progress = Row(Catalog(module), @"codex")[@"installation"];
    NSString *json = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:progress options:0 error:nil]
        encoding:NSUTF8StringEncoding];
    Check([json containsString:@"\"progress\":42"] && ![json containsString:@"42."], @"Fractional transfer progress crosses bridge as integer JSON");
    [downloads recordProgress:2.0 forEngine:@"codex" attempt:[downloads attemptForEngine:@"codex"]];
    Check([[downloads installationForEngine:@"codex"][@"progress"] isEqual:@100], @"Progress is bounded");
    NSData *good = [@"abc" dataUsingEncoding:NSUTF8StringEncoding];
    for (NSHTTPURLResponse *response in @[Response(404), Response(206), NSNull.null]) {
      [downloads installEngine:@"codex"];
      [downloads finishDownloadForEngine:@"codex" attempt:[downloads attemptForEngine:@"codex"] file:TempFile(root, good)
          response:(id)response == NSNull.null ? nil : response];
      Check([downloads verifiedArtifactForEngine:@"codex"] == nil, @"A missing or unsuccessful HTTP response cannot install");
      Check([[downloads installationForEngine:@"codex"][@"error"] isEqual:@"download_integrity_failed"], @"Only bounded error code is exposed");
    }
    for (NSData *bad in @[[NSMutableData dataWithLength:1024 * 1024], [@"ab" dataUsingEncoding:NSUTF8StringEncoding],
        [@"xyz" dataUsingEncoding:NSUTF8StringEncoding]]) {
      [downloads installEngine:@"codex"];
      [downloads finishDownloadForEngine:@"codex" attempt:[downloads attemptForEngine:@"codex"] file:TempFile(root, bad) response:Response(200)];
      Check([downloads verifiedArtifactForEngine:@"codex"] == nil, @"Exact size and SHA256 both gate installation");
    }
    NSURL *existing = [directory URLByAppendingPathComponent:@"codex.bin"];
    [[@"xyz" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:existing atomically:YES];
    NSDictionary *old = [downloads installationForEngine:@"codex"];
    Check([old[@"state"] isEqual:@"downloaded"] && [old[@"integrity"] isEqual:@"unverified"], @"Old unverified cache is not installed");
    Check([old[@"version"] isEqual:NSNull.null], @"Unknown cached bytes do not claim a version");
    Install(module, Request(@"codex"), nil);
    [downloads finishDownloadForEngine:@"codex" attempt:[downloads attemptForEngine:@"codex"] file:TempFile(root, good) response:Response(200)];
    catalog = Catalog(module);
    NSDictionary *installed = Row(catalog, @"codex")[@"installation"];
    Check([installed[@"state"] isEqual:@"downloaded"] && [installed[@"integrity"] isEqual:@"verified"], @"Good HTTP/length/hash promotes artifact");
    Check([installed[@"version"] isEqual:@"fixture-1"], @"Verified artifact has pinned version");
    Check([Row(catalog, @"codex")[@"execution"][@"state"] isEqual:@"unavailable"], @"Verified download never enables missing CLI adapter");
    NSUInteger before = started;
    Install(module, Request(@"codex"), nil);
    Check(started == before, @"Installed artifact is idempotent");
    [[@"xyz" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:existing atomically:YES];
    Check([downloads verifiedArtifactForEngine:@"codex"] == nil, @"Mutated cache invalidates verification");
    [NSFileManager.defaultManager removeItemAtURL:existing error:nil];
    NSURL *other = TempFile(root, good);
    [NSFileManager.defaultManager createSymbolicLinkAtURL:existing withDestinationURL:other error:nil];
    Check([downloads verifiedArtifactForEngine:@"codex"] == nil, @"Symlink artifact is never installed");
    [NSFileManager.defaultManager removeItemAtURL:existing error:nil];
    [downloads installEngine:@"codex"];
    [NSFileManager.defaultManager createDirectoryAtURL:existing withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *sentinel = [existing URLByAppendingPathComponent:@"preserve"];
    [good writeToURL:sentinel atomically:YES];
    [downloads finishDownloadForEngine:@"codex" attempt:[downloads attemptForEngine:@"codex"] file:TempFile(root, good) response:Response(200)];
    Check([[NSData dataWithContentsOfURL:sentinel] isEqual:good], @"Failed atomic publication preserves the previous target");
    Check([[downloads installationForEngine:@"codex"][@"error"] isEqual:@"download_storage_unavailable"], @"Publication failure remains recoverable");
    Install(module, Request(@"claude-code"), nil);
    [downloads failDownloadForEngine:@"claude-code" attempt:[downloads attemptForEngine:@"claude-code"]];
    Check([[downloads installationForEngine:@"claude-code"][@"error"] isEqual:@"download_failed"], @"Transfer failure stays retriable");
    // Actual loopback HTTP transports small fixtures through the same byte and
    // response acceptance gate; it never contacts a release/download service.
    Check(argc == 2, @"HTTP fixture server address is provided");
    NSString *baseURL = [NSString stringWithUTF8String:argv[1]];
    NSURLSession *http = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    for (NSString *path in @[@"good", @"tampered", @"truncated", @"failed"]) {
      RishRuntimeEngineDownloads *httpDownloads = [[RishRuntimeEngineDownloads alloc]
          initWithDirectory:[root URLByAppendingPathComponent:path isDirectory:YES]
          descriptors:@{@"codex": descriptor} starter:^(NSString *engineID, NSURL *url) {}];
      [httpDownloads installEngine:@"codex"];
      dispatch_semaphore_t done = dispatch_semaphore_create(0);
      __block BOOL transportOK = NO;
      NSURL *url = [NSURL URLWithString:[baseURL stringByAppendingFormat:@"/%@", path]];
      NSURLSessionDownloadTask *task = [http downloadTaskWithURL:url
          completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        transportOK = location != nil && error == nil;
        if (transportOK) [httpDownloads finishDownloadForEngine:@"codex" attempt:[httpDownloads attemptForEngine:@"codex"] file:location
            response:[response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil];
        dispatch_semaphore_signal(done);
      }];
      [task resume];
      Check(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0,
          @"Loopback HTTP request completes");
      Check(transportOK, @"Real HTTP fixture bytes arrive");
      BOOL expectedVerified = [path isEqual:@"good"];
      Check(([httpDownloads verifiedArtifactForEngine:@"codex"] != nil) == expectedVerified,
          @"Real HTTP success, tampering, truncation and error status reach integrity gate");
    }
    [http finishTasksAndInvalidate];
    TransferBudgetChecks(root, descriptor);
    LifecycleChecks(root, descriptor);
    [NSFileManager.defaultManager removeItemAtURL:root error:nil];
    printf("PASS: %lu runtime engine and download integrity checks\n", (unsigned long)checks);
  }
}
