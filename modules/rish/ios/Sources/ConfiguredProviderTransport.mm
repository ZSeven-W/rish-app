#import "ConfiguredProviderTransport.h"
#import "ClaudeProviderTransport.h"
#import "CodexProviderTransport.h"
#import "DshProviderTransport.h"
#import "DSHCompletionV2.h"
#import "RishHarnessCatalog.h"

static NSError *ProviderError(NSString *code) {
  return [NSError errorWithDomain:@"RishConfiguredProvider" code:1 userInfo:@{NSLocalizedDescriptionKey:code}];
}
@interface DSHConfiguredProviderTransport ()
@property(nonatomic, copy) NSString *harness;
@property(nonatomic, strong) DSHProviderConfigurationStore *store;
@property(nonatomic, strong) ClaudeProviderTransport *messages;
@property(nonatomic, strong) CodexProviderTransport *responses;
@property(nonatomic, strong) DshProviderTransport *chat;
@end
static BOOL DSHRelayResponseIdUsable(id value) {
  if (![value isKindOfClass:NSString.class]) return NO;
  NSString *text = value;
  if (text.length < 1 || text.length > 128) return NO;
  NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
      @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:-"];
  return [text rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

@implementation DSHConfiguredProviderTransport
- (instancetype)initWithHarness:(NSString *)harness session:(NSURLSession *)session
                   uuidGenerator:(NSString *(^)(void))uuidGenerator
                  monotonicClock:(NSTimeInterval (^)(void))clock
                           store:(DSHProviderConfigurationStore *)store {
  if ((self = [super initWithSession:session uuidGenerator:uuidGenerator monotonicClock:clock])) {
    _harness = harness; _store = store;
    _messages = [[ClaudeProviderTransport alloc] initWithSession:session uuidGenerator:uuidGenerator monotonicClock:clock];
    _responses = [[CodexProviderTransport alloc] initWithSession:session uuidGenerator:uuidGenerator monotonicClock:clock];
    _chat = [[DshProviderTransport alloc] initWithSession:session uuidGenerator:uuidGenerator monotonicClock:clock];
  }
  return self;
}
- (NSDictionary *)profile { return [self.store configurationForHarness:self.harness]; }
- (DSHCompletionProviderTransport *)dialect {
  NSString *protocol = [self profile][@"protocol"];
  if ([protocol isEqual:@"messages"]) return self.messages;
  if ([protocol isEqual:@"responses"]) return self.responses;
  if ([protocol isEqual:@"chat-completions"]) return self.chat;
  return nil;
}
- (NSURL *)providerBaseURL { return [NSURL URLWithString:[self profile][@"endpoint_url"] ?: @""]; }
- (NSString *)providerHarnessId { return self.harness; }
- (BOOL)providerSupportsModel:(NSString *)model { return [DSHHarnessIdForModel(model) isEqual:self.harness]; }
- (NSDictionary *)providerConfigurationForModel:(NSString *)model {
  return DSHProviderBindingFromConfiguration([self profile], model);
}
- (NSDictionary *)providerHeadersWithCredential:(NSString *)credential {
  NSString *auth = [self profile][@"auth_type"];
  NSMutableDictionary *headers = [@{@"Content-Type": @"application/json"} mutableCopy];
  if ([auth isEqual:@"bearer"]) headers[@"Authorization"] = [@"Bearer " stringByAppendingString:credential];
  else if ([@[@"x-api-key", @"api-key"] containsObject:auth]) headers[auth] = credential;
  if ([[self profile][@"protocol"] isEqual:@"messages"]) headers[@"anthropic-version"] = @"2023-06-01";
  return headers;
}
- (NSDictionary *)providerRequestBodyForModel:(NSString *)model thinkingMode:(NSString *)thinkingMode
                                     messages:(NSArray *)messages tools:(NSArray *)tools
                                    streaming:(BOOL)streaming error:(NSError **)error {
  NSDictionary *profile = [self profile];
  if (profile == nil || ![self providerSupportsModel:model]) {
    if (error) *error = ProviderError(@"E_COMPLETION_BODY_INVALID");
    return nil;
  }
  NSString *protocol = profile[@"protocol"];
  NSString *dialectModel = [protocol isEqual:@"messages"] ? @"claude-haiku-4-5-20251001" :
      ([protocol isEqual:@"responses"] ? @"gpt-5.6" : @"deepseek-v4-flash");
  // Keep the built-in dialect for official requests and compatible aliases.
  if ([[self dialect] providerSupportsModel:model]) dialectModel = model;
  NSMutableDictionary *body = [[[self dialect] providerRequestBodyForModel:dialectModel
      thinkingMode:thinkingMode messages:messages tools:tools streaming:streaming error:error] mutableCopy];
  if (body == nil) return nil;
  body[@"model"] = profile[@"model_mappings"][model] ?: model;
  if (![profile[@"send_reasoning"] boolValue]) {
    for (NSString *key in @[@"thinking", @"reasoning", @"reasoning_effort", @"output_config"])
      [body removeObjectForKey:key];
  }
  return body;
}
- (NSDictionary *)providerParseResponseData:(NSData *)data requestedModel:(NSString *)model
                               thinkingMode:(NSString *)thinkingMode error:(NSError **)error {
  NSDictionary *profile = [self profile];
  if (profile == nil) { if (error) *error = ProviderError(@"E_COMPLETION_BODY_INVALID"); return nil; }
  if ([profile[@"official"] boolValue]) return [[self dialect] providerParseResponseData:data
      requestedModel:model thinkingMode:thinkingMode error:error];
  id raw = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![raw isKindOfClass:NSDictionary.class]) {
    if (error) *error = ProviderError(@"E_COMPLETION_RESPONSE_JSON"); return nil;
  }
  NSString *wireModel = profile[@"model_mappings"][model] ?: model;
  id echoed = raw[@"model"];
  BOOL messages = [profile[@"protocol"] isEqual:@"messages"];
  BOOL chat = [profile[@"protocol"] isEqual:@"chat-completions"];
  // A relay the person configured answers for the model they chose under
  // whatever name it uses -- a dated name, or the model it redirected to.
  // Any bounded printable name is accepted, and so is none; the name never
  // selects anything, the chosen model stays on the receipt, and what the
  // relay reported is logged. Same rule as Android's
  // AndroidConfiguredModelIdentity.
  BOOL reportedAcceptable = echoed == nil || echoed == NSNull.null ||
      ([echoed isKindOfClass:NSString.class] && [(NSString *)echoed length] <= 256 &&
       [(NSString *)echoed rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound);
  if (!reportedAcceptable) {
    if (error) *error = ProviderError(@"E_COMPLETION_MODEL_MISMATCH"); return nil;
  }
  if ([echoed isKindOfClass:NSString.class] && ![echoed isEqual:wireModel]) {
    NSLog(@"completion_model_alias requested_model=%@ reported_model=%@", wireModel, echoed);
  }
  NSString *parseModel = messages ? @"claude-haiku-4-5-20251001" : (chat ? model : @"gpt-5.6");
  if ([[self dialect] providerSupportsModel:model]) parseModel = model;
  NSMutableDictionary *decoded = [raw mutableCopy];
  decoded[@"model"] = parseModel;
  // A relay may send no response id, or one a receipt cannot hold (1-128 of
  // [A-Za-z0-9._:-]). Refusing the reply over it failed the round after the
  // answer had arrived; it is named by an id of ours instead. Rounds are
  // deduplicated by the request id, so this one need not be the provider's.
  if (!DSHRelayResponseIdUsable(raw[@"id"])) {
    NSLog(@"completion_response_id_substituted harness=%@", self.harness);
    decoded[@"id"] = [@"rish-" stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];
  }
  if (chat) {
    NSArray *choices = [decoded[@"choices"] isKindOfClass:NSArray.class] ? decoded[@"choices"] : nil;
    NSDictionary *choice = choices.count == 1 && [choices[0] isKindOfClass:NSDictionary.class] ? choices[0] : nil;
    NSDictionary *message = [choice[@"message"] isKindOfClass:NSDictionary.class] ? choice[@"message"] : nil;
    if ([choice[@"finish_reason"] isEqual:@"tool_calls"] && message[@"content"] == NSNull.null) {
      NSMutableDictionary *updatedMessage = [message mutableCopy]; updatedMessage[@"content"] = @"";
      NSMutableDictionary *updatedChoice = [choice mutableCopy]; updatedChoice[@"message"] = updatedMessage;
      decoded[@"choices"] = @[updatedChoice];
    }
  }
  NSData *normalized = [NSJSONSerialization dataWithJSONObject:decoded options:0 error:error];
  NSDictionary *parsed = chat ? DSHParseCompletionResponseSchema2(decoded, model, thinkingMode, error) :
      [[self dialect] providerParseResponseData:normalized requestedModel:parseModel thinkingMode:thinkingMode error:error];
  if (parsed == nil) return nil;
  NSMutableDictionary *result = [parsed mutableCopy]; result[@"model"] = model;
  return result;
}
- (BOOL)providerSupportsStreamingRounds { return [[self dialect] providerSupportsStreamingRounds]; }
- (id<DSHProviderStreamResponseAssembling>)providerNewStreamResponseAssemblerWithThinkingMode:(NSString *)thinkingMode
                                                                                  maximumBytes:(NSUInteger)maximumBytes {
  return [[self dialect] providerNewStreamResponseAssemblerWithThinkingMode:thinkingMode maximumBytes:maximumBytes];
}
- (id<DSHProviderStreamEventParsing>)providerNewStreamEventParser { return [[self dialect] providerNewStreamEventParser]; }
- (NSTimeInterval)providerTimeoutIntervalForStreaming:(BOOL)streaming { return [[self dialect] providerTimeoutIntervalForStreaming:streaming]; }
@end
