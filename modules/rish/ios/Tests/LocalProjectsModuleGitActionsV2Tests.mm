#import "LocalProjectsModuleV2TestSupport.h"
#import "DSHGitPushSupport.h"
#import <CommonCrypto/CommonDigest.h>
#include <git2.h>

typedef void (^GAV2Resolve)(id result);
typedef void (^GAV2Reject)(NSString *code, NSString *message, NSError *error);

@interface LocalProjectsModule (GitActionsV2Testing)
- (void)stageAllV2Request:(id)request resolver:(GAV2Resolve)resolve rejecter:(GAV2Reject)reject;
- (void)commitV2Request:(id)request resolver:(GAV2Resolve)resolve rejecter:(GAV2Reject)reject;
- (void)statusV2Request:(id)request resolver:(GAV2Resolve)resolve rejecter:(GAV2Reject)reject;
- (void)setRemoteV2Request:(id)request resolver:(GAV2Resolve)resolve rejecter:(GAV2Reject)reject;
- (void)presentCredentialPromptV2Request:(id)request resolver:(GAV2Resolve)resolve rejecter:(GAV2Reject)reject;
- (void)clearCredentialV2Request:(id)request resolver:(GAV2Resolve)resolve rejecter:(GAV2Reject)reject;
- (void)pushV2Request:(id)request resolver:(GAV2Resolve)resolve rejecter:(GAV2Reject)reject;
- (void)pushReceiptsV2Request:(id)request resolver:(GAV2Resolve)resolve rejecter:(GAV2Reject)reject;
@end

// Reuse the isolated workspace fixture. Run this class only on a disposable
// simulator: LocalProjectsModule initializes its real registry before DI.
@implementation LocalProjectsModuleV2Tests (GitActions)

- (NSDictionary *)gaAttach {
  NSError *error = nil;
  NSMutableDictionary *root = [self.root mutableCopy];
  @autoreleasepool {
    NSDictionary *attached = [self.module v2AttachWorkspaceProject:@{
      @"schema_version" : @1, @"root" : self.root,
      @"operation_id" : NSUUID.UUID.UUIDString.lowercaseString, @"mode" : @"init"
    } error:&error];
    XCTAssertNotNil(attached, @"%@", error);
    root[@"project_id"] = attached[@"project"][@"project_id"];
  }
  self.root = root;
  return root;
}

- (id)gaBridge:(void (^)(GAV2Resolve, GAV2Reject))operation code:(NSString **)codeOut {
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  __block id result = nil;
  __block NSString *code = nil;
  operation(^(id value) { result = value; dispatch_semaphore_signal(done); },
      ^(NSString *value, __unused NSString *message, __unused NSError *error) {
        code = value; dispatch_semaphore_signal(done);
      });
  XCTAssertEqual(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)), 0L);
  if (codeOut != nil) *codeOut = code;
  return result;
}

- (NSDictionary *)gaRequest {
  return @{ @"schema_version" : @1, @"root" : self.root };
}

- (NSDictionary *)gaRequestWith:(NSDictionary *)fields {
  NSMutableDictionary *request = [[self gaRequest] mutableCopy];
  [request addEntriesFromDictionary:fields];
  return request;
}

- (NSDictionary *)gaCommitRequest:(id)expectedHead {
  return @{
    @"schema_version" : @1, @"root" : self.root,
    @"operation_id" : NSUUID.UUID.UUIDString.lowercaseString,
    @"message" : @"保存中文内容",
    @"author_name" : @"Fixture Author", @"author_email" : @"fixture@example.invalid",
    @"expected_head_oid" : expectedHead
  };
}

- (NSURL *)gaFile:(NSString *)name content:(NSString *)content {
  NSError *error = nil;
  NSURL *file = nil;
  @autoreleasepool {
    DSHLocalProjectLease *lease = [self.projectAccess leaseWorkspaceRootRef:self.root
        mode:DSHLocalProjectAccessModeWrite includeMetadata:NO timeout:1 error:&error];
    XCTAssertNotNil(lease, @"%@", error);
    file = [lease.repositoryURL URLByAppendingPathComponent:name];
    XCTAssertTrue([[content dataUsingEncoding:NSUTF8StringEncoding]
        writeToURL:file options:NSDataWritingAtomic error:&error], @"%@", error);
  }
  return file;
}

- (NSDictionary *)gaStage {
  NSString *code = nil;
  NSDictionary *result = [self gaBridge:^(GAV2Resolve resolve, GAV2Reject reject) {
    [self.module stageAllV2Request:[self gaRequest] resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertNotNil(result, @"%@", code);
  XCTAssertEqualObjects(result[@"schema_version"], @2);
  XCTAssertEqualObjects(result[@"root"], self.root);
  return result;
}

- (void)testGitActionsV2StageCommitAndReadBackChineseContent {
  [self gaAttach];
  NSString *content = @"# 中文文件\n由 Git 面板提交。\n";
  [self gaFile:@"notes.md" content:content];
  [self gaStage];
  NSString *code = nil;
  NSDictionary *committed = [self gaBridge:^(GAV2Resolve resolve, GAV2Reject reject) {
    [self.module commitV2Request:[self gaCommitRequest:NSNull.null] resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertNotNil(committed, @"%@", code);
  XCTAssertEqualObjects(committed[@"schema_version"], @2);
  XCTAssertEqualObjects(committed[@"root"], self.root);
  XCTAssertEqualObjects(committed[@"summary"], @"保存中文内容");
  XCTAssertEqual([committed[@"oid"] length], 40u);
  NSDictionary *status = [self gaBridge:^(GAV2Resolve resolve, GAV2Reject reject) {
    [self.module statusV2Request:[self gaRequest] resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertEqualObjects(status[@"clean"], @YES);
  XCTAssertEqualObjects(status[@"head_oid"], committed[@"oid"]);

  NSError *error = nil;
  @autoreleasepool {
    DSHLocalProjectLease *lease = [self.projectAccess leaseWorkspaceRootRef:self.root
        mode:DSHLocalProjectAccessModeRead includeMetadata:NO timeout:1 error:&error];
    XCTAssertNotNil(lease, @"%@", error);
    git_object *object = nullptr;
    XCTAssertEqual(git_revparse_single(&object, lease.repository, "HEAD:notes.md"), 0);
    if (object != nullptr) {
      git_blob *blob = (git_blob *)object;
      NSData *actual = [NSData dataWithBytes:git_blob_rawcontent(blob) length:git_blob_rawsize(blob)];
      XCTAssertEqualObjects(actual, [content dataUsingEncoding:NSUTF8StringEncoding]);
      git_object_free(object);
    }
  }
}

- (void)testGitActionsV2RejectsStaleHeadWithoutLosingStagedChanges {
  [self gaAttach];
  [self gaFile:@"notes.md" content:@"first\n"];
  [self gaStage];
  NSString *code = nil;
  NSDictionary *first = [self gaBridge:^(GAV2Resolve resolve, GAV2Reject reject) {
    [self.module commitV2Request:[self gaCommitRequest:NSNull.null] resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertNotNil(first, @"%@", code);
  if (first == nil) return;
  [self gaFile:@"notes.md" content:@"second\n"];
  [self gaStage];
  id stale = [self gaBridge:^(GAV2Resolve resolve, GAV2Reject reject) {
    [self.module commitV2Request:[self gaCommitRequest:NSNull.null] resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertNil(stale);
  XCTAssertEqualObjects(code, @"E_PROJECT_CONFLICT");
  NSDictionary *status = [self gaBridge:^(GAV2Resolve resolve, GAV2Reject reject) {
    [self.module statusV2Request:[self gaRequest] resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertEqualObjects(status[@"head_oid"], first[@"oid"]);
  XCTAssertEqualObjects(status[@"clean"], @NO);
  NSDictionary *second = [self gaBridge:^(GAV2Resolve resolve, GAV2Reject reject) {
    [self.module commitV2Request:[self gaCommitRequest:first[@"oid"]] resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertNotNil(second, @"%@", code);
  XCTAssertNotEqualObjects(second[@"oid"], first[@"oid"]);
}

- (void)testGitActionsV2StageAllIncludesTrackedDeletion {
  [self gaAttach];
  NSURL *file = [self gaFile:@"delete-me.txt" content:@"tracked\n"];
  [self gaStage];
  NSString *code = nil;
  NSDictionary *first = [self gaBridge:^(GAV2Resolve resolve, GAV2Reject reject) {
    [self.module commitV2Request:[self gaCommitRequest:NSNull.null] resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertNotNil(first, @"%@", code);
  if (first == nil) return;
  XCTAssertTrue([NSFileManager.defaultManager removeItemAtURL:file error:nil]);
  [self gaStage];
  NSDictionary *deleted = [self gaBridge:^(GAV2Resolve resolve, GAV2Reject reject) {
    [self.module commitV2Request:[self gaCommitRequest:first[@"oid"]] resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertNotNil(deleted, @"%@", code);
  NSDictionary *status = [self gaBridge:^(GAV2Resolve resolve, GAV2Reject reject) {
    [self.module statusV2Request:[self gaRequest] resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertEqualObjects(status[@"clean"], @YES);
  XCTAssertEqualObjects(status[@"head_oid"], deleted[@"oid"]);
  NSError *error = nil;
  @autoreleasepool {
    DSHLocalProjectLease *lease = [self.projectAccess leaseWorkspaceRootRef:self.root
        mode:DSHLocalProjectAccessModeRead includeMetadata:NO timeout:1 error:&error];
    XCTAssertNotNil(lease, @"%@", error);
    git_object *object = nullptr;
    XCTAssertEqual(git_revparse_single(&object, lease.repository, "HEAD:delete-me.txt"), GIT_ENOTFOUND);
    if (object != nullptr) git_object_free(object);
  }
}

- (NSDictionary *)gaControl:(NSString *)path body:(NSDictionary *)body environment:(NSDictionary *)env {
  NSURL *url = [NSURL URLWithString:[env[@"DSH_G2_SERVER"] stringByAppendingString:path]];
  XCTAssertEqualObjects(url.host, @"127.0.0.1");
  XCTAssertEqualObjects(url.scheme, @"http");
  if (![url.host isEqual:@"127.0.0.1"] || ![url.scheme isEqual:@"http"]) return nil;
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = @"POST";
  request.timeoutInterval = 15;
  request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
  [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  NSString *pair = [NSString stringWithFormat:@"%@:%@", env[@"DSH_G2_USER"], env[@"DSH_G2_TOKEN"]];
  NSString *basic = [[pair dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
  [request setValue:[@"Basic " stringByAppendingString:basic] forHTTPHeaderField:@"Authorization"];
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  __block NSDictionary *response = nil;
  __block NSInteger status = 0;
  NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:request
      completionHandler:^(NSData *data, NSURLResponse *reply, __unused NSError *error) {
        status = [(NSHTTPURLResponse *)reply statusCode];
        response = data == nil ? nil : [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        dispatch_semaphore_signal(done);
      }];
  [task resume];
  XCTAssertEqual(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC)), 0L);
  XCTAssertEqual(status, 200);
  return response;
}

- (NSDictionary *)gaPush:(NSString *)oid code:(NSString **)code {
  return [self gaBridge:^(GAV2Resolve resolve, GAV2Reject reject) {
    [self.module pushV2Request:[self gaRequestWith:@{
      @"operation_id" : NSUUID.UUID.UUIDString.lowercaseString,
      @"remote" : @"origin", @"expected_local_oid" : oid,
      @"credential_reference" : @"panel", @"https_proxy_url" : NSNull.null
    }] resolver:resolve rejecter:reject];
  } code:code];
}

- (void)testGitActionsV2PushesToLoopbackAndRejectsDivergence {
  NSDictionary *env = NSProcessInfo.processInfo.environment;
  NSString *target = env[@"DSH_G2_TARGET_URL"];
  if (target.length == 0) XCTSkip(@"Loopback fixture is not configured");
  NSURLComponents *components = [NSURLComponents componentsWithString:target];
  XCTAssertEqualObjects(components.host, @"127.0.0.1");
  XCTAssertEqualObjects(components.scheme, @"http");
  if (![components.host isEqual:@"127.0.0.1"] || ![components.scheme isEqual:@"http"]) return;
  [self gaAttach];
  NSString *projectId = self.root[@"project_id"];
  [self addTeardownBlock:^{ (void)DSHGitDeleteCredentialForScope(projectId, @"127.0.0.1", nil); }];
  NSString *branch = [@"gpui-v2/" stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];
  NSError *error = nil;
  @autoreleasepool {
    DSHLocalProjectLease *lease = [self.projectAccess leaseWorkspaceRootRef:self.root
        mode:DSHLocalProjectAccessModeWrite includeMetadata:NO timeout:1 error:&error];
    XCTAssertNotNil(lease, @"%@", error);
    XCTAssertEqual(git_repository_set_head(lease.repository,
        [@"refs/heads/" stringByAppendingString:branch].UTF8String), 0);
  }
  NSString *content = @"中文内容通过 V2 推送。\n";
  [self gaFile:@"notes.md" content:content];
  [self gaStage];
  NSString *code = nil;
  NSDictionary *first = [self gaBridge:^(GAV2Resolve resolve, GAV2Reject reject) {
    [self.module commitV2Request:[self gaCommitRequest:NSNull.null] resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertNotNil(first, @"%@", code);
  if (first == nil) return;
  id remote = [self gaBridge:^(GAV2Resolve resolve, GAV2Reject reject) {
    [self.module setRemoteV2Request:[self gaRequestWith:@{ @"url" : target }] resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertNotNil(remote, @"%@", code);
  [self.module setValue:^(__unused NSString *host, __unused BOOL chinese, BOOL plaintext,
      void (^completion)(NSString *, NSString *, NSInteger, NSString *)) {
    XCTAssertTrue(plaintext);
    completion(env[@"DSH_G2_USER"], env[@"DSH_G2_TOKEN"], DSHGitCredentialExpiryOneHour, nil);
  } forKey:@"credentialPromptHook"];
  NSDictionary *credential = [self gaBridge:^(GAV2Resolve resolve, GAV2Reject reject) {
    [self.module presentCredentialPromptV2Request:[self gaRequestWith:@{ @"locale" : @"zh-CN" }]
        resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertEqualObjects(credential[@"configured"], @YES, @"%@", code);
  XCTAssertNil(credential[@"token"]);
  XCTAssertNil(credential[@"username"]);
  [self.module setValue:nil forKey:@"credentialPromptHook"];
  NSDictionary *pushed = [self gaPush:first[@"oid"] code:&code];
  XCTAssertNotNil(pushed, @"%@", code);
  XCTAssertEqualObjects(pushed[@"oid"], first[@"oid"]);
  XCTAssertEqualObjects(pushed[@"branch"], branch);
  if (pushed == nil) return;
  NSDictionary *receipts = [self gaBridge:^(GAV2Resolve resolve, GAV2Reject reject) {
    [self.module pushReceiptsV2Request:[self gaRequest] resolver:resolve rejecter:reject];
  } code:&code];
  NSDictionary *receipt = [receipts[@"receipts"] lastObject];
  XCTAssertEqualObjects(receipt[@"remote_oid"], first[@"oid"]);
  NSDictionary *competing = [self gaControl:@"/g2/compete"
      body:@{ @"repo" : @"target.git", @"branch" : branch } environment:env];
  XCTAssertEqualObjects(competing[@"old_oid"], first[@"oid"]);
  [self gaFile:@"notes.md" content:@"local second\n"];
  [self gaStage];
  NSDictionary *second = [self gaBridge:^(GAV2Resolve resolve, GAV2Reject reject) {
    [self.module commitV2Request:[self gaCommitRequest:first[@"oid"]] resolver:resolve rejecter:reject];
  } code:&code];
  XCTAssertNotNil(second, @"%@", code);
  if (second == nil) return;
  XCTAssertNil([self gaPush:second[@"oid"] code:&code]);
  XCTAssertEqualObjects(code, @"E_PROJECT_NON_FAST_FORWARD");
  NSDictionary *status = [self gaBridge:^(GAV2Resolve resolve, GAV2Reject reject) {
    [self.module statusV2Request:[self gaRequest] resolver:resolve rejecter:reject];
  } code:nil];
  XCTAssertEqualObjects(status[@"head_oid"], second[@"oid"]);
  NSDictionary *cleared = [self gaBridge:^(GAV2Resolve resolve, GAV2Reject reject) {
    [self.module clearCredentialV2Request:[self gaRequest] resolver:resolve rejecter:reject];
  } code:nil];
  XCTAssertEqualObjects(cleared[@"configured"], @NO);
  NSData *bytes = [content dataUsingEncoding:NSUTF8StringEncoding];
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, digest);
  NSMutableString *sha = [NSMutableString string];
  for (unsigned char byte : digest) [sha appendFormat:@"%02x", byte];
  NSDictionary *report = @{
    @"schema_version" : @2, @"branch" : branch, @"first_oid" : first[@"oid"],
    @"local_oid" : second[@"oid"], @"remote_oid" : competing[@"oid"],
    @"receipt" : receipt, @"sha256" : sha, @"rejected_code" : code,
  };
  XCTAssertNotNil([self gaControl:@"/g2/report" body:report environment:env]);
}

@end
