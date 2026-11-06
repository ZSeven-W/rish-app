#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL DSHAgentIsAssistantTaskTool(NSString *name);
FOUNDATION_EXPORT BOOL DSHAgentIsAssistantMutationTool(NSString *name);
@class DSHAgentRootResolver;

/// App-private task effects. The only mutable implementation is the Rust
/// AssistantStore; this adapter never reads or writes its snapshot itself.
@interface DSHAssistantTaskExecutor : NSObject

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithRootResolver:(DSHAgentRootResolver *)rootResolver;

/// The conversation must come from the committed session, never tool arguments.
- (BOOL)authorizeConversation:(NSDictionary *)conversation
              registryVersion:(NSNumber *)registryVersion
                        error:(NSError **)error;

/// Captured once at preparation and frozen in native authority, never UI state.
- (nullable NSDictionary *)assistantContextForConversation:(NSDictionary *)conversation
                                            registryVersion:(NSNumber *)registryVersion
                                                      error:(NSError **)error;

- (nullable NSDictionary *)prepareToolNamed:(NSString *)name
                                  arguments:(NSDictionary *)arguments
                               conversation:(NSDictionary *)conversation
                                    request:(NSDictionary *)request
                            registryVersion:(NSNumber *)registryVersion
                                      error:(NSError **)error;

/// Called only after the ledger's approval, claim and dispatch gates.
- (nullable NSDictionary *)executeToolNamed:(NSString *)name
                                  arguments:(NSDictionary *)arguments
                               conversation:(NSDictionary *)conversation
                                    request:(NSDictionary *)request
                                    locator:(NSDictionary *)locator
                               precondition:(NSDictionary *)precondition
                            registryVersion:(NSNumber *)registryVersion
                                      error:(NSError **)error;

/// Reads the durable Rust receipt. It cannot create or update a task.
- (nullable NSDictionary *)recoverToolNamed:(NSString *)name
                                  arguments:(NSDictionary *)arguments
                               conversation:(NSDictionary *)conversation
                                    request:(NSDictionary *)request
                                    locator:(NSDictionary *)locator
                               precondition:(NSDictionary *)precondition
                            registryVersion:(NSNumber *)registryVersion
                                      error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
