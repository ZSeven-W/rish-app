#import <XCTest/XCTest.h>
#import "ShellAssistantModule.h"
#include <sys/stat.h>
#include <unistd.h>

@interface ShellAssistantStorageTests : XCTestCase
@property(nonatomic, strong) NSURL *root;
@end
@implementation ShellAssistantStorageTests
- (void)setUp {
  [super setUp];
  self.root = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:self.root withIntermediateDirectories:YES attributes:nil error:nil]);
}
- (void)tearDown {
  [NSFileManager.defaultManager removeItemAtURL:self.root error:nil];
  [super tearDown];
}
- (void)testPrivateDirectoryIsProtectedExcludedAndStable {
  NSURL *directory = [self.root URLByAppendingPathComponent:@"Assistant-v1" isDirectory:YES];
  ShellAssistantModule *module = [[ShellAssistantModule alloc] initWithDirectory:directory];
  __block NSDictionary *result;
  [module storageWithResolver:^(id value) { result = value; } rejecter:^(NSString *code, NSString *message, NSError *error) { XCTFail(@"%@", code); }];
  XCTAssertEqualObjects(result[@"schema_version"], @1);
  XCTAssertEqualObjects(result[@"platform"], @"ios");
  XCTAssertEqualObjects(result[@"directory"], directory.URLByResolvingSymlinksInPath.path);
  XCTAssertEqual(result.count, 3U);
  struct stat metadata = {};
  XCTAssertEqual(lstat(directory.fileSystemRepresentation, &metadata), 0);
  XCTAssertEqual(metadata.st_mode & 0777, 0700);
  NSNumber *excluded = nil;
  XCTAssertTrue([directory getResourceValue:&excluded forKey:NSURLIsExcludedFromBackupKey error:nil]);
  XCTAssertEqualObjects(excluded, @YES);
  [module storageWithResolver:^(id value) { XCTAssertEqualObjects(value, result); }
      rejecter:^(NSString *code, NSString *message, NSError *error) { XCTFail(@"%@", code); }];
  XCTAssertEqual([NSFileManager.defaultManager contentsOfDirectoryAtURL:directory includingPropertiesForKeys:nil options:0 error:nil].count, 0U);
}
- (void)testSymlinkAndFileRootsAreRejectedWithoutChangingTargets {
  NSURL *target = [self.root URLByAppendingPathComponent:@"target"];
  NSData *before = [@"unchanged" dataUsingEncoding:NSUTF8StringEncoding];
  XCTAssertTrue([before writeToURL:target atomically:YES]);
  NSURL *link = [self.root URLByAppendingPathComponent:@"Assistant-v1"];
  XCTAssertEqual(symlink(target.fileSystemRepresentation, link.fileSystemRepresentation), 0);
  for (NSURL *invalid in @[target, link]) {
    __block BOOL rejected = NO;
    ShellAssistantModule *module = [[ShellAssistantModule alloc] initWithDirectory:invalid];
    [module storageWithResolver:^(id value) { XCTFail(@"unsafe root returned"); }
        rejecter:^(NSString *code, NSString *message, NSError *error) { rejected = YES; }];
    XCTAssertTrue(rejected);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:target], before);
  }
}
@end
