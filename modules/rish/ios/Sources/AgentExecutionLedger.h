#import <Foundation/Foundation.h>

#import "AgentNativeWAL.h"

NS_ASSUME_NONNULL_BEGIN

/// Idempotent execution-row view over DSHAgentNativeWAL. The complete V2
/// locator (including round/call identity and idempotency key) is required by
/// every query and CAS operation.
@interface DSHAgentExecutionLedger : NSObject

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithWAL:(DSHAgentNativeWAL *)wal
    NS_DESIGNATED_INITIALIZER;

- (nullable NSDictionary *)insertAgentExecutionIntentWithInsertCAS:
    (NSDictionary *)insertCAS
                                                  argumentsJSON:(NSString *)argumentsJSON
                                                   exactIntent:(NSDictionary *)intent
                                                         error:(NSError **)error;

- (nullable NSDictionary *)claimAgentExecutionWithLocator:(NSDictionary *)locator
                                      expectedRowRevision:(NSNumber *)revision
                                                     owner:(NSDictionary *)owner
                                                     error:(NSError **)error;

- (nullable NSDictionary *)casAgentExecutionWithCAS:(NSDictionary *)cas
                                               patch:(NSDictionary *)patch
                                               error:(NSError **)error;

- (nullable NSDictionary *)heartbeatAgentExecutionWithCAS:(NSDictionary *)cas
                                                    owner:(NSDictionary *)owner
                                                    error:(NSError **)error;

- (nullable NSDictionary *)markAgentExecutionDispatchedWithCAS:(NSDictionary *)cas
                                                          error:(NSError **)error;

- (nullable NSDictionary *)queryAgentExecutionWithLocator:(NSDictionary *)locator
                                         expectedTranscript:(NSDictionary *)transcript
                                                        root:(NSDictionary *)root
                                                      error:(NSError **)error;

/// Whole-batch native preparation used by AgentToolBatchService.  `request`
/// is native-private: raw argument JSON and operation preconditions are loaded
/// from the protected transcript/executors and never cross app UI.  All
/// executable intents, write reservation accounting, and the versioned batch
/// record commit in one WAL transaction; durable-deny projections create no
/// execution row and no effect gate.
- (nullable NSDictionary *)prepareAgentToolBatchWithRequest:(NSDictionary *)request
                                                       error:(NSError **)error;

/// Opens the one-shot effect gate for an already committed batch manifest.
- (nullable NSDictionary *)openAgentWriteBatchEffectGateWithRequest:
    (NSDictionary *)request
                                                             error:(NSError **)error;

- (nullable NSDictionary *)releaseWriteReservationWithCAS:(NSDictionary *)cas
                                                    error:(NSError **)error;

/// A single transaction for the normal native executor completion path:
/// ledger CAS + transcript-after reference + exact redacted receipt. The
/// transcript message content is already canonical protected feedback bytes.
- (nullable NSDictionary *)settleAgentExecutionWithCAS:(NSDictionary *)cas
                                                  patch:(NSDictionary *)patch
                                                 message:(NSDictionary *)message
                                                   error:(NSError **)error;

/// Compound high-level settlement. `operation` contains only the started
/// operation identity/request hash and the safe effect-occurrence bit. Ledger
/// settlement, transcript/authority advance, and immutable operation result
/// snapshot commit in one WAL candidate.
- (nullable NSDictionary *)settleAgentExecutionWithCAS:(NSDictionary *)cas
                                                  patch:(NSDictionary *)patch
                                                message:(NSDictionary *)message
                                              operation:(nullable NSDictionary *)operation
                                                  error:(NSError **)error;

/// `patch` is exactly `{state:"cancelled"}`. Native derives the cancelled
/// feedback, transcript-after reference, receipt, and any reservation release
/// atomically; callers cannot supply terminal refs or protected content.
- (nullable NSDictionary *)cancelAgentExecutionWithCAS:(NSDictionary *)cas
                                                 patch:(NSDictionary *)patch
                                                 error:(NSError **)error;

/// Reconciliation is explicit and operation-specific. It never retries a
/// settled, cancelled, unknown, or ambiguous mutation automatically.
- (nullable NSDictionary *)reconcileAgentExecutionWithCAS:(NSDictionary *)cas
                                                    patch:(NSDictionary *)patch
                                                    error:(NSError **)error;

/// Native-private in-transaction denial feedback used by
/// DSHAgentToolBatchService for user denials.  It appends one exact protected
/// tool message to the open transcript row and advances the prepared
/// authority in the caller's WAL transaction, returning only the new
/// transcript-after reference.  It never opens an effect gate and never
/// mutates a ledger row.
- (nullable NSDictionary *)appendDenialFeedbackInState:
    (NSMutableDictionary *)state
                                          taskId:(NSString *)taskId
                                       attemptId:(NSString *)attemptId
                                            root:(NSDictionary *)root
                              expectedTranscript:(NSDictionary *)expectedTranscript
                                          policy:(NSDictionary *)policy
                          expectedReservedWriteBytes:(NSNumber *)expectedReservedWriteBytes
                                           callId:(NSString *)callId
                                      roundIndex:(NSNumber *)roundIndex
                                     feedbackJSON:(NSString *)feedbackJSON
                                       timestamp:(NSString *)timestamp
                                           error:(NSError **)error;

/// Native-private in-transaction settlement of a user-denied approval.
/// Composes the feedback append above with a fail-closed ledger settlement:
/// the matching `intent` row (never dispatched) becomes `settled` with a
/// `denied` receipt whose failure code is `E_AGENT_DENIED_BY_USER`, its
/// transcript-after is the appended-feedback reference, and the prepared
/// authority advances to the same reference.  Returns
/// `{receipt, transcript}` or nil; the caller owns the surrounding WAL
/// transaction.  It never opens an effect gate and never fabricates an
/// effect or settled facts.
- (nullable NSDictionary *)settleDeniedApprovalInState:
    (NSMutableDictionary *)state
                                          locator:(NSDictionary *)locator
                                             root:(NSDictionary *)root
                              expectedTranscript:(NSDictionary *)expectedTranscript
                                          policy:(NSDictionary *)policy
                          expectedReservedWriteBytes:(NSNumber *)expectedReservedWriteBytes
                                     feedbackJSON:(NSString *)feedbackJSON
                                       timestamp:(NSString *)timestamp
                                           error:(NSError **)error;

@property(nonatomic, strong, readonly) DSHAgentNativeWAL *wal;

@end

@compatibility_alias AgentExecutionLedger DSHAgentExecutionLedger;

FOUNDATION_EXPORT BOOL DSHAgentValidateExecutionLedgerEntryV2(
    NSDictionary *row,
    NSError **error);

NS_ASSUME_NONNULL_END
