#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Native-only versioned Agent registry; new iOS attempts use v4. The public projection contains only
/// safe summary metadata; the complete descriptor table used for the toolset
/// digest remains private to the implementation.
@interface DSHAgentToolRegistry : NSObject

- (instancetype)init;

/// Builds the capability-filtered `AgentRuntimeRegistryV2` projection.  The
/// registry digest is the domain-separated digest of the complete native
/// descriptor table, not of caller-provided descriptors.
- (nullable NSDictionary *)registryForRoot:(NSDictionary *)root
                                     error:(NSError **)error;
- (nullable NSDictionary *)registryForRoot:(NSDictionary *)root
                                  version:(NSNumber *)version
                                    error:(NSError **)error;

/// Returns the fixed agent-v1 policy for a valid resolved root.  A nil root
/// has no policy and is rejected by this method.
- (nullable NSDictionary *)policyForRoot:(NSDictionary *)root
                                    error:(NSError **)error;

/// Resolves one provider name to its safe public descriptor.  Unknown names
/// produce the durable-deny descriptor with `agent.unknown`; they never turn
/// into a confirmation request.
- (nullable NSDictionary *)descriptorForToolName:(NSString *)name
                                             root:(NSDictionary *)root
                                            error:(NSError **)error;

/// Returns the complete native descriptor for native provider adapters.  This
/// is private native data and must not be sent to UI or ordinary logs.
- (nullable NSDictionary *)nativeDescriptorForToolName:(NSString *)name
                                                 error:(NSError **)error;

/// Historical requests must select their recorded version AND digest. These
/// overloads never substitute current schemas for a stored v1/v2/v3 table.
- (nullable NSDictionary *)descriptorForToolName:(NSString *)name
                                             root:(NSDictionary *)root
                                         registry:(NSDictionary *)registry
                                            error:(NSError **)error;
- (nullable NSDictionary *)nativeDescriptorForToolName:(NSString *)name
                                             registry:(NSDictionary *)registry
                                                error:(NSError **)error;

/// Recomputes the fixed registry digest and compares it to a frozen value.
- (BOOL)validateToolsetSHA256:(NSString *)toolsetSHA256 error:(NSError **)error;

/// Safe structural validation for a frozen public registry/root relation.
+ (BOOL)validateRegistryProjection:(NSDictionary *)registry
                               root:(NSDictionary *)root
                              error:(NSError **)error;

/// The fixed digest is useful to native provider adapters when constructing a
/// model request.  It is independent of the capability-filtered projection.
@property(nonatomic, copy, readonly) NSString *toolsetSHA256;

@end

@compatibility_alias AgentToolRegistry DSHAgentToolRegistry;

NS_ASSUME_NONNULL_END
