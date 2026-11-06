#import <XCTest/XCTest.h>
#import "DSHAgentRuntimeToolExecutor.h"
#import "AgentNativeWAL.h"
#import "AgentRootResolver.h"
#import "AgentWorkspaceToolExecutor.h"
#import "RuntimeEnvironmentStore.h"
#import "RuntimeProgramServiceVM.h"
#import "RuntimeServiceVM.h"
#import "RuntimeWorkspaceSnapshot.h"
#import "SessionWorkspaceCoordinator.h"

@interface ARTestResolver : DSHAgentRootResolver
- (instancetype)init;
@property(nonatomic, copy) NSDictionary *root;
@property(nonatomic, strong) NSURL *directory;
@end
@interface ARTestLease : DSHRuntimeEnvironmentLease
@property(nonatomic, copy) NSDictionary *testManifest;
@end
@interface ARTestStore : DSHRuntimeEnvironmentStore
@property(nonatomic, copy) NSDictionary *manifest;
@property(nonatomic) BOOL installed;
@property(nonatomic) NSUInteger installs;
@property(nonatomic) NSUInteger releases;
@property(nonatomic) NSUInteger leases;
@property(nonatomic, copy) NSString *pendingToken;
@property(nonatomic, copy) DSHEnvironmentCompletion pendingCompletion;
@property(nonatomic) BOOL cancelledBySettings;
@end
@interface ARTestVM : DSHRuntimeProgramVM
@property(nonatomic) BOOL hold;
@property(nonatomic) NSUInteger starts;
@property(nonatomic) NSInteger exitStatus;
@property(nonatomic, strong) NSData *testOutput;
@property(nonatomic, strong) dispatch_semaphore_t began;
@property(nonatomic, strong) dispatch_semaphore_t ended;
@property(nonatomic) BOOL executedOnCoordinator;
@end
@interface ARTestServiceVM : DSHRuntimeServiceVM
@property(nonatomic) NSUInteger starts;
@property(nonatomic, strong) dispatch_semaphore_t ended;
@property(nonatomic, strong) dispatch_semaphore_t began;
@property(nonatomic) BOOL holdBeforeReady;
@end
@interface AgentRuntimeExecutorTests : XCTestCase
@property(nonatomic, strong) NSURL *directory;
@property(nonatomic, strong) ARTestResolver *resolver;
@property(nonatomic, strong) ARTestStore *store;
@property(nonatomic, strong) DSHAgentWorkspaceToolExecutor *workspace;
@property(nonatomic, strong) DSHAgentRuntimeToolExecutor *executor;
@property(nonatomic, strong) ARTestVM *vm;
- (NSDictionary *)owner:(NSString *)name arguments:(NSDictionary *)arguments attempt:(NSString *)attempt;
- (NSDictionary *)condition:(NSString *)name arguments:(NSDictionary *)arguments;
- (NSDictionary *)invoke:(NSString *)name arguments:(NSDictionary *)arguments owner:(NSDictionary *)owner;
- (NSDictionary *)feedback:(NSDictionary *)effect;
@end
