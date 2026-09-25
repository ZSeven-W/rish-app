#import "DshProviderTransport.h"

#import "DSHCompletionV2.h"
#import "DSHStreamEvents.h"
#import "RishHarnessCatalog.h"
#import <os/log.h>

static NSString * const DSHCompletionTransportErrorDomain = @"DSHCompletionTransportError";

@implementation DshProviderTransport

#pragma mark Provider hooks (DeepSeek dialect)

- (NSURL *)providerBaseURL {
  return [NSURL URLWithString:@"https://api.deepseek.com/chat/completions"];
}

- (NSDictionary<NSString *, NSString *> *)providerHeadersWithCredential:(NSString *)credential {
  return @{
    @"Content-Type": @"application/json",
    @"Authorization": [@"Bearer " stringByAppendingString:credential],
  };
}

- (NSDictionary<NSString *, id> *)providerRequestBodyForModel:(NSString *)model
                                                 thinkingMode:(NSString *)thinkingMode
                                                     messages:(NSArray<NSDictionary<NSString *, id> *> *)messages
                                                        tools:(NSArray<NSDictionary<NSString *, id> *> *)tools
                                                    streaming:(BOOL)streaming
                                                        error:(NSError **)error {
  if (error != nil) *error = nil;
  // The body is the shared core's, for this dialect and the other two.
  NSString *failure = nil;
  NSDictionary *body = DSHCompletionTransportRequestBody(
      @"chat-completions", model, thinkingMode, messages, tools, streaming,
      &failure);
  if (body == nil && error != nil) {
    *error = [NSError errorWithDomain:DSHCompletionTransportErrorDomain
                                 code:2001
                             userInfo:@{NSLocalizedDescriptionKey: failure}];
  }
  return body;
}

- (NSDictionary<NSString *, id> *)providerParseResponseData:(NSData *)data
                                              requestedModel:(NSString *)requestedModel
                                                thinkingMode:(NSString *)thinkingMode
                                                      error:(NSError **)error {
  if (error != nil) *error = nil;
  NSError *decodeError = nil;
  NSDictionary *decoded = [NSJSONSerialization
      JSONObjectWithData:data options:0 error:&decodeError];
  if (![decoded isKindOfClass:NSDictionary.class]) {
    if (error != nil) {
      *error = [NSError errorWithDomain:DSHCompletionTransportErrorDomain
                                   code:2102
                               userInfo:@{NSLocalizedDescriptionKey:
                                   @"E_COMPLETION_RESPONSE_JSON"}];
    }
    return nil;
  }
  // DeepSeek's 2026-09-10 announcement explicitly routes these two retired
  // request IDs to V4.1 Flash (deepseek-flash); the vision pair was also
  // observed on device. https://deepseek.com/news/deepseek-v4-1-flash/
  // Keep the closed compatibility map here, not in the shared model parser.
  // V4 Pro is deliberately excluded: its announced transition is later.
  BOOL documentedLegacyAlias =
      [[self providerBaseURL].absoluteString isEqualToString:@"https://api.deepseek.com/chat/completions"] &&
      ([requestedModel isEqualToString:@"deepseek-v4-flash-vision-exp"] ||
       [requestedModel isEqualToString:@"deepseek-v4-flash"]) &&
      [decoded[@"model"] isKindOfClass:NSString.class] &&
      [decoded[@"model"] isEqualToString:@"deepseek-flash"];
  if (!documentedLegacyAlias) {
    return DSHParseCompletionResponseSchema2(decoded, requestedModel, thinkingMode, error);
  }
  NSMutableDictionary *canonical = [decoded mutableCopy];
  canonical[@"model"] = requestedModel;
  NSDictionary *parsed = DSHParseCompletionResponseSchema2(canonical, requestedModel, thinkingMode, error);
  if (parsed == nil) return nil;
  // Public receipts retain the canonical requested model required by their
  // existing schema. Preserve the actual wire identity in the private
  // fragment and a fixed, non-secret provenance event; never claim raw equality.
  NSMutableDictionary *withProvenance = [parsed mutableCopy];
  withProvenance[@"reported_model"] = @"deepseek-flash";
  os_log(OS_LOG_DEFAULT, "completion_model_alias harness=dsh requested_model=%{public}@ reported_model=deepseek-flash", requestedModel);
  return [withProvenance copy];
}

- (id<DSHProviderStreamEventParsing>)providerNewStreamEventParser {
  return [[DSHStreamEventParser alloc] init];
}

- (BOOL)providerSupportsStreamingRounds {
  return YES;
}

- (BOOL)providerSupportsModel:(NSString *)model {
  return [DSHHarnessIdForModel(model) isEqualToString:@"dsh"];
}

- (NSTimeInterval)providerTimeoutIntervalForStreaming:(BOOL)streaming {
  return streaming ? 120 : 600;
}

- (NSString *)providerHarnessId {
  return @"dsh";
}
@end
