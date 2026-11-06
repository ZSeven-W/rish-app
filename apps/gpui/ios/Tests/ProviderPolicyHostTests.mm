#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "ProviderConfiguration.h"
#import "RishHarnessCatalog.h"
#import "HarnessAuthService.h"
#include "rish_agent_core.h"

static NSUInteger checks;
static NSUserDefaults *testDefaults;
static BOOL usesSubscription;
BOOL DSHCodexChatUsesSubscription(void) { return usesSubscription; }
static id IsolatedDefaults(id receiver, SEL selector) { return testDefaults; }
static void Check(BOOL value, NSString *message) {
  checks++;
  NSCAssert(value, @"%@", message);
}
static id Decode(NSString *path) {
  NSData *data = [NSData dataWithContentsOfFile:path];
  return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
}
static NSDictionary *Core(BOOL catalog, NSDictionary *request) {
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
  char *raw = catalog ? rish_agent_model_catalog_reduce((const char *)bytes.bytes, bytes.length) :
    rish_agent_provider_policy_reduce((const char *)bytes.bytes, bytes.length);
  Check(raw != NULL, @"Real Rust C ABI returns an owned response");
  NSData *result = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  return [NSJSONSerialization JSONObjectWithData:result options:0 error:nil];
}
static void FixedIdentityCases(NSString *path) {
  NSDictionary *fixture = Decode(path);
  Check([fixture[@"cases"] count] == 14, @"Pre-migration native identity vectors are fixed");
  DSHProviderConfigurationStore *store = [[DSHProviderConfigurationStore alloc] initWithDefaults:testDefaults];
  for (NSDictionary *item in fixture[@"cases"]) {
    NSDictionary *configuration = item[@"configuration"];
    id expected = item[@"normalized"];
    NSDictionary *normalized = DSHNormalizeProviderConfiguration(configuration);
    Check(expected == NSNull.null ? normalized == nil : [normalized isEqual:expected],
      @"Rust policy plus NSURLComponents preserves the old normalized URL and profile");
    NSDictionary *binding = DSHProviderBindingFromConfiguration(configuration, @"claude-sonnet-5");
    Check(item[@"binding"] == NSNull.null ? binding == nil : [binding isEqual:item[@"binding"]],
      @"Existing profile IDs retain their exact historical bytes");
    if (!normalized) continue;
    Check(DSHValidateProviderBinding(binding, @"claude-sonnet-5"), @"Frozen existing bindings still validate");
    Check([store saveConfiguration:configuration error:nil] != nil, @"Validated profile persists to isolated defaults");
    Check([DSHEffectiveCredentialAccount(@"ANTHROPIC_API_KEY") isEqual:item[@"credential_account"]],
      @"Existing Keychain credential account identities do not change");
    DSHProviderConfigurationStore *restarted = [[DSHProviderConfigurationStore alloc] initWithDefaults:testDefaults];
    Check([[restarted configurationForHarness:@"claude-code"] isEqual:normalized],
      @"A fresh store reads the persisted profile without migration or rewriting");
    NSMutableDictionary *tampered = [binding mutableCopy];
    tampered[@"model_id"] = @"different-model";
    Check(!DSHValidateProviderBinding(tampered, @"claude-sonnet-5"), @"Binding hashes still reject a changed wire model");
    NSMutableDictionary *record = [@{@"id":@"fixture", @"provider_configuration":binding} mutableCopy];
    Check([DSHProviderRecordWithoutConfiguration(record, @"claude-sonnet-5") isEqual:@{@"id":@"fixture"}],
      @"Valid binding removal preserves the record's other fields");
  }
  for (NSString *harness in @[@"claude-code", @"codex", @"dsh", @"glm"]) {
    NSDictionary *profile = [store resetHarness:harness];
    Check([profile[@"official"] isEqual:@YES], @"Reset reads the shared Rust official defaults");
  }
  Check([DSHConfigurableHarnessForSlot(@"ANTHROPIC_API_KEY") isEqual:@"claude-code"], @"Slot routing comes from Rust");
  Check([DSHEffectiveCredentialAccount(@"OPENAI_API_KEY") isEqual:@"OPENAI_API_KEY"], @"Official credential account is unchanged");
  Check([DSHEffectiveCredentialAccount(@"unrelated-account") isEqual:@"unrelated-account"], @"Non-provider credentials are left alone");
  usesSubscription = YES;
  NSDictionary *subscription = DSHProviderBindingForModel(@"gpt-5.6");
  Check([subscription[@"endpoint_url"] isEqual:@"https://chatgpt.com/backend-api/codex/responses"] &&
    DSHValidateProviderBinding(subscription, @"gpt-5.6"), @"Native subscription selection retains the shared binding contract");
  usesSubscription = NO;
}
static void RepeatedSuffixCases(NSString *path) {
  NSDictionary *fixture = Decode(path);
  Check([fixture[@"cases"] count] == 7, @"Pre-migration repeated suffix identities are fixed");
  NSString *key = @"RishCustomProviderConfigurationsV1";
  DSHProviderConfigurationStore *store = [[DSHProviderConfigurationStore alloc] initWithDefaults:testDefaults];
  for (NSDictionary *item in fixture[@"cases"]) {
    NSDictionary *saved = [store saveConfiguration:item[@"configuration"] error:nil];
    Check([saved isEqual:item[@"saved"]], @"Foundation suffix planning preserves the old saved endpoint");
    DSHProviderConfigurationStore *restarted = [[DSHProviderConfigurationStore alloc] initWithDefaults:testDefaults];
    NSDictionary *read = [restarted configurationForHarness:@"claude-code"];
    Check([read isEqual:item[@"read"]], @"Repeated suffix read normalization preserves the old native behavior");
    Check([DSHProviderBindingFromConfiguration(read, @"claude-sonnet-5") isEqual:item[@"binding"]],
      @"The reread profile produces its exact historical binding identity");
    Check([DSHEffectiveCredentialAccount(@"ANTHROPIC_API_KEY") isEqual:item[@"credential_account"]],
      @"Repeated suffix normalization keeps existing Keychain accounts reachable");
    Check([DSHProviderBindingForModel(@"claude-sonnet-5") isEqual:item[@"binding"]],
      @"Live provider selection uses the same persisted historical binding");
    Check([[testDefaults objectForKey:key][@"claude-code"] isEqual:saved],
      @"Read normalization never rewrites the saved endpoint");
  }
  [store resetHarness:@"claude-code"];
}
static void SharedCases(NSString *path, BOOL catalog) {
  NSDictionary *fixture = Decode(path);
  Check([fixture[@"cases"] count] > 0, @"Shared Rust policy fixtures exist");
  for (NSDictionary *item in fixture[@"cases"]) {
    Check([Core(catalog, item[@"input"]) isEqual:item[@"expected"]],
      [@"Real Rust policy fixture: " stringByAppendingString:item[@"name"]]);
  }
}
static void ProviderStorageCases(void) {
  NSString *key = @"RishCustomProviderConfigurationsV1";
  id previous = [testDefaults objectForKey:key];
  DSHProviderConfigurationStore *store = [[DSHProviderConfigurationStore alloc] initWithDefaults:testDefaults];
  NSDictionary *codex = @{@"schema_version":@1, @"harness_id":@"codex", @"name":@"Relay",
    @"endpoint_url":@"https://relay.example/v1/responses", @"protocol":@"responses",
    @"auth_type":@"bearer", @"send_reasoning":@YES, @"model_mappings":@{}};
  NSDictionary *wrongSlot = @{@"claude-code":codex};
  [testDefaults setObject:wrongSlot forKey:key];
  Check([store configurationForHarness:@"claude-code"] == nil,
    @"A saved configuration cannot impersonate the requested harness's slot");
  Check(!DSHProviderBindingIsCurrent(nil, @"claude-sonnet-5") &&
    DSHEffectiveCredentialAccount(@"ANTHROPIC_API_KEY") == nil,
    @"A mismatched saved slot cannot authorize an absent binding or credential account");
  Check([[testDefaults objectForKey:key] isEqual:wrongSlot], @"Mismatched slot reads preserve original data");
  NSArray *corrupt = @[@"invalid-root"];
  [testDefaults setObject:corrupt forKey:key];
  NSError *error = nil;
  Check([store saveConfiguration:codex error:&error] == nil && error.code == 1 &&
    [error.localizedDescription isEqual:@"E_PROVIDER_CONFIGURATION"],
    @"A normal save fails closed when its preference root is malformed");
  Check([[testDefaults objectForKey:key] isEqual:corrupt], @"Normal save never replaces a malformed preference root");
  if (previous) [testDefaults setObject:previous forKey:key];
  else [testDefaults removeObjectForKey:key];
  Check(!DSHProviderBindingIsCurrent(nil, @"unknown-model"), @"Unknown models cannot make absent bindings current");
  Check(DSHProviderBindingIsCurrent(nil, @"claude-sonnet-5"), @"Known official configuration still accepts its absent custom binding");
}
static void CatalogAdapterCases(void) {
  [testDefaults removeObjectForKey:@"rish.dsh-models.v1"];
  [testDefaults removeObjectForKey:@"RishProviderModelsV1"];
  Check([DSHDshModelCatalog()[@"models"] count] == 0, @"Missing preference has no hardcoded active models");
  Check([DSHHarnessIdForModel(@"claude-sonnet-5") isEqual:@"claude-code"], @"Built-in routing comes from Rust");
  Check([DSHHarnessSupportedModels() containsObject:@"GLM-5.3"], @"Supported models include shared built-ins");
  NSDictionary *request = @{@"schema_version":@1, @"models":@[
    @{@"id":@"custom/v1:fast", @"name":@"  自定义模型  ", @"supports_images":@YES}]};
  NSDictionary *saved = DSHSaveDshModelCatalog(request);
  Check([saved[@"models"][0][@"name"] isEqual:@"自定义模型"], @"Rust normalizes custom model labels");
  Check([saved[@"retired_models"] count] == 0, @"Historical builtin identities are not manufactured as user choices");
  Check([DSHHarnessIdForModel(@"custom/v1:fast") isEqual:@"dsh"], @"Custom model mapping uses the same Rust catalog");
  Check(DSHDshModelSupportsImages(@"custom/v1:fast"), @"Custom image capability comes from Rust");
  Check(DSHHarnessIsSupportedModel(@"custom/v1:fast"), @"Supported-model lookup includes custom IDs");
  Check([DSHHarnessSupportedModels() containsObject:@"custom/v1:fast"], @"Supported model set includes custom IDs");
  NSDictionary *profile = @{@"schema_version":@1, @"harness_id":@"dsh", @"name":@"Custom relay",
    @"endpoint_url":@"https://relay.example/v1", @"protocol":@"chat-completions",
    @"auth_type":@"bearer", @"send_reasoning":@YES,
    @"model_mappings":@{@"custom/v1:fast":@"wire-custom"}};
  NSDictionary *binding = DSHProviderBindingFromConfiguration(profile, @"custom/v1:fast");
  Check([binding[@"model_id"] isEqual:@"wire-custom"] && DSHValidateProviderBinding(binding, @"custom/v1:fast"),
    @"Provider mapping and catalog lookup share the same custom identity");
  NSDictionary *replacement = @{@"schema_version":@1, @"models":@[
    @{@"id":@"custom/v2", @"name":@"Next model", @"supports_images":@NO}]};
  NSDictionary *retired = DSHSaveDshModelCatalog(replacement);
  Check(retired != nil && DSHValidateProviderBinding(binding, @"custom/v1:fast"),
    @"Retiring a custom model preserves old conversation bindings");
  Check(DSHDshModelSupportsImages(@"custom/v1:fast"), @"Retired model capabilities remain available");
  saved = retired;
  NSDictionary *invalid = @{@"schema_version":@1, @"models":@[
    @{@"id":@"gpt-5.6", @"name":@"Wrong harness", @"supports_images":@NO}]};
  Check(DSHSaveDshModelCatalog(invalid) == nil, @"Custom catalogs cannot take another harness model identity");
  Check([DSHDshModelCatalog() isEqual:saved] && [testDefaults objectForKey:@"rish.dsh-models.v1"] == nil, @"Legacy save aliases the authoritative provider registry without dual writes");
  Check(DSHRegisterCodexSubscriptionModels(@[@"gpt-fixture-private"]), @"Discovered registration stays native");
  Check(!DSHRegisterCodexSubscriptionModels(@[@"gpt-invalid\n"]) &&
    !DSHRegisterCodexSubscriptionModels(@[@"gpt-invalid\r\n"]), @"Discovery registration rejects trailing line breaks");
  [testDefaults setObject:@[@"gpt-invalid\n", @"gpt-fixture-private"] forKey:@"rish.codex.discovered-models.v1"];
  Check([DSHHarnessIdForModel(@"claude-sonnet-5") isEqual:@"claude-code"] &&
    [DSHHarnessIdForModel(@"gpt-fixture-private") isEqual:@"codex"],
    @"An old invalid discovery record cannot poison valid model routing");
  Check([[testDefaults objectForKey:@"rish.codex.discovered-models.v1"] isEqual:@[@"gpt-invalid\n", @"gpt-fixture-private"]],
    @"Filtering invalid discovery facts does not rewrite saved data");
  Check([DSHHarnessIdForModel(@"gpt-fixture-private") isEqual:@"codex"], @"Rust receives discovered registration facts");
  [testDefaults setObject:@[@"corrupt"] forKey:@"RishProviderModelsV1"];
  Check(DSHDshModelCatalog() == nil && DSHSaveDshModelCatalog(request) == nil,
    @"Malformed storage fails closed without reinitializing the catalog");
  Check([[testDefaults objectForKey:@"RishProviderModelsV1"] isEqual:@[@"corrupt"]], @"Failed reads and saves preserve malformed storage");
  Check([DSHHarnessIdForModel(@"claude-sonnet-5") isEqual:@"claude-code"], @"Malformed custom storage cannot erase static identities");
  Check(DSHHarnessIdForModel(@"custom/v1:fast") == nil, @"Malformed provider storage cannot guess a dynamic API model's harness");
  Check(!DSHProviderBindingIsCurrent(nil, @"custom/v1:fast"),
    @"Failed dynamic routing cannot treat two missing bindings as a current provider");
  [testDefaults removeObjectForKey:@"rish.dsh-models.v1"];
  [testDefaults removeObjectForKey:@"RishProviderModelsV1"];
}
#include "CustomProviderPolicyHostTests.inc"
#include "BuiltinProviderModelsHostTests.inc"

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    Check(argc == 5, @"Native baseline and shared policy fixture paths are required");
    NSString *suite = [@"rish-provider-policy-test-" stringByAppendingString:NSUUID.UUID.UUIDString];
    testDefaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    Method standard = class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults));
    IMP original = method_setImplementation(standard, (IMP)IsolatedDefaults);
    @try {
      FixedIdentityCases([NSString stringWithUTF8String:argv[1]]);
      RepeatedSuffixCases([NSString stringWithUTF8String:argv[4]]);
      SharedCases([NSString stringWithUTF8String:argv[2]], YES);
      SharedCases([NSString stringWithUTF8String:argv[3]], NO);
      ProviderStorageCases();
      CatalogAdapterCases();
      BuiltinProviderModelCases();
      IndependentProviderCases();
    } @finally {
      [testDefaults removePersistentDomainForName:suite];
      method_setImplementation(standard, original);
    }
    printf("Provider/model native policy checks passed: %lu\n", (unsigned long)checks);
  }
  return 0;
}
