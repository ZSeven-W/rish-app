#import <XCTest/XCTest.h>
#import "DSHTestStorageFixture.h"

#import <CommonCrypto/CommonDigest.h>

#import "../../../../modules/rish/ios/Sources/DSHGitPushSupport.h"
#import "../../../../modules/rish/ios/Sources/LocalProjectAccess.h"

#include <git2.h>

/// G2 remote-push acceptance drive against the local HTTP Git remote served
/// by scripts/native-tests/git-test-remote.rb. Every git operation runs inside
/// this app process through the production LocalProjects bridge methods; the
/// Mac side only hosts the bare repositories, creates the competing commit,
/// and verifies the report with the system git afterwards.
///
/// The tests skip unless the orchestrator passes DSH_G2_* through the test
/// runner environment (see scripts/g2-acceptance.rb).
typedef void (^G2Resolve)(id result);
typedef void (^G2Reject)(NSString *code, NSString *message, NSError *error);

@interface LocalProjectsModule : NSObject
@end

@interface LocalProjectsModule (G2Bridge)
- (void)startCloneURL:(id)url name:(id)name options:(id)options resolver:(G2Resolve)resolve rejecter:(G2Reject)reject;
- (void)cloneStatusForOperation:(id)operationId resolver:(G2Resolve)resolve rejecter:(G2Reject)reject;
- (void)cancelCloneOperation:(id)operationId resolver:(G2Resolve)resolve rejecter:(G2Reject)reject;

- (instancetype)initWithSupportURL:(nullable NSURL *)support
                       projectAccess:(DSHLocalProjectAccess *)projectAccess;
- (void)clonePublicRepository:(id)urlValue name:(id)nameValue options:(id)optionsValue
                     resolver:(G2Resolve)resolve rejecter:(G2Reject)reject;
- (void)statusForProject:(id)projectId resolver:(G2Resolve)resolve rejecter:(G2Reject)reject;
- (void)stageAllForProject:(id)projectId resolver:(G2Resolve)resolve rejecter:(G2Reject)reject;
- (void)commitProject:(id)projectId message:(id)message authorName:(id)authorName
          authorEmail:(id)authorEmail resolver:(G2Resolve)resolve rejecter:(G2Reject)reject;
- (void)setRemoteForProject:(id)projectId url:(id)url
                   resolver:(G2Resolve)resolve rejecter:(G2Reject)reject;
- (void)credentialStatusForProject:(id)projectId
                          resolver:(G2Resolve)resolve rejecter:(G2Reject)reject;
- (void)presentCredentialPromptForProject:(id)projectId locale:(id)locale
                                 resolver:(G2Resolve)resolve rejecter:(G2Reject)reject;
- (void)clearCredentialForProject:(id)projectId
                         resolver:(G2Resolve)resolve rejecter:(G2Reject)reject;
- (void)pushProject:(id)projectId options:(id)options
           resolver:(G2Resolve)resolve rejecter:(G2Reject)reject;
- (void)pushReceiptsForProject:(id)projectId
                      resolver:(G2Resolve)resolve rejecter:(G2Reject)reject;
- (void)cancelPushForProject:(id)projectId
                    resolver:(G2Resolve)resolve rejecter:(G2Reject)reject;
@end

@interface GitPushG2Tests : XCTestCase
@property(nonatomic, strong) NSURL *supportURL;
@property(nonatomic, strong) DSHLocalProjectAccess *projectAccess;
@property(nonatomic, strong) LocalProjectsModule *module;
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *env;
@end

@implementation GitPushG2Tests

- (void)setUp {
  [super setUp];
  NSDictionary *environment = NSProcessInfo.processInfo.environment;
  NSMutableDictionary *env = [NSMutableDictionary dictionary];
  for (NSString *key in @[ @"DSH_G2_SERVER", @"DSH_G2_PUBLIC_URL", @"DSH_G2_TARGET_URL",
                           @"DSH_G2_STALL_URL", @"DSH_G2_USER", @"DSH_G2_TOKEN",
                           @"DSH_G2_BRANCH" ]) {
    if ([environment[key] length] > 0) env[key] = environment[key];
  }
  self.env = env;
  if (env.count < 7) {
    XCTSkip(@"DSH_G2_* environment is not set; run scripts/g2-acceptance.rb");
  }
  git_libgit2_init();
  self.supportURL = [NSURL fileURLWithPath:[NSTemporaryDirectory()
      stringByAppendingPathComponent:[NSString stringWithFormat:@"rish-g2-%@",
          NSUUID.UUID.UUIDString.lowercaseString]] isDirectory:YES];
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:self.supportURL
      withIntermediateDirectories:YES attributes:nil error:nil]);
  // The drive uses the app's real project storage (Application Support in
  // the app container) exactly as the production bridge does; only the
  // runner-only repositories live under the temporary support directory.
  self.projectAccess = [DSHLocalProjectAccess sharedAccess];
  Class moduleClass = NSClassFromString(@"LocalProjectsModule");
  XCTAssertNotNil(moduleClass);
  self.module = [[moduleClass alloc] init];
}

- (void)tearDown {
  self.module = nil;
  if (self.supportURL != nil) {
    [NSFileManager.defaultManager removeItemAtURL:self.supportURL error:nil];
    git_libgit2_shutdown();
  }
  [super tearDown];
}

// MARK: - Helpers

static NSString *G2SHA256(NSData *data) {
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  NSMutableString *hex = [NSMutableString stringWithCapacity:64];
  for (int index = 0; index < CC_SHA256_DIGEST_LENGTH; index += 1) {
    [hex appendFormat:@"%02x", digest[index]];
  }
  return hex;
}

/// Runs one bridge method synchronously; returns the resolved value or nil
/// with the rejection code in `codeOut`.
- (id)bridge:(void (^)(G2Resolve resolve, G2Reject reject))operation
        code:(NSString **)codeOut
     message:(NSString **)messageOut {
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  __block id resolved = nil;
  __block NSString *code = nil;
  __block NSString *message = nil;
  operation(^(id result) {
    resolved = result;
    dispatch_semaphore_signal(done);
  }, ^(NSString *rejectCode, NSString *rejectMessage, __unused NSError *error) {
    code = rejectCode;
    message = rejectMessage;
    dispatch_semaphore_signal(done);
  });
  long waited = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW,
                                                            180 * NSEC_PER_SEC));
  XCTAssertEqual(waited, 0, @"bridge call did not settle");
  if (codeOut != nil) *codeOut = code;
  if (messageOut != nil) *messageOut = message;
  return resolved;
}

- (id)expectResolved:(void (^)(G2Resolve resolve, G2Reject reject))operation
                step:(NSString *)step {
  NSString *code = nil;
  NSString *message = nil;
  id result = [self bridge:operation code:&code message:&message];
  XCTAssertNotNil(result, @"%@ rejected: %@ %@", step, code, message);
  NSLog(@"G2: %@ -> %@", step, result);
  return result;
}

- (NSString *)expectRejected:(void (^)(G2Resolve resolve, G2Reject reject))operation
                        step:(NSString *)step {
  NSString *code = nil;
  NSString *message = nil;
  id result = [self bridge:operation code:&code message:&message];
  XCTAssertNil(result, @"%@ unexpectedly resolved: %@", step, result);
  NSLog(@"G2: %@ -> rejected %@ (%@)", step, code, message);
  return code;
}

- (NSDictionary *)control:(NSString *)path json:(NSDictionary *)body {
  NSURL *url = [NSURL URLWithString:[self.env[@"DSH_G2_SERVER"] stringByAppendingString:path]];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = body == nil ? @"GET" : @"POST";
  request.timeoutInterval = 60;
  NSString *pair = [NSString stringWithFormat:@"%@:%@", self.env[@"DSH_G2_USER"],
                                              self.env[@"DSH_G2_TOKEN"]];
  NSString *basic = [[pair dataUsingEncoding:NSUTF8StringEncoding]
      base64EncodedStringWithOptions:0];
  [request setValue:[@"Basic " stringByAppendingString:basic]
      forHTTPHeaderField:@"Authorization"];
  if (body != nil) {
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  }
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  __block NSDictionary *parsed = nil;
  __block NSInteger status = 0;
  NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:request
      completionHandler:^(NSData *data, NSURLResponse *response, __unused NSError *error) {
        status = [(NSHTTPURLResponse *)response statusCode];
        parsed = data == nil ? nil
            : [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        dispatch_semaphore_signal(done);
      }];
  [task resume];
  dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_SEC));
  XCTAssertEqual(status, 200, @"%@ -> %ld %@", path, (long)status, parsed);
  return [parsed isKindOfClass:NSDictionary.class] ? parsed : @{};
}

- (NSString *)writeFile:(NSString *)name
                content:(NSString *)content
              projectId:(NSString *)projectId {
  NSError *error = nil;
  __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *lease =
      [self.projectAccess leaseProjectId:projectId
                                    mode:DSHLocalProjectAccessModeWrite
                         includeMetadata:NO
                                   error:&error];
  XCTAssertNotNil(lease, @"%@", error);
  NSData *bytes = [content dataUsingEncoding:NSUTF8StringEncoding];
  NSURL *target = [lease.repositoryURL URLByAppendingPathComponent:name isDirectory:NO];
  XCTAssertTrue([bytes writeToURL:target options:NSDataWritingAtomic error:&error], @"%@", error);
  lease = nil;
  return G2SHA256(bytes);
}

- (void)installPromptHookWithExpiry:(NSInteger)expirySeconds
                            capture:(NSMutableDictionary *)capture {
  NSString *user = self.env[@"DSH_G2_USER"];
  NSString *token = self.env[@"DSH_G2_TOKEN"];
  id hook = ^(NSString *host, BOOL chinese, BOOL plaintext,
              void (^completion)(NSString *, NSString *, NSInteger, NSString *)) {
    capture[@"host"] = host;
    capture[@"chinese"] = @(chinese);
    capture[@"plaintext"] = @(plaintext);
    completion(user, token, expirySeconds, nil);
  };
  [self.module setValue:hook forKey:@"credentialPromptHook"];
}

// MARK: - G2 drive

- (void)testG2RemotePushAcceptanceOnSimulator {
  NSString *publicURL = self.env[@"DSH_G2_PUBLIC_URL"];
  NSString *targetURL = self.env[@"DSH_G2_TARGET_URL"];
  NSString *branch = self.env[@"DSH_G2_BRANCH"];
  NSString *host = [NSURLComponents componentsWithString:targetURL].host.lowercaseString;
  NSMutableDictionary *report = [NSMutableDictionary dictionary];
  report[@"schema_version"] = @1;
  report[@"branch"] = branch;
  report[@"public_url"] = publicURL;
  report[@"target_url"] = targetURL;

  // 1. Public clone without credentials through the production clone path.
  NSString *projectName = [NSString stringWithFormat:@"g2-%@",
      [[NSUUID.UUID.UUIDString.lowercaseString substringToIndex:8] copy]];
  NSDictionary *project = [self expectResolved:^(G2Resolve resolve, G2Reject reject) {
    [self.module clonePublicRepository:publicURL name:projectName options:nil
                              resolver:resolve rejecter:reject];
  } step:@"clone public"];
  NSString *projectId = project[@"id"];
  XCTAssertEqual(projectId.length, 36u);
  XCTAssertEqualObjects(project[@"origin_url"], publicURL);
  report[@"project_id"] = projectId;
  NSDictionary *cloned = [self expectResolved:^(G2Resolve resolve, G2Reject reject) {
    [self.module statusForProject:projectId resolver:resolve rejecter:reject];
  } step:@"status after clone"];
  XCTAssertEqualObjects(cloned[@"clean"], @YES);
  report[@"clone_head_oid"] = cloned[@"head_oid"];
  report[@"clone_branch"] = cloned[@"branch"];

  // 2. Local commit through the app file path + stage + commit.
  NSMutableArray *files = [NSMutableArray array];
  NSString *content1 = [NSString stringWithFormat:@"pushed from the simulator at %@\n",
                        [NSISO8601DateFormatter stringFromDate:NSDate.date
                                                      timeZone:[NSTimeZone timeZoneWithAbbreviation:@"UTC"]
                                                 formatOptions:NSISO8601DateFormatWithInternetDateTime]];
  [files addObject:@{ @"path" : @"simulator.txt",
                      @"sha256" : [self writeFile:@"simulator.txt" content:content1
                                        projectId:projectId] }];
  [files addObject:@{ @"path" : @"nested/receipt.md",
                      @"sha256" : ({
                        NSError *error = nil;
                        __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *lease =
                            [self.projectAccess leaseProjectId:projectId
                                                          mode:DSHLocalProjectAccessModeWrite
                                               includeMetadata:NO error:&error];
                        [NSFileManager.defaultManager createDirectoryAtURL:
                            [lease.repositoryURL URLByAppendingPathComponent:@"nested" isDirectory:YES]
                            withIntermediateDirectories:YES attributes:nil error:nil];
                        lease = nil;
                        [self writeFile:@"nested/receipt.md" content:@"# receipt\n" projectId:projectId];
                      }) }];
  report[@"files"] = files;
  [self expectResolved:^(G2Resolve resolve, G2Reject reject) {
    [self.module stageAllForProject:projectId resolver:resolve rejecter:reject];
  } step:@"stage all"];
  NSDictionary *commit1 = [self expectResolved:^(G2Resolve resolve, G2Reject reject) {
    [self.module commitProject:projectId message:@"G2 simulator commit"
                    authorName:@"Rish Simulator" authorEmail:@"g2@rish.local"
                      resolver:resolve rejecter:reject];
  } step:@"commit 1"];
  report[@"commit1_oid"] = commit1[@"oid"];

  // 3. Dedicated test remote.
  NSDictionary *remote = [self expectResolved:^(G2Resolve resolve, G2Reject reject) {
    [self.module setRemoteForProject:projectId url:targetURL resolver:resolve rejecter:reject];
  } step:@"set origin"];
  XCTAssertEqualObjects(remote[@"url"], targetURL);

  // 4. Push before provisioning is refused without contacting the server.
  report[@"push_without_credential_code"] = [self expectRejected:^(G2Resolve resolve, G2Reject reject) {
    [self.module pushProject:projectId options:@{} resolver:resolve rejecter:reject];
  } step:@"push without credential"] ?: @"";

  // 5. Token provisioned through the native prompt flow (1 hour expiry).
  NSMutableDictionary *prompt = [NSMutableDictionary dictionary];
  [self installPromptHookWithExpiry:DSHGitCredentialExpiryOneHour capture:prompt];
  NSDictionary *provisioned = [self expectResolved:^(G2Resolve resolve, G2Reject reject) {
    [self.module presentCredentialPromptForProject:projectId locale:@"en"
                                          resolver:resolve rejecter:reject];
  } step:@"provision credential"];
  XCTAssertEqualObjects(prompt[@"host"], host);
  XCTAssertEqualObjects(prompt[@"plaintext"], @YES);
  XCTAssertNil(provisioned[@"token"]);
  XCTAssertNil(provisioned[@"username"]);
  XCTAssertEqualObjects(provisioned[@"configured"], @YES);
  NSDictionary *credentialStatus = [self expectResolved:^(G2Resolve resolve, G2Reject reject) {
    [self.module credentialStatusForProject:projectId resolver:resolve rejecter:reject];
  } step:@"credential status"];
  XCTAssertEqualObjects(credentialStatus[@"expiry_seconds"], @(DSHGitCredentialExpiryOneHour));
  report[@"credential_status"] = credentialStatus;
  [self.module setValue:nil forKey:@"credentialPromptHook"];

  // 6. Push the commit as a new branch.
  NSDictionary *pushed = [self expectResolved:^(G2Resolve resolve, G2Reject reject) {
    [self.module pushProject:projectId options:@{ @"branch" : branch }
                    resolver:resolve rejecter:reject];
  } step:@"push new branch"];
  XCTAssertEqualObjects(pushed[@"branch"], branch);
  XCTAssertEqualObjects(pushed[@"oid"], commit1[@"oid"]);
  NSDictionary *receipt = pushed[@"receipt"];
  XCTAssertEqualObjects(receipt[@"local_oid"], commit1[@"oid"]);
  XCTAssertEqualObjects(receipt[@"remote_oid"], commit1[@"oid"]);
  XCTAssertEqualObjects(receipt[@"host"], host);
  report[@"first_push"] = pushed;
  NSDictionary *afterPush = [self expectResolved:^(G2Resolve resolve, G2Reject reject) {
    [self.module statusForProject:projectId resolver:resolve rejecter:reject];
  } step:@"status after push"];
  XCTAssertEqualObjects(afterPush[@"branch"], branch);
  XCTAssertEqualObjects(afterPush[@"ahead"], @0);
  NSDictionary *receipts = [self expectResolved:^(G2Resolve resolve, G2Reject reject) {
    [self.module pushReceiptsForProject:projectId resolver:resolve rejecter:reject];
  } step:@"push receipts"];
  report[@"receipts_count"] = @([receipts[@"receipts"] count]);
  XCTAssertEqualObjects([receipts[@"receipts"] lastObject][@"remote_oid"], commit1[@"oid"]);

  // 7. The Mac creates a competing commit on the remote branch.
  NSDictionary *compete = [self control:@"/g2/compete"
                                   json:@{ @"repo" : @"target.git", @"branch" : branch }];
  XCTAssertEqualObjects(compete[@"old_oid"], commit1[@"oid"]);
  report[@"compete"] = compete;

  // 8. A second local commit must be rejected as non-fast-forward.
  [self writeFile:@"simulator.txt" content:@"second local change\n" projectId:projectId];
  [self expectResolved:^(G2Resolve resolve, G2Reject reject) {
    [self.module stageAllForProject:projectId resolver:resolve rejecter:reject];
  } step:@"stage all 2"];
  NSDictionary *commit2 = [self expectResolved:^(G2Resolve resolve, G2Reject reject) {
    [self.module commitProject:projectId message:@"G2 second commit"
                    authorName:@"Rish Simulator" authorEmail:@"g2@rish.local"
                      resolver:resolve rejecter:reject];
  } step:@"commit 2"];
  report[@"commit2_oid"] = commit2[@"oid"];
  NSString *message = nil;
  NSString *code = nil;
  id rejected = [self bridge:^(G2Resolve resolve, G2Reject reject) {
    [self.module pushProject:projectId options:@{} resolver:resolve rejecter:reject];
  } code:&code message:&message];
  XCTAssertNil(rejected);
  XCTAssertEqualObjects(code, @"non-fast-forward");
  NSLog(@"G2: second push -> %@ (%@)", code, message);
  report[@"second_push"] = @{ @"code" : code ?: @"", @"message" : message ?: @"" };
  NSDictionary *afterReject = [self expectResolved:^(G2Resolve resolve, G2Reject reject) {
    [self.module statusForProject:projectId resolver:resolve rejecter:reject];
  } step:@"status after rejection"];
  XCTAssertEqualObjects(afterReject[@"head_oid"], commit2[@"oid"]);
  XCTAssertEqualObjects(afterReject[@"branch"], branch);
  report[@"head_after_nff"] = afterReject[@"head_oid"];
  report[@"status_after_nff"] = @{ @"branch" : afterReject[@"branch"],
                                   @"clean" : afterReject[@"clean"] };
  NSDictionary *receiptsAfter = [self expectResolved:^(G2Resolve resolve, G2Reject reject) {
    [self.module pushReceiptsForProject:projectId resolver:resolve rejecter:reject];
  } step:@"push receipts after rejection"];
  XCTAssertEqual([receiptsAfter[@"receipts"] count], [receipts[@"receipts"] count]);

  // 9. Clearing the credential leaves nothing behind.
  NSDictionary *cleared = [self expectResolved:^(G2Resolve resolve, G2Reject reject) {
    [self.module clearCredentialForProject:projectId resolver:resolve rejecter:reject];
  } step:@"clear credential"];
  XCTAssertEqualObjects(cleared[@"configured"], @NO);
  report[@"cleared_credential"] = cleared;
  XCTAssertNil(DSHGitCredentialForScope(projectId, host, nil));

  NSDictionary *stored = [self control:@"/g2/report" json:report];
  XCTAssertNotNil(stored[@"stored"]);
  NSLog(@"G2: report stored at %@", stored[@"stored"]);
}

// MARK: - Bounded runner over the real HTTP transport

- (git_repository *)seedRepositoryWithRemote:(NSString *)remoteURL oid:(NSString **)oidOut {
  NSURL *url = [self.supportURL URLByAppendingPathComponent:@"runner-local" isDirectory:YES];
  git_repository *repository = nullptr;
  XCTAssertEqual(git_repository_init(&repository, url.fileSystemRepresentation, 0), 0);
  XCTAssertEqual(git_repository_set_head(repository, "refs/heads/main"), 0);
  git_oid blob = {};
  const char *bytes = "runner\n";
  XCTAssertEqual(git_blob_create_from_buffer(&blob, repository, bytes, strlen(bytes)), 0);
  git_treebuilder *builder = nullptr;
  XCTAssertEqual(git_treebuilder_new(&builder, repository, nullptr), 0);
  XCTAssertEqual(git_treebuilder_insert(nullptr, builder, "runner.txt", &blob,
                                        GIT_FILEMODE_BLOB), 0);
  git_oid treeOID = {};
  XCTAssertEqual(git_treebuilder_write(&treeOID, builder), 0);
  git_treebuilder_free(builder);
  git_tree *tree = nullptr;
  XCTAssertEqual(git_tree_lookup(&tree, repository, &treeOID), 0);
  git_signature *signature = nullptr;
  XCTAssertEqual(git_signature_new(&signature, "Rish Test", "test@rish.local", 1, 0), 0);
  git_oid commitOID = {};
  XCTAssertEqual(git_commit_create(&commitOID, repository, "refs/heads/main", signature,
                                   signature, "UTF-8", "runner", tree, 0, nullptr), 0);
  git_signature_free(signature);
  git_tree_free(tree);
  git_remote *remote = nullptr;
  XCTAssertEqual(git_remote_create(&remote, repository, "origin", remoteURL.UTF8String), 0);
  git_remote_free(remote);
  char buffer[GIT_OID_SHA1_HEXSIZE + 1] = {};
  git_oid_tostr(buffer, sizeof(buffer), &commitOID);
  if (oidOut != nil) *oidOut = [NSString stringWithUTF8String:buffer];
  return repository;
}

- (DSHGitPushRequest *)runnerRequestForRepository:(git_repository *)repository
                                           remote:(NSString *)remoteURL
                                              oid:(NSString *)oid
                                            token:(NSString *)token {
  DSHGitPushRequest *request = [[DSHGitPushRequest alloc] init];
  request.repository = repository;
  request.remoteName = @"origin";
  request.remoteURL = remoteURL;
  request.host = [NSURLComponents componentsWithString:remoteURL].host.lowercaseString;
  request.fullReference = [@"refs/heads/runner-" stringByAppendingString:
      [NSUUID.UUID.UUIDString.lowercaseString substringToIndex:8]];
  request.localOID = oid;
  request.username = self.env[@"DSH_G2_USER"];
  request.token = token;
  return request;
}

- (void)testRunnerRejectsWrongTokenOverHTTPAsAuthFailure {
  NSString *oid = nil;
  git_repository *repository = [self seedRepositoryWithRemote:self.env[@"DSH_G2_TARGET_URL"]
                                                          oid:&oid];
  // The local branch name must exist for the refspec; point it at main.
  DSHGitPushRequest *request = [self runnerRequestForRepository:repository
      remote:self.env[@"DSH_G2_TARGET_URL"] oid:oid token:@"definitely-not-the-token"];
  git_reference *created = nullptr;
  git_oid target = {};
  XCTAssertEqual(git_oid_fromstr(&target, oid.UTF8String), 0);
  XCTAssertEqual(git_reference_create(&created, repository, request.fullReference.UTF8String,
                                      &target, 0, "test"), 0);
  git_reference_free(created);
  DSHGitPushResult *result = DSHGitPushRun(request);
  XCTAssertEqual(result.outcome, DSHGitPushOutcomeAuthFailure);
  XCTAssertFalse(result.effectMayHaveOccurred);
  git_repository_free(repository);
}

- (void)testRunnerTimesOutAndCancelsAgainstStallingRemote {
  NSString *oid = nil;
  git_repository *repository = [self seedRepositoryWithRemote:self.env[@"DSH_G2_STALL_URL"]
                                                          oid:&oid];
  DSHGitPushRequest *timed = [self runnerRequestForRepository:repository
      remote:self.env[@"DSH_G2_STALL_URL"] oid:oid token:self.env[@"DSH_G2_TOKEN"]];
  git_reference *created = nullptr;
  git_oid target = {};
  XCTAssertEqual(git_oid_fromstr(&target, oid.UTF8String), 0);
  XCTAssertEqual(git_reference_create(&created, repository, timed.fullReference.UTF8String,
                                      &target, 0, "test"), 0);
  git_reference_free(created);
  timed.timeout = 2.0;
  NSDate *start = NSDate.date;
  DSHGitPushResult *timedOut = DSHGitPushRun(timed);
  XCTAssertEqual(timedOut.outcome, DSHGitPushOutcomeTimedOut);
  XCTAssertLessThan(-start.timeIntervalSinceNow, 6.0);

  // A second repository handle keeps the cancelled push independent from the
  // still-draining timed-out worker.
  NSURL *url = [self.supportURL URLByAppendingPathComponent:@"runner-local" isDirectory:YES];
  git_repository *second = nullptr;
  XCTAssertEqual(git_repository_open(&second, url.fileSystemRepresentation), 0);
  DSHGitPushRequest *cancelled = [self runnerRequestForRepository:second
      remote:self.env[@"DSH_G2_STALL_URL"] oid:oid token:self.env[@"DSH_G2_TOKEN"]];
  cancelled.fullReference = timed.fullReference;
  cancelled.timeout = 30.0;
  cancelled.cancelToken = [[DSHGitPushCancelToken alloc] init];
  DSHGitPushCancelToken *token = cancelled.cancelToken;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                 dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [token cancel]; });
  start = NSDate.date;
  DSHGitPushResult *result = DSHGitPushRun(cancelled);
  XCTAssertEqual(result.outcome, DSHGitPushOutcomeCancelled);
  XCTAssertLessThan(-start.timeIntervalSinceNow, 6.0);
  // Let the stalled workers drain before the repositories are freed.
  [NSThread sleepForTimeInterval:9.0];
  git_repository_free(second);
  git_repository_free(repository);
}


// Clone acceptance uses only anonymous fetches and an isolated fixture root.
// It does not configure credentials, mutate remotes, commit, or push.
- (NSDictionary *)cloneStatus:(NSString *)operationId {
  return [self expectResolved:^(G2Resolve resolve, G2Reject reject) {
    [self.module cloneStatusForOperation:operationId resolver:resolve rejecter:reject];
  } step:@"clone status"];
}

- (NSDictionary *)waitForClone:(NSString *)operationId {
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:40];
  NSDictionary *snapshot = nil;
  do {
    snapshot = [self bridge:^(G2Resolve resolve, G2Reject reject) {
      [self.module cloneStatusForOperation:operationId resolver:resolve rejecter:reject];
    } code:nil message:nil];
    if ([@[@"succeeded", @"failed", @"cancelled"] containsObject:snapshot[@"phase"]]) return snapshot;
    [NSThread sleepForTimeInterval:0.05];
  } while (deadline.timeIntervalSinceNow > 0);
  XCTFail(@"Clone did not reach a terminal state: %@", snapshot);
  return snapshot;
}

- (NSDictionary *)startClone:(NSString *)url name:(NSString *)name {
  return [self expectResolved:^(G2Resolve resolve, G2Reject reject) {
    [self.module startCloneURL:url name:name options:@{} resolver:resolve rejecter:reject];
  } step:@"start clone"];
}

- (NSArray *)cloneFixtureEntries {
  return [NSFileManager.defaultManager contentsOfDirectoryAtPath:
    [self.supportURL URLByAppendingPathComponent:@"projects"].path error:nil] ?: @[];
}

- (void)testCloneOperationTransferCancellationAndPublication {
  [NSFileManager.defaultManager removeItemAtURL:self.supportURL error:nil];
  self.supportURL = DSHCreateTestStorageFixtureRoot(@"CloneOperationTests", nil);
  XCTAssertNotNil(self.supportURL);
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:
    [self.supportURL URLByAppendingPathComponent:@"projects" isDirectory:YES]
    withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:nil]);
  self.projectAccess = [[DSHLocalProjectAccess alloc] initWithProjectsRootURL:
    [self.supportURL URLByAppendingPathComponent:@"projects" isDirectory:YES]];
  [self.module setValue:self.projectAccess forKey:@"projectAccess"];

  NSString *slowPublic = [self.env[@"DSH_G2_PUBLIC_URL"]
    stringByReplacingOccurrencesOfString:@"/public.git" withString:@"/slow-public.git"];
  NSDictionary *started = [self startClone:slowPublic name:@"cancel-transfer"];
  [NSThread sleepForTimeInterval:0.4];
  NSDictionary *cancelling = [self expectResolved:^(G2Resolve resolve, G2Reject reject) {
    [self.module cancelCloneOperation:started[@"operation_id"] resolver:resolve rejecter:reject];
  } step:@"cancel transfer"];
  XCTAssertEqualObjects(cancelling[@"cancel_requested"], @YES);
  BOOL alreadyFinished = [@[@"succeeded", @"failed", @"cancelled"] containsObject:cancelling[@"phase"]];
  XCTAssertFalse(alreadyFinished);
  NSDictionary *cancelled = [self waitForClone:started[@"operation_id"]];
  XCTAssertEqualObjects(cancelled[@"phase"], @"cancelled");
  XCTAssertEqualObjects(cancelled[@"project"], NSNull.null);
  XCTAssertEqual(self.cloneFixtureEntries.count, (NSUInteger)0);

  __weak GitPushG2Tests *weakSelf = self;
  [self.module setValue:^(NSString *phase) {
    if (![phase isEqual:@"before_publish"]) return;
    [weakSelf.module cloneStatusForOperation:NSNull.null resolver:^(NSDictionary *current) {
      [weakSelf.module cancelCloneOperation:current[@"operation_id"] resolver:^(__unused id result) {}
        rejecter:^(__unused NSString *code, __unused NSString *message, __unused NSError *error) { XCTFail(@"pre-publish cancel rejected"); }];
    } rejecter:^(__unused NSString *code, __unused NSString *message, __unused NSError *error) { XCTFail(@"snapshot rejected"); }];
  } forKey:@"clonePhaseHook"];
  started = [self startClone:self.env[@"DSH_G2_PUBLIC_URL"] name:@"cancel-before-publish"];
  NSDictionary *beforePublish = [self waitForClone:started[@"operation_id"]];
  XCTAssertEqualObjects(beforePublish[@"phase"], @"cancelled");
  XCTAssertGreaterThan([beforePublish[@"received_bytes"] unsignedIntegerValue], (NSUInteger)0);
  XCTAssertGreaterThan([beforePublish[@"completed_files"] unsignedIntegerValue], (NSUInteger)0);
  XCTAssertEqual(self.cloneFixtureEntries.count, (NSUInteger)0);
  [self.module setValue:nil forKey:@"clonePhaseHook"];

  started = [self startClone:@"http://127.0.0.1:1/offline.git" name:@"offline"];
  NSDictionary *offline = [self waitForClone:started[@"operation_id"]];
  XCTAssertEqualObjects(offline[@"phase"], @"failed");
  XCTAssertEqual(self.cloneFixtureEntries.count, (NSUInteger)0);

  started = [self startClone:self.env[@"DSH_G2_PUBLIC_URL"] name:@"complete-clone"];
  NSDictionary *success = [self waitForClone:started[@"operation_id"]];
  XCTAssertEqualObjects(success[@"phase"], @"succeeded");
  XCTAssertEqual(self.cloneFixtureEntries.count, (NSUInteger)1);
  XCTAssertGreaterThan([success[@"received_bytes"] unsignedIntegerValue], (NSUInteger)0);
  XCTAssertEqualObjects(success[@"completed_files"], success[@"total_files"]);
  NSDictionary *lateCancel = [self expectResolved:^(G2Resolve resolve, G2Reject reject) {
    [self.module cancelCloneOperation:started[@"operation_id"] resolver:resolve rejecter:reject];
  } step:@"late cancellation"];
  XCTAssertEqualObjects(lateCancel[@"phase"], @"succeeded");
  XCTAssertEqualObjects(lateCancel[@"cancel_requested"], @NO);
  if (![success[@"project"] isKindOfClass:NSDictionary.class]) return;
  NSDictionary *status = [self expectResolved:^(G2Resolve resolve, G2Reject reject) {
    [self.module statusForProject:success[@"project"][@"id"] resolver:resolve rejecter:reject];
  } step:@"cloned status"];
  XCTAssertEqualObjects(status[@"clean"], @YES);
  NSLog(@"CLONE_ACCEPTANCE: %@", @{ @"transfer_cancel": cancelled,
    @"before_publish_cancel": beforePublish, @"offline": offline,
    @"success": success, @"status": status });
}

@end
