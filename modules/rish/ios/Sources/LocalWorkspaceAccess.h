#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const DSHLocalWorkspaceAccessErrorDomain;

typedef NS_ERROR_ENUM(DSHLocalWorkspaceAccessErrorDomain,
                      DSHLocalWorkspaceAccessErrorCode) {
  DSHLocalWorkspaceAccessErrorInvalid = 1,
  DSHLocalWorkspaceAccessErrorNotFound = 2,
  DSHLocalWorkspaceAccessErrorBusy = 3,
  DSHLocalWorkspaceAccessErrorPickerBusy = 4,
  DSHLocalWorkspaceAccessErrorSelectionExpired = 5,
  DSHLocalWorkspaceAccessErrorRevisionStale = 6,
  DSHLocalWorkspaceAccessErrorRevisionOverflow = 7,
  DSHLocalWorkspaceAccessErrorStatusStale = 8,
  DSHLocalWorkspaceAccessErrorRevoked = 9,
  DSHLocalWorkspaceAccessErrorUnavailable = 10,
  DSHLocalWorkspaceAccessErrorNotDownloaded = 11,
  DSHLocalWorkspaceAccessErrorImportRequired = 12,
  DSHLocalWorkspaceAccessErrorCapability = 13,
  DSHLocalWorkspaceAccessErrorRootChanged = 14,
  DSHLocalWorkspaceAccessErrorReferenced = 15,
  DSHLocalWorkspaceAccessErrorConfirmation = 16,
  DSHLocalWorkspaceAccessErrorConflict = 17,
  DSHLocalWorkspaceAccessErrorPersistence = 18,
  DSHLocalWorkspaceAccessErrorIO = 19,
};

typedef NSDate * _Nonnull (^DSHLocalWorkspaceClock)(void);
typedef NSString * _Nonnull (^DSHLocalWorkspaceUUIDGenerator)(void);
typedef BOOL (^DSHLocalWorkspaceLegacyResolver)(
    NSString *projectId,
    NSDictionary * _Nullable * _Nullable evidence,
    NSError * _Nullable * _Nullable error);
typedef BOOL (^DSHLocalWorkspaceFaultHook)(NSString *stage);

/// A descriptor-relative authority lease. The descriptor is owned by the
/// lease and is closed when the lease is released; callers cannot provide a
/// path or retain the descriptor through the public bridge.
@interface DSHLocalWorkspaceLease : NSObject
@property(nonatomic, readonly) NSString *workspaceId;
@property(nonatomic, readonly) NSUInteger bindingRevision;
@property(nonatomic, readonly) int rootDescriptor;
@property(nonatomic, readonly) BOOL supportsGit;
@property(nonatomic, readonly) BOOL supportsProjectContext;
@end

/// Native-only mutation guard for the exact workspace authority domain. The
/// guard owns the shared `authority.lock` flock and releases it on dealloc.
/// It never crosses the app UI bridge and must not be held while calling
/// APIs that acquire workspace authority internally.
@interface DSHLocalWorkspaceAuthorityMutationGuard : NSObject
@end

/// Shared pure revision rule for future bounded authority mutations.
FOUNDATION_EXPORT BOOL DSHLocalWorkspaceValidateBindingRevisionAdvance(
    NSNumber *currentRevision,
    NSNumber *proposedRevision,
    NSError * _Nullable * _Nullable error);

/// Private native authority core. It owns no native bridge and therefore cannot
/// be used by the UI to submit arbitrary registry or authority records.
/// Later tasks expose only bounded, purpose-specific bridge operations.
@interface DSHLocalWorkspaceAccess : NSObject

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithPrivateRootURL:(NSURL *)privateRootURL
                                  clock:(DSHLocalWorkspaceClock)clock
                          UUIDGenerator:(DSHLocalWorkspaceUUIDGenerator)UUIDGenerator
                         legacyResolver:(DSHLocalWorkspaceLegacyResolver)legacyResolver
                              faultHook:(nullable DSHLocalWorkspaceFaultHook)faultHook;

/// Testable/application-owned Documents container. Production callers should
/// use the convenience initializer above, which resolves NSDocumentDirectory
/// internally; tests inject a temporary container to avoid touching user data.
- (instancetype)initWithPrivateRootURL:(NSURL *)privateRootURL
                     documentsRootURL:(nullable NSURL *)documentsRootURL
                                  clock:(DSHLocalWorkspaceClock)clock
                         UUIDGenerator:(DSHLocalWorkspaceUUIDGenerator)UUIDGenerator
                        legacyResolver:(DSHLocalWorkspaceLegacyResolver)legacyResolver
                             faultHook:(nullable DSHLocalWorkspaceFaultHook)faultHook
    NS_DESIGNATED_INITIALIZER;

- (BOOL)ensurePrivateLayoutWithError:(NSError **)error;

/// Acquires the shared workspace registry/producer mutation boundary. Native
/// composition code uses this after its own outer lock and retains it across
/// proof, durable commit, second proof, and receipt publication.
- (nullable DSHLocalWorkspaceAuthorityMutationGuard *)
    acquireAuthorityMutationGuard:(NSError **)error NS_RETURNS_RETAINED;

/// Non-reentrant exact registry proof for callers already holding `guard`.
/// Documents-owned and granted roots are accepted only at the exact current
/// revision with a valid authority; legacy-app-owned roots fail closed.
- (BOOL)validateWorkspaceForClearanceId:(NSString *)workspaceId
                        bindingRevision:(NSUInteger)revision
                 authorityMutationGuard:
                     (DSHLocalWorkspaceAuthorityMutationGuard *)guard
                                   error:(NSError **)error;

/// Returns metadata-only WorkspaceDescriptorV2 dictionaries. No root URL,
/// bookmark, descriptor, inode, or native error is projected.
- (nullable NSArray<NSDictionary *> *)listWorkspaceMetadataWithError:
    (NSError **)error;

/// A nil revision is a metadata probe and always returns zero operational
/// capabilities. Operational resolution requires the exact current revision.
- (nullable NSDictionary *)resolveWorkspaceId:(NSString *)workspaceId
                       expectedBindingRevision:(nullable NSNumber *)revision
                          requiredCapabilities:(NSArray<NSString *> *)capabilities
                                         error:(NSError **)error;

/// Resolves one immutable native lease. Only Documents-owned roots may return
/// a retained descriptor; security-scoped roots must use
/// performCoordinatedWorkspaceOperationForId: below. Security-scoped roots
/// currently advertise and support only coordinated read/write; Git and
/// Project Context require a native consumer before being advertised.
- (nullable DSHLocalWorkspaceLease *)leaseWorkspaceId:(NSString *)workspaceId
                               expectedBindingRevision:(NSUInteger)revision
                                  requiredCapabilities:(NSSet<NSString *> *)capabilities
                                                 error:(NSError **)error;

/// Executes synchronously on the native serial executor. For security-scoped
/// roots this balances security scope and NSFileCoordinator exactly once and
/// closes the descriptor before returning. The block must not escape or be
/// asynchronous.
- (BOOL)performCoordinatedWorkspaceOperationForId:(NSString *)workspaceId
                          expectedBindingRevision:(NSUInteger)revision
                             requiredCapabilities:(NSSet<NSString *> *)capabilities
                                            block:(BOOL (^)(int rootDescriptor,
                                                            NSError **error))block
                                            error:(NSError **)error;

- (nullable NSDictionary *)queryOperationId:(NSString *)operationId
                                        error:(NSError **)error;

/// A1's only purpose-specific authority mutation. The resolver is injected;
/// binding to the real LocalProjectAccess implementation remains a later task.
- (nullable NSDictionary *)bootstrapLegacyProjectId:(NSString *)projectId
                                          operationId:(NSString *)operationId
                                                error:(NSError **)error;

/// Resolves the private legacy project UUID behind an exact workspace binding.
/// This native-only reverse lookup never projects a path, display name, or
/// locator and revalidates the current resolver evidence before returning.
- (nullable NSString *)legacyProjectIdForWorkspaceId:(NSString *)workspaceId
                              expectedBindingRevision:(NSUInteger)revision
                                               error:(NSError **)error;

/// Task B Rish-owned Files-visible root creation. The native implementation
/// accepts only the bounded fields from the bridge create request and returns
/// metadata-only WorkspaceDescriptorV2 dictionaries.
- (nullable NSDictionary *)createRishOwnedWorkspaceWithDisplayName:
    (NSString *)displayName
                                                    operationId:
                                                        (NSString *)operationId
                                                          error:(NSError **)error;

/// Destructive authority operations remain fail-closed until the schema-8
/// clearance receipt/outbox is mounted. These declarations keep that boundary
/// explicit for native callers and focused tests.
- (nullable NSDictionary *)forgetWorkspaceId:(NSString *)workspaceId
                       expectedBindingRevision:(NSNumber *)revision
                                     operationId:(NSString *)operationId
                               clearanceReceiptId:(NSString *)clearanceReceiptId
                                            error:(NSError **)error;

- (nullable NSDictionary *)prepareDeleteOwnedContentForWorkspaceId:
    (NSString *)workspaceId
                       expectedBindingRevision:(NSNumber *)revision
                           clearanceReceiptId:(NSString *)clearanceReceiptId
                                        error:(NSError **)error;

- (nullable NSDictionary *)deleteOwnedContentForWorkspaceId:
    (NSString *)workspaceId
                       expectedBindingRevision:(NSNumber *)revision
                                     operationId:(NSString *)operationId
                               clearanceReceiptId:(NSString *)clearanceReceiptId
                                  confirmationId:(NSString *)confirmationId
                                            error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
