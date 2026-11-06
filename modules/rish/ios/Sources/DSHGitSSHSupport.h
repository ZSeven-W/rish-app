#import <Foundation/Foundation.h>

#include <git2.h>

NS_ASSUME_NONNULL_BEGIN

/// Keychain service used exclusively for project-scoped SSH keys and trusted
/// host keys. It is separate from the HTTPS token service.
extern NSString *const DSHGitSSHCredentialService;

/// Parses and validates an SSH remote. Supports `user@host:path` and
/// `ssh://user@host[:port]/path`; no password, query, fragment, or unsafe path
/// component is accepted.
NSDictionary *_Nullable DSHGitSSHValidatedRemote(id value, NSError **error);

/// Read-only compatibility for a credential host stored with Foundation's
/// single IPv6 bracket pair. Does not authorize a different host or mutate it.
BOOL DSHGitSSHCredentialHostsMatch(id storedHost, id requestedHost);

/// Returns the app-private SSH credential for a profile and endpoint. The
/// dictionary is native-only and must never cross the app UI bridge.
NSDictionary *_Nullable DSHGitSSHCredentialForProfile(NSString *profileId,
                                                     NSString *host,
                                                     NSInteger port,
                                                     NSString *username,
                                                 NSError **error);

/// Returns endpoint metadata and a configured flag without returning key
/// material. A missing profile returns nil with no error.
NSDictionary *_Nullable DSHGitSSHCredentialStatusForProfile(NSString *profileId,
                                                              NSError **error);

/// Stores an SSH private/public key and the trusted known-hosts text in the
/// app Keychain. The private key is copied into Keychain data and is never
/// written to a filesystem path or returned by a status method.
BOOL DSHGitSSHStoreCredentialForProfile(NSString *profileId,
                                      NSString *host,
                                      NSInteger port,
                                      NSString *username,
                                      NSString *privateKey,
                                      NSString *_Nullable publicKey,
                                      NSString *_Nullable passphrase,
                                      NSString *knownHosts,
                                      NSError **error);

BOOL DSHGitSSHDeleteCredentialForProfile(NSString *profileId,
                                       NSString *host,
                                       NSInteger port,
                                       NSString *username,
                                       NSError **error);

/// Checks the bounded private-key envelope before Keychain import. Encrypted
/// keys are rejected until a native secure passphrase flow is available.
BOOL DSHGitSSHPrivateKeyIsSupported(NSString *privateKey, NSError **error);

/// Opaque callback payload used only during one libgit2 operation.
void *_Nullable DSHGitSSHAuthContextCreate(NSString *profileId,
                                           NSString *host,
                                           NSInteger port,
                                           NSString *username,
                                           NSError **error);
void DSHGitSSHAuthContextFree(void *context);

int DSHGitSSHCredentialCallback(git_credential * _Nullable * _Nonnull out,
                                const char *url,
                                const char *username,
                                unsigned int allowedTypes,
                                void *payload);
int DSHGitSSHCertificateCallback(git_cert *cert,
                                 int valid,
                                 const char *host,
                                 void *payload);

NS_ASSUME_NONNULL_END
