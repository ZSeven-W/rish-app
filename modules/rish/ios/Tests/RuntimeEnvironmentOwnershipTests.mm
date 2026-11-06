#import <XCTest/XCTest.h>
#import "RuntimeEnvironmentStore.h"

@interface DSHRuntimeEnvironmentStore (OwnershipTestTransport)
- (NSString *)beginEnvironment:(NSString *)environmentId completion:(DSHEnvironmentCompletion)completion;
- (void)finishToken:(NSString *)token descriptor:(NSDictionary *)descriptor error:(NSError *)error
    directory:(NSURL *)directory completion:(DSHEnvironmentCompletion)completion;
@end

@interface RuntimeDownloadCancelSpy : NSObject
@property(nonatomic) NSUInteger cancellations;
- (void)cancel;
@end
@implementation RuntimeDownloadCancelSpy
- (void)cancel { self.cancellations++; }
@end

// Replace only the network transport. Tokens, idempotence and cancellation are
// the real Store implementation; tests never contact a remote package server.
@interface RuntimeOwnershipStore : DSHRuntimeEnvironmentStore
@property(nonatomic) NSUInteger downloadStarts;
@property(nonatomic, strong) RuntimeDownloadCancelSpy *spy;
@end
@implementation RuntimeOwnershipStore
- (NSString *)startDownload:(NSString *)url record:(NSDictionary *)record environmentId:(NSString *)environmentId
    completion:(DSHEnvironmentCompletion)completion {
  NSString *token = [self beginEnvironment:environmentId completion:completion];
  if (token) {
    self.downloadStarts++;
    self.spy = [RuntimeDownloadCancelSpy new];
    [self setValue:self.spy forKey:@"download"];
  }
  return token;
}
@end

static NSString *const OwnershipEnvironmentId = @"python-ownership-test";
static NSDictionary *OwnershipManifest(void) {
  return @{@"schema_version":@1, @"environment_id":OwnershipEnvironmentId,
    @"family":@"python", @"display_name":@"Python", @"version":@"test",
    @"architecture":@"x86_64", @"kernel_sha256":[@"1" stringByPaddingToLength:64 withString:@"1" startingAtIndex:0],
    @"disk_sha256":[@"2" stringByPaddingToLength:64 withString:@"2" startingAtIndex:0],
    @"disk_bytes":@(1024 * 1024), @"minimum_memory_mib":@256};
}

@interface RuntimeEnvironmentOwnershipTests : XCTestCase
@property(nonatomic, strong) NSURL *root;
@property(nonatomic, strong) RuntimeOwnershipStore *store;
@end
@implementation RuntimeEnvironmentOwnershipTests
- (void)setUp {
  [super setUp];
  self.root = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
  NSDictionary *manifest = OwnershipManifest();
  NSDictionary *catalog = @{@"schema_version":@1, @"environments":@[@{
      @"manifest":manifest, @"url":@"https://example.invalid/environment.rishenv",
      @"package_sha256":manifest[@"disk_sha256"], @"package_bytes":@1000}]};
  self.store = [[RuntimeOwnershipStore alloc] initWithRootURL:self.root
      catalog:catalog kernelSHA256:manifest[@"kernel_sha256"]];
}
- (void)tearDown {
  [self.store cancelInstall];
  [NSFileManager.defaultManager removeItemAtURL:self.root error:nil];
  self.store = nil; [super tearDown];
}
- (void)testOwnerCanCancelOnlyItsOwnDownload {
  NSString *token = [self.store beginInstallEnvironmentId:OwnershipEnvironmentId
      completion:^(NSDictionary *descriptor, NSError *error) { XCTFail(@"Pending transport must not finish."); }];
  XCTAssertNotNil(token);
  XCTAssertFalse([self.store cancelInstallToken:NSUUID.UUID.UUIDString]);
  XCTAssertFalse([self.store cancelInstallToken:(id)NSNull.null]);
  XCTAssertEqual(self.store.spy.cancellations, 0U);
  XCTAssertTrue([self.store cancelInstallToken:token]);
  XCTAssertEqual(self.store.spy.cancellations, 1U);
}
- (void)testRetiredAgentTokenCannotCancelTheNextManualDownload {
  NSString *first = [self.store beginInstallEnvironmentId:OwnershipEnvironmentId
      completion:^(NSDictionary *descriptor, NSError *error) {}];
  XCTAssertNotNil(first);
  NSURL *staging = [self.root URLByAppendingPathComponent:@"finished-test-staging"];
  [self.store finishToken:first descriptor:nil error:nil directory:staging
      completion:^(NSDictionary *descriptor, NSError *error) {}];
  [self.store installEnvironmentId:OwnershipEnvironmentId completion:^(NSDictionary *descriptor, NSError *error) {}];
  XCTAssertEqual(self.store.downloadStarts, 2U);
  XCTAssertFalse([self.store cancelInstallToken:first]);
  XCTAssertEqual(self.store.spy.cancellations, 0U);
  XCTAssertTrue([self.store cancelInstall]);
  XCTAssertEqual(self.store.spy.cancellations, 1U);
}
- (void)testCachedInstallDoesNotDownloadOrOwnAnUnrelatedTransfer {
  [self.store installEnvironmentId:OwnershipEnvironmentId completion:^(NSDictionary *descriptor, NSError *error) {}];
  NSString *manualToken = [self.store valueForKey:@"activeToken"];
  [[self.store valueForKey:@"installed"] setObject:OwnershipManifest() forKey:OwnershipEnvironmentId];
  __block BOOL completed = NO;
  NSString *token = [self.store beginInstallEnvironmentId:OwnershipEnvironmentId completion:^(NSDictionary *descriptor, NSError *error) {
    XCTAssertNil(error); XCTAssertEqualObjects(descriptor[@"environment_id"], OwnershipEnvironmentId);
    completed = YES;
  }];
  XCTAssertTrue(completed); XCTAssertNil(token);
  XCTAssertEqual(self.store.downloadStarts, 1U);
  XCTAssertEqualObjects([self.store valueForKey:@"activeToken"], manualToken);
  XCTAssertEqual(self.store.spy.cancellations, 0U);
}
- (void)testManifestLookupIsReadOnlyAndCustomInstallIsNotInTheCatalog {
  NSDictionary *manifest = [self.store catalogManifestForEnvironmentId:OwnershipEnvironmentId];
  XCTAssertEqualObjects(manifest, OwnershipManifest());
  XCTAssertFalse([manifest isKindOfClass:NSMutableDictionary.class]);
  XCTAssertNil([self.store catalogManifestForEnvironmentId:@"../bad"]);
  NSMutableDictionary *custom = [OwnershipManifest() mutableCopy];
  custom[@"environment_id"] = @"python-custom";
  [[self.store valueForKey:@"installed"] setObject:custom forKey:@"python-custom"];
  XCTAssertEqualObjects([self.store manifestForEnvironmentId:@"python-custom"], custom);
  XCTAssertNil([self.store catalogManifestForEnvironmentId:@"python-custom"]);
  __block BOOL failed = NO;
  XCTAssertNil([self.store beginInstallEnvironmentId:@"python-custom" completion:^(NSDictionary *descriptor, NSError *error) {
    XCTAssertNil(descriptor); XCTAssertEqualObjects(error.userInfo[@"code"], @"E_ENV_NOT_FOUND"); failed = YES;
  }]);
  XCTAssertTrue(failed); XCTAssertEqual(self.store.downloadStarts, 0U);
}
@end
