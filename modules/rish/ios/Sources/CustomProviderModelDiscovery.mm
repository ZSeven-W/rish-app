#import "CustomProviderModelDiscovery.h"
#import "ProviderConfiguration.h"
#include "rish_agent_core.h"

static NSUInteger const DiscoveryPageBytes = 1024 * 1024;
static NSUInteger const DiscoveryTotalBytes = 4 * 1024 * 1024;
static NSUInteger const DiscoveryPageLimit = 8;
static NSUInteger const DiscoveryModelLimit = 512;
static NSTimeInterval const DiscoveryTimeout = 30;

BOOL DSHCustomProviderDiscoveryIsOperationId(id value) {
  if (![value isKindOfClass:NSString.class] || [value length] != 36) return NO;
  NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:value];
  return uuid && [uuid.UUIDString.lowercaseString isEqual:value];
}

static BOOL DiscoveryFieldReflectsCredential(id value, NSString *credential) {
  if (![value isKindOfClass:NSString.class] || credential.length == 0) return NO;
  return [value isEqual:credential] || (credential.length >= 8 && [value containsString:credential]);
}

static id DiscoveryPolicy(NSString *op, NSDictionary *fields, NSString **errorCode) {
  NSMutableDictionary *request = [fields mutableCopy]; request[@"op"] = op;
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
  char *raw = bytes ? rish_agent_provider_policy_reduce((const char *)bytes.bytes, bytes.length) : NULL;
  if (!raw) { if (errorCode) *errorCode = @"E_PROVIDER_MODEL_DISCOVERY_INVALID"; return nil; }
  size_t size = strnlen(raw, 1024 * 1024 + 1);
  NSData *replyBytes = size <= 1024 * 1024 ? [NSData dataWithBytes:raw length:size] : nil;
  rish_agent_string_free(raw);
  id reply = replyBytes ? [NSJSONSerialization JSONObjectWithData:replyBytes options:0 error:nil] : nil;
  if (![reply isKindOfClass:NSDictionary.class] || ![reply[@"ok"] isEqual:@YES]) {
    NSString *code = [reply isKindOfClass:NSDictionary.class] ? reply[@"error"] : nil;
    if (errorCode) *errorCode = [@[@"E_PROVIDER_MODEL_DISCOVERY_INVALID", @"E_PROVIDER_MODEL_DISCOVERY_LIMIT",
      @"E_PROVIDER_MODEL_DISCOVERY_UNSUPPORTED"] containsObject:code] ? code : @"E_PROVIDER_MODEL_DISCOVERY_INVALID";
    return nil;
  }
  return reply[@"value"];
}

@interface DSHCustomProviderModelDiscovery ()
@property(nonatomic, copy) NSDictionary *configuration;
@property(nonatomic, copy) NSString *operationId;
@property(nonatomic, copy) NSString *credential;
@property(nonatomic, copy) BOOL (^sourceIsCurrent)(void);
@property(nonatomic, copy) void (^completion)(NSDictionary *, NSString *);
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic, strong) NSMutableData *pageData;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *models;
@property(nonatomic, strong) NSMutableSet<NSString *> *modelIds;
@property(nonatomic, strong) NSMutableSet<NSString *> *cursors;
@property(nonatomic, copy) NSURLComponents *endpoint;
@property(nonatomic) NSUInteger totalBytes;
@property(nonatomic) NSUInteger pages;
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL finished;
@end

@implementation DSHCustomProviderModelDiscovery
- (instancetype)initWithConfiguration:(NSDictionary *)configuration operationId:(NSString *)operationId credential:(NSString *)credential
                     sourceIsCurrent:(BOOL (^)(void))sourceIsCurrent
                          completion:(void (^)(NSDictionary *, NSString *))completion {
  if ((self = [super init])) {
    _configuration = [configuration copy]; _operationId = [operationId copy]; _credential = [credential copy];
    _sourceIsCurrent = [sourceIsCurrent copy]; _completion = [completion copy];
    _models = [NSMutableArray array]; _modelIds = [NSMutableSet set]; _cursors = [NSMutableSet set];
  }
  return self;
}
- (BOOL)isRunning { @synchronized(self) { return self.started && !self.finished; } }
- (BOOL)current {
  @try { return self.sourceIsCurrent && self.sourceIsCurrent(); }
  @catch (__unused NSException *exception) { return NO; }
}
- (BOOL)finish:(NSDictionary *)result error:(NSString *)errorCode {
  if (result && ![self current]) { result = nil; errorCode = @"E_PROVIDER_CONFIGURATION_CHANGED"; }
  void (^completion)(NSDictionary *, NSString *) = nil;
  NSURLSession *session = nil;
  @synchronized(self) {
    if (self.finished) return NO;
    self.finished = YES; completion = self.completion; self.completion = nil;
    self.credential = nil; session = self.session; self.session = nil;
    self.task = nil; self.pageData = nil;
  }
  [session invalidateAndCancel];
  if (completion) completion(result, errorCode);
  return YES;
}
- (void)cancel { [self finish:nil error:@"E_PROVIDER_MODEL_DISCOVERY_CANCELLED"]; }
- (BOOL)cancelForProviderId:(NSString *)providerId operationId:(NSString *)operationId {
  if (!DSHCustomProviderDiscoveryIsOperationId(providerId) || !DSHCustomProviderDiscoveryIsOperationId(operationId)) return NO;
  return [self cancelForHarnessId:[@"custom-" stringByAppendingString:providerId] operationId:operationId];
}
- (BOOL)cancelForHarnessId:(NSString *)harnessId operationId:(NSString *)operationId {
  if (!DSHCustomProviderDiscoveryIsOperationId(operationId) ||
      (!DSHIsCustomProviderHarness(harnessId) && ![@[@"dsh", @"claude-code", @"codex", @"glm"] containsObject:harnessId])) return NO;
  @synchronized(self) {
    if (!self.started || self.finished || ![self.operationId isEqual:operationId] ||
        ![self.configuration[@"harness_id"] isEqual:harnessId]) return NO;
  }
  return [self finish:nil error:@"E_PROVIDER_MODEL_DISCOVERY_CANCELLED"];
}
- (void)start {
  @synchronized(self) { if (self.started || self.finished) return; self.started = YES; }
  if (!DSHCustomProviderDiscoveryIsOperationId(self.operationId)) { [self finish:nil error:@"E_PROVIDER_MODEL_DISCOVERY_INVALID"]; return; }
  if (![self current]) { [self finish:nil error:@"E_PROVIDER_CONFIGURATION_CHANGED"]; return; }
  NSString *harness = self.configuration[@"harness_id"];
  BOOL builtin = [@[@"dsh", @"claude-code", @"codex", @"glm"] containsObject:harness];
  // Official profiles are an exact shared-core value, not editable provider
  // configurations. Normalizing them would change their credential identity.
  NSDictionary *configuration = builtin && [self.configuration[@"official"] isEqual:@YES]
    ? DiscoveryPolicy(@"defaults", @{@"harness_id":harness}, nil)
    : DSHNormalizeProviderConfiguration(self.configuration);
  if (!configuration || ![configuration isEqual:self.configuration] ||
      (!builtin && !DSHIsCustomProviderHarness(harness))) {
    [self finish:nil error:@"E_PROVIDER_MODEL_DISCOVERY_INVALID"]; return;
  }
  BOOL hasCredential;
  @synchronized(self) { hasCredential = self.credential.length > 0; }
  if (DSHProviderRequiresCredential(configuration) && !hasCredential) {
    [self finish:nil error:@"E_PROVIDER_MODEL_DISCOVERY_CREDENTIAL"]; return;
  }
  NSURLComponents *endpoint = [NSURLComponents componentsWithString:configuration[@"endpoint_url"]];
  NSString *error = nil;
  NSString *path = DiscoveryPolicy(@"models_endpoint_path", @{@"path":endpoint.percentEncodedPath ?: @"",
    @"protocol":configuration[@"protocol"]}, &error);
  if (![path isKindOfClass:NSString.class]) { [self finish:nil error:error]; return; }
  endpoint.percentEncodedPath = path; endpoint.query = nil; endpoint.fragment = nil;
  self.endpoint = endpoint;
  NSURLSessionConfiguration *sessionConfiguration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
  sessionConfiguration.URLCache = nil; sessionConfiguration.HTTPCookieStorage = nil;
  sessionConfiguration.URLCredentialStorage = nil; sessionConfiguration.HTTPShouldSetCookies = NO;
  sessionConfiguration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
  sessionConfiguration.timeoutIntervalForRequest = 15; sessionConfiguration.timeoutIntervalForResource = DiscoveryTimeout;
  NSOperationQueue *queue = [[NSOperationQueue alloc] init]; queue.maxConcurrentOperationCount = 1;
  @synchronized(self) {
    // A stop during profile validation may already have finished the request.
    // Creating a delegate session after that would leave it unowned by finish.
    if (self.finished) return;
    self.session = [NSURLSession sessionWithConfiguration:sessionConfiguration delegate:self delegateQueue:queue];
  }
  __weak DSHCustomProviderModelDiscovery *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(DiscoveryTimeout * NSEC_PER_SEC)),
    dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      [weakSelf finish:nil error:@"E_PROVIDER_MODEL_DISCOVERY_TIMEOUT"];
    });
  [self fetchPageAfter:nil];
}
- (void)fetchPageAfter:(NSString *)cursor {
  if (![self current]) { [self finish:nil error:@"E_PROVIDER_CONFIGURATION_CHANGED"]; return; }
  NSURLComponents *url = [self.endpoint copy];
  // The only pagination input used is a validated model id. A server-provided
  // URL, host, path or header can never redirect this authenticated request.
  if (cursor) url.queryItems = @[[NSURLQueryItem queryItemWithName:@"after_id" value:cursor]];
  NSURL *target = url.URL;
  if (!target || ![url.scheme isEqual:self.endpoint.scheme] || ![url.host isEqual:self.endpoint.host] ||
      !((url.port == nil && self.endpoint.port == nil) || [url.port isEqual:self.endpoint.port]) ||
      ![url.percentEncodedPath isEqual:self.endpoint.percentEncodedPath]) {
    [self finish:nil error:@"E_PROVIDER_MODEL_DISCOVERY_INVALID"]; return;
  }
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:target];
  request.HTTPMethod = @"GET"; request.HTTPShouldHandleCookies = NO;
  request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData; request.timeoutInterval = 15;
  [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
  @synchronized(self) {
    if (self.finished) return;
    NSString *auth = self.configuration[@"auth_type"];
    if ([auth isEqual:@"bearer"]) [request setValue:[@"Bearer " stringByAppendingString:self.credential] forHTTPHeaderField:@"Authorization"];
    else if ([@[@"x-api-key", @"api-key"] containsObject:auth]) [request setValue:self.credential forHTTPHeaderField:auth];
    if ([self.configuration[@"protocol"] isEqual:@"messages"])
      [request setValue:@"2023-06-01" forHTTPHeaderField:@"anthropic-version"];
    self.pages += 1; self.pageData = [NSMutableData data];
    self.task = [self.session dataTaskWithRequest:request]; [self.task resume];
  }
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
    didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
  if (![self current]) { completionHandler(NSURLSessionResponseCancel); [self finish:nil error:@"E_PROVIDER_CONFIGURATION_CHANGED"]; return; }
  NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
  NSString *error = nil;
  if (status == 401 || status == 403) error = @"E_PROVIDER_MODEL_DISCOVERY_AUTH";
  else if (status < 200 || status >= 300) error = @"E_PROVIDER_MODEL_DISCOVERY_HTTP";
  else if (response.expectedContentLength > (int64_t)DiscoveryPageBytes) error = @"E_PROVIDER_MODEL_DISCOVERY_LIMIT";
  if (error) { completionHandler(NSURLSessionResponseCancel); [self finish:nil error:error]; }
  else completionHandler(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
  if (![self current]) { [self finish:nil error:@"E_PROVIDER_CONFIGURATION_CHANGED"]; return; }
  BOOL overflow = NO;
  @synchronized(self) {
    if (self.finished || task != self.task) return;
    overflow = data.length > DiscoveryPageBytes - self.pageData.length || data.length > DiscoveryTotalBytes - self.totalBytes;
    if (!overflow) { [self.pageData appendData:data]; self.totalBytes += data.length; }
  }
  if (overflow) [self finish:nil error:@"E_PROVIDER_MODEL_DISCOVERY_LIMIT"];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
  NSData *bytes = nil;
  NSString *credential = nil;
  @synchronized(self) {
    if (self.finished || task != self.task) return;
    bytes = [self.pageData copy]; credential = self.credential; self.task = nil;
  }
  if (![self current]) { [self finish:nil error:@"E_PROVIDER_CONFIGURATION_CHANGED"]; return; }
  if (error) {
    [self finish:nil error:([error.domain isEqual:NSURLErrorDomain] && error.code == NSURLErrorTimedOut)
      ? @"E_PROVIDER_MODEL_DISCOVERY_TIMEOUT" : @"E_PROVIDER_MODEL_DISCOVERY_TRANSPORT"]; return;
  }
  NSString *body = [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
  if (!body) { [self finish:nil error:@"E_PROVIDER_MODEL_DISCOVERY_INVALID"]; return; }
  NSString *failure = nil;
  NSDictionary *page = DiscoveryPolicy(@"models_parse_page", @{@"protocol":self.configuration[@"protocol"], @"response_body":body}, &failure);
  if (![page isKindOfClass:NSDictionary.class]) { [self finish:nil error:failure]; return; }
  BOOL truncated = NO;
  BOOL rejectCredentialEcho = ![self.configuration[@"auth_type"] isEqual:@"none"] && credential.length > 0;
  // A retired row may be filtered out of candidates while its id remains
  // the pagination cursor. Never put a reflected credential into a URL.
  if (rejectCredentialEcho && DiscoveryFieldReflectsCredential(page[@"last_id"], credential)) {
    [self finish:nil error:@"E_PROVIDER_MODEL_DISCOVERY_INVALID"]; return;
  }
  for (NSDictionary *row in page[@"models"]) {
    // Inspect parsed fields, so JSON escapes cannot hide a reflected key.
    // Short test/local keys match exactly; longer keys also match substrings.
    for (NSString *field in @[@"wire_model", @"name"]) {
      NSString *value = row[field];
      if (rejectCredentialEcho && DiscoveryFieldReflectsCredential(value, credential)) {
        [self finish:nil error:@"E_PROVIDER_MODEL_DISCOVERY_INVALID"]; return;
      }
    }
    if ([self.modelIds containsObject:row[@"wire_model"]]) { [self finish:nil error:@"E_PROVIDER_MODEL_DISCOVERY_INVALID"]; return; }
    if (self.models.count == DiscoveryModelLimit) { truncated = YES; break; }
    [self.models addObject:row]; [self.modelIds addObject:row[@"wire_model"]];
  }
  BOOL more = [page[@"has_more"] boolValue];
  if (more && (self.pages >= DiscoveryPageLimit || self.models.count >= DiscoveryModelLimit)) truncated = YES;
  if (more && !truncated) {
    NSString *cursor = page[@"last_id"];
    if (![cursor isKindOfClass:NSString.class] || [self.cursors containsObject:cursor]) { [self finish:nil error:@"E_PROVIDER_MODEL_DISCOVERY_INVALID"]; return; }
    [self.cursors addObject:cursor]; [self fetchPageAfter:cursor]; return;
  }
  [self finish:@{@"models":[self.models copy], @"truncated":@(truncated)} error:nil];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response
       newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
  completionHandler(nil); [self finish:nil error:@"E_PROVIDER_MODEL_DISCOVERY_REDIRECT"];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
    completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
  // TLS server trust uses the OS verifier. No ambient HTTP credentials or
  // client certificate can be substituted for this profile's explicit auth.
  completionHandler([challenge.protectionSpace.authenticationMethod isEqual:NSURLAuthenticationMethodServerTrust]
    ? NSURLSessionAuthChallengePerformDefaultHandling : NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
}
@end
