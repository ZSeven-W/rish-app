#import "AgentPolicyService.h"

#import "AgentNativeWAL.h"
#import "AgentRootResolver.h"
#import "AgentToolRegistry.h"
#import "SessionWorkspaceCoordinator.h"

#include "rish_agent_core.h"

NSErrorDomain const DSHAgentPolicyErrorDomain = @"tech.zseven.rish.agent-policy";
static const NSUInteger DSHPolicyMaximumSafeInteger = 9007199254740991ULL;

static NSError *DSHPolicyError(NSString *code) {
  NSDictionary *messages = @{
    @"E_AGENT_BAD_ARGUMENTS": @"Agent policy request is invalid.",
    @"E_AGENT_ROOT_STALE": @"The workspace binding is no longer current.",
    @"E_AGENT_NATIVE": @"Agent policy is unavailable.",
  };
  if (![code isKindOfClass:NSString.class] || messages[code] == nil) code = @"E_AGENT_NATIVE";
  return [NSError errorWithDomain:DSHAgentPolicyErrorDomain code:1 userInfo:@{
    @"code": code, NSLocalizedDescriptionKey: messages[code],
  }];
}

static NSError *DSHPolicyMapRootError(NSError *error) {
  if ([error.domain isEqual:DSHAgentNativeStoreErrorDomain]) {
    if (error.code == DSHAgentNativeStoreErrorOwnerLost ||
        error.code == DSHAgentNativeStoreErrorNotFound ||
        error.code == DSHAgentNativeStoreErrorConflict) {
      return DSHPolicyError(@"E_AGENT_ROOT_STALE");
    }
  } else if ([error.domain isEqual:DSHLocalWorkspaceAccessErrorDomain]) {
    switch ((DSHLocalWorkspaceAccessErrorCode)error.code) {
      case DSHLocalWorkspaceAccessErrorNotFound:
      case DSHLocalWorkspaceAccessErrorRevisionStale:
      case DSHLocalWorkspaceAccessErrorRootChanged:
      case DSHLocalWorkspaceAccessErrorStatusStale:
      case DSHLocalWorkspaceAccessErrorRevoked:
      case DSHLocalWorkspaceAccessErrorNotDownloaded:
        return DSHPolicyError(@"E_AGENT_ROOT_STALE");
      default: break;
    }
  }
  return DSHPolicyError(@"E_AGENT_NATIVE");
}

// The describe result is a *safe* projection: it is handed to the the UI
// layer and shown in the UI, so what matters is not what it contains but what
// it must never contain — a filesystem path, the native descriptor table, tool
// arguments, or anything that could be mistaken for an authority handle. Its
// keys are enumerated in the shared core (modules/rish/core,
// `rish_agent_policy_reduce`) rather than copied from the inputs, and an
// accidental extra key is a leak.
static NSDictionary *DSHPolicyReduce(NSString *op, NSDictionary *fields) {
  NSMutableDictionary *envelope = [fields mutableCopy];
  envelope[@"op"] = op;
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:envelope options:0
                                                    error:nil];
  char *raw = bytes == nil ? NULL : rish_agent_policy_reduce(
      (const char *)bytes.bytes, bytes.length);
  if (raw == NULL) return nil;
  NSData *replyBytes = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  id reply = [NSJSONSerialization JSONObjectWithData:replyBytes options:0
                                                error:nil];
  return [reply isKindOfClass:NSDictionary.class] &&
      [reply[@"ok"] isEqual:@YES] ? reply : nil;
}

static BOOL DSHPolicyValidRequest(id request) {
  if (![request isKindOfClass:NSDictionary.class]) return NO;
  return [DSHPolicyReduce(@"request_shape",
                          @{ @"request" : request })[@"valid"] isEqual:@YES];
}

static BOOL DSHPolicyValidBudget(NSDictionary *policy) {
  if (![policy isKindOfClass:NSDictionary.class]) return NO;
  return [DSHPolicyReduce(@"budget_shape",
                          @{ @"policy" : policy })[@"valid"] isEqual:@YES];
}

@interface DSHAgentPolicyService ()
@property(nonatomic, strong) DSHAgentRootResolver *rootResolver;
@property(nonatomic, strong) DSHAgentToolRegistry *registry;
@property(nonatomic, strong) DSHSessionWorkspaceCoordinator *coordinator;
@end

@implementation DSHAgentPolicyService

- (instancetype)initWithRootResolver:(DSHAgentRootResolver *)rootResolver
                            registry:(DSHAgentToolRegistry *)registry
                         coordinator:(DSHSessionWorkspaceCoordinator *)coordinator {
  self = [super init];
  if (self) {
    _rootResolver = rootResolver;
    _registry = registry;
    _coordinator = coordinator;
  }
  return self;
}

- (NSDictionary *)describeRequest:(id)request error:(NSError **)error {
  if (error != nullptr) *error = nil;
  if (self.rootResolver == nil || self.registry == nil || self.coordinator == nil) {
    if (error != nullptr) *error = DSHPolicyError(@"E_AGENT_NATIVE");
    return nil;
  }
  __block NSDictionary *result = nil;
  NSError *transactionError = nil;
  BOOL completed = [self.coordinator performSyncWithError:^BOOL(NSError **inner) {
    if (!DSHPolicyValidRequest(request)) {
      *inner = DSHPolicyError(@"E_AGENT_BAD_ARGUMENTS");
      return NO;
    }
    NSDictionary *identity = DSHAgentImmutableJSONCopy(request, nil);
    if (identity == nil) {
      *inner = DSHPolicyError(@"E_AGENT_BAD_ARGUMENTS");
      return NO;
    }
    NSError *nativeError = nil;
    NSDictionary *root = [self.rootResolver
        resolveRootForWorkspaceId:identity[@"workspace_id"]
        projectId:identity[@"project_id"] == NSNull.null ? nil : identity[@"project_id"]
        bindingRevision:identity[@"workspace_binding_revision"] error:&nativeError];
    if (root == nil) {
      *inner = DSHPolicyMapRootError(nativeError);
      return NO;
    }
    // A resolver that answered for a different workspace, revision or project
    // answered a different question, and the display would be about something
    // else.
    if (![DSHAgentRootResolver validateAgentRootProjection:root error:nil] ||
        ![DSHPolicyReduce(@"root_matches_request", @{
            @"root" : root, @"request" : identity,
          })[@"matches"] isEqual:@YES]) {
      *inner = DSHPolicyError(@"E_AGENT_ROOT_STALE");
      return NO;
    }
    NSDictionary *registry = [self.registry registryForRoot:root error:&nativeError];
    NSDictionary *policy = [self.registry policyForRoot:root error:&nativeError];
    if (![DSHAgentToolRegistry validateRegistryProjection:registry root:root error:nil] ||
        !DSHPolicyValidBudget(policy)) {
      *inner = DSHPolicyError(@"E_AGENT_NATIVE");
      return NO;
    }
    if (![self.rootResolver validateFrozenRoot:root error:&nativeError]) {
      *inner = DSHPolicyMapRootError(nativeError);
      return NO;
    }
    result = DSHPolicyReduce(@"projection", @{
      @"request" : identity, @"root" : root,
      @"registry" : registry, @"policy" : policy,
    })[@"result"];
    if (result == nil) {
      *inner = DSHPolicyError(@"E_AGENT_NATIVE");
      return NO;
    }
    return YES;
  } error:&transactionError];
  if (!completed || result == nil) {
    if (error != nullptr) {
      // The coordinator also contains native exceptions. Its NSError and any
      // underlying paths/exception text are intentionally discarded here.
      *error = [transactionError.domain isEqual:DSHAgentPolicyErrorDomain]
          ? DSHPolicyError(transactionError.userInfo[@"code"])
          : DSHPolicyError(@"E_AGENT_NATIVE");
    }
    return nil;
  }
  return result;
}

@end
