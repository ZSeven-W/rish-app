// Pins the container-anchor derivation in LocalProjectAccess: the walker
// must anchor at the app container root derived from NSHomeDirectory() instead
// of guessing path shape. The old scan looked for an "Application" component
// followed by "Application Support", which never matches the real device
// layout /private/var/mobile/Containers/Data/Application/<UUID>/... and made
// the walker fall back to opening /private/var, which the device sandbox
// refuses with EPERM.

#import <XCTest/XCTest.h>

#import "DSHTestHost.h"

#import "../../../../modules/rish/ios/Sources/LocalProjectAccess.h"
#import "../../../../modules/rish/ios/Sources/LocalProjectAccessInternals.h"

@interface ContainerAnchorTests : XCTestCase
@end

@implementation ContainerAnchorTests

// Confirmed device layout (task-confirmed defect report):
//   /private/var/mobile/Containers/Data/Application/<UUID>/...
static NSString *const DSHContainerAnchorDeviceUUID =
    @"11111111-1111-4111-8111-111111111111";
static NSString *const DSHContainerAnchorForgedUUID =
    @"22222222-2222-4222-8222-222222222222";
static NSString *const DSHContainerAnchorDeviceRoot =
    @"/private/var/mobile/Containers/Data/Application/"
    @"11111111-1111-4111-8111-111111111111";

static BOOL DSHContainerAnchorIsUUIDComponent(NSString *component) {
  return component.length == 36 &&
      [[NSUUID alloc] initWithUUIDString:component] != nil;
}

// Asserts the literal component sequence of the device layout so the
// implementation is built from verified sequences, not memory.
- (void)testDeviceLayoutComponentSequenceMatchesConfirmedShape {
  NSString *target = [DSHContainerAnchorDeviceRoot
      stringByAppendingString:@"/Library/Application Support/workspace/projects"];
  NSArray<NSString *> *expected = @[
    @"/", @"private", @"var", @"mobile", @"Containers", @"Data",
    @"Application", DSHContainerAnchorDeviceUUID, @"Library",
    @"Application Support", @"workspace", @"projects"
  ];
  XCTAssertEqualObjects(target.pathComponents, expected);
}

// Probes the live environment so the simulator anchor is built from the real
// component sequence, not from memory:
//   simulator: <...>/CoreSimulator/Devices/<device-uuid>/data/
//              Containers/Data/Application/<app-uuid>/...
- (void)testSimulatorEnvironmentLayoutMatchesExpectedComponentSequence {
  if (DSHTestHostIsDevice()) {
    XCTSkip(@"Simulator-only environment probe.");
  }
  NSString *home = NSHomeDirectory();
  NSArray<NSString *> *components = home.pathComponents;
  XCTAssertGreaterThanOrEqual(components.count, (NSUInteger)8,
      @"unexpected home layout: %@", components);
  if (components.count < 8) return;
  NSUInteger last = components.count;
  XCTAssertEqualObjects(components[last - 4], @"Containers",
      @"home components: %@", components);
  XCTAssertEqualObjects(components[last - 3], @"Data",
      @"home components: %@", components);
  XCTAssertEqualObjects(components[last - 2], @"Application",
      @"home components: %@", components);
  XCTAssertTrue(DSHContainerAnchorIsUUIDComponent(components[last - 1]),
      @"home tail is not a UUID: %@", components[last - 1]);
  NSUInteger devicesIndex = [components indexOfObject:@"Devices"];
  XCTAssertNotEqual(devicesIndex, NSNotFound,
      @"no CoreSimulator Devices segment in %@", components);
  if (devicesIndex == NSNotFound) return;
  XCTAssertLessThan(devicesIndex + 2, components.count,
      @"home components: %@", components);
  XCTAssertTrue(DSHContainerAnchorIsUUIDComponent(components[devicesIndex + 1]),
      @"device UUID segment: %@", components);
  XCTAssertEqualObjects(components[devicesIndex + 2], @"data",
      @"home components: %@", components);
  // Every path the anchored walker is asked to open must live inside the app
  // container; the fix refuses anything else.
  NSString *temporary = NSTemporaryDirectory();
  XCTAssertTrue([temporary hasPrefix:[home stringByAppendingString:@"/"]],
      @"NSTemporaryDirectory %@ outside home %@", temporary, home);
  NSURL *support = [[NSFileManager defaultManager]
      URLForDirectory:NSApplicationSupportDirectory
             inDomain:NSUserDomainMask
    appropriateForURL:nil
               create:NO
                error:nil];
  XCTAssertNotNil(support);
  XCTAssertTrue([support.path hasPrefix:[home stringByAppendingString:@"/"]],
      @"Application Support %@ outside home %@", support.path, home);
}

// A device-shaped target inside its own container anchors at the container
// root component (the UUID), leaving Library/... to the strict walk.
- (void)testDeviceShapePathAnchorsAtContainerRoot {
  NSString *target = [DSHContainerAnchorDeviceRoot
      stringByAppendingString:@"/Library/Application Support/workspace/projects"];
  NSUInteger segments =
      DSHContainerAnchorSegmentCountForPaths(target, DSHContainerAnchorDeviceRoot);
  XCTAssertEqual(segments, (NSUInteger)7);
  XCTAssertEqualObjects(target.pathComponents[segments],
      DSHContainerAnchorDeviceUUID);
}

// The exact container root is a valid target (the bootstrap opens
// NSHomeDirectory() itself).
- (void)testContainerRootItselfIsAnAcceptedTarget {
  NSUInteger segments = DSHContainerAnchorSegmentCountForPaths(
      DSHContainerAnchorDeviceRoot, DSHContainerAnchorDeviceRoot);
  XCTAssertEqual(segments, (NSUInteger)7);
}

// The simulator layout's innermost app container wins over the
// CoreSimulator device UUID.
- (void)testSimulatorShapePathAnchorsAtAppContainerRoot {
  NSString *deviceUUID = @"DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD";
  NSString *appUUID = @"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA";
  NSString *root = [NSHomeDirectory() stringByAppendingPathComponent:
      [NSString stringWithFormat:
          @"Library/Developer/CoreSimulator/Devices/%@/data/"
          @"Containers/Data/Application/%@",
          deviceUUID, appUUID]];
  NSString *target =
      [root stringByAppendingString:@"/Library/Application Support"];
  // The expected index is derived from the root, not written down: it is the
  // last component of the container root, and NSHomeDirectory() sits at a
  // different depth on different machines. The literal 12 this used to assert
  // came from a shallower simulator home and failed everywhere else, which is
  // what the anchor is supposed to make unnecessary.
  NSUInteger expected = root.pathComponents.count - 1;
  NSUInteger segments = DSHContainerAnchorSegmentCountForPaths(target, root);
  XCTAssertEqual(segments, expected);
  XCTAssertEqualObjects(target.pathComponents[segments], appUUID);
  // The innermost app container wins: the CoreSimulator device UUID is
  // further up the same path and must not be chosen.
  XCTAssertNotEqualObjects(target.pathComponents[segments], deviceUUID);
  XCTAssertEqual(DSHContainerRootScanSegmentCount(target), expected);
}

// Forged and malformed container shapes must be refused. This includes the
// shape the old scanner matched ("Application" followed by "Application
// Support"), cross-container UUIDs, traversal, and non-container roots.
- (void)testForgedAndMalformedContainerShapesAreRejected {
  NSString *target = [DSHContainerAnchorDeviceRoot
      stringByAppendingString:@"/Library/Application Support/workspace/projects"];
  XCTAssertEqual(DSHContainerAnchorSegmentCountForPaths(target,
      DSHContainerAnchorDeviceRoot), (NSUInteger)7);

  // A different container UUID is not the derived root: refused.
  NSString *otherRoot =
      @"/private/var/mobile/Containers/Data/Application/"
      @"22222222-2222-4222-8222-222222222222";
  NSString *otherTarget = [otherRoot
      stringByAppendingString:@"/Library/Application Support"];
  XCTAssertEqual(DSHContainerAnchorSegmentCountForPaths(otherTarget,
      DSHContainerAnchorDeviceRoot), NSNotFound);

  // The shape the old broken scanner matched: Application followed by
  // "Application Support" with no UUID at the container boundary.
  NSString *oldShape =
      @"/private/var/mobile/Containers/Data/Application/Application Support/"
      @"workspace/projects";
  XCTAssertEqual(DSHContainerAnchorSegmentCountForPaths(
      oldShape, DSHContainerAnchorDeviceRoot), NSNotFound);
  XCTAssertEqual(DSHContainerRootScanSegmentCount(oldShape), NSNotFound);

  // Path traversal inside the container prefix is refused up front.
  NSString *traversal = [DSHContainerAnchorDeviceRoot
      stringByAppendingString:@"/../../../../etc/passwd"];
  XCTAssertEqual(DSHContainerAnchorSegmentCountForPaths(
      traversal, DSHContainerAnchorDeviceRoot), NSNotFound);

  // A container root that is not the container boundary is invalid.
  NSString *deeperRoot = [DSHContainerAnchorDeviceRoot
      stringByAppendingString:@"/Library"];
  XCTAssertEqual(DSHContainerAnchorSegmentCountForPaths(
      DSHContainerAnchorDeviceRoot, deeperRoot), NSNotFound);

  // Malformed shapes for the scan fallback.
  XCTAssertEqual(DSHContainerRootScanSegmentCount(
      @"/private/var/mobile/Containers/Data/Application/not-a-uuid/Library"),
      NSNotFound);
  XCTAssertEqual(DSHContainerRootScanSegmentCount(
      @"/private/var/mobile/Containers/Application/"
      @"11111111-1111-4111-8111-111111111111"),
      NSNotFound);
  XCTAssertEqual(DSHContainerRootScanSegmentCount(@"/private/var"), NSNotFound);
  XCTAssertEqual(DSHContainerRootScanSegmentCount(@"/"), NSNotFound);
  XCTAssertEqual(DSHContainerRootScanSegmentCount(@""), NSNotFound);

  // Nil / non-string inputs fail closed.
  XCTAssertEqual(DSHContainerAnchorSegmentCountForPaths(nil,
      DSHContainerAnchorDeviceRoot), NSNotFound);
  XCTAssertEqual(DSHContainerAnchorSegmentCountForPaths(
      DSHContainerAnchorDeviceRoot, nil), NSNotFound);
}

// Red for the defect: a root outside the app container must be refused even
// when the host filesystem happens to allow opening it (as the simulator
// does). The broken walker happily anchored at /private/var or /Users.
- (void)testRootOutsideAppContainerIsRejected {
  if (DSHTestHostIsDevice()) {
    XCTSkip(@"Real-device test hosts have a stricter sandbox than the main "
        @"app; cross-container refusal is exercised on the simulator.");
  }
  NSURL *forged = [NSURL fileURLWithPath:@"/Users" isDirectory:YES];
  DSHLocalProjectAccess *access =
      [[DSHLocalProjectAccess alloc] initWithProjectsRootURL:forged];
  NSError *error = nil;
  DSHLocalProjectsRootLease *lease =
      [access leaseProjectsRootCreatingIfNeeded:NO error:&error];
  XCTAssertNil(lease, @"root outside the app container must be refused");
  XCTAssertNotNil(error);
  if (error != nil) {
    XCTAssertEqual(error.code, DSHLocalProjectAccessErrorUnsafeStorage);
  }
}

// Cross-container roots must also be refused when creation is requested; the
// anchored walker rejects before any bootstrap runs.
- (void)testRootOutsideAppContainerIsRejectedWhenCreating {
  if (DSHTestHostIsDevice()) {
    XCTSkip(@"Real-device test hosts have a stricter sandbox than the main "
        @"app; cross-container refusal is exercised on the simulator.");
  }
  NSURL *forged = [NSURL fileURLWithPath:@"/Users" isDirectory:YES];
  DSHLocalProjectAccess *access =
      [[DSHLocalProjectAccess alloc] initWithProjectsRootURL:forged];
  NSError *error = nil;
  DSHLocalProjectsRootLease *lease =
      [access leaseProjectsRootCreatingIfNeeded:YES error:&error];
  XCTAssertNil(lease, @"root outside the app container must be refused");
  XCTAssertNotNil(error);
  if (error != nil) {
    XCTAssertEqual(error.code, DSHLocalProjectAccessErrorUnsafeStorage);
  }
}

// Control: injected roots under NSTemporaryDirectory() (inside the app
// container) must keep working through the container-anchored walker.
- (void)testRootInsideAppContainerStillOpens {
  if (DSHTestHostIsDevice()) {
    XCTSkip(@"Real-device test hosts have a stricter sandbox than the main "
        @"app; container-inside behavior is exercised on the simulator.");
  }
  NSString *rootPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
      [NSString stringWithFormat:@"dsh-anchor-%@",
          NSUUID.UUID.UUIDString.lowercaseString]];
  XCTAssertTrue([[NSFileManager defaultManager]
      createDirectoryAtPath:rootPath
        withIntermediateDirectories:YES
                         attributes:@{NSFilePosixPermissions : @0700}
                              error:nil]);
  DSHLocalProjectAccess *access = [[DSHLocalProjectAccess alloc]
      initWithProjectsRootURL:[NSURL fileURLWithPath:rootPath isDirectory:YES]];
  NSError *error = nil;
  DSHLocalProjectsRootLease *lease =
      [access leaseProjectsRootCreatingIfNeeded:NO error:&error];
  XCTAssertNotNil(lease, @"container-inside root failed: %@",
      error.localizedDescription);
}

// Traversal components inside the container-relative tail must be refused:
// the same directory addressed through a ".." hop is not the canonical root.
- (void)testTraversalComponentsInsideContainerTailAreRejected {
  if (DSHTestHostIsDevice()) {
    XCTSkip(@"Real-device test hosts have a stricter sandbox than the main "
        @"app; traversal refusal is exercised on the simulator.");
  }
  NSString *base = [NSTemporaryDirectory() stringByAppendingPathComponent:
      [NSString stringWithFormat:@"dsh-anchor-traversal-%@",
          NSUUID.UUID.UUIDString.lowercaseString]];
  NSString *realRoot = [base stringByAppendingPathComponent:@"projects"];
  XCTAssertTrue([[NSFileManager defaultManager]
      createDirectoryAtPath:realRoot
        withIntermediateDirectories:YES
                         attributes:@{NSFilePosixPermissions : @0700}
                              error:nil]);
  NSString *traversalRoot =
      [base stringByAppendingPathComponent:@"sub/../projects"];
  DSHLocalProjectAccess *access = [[DSHLocalProjectAccess alloc]
      initWithProjectsRootURL:
          [NSURL fileURLWithPath:traversalRoot isDirectory:YES]];
  NSError *error = nil;
  DSHLocalProjectsRootLease *lease =
      [access leaseProjectsRootCreatingIfNeeded:NO error:&error];
  XCTAssertNil(lease, @"traversal-shaped root must be refused");
  XCTAssertNotNil(error);
  if (error != nil) {
    XCTAssertEqual(error.code, DSHLocalProjectAccessErrorUnsafeStorage);
  }
}

@end
