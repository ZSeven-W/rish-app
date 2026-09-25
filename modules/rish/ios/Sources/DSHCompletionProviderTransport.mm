#import "DSHCompletionProviderTransport.h"

#import "DSHCompletionV2.h"
#import "DSHStreamEvents.h"

#import <CommonCrypto/CommonDigest.h>
#import <os/log.h>

#include "rish_agent_core.h"

#include <math.h>

static NSUInteger const DSHCompletionTransportMaximumRequestBytes = 40 * 1024 * 1024;
static NSUInteger const DSHCompletionTransportMaximumResponseBytes = 8 * 1024 * 1024;

static NSString *DSHCompletionTransportSHA256(NSData *data) {
  if (![data isKindOfClass:NSData.class]) return nil;
  unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {};
  CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  NSMutableString *hex = [NSMutableString
      stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
  for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index += 1) {
    [hex appendFormat:@"%02x", digest[index]];
  }
  return hex;
}

static NSString *DSHCompletionTransportJSONSHA256(id value) {
  if (value == nil || ![NSJSONSerialization isValidJSONObject:value]) {
    return nil;
  }
  NSData *data = [NSJSONSerialization dataWithJSONObject:value
                                                  options:NSJSONWritingSortedKeys
                                                    error:nil];
  return DSHCompletionTransportSHA256(data);
}

static BOOL DSHCompletionTransportValidRequestId(NSString *value) {
  if (![value isKindOfClass:NSString.class] || value.length != 36) return NO;
  NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:value];
  return uuid != nil && [uuid.UUIDString.lowercaseString isEqualToString:value];
}

// Which failure a round may report is a closed vocabulary, and it lives in the
// shared core (modules/rish/core, `rish_agent_completion_response_reduce`):
// the controller switches on these codes to decide whether a retry could help,
// so a code outside the set would be a failure nothing knows how to recover
// from.
/// One round's request body, from the shared core
/// (crates/rish-agent-core/src/completion_request.rs).
///
/// Every dialect's body is built there, from the same recorded cases in
/// RishTests/Fixtures that this suite replays. `failureCode` comes back as
/// the core's own word for a refusal, so each dialect can report it in the
/// numbers its callers already switch on.
NSDictionary *DSHCompletionTransportRequestBody(NSString *dialect,
                                                NSString *model,
                                                NSString *thinkingMode,
                                                NSArray *messages,
                                                NSArray *tools,
                                                BOOL streaming,
                                                NSString **failureCode) {
  if (failureCode != nil) *failureCode = @"E_COMPLETION_BODY_INVALID";
  NSDictionary *envelope = @{
    @"op" : @"request_body",
    @"dialect" : dialect,
    @"model" : model ?: @"",
    @"thinking_mode" : thinkingMode ?: @"",
    @"streaming" : @(streaming),
    @"messages" : messages ?: @[],
    @"tools" : tools ?: @[],
  };
  if (![NSJSONSerialization isValidJSONObject:envelope]) return nil;
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:envelope options:0
                                                    error:nil];
  char *raw = bytes == nil ? NULL : rish_agent_completion_response_reduce(
      (const char *)bytes.bytes, bytes.length);
  if (raw == NULL) return nil;
  NSData *replyBytes = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  id reply = [NSJSONSerialization JSONObjectWithData:replyBytes options:0
                                                error:nil];
  if (![reply isKindOfClass:NSDictionary.class]) return nil;
  if (![reply[@"ok"] isEqual:@YES]) {
    if (failureCode != nil && [reply[@"failure_code"] isKindOfClass:NSString.class]) {
      *failureCode = reply[@"failure_code"];
    }
    return nil;
  }
  NSDictionary *body = reply[@"body"];
  return [body isKindOfClass:NSDictionary.class] ? body : nil;
}

static NSString *DSHCompletionTransportFailureCode(NSString *op,
                                                    NSDictionary *fields,
                                                    NSString *fallback) {
  NSMutableDictionary *envelope = [fields mutableCopy];
  envelope[@"op"] = op;
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:envelope options:0
                                                    error:nil];
  char *raw = bytes == nil ? NULL : rish_agent_completion_response_reduce(
      (const char *)bytes.bytes, bytes.length);
  if (raw == NULL) return fallback;
  NSData *replyBytes = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  id reply = [NSJSONSerialization JSONObjectWithData:replyBytes options:0
                                                error:nil];
  id code = [reply isKindOfClass:NSDictionary.class] &&
      [reply[@"ok"] isEqual:@YES] ? reply[@"failure_code"] : nil;
  return [code isKindOfClass:NSString.class] ? code : fallback;
}

/// The seam stays fail-closed: a verbose diagnostic or a third-party NSError
/// must never travel onward as a failure code.
static NSString *DSHCompletionTransportParserErrorCode(NSError *error) {
  return DSHCompletionTransportFailureCode(@"parser_failure", @{
    @"candidate" : error.localizedDescription ?: @"",
  }, @"E_COMPLETION_EMPTY_RESPONSE");
}

@interface DSHCompletionProviderTransportContext : NSObject
@property(nonatomic) NSInteger schemaVersion;
@property(nonatomic, copy) NSString *roundId;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSUInteger credentialGeneration;
@property(nonatomic, copy) DSHCompletionProviderTransportCredentialGenerationIsCurrentBlock credentialGenerationIsCurrent;
@property(nonatomic, copy) DSHCompletionProviderTransportClaimRoundBlock claimRound;
@property(nonatomic, copy) DSHCompletionProviderTransportMarkRedirectedBlock markRedirected;
@property(nonatomic, copy) DSHCompletionProviderTransportRedirectDecisionBlock redirectDecision;
@property(nonatomic, copy) DSHCompletionProviderTransportCompletionBlock completion;
@property(nonatomic) NSTimeInterval startedAt;
// Per-request values the settle path needs; captured here so streamed and
// buffered tasks settle through one method.
@property(nonatomic, copy) NSString *requestedModel;
@property(nonatomic, copy) NSString *thinkingMode;
@property(nonatomic, copy) NSString *providerRequestId;
@property(nonatomic, copy, nullable) NSDictionary *providerConfiguration;
@property(nonatomic, copy) NSString *visibleDigest;
@property(nonatomic, copy) NSString *modelInputDigest;
@property(nonatomic, copy) NSString *bodyDigest;
// Streamed rounds only.
@property(nonatomic) BOOL streaming;
@property(nonatomic, strong, nullable) id<DSHProviderStreamEventParsing> parser;
@property(nonatomic, strong, nullable) id<DSHProviderStreamResponseAssembling> assembler;
@property(nonatomic, copy, nullable) DSHCompletionProviderTransportPreviewBlock preview;
@property(nonatomic) NSInteger statusCode;
@property(nonatomic, strong, nullable) NSMutableData *errorBody;
@property(nonatomic, copy, nullable) NSString *failureCode;
@end

@implementation DSHCompletionProviderTransportContext
@end

@interface DSHCompletionProviderTransport ()
@property(nonatomic, weak) NSURLSession *session;
@property(nonatomic, copy) NSString *(^uuidGenerator)(void);
@property(nonatomic, copy) NSTimeInterval (^monotonicClock)(void);
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, DSHCompletionProviderTransportContext *> *contexts;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *refusalStatuses;
@end

@interface DSHHTTPCompletionExecution : NSObject <DSHCompletionExecution>
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic, strong) DSHCompletionProviderTransport *transport;
@end
@implementation DSHHTTPCompletionExecution
- (void)cancel { [self.transport cancelTask:self.task]; }
- (NSURLSessionDataTask *)underlyingHTTPTask { return self.task; }
@end

@implementation DSHCompletionProviderTransport

#if DEBUG
static NSString *DSHCompletionTransportDiagnosticKind(NSError *error,
                                                      BOOL hasHTTPResponse) {
  if (hasHTTPResponse) return @"http_status";
  if (error == nil) return @"non_http";
  if (![error.domain isEqualToString:NSURLErrorDomain]) return @"other";
  switch (error.code) {
    case NSURLErrorTimedOut: return @"timeout";
    case NSURLErrorCannotFindHost:
    case NSURLErrorDNSLookupFailed: return @"dns";
    case NSURLErrorSecureConnectionFailed:
    case NSURLErrorServerCertificateUntrusted:
    case NSURLErrorServerCertificateHasBadDate:
    case NSURLErrorServerCertificateHasUnknownRoot:
    case NSURLErrorClientCertificateRejected:
    case NSURLErrorClientCertificateRequired: return @"tls";
    case NSURLErrorCancelled: return @"cancelled";
    case NSURLErrorNotConnectedToInternet:
    case NSURLErrorNetworkConnectionLost:
    case NSURLErrorCannotConnectToHost:
    case NSURLErrorInternationalRoamingOff:
    case NSURLErrorDataNotAllowed:
    case NSURLErrorCallIsActive:
    case NSURLErrorResourceUnavailable: return @"network";
    default: return @"other";
  }
}

- (void)emitDiagnosticForContext:(DSHCompletionProviderTransportContext *)context
                            error:(NSError *)error
                    responseStatus:(NSNumber *)responseStatus
                 callbackSignaled:(BOOL)callbackSignaled {
  if (context == nil) return;
  NSTimeInterval finished = context.startedAt;
  @try { finished = self.monotonicClock(); } @catch (__unused NSException *exception) {}
  NSInteger elapsedMs = (NSInteger)floor(MAX(0, finished - context.startedAt) * 1000.0 + 0.000001);
  BOOL hasHTTPResponse = responseStatus != nil && responseStatus != (id)NSNull.null;
  NSString *harness = [self.providerHarnessId isEqualToString:@"dsh"] ||
      [self.providerHarnessId isEqualToString:@"claude-code"] ||
      [self.providerHarnessId isEqualToString:@"codex"] ||
      [self.providerHarnessId isEqualToString:@"glm"]
      ? self.providerHarnessId : @"unknown";
  NSDictionary *diagnostic = @{
    @"phase": hasHTTPResponse ? @"response" : @"response_callback",
    @"harness": harness,
    @"schema_version": @(context.schemaVersion),
    @"elapsed_ms": @(elapsedMs),
    @"error_kind": DSHCompletionTransportDiagnosticKind(error, hasHTTPResponse),
    @"error_code": error == nil ? @0 : @(error.code),
    @"http_status": responseStatus ?: (id)NSNull.null,
    @"callback_signaled": @(callbackSignaled),
  };
  DSHCompletionProviderTransportDiagnosticBlock handler = self.diagnosticHandler;
  if (handler != nil) handler(diagnostic);
  os_log_info(OS_LOG_DEFAULT, "completion_transport phase=%{public}@ harness=%{public}@ schema=%{public}ld elapsed_ms=%{public}ld error_kind=%{public}@ error_code=%{public}ld http_status=%{public}@ callback_signaled=%{public}@",
              diagnostic[@"phase"], diagnostic[@"harness"], [diagnostic[@"schema_version"] longValue],
              [diagnostic[@"elapsed_ms"] longValue], diagnostic[@"error_kind"],
              [diagnostic[@"error_code"] longValue], diagnostic[@"http_status"], diagnostic[@"callback_signaled"]);
}
#endif

- (instancetype)initWithSession:(NSURLSession *)session
                   uuidGenerator:(NSString *(^)(void))uuidGenerator
                  monotonicClock:(NSTimeInterval (^)(void))monotonicClock {
  self = [super init];
  if (self != nil) {
    _session = session;
    _uuidGenerator = [uuidGenerator copy] ?: [^NSString *{
      return NSUUID.UUID.UUIDString.lowercaseString;
    } copy];
    _monotonicClock = [monotonicClock copy] ?: [^NSTimeInterval {
      return NSProcessInfo.processInfo.systemUptime;
    } copy];
    _contexts = [NSMutableDictionary dictionary];
  }
  return self;
}

- (NSString *)nextProviderRequestId:(NSString **)errorCode {
  NSString *value = nil;
  @try {
    value = self.uuidGenerator();
  } @catch (__unused NSException *exception) {
    value = nil;
  }
  if (!DSHCompletionTransportValidRequestId(value)) {
    if (errorCode != nil) *errorCode = @"E_COMPLETION_PROVIDER_REQUEST_ID";
    return nil;
  }
  if (errorCode != nil) *errorCode = nil;
  return value;
}

- (DSHCompletionProviderTransportContext *)contextForTaskIdentifier:(NSUInteger)taskIdentifier {
  @synchronized (self) {
    return self.contexts[@(taskIdentifier)];
  }
}

- (void)removeContextForTaskIdentifier:(NSUInteger)taskIdentifier {
  @synchronized (self) {
    [self.contexts removeObjectForKey:@(taskIdentifier)];
  }
}

- (void)settleStartFailure:(NSString *)errorCode
                 claimRound:(DSHCompletionProviderTransportClaimRoundBlock)claimRound
                completion:(DSHCompletionProviderTransportCompletionBlock)completion {
  BOOL current = NO;
  @try {
    current = claimRound != nil && claimRound(nil);
  } @catch (__unused NSException *exception) {
    current = NO;
  }
  if (current && completion != nil) completion(nil, errorCode);
}

- (NSURLSessionDataTask *)startRequestWithSchemaVersion:(NSInteger)schemaVersion
                                                 roundId:(NSString *)roundId
                                                generation:(NSUInteger)generation
                                      credentialGeneration:(NSUInteger)credentialGeneration
                                       providerRequestId:(NSString *)providerRequestId
                                             credential:(NSString *)credential
                                         requestedModel:(NSString *)requestedModel
                                          thinkingMode:(NSString *)thinkingMode
                           credentialGenerationIsCurrent:(DSHCompletionProviderTransportCredentialGenerationIsCurrentBlock)credentialGenerationIsCurrent
                                              startedAt:(NSTimeInterval)startedAt
                                              bodyData:(NSData *)bodyData
                                        visibleHistory:(NSArray *)visibleHistory
                                            modelInput:(NSArray *)modelInput
                                             bindTask:(DSHCompletionProviderTransportBindTaskBlock)bindTask
                                           claimRound:(DSHCompletionProviderTransportClaimRoundBlock)claimRound
                                      markRedirected:(DSHCompletionProviderTransportMarkRedirectedBlock)markRedirected
                                    redirectDecision:(DSHCompletionProviderTransportRedirectDecisionBlock)redirectDecision
                                           completion:(DSHCompletionProviderTransportCompletionBlock)completion {
  return [self startRequestWithSchemaVersion:schemaVersion roundId:roundId
      generation:generation credentialGeneration:credentialGeneration
      providerRequestId:providerRequestId credential:credential
      requestedModel:requestedModel thinkingMode:thinkingMode
      credentialGenerationIsCurrent:credentialGenerationIsCurrent
      startedAt:startedAt bodyData:bodyData visibleHistory:visibleHistory
      modelInput:modelInput streaming:NO preview:nil bindTask:bindTask
      claimRound:claimRound markRedirected:markRedirected
      redirectDecision:redirectDecision completion:completion];
}

- (NSURLSessionDataTask *)startRequestWithSchemaVersion:(NSInteger)schemaVersion
                                                 roundId:(NSString *)roundId
                                                generation:(NSUInteger)generation
                                      credentialGeneration:(NSUInteger)credentialGeneration
                                       providerRequestId:(NSString *)providerRequestId
                                             credential:(NSString *)credential
                                         requestedModel:(NSString *)requestedModel
                                          thinkingMode:(NSString *)thinkingMode
                           credentialGenerationIsCurrent:(DSHCompletionProviderTransportCredentialGenerationIsCurrentBlock)credentialGenerationIsCurrent
                                              startedAt:(NSTimeInterval)startedAt
                                              bodyData:(NSData *)bodyData
                                        visibleHistory:(NSArray *)visibleHistory
                                            modelInput:(NSArray *)modelInput
                                             streaming:(BOOL)streaming
                                               preview:(DSHCompletionProviderTransportPreviewBlock)preview
                                             bindTask:(DSHCompletionProviderTransportBindTaskBlock)bindTask
                                           claimRound:(DSHCompletionProviderTransportClaimRoundBlock)claimRound
                                      markRedirected:(DSHCompletionProviderTransportMarkRedirectedBlock)markRedirected
                                    redirectDecision:(DSHCompletionProviderTransportRedirectDecisionBlock)redirectDecision
                                           completion:(DSHCompletionProviderTransportCompletionBlock)completion {
  if ((schemaVersion != 2 && schemaVersion != 3) ||
      !DSHCompletionTransportValidRequestId(roundId)) {
    [self settleStartFailure:@"E_COMPLETION_SCHEMA"
                   claimRound:claimRound completion:completion];
    return nil;
  }
  if (!DSHCompletionTransportValidRequestId(providerRequestId)) {
    [self settleStartFailure:@"E_COMPLETION_PROVIDER_REQUEST_ID"
                   claimRound:claimRound completion:completion];
    return nil;
  }
  if (![credential isKindOfClass:NSString.class] || credential.length == 0) {
    [self settleStartFailure:@"E_COMPLETION_CREDENTIAL_UNAVAILABLE"
                   claimRound:claimRound completion:completion];
    return nil;
  }
  if (![requestedModel isKindOfClass:NSString.class] || requestedModel.length == 0 ||
      ![thinkingMode isKindOfClass:NSString.class] || thinkingMode.length == 0 ||
      ![bodyData isKindOfClass:NSData.class] || bodyData.length == 0) {
    [self settleStartFailure:@"E_COMPLETION_BODY_INVALID"
                   claimRound:claimRound completion:completion];
    return nil;
  }
  BOOL generationCurrent = YES;
  @try {
    generationCurrent = credentialGenerationIsCurrent == nil ||
        credentialGenerationIsCurrent(credentialGeneration);
  } @catch (__unused NSException *exception) {
    generationCurrent = NO;
  }
  if (!generationCurrent) {
    [self settleStartFailure:@"E_COMPLETION_CREDENTIAL_CHANGED"
                   claimRound:claimRound completion:completion];
    return nil;
  }
  if (bodyData.length > DSHCompletionTransportMaximumRequestBytes) {
    [self settleStartFailure:@"E_COMPLETION_BODY_TOO_LARGE"
                   claimRound:claimRound completion:completion];
    return nil;
  }

  NSString *visibleDigest = DSHCompletionTransportJSONSHA256(visibleHistory);
  NSString *modelInputDigest = DSHCompletionTransportJSONSHA256(modelInput);
  NSString *bodyDigest = DSHCompletionTransportSHA256(bodyData);
  if (visibleDigest == nil || modelInputDigest == nil || bodyDigest == nil) {
    [self settleStartFailure:@"E_COMPLETION_BODY_INVALID"
                   claimRound:claimRound completion:completion];
    return nil;
  }
  NSURLSession *session = self.session;
  if (session == nil) {
    [self settleStartFailure:@"E_COMPLETION_TRANSPORT"
                   claimRound:claimRound completion:completion];
    return nil;
  }

  NSDictionary *providerConfiguration = [self providerConfigurationForModel:requestedModel];
  NSURL *url = [self providerBaseURL];
  if (url == nil || [self providerHarnessId].length == 0) {
    [self settleStartFailure:@"E_COMPLETION_TRANSPORT"
                   claimRound:claimRound completion:completion];
    return nil;
  }
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = @"POST";
  request.HTTPShouldHandleCookies = NO;
  request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
  request.timeoutInterval = [self providerTimeoutIntervalForStreaming:streaming];
  NSDictionary<NSString *, NSString *> *headers =
      [self providerHeadersWithCredential:credential];
  for (NSString *field in headers) {
    [request setValue:headers[field] forHTTPHeaderField:field];
  }
  if (streaming) [request setValue:@"text/event-stream" forHTTPHeaderField:@"Accept"];
  request.HTTPBody = bodyData;

  DSHCompletionProviderTransportContext *context =
      [[DSHCompletionProviderTransportContext alloc] init];
  context.schemaVersion = schemaVersion;
  context.startedAt = startedAt;
  context.roundId = [roundId copy];
  context.generation = generation;
  context.credentialGeneration = credentialGeneration;
  context.credentialGenerationIsCurrent = [credentialGenerationIsCurrent copy];
  context.claimRound = [claimRound copy];
  context.markRedirected = [markRedirected copy];
  context.redirectDecision = [redirectDecision copy];
  context.completion = [completion copy];
  context.requestedModel = requestedModel;
  context.thinkingMode = thinkingMode;
  context.providerRequestId = providerRequestId;
  context.providerConfiguration = providerConfiguration;
  context.visibleDigest = visibleDigest;
  context.modelInputDigest = modelInputDigest;
  context.bodyDigest = bodyDigest;
  if (streaming) {
    id<DSHProviderStreamEventParsing> parser = [self providerNewStreamEventParser];
    if (parser == nil) {
      [self settleStartFailure:@"E_COMPLETION_TRANSPORT"
                     claimRound:claimRound completion:completion];
      return nil;
    }
    context.streaming = YES;
    context.parser = parser;
    context.assembler = [self providerNewStreamResponseAssemblerWithThinkingMode:thinkingMode
        maximumBytes:DSHCompletionTransportMaximumResponseBytes];
    if (context.assembler == nil) {
      [self settleStartFailure:@"E_COMPLETION_TRANSPORT"
                     claimRound:claimRound completion:completion];
      return nil;
    }
    context.preview = preview;
    context.statusCode = 0;
  }

  __block NSUInteger taskIdentifier = NSUIntegerMax;
  NSURLSessionDataTask *task = nil;
  @try {
    if (streaming) {
      // Delegate-driven: the session owner forwards data callbacks to
      // streamingTask:... and the round settles in didCompleteWithError.
      task = [session dataTaskWithRequest:request];
    } else {
    task = [session dataTaskWithRequest:request
                      completionHandler:^(NSData *data,
                                          NSURLResponse *response,
                                          NSError *transportError) {
      DSHCompletionProviderTransportContext *owned =
          [self contextForTaskIdentifier:taskIdentifier];
      if (owned == nil) return;
      [self removeContextForTaskIdentifier:taskIdentifier];
      [self settleContext:owned data:data response:response
           transportError:transportError];
    }];
    }
  } @catch (__unused NSException *exception) {
    [self settleStartFailure:@"E_COMPLETION_TRANSPORT"
                   claimRound:claimRound completion:completion];
    return nil;
  }
  if (task == nil) {
    [self settleStartFailure:@"E_COMPLETION_TRANSPORT"
                   claimRound:claimRound completion:completion];
    return nil;
  }
  taskIdentifier = task.taskIdentifier;
  @synchronized (self) {
    self.contexts[@(taskIdentifier)] = context;
  }
  BOOL bound = NO;
  @try {
    bound = bindTask != nil && bindTask(task);
  } @catch (__unused NSException *exception) {
    bound = NO;
  }
  if (!bound) {
    [self removeContextForTaskIdentifier:taskIdentifier];
    [task cancel];
    [self settleStartFailure:@"E_COMPLETION_TRANSPORT"
                   claimRound:claimRound completion:completion];
    return nil;
  }
  @try {
    generationCurrent = context.credentialGenerationIsCurrent == nil ||
        context.credentialGenerationIsCurrent(credentialGeneration);
  } @catch (__unused NSException *exception) {
    generationCurrent = NO;
  }
  if (!generationCurrent) {
    [self removeContextForTaskIdentifier:taskIdentifier];
    [task cancel];
    [self settleStartFailure:@"E_COMPLETION_CREDENTIAL_CHANGED"
                   claimRound:claimRound completion:completion];
    return nil;
  }
  [task resume];
  return task;
}

/// Settles one owned request whose context has already been removed from
/// the routing table. `data` is the buffered body (single-shot) or, for a
/// streamed round, the assembled single-shot object (2xx) / the bounded
/// error body (non-2xx).
- (void)settleContext:(DSHCompletionProviderTransportContext *)owned
                 data:(NSData *)data
             response:(NSURLResponse *)response
       transportError:(NSError *)transportError {
  NSString *requestedModel = owned.requestedModel;
  NSString *thinkingMode = owned.thinkingMode;
  NSString *providerRequestId = owned.providerRequestId;
  NSDictionary *providerConfiguration = owned.providerConfiguration;
  NSString *visibleDigest = owned.visibleDigest;
  NSString *modelInputDigest = owned.modelInputDigest;
  NSString *bodyDigest = owned.bodyDigest;
  NSTimeInterval startedAt = owned.startedAt;
  {
    {
      BOOL redirected = NO;
      BOOL current = NO;
      @try {
        current = owned.claimRound != nil && owned.claimRound(&redirected);
      } @catch (__unused NSException *exception) {
        current = NO;
      }
      if (!current) return;
      BOOL generationCurrent = YES;
      @try {
        generationCurrent = owned.credentialGenerationIsCurrent == nil ||
            owned.credentialGenerationIsCurrent(owned.credentialGeneration);
      } @catch (__unused NSException *exception) {
        generationCurrent = NO;
      }
      NSDictionary *currentConfiguration = [self providerConfigurationForModel:requestedModel];
      BOOL configurationCurrent = (currentConfiguration == nil && providerConfiguration == nil) ||
          [currentConfiguration isEqual:providerConfiguration];
      if (!generationCurrent || !configurationCurrent) {
        if (owned.completion != nil) {
          owned.completion(nil, @"E_COMPLETION_CREDENTIAL_CHANGED");
        }
        return;
      }
      if (redirected) {
        if (owned.completion != nil) {
          owned.completion(nil, @"E_COMPLETION_REDIRECT");
        }
        return;
      }
      if (transportError != nil ||
          ![response isKindOfClass:NSHTTPURLResponse.class]) {
#if DEBUG
        [self emitDiagnosticForContext:owned
                                  error:transportError
                          responseStatus:nil
                       callbackSignaled:owned.completion != nil];
#endif
        if (owned.completion != nil) {
          BOOL timedOut = [transportError.domain isEqualToString:NSURLErrorDomain] &&
              transportError.code == NSURLErrorTimedOut;
          owned.completion(nil, timedOut ? @"E_COMPLETION_TIMEOUT" : @"E_COMPLETION_TRANSPORT");
        }
        return;
      }
      NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
      if (http.statusCode < 200 || http.statusCode >= 300) {
#if DEBUG
        [self emitDiagnosticForContext:owned
                                  error:nil
                          responseStatus:@(http.statusCode)
                       callbackSignaled:owned.completion != nil];
#endif
        if (owned.providerRequestId.length > 0) {
          @synchronized (self) {
            if (self.refusalStatuses == nil) self.refusalStatuses = [NSMutableDictionary dictionary];
            // Bounded: a status nobody takes is dropped with the oldest.
            if (self.refusalStatuses.count >= 16) [self.refusalStatuses removeAllObjects];
            self.refusalStatuses[owned.providerRequestId] = @(http.statusCode);
          }
        }
        if (owned.completion != nil) {
          owned.completion(nil, [self providerErrorCodeForHTTPStatus:http.statusCode
                                                                 data:data]);
        }
        return;
      }
      if (data.length == 0 || data.length > DSHCompletionTransportMaximumResponseBytes) {
        if (owned.completion != nil) {
          owned.completion(nil, @"E_COMPLETION_RESPONSE_SIZE");
        }
        return;
      }
      NSError *parseError = nil;
      NSDictionary *parsed = [self providerParseResponseData:data
                                              requestedModel:requestedModel
                                                thinkingMode:thinkingMode
                                                      error:&parseError];
      if (parsed == nil) {
        // Retain only bounded shape facts for a rejected response. Never log
        // response text, reasoning, arguments, identifiers, or credentials.
        id decoded = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSArray *choices = [decoded isKindOfClass:NSDictionary.class] && [decoded[@"choices"] isKindOfClass:NSArray.class] ? decoded[@"choices"] : nil;
        NSDictionary *choice = choices.count > 0 && [choices[0] isKindOfClass:NSDictionary.class] ? choices[0] : nil;
        NSDictionary *message = [choice[@"message"] isKindOfClass:NSDictionary.class] ? choice[@"message"] : nil;
        NSString *finish = [@[@"stop", @"tool_calls", @"length", @"content_filter"] containsObject:choice[@"finish_reason"] ?: NSNull.null] ? choice[@"finish_reason"] : @"other";
        NSInteger calls = [message[@"tool_calls"] isKindOfClass:NSArray.class] ? [message[@"tool_calls"] count] : -1;
        NSInteger contentBytes = [message[@"content"] isKindOfClass:NSString.class] ? [message[@"content"] lengthOfBytesUsingEncoding:NSUTF8StringEncoding] : -1;
        NSInteger reasoningBytes = [message[@"reasoning_content"] isKindOfClass:NSString.class] ? [message[@"reasoning_content"] lengthOfBytesUsingEncoding:NSUTF8StringEncoding] : -1;
        id responseModel = [decoded isKindOfClass:NSDictionary.class] ? decoded[@"model"] : nil;
        BOOL modelIsString = [responseModel isKindOfClass:NSString.class];
        BOOL modelMatches = modelIsString && [responseModel isEqual:requestedModel];
        id usage = [decoded isKindOfClass:NSDictionary.class] ? decoded[@"usage"] : nil;
        id tokens = [usage isKindOfClass:NSDictionary.class] ? usage[@"completion_tokens"] : nil;
        NSInteger outputTokens = [tokens isKindOfClass:NSNumber.class] && [tokens doubleValue] >= 0 && [tokens doubleValue] <= 1000000 ? [tokens integerValue] : -1;
        os_log_error(OS_LOG_DEFAULT, "completion_parser_reject code=%{public}@ finish=%{public}@ calls=%{public}ld content_bytes=%{public}ld reasoning_bytes=%{public}ld response_bytes=%{public}lu model_present=%{public}d model_is_string=%{public}d model_matches_requested=%{public}d output_tokens=%{public}ld", DSHCompletionTransportParserErrorCode(parseError), finish, calls, contentBytes, reasoningBytes, (unsigned long)data.length, responseModel != nil, modelIsString, modelMatches, outputTokens);
        if (owned.completion != nil) {
          owned.completion(nil, DSHCompletionTransportParserErrorCode(parseError));
        }
        return;
      }
      NSTimeInterval finished = startedAt;
      @try {
        finished = self.monotonicClock();
      } @catch (__unused NSException *exception) {
        finished = startedAt;
      }
      NSInteger latencyMs = (NSInteger)floor(MAX(0, finished - startedAt) *
          1000.0 + 0.000001);
      NSDictionary *result = @{
        @"provider_request_id": providerRequestId,
        @"provider_response_id": parsed[@"provider_response_id"],
        @"harness_id": [self providerHarnessId],
        @"requested_model": requestedModel,
        @"model": parsed[@"model"],
        @"thinking_mode": thinkingMode,
        @"text": parsed[@"text"],
        @"reasoning": parsed[@"reasoning"],
        @"tool_calls": DSHCompletionNormalizeToolCalls(parsed[@"tool_calls"]),
        @"finish_reason": parsed[@"finish_reason"],
        @"latency_ms": @(latencyMs),
        @"visible_history_sha256": visibleDigest,
        @"model_input_sha256": modelInputDigest,
        @"request_body_sha256": bodyDigest,
      };
      if (providerConfiguration != nil) {
        NSMutableDictionary *bound = [result mutableCopy];
        bound[@"provider_configuration"] = providerConfiguration;
        result = bound;
      }
      if (owned.completion != nil) owned.completion(result, nil);
    }
  }
}

#pragma mark Streamed rounds

- (void)streamingTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response {
  DSHCompletionProviderTransportContext *context =
      [self contextForTaskIdentifier:task.taskIdentifier];
  if (context == nil || !context.streaming) return;
  context.statusCode = [response isKindOfClass:NSHTTPURLResponse.class]
      ? ((NSHTTPURLResponse *)response).statusCode : -1;
}

- (void)streamingTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
  DSHCompletionProviderTransportContext *context =
      [self contextForTaskIdentifier:task.taskIdentifier];
  if (context == nil || !context.streaming || context.failureCode != nil ||
      data.length == 0) return;
  if (context.statusCode < 200 || context.statusCode >= 300) {
    // Not an event stream: keep a bounded copy for the status → code map.
    if (context.errorBody == nil) context.errorBody = [NSMutableData data];
    NSUInteger room = 64 * 1024 - MIN(context.errorBody.length, (NSUInteger)64 * 1024);
    [context.errorBody appendBytes:data.bytes length:MIN(data.length, room)];
    return;
  }
  NSError *parseError = nil;
  NSArray<NSDictionary *> *deltas = [context.parser
      appendBytes:static_cast<const uint8_t *>(data.bytes)
           length:data.length error:&parseError];
  if (deltas == nil) {
    context.failureCode = parseError.code == 2104 || parseError.code == 2105
        ? @"E_COMPLETION_RESPONSE_SIZE" : @"E_COMPLETION_RESPONSE_JSON";
    [task cancel];
    return;
  }
  [self applyStreamedDeltas:deltas toContext:context task:task];
}

- (void)applyStreamedDeltas:(NSArray<NSDictionary *> *)deltas
                  toContext:(DSHCompletionProviderTransportContext *)context
                       task:(NSURLSessionTask *)task {
  if ([context.parser respondsToSelector:@selector(streamedResponseId)] &&
      [context.parser respondsToSelector:@selector(streamedModel)]) {
    [context.assembler noteResponseId:[(id)context.parser streamedResponseId]
                                model:[(id)context.parser streamedModel]];
  }
  for (NSDictionary *delta in deltas) {
    NSError *assembleError = nil;
    if (![context.assembler appendDelta:delta error:&assembleError]) {
      context.failureCode = assembleError.code == 2201
          ? @"E_COMPLETION_RESPONSE_SIZE" : @"E_COMPLETION_TOOL_CALL_INVALID";
      [task cancel];
      return;
    }
    if (context.preview != nil && [delta[@"type"] isEqual:@"delta"]) {
      @try { context.preview(delta); } @catch (__unused NSException *exception) {}
    }
  }
}

- (void)streamingTask:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
  DSHCompletionProviderTransportContext *owned =
      [self contextForTaskIdentifier:task.taskIdentifier];
  if (owned == nil || !owned.streaming) return;
  [self removeContextForTaskIdentifier:task.taskIdentifier];
  NSURLResponse *response = task.response;
  BOOL ok = error == nil && [response isKindOfClass:NSHTTPURLResponse.class] &&
      owned.statusCode >= 200 && owned.statusCode < 300;
  if (owned.failureCode == nil && ok) {
    NSError *flushError = nil;
    NSArray *flushed = [owned.parser finish:&flushError];
    if (flushed == nil) {
      owned.failureCode = flushError.code == 2104 || flushError.code == 2105
          ? @"E_COMPLETION_RESPONSE_SIZE" : @"E_COMPLETION_RESPONSE_JSON";
    } else {
      [self applyStreamedDeltas:flushed toContext:owned task:task];
    }
  }
  if (owned.failureCode != nil) {
    // The transport itself cancelled the task; report the parse/budget
    // failure, never the resulting NSURLErrorCancelled.
    BOOL current = NO;
    BOOL redirected = NO;
    @try {
      current = owned.claimRound != nil && owned.claimRound(&redirected);
    } @catch (__unused NSException *exception) {
      current = NO;
    }
    if (current && owned.completion != nil) owned.completion(nil, owned.failureCode);
    return;
  }
  NSData *data = nil;
  if (ok) {
    NSError *encodeError = nil;
    data = [NSJSONSerialization dataWithJSONObject:[owned.assembler responseObject]
                                           options:0 error:&encodeError];
  } else {
    data = owned.errorBody ?: [NSData data];
  }
  [self settleContext:owned data:data response:response transportError:error];
}

- (id<DSHCompletionExecution>)startStreamingExecutionWithSchemaVersion:(NSInteger)schemaVersion
                                                               roundId:(NSString *)roundId
                                                            generation:(NSUInteger)generation
                                                  credentialGeneration:(NSUInteger)credentialGeneration
                                                     providerRequestId:(NSString *)providerRequestId
                                                            credential:(NSString *)credential
                                                        requestedModel:(NSString *)requestedModel
                                                          thinkingMode:(NSString *)thinkingMode
                                         credentialGenerationIsCurrent:(DSHCompletionProviderTransportCredentialGenerationIsCurrentBlock)credentialGenerationIsCurrent
                                                             startedAt:(NSTimeInterval)startedAt
                                                              bodyData:(NSData *)bodyData
                                                        visibleHistory:(NSArray *)visibleHistory
                                                            modelInput:(NSArray *)modelInput
                                                               preview:(DSHCompletionProviderTransportPreviewBlock)preview
                                                         bindExecution:(DSHCompletionProviderTransportBindExecutionBlock)bindExecution
                                                            claimRound:(DSHCompletionProviderTransportClaimRoundBlock)claimRound
                                                        markRedirected:(DSHCompletionProviderTransportMarkRedirectedBlock)markRedirected
                                                      redirectDecision:(DSHCompletionProviderTransportRedirectDecisionBlock)redirectDecision
                                                            completion:(DSHCompletionProviderTransportCompletionBlock)completion {
  if (![self providerSupportsStreamingRounds]) {
    return [self startExecutionWithSchemaVersion:schemaVersion roundId:roundId
        generation:generation credentialGeneration:credentialGeneration
        providerRequestId:providerRequestId credential:credential
        requestedModel:requestedModel thinkingMode:thinkingMode
        credentialGenerationIsCurrent:credentialGenerationIsCurrent
        startedAt:startedAt bodyData:bodyData visibleHistory:visibleHistory
        modelInput:modelInput bindExecution:bindExecution claimRound:claimRound
        markRedirected:markRedirected redirectDecision:redirectDecision
        completion:completion];
  }
  DSHHTTPCompletionExecution *execution = [DSHHTTPCompletionExecution new];
  execution.transport = self;
  NSURLSessionDataTask *task = [self startRequestWithSchemaVersion:schemaVersion
    roundId:roundId generation:generation credentialGeneration:credentialGeneration
    providerRequestId:providerRequestId credential:credential requestedModel:requestedModel
    thinkingMode:thinkingMode credentialGenerationIsCurrent:credentialGenerationIsCurrent
    startedAt:startedAt bodyData:bodyData visibleHistory:visibleHistory modelInput:modelInput
    streaming:YES preview:preview
    bindTask:^BOOL(NSURLSessionDataTask *candidate) {
      execution.task = candidate;
      return bindExecution != nil && bindExecution(execution);
    } claimRound:claimRound markRedirected:markRedirected redirectDecision:redirectDecision completion:completion];
  return task == nil ? nil : execution;
}

- (BOOL)handlesTask:(NSURLSessionTask *)task {
  if (task == nil) return NO;
  @synchronized (self) {
    return self.contexts[@(task.taskIdentifier)] != nil;
  }
}

- (void)cancelTask:(NSURLSessionDataTask *)task {
  if (task == nil) return;
  [task cancel];
  [self removeContextForTaskIdentifier:task.taskIdentifier];
}

- (void)handleHTTPRedirectionForTask:(NSURLSessionTask *)task
                          newRequest:(NSURLRequest *)request
                   completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
  if (completionHandler == nil) return;
  DSHCompletionProviderTransportContext *context =
      [self contextForTaskIdentifier:task.taskIdentifier];
  if (context == nil) {
    completionHandler(request);
    return;
  }
  @try {
    if (context.markRedirected != nil) {
      context.markRedirected((NSURLSessionDataTask *)task);
    }
  } @catch (__unused NSException *exception) {
  }
  @try {
    if (context.redirectDecision != nil) context.redirectDecision(YES);
  } @catch (__unused NSException *exception) {
  }
  completionHandler(nil);
}

#pragma mark Provider hooks (abstract)

/// The base class owns the generic completion-slot, digest, cancellation,
/// and redirect orchestration only. Every provider dialect lives in a
/// subclass (DshProviderTransport, ClaudeProviderTransport,
/// CodexProviderTransport); an unimplemented hook fails closed.

- (BOOL)hasActiveRequests { @synchronized(self) { return self.contexts.count > 0; } }

- (NSDictionary *)providerConfigurationForModel:(NSString *)model { return nil; }

- (NSURL *)providerBaseURL {
  return nil;
}

- (NSDictionary<NSString *, NSString *> *)providerHeadersWithCredential:(NSString *)credential {
  return @{};
}

- (NSDictionary<NSString *, id> *)providerRequestBodyForModel:(NSString *)model
                                                 thinkingMode:(NSString *)thinkingMode
                                                     messages:(NSArray<NSDictionary<NSString *, id> *> *)messages
                                                        tools:(NSArray<NSDictionary<NSString *, id> *> *)tools
                                                    streaming:(BOOL)streaming
                                                        error:(NSError **)error {
  if (error != nil) {
    *error = [NSError errorWithDomain:@"DSHCompletionTransportError"
                                 code:2001
                             userInfo:@{NSLocalizedDescriptionKey:
                                 @"E_COMPLETION_BODY_INVALID"}];
  }
  return nil;
}

- (NSDictionary<NSString *, id> *)providerParseResponseData:(NSData *)data
                                              requestedModel:(NSString *)requestedModel
                                                thinkingMode:(NSString *)thinkingMode
                                                      error:(NSError **)error {
  if (error != nil) {
    *error = [NSError errorWithDomain:@"DSHCompletionTransportError"
                                 code:2002
                             userInfo:@{NSLocalizedDescriptionKey:
                                 @"E_COMPLETION_RESPONSE_JSON"}];
  }
  return nil;
}

- (NSInteger)takeRefusalHTTPStatusForProviderRequestId:(NSString *)providerRequestId {
  if (providerRequestId.length == 0) return 0;
  @synchronized (self) {
    NSNumber *status = self.refusalStatuses[providerRequestId];
    [self.refusalStatuses removeObjectForKey:providerRequestId];
    return status.integerValue;
  }
}

- (NSString *)providerErrorCodeForHTTPStatus:(NSInteger)statusCode
                                         data:(NSData *)data {
  // An unauthenticated or forbidden call means the stored credential is
  // unusable; a rate limit or provider overload gets its own stable code so
  // the caller can back off instead of retrying as a generic status failure.
  (void)data;
  return DSHCompletionTransportFailureCode(@"http_status_failure", @{
    @"status" : @(statusCode),
  }, @"E_COMPLETION_HTTP_STATUS");
}

- (id<DSHProviderStreamEventParsing>)providerNewStreamEventParser {
  return nil;
}

- (BOOL)providerSupportsStreamingRounds {
  return NO;
}

- (id<DSHProviderStreamResponseAssembling>)providerNewStreamResponseAssemblerWithThinkingMode:(NSString *)thinkingMode
                                                                                  maximumBytes:(NSUInteger)maximumBytes {
  return [[DSHStreamResponseAssembler alloc] initWithThinkingMode:thinkingMode
                                                     maximumBytes:maximumBytes];
}

- (BOOL)providerSupportsModel:(NSString *)model {
  return NO;
}

// Silence, not length, is what times out: 120 s without a byte on a stream,
// 600 s for a reply that only arrives whole. A round that thinks at the
// highest setting and writes a whole file takes minutes.
- (NSTimeInterval)providerTimeoutIntervalForStreaming:(BOOL)streaming {
  return streaming ? 120 : 600;
}

- (NSString *)providerHarnessId {
  return nil;
}


- (BOOL)isReadyWithCredential:(NSString *)credential { return [credential isKindOfClass:NSString.class] && credential.length > 0; }
- (BOOL)supportsTools { return YES; }
// The whole round: 15 minutes, as the subscription transport has. 120 s cut
// long replies off while they were still arriving, and a dispatched round
// cut off is an ambiguous one (beta report, 2026-09-25).
- (NSTimeInterval)executionTimeoutInterval { return 900; }
- (id<DSHCompletionExecution>)startExecutionWithSchemaVersion:(NSInteger)schemaVersion
                                                           roundId:(NSString *)roundId
                                                          generation:(NSUInteger)generation
                                                credentialGeneration:(NSUInteger)credentialGeneration
                                                 providerRequestId:(NSString *)providerRequestId
                                                       credential:(NSString *)credential
                                                   requestedModel:(NSString *)requestedModel
                                                    thinkingMode:(NSString *)thinkingMode
                                     credentialGenerationIsCurrent:(DSHCompletionProviderTransportCredentialGenerationIsCurrentBlock)credentialGenerationIsCurrent
                                                        startedAt:(NSTimeInterval)startedAt
                                                        bodyData:(NSData *)bodyData
                                                  visibleHistory:(NSArray *)visibleHistory
                                                      modelInput:(NSArray *)modelInput
                                                       bindExecution:(DSHCompletionProviderTransportBindExecutionBlock)bindExecution
                                                     claimRound:(DSHCompletionProviderTransportClaimRoundBlock)claimRound
                                                markRedirected:(DSHCompletionProviderTransportMarkRedirectedBlock)markRedirected
                                              redirectDecision:(DSHCompletionProviderTransportRedirectDecisionBlock)redirectDecision
                                                     completion:(DSHCompletionProviderTransportCompletionBlock)completion {
  DSHHTTPCompletionExecution *execution = [DSHHTTPCompletionExecution new];
  execution.transport = self;
  NSURLSessionDataTask *task = [self startRequestWithSchemaVersion:schemaVersion
    roundId:roundId generation:generation credentialGeneration:credentialGeneration
    providerRequestId:providerRequestId credential:credential requestedModel:requestedModel
    thinkingMode:thinkingMode credentialGenerationIsCurrent:credentialGenerationIsCurrent
    startedAt:startedAt bodyData:bodyData visibleHistory:visibleHistory modelInput:modelInput
    bindTask:^BOOL(NSURLSessionDataTask *candidate) {
      execution.task = candidate;
      return bindExecution != nil && bindExecution(execution);
    } claimRound:claimRound markRedirected:markRedirected redirectDecision:redirectDecision completion:completion];
  return task == nil ? nil : execution;
}
@end
