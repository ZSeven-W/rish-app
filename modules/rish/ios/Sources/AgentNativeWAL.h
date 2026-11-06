#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The Agent stores are deliberately views over one native transaction domain.
/// This error domain is value-free: callers may use the `code` user-info value
/// for a stable UI/proof code, but must never surface an underlying NSError.
FOUNDATION_EXPORT NSErrorDomain const DSHAgentNativeStoreErrorDomain;

typedef NS_ERROR_ENUM(DSHAgentNativeStoreErrorDomain,
                      DSHAgentNativeStoreErrorCode) {
  DSHAgentNativeStoreErrorInvalidArgument = 1,
  DSHAgentNativeStoreErrorCorrupt = 2,
  DSHAgentNativeStoreErrorConflict = 3,
  DSHAgentNativeStoreErrorCapacity = 4,
  DSHAgentNativeStoreErrorUnavailable = 5,
  DSHAgentNativeStoreErrorOwnerLost = 6,
  DSHAgentNativeStoreErrorNotFound = 7,
  DSHAgentNativeStoreErrorPersistence = 8,
};

/// A fault hook is test-only/application-owned. Returning NO fails the
/// current operation with a stable persistence error. The stage names never
/// contain paths, payloads, or native errors.
typedef BOOL (^DSHAgentNativeWALFaultHook)(NSString *stage);
typedef NSDate * _Nonnull (^DSHAgentNativeWALClock)(void);
typedef NSString * _Nonnull (^DSHAgentNativeWALIdentifierGenerator)(void);

/// One synchronous mutation over the complete WAL state. The mutable state is
/// private to the WAL and is committed atomically only when the block returns
/// YES. A block must not retain the state or perform external effects.
typedef BOOL (^DSHAgentNativeWALMutation)(NSMutableDictionary *state,
                                          NSError **error);

FOUNDATION_EXPORT const NSUInteger DSHAgentNativeWALMaxTranscriptBytes;
FOUNDATION_EXPORT const NSUInteger DSHAgentNativeWALMaxTranscriptCount;
FOUNDATION_EXPORT const NSUInteger DSHAgentNativeWALMaxLedgerRowsPerAttempt;
FOUNDATION_EXPORT const NSUInteger DSHAgentNativeWALMaxRoundRowsPerAttempt;
FOUNDATION_EXPORT const NSUInteger DSHAgentNativeWALMaxStoreBytes;
FOUNDATION_EXPORT const NSUInteger DSHAgentNativeWALMaxSingleWriteBytes;
FOUNDATION_EXPORT const NSUInteger DSHAgentNativeWALMaxBatchWriteBytes;
FOUNDATION_EXPORT const NSUInteger DSHAgentNativeWALMaxAttemptWriteBytes;
FOUNDATION_EXPORT const NSUInteger DSHAgentNativeWALMaxAuthorities;
FOUNDATION_EXPORT const NSUInteger DSHAgentNativeWALMaxOperationsPerAttempt;
FOUNDATION_EXPORT const NSUInteger DSHAgentNativeWALMaxOperations;
FOUNDATION_EXPORT const NSUInteger DSHAgentNativeWALMaxOperationRecordBytes;
FOUNDATION_EXPORT const NSUInteger DSHAgentNativeWALMaxOperationResultBytes;
FOUNDATION_EXPORT const NSUInteger DSHAgentNativeWALMaxBatchesPerAttempt;
FOUNDATION_EXPORT const NSUInteger DSHAgentNativeWALMaxDeniedCallsPerAttempt;
FOUNDATION_EXPORT const NSUInteger DSHAgentNativeWALMaxDeniedCalls;

/// The process launch ID is intentionally fresh for every WAL instance. A
/// persisted owner is considered live only when its launch ID and native task
/// ID are both registered in this exact process.
@interface DSHAgentNativeWAL : NSObject

- (instancetype)init NS_UNAVAILABLE;

- (instancetype)initWithRootURL:(NSURL *)rootURL
                           clock:(DSHAgentNativeWALClock)clock
              identifierGenerator:(DSHAgentNativeWALIdentifierGenerator)generator
                         faultHook:(nullable DSHAgentNativeWALFaultHook)faultHook
    NS_DESIGNATED_INITIALIZER;

- (instancetype)initWithRootURL:(NSURL *)rootURL
                           clock:(DSHAgentNativeWALClock)clock
               launchIdGenerator:(DSHAgentNativeWALIdentifierGenerator)generator
                       faultHook:(nullable DSHAgentNativeWALFaultHook)faultHook;

/// Creates the private directory and performs crash/torn-write recovery. A
/// malformed or torn transaction fails closed and performs no mutation.
- (BOOL)ensureStorageWithError:(NSError **)error;

/// Executes one WAL transaction under the root-shared serial lock. The
/// transaction includes transcript, round, ledger, and write-reservation
/// changes together; typed stores use this method rather than independent
/// files.
- (BOOL)performAtomicTransaction:(DSHAgentNativeWALMutation)mutation
                           error:(NSError **)error;

/// Returns a detached immutable snapshot of the complete WAL state. The
/// result is private native data and must not cross the native bridge.
- (nullable NSDictionary *)snapshotWithError:(NSError **)error;

/// Re-runs owner-loss reconciliation after bootstrap. Existing owners from a
/// prior launch become ambiguous; rows whose owner matches this process remain
/// live only when the native task was explicitly registered.
- (BOOL)reconcileOwnerLossWithError:(NSError **)error;

/// Returns the persisted dispatch proof for a full round/ledger locator. A
/// missing marker returns nil and is treated as not provable, never as
/// `not_dispatched`.
- (nullable NSString *)dispatchStateForKind:(NSString *)kind
                                    locator:(NSDictionary *)locator
                                      error:(NSError **)error;

/// Registers/unregisters an in-process native task. These APIs are only for
/// native executors and tests; a the UI string cannot prove liveness.
- (BOOL)registerNativeTaskId:(NSString *)nativeTaskId error:(NSError **)error;
- (BOOL)unregisterNativeTaskId:(NSString *)nativeTaskId error:(NSError **)error;
- (BOOL)isNativeTaskAlive:(NSString *)nativeTaskId
                  launchId:(NSString *)launchId;

/// The injected clock is the only timestamp authority for persisted rows.
- (NSString *)currentTimestamp;
- (NSString *)currentTimestampAddingInterval:(NSTimeInterval)interval;

/// A fresh canonical lowercase UUID for this process launch.
@property(nonatomic, copy, readonly) NSString *launchId;
@property(nonatomic, strong, readonly) NSURL *rootURL;
@property(nonatomic, strong, readonly) NSURL *walURL;

@end

/// Native-private schema-v2 operation relation helpers. These functions are
/// deliberately not app UI exports: `request` and `safeResult` must be
/// the already validated exact high-level V2 objects owned by the native
/// coordinator. Results are detached immutable Foundation JSON values.
///
/// `DSHAgentNativeWALStartOperation` computes the normative
/// HJ(agent-operation-request,{operation_kind,request}) digest and atomically
/// inserts `started`, or returns the immutable historical result on an exact
/// replay. A reused operation ID with any different request/identity fails
/// with DSHAgentNativeStoreErrorConflict and performs no work.
FOUNDATION_EXPORT NSDictionary * _Nullable DSHAgentNativeWALStartOperation(
    DSHAgentNativeWAL *wal,
    NSString *operationKind,
    NSDictionary *request,
    NSString *taskId,
    NSString *attemptId,
    NSNumber *authorityRevision,
    NSError **error);

/// Cancel/recovery requests carry task/attempt identity only inside their
/// exact `target` union.  This variant binds the caller's explicit identity to
/// that immutable target without rewriting or augmenting the public request;
/// request_sha256 remains HJ(agent-operation-request,{operation_kind,request})
/// over the original complete request bytes.  Only `cancel_agent_attempt` and
/// `recover_agent_attempt` are accepted.  The ordinary start helper remains
/// strict about top-level task_id/attempt_id and is not relaxed.
FOUNDATION_EXPORT NSDictionary * _Nullable
DSHAgentNativeWALStartTargetOperation(
    DSHAgentNativeWAL *wal,
    NSString *operationKind,
    NSDictionary *request,
    NSDictionary *target,
    NSString *taskId,
    NSString *attemptId,
    NSNumber *authorityRevision,
    NSError **error);

/// Full-identity query. `not_started` is returned only for proven absence;
/// exact retained operations include their detached immutable snapshot.
FOUNDATION_EXPORT NSDictionary * _Nullable DSHAgentNativeWALQueryOperation(
    DSHAgentNativeWAL *wal,
    NSString *operationId,
    NSString *requestSHA256,
    NSString *taskId,
    NSString *attemptId,
    NSError **error);

/// Atomically commits one operation state, result reference and immutable safe
/// result snapshot. The snapshot is digest/size bound and may never contain
/// protected Agent/native keys. Repeating the exact terminal commit returns
/// the original snapshot; no current row is re-projected for replay.
FOUNDATION_EXPORT NSDictionary * _Nullable DSHAgentNativeWALCommitOperation(
    DSHAgentNativeWAL *wal,
    NSString *operationId,
    NSString *requestSHA256,
    NSString *taskId,
    NSString *attemptId,
    NSString *state,
    NSString *resultStatus,
    NSDictionary *resultRef,
    NSNumber * _Nullable resultRevision,
    NSDictionary *safeResult,
    NSError **error);

/// Native-private in-transaction form used by the high-level batch/execution
/// coordinators. The caller already owns `state` inside
/// `performAtomicTransaction:`; this mutates the matching started operation and
/// immutable result snapshot in that same candidate. It performs no nested
/// WAL transaction and never accepts protected/raw result fields.
FOUNDATION_EXPORT NSDictionary * _Nullable
DSHAgentNativeWALCommitOperationInState(
    NSMutableDictionary *state,
    DSHAgentNativeWAL *wal,
    NSString *operationId,
    NSString *requestSHA256,
    NSString *taskId,
    NSString *attemptId,
    NSString *terminalState,
    NSString *resultStatus,
    NSDictionary *resultRef,
    NSNumber * _Nullable resultRevision,
    NSDictionary *safeResult,
    NSError **error);

/// The prepare-attempt composition point: inserts the exact frozen authority
/// and commits the matching prepare operation/snapshot in one WAL CAS. Exact
/// replay returns the historical immutable safe result. This has no provider
/// or tool effect and is not exported through native registry.
FOUNDATION_EXPORT NSDictionary * _Nullable
DSHAgentNativeWALPrepareAuthorityOperation(
    DSHAgentNativeWAL *wal,
    NSDictionary *authority,
    NSDictionary *request,
    NSDictionary *safeResult,
    NSError **error);

/// Native-only versioned evidence insertion used by the batch coordinator.
/// Write/read-only branches and durable-denial records are closed exact
/// schema unions. Exact duplicates replay; conflicting identities fail.
FOUNDATION_EXPORT NSDictionary * _Nullable DSHAgentNativeWALRecordBatch(
    DSHAgentNativeWAL *wal,
    NSDictionary *batch,
    NSError **error);
FOUNDATION_EXPORT NSDictionary * _Nullable DSHAgentNativeWALRecordDeniedCall(
    DSHAgentNativeWAL *wal,
    NSDictionary *deniedCall,
    NSError **error);

/// Short class spelling retained for native callers that use the file's
/// `AgentNativeWAL` name. Both names are the same implementation and share the
/// root lock/WAL domain.
@compatibility_alias AgentNativeWAL DSHAgentNativeWAL;

/// Stable, value-free NSError construction shared by typed views.
FOUNDATION_EXPORT NSError *DSHAgentNativeStoreError(
    DSHAgentNativeStoreErrorCode code);
FOUNDATION_EXPORT void DSHSetAgentNativeStoreError(
    NSError **error, DSHAgentNativeStoreErrorCode code);

/// Exact bounded primitive validators shared by the typed views. These do not
/// normalize input: invalid UTF-8, Unicode, numbers, and identifiers reject.
FOUNDATION_EXPORT BOOL DSHAgentCanonicalUUID(id value);
FOUNDATION_EXPORT BOOL DSHAgentCanonicalSHA256(id value);
FOUNDATION_EXPORT BOOL DSHAgentSafeInteger(id value,
                                           NSUInteger maximum,
                                           BOOL allowZero);
FOUNDATION_EXPORT BOOL DSHAgentBoundedUTF8String(id value,
                                                  NSUInteger maximumBytes,
                                                  BOOL allowEmpty,
                                                  NSString * _Nullable * _Nullable output);
FOUNDATION_EXPORT BOOL DSHAgentCanonicalTimestamp(id value);
/// The closed, value-free failure-code union accepted in persisted rows and
/// protected tool feedback.  Native NSError codes are not automatically
/// eligible for this union.
FOUNDATION_EXPORT BOOL DSHAgentFailureCode(id value);
FOUNDATION_EXPORT BOOL DSHAgentExactDictionaryKeys(NSDictionary *value,
                                                   NSArray<NSString *> *keys);
/// Exact keys plus a closed optional-key allowance for post-ship wire
/// fields (currently only `harness_id`).
FOUNDATION_EXPORT BOOL DSHAgentExactDictionaryKeysWithOptional(
    NSDictionary *value, NSArray<NSString *> *keys,
    NSArray<NSString *> *optionalKeys);
FOUNDATION_EXPORT BOOL DSHAgentIsImmutableFoundationJSON(id value);

/// Domain-separated digest helpers. They use the shared
/// DSHWorkspaceCanonicalJSONData/DSHWorkspaceSHA256Hex codec; no Agent-local
/// JSON canonicalizer exists.
FOUNDATION_EXPORT NSString * _Nullable DSHAgentHJ(NSString *tag,
                                                  id value,
                                                  NSError **error);
FOUNDATION_EXPORT NSString * _Nullable DSHAgentHB(NSString *tag,
                                                  NSData *bytes,
                                                  NSError **error);

/// Canonical JSON bytes for a private WAL candidate. This is intentionally a
/// small forwarding surface to the shared workspace codec.
FOUNDATION_EXPORT NSData * _Nullable DSHAgentCanonicalJSON(id value,
                                                           NSError **error);

/// Deep immutable copy through the shared JSON codec. It rejects non-canonical
/// persisted bytes by requiring a canonical byte-for-byte round trip.
FOUNDATION_EXPORT id _Nullable DSHAgentImmutableJSONCopy(id value,
                                                         NSError **error);

/// Strict native parser for provider tool arguments. It rejects duplicate
/// object keys (including escaped-equivalent keys), negative zero, non-finite
/// or mathematically unsafe decimal/exponent numbers, and integer lexemes
/// outside the JSON safe-integer subset. The bounded JSON envelope includes
/// wrapper overhead around a 32768-byte write payload.
FOUNDATION_EXPORT NSDictionary * _Nullable DSHAgentParseArgumentsJSON(
    NSString *argumentsJSON,
    NSError **error);
/// Identity digest of a tool call: a well-formed tool name over parseable
/// argument objects.  It never judges the arguments themselves; see
/// DSHAgentToolArgumentsAccepted.
FOUNDATION_EXPORT NSString * _Nullable DSHAgentArgumentsSHA256(
    NSString *name,
    NSString *argumentsJSON,
    NSError **error);
/// Whether a tool accepts these arguments (schema, workspace-relative paths,
/// write size).  On refusal, `failureCode` is E_AGENT_BAD_PATH or
/// E_AGENT_BAD_ARGUMENTS and `reason` a value-free token (lowercase and
/// underscores, at most 64 bytes) suitable as model-directed feedback.
FOUNDATION_EXPORT BOOL DSHAgentToolArgumentsAccepted(
    NSString *name,
    NSDictionary *arguments,
    NSString * _Nullable * _Nullable failureCode,
    NSString * _Nullable * _Nullable reason);
FOUNDATION_EXPORT NSString * _Nullable DSHAgentIdempotencyKeyForLocator(
    NSDictionary *locator,
    NSString *rootFingerprintSHA256,
    NSString *argumentsSHA256,
    NSError **error);

/// Validates one exact redacted NativeAgentToolFeedbackV1 JSON string and
/// returns no raw/native error detail to callers.
FOUNDATION_EXPORT BOOL DSHAgentValidateNativeToolFeedbackString(
    NSString *feedbackJSON,
    NSError **error);

NS_ASSUME_NONNULL_END
