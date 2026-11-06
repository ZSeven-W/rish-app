#import <XCTest/XCTest.h>
@interface NativeRuntimeSmokeTests : XCTestCase
@end
@implementation NativeRuntimeSmokeTests
- (void)testTestBundleRunsInsideTheAppWorkspace {
  XCTAssertNotNil(NSFileManager.defaultManager);
  XCTAssertTrue(NSTemporaryDirectory().length > 0);
}
@end
