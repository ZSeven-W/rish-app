#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class DSHAgentExecutionLedger;
@class DSHAgentNativeWAL;
@class DSHAgentPreparedAttemptStore;
@class DSHAgentProviderRoundService;
@class DSHAgentRoundJournal;
@class DSHAgentToolBatchService;
@class DSHAgentToolExecutionService;
@class DSHAgentTranscriptStore;

@protocol DSHAgentRuntimeCoordinating <NSObject>
- (nullable NSDictionary *)prepareAgentAttempt:(NSDictionary *)request error:(NSError **)error;
- (nullable NSDictionary *)completeAgentRoundV2:(NSDictionary *)request error:(NSError **)error;
- (nullable NSDictionary *)prepareAgentToolBatch:(NSDictionary *)request error:(NSError **)error;
- (nullable NSDictionary *)bindAgentApproval:(NSDictionary *)request error:(NSError **)error;
- (nullable NSDictionary *)executeAgentTool:(NSDictionary *)request error:(NSError **)error;
- (nullable NSDictionary *)cancelAgentAttempt:(NSDictionary *)request error:(NSError **)error;
- (nullable NSDictionary *)readAgentRoundPresentations:(NSDictionary *)request error:(NSError **)error;
- (nullable NSDictionary *)queryAgentAttempt:(NSDictionary *)request error:(NSError **)error;
- (nullable NSDictionary *)queryAgentTool:(NSDictionary *)request error:(NSError **)error;
- (nullable NSDictionary *)recoverAgentAttempt:(NSDictionary *)request error:(NSError **)error;
- (nullable NSDictionary *)finalizeAgentAttempt:(NSDictionary *)request error:(NSError **)error;
- (nullable NSDictionary *)discardAgentAttempt:(NSDictionary *)request error:(NSError **)error;
- (nullable NSDictionary *)interruptAgentAttempt:(NSDictionary *)request error:(NSError **)error;
- (nullable NSDictionary *)queryAgentCleanup:(NSDictionary *)request error:(NSError **)error;
@property(nonatomic, readonly, getter=isAvailable) BOOL available;
@end

/// Native composition for Agent authority operations and read-only display
/// projections.  It owns no app UI surface and returns only detached,
/// redacted Foundation JSON projections.
@interface DSHAgentRuntimeCoordinator : NSObject <DSHAgentRuntimeCoordinating>

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithWAL:(DSHAgentNativeWAL *)wal
               preparedStore:(DSHAgentPreparedAttemptStore *)preparedStore
                roundService:(DSHAgentProviderRoundService *)roundService
                 batchService:(DSHAgentToolBatchService *)batchService
             executionService:(DSHAgentToolExecutionService *)executionService
                  transcripts:(DSHAgentTranscriptStore *)transcripts
                       rounds:(DSHAgentRoundJournal *)rounds
                       ledger:(DSHAgentExecutionLedger *)ledger
    NS_DESIGNATED_INITIALIZER;

/// Focused native-test seam for recovery routing. It is never exposed by native registry
/// and still requires the queried ledger/transcript views to share `wal`.
- (instancetype)initForRecoveryTestingWithWAL:(DSHAgentNativeWAL *)wal
                                  preparedStore:(DSHAgentPreparedAttemptStore *)preparedStore
                                   roundService:(DSHAgentProviderRoundService *)roundService
                               executionService:(DSHAgentToolExecutionService *)executionService
                                    transcripts:(DSHAgentTranscriptStore *)transcripts
                                         ledger:(DSHAgentExecutionLedger *)ledger
    NS_DESIGNATED_INITIALIZER;

- (nullable NSDictionary *)prepareAgentAttempt:(NSDictionary *)request
                                           error:(NSError **)error;
- (nullable NSDictionary *)completeAgentRoundV2:(NSDictionary *)request
                                             error:(NSError **)error;
- (nullable NSDictionary *)prepareAgentToolBatch:(NSDictionary *)request
                                             error:(NSError **)error;
- (nullable NSDictionary *)bindAgentApproval:(NSDictionary *)request
                                         error:(NSError **)error;
- (nullable NSDictionary *)executeAgentTool:(NSDictionary *)request
                                        error:(NSError **)error;
- (nullable NSDictionary *)cancelAgentAttempt:(NSDictionary *)request
                                          error:(NSError **)error;
- (nullable NSDictionary *)readAgentRoundPresentations:(NSDictionary *)request error:(NSError **)error;
- (nullable NSDictionary *)queryAgentAttempt:(NSDictionary *)request
                                         error:(NSError **)error;
- (nullable NSDictionary *)queryAgentTool:(NSDictionary *)request
                                      error:(NSError **)error;
- (nullable NSDictionary *)recoverAgentAttempt:(NSDictionary *)request
                                           error:(NSError **)error;
- (nullable NSDictionary *)finalizeAgentAttempt:(NSDictionary *)request
                                            error:(NSError **)error;
- (nullable NSDictionary *)discardAgentAttempt:(NSDictionary *)request
                                           error:(NSError **)error;
- (nullable NSDictionary *)interruptAgentAttempt:(NSDictionary *)request
                                           error:(NSError **)error;
- (nullable NSDictionary *)queryAgentCleanup:(NSDictionary *)request
                                         error:(NSError **)error;

@property(nonatomic, readonly, getter=isAvailable) BOOL available;
@property(nonatomic, strong, readonly) DSHAgentNativeWAL *wal;
@property(nonatomic, strong, readonly) DSHAgentPreparedAttemptStore *preparedStore;
@property(nonatomic, strong, readonly) DSHAgentProviderRoundService *roundService;
@property(nonatomic, strong, readonly) DSHAgentToolBatchService *batchService;
@property(nonatomic, strong, readonly) DSHAgentToolExecutionService *executionService;
@property(nonatomic, strong, readonly) DSHAgentTranscriptStore *transcripts;
@property(nonatomic, strong, readonly) DSHAgentRoundJournal *rounds;
@property(nonatomic, strong, readonly) DSHAgentExecutionLedger *ledger;

@end

NS_ASSUME_NONNULL_END
