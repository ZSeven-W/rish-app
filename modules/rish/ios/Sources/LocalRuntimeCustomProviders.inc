// Included inside LocalRuntimeModule's implementation. This bridge carries
// only provider metadata; secret values enter through the native secure alert.
static BOOL DSHCustomProviderRequest(id value, NSArray<NSString *> *keys) {
  if (![value isKindOfClass:NSDictionary.class] || ![value[@"schema_version"] isEqual:@1]) return NO;
  return [[NSSet setWithArray:[value allKeys]] isEqual:[NSSet setWithArray:keys]];
}
static NSDictionary *DSHCustomCredentialStatus(NSDictionary *request, NSString *status) {
  return @{@"schema_version":@1, @"id":request[@"id"], @"status":status};
}
- (NSDictionary *)activeCustomProviderForRequest:(NSDictionary *)request
                               expectedProfile:(BOOL)expectedProfile
                                      rejecter:(RishRejectBlock)reject {
  NSDictionary *provider = [DSHProviderConfigurationStore.sharedStore customProviderForId:request[@"id"]];
  if (![provider[@"active"] boolValue]) {
    reject(@"E_CUSTOM_PROVIDER_UNAVAILABLE", @"E_CUSTOM_PROVIDER_UNAVAILABLE", nil); return nil;
  }
  if (expectedProfile && ![provider[@"configuration"] isEqual:request[@"expected_profile"]]) {
    reject(@"E_PROVIDER_CONFIGURATION_CHANGED", @"E_PROVIDER_CONFIGURATION_CHANGED", nil); return nil;
  }
  return provider;
}
RISH_NATIVE_METHOD(listCustomProviders, listCustomProvidersWithResolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  [DSHSessionWorkspaceCoordinator.sharedCoordinator performAsync:^{
    NSError *error = nil;
    NSDictionary *registry = [DSHProviderConfigurationStore.sharedStore customRegistry:&error];
    if (registry) resolve(registry);
    else reject(error.localizedDescription ?: @"E_CUSTOM_PROVIDER_REGISTRY_INVALID", @"E_CUSTOM_PROVIDER_REGISTRY_INVALID", nil);
  }];
}
RISH_NATIVE_METHOD(saveCustomProvider, saveCustomProvider:(NSDictionary *)request resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  if (!DSHCustomProviderRequest(request, @[@"schema_version", @"expected_revision", @"provider"])) {
    reject(@"E_CUSTOM_PROVIDER_REGISTRY_INVALID", @"E_CUSTOM_PROVIDER_REGISTRY_INVALID", nil); return;
  }
  [DSHSessionWorkspaceCoordinator.sharedCoordinator performAsync:^{
    if (![self providerConfigurationCanChange]) { reject(@"E_COMPLETION_BUSY", @"E_COMPLETION_BUSY", nil); return; }
    NSError *error = nil;
    NSDictionary *registry = [DSHProviderConfigurationStore.sharedStore saveCustomProvider:request[@"provider"]
      expectedRevision:request[@"expected_revision"] error:&error];
    if (!registry) { reject(error.localizedDescription ?: @"E_CUSTOM_PROVIDER_REGISTRY_INVALID", @"Unable to save provider", nil); return; }
    NSString *providerId = request[@"provider"][@"id"];
    NSString *slot = [@"CUSTOM_API_KEY_" stringByAppendingString:providerId];
    [self credentialDidChangeForSlot:slot];
    resolve(registry);
  }];
}
RISH_NATIVE_METHOD(removeCustomProvider, removeCustomProvider:(NSDictionary *)request resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  if (!DSHCustomProviderRequest(request, @[@"schema_version", @"expected_revision", @"id"])) {
    reject(@"E_CUSTOM_PROVIDER_REGISTRY_INVALID", @"E_CUSTOM_PROVIDER_REGISTRY_INVALID", nil); return;
  }
  [DSHSessionWorkspaceCoordinator.sharedCoordinator performAsync:^{
    if (![self providerConfigurationCanChange]) { reject(@"E_COMPLETION_BUSY", @"E_COMPLETION_BUSY", nil); return; }
    NSError *error = nil;
    NSDictionary *registry = [DSHProviderConfigurationStore.sharedStore removeCustomProvider:request[@"id"]
      expectedRevision:request[@"expected_revision"] error:&error];
    if (!registry) { reject(error.localizedDescription ?: @"E_CUSTOM_PROVIDER_REGISTRY_INVALID", @"Unable to remove provider", nil); return; }
    NSString *harness = [@"custom-" stringByAppendingString:request[@"id"]];
    [self credentialDidChangeForSlot:[@"CUSTOM_API_KEY_" stringByAppendingString:request[@"id"]]];
    @synchronized(self) { [self.customProviderTransports removeObjectForKey:harness]; }
    resolve(registry);
  }];
}
RISH_NATIVE_METHOD(customProviderCredentialStatus, customProviderCredentialStatus:(NSDictionary *)request resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  if (!DSHCustomProviderRequest(request, @[@"schema_version", @"id"])) {
    reject(@"E_CUSTOM_PROVIDER_REGISTRY_INVALID", @"E_CUSTOM_PROVIDER_REGISTRY_INVALID", nil); return;
  }
  [DSHSessionWorkspaceCoordinator.sharedCoordinator performAsync:^{
    NSDictionary *provider = [self activeCustomProviderForRequest:request expectedProfile:NO rejecter:reject];
    if (!provider) return;
    if (!DSHProviderRequiresCredential(provider[@"configuration"])) { resolve(DSHCustomCredentialStatus(request, @"not_required")); return; }
    NSString *slot = DSHCredentialAccountForHarnessId(provider[@"configuration"][@"harness_id"]);
    OSStatus status = [self credentialLookupStatusForAccount:slot];
    if (status == errSecSuccess || status == errSecItemNotFound) resolve(DSHCustomCredentialStatus(request, status == errSecSuccess ? @"configured" : @"missing"));
    else reject(@"keychain", @"Unable to read credential status", nil);
  }];
}
RISH_NATIVE_METHOD(presentCustomProviderCredentialPrompt, presentCustomProviderCredentialPrompt:(NSDictionary *)request resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  if (!DSHCustomProviderRequest(request, @[@"schema_version", @"id", @"expected_profile", @"locale"])) {
    reject(@"E_CUSTOM_PROVIDER_REGISTRY_INVALID", @"E_CUSTOM_PROVIDER_REGISTRY_INVALID", nil); return;
  }
  [DSHSessionWorkspaceCoordinator.sharedCoordinator performAsync:^{
    if (![self providerConfigurationCanChange]) { reject(@"E_COMPLETION_BUSY", @"E_COMPLETION_BUSY", nil); return; }
    NSDictionary *provider = [self activeCustomProviderForRequest:request expectedProfile:YES rejecter:reject];
    if (!provider) return;
    if (!DSHProviderRequiresCredential(provider[@"configuration"])) { resolve(DSHCustomCredentialStatus(request, @"not_required")); return; }
    [self presentCredentialPromptForSlot:DSHCredentialAccountForHarnessId(provider[@"configuration"][@"harness_id"])
      locale:request[@"locale"] resolver:^(id result) { resolve(DSHCustomCredentialStatus(request, result[@"status"])); } rejecter:reject];
  }];
}
RISH_NATIVE_METHOD(clearCustomProviderCredential, clearCustomProviderCredential:(NSDictionary *)request resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  if (!DSHCustomProviderRequest(request, @[@"schema_version", @"id", @"expected_profile"])) {
    reject(@"E_CUSTOM_PROVIDER_REGISTRY_INVALID", @"E_CUSTOM_PROVIDER_REGISTRY_INVALID", nil); return;
  }
  [DSHSessionWorkspaceCoordinator.sharedCoordinator performAsync:^{
    if (![self providerConfigurationCanChange]) { reject(@"E_COMPLETION_BUSY", @"E_COMPLETION_BUSY", nil); return; }
    NSDictionary *provider = [self activeCustomProviderForRequest:request expectedProfile:YES rejecter:reject];
    if (!provider) return;
    if (!DSHProviderRequiresCredential(provider[@"configuration"])) { resolve(DSHCustomCredentialStatus(request, @"not_required")); return; }
    NSError *error = nil;
    NSString *slot = DSHCredentialAccountForHarnessId(provider[@"configuration"][@"harness_id"]);
    if (![self deleteCredentialForAccount:slot error:&error]) { reject(@"keychain", @"Unable to clear credential", nil); return; }
    resolve(DSHCustomCredentialStatus(request, @"cleared"));
  }];
}

RISH_NATIVE_METHOD(discoverCustomProviderModels, discoverCustomProviderModels:(NSDictionary *)request resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  if (!DSHCustomProviderRequest(request, @[@"schema_version", @"id", @"operation_id", @"expected_profile"]) ||
      !DSHCustomProviderDiscoveryIsOperationId(request[@"operation_id"])) {
    reject(@"E_CUSTOM_PROVIDER_REGISTRY_INVALID", @"E_CUSTOM_PROVIDER_REGISTRY_INVALID", nil); return;
  }
  [DSHSessionWorkspaceCoordinator.sharedCoordinator performAsync:^{
    if (![self providerConfigurationCanChange]) { reject(@"E_COMPLETION_BUSY", @"E_COMPLETION_BUSY", nil); return; }
    NSDictionary *provider = [self activeCustomProviderForRequest:request expectedProfile:YES rejecter:reject];
    if (!provider) return;
    NSDictionary *profile = provider[@"configuration"];
    NSString *slot = DSHCredentialAccountForHarnessId(profile[@"harness_id"]);
    NSString *account = DSHEffectiveCredentialAccount(slot);
    if (!slot) { reject(@"E_PROVIDER_MODEL_DISCOVERY_CREDENTIAL", @"E_PROVIDER_MODEL_DISCOVERY_CREDENTIAL", nil); return; }
    NSUInteger generation = [self credentialGenerationForSlot:slot];
    NSString *credential = DSHProviderRequiresCredential(profile) ? [self credentialForAccount:slot generation:&generation] : nil;
    if (DSHProviderRequiresCredential(profile) && (account == nil || credential.length == 0)) {
      reject(@"E_PROVIDER_MODEL_DISCOVERY_CREDENTIAL", @"E_PROVIDER_MODEL_DISCOVERY_CREDENTIAL", nil); return;
    }
    __weak LocalRuntimeModule *weakSelf = self;
    BOOL (^isCurrent)(void) = ^BOOL {
      __block BOOL current = NO;
      [DSHSessionWorkspaceCoordinator.sharedCoordinator performSync:^{
        LocalRuntimeModule *runtime = weakSelf;
        NSDictionary *now = [DSHProviderConfigurationStore.sharedStore customProviderForId:request[@"id"]];
        NSString *effective = DSHEffectiveCredentialAccount(slot);
        current = runtime && [runtime.customProviderDiscoveryOperationId isEqual:request[@"operation_id"]] &&
          [now[@"active"] boolValue] && [now[@"configuration"] isEqual:profile] &&
          [runtime credentialGenerationForSlot:slot] == generation &&
          (account == nil ? effective == nil : [account isEqual:effective]);
      }];
      return current;
    };
    DSHCustomProviderModelDiscovery *discovery = [[DSHCustomProviderModelDiscovery alloc]
      initWithConfiguration:profile operationId:request[@"operation_id"] credential:credential sourceIsCurrent:isCurrent
      completion:^(NSDictionary *result, NSString *errorCode) {
        [DSHSessionWorkspaceCoordinator.sharedCoordinator performAsync:^{
          LocalRuntimeModule *runtime = weakSelf;
          BOOL current = isCurrent();
          @synchronized(runtime) {
            if ([runtime.customProviderDiscoveryOperationId isEqual:request[@"operation_id"]]) {
              runtime.customProviderDiscovery = nil; runtime.customProviderDiscoveryId = nil;
              runtime.customProviderDiscoveryOperationId = nil;
            }
          }
          if (!current) { reject(@"E_PROVIDER_CONFIGURATION_CHANGED", @"E_PROVIDER_CONFIGURATION_CHANGED", nil); return; }
          if (!result) { reject(errorCode ?: @"E_PROVIDER_MODEL_DISCOVERY_INVALID", errorCode ?: @"E_PROVIDER_MODEL_DISCOVERY_INVALID", nil); return; }
          resolve(@{@"schema_version":@1, @"id":request[@"id"], @"operation_id":request[@"operation_id"], @"models":result[@"models"], @"truncated":result[@"truncated"]});
        }];
      }];
    @synchronized(self) {
      self.customProviderDiscovery = discovery; self.customProviderDiscoveryId = request[@"id"];
      self.customProviderDiscoveryOperationId = request[@"operation_id"];
    }
    [discovery start];
  }];
}
RISH_NATIVE_METHOD(cancelCustomProviderModelDiscovery, cancelCustomProviderModelDiscovery:(NSDictionary *)request resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  if (!DSHCustomProviderRequest(request, @[@"schema_version", @"id", @"operation_id"]) ||
      !DSHCustomProviderDiscoveryIsOperationId(request[@"id"]) || !DSHCustomProviderDiscoveryIsOperationId(request[@"operation_id"])) {
    reject(@"E_CUSTOM_PROVIDER_REGISTRY_INVALID", @"E_CUSTOM_PROVIDER_REGISTRY_INVALID", nil); return;
  }
  [DSHSessionWorkspaceCoordinator.sharedCoordinator performAsync:^{
    DSHCustomProviderModelDiscovery *discovery = nil;
    @synchronized(self) {
      if ([self.customProviderDiscoveryId isEqual:request[@"id"]] &&
          [self.customProviderDiscoveryOperationId isEqual:request[@"operation_id"]]) discovery = self.customProviderDiscovery;
    }
    BOOL cancelled = [discovery cancelForProviderId:request[@"id"] operationId:request[@"operation_id"]];
    resolve(@{@"schema_version":@1, @"id":request[@"id"], @"operation_id":request[@"operation_id"],
      @"status":cancelled ? @"cancelled" : @"idle"});
  }];
}
