#import "ProviderConfiguration.h"
#import "RishHarnessCatalog.h"
#import "HarnessAuthService.h"
#include "rish_agent_core.h"

static NSString *const SettingsKey = @"RishCustomProviderConfigurationsV1";
static NSString *const RegistryKey = @"RishIndependentProvidersV1";

// Rust owns field validation, routing rules and stable profile/credential
// identities. Foundation owns URL decoding/encoding and preference storage.
static id PolicyWithError(NSString *op, NSDictionary *fields, NSError **error) {
  NSMutableDictionary *request = [fields mutableCopy];
  request[@"op"] = op;
  if (![NSJSONSerialization isValidJSONObject:request]) return nil;
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
  if (!bytes) return nil;
  char *raw = rish_agent_provider_policy_reduce((const char *)bytes.bytes, bytes.length);
  if (!raw) return nil;
  size_t length = strnlen(raw, 1024 * 1024 + 1);
  NSData *result = length <= 1024 * 1024 ? [NSData dataWithBytes:raw length:length] : nil;
  rish_agent_string_free(raw);
  id reply = result ? [NSJSONSerialization JSONObjectWithData:result options:0 error:nil] : nil;
  if (![reply isKindOfClass:NSDictionary.class] || ![reply[@"ok"] isEqual:@YES]) {
    NSString *code = [reply[@"error"] isKindOfClass:NSString.class] ? reply[@"error"] : @"E_CUSTOM_PROVIDER_REGISTRY_INVALID";
    if (error) *error = [NSError errorWithDomain:@"RishProviderConfiguration" code:1 userInfo:@{NSLocalizedDescriptionKey:code}];
    return nil;
  }
  return reply[@"value"] == NSNull.null ? nil : reply[@"value"];
}
static id Policy(NSString *op, NSDictionary *fields) { return PolicyWithError(op, fields, nil); }
BOOL DSHIsCustomProviderHarness(id value) {
  return [value isKindOfClass:NSString.class] && [value hasPrefix:@"custom-"] &&
    [Policy(@"slot_for_harness", @{@"harness_id":value}) isKindOfClass:NSString.class];
}
BOOL DSHProviderRequiresCredential(NSDictionary *configuration) {
  return [Policy(@"credential_required", @{@"configuration":configuration ?: NSNull.null}) boolValue];
}
static BOOL Supported(id value) {
  return [value isKindOfClass:NSString.class] && ([Policy(@"harnesses", @{}) containsObject:value] || DSHIsCustomProviderHarness(value));
}
static NSString *NormalizeEndpoint(id value, id protocol, id fullURL) {
  if (![value isKindOfClass:NSString.class]) return nil;
  NSString *trimmed = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  NSURLComponents *url = [NSURLComponents componentsWithString:trimmed];
  if (!url) return nil;
  NSDictionary *parts = @{@"scheme":url.scheme ?: NSNull.null, @"host":url.host ?: NSNull.null,
    @"port":url.port ?: NSNull.null, @"has_user":@(url.user != nil),
    @"has_password":@(url.password != nil), @"has_query":@(url.query != nil),
    @"has_fragment":@(url.fragment != nil), @"path":url.path ?: @""};
  NSDictionary *plan = Policy(@"endpoint_plan", @{@"codec":@"foundation", @"raw":value, @"protocol":protocol ?: NSNull.null,
    @"full_url":fullURL ?: @NO, @"parts":parts});
  if (![plan isKindOfClass:NSDictionary.class]) return nil;
  url.scheme = plan[@"scheme"];
  url.host = plan[@"host"];
  // A full URL must retain its existing percent-encoded path byte-for-byte.
  // Base URLs keep Foundation's historical decoded-path serialization.
  if (![fullURL boolValue]) url.path = plan[@"path"];
  return url.URL.absoluteString;
}
NSString *DSHNormalizeProviderEndpoint(NSString *value, NSString *protocol) {
  return NormalizeEndpoint(value, protocol, @NO);
}
NSDictionary *DSHNormalizeProviderConfiguration(id raw) {
  if (![raw isKindOfClass:NSDictionary.class]) return nil;
  NSString *endpoint = NormalizeEndpoint(raw[@"endpoint_url"], raw[@"protocol"], raw[@"full_url"]);
  if (!endpoint) return nil;
  NSMutableDictionary *candidate = [raw mutableCopy];
  candidate[@"endpoint_url"] = endpoint;
  NSMutableDictionary *harnesses = [NSMutableDictionary dictionary];
  id mappings = raw[@"model_mappings"];
  if ([mappings isKindOfClass:NSDictionary.class]) {
    for (id model in mappings) {
      NSString *harness = DSHIsCustomProviderHarness(raw[@"harness_id"]) ? raw[@"harness_id"] : DSHHarnessIdForModel(model);
      if (harness) harnesses[model] = harness;
    }
  }
  id result = Policy(@"validate_configuration", @{@"configuration":candidate, @"harness_by_model":harnesses});
  return [result isKindOfClass:NSDictionary.class] ? result : nil;
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
  if (DSHIsCustomProviderHarness(harness)) {
    NSDictionary *provider = [self customProviderForId:[harness substringFromIndex:7]];
    return [provider[@"active"] boolValue] ? provider[@"configuration"] : nil;
  }
  @synchronized(self) {
    id all = [self.defaults objectForKey:SettingsKey];
    if (all != nil && ![all isKindOfClass:NSDictionary.class]) return nil;
    id saved = all[harness];
    if (saved == nil) return Policy(@"defaults", @{@"harness_id":harness});
    NSDictionary *normalized = DSHNormalizeProviderConfiguration(saved);
    return [normalized[@"harness_id"] isEqual:harness] ? normalized : nil;
  }
}
- (NSDictionary *)saveConfiguration:(NSDictionary *)configuration error:(NSError **)error {
  NSDictionary *normalized = DSHIsCustomProviderHarness(configuration[@"harness_id"]) ? nil : DSHNormalizeProviderConfiguration(configuration);
  if (normalized == nil) {
    if (error != nil) *error = [NSError errorWithDomain:@"RishProviderConfiguration" code:1
        userInfo:@{NSLocalizedDescriptionKey: @"E_PROVIDER_CONFIGURATION"}];
    return nil;
  }
  @synchronized(self) {
    id existing = [self.defaults objectForKey:SettingsKey];
    if (existing != nil && ![existing isKindOfClass:NSDictionary.class]) {
      if (error != nil) *error = [NSError errorWithDomain:@"RishProviderConfiguration" code:1
          userInfo:@{NSLocalizedDescriptionKey: @"E_PROVIDER_CONFIGURATION"}];
      return nil;
    }
    NSMutableDictionary *all = [existing mutableCopy] ?: [NSMutableDictionary dictionary];
    all[normalized[@"harness_id"]] = normalized;
    [self.defaults setObject:all forKey:SettingsKey];
    return normalized;
  }
}
- (NSDictionary *)customRegistry:(NSError **)error {
  @synchronized(self) {
    NSDictionary *registry = PolicyWithError(@"registry_read", @{@"registry":[self.defaults objectForKey:RegistryKey] ?: NSNull.null}, error);
    if (!registry) return nil;
    // Rust validates schema and identity. The host validates its own codec's
    // canonical endpoint bytes on read, without repairing malformed storage.
    for (NSDictionary *provider in registry[@"providers"]) {
      NSDictionary *profile = provider[@"configuration"];
      NSString *endpoint = NormalizeEndpoint(profile[@"endpoint_url"], profile[@"protocol"], @YES);
      if (![endpoint isEqual:profile[@"endpoint_url"]] || ![profile[@"full_url"] isEqual:@YES]) {
        if (error) *error = [NSError errorWithDomain:@"RishProviderConfiguration" code:1 userInfo:@{NSLocalizedDescriptionKey:@"E_CUSTOM_PROVIDER_REGISTRY_INVALID"}];
        return nil;
      }
    }
    return registry;
  }
}
- (NSDictionary *)customProviderForId:(NSString *)providerId {
  if (![providerId isKindOfClass:NSString.class]) return nil;
  for (NSDictionary *provider in [self customRegistry:nil][@"providers"])
    if ([provider[@"id"] isEqual:providerId]) return provider;
  return nil;
}
- (NSArray<NSDictionary *> *)customModelsIncludingRetired:(BOOL)includeRetired {
  @synchronized(self) {
    NSDictionary *registry = [self customRegistry:nil];
    return registry ? Policy(@"registry_models", @{@"registry":registry, @"include_retired":@(includeRetired)}) ?: @[] : @[];
  }
}
- (NSDictionary *)customRouteForModel:(NSString *)model requireActive:(BOOL)requireActive {
  @synchronized(self) {
    NSDictionary *registry = [self customRegistry:nil];
    return registry ? Policy(@"registry_route", @{@"registry":registry,
      @"model_id":model ?: NSNull.null, @"require_active":@(requireActive)}) : nil;
  }
}
- (NSDictionary *)saveCustomProvider:(NSDictionary *)provider expectedRevision:(NSNumber *)revision error:(NSError **)error {
  NSDictionary *raw = [provider isKindOfClass:NSDictionary.class] ? provider[@"configuration"] : nil;
  NSDictionary *configuration = DSHNormalizeProviderConfiguration(raw);
  if (!configuration || !DSHIsCustomProviderHarness(configuration[@"harness_id"])) {
    if (error) *error = [NSError errorWithDomain:@"RishProviderConfiguration" code:1 userInfo:@{NSLocalizedDescriptionKey:@"E_CUSTOM_PROVIDER_REGISTRY_INVALID"}];
    return nil;
  }
  NSMutableDictionary *canonical = [configuration mutableCopy]; canonical[@"full_url"] = @YES;
  NSMutableDictionary *candidate = [provider mutableCopy]; candidate[@"configuration"] = canonical;
  @synchronized(self) {
    NSDictionary *registry = [self customRegistry:error];
    if (!registry) return nil;
    NSDictionary *value = PolicyWithError(@"registry_save", @{@"registry":registry,
      @"expected_revision":revision ?: NSNull.null, @"provider":candidate}, error);
    if (value) [self.defaults setObject:value forKey:RegistryKey];
    return value;
  }
}
- (NSDictionary *)removeCustomProvider:(NSString *)providerId expectedRevision:(NSNumber *)revision error:(NSError **)error {
  @synchronized(self) {
    NSDictionary *registry = [self customRegistry:error];
    if (!registry) return nil;
    NSDictionary *value = PolicyWithError(@"registry_remove", @{@"registry":registry,
      @"expected_revision":revision ?: NSNull.null, @"provider_id":providerId ?: NSNull.null}, error);
    if (value) [self.defaults setObject:value forKey:RegistryKey];
    return value;
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
  NSDictionary *profile = DSHNormalizeProviderConfiguration(configuration);
  if (!profile) return nil;
  id result = Policy(@"binding", @{@"configuration":profile ?: NSNull.null,
    @"logical_model":model ?: NSNull.null, @"model_harness":(DSHIsCustomProviderHarness(profile[@"harness_id"]) ? profile[@"harness_id"] : DSHHarnessIdForModel(model)) ?: NSNull.null});
  return [result isKindOfClass:NSDictionary.class] ? result : nil;
}
NSDictionary *DSHProviderBindingForModel(NSString *model) {
  NSString *harness = DSHHarnessIdForModel(model);
  if (!Supported(harness)) return nil;
  if ([harness isEqual:@"codex"] && DSHCodexChatUsesSubscription()) {
    NSDictionary *identity = @{@"schema_version":@1, @"harness_id":@"codex",
      @"endpoint_url":@"https://chatgpt.com/backend-api/codex/responses", @"protocol":@"responses",
      @"auth_type":@"bearer", @"send_reasoning":@YES, @"model_id":model};
    NSString *digest = Policy(@"profile_digest", @{@"identity":identity});
    if (!digest) return nil;
    NSMutableDictionary *binding = [identity mutableCopy];
    binding[@"profile_id"] = digest;
    return binding;
  }
  return DSHProviderBindingFromConfiguration([[DSHProviderConfigurationStore sharedStore] configurationForHarness:harness], model);
}
BOOL DSHValidateProviderBinding(id raw, NSString *model) {
  if (![raw isKindOfClass:NSDictionary.class]) return NO;
  NSString *endpoint = NormalizeEndpoint(raw[@"endpoint_url"], raw[@"protocol"], @YES);
  return [Policy(@"validate_binding", @{@"binding":raw, @"logical_model":model ?: NSNull.null,
    @"model_harness":(DSHIsCustomProviderHarness(raw[@"harness_id"]) ? raw[@"harness_id"] : DSHHarnessIdForModel(model)) ?: NSNull.null,
    @"endpoint_is_canonical":@([endpoint isEqual:raw[@"endpoint_url"]])}) boolValue];
}
BOOL DSHProviderBindingIsCurrent(id value, NSString *model) {
  NSString *harness = DSHHarnessIdForModel(model);
  if (!Supported(harness)) return NO;
  if (DSHIsCustomProviderHarness(harness) && ![DSHProviderConfigurationStore.sharedStore customRouteForModel:model requireActive:YES]) return NO;
  if (!([harness isEqual:@"codex"] && DSHCodexChatUsesSubscription()) && [[DSHProviderConfigurationStore sharedStore] configurationForHarness:harness] == nil) return NO;
  NSDictionary *current = DSHProviderBindingForModel(model);
  return (value == nil && current == nil) || [current isEqual:value];
}
NSString *DSHConfigurableHarnessForSlot(NSString *slot) {
  return Policy(@"harness_for_slot", @{@"slot":slot ?: NSNull.null});
}
BOOL DSHHarnessUsesCustomProvider(NSString *harness) {
  NSDictionary *profile = Supported(harness) ? [[DSHProviderConfigurationStore sharedStore] configurationForHarness:harness] : nil;
  return profile != nil && ![profile[@"official"] isEqual:@YES];
}
NSString *DSHEffectiveCredentialAccount(NSString *slot) {
  NSString *harness = DSHConfigurableHarnessForSlot(slot);
  NSDictionary *profile = harness ? [[DSHProviderConfigurationStore sharedStore] configurationForHarness:harness] : nil;
  return Policy(@"credential_account", @{@"slot":slot ?: NSNull.null, @"configuration":profile ?: NSNull.null});
}

NSDictionary *DSHProviderRecordWithoutConfiguration(NSDictionary *record, NSString *model) {
  id binding = [record isKindOfClass:NSDictionary.class] ? record[@"provider_configuration"] : nil;
  if (binding == nil) return record;
  if (!DSHValidateProviderBinding(binding, model)) return nil;
  NSMutableDictionary *plain = [record mutableCopy];
  [plain removeObjectForKey:@"provider_configuration"];
  return [plain copy];
}
