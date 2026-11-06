#import <Foundation/Foundation.h>
@class DSHAgentRootResolver, DSHAgentWorkspaceToolExecutor, DSHRuntimeEnvironmentStore;
@class DSHRuntimeProgramVM, DSHRuntimeServiceVM;
NS_ASSUME_NONNULL_BEGIN
typedef BOOL (^DSHAgentRuntimeOwnerValidator)(BOOL executionIntentRequired);

@interface DSHAgentRuntimeToolExecutor : NSObject
+ (instancetype)executorForWorkspaceExecutor:(DSHAgentWorkspaceToolExecutor *)workspace;
+ (nullable instancetype)existingExecutorForWorkspaceExecutor:(DSHAgentWorkspaceToolExecutor *)workspace;
- (instancetype)initWithResolver:(DSHAgentRootResolver *)resolver store:(DSHRuntimeEnvironmentStore *)store;
- (NSDictionary *)prepareToolNamed:(NSString *)name arguments:(NSDictionary *)arguments root:(NSDictionary *)root;
/// Register after native dispatch and before leaving the serialization queue.
- (BOOL)registerToolNamed:(NSString *)name arguments:(NSDictionary *)arguments root:(NSDictionary *)root
                    owner:(NSDictionary *)owner precondition:(NSDictionary *)precondition
                validator:(DSHAgentRuntimeOwnerValidator)validator;
- (NSDictionary *)executeToolNamed:(NSString *)name arguments:(NSDictionary *)arguments root:(NSDictionary *)root
                             owner:(NSDictionary *)owner precondition:(NSDictionary *)precondition;
- (NSDictionary *)recoverToolNamed:(NSString *)name arguments:(NSDictionary *)arguments root:(NSDictionary *)root
                             owner:(NSDictionary *)owner precondition:(NSDictionary *)precondition;
- (void)cancelLocator:(NSDictionary *)locator;
/// Out-of-band UI hint: only an immutable native registered target can match.
- (void)signalCancelRequest:(NSDictionary *)request;
- (void)cancelAttempt:(NSString *)attemptId;
- (void)cancelAll;
/// Reclaim only after the durable ledger returned its operation result.
- (void)acknowledgeSettlementOwner:(NSDictionary *)owner;
/// Native injection only; production factories always use the controlled bundle.
@property(nonatomic, copy) DSHRuntimeProgramVM *(^programFactory)(void);
@property(nonatomic, copy) DSHRuntimeServiceVM *(^serviceFactory)(void);
@end
NS_ASSUME_NONNULL_END
