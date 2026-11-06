#import "ProviderConfiguration.h"
#import "AgentProviderRoundServiceInternals.h"
#import "RishHarnessCatalog.h"

#import "AgentToolRegistry.h"
#import "DSHCompletionV2.h"
#import "DSHWorkspaceCanonical.h"

#include "rish_agent_core.h"

#include <CoreFoundation/CoreFoundation.h>
#include <math.h>

// The pure half of this file lives in the shared core (modules/rish/core,
// `rish_agent_provider_round_reduce`): request and result shapes, the
// controller CAS and checkpoint relations, the locator and ledger CAS, the
// native-to-provider message conversion, the public receipt, the recovered
// round projection, the project-context bundle, the failure-code mapping,
// the selector requests and the tool descriptions. This side keeps the
// transport, credentials, the registry's native descriptors, the root
// projection validator, and the two provider digests — those use
// NSJSONSerialization with sorted keys, a different byte protocol from the
// core's canonical JSON, so they are computed here and passed in as facts.

void DSHSetProviderError(NSError **error,
                                DSHAgentNativeStoreErrorCode code) {
  if (error != nullptr) *error = DSHAgentNativeStoreError(code);
}

BOOL DSHProviderUUID(id value) { return DSHAgentCanonicalUUID(value); }
BOOL DSHProviderDigest(id value) { return DSHAgentCanonicalSHA256(value); }

static id DSHProviderValue(id value) {
  return value ?: NSNull.null;
}

// Catalogue and provider-binding answers for one parsed tree, the host facts
// the core's shapes need. Mirrors the session store's environment builder.
static NSString *DSHProviderBindingKey(id binding, id model) {
  NSData *canonical = DSHWorkspaceCanonicalJSONData(
      @{ @"binding" : DSHProviderValue(binding), @"model" : DSHProviderValue(model) }, nil);
  return canonical == nil ? nil : DSHWorkspaceSHA256Hex(canonical);
}

static void DSHProviderCollectFacts(id node,
                                    NSMutableSet<NSString *> *strings,
                                    NSMutableArray<NSDictionary *> *bindings,
                                    NSMutableSet<NSString *> *keys) {
  if ([node isKindOfClass:NSString.class]) {
    [strings addObject:node];
    return;
  }
  if ([node isKindOfClass:NSArray.class]) {
    for (id child in (NSArray *)node) {
      DSHProviderCollectFacts(child, strings, bindings, keys);
    }
    return;
  }
  if (![node isKindOfClass:NSDictionary.class]) return;
  NSDictionary *record = node;
  id binding = record[@"provider_configuration"];
  if (binding != nil) {
    id model = record[@"model"];
    NSString *key = DSHProviderBindingKey(binding, model);
    if (key != nil && ![keys containsObject:key]) {
      [keys addObject:key];
      BOOL valid = [binding isKindOfClass:NSDictionary.class] &&
          DSHValidateProviderBinding(binding, model);
      NSString *host = nil;
      if (valid && [((NSDictionary *)binding)[@"endpoint_url"] isKindOfClass:NSString.class]) {
        host = [NSURL URLWithString:((NSDictionary *)binding)[@"endpoint_url"]].host;
      }
      [bindings addObject:@{
        @"canonical_sha256" : key,
        @"valid" : @(valid),
        @"host" : DSHProviderValue(host),
      }];
    }
  }
  for (id child in record.allValues) {
    DSHProviderCollectFacts(child, strings, bindings, keys);
  }
}

static NSDictionary *DSHProviderEnvironment(id root) {
  NSMutableSet<NSString *> *strings = [NSMutableSet set];
  NSMutableArray<NSDictionary *> *bindings = [NSMutableArray array];
  NSMutableSet<NSString *> *keys = [NSMutableSet set];
  DSHProviderCollectFacts(root, strings, bindings, keys);
  NSMutableArray<NSString *> *models = [NSMutableArray array];
  NSMutableDictionary<NSString *, NSString *> *harnessByModel =
      [NSMutableDictionary dictionary];
  NSMutableDictionary<NSString *, NSString *> *hostByModel =
      [NSMutableDictionary dictionary];
  NSMutableArray<NSString *> *providers = [NSMutableArray array];
  for (NSString *string in strings) {
    if (DSHHarnessIsSupportedModel(string)) {
      [models addObject:string];
      NSString *harness = DSHHarnessIdForModel(string);
      if (harness != nil) harnessByModel[string] = harness;
      NSString *host = DSHProviderHostForModel(string);
      if (host != nil) hostByModel[string] = host;
    }
    if (DSHHarnessIsProviderId(string)) [providers addObject:string];
  }
  [models sortUsingSelector:@selector(compare:)];
  [providers sortUsingSelector:@selector(compare:)];
  [bindings sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
    return [a[@"canonical_sha256"] compare:b[@"canonical_sha256"]];
  }];
  return @{
    @"supported_models" : [models copy],
    @"harness_by_model" : [harnessByModel copy],
    @"provider_ids" : [providers copy],
    @"host_by_model" : [hostByModel copy],
    @"provider_bindings" : [bindings copy],
  };
}

static NSDictionary *DSHProviderReduce(NSString *op,
                                       NSDictionary *fields,
                                       NSError **error) {
  NSMutableDictionary *envelope = [fields mutableCopy];
  envelope[@"op"] = op;
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:envelope options:0 error:nil];
  if (bytes == nil) {
    DSHSetProviderError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  char *raw = rish_agent_provider_round_reduce((const char *)bytes.bytes, bytes.length);
  if (raw == NULL) {
    DSHSetProviderError(error, DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  NSData *replyBytes = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  id reply = [NSJSONSerialization JSONObjectWithData:replyBytes options:0 error:nil];
  if (![reply isKindOfClass:NSDictionary.class]) {
    DSHSetProviderError(error, DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  if (![reply[@"ok"] isEqual:@YES]) {
    NSInteger code = [reply[@"error"] isKindOfClass:NSNumber.class]
        ? [reply[@"error"] integerValue] : DSHAgentNativeStoreErrorCorrupt;
    if (code < DSHAgentNativeStoreErrorInvalidArgument ||
        code > DSHAgentNativeStoreErrorPersistence) {
      code = DSHAgentNativeStoreErrorCorrupt;
    }
    DSHSetProviderError(error, (DSHAgentNativeStoreErrorCode)code);
    return nil;
  }
  return reply;
}

NSArray *DSHProviderAssistantContextMessages(NSDictionary *authority, NSError **error) {
  NSDictionary *reply = DSHProviderReduce(@"assistant_context_messages",
      @{@"authority":authority}, error);
  return [reply[@"messages"] isKindOfClass:NSArray.class] ? reply[@"messages"] : nil;
}

NSString *DSHProviderJSONSHA256(id value, NSError **error) {
  // The provider input digest is NOT this project's canonical JSON: it is
  // NSJSONSerialization with sorted keys, and the request body digest binds
  // the exact bytes that were sent. Both stay native.
  if (value == nil || ![NSJSONSerialization isValidJSONObject:value]) {
    DSHSetProviderError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:value
                                                    options:NSJSONWritingSortedKeys
                                                      error:error];
  return bytes == nil ? nil : DSHWorkspaceSHA256Hex(bytes);
}

// Opaque identifiers are checked inside every shape the core owns; this
// standalone predicate has no request context, so it stays native.
BOOL DSHProviderOpaqueId(id value) {
  if (!DSHAgentBoundedUTF8String(value, 128, NO, nullptr)) return NO;
  NSCharacterSet *invalid = [[NSCharacterSet
      characterSetWithCharactersInString:
          @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-"]
      invertedSet];
  return [value rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

BOOL DSHProviderResultShape(NSDictionary *result) {
  if (![result isKindOfClass:NSDictionary.class]) return NO;
  NSDictionary *reply = DSHProviderReduce(@"result_only_shape", @{
    @"result" : result, @"request" : @{}, @"env" : DSHProviderEnvironment(result),
  }, nullptr);
  return reply != nil && [reply[@"matches"] isEqual:@YES];
}

BOOL DSHProviderResultMatchesRequest(NSDictionary *result,
                                     NSDictionary *request,
                                     NSString *providerRequestId) {
  if (![result isKindOfClass:NSDictionary.class] ||
      ![request isKindOfClass:NSDictionary.class]) return NO;
  NSDictionary *reply = DSHProviderReduce(@"result_shape", @{
    @"result" : result,
    @"request" : request,
    @"provider_request_id" : DSHProviderValue(providerRequestId),
    @"env" : DSHProviderEnvironment(result),
  }, nullptr);
  return reply != nil && [reply[@"matches"] isEqual:@YES];
}

NSDictionary *DSHProviderConflictResult(NSString *operationId,
                                               NSString *failureCode,
                                               NSDictionary *request,
                                               NSNumber *actualRoundRevision,
                                               NSString *actualRoundStatus,
                                               NSDictionary *actualTranscript) {
  NSDictionary *reply = DSHProviderReduce(@"conflict", @{
    @"operation_id" : DSHProviderValue(operationId),
    @"failure_code" : failureCode,
    @"request" : request,
    @"actual_round_revision" : DSHProviderValue(actualRoundRevision),
    @"actual_round_status" : DSHProviderValue(actualRoundStatus),
    @"actual_transcript" : DSHProviderValue(actualTranscript),
  }, nullptr);
  return reply[@"result"];
}

NSDictionary *DSHProviderRoundRequestCopy(NSDictionary *request,
                                                 NSError **error) {
  NSError *copyError = nil;
  NSDictionary *copy = DSHAgentImmutableJSONCopy(request, &copyError);
  BOOL rootOK = [copy[@"root"] isKindOfClass:NSDictionary.class] &&
      [DSHAgentRootResolver validateAgentRootProjection:copy[@"root"]
                                                  error:&copyError];
  if (copy == nil ||
      DSHProviderReduce(@"round_request", @{
        @"request" : copy, @"root_ok" : @(rootOK),
        @"env" : DSHProviderEnvironment(copy),
      }, nullptr) == nil) {
    if (error != nullptr) *error = DSHAgentNativeStoreError(
        DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  return copy;
}

NSDictionary *DSHProviderRoundLocator(NSDictionary *request) {
  return @{
    @"schema_version" : @1,
    @"task_id" : request[@"task_id"],
    @"attempt_id" : request[@"attempt_id"],
    @"round_id" : request[@"round_id"],
    @"round_index" : request[@"round_index"],
  };
}

NSDictionary *DSHProviderOwner(DSHAgentNativeWAL *wal,
                                      NSString *taskId,
                                      NSString *nativeTaskId) {
  return @{
    @"schema_version" : @1,
    @"task_id" : taskId,
    @"launch_id" : wal.launchId,
    @"native_task_id" : nativeTaskId,
    @"owner_generation" : @1,
    @"heartbeat_at" : wal.currentTimestamp,
  };
}

NSDictionary *DSHProviderRoundCASForRow(NSDictionary *row) {
  NSDictionary *reply = DSHProviderReduce(@"round_cas", @{ @"row" : row }, nullptr);
  return reply[@"cas"];
}

NSDictionary *DSHProviderNativeToCompletionMessage(NSDictionary *message,
                                                          NSError **error) {
  if (![message isKindOfClass:NSDictionary.class]) return nil;
  NSDictionary *reply = DSHProviderReduce(@"assistant_message", @{
    @"message" : message,
  }, error);
  id converted = reply[@"message"];
  return [converted isKindOfClass:NSDictionary.class] ? converted : nil;
}

NSDictionary *DSHProviderPublicReceipt(NSDictionary *provider,
                                              NSDictionary *request,
                                              NSString *providerRequestId,
                                              NSDictionary *contextReceipt) {
  NSDictionary *reply = DSHProviderReduce(@"public_receipt", @{
    @"provider" : provider,
    @"request" : request,
    @"provider_request_id" : DSHProviderValue(providerRequestId),
    @"context_receipt" : DSHProviderValue(contextReceipt),
  }, nullptr);
  return reply[@"receipt"];
}

NSDictionary *DSHProviderRecoveredRoundProjection(NSDictionary *row,
                                                    NSDictionary *request,
                                                    NSArray *nativeMessages,
                                                    NSError **error) {
  if (![row isKindOfClass:NSDictionary.class] ||
      ![request isKindOfClass:NSDictionary.class] ||
      ![nativeMessages isKindOfClass:NSArray.class]) {
    DSHSetProviderError(error, DSHAgentNativeStoreErrorConflict);
    return nil;
  }
  NSDictionary *reply = DSHProviderReduce(@"recovered_projection", @{
    @"row" : row, @"request" : request, @"messages" : nativeMessages,
  }, error);
  return reply[@"projection"];
}

BOOL DSHProviderContextBundle(NSDictionary *bundle,
                                     NSString *expectedContextDigest,
                                     NSDictionary **receiptOut,
                                     NSArray **messagesOut,
                                     NSError **error) {
  if (bundle == nil && error != nullptr && *error != nil) return NO;
  NSDictionary *reply = DSHProviderReduce(@"context_bundle", @{
    @"bundle" : DSHProviderValue(bundle),
    @"expected_digest" : DSHProviderValue(expectedContextDigest),
  }, error);
  if (reply == nil) return NO;
  if (![reply[@"receipt"] isKindOfClass:NSDictionary.class] ||
      ![reply[@"messages"] isKindOfClass:NSArray.class]) {
    DSHSetProviderError(error, DSHAgentNativeStoreErrorCorrupt);
    return NO;
  }
  if (receiptOut != nullptr) *receiptOut = reply[@"receipt"];
  if (messagesOut != nullptr) *messagesOut = reply[@"messages"];
  return YES;
}

NSDictionary *DSHProviderUnknownResult(NSDictionary *request,
                                              NSString *status,
                                              NSUInteger revision,
                                              NSString *failureCode) {
  NSDictionary *reply = DSHProviderReduce(@"unknown_result", @{
    @"request" : request, @"status" : status, @"revision" : @(revision),
    @"failure_code" : failureCode,
  }, nullptr);
  return reply[@"result"];
}

NSString *DSHProviderFailureCode(NSString *providerErrorCode,
                                 BOOL digestMismatch) {
  NSDictionary *reply = DSHProviderReduce(@"failure_code", @{
    @"provider_error_code" : DSHProviderValue(providerErrorCode),
    @"digest_mismatch" : @(digestMismatch),
  }, nullptr);
  return reply[@"code"];
}

NSDictionary *DSHProviderOperationSafeResult(NSDictionary *result) {
  return @{
    @"schema_version" : @2,
    @"result_kind" : @"complete_agent_round_v2",
    @"result" : result,
  };
}

NSArray *DSHProviderToolsForAuthority(
    NSDictionary *authority,
    DSHAgentToolRegistry *registry,
    NSError **error) {
  NSMutableArray *raw = [NSMutableArray array];
  for (NSDictionary *safeTool in authority[@"registry"][@"tools"]) {
    NSDictionary *native = [registry nativeDescriptorForToolName:safeTool[@"name"]
                                                     registry:authority[@"registry"]
                                                        error:error];
    if (native == nil) return nil;
    // The description the model is shown is shared with Android; the registry
    // supplies the tool's native identity and parameters.
    NSDictionary *described = DSHProviderReduce(@"tool_description", @{
      @"name" : native[@"name"],
    }, nullptr);
    id description = described[@"description"];
    [raw addObject:@{
      @"type" : @"function",
      @"name" : native[@"name"],
      @"description" : [description isKindOfClass:NSString.class]
          ? description : native[@"safe_summary_key"],
      @"parameters" : native[@"parameters"],
    }];
  }
  return DSHCompletionToolsV2FromArray(raw, error);
}

NSArray *DSHProviderTranscriptForBody(NSArray *nativeMessages,
                                             NSUInteger roundIndex,
                                             NSString *thinkingMode,
                                             NSError **error) {
  if (![nativeMessages isKindOfClass:NSArray.class]) {
    DSHSetProviderError(error, DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  NSDictionary *reply = DSHProviderReduce(@"transcript_body", @{
    @"request" : @{}, @"messages" : nativeMessages,
  }, error);
  NSArray *provider = reply[@"messages"];
  if (![provider isKindOfClass:NSArray.class]) return nil;
  return DSHCompletionRoundTranscriptSchema2FromArray(provider,
                                                       (NSInteger)roundIndex,
                                                       thinkingMode,
                                                       error);
}


@implementation DSHAgentProviderRoundContext
@end

NSString *DSHProviderLocatorKey(NSDictionary *locator) {
  NSDictionary *reply = DSHProviderReduce(@"locator_key", @{
    @"request" : @{}, @"locator" : locator,
  }, nullptr);
  id key = reply[@"key"];
  return [key isKindOfClass:NSString.class] ? key : nil;
}

NSDictionary *DSHProviderStartedOperationCommit(NSDictionary *request,
                                                NSString *requestSHA,
                                                NSDictionary *row,
                                                NSString *status,
                                                NSString *failureCode) {
  NSMutableDictionary *fields = [@{
    @"request" : request ?: NSNull.null,
    @"request_sha256" : requestSHA ?: NSNull.null,
    @"status" : status ?: NSNull.null,
  } mutableCopy];
  if ([row isKindOfClass:NSDictionary.class]) fields[@"row"] = row;
  if (failureCode != nil) fields[@"failure_code"] = failureCode;
  return DSHProviderReduce(@"started_operation_commit", fields, nullptr)[@"commit"];
}

NSDictionary *DSHProviderPublicResult(NSDictionary *request, NSDictionary *row,
                                      NSDictionary *round) {
  return DSHProviderReduce(@"public_result", @{
    @"request" : request ?: NSNull.null, @"row" : row ?: NSNull.null,
    @"round" : round ?: NSNull.null,
  }, nullptr)[@"output"];
}

NSString *DSHProviderPresentationExcerpt(NSString *reasoning) {
  NSDictionary *reply = DSHProviderReduce(@"presentation_excerpt", @{
    @"text" : reasoning ?: @"",
  }, nullptr);
  // A rule that cannot answer leaves nothing to show rather than a value the
  // controller would refuse.
  return [reply[@"text"] isKindOfClass:NSString.class] ? reply[@"text"] : @"";
}

NSDictionary *DSHProviderRoundFailureCode(NSString *kind, NSString *state, id recorded) {
  return DSHProviderReduce(@"round_failure_code", @{
    @"kind" : kind ?: NSNull.null, @"state" : state ?: NSNull.null,
    @"recorded" : [recorded isKindOfClass:NSString.class] ? recorded : NSNull.null,
  }, nullptr);
}

NSDictionary *DSHProviderRoundResultForRow(NSDictionary *request,
                                                  NSDictionary *row,
                                                  NSString *status,
                                                  NSString *failureCode) {
  NSDictionary *reply = DSHProviderReduce(@"round_result", @{
    @"request" : request, @"row" : row, @"status" : status,
    @"failure_code" : DSHProviderValue(failureCode),
  }, nullptr);
  return reply[@"result"];
}

NSDictionary *DSHProviderQueryResultForRow(NSDictionary *request,
                                                  NSDictionary *row,
                                                  NSString *status,
                                                  NSString *failureCode) {
  NSDictionary *reply = DSHProviderReduce(@"query_result", @{
    @"request" : request, @"row" : row, @"status" : status,
    @"failure_code" : DSHProviderValue(failureCode),
  }, nullptr);
  return reply[@"result"];
}

NSDictionary *DSHProviderSelectorConflict(NSDictionary *request,
                                                 NSDictionary *row,
                                                 NSString *failureCode) {
  NSDictionary *reply = DSHProviderReduce(@"selector_conflict", @{
    @"request" : request, @"row" : row, @"failure_code" : failureCode,
  }, nullptr);
  return reply[@"result"];
}

BOOL DSHProviderSelectorRequest(NSDictionary *request,
                                       BOOL cancellation,
                                       BOOL allowZeroRevision,
                                       NSError **error) {
  if (![request isKindOfClass:NSDictionary.class]) {
    DSHSetProviderError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return NO;
  }
  NSError *rootError = nil;
  BOOL rootOK = [request[@"root"] isKindOfClass:NSDictionary.class] &&
      [DSHAgentRootResolver validateAgentRootProjection:request[@"root"]
                                                  error:&rootError];
  if (DSHProviderReduce(@"selector_request", @{
        @"request" : request, @"cancellation" : @(cancellation),
        @"allow_zero_revision" : @(allowZeroRevision), @"root_ok" : @(rootOK),
      }, nullptr) == nil) {
    if (error != nullptr && *error == nil) {
      *error = rootError ?: DSHAgentNativeStoreError(
          DSHAgentNativeStoreErrorInvalidArgument);
    }
    return NO;
  }
  return YES;
}

BOOL DSHProviderSelectorMatchesRow(NSDictionary *request,
                                          NSDictionary *row) {
  NSDictionary *reply = DSHProviderReduce(@"selector_matches", @{
    @"request" : request, @"row" : row,
  }, nullptr);
  return [reply[@"matches"] isEqual:@YES];
}

void DSHProviderFinishContext(DSHAgentProviderRoundContext *context,
                                     NSDictionary *result,
                                     NSString *errorCode) {
  if (context == nil) return;
  BOOL signal = NO;
  @synchronized (context) {
    if (!context.finished) {
      context.finished = YES;
      context.providerResult = [result copy];
      context.providerErrorCode = [errorCode copy];
      signal = YES;
    }
  }
  if (signal && context.semaphore != nil) {
    dispatch_semaphore_signal(context.semaphore);
  }
}
