#import "ProviderConfiguration.h"
#import "RishHarnessCatalog.h"
#import "HarnessAuthService.h"
#import "AgentNativeWAL.h"
#include <CoreFoundation/CoreFoundation.h>

static NSString *const SettingsKey = @"RishCustomProviderConfigurationsV1";
/// Every harness can go through a relay the person configured.
static BOOL Supported(id value) {
  return [value isEqual:@"claude-code"] || [value isEqual:@"codex"] ||
      [value isEqual:@"dsh"] || [value isEqual:@"glm"];
}
static BOOL Text(id value, NSUInteger maximum) {
  if (![value isKindOfClass:NSString.class]) return NO;
  NSData *bytes = [value dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
  if (bytes == nil || bytes.length == 0 || bytes.length > maximum) return NO;
  return [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}
static BOOL Keys(NSDictionary *value, NSArray *keys) {
  return [value isKindOfClass:NSDictionary.class] &&
      [[NSSet setWithArray:value.allKeys] isEqual:[NSSet setWithArray:keys]];
}
static NSString *Digest(NSDictionary *value) {
  return DSHAgentHJ(@"provider-configuration-v1", value, nil);
}
static NSString *NormalizeEndpoint(NSString *value, NSString *protocol, BOOL fullURL) {
  if (!Text(value, 2048) || ![@[@"messages", @"responses", @"chat-completions"] containsObject:protocol]) return nil;
  NSString *trimmed = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  NSURLComponents *url = [NSURLComponents componentsWithString:trimmed];
  NSString *host = url.host.lowercaseString;
  BOOL local = [@[@"localhost", @"127.0.0.1", @"::1", @"[::1]"] containsObject:host];
  if (host.length == 0 || url.user != nil || url.password != nil || url.query != nil ||
      url.fragment != nil || (! [url.scheme.lowercaseString isEqual:@"https"] &&
      !(local && [url.scheme.lowercaseString isEqual:@"http"]))) return nil;
  if (url.port != nil && (url.port.integerValue < 1 || url.port.integerValue > 65535)) return nil;
  url.scheme = url.scheme.lowercaseString;
  url.host = host;
  if (fullURL) return url.URL.absoluteString;
  NSString *suffix = [protocol isEqual:@"messages"] ? @"messages" :
      ([protocol isEqual:@"responses"] ? @"responses" : @"chat/completions");
  NSString *path = url.path ?: @"";
  while ([path hasSuffix:@"/"]) path = [path substringToIndex:path.length - 1];
  BOOL knownEndpoint = NO;
  for (NSString *known in @[@"/chat/completions", @"/responses", @"/messages"]) {
    if ([path hasSuffix:known]) { path = [path substringToIndex:path.length - known.length]; knownEndpoint = YES; break; }
  }
  if (![path hasSuffix:[@"/" stringByAppendingString:suffix]]) {
    if (!knownEndpoint && ![path hasSuffix:@"/v1"]) path = [path stringByAppendingString:@"/v1"];
    path = [path stringByAppendingFormat:@"/%@", suffix];
  }
  url.path = path;
  return url.URL.absoluteString;
}
NSString *DSHNormalizeProviderEndpoint(NSString *value, NSString *protocol) {
  return NormalizeEndpoint(value, protocol, NO);
}
NSDictionary *DSHNormalizeProviderConfiguration(id raw) {
  if (![raw isKindOfClass:NSDictionary.class]) return nil;
  id fullURL = raw[@"full_url"];
  if (fullURL != nil && (![fullURL isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)fullURL) != CFBooleanGetTypeID())) return nil;
  NSMutableDictionary *required = [raw mutableCopy]; [required removeObjectForKey:@"full_url"];
  if (!Keys(required, @[@"schema_version", @"harness_id", @"name", @"endpoint_url", @"protocol", @"auth_type", @"model_mappings", @"send_reasoning"]) ||
      ![raw[@"schema_version"] isEqual:@1] || CFGetTypeID((__bridge CFTypeRef)raw[@"schema_version"]) == CFBooleanGetTypeID() ||
      !Supported(raw[@"harness_id"]) || !Text(raw[@"name"], 80) ||
      ![@[@"bearer", @"x-api-key", @"api-key"] containsObject:raw[@"auth_type"]] ||
      ![raw[@"model_mappings"] isKindOfClass:NSDictionary.class] ||
      ![raw[@"send_reasoning"] isKindOfClass:NSNumber.class] ||
      CFGetTypeID((__bridge CFTypeRef)raw[@"send_reasoning"]) != CFBooleanGetTypeID()) return nil;
  NSString *endpoint = NormalizeEndpoint(raw[@"endpoint_url"], raw[@"protocol"], [fullURL boolValue]);
  if (endpoint == nil) return nil;
  NSDictionary *mappings = raw[@"model_mappings"];
  // DSH's catalog holds up to 32 models, and each may be mapped.
  if (mappings.count > 32) return nil;
  for (id model in mappings) {
    if (![DSHHarnessIdForModel(model) isEqual:raw[@"harness_id"]] || !Text(mappings[model], 128) ||
        [mappings[model] rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) return nil;
  }
  NSMutableDictionary *normalized = [raw mutableCopy];
  normalized[@"endpoint_url"] = endpoint;
  normalized[@"full_url"] = fullURL ?: @NO;
  normalized[@"model_mappings"] = [mappings copy];
  return [normalized copy];
}

@interface DSHProviderConfigurationStore ()
@property(nonatomic, strong) NSUserDefaults *defaults;
@end
@implementation DSHProviderConfigurationStore
+ (instancetype)sharedStore {
  static DSHProviderConfigurationStore *store;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ store = [[self alloc] initWithDefaults:NSUserDefaults.standardUserDefaults]; });
  return store;
}
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {
  if ((self = [super init])) _defaults = defaults;
  return self;
}
- (NSDictionary *)configurationForHarness:(NSString *)harness {
  if (!Supported(harness)) return nil;
  @synchronized(self) {
    id all = [self.defaults objectForKey:SettingsKey];
    if (all != nil && ![all isKindOfClass:NSDictionary.class]) return nil;
    id saved = all[harness];
    if (saved != nil) return DSHNormalizeProviderConfiguration(saved);
    // The official service each harness speaks to, shown as the starting
    // point of a custom configuration.
    NSArray *official = @{
      @"claude-code": @[@"https://api.anthropic.com/v1/messages", @"messages", @"x-api-key"],
      @"codex": @[@"https://api.openai.com/v1/responses", @"responses", @"bearer"],
      @"dsh": @[@"https://api.deepseek.com/chat/completions", @"chat-completions", @"bearer"],
      @"glm": @[@"https://open.bigmodel.cn/api/anthropic/v1/messages", @"messages", @"x-api-key"],
    }[harness];
    return @{@"schema_version": @1, @"harness_id": harness, @"name": @"", @"endpoint_url": official[0],
             @"protocol": official[1], @"auth_type": official[2],
             @"model_mappings": @{}, @"send_reasoning": @YES, @"official": @YES};
  }
}
- (NSDictionary *)saveConfiguration:(NSDictionary *)configuration error:(NSError **)error {
  NSDictionary *normalized = DSHNormalizeProviderConfiguration(configuration);
  if (normalized == nil) {
    if (error != nil) *error = [NSError errorWithDomain:@"RishProviderConfiguration" code:1
        userInfo:@{NSLocalizedDescriptionKey: @"E_PROVIDER_CONFIGURATION"}];
    return nil;
  }
  @synchronized(self) {
    NSMutableDictionary *all = [[self.defaults dictionaryForKey:SettingsKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    all[normalized[@"harness_id"]] = normalized;
    [self.defaults setObject:all forKey:SettingsKey];
    return normalized;
  }
}
- (NSDictionary *)resetHarness:(NSString *)harness {
  @synchronized(self) {
    NSMutableDictionary *all = [[self.defaults dictionaryForKey:SettingsKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    [all removeObjectForKey:harness];
    [self.defaults setObject:all forKey:SettingsKey];
    return [self configurationForHarness:harness];
  }
}
@end

NSDictionary *DSHProviderBindingFromConfiguration(NSDictionary *configuration, NSString *model) {
  if ([configuration[@"official"] isEqual:@YES]) return nil;
  NSDictionary *profile = DSHNormalizeProviderConfiguration(configuration);
  if (profile == nil || ![DSHHarnessIdForModel(model) isEqual:profile[@"harness_id"]]) return nil;
  NSDictionary *identity = @{@"schema_version": @1, @"harness_id": profile[@"harness_id"],
      @"endpoint_url": profile[@"endpoint_url"], @"protocol": profile[@"protocol"],
      @"auth_type": profile[@"auth_type"], @"send_reasoning": profile[@"send_reasoning"], @"model_id": profile[@"model_mappings"][model] ?: model};
  NSMutableDictionary *binding = [identity mutableCopy];
  binding[@"profile_id"] = Digest(identity);
  return binding;
}
NSDictionary *DSHProviderBindingForModel(NSString *model) {
  NSString *harness = DSHHarnessIdForModel(model);
  if (!Supported(harness)) return nil;
  if ([harness isEqual:@"codex"] && DSHCodexChatUsesSubscription()) {
    NSDictionary *identity = @{@"schema_version":@1, @"harness_id":@"codex",
      @"endpoint_url":@"https://chatgpt.com/backend-api/codex/responses", @"protocol":@"responses",
      @"auth_type":@"bearer", @"send_reasoning":@YES, @"model_id":model};
    NSMutableDictionary *binding = [identity mutableCopy];
    binding[@"profile_id"] = Digest(identity);
    return binding;
  }
  return DSHProviderBindingFromConfiguration([[DSHProviderConfigurationStore sharedStore] configurationForHarness:harness], model);
}
BOOL DSHValidateProviderBinding(id raw, NSString *model) {
  if (!Keys(raw, @[@"schema_version", @"harness_id", @"endpoint_url", @"protocol", @"auth_type", @"send_reasoning", @"model_id", @"profile_id"]) ||
      ![raw[@"schema_version"] isEqual:@1] || !Supported(raw[@"harness_id"]) ||
      ![DSHHarnessIdForModel(model) isEqual:raw[@"harness_id"]] || !Text(raw[@"model_id"], 128) ||
      [raw[@"model_id"] rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound ||
      ![raw[@"send_reasoning"] isKindOfClass:NSNumber.class] ||
      CFGetTypeID((__bridge CFTypeRef)raw[@"send_reasoning"]) != CFBooleanGetTypeID() ||
      ![@[@"bearer", @"x-api-key", @"api-key"] containsObject:raw[@"auth_type"]] ||
      ![NormalizeEndpoint(raw[@"endpoint_url"], raw[@"protocol"], YES) isEqual:raw[@"endpoint_url"]]) return NO;
  NSMutableDictionary *identity = [raw mutableCopy];
  [identity removeObjectForKey:@"profile_id"];
  return [Digest(identity) isEqual:raw[@"profile_id"]];
}
BOOL DSHProviderBindingIsCurrent(id value, NSString *model) {
  NSString *harness = DSHHarnessIdForModel(model);
  if (Supported(harness) && !([harness isEqual:@"codex"] && DSHCodexChatUsesSubscription()) && [[DSHProviderConfigurationStore sharedStore] configurationForHarness:harness] == nil) return NO;
  NSDictionary *current = DSHProviderBindingForModel(model);
  return (value == nil && current == nil) || [current isEqual:value];
}
NSString *DSHConfigurableHarnessForSlot(NSString *slot) {
  return @{@"ANTHROPIC_API_KEY": @"claude-code", @"OPENAI_API_KEY": @"codex",
           @"DEEPSEEK_API_KEY": @"dsh", @"BIGMODEL_API_KEY": @"glm"}[slot];
}
BOOL DSHHarnessUsesCustomProvider(NSString *harness) {
  NSDictionary *profile = Supported(harness) ? [[DSHProviderConfigurationStore sharedStore] configurationForHarness:harness] : nil;
  return profile != nil && ![profile[@"official"] isEqual:@YES];
}
NSString *DSHEffectiveCredentialAccount(NSString *slot) {
  NSString *harness = DSHConfigurableHarnessForSlot(slot);
  if (harness == nil) return slot;
  NSDictionary *profile = [[DSHProviderConfigurationStore sharedStore] configurationForHarness:harness];
  if (profile == nil) return nil;
  if ([profile[@"official"] isEqual:@YES]) return slot;
  NSString *identity = Digest(@{@"harness_id": harness, @"endpoint_url": profile[@"endpoint_url"],
                               @"auth_type": profile[@"auth_type"], @"protocol": profile[@"protocol"]});
  return [NSString stringWithFormat:@"CUSTOM_PROVIDER_%@_%@", harness, identity];
}

NSDictionary *DSHProviderRecordWithoutConfiguration(NSDictionary *record, NSString *model) {
  id binding = [record isKindOfClass:NSDictionary.class] ? record[@"provider_configuration"] : nil;
  if (binding == nil) return record;
  if (!DSHValidateProviderBinding(binding, model)) return nil;
  NSMutableDictionary *plain = [record mutableCopy];
  [plain removeObjectForKey:@"provider_configuration"];
  return [plain copy];
}
