#import <Foundation/Foundation.h>

#import "LocalProjectAccess.h"
#import "LocalWorkspaceAccess.h"

NS_ASSUME_NONNULL_BEGIN

@class DSHLegacyBoundProjectRootProof;

FOUNDATION_EXPORT NSErrorDomain const DSHLegacyBoundProjectRootAccessErrorDomain;

typedef NS_ERROR_ENUM(DSHLegacyBoundProjectRootAccessErrorDomain,
                      DSHLegacyBoundProjectRootAccessErrorCode) {
  DSHLegacyBoundProjectRootAccessErrorInvalid = 1,
  DSHLegacyBoundProjectRootAccessErrorConflict = 2,
  DSHLegacyBoundProjectRootAccessErrorRootChanged = 3,
  DSHLegacyBoundProjectRootAccessErrorUnavailable = 4,
};

typedef NS_ENUM(NSInteger, DSHLegacyBoundProjectRootOperationMode) {
  DSHLegacyBoundProjectRootOperationModeRead = 0,
  DSHLegacyBoundProjectRootOperationModeWrite = 1,
  DSHLegacyBoundProjectRootOperationModeGitRead = 2,
  DSHLegacyBoundProjectRootOperationModeGitWrite = 3,
  DSHLegacyBoundProjectRootOperationModeProjectContext = 4,
};

// Source compatibility for consumers which have not yet selected a Git
// mutation mode.  The old Git mode was read-only (`git_status` + read lease).
#define DSHLegacyBoundProjectRootOperationModeGit \
  DSHLegacyBoundProjectRootOperationModeGitRead

typedef NS_ENUM(NSInteger, DSHLegacyBoundProjectRootDisposition) {
  DSHLegacyBoundProjectRootDispositionFailed = 0,
  DSHLegacyBoundProjectRootDispositionNotHandled = 1,
  DSHLegacyBoundProjectRootDispositionHandled = 2,
};

/// A synchronous, native-only operation over a borrowed repository-root
/// descriptor. The descriptor remains owned by the project lease and is valid
/// only for the dynamic extent of the block. The block must not close, dup,
/// retain, dispatch, or otherwise allow the descriptor to escape.
typedef BOOL (^DSHLegacyBoundProjectRootOperation)(int repositoryRootDescriptor,
                                                   NSError **error);

/// Agent-only variant. Both values are borrowed from the same project lease
/// and are valid only for the synchronous dynamic extent of the block.
typedef BOOL (^DSHLegacyBoundProjectHandleOperation)(
    int repositoryRootDescriptor,
    git_repository *repository,
    NSError **error);

/// Compatibility adapter for a safe, frozen project root whose workspace
/// authority still points at an app-owned legacy project. It never accepts a
/// path, URL, bookmark, descriptor, inode, authority record, or raw workspace
/// descriptor and is not exposed as an app UI module.
@interface DSHLegacyBoundProjectRootAccess : NSObject

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithWorkspaceAccess:(DSHLocalWorkspaceAccess *)workspaceAccess
                           projectAccess:(DSHLocalProjectAccess *)projectAccess
    NS_DESIGNATED_INITIALIZER;

/// `boundRoot` is the exact seven-field AgentRuntimeRootV1 safe projection.
/// The selected mode is capability-bound: read requires file_read, write
/// requires file_write, Git Read requires git_status, Git Write requires
/// git_commit plus a write lease, and Project Context requires file_read plus
/// the native project_context authority capability. Timeout is
/// finite and in [0, 30]. Documents-owned roots return NotHandled so their
/// existing consumer path remains authoritative. Every other non-legacy
/// locator, workspace-only root, or malformed/raw workspace value fails
/// closed. On Handled, the workspace proof and project lease identities are
/// checked before and after the block.
- (DSHLegacyBoundProjectRootDisposition)
    performRepositoryRootOperationForBoundRoot:(NSDictionary *)boundRoot
                                           mode:(DSHLegacyBoundProjectRootOperationMode)mode
                                        timeout:(NSTimeInterval)timeout
                                          block:(DSHLegacyBoundProjectRootOperation)block
                                          error:(NSError **)error;

- (DSHLegacyBoundProjectRootDisposition)
    performProjectHandleOperationForBoundRoot:(NSDictionary *)boundRoot
                                          mode:(DSHLegacyBoundProjectRootOperationMode)mode
                                       timeout:(NSTimeInterval)timeout
                                         block:(DSHLegacyBoundProjectHandleOperation)block
                                         error:(NSError **)error;

/// Exact legacy proof for a caller which already owns the workspace authority
/// mutation guard. No borrowed descriptor or repository handle is exposed.
- (DSHLegacyBoundProjectRootDisposition)
    validateBoundRoot:(NSDictionary *)boundRoot
                 mode:(DSHLegacyBoundProjectRootOperationMode)mode
              timeout:(NSTimeInterval)timeout
    authorityMutationGuard:(DSHLocalWorkspaceAuthorityMutationGuard *)guard
                error:(NSError **)error;

/// Retains the verified legacy project lease without exposing its handles.
/// The caller must already own the matching workspace authority guard.
- (nullable DSHLegacyBoundProjectRootProof *)
    acquireProofForBoundRoot:(NSDictionary *)boundRoot
                        mode:(DSHLegacyBoundProjectRootOperationMode)mode
                     timeout:(NSTimeInterval)timeout
      authorityMutationGuard:(DSHLocalWorkspaceAuthorityMutationGuard *)guard
                 disposition:(DSHLegacyBoundProjectRootDisposition *)disposition
                       error:(NSError **)error NS_RETURNS_RETAINED;

@end

NS_ASSUME_NONNULL_END
