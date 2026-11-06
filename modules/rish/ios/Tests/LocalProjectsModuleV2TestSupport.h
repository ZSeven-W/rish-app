#pragma once

#import <XCTest/XCTest.h>
#import "../../../../modules/rish/ios/Sources/LocalProjectAccess.h"
#import "../../../../modules/rish/ios/Sources/LocalWorkspaceAccess.h"

NS_ASSUME_NONNULL_BEGIN

// Shared declarations for the real workspace/project integration fixture.
@interface LocalProjectsModule : NSObject
@end

@interface LocalProjectsModule (V2Testing)
- (nullable NSDictionary *)clonePublicRepositoryAtURL:(NSURL *)remoteURL
                                                 name:(NSString *)name
                                             proxyURL:(nullable NSString *)proxyURL
                                           operation:(nullable id)operation
                                        sshProfileId:(nullable NSString *)sshProfileId
                                               error:(NSError **)error;
- (nullable NSDictionary *)v2AttachWorkspaceProject:(NSDictionary *)request
                                               error:(NSError **)error;
- (BOOL)v2ReconcileAttachStagingForWorkspaceId:(NSString *)workspaceId
                                          error:(NSError **)error;
- (nullable NSDictionary *)v2ProjectForWorkspace:(NSDictionary *)root
                                             error:(NSError **)error;
- (DSHLocalProjectAccess *)v2LegacyProjectAccess;
- (instancetype)initWithSupportURL:(nullable NSURL *)support
                       projectAccess:(DSHLocalProjectAccess *)projectAccess;
@end

@interface LocalProjectsModule (SSHBridgeTesting)
- (void)fetchForProject:(id)projectIdValue
           sshProfileId:(id)profileIdValue
               resolver:(void (^)(id result))resolve
               rejecter:(void (^)(NSString *code, NSString *message, NSError *error))reject;
- (void)listWithResolver:(void (^)(id result))resolve
                rejecter:(void (^)(NSString *code, NSString *message, NSError *error))reject;
@end

@interface DSHLocalWorkspaceAccess (V2CapabilityTesting)
- (NSSet<NSString *> *)operationalCapabilitiesForMetadataRecord:
    (NSDictionary *)record
                                                        authority:
    (NSDictionary *)authority
                                                           status:(NSString *)status;
@end

@interface LocalProjectsModuleV2Tests : XCTestCase
@property(nonatomic, strong) NSURL *privateRoot;
@property(nonatomic, strong) NSURL *documentsRoot;
@property(nonatomic, strong) DSHLocalWorkspaceAccess *workspaceAccess;
@property(nonatomic, strong) DSHLocalProjectAccess *projectAccess;
@property(nonatomic, strong, nullable) LocalProjectsModule *module;
@property(nonatomic, copy) NSDictionary *root;
@property(nonatomic, strong) NSURL *legacyBaseRoot;
@end

NS_ASSUME_NONNULL_END
