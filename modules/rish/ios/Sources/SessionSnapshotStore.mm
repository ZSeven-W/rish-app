#import "ProviderConfiguration.h"
#import "SessionSnapshotStore.h"
#import "AgentTranscriptStore.h"
#import "RishHarnessCatalog.h"

#include "rish_agent_core.h"

#import "DSHWorkspaceCanonical.h"
#import "LocalWorkspaceAccess.h"
#import "WorkspaceClearanceStore.h"

#import <TargetConditionals.h>
#import <objc/runtime.h>

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdint.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

NSErrorDomain const DSHSessionSnapshotStoreErrorDomain =
    @"dev.zseven.rish.session-snapshot-store";

NSString *const DSHSessionSnapshotStoreErrorInvalidCode =
    @"E_SESSION_INVALID";
NSString *const DSHSessionSnapshotStoreErrorCorruptCode =
    @"E_SESSION_CORRUPT";
NSString *const DSHSessionSnapshotStoreErrorStorageCode =
    @"E_SESSION_STORAGE";
NSString *const DSHSessionSnapshotStoreErrorProtectionCode =
    @"E_SESSION_PROTECTION";
NSString *const DSHSessionSnapshotStoreErrorBoundsCode =
    @"E_SESSION_BOUNDS";
NSString *const DSHSessionSnapshotStoreErrorConflictCode =
    @"E_SESSION_CONFLICT";

static const NSUInteger DSHSessionSnapshotMaximumBytes = 16U * 1024U * 1024U;
static const NSUInteger DSHSessionSnapshotMaximumCanonicalBytes =
    16U * 1024U * 1024U;
static const unsigned long long DSHSessionSnapshotMaximumSafeInteger =
    9007199254740991ULL;
static const NSUInteger DSHSessionSnapshotMaximumTombstoneBytes =
    16U * 1024U * 1024U;

static NSString *const DSHSessionSnapshotFilename = @"sessions.json";
static NSString *const DSHSessionSnapshotTombstoneFilename =
    @".sessions.commit-tombstones";

static NSError *DSHSessionStoreError(
    DSHSessionSnapshotStoreErrorCode code) {
  NSString *publicCode = DSHSessionSnapshotStoreErrorStorageCode;
  switch (code) {
    case DSHSessionSnapshotStoreErrorInvalidArgument:
      publicCode = DSHSessionSnapshotStoreErrorInvalidCode;
      break;
    case DSHSessionSnapshotStoreErrorCorrupt:
      publicCode = DSHSessionSnapshotStoreErrorCorruptCode;
      break;
    case DSHSessionSnapshotStoreErrorStorage:
      publicCode = DSHSessionSnapshotStoreErrorStorageCode;
      break;
    case DSHSessionSnapshotStoreErrorProtection:
      publicCode = DSHSessionSnapshotStoreErrorProtectionCode;
      break;
    case DSHSessionSnapshotStoreErrorBounds:
      publicCode = DSHSessionSnapshotStoreErrorBoundsCode;
      break;
    case DSHSessionSnapshotStoreErrorConflict:
      publicCode = DSHSessionSnapshotStoreErrorConflictCode;
      break;
  }
  return [NSError errorWithDomain:DSHSessionSnapshotStoreErrorDomain
                             code:code
                         userInfo:@{
                           @"code" : publicCode,
                           NSLocalizedDescriptionKey : publicCode,
                         }];
}

static BOOL DSHSessionSetError(NSError **error,
                               DSHSessionSnapshotStoreErrorCode code) {
  if (error != nullptr) *error = DSHSessionStoreError(code);
  return NO;
}

typedef NS_ENUM(NSInteger, DSHSessionPinnedPathCheck) {
  DSHSessionPinnedPathCheckOK = 0,
  DSHSessionPinnedPathCheckStorage = 1,
  DSHSessionPinnedPathCheckProtection = 2,
  DSHSessionPinnedPathCheckConflict = 3,
};

static BOOL DSHSessionSamePinnedIdentity(const struct stat *left,
                                         const struct stat *right) {
  return left != nullptr && right != nullptr &&
      left->st_dev == right->st_dev && left->st_ino == right->st_ino &&
      left->st_size == right->st_size &&
      (left->st_mode & S_IFMT) == (right->st_mode & S_IFMT) &&
      left->st_nlink == right->st_nlink &&
      (left->st_mode & 0777) == (right->st_mode & 0777);
}

static DSHSessionPinnedPathCheck DSHSessionCheckPinnedPath(
    int descriptor,
    NSURL *url,
    BOOL directory,
    mode_t requiredMode,
    const struct stat *expected,
    struct stat *stateOut) {
  if (descriptor < 0 || ![url isKindOfClass:NSURL.class] || !url.isFileURL ||
      url.path.length == 0) {
    return DSHSessionPinnedPathCheckStorage;
  }
  struct stat descriptorState = {};
  struct stat pathState = {};
  if (fstat(descriptor, &descriptorState) != 0 ||
      lstat(url.fileSystemRepresentation, &pathState) != 0) {
    return DSHSessionPinnedPathCheckStorage;
  }
  BOOL descriptorTypeOK = directory ? S_ISDIR(descriptorState.st_mode)
                                    : S_ISREG(descriptorState.st_mode);
  BOOL pathTypeOK = directory ? S_ISDIR(pathState.st_mode)
                              : S_ISREG(pathState.st_mode);
  if (!descriptorTypeOK || !pathTypeOK || S_ISLNK(pathState.st_mode)) {
    return DSHSessionPinnedPathCheckProtection;
  }
  if (!DSHSessionSamePinnedIdentity(&descriptorState, &pathState) ||
      (expected != nullptr &&
       !DSHSessionSamePinnedIdentity(&descriptorState, expected))) {
    return DSHSessionPinnedPathCheckConflict;
  }
  if ((!directory &&
       (descriptorState.st_nlink != 1 || pathState.st_nlink != 1)) ||
      (descriptorState.st_mode & 0777) != requiredMode ||
      (pathState.st_mode & 0777) != requiredMode) {
    return DSHSessionPinnedPathCheckProtection;
  }
  if (stateOut != nullptr) *stateOut = descriptorState;
  return DSHSessionPinnedPathCheckOK;
}

static BOOL DSHSessionObjectComesFromSystemFramework(id value) {
  if (value == nil) return NO;
  const char *image = class_getImageName(object_getClass(value));
  if (image == nullptr) return NO;
  return strstr(image, "/Foundation.framework/") != nullptr ||
      strstr(image, "/CoreFoundation.framework/") != nullptr ||
      strstr(image, "/libobjc.A.dylib") != nullptr;
}

static BOOL DSHSessionTrustedDictionary(id value) {
  return [value isKindOfClass:NSDictionary.class] &&
      DSHSessionObjectComesFromSystemFramework(value) && [value copy] == value;
}

static BOOL DSHSessionTrustedString(id value) {
  return [value isKindOfClass:NSString.class] &&
      DSHSessionObjectComesFromSystemFramework(value) && [value copy] == value;
}

static BOOL DSHSessionTrustedNumber(id value) {
  return [value isKindOfClass:NSNumber.class] &&
      ![value isKindOfClass:NSDecimalNumber.class] &&
      DSHSessionObjectComesFromSystemFramework(value);
}

static BOOL DSHSessionIsBoolean(id value) {
  return DSHSessionTrustedNumber(value) &&
      CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static BOOL DSHSessionSafeInteger(id value, BOOL allowZero) {
  if (!DSHSessionTrustedNumber(value) || DSHSessionIsBoolean(value)) {
    return NO;
  }
  double number = [value doubleValue];
  if (!isfinite(number) || floor(number) != number || number < 0.0 ||
      number > (double)DSHSessionSnapshotMaximumSafeInteger ||
      (number == 0.0 && signbit(number)) || (!allowZero && number == 0.0)) {
    return NO;
  }
  return YES;
}

static BOOL DSHSessionExactKeys(NSDictionary *dictionary,
                                NSArray<NSString *> *keys) {
  if (!DSHSessionTrustedDictionary(dictionary) ||
      dictionary.count != keys.count) {
    return NO;
  }
  NSSet *expected = [NSSet setWithArray:keys];
  for (id key in dictionary) {
    if (!DSHSessionTrustedString(key) || ![expected containsObject:key]) {
      return NO;
    }
  }
  return YES;
}

static BOOL DSHSessionCanonicalUUID(id value) {
  if (!DSHSessionTrustedString(value)) return NO;
  NSString *string = value;
  if (string.length != 36 || ![string isEqualToString:string.lowercaseString]) {
    return NO;
  }
  NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:string];
  return uuid != nil && [uuid.UUIDString.lowercaseString isEqualToString:string];
}

static BOOL DSHSessionCanonicalDigest(id value) {
  if (!DSHSessionTrustedString(value)) return NO;
  NSString *string = value;
  if (string.length != 64 || ![string isEqualToString:string.lowercaseString]) {
    return NO;
  }
  NSCharacterSet *hex =
      [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
  return [string rangeOfCharacterFromSet:hex.invertedSet].location == NSNotFound;
}

static BOOL DSHSessionExactSchema(id value, NSUInteger schema) {
  return DSHSessionSafeInteger(value, YES) &&
      [value unsignedIntegerValue] == schema;
}

static NSData *DSHSessionCanonicalJSON(id object,
                                       NSError **error,
                                       DSHSessionSnapshotStoreErrorCode code) {
  NSError *canonicalError = nil;
  NSData *data = DSHWorkspaceCanonicalJSONData(object, &canonicalError);
  if (![data isKindOfClass:NSData.class] || data.length == 0 ||
      data.length > DSHSessionSnapshotMaximumCanonicalBytes) {
    DSHSessionSetError(error, code);
    return nil;
  }
  return data;
}

#pragma mark - Shared core bridge (modules/rish/core session_schema)

// The shared core validates candidates, stored envelopes and tombstone files
// and mints the chat-session digest; it never touches the catalogue. Every
// catalogue answer the validators need is gathered here from the strings and
// provider bindings that actually occur in the parsed tree, so the core's
// answer is exactly the one the catalogue would give for this input.

static NSString *DSHSessionCoreBindingKey(id binding, id model) {
  NSDictionary *keyed = @{
    @"binding" : binding ?: NSNull.null,
    @"model" : model ?: NSNull.null,
  };
  NSData *canonical = DSHWorkspaceCanonicalJSONData(keyed, nil);
  return canonical == nil ? nil : DSHWorkspaceSHA256Hex(canonical);
}

static void DSHSessionCoreCollectFacts(id node,
                                       NSMutableSet<NSString *> *strings,
                                       NSMutableArray<NSDictionary *> *bindings,
                                       NSMutableSet<NSString *> *bindingKeys) {
  if ([node isKindOfClass:NSString.class]) {
    [strings addObject:node];
    return;
  }
  if ([node isKindOfClass:NSArray.class]) {
    for (id child in (NSArray *)node) {
      DSHSessionCoreCollectFacts(child, strings, bindings, bindingKeys);
    }
    return;
  }
  if (![node isKindOfClass:NSDictionary.class]) return;
  NSDictionary *record = node;
  id binding = record[@"provider_configuration"];
  if (binding != nil) {
    id model = record[@"model"];
    NSString *key = DSHSessionCoreBindingKey(binding, model);
    if (key != nil && ![bindingKeys containsObject:key]) {
      [bindingKeys addObject:key];
      BOOL valid = [binding isKindOfClass:NSDictionary.class] &&
          DSHValidateProviderBinding(binding, model);
      NSString *host = nil;
      if (valid) {
        id endpoint = ((NSDictionary *)binding)[@"endpoint_url"];
        if ([endpoint isKindOfClass:NSString.class]) {
          host = [NSURL URLWithString:endpoint].host;
        }
      }
      [bindings addObject:@{
        @"canonical_sha256" : key,
        @"valid" : @(valid),
        @"host" : host ?: NSNull.null,
      }];
    }
  }
  for (id child in record.allValues) {
    DSHSessionCoreCollectFacts(child, strings, bindings, bindingKeys);
  }
}

static NSDictionary *DSHSessionCoreEnvironment(id root) {
  NSMutableSet<NSString *> *strings = [NSMutableSet set];
  NSMutableArray<NSDictionary *> *bindings = [NSMutableArray array];
  NSMutableSet<NSString *> *bindingKeys = [NSMutableSet set];
  DSHSessionCoreCollectFacts(root, strings, bindings, bindingKeys);
  NSMutableArray<NSString *> *models = [NSMutableArray array];
  NSMutableDictionary<NSString *, NSString *> *harnessByModel =
      [NSMutableDictionary dictionary];
  NSMutableDictionary<NSString *, NSString *> *hostByModel =
      [NSMutableDictionary dictionary];
  NSMutableArray<NSString *> *providers = [NSMutableArray array];
  for (NSString *string in strings) {
    if (DSHHarnessIsSupportedModel(string)) {
      [models addObject:string];
      NSString *harness = DSHHarnessIdForModel(string);
      if (harness != nil) harnessByModel[string] = harness;
      NSString *host = DSHProviderHostForModel(string);
      if (host != nil) hostByModel[string] = host;
    }
    if (DSHHarnessIsProviderId(string)) [providers addObject:string];
  }
  [models sortUsingSelector:@selector(compare:)];
  [providers sortUsingSelector:@selector(compare:)];
  [bindings sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
    return [a[@"canonical_sha256"] compare:b[@"canonical_sha256"]];
  }];
  return @{
    @"supported_models" : [models copy],
    @"harness_by_model" : [harnessByModel copy],
    @"provider_ids" : [providers copy],
    @"host_by_model" : [hostByModel copy],
    @"provider_bindings" : [bindings copy],
  };
}

static NSDictionary *DSHSessionCoreReduce(NSString *op,
                                          NSDictionary *fields,
                                          NSData *input,
                                          NSDictionary *env,
                                          DSHSessionSnapshotStoreErrorCode fallback,
                                          NSError **error) {
  NSMutableDictionary *envelope = [fields mutableCopy] ?: [NSMutableDictionary dictionary];
  envelope[@"op"] = op;
  envelope[@"env"] = env ?: @{};
  NSData *request = [NSJSONSerialization dataWithJSONObject:envelope options:0 error:nil];
  if (request == nil) {
    DSHSessionSetError(error, fallback);
    return nil;
  }
  char *raw = rish_agent_session_reduce((const char *)request.bytes,
                                        request.length,
                                        (const uint8_t *)input.bytes,
                                        input.length);
  if (raw == NULL) {
    DSHSessionSetError(error, fallback);
    return nil;
  }
  NSData *bytes = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  id reply = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
  if (![reply isKindOfClass:NSDictionary.class]) {
    DSHSessionSetError(error, fallback);
    return nil;
  }
  if (![reply[@"ok"] isEqual:@YES]) {
    NSInteger code = [reply[@"error"] isKindOfClass:NSNumber.class]
        ? [reply[@"error"] integerValue] : 0;
    DSHSessionSnapshotStoreErrorCode mapped = fallback;
    if (code == DSHSessionSnapshotStoreErrorInvalidArgument ||
        code == DSHSessionSnapshotStoreErrorCorrupt ||
        code == DSHSessionSnapshotStoreErrorBounds ||
        code == DSHSessionSnapshotStoreErrorConflict) {
      mapped = (DSHSessionSnapshotStoreErrorCode)code;
    }
    DSHSessionSetError(error, mapped);
    return nil;
  }
  return reply;
}

// The tree the store keeps once the core has accepted the bytes: a plain
// Foundation decode of exactly the bytes the core validated.
static NSDictionary *DSHSessionCoreDecodedObject(NSData *bytes) {
  if (![bytes isKindOfClass:NSData.class] || bytes.length == 0) return nil;
  id object = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
  return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

// Candidate acceptance for the CAS and clearance paths: the core applies the
// strict parse, the full schema-9 validation and mints the chat-session
// digest; callers have already applied the byte bounds.
static NSDictionary *DSHSessionCoreAcceptCandidate(NSData *bytes,
                                                   NSString **digestOut,
                                                   NSError **error) {
  NSDictionary *candidate = DSHSessionCoreDecodedObject(bytes);
  NSDictionary *reply = DSHSessionCoreReduce(
      @"candidate", nil, bytes, DSHSessionCoreEnvironment(candidate),
      DSHSessionSnapshotStoreErrorInvalidArgument, error);
  if (reply == nil) return nil;
  NSString *digest = reply[@"digest"];
  if (candidate == nil || ![digest isKindOfClass:NSString.class]) {
    DSHSessionSetError(error, DSHSessionSnapshotStoreErrorInvalidArgument);
    return nil;
  }
  if (digestOut != nullptr) *digestOut = digest;
  return candidate;
}

static NSDictionary *DSHSessionSnapshotRef(NSUInteger generation,
                                           NSString *digest) {
  return @{
    @"schema_version" : @1,
    @"generation" : @(generation),
    @"session_sha256" : digest,
  };
}

static NSDictionary *DSHSessionLegacyRef(NSString *digest) {
  return @{
    @"schema_version" : @1,
    @"legacy_bytes_sha256" : digest,
  };
}

static NSDictionary *DSHSessionMissingAuthority(void) {
  return @{@"schema_version" : @1, @"kind" : @"missing"};
}

static NSDictionary *DSHSessionLegacyAuthority(NSString *digest) {
  return @{
    @"schema_version" : @1,
    @"kind" : @"legacy_present",
    @"legacy" : DSHSessionLegacyRef(digest),
  };
}

static NSDictionary *DSHSessionPresentAuthority(NSUInteger generation,
                                                NSString *digest) {
  return @{
    @"schema_version" : @1,
    @"kind" : @"present",
    @"snapshot" : DSHSessionSnapshotRef(generation, digest),
  };
}

static NSDictionary *DSHSessionLoadMissingResult(NSString *currentLaunchInstanceId) {
  return @{
    @"schema_version" : @1,
    @"status" : @"missing",
    @"snapshot" : NSNull.null,
    @"session_json" : NSNull.null,
    @"writer_launch_instance_id" : NSNull.null,
    @"current_launch_instance_id" : currentLaunchInstanceId,
  };
}

@interface DSHSessionLoadedState : NSObject
@property(nonatomic) BOOL missing;
@property(nonatomic) BOOL legacy;
@property(nonatomic) BOOL hasFile;
@property(nonatomic) dev_t device;
@property(nonatomic) ino_t inode;
@property(nonatomic) off_t fileSize;
@property(nonatomic, strong) NSData *rawBytes;
@property(nonatomic, strong) NSDictionary *session;
@property(nonatomic, strong) NSArray<NSDictionary *> *recentCommits;
@property(nonatomic, copy) NSString *legacyBytesDigest;
@property(nonatomic, copy) NSString *sessionDigest;
@property(nonatomic, copy) NSString *writerLaunchInstanceId;
@property(nonatomic) NSUInteger generation;
@property(nonatomic, copy) NSDictionary *authority;
/// The core's view of the tombstone ledger read right after the envelope
/// (`{missing, valid, generation, operation_ids}`), nil when that read failed.
@property(nonatomic, copy) NSDictionary *tombstones;
@end

@implementation DSHSessionLoadedState
@end

@interface DSHSessionTombstoneState : NSObject
@property(nonatomic) BOOL missing;
@property(nonatomic) BOOL valid;
@property(nonatomic) dev_t device;
@property(nonatomic) ino_t inode;
@property(nonatomic) off_t fileSize;
@property(nonatomic, strong) NSData *rawBytes;
@property(nonatomic) NSUInteger generation;
@property(nonatomic, strong) NSSet<NSString *> *operationIds;
@end

@implementation DSHSessionTombstoneState
@end

static DSHSessionLoadedState *DSHSessionExpectedStateForTombstones(
    DSHSessionTombstoneState *tombstones) {
  DSHSessionLoadedState *expected = [[DSHSessionLoadedState alloc] init];
  expected.missing = tombstones == nil || tombstones.missing;
  expected.hasFile = !expected.missing;
  if (tombstones != nil) {
    expected.device = tombstones.device;
    expected.inode = tombstones.inode;
    expected.fileSize = tombstones.fileSize;
    expected.rawBytes = tombstones.rawBytes;
  }
  return expected;
}

// The core's view of a tombstone read: nil (the read failed) becomes null.
static NSDictionary *DSHSessionCoreTombstoneView(DSHSessionTombstoneState *tombstones) {
  if (tombstones == nil) return nil;
  NSArray *ids = [tombstones.operationIds.allObjects
      sortedArrayUsingSelector:@selector(compare:)] ?: @[];
  return @{
    @"missing" : @(tombstones.missing),
    @"valid" : @(tombstones.valid),
    @"generation" : @(tombstones.generation),
    @"operation_ids" : ids,
  };
}

// The core's view of a loaded state (`Loaded` in session_schema::cas).
static id DSHSessionCoreLoadedView(DSHSessionLoadedState *state) {
  if (state == nil) return NSNull.null;
  if (state.missing) return @{ @"kind" : @"missing" };
  if (state.legacy) {
    return @{ @"kind" : @"legacy", @"legacy_bytes_sha256" : state.legacyBytesDigest ?: @"" };
  }
  NSMutableArray<NSString *> *outbox = [NSMutableArray array];
  id entries = state.session[@"workspace_authority_outbox"];
  if ([entries isKindOfClass:NSArray.class]) {
    for (id entry in entries) {
      id operationId = [entry isKindOfClass:NSDictionary.class] ? entry[@"operation_id"] : nil;
      if ([operationId isKindOfClass:NSString.class]) [outbox addObject:operationId];
    }
  }
  return @{
    @"kind" : @"present",
    @"generation" : @(state.generation),
    @"session_sha256" : state.sessionDigest ?: @"",
    @"recent_commits" : state.recentCommits ?: @[],
    @"tombstones" : state.tombstones ?: NSNull.null,
    @"outbox_operation_ids" : outbox,
  };
}

// committed / conflict / unknown outcomes become the CAS result; nil means
// the core said to proceed.
static NSDictionary *DSHSessionCASOutcomeResult(NSDictionary *reply) {
  NSString *outcome = reply[@"outcome"];
  if ([outcome isEqual:@"committed"] && [reply[@"snapshot"] isKindOfClass:NSDictionary.class]) {
    return @{ @"schema_version" : @1, @"status" : @"committed", @"snapshot" : reply[@"snapshot"] };
  }
  if (([outcome isEqual:@"conflict"] || [outcome isEqual:@"unknown"]) &&
      [reply[@"current"] isKindOfClass:NSDictionary.class]) {
    return @{ @"schema_version" : @1, @"status" : outcome, @"current" : reply[@"current"] };
  }
  return nil;
}

typedef NS_ENUM(NSInteger, DSHSessionAtomicWriteResult) {
  DSHSessionAtomicWriteCommitted = 0,
  DSHSessionAtomicWriteNoEffect = 1,
  DSHSessionAtomicWriteUnknown = 2,
};

// Parsing and validating a megabyte envelope is a pure function of its bytes,
// and one checkpoint reads the same file three or four times (authority read,
// CAS pre-check, CAS re-check, post-write verification). Remember the last
// validated envelope by exact byte equality; identity, protection and
// tombstone checks are still performed on every read.
@interface DSHSessionValidatedEnvelope : NSObject
@property(nonatomic, strong) NSData *bytes;
@property(nonatomic, strong) NSDictionary *envelope;
@property(nonatomic, strong) NSDictionary *session;
@property(nonatomic, copy) NSString *digest;
@property(nonatomic) NSUInteger generation;
@property(nonatomic, strong) NSArray *commits;
@end
@implementation DSHSessionValidatedEnvelope
@end

static DSHSessionValidatedEnvelope *DSHSessionValidatedEnvelopeLast;

static DSHSessionValidatedEnvelope *DSHSessionValidatedEnvelopeCached(NSData *raw) {
  @synchronized (DSHSessionValidatedEnvelope.class) {
    DSHSessionValidatedEnvelope *cached = DSHSessionValidatedEnvelopeLast;
    if (raw == nil || cached == nil) return nil;
    return [cached.bytes isEqualToData:raw] ? cached : nil;
  }
}

static void DSHSessionValidatedEnvelopeRemember(DSHSessionValidatedEnvelope *entry) {
  @synchronized (DSHSessionValidatedEnvelope.class) {
    DSHSessionValidatedEnvelopeLast = entry;
  }
}

@interface DSHSessionSnapshotStore ()
@property(nonatomic, readwrite, strong) NSURL *sessionURL;
@property(nonatomic, readwrite, strong) NSURL *rootURL;
@property(nonatomic, readwrite, copy) NSString *launchInstanceId;
@property(nonatomic, readwrite, strong) DSHSessionWorkspaceCoordinator *coordinator;
@property(nonatomic, readwrite, strong) DSHWorkspaceClearanceStore *clearanceStore;
@property(nonatomic, strong) DSHLocalWorkspaceAccess *clearanceWorkspaceAccess;
@property(nonatomic, copy) DSHSessionSnapshotStoreFaultHook faultHook;
@property(nonatomic) int rootDescriptor;
@property(nonatomic) dev_t rootDevice;
@property(nonatomic) ino_t rootInode;
@property(nonatomic) int parentDescriptor;
@property(nonatomic) dev_t parentDevice;
@property(nonatomic) ino_t parentInode;
@property(nonatomic, copy) NSString *rootName;
@property(nonatomic, copy) NSString *sessionFilename;
- (BOOL)requiresSessionResourceMetadata;
- (id)sessionProtectionPolicyValue;
- (BOOL)setSessionProtectionValue:(id)value
                            atURL:(NSURL *)url
                            error:(NSError **)error;
- (BOOL)setSessionBackupExcluded:(BOOL)excluded
                           atURL:(NSURL *)url
                           error:(NSError **)error;
- (BOOL)getSessionProtectionAtURL:(NSURL *)url
                            value:(id *)value
                            error:(NSError **)error;
- (BOOL)getSessionBackupExcludedAtURL:(NSURL *)url
                                value:(NSNumber **)value
                                error:(NSError **)error;
- (BOOL)hardenPinnedDescriptor:(int)descriptor
                         atURL:(NSURL *)url
                     directory:(BOOL)directory
                 excludeBackup:(BOOL)excludeBackup
                         error:(NSError **)error;
- (BOOL)validatePinnedDescriptor:(int)descriptor
                           atURL:(NSURL *)url
                       directory:(BOOL)directory
                   excludeBackup:(BOOL)excludeBackup
                 requireMetadata:(BOOL)requireMetadata
                           error:(NSError **)error;
- (NSData *)readStoredBytesForFilename:(NSString *)filename
                               missing:(BOOL *)missing
                                 state:(struct stat *)identity
                                 error:(NSError **)error;
- (BOOL)targetMatchesExpectedState:(DSHSessionLoadedState *)expected
                           filename:(NSString *)filename
                              error:(NSError **)error;
- (BOOL)validateProtectedFileWithIdentity:(const struct stat *)expected
                                  filename:(NSString *)filename
                                     error:(NSError **)error;
- (DSHSessionAtomicWriteResult)writeProtectedData:(NSData *)data
                                          filename:(NSString *)filename
                                     expectedState:(DSHSessionLoadedState *)expected
                                             error:(NSError **)error;
- (DSHSessionAtomicWriteResult)writeProtectedData:(NSData *)data
                                          filename:(NSString *)filename
                                     expectedState:(DSHSessionLoadedState *)expected
                                    lockDescriptor:(int)lockDescriptor
                                             error:(NSError **)error;
- (DSHSessionAtomicWriteResult)writeEnvelopeData:(NSData *)data
                                     expectedState:(DSHSessionLoadedState *)expected
                                    lockDescriptor:(int)lockDescriptor
                                             error:(NSError **)error;
- (DSHSessionAtomicWriteResult)publishTemporaryFilename:(NSString *)temporaryName
                                               filename:(NSString *)filename
                                          expectedState:(DSHSessionLoadedState *)expected
                                                  error:(NSError **)error;
- (DSHSessionTombstoneState *)readTombstoneStateWithError:(NSError **)error;
- (int)acquireCASLock:(NSError **)error;
- (nullable NSDictionary *)casPersistSessionLocked:(NSDictionary *)request
                                    lockDescriptor:(int)lockDescriptor
                                              error:(NSError **)error;
@end

NSString *DSHSessionSnapshotStoreLaunchInstanceId(void) {
  static NSString *value = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    value = NSUUID.UUID.UUIDString.lowercaseString;
  });
  return value;
}

@implementation DSHSessionSnapshotStore

- (nullable instancetype)initWithError:(NSError **)error {
  NSError *supportError = nil;
  NSURL *support = [[NSFileManager defaultManager]
      URLForDirectory:NSApplicationSupportDirectory
             inDomain:NSUserDomainMask
    appropriateForURL:nil
               create:YES
                error:&supportError];
  if (support == nil) {
    if (error != nullptr) *error = DSHSessionStoreError(
        DSHSessionSnapshotStoreErrorStorage);
    return nil;
  }
  return [self initWithRootURL:support
                     sessionURL:[support URLByAppendingPathComponent:
                                           DSHSessionSnapshotFilename]
               launchInstanceId:nil
                     coordinator:nil
                       faultHook:nil];
}

- (instancetype)initWithRootURL:(NSURL *)rootURL {
  return [self initWithRootURL:rootURL
                     sessionURL:[rootURL URLByAppendingPathComponent:
                                           DSHSessionSnapshotFilename]
               launchInstanceId:nil
                     coordinator:nil
                       faultHook:nil];
}

- (instancetype)initWithRootURL:(NSURL *)rootURL
                launchInstanceId:(NSString *)launchInstanceId {
  return [self initWithRootURL:rootURL
                     sessionURL:[rootURL URLByAppendingPathComponent:
                                           DSHSessionSnapshotFilename]
               launchInstanceId:launchInstanceId
                     coordinator:nil
                       faultHook:nil];
}

- (instancetype)initWithPrivateRootURL:(NSURL *)privateRootURL {
  return [self initWithRootURL:privateRootURL];
}

- (instancetype)initWithSessionURL:(NSURL *)sessionURL {
  return [self initWithRootURL:sessionURL.URLByDeletingLastPathComponent
                     sessionURL:sessionURL
               launchInstanceId:nil
                     coordinator:nil
                       faultHook:nil];
}

- (instancetype)initWithSessionURL:(NSURL *)sessionURL
                  launchInstanceId:(NSString *)launchInstanceId {
  return [self initWithRootURL:sessionURL.URLByDeletingLastPathComponent
                     sessionURL:sessionURL
               launchInstanceId:launchInstanceId
                     coordinator:nil
                       faultHook:nil];
}

- (instancetype)initWithRootURL:(NSURL *)rootURL
                      sessionURL:(NSURL *)sessionURL
                launchInstanceId:(NSString *)launchInstanceId
                      coordinator:(DSHSessionWorkspaceCoordinator *)coordinator
                        faultHook:(DSHSessionSnapshotStoreFaultHook)faultHook {
  return [self initWithRootURL:rootURL
                    sessionURL:sessionURL
              launchInstanceId:launchInstanceId
                    coordinator:coordinator
                      faultHook:faultHook
        projectDetachValidator:nil];
}

- (instancetype)initWithRootURL:(NSURL *)rootURL
                      sessionURL:(NSURL *)sessionURL
                launchInstanceId:(NSString *)launchInstanceId
                      coordinator:(DSHSessionWorkspaceCoordinator *)coordinator
                        faultHook:(DSHSessionSnapshotStoreFaultHook)faultHook
          projectDetachValidator:
              (DSHWorkspaceClearanceProjectDetachValidator)projectDetachValidator {
  if (![rootURL isKindOfClass:NSURL.class] || !rootURL.isFileURL ||
      ![sessionURL isKindOfClass:NSURL.class] || !sessionURL.isFileURL ||
      rootURL.path.length == 0 || sessionURL.path.length == 0) {
    return nil;
  }
  NSString *rootPath = rootURL.path.stringByStandardizingPath;
  // Standardize the session file's PARENT, not the file path itself, and
  // derive the file path from it. `stringByStandardizingPath` drops a leading
  // "/private" only when the path exists; on a physical device the app
  // container is spelled "/private/var/...", so standardizing the root (which
  // exists) and a not-yet-written sessions.json independently yields two
  // spellings of the same directory and the containment check below fails.
  // The parent directory exists exactly when the root does, so both sides
  // standardize the same way.
  NSString *sessionParentPath =
      sessionURL.URLByDeletingLastPathComponent.path.stringByStandardizingPath;
  NSString *normalizedRootName = [NSURL fileURLWithPath:rootPath
                                          isDirectory:YES].lastPathComponent;
  NSString *normalizedSessionName = [NSURL fileURLWithPath:sessionURL.path
                                             isDirectory:NO].lastPathComponent;
  NSString *sessionPath =
      [sessionParentPath stringByAppendingPathComponent:normalizedSessionName];
  if (![sessionParentPath isEqualToString:rootPath] ||
      ![sessionPath hasPrefix:[rootPath stringByAppendingString:@"/"]] ||
      normalizedRootName.length == 0 || [normalizedRootName isEqual:@"."] ||
      [normalizedRootName isEqual:@".."] || normalizedSessionName.length == 0 ||
      [normalizedSessionName isEqual:@"."] || [normalizedSessionName isEqual:@".."] ||
      [normalizedSessionName rangeOfString:@"/"].location != NSNotFound) {
    return nil;
  }
  self = [super init];
  if (self != nil) {
    _rootURL = [NSURL fileURLWithPath:rootPath isDirectory:YES];
    _sessionURL = [NSURL fileURLWithPath:sessionPath isDirectory:NO];
    NSString *candidate = launchInstanceId ?: DSHSessionSnapshotStoreLaunchInstanceId();
    if (launchInstanceId != nil && !DSHSessionCanonicalUUID(candidate)) {
      return nil;
    }
    _launchInstanceId = [candidate copy];
    _coordinator = coordinator ?: [DSHSessionWorkspaceCoordinator sharedCoordinator];
    _clearanceStore = [[DSHWorkspaceClearanceStore alloc]
        initWithPrivateRootURL:_rootURL
                    coordinator:_coordinator
                          clock:nil
             identifierGenerator:nil
                      faultHook:nil
         projectDetachValidator:projectDetachValidator];
    _clearanceWorkspaceAccess = [[DSHLocalWorkspaceAccess alloc]
        initWithPrivateRootURL:_rootURL
                         clock:^NSDate * { return NSDate.date; }
                 UUIDGenerator:^NSString * {
                   return NSUUID.UUID.UUIDString.lowercaseString;
                 }
                legacyResolver:^BOOL(__unused NSString *projectId,
                                      NSDictionary **evidence,
                                      NSError **innerError) {
                  if (evidence != nil) *evidence = nil;
                  if (innerError != nil) {
                    *innerError = [NSError errorWithDomain:
                        DSHLocalWorkspaceAccessErrorDomain
                                                       code:
                        DSHLocalWorkspaceAccessErrorUnavailable
                                                   userInfo:@{}];
                  }
                  return NO;
                }
                     faultHook:nil];
    _faultHook = [faultHook copy];
    _rootDescriptor = -1;
    _parentDescriptor = -1;
    _rootName = [normalizedRootName copy];
    _sessionFilename = [normalizedSessionName copy];
  }
  return self;
}

- (void)dealloc {
  if (_rootDescriptor >= 0) close(_rootDescriptor);
  if (_parentDescriptor >= 0) close(_parentDescriptor);
}

- (BOOL)requiresSessionResourceMetadata {
#if TARGET_OS_OSX || TARGET_OS_SIMULATOR
  return NO;
#else
  return YES;
#endif
}

- (id)sessionProtectionPolicyValue {
  return NSFileProtectionCompleteUntilFirstUserAuthentication;
}

- (NSFileManager *)sessionFileManager {
  return NSFileManager.defaultManager;
}

- (BOOL)setSessionProtectionValue:(id)value
                            atURL:(NSURL *)url
                            error:(NSError **)error {
  // This also hardens Application Support itself. Use the file-attribute
  // setter for both directories and files, matching the workspace stores;
  // Read back the same NSFileProtectionKey attribute for each kind.
  return [[self sessionFileManager] setAttributes:@{ NSFileProtectionKey : value }
                                    ofItemAtPath:url.path
                                           error:error];
}

- (BOOL)setSessionBackupExcluded:(BOOL)excluded
                           atURL:(NSURL *)url
                           error:(NSError **)error {
  return [url setResourceValue:@(excluded)
                         forKey:NSURLIsExcludedFromBackupKey
                          error:error];
}

- (BOOL)getSessionProtectionAtURL:(NSURL *)url
                            value:(id *)value
                            error:(NSError **)error {
  // Read the actual attributes afresh instead of a cached NSURL resource
  // value. An absent class still fails the caller's exact-policy check.
  if (value != nullptr) *value = nil;
  NSDictionary *attributes = [[self sessionFileManager]
      attributesOfItemAtPath:url.path error:error];
  if (attributes == nil) return NO;
  if (value != nullptr) *value = attributes[NSFileProtectionKey];
  return YES;
}

- (BOOL)getSessionBackupExcludedAtURL:(NSURL *)url
                                value:(NSNumber **)value
                                error:(NSError **)error {
  return [url getResourceValue:value
                        forKey:NSURLIsExcludedFromBackupKey
                         error:error];
}

- (BOOL)setErrorForPinnedPathCheck:(DSHSessionPinnedPathCheck)check
                             error:(NSError **)error {
  switch (check) {
    case DSHSessionPinnedPathCheckOK:
      return YES;
    case DSHSessionPinnedPathCheckStorage:
      return DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
    case DSHSessionPinnedPathCheckProtection:
      return DSHSessionSetError(error, DSHSessionSnapshotStoreErrorProtection);
    case DSHSessionPinnedPathCheckConflict:
      return DSHSessionSetError(error, DSHSessionSnapshotStoreErrorConflict);
  }
}

- (BOOL)validatePinnedDescriptor:(int)descriptor
                           atURL:(NSURL *)url
                       directory:(BOOL)directory
                   excludeBackup:(BOOL)excludeBackup
                 requireMetadata:(BOOL)requireMetadata
                           error:(NSError **)error {
  mode_t requiredMode = directory ? 0700 : 0600;
  DSHSessionPinnedPathCheck check = DSHSessionCheckPinnedPath(
      descriptor, url, directory, requiredMode, nullptr, nullptr);
  if (![self setErrorForPinnedPathCheck:check error:error]) return NO;
  if (!requireMetadata || ![self requiresSessionResourceMetadata]) return YES;

  // An item created by an earlier build, or by a path that never applied the
  // policy, carries a different (or absent) protection class and backup flag.
  // Re-apply the required metadata in place once and read it back, the way
  // the workspace store migrates a legacy class, instead of refusing the
  // store forever. The pinned-path check below re-proves identity, so the
  // repair cannot be redirected to another item.
  NSError *readError = nil;
  id protection = nil;
  BOOL protectionRead =
      [self getSessionProtectionAtURL:url value:&protection error:&readError];
  if (protectionRead && ![protection isEqual:[self sessionProtectionPolicyValue]]) {
    readError = nil;
    protection = nil;
    protectionRead =
        [self setSessionProtectionValue:[self sessionProtectionPolicyValue]
                                  atURL:url
                                  error:&readError] &&
        [self getSessionProtectionAtURL:url value:&protection error:&readError];
  }
  if (!protectionRead) {
    if (readError != nil) {
      return DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
    }
    return DSHSessionSetError(error, DSHSessionSnapshotStoreErrorProtection);
  }
  if (![protection isEqual:[self sessionProtectionPolicyValue]]) {
    return DSHSessionSetError(error, DSHSessionSnapshotStoreErrorProtection);
  }
  check = DSHSessionCheckPinnedPath(descriptor, url, directory, requiredMode,
                                    nullptr, nullptr);
  if (![self setErrorForPinnedPathCheck:check error:error]) return NO;
  NSNumber *excluded = nil;
  readError = nil;
  BOOL excludedRead =
      [self getSessionBackupExcludedAtURL:url value:&excluded error:&readError];
  if (excludedRead && (![excluded isKindOfClass:NSNumber.class] ||
                       excluded.boolValue != excludeBackup)) {
    readError = nil;
    excluded = nil;
    excludedRead =
        [self setSessionBackupExcluded:excludeBackup atURL:url error:&readError] &&
        [self getSessionBackupExcludedAtURL:url value:&excluded error:&readError];
  }
  if (!excludedRead) {
    if (readError != nil) {
      return DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
    }
    return DSHSessionSetError(error, DSHSessionSnapshotStoreErrorProtection);
  }
  if (![excluded isKindOfClass:NSNumber.class] ||
      excluded.boolValue != excludeBackup) {
    return DSHSessionSetError(error, DSHSessionSnapshotStoreErrorProtection);
  }
  check = DSHSessionCheckPinnedPath(descriptor, url, directory, requiredMode,
                                    nullptr, nullptr);
  return [self setErrorForPinnedPathCheck:check error:error];
}

- (BOOL)hardenPinnedDescriptor:(int)descriptor
                         atURL:(NSURL *)url
                     directory:(BOOL)directory
                 excludeBackup:(BOOL)excludeBackup
                         error:(NSError **)error {
  if (descriptor < 0 || ![url isKindOfClass:NSURL.class] || !url.isFileURL) {
    return DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
  }
  struct stat descriptorBefore = {};
  struct stat pathBefore = {};
  if (fstat(descriptor, &descriptorBefore) != 0 ||
      lstat(url.fileSystemRepresentation, &pathBefore) != 0) {
    return DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
  }
  BOOL descriptorTypeOK = directory ? S_ISDIR(descriptorBefore.st_mode)
                                    : S_ISREG(descriptorBefore.st_mode);
  BOOL pathTypeOK = directory ? S_ISDIR(pathBefore.st_mode)
                              : S_ISREG(pathBefore.st_mode);
  if (!descriptorTypeOK || !pathTypeOK || S_ISLNK(pathBefore.st_mode) ||
      (!directory &&
       (descriptorBefore.st_nlink != 1 || pathBefore.st_nlink != 1))) {
    return DSHSessionSetError(error, DSHSessionSnapshotStoreErrorProtection);
  }
  if (!DSHSessionSamePinnedIdentity(&descriptorBefore, &pathBefore)) {
    return DSHSessionSetError(error, DSHSessionSnapshotStoreErrorConflict);
  }
  mode_t requiredMode = directory ? 0700 : 0600;
  if (fchmod(descriptor, requiredMode) != 0) {
    return DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
  }
  struct stat hardened = {};
  DSHSessionPinnedPathCheck check = DSHSessionCheckPinnedPath(
      descriptor, url, directory, requiredMode, nullptr, &hardened);
  if (![self setErrorForPinnedPathCheck:check error:error]) return NO;

  if ([self requiresSessionResourceMetadata]) {
    check = DSHSessionCheckPinnedPath(descriptor, url, directory, requiredMode,
                                      &hardened, nullptr);
    if (![self setErrorForPinnedPathCheck:check error:error]) return NO;
    NSError *metadataError = nil;
    if (![self setSessionProtectionValue:[self sessionProtectionPolicyValue]
                                   atURL:url
                                   error:&metadataError]) {
      return DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
    }
    check = DSHSessionCheckPinnedPath(descriptor, url, directory, requiredMode,
                                      &hardened, nullptr);
    if (![self setErrorForPinnedPathCheck:check error:error]) return NO;

    check = DSHSessionCheckPinnedPath(descriptor, url, directory, requiredMode,
                                      &hardened, nullptr);
    if (![self setErrorForPinnedPathCheck:check error:error]) return NO;
    metadataError = nil;
    if (![self setSessionBackupExcluded:excludeBackup
                                  atURL:url
                                  error:&metadataError]) {
      return DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
    }
    check = DSHSessionCheckPinnedPath(descriptor, url, directory, requiredMode,
                                      &hardened, nullptr);
    if (![self setErrorForPinnedPathCheck:check error:error]) return NO;
    if (![self validatePinnedDescriptor:descriptor
                                  atURL:url
                              directory:directory
                          excludeBackup:excludeBackup
                        requireMetadata:YES
                                  error:error]) {
      return NO;
    }
  }
  if (fsync(descriptor) != 0) {
    return DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
  }
  check = DSHSessionCheckPinnedPath(descriptor, url, directory, requiredMode,
                                    &hardened, nullptr);
  if (![self setErrorForPinnedPathCheck:check error:error]) return NO;
  return [self validatePinnedDescriptor:descriptor
                                  atURL:url
                              directory:directory
                          excludeBackup:excludeBackup
                        requireMetadata:YES
                                  error:error];
}

- (BOOL)ensurePrivateRoot:(NSError **)error {
  if (self.rootDescriptor >= 0) {
    struct stat pinned = {};
    struct stat parent = {};
    NSURL *parentURL = self.rootURL.URLByDeletingLastPathComponent;
    int visibleParentDescriptor = open(
        parentURL.fileSystemRepresentation,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    struct stat visibleParent = {};
    BOOL parentPathPinned = visibleParentDescriptor >= 0 &&
        fstat(visibleParentDescriptor, &visibleParent) == 0;
    if (visibleParentDescriptor >= 0) close(visibleParentDescriptor);
    if (!parentPathPinned || fstat(self.rootDescriptor, &pinned) != 0 ||
        fstat(self.parentDescriptor, &parent) != 0) {
      return DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
    }
    if (!S_ISDIR(pinned.st_mode) || S_ISLNK(pinned.st_mode)) {
      return DSHSessionSetError(error, DSHSessionSnapshotStoreErrorProtection);
    }
    if (pinned.st_dev != self.rootDevice || pinned.st_ino != self.rootInode ||
        visibleParent.st_dev != self.parentDevice ||
        visibleParent.st_ino != self.parentInode ||
        parent.st_dev != self.parentDevice || parent.st_ino != self.parentInode) {
      return DSHSessionSetError(error, DSHSessionSnapshotStoreErrorConflict);
    }
    return [self hardenPinnedDescriptor:self.rootDescriptor
                                  atURL:self.rootURL
                              directory:YES
                          excludeBackup:NO
                                  error:error];
  }

  NSURL *parentURL = self.rootURL.URLByDeletingLastPathComponent;
  int parent = open(parentURL.fileSystemRepresentation,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (parent < 0) {
    return DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
  }
  struct stat parentState = {};
  if (fstat(parent, &parentState) != 0) {
    close(parent);
    return DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
  }
  int descriptor = openat(parent, self.rootName.fileSystemRepresentation,
                          O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (descriptor < 0 && errno == ENOENT) {
    if (mkdirat(parent, self.rootName.fileSystemRepresentation, 0700) != 0 &&
        errno != EEXIST) {
      close(parent);
      return DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
    }
    if (fsync(parent) != 0) {
      close(parent);
      return DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
    }
    descriptor = openat(parent, self.rootName.fileSystemRepresentation,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  }
  if (descriptor < 0) {
    close(parent);
    return DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
  }
  struct stat state = {};
  if (fstat(descriptor, &state) != 0) {
    close(descriptor);
    close(parent);
    return DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
  }
  if (!S_ISDIR(state.st_mode) || S_ISLNK(state.st_mode)) {
    close(descriptor);
    close(parent);
    return DSHSessionSetError(error, DSHSessionSnapshotStoreErrorProtection);
  }
  struct stat visible = {};
  if (fstatat(parent, self.rootName.fileSystemRepresentation, &visible,
              AT_SYMLINK_NOFOLLOW) != 0 || visible.st_dev != state.st_dev ||
      visible.st_ino != state.st_ino) {
    close(descriptor);
    close(parent);
    return DSHSessionSetError(error, DSHSessionSnapshotStoreErrorConflict);
  }
  if (![self hardenPinnedDescriptor:descriptor
                              atURL:self.rootURL
                          directory:YES
                      excludeBackup:NO
                              error:error]) {
    close(descriptor);
    close(parent);
    return NO;
  }
  self.parentDescriptor = parent;
  self.parentDevice = parentState.st_dev;
  self.parentInode = parentState.st_ino;
  self.rootDescriptor = descriptor;
  self.rootDevice = state.st_dev;
  self.rootInode = state.st_ino;
  return YES;
}

- (int)acquireCASLock:(NSError **)error {
  NSString *lockName = @".sessions.cas-lock";
  int descriptor = openat(self.rootDescriptor,
                          lockName.fileSystemRepresentation,
                          O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (descriptor < 0) {
    DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
    return -1;
  }
  struct stat state = {};
  if (fstat(descriptor, &state) != 0) {
    close(descriptor);
    DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
    return -1;
  }
  if (!S_ISREG(state.st_mode) || state.st_nlink != 1) {
    close(descriptor);
    DSHSessionSetError(error, DSHSessionSnapshotStoreErrorProtection);
    return -1;
  }
  int lockResult = 0;
  do {
    lockResult = flock(descriptor, LOCK_EX);
  } while (lockResult != 0 && errno == EINTR);
  if (lockResult != 0) {
    close(descriptor);
    DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
    return -1;
  }
  NSURL *lockURL = [self.rootURL URLByAppendingPathComponent:lockName
                                                isDirectory:NO];
  if (![self hardenPinnedDescriptor:descriptor
                              atURL:lockURL
                          directory:NO
                      excludeBackup:YES
                              error:error]) {
    close(descriptor);
    return -1;
  }
  return descriptor;
}

- (BOOL)validateStoredFileDescriptor:(int)descriptor
                               atURL:(NSURL *)url
                      requireMetadata:(BOOL)requireMetadata
                                error:(NSError **)error {
  return [self validatePinnedDescriptor:descriptor
                                  atURL:url
                              directory:NO
                          excludeBackup:YES
                        requireMetadata:requireMetadata
                                  error:error];
}

- (NSData *)readStoredBytes:(BOOL *)missing
                       state:(struct stat *)identity
                       error:(NSError **)error {
  return [self readStoredBytesForFilename:self.sessionFilename
                                  missing:missing
                                    state:identity
                                    error:error];
}

- (NSData *)readStoredBytesForFilename:(NSString *)filename
                               missing:(BOOL *)missing
                                 state:(struct stat *)identity
                                 error:(NSError **)error {
  if (missing != nullptr) *missing = NO;
  if (![self ensurePrivateRoot:error]) return nil;
  int descriptor = openat(self.rootDescriptor, filename.fileSystemRepresentation,
                          O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (descriptor < 0) {
    if (errno == ENOENT) {
      if (missing != nullptr) *missing = YES;
      return nil;
    }
    DSHSessionSetError(error, errno == ELOOP
                               ? DSHSessionSnapshotStoreErrorProtection
                               : DSHSessionSnapshotStoreErrorStorage);
    return nil;
  }
  struct stat before = {};
  NSURL *storedURL = [self.rootURL URLByAppendingPathComponent:filename
                                                  isDirectory:NO];
  if (fstat(descriptor, &before) != 0) {
    close(descriptor);
    DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
    return nil;
  }
  BOOL descriptorValid = [self validateStoredFileDescriptor:descriptor
                                                      atURL:storedURL
                                            requireMetadata:NO
                                                      error:error];
  BOOL sizeValid = descriptorValid && before.st_size > 0 &&
      (uint64_t)before.st_size <= DSHSessionSnapshotMaximumBytes;
  if (!sizeValid) {
    if (descriptorValid && before.st_size == 0) {
      DSHSessionSetError(error, DSHSessionSnapshotStoreErrorCorrupt);
    } else if (descriptorValid && before.st_size > 0 &&
               (uint64_t)before.st_size > DSHSessionSnapshotMaximumBytes) {
      DSHSessionSetError(error, DSHSessionSnapshotStoreErrorBounds);
    }
    close(descriptor);
    return nil;
  }
  NSMutableData *data = [NSMutableData dataWithCapacity:(NSUInteger)before.st_size];
  uint8_t buffer[16384];
  while (data.length < (NSUInteger)before.st_size) {
    ssize_t count = read(descriptor, buffer,
                         MIN(sizeof(buffer),
                             (NSUInteger)before.st_size - data.length));
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) {
      close(descriptor);
      DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
      return nil;
    }
    [data appendBytes:buffer length:(NSUInteger)count];
  }
  struct stat after = {};
  struct stat visible = {};
  BOOL stable = fstat(descriptor, &after) == 0 &&
      fstatat(self.rootDescriptor, filename.fileSystemRepresentation,
              &visible, AT_SYMLINK_NOFOLLOW) == 0 &&
      after.st_dev == before.st_dev && after.st_ino == before.st_ino &&
      after.st_size == before.st_size && visible.st_dev == before.st_dev &&
      visible.st_ino == before.st_ino && visible.st_size == before.st_size;
  close(descriptor);
  if (!stable) {
    DSHSessionSetError(error, DSHSessionSnapshotStoreErrorConflict);
    return nil;
  }
  if (identity != nullptr) *identity = before;
  return [data copy];
}

- (DSHSessionTombstoneState *)readTombstoneStateWithError:(NSError **)error {
  DSHSessionTombstoneState *state = [[DSHSessionTombstoneState alloc] init];
  BOOL missing = NO;
  struct stat identity = {};
  NSError *readError = nil;
  NSData *raw = [self readStoredBytesForFilename:DSHSessionSnapshotTombstoneFilename
                                          missing:&missing
                                            state:&identity
                                            error:&readError];
  if (missing) {
    state.missing = YES;
    state.valid = YES;
    state.generation = 0;
    state.operationIds = [NSSet set];
    return state;
  }
  if (raw == nil) {
    state.valid = NO;
    if (error != nullptr) *error = readError;
    return state;
  }
  state.missing = NO;
  state.device = identity.st_dev;
  state.inode = identity.st_ino;
  state.fileSize = identity.st_size;
  state.rawBytes = raw;
  if (raw.length > DSHSessionSnapshotMaximumTombstoneBytes) {
    state.valid = NO;
    if (error != nullptr) *error = DSHSessionStoreError(
        DSHSessionSnapshotStoreErrorBounds);
    return state;
  }
  NSError *parseError = nil;
  NSDictionary *verdict = DSHSessionCoreReduce(
      @"tombstones", nil, raw, @{}, DSHSessionSnapshotStoreErrorCorrupt, &parseError);
  NSUInteger generation = 0;
  NSSet<NSString *> *operationIds = nil;
  if (verdict == nil || ![verdict[@"generation"] isKindOfClass:NSNumber.class] ||
      ![verdict[@"operation_ids"] isKindOfClass:NSArray.class]) {
    state.valid = NO;
    if (error != nullptr) *error = parseError ?: DSHSessionStoreError(
        DSHSessionSnapshotStoreErrorCorrupt);
    return state;
  }
  generation = [verdict[@"generation"] unsignedIntegerValue];
  operationIds = [NSSet setWithArray:verdict[@"operation_ids"]];
  NSError *protectionError = nil;
  if (![self validateProtectedFileWithIdentity:&identity
                                        filename:DSHSessionSnapshotTombstoneFilename
                                           error:&protectionError]) {
    state.valid = NO;
    if (error != nullptr) *error = protectionError;
    return state;
  }
  state.missing = NO;
  state.valid = YES;
  state.device = identity.st_dev;
  state.inode = identity.st_ino;
  state.fileSize = identity.st_size;
  state.rawBytes = raw;
  state.generation = generation;
  state.operationIds = operationIds ?: [NSSet set];
  return state;
}

- (BOOL)hardenLegacyFileWithIdentity:(const struct stat *)expected
                                error:(NSError **)error {
  int descriptor = openat(self.rootDescriptor,
                          self.sessionFilename.fileSystemRepresentation,
                          O_RDWR | O_CLOEXEC | O_NOFOLLOW);
  if (descriptor < 0) {
    return DSHSessionSetError(error, DSHSessionSnapshotStoreErrorConflict);
  }
  struct stat before = {};
  BOOL same = fstat(descriptor, &before) == 0 &&
      expected != nullptr && before.st_dev == expected->st_dev &&
      before.st_ino == expected->st_ino && before.st_size == expected->st_size;
  if (!same) {
    close(descriptor);
    return DSHSessionSetError(error, DSHSessionSnapshotStoreErrorConflict);
  }
  BOOL ok = [self hardenPinnedDescriptor:descriptor
                                   atURL:self.sessionURL
                               directory:NO
                           excludeBackup:YES
                                   error:error];
  if (ok && fsync(self.rootDescriptor) != 0) {
    ok = DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
  }
  close(descriptor);
  return ok;
}

- (BOOL)validateProtectedFileWithIdentity:(const struct stat *)expected
                                     error:(NSError **)error {
  return [self validateProtectedFileWithIdentity:expected
                                         filename:self.sessionFilename
                                            error:error];
}

- (BOOL)validateProtectedFileWithIdentity:(const struct stat *)expected
                                  filename:(NSString *)filename
                                     error:(NSError **)error {
  if (expected == nullptr || ![filename isKindOfClass:NSString.class] ||
      filename.length == 0 || [filename containsString:@"/"]) {
    return DSHSessionSetError(error, DSHSessionSnapshotStoreErrorInvalidArgument);
  }
  int descriptor = openat(self.rootDescriptor,
                          filename.fileSystemRepresentation,
                          O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (descriptor < 0) {
    return DSHSessionSetError(error, DSHSessionSnapshotStoreErrorConflict);
  }
  struct stat state = {};
  struct stat visible = {};
  NSURL *storedURL = [self.rootURL URLByAppendingPathComponent:filename
                                                  isDirectory:NO];
  BOOL ok = fstat(descriptor, &state) == 0 &&
      state.st_dev == expected->st_dev && state.st_ino == expected->st_ino &&
      state.st_size == expected->st_size &&
      [self validateStoredFileDescriptor:descriptor
                                   atURL:storedURL
                         requireMetadata:YES
                                   error:error] &&
      fstatat(self.rootDescriptor, filename.fileSystemRepresentation,
              &visible, AT_SYMLINK_NOFOLLOW) == 0 &&
      visible.st_dev == state.st_dev && visible.st_ino == state.st_ino &&
      visible.st_size == state.st_size;
  close(descriptor);
  if (!ok && (error == nullptr || *error == nil)) {
    DSHSessionSetError(error, DSHSessionSnapshotStoreErrorConflict);
  }
  return ok;
}

- (DSHSessionLoadedState *)readStateWithError:(NSError **)error {
  BOOL missing = NO;
  struct stat identity = {};
  NSData *raw = [self readStoredBytes:&missing state:&identity error:error];
  if (missing) {
    DSHSessionLoadedState *state = [[DSHSessionLoadedState alloc] init];
    state.missing = YES;
    state.authority = DSHSessionMissingAuthority();
    return state;
  }
  if (raw == nil) return nil;
  DSHSessionValidatedEnvelope *remembered = DSHSessionValidatedEnvelopeCached(raw);
  // A file the store has not validated in this process goes through the
  // core: strict parse, v2/v3 envelope rules, the session validators and the
  // digest checks. The Foundation decode of the same bytes is the tree the
  // store keeps; every field read from it below was accepted by the core.
  NSDictionary *envelope = remembered != nil ? remembered.envelope : nil;
  NSDictionary *verdict = nil;
  if (remembered == nil) {
    NSError *validationError = nil;
    envelope = DSHSessionCoreDecodedObject(raw);
    verdict = DSHSessionCoreReduce(
        @"envelope", nil, raw, DSHSessionCoreEnvironment(envelope),
        DSHSessionSnapshotStoreErrorCorrupt, &validationError);
    if (verdict == nil || envelope == nil) {
      if (error != nullptr) *error = validationError ?: DSHSessionStoreError(
          DSHSessionSnapshotStoreErrorCorrupt);
      return nil;
    }
  }
  if (remembered == nil && [verdict[@"kind"] isEqual:@2]) {
    NSDictionary *session = envelope[@"session"];
    NSString *legacyDigest = verdict[@"legacy_bytes_sha256"];
    if (![session isKindOfClass:NSDictionary.class] ||
        ![legacyDigest isKindOfClass:NSString.class]) {
      DSHSessionSetError(error, DSHSessionSnapshotStoreErrorCorrupt);
      return nil;
    }
    DSHSessionLoadedState *state = [[DSHSessionLoadedState alloc] init];
    state.legacy = YES;
    state.hasFile = YES;
    state.device = identity.st_dev;
    state.inode = identity.st_ino;
    state.fileSize = identity.st_size;
    state.rawBytes = raw;
    state.session = session;
    state.legacyBytesDigest = legacyDigest;
    state.writerLaunchInstanceId = envelope[@"writer_launch_instance_id"];
    NSError *hardenError = nil;
    BOOL hardened =
        [self hardenLegacyFileWithIdentity:&identity error:&hardenError];
    if (!hardened) {
      if (error != nullptr) *error = hardenError;
      return nil;
    }
    state.authority = DSHSessionLegacyAuthority(legacyDigest);
    return state;
  }
  if (remembered != nil || [verdict[@"kind"] isEqual:@3]) {
    NSDictionary *session = nil;
    NSString *digest = nil;
    NSUInteger generation = 0;
    NSArray *commits = nil;
    if (remembered != nil) {
      session = remembered.session;
      digest = remembered.digest;
      generation = remembered.generation;
      commits = remembered.commits;
    } else {
      session = envelope[@"session"];
      digest = verdict[@"session_sha256"];
      commits = envelope[@"recent_commits"];
      if (![session isKindOfClass:NSDictionary.class] ||
          ![digest isKindOfClass:NSString.class] ||
          ![verdict[@"generation"] isKindOfClass:NSNumber.class] ||
          ![commits isKindOfClass:NSArray.class]) {
        DSHSessionSetError(error, DSHSessionSnapshotStoreErrorCorrupt);
        return nil;
      }
      generation = [verdict[@"generation"] unsignedIntegerValue];
      DSHSessionValidatedEnvelope *entry = [[DSHSessionValidatedEnvelope alloc] init];
      entry.bytes = raw;
      entry.envelope = envelope;
      entry.session = session;
      entry.digest = digest;
      entry.generation = generation;
      entry.commits = commits;
      DSHSessionValidatedEnvelopeRemember(entry);
    }
    DSHSessionLoadedState *state = [[DSHSessionLoadedState alloc] init];
    NSError *protectionError = nil;
    if (![self validateProtectedFileWithIdentity:&identity error:&protectionError]) {
      if (error != nullptr) *error = protectionError;
      return nil;
    }
    state.hasFile = YES;
    state.device = identity.st_dev;
    state.inode = identity.st_ino;
    state.fileSize = identity.st_size;
    state.rawBytes = raw;
    state.session = session;
    state.sessionDigest = digest;
    state.writerLaunchInstanceId = envelope[@"writer_launch_instance_id"];
    state.generation = generation;
    state.recentCommits = commits;
    state.authority = DSHSessionPresentAuthority(generation, digest);
    NSError *tombstoneError = nil;
    DSHSessionTombstoneState *tombstones =
        [self readTombstoneStateWithError:&tombstoneError];
    state.tombstones = DSHSessionCoreTombstoneView(tombstones);
    return state;
  }
  DSHSessionSetError(error, DSHSessionSnapshotStoreErrorCorrupt);
  return nil;
}

- (NSDictionary *)loadResultForState:(DSHSessionLoadedState *)state
                                error:(NSError **)error {
  if (state.missing) {
    return DSHSessionLoadMissingResult(self.launchInstanceId);
  }
  NSData *sessionData = DSHSessionCanonicalJSON(
      state.session, error, DSHSessionSnapshotStoreErrorCorrupt);
  if (sessionData == nil) return nil;
  NSString *sessionJSON = [[NSString alloc] initWithData:sessionData
                                                 encoding:NSUTF8StringEncoding];
  if (sessionJSON == nil) {
    DSHSessionSetError(error, DSHSessionSnapshotStoreErrorCorrupt);
    return nil;
  }
  if (state.legacy) {
    return @{
      @"schema_version" : @1,
      @"status" : @"legacy_present",
      @"legacy" : DSHSessionLegacyRef(state.legacyBytesDigest),
      @"session_json" : sessionJSON,
      @"writer_launch_instance_id" : state.writerLaunchInstanceId ?: NSNull.null,
      @"current_launch_instance_id" : self.launchInstanceId,
    };
  }
  return @{
    @"schema_version" : @1,
    @"status" : @"present",
    @"snapshot" : DSHSessionSnapshotRef(state.generation, state.sessionDigest),
    @"session_json" : sessionJSON,
    @"writer_launch_instance_id" : state.writerLaunchInstanceId ?: NSNull.null,
    @"current_launch_instance_id" : self.launchInstanceId,
  };
}

- (NSDictionary *)authorityResultForState:(DSHSessionLoadedState *)state {
  return state.authority ?: DSHSessionMissingAuthority();
}

- (BOOL)targetMatchesExpectedState:(DSHSessionLoadedState *)expected
                              error:(NSError **)error {
  return [self targetMatchesExpectedState:expected
                                 filename:self.sessionFilename
                                    error:error];
}

- (BOOL)targetMatchesExpectedState:(DSHSessionLoadedState *)expected
                           filename:(NSString *)filename
                              error:(NSError **)error {
  if (expected == nil || ![filename isKindOfClass:NSString.class] ||
      filename.length == 0 || [filename containsString:@"/"]) {
    return DSHSessionSetError(error, DSHSessionSnapshotStoreErrorInvalidArgument);
  }
  struct stat target = {};
  if (fstatat(self.rootDescriptor, filename.fileSystemRepresentation,
              &target, AT_SYMLINK_NOFOLLOW) != 0) {
    if (errno == ENOENT && expected.missing) return YES;
    return DSHSessionSetError(error, DSHSessionSnapshotStoreErrorConflict);
  }
  if (expected.missing || !expected.hasFile || !S_ISREG(target.st_mode) ||
      target.st_nlink != 1 || (target.st_mode & 0777) != 0600 ||
      target.st_dev != expected.device || target.st_ino != expected.inode ||
      target.st_size != expected.fileSize) {
    return DSHSessionSetError(error, DSHSessionSnapshotStoreErrorConflict);
  }
  // Device/inode identity catches replacement, while the byte comparison
  // catches an in-place external writer that preserves both identity and
  // length.  The latter is required for a real CAS boundary because the
  // process-global queue cannot serialize another process.
  if (expected.rawBytes != nil) {
    int descriptor = openat(self.rootDescriptor,
                            filename.fileSystemRepresentation,
                            O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) {
      return DSHSessionSetError(error, DSHSessionSnapshotStoreErrorConflict);
    }
    struct stat opened = {};
    NSURL *storedURL = [self.rootURL URLByAppendingPathComponent:filename
                                                    isDirectory:NO];
    BOOL same = fstat(descriptor, &opened) == 0 &&
        opened.st_dev == expected.device && opened.st_ino == expected.inode &&
        opened.st_size == expected.fileSize &&
        [self validateStoredFileDescriptor:descriptor
                                     atURL:storedURL
                           requireMetadata:YES
                                     error:error];
    NSMutableData *bytes = [NSMutableData dataWithCapacity:
        expected.rawBytes.length];
    uint8_t buffer[16384];
    while (same && bytes.length < expected.rawBytes.length) {
      ssize_t count = read(descriptor, buffer,
                           MIN(sizeof(buffer),
                               expected.rawBytes.length - bytes.length));
      if (count < 0 && errno == EINTR) continue;
      if (count <= 0) {
        same = NO;
        break;
      }
      [bytes appendBytes:buffer length:(NSUInteger)count];
    }
    struct stat visible = {};
    same = same && bytes.length == expected.rawBytes.length &&
        [bytes isEqualToData:expected.rawBytes] &&
        fstat(descriptor, &opened) == 0 &&
        fstatat(self.rootDescriptor, filename.fileSystemRepresentation,
                &visible, AT_SYMLINK_NOFOLLOW) == 0 &&
        opened.st_dev == expected.device && opened.st_ino == expected.inode &&
        opened.st_size == expected.fileSize && visible.st_dev == expected.device &&
        visible.st_ino == expected.inode && visible.st_size == expected.fileSize;
    close(descriptor);
    if (!same) {
      return DSHSessionSetError(error, DSHSessionSnapshotStoreErrorConflict);
    }
  }
  return YES;
}

- (DSHSessionAtomicWriteResult)publishTemporaryFilename:(NSString *)temporaryName
                                               filename:(NSString *)filename
                                          expectedState:(DSHSessionLoadedState *)expected
                                                  error:(NSError **)error {
  if (expected == nil || expected.missing) {
    if (renameatx_np(self.rootDescriptor, temporaryName.fileSystemRepresentation,
                     self.rootDescriptor, filename.fileSystemRepresentation,
                     RENAME_EXCL) == 0) {
      return DSHSessionAtomicWriteCommitted;
    }
    unlinkat(self.rootDescriptor, temporaryName.fileSystemRepresentation, 0);
    DSHSessionSetError(error, errno == EEXIST
                               ? DSHSessionSnapshotStoreErrorConflict
                               : DSHSessionSnapshotStoreErrorStorage);
    return DSHSessionAtomicWriteNoEffect;
  }
  if (expected.rawBytes == nil) {
    DSHSessionSetError(error, DSHSessionSnapshotStoreErrorConflict);
    return DSHSessionAtomicWriteNoEffect;
  }
  struct stat replacementIdentity = {};
  int replacementDescriptor = openat(
      self.rootDescriptor, temporaryName.fileSystemRepresentation,
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  BOOL replacementIdentityValid = replacementDescriptor >= 0 &&
      fstat(replacementDescriptor, &replacementIdentity) == 0;
  if (replacementDescriptor >= 0) close(replacementDescriptor);
  if (!replacementIdentityValid) {
    DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
    return DSHSessionAtomicWriteNoEffect;
  }
  if (renameatx_np(self.rootDescriptor, temporaryName.fileSystemRepresentation,
                   self.rootDescriptor, filename.fileSystemRepresentation,
                   RENAME_SWAP) != 0) {
    unlinkat(self.rootDescriptor, temporaryName.fileSystemRepresentation, 0);
    DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
    return DSHSessionAtomicWriteNoEffect;
  }
  int oldTarget = openat(self.rootDescriptor, temporaryName.fileSystemRepresentation,
                         O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (oldTarget < 0) {
    // The exchange succeeded; leave both inodes recoverable for the next
    // reconciliation rather than unlinking an unknown target.
    DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
    return DSHSessionAtomicWriteUnknown;
  }
  struct stat oldState = {};
  BOOL matches = fstat(oldTarget, &oldState) == 0 &&
      oldState.st_dev == expected.device && oldState.st_ino == expected.inode &&
      oldState.st_size == expected.fileSize && oldState.st_nlink == 1 &&
      (oldState.st_mode & 0777) == 0600;
  NSMutableData *oldBytes = [NSMutableData dataWithCapacity:
      expected.rawBytes.length];
  uint8_t buffer[16384];
  while (matches && oldBytes.length < expected.rawBytes.length) {
    ssize_t count = read(oldTarget, buffer,
                         MIN(sizeof(buffer),
                             expected.rawBytes.length - oldBytes.length));
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) {
      matches = NO;
      break;
    }
    [oldBytes appendBytes:buffer length:(NSUInteger)count];
  }
  struct stat oldAfter = {};
  matches = matches && oldBytes.length == expected.rawBytes.length &&
      [oldBytes isEqualToData:expected.rawBytes] && fstat(oldTarget, &oldAfter) == 0 &&
      oldAfter.st_dev == oldState.st_dev && oldAfter.st_ino == oldState.st_ino &&
      oldAfter.st_size == oldState.st_size;
  close(oldTarget);
  if (matches) {
    if (unlinkat(self.rootDescriptor, temporaryName.fileSystemRepresentation, 0) == 0) {
      return DSHSessionAtomicWriteCommitted;
    }
    DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
    return DSHSessionAtomicWriteUnknown;
  }
  // The target changed after the original read. Atomically exchange back so
  // the changed inode remains authoritative, then remove only our temporary
  // inode after verifying its identity.
  if (renameatx_np(self.rootDescriptor, temporaryName.fileSystemRepresentation,
                   self.rootDescriptor, filename.fileSystemRepresentation,
                   RENAME_SWAP) != 0) {
    DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
    return DSHSessionAtomicWriteUnknown;
  }
  int replacement = openat(self.rootDescriptor,
                           temporaryName.fileSystemRepresentation,
                           O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  struct stat replacementState = {};
  BOOL replacementIsOurs = replacement >= 0 && fstat(replacement, &replacementState) == 0 &&
      replacementState.st_dev == replacementIdentity.st_dev &&
      replacementState.st_ino == replacementIdentity.st_ino;
  if (replacement >= 0) close(replacement);
  if (replacementIsOurs) {
    unlinkat(self.rootDescriptor, temporaryName.fileSystemRepresentation, 0);
  }
  DSHSessionSetError(error, DSHSessionSnapshotStoreErrorConflict);
  return DSHSessionAtomicWriteNoEffect;
}

- (DSHSessionAtomicWriteResult)writeProtectedData:(NSData *)data
                                          filename:(NSString *)filename
                                     expectedState:(DSHSessionLoadedState *)expected
                                             error:(NSError **)error {
  if (![self ensurePrivateRoot:error]) return DSHSessionAtomicWriteNoEffect;
  int lockDescriptor = [self acquireCASLock:error];
  if (lockDescriptor < 0) return DSHSessionAtomicWriteNoEffect;
  @try {
    return [self writeProtectedData:data
                            filename:filename
                       expectedState:expected
                      lockDescriptor:lockDescriptor
                               error:error];
  } @finally {
    close(lockDescriptor);
  }
}

- (DSHSessionAtomicWriteResult)writeProtectedData:(NSData *)data
                                          filename:(NSString *)filename
                                     expectedState:(DSHSessionLoadedState *)expected
                                    lockDescriptor:(int)lockDescriptor
                                             error:(NSError **)error {
  if (![data isKindOfClass:NSData.class] || data.length == 0 ||
      data.length > DSHSessionSnapshotMaximumBytes ||
      lockDescriptor < 0) {
    return DSHSessionAtomicWriteNoEffect;
  }
  if (![self targetMatchesExpectedState:expected filename:filename error:error]) {
    return DSHSessionAtomicWriteNoEffect;
  }
  if (self.faultHook != nil &&
      !self.faultHook(DSHSessionSnapshotStoreFaultPointBeforeWrite)) {
    DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
    return DSHSessionAtomicWriteNoEffect;
  }
  NSString *temporaryName = [NSString stringWithFormat:@".%@.%@.tmp",
      filename, NSUUID.UUID.UUIDString.lowercaseString];
  int descriptor = openat(self.rootDescriptor, temporaryName.fileSystemRepresentation,
                          O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                          0600);
  if (descriptor < 0) {
    DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
    return DSHSessionAtomicWriteNoEffect;
  }
  BOOL ok = YES;
  const uint8_t *bytes = (const uint8_t *)data.bytes;
  NSUInteger offset = 0;
  while (ok && offset < data.length) {
    ssize_t count = write(descriptor, bytes + offset, data.length - offset);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) {
      ok = NO;
      break;
    }
    offset += (NSUInteger)count;
  }
  NSURL *temporaryURL = [self.rootURL URLByAppendingPathComponent:temporaryName
                                                      isDirectory:NO];
  if (ok) {
    ok = [self hardenPinnedDescriptor:descriptor
                                atURL:temporaryURL
                            directory:NO
                        excludeBackup:YES
                                error:error];
  }
  if (close(descriptor) != 0) ok = NO;
  descriptor = -1;
  if (!ok) {
    unlinkat(self.rootDescriptor, temporaryName.fileSystemRepresentation, 0);
    if (error == nullptr || *error == nil) {
      DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
    }
    return DSHSessionAtomicWriteNoEffect;
  }
  if (self.faultHook != nil &&
      !self.faultHook(DSHSessionSnapshotStoreFaultPointAfterWriteBeforeRename)) {
    unlinkat(self.rootDescriptor, temporaryName.fileSystemRepresentation, 0);
    DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
    return DSHSessionAtomicWriteNoEffect;
  }
  if (![self targetMatchesExpectedState:expected filename:filename error:error]) {
    unlinkat(self.rootDescriptor, temporaryName.fileSystemRepresentation, 0);
    return DSHSessionAtomicWriteNoEffect;
  }
  DSHSessionAtomicWriteResult publishResult =
      [self publishTemporaryFilename:temporaryName
                             filename:filename
                        expectedState:expected
                                error:error];
  if (publishResult != DSHSessionAtomicWriteCommitted) {
    return publishResult;
  }
  int published = openat(self.rootDescriptor, filename.fileSystemRepresentation,
                         O_RDWR | O_CLOEXEC | O_NOFOLLOW);
  if (published < 0) {
    DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
    return DSHSessionAtomicWriteUnknown;
  }
  struct stat publishedBefore = {};
  struct stat visibleBefore = {};
  BOOL identity = fstat(published, &publishedBefore) == 0 &&
      fstatat(self.rootDescriptor, filename.fileSystemRepresentation,
              &visibleBefore, AT_SYMLINK_NOFOLLOW) == 0 &&
      publishedBefore.st_dev == visibleBefore.st_dev &&
      publishedBefore.st_ino == visibleBefore.st_ino &&
      publishedBefore.st_size == visibleBefore.st_size &&
      publishedBefore.st_size == (off_t)data.length;
  if (!identity) {
    close(published);
    DSHSessionSetError(error, DSHSessionSnapshotStoreErrorConflict);
    return DSHSessionAtomicWriteUnknown;
  }
  NSURL *publishedURL = [self.rootURL URLByAppendingPathComponent:filename
                                                     isDirectory:NO];
  if (![self hardenPinnedDescriptor:published
                              atURL:publishedURL
                          directory:NO
                      excludeBackup:YES
                              error:error]) {
    close(published);
    return DSHSessionAtomicWriteUnknown;
  }
  if (self.faultHook != nil &&
      !self.faultHook(DSHSessionSnapshotStoreFaultPointAfterRename)) {
    close(published);
    DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
    return DSHSessionAtomicWriteUnknown;
  }
  if (fsync(published) != 0 || fsync(self.rootDescriptor) != 0) {
    close(published);
    DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
    return DSHSessionAtomicWriteUnknown;
  }
  if (self.faultHook != nil &&
      !self.faultHook(DSHSessionSnapshotStoreFaultPointAfterRenameBeforeVerify)) {
    close(published);
    DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
    return DSHSessionAtomicWriteUnknown;
  }
  struct stat finalState = {};
  struct stat finalVisible = {};
  BOOL verified = fstat(published, &finalState) == 0 &&
      [self validateStoredFileDescriptor:published
                                   atURL:publishedURL
                         requireMetadata:YES
                                   error:error] &&
      fstatat(self.rootDescriptor, filename.fileSystemRepresentation,
              &finalVisible, AT_SYMLINK_NOFOLLOW) == 0 &&
      finalVisible.st_dev == finalState.st_dev &&
      finalVisible.st_ino == finalState.st_ino &&
      finalVisible.st_size == finalState.st_size &&
      finalState.st_size == (off_t)data.length;
  close(published);
  if (!verified) return DSHSessionAtomicWriteUnknown;
  return DSHSessionAtomicWriteCommitted;
}

- (DSHSessionAtomicWriteResult)writeEnvelopeData:(NSData *)data
                                     expectedState:(DSHSessionLoadedState *)expected
                                             error:(NSError **)error {
  if (![self ensurePrivateRoot:error]) return DSHSessionAtomicWriteNoEffect;
  int lockDescriptor = [self acquireCASLock:error];
  if (lockDescriptor < 0) return DSHSessionAtomicWriteNoEffect;
  @try {
    return [self writeEnvelopeData:data
                      expectedState:expected
                     lockDescriptor:lockDescriptor
                              error:error];
  } @finally {
    close(lockDescriptor);
  }
}

- (DSHSessionAtomicWriteResult)writeEnvelopeData:(NSData *)data
                                     expectedState:(DSHSessionLoadedState *)expected
                                    lockDescriptor:(int)lockDescriptor
                                             error:(NSError **)error {
  if (![data isKindOfClass:NSData.class] || data.length == 0 ||
      data.length > DSHSessionSnapshotMaximumBytes ||
      lockDescriptor < 0) {
    return DSHSessionAtomicWriteNoEffect;
  }
  if (![self targetMatchesExpectedState:expected error:error]) {
    return DSHSessionAtomicWriteNoEffect;
  }
  if (self.faultHook != nil &&
      !self.faultHook(DSHSessionSnapshotStoreFaultPointBeforeWrite)) {
    DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
    return DSHSessionAtomicWriteNoEffect;
  }
  NSString *temporaryName = [NSString stringWithFormat:@".%@.%@.tmp",
      self.sessionFilename, NSUUID.UUID.UUIDString.lowercaseString];
  int descriptor = openat(self.rootDescriptor, temporaryName.fileSystemRepresentation,
                          O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                          0600);
  if (descriptor < 0) {
    DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
    return DSHSessionAtomicWriteNoEffect;
  }
  BOOL ok = YES;
  const uint8_t *bytes = (const uint8_t *)data.bytes;
  NSUInteger offset = 0;
  while (ok && offset < data.length) {
    ssize_t count = write(descriptor, bytes + offset, data.length - offset);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) {
      ok = NO;
      break;
    }
    offset += (NSUInteger)count;
  }
  NSURL *temporaryURL = [self.rootURL URLByAppendingPathComponent:temporaryName
                                                      isDirectory:NO];
  if (ok) {
    ok = [self hardenPinnedDescriptor:descriptor
                                atURL:temporaryURL
                            directory:NO
                        excludeBackup:YES
                                error:error];
  }
  if (close(descriptor) != 0) ok = NO;
  descriptor = -1;
  if (!ok) {
    unlinkat(self.rootDescriptor, temporaryName.fileSystemRepresentation, 0);
    if (error == nullptr || *error == nil) {
      DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
    }
    return DSHSessionAtomicWriteNoEffect;
  }
  if (self.faultHook != nil &&
      !self.faultHook(DSHSessionSnapshotStoreFaultPointAfterWriteBeforeRename)) {
    unlinkat(self.rootDescriptor, temporaryName.fileSystemRepresentation, 0);
    DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
    return DSHSessionAtomicWriteNoEffect;
  }
  // Recheck the complete expected target immediately before publication. This
  // is the CAS identity guard; the pinned root descriptor prevents path swap.
  if (![self targetMatchesExpectedState:expected error:error]) {
    unlinkat(self.rootDescriptor, temporaryName.fileSystemRepresentation, 0);
    return DSHSessionAtomicWriteNoEffect;
  }
  DSHSessionAtomicWriteResult publishResult =
      [self publishTemporaryFilename:temporaryName
                             filename:self.sessionFilename
                        expectedState:expected
                                error:error];
  if (publishResult != DSHSessionAtomicWriteCommitted) {
    return publishResult;
  }
  // Keep the published inode open while applying metadata to the canonical
  // path. Identity is checked against the pinned descriptor before and after
  // each resource operation, so a lexical-path swap is a conflict.
  int published = openat(self.rootDescriptor,
                         self.sessionFilename.fileSystemRepresentation,
                         O_RDWR | O_CLOEXEC | O_NOFOLLOW);
  if (published < 0) {
    DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
    return DSHSessionAtomicWriteUnknown;
  }
  struct stat publishedBefore = {};
  struct stat visibleBefore = {};
  BOOL publishedIdentity = fstat(published, &publishedBefore) == 0 &&
      fstatat(self.rootDescriptor, self.sessionFilename.fileSystemRepresentation,
              &visibleBefore, AT_SYMLINK_NOFOLLOW) == 0 &&
      publishedBefore.st_dev == visibleBefore.st_dev &&
      publishedBefore.st_ino == visibleBefore.st_ino &&
      publishedBefore.st_size == visibleBefore.st_size &&
      publishedBefore.st_size == (off_t)data.length;
  if (!publishedIdentity) {
    close(published);
    DSHSessionSetError(error, DSHSessionSnapshotStoreErrorConflict);
    return DSHSessionAtomicWriteUnknown;
  }
  NSURL *destinationURL = self.sessionURL;
  if (![self hardenPinnedDescriptor:published
                              atURL:destinationURL
                          directory:NO
                      excludeBackup:YES
                              error:error]) {
    close(published);
    return DSHSessionAtomicWriteUnknown;
  }
  if (self.faultHook != nil &&
      !self.faultHook(DSHSessionSnapshotStoreFaultPointAfterRename)) {
    close(published);
    DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
    return DSHSessionAtomicWriteUnknown;
  }
  if (fsync(published) != 0 || fsync(self.rootDescriptor) != 0) {
    close(published);
    DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
    return DSHSessionAtomicWriteUnknown;
  }
  if (self.faultHook != nil &&
      !self.faultHook(DSHSessionSnapshotStoreFaultPointAfterRenameBeforeVerify)) {
    close(published);
    DSHSessionSetError(error, DSHSessionSnapshotStoreErrorStorage);
    return DSHSessionAtomicWriteUnknown;
  }
  struct stat state = {};
  struct stat visible = {};
  BOOL fstatOK = fstat(published, &state) == 0;
  BOOL metadataOK = fstatOK &&
      [self validateStoredFileDescriptor:published
                                   atURL:destinationURL
                         requireMetadata:YES
                                   error:error];
  BOOL visibleOK = fstatat(self.rootDescriptor, self.sessionFilename.fileSystemRepresentation,
                           &visible, AT_SYMLINK_NOFOLLOW) == 0;
  BOOL nodeOK = visibleOK && visible.st_dev == state.st_dev &&
      visible.st_ino == state.st_ino && visible.st_size == state.st_size;
  BOOL sizeOK = state.st_size == (off_t)data.length;
  BOOL verified = fstatOK && metadataOK && visibleOK && nodeOK && sizeOK;
  close(published);
  if (!verified) return DSHSessionAtomicWriteUnknown;
  return DSHSessionAtomicWriteCommitted;
}

- (NSDictionary *)casPersistSessionLocked:(NSDictionary *)request
                                     error:(NSError **)error {
  BOOL rootReady = [self ensurePrivateRoot:error];
  if (!rootReady) return nil;
  int lockDescriptor = [self acquireCASLock:error];
  if (lockDescriptor < 0) return nil;
  @try {
    NSDictionary *result = [self casPersistSessionLocked:request
                                           lockDescriptor:lockDescriptor
                                                     error:error];
    return result;
  } @finally {
    close(lockDescriptor);
  }
}

- (NSDictionary *)casPersistSessionLocked:(NSDictionary *)request
                            lockDescriptor:(int)lockDescriptor
                                      error:(NSError **)error {
  if (!DSHSessionTrustedDictionary(request) ||
      !DSHSessionTrustedString(request[@"candidate_json"])) {
    DSHSessionSetError(error, DSHSessionSnapshotStoreErrorInvalidArgument);
    return nil;
  }
  // The request shape and the expected authority are judged by the core; the
  // candidate text is not part of that shape and stays out of the envelope.
  NSMutableDictionary *shape = [request mutableCopy];
  shape[@"candidate_json"] = @"";
  if (DSHSessionCoreReduce(@"cas_request", @{ @"request" : shape }, nil, @{},
                           DSHSessionSnapshotStoreErrorInvalidArgument, error) == nil) {
    return nil;
  }
  NSData *candidateBytes = [request[@"candidate_json"]
      dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
  if (candidateBytes == nil || candidateBytes.length == 0 ||
      candidateBytes.length > DSHSessionSnapshotMaximumBytes) {
    DSHSessionSetError(error, DSHSessionSnapshotStoreErrorBounds);
    return nil;
  }
  NSString *candidateDigest = nil;
  NSDictionary *candidate = DSHSessionCoreAcceptCandidate(
      candidateBytes, &candidateDigest, error);
  if (candidate == nil) return nil;

  NSError *stateError = nil;
  DSHSessionLoadedState *state = [self readStateWithError:&stateError];
  if (state == nil) {
    if (error != nullptr) *error = stateError;
    return nil;
  }
  NSString *operationId = request[@"operation_id"];
  NSDictionary *expected = request[@"expected"];
  NSDictionary *precheck = DSHSessionCoreReduce(
      @"cas_precheck",
      @{
        @"operation_id" : operationId,
        @"expected" : expected,
        @"candidate_digest" : candidateDigest,
        @"state" : DSHSessionCoreLoadedView(state),
      },
      nil, @{}, DSHSessionSnapshotStoreErrorCorrupt, error);
  if (precheck == nil) return nil;
  NSDictionary *early = DSHSessionCASOutcomeResult(precheck);
  if (early != nil) return early;

  // Re-read while still holding the same process-global serial lock.  This is
  // the legacy migration guard: an expected token is the digest of exact raw
  // bytes, not of a parsed/re-serialized object.
  DSHSessionLoadedState *current = [self readStateWithError:&stateError];
  if (current == nil) {
    if (error != nullptr) *error = stateError;
    return nil;
  }
  // Re-read the separate tombstone ledger after the authority re-read.  A
  // valid ledger makes a non-retained operation a fresh operation; an absent,
  // stale, or malformed ledger makes the absence unprovable and therefore
  // cannot be allowed to advance the session. The core applies those rules
  // and plans the two writes.
  NSError *tombstoneError = nil;
  DSHSessionTombstoneState *tombstones =
      [self readTombstoneStateWithError:&tombstoneError];
  NSDictionary *plan = DSHSessionCoreReduce(
      @"cas_plan",
      @{
        @"operation_id" : operationId,
        @"expected" : expected,
        @"current" : DSHSessionCoreLoadedView(current),
        @"tombstones" : DSHSessionCoreTombstoneView(tombstones) ?: NSNull.null,
        @"launch_instance_id" : self.launchInstanceId,
      },
      candidateBytes, DSHSessionCoreEnvironment(candidate),
      DSHSessionSnapshotStoreErrorInvalidArgument, error);
  if (plan == nil) return nil;
  early = DSHSessionCASOutcomeResult(plan);
  if (early != nil) return early;
  NSData *tombstoneData = [plan[@"tombstone_json"] isKindOfClass:NSString.class]
      ? [plan[@"tombstone_json"] dataUsingEncoding:NSUTF8StringEncoding] : nil;
  NSData *encoded = [plan[@"envelope_json"] isKindOfClass:NSString.class]
      ? [plan[@"envelope_json"] dataUsingEncoding:NSUTF8StringEncoding] : nil;
  NSArray *commits = plan[@"recent_commits"];
  if (![plan[@"outcome"] isEqual:@"write"] || tombstoneData.length == 0 ||
      encoded.length == 0 || ![commits isKindOfClass:NSArray.class] ||
      ![plan[@"next_generation"] isKindOfClass:NSNumber.class]) {
    DSHSessionSetError(error, DSHSessionSnapshotStoreErrorCorrupt);
    return nil;
  }
  NSUInteger nextGeneration = [plan[@"next_generation"] unsignedIntegerValue];
  if (tombstoneData.length > DSHSessionSnapshotMaximumTombstoneBytes ||
      encoded.length > DSHSessionSnapshotMaximumBytes) {
    DSHSessionSetError(error, DSHSessionSnapshotStoreErrorBounds);
    return nil;
  }
  DSHSessionLoadedState *tombstoneExpected =
      DSHSessionExpectedStateForTombstones(tombstones);
  DSHSessionAtomicWriteResult tombstoneWrite =
      [self writeProtectedData:tombstoneData
                        filename:DSHSessionSnapshotTombstoneFilename
                   expectedState:tombstoneExpected
                  lockDescriptor:lockDescriptor
                           error:error];
  if (tombstoneWrite == DSHSessionAtomicWriteNoEffect) {
    return @{
      @"schema_version" : @1,
      @"status" : @"not_committed",
      @"current" : current.authority,
    };
  }
  if (tombstoneWrite == DSHSessionAtomicWriteUnknown) {
    return @{
      @"schema_version" : @1,
      @"status" : @"unknown",
      @"current" : current.authority,
    };
  }
  DSHSessionAtomicWriteResult writeResult =
      [self writeEnvelopeData:encoded
                 expectedState:current
                lockDescriptor:lockDescriptor
                         error:error];
  if (writeResult == DSHSessionAtomicWriteNoEffect) {
    return @{
      @"schema_version" : @1,
      @"status" : @"not_committed",
      @"current" : current.authority,
    };
  }
  if (writeResult == DSHSessionAtomicWriteUnknown) {
    return @{
      @"schema_version" : @1,
      @"status" : @"unknown",
      // The rename may have committed, but native cannot claim the target
      // authority until the protected read-back succeeds. The caller must
      // resolve this operation through querySessionCommit.
      @"current" : current.authority,
    };
  }
  {
    // The bytes on disk are exactly `encoded`; the read-back below proves
    // that by byte equality instead of parsing and validating a megabyte
    // envelope the core assembled a moment ago.
    DSHSessionValidatedEnvelope *written = [[DSHSessionValidatedEnvelope alloc] init];
    written.bytes = encoded;
    written.envelope = @{
      @"schema_version" : @3,
      @"writer_launch_instance_id" : self.launchInstanceId,
      @"generation" : @(nextGeneration),
      @"session_sha256" : candidateDigest,
      @"session" : candidate,
      @"recent_commits" : commits,
      @"proof_run_id" : NSNull.null,
      @"proof_request_id" : NSNull.null,
    };
    written.session = candidate;
    written.digest = candidateDigest;
    written.generation = nextGeneration;
    written.commits = commits;
    DSHSessionValidatedEnvelopeRemember(written);
  }
  DSHSessionLoadedState *verified = [self readStateWithError:&stateError];
  NSDictionary *verdict = DSHSessionCoreReduce(
      @"cas_verify",
      @{
        @"operation_id" : operationId,
        @"next_generation" : @(nextGeneration),
        @"candidate_digest" : candidateDigest,
        @"verified" : DSHSessionCoreLoadedView(verified),
      },
      nil, @{}, DSHSessionSnapshotStoreErrorCorrupt, nullptr);
  if ([verdict[@"committed"] isEqual:@YES]) {
    @try {
      NSMutableSet *conversationIds = [NSMutableSet set];
      for (NSDictionary *conversation in candidate[@"conversations"]) [conversationIds addObject:conversation[@"id"]];
      DSHAgentPruneRoundPresentationCache([self.rootURL URLByAppendingPathComponent:@"agent-runtime" isDirectory:YES], conversationIds);
    } @catch (__unused NSException *exception) {}
    return @{
      @"schema_version" : @1,
      @"status" : @"committed",
      @"snapshot" : DSHSessionSnapshotRef(nextGeneration, candidateDigest),
    };
  }
  return @{
    @"schema_version" : @1,
    @"status" : @"unknown",
    @"current" : current.authority,
  };
}

- (NSDictionary *)loadSessionSnapshotWithError:(NSError **)error {
  __block NSDictionary *result = nil;
  __block NSError *operationError = nil;
  BOOL completed = [self.coordinator performSyncWithError:^BOOL(NSError **innerError) {
    BOOL rootReady = [self ensurePrivateRoot:&operationError];
    if (!rootReady) {
      if (innerError != nullptr) *innerError = operationError;
      return NO;
    }
    int lockDescriptor = [self acquireCASLock:&operationError];
    if (lockDescriptor < 0) {
      if (innerError != nullptr) *innerError = operationError;
      return NO;
    }
    @try {
    DSHSessionLoadedState *state = [self readStateWithError:&operationError];
    if (state == nil) {
      if (innerError != nullptr) *innerError = operationError;
      return NO;
    }
    result = [self loadResultForState:state error:&operationError];
    if (result == nil && innerError != nullptr) *innerError = operationError;
    return result != nil;
    } @finally {
      close(lockDescriptor);
    }
  } error:error];
  if (!completed && error != nullptr && *error == nil) {
    *error = operationError ?: DSHSessionStoreError(
        DSHSessionSnapshotStoreErrorStorage);
  }
  return result;
}

- (NSDictionary *)loadSessionSnapshot:(NSError **)error {
  return [self loadSessionSnapshotWithError:error];
}

- (NSDictionary *)casPersistSession:(NSDictionary *)request
                               error:(NSError **)error {
  __block NSDictionary *result = nil;
  __block NSError *operationError = nil;
  BOOL completed = [self.coordinator performSyncWithError:^BOOL(NSError **innerError) {
    result = [self casPersistSessionLocked:request error:&operationError];
    if (result == nil && innerError != nullptr) *innerError = operationError;
    return result != nil;
  } error:error];
  if (!completed && error != nullptr && *error == nil) {
    *error = operationError ?: DSHSessionStoreError(
        DSHSessionSnapshotStoreErrorStorage);
  }
  return result;
}

- (NSDictionary *)casPersistSessionWithRequest:(NSDictionary *)request
                                          error:(NSError **)error {
  return [self casPersistSession:request error:error];
}

- (NSDictionary *)querySessionCommit:(NSDictionary *)request
                                error:(NSError **)error {
  __block NSDictionary *result = nil;
  __block NSError *operationError = nil;
  BOOL completed = [self.coordinator performSyncWithError:^BOOL(NSError **innerError) {
    if (!DSHSessionTrustedDictionary(request) ||
        DSHSessionCoreReduce(@"query_request", @{ @"request" : request }, nil, @{},
                             DSHSessionSnapshotStoreErrorInvalidArgument,
                             &operationError) == nil) {
      if (operationError == nil) {
        operationError = DSHSessionStoreError(
            DSHSessionSnapshotStoreErrorInvalidArgument);
      }
      if (innerError != nullptr) *innerError = operationError;
      return NO;
    }
    BOOL rootReady = [self ensurePrivateRoot:&operationError];
    if (!rootReady) {
      if (innerError != nullptr) *innerError = operationError;
      return NO;
    }
    int lockDescriptor = [self acquireCASLock:&operationError];
    if (lockDescriptor < 0) {
      if (innerError != nullptr) *innerError = operationError;
      return NO;
    }
    @try {
    NSError *stateError = nil;
    // Query is intentionally weaker than load: malformed or unavailable
    // storage prevents proving absence, so the core answers `unknown` for a
    // failed read without projecting any native failure detail.
    DSHSessionLoadedState *state = [self readStateWithError:&stateError];
    NSDictionary *reply = DSHSessionCoreReduce(
        @"query_commit",
        @{
          @"operation_id" : request[@"operation_id"],
          @"state" : DSHSessionCoreLoadedView(state),
        },
        nil, @{}, DSHSessionSnapshotStoreErrorCorrupt, nullptr);
    result = [reply[@"result"] isKindOfClass:NSDictionary.class]
        ? reply[@"result"] : @{@"schema_version" : @1, @"status" : @"unknown"};
    return YES;
    } @finally {
      close(lockDescriptor);
    }
  } error:error];
  if (!completed && error != nullptr && *error == nil) {
    *error = operationError ?: DSHSessionStoreError(
        DSHSessionSnapshotStoreErrorStorage);
  }
  return result;
}

- (NSDictionary *)querySessionCommitWithRequest:(NSDictionary *)request
                                           error:(NSError **)error {
  return [self querySessionCommit:request error:error];
}

static NSDictionary *DSHSessionClearanceResult(NSString *status,
                                               NSDictionary *receipt) {
  return receipt == nil
      ? @{ @"schema_version" : @1,
           @"status" : status,
           @"receipt" : NSNull.null }
      : @{ @"schema_version" : @1,
           @"status" : status,
           @"receipt" : receipt };
}

- (NSDictionary *)persistSessionWithWorkspaceClearance:(NSDictionary *)request
                                                 error:(NSError **)error {
  __block NSDictionary *result = nil;
  __block NSError *operationError = nil;
  BOOL completed = [self.coordinator performSyncWithError:^BOOL(NSError **innerError) {
    if (!DSHSessionTrustedDictionary(request) ||
        !DSHSessionExactKeys(request, @[@"schema_version", @"candidate_json",
                                       @"operation"]) ||
        !DSHSessionExactSchema(request[@"schema_version"], 1) ||
        !DSHSessionTrustedString(request[@"candidate_json"]) ||
        !DSHWorkspaceClearanceValidateOperation(request[@"operation"],
                                                &operationError)) {
      if (operationError == nil) {
        operationError = DSHSessionStoreError(
            DSHSessionSnapshotStoreErrorInvalidArgument);
      }
      if (innerError != nullptr) *innerError = operationError;
      return NO;
    }
    NSDictionary *operation = request[@"operation"];
    NSData *candidateBytes = [request[@"candidate_json"]
        dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
    if (candidateBytes == nil || candidateBytes.length == 0 ||
        candidateBytes.length > DSHSessionSnapshotMaximumBytes) {
      operationError = DSHSessionStoreError(
          DSHSessionSnapshotStoreErrorBounds);
      if (innerError != nullptr) *innerError = operationError;
      return NO;
    }
    // The core accepts the candidate and checks that the operation appears
    // unchanged in its authority outbox and that nothing in it still
    // references the workspace (Conflict otherwise).
    NSError *candidateError = nil;
    NSDictionary *candidate = DSHSessionCoreDecodedObject(candidateBytes);
    if (candidate == nil ||
        DSHSessionCoreReduce(@"clearance_candidate", @{ @"operation" : operation },
                             candidateBytes, DSHSessionCoreEnvironment(candidate),
                             DSHSessionSnapshotStoreErrorInvalidArgument,
                             &candidateError) == nil) {
      operationError = candidateError ?: DSHSessionStoreError(
          DSHSessionSnapshotStoreErrorInvalidArgument);
      if (innerError != nullptr) *innerError = operationError;
      return NO;
    }

    if (![self ensurePrivateRoot:&operationError]) {
      result = DSHSessionClearanceResult(@"unknown", nil);
      return YES;
    }
    int lockDescriptor = [self acquireCASLock:&operationError];
    if (lockDescriptor < 0) {
      result = DSHSessionClearanceResult(@"unknown", nil);
      return YES;
    }
    DSHLocalWorkspaceAuthorityMutationGuard *authorityGuard = nil;
    @try {
      // Fixed lock order: the session CAS lock is outermost, then the shared
      // workspace authority mutation guard. Keep both through proof, CAS,
      // second proof, receipt publication, and lost-response query.
      authorityGuard = [self.clearanceWorkspaceAccess
          acquireAuthorityMutationGuard:&operationError];
      if (authorityGuard == nil || self.clearanceStore == nil ||
          ![self.clearanceStore validateProjectDetachedForOperation:operation
              workspaceAccess:self.clearanceWorkspaceAccess
       authorityMutationGuard:authorityGuard error:nil]) {
        result = DSHSessionClearanceResult(@"not_committed", nil);
        return YES;
      }
      NSError *stateError = nil;
      DSHSessionLoadedState *state = [self readStateWithError:&stateError];
      if (state == nil) {
        // A failed read cannot prove the operation's current CAS or issue a
        // receipt. Preserve the recovery surface without projecting details.
        result = DSHSessionClearanceResult(@"unknown", nil);
        return YES;
      }
      NSString *operationId = operation[@"operation_id"];
      // A replayed operation is only idempotent while it still describes
      // the current authority. Once any later generation committed, the
      // old operation can no longer mint/return its generation-1 receipt.
      NSDictionary *replay = DSHSessionCoreReduce(
          @"clearance_replay",
          @{ @"operation_id" : operationId, @"state" : DSHSessionCoreLoadedView(state) },
          nil, @{}, DSHSessionSnapshotStoreErrorCorrupt, nullptr);
      if (![replay[@"allowed"] isEqual:@YES]) {
        result = DSHSessionClearanceResult(@"not_committed", nil);
        return YES;
      }
      NSDictionary *casRequest = @{
        @"schema_version" : @1,
        @"operation_id" : operationId,
        @"expected" : state.authority,
        @"candidate_json" : request[@"candidate_json"],
      };
      NSDictionary *cas = [self casPersistSessionLocked:casRequest
                                          lockDescriptor:lockDescriptor
                                                    error:&stateError];
      if (cas == nil) {
        result = DSHSessionClearanceResult(@"unknown", nil);
        return YES;
      }
      NSString *casStatus = cas[@"status"];
      if (![casStatus isEqual:@"committed"]) {
        result = DSHSessionClearanceResult(
            [casStatus isEqual:@"unknown"] ? @"unknown" : @"not_committed", nil);
        return YES;
      }
      NSDictionary *snapshot = cas[@"snapshot"];
      NSUInteger generation = [snapshot[@"generation"] unsignedIntegerValue];
      NSString *digest = snapshot[@"session_sha256"];
      if (generation == 0 || !DSHSessionCanonicalDigest(digest) ||
          self.clearanceStore == nil) {
        result = DSHSessionClearanceResult(@"unknown", nil);
        return YES;
      }
      NSError *receiptError = nil;
      NSDictionary *receipt = [self.clearanceStore
          issueReceiptForOperation:operation
          committedSessionGeneration:generation
          committedSessionSHA256:digest
          lockDescriptor:lockDescriptor
          workspaceAccess:self.clearanceWorkspaceAccess
          authorityMutationGuard:authorityGuard
          error:&receiptError];
      if (receipt != nil) {
        result = DSHSessionClearanceResult(@"committed", receipt);
        return YES;
      }
      // A receipt may have committed even when its bridge response was lost
      // at the final verification checkpoint. Querying by the same operation
      // and session token recovers it without writing a second receipt.
      NSDictionary *recovered = [self.clearanceStore
          queryReceiptForOperationId:operationId
          currentSessionGeneration:generation
          currentSessionSHA256:digest
          lockDescriptor:lockDescriptor
          error:nil];
      if ([recovered[@"status"] isEqual:@"committed"] &&
          recovered[@"receipt"] != NSNull.null) {
        result = recovered;
      } else {
        result = DSHSessionClearanceResult(@"unknown", nil);
      }
      return YES;
    } @finally {
      authorityGuard = nil;
      close(lockDescriptor);
    }
  } error:error];
  if (!completed && error != nullptr && *error == nil) {
    *error = operationError ?: DSHSessionStoreError(
        DSHSessionSnapshotStoreErrorStorage);
  }
  return result;
}

- (NSDictionary *)queryWorkspaceClearance:(NSDictionary *)request
                                     error:(NSError **)error {
  __block NSDictionary *result = nil;
  __block NSError *operationError = nil;
  BOOL completed = [self.coordinator performSyncWithError:^BOOL(NSError **innerError) {
    if (!DSHSessionTrustedDictionary(request) ||
        DSHSessionCoreReduce(@"query_request", @{ @"request" : request }, nil, @{},
                             DSHSessionSnapshotStoreErrorInvalidArgument,
                             &operationError) == nil) {
      if (operationError == nil) {
        operationError = DSHSessionStoreError(
            DSHSessionSnapshotStoreErrorInvalidArgument);
      }
      if (innerError != nullptr) *innerError = operationError;
      return NO;
    }
    if (self.clearanceStore == nil) {
      result = @{ @"schema_version" : @1, @"status" : @"unknown" };
      return YES;
    }
    NSError *stateError = nil;
    DSHSessionLoadedState *state = [self readStateWithError:&stateError];
    if (state == nil) {
      result = @{ @"schema_version" : @1, @"status" : @"unknown" };
      return YES;
    }
    if (state.missing || state.legacy) {
      result = @{ @"schema_version" : @1, @"status" : @"not_started" };
      return YES;
    }
    result = [self.clearanceStore
        queryReceiptForOperationId:request[@"operation_id"]
        currentSessionGeneration:state.generation
        currentSessionSHA256:state.sessionDigest
        error:nil];
    if ([result[@"status"] isEqual:@"not_started"]) {
      // A missing receipt is not provable absence once the session store has
      // durably observed this operation.  The session CAS may have committed
      // while receipt publication failed or was interrupted; preserve that
      // recovery surface as unknown instead of inviting a fresh operation.
      NSDictionary *observed = DSHSessionCoreReduce(
          @"clearance_observed",
          @{ @"operation_id" : request[@"operation_id"], @"state" : DSHSessionCoreLoadedView(state) },
          nil, @{}, DSHSessionSnapshotStoreErrorCorrupt, nullptr);
      if ([observed[@"observed"] isEqual:@YES]) {
        result = @{ @"schema_version" : @1, @"status" : @"unknown" };
      }
    }
    if (result == nil) {
      result = @{ @"schema_version" : @1, @"status" : @"unknown" };
    }
    return YES;
  } error:error];
  if (!completed && error != nullptr && *error == nil) {
    *error = operationError ?: DSHSessionStoreError(
        DSHSessionSnapshotStoreErrorStorage);
  }
  return result;
}

#pragma mark - Candidate digest (shared shell/native contract)

+ (nullable NSString *)candidateDigestForSessionJSON:(NSString *)candidateJSON {
  // UTF-8 bounds, strict parse, schema-9 root, canonical JSON and the
  // domain-separated SHA-256 the CAS mints as session_sha256.
  if (![candidateJSON isKindOfClass:NSString.class]) return nil;
  NSData *bytes = [candidateJSON dataUsingEncoding:NSUTF8StringEncoding
                              allowLossyConversion:NO];
  if (bytes == nil || bytes.length == 0 ||
      bytes.length > DSHSessionSnapshotMaximumBytes) {
    return nil;
  }
  // The authority read right after a commit hands UI the exact bytes the CAS
  // just validated and digested; a byte-equal hit returns that digest without
  // parsing and canonicalising a megabyte again.
  DSHSessionValidatedEnvelope *validated = DSHSessionValidatedEnvelopeCached(bytes);
  if (validated != nil && validated.digest.length > 0) return validated.digest;
  // Accept a JSON object whose schema_version is 9 and that canonicalises. The CAS path still
  // applies the full schema-9 validation before anything is written.
  NSDictionary *reply = DSHSessionCoreReduce(
      @"candidate_digest", nil, bytes, @{},
      DSHSessionSnapshotStoreErrorInvalidArgument, nullptr);
  NSString *digest = reply[@"digest"];
  return [digest isKindOfClass:NSString.class] ? digest : nil;
}

@end
