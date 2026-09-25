#import <Foundation/Foundation.h>

#include <git2.h>

NS_ASSUME_NONNULL_BEGIN

/// Keychain service shared with the pre-existing git HTTPS credential store.
extern NSString *const DSHGitPushCredentialService;

/// Receipt journal filename inside the repository's private git directory.
extern NSString *const DSHGitPushReceiptFilename;

/// Expiry choices offered by the native credential prompt, in seconds.
typedef NS_ENUM(NSInteger, DSHGitCredentialExpiry) {
  DSHGitCredentialExpiryOneHour = 3600,
  DSHGitCredentialExpiryOneDay = 24 * 3600,
  DSHGitCredentialExpirySevenDays = 7 * 24 * 3600,
};

/// Validated remote URL for clone, set-origin, credential status, and push.
/// Accepts credential-free `https://` DNS hosts on port 443, and plain
/// `http://` only for loopback, RFC 1918, link-local, and ULA literals (the
/// LAN test remote). Query, fragment, userinfo, and dot segments are rejected.
NSURL *_Nullable DSHGitValidatedRemoteURL(id value, NSError **error);

/// YES when the validated remote host is a private literal reached over plain
/// HTTP. Callers surface this so the user knows the token travels unencrypted
/// on the local network only.
BOOL DSHGitRemoteURLIsPlaintext(NSURL *url);

/// YES for one of the three prompt expiry windows.
BOOL DSHGitCredentialExpiryIsValid(NSInteger expirySeconds);

/// Keychain account key for the (project scope, host) credential.
NSString *DSHGitCredentialAccountForScope(NSString *scopeId, NSString *host);

/// Reads the credential for (scopeId, host). Expired items are deleted and
/// reported as absent. The returned dictionary carries `username`, `token`,
/// `expires_at` (unix seconds) and `expiry_seconds`; it must never cross the
/// React Native bridge.
NSDictionary *_Nullable DSHGitCredentialForScope(NSString *scopeId,
                                                 NSString *host,
                                                 NSError **error);

/// Stores or updates the credential with an absolute expiry derived from one
/// of the three prompt windows.
BOOL DSHGitStoreCredentialForScope(NSString *scopeId, NSString *host,
                                   NSString *username, NSString *token,
                                   NSInteger expirySeconds, NSError **error);

/// Deletes the scoped credential for one host.
BOOL DSHGitDeleteCredentialForScope(NSString *scopeId, NSString *host,
                                    NSError **error);

/// Deletes a legacy v1 host-only credential left behind by older builds.
BOOL DSHGitDeleteLegacyHostCredential(NSString *host, NSError **error);

typedef NS_ENUM(NSInteger, DSHGitPushOutcome) {
  DSHGitPushOutcomeSuccess = 0,
  /// The advertised remote reference did not match `expectedRemoteOID`.
  DSHGitPushOutcomeConflict,
  DSHGitPushOutcomeNonFastForward,
  /// The server reported a rejection for the target reference.
  DSHGitPushOutcomeRejected,
  DSHGitPushOutcomeAuthFailure,
  DSHGitPushOutcomeTimedOut,
  DSHGitPushOutcomeCancelled,
  DSHGitPushOutcomeFailed,
  /// The proxy the person set refused, failed or could not be reached.
  /// Last, so the values before it keep their numbers.
  DSHGitPushOutcomeProxyFailed,
};

/// Whether libgit2's last error came from `proxyURL` rather than the
/// repository: libgit2 words every proxy refusal "proxy ..." (including a
/// 407, which it returns as GIT_EAUTH), and names an unreachable proxy's
/// host in the connect error. NO when no proxy is set. Ask before treating
/// GIT_EAUTH as the repository turning a credential away.
BOOL DSHGitProxyFailed(NSString *_Nullable proxyURL);

/// The one spelling libgit2 is handed for a person's HTTPS proxy,
/// `scheme://host:port/`: an http or https proxy with a host and an explicit
/// port and nothing else (no path, credentials, query or fragment). nil for
/// nil, NSNull or an empty string (no proxy); nil with `*invalid = YES` for
/// anything else. The panel's options and the committed session's
/// preferences are judged by the same rule.
NSString *_Nullable DSHGitCanonicalProxyURL(id _Nullable value, BOOL *_Nullable invalid);

/// The Git proxy a loaded session snapshot holds
/// (`preferences.git_https_proxy_url`, canonical), or nil for none: no
/// snapshot, no proxy, or a value that no longer reads. `loaded` is what
/// DSHSessionSnapshotStore's loadSessionSnapshotWithError: answers.
NSString *_Nullable DSHCommittedGitProxyURL(NSDictionary *_Nullable loaded);

/// Cancellation token polled by the bounded push runner.
@interface DSHGitPushCancelToken : NSObject
@property(nonatomic, readonly) BOOL cancelled;
- (void)cancel;
@end

@interface DSHGitPushRequest : NSObject
@property(nonatomic) git_repository *repository;  // borrowed; caller keeps lease
@property(nonatomic, copy) NSString *remoteName;  // origin
/// Validated absolute URL applied to the remote instance. When nil the
/// remote's configured URL is used verbatim (local filesystem remotes used by
/// the native test fixtures).
@property(nonatomic, copy, nullable) NSString *remoteURL;
@property(nonatomic, copy, nullable) NSString *host;  // lowercase host
@property(nonatomic, copy) NSString *fullReference;  // refs/heads/<branch>
@property(nonatomic, copy) NSString *localOID;
@property(nonatomic, copy, nullable) NSString *username;
@property(nonatomic, copy, nullable) NSString *token;
@property(nonatomic, copy, nullable) NSString *proxyURL;
/// nil: no precondition. NSNull: the reference must be absent on the remote.
/// NSString: the advertised OID must equal this value.
@property(nonatomic, strong, nullable) id expectedRemoteOID;
@property(nonatomic, strong, nullable) DSHGitPushCancelToken *cancelToken;
@property(nonatomic) NSTimeInterval timeout;  // default 60
/// Fires exactly once on the push worker with the settled outcome, even after
/// the caller already observed a timeout or cancellation.
@property(nonatomic, copy, nullable) void (^completion)(
    DSHGitPushOutcome outcome, NSString *_Nullable remoteOID);
@end

@interface DSHGitPushResult : NSObject
@property(nonatomic) DSHGitPushOutcome outcome;
/// Advertised OID of the target reference before the push (nil when absent).
@property(nonatomic, copy, nullable) NSString *advertisedOID;
/// OID the server advertises for the target reference after the push.
@property(nonatomic, copy, nullable) NSString *remoteOID;
/// YES when `remoteOID` was read back from the server after the push.
@property(nonatomic) BOOL verified;
/// YES when the failure happened after bytes may have reached the server.
@property(nonatomic) BOOL effectMayHaveOccurred;
@end

/// Runs a non-force push bounded by `timeout`, polling the cancel token. The
/// caller returns at the deadline or on cancellation; the network phase then
/// aborts at its next libgit2 callback or socket timeout.
DSHGitPushResult *DSHGitPushRun(DSHGitPushRequest *request);

/// Builds a receipt dictionary from the settled push facts.
NSDictionary *DSHGitPushReceipt(NSString *host, NSString *branch,
                                NSString *localOID, NSString *remoteOID,
                                NSString *pushedAt);

/// Appends a push receipt to the journal stored in the git directory.
BOOL DSHGitPushRecordReceipt(int gitDirectoryDescriptor,
                             NSString *projectId,
                             NSDictionary *receipt,
                             NSError **error);

/// Loads the receipt journal (oldest first). A missing journal is empty.
NSArray<NSDictionary *> *_Nullable DSHGitPushLoadReceipts(
    int gitDirectoryDescriptor, NSString *projectId, NSError **error);

NS_ASSUME_NONNULL_END
