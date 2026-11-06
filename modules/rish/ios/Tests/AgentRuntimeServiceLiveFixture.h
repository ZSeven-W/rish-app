#import <Foundation/Foundation.h>
#import "RuntimeEnvironmentStore.h"
#include <sys/stat.h>

// Bounded release-manifest validation shared only by the new service gate.
// Nothing here imports, downloads, boots or rewrites a published package.
static inline NSArray<NSString *> *DSHServiceLiveFamilies(void) {
  return @[@"python", @"java", @"go", @"rust", @"bun", @"node"];
}
static inline BOOL DSHServiceLiveExactKeys(id value, NSArray<NSString *> *keys) {
  return [value isKindOfClass:NSDictionary.class] && [value count] == keys.count &&
      [[NSSet setWithArray:[value allKeys]] isEqualToSet:[NSSet setWithArray:keys]];
}
static inline BOOL DSHServiceLiveError(NSError **error, NSString *reason) {
  if (error) *error = [NSError errorWithDomain:@"RishRuntimeServiceLiveFixture" code:1
      userInfo:@{NSLocalizedDescriptionKey:reason}];
  return NO;
}
static inline NSDictionary *DSHServiceLivePackages(NSURL *directory, NSError **error) {
  struct stat status = {};
  if (!directory.isFileURL || lstat(directory.fileSystemRepresentation, &status) != 0 ||
      !S_ISDIR(status.st_mode) || S_ISLNK(status.st_mode)) {
    DSHServiceLiveError(error, @"An existing real fixture directory is required."); return nil;
  }
  NSData *data = DSHEnvironmentReadSmallFile([directory URLByAppendingPathComponent:@"fixture.json"], 65536);
  id manifest = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:error] : nil;
  if (!DSHServiceLiveExactKeys(manifest, @[@"schema_version", @"packages"]) ||
      ![manifest[@"schema_version"] isKindOfClass:NSNumber.class] ||
      CFGetTypeID((__bridge CFTypeRef)manifest[@"schema_version"]) == CFBooleanGetTypeID() ||
      ![manifest[@"schema_version"] isEqual:@1] ||
      ![manifest[@"packages"] isKindOfClass:NSArray.class] || [manifest[@"packages"] count] != 6) {
    DSHServiceLiveError(error, @"fixture.json must contain exactly the six published language records."); return nil;
  }
  NSMutableDictionary *packages = [NSMutableDictionary dictionary];
  NSMutableSet *ids = [NSMutableSet set], *files = [NSMutableSet set];
  for (NSDictionary *record in manifest[@"packages"]) {
    if (!DSHServiceLiveExactKeys(record, @[@"family", @"file", @"environment_id", @"package_sha256", @"package_bytes"])) {
      DSHServiceLiveError(error, @"Unexpected package fixture fields."); return nil;
    }
    NSString *family = record[@"family"], *file = record[@"file"], *digest = record[@"package_sha256"];
    NSNumber *size = record[@"package_bytes"];
    BOOL valid = [DSHServiceLiveFamilies() containsObject:family] && !packages[family] &&
        [file isKindOfClass:NSString.class] && [file rangeOfString:@"^[A-Za-z0-9][A-Za-z0-9._-]{0,159}\\.rishenv$"
            options:NSRegularExpressionSearch].location == 0 &&
        [file rangeOfString:@"^[A-Za-z0-9][A-Za-z0-9._-]{0,159}\\.rishenv$"
            options:NSRegularExpressionSearch].length == file.length &&
        DSHEnvironmentValidId(record[@"environment_id"]) && ![ids containsObject:record[@"environment_id"]] &&
        ![files containsObject:file] && [digest isKindOfClass:NSString.class] && digest.length == 64 &&
        [digest rangeOfString:@"^[0-9a-f]{64}$" options:NSRegularExpressionSearch].location == 0 &&
        [size isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)size) != CFBooleanGetTypeID() &&
        size.unsignedLongLongValue > 0 && size.unsignedLongLongValue <= 768ULL * 1024 * 1024 &&
        size.doubleValue == (double)size.unsignedLongLongValue;
    if (!valid) { DSHServiceLiveError(error, @"Malformed, duplicate or unbounded package record."); return nil; }
    [ids addObject:record[@"environment_id"]]; [files addObject:file]; packages[family] = record;
  }
  BOOL diagnostic = [NSProcessInfo.processInfo.environment[@"RISH_RUNTIME_SERVICES_DIAGNOSTIC_FIXTURE"] isEqual:@"1"];
  if (!diagnostic) {
    NSURL *catalogURL = [NSBundle.mainBundle URLForResource:@"RuntimeEnvironmentCatalog" withExtension:@"json"];
    NSData *catalogData = catalogURL ? DSHEnvironmentReadSmallFile(catalogURL, 1024 * 1024) : nil;
    NSDictionary *catalog = catalogData ? [NSJSONSerialization JSONObjectWithData:catalogData options:0 error:nil] : nil;
    NSArray *current = [catalog isKindOfClass:NSDictionary.class] ? catalog[@"environments"] : nil;
    if (![current isKindOfClass:NSArray.class] || current.count != 6) {
      DSHServiceLiveError(error, @"The app's pinned runtime catalog is missing or invalid."); return nil;
    }
    NSMutableSet *checked = [NSMutableSet set];
    for (NSDictionary *record in current) {
      NSDictionary *manifest = [record isKindOfClass:NSDictionary.class] ? record[@"manifest"] : nil;
      NSString *family = [manifest isKindOfClass:NSDictionary.class] ? manifest[@"family"] : nil;
      NSDictionary *fixture = [family isKindOfClass:NSString.class] ? packages[family] : nil;
      if (!fixture || [checked containsObject:family] ||
          ![fixture[@"environment_id"] isEqual:manifest[@"environment_id"]] ||
          ![fixture[@"package_sha256"] isEqual:record[@"package_sha256"]] ||
          ![fixture[@"package_bytes"] isEqual:record[@"package_bytes"]]) {
        DSHServiceLiveError(error, @"Fixture differs from the runtime catalog shipped in the app."); return nil;
      }
      [checked addObject:family];
    }
  } else {
    NSLog(@"RISH_RUNTIME_DIAGNOSTIC_FIXTURE: candidate/legacy package; not current release acceptance");
  }
  return packages;
}
static inline BOOL DSHServiceLiveVerifyPackage(NSURL *url, NSDictionary *record, NSError **error) {
  struct stat status = {};
  return (lstat(url.fileSystemRepresentation, &status) == 0 && S_ISREG(status.st_mode) &&
      !S_ISLNK(status.st_mode) && (uint64_t)status.st_size == [record[@"package_bytes"] unsignedLongLongValue] &&
      [DSHEnvironmentHashFile(url, (uint64_t)status.st_size, nil) isEqual:record[@"package_sha256"]]) ||
      DSHServiceLiveError(error, @"Published package size/digest changed or package is missing.");
}
