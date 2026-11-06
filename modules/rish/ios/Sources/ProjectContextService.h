#import <Foundation/Foundation.h>

#import "LocalProjectAccess.h"
#import "ProjectContextPolicy.h"
#import "ProjectContextStore.h"

NS_ASSUME_NONNULL_BEGIN

@class DSHLocalWorkspaceAccess;

FOUNDATION_EXPORT NSErrorDomain const DSHProjectContextServiceErrorDomain;

typedef NS_ERROR_ENUM(DSHProjectContextServiceErrorDomain,
                      DSHProjectContextServiceErrorCode) {
  DSHProjectContextServiceErrorInvalidArgument = 1,
  DSHProjectContextServiceErrorProjectUnavailable = 2,
  DSHProjectContextServiceErrorChanged = 3,
  DSHProjectContextServiceErrorSecret = 4,
  DSHProjectContextServiceErrorBudgetExceeded = 5,
  DSHProjectContextServiceErrorStorage = 6,
  DSHProjectContextServiceErrorTimeout = 7,
  DSHProjectContextServiceErrorConsent = 8,
  DSHProjectContextServiceErrorIntegrity = 9,
  DSHProjectContextServiceErrorSnapshotMissing = 10,
};

typedef void (^DSHProjectContextServiceHook)(NSString *stage,
                                              NSString *_Nullable relativePath);

@interface DSHProjectContextService : NSObject

- (instancetype)init;
- (instancetype)initWithProjectAccess:(DSHLocalProjectAccess *)projectAccess
                                  store:(DSHProjectContextStore *)store
                                 policy:(DSHProjectContextPolicy *)policy
                                  clock:(DSHProjectContextClock)clock
                    identifierGenerator:
                        (DSHProjectContextIdentifierGenerator)identifierGenerator
                                   hook:(nullable DSHProjectContextServiceHook)hook
    NS_DESIGNATED_INITIALIZER;

/// Workspace-routed composition root. V2 operations require this resolver;
/// the older project-id methods remain available only for the explicit legacy
/// adapter and existing migration tests.
- (instancetype)initWithProjectAccess:(DSHLocalProjectAccess *)projectAccess
                       workspaceAccess:(nullable DSHLocalWorkspaceAccess *)workspaceAccess
                                  store:(DSHProjectContextStore *)store
                                 policy:(DSHProjectContextPolicy *)policy
                                  clock:(DSHProjectContextClock)clock
                    identifierGenerator:
                        (DSHProjectContextIdentifierGenerator)identifierGenerator
                                   hook:(nullable DSHProjectContextServiceHook)hook;

- (nullable NSDictionary *)listCandidatesForProjectId:(NSString *)projectId
                                                  query:(NSString *)query
                                                 cursor:(nullable NSString *)cursor
                                                  error:(NSError **)error;
- (nullable NSDictionary *)prepareSelection:(NSDictionary *)selection
                                       error:(NSError **)error;
- (nullable NSDictionary *)confirmSnapshotId:(NSString *)snapshotId
                                        error:(NSError **)error;
- (nullable NSDictionary *)inspectSnapshotId:(NSString *)snapshotId
                                        error:(NSError **)error;
- (BOOL)discardSnapshotId:(NSString *)snapshotId error:(NSError **)error;
- (nullable NSData *)verifiedEnvelopeForSnapshotId:(NSString *)snapshotId
                                   consentReceiptId:(NSString *)consentReceiptId
                                        requestBind:(NSDictionary *)requestBind
                                            receipt:
                                                (NSDictionary *_Nullable *_Nullable)receipt
                                              error:(NSError **)error;

/// Native Project Context V2 core. Every request carries the exact
/// WorkspaceRootRefV1 and every operation reacquires/revalidates the
/// workspace/project/repository lease before opening, committing, and
/// returning. These methods never fall back to a project-id or global path.
- (nullable NSDictionary *)listCandidatesV2:(NSDictionary *)request
                                      error:(NSError **)error;
- (nullable NSDictionary *)listCandidatesV2ForRoot:(NSDictionary *)rootRef
                                              query:(NSString *)query
                                             cursor:(nullable NSString *)cursor
                                              error:(NSError **)error;
- (nullable NSDictionary *)prepareCandidateV2:(NSDictionary *)request
                                         error:(NSError **)error;
- (nullable NSDictionary *)prepareCandidateV2WithRoot:(NSDictionary *)rootRef
                                       conversationId:(NSString *)conversationId
                                              modelId:(NSString *)modelId
                                               policy:(NSString *)policy
                                        selectedPaths:(NSArray<NSString *> *)selectedPaths
                                                error:(NSError **)error;
- (nullable NSDictionary *)confirmSnapshotV2:(NSDictionary *)request
                                        error:(NSError **)error;
- (nullable NSDictionary *)confirmSnapshotV2Id:(NSString *)snapshotId
                                           root:(NSDictionary *)rootRef
                                           error:(NSError **)error;
- (nullable NSDictionary *)inspectSnapshotV2:(NSDictionary *)request
                                        error:(NSError **)error;
- (nullable NSDictionary *)inspectSnapshotV2Id:(NSString *)snapshotId
                                           root:(NSDictionary *)rootRef
                                           error:(NSError **)error;
/// Detaches and deletes only the snapshot bound to the supplied V2 root. The
/// result is an exact, value-free status receipt; stale roots, mismatched
/// source relations, and unbound references fail closed.
- (nullable NSDictionary *)discardSnapshotV2:(NSDictionary *)request
                                        error:(NSError **)error;
- (nullable NSDictionary *)discardSnapshotV2Id:(NSString *)snapshotId
                                          root:(NSDictionary *)rootRef
                                         error:(NSError **)error;
- (nullable NSData *)verifiedEnvelopeV2:(NSDictionary *)request
                                receipt:(NSDictionary *_Nullable *_Nullable)receipt
                                  error:(NSError **)error;
/// Native Agent continuation only: returns the same consented snapshot bytes
/// after tools change files. Still verifies protection, consent, digest, root
/// identity and live lease. Never exposed as a UI freshness bypass.
- (nullable NSData *)verifiedFrozenEnvelopeV2:(NSDictionary *)request
                                     receipt:(NSDictionary *_Nullable *_Nullable)receipt
                                       error:(NSError **)error;
- (nullable NSData *)verifiedEnvelopeV2ForSnapshotId:(NSString *)snapshotId
                                    consentReceiptId:(NSString *)consentReceiptId
                                                root:(NSDictionary *)rootRef
                                      conversationId:(NSString *)conversationId
                                             modelId:(NSString *)modelId
                                              policy:(NSString *)policy
                                               receipt:(NSDictionary *_Nullable *_Nullable)receipt
                                                 error:(NSError **)error;
- (nullable NSData *)verifiedEnvelopeV2ForSnapshotId:(NSString *)snapshotId
                                    consentReceiptId:(NSString *)consentReceiptId
                                         requestBind:(NSDictionary *)requestBind
                                             receipt:(NSDictionary *_Nullable *_Nullable)receipt
                                               error:(NSError **)error;

@end

/// One process-wide composition root. All production bridge instances share
/// its project access, protected store, policy cursor key, clock, and ids.
FOUNDATION_EXPORT DSHProjectContextService *DSHSharedProjectContextService(void);

NS_ASSUME_NONNULL_END
