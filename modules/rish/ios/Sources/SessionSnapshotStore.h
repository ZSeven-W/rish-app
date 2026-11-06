#import <Foundation/Foundation.h>

#import "SessionWorkspaceCoordinator.h"
#import "WorkspaceClearanceStore.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const DSHSessionSnapshotStoreErrorDomain;

typedef NS_ERROR_ENUM(DSHSessionSnapshotStoreErrorDomain,
                      DSHSessionSnapshotStoreErrorCode) {
  DSHSessionSnapshotStoreErrorInvalidArgument = 1,
  DSHSessionSnapshotStoreErrorCorrupt = 2,
  DSHSessionSnapshotStoreErrorStorage = 3,
  DSHSessionSnapshotStoreErrorProtection = 4,
  DSHSessionSnapshotStoreErrorBounds = 5,
  DSHSessionSnapshotStoreErrorConflict = 6,
};

FOUNDATION_EXPORT NSString *const DSHSessionSnapshotStoreErrorInvalidCode;
FOUNDATION_EXPORT NSString *const DSHSessionSnapshotStoreErrorCorruptCode;
FOUNDATION_EXPORT NSString *const DSHSessionSnapshotStoreErrorStorageCode;
FOUNDATION_EXPORT NSString *const DSHSessionSnapshotStoreErrorProtectionCode;
FOUNDATION_EXPORT NSString *const DSHSessionSnapshotStoreErrorBoundsCode;
FOUNDATION_EXPORT NSString *const DSHSessionSnapshotStoreErrorConflictCode;

/// Stable process-local launch identity used in every native session envelope.
/// It is generated once per process and is always a canonical lowercase UUID.
FOUNDATION_EXPORT NSString *DSHSessionSnapshotStoreLaunchInstanceId(void);

typedef NS_ENUM(NSInteger, DSHSessionSnapshotStoreFaultPoint) {
  DSHSessionSnapshotStoreFaultPointBeforeWrite = 1,
  DSHSessionSnapshotStoreFaultPointAfterWriteBeforeRename = 2,
  DSHSessionSnapshotStoreFaultPointAfterRename = 3,
  DSHSessionSnapshotStoreFaultPointAfterRenameBeforeVerify = 4,
};

/// Test-only hook. Production callers pass nil. It is called on the shared
/// coordinator queue and may return NO to force a stable storage failure at the
/// selected point. The hook receives no path or private data.
typedef BOOL (^DSHSessionSnapshotStoreFaultHook)(
    DSHSessionSnapshotStoreFaultPoint point);

/// Native schema-9 session snapshot store. The public bridge should expose
/// only the three versioned request/result dictionaries declared in the
/// approved session contract; this class intentionally has no app UI
/// dependency so it can be tested as a protected native primitive.
@interface DSHSessionSnapshotStore : NSObject

@property(nonatomic, readonly) NSURL *sessionURL;
@property(nonatomic, readonly) NSURL *rootURL;
@property(nonatomic, readonly) NSString *launchInstanceId;
@property(nonatomic, readonly) DSHSessionWorkspaceCoordinator *coordinator;
@property(nonatomic, readonly) DSHWorkspaceClearanceStore *clearanceStore;

- (instancetype)init NS_UNAVAILABLE;

/// Production convenience initializer. It resolves Application Support and
/// uses the existing `sessions.json` location.
- (nullable instancetype)initWithError:(NSError **)error;

/// Uses `rootURL/sessions.json`; intended for tests and native composition.
- (instancetype)initWithRootURL:(NSURL *)rootURL;

- (instancetype)initWithRootURL:(NSURL *)rootURL
                launchInstanceId:(NSString *)launchInstanceId;

/// Naming-compatible alias for native stores that call their private
/// Application Support directory a `privateRootURL`.
- (instancetype)initWithPrivateRootURL:(NSURL *)privateRootURL;

/// Uses an explicitly supplied file URL. The containing directory is treated
/// as the private store root and is created/validated as needed.
- (instancetype)initWithSessionURL:(NSURL *)sessionURL;

- (instancetype)initWithSessionURL:(NSURL *)sessionURL
                  launchInstanceId:(NSString *)launchInstanceId;

/// Injectable initializer for focused native tests and future workspace
/// clearance composition. The session URL must be a file URL.
- (instancetype)initWithRootURL:(NSURL *)rootURL
                      sessionURL:(NSURL *)sessionURL
                launchInstanceId:(nullable NSString *)launchInstanceId
                      coordinator:(nullable DSHSessionWorkspaceCoordinator *)coordinator
                        faultHook:(nullable DSHSessionSnapshotStoreFaultHook)faultHook;

- (instancetype)initWithRootURL:(NSURL *)rootURL
                      sessionURL:(NSURL *)sessionURL
                launchInstanceId:(nullable NSString *)launchInstanceId
                      coordinator:(nullable DSHSessionWorkspaceCoordinator *)coordinator
                        faultHook:(nullable DSHSessionSnapshotStoreFaultHook)faultHook
          projectDetachValidator:
              (nullable DSHWorkspaceClearanceProjectDetachValidator)validator
    NS_DESIGNATED_INITIALIZER;

/// Returns the exact versioned load result. Missing, legacy_present, and
/// present are resolved values; malformed/protected-store failures return nil
/// and a stable NSError.
- (nullable NSDictionary *)loadSessionSnapshotWithError:(NSError **)error;

/// Short selector retained for native callers that already use the contract
/// name without the Objective-C `WithError` suffix.
- (nullable NSDictionary *)loadSessionSnapshot:(NSError **)error;

- (nullable NSDictionary *)casPersistSession:(NSDictionary *)request
                                        error:(NSError **)error;

- (nullable NSDictionary *)casPersistSessionWithRequest:(NSDictionary *)request
                                                  error:(NSError **)error;

- (nullable NSDictionary *)querySessionCommit:(NSDictionary *)request
                                         error:(NSError **)error;

- (nullable NSDictionary *)querySessionCommitWithRequest:(NSDictionary *)request
                                                   error:(NSError **)error;

/// Atomically commits a session candidate and issues a native clearance
/// receipt bound to the committed session generation/hash and workspace
/// outbox identity. The receipt contains metadata only.
- (nullable NSDictionary *)persistSessionWithWorkspaceClearance:(NSDictionary *)request
                                                           error:(NSError **)error;

/// Recovers a clearance receipt by its durable operation/write id. A receipt
/// from an older session generation/hash is reported as `unknown`.
- (nullable NSDictionary *)queryWorkspaceClearance:(NSDictionary *)request
                                              error:(NSError **)error;

/// Digest of a schema-9 session candidate under the shared shell/native
/// contract: SHA-256 over "rish.chat-session.v1\0" + canonical JSON, exactly
/// the value the CAS path mints as `session_sha256`. Pure function of the
/// candidate bytes: no lock, no disk, no store state. nil when the candidate
/// is not a valid schema-9 session. The native bridge shares this implementation
/// with the shell so checkpoints use exactly the same digest contract.
+ (nullable NSString *)candidateDigestForSessionJSON:(NSString *)candidateJSON;

@end

@compatibility_alias SessionSnapshotStore DSHSessionSnapshotStore;

NS_ASSUME_NONNULL_END
