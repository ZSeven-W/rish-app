#import "AgentGitToolExecutor.h"
#import "AgentGitToolSupport.h"

#import "AgentNativeWAL.h"
#import "AgentRootResolver.h"
#import "DSHGitPushSupport.h"
#import "LocalProjectAccess.h"
#import "LocalWorkspaceAccess.h"

#include <git2.h>
#include <math.h>
#include <string.h>

@interface DSHAgentGitToolExecutor ()
@property(nonatomic, strong, readwrite) DSHAgentRootResolver *rootResolver;
- (DSHLocalProjectLease *)leaseForRoot:(NSDictionary *)root
                                  mode:(DSHLocalProjectAccessMode)mode
                                 error:(NSError **)error NS_RETURNS_RETAINED;
- (nullable NSDictionary *)performForToolNamed:(NSString *)name
                                           root:(NSDictionary *)root
                                      operation:(NSDictionary *_Nullable (^)(
                                          git_repository *repository,
                                          NSError **error))operation
                                          error:(NSError **)error;
- (nullable NSDictionary *)performPushForToolNamed:(NSString *)name
                                              root:(NSDictionary *)root
                                         operation:(NSDictionary *_Nullable (^)(
                                             git_repository *repository,
                                             DSHLocalProjectLease *lease,
                                             NSError **error))operation
                                             error:(NSError **)error;
- (nullable NSDictionary *)prepareToolNamed:(NSString *)name
                                   arguments:(NSDictionary *)arguments
                                        root:(NSDictionary *)root
                                  repository:(git_repository *)repository
                                       error:(NSError **)error;
- (nullable NSDictionary *)executeToolNamed:(NSString *)name
                                   arguments:(NSDictionary *)arguments
                                        root:(NSDictionary *)root
                                precondition:(NSDictionary *)precondition
                                  repository:(git_repository *)repository
                                       error:(NSError **)error;
- (nullable NSDictionary *)executeToolNamed:(NSString *)name
                                   arguments:(NSDictionary *)arguments
                                        root:(NSDictionary *)root
                                precondition:(NSDictionary *)precondition
                                 cancelToken:(nullable DSHGitPushCancelToken *)cancelToken
                                  repository:(git_repository *)repository
                                       lease:(nullable DSHLocalProjectLease *)lease
                                       error:(NSError **)error;
- (nullable NSDictionary *)recoverToolNamed:(NSString *)name
                                   arguments:(NSDictionary *)arguments
                                        root:(NSDictionary *)root
                                precondition:(NSDictionary *)precondition
                                  repository:(git_repository *)repository
                                       error:(NSError **)error;
@end

@implementation DSHAgentGitToolExecutor

- (instancetype)initWithRootResolver:(DSHAgentRootResolver *)rootResolver {
  self = [super init];
  if (self) _rootResolver = rootResolver;
  return self;
}

- (DSHLocalProjectLease *)leaseForRoot:(NSDictionary *)root
                                  mode:(DSHLocalProjectAccessMode)mode
                                 error:(NSError **)error {
  return [self.rootResolver projectLeaseForFrozenRoot:root
                                                 mode:mode timeout:5.0
                                                error:error];
}

- (NSDictionary *)performForToolNamed:(NSString *)name
                                  root:(NSDictionary *)root
                             operation:(NSDictionary *(^)(
                                 git_repository *, NSError **))operation
                                 error:(NSError **)error {
  if (operation == nil ||
      (![name isEqualToString:@"git_status"] &&
       ![name isEqualToString:@"git_commit"] &&
       ![name isEqualToString:@"git_push"])) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  // Push intentionally remains on the established split-git lease path. The
  // legacy adapter scope in this integration is status + commit only.
  if ([name isEqualToString:@"git_push"]) {
    return [self performPushForToolNamed:name root:root
        operation:^NSDictionary *(git_repository *repository,
                                   __unused DSHLocalProjectLease *lease,
                                   NSError **operationError) {
          return operation(repository, operationError);
        } error:error];
  }
  __block NSDictionary *result = nil;
  DSHAgentRootOperationMode mode = [name isEqualToString:@"git_status"]
      ? DSHAgentRootOperationModeGitRead : DSHAgentRootOperationModeGitWrite;
  BOOL succeeded = [self.rootResolver performOperationForFrozenRoot:root
      mode:mode timeout:5.0
      block:^BOOL(__unused int descriptor, git_repository *repository,
                  NSError **blockError) {
        if (repository == nullptr) {
          DSHSetAgentNativeStoreError(blockError,
                                      DSHAgentNativeStoreErrorUnavailable);
          return NO;
        }
        result = operation(repository, blockError);
        return result != nil;
      } error:error];
  return succeeded ? result : nil;
}

- (NSDictionary *)performPushForToolNamed:(NSString *)name
                                              root:(NSDictionary *)root
                                         operation:(NSDictionary *(^)(
                                             git_repository *repository,
                                             DSHLocalProjectLease *lease,
                                             NSError **error))operation
                                             error:(NSError **)error {
  if (operation == nil || ![name isEqualToString:@"git_push"]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  DSHLocalProjectLease *lease = [self leaseForRoot:root
                                              mode:DSHLocalProjectAccessModeWrite
                                             error:error];
  return lease == nil ? nil : operation(lease.repository, lease, error);
}

- (NSDictionary *)prepareToolNamed:(NSString *)name
                          arguments:(NSDictionary *)arguments
                               root:(NSDictionary *)root
                              error:(NSError **)error {
  return [self performForToolNamed:name root:root
      operation:^NSDictionary *(git_repository *repository,
                                 NSError **operationError) {
        return [self prepareToolNamed:name arguments:arguments root:root
                            repository:repository error:operationError];
      } error:error];
}

- (NSDictionary *)prepareToolNamed:(NSString *)name
                          arguments:(NSDictionary *)arguments
                               root:(NSDictionary *)root
                         repository:(git_repository *)repository
                              error:(NSError **)error {
  NSString *capability = [name isEqualToString:@"git_status"] ? @"git_status" :
      ([name isEqualToString:@"git_commit"] ? @"git_commit" : @"git_push");
  if (![DSHAgentRootResolver validateAgentRootProjection:root error:error] ||
      ![root[@"kind"] isEqualToString:@"project"] ||
      ![root[@"capabilities"] containsObject:capability] ||
      ![arguments isKindOfClass:NSDictionary.class]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  if ([name isEqualToString:@"git_status"]) {
    if (arguments.count != 0) {
      DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
      return nil;
    }
    NSDictionary *status = DSHAgentGitStatus(repository, error);
    if (status == nil) return nil;
    return @{
      @"schema_version" : @1,
      @"precondition" : @{
        @"schema_version" : @1, @"kind" : @"git_status",
        @"head_oid" : status[@"head_oid"],
      },
      @"reserved_write_bytes" : @0,
    };
  }
  if ([name isEqualToString:@"git_commit"]) {
    if (!DSHAgentExactDictionaryKeys(arguments, @[@"message"]) ||
        !DSHAgentBoundedUTF8String(arguments[@"message"], 500, NO, nullptr)) {
      DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
      return nil;
    }
    NSString *preHead = nil;
    NSString *branch = nil;
    (void)DSHAgentGitBranchReference(repository, &branch, &preHead);
    git_oid treeOID = {};
    NSString *indexDigest = nil;
    git_index *index = DSHAgentGitStageAll(repository, &treeOID, &indexDigest, error);
    if (index == nullptr) return nil;
    git_index_free(index);
    NSString *tree = DSHAgentGitOID(&treeOID);
    NSData *messageBytes = [arguments[@"message"] dataUsingEncoding:NSUTF8StringEncoding];
    NSString *messageDigest = DSHAgentHB(@"commit-message", messageBytes, error);
    if (tree == nil || messageDigest == nil) return nil;
    NSDate *now = NSDate.date;
    NSInteger timezoneMinutes = NSTimeZone.localTimeZone.secondsFromGMT / 60;
    NSDictionary *identity = @{
      @"schema_version" : @1,
      @"name" : @"Rish Agent",
      @"email" : @"agent@rish.local",
      @"timestamp_seconds" : @((long long)floor(now.timeIntervalSince1970)),
      @"timezone_offset" : DSHAgentGitTimezoneString(timezoneMinutes),
    };
    NSArray *parents = preHead == nil ? @[] : @[preHead];
    NSDictionary *commit = DSHAgentGitCommitIdentity(tree, parents, identity,
                                                     arguments[@"message"],
                                                     error);
    if (commit == nil) return nil;
    return @{
      @"schema_version" : @1,
      @"precondition" : @{
        @"schema_version" : @2,
        @"kind" : @"git_commit",
        @"object_format" : @"sha1",
        @"pre_head_oid" : preHead ?: NSNull.null,
        @"ordered_parent_oids" : parents,
        @"staged_index_sha256" : indexDigest,
        @"tree_oid" : tree,
        @"author" : identity,
        @"committer" : identity,
        @"message_blob_ref" : messageDigest,
        @"message_sha256" : messageDigest,
        @"message_bytes" : @(messageBytes.length),
        @"encoding_header" : @"UTF-8",
        @"signature_policy" : @"unsigned",
        @"extra_headers" : @[],
        @"stage_all" : @YES,
        @"commit_payload_sha256" : commit[@"commit_payload_sha256"],
        @"expected_commit_oid" : commit[@"expected_commit_oid"],
      },
      @"reserved_write_bytes" : @0,
    };
  }
  if (![name isEqualToString:@"git_push"] || arguments.count != 0) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  NSString *branch = nil;
  NSString *targetOID = nil;
  NSString *remoteRef = DSHAgentGitBranchReference(repository, &branch, &targetOID);
  if (remoteRef == nil) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorConflict);
    return nil;
  }
  NSString *proxyURL = [self proxyForOrigin:DSHAgentGitRawOriginURL(repository)];
  if (proxyURL == (id)NSNull.null) {
    // A proxy with a plain-http origin: libgit2 would go straight past it.
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorConflict);
    return nil;
  }
  NSString *preRemote = nil;
  if (!DSHAgentGitRemoteOID(repository, remoteRef, proxyURL, &preRemote, error)) return nil;
  return @{
    @"schema_version" : @1,
    @"precondition" : @{
      @"schema_version" : @1, @"kind" : @"git_push",
      @"remote" : @"origin", @"remote_ref" : remoteRef,
      @"pre_remote_oid" : preRemote ?: NSNull.null,
      @"target_oid" : targetOID,
    },
    @"reserved_write_bytes" : @0,
  };
}

/// The cancellation token rides on the calling thread between the six- and
/// five-argument entries, so subclasses that override the five-argument
/// entry (test doubles) keep intercepting every execution.
static NSString *const DSHAgentGitActiveCancelTokenKey =
    @"dev.zseven.rish.agent-git-push.cancel-token";

- (NSDictionary *)executeToolNamed:(NSString *)name
                          arguments:(NSDictionary *)arguments
                               root:(NSDictionary *)root
                       precondition:(NSDictionary *)precondition
                        cancelToken:(DSHGitPushCancelToken *)cancelToken
                              error:(NSError **)error {
  NSMutableDictionary *thread = NSThread.currentThread.threadDictionary;
  id previous = thread[DSHAgentGitActiveCancelTokenKey];
  if (cancelToken != nil) {
    thread[DSHAgentGitActiveCancelTokenKey] = cancelToken;
  } else {
    [thread removeObjectForKey:DSHAgentGitActiveCancelTokenKey];
  }
  NSDictionary *result = [self executeToolNamed:name arguments:arguments root:root
                                   precondition:precondition error:error];
  if (previous != nil) {
    thread[DSHAgentGitActiveCancelTokenKey] = previous;
  } else {
    [thread removeObjectForKey:DSHAgentGitActiveCancelTokenKey];
  }
  return result;
}

- (NSDictionary *)executeToolNamed:(NSString *)name
                          arguments:(NSDictionary *)arguments
                               root:(NSDictionary *)root
                       precondition:(NSDictionary *)precondition
                              error:(NSError **)error {
  DSHGitPushCancelToken *cancelToken =
      NSThread.currentThread.threadDictionary[DSHAgentGitActiveCancelTokenKey];
  if ([name isEqualToString:@"git_push"]) {
    return [self performPushForToolNamed:name root:root
        operation:^NSDictionary *(git_repository *repository,
                                   DSHLocalProjectLease *lease,
                                   NSError **operationError) {
          return [self executeToolNamed:name arguments:arguments root:root
                       precondition:precondition cancelToken:cancelToken
                           repository:repository lease:lease error:operationError];
        } error:error];
  }
  return [self performForToolNamed:name root:root
      operation:^NSDictionary *(git_repository *repository,
                                 NSError **operationError) {
        return [self executeToolNamed:name arguments:arguments root:root
                         precondition:precondition cancelToken:nil
                             repository:repository lease:nil error:operationError];
      } error:error];
}

- (NSDictionary *)executeToolNamed:(NSString *)name
                          arguments:(NSDictionary *)arguments
                               root:(NSDictionary *)root
                       precondition:(NSDictionary *)precondition
                         repository:(git_repository *)repository
                              error:(NSError **)error {
  return [self executeToolNamed:name arguments:arguments root:root
                   precondition:precondition cancelToken:nil
                       repository:repository lease:nil error:error];
}

- (NSDictionary *)executeToolNamed:(NSString *)name
                          arguments:(NSDictionary *)arguments
                               root:(NSDictionary *)root
                       precondition:(NSDictionary *)precondition
                        cancelToken:(DSHGitPushCancelToken *)cancelToken
                         repository:(git_repository *)repository
                              lease:(DSHLocalProjectLease *)lease
                              error:(NSError **)error {
  if (![precondition[@"kind"] isEqual:name]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  if ([name isEqualToString:@"git_status"]) {
    NSDictionary *status = DSHAgentGitStatus(repository, error);
    if (status == nil) return nil;
    NSMutableDictionary *object = [status mutableCopy];
    object[@"schema_version"] = @1;
    NSString *feedback = DSHAgentGitCanonicalFeedback(@{
      @"schema_version" : @1, @"name" : name, @"outcome" : @"ok",
      @"payload" : object,
    }, error);
    if (feedback == nil) return nil;
    return @{
      @"schema_version" : @1, @"status" : @"ok", @"feedback" : feedback,
      @"settled_facts" : @{
        @"schema_version" : @1, @"kind" : @"git_status",
        @"head_oid" : status[@"head_oid"],
      },
      @"truncated" : @NO, @"effect_may_have_occurred" : @NO,
    };
  }
  if ([name isEqualToString:@"git_commit"]) {
    NSString *headReference = DSHAgentGitHeadReferenceName(repository);
    id expectedHead = precondition[@"pre_head_oid"];
    git_oid treeOID = {};
    NSString *indexDigest = nil;
    git_index *index = DSHAgentGitStageAll(repository, &treeOID, &indexDigest, error);
    if (index == nullptr) return nil;
    NSString *tree = DSHAgentGitOID(&treeOID);
    if (![tree isEqual:precondition[@"tree_oid"]] ||
        ![indexDigest isEqual:precondition[@"staged_index_sha256"]]) {
      git_index_free(index);
      return DSHAgentGitFailure(name, @"E_AGENT_CONFLICT", NO, error);
    }
    NSDictionary *identity = precondition[@"author"];
    git_signature *signature = nullptr;
    NSInteger offset = DSHAgentGitTimezoneMinutes(identity[@"timezone_offset"]);
    int resultCode = git_signature_new(
        &signature, "Rish Agent", "agent@rish.local",
        [identity[@"timestamp_seconds"] longLongValue], (int)offset);
    git_commit *parent = nullptr;
    git_oid parentOID = {};
    if (resultCode == 0 && expectedHead != NSNull.null) {
      resultCode = git_oid_fromstr(&parentOID, [expectedHead UTF8String]);
      if (resultCode == 0) resultCode = git_commit_lookup(&parent, repository,
                                                          &parentOID);
    }
    git_oid commitOID = {};
    git_tree *treeObject = nullptr;
    const git_commit *parents[] = { parent };
    if (resultCode == 0) {
      resultCode = git_tree_lookup(&treeObject, repository, &treeOID);
    }
    if (resultCode == 0) {
      resultCode = git_commit_create(
          &commitOID, repository, nullptr, signature, signature, "UTF-8",
          [arguments[@"message"] UTF8String], treeObject,
          parent == nullptr ? 0 : 1, parent == nullptr ? nullptr : parents);
    }
    if (treeObject != nullptr) git_tree_free(treeObject);
    if (parent != nullptr) git_commit_free(parent);
    if (signature != nullptr) git_signature_free(signature);
    NSString *commit = resultCode == 0 ? DSHAgentGitOID(&commitOID) : nil;
    if (commit == nil) {
      git_index_free(index);
      return DSHAgentGitFailure(name, @"E_AGENT_TOOL_FAILED", NO, error);
    }
    if (![commit isEqual:precondition[@"expected_commit_oid"]]) {
      git_index_free(index);
      return DSHAgentGitFailure(name, @"E_AGENT_EXECUTION_AMBIGUOUS", YES, error);
    }
    if (headReference == nil) {
      git_index_free(index);
      return DSHAgentGitFailure(name, @"E_AGENT_CONFLICT", NO, error);
    }
    git_reference *updatedReference = nullptr;
    // A zero OID is libgit2's compare-and-swap sentinel for an expected
    // absent reference.  NULL would disable matching and could overwrite a
    // branch concurrently created after preflight.
    git_oid absentOID = {};
    const git_oid *expectedOID = expectedHead == NSNull.null
        ? &absentOID : &parentOID;
    int referenceResult = git_reference_create_matching(
        &updatedReference, repository, headReference.UTF8String, &commitOID, 1,
        expectedOID, "rish agent commit");
    if (updatedReference != nullptr) git_reference_free(updatedReference);
    if (referenceResult != 0) {
      git_index_free(index);
      return DSHAgentGitFailure(name, @"E_AGENT_CONFLICT", NO, error);
    }
    // Commit creation uses an in-memory stage-all index so preflight never
    // mutates the user's index. Once the branch CAS succeeds, publish that
    // exact index so HEAD, index, and worktree settle cleanly together.
    int indexWriteResult = git_index_write(index);
    git_index_free(index);
    if (indexWriteResult != 0) {
      return DSHAgentGitFailure(name, @"E_AGENT_EXECUTION_AMBIGUOUS", YES, error);
    }
    NSString *feedback = DSHAgentGitCanonicalFeedback(@{
      @"schema_version" : @1, @"name" : name, @"outcome" : @"ok",
      @"payload" : @{
        @"schema_version" : @1, @"commit_oid" : commit, @"tree_oid" : tree,
      },
    }, error);
    if (feedback == nil) return nil;
    return @{
      @"schema_version" : @1, @"status" : @"ok", @"feedback" : feedback,
      @"settled_facts" : @{
        @"schema_version" : @1, @"kind" : @"git_commit",
        @"actual_commit_oid" : commit,
      },
      @"truncated" : @NO, @"effect_may_have_occurred" : @YES,
    };
  }
  if (![name isEqualToString:@"git_push"] || arguments.count != 0) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  NSString *branch = nil;
  NSString *headOID = nil;
  NSString *headRef = DSHAgentGitBranchReference(repository, &branch, &headOID);
  if (headRef == nil || ![headRef isEqual:precondition[@"remote_ref"]] ||
      ![headOID isEqual:precondition[@"target_oid"]]) {
    return DSHAgentGitFailure(name, @"E_AGENT_CONFLICT", NO, error);
  }
  // Origin policy: a validated HTTPS (or LAN-HTTP) URL is pushed with the
  // project-scoped Keychain credential; an absolute local path (the native
  // test fixture transport) needs none. Anything else is refused before any
  // connection is attempted.
  NSString *rawOrigin = DSHAgentGitRawOriginURL(repository);
  NSURL *validatedOrigin = DSHGitValidatedRemoteURL(rawOrigin, nil);
  BOOL localPathOrigin = validatedOrigin == nil && [rawOrigin hasPrefix:@"/"];
  if (validatedOrigin == nil && !localPathOrigin) {
    return DSHAgentGitPushFailure(name, @"E_AGENT_TOOL_FAILED",
                                  @"origin_unsafe", NO, error);
  }
  // A proxy with a plain-http origin is refused before anything else, as
  // the panel refuses it: libgit2 would send that origin past the proxy.
  NSString *proxyURL = localPathOrigin ? nil : [self proxyForOrigin:rawOrigin];
  if (proxyURL == (id)NSNull.null) {
    return DSHAgentGitPushFailure(name, @"E_AGENT_TOOL_FAILED",
                                  @"origin_unsafe", NO, error);
  }
  NSString *host = validatedOrigin.host.lowercaseString;
  NSDictionary *credential = nil;
  if (validatedOrigin != nil) {
    credential = DSHGitCredentialForScope(root[@"project_id"], host, nil);
    if (credential == nil) {
      return DSHAgentGitPushFailure(name, @"E_AGENT_TOOL_FAILED",
                                    @"credential_missing", NO, error);
    }
  }
  // The whole network phase runs through the bounded push runner on one
  // connection: advertised-ref check against the precondition, credential
  // callback, non-force upload, report-status shape check, server read-back
  // of the pushed OID, a hard time bound, and cooperative cancellation.
  int gitDescriptor = lease == nil ? -1 : lease.gitDescriptor;
  NSString *projectId = root[@"project_id"];
  NSString *receiptHost = host ?: @"localhost";
  __attribute__((objc_precise_lifetime)) DSHGitPushRequest *pushRequest =
      [[DSHGitPushRequest alloc] init];
  pushRequest.repository = repository;
  pushRequest.remoteName = @"origin";
  pushRequest.remoteURL = validatedOrigin.absoluteString;
  pushRequest.host = host;
  pushRequest.fullReference = headRef;
  pushRequest.localOID = headOID;
  pushRequest.username = credential[@"username"];
  pushRequest.token = credential[@"token"];
  pushRequest.proxyURL = proxyURL;
  pushRequest.expectedRemoteOID = precondition[@"pre_remote_oid"];
  pushRequest.cancelToken = cancelToken;
  pushRequest.timeout = 60.0;
  __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *heldLease = lease;
  pushRequest.completion = ^(DSHGitPushOutcome outcome, NSString *remoteOID) {
    (void)heldLease;
    if (outcome == DSHGitPushOutcomeSuccess && remoteOID.length > 0 &&
        gitDescriptor >= 0 && projectId.length > 0) {
      (void)DSHGitPushRecordReceipt(gitDescriptor, projectId,
          DSHGitPushReceipt(receiptHost, branch, headOID, remoteOID,
                            DSHAgentGitTimestamp()), nil);
    }
  };
  DSHGitPushResult *pushResult = DSHGitPushRun(pushRequest);
  switch (pushResult.outcome) {
    case DSHGitPushOutcomeSuccess:
      break;
    case DSHGitPushOutcomeConflict:
      return DSHAgentGitPushFailure(name, @"E_AGENT_CONFLICT", @"remote_moved",
                                    NO, error);
    case DSHGitPushOutcomeNonFastForward:
      return DSHAgentGitPushFailure(name, @"E_AGENT_CONFLICT",
                                    @"non_fast_forward", NO, error);
    case DSHGitPushOutcomeRejected:
      return DSHAgentGitPushFailure(name, @"E_AGENT_TOOL_FAILED", @"rejected",
                                    NO, error);
    case DSHGitPushOutcomeAuthFailure:
      return DSHAgentGitPushFailure(name, @"E_AGENT_TOOL_FAILED", @"auth_failed",
                                    NO, error);
    case DSHGitPushOutcomeTimedOut:
      return DSHAgentGitPushFailure(name, @"E_AGENT_EXECUTION_AMBIGUOUS",
                                    @"timeout", YES, error);
    case DSHGitPushOutcomeCancelled:
      return pushResult.effectMayHaveOccurred
          ? DSHAgentGitPushFailure(name, @"E_AGENT_EXECUTION_AMBIGUOUS",
                                   @"cancelled", YES, error)
          : DSHAgentGitPushFailure(name, @"E_AGENT_CANCELLED", @"cancelled",
                                   NO, error);
    // The person's proxy refused or could not reach the remote: named apart,
    // so the model points at the proxy, with the same rule about what may
    // have happened.
    case DSHGitPushOutcomeProxyFailed:
      return pushResult.effectMayHaveOccurred
          ? DSHAgentGitPushFailure(name, @"E_AGENT_EXECUTION_AMBIGUOUS",
                                   @"proxy", YES, error)
          : DSHAgentGitPushFailure(name, @"E_AGENT_TOOL_FAILED", @"proxy",
                                   NO, error);
    case DSHGitPushOutcomeFailed:
      // Once the request went out, a lost response cannot prove that the
      // server rejected the update.
      return pushResult.effectMayHaveOccurred
          ? DSHAgentGitPushFailure(name, @"E_AGENT_EXECUTION_AMBIGUOUS",
                                   @"transport", YES, error)
          : DSHAgentGitPushFailure(name, @"E_AGENT_TOOL_FAILED", @"transport",
                                   NO, error);
  }
  NSString *remoteOID = pushResult.remoteOID ?: headOID;
  NSString *trackingName = [@"refs/remotes/origin/" stringByAppendingString:branch];
  git_oid target = {};
  git_reference *tracking = nullptr;
  if (git_oid_fromstr(&target, headOID.UTF8String) != 0 ||
      git_reference_create(&tracking, repository, trackingName.UTF8String,
                           &target, 1, "rish agent push") != 0) {
    if (tracking != nullptr) git_reference_free(tracking);
    return DSHAgentGitFailure(name, @"E_AGENT_EXECUTION_AMBIGUOUS", YES, error);
  }
  git_reference_free(tracking);
  NSString *feedback = DSHAgentGitCanonicalFeedback(@{
    @"schema_version" : @1, @"name" : name, @"outcome" : @"ok",
    @"payload" : @{
      @"schema_version" : @1, @"remote" : @"origin",
      @"remote_ref" : headRef, @"pushed_oid" : headOID,
      @"remote_oid" : remoteOID,
    },
  }, error);
  if (feedback == nil) return nil;
  return @{
    @"schema_version" : @1, @"status" : @"ok", @"feedback" : feedback,
    @"settled_facts" : @{
      @"schema_version" : @1, @"kind" : @"git_push",
      @"actual_remote_oid" : remoteOID,
    },
    @"truncated" : @NO, @"effect_may_have_occurred" : @YES,
  };
}

- (NSDictionary *)recoverToolNamed:(NSString *)name
                          arguments:(NSDictionary *)arguments
                               root:(NSDictionary *)root
                       precondition:(NSDictionary *)precondition
                              error:(NSError **)error {
  return [self performForToolNamed:name root:root
      operation:^NSDictionary *(git_repository *repository,
                                 NSError **operationError) {
        return [self recoverToolNamed:name arguments:arguments root:root
                         precondition:precondition repository:repository
                                error:operationError];
      } error:error];
}

- (NSDictionary *)recoverToolNamed:(NSString *)name
                          arguments:(NSDictionary *)arguments
                               root:(NSDictionary *)root
                       precondition:(NSDictionary *)precondition
                         repository:(git_repository *)repository
                              error:(NSError **)error {
  if ([name isEqualToString:@"git_commit"]) {
    NSString *headOID = nil;
    (void)DSHAgentGitBranchReference(repository, nullptr, &headOID);
    if ([headOID isEqual:precondition[@"expected_commit_oid"]]) {
      return @{ @"schema_version" : @1, @"status" : @"settled",
                @"actual_commit_oid" : headOID };
    }
    id prior = precondition[@"pre_head_oid"];
    if ((prior == NSNull.null && headOID == nil) || [prior isEqual:headOID]) {
      git_oid treeOID = {};
      NSString *indexDigest = nil;
      git_index *index = DSHAgentGitStageAll(
          repository, &treeOID, &indexDigest, error);
      NSString *tree = index == nullptr ? nil : DSHAgentGitOID(&treeOID);
      if (index != nullptr) git_index_free(index);
      NSData *messageBytes = [arguments[@"message"]
          dataUsingEncoding:NSUTF8StringEncoding];
      NSString *messageSHA = messageBytes == nil ? nil
          : DSHAgentHB(@"commit-message", messageBytes, error);
      NSDictionary *commit = tree == nil ? nil : DSHAgentGitCommitIdentity(
          tree, precondition[@"ordered_parent_oids"],
          precondition[@"author"], arguments[@"message"], nil);
      BOOL frozen = commit != nil &&
          [indexDigest isEqual:precondition[@"staged_index_sha256"]] &&
          [tree isEqual:precondition[@"tree_oid"]] &&
          [messageSHA isEqual:precondition[@"message_sha256"]] &&
          [@(messageBytes.length) isEqual:precondition[@"message_bytes"]] &&
          [commit[@"commit_payload_sha256"]
              isEqual:precondition[@"commit_payload_sha256"]] &&
          [commit[@"expected_commit_oid"]
              isEqual:precondition[@"expected_commit_oid"]];
      return @{ @"schema_version" : @1,
                @"status" : frozen ? @"not_dispatched" : @"ambiguous" };
    }
    return @{ @"schema_version" : @1, @"status" : @"ambiguous" };
  }
  if ([name isEqualToString:@"git_push"]) {
    NSString *remoteRef = precondition[@"remote_ref"];
    NSString *proxyURL = [self proxyForOrigin:DSHAgentGitRawOriginURL(repository)];
    if (proxyURL == (id)NSNull.null) {
      return @{ @"schema_version" : @1, @"status" : @"ambiguous" };
    }
    NSString *actual = nil;
    if (!DSHAgentGitRemoteOID(repository, remoteRef, proxyURL, &actual, error)) {
      return nil;
    }
    if ([actual isEqual:precondition[@"target_oid"]]) {
      return @{ @"schema_version" : @1, @"status" : @"settled",
                @"actual_remote_oid" : actual };
    }
    id prior = precondition[@"pre_remote_oid"];
    if ((prior == NSNull.null && actual == nil) || [prior isEqual:actual]) {
      return @{ @"schema_version" : @1, @"status" : @"not_dispatched" };
    }
    return @{ @"schema_version" : @1, @"status" : @"ambiguous" };
  }
  return @{ @"schema_version" : @1, @"status" : @"not_dispatched" };
}

/// The proxy the remote step goes through: nil for none (or a local-path
/// origin, which has no network), NSNull when a proxy is set but the origin
/// is not https -- libgit2 would send that one straight past the proxy.
- (id)proxyForOrigin:(NSString *)rawOrigin {
  NSString *proxy = self.proxyProvider != nil ? self.proxyProvider() : nil;
  if (proxy.length == 0 || [rawOrigin hasPrefix:@"/"]) return nil;
  return [rawOrigin.lowercaseString hasPrefix:@"https://"] ? proxy : (id)NSNull.null;
}

@end
