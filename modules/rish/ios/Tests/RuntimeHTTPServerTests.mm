#import <XCTest/XCTest.h>
#import "../../../../modules/rish/ios/Sources/RuntimeHTTPServer.h"
#import "../../../../modules/rish/ios/Sources/RishGuestCgiHTTP.h"
#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>

@interface RuntimeHTTPServerTests : XCTestCase
@property(nonatomic, strong) DSHRuntimeHTTPServer *server;
@end

@implementation RuntimeHTTPServerTests
- (void)tearDown { [self.server stop]; self.server = nil; [super tearDown]; }
- (NSData *)bytes:(NSString *)value { return [value dataUsingEncoding:NSUTF8StringEncoding]; }
- (NSString *)text:(NSData *)value { return [[NSString alloc] initWithData:value encoding:NSISOLatin1StringEncoding]; }
- (void)start:(DSHRuntimeHTTPRequestHandler)handler {
  self.server = [[DSHRuntimeHTTPServer alloc] initWithRequestHandler:handler];
  NSError *error = nil;
  XCTAssertTrue([self.server startWithError:&error]); XCTAssertNil(error);
  XCTAssertEqualObjects(self.server.url.host, @"127.0.0.1");
  XCTAssertGreaterThan(self.server.url.port.integerValue, 0);
}
- (int)connectURL:(NSURL *)url {
  int fd = socket(AF_INET, SOCK_STREAM, 0); XCTAssertGreaterThanOrEqual(fd, 0);
  int yes = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
  struct timeval timeout = { 8, 0 };
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
  struct sockaddr_in address = {};
  address.sin_len = sizeof(address); address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  address.sin_port = htons(url.port.unsignedShortValue);
  XCTAssertEqual(connect(fd, (struct sockaddr *)&address, sizeof(address)), 0);
  return fd;
}
- (NSData *)receive:(int)fd {
  NSMutableData *data = [NSMutableData data]; uint8_t buffer[4096];
  while (true) {
    ssize_t count = recv(fd, buffer, sizeof(buffer), 0);
    if (count <= 0) { XCTAssertTrue(count == 0 || errno == ECONNRESET, @"errno %d", errno); break; }
    [data appendBytes:buffer length:(NSUInteger)count];
    XCTAssertLessThanOrEqual(data.length, 2U * 1024 * 1024);
    if (data.length > 2 * 1024 * 1024) break;
  }
  return data;
}
- (NSData *)exchange:(NSData *)request url:(NSURL *)url {
  int fd = [self connectURL:url]; NSUInteger offset = 0;
  while (offset < request.length) {
    ssize_t count = send(fd, (const uint8_t *)request.bytes + offset, request.length - offset, 0);
    if (count <= 0) break;
    offset += (NSUInteger)count;
  }
  shutdown(fd, SHUT_WR);
  NSData *response = [self receive:fd]; close(fd); return response;
}
- (NSString *)authority { return [NSString stringWithFormat:@"127.0.0.1:%@", self.server.url.port]; }
- (NSData *)get:(NSString *)path {
  return [self bytes:[NSString stringWithFormat:@"GET %@ HTTP/1.1\r\nHost: %@\r\nConnection: keep-alive\r\n\r\n", path, [self authority]]];
}
- (NSString *)bridgeCookie:(NSData *)response {
  for (NSString *line in [[self text:response] componentsSeparatedByString:@"\r\n"]) {
    if ([line hasPrefix:@"Set-Cookie: rish_runtime_"]) {
      return [[[line substringFromIndex:12] componentsSeparatedByString:@";"] firstObject];
    }
  }
  XCTFail(@"missing bridge cookie"); return @"";
}
- (void)testLoopbackForwardsGETQueryBinaryStatusAndRepeatedSetCookieHeaders {
  uint8_t raw[] = {0, 255, 128, 42}; NSData *binary = [NSData dataWithBytes:raw length:sizeof(raw)];
  NSMutableData *appResponse = [[self bytes:@"HTTP/1.1 201 Created\r\nContent-Length: 4\r\nContent-Type: application/octet-stream\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\nConnection: keep-alive\r\n\r\n"] mutableCopy];
  [appResponse appendData:binary];
  XCTestExpectation *forwarded = [self expectationWithDescription:@"real GET"];
  [self start:^(NSData *request, DSHRuntimeHTTPCompletion completion) {
    RishGuestHttpRequest *parsed = nil;
    XCTAssertTrue(RishParseGuestHttpRequest(request, &parsed, nil));
    XCTAssertEqualObjects(parsed.path, @"/assets/icon.bin?q=%E4%B8%AD&x=1");
    XCTAssertEqualObjects(parsed.headers[@"connection"], @"close");
    [forwarded fulfill]; completion(appResponse, nil);
  }];
  NSData *response = [self exchange:[self get:@"/assets/icon.bin?q=%E4%B8%AD&x=1"] url:self.server.url];
  XCTAssertTrue([[self text:response] hasPrefix:@"HTTP/1.1 201 Created\r\n"]);
  XCTAssertTrue([[self text:response] containsString:@"Set-Cookie: a=1\r\nSet-Cookie: b=2\r\n"]);
  XCTAssertEqualObjects([response subdataWithRange:NSMakeRange(response.length - 4, 4)], binary);
  XCTAssertFalse([[self text:response] containsString:@"keep-alive"]);
  XCTAssertTrue([[self text:response] containsString:@"SameSite=Strict"]);
  [self waitForExpectations:@[forwarded] timeout:2];
}
- (void)testPOSTRequiresSameOriginCookieAndForwardsBinaryBody {
  uint8_t raw[] = {0, 255, '\r', '\n', 42}; NSData *binary = [NSData dataWithBytes:raw length:sizeof(raw)];
  XCTestExpectation *posted = [self expectationWithDescription:@"real POST"];
  NSData *okay = [self bytes:@"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"];
  [self start:^(NSData *request, DSHRuntimeHTTPCompletion completion) {
    RishGuestHttpRequest *parsed = nil;
    XCTAssertTrue(RishParseGuestHttpRequest(request, &parsed, nil));
    if ([parsed.method isEqual:@"POST"]) {
      XCTAssertEqualObjects(parsed.path, @"/api?replace=1"); XCTAssertEqualObjects(parsed.body, binary);
      [posted fulfill];
    }
    completion(okay, nil);
  }];
  NSString *cookie = [self bridgeCookie:[self exchange:[self get:@"/"] url:self.server.url]];
  for (NSString *origin in @[@"https://evil.example", @"null", @""]) {
    NSData *request = [self bytes:[NSString stringWithFormat:
        @"POST /api HTTP/1.1\r\nHost: %@\r\nOrigin: %@\r\nCookie: %@\r\nContent-Length: 0\r\n\r\n", [self authority], origin, cookie]];
    XCTAssertTrue([[self text:[self exchange:request url:self.server.url]] hasPrefix:@"HTTP/1.1 403 "]);
  }
  NSMutableData *request = [[self bytes:[NSString stringWithFormat:
      @"POST /api?replace=1 HTTP/1.1\r\nHost: %@\r\nOrigin: http://%@\r\nCookie: %@; app=kept\r\nContent-Length: 5\r\n\r\n", [self authority], [self authority], cookie]] mutableCopy];
  [request appendData:binary];
  XCTAssertTrue([[self text:[self exchange:request url:self.server.url]] hasSuffix:@"\r\n\r\nok"]);
  [self waitForExpectations:@[posted] timeout:2];
}
- (void)testMalformedAndOversizedRequestsNeverReachGuest {
  [self start:^(NSData *request, DSHRuntimeHTTPCompletion completion) { XCTFail(@"invalid request forwarded"); completion(nil, nil); }];
  NSString *host = [self authority];
  NSArray *requests = @[
    @"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n",
    [NSString stringWithFormat:@"GET / HTTP/1.1\r\nHost: %@\r\nOrigin: https://evil.example\r\n\r\n", host],
    [NSString stringWithFormat:@"POST / HTTP/1.1\r\nHost: %@\r\nOrigin: http://%@\r\nContent-Length: 0\r\n\r\n", host, host],
    [NSString stringWithFormat:@"CONNECT / HTTP/1.1\r\nHost: %@\r\n\r\n", host],
    [NSString stringWithFormat:@"GET / HTTP/1.1\r\nHost: %@\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n", host],
    [NSString stringWithFormat:@"GET / HTTP/1.1\r\nHost: %@\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n", host],
    [NSString stringWithFormat:@"POST / HTTP/1.1\r\nHost: %@\r\nTransfer-Encoding: chunked\r\nContent-Length: 0\r\n\r\n", host],
    [NSString stringWithFormat:@"GET / HTTP/1.1\r\nHost: %@\r\nX-Test: okay\rbad\r\n\r\n", host],
    [NSString stringWithFormat:@"GET / HTTP/1.1\r\nHost: %@\r\n\r\nGET /second HTTP/1.1\r\n\r\n", host],
    [NSString stringWithFormat:@"POST / HTTP/1.1\r\nHost: %@\r\nContent-Length: 65537\r\n\r\n", host],
    [NSString stringWithFormat:@"GET / HTTP/1.1\r\nHost: %@\r\nX-Long: %@\r\n\r\n", host, [@"a" stringByPaddingToLength:17000 withString:@"a" startingAtIndex:0]],
  ];
  for (NSString *request in requests) {
    NSString *response = [self text:[self exchange:[self bytes:request] url:self.server.url]];
    XCTAssertTrue([response hasPrefix:@"HTTP/1.1 4"], @"%@", response);
  }
}
- (void)testResponseValidationPreservesChunkedBinaryAndNoBodySemantics {
  uint8_t raw[] = {0, 255, 128};
  NSMutableData *chunked = [[self bytes:@"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3;tag=ok\r\n"] mutableCopy];
  [chunked appendBytes:raw length:3]; [chunked appendData:[self bytes:@"\r\n0\r\nX-Checksum: abc\r\n\r\n"]];
  for (NSArray *row in @[
    @[chunked, @"GET"],
    @[[self bytes:@"HTTP/1.1 200 OK\r\nContent-Length: 9999999\r\n\r\n"], @"HEAD"],
    @[[self bytes:@"HTTP/1.1 204 No Content\r\n\r\n"], @"GET"],
    @[[self bytes:@"HTTP/1.1 304 Not Modified\r\nContent-Length: 42\r\nETag: a\r\n\r\n"], @"GET"],
    @[[self bytes:@"HTTP/1.0 404 Missing\r\nContent-Type: text/plain\r\n\r\nactual app error"], @"GET"],
  ]) {
    NSError *error = nil;
    NSData *valid = [DSHRuntimeHTTPServer validateResponse:row[0] requestMethod:row[1] error:&error];
    XCTAssertNotNil(valid, @"%@", error); XCTAssertNil(error);
    XCTAssertTrue([[self text:valid] containsString:@"Connection: close\r\n"]);
  }
  NSData *valid = [DSHRuntimeHTTPServer validateResponse:chunked requestMethod:@"GET" error:nil];
  NSRange originalEnd = [chunked rangeOfData:[self bytes:@"\r\n\r\n"] options:0 range:NSMakeRange(0, chunked.length)];
  NSRange validatedEnd = [valid rangeOfData:[self bytes:@"\r\n\r\n"] options:0 range:NSMakeRange(0, valid.length)];
  XCTAssertEqualObjects([valid subdataWithRange:NSMakeRange(NSMaxRange(validatedEnd), valid.length - NSMaxRange(validatedEnd))],
      [chunked subdataWithRange:NSMakeRange(NSMaxRange(originalEnd), chunked.length - NSMaxRange(originalEnd))]);
}
- (void)testResponseValidationRejectsSmugglingTruncationUpgradeAndOversize {
  NSArray *invalid = @[
    @"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nx",
    @"HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nxx",
    @"HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx",
    @"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
    @"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nxx\r\n0\r\n\r\n",
    @"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\ntrailing",
    @"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0;bad=\r\n\r\n",
    @"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0;bad=\"unclosed\r\n\r\n",
    @"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nContent-Length: 0\r\n\r\n",
    @"HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\n",
    @"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n",
    @"HTTP/1.1 200 OK\r\nConnection: Content-Length\r\nContent-Length: 0\r\n\r\n",
    @"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n",
    @"HTTP/1.1 304 Not Modified\r\n\r\nx",
    @"HTTP/1.1 200 OK\r\nX-A: a\nb\r\n\r\n",
  ];
  for (NSString *raw in invalid) {
    NSError *error = nil;
    XCTAssertNil([DSHRuntimeHTTPServer validateResponse:[self bytes:raw] requestMethod:@"GET" error:&error], @"%@", raw);
    XCTAssertNotNil(error);
  }
  XCTAssertNil([DSHRuntimeHTTPServer validateResponse:[self bytes:@"HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nx"] requestMethod:@"HEAD" error:nil]);
  NSMutableData *huge = [[self bytes:@"HTTP/1.1 200 OK\r\n\r\n"] mutableCopy];
  [huge increaseLengthBy:1024 * 1024];
  XCTAssertNil([DSHRuntimeHTTPServer validateResponse:huge requestMethod:@"GET" error:nil]);
}
- (void)testInvalidGuestResponseBecomesBadGateway {
  [self start:^(NSData *request, DSHRuntimeHTTPCompletion completion) {
    completion([@"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nx" dataUsingEncoding:NSUTF8StringEncoding], nil);
  }];
  XCTAssertTrue([[self text:[self exchange:[self get:@"/"] url:self.server.url]] hasPrefix:@"HTTP/1.1 502 "]);
}
- (void)testStopClosesPendingRequestAndLateCallbackCannotWriteAfterRestart {
  NSLock *lock = [NSLock new]; __block DSHRuntimeHTTPCompletion delayed = nil;
  dispatch_semaphore_t called = dispatch_semaphore_create(0);
  NSData *fresh = [self bytes:@"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nfresh"];
  [self start:^(NSData *request, DSHRuntimeHTTPCompletion completion) {
    [lock lock]; BOOL first = delayed == nil;
    if (first) delayed = [completion copy];
    [lock unlock];
    if (first) dispatch_semaphore_signal(called); else completion(fresh, nil);
  }];
  int old = [self connectURL:self.server.url]; NSData *request = [self get:@"/old"];
  XCTAssertEqual(send(old, request.bytes, request.length, 0), (ssize_t)request.length);
  XCTAssertEqual(dispatch_semaphore_wait(called, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)), 0L);
  [self.server stop]; XCTAssertNil(self.server.url);
  XCTAssertEqual([self receive:old].length, 0U); close(old);
  XCTAssertTrue([self.server startWithError:nil]);
  [lock lock]; DSHRuntimeHTTPCompletion callback = delayed; [lock unlock];
  callback([self bytes:@"HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nold"], nil);
  NSData *response = [self exchange:[self get:@"/new"] url:self.server.url];
  XCTAssertTrue([[self text:response] hasSuffix:@"\r\n\r\nfresh"]);
  callback(fresh, nil);
  [self.server stop];
}
- (void)testIncompleteRequestHasBoundedDeadline {
  [self start:^(NSData *request, DSHRuntimeHTTPCompletion completion) { XCTFail(@"partial request forwarded"); }];
  int fd = [self connectURL:self.server.url];
  NSData *partial = [self bytes:@"GET / HTTP/1.1\r\n"];
  XCTAssertEqual(send(fd, partial.bytes, partial.length, 0), (ssize_t)partial.length);
  NSTimeInterval before = NSProcessInfo.processInfo.systemUptime;
  NSData *response = [self receive:fd]; close(fd);
  XCTAssertTrue([[self text:response] hasPrefix:@"HTTP/1.1 408 "]);
  XCTAssertLessThan(NSProcessInfo.processInfo.systemUptime - before, 8.0);
}
- (void)testConnectionLimitRefusesAdditionalPendingClients {
  dispatch_semaphore_t called = dispatch_semaphore_create(0);
  [self start:^(NSData *request, DSHRuntimeHTTPCompletion completion) { dispatch_semaphore_signal(called); }];
  NSMutableArray<NSNumber *> *fds = [NSMutableArray array];
  @try {
    for (NSUInteger i = 0; i < 8; i++) {
      int fd = [self connectURL:self.server.url]; [fds addObject:@(fd)];
      NSData *request = [self get:@"/pending"];
      XCTAssertEqual(send(fd, request.bytes, request.length, 0), (ssize_t)request.length);
      XCTAssertEqual(dispatch_semaphore_wait(called, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)), 0L);
    }
    int extra = [self connectURL:self.server.url];
    XCTAssertEqual([self receive:extra].length, 0U); close(extra);
    [self.server stop];
    for (NSNumber *fd in fds) XCTAssertEqual([self receive:fd.intValue].length, 0U);
  } @finally { for (NSNumber *fd in fds) close(fd.intValue); }
}
@end
