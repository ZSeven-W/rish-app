static NSDictionary *ProviderRow(NSDictionary *catalog, NSString *harness) {
  for (NSDictionary *row in catalog[@"providers"]) if ([row[@"harness_id"] isEqual:harness]) return row;
  return nil;
}
static NSDictionary *SaveModels(NSDictionary *catalog, NSString *harness, NSArray *models) {
  return DSHSaveProviderModelCatalog(@{@"schema_version":@1, @"expected_revision":catalog[@"revision"],
    @"harness_id":harness, @"models":models}, nil);
}
static void BuiltinProviderModelCases(void) {
  NSString *key = @"RishProviderModelsV1";
  [testDefaults removeObjectForKey:key];
  [testDefaults removeObjectForKey:@"rish.dsh-models.v1"];
  NSDictionary *catalog = DSHProviderModelCatalog();
  Check(catalog != nil && [catalog[@"providers"] count] == 4 && [catalog[@"revision"] isEqual:@0], @"Fresh API catalog has four provider identities and no selected model");
  Check(DSHProviderModelRows(NO).count == 0 && [testDefaults objectForKey:key] == nil,
    @"Reading an empty provider catalog never writes storage or exposes baked-in choices");
  Check([DSHHarnessSupportedModels() containsObject:@"claude-sonnet-5"] &&
    !DSHHarnessModelIsExecutable(@"claude-sonnet-5"), @"Legacy identity validates history without authorizing fresh work");
  NSArray *harnesses = @[@"dsh", @"claude-code", @"codex", @"glm"];
  NSArray *models = @[@"deepseek-test-next", @"claude-test-next", @"gpt-test-next", @"glm-test-next"];
  NSMutableDictionary *accounts = [NSMutableDictionary dictionary];
  for (NSString *harness in harnesses) {
    NSString *slot = DSHCredentialAccountForHarnessId(harness);
    accounts[harness] = DSHEffectiveCredentialAccount(slot);
  }
  for (NSUInteger i = 0; i < harnesses.count; i++) {
    NSDictionary *row = @{@"id":models[i], @"name":[@"用户模型 " stringByAppendingString:models[i]], @"supports_images":@(i == 1)};
    catalog = SaveModels(catalog, harnesses[i], @[row]);
    Check(catalog != nil && [DSHHarnessIdForModel(models[i]) isEqual:harnesses[i]] && DSHHarnessModelIsExecutable(models[i]),
      @"Explicit provider registration authorizes arbitrary real raw IDs in their own harness");
    Check([DSHHarnessSupportedModels() containsObject:models[i]], @"Native history environment contains registered raw model ID");
    Check([DSHEffectiveCredentialAccount(DSHCredentialAccountForHarnessId(harnesses[i])) isEqual:accounts[harnesses[i]]],
      @"Changing model metadata never changes the API credential account or provider profile");
  }
  Check(DSHDshModelSupportsImages(models[1]) && !DSHDshModelSupportsImages(models[2]),
    @"Generic attachment capability lookup reads explicit metadata for every provider");
  NSDictionary *before = [testDefaults objectForKey:key];
  NSError *conflict = nil;
  Check(DSHSaveProviderModelCatalog(@{@"schema_version":@1, @"expected_revision":@0, @"harness_id":@"dsh", @"models":@[]}, &conflict) == nil &&
    [[testDefaults objectForKey:key] isEqual:before], @"Stale revisions preserve the complete model catalog");
  Check(SaveModels(catalog, @"dsh", @[@{@"id":models[2], @"name":@"Wrong owner", @"supports_images":@NO}]) == nil &&
    [[testDefaults objectForKey:key] isEqual:before], @"Another provider cannot take an existing model identity");
  catalog = SaveModels(catalog, @"claude-code", @[]);
  Check(catalog != nil && [ProviderRow(catalog,@"claude-code")[@"retired_models"] count] == 1 &&
    [DSHHarnessIdForModel(models[1]) isEqual:@"claude-code"] && !DSHHarnessModelIsExecutable(models[1]) && DSHDshModelSupportsImages(models[1]),
    @"Removing a model retires execution without erasing historical ownership or attachment metadata");
  Check([DSHProviderModelRows(NO) count] == 3 && [DSHProviderModelRows(YES) count] == 4,
    @"Selectable and historical catalog projections remain distinct");
  [testDefaults removeObjectForKey:key];
  NSDictionary *legacy = @{@"schema_version":@1, @"models":@[@{@"id":@"legacy-manual", @"name":@"原有模型", @"supports_images":@NO}], @"retired_models":@[]};
  [testDefaults setObject:legacy forKey:@"rish.dsh-models.v1"];
  catalog = DSHProviderModelCatalog();
  Check([ProviderRow(catalog,@"dsh")[@"models"] isEqual:legacy[@"models"]] &&
    [testDefaults objectForKey:key] == nil && [[testDefaults objectForKey:@"rish.dsh-models.v1"] isEqual:legacy],
    @"Explicit old DSH model choices migrate as a read view without rewriting the legacy record");
  [testDefaults removeObjectForKey:@"rish.dsh-models.v1"];
  [testDefaults removeObjectForKey:key];
}
