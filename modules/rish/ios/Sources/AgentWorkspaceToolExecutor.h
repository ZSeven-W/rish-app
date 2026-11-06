#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class DSHAgentRootResolver;

/// Native-only descriptor-relative file-tool executor.  Raw paths and content
/// are accepted only from the protected Agent transcript and are never part of
/// an app UI result.
@interface DSHAgentWorkspaceToolExecutor : NSObject

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithRootResolver:(DSHAgentRootResolver *)rootResolver
    NS_DESIGNATED_INITIALIZER;

/// Side-effect-free preflight for list_dir/read_file/write_file.  The returned
/// object contains only the exact native precondition and reservation metadata.
- (nullable NSDictionary *)prepareToolNamed:(NSString *)name
                                  arguments:(NSDictionary *)arguments
                                       root:(NSDictionary *)root
                                      error:(NSError **)error;

/// Performs one descriptor-relative operation after ledger dispatch.  The
/// result is native-private and contains canonical protected feedback plus the
/// exact settled facts used by AgentExecutionLedger.
- (nullable NSDictionary *)executeToolNamed:(NSString *)name
                                  arguments:(NSDictionary *)arguments
                                       root:(NSDictionary *)root
                               precondition:(NSDictionary *)precondition
                                      error:(NSError **)error;

/// Operation-specific recovery.  It never repeats a write.  `status` is one of
/// settled/not_dispatched/ambiguous and carries no path or content.
- (nullable NSDictionary *)recoverToolNamed:(NSString *)name
                                  arguments:(NSDictionary *)arguments
                                       root:(NSDictionary *)root
                               precondition:(NSDictionary *)precondition
                                      error:(NSError **)error;

@property(nonatomic, strong, readonly) DSHAgentRootResolver *rootResolver;

@end

@compatibility_alias AgentWorkspaceToolExecutor DSHAgentWorkspaceToolExecutor;

NS_ASSUME_NONNULL_END
