// Included by ProviderPolicyHostTests.mm so these checks exercise the same
// real Rust C ABI and isolated NSUserDefaults suite as the baseline cases.
static NSString *const IndependentRegistryKey = @"RishIndependentProvidersV1";
static NSString *const IndependentProviderA = @"11111111-1111-4111-8111-111111111111";
static NSString *const IndependentProviderB = @"22222222-2222-4222-8222-222222222222";
static NSString *const IndependentProviderC = @"33333333-3333-4333-8333-333333333333";
static NSString *const IndependentProviderD = @"44444444-4444-4444-8444-444444444444";
static NSString *const IndependentModelA = @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
static NSString *const IndependentModelB = @"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";

static NSString *IndependentLogical(NSString *provider, NSString *model) {
  return [NSString stringWithFormat:@"custom:%@:%@", provider, model];
}
static NSString *IndependentHarness(NSString *provider) {
  return [@"custom-" stringByAppendingString:provider];
}
static NSDictionary *IndependentProvider(NSString *provider, NSString *model, NSString *protocol,
                                        NSString *auth) {
  return @{@"id":provider, @"active":@YES,
    @"configuration":@{@"schema_version":@1, @"harness_id":IndependentHarness(provider),
      @"name":@"Independent relay", @"endpoint_url":@"https://relay.example/v1",
      @"protocol":protocol, @"auth_type":auth, @"send_reasoning":@YES,
      @"model_mappings":@{IndependentLogical(provider, model):@"same-wire-model"}},
    @"models":@[@{@"id":model, @"name":@"Independent model", @"wire_model":@"same-wire-model",
      @"supports_images":@YES, @"active":@YES}]};
}
static NSDictionary *IndependentRename(NSDictionary *provider, NSString *name) {
  NSMutableDictionary *changed = [provider mutableCopy];
  NSMutableDictionary *configuration = [provider[@"configuration"] mutableCopy];
  configuration[@"name"] = name;
  changed[@"configuration"] = configuration;
  return changed;
}

static void EmptyIndependentProviderCases(DSHProviderConfigurationStore *store) {
  id previous = [testDefaults objectForKey:IndependentRegistryKey];
  NSSet *modelsBefore = DSHHarnessSupportedModels();
  NSMutableDictionary *provider = [IndependentProvider(IndependentProviderA, IndependentModelA, @"responses", @"bearer") mutableCopy];
  NSMutableDictionary *configuration = [provider[@"configuration"] mutableCopy];
  configuration[@"model_mappings"] = @{}; provider[@"configuration"] = configuration; provider[@"models"] = @[];
  NSString *harness = IndependentHarness(IndependentProviderA);
  NSString *model = IndependentLogical(IndependentProviderA, IndependentModelA);
  NSString *slot = [@"CUSTOM_API_KEY_" stringByAppendingString:IndependentProviderA];
  @try {
    NSDictionary *saved = [store saveCustomProvider:provider expectedRevision:@0 error:nil];
    Check([saved[@"revision"] isEqual:@1] && [store configurationForHarness:harness] != nil &&
      [[store customProviderForId:IndependentProviderA][@"models"] count] == 0,
      @"A provider can persist its own endpoint and configuration before any models are selected");
    Check(DSHHarnessIsSupportedHarnessId(harness) && [DSHHarnessSupportedHarnessIds() containsObject:harness] &&
      DSHHarnessIsProviderId(harness) && [DSHHarnessSupportedProviderIds() containsObject:harness] &&
      [DSHProviderIdForHarnessId(harness) isEqual:harness],
      @"An empty provider retains harness and provider identity independently of model rows");
    Check([DSHProviderHostForProviderId(harness) isEqual:@"relay.example"] &&
      [DSHHarnessSupportedProviderHosts() containsObject:@"relay.example"],
      @"An empty provider exposes its own endpoint host for provider operations");
    Check([DSHCredentialAccountForHarnessId(harness) isEqual:slot] && DSHHarnessIsCredentialAccount(slot) &&
      [DSHHarnessCredentialAccounts() containsObject:slot] && DSHEffectiveCredentialAccount(slot).length > 0,
      @"An empty provider can configure its isolated credential before model discovery");
    Check([store customModelsIncludingRetired:NO].count == 0 && [store customModelsIncludingRetired:YES].count == 0 &&
      [DSHHarnessSupportedModels() isEqual:modelsBefore] && DSHHarnessIdForModel(model) == nil &&
      [store customRouteForModel:model requireActive:YES] == nil && [store customRouteForModel:model requireActive:NO] == nil,
      @"An empty provider creates no implicit model identity or executable route");
    Check(DSHProviderBindingForModel(model) == nil && !DSHProviderBindingIsCurrent(nil, model),
      @"An unselected model cannot receive a binding or authorize missing-binding dispatch");
    Check([store saveCustomProvider:IndependentProvider(IndependentProviderA, IndependentModelA, @"responses", @"bearer")
      expectedRevision:@1 error:nil] != nil && [store customRouteForModel:model requireActive:YES] != nil,
      @"Selecting a model explicitly activates only its registered independent route");
    Check([store saveCustomProvider:provider expectedRevision:@2 error:nil] != nil &&
      [store customRouteForModel:model requireActive:YES] == nil &&
      [store customRouteForModel:model requireActive:NO] != nil &&
      [store configurationForHarness:harness] != nil && DSHEffectiveCredentialAccount(slot).length > 0,
      @"Removing the last selected model retains provider configuration and credentials while retiring its route");
    Check([store removeCustomProvider:IndependentProviderA expectedRevision:@3 error:nil] != nil &&
      DSHHarnessIsSupportedHarnessId(harness) && DSHHarnessIsProviderId(harness) &&
      [DSHCredentialAccountForHarnessId(harness) isEqual:slot] && [store configurationForHarness:harness] == nil,
      @"Retiring an empty provider preserves its catalog identities without an active configuration");
  } @finally {
    if (previous) [testDefaults setObject:previous forKey:IndependentRegistryKey];
    else [testDefaults removeObjectForKey:IndependentRegistryKey];
  }
}

static void IndependentProviderIdentityCases(DSHProviderConfigurationStore *store) {
  NSDictionary *empty = [store customRegistry:nil];
  Check([empty isEqual:@{@"schema_version":@1, @"revision":@0, @"providers":@[]}],
    @"Only missing independent registry storage selects an empty registry");
  Check([testDefaults objectForKey:IndependentRegistryKey] == nil,
    @"Reading an absent independent registry does not persist defaults");
  NSDictionary *first = IndependentProvider(IndependentProviderA, IndependentModelA, @"responses", @"bearer");
  NSDictionary *second = IndependentProvider(IndependentProviderB, IndependentModelA, @"responses", @"bearer");
  Check([store saveCustomProvider:first expectedRevision:@0 error:nil] != nil,
    @"Native storage saves a first independent provider through Rust validation");
  NSDictionary *saved = [store saveCustomProvider:second expectedRevision:@1 error:nil];
  Check([saved[@"revision"] isEqual:@2] && [saved[@"providers"] count] == 2,
    @"The same name, URL, dialect and wire model create two separate providers");
  NSString *firstModel = IndependentLogical(IndependentProviderA, IndependentModelA);
  NSString *secondModel = IndependentLogical(IndependentProviderB, IndependentModelA);
  NSString *firstHarness = IndependentHarness(IndependentProviderA);
  NSString *secondHarness = IndependentHarness(IndependentProviderB);
  NSDictionary *firstRoute = [store customRouteForModel:firstModel requireActive:YES];
  NSDictionary *secondRoute = [store customRouteForModel:secondModel requireActive:YES];
  Check([firstRoute[@"wire_model"] isEqual:secondRoute[@"wire_model"]] &&
    ![firstRoute[@"provider_id"] isEqual:secondRoute[@"provider_id"]],
    @"The shared upstream wire model never collapses independent provider identities");
  Check([firstRoute[@"configuration"][@"endpoint_url"] isEqual:@"https://relay.example/v1/responses"],
    @"Foundation normalizes the base URL using the selected Rust dialect plan");
  Check([DSHHarnessIdForModel(firstModel) isEqual:firstHarness] &&
    [DSHProviderIdForModel(secondModel) isEqual:secondHarness],
    @"Native model and provider lookups use registered independent identities");
  Check([DSHHarnessSupportedModels() containsObject:firstModel] &&
    [DSHHarnessSupportedHarnessIds() containsObject:firstHarness] &&
    [DSHHarnessSupportedProviderIds() containsObject:secondHarness] &&
    [DSHHarnessSupportedProviderHosts() containsObject:@"relay.example"],
    @"Native validation sets include independent models, harnesses, providers and hosts");
  Check([DSHProviderHostForModel(firstModel) isEqual:@"relay.example"] &&
    DSHHarnessIsSupportedHarnessId(firstHarness) && DSHHarnessIsProviderId(firstHarness),
    @"Independent catalog host and membership predicates agree with registry routing");
  NSString *firstSlot = DSHCredentialAccountForHarnessId(firstHarness);
  NSString *secondSlot = DSHCredentialAccountForHarnessId(secondHarness);
  Check([firstSlot isEqual:[@"CUSTOM_API_KEY_" stringByAppendingString:IndependentProviderA]] &&
    [secondSlot isEqual:[@"CUSTOM_API_KEY_" stringByAppendingString:IndependentProviderB]],
    @"Each independent provider has a distinct strict credential slot");
  Check(DSHHarnessIsCredentialAccount(firstSlot) &&
    [DSHConfigurableHarnessForSlot(firstSlot) isEqual:firstHarness],
    @"Credential slot membership and reverse harness routing agree");
  NSString *firstAccount = DSHEffectiveCredentialAccount(firstSlot);
  NSString *secondAccount = DSHEffectiveCredentialAccount(secondSlot);
  Check(firstAccount.length > 0 && secondAccount.length > 0 && ![firstAccount isEqual:secondAccount],
    @"Identical endpoints and labels cannot share a Keychain account across providers");
  NSDictionary *firstBinding = DSHProviderBindingForModel(firstModel);
  NSDictionary *secondBinding = DSHProviderBindingForModel(secondModel);
  Check([firstBinding[@"model_id"] isEqual:@"same-wire-model"] &&
    ![firstBinding[@"profile_id"] isEqual:secondBinding[@"profile_id"]],
    @"Bindings map wire models while including the independent harness in their identity");
  Check(DSHValidateProviderBinding(firstBinding, firstModel) &&
    DSHProviderBindingIsCurrent(firstBinding, firstModel) &&
    !DSHValidateProviderBinding(firstBinding, secondModel),
    @"A current independent binding cannot authorize another provider's logical model");
  Check([store customRouteForModel:@"same-wire-model" requireActive:YES] == nil &&
    !DSHHarnessIsSupportedModel(@"same-wire-model"),
    @"A wire model name is never an independent logical routing identity");
  usesSubscription = YES;
  Check([DSHProviderBindingForModel(firstModel) isEqual:firstBinding],
    @"Codex subscription selection cannot replace an independent provider binding");
  usesSubscription = NO;
  DSHProviderConfigurationStore *restarted = [[DSHProviderConfigurationStore alloc] initWithDefaults:testDefaults];
  Check([[restarted customRegistry:nil] isEqual:saved] &&
    [[restarted configurationForHarness:firstHarness] isEqual:firstRoute[@"configuration"]],
    @"A restarted native store preserves both independent profiles and normalized URLs");
  Check([DSHCredentialAccountForHarnessId(@"codex") isEqual:@"OPENAI_API_KEY"] &&
    [DSHEffectiveCredentialAccount(@"OPENAI_API_KEY") isEqual:@"OPENAI_API_KEY"],
    @"Adding independent providers leaves built-in credential slots unchanged");
}

static void IndependentProviderProtocolCases(DSHProviderConfigurationStore *store) {
  NSDictionary *chat = IndependentProvider(IndependentProviderC, IndependentModelA, @"chat-completions", @"none");
  NSDictionary *messages = IndependentProvider(IndependentProviderD, IndependentModelA, @"messages", @"x-api-key");
  Check([store saveCustomProvider:chat expectedRevision:@2 error:nil] != nil &&
    [store saveCustomProvider:messages expectedRevision:@3 error:nil] != nil,
    @"Independent providers accept all three supported protocol dialects");
  NSString *chatModel = IndependentLogical(IndependentProviderC, IndependentModelA);
  NSString *messageModel = IndependentLogical(IndependentProviderD, IndependentModelA);
  NSDictionary *chatProfile = [store configurationForHarness:IndependentHarness(IndependentProviderC)];
  NSDictionary *messageProfile = [store configurationForHarness:IndependentHarness(IndependentProviderD)];
  Check([chatProfile[@"endpoint_url"] isEqual:@"https://relay.example/v1/chat/completions"] &&
    [messageProfile[@"endpoint_url"] isEqual:@"https://relay.example/v1/messages"],
    @"Each independently selected dialect receives its own normalized endpoint");
  Check(!DSHProviderRequiresCredential(chatProfile) && DSHProviderRequiresCredential(messageProfile),
    @"Only an explicit no-auth profile bypasses credential requirements");
  Check(DSHDshModelSupportsImages(chatModel) && DSHDshModelSupportsImages(messageModel),
    @"Native attachment capability resolves independent model configuration");
  Check(DSHEffectiveCredentialAccount(DSHCredentialAccountForHarnessId(IndependentHarness(IndependentProviderC))) == nil,
    @"No-auth profiles have no effective Keychain account or built-in key fallback");
  Check(DSHValidateProviderBinding(DSHProviderBindingForModel(chatModel), chatModel) &&
    DSHValidateProviderBinding(DSHProviderBindingForModel(messageModel), messageModel),
    @"No-auth chat and API-key Messages profiles produce valid independent bindings");
  Check(DSHEffectiveCredentialAccount(@"CUSTOM_API_KEY_99999999-9999-4999-8999-999999999999") == nil &&
    DSHEffectiveCredentialAccount(@"CUSTOM_API_KEY_bad") == nil,
    @"Missing or malformed independent slots cannot fall back to another credential account");
}

static void IndependentProviderConflictCases(DSHProviderConfigurationStore *store) {
  NSDictionary *before = [store customRegistry:nil];
  NSDictionary *provider = [store customProviderForId:IndependentProviderA];
  NSError *error = nil;
  Check([store saveCustomProvider:IndependentRename(provider, @"Stale edit") expectedRevision:@0 error:&error] == nil &&
    [error.localizedDescription isEqual:@"E_CUSTOM_PROVIDER_REGISTRY_CONFLICT"],
    @"A stale changed provider update fails the registry compare-and-swap");
  Check([[testDefaults objectForKey:IndependentRegistryKey] isEqual:before],
    @"A stale provider update leaves the full persisted registry unchanged");
  error = nil;
  Check([store removeCustomProvider:IndependentProviderB expectedRevision:@0 error:&error] == nil &&
    [error.localizedDescription isEqual:@"E_CUSTOM_PROVIDER_REGISTRY_CONFLICT"],
    @"A stale removal cannot retire a different currently active provider");
  NSArray *corrupt = @[@"invalid-registry"];
  [testDefaults setObject:corrupt forKey:IndependentRegistryKey];
  error = nil;
  Check([store customRegistry:&error] == nil &&
    [error.localizedDescription isEqual:@"E_CUSTOM_PROVIDER_REGISTRY_INVALID"],
    @"Malformed independent storage fails closed rather than selecting empty defaults");
  Check([store saveCustomProvider:provider expectedRevision:@0 error:nil] == nil &&
    [store removeCustomProvider:IndependentProviderA expectedRevision:@0 error:nil] == nil,
    @"Neither a normal save nor removal repairs malformed storage implicitly");
  Check([[testDefaults objectForKey:IndependentRegistryKey] isEqual:corrupt] &&
    [store customRouteForModel:IndependentLogical(IndependentProviderA, IndependentModelA) requireActive:YES] == nil,
    @"Corrupt storage is preserved and cannot authorize a request");
  Check([DSHHarnessIdForModel(@"claude-sonnet-5") isEqual:@"claude-code"],
    @"Malformed independent storage cannot erase a built-in identity");
  [testDefaults setObject:before forKey:IndependentRegistryKey];
  for (NSString *endpoint in @[@"http://remote.example/v1/responses", @"https://user:secret@relay.example/v1/responses",
      @"https://relay.example/v1/responses?token=hidden", @"HTTPS://RELAY.EXAMPLE/v1/responses"]) {
    NSMutableDictionary *poisoned = [before mutableCopy];
    NSMutableArray *providers = [before[@"providers"] mutableCopy];
    NSMutableDictionary *invalid = [providers[0] mutableCopy];
    NSMutableDictionary *profile = [invalid[@"configuration"] mutableCopy];
    profile[@"endpoint_url"] = endpoint; invalid[@"configuration"] = profile; providers[0] = invalid;
    poisoned[@"providers"] = providers;
    [testDefaults setObject:poisoned forKey:IndependentRegistryKey];
    Check([store customRegistry:nil] == nil && [store saveCustomProvider:provider expectedRevision:@4 error:nil] == nil &&
      [[testDefaults objectForKey:IndependentRegistryKey] isEqual:poisoned],
      @"Host codec rejects unsafe or noncanonical stored endpoints without repairing or replacing storage");
  }
  [testDefaults setObject:before forKey:IndependentRegistryKey];
}

static void IndependentProviderHistoryCases(DSHProviderConfigurationStore *store) {
  NSString *oldModel = IndependentLogical(IndependentProviderA, IndependentModelA);
  NSString *newModel = IndependentLogical(IndependentProviderA, IndependentModelB);
  NSString *harness = IndependentHarness(IndependentProviderA);
  NSString *slot = DSHCredentialAccountForHarnessId(harness);
  NSString *oldAccount = DSHEffectiveCredentialAccount(slot);
  NSDictionary *oldBinding = DSHProviderBindingForModel(oldModel);
  NSDictionary *provider = [store customProviderForId:IndependentProviderA];
  NSDictionary *renamed = IndependentRename(provider, @"Renamed relay");
  NSDictionary *saved = [store saveCustomProvider:renamed expectedRevision:@4 error:nil];
  Check([saved[@"revision"] isEqual:@5] && [DSHEffectiveCredentialAccount(slot) isEqual:oldAccount] &&
    [DSHProviderBindingForModel(oldModel) isEqual:oldBinding],
    @"Renaming a provider preserves its credential and captured execution identity");
  NSMutableDictionary *moved = [renamed mutableCopy];
  NSMutableDictionary *configuration = [renamed[@"configuration"] mutableCopy];
  configuration[@"endpoint_url"] = @"https://other.example/v1/responses";
  moved[@"configuration"] = configuration;
  saved = [store saveCustomProvider:moved expectedRevision:@5 error:nil];
  Check([saved[@"revision"] isEqual:@6] && ![DSHEffectiveCredentialAccount(slot) isEqual:oldAccount],
    @"Changing an independent endpoint rotates its effective credential account");
  Check(DSHValidateProviderBinding(oldBinding, oldModel) && !DSHProviderBindingIsCurrent(oldBinding, oldModel),
    @"An endpoint edit preserves historical binding validity while rejecting stale dispatch");
  NSDictionary *replacement = IndependentProvider(IndependentProviderA, IndependentModelB, @"responses", @"bearer");
  saved = [store saveCustomProvider:replacement expectedRevision:@6 error:nil];
  Check([saved[@"revision"] isEqual:@7] && [store customRouteForModel:oldModel requireActive:YES] == nil &&
    [store customRouteForModel:newModel requireActive:YES] != nil,
    @"Replacing a model retires its old logical identity and routes only the new model");
  Check([[store customRouteForModel:oldModel requireActive:NO][@"active"] isEqual:@NO] &&
    [DSHHarnessIdForModel(oldModel) isEqual:harness] && [DSHHarnessSupportedModels() containsObject:oldModel],
    @"Retired models remain discoverable for stored conversation validation");
  Check(DSHValidateProviderBinding(oldBinding, oldModel) && !DSHProviderBindingIsCurrent(oldBinding, oldModel),
    @"A retired model's captured binding remains historical and cannot become current");
  Check(!DSHDshModelSupportsImages(oldModel), @"Retired model capabilities cannot authorize a new attachment request");
  NSDictionary *newBinding = DSHProviderBindingForModel(newModel);
  saved = [store removeCustomProvider:IndependentProviderA expectedRevision:@7 error:nil];
  Check([saved[@"revision"] isEqual:@8] && [store configurationForHarness:harness] == nil &&
    [store customRouteForModel:newModel requireActive:YES] == nil,
    @"Removing a provider disables live configuration and every active route");
  Check([store customRouteForModel:newModel requireActive:NO] != nil &&
    DSHHarnessIsSupportedHarnessId(harness) && DSHHarnessIsProviderId(harness) &&
    [DSHCredentialAccountForHarnessId(harness) isEqual:slot],
    @"Retired provider, model and credential-slot identities remain available to history");
  Check(DSHValidateProviderBinding(newBinding, newModel) &&
    !DSHProviderBindingIsCurrent(newBinding, newModel) && !DSHProviderBindingIsCurrent(nil, newModel) &&
    DSHEffectiveCredentialAccount(slot) == nil,
    @"A removed provider cannot authorize missing bindings or recover an execution credential");
  Check([store customModelsIncludingRetired:NO].count == 3 && [store customModelsIncludingRetired:YES].count == 5,
    @"Active model listings hide the retired provider while history includes both retired models");
}

// This prefix was historically an opaque DSH model name. Only the exact
// two-UUID namespace is reserved for independent provider identities.
static void LegacyOpaqueProviderModelCases(void) {
  NSString *key = @"rish.dsh-models.v1";
  id previous = [testDefaults objectForKey:key];
  NSString *collision = IndependentLogical(IndependentProviderA, IndependentModelA);
  NSDictionary *legacy = @{@"schema_version":@1, @"models":@[
    @{@"id":@"custom:my-llama", @"name":@"Legacy Llama", @"supports_images":@YES},
    @{@"id":collision, @"name":@"Historical collision", @"supports_images":@YES}],
    @"retired_models":@[@{@"id":@"custom:old-model", @"name":@"Retired opaque model", @"supports_images":@YES}]};
  [testDefaults setObject:legacy forKey:key];
  @try {
    Check(DSHDshModelCatalog() != nil && [[testDefaults objectForKey:key] isEqual:legacy],
      @"Old opaque custom-prefix DSH models remain readable without migration");
    Check([DSHHarnessIdForModel(@"custom:my-llama") isEqual:@"dsh"] &&
      DSHHarnessIsSupportedModel(@"custom:my-llama") && DSHDshModelSupportsImages(@"custom:my-llama"),
      @"Existing opaque custom-prefix model preserves DSH routing and image capability");
    Check([DSHHarnessIdForModel(@"custom:old-model") isEqual:@"dsh"] &&
      [DSHHarnessSupportedModels() containsObject:@"custom:old-model"],
      @"Retired opaque DSH model identities remain available for history");
    Check(DSHHarnessIdForModel(collision) == nil && !DSHHarnessIsSupportedModel(collision) &&
      ![DSHHarnessSupportedModels() containsObject:collision] && !DSHDshModelSupportsImages(collision),
      @"A legacy exact UUID collision cannot route outside the independent registry");
    Check(DSHDshModelEntry(collision) != nil && [[testDefaults objectForKey:key] isEqual:legacy],
      @"Colliding legacy metadata remains available for repair and does not erase valid entries");
    NSDictionary *profile = @{@"schema_version":@1, @"harness_id":@"dsh", @"name":@"Legacy relay",
      @"endpoint_url":@"https://legacy.example/v1", @"protocol":@"chat-completions", @"auth_type":@"bearer",
      @"send_reasoning":@NO, @"model_mappings":@{@"custom:my-llama":@"wire-llama"}};
    NSDictionary *binding = DSHProviderBindingFromConfiguration(profile, @"custom:my-llama");
    Check([binding[@"model_id"] isEqual:@"wire-llama"] && DSHValidateProviderBinding(binding, @"custom:my-llama"),
      @"Legacy opaque DSH identity retains its existing provider binding semantics");
    NSDictionary *request = @{@"schema_version":@1, @"models":@[
      @{@"id":@"custom:new-model", @"name":@"New reserved name", @"supports_images":@NO}]};
    Check(DSHSaveDshModelCatalog(request) == nil && [[testDefaults objectForKey:key] isEqual:legacy],
      @"New DSH catalog writes reject reserved prefixes without damaging historical storage");
  } @finally {
    if (previous) [testDefaults setObject:previous forKey:key]; else [testDefaults removeObjectForKey:key];
  }
}

static void IndependentProviderCases(void) {
  id previous = [testDefaults objectForKey:IndependentRegistryKey];
  [testDefaults removeObjectForKey:IndependentRegistryKey];
  DSHProviderConfigurationStore *store = [[DSHProviderConfigurationStore alloc] initWithDefaults:testDefaults];
  @try {
    EmptyIndependentProviderCases(store);
    LegacyOpaqueProviderModelCases();
    IndependentProviderIdentityCases(store);
    IndependentProviderProtocolCases(store);
    IndependentProviderConflictCases(store);
    IndependentProviderHistoryCases(store);
  } @finally {
    if (previous) [testDefaults setObject:previous forKey:IndependentRegistryKey];
    else [testDefaults removeObjectForKey:IndependentRegistryKey];
  }
}
