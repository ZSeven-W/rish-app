#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "ConfiguredProviderTransport.h"
#import "ClaudeProviderTransport.h"
#import "CodexProviderTransport.h"
#import "DSHCompletionV2.h"
#import "HarnessAuthService.h"
#import "ProviderConfiguration.h"
#import "RishHarnessCatalog.h"
#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>

static NSUInteger checks;
static NSUserDefaults *testDefaults;
BOOL DSHCodexChatUsesSubscription(void) { return NO; }
static id IsolatedDefaults(id receiver, SEL selector) { return testDefaults; }
static void Check(BOOL value, NSString *message) {
  checks++;
  NSCAssert(value, @"%@", message);
}
static BOOL Wait(dispatch_semaphore_t semaphore) {
  return dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)) == 0;
}
static NSData *JSON(id value) {
  return [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
}

@interface LoopbackReply : NSObject
@property(nonatomic) NSInteger status;
@property(nonatomic, copy) NSDictionary *body;
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
  NSData *payload = JSON(reply.body ?: @{});
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

@interface TransportDelegate : NSObject <NSURLSessionTaskDelegate>
@property(nonatomic, strong) NSMutableArray<DSHConfiguredProviderTransport *> *transports;
@end
@implementation TransportDelegate
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest *))completionHandler {
  for (DSHConfiguredProviderTransport *transport in self.transports) {
    if ([transport handlesTask:task]) {
      [transport handleHTTPRedirectionForTask:task newRequest:request completionHandler:completionHandler];
      return;
    }
  }
  completionHandler(nil);
}
@end

@interface RoundResult : NSObject
@property(nonatomic, strong) dispatch_semaphore_t completed;
@property(nonatomic, copy) NSDictionary *result;
@property(nonatomic, copy) NSString *errorCode;
@property(nonatomic) BOOL redirected;
@property(nonatomic) BOOL redirectRejected;
@property(nonatomic) BOOL claimed;
@property(nonatomic) BOOL generationCurrent;
@property(nonatomic) NSUInteger completionCount;
@end
@implementation RoundResult
- (instancetype)init {
  if ((self = [super init])) { _completed = dispatch_semaphore_create(0); _generationCurrent = YES; }
  return self;
}
@end

static NSString *const ModelUUID = @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
static NSString *ProviderUUID(NSUInteger number) {
  return [NSString stringWithFormat:@"%08lu-1111-4111-8111-111111111111", (unsigned long)number];
}
static NSString *Harness(NSUInteger number) { return [@"custom-" stringByAppendingString:ProviderUUID(number)]; }
static NSString *Model(NSUInteger number) { return [NSString stringWithFormat:@"custom:%@:%@", ProviderUUID(number), ModelUUID]; }
static NSDictionary *Provider(NSUInteger number, NSString *protocol, NSString *auth, NSString *endpoint) {
  return @{@"id":ProviderUUID(number), @"active":@YES,
    @"configuration":@{@"schema_version":@1, @"harness_id":Harness(number), @"name":@"Loopback relay",
      @"endpoint_url":endpoint, @"protocol":protocol, @"auth_type":auth, @"send_reasoning":@NO,
      @"full_url":@YES, @"model_mappings":@{Model(number):@"same-wire-model"}},
    @"models":@[@{@"id":ModelUUID, @"name":@"Local model", @"wire_model":@"same-wire-model",
      @"supports_images":@YES, @"active":@YES}]};
}
static NSDictionary *Payload(NSString *protocol) {
  if ([protocol isEqual:@"messages"]) return @{@"id":@"response-local", @"model":@"same-wire-model",
    @"content":@[@{@"type":@"text", @"text":@"local answer"}], @"stop_reason":@"end_turn"};
  if ([protocol isEqual:@"responses"]) return @{@"id":@"response-local", @"model":@"same-wire-model",
    @"status":@"completed", @"output":@[@{@"type":@"message", @"role":@"assistant",
      @"content":@[@{@"type":@"output_text", @"text":@"local answer"}]}]};
  return @{@"id":@"response-local", @"model":@"same-wire-model", @"choices":@[@{
    @"finish_reason":@"stop", @"message":@{@"role":@"assistant", @"content":@"local answer"}}]};
}
static DSHConfiguredProviderTransport *NewTransport(NSUInteger number, NSURLSession *session,
    TransportDelegate *delegate, DSHProviderConfigurationStore *store) {
  DSHConfiguredProviderTransport *transport = [[DSHConfiguredProviderTransport alloc]
    initWithHarness:Harness(number) session:session uuidGenerator:nil
    monotonicClock:^NSTimeInterval { return 20.25; } store:store];
  [delegate.transports addObject:transport];
  return transport;
}
static RoundResult *Start(DSHConfiguredProviderTransport *transport, NSString *model, NSString *credential) {
  NSArray *messages = @[@{@"role":@"user", @"content":@"local test"}];
  NSError *bodyError = nil;
  NSDictionary *body = [transport providerRequestBodyForModel:model thinkingMode:@"off"
    messages:messages tools:@[] streaming:NO error:&bodyError];
  Check(body != nil && bodyError == nil, @"Real Rust dialect body builds for the custom logical model");
  RoundResult *round = [[RoundResult alloc] init];
  NSURLSessionDataTask *task = [transport startRequestWithSchemaVersion:2
    roundId:NSUUID.UUID.UUIDString.lowercaseString generation:1 credentialGeneration:1
    providerRequestId:NSUUID.UUID.UUIDString.lowercaseString credential:credential requestedModel:model
    thinkingMode:@"off" credentialGenerationIsCurrent:^BOOL(NSUInteger generation) {
      @synchronized(round) { return generation == 1 && round.generationCurrent; }
    } startedAt:20.0 bodyData:JSON(body) visibleHistory:messages modelInput:messages
    bindTask:^BOOL(NSURLSessionDataTask *bound) { return bound != nil; }
    claimRound:^BOOL(BOOL *redirected) {
      @synchronized(round) {
        if (redirected) *redirected = round.redirected;
        if (round.claimed) return NO; round.claimed = YES; return YES;
      }
    } markRedirected:^(NSURLSessionDataTask *redirectedTask) {
      @synchronized(round) { round.redirected = YES; }
    } redirectDecision:^(BOOL rejected) { @synchronized(round) { round.redirectRejected = rejected; } }
    completion:^(NSDictionary *result, NSString *code) {
      @synchronized(round) { round.result = result; round.errorCode = code; round.completionCount++; }
      dispatch_semaphore_signal(round.completed);
    }];
  Check(task != nil, @"Configured transport starts a real NSURLSession task");
  return round;
}
static void Completed(RoundResult *round, DSHConfiguredProviderTransport *transport) {
  Check(Wait(round.completed), @"Configured transport completes within the bounded test wait");
  Check(round.completionCount == 1 && ![transport hasActiveRequests],
    @"A settled request completes exactly once and releases transport ownership");
}
static void RejectedPreparedStart(DSHConfiguredProviderTransport *transport, NSString *model,
                                  NSString *credential, NSData *preparedBody) {
  Check(preparedBody.length > 0, @"Retirement test uses a body built while the selected model was active");
  RoundResult *round = [[RoundResult alloc] init];
  NSURLSessionDataTask *task = [transport startRequestWithSchemaVersion:2
    roundId:NSUUID.UUID.UUIDString.lowercaseString generation:1 credentialGeneration:1
    providerRequestId:NSUUID.UUID.UUIDString.lowercaseString credential:credential requestedModel:model
    thinkingMode:@"off" credentialGenerationIsCurrent:^BOOL(NSUInteger generation) { return YES; }
    startedAt:20.0 bodyData:preparedBody visibleHistory:@[] modelInput:@[]
    bindTask:^BOOL(NSURLSessionDataTask *bound) { return YES; }
    claimRound:^BOOL(BOOL *redirected) { if (redirected) *redirected = NO; return YES; }
    markRedirected:nil redirectDecision:nil completion:^(NSDictionary *result, NSString *code) {
      round.result = result; round.errorCode = code; round.completionCount++;
      dispatch_semaphore_signal(round.completed);
    }];
  Check(task == nil, @"A prepared body cannot start an HTTP task after its model route is retired");
  Completed(round, transport);
  Check(round.result == nil && [round.errorCode isEqual:@"E_COMPLETION_MODEL"],
    @"The final dispatch boundary rejects a retired model with the stable model error");
}
static void Success(RoundResult *round, NSString *model, DSHConfiguredProviderTransport *transport) {
  Completed(round, transport);
  Check(round.errorCode == nil && [round.result[@"text"] isEqual:@"local answer"],
    @"The loopback provider response produces the canonical answer");
  Check([round.result[@"harness_id"] isEqual:[transport providerHarnessId]] &&
    [round.result[@"model"] isEqual:model] && [round.result[@"requested_model"] isEqual:model],
    @"Receipt retains the independent harness and logical requested model");
  Check(DSHValidateProviderBinding(round.result[@"provider_configuration"], model) &&
    [round.result[@"provider_configuration"] isEqual:[transport providerConfigurationForModel:model]],
    @"Receipt carries the exact captured endpoint, dialect and wire-model binding");
}

static void TransportCases(LoopbackServer *server, NSURLSession *session, TransportDelegate *delegate,
                           DSHProviderConfigurationStore *store) {
  NSArray *protocols = @[@"chat-completions", @"chat-completions", @"messages", @"responses", @"messages"];
  NSArray *authTypes = @[@"bearer", @"bearer", @"x-api-key", @"api-key", @"none"];
  NSArray *paths = @[@"/v1/chat/completions", @"/v1/chat/completions", @"/v1/messages", @"/v1/responses", @"/v1/messages"];
  NSArray *markers = @[@"synthetic-provider-a", @"synthetic-provider-b", @"synthetic-messages", @"synthetic-responses", @"no-auth-local-sentinel"];
  NSMutableArray<DSHConfiguredProviderTransport *> *transports = [NSMutableArray array];
  for (NSUInteger index = 0; index < protocols.count; index++) {
    NSUInteger number = index + 1;
    NSString *endpoint = [NSString stringWithFormat:@"http://127.0.0.1:%u%@", server.port, paths[index]];
    NSDictionary *saved = [store saveCustomProvider:Provider(number, protocols[index], authTypes[index], endpoint)
      expectedRevision:@(index) error:nil];
    Check(saved != nil, @"Independent provider metadata saves without initiating a network request");
    Check(server.captured.count == index, @"Adding provider metadata does not contact an endpoint");
    DSHConfiguredProviderTransport *transport = NewTransport(number, session, delegate, store);
    [transports addObject:transport];
    Check([transport providerSupportsModel:Model(number)] && ![transport providerSupportsModel:@"gpt-5.6"],
      @"Independent transport accepts its registered model and rejects built-in identities");
    LoopbackReply *reply = [[LoopbackReply alloc] init]; reply.body = Payload(protocols[index]);
    reply.releaseResponse = dispatch_semaphore_create(0); [server enqueue:reply];
    RoundResult *round = Start(transport, Model(number), markers[index]);
    Check(Wait(reply.received) && [transport hasActiveRequests], @"In-flight local requests hold transport ownership");
    dispatch_semaphore_signal(reply.releaseResponse);
    Success(round, Model(number), transport);
    NSDictionary *request = server.captured.lastObject;
    Check([request[@"method"] isEqual:@"POST"] && [request[@"path"] isEqual:paths[index]] &&
      [request[@"body"][@"model"] isEqual:@"same-wire-model"],
      @"The real HTTP request has the selected dialect path and explicit wire model");
    NSDictionary *headers = request[@"headers"];
    if ([authTypes[index] isEqual:@"bearer"]) {
      Check([headers[@"authorization"] isEqual:[@"Bearer " stringByAppendingString:markers[index]]] &&
        headers[@"x-api-key"] == nil && headers[@"api-key"] == nil,
        @"The provider request receives only its supplied bearer credential");
    } else if ([authTypes[index] isEqual:@"none"]) {
      Check(headers[@"authorization"] == nil && headers[@"x-api-key"] == nil && headers[@"api-key"] == nil &&
        ![headers.allValues containsObject:markers[index]],
        @"No-auth requests omit every credential header and never forward their local sentinel");
    } else {
      Check([headers[authTypes[index]] isEqual:markers[index]] && headers[@"authorization"] == nil,
        @"The selected API-key header contains only the independent provider credential");
    }
    if ([protocols[index] isEqual:@"messages"])
      Check([headers[@"anthropic-version"] isEqual:@"2023-06-01"], @"Messages dialect sends its protocol version header");
  }
  NSArray *requests = server.captured;
  Check([requests[0][@"path"] isEqual:requests[1][@"path"]] &&
    ![requests[0][@"headers"][@"authorization"] isEqual:requests[1][@"headers"][@"authorization"]],
    @"Two independent profiles sharing URL, name and wire model retain distinct request keys");
  Check(![DSHEffectiveCredentialAccount(DSHCredentialAccountForHarnessId(Harness(1)))
    isEqual:DSHEffectiveCredentialAccount(DSHCredentialAccountForHarnessId(Harness(2)))],
    @"The same-URL profiles also retain distinct effective Keychain identities");

  DSHConfiguredProviderTransport *first = transports[0];
  LoopbackReply *redirect = [[LoopbackReply alloc] init]; redirect.status = 307;
  redirect.location = [NSString stringWithFormat:@"http://127.0.0.1:%u/forbidden", server.port];
  redirect.body = @{}; [server enqueue:redirect];
  NSUInteger beforeRedirect = server.captured.count;
  RoundResult *redirected = Start(first, Model(1), markers[0]);
  Completed(redirected, first);
  Check(redirected.result == nil && [redirected.errorCode isEqual:@"E_COMPLETION_REDIRECT"] &&
    redirected.redirectRejected, @"The transport rejects an HTTP redirect with its stable error code");
  Check(server.captured.count == beforeRedirect + 1 &&
    ![server.captured.lastObject[@"path"] isEqual:@"/forbidden"],
    @"No follow-up HTTP request or credential reaches the redirect destination");

  LoopbackReply *stale = [[LoopbackReply alloc] init]; stale.body = Payload(protocols[0]);
  stale.releaseResponse = dispatch_semaphore_create(0); [server enqueue:stale];
  NSDictionary *binding = [first providerConfigurationForModel:Model(1)];
  NSData *preparedFirst = JSON([first providerRequestBodyForModel:Model(1) thinkingMode:@"off"
    messages:@[@{@"role":@"user", @"content":@"prepared before retirement"}] tools:@[] streaming:NO error:nil]);
  RoundResult *removed = Start(first, Model(1), markers[0]);
  Check(Wait(stale.received) && [first hasActiveRequests], @"Delayed response leaves the custom transport visibly busy");
  // The runtime blocks metadata writes while busy. Directly mutate this test
  // store to verify the transport's independent stale-response backstop.
  Check([store removeCustomProvider:ProviderUUID(1) expectedRevision:@5 error:nil] != nil,
    @"Test fixture retires the provider while the real request is in flight");
  Check(![first providerSupportsModel:Model(1)] && [first hasActiveRequests],
    @"Retirement disables new model routing without losing ownership of the in-flight task");
  dispatch_semaphore_signal(stale.releaseResponse); Completed(removed, first);
  Check(removed.result == nil && [removed.errorCode isEqual:@"E_COMPLETION_CREDENTIAL_CHANGED"],
    @"A response captured before provider removal cannot settle as a current success");
  Check(DSHValidateProviderBinding(binding, Model(1)) && !DSHProviderBindingIsCurrent(binding, Model(1)),
    @"The removed provider binding remains valid history without authorizing dispatch");
  Check([first providerRequestBodyForModel:Model(1) thinkingMode:@"off" messages:@[] tools:@[] streaming:NO error:nil] == nil,
    @"A retired provider cannot build a new request body");
  NSUInteger beforeRetiredStart = server.captured.count;
  RejectedPreparedStart(first, Model(1), markers[0], preparedFirst);
  Check(server.captured.count == beforeRetiredStart && [first providerBaseURL] == nil,
    @"Retired provider dispatch sends no request and exposes no fallback URL");
  DSHConfiguredProviderTransport *missing = NewTransport(99, session, delegate, store);
  Check(![missing providerSupportsModel:Model(99)] && [missing providerConfigurationForModel:Model(99)] == nil,
    @"An absent independent provider has no model route or built-in configuration fallback");

  DSHConfiguredProviderTransport *second = transports[1];
  LoopbackReply *changed = [[LoopbackReply alloc] init]; changed.body = Payload(protocols[1]);
  changed.releaseResponse = dispatch_semaphore_create(0); [server enqueue:changed];
  RoundResult *generation = Start(second, Model(2), markers[1]);
  Check(Wait(changed.received), @"Credential-generation fixture reaches the loopback endpoint");
  @synchronized(generation) { generation.generationCurrent = NO; }
  dispatch_semaphore_signal(changed.releaseResponse); Completed(generation, second);
  Check(generation.result == nil && [generation.errorCode isEqual:@"E_COMPLETION_CREDENTIAL_CHANGED"],
    @"A changed credential generation independently rejects the completed local response");

  NSData *preparedSecond = JSON([second providerRequestBodyForModel:Model(2) thinkingMode:@"off"
    messages:@[@{@"role":@"user", @"content":@"prepared before model retirement"}] tools:@[] streaming:NO error:nil]);
  NSString *replacementId = @"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
  NSString *replacementModel = [NSString stringWithFormat:@"custom:%@:%@", ProviderUUID(2), replacementId];
  NSMutableDictionary *replacement = [[store customProviderForId:ProviderUUID(2)] mutableCopy];
  NSMutableDictionary *replacementConfiguration = [replacement[@"configuration"] mutableCopy];
  replacementConfiguration[@"model_mappings"] = @{replacementModel:@"replacement-wire-model"};
  replacement[@"configuration"] = replacementConfiguration;
  replacement[@"models"] = @[@{@"id":replacementId, @"name":@"Replacement model",
    @"wire_model":@"replacement-wire-model", @"supports_images":@YES, @"active":@YES}];
  Check([store saveCustomProvider:replacement expectedRevision:@6 error:nil] != nil &&
    ![second providerSupportsModel:Model(2)] && [second providerSupportsModel:replacementModel],
    @"Replacing a model retires its old route while preserving the independent provider's new route");
  NSUInteger beforeRetiredModelStart = server.captured.count;
  RejectedPreparedStart(second, Model(2), markers[1], preparedSecond);
  Check(server.captured.count == beforeRetiredModelStart,
    @"A previously built body for a retired model never reaches the active provider endpoint");
}

static void LegacyDshOpaqueModelCase(LoopbackServer *server, NSURLSession *session,
                                     TransportDelegate *delegate, DSHProviderConfigurationStore *store) {
  NSString *catalogKey = @"rish.dsh-models.v1";
  NSString *model = @"custom:my-llama";
  NSDictionary *oldCatalog = @{@"schema_version":@1,
    @"models":@[@{@"id":model, @"name":@"Existing saved model", @"supports_images":@YES}],
    @"retired_models":@[]};
  NSDictionary *registryBefore = [store customRegistry:nil];
  [testDefaults setObject:oldCatalog forKey:catalogKey];
  Check([DSHDshModelCatalog() isEqual:oldCatalog] && [DSHHarnessIdForModel(model) isEqual:@"dsh"] &&
    DSHDshModelSupportsImages(model),
    @"An older opaque DSH id beginning custom: remains readable with its original harness and capabilities");
  Check(DSHSaveDshModelCatalog(@{@"schema_version":@1, @"models":oldCatalog[@"models"]}) != nil &&
    [[testDefaults objectForKey:catalogKey] isEqual:oldCatalog],
    @"An existing opaque DSH identity survives explicit saves without rewriting its old preference");
  Check(DSHSaveDshModelCatalog(@{@"schema_version":@1, @"models":@[@{@"id":@"custom:new-unregistered", @"name":@"Rejected new id", @"supports_images":@NO}]}) == nil,
    @"New manual model input still reserves the independent custom namespace");
  NSString *endpoint = [NSString stringWithFormat:@"http://127.0.0.1:%u/v1/chat/completions", server.port];
  NSDictionary *profile = @{@"schema_version":@1, @"harness_id":@"dsh", @"name":@"Existing relay",
    @"endpoint_url":endpoint, @"protocol":@"chat-completions", @"auth_type":@"bearer",
    @"send_reasoning":@NO, @"full_url":@YES, @"model_mappings":@{model:@"same-wire-model"}};
  NSUInteger before = server.captured.count;
  Check([store saveConfiguration:profile error:nil] != nil && server.captured.count == before,
    @"An existing DSH relay configuration still saves without making a network request");
  DSHConfiguredProviderTransport *transport = [[DSHConfiguredProviderTransport alloc]
    initWithHarness:@"dsh" session:session uuidGenerator:nil
    monotonicClock:^NSTimeInterval { return 20.25; } store:store];
  [delegate.transports addObject:transport];
  Check([transport providerSupportsModel:model] && DSHProviderBindingForModel(model) != nil,
    @"The existing DSH configured transport still routes and binds its opaque logical model");
  LoopbackReply *reply = [[LoopbackReply alloc] init]; reply.body = Payload(@"chat-completions");
  [server enqueue:reply];
  RoundResult *round = Start(transport, model, @"synthetic-legacy-dsh");
  Success(round, model, transport);
  NSDictionary *request = server.captured.lastObject;
  Check(server.captured.count == before + 1 && [request[@"path"] isEqual:@"/v1/chat/completions"] &&
    [request[@"body"][@"model"] isEqual:@"same-wire-model"] &&
    [request[@"headers"][@"authorization"] isEqual:@"Bearer synthetic-legacy-dsh"],
    @"The legacy opaque model executes through its existing configured endpoint and credential");
  Check([round.result[@"harness_id"] isEqual:@"dsh"] && [round.result[@"model"] isEqual:model] &&
    [[store customRegistry:nil] isEqual:registryBefore],
    @"Legacy DSH execution preserves its receipt identity and leaves the independent provider registry unchanged");
}

static void BuiltinRawModelCases(NSURLSession *session) {
  [testDefaults removeObjectForKey:@"RishProviderModelsV1"];
  [testDefaults removeObjectForKey:@"rish.dsh-models.v1"];
  NSArray *harnesses = @[@"claude-code", @"codex", @"glm"];
  NSArray *models = @[@"claude-future-dynamic", @"gpt-future-dynamic", @"glm-future-dynamic"];
  NSArray *transports = @[
    [[ClaudeProviderTransport alloc] initWithSession:session uuidGenerator:nil monotonicClock:nil],
    [[CodexProviderTransport alloc] initWithSession:session uuidGenerator:nil monotonicClock:nil],
    [[GlmProviderTransport alloc] initWithSession:session uuidGenerator:nil monotonicClock:nil]];
  for (NSUInteger i = 0; i < models.count; i++) {
    NSDictionary *before = DSHProviderModelCatalog();
    Check(DSHSaveProviderModelCatalog(@{@"schema_version":@1, @"expected_revision":before[@"revision"], @"harness_id":harnesses[i],
      @"models":@[@{@"id":models[i], @"name":@"Fetched dynamic model", @"supports_images":@YES}]}, nil) != nil,
      @"A new raw upstream model can be explicitly registered without changing endpoint or credential configuration");
    DSHCompletionProviderTransport *transport = transports[i]; NSError *error = nil;
    NSDictionary *body = [transport providerRequestBodyForModel:models[i] thinkingMode:@"off"
      messages:@[@{@"role":@"user", @"content":@"Fixture"}] tools:@[] streaming:NO error:&error];
    Check(body != nil && error == nil && [body[@"model"] isEqual:models[i]],
      @"The native API body uses the exact newly registered raw model without a baked-in alias");
    NSMutableDictionary *response = [Payload(i == 1 ? @"responses" : @"messages") mutableCopy]; response[@"model"] = models[i];
    NSDictionary *parsed = [transport providerParseResponseData:JSON(response) requestedModel:models[i] thinkingMode:@"off" error:&error];
    Check(parsed != nil && error == nil, @"Native response parsing accepts the same raw provider model identity");
    if (i == 2) {
      NSDictionary *thinking = [transport providerRequestBodyForModel:models[i] thinkingMode:@"high"
        messages:@[@{@"role":@"user", @"content":@"Fixture"}] tools:@[] streaming:NO error:&error];
      Check([thinking[@"thinking"][@"type"] isEqual:@"enabled"] && thinking[@"output_config"] == nil,
        @"Lowercase GLM model IDs use the GLM budget protocol rather than Anthropic adaptive thinking");
    }
    NSDictionary *catalog = DSHProviderModelCatalog();
    Check(DSHSaveProviderModelCatalog(@{@"schema_version":@1, @"expected_revision":catalog[@"revision"],
      @"harness_id":harnesses[i], @"models":@[]}, nil) != nil && !DSHHarnessModelIsExecutable(models[i]) &&
      [DSHHarnessIdForModel(models[i]) isEqual:harnesses[i]],
      @"Retirement blocks new native dispatch while preserving the receipt's provider identity");
  }
  [testDefaults removeObjectForKey:@"RishProviderModelsV1"];
}

int main(void) {
  @autoreleasepool {
    NSString *suite = [@"rish-custom-transport-" stringByAppendingString:NSUUID.UUID.UUIDString];
    testDefaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    Method standard = class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults));
    IMP original = method_setImplementation(standard, (IMP)IsolatedDefaults);
    LoopbackServer *server = [[LoopbackServer alloc] init];
    Check([server start], @"Test server binds an ephemeral IPv4 loopback port");
    TransportDelegate *delegate = [[TransportDelegate alloc] init]; delegate.transports = [NSMutableArray array];
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.URLCache = nil; configuration.HTTPCookieStorage = nil; configuration.URLCredentialStorage = nil;
    configuration.connectionProxyDictionary = @{};
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:delegate delegateQueue:nil];
    @try {
      DSHProviderConfigurationStore *store = [[DSHProviderConfigurationStore alloc] initWithDefaults:testDefaults];
      Check(DSHProviderModelRows(NO).count == 0, @"Custom transports run with no builtin active model defaults");
      TransportCases(server, session, delegate, store);
      LegacyDshOpaqueModelCase(server, session, delegate, store);
      BuiltinRawModelCases(session);
    } @finally {
      [session invalidateAndCancel]; [server stop];
      [testDefaults removePersistentDomainForName:suite];
      method_setImplementation(standard, original);
    }
    printf("Custom provider native loopback checks passed: %lu\n", (unsigned long)checks);
  }
  return 0;
}
