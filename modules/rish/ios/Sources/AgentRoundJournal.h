#import <Foundation/Foundation.h>

#import "AgentNativeWAL.h"

NS_ASSUME_NONNULL_BEGIN

/// The durable provider-round view over DSHAgentNativeWAL. A round is located
/// by task, attempt, round ID, and round index; an execution-row CAS is never
/// reused as round authority.
@interface DSHAgentRoundJournal : NSObject

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithWAL:(DSHAgentNativeWAL *)wal
    NS_DESIGNATED_INITIALIZER;

/// Native schema-3 round view used by AgentProviderRoundService.  These
/// selectors are native-only; no provider body, transcript message, owner,
/// or row is exported through UI.  They are a facade over the shared Rust
/// core (modules/rish/core, `rish_agent_round_reduce`); the older schema-2
/// selectors were removed once nothing but low-level tests used them.
- (nullable NSDictionary *)createAgentRoundV3WithInsertCAS:(NSDictionary *)insertCAS
                                           exactRoundStart:(NSDictionary *)round
                                                     error:(NSError **)error;
- (nullable NSDictionary *)claimAgentRoundV3WithLocator:(NSDictionary *)locator
                                    expectedRowRevision:(NSNumber *)revision
                                                   owner:(NSDictionary *)owner
                                                     error:(NSError **)error;
- (nullable NSDictionary *)markAgentRoundV3DispatchedWithCAS:(NSDictionary *)cas
                                                        error:(NSError **)error;
- (nullable NSDictionary *)completeAgentRoundV3WithLocator:(NSDictionary *)locator
                                               expectedCAS:(NSDictionary *)cas
                                                  messages:(NSArray *)messages
                                         completionReceipt:(NSDictionary *)receipt
                                              terminalKind:(NSString *)terminalKind
                                                    calls:(NSArray *)calls
                                                     root:(NSDictionary *)root
                                                     error:(NSError **)error;
- (nullable NSDictionary *)cancelAgentRoundV3WithCAS:(NSDictionary *)cas
                                               error:(NSError **)error;
- (nullable NSDictionary *)reconcileAgentRoundV3OwnerLossWithLocator:(NSDictionary *)locator
                                                          expectedCAS:(NSDictionary *)cas
                                                                 error:(NSError **)error;
/// `evidence` is what the transport heard when the provider refused the
/// request -- `{kind: http_rejected, http_status, owner}`. The core alone
/// decides whether it proves the round was turned away.
- (nullable NSDictionary *)reconcileAgentRoundV3OwnerLossWithLocator:(NSDictionary *)locator
                                                          expectedCAS:(NSDictionary *)cas
                                                    transportEvidence:(nullable NSDictionary *)evidence
                                                                 error:(NSError **)error;
/// A known local preflight cause. The core ignores it after any dispatch.
- (nullable NSDictionary *)reconcileAgentRoundV3OwnerLossWithLocator:(NSDictionary *)locator
                                                      expectedCAS:(NSDictionary *)cas
                                                      failureCode:(NSString *)failureCode
                                                            error:(NSError **)error;
- (nullable NSDictionary *)queryAgentRoundV3WithLocator:(NSDictionary *)locator
                                                     error:(NSError **)error;

@property(nonatomic, strong, readonly) DSHAgentNativeWAL *wal;

@end

@compatibility_alias AgentRoundJournal DSHAgentRoundJournal;

/// Full persisted-row validator used by WAL bootstrap before any typed view
/// is allowed to read or mutate the row.
FOUNDATION_EXPORT BOOL DSHAgentValidateRoundNativeEntryV2(
    NSDictionary *row,
    NSError **error);

NS_ASSUME_NONNULL_END
