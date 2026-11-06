#import "AgentProviderPreflightFailure.h"
#import "AgentProviderRoundServiceInternals.h"
#import "AgentRoundJournal.h"

NSDictionary *DSHProviderFailBeforeDispatch(
    DSHAgentNativeWAL *wal, DSHAgentRoundJournal *rounds,
    NSDictionary *request, NSString *requestSHA, BOOL retry,
    NSDictionary *existingRow, NSString *nativeTaskId,
    NSString *failureCode, NSError **error) {
  NSDictionary *locator = DSHProviderRoundLocator(request);
  NSDictionary *row = existingRow;
  NSString *ownerId = nativeTaskId;
  if (row == nil) {
    ownerId = NSUUID.UUID.UUIDString.lowercaseString;
    if (![wal registerNativeTaskId:ownerId error:error]) return nil;
    NSDictionary *owner = DSHProviderOwner(wal, request[@"task_id"], ownerId);
    if (retry) {
      NSDictionary *previous = [rounds queryAgentRoundV3WithLocator:locator error:error][@"row"];
      NSUInteger launch = [previous[@"launch_attempt"] unsignedIntegerValue];
      if (![previous[@"state"] isEqual:@"failed_retryable"] ||
          ![previous[@"row_revision"] isEqual:request[@"expected_round_revision"]] ||
          launch >= 8 || [request[@"launch_attempt"] unsignedIntegerValue] != launch + 1) {
        [wal unregisterNativeTaskId:ownerId error:nil];
        DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorConflict);
        return nil;
      }
      row = [rounds claimAgentRoundV3WithLocator:locator
        expectedRowRevision:previous[@"row_revision"] owner:owner error:error][@"row"];
    } else {
      NSString *now = wal.currentTimestamp;
      NSDictionary *start = @{@"schema_version":@3, @"locator":locator, @"row_revision":@1,
        @"root_fingerprint_sha256":request[@"root"][@"root_fingerprint_sha256"],
        @"binding_revision":request[@"root"][@"workspace_binding_revision"], @"request_sha256":requestSHA,
        @"transcript_before":request[@"transcript"], @"launch_attempt":request[@"launch_attempt"],
        @"state":@"in_flight", @"owner":owner, @"failure_code":NSNull.null,
        @"completion_receipt":NSNull.null, @"transcript_after":NSNull.null, @"calls":@[],
        @"batch_class":NSNull.null, @"executable_call_count":@0, @"denied_call_count":@0,
        @"terminal_kind":NSNull.null, @"created_at":now, @"updated_at":now};
      NSDictionary *cas = @{@"schema_version":@1, @"locator":locator, @"expected_absent":@YES,
        @"expected_transcript_generation":request[@"transcript"][@"generation"],
        @"expected_transcript_sha256":request[@"transcript"][@"transcript_sha256"],
        @"expected_root_fingerprint_sha256":request[@"root"][@"root_fingerprint_sha256"],
        @"expected_binding_revision":request[@"root"][@"workspace_binding_revision"]};
      row = [rounds createAgentRoundV3WithInsertCAS:cas exactRoundStart:start error:error][@"row"];
    }
  }
  // The core accepts an explicit cause only after proving this owner is gone
  // and the durable dispatch marker is still not_dispatched.
  if (ownerId != nil && ![wal unregisterNativeTaskId:ownerId error:error]) return nil;
  if (row == nil) return nil;
  NSDictionary *settled = [rounds reconcileAgentRoundV3OwnerLossWithLocator:locator
    expectedCAS:DSHProviderRoundCASForRow(row) failureCode:failureCode error:error][@"row"];
  NSString *status = settled[@"state"];
  if (![@[@"failed_retryable", @"cancelled"] containsObject:status ?: @""]) {
    if (error != nullptr && *error == nil) DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorPersistence);
    return nil;
  }
  NSDictionary *result = DSHProviderRoundResultForRow(request, settled, status, settled[@"failure_code"]);
  if (result == nil) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  NSDictionary *ref = @{@"schema_version":@2, @"kind":@"round", @"task_id":request[@"task_id"],
    @"attempt_id":request[@"attempt_id"], @"round_id":request[@"round_id"],
    @"round_index":request[@"round_index"], @"round_revision":settled[@"row_revision"]};
  NSDictionary *committed = DSHAgentNativeWALCommitOperation(wal,
    request[@"operation_id"], requestSHA, request[@"task_id"], request[@"attempt_id"],
    @"committed", status, ref, settled[@"row_revision"], DSHProviderOperationSafeResult(result), error);
  if (committed == nil) return nil;
  if (error != nullptr) *error = nil;
  return result;
}
