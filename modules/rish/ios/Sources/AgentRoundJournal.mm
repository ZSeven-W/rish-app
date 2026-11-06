#import "ProviderConfiguration.h"
#import "AgentRoundJournal.h"
#import "RishHarnessCatalog.h"

#import "AgentTranscriptStore.h"

#include "rish_agent_core.h"

static NSArray<NSString *> *DSHAgentRoundLocatorKeys(void) {
  return @[
    @"schema_version", @"task_id", @"attempt_id", @"round_id",
    @"round_index",
  ];
}

static NSString *DSHAgentRoundDispatchState(NSArray *dispatchRows,
                                             NSDictionary *locator) {
  for (NSDictionary *entry in dispatchRows) {
    if ([entry[@"kind"] isEqualToString:@"round"] &&
        [entry[@"locator"] isEqual:locator]) {
      return entry[@"dispatch_state"];
    }
  }
  return nil;
}

static NSArray<NSString *> *DSHAgentRoundKeys(void) {
  return @[
    @"schema_version", @"locator", @"row_revision",
    @"root_fingerprint_sha256", @"binding_revision", @"request_sha256",
    @"transcript_before", @"launch_attempt", @"state", @"owner",
    @"failure_code", @"completion_receipt", @"transcript_after", @"calls",
    @"terminal_kind", @"created_at", @"updated_at",
  ];
}

static NSArray<NSString *> *DSHAgentReferenceKeysForRound(void) {
  return @[
    @"schema_version", @"transcript_ref", @"generation",
    @"transcript_sha256", @"transcript_bytes",
  ];
}

static BOOL DSHAgentRoundLocator(NSDictionary *locator) {
  return DSHAgentExactDictionaryKeys(locator, DSHAgentRoundLocatorKeys()) &&
      DSHAgentSafeInteger(locator[@"schema_version"], 1, NO) &&
      DSHAgentCanonicalUUID(locator[@"task_id"]) &&
      DSHAgentCanonicalUUID(locator[@"attempt_id"]) &&
      DSHAgentCanonicalUUID(locator[@"round_id"]) &&
      DSHAgentSafeInteger(locator[@"round_index"], 7, YES);
}

static BOOL DSHAgentRoundReference(NSDictionary *reference) {
  if (![reference isKindOfClass:NSDictionary.class]) return NO;
  return DSHAgentExactDictionaryKeys(reference, DSHAgentReferenceKeysForRound()) &&
      DSHAgentSafeInteger(reference[@"schema_version"], 1, NO) &&
      DSHAgentCanonicalUUID(reference[@"transcript_ref"]) &&
      DSHAgentSafeInteger(reference[@"generation"], 9007199254740991ULL, YES) &&
      DSHAgentCanonicalSHA256(reference[@"transcript_sha256"]) &&
      DSHAgentSafeInteger(reference[@"transcript_bytes"],
                          DSHAgentNativeWALMaxTranscriptBytes, YES);
}

static BOOL DSHAgentRoundOwner(NSDictionary *owner) {
  return DSHAgentExactDictionaryKeys(owner, @[
    @"schema_version", @"task_id", @"launch_id", @"native_task_id",
    @"owner_generation", @"heartbeat_at",
  ]) && DSHAgentSafeInteger(owner[@"schema_version"], 1, NO) &&
      DSHAgentCanonicalUUID(owner[@"task_id"]) &&
      DSHAgentCanonicalUUID(owner[@"launch_id"]) &&
      DSHAgentCanonicalUUID(owner[@"native_task_id"]) &&
      DSHAgentSafeInteger(owner[@"owner_generation"],
                          9007199254740991ULL, NO) &&
      DSHAgentCanonicalTimestamp(owner[@"heartbeat_at"]);
}

static BOOL DSHAgentRoundCallPresentation(NSDictionary *call) {
  if (![call isKindOfClass:NSDictionary.class]) return NO;
  NSString *callId = call[@"call_id"];
  NSString *name = call[@"name"];
  if (![call[@"access"] isKindOfClass:NSString.class]) return NO;
  NSCharacterSet *invalid = [[NSCharacterSet
      characterSetWithCharactersInString:
          @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-"]
      invertedSet];
  return DSHAgentExactDictionaryKeys(call, @[
    @"schema_version", @"call_id", @"name", @"arguments_sha256",
    @"safe_summary_key", @"access",
  ]) && DSHAgentSafeInteger(call[@"schema_version"], 1, NO) &&
      DSHAgentCanonicalSHA256(call[@"arguments_sha256"]) &&
      DSHAgentBoundedUTF8String(callId, 128, NO, nullptr) &&
      [callId rangeOfCharacterFromSet:invalid].location == NSNotFound &&
      DSHAgentBoundedUTF8String(name, 64, NO, nullptr) &&
      [name rangeOfCharacterFromSet:[[NSCharacterSet
          characterSetWithCharactersInString:
              @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"]
          invertedSet]].location == NSNotFound &&
      DSHAgentBoundedUTF8String(call[@"safe_summary_key"], 128, NO, nullptr) &&
      ([call[@"access"] isEqualToString:@"auto"] ||
       [call[@"access"] isEqualToString:@"conversation_confirm"] ||
       [call[@"access"] isEqualToString:@"confirm_once"]);
}

static BOOL DSHAgentOpaqueIdentifier(NSString *value) {
  if (!DSHAgentBoundedUTF8String(value, 128, NO, nullptr)) return NO;
  NSCharacterSet *invalid = [[NSCharacterSet
      characterSetWithCharactersInString:
          @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-"]
      invertedSet];
  return [value rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

static BOOL DSHAgentCompletionReceipt(NSDictionary *receipt,
                                      NSDictionary *locator) {
  if (![receipt isKindOfClass:NSDictionary.class]) return NO;
  receipt = DSHProviderRecordWithoutConfiguration(receipt, receipt[@"model"]);
  if (!DSHAgentExactDictionaryKeysWithOptional(receipt, @[
        @"schema_version", @"transport_schema_version", @"turn_id",
        @"attempt_id", @"round_id", @"round_index", @"provider_request_id",
        @"provider_response_id", @"requested_model", @"model", @"thinking_mode",
        @"finish_reason", @"latency_ms", @"visible_history_sha256",
        @"model_input_sha256", @"request_body_sha256", @"project_context_receipt",
      ], @[@"harness_id"]) || !DSHAgentSafeInteger(receipt[@"schema_version"], 1, NO) ||
      (![receipt[@"transport_schema_version"] isEqual:@2] &&
       ![receipt[@"transport_schema_version"] isEqual:@3]) ||
      !DSHAgentCanonicalUUID(receipt[@"turn_id"]) ||
      !DSHAgentCanonicalUUID(receipt[@"attempt_id"]) ||
      !DSHAgentCanonicalUUID(receipt[@"round_id"]) ||
      ![receipt[@"turn_id"] isEqual:locator[@"task_id"]] ||
      ![receipt[@"attempt_id"] isEqual:locator[@"attempt_id"]] ||
      ![receipt[@"round_id"] isEqual:locator[@"round_id"]] ||
      !DSHAgentSafeInteger(receipt[@"round_index"], 7, YES) ||
      ![receipt[@"round_index"] isEqual:locator[@"round_index"]] ||
      !DSHAgentOpaqueIdentifier(receipt[@"provider_request_id"]) ||
      !DSHAgentOpaqueIdentifier(receipt[@"provider_response_id"]) ||
      !DSHAgentBoundedUTF8String(receipt[@"requested_model"], 128, NO, nullptr) ||
      !DSHAgentBoundedUTF8String(receipt[@"model"], 128, NO, nullptr) ||
      !DSHAgentBoundedUTF8String(receipt[@"thinking_mode"], 32, NO, nullptr) ||
      !DSHAgentBoundedUTF8String(receipt[@"finish_reason"], 32, NO, nullptr) ||
      !DSHAgentSafeInteger(receipt[@"latency_ms"], 24 * 60 * 60 * 1000, YES) ||
      !DSHAgentCanonicalSHA256(receipt[@"visible_history_sha256"]) ||
      !DSHAgentCanonicalSHA256(receipt[@"model_input_sha256"]) ||
      !DSHAgentCanonicalSHA256(receipt[@"request_body_sha256"])) {
    return NO;
  }
  NSSet *models = DSHHarnessSupportedModels();
  if (receipt[@"harness_id"] != nil &&
      ![DSHHarnessIdForModel(receipt[@"model"]) isEqual:receipt[@"harness_id"]]) {
    return NO;
  }
  if (![models containsObject:receipt[@"requested_model"]] ||
      ![models containsObject:receipt[@"model"]] ||
      ![receipt[@"requested_model"] isEqual:receipt[@"model"]] ||
      (![receipt[@"thinking_mode"] isEqualToString:@"off"] &&
       ![receipt[@"thinking_mode"] isEqualToString:@"high"] &&
       ![receipt[@"thinking_mode"] isEqualToString:@"max"])) return NO;
  NSString *finishReason = receipt[@"finish_reason"];
  if (![finishReason isEqualToString:@"stop"] &&
      ![finishReason isEqualToString:@"tool_calls"] &&
      ![finishReason isEqualToString:@"length"] &&
      ![finishReason isEqualToString:@"content_filter"]) return NO;
  id context = receipt[@"project_context_receipt"];
  if (context == NSNull.null) return YES;
  return DSHAgentExactDictionaryKeys(context, @[
           @"schema_version", @"snapshot_id", @"snapshot_sha256",
           @"source_fingerprint", @"context_bytes", @"verified_at",
         ]) && DSHAgentSafeInteger(context[@"schema_version"], 1, NO) &&
      DSHAgentCanonicalUUID(context[@"snapshot_id"]) &&
      DSHAgentCanonicalSHA256(context[@"snapshot_sha256"]) &&
      DSHAgentCanonicalSHA256(context[@"source_fingerprint"]) &&
      DSHAgentSafeInteger(context[@"context_bytes"], 32 * 1024 * 1024, YES) &&
      DSHAgentCanonicalTimestamp(context[@"verified_at"]);
}

static BOOL DSHAgentRoundRow(NSDictionary *row) {
  if (!DSHAgentExactDictionaryKeys(row, DSHAgentRoundKeys()) ||
      ![row[@"schema_version"] isEqual:@2] ||
      !DSHAgentRoundLocator(row[@"locator"]) ||
      !DSHAgentSafeInteger(row[@"row_revision"], 9007199254740991ULL, NO) ||
      !DSHAgentCanonicalSHA256(row[@"root_fingerprint_sha256"]) ||
      !DSHAgentSafeInteger(row[@"binding_revision"], 9007199254740991ULL, NO) ||
      !DSHAgentCanonicalSHA256(row[@"request_sha256"]) ||
      !DSHAgentRoundReference(row[@"transcript_before"]) ||
      !DSHAgentSafeInteger(row[@"launch_attempt"], 8, NO) ||
      ![row[@"calls"] isKindOfClass:NSArray.class] ||
      [(NSArray *)row[@"calls"] count] > 16 ||
      !DSHAgentCanonicalTimestamp(row[@"created_at"]) ||
      !DSHAgentCanonicalTimestamp(row[@"updated_at"])) {
    return NO;
  }
  NSString *state = row[@"state"];
  if (![state isKindOfClass:NSString.class]) return NO;
  NSSet *states = [NSSet setWithArray:@[
    @"in_flight", @"failed_retryable", @"completed", @"cancel_requested",
    @"cancelled", @"unknown", @"ambiguous",
  ]];
  if (![states containsObject:state]) return NO;
  id owner = row[@"owner"];
  if (owner != NSNull.null && !DSHAgentRoundOwner(owner)) return NO;
  if (owner != NSNull.null &&
      ![owner[@"task_id"] isEqual:row[@"locator"][@"task_id"]]) return NO;
  id failure = row[@"failure_code"];
  if (failure != NSNull.null && !DSHAgentFailureCode(failure)) {
    return NO;
  }
  id receipt = row[@"completion_receipt"];
  if (receipt != NSNull.null &&
      (!DSHAgentCompletionReceipt(receipt, row[@"locator"]))) return NO;
  id after = row[@"transcript_after"];
  if (after != NSNull.null && !DSHAgentRoundReference(after)) return NO;
  id terminal = row[@"terminal_kind"];
  if (terminal != NSNull.null && ![terminal isKindOfClass:NSString.class]) return NO;
  if (terminal != NSNull.null && (![terminal isEqualToString:@"final"] &&
                                  ![terminal isEqualToString:@"tool_batch"] &&
                                  ![terminal isEqualToString:@"blocked"])) {
    return NO;
  }
  for (NSDictionary *call in row[@"calls"]) {
    if (!DSHAgentRoundCallPresentation(call)) return NO;
  }
  if ([state isEqualToString:@"completed"] && receipt != NSNull.null) {
    NSString *finishReason = receipt[@"finish_reason"];
    if ([finishReason isEqualToString:@"tool_calls"] &&
        (![terminal isEqualToString:@"tool_batch"] ||
         [(NSArray *)row[@"calls"] count] == 0)) return NO;
    if ([finishReason isEqualToString:@"stop"] &&
        (![terminal isEqualToString:@"final"] ||
         [(NSArray *)row[@"calls"] count] != 0)) return NO;
    if (([finishReason isEqualToString:@"length"] ||
         [finishReason isEqualToString:@"content_filter"]) &&
        (![terminal isEqualToString:@"blocked"] ||
         [(NSArray *)row[@"calls"] count] != 0)) return NO;
  }
  if ([state isEqualToString:@"in_flight"] ||
      [state isEqualToString:@"cancel_requested"]) {
    if (owner == NSNull.null || receipt != NSNull.null) return NO;
  } else if ([state isEqualToString:@"completed"]) {
    if (owner != NSNull.null || receipt == NSNull.null || after == NSNull.null ||
        terminal == NSNull.null || failure != NSNull.null) {
      return NO;
    }
  } else if ([state isEqualToString:@"cancelled"]) {
    if (owner != NSNull.null || receipt != NSNull.null || after == NSNull.null ||
        ![terminal isEqualToString:@"blocked"] ||
        ![failure isEqualToString:@"E_AGENT_CANCELLED"]) {
      return NO;
    }
    if (![after isEqual:row[@"transcript_before"]]) return NO;
  } else if ([state isEqualToString:@"failed_retryable"]) {
    if (owner != NSNull.null || receipt != NSNull.null || after != NSNull.null ||
        terminal != NSNull.null || failure == NSNull.null) {
      return NO;
    }
  } else if ([state isEqualToString:@"unknown"] ||
             [state isEqualToString:@"ambiguous"]) {
    if (owner != NSNull.null || receipt != NSNull.null || terminal != NSNull.null ||
        failure == NSNull.null) {
      return NO;
    }
    if ([state isEqualToString:@"ambiguous"] &&
        ![failure isEqualToString:@"E_AGENT_ROUND_AMBIGUOUS"]) return NO;
    if ([state isEqualToString:@"unknown"] &&
        ![failure isEqualToString:@"E_AGENT_PERSISTENCE"]) return NO;
  }
  return YES;
}

BOOL DSHAgentValidateRoundNativeEntryV2(NSDictionary *row, NSError **error) {
  if (DSHAgentRoundRow(row)) return YES;
  DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
  return NO;
}

@interface DSHAgentRoundJournal ()
@property(nonatomic, strong, readwrite) DSHAgentNativeWAL *wal;
@end

@implementation DSHAgentRoundJournal

- (instancetype)initWithWAL:(DSHAgentNativeWAL *)wal {
  self = [super init];
  if (self) _wal = wal;
  return self;
}

#pragma mark - Native schema-v3 round composition (shared-core facade)

// The schema-3 selectors are a facade over the Rust reducer in
// modules/rish/core (`rish_agent_round_reduce`). This side owns the WAL
// transaction: it gathers the round row, its dispatch marker, the bound
// transcript row and the two liveness answers into a view, hands the
// operation to the reducer, and applies the returned effect verbatim. Round
// policy (argument validation, CAS matching, transitions, digests) lives in
// crates/rish-agent-core/src/round_journal.rs and nowhere else.

static NSDictionary *DSHAgentRoundReduce(NSDictionary *envelope,
                                         NSError **error) {
  NSData *bytes = DSHAgentCanonicalJSON(envelope, nil);
  if (bytes == nil) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  char *raw = rish_agent_round_reduce((const char *)bytes.bytes, bytes.length);
  if (raw == NULL) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  NSData *reply = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  id parsed = [NSJSONSerialization JSONObjectWithData:reply options:0 error:nil];
  if (![parsed isKindOfClass:NSDictionary.class]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  if (![parsed[@"ok"] isEqual:@YES]) {
    NSInteger code = [parsed[@"error"] isKindOfClass:NSNumber.class]
        ? [parsed[@"error"] integerValue] : 0;
    if (code < DSHAgentNativeStoreErrorInvalidArgument ||
        code > DSHAgentNativeStoreErrorPersistence) {
      code = DSHAgentNativeStoreErrorCorrupt;
    }
    DSHSetAgentNativeStoreError(error, (DSHAgentNativeStoreErrorCode)code);
    return nil;
  }
  return parsed;
}

// Host facts the reducer cannot derive: the launch, the injected clock, and
// the provider catalogue's answers for the receipt being committed. The
// catalogue is consulted outside the WAL lock.
- (NSDictionary *)v3EnvironmentForReceipt:(id)receipt {
  NSMutableArray *models = [NSMutableArray array];
  for (id model in DSHHarnessSupportedModels()) {
    if ([model isKindOfClass:NSString.class]) [models addObject:model];
  }
  [models sortUsingSelector:@selector(compare:)];
  id harness = NSNull.null;
  NSNumber *bindingValid = @NO;
  if ([receipt isKindOfClass:NSDictionary.class]) {
    id model = receipt[@"model"];
    NSString *resolved = DSHHarnessIdForModel(model);
    if (resolved != nil) harness = resolved;
    id binding = receipt[@"provider_configuration"];
    if (binding != nil) {
      bindingValid = ([model isKindOfClass:NSString.class] &&
                      DSHValidateProviderBinding(binding, model)) ? @YES : @NO;
    }
  }
  return @{
    @"launch_id" : self.wal.launchId,
    @"now" : [self.wal currentTimestamp],
    @"supported_models" : models,
    @"receipt_harness_id" : harness,
    @"receipt_binding_valid" : bindingValid,
  };
}

- (NSDictionary *)runV3Operation:(NSString *)op
                            args:(NSDictionary *)args
                         locator:(id)locator
                        argOwner:(id)argOwner
                         receipt:(id)receipt
                 needsTranscript:(BOOL)needsTranscript
                        readOnly:(BOOL)readOnly
                           error:(NSError **)error {
  NSDictionary *environment = [self v3EnvironmentForReceipt:receipt];
  __block NSDictionary *output = nil;
  DSHAgentNativeWALMutation run = ^BOOL(NSMutableDictionary *state,
                                        NSError **mutationError) {
    NSArray *rounds = state[@"rounds"];
    NSArray *dispatch = state[@"dispatch"];
    NSArray *transcripts = state[@"transcripts"];
    NSDictionary *row = nil;
    NSUInteger rowIndex = NSNotFound;
    for (NSUInteger index = 0; index < rounds.count; index += 1) {
      NSDictionary *candidate = rounds[index];
      if (locator != nil && [candidate[@"locator"] isEqual:locator]) {
        row = candidate;
        rowIndex = index;
        break;
      }
    }
    NSString *dispatchState = locator == nil ? nil
        : DSHAgentRoundDispatchState(dispatch, locator);
    NSDictionary *transcript = nil;
    NSUInteger transcriptIndex = NSNotFound;
    if (needsTranscript && row != nil) {
      id reference = row[@"transcript_before"];
      id transcriptRef = [reference isKindOfClass:NSDictionary.class]
          ? reference[@"transcript_ref"] : nil;
      for (NSUInteger index = 0; index < transcripts.count; index += 1) {
        NSDictionary *candidate = transcripts[index];
        if (transcriptRef != nil &&
            [candidate[@"transcript_ref"] isEqual:transcriptRef]) {
          transcript = candidate;
          transcriptIndex = index;
          break;
        }
      }
    }
    BOOL argOwnerAlive = [argOwner isKindOfClass:NSDictionary.class] &&
        [self.wal isNativeTaskAlive:argOwner[@"native_task_id"]
                            launchId:argOwner[@"launch_id"]];
    id rowOwner = row[@"owner"];
    BOOL rowOwnerAlive = [rowOwner isKindOfClass:NSDictionary.class] &&
        [self.wal isNativeTaskAlive:rowOwner[@"native_task_id"]
                            launchId:rowOwner[@"launch_id"]];
    NSMutableDictionary *env = [environment mutableCopy];
    env[@"round_count"] = @(rounds.count);
    NSDictionary *envelope = @{
      @"op" : op,
      @"args" : args,
      @"env" : env,
      @"view" : @{
        @"row" : row ?: NSNull.null,
        @"dispatch_state" : dispatchState ?: NSNull.null,
        @"transcript" : transcript ?: NSNull.null,
        @"arg_owner_alive" : argOwnerAlive ? @YES : @NO,
        @"row_owner_alive" : rowOwnerAlive ? @YES : @NO,
      },
    };
    NSDictionary *result = DSHAgentRoundReduce(envelope, mutationError);
    if (result == nil) return NO;
    output = [result[@"output"] isKindOfClass:NSDictionary.class]
        ? result[@"output"] : nil;
    if (output == nil) {
      DSHSetAgentNativeStoreError(mutationError, DSHAgentNativeStoreErrorCorrupt);
      return NO;
    }
    // A decided-but-uncommitted answer (already_present, already_dispatched,
    // query) is the WAL's explicit no-op: return NO with no error.
    if (readOnly || ![result[@"commit"] isEqual:@YES]) return NO;

    id nextRow = result[@"row"];
    if ([nextRow isKindOfClass:NSDictionary.class]) {
      NSMutableArray *nextRounds = [rounds mutableCopy];
      if (rowIndex == NSNotFound) {
        [nextRounds addObject:nextRow];
      } else {
        nextRounds[rowIndex] = nextRow;
      }
      state[@"rounds"] = nextRounds;
    }
    id dispatchEffect = result[@"dispatch"];
    if ([dispatchEffect isEqual:@"insert_not_dispatched"]) {
      NSMutableArray *nextDispatch = [dispatch mutableCopy];
      [nextDispatch addObject:@{
        @"schema_version" : @1,
        @"kind" : @"round",
        @"locator" : nextRow[@"locator"],
        @"dispatch_state" : @"not_dispatched",
      }];
      state[@"dispatch"] = nextDispatch;
    } else if ([dispatchEffect isEqual:@"mark_dispatched"]) {
      NSMutableArray *nextDispatch = [dispatch mutableCopy];
      NSUInteger markerIndex = NSNotFound;
      for (NSUInteger index = 0; index < nextDispatch.count; index += 1) {
        NSDictionary *candidate = nextDispatch[index];
        if ([candidate[@"kind"] isEqualToString:@"round"] &&
            [candidate[@"locator"] isEqual:locator]) {
          markerIndex = index;
          break;
        }
      }
      if (markerIndex == NSNotFound) {
        DSHSetAgentNativeStoreError(mutationError, DSHAgentNativeStoreErrorCorrupt);
        return NO;
      }
      NSMutableDictionary *marker = [nextDispatch[markerIndex] mutableCopy];
      marker[@"dispatch_state"] = @"dispatched";
      nextDispatch[markerIndex] = [marker copy];
      state[@"dispatch"] = nextDispatch;
    } else if ([dispatchEffect isEqual:@"reset_not_dispatched"]) {
      // The provider refused the request in full: the row is
      // failed_retryable, and the marker goes back in the same transaction,
      // or the WAL holds a state the core calls corrupt.
      NSMutableArray *nextDispatch = [dispatch mutableCopy];
      NSUInteger markerIndex = NSNotFound;
      for (NSUInteger index = 0; index < nextDispatch.count; index += 1) {
        NSDictionary *candidate = nextDispatch[index];
        if ([candidate[@"kind"] isEqualToString:@"round"] &&
            [candidate[@"locator"] isEqual:locator]) {
          markerIndex = index;
          break;
        }
      }
      if (markerIndex == NSNotFound) {
        DSHSetAgentNativeStoreError(mutationError, DSHAgentNativeStoreErrorCorrupt);
        return NO;
      }
      NSMutableDictionary *marker = [nextDispatch[markerIndex] mutableCopy];
      marker[@"dispatch_state"] = @"not_dispatched";
      nextDispatch[markerIndex] = [marker copy];
      state[@"dispatch"] = nextDispatch;
    } else if (dispatchEffect != nil && dispatchEffect != NSNull.null) {
      // An effect this file does not know must not be dropped: the row
      // beside it would be committed without it.
      DSHSetAgentNativeStoreError(mutationError, DSHAgentNativeStoreErrorCorrupt);
      return NO;
    }
    id nextTranscript = result[@"transcript"];
    if ([nextTranscript isKindOfClass:NSDictionary.class]) {
      if (transcriptIndex == NSNotFound) {
        DSHSetAgentNativeStoreError(mutationError, DSHAgentNativeStoreErrorCorrupt);
        return NO;
      }
      NSMutableArray *nextTranscripts = [transcripts mutableCopy];
      nextTranscripts[transcriptIndex] = nextTranscript;
      state[@"transcripts"] = nextTranscripts;
    }
    return YES;
  };
  if (readOnly) {
    NSDictionary *snapshot = [self.wal snapshotWithError:error];
    if (snapshot == nil) return nil;
    NSError *reduceError = nil;
    (void)run([snapshot mutableCopy], &reduceError);
    if (reduceError != nil) {
      if (error != nullptr) *error = reduceError;
      return nil;
    }
    return output;
  }
  BOOL committed = [self.wal performAtomicTransaction:run error:error];
  return committed ? output : nil;
}

static id DSHAgentRoundArgument(id value) {
  return value ?: NSNull.null;
}

static id DSHAgentRoundLocatorOf(id container) {
  return [container isKindOfClass:NSDictionary.class] ? container[@"locator"] : nil;
}

- (NSDictionary *)createAgentRoundV3WithInsertCAS:(NSDictionary *)insertCAS
                                  exactRoundStart:(NSDictionary *)round
                                             error:(NSError **)error {
  return [self runV3Operation:@"create"
                         args:@{
                           @"insert_cas" : DSHAgentRoundArgument(insertCAS),
                           @"round" : DSHAgentRoundArgument(round),
                         }
                      locator:DSHAgentRoundLocatorOf(insertCAS)
                     argOwner:[round isKindOfClass:NSDictionary.class] ? round[@"owner"] : nil
                      receipt:nil
              needsTranscript:NO
                     readOnly:NO
                        error:error];
}

- (NSDictionary *)claimAgentRoundV3WithLocator:(NSDictionary *)locator
                              expectedRowRevision:(NSNumber *)revision
                                             owner:(NSDictionary *)owner
                                             error:(NSError **)error {
  return [self runV3Operation:@"claim"
                         args:@{
                           @"locator" : DSHAgentRoundArgument(locator),
                           @"expected_row_revision" : DSHAgentRoundArgument(revision),
                           @"owner" : DSHAgentRoundArgument(owner),
                         }
                      locator:locator
                     argOwner:owner
                      receipt:nil
              needsTranscript:NO
                     readOnly:NO
                        error:error];
}

- (NSDictionary *)markAgentRoundV3DispatchedWithCAS:(NSDictionary *)cas
                                               error:(NSError **)error {
  return [self runV3Operation:@"mark_dispatched"
                         args:@{ @"cas" : DSHAgentRoundArgument(cas) }
                      locator:DSHAgentRoundLocatorOf(cas)
                     argOwner:nil
                      receipt:nil
              needsTranscript:NO
                     readOnly:NO
                        error:error];
}

- (NSDictionary *)completeAgentRoundV3WithLocator:(NSDictionary *)locator
                                      expectedCAS:(NSDictionary *)cas
                                         messages:(NSArray *)messages
                                completionReceipt:(NSDictionary *)receipt
                                     terminalKind:(NSString *)terminalKind
                                           calls:(NSArray *)calls
                                            root:(NSDictionary *)root
                                            error:(NSError **)error {
  return [self runV3Operation:@"complete"
                         args:@{
                           @"locator" : DSHAgentRoundArgument(locator),
                           @"cas" : DSHAgentRoundArgument(cas),
                           @"messages" : DSHAgentRoundArgument(messages),
                           @"receipt" : DSHAgentRoundArgument(receipt),
                           @"terminal_kind" : DSHAgentRoundArgument(terminalKind),
                           @"calls" : DSHAgentRoundArgument(calls),
                           @"root" : DSHAgentRoundArgument(root),
                         }
                      locator:locator
                     argOwner:nil
                      receipt:receipt
              needsTranscript:YES
                     readOnly:NO
                        error:error];
}

- (NSDictionary *)cancelAgentRoundV3WithCAS:(NSDictionary *)cas
                                        error:(NSError **)error {
  return [self runV3Operation:@"cancel"
                         args:@{ @"cas" : DSHAgentRoundArgument(cas) }
                      locator:DSHAgentRoundLocatorOf(cas)
                     argOwner:nil
                      receipt:nil
              needsTranscript:NO
                     readOnly:NO
                        error:error];
}

- (NSDictionary *)reconcileAgentRoundV3OwnerLossWithLocator:(NSDictionary *)locator
                                                 expectedCAS:(NSDictionary *)cas
                                                        error:(NSError **)error {
  return [self reconcileAgentRoundV3OwnerLossWithLocator:locator
                                              expectedCAS:cas
                                        transportEvidence:nil
                                                    error:error];
}

- (NSDictionary *)reconcileAgentRoundV3OwnerLossWithLocator:(NSDictionary *)locator
                                                 expectedCAS:(NSDictionary *)cas
                                           transportEvidence:(NSDictionary *)evidence
                                                        error:(NSError **)error {
  return [self runV3Operation:@"reconcile"
                         args:@{
                           @"locator" : DSHAgentRoundArgument(locator),
                           @"cas" : DSHAgentRoundArgument(cas),
                           @"transport_evidence" : evidence ?: NSNull.null,
                         }
                      locator:locator
                     argOwner:nil
                      receipt:nil
              needsTranscript:NO
                     readOnly:NO
                        error:error];
}

- (NSDictionary *)queryAgentRoundV3WithLocator:(NSDictionary *)locator
                                          error:(NSError **)error {
  return [self runV3Operation:@"query"
                         args:@{ @"locator" : DSHAgentRoundArgument(locator) }
                      locator:locator
                     argOwner:nil
                      receipt:nil
              needsTranscript:NO
                     readOnly:YES
                        error:error];
}

- (NSDictionary *)reconcileAgentRoundV3OwnerLossWithLocator:(NSDictionary *)locator
                                              expectedCAS:(NSDictionary *)cas
                                              failureCode:(NSString *)failureCode
                                                    error:(NSError **)error {
  return [self runV3Operation:@"reconcile" args:@{@"locator":DSHAgentRoundArgument(locator),
    @"cas":DSHAgentRoundArgument(cas), @"failure_code":failureCode ?: NSNull.null}
    locator:locator argOwner:nil receipt:nil needsTranscript:NO readOnly:NO error:error];
}

@end
