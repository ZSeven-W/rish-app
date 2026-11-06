#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
#import <math.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>
#import "RishGuestCgiHTTP.h"
#import "RishGuestCgiService.h"
#import "LocalGuestModule.h"

@interface RishGuestCgiService (Testing)
- (instancetype)initWithGuestFactoryForTesting:(LocalGuestModule *(^)(void))factory;
- (NSTimeInterval)previewDurationForTesting:(NSTimeInterval)remaining;
- (void)setPreviewTaskForTesting:(UIBackgroundTaskIdentifier (^)(void (^)(void)))begin end:(void (^)(UIBackgroundTaskIdentifier))end limit:(NSTimeInterval)limit;
@end

@interface RishCgiPreviewLease : NSObject
@property(nonatomic) UIBackgroundTaskIdentifier identifier;
@property(nonatomic, copy) void (^endTask)(UIBackgroundTaskIdentifier);
- (void)finish;
@end

@interface FakeGuest : LocalGuestModule
@property(nonatomic, copy) void (^bootResolve)(id result);
@property(nonatomic, copy) void (^bootReject)(NSString *code, NSString *message, NSError *error);
@property(nonatomic, strong) NSMutableArray<void (^)(id result)> *execResolves;
@property(nonatomic, strong) NSMutableArray<NSString *> *commands;
@property(nonatomic, assign) NSUInteger shutdownCount;
@property(nonatomic, assign) BOOL holdNextStageExec;
@end

@implementation FakeGuest
- (instancetype)init {
  self = [super init];
  if (self) { _execResolves = [NSMutableArray array]; _commands = [NSMutableArray array]; }
  return self;
}
- (void)bootGuestRequest:(NSDictionary *)request resolve:(void (^)(id))resolve reject:(void (^)(NSString *, NSString *, NSError *))reject {
  (void)request; self.bootResolve = resolve; self.bootReject = reject;
}
- (void)guestExecRequest:(NSDictionary *)request resolve:(void (^)(id))resolve reject:(void (^)(NSString *, NSString *, NSError *))reject {
  (void)reject;
  NSArray *command = request[@"command"];
  [self.commands addObject:command.count > 2 ? command[2] : @""];
  NSString *shell = command.count > 2 ? command[2] : @"";
  // Teardown cleanup is safe to complete immediately. Other commands remain
  // pending so the test can deliver a stale callback after stop.
  if ([shell hasPrefix:@"rm -rf"] || [shell hasPrefix:@"rm -f"]) {
    resolve(@{ @"ok": @YES, @"exit_code": @0, @"stdout": @"", @"stderr": @"" });
  } else if (self.holdNextStageExec && ([shell containsString:@"mkdir -p"] || [shell containsString:@"printf '%s'"] || [shell containsString:@"base64 -d"])) {
    // Lifecycle race cases explicitly pause one staging command. Cleanup
    // remains immediate so stop/dealloc can be tested independently.
    self.holdNextStageExec = NO;
    [self.execResolves addObject:[resolve copy]];
  } else if ([shell containsString:@"mkdir -p"] || [shell containsString:@"printf '%s'"]) {
    resolve(@{ @"ok": @YES, @"exit_code": @0, @"stdout": @"", @"stderr": @"" });
  } else if ([shell containsString:@"base64 -d"]) {
    NSRange sizeMarker = [shell rangeOfString:@"test \"$n\" = \""];
    NSRange hashMarker = [shell rangeOfString:@"test \"$h\" = \""];
    NSString *size = @"0"; NSString *hash = @"";
    if (sizeMarker.location != NSNotFound) {
      NSUInteger start = NSMaxRange(sizeMarker);
      NSRange rest = [shell rangeOfString:@"\"" options:0 range:NSMakeRange(start, shell.length - start)];
      if (rest.location != NSNotFound) size = [shell substringWithRange:NSMakeRange(start, rest.location - start)];
    }
    if (hashMarker.location != NSNotFound) {
      NSUInteger start = NSMaxRange(hashMarker);
      NSRange rest = [shell rangeOfString:@"\"" options:0 range:NSMakeRange(start, shell.length - start)];
      if (rest.location != NSNotFound) hash = [shell substringWithRange:NSMakeRange(start, rest.location - start)];
    }
    resolve(@{ @"ok": @YES, @"exit_code": @0, @"stdout": [NSString stringWithFormat:@"%@ %@", size, hash], @"stderr": @"" });
  } else if ([shell containsString:@"timeout "]) {
    resolve(@{ @"ok": @YES, @"exit_code": @0, @"stdout": @"{}", @"stderr": @"" });
  } else {
    [self.execResolves addObject:[resolve copy]];
  }
}
- (void)shutdownGuestResolve:(void (^)(id))resolve reject:(void (^)(NSString *, NSString *, NSError *))reject {
  self.shutdownCount += 1;
  resolve(@{ @"state": @"stopped" });
  (void)reject;
}
@end

static NSData *Request(NSString *headers, NSString *body) {
  NSMutableData *data = [[headers dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
  [data appendData:[body dataUsingEncoding:NSUTF8StringEncoding]];
  return data;
}

static void Expect(BOOL condition, NSString *name) {
  XCTAssertTrue(condition, @"%@", name);
}

static void WaitUntil(BOOL (^predicate)(void), NSString *name) {
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
  while (!predicate() && [deadline timeIntervalSinceNow] > 0) {
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
  }
  Expect(predicate(), name);
}

static NSInteger CGIRequestStatus(int port, NSString *host, NSString *origin, NSString *cookie, BOOL includeBody, NSString **setCookieOut) {
  int fd = socket(AF_INET, SOCK_STREAM, 0); if (fd < 0) return -1;
  struct timeval timeout = { .tv_sec = 3, .tv_usec = 0 };
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
  struct sockaddr_in address = {}; address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK); address.sin_port = htons((uint16_t)port);
  if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) { close(fd); return -1; }
  NSString *method = includeBody ? @"POST" : @"GET";
  NSString *path = includeBody ? @"/api" : @"/";
  NSData *body = includeBody ? [NSData dataWithBytes:"{}" length:2] : [NSData data];
  NSMutableString *request = [NSMutableString stringWithFormat:@"%@ %@ HTTP/1.1\r\nHost: %@\r\nConnection: close\r\n", method, path, host];
  if (origin) [request appendFormat:@"Origin: %@\r\n", origin];
  if (cookie) [request appendFormat:@"Cookie: %@\r\n", cookie];
  [request appendFormat:@"Content-Length: %lu\r\n\r\n", (unsigned long)body.length];
  NSData *head = [request dataUsingEncoding:NSUTF8StringEncoding];
  if (send(fd, head.bytes, head.length, 0) != (ssize_t)head.length || (body.length && send(fd, body.bytes, body.length, 0) != (ssize_t)body.length)) { close(fd); return -1; }
  NSMutableData *response = [NSMutableData data]; uint8_t buffer[2048]; ssize_t count;
  while ((count = recv(fd, buffer, sizeof(buffer), 0)) > 0) [response appendBytes:buffer length:(NSUInteger)count];
  close(fd);
  NSString *text = [[NSString alloc] initWithData:response encoding:NSUTF8StringEncoding];
  NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\r\n"];
  NSArray *status = lines.count ? [lines[0] componentsSeparatedByString:@" "] : @[];
  if (setCookieOut) for (NSString *line in lines) if ([line.lowercaseString hasPrefix:@"set-cookie:"]) *setCookieOut = [[line substringFromIndex:11] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  return status.count > 1 ? [status[1] integerValue] : -1;
}

static void TestParser(void) {
  RishGuestHttpRequest *request = nil; NSString *error = nil;
  BOOL ok = RishParseGuestHttpRequest(Request(@"GET / HTTP/1.1\r\nHost: 127.0.0.1:4321\r\n\r\n", @""), &request, &error);
  Expect(ok && [request.method isEqualToString:@"GET"] && request.body.length == 0, @"valid GET");
  ok = RishParseGuestHttpRequest(Request(@"POST /api HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\na", @""), &request, &error);
  Expect(!ok && [error containsString:@"duplicate"], @"duplicate Content-Length rejected");
  ok = RishParseGuestHttpRequest(Request(@"POST /api HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n", @""), &request, &error);
  Expect(!ok && [error containsString:@"transfer"], @"Transfer-Encoding rejected");
  ok = RishParseGuestHttpRequest(Request(@"POST /api HTTP/1.1\r\nContent-Length: 1x\r\n\r\na", @""), &request, &error);
  Expect(!ok && [error containsString:@"Content-Length"], @"junk Content-Length rejected");
  ok = RishParseGuestHttpRequest(Request(@"POST /api HTTP/1.1\r\nContent-Length: 1\r\n\r\naX", @""), &request, &error);
  Expect(!ok && [error containsString:@"trailing"], @"trailing bytes rejected");
  ok = RishParseGuestHttpRequest(Request(@"POST /api HTTP/1.1\r\nContent-Length: 65537\r\n\r\n", @""), &request, &error);
  Expect(!ok && [error containsString:@"large"], @"body bound enforced");
  ok = RishParseGuestHttpRequest(Request(@"GET / HTTP/1.1\r\nBad Header: x\r\n\r\n", @""), &request, &error);
  Expect(!ok && [error containsString:@"header"], @"invalid header name rejected");
  NSMutableString *largeHead = [NSMutableString stringWithString:@"GET / HTTP/1.1\r\nHost: 127.0.0.1:4321\r\nX-Pad: "];
  while (largeHead.length < RishGuestHttpMaxHeaderBytes) [largeHead appendString:@"x"];
  [largeHead appendString:@"\r\n\r\n"];
  ok = RishParseGuestHttpRequest([largeHead dataUsingEncoding:NSUTF8StringEncoding], &request, &error);
  Expect(!ok && [error containsString:@"headers"], @"header bound enforced");
}

static void TestStopBeforeBoot(void) {
  FakeGuest *fake = [FakeGuest new];
  __block BOOL startRejected = NO;
  RishGuestCgiService *service = [[RishGuestCgiService alloc] initWithGuestFactoryForTesting:^LocalGuestModule *{
    return fake;
  }];
  [service start:@{ @"indexHtml": @"<h1>ok</h1>", @"backendScript": @"#!/bin/sh\nprintf '{}'" }
      resolve:^(NSDictionary *result) { (void)result; }
       reject:^(NSString *code, NSString *message) { (void)code; (void)message; startRejected = YES; }];
  WaitUntil(^{ return fake.bootResolve != nil; }, @"service uses owned fake guest boot");
  NSString *serviceID = service.status[@"service_id"];
  [service stop:serviceID resolve:^(NSDictionary *result) { (void)result; }
      reject:^(NSString *code, NSString *message) { (void)code; (void)message; }];
  void (^bootResolve)(id) = [fake.bootResolve copy];
  bootResolve(@{ @"state": @"booted" });
  WaitUntil(^{ return fake.shutdownCount == 1; }, @"stop before boot resolves owned shutdown");
  Expect(startRejected, @"stop before boot rejects start");
  Expect([service.status[@"state"] isEqualToString:@"idle"] && service.status[@"url"] == nil,
         @"stop before boot leaves no listener");
  NSUInteger cleanupCount = [fake.commands indexOfObjectPassingTest:^BOOL(NSString *value, NSUInteger index, BOOL *stop) {
    (void)index; (void)stop; return [value containsString:@"rm -rf"];
  }];
  Expect(cleanupCount != NSNotFound, @"stop cleans owned guest root");

}

static void TestStaleExec(void) {
  FakeGuest *staleFake = [FakeGuest new];
  staleFake.holdNextStageExec = YES;
  RishGuestCgiService *staleService = [[RishGuestCgiService alloc] initWithGuestFactoryForTesting:^LocalGuestModule *{
    return staleFake;
  }];
  [staleService start:@{ @"indexHtml": @"x", @"backendScript": @"y" } resolve:^(NSDictionary *result) { (void)result; } reject:^(NSString *code, NSString *message) { (void)code; (void)message; }];
  WaitUntil(^{ return staleFake.bootResolve != nil; }, @"stale test boot callback captured");
  void (^staleBootResolve)(id) = [staleFake.bootResolve copy];
  staleBootResolve(@{ @"state": @"booted" });
  WaitUntil(^{ return staleFake.execResolves.count > 0; }, @"stale test stage exec captured");
  void (^staleResolve)(id) = [staleFake.execResolves.firstObject copy];
  NSString *staleID = staleService.status[@"service_id"];
  [staleService stop:staleID resolve:^(NSDictionary *result) { (void)result; } reject:^(NSString *code, NSString *message) { (void)code; (void)message; }];
  WaitUntil(^{ return staleFake.shutdownCount == 1; }, @"stale test service stopped");
  staleResolve(@{ @"ok": @YES, @"exit_code": @0, @"stdout": @"", @"stderr": @"" });
  Expect([staleService.status[@"state"] isEqualToString:@"idle"] && staleService.status[@"url"] == nil,
         @"stale exec cannot write listener state");

}

static void TestDeallocOwnedGuest(void) {
  FakeGuest *deallocFake = [FakeGuest new];
  deallocFake.holdNextStageExec = YES;
  __weak RishGuestCgiService *weakService = nil;
  @autoreleasepool {
    RishGuestCgiService *ownedService = [[RishGuestCgiService alloc] initWithGuestFactoryForTesting:^LocalGuestModule *{ return deallocFake; }];
    weakService = ownedService;
    [ownedService start:@{ @"indexHtml": @"x", @"backendScript": @"y" } resolve:^(NSDictionary *result) { (void)result; } reject:^(NSString *code, NSString *message) { (void)code; (void)message; }];
    WaitUntil(^{ return deallocFake.bootResolve != nil; }, @"dealloc test boot callback captured");
    void (^deallocBootResolve)(id) = [deallocFake.bootResolve copy];
    deallocBootResolve(@{ @"state": @"booted" });
    WaitUntil(^{ return deallocFake.shutdownCount == 0 && deallocFake.execResolves.count > 0; }, @"dealloc test owns booted guest");
  }
  WaitUntil(^{ return deallocFake.shutdownCount == 1; }, @"dealloc shuts down owned guest");
  Expect(weakService == nil, @"service deallocated after owned shutdown");
}

static void TestBackgroundNotification(void) {
  FakeGuest *fake = [FakeGuest new];
  RishGuestCgiService *service = [[RishGuestCgiService alloc] initWithGuestFactoryForTesting:^LocalGuestModule *{ return fake; }];
  [service start:@{ @"indexHtml": @"x", @"backendScript": @"y" } resolve:^(NSDictionary *result) { (void)result; } reject:^(NSString *code, NSString *message) { (void)code; (void)message; }];
  WaitUntil(^{ return fake.bootResolve != nil; }, @"background test boot callback captured");
  [[NSNotificationCenter defaultCenter] postNotificationName:UIApplicationDidEnterBackgroundNotification object:nil];
  void (^backgroundBootResolve)(id) = [fake.bootResolve copy];
  backgroundBootResolve(@{ @"state": @"booted" });
  WaitUntil(^{ return fake.shutdownCount == 1; }, @"background notification shuts down owned guest");
  Expect([service.status[@"state"] isEqualToString:@"idle"] && service.status[@"url"] == nil,
         @"background notification leaves no listener");
}

static void TestCookiePolicyWithRealService(void) {
  FakeGuest *fake = [FakeGuest new];
  RishGuestCgiService *service = [[RishGuestCgiService alloc] initWithGuestFactoryForTesting:^LocalGuestModule *{ return fake; }];
  __block BOOL started = NO;
  [service start:@{ @"indexHtml": @"<p>ok</p>", @"backendScript": @"#!/bin/sh\nprintf '{}'" }
      resolve:^(NSDictionary *result) { (void)result; started = YES; }
       reject:^(NSString *code, NSString *message) { (void)code; (void)message; }];
  WaitUntil(^{ return fake.bootResolve != nil; }, @"cookie policy boot callback captured");
  void (^bootResolve)(id) = [fake.bootResolve copy]; bootResolve(@{ @"state": @"booted" });
  WaitUntil(^{ return started; }, @"cookie policy service listener running");
  NSDictionary *status = service.status;
  NSURLComponents *url = [NSURLComponents componentsWithString:status[@"url"]];
  int port = (int)url.port.integerValue;
  NSString *host = [NSString stringWithFormat:@"127.0.0.1:%d", port];
  NSString *origin = [NSString stringWithFormat:@"http://%@", host];
  NSString *setCookie = nil;
  Expect(CGIRequestStatus(port, host, nil, nil, NO, &setCookie) == 200 && setCookie.length > 0, @"cookie policy GET sets cookie");
  NSString *ownCookie = [setCookie componentsSeparatedByString:@";"].firstObject;
  Expect(CGIRequestStatus(port, host, origin, [NSString stringWithFormat:@"other=1; %@; theme=dark", ownCookie], YES, NULL) == 200, @"extra unrelated cookies accepted");
  Expect(CGIRequestStatus(port, host, origin, [NSString stringWithFormat:@"%@; rish_cgi=wrong", ownCookie], YES, NULL) == 403, @"duplicate own cookie rejected");
  Expect(CGIRequestStatus(port, host, origin, @"rish_cgi=wrong; other=1", YES, NULL) == 403, @"wrong own cookie rejected");
  Expect(CGIRequestStatus(port, host, @"http://evil.invalid", ownCookie, YES, NULL) == 403, @"cross-origin rejected");
  NSString *serviceID = status[@"service_id"];
  [service stop:serviceID resolve:^(NSDictionary *result) { (void)result; } reject:^(NSString *code, NSString *message) { (void)code; (void)message; }];
  WaitUntil(^{ return [service.status[@"state"] isEqualToString:@"idle"]; }, @"cookie policy service stopped");
}

static void TestFinitePreviewLease(NSUInteger scenario) {
  FakeGuest *fake = [FakeGuest new];
  RishGuestCgiService *service = [[RishGuestCgiService alloc] initWithGuestFactoryForTesting:^LocalGuestModule *{ return fake; }];
  __block NSUInteger begins = 0, ends = 0;
  __block void (^expiration)(void);
  [service setPreviewTaskForTesting:^UIBackgroundTaskIdentifier(void (^handler)(void)) {
    Expect(NSThread.isMainThread, @"begin lease must be main");
    begins++; expiration = handler;
    return scenario == 0 ? UIBackgroundTaskInvalid : (UIBackgroundTaskIdentifier)42;
  } end:^(UIBackgroundTaskIdentifier task) {
    Expect(NSThread.isMainThread && task == 42, @"end lease must be main and owned"); ends++;
  } limit:(scenario == 3 || scenario == 2 ? 0.08 : 2.0)];
  __block BOOL started = NO;
  [service start:@{ @"indexHtml": @"<p>preview</p>", @"backendScript": @"#!/bin/sh\nprintf '{}'" } resolve:^(NSDictionary *result) { started = YES; } reject:^(NSString *code, NSString *message) {}];
  WaitUntil(^{ return fake.bootResolve != nil; }, @"preview boot requested");
  fake.bootResolve(@{ @"state": @"booted" });
  WaitUntil(^{ return started; }, @"preview running");
  NSString *serviceID = service.status[@"service_id"];
  [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidEnterBackgroundNotification object:nil];
  WaitUntil(^{ return begins == 1; }, @"preview grant attempted");
  if (scenario == 0) {
    WaitUntil(^{ return fake.shutdownCount == 1; }, @"denied preview stops guest");
    Expect(ends == 0, @"invalid task never ended"); return;
  }
  if (scenario == 2) {
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationWillEnterForegroundNotification object:nil];
    WaitUntil(^{ return ends == 1; }, @"foreground releases grant");
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.15]];
    Expect([service.status[@"state"] isEqual:@"running"] && fake.shutdownCount == 0, @"cancelled preview timer cannot stop foreground service");
  } else if (scenario == 1) {
    Expect([service.status[@"state"] isEqual:@"running"], @"valid grant preserves listener");
    expiration();
    Expect(ends == 1, @"system expiration ends its UIKit task before returning");
    Expect(service.status[@"url"] == nil, @"system expiration closes listener before returning");
    expiration();
    WaitUntil(^{ return fake.shutdownCount == 1 && ends == 1; }, @"expiration stops and releases exactly once");
    Expect(service.status[@"url"] == nil, @"expired listener closed"); return;
  } else if (scenario == 3) {
    WaitUntil(^{ return fake.shutdownCount == 1 && ends == 1; }, @"hard preview deadline stops and releases"); return;
  }
  [service stop:serviceID resolve:^(NSDictionary *result) {} reject:^(NSString *code, NSString *message) {}];
  WaitUntil(^{ return fake.shutdownCount == 1 && ends == 1; }, @"explicit stop releases lease once");
  if (expiration) expiration();
  Expect(ends == 1, @"late expiry does not double-end task");
}

@interface RishGuestCgiHTTPTests : XCTestCase
@end

@implementation RishGuestCgiHTTPTests
- (void)testSystemExpirationFlushesPreviouslyQueuedMainEnd {
  RishCgiPreviewLease *lease = [RishCgiPreviewLease new];
  lease.identifier = 42;
  __block NSUInteger ends = 0;
  lease.endTask = ^(UIBackgroundTaskIdentifier task) { XCTAssertTrue(NSThread.isMainThread); XCTAssertEqual(task, (UIBackgroundTaskIdentifier)42); ends++; };
  dispatch_semaphore_t queued = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ [lease finish]; dispatch_semaphore_signal(queued); });
  XCTAssertEqual(dispatch_semaphore_wait(queued, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)), 0L);
  XCTAssertEqual(ends, 0U);
  // Simulate the OS expiry handler before the queued main cleanup can run.
  [lease finish];
  XCTAssertEqual(ends, 1U);
  [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
  XCTAssertEqual(ends, 1U);
}
- (void)testFinitePreviewUsesOnlyGrantedBudgetWithinHardCap {
  RishGuestCgiService *service = [RishGuestCgiService new];
  XCTAssertEqualWithAccuracy([service previewDurationForTesting:30], 25, 0.001);
  XCTAssertEqualWithAccuracy([service previewDurationForTesting:90], 85, 0.001);
  XCTAssertEqualWithAccuracy([service previewDurationForTesting:180], 115, 0.001);
  XCTAssertEqualWithAccuracy([service previewDurationForTesting:INFINITY], 115, 0.001);
  XCTAssertEqual([service previewDurationForTesting:5], 0);
  XCTAssertEqual([service previewDurationForTesting:-1], 0);
  XCTAssertEqual([service previewDurationForTesting:NAN], 0);
}
- (void)testFinitePreviewRejectsDeniedBackgroundGrant { TestFinitePreviewLease(0); }
- (void)testFinitePreviewSystemExpirationStopsOwnedService { TestFinitePreviewLease(1); }
- (void)testFinitePreviewForegroundCancelsOldDeadline { TestFinitePreviewLease(2); }
- (void)testFinitePreviewHardDeadlineStopsOwnedService { TestFinitePreviewLease(3); }
- (void)testFinitePreviewExplicitStopEndsGrantOnce { TestFinitePreviewLease(4); }
- (void)testHTTPParserBoundariesAndRejections { TestParser(); }
- (void)testServiceStopBeforeBootCleansOwnedGuest { TestStopBeforeBoot(); }
- (void)testServiceDropsStaleExecAfterStop { TestStaleExec(); }
- (void)testServiceDeallocShutsDownOwnedGuest { TestDeallocOwnedGuest(); }
- (void)testServiceBackgroundNotificationStopsGuest { TestBackgroundNotification(); }
- (void)testServiceCookiePolicyAllowsUnrelatedCookiesOnly { TestCookiePolicyWithRealService(); }
@end
