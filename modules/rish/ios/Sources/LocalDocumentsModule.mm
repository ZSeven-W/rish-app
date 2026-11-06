#import <Foundation/Foundation.h>
#import <RishNative/RishNativeModule.h>
#import <RishNative/RishUIKit.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "LocalProjectAccess.h"
#import "LocalWorkspaceAccess.h"
#import "LegacyBoundProjectRootAccess.h"
#import "DSHWorkspaceCanonical.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <sys/stat.h>
#include <unistd.h>

static const NSUInteger LDMaxPathBytes = 1024;
static const NSUInteger LDMaxEntries = 2000;
static const uint64_t LDMaxFileBytes = 64ULL * 1024 * 1024;
static const uint64_t LDMaxTotalBytes = 256ULL * 1024 * 1024;
static const NSUInteger LDMaxDepth = 64;
static const NSUInteger LDMaxExportItems = 100;
static const NSUInteger LDMaxJournalBytes = 64 * 1024;
static const NSUInteger LDMaxCommittedReceipts = 16;
static NSString *const LDJournalFileName = @".rish-document-journal.json";
static NSString *const LDReceiptStoreFileName = @".rish-document-receipts.json";

@interface DSHLocalWorkspaceAccess (LDLegacyBoundPrivate)
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

@interface DSHLocalWorkspaceAuthorityMutationGuard (LDLegacyBoundPrivate)
@property(nonatomic, weak, readonly) DSHLocalWorkspaceAccess *owner;
@end

static NSISO8601DateFormatter *LDCanonicalTimestampFormatter(void) {
  static NSISO8601DateFormatter *formatter = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                              NSISO8601DateFormatWithFractionalSeconds;
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
  });
  return formatter;
}

static NSString *LDNow(void) {
  return [LDCanonicalTimestampFormatter() stringFromDate:NSDate.date];
}

typedef NS_ENUM(NSInteger, LDPickerMode) {
  LDPickerModeNone = 0,
  LDPickerModeImport = 1,
  LDPickerModeExport = 2,
};

static NSError *LDError(DSHLocalWorkspaceAccessErrorCode code) {
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

static void LDSetError(NSError **error, DSHLocalWorkspaceAccessErrorCode code) {
  if (error != nil) *error = LDError(code);
}

static NSError *LDWorkspaceRootError(NSError *error) {
  if ([error.domain isEqual:DSHLocalWorkspaceAccessErrorDomain] &&
      (error.code == DSHLocalWorkspaceAccessErrorUnavailable ||
       error.code == DSHLocalWorkspaceAccessErrorStatusStale ||
       error.code == DSHLocalWorkspaceAccessErrorRootChanged)) {
    return LDError(DSHLocalWorkspaceAccessErrorRootChanged);
  }
  return error ?: LDError(DSHLocalWorkspaceAccessErrorRootChanged);
}

static NSError *LDProjectRelationError(NSError *error) {
  if ([error.domain isEqual:DSHLocalWorkspaceAccessErrorDomain]) {
    return LDWorkspaceRootError(error);
  }
  if ([error.domain isEqual:DSHLocalProjectAccessErrorDomain] &&
      error.code == DSHLocalProjectAccessErrorInvalidIdentifier) {
    return LDError(DSHLocalWorkspaceAccessErrorInvalid);
  }
  if ([error.domain isEqual:DSHLocalProjectAccessErrorDomain] &&
      error.code == DSHLocalProjectAccessErrorLockTimeout) {
    return LDError(DSHLocalWorkspaceAccessErrorBusy);
  }
  return LDError(DSHLocalWorkspaceAccessErrorRootChanged);
}

static NSString *LDStableCode(NSError *error) {
  NSString *code = [error.userInfo[@"code"] isKindOfClass:NSString.class]
      ? error.userInfo[@"code"] : nil;
  if (code != nil) return code;
  switch ((DSHLocalWorkspaceAccessErrorCode)error.code) {
    case DSHLocalWorkspaceAccessErrorInvalid: return @"E_WORKSPACE_INVALID";
    case DSHLocalWorkspaceAccessErrorNotFound: return @"E_WORKSPACE_NOT_FOUND";
    case DSHLocalWorkspaceAccessErrorBusy: return @"E_WORKSPACE_BUSY";
    case DSHLocalWorkspaceAccessErrorPickerBusy: return @"E_WORKSPACE_PICKER_BUSY";
    case DSHLocalWorkspaceAccessErrorSelectionExpired: return @"E_WORKSPACE_SELECTION_EXPIRED";
    case DSHLocalWorkspaceAccessErrorRevisionStale: return @"E_WORKSPACE_REVISION_STALE";
    case DSHLocalWorkspaceAccessErrorRevisionOverflow: return @"E_WORKSPACE_REVISION_OVERFLOW";
    case DSHLocalWorkspaceAccessErrorStatusStale: return @"E_WORKSPACE_STATUS_STALE";
    case DSHLocalWorkspaceAccessErrorRevoked: return @"E_WORKSPACE_REVOKED";
    case DSHLocalWorkspaceAccessErrorUnavailable: return @"E_WORKSPACE_UNAVAILABLE";
    case DSHLocalWorkspaceAccessErrorNotDownloaded: return @"E_WORKSPACE_NOT_DOWNLOADED";
    case DSHLocalWorkspaceAccessErrorImportRequired: return @"E_WORKSPACE_IMPORT_REQUIRED";
    case DSHLocalWorkspaceAccessErrorCapability: return @"E_WORKSPACE_CAPABILITY";
    case DSHLocalWorkspaceAccessErrorRootChanged: return @"E_WORKSPACE_ROOT_CHANGED";
    case DSHLocalWorkspaceAccessErrorReferenced: return @"E_WORKSPACE_REFERENCED";
    case DSHLocalWorkspaceAccessErrorConfirmation: return @"E_WORKSPACE_CONFIRMATION";
    case DSHLocalWorkspaceAccessErrorConflict: return @"E_WORKSPACE_CONFLICT";
    case DSHLocalWorkspaceAccessErrorPersistence: return @"E_WORKSPACE_PERSISTENCE";
    case DSHLocalWorkspaceAccessErrorIO: return @"E_WORKSPACE_IO";
  }
  return @"E_WORKSPACE_UNAVAILABLE";
}

static NSString *LDMessage(NSString *code) {
  NSDictionary *messages = @{
    @"E_WORKSPACE_INVALID": @"Workspace request is invalid.",
    @"E_WORKSPACE_NOT_FOUND": @"Workspace is not available.",
    @"E_WORKSPACE_BUSY": @"Workspace storage is busy.",
    @"E_WORKSPACE_PICKER_BUSY": @"Another workspace picker operation is active.",
    @"E_WORKSPACE_SELECTION_EXPIRED": @"Workspace picker selection has expired.",
    @"E_WORKSPACE_REVISION_STALE": @"Workspace binding is stale.",
    @"E_WORKSPACE_REVISION_OVERFLOW": @"Workspace binding cannot be advanced.",
    @"E_WORKSPACE_STATUS_STALE": @"Workspace authority is stale.",
    @"E_WORKSPACE_REVOKED": @"Workspace authority was revoked.",
    @"E_WORKSPACE_UNAVAILABLE": @"Workspace is unavailable.",
    @"E_WORKSPACE_NOT_DOWNLOADED": @"Workspace content is not downloaded.",
    @"E_WORKSPACE_IMPORT_REQUIRED": @"Workspace import is required.",
    @"E_WORKSPACE_CAPABILITY": @"Workspace capability is unavailable.",
    @"E_WORKSPACE_ROOT_CHANGED": @"Workspace root changed.",
    @"E_WORKSPACE_CONFLICT": @"Workspace storage changed concurrently.",
    @"E_WORKSPACE_PERSISTENCE": @"Workspace storage is invalid.",
    @"E_WORKSPACE_IO": @"Workspace operation failed.",
  };
  return messages[code] ?: messages[@"E_WORKSPACE_UNAVAILABLE"];
}

static BOOL LDIsBooleanNumber(id value) {
  return [value isKindOfClass:NSNumber.class] &&
      CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static BOOL LDSchemaOne(id value) {
  return [value isKindOfClass:NSNumber.class] && !LDIsBooleanNumber(value) && [value isEqual:@1];
}

static BOOL LDIsSafeInteger(id value, BOOL allowZero) {
  if (![value isKindOfClass:NSNumber.class] || LDIsBooleanNumber(value)) return NO;
  double number = [value doubleValue];
  return isfinite(number) && floor(number) == number && number >= 0 &&
      number <= 9007199254740991.0 && (allowZero || number > 0) &&
      !(number == 0 && signbit(number));
}

static BOOL LDUUID(id value) {
  if (![value isKindOfClass:NSString.class]) return NO;
  NSString *string = value;
  NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:
      @"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$" options:0 error:nil];
  NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:string];
  return [regex firstMatchInString:string options:0 range:NSMakeRange(0, string.length)] != nil &&
      uuid != nil && [uuid.UUIDString.lowercaseString isEqual:string];
}

static BOOL LDExact(NSDictionary *value, NSArray<NSString *> *keys) {
  if (![value isKindOfClass:NSDictionary.class] || value.count != keys.count) return NO;
  NSSet *expected = [NSSet setWithArray:keys];
  for (id key in value) if (![key isKindOfClass:NSString.class] || ![expected containsObject:key]) return NO;
  return YES;
}

static NSDictionary *LDRootFromRequest(NSDictionary *request, NSError **error) {
  NSDictionary *root = [request[@"root"] isKindOfClass:NSDictionary.class] ? request[@"root"] : nil;
  if (!LDExact(root, @[@"schema_version", @"workspace_id", @"binding_revision", @"project_id"]) ||
      !LDSchemaOne(root[@"schema_version"]) || !LDUUID(root[@"workspace_id"]) ||
      !LDIsSafeInteger(root[@"binding_revision"], NO) ||
      !(root[@"project_id"] == NSNull.null || LDUUID(root[@"project_id"]))) {
    LDSetError(error, DSHLocalWorkspaceAccessErrorInvalid);
    return nil;
  }
  return @{ @"schema_version": @1, @"workspace_id": root[@"workspace_id"],
            @"binding_revision": root[@"binding_revision"], @"project_id": root[@"project_id"] };
}

static BOOL LDStoredRootMatches(NSDictionary *stored, NSDictionary *root) {
  return [stored isKindOfClass:NSDictionary.class] &&
      [root isKindOfClass:NSDictionary.class] &&
      [stored[@"workspace_id"] isEqual:root[@"workspace_id"]] &&
      [stored[@"binding_revision"] isEqual:root[@"binding_revision"]] &&
      [stored[@"project_id"] isEqual:root[@"project_id"]];
}

static BOOL LDValidComponent(NSString *component) {
  if (![component isKindOfClass:NSString.class] || component.length == 0 ||
      [component lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > NAME_MAX ||
      [component isEqual:@"."] || [component isEqual:@".."] || [component containsString:@"\\"] ||
      [component rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return NO;
  NSString *folded = component.lowercaseString;
  return ![folded isEqual:@".git"] && ![folded isEqual:@".gitmodules"] &&
      ![folded isEqual:@".trash"] && ![folded hasPrefix:@".staging-"] &&
      ![folded hasPrefix:@".rish-write-"];
}

static BOOL LDSameFileState(struct stat left, struct stat right) {
  return left.st_dev == right.st_dev && left.st_ino == right.st_ino &&
      left.st_mode == right.st_mode && left.st_size == right.st_size &&
      left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec &&
      left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec;
}

static BOOL LDStatAtMatches(int directory, NSString *name, struct stat expected,
                            struct stat *actualOut) {
  struct stat actual = {};
  if (fstatat(directory, name.fileSystemRepresentation, &actual,
              AT_SYMLINK_NOFOLLOW) != 0 || !LDSameFileState(actual, expected) ||
      (S_ISREG(actual.st_mode) && actual.st_nlink != 1)) return NO;
  if (actualOut != nullptr) *actualOut = actual;
  return YES;
}

static BOOL LDStatAtRawMatches(int directory, NSString *name, struct stat expected,
                               struct stat *actualOut) {
  struct stat actual = {};
  if (fstatat(directory, name.fileSystemRepresentation, &actual,
              AT_SYMLINK_NOFOLLOW) != 0 || !LDSameFileState(actual, expected)) {
    return NO;
  }
  if (actualOut != nullptr) *actualOut = actual;
  return YES;
}

static BOOL LDSafeSwapBack(int directory,
                           NSString *destination,
                           NSString *backup,
                           struct stat expectedDestination,
                           struct stat expectedBackup) {
  if (!LDStatAtMatches(directory, destination, expectedDestination, nullptr) ||
      !LDStatAtMatches(directory, backup, expectedBackup, nullptr)) return NO;
  if (renameatx_np(directory, destination.fileSystemRepresentation,
                   directory, backup.fileSystemRepresentation, RENAME_SWAP) != 0) return NO;
  return LDStatAtMatches(directory, destination, expectedBackup, nullptr) &&
      LDStatAtMatches(directory, backup, expectedDestination, nullptr);
}

static BOOL LDRestoreMoveToObservedSource(int sourceDirectory,
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
  return LDStatAtRawMatches(sourceDirectory, source, observed, nullptr) &&
      (fstatat(destinationDirectory, destination.fileSystemRepresentation,
               &sourceState, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT);
}

static NSArray<NSString *> *LDComponents(id value, BOOL allowRoot, NSError **error) {
  NSString *path = [value isKindOfClass:NSString.class] ? value : nil;
  if (path == nil || [path lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > LDMaxPathBytes ||
      [path hasPrefix:@"/"] || [path containsString:@"\\"] ||
      [path rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) {
    LDSetError(error, DSHLocalWorkspaceAccessErrorInvalid); return nil;
  }
  if (path.length == 0) {
    if (allowRoot) return @[];
    LDSetError(error, DSHLocalWorkspaceAccessErrorInvalid); return nil;
  }
  NSArray<NSString *> *components = [path componentsSeparatedByString:@"/"];
  for (NSString *component in components) if (!LDValidComponent(component)) {
    LDSetError(error, DSHLocalWorkspaceAccessErrorInvalid); return nil;
  }
  return components;
}

static BOOL LDMatches(NSString *value, NSString *pattern) {
  NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
  return regex != nil && [regex firstMatchInString:value options:0 range:NSMakeRange(0, value.length)] != nil;
}

static BOOL LDDigest(id value) {
  return [value isKindOfClass:NSString.class] &&
      LDMatches(value, @"^[0-9a-f]{64}$");
}

static NSString *LDDocumentRequestSHA256(NSString *kind,
                                         NSDictionary *root,
                                         NSString *operationId,
                                         NSString *destinationPath,
                                         NSArray<NSString *> *sourcePaths) {
  NSDictionary *semanticRequest = @{
    @"domain": @"rish.local-documents.request.v1",
    @"operation": kind,
    @"operation_id": operationId,
    @"root": @{
      @"schema_version": @1,
      @"workspace_id": root[@"workspace_id"],
      @"binding_revision": root[@"binding_revision"],
      @"project_id": root[@"project_id"],
    },
    @"destination_path": destinationPath ?: @"",
    @"source_paths": sourcePaths ?: @[],
  };
  NSData *canonical = DSHWorkspaceCanonicalJSONData(semanticRequest, nil);
  return DSHWorkspaceSHA256Hex(canonical);
}

static BOOL LDValidStagingName(id value) {
  return [value isKindOfClass:NSString.class] &&
      LDMatches(value, @"^(import|export)-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$");
}

static BOOL LDValidTimestamp(id value) {
  if (![value isKindOfClass:NSString.class] ||
      !LDMatches(value, @"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$")) return NO;
  NSDate *date = [LDCanonicalTimestampFormatter() dateFromString:value];
  return date != nil &&
      [[LDCanonicalTimestampFormatter() stringFromDate:date] isEqual:value];
}

static BOOL LDUnsignedString(id value) {
  if (![value isKindOfClass:NSString.class] || [value length] == 0) return NO;
  NSRegularExpression *regex = [NSRegularExpression
      regularExpressionWithPattern:@"^[0-9]+$" options:0 error:nil];
  return [regex firstMatchInString:value options:0
                              range:NSMakeRange(0, [value length])] != nil;
}

static BOOL LDSignedString(id value) {
  if (![value isKindOfClass:NSString.class] || [value length] == 0) return NO;
  NSRegularExpression *regex = [NSRegularExpression
      regularExpressionWithPattern:@"^-?[0-9]+$" options:0 error:nil];
  return [regex firstMatchInString:value options:0
                              range:NSMakeRange(0, [value length])] != nil;
}

static NSDictionary *LDFileStateRecord(NSString *name, struct stat state) {
  return @{
    @"name" : name,
    @"device_id" : [NSString stringWithFormat:@"%llu", (unsigned long long)state.st_dev],
    @"inode_id" : [NSString stringWithFormat:@"%llu", (unsigned long long)state.st_ino],
    @"mode" : [NSString stringWithFormat:@"%llu", (unsigned long long)state.st_mode],
    @"size" : [NSString stringWithFormat:@"%llu", (unsigned long long)state.st_size],
    @"mtime_sec" : [NSString stringWithFormat:@"%lld", (long long)state.st_mtimespec.tv_sec],
    @"mtime_nsec" : [NSString stringWithFormat:@"%lld", (long long)state.st_mtimespec.tv_nsec],
  };
}

static BOOL LDFileStateRecordMatches(NSDictionary *record, NSString *name,
                                     struct stat state) {
  NSArray *keys = @[@"name", @"device_id", @"inode_id", @"mode", @"size",
                    @"mtime_sec", @"mtime_nsec"];
  if (!LDExact(record, keys) || ![record[@"name"] isEqual:name] ||
      !LDUnsignedString(record[@"device_id"]) || !LDUnsignedString(record[@"inode_id"]) ||
      !LDUnsignedString(record[@"mode"]) || !LDUnsignedString(record[@"size"]) ||
      !LDSignedString(record[@"mtime_sec"]) || !LDUnsignedString(record[@"mtime_nsec"])) return NO;
  return strtoull([record[@"device_id"] UTF8String], nullptr, 10) == (unsigned long long)state.st_dev &&
      strtoull([record[@"inode_id"] UTF8String], nullptr, 10) == (unsigned long long)state.st_ino &&
      strtoull([record[@"mode"] UTF8String], nullptr, 10) == (unsigned long long)state.st_mode &&
      strtoull([record[@"size"] UTF8String], nullptr, 10) == (unsigned long long)state.st_size &&
      strtoll([record[@"mtime_sec"] UTF8String], nullptr, 10) == (long long)state.st_mtimespec.tv_sec &&
      strtoll([record[@"mtime_nsec"] UTF8String], nullptr, 10) == (long long)state.st_mtimespec.tv_nsec;
}

static BOOL LDWriteData(int descriptor, NSData *data) {
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

static BOOL LDJournalValid(NSDictionary *journal) {
  NSArray *keys = @[
    @"schema_version", @"operation_id", @"request_sha256", @"kind", @"phase", @"workspace_id",
    @"binding_revision", @"project_id", @"destination_path", @"source_paths", @"staging_name",
    @"entry_names", @"entry_states", @"created_at", @"updated_at",
  ];
  if (!LDExact(journal, keys) || !LDSchemaOne(journal[@"schema_version"]) ||
      !LDUUID(journal[@"operation_id"]) ||
      !LDDigest(journal[@"request_sha256"]) ||
      !([journal[@"kind"] isEqual:@"import"] || [journal[@"kind"] isEqual:@"export"]) ||
      !([journal[@"phase"] isEqual:@"prepared"] || [journal[@"phase"] isEqual:@"staged"] ||
        [journal[@"phase"] isEqual:@"publishing"] || [journal[@"phase"] isEqual:@"needs_recovery"] ||
        [journal[@"phase"] isEqual:@"committed"]) ||
      !LDUUID(journal[@"workspace_id"]) || !LDIsSafeInteger(journal[@"binding_revision"], NO) ||
      !(journal[@"project_id"] == NSNull.null || LDUUID(journal[@"project_id"])) ||
      !([journal[@"destination_path"] isKindOfClass:NSString.class] &&
        LDComponents(journal[@"destination_path"], YES, nil) != nil) ||
      ![journal[@"source_paths"] isKindOfClass:NSArray.class] || [journal[@"source_paths"] count] > LDMaxExportItems ||
      !LDValidStagingName(journal[@"staging_name"]) || ![journal[@"entry_names"] isKindOfClass:NSArray.class] ||
      [journal[@"entry_names"] count] > LDMaxExportItems || !LDValidTimestamp(journal[@"created_at"]) ||
      !LDValidTimestamp(journal[@"updated_at"]) || ![journal[@"entry_states"] isKindOfClass:NSArray.class] ||
      [journal[@"entry_states"] count] > [journal[@"entry_names"] count]) return NO;
  for (id path in journal[@"source_paths"]) if (LDComponents(path, NO, nil) == nil) return NO;
  NSMutableSet<NSString *> *entryNames = [NSMutableSet set];
  for (id name in journal[@"entry_names"]) {
    if (!LDValidComponent(name) || [entryNames containsObject:name]) return NO;
    [entryNames addObject:name];
  }
  NSMutableSet<NSString *> *stateNames = [NSMutableSet set];
  NSArray *stateKeys = @[@"name", @"device_id", @"inode_id", @"mode", @"size", @"mtime_sec", @"mtime_nsec"];
  for (id state in journal[@"entry_states"]) {
    NSString *name = [state isKindOfClass:NSDictionary.class] ? state[@"name"] : nil;
    if (![state isKindOfClass:NSDictionary.class] || !LDExact(state, stateKeys) ||
        ![name isKindOfClass:NSString.class] || ![entryNames containsObject:name] ||
        [stateNames containsObject:name] || !LDUnsignedString(state[@"device_id"]) ||
      !LDUnsignedString(state[@"inode_id"]) || !LDUnsignedString(state[@"mode"]) ||
        !LDUnsignedString(state[@"size"]) || !LDSignedString(state[@"mtime_sec"]) ||
        !LDUnsignedString(state[@"mtime_nsec"])) return NO;
    [stateNames addObject:name];
  }
  NSString *expectedDigest = LDDocumentRequestSHA256(
      journal[@"kind"],
      @{
        @"schema_version": @1,
        @"workspace_id": journal[@"workspace_id"],
        @"binding_revision": journal[@"binding_revision"],
        @"project_id": journal[@"project_id"],
      },
      journal[@"operation_id"], journal[@"destination_path"], journal[@"source_paths"]);
  return expectedDigest != nil && [journal[@"request_sha256"] isEqual:expectedDigest];
}

static BOOL LDCompactReceiptValid(NSDictionary *receipt) {
  NSArray *keys = @[
    @"schema_version", @"receipt_kind", @"operation_id", @"request_sha256", @"kind", @"phase",
    @"workspace_id", @"binding_revision", @"project_id", @"destination_path", @"entry_count",
    @"created_at", @"updated_at",
  ];
  return LDExact(receipt, keys) && LDSchemaOne(receipt[@"schema_version"]) &&
      [receipt[@"receipt_kind"] isEqual:@"compact_terminal"] &&
      LDUUID(receipt[@"operation_id"]) &&
      LDDigest(receipt[@"request_sha256"]) &&
      ([receipt[@"kind"] isEqual:@"import"] || [receipt[@"kind"] isEqual:@"export"]) &&
      [receipt[@"phase"] isEqual:@"committed"] && LDUUID(receipt[@"workspace_id"]) &&
      LDIsSafeInteger(receipt[@"binding_revision"], NO) &&
      (receipt[@"project_id"] == NSNull.null || LDUUID(receipt[@"project_id"])) &&
      [receipt[@"destination_path"] isKindOfClass:NSString.class] &&
      LDComponents(receipt[@"destination_path"], YES, nil) != nil &&
      LDIsSafeInteger(receipt[@"entry_count"], YES) &&
      [receipt[@"entry_count"] unsignedIntegerValue] <= LDMaxExportItems &&
      LDValidTimestamp(receipt[@"created_at"]) && LDValidTimestamp(receipt[@"updated_at"]);
}

static NSDictionary *LDCompactReceiptFromJournal(NSDictionary *journal) {
  NSUInteger count = [journal[@"kind"] isEqual:@"import"]
      ? [journal[@"entry_names"] count] : [journal[@"source_paths"] count];
  return @{
    @"schema_version": @1,
    @"receipt_kind": @"compact_terminal",
    @"operation_id": journal[@"operation_id"],
    @"request_sha256": journal[@"request_sha256"],
    @"kind": journal[@"kind"],
    @"phase": @"committed",
    @"workspace_id": journal[@"workspace_id"],
    @"binding_revision": journal[@"binding_revision"],
    @"project_id": journal[@"project_id"],
    @"destination_path": journal[@"destination_path"],
    @"entry_count": @(count),
    @"created_at": journal[@"created_at"],
    @"updated_at": journal[@"updated_at"],
  };
}

static NSData *LDReceiptStoreData(NSArray<NSDictionary *> *receipts) {
  NSDictionary *store = @{ @"schema_version": @1, @"receipts": receipts ?: @[] };
  return [NSJSONSerialization dataWithJSONObject:store options:NSJSONWritingSortedKeys error:nil];
}

static BOOL LDReceiptStoreValid(NSDictionary *store) {
  if (!LDExact(store, @[@"schema_version", @"receipts"]) ||
      !LDSchemaOne(store[@"schema_version"]) ||
      ![store[@"receipts"] isKindOfClass:NSArray.class] ||
      [store[@"receipts"] count] > LDMaxCommittedReceipts) return NO;
  NSMutableSet<NSString *> *operationIds = [NSMutableSet set];
  for (id value in store[@"receipts"]) {
    if ((!LDJournalValid(value) && !LDCompactReceiptValid(value)) ||
        ![value[@"phase"] isEqual:@"committed"] ||
        [operationIds containsObject:value[@"operation_id"]]) return NO;
    [operationIds addObject:value[@"operation_id"]];
  }
  return YES;
}

/* Atomic store replacement used by both the active journal and the bounded
 * committed-receipt store.  Existing files are swapped, verified by raw
 * inode, synced, and only then is the old copy removed. */
static BOOL LDAtomicWriteNamed(int rootDescriptor, NSString *name, NSData *data,
                               NSError **error) {
  NSString *temporary = [NSString stringWithFormat:@".rish-document-tmp-%@",
                           NSUUID.UUID.UUIDString.lowercaseString];
  int descriptor = openat(rootDescriptor, temporary.fileSystemRepresentation,
                          O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
  BOOL ok = descriptor >= 0 && LDWriteData(descriptor, data) && fsync(descriptor) == 0;
  struct stat replacementState = {};
  if (ok) ok = fstat(descriptor, &replacementState) == 0 &&
      S_ISREG(replacementState.st_mode) && replacementState.st_nlink == 1;
  if (descriptor >= 0) close(descriptor);
  struct stat priorState = {};
  BOOL priorExists = fstatat(rootDescriptor, name.fileSystemRepresentation,
                             &priorState, AT_SYMLINK_NOFOLLOW) == 0;
  int priorErrno = errno;
  if (ok && !priorExists && priorErrno != ENOENT) ok = NO;
  if (ok && priorExists && (!S_ISREG(priorState.st_mode) || priorState.st_nlink != 1)) ok = NO;
  BOOL swapped = NO;
  BOOL rolledBack = NO;
  if (ok) {
    int flags = priorExists ? RENAME_SWAP : RENAME_EXCL;
    swapped = renameatx_np(rootDescriptor, temporary.fileSystemRepresentation,
                           rootDescriptor, name.fileSystemRepresentation, flags) == 0;
    ok = swapped;
    if (ok && priorExists) {
      ok = LDStatAtMatches(rootDescriptor, name, replacementState, nullptr) &&
          LDStatAtMatches(rootDescriptor, temporary, priorState, nullptr);
    }
    if (ok) ok = fsync(rootDescriptor) == 0;
    if (ok && priorExists) {
      ok = unlinkat(rootDescriptor, temporary.fileSystemRepresentation, 0) == 0 &&
          fsync(rootDescriptor) == 0;
    }
    if (!ok && swapped && priorExists) {
      rolledBack = LDSafeSwapBack(rootDescriptor, name, temporary,
                                  replacementState, priorState);
      if (rolledBack) (void)fsync(rootDescriptor);
    } else if (!ok && swapped && !priorExists &&
               LDStatAtMatches(rootDescriptor, name, replacementState, nullptr)) {
      rolledBack = unlinkat(rootDescriptor, name.fileSystemRepresentation, 0) == 0 &&
          fsync(rootDescriptor) == 0;
    }
  }
  if (!ok && (!swapped || rolledBack || !priorExists)) {
    (void)unlinkat(rootDescriptor, temporary.fileSystemRepresentation, 0);
  }
  if (!ok) LDSetError(error, DSHLocalWorkspaceAccessErrorIO);
  return ok;
}

static NSString *LDOperationStatusForPhase(NSString *phase) {
  if ([phase isEqual:@"committed"]) return @"committed";
  if ([phase isEqual:@"needs_recovery"]) return @"needs_recovery";
  if ([phase isEqual:@"prepared"] || [phase isEqual:@"staged"] || [phase isEqual:@"publishing"]) return @"in_progress";
  return @"needs_recovery";
}

static NSData *LDReadDescriptor(int descriptor, NSUInteger maximum, NSError **error) {
  if (descriptor < 0) {
    LDSetError(error, DSHLocalWorkspaceAccessErrorIO); return nil;
  }
  NSMutableData *data = [NSMutableData dataWithCapacity:4096];
  uint8_t buffer[8192];
  while (data.length <= maximum) {
    ssize_t amount = read(descriptor, buffer, sizeof(buffer));
    if (amount < 0 && errno == EINTR) continue;
    if (amount < 0) { LDSetError(error, DSHLocalWorkspaceAccessErrorIO); return nil; }
    if (amount == 0) return data;
    if (data.length + (NSUInteger)amount > maximum) {
      LDSetError(error, DSHLocalWorkspaceAccessErrorIO); return nil;
    }
    [data appendBytes:buffer length:(NSUInteger)amount];
  }
  LDSetError(error, DSHLocalWorkspaceAccessErrorIO);
  return nil;
}

static BOOL LDRemoveTree(int descriptor, NSError **error) {
  int duplicate = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  DIR *directory = duplicate < 0 ? nullptr : fdopendir(duplicate);
  if (directory == nullptr) {
    if (duplicate >= 0) close(duplicate);
    LDSetError(error, DSHLocalWorkspaceAccessErrorIO); return NO;
  }
  struct dirent *entry = nullptr; BOOL valid = YES;
  while (valid) {
    errno = 0; entry = readdir(directory);
    if (entry == nullptr) { valid = errno == 0; break; }
    if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
    struct stat state = {};
    if (fstatat(dirfd(directory), entry->d_name, &state, AT_SYMLINK_NOFOLLOW) != 0 || S_ISLNK(state.st_mode)) {
      valid = NO; break;
    }
    if (S_ISDIR(state.st_mode)) {
      int child = openat(dirfd(directory), entry->d_name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
      if (child < 0 || !LDRemoveTree(child, error) || unlinkat(dirfd(directory), entry->d_name, AT_REMOVEDIR) != 0) valid = NO;
      if (child >= 0) close(child);
    } else if (S_ISREG(state.st_mode) && state.st_nlink == 1) {
      if (unlinkat(dirfd(directory), entry->d_name, 0) != 0) valid = NO;
    } else {
      valid = NO;
    }
    if (!valid && error != nil && *error == nil) LDSetError(error, DSHLocalWorkspaceAccessErrorIO);
  }
  closedir(directory);
  if (valid && fsync(descriptor) != 0) {
    LDSetError(error, DSHLocalWorkspaceAccessErrorIO); valid = NO;
  }
  return valid;
}

@interface LocalDocumentsModule : NSObject <RishNativeModule, UIDocumentPickerDelegate>
@property(nonatomic, strong) dispatch_queue_t documentQueue;
@property(nonatomic, strong) DSHLocalWorkspaceAccess *access;
@property(nonatomic, strong) DSHLocalProjectAccess *projectAccess;
@property(nonatomic, copy) RishResolveBlock pendingResolve;
@property(nonatomic, copy) RishRejectBlock pendingReject;
@property(nonatomic) LDPickerMode pendingMode;
@property(nonatomic, copy) NSDictionary *pendingRoot;
@property(nonatomic, copy) NSString *pendingDestinationPath;
@property(nonatomic, copy) NSArray<NSString *> *pendingSourcePaths;
@property(nonatomic, copy) NSString *pendingOperationId;
@property(nonatomic, strong) NSURL *pendingExportStaging;
@property(nonatomic) BOOL pendingCallbackSettled;
@property(nonatomic) NSUInteger pendingGeneration;
@property(nonatomic, weak) UIDocumentPickerViewController *pendingController;
@property(nonatomic) BOOL didRecoverStaging;
- (BOOL)recoverStagingJournal:(NSError **)error;
- (BOOL)saveStagingJournal:(NSDictionary *)journal error:(NSError **)error;
- (nullable NSDictionary *)loadStagingJournal:(NSError **)error;
- (nullable NSArray<NSDictionary *> *)loadCommittedReceipts:(NSError **)error;
- (BOOL)saveCommittedReceipts:(NSArray<NSDictionary *> *)receipts error:(NSError **)error;
- (BOOL)archiveCommittedJournal:(NSDictionary *)journal error:(NSError **)error;
- (nullable NSDictionary *)committedReceiptForOperationId:(NSString *)operationId
                                                      root:(NSDictionary *)root
                                                     error:(NSError **)error;
- (nullable NSDictionary *)committedImportResultForJournal:(NSDictionary *)journal
                                                       root:(NSDictionary *)root;
- (BOOL)validateCommittedReceipt:(NSDictionary *)receipt
                            kind:(NSString *)kind
                            root:(NSDictionary *)root
                  destinationPath:(NSString *)destinationPath
                       sourcePaths:(NSArray<NSString *> *)sourcePaths;
- (BOOL)removeCommittedReceiptForOperationId:(NSString *)operationId
                                         root:(NSDictionary *)root
                                        error:(NSError **)error;
- (BOOL)removeStagingJournal:(NSError **)error;
- (int)openStagingRootCreating:(BOOL)create error:(NSError **)error;
- (nullable NSURL *)newStagingDirectory:(NSString *)prefix
                              operationId:(NSString *)operationId
                                   error:(NSError **)error;
- (nullable NSURL *)existingStagingDirectory:(NSString *)prefix
                                   operationId:(NSString *)operationId
                                        error:(NSError **)error;
- (BOOL)removeStagingDirectoryNamed:(NSString *)stagingName
                              error:(NSError **)error;
- (BOOL)reconcileJournal:(NSDictionary *)journal error:(NSError **)error;
- (BOOL)canCleanupUnpublishedJournal:(NSDictionary *)journal error:(NSError **)error;
- (BOOL)publishJournal:(NSDictionary *)journal
                  root:(NSDictionary *)root
               entries:(NSArray<NSDictionary *> **)entries
                 error:(NSError **)error;
@end

@implementation LocalDocumentsModule

RISH_NATIVE_MODULE(LocalDocuments)

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
    _documentQueue = dispatch_queue_create("dev.zseven.rish.local-documents-v2", DISPATCH_QUEUE_SERIAL);
    _pendingMode = LDPickerModeNone;
    _pendingCallbackSettled = NO;
    _pendingGeneration = 0;
    _didRecoverStaging = NO;
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
              if (resolverError != nil) *resolverError = projectError ?: LDError(DSHLocalWorkspaceAccessErrorUnavailable);
              return NO;
            }
            if (evidence != nil) *evidence = [resolved copy];
            return YES;
          }
          faultHook:nil];
      _projectAccess = [[DSHLocalProjectAccess alloc]
          initWithProjectsRootURL:[legacyAccess projectsRootURLWithError:nil]
                 workspaceAccess:_access hook:nil];
      dispatch_async(_documentQueue, ^{
        NSError *recoveryError = nil;
        [self recoverStagingJournal:&recoveryError];
        self.didRecoverStaging = recoveryError == nil;
      });
    }
  }
  return self;
}

- (void)reject:(RishRejectBlock)reject error:(NSError *)error {
  if (error == nil) error = LDError(DSHLocalWorkspaceAccessErrorUnavailable);
  NSString *code = LDStableCode(error);
  reject(code, LDMessage(code), nil);
}

- (void)dispatchInvalid:(RishRejectBlock)reject {
  dispatch_async(self.documentQueue, ^{
    [self reject:reject error:LDError(DSHLocalWorkspaceAccessErrorInvalid)];
  });
}

- (nullable NSDictionary *)legacyBoundRootForRootRef:(NSDictionary *)root
                                                error:(NSError **)error {
  NSError *authorityError = nil;
  __attribute__((objc_precise_lifetime))
  DSHLocalWorkspaceAuthorityMutationGuard *guard =
      [self.access acquireAuthorityMutationGuard:&authorityError];
  if (guard == nil || guard.owner != self.access ||
      ![self.access ensurePrivateLayoutLocked:&authorityError]) {
    if (error != nil) *error = LDWorkspaceRootError(authorityError);
    return nil;
  }
  NSDictionary *registry = [self.access loadRegistry:&authorityError digest:nil];
  NSDictionary *record = registry == nil ? nil :
      [self.access recordInRegistry:registry workspaceId:root[@"workspace_id"]];
  if (record == nil ||
      ![record[@"binding_revision"] isEqual:root[@"binding_revision"]]) {
    if (error != nil) *error = LDError(record == nil
        ? DSHLocalWorkspaceAccessErrorNotFound
        : DSHLocalWorkspaceAccessErrorRevisionStale);
    return nil;
  }
  NSDictionary *authority =
      [self.access loadAuthorityForRecord:record error:&authorityError];
  NSString *fingerprint = authority[@"root_fingerprint_sha256"];
  if (authority == nil || ![fingerprint isKindOfClass:NSString.class] ||
      fingerprint.length != 64) {
    if (error != nil) *error = LDWorkspaceRootError(authorityError);
    return nil;
  }
  NSMutableArray<NSString *> *capabilities = [NSMutableArray array];
  NSSet *available = nil;
  if ([record[@"root_locator_kind"] isEqual:@"legacy_app_owned"]) {
    available = [self.access verifiedLegacyCapabilitiesForRecord:record
                                                       authority:authority];
    if (available == nil ||
        ![record[@"legacy_project_id"] isEqual:root[@"project_id"]]) {
      if (error != nil) *error = LDError(DSHLocalWorkspaceAccessErrorRootChanged);
      return nil;
    }
  } else if ([record[@"root_locator_kind"] isEqual:@"documents_owned"]) {
    available = [NSSet setWithArray:@[@"read", @"write", @"git"]];
  } else {
    if (error != nil) *error = LDError(DSHLocalWorkspaceAccessErrorCapability);
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

- (BOOL)performRoot:(NSDictionary *)root
      capabilities:(NSSet<NSString *> *)capabilities
             block:(BOOL (^)(int descriptor, NSError **error))block
             error:(NSError **)error {
  if (self.access == nil || root == nil || block == nil) {
    LDSetError(error, DSHLocalWorkspaceAccessErrorUnavailable);
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
            ? LDError(DSHLocalWorkspaceAccessErrorRootChanged)
            : (boundError.code == DSHLegacyBoundProjectRootAccessErrorInvalid
                   ? LDError(DSHLocalWorkspaceAccessErrorInvalid)
                   : LDError(DSHLocalWorkspaceAccessErrorCapability));
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
        if (error != nil) *error = LDProjectRelationError(projectError);
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
        if (error != nil) *error = LDError(DSHLocalWorkspaceAccessErrorRootChanged);
        return NO;
      }
    }
    NSError *blockError = nil;
    BOOL result = NO;
    @try {
      int descriptor = projectBound
          ? projectLease.workspaceRootDescriptor : lease.rootDescriptor;
      result = block(descriptor, &blockError);
    }
    @catch (__unused NSException *exception) {
      result = NO; blockError = LDError(DSHLocalWorkspaceAccessErrorIO);
    }
    if (!result) {
      if (error != nil) *error = blockError ?: LDError(DSHLocalWorkspaceAccessErrorIO);
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
        if (error != nil) *error = LDProjectRelationError(relationError);
        return NO;
      }
      return YES;
    }
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
      if (error != nil) *error = LDWorkspaceRootError(afterError);
      return NO;
    }
    return YES;
  }
  if (leaseError.code != DSHLocalWorkspaceAccessErrorCapability) {
    if (error != nil) *error = LDWorkspaceRootError(leaseError);
    return NO;
  }
  if (projectBound) {
    if (error != nil) *error = leaseError ?: LDError(DSHLocalWorkspaceAccessErrorCapability);
    return NO;
  }
  return [self.access performCoordinatedWorkspaceOperationForId:root[@"workspace_id"]
      expectedBindingRevision:[root[@"binding_revision"] unsignedIntegerValue]
      requiredCapabilities:requiredCapabilities block:block error:error];
}

- (int)openDirectory:(NSArray<NSString *> *)components root:(int)rootDescriptor error:(NSError **)error {
  int descriptor = dup(rootDescriptor);
  if (descriptor < 0) { LDSetError(error, DSHLocalWorkspaceAccessErrorUnavailable); return -1; }
  for (NSString *component in components) {
    NSString *resolved = [self resolvedComponent:component directory:descriptor allowMissing:NO error:error];
    if (resolved == nil) { close(descriptor); return -1; }
    struct stat state = {};
    if (fstatat(descriptor, resolved.fileSystemRepresentation, &state, AT_SYMLINK_NOFOLLOW) != 0 || !S_ISDIR(state.st_mode) || S_ISLNK(state.st_mode)) {
      close(descriptor); LDSetError(error, DSHLocalWorkspaceAccessErrorUnavailable); return -1;
    }
    int next = openat(descriptor, resolved.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    close(descriptor);
    if (next < 0) { LDSetError(error, DSHLocalWorkspaceAccessErrorUnavailable); return -1; }
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
  if (errno != ENOENT) { LDSetError(error, DSHLocalWorkspaceAccessErrorUnavailable); return nil; }
  NSString *folded = requested.precomposedStringWithCanonicalMapping.lowercaseString;
  int duplicate = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  DIR *contents = duplicate < 0 ? nullptr : fdopendir(duplicate);
  if (contents == nullptr) { if (duplicate >= 0) close(duplicate); LDSetError(error, DSHLocalWorkspaceAccessErrorUnavailable); return nil; }
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
  if (!valid) { LDSetError(error, DSHLocalWorkspaceAccessErrorConflict); return nil; }
  if (match != nil) return match;
  if (allowMissing) return requested;
  LDSetError(error, DSHLocalWorkspaceAccessErrorUnavailable);
  return nil;
}

- (int)openParent:(NSString *)path root:(int)rootDescriptor name:(NSString **)name relative:(NSString **)relative error:(NSError **)error {
  NSArray<NSString *> *components = LDComponents(path, NO, error);
  if (components == nil || components.count == 0) return -1;
  NSArray *parents = components.count > 1 ? [components subarrayWithRange:NSMakeRange(0, components.count - 1)] : @[];
  int descriptor = [self openDirectory:parents root:rootDescriptor error:error];
  if (descriptor < 0) return -1;
  NSString *resolved = [self resolvedComponent:components.lastObject directory:descriptor allowMissing:YES error:error];
  if (resolved == nil) { close(descriptor); return -1; }
  if (name != nil) *name = resolved;
  if (relative != nil) *relative = [components componentsJoinedByString:@"/"];
  return descriptor;
}

- (int)openStagingRootCreating:(BOOL)create error:(NSError **)error {
  NSURL *support = [[NSFileManager defaultManager] URLForDirectory:NSApplicationSupportDirectory
                                                            inDomain:NSUserDomainMask
                                                   appropriateForURL:nil
                                                              create:YES
                                                               error:error];
  if (support == nil) return -1;
  int supportDescriptor = open(support.fileSystemRepresentation,
                               O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (supportDescriptor < 0) {
    LDSetError(error, DSHLocalWorkspaceAccessErrorIO); return -1;
  }
  NSURL *stagingRoot = [support URLByAppendingPathComponent:@"document-staging" isDirectory:YES];
  struct stat state = {};
  if (fstatat(supportDescriptor, "document-staging", &state, AT_SYMLINK_NOFOLLOW) != 0) {
    if (errno == ENOENT && !create) { close(supportDescriptor); return -2; }
    if (errno != ENOENT || mkdirat(supportDescriptor, "document-staging", 0700) != 0 || fsync(supportDescriptor) != 0) {
      close(supportDescriptor); LDSetError(error, DSHLocalWorkspaceAccessErrorIO); return -1;
    }
  } else if (!S_ISDIR(state.st_mode) || S_ISLNK(state.st_mode)) {
    close(supportDescriptor); LDSetError(error, DSHLocalWorkspaceAccessErrorIO); return -1;
  }
  int descriptor = openat(supportDescriptor, "document-staging", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  close(supportDescriptor);
  if (descriptor < 0) LDSetError(error, DSHLocalWorkspaceAccessErrorIO);
  (void)stagingRoot;
  return descriptor;
}

- (NSURL *)newStagingDirectory:(NSString *)prefix
                     operationId:(NSString *)operationId
                          error:(NSError **)error {
  if (!LDUUID(operationId) || (![prefix isEqual:@"import"] && ![prefix isEqual:@"export"])) {
    LDSetError(error, DSHLocalWorkspaceAccessErrorInvalid); return nil;
  }
  int rootDescriptor = [self openStagingRootCreating:YES error:error];
  if (rootDescriptor < 0) return nil;
  NSString *name = [NSString stringWithFormat:@"%@-%@", prefix, operationId];
  struct stat state = {};
  if (fstatat(rootDescriptor, name.fileSystemRepresentation, &state, AT_SYMLINK_NOFOLLOW) != 0) {
    if (errno != ENOENT || mkdirat(rootDescriptor, name.fileSystemRepresentation, 0700) != 0 || fsync(rootDescriptor) != 0) {
      close(rootDescriptor); LDSetError(error, DSHLocalWorkspaceAccessErrorIO); return nil;
    }
  } else if (!S_ISDIR(state.st_mode) || S_ISLNK(state.st_mode)) {
    close(rootDescriptor); LDSetError(error, DSHLocalWorkspaceAccessErrorIO); return nil;
  } else {
    close(rootDescriptor); LDSetError(error, DSHLocalWorkspaceAccessErrorConflict); return nil;
  }
  close(rootDescriptor);
  NSURL *support = [[NSFileManager defaultManager] URLForDirectory:NSApplicationSupportDirectory
                                                            inDomain:NSUserDomainMask
                                                   appropriateForURL:nil
                                                              create:YES
                                                               error:error];
  if (support == nil) return nil;
  return [[support URLByAppendingPathComponent:@"document-staging" isDirectory:YES]
      URLByAppendingPathComponent:name isDirectory:YES];
}

- (NSURL *)existingStagingDirectory:(NSString *)prefix
                           operationId:(NSString *)operationId
                                error:(NSError **)error {
  if (!LDUUID(operationId) || (![prefix isEqual:@"import"] && ![prefix isEqual:@"export"])) {
    LDSetError(error, DSHLocalWorkspaceAccessErrorInvalid); return nil;
  }
  int rootDescriptor = [self openStagingRootCreating:NO error:error];
  if (rootDescriptor < 0) {
    if (rootDescriptor == -2) LDSetError(error, DSHLocalWorkspaceAccessErrorConflict);
    return nil;
  }
  NSString *name = [NSString stringWithFormat:@"%@-%@", prefix, operationId];
  int descriptor = openat(rootDescriptor, name.fileSystemRepresentation,
                          O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  close(rootDescriptor);
  if (descriptor < 0) { LDSetError(error, DSHLocalWorkspaceAccessErrorConflict); return nil; }
  close(descriptor);
  NSURL *support = [[NSFileManager defaultManager] URLForDirectory:NSApplicationSupportDirectory
                                                            inDomain:NSUserDomainMask
                                                   appropriateForURL:nil
                                                              create:YES
                                                               error:error];
  if (support == nil) return nil;
  return [[support URLByAppendingPathComponent:@"document-staging" isDirectory:YES]
      URLByAppendingPathComponent:name isDirectory:YES];
}

- (NSURL *)newStagingDirectory:(NSString *)prefix error:(NSError **)error {
  return [self newStagingDirectory:prefix operationId:NSUUID.UUID.UUIDString.lowercaseString error:error];
}

- (BOOL)saveStagingJournal:(NSDictionary *)journal error:(NSError **)error {
  if (!LDJournalValid(journal)) { LDSetError(error, DSHLocalWorkspaceAccessErrorPersistence); return NO; }
  NSData *data = [NSJSONSerialization dataWithJSONObject:journal options:NSJSONWritingSortedKeys error:nil];
  if (data == nil || data.length > LDMaxJournalBytes) { LDSetError(error, DSHLocalWorkspaceAccessErrorPersistence); return NO; }
  int rootDescriptor = [self openStagingRootCreating:YES error:error];
  if (rootDescriptor < 0) return NO;
  BOOL ok = LDAtomicWriteNamed(rootDescriptor, LDJournalFileName, data, error);
  close(rootDescriptor);
  return ok;
}

- (NSDictionary *)loadStagingJournal:(NSError **)error {
  int rootDescriptor = [self openStagingRootCreating:NO error:error];
  if (rootDescriptor == -2) return nil;
  if (rootDescriptor < 0) return nil;
  int descriptor = openat(rootDescriptor, LDJournalFileName.UTF8String,
                          O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (descriptor < 0) {
    BOOL absent = errno == ENOENT;
    close(rootDescriptor);
    if (!absent) LDSetError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return nil;
  }
  struct stat state = {};
  NSData *data = fstat(descriptor, &state) == 0 && S_ISREG(state.st_mode) && state.st_nlink == 1
      ? LDReadDescriptor(descriptor, LDMaxJournalBytes, error) : nil;
  close(descriptor); close(rootDescriptor);
  NSDictionary *journal = data == nil ? nil : [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (!LDJournalValid(journal)) {
    LDSetError(error, DSHLocalWorkspaceAccessErrorPersistence); return nil;
  }
  return journal;
}

- (NSArray<NSDictionary *> *)loadCommittedReceipts:(NSError **)error {
  int rootDescriptor = [self openStagingRootCreating:NO error:error];
  if (rootDescriptor == -2) return @[];
  if (rootDescriptor < 0) return nil;
  int descriptor = openat(rootDescriptor, LDReceiptStoreFileName.fileSystemRepresentation,
                          O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (descriptor < 0) {
    BOOL absent = errno == ENOENT;
    close(rootDescriptor);
    if (!absent) LDSetError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return absent ? @[] : nil;
  }
  struct stat state = {};
  NSData *data = fstat(descriptor, &state) == 0 && S_ISREG(state.st_mode) && state.st_nlink == 1
      ? LDReadDescriptor(descriptor, LDMaxJournalBytes, error) : nil;
  close(descriptor); close(rootDescriptor);
  NSDictionary *store = data == nil ? nil : [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (!LDReceiptStoreValid(store)) {
    LDSetError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return nil;
  }
  return store[@"receipts"];
}

- (BOOL)saveCommittedReceipts:(NSArray<NSDictionary *> *)receipts error:(NSError **)error {
  NSDictionary *store = @{ @"schema_version": @1, @"receipts": receipts ?: @[] };
  if (!LDReceiptStoreValid(store)) {
    LDSetError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return NO;
  }
  NSData *data = LDReceiptStoreData(receipts);
  if (data == nil || data.length > LDMaxJournalBytes) {
    LDSetError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return NO;
  }
  int rootDescriptor = [self openStagingRootCreating:YES error:error];
  if (rootDescriptor < 0) return NO;
  BOOL ok = LDAtomicWriteNamed(rootDescriptor, LDReceiptStoreFileName, data, error);
  close(rootDescriptor);
  return ok;
}

- (BOOL)archiveCommittedJournal:(NSDictionary *)journal error:(NSError **)error {
  if (!LDJournalValid(journal) || ![journal[@"phase"] isEqual:@"committed"]) {
    LDSetError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return NO;
  }
  NSArray<NSDictionary *> *receipts = [self loadCommittedReceipts:error];
  if (receipts == nil) return NO;
  NSMutableArray<NSDictionary *> *updated = [NSMutableArray arrayWithCapacity:receipts.count + 1];
  for (NSDictionary *receipt in receipts) {
    if (![receipt[@"operation_id"] isEqual:journal[@"operation_id"]]) {
      [updated addObject:receipt];
      continue;
    }
    NSDictionary *root = @{
      @"schema_version" : @1,
      @"workspace_id" : journal[@"workspace_id"],
      @"binding_revision" : journal[@"binding_revision"],
      @"project_id" : journal[@"project_id"],
    };
    if (!LDStoredRootMatches(receipt, root)) {
      LDSetError(error, DSHLocalWorkspaceAccessErrorConflict);
      return NO;
    }
  }
  [updated addObject:journal];
  while (updated.count > LDMaxCommittedReceipts ||
         (LDReceiptStoreData(updated) != nil &&
          LDReceiptStoreData(updated).length > LDMaxJournalBytes)) {
    if (updated.count > 1) {
      /* The newly committed receipt is always appended last. */
      [updated removeObjectAtIndex:0];
      continue;
    }
    NSDictionary *compact = LDCompactReceiptFromJournal(journal);
    if (!LDCompactReceiptValid(compact)) {
      LDSetError(error, DSHLocalWorkspaceAccessErrorPersistence);
      return NO;
    }
    updated[0] = compact;
    break;
  }
  NSData *boundedData = LDReceiptStoreData(updated);
  if (boundedData == nil || boundedData.length > LDMaxJournalBytes) {
    LDSetError(error, DSHLocalWorkspaceAccessErrorPersistence);
    return NO;
  }
  if (![self saveCommittedReceipts:updated error:error]) return NO;
  return [self removeStagingJournal:error];
}

- (NSDictionary *)committedReceiptForOperationId:(NSString *)operationId
                                              root:(NSDictionary *)root
                                             error:(NSError **)error {
  if (!LDUUID(operationId) || root == nil) {
    LDSetError(error, DSHLocalWorkspaceAccessErrorInvalid);
    return nil;
  }
  for (NSDictionary *receipt in [self loadCommittedReceipts:error]) {
    if (![receipt[@"operation_id"] isEqual:operationId]) continue;
    if (!LDStoredRootMatches(receipt, root)) {
      LDSetError(error, DSHLocalWorkspaceAccessErrorConflict);
      return nil;
    }
    return receipt;
  }
  return nil;
}

- (BOOL)validateCommittedReceipt:(NSDictionary *)receipt
                            kind:(NSString *)kind
                            root:(NSDictionary *)root
                  destinationPath:(NSString *)destinationPath
                       sourcePaths:(NSArray<NSString *> *)sourcePaths {
  NSString *requestDigest = receipt == nil ? nil :
      LDDocumentRequestSHA256(kind, root, receipt[@"operation_id"],
                              destinationPath, sourcePaths);
  if (!LDDigest(requestDigest) || ![receipt[@"request_sha256"] isEqual:requestDigest]) return NO;
  if (receipt != nil && [receipt[@"receipt_kind"] isEqual:@"compact_terminal"]) {
    return LDCompactReceiptValid(receipt) && [receipt[@"kind"] isEqual:kind] &&
        [receipt[@"workspace_id"] isEqual:root[@"workspace_id"]] &&
        [receipt[@"binding_revision"] isEqual:root[@"binding_revision"]] &&
        [receipt[@"project_id"] isEqual:root[@"project_id"]] &&
        [receipt[@"destination_path"] isEqual:destinationPath];
  }
  return receipt != nil && LDJournalValid(receipt) && [receipt[@"kind"] isEqual:kind] &&
      [receipt[@"workspace_id"] isEqual:root[@"workspace_id"]] &&
      [receipt[@"binding_revision"] isEqual:root[@"binding_revision"]] &&
      [receipt[@"project_id"] isEqual:root[@"project_id"]] &&
      [receipt[@"destination_path"] isEqual:destinationPath] &&
      [receipt[@"source_paths"] isEqual:sourcePaths];
}

- (NSDictionary *)committedImportResultForJournal:(NSDictionary *)journal
                                               root:(NSDictionary *)root {
  if (LDCompactReceiptValid(journal) && [journal[@"kind"] isEqual:@"import"]) {
    return @{
      @"schema_version": @1,
      @"status": @"imported",
      @"root": root,
      @"operation_id": journal[@"operation_id"],
      @"destination_path": journal[@"destination_path"],
      @"entries": @[],
    };
  }
  NSArray<NSString *> *entryNames = journal[@"entry_names"];
  NSArray<NSDictionary *> *entryStates = journal[@"entry_states"];
  NSString *destinationPath = journal[@"destination_path"];
  if (![journal[@"kind"] isEqual:@"import"] ||
      ![journal[@"phase"] isEqual:@"committed"] ||
      entryNames.count != entryStates.count) return nil;
  NSMutableArray<NSDictionary *> *entries = [NSMutableArray arrayWithCapacity:entryNames.count];
  for (NSDictionary *state in entryStates) {
    NSString *name = state[@"name"];
    unsigned long long mode = strtoull([state[@"mode"] UTF8String], nullptr, 10);
    unsigned long long size = strtoull([state[@"size"] UTF8String], nullptr, 10);
    if ((mode & S_IFMT) != S_IFDIR && (mode & S_IFMT) != S_IFREG) return nil;
    NSString *relative = destinationPath.length == 0
        ? name : [destinationPath stringByAppendingFormat:@"/%@", name];
    [entries addObject:@{
      @"path": relative,
      @"kind": (mode & S_IFMT) == S_IFDIR ? @"directory" : @"file",
      @"size": @(size),
    }];
  }
  return @{
    @"schema_version": @1,
    @"status": @"imported",
    @"root": root,
    @"operation_id": journal[@"operation_id"],
    @"destination_path": journal[@"destination_path"],
    @"entries": entries,
  };
}

- (BOOL)removeCommittedReceiptForOperationId:(NSString *)operationId
                                         root:(NSDictionary *)root
                                        error:(NSError **)error {
  if (!LDUUID(operationId) || root == nil) {
    LDSetError(error, DSHLocalWorkspaceAccessErrorInvalid);
    return NO;
  }
  NSArray<NSDictionary *> *receipts = [self loadCommittedReceipts:error];
  if (receipts == nil) return NO;
  NSMutableArray<NSDictionary *> *updated = [NSMutableArray arrayWithCapacity:receipts.count];
  BOOL found = NO;
  for (NSDictionary *receipt in receipts) {
    if (![receipt[@"operation_id"] isEqual:operationId]) {
      [updated addObject:receipt];
      continue;
    }
    if (!LDStoredRootMatches(receipt, root)) {
      LDSetError(error, DSHLocalWorkspaceAccessErrorConflict);
      return NO;
    }
    found = YES;
  }
  return !found || [self saveCommittedReceipts:updated error:error];
}

- (BOOL)removeStagingJournal:(NSError **)error {
  int rootDescriptor = [self openStagingRootCreating:NO error:error];
  if (rootDescriptor == -2) return YES;
  if (rootDescriptor < 0) return NO;
  BOOL ok = unlinkat(rootDescriptor, LDJournalFileName.UTF8String, 0) == 0 || errno == ENOENT;
  if (ok) ok = fsync(rootDescriptor) == 0;
  if (!ok) LDSetError(error, DSHLocalWorkspaceAccessErrorIO);
  close(rootDescriptor);
  return ok;
}

- (BOOL)removeStagingDirectoryNamed:(NSString *)stagingName error:(NSError **)error {
  if (!LDValidStagingName(stagingName)) { LDSetError(error, DSHLocalWorkspaceAccessErrorInvalid); return NO; }
  int rootDescriptor = [self openStagingRootCreating:NO error:error];
  if (rootDescriptor == -2) return YES;
  if (rootDescriptor < 0) return NO;
  int descriptor = openat(rootDescriptor, stagingName.fileSystemRepresentation,
                          O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (descriptor < 0) {
    BOOL absent = errno == ENOENT;
    close(rootDescriptor);
    if (!absent) LDSetError(error, DSHLocalWorkspaceAccessErrorIO);
    return absent;
  }
  BOOL ok = LDRemoveTree(descriptor, error);
  close(descriptor);
  if (ok) ok = unlinkat(rootDescriptor, stagingName.fileSystemRepresentation, AT_REMOVEDIR) == 0 && fsync(rootDescriptor) == 0;
  if (!ok) LDSetError(error, DSHLocalWorkspaceAccessErrorIO);
  close(rootDescriptor);
  return ok;
}

- (BOOL)reconcileJournal:(NSDictionary *)journal error:(NSError **)error {
  if (!LDJournalValid(journal)) {
    LDSetError(error, DSHLocalWorkspaceAccessErrorPersistence); return NO;
  }
  NSDictionary *root = @{
    @"schema_version": @1,
    @"workspace_id": journal[@"workspace_id"],
    @"binding_revision": journal[@"binding_revision"],
    @"project_id": journal[@"project_id"],
  };
  NSString *destinationPath = journal[@"destination_path"];
  NSArray<NSString *> *destinationComponents = LDComponents(destinationPath, YES, error);
  if (destinationComponents == nil) return NO;
  NSString *stagingName = journal[@"staging_name"];
  NSArray<NSString *> *entryNames = journal[@"entry_names"];
  NSMutableDictionary<NSString *, NSDictionary *> *expectedStates = [NSMutableDictionary dictionary];
  for (NSDictionary *state in journal[@"entry_states"]) expectedStates[state[@"name"]] = state;
  BOOL isImport = [journal[@"kind"] isEqual:@"import"];
  __block NSString *phase = nil;
  NSError *operationError = nil;
  BOOL rootOK = [self performRoot:root capabilities:[NSSet setWithObject:@"read"] block:^BOOL(int rootDescriptor, NSError **blockError) {
    int destination = isImport ? [self openDirectory:destinationComponents root:rootDescriptor error:blockError] : -1;
    int stagingRoot = [self openStagingRootCreating:NO error:blockError];
    int staging = stagingRoot < 0 ? -1 : openat(stagingRoot, stagingName.fileSystemRepresentation,
                                                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if ((isImport && destination < 0) || stagingRoot == -1 || (stagingRoot >= 0 && staging < 0 && errno != ENOENT)) {
      if (destination >= 0) close(destination);
      if (staging >= 0) close(staging);
      if (stagingRoot >= 0) close(stagingRoot);
      if (blockError != nil && *blockError == nil) LDSetError(blockError, DSHLocalWorkspaceAccessErrorConflict);
      return NO;
    }
    BOOL allPublished = entryNames.count > 0;
    BOOL allStaged = entryNames.count > 0;
    BOOL ambiguous = NO;
    for (NSString *name in entryNames) {
      struct stat sourceState = {}, destinationState = {};
      BOOL sourceExists = staging >= 0 && fstatat(staging, name.fileSystemRepresentation,
                                                  &sourceState, AT_SYMLINK_NOFOLLOW) == 0;
      int sourceErrno = staging >= 0 ? errno : ENOENT;
      BOOL destinationExists = isImport &&
          fstatat(destination, name.fileSystemRepresentation, &destinationState,
                  AT_SYMLINK_NOFOLLOW) == 0;
      int destinationErrno = isImport ? errno : ENOENT;
      if ((!sourceExists && sourceErrno != ENOENT) || (!destinationExists && destinationErrno != ENOENT) ||
          (sourceExists && S_ISLNK(sourceState.st_mode)) ||
          (destinationExists && S_ISLNK(destinationState.st_mode)) ||
          (sourceExists && !S_ISREG(sourceState.st_mode) && !S_ISDIR(sourceState.st_mode)) ||
          (destinationExists && !S_ISREG(destinationState.st_mode) && !S_ISDIR(destinationState.st_mode)) ||
          (sourceExists && S_ISREG(sourceState.st_mode) && sourceState.st_nlink != 1) ||
          (destinationExists && S_ISREG(destinationState.st_mode) && destinationState.st_nlink != 1)) {
        ambiguous = YES; break;
      }
      NSDictionary *expected = expectedStates[name];
      if ((sourceExists || destinationExists) && expected == nil) {
        ambiguous = YES; break;
      }
      if ((sourceExists && !LDFileStateRecordMatches(expected, name, sourceState)) ||
          (destinationExists && !LDFileStateRecordMatches(expected, name, destinationState))) {
        ambiguous = YES; break;
      }
      if (!sourceExists && !destinationExists) {
        ambiguous = YES;
        break;
      }
      if (sourceExists && destinationExists) ambiguous = YES;
      allPublished = allPublished && destinationExists && !sourceExists;
      allStaged = allStaged && sourceExists && !destinationExists;
    }
    if (entryNames.count == 0) phase = @"prepared";
    else if (ambiguous) phase = @"needs_recovery";
    else if (isImport && allPublished) phase = @"committed";
    else if (allStaged || isImport) phase = @"staged";
    else phase = @"needs_recovery";
    if (destination >= 0) close(destination);
    if (staging >= 0) close(staging);
    if (stagingRoot >= 0) close(stagingRoot);
    return YES;
  } error:&operationError];
  if (!rootOK) {
    if (error != nil) *error = operationError;
    return NO;
  }
  NSMutableDictionary *updated = [journal mutableCopy];
  updated[@"phase"] = phase ?: @"needs_recovery";
  updated[@"updated_at"] = LDNow();
  if (![self saveStagingJournal:updated error:error]) return NO;
  if ([phase isEqual:@"committed"]) {
    NSError *removeError = nil;
    if (![self removeStagingDirectoryNamed:stagingName error:&removeError]) {
      if (error != nil) *error = removeError;
      return NO;
    }
    if (![self archiveCommittedJournal:updated error:&removeError]) {
      if (error != nil) *error = removeError;
      return NO;
    }
  }
  return YES;
}

- (BOOL)canCleanupUnpublishedJournal:(NSDictionary *)journal error:(NSError **)error {
  if (!LDJournalValid(journal) || ![journal[@"kind"] isEqual:@"import"]) {
    LDSetError(error, DSHLocalWorkspaceAccessErrorConflict);
    return NO;
  }
  NSDictionary *root = @{
    @"schema_version": @1,
    @"workspace_id": journal[@"workspace_id"],
    @"binding_revision": journal[@"binding_revision"],
    @"project_id": journal[@"project_id"],
  };
  NSArray *components = LDComponents(journal[@"destination_path"], YES, error);
  if (components == nil) return NO;
  __block BOOL absent = YES;
  NSError *operationError = nil;
  BOOL rootOK = [self performRoot:root capabilities:[NSSet setWithObject:@"read"] block:^BOOL(int rootDescriptor, NSError **blockError) {
    int destination = [self openDirectory:components root:rootDescriptor error:blockError];
    if (destination < 0) return NO;
    for (NSString *name in journal[@"entry_names"]) {
      struct stat state = {};
      if (fstatat(destination, name.fileSystemRepresentation, &state, AT_SYMLINK_NOFOLLOW) == 0) {
        absent = NO;
        break;
      }
      if (errno != ENOENT) {
        absent = NO;
        LDSetError(blockError, DSHLocalWorkspaceAccessErrorIO);
        break;
      }
    }
    close(destination);
    return blockError == nil || *blockError == nil;
  } error:&operationError];
  if (!rootOK) {
    if (error != nil) *error = operationError ?: LDError(DSHLocalWorkspaceAccessErrorConflict);
    return NO;
  }
  if (!absent) LDSetError(error, DSHLocalWorkspaceAccessErrorConflict);
  return absent;
}

- (BOOL)recoverStagingJournal:(NSError **)error {
  NSError *loadError = nil;
  NSDictionary *journal = [self loadStagingJournal:&loadError];
  if (journal == nil) {
    if (loadError != nil && error != nil) *error = loadError;
    return loadError == nil;
  }
  NSString *phase = journal[@"phase"];
  if ([phase isEqual:@"publishing"] ||
      ([phase isEqual:@"needs_recovery"] && [journal[@"kind"] isEqual:@"import"])) {
    return [self reconcileJournal:journal error:error];
  }
  if ([phase isEqual:@"committed"]) {
    if (![self removeStagingDirectoryNamed:journal[@"staging_name"] error:error]) return NO;
    return [self archiveCommittedJournal:journal error:error];
  }
  return YES;
}

- (BOOL)publishJournal:(NSDictionary *)journal
                  root:(NSDictionary *)root
               entries:(NSArray<NSDictionary *> **)entries
                 error:(NSError **)error {
  if (!LDJournalValid(journal) || ![journal[@"kind"] isEqual:@"import"] ||
      ![root[@"workspace_id"] isEqual:journal[@"workspace_id"]] ||
      ![root[@"binding_revision"] isEqual:journal[@"binding_revision"]] ||
      ![root[@"project_id"] isEqual:journal[@"project_id"]]) {
    LDSetError(error, DSHLocalWorkspaceAccessErrorConflict); return NO;
  }
  NSString *destinationPath = journal[@"destination_path"];
  NSArray<NSString *> *destinationComponents = LDComponents(destinationPath, YES, error);
  NSArray<NSString *> *entryNames = journal[@"entry_names"];
  NSMutableDictionary<NSString *, NSDictionary *> *expectedStates = [NSMutableDictionary dictionary];
  for (NSDictionary *state in journal[@"entry_states"]) expectedStates[state[@"name"]] = state;
  if (destinationComponents == nil || entryNames.count == 0 ||
      expectedStates.count != entryNames.count || [journal[@"phase"] isEqual:@"prepared"]) {
    LDSetError(error, DSHLocalWorkspaceAccessErrorConflict); return NO;
  }
  __block NSArray<NSDictionary *> *publishedEntries = nil;
  __block BOOL journalWasCommitted = NO;
  __block NSDictionary *committedJournal = nil;
  NSError *operationError = nil;
  BOOL rootOK = [self performRoot:root capabilities:[NSSet setWithObject:@"write"] block:^BOOL(int rootDescriptor, NSError **blockError) {
    int destination = [self openDirectory:destinationComponents root:rootDescriptor error:blockError];
    int stagingRoot = [self openStagingRootCreating:NO error:blockError];
    int staging = stagingRoot < 0 ? -1 : openat(stagingRoot, [journal[@"staging_name"] fileSystemRepresentation], O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (destination < 0 || stagingRoot < 0 || staging < 0) {
      if (destination >= 0) close(destination);
      if (staging >= 0) close(staging);
      if (stagingRoot >= 0) close(stagingRoot);
      if (*blockError == nil) LDSetError(blockError, DSHLocalWorkspaceAccessErrorConflict);
      return NO;
    }
    NSMutableDictionary *publishing = [journal mutableCopy];
    publishing[@"phase"] = @"publishing";
    publishing[@"updated_at"] = LDNow();
    if (![self saveStagingJournal:publishing error:blockError]) {
      close(destination); close(staging); close(stagingRoot); return NO;
    }
    NSMutableArray<NSString *> *published = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSValue *> *publishedStates = [NSMutableDictionary dictionary];
    NSMutableArray<NSDictionary *> *metadata = [NSMutableArray array];
    for (NSString *name in entryNames) {
      struct stat sourceState = {}, destinationState = {};
      BOOL sourceExists = fstatat(staging, name.fileSystemRepresentation, &sourceState,
                                  AT_SYMLINK_NOFOLLOW) == 0;
      int sourceErrno = errno;
      BOOL destinationExists = fstatat(destination, name.fileSystemRepresentation,
                                       &destinationState, AT_SYMLINK_NOFOLLOW) == 0;
      int destinationErrno = errno;
      NSDictionary *expected = expectedStates[name];
      if ((!sourceExists && sourceErrno != ENOENT) ||
          (!destinationExists && destinationErrno != ENOENT) || expected == nil) {
        LDSetError(blockError, DSHLocalWorkspaceAccessErrorConflict); break;
      }
      NSString *relative = destinationPath.length == 0 ? name : [destinationPath stringByAppendingFormat:@"/%@", name];
      if (!sourceExists && destinationExists) {
        if (S_ISLNK(destinationState.st_mode) ||
            (!S_ISREG(destinationState.st_mode) && !S_ISDIR(destinationState.st_mode)) ||
            (S_ISREG(destinationState.st_mode) && destinationState.st_nlink != 1) ||
            !LDFileStateRecordMatches(expected, name, destinationState)) {
          LDSetError(blockError, DSHLocalWorkspaceAccessErrorConflict); break;
        }
        [published addObject:name];
        [publishedStates setObject:[NSValue valueWithBytes:&destinationState objCType:@encode(struct stat)]
                            forKey:name];
        [metadata addObject:@{ @"path": relative, @"kind": S_ISDIR(destinationState.st_mode) ? @"directory" : @"file", @"size": S_ISREG(destinationState.st_mode) ? @(destinationState.st_size) : @0 }];
        continue;
      }
      if (!sourceExists || destinationExists || S_ISLNK(sourceState.st_mode) ||
          (!S_ISREG(sourceState.st_mode) && !S_ISDIR(sourceState.st_mode)) ||
          (S_ISREG(sourceState.st_mode) && sourceState.st_nlink != 1) ||
          !LDFileStateRecordMatches(expected, name, sourceState)) {
        LDSetError(blockError, DSHLocalWorkspaceAccessErrorConflict); break;
      }
      int sourceFlags = S_ISDIR(sourceState.st_mode) ? (O_RDONLY | O_DIRECTORY) : O_RDONLY;
      int sourceDescriptor = openat(staging, name.fileSystemRepresentation,
                                    sourceFlags | O_CLOEXEC | O_NOFOLLOW);
      struct stat sourceOpened = {};
      BOOL sourceHeld = sourceDescriptor >= 0 && fstat(sourceDescriptor, &sourceOpened) == 0 &&
          LDSameFileState(sourceState, sourceOpened) &&
          (!S_ISREG(sourceOpened.st_mode) || sourceOpened.st_nlink == 1);
      if (!sourceHeld || renameatx_np(staging, name.fileSystemRepresentation,
                                      destination, name.fileSystemRepresentation, RENAME_EXCL) != 0) {
        if (sourceDescriptor >= 0) close(sourceDescriptor);
        LDSetError(blockError, sourceHeld ? DSHLocalWorkspaceAccessErrorIO : DSHLocalWorkspaceAccessErrorConflict); break;
      }
      [published addObject:name];
      [publishedStates setObject:[NSValue valueWithBytes:&sourceState objCType:@encode(struct stat)]
                          forKey:name];
      struct stat installed = {}, sourceAfter = {};
      BOOL sourceGone = fstatat(staging, name.fileSystemRepresentation, &sourceAfter,
                                AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT;
      if (fstatat(destination, name.fileSystemRepresentation, &installed, AT_SYMLINK_NOFOLLOW) != 0 ||
          S_ISLNK(installed.st_mode) || (!S_ISREG(installed.st_mode) && !S_ISDIR(installed.st_mode)) ||
          (S_ISREG(installed.st_mode) && installed.st_nlink != 1) ||
          !LDSameFileState(sourceState, installed) || !sourceGone ||
          fstat(sourceDescriptor, &sourceAfter) != 0 || !LDSameFileState(sourceState, sourceAfter) ||
          (S_ISREG(sourceAfter.st_mode) && sourceAfter.st_nlink != 1)) {
        close(sourceDescriptor);
        LDSetError(blockError, DSHLocalWorkspaceAccessErrorIO); break;
      }
      close(sourceDescriptor);
      [metadata addObject:@{ @"path": relative, @"kind": S_ISDIR(installed.st_mode) ? @"directory" : @"file", @"size": S_ISREG(installed.st_mode) ? @(installed.st_size) : @0 }];
    }
    if (*blockError != nil) {
      BOOL rolledBack = YES;
      for (NSString *name in published.reverseObjectEnumerator) {
        struct stat expected = {};
        NSValue *boxed = publishedStates[name];
        if (boxed == nil) { rolledBack = NO; continue; }
        [boxed getValue:&expected];
        if (!LDRestoreMoveToObservedSource(staging, name, destination, name) ||
            !LDStatAtMatches(staging, name, expected, nullptr)) rolledBack = NO;
      }
      if (fsync(destination) != 0 || fsync(staging) != 0) rolledBack = NO;
      if (!rolledBack) LDSetError(blockError, DSHLocalWorkspaceAccessErrorConflict);
      NSMutableDictionary *needs = [publishing mutableCopy];
      needs[@"phase"] = @"needs_recovery";
      needs[@"updated_at"] = LDNow();
      [self saveStagingJournal:needs error:nil];
      close(destination); close(staging); close(stagingRoot); return NO;
    }
    if (fsync(destination) != 0 || fsync(staging) != 0) {
      BOOL rolledBack = YES;
      for (NSString *name in published.reverseObjectEnumerator) {
        struct stat expected = {};
        NSValue *boxed = publishedStates[name];
        if (boxed == nil) { rolledBack = NO; continue; }
        [boxed getValue:&expected];
        if (!LDRestoreMoveToObservedSource(staging, name, destination, name) ||
            !LDStatAtMatches(staging, name, expected, nullptr)) rolledBack = NO;
      }
      NSMutableDictionary *needs = [publishing mutableCopy];
      needs[@"phase"] = @"needs_recovery";
      needs[@"updated_at"] = LDNow();
      [self saveStagingJournal:needs error:nil];
      close(destination); close(staging); close(stagingRoot);
      if (!rolledBack) LDSetError(blockError, DSHLocalWorkspaceAccessErrorConflict);
      else LDSetError(blockError, DSHLocalWorkspaceAccessErrorIO);
      return NO;
    }
    NSMutableDictionary *committed = [publishing mutableCopy];
    committed[@"phase"] = @"committed";
    committed[@"updated_at"] = LDNow();
    if (![self saveStagingJournal:committed error:blockError]) {
      close(destination); close(staging); close(stagingRoot); return NO;
    }
    close(destination); close(staging); close(stagingRoot);
    publishedEntries = metadata;
    committedJournal = [committed copy];
    journalWasCommitted = YES;
    return YES;
  } error:&operationError];
  if (!rootOK) {
    if (error != nil) *error = operationError ?: LDError(DSHLocalWorkspaceAccessErrorIO);
    return NO;
  }
  if (!journalWasCommitted) {
    LDSetError(error, DSHLocalWorkspaceAccessErrorConflict); return NO;
  }
  NSError *removeError = nil;
  if (![self removeStagingDirectoryNamed:journal[@"staging_name"] error:&removeError]) {
    if (error != nil) *error = removeError;
    return NO;
  }
  if (![self archiveCommittedJournal:committedJournal error:&removeError]) {
    if (error != nil) *error = removeError;
    return NO;
  }
  if (entries != nil) *entries = publishedEntries;
  return YES;
}
- (BOOL)copyOpenedItem:(int)sourceDescriptor
                 state:(struct stat)state
                    to:(NSURL *)destination
                 depth:(NSUInteger)depth
                 count:(NSUInteger *)count
            totalBytes:(uint64_t *)totalBytes
                 error:(NSError **)error {
  if (depth > LDMaxDepth || *count >= LDMaxEntries) {
    LDSetError(error, DSHLocalWorkspaceAccessErrorIO); return NO;
  }
  *count += 1;
  if (S_ISDIR(state.st_mode)) {
    if (mkdir(destination.fileSystemRepresentation, 0700) != 0) {
      LDSetError(error, DSHLocalWorkspaceAccessErrorIO); return NO;
    }
    int duplicate = openat(sourceDescriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    DIR *children = duplicate < 0 ? nullptr : fdopendir(duplicate);
    if (children == nullptr) {
      if (duplicate >= 0) close(duplicate);
      LDSetError(error, DSHLocalWorkspaceAccessErrorIO); return NO;
    }
    struct dirent *entry = nullptr; BOOL ok = YES;
    while (ok) {
      errno = 0; entry = readdir(children);
      if (entry == nullptr) { ok = errno == 0; break; }
      if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
      NSString *name = [NSString stringWithUTF8String:entry->d_name];
      if (name == nil || !LDValidComponent(name)) {
        LDSetError(error, DSHLocalWorkspaceAccessErrorInvalid); ok = NO; break;
      }
      struct stat childState = {};
      if (fstatat(dirfd(children), name.fileSystemRepresentation, &childState, AT_SYMLINK_NOFOLLOW) != 0 ||
          S_ISLNK(childState.st_mode) || (!S_ISDIR(childState.st_mode) && !S_ISREG(childState.st_mode))) {
        LDSetError(error, DSHLocalWorkspaceAccessErrorIO); ok = NO; break;
      }
      int childFlags = (S_ISDIR(childState.st_mode) ? (O_RDONLY | O_DIRECTORY) : O_RDONLY) |
          O_CLOEXEC | O_NOFOLLOW;
      int child = openat(dirfd(children), name.fileSystemRepresentation, childFlags);
      if (child < 0) { LDSetError(error, DSHLocalWorkspaceAccessErrorIO); ok = NO; break; }
      struct stat opened = {};
      BOOL identity = fstat(child, &opened) == 0 && LDSameFileState(childState, opened) &&
          (!S_ISREG(childState.st_mode) || childState.st_nlink == 1);
      NSURL *childDestination = [destination URLByAppendingPathComponent:name];
      if (!identity || ![self copyOpenedItem:child state:opened to:childDestination depth:depth + 1 count:count totalBytes:totalBytes error:error]) ok = NO;
      close(child);
    }
    closedir(children);
    struct stat finalState = {};
    if (ok && (fstat(sourceDescriptor, &finalState) != 0 || !LDSameFileState(state, finalState))) {
      LDSetError(error, DSHLocalWorkspaceAccessErrorConflict);
      ok = NO;
    }
    int stagedDirectory = ok ? open(destination.fileSystemRepresentation,
                                     O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) : -1;
    if (ok && (stagedDirectory < 0 || fsync(stagedDirectory) != 0)) {
      /* The staging directory is private; a failed fsync still fails closed. */
      LDSetError(error, DSHLocalWorkspaceAccessErrorIO); ok = NO;
    }
    if (stagedDirectory >= 0) close(stagedDirectory);
    return ok;
  }
  if (state.st_nlink != 1 || state.st_size < 0) {
    LDSetError(error, DSHLocalWorkspaceAccessErrorConflict); return NO;
  }
  uint64_t bytes = (uint64_t)state.st_size;
  if (bytes > LDMaxFileBytes || bytes > LDMaxTotalBytes - *totalBytes) {
    LDSetError(error, DSHLocalWorkspaceAccessErrorIO); return NO;
  }
  int input = dup(sourceDescriptor);
  int output = input < 0 ? -1 : open(destination.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (input < 0 || output < 0) {
    if (input >= 0) close(input); if (output >= 0) close(output);
    LDSetError(error, DSHLocalWorkspaceAccessErrorIO); return NO;
  }
  uint8_t buffer[64 * 1024]; ssize_t readBytes = 0; uint64_t copied = 0; BOOL ok = YES;
  while ((readBytes = read(input, buffer, sizeof(buffer))) != 0) {
    if (readBytes < 0) { if (errno == EINTR) continue; ok = NO; break; }
    ssize_t offset = 0;
    while (offset < readBytes) {
      ssize_t written = write(output, buffer + offset, (size_t)(readBytes - offset));
      if (written < 0 && errno == EINTR) continue;
      if (written <= 0) { ok = NO; break; }
      offset += written; copied += (uint64_t)written;
    }
    if (!ok) break;
  }
  struct stat after = {};
  ok = ok && copied == bytes && fsync(output) == 0 && fstat(input, &after) == 0 && LDSameFileState(state, after);
  close(input); close(output);
  if (!ok) { unlink(destination.fileSystemRepresentation); LDSetError(error, DSHLocalWorkspaceAccessErrorIO); return NO; }
  *totalBytes += bytes;
  return YES;
}

- (BOOL)copyExternalDescriptor:(int)sourceDescriptor
                             to:(NSURL *)destination
                          depth:(NSUInteger)depth
                          count:(NSUInteger *)count
                     totalBytes:(uint64_t *)totalBytes
                          error:(NSError **)error {
  struct stat state = {};
  if (fstat(sourceDescriptor, &state) != 0 || S_ISLNK(state.st_mode) ||
      (!S_ISDIR(state.st_mode) && !S_ISREG(state.st_mode))) {
    LDSetError(error, DSHLocalWorkspaceAccessErrorIO); return NO;
  }
  return [self copyOpenedItem:sourceDescriptor state:state to:destination depth:depth count:count totalBytes:totalBytes error:error];
}

- (BOOL)copyDescriptorItem:(int)parent
                       name:(NSString *)name
                         to:(NSURL *)destination
                      depth:(NSUInteger)depth
                      count:(NSUInteger *)count
                      totalBytes:(uint64_t *)totalBytes
                      error:(NSError **)error {
  if (depth > LDMaxDepth || *count >= LDMaxEntries) { LDSetError(error, DSHLocalWorkspaceAccessErrorIO); return NO; }
  struct stat state = {};
  if (fstatat(parent, name.fileSystemRepresentation, &state, AT_SYMLINK_NOFOLLOW) != 0 || S_ISLNK(state.st_mode) || (!S_ISDIR(state.st_mode) && !S_ISREG(state.st_mode))) { LDSetError(error, DSHLocalWorkspaceAccessErrorIO); return NO; }
  if (!LDValidComponent(name)) { LDSetError(error, DSHLocalWorkspaceAccessErrorInvalid); return NO; }
  if (S_ISREG(state.st_mode) && state.st_nlink != 1) {
    LDSetError(error, DSHLocalWorkspaceAccessErrorConflict); return NO;
  }
  int descriptorFlags = (S_ISDIR(state.st_mode) ? (O_RDONLY | O_DIRECTORY) : O_RDONLY) |
      O_CLOEXEC | O_NOFOLLOW;
  int descriptor = openat(parent, name.fileSystemRepresentation, descriptorFlags);
  if (descriptor < 0) { LDSetError(error, DSHLocalWorkspaceAccessErrorIO); return NO; }
  struct stat opened = {};
  BOOL identity = fstat(descriptor, &opened) == 0 && LDSameFileState(state, opened);
  BOOL ok = identity && [self copyOpenedItem:descriptor state:opened to:destination depth:depth count:count totalBytes:totalBytes error:error];
  close(descriptor);
  return ok;
}

- (void)finishWithResult:(NSDictionary *)result
                   error:(NSError *)error
                 staging:(NSURL *)staging
             generation:(NSUInteger)generation {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (generation != self.pendingGeneration) {
      if (staging != nil) {
        NSString *stagingName = staging.lastPathComponent;
        dispatch_async(self.documentQueue, ^{
          [self removeStagingDirectoryNamed:stagingName error:nil];
        });
      }
      return;
    }
    RishResolveBlock resolve = self.pendingResolve;
    RishRejectBlock reject = self.pendingReject;
    self.pendingResolve = nil;
    self.pendingReject = nil;
    self.pendingRoot = nil;
    self.pendingDestinationPath = nil;
    self.pendingSourcePaths = nil;
    self.pendingOperationId = nil;
    self.pendingMode = LDPickerModeNone;
    self.pendingController = nil;
    NSURL *ownedStaging = staging;
    self.pendingExportStaging = nil;
    if (ownedStaging != nil) {
      NSString *stagingName = ownedStaging.lastPathComponent;
      dispatch_async(self.documentQueue, ^{
        [self removeStagingDirectoryNamed:stagingName error:nil];
      });
    }
    if (resolve == nil || reject == nil) return;
    if (error != nil) {
      NSString *code = LDStableCode(error);
      reject(code, LDMessage(code), nil);
    } else {
      resolve(result);
    }
  });
}

- (BOOL)beginPickerMode:(LDPickerMode)mode
                 resolve:(RishResolveBlock)resolve
                  reject:(RishRejectBlock)reject {
  NSAssert(NSThread.isMainThread, @"document picker state must stay on main");
  if (self.pendingMode != LDPickerModeNone) {
    reject(@"E_WORKSPACE_PICKER_BUSY", LDMessage(@"E_WORKSPACE_PICKER_BUSY"), nil);
    return NO;
  }
  UIViewController *presenter = RishPresentedViewController();
  if (presenter == nil || [presenter isKindOfClass:UIAlertController.class]) {
    reject(@"E_WORKSPACE_UNAVAILABLE", LDMessage(@"E_WORKSPACE_UNAVAILABLE"), nil);
    return NO;
  }
  self.pendingMode = mode;
  self.pendingCallbackSettled = NO;
  self.pendingGeneration = self.pendingGeneration == NSUIntegerMax ? 1 : self.pendingGeneration + 1;
  self.pendingController = nil;
  self.pendingResolve = resolve;
  self.pendingReject = reject;
  return YES;
}

- (void)finishCancellationForMode:(LDPickerMode)mode
                        generation:(NSUInteger)generation {
  NSDictionary *root = self.pendingRoot;
  NSString *operationId = self.pendingOperationId ?: @"";
  NSString *destinationPath = self.pendingDestinationPath ?: @"";
  NSURL *staging = self.pendingExportStaging;
  dispatch_async(self.documentQueue, ^{
    NSError *error = nil;
    BOOL valid = root != nil && [self performRoot:root capabilities:[NSSet setWithObject:@"read"] block:^BOOL(__unused int descriptor, __unused NSError **blockError) { return YES; } error:&error];
    NSDictionary *journal = [self loadStagingJournal:&error];
    if (error != nil) valid = NO;
    if (valid && journal != nil) {
      BOOL journalMatches = [journal[@"operation_id"] isEqual:operationId] &&
          [journal[@"workspace_id"] isEqual:root[@"workspace_id"]] &&
          [journal[@"binding_revision"] isEqual:root[@"binding_revision"]] &&
          [journal[@"project_id"] isEqual:root[@"project_id"]];
      valid = journalMatches &&
          [self removeStagingDirectoryNamed:journal[@"staging_name"] error:&error] &&
          [self removeStagingJournal:&error];
      if (!journalMatches && error == nil) {
        error = LDError(DSHLocalWorkspaceAccessErrorConflict);
      }
    }
    NSDictionary *result = nil;
    if (valid && mode == LDPickerModeImport) {
      result = @{ @"schema_version": @1, @"status": @"cancelled", @"root": root, @"operation_id": operationId, @"destination_path": destinationPath, @"entries": @[] };
    } else if (valid && mode == LDPickerModeExport) {
      result = @{ @"schema_version": @1, @"status": @"cancelled", @"root": root, @"operation_id": operationId, @"item_count": @0 };
    }
    [self finishWithResult:result error:valid ? nil : error staging:staging generation:generation];
  });
}

- (BOOL)claimPendingCallbackForController:(UIDocumentPickerViewController *)controller
                               generation:(NSUInteger)generation {
  NSAssert(NSThread.isMainThread, @"document picker callbacks must stay on main");
  if (self.pendingMode == LDPickerModeNone || self.pendingCallbackSettled ||
      generation != self.pendingGeneration || self.pendingController != controller) return NO;
  self.pendingCallbackSettled = YES;
  return YES;
}

RISH_NATIVE_METHOD(presentImportPicker,
                 presentImportPickerRequest:(id)requestValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSDictionary *request = [requestValue isKindOfClass:NSDictionary.class] ? requestValue : nil;
  if (!LDExact(request, @[@"schema_version", @"root", @"operation_id", @"destination_path"]) ||
      !LDSchemaOne(request[@"schema_version"]) || ![request[@"destination_path"] isKindOfClass:NSString.class]) {
    [self dispatchInvalid:reject]; return;
  }
  NSError *validationError = nil;
  NSDictionary *root = LDRootFromRequest(request, &validationError);
  NSString *operationId = request[@"operation_id"];
  NSString *destinationPath = request[@"destination_path"];
  NSArray<NSString *> *destinationComponents = LDComponents(destinationPath, YES, &validationError);
  NSString *requestDigest = root == nil || !LDUUID(operationId) || destinationComponents == nil
      ? nil : LDDocumentRequestSHA256(@"import", root, operationId, destinationPath, @[]);
  if (root == nil || !LDUUID(operationId) || destinationComponents == nil || !LDDigest(requestDigest)) { [self dispatchInvalid:reject]; return; }
  dispatch_async(self.documentQueue, ^{
    NSError *error = nil;
    if (![self recoverStagingJournal:&error]) { [self reject:reject error:error]; return; }
    NSDictionary *active = [self loadStagingJournal:&error];
    if (active != nil || error != nil) {
      [self reject:reject error:error ?: LDError(DSHLocalWorkspaceAccessErrorBusy)];
      return;
    }
    NSDictionary *committed = [self committedReceiptForOperationId:operationId
                                                               root:root
                                                              error:&error];
    if (error != nil) { [self reject:reject error:error]; return; }
    if (committed != nil) {
      if (![self validateCommittedReceipt:committed kind:@"import" root:root
                           destinationPath:destinationPath sourcePaths:@[]]) {
        [self reject:reject error:LDError(DSHLocalWorkspaceAccessErrorConflict)]; return;
      }
      __block BOOL rootValid = NO;
      rootValid = [self performRoot:root capabilities:[NSSet setWithObject:@"read"]
                               block:^BOOL(__unused int descriptor, __unused NSError **blockError) { return YES; }
                               error:&error];
      NSDictionary *result = rootValid ? [self committedImportResultForJournal:committed root:root] : nil;
      if (result == nil || error != nil) {
        [self reject:reject error:error ?: LDError(DSHLocalWorkspaceAccessErrorPersistence)]; return;
      }
      resolve(result);
      return;
    }
    BOOL valid = [self performRoot:root capabilities:[NSSet setWithObject:@"write"] block:^BOOL(int descriptor, NSError **blockError) {
      int destination = [self openDirectory:destinationComponents root:descriptor error:blockError];
      if (destination < 0) return NO;
      close(destination);
      return YES;
    } error:&error];
    if (!valid) { [self reject:reject error:error]; return; }
    NSString *stagingName = [NSString stringWithFormat:@"import-%@", operationId];
    NSDictionary *journal = @{
      @"schema_version": @1,
      @"operation_id": operationId,
      @"request_sha256": requestDigest,
      @"kind": @"import",
      @"phase": @"prepared",
      @"workspace_id": root[@"workspace_id"],
      @"binding_revision": root[@"binding_revision"],
      @"project_id": root[@"project_id"],
      @"destination_path": destinationPath,
      @"source_paths": @[],
      @"staging_name": stagingName,
      @"entry_names": @[],
      @"entry_states": @[],
      @"created_at": LDNow(),
      @"updated_at": LDNow(),
    };
    if (![self saveStagingJournal:journal error:&error]) {
      [self reject:reject error:error]; return;
    }
    NSURL *staging = [self newStagingDirectory:@"import" operationId:operationId error:&error];
    if (staging == nil) { [self reject:reject error:error]; return; }
    dispatch_async(dispatch_get_main_queue(), ^{
      if (![self beginPickerMode:LDPickerModeImport resolve:resolve reject:reject]) {
        dispatch_async(self.documentQueue, ^{
          [self removeStagingDirectoryNamed:staging.lastPathComponent error:nil];
          [self removeStagingJournal:nil];
        });
        return;
      }
      self.pendingRoot = root;
      self.pendingDestinationPath = destinationPath;
      self.pendingOperationId = operationId;
      self.pendingExportStaging = nil;
      (void)staging;
      UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
          initForOpeningContentTypes:@[UTTypeItem, UTTypeFolder] asCopy:YES];
      picker.allowsMultipleSelection = YES;
      picker.delegate = self;
      self.pendingController = picker;
      [RishPresentedViewController() presentViewController:picker animated:YES completion:nil];
    });
  });
}

RISH_NATIVE_METHOD(presentExportPicker,
                 presentExportPickerRequest:(id)requestValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSDictionary *request = [requestValue isKindOfClass:NSDictionary.class] ? requestValue : nil;
  NSArray *sourcePaths = [request[@"source_paths"] isKindOfClass:NSArray.class] ? request[@"source_paths"] : nil;
  if (!LDExact(request, @[@"schema_version", @"root", @"operation_id", @"source_paths"]) ||
      !LDSchemaOne(request[@"schema_version"]) || sourcePaths.count == 0 || sourcePaths.count > LDMaxExportItems) {
    [self dispatchInvalid:reject]; return;
  }
  NSError *validationError = nil;
  NSDictionary *root = LDRootFromRequest(request, &validationError);
  NSString *operationId = request[@"operation_id"];
  NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:sourcePaths.count];
  NSMutableSet<NSString *> *names = [NSMutableSet set];
  for (id pathValue in sourcePaths) {
    if (![pathValue isKindOfClass:NSString.class] || LDComponents(pathValue, NO, &validationError) == nil || [names containsObject:[pathValue lastPathComponent]]) {
      validationError = LDError(DSHLocalWorkspaceAccessErrorInvalid); break;
    }
    NSString *path = pathValue;
    [paths addObject:path]; [names addObject:path.lastPathComponent];
  }
  if (root == nil || !LDUUID(operationId) || validationError != nil || paths.count != sourcePaths.count) { [self dispatchInvalid:reject]; return; }
  NSString *requestDigest = LDDocumentRequestSHA256(@"export", root, operationId, @"", paths);
  if (!LDDigest(requestDigest)) { [self dispatchInvalid:reject]; return; }
  dispatch_async(self.documentQueue, ^{
    NSError *error = nil;
    if (![self recoverStagingJournal:&error]) { [self reject:reject error:error]; return; }
    NSDictionary *active = [self loadStagingJournal:&error];
    if (active != nil || error != nil) {
      [self reject:reject error:error ?: LDError(DSHLocalWorkspaceAccessErrorBusy)];
      return;
    }
    NSDictionary *committed = [self committedReceiptForOperationId:operationId
                                                               root:root
                                                              error:&error];
    if (error != nil) { [self reject:reject error:error]; return; }
    if (committed != nil) {
      if (![self validateCommittedReceipt:committed kind:@"export" root:root
                           destinationPath:@"" sourcePaths:paths]) {
        [self reject:reject error:LDError(DSHLocalWorkspaceAccessErrorConflict)]; return;
      }
      BOOL rootValid = [self performRoot:root capabilities:[NSSet setWithObject:@"read"]
                                   block:^BOOL(__unused int descriptor, __unused NSError **blockError) { return YES; }
                                   error:&error];
      if (!rootValid || error != nil) {
        [self reject:reject error:error ?: LDError(DSHLocalWorkspaceAccessErrorRootChanged)]; return;
      }
      NSUInteger committedCount = [committed[@"receipt_kind"] isEqual:@"compact_terminal"]
          ? [committed[@"entry_count"] unsignedIntegerValue] : paths.count;
      resolve(@{ @"schema_version": @1, @"status": @"exported", @"root": root,
                 @"operation_id": operationId, @"item_count": @(committedCount) });
      return;
    }
    NSString *stagingName = [NSString stringWithFormat:@"export-%@", operationId];
    NSDictionary *journal = @{
      @"schema_version": @1,
      @"operation_id": operationId,
      @"request_sha256": requestDigest,
      @"kind": @"export",
      @"phase": @"prepared",
      @"workspace_id": root[@"workspace_id"],
      @"binding_revision": root[@"binding_revision"],
      @"project_id": root[@"project_id"],
      @"destination_path": @"",
      @"source_paths": paths,
      @"staging_name": stagingName,
      @"entry_names": @[],
      @"entry_states": @[],
      @"created_at": LDNow(),
      @"updated_at": LDNow(),
    };
    if (![self saveStagingJournal:journal error:&error]) { [self reject:reject error:error]; return; }
    NSURL *staging = [self newStagingDirectory:@"export" operationId:operationId error:&error];
    if (staging == nil) { [self reject:reject error:error]; return; }
    NSMutableArray<NSURL *> *staged = [NSMutableArray arrayWithCapacity:paths.count];
    __block NSUInteger count = 0; __block uint64_t totalBytes = 0;
    BOOL copied = staging != nil && [self performRoot:root capabilities:[NSSet setWithObject:@"read"] block:^BOOL(int descriptor, NSError **blockError) {
      for (NSString *path in paths) {
        NSString *name = nil; NSString *relative = nil;
        int parent = [self openParent:path root:descriptor name:&name relative:&relative error:blockError];
        if (parent < 0) return NO;
        struct stat state = {};
        BOOL safe = fstatat(parent, name.fileSystemRepresentation, &state, AT_SYMLINK_NOFOLLOW) == 0 && !S_ISLNK(state.st_mode) && (S_ISREG(state.st_mode) || S_ISDIR(state.st_mode));
        NSURL *destination = [staging URLByAppendingPathComponent:name];
        if (!safe || ![self copyDescriptorItem:parent name:name to:destination depth:0 count:&count totalBytes:&totalBytes error:blockError]) { close(parent); return NO; }
        close(parent); [staged addObject:destination];
      }
      return YES;
    } error:&error];
    if (!copied) {
      NSMutableDictionary *needs = [journal mutableCopy];
      needs[@"phase"] = @"needs_recovery";
      needs[@"updated_at"] = LDNow();
      [self saveStagingJournal:needs error:nil];
      /* Keep a failed export staging tree recoverable for the next guarded retry. */
      [self reject:reject error:error ?: LDError(DSHLocalWorkspaceAccessErrorIO)]; return;
    }
    NSMutableArray<NSString *> *entryNames = [NSMutableArray arrayWithCapacity:paths.count];
    for (NSURL *url in staged) [entryNames addObject:url.lastPathComponent];
    NSMutableArray<NSDictionary *> *entryStates = [NSMutableArray arrayWithCapacity:staged.count];
    for (NSURL *url in staged) {
      struct stat stagedState = {};
      int stagedDescriptor = open(url.fileSystemRepresentation,
                                  O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
      BOOL stateValid = stagedDescriptor >= 0 && fstat(stagedDescriptor, &stagedState) == 0 &&
          (S_ISREG(stagedState.st_mode) || S_ISDIR(stagedState.st_mode)) &&
          (!S_ISREG(stagedState.st_mode) || stagedState.st_nlink == 1);
      if (stagedDescriptor >= 0) close(stagedDescriptor);
      if (!stateValid) {
        NSMutableDictionary *needs = [journal mutableCopy];
        needs[@"phase"] = @"needs_recovery";
        needs[@"entry_names"] = entryNames;
        needs[@"updated_at"] = LDNow();
        [self saveStagingJournal:needs error:nil];
        [self reject:reject error:LDError(DSHLocalWorkspaceAccessErrorConflict)];
        return;
      }
      [entryStates addObject:LDFileStateRecord(url.lastPathComponent, stagedState)];
    }
    NSMutableDictionary *stagedJournal = [journal mutableCopy];
    stagedJournal[@"phase"] = @"staged";
    stagedJournal[@"entry_names"] = entryNames;
    stagedJournal[@"entry_states"] = entryStates;
    stagedJournal[@"updated_at"] = LDNow();
    if (![self saveStagingJournal:stagedJournal error:&error]) { [self reject:reject error:error]; return; }
    dispatch_async(dispatch_get_main_queue(), ^{
      if (![self beginPickerMode:LDPickerModeExport resolve:resolve reject:reject]) {
        dispatch_async(self.documentQueue, ^{
          [self removeStagingDirectoryNamed:staging.lastPathComponent error:nil];
          [self removeStagingJournal:nil];
        });
        return;
      }
      self.pendingRoot = root;
      self.pendingSourcePaths = [paths copy];
      self.pendingOperationId = operationId;
      self.pendingExportStaging = staging;
      NSMutableArray<NSURL *> *urls = [staged mutableCopy];
      UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForExportingURLs:urls asCopy:YES];
      picker.delegate = self;
      self.pendingController = picker;
      [RishPresentedViewController() presentViewController:picker animated:YES completion:nil];
    });
  });
}

RISH_NATIVE_METHOD(queryOperation,
                 queryOperationRequest:(id)requestValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSDictionary *request = [requestValue isKindOfClass:NSDictionary.class] ? requestValue : nil;
  if (!LDExact(request, @[@"schema_version", @"operation_id", @"root"]) ||
      !LDSchemaOne(request[@"schema_version"]) || !LDUUID(request[@"operation_id"])) {
    [self dispatchInvalid:reject]; return;
  }
  NSError *validationError = nil;
  NSDictionary *root = LDRootFromRequest(request, &validationError);
  if (root == nil) { [self dispatchInvalid:reject]; return; }
  NSString *operationId = request[@"operation_id"];
  dispatch_async(self.documentQueue, ^{
    NSError *error = nil;
    NSDictionary *journal = [self loadStagingJournal:&error];
    if (error != nil) { [self reject:reject error:error]; return; }
    if (journal != nil && [journal[@"operation_id"] isEqual:operationId] &&
        !LDStoredRootMatches(journal, root)) {
      [self reject:reject error:LDError(DSHLocalWorkspaceAccessErrorConflict)];
      return;
    }
    if (![self recoverStagingJournal:&error]) { [self reject:reject error:error]; return; }
    journal = [self loadStagingJournal:&error];
    if (error != nil) { [self reject:reject error:error]; return; }
    if (journal != nil && [journal[@"operation_id"] isEqual:operationId] &&
        !LDStoredRootMatches(journal, root)) {
      [self reject:reject error:LDError(DSHLocalWorkspaceAccessErrorConflict)];
      return;
    }
    NSDictionary *receipt = journal == nil || ![journal[@"operation_id"] isEqual:operationId]
        ? [self committedReceiptForOperationId:operationId root:root error:&error] : nil;
    if (error != nil) { [self reject:reject error:error]; return; }
    NSString *status = journal != nil && [journal[@"operation_id"] isEqual:operationId]
        ? LDOperationStatusForPhase(journal[@"phase"])
        : receipt != nil ? @"committed" : @"not_started";
    resolve(@{ @"schema_version": @1, @"operation_id": operationId, @"status": status });
  });
}

RISH_NATIVE_METHOD(retryOperation,
                 retryOperationRequest:(id)requestValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSDictionary *request = [requestValue isKindOfClass:NSDictionary.class] ? requestValue : nil;
  if (!LDExact(request, @[@"schema_version", @"operation_id", @"root"]) ||
      !LDSchemaOne(request[@"schema_version"]) || !LDUUID(request[@"operation_id"])) {
    [self dispatchInvalid:reject]; return;
  }
  NSError *validationError = nil;
  NSDictionary *root = LDRootFromRequest(request, &validationError);
  if (root == nil) { [self dispatchInvalid:reject]; return; }
  NSString *operationId = request[@"operation_id"];
  dispatch_async(self.documentQueue, ^{
    NSError *error = nil;
    if (![self recoverStagingJournal:&error]) { [self reject:reject error:error]; return; }
    NSDictionary *journal = [self loadStagingJournal:&error];
    if (error != nil) { [self reject:reject error:error]; return; }
    if (journal == nil || ![journal[@"operation_id"] isEqual:operationId]) {
      NSDictionary *receipt = [self committedReceiptForOperationId:operationId
                                                               root:root
                                                              error:&error];
      if (error != nil) { [self reject:reject error:error]; return; }
      if (receipt != nil && (![receipt[@"workspace_id"] isEqual:root[@"workspace_id"]] ||
                             ![receipt[@"binding_revision"] isEqual:root[@"binding_revision"]] ||
                             ![receipt[@"project_id"] isEqual:root[@"project_id"]])) {
        [self reject:reject error:LDError(DSHLocalWorkspaceAccessErrorConflict)]; return;
      }
      resolve(@{ @"schema_version": @1, @"operation_id": operationId,
                 @"status": receipt == nil ? @"not_started" : @"committed" });
      return;
    }
    if (![journal[@"workspace_id"] isEqual:root[@"workspace_id"]] ||
        ![journal[@"binding_revision"] isEqual:root[@"binding_revision"]] ||
        ![journal[@"project_id"] isEqual:root[@"project_id"]]) {
      [self reject:reject error:LDError(DSHLocalWorkspaceAccessErrorConflict)]; return;
    }
    NSString *phase = journal[@"phase"];
    if ([phase isEqual:@"needs_recovery"]) {
      if (![self reconcileJournal:journal error:&error]) {
        [self reject:reject error:error ?: LDError(DSHLocalWorkspaceAccessErrorConflict)]; return;
      }
      journal = [self loadStagingJournal:&error];
      if (error != nil) { [self reject:reject error:error]; return; }
      if (journal == nil || ![journal[@"operation_id"] isEqual:operationId]) {
        [self reject:reject error:LDError(DSHLocalWorkspaceAccessErrorConflict)]; return;
      }
      phase = journal[@"phase"];
    }
    if ([journal[@"kind"] isEqual:@"import"] && ([phase isEqual:@"staged"] || [phase isEqual:@"publishing"])) {
      NSArray *entries = nil;
      if (![self publishJournal:journal root:root entries:&entries error:&error]) {
        [self reject:reject error:error]; return;
      }
      resolve(@{ @"schema_version": @1, @"operation_id": operationId, @"status": @"committed" });
      return;
    }
    resolve(@{ @"schema_version": @1, @"operation_id": operationId, @"status": LDOperationStatusForPhase(phase) });
  });
}

RISH_NATIVE_METHOD(cleanupOperation,
                 cleanupOperationRequest:(id)requestValue
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  NSDictionary *request = [requestValue isKindOfClass:NSDictionary.class] ? requestValue : nil;
  if (!LDExact(request, @[@"schema_version", @"operation_id", @"root"]) ||
      !LDSchemaOne(request[@"schema_version"]) || !LDUUID(request[@"operation_id"])) {
    [self dispatchInvalid:reject]; return;
  }
  NSError *validationError = nil;
  NSDictionary *root = LDRootFromRequest(request, &validationError);
  if (root == nil) { [self dispatchInvalid:reject]; return; }
  NSString *operationId = request[@"operation_id"];
  dispatch_async(self.documentQueue, ^{
    NSError *error = nil;
    NSDictionary *journal = [self loadStagingJournal:&error];
    if (error != nil) { [self reject:reject error:error]; return; }
    if (journal != nil && [journal[@"operation_id"] isEqual:operationId] &&
        !LDStoredRootMatches(journal, root)) {
      [self reject:reject error:LDError(DSHLocalWorkspaceAccessErrorConflict)];
      return;
    }
    if (![self recoverStagingJournal:&error]) { [self reject:reject error:error]; return; }
    journal = [self loadStagingJournal:&error];
    if (error != nil) { [self reject:reject error:error]; return; }
    if (journal != nil && [journal[@"operation_id"] isEqual:operationId] &&
        !LDStoredRootMatches(journal, root)) {
      [self reject:reject error:LDError(DSHLocalWorkspaceAccessErrorConflict)];
      return;
    }
    if (journal == nil || ![journal[@"operation_id"] isEqual:operationId]) {
      if (![self removeCommittedReceiptForOperationId:operationId root:root error:&error]) {
        [self reject:reject error:error ?: LDError(DSHLocalWorkspaceAccessErrorIO)]; return;
      }
      resolve(@{ @"schema_version": @1, @"operation_id": operationId, @"status": @"cleaned" });
      return;
    }
    if ([journal[@"phase"] isEqual:@"needs_recovery"] && [journal[@"kind"] isEqual:@"export"]) {
      if (![self removeStagingDirectoryNamed:journal[@"staging_name"] error:&error] ||
          ![self removeStagingJournal:&error]) {
        [self reject:reject error:error ?: LDError(DSHLocalWorkspaceAccessErrorIO)]; return;
      }
      resolve(@{ @"schema_version": @1, @"operation_id": operationId, @"status": @"cleaned" });
      return;
    }
    if ([journal[@"phase"] isEqual:@"needs_recovery"]) {
      NSError *safeCleanupError = nil;
      if ([self canCleanupUnpublishedJournal:journal error:&safeCleanupError]) {
        if (![self removeStagingDirectoryNamed:journal[@"staging_name"] error:&error] ||
            ![self removeStagingJournal:&error]) {
          [self reject:reject error:error ?: LDError(DSHLocalWorkspaceAccessErrorIO)]; return;
        }
        resolve(@{ @"schema_version": @1, @"operation_id": operationId, @"status": @"cleaned" });
        return;
      }
      if (safeCleanupError != nil && safeCleanupError.code != DSHLocalWorkspaceAccessErrorConflict) {
        [self reject:reject error:safeCleanupError]; return;
      }
      if (![self reconcileJournal:journal error:&error]) {
        [self reject:reject error:error ?: LDError(DSHLocalWorkspaceAccessErrorConflict)]; return;
      }
      journal = [self loadStagingJournal:&error];
      if (error != nil) { [self reject:reject error:error]; return; }
      if (journal == nil || ![journal[@"operation_id"] isEqual:operationId]) {
        if (![self removeCommittedReceiptForOperationId:operationId root:root error:&error]) {
          [self reject:reject error:error ?: LDError(DSHLocalWorkspaceAccessErrorIO)];
          return;
        }
        resolve(@{ @"schema_version": @1, @"operation_id": operationId, @"status": @"cleaned" });
        return;
      }
      if (!LDStoredRootMatches(journal, root)) {
        [self reject:reject error:LDError(DSHLocalWorkspaceAccessErrorConflict)];
        return;
      }
    }
    if ([journal[@"phase"] isEqual:@"publishing"] || [journal[@"phase"] isEqual:@"needs_recovery"]) {
      [self reject:reject error:LDError(DSHLocalWorkspaceAccessErrorConflict)]; return;
    }
    if (![self removeStagingDirectoryNamed:journal[@"staging_name"] error:&error] ||
        ![self removeStagingJournal:&error]) {
      [self reject:reject error:error ?: LDError(DSHLocalWorkspaceAccessErrorIO)]; return;
    }
    resolve(@{ @"schema_version": @1, @"operation_id": operationId, @"status": @"cleaned" });
  });
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
  (void)controller;
  LDPickerMode mode = self.pendingMode;
  NSUInteger generation = self.pendingGeneration;
  if ([self claimPendingCallbackForController:controller generation:generation] &&
      (mode == LDPickerModeImport || mode == LDPickerModeExport)) {
    [self finishCancellationForMode:mode generation:generation];
  }
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
  NSArray<NSURL *> *selectedURLs = [urls copy];
  LDPickerMode mode = self.pendingMode;
  NSDictionary *root = self.pendingRoot;
  NSString *operationId = self.pendingOperationId;
  NSUInteger generation = self.pendingGeneration;
  if (![self claimPendingCallbackForController:controller generation:generation]) return;
  if (mode == LDPickerModeExport) {
    NSURL *staging = self.pendingExportStaging;
    dispatch_async(self.documentQueue, ^{
      NSError *error = nil;
      NSDictionary *journal = [self loadStagingJournal:&error];
      BOOL valid = root != nil && journal != nil &&
          [journal[@"operation_id"] isEqual:operationId] &&
          [journal[@"workspace_id"] isEqual:root[@"workspace_id"]] &&
          [journal[@"binding_revision"] isEqual:root[@"binding_revision"]] &&
          [journal[@"project_id"] isEqual:root[@"project_id"]] &&
          [journal[@"kind"] isEqual:@"export"] &&
          [self performRoot:root capabilities:[NSSet setWithObject:@"read"] block:^BOOL(__unused int descriptor, __unused NSError **blockError) { return YES; } error:&error];
      if (valid) {
        NSMutableDictionary *committed = [journal mutableCopy];
        committed[@"phase"] = @"committed";
        committed[@"updated_at"] = LDNow();
        valid = [self saveStagingJournal:committed error:&error];
        journal = committed;
      }
      if (valid) valid = [self removeStagingDirectoryNamed:staging.lastPathComponent error:&error];
      if (valid) valid = [self archiveCommittedJournal:journal error:&error];
      NSDictionary *result = valid ? @{ @"schema_version": @1, @"status": @"exported", @"root": root, @"operation_id": operationId ?: @"", @"item_count": @(selectedURLs.count) } : nil;
      [self finishWithResult:result error:valid ? nil : (error ?: LDError(DSHLocalWorkspaceAccessErrorIO)) staging:nil generation:generation];
    });
    return;
  }
  if (mode == LDPickerModeImport && selectedURLs.count == 0 && root != nil) {
    [self finishCancellationForMode:mode generation:generation];
    return;
  }
  if (mode != LDPickerModeImport || selectedURLs.count > LDMaxExportItems || root == nil) {
    [self finishWithResult:nil error:LDError(DSHLocalWorkspaceAccessErrorInvalid) staging:nil generation:generation];
    return;
  }
  NSString *destinationPath = self.pendingDestinationPath;
  dispatch_async(self.documentQueue, ^{
    NSError *error = nil;
    if (![self recoverStagingJournal:&error]) {
      [self finishWithResult:nil error:error staging:nil generation:generation];
      return;
    }
    __block NSDictionary *journal = [self loadStagingJournal:&error];
    if (journal == nil || ![journal[@"operation_id"] isEqual:operationId] ||
        ![journal[@"workspace_id"] isEqual:root[@"workspace_id"]] ||
        ![journal[@"binding_revision"] isEqual:root[@"binding_revision"]] ||
        ![journal[@"project_id"] isEqual:root[@"project_id"]] ||
        ![journal[@"kind"] isEqual:@"import"]) {
      [self finishWithResult:nil error:error ?: LDError(DSHLocalWorkspaceAccessErrorConflict) staging:nil generation:generation];
      return;
    }
    NSURL *staging = [self existingStagingDirectory:@"import" operationId:operationId error:&error];
    if (staging == nil) {
      [self finishWithResult:nil error:error staging:nil generation:generation];
      return;
    }
    NSMutableSet<NSString *> *names = [NSMutableSet set];
    NSMutableArray<NSString *> *selectedNames = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *selectedStates = [NSMutableArray array];
    __block NSUInteger count = 0; __block uint64_t totalBytes = 0;
    BOOL copied = staging != nil;
    for (NSURL *source in selectedURLs) {
      NSString *name = source.lastPathComponent;
      if (!copied || !LDValidComponent(name) || [names containsObject:name]) {
        copied = NO; error = LDError(DSHLocalWorkspaceAccessErrorInvalid); break;
      }
      [names addObject:name]; [selectedNames addObject:name];
      NSMutableDictionary *stagedJournal = [journal mutableCopy];
      stagedJournal[@"phase"] = @"staged";
      stagedJournal[@"entry_names"] = [selectedNames copy];
      stagedJournal[@"updated_at"] = LDNow();
      if (![self saveStagingJournal:stagedJournal error:&error]) { copied = NO; break; }
      journal = stagedJournal;
      BOOL scoped = [source startAccessingSecurityScopedResource];
      __block BOOL sourceCopied = NO;
      __block NSError *copyError = nil;
      NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
      NSURL *destination = [staging URLByAppendingPathComponent:name];
      @try {
        [coordinator coordinateReadingItemAtURL:source options:NSFileCoordinatorReadingWithoutChanges error:&copyError byAccessor:^(NSURL *coordinatedURL) {
          struct stat selectedState = {};
          if (lstat(coordinatedURL.fileSystemRepresentation, &selectedState) != 0 ||
              S_ISLNK(selectedState.st_mode) ||
              (!S_ISDIR(selectedState.st_mode) && !S_ISREG(selectedState.st_mode))) {
            copyError = LDError(DSHLocalWorkspaceAccessErrorIO);
            return;
          }
          int sourceFlags = (S_ISDIR(selectedState.st_mode) ? (O_RDONLY | O_DIRECTORY) : O_RDONLY) |
              O_CLOEXEC | O_NOFOLLOW;
          int sourceDescriptor = open(coordinatedURL.fileSystemRepresentation, sourceFlags);
          struct stat openedState = {};
          BOOL identity = sourceDescriptor >= 0 && fstat(sourceDescriptor, &openedState) == 0 &&
              LDSameFileState(selectedState, openedState);
          sourceCopied = identity && [self copyOpenedItem:sourceDescriptor state:openedState to:destination depth:0 count:&count totalBytes:&totalBytes error:&copyError];
          if (sourceDescriptor >= 0) close(sourceDescriptor);
        }];
      } @catch (__unused NSException *exception) {
        sourceCopied = NO;
        copyError = LDError(DSHLocalWorkspaceAccessErrorIO);
      } @finally {
        if (scoped) [source stopAccessingSecurityScopedResource];
      }
      if (!sourceCopied) { copied = NO; error = copyError ?: LDError(DSHLocalWorkspaceAccessErrorIO); break; }
      struct stat stagedState = {};
      int stagedDescriptor = open(destination.fileSystemRepresentation,
                                  O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
      BOOL stagedValid = stagedDescriptor >= 0 && fstat(stagedDescriptor, &stagedState) == 0 &&
          (S_ISREG(stagedState.st_mode) || S_ISDIR(stagedState.st_mode)) &&
          (!S_ISREG(stagedState.st_mode) || stagedState.st_nlink == 1);
      if (stagedDescriptor >= 0) close(stagedDescriptor);
      if (!stagedValid) {
        copied = NO;
        error = LDError(DSHLocalWorkspaceAccessErrorConflict);
        break;
      }
      [selectedStates addObject:LDFileStateRecord(name, stagedState)];
      stagedJournal = [journal mutableCopy];
      stagedJournal[@"phase"] = @"staged";
      stagedJournal[@"entry_names"] = [selectedNames copy];
      stagedJournal[@"entry_states"] = [selectedStates copy];
      stagedJournal[@"updated_at"] = LDNow();
      if (![self saveStagingJournal:stagedJournal error:&error]) { copied = NO; break; }
      journal = stagedJournal;
    }
    if (copied) {
      int stagedDescriptor = open(staging.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
      if (stagedDescriptor < 0 || fsync(stagedDescriptor) != 0) {
        if (stagedDescriptor >= 0) close(stagedDescriptor);
        copied = NO;
        error = LDError(DSHLocalWorkspaceAccessErrorIO);
      } else {
        close(stagedDescriptor);
      }
    }
    if (!copied) {
      NSMutableDictionary *needs = [journal mutableCopy];
      needs[@"phase"] = @"needs_recovery";
      needs[@"updated_at"] = LDNow();
      [self saveStagingJournal:needs error:nil];
      [self finishWithResult:nil error:error ?: LDError(DSHLocalWorkspaceAccessErrorIO) staging:nil generation:generation];
      return;
    }
    NSMutableDictionary *staged = [journal mutableCopy];
    staged[@"phase"] = @"staged";
    staged[@"entry_names"] = [selectedNames copy];
    staged[@"entry_states"] = [selectedStates copy];
    staged[@"updated_at"] = LDNow();
    if (![self saveStagingJournal:staged error:&error]) {
      [self finishWithResult:nil error:error staging:nil generation:generation];
      return;
    }
    NSArray<NSDictionary *> *entries = nil;
    BOOL published = [self publishJournal:staged root:root entries:&entries error:&error];
    NSDictionary *result = published ? @{ @"schema_version": @1, @"status": @"imported", @"root": root, @"operation_id": operationId, @"destination_path": destinationPath ?: @"", @"entries": entries ?: @[] } : nil;
    [self finishWithResult:result error:published ? nil : (error ?: LDError(DSHLocalWorkspaceAccessErrorIO)) staging:nil generation:generation];
  });
}

@end
