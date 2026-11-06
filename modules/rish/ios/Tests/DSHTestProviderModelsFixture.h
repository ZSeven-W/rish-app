// Explicit model metadata for positive native execution tests. Production has
// no default choices; each suite opts in to exactly the model IDs it exercises.
#pragma once
#import <XCTest/XCTest.h>
#import "RishHarnessCatalog.h"

static inline BOOL DSHInstallTestProviderModels(
    XCTestCase *testCase,
    NSDictionary<NSString *, NSArray<NSString *> *> *modelsByHarness,
    NSSet<NSString *> *imageModels) {
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  NSString *key = @"RishProviderModelsV1";
  id previous = [defaults objectForKey:key];
  // Register cleanup before writing, so failures and skipped tests also
  // restore the exact prior metadata (including an absent preference).
  [testCase addTeardownBlock:^{
    @synchronized(defaults) {
      if (previous != nil) [defaults setObject:previous forKey:key];
      else [defaults removeObjectForKey:key];
    }
  }];
  NSMutableArray *providers = [NSMutableArray array];
  for (NSString *harness in @[@"dsh", @"claude-code", @"codex", @"glm"]) {
    NSMutableArray *models = [NSMutableArray array];
    for (NSString *identifier in modelsByHarness[harness] ?: @[]) {
      [models addObject:@{@"id":identifier, @"name":identifier,
          @"supports_images":@([imageModels containsObject:identifier])}];
    }
    [providers addObject:@{@"harness_id":harness, @"models":models,
        @"retired_models":@[]}];
  }
  @synchronized(defaults) {
    [defaults setObject:@{@"schema_version":@1, @"revision":@0,
        @"providers":providers} forKey:key];
    NSDictionary *read = DSHProviderModelCatalog();
    if (read == nil) return NO;
    for (NSArray *identifiers in modelsByHarness.allValues)
      for (NSString *identifier in identifiers)
        if (!DSHProviderModelIsActive(identifier)) return NO;
  }
  return YES;
}
