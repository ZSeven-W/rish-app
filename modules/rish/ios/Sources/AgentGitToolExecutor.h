#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class DSHAgentRootResolver;
@class DSHGitPushCancelToken;

/// Native-only Git executor over the current LocalWorkspace/LocalProjects
/// authority services.  It never resolves a repository from project_id alone.
@interface DSHAgentGitToolExecutor : NSObject

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithRootResolver:(DSHAgentRootResolver *)rootResolver
    NS_DESIGNATED_INITIALIZER;

- (nullable NSDictionary *)prepareToolNamed:(NSString *)name
                                  arguments:(NSDictionary *)arguments
                                       root:(NSDictionary *)root
                                      error:(NSError **)error;
- (nullable NSDictionary *)executeToolNamed:(NSString *)name
                                  arguments:(NSDictionary *)arguments
                                       root:(NSDictionary *)root
                               precondition:(NSDictionary *)precondition
                                      error:(NSError **)error;
/// git_push only: the token lets the runtime coordinator interrupt the
/// bounded network phase cooperatively. Ignored for other tools.
- (nullable NSDictionary *)executeToolNamed:(NSString *)name
                                  arguments:(NSDictionary *)arguments
                                       root:(NSDictionary *)root
                               precondition:(NSDictionary *)precondition
                                cancelToken:(nullable DSHGitPushCancelToken *)cancelToken
                                      error:(NSError **)error;
- (nullable NSDictionary *)recoverToolNamed:(NSString *)name
                                  arguments:(NSDictionary *)arguments
                                       root:(NSDictionary *)root
                               precondition:(NSDictionary *)precondition
                                      error:(NSError **)error;

@property(nonatomic, strong, readonly) DSHAgentRootResolver *rootResolver;
/// The person's HTTPS proxy for Git, as the last committed session holds it
/// (canonical, or nil for none). Read at each remote step; the commit that
/// approved the call is in that session. nil provider = no proxy.
@property(nonatomic, copy, nullable) NSString *_Nullable (^proxyProvider)(void);

@end

@compatibility_alias AgentGitToolExecutor DSHAgentGitToolExecutor;

NS_ASSUME_NONNULL_END
