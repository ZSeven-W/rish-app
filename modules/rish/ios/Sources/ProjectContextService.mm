#import "ProviderConfiguration.h"
#import "ProjectContextService.h"
#import "RishHarnessCatalog.h"
#import "LegacyBoundProjectRootAccess.h"

#import <CommonCrypto/CommonDigest.h>

#import "DSHWorkspaceCanonical.h"

#include "rish_agent_core.h"
#import "LocalProjectAccessInternals.h"
#import "LocalWorkspaceAccess.h"

#include <fcntl.h>
#include <git2.h>
#include <limits.h>
#include <math.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString *DSHServiceSHA256(NSData *data);

// The project-access reducer, for the root reference rule this file shares
// with LocalProjectAccess.
static NSDictionary *DSHProjectAccessReduce(NSString *op,
                                            NSDictionary *fields) {
  NSMutableDictionary *envelope = [fields mutableCopy];
  envelope[@"op"] = op;
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:envelope options:0
                                                    error:nil];
  char *raw = bytes == nil ? NULL : rish_agent_project_access_reduce(
      (const char *)bytes.bytes, bytes.length);
  if (raw == NULL) return nil;
  NSData *replyBytes = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  id reply = [NSJSONSerialization JSONObjectWithData:replyBytes options:0
                                                error:nil];
  return [reply isKindOfClass:NSDictionary.class] &&
      [reply[@"ok"] isEqual:@YES] ? reply : nil;
}
static NSData *DSHCanonicalJSON(id object);

@interface DSHLocalWorkspaceAccess (DSHContextLegacyBoundPrivate)
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

@interface DSHLocalWorkspaceAuthorityMutationGuard (DSHContextLegacyBoundPrivate)
@property(nonatomic, weak, readonly) DSHLocalWorkspaceAccess *owner;
@end

@interface DSHBorrowedProjectContextLease : NSObject
@property(nonatomic, copy) NSString *projectId;
@property(nonatomic, copy) NSDictionary *metadata;
@property(nonatomic, copy) NSString *workspaceId;
@property(nonatomic) NSUInteger workspaceBindingRevision;
@property(nonatomic, copy) NSString *rootFingerprintSHA256;
@property(nonatomic, copy) NSString *rootFingerprint;
@property(nonatomic, copy) NSDictionary *workspaceRootRef;
@property(nonatomic, copy) NSString *gitTopology;
@property(nonatomic, copy) NSString *workspaceBindingDigest;
@property(nonatomic) int repositoryDescriptor;
@property(nonatomic) int workspaceRootDescriptor;
@property(nonatomic) dev_t projectsRootDevice;
@property(nonatomic) ino_t projectsRootInode;
@property(nonatomic) dev_t projectDevice;
@property(nonatomic) ino_t projectInode;
@property(nonatomic) dev_t repositoryDevice;
@property(nonatomic) ino_t repositoryInode;
@property(nonatomic) dev_t workspaceRootDevice;
@property(nonatomic) ino_t workspaceRootInode;
@property(nonatomic) dev_t gitDevice;
@property(nonatomic) ino_t gitInode;
@property(nonatomic) dev_t objectsDevice;
@property(nonatomic) ino_t objectsInode;
@property(nonatomic) git_repository *repository;
- (nullable instancetype)initWithBorrowedDescriptor:(int)descriptor
                                                root:(NSDictionary *)root
                                         fingerprint:(NSString *)fingerprint
                                               error:(NSError **)error;
- (BOOL)validateIdentity;
@end

@implementation DSHBorrowedProjectContextLease
- (instancetype)initWithBorrowedDescriptor:(int)descriptor
                                       root:(NSDictionary *)root
                                fingerprint:(NSString *)fingerprint
                                      error:(NSError **)error {
  self = [super init];
  if (self == nil) return nil;
  _repositoryDescriptor = dup(descriptor);
  if (_repositoryDescriptor < 0) return nil;
  struct stat repositoryState = {};
  if (fstat(_repositoryDescriptor, &repositoryState) != 0 ||
      !S_ISDIR(repositoryState.st_mode)) return nil;
  int gitDescriptor = openat(_repositoryDescriptor, ".git",
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  int objectsDescriptor = gitDescriptor < 0 ? -1 : openat(gitDescriptor,
      "objects", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  struct stat gitState = {}, objectsState = {};
  if (gitDescriptor < 0 || objectsDescriptor < 0 ||
      fstat(gitDescriptor, &gitState) != 0 ||
      fstat(objectsDescriptor, &objectsState) != 0) {
    if (gitDescriptor >= 0) close(gitDescriptor);
    if (objectsDescriptor >= 0) close(objectsDescriptor);
    return nil;
  }
  close(gitDescriptor);
  close(objectsDescriptor);
  char descriptorPath[PATH_MAX] = {};
  if (fcntl(_repositoryDescriptor, F_GETPATH, descriptorPath) != 0) return nil;
  git_repository *repository = nullptr;
  if (git_repository_open_ext(&repository, descriptorPath,
                              GIT_REPOSITORY_OPEN_NO_SEARCH, nullptr) != 0 ||
      repository == nullptr) return nil;
  _repository = repository;
  _projectId = [root[@"project_id"] copy];
  _metadata = @{
    @"schema_version" : @1,
    @"name" : _projectId,
    @"origin_url" : NSNull.null,
  };
  _workspaceId = [root[@"workspace_id"] copy];
  _workspaceBindingRevision = [root[@"binding_revision"] unsignedIntegerValue];
  _rootFingerprintSHA256 = [fingerprint copy];
  _rootFingerprint = [fingerprint copy];
  _workspaceRootRef = [root copy];
  // `legacy_app_owned` is the workspace locator/origin vocabulary.  The
  // public Project Context V2 descriptor uses the Git topology vocabulary
  // accepted by LocalProjectContextModule.
  _gitTopology = @"legacy_embedded";
  _workspaceBindingDigest = DSHServiceSHA256(
      DSHCanonicalJSON(@{@"root" : root, @"fingerprint" : fingerprint})
          ?: NSData.data);
  _projectsRootDevice = _projectDevice = _repositoryDevice =
      _workspaceRootDevice = repositoryState.st_dev;
  _projectsRootInode = _projectInode = _repositoryInode =
      _workspaceRootInode = repositoryState.st_ino;
  _gitDevice = gitState.st_dev;
  _gitInode = gitState.st_ino;
  _objectsDevice = objectsState.st_dev;
  _objectsInode = objectsState.st_ino;
  _workspaceRootDescriptor = _repositoryDescriptor;
  return self;
}
- (void)dealloc {
  if (_repository != nullptr) git_repository_free(_repository);
  if (_repositoryDescriptor >= 0) close(_repositoryDescriptor);
}
- (BOOL)validateIdentity {
  struct stat state = {};
  return _repositoryDescriptor >= 0 &&
      fstat(_repositoryDescriptor, &state) == 0 && S_ISDIR(state.st_mode) &&
      state.st_dev == _repositoryDevice && state.st_ino == _repositoryInode;
}
@end

NSErrorDomain const DSHProjectContextServiceErrorDomain =
    @"dev.zseven.rish.project-context-service";

static NSError *DSHServiceError(DSHProjectContextServiceErrorCode code) {
  NSString *message = @"Project context input is invalid.";
  switch (code) {
    case DSHProjectContextServiceErrorProjectUnavailable:
      message = @"Project context is unavailable.";
      break;
    case DSHProjectContextServiceErrorChanged:
      message = @"Project context changed.";
      break;
    case DSHProjectContextServiceErrorSecret:
      message = @"Project context contains restricted data.";
      break;
    case DSHProjectContextServiceErrorBudgetExceeded:
      message = @"Project context budget exceeded.";
      break;
    case DSHProjectContextServiceErrorStorage:
      message = @"Project context storage is unavailable.";
      break;
    case DSHProjectContextServiceErrorTimeout:
      message = @"Project context preparation timed out.";
      break;
    case DSHProjectContextServiceErrorConsent:
      message = @"Project context consent is invalid.";
      break;
    case DSHProjectContextServiceErrorIntegrity:
      message = @"Project context integrity validation failed.";
      break;
    case DSHProjectContextServiceErrorSnapshotMissing:
      message = @"Project context snapshot is missing.";
      break;
    case DSHProjectContextServiceErrorInvalidArgument:
      break;
  }
  return [NSError errorWithDomain:DSHProjectContextServiceErrorDomain
                             code:code
                         userInfo:@{NSLocalizedDescriptionKey : message}];
}

static void DSHSetServiceError(NSError **error,
                               DSHProjectContextServiceErrorCode code) {
  if (error != nil) *error = DSHServiceError(code);
}

static DSHProjectContextServiceErrorCode DSHServiceSnapshotStoreError(
    NSError *storeError) {
  if ([storeError.domain isEqual:DSHProjectContextStoreErrorDomain]) {
    if (storeError.code == DSHProjectContextStoreErrorNotFound) {
      return DSHProjectContextServiceErrorSnapshotMissing;
    }
    if (storeError.code == DSHProjectContextStoreErrorIntegrity) {
      return DSHProjectContextServiceErrorIntegrity;
    }
    if (storeError.code == DSHProjectContextStoreErrorCapacity) {
      return DSHProjectContextServiceErrorBudgetExceeded;
    }
  }
  return DSHProjectContextServiceErrorStorage;
}

static NSString *DSHServiceSHA256(NSData *data) {
  uint8_t digest[CC_SHA256_DIGEST_LENGTH] = {};
  CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  NSMutableString *hex =
      [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
  for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
    [hex appendFormat:@"%02x", digest[index]];
  }
  return hex;
}

static NSString *DSHServiceOid(const git_oid *oid) {
  if (oid == nullptr || git_oid_is_zero(oid)) return nil;
  char output[GIT_OID_SHA1_HEXSIZE + 1] = {};
  git_oid_tostr(output, sizeof(output), oid);
  return [NSString stringWithUTF8String:output];
}

static NSData *DSHCanonicalJSON(id object) {
  if (![NSJSONSerialization isValidJSONObject:object]) return nil;
  return [NSJSONSerialization dataWithJSONObject:object
                                         options:NSJSONWritingSortedKeys
                                           error:nil];
}

static NSString *DSHServiceISO8601(NSDate *date) {
  NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
  formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                            NSISO8601DateFormatWithFractionalSeconds;
  formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
  return [formatter stringFromDate:date];
}

static BOOL DSHServiceCanonicalIdentifier(NSString *value) {
  if (![value isKindOfClass:NSString.class] || value.length != 36) return NO;
  NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:value];
  return uuid != nil &&
         [uuid.UUIDString.lowercaseString isEqualToString:value];
}

static NSString *DSHServiceCanonicalIdentifierString(id value) {
  NSString *candidate = [value isKindOfClass:NSString.class] ? value : nil;
  return DSHServiceCanonicalIdentifier(candidate) ? [candidate copy] : nil;
}

static NSString *DSHServiceCanonicalUInt64String(unsigned long long value) {
  return [NSString stringWithFormat:@"%llu", value];
}

static BOOL DSHServiceExactKeys(NSDictionary *object,
                                NSArray<NSString *> *keys) {
  if (![object isKindOfClass:NSDictionary.class] || object.count != keys.count) {
    return NO;
  }
  NSSet *allowed = [NSSet setWithArray:keys];
  for (id key in object) {
    if (![key isKindOfClass:NSString.class] || ![allowed containsObject:key]) {
      return NO;
    }
  }
  return YES;
}

static BOOL DSHServiceIsBoolean(id value) {
  return [value isKindOfClass:NSNumber.class] &&
         CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static BOOL DSHServiceSafeRevision(id value, NSUInteger *revisionOut) {
  if (![value isKindOfClass:NSNumber.class] || DSHServiceIsBoolean(value) ||
      [value isKindOfClass:NSDecimalNumber.class]) {
    return NO;
  }
  NSNumber *number = value;
  double decimal = number.doubleValue;
  if (!isfinite(decimal) || signbit(decimal) || floor(decimal) != decimal ||
      decimal < 1.0 || decimal > 9007199254740991.0 ||
      number.unsignedLongLongValue != (unsigned long long)decimal) {
    return NO;
  }
  if (revisionOut != nullptr) *revisionOut = (NSUInteger)decimal;
  return YES;
}

// How a snapshot reference is named, and what a v2 argument has to be, live in
// the shared core (modules/rish/core,
// `rish_agent_project_context_service_reduce`). The root reference rule is the
// one `project_access` owns; this file used to carry a second copy of it.
static NSDictionary *DSHServiceReduce(NSString *op, NSDictionary *fields) {
  NSMutableDictionary *envelope = [fields mutableCopy];
  envelope[@"op"] = op;
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:envelope options:0
                                                    error:nil];
  char *raw = bytes == nil ? NULL : rish_agent_project_context_service_reduce(
      (const char *)bytes.bytes, bytes.length);
  if (raw == NULL) return nil;
  NSData *replyBytes = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  id reply = [NSJSONSerialization JSONObjectWithData:replyBytes options:0
                                                error:nil];
  return [reply isKindOfClass:NSDictionary.class] &&
      [reply[@"ok"] isEqual:@YES] ? reply : nil;
}

static NSDictionary *DSHServiceV2RootRef(id value, BOOL projectRequired) {
  NSDictionary *root = [value isKindOfClass:NSDictionary.class] ? value : nil;
  id canonical = DSHProjectAccessReduce(@"canonical_root_ref", @{
    @"root_ref" : root ?: NSNull.null,
  })[@"root_ref"];
  if (![canonical isKindOfClass:NSDictionary.class]) return nil;
  // `canonical_root_ref` answers the project-optional question; asking for a
  // project is the caller's, and is checked here rather than by deriving a
  // second canonical form.
  if (projectRequired && canonical[@"project_id"] == NSNull.null) return nil;
  return canonical;
}

static NSString *DSHServiceV2Model(id value) {
  return DSHHarnessIsSupportedModel(value) ? [value copy] : nil;
}

static NSString *DSHServiceV2BoundedString(id value, NSUInteger maxBytes,
                                            BOOL allowEmpty) {
  if (![value isKindOfClass:NSString.class]) return nil;
  NSString *string = value;
  NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding
                         allowLossyConversion:NO];
  if (data == nil || data.length > maxBytes ||
      (!allowEmpty && string.length == 0) ||
      [string rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet]
              .location != NSNotFound) {
    return nil;
  }
  return [string copy];
}

static BOOL DSHServiceV2RootsEqual(NSDictionary *left, NSDictionary *right) {
  return [DSHServiceReduce(@"roots_equal", @{
    @"left" : [left isKindOfClass:NSDictionary.class] ? left : NSNull.null,
    @"right" : [right isKindOfClass:NSDictionary.class] ? right : NSNull.null,
  })[@"equal"] isEqual:@YES];
}

static BOOL DSHServiceCanonicalDigest(id value) {
  return [DSHServiceReduce(@"canonical_digest", @{
    @"value" : value ?: NSNull.null,
  })[@"valid"] isEqual:@YES];
}

// ProjectContextStore's prepare protocol names its transaction by the suffix
// of an active:<uuid> key. Derive that UUID from the complete V2 authority
// tuple so two workspaces using the same conversation UUID can never evict or
// authorize one another's snapshot. The derived UUID is private and never
// returned to the UI.
static NSString *DSHServiceV2ReferenceId(NSDictionary *root,
                                         NSString *rootFingerprint,
                                         NSString *conversationId) {
  id derived = DSHServiceReduce(@"reference_id", @{
    @"root" : [root isKindOfClass:NSDictionary.class] ? root : NSNull.null,
    @"root_fingerprint_sha256" : rootFingerprint ?: NSNull.null,
    @"conversation_id" : conversationId ?: NSNull.null,
  })[@"reference_id"];
  return [derived isKindOfClass:NSString.class] ? derived : nil;
}

static NSString *const DSHServiceV2PrepareNoPriorSnapshotId =
    @"00000000-0000-0000-0000-000000000000";

static BOOL DSHServiceSameStat(const struct stat &left,
                               const struct stat &right) {
  return left.st_dev == right.st_dev && left.st_ino == right.st_ino &&
         left.st_mode == right.st_mode && left.st_nlink == right.st_nlink &&
         left.st_size == right.st_size &&
         left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec &&
         left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec &&
         left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec &&
         left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec;
}

static NSDictionary *DSHServiceStatDescriptor(const struct stat &metadata) {
  return @{
    @"device" : @((unsigned long long)metadata.st_dev),
    @"inode" : @((unsigned long long)metadata.st_ino),
    @"mode" : @((unsigned long long)metadata.st_mode),
    @"links" : @((unsigned long long)metadata.st_nlink),
    @"size" : @((long long)metadata.st_size),
    @"mtime_seconds" : @((long long)metadata.st_mtimespec.tv_sec),
    @"mtime_nanoseconds" : @((long long)metadata.st_mtimespec.tv_nsec),
    @"ctime_seconds" : @((long long)metadata.st_ctimespec.tv_sec),
    @"ctime_nanoseconds" : @((long long)metadata.st_ctimespec.tv_nsec),
  };
}

static NSDictionary *DSHServiceObservation(const struct stat &metadata) {
  NSDictionary *descriptor = DSHServiceStatDescriptor(metadata);
  return @{
    @"metadata" : descriptor,
    @"observation_sha256" :
        DSHServiceSHA256(DSHCanonicalJSON(descriptor) ?: NSData.data),
  };
}

static NSString *DSHServiceDeltaPath(const git_diff_delta *delta,
                                     BOOL newSide) {
  if (delta == nullptr) return nil;
  const char *path = newSide ? delta->new_file.path : delta->old_file.path;
  if (path == nullptr) path = newSide ? delta->old_file.path : delta->new_file.path;
  return path == nullptr ? nil : [NSString stringWithUTF8String:path];
}

static NSString *DSHServiceGitState(BOOL staged,
                                    BOOL unstaged,
                                    BOOL conflicted) {
  if (conflicted) return @"conflicted";
  if (unstaged) return @"unstaged";
  if (staged) return @"staged";
  return @"unchanged";
}

@interface DSHProjectContextService ()
@property(nonatomic, strong) DSHLocalProjectAccess *projectAccess;
@property(nonatomic, strong, nullable) DSHLocalWorkspaceAccess *workspaceAccess;
@property(nonatomic, strong) DSHProjectContextStore *store;
@property(nonatomic, strong) DSHProjectContextPolicy *policy;
@property(nonatomic, copy) DSHProjectContextClock clock;
@property(nonatomic, copy) DSHProjectContextIdentifierGenerator identifierGenerator;
@property(nonatomic, copy, nullable) DSHProjectContextServiceHook hook;
@property(nonatomic, strong, nullable) DSHBorrowedProjectContextLease *borrowedLegacyLease;
- (nullable DSHLocalProjectLease *)v2LeaseForRoot:(NSDictionary *)rootRef
                                  includeMetadata:(BOOL)includeMetadata
                                           error:(NSError **)error;
- (BOOL)verifyLiveSnapshotV2:(NSDictionary *)snapshot
                       root:(NSDictionary *)rootRef
              retainedLease:(DSHLocalProjectLease *_Nullable *_Nullable)lease
                       error:(NSError **)error;
- (BOOL)verifySnapshotV2:(NSDictionary *)snapshot root:(NSDictionary *)rootRef
       requireLiveSource:(BOOL)requireLiveSource
           retainedLease:(DSHLocalProjectLease *_Nullable *_Nullable)lease
                    error:(NSError **)error;
- (nullable NSData *)verifiedEnvelopeV2:(NSDictionary *)request
                     requireLiveSource:(BOOL)requireLiveSource
                               receipt:(NSDictionary *_Nullable *_Nullable)receipt
                                 error:(NSError **)error;
- (nullable NSDictionary *)captureV2ForLease:(DSHLocalProjectLease *)lease
                                selectedPaths:(NSArray<NSString *> *)selectedPaths
                                       blocks:(BOOL)includeBlocks
                                        start:(NSDate *)start
                                        error:(NSError **)error;
- (BOOL)validateV2Lease:(DSHLocalProjectLease *)lease
                   root:(NSDictionary *)root
                  error:(NSError **)error;
- (nullable NSDictionary *)legacyBoundRootForV2Root:(NSDictionary *)root
                                            locator:(NSString *_Nullable *_Nullable)locator
                                              error:(NSError **)error;
- (DSHLegacyBoundProjectRootDisposition)performLegacyContextForRoot:
    (NSDictionary *)root operation:(BOOL (^)(NSError **error))operation
    error:(NSError **)error;
@end

@implementation DSHProjectContextService

- (instancetype)init {
  return [self initWithProjectAccess:DSHLocalProjectAccess.sharedAccess
                     workspaceAccess:nil
                               store:[[DSHProjectContextStore alloc] init]
                              policy:[[DSHProjectContextPolicy alloc] init]
                               clock:^NSDate * {
                                 return NSDate.date;
                               }
                 identifierGenerator:^NSString * {
                   return NSUUID.UUID.UUIDString.lowercaseString;
                 }
                                hook:nil];
}

- (instancetype)initWithProjectAccess:(DSHLocalProjectAccess *)projectAccess
                                  store:(DSHProjectContextStore *)store
                                 policy:(DSHProjectContextPolicy *)policy
                                  clock:(DSHProjectContextClock)clock
                    identifierGenerator:
                        (DSHProjectContextIdentifierGenerator)identifierGenerator
                                   hook:(DSHProjectContextServiceHook)hook {
  return [self initWithProjectAccess:projectAccess
                     workspaceAccess:nil
                                store:store
                               policy:policy
                                clock:clock
                  identifierGenerator:identifierGenerator
                                 hook:hook];
}

- (instancetype)initWithProjectAccess:(DSHLocalProjectAccess *)projectAccess
                       workspaceAccess:(DSHLocalWorkspaceAccess *)workspaceAccess
                                  store:(DSHProjectContextStore *)store
                                 policy:(DSHProjectContextPolicy *)policy
                                  clock:(DSHProjectContextClock)clock
                    identifierGenerator:
                        (DSHProjectContextIdentifierGenerator)identifierGenerator
                                   hook:(DSHProjectContextServiceHook)hook {
  self = [super init];
  if (self) {
    _projectAccess = projectAccess;
    _workspaceAccess = workspaceAccess;
    _store = store;
    _policy = policy;
    _clock = [clock copy];
    _identifierGenerator = [identifierGenerator copy];
    _hook = [hook copy];
  }
  return self;
}

- (BOOL)deadlineFrom:(NSDate *)start error:(NSError **)error {
  NSTimeInterval elapsed = [self.clock() timeIntervalSinceDate:start];
  if (!isfinite(elapsed) || elapsed < 0 ||
      elapsed > DSHProjectContextDeadlineSeconds) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorTimeout);
    return NO;
  }
  return YES;
}

- (BOOL)validateV2Lease:(DSHLocalProjectLease *)lease
                   root:(NSDictionary *)root
                  error:(NSError **)error {
  if ((id)lease == self.borrowedLegacyLease) {
    BOOL valid = [self.borrowedLegacyLease validateIdentity] &&
        [self.borrowedLegacyLease.workspaceRootRef isEqual:root];
    if (!valid) DSHSetServiceError(error, DSHProjectContextServiceErrorChanged);
    return valid;
  }
  return [self.projectAccess validateWorkspaceLeaseIdentity:lease
                                                     rootRef:root
                                                       error:error];
}

- (NSDictionary *)legacyBoundRootForV2Root:(NSDictionary *)root
                                    locator:(NSString **)locatorOut
                                      error:(NSError **)error {
  NSError *authorityError = nil;
  __attribute__((objc_precise_lifetime))
  DSHLocalWorkspaceAuthorityMutationGuard *guard =
      [self.workspaceAccess acquireAuthorityMutationGuard:&authorityError];
  if (guard == nil || guard.owner != self.workspaceAccess ||
      ![self.workspaceAccess ensurePrivateLayoutLocked:&authorityError]) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorProjectUnavailable);
    return nil;
  }
  NSDictionary *registry = [self.workspaceAccess loadRegistry:&authorityError
                                                        digest:nil];
  NSDictionary *record = registry == nil ? nil :
      [self.workspaceAccess recordInRegistry:registry
                                  workspaceId:root[@"workspace_id"]];
  if (record == nil ||
      ![record[@"binding_revision"] isEqual:root[@"binding_revision"]]) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorChanged);
    return nil;
  }
  NSString *locator = record[@"root_locator_kind"];
  if (locatorOut != nil) *locatorOut = [locator copy];
  if ([locator isEqual:@"documents_owned"]) return nil;
  if (![locator isEqual:@"legacy_app_owned"] ||
      ![record[@"origin"] isEqual:@"legacy_app_owned"] ||
      ![record[@"legacy_project_id"] isEqual:root[@"project_id"]]) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorProjectUnavailable);
    return nil;
  }
  NSDictionary *authority = [self.workspaceAccess
      loadAuthorityForRecord:record error:&authorityError];
  NSSet *available = authority == nil ? nil : [self.workspaceAccess
      verifiedLegacyCapabilitiesForRecord:record authority:authority];
  NSString *fingerprint = authority[@"root_fingerprint_sha256"];
  if (available == nil || ![available containsObject:@"read"] ||
      ![available containsObject:@"project_context"] ||
      ![fingerprint isKindOfClass:NSString.class] || fingerprint.length != 64) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorChanged);
    return nil;
  }
  NSMutableArray *capabilities = [NSMutableArray arrayWithObject:@"file_read"];
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

- (DSHLegacyBoundProjectRootDisposition)performLegacyContextForRoot:
    (NSDictionary *)root operation:(BOOL (^)(NSError **error))operation
    error:(NSError **)error {
  if (self.borrowedLegacyLease != nil || self.workspaceAccess == nil) {
    if (error != nil) *error = nil;
    return DSHLegacyBoundProjectRootDispositionNotHandled;
  }
  NSString *locator = nil;
  NSError *boundError = nil;
  NSDictionary *boundRoot = [self legacyBoundRootForV2Root:root
                                                   locator:&locator
                                                     error:&boundError];
  if ([locator isEqual:@"documents_owned"]) {
    if (error != nil) *error = nil;
    return DSHLegacyBoundProjectRootDispositionNotHandled;
  }
  if (boundRoot == nil) {
    if (error != nil) *error = boundError ?: DSHServiceError(
        DSHProjectContextServiceErrorProjectUnavailable);
    return DSHLegacyBoundProjectRootDispositionFailed;
  }
  DSHLegacyBoundProjectRootAccess *adapter =
      [[DSHLegacyBoundProjectRootAccess alloc]
          initWithWorkspaceAccess:self.workspaceAccess
                     projectAccess:self.projectAccess];
  DSHLegacyBoundProjectRootDisposition disposition = [adapter
      performRepositoryRootOperationForBoundRoot:boundRoot
                                            mode:
                                                DSHLegacyBoundProjectRootOperationModeProjectContext
                                         timeout:DSHProjectContextDeadlineSeconds
                                           block:^BOOL(int descriptor,
                                                       NSError **blockError) {
    DSHBorrowedProjectContextLease *borrowed =
        [[DSHBorrowedProjectContextLease alloc]
            initWithBorrowedDescriptor:descriptor
                                  root:root
                           fingerprint:boundRoot[@"root_fingerprint_sha256"]
                                 error:blockError];
    if (borrowed == nil) {
      DSHSetServiceError(blockError,
                         DSHProjectContextServiceErrorProjectUnavailable);
      return NO;
    }
    @synchronized(self) {
      self.borrowedLegacyLease = borrowed;
      BOOL succeeded = operation(blockError);
      self.borrowedLegacyLease = nil;
      return succeeded;
    }
  } error:&boundError];
  if (disposition == DSHLegacyBoundProjectRootDispositionFailed) {
    if (error != nil) {
      if ([boundError.domain isEqual:DSHProjectContextServiceErrorDomain]) {
        *error = boundError;
      } else {
        *error = DSHServiceError(
            boundError.code == DSHLegacyBoundProjectRootAccessErrorUnavailable
                ? DSHProjectContextServiceErrorProjectUnavailable
                : DSHProjectContextServiceErrorChanged);
      }
    }
  } else if (error != nil) {
    *error = nil;
  }
  return disposition;
}

- (NSDictionary *)validatedSelection:(NSDictionary *)selection
                                error:(NSError **)error {
  NSArray *keys = @[
    @"schema_version", @"project_id", @"conversation_id", @"provider",
    @"model", @"policy", @"selected_paths"
  ];
  if (!DSHServiceExactKeys(selection, keys) ||
      ![selection[@"schema_version"] isEqual:@1] ||
      ![DSHLocalProjectAccess isCanonicalProjectId:selection[@"project_id"]] ||
      !DSHServiceCanonicalIdentifier(selection[@"conversation_id"]) ||
      !DSHHarnessIsSupportedModel(selection[@"model"]) ||
      ![selection[@"provider"] isEqual:DSHProviderIdForModel(selection[@"model"])] ||
      ![selection[@"policy"] isEqual:@"chat-read-v1"] ||
      ![selection[@"selected_paths"] isKindOfClass:NSArray.class] ||
      [selection[@"selected_paths"] count] > DSHProjectContextMaxEntries) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorInvalidArgument);
    return nil;
  }
  NSMutableArray<NSString *> *paths = [NSMutableArray array];
  NSMutableSet<NSString *> *seen = [NSMutableSet set];
  for (id rawPath in selection[@"selected_paths"]) {
    if (![rawPath isKindOfClass:NSString.class]) {
      DSHSetServiceError(error, DSHProjectContextServiceErrorInvalidArgument);
      return nil;
    }
    DSHProjectContextPathDecision *decision =
        [self.policy decisionForRelativePath:rawPath];
    NSString *normalized = decision.normalizedPath;
    if (normalized.length == 0 || [seen containsObject:normalized]) {
      DSHSetServiceError(error, DSHProjectContextServiceErrorInvalidArgument);
      return nil;
    }
    [seen addObject:normalized];
    [paths addObject:normalized];
  }
  [paths sortUsingSelector:@selector(compare:)];
  NSMutableDictionary *validated = [selection mutableCopy];
  validated[@"selected_paths"] = paths;
  return validated;
}

- (NSDictionary *)safeReadPath:(NSString *)relativePath
                          lease:(DSHLocalProjectLease *)lease
                          error:(NSError **)error {
  NSArray<NSString *> *components = [relativePath componentsSeparatedByString:@"/"];
  int current = dup(lease.repositoryDescriptor);
  if (current < 0) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorProjectUnavailable);
    return nil;
  }
  for (NSUInteger index = 0; index + 1 < components.count; index++) {
    NSString *component = components[index];
    struct stat before = {};
    if (fstatat(current, component.fileSystemRepresentation, &before,
                AT_SYMLINK_NOFOLLOW) != 0) {
      close(current);
      return @{
        @"reason" : DSHProjectContextOmissionReasonPolicy,
        @"observation_sha256" : DSHServiceSHA256(
            DSHCanonicalJSON(@{
              @"state" : @"missing_ancestor",
              @"component_index" : @(index),
            }) ?: NSData.data),
      };
    }
    if (!S_ISDIR(before.st_mode) ||
        before.st_dev != lease.repositoryDevice) {
      NSDictionary *ancestor = DSHServiceObservation(before);
      close(current);
      NSDictionary *boundObservation = @{
        @"state" : @"unsafe_ancestor",
        @"component_index" : @(index),
        @"metadata" : ancestor[@"metadata"],
      };
      return @{
        @"reason" : DSHProjectContextOmissionReasonPolicy,
        @"metadata" : ancestor[@"metadata"],
        @"observation_sha256" : DSHServiceSHA256(
            DSHCanonicalJSON(boundObservation) ?: NSData.data),
      };
    }
    int next = openat(current, component.fileSystemRepresentation,
                      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    struct stat opened = {};
    BOOL valid = next >= 0 && fstat(next, &opened) == 0 &&
                 DSHServiceSameStat(before, opened);
    close(current);
    if (!valid) {
      if (next >= 0) close(next);
      DSHSetServiceError(error, DSHProjectContextServiceErrorChanged);
      return nil;
    }
    current = next;
  }
  NSString *filename = components.lastObject;
  struct stat before = {};
  if (fstatat(current, filename.fileSystemRepresentation, &before,
              AT_SYMLINK_NOFOLLOW) != 0) {
    close(current);
    return @{
      @"reason" : DSHProjectContextOmissionReasonPolicy,
      @"observation_sha256" : DSHServiceSHA256(
          DSHCanonicalJSON(@{@"state" : @"missing"}) ?: NSData.data),
    };
  }
  NSDictionary *observation = DSHServiceObservation(before);
  if (!S_ISREG(before.st_mode) || before.st_nlink != 1 ||
      before.st_dev != lease.repositoryDevice) {
    close(current);
    return @{
      @"reason" : DSHProjectContextOmissionReasonPolicy,
      @"metadata" : observation[@"metadata"],
      @"observation_sha256" : observation[@"observation_sha256"],
    };
  }
  if (before.st_size < 0 ||
      before.st_size > (off_t)DSHProjectContextMaxFileBytes) {
    close(current);
    return @{
      @"reason" : DSHProjectContextOmissionReasonBudgetExceeded,
      @"metadata" : observation[@"metadata"],
      @"observation_sha256" : observation[@"observation_sha256"],
    };
  }
  if (self.hook != nil) self.hook(@"before_file_open", relativePath);
  int descriptor = openat(current, filename.fileSystemRepresentation,
                          O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW);
  close(current);
  if (descriptor < 0) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorChanged);
    return nil;
  }
  if (self.hook != nil) self.hook(@"after_file_open", relativePath);
  struct stat opened = {};
  BOOL valid = fstat(descriptor, &opened) == 0 &&
               DSHServiceSameStat(before, opened);
  NSMutableData *data =
      valid ? [NSMutableData dataWithLength:(NSUInteger)opened.st_size] : nil;
  NSUInteger offset = 0;
  while (valid && offset < data.length) {
    ssize_t count = pread(descriptor,
                          static_cast<uint8_t *>(data.mutableBytes) + offset,
                          data.length - offset, (off_t)offset);
    if (count <= 0) {
      valid = NO;
      break;
    }
    offset += (NSUInteger)count;
  }
  if (self.hook != nil) self.hook(@"after_file_read", relativePath);
  struct stat after = {};
  valid = valid && fstat(descriptor, &after) == 0 &&
          DSHServiceSameStat(opened, after);
  close(descriptor);
  int directory = dup(lease.repositoryDescriptor);
  for (NSUInteger index = 0; valid && index + 1 < components.count; index++) {
    int next = openat(directory, components[index].fileSystemRepresentation,
                      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    close(directory);
    directory = next;
    valid = directory >= 0;
  }
  struct stat pathAfter = {};
  valid = valid && directory >= 0 &&
          fstatat(directory, filename.fileSystemRepresentation, &pathAfter,
                  AT_SYMLINK_NOFOLLOW) == 0 &&
          DSHServiceSameStat(after, pathAfter);
  if (directory >= 0) close(directory);
  if (!valid) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorChanged);
    return nil;
  }
  DSHProjectContextContentDecision *content =
      [self.policy decisionForContentData:data];
  if (!content.eligible) return @{
    @"reason" : content.omissionReason,
    @"metadata" : DSHServiceStatDescriptor(after),
    @"observation_sha256" : DSHServiceSHA256(data),
  };
  DSHProjectContextSecretDecision *secret =
      [self.policy secretDecisionForData:data];
  if (secret.suspectedSecret) return @{
    @"reason" : secret.omissionReason,
    @"metadata" : DSHServiceStatDescriptor(after),
    @"observation_sha256" : DSHServiceSHA256(data),
  };
  return @{
    @"data" : data,
    @"sha256" : DSHServiceSHA256(data),
    @"metadata" : DSHServiceStatDescriptor(after),
  };
}

- (NSDictionary *)validatedBlob:(git_blob *)blob {
  if (blob == nullptr) return @{@"data" : NSData.data};
  git_object_size_t size = git_blob_rawsize(blob);
  if (size < 0 || size > DSHProjectContextMaxFileBytes) {
    return @{@"reason" : DSHProjectContextOmissionReasonBudgetExceeded};
  }
  NSData *data = [NSData dataWithBytes:git_blob_rawcontent(blob)
                                length:(NSUInteger)size];
  DSHProjectContextContentDecision *content =
      [self.policy decisionForContentData:data];
  if (!content.eligible) return @{@"reason" : content.omissionReason};
  DSHProjectContextSecretDecision *secret =
      [self.policy secretDecisionForData:data];
  return secret.suspectedSecret ? @{@"reason" : secret.omissionReason}
                                : @{@"data" : data};
}

static int DSHAppendSerializedPatchLine(__unused const git_diff_delta *delta,
                                        __unused const git_diff_hunk *hunk,
                                        const git_diff_line *line,
                                        void *payload) {
  if (line == nullptr || payload == nullptr ||
      (line->content_len > 0 && line->content == nullptr)) {
    return -1;
  }
  NSMutableData *expected = (__bridge NSMutableData *)payload;
  if (line->origin == GIT_DIFF_LINE_CONTEXT ||
      line->origin == GIT_DIFF_LINE_ADDITION ||
      line->origin == GIT_DIFF_LINE_DELETION) {
    [expected appendBytes:&line->origin length:1];
  }
  if (line->content_len > 0) {
    [expected appendBytes:line->content length:line->content_len];
  }
  return 0;
}

- (NSData *)serializedPatch:(git_patch *)patch {
  if (patch == nullptr) return nil;
  // git_patch_size intentionally omits some extended file-header bytes even
  // when include_file_headers is set. Build an independent complete expected
  // serialization through the checked print callback, then require the buffer
  // API to match it byte-for-byte.
  size_t accountedSize = git_patch_size(patch, 1, 1, 1);
  NSMutableData *expected = [NSMutableData data];
  int printResult = git_patch_print(
      patch, DSHAppendSerializedPatchLine, (__bridge void *)expected);
  git_buf buffer = GIT_BUF_INIT;
  int result = git_patch_to_buf(&buffer, patch);
  NSData *data = result == 0 && buffer.ptr != nullptr
                     ? [NSData dataWithBytes:buffer.ptr length:buffer.size]
                     : nil;
  git_buf_dispose(&buffer);
  if (printResult != 0 || result != 0 || accountedSize == 0 ||
      expected.length == 0 || data.length != expected.length ||
      accountedSize > expected.length || ![data isEqualToData:expected]) {
    return nil;
  }
  // The per-file content and secret gates already validated both complete
  // sides. A complete patch has its own 128 KiB budget and may legitimately
  // exceed the 64 KiB single-file gate, so validate encoding/framing here
  // without reapplying the smaller file limit.
  const uint8_t *bytes = static_cast<const uint8_t *>(data.bytes);
  for (NSUInteger index = 0; index < data.length; index++) {
    uint8_t byte = bytes[index];
    if (byte == 0 || (byte < 0x20 && byte != '\n' && byte != '\r' &&
                      byte != '\t')) {
      return nil;
    }
  }
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
             .length > 0
             ? data
             : nil;
}

- (void)addOmissionPath:(NSString *)path
                  reason:(NSString *)reason
                 omitted:(NSMutableArray<NSDictionary *> *)omitted {
  for (NSDictionary *existing in omitted) {
    if ([existing[@"path"] isEqual:path] &&
        [existing[@"reason"] isEqual:reason]) {
      return;
    }
  }
  [omitted addObject:@{
    @"path" : path,
    @"reason" : reason ?: DSHProjectContextOmissionReasonPolicy,
  }];
}

- (NSDictionary *)captureLease:(DSHLocalProjectLease *)lease
                  selectedPaths:(NSArray<NSString *> *)selectedPaths
                   includeBlocks:(BOOL)includeBlocks
                          start:(NSDate *)start
                          error:(NSError **)error {
  git_repository *repository = lease.repository;
  __block git_index *index = nullptr;
  __block git_tree *headTree = nullptr;
  __block git_reference *head = nullptr;
  __block git_diff *stagedDiff = nullptr;
  __block git_diff *worktreeDiff = nullptr;
  @try {
    int result = git_repository_index(&index, repository);
    if (result == 0) result = git_index_read(index, 1);
    if (result < 0 || index == nullptr) {
      DSHSetServiceError(error,
                         DSHProjectContextServiceErrorProjectUnavailable);
      return nil;
    }
    size_t rawEntryCount = git_index_entrycount(index);
    if (rawEntryCount > DSHProjectContextMaxEntries) {
      DSHSetServiceError(error,
                         DSHProjectContextServiceErrorBudgetExceeded);
      return nil;
    }

    NSString *branch = nil;
    NSString *headOid = nil;
    NSString *headTarget = nil;
    int headResult = git_repository_head(&head, repository);
    if (headResult == 0 && head != nullptr) {
      headOid = DSHServiceOid(git_reference_target(head));
      if (git_reference_is_branch(head)) {
        const char *name = git_reference_shorthand(head);
        branch = name == nullptr ? nil : [NSString stringWithUTF8String:name];
      }
      git_commit *commit = nullptr;
      int commitResult = git_commit_lookup(&commit, repository,
                                           git_reference_target(head));
      int treeResult = commitResult == 0
          ? git_commit_tree(&headTree, commit)
          : commitResult;
      if (commit != nullptr) git_commit_free(commit);
      if (commitResult != 0 || treeResult != 0 || headTree == nullptr) {
        DSHSetServiceError(error, DSHProjectContextServiceErrorIntegrity);
        return nil;
      }
    } else if (headResult == GIT_EUNBORNBRANCH ||
               headResult == GIT_ENOTFOUND) {
      git_reference *symbolic = nullptr;
      if (git_reference_lookup(&symbolic, repository, "HEAD") == 0 &&
          symbolic != nullptr) {
        const char *target = git_reference_symbolic_target(symbolic);
        headTarget =
            target == nullptr ? nil : [NSString stringWithUTF8String:target];
        if ([headTarget hasPrefix:@"refs/heads/"]) {
          branch = [headTarget substringFromIndex:11];
        }
        git_reference_free(symbolic);
      }
    } else {
      DSHSetServiceError(error,
                         DSHProjectContextServiceErrorProjectUnavailable);
      return nil;
    }

    NSMutableDictionary<NSString *, NSMutableDictionary *> *candidateByPath =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *rawByNormalized =
        [NSMutableDictionary dictionary];
    NSMutableArray<NSDictionary *> *indexRows = [NSMutableArray array];
    NSMutableSet<NSString *> *conflictPaths = [NSMutableSet set];
    for (size_t item = 0; item < rawEntryCount; item++) {
      const git_index_entry *entry = git_index_get_byindex(index, item);
      NSString *rawPath = entry == nullptr || entry->path == nullptr
                              ? nil
                              : [NSString stringWithUTF8String:entry->path];
      if (rawPath == nil) {
        DSHSetServiceError(error, DSHProjectContextServiceErrorIntegrity);
        return nil;
      }
      DSHProjectContextPathDecision *pathDecision =
          [self.policy decisionForRelativePath:rawPath];
      NSString *path = pathDecision.normalizedPath;
      NSString *existingRaw = rawByNormalized[path];
      if (path.length == 0 || ![path isEqualToString:rawPath] ||
          (existingRaw != nil && ![existingRaw isEqualToString:rawPath])) {
        DSHSetServiceError(error, DSHProjectContextServiceErrorIntegrity);
        return nil;
      }
      rawByNormalized[path] = rawPath;
      NSUInteger stage = git_index_entry_stage(entry);
      [indexRows addObject:@{
        @"path" : path,
        @"stage" : @(stage),
        @"mode" : @(entry->mode),
        @"size" : @(entry->file_size),
        @"oid" : DSHServiceOid(&entry->id) ?: @"",
      }];
      if (stage != 0) {
        [conflictPaths addObject:path];
        continue;
      }
      BOOL regularMode = entry->mode == GIT_FILEMODE_BLOB ||
                         entry->mode == GIT_FILEMODE_BLOB_EXECUTABLE;
      BOOL eligible = pathDecision.eligible && regularMode &&
                      entry->file_size <= DSHProjectContextMaxFileBytes;
      NSString *reason = pathDecision.omissionReason;
      if (pathDecision.eligible && !regularMode) {
        reason = DSHProjectContextOmissionReasonPolicy;
      } else if (pathDecision.eligible && regularMode &&
                 entry->file_size > DSHProjectContextMaxFileBytes) {
        reason = DSHProjectContextOmissionReasonBudgetExceeded;
      }
      candidateByPath[path] = [@{
        @"path" : path,
        @"size" : @(entry->file_size),
        @"revision" : DSHServiceOid(&entry->id) ?: @"",
        @"git_state" : @"unchanged",
        @"eligible" : @(eligible),
        @"omission_reason" :
            eligible ? NSNull.null
                     : (reason ?: DSHProjectContextOmissionReasonPolicy),
        @"staged" : @NO,
        @"unstaged" : @NO,
        @"conflicted" : @NO,
      } mutableCopy];
    }
    [indexRows sortUsingComparator:^NSComparisonResult(NSDictionary *left,
                                                       NSDictionary *right) {
      NSComparisonResult pathResult = [left[@"path"] compare:right[@"path"]];
      return pathResult == NSOrderedSame
                 ? [left[@"stage"] compare:right[@"stage"]]
                 : pathResult;
    }];

    git_diff_options diffOptions = GIT_DIFF_OPTIONS_INIT;
    diffOptions.flags = GIT_DIFF_INCLUDE_TYPECHANGE |
                        GIT_DIFF_INCLUDE_TYPECHANGE_TREES |
                        GIT_DIFF_IGNORE_SUBMODULES |
                        GIT_DIFF_DISABLE_PATHSPEC_MATCH;
    diffOptions.context_lines = 3;
    diffOptions.interhunk_lines = 0;
    diffOptions.id_abbrev = GIT_OID_SHA1_HEXSIZE;
    diffOptions.max_size = DSHProjectContextMaxFileBytes + 1;
    diffOptions.old_prefix = "a";
    diffOptions.new_prefix = "b";
    result = git_diff_tree_to_index(&stagedDiff, repository, headTree, index,
                                    &diffOptions);
    if (result == 0) {
      result = git_diff_index_to_workdir(&worktreeDiff, repository, index,
                                         &diffOptions);
    }
    if (result < 0 || stagedDiff == nullptr || worktreeDiff == nullptr) {
      DSHSetServiceError(error,
                         DSHProjectContextServiceErrorProjectUnavailable);
      return nil;
    }
    git_diff_find_options findOptions = GIT_DIFF_FIND_OPTIONS_INIT;
    findOptions.flags = GIT_DIFF_FIND_RENAMES;
    findOptions.rename_limit = DSHProjectContextMaxChangedPaths;
    if (git_diff_find_similar(stagedDiff, &findOptions) != 0 ||
        git_diff_find_similar(worktreeDiff, &findOptions) != 0) {
      DSHSetServiceError(error, DSHProjectContextServiceErrorIntegrity);
      return nil;
    }

    NSMutableArray<NSDictionary *> *statusRows = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *disclosedStatusRows = [NSMutableArray array];
    NSMutableSet<NSString *> *changedPaths = [NSMutableSet set];
    for (NSUInteger kind = 0; kind < 2; kind++) {
      git_diff *diff = kind == 0 ? stagedDiff : worktreeDiff;
      size_t count = git_diff_num_deltas(diff);
      for (size_t item = 0; item < count; item++) {
        const git_diff_delta *delta = git_diff_get_delta(diff, item);
        NSString *oldPath = DSHServiceDeltaPath(delta, NO);
        NSString *newPath = DSHServiceDeltaPath(delta, YES);
        NSArray *rawPaths = @[ oldPath ?: @"", newPath ?: @"" ];
        for (NSString *raw in rawPaths) {
          if (raw.length == 0) continue;
          DSHProjectContextPathDecision *decision =
              [self.policy decisionForRelativePath:raw];
          if (decision.normalizedPath.length == 0 ||
              ![decision.normalizedPath isEqualToString:raw]) {
            DSHSetServiceError(error, DSHProjectContextServiceErrorIntegrity);
            return nil;
          }
          [changedPaths addObject:raw];
          NSMutableDictionary *candidate = candidateByPath[raw];
          if (candidate != nil) {
            candidate[kind == 0 ? @"staged" : @"unstaged"] = @YES;
          }
        }
        NSDictionary *statusRow = @{
          @"kind" : kind == 0 ? @"staged" : @"worktree",
          @"status" :
              @(delta == nullptr ? GIT_DELTA_UNMODIFIED : delta->status),
          @"old_path" : oldPath ?: @"",
          @"new_path" : newPath ?: @"",
          @"old_mode" : @(delta == nullptr ? 0 : delta->old_file.mode),
          @"new_mode" : @(delta == nullptr ? 0 : delta->new_file.mode),
          @"old_oid" :
              delta == nullptr ? @"" : (DSHServiceOid(&delta->old_file.id) ?: @""),
          @"new_oid" :
              delta == nullptr ? @"" : (DSHServiceOid(&delta->new_file.id) ?: @""),
        };
        [statusRows addObject:statusRow];
        DSHProjectContextPathDecision *oldDisclosure = oldPath.length == 0
            ? nil : [self.policy decisionForRelativePath:oldPath];
        DSHProjectContextPathDecision *newDisclosure = newPath.length == 0
            ? nil : [self.policy decisionForRelativePath:newPath];
        [disclosedStatusRows addObject:@{
          @"kind" : statusRow[@"kind"],
          @"status" : statusRow[@"status"],
          @"old_path" : oldDisclosure.eligible ? oldDisclosure.normalizedPath
                                                : NSNull.null,
          @"new_path" : newDisclosure.eligible ? newDisclosure.normalizedPath
                                                : NSNull.null,
          @"old_restricted" : @(oldDisclosure != nil && !oldDisclosure.eligible),
          @"new_restricted" : @(newDisclosure != nil && !newDisclosure.eligible),
        }];
      }
    }
    for (NSString *path in conflictPaths) {
      [changedPaths addObject:path];
      NSMutableDictionary *candidate = candidateByPath[path];
      if (candidate == nil) {
        NSMutableArray *conflictRows = [NSMutableArray array];
        for (NSDictionary *row in indexRows) {
          if ([row[@"path"] isEqual:path]) [conflictRows addObject:row];
        }
        candidate = [@{
          @"path" : path,
          @"size" : @0,
          @"revision" :
              DSHServiceSHA256(DSHCanonicalJSON(conflictRows) ?: NSData.data),
          @"git_state" : @"conflicted",
          @"eligible" : @NO,
          @"omission_reason" : DSHProjectContextOmissionReasonPolicy,
          @"staged" : @NO,
          @"unstaged" : @NO,
          @"conflicted" : @YES,
        } mutableCopy];
        candidateByPath[path] = candidate;
      } else {
        candidate[@"conflicted"] = @YES;
        candidate[@"eligible"] = @NO;
        candidate[@"omission_reason"] =
            DSHProjectContextOmissionReasonPolicy;
      }
    }
    if (changedPaths.count > DSHProjectContextMaxChangedPaths) {
      DSHSetServiceError(error,
                         DSHProjectContextServiceErrorBudgetExceeded);
      return nil;
    }
    [statusRows sortUsingComparator:^NSComparisonResult(NSDictionary *left,
                                                        NSDictionary *right) {
      NSString *leftText = [[NSString alloc]
          initWithData:DSHCanonicalJSON(left)
              encoding:NSUTF8StringEncoding];
      NSString *rightText = [[NSString alloc]
          initWithData:DSHCanonicalJSON(right)
              encoding:NSUTF8StringEncoding];
      return [leftText compare:rightText];
    }];
    [disclosedStatusRows sortUsingComparator:^NSComparisonResult(NSDictionary *left,
                                                                 NSDictionary *right) {
      NSString *leftText = [[NSString alloc]
          initWithData:DSHCanonicalJSON(left) encoding:NSUTF8StringEncoding];
      NSString *rightText = [[NSString alloc]
          initWithData:DSHCanonicalJSON(right) encoding:NSUTF8StringEncoding];
      return [leftText compare:rightText];
    }];

    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
    NSArray<NSString *> *candidatePaths =
        [candidateByPath.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *path in candidatePaths) {
      NSMutableDictionary *candidate = candidateByPath[path];
      candidate[@"git_state"] = DSHServiceGitState(
          [candidate[@"staged"] boolValue],
          [candidate[@"unstaged"] boolValue],
          [candidate[@"conflicted"] boolValue]);
      [candidate removeObjectsForKeys:
                     @[@"staged", @"unstaged", @"conflicted"]];
      [candidates addObject:candidate];
    }

    NSMutableOrderedSet<NSString *> *effectiveSelection =
        [NSMutableOrderedSet orderedSet];
    for (NSString *selectionPath in selectedPaths) {
      if (candidateByPath[selectionPath] != nil) {
        [effectiveSelection addObject:selectionPath];
        continue;
      }
      NSString *prefix = [selectionPath stringByAppendingString:@"/"];
      BOOL expanded = NO;
      for (NSString *candidatePath in candidatePaths) {
        if ([candidatePath hasPrefix:prefix]) {
          [effectiveSelection addObject:candidatePath];
          expanded = YES;
        }
      }
      if (!expanded) [effectiveSelection addObject:selectionPath];
    }
    NSArray<NSString *> *effectiveSelectedPaths =
        [effectiveSelection.array sortedArrayUsingSelector:@selector(compare:)];

    NSMutableArray<NSDictionary *> *blocks = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *omitted = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSDictionary *> *safeFiles =
        [NSMutableDictionary dictionary];
    NSMutableArray<NSDictionary *> *selectedStates = [NSMutableArray array];
    for (NSString *path in effectiveSelectedPaths) {
      NSDictionary *candidate = candidateByPath[path];
      if (candidate == nil) {
        [self addOmissionPath:path
                       reason:DSHProjectContextOmissionReasonNotTracked
                      omitted:omitted];
        [selectedStates addObject:@{@"path" : path, @"state" : @"not_tracked"}];
        continue;
      }
      NSString *revision = candidate[@"revision"];
      if (revision.length == GIT_OID_SHA1_HEXSIZE) {
        git_oid oid = {};
        git_blob *selectedBlob = nullptr;
        int oidResult = git_oid_fromstr(&oid, revision.UTF8String);
        int blobResult = oidResult == 0
            ? git_blob_lookup(&selectedBlob, repository, &oid)
            : oidResult;
        if (selectedBlob != nullptr) git_blob_free(selectedBlob);
        if (oidResult != 0 || blobResult != 0) {
          DSHSetServiceError(error, DSHProjectContextServiceErrorIntegrity);
          return nil;
        }
      }
      if (![candidate[@"eligible"] boolValue]) {
        NSString *reason = candidate[@"omission_reason"] == NSNull.null
                               ? DSHProjectContextOmissionReasonPolicy
                               : candidate[@"omission_reason"];
        [self addOmissionPath:path reason:reason omitted:omitted];
        [selectedStates addObject:@{
          @"path" : path,
          @"state" : @"omitted",
          @"reason" : reason,
          @"revision" : candidate[@"revision"],
        }];
        continue;
      }
      if (safeFiles.count >= DSHProjectContextMaxFiles) {
        [self addOmissionPath:path
                       reason:DSHProjectContextOmissionReasonBudgetExceeded
                      omitted:omitted];
        [selectedStates addObject:@{
          @"path" : path,
          @"state" : @"omitted",
          @"reason" : DSHProjectContextOmissionReasonBudgetExceeded,
          @"revision" : candidate[@"revision"],
        }];
        continue;
      }
      NSDictionary *safe = [self safeReadPath:path lease:lease error:error];
      if (safe == nil) return nil;
      if (safe[@"data"] == nil) {
        NSString *reason =
            safe[@"reason"] ?: DSHProjectContextOmissionReasonPolicy;
        [self addOmissionPath:path reason:reason omitted:omitted];
        NSMutableDictionary *state = [@{
          @"path" : path,
          @"state" : @"omitted",
          @"reason" : reason,
          @"revision" : candidate[@"revision"],
        } mutableCopy];
        if (safe[@"metadata"] != nil) state[@"metadata"] = safe[@"metadata"];
        if (safe[@"observation_sha256"] != nil) {
          state[@"observation_sha256"] = safe[@"observation_sha256"];
        }
        [selectedStates addObject:state];
        continue;
      }
      safeFiles[path] = safe;
      [selectedStates addObject:@{
        @"path" : path,
        @"state" : @"included",
        @"revision" : candidate[@"revision"],
        @"content_sha256" : safe[@"sha256"],
        @"metadata" : safe[@"metadata"],
      }];
      if (includeBlocks) {
        [blocks addObject:@{
          @"path" : path,
          @"source" : @"tracked_file",
          @"data" : safe[@"data"],
        }];
      }
    }
    if (![self deadlineFrom:start error:error]) return nil;

    if (includeBlocks) {
      for (NSUInteger kind = 0; kind < 2; kind++) {
        git_diff *diff = kind == 0 ? stagedDiff : worktreeDiff;
        size_t count = git_diff_num_deltas(diff);
        for (size_t item = 0; item < count; item++) {
          const git_diff_delta *delta = git_diff_get_delta(diff, item);
          NSString *oldPath = DSHServiceDeltaPath(delta, NO);
          NSString *newPath = DSHServiceDeltaPath(delta, YES);
          NSString *selectedPath = [effectiveSelectedPaths containsObject:newPath]
                                       ? newPath
                                       : ([effectiveSelectedPaths containsObject:oldPath]
                                              ? oldPath
                                              : nil);
          if (selectedPath == nil ||
              [conflictPaths containsObject:selectedPath]) {
            continue;
          }
          // A patch is disclosure too. If the selected worktree path did not
          // pass the descriptor-bound file read, no index/blob side may be
          // used as a fallback source of content.
          if (safeFiles[selectedPath] == nil) continue;
          DSHProjectContextPathDecision *oldDecision = oldPath.length == 0
              ? nil
              : [self.policy decisionForRelativePath:oldPath];
          DSHProjectContextPathDecision *newDecision = newPath.length == 0
              ? nil
              : [self.policy decisionForRelativePath:newPath];
          if ((oldDecision != nil && !oldDecision.eligible) ||
              (newDecision != nil && !newDecision.eligible)) {
            NSString *reason = oldDecision != nil && !oldDecision.eligible
                                   ? oldDecision.omissionReason
                                   : newDecision.omissionReason;
            [self addOmissionPath:selectedPath
                           reason:reason ?: DSHProjectContextOmissionReasonPolicy
                          omitted:omitted];
            continue;
          }
          git_blob *oldBlob = nullptr;
          git_blob *newBlob = nullptr;
          if (delta != nullptr && !git_oid_is_zero(&delta->old_file.id)) {
            if (git_blob_lookup(&oldBlob, repository, &delta->old_file.id) != 0 ||
                oldBlob == nullptr) {
              DSHSetServiceError(error, DSHProjectContextServiceErrorIntegrity);
              return nil;
            }
          }
          if (kind == 0 && delta != nullptr &&
              !git_oid_is_zero(&delta->new_file.id)) {
            if (git_blob_lookup(&newBlob, repository, &delta->new_file.id) != 0 ||
                newBlob == nullptr) {
              if (oldBlob != nullptr) git_blob_free(oldBlob);
              DSHSetServiceError(error, DSHProjectContextServiceErrorIntegrity);
              return nil;
            }
          }
          NSDictionary *oldValidation = [self validatedBlob:oldBlob];
          NSDictionary *newValidation = kind == 0
                                            ? [self validatedBlob:newBlob]
                                            : safeFiles[selectedPath];
          NSString *reason =
              oldValidation[@"reason"] ?: newValidation[@"reason"];
          BOOL deletion = delta != nullptr && delta->status == GIT_DELTA_DELETED;
          if (reason != nil ||
              (kind == 1 && newValidation == nil && !deletion)) {
            [self addOmissionPath:selectedPath
                           reason:reason ?: DSHProjectContextOmissionReasonPolicy
                          omitted:omitted];
            if (newBlob != nullptr) git_blob_free(newBlob);
            if (oldBlob != nullptr) git_blob_free(oldBlob);
            continue;
          }
          git_diff_options patchOptions = diffOptions;
          patchOptions.flags |= GIT_DIFF_FORCE_TEXT;
          git_patch *patch = nullptr;
          int patchResult = 0;
          if (kind == 0) {
            patchResult = git_patch_from_blobs(
                &patch, oldBlob, oldPath.UTF8String, newBlob,
                newPath.UTF8String, &patchOptions);
          } else {
            NSData *newData = newValidation[@"data"] ?: NSData.data;
            patchResult = git_patch_from_blob_and_buffer(
                &patch, oldBlob, oldPath.UTF8String, newData.bytes,
                newData.length, newPath.UTF8String, &patchOptions);
          }
          NSData *patchData =
              patchResult == 0 ? [self serializedPatch:patch] : nil;
          if (patch != nullptr) git_patch_free(patch);
          if (newBlob != nullptr) git_blob_free(newBlob);
          if (oldBlob != nullptr) git_blob_free(oldBlob);
          if (patchResult != 0 || patchData == nil) {
            DSHSetServiceError(error, DSHProjectContextServiceErrorIntegrity);
            return nil;
          }
          [blocks addObject:@{
            @"path" : selectedPath,
            @"source" : kind == 0 ? @"staged_diff" : @"worktree_diff",
            @"data" : patchData,
          }];
        }
      }
    }

    NSString *indexChecksum =
        DSHServiceOid(git_index_checksum(index)) ?: @"none";
    NSString *projectMetadataDigest = (id)lease == self.borrowedLegacyLease
        ? DSHServiceSHA256(DSHCanonicalJSON(lease.metadata) ?: NSData.data)
        : [self.projectAccess projectMetadataDigestFromLease:lease error:nil];
    if (projectMetadataDigest == nil) {
      DSHSetServiceError(error, DSHProjectContextServiceErrorIntegrity);
      return nil;
    }
    NSData *indexDigestData = DSHCanonicalJSON(indexRows) ?: NSData.data;
    NSData *statusDigestData = DSHCanonicalJSON(statusRows) ?: NSData.data;
    NSDictionary *fingerprintInput = @{
      @"policy_version" : DSHProjectContextPolicyVersion,
      @"project_id" : lease.projectId,
      @"projects_root_device" : @((unsigned long long)lease.projectsRootDevice),
      @"projects_root_inode" : @((unsigned long long)lease.projectsRootInode),
      @"project_device" : @((unsigned long long)lease.projectDevice),
      @"project_inode" : @((unsigned long long)lease.projectInode),
      @"repository_device" : @((unsigned long long)lease.repositoryDevice),
      @"repository_inode" : @((unsigned long long)lease.repositoryInode),
      @"git_device" : @((unsigned long long)lease.gitDevice),
      @"git_inode" : @((unsigned long long)lease.gitInode),
      @"objects_device" : @((unsigned long long)lease.objectsDevice),
      @"objects_inode" : @((unsigned long long)lease.objectsInode),
      @"project_metadata_sha256" : projectMetadataDigest,
      @"repository_state" : @(git_repository_state(repository)),
      @"branch" : branch ?: NSNull.null,
      @"head_oid" : headOid ?: NSNull.null,
      @"head_target" : headTarget ?: NSNull.null,
      @"index_checksum" : indexChecksum,
      @"index_digest" : DSHServiceSHA256(indexDigestData),
      @"status_digest" : DSHServiceSHA256(statusDigestData),
      @"selection_intent" : selectedPaths,
      @"selected_paths" : effectiveSelectedPaths,
      @"selected_states" : selectedStates,
    };
    NSString *fingerprint =
        DSHServiceSHA256(DSHCanonicalJSON(fingerprintInput) ?: NSData.data);
    return @{
      @"branch" : branch ?: NSNull.null,
      @"head_oid" : headOid ?: NSNull.null,
      @"clean" : @(changedPaths.count == 0),
      @"conflicted" : @(conflictPaths.count > 0 ||
                         git_repository_state(repository) !=
                             GIT_REPOSITORY_STATE_NONE),
      @"source_fingerprint" : fingerprint,
      @"candidates" : candidates,
      @"blocks" : blocks,
      @"omitted" : omitted,
      @"tracked_status" : disclosedStatusRows,
      @"expanded_paths" : effectiveSelectedPaths,
      @"fingerprint_input" : fingerprintInput,
      @"project_metadata_sha256" : projectMetadataDigest,
    };
  } @finally {
    if (worktreeDiff != nullptr) git_diff_free(worktreeDiff);
    if (stagedDiff != nullptr) git_diff_free(stagedDiff);
    if (head != nullptr) git_reference_free(head);
    if (headTree != nullptr) git_tree_free(headTree);
    if (index != nullptr) git_index_free(index);
  }
}

- (NSDictionary *)captureAndVerifyLease:(DSHLocalProjectLease *)lease
                           selectedPaths:(NSArray<NSString *> *)selectedPaths
                           includeBlocks:(BOOL)includeBlocks
                                   start:(NSDate *)start
                                   error:(NSError **)error {
  BOOL (^valid)(void) = ^BOOL {
    return (id)lease == self.borrowedLegacyLease
        ? [self.borrowedLegacyLease validateIdentity]
        : [self.projectAccess validateLeaseIdentity:lease error:nil];
  };
  if (!valid()) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorChanged);
    return nil;
  }
  NSDictionary *capture = [self captureLease:lease
                                selectedPaths:selectedPaths
                                includeBlocks:includeBlocks
                                        start:start
                                        error:error];
  if (capture == nil) return nil;
  if (self.hook != nil) self.hook(@"before_fingerprint_recheck", nil);
  if (!valid()) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorChanged);
    return nil;
  }
  NSDictionary *verification = [self captureLease:lease
                                     selectedPaths:selectedPaths
                                     includeBlocks:NO
                                             start:start
                                             error:error];
  if (verification == nil) return nil;
  if (!valid()) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorChanged);
    return nil;
  }
  if (![capture[@"source_fingerprint"]
          isEqualToString:verification[@"source_fingerprint"]]) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorChanged);
    return nil;
  }
  return capture;
}

- (NSDictionary *)metadataObservationForPath:(NSString *)relativePath
                                         lease:(DSHLocalProjectLease *)lease {
  NSArray<NSString *> *components = [relativePath componentsSeparatedByString:@"/"];
  int directory = dup(lease.repositoryDescriptor);
  if (directory < 0) return nil;
  for (NSUInteger index = 0; index + 1 < components.count; index++) {
    struct stat before = {};
    NSString *component = components[index];
    if (fstatat(directory, component.fileSystemRepresentation, &before,
                AT_SYMLINK_NOFOLLOW) != 0 || !S_ISDIR(before.st_mode) ||
        before.st_dev != lease.repositoryDevice) {
      close(directory);
      return @{
        @"exists" : @NO,
        @"safe_regular" : @NO,
        @"size" : @0,
        @"observation_sha256" : DSHServiceSHA256(DSHCanonicalJSON(@{
          @"state" : @"unsafe_ancestor", @"component_index" : @(index),
        }) ?: NSData.data),
      };
    }
    int next = openat(directory, component.fileSystemRepresentation,
                      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    struct stat opened = {};
    BOOL valid = next >= 0 && fstat(next, &opened) == 0 &&
                 DSHServiceSameStat(before, opened);
    close(directory);
    if (!valid) {
      if (next >= 0) close(next);
      return nil;
    }
    directory = next;
  }
  struct stat metadata = {};
  BOOL exists = fstatat(directory,
                        components.lastObject.fileSystemRepresentation,
                        &metadata, AT_SYMLINK_NOFOLLOW) == 0;
  close(directory);
  if (!exists) {
    return @{
      @"exists" : @NO,
      @"safe_regular" : @NO,
      @"size" : @0,
      @"observation_sha256" : DSHServiceSHA256(
          DSHCanonicalJSON(@{@"state" : @"missing"}) ?: NSData.data),
    };
  }
  NSDictionary *observation = DSHServiceObservation(metadata);
  return @{
    @"exists" : @YES,
    @"safe_regular" : @(S_ISREG(metadata.st_mode) && metadata.st_nlink == 1 &&
                           metadata.st_dev == lease.repositoryDevice),
    @"size" : metadata.st_size < 0 ? @0 : @((unsigned long long)metadata.st_size),
    @"mode" : @((unsigned long long)metadata.st_mode),
    @"metadata" : observation[@"metadata"],
    @"observation_sha256" : observation[@"observation_sha256"],
  };
}

- (NSDictionary *)metadataCandidateCaptureLease:(DSHLocalProjectLease *)lease
                                            start:(NSDate *)start
                                            error:(NSError **)error {
  BOOL borrowed = (id)lease == self.borrowedLegacyLease;
  if (!(borrowed ? [self.borrowedLegacyLease validateIdentity]
                 : [self.projectAccess validateLeaseIdentity:lease error:nil])) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorChanged);
    return nil;
  }
  git_index *index = nullptr;
  git_reference *head = nullptr;
  git_tree *headTree = nullptr;
  @try {
    if (git_repository_index(&index, lease.repository) != 0 || index == nullptr ||
        git_index_read(index, 1) != 0) {
      DSHSetServiceError(error, DSHProjectContextServiceErrorProjectUnavailable);
      return nil;
    }
    size_t count = git_index_entrycount(index);
    if (count > DSHProjectContextMaxEntries) {
      DSHSetServiceError(error, DSHProjectContextServiceErrorBudgetExceeded);
      return nil;
    }
    NSString *headOid = nil;
    NSString *branch = nil;
    NSString *headTarget = nil;
    int detachedResult = git_repository_head_detached(lease.repository);
    if (detachedResult < 0) {
      DSHSetServiceError(error, DSHProjectContextServiceErrorProjectUnavailable);
      return nil;
    }
    int headResult = git_repository_head(&head, lease.repository);
    if (headResult == 0 && head != nullptr) {
      headOid = DSHServiceOid(git_reference_target(head));
      if (git_reference_is_branch(head)) {
        const char *name = git_reference_shorthand(head);
        branch = name == nullptr ? nil : [NSString stringWithUTF8String:name];
      }
      git_commit *commit = nullptr;
      int commitResult = git_commit_lookup(&commit, lease.repository,
                                           git_reference_target(head));
      int treeResult = commitResult == 0 ? git_commit_tree(&headTree, commit)
                                         : commitResult;
      if (commit != nullptr) git_commit_free(commit);
      if (commitResult != 0 || treeResult != 0 || headTree == nullptr) {
        DSHSetServiceError(error, DSHProjectContextServiceErrorIntegrity);
        return nil;
      }
    } else if (headResult != GIT_EUNBORNBRANCH &&
               headResult != GIT_ENOTFOUND) {
      DSHSetServiceError(error, DSHProjectContextServiceErrorProjectUnavailable);
      return nil;
    }
    git_reference *symbolicHead = nullptr;
    int symbolicResult = git_reference_lookup(&symbolicHead, lease.repository,
                                              "HEAD");
    if (symbolicResult == 0 && symbolicHead != nullptr) {
      const char *target = git_reference_symbolic_target(symbolicHead);
      headTarget = target == nullptr ? nil : [NSString stringWithUTF8String:target];
      git_reference_free(symbolicHead);
    } else if (symbolicResult != GIT_ENOTFOUND) {
      if (symbolicHead != nullptr) git_reference_free(symbolicHead);
      DSHSetServiceError(error, DSHProjectContextServiceErrorIntegrity);
      return nil;
    }

    NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *rowsByPath =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSValue *> *stageZeroEntries =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *rawByNormalized =
        [NSMutableDictionary dictionary];
    for (size_t item = 0; item < count; item++) {
      const git_index_entry *entry = git_index_get_byindex(index, item);
      if (entry == nullptr || entry->path == nullptr) {
        DSHSetServiceError(error, DSHProjectContextServiceErrorIntegrity);
        return nil;
      }
      NSString *rawPath = [NSString stringWithUTF8String:entry->path];
      if (rawPath == nil) {
        DSHSetServiceError(error, DSHProjectContextServiceErrorIntegrity);
        return nil;
      }
      DSHProjectContextPathDecision *decision =
          [self.policy decisionForRelativePath:rawPath];
      NSString *path = decision.normalizedPath;
      if (path.length == 0 || ![rawPath isEqual:path]) {
        DSHSetServiceError(error, DSHProjectContextServiceErrorIntegrity);
        return nil;
      }
      NSString *existing = rawByNormalized[path];
      if (existing != nil && ![existing isEqual:rawPath]) {
        DSHSetServiceError(error, DSHProjectContextServiceErrorIntegrity);
        return nil;
      }
      rawByNormalized[path] = rawPath;
      NSUInteger stage = git_index_entry_stage(entry);
      NSMutableArray *rows = rowsByPath[path] ?: [NSMutableArray array];
      rowsByPath[path] = rows;
      [rows addObject:@{
        @"stage" : @(stage), @"mode" : @(entry->mode),
        @"size" : @(entry->file_size),
        @"oid" : DSHServiceOid(&entry->id) ?: @"",
      }];
      if (stage == 0) {
        stageZeroEntries[path] = [NSValue valueWithPointer:entry];
      }
    }

    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *fingerprintRows = [NSMutableArray array];
    NSArray<NSString *> *paths =
        [rowsByPath.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *path in paths) {
      NSArray<NSDictionary *> *rows = rowsByPath[path];
      const git_index_entry *entry =
          (const git_index_entry *)stageZeroEntries[path].pointerValue;
      if (entry == nullptr) {
        [candidates addObject:@{
          @"path" : path, @"size" : @0,
          @"revision" : DSHServiceSHA256(DSHCanonicalJSON(rows) ?: NSData.data),
          @"git_state" : @"conflicted", @"eligible" : @NO,
          @"omission_reason" : DSHProjectContextOmissionReasonPolicy,
        }];
        [fingerprintRows addObject:@{@"path" : path, @"index" : rows,
                                     @"live" : @"conflicted"}];
        continue;
      }
      NSDictionary *live = [self metadataObservationForPath:path lease:lease];
      if (live == nil) {
        DSHSetServiceError(error, DSHProjectContextServiceErrorChanged);
        return nil;
      }
      DSHProjectContextPathDecision *decision =
          [self.policy decisionForRelativePath:path];
      BOOL indexRegular = entry->mode == GIT_FILEMODE_BLOB ||
                          entry->mode == GIT_FILEMODE_BLOB_EXECUTABLE;
      BOOL liveRegular = [live[@"safe_regular"] boolValue];
      unsigned long long liveSize = 0;
      BOOL staged = headTree == nullptr;
      if (headTree != nullptr) {
        git_tree_entry *treeEntry = nullptr;
        int treeEntryResult = git_tree_entry_bypath(&treeEntry, headTree,
                                                    path.UTF8String);
        staged = treeEntryResult == GIT_ENOTFOUND ||
            (treeEntryResult == 0 &&
             (git_oid_cmp(git_tree_entry_id(treeEntry), &entry->id) != 0 ||
              git_tree_entry_filemode(treeEntry) != entry->mode));
        if (treeEntry != nullptr) git_tree_entry_free(treeEntry);
        if (treeEntryResult != 0 && treeEntryResult != GIT_ENOTFOUND) {
          DSHSetServiceError(error, DSHProjectContextServiceErrorIntegrity);
          return nil;
        }
      }
      NSDictionary *metadata = live[@"metadata"];
      unsigned long long liveMode = 0;
      unsigned long long liveDevice = 0;
      unsigned long long liveInode = 0;
      BOOL liveMetadataValid =
          DSHLocalProjectAccessParseCanonicalUInt64(live[@"size"],
                                                    &liveSize) &&
          DSHLocalProjectAccessParseCanonicalUInt64(metadata[@"mode"],
                                                    &liveMode) &&
          DSHLocalProjectAccessParseCanonicalUInt64(metadata[@"device"],
                                                    &liveDevice) &&
          DSHLocalProjectAccessParseCanonicalUInt64(metadata[@"inode"],
                                                    &liveInode);
      BOOL eligible = decision.eligible && indexRegular && liveRegular &&
                      liveSize <= DSHProjectContextMaxFileBytes;
      NSString *reason = decision.omissionReason;
      if (decision.eligible && (!indexRegular || !liveRegular)) {
        reason = DSHProjectContextOmissionReasonPolicy;
      } else if (decision.eligible && indexRegular && liveRegular &&
                 liveSize > DSHProjectContextMaxFileBytes) {
        reason = DSHProjectContextOmissionReasonBudgetExceeded;
      }
      uint32_t liveGitMode = (liveMode &
                              (S_IXUSR | S_IXGRP | S_IXOTH)) != 0
          ? GIT_FILEMODE_BLOB_EXECUTABLE : GIT_FILEMODE_BLOB;
      BOOL unstaged = ![live[@"exists"] boolValue] || !liveRegular ||
          !liveMetadataValid ||
          entry->file_size != liveSize ||
          entry->mode != liveGitMode ||
          entry->dev != (uint32_t)liveDevice ||
          entry->ino != (uint32_t)liveInode ||
          entry->mtime.seconds != [metadata[@"mtime_seconds"] intValue] ||
          entry->mtime.nanoseconds != [metadata[@"mtime_nanoseconds"] unsignedIntValue] ||
          entry->ctime.seconds != [metadata[@"ctime_seconds"] intValue] ||
          entry->ctime.nanoseconds != [metadata[@"ctime_nanoseconds"] unsignedIntValue];
      [candidates addObject:@{
        @"path" : path, @"size" : @(liveSize),
        @"revision" : DSHServiceOid(&entry->id) ?: @"",
        @"git_state" : DSHServiceGitState(staged, unstaged, NO),
        @"eligible" : @(eligible),
        @"omission_reason" : eligible ? NSNull.null :
            (reason ?: DSHProjectContextOmissionReasonPolicy),
      }];
      [fingerprintRows addObject:@{
        @"path" : path, @"index" : rows,
        @"live_observation_sha256" : live[@"observation_sha256"],
      }];
    }
    if (!(borrowed ? [self.borrowedLegacyLease validateIdentity]
                   : [self.projectAccess validateLeaseIdentity:lease error:nil]) ||
        ![self deadlineFrom:start error:error]) {
      if (error != nil && *error == nil) {
        DSHSetServiceError(error, DSHProjectContextServiceErrorChanged);
      }
      return nil;
    }
    NSDictionary *fingerprintInput = @{
      @"policy_version" : DSHProjectContextPolicyVersion,
      @"project_id" : lease.projectId,
      @"projects_root_device" : @((unsigned long long)lease.projectsRootDevice),
      @"projects_root_inode" : @((unsigned long long)lease.projectsRootInode),
      @"project_device" : @((unsigned long long)lease.projectDevice),
      @"project_inode" : @((unsigned long long)lease.projectInode),
      @"repository_device" : @((unsigned long long)lease.repositoryDevice),
      @"repository_inode" : @((unsigned long long)lease.repositoryInode),
      @"git_device" : @((unsigned long long)lease.gitDevice),
      @"git_inode" : @((unsigned long long)lease.gitInode),
      @"repository_state" : @(git_repository_state(lease.repository)),
      @"branch" : branch ?: NSNull.null,
      @"head_oid" : headOid ?: NSNull.null,
      @"head_target" : headTarget ?: NSNull.null,
      @"head_detached" : @(detachedResult == 1),
      @"index_checksum" : DSHServiceOid(git_index_checksum(index)) ?: @"none",
      @"rows" : fingerprintRows,
    };
    return @{
      @"candidates" : candidates,
      @"source_fingerprint" : DSHServiceSHA256(
          DSHCanonicalJSON(fingerprintInput) ?: NSData.data),
    };
  } @finally {
    if (headTree != nullptr) git_tree_free(headTree);
    if (head != nullptr) git_reference_free(head);
    if (index != nullptr) git_index_free(index);
  }
}

- (NSDictionary *)listCandidatesForProjectId:(NSString *)projectId
                                         query:(NSString *)query
                                        cursor:(NSString *)cursor
                                         error:(NSError **)error {
  NSDate *start = self.clock();
  if (![DSHLocalProjectAccess isCanonicalProjectId:projectId] ||
      ![query isKindOfClass:NSString.class] ||
      (cursor != nil && ![cursor isKindOfClass:NSString.class])) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorInvalidArgument);
    return nil;
  }
  NSError *accessError = nil;
  DSHLocalProjectLease *lease = [self.projectAccess
      leaseProjectId:projectId
                mode:DSHLocalProjectAccessModeRead
     includeMetadata:NO
             timeout:DSHProjectContextDeadlineSeconds
               error:&accessError];
  if (lease == nil) {
    DSHSetServiceError(
        error,
        [accessError.domain isEqual:DSHLocalProjectAccessErrorDomain] &&
                accessError.code == DSHLocalProjectAccessErrorLockTimeout
            ? DSHProjectContextServiceErrorTimeout
            : DSHProjectContextServiceErrorProjectUnavailable);
    return nil;
  }
  NSDictionary *capture = [self metadataCandidateCaptureLease:lease
                                                         start:start
                                                         error:error];
  if (capture == nil) return nil;
  NSError *policyError = nil;
  NSDictionary *page = [self.policy
      candidatePageForCandidates:capture[@"candidates"]
                           query:query
               sourceFingerprint:capture[@"source_fingerprint"]
                          cursor:cursor
                           limit:DSHProjectContextMaxCandidatePageSize
                           error:&policyError];
  if (page == nil) {
    DSHProjectContextServiceErrorCode serviceCode =
        DSHProjectContextServiceErrorInvalidArgument;
    if (policyError.code == DSHProjectContextPolicyErrorBudgetExceeded) {
      serviceCode = DSHProjectContextServiceErrorBudgetExceeded;
    } else if (policyError.code == DSHProjectContextPolicyErrorStaleCursor) {
      serviceCode = DSHProjectContextServiceErrorChanged;
    }
    DSHSetServiceError(error, serviceCode);
    return nil;
  }
  return @{
    @"schema_version" : @1,
    @"project_id" : projectId,
    @"candidates" : page[@"candidates"],
    @"next_cursor" : page[@"next_cursor"],
  };
}

- (NSData *)framedEnvelopeMetadata:(NSDictionary *)metadata
                             blocks:(NSArray<NSDictionary *> *)blocks
                           included:(NSMutableArray<NSDictionary *> *)included
                            omitted:(NSMutableArray<NSDictionary *> *)omitted
                              error:(NSError **)error {
  NSData *metadataData = DSHCanonicalJSON(metadata);
  if (metadataData == nil) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorIntegrity);
    return nil;
  }
  NSMutableData *envelope = [NSMutableData data];
  NSString *wireVersion = [metadata[@"schema_version"] isEqual:@2] ? @"2" : @"1";
  [envelope appendData:[[NSString stringWithFormat:
                              @"RISH-PROJECT-CONTEXT/%@\n", wireVersion]
                           dataUsingEncoding:NSUTF8StringEncoding]];
  [envelope appendData:[[NSString
      stringWithFormat:@"META %lu\n", (unsigned long)metadataData.length]
                           dataUsingEncoding:NSUTF8StringEncoding]];
  [envelope appendData:metadataData];
  [envelope appendBytes:"\n" length:1];
  NSArray<NSDictionary *> *sorted = [blocks
      sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left,
                                                     NSDictionary *right) {
        NSComparisonResult pathResult =
            [left[@"path"] compare:right[@"path"]];
        return pathResult == NSOrderedSame
                   ? [left[@"source"] compare:right[@"source"]]
                   : pathResult;
      }];
  NSUInteger diffBytes = 0;
  for (NSDictionary *block in sorted) {
    NSData *data = block[@"data"];
    NSString *path = block[@"path"];
    NSString *source = block[@"source"];
    NSString *digest = DSHServiceSHA256(data);
    NSDictionary *header = @{
      @"path" : path,
      @"source" : source,
      @"sha256" : digest,
      @"length" : @(data.length),
    };
    NSData *headerData = DSHCanonicalJSON(header);
    NSData *prefix = [[NSString
        stringWithFormat:@"BLOCK %lu %lu\n", (unsigned long)headerData.length,
                         (unsigned long)data.length]
        dataUsingEncoding:NSUTF8StringEncoding];
    NSUInteger frameBytes =
        prefix.length + headerData.length + 1 + data.length + 1;
    BOOL diff = ![source isEqual:@"tracked_file"];
    BOOL diffBudget =
        diff && diffBytes + data.length > DSHProjectContextMaxDiffBytes;
    BOOL contextBudget = envelope.length + frameBytes + 4 >
                         DSHProjectContextMaxContextBytes;
    if (diffBudget || contextBudget) {
      [self addOmissionPath:path
                     reason:DSHProjectContextOmissionReasonBudgetExceeded
                    omitted:omitted];
      continue;
    }
    [envelope appendData:prefix];
    [envelope appendData:headerData];
    [envelope appendBytes:"\n" length:1];
    [envelope appendData:data];
    [envelope appendBytes:"\n" length:1];
    if (diff) diffBytes += data.length;
    [included addObject:@{
      @"path" : path,
      @"source" : source,
      @"bytes" : @(data.length),
      @"sha256" : digest,
    }];
  }
  [envelope appendData:[@"END\n" dataUsingEncoding:NSUTF8StringEncoding]];
  if (envelope.length > DSHProjectContextMaxContextBytes) {
    DSHSetServiceError(error,
                       DSHProjectContextServiceErrorBudgetExceeded);
    return nil;
  }
  return envelope;
}

- (NSDictionary *)prepareSelection:(NSDictionary *)selection
                              error:(NSError **)error {
  NSDate *start = self.clock();
  NSDictionary *validated = [self validatedSelection:selection error:error];
  if (validated == nil || self.projectAccess == nil || self.store == nil ||
      self.policy == nil || self.clock == nil ||
      self.identifierGenerator == nil) {
    if (validated != nil) {
      DSHSetServiceError(error,
                         DSHProjectContextServiceErrorInvalidArgument);
    }
    return nil;
  }
  NSError *accessError = nil;
  DSHLocalProjectLease *lease = [self.projectAccess
      leaseProjectId:validated[@"project_id"]
                mode:DSHLocalProjectAccessModeRead
     includeMetadata:YES
             timeout:DSHProjectContextDeadlineSeconds
               error:&accessError];
  if (lease == nil) {
    DSHSetServiceError(
        error,
        [accessError.domain isEqual:DSHLocalProjectAccessErrorDomain] &&
                accessError.code == DSHLocalProjectAccessErrorLockTimeout
            ? DSHProjectContextServiceErrorTimeout
            : DSHProjectContextServiceErrorProjectUnavailable);
    return nil;
  }
  NSDictionary *capture = [self captureAndVerifyLease:lease
                                         selectedPaths:validated[@"selected_paths"]
                                         includeBlocks:YES
                                                 start:start
                                                 error:error];
  if (capture == nil) return nil;
  NSString *snapshotId = self.identifierGenerator();
  if (!DSHServiceCanonicalIdentifier(snapshotId)) {
    DSHSetServiceError(error,
                       DSHProjectContextServiceErrorInvalidArgument);
    return nil;
  }
  NSString *capturedAt = DSHServiceISO8601(self.clock());
  NSDictionary *envelopeMetadata = @{
    @"schema_version" : @1,
    @"snapshot_id" : snapshotId,
    @"project_id" : validated[@"project_id"],
    @"project_name" : lease.metadata[@"name"],
    @"conversation_id" : validated[@"conversation_id"],
    @"provider" : validated[@"provider"],
    @"model" : validated[@"model"],
    @"policy" : validated[@"policy"],
    @"policy_version" : DSHProjectContextPolicyVersion,
    @"branch" : capture[@"branch"],
    @"head_oid" : capture[@"head_oid"],
    @"clean" : capture[@"clean"],
    @"conflicted" : capture[@"conflicted"],
    @"captured_at" : capturedAt,
    @"source_fingerprint" : capture[@"source_fingerprint"],
    @"selected_paths" : capture[@"expanded_paths"],
    @"tracked_status" : capture[@"tracked_status"],
  };
  NSDictionary *providerBinding = DSHProviderBindingForModel(validated[@"model"]);
  if (providerBinding != nil) {
    NSMutableDictionary *boundMetadata = [envelopeMetadata mutableCopy];
    boundMetadata[@"provider_configuration"] = providerBinding;
    envelopeMetadata = boundMetadata;
  }
  NSMutableArray *included = [NSMutableArray array];
  NSMutableArray *omitted = [capture[@"omitted"] mutableCopy];
  NSData *envelope = [self framedEnvelopeMetadata:envelopeMetadata
                                           blocks:capture[@"blocks"]
                                         included:included
                                          omitted:omitted
                                            error:error];
  if (envelope == nil || ![self deadlineFrom:start error:error]) return nil;
  NSString *snapshotDigest = DSHServiceSHA256(envelope);
  NSDictionary *manifest = @{
    @"schema_version" : @1,
    @"snapshot_id" : snapshotId,
    @"project_id" : validated[@"project_id"],
    @"project_name" : lease.metadata[@"name"],
    @"branch" : capture[@"branch"],
    @"head_oid" : capture[@"head_oid"],
    @"clean" : capture[@"clean"],
    @"conflicted" : capture[@"conflicted"],
    @"captured_at" : capturedAt,
    @"policy_version" : DSHProjectContextPolicyVersion,
    @"provider_host" : DSHProviderHostForModel(validated[@"model"]),
    @"model" : validated[@"model"],
    @"included" : included,
    @"omitted" : omitted,
    @"context_bytes" : @(envelope.length),
    @"estimated_tokens" : @((envelope.length + 3) / 4),
    @"snapshot_sha256" : snapshotDigest,
    @"source_fingerprint" : capture[@"source_fingerprint"],
  };
  if (providerBinding != nil) {
    NSMutableDictionary *boundManifest = [manifest mutableCopy];
    boundManifest[@"provider_configuration"] = providerBinding;
    boundManifest[@"provider_host"] = [NSURL URLWithString:providerBinding[@"endpoint_url"]].host;
    manifest = boundManifest;
  }
  NSDictionary *sourceDescriptor = @{
    @"schema_version" : @1,
    @"project_id" : validated[@"project_id"],
    @"conversation_id" : validated[@"conversation_id"],
    @"provider" : validated[@"provider"],
    @"model" : validated[@"model"],
    @"policy" : validated[@"policy"],
    @"selected_paths" : validated[@"selected_paths"],
    @"source_fingerprint" : capture[@"source_fingerprint"],
    @"projects_root_device" : @((unsigned long long)lease.projectsRootDevice),
    @"projects_root_inode" : @((unsigned long long)lease.projectsRootInode),
    @"project_device" : @((unsigned long long)lease.projectDevice),
    @"project_inode" : @((unsigned long long)lease.projectInode),
    @"repository_device" : @((unsigned long long)lease.repositoryDevice),
    @"repository_inode" : @((unsigned long long)lease.repositoryInode),
    @"git_device" : @((unsigned long long)lease.gitDevice),
    @"git_inode" : @((unsigned long long)lease.gitInode),
    @"objects_device" : @((unsigned long long)lease.objectsDevice),
    @"objects_inode" : @((unsigned long long)lease.objectsInode),
    @"project_metadata_sha256" : capture[@"project_metadata_sha256"],
  };
  NSString *activeReferenceKey = [@"active:" stringByAppendingString:
      validated[@"conversation_id"]];
  if (![self.store beginPrepareTransactionWithEnvelope:envelope
                                               manifest:manifest
                                        sourceDescriptor:sourceDescriptor
                                             snapshotId:snapshotId
                                      activeReferenceKey:activeReferenceKey
                                                  error:nil]) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorStorage);
    return nil;
  }
  if (![self deadlineFrom:start error:error]) {
    NSError *abortError = nil;
    if (![self.store abortPrepareTransactionForSnapshotId:snapshotId
                                        activeReferenceKey:activeReferenceKey
                                                     error:&abortError]) {
      DSHSetServiceError(error, DSHProjectContextServiceErrorStorage);
    }
    return nil;
  }
  return manifest;
}

- (BOOL)verifyLiveSnapshot:(NSDictionary *)snapshot
              retainedLease:(DSHLocalProjectLease *__strong *)retainedLease
                      error:(NSError **)error {
  NSDictionary *providerManifest = snapshot[@"manifest"];
  if (![providerManifest isKindOfClass:NSDictionary.class]) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorIntegrity); return NO;
  }
  NSString *providerModel = providerManifest[@"model_id"] ?: providerManifest[@"model"];
  if (!DSHProviderBindingIsCurrent(providerManifest[@"provider_configuration"], providerModel)) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorChanged);
    return NO;
  }

  if (retainedLease != nil) *retainedLease = nil;
  NSDictionary *descriptor = snapshot[@"source_descriptor"];
  NSString *projectId = descriptor[@"project_id"];
  NSArray *paths = descriptor[@"selected_paths"];
  if (![DSHLocalProjectAccess isCanonicalProjectId:projectId] ||
      ![paths isKindOfClass:NSArray.class]) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorIntegrity);
    return NO;
  }
  NSDate *start = self.clock();
  NSError *accessError = nil;
  DSHLocalProjectLease *lease = [self.projectAccess
      leaseProjectId:projectId
                mode:DSHLocalProjectAccessModeRead
     includeMetadata:NO
             timeout:DSHProjectContextDeadlineSeconds
               error:&accessError];
  unsigned long long projectsRootDevice = 0;
  unsigned long long projectsRootInode = 0;
  unsigned long long projectDevice = 0;
  unsigned long long projectInode = 0;
  unsigned long long repositoryDevice = 0;
  unsigned long long repositoryInode = 0;
  unsigned long long gitDevice = 0;
  unsigned long long gitInode = 0;
  unsigned long long objectsDevice = 0;
  unsigned long long objectsInode = 0;
  BOOL descriptorIdentityValid =
      DSHLocalProjectAccessParseCanonicalUInt64(
          descriptor[@"projects_root_device"], &projectsRootDevice) &&
      DSHLocalProjectAccessParseCanonicalUInt64(
          descriptor[@"projects_root_inode"], &projectsRootInode) &&
      DSHLocalProjectAccessParseCanonicalUInt64(
          descriptor[@"project_device"], &projectDevice) &&
      DSHLocalProjectAccessParseCanonicalUInt64(
          descriptor[@"project_inode"], &projectInode) &&
      DSHLocalProjectAccessParseCanonicalUInt64(
          descriptor[@"repository_device"], &repositoryDevice) &&
      DSHLocalProjectAccessParseCanonicalUInt64(
          descriptor[@"repository_inode"], &repositoryInode) &&
      DSHLocalProjectAccessParseCanonicalUInt64(
          descriptor[@"git_device"], &gitDevice) &&
      DSHLocalProjectAccessParseCanonicalUInt64(
          descriptor[@"git_inode"], &gitInode) &&
      DSHLocalProjectAccessParseCanonicalUInt64(
          descriptor[@"objects_device"], &objectsDevice) &&
      DSHLocalProjectAccessParseCanonicalUInt64(
          descriptor[@"objects_inode"], &objectsInode);
  if (lease == nil || !descriptorIdentityValid ||
      projectsRootDevice != (unsigned long long)lease.projectsRootDevice ||
      projectsRootInode != (unsigned long long)lease.projectsRootInode ||
      projectDevice != (unsigned long long)lease.projectDevice ||
      projectInode != (unsigned long long)lease.projectInode ||
      repositoryDevice != (unsigned long long)lease.repositoryDevice ||
      repositoryInode != (unsigned long long)lease.repositoryInode ||
      gitDevice != (unsigned long long)lease.gitDevice ||
      gitInode != (unsigned long long)lease.gitInode ||
      objectsDevice != (unsigned long long)lease.objectsDevice ||
      objectsInode != (unsigned long long)lease.objectsInode) {
    DSHSetServiceError(
        error,
        lease == nil &&
                [accessError.domain isEqual:DSHLocalProjectAccessErrorDomain] &&
                accessError.code == DSHLocalProjectAccessErrorLockTimeout
            ? DSHProjectContextServiceErrorTimeout
            : DSHProjectContextServiceErrorChanged);
    return NO;
  }
  NSDictionary *capture = [self captureAndVerifyLease:lease
                                         selectedPaths:paths
                                         includeBlocks:NO
                                                 start:start
                                                 error:error];
  if (capture == nil) return NO;
  if (![capture[@"source_fingerprint"]
          isEqualToString:descriptor[@"source_fingerprint"]]) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorChanged);
    return NO;
  }
  if (retainedLease != nil) *retainedLease = lease;
  return YES;
}

- (NSDictionary *)confirmSnapshotId:(NSString *)snapshotId
                               error:(NSError **)error {
  NSError *authorizationError = nil;
  DSHProjectContextAuthorizationLease *authorization = [self.store
      beginAuthorizationForSnapshotId:snapshotId
                   activeReferenceKey:nil error:&authorizationError];
  if (authorization == nil) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorConsent);
    return nil;
  }
  NSDictionary *snapshot = authorization.snapshot;
  NSString *activeKey = [@"active:" stringByAppendingString:
      snapshot[@"source_descriptor"][@"conversation_id"] ?: @""];
  for (NSDictionary *omission in snapshot[@"manifest"][@"omitted"]) {
    if ([omission[@"reason"]
            isEqual:DSHProjectContextOmissionReasonBudgetExceeded]) {
      [self.store cancelAuthorizationLease:authorization];
      DSHSetServiceError(error,
                         DSHProjectContextServiceErrorBudgetExceeded);
      return nil;
    }
  }
  __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *liveLease = nil;
  if (![self verifyLiveSnapshot:snapshot retainedLease:&liveLease error:error]) {
    [self.store cancelAuthorizationLease:authorization];
    return nil;
  }
  if (self.hook != nil) self.hook(@"before_authorization_complete", nil);
  authorizationError = nil;
  NSDictionary *receipt = [self.store
      completeAuthorizationLease:authorization
             activeReferenceKey:activeKey
                      operation:^id(NSDictionary *current, NSError **storeError) {
                        return [self.store
                            commitPrepareTransactionForSnapshotId:snapshotId
                              activeReferenceKey:activeKey
                                  snapshotDigest:current[@"manifest"]
                                                        [@"snapshot_sha256"]
                                           error:storeError];
                      }
                          error:&authorizationError];
  if (receipt == nil) {
    DSHSetServiceError(
        error,
        authorizationError.code == DSHProjectContextStoreErrorNotFound
            ? DSHProjectContextServiceErrorConsent
            : DSHProjectContextServiceErrorStorage);
  }
  return receipt;
}

- (NSDictionary *)inspectSnapshotId:(NSString *)snapshotId
                               error:(NSError **)error {
  NSError *storeError = nil;
  NSDictionary *snapshot = [self.store loadSnapshotId:snapshotId
                                                 error:&storeError];
  if (snapshot == nil) {
    DSHSetServiceError(error, DSHServiceSnapshotStoreError(storeError));
    return nil;
  }
  NSError *verificationError = nil;
  BOOL live = [self verifyLiveSnapshot:snapshot retainedLease:nil
                                  error:&verificationError];
  NSMutableDictionary *inspection = [snapshot[@"manifest"] mutableCopy];
  NSString *conversationId = snapshot[@"manifest"][@"conversation_id"];
  NSString *transactionKey = [conversationId isKindOfClass:NSString.class]
      ? [@"txn:prepare:" stringByAppendingString:conversationId] : nil;
  NSString *inspectionActiveKey = [conversationId isKindOfClass:NSString.class]
      ? [@"active:" stringByAppendingString:conversationId] : nil;
  BOOL prepared = transactionKey != nil && inspectionActiveKey != nil &&
      [self.store snapshotIdForReferenceKey:transactionKey error:nil] != nil &&
      [[self.store snapshotIdForReferenceKey:inspectionActiveKey error:nil]
          isEqual:snapshotId];
  BOOL confirmed = NO;
  if (live && !prepared) {
    NSArray<NSURL *> *files =
        [self.store fileURLsForSnapshotId:snapshotId error:nil];
    for (NSURL *url in files) {
      if (![url.URLByDeletingLastPathComponent.lastPathComponent
              isEqual:@"consents"]) {
        continue;
      }
      NSString *receiptId = url.lastPathComponent.stringByDeletingPathExtension;
      NSDictionary *consent =
          [self.store loadConsentReceiptId:receiptId error:nil];
      if ([consent[@"snapshot_id"] isEqual:snapshotId] &&
          [consent[@"snapshot_sha256"]
              isEqual:snapshot[@"manifest"][@"snapshot_sha256"]]) {
        confirmed = YES;
        break;
      }
    }
  }
  inspection[@"state"] = live ? (confirmed ? @"confirmed" : @"prepared")
                                 : @"stale";
  return inspection;
}

- (BOOL)discardSnapshotId:(NSString *)snapshotId error:(NSError **)error {
  NSError *storeError = nil;
  if (![self.store discardSnapshotId:snapshotId error:&storeError]) {
    DSHSetServiceError(error, DSHServiceSnapshotStoreError(storeError));
    return NO;
  }
  return YES;
}

- (NSData *)verifiedEnvelopeForSnapshotId:(NSString *)snapshotId
                          consentReceiptId:(NSString *)consentReceiptId
                               requestBind:(NSDictionary *)requestBind
                                   receipt:(NSDictionary **)receipt
                                     error:(NSError **)error {
  NSArray *keys = @[
    @"schema_version", @"conversation_id", @"project_id", @"provider",
    @"model", @"policy"
  ];
  if (!DSHServiceExactKeys(requestBind, keys) ||
      ![requestBind[@"schema_version"] isEqual:@1] ||
      ![requestBind[@"conversation_id"] isKindOfClass:NSString.class]) {
    DSHSetServiceError(error,
                       DSHProjectContextServiceErrorInvalidArgument);
    return nil;
  }
  NSString *transactionKey = [@"txn:prepare:" stringByAppendingString:
      requestBind[@"conversation_id"] ?: @""];
  NSString *requestActiveKey = [@"active:" stringByAppendingString:
      requestBind[@"conversation_id"]];
  if ([self.store snapshotIdForReferenceKey:transactionKey error:nil] != nil &&
      [[self.store snapshotIdForReferenceKey:requestActiveKey error:nil]
          isEqual:snapshotId]) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorConsent);
    return nil;
  }
  NSError *authorizationError = nil;
  DSHProjectContextAuthorizationLease *authorization = [self.store
      beginAuthorizationForSnapshotId:snapshotId
                   activeReferenceKey:nil error:&authorizationError];
  if (authorization == nil) {
    DSHSetServiceError(error, DSHServiceSnapshotStoreError(authorizationError));
    return nil;
  }
  NSDictionary *snapshot = authorization.snapshot;
  NSDictionary *consent =
      [self.store loadConsentReceiptId:consentReceiptId error:nil];
  NSDictionary *descriptor = snapshot[@"source_descriptor"];
  if (snapshot == nil || consent == nil ||
      ![consent[@"snapshot_id"] isEqual:snapshotId] ||
      ![consent[@"snapshot_sha256"]
          isEqual:snapshot[@"manifest"][@"snapshot_sha256"]] ||
      ![requestBind[@"conversation_id"]
          isEqual:descriptor[@"conversation_id"]] ||
      ![requestBind[@"project_id"] isEqual:descriptor[@"project_id"]] ||
      ![requestBind[@"provider"] isEqual:descriptor[@"provider"]] ||
      ![requestBind[@"model"] isEqual:descriptor[@"model"]] ||
      ![requestBind[@"policy"] isEqual:descriptor[@"policy"]]) {
    [self.store cancelAuthorizationLease:authorization];
    DSHSetServiceError(error, DSHProjectContextServiceErrorConsent);
    return nil;
  }
  NSString *activeKey = [@"active:" stringByAppendingString:
      descriptor[@"conversation_id"] ?: @""];
  __attribute__((objc_precise_lifetime)) DSHLocalProjectLease *liveLease = nil;
  if (![self verifyLiveSnapshot:snapshot retainedLease:&liveLease error:error]) {
    [self.store cancelAuthorizationLease:authorization];
    return nil;
  }
  if (self.hook != nil) self.hook(@"before_authorization_complete", nil);
  __block NSDictionary *verifiedReceipt = nil;
  authorizationError = nil;
  NSData *verified = [self.store
      completeAuthorizationLease:authorization
             activeReferenceKey:activeKey
                      operation:^id(NSDictionary *current,
                                    NSError **storeError) {
                        if ([self.store snapshotIdForReferenceKey:transactionKey
                                                           error:nil] != nil &&
                            [[self.store snapshotIdForReferenceKey:activeKey
                                                             error:nil]
                                isEqual:snapshotId]) {
                          if (storeError != nil) {
                            *storeError = [NSError
                                errorWithDomain:DSHProjectContextStoreErrorDomain
                                           code:DSHProjectContextStoreErrorIntegrity
                                       userInfo:@{}];
                          }
                          return nil;
                        }
                        NSDictionary *finalConsent = [self.store
                            loadConsentReceiptId:consentReceiptId
                                           error:storeError];
                        if (finalConsent == nil ||
                            ![finalConsent[@"snapshot_id"] isEqual:snapshotId] ||
                            ![finalConsent[@"snapshot_sha256"]
                                isEqual:current[@"manifest"][@"snapshot_sha256"]]) {
                          if (storeError != nil && *storeError == nil) {
                            *storeError = [NSError
                                errorWithDomain:DSHProjectContextStoreErrorDomain
                                           code:DSHProjectContextStoreErrorIntegrity
                                       userInfo:@{}];
                          }
                          return nil;
                        }
                        verifiedReceipt = @{
                          @"schema_version" : @1,
                          @"snapshot_id" : snapshotId,
                          @"snapshot_sha256" :
                              current[@"manifest"][@"snapshot_sha256"],
                          @"source_fingerprint" :
                              current[@"manifest"][@"source_fingerprint"],
                          @"context_bytes" :
                              current[@"manifest"][@"context_bytes"],
                          @"verified_at" : DSHServiceISO8601(self.clock()),
                        };
                        return [current[@"envelope"] copy];
                      }
                          error:&authorizationError];
  if (verified == nil) {
    DSHSetServiceError(
        error,
        (authorizationError.code == DSHProjectContextStoreErrorNotFound ||
         authorizationError.code == DSHProjectContextStoreErrorIntegrity)
            ? DSHProjectContextServiceErrorConsent
            : DSHProjectContextServiceErrorStorage);
    return nil;
  }
  if (receipt != nil) *receipt = verifiedReceipt;
  return verified;
}

- (DSHLocalProjectLease *)v2LeaseForRoot:(NSDictionary *)rootRef
                          includeMetadata:(BOOL)includeMetadata
                                   error:(NSError **)error {
  NSDictionary *root = DSHServiceV2RootRef(rootRef, YES);
  if (root == nil || self.projectAccess == nil || self.workspaceAccess == nil) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorInvalidArgument);
    return nil;
  }
  if (self.borrowedLegacyLease != nil) {
    if (![self.borrowedLegacyLease.workspaceRootRef isEqual:root] ||
        ![self.borrowedLegacyLease validateIdentity]) {
      DSHSetServiceError(error, DSHProjectContextServiceErrorChanged);
      return nil;
    }
    return (DSHLocalProjectLease *)self.borrowedLegacyLease;
  }
  NSError *accessError = nil;
  DSHLocalProjectLease *lease = [self.projectAccess
      leaseWorkspaceRootRef:root
             workspaceAccess:self.workspaceAccess
                        mode:DSHLocalProjectAccessModeRead
             includeMetadata:includeMetadata
                     timeout:DSHProjectContextDeadlineSeconds
                       error:&accessError];
  if (lease == nil) {
    if ([accessError.domain isEqual:DSHLocalProjectAccessErrorDomain] &&
        accessError.code == DSHLocalProjectAccessErrorLockTimeout) {
      DSHSetServiceError(error, DSHProjectContextServiceErrorTimeout);
    } else if ([accessError.domain isEqual:DSHLocalProjectAccessErrorDomain] &&
               (accessError.code == DSHLocalProjectAccessErrorInvalidIdentifier ||
                accessError.code == DSHLocalProjectAccessErrorRepositoryUnavailable)) {
      DSHSetServiceError(error, DSHProjectContextServiceErrorProjectUnavailable);
    } else {
      DSHSetServiceError(error, DSHProjectContextServiceErrorChanged);
    }
    return nil;
  }
  if (![self validateV2Lease:lease root:root error:&accessError]) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorChanged);
    return nil;
  }
  return lease;
}

- (NSDictionary *)v2ProjectDescriptorForLease:(DSHLocalProjectLease *)lease
                                          root:(NSDictionary *)root {
  NSString *name = lease.metadata[@"name"];
  NSData *nameData = [name dataUsingEncoding:NSUTF8StringEncoding
                             allowLossyConversion:NO];
  if (![name isKindOfClass:NSString.class] || name.length == 0 ||
      nameData == nil || nameData.length > 120 ||
      [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet]
              .location != NSNotFound || [name containsString:@"/"] ||
      [name containsString:@"\\"] || [name isEqual:@"."] ||
      [name isEqual:@".."]) {
    name = lease.projectId;
  }
  return @{
    @"schema_version" : @2,
    @"project_id" : lease.projectId,
    @"workspace_id" : root[@"workspace_id"],
    @"workspace_binding_revision" : root[@"binding_revision"],
    @"display_name" : name,
    @"git_topology" : lease.gitTopology,
  };
}

- (NSDictionary *)captureV2ForLease:(DSHLocalProjectLease *)lease
                       selectedPaths:(NSArray<NSString *> *)selectedPaths
                              blocks:(BOOL)includeBlocks
                               start:(NSDate *)start
                               error:(NSError **)error {
  NSDictionary *capture = [self captureAndVerifyLease:lease
                                         selectedPaths:selectedPaths
                                         includeBlocks:includeBlocks
                                                 start:start
                                                 error:error];
  if (capture == nil) return nil;
  if (![self validateV2Lease:lease root:lease.workspaceRootRef error:error]) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorChanged);
    return nil;
  }
  NSDictionary *fingerprintInput = @{
    @"workspace_root_fingerprint" : lease.rootFingerprintSHA256 ?: @"",
    @"workspace_root" : lease.workspaceRootRef ?: @{},
    @"capture_source_fingerprint" : capture[@"source_fingerprint"] ?: @"",
  };
  NSString *fingerprint = DSHServiceSHA256(
      DSHCanonicalJSON(fingerprintInput) ?: NSData.data);
  NSMutableDictionary *result = [capture mutableCopy];
  result[@"source_fingerprint"] = fingerprint;
  result[@"workspace_root_fingerprint"] = lease.rootFingerprintSHA256 ?: @"";
  return result;
}

- (BOOL)verifyLiveSnapshotV2:(NSDictionary *)snapshot
                         root:(NSDictionary *)rootRef
                retainedLease:(DSHLocalProjectLease **)retainedLease
                         error:(NSError **)error {
  return [self verifySnapshotV2:snapshot root:rootRef requireLiveSource:YES
                 retainedLease:retainedLease error:error];
}

- (BOOL)verifySnapshotV2:(NSDictionary *)snapshot
                    root:(NSDictionary *)rootRef
       requireLiveSource:(BOOL)requireLiveSource
           retainedLease:(DSHLocalProjectLease **)retainedLease
                    error:(NSError **)error {
  NSDictionary *providerManifest = snapshot[@"manifest"];
  if (![providerManifest isKindOfClass:NSDictionary.class]) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorIntegrity); return NO;
  }
  NSString *providerModel = providerManifest[@"model_id"] ?: providerManifest[@"model"];
  if (!DSHProviderBindingIsCurrent(providerManifest[@"provider_configuration"], providerModel)) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorChanged);
    return NO;
  }

  if (retainedLease != nil) *retainedLease = nil;
  NSDictionary *root = DSHServiceV2RootRef(rootRef, YES);
  NSDictionary *source = snapshot[@"source_descriptor"];
  NSDictionary *manifest = snapshot[@"manifest"];
  if (![source isKindOfClass:NSDictionary.class] ||
      ![manifest isKindOfClass:NSDictionary.class]) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorIntegrity);
    return NO;
  }
  if (!DSHServiceExactKeys(source, @[
        @"schema_version", @"root", @"workspace_id",
        @"workspace_binding_revision", @"project_id", @"conversation_id",
        @"model_id", @"policy", @"selected_paths", @"source_fingerprint",
        @"root_fingerprint_sha256", @"workspace_binding_sha256",
        @"reference_id", @"root_device",
        @"root_inode", @"repository_device", @"repository_inode",
        @"git_device", @"git_inode", @"objects_device", @"objects_inode"
      ]) ||
      ![source[@"schema_version"] isEqual:@2]) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorIntegrity);
    return NO;
  }
  NSDictionary *storedRoot = source[@"root"];
  NSArray *paths = source[@"selected_paths"];
  NSMutableSet<NSString *> *pathSet = [NSMutableSet set];
  BOOL pathsValid = [paths isKindOfClass:NSArray.class] &&
      paths.count <= DSHProjectContextMaxEntries;
  for (id rawPath in paths) {
    NSString *path = DSHServiceV2BoundedString(
        rawPath, DSHProjectContextMaxRelativePathCharacters, NO);
    DSHProjectContextPathDecision *decision = path == nil
        ? nil : [self.policy decisionForRelativePath:path];
    if (decision == nil ||
        ![decision.normalizedPath isEqual:path] ||
        [pathSet containsObject:path]) {
      pathsValid = NO;
      break;
    }
    [pathSet addObject:path];
  }
  if (root == nil || ![storedRoot isKindOfClass:NSDictionary.class] ||
      !DSHServiceV2RootsEqual(root, storedRoot) ||
      !pathsValid ||
      ![manifest[@"snapshot_id"] isKindOfClass:NSString.class] ||
      !DSHServiceCanonicalIdentifier(manifest[@"snapshot_id"]) ||
      ![manifest[@"schema_version"] isKindOfClass:NSNumber.class] ||
      DSHServiceIsBoolean(manifest[@"schema_version"]) ||
      [manifest[@"schema_version"] isKindOfClass:NSDecimalNumber.class] ||
      ![manifest[@"schema_version"] isEqual:@2] ||
      !DSHServiceV2RootsEqual(root, manifest[@"root"]) ||
      ![manifest[@"project_id"] isEqual:root[@"project_id"]] ||
      ![manifest[@"conversation_id"] isEqual:source[@"conversation_id"]] ||
      ![manifest[@"model_id"] isEqual:source[@"model_id"]] ||
      ![manifest[@"policy"] isEqual:source[@"policy"]] ||
      ![DSHLocalProjectAccess isCanonicalProjectId:source[@"project_id"]] ||
      ![source[@"project_id"] isEqual:root[@"project_id"]] ||
      ![DSHLocalProjectAccess isCanonicalProjectId:source[@"workspace_id"]] ||
      ![source[@"workspace_id"] isEqual:root[@"workspace_id"]] ||
      ![source[@"workspace_binding_revision"] isEqual:root[@"binding_revision"]] ||
      !DSHServiceCanonicalDigest(source[@"root_fingerprint_sha256"]) ||
      !DSHServiceCanonicalDigest(source[@"workspace_binding_sha256"]) ||
      !DSHServiceCanonicalIdentifierString(source[@"conversation_id"]) ||
      DSHServiceV2Model(source[@"model_id"]) == nil ||
      ![source[@"policy"] isEqual:@"chat-read-v1"] ||
      !DSHServiceCanonicalIdentifierString(source[@"reference_id"]) ||
      ![source[@"reference_id"] isEqual:DSHServiceV2ReferenceId(
          root, source[@"root_fingerprint_sha256"], source[@"conversation_id"])] ||
      ![manifest[@"included"] isKindOfClass:NSArray.class] ||
      ![manifest[@"omitted"] isKindOfClass:NSArray.class] ||
      !DSHServiceCanonicalDigest(source[@"source_fingerprint"]) ||
      ![source[@"source_fingerprint"]
          isEqual:manifest[@"source_fingerprint"]] ||
      ![manifest[@"source_fingerprint"] isKindOfClass:NSString.class] ||
      !DSHServiceCanonicalDigest(manifest[@"source_fingerprint"]) ||
      !DSHServiceCanonicalDigest(manifest[@"snapshot_sha256"]) ||
      ![source[@"workspace_id"] isEqual:root[@"workspace_id"]] ||
      ![source[@"workspace_binding_revision"] isEqual:root[@"binding_revision"]]) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorIntegrity);
    return NO;
  }
  NSDate *start = self.clock();
  DSHLocalProjectLease *lease = [self v2LeaseForRoot:root
                                      includeMetadata:YES
                                               error:error];
  if (lease == nil) return NO;
  unsigned long long rootDevice = 0;
  unsigned long long rootInode = 0;
  unsigned long long repositoryDevice = 0;
  unsigned long long repositoryInode = 0;
  unsigned long long gitDevice = 0;
  unsigned long long gitInode = 0;
  unsigned long long objectsDevice = 0;
  unsigned long long objectsInode = 0;
  BOOL sourceIdentityValid =
      DSHLocalProjectAccessParseCanonicalUInt64(source[@"root_device"],
                                                &rootDevice) &&
      DSHLocalProjectAccessParseCanonicalUInt64(source[@"root_inode"],
                                                &rootInode) &&
      DSHLocalProjectAccessParseCanonicalUInt64(source[@"repository_device"],
                                                &repositoryDevice) &&
      DSHLocalProjectAccessParseCanonicalUInt64(source[@"repository_inode"],
                                                &repositoryInode) &&
      DSHLocalProjectAccessParseCanonicalUInt64(source[@"git_device"],
                                                &gitDevice) &&
      DSHLocalProjectAccessParseCanonicalUInt64(source[@"git_inode"],
                                                &gitInode) &&
      DSHLocalProjectAccessParseCanonicalUInt64(source[@"objects_device"],
                                                &objectsDevice) &&
      DSHLocalProjectAccessParseCanonicalUInt64(source[@"objects_inode"],
                                                &objectsInode);
  if (![source[@"root_fingerprint_sha256"]
          isEqual:lease.rootFingerprintSHA256] ||
      ![source[@"workspace_binding_sha256"]
          isEqual:lease.workspaceBindingDigest] ||
      !sourceIdentityValid ||
      rootDevice != (unsigned long long)lease.workspaceRootDevice ||
      rootInode != (unsigned long long)lease.workspaceRootInode ||
      repositoryDevice != (unsigned long long)lease.repositoryDevice ||
      repositoryInode != (unsigned long long)lease.repositoryInode ||
      gitDevice != (unsigned long long)lease.gitDevice ||
      gitInode != (unsigned long long)lease.gitInode ||
      objectsDevice != (unsigned long long)lease.objectsDevice ||
      objectsInode != (unsigned long long)lease.objectsInode) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorIntegrity);
    return NO;
  }
  if (!requireLiveSource) {
    if (![self validateV2Lease:lease root:root error:error]) return NO;
    if (retainedLease != nil) *retainedLease = lease;
    return YES;
  }
  NSDictionary *capture = [self captureV2ForLease:lease
                                     selectedPaths:paths
                                            blocks:NO
                                             start:start
                                             error:error];
  if (capture == nil ||
      ![capture[@"source_fingerprint"]
          isEqual:snapshot[@"manifest"][@"source_fingerprint"]] ||
      ![self validateV2Lease:lease root:root error:error]) {
    if (capture != nil && error != nil && *error == nil) {
      DSHSetServiceError(error, DSHProjectContextServiceErrorChanged);
    }
    return NO;
  }
  if (retainedLease != nil) *retainedLease = lease;
  return YES;
}

- (NSDictionary *)v2ManifestForSnapshot:(NSDictionary *)snapshot {
  NSDictionary *manifest = snapshot[@"manifest"];
  return [manifest isKindOfClass:NSDictionary.class] ? manifest : nil;
}

- (NSDictionary *)listCandidatesV2:(NSDictionary *)request
                              error:(NSError **)error {
  NSArray *keys = @[
    @"schema_version", @"root", @"query", @"cursor"
  ];
  if (!DSHServiceExactKeys(request, keys) ||
      ![request[@"schema_version"] isKindOfClass:NSNumber.class] ||
      DSHServiceIsBoolean(request[@"schema_version"]) ||
      [request[@"schema_version"] isKindOfClass:NSDecimalNumber.class] ||
      ![request[@"schema_version"] isEqual:@1] ||
      DSHServiceV2RootRef(request[@"root"], YES) == nil ||
      DSHServiceV2BoundedString(request[@"query"], 256, YES) == nil ||
      (request[@"cursor"] != NSNull.null &&
       DSHServiceV2BoundedString(request[@"cursor"], 256, NO) == nil)) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorInvalidArgument);
    return nil;
  }
  NSDictionary *root = DSHServiceV2RootRef(request[@"root"], YES);
  NSString *query = DSHServiceV2BoundedString(request[@"query"], 256, YES);
  NSString *cursor = request[@"cursor"] == NSNull.null
      ? nil : DSHServiceV2BoundedString(request[@"cursor"], 256, NO);
  return [self listCandidatesV2ForRoot:root query:query cursor:cursor error:error];
}

- (NSDictionary *)listCandidatesV2ForRoot:(NSDictionary *)rootRef
                                     query:(NSString *)query
                                    cursor:(NSString *)cursor
                                     error:(NSError **)error {
  if ((id)cursor == NSNull.null) cursor = nil;
  NSDictionary *root = DSHServiceV2RootRef(rootRef, YES);
  if (root == nil || DSHServiceV2BoundedString(query, 256, YES) == nil ||
      (cursor != nil && DSHServiceV2BoundedString(cursor, 256, NO) == nil)) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorInvalidArgument);
    return nil;
  }
  if (self.borrowedLegacyLease == nil) {
    __block NSDictionary *legacyResult = nil;
    DSHLegacyBoundProjectRootDisposition disposition =
        [self performLegacyContextForRoot:root
            operation:^BOOL(NSError **operationError) {
              legacyResult = [self listCandidatesV2ForRoot:root
                                                     query:query
                                                    cursor:cursor
                                                     error:operationError];
              return legacyResult != nil;
            } error:error];
    if (disposition == DSHLegacyBoundProjectRootDispositionHandled) {
      return legacyResult;
    }
    if (disposition == DSHLegacyBoundProjectRootDispositionFailed) return nil;
  }
  NSDate *start = self.clock();
  DSHLocalProjectLease *lease = [self v2LeaseForRoot:root
                                      includeMetadata:YES
                                               error:error];
  if (lease == nil) return nil;
  NSDictionary *capture = [self metadataCandidateCaptureLease:lease
                                                         start:start
                                                         error:error];
  if (capture == nil ||
      ![self validateV2Lease:lease root:root error:error]) {
    if (capture != nil && error != nil && *error == nil) {
      DSHSetServiceError(error, DSHProjectContextServiceErrorChanged);
    }
    return nil;
  }
  NSDictionary *candidateFingerprintInput = @{
    @"workspace_root" : root,
    @"workspace_root_fingerprint" : lease.rootFingerprintSHA256 ?: @"",
    @"candidate_source_fingerprint" : capture[@"source_fingerprint"] ?: @"",
  };
  NSMutableDictionary *candidateCapture = [capture mutableCopy];
  candidateCapture[@"source_fingerprint"] = DSHServiceSHA256(
      DSHCanonicalJSON(candidateFingerprintInput) ?: NSData.data);
  NSError *policyError = nil;
  NSDictionary *page = [self.policy
      candidatePageForCandidates:candidateCapture[@"candidates"]
                           query:query
               sourceFingerprint:candidateCapture[@"source_fingerprint"]
                          cursor:cursor
                           limit:DSHProjectContextMaxCandidatePageSize
                           error:&policyError];
  if (page == nil) {
    DSHSetServiceError(error,
        policyError.code == DSHProjectContextPolicyErrorBudgetExceeded
            ? DSHProjectContextServiceErrorBudgetExceeded
            : (policyError.code == DSHProjectContextPolicyErrorStaleCursor
                   ? DSHProjectContextServiceErrorChanged
                   : DSHProjectContextServiceErrorInvalidArgument));
    return nil;
  }
  if (![self validateV2Lease:lease root:root error:error] ||
      ![self deadlineFrom:start error:error]) {
    if (error != nil && *error == nil) {
      DSHSetServiceError(error, DSHProjectContextServiceErrorChanged);
    }
    return nil;
  }
  return @{
    @"schema_version" : @2,
    @"root" : root,
    @"project" : [self v2ProjectDescriptorForLease:lease root:root],
    @"candidates" : page[@"candidates"] ?: @[],
    @"next_cursor" : page[@"next_cursor"] ?: NSNull.null,
  };
}

- (NSDictionary *)prepareCandidateV2:(NSDictionary *)request
                                error:(NSError **)error {
  NSArray *keys = @[
    @"schema_version", @"root", @"conversation_id", @"model_id", @"policy",
    @"selected_paths"
  ];
  NSDictionary *root = DSHServiceV2RootRef(request[@"root"], YES);
  NSString *conversation = DSHServiceV2BoundedString(request[@"conversation_id"],
                                                       128, NO);
  NSString *model = DSHServiceV2Model(request[@"model_id"]);
  NSString *policy = DSHServiceV2BoundedString(request[@"policy"], 64, NO);
  NSArray *paths = request[@"selected_paths"];
  if (!DSHServiceExactKeys(request, keys) ||
      ![request[@"schema_version"] isKindOfClass:NSNumber.class] ||
      DSHServiceIsBoolean(request[@"schema_version"]) ||
      [request[@"schema_version"] isKindOfClass:NSDecimalNumber.class] ||
      ![request[@"schema_version"] isEqual:@2] || root == nil ||
      !DSHServiceCanonicalIdentifier(conversation) || model == nil ||
      ![policy isEqual:@"chat-read-v1"] ||
      ![paths isKindOfClass:NSArray.class] || paths.count > DSHProjectContextMaxEntries) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorInvalidArgument);
    return nil;
  }
  NSMutableArray<NSString *> *normalized = [NSMutableArray array];
  NSMutableSet<NSString *> *seen = [NSMutableSet set];
  for (id value in paths) {
    NSString *path = DSHServiceV2BoundedString(value,
                                               DSHProjectContextMaxRelativePathCharacters,
                                               NO);
    DSHProjectContextPathDecision *decision = path == nil
        ? nil : [self.policy decisionForRelativePath:path];
    if (decision == nil || decision.normalizedPath.length == 0 ||
        [seen containsObject:decision.normalizedPath]) {
      DSHSetServiceError(error, DSHProjectContextServiceErrorInvalidArgument);
      return nil;
    }
    [seen addObject:decision.normalizedPath];
    [normalized addObject:decision.normalizedPath];
  }
  [normalized sortUsingSelector:@selector(compare:)];
  if (self.borrowedLegacyLease == nil) {
    __block NSDictionary *legacyResult = nil;
    DSHLegacyBoundProjectRootDisposition disposition =
        [self performLegacyContextForRoot:root
            operation:^BOOL(NSError **operationError) {
              legacyResult = [self prepareCandidateV2:request
                                                error:operationError];
              return legacyResult != nil;
            } error:error];
    if (disposition == DSHLegacyBoundProjectRootDispositionHandled) {
      return legacyResult;
    }
    if (disposition == DSHLegacyBoundProjectRootDispositionFailed) return nil;
  }
  NSDate *start = self.clock();
  DSHLocalProjectLease *lease = [self v2LeaseForRoot:root
                                      includeMetadata:YES
                                               error:error];
  if (lease == nil) return nil;
  NSDictionary *capture = [self captureV2ForLease:lease
                                     selectedPaths:normalized
                                            blocks:YES
                                             start:start
                                             error:error];
  if (capture == nil) return nil;
  NSString *referenceId = DSHServiceV2ReferenceId(
      root, lease.rootFingerprintSHA256, conversation);
  if (referenceId == nil) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorIntegrity);
    return nil;
  }
  NSString *snapshotId = self.identifierGenerator();
  if (!DSHServiceCanonicalIdentifier(snapshotId)) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorInvalidArgument);
    return nil;
  }
  NSString *capturedAt = DSHServiceISO8601(self.clock());
  NSDictionary *metadata = @{
    @"schema_version" : @2,
    @"snapshot_id" : snapshotId,
    @"root" : root,
    @"project" : [self v2ProjectDescriptorForLease:lease root:root],
    @"project_id" : root[@"project_id"],
    @"conversation_id" : conversation,
    @"model_id" : model,
    @"policy" : policy,
    @"policy_version" : DSHProjectContextPolicyVersion,
    @"branch" : capture[@"branch"] ?: NSNull.null,
    @"head_oid" : capture[@"head_oid"] ?: NSNull.null,
    @"clean" : capture[@"clean"] ?: @NO,
    @"conflicted" : capture[@"conflicted"] ?: @NO,
    @"captured_at" : capturedAt ?: @"",
    @"source_fingerprint" : capture[@"source_fingerprint"],
    @"selected_paths" : capture[@"expanded_paths"] ?: @[],
    @"tracked_status" : capture[@"tracked_status"] ?: @[],
  };
  NSDictionary *providerBinding = DSHProviderBindingForModel(model);
  if (providerBinding != nil) {
    NSMutableDictionary *boundMetadata = [metadata mutableCopy];
    boundMetadata[@"provider_configuration"] = providerBinding;
    metadata = boundMetadata;
  }
  NSMutableArray *included = [NSMutableArray array];
  NSMutableArray *omitted = [capture[@"omitted"] mutableCopy] ?: [NSMutableArray array];
  NSData *envelope = [self framedEnvelopeMetadata:metadata
                                           blocks:capture[@"blocks"]
                                         included:included
                                          omitted:omitted
                                            error:error];
  if (envelope == nil || ![self deadlineFrom:start error:error]) return nil;
  NSString *snapshotDigest = DSHServiceSHA256(envelope);
  NSDictionary *manifest = @{
    @"schema_version" : @2,
    @"snapshot_id" : snapshotId,
    @"root" : root,
    @"project" : [self v2ProjectDescriptorForLease:lease root:root],
    @"project_id" : root[@"project_id"],
    @"conversation_id" : conversation,
    @"model_id" : model,
    @"policy" : policy,
    @"branch" : capture[@"branch"] ?: NSNull.null,
    @"head_oid" : capture[@"head_oid"] ?: NSNull.null,
    @"clean" : capture[@"clean"] ?: @NO,
    @"conflicted" : capture[@"conflicted"] ?: @NO,
    @"captured_at" : capturedAt ?: @"",
    @"policy_version" : DSHProjectContextPolicyVersion,
    @"included" : included,
    @"omitted" : omitted,
    @"context_bytes" : @(envelope.length),
    @"estimated_tokens" : @((envelope.length + 3) / 4),
    @"snapshot_sha256" : snapshotDigest,
    @"source_fingerprint" : capture[@"source_fingerprint"],
  };
  if (providerBinding != nil) {
    NSMutableDictionary *boundManifest = [manifest mutableCopy];
    boundManifest[@"provider_configuration"] = providerBinding;
    manifest = boundManifest;
  }
  NSDictionary *sourceDescriptor = @{
    @"schema_version" : @2,
    @"root" : root,
    @"workspace_id" : root[@"workspace_id"],
    @"workspace_binding_revision" : root[@"binding_revision"],
    @"project_id" : root[@"project_id"],
    @"conversation_id" : conversation,
    @"model_id" : model,
    @"policy" : policy,
    @"selected_paths" : normalized,
    @"source_fingerprint" : capture[@"source_fingerprint"],
    @"root_fingerprint_sha256" : lease.rootFingerprintSHA256,
    @"workspace_binding_sha256" : lease.workspaceBindingDigest,
    @"reference_id" : referenceId,
    @"root_device" : DSHServiceCanonicalUInt64String(
        (unsigned long long)lease.workspaceRootDevice),
    @"root_inode" : DSHServiceCanonicalUInt64String(
        (unsigned long long)lease.workspaceRootInode),
    @"repository_device" : DSHServiceCanonicalUInt64String(
        (unsigned long long)lease.repositoryDevice),
    @"repository_inode" : DSHServiceCanonicalUInt64String(
        (unsigned long long)lease.repositoryInode),
    @"git_device" : DSHServiceCanonicalUInt64String(
        (unsigned long long)lease.gitDevice),
    @"git_inode" : DSHServiceCanonicalUInt64String(
        (unsigned long long)lease.gitInode),
    @"objects_device" : DSHServiceCanonicalUInt64String(
        (unsigned long long)lease.objectsDevice),
    @"objects_inode" : DSHServiceCanonicalUInt64String(
        (unsigned long long)lease.objectsInode),
  };
  // ProjectContextStore's transaction protocol accepts an active:<uuid>
  // suffix. The UUID is a private digest of the complete V2 root tuple,
  // root fingerprint, and conversation, preventing cross-workspace UUID
  // collisions while preserving the store's one-shot transaction primitive.
  NSString *activeReferenceKey = [@"active:" stringByAppendingString:referenceId];
  if (self.hook != nil) self.hook(@"before_v2_store_cas", nil);
  NSError *storeError = nil;
  BOOL workspaceStillValid = [self validateV2Lease:lease root:root error:error];
  BOOL transactionStarted = workspaceStillValid &&
      [self.store beginPrepareTransactionWithEnvelope:envelope
                                               manifest:manifest
                                        sourceDescriptor:sourceDescriptor
                                             snapshotId:snapshotId
                                      activeReferenceKey:activeReferenceKey
                                                  error:&storeError];
  if (!transactionStarted) {
    if (!workspaceStillValid) {
      DSHSetServiceError(error, DSHProjectContextServiceErrorChanged);
    } else {
      DSHSetServiceError(error, DSHServiceSnapshotStoreError(storeError));
    }
    return nil;
  }
  if (self.hook != nil) self.hook(@"after_v2_store_cas", nil);
  if (![self validateV2Lease:lease root:root error:error]) {
    NSError *abortError = nil;
    if (![self.store abortPrepareTransactionForSnapshotId:snapshotId
                                       activeReferenceKey:activeReferenceKey
                                                    error:&abortError]) {
      DSHSetServiceError(error, DSHProjectContextServiceErrorStorage);
    } else if (error != nil && *error == nil) {
      DSHSetServiceError(error, DSHProjectContextServiceErrorChanged);
    }
    return nil;
  }
  if (![self deadlineFrom:start error:error]) {
    [self.store abortPrepareTransactionForSnapshotId:snapshotId
                                   activeReferenceKey:activeReferenceKey
                                                error:nil];
    return nil;
  }
  return manifest;
}

- (NSDictionary *)confirmSnapshotV2:(NSDictionary *)request
                               error:(NSError **)error {
  NSArray *keys = @[@"schema_version", @"snapshot_id", @"root"];
  NSDictionary *root = DSHServiceV2RootRef(request[@"root"], YES);
  NSString *snapshotId = DSHServiceCanonicalIdentifierString(request[@"snapshot_id"]);
  if (!DSHServiceExactKeys(request, keys) ||
      ![request[@"schema_version"] isKindOfClass:NSNumber.class] ||
      DSHServiceIsBoolean(request[@"schema_version"]) ||
      [request[@"schema_version"] isKindOfClass:NSDecimalNumber.class] ||
      ![request[@"schema_version"] isEqual:@2] || snapshotId == nil ||
      root == nil) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorInvalidArgument);
    return nil;
  }
  if (self.borrowedLegacyLease == nil) {
    __block NSDictionary *legacyResult = nil;
    DSHLegacyBoundProjectRootDisposition disposition =
        [self performLegacyContextForRoot:root
            operation:^BOOL(NSError **operationError) {
              legacyResult = [self confirmSnapshotV2:request error:operationError];
              return legacyResult != nil;
            } error:error];
    if (disposition == DSHLegacyBoundProjectRootDispositionHandled) return legacyResult;
    if (disposition == DSHLegacyBoundProjectRootDispositionFailed) return nil;
  }
  NSError *storeError = nil;
  NSDictionary *snapshot = [self.store loadSnapshotId:snapshotId error:&storeError];
  if (snapshot == nil) {
    DSHSetServiceError(error, DSHServiceSnapshotStoreError(storeError));
    return nil;
  }
  NSDictionary *manifest = snapshot[@"manifest"];
  if (!DSHServiceV2RootsEqual(root, manifest[@"root"])) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorChanged);
    return nil;
  }
  for (NSDictionary *omission in manifest[@"omitted"]) {
    if ([omission[@"reason"] isEqual:DSHProjectContextOmissionReasonBudgetExceeded]) {
      DSHSetServiceError(error, DSHProjectContextServiceErrorBudgetExceeded);
      return nil;
    }
  }
  DSHLocalProjectLease *lease = nil;
  if (![self verifyLiveSnapshotV2:snapshot root:root retainedLease:&lease error:error]) {
    return nil;
  }
  NSDictionary *source = snapshot[@"source_descriptor"];
  NSString *referenceId = source[@"reference_id"];
  NSString *activeKey = [@"active:" stringByAppendingString:referenceId ?: @""];
  NSString *transactionKey = [@"txn:prepare:" stringByAppendingString:referenceId ?: @""];
  NSError *authorizationError = nil;
  DSHProjectContextAuthorizationLease *authorization = [self.store
      beginAuthorizationForSnapshotId:snapshotId activeReferenceKey:nil
                                 error:&authorizationError];
  if (authorization == nil) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorConsent);
    return nil;
  }
  if (![self validateV2Lease:lease root:root error:error]) {
    [self.store cancelAuthorizationLease:authorization];
    return nil;
  }
  if (self.hook != nil) self.hook(@"before_v2_authorization_complete", nil);
  authorizationError = nil;
  NSDictionary *baseReceipt = [self.store
      completeAuthorizationLease:authorization
             activeReferenceKey:activeKey
                      operation:^id(NSDictionary *current, NSError **storeError) {
                        if ([self.store snapshotIdForReferenceKey:transactionKey
                                                           error:nil] == nil) {
                          if (storeError != nil) {
                            *storeError = [NSError errorWithDomain:
                                DSHProjectContextStoreErrorDomain
                                                             code:DSHProjectContextStoreErrorNotFound
                                                         userInfo:@{}];
                          }
                          return nil;
                        }
                        if (![self validateV2Lease:lease root:root error:nil]) {
                          if (storeError != nil) {
                            *storeError = [NSError errorWithDomain:
                                DSHProjectContextStoreErrorDomain
                                                             code:DSHProjectContextStoreErrorIntegrity
                                                         userInfo:@{}];
                          }
                          return nil;
                        }
                        return [self.store
                            commitPrepareTransactionForSnapshotId:snapshotId
                              activeReferenceKey:activeKey
                                  snapshotDigest:current[@"manifest"][@"snapshot_sha256"]
                                           error:storeError];
                      }
                          error:&authorizationError];
  if (baseReceipt == nil) {
    DSHSetServiceError(error,
        authorizationError.code == DSHProjectContextStoreErrorIntegrity
            ? DSHProjectContextServiceErrorChanged
            : (authorizationError.code == DSHProjectContextStoreErrorCapacity
                   ? DSHProjectContextServiceErrorBudgetExceeded
                   : DSHProjectContextServiceErrorConsent));
    return nil;
  }
  if (self.hook != nil) self.hook(@"after_v2_authorization_complete", nil);
  if (![self validateV2Lease:lease root:root error:error]) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorChanged);
    return nil;
  }
  NSMutableDictionary *receipt = [baseReceipt mutableCopy];
  receipt[@"schema_version"] = @2;
  receipt[@"root"] = root;
  receipt[@"workspace_id"] = root[@"workspace_id"];
  receipt[@"workspace_binding_revision"] = root[@"binding_revision"];
  return receipt;
}

- (NSDictionary *)inspectSnapshotV2:(NSDictionary *)request
                               error:(NSError **)error {
  NSArray *keys = @[@"schema_version", @"snapshot_id", @"root"];
  NSDictionary *root = DSHServiceV2RootRef(request[@"root"], YES);
  NSString *snapshotId = DSHServiceCanonicalIdentifierString(request[@"snapshot_id"]);
  if (!DSHServiceExactKeys(request, keys) ||
      ![request[@"schema_version"] isKindOfClass:NSNumber.class] ||
      DSHServiceIsBoolean(request[@"schema_version"]) ||
      [request[@"schema_version"] isKindOfClass:NSDecimalNumber.class] ||
      ![request[@"schema_version"] isEqual:@2] || snapshotId == nil ||
      root == nil) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorInvalidArgument);
    return nil;
  }
  if (self.borrowedLegacyLease == nil) {
    __block NSDictionary *legacyResult = nil;
    DSHLegacyBoundProjectRootDisposition disposition =
        [self performLegacyContextForRoot:root
            operation:^BOOL(NSError **operationError) {
              legacyResult = [self inspectSnapshotV2:request error:operationError];
              return legacyResult != nil;
            } error:error];
    if (disposition == DSHLegacyBoundProjectRootDispositionHandled) return legacyResult;
    if (disposition == DSHLegacyBoundProjectRootDispositionFailed) return nil;
  }
  NSError *storeError = nil;
  NSDictionary *snapshot = [self.store loadSnapshotId:snapshotId error:&storeError];
  if (snapshot == nil) {
    DSHSetServiceError(error, DSHServiceSnapshotStoreError(storeError));
    return nil;
  }
  if (!DSHServiceV2RootsEqual(root, snapshot[@"manifest"][@"root"])) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorChanged);
    return nil;
  }
  NSError *verificationError = nil;
  BOOL live = [self verifyLiveSnapshotV2:snapshot
                                   root:root
                          retainedLease:nil
                                   error:&verificationError];
  if (!live && verificationError.code == DSHProjectContextServiceErrorIntegrity) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorIntegrity);
    return nil;
  }
  if (live) {
    DSHLocalProjectLease *resultLease = [self v2LeaseForRoot:root
                                              includeMetadata:NO
                                                       error:error];
    if (resultLease == nil ||
        ![self validateV2Lease:resultLease root:root error:error]) {
      DSHSetServiceError(error, DSHProjectContextServiceErrorChanged);
      return nil;
    }
  }
  NSMutableDictionary *inspection = [snapshot[@"manifest"] mutableCopy];
  NSDictionary *source = snapshot[@"source_descriptor"];
  NSString *referenceId = source[@"reference_id"];
  NSString *activeKey = [@"active:" stringByAppendingString:referenceId ?: @""];
  NSString *transactionKey = [@"txn:prepare:" stringByAppendingString:referenceId ?: @""];
  BOOL prepared = [self.store snapshotIdForReferenceKey:transactionKey error:nil] != nil &&
      [[self.store snapshotIdForReferenceKey:activeKey error:nil] isEqual:snapshotId];
  BOOL confirmed = NO;
  if (live && !prepared) {
    for (NSURL *url in [self.store fileURLsForSnapshotId:snapshotId error:nil]) {
      if (![url.URLByDeletingLastPathComponent.lastPathComponent isEqual:@"consents"]) {
        continue;
      }
      NSDictionary *consent = [self.store loadConsentReceiptId:url.lastPathComponent.stringByDeletingPathExtension
                                                          error:nil];
      if ([consent[@"snapshot_id"] isEqual:snapshotId] &&
          [consent[@"snapshot_sha256"] isEqual:snapshot[@"manifest"][@"snapshot_sha256"]]) {
        confirmed = YES;
        break;
      }
    }
  }
  inspection[@"state"] = live ? (confirmed ? @"confirmed" : @"prepared") : @"stale";
  return inspection;
}

- (NSDictionary *)discardSnapshotV2:(NSDictionary *)request
                               error:(NSError **)error {
  NSArray *keys = @[@"schema_version", @"snapshot_id", @"root"];
  NSDictionary *root = DSHServiceV2RootRef(request[@"root"], YES);
  NSString *snapshotId =
      DSHServiceCanonicalIdentifierString(request[@"snapshot_id"]);
  if (!DSHServiceExactKeys(request, keys) ||
      ![request[@"schema_version"] isKindOfClass:NSNumber.class] ||
      DSHServiceIsBoolean(request[@"schema_version"]) ||
      [request[@"schema_version"] isKindOfClass:NSDecimalNumber.class] ||
      ![request[@"schema_version"] isEqual:@2] || snapshotId == nil ||
      root == nil) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorInvalidArgument);
    return nil;
  }
  if (self.borrowedLegacyLease == nil) {
    __block NSDictionary *legacyResult = nil;
    DSHLegacyBoundProjectRootDisposition disposition =
        [self performLegacyContextForRoot:root
            operation:^BOOL(NSError **operationError) {
              legacyResult = [self discardSnapshotV2:request error:operationError];
              return legacyResult != nil;
            } error:error];
    if (disposition == DSHLegacyBoundProjectRootDispositionHandled) return legacyResult;
    if (disposition == DSHLegacyBoundProjectRootDispositionFailed) return nil;
  }

  NSError *storeError = nil;
  NSDictionary *snapshot = [self.store loadSnapshotId:snapshotId
                                                  error:&storeError];
  if (snapshot == nil) {
    DSHSetServiceError(error, DSHServiceSnapshotStoreError(storeError));
    return nil;
  }
  NSDictionary *manifest = snapshot[@"manifest"];
  NSDictionary *source = snapshot[@"source_descriptor"];
  if (![manifest isKindOfClass:NSDictionary.class] ||
      ![source isKindOfClass:NSDictionary.class]) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorIntegrity);
    return nil;
  }
  if (!DSHServiceV2RootsEqual(root, manifest[@"root"])) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorChanged);
    return nil;
  }
  // The source relation is private store integrity, not a caller-selected
  // path. Refuse to detach anything when the snapshot's root/project binding
  // is internally inconsistent.
  if (!DSHServiceV2RootsEqual(root, source[@"root"]) ||
      ![manifest[@"snapshot_id"] isEqual:snapshotId] ||
      ![manifest[@"project_id"] isEqual:root[@"project_id"]] ||
      ![source[@"project_id"] isEqual:root[@"project_id"]] ||
      ![source[@"workspace_id"] isEqual:root[@"workspace_id"]] ||
      ![source[@"workspace_binding_revision"]
          isEqual:root[@"binding_revision"]]) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorIntegrity);
    return nil;
  }

  DSHLocalProjectLease *lease = nil;
  if (![self verifyLiveSnapshotV2:snapshot
                              root:root
                     retainedLease:&lease
                              error:error]) {
    return nil;
  }
  NSString *referenceId = source[@"reference_id"];
  NSString *activeKey = [@"active:" stringByAppendingString:referenceId ?: @""];
  NSString *transactionKey =
      [@"txn:prepare:" stringByAppendingString:referenceId ?: @""];
  NSError *referenceError = nil;
  NSString *activeSnapshot = [self.store snapshotIdForReferenceKey:activeKey
                                                               error:&referenceError];
  if (referenceError != nil) {
    DSHSetServiceError(error, DSHServiceSnapshotStoreError(referenceError));
    return nil;
  }
  NSString *transactionValue =
      [self.store snapshotIdForReferenceKey:transactionKey error:&referenceError];
  if (referenceError != nil) {
    DSHSetServiceError(error, DSHServiceSnapshotStoreError(referenceError));
    return nil;
  }
  if (![activeSnapshot isEqual:snapshotId] ||
      (transactionValue != nil &&
       ![transactionValue isEqual:DSHServiceV2PrepareNoPriorSnapshotId] &&
       !DSHServiceCanonicalIdentifier(transactionValue))) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorChanged);
    return nil;
  }

  if (self.hook != nil) self.hook(@"before_v2_discard", nil);
  BOOL applied = NO;
  NSError *effectError = nil;
  if (transactionValue != nil) {
    applied = [self.store abortPrepareTransactionForSnapshotId:snapshotId
                                             activeReferenceKey:activeKey
                                                          error:&effectError];
  } else {
    applied = [self.store clearReferenceKey:activeKey error:&effectError];
  }
  if (!applied) {
    if (effectError.code == DSHProjectContextStoreErrorIntegrity ||
        effectError.code == DSHProjectContextStoreErrorNotFound) {
      DSHSetServiceError(error, DSHProjectContextServiceErrorChanged);
    } else {
      DSHSetServiceError(error, DSHServiceSnapshotStoreError(effectError));
    }
    return nil;
  }
  if (self.hook != nil) self.hook(@"after_v2_discard", nil);
  if (![self validateV2Lease:lease root:root error:error]) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorChanged);
    return nil;
  }

  NSError *remainingError = nil;
  NSDictionary *remaining = [self.store loadSnapshotId:snapshotId
                                                  error:&remainingError];
  if (remaining != nil) {
    // A different reference may still retain this snapshot. The requested
    // root relation was detached, but claiming deletion would be false.
    DSHSetServiceError(error, DSHProjectContextServiceErrorChanged);
    return nil;
  }
  if (remainingError != nil &&
      remainingError.code != DSHProjectContextStoreErrorNotFound) {
    DSHSetServiceError(error, DSHServiceSnapshotStoreError(remainingError));
    return nil;
  }
  return @{
    @"schema_version" : @2,
    @"status" : @"discarded",
    @"snapshot_id" : snapshotId,
    @"root" : root,
    @"workspace_id" : root[@"workspace_id"],
    @"workspace_binding_revision" : root[@"binding_revision"],
  };
}

- (NSData *)verifiedEnvelopeV2:(NSDictionary *)request
                        receipt:(NSDictionary **)receipt
                          error:(NSError **)error {
  return [self verifiedEnvelopeV2:request requireLiveSource:YES receipt:receipt error:error];
}

- (NSData *)verifiedFrozenEnvelopeV2:(NSDictionary *)request
                             receipt:(NSDictionary **)receipt
                               error:(NSError **)error {
  return [self verifiedEnvelopeV2:request requireLiveSource:NO receipt:receipt error:error];
}

- (NSData *)verifiedEnvelopeV2:(NSDictionary *)request
             requireLiveSource:(BOOL)requireLiveSource
                       receipt:(NSDictionary **)receipt
                         error:(NSError **)error {
  NSArray *keys = @[
    @"schema_version", @"snapshot_id", @"consent_receipt_id", @"root",
    @"conversation_id", @"model_id", @"policy"
  ];
  NSDictionary *root = DSHServiceV2RootRef(request[@"root"], YES);
  NSString *snapshotId = DSHServiceCanonicalIdentifierString(request[@"snapshot_id"]);
  NSString *consentId = DSHServiceCanonicalIdentifierString(request[@"consent_receipt_id"]);
  NSString *conversation = DSHServiceCanonicalIdentifierString(request[@"conversation_id"]);
  NSString *model = DSHServiceV2Model(request[@"model_id"]);
  NSString *policy = DSHServiceV2BoundedString(request[@"policy"], 64, NO);
  if (!DSHServiceExactKeys(request, keys) ||
      ![request[@"schema_version"] isKindOfClass:NSNumber.class] ||
      DSHServiceIsBoolean(request[@"schema_version"]) ||
      [request[@"schema_version"] isKindOfClass:NSDecimalNumber.class] ||
      ![request[@"schema_version"] isEqual:@2] || snapshotId == nil ||
      consentId == nil || root == nil || conversation == nil || model == nil ||
      ![policy isEqual:@"chat-read-v1"]) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorInvalidArgument);
    return nil;
  }
  if (self.borrowedLegacyLease == nil) {
    __block NSData *legacyResult = nil;
    __block NSDictionary *legacyReceipt = nil;
    DSHLegacyBoundProjectRootDisposition disposition =
        [self performLegacyContextForRoot:root
            operation:^BOOL(NSError **operationError) {
              legacyResult = [self verifiedEnvelopeV2:request
                                    requireLiveSource:requireLiveSource
                                              receipt:&legacyReceipt
                                                error:operationError];
              return legacyResult != nil;
            } error:error];
    if (disposition == DSHLegacyBoundProjectRootDispositionHandled) {
      if (receipt != nil) *receipt = legacyReceipt;
      return legacyResult;
    }
    if (disposition == DSHLegacyBoundProjectRootDispositionFailed) return nil;
  }
  NSError *authorizationError = nil;
  DSHProjectContextAuthorizationLease *authorization = [self.store
      beginAuthorizationForSnapshotId:snapshotId activeReferenceKey:nil
                                 error:&authorizationError];
  if (authorization == nil) {
    DSHSetServiceError(error, DSHServiceSnapshotStoreError(authorizationError));
    return nil;
  }
  NSDictionary *snapshot = authorization.snapshot;
  NSDictionary *manifest = snapshot[@"manifest"];
  NSDictionary *source = snapshot[@"source_descriptor"];
  NSDictionary *storedRoot = source[@"root"];
  NSDictionary *consent = [self.store loadConsentReceiptId:consentId error:nil];
  NSString *referenceId = source[@"reference_id"];
  NSString *transactionKey = [@"txn:prepare:" stringByAppendingString:referenceId ?: @""];
  NSString *activeKey = [@"active:" stringByAppendingString:referenceId ?: @""];
  if (!DSHServiceV2RootsEqual(root, storedRoot) ||
      ![referenceId isKindOfClass:NSString.class] ||
      ![referenceId isEqual:DSHServiceV2ReferenceId(
          root, source[@"root_fingerprint_sha256"], conversation)] ||
      ![conversation isEqual:source[@"conversation_id"]] ||
      ![model isEqual:source[@"model_id"]] ||
      ![policy isEqual:source[@"policy"]] ||
      ![consent[@"snapshot_id"] isEqual:snapshotId] ||
      ![consent[@"snapshot_sha256"] isEqual:manifest[@"snapshot_sha256"]]) {
    [self.store cancelAuthorizationLease:authorization];
    DSHSetServiceError(error, DSHProjectContextServiceErrorConsent);
    return nil;
  }
  if ([self.store snapshotIdForReferenceKey:transactionKey error:nil] != nil &&
      [[self.store snapshotIdForReferenceKey:activeKey error:nil] isEqual:snapshotId]) {
    [self.store cancelAuthorizationLease:authorization];
    DSHSetServiceError(error, DSHProjectContextServiceErrorConsent);
    return nil;
  }
  DSHLocalProjectLease *liveLease = nil;
  if (![self verifySnapshotV2:snapshot root:root requireLiveSource:requireLiveSource
                retainedLease:&liveLease error:error]) {
    [self.store cancelAuthorizationLease:authorization];
    return nil;
  }
  if (self.hook != nil) self.hook(@"before_v2_authorization_complete", nil);
  __block NSDictionary *verifiedReceipt = nil;
  authorizationError = nil;
  NSData *verified = [self.store
      completeAuthorizationLease:authorization
             activeReferenceKey:activeKey
                      operation:^id(NSDictionary *current, NSError **storeError) {
                        if (![self validateV2Lease:liveLease root:root error:nil]) {
                          if (storeError != nil) {
                            *storeError = [NSError errorWithDomain:
                                DSHProjectContextStoreErrorDomain
                                                             code:DSHProjectContextStoreErrorIntegrity
                                                         userInfo:@{}];
                          }
                          return nil;
                        }
                        NSDictionary *finalConsent = [self.store
                            loadConsentReceiptId:consentId error:storeError];
                        if (![finalConsent[@"snapshot_id"] isEqual:snapshotId] ||
                            ![finalConsent[@"snapshot_sha256"]
                                isEqual:current[@"manifest"][@"snapshot_sha256"]]) {
                          if (storeError != nil && *storeError == nil) {
                            *storeError = [NSError errorWithDomain:
                                DSHProjectContextStoreErrorDomain
                                                             code:DSHProjectContextStoreErrorIntegrity
                                                         userInfo:@{}];
                          }
                          return nil;
                        }
                        verifiedReceipt = @{
                          @"schema_version" : @2,
                          @"snapshot_id" : snapshotId,
                          @"root" : root,
                          @"snapshot_sha256" : current[@"manifest"][@"snapshot_sha256"],
                          @"source_fingerprint" : current[@"manifest"][@"source_fingerprint"],
                          @"context_bytes" : current[@"manifest"][@"context_bytes"],
                          @"verified_at" : DSHServiceISO8601(self.clock()),
                        };
                        return [current[@"envelope"] copy];
                      }
                          error:&authorizationError];
  if (verified == nil) {
    DSHSetServiceError(error,
        authorizationError.code == DSHProjectContextStoreErrorIntegrity
            ? DSHProjectContextServiceErrorChanged
            : (authorizationError.code == DSHProjectContextStoreErrorCapacity
                   ? DSHProjectContextServiceErrorBudgetExceeded
                   : (authorizationError.code == DSHProjectContextStoreErrorNotFound
                          ? DSHProjectContextServiceErrorConsent
                          : DSHProjectContextServiceErrorStorage)));
    return nil;
  }
  if (self.hook != nil) self.hook(@"after_v2_authorization_complete", nil);
  if (![self validateV2Lease:liveLease root:root error:error]) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorChanged);
    return nil;
  }
  if (receipt != nil) *receipt = verifiedReceipt;
  return verified;
}

- (NSDictionary *)prepareCandidateV2WithRoot:(NSDictionary *)rootRef
                               conversationId:(NSString *)conversationId
                                      modelId:(NSString *)modelId
                                       policy:(NSString *)policy
                                selectedPaths:(NSArray<NSString *> *)selectedPaths
                                        error:(NSError **)error {
  return [self prepareCandidateV2:@{
    @"schema_version" : @2,
    @"root" : rootRef ?: NSNull.null,
    @"conversation_id" : conversationId ?: NSNull.null,
    @"model_id" : modelId ?: NSNull.null,
    @"policy" : policy ?: NSNull.null,
    @"selected_paths" : selectedPaths ?: NSNull.null,
  } error:error];
}

- (NSDictionary *)confirmSnapshotV2Id:(NSString *)snapshotId
                                   root:(NSDictionary *)rootRef
                                   error:(NSError **)error {
  return [self confirmSnapshotV2:@{
    @"schema_version" : @2,
    @"snapshot_id" : snapshotId ?: NSNull.null,
    @"root" : rootRef ?: NSNull.null,
  } error:error];
}

- (NSDictionary *)inspectSnapshotV2Id:(NSString *)snapshotId
                                   root:(NSDictionary *)rootRef
                                   error:(NSError **)error {
  return [self inspectSnapshotV2:@{
    @"schema_version" : @2,
    @"snapshot_id" : snapshotId ?: NSNull.null,
    @"root" : rootRef ?: NSNull.null,
  } error:error];
}

- (NSDictionary *)discardSnapshotV2Id:(NSString *)snapshotId
                                  root:(NSDictionary *)rootRef
                                 error:(NSError **)error {
  return [self discardSnapshotV2:@{
    @"schema_version" : @2,
    @"snapshot_id" : snapshotId ?: NSNull.null,
    @"root" : rootRef ?: NSNull.null,
  } error:error];
}

- (NSData *)verifiedEnvelopeV2ForSnapshotId:(NSString *)snapshotId
                            consentReceiptId:(NSString *)consentReceiptId
                                         root:(NSDictionary *)rootRef
                              conversationId:(NSString *)conversationId
                                     modelId:(NSString *)modelId
                                      policy:(NSString *)policy
                                     receipt:(NSDictionary **)receipt
                                       error:(NSError **)error {
  return [self verifiedEnvelopeV2:@{
    @"schema_version" : @2,
    @"snapshot_id" : snapshotId ?: NSNull.null,
    @"consent_receipt_id" : consentReceiptId ?: NSNull.null,
    @"root" : rootRef ?: NSNull.null,
    @"conversation_id" : conversationId ?: NSNull.null,
    @"model_id" : modelId ?: NSNull.null,
    @"policy" : policy ?: NSNull.null,
  } receipt:receipt error:error];
}

- (NSData *)verifiedEnvelopeV2ForSnapshotId:(NSString *)snapshotId
                            consentReceiptId:(NSString *)consentReceiptId
                                 requestBind:(NSDictionary *)requestBind
                                     receipt:(NSDictionary **)receipt
                                       error:(NSError **)error {
  if (!DSHServiceExactKeys(requestBind, @[
        @"schema_version", @"root", @"conversation_id", @"model_id", @"policy"
      ]) ||
      ![requestBind[@"schema_version"] isKindOfClass:NSNumber.class] ||
      DSHServiceIsBoolean(requestBind[@"schema_version"]) ||
      [requestBind[@"schema_version"] isKindOfClass:NSDecimalNumber.class] ||
      ![requestBind[@"schema_version"] isEqual:@2]) {
    DSHSetServiceError(error, DSHProjectContextServiceErrorInvalidArgument);
    return nil;
  }
  NSMutableDictionary *request = [requestBind mutableCopy];
  request[@"snapshot_id"] = snapshotId ?: NSNull.null;
  request[@"consent_receipt_id"] = consentReceiptId ?: NSNull.null;
  return [self verifiedEnvelopeV2:request receipt:receipt error:error];
}

@end

static DSHLocalWorkspaceAccess *DSHSharedProjectContextWorkspaceAccess(void) {
  static DSHLocalWorkspaceAccess *access = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    NSError *error = nil;
    NSURL *support = [[NSFileManager defaultManager]
        URLForDirectory:NSApplicationSupportDirectory
               inDomain:NSUserDomainMask
      appropriateForURL:nil
                 create:YES
                  error:&error];
    if (support == nil) return;
    access = [[DSHLocalWorkspaceAccess alloc]
        initWithPrivateRootURL:support
        clock:^NSDate * {
          return NSDate.date;
        }
        UUIDGenerator:^NSString * {
          return NSUUID.UUID.UUIDString.lowercaseString;
        }
        legacyResolver:^BOOL(NSString *projectId,
                             NSDictionary **evidence,
                             NSError **resolverError) {
          NSError *projectError = nil;
          NSDictionary *resolved = [[DSHLocalProjectAccess sharedAccess]
              legacyWorkspaceBootstrapEvidenceForProjectId:projectId
                                                     error:&projectError];
          if (resolved == nil) {
            if (resolverError != nil) *resolverError = projectError;
            return NO;
          }
          if (evidence != nil) *evidence = [resolved copy];
          return YES;
        }
        faultHook:nil];
  });
  return access;
}

DSHProjectContextService *DSHSharedProjectContextService(void) {
  static DSHProjectContextService *shared = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    DSHLocalWorkspaceAccess *workspaceAccess =
        DSHSharedProjectContextWorkspaceAccess();
    DSHLocalProjectAccess *projectAccess = [[DSHLocalProjectAccess alloc]
        initWithWorkspaceAccess:workspaceAccess
              bindingResolver:nil
                          hook:nil];
    shared = [[DSHProjectContextService alloc]
        initWithProjectAccess:projectAccess
               workspaceAccess:workspaceAccess
                          store:[[DSHProjectContextStore alloc] init]
                         policy:[[DSHProjectContextPolicy alloc] init]
                          clock:^NSDate * {
                            return NSDate.date;
                          }
            identifierGenerator:^NSString * {
              return NSUUID.UUID.UUIDString.lowercaseString;
            }
                             hook:nil];
  });
  return shared;
}
