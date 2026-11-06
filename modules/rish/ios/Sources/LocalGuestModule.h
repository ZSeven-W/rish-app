#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Bundle resource names and the pinned digests they must match at boot.
// The digest constants mirror modules/rish/shared/GuestAssets/SHA256SUMS.
FOUNDATION_EXPORT NSString *const DSHGuestKernelResourceName;
FOUNDATION_EXPORT NSString *const DSHGuestInitramfsResourceName;
FOUNDATION_EXPORT NSString *const DSHGuestKernelSha256;
FOUNDATION_EXPORT NSString *const DSHGuestInitramfsSha256;

// Stable error codes surfaced to the UI. Fail-closed single-session
// semantics: concurrent or repeated boot is refused, not restarted.
FOUNDATION_EXPORT NSString *const DSHGuestErrorInvalidRequest;   // E_GUEST_INVALID_REQUEST
FOUNDATION_EXPORT NSString *const DSHGuestErrorAssetsMissing;    // E_GUEST_ASSETS_MISSING
FOUNDATION_EXPORT NSString *const DSHGuestErrorAssetIntegrity;   // E_GUEST_ASSET_INTEGRITY
FOUNDATION_EXPORT NSString *const DSHGuestErrorBootInProgress;   // E_GUEST_BOOT_IN_PROGRESS
FOUNDATION_EXPORT NSString *const DSHGuestErrorAlreadyBooted;    // E_GUEST_ALREADY_BOOTED
FOUNDATION_EXPORT NSString *const DSHGuestErrorNotBooted;        // E_GUEST_NOT_BOOTED
FOUNDATION_EXPORT NSString *const DSHGuestErrorBootFailed;       // E_GUEST_BOOT_FAILED
FOUNDATION_EXPORT NSString *const DSHGuestErrorBootCancelled;    // E_GUEST_BOOT_CANCELLED
FOUNDATION_EXPORT NSString *const DSHGuestErrorExecFailed;       // E_GUEST_EXEC_FAILED
FOUNDATION_EXPORT NSString *const DSHGuestErrorUnavailable;      // E_GUEST_UNAVAILABLE

/// Native rish guest session module. The native registry exposes bootGuest / guestExec /
/// shutdownGuest; tests may call the plain methods directly. The blocking
/// FFI boot runs on a dedicated worker queue, so the module never blocks the
/// main thread. One session at a time: the handle is owned by a serial state
/// queue and released exactly once (shutdown, boot cancellation, or dealloc).
@interface LocalGuestModule : NSObject

- (instancetype)init;
- (instancetype)initWithBundle:(NSBundle *)bundle;

/// Resolved boot asset URLs (nil when the resource is missing from the bundle).
@property(nonatomic, readonly, nullable) NSURL *kernelURL;
@property(nonatomic, readonly, nullable) NSURL *initramfsURL;

- (void)bootGuestRequest:(NSDictionary *)request
                 resolve:(void (^)(id result))resolve
                  reject:(void (^)(NSString *code, NSString *message, NSError *error))reject;

- (void)guestExecRequest:(NSDictionary *)request
                 resolve:(void (^)(id result))resolve
                  reject:(void (^)(NSString *code, NSString *message, NSError *error))reject;

- (void)shutdownGuestResolve:(void (^)(id result))resolve
                      reject:(void (^)(NSString *code, NSString *message, NSError *error))reject;

@end

NS_ASSUME_NONNULL_END
