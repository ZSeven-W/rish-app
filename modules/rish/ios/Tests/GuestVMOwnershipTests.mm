#import <XCTest/XCTest.h>
#import "DSHGuestRuntimeState.h"
#import "LocalGuestModule.h"
#import "RuntimeProgramServiceVM.h"
#import "RuntimeWorkspaceSnapshot.h"
#import "ClaudeOfficialSession.h"

@interface DSHOwnerTestBundle : NSBundle
@property(nonatomic, copy) dispatch_block_t onLookup;
@property(nonatomic) BOOL returnMissing;
@end
@implementation DSHOwnerTestBundle
- (NSURL *)URLForResource:(NSString *)name withExtension:(NSString *)extension {
  (void)name; (void)extension;
  if (self.onLookup) self.onLookup();
  return self.returnMissing ? nil : [NSURL fileURLWithPath:@"/native-only/test-guest"];
}
@end

@interface DSHOwnerTestGuest : LocalGuestModule
@property(nonatomic, strong) dispatch_semaphore_t entered;
@property(nonatomic, strong) dispatch_semaphore_t unblock;
@property(nonatomic) BOOL failBoot;
@property(nonatomic) BOOL throwBoot;
@property(nonatomic) NSUInteger frees;
@end
@implementation DSHOwnerTestGuest
- (instancetype)init {
  self = [super initWithBundle:[[DSHOwnerTestBundle alloc] init]];
  if (self) { _entered = dispatch_semaphore_create(0); _unblock = dispatch_semaphore_create(0); }
  return self;
}
- (NSString *)bootAssetErrorCode { return nil; }
- (void *)bootSessionData:(NSData *)data {
  (void)data;
  dispatch_semaphore_signal(self.entered);
  dispatch_semaphore_wait(self.unblock, DISPATCH_TIME_FOREVER);
  if (self.throwBoot) [NSException raise:@"private" format:@"private native error"];
  return self.failBoot ? NULL : (__bridge void *)self;
}
- (void)freeSessionHandle:(void *)handle { (void)handle; self.frees++; }
@end

@interface DSHClaudeOfficialSession (DSHOwnerTests)
- (BOOL)ensureGuestMountedWithError:(NSString **)error;
- (void)freeGuest;
@end
@interface DSHOwnerTestClaude : DSHClaudeOfficialSession
@end
@implementation DSHOwnerTestClaude
- (BOOL)runtimeAvailableWithReason:(NSString **)reason { (void)reason; return YES; }
@end

@interface GuestVMOwnershipTests : XCTestCase
@end
@implementation GuestVMOwnershipTests
- (void)testOnlyOneConcurrentReservationWinsAndWrongOwnerCannotRelease {
  DSHGuestRuntimeState *state = [[DSHGuestRuntimeState alloc] init];
  NSMutableArray<DSHGuestVMOwner *> *winners = [NSMutableArray array];
  dispatch_apply(32, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t index) {
    (void)index; DSHGuestVMOwner *owner = [state acquireGuestOwner];
    if (owner) @synchronized (winners) { [winners addObject:owner]; }
  });
  XCTAssertEqual(winners.count, 1U);
  DSHGuestVMOwner *first = winners.firstObject;
  XCTAssertFalse(state.guestRuntimeMounted);
  [state setGuestRuntimeMounted:YES];
  XCTAssertFalse(state.guestRuntimeMounted);
  XCTAssertTrue([state setGuestRuntimeMounted:YES owner:first]);
  XCTAssertTrue([state releaseGuestOwner:first]);
  DSHGuestVMOwner *next = [state acquireGuestOwner];
  XCTAssertNotNil(next); XCTAssertFalse([state releaseGuestOwner:first]);
  XCTAssertFalse([state setGuestRuntimeMounted:YES owner:first]);
  XCTAssertNil([state acquireGuestOwner]);
  XCTAssertTrue([state releaseGuestOwner:next]);
}
- (void)testPreviewBootBlocksProgramsUntilCancelledBootActuallySettles {
  DSHOwnerTestGuest *guest = [[DSHOwnerTestGuest alloc] init];
  XCTestExpectation *boot = [self expectationWithDescription:@"cancelled preview boot"];
  [guest bootGuestRequest:@{@"schema_version":@1, @"memory_mib":@256} resolve:^(id value) {
    (void)value; XCTFail(@"Cancelled boot must not commit"); [boot fulfill];
  } reject:^(NSString *code, NSString *message, NSError *error) {
    (void)message; (void)error; XCTAssertEqualObjects(code, DSHGuestErrorBootCancelled); [boot fulfill];
  }];
  XCTAssertEqual(dispatch_semaphore_wait(guest.entered, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)), 0L);
  DSHRuntimeProgramVM *program = [[DSHRuntimeProgramVM alloc] initWithBundle:NSBundle.mainBundle];
  NSError *error = nil;
  XCTAssertNil([program executeLease:(id)nil snapshot:(id)nil entryPath:@"main.py" args:@[]
      started:^{} output:^(NSString *channel, NSData *data) { (void)channel; (void)data; } error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_PROGRAM_BUSY");
  XCTestExpectation *stop = [self expectationWithDescription:@"stop requested"];
  [guest shutdownGuestResolve:^(id result) {
    XCTAssertEqualObjects(result[@"status"], @"shutdown_scheduled"); [stop fulfill];
  } reject:^(NSString *code, NSString *message, NSError *failure) {
    (void)code; (void)message; (void)failure; XCTFail(@"Stop failed"); [stop fulfill];
  }];
  [self waitForExpectations:@[stop] timeout:3];
  XCTAssertNil([DSHGuestRuntimeState.sharedState acquireGuestOwner]);
  dispatch_semaphore_signal(guest.unblock);
  [self waitForExpectations:@[boot] timeout:3];
  XCTAssertEqual(guest.frees, 1U);
  DSHGuestVMOwner *next = [DSHGuestRuntimeState.sharedState acquireGuestOwner];
  XCTAssertNotNil(next); [DSHGuestRuntimeState.sharedState releaseGuestOwner:next];
}
- (void)testProgramReservationBlocksPreviewAndFailureReleasesForRetry {
  DSHOwnerTestBundle *bundle = [[DSHOwnerTestBundle alloc] init]; bundle.returnMissing = YES;
  dispatch_semaphore_t entered = dispatch_semaphore_create(0), unblock = dispatch_semaphore_create(0);
  bundle.onLookup = ^{ dispatch_semaphore_signal(entered); dispatch_semaphore_wait(unblock, DISPATCH_TIME_FOREVER); };
  DSHRuntimeProgramVM *program = [[DSHRuntimeProgramVM alloc] initWithBundle:bundle];
  XCTestExpectation *done = [self expectationWithDescription:@"program asset failure"];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSError *error = nil;
    XCTAssertNil([program executeLease:(id)nil snapshot:(id)nil entryPath:@"main.py" args:@[]
        started:^{} output:^(NSString *channel, NSData *data) { (void)channel; (void)data; } error:&error]);
    XCTAssertEqualObjects(error.userInfo[@"code"], @"E_PROGRAM_ASSETS_MISSING"); [done fulfill];
  });
  XCTAssertEqual(dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)), 0L);
  LocalGuestModule *guest = [[LocalGuestModule alloc] initWithBundle:nil];
  XCTestExpectation *busy = [self expectationWithDescription:@"preview is busy"];
  [guest bootGuestRequest:@{@"schema_version":@1, @"memory_mib":@256} resolve:^(id result) {
    (void)result; XCTFail(@"Second VM must not boot"); [busy fulfill];
  } reject:^(NSString *code, NSString *message, NSError *error) {
    (void)message; (void)error; XCTAssertEqualObjects(code, @"E_GUEST_BUSY"); [busy fulfill];
  }];
  [self waitForExpectations:@[busy] timeout:3];
  dispatch_semaphore_signal(unblock); dispatch_semaphore_signal(unblock);
  [self waitForExpectations:@[done] timeout:3];
  XCTestExpectation *retry = [self expectationWithDescription:@"preview may retry"];
  [guest bootGuestRequest:@{@"schema_version":@1, @"memory_mib":@256} resolve:^(id result) {
    (void)result; XCTFail(@"Fixture has no assets"); [retry fulfill];
  } reject:^(NSString *code, NSString *message, NSError *error) {
    (void)message; (void)error; XCTAssertEqualObjects(code, DSHGuestErrorAssetsMissing); [retry fulfill];
  }];
  [self waitForExpectations:@[retry] timeout:3];
  DSHGuestVMOwner *next = [DSHGuestRuntimeState.sharedState acquireGuestOwner];
  XCTAssertNotNil(next); [DSHGuestRuntimeState.sharedState releaseGuestOwner:next];
}
- (void)testPreviewFailureAndExceptionBothReleaseOwner {
  for (NSNumber *throws in @[@NO, @YES]) {
    DSHOwnerTestGuest *guest = [[DSHOwnerTestGuest alloc] init];
    guest.failBoot = YES; guest.throwBoot = throws.boolValue;
    dispatch_semaphore_signal(guest.unblock);
    XCTestExpectation *done = [self expectationWithDescription:@"preview boot failure"];
    [guest bootGuestRequest:@{@"schema_version":@1, @"memory_mib":@256} resolve:^(id result) {
      (void)result; XCTFail(@"Fixture fails boot"); [done fulfill];
    } reject:^(NSString *code, NSString *message, NSError *error) {
      (void)message; (void)error; XCTAssertEqualObjects(code, DSHGuestErrorBootFailed); [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:3];
    DSHGuestVMOwner *next = [DSHGuestRuntimeState.sharedState acquireGuestOwner];
    XCTAssertNotNil(next); [DSHGuestRuntimeState.sharedState releaseGuestOwner:next];
  }
}
- (void)testLivePreviewKeepsReservationUntilItsHandleIsFreed {
  DSHOwnerTestGuest *guest = [[DSHOwnerTestGuest alloc] init];
  dispatch_semaphore_signal(guest.unblock);
  XCTestExpectation *boot = [self expectationWithDescription:@"live preview"];
  [guest bootGuestRequest:@{@"schema_version":@1, @"memory_mib":@256} resolve:^(id result) {
    XCTAssertEqualObjects(result[@"status"], @"booted"); [boot fulfill];
  } reject:^(NSString *code, NSString *message, NSError *error) {
    (void)code; (void)message; (void)error; XCTFail(@"Fixture boot failed"); [boot fulfill];
  }];
  [self waitForExpectations:@[boot] timeout:3];
  XCTAssertTrue(DSHGuestRuntimeState.sharedState.guestRuntimeMounted);
  [DSHGuestRuntimeState.sharedState setGuestRuntimeMounted:NO];
  XCTAssertTrue(DSHGuestRuntimeState.sharedState.guestRuntimeMounted);
  XCTAssertNil([DSHGuestRuntimeState.sharedState acquireGuestOwner]);
  XCTestExpectation *stop = [self expectationWithDescription:@"live preview freed"];
  [guest shutdownGuestResolve:^(id result) {
    XCTAssertEqualObjects(result[@"status"], @"shutdown"); [stop fulfill];
  } reject:^(NSString *code, NSString *message, NSError *error) {
    (void)code; (void)message; (void)error; XCTFail(@"Fixture shutdown failed"); [stop fulfill];
  }];
  [self waitForExpectations:@[stop] timeout:3];
  XCTAssertEqual(guest.frees, 1U); XCTAssertFalse(DSHGuestRuntimeState.sharedState.guestRuntimeMounted);
  DSHGuestVMOwner *next = [DSHGuestRuntimeState.sharedState acquireGuestOwner];
  XCTAssertNotNil(next); [DSHGuestRuntimeState.sharedState releaseGuestOwner:next];
}
- (void)testClaudeBootUsesSameOwnerAndReleasesFailedReservation {
  NSURL *directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
  DSHOwnerTestClaude *claude = [[DSHOwnerTestClaude alloc] initWithKernelURL:directory
      initrdURL:directory storageDirectory:directory version:@"test"];
  __block NSUInteger boots = 0;
  claude.guestBootOverride = ^BOOL(NSDictionary *request) { (void)request; boots++; return NO; };
  DSHGuestVMOwner *other = [DSHGuestRuntimeState.sharedState acquireGuestOwner];
  XCTAssertNotNil(other);
  NSString *error = nil;
  XCTAssertFalse([claude ensureGuestMountedWithError:&error]);
  XCTAssertEqualObjects(error, @"E_GUEST_BUSY"); XCTAssertEqual(boots, 0U);
  [DSHGuestRuntimeState.sharedState releaseGuestOwner:other];
  XCTAssertFalse([claude ensureGuestMountedWithError:&error]);
  XCTAssertEqualObjects(error, @"E_CLAUDE_OFFICIAL_GUEST_BOOT_FAILED"); XCTAssertEqual(boots, 1U);
  DSHGuestVMOwner *next = [DSHGuestRuntimeState.sharedState acquireGuestOwner];
  XCTAssertNotNil(next); [DSHGuestRuntimeState.sharedState releaseGuestOwner:next];
  [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
}
@end
