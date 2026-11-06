#import <XCTest/XCTest.h>
#import "RuntimeServiceVM.h"
#import "RuntimeEnvironmentStore.h"
#import "RuntimeWorkspaceSnapshot.h"

@interface DSHServiceTestLease : DSHRuntimeEnvironmentLease
@property(nonatomic, copy) NSString *family;
@end
@implementation DSHServiceTestLease
- (NSDictionary *)manifest { return @{@"family":self.family ?: @"node"}; }
@end

@interface DSHServiceTestVM : DSHRuntimeServiceVM
@property(nonatomic, strong) NSMutableArray *commands;
@property(nonatomic, strong) NSMutableArray *limits;
@property(nonatomic, strong) NSMutableData *staged;
@property(nonatomic, strong) NSData *response;
@property(nonatomic) NSUInteger forwards;
@property(nonatomic) NSUInteger scopes;
@property(nonatomic) BOOL scopeReturned;
@property(nonatomic, copy) NSString *forwardError;
@property(nonatomic) NSUInteger refusals;
@property(nonatomic) NSUInteger statusTimeouts;
@property(nonatomic) NSUInteger statusChecks;
@property(nonatomic, copy) NSString *statusError;
@property(nonatomic) BOOL poisonOnTimeout;
@property(nonatomic) BOOL poisoned;
@property(nonatomic) NSUInteger commandsAfterTimeout;
@property(nonatomic) BOOL errorOnFirstForward;
@end
@implementation DSHServiceTestVM
- (instancetype)init {
  self = [super initWithBundle:NSBundle.mainBundle];
  if (self) {
    _commands = [NSMutableArray array]; _limits = [NSMutableArray array];
    _staged = [NSMutableData data];
    _response = [@"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK"
        dataUsingEncoding:NSUTF8StringEncoding];
  }
  return self;
}
- (NSNumber *)performWithLease:(DSHRuntimeEnvironmentLease *)lease snapshot:(DSHRuntimeWorkspaceSnapshot *)snapshot
                      operation:(DSHRuntimeVMOperation)operation error:(NSError **)error {
  (void)lease; (void)snapshot; self.scopes++;
  NSNumber *result = operation((__bridge void *)self, error);
  self.scopeReturned = YES; return result;
}
- (NSDictionary *)executeSession:(void *)session command:(NSArray *)command
                         deadline:(NSTimeInterval)deadline limit:(NSUInteger)limit
                           stdout:(NSData **)stdoutData error:(NSError **)error {
  (void)session; (void)deadline;
  [self.commands addObject:command]; [self.limits addObject:@(limit)];
  if (self.poisoned) {
    self.commandsAfterTimeout++;
    [self cancel];
    if (error) *error = DSHRuntimeProgramError(@"E_PROGRAM_TIMEOUT");
    return nil;
  }
  NSString *script = command.count > 2 ? command[2] : @"";
  if ([script isEqual:@": > \"$1\""]) [self.staged setLength:0];
  else if ([script containsString:@"base64 -d >>"]) {
    NSData *data = [[NSData alloc] initWithBase64EncodedString:command.lastObject options:0];
    [self.staged appendData:data];
  } else if ([script hasPrefix:@"exec /bin/busybox nc"]) {
    self.forwards++;
    // A program that has not bound its port yet refuses the probe.
    if (self.forwards <= self.refusals) {
      if (error) *error = DSHRuntimeProgramError(@"E_PROGRAM_EXEC"); return nil;
    }
    if ((self.forwards > 1 || self.errorOnFirstForward) && self.forwardError) {
      if (self.poisonOnTimeout && [self.forwardError isEqual:@"E_PROGRAM_TIMEOUT"]) self.poisoned = YES;
      if (error) *error = DSHRuntimeProgramError(self.forwardError); return nil;
    }
    if (stdoutData) *stdoutData = self.response;
  } else if ([script hasPrefix:@"if test -s"]) {
    self.statusChecks++;
    if (self.statusError) {
      if (self.poisonOnTimeout && [self.statusError isEqual:@"E_PROGRAM_TIMEOUT"]) self.poisoned = YES;
      if (error) *error = DSHRuntimeProgramError(self.statusError); return nil;
    }
    if (self.statusChecks <= self.statusTimeouts) {
      if (error) *error = DSHRuntimeProgramError(@"E_PROGRAM_TIMEOUT"); return nil;
    }
    if (stdoutData) *stdoutData = [@"running" dataUsingEncoding:NSUTF8StringEncoding];
  } else if (stdoutData) *stdoutData = NSData.data;
  return @{@"exit_code":@0};
}
@end

@interface RuntimeServiceVMTests : XCTestCase
@end
@implementation RuntimeServiceVMTests
- (DSHServiceTestLease *)lease:(NSString *)family {
  DSHServiceTestLease *lease = [[DSHServiceTestLease alloc] init]; lease.family = family; return lease;
}
- (void)testAllSixFamiliesUseDetachedLiteralCommandAndPortEnvironment {
  NSArray *args = @[@"", @"literal ; $(touch /tmp/nope)", @"quoted' value"];
  NSString *entry = @"src/server 'literal'.js";
  for (NSString *family in @[@"python", @"java", @"go", @"rust", @"bun", @"node"]) {
    DSHServiceTestVM *vm = [[DSHServiceTestVM alloc] init];
    __block BOOL ready = NO;
    [vm serveLease:[self lease:family] snapshot:(id)nil entryPath:entry args:args guestPort:3000
        ready:^(NSData *probe) { ready = YES; XCTAssertEqualObjects(probe, vm.response); [vm cancel]; }
        output:^(__unused NSString *channel, __unused NSData *data) {} error:nil];
    XCTAssertTrue(ready); XCTAssertTrue(vm.scopeReturned);
    NSArray *launch = vm.commands.firstObject;
    NSString *script = launch[2];
    XCTAssertTrue([script containsString:@"setsid"]); XCTAssertTrue([script containsString:@"server.pid"]);
    XCTAssertTrue([script containsString:@"head -c 262144"]); XCTAssertTrue([script containsString:@"mkfifo"]);
    XCTAssertFalse([script containsString:entry]); XCTAssertFalse([script containsString:args[1]]);
    XCTAssertTrue([launch containsObject:@"PORT=3000"]);
    XCTAssertTrue([launch containsObject:@"HOST=127.0.0.1"]);
    NSArray *tail = [launch subarrayWithRange:NSMakeRange(launch.count - args.count, args.count)];
    XCTAssertEqualObjects(tail, args);
    XCTAssertTrue([launch containsObject:[@"/workspace/" stringByAppendingString:entry]]);
  }
}
- (void)testRequestsPreserveBinaryBytesAndResponsesAreNeverDecodedAsUTF8 {
  DSHServiceTestVM *vm = [[DSHServiceTestVM alloc] init];
  NSMutableData *request = [[@"POST /a?q=1 HTTP/1.1\r\nContent-Length: 5\r\nConnection: close\r\n\r\n"
      dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
  const uint8_t body[] = {0, 255, 128, '\'', '\n'}; [request appendBytes:body length:sizeof(body)];
  NSMutableData *response = [[@"HTTP/1.1 201 Created\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n5\r\n"
      dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
  [response appendBytes:body length:sizeof(body)];
  [response appendData:[@"\r\n0\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
  vm.response = response;
  __block NSData *received = nil;
  [vm serveLease:[self lease:@"node"] snapshot:(id)nil entryPath:@"server.js" args:@[] guestPort:3000
      ready:^(__unused NSData *probe) {
        [vm requestHTTP:request completion:^(NSData *bytes, NSError *error) {
          XCTAssertNil(error); received = bytes; [vm cancel];
        }];
      } output:^(__unused NSString *channel, __unused NSData *data) {} error:nil];
  XCTAssertEqualObjects(vm.staged, request); XCTAssertEqualObjects(received, response);
  XCTAssertEqual(vm.forwards, 2U); XCTAssertTrue(vm.scopeReturned);
  for (NSArray *command in vm.commands) {
    NSString *script = command[2];
    if ([script hasPrefix:@"exec /bin/busybox nc"]) {
      XCTAssertFalse([script containsString:@" -w"]);
      XCTAssertFalse([script containsString:@"timeout "]);
    }
  }
}
- (void)testQueueRejectsBeforeReadyAndBeyondCapacityAndFlushesOnCancel {
  DSHServiceTestVM *vm = [[DSHServiceTestVM alloc] init];
  NSData *request = [@"GET / HTTP/1.1\r\nConnection: close\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
  __block NSUInteger rejected = 0, cancelled = 0;
  [vm requestHTTP:request completion:^(NSData *bytes, NSError *error) {
    XCTAssertNil(bytes); XCTAssertEqualObjects(error.userInfo[@"code"], @"E_PROGRAM_BUSY"); rejected++;
  }];
  [vm serveLease:[self lease:@"node"] snapshot:(id)nil entryPath:@"server.js" args:@[] guestPort:3000
      ready:^(__unused NSData *probe) {
        for (NSUInteger i = 0; i < 9; i++) [vm requestHTTP:request completion:^(NSData *bytes, NSError *error) {
          XCTAssertNil(bytes);
          if ([error.userInfo[@"code"] isEqual:@"E_PROGRAM_BUSY"]) rejected++;
          else { XCTAssertEqualObjects(error.userInfo[@"code"], @"E_PROGRAM_UNAVAILABLE"); cancelled++; }
        }];
        [vm cancel];
      } output:^(__unused NSString *channel, __unused NSData *data) {} error:nil];
  XCTAssertEqual(rejected, 2U); XCTAssertEqual(cancelled, 8U); XCTAssertEqual(vm.forwards, 1U);
}
- (void)testOversizedRequestAndInvalidPortDoNotReachTheVM {
  DSHServiceTestVM *vm = [[DSHServiceTestVM alloc] init];
  [vm requestHTTP:[NSMutableData dataWithLength:DSHRuntimeServiceMaxRequestBytes + 1]
      completion:^(NSData *bytes, NSError *error) {
        XCTAssertNil(bytes); XCTAssertEqualObjects(error.userInfo[@"code"], @"E_PROGRAM_INVALID_REQUEST");
      }];
  for (NSNumber *port in @[@0, @65536]) {
    NSError *error = nil;
    XCTAssertNil([vm serveLease:[self lease:@"node"] snapshot:(id)nil entryPath:@"server.js" args:@[]
        guestPort:port.unsignedIntegerValue ready:^(__unused NSData *data) {}
        output:^(__unused NSString *channel, __unused NSData *data) {} error:&error]);
    XCTAssertEqualObjects(error.userInfo[@"code"], @"E_PROGRAM_INVALID_REQUEST");
  }
  XCTAssertEqual(vm.scopes, 0U); XCTAssertEqual(vm.commands.count, 0U);
}
- (void)testOutputLimitAndHostTimeoutArePreservedAndEndTheScope {
  for (NSString *code in @[@"E_PROGRAM_OUTPUT_LIMIT", @"E_PROGRAM_TIMEOUT"]) {
    DSHServiceTestVM *vm = [[DSHServiceTestVM alloc] init]; vm.forwardError = code;
    __block NSError *replyError = nil; NSError *error = nil;
    [vm serveLease:[self lease:@"node"] snapshot:(id)nil entryPath:@"server.js" args:@[] guestPort:3000
        ready:^(__unused NSData *probe) {
          [vm requestHTTP:[@"GET / HTTP/1.1\r\nConnection: close\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]
              completion:^(__unused NSData *bytes, NSError *failure) { replyError = failure; }];
        } output:^(__unused NSString *channel, __unused NSData *data) {} error:&error];
    XCTAssertEqualObjects(replyError.userInfo[@"code"], code);
    XCTAssertEqualObjects(error.userInfo[@"code"], code); XCTAssertTrue(vm.scopeReturned);
  }
}
- (void)testCompilingProgramCanRefuseReadinessBeforeItsPortIsBound {
  DSHServiceTestVM *vm = [[DSHServiceTestVM alloc] init];
  vm.refusals = 3;
  __block BOOL ready = NO; NSError *error = nil;
  [vm serveLease:[self lease:@"go"] snapshot:(id)nil entryPath:@"go.go" args:@[@"8080"] guestPort:8080
      ready:^(__unused NSData *probe) { ready = YES; [vm cancel]; }
      output:^(__unused NSString *channel, __unused NSData *data) {} error:&error];
  XCTAssertTrue(ready, @"Connection refusal before the first listen is retryable.");
  XCTAssertNil(error);
  XCTAssertEqual(vm.forwards, 4U); XCTAssertGreaterThanOrEqual(vm.statusChecks, 3U);
  NSUInteger writes = 0;
  for (NSArray *command in vm.commands) if ([command[2] isEqual:@": > \"$1\""]) writes++;
  XCTAssertEqual(writes, 1U, @"Refused readiness probes must reuse the immutable request.");
}
- (void)testHostDeadlinePermanentlyEndsTheFFISessionWithoutAnotherCommand {
  // The actual FFI's host deadline sets a one-shot Cancellation reason and
  // cancels the machine. It is not a recoverable guest command timeout.
  DSHServiceTestVM *vm = [[DSHServiceTestVM alloc] init];
  vm.refusals = NSUIntegerMax; vm.statusError = @"E_PROGRAM_TIMEOUT";
  vm.poisonOnTimeout = YES;
  __block BOOL ready = NO; NSError *error = nil;
  XCTAssertNil([vm serveLease:[self lease:@"go"] snapshot:nil entryPath:@"go.go" args:@[] guestPort:8080
      ready:^(__unused NSData *probe) { ready = YES; [vm cancel]; }
      output:^(__unused NSString *channel, __unused NSData *data) {} error:&error]);
  XCTAssertFalse(ready); XCTAssertTrue(vm.scopeReturned);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_PROGRAM_TIMEOUT");
  XCTAssertEqual(vm.commandsAfterTimeout, 0U);
}
- (void)testReadinessTimeoutDoesNotTryToCollectLogsFromTheCancelledVM {
  DSHServiceTestVM *vm = [[DSHServiceTestVM alloc] init];
  vm.forwardError = @"E_PROGRAM_TIMEOUT"; vm.errorOnFirstForward = YES;
  vm.poisonOnTimeout = YES;
  NSError *error = nil;
  XCTAssertNil([vm serveLease:[self lease:@"python"] snapshot:nil entryPath:@"server.py" args:@[] guestPort:8080
      ready:^(__unused NSData *probe) { XCTFail(@"A timed out probe cannot be published."); }
      output:^(__unused NSString *channel, __unused NSData *data) {} error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_PROGRAM_TIMEOUT");
  XCTAssertEqual(vm.commandsAfterTimeout, 0U); XCTAssertTrue(vm.scopeReturned);
}
- (void)testSupervisionFailureThatIsNotADeadlineStillEndsTheStart {
  DSHServiceTestVM *vm = [[DSHServiceTestVM alloc] init];
  vm.refusals = 1; vm.statusError = @"E_PROGRAM_OUTPUT_LIMIT";
  __block BOOL ready = NO; NSError *error = nil;
  XCTAssertNil([vm serveLease:[self lease:@"go"] snapshot:(id)nil entryPath:@"go.go" args:@[@"8080"]
      guestPort:8080 ready:^(__unused NSData *probe) { ready = YES; [vm cancel]; }
      output:^(__unused NSString *channel, __unused NSData *data) {} error:&error]);
  XCTAssertFalse(ready);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_PROGRAM_OUTPUT_LIMIT");
  XCTAssertTrue(vm.scopeReturned);
}
- (void)testCancellationFromAnotherThreadWakesTheIdleService {
  DSHServiceTestVM *vm = [[DSHServiceTestVM alloc] init];
  XCTestExpectation *ready = [self expectationWithDescription:@"ready"];
  XCTestExpectation *finished = [self expectationWithDescription:@"finished"];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    [vm serveLease:[self lease:@"node"] snapshot:(id)nil entryPath:@"server.js" args:@[] guestPort:3000
        ready:^(__unused NSData *probe) { [ready fulfill]; }
        output:^(__unused NSString *channel, __unused NSData *data) {} error:nil];
    [finished fulfill];
  });
  [self waitForExpectations:@[ready] timeout:2];
  [vm cancel]; [self waitForExpectations:@[finished] timeout:2]; XCTAssertTrue(vm.scopeReturned);
}
@end
