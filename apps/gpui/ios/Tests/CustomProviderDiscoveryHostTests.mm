#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "CustomProviderModelDiscovery.h"
#import "ProviderConfiguration.h"
#import "HarnessAuthService.h"
#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>

static NSUInteger checks;
static NSUserDefaults *testDefaults;
BOOL DSHCodexChatUsesSubscription(void) { return NO; }
static id IsolatedDefaults(id receiver, SEL selector) { return testDefaults; }
static void Check(BOOL value, NSString *message) { checks++; NSCAssert(value, @"%@", message); }
static BOOL Wait(dispatch_semaphore_t semaphore) {
  return dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)) == 0;
}
static NSData *JSON(id value) {
  return [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
}

@interface LoopbackReply : NSObject
@property(nonatomic) NSInteger status;
@property(nonatomic, copy) NSDictionary *body;
@property(nonatomic, copy) NSData *rawBody;
@property(nonatomic, copy) NSString *location;
@property(nonatomic, strong) dispatch_semaphore_t received;
@property(nonatomic, strong) dispatch_semaphore_t releaseResponse;
@end
@implementation LoopbackReply
- (instancetype)init {
  if ((self = [super init])) { _status = 200; _received = dispatch_semaphore_create(0); }
  return self;
}
@end

// A real TCP server, restricted to the simulator's loopback interface. Every
// connection closes after a bounded request and response; redirects cannot
// hide in a reused socket. Captured synthetic request values never get logged.
@interface LoopbackServer : NSObject
@property(nonatomic) int listener;
@property(nonatomic) uint16_t port;
@property(nonatomic) BOOL stopped;
@property(nonatomic, strong) NSMutableArray<LoopbackReply *> *replies;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *requests;
@property(nonatomic, strong) dispatch_semaphore_t finished;
- (BOOL)start;
- (void)stop;
- (void)enqueue:(LoopbackReply *)reply;
- (NSArray<NSDictionary *> *)captured;
@end
@implementation LoopbackServer
- (BOOL)start {
  self.replies = [NSMutableArray array]; self.requests = [NSMutableArray array];
  self.finished = dispatch_semaphore_create(0);
  self.listener = socket(AF_INET, SOCK_STREAM, 0);
  if (self.listener < 0) return NO;
  struct sockaddr_in address = {};
  address.sin_len = sizeof(address); address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK); address.sin_port = 0;
  if (bind(self.listener, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(self.listener, 8) != 0) {
    close(self.listener); return NO;
  }
  socklen_t size = sizeof(address);
  if (getsockname(self.listener, (struct sockaddr *)&address, &size) != 0) { close(self.listener); return NO; }
  self.port = ntohs(address.sin_port);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    @autoreleasepool {
      while (YES) {
        int client = accept(self.listener, nullptr, nullptr);
        if (client < 0) break;
        @synchronized(self) { if (self.stopped) { close(client); break; } }
        struct timeval timeout = {10, 0}; int noSignal = 1;
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));
        [self serveClient:client]; close(client);
      }
      dispatch_semaphore_signal(self.finished);
    }
  });
  return YES;
}
- (void)enqueue:(LoopbackReply *)reply { @synchronized(self) { [self.replies addObject:reply]; } }
- (NSArray<NSDictionary *> *)captured { @synchronized(self) { return [self.requests copy]; } }
- (void)serveClient:(int)client {
  NSMutableData *bytes = [NSMutableData data];
  NSData *boundary = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
  NSUInteger headerEnd = NSNotFound; NSUInteger contentLength = 0;
  NSDictionary *headers = nil; NSString *path = nil; NSString *method = nil;
  while (bytes.length <= 2 * 1024 * 1024) {
    uint8_t buffer[4096]; ssize_t received = recv(client, buffer, sizeof(buffer), 0);
    if (received <= 0) return;
    [bytes appendBytes:buffer length:(NSUInteger)received];
    if (headerEnd == NSNotFound) {
      NSRange found = [bytes rangeOfData:boundary options:0 range:NSMakeRange(0, bytes.length)];
      if (found.location == NSNotFound) continue;
      headerEnd = NSMaxRange(found);
      NSString *headerText = [[NSString alloc] initWithData:[bytes subdataWithRange:NSMakeRange(0, found.location)]
                                                  encoding:NSUTF8StringEncoding];
      NSArray *lines = [headerText componentsSeparatedByString:@"\r\n"];
      NSArray *first = [lines.firstObject componentsSeparatedByString:@" "];
      if (first.count != 3) return;
      method = first[0]; path = first[1];
      NSMutableDictionary *fields = [NSMutableDictionary dictionary];
      for (NSUInteger index = 1; index < lines.count; index++) {
        NSString *line = lines[index]; NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) return;
        NSString *name = [[line substringToIndex:colon.location] lowercaseString];
        fields[name] = [[line substringFromIndex:colon.location + 1]
          stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
      }
      headers = fields; contentLength = [fields[@"content-length"] integerValue];
      if (contentLength > 1024 * 1024) return;
    }
    if (bytes.length >= headerEnd + contentLength) break;
  }
  if (headerEnd == NSNotFound || bytes.length < headerEnd + contentLength) return;
  NSData *bodyBytes = [bytes subdataWithRange:NSMakeRange(headerEnd, contentLength)];
  id body = [NSJSONSerialization JSONObjectWithData:bodyBytes options:0 error:nil];
  LoopbackReply *reply = nil;
  @synchronized(self) {
    [self.requests addObject:@{@"method":method, @"path":path, @"headers":headers, @"body":body ?: NSNull.null}];
    if (self.replies.count) { reply = self.replies.firstObject; [self.replies removeObjectAtIndex:0]; }
  }
  if (!reply) { reply = [[LoopbackReply alloc] init]; reply.status = 500; reply.body = @{}; }
  dispatch_semaphore_signal(reply.received);
  if (reply.releaseResponse && !Wait(reply.releaseResponse)) return;
  NSData *payload = reply.rawBody ?: JSON(reply.body ?: @{});
  NSString *header = [NSString stringWithFormat:
    @"HTTP/1.1 %ld %@\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nConnection: close\r\n%@\r\n",
    (long)reply.status, reply.status == 200 ? @"OK" : @"Test response", (unsigned long)payload.length,
    reply.location ? [NSString stringWithFormat:@"Location: %@\r\n", reply.location] : @""];
  NSMutableData *response = [[header dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
  [response appendData:payload];
  NSUInteger sent = 0;
  while (sent < response.length) {
    ssize_t count = send(client, (const uint8_t *)response.bytes + sent, response.length - sent, 0);
    if (count <= 0) break; sent += (NSUInteger)count;
  }
}
- (void)stop {
  @synchronized(self) { self.stopped = YES; }
  shutdown(self.listener, SHUT_RDWR); close(self.listener);
  Check(Wait(self.finished), @"Loopback server terminates within its bounded wait");
}
@end

@interface DiscoveryRun : NSObject
@property(nonatomic, strong) DSHCustomProviderModelDiscovery *service;
@property(nonatomic, strong) dispatch_semaphore_t completed;
@property(nonatomic, copy) NSDictionary *result;
@property(nonatomic, copy) NSString *errorCode;
@property(nonatomic, copy) NSString *operationId;
@property(nonatomic) BOOL current;
@property(nonatomic) NSUInteger completionCount;
@end
@implementation DiscoveryRun
@end

static NSString *ProviderId(NSUInteger index) {
  return [NSString stringWithFormat:@"%08lu-2222-4222-8222-222222222222", (unsigned long)index];
}
static NSDictionary *Configuration(LoopbackServer *server, NSUInteger index, NSString *protocol, NSString *auth) {
  NSString *suffix = [protocol isEqual:@"messages"] ? @"messages" :
    ([protocol isEqual:@"responses"] ? @"responses" : @"chat/completions");
  return DSHNormalizeProviderConfiguration(@{@"schema_version":@1,
    @"harness_id":[@"custom-" stringByAppendingString:ProviderId(index)], @"name":@"Discovery relay",
    @"endpoint_url":[NSString stringWithFormat:@"http://127.0.0.1:%u/tenant%%2Fspace/v1/%@", server.port, suffix],
    @"protocol":protocol, @"auth_type":auth, @"send_reasoning":@NO, @"full_url":@YES,
    @"model_mappings":@{}});
}
static DiscoveryRun *NewDiscovery(NSDictionary *configuration, NSString *credential) {
  DiscoveryRun *run = [[DiscoveryRun alloc] init]; run.current = YES;
  run.operationId = NSUUID.UUID.UUIDString.lowercaseString;
  run.completed = dispatch_semaphore_create(0);
  __weak DiscoveryRun *weakRun = run;
  run.service = [[DSHCustomProviderModelDiscovery alloc] initWithConfiguration:configuration
    operationId:run.operationId credential:credential
    sourceIsCurrent:^BOOL { DiscoveryRun *owner = weakRun; @synchronized(owner) { return owner && owner.current; } }
    completion:^(NSDictionary *result, NSString *code) {
      DiscoveryRun *owner = weakRun;
      @synchronized(owner) { owner.result = result; owner.errorCode = code; owner.completionCount++; }
      dispatch_semaphore_signal(owner.completed);
    }];
  Check(![run.service isRunning], @"Constructing a discovery service does not start a network request");
  return run;
}
static void Complete(DiscoveryRun *run, NSString *expectedError) {
  Check(Wait(run.completed), @"Explicit discovery completes within the bounded test wait");
  Check(run.completionCount == 1 && ![run.service isRunning],
    @"Discovery settles once and releases its running reservation");
  if (expectedError) {
    Check(run.result == nil && [run.errorCode isEqual:expectedError],
      [@"Discovery rejects with its fixed error: " stringByAppendingString:expectedError]);
  } else Check(run.result != nil && run.errorCode == nil, @"Discovery returns validated candidate models");
}
static LoopbackReply *Reply(LoopbackServer *server, NSDictionary *body) {
  LoopbackReply *reply = [[LoopbackReply alloc] init]; reply.body = body; [server enqueue:reply]; return reply;
}
static NSDictionary *Page(NSArray *ids, BOOL more) {
  NSMutableArray *data = [NSMutableArray array];
  for (NSString *identifier in ids) [data addObject:@{@"id":identifier, @"display_name":[@"Model " stringByAppendingString:identifier]}];
  return @{@"data":data, @"has_more":@(more), @"last_id":ids.lastObject ?: NSNull.null};
}
static void CheckRegistry(DSHProviderConfigurationStore *store, NSDictionary *expected) {
  Check([[store customRegistry:nil] isEqual:expected], @"Model discovery never imports candidates or mutates provider metadata");
}

static void DialectCases(LoopbackServer *server, DSHProviderConfigurationStore *store) {
  NSArray *protocols = @[@"chat-completions", @"chat-completions", @"messages", @"responses", @"messages"];
  NSArray *auth = @[@"bearer", @"bearer", @"x-api-key", @"api-key", @"none"];
  NSArray *credentials = @[@"synthetic-discovery-a", @"synthetic-discovery-b", @"synthetic-messages", @"synthetic-responses", @"no-auth-sentinel"];
  for (NSUInteger index = 0; index < protocols.count; index++) {
    NSDictionary *configuration = Configuration(server, index + 1, protocols[index], auth[index]);
    Check(configuration != nil, @"Native codec accepts a full loopback endpoint with an encoded prefix");
    NSUInteger before = server.captured.count;
    NSDictionary *saved = [store saveCustomProvider:@{@"id":ProviderId(index + 1), @"active":@YES,
      @"configuration":configuration, @"models":@[]} expectedRevision:@(index) error:nil];
    Check(saved != nil && server.captured.count == before,
      @"Saving an empty provider does not automatically fetch a model list");
    NSDictionary *body = @{@"data":@[@{@"id":@"wire-model", @"display_name":@"Visible model", @"supports_images":@YES,
      @"ignored_remote_field":@"not-imported"}], @"has_more":@NO};
    LoopbackReply *reply = Reply(server, body); reply.releaseResponse = dispatch_semaphore_create(0);
    DiscoveryRun *run = NewDiscovery(configuration, credentials[index]);
    Check(server.captured.count == before, @"Only an explicit discovery start may contact the saved provider");
    [run.service start];
    Check(Wait(reply.received) && [run.service isRunning], @"A pending model response keeps discovery running");
    dispatch_semaphore_signal(reply.releaseResponse); Complete(run, nil);
    Check([run.result[@"models"] isEqual:@[@{@"wire_model":@"wire-model", @"name":@"Visible model", @"supports_images":@YES}]] &&
      [run.result[@"truncated"] isEqual:@NO], @"Discovery returns only the closed candidate shape without remote extra fields");
    NSDictionary *request = server.captured.lastObject; NSDictionary *headers = request[@"headers"];
    Check([request[@"method"] isEqual:@"GET"] && [request[@"path"] isEqual:@"/tenant%2Fspace/v1/models"],
      @"All three dialects use GET models while preserving the exact encoded prefix");
    if ([auth[index] isEqual:@"bearer"]) {
      Check([headers[@"authorization"] isEqual:[@"Bearer " stringByAppendingString:credentials[index]]] &&
        headers[@"x-api-key"] == nil && headers[@"api-key"] == nil, @"Discovery uses only its explicit bearer credential");
    } else if ([auth[index] isEqual:@"none"]) {
      Check(headers[@"authorization"] == nil && headers[@"x-api-key"] == nil && headers[@"api-key"] == nil &&
        ![headers.allValues containsObject:credentials[index]], @"No-auth discovery never sends a credential or local sentinel");
    } else Check([headers[auth[index]] isEqual:credentials[index]] && headers[@"authorization"] == nil,
      @"Discovery selects the profile's exact API-key header");
    if ([protocols[index] isEqual:@"messages"]) Check([headers[@"anthropic-version"] isEqual:@"2023-06-01"],
      @"Messages discovery sends the protocol version header");
    CheckRegistry(store, saved);
  }
  NSArray *requests = server.captured;
  Check([requests[0][@"path"] isEqual:requests[1][@"path"]] &&
    ![requests[0][@"headers"][@"authorization"] isEqual:requests[1][@"headers"][@"authorization"]],
    @"Independent providers sharing one models endpoint never share request credentials");
}

static void PaginationCases(LoopbackServer *server, NSDictionary *configuration) {
  NSUInteger before = server.captured.count;
  Reply(server, Page(@[@"first/cursor"], YES)); Reply(server, Page(@[@"second"], NO));
  DiscoveryRun *run = NewDiscovery(configuration, @"synthetic-pagination"); [run.service start]; Complete(run, nil);
  NSArray *requests = server.captured;
  Check([run.result[@"models"] count] == 2 && requests.count == before + 2 && [run.result[@"truncated"] isEqual:@NO],
    @"Messages model listing follows a bounded two-page result");
  NSURLComponents *first = [NSURLComponents componentsWithString:[@"http://localhost" stringByAppendingString:requests[before][@"path"]]];
  NSURLComponents *second = [NSURLComponents componentsWithString:[@"http://localhost" stringByAppendingString:requests[before + 1][@"path"]]];
  Check([first.percentEncodedPath isEqual:second.percentEncodedPath] &&
    [second.percentEncodedPath isEqual:@"/tenant%2Fspace/v1/models"] && second.queryItems.count == 1 &&
    [second.queryItems[0].name isEqual:@"after_id"] && [second.queryItems[0].value isEqual:@"first/cursor"] &&
    [requests[before][@"headers"][@"host"] isEqual:requests[before + 1][@"headers"][@"host"]],
    @"Pagination changes only the encoded after_id query on the same host, port and path");
  before = server.captured.count;
  Reply(server, @{@"data":@[@{@"id":@"retired-last", @"display_name":@"Retired model", @"lifecycle":@"retired"}],
    @"has_more":@YES, @"last_id":@"retired-last"});
  Reply(server, @{@"data":@[@{@"id":@"active-picture",
    @"display_name":[@"长" stringByPaddingToLength:100 withString:@"长" startingAtIndex:0],
    @"capabilities":@{@"image_input":@{@"supported":@YES}}}],
    @"has_more":@NO});
  run = NewDiscovery(configuration, @"synthetic-pagination"); [run.service start]; Complete(run, nil);
  Check([run.result[@"models"] isEqual:@[@{@"wire_model":@"active-picture", @"name":@"active-picture", @"supports_images":@YES}]] &&
    server.captured.count == before + 2 && [run.result[@"truncated"] isEqual:@NO],
    @"A retired-only page continues to active candidates and retains explicit image capabilities");
  Check([run.result[@"models"][0][@"name"] lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= 80,
    @"An oversized remote display name falls back to a bounded safe model label");
  NSURLComponents *afterRetired = [NSURLComponents componentsWithString:[@"http://localhost"
    stringByAppendingString:server.captured.lastObject[@"path"]]];
  Check(afterRetired.queryItems.count == 1 && [afterRetired.queryItems[0].name isEqual:@"after_id"] &&
    [afterRetired.queryItems[0].value isEqual:@"retired-last"],
    @"Pagination uses the last raw retired row even when the filtered page contains no candidates");
  before = server.captured.count;
  Reply(server, Page(@[@"overlap", @"page-one"], YES));
  Reply(server, Page(@[@"overlap", @"page-two"], NO));
  run = NewDiscovery(configuration, @"synthetic-pagination"); [run.service start]; Complete(run, nil);
  Check([[run.result[@"models"] valueForKey:@"wire_model"] isEqual:@[@"overlap", @"page-one", @"page-two"]] &&
    server.captured.count == before + 2, @"Overlapping pages preserve the first occurrence and collect later candidates");
  before = server.captured.count;
  Reply(server, Page(@[@"repeat"], YES)); Reply(server, Page(@[@"repeat"], YES));
  run = NewDiscovery(configuration, @"synthetic-pagination"); [run.service start];
  Complete(run, @"E_PROVIDER_MODEL_DISCOVERY_INVALID");
  Check(server.captured.count == before + 2, @"A repeated cursor cannot trigger a third request");

  NSMutableArray *firstBatch = [NSMutableArray array]; NSMutableArray *secondBatch = [NSMutableArray array];
  for (NSUInteger index = 0; index < 300; index++) {
    [firstBatch addObject:[NSString stringWithFormat:@"batch-a-%lu", (unsigned long)index]];
    [secondBatch addObject:[NSString stringWithFormat:@"batch-b-%lu", (unsigned long)index]];
  }
  before = server.captured.count;
  Reply(server, Page(firstBatch, YES)); Reply(server, Page(secondBatch, YES));
  run = NewDiscovery(configuration, @"synthetic-pagination"); [run.service start]; Complete(run, nil);
  Check([run.result[@"models"] count] == 512 && [run.result[@"truncated"] isEqual:@YES] &&
    server.captured.count == before + 2, @"Discovery truncates a multipage list at 512 models without following another cursor");
  before = server.captured.count;
  for (NSUInteger index = 0; index < 8; index++) Reply(server, Page(@[[NSString stringWithFormat:@"page-%lu", (unsigned long)index]], YES));
  run = NewDiscovery(configuration, @"synthetic-pagination"); [run.service start]; Complete(run, nil);
  Check([run.result[@"models"] count] == 8 && [run.result[@"truncated"] isEqual:@YES] &&
    server.captured.count == before + 8, @"Discovery truncates at eight pages rather than following an unbounded remote list");
}

static void RefusalCases(LoopbackServer *server, NSDictionary *configuration) {
  NSArray *bodies = @[@"{bad-json", @"{\"data\":[],\"data\":[]}",
    @"{\"data\":[{\"id\":\"duplicate\"},{\"id\":\"duplicate\"}]}",
    @"{\"data\":[{\"id\":\"bad model id\"}]}"];
  for (NSString *body in bodies) {
    LoopbackReply *reply = [[LoopbackReply alloc] init]; reply.rawBody = [body dataUsingEncoding:NSUTF8StringEncoding];
    [server enqueue:reply]; DiscoveryRun *run = NewDiscovery(configuration, @"synthetic-invalid");
    [run.service start]; Complete(run, @"E_PROVIDER_MODEL_DISCOVERY_INVALID");
  }
  LoopbackReply *unauthorized = [[LoopbackReply alloc] init]; unauthorized.status = 401;
  unauthorized.body = @{@"error":@"remote text must never become the error code"}; [server enqueue:unauthorized];
  DiscoveryRun *run = NewDiscovery(configuration, @"synthetic-invalid"); [run.service start];
  Complete(run, @"E_PROVIDER_MODEL_DISCOVERY_AUTH");
  NSUInteger before = server.captured.count;
  LoopbackReply *redirect = [[LoopbackReply alloc] init]; redirect.status = 307;
  redirect.location = [NSString stringWithFormat:@"http://127.0.0.1:%u/forbidden", server.port]; [server enqueue:redirect];
  run = NewDiscovery(configuration, @"synthetic-redirect"); [run.service start];
  Complete(run, @"E_PROVIDER_MODEL_DISCOVERY_REDIRECT");
  Check(server.captured.count == before + 1 && ![server.captured.lastObject[@"path"] isEqual:@"/forbidden"],
    @"Discovery never follows a redirect or sends credentials to its destination");
  LoopbackReply *oversize = [[LoopbackReply alloc] init]; oversize.rawBody = [NSMutableData dataWithLength:1024 * 1024 + 1];
  [server enqueue:oversize]; run = NewDiscovery(configuration, @"synthetic-oversize"); [run.service start];
  Complete(run, @"E_PROVIDER_MODEL_DISCOVERY_LIMIT");
  before = server.captured.count;
  run = NewDiscovery(configuration, nil); [run.service start]; Complete(run, @"E_PROVIDER_MODEL_DISCOVERY_CREDENTIAL");
  Check(server.captured.count == before, @"Missing profile credentials fail before any request");
  NSMutableDictionary *unsupported = [configuration mutableCopy];
  unsupported[@"endpoint_url"] = [NSString stringWithFormat:@"http://127.0.0.1:%u/custom-endpoint", server.port];
  run = NewDiscovery(unsupported, @"synthetic-unsupported"); [run.service start];
  Complete(run, @"E_PROVIDER_MODEL_DISCOVERY_UNSUPPORTED");
  Check(server.captured.count == before, @"Unsupported full endpoint paths fail explicitly without guessing another endpoint");
}

static void StaleAndCancelCases(LoopbackServer *server, NSDictionary *configuration) {
  NSUInteger before = server.captured.count;
  DiscoveryRun *initial = NewDiscovery(configuration, @"synthetic-stale"); initial.current = NO;
  [initial.service start]; Complete(initial, @"E_PROVIDER_CONFIGURATION_CHANGED");
  Check(server.captured.count == before, @"An already stale configuration never starts model discovery");
  for (NSNumber *cancel in @[@NO, @YES]) {
    LoopbackReply *reply = Reply(server, Page(@[@"late-result"], NO)); reply.releaseResponse = dispatch_semaphore_create(0);
    DiscoveryRun *run = NewDiscovery(configuration, @"synthetic-stale"); [run.service start];
    Check(Wait(reply.received) && [run.service isRunning], @"Stale/cancel fixture holds a real in-flight discovery request");
    if (cancel.boolValue) [run.service cancel]; else { @synchronized(run) { run.current = NO; } }
    dispatch_semaphore_signal(reply.releaseResponse);
    Complete(run, cancel.boolValue ? @"E_PROVIDER_MODEL_DISCOVERY_CANCELLED" : @"E_PROVIDER_CONFIGURATION_CHANGED");
  }
}

static void ScopedCancellationCases(LoopbackServer *server, NSDictionary *configuration) {
  NSString *canonicalOperation = @"abcdefab-1234-4234-8234-123456abcdef";
  Check(DSHCustomProviderDiscoveryIsOperationId(canonicalOperation) &&
    !DSHCustomProviderDiscoveryIsOperationId(canonicalOperation.uppercaseString) &&
    !DSHCustomProviderDiscoveryIsOperationId(@"abcdefab123442348234123456abcdef"),
    @"Discovery operation tokens require the canonical lowercase UUID spelling");
  Check(!DSHCustomProviderDiscoveryIsOperationId(nil) && !DSHCustomProviderDiscoveryIsOperationId(NSNull.null) &&
    !DSHCustomProviderDiscoveryIsOperationId(@1) && !DSHCustomProviderDiscoveryIsOperationId(@[]) &&
    !DSHCustomProviderDiscoveryIsOperationId(@{}), @"Non-string operation token values are rejected before cancellation");
  Reply(server, Page(@[@"previous-operation"], NO));
  DiscoveryRun *previous = NewDiscovery(configuration, @"synthetic-scoped"); [previous.service start]; Complete(previous, nil);
  LoopbackReply *reply = Reply(server, Page(@[@"current-operation"], NO)); reply.releaseResponse = dispatch_semaphore_create(0);
  DiscoveryRun *current = NewDiscovery(configuration, @"synthetic-scoped"); [current.service start];
  Check(Wait(reply.received) && [current.service isRunning], @"Scoped cancellation fixture holds a real current operation");
  Check(![current.service cancelForProviderId:ProviderId(4) operationId:current.operationId] && [current.service isRunning],
    @"A cancellation for another provider cannot stop the current discovery");
  Check(![current.service cancelForProviderId:ProviderId(3) operationId:NSUUID.UUID.UUIDString.lowercaseString] &&
    [current.service isRunning], @"An unrelated operation token cannot stop the current discovery");
  Check(![current.service cancelForProviderId:ProviderId(3) operationId:previous.operationId] && [current.service isRunning],
    @"A delayed cancellation from an older operation cannot cancel a newer fetch for the same provider");
  Check(![current.service cancelForProviderId:ProviderId(3) operationId:@"invalid-operation"] && [current.service isRunning],
    @"A malformed operation token cannot cancel a discovery request");
  dispatch_semaphore_signal(reply.releaseResponse); Complete(current, nil);
  Check([current.result[@"models"][0][@"wire_model"] isEqual:@"current-operation"],
    @"The current operation retains its own successful result after unrelated cancellations");
  reply = Reply(server, Page(@[@"cancelled-operation"], NO)); reply.releaseResponse = dispatch_semaphore_create(0);
  DiscoveryRun *cancelled = NewDiscovery(configuration, @"synthetic-scoped"); [cancelled.service start];
  Check(Wait(reply.received) && [cancelled.service isRunning], @"Matching cancellation fixture starts a live request");
  Check([cancelled.service cancelForProviderId:ProviderId(3) operationId:cancelled.operationId],
    @"Only a matching provider and operation token cancels an active discovery");
  dispatch_semaphore_signal(reply.releaseResponse); Complete(cancelled, @"E_PROVIDER_MODEL_DISCOVERY_CANCELLED");
  Check(![cancelled.service cancelForProviderId:ProviderId(3) operationId:cancelled.operationId],
    @"A completed cancellation cannot claim the same operation again");
}

static void CredentialEchoCases(LoopbackServer *server, NSDictionary *configuration) {
  NSString *credential = @"synthetic-secret-value";
  NSArray *rows = @[
    @{@"id":credential, @"display_name":@"Public label"},
    @{@"id":[@"prefix/" stringByAppendingString:credential], @"display_name":@"Public label"},
    @{@"id":@"public-model", @"display_name":credential},
    @{@"id":@"public-model", @"display_name":[@"prefix " stringByAppendingString:credential]}];
  for (NSDictionary *row in rows) {
    Reply(server, @{@"data":@[row], @"has_more":@NO});
    DiscoveryRun *run = NewDiscovery(configuration, credential); [run.service start];
    Complete(run, @"E_PROVIDER_MODEL_DISCOVERY_INVALID");
  }
  NSMutableString *escaped = [NSMutableString string];
  for (NSUInteger index = 0; index < credential.length; index++) [escaped appendFormat:@"\\u%04x", [credential characterAtIndex:index]];
  LoopbackReply *escapedReply = [[LoopbackReply alloc] init];
  escapedReply.rawBody = [[NSString stringWithFormat:@"{\"data\":[{\"id\":\"public-model\",\"display_name\":\"%@\"}],\"has_more\":false}", escaped]
    dataUsingEncoding:NSUTF8StringEncoding];
  [server enqueue:escapedReply];
  DiscoveryRun *run = NewDiscovery(configuration, credential); [run.service start];
  Complete(run, @"E_PROVIDER_MODEL_DISCOVERY_INVALID");
  for (NSDictionary *row in @[@{@"id":@"x", @"display_name":@"Public label"},
      @{@"id":@"public-model", @"display_name":@"x"}]) {
    Reply(server, @{@"data":@[row], @"has_more":@NO});
    run = NewDiscovery(configuration, @"x"); [run.service start];
    Complete(run, @"E_PROVIDER_MODEL_DISCOVERY_INVALID");
  }
  Reply(server, @{@"data":@[@{@"id":@"extra-model", @"display_name":@"Example x label"}], @"has_more":@NO});
  run = NewDiscovery(configuration, @"x"); [run.service start]; Complete(run, nil);
  Check([run.result[@"models"][0][@"wire_model"] isEqual:@"extra-model"] &&
    [run.result[@"models"][0][@"name"] isEqual:@"Example x label"],
    @"A short credential substring does not reject otherwise unrelated public model metadata");
  Reply(server, @{@"data":@[@{@"id":@"independent-safe", @"display_name":@"Independent model", @"ignored_field":credential}], @"has_more":@NO});
  run = NewDiscovery(configuration, credential); [run.service start]; Complete(run, nil);
  Check([run.result[@"models"] isEqual:@[@{@"wire_model":@"independent-safe", @"name":@"Independent model", @"supports_images":@NO}]],
    @"Public candidate fields survive while unselected remote fields never reach the discovery result");
  NSMutableDictionary *noAuth = [configuration mutableCopy]; noAuth[@"auth_type"] = @"none";
  Reply(server, @{@"data":@[@{@"id":credential, @"display_name":credential}], @"has_more":@NO});
  run = NewDiscovery(noAuth, credential); [run.service start]; Complete(run, nil);
  Check([run.result[@"models"][0][@"wire_model"] isEqual:credential] &&
    server.captured.lastObject[@"headers"][@"authorization"] == nil &&
    server.captured.lastObject[@"headers"][@"x-api-key"] == nil,
    @"No-auth discovery ignores the local nonsecret marker when validating model metadata");
}

static void CredentialCursorEchoCases(LoopbackServer *server, NSDictionary *configuration) {
  NSString *credential = @"synthetic-cursor-key";
  for (NSString *cursor in @[credential, [@"model-" stringByAppendingString:credential], @"x"]) {
    NSString *capturedKey = [cursor isEqual:@"x"] ? @"x" : credential;
    NSUInteger before = server.captured.count;
    Reply(server, @{@"data":@[@{@"id":cursor, @"lifecycle":@"retired"}],
      @"has_more":@YES, @"last_id":cursor});
    DiscoveryRun *run = NewDiscovery(configuration, capturedKey); [run.service start];
    Complete(run, @"E_PROVIDER_MODEL_DISCOVERY_INVALID");
    NSURLComponents *sent = [NSURLComponents componentsWithString:[@"http://localhost"
      stringByAppendingString:server.captured.lastObject[@"path"]]];
    Check(run.result == nil && server.captured.count == before + 1 && sent.queryItems.count == 0,
      @"A credential reflected only in a retired row cursor returns no result and cannot reach a second request URL");
  }
  NSMutableDictionary *noAuth = [configuration mutableCopy]; noAuth[@"auth_type"] = @"none";
  NSUInteger before = server.captured.count;
  Reply(server, @{@"data":@[@{@"id":credential, @"lifecycle":@"retired"}],
    @"has_more":@YES, @"last_id":credential});
  Reply(server, Page(@[@"public-after-marker"], NO));
  DiscoveryRun *run = NewDiscovery(noAuth, credential); [run.service start]; Complete(run, nil);
  Check(server.captured.count == before + 2 && [run.result[@"models"][0][@"wire_model"] isEqual:@"public-after-marker"] &&
    server.captured.lastObject[@"headers"][@"authorization"] == nil && server.captured.lastObject[@"headers"][@"x-api-key"] == nil,
    @"No-auth discovery may paginate using its nonsecret marker without sending authentication headers");
}

int main(void) {
  @autoreleasepool {
    NSString *suite = [@"rish-provider-discovery-" stringByAppendingString:NSUUID.UUID.UUIDString];
    testDefaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    Method standard = class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults));
    IMP original = method_setImplementation(standard, (IMP)IsolatedDefaults);
    LoopbackServer *server = [[LoopbackServer alloc] init]; Check([server start], @"Discovery fixture binds loopback only");
    @try {
      DSHProviderConfigurationStore *store = [[DSHProviderConfigurationStore alloc] initWithDefaults:testDefaults];
      DialectCases(server, store);
      NSDictionary *registry = [store customRegistry:nil];
      NSDictionary *configuration = Configuration(server, 3, @"messages", @"x-api-key");
      PaginationCases(server, configuration); CheckRegistry(store, registry);
      RefusalCases(server, configuration); CheckRegistry(store, registry);
      StaleAndCancelCases(server, configuration); CheckRegistry(store, registry);
      ScopedCancellationCases(server, configuration); CheckRegistry(store, registry);
      CredentialEchoCases(server, configuration); CheckRegistry(store, registry);
      CredentialCursorEchoCases(server, configuration); CheckRegistry(store, registry);
    } @finally {
      [server stop]; [testDefaults removePersistentDomainForName:suite];
      method_setImplementation(standard, original);
    }
    printf("Custom provider model discovery loopback checks passed: %lu\n", (unsigned long)checks);
  }
  return 0;
}
