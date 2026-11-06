#import <Foundation/Foundation.h>

#include <git2.h>

NS_ASSUME_NONNULL_BEGIN

@class DSHLocalWorkspaceAccess;
@class DSHLocalWorkspaceLease;

FOUNDATION_EXPORT NSErrorDomain const DSHLocalProjectAccessErrorDomain;

typedef NS_ERROR_ENUM(DSHLocalProjectAccessErrorDomain,
                      DSHLocalProjectAccessErrorCode) {
  DSHLocalProjectAccessErrorInvalidIdentifier = 1,
  DSHLocalProjectAccessErrorStorageUnavailable = 2,
  DSHLocalProjectAccessErrorUnsafeStorage = 3,
  DSHLocalProjectAccessErrorRepositoryUnavailable = 4,
  DSHLocalProjectAccessErrorMetadataInvalid = 5,
  DSHLocalProjectAccessErrorLockTimeout = 6,
  DSHLocalProjectAccessErrorRootAbsent = 7,
};

typedef NS_ENUM(NSInteger, DSHLocalProjectAccessMode) {
  DSHLocalProjectAccessModeRead = 0,
  DSHLocalProjectAccessModeWrite = 1,
};

typedef void (^DSHLocalProjectAccessHook)(NSString *stage);

/// Native-only project binding supplied by the Git/project owner. The
/// dictionary is never bridged; its exact fields are validated before any
/// repository open. `git_directory_url` must name the protected private
/// split gitdir and `git_topology` must be `private_split_gitdir` for V2.
typedef NSDictionary *_Nullable (^DSHLocalProjectWorkspaceBindingResolver)(
    NSDictionary *rootRef,
    NSString *rootFingerprintSHA256,
    NSError *_Nullable *_Nullable error);

/// A process-wide per-project lock token. Release the token before presenting
/// credential UI or invoking unrelated asynchronous work.
@interface DSHLocalProjectLockToken : NSObject
@end

@interface DSHLocalProjectsRootLease : NSObject
@property(nonatomic, strong, readonly) NSURL *rootURL;
@property(nonatomic, readonly) int descriptor;
@property(nonatomic, readonly) dev_t device;
@property(nonatomic, readonly) ino_t inode;
@end

/// Owns the per-project lock, stable root-relative descriptors, and libgit2
/// repository handle. All resources remain valid until the lease is released.
@interface DSHLocalProjectLease : NSObject
@property(nonatomic, copy, readonly) NSString *projectId;
@property(nonatomic, strong, readonly) NSURL *projectDirectoryURL;
@property(nonatomic, strong, readonly) NSURL *repositoryURL;
@property(nonatomic, copy, readonly, nullable) NSDictionary *metadata;
@property(nonatomic, readonly) int projectsRootDescriptor;
@property(nonatomic, readonly) int projectDescriptor;
@property(nonatomic, readonly) int repositoryDescriptor;
@property(nonatomic, readonly) int gitDescriptor;
@property(nonatomic, readonly) int objectsDescriptor;
@property(nonatomic, readonly) dev_t projectsRootDevice;
@property(nonatomic, readonly) ino_t projectsRootInode;
@property(nonatomic, readonly) dev_t projectDevice;
@property(nonatomic, readonly) ino_t projectInode;
@property(nonatomic, readonly) dev_t repositoryDevice;
@property(nonatomic, readonly) ino_t repositoryInode;
@property(nonatomic, readonly) dev_t gitDevice;
@property(nonatomic, readonly) ino_t gitInode;
@property(nonatomic, readonly) dev_t objectsDevice;
@property(nonatomic, readonly) ino_t objectsInode;
@property(nonatomic, readonly) git_repository *repository;
@property(nonatomic, readonly) DSHLocalProjectAccessMode accessMode;

/// Workspace-scoped V2 identity. These fields are populated only for a lease
/// derived from a DSHLocalWorkspaceLease and a validated WorkspaceRootRefV1.
/// They are never projected through an app UI result.
@property(nonatomic, copy, readonly, nullable) NSString *workspaceId;
@property(nonatomic, readonly) NSUInteger workspaceBindingRevision;
@property(nonatomic, copy, readonly, nullable) NSString *rootFingerprintSHA256;
@property(nonatomic, copy, readonly, nullable) NSString *rootFingerprint;
@property(nonatomic, readonly) int workspaceRootDescriptor;
@property(nonatomic, readonly) dev_t workspaceRootDevice;
@property(nonatomic, readonly) ino_t workspaceRootInode;
@property(nonatomic, copy, readonly, nullable) NSDictionary *workspaceRootRef;
@property(nonatomic, copy, readonly, nullable) NSString *gitTopology;
/// Digest of the native project binding with its private URL removed. This is
/// an internal lease identity and is never projected through the bridge.
@property(nonatomic, copy, readonly, nullable) NSString *workspaceBindingDigest;
@end

@interface DSHLocalProjectLeaseSet : NSObject
- (nullable DSHLocalProjectLease *)leaseForProjectId:(NSString *)projectId;
@end

/// Canonical resolver shared by LocalProjects and project-context capture.
/// The default root is Application Support/workspace/projects. Tests inject a
/// temporary projects root and never touch user projects.
@interface DSHLocalProjectAccess : NSObject

+ (instancetype)sharedAccess;
+ (BOOL)isCanonicalProjectId:(NSString *)projectId;
+ (nullable NSString *)filesystemFoldedComponent:(NSString *)component;
+ (nullable NSString *)projectIdForWorkspacePath:(NSString *)path
                                           error:(NSError **)error;

- (instancetype)init;
- (instancetype)initWithProjectsRootURL:(nullable NSURL *)projectsRootURL;
- (instancetype)initWithProjectsRootURL:(nullable NSURL *)projectsRootURL
                                   hook:(nullable DSHLocalProjectAccessHook)hook
    NS_DESIGNATED_INITIALIZER;

/// Workspace-scoped construction. A non-nil workspace access object is
/// required for every V2 lease; the legacy projects-root initializer remains
/// available only to the explicit legacy adapter and existing tests.
- (instancetype)initWithWorkspaceAccess:(DSHLocalWorkspaceAccess *)workspaceAccess
                                    hook:(nullable DSHLocalProjectAccessHook)hook;

- (instancetype)initWithWorkspaceAccess:(DSHLocalWorkspaceAccess *)workspaceAccess
                        bindingResolver:(nullable DSHLocalProjectWorkspaceBindingResolver)bindingResolver
                                    hook:(nullable DSHLocalProjectAccessHook)hook;

- (instancetype)initWithProjectsRootURL:(nullable NSURL *)projectsRootURL
                        workspaceAccess:(nullable DSHLocalWorkspaceAccess *)workspaceAccess
                                    hook:(nullable DSHLocalProjectAccessHook)hook;

- (instancetype)initWithProjectsRootURL:(nullable NSURL *)projectsRootURL
                        workspaceAccess:(nullable DSHLocalWorkspaceAccess *)workspaceAccess
                       bindingResolver:(nullable DSHLocalProjectWorkspaceBindingResolver)bindingResolver
                                    hook:(nullable DSHLocalProjectAccessHook)hook;

- (nullable NSURL *)projectsRootURLWithError:(NSError **)error;
- (nullable NSURL *)projectsRootURLCreatingIfNeeded:(BOOL)create
                                               error:(NSError **)error;
- (nullable DSHLocalProjectsRootLease *)
    leaseProjectsRootCreatingIfNeeded:(BOOL)create
                                 error:(NSError **)error NS_RETURNS_RETAINED;
- (BOOL)validateProjectsRootLease:(DSHLocalProjectsRootLease *)lease
                             error:(NSError **)error;
- (nullable NSURL *)projectDirectoryURLForId:(NSString *)projectId
                                       error:(NSError **)error;

- (nullable DSHLocalProjectLockToken *)lockProjectId:(NSString *)projectId
                                                mode:(DSHLocalProjectAccessMode)mode
                                               error:(NSError **)error
    NS_RETURNS_RETAINED;
- (nullable DSHLocalProjectLockToken *)tryLockProjectIdForWrite:
    (NSString *)projectId error:(NSError **)error NS_RETURNS_RETAINED;

/// Legacy app-owned adapter only. Production workspace-routed consumers must
/// use leaseWorkspaceRootRef:... and may not resolve a project ID alone.
- (nullable DSHLocalProjectLease *)leaseProjectId:(NSString *)projectId
                                              mode:(DSHLocalProjectAccessMode)mode
                                   includeMetadata:(BOOL)includeMetadata
                                             error:(NSError **)error
    NS_RETURNS_RETAINED;

- (nullable DSHLocalProjectLeaseSet *)
    leaseWorkspaceReadPaths:(NSArray<NSString *> *)readPaths
                  writePaths:(NSArray<NSString *> *)writePaths
                     timeout:(NSTimeInterval)timeout
                       error:(NSError **)error NS_RETURNS_RETAINED;

- (BOOL)validateLeaseIdentity:(DSHLocalProjectLease *)lease
                         error:(NSError **)error;
- (nullable NSDictionary *)readProjectMetadataFromLease:(DSHLocalProjectLease *)lease
                                                   error:(NSError **)error;
- (nullable NSString *)projectMetadataDigestFromLease:(DSHLocalProjectLease *)lease
                                                 error:(NSError **)error;

/// Native-only evidence used to bootstrap an app-owned legacy project into
/// workspace authority. The project read lock remains held while metadata and
/// the projects-root/repository/git physical identities are read and rechecked.
/// The returned exact-shape dictionary contains no path, URL, bookmark, or
/// descriptor and is not an app UI result.
- (nullable NSDictionary *)legacyWorkspaceBootstrapEvidenceForProjectId:
    (NSString *)projectId error:(NSError **)error;

- (BOOL)writeProjectMetadataRecord:(NSDictionary *)record
                              lease:(DSHLocalProjectLease *)lease
                              error:(NSError **)error;
- (BOOL)writeInitialProjectMetadataRecord:(NSDictionary *)record
                                  projectId:(NSString *)projectId
                          projectDescriptor:(int)projectDescriptor
                                 writeToken:(DSHLocalProjectLockToken *)writeToken
                                      error:(NSError **)error;

- (nullable DSHLocalProjectLease *)leaseProjectId:(NSString *)projectId
                                              mode:(DSHLocalProjectAccessMode)mode
                                           includeMetadata:(BOOL)includeMetadata
                                           timeout:(NSTimeInterval)timeout
                                             error:(NSError **)error
    NS_RETURNS_RETAINED;

/// Validates the sole public workspace authority reference. The reference has
/// exactly schema_version, workspace_id, binding_revision, and project_id;
/// paths, URLs, bookmarks, descriptors, identities, and provider data are
/// intentionally not accepted.
+ (BOOL)validateWorkspaceRootRefV1:(NSDictionary *)rootRef
                    projectRequired:(BOOL)projectRequired
                              error:(NSError **)error;

/// Derives the project/repository lease from a workspace authority lease. No
/// project-id-only or global-path fallback is performed by this method. The
/// supplied DSHLocalWorkspaceLease is retained for the lifetime of the
/// returned lease, so its descriptor and authority lock cannot outlive the
/// operation that owns the project lease. The workspace lease must carry the
/// Git capability; the Project Context capability is required only by the
/// Project Context service's own all-capability entry point.
- (nullable DSHLocalProjectLease *)leaseWorkspaceRootRef:(NSDictionary *)rootRef
                                         workspaceLease:(DSHLocalWorkspaceLease *)workspaceLease
                                                  mode:(DSHLocalProjectAccessMode)mode
                                       includeMetadata:(BOOL)includeMetadata
                                               timeout:(NSTimeInterval)timeout
                                                 error:(NSError **)error
    NS_RETURNS_RETAINED;

/// Native-only attach preflight. The supplied binding must be an already
/// validated private split-git binding, commonly located in an unlisted
/// staging directory. No bridge caller can supply this object.
- (nullable DSHLocalProjectLease *)leaseWorkspaceRootRef:(NSDictionary *)rootRef
                                         workspaceLease:(DSHLocalWorkspaceLease *)workspaceLease
                                      workspaceBinding:(NSDictionary *)workspaceBinding
                                                  mode:(DSHLocalProjectAccessMode)mode
                                       includeMetadata:(BOOL)includeMetadata
                                               timeout:(NSTimeInterval)timeout
                                                 error:(NSError **)error
    NS_RETURNS_RETAINED;

/// Resolves a workspace lease through the configured DSHLocalWorkspaceAccess
/// and then delegates to leaseWorkspaceRootRef:workspaceLease:... . This is
/// the normal native entry used by Project Context V2.
- (nullable DSHLocalProjectLease *)leaseWorkspaceRootRef:(NSDictionary *)rootRef
                                                  mode:(DSHLocalProjectAccessMode)mode
                                       includeMetadata:(BOOL)includeMetadata
                                               timeout:(NSTimeInterval)timeout
                                                 error:(NSError **)error
    NS_RETURNS_RETAINED;

- (nullable DSHLocalProjectLease *)leaseWorkspaceRootRef:(NSDictionary *)rootRef
                                         workspaceAccess:(DSHLocalWorkspaceAccess *)workspaceAccess
                                                    mode:(DSHLocalProjectAccessMode)mode
                                         includeMetadata:(BOOL)includeMetadata
                                                 timeout:(NSTimeInterval)timeout
                                                   error:(NSError **)error
    NS_RETURNS_RETAINED;

- (BOOL)validateWorkspaceLeaseIdentity:(DSHLocalProjectLease *)lease
                                rootRef:(NSDictionary *)rootRef
                                  error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
