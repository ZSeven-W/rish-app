#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <React/RCTBridgeModule.h>
#import <React/RCTUtils.h>
#import <Security/Security.h>
#import <UIKit/UIKit.h>

#include "rish_agent_core.h"

#import "DSHGitPushSupport.h"
#import "DSHGitSSHSupport.h"
#import "LocalProjectAccess.h"
#import "LocalWorkspaceAccess.h"
#import "WorkspaceClearanceStore.h"

#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <git2.h>
#include <netinet/in.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString *const LPRemoteName = @"origin";
static NSUInteger const LPMaxProjectNameBytes = 120;
static NSUInteger const LPMaxStatusEntries = 10000;
static NSUInteger const LPMaxDiffFiles = 1000;
static NSUInteger const LPMaxDiffBytes = 1024 * 1024;
static NSUInteger const LPMaxCommitMessageBytes = 64 * 1024;
static NSUInteger const LPMaxCheckoutEntries = 100000;
static NSUInteger const LPMaxCheckoutDepth = 64;
// Cleanup begins one directory above the validated checkout, at the staging
// wrapper. Preserve the checkout limit while accounting for that wrapper.
static NSUInteger const LPMaxCleanupDepth = LPMaxCheckoutDepth + 1;
static NSUInteger const LPMaxOrphansPerReconcile = 128;
static NSUInteger const LPMaxOrphanCleanupEntriesPerPass = 128;
static NSUInteger const LPMaxStagingOwnerBytes = 1024;
static NSString *const LPStagingOwnerMarker = @".rish-staging-owner.json";
static NSUInteger const LPV2MaxDiffBytes = 1024 * 1024;
static NSUInteger const LPV2MaxCommitMessageBytes = 500;
static NSUInteger const LPV2MaxCredentialReferenceBytes = 256;
static NSTimeInterval const LPPushTimeoutSeconds = 60.0;
static NSUInteger const LPV2MaxAttachJournalBytes = 16 * 1024;
static NSString *const LPV2BindingFile = @"binding-v2.json";
static NSString *const LPV2GitTopology = @"private_split_gitdir";
typedef BOOL (^LPV2AttachFaultHook)(NSString *stage);

// LocalWorkspaceAccess intentionally keeps authority storage private.  This
// narrow native-only category is used to read the already verified root
// fingerprint and to publish the private Git binding; none of these methods
// or objects cross the React Native boundary.
@interface DSHLocalWorkspaceAccess (DSHLocalProjectsPrivateAccess)
@property(nonatomic, strong) NSURL *privateRootURL;
- (nullable NSURL *)ownedWorkspacesRootURL;
- (nullable NSDictionary *)loadRegistry:(NSError **)error
                                  digest:(NSString *_Nullable *_Nullable)digest;
- (nullable NSDictionary *)recordInRegistry:(NSDictionary *)registry
                                  workspaceId:(NSString *)workspaceId;
- (nullable NSDictionary *)loadAuthorityForRecord:(NSDictionary *)record
                                             error:(NSError **)error;
@end

static NSError *LPError(NSInteger code, NSString *message) {
  return [NSError errorWithDomain:@"LocalProjects"
                             code:code
                         userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString *LPString(id value) {
  return [value isKindOfClass:NSString.class] ? value : nil;
}

/// Validates either the existing HTTPS remote grammar or the native SSH
/// grammar. SSH is kept out of the HTTPS token credential path.
static NSURL *LPValidatedRemoteURL(id value, NSError **error) {
  NSURL *https = DSHGitValidatedRemoteURL(value, nil);
  if (https != nil) return https;
  NSDictionary *ssh = DSHGitSSHValidatedRemote(value, error);
  if (ssh == nil) return nil;
  return [NSURL URLWithString:ssh[@"canonical_url"]];
}

static NSDictionary *LPDictionary(id value) {
  return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static BOOL LPHasControlCharacter(NSString *value);
static BOOL LPSameNode(const struct stat &left, const struct stat &right);

static BOOL LPV2ExactKeys(NSDictionary *value, NSArray<NSString *> *keys) {
  if (![value isKindOfClass:NSDictionary.class] || value.count != keys.count) {
    return NO;
  }
  return [[NSSet setWithArray:value.allKeys]
      isEqualToSet:[NSSet setWithArray:keys]];
}

static BOOL LPV2SafeRevision(id value) {
  if (![value isKindOfClass:NSNumber.class] ||
      CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() ||
      [value isKindOfClass:NSDecimalNumber.class]) {
    return NO;
  }
  double number = [value doubleValue];
  if (!isfinite(number) || signbit(number) || floor(number) != number ||
      number < 1.0 || number > 9007199254740991.0) {
    return NO;
  }
  unsigned long long exact = [value unsignedLongLongValue];
  return (double)exact == number && exact >= 1 &&
      exact <= 9007199254740991ULL;
}

// What a project operation's arguments have to be, and which code a failure is
// reported to JavaScript as, live in the shared core (modules/rish/core,
// `rish_agent_project_module_reduce`).
static NSDictionary *LPV2Reduce(NSString *op, NSDictionary *fields) {
  NSMutableDictionary *envelope = [fields mutableCopy];
  envelope[@"op"] = op;
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:envelope options:0
                                                    error:nil];
  char *raw = bytes == nil ? NULL : rish_agent_project_module_reduce(
      (const char *)bytes.bytes, bytes.length);
  if (raw == NULL) return nil;
  NSData *replyBytes = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  id reply = [NSJSONSerialization JSONObjectWithData:replyBytes options:0
                                                error:nil];
  return [reply isKindOfClass:NSDictionary.class] &&
      [reply[@"ok"] isEqual:@YES] ? reply : nil;
}

static BOOL LPV2CanonicalOID(id value, BOOL allowNull) {
  return [LPV2Reduce(@"canonical_oid", @{
    @"value" : value ?: NSNull.null,
    @"allow_null" : allowNull ? @YES : @NO,
  })[@"valid"] isEqual:@YES];
}

static BOOL LPV2CanonicalDigest(id value) {
  NSString *digest = LPString(value);
  if (digest.length != 64) return NO;
  NSCharacterSet *hex =
      [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
  return [digest rangeOfCharacterFromSet:hex.invertedSet].location == NSNotFound;
}

static BOOL LPV2CanonicalOperationId(id value) {
  return [LPV2Reduce(@"canonical_operation_id", @{
    @"value" : value ?: NSNull.null,
  })[@"valid"] isEqual:@YES];
}

static BOOL LPV2BoundedString(id value, NSUInteger maximumBytes,
                              BOOL allowEmpty) {
  return [LPV2Reduce(@"bounded_string", @{
    @"value" : value ?: NSNull.null,
    @"maximum_bytes" : @((unsigned long long)maximumBytes),
    @"allow_empty" : allowEmpty ? @YES : @NO,
  })[@"valid"] isEqual:@YES];
}

static NSDictionary *LPV2Root(id value, BOOL projectRequired, NSError **error) {
  NSDictionary *root = LPDictionary(value);
  if (!LPV2ExactKeys(root, @[
        @"schema_version", @"workspace_id", @"binding_revision", @"project_id"
      ]) || ![root[@"schema_version"] isKindOfClass:NSNumber.class] ||
      CFGetTypeID((__bridge CFTypeRef)root[@"schema_version"]) ==
          CFBooleanGetTypeID() ||
      [root[@"schema_version"] isKindOfClass:NSDecimalNumber.class] ||
      ![root[@"schema_version"] isEqual:@1] ||
      ![DSHLocalProjectAccess isCanonicalProjectId:LPString(root[@"workspace_id"])] ||
      !LPV2SafeRevision(root[@"binding_revision"])) {
    if (error != nil) *error = LPError(3101, @"Workspace root is invalid");
    return nil;
  }
  id project = root[@"project_id"];
  if (project == NSNull.null) {
    if (projectRequired) {
      if (error != nil) *error = LPError(3101, @"Workspace root is invalid");
      return nil;
    }
  } else if (![DSHLocalProjectAccess isCanonicalProjectId:LPString(project)]) {
    if (error != nil) *error = LPError(3101, @"Workspace root is invalid");
    return nil;
  }
  return @{
    @"schema_version" : @1,
    @"workspace_id" : [root[@"workspace_id"] copy],
    @"binding_revision" : @([root[@"binding_revision"] unsignedLongLongValue]),
    @"project_id" : project == NSNull.null ? NSNull.null : [project copy],
  };
}

static BOOL LPV2RootsEqual(NSDictionary *left, NSDictionary *right) {
  NSDictionary *a = LPV2Root(left, NO, nil);
  NSDictionary *b = LPV2Root(right, NO, nil);
  return a != nil && b != nil && [a isEqual:b];
}

static NSDictionary *LPV2ReadAttachJournal(NSURL *url,
                                           NSString *workspaceId,
                                           NSString *operationId,
                                           NSError **error) {
  struct stat before = {};
  if (url == nil || lstat(url.fileSystemRepresentation, &before) != 0 ||
      !S_ISREG(before.st_mode) || S_ISLNK(before.st_mode) ||
      before.st_nlink != 1 || before.st_size <= 0 ||
      before.st_size > (off_t)LPV2MaxAttachJournalBytes) {
    if (error != nil) *error = LPError(3104, @"Attach journal is unsafe");
    return nil;
  }
  int descriptor = open(url.fileSystemRepresentation,
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  struct stat opened = {};
  BOOL valid = descriptor >= 0 && fstat(descriptor, &opened) == 0 &&
      LPSameNode(before, opened) && opened.st_size == before.st_size;
  NSMutableData *data = valid
      ? [NSMutableData dataWithLength:(NSUInteger)opened.st_size] : nil;
  NSUInteger offset = 0;
  while (valid && offset < data.length) {
    ssize_t count = pread(descriptor,
        static_cast<uint8_t *>(data.mutableBytes) + offset,
        data.length - offset, (off_t)offset);
    if (count <= 0) { valid = NO; break; }
    offset += (NSUInteger)count;
  }
  struct stat after = {};
  valid = valid && fstat(descriptor, &after) == 0 &&
      LPSameNode(opened, after) && after.st_size == opened.st_size;
  if (descriptor >= 0) close(descriptor);
  NSDictionary *journal = valid ? LPDictionary([NSJSONSerialization
      JSONObjectWithData:data options:0 error:nil]) : nil;
  if (!LPV2ExactKeys(journal, @[
        @"schema_version", @"operation_id", @"workspace_id",
        @"binding_revision", @"project_id", @"root_fingerprint_sha256",
        @"staging_name", @"final_name", @"phase"
      ]) || ![journal[@"schema_version"] isEqual:@1] ||
      ![journal[@"operation_id"] isEqual:operationId] ||
      ![journal[@"workspace_id"] isEqual:workspaceId] ||
      !LPV2SafeRevision(journal[@"binding_revision"]) ||
      ![DSHLocalProjectAccess isCanonicalProjectId:journal[@"project_id"]] ||
      !LPV2CanonicalDigest(journal[@"root_fingerprint_sha256"]) ||
      ![journal[@"staging_name"] isEqual:
          [NSString stringWithFormat:@".rish-attach-%@", operationId]] ||
      ![journal[@"final_name"] isEqual:journal[@"project_id"]] ||
      !([journal[@"phase"] isEqual:@"prepared"] ||
        [journal[@"phase"] isEqual:@"published"])) {
    if (error != nil) *error = LPError(3104, @"Attach journal is invalid");
    return nil;
  }
  return journal;
}

static NSString *LPV2StableErrorCode(NSError *error) {
  id code = LPV2Reduce(@"stable_error_code", @{
    @"domain" : error.domain ?: @"",
    @"code" : @((long long)error.code),
  })[@"code"];
  return [code isKindOfClass:NSString.class] ? code : @"E_PROJECT_NATIVE";
}

static void LPV2Reject(RCTPromiseRejectBlock reject, NSError *error) {
  NSString *code = LPV2StableErrorCode(error);
  reject(code, code, nil);
}

static NSString *LPV2DescriptorPath(int descriptor) {
  if (descriptor < 0) return nil;
  char path[PATH_MAX] = {};
  if (fcntl(descriptor, F_GETPATH, path) != 0 || path[0] != '/') return nil;
  return [[NSFileManager defaultManager]
      stringWithFileSystemRepresentation:path length:strlen(path)];
}

static NSString *LPV2ProjectDisplayName(DSHLocalProjectLease *lease) {
  NSString *name = LPString(lease.metadata[@"name"]);
  if (name.length == 0 || LPHasControlCharacter(name) ||
      [name containsString:@"/"] || [name containsString:@"\\"] ||
      [name isEqual:@"."] || [name isEqual:@".."]) {
    return lease.projectId;
  }
  return name;
}

static NSString *LPV2ClipUTF8(NSString *value, NSUInteger maximumBytes,
                              BOOL *truncated) {
  NSDictionary *reply = [value isKindOfClass:NSString.class]
      ? LPV2Reduce(@"clip_utf8", @{
          @"value" : value,
          @"maximum_bytes" : @((unsigned long long)maximumBytes),
        })
      : nil;
  id clipped = reply[@"value"];
  if (![clipped isKindOfClass:NSString.class]) {
    if (truncated != nullptr) *truncated = NO;
    return value ?: @"";
  }
  if (truncated != nullptr) *truncated = [reply[@"truncated"] isEqual:@YES];
  return clipped;
}

static NSString *LPNow(void) {
  static NSISO8601DateFormatter *formatter = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime
      | NSISO8601DateFormatWithFractionalSeconds;
  });
  return [formatter stringFromDate:NSDate.date];
}

static BOOL LPHasControlCharacter(NSString *value) {
  return [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location
    != NSNotFound;
}

static NSString *LPValidatedHTTPSProxyURL(id optionsValue, NSError **error) {
  if (optionsValue == nil || optionsValue == NSNull.null) return nil;
  NSDictionary *options = LPDictionary(optionsValue);
  if (options == nil) {
    if (error != nil) *error = LPError(3003, @"HTTPS proxy options are invalid");
    return nil;
  }
  id proxyValue = options[@"httpsProxyUrl"];
  if (proxyValue == nil || proxyValue == NSNull.null) return nil;
  NSString *input = LPString(proxyValue);
  if (input == nil) {
    if (error != nil) *error = LPError(3003, @"HTTPS proxy URL is invalid");
    return nil;
  }
  if (input.length == 0) return nil;
  if (input.length > 2048 || LPHasControlCharacter(input)
    || ![input isEqualToString:[input stringByTrimmingCharactersInSet:
      NSCharacterSet.whitespaceAndNewlineCharacterSet]]) {
    if (error != nil) *error = LPError(3003, @"HTTPS proxy URL is invalid");
    return nil;
  }
  NSURLComponents *components = [NSURLComponents componentsWithString:input];
  NSString *scheme = components.scheme.lowercaseString;
  NSString *host = components.host;
  NSNumber *port = components.port;
  NSString *path = components.path;
  BOOL valid = ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])
    && host.length > 0 && !LPHasControlCharacter(host)
    && port != nil && port.integerValue >= 1 && port.integerValue <= 65535
    && (path.length == 0 || [path isEqualToString:@"/"])
    && components.user == nil && components.password == nil
    && components.query == nil && components.fragment == nil
    && components.URL != nil;
  if (!valid) {
    if (error != nil) *error = LPError(3003, @"HTTPS proxy URL is invalid");
    return nil;
  }
  NSURLComponents *canonical = [[NSURLComponents alloc] init];
  canonical.scheme = scheme;
  canonical.host = host;
  canonical.port = port;
  canonical.path = @"/";
  NSString *proxyURL = canonical.URL.absoluteString;
  if (proxyURL.length == 0 || proxyURL.length > 2048) {
    if (error != nil) *error = LPError(3003, @"HTTPS proxy URL is invalid");
    return nil;
  }
  return proxyURL;
}

static NSString *LPValidatedSSHProfileId(id optionsValue, NSError **error) {
  if (optionsValue == nil || optionsValue == NSNull.null) return nil;
  NSDictionary *options = LPDictionary(optionsValue);
  if (options == nil) {
    if (error) *error = LPError(3004, @"SSH profile options are invalid");
    return nil;
  }
  id value = options[@"sshProfileId"];
  if (value == nil || value == NSNull.null) return nil;
  NSString *profile = LPString(value);
  if (profile.length == 0 || profile.length > 128 || LPHasControlCharacter(profile)) {
    if (error) *error = LPError(3004, @"SSH profile id is invalid");
    return nil;
  }
  return profile;
}

static NSString *LPValidatedProjectName(id value, NSError **error) {
  NSString *name = [LPString(value) stringByTrimmingCharactersInSet:
    NSCharacterSet.whitespaceAndNewlineCharacterSet];
  NSUInteger bytes = [name lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
  if (name == nil || bytes == 0 || bytes > LPMaxProjectNameBytes
    || LPHasControlCharacter(name) || [name containsString:@"/"]
    || [name containsString:@"\\"] || [name isEqualToString:@"."]
    || [name isEqualToString:@".."]) {
    if (error != nil) *error = LPError(3001, @"Project name is invalid");
    return nil;
  }
  return name;
}

static BOOL LPIsSafeRepositoryPath(NSString *path) {
  if (path.length == 0 || [path hasPrefix:@"/"] || [path containsString:@"\\"]
    || LPHasControlCharacter(path)) return NO;
  for (NSString *component in [path componentsSeparatedByString:@"/"]) {
    if (component.length == 0 || [component isEqualToString:@"."]
      || [component isEqualToString:@".."]
      || [component isEqualToString:@".git"]) return NO;
  }
  return YES;
}

/// Optional `branch` push option: publish HEAD under a new local branch name.
/// Absent or empty means "push the current branch".
static BOOL LPValidatedPushBranchOption(id optionsValue, NSString **branchOut,
                                        NSError **error) {
  if (branchOut != nullptr) *branchOut = nil;
  if (optionsValue == nil || optionsValue == NSNull.null) return YES;
  NSDictionary *options = LPDictionary(optionsValue);
  id value = options[@"branch"];
  if (value == nil || value == NSNull.null) return YES;
  NSString *branch = LPString(value);
  if (branch != nil && branch.length == 0) return YES;
  NSString *fullName = [@"refs/heads/" stringByAppendingString:branch ?: @""];
  char normalized[2048] = {};
  BOOL valid = branch != nil
    && [branch lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= 1024
    && !LPHasControlCharacter(branch) && ![branch containsString:@" "]
    && ![branch containsString:@".."] && ![branch hasPrefix:@"-"]
    && ![branch hasSuffix:@".lock"] && LPIsSafeRepositoryPath(branch)
    && git_reference_normalize_name(normalized, sizeof(normalized),
                                    fullName.UTF8String,
                                    GIT_REFERENCE_FORMAT_NORMAL) == 0
    && strcmp(normalized, fullName.UTF8String) == 0;
  if (!valid) {
    if (error != nil) *error = LPError(3004, @"Branch name is invalid");
    return NO;
  }
  if (branchOut != nullptr) *branchOut = branch;
  return YES;
}

static NSString *LPOidString(const git_oid *oid) {
  if (oid == nullptr) return nil;
  char buffer[GIT_OID_SHA1_HEXSIZE + 1] = {};
  git_oid_tostr(buffer, sizeof(buffer), oid);
  return [NSString stringWithUTF8String:buffer];
}

static NSString *LPStatusName(unsigned int status, BOOL index) {
  if (status & GIT_STATUS_CONFLICTED) return @"modified";
  if (index) {
    if (status & GIT_STATUS_INDEX_NEW) return @"added";
    if (status & GIT_STATUS_INDEX_MODIFIED) return @"modified";
    if (status & GIT_STATUS_INDEX_DELETED) return @"deleted";
    if (status & GIT_STATUS_INDEX_RENAMED) return @"renamed";
    if (status & GIT_STATUS_INDEX_TYPECHANGE) return @"typechange";
  } else {
    if (status & GIT_STATUS_WT_NEW) return @"added";
    if (status & GIT_STATUS_WT_MODIFIED) return @"modified";
    if (status & GIT_STATUS_WT_DELETED) return @"deleted";
    if (status & GIT_STATUS_WT_RENAMED) return @"renamed";
    if (status & GIT_STATUS_WT_TYPECHANGE) return @"typechange";
    if (status & GIT_STATUS_WT_UNREADABLE) return @"unreadable";
  }
  return @"unmodified";
}

static NSString *LPDiffStatusName(git_delta_t status) {
  switch (status) {
    case GIT_DELTA_ADDED:
    case GIT_DELTA_UNTRACKED:
      return @"added";
    case GIT_DELTA_DELETED:
      return @"deleted";
    case GIT_DELTA_RENAMED:
    case GIT_DELTA_COPIED:
      return @"renamed";
    case GIT_DELTA_TYPECHANGE:
      return @"typechange";
    case GIT_DELTA_UNREADABLE:
      return @"unreadable";
    case GIT_DELTA_UNMODIFIED:
      return @"unmodified";
    default:
      return @"modified";
  }
}

static NSString *LPGitErrorClassName(int errorClass) {
  switch (errorClass) {
    case GIT_ERROR_OS: return @"os";
    case GIT_ERROR_NET: return @"network";
    case GIT_ERROR_SSL: return @"tls";
    case GIT_ERROR_HTTP: return @"http";
    case GIT_ERROR_CALLBACK: return @"callback";
    case GIT_ERROR_CHECKOUT: return @"checkout";
    case GIT_ERROR_REPOSITORY: return @"repository";
    case GIT_ERROR_CONFIG: return @"config";
    case GIT_ERROR_INDEXER: return @"indexer";
    case GIT_ERROR_FILESYSTEM: return @"filesystem";
    default: return @"git";
  }
}

static NSString *LPSanitizedGitFailure(NSString *operation, int result) {
  const git_error *last = git_error_last();
  int errorClass = last == nullptr ? GIT_ERROR_NONE : last->klass;
  return [NSString stringWithFormat:@"%@ failed (code %d, class %@/%d)",
    operation, result, LPGitErrorClassName(errorClass), errorClass];
}

static NSString *LPPathForStatusEntry(const git_status_entry *entry) {
  const char *path = nullptr;
  if (entry->index_to_workdir != nullptr) {
    path = entry->index_to_workdir->new_file.path ?: entry->index_to_workdir->old_file.path;
  }
  if (path == nullptr && entry->head_to_index != nullptr) {
    path = entry->head_to_index->new_file.path ?: entry->head_to_index->old_file.path;
  }
  return path == nullptr ? nil : [NSString stringWithUTF8String:path];
}

static int LPHeadTree(git_tree **tree, git_repository *repository) {
  git_reference *head = nullptr;
  git_commit *commit = nullptr;
  int result = git_repository_head(&head, repository);
  if (result == 0) {
    const git_oid *oid = git_reference_target(head);
    result = oid == nullptr ? GIT_ENOTFOUND : git_commit_lookup(&commit, repository, oid);
  }
  if (result == 0) result = git_commit_tree(tree, commit);
  if (commit != nullptr) git_commit_free(commit);
  if (head != nullptr) git_reference_free(head);
  return result;
}

static BOOL LPDirectoryIsSafe(NSURL *url) {
  struct stat metadata = {};
  return lstat(url.fileSystemRepresentation, &metadata) == 0
    && S_ISDIR(metadata.st_mode) && !S_ISLNK(metadata.st_mode);
}

static BOOL LPSameNode(const struct stat &left, const struct stat &right) {
  return left.st_dev == right.st_dev && left.st_ino == right.st_ino &&
      left.st_mode == right.st_mode;
}

static BOOL LPWriteAll(int descriptor, NSData *data) {
  const uint8_t *bytes = static_cast<const uint8_t *>(data.bytes);
  size_t offset = 0;
  while (offset < data.length) {
    ssize_t written = write(descriptor, bytes + offset, data.length - offset);
    if (written < 0 && errno == EINTR) continue;
    if (written <= 0) return NO;
    offset += static_cast<size_t>(written);
  }
  return YES;
}

static BOOL LPRemoveTreeContents(int directoryDescriptor,
                                 dev_t expectedDevice,
                                 NSUInteger depth,
                                 NSUInteger *entryCount,
                                 NSUInteger maxEntries) {
  if (depth > LPMaxCleanupDepth) return NO;
  int duplicate = openat(directoryDescriptor, ".",
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  DIR *directory = duplicate < 0 ? nullptr : fdopendir(duplicate);
  if (directory == nullptr) {
    if (duplicate >= 0) close(duplicate);
    return NO;
  }
  BOOL ownerMarkerPresent = NO;
  NSMutableArray<NSData *> *names = [NSMutableArray array];
  BOOL valid = YES;
  BOOL fullyEnumerated = YES;
  while (valid) {
    errno = 0;
    struct dirent *entry = readdir(directory);
    if (entry == nullptr) {
      valid = errno == 0;
      break;
    }
    if (strcmp(entry->d_name, ".") == 0 ||
        strcmp(entry->d_name, "..") == 0) {
      continue;
    }
    if (strcmp(entry->d_name, LPStagingOwnerMarker.UTF8String) == 0) {
      ownerMarkerPresent = YES;
      continue;
    }
    if (*entryCount >= maxEntries ||
        names.count >= maxEntries - *entryCount) {
      fullyEnumerated = NO;
      break;
    }
    [names addObject:[NSData dataWithBytes:entry->d_name
                                    length:strlen(entry->d_name) + 1]];
  }
  closedir(directory);
  if (!valid) return NO;
  for (NSData *nameData in names) {
    if (*entryCount >= maxEntries) return NO;
    *entryCount += 1;
    const char *name = static_cast<const char *>(nameData.bytes);
    struct stat before = {};
    if (fstatat(directoryDescriptor, name, &before,
                AT_SYMLINK_NOFOLLOW) != 0 ||
        before.st_dev != expectedDevice ||
        (!S_ISDIR(before.st_mode) && !S_ISREG(before.st_mode) &&
         !S_ISLNK(before.st_mode))) {
      valid = NO;
      break;
    }
    if (S_ISDIR(before.st_mode)) {
      int child = openat(directoryDescriptor, name,
                         O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
      struct stat opened = {};
      valid = child >= 0 && fstat(child, &opened) == 0 &&
          LPSameNode(before, opened) &&
          LPRemoveTreeContents(child, expectedDevice, depth + 1, entryCount,
                               maxEntries);
      if (child >= 0) close(child);
      struct stat after = {};
      valid = valid &&
          fstatat(directoryDescriptor, name, &after,
                  AT_SYMLINK_NOFOLLOW) == 0 &&
          LPSameNode(before, after) &&
          unlinkat(directoryDescriptor, name, AT_REMOVEDIR) == 0;
    } else {
      struct stat after = {};
      valid = fstatat(directoryDescriptor, name, &after,
                      AT_SYMLINK_NOFOLLOW) == 0 &&
          LPSameNode(before, after) &&
          unlinkat(directoryDescriptor, name, 0) == 0;
    }
    if (!valid) return NO;
  }
  if (!valid) return NO;
  if (!fullyEnumerated) return NO;
  if (ownerMarkerPresent) {
    struct stat marker = {};
    if (fstatat(directoryDescriptor, LPStagingOwnerMarker.UTF8String, &marker,
                AT_SYMLINK_NOFOLLOW) != 0 || !S_ISREG(marker.st_mode) ||
        marker.st_dev != expectedDevice ||
        unlinkat(directoryDescriptor, LPStagingOwnerMarker.UTF8String, 0) != 0) {
      return NO;
    }
  }
  return fsync(directoryDescriptor) == 0;
}

static NSDictionary *LPReadStagingOwner(int directoryDescriptor,
                                         dev_t expectedDevice) {
  int markerDescriptor = openat(directoryDescriptor,
      LPStagingOwnerMarker.UTF8String, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  struct stat before = {};
  BOOL safe = markerDescriptor >= 0 && fstat(markerDescriptor, &before) == 0 &&
      S_ISREG(before.st_mode) && before.st_dev == expectedDevice &&
      before.st_nlink == 1 && (before.st_mode & 0777) == 0600 &&
      before.st_size > 0 && before.st_size <= LPMaxStagingOwnerBytes;
  NSMutableData *data = safe
      ? [NSMutableData dataWithLength:static_cast<NSUInteger>(before.st_size)]
      : nil;
  size_t offset = 0;
  while (safe && offset < data.length) {
    ssize_t count = read(markerDescriptor,
                         static_cast<uint8_t *>(data.mutableBytes) + offset,
                         data.length - offset);
    if (count <= 0) {
      safe = NO;
      break;
    }
    offset += static_cast<size_t>(count);
  }
  struct stat after = {};
  safe = safe && fstat(markerDescriptor, &after) == 0 &&
      LPSameNode(before, after) && before.st_size == after.st_size &&
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec &&
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec &&
      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec &&
      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec;
  if (markerDescriptor >= 0) close(markerDescriptor);
  if (!safe) return nil;
  NSDictionary *marker = LPDictionary(
      [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]);
  NSSet *expectedKeys = [NSSet setWithArray:
      @[@"schema_version", @"project_id", @"cleanup_token"]];
  if (marker.count != expectedKeys.count ||
      ![[NSSet setWithArray:marker.allKeys] isEqual:expectedKeys] ||
      ![marker[@"schema_version"] isEqual:@1] ||
      ![DSHLocalProjectAccess isCanonicalProjectId:LPString(marker[@"project_id"])] ||
      ![DSHLocalProjectAccess isCanonicalProjectId:LPString(marker[@"cleanup_token"])]) {
    return nil;
  }
  return marker;
}

static BOOL LPRemoveOwnedDirectoryAtRoot(int rootDescriptor,
                                          NSString *name,
                                          const struct stat *expectedIdentity,
                                          NSString *expectedToken,
                                          NSUInteger *entryCount,
                                          NSUInteger maxEntries) {
  struct stat before = {};
  if (rootDescriptor < 0 || name.length == 0 ||
      fstatat(rootDescriptor, name.fileSystemRepresentation, &before,
              AT_SYMLINK_NOFOLLOW) != 0 || !S_ISDIR(before.st_mode) ||
      (expectedIdentity != nullptr &&
       !LPSameNode(*expectedIdentity, before))) {
    return NO;
  }
  int directoryDescriptor = openat(rootDescriptor, name.fileSystemRepresentation,
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  struct stat opened = {};
  BOOL bound = directoryDescriptor >= 0 &&
      fstat(directoryDescriptor, &opened) == 0 && LPSameNode(before, opened);
  NSDictionary *marker = bound
      ? LPReadStagingOwner(directoryDescriptor, before.st_dev) : nil;
  bound = bound && marker != nil &&
      [marker[@"cleanup_token"] isEqual:expectedToken];
  BOOL emptied = bound && LPRemoveTreeContents(directoryDescriptor,
      before.st_dev, 0, entryCount, maxEntries);
  if (directoryDescriptor >= 0) close(directoryDescriptor);
  struct stat after = {};
  BOOL removed = emptied &&
      fstatat(rootDescriptor, name.fileSystemRepresentation, &after,
              AT_SYMLINK_NOFOLLOW) == 0 &&
      LPSameNode(before, after) &&
      unlinkat(rootDescriptor, name.fileSystemRepresentation,
               AT_REMOVEDIR) == 0 &&
      fsync(rootDescriptor) == 0;
  return removed;
}

static BOOL LPValidateCheckoutTree(int directoryDescriptor,
                                   NSUInteger depth,
                                   NSUInteger *entryCount) {
  if (depth > LPMaxCheckoutDepth) return NO;
  int duplicate = openat(directoryDescriptor, ".",
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  DIR *directory = duplicate < 0 ? nullptr : fdopendir(duplicate);
  if (directory == nullptr) {
    if (duplicate >= 0) close(duplicate);
    return NO;
  }
  struct dirent *entry = nullptr;
  errno = 0;
  while ((entry = readdir(directory)) != nullptr) {
    if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
    if (depth == 0 && strcmp(entry->d_name, ".git") == 0) continue;
    if (strcmp(entry->d_name, ".git") == 0 || strcmp(entry->d_name, ".gitmodules") == 0) {
      closedir(directory);
      return NO;
    }
    *entryCount += 1;
    if (*entryCount > LPMaxCheckoutEntries) {
      closedir(directory);
      return NO;
    }
    struct stat metadata = {};
    if (fstatat(directoryDescriptor, entry->d_name, &metadata, AT_SYMLINK_NOFOLLOW) != 0
      || S_ISLNK(metadata.st_mode)
      || (!S_ISDIR(metadata.st_mode) && !S_ISREG(metadata.st_mode))) {
      closedir(directory);
      return NO;
    }
    if (S_ISDIR(metadata.st_mode)) {
      int child = openat(directoryDescriptor, entry->d_name,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
      BOOL valid = child >= 0 && LPValidateCheckoutTree(child, depth + 1, entryCount);
      if (child >= 0) close(child);
      if (!valid) {
        closedir(directory);
        return NO;
      }
    }
  }
  BOOL valid = errno == 0;
  closedir(directory);
  return valid;
}

/// Network budget for a public clone.  Before this, libgit2 was handed no
/// connect timeout, no idle timeout and no progress callback, so a remote that
/// was slow or unreachable left the Projects form on "Loading projects…"
/// indefinitely: no error, no cancel, no end.  A clone that cannot reach the
/// server, or whose transfer stalls, must fail with a message the surface can
/// show.  The idle timeout is what ends a stalled transfer; the overall budget
/// is only a backstop for the pathological case where neither fires.
static const int LPCloneConnectTimeoutMilliseconds = 15000;
static const int LPCloneIdleTimeoutMilliseconds = 30000;
static const NSTimeInterval LPCloneOverallBudgetSeconds = 300;

// One retained operation per module: snapshots and cancellation never wait on
// projectQueue, which is occupied by libgit2. Only complete clones are published.
@interface LPCloneOperation : NSObject
@property(nonatomic, copy) NSString *operationId;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *phase;
@property(nonatomic) BOOL cancelRequested;
@property(nonatomic) NSUInteger receivedObjects;
@property(nonatomic) NSUInteger totalObjects;
@property(nonatomic) NSUInteger receivedBytes;
@property(nonatomic) NSUInteger completedFiles;
@property(nonatomic) NSUInteger totalFiles;
@property(nonatomic, copy) NSDictionary *project;
@property(nonatomic, copy) NSString *failureCode;
@property(nonatomic, copy, nullable) NSString *sshProfileId;
- (NSDictionary *)snapshot;
- (BOOL)terminal;
- (BOOL)shouldCancel;
- (void)updatePhase:(NSString *)phase;
- (BOOL)beginPublication;
@end

@implementation LPCloneOperation
- (instancetype)init {
  if ((self = [super init])) {
    _operationId = NSUUID.UUID.UUIDString.lowercaseString;
    _phase = @"queued";
  }
  return self;
}
- (BOOL)terminal {
  @synchronized (self) {
    return [@[@"succeeded", @"failed", @"cancelled"] containsObject:self.phase];
  }
}
- (BOOL)shouldCancel {
  @synchronized (self) { return self.cancelRequested; }
}
- (void)updatePhase:(NSString *)phase {
  @synchronized (self) { if (![self terminal]) self.phase = phase; }
}
- (BOOL)beginPublication {
  @synchronized (self) {
    if (self.cancelRequested) return NO;
    self.phase = @"publishing";
    return YES;
  }
}
- (NSDictionary *)snapshot {
  @synchronized (self) {
    return @{@"schema_version": @1, @"operation_id": self.operationId,
      @"name": self.name, @"phase": self.phase,
      @"cancel_requested": @(self.cancelRequested),
      @"received_objects": @(self.receivedObjects), @"total_objects": @(self.totalObjects),
      @"received_bytes": @(self.receivedBytes),
      @"completed_files": @(self.completedFiles), @"total_files": @(self.totalFiles),
      @"project": self.project ?: NSNull.null,
      @"error_code": self.failureCode ?: NSNull.null};
  }
}
@end

typedef struct {
  NSTimeInterval deadline;
  bool exceeded;
  __unsafe_unretained LPCloneOperation *operation;
  void *sshContext;
} LPCloneBudget;

static int LPCloneBudgetExpired(void *payload) {
  LPCloneBudget *budget = (LPCloneBudget *)payload;
  if (budget == nullptr) return 0;
  if ([budget->operation shouldCancel]) return GIT_EUSER;
  if (NSProcessInfo.processInfo.systemUptime < budget->deadline) return 0;
  budget->exceeded = true;
  return GIT_EUSER;
}

static int LPCloneTransferProgress(const git_indexer_progress *stats,
                                    void *payload) {
  LPCloneOperation *operation = ((LPCloneBudget *)payload)->operation;
  @synchronized (operation) {
    [operation updatePhase:@"receiving"];
    operation.receivedObjects = stats->received_objects;
    operation.totalObjects = stats->total_objects;
    operation.receivedBytes = stats->received_bytes;
  }
  return LPCloneBudgetExpired(payload);
}

static int LPCloneSidebandProgress(const char *text, int length, void *payload) {
  (void)text;
  (void)length;
  return LPCloneBudgetExpired(payload);
}

static int LPCloneCheckoutNotify(git_checkout_notify_t why, const char *path,
    const git_diff_file *baseline, const git_diff_file *target,
    const git_diff_file *workdir, void *payload) {
  (void)why; (void)path; (void)baseline; (void)target; (void)workdir;
  [((LPCloneBudget *)payload)->operation updatePhase:@"checkout"];
  return LPCloneBudgetExpired(payload);
}

static void LPCloneCheckoutProgress(const char *path, size_t completed,
    size_t total, void *payload) {
  (void)path;
  LPCloneOperation *operation = ((LPCloneBudget *)payload)->operation;
  @synchronized (operation) {
    [operation updatePhase:@"checkout"];
    operation.completedFiles = completed;
    operation.totalFiles = total;
  }
}

static int LPPublicCloneCredentialCallback(git_credential **out,
                                            const char *url,
                                            const char *username,
                                            unsigned int allowedTypes,
                                            void *payload) {
  LPCloneBudget *budget = (LPCloneBudget *)payload;
  if (budget != nullptr && budget->sshContext != nullptr)
    return DSHGitSSHCredentialCallback(out, url, username, allowedTypes,
                                       budget->sshContext);
  (void)out;
  (void)url;
  (void)username;
  (void)allowedTypes;
  (void)payload;
  return GIT_EAUTH;
}

static int LPCloneCertificateCallback(git_cert *cert, int valid,
                                      const char *host, void *payload) {
  LPCloneBudget *budget = (LPCloneBudget *)payload;
  if (budget == nullptr || budget->sshContext == nullptr) return valid ? 0 : -1;
  return DSHGitSSHCertificateCallback(cert, valid, host, budget->sshContext);
}

/// Native credential prompt result. `failureCode` nil means the user entered a
/// username, token, and expiry window; "cancelled" and "presentation" are the
/// only failure codes. Neither value is ever returned to React Native.
typedef void (^LPCredentialPromptCompletion)(NSString *_Nullable username,
                                             NSString *_Nullable token,
                                             NSInteger expirySeconds,
                                             NSString *_Nullable failureCode);
/// Test seam replacing the UIAlertController interaction only; validation,
/// origin re-check, Keychain storage, and the bridge result stay shared.
typedef void (^LPCredentialPromptHook)(NSString *host, BOOL chinese,
                                       BOOL plaintext,
                                       LPCredentialPromptCompletion completion);

@interface LocalProjectsModule : NSObject <RCTBridgeModule, UIDocumentPickerDelegate>
@property(nonatomic, strong) dispatch_queue_t projectQueue;
@property(nonatomic, strong) LPCloneOperation *cloneOperation;
@property(nonatomic, copy, nullable) LPCredentialPromptHook credentialPromptHook;
@property(nonatomic, strong) DSHLocalProjectAccess *projectAccess;
@property(nonatomic, strong, nullable) DSHLocalWorkspaceAccess *workspaceAccessV2;
@property(nonatomic, strong, nullable) DSHLocalProjectAccess *projectAccessV2;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *stagingIdentities;
@property(nonatomic, strong) NSMutableDictionary<NSString *, DSHLocalProjectsRootLease *> *stagingRootLeases;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *stagingCleanupTokens;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *v2DetachCheckpoints;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *v2AttachResults;
@property(nonatomic, strong) NSMutableDictionary<NSString *, DSHGitPushCancelToken *> *pushCancelTokens;
@property(nonatomic, strong, nullable) NSError *v2AttachStartupError;
@property(nonatomic, strong, nullable) DSHLocalProjectsRootLease *pendingRootLease;
@property(nonatomic, copy, nullable) LPV2AttachFaultHook v2AttachFaultHook;
@property(nonatomic, copy, nullable) void (^clonePhaseHook)(NSString *phase);
@property(nonatomic, copy, nullable) NSString *sshImportProfileId;
@property(nonatomic, copy, nullable) NSString *sshImportHost;
@property(nonatomic) NSInteger sshImportPort;
@property(nonatomic, copy, nullable) NSString *sshImportUsername;
@property(nonatomic, copy, nullable) RCTPromiseResolveBlock sshImportResolve;
@property(nonatomic, copy, nullable) RCTPromiseRejectBlock sshImportReject;
- (nullable NSDictionary *)diffForRepository:(git_repository *)repository projectId:(NSString *)projectId
  staged:(BOOL)staged contextLines:(NSUInteger)contextLines pageOffset:(NSNumber *)pageOffset
  expectedSnapshot:(NSString *)expectedSnapshot error:(NSError **)error;
- (nullable NSDictionary *)clonePublicRepositoryAtURL:(NSURL *)remoteURL name:(NSString *)name proxyURL:(NSString *)proxyURL operation:(LPCloneOperation *_Nullable)operation sshProfileId:(NSString *_Nullable)sshProfileId error:(NSError **)error;
- (BOOL)stagingEntryIsExactForProjectId:(NSString *)projectId
                                  error:(NSError **)error;
- (void)removeVisibleStagingDirectory:(NSURL *)staging
                            projectId:(NSString *)projectId;
- (BOOL)reconcileOwnedOrphansInRootLease:(DSHLocalProjectsRootLease *)rootLease;
- (BOOL)removePublishedOwnerMarkerAtDescriptor:(int)descriptor;
- (BOOL)syncPublishedRootDescriptor:(int)descriptor;
- (nullable DSHLocalProjectLease *)v2LeaseForRoot:(NSDictionary *)root
                                             mode:(DSHLocalProjectAccessMode)mode
                                            error:(NSError **)error;
- (nullable NSDictionary *)v2ProjectDescriptorForLease:(DSHLocalProjectLease *)lease
                                                  root:(NSDictionary *)root;
- (nullable NSDictionary *)v2ProjectDescriptorForRoot:(NSDictionary *)root
                                            projectId:(NSString *)projectId
                                          displayName:(NSString *)displayName;
- (nullable NSDictionary *)v2ProjectForWorkspace:(NSDictionary *)root
                                             error:(NSError **)error;
- (DSHLocalProjectAccess *)v2LegacyProjectAccess;
- (nullable NSDictionary *)v2AttachWorkspaceProject:(NSDictionary *)request
                                               error:(NSError **)error;
- (BOOL)v2ReconcileAttachStagingForWorkspaceId:(NSString *)workspaceId
                                         error:(NSError **)error;
- (BOOL)v2ReconcileAllAttachStaging:(NSError **)error;
- (nullable NSArray<NSURL *> *)v2AttachContentsOfDirectory:(NSURL *)directory
                                                      error:(NSError **)error;
- (BOOL)v2WriteAttachJournalData:(NSData *)data
                            toURL:(NSURL *)url
                            error:(NSError **)error;
- (BOOL)v2RemoveAttachItemAtURL:(NSURL *)url
                          parent:(NSURL *)parent
                           error:(NSError **)error;
- (BOOL)v2FsyncDirectoryAtURL:(NSURL *)url error:(NSError **)error;
- (nullable NSDictionary *)v2PrepareDetach:(NSDictionary *)request
                                      error:(NSError **)error;
- (nullable NSDictionary *)v2CommitDetach:(NSDictionary *)request
                                     error:(NSError **)error;
- (nullable NSString *)v2RootFingerprintForRoot:(NSDictionary *)root
                                           error:(NSError **)error;
- (nullable NSDictionary *)v2BindingForRoot:(NSDictionary *)root
                                  projectId:(NSString *)projectId
                                     error:(NSError **)error;
- (nullable NSURL *)v2GitDirectoryURLForWorkspaceId:(NSString *)workspaceId
                                           projectId:(NSString *)projectId;
- (BOOL)v2WriteBindingForRoot:(NSDictionary *)root
                    projectId:(NSString *)projectId
                  displayName:(NSString *)displayName
                        gitURL:(NSURL *)gitURL
                 rootFingerprint:(NSString *)rootFingerprint
                           error:(NSError **)error;
- (instancetype)initWithSupportURL:(nullable NSURL *)support
                       projectAccess:(DSHLocalProjectAccess *)projectAccess;
@end

@implementation LocalProjectsModule

RCT_EXPORT_MODULE(LocalProjects)

+ (BOOL)requiresMainQueueSetup {
  return NO;
}

- (instancetype)init {
  NSError *workspaceError = nil;
  NSURL *support = [[NSFileManager defaultManager]
      URLForDirectory:NSApplicationSupportDirectory
             inDomain:NSUserDomainMask
    appropriateForURL:nil
               create:YES
                error:&workspaceError];
  return [self initWithSupportURL:support
                     projectAccess:[DSHLocalProjectAccess sharedAccess]];
}

- (instancetype)initWithSupportURL:(NSURL *)support
                       projectAccess:(DSHLocalProjectAccess *)projectAccess {
  self = [super init];
  if (self != nil) {
    _projectAccess = projectAccess;
    if (support != nil) {
      DSHLocalProjectAccess *legacyProjectAccess = projectAccess;
      _workspaceAccessV2 = [[DSHLocalWorkspaceAccess alloc]
          initWithPrivateRootURL:support
          clock:^NSDate * { return NSDate.date; }
          UUIDGenerator:^NSString * {
            return NSUUID.UUID.UUIDString.lowercaseString;
          }
          legacyResolver:^BOOL(NSString *projectId,
                               NSDictionary **evidence,
                               NSError **resolverError) {
            NSError *projectError = nil;
            NSDictionary *resolved = [legacyProjectAccess
                legacyWorkspaceBootstrapEvidenceForProjectId:projectId
                                                       error:&projectError];
            if (resolved == nil) {
              if (evidence != nil) *evidence = nil;
              if (resolverError != nil) {
                *resolverError = [NSError errorWithDomain:
                  DSHLocalWorkspaceAccessErrorDomain
                                             code:DSHLocalWorkspaceAccessErrorUnavailable
                                         userInfo:@{}];
              }
              return NO;
            }
            if (evidence != nil) *evidence = [resolved copy];
            return YES;
          }
          faultHook:nil];
      _projectAccessV2 = [[DSHLocalProjectAccess alloc]
          initWithWorkspaceAccess:_workspaceAccessV2 hook:nil];
    }
    _stagingIdentities = [NSMutableDictionary dictionary];
    _stagingRootLeases = [NSMutableDictionary dictionary];
    _stagingCleanupTokens = [NSMutableDictionary dictionary];
    _v2DetachCheckpoints = [NSMutableDictionary dictionary];
    _v2AttachResults = [NSMutableDictionary dictionary];
    _pushCancelTokens = [NSMutableDictionary dictionary];
    _projectQueue = dispatch_queue_create(
      "dev.zseven.rish.local-projects", DISPATCH_QUEUE_SERIAL);
    NSError *startupError = nil;
    if (_workspaceAccessV2 != nil &&
        ![self v2ReconcileAllAttachStaging:&startupError]) {
      _v2AttachStartupError = startupError ?:
          LPError(3104, @"Attach startup reconciliation failed");
    }
  }
  return self;
}

- (NSURL *)projectsRootCreatingIfNeeded:(BOOL)create error:(NSError **)error {
  NSError *accessError = nil;
  DSHLocalProjectsRootLease *rootLease = [self.projectAccess
      leaseProjectsRootCreatingIfNeeded:create error:&accessError];
  self.pendingRootLease = rootLease;
  if (rootLease == nil) {
    if (error != nil) {
      *error = accessError ?: LPError(3005, @"Project storage is unavailable");
    }
    return nil;
  }
  return rootLease.rootURL;
}

- (BOOL)removePublishedOwnerMarkerAtDescriptor:(int)descriptor {
  return descriptor >= 0 &&
      unlinkat(descriptor, LPStagingOwnerMarker.UTF8String, 0) == 0 &&
      fsync(descriptor) == 0;
}

- (BOOL)syncPublishedRootDescriptor:(int)descriptor {
  return descriptor >= 0 && fsync(descriptor) == 0;
}

- (NSURL *)projectDirectoryForId:(NSString *)projectId error:(NSError **)error {
  if (![DSHLocalProjectAccess isCanonicalProjectId:projectId]) {
    if (error != nil) *error = LPError(3006, @"Project identifier is invalid");
    return nil;
  }
  NSURL *project = [self.projectAccess projectDirectoryURLForId:projectId error:nil];
  if (project == nil) {
    if (error != nil) *error = LPError(3007, @"Project is unavailable");
    return nil;
  }
  return project;
}

- (DSHLocalProjectLease *)leaseRepositoryForId:(NSString *)projectId
                                          mode:(DSHLocalProjectAccessMode)mode
                                      metadata:(NSDictionary **)metadata
                                         error:(NSError **)error {
  NSError *accessError = nil;
  DSHLocalProjectLease *lease = [self.projectAccess
    leaseProjectId:projectId
              mode:mode
   includeMetadata:NO
             error:&accessError];
  if (lease == nil) {
    if (error != nil) {
      if (accessError.code == DSHLocalProjectAccessErrorInvalidIdentifier) {
        *error = LPError(3006, @"Project identifier is invalid");
      } else if (accessError.code == DSHLocalProjectAccessErrorStorageUnavailable) {
        *error = LPError(3007, @"Project is unavailable");
      } else if (accessError.code == DSHLocalProjectAccessErrorUnsafeStorage) {
        *error = LPError(3008, @"Repository storage is unsafe");
      } else {
        *error = LPError(3009, @"Repository cannot be opened");
      }
    }
    return nil;
  }
  if (metadata != nullptr) {
    *metadata = [self.projectAccess readProjectMetadataFromLease:lease
                                                          error:nil];
    NSString *origin = (*metadata)[@"origin_url"] == NSNull.null
      ? nil : LPString((*metadata)[@"origin_url"]);
    if (*metadata != nil && origin != nil &&
        LPValidatedRemoteURL(origin, nil) == nil) {
      *metadata = nil;
    }
    if (*metadata == nil) {
      if (error != nil) *error = LPError(3010, @"Project metadata is invalid");
      return nil;
    }
  }
  return lease;
}

- (BOOL)writeMetadata:(NSDictionary *)metadata
    atProjectDirectory:(NSURL *)project
             projectId:(NSString *)projectId
            writeToken:(DSHLocalProjectLockToken *)writeToken
                 error:(NSError **)error {
  DSHLocalProjectsRootLease *rootLease = self.stagingRootLeases[projectId];
  NSString *stagingName = [@".staging-" stringByAppendingString:projectId];
  BOOL stagingBound = [self stagingEntryIsExactForProjectId:projectId
                                                       error:nil];
  int descriptor = !stagingBound || rootLease == nil ? -1 : openat(
      rootLease.descriptor, stagingName.fileSystemRepresentation,
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  BOOL correctURL = [project.lastPathComponent isEqual:stagingName] &&
      [project.URLByDeletingLastPathComponent.path.stringByStandardizingPath
          isEqual:rootLease.rootURL.path.stringByStandardizingPath];
  BOOL success = descriptor >= 0 && correctURL && [self.projectAccess
      writeInitialProjectMetadataRecord:metadata
                       projectId:projectId
               projectDescriptor:descriptor
                      writeToken:writeToken
                           error:nil];
  struct stat identity = {};
  success = success && fstat(descriptor, &identity) == 0 &&
            S_ISDIR(identity.st_mode);
  if (success) {
    self.stagingIdentities[projectId] =
        [NSValue value:&identity withObjCType:@encode(struct stat)];
  }
  if (descriptor >= 0) close(descriptor);
  if (!success) {
    if (error != nil) *error = LPError(3011, @"Project metadata cannot be saved");
    return NO;
  }
  return YES;
}

- (NSDictionary *)updatedMetadata:(NSDictionary *)metadata
                         originURL:(NSString *)origin
                             lease:(DSHLocalProjectLease *)lease
                             error:(NSError **)error {
  NSDictionary *stored = @{
    @"schema_version": @1,
    @"name": metadata[@"name"],
    @"created_at": metadata[@"created_at"],
    @"updated_at": LPNow(),
    @"origin_url": origin ?: NSNull.null,
  };
  if (![self.projectAccess writeProjectMetadataRecord:stored
                                                lease:lease error:nil]) {
    if (error != nil) *error = LPError(3011, @"Project metadata cannot be saved");
    return nil;
  }
  NSDictionary *updated = [self.projectAccess readProjectMetadataFromLease:lease
                                                                      error:nil];
  if (updated == nil) {
    if (error != nil) *error = LPError(3010, @"Project metadata is invalid");
  }
  return updated;
}

// Credentials are Keychain items scoped to (project id, remote host) with an
// absolute expiry. The project id is the app's opaque per-workspace repository
// identity and is present on every push path (legacy project API, V2 root,
// agent root), so one provisioned token serves all of them. The token itself
// never crosses the bridge and is never logged; it only reaches libgit2
// through DSHGitPushSupport's callback.
- (NSDictionary *)credentialStatusForScope:(NSString *)projectId
                                      host:(NSString *)host
                                     error:(NSError **)error {
  NSError *lookupError = nil;
  NSDictionary *credential = DSHGitCredentialForScope(projectId, host, &lookupError);
  if (lookupError != nil) {
    if (error != nil) *error = lookupError;
    return nil;
  }
  NSMutableDictionary *status = [@{
    @"schema_version": @1,
    @"project_id": projectId,
    @"host": host,
    @"configured": @(credential != nil),
  } mutableCopy];
  if (credential != nil) {
    status[@"expires_at"] = credential[@"expires_at"];
    status[@"expiry_seconds"] = credential[@"expiry_seconds"];
  }
  return status;
}

- (NSString *)originURLForRepository:(git_repository *)repository error:(NSError **)error {
  git_config *config = nullptr;
  git_buf value = GIT_BUF_INIT;
  int result = git_repository_config(&config, repository);
  if (result == 0) result = git_config_get_string_buf(&value, config, "remote.origin.url");
  NSString *raw = result == 0 && value.ptr != nullptr
    ? [NSString stringWithUTF8String:value.ptr] : nil;
  git_buf_dispose(&value);
  if (config != nullptr) git_config_free(config);
  NSURL *validated = LPValidatedRemoteURL(raw, nil);
  if (validated == nil) {
    if (error != nil) *error = LPError(3015, @"Origin remote is unavailable or unsafe");
    return nil;
  }
  return validated.absoluteString;
}

- (NSDictionary *)credentialStatusForId:(NSString *)projectId
                              repository:(git_repository *)repository
                                   error:(NSError **)error {
  NSString *origin = [self originURLForRepository:repository error:error];
  if (origin == nil) return nil;
  NSString *host = [NSURLComponents componentsWithString:origin].host.lowercaseString;
  return [self credentialStatusForScope:projectId host:host error:error];
}

- (NSURL *)createStagingDirectoryAtRoot:(NSURL *)root
                              projectId:(NSString *)projectId
                                   error:(NSError **)error {
  DSHLocalProjectsRootLease *rootLease = self.pendingRootLease;
  self.pendingRootLease = nil;
  if (rootLease == nil ||
      ![rootLease.rootURL.path.stringByStandardizingPath
          isEqual:root.path.stringByStandardizingPath]) {
    rootLease = [self.projectAccess leaseProjectsRootCreatingIfNeeded:NO
                                                                error:nil];
  }
  NSURL *staging = [root URLByAppendingPathComponent:
    [@".staging-" stringByAppendingString:projectId] isDirectory:YES];
  NSString *stagingName = [@".staging-" stringByAppendingString:projectId];
  if (rootLease == nil ||
      mkdirat(rootLease.descriptor, stagingName.fileSystemRepresentation,
              0700) != 0) {
    if (error != nil) *error = LPError(3017, @"Project staging cannot be created");
    return nil;
  }
  self.stagingRootLeases[projectId] = rootLease;
  struct stat identity = {};
  int stagingDescriptor = openat(rootLease.descriptor,
      stagingName.fileSystemRepresentation,
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  struct stat openedIdentity = {};
  BOOL openedValid = stagingDescriptor >= 0 &&
      fstat(stagingDescriptor, &openedIdentity) == 0 &&
      S_ISDIR(openedIdentity.st_mode);
  BOOL pathValid =
      fstatat(rootLease.descriptor, stagingName.fileSystemRepresentation,
              &identity, AT_SYMLINK_NOFOLLOW) == 0 && S_ISDIR(identity.st_mode);
  BOOL stagingBound = openedValid && pathValid &&
      LPSameNode(identity, openedIdentity);
  if (!stagingBound) {
    if (stagingDescriptor >= 0) close(stagingDescriptor);
    struct stat finalIdentity = {};
    if (openedValid && pathValid &&
        fstatat(rootLease.descriptor, stagingName.fileSystemRepresentation,
                &finalIdentity, AT_SYMLINK_NOFOLLOW) == 0 &&
        LPSameNode(openedIdentity, finalIdentity) &&
        unlinkat(rootLease.descriptor, stagingName.fileSystemRepresentation,
                 AT_REMOVEDIR) == 0) {
      (void)fsync(rootLease.descriptor);
    }
    [self.stagingRootLeases removeObjectForKey:projectId];
    if (error != nil) *error = LPError(3017, @"Project staging cannot be created");
    return nil;
  }
  self.stagingIdentities[projectId] =
      [NSValue value:&identity withObjCType:@encode(struct stat)];
  NSString *cleanupToken = NSUUID.UUID.UUIDString.lowercaseString;
  NSDictionary *owner = @{
    @"schema_version" : @1,
    @"project_id" : projectId,
    @"cleanup_token" : cleanupToken,
  };
  NSData *ownerData = [NSJSONSerialization dataWithJSONObject:owner
      options:NSJSONWritingSortedKeys error:nil];
  int markerDescriptor = stagingDescriptor < 0 ? -1 : openat(
      stagingDescriptor, LPStagingOwnerMarker.UTF8String,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
  BOOL markerSaved = markerDescriptor >= 0 && ownerData.length > 0 &&
      ownerData.length <= LPMaxStagingOwnerBytes &&
      fchmod(markerDescriptor, 0600) == 0 &&
      LPWriteAll(markerDescriptor, ownerData) && fsync(markerDescriptor) == 0 &&
      fsync(stagingDescriptor) == 0;
  if (markerDescriptor >= 0) close(markerDescriptor);
  if (stagingDescriptor >= 0) close(stagingDescriptor);
  if (!markerSaved) {
    struct stat current = {};
    if (fstatat(rootLease.descriptor, stagingName.fileSystemRepresentation,
                &current, AT_SYMLINK_NOFOLLOW) == 0 &&
        LPSameNode(identity, current)) {
      int cleanupDescriptor = openat(rootLease.descriptor,
          stagingName.fileSystemRepresentation,
          O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
      if (cleanupDescriptor >= 0) {
        errno = 0;
        if (unlinkat(cleanupDescriptor, LPStagingOwnerMarker.UTF8String, 0) == 0 ||
            errno == ENOENT) {
          (void)fsync(cleanupDescriptor);
        }
        close(cleanupDescriptor);
      }
      struct stat finalIdentity = {};
      if (fstatat(rootLease.descriptor, stagingName.fileSystemRepresentation,
                  &finalIdentity, AT_SYMLINK_NOFOLLOW) == 0 &&
          LPSameNode(identity, finalIdentity) &&
          unlinkat(rootLease.descriptor, stagingName.fileSystemRepresentation,
                   AT_REMOVEDIR) == 0) {
        (void)fsync(rootLease.descriptor);
      }
    }
    [self.stagingIdentities removeObjectForKey:projectId];
    [self.stagingRootLeases removeObjectForKey:projectId];
    if (error != nil) *error = LPError(3017, @"Project staging cannot be created");
    return nil;
  }
  self.stagingCleanupTokens[projectId] = cleanupToken;
  if (fsync(rootLease.descriptor) != 0) {
    [self removeVisibleStagingDirectory:staging projectId:projectId];
    if (error != nil) *error = LPError(3017, @"Project staging cannot be created");
    return nil;
  }
  return staging;
}

- (BOOL)stagingEntryIsExactForProjectId:(NSString *)projectId
                                  error:(NSError **)error {
  DSHLocalProjectsRootLease *rootLease = self.stagingRootLeases[projectId];
  NSValue *identityValue = self.stagingIdentities[projectId];
  if (rootLease == nil || identityValue == nil ||
      ![self.projectAccess validateProjectsRootLease:rootLease error:nil]) {
    if (error != nil) *error = LPError(3018, @"Project cannot be published");
    return NO;
  }
  NSString *expectedName = [@".staging-" stringByAppendingString:projectId];
  NSString *expectedFold =
      [DSHLocalProjectAccess filesystemFoldedComponent:expectedName];
  struct stat expected = {};
  [identityValue getValue:&expected size:sizeof(expected)];
  int duplicate = openat(rootLease.descriptor, ".",
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  DIR *directory = duplicate < 0 ? nullptr : fdopendir(duplicate);
  if (directory == nullptr) {
    if (duplicate >= 0) close(duplicate);
    if (error != nil) *error = LPError(3018, @"Project cannot be published");
    return NO;
  }
  NSUInteger entries = 0;
  NSUInteger foldedMatches = 0;
  BOOL exactBound = NO;
  struct dirent *entry = nullptr;
  int enumerationError = 0;
  while (YES) {
    errno = 0;
    entry = readdir(directory);
    if (entry == nullptr) {
      enumerationError = errno;
      break;
    }
    if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
      continue;
    }
    entries += 1;
    if (entries > LPMaxStatusEntries) break;
    NSString *candidate = [NSString stringWithUTF8String:entry->d_name];
    if (candidate == nil || ![[DSHLocalProjectAccess
        filesystemFoldedComponent:candidate] isEqual:expectedFold]) {
      continue;
    }
    foldedMatches += 1;
    if ([candidate isEqual:expectedName]) {
      struct stat observed = {};
      exactBound = fstatat(rootLease.descriptor, entry->d_name, &observed,
                           AT_SYMLINK_NOFOLLOW) == 0 &&
          expected.st_dev == observed.st_dev &&
          expected.st_ino == observed.st_ino &&
          expected.st_mode == observed.st_mode;
    }
  }
  closedir(directory);
  BOOL valid = enumerationError == 0 && entries <= LPMaxStatusEntries &&
      foldedMatches == 1 && exactBound;
  if (!valid && error != nil) {
    *error = LPError(3018, @"Project cannot be published");
  }
  return valid;
}

- (void)removeVisibleStagingDirectory:(NSURL *)staging
                            projectId:(NSString *)projectId {
  BOOL safeToRemove = [self stagingEntryIsExactForProjectId:projectId
                                                       error:nil];
  DSHLocalProjectsRootLease *rootLease = self.stagingRootLeases[projectId];
  NSString *cleanupToken = self.stagingCleanupTokens[projectId];
  NSValue *identityValue = self.stagingIdentities[projectId];
  struct stat expected = {};
  if (identityValue != nil) {
    [identityValue getValue:&expected size:sizeof(expected)];
  }
  BOOL rootValid = rootLease != nil &&
      [self.projectAccess validateProjectsRootLease:rootLease error:nil];
  NSString *stagingName = [@".staging-" stringByAppendingString:projectId];
  NSString *sourceName = safeToRemove ? stagingName : nil;
  if (sourceName == nil && rootValid && identityValue != nil) {
    struct stat published = {};
    if (fstatat(rootLease.descriptor, projectId.fileSystemRepresentation,
                &published, AT_SYMLINK_NOFOLLOW) == 0 &&
        LPSameNode(expected, published) && S_ISDIR(published.st_mode)) {
      sourceName = projectId;
    }
  }
  if (sourceName != nil && rootValid && cleanupToken != nil &&
      identityValue != nil) {
    int stagingDescriptor = openat(rootLease.descriptor,
        sourceName.fileSystemRepresentation,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    NSDictionary *owner = stagingDescriptor < 0 ? nil :
        LPReadStagingOwner(stagingDescriptor, expected.st_dev);
    if (stagingDescriptor >= 0) close(stagingDescriptor);
    BOOL owned = [owner[@"project_id"] isEqual:projectId] &&
        [owner[@"cleanup_token"] isEqual:cleanupToken];
    NSString *quarantineName = [@".orphan-"
        stringByAppendingString:cleanupToken];
    BOOL renamed = owned && renameatx_np(
        rootLease.descriptor, sourceName.fileSystemRepresentation,
        rootLease.descriptor, quarantineName.fileSystemRepresentation,
        RENAME_EXCL) == 0;
    if (renamed) {
      (void)fsync(rootLease.descriptor);
      NSUInteger cleanupEntries = 0;
      (void)LPRemoveOwnedDirectoryAtRoot(rootLease.descriptor,
          quarantineName, &expected, cleanupToken, &cleanupEntries,
          LPMaxOrphanCleanupEntriesPerPass);
    }
  }
  [self.stagingIdentities removeObjectForKey:projectId];
  [self.stagingRootLeases removeObjectForKey:projectId];
  [self.stagingCleanupTokens removeObjectForKey:projectId];
  (void)staging;
}

- (BOOL)reconcileOwnedOrphansInRootLease:(DSHLocalProjectsRootLease *)rootLease {
  if (rootLease == nil ||
      ![self.projectAccess validateProjectsRootLease:rootLease error:nil]) {
    return NO;
  }
  int duplicate = openat(rootLease.descriptor, ".",
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  DIR *directory = duplicate < 0 ? nullptr : fdopendir(duplicate);
  if (directory == nullptr) {
    if (duplicate >= 0) close(duplicate);
    return NO;
  }
  NSMutableArray<NSString *> *candidates = [NSMutableArray array];
  NSUInteger entries = 0;
  int enumerationError = 0;
  while (YES) {
    errno = 0;
    struct dirent *entry = readdir(directory);
    if (entry == nullptr) {
      enumerationError = errno;
      break;
    }
    if (strcmp(entry->d_name, ".") == 0 ||
        strcmp(entry->d_name, "..") == 0) {
      continue;
    }
    entries += 1;
    if (entries > LPMaxStatusEntries) break;
    NSString *name = [NSString stringWithUTF8String:entry->d_name];
    BOOL orphan = [name hasPrefix:@".orphan-"] &&
        [DSHLocalProjectAccess isCanonicalProjectId:
            [name substringFromIndex:@".orphan-".length]];
    BOOL staging = [name hasPrefix:@".staging-"] &&
        [DSHLocalProjectAccess isCanonicalProjectId:
            [name substringFromIndex:@".staging-".length]];
    if (orphan || staging ||
        [DSHLocalProjectAccess isCanonicalProjectId:name]) {
      [candidates addObject:name];
    }
  }
  closedir(directory);
  if (enumerationError != 0 || entries > LPMaxStatusEntries) return NO;
  NSUInteger removedCount = 0;
  NSUInteger cleanupEntries = 0;
  for (NSString *name in candidates) {
    BOOL orphan = [name hasPrefix:@".orphan-"];
    BOOL staging = [name hasPrefix:@".staging-"];
    NSString *nameIdentity = orphan
        ? [name substringFromIndex:@".orphan-".length]
        : (staging ? [name substringFromIndex:@".staging-".length] : name);
    struct stat before = {};
    if (fstatat(rootLease.descriptor, name.fileSystemRepresentation, &before,
                AT_SYMLINK_NOFOLLOW) != 0 || !S_ISDIR(before.st_mode) ||
        before.st_dev != rootLease.device) {
      continue;
    }
    int orphanDescriptor = openat(rootLease.descriptor,
        name.fileSystemRepresentation,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    struct stat opened = {};
    BOOL bound = orphanDescriptor >= 0 &&
        fstat(orphanDescriptor, &opened) == 0 && LPSameNode(before, opened);
    NSDictionary *owner = bound
        ? LPReadStagingOwner(orphanDescriptor, rootLease.device) : nil;
    if (orphanDescriptor >= 0) close(orphanDescriptor);
    if (owner == nil) continue;
    NSString *projectId = LPString(owner[@"project_id"]);
    NSString *cleanupToken = LPString(owner[@"cleanup_token"]);
    BOOL bindingValid = [DSHLocalProjectAccess
        isCanonicalProjectId:projectId] &&
        [DSHLocalProjectAccess isCanonicalProjectId:cleanupToken] &&
        (orphan ? [cleanupToken isEqual:nameIdentity]
                : [projectId isEqual:nameIdentity]);
    if (!bindingValid) {
      continue;
    }
    __attribute__((objc_precise_lifetime)) DSHLocalProjectLockToken *cleanupLock =
        [self.projectAccess tryLockProjectIdForWrite:projectId error:nil];
    if (cleanupLock == nil) continue;
    if (!orphan && !staging) {
      int projectDescriptor = openat(rootLease.descriptor,
          name.fileSystemRepresentation,
          O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
      struct stat openedProject = {};
      BOOL boundProject = projectDescriptor >= 0 &&
          fstat(projectDescriptor, &openedProject) == 0 &&
          LPSameNode(before, openedProject);
      BOOL cleaned = boundProject &&
          [self removePublishedOwnerMarkerAtDescriptor:projectDescriptor];
      if (projectDescriptor >= 0) close(projectDescriptor);
      if (cleaned) (void)fsync(rootLease.descriptor);
      continue;
    }
    if (removedCount >= LPMaxOrphansPerReconcile) break;
    if (!LPRemoveOwnedDirectoryAtRoot(rootLease.descriptor, name,
                                      &before, cleanupToken, &cleanupEntries,
                                      LPMaxOrphanCleanupEntriesPerPass)) {
      if (cleanupEntries >= LPMaxOrphanCleanupEntriesPerPass) break;
      continue;
    }
    removedCount += 1;
  }
  return [self.projectAccess validateProjectsRootLease:rootLease error:nil];
}

- (BOOL)publishStagingDirectory:(NSURL *)staging
                         atRoot:(NSURL *)root
                      projectId:(NSString *)projectId
                          error:(NSError **)error {
  NSString *stagingName = [@".staging-" stringByAppendingString:projectId];
  NSValue *identityValue = self.stagingIdentities[projectId];
  DSHLocalProjectsRootLease *rootLease = self.stagingRootLeases[projectId];
  if (![staging.lastPathComponent isEqual:stagingName] ||
      ![staging.URLByDeletingLastPathComponent.path.stringByStandardizingPath
          isEqual:root.path.stringByStandardizingPath] || identityValue == nil ||
      rootLease == nil ||
      ![rootLease.rootURL.path.stringByStandardizingPath
          isEqual:root.path.stringByStandardizingPath] ||
      ![self stagingEntryIsExactForProjectId:projectId error:nil]) {
    if (error != nil) *error = LPError(3018, @"Project cannot be published");
    return NO;
  }
  int rootDescriptor = dup(rootLease.descriptor);
  int stagingDescriptor = rootDescriptor < 0 ? -1 : openat(
    rootDescriptor, stagingName.fileSystemRepresentation,
    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  struct stat expected = {};
  struct stat opened = {};
  struct stat pathBefore = {};
  struct stat destinationBefore = {};
  [identityValue getValue:&expected size:sizeof(expected)];
  NSString *cleanupToken = self.stagingCleanupTokens[projectId];
  NSDictionary *owner = stagingDescriptor < 0 ? nil :
      LPReadStagingOwner(stagingDescriptor, expected.st_dev);
  errno = 0;
  BOOL destinationAbsent = rootDescriptor >= 0 &&
    fstatat(rootDescriptor, projectId.fileSystemRepresentation,
            &destinationBefore, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT;
  BOOL bound = stagingDescriptor >= 0 && fstat(stagingDescriptor, &opened) == 0 &&
    fstatat(rootDescriptor, stagingName.fileSystemRepresentation,
            &pathBefore, AT_SYMLINK_NOFOLLOW) == 0 &&
    expected.st_dev == opened.st_dev && expected.st_ino == opened.st_ino &&
    expected.st_mode == opened.st_mode &&
    opened.st_dev == pathBefore.st_dev && opened.st_ino == pathBefore.st_ino &&
    opened.st_mode == pathBefore.st_mode && destinationAbsent &&
    cleanupToken != nil && [owner[@"project_id"] isEqual:projectId] &&
    [owner[@"cleanup_token"] isEqual:cleanupToken];
  BOOL renamed = bound && renameatx_np(
    rootDescriptor, stagingName.fileSystemRepresentation,
    rootDescriptor, projectId.fileSystemRepresentation, RENAME_EXCL) == 0;
  struct stat published = {};
  BOOL publishedBound = renamed &&
    fstatat(rootDescriptor, projectId.fileSystemRepresentation,
            &published, AT_SYMLINK_NOFOLLOW) == 0 &&
    expected.st_dev == published.st_dev && expected.st_ino == published.st_ino &&
    expected.st_mode == published.st_mode;
  BOOL rootSynced = publishedBound &&
      [self syncPublishedRootDescriptor:rootDescriptor];
  BOOL durable = publishedBound && rootSynced;
  if (renamed && !durable) {
    if (renameatx_np(rootDescriptor, projectId.fileSystemRepresentation,
                     rootDescriptor, stagingName.fileSystemRepresentation,
                     RENAME_EXCL) == 0) {
      (void)fsync(rootDescriptor);
    }
  }
  if (durable) {
    // The root rename is the commit point. Marker removal is recoverable
    // housekeeping; list reconciliation retries it after a crash or I/O error.
    (void)[self removePublishedOwnerMarkerAtDescriptor:stagingDescriptor];
  }
  if (stagingDescriptor >= 0) close(stagingDescriptor);
  if (rootDescriptor >= 0) close(rootDescriptor);
  if (!durable) {
    if (error != nil) *error = LPError(3018, @"Project cannot be published");
    return NO;
  }
  [self.stagingIdentities removeObjectForKey:projectId];
  [self.stagingRootLeases removeObjectForKey:projectId];
  [self.stagingCleanupTokens removeObjectForKey:projectId];
  return YES;
}

- (NSDictionary *)statusForRepository:(git_repository *)repository
                             projectId:(NSString *)projectId
                                  error:(NSError **)error {
  git_status_options options = GIT_STATUS_OPTIONS_INIT;
  options.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR;
  options.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED
    | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS
    | GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX
    | GIT_STATUS_OPT_RENAMES_INDEX_TO_WORKDIR
    | GIT_STATUS_OPT_SORT_CASE_SENSITIVELY;
  git_status_list *statusList = nullptr;
  if (git_status_list_new(&statusList, repository, &options) < 0) {
    if (error != nil) *error = LPError(3019, @"Repository status is unavailable");
    return nil;
  }
  size_t count = git_status_list_entrycount(statusList);
  if (count > LPMaxStatusEntries) {
    git_status_list_free(statusList);
    if (error != nil) *error = LPError(3020, @"Repository has too many changed files");
    return nil;
  }
  NSMutableArray<NSDictionary *> *entries = [NSMutableArray arrayWithCapacity:count];
  BOOL hasConflicts = NO;
  for (size_t index = 0; index < count; index += 1) {
    const git_status_entry *entry = git_status_byindex(statusList, index);
    NSString *path = entry == nullptr ? nil : LPPathForStatusEntry(entry);
    if (path == nil || !LPIsSafeRepositoryPath(path)) {
      git_status_list_free(statusList);
      if (error != nil) *error = LPError(3021, @"Repository contains an unsafe path");
      return nil;
    }
    BOOL conflicted = (entry->status & GIT_STATUS_CONFLICTED) != 0;
    hasConflicts = hasConflicts || conflicted;
    [entries addObject:@{
      @"path": path,
      @"index_status": LPStatusName(entry->status, YES),
      @"worktree_status": LPStatusName(entry->status, NO),
      @"conflicted": @(conflicted),
    }];
  }
  git_status_list_free(statusList);

  NSString *branch = nil;
  NSString *headOid = nil;
  size_t ahead = 0;
  size_t behind = 0;
  git_reference *head = nullptr;
  int headResult = git_repository_head(&head, repository);
  if (headResult == 0 && head != nullptr) {
    const git_oid *target = git_reference_target(head);
    headOid = LPOidString(target);
    if (git_reference_is_branch(head)) {
      const char *shorthand = git_reference_shorthand(head);
      branch = shorthand == nullptr ? nil : [NSString stringWithUTF8String:shorthand];
      git_reference *upstream = nullptr;
      if (git_branch_upstream(&upstream, head) == 0 && upstream != nullptr) {
        const git_oid *upstreamTarget = git_reference_target(upstream);
        if (target != nullptr && upstreamTarget != nullptr) {
          git_graph_ahead_behind(&ahead, &behind, repository, target, upstreamTarget);
        }
        git_reference_free(upstream);
      }
    }
  } else if (headResult == GIT_EUNBORNBRANCH) {
    git_reference *headReference = nullptr;
    if (git_reference_lookup(&headReference, repository, "HEAD") == 0
      && headReference != nullptr) {
      const char *symbolic = git_reference_symbolic_target(headReference);
      if (symbolic != nullptr && strncmp(symbolic, "refs/heads/", 11) == 0) {
        branch = [NSString stringWithUTF8String:symbolic + 11];
      }
      git_reference_free(headReference);
    }
  }
  if (head != nullptr) git_reference_free(head);
  if (branch != nil && (!LPIsSafeRepositoryPath(branch) || [branch containsString:@".."]
    || [branch containsString:@" "])) {
    if (error != nil) *error = LPError(3022, @"Repository branch name is unsafe");
    return nil;
  }
  return @{
    @"schema_version": @1,
    @"project_id": projectId,
    @"branch": branch ?: NSNull.null,
    @"head_oid": headOid ?: NSNull.null,
    @"clean": @(entries.count == 0),
    @"has_conflicts": @(hasConflicts),
    @"ahead": @(ahead),
    @"behind": @(behind),
    @"entries": entries,
  };
}

- (BOOL)repositoryContainsGitlink:(git_repository *)repository {
  git_index *index = nullptr;
  if (git_repository_index(&index, repository) < 0 || index == nullptr) return YES;
  BOOL contains = NO;
  size_t count = git_index_entrycount(index);
  for (size_t item = 0; item < count; item += 1) {
    const git_index_entry *entry = git_index_get_byindex(index, item);
    if (entry != nullptr && entry->mode == GIT_FILEMODE_COMMIT) {
      contains = YES;
      break;
    }
  }
  git_index_free(index);
  return contains;
}

- (DSHLocalProjectLease *)v2LeaseForRoot:(NSDictionary *)root
                                   mode:(DSHLocalProjectAccessMode)mode
                                  error:(NSError **)error {
  NSDictionary *canonical = LPV2Root(root, YES, error);
  if (canonical == nil || self.projectAccessV2 == nil) {
    if (error != nil && *error == nil) {
      *error = LPError(3102, @"Workspace project is unavailable");
    }
    return nil;
  }
  if (self.workspaceAccessV2 == nil) {
    if (error != nil) *error = LPError(3102, @"Workspace project is unavailable");
    return nil;
  }
  NSSet<NSString *> *requiredCapabilities = mode == DSHLocalProjectAccessModeRead
      ? [NSSet setWithObjects:@"read", @"git", nil]
      : [NSSet setWithObjects:@"read", @"write", @"git", nil];
  NSError *accessError = nil;
  DSHLocalWorkspaceLease *workspaceLease = [self.workspaceAccessV2
      leaseWorkspaceId:canonical[@"workspace_id"]
      expectedBindingRevision:[canonical[@"binding_revision"] unsignedIntegerValue]
      requiredCapabilities:requiredCapabilities
      error:&accessError];
  DSHLocalProjectLease *lease = workspaceLease == nil ? nil
      : [self.projectAccessV2
          leaseWorkspaceRootRef:canonical
                  workspaceLease:workspaceLease
                             mode:mode
                  includeMetadata:YES
                          timeout:2.0
                            error:&accessError];
  if (lease == nil && error != nil) {
    *error = accessError ?: LPError(3102, @"Workspace project is unavailable");
  }
  return lease;
}

- (NSDictionary *)v2ProjectDescriptorForLease:(DSHLocalProjectLease *)lease
                                          root:(NSDictionary *)root {
  NSDictionary *canonicalRoot = LPV2Root(root, YES, nil);
  if (lease == nil || canonicalRoot == nil ||
      ![lease.projectId isEqual:canonicalRoot[@"project_id"]] ||
      ![lease.workspaceId isEqual:canonicalRoot[@"workspace_id"]] ||
      lease.workspaceBindingRevision !=
          [canonicalRoot[@"binding_revision"] unsignedIntegerValue]) {
    return nil;
  }
  return @{
    @"schema_version" : @2,
    @"project_id" : lease.projectId,
    @"workspace_id" : lease.workspaceId,
    @"workspace_binding_revision" :
        @(lease.workspaceBindingRevision),
    @"display_name" : LPV2ProjectDisplayName(lease),
    @"git_topology" : lease.gitTopology ?: LPV2GitTopology,
  };
}

- (NSDictionary *)v2ProjectDescriptorForRoot:(NSDictionary *)root
                                    projectId:(NSString *)projectId
                                  displayName:(NSString *)displayName {
  NSDictionary *canonical = LPV2Root(root, YES, nil);
  if (canonical == nil ||
      ![projectId isKindOfClass:NSString.class] ||
      ![DSHLocalProjectAccess isCanonicalProjectId:projectId] ||
      ![projectId isEqual:canonical[@"project_id"]] ||
      !LPV2BoundedString(displayName, LPMaxProjectNameBytes, NO)) {
    return nil;
  }
  return @{
    @"schema_version" : @2,
    @"project_id" : projectId,
    @"workspace_id" : canonical[@"workspace_id"],
    @"workspace_binding_revision" : canonical[@"binding_revision"],
    @"display_name" : displayName,
    @"git_topology" : LPV2GitTopology,
  };
}

- (DSHLocalProjectAccess *)v2LegacyProjectAccess {
  return self.projectAccess;
}

- (NSString *)v2RootFingerprintForRoot:(NSDictionary *)root
                                  error:(NSError **)error {
  NSDictionary *canonical = LPV2Root(root, NO, error);
  if (canonical == nil || self.workspaceAccessV2 == nil) return nil;
  NSError *authorityError = nil;
  NSDictionary *registry = [self.workspaceAccessV2
      loadRegistry:&authorityError digest:nil];
  NSDictionary *record = registry == nil
      ? nil
      : [self.workspaceAccessV2 recordInRegistry:registry
                                      workspaceId:canonical[@"workspace_id"]];
  NSDictionary *authority = record == nil
      ? nil
      : [self.workspaceAccessV2 loadAuthorityForRecord:record
                                                  error:&authorityError];
  NSString *fingerprint = LPString(authority[@"root_fingerprint_sha256"]);
  if (authority == nil ||
      ![authority[@"workspace_id"] isEqual:canonical[@"workspace_id"]] ||
      ![authority[@"binding_revision"] isEqual:canonical[@"binding_revision"]] ||
      !LPV2CanonicalDigest(fingerprint)) {
    if (error != nil) {
      *error = authorityError ?: LPError(3103, @"Workspace authority is unavailable");
    }
    return nil;
  }
  return [fingerprint copy];
}

- (NSURL *)v2GitDirectoryURLForWorkspaceId:(NSString *)workspaceId
                                  projectId:(NSString *)projectId {
  NSURL *privateRoot = self.workspaceAccessV2.privateRootURL;
  if (privateRoot == nil ||
      ![DSHLocalProjectAccess isCanonicalProjectId:workspaceId] ||
      ![DSHLocalProjectAccess isCanonicalProjectId:projectId]) {
    return nil;
  }
  NSURL *gitdirs = [privateRoot URLByAppendingPathComponent:@"workspace-gitdirs"
                                               isDirectory:YES];
  NSURL *workspace = [gitdirs URLByAppendingPathComponent:workspaceId
                                               isDirectory:YES];
  return [workspace URLByAppendingPathComponent:projectId isDirectory:YES];
}

- (BOOL)v2WriteBindingForRoot:(NSDictionary *)root
                      projectId:(NSString *)projectId
                    displayName:(NSString *)displayName
                          gitURL:(NSURL *)gitURL
                   rootFingerprint:(NSString *)rootFingerprint
                             error:(NSError **)error {
  if (gitURL == nil || !LPV2CanonicalDigest(rootFingerprint) ||
      !LPV2BoundedString(displayName, LPMaxProjectNameBytes, NO)) {
    if (error != nil) *error = LPError(3104, @"Project binding is invalid");
    return NO;
  }
  NSDictionary *canonical = LPV2Root(root, YES, error);
  if (canonical == nil) return NO;
  NSURL *privateRoot = self.workspaceAccessV2.privateRootURL;
  NSString *relative = [NSString stringWithFormat:@"workspace-gitdirs/%@/%@",
      canonical[@"workspace_id"], projectId];
  NSDictionary *binding = @{
    @"schema_version" : @2,
    @"workspace_id" : canonical[@"workspace_id"],
    @"binding_revision" : canonical[@"binding_revision"],
    @"project_id" : projectId,
    @"display_name" : displayName,
    @"git_topology" : LPV2GitTopology,
    @"git_directory_relative" : relative,
    @"root_fingerprint_sha256" : rootFingerprint,
  };
  NSData *data = [NSJSONSerialization dataWithJSONObject:binding
                                                   options:NSJSONWritingSortedKeys
                                                     error:nil];
  if (data == nil || privateRoot == nil) {
    if (error != nil) *error = LPError(3104, @"Project binding is invalid");
    return NO;
  }
  NSURL *bindingURL = [gitURL URLByAppendingPathComponent:LPV2BindingFile];
  int descriptor = open(bindingURL.fileSystemRepresentation,
                         O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                         0600);
  BOOL written = descriptor >= 0 && LPWriteAll(descriptor, data) &&
      fchmod(descriptor, 0600) == 0 && fsync(descriptor) == 0;
  if (descriptor >= 0) close(descriptor);
  written = written &&
      [[NSFileManager defaultManager]
          setAttributes:@{NSFilePosixPermissions : @0600,
                          NSFileProtectionKey : NSFileProtectionComplete}
                 ofItemAtPath:bindingURL.path error:nil] &&
      [bindingURL setResourceValue:@YES
                             forKey:NSURLIsExcludedFromBackupKey
                              error:nil];
  int parent = written
      ? open(gitURL.fileSystemRepresentation,
             O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      : -1;
  BOOL durable = written && parent >= 0 && fsync(parent) == 0;
  if (parent >= 0) close(parent);
  if (!durable) {
    unlink(bindingURL.fileSystemRepresentation);
    if (error != nil) *error = LPError(3104, @"Project binding cannot be saved");
    return NO;
  }
  return YES;
}

- (NSDictionary *)v2BindingForRoot:(NSDictionary *)root
                          projectId:(NSString *)projectId
                             error:(NSError **)error {
  NSDictionary *canonical = LPV2Root(root, YES, error);
  NSURL *gitURL = [self v2GitDirectoryURLForWorkspaceId:canonical[@"workspace_id"]
                                                projectId:projectId];
  if (canonical == nil || gitURL == nil) return nil;
  NSURL *bindingURL = [gitURL URLByAppendingPathComponent:LPV2BindingFile];
  struct stat metadata = {};
  if (lstat(bindingURL.fileSystemRepresentation, &metadata) != 0 ||
      !S_ISREG(metadata.st_mode) || metadata.st_nlink != 1 ||
      metadata.st_size <= 0 || metadata.st_size > 64 * 1024) {
    if (error != nil) *error = LPError(3102, @"Workspace project is unavailable");
    return nil;
  }
  int descriptor = open(bindingURL.fileSystemRepresentation,
                        O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  struct stat opened = {};
  BOOL readable = descriptor >= 0 && fstat(descriptor, &opened) == 0 &&
      LPSameNode(metadata, opened) && opened.st_size == metadata.st_size;
  NSMutableData *data = readable
      ? [NSMutableData dataWithLength:(NSUInteger)opened.st_size]
      : nil;
  NSUInteger offset = 0;
  while (readable && offset < data.length) {
    ssize_t count = pread(descriptor,
                           static_cast<uint8_t *>(data.mutableBytes) + offset,
                           data.length - offset, (off_t)offset);
    if (count <= 0) {
      readable = NO;
      break;
    }
    offset += (NSUInteger)count;
  }
  struct stat closed = {};
  readable = readable && fstat(descriptor, &closed) == 0 &&
      LPSameNode(opened, closed) && closed.st_size == opened.st_size;
  if (descriptor >= 0) close(descriptor);
  if (!readable) data = nil;
  NSDictionary *binding = LPDictionary([NSJSONSerialization
      JSONObjectWithData:data options:0 error:nil]);
  if (!LPV2ExactKeys(binding, @[
        @"schema_version", @"workspace_id", @"binding_revision",
        @"project_id", @"display_name", @"git_topology",
        @"git_directory_relative", @"root_fingerprint_sha256"
      ]) || ![binding[@"schema_version"] isEqual:@2] ||
      ![binding[@"workspace_id"] isEqual:canonical[@"workspace_id"]] ||
      ![binding[@"binding_revision"] isEqual:canonical[@"binding_revision"]] ||
      ![binding[@"project_id"] isEqual:projectId] ||
      ![binding[@"git_topology"] isEqual:LPV2GitTopology] ||
      !LPV2BoundedString(binding[@"display_name"], LPMaxProjectNameBytes, NO) ||
      !LPV2CanonicalDigest(binding[@"root_fingerprint_sha256"])) {
    if (error != nil) *error = LPError(3104, @"Project binding is invalid");
    return nil;
  }
  NSString *fingerprint = [self v2RootFingerprintForRoot:@{
    @"schema_version" : @1,
    @"workspace_id" : canonical[@"workspace_id"],
    @"binding_revision" : canonical[@"binding_revision"],
    @"project_id" : NSNull.null,
  } error:error];
  if (fingerprint == nil || ![fingerprint isEqual:binding[@"root_fingerprint_sha256"]]) {
    if (error != nil && *error == nil) *error = LPError(3104, @"Project binding is invalid");
    return nil;
  }
  return binding;
}

- (NSDictionary *)v2ProjectForWorkspace:(NSDictionary *)root
                                   error:(NSError **)error {
  NSDictionary *canonical = LPV2Root(root, NO, error);
  if (canonical == nil) return nil;
  id project = canonical[@"project_id"];
  if (project != NSNull.null) {
    NSDictionary *binding = [self v2BindingForRoot:canonical
                                           projectId:project
                                              error:error];
    NSDictionary *descriptor = binding == nil
        ? nil
        : [self v2ProjectDescriptorForRoot:canonical
                                 projectId:project
                               displayName:binding[@"display_name"]];
    return descriptor == nil
        ? nil
        : @{ @"schema_version" : @1, @"status" : @"attached",
             @"project" : descriptor };
  }
  NSError *legacyRelationError = nil;
  NSString *legacyProjectId = [self.workspaceAccessV2
      legacyProjectIdForWorkspaceId:canonical[@"workspace_id"]
      expectedBindingRevision:
          [canonical[@"binding_revision"] unsignedIntegerValue]
      error:&legacyRelationError];
  if (legacyProjectId != nil) {
    NSError *legacyEvidenceError = nil;
    NSDictionary *evidence = [[self v2LegacyProjectAccess]
        legacyWorkspaceBootstrapEvidenceForProjectId:legacyProjectId
                                               error:&legacyEvidenceError];
    NSString *verifiedProjectId = LPString(evidence[@"project_id"]);
    NSString *displayName = LPString(evidence[@"display_name"]);
    if (evidence == nil ||
        ![verifiedProjectId isEqual:legacyProjectId] ||
        !LPV2BoundedString(displayName, LPMaxProjectNameBytes, NO)) {
      if (error != nil) {
        *error = LPError(3110, @"Legacy workspace project relation changed");
      }
      return nil;
    }
    NSDictionary *descriptor = @{
      @"schema_version" : @2,
      @"project_id" : legacyProjectId,
      @"workspace_id" : canonical[@"workspace_id"],
      @"workspace_binding_revision" : canonical[@"binding_revision"],
      @"display_name" : displayName,
      @"git_topology" : @"legacy_embedded",
    };
    return @{ @"schema_version" : @1, @"status" : @"attached",
              @"project" : descriptor };
  }
  if (legacyRelationError != nil) {
    DSHLocalWorkspaceAccessErrorCode code =
        (DSHLocalWorkspaceAccessErrorCode)legacyRelationError.code;
    if ([legacyRelationError.domain
            isEqual:DSHLocalWorkspaceAccessErrorDomain] &&
        (code == DSHLocalWorkspaceAccessErrorRevisionStale ||
         code == DSHLocalWorkspaceAccessErrorRootChanged ||
         code == DSHLocalWorkspaceAccessErrorConflict)) {
      if (error != nil) {
        *error = LPError(3110, @"Legacy workspace project relation changed");
      }
    } else if (error != nil) {
      *error = legacyRelationError;
    }
    return nil;
  }
  NSURL *workspaceGitRoot = [[self.workspaceAccessV2.privateRootURL
      URLByAppendingPathComponent:@"workspace-gitdirs" isDirectory:YES]
      URLByAppendingPathComponent:canonical[@"workspace_id"] isDirectory:YES];
  NSError *enumerationError = nil;
  NSArray<NSURL *> *children = [self
      v2AttachContentsOfDirectory:workspaceGitRoot error:&enumerationError];
  if (children == nil) {
    if ([enumerationError.domain isEqual:NSCocoaErrorDomain] &&
        enumerationError.code == NSFileReadNoSuchFileError) {
      return @{ @"schema_version" : @1, @"status" : @"none" };
    }
    if (error != nil) {
      *error = enumerationError ?:
          LPError(3104, @"Workspace project enumeration failed");
    }
    return nil;
  }
  NSMutableArray<NSString *> *projectIds = [NSMutableArray array];
  for (NSURL *child in children) {
    NSString *candidate = child.lastPathComponent;
    if ([candidate hasPrefix:@".rish-attach-"]) continue;
    if (![DSHLocalProjectAccess isCanonicalProjectId:candidate]) continue;
    NSDictionary *candidateRoot = @{
      @"schema_version" : @1,
      @"workspace_id" : canonical[@"workspace_id"],
      @"binding_revision" : canonical[@"binding_revision"],
      @"project_id" : candidate,
    };
    if ([self v2BindingForRoot:candidateRoot
                      projectId:candidate error:error] == nil) return nil;
    [projectIds addObject:candidate];
  }
  if (projectIds.count == 0) {
    return @{ @"schema_version" : @1, @"status" : @"none" };
  }
  if (projectIds.count != 1) {
    if (error != nil) *error = LPError(3105, @"Workspace has conflicting projects");
    return nil;
  }
  NSDictionary *attachedRoot = @{
    @"schema_version" : @1,
    @"workspace_id" : canonical[@"workspace_id"],
    @"binding_revision" : canonical[@"binding_revision"],
    @"project_id" : projectIds.firstObject,
  };
  NSDictionary *binding = [self v2BindingForRoot:attachedRoot
                                         projectId:projectIds.firstObject
                                            error:error];
  NSDictionary *descriptor = binding == nil
      ? nil
      : [self v2ProjectDescriptorForRoot:attachedRoot
                               projectId:projectIds.firstObject
                             displayName:binding[@"display_name"]];
  if (descriptor == nil) {
    if (error != nil && *error == nil) *error = LPError(3102, @"Workspace project is unavailable");
    return nil;
  }
  return @{ @"schema_version" : @1, @"status" : @"attached",
            @"project" : descriptor };
}

- (BOOL)v2FsyncDirectoryAtURL:(NSURL *)url error:(NSError **)error {
  int descriptor = url == nil ? -1 : open(url.fileSystemRepresentation,
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  BOOL durable = descriptor >= 0 && fsync(descriptor) == 0;
  if (descriptor >= 0) close(descriptor);
  if (!durable && error != nil) {
    *error = LPError(3104, @"Attach directory is not durable");
  }
  return durable;
}

- (NSArray<NSURL *> *)v2AttachContentsOfDirectory:(NSURL *)directory
                                             error:(NSError **)error {
  if (self.v2AttachFaultHook != nil &&
      self.v2AttachFaultHook(@"attach_reconcile_enumeration")) {
    if (error != nil) *error = LPError(3104, @"Attach enumeration failed");
    return nil;
  }
  NSError *enumerationError = nil;
  NSArray<NSURL *> *entries = [[NSFileManager defaultManager]
      contentsOfDirectoryAtURL:directory
      includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLIsRegularFileKey]
                         options:0
                           error:&enumerationError];
  if (entries == nil && error != nil) *error = enumerationError;
  return entries;
}

- (BOOL)v2WriteAttachJournalData:(NSData *)data
                            toURL:(NSURL *)url
                            error:(NSError **)error {
  if (![data isKindOfClass:NSData.class] || data.length == 0 ||
      data.length > LPV2MaxAttachJournalBytes || url == nil) {
    if (error != nil) *error = LPError(3104, @"Attach journal is invalid");
    return NO;
  }
  NSError *writeError = nil;
  BOOL written = [data writeToURL:url
                         options:NSDataWritingAtomic
                           error:&writeError];
  if (written) {
    written = [[NSFileManager defaultManager]
        setAttributes:@{NSFilePosixPermissions : @0600,
                        NSFileProtectionKey : NSFileProtectionComplete}
           ofItemAtPath:url.path error:&writeError] &&
        [url setResourceValue:@YES
                       forKey:NSURLIsExcludedFromBackupKey error:&writeError];
  }
  int descriptor = written ? open(url.fileSystemRepresentation,
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW) : -1;
  struct stat metadata = {};
  written = written && descriptor >= 0 && fstat(descriptor, &metadata) == 0 &&
      S_ISREG(metadata.st_mode) && metadata.st_nlink == 1 &&
      metadata.st_size == (off_t)data.length && fsync(descriptor) == 0;
  if (descriptor >= 0) close(descriptor);
  if (written) {
    written = [self v2FsyncDirectoryAtURL:url.URLByDeletingLastPathComponent
                                    error:&writeError];
  }
  if (!written && error != nil) {
    *error = writeError ?: LPError(3104, @"Attach journal cannot be saved");
  }
  return written;
}

- (BOOL)v2RemoveAttachItemAtURL:(NSURL *)url
                          parent:(NSURL *)parent
                           error:(NSError **)error {
  if (url == nil || parent == nil ||
      ![url.URLByDeletingLastPathComponent.path.stringByStandardizingPath
          isEqual:parent.path.stringByStandardizingPath]) {
    if (error != nil) *error = LPError(3104, @"Attach cleanup target is invalid");
    return NO;
  }
  if (self.v2AttachFaultHook != nil &&
      self.v2AttachFaultHook(@"attach_cleanup")) {
    if (error != nil) *error = LPError(3104, @"Attach cleanup failed");
    return NO;
  }
  struct stat state = {};
  if (lstat(url.fileSystemRepresentation, &state) != 0) {
    if (errno == ENOENT) return YES;
    if (error != nil) *error = LPError(3104, @"Attach cleanup stat failed");
    return NO;
  }
  NSError *cleanupError = nil;
  if (![[NSFileManager defaultManager] removeItemAtURL:url error:&cleanupError] ||
      ![self v2FsyncDirectoryAtURL:parent error:&cleanupError]) {
    if (error != nil) {
      *error = cleanupError ?: LPError(3104, @"Attach cleanup failed");
    }
    return NO;
  }
  return YES;
}

- (BOOL)v2ReconcileAttachStagingForWorkspaceId:(NSString *)workspaceId
                                         error:(NSError **)error {
  if (![DSHLocalProjectAccess isCanonicalProjectId:workspaceId] ||
      self.workspaceAccessV2.privateRootURL == nil) {
    if (error != nil) *error = LPError(3104, @"Attach reconciliation root is invalid");
    return NO;
  }
  NSURL *workspaceGitRoot = [[self.workspaceAccessV2.privateRootURL
      URLByAppendingPathComponent:@"workspace-gitdirs" isDirectory:YES]
      URLByAppendingPathComponent:workspaceId isDirectory:YES];
  NSError *enumerationError = nil;
  NSArray<NSURL *> *entries = [self
      v2AttachContentsOfDirectory:workspaceGitRoot error:&enumerationError];
  if (entries == nil) {
    if ([enumerationError.domain isEqual:NSCocoaErrorDomain] &&
        enumerationError.code == NSFileReadNoSuchFileError) return YES;
    if (error != nil) {
      *error = enumerationError ?:
          LPError(3104, @"Attach staging enumeration failed");
    }
    return NO;
  }
  NSMutableDictionary<NSString *, NSURL *> *stagingByOperation =
      [NSMutableDictionary dictionary];
  NSMutableDictionary<NSString *, NSURL *> *journalByOperation =
      [NSMutableDictionary dictionary];
  NSMutableDictionary<NSString *, NSDictionary *> *journals =
      [NSMutableDictionary dictionary];
  for (NSURL *entry in entries) {
    if (![entry.lastPathComponent hasPrefix:@".rish-attach-"]) continue;
    NSString *name = entry.lastPathComponent;
    NSString *operation = [name substringFromIndex:@".rish-attach-".length];
    BOOL journalEntry = [operation hasSuffix:@".journal"];
    if (journalEntry) {
      operation = [operation substringToIndex:
          operation.length - @".journal".length];
    }
    if (!LPV2CanonicalOperationId(operation)) {
      if (error != nil) *error = LPError(3104, @"Attach staging entry is invalid");
      return NO;
    }
    if (journalEntry) {
      NSDictionary *journal = LPV2ReadAttachJournal(
          entry, workspaceId, operation, error);
      if (journal == nil || journalByOperation[operation] != nil) return NO;
      journalByOperation[operation] = entry;
      journals[operation] = journal;
    } else {
      if (stagingByOperation[operation] != nil) {
        if (error != nil) *error = LPError(3104, @"Attach staging is duplicated");
        return NO;
      }
      stagingByOperation[operation] = entry;
    }
  }
  for (NSString *operation in journals) {
    NSDictionary *journal = journals[operation];
    NSURL *journalURL = journalByOperation[operation];
    NSURL *stagingURL = stagingByOperation[operation];
    NSURL *finalURL = [workspaceGitRoot
        URLByAppendingPathComponent:journal[@"final_name"] isDirectory:YES];
    struct stat stagingState = {};
    struct stat finalState = {};
    BOOL stagingExists = stagingURL != nil &&
        lstat(stagingURL.fileSystemRepresentation, &stagingState) == 0;
    BOOL finalExists = lstat(finalURL.fileSystemRepresentation, &finalState) == 0;
    if ((stagingExists && finalExists) ||
        ([journal[@"phase"] isEqual:@"published"] && stagingExists)) {
      if (error != nil) *error = LPError(3104, @"Attach recovery is ambiguous");
      return NO;
    }
    if (finalExists) {
      NSDictionary *root = @{
        @"schema_version" : @1,
        @"workspace_id" : journal[@"workspace_id"],
        @"binding_revision" : journal[@"binding_revision"],
        @"project_id" : journal[@"project_id"],
      };
      NSError *leaseError = nil;
      DSHLocalProjectLease *lease = [self v2LeaseForRoot:root
                                                   mode:DSHLocalProjectAccessModeRead
                                                  error:&leaseError];
      if (lease == nil ||
          ![lease.rootFingerprintSHA256
              isEqual:journal[@"root_fingerprint_sha256"]]) {
        if (error != nil) {
          *error = leaseError ?: LPError(3104, @"Published attach is invalid");
        }
        return NO;
      }
    }
    if (stagingExists && ![self v2RemoveAttachItemAtURL:stagingURL
                                                  parent:workspaceGitRoot
                                                   error:error]) {
      return NO;
    }
    if (![self v2RemoveAttachItemAtURL:journalURL
                                parent:workspaceGitRoot error:error]) {
      return NO;
    }
    [stagingByOperation removeObjectForKey:operation];
  }
  for (NSString *operation in stagingByOperation) {
    if (![self v2RemoveAttachItemAtURL:stagingByOperation[operation]
                                parent:workspaceGitRoot error:error]) {
      return NO;
    }
  }
  return YES;
}

- (BOOL)v2ReconcileAllAttachStaging:(NSError **)error {
  NSURL *privateRoot = self.workspaceAccessV2.privateRootURL;
  if (privateRoot == nil) {
    if (error != nil) *error = LPError(3104, @"Attach startup root is unavailable");
    return NO;
  }
  NSURL *gitdirs = [privateRoot URLByAppendingPathComponent:@"workspace-gitdirs"
                                                isDirectory:YES];
  NSError *enumerationError = nil;
  NSArray<NSURL *> *workspaces = [self
      v2AttachContentsOfDirectory:gitdirs error:&enumerationError];
  if (workspaces == nil) {
    if ([enumerationError.domain isEqual:NSCocoaErrorDomain] &&
        enumerationError.code == NSFileReadNoSuchFileError) return YES;
    if (error != nil) {
      *error = enumerationError ?:
          LPError(3104, @"Attach startup enumeration failed");
    }
    return NO;
  }
  for (NSURL *workspace in workspaces) {
    NSString *workspaceId = workspace.lastPathComponent;
    if (![DSHLocalProjectAccess isCanonicalProjectId:workspaceId]) continue;
    if (![self v2ReconcileAttachStagingForWorkspaceId:workspaceId error:error]) {
      return NO;
    }
  }
  return YES;
}

- (NSDictionary *)v2AttachWorkspaceProject:(NSDictionary *)request
                                      error:(NSError **)error {
  NSDictionary *canonical = LPV2Root(request[@"root"], NO, error);
  NSString *operationId = LPString(request[@"operation_id"]);
  NSString *mode = LPString(request[@"mode"]);
  if (!LPV2ExactKeys(request, @[
        @"schema_version", @"operation_id", @"root", @"mode"
      ]) || ![request[@"schema_version"] isEqual:@1] ||
      !LPV2CanonicalOperationId(operationId) || canonical == nil ||
      (![mode isEqual:@"open"] && ![mode isEqual:@"init"])) {
    if (error != nil) *error = LPError(3101, @"Project attach request is invalid");
    return nil;
  }
  if (self.v2AttachStartupError != nil) {
    if (error != nil) *error = self.v2AttachStartupError;
    return nil;
  }
  if (self.workspaceAccessV2 == nil ||
      ![self v2ReconcileAttachStagingForWorkspaceId:canonical[@"workspace_id"]
                                              error:error]) {
    if (error != nil && *error == nil) {
      *error = LPError(3104, @"Attach staging reconciliation failed");
    }
    return nil;
  }
  NSDictionary *cached = nil;
  @synchronized (self) {
    cached = self.v2AttachResults[operationId];
  }
  if (cached != nil) {
    if (![cached[@"root"] isEqual:canonical]) {
      if (error != nil) *error = LPError(3106, @"Project attach operation conflicts");
      return nil;
    }
    NSString *cachedProjectId = cached[@"result"][@"project"][@"project_id"];
    NSDictionary *cachedRoot = cachedProjectId == nil ? nil : @{
      @"schema_version" : @1,
      @"workspace_id" : canonical[@"workspace_id"],
      @"binding_revision" : canonical[@"binding_revision"],
      @"project_id" : cachedProjectId,
    };
    DSHLocalProjectLease *cachedLease = cachedRoot == nil
        ? nil : [self v2LeaseForRoot:cachedRoot
                                  mode:DSHLocalProjectAccessModeRead
                                 error:error];
    NSDictionary *verifiedProject = cachedLease == nil
        ? nil : [self v2ProjectDescriptorForLease:cachedLease root:cachedRoot];
    if (verifiedProject == nil) {
      if (error != nil && *error == nil) {
        *error = LPError(3102, @"Cached project verification failed");
      }
      return nil;
    }
    return @{ @"schema_version" : @1,
              @"status" : @"already_attached",
              @"project" : verifiedProject };
  }
  if (canonical[@"project_id"] != NSNull.null) {
    NSDictionary *existing = [self v2ProjectForWorkspace:canonical error:error];
    if (existing == nil || ![existing[@"status"] isEqual:@"attached"]) {
      return nil;
    }
    DSHLocalProjectLease *verifiedLease = [self v2LeaseForRoot:canonical
                                                            mode:DSHLocalProjectAccessModeRead
                                                           error:error];
    NSDictionary *verifiedProject = verifiedLease == nil
        ? nil : [self v2ProjectDescriptorForLease:verifiedLease root:canonical];
    if (verifiedProject == nil) {
      if (error != nil && *error == nil) {
        *error = LPError(3102, @"Attached project verification failed");
      }
      return nil;
    }
    NSDictionary *result = @{ @"schema_version" : @1,
                              @"status" : @"already_attached",
                              @"project" : verifiedProject };
    @synchronized (self) {
      self.v2AttachResults[operationId] = @{ @"root" : canonical,
                                             @"result" : result };
    }
    return result;
  }
  NSDictionary *existing = [self v2ProjectForWorkspace:canonical error:error];
  if (existing == nil) return nil;
  if ([existing[@"status"] isEqual:@"attached"]) {
    NSString *attachedProjectId = existing[@"project"][@"project_id"];
    NSDictionary *attachedRoot = attachedProjectId == nil ? nil : @{
      @"schema_version" : @1,
      @"workspace_id" : canonical[@"workspace_id"],
      @"binding_revision" : canonical[@"binding_revision"],
      @"project_id" : attachedProjectId,
    };
    DSHLocalProjectLease *verifiedLease = attachedRoot == nil
        ? nil : [self v2LeaseForRoot:attachedRoot
                                  mode:DSHLocalProjectAccessModeRead
                                 error:error];
    NSDictionary *verifiedProject = verifiedLease == nil
        ? nil : [self v2ProjectDescriptorForLease:verifiedLease root:attachedRoot];
    if (verifiedProject == nil) {
      if (error != nil && *error == nil) {
        *error = LPError(3102, @"Attached project verification failed");
      }
      return nil;
    }
    NSDictionary *result = @{ @"schema_version" : @1,
                              @"status" : @"already_attached",
                              @"project" : verifiedProject };
    @synchronized (self) {
      self.v2AttachResults[operationId] = @{ @"root" : canonical,
                                             @"result" : result };
    }
    return result;
  }
  if ([mode isEqual:@"open"]) {
    if (error != nil) *error = LPError(3102, @"Workspace project is unavailable");
    return nil;
  }
  if (self.workspaceAccessV2 == nil || self.projectAccessV2 == nil) {
    if (error != nil) *error = LPError(3102, @"Workspace project is unavailable");
    return nil;
  }
  NSError *workspaceError = nil;
  DSHLocalWorkspaceLease *workspaceLease = [self.workspaceAccessV2
      leaseWorkspaceId:canonical[@"workspace_id"]
      expectedBindingRevision:[canonical[@"binding_revision"] unsignedIntegerValue]
      requiredCapabilities:[NSSet setWithObjects:@"read", @"write", @"git", nil]
      error:&workspaceError];
  if (workspaceLease == nil) {
    if (error != nil) *error = workspaceError ?: LPError(3102, @"Workspace project is unavailable");
    return nil;
  }
  NSString *rootPath = LPV2DescriptorPath(workspaceLease.rootDescriptor);
  struct stat rootBefore = {};
  BOOL rootBeforeValid = rootPath != nil &&
      fstat(workspaceLease.rootDescriptor, &rootBefore) == 0 &&
      S_ISDIR(rootBefore.st_mode);
  NSString *fingerprint = [self v2RootFingerprintForRoot:canonical error:error];
  NSString *projectId = NSUUID.UUID.UUIDString.lowercaseString;
  NSURL *gitURL = [self v2GitDirectoryURLForWorkspaceId:canonical[@"workspace_id"]
                                                projectId:projectId];
  if (!rootBeforeValid || fingerprint == nil || gitURL == nil ||
      !LPV2CanonicalOperationId(projectId)) {
    if (error != nil && *error == nil) *error = LPError(3102, @"Workspace project is unavailable");
    return nil;
  }
  NSURL *finalGitURL = gitURL;
  NSURL *gitParent = finalGitURL.URLByDeletingLastPathComponent;
  NSURL *stagingGitURL = [gitParent
      URLByAppendingPathComponent:[NSString stringWithFormat:@".rish-attach-%@", operationId]
                         isDirectory:YES];
  NSURL *attachJournalURL = [gitParent
      URLByAppendingPathComponent:[NSString stringWithFormat:@".rish-attach-%@.journal", operationId]
                         isDirectory:NO];
  NSDictionary *attachJournal = @{
    @"schema_version" : @1,
    @"operation_id" : operationId,
    @"workspace_id" : canonical[@"workspace_id"],
    @"binding_revision" : canonical[@"binding_revision"],
    @"project_id" : projectId,
    @"root_fingerprint_sha256" : fingerprint,
    @"staging_name" : stagingGitURL.lastPathComponent,
    @"final_name" : finalGitURL.lastPathComponent,
    @"phase" : @"prepared",
  };
  NSError *attachError = nil;
  if (![[NSFileManager defaultManager]
          createDirectoryAtURL:gitParent
     withIntermediateDirectories:YES
                      attributes:@{NSFilePosixPermissions : @0700}
                           error:&attachError] ||
      ![self v2FsyncDirectoryAtURL:gitParent.URLByDeletingLastPathComponent
                              error:&attachError]) {
    if (error != nil) {
      *error = attachError ?: LPError(3104, @"Attach staging root cannot be created");
    }
    return nil;
  }
  NSData *attachJournalData = [NSJSONSerialization
      dataWithJSONObject:attachJournal options:NSJSONWritingSortedKeys error:nil];
  if (attachJournalData == nil ||
      ![self v2WriteAttachJournalData:attachJournalData
                                toURL:attachJournalURL error:&attachError]) {
    (void)[self v2RemoveAttachItemAtURL:attachJournalURL
                                 parent:gitParent error:nil];
    if (error != nil) {
      *error = attachError ?: LPError(3104, @"Attach journal cannot be saved");
    }
    return nil;
  }
  if (self.v2AttachFaultHook != nil && self.v2AttachFaultHook(@"after_attach_journal")) {
    (void)[self v2RemoveAttachItemAtURL:attachJournalURL
                                 parent:gitParent error:nil];
    if (error != nil) *error = LPError(3104, @"Attach interrupted after journal");
    return nil;
  }
  BOOL (^cleanupAttachURL)(NSURL *) = ^BOOL(NSURL *url) {
    NSError *cleanupError = nil;
    BOOL cleaned = [self v2RemoveAttachItemAtURL:url
                                          parent:gitParent
                                           error:&cleanupError];
    if (!cleaned && error != nil) {
      *error = cleanupError ?:
          LPError(3104, @"Attach cleanup failed; reconciliation required");
    }
    return cleaned;
  };
  BOOL stagingCreateFault = self.v2AttachFaultHook != nil &&
      self.v2AttachFaultHook(@"attach_staging_create");
  BOOL stagingCreated = !stagingCreateFault &&
      [[NSFileManager defaultManager]
          createDirectoryAtURL:stagingGitURL
     withIntermediateDirectories:NO
                      attributes:@{NSFilePosixPermissions : @0700}
                           error:&attachError];
  BOOL stagingDurable = stagingCreated &&
      [self v2FsyncDirectoryAtURL:gitParent error:&attachError];
  if (!stagingDurable) {
    if (stagingCreated) (void)cleanupAttachURL(stagingGitURL);
    (void)cleanupAttachURL(attachJournalURL);
    if (error != nil && *error == nil) {
      *error = stagingCreateFault
          ? LPError(3104, @"Attach staging creation failed")
          : (attachError ?: LPError(3105, @"Workspace project already exists"));
    }
    return nil;
  }
  git_repository *repository = nullptr;
  git_repository_init_options options = GIT_REPOSITORY_INIT_OPTIONS_INIT;
  options.flags = GIT_REPOSITORY_INIT_BARE | GIT_REPOSITORY_INIT_MKPATH;
  options.mode = 0700;
  options.initial_head = "main";
  int initResult = git_repository_init_ext(&repository,
                                           stagingGitURL.fileSystemRepresentation,
                                           &options);
  BOOL configured = initResult == 0 && repository != nullptr &&
      git_repository_set_workdir(repository, rootPath.fileSystemRepresentation, 0) == 0;
  if (repository != nullptr) git_repository_free(repository);
  NSDictionary *attachedRoot = @{
    @"schema_version" : @1,
    @"workspace_id" : canonical[@"workspace_id"],
    @"binding_revision" : canonical[@"binding_revision"],
    @"project_id" : projectId,
  };
  BOOL bindingWritten = configured &&
      [self v2WriteBindingForRoot:attachedRoot
                         projectId:projectId
                       displayName:projectId
                             gitURL:stagingGitURL
                      rootFingerprint:fingerprint
                                error:error];
  if (!bindingWritten) {
    cleanupAttachURL(stagingGitURL);
    cleanupAttachURL(attachJournalURL);
    if (error != nil && *error == nil) *error = LPError(3104, @"Project binding cannot be saved");
    return nil;
  }
  if (self.v2AttachFaultHook != nil && self.v2AttachFaultHook(@"after_attach_staging")) {
    cleanupAttachURL(stagingGitURL);
    cleanupAttachURL(attachJournalURL);
    if (error != nil) *error = LPError(3104, @"Attach interrupted during staging");
    return nil;
  }
  NSDictionary *stagingBinding = @{
    @"schema_version" : @2,
    @"workspace_id" : attachedRoot[@"workspace_id"],
    @"binding_revision" : attachedRoot[@"binding_revision"],
    @"project_id" : projectId,
    @"display_name" : projectId,
    @"git_topology" : LPV2GitTopology,
    @"git_directory_url" : stagingGitURL,
    @"root_fingerprint_sha256" : fingerprint,
  };
  DSHLocalProjectLease *stagedLease = [self.projectAccessV2
      leaseWorkspaceRootRef:attachedRoot
               workspaceLease:workspaceLease
            workspaceBinding:stagingBinding
                         mode:DSHLocalProjectAccessModeRead
              includeMetadata:YES
                      timeout:2.0
                        error:error];
  if (stagedLease == nil) {
    cleanupAttachURL(stagingGitURL);
    cleanupAttachURL(attachJournalURL);
    return nil;
  }
  if (self.v2AttachFaultHook != nil && self.v2AttachFaultHook(@"after_attach_preflight")) {
    cleanupAttachURL(stagingGitURL);
    cleanupAttachURL(attachJournalURL);
    if (error != nil) *error = LPError(3104, @"Attach interrupted after preflight");
    return nil;
  }
  // The production project lease has pinned and verified root, worktree,
  // private gitdir and objects. Release that staging lease before rename so
  // the final production lease can acquire the same project lock; the
  // workspace descriptor remains pinned through publication and revalidation.
  stagedLease = nil;
  NSError *mutationError = nil;
  DSHLocalWorkspaceAuthorityMutationGuard *authorityGuard =
      [self.workspaceAccessV2 acquireAuthorityMutationGuard:&mutationError];
  if (authorityGuard == nil) {
    cleanupAttachURL(stagingGitURL);
    cleanupAttachURL(attachJournalURL);
    if (error != nil) {
      *error = mutationError ?: LPError(3104, @"Workspace authority is busy");
    }
    return nil;
  }
  int publishParent = open(gitParent.fileSystemRepresentation,
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  int renameResult = publishParent < 0 ? -1 : renameatx_np(
      publishParent, stagingGitURL.lastPathComponent.fileSystemRepresentation,
      publishParent, finalGitURL.lastPathComponent.fileSystemRepresentation,
      RENAME_EXCL);
  int renameFailure = renameResult == 0 ? 0 : errno;
  BOOL renameDurable = renameResult == 0 && fsync(publishParent) == 0;
  if (publishParent >= 0) close(publishParent);
  if (!renameDurable) {
    errno = renameFailure;
    if (errno == EEXIST) {
      if (error != nil) *error = LPError(3105, @"Workspace project already exists");
    } else if (error != nil) {
      *error = LPError(3104, @"Workspace project cannot be published");
    }
    cleanupAttachURL(renameResult == 0 ? finalGitURL : stagingGitURL);
    cleanupAttachURL(attachJournalURL);
    return nil;
  }
  NSMutableDictionary *publishedJournal = [attachJournal mutableCopy];
  publishedJournal[@"phase"] = @"published";
  NSData *publishedJournalData = [NSJSONSerialization
      dataWithJSONObject:publishedJournal options:NSJSONWritingSortedKeys error:nil];
  if (publishedJournalData == nil ||
      ![self v2WriteAttachJournalData:publishedJournalData
                                toURL:attachJournalURL error:&attachError]) {
    cleanupAttachURL(finalGitURL);
    cleanupAttachURL(attachJournalURL);
    if (error != nil && *error == nil) {
      *error = attachError ?: LPError(3104, @"Attach journal cannot be updated");
    }
    return nil;
  }
  if (self.v2AttachFaultHook != nil && self.v2AttachFaultHook(@"after_attach_publish")) {
    cleanupAttachURL(finalGitURL);
    cleanupAttachURL(attachJournalURL);
    if (error != nil) *error = LPError(3104, @"Attach interrupted after publication");
    return nil;
  }
  BOOL parentDurable = [self v2FsyncDirectoryAtURL:gitParent error:&attachError];
  if (!parentDurable) {
    if (error != nil) *error = LPError(3104, @"Workspace project publication is not durable");
    cleanupAttachURL(finalGitURL);
    cleanupAttachURL(attachJournalURL);
    return nil;
  }
  authorityGuard = nil;
  BOOL (^cleanupPublishedRelation)(void) = ^BOOL {
    NSError *guardError = nil;
    DSHLocalWorkspaceAuthorityMutationGuard *cleanupGuard =
        [self.workspaceAccessV2 acquireAuthorityMutationGuard:&guardError];
    if (cleanupGuard == nil) {
      if (error != nil) *error = guardError ?:
          LPError(3104, @"Published relation cleanup is blocked");
      return NO;
    }
    return cleanupAttachURL(finalGitURL);
  };
  DSHLocalWorkspaceLease *afterWorkspaceLease = [self.workspaceAccessV2
      leaseWorkspaceId:canonical[@"workspace_id"]
      expectedBindingRevision:[canonical[@"binding_revision"] unsignedIntegerValue]
      requiredCapabilities:[NSSet setWithObjects:@"read", @"write", @"git", nil]
      error:nil];
  struct stat rootAfter = {};
  if (afterWorkspaceLease == nil ||
      fstat(afterWorkspaceLease.rootDescriptor, &rootAfter) != 0 ||
      rootAfter.st_dev != rootBefore.st_dev ||
      rootAfter.st_ino != rootBefore.st_ino) {
    cleanupPublishedRelation();
    cleanupAttachURL(attachJournalURL);
    if (error != nil) *error = LPError(3106, @"Workspace root changed");
    return nil;
  }
  DSHLocalProjectLease *finalLease = [self.projectAccessV2
      leaseWorkspaceRootRef:attachedRoot
                       mode:DSHLocalProjectAccessModeRead
            includeMetadata:YES
                    timeout:2.0
                      error:error];
  NSDictionary *verifiedDescriptor = finalLease == nil
      ? nil : [self v2ProjectDescriptorForLease:finalLease root:attachedRoot];
  if (verifiedDescriptor == nil) {
    cleanupPublishedRelation();
    cleanupAttachURL(attachJournalURL);
    if (error != nil && *error == nil) *error = LPError(3102, @"Workspace project verification failed");
    return nil;
  }
  if (self.v2AttachFaultHook != nil && self.v2AttachFaultHook(@"after_attach_terminal_validation")) {
    cleanupPublishedRelation();
    cleanupAttachURL(attachJournalURL);
    if (error != nil) *error = LPError(3104, @"Attach interrupted after validation");
    return nil;
  }
  NSDictionary *result = @{ @"schema_version" : @1,
                            @"status" : @"attached",
                            @"project" : verifiedDescriptor };
  @synchronized (self) {
    self.v2AttachResults[operationId] = @{ @"root" : canonical,
                                           @"result" : result };
  }
  if (!cleanupAttachURL(attachJournalURL)) {
    @synchronized (self) {
      [self.v2AttachResults removeObjectForKey:operationId];
    }
    return nil;
  }
  return result;
}

RCT_REMAP_METHOD(list,
                 listWithResolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  dispatch_async(self.projectQueue, ^{
    NSError *error = nil;
    NSURL *root = [self projectsRootCreatingIfNeeded:NO error:&error];
    if (root == nil) {
      if ([error.domain isEqual:DSHLocalProjectAccessErrorDomain] &&
          error.code == DSHLocalProjectAccessErrorRootAbsent) {
        resolve(@{ @"schema_version": @1, @"projects": @[] });
        return;
      }
      reject(@"storage", error.localizedDescription, nil);
      return;
    }
    __attribute__((objc_precise_lifetime)) DSHLocalProjectsRootLease *rootLease =
      self.pendingRootLease;
    self.pendingRootLease = nil;
    if (![self reconcileOwnedOrphansInRootLease:rootLease]) {
      reject(@"storage", @"Project storage is unavailable", nil);
      return;
    }
    int duplicate = rootLease == nil ? -1 : openat(rootLease.descriptor, ".",
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    DIR *children = duplicate < 0 ? nullptr : fdopendir(duplicate);
    if (children == nullptr) {
      if (duplicate >= 0) close(duplicate);
      reject(@"storage", @"Project storage is unavailable", nil);
      return;
    }
    NSMutableArray<NSDictionary *> *projects = [NSMutableArray array];
    BOOL rootChanged = NO;
    struct dirent *entry = nullptr;
    while ((entry = readdir(children)) != nullptr) {
      NSString *projectId = [NSString stringWithUTF8String:entry->d_name];
      if (projectId == nil || [projectId hasPrefix:@"."]) continue;
      if (![DSHLocalProjectAccess isCanonicalProjectId:projectId]) continue;
      if (![self.projectAccess validateProjectsRootLease:rootLease error:nil]) {
        rootChanged = YES;
        break;
      }
      NSDictionary *metadata = nil;
      __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *lease = [self leaseRepositoryForId:projectId
                                                          mode:DSHLocalProjectAccessModeRead
                                                      metadata:&metadata
                                                         error:nil];
      if (![self.projectAccess validateProjectsRootLease:rootLease error:nil]) {
        rootChanged = YES;
        break;
      }
      if (lease == nil || metadata == nil) continue;
      [projects addObject:metadata];
    }
    closedir(children);
    if (rootChanged) {
      reject(@"storage", @"Project storage changed during listing", nil);
      return;
    }
    [projects sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
      NSComparisonResult date = [right[@"updated_at"] compare:left[@"updated_at"]];
      return date == NSOrderedSame ? [left[@"name"] compare:right[@"name"]] : date;
    }];
    resolve(@{ @"schema_version": @1, @"projects": projects });
  });
}

RCT_REMAP_METHOD(create,
                 createProjectWithName:(id)nameValue
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  dispatch_async(self.projectQueue, ^{
    NSError *error = nil;
    NSString *name = LPValidatedProjectName(nameValue, &error);
    NSURL *root = [self projectsRootCreatingIfNeeded:YES error:&error];
    if (name == nil || root == nil) {
      reject(@"validation", error.localizedDescription, nil);
      return;
    }
    NSString *projectId = NSUUID.UUID.UUIDString.lowercaseString;
    __attribute__((objc_precise_lifetime)) DSHLocalProjectLockToken *projectLock = [self.projectAccess
      lockProjectId:projectId
               mode:DSHLocalProjectAccessModeWrite
              error:nil];
    if (projectLock == nil) {
      reject(@"storage", @"Project storage is unavailable", nil);
      return;
    }
    NSURL *staging = [self createStagingDirectoryAtRoot:root projectId:projectId error:&error];
    if (staging == nil) {
      reject(@"storage", error.localizedDescription, nil);
      return;
    }
    NSURL *repoURL = [staging URLByAppendingPathComponent:@"repo" isDirectory:YES];
    git_repository_init_options options = GIT_REPOSITORY_INIT_OPTIONS_INIT;
    options.flags = GIT_REPOSITORY_INIT_NO_REINIT | GIT_REPOSITORY_INIT_MKDIR;
    options.mode = 0700;
    options.initial_head = "main";
    git_repository *repository = nullptr;
    BOOL stagingBoundBefore = [self stagingEntryIsExactForProjectId:projectId
                                                               error:&error];
    int result = stagingBoundBefore
      ? git_repository_init_ext(&repository, repoURL.fileSystemRepresentation,
                                &options)
      : -1;
    BOOL stagingBoundAfter = result == 0 &&
      [self stagingEntryIsExactForProjectId:projectId error:&error];
    NSString *now = LPNow();
    NSDictionary *stored = @{
      @"schema_version": @1,
      @"name": name,
      @"created_at": now,
      @"updated_at": now,
      @"origin_url": NSNull.null,
    };
    BOOL success = stagingBoundAfter && repository != nullptr
      && LPDirectoryIsSafe(repoURL)
      && LPDirectoryIsSafe([repoURL URLByAppendingPathComponent:@".git" isDirectory:YES])
      && [self writeMetadata:stored atProjectDirectory:staging
                   projectId:projectId writeToken:projectLock error:&error]
      && [self publishStagingDirectory:staging atRoot:root projectId:projectId error:&error];
    if (repository != nullptr) git_repository_free(repository);
    if (!success) {
      [self removeVisibleStagingDirectory:staging projectId:projectId];
      reject(@"git", error.localizedDescription ?: @"Project cannot be created", nil);
      return;
    }
    projectLock = nil;
    NSDictionary *metadata = nil;
    DSHLocalProjectLease *publishedLease = [self leaseRepositoryForId:projectId
                                                                 mode:DSHLocalProjectAccessModeRead
                                                             metadata:&metadata
                                                                error:&error];
    if (publishedLease == nil || metadata == nil) {
      reject(@"storage", error.localizedDescription, nil);
      return;
    }
    resolve(metadata);
  });
}

RCT_REMAP_METHOD(startClone,
                 startCloneURL:(id)urlValue name:(id)nameValue options:(id)optionsValue
                 resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
  NSError *error = nil;
  NSString *proxyURL = LPValidatedHTTPSProxyURL(optionsValue, &error);
  NSString *sshProfileId = error == nil ? LPValidatedSSHProfileId(optionsValue, &error) : nil;
  NSURL *remoteURL = error == nil ? LPValidatedRemoteURL(urlValue, &error) : nil;
  NSString *name = nil;
  if (nameValue == nil || nameValue == NSNull.null) {
    NSString *derived = remoteURL.path.lastPathComponent.stringByRemovingPercentEncoding;
    if ([derived.lowercaseString hasSuffix:@".git"] && derived.length > 4)
      derived = [derived substringToIndex:derived.length - 4];
    name = LPValidatedProjectName(derived, nil) ?: @"Repository";
  } else name = LPValidatedProjectName(nameValue, &error);
  if (error != nil || remoteURL == nil || name == nil) {
    reject(@"validation", @"Invalid public clone request", nil);
    return;
  }
  LPCloneOperation *operation = [[LPCloneOperation alloc] init];
  operation.name = name;
  operation.sshProfileId = sshProfileId;
  @synchronized (self) {
    if (self.cloneOperation != nil && ![self.cloneOperation terminal]) {
      reject(@"busy", @"A clone is already running", nil);
      return;
    }
    self.cloneOperation = operation;
  }
  resolve([operation snapshot]);
  dispatch_async(self.projectQueue, ^{
    NSError *failure = nil;
    NSDictionary *project = [self clonePublicRepositoryAtURL:remoteURL name:name
      proxyURL:proxyURL operation:operation sshProfileId:operation.sshProfileId error:&failure];
    @synchronized (operation) {
      operation.project = project;
      operation.phase = project != nil ? @"succeeded"
        : operation.cancelRequested ? @"cancelled" : @"failed";
      operation.failureCode = project != nil || operation.cancelRequested ? nil
        : failure.code == 3010 ? @"timeout" : @"git";
    }
  });
}

RCT_REMAP_METHOD(cloneStatus,
                 cloneStatusForOperation:(id)operationIdValue
                 resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
  LPCloneOperation *operation = nil;
  @synchronized (self) { operation = self.cloneOperation; }
  if (operationIdValue != nil && operationIdValue != NSNull.null &&
      ![operation.operationId isEqual:LPString(operationIdValue)]) {
    reject(@"state", @"Clone operation is unavailable", nil);
    return;
  }
  resolve(operation == nil ? NSNull.null : [operation snapshot]);
}

RCT_REMAP_METHOD(cancelClone,
                 cancelCloneOperation:(id)operationIdValue
                 resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
  LPCloneOperation *operation = nil;
  @synchronized (self) { operation = self.cloneOperation; }
  if (operation == nil || ![operation.operationId isEqual:LPString(operationIdValue)]) {
    reject(@"state", @"Clone operation is unavailable", nil);
    return;
  }
  @synchronized (operation) {
    // Once publication starts, report its real result; never claim cancellation.
    if (![operation terminal] && ![operation.phase isEqual:@"publishing"])
      operation.cancelRequested = YES;
    resolve([operation snapshot]);
  }
}

RCT_REMAP_METHOD(clone,
                 clonePublicRepository:(id)urlValue
                 name:(id)nameValue
                 options:(id)optionsValue
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  dispatch_async(self.projectQueue, ^{
    NSError *error = nil;
    __attribute__((objc_precise_lifetime)) NSString *proxyURL =
      LPValidatedHTTPSProxyURL(optionsValue, &error);
    NSString *sshProfileId = error == nil ? LPValidatedSSHProfileId(optionsValue, &error) : nil;
    if (error != nil) {
      reject(@"validation", error.localizedDescription, nil);
      return;
    }
    NSURL *remoteURL = LPValidatedRemoteURL(urlValue, &error);
    NSString *name = nil;
    if (nameValue == nil || nameValue == NSNull.null) {
      NSString *derived = remoteURL.path.lastPathComponent.stringByRemovingPercentEncoding;
      if ([derived.lowercaseString hasSuffix:@".git"] && derived.length > 4) {
        derived = [derived substringToIndex:derived.length - 4];
      }
      name = LPValidatedProjectName(derived, nil) ?: @"Repository";
    } else {
      name = LPValidatedProjectName(nameValue, &error);
    }
    if (remoteURL == nil || name == nil) {
      reject(@"validation", error.localizedDescription, nil);
      return;
    }
    NSDictionary *metadata = [self clonePublicRepositoryAtURL:remoteURL
                                                         name:name
                                                     proxyURL:proxyURL
                                                   operation:nil
                                                sshProfileId:sshProfileId
                                                        error:&error];
    if (metadata == nil) {
      reject(@"git", error.localizedDescription ?: @"Public repository cannot be cloned", nil);
      return;
    }
    resolve(metadata);
  });
}

RCT_REMAP_METHOD(fetch,
                 fetchForProject:(id)projectIdValue
                 sshProfileId:(id)profileIdValue
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  dispatch_async(self.projectQueue, ^{
    NSError *error = nil;
    NSString *projectId = LPString(projectIdValue);
    NSString *profileId = LPString(profileIdValue);
    __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *lease =
        [self leaseRepositoryForId:projectId mode:DSHLocalProjectAccessModeWrite
                           metadata:nil error:&error];
    if (lease == nil) {
      reject(@"project", error.localizedDescription ?: @"Project is unavailable", nil);
      return;
    }
    NSString *origin = [self originURLForRepository:lease.repository error:&error];
    NSDictionary *ssh = DSHGitSSHValidatedRemote(origin, nil);
    if (ssh != nil && profileId.length == 0) {
      reject(@"credential", @"An SSH credential profile is required", nil);
      return;
    }
    void *auth = nullptr;
    if (ssh != nil) {
      auth = DSHGitSSHAuthContextCreate(profileId, ssh[@"host"],
          [ssh[@"port"] integerValue], ssh[@"username"], &error);
      if (auth == nullptr) {
        reject(@"credential", error.localizedDescription ?: @"SSH credential is unavailable", nil);
        return;
      }
    }
    git_remote *remote = nullptr;
    int result = git_remote_lookup(&remote, lease.repository, LPRemoteName.UTF8String);
    git_fetch_options options = GIT_FETCH_OPTIONS_INIT;
    if (auth != nullptr) {
      options.callbacks.credentials = DSHGitSSHCredentialCallback;
      options.callbacks.certificate_check = DSHGitSSHCertificateCallback;
      options.callbacks.payload = auth;
    }
    git_libgit2_opts(GIT_OPT_SET_SERVER_CONNECT_TIMEOUT,
                     LPCloneConnectTimeoutMilliseconds);
    git_libgit2_opts(GIT_OPT_SET_SERVER_TIMEOUT, LPCloneIdleTimeoutMilliseconds);
    if (result == 0) result = git_remote_fetch(remote, nullptr, &options, nullptr);
    if (remote != nullptr) git_remote_free(remote);
    if (auth != nullptr) DSHGitSSHAuthContextFree(auth);
    if (result < 0) {
      reject(@"git", @"Git fetch failed", nil);
      return;
    }
    resolve(@{ @"schema_version": @1, @"project_id": projectId,
               @"remote": LPRemoteName, @"fetched": @YES });
  });
}

/// Runs the complete staged, validated public clone. Callers must serialize
/// access through the project queue; used by the RCT clone method and by the
/// env-gated test fixture driver.
- (NSDictionary *)clonePublicRepositoryAtURL:(NSURL *)remoteURL
                                        name:(NSString *)name
                                    proxyURL:(NSString *)proxyURL
                                        error:(NSError **)error {
  return [self clonePublicRepositoryAtURL:remoteURL name:name proxyURL:proxyURL
    operation:nil sshProfileId:nil error:error];
}

- (NSDictionary *)clonePublicRepositoryAtURL:(NSURL *)remoteURL
                                        name:(NSString *)name
                                    proxyURL:(NSString *)proxyURL
                                   operation:(LPCloneOperation *)operation
                               sshProfileId:(NSString *)sshProfileId
                                       error:(NSError **)error {
  if (self.clonePhaseHook != nil) self.clonePhaseHook(@"queued");
  if ([operation shouldCancel]) return nil;
  [operation updatePhase:@"connecting"];
  NSURL *root = [self projectsRootCreatingIfNeeded:YES error:error];
  if (root == nil) return nil;
  NSString *projectId = NSUUID.UUID.UUIDString.lowercaseString;
  __attribute__((objc_precise_lifetime)) DSHLocalProjectLockToken *projectLock = [self.projectAccess
    lockProjectId:projectId
             mode:DSHLocalProjectAccessModeWrite
            error:nil];
  if (projectLock == nil) {
    if (error != nil) *error = LPError(3007, @"Project is unavailable");
    return nil;
  }
  NSURL *staging = [self createStagingDirectoryAtRoot:root projectId:projectId error:error];
  if (staging == nil) return nil;
  NSURL *repoURL = [staging URLByAppendingPathComponent:@"repo" isDirectory:YES];
  git_clone_options options = GIT_CLONE_OPTIONS_INIT;
  // Never over a file the person keeps out of Git; see the fast-forward.
  options.checkout_opts.checkout_strategy =
      GIT_CHECKOUT_SAFE | GIT_CHECKOUT_DONT_OVERWRITE_IGNORED;
  options.fetch_opts.follow_redirects = GIT_REMOTE_REDIRECT_NONE;
  options.fetch_opts.proxy_opts.type = proxyURL.length > 0
    ? GIT_PROXY_SPECIFIED : GIT_PROXY_NONE;
  options.fetch_opts.proxy_opts.url = proxyURL.UTF8String;
  options.fetch_opts.callbacks.credentials = LPPublicCloneCredentialCallback;
  // Bound every phase: connecting, waiting on a silent server, and the whole
  // operation.  The credential callback ignores its payload, so the budget can
  // ride along on the shared callbacks payload.
  LPCloneBudget budget = {
    .deadline = NSProcessInfo.processInfo.systemUptime + LPCloneOverallBudgetSeconds,
    .exceeded = false,
    .operation = operation,
    .sshContext = nullptr,
  };
  NSDictionary *sshRemote = DSHGitSSHValidatedRemote(remoteURL.absoluteString, nil);
  if (sshRemote != nil && sshProfileId.length > 0) {
    budget.sshContext = DSHGitSSHAuthContextCreate(
        sshProfileId, sshRemote[@"host"], [sshRemote[@"port"] integerValue],
        sshRemote[@"username"], error);
    if (budget.sshContext == nullptr) {
      [self removeVisibleStagingDirectory:staging projectId:projectId];
      return nil;
    }
    options.fetch_opts.callbacks.certificate_check = LPCloneCertificateCallback;
  } else if (sshRemote != nil) {
    if (error) *error = LPError(3021, @"An SSH credential profile is required");
    [self removeVisibleStagingDirectory:staging projectId:projectId];
    return nil;
  }
  options.fetch_opts.callbacks.transfer_progress = LPCloneTransferProgress;
  options.fetch_opts.callbacks.sideband_progress = LPCloneSidebandProgress;
  options.fetch_opts.callbacks.payload = &budget;
  options.checkout_opts.notify_flags = GIT_CHECKOUT_NOTIFY_ALL;
  options.checkout_opts.notify_cb = LPCloneCheckoutNotify;
  options.checkout_opts.notify_payload = &budget;
  options.checkout_opts.progress_cb = LPCloneCheckoutProgress;
  options.checkout_opts.progress_payload = &budget;
  git_libgit2_opts(GIT_OPT_SET_SERVER_CONNECT_TIMEOUT,
                   LPCloneConnectTimeoutMilliseconds);
  git_libgit2_opts(GIT_OPT_SET_SERVER_TIMEOUT, LPCloneIdleTimeoutMilliseconds);
  git_repository *repository = nullptr;
  BOOL stagingBoundBefore = [self stagingEntryIsExactForProjectId:projectId
                                                             error:error];
  if (self.clonePhaseHook != nil) self.clonePhaseHook(@"before_transfer");
  int result = stagingBoundBefore && LPCloneBudgetExpired(&budget) == 0
    ? git_clone(&repository, remoteURL.absoluteString.UTF8String,
                repoURL.fileSystemRepresentation, &options)
    : -1;
  if (budget.sshContext != nullptr) {
    DSHGitSSHAuthContextFree(budget.sshContext);
    budget.sshContext = nullptr;
  }
  BOOL stagingBoundAfter = result == 0 &&
    [self stagingEntryIsExactForProjectId:projectId error:error];
  NSString *cloneFailure = nil;
  if (result < 0) {
    cloneFailure = budget.exceeded
      ? [NSString stringWithFormat:
          @"Public clone stopped after %.0f seconds without completing",
          LPCloneOverallBudgetSeconds]
      : LPSanitizedGitFailure(@"Public clone transport", result);
  }
  [operation updatePhase:@"validating"];
  BOOL checkoutSafe = NO;
  if (stagingBoundAfter && repository != nullptr && LPDirectoryIsSafe(repoURL)
    && LPDirectoryIsSafe([repoURL URLByAppendingPathComponent:@".git" isDirectory:YES])
    && ![self repositoryContainsGitlink:repository]) {
    int repoDescriptor = open(repoURL.fileSystemRepresentation,
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    NSUInteger entryCount = 0;
    checkoutSafe = repoDescriptor >= 0
      && LPValidateCheckoutTree(repoDescriptor, 0, &entryCount);
    if (repoDescriptor >= 0) close(repoDescriptor);
    if (!checkoutSafe) cloneFailure = @"Public clone validation failed (code 1, class checkout/20)";
  } else if (stagingBoundAfter && repository != nullptr
    && [self repositoryContainsGitlink:repository]) {
    cloneFailure = @"Public clone validation failed (code 2, class submodule/17)";
  }
  NSString *storedOrigin = !stagingBoundAfter || repository == nullptr ? nil
    : [self originURLForRepository:repository error:nil];
  if (stagingBoundAfter && repository != nullptr
    && ![storedOrigin isEqualToString:remoteURL.absoluteString]) {
    checkoutSafe = NO;
    cloneFailure = @"Public clone validation failed (code 3, class config/7)";
  }
  NSString *now = LPNow();
  NSDictionary *stored = @{
    @"schema_version": @1,
    @"name": name,
    @"created_at": now,
    @"updated_at": now,
    @"origin_url": remoteURL.absoluteString,
  };
  if (self.clonePhaseHook != nil) self.clonePhaseHook(@"before_publish");
  BOOL success = checkoutSafe && LPCloneBudgetExpired(&budget) == 0
    && [self writeMetadata:stored atProjectDirectory:staging
                 projectId:projectId writeToken:projectLock error:error]
    && (operation == nil || [operation beginPublication])
    && [self publishStagingDirectory:staging atRoot:root projectId:projectId error:error];
  if (repository != nullptr) git_repository_free(repository);
  if (!success) {
    [self removeVisibleStagingDirectory:staging projectId:projectId];
    if (error != nil && *error == nil) {
      *error = LPError(budget.exceeded ? 3010 : 3009, cloneFailure ?: @"Public repository cannot be cloned");
    }
    return nil;
  }
  projectLock = nil;
  NSDictionary *metadata = nil;
  DSHLocalProjectLease *publishedLease = [self leaseRepositoryForId:projectId
                                                               mode:DSHLocalProjectAccessModeRead
                                                           metadata:&metadata
                                                              error:error];
  if (publishedLease == nil || metadata == nil) {
    if (error != nil && *error == nil) *error = LPError(3007, @"Project is unavailable");
    return nil;
  }
  return metadata;
}

RCT_REMAP_METHOD(status,
                 statusForProject:(id)projectIdValue
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  dispatch_async(self.projectQueue, ^{
    NSError *error = nil;
    NSString *projectId = LPString(projectIdValue);
    __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *lease = [self leaseRepositoryForId:projectId
                                                        mode:DSHLocalProjectAccessModeRead
                                                    metadata:nil
                                                       error:&error];
    if (lease == nil) {
      reject(@"project", error.localizedDescription, nil);
      return;
    }
    git_repository *repository = lease.repository;
    NSDictionary *status = [self statusForRepository:repository projectId:projectId error:&error];
    if (status == nil) {
      reject(@"git", error.localizedDescription, nil);
      return;
    }
    resolve(status);
  });
}

- (NSDictionary *)diffForRepository:(git_repository *)repository
                           projectId:(NSString *)projectId
                              staged:(BOOL)staged
                        contextLines:(NSUInteger)contextLines
                               error:(NSError **)error {
  return [self diffForRepository:repository projectId:projectId staged:staged
    contextLines:contextLines pageOffset:nil expectedSnapshot:nil error:error];
}

- (NSDictionary *)diffForRepository:(git_repository *)repository
                           projectId:(NSString *)projectId
                              staged:(BOOL)staged
                        contextLines:(NSUInteger)contextLines
                          pageOffset:(NSNumber *)pageOffset
                    expectedSnapshot:(NSString *)expectedSnapshot
                               error:(NSError **)error {
  BOOL paged = pageOffset != nil;
  NSUInteger offset = pageOffset.unsignedIntegerValue;
  const NSUInteger pageLimit = 64 * 1024;
  const NSUInteger reviewLimit = 64 * 1024 * 1024;
  CC_SHA256_CTX digest;
  CC_SHA256_Init(&digest);
  CC_SHA256_Update(&digest, staged ? "staged" : "unstaged", staged ? 6 : 8);
  NSMutableArray<NSString *> *omitted = [NSMutableArray array];
  NSUInteger totalBytes = 0;
  BOOL pageClosed = NO;
  git_diff_options options = GIT_DIFF_OPTIONS_INIT;
  options.context_lines = (uint32_t)contextLines;
  options.max_size = 4 * 1024 * 1024;
  options.flags = GIT_DIFF_INCLUDE_TYPECHANGE | GIT_DIFF_INCLUDE_TYPECHANGE_TREES;
  if (!staged) {
    options.flags |= GIT_DIFF_INCLUDE_UNTRACKED
      | GIT_DIFF_RECURSE_UNTRACKED_DIRS
      | GIT_DIFF_SHOW_UNTRACKED_CONTENT;
  }
  git_index *index = nullptr;
  if (git_repository_index(&index, repository) < 0 || index == nullptr) {
    if (error != nil) *error = LPError(3023, @"Repository index is unavailable");
    return nil;
  }
  git_tree *headTree = nullptr;
  int headTreeResult = LPHeadTree(&headTree, repository);
  if (headTreeResult != 0 && headTreeResult != GIT_EUNBORNBRANCH
    && headTreeResult != GIT_ENOTFOUND) {
    git_index_free(index);
    if (error != nil) *error = LPError(3024, @"Repository history is unavailable");
    return nil;
  }
  git_diff *diff = nullptr;
  int result = staged
    ? git_diff_tree_to_index(&diff, repository, headTree, index, &options)
    : git_diff_index_to_workdir(&diff, repository, index, &options);
  if (headTree != nullptr) git_tree_free(headTree);
  git_index_free(index);
  if (result < 0 || diff == nullptr) {
    if (diff != nullptr) git_diff_free(diff);
    if (error != nil) *error = LPError(3025, @"Repository diff is unavailable");
    return nil;
  }
  size_t count = git_diff_num_deltas(diff);
  if (count > LPMaxDiffFiles) {
    git_diff_free(diff);
    if (error != nil) *error = LPError(3026, @"Repository diff contains too many files");
    return nil;
  }
  NSMutableArray<NSDictionary *> *files = [NSMutableArray arrayWithCapacity:count];
  NSMutableString *patchText = [NSMutableString string];
  NSUInteger usedBytes = 0;
  BOOL truncated = NO;
  for (size_t item = 0; item < count; item += 1) {
    const git_diff_delta *delta = git_diff_get_delta(diff, item);
    const char *rawPath = delta == nullptr ? nullptr
      : (delta->new_file.path ?: delta->old_file.path);
    NSString *path = rawPath == nullptr ? nil : [NSString stringWithUTF8String:rawPath];
    if (delta == nullptr || path == nil || !LPIsSafeRepositoryPath(path)) {
      git_diff_free(diff);
      if (error != nil) *error = LPError(3021, @"Repository contains an unsafe path");
      return nil;
    }
    git_patch *patch = nullptr;
    size_t context = 0;
    size_t additions = 0;
    size_t deletions = 0;
    if (git_patch_from_diff(&patch, diff, item) == 0 && patch != nullptr) {
      git_patch_line_stats(&context, &additions, &deletions, patch);
    }
    [files addObject:@{
      @"path": path,
      @"status": LPDiffStatusName(delta->status),
      @"additions": @(additions),
      @"deletions": @(deletions),
    }];
    if (paged && (delta->flags & GIT_DIFF_FLAG_BINARY)) [omitted addObject:path];
    if (patch != nullptr && (paged || !truncated)) {
      git_buf buffer = GIT_BUF_INIT;
      if (git_patch_to_buf(&buffer, patch) == 0 && buffer.ptr != nullptr && buffer.size > 0) {
        NSString *text = [[NSString alloc] initWithBytes:buffer.ptr
                                                  length:buffer.size
                                                encoding:NSUTF8StringEncoding];
        if (text == nil) {
          if (paged && ![omitted containsObject:path]) [omitted addObject:path];
          text = [NSString stringWithFormat:@"Binary or non-UTF-8 diff omitted: %@\n", path];
        }
        NSData *encoded = [text dataUsingEncoding:NSUTF8StringEncoding];
        if (paged) {
          CC_SHA256_Update(&digest, encoded.bytes, (CC_LONG)encoded.length);
          CC_SHA256_Update(&digest, delta->old_file.id.id, GIT_OID_SHA1_SIZE);
          CC_SHA256_Update(&digest, delta->new_file.id.id, GIT_OID_SHA1_SIZE);
          if (encoded.length > reviewLimit - totalBytes) {
            git_buf_dispose(&buffer); git_patch_free(patch); git_diff_free(diff);
            if (error != nil) *error = LPError(3042, @"Diff exceeds the 64 MiB review limit");
            return nil;
          }
          NSUInteger start = offset > totalBytes ? MIN(offset - totalBytes, encoded.length) : 0;
          NSUInteger take = pageClosed ? 0 : MIN(encoded.length - start, pageLimit - usedBytes);
          if (take > 0) {
            // Reject an offset inside a UTF-8 code point before trying suffixes.
            if ((((const uint8_t *)encoded.bytes)[start] & 0xC0) == 0x80) {
              git_buf_dispose(&buffer); git_patch_free(patch); git_diff_free(diff);
              if (error != nil) *error = LPError(3040, @"Diff page offset is invalid");
              return nil;
            }
            NSString *piece = nil;
            while (take > 0 && piece == nil) {
              piece = [[NSString alloc] initWithBytes:(const uint8_t *)encoded.bytes + start
                length:take encoding:NSUTF8StringEncoding];
              if (piece == nil) take -= 1;
            }
            if (piece == nil) {
              git_buf_dispose(&buffer); git_patch_free(patch); git_diff_free(diff);
              if (error != nil) *error = LPError(3040, @"Diff page offset is invalid");
              return nil;
            }
            [patchText appendString:piece];
            usedBytes += take;
            if (start + take < encoded.length) pageClosed = YES;
          }
          totalBytes += encoded.length;
        } else {
        NSUInteger remaining = LPMaxDiffBytes - usedBytes;
        if (encoded.length <= remaining) {
          [patchText appendString:text];
          usedBytes += encoded.length;
        } else {
          NSUInteger take = remaining;
          NSString *clipped = nil;
          while (take > 0 && clipped == nil) {
            NSData *prefix = [encoded subdataWithRange:NSMakeRange(0, take)];
            clipped = [[NSString alloc] initWithData:prefix encoding:NSUTF8StringEncoding];
            if (clipped == nil) take -= 1;
          }
          if (clipped != nil) [patchText appendString:clipped];
          usedBytes = LPMaxDiffBytes;
          truncated = YES;
        }
        }
      } else if (paged) {
        git_buf_dispose(&buffer); git_patch_free(patch); git_diff_free(diff);
        if (error != nil) *error = LPError(3025, @"Repository diff text is unavailable");
        return nil;
      }
      git_buf_dispose(&buffer);
    }
    if (paged && patch == nullptr) {
      git_diff_free(diff);
      if (error != nil) *error = LPError(3025, @"Repository diff text is unavailable");
      return nil;
    }
    if (patch != nullptr) git_patch_free(patch);
  }
  git_diff_free(diff);
  if (paged) {
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(bytes, &digest);
    NSMutableString *snapshot = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(bytes); i++) [snapshot appendFormat:@"%02x", bytes[i]];
    if (expectedSnapshot != nil && ![snapshot isEqual:expectedSnapshot]) {
      if (error != nil) *error = LPError(3041, @"Diff changed; restart the review");
      return nil;
    }
    if (offset > totalBytes) {
      if (error != nil) *error = LPError(3040, @"Diff page offset is invalid");
      return nil;
    }
    BOOL more = offset + usedBytes < totalBytes;
    return @{@"schema_version": @1, @"project_id": projectId, @"staged": @(staged),
      @"truncated": @(more), @"patch": patchText, @"files": files,
      @"page_offset": @(offset), @"next_offset": more ? @(offset + usedBytes) : NSNull.null,
      @"snapshot_id": snapshot, @"omitted_paths": omitted};
  }
  return @{
    @"schema_version": @1,
    @"project_id": projectId,
    @"staged": @(staged),
    @"truncated": @(truncated),
    @"patch": patchText,
    @"files": files,
  };
}

RCT_REMAP_METHOD(diff,
                 diffForProject:(id)projectIdValue
                 staged:(BOOL)staged
                 contextLines:(nonnull NSNumber *)contextLinesValue
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  dispatch_async(self.projectQueue, ^{
    NSError *error = nil;
    NSString *projectId = LPString(projectIdValue);
    NSInteger rawContext = contextLinesValue.integerValue;
    if (rawContext < 0 || rawContext > 20) {
      reject(@"validation", @"Diff context is invalid", nil);
      return;
    }
    __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *lease = [self leaseRepositoryForId:projectId
                                                        mode:DSHLocalProjectAccessModeRead
                                                    metadata:nil
                                                       error:&error];
    if (lease == nil) {
      reject(@"project", error.localizedDescription, nil);
      return;
    }
    git_repository *repository = lease.repository;
    NSDictionary *diff = [self diffForRepository:repository
                                       projectId:projectId
                                          staged:staged
                                    contextLines:(NSUInteger)rawContext
                                           error:&error];
    if (diff == nil) {
      reject(@"git", error.localizedDescription, nil);
      return;
    }
    resolve(diff);
  });
}

RCT_REMAP_METHOD(diffPage,
                 diffPageForProject:(id)projectIdValue staged:(BOOL)staged
                 offset:(id)offsetValue snapshot:(id)snapshotValue
                 resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
  BOOL validOffset = [offsetValue isKindOfClass:NSNumber.class] &&
    CFGetTypeID((__bridge CFTypeRef)offsetValue) != CFBooleanGetTypeID() &&
    isfinite([offsetValue doubleValue]) && [offsetValue doubleValue] >= 0 &&
    [offsetValue doubleValue] <= 64 * 1024 * 1024 &&
    floor([offsetValue doubleValue]) == [offsetValue doubleValue];
  NSString *snapshot = snapshotValue == NSNull.null ? nil : LPString(snapshotValue);
  BOOL validSnapshot = snapshot == nil ? snapshotValue == NSNull.null || snapshotValue == nil
    : [snapshot rangeOfString:@"^[0-9a-f]{64}$" options:NSRegularExpressionSearch].location != NSNotFound;
  if (!validOffset || !validSnapshot || ([offsetValue unsignedIntegerValue] > 0 && snapshot == nil)) {
    reject(@"validation", @"Diff page request is invalid", nil); return;
  }
  dispatch_async(self.projectQueue, ^{
    NSError *error = nil;
    NSString *projectId = LPString(projectIdValue);
    __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *lease =
      [self leaseRepositoryForId:projectId mode:DSHLocalProjectAccessModeRead metadata:nil error:&error];
    NSDictionary *page = lease == nil ? nil : [self diffForRepository:lease.repository
      projectId:projectId staged:staged contextLines:3 pageOffset:offsetValue
      expectedSnapshot:snapshot error:&error];
    if (page == nil) {
      reject(error.code == 3041 ? @"diff_changed" : @"git", error.localizedDescription, nil);
      return;
    }
    resolve(page);
  });
}

RCT_REMAP_METHOD(stageAll,
                 stageAllForProject:(id)projectIdValue
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  dispatch_async(self.projectQueue, ^{
    NSError *error = nil;
    NSString *projectId = LPString(projectIdValue);
    __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *lease = [self leaseRepositoryForId:projectId
                                                        mode:DSHLocalProjectAccessModeWrite
                                                    metadata:nil
                                                       error:&error];
    if (lease == nil) {
      reject(@"project", error.localizedDescription, nil);
      return;
    }
    git_repository *repository = lease.repository;
    git_index *index = nullptr;
    int result = git_repository_index(&index, repository);
    char wildcard[] = "*";
    char *patterns[] = { wildcard };
    git_strarray pathspec = { patterns, 1 };
    if (result == 0) {
      result = git_index_add_all(index, &pathspec, GIT_INDEX_ADD_DEFAULT, nullptr, nullptr);
    }
    if (result == 0) result = git_index_write(index);
    if (index != nullptr) git_index_free(index);
    NSDictionary *status = result == 0
      ? [self statusForRepository:repository projectId:projectId error:&error] : nil;
    if (result < 0 || status == nil) {
      reject(@"git", error.localizedDescription ?: @"Repository changes cannot be staged", nil);
      return;
    }
    resolve(status);
  });
}

static NSString *LPValidatedCommitMessage(id value, NSError **error) {
  NSString *message = LPString(value);
  NSString *trimmed = [message stringByTrimmingCharactersInSet:
    NSCharacterSet.whitespaceAndNewlineCharacterSet];
  NSUInteger bytes = [message lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
  const char *utf8 = message.UTF8String;
  if (message == nil || trimmed.length == 0 || bytes > LPMaxCommitMessageBytes
    || utf8 == nullptr || strlen(utf8) != bytes) {
    if (error != nil) *error = LPError(3027, @"Commit message is invalid");
    return nil;
  }
  return message;
}

static NSString *LPValidatedAuthorName(id value, NSError **error) {
  NSString *name = [LPString(value) stringByTrimmingCharactersInSet:
    NSCharacterSet.whitespaceAndNewlineCharacterSet];
  NSUInteger bytes = [name lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
  if (name == nil || bytes == 0 || bytes > 255 || LPHasControlCharacter(name)
    || [name containsString:@"<"] || [name containsString:@">"]) {
    if (error != nil) *error = LPError(3028, @"Commit author is invalid");
    return nil;
  }
  return name;
}

static NSString *LPValidatedAuthorEmail(id value, NSError **error) {
  NSString *email = [LPString(value) stringByTrimmingCharactersInSet:
    NSCharacterSet.whitespaceAndNewlineCharacterSet];
  NSArray<NSString *> *parts = [email componentsSeparatedByString:@"@"];
  NSUInteger bytes = [email lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
  if (email == nil || bytes < 3 || bytes > 320 || parts.count != 2
    || [parts[0] length] == 0 || [parts[1] length] == 0
    || LPHasControlCharacter(email)
    || [email rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location
      != NSNotFound || [email containsString:@"<"] || [email containsString:@">"]) {
    if (error != nil) *error = LPError(3029, @"Commit email is invalid");
    return nil;
  }
  return email;
}

RCT_REMAP_METHOD(commit,
                 commitProject:(id)projectIdValue
                 message:(id)messageValue
                 authorName:(id)authorNameValue
                 authorEmail:(id)authorEmailValue
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  dispatch_async(self.projectQueue, ^{
    NSError *error = nil;
    NSString *projectId = LPString(projectIdValue);
    NSString *message = LPValidatedCommitMessage(messageValue, &error);
    NSString *authorName = LPValidatedAuthorName(authorNameValue, &error);
    NSString *authorEmail = LPValidatedAuthorEmail(authorEmailValue, &error);
    if (message == nil || authorName == nil || authorEmail == nil) {
      reject(@"validation", error.localizedDescription, nil);
      return;
    }
    NSDictionary *metadata = nil;
    __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *lease = [self leaseRepositoryForId:projectId
                                                        mode:DSHLocalProjectAccessModeWrite
                                                    metadata:&metadata
                                                       error:&error];
    if (lease == nil) {
      reject(@"project", error.localizedDescription, nil);
      return;
    }
    git_repository *repository = lease.repository;
    git_index *index = nullptr;
    git_tree *tree = nullptr;
    git_commit *parent = nullptr;
    git_signature *signature = nullptr;
    git_oid treeOid = {};
    git_oid commitOid = {};
    int result = git_repository_index(&index, repository);
    if (result == 0 && git_index_has_conflicts(index)) result = GIT_EUNMERGED;
    if (result == 0) result = git_index_write_tree(&treeOid, index);
    if (result == 0) result = git_tree_lookup(&tree, repository, &treeOid);
    git_reference *head = nullptr;
    int headResult = result == 0 ? git_repository_head(&head, repository) : result;
    if (headResult == 0 && head != nullptr) {
      const git_oid *parentOid = git_reference_target(head);
      if (parentOid == nullptr || git_commit_lookup(&parent, repository, parentOid) < 0) {
        result = -1;
      } else if (git_oid_equal(&treeOid, git_commit_tree_id(parent))) {
        result = GIT_EUNCHANGED;
      }
    } else if (headResult == GIT_EUNBORNBRANCH || headResult == GIT_ENOTFOUND) {
      if (git_index_entrycount(index) == 0) result = GIT_EUNCHANGED;
      else result = 0;
    } else if (headResult < 0) {
      result = headResult;
    }
    if (head != nullptr) git_reference_free(head);
    if (result == 0) result = git_signature_now(
      &signature, authorName.UTF8String, authorEmail.UTF8String);
    const git_commit *parents[] = { parent };
    if (result == 0) {
      result = git_commit_create(&commitOid, repository, "HEAD", signature, signature,
        "UTF-8", message.UTF8String, tree, parent == nullptr ? 0 : 1, parents);
    }
    if (signature != nullptr) git_signature_free(signature);
    if (parent != nullptr) git_commit_free(parent);
    if (tree != nullptr) git_tree_free(tree);
    if (index != nullptr) git_index_free(index);
    if (result != 0) {
      NSString *reason = result == GIT_EUNCHANGED ? @"There are no staged changes"
        : result == GIT_EUNMERGED ? @"Repository has unresolved conflicts"
        : @"Commit cannot be created";
      reject(@"git", reason, nil);
      return;
    }
    [self updatedMetadata:metadata
                originURL:(metadata[@"origin_url"] == NSNull.null ? nil : metadata[@"origin_url"])
                    lease:lease
                    error:nil];
    NSString *summary = [[message componentsSeparatedByCharactersInSet:
      NSCharacterSet.newlineCharacterSet] firstObject];
    resolve(@{
      @"schema_version": @1,
      @"project_id": projectId,
      @"oid": LPOidString(&commitOid),
      @"summary": summary ?: @"",
      @"committed_at": LPNow(),
    });
  });
}

RCT_REMAP_METHOD(setRemote,
                 setRemoteForProject:(id)projectIdValue
                 url:(id)urlValue
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  dispatch_async(self.projectQueue, ^{
    NSError *error = nil;
    NSString *projectId = LPString(projectIdValue);
    NSURL *remoteURL = LPValidatedRemoteURL(urlValue, &error);
    if (remoteURL == nil) {
      reject(@"validation", error.localizedDescription, nil);
      return;
    }
    NSDictionary *metadata = nil;
    __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *lease = [self leaseRepositoryForId:projectId
                                                        mode:DSHLocalProjectAccessModeWrite
                                                    metadata:&metadata
                                                       error:&error];
    if (lease == nil) {
      reject(@"project", error.localizedDescription, nil);
      return;
    }
    git_repository *repository = lease.repository;
    git_remote *remote = nullptr;
    int result = git_remote_lookup(&remote, repository, LPRemoteName.UTF8String);
    if (result == GIT_ENOTFOUND) {
      result = git_remote_create(&remote, repository, LPRemoteName.UTF8String,
        remoteURL.absoluteString.UTF8String);
    } else if (result == 0) {
      git_remote_free(remote);
      remote = nullptr;
      result = git_remote_set_url(repository, LPRemoteName.UTF8String,
        remoteURL.absoluteString.UTF8String);
    }
    if (result == 0) {
      int clearPushURL = git_remote_set_pushurl(repository, LPRemoteName.UTF8String, nullptr);
      if (clearPushURL != 0 && clearPushURL != GIT_ENOTFOUND) result = clearPushURL;
    }
    if (remote != nullptr) git_remote_free(remote);
    NSString *storedURL = result == 0
      ? [self originURLForRepository:repository error:&error] : nil;
    if (result < 0 || ![storedURL isEqualToString:remoteURL.absoluteString]) {
      reject(@"git", @"Origin remote cannot be updated", nil);
      return;
    }
    NSDictionary *updated = [self updatedMetadata:metadata
                                        originURL:remoteURL.absoluteString
                                           lease:lease
                                            error:&error];
    if (updated == nil) {
      reject(@"storage", error.localizedDescription, nil);
      return;
    }
    resolve(@{
      @"schema_version": @1,
      @"project_id": projectId,
      @"name": LPRemoteName,
      @"url": remoteURL.absoluteString,
    });
  });
}

RCT_REMAP_METHOD(credentialStatus,
                 credentialStatusForProject:(id)projectIdValue
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  dispatch_async(self.projectQueue, ^{
    NSError *error = nil;
    NSString *projectId = LPString(projectIdValue);
    __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *lease = [self leaseRepositoryForId:projectId
                                                        mode:DSHLocalProjectAccessModeRead
                                                    metadata:nil
                                                       error:&error];
    if (lease == nil) {
      reject(@"project", error.localizedDescription, nil);
      return;
    }
    git_repository *repository = lease.repository;
    NSDictionary *status = [self credentialStatusForId:projectId
                                             repository:repository
                                                  error:&error];
    if (status == nil) {
      reject(@"keychain", error.localizedDescription, nil);
      return;
    }
    resolve(status);
  });
}

RCT_REMAP_METHOD(sshCredentialStatus,
                 sshCredentialStatusForProfile:(id)profileIdValue
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  dispatch_async(self.projectQueue, ^{
    NSError *error = nil;
    NSString *profileId = LPString(profileIdValue);
    NSDictionary *status = DSHGitSSHCredentialStatusForProfile(profileId, &error);
    if (error != nil) {
      reject(@"credential", error.localizedDescription, nil);
      return;
    }
    resolve(status ?: NSNull.null);
  });
}

/// Opens the native document picker for exactly one private-key file and one
/// OpenSSH known_hosts file. Selected data is read under the security-scoped
/// URL and immediately handed to Keychain storage; no filesystem copy is made.
RCT_REMAP_METHOD(beginSSHCredentialImport,
                 beginSSHCredentialImportForProfile:(id)profileIdValue
                 host:(id)hostValue
                 port:(id)portValue
                 username:(id)usernameValue
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  NSString *profileId = LPString(profileIdValue);
  NSString *host = LPString(hostValue).lowercaseString;
  NSInteger port = [portValue isKindOfClass:NSNumber.class] ? [portValue integerValue] : 0;
  NSString *username = LPString(usernameValue);
  if (profileId.length == 0 || host.length == 0 || port < 1 || port > 65535 || username.length == 0) {
    reject(@"validation", @"SSH profile endpoint is invalid", nil);
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    @synchronized (self) {
      if (self.sshImportResolve != nil) {
        reject(@"busy", @"Another SSH credential import is already active", nil);
        return;
      }
    }
    UIViewController *presenter = RCTPresentedViewController();
    if (presenter == nil || [presenter isKindOfClass:UIAlertController.class]) {
      reject(@"presentation", @"SSH credential picker cannot be presented", nil);
      return;
    }
    self.sshImportProfileId = profileId;
    self.sshImportHost = host;
    self.sshImportPort = port;
    self.sshImportUsername = username;
    self.sshImportResolve = resolve;
    self.sshImportReject = reject;
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.data"]
                                                                  inMode:UIDocumentPickerModeOpen];
    picker.allowsMultipleSelection = YES;
    picker.delegate = self;
    [presenter presentViewController:picker animated:YES completion:nil];
  });
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
  (void)controller;
  RCTPromiseResolveBlock resolve = self.sshImportResolve;
  self.sshImportResolve = nil;
  self.sshImportReject = nil;
  self.sshImportProfileId = nil;
  self.sshImportHost = nil;
  self.sshImportUsername = nil;
  self.sshImportPort = 0;
  if (resolve != nil) resolve(NSNull.null);
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
 didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
  (void)controller;
  RCTPromiseResolveBlock resolve = self.sshImportResolve;
  RCTPromiseRejectBlock reject = self.sshImportReject;
  NSString *profileId = self.sshImportProfileId;
  NSString *host = self.sshImportHost;
  NSInteger port = self.sshImportPort;
  NSString *username = self.sshImportUsername;
  self.sshImportResolve = nil;
  self.sshImportReject = nil;
  self.sshImportProfileId = nil;
  self.sshImportHost = nil;
  self.sshImportUsername = nil;
  self.sshImportPort = 0;
  if (urls.count != 2 || resolve == nil || reject == nil) {
    if (reject) reject(@"validation", @"Choose one private key and one known_hosts file", nil);
    return;
  }
  NSURL *keyURL = nil;
  NSURL *knownURL = nil;
  for (NSURL *url in urls) {
    if ([url.lastPathComponent isEqualToString:@"known_hosts"] ||
        [url.lastPathComponent isEqualToString:@"known_hosts.old"]) knownURL = url;
    else if (keyURL == nil) keyURL = url;
    else { keyURL = nil; break; }
  }
  if (keyURL == nil || knownURL == nil) {
    reject(@"validation", @"Choose one private key and one known_hosts file", nil);
    return;
  }
  NSDictionary *resourceKeys = [keyURL resourceValuesForKeys:
      @[NSURLIsDirectoryKey, NSURLFileSizeKey] error:nil];
  NSDictionary *knownResourceKeys = [knownURL resourceValuesForKeys:
      @[NSURLIsDirectoryKey, NSURLFileSizeKey] error:nil];
  NSNumber *keySize = resourceKeys[NSURLFileSizeKey];
  NSNumber *knownSize = knownResourceKeys[NSURLFileSizeKey];
  if ([resourceKeys[NSURLIsDirectoryKey] boolValue] ||
      [knownResourceKeys[NSURLIsDirectoryKey] boolValue] ||
      keySize == nil || knownSize == nil || keySize.unsignedLongLongValue > 131072 ||
      knownSize.unsignedLongLongValue > 1048576) {
    reject(@"validation", @"SSH key or known_hosts file is too large", nil);
    return;
  }
  BOOL keyAccess = [keyURL startAccessingSecurityScopedResource];
  BOOL knownAccess = [knownURL startAccessingSecurityScopedResource];
  NSData *keyData = keyAccess ? [NSData dataWithContentsOfURL:keyURL options:NSDataReadingMappedIfSafe error:nil] : nil;
  NSData *knownData = knownAccess ? [NSData dataWithContentsOfURL:knownURL options:NSDataReadingMappedIfSafe error:nil] : nil;
  if (keyAccess) [keyURL stopAccessingSecurityScopedResource];
  if (knownAccess) [knownURL stopAccessingSecurityScopedResource];
  NSString *privateKey = [[NSString alloc] initWithData:keyData encoding:NSUTF8StringEncoding];
  NSString *knownHosts = [[NSString alloc] initWithData:knownData encoding:NSUTF8StringEncoding];
  keyData = nil;
  knownData = nil;
  NSError *error = nil;
  if (privateKey == nil || knownHosts == nil ||
      !DSHGitSSHPrivateKeyIsSupported(privateKey, &error)) {
    reject(@"credential", error.localizedDescription ?: @"SSH private key is invalid", nil);
    return;
  }
  BOOL stored = DSHGitSSHStoreCredentialForProfile(profileId, host, port, username,
      privateKey, nil, nil, knownHosts, &error);
  privateKey = nil;
  knownHosts = nil;
  if (!stored) {
    reject(@"credential", error.localizedDescription ?: @"SSH credential cannot be saved", nil);
    return;
  }
  resolve(DSHGitSSHCredentialStatusForProfile(profileId, nil));
}

RCT_REMAP_METHOD(presentCredentialPrompt,
                 presentCredentialPromptForProject:(id)projectIdValue
                 locale:(id)localeValue
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  NSString *projectId = LPString(projectIdValue);
  NSString *locale = LPString(localeValue);
  dispatch_async(self.projectQueue, ^{
    NSError *error = nil;
    __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *lease = [self leaseRepositoryForId:projectId
                                                        mode:DSHLocalProjectAccessModeRead
                                                    metadata:nil
                                                       error:&error];
    if (lease == nil) {
      reject(@"project", error.localizedDescription, nil);
      return;
    }
    NSString *origin = [self originURLForRepository:lease.repository error:&error];
    lease = nil;
    if (origin == nil) {
      reject(@"remote", error.localizedDescription, nil);
      return;
    }
    NSString *host = [NSURLComponents componentsWithString:origin].host.lowercaseString;
    BOOL plaintext = DSHGitRemoteURLIsPlaintext([NSURL URLWithString:origin]);
    BOOL chinese = [locale isEqualToString:@"zh-CN"];
    // The username, token, and expiry choice travel from the native prompt
    // into this completion only; the token is written to the Keychain and the
    // bridge receives the credential status, never the secret.
    LPCredentialPromptCompletion completion = ^(NSString *username,
                                                NSString *token,
                                                NSInteger expirySeconds,
                                                NSString *failureCode) {
      if (failureCode != nil || username == nil || token == nil) {
        NSString *code = failureCode ?: @"cancelled";
        reject(code, [code isEqualToString:@"presentation"]
            ? @"Git credential prompt cannot be presented right now"
            : @"Git credential prompt was cancelled", nil);
        return;
      }
      dispatch_async(self.projectQueue, ^{
        NSError *storeError = nil;
        __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *currentLease = [self leaseRepositoryForId:projectId
                                                                   mode:DSHLocalProjectAccessModeRead
                                                               metadata:nil
                                                                  error:&storeError];
        NSString *currentOrigin = currentLease == nil ? nil
          : [self originURLForRepository:currentLease.repository error:&storeError];
        NSString *currentHost = [NSURLComponents
          componentsWithString:currentOrigin].host.lowercaseString;
        if (currentOrigin == nil || ![currentHost isEqualToString:host]) {
          currentLease = nil;
          reject(@"remote", @"Origin remote changed before credential save", nil);
          return;
        }
        if (!DSHGitStoreCredentialForScope(projectId, host, username, token,
                                            expirySeconds, &storeError)) {
          currentLease = nil;
          reject(@"credential", storeError.localizedDescription, nil);
          return;
        }
        NSDictionary *status = [self credentialStatusForScope:projectId
                                                         host:host
                                                        error:&storeError];
        currentLease = nil;
        if (status == nil) {
          reject(@"keychain", storeError.localizedDescription, nil);
          return;
        }
        resolve(status);
      });
    };
    LPCredentialPromptHook hook = self.credentialPromptHook;
    if (hook != nil) {
      hook(host, chinese, plaintext, completion);
      return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      [self presentCredentialAlertForHost:host
                                  chinese:chinese
                                plaintext:plaintext
                               completion:completion];
    });
  });
}

/// The native (non React Native) secure prompt: a username/token alert
/// followed by an explicit expiry choice. Text fields are cleared as soon as
/// their values are captured.
- (void)presentCredentialAlertForHost:(NSString *)host
                              chinese:(BOOL)chinese
                            plaintext:(BOOL)plaintext
                           completion:(LPCredentialPromptCompletion)completion {
  UIViewController *presenter = RCTPresentedViewController();
  if (presenter == nil || [presenter isKindOfClass:UIAlertController.class]) {
    completion(nil, nil, 0, @"presentation");
    return;
  }
  NSString *title = chinese ? @"Git HTTPS 凭据" : @"Git HTTPS credential";
  NSString *transport = plaintext
    ? (chinese ? @"该远程是局域网明文 HTTP 测试地址。" : @" This remote is a plain-HTTP address on the local network.")
    : @"";
  NSString *message = chinese
    ? [NSString stringWithFormat:@"用于 %@ 的推送。PAT 仅保存在本机 Keychain，永不传回 React Native。%@接下来选择保存时长（1 小时 / 24 小时 / 7 天）。", host, transport]
    : [NSString stringWithFormat:@"Used to push to %@. The PAT stays in this device's Keychain and is never returned to React Native.%@ Next, choose how long to keep it (1 hour / 24 hours / 7 days).", host, transport];
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
    message:message preferredStyle:UIAlertControllerStyleAlert];
  [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
    field.placeholder = chinese ? @"用户名" : @"Username";
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.textContentType = UITextContentTypeUsername;
  }];
  [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
    field.placeholder = @"Personal access token";
    field.secureTextEntry = YES;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.textContentType = UITextContentTypePassword;
  }];
  [alert addAction:[UIAlertAction actionWithTitle:(chinese ? @"取消" : @"Cancel")
    style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) {
      for (UITextField *field in alert.textFields) field.text = @"";
      completion(nil, nil, 0, @"cancelled");
    }]];
  [alert addAction:[UIAlertAction actionWithTitle:(chinese ? @"保存" : @"Save")
    style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
      NSString *username = alert.textFields.firstObject.text ?: @"";
      NSString *token = alert.textFields.lastObject.text ?: @"";
      for (UITextField *field in alert.textFields) field.text = @"";
      // The expiry is an explicit user choice in the same native flow.
      // Cancelling here abandons the whole provisioning.
      UIAlertController *expiry = [UIAlertController alertControllerWithTitle:
          (chinese ? @"令牌保存时长" : @"How long should this token stay stored?")
          message:(chinese ? @"到期后推送会要求重新输入。"
                           : @"Push will ask for a new token once it expires.")
          preferredStyle:UIAlertControllerStyleAlert];
      [expiry addAction:[UIAlertAction actionWithTitle:(chinese ? @"1 小时" : @"1 hour")
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *ignored) {
          completion(username, token, DSHGitCredentialExpiryOneHour, nil);
        }]];
      [expiry addAction:[UIAlertAction actionWithTitle:(chinese ? @"24 小时" : @"24 hours")
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *ignored) {
          completion(username, token, DSHGitCredentialExpiryOneDay, nil);
        }]];
      [expiry addAction:[UIAlertAction actionWithTitle:(chinese ? @"7 天" : @"7 days")
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *ignored) {
          completion(username, token, DSHGitCredentialExpirySevenDays, nil);
        }]];
      [expiry addAction:[UIAlertAction actionWithTitle:(chinese ? @"取消" : @"Cancel")
        style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *ignored) {
          completion(nil, nil, 0, @"cancelled");
        }]];
      // Let the credential alert finish dismissing before presenting the
      // expiry choice from the same presenter.
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC),
          dispatch_get_main_queue(), ^{
        UIViewController *nextPresenter = RCTPresentedViewController();
        if (nextPresenter == nil) {
          completion(nil, nil, 0, @"presentation");
          return;
        }
        [nextPresenter presentViewController:expiry animated:YES completion:nil];
      });
    }]];
  [presenter presentViewController:alert animated:YES completion:nil];
}

RCT_REMAP_METHOD(clearCredential,
                 clearCredentialForProject:(id)projectIdValue
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  dispatch_async(self.projectQueue, ^{
    NSError *error = nil;
    NSString *projectId = LPString(projectIdValue);
    __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *lease = [self leaseRepositoryForId:projectId
                                                        mode:DSHLocalProjectAccessModeRead
                                                    metadata:nil
                                                       error:&error];
    if (lease == nil) {
      reject(@"project", error.localizedDescription, nil);
      return;
    }
    git_repository *repository = lease.repository;
    NSString *origin = [self originURLForRepository:repository error:&error];
    if (origin == nil) {
      lease = nil;
      reject(@"remote", error.localizedDescription, nil);
      return;
    }
    NSString *host = [NSURLComponents componentsWithString:origin].host.lowercaseString;
    if (!DSHGitDeleteCredentialForScope(projectId, host, &error)) {
      lease = nil;
      reject(@"keychain", error.localizedDescription, nil);
      return;
    }
    // Older builds stored a host-only item; remove it too so clearing is total.
    (void)DSHGitDeleteLegacyHostCredential(host, nil);
    lease = nil;
    resolve(@{
      @"schema_version": @1,
      @"project_id": projectId,
      @"host": host,
      @"configured": @NO,
    });
  });
}

RCT_REMAP_METHOD(push,
                 pushProject:(id)projectIdValue
                 options:(id)optionsValue
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  dispatch_async(self.projectQueue, ^{
    NSError *error = nil;
    __attribute__((objc_precise_lifetime)) NSString *proxyURL =
      LPValidatedHTTPSProxyURL(optionsValue, &error);
    NSString *requestedBranch = nil;
    if (error == nil) {
      (void)LPValidatedPushBranchOption(optionsValue, &requestedBranch, &error);
    }
    if (error != nil) {
      reject(@"validation", error.localizedDescription, nil);
      return;
    }
    NSString *projectId = LPString(projectIdValue);
    NSDictionary *metadata = nil;
    __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *lease = [self leaseRepositoryForId:projectId
                                                        mode:DSHLocalProjectAccessModeWrite
                                                    metadata:&metadata
                                                       error:&error];
    if (lease == nil) {
      reject(@"project", error.localizedDescription, nil);
      return;
    }
    git_repository *repository = lease.repository;
    NSString *origin = [self originURLForRepository:repository error:&error];
    if (origin == nil) {
      lease = nil;
      reject(@"remote", error.localizedDescription ?: @"Origin remote is unavailable or unsafe", nil);
      return;
    }
    if (DSHGitSSHValidatedRemote(origin, nil) != nil) {
      lease = nil;
      reject(@"credential", @"SSH push is unavailable until an SSH push transport is enabled", nil);
      return;
    }
    NSString *host = [NSURLComponents componentsWithString:origin].host.lowercaseString;
    NSError *credentialError = nil;
    NSDictionary *credential = DSHGitCredentialForScope(projectId, host, &credentialError);
    if (credential == nil) {
      lease = nil;
      reject(@"credential", credentialError.localizedDescription
        ?: @"Git credential is not configured for this host", nil);
      return;
    }
    git_reference *head = nullptr;
    int result = git_repository_head(&head, repository);
    const char *fullRef = result == 0 && head != nullptr ? git_reference_name(head) : nullptr;
    const git_oid *headTarget = head == nullptr ? nullptr : git_reference_target(head);
    BOOL localBranch = fullRef != nullptr && headTarget != nullptr
      && git_reference_is_branch(head) && strncmp(fullRef, "refs/heads/", 11) == 0;
    NSString *branch = localBranch ? [NSString stringWithUTF8String:fullRef + 11] : nil;
    NSString *oid = LPOidString(headTarget);
    if (!localBranch || branch.length == 0 || !LPIsSafeRepositoryPath(branch)
      || [branch containsString:@".."] || [branch containsString:@" "] || oid == nil) {
      if (head != nullptr) git_reference_free(head);
      lease = nil;
      reject(@"git", @"A local branch with at least one commit is required", nil);
      return;
    }
    if (requestedBranch != nil && ![requestedBranch isEqualToString:branch]) {
      // Publish HEAD under a new local branch and switch to it. Only a new
      // reference is created; the commit graph and worktree are untouched.
      git_oid target = *headTarget;
      git_reference_free(head);
      head = nullptr;
      NSString *created = [self createLocalBranchNamed:requestedBranch
                                                 atOID:&target
                                            repository:repository
                                                 error:&error];
      if (created == nil ||
          git_reference_lookup(&head, repository, created.UTF8String) != 0) {
        if (head != nullptr) git_reference_free(head);
        lease = nil;
        reject(error.code == 3030 ? @"conflict" : @"git",
               error.localizedDescription ?: @"Branch cannot be created", nil);
        return;
      }
      fullRef = git_reference_name(head);
      headTarget = git_reference_target(head);
      branch = requestedBranch;
    }
    NSString *fullReference = [NSString stringWithUTF8String:fullRef];
    DSHGitPushCancelToken *cancelToken = [[DSHGitPushCancelToken alloc] init];
    @synchronized (self) {
      self.pushCancelTokens[projectId] = cancelToken;
    }
    int gitDescriptor = lease.gitDescriptor;
    __attribute__((objc_precise_lifetime)) DSHGitPushRequest *pushRequest =
        [[DSHGitPushRequest alloc] init];
    pushRequest.repository = repository;
    pushRequest.remoteName = LPRemoteName;
    pushRequest.remoteURL = origin;
    pushRequest.host = host;
    pushRequest.fullReference = fullReference;
    pushRequest.localOID = oid;
    pushRequest.username = credential[@"username"];
    pushRequest.token = credential[@"token"];
    pushRequest.proxyURL = proxyURL;
    pushRequest.cancelToken = cancelToken;
    pushRequest.timeout = LPPushTimeoutSeconds;
    // Keep the lease alive until the network phase truly settles; the
    // completion records the receipt even when the caller already observed a
    // timeout or cancellation, so a late success is still accounted for.
    __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *heldLease = lease;
    NSString *receiptBranch = branch;
    pushRequest.completion = ^(DSHGitPushOutcome outcome, NSString *remoteOID) {
      (void)heldLease;
      if (outcome == DSHGitPushOutcomeSuccess && remoteOID.length > 0) {
        (void)DSHGitPushRecordReceipt(gitDescriptor, projectId,
            DSHGitPushReceipt(host, receiptBranch, oid, remoteOID, LPNow()), nil);
      }
    };
    DSHGitPushResult *pushResult = DSHGitPushRun(pushRequest);
    @synchronized (self) {
      if (self.pushCancelTokens[projectId] == cancelToken) {
        [self.pushCancelTokens removeObjectForKey:projectId];
      }
    }
    if (pushResult.outcome == DSHGitPushOutcomeSuccess) {
      NSString *trackingName = [NSString stringWithFormat:@"refs/remotes/origin/%@", branch];
      git_reference *tracking = nullptr;
      if (git_reference_create(&tracking, repository, trackingName.UTF8String,
        headTarget, 1, "rish push") == 0) {
        git_branch_set_upstream(head,
          [[NSString stringWithFormat:@"origin/%@", branch] UTF8String]);
      }
      if (tracking != nullptr) git_reference_free(tracking);
      git_reference_free(head);
      [self updatedMetadata:metadata
                  originURL:origin
                      lease:lease
                      error:nil];
      NSDictionary *receipt = DSHGitPushLoadReceipts(gitDescriptor, projectId, nil).lastObject;
      if (![receipt[@"local_oid"] isEqual:oid] || ![receipt[@"branch"] isEqual:branch]) {
        receipt = DSHGitPushReceipt(host, branch, oid, pushResult.remoteOID ?: oid, LPNow());
      }
      resolve(@{
        @"schema_version": @1,
        @"project_id": projectId,
        @"remote": LPRemoteName,
        @"branch": branch,
        @"oid": oid,
        @"pushed_at": receipt[@"pushed_at"],
        @"receipt": receipt,
      });
      return;
    }
    git_reference_free(head);
    switch (pushResult.outcome) {
      case DSHGitPushOutcomeNonFastForward:
        reject(@"non-fast-forward",
          @"Remote rejected the push: the branch is not fast-forward. "
          "Pull the remote changes first or push a different branch.", nil);
        return;
      case DSHGitPushOutcomeRejected:
        reject(@"rejected", @"Remote rejected the push", nil);
        return;
      case DSHGitPushOutcomeAuthFailure:
        reject(@"credential", @"Git credential was rejected by the remote", nil);
        return;
      case DSHGitPushOutcomeTimedOut:
        reject(@"timeout", @"Push timed out", nil);
        return;
      case DSHGitPushOutcomeCancelled:
        reject(@"cancelled", @"Push was cancelled", nil);
        return;
      default:
        reject(@"git", @"Repository cannot be pushed", nil);
        return;
    }
  });
}

/// Creates `refs/heads/<name>` at `target` (or accepts an existing branch
/// already at `target`) and points HEAD at it without touching the worktree.
- (NSString *)createLocalBranchNamed:(NSString *)name
                               atOID:(const git_oid *)target
                          repository:(git_repository *)repository
                               error:(NSError **)error {
  NSString *fullName = [@"refs/heads/" stringByAppendingString:name];
  git_reference *existing = nullptr;
  int lookup = git_reference_lookup(&existing, repository, fullName.UTF8String);
  if (lookup == 0) {
    const git_oid *existingTarget = git_reference_target(existing);
    BOOL same = existingTarget != nullptr && git_oid_equal(existingTarget, target);
    git_reference_free(existing);
    if (!same) {
      if (error != nil) *error = LPError(3030, @"A local branch with that name already exists");
      return nil;
    }
  } else if (lookup == GIT_ENOTFOUND) {
    git_reference *created = nullptr;
    if (git_reference_create(&created, repository, fullName.UTF8String, target, 0,
                             "rish push: new branch") != 0) {
      if (error != nil) *error = LPError(3031, @"Branch cannot be created");
      return nil;
    }
    git_reference_free(created);
  } else {
    if (error != nil) *error = LPError(3031, @"Branch cannot be created");
    return nil;
  }
  if (git_repository_set_head(repository, fullName.UTF8String) != 0) {
    if (error != nil) *error = LPError(3031, @"Branch cannot be created");
    return nil;
  }
  return fullName;
}

RCT_REMAP_METHOD(cancelPush,
                 cancelPushForProject:(id)projectIdValue
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  // Deliberately not queued on projectQueue: the in-flight push blocks that
  // queue while polling the cancel token.
  NSString *projectId = LPString(projectIdValue);
  DSHGitPushCancelToken *token = nil;
  @synchronized (self) {
    token = self.pushCancelTokens[projectId];
  }
  if (token == nil) {
    reject(@"state", @"No push is in flight for this project", nil);
    return;
  }
  [token cancel];
  resolve(@{
    @"schema_version": @1,
    @"project_id": projectId,
    @"cancelled": @YES,
  });
}

RCT_REMAP_METHOD(pushReceipts,
                 pushReceiptsForProject:(id)projectIdValue
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  dispatch_async(self.projectQueue, ^{
    NSError *error = nil;
    NSString *projectId = LPString(projectIdValue);
    __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *lease = [self leaseRepositoryForId:projectId
                                                        mode:DSHLocalProjectAccessModeRead
                                                    metadata:nil
                                                       error:&error];
    if (lease == nil) {
      reject(@"project", error.localizedDescription, nil);
      return;
    }
    NSArray<NSDictionary *> *receipts =
        DSHGitPushLoadReceipts(lease.gitDescriptor, projectId, &error);
    if (receipts == nil) {
      reject(@"storage", error.localizedDescription ?: @"Receipt storage is unavailable", nil);
      return;
    }
    // Sanitize before crossing the bridge: hosts, branch names, OIDs, and
    // timestamps only. Tokens and container paths never appear here.
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *receipt in receipts) {
      [rows addObject:@{
        @"schema_version" : @1,
        @"remote" : receipt[@"remote"],
        @"host" : receipt[@"host"],
        @"branch" : receipt[@"branch"],
        @"local_oid" : receipt[@"local_oid"],
        @"remote_oid" : receipt[@"remote_oid"],
        @"pushed_at" : receipt[@"pushed_at"],
      }];
    }
    resolve(@{
      @"schema_version": @1,
      @"project_id": projectId,
      @"receipts": rows,
    });
  });
}

// MARK: - Workspace-root routed Project/Git V2

RCT_REMAP_METHOD(attachWorkspaceProject,
                 attachWorkspaceProjectRequest:(id)requestValue
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  NSDictionary *request = nil;
  NSError *validationError = nil;
  @try {
    request = LPDictionary(requestValue);
    NSDictionary *root = LPV2Root(request[@"root"], NO, &validationError);
    NSString *operationId = LPString(request[@"operation_id"]);
    NSString *mode = LPString(request[@"mode"]);
    if (!LPV2ExactKeys(request, @[
          @"schema_version", @"operation_id", @"root", @"mode"
        ]) || ![request[@"schema_version"] isEqual:@1] ||
        !LPV2CanonicalOperationId(operationId) || root == nil ||
        (![mode isEqual:@"open"] && ![mode isEqual:@"init"])) {
      validationError = LPError(3101, @"Project attach request is invalid");
    } else {
      request = @{
        @"schema_version" : @1,
        @"operation_id" : [operationId copy],
        @"root" : root,
        @"mode" : [mode copy],
      };
    }
  } @catch (__unused NSException *exception) {
    validationError = LPError(3101, @"Project attach request is invalid");
  }
  if (validationError != nil || request == nil) {
    LPV2Reject(reject, validationError ?: LPError(3101, @"Project attach request is invalid"));
    return;
  }
  dispatch_async(self.projectQueue, ^{
    NSError *error = nil;
    NSDictionary *result = nil;
    @try {
      result = [self v2AttachWorkspaceProject:request error:&error];
    } @catch (__unused NSException *exception) {
      error = LPError(3199, @"Project attach failed");
    }
    if (result == nil) {
      LPV2Reject(reject, error ?: LPError(3199, @"Project attach failed"));
    } else {
      resolve(result);
    }
  });
}

RCT_REMAP_METHOD(projectForWorkspaceV2,
                 projectForWorkspaceV2:(id)rootValue
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  NSDictionary *root = nil;
  NSError *validationError = nil;
  @try {
    root = LPV2Root(rootValue, NO, &validationError);
  } @catch (__unused NSException *exception) {
    validationError = LPError(3101, @"Workspace root is invalid");
  }
  if (root == nil) {
    LPV2Reject(reject, validationError ?: LPError(3101, @"Workspace root is invalid"));
    return;
  }
  dispatch_async(self.projectQueue, ^{
    NSError *error = nil;
    NSDictionary *result = nil;
    @try {
      result = [self v2ProjectForWorkspace:root error:&error];
    } @catch (__unused NSException *exception) {
      error = LPError(3199, @"Project lookup failed");
    }
    if (result == nil) LPV2Reject(reject, error ?: LPError(3199, @"Project lookup failed"));
    else resolve(result);
  });
}

- (NSDictionary *)v2PrepareDetach:(NSDictionary *)request
                             error:(NSError **)error {
  NSDictionary *root = LPV2Root(request[@"root"], YES, error);
  NSString *operationId = LPString(request[@"operation_id"]);
  NSString *mode = LPString(request[@"mode"]);
  if (!LPV2ExactKeys(request, @[
        @"schema_version", @"operation_id", @"root", @"mode"
      ]) || ![request[@"schema_version"] isEqual:@1] || root == nil ||
      !LPV2CanonicalOperationId(operationId) ||
      (![mode isEqual:@"retain_private_gitdir"] &&
       ![mode isEqual:@"delete_private_gitdir"])) {
    if (error != nil) *error = LPError(3101, @"Project detach request is invalid");
    return nil;
  }
  DSHLocalProjectLease *lease = [self v2LeaseForRoot:root
                                                 mode:DSHLocalProjectAccessModeRead
                                                error:error];
  if (lease == nil || ![self.projectAccessV2
          validateWorkspaceLeaseIdentity:lease rootRef:root error:error]) {
    return nil;
  }
  NSString *checkpointId = NSUUID.UUID.UUIDString.lowercaseString;
  NSString *gitdirDigest = lease.workspaceBindingDigest;
  if (!LPV2CanonicalOperationId(checkpointId) ||
      !LPV2CanonicalDigest(gitdirDigest)) {
    if (error != nil) *error = LPError(3104, @"Project detach checkpoint is invalid");
    return nil;
  }
  NSDictionary *checkpoint = @{
    @"schema_version" : @1,
    @"checkpoint_id" : checkpointId,
    @"project_id" : root[@"project_id"],
    @"workspace_id" : root[@"workspace_id"],
    @"binding_revision" : root[@"binding_revision"],
    @"gitdir_sha256" : gitdirDigest,
    @"mode" : mode,
    @"created_at" : LPNow(),
  };
  @synchronized (self) {
    self.v2DetachCheckpoints[checkpointId] = checkpoint;
  }
  DSHWorkspaceClearanceRegisterProjectDetachCheckpoint(
      checkpoint[@"workspace_id"],
      [checkpoint[@"binding_revision"] unsignedIntegerValue]);
  return checkpoint;
}

- (NSDictionary *)v2CommitDetach:(NSDictionary *)request
                            error:(NSError **)error {
  NSString *operationId = LPString(request[@"operation_id"]);
  NSString *clearance = LPString(request[@"clearance_receipt_id"]);
  NSDictionary *checkpoint = LPDictionary(request[@"checkpoint"]);
  if (!LPV2ExactKeys(request, @[
        @"schema_version", @"operation_id", @"checkpoint",
        @"clearance_receipt_id"
      ]) || ![request[@"schema_version"] isEqual:@1] ||
      !LPV2CanonicalOperationId(operationId) ||
      !LPV2CanonicalOperationId(clearance) ||
      !LPV2ExactKeys(checkpoint, @[
        @"schema_version", @"checkpoint_id", @"project_id",
        @"workspace_id", @"binding_revision", @"gitdir_sha256",
        @"mode", @"created_at"
      ]) || ![checkpoint[@"schema_version"] isEqual:@1] ||
      !LPV2CanonicalOperationId(LPString(checkpoint[@"checkpoint_id"])) ||
      ![DSHLocalProjectAccess isCanonicalProjectId:
          LPString(checkpoint[@"project_id"])] ||
      ![DSHLocalProjectAccess isCanonicalProjectId:
          LPString(checkpoint[@"workspace_id"])] ||
      !LPV2SafeRevision(checkpoint[@"binding_revision"]) ||
      !LPV2CanonicalDigest(checkpoint[@"gitdir_sha256"] ) ||
      (![checkpoint[@"mode"] isEqual:@"retain_private_gitdir"] &&
       ![checkpoint[@"mode"] isEqual:@"delete_private_gitdir"])) {
    if (error != nil) *error = LPError(3101, @"Project detach request is invalid");
    return nil;
  }
  NSDictionary *stored = nil;
  @synchronized (self) {
    stored = self.v2DetachCheckpoints[checkpoint[@"checkpoint_id"]];
  }
  if (stored == nil || ![stored isEqual:checkpoint]) {
    if (error != nil) *error = LPError(3106, @"Project detach checkpoint is stale");
    return nil;
  }
  NSDictionary *root = @{
    @"schema_version" : @1,
    @"workspace_id" : checkpoint[@"workspace_id"],
    @"binding_revision" : checkpoint[@"binding_revision"],
    @"project_id" : checkpoint[@"project_id"],
  };
  DSHLocalProjectLease *lease = [self v2LeaseForRoot:root
                                                 mode:DSHLocalProjectAccessModeRead
                                                error:error];
  if (lease == nil || ![lease.workspaceBindingDigest
          isEqual:checkpoint[@"gitdir_sha256"]] ||
      ![self.projectAccessV2 validateWorkspaceLeaseIdentity:lease
                                                     rootRef:root
                                                       error:error]) {
    if (error != nil && *error == nil) *error = LPError(3106, @"Project detach checkpoint is stale");
    return nil;
  }
  // The schema-8 clearance store is the only authority allowed to approve a
  // destructive private-gitdir mutation. This bridge has no access to that
  // store yet, so fail closed rather than treating a JavaScript UUID as a
  // trust anchor. The checkpoint remains retryable for the mounted owner.
  if (error != nil) *error = LPError(3112, @"Workspace clearance is unavailable");
  return nil;

}

RCT_REMAP_METHOD(prepareProjectDetachV1,
                 prepareProjectDetachV1Request:(id)requestValue
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  NSDictionary *request = nil;
  NSError *validationError = nil;
  NSDictionary *root = nil;
  NSString *operationId = nil;
  NSString *mode = nil;
  BOOL inputValid = NO;
  @try {
    request = LPDictionary(requestValue);
    root = LPV2Root(request[@"root"], YES, &validationError);
    operationId = LPString(request[@"operation_id"]);
    mode = LPString(request[@"mode"]);
    inputValid = LPV2ExactKeys(request, @[
          @"schema_version", @"operation_id", @"root", @"mode"
        ]) && [request[@"schema_version"] isEqual:@1] && root != nil &&
        LPV2CanonicalOperationId(operationId) &&
        ([mode isEqual:@"retain_private_gitdir"] ||
         [mode isEqual:@"delete_private_gitdir"]);
  } @catch (__unused NSException *exception) {
    validationError = LPError(3199, @"Project detach request is invalid");
  }
  if (!inputValid) {
    LPV2Reject(reject, validationError ?: LPError(3101, @"Project detach request is invalid"));
    return;
  }
  NSDictionary *canonicalRequest = @{
    @"schema_version" : @1,
    @"operation_id" : operationId,
    @"root" : root,
    @"mode" : mode,
  };
  dispatch_async(self.projectQueue, ^{
    NSError *error = nil;
    NSDictionary *result = nil;
    @try { result = [self v2PrepareDetach:canonicalRequest error:&error]; }
    @catch (__unused NSException *exception) { error = LPError(3199, @"Project detach failed"); }
    if (result == nil) LPV2Reject(reject, error ?: LPError(3199, @"Project detach failed"));
    else resolve(result);
  });
}

RCT_REMAP_METHOD(commitProjectDetachV1,
                 commitProjectDetachV1Request:(id)requestValue
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  NSDictionary *request = LPDictionary(requestValue);
  dispatch_async(self.projectQueue, ^{
    NSError *error = nil;
    NSDictionary *result = nil;
    @try { result = [self v2CommitDetach:request error:&error]; }
    @catch (__unused NSException *exception) { error = LPError(3199, @"Project detach failed"); }
    if (result == nil) LPV2Reject(reject, error ?: LPError(3199, @"Project detach failed"));
    else resolve(result);
  });
}

RCT_REMAP_METHOD(statusV2,
                 statusV2Request:(id)requestValue
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  NSDictionary *request = nil;
  NSError *validationError = nil;
  NSDictionary *root = nil;
  BOOL inputValid = NO;
  @try {
    request = LPDictionary(requestValue);
    root = LPV2Root(request[@"root"], YES, &validationError);
    inputValid = LPV2ExactKeys(request, @[@"schema_version", @"root"]) &&
        [request[@"schema_version"] isEqual:@1] && root != nil;
  } @catch (__unused NSException *exception) {
    validationError = LPError(3199, @"Git request is invalid");
  }
  if (!inputValid) {
    LPV2Reject(reject, validationError ?: LPError(3101, @"Git request is invalid"));
    return;
  }
  dispatch_async(self.projectQueue, ^{
    NSError *error = nil;
    DSHLocalProjectLease *lease = [self v2LeaseForRoot:root
                                                   mode:DSHLocalProjectAccessModeRead
                                                  error:&error];
    NSDictionary *status = lease == nil ? nil
        : [self statusForRepository:lease.repository
                           projectId:root[@"project_id"] error:&error];
    BOOL valid = status != nil && [self.projectAccessV2
        validateWorkspaceLeaseIdentity:lease rootRef:root error:&error];
    if (!valid) {
      LPV2Reject(reject, error ?: LPError(3199, @"Git status failed"));
      return;
    }
    NSMutableDictionary *result = [status mutableCopy];
    result[@"schema_version"] = @2;
    result[@"root"] = root;
    resolve(result);
  });
}

RCT_REMAP_METHOD(diffV2,
                 diffV2Request:(id)requestValue
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  NSDictionary *request = nil;
  NSError *validationError = nil;
  NSDictionary *root = nil;
  id maxValue = nil;
  BOOL inputValid = NO;
  @try {
    request = LPDictionary(requestValue);
    root = LPV2Root(request[@"root"], YES, &validationError);
    maxValue = request[@"max_bytes"];
    BOOL validMax = [maxValue isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)maxValue) != CFBooleanGetTypeID() &&
        ![maxValue isKindOfClass:NSDecimalNumber.class] &&
        isfinite([maxValue doubleValue]) && floor([maxValue doubleValue]) ==
            [maxValue doubleValue] && [maxValue unsignedIntegerValue] >= 1 &&
        [maxValue unsignedIntegerValue] <= LPV2MaxDiffBytes &&
        (double)[maxValue unsignedIntegerValue] == [maxValue doubleValue];
    // `staged` chooses the index against HEAD over the working tree against
    // the index; the panel asks for both, a commit review for the first.
    id stagedValue = request[@"staged"];
    BOOL validStaged = [stagedValue isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)stagedValue) == CFBooleanGetTypeID();
    inputValid = LPV2ExactKeys(request,
                               @[@"schema_version", @"root", @"max_bytes", @"staged"]) &&
        [request[@"schema_version"] isEqual:@1] && root != nil && validMax &&
        validStaged;
  } @catch (__unused NSException *exception) {
    validationError = LPError(3199, @"Git diff request is invalid");
  }
  if (!inputValid) {
    LPV2Reject(reject, validationError ?: LPError(3101, @"Git diff request is invalid"));
    return;
  }
  NSUInteger maxBytes = [maxValue unsignedIntegerValue];
  BOOL staged = [request[@"staged"] boolValue];
  dispatch_async(self.projectQueue, ^{
    NSError *error = nil;
    DSHLocalProjectLease *lease = [self v2LeaseForRoot:root
                                                   mode:DSHLocalProjectAccessModeRead
                                                  error:&error];
    NSDictionary *diff = lease == nil ? nil
        : [self diffForRepository:lease.repository
                           projectId:root[@"project_id"] staged:staged
                       contextLines:3 error:&error];
    BOOL valid = diff != nil && [self.projectAccessV2
        validateWorkspaceLeaseIdentity:lease rootRef:root error:&error];
    if (!valid) {
      LPV2Reject(reject, error ?: LPError(3199, @"Git diff failed"));
      return;
    }
    NSMutableDictionary *result = [diff mutableCopy];
    BOOL clipped = NO;
    result[@"patch"] = LPV2ClipUTF8(result[@"patch"], maxBytes, &clipped);
    result[@"truncated"] = @([result[@"truncated"] boolValue] || clipped);
    result[@"schema_version"] = @2;
    result[@"root"] = root;
    resolve(result);
  });
}

RCT_REMAP_METHOD(stageAllV2,
                 stageAllV2Request:(id)requestValue
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  NSDictionary *request = nil;
  NSError *validationError = nil;
  NSDictionary *root = nil;
  BOOL inputValid = NO;
  @try {
    request = LPDictionary(requestValue);
    root = LPV2Root(request[@"root"], YES, &validationError);
    inputValid = LPV2ExactKeys(request, @[@"schema_version", @"root"]) &&
        [request[@"schema_version"] isEqual:@1] && root != nil;
  } @catch (__unused NSException *exception) {
    validationError = LPError(3199, @"Git request is invalid");
  }
  if (!inputValid) {
    LPV2Reject(reject, validationError ?: LPError(3101, @"Git request is invalid"));
    return;
  }
  dispatch_async(self.projectQueue, ^{
    NSError *error = nil;
    DSHLocalProjectLease *lease = [self v2LeaseForRoot:root
                                                   mode:DSHLocalProjectAccessModeWrite
                                                  error:&error];
    git_index *index = nullptr;
    int resultCode = lease == nil ? -1 : git_repository_index(&index, lease.repository);
    char wildcard[] = "*";
    char *patterns[] = {wildcard};
    git_strarray pathspec = {patterns, 1};
    if (resultCode == 0) resultCode = git_index_add_all(
        index, &pathspec, GIT_INDEX_ADD_DEFAULT, nullptr, nullptr);
    if (resultCode == 0) resultCode = git_index_write(index);
    if (index != nullptr) git_index_free(index);
    NSDictionary *status = resultCode == 0
        ? [self statusForRepository:lease.repository
                           projectId:root[@"project_id"] error:&error]
        : nil;
    BOOL valid = resultCode == 0 && status != nil && [self.projectAccessV2
        validateWorkspaceLeaseIdentity:lease rootRef:root error:&error];
    if (!valid) {
      LPV2Reject(reject, error ?: LPError(3199, @"Git stage failed"));
      return;
    }
    NSMutableDictionary *response = [status mutableCopy];
    response[@"schema_version"] = @2;
    response[@"root"] = root;
    resolve(response);
  });
}

RCT_REMAP_METHOD(commitV2,
                 commitV2Request:(id)requestValue
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  NSDictionary *request = nil;
  NSError *validationError = nil;
  NSDictionary *root = nil;
  NSString *operationId = nil;
  NSString *message = nil;
  NSString *authorName = nil;
  NSString *authorEmail = nil;
  id expectedHead = nil;
  BOOL inputValid = NO;
  @try {
    request = LPDictionary(requestValue);
    root = LPV2Root(request[@"root"], YES, &validationError);
    operationId = LPString(request[@"operation_id"]);
    message = LPString(request[@"message"]);
    authorName = LPString(request[@"author_name"]);
    authorEmail = LPString(request[@"author_email"]);
    expectedHead = request[@"expected_head_oid"];
    BOOL messageValid = LPV2BoundedString(message, LPV2MaxCommitMessageBytes, NO) &&
        [message stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0;
    BOOL nameValid = LPV2BoundedString(authorName, 120, NO) &&
        [authorName isEqualToString:[authorName
            stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet]] &&
        !LPHasControlCharacter(authorName) &&
        ![authorName containsString:@"<"] && ![authorName containsString:@">"];
    NSArray<NSString *> *emailParts =
        [authorEmail componentsSeparatedByString:@"@"];
    BOOL emailValid = LPV2BoundedString(authorEmail, 254, NO) &&
        emailParts.count == 2 && emailParts[0].length > 0 &&
        emailParts[1].length > 0 &&
        [authorEmail rangeOfCharacterFromSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet].location == NSNotFound &&
        ![authorEmail containsString:@"<"] && ![authorEmail containsString:@">"];
    inputValid = LPV2ExactKeys(request, @[
          @"schema_version", @"root", @"operation_id", @"message",
          @"author_name", @"author_email", @"expected_head_oid"
        ]) && [request[@"schema_version"] isEqual:@1] && root != nil &&
        LPV2CanonicalOperationId(operationId) && messageValid && nameValid &&
        emailValid && LPV2CanonicalOID(expectedHead, YES);
  } @catch (__unused NSException *exception) {
    validationError = LPError(3199, @"Git commit request is invalid");
  }
  if (!inputValid) {
    LPV2Reject(reject, validationError ?: LPError(3101, @"Git commit request is invalid"));
    return;
  }
  dispatch_async(self.projectQueue, ^{
    NSError *error = nil;
    DSHLocalProjectLease *lease = [self v2LeaseForRoot:root
                                                   mode:DSHLocalProjectAccessModeWrite
                                                  error:&error];
    if (lease == nil) {
      LPV2Reject(reject, error ?: LPError(3199, @"Git commit failed"));
      return;
    }
    git_repository *repository = lease.repository;
    git_reference *head = nullptr;
    const git_oid *target = nullptr;
    int headResult = git_repository_head(&head, repository);
    if (headResult == 0 && head != nullptr) target = git_reference_target(head);
    NSString *currentHead = LPOidString(target);
    BOOL unborn = headResult == GIT_EUNBORNBRANCH || headResult == GIT_ENOTFOUND;
    BOOL expectedMatches = expectedHead == NSNull.null
        ? unborn
        : (headResult == 0 && [currentHead isEqual:expectedHead]);
    if (!expectedMatches) {
      if (head != nullptr) git_reference_free(head);
      LPV2Reject(reject, LPError(3110, @"Git HEAD changed"));
      return;
    }
    if (head != nullptr) git_reference_free(head);

    git_index *index = nullptr;
    git_tree *tree = nullptr;
    git_commit *parent = nullptr;
    git_signature *signature = nullptr;
    git_oid treeOid = {};
    git_oid commitOid = {};
    int resultCode = git_repository_index(&index, repository);
    if (resultCode == 0 && git_index_has_conflicts(index)) resultCode = GIT_EUNMERGED;
    if (resultCode == 0) resultCode = git_index_write_tree(&treeOid, index);
    if (resultCode == 0) resultCode = git_tree_lookup(&tree, repository, &treeOid);
    git_reference *current = nullptr;
    int currentResult = resultCode == 0 ? git_repository_head(&current, repository)
                                        : resultCode;
    if (currentResult == 0 && current != nullptr) {
      const git_oid *parentOid = git_reference_target(current);
      if (parentOid == nullptr || git_commit_lookup(&parent, repository, parentOid) < 0) {
        resultCode = -1;
      } else if (git_oid_equal(&treeOid, git_commit_tree_id(parent))) {
        resultCode = GIT_EUNCHANGED;
      }
    } else if (currentResult == GIT_EUNBORNBRANCH || currentResult == GIT_ENOTFOUND) {
      resultCode = git_index_entrycount(index) == 0 ? GIT_EUNCHANGED : 0;
    } else if (currentResult < 0) {
      resultCode = currentResult;
    }
    if (current != nullptr) git_reference_free(current);
    if (resultCode == 0) resultCode = git_signature_now(
        &signature, authorName.UTF8String, authorEmail.UTF8String);
    const git_commit *parents[] = {parent};
    if (resultCode == 0) resultCode = git_commit_create(
        &commitOid, repository, "HEAD", signature, signature, "UTF-8",
        message.UTF8String, tree, parent == nullptr ? 0 : 1, parents);
    if (signature != nullptr) git_signature_free(signature);
    if (parent != nullptr) git_commit_free(parent);
    if (tree != nullptr) git_tree_free(tree);
    if (index != nullptr) git_index_free(index);
    if (resultCode != 0 || ![self.projectAccessV2
        validateWorkspaceLeaseIdentity:lease rootRef:root error:&error]) {
      LPV2Reject(reject, error ?: LPError(3199, @"Git commit failed"));
      return;
    }
    NSString *summary = [[message componentsSeparatedByCharactersInSet:
        NSCharacterSet.newlineCharacterSet] firstObject] ?: @"";
    resolve(@{
      @"schema_version" : @2,
      @"root" : root,
      @"project_id" : root[@"project_id"],
      @"oid" : LPOidString(&commitOid) ?: @"",
      @"summary" : summary,
      @"committed_at" : LPNow(),
    });
  });
}

RCT_REMAP_METHOD(pushV2,
                 pushV2Request:(id)requestValue
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  NSDictionary *request = nil;
  NSError *validationError = nil;
  NSDictionary *root = nil;
  NSString *operationId = nil;
  NSString *credentialReference = nil;
  NSString *expectedLocalOid = nil;
  NSString *proxyURL = nil;
  BOOL inputValid = NO;
  @try {
    request = LPDictionary(requestValue);
    root = LPV2Root(request[@"root"], YES, &validationError);
    operationId = LPString(request[@"operation_id"]);
    credentialReference = LPString(request[@"credential_reference"]);
    expectedLocalOid = LPString(request[@"expected_local_oid"]);
    id proxyValue = request[@"https_proxy_url"];
    if (proxyValue != NSNull.null) {
      proxyURL = LPValidatedHTTPSProxyURL(
          @{ @"httpsProxyUrl" : proxyValue }, &validationError);
    }
    BOOL proxyValid = proxyValue == NSNull.null || proxyURL != nil;
    inputValid = LPV2ExactKeys(request, @[
          @"schema_version", @"root", @"operation_id", @"remote",
          @"expected_local_oid", @"credential_reference", @"https_proxy_url"
        ]) && [request[@"schema_version"] isEqual:@1] && root != nil &&
        LPV2CanonicalOperationId(operationId) &&
        [request[@"remote"] isEqual:@"origin"] &&
        LPV2CanonicalOID(expectedLocalOid, NO) &&
        LPV2BoundedString(credentialReference, LPV2MaxCredentialReferenceBytes, NO) &&
        proxyValid;
  } @catch (__unused NSException *exception) {
    validationError = LPError(3199, @"Git push request is invalid");
  }
  if (!inputValid) {
    LPV2Reject(reject, validationError ?: LPError(3101, @"Git push request is invalid"));
    return;
  }
  request = @{
    @"schema_version" : @1,
    @"root" : root,
    @"operation_id" : operationId,
    @"remote" : @"origin",
    @"expected_local_oid" : expectedLocalOid,
    @"credential_reference" : credentialReference,
    @"https_proxy_url" : proxyURL ?: NSNull.null,
  };
  dispatch_async(self.projectQueue, ^{
    NSError *error = nil;
    DSHLocalProjectLease *lease = [self v2LeaseForRoot:root
                                                   mode:DSHLocalProjectAccessModeWrite
                                                  error:&error];
    if (lease == nil) {
      LPV2Reject(reject, error ?: LPError(3199, @"Git push failed"));
      return;
    }
    git_repository *repository = lease.repository;
    git_reference *head = nullptr;
    int headResult = git_repository_head(&head, repository);
    const git_oid *target = head == nullptr ? nullptr : git_reference_target(head);
    NSString *branch = nil;
    const char *fullRef = head == nullptr ? nullptr : git_reference_name(head);
    BOOL localBranch = headResult == 0 && fullRef != nullptr && target != nullptr &&
        git_reference_is_branch(head) && strncmp(fullRef, "refs/heads/", 11) == 0;
    if (localBranch) branch = [NSString stringWithUTF8String:fullRef + 11];
    BOOL expectedMatches = localBranch && [LPOidString(target)
        isEqual:expectedLocalOid] && branch.length > 0 &&
        LPV2BoundedString(branch, 1024, NO);
    if (!expectedMatches) {
      if (head != nullptr) git_reference_free(head);
      LPV2Reject(reject, LPError(3110, @"Git HEAD changed"));
      return;
    }
    NSString *origin = [self originURLForRepository:repository error:&error];
    NSString *host = origin == nil ? nil
      : [NSURLComponents componentsWithString:origin].host.lowercaseString;
    // V2 resolves the credential from the same (project id, host) Keychain
    // scope the native prompt writes. The opaque credential_reference field
    // is validated for shape only; it never selects a different item.
    NSString *projectId = root[@"project_id"];
    NSDictionary *credential = origin == nil ? nil
        : DSHGitCredentialForScope(projectId, host, nil);
    if (credential == nil) {
      if (head != nullptr) git_reference_free(head);
      LPV2Reject(reject, LPError(3111, @"Git credential is unavailable"));
      return;
    }
    NSString *fullReference = [NSString stringWithUTF8String:fullRef];
    NSString *oid = LPOidString(target);
    DSHGitPushCancelToken *cancelToken = [[DSHGitPushCancelToken alloc] init];
    @synchronized (self) {
      self.pushCancelTokens[projectId] = cancelToken;
    }
    int gitDescriptor = lease.gitDescriptor;
    __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *heldLease = lease;
    __attribute__((objc_precise_lifetime)) DSHGitPushRequest *pushRequest =
        [[DSHGitPushRequest alloc] init];
    pushRequest.repository = repository;
    pushRequest.remoteName = @"origin";
    pushRequest.remoteURL = origin;
    pushRequest.host = host;
    pushRequest.fullReference = fullReference;
    pushRequest.localOID = oid;
    pushRequest.username = credential[@"username"];
    pushRequest.token = credential[@"token"];
    pushRequest.proxyURL = proxyURL;
    pushRequest.cancelToken = cancelToken;
    pushRequest.timeout = LPPushTimeoutSeconds;
    pushRequest.completion = ^(DSHGitPushOutcome outcome, NSString *remoteOID) {
      (void)heldLease;
      if (outcome == DSHGitPushOutcomeSuccess && remoteOID.length > 0) {
        (void)DSHGitPushRecordReceipt(gitDescriptor, projectId,
            DSHGitPushReceipt(host, branch, oid, remoteOID, LPNow()), nil);
      }
    };
    DSHGitPushResult *pushResult = DSHGitPushRun(pushRequest);
    @synchronized (self) {
      if (self.pushCancelTokens[projectId] == cancelToken) {
        [self.pushCancelTokens removeObjectForKey:projectId];
      }
    }
    if (head != nullptr) git_reference_free(head);
    if (pushResult.outcome != DSHGitPushOutcomeSuccess ||
        ![self.projectAccessV2 validateWorkspaceLeaseIdentity:lease
                                                       rootRef:root
                                                         error:&error]) {
      switch (pushResult.outcome) {
        case DSHGitPushOutcomeNonFastForward:
          LPV2Reject(reject, LPError(3196, @"Remote rejected the push: not fast-forward"));
          return;
        case DSHGitPushOutcomeAuthFailure:
          LPV2Reject(reject, LPError(3197, @"Git credential was rejected by the remote"));
          return;
        case DSHGitPushOutcomeTimedOut:
          LPV2Reject(reject, LPError(3198, @"Push timed out"));
          return;
        case DSHGitPushOutcomeCancelled:
          LPV2Reject(reject, LPError(3195, @"Push was cancelled"));
          return;
        default:
          LPV2Reject(reject, error ?: LPError(3199, @"Git push failed"));
          return;
      }
    }
    resolve(@{
      @"schema_version" : @2,
      @"root" : root,
      @"project_id" : root[@"project_id"],
      @"remote" : @"origin",
      @"branch" : branch,
      @"oid" : expectedLocalOid,
      @"pushed_at" : LPNow(),
    });
  });
}

/// The V2 remote descriptor: `url` and `host` are null together when the
/// project has no origin. What JavaScript renders and what Android answers.
- (NSDictionary *)v2RemoteDescriptorForRoot:(NSDictionary *)root
                                     origin:(nullable NSString *)origin {
  NSString *host = origin == nil ? nil
      : [NSURLComponents componentsWithString:origin].host.lowercaseString;
  return @{
    @"schema_version" : @2,
    @"root" : root,
    @"project_id" : root[@"project_id"],
    @"remote" : LPRemoteName,
    @"url" : origin ?: NSNull.null,
    @"host" : host ?: NSNull.null,
  };
}

/// The V2 credential status: the v1 scope status with the root stamped on.
- (nullable NSDictionary *)v2CredentialStatusForRoot:(NSDictionary *)root
                                                host:(NSString *)host
                                               error:(NSError **)error {
  NSDictionary *status = [self credentialStatusForScope:root[@"project_id"]
                                                   host:host error:error];
  if (status == nil) return nil;
  NSMutableDictionary *stamped = [status mutableCopy];
  stamped[@"schema_version"] = @2;
  stamped[@"root"] = root;
  return stamped;
}

/// The origin of a V2 lease, as a validated URL string, or nil with 3112.
- (nullable NSString *)v2OriginForLease:(DSHLocalProjectLease *)lease
                                  error:(NSError **)error {
  NSError *originError = nil;
  NSString *origin = [self originURLForRepository:lease.repository error:&originError];
  if (origin == nil && error != nil) {
    *error = LPError(3112, @"Git remote is not configured");
  }
  return origin;
}

RCT_REMAP_METHOD(setRemoteV2,
                 setRemoteV2Request:(id)requestValue
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  NSDictionary *request = nil;
  NSError *validationError = nil;
  NSDictionary *root = nil;
  NSURL *remoteURL = nil;
  BOOL inputValid = NO;
  @try {
    request = LPDictionary(requestValue);
    root = LPV2Root(request[@"root"], YES, &validationError);
    remoteURL = LPValidatedRemoteURL(request[@"url"], &validationError);
    inputValid = LPV2ExactKeys(request, @[@"schema_version", @"root", @"url"]) &&
        [request[@"schema_version"] isEqual:@1] && root != nil && remoteURL != nil;
  } @catch (__unused NSException *exception) {
    validationError = LPError(3199, @"Git remote request is invalid");
  }
  if (!inputValid) {
    LPV2Reject(reject, remoteURL == nil && root != nil
        ? LPError(3101, @"Git remote URL is invalid")
        : (validationError ?: LPError(3101, @"Git remote request is invalid")));
    return;
  }
  dispatch_async(self.projectQueue, ^{ @autoreleasepool {
    NSError *error = nil;
    __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *lease = [self v2LeaseForRoot:root
                                                   mode:DSHLocalProjectAccessModeWrite
                                                  error:&error];
    if (lease == nil) {
      LPV2Reject(reject, error ?: LPError(3199, @"Git remote failed"));
      return;
    }
    git_repository *repository = lease.repository;
    git_remote *remote = nullptr;
    int result = git_remote_lookup(&remote, repository, LPRemoteName.UTF8String);
    if (result == GIT_ENOTFOUND) {
      result = git_remote_create(&remote, repository, LPRemoteName.UTF8String,
        remoteURL.absoluteString.UTF8String);
    } else if (result == 0) {
      git_remote_free(remote);
      remote = nullptr;
      result = git_remote_set_url(repository, LPRemoteName.UTF8String,
        remoteURL.absoluteString.UTF8String);
    }
    if (result == 0) {
      int clearPushURL = git_remote_set_pushurl(repository, LPRemoteName.UTF8String, nullptr);
      if (clearPushURL != 0 && clearPushURL != GIT_ENOTFOUND) result = clearPushURL;
    }
    if (remote != nullptr) git_remote_free(remote);
    NSString *storedURL = result == 0
      ? [self originURLForRepository:repository error:&error] : nil;
    BOOL valid = [storedURL isEqualToString:remoteURL.absoluteString] &&
        [self.projectAccessV2 validateWorkspaceLeaseIdentity:lease rootRef:root error:&error];
    lease = nil;
    if (!valid) {
      LPV2Reject(reject, error ?: LPError(3199, @"Origin remote cannot be updated"));
      return;
    }
    resolve([self v2RemoteDescriptorForRoot:root origin:storedURL]);
  } });
}

RCT_REMAP_METHOD(remoteV2,
                 remoteV2Request:(id)requestValue
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  NSDictionary *request = nil;
  NSError *validationError = nil;
  NSDictionary *root = nil;
  BOOL inputValid = NO;
  @try {
    request = LPDictionary(requestValue);
    root = LPV2Root(request[@"root"], YES, &validationError);
    inputValid = LPV2ExactKeys(request, @[@"schema_version", @"root"]) &&
        [request[@"schema_version"] isEqual:@1] && root != nil;
  } @catch (__unused NSException *exception) {
    validationError = LPError(3199, @"Git request is invalid");
  }
  if (!inputValid) {
    LPV2Reject(reject, validationError ?: LPError(3101, @"Git request is invalid"));
    return;
  }
  dispatch_async(self.projectQueue, ^{ @autoreleasepool {
    NSError *error = nil;
    __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *lease = [self v2LeaseForRoot:root
                                                   mode:DSHLocalProjectAccessModeRead
                                                  error:&error];
    if (lease == nil || ![self.projectAccessV2 validateWorkspaceLeaseIdentity:lease
                                                                        rootRef:root
                                                                          error:&error]) {
      LPV2Reject(reject, error ?: LPError(3199, @"Git remote failed"));
      return;
    }
    // No origin is an answer here, not a refusal: the panel asks before
    // anything is set.
    NSString *origin = [self originURLForRepository:lease.repository error:nil];
    lease = nil;
    resolve([self v2RemoteDescriptorForRoot:root origin:origin]);
  } });
}

RCT_REMAP_METHOD(credentialStatusV2,
                 credentialStatusV2Request:(id)requestValue
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  NSDictionary *request = nil;
  NSError *validationError = nil;
  NSDictionary *root = nil;
  BOOL inputValid = NO;
  @try {
    request = LPDictionary(requestValue);
    root = LPV2Root(request[@"root"], YES, &validationError);
    inputValid = LPV2ExactKeys(request, @[@"schema_version", @"root"]) &&
        [request[@"schema_version"] isEqual:@1] && root != nil;
  } @catch (__unused NSException *exception) {
    validationError = LPError(3199, @"Git request is invalid");
  }
  if (!inputValid) {
    LPV2Reject(reject, validationError ?: LPError(3101, @"Git request is invalid"));
    return;
  }
  dispatch_async(self.projectQueue, ^{ @autoreleasepool {
    NSError *error = nil;
    __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *lease = [self v2LeaseForRoot:root
                                                   mode:DSHLocalProjectAccessModeRead
                                                  error:&error];
    NSString *origin = lease == nil ? nil : [self v2OriginForLease:lease error:&error];
    NSString *host = origin == nil ? nil
        : [NSURLComponents componentsWithString:origin].host.lowercaseString;
    NSDictionary *status = host == nil ? nil
        : [self v2CredentialStatusForRoot:root host:host error:&error];
    BOOL valid = status != nil && [self.projectAccessV2
        validateWorkspaceLeaseIdentity:lease rootRef:root error:&error];
    lease = nil;
    if (!valid) {
      LPV2Reject(reject, error ?: LPError(3199, @"Git credential status failed"));
      return;
    }
    resolve(status);
  } });
}

RCT_REMAP_METHOD(presentCredentialPromptV2,
                 presentCredentialPromptV2Request:(id)requestValue
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  NSDictionary *request = nil;
  NSError *validationError = nil;
  NSDictionary *root = nil;
  NSString *locale = nil;
  BOOL inputValid = NO;
  @try {
    request = LPDictionary(requestValue);
    root = LPV2Root(request[@"root"], YES, &validationError);
    locale = LPString(request[@"locale"]);
    inputValid = LPV2ExactKeys(request, @[@"schema_version", @"root", @"locale"]) &&
        [request[@"schema_version"] isEqual:@1] && root != nil &&
        ([locale isEqualToString:@"zh-CN"] || [locale isEqualToString:@"en"]);
  } @catch (__unused NSException *exception) {
    validationError = LPError(3199, @"Git request is invalid");
  }
  if (!inputValid) {
    LPV2Reject(reject, validationError ?: LPError(3101, @"Git request is invalid"));
    return;
  }
  dispatch_async(self.projectQueue, ^{ @autoreleasepool {
    NSError *error = nil;
    __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *lease = [self v2LeaseForRoot:root
                                                   mode:DSHLocalProjectAccessModeRead
                                                  error:&error];
    NSString *origin = lease == nil ? nil : [self v2OriginForLease:lease error:&error];
    BOOL valid = origin != nil && [self.projectAccessV2 validateWorkspaceLeaseIdentity:lease
                                                                                 rootRef:root
                                                                                   error:&error];
    lease = nil;
    if (!valid) {
      LPV2Reject(reject, error ?: LPError(3199, @"Git credential prompt failed"));
      return;
    }
    NSString *host = [NSURLComponents componentsWithString:origin].host.lowercaseString;
    BOOL plaintext = DSHGitRemoteURLIsPlaintext([NSURL URLWithString:origin]);
    BOOL chinese = [locale isEqualToString:@"zh-CN"];
    LPCredentialPromptCompletion completion = ^(NSString *username,
                                                NSString *token,
                                                NSInteger expirySeconds,
                                                NSString *failureCode) {
      if (failureCode != nil || username == nil || token == nil) {
        LPV2Reject(reject, [failureCode isEqualToString:@"presentation"]
            ? LPError(3102, @"Git credential prompt cannot be presented right now")
            : LPError(3195, @"Git credential prompt was cancelled"));
        return;
      }
      dispatch_async(self.projectQueue, ^{ @autoreleasepool {
        // The origin is read again at save time so a remote changed under
        // the prompt does not receive a credential meant for another host.
        NSError *storeError = nil;
        __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *currentLease = [self v2LeaseForRoot:root
                                                              mode:DSHLocalProjectAccessModeRead
                                                             error:&storeError];
        NSString *currentOrigin = currentLease == nil ? nil
          : [self originURLForRepository:currentLease.repository error:&storeError];
        NSString *currentHost = [NSURLComponents
          componentsWithString:currentOrigin].host.lowercaseString;
        currentLease = nil;
        if (currentOrigin == nil || ![currentHost isEqualToString:host]) {
          LPV2Reject(reject, LPError(3113, @"Origin remote changed before credential save"));
          return;
        }
        if (!DSHGitStoreCredentialForScope(root[@"project_id"], host, username, token,
                                            expirySeconds, &storeError)) {
          LPV2Reject(reject, LPError(3101, @"Git credential is invalid"));
          return;
        }
        NSDictionary *status = [self v2CredentialStatusForRoot:root host:host
                                                          error:&storeError];
        if (status == nil) {
          LPV2Reject(reject, storeError ?: LPError(3199, @"Git credential status failed"));
          return;
        }
        resolve(status);
      } });
    };
    LPCredentialPromptHook hook = self.credentialPromptHook;
    if (hook != nil) {
      hook(host, chinese, plaintext, completion);
      return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      [self presentCredentialAlertForHost:host
                                  chinese:chinese
                                plaintext:plaintext
                               completion:completion];
    });
  } });
}

RCT_REMAP_METHOD(clearCredentialV2,
                 clearCredentialV2Request:(id)requestValue
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  NSDictionary *request = nil;
  NSError *validationError = nil;
  NSDictionary *root = nil;
  BOOL inputValid = NO;
  @try {
    request = LPDictionary(requestValue);
    root = LPV2Root(request[@"root"], YES, &validationError);
    inputValid = LPV2ExactKeys(request, @[@"schema_version", @"root"]) &&
        [request[@"schema_version"] isEqual:@1] && root != nil;
  } @catch (__unused NSException *exception) {
    validationError = LPError(3199, @"Git request is invalid");
  }
  if (!inputValid) {
    LPV2Reject(reject, validationError ?: LPError(3101, @"Git request is invalid"));
    return;
  }
  dispatch_async(self.projectQueue, ^{ @autoreleasepool {
    NSError *error = nil;
    __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *lease = [self v2LeaseForRoot:root
                                                   mode:DSHLocalProjectAccessModeRead
                                                  error:&error];
    NSString *origin = lease == nil ? nil : [self v2OriginForLease:lease error:&error];
    BOOL valid = origin != nil && [self.projectAccessV2 validateWorkspaceLeaseIdentity:lease
                                                                                 rootRef:root
                                                                                   error:&error];
    lease = nil;
    if (!valid) {
      LPV2Reject(reject, error ?: LPError(3199, @"Git credential clear failed"));
      return;
    }
    NSString *host = [NSURLComponents componentsWithString:origin].host.lowercaseString;
    NSString *projectId = root[@"project_id"];
    if (!DSHGitDeleteCredentialForScope(projectId, host, &error)) {
      LPV2Reject(reject, error ?: LPError(3199, @"Git credential clear failed"));
      return;
    }
    (void)DSHGitDeleteLegacyHostCredential(host, nil);
    NSDictionary *status = [self v2CredentialStatusForRoot:root host:host error:&error];
    if (status == nil) {
      LPV2Reject(reject, error ?: LPError(3199, @"Git credential status failed"));
      return;
    }
    resolve(status);
  } });
}

/// The fetch side of the remote half: the credential offered once and only
/// to its host, the cancel token polled from the transfer callback, no
/// redirects, no proxy. What `git fetch origin` needs and nothing more.
struct LPV2FetchState {
  NSString *__unsafe_unretained host;
  NSString *__unsafe_unretained username;
  NSString *__unsafe_unretained token;
  DSHGitPushCancelToken *__unsafe_unretained cancel;
  BOOL attempted;
};

static int LPV2FetchCredentialCallback(git_credential **out, const char *url,
                                       const char *usernameFromUrl,
                                       unsigned int allowedTypes, void *payload) {
  (void)usernameFromUrl;
  auto *state = static_cast<LPV2FetchState *>(payload);
  if (state == nullptr || state->attempted || state->token.length == 0 ||
      state->username.length == 0 || (allowedTypes & GIT_CREDENTIAL_USERPASS_PLAINTEXT) == 0) {
    return GIT_EAUTH;
  }
  // Stored for one host; a redirect that asks elsewhere gets nothing.
  NSString *asked = url == nullptr ? nil
      : [NSURLComponents componentsWithString:[NSString stringWithUTF8String:url]].host.lowercaseString;
  if (asked == nil || ![asked isEqualToString:state->host]) return GIT_EAUTH;
  state->attempted = YES;
  return git_credential_userpass_plaintext_new(out, state->username.UTF8String, state->token.UTF8String);
}

static int LPV2FetchProgress(const git_indexer_progress *stats, void *payload) {
  (void)stats;
  auto *state = static_cast<LPV2FetchState *>(payload);
  return state != nullptr && state->cancel != nil && state->cancel.cancelled ? GIT_EUSER : 0;
}

/// The origin as fetch and fast-forward may use it: a validated network URL
/// with its host, or an absolute local path with none (the native test
/// transport, as the agent's push allows). Anything else is nil.
static NSString *LPV2FetchOrigin(git_repository *repository, NSString **hostOut) {
  git_config *config = nullptr;
  git_buf value = GIT_BUF_INIT;
  int result = git_repository_config(&config, repository);
  if (result == 0) result = git_config_get_string_buf(&value, config, "remote.origin.url");
  NSString *raw = result == 0 && value.ptr != nullptr ? [NSString stringWithUTF8String:value.ptr] : nil;
  git_buf_dispose(&value);
  if (config != nullptr) git_config_free(config);
  NSURL *validated = LPValidatedRemoteURL(raw, nil);
  if (validated != nil) {
    if (hostOut != nullptr) *hostOut = validated.host.lowercaseString;
    return validated.absoluteString;
  }
  if ([raw hasPrefix:@"/"]) {
    if (hostOut != nullptr) *hostOut = nil;
    return raw;
  }
  return nil;
}

RCT_REMAP_METHOD(pushReceiptsV2,
                 pushReceiptsV2Request:(id)requestValue
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  NSDictionary *request = nil;
  NSError *validationError = nil;
  NSDictionary *root = nil;
  BOOL inputValid = NO;
  @try {
    request = LPDictionary(requestValue);
    root = LPV2Root(request[@"root"], YES, &validationError);
    inputValid = LPV2ExactKeys(request, @[@"schema_version", @"root"]) &&
        [request[@"schema_version"] isEqual:@1] && root != nil;
  } @catch (__unused NSException *exception) {
    validationError = LPError(3199, @"Git request is invalid");
  }
  if (!inputValid) {
    LPV2Reject(reject, validationError ?: LPError(3101, @"Git request is invalid"));
    return;
  }
  dispatch_async(self.projectQueue, ^{ @autoreleasepool {
    NSError *error = nil;
    __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *lease = [self v2LeaseForRoot:root
                                                   mode:DSHLocalProjectAccessModeRead
                                                  error:&error];
    NSString *projectId = root[@"project_id"];
    NSArray<NSDictionary *> *receipts = lease == nil ? nil
        : DSHGitPushLoadReceipts(lease.gitDescriptor, projectId, &error);
    BOOL valid = receipts != nil && [self.projectAccessV2 validateWorkspaceLeaseIdentity:lease
                                                                                  rootRef:root
                                                                                    error:&error];
    lease = nil;
    if (!valid) {
      LPV2Reject(reject, error ?: LPError(3199, @"Receipt storage is unavailable"));
      return;
    }
    // Sanitize before crossing the bridge: hosts, branch names, OIDs, and
    // timestamps only.
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *receipt in receipts) {
      [rows addObject:@{
        @"schema_version" : @1,
        @"remote" : receipt[@"remote"],
        @"host" : receipt[@"host"],
        @"branch" : receipt[@"branch"],
        @"local_oid" : receipt[@"local_oid"],
        @"remote_oid" : receipt[@"remote_oid"],
        @"pushed_at" : receipt[@"pushed_at"],
      }];
    }
    resolve(@{
      @"schema_version" : @2,
      @"root" : root,
      @"project_id" : projectId,
      @"receipts" : rows,
    });
  } });
}

RCT_REMAP_METHOD(fetchV2,
                 fetchV2Request:(id)requestValue
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  NSDictionary *request = nil;
  NSError *validationError = nil;
  NSDictionary *root = nil;
  NSString *operationId = nil;
  BOOL inputValid = NO;
  @try {
    request = LPDictionary(requestValue);
    root = LPV2Root(request[@"root"], YES, &validationError);
    operationId = LPString(request[@"operation_id"]);
    inputValid = LPV2ExactKeys(request, @[@"schema_version", @"root", @"operation_id", @"remote"]) &&
        [request[@"schema_version"] isEqual:@1] && root != nil &&
        LPV2CanonicalOperationId(operationId) && [request[@"remote"] isEqual:@"origin"];
  } @catch (__unused NSException *exception) {
    validationError = LPError(3199, @"Git fetch request is invalid");
  }
  if (!inputValid) {
    LPV2Reject(reject, validationError ?: LPError(3101, @"Git fetch request is invalid"));
    return;
  }
  dispatch_async(self.projectQueue, ^{ @autoreleasepool {
    NSError *error = nil;
    __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *lease = [self v2LeaseForRoot:root
                                                   mode:DSHLocalProjectAccessModeWrite
                                                  error:&error];
    if (lease == nil) {
      LPV2Reject(reject, error ?: LPError(3199, @"Git fetch failed"));
      return;
    }
    git_repository *repository = lease.repository;
    git_reference *head = nullptr;
    NSString *branch = nil;
    if (git_repository_head(&head, repository) == 0 && head != nullptr && git_reference_is_branch(head)) {
      const char *shorthand = git_reference_shorthand(head);
      if (shorthand != nullptr) branch = [NSString stringWithUTF8String:shorthand];
    }
    if (head != nullptr) git_reference_free(head);
    if (branch.length == 0) {
      lease = nil;
      LPV2Reject(reject, LPError(3110, @"No branch to fetch for"));
      return;
    }
    NSString *host = nil;
    NSString *origin = LPV2FetchOrigin(repository, &host);
    if (origin == nil) {
      lease = nil;
      LPV2Reject(reject, LPError(3112, @"Git remote is not configured"));
      return;
    }
    NSString *projectId = root[@"project_id"];
    NSDictionary *credential = host == nil ? nil : DSHGitCredentialForScope(projectId, host, nil);
    DSHGitPushCancelToken *cancelToken = [[DSHGitPushCancelToken alloc] init];
    @synchronized (self) {
      self.pushCancelTokens[projectId] = cancelToken;
    }
    LPV2FetchState state = {};
    state.host = host;
    state.username = credential[@"username"];
    state.token = credential[@"token"];
    state.cancel = cancelToken;
    state.attempted = NO;
    git_remote *remote = nullptr;
    int result = git_remote_lookup(&remote, repository, LPRemoteName.UTF8String);
    if (result == 0 && host != nil) result = git_remote_set_instance_url(remote, origin.UTF8String);
    git_fetch_options options = GIT_FETCH_OPTIONS_INIT;
    options.follow_redirects = GIT_REMOTE_REDIRECT_NONE;
    options.proxy_opts.type = GIT_PROXY_NONE;
    if (credential != nil) options.callbacks.credentials = LPV2FetchCredentialCallback;
    options.callbacks.transfer_progress = LPV2FetchProgress;
    options.callbacks.payload = &state;
    git_libgit2_opts(GIT_OPT_SET_SERVER_CONNECT_TIMEOUT, LPCloneConnectTimeoutMilliseconds);
    git_libgit2_opts(GIT_OPT_SET_SERVER_TIMEOUT, LPCloneIdleTimeoutMilliseconds);
    if (result == 0) result = git_remote_fetch(remote, nullptr, &options, "rish fetch");
    if (remote != nullptr) git_remote_free(remote);
    @synchronized (self) {
      if (self.pushCancelTokens[projectId] == cancelToken) {
        [self.pushCancelTokens removeObjectForKey:projectId];
      }
    }
    if (result != 0) {
      lease = nil;
      if (cancelToken.cancelled) LPV2Reject(reject, LPError(3195, @"Fetch was cancelled"));
      else if (result == GIT_EAUTH) LPV2Reject(reject, LPError(3197, @"Git credential was rejected by the remote"));
      else LPV2Reject(reject, LPError(3199, @"Git fetch failed"));
      return;
    }
    // What the remote holds for this branch, and where the local branch
    // stands against it. The upstream is set the first time the remote has
    // the branch, so the panel's ahead/behind count from then on.
    NSString *remoteOid = nil;
    size_t ahead = 0;
    size_t behind = 0;
    NSString *trackingName = [@"refs/remotes/origin/" stringByAppendingString:branch];
    git_reference *tracking = nullptr;
    git_reference *local = nullptr;
    if (git_reference_lookup(&tracking, repository, trackingName.UTF8String) == 0 && tracking != nullptr) {
      const git_oid *remoteTarget = git_reference_target(tracking);
      if (remoteTarget != nullptr) remoteOid = LPOidString(remoteTarget);
      if (git_branch_lookup(&local, repository, branch.UTF8String, GIT_BRANCH_LOCAL) == 0 && local != nullptr) {
        git_reference *upstream = nullptr;
        if (git_branch_upstream(&upstream, local) != 0) {
          (void)git_branch_set_upstream(local, [@"origin/" stringByAppendingString:branch].UTF8String);
        } else if (upstream != nullptr) {
          git_reference_free(upstream);
        }
        const git_oid *localTarget = git_reference_target(local);
        if (localTarget != nullptr && remoteTarget != nullptr) {
          git_graph_ahead_behind(&ahead, &behind, repository, localTarget, remoteTarget);
        }
      }
    }
    if (local != nullptr) git_reference_free(local);
    if (tracking != nullptr) git_reference_free(tracking);
    BOOL valid = [self.projectAccessV2 validateWorkspaceLeaseIdentity:lease rootRef:root error:&error];
    lease = nil;
    if (!valid) {
      LPV2Reject(reject, error ?: LPError(3199, @"Git fetch failed"));
      return;
    }
    resolve(@{
      @"schema_version" : @2,
      @"root" : root,
      @"project_id" : projectId,
      @"remote" : LPRemoteName,
      @"branch" : branch,
      @"remote_oid" : remoteOid ?: NSNull.null,
      @"ahead" : @((unsigned long long)ahead),
      @"behind" : @((unsigned long long)behind),
      @"fetched_at" : LPNow(),
    });
  } });
}

RCT_REMAP_METHOD(pullFastForwardV2,
                 pullFastForwardV2Request:(id)requestValue
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  NSDictionary *request = nil;
  NSError *validationError = nil;
  NSDictionary *root = nil;
  NSString *expected = nil;
  BOOL inputValid = NO;
  @try {
    request = LPDictionary(requestValue);
    root = LPV2Root(request[@"root"], YES, &validationError);
    expected = LPString(request[@"expected_head_oid"]);
    inputValid = LPV2ExactKeys(request, @[@"schema_version", @"root", @"expected_head_oid"]) &&
        [request[@"schema_version"] isEqual:@1] && root != nil && LPV2CanonicalOID(expected, NO);
  } @catch (__unused NSException *exception) {
    validationError = LPError(3199, @"Git pull request is invalid");
  }
  if (!inputValid) {
    LPV2Reject(reject, validationError ?: LPError(3101, @"Git pull request is invalid"));
    return;
  }
  dispatch_async(self.projectQueue, ^{ @autoreleasepool {
    NSError *error = nil;
    __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *lease = [self v2LeaseForRoot:root
                                                   mode:DSHLocalProjectAccessModeWrite
                                                  error:&error];
    if (lease == nil) {
      LPV2Reject(reject, error ?: LPError(3199, @"Git pull failed"));
      return;
    }
    git_repository *repository = lease.repository;
    // A fast-forward of the current branch to origin/<branch>, and nothing
    // else: never a merge, never over changes to tracked files, never past a
    // HEAD other than the one the caller reviewed.
    git_reference *head = nullptr;
    git_reference *tracking = nullptr;
    git_commit *commit = nullptr;
    git_status_list *list = nullptr;
    git_reference *updated = nullptr;
    NSError *failure = nil;
    NSDictionary *answer = nil;
    do {
      if (git_repository_head(&head, repository) != 0 || head == nullptr || !git_reference_is_branch(head) ||
          git_reference_target(head) == nullptr) {
        failure = LPError(3110, @"Git HEAD changed");
        break;
      }
      NSString *previous = LPOidString(git_reference_target(head));
      if (![previous isEqualToString:expected]) { failure = LPError(3110, @"Git HEAD changed"); break; }
      const char *shorthand = git_reference_shorthand(head);
      NSString *branch = shorthand == nullptr ? @"" : [NSString stringWithUTF8String:shorthand];
      NSString *trackingName = [@"refs/remotes/origin/" stringByAppendingString:branch];
      if (git_reference_lookup(&tracking, repository, trackingName.UTF8String) != 0 || tracking == nullptr ||
          git_reference_target(tracking) == nullptr) {
        failure = LPError(3112, @"Nothing fetched for this branch");
        break;
      }
      const git_oid *remoteTarget = git_reference_target(tracking);
      size_t ahead = 0;
      size_t behind = 0;
      if (git_graph_ahead_behind(&ahead, &behind, repository, git_reference_target(head), remoteTarget) != 0) {
        failure = LPError(3199, @"Git pull failed");
        break;
      }
      NSDictionary *(^result)(NSString *, BOOL) = ^NSDictionary *(NSString *oid, BOOL moved) {
        return @{
          @"schema_version" : @2, @"root" : root, @"project_id" : root[@"project_id"],
          @"branch" : branch, @"oid" : oid, @"previous_oid" : previous, @"updated" : @(moved),
        };
      };
      if (behind == 0) { answer = result(previous, NO); break; }
      if (ahead > 0) { failure = LPError(3196, @"Local and remote histories diverged"); break; }
      git_status_options statusOptions = GIT_STATUS_OPTIONS_INIT;
      statusOptions.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR;
      statusOptions.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS;
      if (git_status_list_new(&list, repository, &statusOptions) != 0) { failure = LPError(3199, @"Git pull failed"); break; }
      BOOL dirty = NO;
      const size_t count = git_status_list_entrycount(list);
      for (size_t index = 0; index < count && !dirty; index += 1) {
        const git_status_entry *entry = git_status_byindex(list, index);
        if (entry != nullptr && (entry->status & ~GIT_STATUS_WT_NEW) != 0) dirty = YES;
      }
      if (dirty) { failure = LPError(3110, @"Working tree has changes"); break; }
      if (git_commit_lookup(&commit, repository, remoteTarget) != 0) { failure = LPError(3199, @"Git pull failed"); break; }
      git_checkout_options checkout = GIT_CHECKOUT_OPTIONS_INIT;
      // SAFE protects tracked changes and untracked files but not ignored
      // ones: an incoming commit that starts tracking a path ignored here --
      // a local config, a secrets file -- was written straight over it, and
      // the cleanliness check never saw it because status does not list
      // ignored files. DONT_OVERWRITE_IGNORED makes that a checkout conflict.
      checkout.checkout_strategy =
          GIT_CHECKOUT_SAFE | GIT_CHECKOUT_DONT_OVERWRITE_IGNORED;
      const int checkedOut = git_checkout_tree(repository, reinterpret_cast<const git_object *>(commit), &checkout);
      if (checkedOut == GIT_ECONFLICT) { failure = LPError(3110, @"Working tree has changes"); break; }
      if (checkedOut != 0) { failure = LPError(3199, @"Git pull failed"); break; }
      if (git_reference_set_target(&updated, head, remoteTarget, "rish fast-forward") != 0) {
        failure = LPError(3199, @"Git pull failed");
        break;
      }
      answer = result(LPOidString(remoteTarget), YES);
    } while (false);
    if (updated != nullptr) git_reference_free(updated);
    if (list != nullptr) git_status_list_free(list);
    if (commit != nullptr) git_commit_free(commit);
    if (tracking != nullptr) git_reference_free(tracking);
    if (head != nullptr) git_reference_free(head);
    BOOL valid = answer != nil && [self.projectAccessV2 validateWorkspaceLeaseIdentity:lease rootRef:root error:&error];
    lease = nil;
    if (!valid) {
      LPV2Reject(reject, failure ?: error ?: LPError(3199, @"Git pull failed"));
      return;
    }
    resolve(answer);
  } });
}

RCT_REMAP_METHOD(cancelPushV2,
                 cancelPushV2Request:(id)requestValue
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
  // Not queued on projectQueue: the in-flight push blocks that queue while
  // polling the cancel token. The token is the project's; the operation id
  // is echoed so the caller can match the answer to the push it meant.
  NSDictionary *request = nil;
  NSError *validationError = nil;
  NSDictionary *root = nil;
  NSString *operationId = nil;
  BOOL inputValid = NO;
  @try {
    request = LPDictionary(requestValue);
    root = LPV2Root(request[@"root"], YES, &validationError);
    operationId = LPString(request[@"operation_id"]);
    inputValid = LPV2ExactKeys(request, @[@"schema_version", @"root", @"operation_id"]) &&
        [request[@"schema_version"] isEqual:@1] && root != nil &&
        LPV2CanonicalOperationId(operationId);
  } @catch (__unused NSException *exception) {
    validationError = LPError(3199, @"Cancel request is invalid");
  }
  if (!inputValid) {
    LPV2Reject(reject, validationError ?: LPError(3101, @"Cancel request is invalid"));
    return;
  }
  NSString *projectId = root[@"project_id"];
  DSHGitPushCancelToken *token = nil;
  @synchronized (self) {
    token = self.pushCancelTokens[projectId];
  }
  if (token != nil) [token cancel];
  resolve(@{
    @"schema_version" : @2,
    @"root" : root,
    @"project_id" : projectId,
    @"operation_id" : operationId,
    @"status" : token != nil ? @"cancel_requested" : @"not_running",
  });
}

@end
