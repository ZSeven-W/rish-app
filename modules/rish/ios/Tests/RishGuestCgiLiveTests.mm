#import <XCTest/XCTest.h>

#import <CommonCrypto/CommonDigest.h>
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <math.h>
#import <poll.h>
#import <netinet/in.h>
#import <string.h>
#import <sys/socket.h>
#import <unistd.h>

#import "RishGuestCgiService.h"
#import "AgentToolRegistry.h"

static NSData *RishCGISHA256(NSData *data) {
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  NSMutableData *result = [NSMutableData dataWithLength:CC_SHA256_DIGEST_LENGTH];
  memcpy(result.mutableBytes, digest, CC_SHA256_DIGEST_LENGTH);
  return result;
}

static NSString *RishCGIHex(NSData *data) {
  const unsigned char *bytes = (const unsigned char *)data.bytes;
  NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
  for (NSUInteger i = 0; i < data.length; i++) [hex appendFormat:@"%02x", bytes[i]];
  return hex;
}

// The software guest stages, executes and cleans up in separate exchanges.
// Bound that whole HTTP operation in host monotonic time; the backend's guest
// shell timeout is a separate production limit and is deliberately unchanged.
static NSTimeInterval const RishCGIHTTPDeadline = 60.0;
static NSUInteger const RishCGIMaxHTTPResponse = 1024 * 1024 + 16 * 1024;

struct RishCGISocket {
  int descriptor;
  ~RishCGISocket() { if (descriptor >= 0) close(descriptor); }
};

static BOOL RishCGIWaitSocket(int fd, short events, NSTimeInterval deadline) {
  while (YES) {
    NSTimeInterval remaining = deadline - NSProcessInfo.processInfo.systemUptime;
    if (remaining <= 0) return NO;
    struct pollfd item = { .fd = fd, .events = events, .revents = 0 };
    int result = poll(&item, 1, (int)ceil(MIN(remaining, 60.0) * 1000));
    if (result < 0 && errno == EINTR) continue;
    if (result <= 0 || NSProcessInfo.processInfo.systemUptime >= deadline) return NO;
    return (item.revents & (events | POLLHUP | POLLERR)) != 0;
  }
}

static BOOL RishCGISendAll(int fd, const uint8_t *bytes, NSUInteger length,
                          NSTimeInterval deadline) {
  NSUInteger offset = 0;
  while (offset < length) {
    if (!RishCGIWaitSocket(fd, POLLOUT, deadline)) return NO;
    ssize_t sent = send(fd, bytes + offset, length - offset, 0);
    if (sent < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
    if (sent <= 0) return NO;
    offset += (NSUInteger)sent;
  }
  return YES;
}

static NSData *RishCGIHTTP(int port, NSString *host, NSString *origin,
                           NSString *cookie, NSString *method, NSString *path,
                           NSData *body, NSTimeInterval timeout,
                           NSInteger *statusOut,
                           NSDictionary<NSString *, NSString *> **headersOut) {
  if (statusOut) *statusOut = 0;
  if (headersOut) *headersOut = nil;
  NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + timeout;
  RishCGISocket socketOwner = { socket(AF_INET, SOCK_STREAM, 0) };
  int fd = socketOwner.descriptor;
  if (fd < 0 || !isfinite(timeout) || timeout <= 0) return nil;
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0) return nil;
#ifdef SO_NOSIGPIPE
  int noSigPipe = 1;
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
#endif
  struct sockaddr_in address = {};
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  address.sin_port = htons((uint16_t)port);
  if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
    if (errno != EINPROGRESS || !RishCGIWaitSocket(fd, POLLOUT, deadline)) return nil;
    int error = 0; socklen_t length = sizeof(error);
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) != 0 || error != 0) return nil;
  }
  NSMutableString *request = [NSMutableString stringWithFormat:
      @"%@ %@ HTTP/1.1\r\nHost: %@\r\nConnection: close\r\n", method, path, host];
  if (origin) [request appendFormat:@"Origin: %@\r\n", origin];
  if (cookie) [request appendFormat:@"Cookie: %@\r\n", cookie];
  [request appendFormat:@"Content-Length: %lu\r\n\r\n", (unsigned long)body.length];
  NSData *head = [request dataUsingEncoding:NSUTF8StringEncoding];
  if (!RishCGISendAll(fd, (const uint8_t *)head.bytes, head.length, deadline) ||
      !RishCGISendAll(fd, (const uint8_t *)body.bytes, body.length, deadline)) return nil;
  NSMutableData *response = [NSMutableData data];
  uint8_t buffer[4096];
  while (YES) {
    if (!RishCGIWaitSocket(fd, POLLIN, deadline)) return nil;
    ssize_t count = recv(fd, buffer, sizeof(buffer), 0);
    if (count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
    if (count < 0) return nil;
    if (count == 0) break;
    if (response.length > RishCGIMaxHTTPResponse - (NSUInteger)count) return nil;
    [response appendBytes:buffer length:(NSUInteger)count];
  }
  const uint8_t *bytes = (const uint8_t *)response.bytes;
  NSUInteger end = NSNotFound;
  for (NSUInteger i = 3; i < response.length; i++) {
    if (bytes[i - 3] == '\r' && bytes[i - 2] == '\n' && bytes[i - 1] == '\r' && bytes[i] == '\n') { end = i + 1; break; }
  }
  if (end == NSNotFound || end > 16 * 1024) return nil;
  NSString *headString = [[NSString alloc] initWithBytes:bytes length:end encoding:NSUTF8StringEncoding];
  NSArray<NSString *> *lines = [headString componentsSeparatedByString:@"\r\n"];
  NSArray<NSString *> *statusParts = [lines.firstObject componentsSeparatedByString:@" "];
  if (statusParts.count < 2) return nil;
  NSInteger status = statusParts[1].integerValue;
  if (status < 100 || status > 599) return nil;
  NSMutableDictionary *headers = [NSMutableDictionary dictionary];
  for (NSUInteger i = 1; i + 2 < lines.count; i++) {
    NSRange colon = [lines[i] rangeOfString:@":"];
    if (colon.location == NSNotFound) return nil;
    NSString *name = [lines[i] substringToIndex:colon.location].lowercaseString;
    if (headers[name] != nil) return nil;
    headers[name] = [[lines[i] substringFromIndex:colon.location + 1]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  }
  NSString *lengthText = headers[@"content-length"];
  if (lengthText.length == 0 || [lengthText rangeOfCharacterFromSet:
      NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound) return nil;
  unsigned long long contentLength = strtoull(lengthText.UTF8String, NULL, 10);
  if (contentLength > RishCGIMaxHTTPResponse || response.length - end != contentLength) return nil;
  if (NSProcessInfo.processInfo.systemUptime >= deadline) return nil;
  // Publish status and headers only after the complete declared body arrives.
  if (statusOut) *statusOut = status;
  if (headersOut) *headersOut = [headers copy];
  return [response subdataWithRange:NSMakeRange(end, (NSUInteger)contentLength)];
}

static BOOL RishCGIWait(BOOL (^predicate)(void), NSTimeInterval timeout) {
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  while (!predicate() && [deadline timeIntervalSinceNow] > 0) {
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  }
  return predicate();
}

@interface RishGuestCgiLiveTests : XCTestCase
@end

@implementation RishGuestCgiLiveTests

- (NSData *)httpAtPort:(int)port host:(NSString *)host origin:(NSString *)origin
               cookie:(NSString *)cookie method:(NSString *)method path:(NSString *)path
                 body:(NSData *)body timeout:(NSTimeInterval)timeout label:(NSString *)label
               status:(NSInteger *)statusOut headers:(NSDictionary **)headersOut {
  if (statusOut) *statusOut = 0;
  if (headersOut) *headersOut = nil;
  __block NSData *bodyResult = nil;
  __block NSInteger status = 0;
  __block NSDictionary *headers = nil;
  XCTestExpectation *done = [self expectationWithDescription:label];
  NSTimeInterval began = NSProcessInfo.processInfo.systemUptime;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSInteger receivedStatus = 0;
    NSDictionary *receivedHeaders = nil;
    NSTimeInterval remaining = MAX(0, timeout - (NSProcessInfo.processInfo.systemUptime - began));
    NSData *receivedBody = RishCGIHTTP(port, host, origin, cookie, method, path, body,
                                      remaining, &receivedStatus, &receivedHeaders);
    NSLog(@"Rish CGI live step=%@ elapsed=%.3f status=%ld body_bytes=%lu", label,
        NSProcessInfo.processInfo.systemUptime - began, (long)receivedStatus,
        (unsigned long)receivedBody.length);
    @synchronized(done) {
      bodyResult = receivedBody; status = receivedStatus; headers = receivedHeaders;
    }
    [done fulfill];
  });
  // XCTest runs the main run loop while the bounded socket operation waits.
  [self waitForExpectations:@[done] timeout:timeout + 5.0];
  @synchronized(done) {
    if (statusOut) *statusOut = status;
    if (headersOut) *headersOut = headers;
    return bodyResult;
  }
}

- (void)testHTTPClientHonorsWholeRequestDeadlineAndRejectsTruncation {
  for (NSString *scenario in @[@"delayed_complete", @"whole_deadline", @"truncated_body"]) {
    RishCGISocket listener = { socket(AF_INET, SOCK_STREAM, 0) };
    XCTAssertGreaterThanOrEqual(listener.descriptor, 0);
    if (listener.descriptor < 0) return;
    struct sockaddr_in address = {};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    XCTAssertEqual(bind(listener.descriptor, (struct sockaddr *)&address, sizeof(address)), 0);
    XCTAssertEqual(listen(listener.descriptor, 1), 0);
    socklen_t addressLength = sizeof(address);
    XCTAssertEqual(getsockname(listener.descriptor, (struct sockaddr *)&address, &addressLength), 0);
    int port = ntohs(address.sin_port);
    int listenerFD = listener.descriptor;
    XCTestExpectation *serverDone = [self expectationWithDescription:@"loopback server completed"];
    __block BOOL accepted = NO;
    __block BOOL sentHead = NO;
    __block NSUInteger sentChunks = 0;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      if (RishCGIWaitSocket(listenerFD, POLLIN, NSProcessInfo.processInfo.systemUptime + 2.0)) {
        RishCGISocket peer = { accept(listenerFD, NULL, NULL) };
        if (peer.descriptor >= 0) {
          accepted = YES;
          int noSigPipe = 1;
          setsockopt(peer.descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
          struct timeval receiveTimeout = { .tv_sec = 2, .tv_usec = 0 };
          setsockopt(peer.descriptor, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, sizeof(receiveTimeout));
          uint8_t request[2048];
          (void)recv(peer.descriptor, request, sizeof(request), 0);
          NSData *head = [@"HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\n"
              dataUsingEncoding:NSUTF8StringEncoding];
          NSTimeInterval sendDeadline = NSProcessInfo.processInfo.systemUptime + 2.0;
          sentHead = RishCGISendAll(peer.descriptor, (const uint8_t *)head.bytes, head.length, sendDeadline);
          const char *body = "hello";
          NSUInteger length = [scenario isEqual:@"truncated_body"] ? 1 : 5;
          for (NSUInteger index = 0; index < length; index++) {
            // Each chunk is within a socket inactivity timeout, but the whole
            // slow response exceeds the short test deadline.
            usleep([scenario isEqual:@"whole_deadline"] ? 60000 : 10000);
            if (!RishCGISendAll(peer.descriptor, (const uint8_t *)body + index, 1, sendDeadline)) break;
            sentChunks += 1;
          }
        }
      }
      [serverDone fulfill];
    });
    NSInteger status = 200;
    NSDictionary *headers = @{@"stale": @"previous response"};
    BOOL complete = [scenario isEqual:@"delayed_complete"];
    NSData *body = [self httpAtPort:port host:[NSString stringWithFormat:@"127.0.0.1:%d", port]
        origin:nil cookie:nil method:@"GET" path:@"/" body:NSData.data
        timeout:[scenario isEqual:@"whole_deadline"] ? 0.15 : 1.0
        label:scenario status:&status headers:&headers];
    if (complete) {
      XCTAssertEqual(status, 200);
      XCTAssertEqualObjects(body, [@"hello" dataUsingEncoding:NSUTF8StringEncoding]);
      XCTAssertEqualObjects(headers[@"content-length"], @"5");
    } else {
      XCTAssertNil(body);
      XCTAssertEqual(status, 0);
      XCTAssertNil(headers);
    }
    [self waitForExpectations:@[serverDone] timeout:3.0];
    XCTAssertTrue(accepted);
    XCTAssertTrue(sentHead);
    XCTAssertGreaterThan(sentChunks, 0U);
  }
}

- (void)testOptInRealGuestCgiCounterOverLoopback {
  NSDictionary *environment = NSProcessInfo.processInfo.environment;
  if (![environment[@"RISH_GUEST_CGI_LIVE"] isEqualToString:@"1"]) {
    XCTSkip(@"Set RISH_GUEST_CGI_LIVE=1 and stage the simulator Documents fixture to run the bounded real guest test.");
  }
  NSError *registryError = nil;
  DSHAgentToolRegistry *registry = [[DSHAgentToolRegistry alloc] init];
  XCTAssertNotNil([registry nativeDescriptorForToolName:@"start_guest_cgi" error:&registryError]);
  XCTAssertNil(registryError, @"Release must advertise the service tool");
  NSString *directory = environment[@"RISH_GUEST_CGI_FIXTURE_DIR"] ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/RishGuestCgiLiveFixture"];
  NSArray<NSString *> *names = @[@"index.html", @"backend.sh", @"initial.json"];
  NSData *sumsData = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"SHA256SUMS"]];
  XCTAssertNotNil(sumsData, @"Opted-in live test requires its fixture manifest");
  if (sumsData == nil) return;
  NSString *sums = [[NSString alloc] initWithData:sumsData encoding:NSUTF8StringEncoding];
  NSMutableDictionary *expected = [NSMutableDictionary dictionary];
  for (NSString *line in [sums componentsSeparatedByString:@"\n"]) {
    NSArray *parts = [line componentsSeparatedByString:@"  "];
    if (parts.count == 2) expected[parts[1]] = parts[0];
  }
  NSMutableDictionary *contents = [NSMutableDictionary dictionary];
  for (NSString *name in names) {
    NSData *data = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:name]];
    XCTAssertNotNil(data, @"fixture file present");
    XCTAssertEqualObjects(RishCGIHex(RishCGISHA256(data)), expected[name], @"fixture digest matches SHA256SUMS");
    contents[name] = data;
  }
  if (!contents[@"index.html"] || !contents[@"backend.sh"] || !contents[@"initial.json"]) return;
  NSData *indexData = contents[@"index.html"];
  NSData *backendData = contents[@"backend.sh"];
  NSData *initialData = contents[@"initial.json"];
  XCTAssertLessThanOrEqual(indexData.length, (NSUInteger)32 * 1024);
  XCTAssertLessThanOrEqual(backendData.length, (NSUInteger)8 * 1024);
  XCTAssertLessThanOrEqual(initialData.length, (NSUInteger)4 * 1024);
  NSString *html = [[NSString alloc] initWithData:indexData encoding:NSUTF8StringEncoding];
  NSString *backend = [[NSString alloc] initWithData:backendData encoding:NSUTF8StringEncoding];
  NSDictionary *initial = [NSJSONSerialization JSONObjectWithData:initialData options:0 error:nil];
  XCTAssertNotNil(html); XCTAssertNotNil(backend); XCTAssertTrue([NSJSONSerialization isValidJSONObject:initial]);
  if (!html || !backend || ![NSJSONSerialization isValidJSONObject:initial]) return;

  RishGuestCgiService *service = [[RishGuestCgiService alloc] init];
  __block NSDictionary *started = nil; __block NSString *startCode = nil;
  XCTestExpectation *startExpectation = [self expectationWithDescription:@"real guest CGI start"];
  NSTimeInterval startBegan = NSProcessInfo.processInfo.systemUptime;
  [service start:@{ @"indexHtml": html, @"backendScript": backend, @"initialData": initial }
      resolve:^(NSDictionary *result) { started = result; [startExpectation fulfill]; }
       reject:^(NSString *code, NSString *message) { (void)message; startCode = code; [startExpectation fulfill]; }];
  [self waitForExpectations:@[startExpectation] timeout:180.0];
  NSLog(@"Rish CGI live step=start elapsed=%.3f status=%@",
      NSProcessInfo.processInfo.systemUptime - startBegan,
      [started[@"state"] isEqualToString:@"running"] ? @"running" : @"failed");
  if (!started || ![started[@"state"] isEqualToString:@"running"]) {
    NSString *pendingServiceID = service.status[@"service_id"];
    if (pendingServiceID.length > 0) {
      XCTestExpectation *cleanup = [self expectationWithDescription:@"cleanup failed real guest CGI start"];
      [service stop:pendingServiceID resolve:^(NSDictionary *result) { (void)result; [cleanup fulfill]; }
           reject:^(NSString *code, NSString *message) { (void)code; (void)message; [cleanup fulfill]; }];
      [self waitForExpectations:@[cleanup] timeout:30.0];
    }
    XCTFail(@"real guest CGI start failed: %@", startCode ?: @"timeout");
    return;
  }
  XCTAssertNil(startCode, @"real guest CGI start succeeds");
  XCTAssertEqualObjects(started[@"state"], @"running");
  NSString *url = started[@"url"];
  NSURLComponents *components = [NSURLComponents componentsWithString:url];
  NSInteger port = components.port.integerValue;
  NSString *host = [NSString stringWithFormat:@"127.0.0.1:%ld", (long)port];
  NSString *origin = [NSString stringWithFormat:@"http://%@", host];
  @try {
    NSInteger status = 0; NSDictionary *responseHeaders = nil;
    NSData *page = [self httpAtPort:(int)port host:host origin:nil cookie:nil
        method:@"GET" path:@"/" body:NSData.data timeout:RishCGIHTTPDeadline
        label:@"page" status:&status headers:&responseHeaders];
    NSData *expectedPage = [html dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertEqual(status, (NSInteger)200); XCTAssertEqualObjects(page, expectedPage);
    if (status != 200 || ![page isEqual:expectedPage]) return;
    NSString *setCookie = responseHeaders[@"set-cookie"];
    NSString *cookie = [setCookie componentsSeparatedByString:@";"].firstObject;
    XCTAssertTrue(cookie.length > 0);
    if (cookie.length == 0) return;
    NSData *readBody = [@"{\"action\":\"read\"}" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *incBody = [@"{\"action\":\"inc\"}" dataUsingEncoding:NSUTF8StringEncoding];
    NSArray *steps = @[
      @{@"label": @"read_initial", @"request": readBody, @"expected": @"{\"count\":0}\n"},
      @{@"label": @"increment_once", @"request": incBody, @"expected": @"{\"count\":1}\n"},
      @{@"label": @"read_updated", @"request": readBody, @"expected": @"{\"count\":1}\n"},
    ];
    for (NSDictionary *step in steps) {
      NSData *result = [self httpAtPort:(int)port host:host origin:origin cookie:cookie
          method:@"POST" path:@"/api" body:step[@"request"] timeout:RishCGIHTTPDeadline
          label:step[@"label"] status:&status headers:NULL];
      NSData *expected = [step[@"expected"] dataUsingEncoding:NSUTF8StringEncoding];
      XCTAssertEqual(status, (NSInteger)200, @"%@", step[@"label"]);
      XCTAssertEqualObjects(result, expected, @"%@", step[@"label"]);
      // An ambiguous response must never cause an increment retry or another
      // POST racing the still-active guest request. The finally always stops.
      if (status != 200 || ![result isEqual:expected]) return;
    }
  } @finally {
    XCTestExpectation *stopExpectation = [self expectationWithDescription:@"real guest CGI stop"];
    NSTimeInterval stopBegan = NSProcessInfo.processInfo.systemUptime;
    [service stop:started[@"service_id"] resolve:^(NSDictionary *result) {
        (void)result; [stopExpectation fulfill];
      } reject:^(NSString *code, NSString *message) {
        (void)code; (void)message; [stopExpectation fulfill];
      }];
    [self waitForExpectations:@[stopExpectation] timeout:30.0];
    NSLog(@"Rish CGI live step=stop elapsed=%.3f", NSProcessInfo.processInfo.systemUptime - stopBegan);
    XCTAssertTrue(RishCGIWait(^{ int probe = socket(AF_INET, SOCK_STREAM, 0); if (probe < 0) return YES; struct sockaddr_in address = {}; address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK); address.sin_port = htons((uint16_t)port); int result = connect(probe, (struct sockaddr *)&address, sizeof(address)); close(probe); return result != 0; }, 10.0));
  }

}

@end
