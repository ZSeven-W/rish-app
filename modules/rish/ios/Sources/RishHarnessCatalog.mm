#import "RishHarnessCatalog.h"
#import "ProviderConfiguration.h"
#import "HarnessAuthService.h"
#include "rish_agent_core.h"

static NSString *const DSHCatalogHarnessDsh = @"dsh";
static NSString *const DSHCatalogHarnessClaudeCode = @"claude-code";
static NSString *const DSHCatalogHarnessCodex = @"codex";
static NSString *const DSHCodexDiscoveredModelsKey = @"rish.codex.discovered-models.v1";
static NSString *const DSHProviderModelsKey = @"RishProviderModelsV1";
static BOOL DSHCodexDiscoveryID(id value) {
  if (![value isKindOfClass:NSString.class] || [value length] > 80) return NO;
  NSRange match = [value rangeOfString:@"^(?:(?:gpt|codex)-[A-Za-z0-9][A-Za-z0-9._-]*|o[0-9][A-Za-z0-9._-]*)$" options:NSRegularExpressionSearch];
  return match.location == 0 && match.length == [value length];
}
static NSSet<NSString *> *DSHCodexDiscoveredModels(void) {
  NSArray *values = [NSUserDefaults.standardUserDefaults arrayForKey:DSHCodexDiscoveredModelsKey];
  NSMutableSet *result = [NSMutableSet set];
  for (id value in values) if (DSHCodexDiscoveryID(value) && result.count < 256) [result addObject:value];
  return result;
}
BOOL DSHRegisterCodexSubscriptionModels(NSArray<NSString *> *models) {
  if (![models isKindOfClass:NSArray.class] || models.count > 64) return NO;
  @synchronized (NSUserDefaults.standardUserDefaults) {
    NSMutableSet *all = [DSHCodexDiscoveredModels() mutableCopy];
    for (id model in models) { if (!DSHCodexDiscoveryID(model)) return NO; [all addObject:model]; }
    if (all.count > 256) return NO;
    [NSUserDefaults.standardUserDefaults setObject:[all.allObjects sortedArrayUsingSelector:@selector(compare:)] forKey:DSHCodexDiscoveredModelsKey];
    return YES;
  }
}
/// Zhipu GLM served over its Anthropic-compatible Messages endpoint. A
/// distinct catalog entry rather than a base-URL override on claude-code:
/// provider_host is recorded in consent manifests, runtime proof and session
/// snapshots and compared by equality, so the host that actually served a
/// round has to be a fixed catalog fact, not mutable state.
static NSString *const DSHCatalogHarnessGlm = @"glm";

// Custom model rules and built-in model identities are defined once in Rust.
// This adapter owns NSUserDefaults and subscription-discovered registrations.
static id DSHCatalogCore(NSString *op, NSDictionary *fields, BOOL provider) {
  NSMutableDictionary *request = [fields mutableCopy];
  request[@"op"] = op;
  if (![NSJSONSerialization isValidJSONObject:request]) return nil;
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
  if (!bytes) return nil;
  char *raw = provider ? rish_agent_provider_policy_reduce((const char *)bytes.bytes, bytes.length) :
    rish_agent_model_catalog_reduce((const char *)bytes.bytes, bytes.length);
  if (!raw) return nil;
  size_t length = strnlen(raw, 1024 * 1024 + 1);
  NSData *result = length <= 1024 * 1024 ? [NSData dataWithBytes:raw length:length] : nil;
  rish_agent_string_free(raw);
  id reply = result ? [NSJSONSerialization JSONObjectWithData:result options:0 error:nil] : nil;
  if (![reply isKindOfClass:NSDictionary.class] || ![reply[@"ok"] isEqual:@YES]) return nil;
  return reply[@"value"] == NSNull.null ? nil : reply[@"value"];
}
static id DSHCatalogReduce(NSString *op, NSDictionary *fields) {
  return DSHCatalogCore(op, fields, NO);
}
static id DSHStoredDshCatalog(void) {
  // Only missing storage is null. A malformed saved value must not silently
  // become a new default catalog or be rewritten during a read.
  return [NSUserDefaults.standardUserDefaults objectForKey:@"rish.dsh-models.v1"] ?: NSNull.null;
}

static id DSHProviderCatalogReduce(NSString *operation, NSDictionary *fields, NSError **error) {
  NSMutableDictionary *request = [@{@"op":operation,
    @"registry":[NSUserDefaults.standardUserDefaults objectForKey:DSHProviderModelsKey] ?: NSNull.null,
    @"legacy_dsh_catalog":DSHStoredDshCatalog(),
    @"discovered_models":DSHCodexDiscoveredModels().allObjects} mutableCopy];
  [request addEntriesFromDictionary:fields];
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
  char *raw = bytes ? rish_agent_model_catalog_reduce((const char *)bytes.bytes, bytes.length) : NULL;
  if (!raw) return nil;
  size_t size = strnlen(raw, 1024 * 1024 + 1);
  NSData *data = size <= 1024 * 1024 ? [NSData dataWithBytes:raw length:size] : nil;
  rish_agent_string_free(raw);
  NSDictionary *reply = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  if (![reply isKindOfClass:NSDictionary.class] || ![reply[@"ok"] isEqual:@YES]) {
    NSString *code = [reply[@"error"] isKindOfClass:NSString.class] ? reply[@"error"] : @"E_MODEL_CATALOG_INVALID";
    if (error) *error = [NSError errorWithDomain:@"RishProviderModelCatalog" code:1 userInfo:@{NSLocalizedDescriptionKey:code}];
    return nil;
  }
  return reply[@"value"] == NSNull.null ? nil : reply[@"value"];
}
NSDictionary *DSHProviderModelCatalog(void) {
  @synchronized(NSUserDefaults.standardUserDefaults) { return DSHProviderCatalogReduce(@"provider_read", @{}, nil); }
}
NSArray<NSDictionary *> *DSHProviderModelRows(BOOL includeRetired) {
  @synchronized(NSUserDefaults.standardUserDefaults) {
    return DSHProviderCatalogReduce(@"provider_models", @{@"include_retired":@(includeRetired)}, nil);
  }
}
NSDictionary *DSHSaveProviderModelCatalog(NSDictionary *request, NSError **error) {
  @synchronized(NSUserDefaults.standardUserDefaults) {
    NSDictionary *saved = DSHProviderCatalogReduce(@"provider_save", @{@"request":request ?: NSNull.null}, error);
    if (saved) [NSUserDefaults.standardUserDefaults setObject:saved forKey:DSHProviderModelsKey];
    return saved;
  }
}
BOOL DSHProviderModelIsActive(NSString *model) {
  for (NSDictionary *row in DSHProviderModelRows(NO)) if ([row[@"id"] isEqual:model]) return YES;
  return NO;
}
BOOL DSHHarnessModelIsExecutable(id model) {
  if (![model isKindOfClass:NSString.class]) return NO;
  if ([DSHCatalogCore(@"is_custom_model", @{@"model_id":model}, YES) boolValue])
    return [DSHProviderConfigurationStore.sharedStore customRouteForModel:model requireActive:YES] != nil;
  NSString *harness = DSHHarnessIdForModel(model);
  if ([harness isEqual:@"codex"] && DSHCodexChatUsesSubscription())
    return [DSHCodexDiscoveredModels() containsObject:model];
  return harness && DSHProviderModelIsActive(model);
}

static NSDictionary<NSString *, NSString *> *DSHCatalogProviderByHarness(void) {
  static NSDictionary<NSString *, NSString *> *table = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    table = @{
      DSHCatalogHarnessDsh : @"deepseek",
      DSHCatalogHarnessClaudeCode : @"anthropic",
      DSHCatalogHarnessCodex : @"openai",
      DSHCatalogHarnessGlm : @"bigmodel",
    };
  });
  return table;
}

static NSDictionary<NSString *, NSString *> *DSHCatalogHostByProvider(void) {
  static NSDictionary<NSString *, NSString *> *table = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    table = @{
      @"deepseek" : @"api.deepseek.com",
      @"anthropic" : @"api.anthropic.com",
      @"openai" : @"api.openai.com",
      @"bigmodel" : @"open.bigmodel.cn",
    };
  });
  return table;
}

static NSDictionary<NSString *, NSString *> *DSHCatalogAccountByHarness(void) {
  static NSDictionary<NSString *, NSString *> *table;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    NSMutableDictionary *accounts = [NSMutableDictionary dictionary];
    for (NSString *harness in DSHCatalogCore(@"harnesses", @{}, YES)) {
      NSString *slot = DSHCatalogCore(@"slot_for_harness", @{@"harness_id":harness}, YES);
      if (slot) accounts[harness] = slot;
    }
    table = [accounts copy];
  });
  return table;
}

static NSString *_Nullable DSHCatalogString(id _Nullable value) {
  return [value isKindOfClass:NSString.class] ? value : nil;
}

// Retired identities remain recognizable when validating saved receipts and
// session history. This catalog never authorizes a new request; dispatch uses
// the registry's requireActive route and its captured configuration binding.
static NSArray<NSDictionary *> *DSHCatalogCustomModels(void) {
  return [DSHProviderConfigurationStore.sharedStore customModelsIncludingRetired:YES] ?: @[];
}

static NSArray<NSDictionary *> *DSHCatalogCustomProviders(void) {
  // Providers exist before model discovery or selection. Their credential and
  // endpoint identities must not depend on having an executable model row.
  return [DSHProviderConfigurationStore.sharedStore customRegistry:nil][@"providers"] ?: @[];
}

static NSDictionary *_Nullable DSHCatalogCustomRowForHarness(NSString *harness) {
  if (![harness hasPrefix:@"custom-"]) return nil;
  for (NSDictionary *provider in DSHCatalogCustomProviders()) {
    NSDictionary *configuration = provider[@"configuration"];
    if ([configuration[@"harness_id"] isEqual:harness])
      return @{@"harness_id":harness, @"provider_id":harness, @"configuration":configuration};
  }
  return nil;
}

static NSString *_Nullable DSHCatalogCustomHost(NSDictionary *row) {
  NSString *endpoint = DSHCatalogString(row[@"configuration"][@"endpoint_url"]);
  return endpoint ? [NSURLComponents componentsWithString:endpoint].host : nil;
}

NSSet<NSString *> *DSHHarnessSupportedModels(void) {
  NSArray *models = DSHCatalogReduce(@"supported_models", @{@"catalog":DSHStoredDshCatalog(),
    @"discovered_models":DSHCodexDiscoveredModels().allObjects});
  NSMutableSet *result = [NSMutableSet setWithArray:models ?: @[]];
  for (NSDictionary *row in DSHProviderModelRows(YES)) {
    NSString *model = DSHCatalogString(row[@"id"]);
    if (model) [result addObject:model];
  }
  for (NSDictionary *row in DSHCatalogCustomModels()) {
    NSString *model = DSHCatalogString(row[@"id"]);
    if (model) [result addObject:model];
  }
  return result;
}

BOOL DSHHarnessIsSupportedModel(id value) {
  return DSHHarnessIdForModel(value) != nil;
}

NSSet<NSString *> *DSHHarnessSupportedHarnessIds(void) {
  NSMutableSet *ids = [NSMutableSet setWithArray:DSHCatalogProviderByHarness().allKeys];
  for (NSDictionary *provider in DSHCatalogCustomProviders()) {
    NSString *harness = DSHCatalogString(provider[@"configuration"][@"harness_id"]);
    if (harness) [ids addObject:harness];
  }
  return ids;
}

BOOL DSHHarnessIsSupportedHarnessId(id value) {
  NSString *harness = DSHCatalogString(value);
  return harness != nil && (DSHCatalogProviderByHarness()[harness] != nil ||
                           DSHCatalogCustomRowForHarness(harness) != nil);
}

NSString *DSHHarnessIdForModel(id model) {
  NSString *key = DSHCatalogString(model);
  if ([DSHCatalogCore(@"is_custom_model", @{@"model_id":key ?: NSNull.null}, YES) boolValue]) {
    NSDictionary *row = [DSHProviderConfigurationStore.sharedStore customRouteForModel:key requireActive:NO];
    return DSHCatalogString(row[@"harness_id"]);
  }
  NSString *registered = DSHProviderCatalogReduce(@"provider_harness", @{@"model":model ?: NSNull.null}, nil);
  if (registered) return registered;
  return DSHCatalogReduce(@"harness_for_model", @{@"catalog":DSHStoredDshCatalog(),
    @"model":model ?: NSNull.null, @"discovered_models":DSHCodexDiscoveredModels().allObjects});
}

NSSet<NSString *> *DSHHarnessSupportedProviderIds(void) {
  NSMutableSet *ids = [NSMutableSet setWithArray:DSHCatalogHostByProvider().allKeys];
  for (NSDictionary *provider in DSHCatalogCustomProviders()) {
    NSString *identifier = DSHCatalogString(provider[@"configuration"][@"harness_id"]);
    if (identifier) [ids addObject:identifier];
  }
  return ids;
}

BOOL DSHHarnessIsProviderId(id value) {
  NSString *provider = DSHCatalogString(value);
  return provider != nil && [DSHHarnessSupportedProviderIds() containsObject:provider];
}

NSString *DSHProviderIdForHarnessId(id harnessId) {
  NSString *key = DSHCatalogString(harnessId);
  if (key == nil) return nil;
  return DSHCatalogProviderByHarness()[key] ?: DSHCatalogString(DSHCatalogCustomRowForHarness(key)[@"provider_id"]);
}

NSString *DSHProviderIdForModel(id model) {
  return DSHProviderIdForHarnessId(DSHHarnessIdForModel(model));
}

NSSet<NSString *> *DSHHarnessSupportedProviderHosts(void) {
  NSMutableSet *hosts = [NSMutableSet setWithArray:DSHCatalogHostByProvider().allValues];
  for (NSDictionary *provider in DSHCatalogCustomProviders()) {
    NSString *host = DSHCatalogCustomHost(provider);
    if (host) [hosts addObject:host];
  }
  return hosts;
}

BOOL DSHHarnessIsProviderHost(id value) {
  NSString *host = DSHCatalogString(value);
  return host != nil && [DSHHarnessSupportedProviderHosts() containsObject:host];
}

NSString *DSHProviderHostForProviderId(id providerId) {
  NSString *key = DSHCatalogString(providerId);
  if (key == nil) return nil;
  return DSHCatalogHostByProvider()[key] ?: DSHCatalogCustomHost(DSHCatalogCustomRowForHarness(key));
}

NSString *DSHProviderHostForModel(id model) {
  return DSHProviderHostForProviderId(DSHProviderIdForModel(model));
}

NSSet<NSString *> *DSHHarnessCredentialAccounts(void) {
  NSMutableSet *accounts = [NSMutableSet setWithArray:DSHCatalogAccountByHarness().allValues];
  for (NSDictionary *provider in DSHCatalogCustomProviders()) {
    NSString *harness = DSHCatalogString(provider[@"configuration"][@"harness_id"]);
    NSString *slot = harness ? DSHCatalogCore(@"slot_for_harness", @{@"harness_id":harness}, YES) : nil;
    if (slot) [accounts addObject:slot];
  }
  return accounts;
}

BOOL DSHHarnessIsCredentialAccount(id value) {
  NSString *account = DSHCatalogString(value);
  return account != nil && [DSHHarnessCredentialAccounts() containsObject:account];
}

NSString *DSHCredentialAccountForHarnessId(id harnessId) {
  NSString *key = DSHCatalogString(harnessId);
  if (key == nil) return nil;
  NSString *builtIn = DSHCatalogAccountByHarness()[key];
  if (builtIn) return builtIn;
  return DSHCatalogCustomRowForHarness(key) ?
      DSHCatalogCore(@"slot_for_harness", @{@"harness_id":key}, YES) : nil;
}

NSDictionary *DSHDshModelCatalog(void) {
  NSDictionary *registry = DSHProviderModelCatalog();
  if (!registry) return nil;
  for (NSDictionary *provider in registry[@"providers"]) {
    if ([provider[@"harness_id"] isEqual:@"dsh"])
      return @{@"schema_version":@1, @"models":provider[@"models"], @"retired_models":provider[@"retired_models"]};
  }
  return nil;
}
NSDictionary *DSHDshModelEntry(NSString *model) {
  for (NSDictionary *row in DSHProviderModelRows(YES)) {
    if ([row[@"harness_id"] isEqual:@"dsh"] && [row[@"id"] isEqual:model])
      return @{@"id":row[@"id"], @"name":row[@"name"], @"supports_images":row[@"supports_images"]};
  }
  return DSHCatalogReduce(@"lookup", @{@"catalog":DSHStoredDshCatalog(), @"model":model ?: NSNull.null});
}
BOOL DSHDshModelSupportsImages(NSString *model) {
  if ([DSHCatalogCore(@"is_custom_model", @{@"model_id":model ?: NSNull.null}, YES) boolValue])
    return [[DSHProviderConfigurationStore.sharedStore customRouteForModel:model requireActive:YES][@"supports_images"] boolValue];
  for (NSDictionary *row in DSHProviderModelRows(YES)) {
    if ([row[@"id"] isEqual:model]) return [row[@"supports_images"] boolValue];
  }
  return [DSHCatalogReduce(@"supports_images", @{@"catalog":DSHStoredDshCatalog(),
    @"model":model ?: NSNull.null}) boolValue];
}
NSDictionary *DSHSaveDshModelCatalog(NSDictionary *request) {
  @synchronized(NSUserDefaults.standardUserDefaults) {
    if (![request isKindOfClass:NSDictionary.class] || request.count != 2 ||
        ![request[@"schema_version"] isEqual:@1] || ![request[@"models"] isKindOfClass:NSArray.class]) return nil;
    NSDictionary *current = DSHProviderModelCatalog();
    if (!current) return nil;
    NSDictionary *saved = DSHSaveProviderModelCatalog(@{@"schema_version":@1,
      @"harness_id":@"dsh", @"expected_revision":current[@"revision"], @"models":request[@"models"]}, nil);
    if (!saved) return nil;
    return DSHDshModelCatalog();
  }
}
