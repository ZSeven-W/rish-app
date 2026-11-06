#import <XCTest/XCTest.h>

#import <Security/Security.h>

#import "../../../../modules/rish/ios/Sources/DSHGitPushSupport.h"

#include <git2.h>
#include <fcntl.h>
#include <unistd.h>

/// Offline coverage of the push support layer: remote URL policy, the
/// project-scoped expiring Keychain credential, the receipt journal, and the
/// bounded runner against a bare repository reached through libgit2's local
/// transport (no credentials, no network).
@interface GitPushSupportTests : XCTestCase
@property(nonatomic, strong) NSURL *rootURL;
@property(nonatomic, copy) NSString *scopeId;
@end

@implementation GitPushSupportTests

- (void)setUp {
  [super setUp];
  git_libgit2_init();
  self.rootURL = [NSURL fileURLWithPath:[NSTemporaryDirectory()
      stringByAppendingPathComponent:[NSString stringWithFormat:@"rish-push-%@",
          NSUUID.UUID.UUIDString.lowercaseString]] isDirectory:YES];
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:self.rootURL
      withIntermediateDirectories:YES attributes:nil error:nil]);
  self.scopeId = NSUUID.UUID.UUIDString.lowercaseString;
}

- (void)tearDown {
  (void)DSHGitDeleteCredentialForScope(self.scopeId, @"127.0.0.1", nil);
  (void)DSHGitDeleteCredentialForScope(self.scopeId, @"github.com", nil);
  [NSFileManager.defaultManager removeItemAtURL:self.rootURL error:nil];
  git_libgit2_shutdown();
  [super tearDown];
}

// MARK: - Helpers

static NSString *GPSOID(const git_oid *oid) {
  char buffer[GIT_OID_SHA1_HEXSIZE + 1] = {};
  git_oid_tostr(buffer, sizeof(buffer), oid);
  return [NSString stringWithUTF8String:buffer];
}

- (git_repository *)initRepositoryNamed:(NSString *)name bare:(BOOL)bare {
  NSURL *url = [self.rootURL URLByAppendingPathComponent:name isDirectory:YES];
  git_repository *repository = nullptr;
  XCTAssertEqual(git_repository_init(&repository, url.fileSystemRepresentation,
                                     bare ? 1 : 0), 0);
  if (!bare) XCTAssertEqual(git_repository_set_head(repository, "refs/heads/main"), 0);
  return repository;
}

/// Commits `content` at `path` on refs/heads/main (or on top of `parentOID`
/// in a bare repository) and returns the commit OID.
- (NSString *)commitPath:(NSString *)path
                 content:(NSString *)content
            inRepository:(git_repository *)repository
                  parent:(NSString *)parentOID
               timestamp:(git_time_t)timestamp {
  git_oid blobOID = {};
  NSData *bytes = [content dataUsingEncoding:NSUTF8StringEncoding];
  XCTAssertEqual(git_blob_create_from_buffer(&blobOID, repository, bytes.bytes,
                                             bytes.length), 0);
  git_treebuilder *builder = nullptr;
  git_tree *parentTree = nullptr;
  git_commit *parent = nullptr;
  if (parentOID != nil) {
    git_oid oid = {};
    XCTAssertEqual(git_oid_fromstr(&oid, parentOID.UTF8String), 0);
    XCTAssertEqual(git_commit_lookup(&parent, repository, &oid), 0);
    XCTAssertEqual(git_commit_tree(&parentTree, parent), 0);
  }
  XCTAssertEqual(git_treebuilder_new(&builder, repository, parentTree), 0);
  XCTAssertEqual(git_treebuilder_insert(nullptr, builder, path.UTF8String, &blobOID,
                                        GIT_FILEMODE_BLOB), 0);
  git_oid treeOID = {};
  XCTAssertEqual(git_treebuilder_write(&treeOID, builder), 0);
  git_treebuilder_free(builder);
  if (parentTree != nullptr) git_tree_free(parentTree);
  git_tree *tree = nullptr;
  XCTAssertEqual(git_tree_lookup(&tree, repository, &treeOID), 0);
  git_signature *signature = nullptr;
  XCTAssertEqual(git_signature_new(&signature, "Rish Test", "test@rish.local",
                                   timestamp, 0), 0);
  const git_commit *parents[] = { parent };
  git_oid commitOID = {};
  XCTAssertEqual(git_commit_create(&commitOID, repository, "refs/heads/main",
                                   signature, signature, "UTF-8",
                                   path.UTF8String, tree,
                                   parent == nullptr ? 0 : 1,
                                   parent == nullptr ? nullptr : parents), 0);
  git_signature_free(signature);
  git_tree_free(tree);
  if (parent != nullptr) git_commit_free(parent);
  return GPSOID(&commitOID);
}

- (NSString *)referenceOID:(NSString *)name inRepository:(git_repository *)repository {
  git_oid oid = {};
  if (git_reference_name_to_id(&oid, repository, name.UTF8String) != 0) return nil;
  return GPSOID(&oid);
}

- (DSHGitPushRequest *)requestForRepository:(git_repository *)repository
                                    localOID:(NSString *)localOID {
  DSHGitPushRequest *request = [[DSHGitPushRequest alloc] init];
  request.repository = repository;
  request.remoteName = @"origin";
  request.fullReference = @"refs/heads/main";
  request.localOID = localOID;
  request.timeout = 20.0;
  return request;
}

/// Local worktree with commit A on main, plus a bare origin already holding A.
- (NSDictionary *)seededPair {
  git_repository *origin = [self initRepositoryNamed:@"origin.git" bare:YES];
  git_repository *local = [self initRepositoryNamed:@"local" bare:NO];
  NSString *baseOID = [self commitPath:@"README.md" content:@"base\n"
                          inRepository:local parent:nil timestamp:1];
  NSURL *originURL = [self.rootURL URLByAppendingPathComponent:@"origin.git"
                                                    isDirectory:YES];
  git_remote *remote = nullptr;
  XCTAssertEqual(git_remote_create(&remote, local, "origin",
                                   originURL.fileSystemRepresentation), 0);
  git_remote_free(remote);
  DSHGitPushRequest *seed = [self requestForRepository:local localOID:baseOID];
  seed.expectedRemoteOID = NSNull.null;
  DSHGitPushResult *seeded = DSHGitPushRun(seed);
  XCTAssertEqual(seeded.outcome, DSHGitPushOutcomeSuccess);
  XCTAssertEqualObjects(seeded.remoteOID, baseOID);
  XCTAssertTrue(seeded.verified);
  XCTAssertNil(seeded.advertisedOID);
  return @{ @"local" : [NSValue valueWithPointer:local],
            @"origin" : [NSValue valueWithPointer:origin],
            @"base" : baseOID };
}

// MARK: - Remote URL policy

- (void)testValidatedRemoteURLAcceptsHTTPSDNSAndPrivateLiteralHTTPOnly {
  NSArray<NSString *> *accepted = @[
    @"https://github.com/octocat/Hello-World.git",
    @"https://github.com:443/octocat/Hello-World.git",
    @"http://127.0.0.1:8418/target.git",
    @"http://192.168.50.70:8418/target.git",
    @"http://10.1.2.3/target.git",
    @"http://172.16.0.9:1/target.git",
    @"http://localhost:9000/target.git",
    @"http://[::1]:8418/target.git",
  ];
  for (NSString *candidate in accepted) {
    NSError *error = nil;
    XCTAssertNotNil(DSHGitValidatedRemoteURL(candidate, &error), @"%@", candidate);
    XCTAssertNil(error, @"%@", candidate);
  }
  NSArray<NSString *> *rejected = @[
    @"", @"github.com/x.git", @"ftp://github.com/x.git", @"file:///tmp/x.git",
    @"https://127.0.0.1/x.git", @"https://localhost/x.git",
    @"https://github.com:8443/x.git", @"https://user:pw@github.com/x.git",
    @"https://github.com/x.git?y=1", @"https://github.com/x.git#frag",
    @"https://github.com/../x.git", @"https://box.local/x.git",
    @"https://box.internal/x.git", @"https://github.com./x.git",
    @"http://example.com/x.git", @"http://8.8.8.8/x.git",
    @"http://172.32.0.1/x.git", @"http://10.0.0.1:0/x.git",
    @"http://10.0.0.1:70000/x.git", @"http://rish:tok@127.0.0.1/x.git",
    @" https://github.com/x.git", @"https://github.com/x.git\n",
    @"https://github.com/x\\y.git",
  ];
  for (NSString *candidate in rejected) {
    NSError *error = nil;
    XCTAssertNil(DSHGitValidatedRemoteURL(candidate, &error), @"%@", candidate);
    XCTAssertEqual(error.code, 3002, @"%@", candidate);
  }
  XCTAssertEqualObjects(DSHGitValidatedRemoteURL(@"HTTPS://GitHub.com/X.git", nil)
                            .absoluteString, @"https://github.com/X.git");
  XCTAssertTrue(DSHGitRemoteURLIsPlaintext(
      DSHGitValidatedRemoteURL(@"http://127.0.0.1:1/x.git", nil)));
  XCTAssertFalse(DSHGitRemoteURLIsPlaintext(
      DSHGitValidatedRemoteURL(@"https://github.com/x.git", nil)));
}

// MARK: - Keychain credential

- (void)testCredentialIsScopedExpiringAndNeverAmbient {
  NSString *host = @"127.0.0.1";
  NSError *error = nil;
  XCTAssertNil(DSHGitCredentialForScope(self.scopeId, host, &error));
  XCTAssertNil(error);
  XCTAssertFalse(DSHGitStoreCredentialForScope(self.scopeId, host, @"rish",
                                                @"secret-token-1234", 120, &error));
  XCTAssertEqual(error.code, 3012);
  error = nil;
  XCTAssertFalse(DSHGitStoreCredentialForScope(self.scopeId, host, @"ri sh",
                                                @"secret-token-1234",
                                                DSHGitCredentialExpiryOneHour, &error));
  XCTAssertFalse(DSHGitStoreCredentialForScope(self.scopeId, host, @"rish",
                                                @"short",
                                                DSHGitCredentialExpiryOneHour, &error));
  error = nil;
  NSTimeInterval before = floor(NSDate.date.timeIntervalSince1970);
  XCTAssertTrue(DSHGitStoreCredentialForScope(self.scopeId, host, @"rish",
                                               @"secret-token-1234",
                                               DSHGitCredentialExpiryOneHour, &error));
  XCTAssertNil(error);
  NSDictionary *stored = DSHGitCredentialForScope(self.scopeId, host, &error);
  XCTAssertEqualObjects(stored[@"username"], @"rish");
  XCTAssertEqualObjects(stored[@"token"], @"secret-token-1234");
  XCTAssertEqualObjects(stored[@"expiry_seconds"], @(DSHGitCredentialExpiryOneHour));
  double expiresAt = [stored[@"expires_at"] doubleValue];
  XCTAssertGreaterThanOrEqual(expiresAt, before + DSHGitCredentialExpiryOneHour);
  XCTAssertLessThanOrEqual(expiresAt, before + DSHGitCredentialExpiryOneHour + 5);
  // Another project or another host never sees this item.
  XCTAssertNil(DSHGitCredentialForScope(NSUUID.UUID.UUIDString.lowercaseString, host, nil));
  XCTAssertNil(DSHGitCredentialForScope(self.scopeId, @"github.com", nil));
  // Re-provisioning with a longer window replaces the item in place.
  XCTAssertTrue(DSHGitStoreCredentialForScope(self.scopeId, host, @"rish",
                                               @"secret-token-5678",
                                               DSHGitCredentialExpirySevenDays, nil));
  NSDictionary *replaced = DSHGitCredentialForScope(self.scopeId, host, nil);
  XCTAssertEqualObjects(replaced[@"token"], @"secret-token-5678");
  XCTAssertEqualObjects(replaced[@"expiry_seconds"], @(DSHGitCredentialExpirySevenDays));
  XCTAssertTrue(DSHGitDeleteCredentialForScope(self.scopeId, host, nil));
  XCTAssertNil(DSHGitCredentialForScope(self.scopeId, host, nil));
  XCTAssertTrue(DSHGitDeleteCredentialForScope(self.scopeId, host, nil));
}

- (void)testExpiredCredentialIsDeletedOnLookup {
  NSString *host = @"127.0.0.1";
  NSString *account = DSHGitCredentialAccountForScope(self.scopeId, host);
  NSData *payload = [NSJSONSerialization dataWithJSONObject:@{
    @"schema_version" : @2, @"username" : @"rish", @"token" : @"secret-token-1234",
    @"expires_at" : @(floor(NSDate.date.timeIntervalSince1970) - 10),
    @"expiry_seconds" : @(DSHGitCredentialExpiryOneHour),
  } options:0 error:nil];
  NSDictionary *item = @{
    (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
    (__bridge id)kSecAttrService : DSHGitPushCredentialService,
    (__bridge id)kSecAttrAccount : account,
    (__bridge id)kSecAttrSynchronizable : @NO,
    (__bridge id)kSecValueData : payload,
    (__bridge id)kSecAttrAccessible : (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
  };
  SecItemDelete((__bridge CFDictionaryRef)item);
  XCTAssertEqual(SecItemAdd((__bridge CFDictionaryRef)item, nil), errSecSuccess);
  NSError *error = nil;
  XCTAssertNil(DSHGitCredentialForScope(self.scopeId, host, &error));
  XCTAssertNil(error);
  NSDictionary *query = @{
    (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
    (__bridge id)kSecAttrService : DSHGitPushCredentialService,
    (__bridge id)kSecAttrAccount : account,
    (__bridge id)kSecAttrSynchronizable : @NO,
  };
  XCTAssertEqual(SecItemCopyMatching((__bridge CFDictionaryRef)query, nil),
                 errSecItemNotFound);
}

// MARK: - Receipt journal

- (void)testReceiptJournalIsAtomicBoundedAndValidated {
  int directory = open(self.rootURL.fileSystemRepresentation,
                       O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  XCTAssertGreaterThanOrEqual(directory, 0);
  NSString *projectId = NSUUID.UUID.UUIDString.lowercaseString;
  NSError *error = nil;
  XCTAssertEqualObjects(DSHGitPushLoadReceipts(directory, projectId, &error), @[]);
  XCTAssertNil(error);
  NSString *oid = [@"" stringByPaddingToLength:40 withString:@"a" startingAtIndex:0];
  XCTAssertFalse(DSHGitPushRecordReceipt(directory, projectId,
      DSHGitPushReceipt(@"127.0.0.1", @"main", @"short", oid, @"2026-09-03T00:00:00.000Z"),
      &error));
  XCTAssertEqual(error.code, 3021);
  for (NSUInteger index = 0; index < 27; index += 1) {
    NSString *branch = [NSString stringWithFormat:@"feature/%lu", (unsigned long)index];
    XCTAssertTrue(DSHGitPushRecordReceipt(directory, projectId,
        DSHGitPushReceipt(@"127.0.0.1", branch, oid, oid, @"2026-09-03T00:00:00.000Z"),
        nil));
  }
  NSArray<NSDictionary *> *receipts = DSHGitPushLoadReceipts(directory, projectId, &error);
  XCTAssertEqual(receipts.count, 25u);
  XCTAssertEqualObjects(receipts.firstObject[@"branch"], @"feature/2");
  XCTAssertEqualObjects(receipts.lastObject[@"branch"], @"feature/26");
  XCTAssertNil(DSHGitPushLoadReceipts(directory, @"other-project", &error));
  XCTAssertEqual(error.code, 3021);
  NSURL *journal = [self.rootURL URLByAppendingPathComponent:DSHGitPushReceiptFilename];
  XCTAssertTrue([[@"{not json" dataUsingEncoding:NSUTF8StringEncoding]
      writeToURL:journal atomically:YES]);
  error = nil;
  XCTAssertNil(DSHGitPushLoadReceipts(directory, projectId, &error));
  XCTAssertEqual(error.code, 3021);
  XCTAssertFalse(DSHGitPushRecordReceipt(directory, projectId,
      DSHGitPushReceipt(@"127.0.0.1", @"main", oid, oid, @"2026-09-03T00:00:00.000Z"),
      &error));
  XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:
      [journal.path stringByAppendingString:@".tmp"]]);
  close(directory);
}

// MARK: - Bounded runner over the local transport

- (void)testRunnerPushesFastForwardAndReadsBackRemoteOID {
  NSDictionary *pair = [self seededPair];
  git_repository *local = (git_repository *)[pair[@"local"] pointerValue];
  git_repository *origin = (git_repository *)[pair[@"origin"] pointerValue];
  NSString *next = [self commitPath:@"next.txt" content:@"next\n"
                       inRepository:local parent:pair[@"base"] timestamp:2];
  DSHGitPushRequest *request = [self requestForRepository:local localOID:next];
  request.expectedRemoteOID = pair[@"base"];
  DSHGitPushResult *result = DSHGitPushRun(request);
  XCTAssertEqual(result.outcome, DSHGitPushOutcomeSuccess);
  XCTAssertEqualObjects(result.advertisedOID, pair[@"base"]);
  XCTAssertEqualObjects(result.remoteOID, next);
  XCTAssertTrue(result.verified);
  XCTAssertEqualObjects([self referenceOID:@"refs/heads/main" inRepository:origin], next);
  git_repository_free(local);
  git_repository_free(origin);
}

- (void)testRunnerRejectsMovedRemoteAsConflictBeforeUploading {
  NSDictionary *pair = [self seededPair];
  git_repository *local = (git_repository *)[pair[@"local"] pointerValue];
  git_repository *origin = (git_repository *)[pair[@"origin"] pointerValue];
  NSString *next = [self commitPath:@"next.txt" content:@"next\n"
                       inRepository:local parent:pair[@"base"] timestamp:2];
  DSHGitPushRequest *request = [self requestForRepository:local localOID:next];
  request.expectedRemoteOID = NSNull.null;
  DSHGitPushResult *result = DSHGitPushRun(request);
  XCTAssertEqual(result.outcome, DSHGitPushOutcomeConflict);
  XCTAssertFalse(result.effectMayHaveOccurred);
  XCTAssertEqualObjects([self referenceOID:@"refs/heads/main" inRepository:origin],
                        pair[@"base"]);
  git_repository_free(local);
  git_repository_free(origin);
}

- (void)testRunnerReportsNonFastForwardWithoutRewritingEitherHistory {
  NSDictionary *pair = [self seededPair];
  git_repository *local = (git_repository *)[pair[@"local"] pointerValue];
  git_repository *origin = (git_repository *)[pair[@"origin"] pointerValue];
  // Competing commit lands on the bare origin directly (independent writer).
  NSString *competing = [self commitPath:@"COMPETING.txt" content:@"remote\n"
                            inRepository:origin parent:pair[@"base"] timestamp:3];
  NSString *local2 = [self commitPath:@"local.txt" content:@"local\n"
                         inRepository:local parent:pair[@"base"] timestamp:4];
  DSHGitPushRequest *request = [self requestForRepository:local localOID:local2];
  DSHGitPushResult *result = DSHGitPushRun(request);
  XCTAssertEqual(result.outcome, DSHGitPushOutcomeNonFastForward);
  XCTAssertFalse(result.effectMayHaveOccurred);
  XCTAssertEqualObjects(result.advertisedOID, competing);
  XCTAssertEqualObjects([self referenceOID:@"refs/heads/main" inRepository:origin],
                        competing);
  XCTAssertEqualObjects([self referenceOID:@"refs/heads/main" inRepository:local],
                        local2);
  git_repository_free(local);
  git_repository_free(origin);
}

- (void)testRunnerHonoursCancellationBeforeAnyBytesLeave {
  NSDictionary *pair = [self seededPair];
  git_repository *local = (git_repository *)[pair[@"local"] pointerValue];
  git_repository *origin = (git_repository *)[pair[@"origin"] pointerValue];
  NSString *next = [self commitPath:@"next.txt" content:@"next\n"
                       inRepository:local parent:pair[@"base"] timestamp:2];
  DSHGitPushRequest *request = [self requestForRepository:local localOID:next];
  request.cancelToken = [[DSHGitPushCancelToken alloc] init];
  [request.cancelToken cancel];
  __block DSHGitPushOutcome completed = DSHGitPushOutcomeFailed;
  XCTestExpectation *settled = [self expectationWithDescription:@"completion"];
  request.completion = ^(DSHGitPushOutcome outcome, __unused NSString *remoteOID) {
    completed = outcome;
    [settled fulfill];
  };
  DSHGitPushResult *result = DSHGitPushRun(request);
  XCTAssertEqual(result.outcome, DSHGitPushOutcomeCancelled);
  [self waitForExpectations:@[ settled ] timeout:10];
  XCTAssertEqual(completed, DSHGitPushOutcomeCancelled);
  XCTAssertEqualObjects([self referenceOID:@"refs/heads/main" inRepository:origin],
                        pair[@"base"]);
  git_repository_free(local);
  git_repository_free(origin);
}

- (void)testRunnerRejectsInvalidRequestsWithoutTouchingTheRemote {
  XCTAssertEqual(DSHGitPushRun(nil).outcome, DSHGitPushOutcomeFailed);
  NSDictionary *pair = [self seededPair];
  git_repository *local = (git_repository *)[pair[@"local"] pointerValue];
  git_repository *origin = (git_repository *)[pair[@"origin"] pointerValue];
  DSHGitPushRequest *request = [self requestForRepository:local localOID:pair[@"base"]];
  request.remoteURL = @"http://127.0.0.1:1/x.git";  // host missing -> invalid
  XCTAssertEqual(DSHGitPushRun(request).outcome, DSHGitPushOutcomeFailed);
  request.remoteURL = nil;
  request.fullReference = @"";
  XCTAssertEqual(DSHGitPushRun(request).outcome, DSHGitPushOutcomeFailed);
  git_repository_free(local);
  git_repository_free(origin);
}

@end
