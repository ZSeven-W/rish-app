// Built-in API catalogs retain their original harness, endpoint and Keychain
// ownership. Fetching a catalog never selects a subscription or changes keys.
static BOOL DSHBuiltinModelHarness(id harness) {
  return [harness isKindOfClass:NSString.class] &&
    [@[@"dsh", @"claude-code", @"codex", @"glm"] containsObject:harness];
}
static BOOL DSHProviderModelsRequest(id value, NSArray<NSString *> *keys) {
  return [value isKindOfClass:NSDictionary.class] && [value[@"schema_version"] isEqual:@1] &&
    [[NSSet setWithArray:[value allKeys]] isEqual:[NSSet setWithArray:keys]];
}
- (NSString *)apiModelDiscoveryCredentialForSlot:(NSString *)slot expectedAccount:(NSString *)account {
  // credentialForAccount: may return a Codex or ZCode subscription token.
  // An API /models request must read ONLY the captured API Keychain account.
  NSMutableDictionary *query = [self keychainQueryForAccount:slot];
  if (!account || ![query[(__bridge id)kSecAttrAccount] isEqual:account]) return nil;
  query[(__bridge id)kSecReturnData] = @YES;
  query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
  CFTypeRef value = nil;
  OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &value);
  if (status != errSecSuccess || !value) return nil;
  NSData *data = CFBridgingRelease(value);
  return [data isKindOfClass:NSData.class] ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}
RISH_NATIVE_METHOD(listProviderModels, listProviderModelsWithResolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  [DSHSessionWorkspaceCoordinator.sharedCoordinator performAsync:^{
    NSDictionary *registry = DSHProviderModelCatalog();
    if (registry) resolve(registry);
    else reject(@"E_MODEL_CATALOG_INVALID", @"E_MODEL_CATALOG_INVALID", nil);
  }];
}
RISH_NATIVE_METHOD(saveProviderModels, saveProviderModels:(NSDictionary *)request resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  if (!DSHProviderModelsRequest(request, @[@"schema_version", @"expected_revision", @"harness_id", @"models"]) ||
      !DSHBuiltinModelHarness(request[@"harness_id"])) {
    reject(@"E_MODEL_CATALOG_INVALID", @"E_MODEL_CATALOG_INVALID", nil); return;
  }
  [DSHSessionWorkspaceCoordinator.sharedCoordinator performAsync:^{
    if (![self providerConfigurationCanChange]) { reject(@"E_COMPLETION_BUSY", @"E_COMPLETION_BUSY", nil); return; }
    NSError *error = nil;
    NSDictionary *registry = DSHSaveProviderModelCatalog(request, &error);
    if (registry) resolve(registry);
    else reject(error.localizedDescription ?: @"E_MODEL_CATALOG_INVALID", @"Unable to save provider models", nil);
  }];
}
RISH_NATIVE_METHOD(discoverProviderModels, discoverProviderModels:(NSDictionary *)request resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  if (!DSHProviderModelsRequest(request, @[@"schema_version", @"harness_id", @"operation_id", @"expected_profile"]) ||
      !DSHBuiltinModelHarness(request[@"harness_id"]) || !DSHCustomProviderDiscoveryIsOperationId(request[@"operation_id"])) {
    reject(@"E_PROVIDER_MODEL_DISCOVERY_INVALID", @"E_PROVIDER_MODEL_DISCOVERY_INVALID", nil); return;
  }
  [DSHSessionWorkspaceCoordinator.sharedCoordinator performAsync:^{
    if (![self providerConfigurationCanChange]) { reject(@"E_COMPLETION_BUSY", @"E_COMPLETION_BUSY", nil); return; }
    NSString *harness = request[@"harness_id"];
    NSDictionary *profile = [DSHProviderConfigurationStore.sharedStore configurationForHarness:harness];
    NSDictionary *registry = DSHProviderModelCatalog();
    if (!profile || !registry || ![profile isEqual:request[@"expected_profile"]]) {
      reject(@"E_PROVIDER_CONFIGURATION_CHANGED", @"E_PROVIDER_CONFIGURATION_CHANGED", nil); return;
    }
    NSString *slot = DSHCredentialAccountForHarnessId(harness);
    NSString *account = DSHEffectiveCredentialAccount(slot);
    NSUInteger generation = [self credentialGenerationForSlot:slot];
    NSString *credential = [self apiModelDiscoveryCredentialForSlot:slot expectedAccount:account];
    if (!slot || !account || credential.length == 0) {
      reject(@"E_PROVIDER_MODEL_DISCOVERY_CREDENTIAL", @"E_PROVIDER_MODEL_DISCOVERY_CREDENTIAL", nil); return;
    }
    NSNumber *revision = registry[@"revision"];
    __weak LocalRuntimeModule *weakSelf = self;
    BOOL (^isCurrent)(void) = ^BOOL {
      __block BOOL current = NO;
      [DSHSessionWorkspaceCoordinator.sharedCoordinator performSync:^{
        LocalRuntimeModule *runtime = weakSelf;
        NSDictionary *now = [DSHProviderConfigurationStore.sharedStore configurationForHarness:harness];
        current = runtime && [runtime.customProviderDiscoveryId isEqual:harness] &&
          [runtime.customProviderDiscoveryOperationId isEqual:request[@"operation_id"]] &&
          [now isEqual:profile] && [DSHProviderModelCatalog()[@"revision"] isEqual:revision] &&
          [DSHEffectiveCredentialAccount(slot) isEqual:account] &&
          [runtime credentialGenerationForSlot:slot] == generation &&
          [[runtime apiModelDiscoveryCredentialForSlot:slot expectedAccount:account] isEqual:credential];
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
            if ([runtime.customProviderDiscoveryId isEqual:harness] &&
                [runtime.customProviderDiscoveryOperationId isEqual:request[@"operation_id"]]) {
              runtime.customProviderDiscovery = nil; runtime.customProviderDiscoveryId = nil;
              runtime.customProviderDiscoveryOperationId = nil;
            }
          }
          if (!current) { reject(@"E_PROVIDER_CONFIGURATION_CHANGED", @"E_PROVIDER_CONFIGURATION_CHANGED", nil); return; }
          if (!result) { reject(errorCode ?: @"E_PROVIDER_MODEL_DISCOVERY_INVALID", errorCode ?: @"E_PROVIDER_MODEL_DISCOVERY_INVALID", nil); return; }
          resolve(@{@"schema_version":@1, @"harness_id":harness, @"operation_id":request[@"operation_id"],
            @"models":result[@"models"], @"truncated":result[@"truncated"]});
        }];
      }];
    @synchronized(self) {
      self.customProviderDiscovery = discovery; self.customProviderDiscoveryId = harness;
      self.customProviderDiscoveryOperationId = request[@"operation_id"];
    }
    [discovery start];
  }];
}
RISH_NATIVE_METHOD(cancelProviderModelDiscovery, cancelProviderModelDiscovery:(NSDictionary *)request resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  if (!DSHProviderModelsRequest(request, @[@"schema_version", @"harness_id", @"operation_id"]) ||
      !DSHBuiltinModelHarness(request[@"harness_id"]) || !DSHCustomProviderDiscoveryIsOperationId(request[@"operation_id"])) {
    reject(@"E_PROVIDER_MODEL_DISCOVERY_INVALID", @"E_PROVIDER_MODEL_DISCOVERY_INVALID", nil); return;
  }
  [DSHSessionWorkspaceCoordinator.sharedCoordinator performAsync:^{
    DSHCustomProviderModelDiscovery *discovery = nil;
    @synchronized(self) {
      if ([self.customProviderDiscoveryId isEqual:request[@"harness_id"]] &&
          [self.customProviderDiscoveryOperationId isEqual:request[@"operation_id"]]) discovery = self.customProviderDiscovery;
    }
    BOOL cancelled = [discovery cancelForHarnessId:request[@"harness_id"] operationId:request[@"operation_id"]];
    resolve(@{@"schema_version":@1, @"harness_id":request[@"harness_id"], @"operation_id":request[@"operation_id"],
      @"status":cancelled ? @"cancelled" : @"idle"});
  }];
}
