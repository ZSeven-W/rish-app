#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class RishGuestCgiService;
@class DSHAgentWorkspaceToolExecutor;

/// A coordinator-owned reader. Implementations must delegate to the existing
/// descriptor-relative AgentWorkspaceToolExecutor and return no path outside
/// the frozen root. Its data is native-private and never crosses UI.
typedef void (^DSHAgentGuestCgiReadFile)(NSString *relativePath,
                                         NSDictionary *root,
                                         NSUInteger maximumBytes,
                                         void (^completion)(NSData *_Nullable data,
                                                            NSString *_Nullable revision,
                                                            NSError *_Nullable error));

/// Native durable Agent adapter for start_guest_cgi / stop_guest_cgi.
/// The synchronous effect bridge waits only on the native background worker.
@interface DSHAgentGuestCgiToolExecutor : NSObject

- (instancetype)initWithService:(RishGuestCgiService *)service
                       fileReader:(DSHAgentGuestCgiReadFile)fileReader
    NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
- (void)cancelAttempt:(NSString *)attemptId;
+ (instancetype)executorForWorkspaceExecutor:(DSHAgentWorkspaceToolExecutor *)workspace;
- (NSDictionary *)executeSynchronouslyToolNamed:(NSString *)name arguments:(NSDictionary *)arguments root:(NSDictionary *)root owner:(NSDictionary *)owner precondition:(NSDictionary *)precondition;


- (nullable NSDictionary *)prepareToolNamed:(NSString *)name
                                  arguments:(NSDictionary *)arguments
                                       root:(NSDictionary *)root
                                      error:(NSError **)error;

/// Completion is asynchronous because boot/staging and service teardown are
/// supervised operations. `result` is already reduced to safe WAL facts.
- (void)executeToolNamed:(NSString *)name
               arguments:(NSDictionary *)arguments
                    root:(NSDictionary *)root
                    owner:(NSDictionary *)owner
            precondition:(NSDictionary *)precondition
               completion:(void (^)(NSDictionary *_Nullable result,
                                    NSError *_Nullable error))completion;

- (void)cancelServiceForAttempt:(NSString *)attemptId
                        serviceId:(NSString *)serviceId
                       completion:(void (^)(BOOL stopped,
                                            NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
