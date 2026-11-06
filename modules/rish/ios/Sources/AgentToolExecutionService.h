#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class DSHAgentExecutionLedger;
@class DSHAgentGitToolExecutor;
@class DSHAgentNativeWAL;
@class DSHAgentPreparedAttemptStore;
@class DSHAgentTranscriptStore;
@class DSHAgentWorkspaceToolExecutor;
@class DSHGitPushCancelToken;

/// The sole native protected call protocol: validate -> claim -> dispatch ->
/// one effect -> operation-specific reconciliation -> ledger/transcript settle.
@interface DSHAgentToolExecutionService : NSObject

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithWAL:(DSHAgentNativeWAL *)wal
                      ledger:(DSHAgentExecutionLedger *)ledger
               preparedStore:(DSHAgentPreparedAttemptStore *)preparedStore
                 transcripts:(DSHAgentTranscriptStore *)transcripts
           workspaceExecutor:(DSHAgentWorkspaceToolExecutor *)workspaceExecutor
                 gitExecutor:(DSHAgentGitToolExecutor *)gitExecutor
    NS_DESIGNATED_INITIALIZER;

- (nullable NSDictionary *)executeAgentToolWithRequest:(NSDictionary *)request
                                                   error:(NSError **)error;

/// Reconciles one existing full-locator ledger row.  It never dispatches a new
/// effect and returns only a safe tool projection/result.
- (nullable NSDictionary *)recoverAgentToolWithRequest:(NSDictionary *)request
                                                   error:(NSError **)error;

/// Flips the cancellation token registered for an in-flight git_push execution.
/// The locator carries the same task/attempt/round/call identity as the ledger
/// row. A missing registration is a no-op.
- (void)requestCancelForExecutionLocator:(NSDictionary *)locator;
/// Fast hint before UI cancellation enters the coordinator. The runtime
/// executor verifies the entire target against its immutable native record.
- (void)signalRuntimeCancellationRequest:(NSDictionary *)request;
- (void)cancelRuntimeWork;

@end

@compatibility_alias AgentToolExecutionService DSHAgentToolExecutionService;

NS_ASSUME_NONNULL_END
