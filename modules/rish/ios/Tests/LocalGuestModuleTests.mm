// Proves the persistent rish guest is genuinely bootable inside the app
// process: the real FFI boots the bundled kernel + initramfs in the pure-Rust
// x86_64 interpreter (no mock), apk add tree installs from the offline
// repository baked into the initramfs with signature verification, and the
// installed binary runs. The boot takes ~40 s, so this test raises
// executionTimeAllowance and never runs a mocked session.

#import <XCTest/XCTest.h>
#import <CommonCrypto/CommonDigest.h>

#import "../../../../modules/rish/ios/Sources/DSHGuestRuntimeState.h"
#import "../../../../modules/rish/ios/Sources/LocalGuestModule.h"

// Production-private seam for the mirrors receipt wiring, same pattern as the
// LocalRuntime tests: the real class lives in the linked module sources.
@interface LocalMirrorsModule : NSObject
- (void)applyMirrorsValue:(NSDictionary *)mirrors
                 resolver:(void (^)(id result))resolve
                 rejecter:(void (^)(NSString *code, NSString *message,
                                    NSError *error))reject;
@end

@interface LocalGuestModuleTests : XCTestCase
@end

@implementation LocalGuestModuleTests

static NSString *DSHTestHexSHA256OfFile(NSURL *url) {
  NSData *data = [NSData dataWithContentsOfURL:url options:0 error:nil];
  if (data == nil) return nil;
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  NSMutableString *hex =
      [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
  for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index += 1) {
    [hex appendFormat:@"%02x", digest[index]];
  }
  return hex;
}

// Runs an async module call to completion on the test thread. Returns the
// resolved dictionary (nil when rejected); the reject code is returned via
// outCode. Times out via outCode = @"TIMEOUT" when the call exceeds timeout.
static NSDictionary *DSHGuestCall(
    void (^invoke)(void (^)(id), void (^)(NSString *, NSString *, NSError *)),
    NSString **outCode, NSTimeInterval timeout) {
  __block NSDictionary *result = nil;
  __block NSString *code = nil;
  dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
  invoke(^(id value) {
    result = [value isKindOfClass:NSDictionary.class] ? value : nil;
    dispatch_semaphore_signal(semaphore);
  }, ^(NSString *rejectCode, NSString *message, NSError *error) {
    (void)message;
    (void)error;
    code = rejectCode;
    dispatch_semaphore_signal(semaphore);
  });
  long wait = dispatch_semaphore_wait(
      semaphore, dispatch_time(DISPATCH_TIME_NOW,
                               (int64_t)(timeout * NSEC_PER_SEC)));
  if (wait != 0) code = @"TIMEOUT";
  if (outCode != nil) *outCode = code;
  return result;
}

static NSDictionary *DSHGuestBoot(LocalGuestModule *module,
                                  NSDictionary *request, NSString **outCode,
                                  NSTimeInterval timeout) {
  return DSHGuestCall(
      ^(void (^resolve)(id), void (^reject)(NSString *, NSString *, NSError *)) {
        [module bootGuestRequest:request resolve:resolve reject:reject];
      },
      outCode, timeout);
}

static NSDictionary *DSHGuestExec(LocalGuestModule *module,
                                  NSArray<NSString *> *command,
                                  NSString **outCode, NSTimeInterval timeout) {
  return DSHGuestCall(
      ^(void (^resolve)(id), void (^reject)(NSString *, NSString *, NSError *)) {
        [module guestExecRequest:@{ @"schema_version" : @1, @"command" : command }
                         resolve:resolve
                          reject:reject];
      },
      outCode, timeout);
}

static NSDictionary *DSHGuestShutdown(LocalGuestModule *module,
                                      NSString **outCode) {
  return DSHGuestCall(
      ^(void (^resolve)(id), void (^reject)(NSString *, NSString *, NSError *)) {
        [module shutdownGuestResolve:resolve reject:reject];
      },
      outCode, 30);
}

// The bundled assets must resolve and match the pinned digests recorded in
// GuestAssets/SHA256SUMS before anything is booted.
- (void)testBundleAssetsResolveAndMatchPinnedDigests {
  LocalGuestModule *module =
      [[LocalGuestModule alloc] initWithBundle:NSBundle.mainBundle];
  XCTAssertNotNil(module.kernelURL, @"kernel resource missing from bundle");
  XCTAssertNotNil(module.initramfsURL, @"initramfs resource missing from bundle");
  if (module.kernelURL == nil || module.initramfsURL == nil) return;
  XCTAssertEqualObjects(DSHTestHexSHA256OfFile(module.kernelURL),
                        DSHGuestKernelSha256);
  XCTAssertEqualObjects(DSHTestHexSHA256OfFile(module.initramfsURL),
                        DSHGuestInitramfsSha256);
}

// Boot request validation fails closed: malformed envelopes never reach the
// FFI and never leave the module outside the idle state.
- (void)testBootRequestValidationFailsClosed {
  LocalGuestModule *module =
      [[LocalGuestModule alloc] initWithBundle:NSBundle.mainBundle];
  NSArray<NSDictionary *> *invalid = @[
    @{ @"schema_version" : @1 },                                 // missing key
    @{ @"schema_version" : @1, @"memory_mib" : @1024, @"extra" : @1 },
    @{ @"schema_version" : @2, @"memory_mib" : @1024 },
    @{ @"schema_version" : @YES, @"memory_mib" : @1024 },
    @{ @"schema_version" : @1, @"memory_mib" : @"1024" },
    @{ @"schema_version" : @1, @"memory_mib" : @255 },
    @{ @"schema_version" : @1, @"memory_mib" : @4097 },
    @{ @"schema_version" : @1, @"memory_mib" : @(-1) },
    @{ @"schema_version" : @1, @"memory_mib" : @1024.5 },
  ];
  for (NSDictionary *request in invalid) {
    NSString *code = nil;
    NSDictionary *receipt = DSHGuestBoot(module, request, &code, 5);
    XCTAssertNil(receipt, @"request must be rejected: %@", request);
    XCTAssertEqualObjects(code, DSHGuestErrorInvalidRequest,
        @"request %@ must fail closed with E_GUEST_INVALID_REQUEST", request);
  }
  NSString *code = nil;
  NSDictionary *shutdown = DSHGuestShutdown(module, &code);
  XCTAssertEqualObjects(shutdown[@"status"], @"already_idle",
      @"failed validation must leave the session idle");
}

// Exec before boot fails closed with an explicit code instead of queueing.
- (void)testExecBeforeBootFailsClosed {
  LocalGuestModule *module =
      [[LocalGuestModule alloc] initWithBundle:NSBundle.mainBundle];
  NSString *code = nil;
  NSDictionary *receipt =
      DSHGuestExec(module, @[ @"uname", @"-a" ], &code, 5);
  XCTAssertNil(receipt);
  XCTAssertEqualObjects(code, DSHGuestErrorNotBooted);
}

// Command validation precedes the session-state check: even an idle module
// rejects malformed argv with E_GUEST_INVALID_REQUEST, never E_GUEST_NOT_BOOTED.
- (void)testExecRequestValidationFailsClosed {
  LocalGuestModule *module =
      [[LocalGuestModule alloc] initWithBundle:NSBundle.mainBundle];
  NSMutableArray<NSString *> *oversizedArg = [NSMutableArray array];
  for (NSUInteger index = 0; index < 5000; index += 1) {
    [oversizedArg addObject:@"a"];
  }
  NSMutableArray<NSString *> *tooManyArgs = [NSMutableArray array];
  for (NSUInteger index = 0; index < 65; index += 1) {
    [tooManyArgs addObject:@"x"];
  }
  NSMutableArray<NSString *> *oversizedTotal = [NSMutableArray array];
  for (NSUInteger index = 0; index < 20; index += 1) {
    [oversizedTotal addObject:[oversizedArg componentsJoinedByString:@""]];
  }
  NSArray *invalidRequests = @[
    @{},                                                       // missing keys
    @{ @"schema_version" : @1 },                               // missing command
    @{ @"schema_version" : @2, @"command" : @[ @"true" ] },
    @{ @"schema_version" : @1, @"command" : @"uname" },        // command not array
    @{ @"schema_version" : @1, @"command" : @[] },             // empty array
    @{ @"schema_version" : @1, @"command" : @[ @1, @2 ] },     // non-string argv
    @{ @"schema_version" : @1, @"command" : @[ @"", @"x" ] },  // empty argv0
    @{ @"schema_version" : @1, @"command" : @[ @"x\0y" ] },    // embedded NUL
    @{ @"schema_version" : @1, @"command" : @[ oversizedArg ] }, // over 4096 bytes
    @{ @"schema_version" : @1, @"command" : [tooManyArgs copy] }, // over 64 args
    @{ @"schema_version" : @1, @"command" : [oversizedTotal copy] }, // over 65536 bytes
  ];
  for (NSDictionary *request in invalidRequests) {
    __block NSDictionary *result = nil;
    __block NSString *code = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [module guestExecRequest:request
                     resolve:^(id value) {
                       result = [value isKindOfClass:NSDictionary.class]
                           ? value : nil;
                       dispatch_semaphore_signal(semaphore);
                     }
                      reject:^(NSString *rejectCode, NSString *message,
                               NSError *error) {
                        (void)message;
                        (void)error;
                        code = rejectCode;
                        dispatch_semaphore_signal(semaphore);
                      }];
    XCTAssertEqual(dispatch_semaphore_wait(
                       semaphore,
                       dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)), 0);
    XCTAssertNil(result, @"request must be rejected: %@", request);
    XCTAssertEqualObjects(code, DSHGuestErrorInvalidRequest,
        @"request %@ must fail closed with E_GUEST_INVALID_REQUEST", request);
  }
}

// Shutdown without a session is idempotent, never an error.
- (void)testShutdownWhenIdleIsIdempotent {
  LocalGuestModule *module =
      [[LocalGuestModule alloc] initWithBundle:NSBundle.mainBundle];
  NSString *code = nil;
  NSDictionary *first = DSHGuestShutdown(module, &code);
  XCTAssertNil(code);
  XCTAssertEqualObjects(first[@"status"], @"already_idle");
  NSDictionary *second = DSHGuestShutdown(module, &code);
  XCTAssertNil(code);
  XCTAssertEqualObjects(second[@"status"], @"already_idle");
}

// Mirrors receipts stay honest: mounted is NO while no guest is booted and
// the staged overlay is never claimed to enter the guest.
- (void)testMirrorsReceiptReportsNoGuestWhenIdle {
  [[DSHGuestRuntimeState sharedState] setGuestRuntimeMounted:NO];
  LocalMirrorsModule *mirrors = [[LocalMirrorsModule alloc] init];
  NSDictionary *request = @{
    @"alpine" : @{
      @"enabled" : @YES,
      @"baseUrl" : @"https://dl-cdn.alpinelinux.org/alpine/",
    },
    @"pip" : @{
      @"enabled" : @YES,
      @"baseUrl" : @"https://pypi.org/simple/",
    },
    @"npm" : @{
      @"enabled" : @YES,
      @"baseUrl" : @"https://registry.npmjs.org/",
    },
  };
  __block NSDictionary *receipt = nil;
  dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
  [mirrors applyMirrorsValue:request
                    resolver:^(id value) {
                      receipt = [value isKindOfClass:NSDictionary.class]
                          ? value : nil;
                      dispatch_semaphore_signal(semaphore);
                    }
                    rejecter:^(NSString *code, NSString *message, NSError *error) {
                      (void)code;
                      (void)message;
                      (void)error;
                      dispatch_semaphore_signal(semaphore);
                    }];
  XCTAssertEqual(dispatch_semaphore_wait(
                     semaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)),
                 0);
  XCTAssertNotNil(receipt);
  XCTAssertEqualObjects(receipt[@"guest_runtime_mounted"], @NO);
  XCTAssertEqualObjects(receipt[@"staged_config_enters_guest"], @NO);
}

// THE real proof: boots the guest in-process on the pure-Rust interpreter and
// installs tree from the baked offline repository, then runs the binary.
- (void)testGuestBootsAndInstallsTreeFromOfflineRepository {
  self.executionTimeAllowance = 900;
  LocalGuestModule *module =
      [[LocalGuestModule alloc] initWithBundle:NSBundle.mainBundle];

  NSString *bootCode = nil;
  NSDictionary *boot = DSHGuestBoot(module, @{
    @"schema_version" : @1,
    @"memory_mib" : @1024,
  }, &bootCode, 600);
  XCTAssertNil(bootCode, @"boot rejected: %@", bootCode);
  XCTAssertNotNil(boot, @"boot returned no receipt");
  if (boot == nil) return;
  XCTAssertEqualObjects(boot[@"schema_version"], @1);
  XCTAssertEqualObjects(boot[@"status"], @"booted");
  XCTAssertGreaterThan([boot[@"boot_ms"] unsignedLongLongValue], 0ULL);
  XCTAssertEqualObjects(boot[@"memory_mib"], @1024);
  // Receipts must never leak absolute container paths back to JavaScript.
  XCTAssertFalse([boot[@"kernel"] containsString:@"/"],
      @"kernel field must be a bundle-relative name, got %@", boot[@"kernel"]);
  XCTAssertFalse([boot[@"initramfs"] containsString:@"/"],
      @"initramfs field must be a bundle-relative name, got %@",
      boot[@"initramfs"]);
  XCTAssertEqualObjects(boot[@"kernel_sha256"], DSHGuestKernelSha256);
  XCTAssertEqualObjects(boot[@"initramfs_sha256"], DSHGuestInitramfsSha256);
  NSLog(@"GUEST_BOOT_RECEIPT %@", boot);
  XCTAssertTrue([[DSHGuestRuntimeState sharedState] guestRuntimeMounted],
      @"shared registry must report a mounted guest after boot");

  // Single-session semantics: a second boot fails closed instead of silently
  // restarting the guest.
  NSString *doubleBootCode = nil;
  NSDictionary *doubleBoot = DSHGuestBoot(module, @{
    @"schema_version" : @1,
    @"memory_mib" : @1024,
  }, &doubleBootCode, 5);
  XCTAssertNil(doubleBoot);
  XCTAssertEqualObjects(doubleBootCode, DSHGuestErrorAlreadyBooted);

  // apk add tree against the build-time-baked offline repository. This is a
  // real guest command, not a mock: it resolves musl as a dependency,
  // verifies the signed index, and installs both packages.
  NSString *apkCode = nil;
  NSDictionary *apk = DSHGuestExec(module, @[ @"apk", @"add", @"tree" ],
                                   &apkCode, 300);
  XCTAssertNil(apkCode, @"apk add rejected: %@", apkCode);
  XCTAssertNotNil(apk, @"apk add returned no receipt");
  if (apk == nil) return;
  XCTAssertTrue([apk[@"ok"] boolValue], @"apk add ok=false: %@", apk);
  XCTAssertEqual([apk[@"exit_code"] integerValue], 0,
      @"apk add exit code: %@", apk);
  XCTAssertNotNil(apk[@"boot_units"],
      @"exec receipt must carry the guest boot unit count");
  NSLog(@"GUEST_APK_ADD_EXIT=%ld BOOT_UNITS=%@",
      (long)[apk[@"exit_code"] integerValue], apk[@"boot_units"]);
  NSLog(@"GUEST_APK_ADD_STDOUT %@", apk[@"stdout"]);
  NSLog(@"GUEST_APK_ADD_STDERR %@", apk[@"stderr"]);
  NSString *apkStdout = apk[@"stdout"];
  XCTAssertTrue([apkStdout containsString:@"Installing tree"],
      @"apk add output must show the tree install: %@", apkStdout);
  XCTAssertTrue([apkStdout containsString:@"OK:"],
      @"apk add output must finish with OK: %@", apkStdout);

  // The installed binary exists and runs in the same session.
  NSString *treeCode = nil;
  NSDictionary *tree = DSHGuestExec(
      module, @[ @"sh", @"-lc", @"/usr/bin/tree --version" ], &treeCode, 60);
  XCTAssertNil(treeCode, @"tree exec rejected: %@", treeCode);
  XCTAssertNotNil(tree);
  if (tree == nil) return;
  XCTAssertTrue([tree[@"ok"] boolValue], @"tree run ok=false: %@", tree);
  XCTAssertEqual([tree[@"exit_code"] integerValue], 0,
      @"tree run exit code: %@", tree);
  XCTAssertTrue([[tree[@"stdout"] description] containsString:@"tree v2.3.2"],
      @"tree binary must report its version: %@", tree[@"stdout"]);

  // Mirrors receipt while the guest is genuinely booted: mounted reflects the
  // real state, but the staged overlay is still explicitly NOT in the guest.
  LocalMirrorsModule *mirrors = [[LocalMirrorsModule alloc] init];
  NSDictionary *mirrorRequest = @{
    @"alpine" : @{
      @"enabled" : @YES,
      @"baseUrl" : @"https://dl-cdn.alpinelinux.org/alpine/",
    },
    @"pip" : @{
      @"enabled" : @YES,
      @"baseUrl" : @"https://pypi.org/simple/",
    },
    @"npm" : @{
      @"enabled" : @YES,
      @"baseUrl" : @"https://registry.npmjs.org/",
    },
  };
  __block NSDictionary *mirrorReceipt = nil;
  dispatch_semaphore_t mirrorSemaphore = dispatch_semaphore_create(0);
  [mirrors applyMirrorsValue:mirrorRequest
                    resolver:^(id value) {
                      mirrorReceipt = [value isKindOfClass:NSDictionary.class]
                          ? value : nil;
                      dispatch_semaphore_signal(mirrorSemaphore);
                    }
                    rejecter:^(NSString *code, NSString *message, NSError *error) {
                      (void)code;
                      (void)message;
                      (void)error;
                      dispatch_semaphore_signal(mirrorSemaphore);
                    }];
  XCTAssertEqual(dispatch_semaphore_wait(
                     mirrorSemaphore,
                     dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)), 0);
  XCTAssertEqualObjects(mirrorReceipt[@"guest_runtime_mounted"], @YES,
      @"mounted must be YES while the guest session is live");
  XCTAssertEqualObjects(mirrorReceipt[@"staged_config_enters_guest"], @NO,
      @"the staged mirror overlay must never claim to enter the guest");

  // Shutdown releases the session: further exec fails closed and the shared
  // registry drops back to unmounted.
  NSString *shutdownCode = nil;
  NSDictionary *shutdown = DSHGuestShutdown(module, &shutdownCode);
  XCTAssertNil(shutdownCode);
  XCTAssertEqualObjects(shutdown[@"status"], @"shutdown");
  XCTAssertFalse([[DSHGuestRuntimeState sharedState] guestRuntimeMounted],
      @"shared registry must report unmounted after shutdown");
  NSString *afterCode = nil;
  NSDictionary *after = DSHGuestExec(module, @[ @"true" ], &afterCode, 5);
  XCTAssertNil(after);
  XCTAssertEqualObjects(afterCode, DSHGuestErrorNotBooted,
      @"exec after shutdown must fail closed with E_GUEST_NOT_BOOTED");
  NSString *idleCode = nil;
  NSDictionary *idle = DSHGuestShutdown(module, &idleCode);
  XCTAssertEqualObjects(idle[@"status"], @"already_idle");
}

@end
