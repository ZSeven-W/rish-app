#import <Foundation/Foundation.h>
#import "ShellRuntimeEnginesModule.h"
#import "RishRuntimeEngineDownloads.h"

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
    [downloads recordProgress:0.42 forEngine:@"codex"];
    Check([[downloads installationForEngine:@"codex"][@"progress"] isEqual:@42], @"Progress uses percentage units");
    [downloads recordProgress:0.423 forEngine:@"codex"];
    NSDictionary *progress = Row(Catalog(module), @"codex")[@"installation"];
    NSString *json = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:progress options:0 error:nil]
        encoding:NSUTF8StringEncoding];
    Check([json containsString:@"\"progress\":42"] && ![json containsString:@"42."], @"Fractional transfer progress crosses bridge as integer JSON");
    [downloads recordProgress:2.0 forEngine:@"codex"];
    Check([[downloads installationForEngine:@"codex"][@"progress"] isEqual:@100], @"Progress is bounded");
    NSData *good = [@"abc" dataUsingEncoding:NSUTF8StringEncoding];
    for (NSHTTPURLResponse *response in @[Response(404), Response(206), NSNull.null]) {
      [downloads finishDownloadForEngine:@"codex" file:TempFile(root, good)
          response:(id)response == NSNull.null ? nil : response];
      Check([downloads verifiedArtifactForEngine:@"codex"] == nil, @"A missing or unsuccessful HTTP response cannot install");
      Check([[downloads installationForEngine:@"codex"][@"error"] isEqual:@"download_integrity_failed"], @"Only bounded error code is exposed");
    }
    for (NSData *bad in @[[NSMutableData dataWithLength:1024 * 1024], [@"ab" dataUsingEncoding:NSUTF8StringEncoding],
        [@"xyz" dataUsingEncoding:NSUTF8StringEncoding]]) {
      [downloads finishDownloadForEngine:@"codex" file:TempFile(root, bad) response:Response(200)];
      Check([downloads verifiedArtifactForEngine:@"codex"] == nil, @"Exact size and SHA256 both gate installation");
    }
    NSURL *existing = [directory URLByAppendingPathComponent:@"codex.bin"];
    [[@"xyz" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:existing atomically:YES];
    NSDictionary *old = [downloads installationForEngine:@"codex"];
    Check([old[@"state"] isEqual:@"downloaded"] && [old[@"integrity"] isEqual:@"unverified"], @"Old unverified cache is not installed");
    Check([old[@"version"] isEqual:NSNull.null], @"Unknown cached bytes do not claim a version");
    Install(module, Request(@"codex"), nil);
    [downloads finishDownloadForEngine:@"codex" file:TempFile(root, good) response:Response(200)];
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
    [NSFileManager.defaultManager createDirectoryAtURL:existing withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *sentinel = [existing URLByAppendingPathComponent:@"preserve"];
    [good writeToURL:sentinel atomically:YES];
    [downloads finishDownloadForEngine:@"codex" file:TempFile(root, good) response:Response(200)];
    Check([[NSData dataWithContentsOfURL:sentinel] isEqual:good], @"Failed atomic publication preserves the previous target");
    Check([[downloads installationForEngine:@"codex"][@"error"] isEqual:@"download_storage_unavailable"], @"Publication failure remains recoverable");
    Install(module, Request(@"claude-code"), nil);
    [downloads failDownloadForEngine:@"claude-code"];
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
        if (transportOK) [httpDownloads finishDownloadForEngine:@"codex" file:location
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
    [NSFileManager.defaultManager removeItemAtURL:root error:nil];
    printf("PASS: %lu runtime engine and download integrity checks\n", (unsigned long)checks);
  }
}
