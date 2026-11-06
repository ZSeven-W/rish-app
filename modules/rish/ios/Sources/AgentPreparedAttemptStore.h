#import <Foundation/Foundation.h>

#import "AgentNativeWAL.h"
#import "AgentRootResolver.h"
#import "AgentToolRegistry.h"
#import "AgentTranscriptStore.h"
#import "SessionSnapshotStore.h"

NS_ASSUME_NONNULL_BEGIN

@class DSHAssistantTaskExecutor;

/// Native-only prepared Agent authority.  This store owns the one durable
/// authority row per `(task_id, attempt_id)` and its operation/result replay
/// relation.  Its public methods return only safe projections; raw session
/// messages and transcript/tool arguments never leave native storage.
@interface DSHAgentPreparedAttemptStore : NSObject

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithWAL:(DSHAgentNativeWAL *)wal
              rootResolver:(DSHAgentRootResolver *)rootResolver
        sessionSnapshotStore:(DSHSessionSnapshotStore *)sessionSnapshotStore
             transcriptStore:(nullable DSHAgentTranscriptStore *)transcriptStore
    NS_DESIGNATED_INITIALIZER;

/// Resolves the committed schema-9 checkpoint, freezes root/registry/policy,
/// creates an empty protected transcript, and atomically commits the authority
/// and `prepare_agent_attempt` operation.  Exact retries return a safe replay;
/// a different root/revision/registry/policy never replaces the authority.
- (nullable NSDictionary *)prepareAgentAttemptWithRequest:(NSDictionary *)request
                                                    error:(NSError **)error;

/// Requeries the durable authority and returns the same safe attempt
/// projection without loading or returning transcript messages.
- (nullable NSDictionary *)preparedAttemptForTaskId:(NSString *)taskId
                                          attemptId:(NSString *)attemptId
                                              error:(NSError **)error;

/// Native pre-effect root assertion for the executor lane.  It compares the
/// supplied root with both the frozen authority and the current workspace
/// binding, failing closed on replacement/revision drift.
- (BOOL)validatePreparedRoot:(NSDictionary *)root
                      taskId:(NSString *)taskId
                   attemptId:(NSString *)attemptId
                        error:(NSError **)error;

/// Returns the detached native authority snapshot for other native services.
/// This selector is not a UI bridge method; callers must still run the root
/// assertion above before any effect.
- (nullable NSDictionary *)nativeAuthorityForTaskId:(NSString *)taskId
                                          attemptId:(NSString *)attemptId
                                              error:(NSError **)error;

@property(nonatomic, strong, readonly) DSHAgentNativeWAL *wal;
@property(nonatomic, strong, readonly) DSHAgentRootResolver *rootResolver;
@property(nonatomic, strong, readonly) DSHAgentToolRegistry *toolRegistry;
@property(nonatomic, strong, readonly) DSHSessionSnapshotStore *sessionSnapshotStore;
@property(nonatomic, strong, readonly) DSHAgentTranscriptStore *transcriptStore;
@property(nonatomic, strong, readonly) DSHAssistantTaskExecutor *assistantTaskExecutor;

@end

@compatibility_alias AgentPreparedAttemptStore DSHAgentPreparedAttemptStore;

NS_ASSUME_NONNULL_END
