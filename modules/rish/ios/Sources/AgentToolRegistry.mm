#import "RishGuestCgiFeature.h"
#import "AgentToolRegistry.h"

#import "AgentNativeWAL.h"
#import "AgentRootResolver.h"
#include "rish_agent_core.h"

// The tool table, the registry a root implies, the write policy and the
// toolset digest all live in the shared core (modules/rish/core,
// `rish_agent_tool_registry_reduce`). The table is a pure table, and the
// digest taken over it is what every stored authority is bound to, so there
// is exactly one copy of it. What stays here is the one build fact the core
// cannot know: whether this binary has the guest CGI tools compiled in.
#if DSH_GUEST_CGI_AVAILABLE
static const BOOL DSHAgentGuestCGIAvailable = YES;
#else
static const BOOL DSHAgentGuestCGIAvailable = NO;
#endif

static NSDictionary *DSHAgentRegistryReduce(NSString *op,
                                            NSDictionary *fields,
                                            NSError **error) {
  NSMutableDictionary *envelope = [fields mutableCopy];
  envelope[@"op"] = op;
  if (!envelope[@"registry_version"]) envelope[@"registry_version"] = @4; // Runtime and durable question adapters.
  envelope[@"guest_cgi"] = @(DSHAgentGuestCGIAvailable);
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:envelope options:0 error:nil];
  if (bytes == nil) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  char *raw = rish_agent_tool_registry_reduce((const char *)bytes.bytes, bytes.length);
  if (raw == NULL) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  size_t length = strnlen(raw, 1024 * 1024 + 1);
  NSData *replyBytes = length <= 1024 * 1024 ? [NSData dataWithBytes:raw length:length] : nil;
  rish_agent_string_free(raw);
  id reply = replyBytes ? [NSJSONSerialization JSONObjectWithData:replyBytes options:0 error:nil] : nil;
  if (![reply isKindOfClass:NSDictionary.class]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  if (![reply[@"ok"] isEqual:@YES]) {
    NSInteger code = [reply[@"error"] isKindOfClass:NSNumber.class]
        ? [reply[@"error"] integerValue] : 0;
    if (code < DSHAgentNativeStoreErrorInvalidArgument ||
        code > DSHAgentNativeStoreErrorPersistence) {
      code = DSHAgentNativeStoreErrorCorrupt;
    }
    DSHSetAgentNativeStoreError(error, (DSHAgentNativeStoreErrorCode)code);
    return nil;
  }
  return reply;
}

@interface DSHAgentToolRegistry ()
@property(nonatomic, copy, readwrite) NSString *toolsetSHA256;
@end

@implementation DSHAgentToolRegistry

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    NSDictionary *reply = DSHAgentRegistryReduce(@"toolset_sha256", @{}, nullptr);
    id digest = reply[@"toolset_sha256"];
    _toolsetSHA256 = [digest isKindOfClass:NSString.class] ? digest : @"";
  }
  return self;
}

- (nullable NSDictionary *)registryForRoot:(NSDictionary *)root
                                     error:(NSError **)error {
  if (![DSHAgentRootResolver validateAgentRootProjection:root error:error]) return nil;
  return DSHAgentRegistryReduce(@"registry", @{ @"root" : root }, error)[@"registry"];
}

- (nullable NSDictionary *)registryForRoot:(NSDictionary *)root
                                  version:(NSNumber *)version
                                    error:(NSError **)error {
  if (![DSHAgentRootResolver validateAgentRootProjection:root error:error]) return nil;
  return DSHAgentRegistryReduce(@"registry", @{@"root":root,
    @"registry_version":version ?: NSNull.null}, error)[@"registry"];
}

- (nullable NSDictionary *)policyForRoot:(NSDictionary *)root
                                    error:(NSError **)error {
  if (![DSHAgentRootResolver validateAgentRootProjection:root error:error]) return nil;
  return DSHAgentRegistryReduce(@"policy", @{ @"root" : root }, error)[@"policy"];
}

- (nullable NSDictionary *)descriptorForToolName:(NSString *)name
                                             root:(NSDictionary *)root
                                            error:(NSError **)error {
  if (![DSHAgentRootResolver validateAgentRootProjection:root error:error]) return nil;
  return DSHAgentRegistryReduce(@"descriptor", @{
    @"name" : name ?: @"", @"root" : root,
  }, error)[@"descriptor"];
}

- (nullable NSDictionary *)nativeDescriptorForToolName:(NSString *)name
                                                 error:(NSError **)error {
  return DSHAgentRegistryReduce(@"native_descriptor", @{
    @"name" : name ?: @"",
  }, error)[@"descriptor"];
}

- (nullable NSDictionary *)descriptorForToolName:(NSString *)name
                                             root:(NSDictionary *)root
                                         registry:(NSDictionary *)registry
                                            error:(NSError **)error {
  if (![DSHAgentRootResolver validateAgentRootProjection:root error:error] ||
      ![registry isKindOfClass:NSDictionary.class] || registry[@"registry_version"] == nil ||
      !DSHAgentCanonicalSHA256(registry[@"toolset_sha256"])) {
    if (error && *error == nil) DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  return DSHAgentRegistryReduce(@"frozen_descriptor", @{
    @"name":name ?: @"", @"root":root, @"registry":registry,
  }, error)[@"descriptor"];
}

- (nullable NSDictionary *)nativeDescriptorForToolName:(NSString *)name
                                             registry:(NSDictionary *)registry
                                                error:(NSError **)error {
  if (![registry isKindOfClass:NSDictionary.class] || registry[@"registry_version"] == nil ||
      !DSHAgentCanonicalSHA256(registry[@"toolset_sha256"])) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  return DSHAgentRegistryReduce(@"native_descriptor", @{
    @"name":name ?: @"", @"registry_version":registry[@"registry_version"],
    @"toolset_sha256":registry[@"toolset_sha256"],
  }, error)[@"descriptor"];
}

- (BOOL)validateToolsetSHA256:(NSString *)toolsetSHA256 error:(NSError **)error {
  NSDictionary *reply = DSHAgentRegistryReduce(@"toolset_valid", @{
    @"toolset_sha256":toolsetSHA256 ?: NSNull.null,
  }, nullptr);
  if (![reply[@"valid"] isEqual:@YES]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorConflict);
    return NO;
  }
  return YES;
}

+ (BOOL)validateRegistryProjection:(NSDictionary *)registry
                               root:(NSDictionary *)root
                              error:(NSError **)error {
  if (!DSHAgentIsImmutableFoundationJSON(registry) ||
      ![DSHAgentRootResolver validateAgentRootProjection:root error:error]) {
    if (error != nullptr && *error == nil) {
      DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    }
    return NO;
  }
  NSDictionary *reply = DSHAgentRegistryReduce(@"registry_shape", @{
    @"registry" : registry, @"root" : root,
  }, error);
  if (![reply[@"valid"] isEqual:@YES]) {
    if (error != nullptr && *error == nil) {
      DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    }
    return NO;
  }
  // The core checks the exact descriptor-table digest for the recorded
  // registry version, including historical v1/v2 build variants.
  return YES;
}

@end
