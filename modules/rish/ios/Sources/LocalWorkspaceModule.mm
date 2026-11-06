#import <Foundation/Foundation.h>
#import <RishNative/RishNativeModule.h>
#import <CommonCrypto/CommonDigest.h>

#include "rish_agent_core.h"

#import "LocalProjectAccess.h"
#import "LocalWorkspaceAccess.h"
#import "LegacyBoundProjectRootAccess.h"

#include "rish.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static const NSUInteger LWMaxPathBytes = 1024;
static const NSUInteger LWMaxTextBytes = 1024 * 1024;
static const NSUInteger LWMaxListEntries = 1000;
static const NSUInteger LWMaxTreeEntries = 10000;
static const NSUInteger LWMaxTreeDepth = 64;
static const NSUInteger LWMaxToolOutputBytes = 256 * 1024;
static const unsigned long long LWMaxSafeInteger = 9007199254740991ULL;

@interface DSHLocalWorkspaceAccess (LWLegacyBoundPrivate)
- (BOOL)ensurePrivateLayoutLocked:(NSError **)error;
- (nullable NSDictionary *)loadRegistry:(NSError **)error
                                  digest:(NSString *_Nullable *_Nullable)digest;
- (nullable NSDictionary *)recordInRegistry:(NSDictionary *)registry
                                  workspaceId:(NSString *)workspaceId;
- (nullable NSDictionary *)loadAuthorityForRecord:(NSDictionary *)record
                                             error:(NSError **)error;
- (nullable NSSet<NSString *> *)verifiedLegacyCapabilitiesForRecord:
    (NSDictionary *)record authority:(NSDictionary *)authority;
@end

@interface DSHLocalWorkspaceAuthorityMutationGuard (LWLegacyBoundPrivate)
@property(nonatomic, weak, readonly) DSHLocalWorkspaceAccess *owner;
@end

static NSError *LWError(DSHLocalWorkspaceAccessErrorCode code) {
  NSString *publicCode = nil;
  NSString *message = nil;
  switch (code) {
    case DSHLocalWorkspaceAccessErrorInvalid: publicCode = @"E_WORKSPACE_INVALID"; message = @"Workspace request is invalid."; break;
    case DSHLocalWorkspaceAccessErrorNotFound: publicCode = @"E_WORKSPACE_NOT_FOUND"; message = @"Workspace is not available."; break;
    case DSHLocalWorkspaceAccessErrorBusy: publicCode = @"E_WORKSPACE_BUSY"; message = @"Workspace storage is busy."; break;
    case DSHLocalWorkspaceAccessErrorPickerBusy: publicCode = @"E_WORKSPACE_PICKER_BUSY"; message = @"Another workspace picker operation is active."; break;
    case DSHLocalWorkspaceAccessErrorSelectionExpired: publicCode = @"E_WORKSPACE_SELECTION_EXPIRED"; message = @"Workspace picker selection has expired."; break;
    case DSHLocalWorkspaceAccessErrorRevisionStale: publicCode = @"E_WORKSPACE_REVISION_STALE"; message = @"Workspace binding is stale."; break;
    case DSHLocalWorkspaceAccessErrorRevisionOverflow: publicCode = @"E_WORKSPACE_REVISION_OVERFLOW"; message = @"Workspace binding cannot be advanced."; break;
    case DSHLocalWorkspaceAccessErrorStatusStale: publicCode = @"E_WORKSPACE_STATUS_STALE"; message = @"Workspace authority is stale."; break;
    case DSHLocalWorkspaceAccessErrorRevoked: publicCode = @"E_WORKSPACE_REVOKED"; message = @"Workspace authority was revoked."; break;
    case DSHLocalWorkspaceAccessErrorUnavailable: publicCode = @"E_WORKSPACE_UNAVAILABLE"; message = @"Workspace is unavailable."; break;
    case DSHLocalWorkspaceAccessErrorNotDownloaded: publicCode = @"E_WORKSPACE_NOT_DOWNLOADED"; message = @"Workspace content is not downloaded."; break;
    case DSHLocalWorkspaceAccessErrorImportRequired: publicCode = @"E_WORKSPACE_IMPORT_REQUIRED"; message = @"Workspace import is required."; break;
    case DSHLocalWorkspaceAccessErrorCapability: publicCode = @"E_WORKSPACE_CAPABILITY"; message = @"Workspace capability is unavailable."; break;
    case DSHLocalWorkspaceAccessErrorRootChanged: publicCode = @"E_WORKSPACE_ROOT_CHANGED"; message = @"Workspace root changed."; break;
    case DSHLocalWorkspaceAccessErrorReferenced: publicCode = @"E_WORKSPACE_REFERENCED"; message = @"Workspace is still referenced."; break;
    case DSHLocalWorkspaceAccessErrorConfirmation: publicCode = @"E_WORKSPACE_CONFIRMATION"; message = @"Workspace confirmation is invalid."; break;
    case DSHLocalWorkspaceAccessErrorConflict: publicCode = @"E_WORKSPACE_CONFLICT"; message = @"Workspace storage changed concurrently."; break;
    case DSHLocalWorkspaceAccessErrorPersistence: publicCode = @"E_WORKSPACE_PERSISTENCE"; message = @"Workspace storage is invalid."; break;
    case DSHLocalWorkspaceAccessErrorIO: publicCode = @"E_WORKSPACE_IO"; message = @"Workspace operation failed."; break;
  }
  if (publicCode == nil) {
    publicCode = @"E_WORKSPACE_UNAVAILABLE";
    message = @"Workspace is unavailable.";
    code = DSHLocalWorkspaceAccessErrorUnavailable;
  }
  return [NSError errorWithDomain:DSHLocalWorkspaceAccessErrorDomain
                              code:code
                          userInfo:@{ @"code": publicCode,
                                      NSLocalizedDescriptionKey: message }];
}

static void LWSetError(NSError **error, DSHLocalWorkspaceAccessErrorCode code) {
  if (error != nil) *error = LWError(code);
}

static NSError *LWWorkspaceRootError(NSError *error) {
  if ([error.domain isEqual:DSHLocalWorkspaceAccessErrorDomain] &&
      (error.code == DSHLocalWorkspaceAccessErrorUnavailable ||
       error.code == DSHLocalWorkspaceAccessErrorStatusStale ||
       error.code == DSHLocalWorkspaceAccessErrorRootChanged)) {
    return LWError(DSHLocalWorkspaceAccessErrorRootChanged);
  }
  return error ?: LWError(DSHLocalWorkspaceAccessErrorRootChanged);
}

static NSError *LWProjectRelationError(NSError *error) {
  if ([error.domain isEqual:DSHLocalWorkspaceAccessErrorDomain]) {
    return LWWorkspaceRootError(error);
  }
  if ([error.domain isEqual:DSHLocalProjectAccessErrorDomain] &&
      error.code == DSHLocalProjectAccessErrorInvalidIdentifier) {
    return LWError(DSHLocalWorkspaceAccessErrorInvalid);
  }
  if ([error.domain isEqual:DSHLocalProjectAccessErrorDomain] &&
      error.code == DSHLocalProjectAccessErrorLockTimeout) {
    return LWError(DSHLocalWorkspaceAccessErrorBusy);
  }
  return LWError(DSHLocalWorkspaceAccessErrorRootChanged);
}

// Which code and message a workspace failure is reported as lives in the
// shared core (modules/rish/core, `rish_agent_workspace_error_reduce`). This
// file used to carry a third copy of that table, after LocalWorkspaceAccess
// and the core itself.
static NSDictionary *LWErrorProjection(NSInteger code) {
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:@{
    @"op" : @"projection",
    @"code" : @((unsigned long long)code),
  } options:0 error:nil];
  char *raw = bytes == nil ? NULL : rish_agent_workspace_error_reduce(
      (const char *)bytes.bytes, bytes.length);
  if (raw == NULL) return nil;
  NSData *replyBytes = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  id reply = [NSJSONSerialization JSONObjectWithData:replyBytes options:0
                                                error:nil];
  if (![reply isKindOfClass:NSDictionary.class] ||
      ![reply[@"ok"] isEqual:@YES]) {
    return nil;
  }
  id projection = reply[@"projection"];
  return [projection isKindOfClass:NSDictionary.class] ? projection : nil;
}

static NSString *LWStableCode(NSError *error) {
  // An error that already carries a public code keeps it: it came from a layer
  // that had already made this decision.
  NSString *code = [error.userInfo[@"code"] isKindOfClass:NSString.class]
      ? error.userInfo[@"code"] : nil;
  if (code != nil) return code;
  NSDictionary *projection = LWErrorProjection(error.code);
  return projection[@"code"] ?: @"E_WORKSPACE_UNAVAILABLE";
}

static NSString *LWMessageForCode(NSString *code) {
  for (NSUInteger number = 1; number <= 19; number += 1) {
    NSDictionary *projection = LWErrorProjection((NSInteger)number);
    if ([projection[@"code"] isEqual:code]) return projection[@"message"];
  }
  return @"Workspace is unavailable.";
}

static BOOL LWIsBooleanNumber(id value) {
  return [value isKindOfClass:NSNumber.class] &&
      CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static BOOL LWIsSafeInteger(id value, BOOL allowZero) {
  if (![value isKindOfClass:NSNumber.class] || LWIsBooleanNumber(value)) return NO;
  double number = [value doubleValue];
  return isfinite(number) && floor(number) == number && number >= 0 &&
      number <= (double)LWMaxSafeInteger && (allowZero || number > 0) &&
      !(number == 0 && signbit(number));
}

static BOOL LWSchemaOne(id value) {
  return [value isKindOfClass:NSNumber.class] && !LWIsBooleanNumber(value) && [value isEqual:@1];
}

static BOOL LWExact(NSDictionary *value, NSArray<NSString *> *keys) {
  if (![value isKindOfClass:NSDictionary.class] || value.count != keys.count) return NO;
  NSSet *allowed = [NSSet setWithArray:keys];
  for (id key in value) {
    if (![key isKindOfClass:NSString.class] || ![allowed containsObject:key]) return NO;
  }
  return YES;
}

static BOOL LWUUID(id value) {
  if (![value isKindOfClass:NSString.class]) return NO;
  NSString *string = value;
  NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:
      @"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
                                                                            options:0 error:nil];
  NSRange full = NSMakeRange(0, string.length);
  NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:string];
  return [regex firstMatchInString:string options:0 range:full] != nil && uuid != nil &&
      [uuid.UUIDString.lowercaseString isEqual:string];
}

static BOOL LWDigest(id value) {
  if (![value isKindOfClass:NSString.class] || [value length] != 64) return NO;
  NSString *string = value;
  NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^[0-9a-f]{64}$" options:0 error:nil];
  return [regex firstMatchInString:string options:0 range:NSMakeRange(0, string.length)] != nil;
}

static NSDictionary *LWReadToolsReduce(NSString *op, NSDictionary *fields) {
  NSMutableDictionary *envelope = [fields mutableCopy];
  envelope[@"op"] = op;
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:envelope options:0
                                                    error:nil];
  char *raw = bytes == nil ? NULL : rish_agent_workspace_read_tools_reduce(
      (const char *)bytes.bytes, bytes.length);
  if (raw == NULL) return nil;
  NSData *replyBytes = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  id reply = [NSJSONSerialization JSONObjectWithData:replyBytes options:0
                                                error:nil];
  return [reply isKindOfClass:NSDictionary.class] &&
      [reply[@"ok"] isEqual:@YES] ? reply : nil;
}

static BOOL LWToolOptionsValid(NSDictionary *options) {
  return [LWReadToolsReduce(@"tool_options_valid", @{
    @"options" : [options isKindOfClass:NSDictionary.class] ? options
                                                            : NSNull.null,
  })[@"valid"] isEqual:@YES];
}

static BOOL LWToolNameValid(NSString *tool) {
  return [LWReadToolsReduce(@"tool_name_valid", @{
    @"value" : tool ?: NSNull.null,
  })[@"valid"] isEqual:@YES];
}

static NSData *LWBytesFromArray(id value) {
  if (![value isKindOfClass:NSArray.class] || [value count] > LWMaxToolOutputBytes) return nil;
  NSMutableData *data = [NSMutableData dataWithCapacity:[value count]];
  for (id item in (NSArray *)value) {
    if (!LWIsSafeInteger(item, YES) || [item unsignedIntegerValue] > UINT8_MAX) return nil;
    uint8_t byte = (uint8_t)[item integerValue];
    [data appendBytes:&byte length:1];
  }
  return data;
}

static NSArray<NSString *> *LWToolArguments(NSString *tool,
                                             NSDictionary *options,
                                             NSError **error) {
  if (!LWToolNameValid(tool) || !LWToolOptionsValid(options)) {
    LWSetError(error, DSHLocalWorkspaceAccessErrorInvalid);
    return nil;
  }
  NSString *operand = @"./input";
  if ([tool isEqual:@"cat"] || [tool isEqual:@"sha256sum"]) {
    if (options.count != 0) {
      LWSetError(error, DSHLocalWorkspaceAccessErrorInvalid);
      return nil;
    }
    return @[operand];
  }
  if ([tool isEqual:@"head"] || [tool isEqual:@"tail"]) {
    NSNumber *lines = options[@"lines"] ?: @40;
    return @[@"-n", lines.stringValue, operand];
  }
  if ([tool isEqual:@"wc"]) {
    NSString *metric = options[@"metric"] ?: @"lines";
    NSString *flag = @{ @"lines": @"-l", @"words": @"-w", @"bytes": @"-c" }[metric];
    if (flag == nil) {
      LWSetError(error, DSHLocalWorkspaceAccessErrorInvalid);
      return nil;
    }
    return @[flag, operand];
  }
  NSString *pattern = options[@"pattern"];
  if (pattern.length == 0) {
    LWSetError(error, DSHLocalWorkspaceAccessErrorInvalid);
    return nil;
  }
  return [options[@"case_insensitive"] boolValue]
      ? @[@"-F", @"-i", @"-n", @"--", pattern, operand]
      : @[@"-F", @"-n", @"--", pattern, operand];
}

static NSString *LWTimestamp(struct stat metadata) {
  NSDate *date = [NSDate dateWithTimeIntervalSince1970:
      metadata.st_mtimespec.tv_sec + metadata.st_mtimespec.tv_nsec / 1000000000.0];
  static NSISO8601DateFormatter *formatter = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                              NSISO8601DateFormatWithFractionalSeconds;
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
  });
  return [formatter stringFromDate:date];
}

static NSString *LWNow(void) {
  struct stat metadata = {};
  struct timespec now = {};
  clock_gettime(CLOCK_REALTIME, &now);
  metadata.st_mtimespec = now;
  return LWTimestamp(metadata);
}

static NSString *LWRevision(struct stat metadata) {
  int64_t fields[] = {
    (int64_t)metadata.st_dev, (int64_t)metadata.st_ino,
    (int64_t)metadata.st_mode,
    (int64_t)metadata.st_size, (int64_t)metadata.st_mtimespec.tv_sec,
    (int64_t)metadata.st_mtimespec.tv_nsec,
    (int64_t)metadata.st_ctimespec.tv_sec,
    (int64_t)metadata.st_ctimespec.tv_nsec,
  };
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(fields, (CC_LONG)sizeof(fields), digest);
  NSMutableString *result = [NSMutableString stringWithCapacity:64];
  for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index += 1) {
    [result appendFormat:@"%02x", digest[index]];
  }
  return result;
}

static BOOL LWSameFileState(struct stat left, struct stat right) {
  return left.st_dev == right.st_dev && left.st_ino == right.st_ino &&
      left.st_mode == right.st_mode && left.st_size == right.st_size &&
      left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec &&
      left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec;
}

static BOOL LWStatAtMatches(int directory, NSString *name, struct stat expected,
                            struct stat *actualOut) {
  struct stat actual = {};
  if (fstatat(directory, name.fileSystemRepresentation, &actual,
              AT_SYMLINK_NOFOLLOW) != 0 || !LWSameFileState(actual, expected) ||
      (S_ISREG(actual.st_mode) && actual.st_nlink != 1)) {
    return NO;
  }
  if (actualOut != nullptr) *actualOut = actual;
  return YES;
}

static BOOL LWStatAtRawMatches(int directory, NSString *name, struct stat expected,
                               struct stat *actualOut) {
  struct stat actual = {};
  if (fstatat(directory, name.fileSystemRepresentation, &actual,
              AT_SYMLINK_NOFOLLOW) != 0 || !LWSameFileState(actual, expected)) {
    return NO;
  }
  if (actualOut != nullptr) *actualOut = actual;
  return YES;
}

/*
 * RENAME_SWAP is the only safe rollback primitive for an overwrite: verify
 * both names still contain the exact inodes observed by the operation, swap
 * them back, then verify the restored name and staged replacement.  An
 * unchecked replacement would turn a stale-name race into data loss.
 */
static BOOL LWSafeSwapBack(int directory,
                           NSString *destination,
                           NSString *backup,
                           struct stat expectedDestination,
                           struct stat expectedBackup) {
  if (!LWStatAtMatches(directory, destination, expectedDestination, nullptr) ||
      !LWStatAtMatches(directory, backup, expectedBackup, nullptr)) return NO;
  if (renameatx_np(directory, destination.fileSystemRepresentation,
                   directory, backup.fileSystemRepresentation, RENAME_SWAP) != 0) return NO;
  return LWStatAtMatches(directory, destination, expectedBackup, nullptr) &&
      LWStatAtMatches(directory, backup, expectedDestination, nullptr);
}

/* Restore a target that lost the CAS race while retaining the inode which
 * won the name.  This protects an external replacement from being discarded
 * merely because our post-swap verification observed the wrong old inode. */
static BOOL LWRestoreSwapToObservedBackup(int directory,
                                          NSString *destination,
                                          NSString *backup,
                                          struct stat expectedDestination) {
  struct stat observedBackup = {};
  if (fstatat(directory, backup.fileSystemRepresentation, &observedBackup,
              AT_SYMLINK_NOFOLLOW) != 0 ||
      !LWStatAtMatches(directory, destination, expectedDestination, nullptr)) return NO;
  if (renameatx_np(directory, destination.fileSystemRepresentation,
                   directory, backup.fileSystemRepresentation, RENAME_SWAP) != 0) return NO;
  return LWStatAtRawMatches(directory, destination, observedBackup, nullptr) &&
      LWStatAtMatches(directory, backup, expectedDestination, nullptr);
}

/* Undo an EXCL move without assuming the destination still contains our
 * source inode.  The observed destination inode is moved back only while the
 * source name is absent, preserving a concurrent replacement instead of
 * silently deleting it. */
static BOOL LWRestoreMoveToObservedSource(int sourceDirectory,
                                          NSString *source,
                                          int destinationDirectory,
                                          NSString *destination) {
  struct stat observed = {};
  if (fstatat(destinationDirectory, destination.fileSystemRepresentation,
              &observed, AT_SYMLINK_NOFOLLOW) != 0) return NO;
  struct stat sourceState = {};
  if (fstatat(sourceDirectory, source.fileSystemRepresentation, &sourceState,
              AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT) return NO;
  if (renameatx_np(destinationDirectory, destination.fileSystemRepresentation,
                   sourceDirectory, source.fileSystemRepresentation, RENAME_EXCL) != 0) return NO;
  return LWStatAtRawMatches(sourceDirectory, source, observed, nullptr) &&
      (fstatat(destinationDirectory, destination.fileSystemRepresentation,
               &sourceState, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT);
}

static BOOL LWPathName(NSString *component) {
  if (![component isKindOfClass:NSString.class] || component.length == 0 ||
      [component lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > NAME_MAX ||
      [component isEqual:@"."] || [component isEqual:@".."] ||
      [component containsString:@"\\"] ||
      [component rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return NO;
  NSString *folded = component.lowercaseString;
  return ![folded isEqual:@".git"] && ![folded isEqual:@".trash"] &&
      ![folded hasPrefix:@".staging-"] && ![folded hasPrefix:@".rish-write-"];
}

static NSArray<NSString *> *LWComponents(id value, BOOL allowRoot, NSError **error) {
  NSString *path = [value isKindOfClass:NSString.class] ? value : nil;
  if (path == nil || [path lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > LWMaxPathBytes ||
      [path hasPrefix:@"/"] || [path containsString:@"\\"] ||
      [path rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) {
    LWSetError(error, DSHLocalWorkspaceAccessErrorInvalid);
    return nil;
  }
  if (path.length == 0) {
    if (allowRoot) return @[];
    LWSetError(error, DSHLocalWorkspaceAccessErrorInvalid);
    return nil;
  }
  NSArray<NSString *> *components = [path componentsSeparatedByString:@"/"];
  for (NSString *component in components) {
    if (!LWPathName(component)) {
      LWSetError(error, DSHLocalWorkspaceAccessErrorInvalid);
      return nil;
    }
  }
  return components;
}

static NSDictionary *LWRootFromRequest(NSDictionary *request, NSError **error) {
  NSDictionary *root = [request[@"root"] isKindOfClass:NSDictionary.class] ? request[@"root"] : nil;
  if (!LWExact(root, @[@"schema_version", @"workspace_id", @"binding_revision", @"project_id"]) ||
      ![root[@"schema_version"] isKindOfClass:NSNumber.class] || LWIsBooleanNumber(root[@"schema_version"]) ||
      ![root[@"schema_version"] isEqual:@1] || !LWUUID(root[@"workspace_id"]) ||
      !LWIsSafeInteger(root[@"binding_revision"], NO) ||
      !(root[@"project_id"] == NSNull.null || LWUUID(root[@"project_id"]))) {
    LWSetError(error, DSHLocalWorkspaceAccessErrorInvalid);
    return nil;
  }
  return @{
    @"schema_version": @1,
    @"workspace_id": root[@"workspace_id"],
    @"binding_revision": root[@"binding_revision"],
    @"project_id": root[@"project_id"],
  };
}

static BOOL LWWriteAll(int descriptor, NSData *data) {
  const uint8_t *bytes = (const uint8_t *)data.bytes;
  NSUInteger offset = 0;
  while (offset < data.length) {
    ssize_t written = write(descriptor, bytes + offset, data.length - offset);
    if (written < 0 && errno == EINTR) continue;
    if (written <= 0) return NO;
    offset += (NSUInteger)written;
  }
  return YES;
}

static BOOL LWPathName(NSString *component);

static void LWRemoveToolStaging(NSURL *staging) {
  if (staging == nil) return;
  int descriptor = open(staging.fileSystemRepresentation,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (descriptor < 0) return;
  struct stat input = {};
  if (fstatat(descriptor, "input", &input, AT_SYMLINK_NOFOLLOW) == 0 &&
      S_ISREG(input.st_mode) && input.st_nlink == 1) {
    (void)unlinkat(descriptor, "input", 0);
  }
  (void)fsync(descriptor);
  close(descriptor);
  (void)rmdir(staging.fileSystemRepresentation);
}

static BOOL LWValidTree(int descriptor, NSUInteger depth, NSUInteger *count) {
  if (depth > LWMaxTreeDepth) return NO;
  int duplicate = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (duplicate < 0) return NO;
  DIR *directory = fdopendir(duplicate);
  if (directory == nullptr) { close(duplicate); return NO; }
  struct dirent *entry = nullptr;
  BOOL valid = YES;
  while (valid) {
    errno = 0;
    entry = readdir(directory);
    if (entry == nullptr) { valid = errno == 0; break; }
    if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
    *count += 1;
    if (*count > LWMaxTreeEntries) { valid = NO; break; }
    NSString *name = [NSString stringWithUTF8String:entry->d_name];
    if (name == nil || !LWPathName(name)) { valid = NO; break; }
    struct stat metadata = {};
    if (fstatat(descriptor, entry->d_name, &metadata, AT_SYMLINK_NOFOLLOW) != 0 ||
        S_ISLNK(metadata.st_mode) || (!S_ISREG(metadata.st_mode) && !S_ISDIR(metadata.st_mode)) ||
        (S_ISREG(metadata.st_mode) && metadata.st_nlink != 1)) {
      valid = NO;
      break;
    }
    if (S_ISDIR(metadata.st_mode)) {
      int child = openat(descriptor, entry->d_name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
      if (child < 0 || !LWValidTree(child, depth + 1, count)) valid = NO;
      if (child >= 0) close(child);
    }
  }
  closedir(directory);
  return valid;
}

@interface LocalWorkspaceModule : NSObject <RishNativeModule>
@property(nonatomic, strong) dispatch_queue_t workspaceQueue;
@property(nonatomic, strong) DSHLocalWorkspaceAccess *access;
@property(nonatomic, strong) DSHLocalProjectAccess *projectAccess;
/* Test-only, never bridge-exposed.  It lets native recovery tests fail one
 * restore unlink/fsync checkpoint without weakening production defaults. */
@property(nonatomic, copy) BOOL (^filesV2FaultHook)(NSString *stage);
@end

@implementation LocalWorkspaceModule

RISH_NATIVE_MODULE(LocalWorkspace)

+ (BOOL)requiresMainQueueSetup { return NO; }

- (instancetype)init {
  NSError *error = nil;
  NSURL *support = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory
    inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:&error];
  return [self initWithSupportURL:support
             legacyProjectAccess:[DSHLocalProjectAccess sharedAccess]];
}

- (instancetype)initWithSupportURL:(NSURL *)support
                legacyProjectAccess:(DSHLocalProjectAccess *)legacyAccess {
  self = [super init];
  if (self != nil) {
    _workspaceQueue = dispatch_queue_create("dev.zseven.rish.local-workspace-v2", DISPATCH_QUEUE_SERIAL);
    if (support != nil) {
      _access = [[DSHLocalWorkspaceAccess alloc]
          initWithPrivateRootURL:support
          clock:^NSDate *{ return NSDate.date; }
          UUIDGenerator:^NSString *{ return NSUUID.UUID.UUIDString.lowercaseString; }
          legacyResolver:^BOOL(NSString *projectId, NSDictionary **evidence,
                               NSError **resolverError) {
            NSError *projectError = nil;
            NSDictionary *resolved = [legacyAccess
                legacyWorkspaceBootstrapEvidenceForProjectId:projectId error:&projectError];
            if (resolved == nil) {
              if (evidence != nil) *evidence = nil;
              if (resolverError != nil) *resolverError = projectError ?: LWError(DSHLocalWorkspaceAccessErrorUnavailable);
              return NO;
            }
            if (evidence != nil) *evidence = [resolved copy];
            return YES;
          }
          faultHook:nil];
      _projectAccess = [[DSHLocalProjectAccess alloc]
          initWithProjectsRootURL:[legacyAccess projectsRootURLWithError:nil]
                 workspaceAccess:_access hook:nil];
    }
  }
  return self;
}

- (void)reject:(RishRejectBlock)reject error:(NSError *)error {
  if (error == nil) error = LWError(DSHLocalWorkspaceAccessErrorUnavailable);
  NSString *code = LWStableCode(error);
  reject(code, LWMessageForCode(code), nil);
}

- (void)invalid:(RishRejectBlock)reject {
  [self reject:reject error:LWError(DSHLocalWorkspaceAccessErrorInvalid)];
}

- (void)dispatchInvalid:(RishRejectBlock)reject {
  dispatch_async(self.workspaceQueue, ^{ [self invalid:reject]; });
}

- (BOOL)filesV2ShouldFail:(NSString *)stage {
  @try {
    return self.filesV2FaultHook != nil && self.filesV2FaultHook(stage);
  } @catch (__unused NSException *exception) {
    return YES;
  }
}

- (BOOL)filesV2Fsync:(int)descriptor stage:(NSString *)stage {
  if ([self filesV2ShouldFail:stage]) {
    errno = EIO;
    return NO;
  }
  return fsync(descriptor) == 0;
}

- (nullable NSDictionary *)legacyBoundRootForRootRef:(NSDictionary *)root
                                                error:(NSError **)error {
  NSError *authorityError = nil;
  __attribute__((objc_precise_lifetime))
  DSHLocalWorkspaceAuthorityMutationGuard *guard =
      [self.access acquireAuthorityMutationGuard:&authorityError];
  if (guard == nil || guard.owner != self.access ||
      ![self.access ensurePrivateLayoutLocked:&authorityError]) {
    if (error != nil) *error = LWWorkspaceRootError(authorityError);
    return nil;
  }
  NSDictionary *registry = [self.access loadRegistry:&authorityError digest:nil];
  NSDictionary *record = registry == nil ? nil :
      [self.access recordInRegistry:registry workspaceId:root[@"workspace_id"]];
  if (record == nil ||
      ![record[@"binding_revision"] isEqual:root[@"binding_revision"]]) {
    if (error != nil) *error = LWError(record == nil
        ? DSHLocalWorkspaceAccessErrorNotFound
        : DSHLocalWorkspaceAccessErrorRevisionStale);
    return nil;
  }
  NSDictionary *authority =
      [self.access loadAuthorityForRecord:record error:&authorityError];
  NSString *fingerprint = authority[@"root_fingerprint_sha256"];
  if (authority == nil || ![fingerprint isKindOfClass:NSString.class] ||
      fingerprint.length != 64) {
    if (error != nil) *error = LWWorkspaceRootError(authorityError);
    return nil;
  }
  NSMutableArray<NSString *> *capabilities = [NSMutableArray array];
  NSSet *available = nil;
  if ([record[@"root_locator_kind"] isEqual:@"legacy_app_owned"]) {
    available = [self.access verifiedLegacyCapabilitiesForRecord:record
                                                       authority:authority];
    if (available == nil ||
        ![record[@"legacy_project_id"] isEqual:root[@"project_id"]]) {
      if (error != nil) *error = LWError(DSHLocalWorkspaceAccessErrorRootChanged);
      return nil;
    }
  } else if ([record[@"root_locator_kind"] isEqual:@"documents_owned"]) {
    available = [NSSet setWithArray:@[@"read", @"write", @"git"]];
  } else {
    if (error != nil) *error = LWError(DSHLocalWorkspaceAccessErrorCapability);
    return nil;
  }
  if ([available containsObject:@"read"]) [capabilities addObject:@"file_read"];
  if ([available containsObject:@"write"]) [capabilities addObject:@"file_write"];
  if ([available containsObject:@"git"]) {
    [capabilities addObjectsFromArray:@[@"git_status", @"git_commit", @"git_push"]];
  }
  return @{
    @"schema_version" : @1,
    @"kind" : @"project",
    @"workspace_id" : root[@"workspace_id"],
    @"workspace_binding_revision" : root[@"binding_revision"],
    @"project_id" : root[@"project_id"],
    @"root_fingerprint_sha256" : fingerprint,
    @"capabilities" : capabilities,
  };
}

/*
 * A long-lived descriptor lease is used for app-owned roots. Security-scoped
 * roots are deliberately handed to the synchronous coordinated core API.
 * Both paths revalidate identity before the descriptor-relative block and
 * before publishing a result; no path is ever used as authority.
 */
- (BOOL)performRoot:(NSDictionary *)root
      capabilities:(NSSet<NSString *> *)capabilities
             block:(BOOL (^)(int descriptor, NSError **error))block
             error:(NSError **)error {
  if (self.access == nil || root == nil || block == nil) {
    LWSetError(error, DSHLocalWorkspaceAccessErrorUnavailable);
    return NO;
  }
  BOOL projectBound = root[@"project_id"] != NSNull.null;
  NSMutableSet<NSString *> *requiredCapabilities = [capabilities mutableCopy];
  if (projectBound) {
    [requiredCapabilities addObject:@"read"];
    [requiredCapabilities addObject:@"git"];
  }
  DSHLocalProjectAccessMode projectMode = [capabilities containsObject:@"write"]
      ? DSHLocalProjectAccessModeWrite : DSHLocalProjectAccessModeRead;
  if (projectBound) {
    NSError *boundError = nil;
    NSDictionary *boundRoot = [self legacyBoundRootForRootRef:root
                                                         error:&boundError];
    if (boundRoot == nil) {
      if (error != nil) *error = boundError;
      return NO;
    }
    DSHLegacyBoundProjectRootAccess *adapter =
        [[DSHLegacyBoundProjectRootAccess alloc]
            initWithWorkspaceAccess:self.access projectAccess:self.projectAccess];
    DSHLegacyBoundProjectRootOperationMode mode =
        [capabilities containsObject:@"write"]
            ? DSHLegacyBoundProjectRootOperationModeWrite
            : DSHLegacyBoundProjectRootOperationModeRead;
    DSHLegacyBoundProjectRootDisposition disposition = [adapter
        performRepositoryRootOperationForBoundRoot:boundRoot
                                              mode:mode
                                           timeout:5.0
                                             block:block
                                             error:&boundError];
    if (disposition == DSHLegacyBoundProjectRootDispositionHandled) return YES;
    if (disposition == DSHLegacyBoundProjectRootDispositionFailed) {
      if (error != nil) {
        *error = boundError.code == DSHLegacyBoundProjectRootAccessErrorRootChanged
            ? LWError(DSHLocalWorkspaceAccessErrorRootChanged)
            : (boundError.code == DSHLegacyBoundProjectRootAccessErrorInvalid
                   ? LWError(DSHLocalWorkspaceAccessErrorInvalid)
                   : LWError(DSHLocalWorkspaceAccessErrorCapability));
      }
      return NO;
    }
  }
  NSError *leaseError = nil;
  DSHLocalWorkspaceLease *lease = [self.access
      leaseWorkspaceId:root[@"workspace_id"]
      expectedBindingRevision:[root[@"binding_revision"] unsignedIntegerValue]
      requiredCapabilities:requiredCapabilities
      error:&leaseError];
  if (lease != nil) {
    DSHLocalProjectLease *projectLease = nil;
    if (projectBound) {
      NSError *projectError = nil;
      projectLease = [self.projectAccess
          leaseWorkspaceRootRef:root
                   workspaceLease:lease
                              mode:projectMode
                   includeMetadata:NO
                           timeout:-1
                             error:&projectError];
      if (projectLease == nil) {
        if (error != nil) *error = LWProjectRelationError(projectError);
        return NO;
      }
    }
    struct stat pinnedRootState = {};
    NSString *pinnedFingerprint = nil;
    NSString *pinnedBindingDigest = nil;
    if (projectBound) {
      BOOL pinned = fstat(projectLease.workspaceRootDescriptor,
                          &pinnedRootState) == 0 &&
          S_ISDIR(pinnedRootState.st_mode) &&
          [projectLease.workspaceId isEqual:root[@"workspace_id"]] &&
          projectLease.workspaceBindingRevision ==
              [root[@"binding_revision"] unsignedIntegerValue] &&
          [projectLease.projectId isEqual:root[@"project_id"]];
      pinnedFingerprint = [projectLease.rootFingerprintSHA256 copy];
      pinnedBindingDigest = [projectLease.workspaceBindingDigest copy];
      if (!pinned || pinnedFingerprint.length == 0 ||
          pinnedBindingDigest.length == 0) {
        if (error != nil) *error = LWError(DSHLocalWorkspaceAccessErrorRootChanged);
        return NO;
      }
    }
    NSError *blockError = nil;
    BOOL result = NO;
    @try {
      int descriptor = projectBound
          ? projectLease.workspaceRootDescriptor : lease.rootDescriptor;
      result = block(descriptor, &blockError);
    } @catch (__unused NSException *exception) {
      blockError = LWError(DSHLocalWorkspaceAccessErrorIO);
      result = NO;
    }
    if (!result) {
      if (error != nil) *error = blockError ?: LWError(DSHLocalWorkspaceAccessErrorIO);
      return NO;
    }
    if (projectBound) {
      NSError *relationError = nil;
      DSHLocalWorkspaceLease *reopenedWorkspace = [self.access
          leaseWorkspaceId:root[@"workspace_id"]
          expectedBindingRevision:[root[@"binding_revision"] unsignedIntegerValue]
          requiredCapabilities:requiredCapabilities
          error:&relationError];
      struct stat reopenedRootState = {};
      BOOL relationStable = reopenedWorkspace != nil &&
          fstat(reopenedWorkspace.rootDescriptor, &reopenedRootState) == 0 &&
          reopenedRootState.st_dev == pinnedRootState.st_dev &&
          reopenedRootState.st_ino == pinnedRootState.st_ino &&
          [projectLease.rootFingerprintSHA256 isEqual:pinnedFingerprint] &&
          [projectLease.workspaceBindingDigest isEqual:pinnedBindingDigest] &&
          [self.projectAccess validateWorkspaceLeaseIdentity:projectLease
                                                      rootRef:root
                                                        error:&relationError];
      if (!relationStable) {
        if (error != nil) *error = LWProjectRelationError(relationError);
        return NO;
      }
      return YES;
    }
    /* A second lease is the terminal root-fingerprint/identity check. */
    NSError *afterError = nil;
    DSHLocalWorkspaceLease *after = [self.access
        leaseWorkspaceId:root[@"workspace_id"]
        expectedBindingRevision:[root[@"binding_revision"] unsignedIntegerValue]
        requiredCapabilities:requiredCapabilities
        error:&afterError];
    struct stat beforeState = {}, afterState = {};
    if (after == nil || fstat(lease.rootDescriptor, &beforeState) != 0 ||
        fstat(after.rootDescriptor, &afterState) != 0 ||
        beforeState.st_dev != afterState.st_dev || beforeState.st_ino != afterState.st_ino) {
      if (error != nil) *error = LWWorkspaceRootError(afterError);
      return NO;
    }
    return YES;
  }
  if (leaseError.code != DSHLocalWorkspaceAccessErrorCapability) {
    if (error != nil) *error = LWWorkspaceRootError(leaseError);
    return NO;
  }
  if (projectBound) {
    if (error != nil) *error = leaseError ?: LWError(DSHLocalWorkspaceAccessErrorCapability);
    return NO;
  }
  return [self.access performCoordinatedWorkspaceOperationForId:root[@"workspace_id"]
      expectedBindingRevision:[root[@"binding_revision"] unsignedIntegerValue]
      requiredCapabilities:requiredCapabilities
      block:block
      error:error];
}

- (int)openDirectory:(NSArray<NSString *> *)components
                root:(int)rootDescriptor
               error:(NSError **)error {
  int descriptor = dup(rootDescriptor);
  if (descriptor < 0) {
    LWSetError(error, DSHLocalWorkspaceAccessErrorUnavailable);
    return -1;
  }
  for (NSString *component in components) {
    NSString *resolved = [self resolvedComponent:component directory:descriptor allowMissing:NO error:error];
    if (resolved == nil) { close(descriptor); return -1; }
    struct stat state = {};
    if (fstatat(descriptor, resolved.fileSystemRepresentation, &state, AT_SYMLINK_NOFOLLOW) != 0 ||
        S_ISLNK(state.st_mode) || !S_ISDIR(state.st_mode)) {
      close(descriptor);
      LWSetError(error, DSHLocalWorkspaceAccessErrorUnavailable);
      return -1;
    }
    int next = openat(descriptor, resolved.fileSystemRepresentation,
                      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    close(descriptor);
    if (next < 0) {
      LWSetError(error, DSHLocalWorkspaceAccessErrorUnavailable);
      return -1;
    }
    descriptor = next;
  }
  return descriptor;
}

- (NSString *)resolvedComponent:(NSString *)requested
                       directory:(int)directory
                    allowMissing:(BOOL)allowMissing
                           error:(NSError **)error {
  struct stat state = {};
  if (fstatat(directory, requested.fileSystemRepresentation, &state, AT_SYMLINK_NOFOLLOW) == 0) return requested;
  if (errno != ENOENT) { LWSetError(error, DSHLocalWorkspaceAccessErrorUnavailable); return nil; }
  NSString *folded = requested.precomposedStringWithCanonicalMapping.lowercaseString;
  int duplicate = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  DIR *contents = duplicate < 0 ? nullptr : fdopendir(duplicate);
  if (contents == nullptr) { if (duplicate >= 0) close(duplicate); LWSetError(error, DSHLocalWorkspaceAccessErrorUnavailable); return nil; }
  NSString *match = nil; struct dirent *entry = nullptr; BOOL valid = YES;
  while (valid) {
    errno = 0; entry = readdir(contents);
    if (entry == nullptr) { valid = errno == 0; break; }
    if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
    NSString *candidate = [NSString stringWithUTF8String:entry->d_name];
    if (candidate == nil || ![candidate.precomposedStringWithCanonicalMapping.lowercaseString isEqual:folded]) continue;
    if (match != nil && ![match isEqual:candidate]) { valid = NO; break; }
    match = candidate;
  }
  closedir(contents);
  if (!valid) { LWSetError(error, DSHLocalWorkspaceAccessErrorConflict); return nil; }
  if (match != nil) return match;
  if (allowMissing) return requested;
  LWSetError(error, DSHLocalWorkspaceAccessErrorUnavailable);
  return nil;
}

- (int)openParentForPath:(NSString *)path
                    root:(int)rootDescriptor
                    name:(NSString **)name
                relative:(NSString **)relative
                   error:(NSError **)error {
  NSArray<NSString *> *components = LWComponents(path, NO, error);
  if (components == nil || components.count == 0) return -1;
  NSArray<NSString *> *parents = components.count > 1
      ? [components subarrayWithRange:NSMakeRange(0, components.count - 1)] : @[];
  int descriptor = [self openDirectory:parents root:rootDescriptor error:error];
  if (descriptor < 0) return -1;
  NSString *last = [self resolvedComponent:components.lastObject directory:descriptor allowMissing:YES error:error];
  if (last == nil) { close(descriptor); return -1; }
  if (name != nil) *name = last;
  if (relative != nil) *relative = [components componentsJoinedByString:@"/"];
  return descriptor;
}

- (NSDictionary *)metadataForStat:(struct stat)state path:(NSString *)path error:(NSError **)error {
  NSString *kind = S_ISREG(state.st_mode) ? @"file" : S_ISDIR(state.st_mode) ? @"directory" : nil;
  if (kind == nil || path.length == 0) {
    LWSetError(error, DSHLocalWorkspaceAccessErrorIO);
    return nil;
  }
  return @{
    @"path": path,
    @"name": path.lastPathComponent,
    @"kind": kind,
    @"size": S_ISREG(state.st_mode) ? @(state.st_size) : @0,
    @"modified_at": LWTimestamp(state),
    @"revision": LWRevision(state),
  };
}

- (NSData *)readDataInParent:(int)parent
                         name:(NSString *)name
                         limit:(NSUInteger)limit
                      metadata:(struct stat *)metadataOut
                         error:(NSError **)error {
  struct stat before = {};
  if (fstatat(parent, name.fileSystemRepresentation, &before, AT_SYMLINK_NOFOLLOW) != 0 ||
      !S_ISREG(before.st_mode) || S_ISLNK(before.st_mode) || before.st_nlink != 1 || before.st_size < 0 ||
      (uint64_t)before.st_size > limit) {
    LWSetError(error, DSHLocalWorkspaceAccessErrorIO);
    return nil;
  }
  int descriptor = openat(parent, name.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (descriptor < 0) {
    LWSetError(error, DSHLocalWorkspaceAccessErrorIO);
    return nil;
  }
  struct stat opened = {};
  if (fstat(descriptor, &opened) != 0 || !S_ISREG(opened.st_mode) || opened.st_nlink != 1 || opened.st_dev != before.st_dev ||
      opened.st_ino != before.st_ino || opened.st_size != before.st_size || opened.st_size < 0 ||
      (uint64_t)opened.st_size > limit) {
    close(descriptor);
    LWSetError(error, DSHLocalWorkspaceAccessErrorRootChanged);
    return nil;
  }
  NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)opened.st_size];
  NSUInteger offset = 0;
  while (offset < data.length) {
    ssize_t amount = read(descriptor, (uint8_t *)data.mutableBytes + offset, data.length - offset);
    if (amount < 0 && errno == EINTR) continue;
    if (amount <= 0) break;
    offset += (NSUInteger)amount;
  }
  struct stat after = {};
  BOOL stable = fstat(descriptor, &after) == 0 && LWSameFileState(opened, after) &&
      (!S_ISREG(after.st_mode) || after.st_nlink == 1);
  close(descriptor);
  if (offset != data.length || !stable) {
    LWSetError(error, stable ? DSHLocalWorkspaceAccessErrorIO : DSHLocalWorkspaceAccessErrorConflict);
    return nil;
  }
  if (metadataOut != nullptr) *metadataOut = opened;
  return data;
}

- (BOOL)atomicWrite:(NSData *)data
               parent:(int)parent
                 name:(NSString *)name
           createOnly:(BOOL)createOnly
     expectedRevision:(NSString *)expectedRevision
                error:(NSError **)error {
  struct stat existing = {};
  BOOL exists = fstatat(parent, name.fileSystemRepresentation, &existing, AT_SYMLINK_NOFOLLOW) == 0;
  int lookupErrno = errno;
  if (!exists && lookupErrno != ENOENT) {
    LWSetError(error, DSHLocalWorkspaceAccessErrorIO);
    return NO;
  }
  if (createOnly && (exists || expectedRevision != nil)) {
    LWSetError(error, DSHLocalWorkspaceAccessErrorConflict);
    return NO;
  }
  if (exists && (!S_ISREG(existing.st_mode) || S_ISLNK(existing.st_mode))) {
    LWSetError(error, DSHLocalWorkspaceAccessErrorIO);
    return NO;
  }
  if (exists && existing.st_nlink != 1) {
    LWSetError(error, DSHLocalWorkspaceAccessErrorConflict);
    return NO;
  }
  if (!exists && !createOnly && expectedRevision != nil) {
    LWSetError(error, DSHLocalWorkspaceAccessErrorConflict);
    return NO;
  }
  if (exists && !createOnly &&
      (!LWDigest(expectedRevision) || ![LWRevision(existing) isEqual:expectedRevision])) {
    LWSetError(error, DSHLocalWorkspaceAccessErrorConflict);
    return NO;
  }

  int existingDescriptor = -1;
  if (exists) {
    existingDescriptor = openat(parent, name.fileSystemRepresentation,
                                O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    struct stat opened = {};
    if (existingDescriptor < 0 || fstat(existingDescriptor, &opened) != 0 ||
        !LWSameFileState(existing, opened)) {
      if (existingDescriptor >= 0) close(existingDescriptor);
      LWSetError(error, DSHLocalWorkspaceAccessErrorConflict);
      return NO;
    }
  }

  NSString *temporary = [@".rish-write-" stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];
  int descriptor = openat(parent, temporary.fileSystemRepresentation,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (descriptor < 0) {
    if (existingDescriptor >= 0) close(existingDescriptor);
    LWSetError(error, DSHLocalWorkspaceAccessErrorIO);
    return NO;
  }
  BOOL written = fchmod(descriptor, 0600) == 0 && LWWriteAll(descriptor, data) && fsync(descriptor) == 0;
  if (close(descriptor) != 0) written = NO;
  if (!written) {
    unlinkat(parent, temporary.fileSystemRepresentation, 0);
    if (existingDescriptor >= 0) close(existingDescriptor);
    LWSetError(error, DSHLocalWorkspaceAccessErrorIO);
    return NO;
  }

  if (!exists) {
    /* Creation is a name CAS: EXCL, never an unchecked flags-0 replace. */
    int renameResult = renameatx_np(parent, temporary.fileSystemRepresentation,
                                    parent, name.fileSystemRepresentation, RENAME_EXCL);
    if (renameResult != 0) {
      unlinkat(parent, temporary.fileSystemRepresentation, 0);
      if (existingDescriptor >= 0) close(existingDescriptor);
      LWSetError(error, errno == EEXIST ? DSHLocalWorkspaceAccessErrorConflict : DSHLocalWorkspaceAccessErrorIO);
      return NO;
    }
    struct stat installed = {};
    BOOL verified = fstatat(parent, name.fileSystemRepresentation, &installed,
                            AT_SYMLINK_NOFOLLOW) == 0 && S_ISREG(installed.st_mode) &&
        installed.st_nlink == 1;
    if (!verified || fsync(parent) != 0) {
      BOOL removed = verified && LWStatAtMatches(parent, name, installed, nullptr) &&
          unlinkat(parent, name.fileSystemRepresentation, 0) == 0 && fsync(parent) == 0;
      if (existingDescriptor >= 0) close(existingDescriptor);
      LWSetError(error, removed ? DSHLocalWorkspaceAccessErrorIO : DSHLocalWorkspaceAccessErrorConflict);
      return NO;
    }
    if (existingDescriptor >= 0) close(existingDescriptor);
    return YES;
  }

  /*
   * Overwrite is a swap-and-verify CAS.  The old inode remains at `temporary`
   * until the new name has been verified and its parent directory synced.  If
   * any check fails, swap back only while both names still carry the exact
   * expected inodes; otherwise retain both names as recoverable staging.
   */
  int replacementDescriptor = openat(parent, temporary.fileSystemRepresentation,
                                     O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  struct stat replacement = {};
  BOOL replacementValid = replacementDescriptor >= 0 &&
      fstat(replacementDescriptor, &replacement) == 0 && S_ISREG(replacement.st_mode) &&
      replacement.st_nlink == 1;
  struct stat held = {};
  BOOL precondition = replacementValid && fstat(existingDescriptor, &held) == 0 &&
      LWSameFileState(existing, held) && LWStatAtMatches(parent, name, existing, nullptr);
  if (!precondition || renameatx_np(parent, temporary.fileSystemRepresentation,
                                    parent, name.fileSystemRepresentation, RENAME_SWAP) != 0) {
    if (replacementDescriptor >= 0) close(replacementDescriptor);
    close(existingDescriptor);
    unlinkat(parent, temporary.fileSystemRepresentation, 0);
    LWSetError(error, precondition ? DSHLocalWorkspaceAccessErrorIO : DSHLocalWorkspaceAccessErrorConflict);
    return NO;
  }
  BOOL swapped = YES;
  struct stat installed = {}, backup = {};
  BOOL verified = LWStatAtMatches(parent, name, replacement, &installed) &&
      LWStatAtMatches(parent, temporary, existing, &backup) &&
      fstat(replacementDescriptor, &held) == 0 && LWSameFileState(replacement, held);
  if (!verified) {
    BOOL rolledBack = LWSafeSwapBack(parent, name, temporary, replacement, existing) ||
        LWRestoreSwapToObservedBackup(parent, name, temporary, replacement);
    if (!rolledBack) swapped = NO;
    if (replacementDescriptor >= 0) close(replacementDescriptor);
    close(existingDescriptor);
    if (swapped) unlinkat(parent, temporary.fileSystemRepresentation, 0);
    LWSetError(error, DSHLocalWorkspaceAccessErrorConflict);
    return NO;
  }
  BOOL synced = fsync(parent) == 0;
  if (!synced) {
    BOOL rolledBack = LWSafeSwapBack(parent, name, temporary, replacement, existing);
    if (rolledBack) {
      /* The old name is restored; leave a failed replacement recoverable. */
      (void)fsync(parent);
    }
    if (replacementDescriptor >= 0) close(replacementDescriptor);
    close(existingDescriptor);
    LWSetError(error, rolledBack ? DSHLocalWorkspaceAccessErrorIO : DSHLocalWorkspaceAccessErrorConflict);
    return NO;
  }
  if (!LWStatAtMatches(parent, temporary, existing, nullptr) ||
      unlinkat(parent, temporary.fileSystemRepresentation, 0) != 0) {
    BOOL rolledBack = LWSafeSwapBack(parent, name, temporary, replacement, existing);
    if (rolledBack) (void)fsync(parent);
    if (replacementDescriptor >= 0) close(replacementDescriptor);
    close(existingDescriptor);
    LWSetError(error, rolledBack ? DSHLocalWorkspaceAccessErrorIO : DSHLocalWorkspaceAccessErrorConflict);
    return NO;
  }
  if (fsync(parent) != 0) {
    /* The replacement is complete, but report persistence failure; no stale
       caller may mistake it for a durable success. */
    if (replacementDescriptor >= 0) close(replacementDescriptor);
    close(existingDescriptor);
    LWSetError(error, DSHLocalWorkspaceAccessErrorIO);
    return NO;
  }
  if (replacementDescriptor >= 0) close(replacementDescriptor);
  close(existingDescriptor);
  (void)swapped;
  return YES;
}

- (int)openTrashForRoot:(int)rootDescriptor
                  create:(BOOL)create
                   error:(NSError **)error {
  struct stat state = {};
  if (fstatat(rootDescriptor, ".trash", &state, AT_SYMLINK_NOFOLLOW) != 0) {
    if (errno == ENOENT && !create) return -2;
    if (errno != ENOENT || mkdirat(rootDescriptor, ".trash", 0700) != 0 || fsync(rootDescriptor) != 0) {
      LWSetError(error, DSHLocalWorkspaceAccessErrorIO);
      return -1;
    }
  } else if (!S_ISDIR(state.st_mode) || S_ISLNK(state.st_mode)) {
    LWSetError(error, DSHLocalWorkspaceAccessErrorIO);
    return -1;
  }
  int descriptor = openat(rootDescriptor, ".trash", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (descriptor < 0) LWSetError(error, DSHLocalWorkspaceAccessErrorIO);
  return descriptor;
}

- (NSDictionary *)trashReceiptAtRecord:(int)record
                                trashId:(NSString *)trashId
                                  state:(struct stat *)payloadOut
                                 error:(NSError **)error {
  NSError *metadataError = nil;
  NSData *metadata = [self readDataInParent:record name:@"metadata.json" limit:4096 metadata:nil error:&metadataError];
  NSDictionary *receipt = metadata == nil ? nil : [NSJSONSerialization JSONObjectWithData:metadata options:0 error:nil];
  if (receipt == nil) {
    NSError *recoveryError = nil;
    NSData *recovery = [self readDataInParent:record name:@"metadata.recovery.json" limit:4096 metadata:nil error:&recoveryError];
    receipt = recovery == nil ? nil : [NSJSONSerialization JSONObjectWithData:recovery options:0 error:nil];
    if (receipt == nil && error != nil) *error = recoveryError ?: metadataError;
  }
  NSString *original = [receipt[@"original_path"] isKindOfClass:NSString.class] ? receipt[@"original_path"] : nil;
  NSString *kind = [receipt[@"kind"] isKindOfClass:NSString.class] ? receipt[@"kind"] : nil;
  NSString *deleted = [receipt[@"deleted_at"] isKindOfClass:NSString.class] ? receipt[@"deleted_at"] : nil;
  struct stat payload = {};
  BOOL validPayload = fstatat(record, "payload", &payload, AT_SYMLINK_NOFOLLOW) == 0 &&
      !S_ISLNK(payload.st_mode) && (S_ISREG(payload.st_mode) || S_ISDIR(payload.st_mode)) &&
      (!S_ISREG(payload.st_mode) || payload.st_nlink == 1);
  BOOL validPath = LWComponents(original, NO, nil) != nil;
  BOOL validKind = [kind isEqual:@"file"] || [kind isEqual:@"directory"];
  BOOL matches = ([kind isEqual:@"file"] && S_ISREG(payload.st_mode)) ||
      ([kind isEqual:@"directory"] && S_ISDIR(payload.st_mode));
  if (!LWExact(receipt, @[@"schema_version", @"trash_id", @"original_path", @"kind", @"deleted_at"]) ||
      !LWSchemaOne(receipt[@"schema_version"]) || ![receipt[@"trash_id"] isEqual:trashId] ||
      !validPath || !validKind || !matches || !validPayload || ![deleted isKindOfClass:NSString.class] || deleted.length == 0) {
    LWSetError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return nil;
  }
  NSUInteger count = 0;
  if (S_ISDIR(payload.st_mode)) {
    int child = openat(record, "payload", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    BOOL safe = child >= 0 && LWValidTree(child, 0, &count);
    if (child >= 0) close(child);
    if (!safe) {
      LWSetError(error, DSHLocalWorkspaceAccessErrorPersistence);
      return nil;
    }
  }
  if (payloadOut != nullptr) *payloadOut = payload;
  return receipt;
}

RISH_NATIVE_METHOD(capabilities,
                 capabilitiesWithResolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  (void)reject;
  resolve(@{
    @"schema_version": @1,
    @"root": @"workspace",
    @"max_text_bytes": @(LWMaxTextBytes),
    @"max_list_entries": @(LWMaxListEntries),
    @"max_tool_output_bytes": @(LWMaxToolOutputBytes),
    @"trash_recoverable": @YES,
    @"trash_listable": @YES,
    @"atomic_writes": @YES,
    @"symlinks_allowed": @NO,
    @"rish_protocol_version": @(rish_protocol_version()),
    @"portable_tools": @[@"cat", @"grep", @"head", @"tail", @"wc", @"sha256sum"],
  });
}

RISH_NATIVE_METHOD(listV2,
                 listV2Request:(id)requestValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSDictionary *request = [requestValue isKindOfClass:NSDictionary.class] ? requestValue : nil;
  if (!LWExact(request, @[@"schema_version", @"root", @"path", @"max_entries"]) ||
      !LWSchemaOne(request[@"schema_version"]) || !LWIsSafeInteger(request[@"max_entries"], NO)) {
    [self dispatchInvalid:reject];
    return;
  }
  NSError *validationError = nil;
  NSDictionary *root = LWRootFromRequest(request, &validationError);
  NSString *path = [request[@"path"] isKindOfClass:NSString.class] ? request[@"path"] : nil;
  NSArray<NSString *> *components = path == nil ? nil : LWComponents(path, YES, &validationError);
  NSUInteger maximum = [request[@"max_entries"] unsignedIntegerValue];
  if (root == nil || components == nil || maximum > LWMaxListEntries) {
    [self dispatchInvalid:reject];
    return;
  }
  dispatch_async(self.workspaceQueue, ^{
    __block NSArray *entries = nil;
    NSError *error = nil;
    BOOL ok = [self performRoot:root capabilities:[NSSet setWithObject:@"read"] block:^BOOL(int descriptor, NSError **blockError) {
      int directory = [self openDirectory:components root:descriptor error:blockError];
      if (directory < 0) return NO;
      DIR *children = fdopendir(directory);
      if (children == nullptr) {
        close(directory);
        LWSetError(blockError, DSHLocalWorkspaceAccessErrorIO);
        return NO;
      }
      NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
      struct dirent *entry = nullptr;
      BOOL valid = YES;
      while (valid) {
        errno = 0;
        entry = readdir(children);
        if (entry == nullptr) {
          valid = errno == 0;
          break;
        }
        NSString *name = [NSString stringWithUTF8String:entry->d_name];
        if (name == nil || [name isEqual:@"."] || [name isEqual:@".."] ||
            [name.lowercaseString isEqual:@".trash"] || [name.lowercaseString isEqual:@".git"] ||
            [name.lowercaseString hasPrefix:@".staging-"] ||
            [name.lowercaseString hasPrefix:@".rish-write-"]) continue;
        if (result.count >= maximum || !LWPathName(name)) {
          valid = NO;
          LWSetError(blockError, DSHLocalWorkspaceAccessErrorIO);
          break;
        }
        struct stat state = {};
        if (fstatat(dirfd(children), name.fileSystemRepresentation, &state, AT_SYMLINK_NOFOLLOW) != 0 ||
            S_ISLNK(state.st_mode) || (!S_ISREG(state.st_mode) && !S_ISDIR(state.st_mode)) ||
            (S_ISREG(state.st_mode) && state.st_nlink != 1)) {
          valid = NO;
          LWSetError(blockError, DSHLocalWorkspaceAccessErrorIO);
          break;
        }
        NSString *relative = path.length == 0 ? name : [path stringByAppendingFormat:@"/%@", name];
        NSDictionary *metadata = [self metadataForStat:state path:relative error:blockError];
        if (metadata == nil) { valid = NO; break; }
        [result addObject:metadata];
      }
      if (!valid) { closedir(children); return NO; }
      closedir(children);
      [result sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [left[@"name"] localizedStandardCompare:right[@"name"]];
      }];
      entries = result;
      return YES;
    } error:&error];
    if (!ok) { [self reject:reject error:error]; return; }
    resolve(@{ @"schema_version": @1, @"root": root, @"path": path, @"entries": entries ?: @[] });
  });
}

RISH_NATIVE_METHOD(readV2,
                 readV2Request:(id)requestValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSDictionary *request = [requestValue isKindOfClass:NSDictionary.class] ? requestValue : nil;
  if (!LWExact(request, @[@"schema_version", @"root", @"path", @"max_bytes"]) ||
      !LWSchemaOne(request[@"schema_version"]) || !LWIsSafeInteger(request[@"max_bytes"], NO) ||
      [request[@"path"] isKindOfClass:NSString.class] == NO) {
    [self dispatchInvalid:reject];
    return;
  }
  NSError *validationError = nil;
  NSDictionary *root = LWRootFromRequest(request, &validationError);
  NSString *path = request[@"path"];
  NSArray *components = LWComponents(path, NO, &validationError);
  NSUInteger maximum = [request[@"max_bytes"] unsignedIntegerValue];
  if (root == nil || components == nil || maximum > LWMaxTextBytes) { [self dispatchInvalid:reject]; return; }
  dispatch_async(self.workspaceQueue, ^{
    __block NSDictionary *file = nil;
    __block NSString *content = nil;
    NSError *error = nil;
    BOOL ok = [self performRoot:root capabilities:[NSSet setWithObject:@"read"] block:^BOOL(int descriptor, NSError **blockError) {
      NSString *name = nil;
      NSString *relative = nil;
      int parent = [self openParentForPath:path root:descriptor name:&name relative:&relative error:blockError];
      if (parent < 0) return NO;
      struct stat state = {};
      NSData *data = [self readDataInParent:parent name:name limit:maximum metadata:&state error:blockError];
      close(parent);
      if (data == nil) return NO;
      NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
      if (text == nil) { LWSetError(blockError, DSHLocalWorkspaceAccessErrorIO); return NO; }
      NSDictionary *metadata = [self metadataForStat:state path:relative error:blockError];
      if (metadata == nil) return NO;
      file = metadata;
      content = text;
      return YES;
    } error:&error];
    if (!ok) { [self reject:reject error:error]; return; }
    resolve(@{ @"schema_version": @1, @"root": root, @"path": path, @"file": file, @"content": content });
  });
}

RISH_NATIVE_METHOD(writeV2,
                 writeV2Request:(id)requestValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSDictionary *request = [requestValue isKindOfClass:NSDictionary.class] ? requestValue : nil;
  if (!LWExact(request, @[@"schema_version", @"root", @"path", @"content", @"expected_revision", @"create_only"]) ||
      !LWSchemaOne(request[@"schema_version"]) || ![request[@"content"] isKindOfClass:NSString.class] ||
      !LWIsSafeInteger(@([request[@"content"] lengthOfBytesUsingEncoding:NSUTF8StringEncoding]), YES) ||
      !LWIsBooleanNumber(request[@"create_only"]) ||
      (request[@"expected_revision"] != NSNull.null && !LWDigest(request[@"expected_revision"]))) {
    [self dispatchInvalid:reject];
    return;
  }
  NSString *content = request[@"content"];
  NSData *data = [content dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
  NSError *validationError = nil;
  NSDictionary *root = LWRootFromRequest(request, &validationError);
  NSString *path = request[@"path"];
  NSArray *components = LWComponents(path, NO, &validationError);
  if (root == nil || components == nil || data == nil || data.length > LWMaxTextBytes) { [self dispatchInvalid:reject]; return; }
  BOOL createOnly = [request[@"create_only"] boolValue];
  NSString *expectedRevision = request[@"expected_revision"] == NSNull.null ? nil : request[@"expected_revision"];
  dispatch_async(self.workspaceQueue, ^{
    __block NSDictionary *file = nil;
    __block BOOL created = NO;
    NSError *error = nil;
    BOOL ok = [self performRoot:root capabilities:[NSSet setWithObject:@"write"] block:^BOOL(int descriptor, NSError **blockError) {
      NSString *name = nil;
      NSString *relative = nil;
      int parent = [self openParentForPath:path root:descriptor name:&name relative:&relative error:blockError];
      if (parent < 0) return NO;
      struct stat prior = {};
      BOOL existed = fstatat(parent, name.fileSystemRepresentation, &prior, AT_SYMLINK_NOFOLLOW) == 0;
      if (!existed && errno != ENOENT) { close(parent); LWSetError(blockError, DSHLocalWorkspaceAccessErrorIO); return NO; }
      if (!createOnly && expectedRevision == nil) { close(parent); LWSetError(blockError, DSHLocalWorkspaceAccessErrorConflict); return NO; }
      if (!createOnly && !existed && expectedRevision != nil) { close(parent); LWSetError(blockError, DSHLocalWorkspaceAccessErrorConflict); return NO; }
      if (![self atomicWrite:data parent:parent name:name createOnly:createOnly expectedRevision:expectedRevision error:blockError]) { close(parent); return NO; }
      struct stat state = {};
      BOOL statted = fstatat(parent, name.fileSystemRepresentation, &state, AT_SYMLINK_NOFOLLOW) == 0;
      NSDictionary *metadata = statted ? [self metadataForStat:state path:relative error:blockError] : nil;
      close(parent);
      if (metadata == nil) return NO;
      file = metadata;
      created = !existed;
      return YES;
    } error:&error];
    if (!ok) { [self reject:reject error:error]; return; }
    resolve(@{ @"schema_version": @1, @"root": root, @"file": file, @"created": @(created) });
  });
}

RISH_NATIVE_METHOD(createDirectoryV2,
                 createDirectoryV2Request:(id)requestValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSDictionary *request = [requestValue isKindOfClass:NSDictionary.class] ? requestValue : nil;
  if (!LWExact(request, @[@"schema_version", @"root", @"path"]) || !LWSchemaOne(request[@"schema_version"]) || ![request[@"path"] isKindOfClass:NSString.class]) { [self dispatchInvalid:reject]; return; }
  NSError *validationError = nil;
  NSDictionary *root = LWRootFromRequest(request, &validationError);
  NSString *path = request[@"path"];
  if (root == nil || LWComponents(path, NO, &validationError) == nil) { [self dispatchInvalid:reject]; return; }
  dispatch_async(self.workspaceQueue, ^{
    __block NSDictionary *directoryMetadata = nil;
    NSError *error = nil;
    BOOL ok = [self performRoot:root capabilities:[NSSet setWithObject:@"write"] block:^BOOL(int descriptor, NSError **blockError) {
      NSString *name = nil; NSString *relative = nil;
      int parent = [self openParentForPath:path root:descriptor name:&name relative:&relative error:blockError];
      if (parent < 0) return NO;
      if (mkdirat(parent, name.fileSystemRepresentation, 0700) != 0) {
        int mkdirErrno = errno;
        close(parent);
        LWSetError(blockError, mkdirErrno == EEXIST
            ? DSHLocalWorkspaceAccessErrorConflict : DSHLocalWorkspaceAccessErrorIO);
        return NO;
      }
      struct stat createdState = {};
      BOOL createdStable = fstatat(parent, name.fileSystemRepresentation, &createdState,
                                   AT_SYMLINK_NOFOLLOW) == 0 && S_ISDIR(createdState.st_mode);
      BOOL parentSynced = createdStable && fsync(parent) == 0;
      if (!parentSynced) {
        BOOL removed = createdStable && LWStatAtMatches(parent, name, createdState, nullptr) &&
            unlinkat(parent, name.fileSystemRepresentation, AT_REMOVEDIR) == 0 && fsync(parent) == 0;
        close(parent);
        LWSetError(blockError, removed ? DSHLocalWorkspaceAccessErrorIO : DSHLocalWorkspaceAccessErrorConflict);
        return NO;
      }
      struct stat state = {};
      BOOL statted = fstatat(parent, name.fileSystemRepresentation, &state, AT_SYMLINK_NOFOLLOW) == 0;
      directoryMetadata = statted ? [self metadataForStat:state path:relative error:blockError] : nil;
      close(parent);
      return directoryMetadata != nil;
    } error:&error];
    if (!ok) { [self reject:reject error:error]; return; }
    resolve(@{ @"schema_version": @1, @"root": root, @"directory": directoryMetadata });
  });
}

RISH_NATIVE_METHOD(renameEntryV2,
                 renameEntryV2Request:(id)requestValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSDictionary *request = [requestValue isKindOfClass:NSDictionary.class] ? requestValue : nil;
  if (!LWExact(request, @[@"schema_version", @"root", @"source_path", @"destination_path"]) || !LWSchemaOne(request[@"schema_version"]) || ![request[@"source_path"] isKindOfClass:NSString.class] || ![request[@"destination_path"] isKindOfClass:NSString.class]) { [self dispatchInvalid:reject]; return; }
  NSError *validationError = nil;
  NSDictionary *root = LWRootFromRequest(request, &validationError);
  NSString *source = request[@"source_path"]; NSString *destination = request[@"destination_path"];
  if (root == nil || LWComponents(source, NO, &validationError) == nil || LWComponents(destination, NO, &validationError) == nil) { [self dispatchInvalid:reject]; return; }
  if ([destination isEqual:source] || [destination hasPrefix:[source stringByAppendingString:@"/"]]) { [self dispatchInvalid:reject]; return; }
  dispatch_async(self.workspaceQueue, ^{
    __block NSDictionary *entry = nil; NSError *error = nil;
    BOOL ok = [self performRoot:root capabilities:[NSSet setWithObject:@"write"] block:^BOOL(int descriptor, NSError **blockError) {
      NSString *sourceName = nil; NSString *sourceRelative = nil; NSString *destinationName = nil; NSString *destinationRelative = nil;
      int sourceParent = [self openParentForPath:source root:descriptor name:&sourceName relative:&sourceRelative error:blockError];
      int destinationParent = [self openParentForPath:destination root:descriptor name:&destinationName relative:&destinationRelative error:blockError];
      if (sourceParent < 0 || destinationParent < 0) { if (sourceParent >= 0) close(sourceParent); if (destinationParent >= 0) close(destinationParent); return NO; }
      struct stat state = {};
      BOOL sourceValid = fstatat(sourceParent, sourceName.fileSystemRepresentation, &state, AT_SYMLINK_NOFOLLOW) == 0 && !S_ISLNK(state.st_mode) && (S_ISREG(state.st_mode) || S_ISDIR(state.st_mode));
      int sourceDescriptor = -1;
      if (sourceValid) {
        int flags = S_ISDIR(state.st_mode) ? (O_RDONLY | O_DIRECTORY) : O_RDONLY;
        sourceDescriptor = openat(sourceParent, sourceName.fileSystemRepresentation, flags | O_CLOEXEC | O_NOFOLLOW);
        struct stat opened = {};
        sourceValid = sourceDescriptor >= 0 && fstat(sourceDescriptor, &opened) == 0 && LWSameFileState(state, opened) &&
            (!S_ISREG(state.st_mode) || state.st_nlink == 1);
      }
      struct stat current = {};
      BOOL sourceStable = sourceValid && fstat(sourceDescriptor, &current) == 0 && LWSameFileState(state, current) &&
          (!S_ISREG(current.st_mode) || current.st_nlink == 1) &&
          fstatat(sourceParent, sourceName.fileSystemRepresentation, &current, AT_SYMLINK_NOFOLLOW) == 0 &&
          LWSameFileState(state, current) && (!S_ISREG(current.st_mode) || current.st_nlink == 1);
      struct stat destinationState = {};
      BOOL destinationAbsent = fstatat(destinationParent, destinationName.fileSystemRepresentation,
                                       &destinationState, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT;
      if (!sourceStable || !destinationAbsent ||
          renameatx_np(sourceParent, sourceName.fileSystemRepresentation,
                       destinationParent, destinationName.fileSystemRepresentation, RENAME_EXCL) != 0) {
        if (sourceDescriptor >= 0) close(sourceDescriptor);
        close(sourceParent); close(destinationParent);
        LWSetError(blockError, sourceStable && destinationAbsent
            ? DSHLocalWorkspaceAccessErrorIO : DSHLocalWorkspaceAccessErrorConflict);
        return NO;
      }
      struct stat installed = {};
      BOOL installedCorrectly = fstatat(destinationParent, destinationName.fileSystemRepresentation,
                                        &installed, AT_SYMLINK_NOFOLLOW) == 0 &&
          LWSameFileState(state, installed) &&
          (!S_ISREG(installed.st_mode) || installed.st_nlink == 1) &&
          fstat(sourceDescriptor, &current) == 0 && LWSameFileState(state, current) &&
          (!S_ISREG(current.st_mode) || current.st_nlink == 1);
      BOOL sourceGone = fstatat(sourceParent, sourceName.fileSystemRepresentation,
                                &current, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT;
      BOOL rolledBack = YES;
      if (!installedCorrectly || !sourceGone) {
        rolledBack = sourceGone && LWRestoreMoveToObservedSource(
            sourceParent, sourceName, destinationParent, destinationName);
        if (sourceDescriptor >= 0) close(sourceDescriptor);
        close(sourceParent); close(destinationParent);
        LWSetError(blockError, DSHLocalWorkspaceAccessErrorConflict); return NO;
      }
      BOOL synced = fsync(sourceParent) == 0 &&
          (destinationParent == sourceParent || fsync(destinationParent) == 0);
      if (!synced) {
        BOOL sourceGoneNow = fstatat(sourceParent, sourceName.fileSystemRepresentation,
                                     &current, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT;
        if (sourceGoneNow) {
          rolledBack = LWRestoreMoveToObservedSource(
              sourceParent, sourceName, destinationParent, destinationName);
          if (rolledBack) (void)fsync(sourceParent);
        } else {
          rolledBack = NO;
        }
        if (sourceDescriptor >= 0) close(sourceDescriptor);
        close(sourceParent); close(destinationParent);
        LWSetError(blockError, rolledBack ? DSHLocalWorkspaceAccessErrorIO : DSHLocalWorkspaceAccessErrorConflict);
        return NO;
      }
      entry = [self metadataForStat:installed path:destinationRelative error:blockError];
      close(sourceDescriptor);
      close(sourceParent); close(destinationParent);
      return entry != nil;
    } error:&error];
    if (!ok) { [self reject:reject error:error]; return; }
    resolve(@{ @"schema_version": @1, @"root": root, @"entry": entry, @"from": source });
  });
}

RISH_NATIVE_METHOD(listTrashV2,
                 listTrashV2Request:(id)requestValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSDictionary *request = [requestValue isKindOfClass:NSDictionary.class] ? requestValue : nil;
  if (!LWExact(request, @[@"schema_version", @"root", @"max_entries"]) || !LWSchemaOne(request[@"schema_version"]) || !LWIsSafeInteger(request[@"max_entries"], NO)) { [self dispatchInvalid:reject]; return; }
  NSError *validationError = nil;
  NSDictionary *root = LWRootFromRequest(request, &validationError);
  NSUInteger maximum = [request[@"max_entries"] unsignedIntegerValue];
  if (root == nil || maximum > LWMaxListEntries) { [self dispatchInvalid:reject]; return; }
  dispatch_async(self.workspaceQueue, ^{
    __block NSArray *entries = nil; __block NSUInteger invalidCount = 0; NSError *error = nil;
    BOOL ok = [self performRoot:root capabilities:[NSSet setWithObject:@"read"] block:^BOOL(int descriptor, NSError **blockError) {
      int trash = [self openTrashForRoot:descriptor create:NO error:blockError];
      if (trash == -2) {
        entries = @[];
        invalidCount = 0;
        return YES;
      }
      if (trash < 0) return NO;
      DIR *records = fdopendir(trash);
      if (records == nullptr) { close(trash); LWSetError(blockError, DSHLocalWorkspaceAccessErrorIO); return NO; }
      NSMutableArray *result = [NSMutableArray array];
      NSUInteger scanned = 0;
      struct dirent *record = nullptr;
      BOOL valid = YES;
      while (valid) {
        errno = 0; record = readdir(records);
        if (record == nullptr) { valid = errno == 0; break; }
        if (strcmp(record->d_name, ".") == 0 || strcmp(record->d_name, "..") == 0) continue;
        if (scanned >= maximum) { valid = NO; LWSetError(blockError, DSHLocalWorkspaceAccessErrorIO); break; }
        scanned += 1;
        NSString *trashId = [NSString stringWithUTF8String:record->d_name].lowercaseString;
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:trashId];
        int recordDescriptor = uuid == nil ? -1 : openat(dirfd(records), record->d_name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        NSError *recordError = nil;
        NSDictionary *receipt = recordDescriptor < 0 ? nil : [self trashReceiptAtRecord:recordDescriptor trashId:trashId state:nil error:&recordError];
        if (recordDescriptor >= 0) close(recordDescriptor);
        if (receipt == nil) invalidCount += 1; else [result addObject:receipt];
      }
      if (!valid) { closedir(records); return NO; }
      closedir(records);
      [result sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) { return [right[@"deleted_at"] compare:left[@"deleted_at"]]; }];
      entries = result;
      return YES;
    } error:&error];
    if (!ok) { [self reject:reject error:error]; return; }
    resolve(@{ @"schema_version": @1, @"root": root, @"entries": entries ?: @[], @"invalid_record_count": @(invalidCount) });
  });
}

RISH_NATIVE_METHOD(trashEntryV2,
                 trashEntryV2Request:(id)requestValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSDictionary *request = [requestValue isKindOfClass:NSDictionary.class] ? requestValue : nil;
  if (!LWExact(request, @[@"schema_version", @"root", @"path"]) || !LWSchemaOne(request[@"schema_version"]) || ![request[@"path"] isKindOfClass:NSString.class]) { [self dispatchInvalid:reject]; return; }
  NSError *validationError = nil;
  NSDictionary *root = LWRootFromRequest(request, &validationError);
  NSString *path = request[@"path"];
  if (root == nil || LWComponents(path, NO, &validationError) == nil) { [self dispatchInvalid:reject]; return; }
  dispatch_async(self.workspaceQueue, ^{
    __block NSDictionary *receipt = nil; NSError *error = nil;
    BOOL ok = [self performRoot:root capabilities:[NSSet setWithObject:@"write"] block:^BOOL(int descriptor, NSError **blockError) {
      NSString *name = nil; NSString *relative = nil;
      int parent = [self openParentForPath:path root:descriptor name:&name relative:&relative error:blockError];
      if (parent < 0) return NO;
      struct stat state = {};
      if (fstatat(parent, name.fileSystemRepresentation, &state, AT_SYMLINK_NOFOLLOW) != 0 || S_ISLNK(state.st_mode) || (!S_ISREG(state.st_mode) && !S_ISDIR(state.st_mode))) { close(parent); LWSetError(blockError, DSHLocalWorkspaceAccessErrorIO); return NO; }
      int sourceFlags = S_ISDIR(state.st_mode) ? (O_RDONLY | O_DIRECTORY) : O_RDONLY;
      int sourceDescriptor = openat(parent, name.fileSystemRepresentation, sourceFlags | O_CLOEXEC | O_NOFOLLOW);
      struct stat opened = {};
      BOOL sourceStable = sourceDescriptor >= 0 && fstat(sourceDescriptor, &opened) == 0 && LWSameFileState(state, opened) &&
          (!S_ISREG(state.st_mode) || state.st_nlink == 1);
      if (!sourceStable) {
        if (sourceDescriptor >= 0) close(sourceDescriptor);
        close(parent);
        LWSetError(blockError, DSHLocalWorkspaceAccessErrorConflict);
        return NO;
      }
      if (S_ISDIR(state.st_mode)) {
        NSUInteger treeCount = 0;
        if (!LWValidTree(sourceDescriptor, 0, &treeCount)) {
          close(sourceDescriptor);
          close(parent);
          LWSetError(blockError, DSHLocalWorkspaceAccessErrorConflict);
          return NO;
        }
      }
      int trash = [self openTrashForRoot:descriptor create:YES error:blockError];
      NSString *trashId = NSUUID.UUID.UUIDString.lowercaseString;
      BOOL recordCreated = trash >= 0 && mkdirat(trash, trashId.fileSystemRepresentation, 0700) == 0;
      int record = recordCreated ? openat(trash, trashId.fileSystemRepresentation,
                                          O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) : -1;
      if (record < 0) {
        if (recordCreated) (void)unlinkat(trash, trashId.fileSystemRepresentation, AT_REMOVEDIR);
        if (trash >= 0) close(trash);
        close(sourceDescriptor); close(parent);
        LWSetError(blockError, DSHLocalWorkspaceAccessErrorIO); return NO;
      }
      NSDictionary *candidate = @{ @"schema_version": @1, @"trash_id": trashId, @"original_path": relative, @"kind": S_ISDIR(state.st_mode) ? @"directory" : @"file", @"deleted_at": LWNow() };
      NSData *encoded = [NSJSONSerialization dataWithJSONObject:candidate options:NSJSONWritingSortedKeys error:nil];
      BOOL written = encoded != nil && [self atomicWrite:encoded parent:record name:@"metadata.json" createOnly:YES expectedRevision:nil error:blockError];
      struct stat current = {};
      sourceStable = written && fstat(sourceDescriptor, &current) == 0 && LWSameFileState(state, current) &&
          (!S_ISREG(current.st_mode) || current.st_nlink == 1) &&
          fstatat(parent, name.fileSystemRepresentation, &current, AT_SYMLINK_NOFOLLOW) == 0 &&
          LWSameFileState(state, current) && (!S_ISREG(current.st_mode) || current.st_nlink == 1);
      BOOL moved = sourceStable && renameatx_np(parent, name.fileSystemRepresentation, record, "payload", RENAME_EXCL) == 0;
      if (!moved) {
        unlinkat(record, "metadata.json", 0); close(record); unlinkat(trash, trashId.fileSystemRepresentation, AT_REMOVEDIR); close(trash); close(sourceDescriptor); close(parent);
        LWSetError(blockError, sourceStable ? DSHLocalWorkspaceAccessErrorIO : DSHLocalWorkspaceAccessErrorConflict); return NO;
      }
      struct stat payload = {};
      BOOL payloadAtDestination = fstatat(record, "payload", &payload, AT_SYMLINK_NOFOLLOW) == 0 &&
          LWSameFileState(state, payload) &&
          (!S_ISREG(payload.st_mode) || payload.st_nlink == 1);
      BOOL sourceDescriptorStable =
          fstat(sourceDescriptor, &current) == 0 && LWSameFileState(state, current) &&
          (!S_ISREG(current.st_mode) || current.st_nlink == 1);
      BOOL sourceGone = fstatat(parent, name.fileSystemRepresentation, &current,
                                AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT;
      BOOL movedSafely = payloadAtDestination && sourceDescriptorStable && sourceGone;
      if (!movedSafely) {
        BOOL rolledBack = sourceGone && LWRestoreMoveToObservedSource(
            parent, name, record, @"payload");
        if (rolledBack) {
          (void)unlinkat(record, "metadata.json", 0);
          (void)fsync(record);
          (void)unlinkat(trash, trashId.fileSystemRepresentation, AT_REMOVEDIR);
          (void)fsync(trash);
        }
        close(record); close(trash); close(sourceDescriptor); close(parent);
        LWSetError(blockError, rolledBack ? DSHLocalWorkspaceAccessErrorConflict : DSHLocalWorkspaceAccessErrorConflict);
        return NO;
      }
      BOOL synced = fsync(parent) == 0 && fsync(record) == 0 && fsync(trash) == 0;
      if (!synced) {
        BOOL sourceGoneNow = fstatat(parent, name.fileSystemRepresentation, &current,
                                     AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT;
        BOOL rolledBack = sourceGoneNow && LWRestoreMoveToObservedSource(
            parent, name, record, @"payload");
        if (rolledBack) {
          (void)fsync(parent);
          (void)unlinkat(record, "metadata.json", 0);
          (void)fsync(record);
          (void)unlinkat(trash, trashId.fileSystemRepresentation, AT_REMOVEDIR);
          (void)fsync(trash);
        }
        close(record); close(trash); close(sourceDescriptor); close(parent);
        LWSetError(blockError, rolledBack ? DSHLocalWorkspaceAccessErrorIO : DSHLocalWorkspaceAccessErrorConflict);
        return NO;
      }
      receipt = candidate;
      close(record); close(trash); close(sourceDescriptor); close(parent);
      return YES;
    } error:&error];
    if (!ok) { [self reject:reject error:error]; return; }
    resolve(@{ @"schema_version": @1, @"root": root, @"receipt": receipt });
  });
}

RISH_NATIVE_METHOD(restoreFromTrashV2,
                 restoreFromTrashV2Request:(id)requestValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSDictionary *request = [requestValue isKindOfClass:NSDictionary.class] ? requestValue : nil;
  if (!LWExact(request, @[@"schema_version", @"root", @"trash_id", @"destination_path"]) || !LWSchemaOne(request[@"schema_version"]) || !LWUUID(request[@"trash_id"]) || !(request[@"destination_path"] == NSNull.null || [request[@"destination_path"] isKindOfClass:NSString.class])) { [self dispatchInvalid:reject]; return; }
  NSError *validationError = nil;
  NSDictionary *root = LWRootFromRequest(request, &validationError);
  NSString *requestedDestination = request[@"destination_path"] == NSNull.null ? nil : request[@"destination_path"];
  if (root == nil || (requestedDestination != nil && LWComponents(requestedDestination, NO, &validationError) == nil)) { [self dispatchInvalid:reject]; return; }
  NSString *trashId = request[@"trash_id"];
  dispatch_async(self.workspaceQueue, ^{
    __block NSDictionary *entry = nil; __block NSString *originalPath = nil; NSError *error = nil;
    BOOL ok = [self performRoot:root capabilities:[NSSet setWithObject:@"write"] block:^BOOL(int descriptor, NSError **blockError) {
      int trash = [self openTrashForRoot:descriptor create:YES error:blockError];
      if (trash < 0) return NO;
      int record = openat(trash, trashId.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
      struct stat payloadState = {};
      NSDictionary *receipt = record < 0 ? nil : [self trashReceiptAtRecord:record trashId:trashId state:&payloadState error:blockError];
      originalPath = receipt[@"original_path"];
      NSString *destination = requestedDestination ?: originalPath;
      NSString *name = nil; NSString *relative = nil;
      int parent = receipt == nil ? -1 : [self openParentForPath:destination root:descriptor name:&name relative:&relative error:blockError];
      if (record < 0 || receipt == nil || parent < 0) { if (parent >= 0) close(parent); if (record >= 0) close(record); close(trash); return NO; }
      int payloadFlags = S_ISDIR(payloadState.st_mode) ? (O_RDONLY | O_DIRECTORY) : O_RDONLY;
      int payloadDescriptor = openat(record, "payload", payloadFlags | O_CLOEXEC | O_NOFOLLOW);
      struct stat payloadOpened = {};
      BOOL payloadHeld = payloadDescriptor >= 0 && fstat(payloadDescriptor, &payloadOpened) == 0 &&
          LWSameFileState(payloadState, payloadOpened) &&
          (!S_ISREG(payloadState.st_mode) || payloadState.st_nlink == 1);
      struct stat destinationState = {};
      BOOL destinationAbsent = fstatat(parent, name.fileSystemRepresentation, &destinationState,
                                       AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT;
      if (!payloadHeld || !destinationAbsent ||
          renameatx_np(record, "payload", parent, name.fileSystemRepresentation, RENAME_EXCL) != 0) {
        if (payloadDescriptor >= 0) close(payloadDescriptor);
        close(parent); close(record); close(trash);
        LWSetError(blockError, payloadHeld && destinationAbsent ? DSHLocalWorkspaceAccessErrorIO : DSHLocalWorkspaceAccessErrorConflict);
        return NO;
      }
      struct stat installed = {}, current = {};
      BOOL installedCorrectly = fstatat(parent, name.fileSystemRepresentation, &installed,
                                        AT_SYMLINK_NOFOLLOW) == 0 &&
          LWSameFileState(payloadState, installed) &&
          (!S_ISREG(installed.st_mode) || installed.st_nlink == 1) &&
          fstat(payloadDescriptor, &current) == 0 && LWSameFileState(payloadState, current) &&
          (!S_ISREG(current.st_mode) || current.st_nlink == 1);
      BOOL payloadGone = fstatat(record, "payload", &current, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT;
      if (!installedCorrectly || !payloadGone) {
        BOOL rolledBack = payloadGone && LWRestoreMoveToObservedSource(
            record, @"payload", parent, name);
        if (payloadDescriptor >= 0) close(payloadDescriptor);
        close(parent); close(record); close(trash);
        LWSetError(blockError, rolledBack ? DSHLocalWorkspaceAccessErrorConflict : DSHLocalWorkspaceAccessErrorConflict);
        return NO;
      }
      BOOL synced = [self filesV2Fsync:parent stage:@"restore_payload_fsync"] &&
          [self filesV2Fsync:record stage:@"restore_payload_record_fsync"];
      if (!synced) {
        BOOL rolledBack = payloadGone && LWRestoreMoveToObservedSource(
            record, @"payload", parent, name);
        if (rolledBack) (void)fsync(parent);
        if (payloadDescriptor >= 0) close(payloadDescriptor);
        close(parent); close(record); close(trash);
        LWSetError(blockError, rolledBack ? DSHLocalWorkspaceAccessErrorIO : DSHLocalWorkspaceAccessErrorConflict);
        return NO;
      }
      entry = [self metadataForStat:payloadState path:relative error:blockError];
      if (entry == nil) {
        BOOL rolledBack = payloadGone && LWRestoreMoveToObservedSource(
            record, @"payload", parent, name);
        if (rolledBack) (void)fsync(parent);
        close(payloadDescriptor); close(parent); close(record); close(trash);
        LWSetError(blockError, rolledBack ? DSHLocalWorkspaceAccessErrorIO : DSHLocalWorkspaceAccessErrorConflict);
        return NO;
      }

      /* Keep a second receipt name until the payload move and both directory
       * fsyncs are durable.  If metadata cleanup itself loses a fsync race,
       * restore metadata.json before rolling the payload back. */
      NSData *encodedReceipt = [NSJSONSerialization dataWithJSONObject:receipt
                                                                   options:NSJSONWritingSortedKeys
                                                                     error:nil];
      struct stat recoveryState = {};
      BOOL recoveryExists = fstatat(record, "metadata.recovery.json", &recoveryState,
                                   AT_SYMLINK_NOFOLLOW) == 0;
      BOOL recoveryReady = recoveryExists && S_ISREG(recoveryState.st_mode) &&
          recoveryState.st_nlink == 1;
      if (!recoveryReady) {
        recoveryReady = encodedReceipt != nil &&
            [self atomicWrite:encodedReceipt parent:record name:@"metadata.recovery.json"
                   createOnly:YES expectedRevision:nil error:blockError];
      }
      if (!recoveryReady) {
        BOOL rolledBack = payloadGone && LWRestoreMoveToObservedSource(
            record, @"payload", parent, name);
        if (rolledBack) (void)fsync(parent);
        close(payloadDescriptor); close(parent); close(record); close(trash);
        LWSetError(blockError, rolledBack ? DSHLocalWorkspaceAccessErrorIO : DSHLocalWorkspaceAccessErrorConflict);
        return NO;
      }
      struct stat metadataState = {};
      BOOL metadataExists = fstatat(record, "metadata.json", &metadataState,
                                    AT_SYMLINK_NOFOLLOW) == 0 &&
          S_ISREG(metadataState.st_mode) && metadataState.st_nlink == 1;
      BOOL metadataUnlinkFault = [self filesV2ShouldFail:@"restore_metadata_unlink"];
      if (metadataUnlinkFault) errno = EIO;
      BOOL metadataUnlinked = metadataExists && !metadataUnlinkFault &&
          unlinkat(record, "metadata.json", 0) == 0;
      BOOL metadataDurable = metadataUnlinked &&
          [self filesV2Fsync:record stage:@"restore_metadata_fsync"];
      if (!metadataDurable) {
        struct stat metadataAfter = {};
        BOOL metadataPresent = fstatat(record, "metadata.json", &metadataAfter,
                                       AT_SYMLINK_NOFOLLOW) == 0 &&
            S_ISREG(metadataAfter.st_mode) && metadataAfter.st_nlink == 1;
        BOOL metadataRestored = metadataPresent ||
            (encodedReceipt != nil && [self atomicWrite:encodedReceipt parent:record
                                                 name:@"metadata.json" createOnly:YES
                                         expectedRevision:nil error:nil] && fsync(record) == 0);
        BOOL rolledBack = payloadGone && (metadataRestored || recoveryReady) &&
            LWRestoreMoveToObservedSource(record, @"payload", parent, name);
        if (rolledBack) (void)fsync(parent);
        close(payloadDescriptor); close(parent); close(record); close(trash);
        LWSetError(blockError, rolledBack ? DSHLocalWorkspaceAccessErrorIO : DSHLocalWorkspaceAccessErrorConflict);
        return NO;
      }
      BOOL recoveryUnlinked = unlinkat(record, "metadata.recovery.json", 0) == 0 || errno == ENOENT;
      BOOL recoveryDurable = recoveryUnlinked &&
          [self filesV2Fsync:record stage:@"restore_recovery_fsync"];
      if (!recoveryDurable) {
        BOOL metadataRestored = encodedReceipt != nil &&
            [self atomicWrite:encodedReceipt parent:record name:@"metadata.json"
                   createOnly:YES expectedRevision:nil error:nil] && fsync(record) == 0;
        BOOL recoveryStillPresent = fstatat(record, "metadata.recovery.json", &recoveryState,
                                            AT_SYMLINK_NOFOLLOW) == 0 &&
            S_ISREG(recoveryState.st_mode) && recoveryState.st_nlink == 1;
        BOOL rolledBack = payloadGone && (metadataRestored || recoveryStillPresent) &&
            LWRestoreMoveToObservedSource(record, @"payload", parent, name);
        if (rolledBack) (void)fsync(parent);
        close(payloadDescriptor); close(parent); close(record); close(trash);
        LWSetError(blockError, rolledBack ? DSHLocalWorkspaceAccessErrorIO : DSHLocalWorkspaceAccessErrorConflict);
        return NO;
      }
      close(payloadDescriptor); close(parent); close(record);
      BOOL removed = unlinkat(trash, trashId.fileSystemRepresentation, AT_REMOVEDIR) == 0;
      BOOL trashSynced = removed && fsync(trash) == 0;
      close(trash);
      if (!removed || !trashSynced) {
        LWSetError(blockError, DSHLocalWorkspaceAccessErrorIO);
        return NO;
      }
      return YES;
    } error:&error];
    if (!ok) { [self reject:reject error:error]; return; }
    resolve(@{ @"schema_version": @1, @"root": root, @"entry": entry, @"trash_id": trashId, @"original_path": originalPath });
  });
}

RISH_NATIVE_METHOD(executePortableToolV2,
                 executePortableToolV2Request:(id)requestValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSDictionary *request = [requestValue isKindOfClass:NSDictionary.class] ? requestValue : nil;
  if (!LWExact(request, @[@"schema_version", @"root", @"tool", @"path", @"options"]) ||
      !LWSchemaOne(request[@"schema_version"]) || ![request[@"tool"] isKindOfClass:NSString.class] ||
      !LWToolNameValid(request[@"tool"]) || ![request[@"path"] isKindOfClass:NSString.class] ||
      !LWToolOptionsValid(request[@"options"])) {
    [self dispatchInvalid:reject];
    return;
  }
  NSError *error = nil;
  if (LWRootFromRequest(request, &error) == nil || LWComponents(request[@"path"], NO, &error) == nil) {
    [self dispatchInvalid:reject];
    return;
  }
  NSDictionary *root = LWRootFromRequest(request, &error);
  NSString *tool = request[@"tool"];
  NSString *path = request[@"path"];
  NSDictionary *options = request[@"options"];
  NSArray *components = LWComponents(path, NO, &error);
  if (root == nil || components == nil) {
    [self dispatchInvalid:reject];
    return;
  }
  dispatch_async(self.workspaceQueue, ^{
    __block NSDictionary *result = nil;
    NSError *operationError = nil;
    BOOL ok = [self performRoot:root capabilities:[NSSet setWithObject:@"read"] block:^BOOL(int descriptor, NSError **blockError) {
      NSString *name = nil; NSString *relative = nil;
      int parent = [self openParentForPath:path root:descriptor name:&name relative:&relative error:blockError];
      if (parent < 0) return NO;
      struct stat state = {};
      if (fstatat(parent, name.fileSystemRepresentation, &state, AT_SYMLINK_NOFOLLOW) != 0 || !S_ISREG(state.st_mode) || S_ISLNK(state.st_mode)) {
        close(parent); LWSetError(blockError, DSHLocalWorkspaceAccessErrorIO); return NO;
      }
      NSData *data = [self readDataInParent:parent name:name limit:LWMaxTextBytes metadata:&state error:blockError];
      close(parent);
      if (data == nil) return NO;
      NSArray *arguments = LWToolArguments(tool, options, blockError);
      if (arguments == nil) return NO;
      NSURL *staging = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"rish-tool-%@", NSUUID.UUID.UUIDString.lowercaseString]] isDirectory:YES];
      if (mkdir(staging.fileSystemRepresentation, 0700) != 0) { LWSetError(blockError, DSHLocalWorkspaceAccessErrorIO); return NO; }
      NSString *inputPath = [staging.path stringByAppendingPathComponent:@"input"];
      int input = open(inputPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
      BOOL wrote = input >= 0 && LWWriteAll(input, data) && fsync(input) == 0;
      if (input >= 0) close(input);
      if (!wrote) { LWRemoveToolStaging(staging); LWSetError(blockError, DSHLocalWorkspaceAccessErrorIO); return NO; }
      NSDictionary *toolRequest = @{
        @"protocol_version": @1,
        @"sandbox_root": staging.path,
        @"read_only": @YES,
        @"user": @"rish-mobile",
        @"hostname": @"ios-workspace",
        @"limits": @{ @"max_input_bytes": @(LWMaxTextBytes), @"max_output_bytes": @(LWMaxToolOutputBytes), @"max_filesystem_entries": @(LWMaxListEntries), @"max_recursion_depth": @16 },
        @"command": @{ @"program": tool, @"args": arguments, @"env": @{}, @"cwd": @"/", @"stdin": @[] },
      };
      NSData *encoded = [NSJSONSerialization dataWithJSONObject:toolRequest options:0 error:nil];
      char *raw = encoded == nil ? nullptr : rish_execute_applet_json((const char *)encoded.bytes, encoded.length);
      size_t length = raw == nullptr ? 0 : strnlen(raw, LWMaxToolOutputBytes + LWMaxTextBytes);
      NSData *responseData = raw == nullptr || length > LWMaxToolOutputBytes + LWMaxTextBytes ? nil : [NSData dataWithBytes:raw length:length];
      if (raw != nullptr) rish_string_free(raw);
      NSDictionary *response = responseData == nil ? nil : [NSJSONSerialization JSONObjectWithData:responseData options:0 error:nil];
      NSDictionary *outcome = [response[@"outcome"] isKindOfClass:NSDictionary.class] ? response[@"outcome"] : nil;
      NSDictionary *executionPath = [outcome[@"path"] isKindOfClass:NSDictionary.class] ? outcome[@"path"] : nil;
      NSData *stdoutData = LWBytesFromArray(outcome[@"stdout"]);
      NSData *stderrData = LWBytesFromArray(outcome[@"stderr"]);
      NSString *stdoutText = stdoutData == nil ? nil : [[NSString alloc] initWithData:stdoutData encoding:NSUTF8StringEncoding];
      NSString *stderrText = stderrData == nil ? nil : [[NSString alloc] initWithData:stderrData encoding:NSUTF8StringEncoding];
      NSNumber *okValue = [response[@"ok"] isKindOfClass:NSNumber.class] ? response[@"ok"] : nil;
      NSNumber *protocol = [response[@"protocol_version"] isKindOfClass:NSNumber.class] ? response[@"protocol_version"] : nil;
      NSNumber *exit = [outcome[@"exit_code"] isKindOfClass:NSNumber.class] ? outcome[@"exit_code"] : nil;
      NSString *kind = [executionPath[@"kind"] isKindOfClass:NSString.class] ? executionPath[@"kind"] : nil;
      NSString *nameValue = [executionPath[@"name"] isKindOfClass:NSString.class] ? executionPath[@"name"] : nil;
      NSInteger exitCode = exit.integerValue;
      BOOL valid = LWIsBooleanNumber(okValue) && okValue.boolValue &&
          LWIsSafeInteger(protocol, YES) && protocol.unsignedIntegerValue == rish_protocol_version() &&
          LWIsSafeInteger(exit, YES) && [kind isEqual:@"portable_applet"] &&
          [nameValue isEqual:tool] && stdoutText != nil && stderrText != nil &&
          (exitCode == 0 || ([tool isEqual:@"grep"] && exitCode == 1));
      LWRemoveToolStaging(staging);
      if (!valid) { LWSetError(blockError, DSHLocalWorkspaceAccessErrorIO); return NO; }
      result = @{ @"schema_version": @1, @"root": root, @"tool": tool, @"path": relative, @"exit_code": @(exitCode), @"stdout": stdoutText, @"stderr": stderrText, @"protocol_version": protocol, @"path_kind": kind };
      return YES;
    } error:&operationError];
    if (!ok) { [self reject:reject error:operationError]; return; }
    resolve(result);
  });
}

@end
