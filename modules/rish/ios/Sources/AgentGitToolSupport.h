// Internal libgit2 observations and transport to the shared Git rules.
#import <Foundation/Foundation.h>
#include <git2.h>

NSDictionary *DSHAgentGitReduce(NSString *op, NSDictionary *fields, NSError **error);
NSString *DSHAgentGitOID(const git_oid *oid);
NSString *DSHAgentGitTimestamp(void);
NSString *DSHAgentGitCanonicalFeedback(NSDictionary *feedback, NSError **error);
NSDictionary *DSHAgentGitFailureWithReason(NSString *name, NSString *failureCode, NSString *reason, BOOL ambiguous, NSError **error);
NSDictionary *DSHAgentGitFailure(NSString *name, NSString *failureCode, BOOL ambiguous, NSError **error);
NSString *DSHAgentGitBranchReference(git_repository *repository, NSString **branchOut, NSString **headOIDOut);
NSString *DSHAgentGitHeadReferenceName(git_repository *repository);
NSString *DSHAgentGitRawOriginURL(git_repository *repository);
NSDictionary *DSHAgentGitPushFailure(NSString *name, NSString *failureCode, NSString *reason, BOOL ambiguous, NSError **error);
/// What origin advertises for `remoteRef`, asked through `proxyURL` when
/// one is given (the canonical spelling from DSHGitCanonicalProxyURL).
BOOL DSHAgentGitRemoteOID(git_repository *repository, NSString *remoteRef, NSString *_Nullable proxyURL,
                          NSString **oidOut, NSError **error);
NSDictionary *DSHAgentGitStatus(git_repository *repository, NSError **error);
NSString *DSHAgentGitIndexDigest(git_index *index, NSError **error);
git_index *DSHAgentGitStageAll(git_repository *repository, git_oid *treeOID, NSString **indexDigest, NSError **error);
NSDictionary *DSHAgentGitCommitIdentity(NSString *tree, NSArray<NSString *> *parents, NSDictionary *identity, NSString *message, NSError **error);
NSInteger DSHAgentGitTimezoneMinutes(NSString *value);
NSString *DSHAgentGitTimezoneString(NSInteger minutes);
