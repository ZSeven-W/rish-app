#import <XCTest/XCTest.h>
#import "RuntimeEnvironmentStore.h"
#import "RuntimeEnvironmentDownload.h"
#import <CommonCrypto/CommonDigest.h>
#include <zlib.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

static NSString *const TestKernel = @"1111111111111111111111111111111111111111111111111111111111111111";
static NSString *const TestWorkspace = @"10000000-0000-4000-8000-000000000001";
static NSString *Hash(NSData *data) {
  unsigned char digest[32]; CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  NSMutableString *value = [NSMutableString string];
  for (NSUInteger n = 0; n < 32; n++) [value appendFormat:@"%02x", digest[n]];
  return value;
}
// A parser fixture, not an executable OS: the real language smoke test covers runnable ext4 images.
static NSData *Disk(void) {
  NSMutableData *disk = [NSMutableData dataWithLength:1024 * 1024];
  uint8_t *bytes = (uint8_t *)disk.mutableBytes;
  bytes[1029] = 4; // 1024 blocks at 1024 bytes.
  bytes[1080] = 0x53; bytes[1081] = 0xef;
  return disk;
}
static NSDictionary *Manifest(NSData *disk) {
  return @{@"schema_version":@1,@"environment_id":@"python-test-1",@"family":@"python",@"display_name":@"Python Test",
      @"version":@"1",@"architecture":@"x86_64",@"kernel_sha256":TestKernel,@"disk_sha256":Hash(disk),
      @"disk_bytes":@(disk.length),@"minimum_memory_mib":@256};
}
static NSData *Package(NSData *disk, NSDictionary *manifest) {
  NSData *json = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingSortedKeys error:nil];
  uint8_t prefix[12] = {'R','I','S','H','E','N','V','1', (uint8_t)(json.length >> 24),
      (uint8_t)(json.length >> 16), (uint8_t)(json.length >> 8), (uint8_t)json.length};
  NSMutableData *result = [NSMutableData dataWithBytes:prefix length:12]; [result appendData:json];
  z_stream stream = {};
  deflateInit2(&stream, 6, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY);
  stream.next_in = (Bytef *)disk.bytes; stream.avail_in = (uInt)disk.length;
  uint8_t buffer[65536]; int status;
  do {
    stream.next_out = buffer; stream.avail_out = sizeof(buffer);
    status = deflate(&stream, Z_FINISH);
    [result appendBytes:buffer length:sizeof(buffer) - stream.avail_out];
  } while (status == Z_OK);
  deflateEnd(&stream); return result;
}

@interface EnvironmentDownloadProtocol : NSURLProtocol
@end
@implementation EnvironmentDownloadProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return [request.URL.host isEqual:@"environment.test"]; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
  if ([self.request.URL.path isEqual:@"/wait"]) return;
  NSData *payload = [@"abc" dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *headers = [self.request.URL.path isEqual:@"/unknown"] ? @{} : @{@"Content-Length":@"3"};
  NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:headers];
  [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
  [self.client URLProtocol:self didLoadData:payload];
  [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end

@interface RuntimeEnvironmentStoreTests : XCTestCase
@property(nonatomic, strong) NSURL *temporary;
@end
@implementation RuntimeEnvironmentStoreTests
- (void)setUp {
  [super setUp];
  self.temporary = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:self.temporary withIntermediateDirectories:YES attributes:nil error:nil]);
}
- (void)tearDown {
  [NSFileManager.defaultManager removeItemAtURL:self.temporary error:nil]; [super tearDown];
}
- (NSURL *)writePackage:(NSData *)data {
  NSURL *url = [self.temporary URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".rishenv"]];
  XCTAssertTrue([data writeToURL:url atomically:YES]); return url;
}
- (DSHRuntimeEnvironmentStore *)store:(NSDictionary *)catalog {
  return [[DSHRuntimeEnvironmentStore alloc] initWithRootURL:[self.temporary URLByAppendingPathComponent:@"store"]
      catalog:catalog ?: @{} kernelSHA256:TestKernel];
}
- (NSDictionary *)importPackage:(NSURL *)url store:(DSHRuntimeEnvironmentStore *)store expectedError:(NSString *)code {
  XCTestExpectation *done = [self expectationWithDescription:@"native import"];
  __block NSDictionary *result;
  [store importPackageURL:url completion:^(NSDictionary *descriptor, NSError *error) {
    result = descriptor;
    if (code) { XCTAssertNil(descriptor); XCTAssertEqualObjects(error.userInfo[@"code"], code); }
    else { XCTAssertNotNil(descriptor); XCTAssertNil(error); }
    [done fulfill];
  }];
  [self waitForExpectations:@[done] timeout:10]; return result;
}
- (void)testManifestRejectsUnsafeIdsAndWrongKernelAndInvalidNumericTypes {
  NSDictionary *valid = Manifest(Disk()); XCTAssertTrue(DSHEnvironmentValidateManifest(valid, TestKernel));
  for (NSDictionary *patch in @[@{@"environment_id":@"../outside"},@{@"environment_id":@"python_test"},
      @{@"minimum_memory_mib":@YES},@{@"disk_bytes":@1025},@{@"architecture":@"arm64"},
      @{@"kernel_sha256":@"other"},@{@"display_name":@"bad\nlabel"},@{@"extra":@1}]) {
    NSMutableDictionary *value = [valid mutableCopy]; [value addEntriesFromDictionary:patch];
    XCTAssertFalse(DSHEnvironmentValidateManifest(value, TestKernel));
  }
  XCTAssertFalse(DSHEnvironmentValidHTTPSURL(@"http://example.com/test.rishenv"));
  XCTAssertFalse(DSHEnvironmentValidHTTPSURL(@"https://user:secret@example.com/test.rishenv"));
  XCTAssertFalse(DSHEnvironmentValidHTTPSURL(@"https://example.com/test.rishenv#fragment"));
  XCTAssertTrue(DSHEnvironmentValidHTTPSURL(@"https://example.com/test.rishenv"));
}
- (void)testStreamedImportPersistsSelectionAndLeaseCannotMutateOriginalOrBeRemoved {
  NSData *disk = Disk(); NSURL *package = [self writePackage:Package(disk, Manifest(disk))];
  DSHRuntimeEnvironmentStore *store = [self store:nil];
  NSDictionary *descriptor = [self importPackage:package store:store expectedError:nil];
  XCTAssertEqualObjects(descriptor[@"state"], @"installed");
  XCTAssertNil(descriptor[@"diskURL"]); XCTAssertNil(descriptor[@"kernel_sha256"]);
  NSError *error = nil;
  XCTAssertTrue([store selectEnvironmentId:@"python-test-1" workspaceId:TestWorkspace error:&error]);
  DSHRuntimeEnvironmentLease *lease = [store acquireLeaseForEnvironmentId:@"python-test-1" error:&error];
  XCTAssertNotNil(lease); XCTAssertNil(error);
  int fd = open(lease.diskURL.fileSystemRepresentation, O_WRONLY | O_NOFOLLOW);
  XCTAssertGreaterThanOrEqual(fd, 0); XCTAssertEqual(pwrite(fd, "changed", 7, 0), 7); close(fd);
  XCTAssertFalse([store removeEnvironmentId:@"python-test-1" error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_ENV_IN_USE");
  XCTAssertNil([store acquireLeaseForEnvironmentId:@"python-test-1" error:&error]);
  NSURL *leaseURL = lease.diskURL; [store releaseLease:lease]; [store releaseLease:lease];
  XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:leaseURL.path]);
  error = nil;
  DSHRuntimeEnvironmentLease *second = [store acquireLeaseForEnvironmentId:@"python-test-1" error:&error];
  XCTAssertNotNil(second); XCTAssertEqualObjects(DSHEnvironmentHashFile(second.diskURL, disk.length, nil), Hash(disk));
  [store releaseLease:second];
  DSHRuntimeEnvironmentStore *reopened = [self store:nil];
  NSDictionary *list = [reopened listEnvironmentsForWorkspaceId:TestWorkspace error:&error];
  XCTAssertEqualObjects(list[@"selected_environment_id"], @"python-test-1");
  XCTAssertEqual([list[@"environments"] count], 1);
  XCTAssertTrue([reopened removeEnvironmentId:@"python-test-1" error:&error]);
  XCTAssertEqualObjects([reopened listEnvironmentsForWorkspaceId:TestWorkspace error:&error][@"selected_environment_id"], NSNull.null);
}
- (void)testCatalogSelectionNeedsNoDownloadAndPartialDirectoriesAreIgnoredAfterRestart {
  NSData *disk = Disk(); NSDictionary *manifest = Manifest(disk); NSData *package = Package(disk, manifest);
  NSDictionary *record = @{@"manifest":manifest,@"url":@"https://environment.test/python.rishenv",
      @"package_sha256":Hash(package),@"package_bytes":@(package.length)};
  NSDictionary *catalog = @{@"schema_version":@1,@"environments":@[record]};
  DSHRuntimeEnvironmentStore *store = [self store:catalog]; NSError *error = nil;
  XCTAssertTrue([store selectEnvironmentId:@"python-test-1" workspaceId:TestWorkspace error:&error]);
  NSDictionary *list = [store listEnvironmentsForWorkspaceId:TestWorkspace error:&error];
  XCTAssertEqualObjects([list[@"environments"] firstObject][@"state"], @"not_installed");
  NSURL *partial = [self.temporary URLByAppendingPathComponent:@"store/staging/unfinished.rishenv"];
  XCTAssertTrue([@"partial" writeToURL:partial atomically:YES encoding:NSUTF8StringEncoding error:nil]);
  DSHRuntimeEnvironmentStore *reopened = [self store:catalog];
  XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:partial.path]);
  XCTAssertEqualObjects([reopened listEnvironmentsForWorkspaceId:TestWorkspace error:&error][@"selected_environment_id"], @"python-test-1");
  XCTAssertNil([reopened acquireLeaseForEnvironmentId:@"python-test-1" error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_ENV_NOT_INSTALLED");
}
- (void)testCorruptPackageTrailingStreamAndExpansionPastDeclaredLimitNeverInstall {
  NSData *disk = Disk(); NSDictionary *manifest = Manifest(disk); NSData *valid = Package(disk, manifest);
  NSMutableData *trailing = [valid mutableCopy]; [trailing appendBytes:"x" length:1];
  NSMutableData *concatenated = [valid mutableCopy]; [concatenated appendData:valid];
  NSMutableData *bigger = [disk mutableCopy]; [bigger increaseLengthBy:512];
  NSMutableDictionary *badDigest = [manifest mutableCopy]; badDigest[@"disk_sha256"] = TestKernel;
  NSMutableDictionary *wrongKernel = [manifest mutableCopy]; wrongKernel[@"kernel_sha256"] = Hash(valid);
  NSArray *inputs = @[trailing, concatenated, Package(bigger, manifest), Package(disk, badDigest), Package(disk, wrongKernel)];
  NSArray *codes = @[@"E_ENV_PACKAGE_INVALID",@"E_ENV_PACKAGE_INVALID",@"E_ENV_PACKAGE_INVALID",@"E_ENV_INTEGRITY",@"E_ENV_INCOMPATIBLE"];
  DSHRuntimeEnvironmentStore *store = [self store:nil];
  for (NSUInteger n = 0; n < inputs.count; n++) [self importPackage:[self writePackage:inputs[n]] store:store expectedError:codes[n]];
  XCTAssertEqual([[store listEnvironmentsForWorkspaceId:nil error:nil][@"environments"] count], 0);
  XCTAssertEqual([[NSFileManager.defaultManager contentsOfDirectoryAtPath:[self.temporary.path stringByAppendingPathComponent:@"store/staging"] error:nil] count], 0);
}
- (void)testOuterCatalogDigestAndSymlinkInputAreRejectedAndCancellationRemovesPartialDisk {
  NSData *disk = Disk(); NSDictionary *manifest = Manifest(disk); NSData *data = Package(disk, manifest);
  NSURL *package = [self writePackage:data]; NSURL *target = [self.temporary URLByAppendingPathComponent:@"disk.ext4"];
  NSDictionary *record = @{@"manifest":manifest,@"url":@"https://environment.test/test.rishenv",@"package_sha256":TestKernel,@"package_bytes":@(data.length)};
  NSError *error = nil;
  XCTAssertNil([DSHRuntimeEnvironmentPackage unpackURL:package diskURL:target kernelSHA256:TestKernel expectedRecord:record cancelled:^BOOL { return NO; } error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_ENV_INTEGRITY");
  NSURL *link = [self.temporary URLByAppendingPathComponent:@"link.rishenv"];
  XCTAssertEqual(symlink(package.fileSystemRepresentation, link.fileSystemRepresentation), 0);
  XCTAssertNil([DSHRuntimeEnvironmentPackage unpackURL:link diskURL:target kernelSHA256:TestKernel expectedRecord:nil cancelled:^BOOL { return NO; } error:&error]);
  XCTAssertNil([DSHRuntimeEnvironmentPackage unpackURL:package diskURL:target kernelSHA256:TestKernel expectedRecord:nil cancelled:^BOOL { return YES; } error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_ENV_CANCELLED");
  XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:target.path]);
}
- (void)testInstalledDiskTamperingIsRejectedBeforeRunLease {
  NSData *disk = Disk(); DSHRuntimeEnvironmentStore *store = [self store:nil];
  [self importPackage:[self writePackage:Package(disk, Manifest(disk))] store:store expectedError:nil];
  NSURL *original = [self.temporary URLByAppendingPathComponent:@"store/installed/python-test-1/disk.ext4"];
  XCTAssertEqual(chmod(original.fileSystemRepresentation, 0600), 0);
  int fd = open(original.fileSystemRepresentation, O_WRONLY); XCTAssertGreaterThanOrEqual(fd, 0);
  XCTAssertEqual(pwrite(fd, "x", 1, 0), 1); close(fd);
  NSError *error = nil; XCTAssertNil([store acquireLeaseForEnvironmentId:@"python-test-1" error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_ENV_INTEGRITY");
}
- (void)testRealPythonPackageImportLeaseAndRemoval {
  NSString *path = NSProcessInfo.processInfo.environment[@"RISH_ENVIRONMENT_TEST_PACKAGE"];
  NSURL *package = path.length ? [NSURL fileURLWithPath:path]
      : [[NSBundle bundleForClass:self.class] URLForResource:@"python-3-12-14-alpine3-21-amd64" withExtension:@"rishenv"];
  XCTSkipIf(package == nil, @"Provide the built real Python package as a native integration fixture.");
  NSString *kernel = @"1e6bf9027720c75c3ed0d79171f21b5791ee40ca9795d07c7c6e04dc5ea2ae90";
  DSHRuntimeEnvironmentStore *store = [[DSHRuntimeEnvironmentStore alloc]
      initWithRootURL:[self.temporary URLByAppendingPathComponent:@"real-store"] catalog:@{} kernelSHA256:kernel];
  NSDictionary *descriptor = [self importPackage:package store:store expectedError:nil];
  XCTAssertEqualObjects(descriptor[@"family"], @"python");
  NSError *error = nil;
  DSHRuntimeEnvironmentLease *lease = [store acquireLeaseForEnvironmentId:descriptor[@"environment_id"] error:&error];
  XCTAssertNotNil(lease); XCTAssertNil(error);
  XCTAssertEqualObjects(DSHEnvironmentHashFile(lease.diskURL, [descriptor[@"disk_bytes"] unsignedLongLongValue], nil), lease.manifest[@"disk_sha256"]);
  XCTAssertFalse([store removeEnvironmentId:descriptor[@"environment_id"] error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_ENV_IN_USE");
  NSURL *disk = lease.diskURL; [store releaseLease:lease];
  XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:disk.path]);
  XCTAssertTrue([store removeEnvironmentId:descriptor[@"environment_id"] error:&error]);
  XCTAssertEqual([[store listEnvironmentsForWorkspaceId:nil error:nil][@"environments"] count], 0);
}
- (DSHRuntimeEnvironmentDownload *)downloader {
  NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
  configuration.protocolClasses = @[EnvironmentDownloadProtocol.class];
  return [[DSHRuntimeEnvironmentDownload alloc] initWithConfiguration:configuration];
}
- (void)testDownloadStreamsOnlyExpectedBytesAndCleansCancellation {
  for (NSString *path in @[@"/ok",@"/unknown",@"/wait"]) {
    DSHRuntimeEnvironmentDownload *download = [self downloader];
    NSURL *destination = [self.temporary URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTestExpectation *done = [self expectationWithDescription:path];
    __block uint64_t downloaded = 0;
    [download startURL:[@"https://environment.test" stringByAppendingString:path] destination:destination expectedBytes:@3
        progress:^(uint64_t bytes, NSNumber *total) { downloaded = bytes; }
        completion:^(NSError *error) {
          if ([path isEqual:@"/wait"]) {
            XCTAssertEqualObjects(error.userInfo[@"code"], @"E_ENV_CANCELLED");
            XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:destination.path]);
          } else {
            XCTAssertNil(error); XCTAssertEqual(downloaded, 3);
            XCTAssertEqualObjects([NSData dataWithContentsOfURL:destination], [@"abc" dataUsingEncoding:NSUTF8StringEncoding]);
          }
          [done fulfill];
        }];
    if ([path isEqual:@"/wait"]) [download cancel];
    [self waitForExpectations:@[done] timeout:10];
  }
}
- (void)testDownloadRefusesAdvertisedSizeMismatchBeforeKeepingBody {
  DSHRuntimeEnvironmentDownload *download = [self downloader];
  NSURL *destination = [self.temporary URLByAppendingPathComponent:@"download.rishenv"];
  XCTestExpectation *done = [self expectationWithDescription:@"size mismatch"];
  [download startURL:@"https://environment.test/ok" destination:destination expectedBytes:@2
      progress:^(uint64_t bytes, NSNumber *total) { XCTFail(@"Rejected response cannot publish progress"); }
      completion:^(NSError *error) {
        XCTAssertEqualObjects(error.userInfo[@"code"], @"E_ENV_DOWNLOAD");
        XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:destination.path]); [done fulfill];
      }];
  [self waitForExpectations:@[done] timeout:10];
}
- (void)testDownloadBoundsUnknownLengthAndRefusesCredentialURLsBeforeOpeningFile {
  for (NSString *url in @[@"https://environment.test/unknown",@"https://secret@environment.test/ok"]) {
    DSHRuntimeEnvironmentDownload *download = [self downloader];
    NSURL *destination = [self.temporary URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTestExpectation *done = [self expectationWithDescription:@"refuse oversized or credential URL"];
    [download startURL:url destination:destination expectedBytes:@2
        progress:^(uint64_t bytes, NSNumber *total) { XCTFail(@"Invalid data cannot publish progress"); }
        completion:^(NSError *error) {
          XCTAssertEqualObjects(error.userInfo[@"code"], [url containsString:@"secret@"] ? @"E_ENV_BAD_ARGUMENTS" : @"E_ENV_PACKAGE_TOO_LARGE");
          XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:destination.path]); [done fulfill];
        }];
    [self waitForExpectations:@[done] timeout:10];
  }
}
- (void)testCancelImportLeavesNoSelectablePartialAndRetryWorks {
  NSData *disk = Disk(); NSURL *package = [self writePackage:Package(disk, Manifest(disk))];
  DSHRuntimeEnvironmentStore *store = [self store:nil];
  XCTestExpectation *done = [self expectationWithDescription:@"cancel import"];
  [store importPackageURL:package completion:^(NSDictionary *descriptor, NSError *error) {
    XCTAssertNil(descriptor); XCTAssertEqualObjects(error.userInfo[@"code"], @"E_ENV_CANCELLED"); [done fulfill];
  }];
  XCTAssertTrue([store cancelInstall]);
  [self waitForExpectations:@[done] timeout:10];
  XCTAssertFalse([store cancelInstall]);
  XCTAssertEqual([[store listEnvironmentsForWorkspaceId:nil error:nil][@"environments"] count], 0);
  [self importPackage:package store:store expectedError:nil];
}
- (void)testDownloadFailureNeverDeletesExistingDestination {
  NSURL *destination = [self.temporary URLByAppendingPathComponent:@"existing.rishenv"];
  NSData *existing = [@"existing" dataUsingEncoding:NSUTF8StringEncoding];
  XCTAssertTrue([existing writeToURL:destination atomically:YES]);
  DSHRuntimeEnvironmentDownload *download = [self downloader];
  XCTestExpectation *done = [self expectationWithDescription:@"existing file protected"];
  [download startURL:@"https://environment.test/ok" destination:destination expectedBytes:@3
      progress:^(uint64_t bytes, NSNumber *total) { XCTFail(@"Existing file cannot be opened for download"); }
      completion:^(NSError *error) {
        XCTAssertEqualObjects(error.userInfo[@"code"], @"E_ENV_STORAGE");
        XCTAssertEqualObjects([NSData dataWithContentsOfURL:destination], existing); [done fulfill];
      }];
  [self waitForExpectations:@[done] timeout:10];
}
@end
