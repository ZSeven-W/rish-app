#import "AgentGitToolSupport.h"
#import "AgentNativeWAL.h"
#include "rish_agent_core.h"
#include <string.h>

// The Git tools' judgements live in the shared core (modules/rish/core,
// `rish_agent_git_tool_reduce`): which staged paths a commit may contain, the
// exact bytes of the commit object, and therefore the id it will have.  That
// last one is load-bearing — the precondition carries `expected_commit_oid`,
// so a crash between libgit2 writing the object and the ledger recording it is
// recoverable by looking for that exact id.  Two implementations of the
// payload encoding would predict two different ids and the recovery would
// silently find nothing.  libgit2 itself stays here.
NSDictionary *DSHAgentGitReduce(NSString *op,
                                       NSDictionary *fields,
                                       NSError **error) {
  NSMutableDictionary *envelope = [fields mutableCopy];
  envelope[@"op"] = op;
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:envelope options:0
                                                    error:nil];
  char *raw = bytes == nil ? NULL : rish_agent_git_tool_reduce(
      (const char *)bytes.bytes, bytes.length);
  if (raw == NULL) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  NSData *replyBytes = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  id reply = [NSJSONSerialization JSONObjectWithData:replyBytes options:0
                                                error:nil];
  if (![reply isKindOfClass:NSDictionary.class]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  if ([reply[@"ok"] isEqual:@YES]) {
    if (error != nullptr) *error = nil;
    return reply;
  }
  NSInteger code = [reply[@"error"] isKindOfClass:NSNumber.class]
      ? [reply[@"error"] integerValue] : 0;
  if (code < DSHAgentNativeStoreErrorInvalidArgument ||
      code > DSHAgentNativeStoreErrorPersistence) {
    code = DSHAgentNativeStoreErrorCorrupt;
  }
  DSHSetAgentNativeStoreError(error, (DSHAgentNativeStoreErrorCode)code);
  return nil;
}

NSString *DSHAgentGitOID(const git_oid *oid) {
  if (oid == nullptr) return nil;
  char value[65] = {};
  git_oid_tostr(value, sizeof(value), oid);
  return [NSString stringWithUTF8String:value];
}

NSString *DSHAgentGitTimestamp(void) {
  static NSISO8601DateFormatter *formatter = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime
      | NSISO8601DateFormatWithFractionalSeconds;
  });
  return [formatter stringFromDate:NSDate.date];
}

NSString *DSHAgentGitCanonicalFeedback(NSDictionary *feedback,
                                               NSError **error) {
  NSData *bytes = DSHAgentCanonicalJSON(feedback, error);
  NSString *value = bytes == nil ? nil
      : [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
  if (value == nil || !DSHAgentValidateNativeToolFeedbackString(value, error)) {
    return nil;
  }
  return value;
}

NSDictionary *DSHAgentGitFailureWithReason(NSString *name,
                                                   NSString *failureCode,
                                                   NSString *reason,
                                                   BOOL ambiguous,
                                                   NSError **error) {
  NSMutableDictionary *request = [@{
    @"name" : name ?: NSNull.null,
    @"failure_code" : failureCode ?: NSNull.null,
    @"ambiguous" : @(ambiguous),
  } mutableCopy];
  if (reason != nil) request[@"reason"] = reason;
  return DSHAgentGitReduce(@"failure_result", request, error)[@"result"];
}

NSDictionary *DSHAgentGitFailure(NSString *name,
                                         NSString *failureCode,
                                         BOOL ambiguous,
                                         NSError **error) {
  return DSHAgentGitFailureWithReason(name, failureCode, nil, ambiguous, error);
}

NSString *DSHAgentGitBranchReference(git_repository *repository,
                                             NSString **branchOut,
                                             NSString **headOIDOut) {
  git_reference *head = nullptr;
  if (git_repository_head(&head, repository) != 0 ||
      git_reference_target(head) == nullptr) {
    if (head != nullptr) git_reference_free(head);
    return nil;
  }
  NSString *reference = [NSString stringWithUTF8String:git_reference_name(head)];
  const char *shorthand = git_reference_shorthand(head);
  NSString *branch = shorthand == nullptr ? nil
      : [NSString stringWithUTF8String:shorthand];
  NSString *oid = DSHAgentGitOID(git_reference_target(head));
  git_reference_free(head);
  if (![reference hasPrefix:@"refs/heads/"] || branch.length == 0 || oid == nil) {
    return nil;
  }
  if (branchOut != nullptr) *branchOut = branch;
  if (headOIDOut != nullptr) *headOIDOut = oid;
  return reference;
}

NSString *DSHAgentGitHeadReferenceName(git_repository *repository) {
  NSString *reference = DSHAgentGitBranchReference(repository, nullptr, nullptr);
  if (reference != nil) return reference;
  git_reference *head = nullptr;
  if (git_reference_lookup(&head, repository, "HEAD") != 0) return nil;
  const char *symbolic = git_reference_symbolic_target(head);
  NSString *value = symbolic == nullptr ? nil
      : [NSString stringWithUTF8String:symbolic];
  git_reference_free(head);
  return [value hasPrefix:@"refs/heads/"] ? value : nil;
}

NSString *DSHAgentGitRawOriginURL(git_repository *repository) {
  git_config *config = nullptr;
  git_buf value = GIT_BUF_INIT;
  int result = git_repository_config(&config, repository);
  if (result == 0) {
    result = git_config_get_string_buf(&value, config, "remote.origin.url");
  }
  NSString *raw = result == 0 && value.ptr != nullptr
    ? [NSString stringWithUTF8String:value.ptr] : nil;
  git_buf_dispose(&value);
  if (config != nullptr) git_config_free(config);
  return raw;
}

/// git_push failures carry a value-free `reason` next to the stable failure
/// code so the model can distinguish a non-fast-forward conflict from a
/// moved remote or a rejected credential without any server text.
/// git_push failures carry a value-free `reason` next to the stable failure
/// code so the model can distinguish a non-fast-forward conflict from a
/// moved remote or a rejected credential without any server text.  The set of
/// tokens is closed in the core, so a server string cannot become one.
NSDictionary *DSHAgentGitPushFailure(NSString *name,
                                             NSString *failureCode,
                                             NSString *reason,
                                             BOOL ambiguous,
                                             NSError **error) {
  return DSHAgentGitFailureWithReason(name, failureCode, reason, ambiguous,
                                      error);
}

BOOL DSHAgentGitRemoteOID(git_repository *repository,
                                 NSString *remoteRef,
                                 NSString *proxyURL,
                                 NSString **oidOut,
                                 NSError **error) {
  git_remote *remote = nullptr;
  git_remote_callbacks callbacks = {};
  git_proxy_options proxy = {};
  callbacks.version = GIT_REMOTE_CALLBACKS_VERSION;
  proxy.version = GIT_PROXY_OPTIONS_VERSION;
  proxy.type = proxyURL.length > 0 ? GIT_PROXY_SPECIFIED : GIT_PROXY_NONE;
  proxy.url = proxyURL.length > 0 ? proxyURL.UTF8String : nullptr;
  int code = git_remote_lookup(&remote, repository, "origin");
  if (code == 0) {
    code = git_remote_connect(remote, GIT_DIRECTION_FETCH, &callbacks, &proxy,
                              nullptr);
  }
  const git_remote_head **heads = nullptr;
  size_t count = 0;
  if (code == 0) code = git_remote_ls(&heads, &count, remote);
  NSString *resolved = nil;
  if (code == 0) {
    for (size_t index = 0; index < count; index += 1) {
      if (heads[index] != nullptr && heads[index]->name != nullptr &&
          strcmp(heads[index]->name, remoteRef.UTF8String) == 0) {
        resolved = DSHAgentGitOID(&heads[index]->oid);
        break;
      }
    }
  }
  if (remote != nullptr) {
    git_remote_disconnect(remote);
    git_remote_free(remote);
  }
  if (code != 0) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorUnavailable);
    return NO;
  }
  if (oidOut != nullptr) *oidOut = resolved;
  return YES;
}

NSDictionary *DSHAgentGitStatus(git_repository *repository,
                                        NSError **error) {
  git_status_options options = {};
  if (git_status_options_init(&options, GIT_STATUS_OPTIONS_VERSION) != 0) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorUnavailable);
    return nil;
  }
  options.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR;
  options.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED |
      GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS |
      GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX |
      GIT_STATUS_OPT_RENAMES_INDEX_TO_WORKDIR;
  git_status_list *list = nullptr;
  if (git_status_list_new(&list, repository, &options) != 0) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorUnavailable);
    return nil;
  }
  size_t count = git_status_list_entrycount(list);
  BOOL conflicts = NO;
  for (size_t index = 0; index < count; index += 1) {
    const git_status_entry *entry = git_status_byindex(list, index);
    if (entry != nullptr && (entry->status & GIT_STATUS_CONFLICTED) != 0) {
      conflicts = YES;
    }
  }
  git_status_list_free(list);
  NSString *branch = nil;
  NSString *headOID = nil;
  (void)DSHAgentGitBranchReference(repository, &branch, &headOID);
  return @{
    @"branch" : branch ?: NSNull.null,
    @"head_oid" : headOID ?: NSNull.null,
    @"clean" : @(count == 0),
    @"has_conflicts" : @(conflicts),
    @"entry_count" : @(count),
  };
}

/// Hands the staged index to the core exactly as libgit2 reported it.  Which
/// paths and modes may be committed, and the digest the precondition is taken
/// over, are decided there.  A name that is not UTF-8 cannot be reported at
/// all, so that one refusal stays here.
NSString *DSHAgentGitIndexDigest(git_index *index, NSError **error) {
  NSMutableArray *entries = [NSMutableArray array];
  size_t count = git_index_entrycount(index);
  for (size_t item = 0; item < count; item += 1) {
    const git_index_entry *entry = git_index_get_byindex(index, item);
    if (entry == nullptr || entry->path == nullptr) {
      DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
      return nil;
    }
    NSString *path = [[NSString alloc]
        initWithBytes:entry->path length:strlen(entry->path)
             encoding:NSUTF8StringEncoding];
    NSString *oid = DSHAgentGitOID(&entry->id);
    if (path == nil) {
      // libgit2 accepts byte paths that cannot cross the JSON boundary. The
      // call is valid; this index cannot be committed by the agent.
      DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorConflict);
      return nil;
    }
    if (oid == nil) {
      DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
      return nil;
    }
    [entries addObject:@{
      @"path" : path,
      @"mode" : @((unsigned long long)entry->mode),
      @"oid" : oid,
      @"stage" : @(git_index_entry_stage(entry)),
    }];
  }
  return DSHAgentGitReduce(@"index_digest", @{ @"entries" : entries },
                           error)[@"staged_index_sha256"];
}

git_index *DSHAgentGitStageAll(git_repository *repository,
                                      git_oid *treeOID,
                                      NSString **indexDigest,
                                      NSError **error) {
  git_index *index = nullptr;
  if (git_repository_index(&index, repository) != 0 ||
      git_index_read(index, 1) != 0 ||
      git_index_add_all(index, nullptr, GIT_INDEX_ADD_DEFAULT, nullptr, nullptr) != 0 ||
      git_index_update_all(index, nullptr, nullptr, nullptr) != 0 ||
      git_index_write_tree_to(treeOID, index, repository) != 0) {
    if (index != nullptr) git_index_free(index);
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorUnavailable);
    return nullptr;
  }
  NSString *digest = DSHAgentGitIndexDigest(index, error);
  if (digest == nil) {
    git_index_free(index);
    return nullptr;
  }
  if (indexDigest != nullptr) *indexDigest = digest;
  return index;
}

/// The commit object's digest and the id it will have, from the core, as one
/// answer.  Returns nil when the identity cannot be spelled at all.
NSDictionary *DSHAgentGitCommitIdentity(NSString *tree,
                                                NSArray<NSString *> *parents,
                                                NSDictionary *identity,
                                                NSString *message,
                                                NSError **error) {
  if (tree == nil || parents == nil || message == nil) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  return DSHAgentGitReduce(@"commit_identity", @{
    @"tree_oid" : tree,
    @"parents" : parents,
    @"timestamp_seconds" :
        [identity[@"timestamp_seconds"] isKindOfClass:NSNumber.class]
            ? [identity[@"timestamp_seconds"] stringValue] : @"",
    @"timezone_offset" : identity[@"timezone_offset"] ?: @"",
    @"message" : message,
  }, error);
}

/// The inverse, for handing the stored offset back to libgit2's signature.
NSInteger DSHAgentGitTimezoneMinutes(NSString *value) {
  NSDictionary *reply = DSHAgentGitReduce(@"timezone_minutes", @{
    @"timezone_offset" : value ?: @"",
  }, nullptr);
  id minutes = reply[@"minutes"];
  return [minutes isKindOfClass:NSNumber.class] ? [minutes integerValue] : 0;
}

NSString *DSHAgentGitTimezoneString(NSInteger minutes) {
  NSDictionary *reply = DSHAgentGitReduce(@"timezone_string", @{
    @"minutes" : @((long long)minutes),
  }, nullptr);
  id offset = reply[@"timezone_offset"];
  return [offset isKindOfClass:NSString.class] ? offset : @"+0000";
}
