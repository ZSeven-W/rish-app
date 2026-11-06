#import <XCTest/XCTest.h>

#import <CommonCrypto/CommonDigest.h>

#import "DSHTestHost.h"

#import "../../../../modules/rish/ios/Sources/LocalWorkspaceAccess.h"
#import "../../../../modules/rish/ios/Sources/DSHWorkspaceCanonical.h"
#import "DSHTestStorageFixture.h"

#include <math.h>
#include <fcntl.h>
#include <sys/stat.h>

typedef void (^DSHLWResolve)(id value);
typedef void (^DSHLWReject)(NSString *code, NSString *message, NSError *error);

@protocol DSHLocalWorkspacesModuleTesting <NSObject>
- (void)createWorkspaceRequest:(id)request
                       resolver:(DSHLWResolve)resolve
                       rejecter:(DSHLWReject)reject;
- (void)resolveWorkspaceRequest:(id)request
                        resolver:(DSHLWResolve)resolve
                        rejecter:(DSHLWReject)reject;
- (void)queryOperationRequest:(id)request
                       resolver:(DSHLWResolve)resolve
                       rejecter:(DSHLWReject)reject;
@end

@interface LocalWorkspaceAccessTests : XCTestCase
@property(nonatomic, strong) NSURL *fixtureRootURL;
@property(nonatomic, strong) NSURL *rootURL;
@property(nonatomic, strong) NSURL *documentsURL;
@property(nonatomic, strong) NSDate *now;
@property(nonatomic) NSUInteger resolverCalls;
@property(nonatomic) BOOL resolverThrows;
@property(nonatomic, copy) NSString *resolverIdentity;
@property(nonatomic, copy) NSString *resolverDisplayName;
@property(nonatomic, copy) NSSet<NSString *> *resolverCapabilities;
@property(nonatomic, copy) NSString *resolverRepositoryInode;
@end

@implementation LocalWorkspaceAccessTests

static NSString *const DSHWorkspaceA =
    @"11111111-1111-4111-8111-111111111111";
static NSString *const DSHWorkspaceB =
    @"22222222-2222-4222-8222-222222222222";
static NSString *const DSHWorkspaceC =
    @"33333333-3333-4333-8333-333333333333";
static NSString *const DSHWorkspaceD =
    @"44444444-4444-4444-8444-444444444444";
static NSString *const DSHProjectA =
    @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
static NSString *const DSHProjectWide =
    @"dddddddd-dddd-7ddd-cddd-dddddddddddd";
static NSString *const DSHOperationA =
    @"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
static NSString *const DSHOperationB =
    @"cccccccc-cccc-4ccc-8ccc-cccccccccccc";
static NSString *const DSHTimestamp = @"2026-08-29T00:00:00.000Z";
static NSString *const DSHDigestA =
    @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
static NSString *const DSHDigestB =
    @"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

- (void)testRootFingerprintUsesExactJCSAndDomainSeparation {
  NSDictionary *input = @{
    @"schema_version" : @1,
    @"origin" : @"rish_created",
    @"workspace_id" : DSHWorkspaceA,
    @"binding_revision" : @7,
    @"root_locator_kind" : @"documents_owned",
    @"device_id" : @"4",
    @"inode_id" : @"8",
    @"directory_name_sha256" : DSHDigestA,
    @"authority_sha256" : DSHDigestB,
  };
  NSError *error = nil;
  NSData *canonical = DSHWorkspaceCanonicalJSONData(input, &error);
  XCTAssertNotNil(canonical);
  XCTAssertNil(error);
  XCTAssertEqualObjects(
      [[NSString alloc] initWithData:canonical encoding:NSUTF8StringEncoding],
      @"{\"authority_sha256\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"binding_revision\":7,\"device_id\":\"4\",\"directory_name_sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"inode_id\":\"8\",\"origin\":\"rish_created\",\"root_locator_kind\":\"documents_owned\",\"schema_version\":1,\"workspace_id\":\"11111111-1111-4111-8111-111111111111\"}");
  XCTAssertTrue(DSHWorkspaceValidateRootFingerprintInput(input, &error));
  XCTAssertEqualObjects(
      DSHWorkspaceRootFingerprintSHA256(input, &error),
      @"d6df01a63e0b6c19597592adc25f012511f95f252ba4fa99ec4704fafd566be1");
  XCTAssertNil(error);
}

- (void)testCanonicalNumbersMatchECMAScriptJCSVectors {
  NSArray *vectors = @[
    @[@(1.0e-6), @"0.000001"],
    @[@(1.0e-7), @"1e-7"],
    @[@(1.0e20), @"100000000000000000000"],
    @[@(1.0e21), @"1e+21"],
    @[@(1.2345678901234567), @"1.2345678901234567"],
    @[@(-1.0e-7), @"-1e-7"],
  ];
  for (NSArray *vector in vectors) {
    NSData *data = DSHWorkspaceCanonicalJSONData(vector[0], nil);
    XCTAssertEqualObjects([[NSString alloc] initWithData:data
                                                  encoding:NSUTF8StringEncoding],
                          vector[1]);
  }
  NSError *error = nil;
  XCTAssertNil(DSHWorkspaceCanonicalJSONData(@(9007199254740993ULL), &error));
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_INVALID");
}

- (void)setUp {
  [super setUp];
  NSError *error = nil;
  self.fixtureRootURL = DSHCreateTestStorageFixtureRoot(
      @"LocalWorkspaceAccessTests", &error);
  XCTAssertNotNil(self.fixtureRootURL, @"%@", error);
  if (self.fixtureRootURL == nil) return;
  self.rootURL = [self.fixtureRootURL URLByAppendingPathComponent:@"private"
                                                       isDirectory:YES];
  self.documentsURL = [self.fixtureRootURL
      URLByAppendingPathComponent:@"Documents" isDirectory:YES];
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:self.rootURL
                                       withIntermediateDirectories:YES
                                                        attributes:@{
                                                          NSFilePosixPermissions : @0700
                                                        }
                                                             error:&error], @"%@", error);
  self.now = [NSDate dateWithTimeIntervalSince1970:1787961600];
  self.resolverCalls = 0;
  self.resolverThrows = NO;
  self.resolverIdentity = DSHDigestA;
  self.resolverDisplayName = @"Legacy Repo";
  self.resolverCapabilities = [NSSet setWithArray:
      @[@"read", @"write", @"git", @"project_context"]];
  self.resolverRepositoryInode = @"9";
}

- (void)tearDown {
  if (self.fixtureRootURL != nil) {
    [NSFileManager.defaultManager removeItemAtURL:self.fixtureRootURL error:nil];
  }
  self.documentsURL = nil;
  self.rootURL = nil;
  self.fixtureRootURL = nil;
  [super tearDown];
}

- (DSHLocalWorkspaceAccess *)accessWithRoot:(NSURL *)root
                                       fault:(nullable DSHLocalWorkspaceFaultHook)fault {
  return [self accessWithRoot:root fault:fault workspaceId:DSHWorkspaceA];
}

- (DSHLocalWorkspaceAccess *)accessWithRoot:(NSURL *)root
                                       fault:(nullable DSHLocalWorkspaceFaultHook)fault
                                 workspaceId:(NSString *)workspaceId {
  return [self accessWithRoot:root fault:fault UUIDGenerator:^NSString *{
    return workspaceId;
  }];
}

- (DSHLocalWorkspaceAccess *)accessWithRoot:(NSURL *)root
                                       fault:(nullable DSHLocalWorkspaceFaultHook)fault
                               UUIDGenerator:(DSHLocalWorkspaceUUIDGenerator)UUIDGenerator {
  return [self accessWithRoot:root
                documentsRootURL:nil
                         fault:fault
                   UUIDGenerator:UUIDGenerator];
}

- (DSHLocalWorkspaceAccess *)accessWithRoot:(NSURL *)root
                           documentsRootURL:(nullable NSURL *)documentsRootURL
                                      fault:(nullable DSHLocalWorkspaceFaultHook)fault
                              UUIDGenerator:(DSHLocalWorkspaceUUIDGenerator)UUIDGenerator {
  __weak LocalWorkspaceAccessTests *weakSelf = self;
  return [[DSHLocalWorkspaceAccess alloc]
      initWithPrivateRootURL:root
          documentsRootURL:documentsRootURL
      clock:^NSDate *{
        return weakSelf.now;
      }
      UUIDGenerator:UUIDGenerator
      legacyResolver:^BOOL(NSString *projectId,
                           NSDictionary *__autoreleasing *evidence,
                           NSError *__autoreleasing *error) {
        __strong LocalWorkspaceAccessTests *self = weakSelf;
        self.resolverCalls += 1;
        if (self.resolverThrows) {
          [NSException raise:@"PrivateResolverFailure"
                      format:@"native path /private/secret must not escape"];
        }
        if (![projectId isEqual:DSHProjectA] &&
            ![projectId isEqual:DSHProjectWide]) {
          if (error != nil) {
            *error = [NSError errorWithDomain:@"private.native"
                                         code:71
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"provider /private/secret unavailable"}];
          }
          return NO;
        }
        if (evidence != nil) {
          *evidence = @{
            @"project_id" : projectId,
            @"display_name" : self.resolverDisplayName,
            @"metadata_sha256" : self.resolverIdentity,
            @"capabilities" : self.resolverCapabilities,
            @"projects_root_device_id" : @"42",
            @"projects_root_inode_id" : @"84",
            @"repository_device_id" : @"7",
            @"repository_inode_id" : self.resolverRepositoryInode,
            @"git_device_id" : @"11",
            @"git_inode_id" : @"13",
          };
        }
        return YES;
      }
      faultHook:fault];
}

- (DSHLocalWorkspaceAccess *)access {
  return [self accessWithRoot:self.rootURL fault:nil];
}

- (id<DSHLocalWorkspacesModuleTesting>)workspaceModuleWithAccess:
    (DSHLocalWorkspaceAccess *)access {
  Class cls = NSClassFromString(@"LocalWorkspacesModule");
  XCTAssertNotNil(cls);
  id module = [[(id)cls alloc] init];
  [module setValue:access forKey:@"access"];
  return module;
}

- (NSURL *)registryURLForRoot:(NSURL *)root {
  return [[root URLByAppendingPathComponent:@"local-workspaces"
                                isDirectory:YES]
      URLByAppendingPathComponent:@"registry-v1.json"];
}

- (NSURL *)receiptsURLForRoot:(NSURL *)root {
  return [[root URLByAppendingPathComponent:@"local-workspaces"
                                isDirectory:YES]
      URLByAppendingPathComponent:@"receipts-v1.json"];
}

- (NSURL *)journalURLForRoot:(NSURL *)root {
  return [[root URLByAppendingPathComponent:@"local-workspaces"
                                isDirectory:YES]
      URLByAppendingPathComponent:@"authority-journal-v1.json"];
}

- (NSURL *)documentsRootForRoot:(NSURL *)root {
  if ([root.URLByStandardizingPath.path
          isEqual:self.rootURL.URLByStandardizingPath.path]) {
    return self.documentsURL;
  }
  return [root URLByAppendingPathComponent:@"Documents" isDirectory:YES];
}

- (NSURL *)ownedWorkspacesRootForRoot:(NSURL *)root {
  return [[self documentsRootForRoot:root]
      URLByAppendingPathComponent:@"Rish Workspaces" isDirectory:YES];
}

- (NSDictionary *)registryObjectForRoot:(NSURL *)root {
  NSData *data = [NSData dataWithContentsOfURL:[self registryURLForRoot:root]];
  return data == nil ? nil : [NSJSONSerialization JSONObjectWithData:data
                                                               options:0
                                                                 error:nil];
}

- (NSDictionary *)recordForRoot:(NSURL *)root workspaceId:(NSString *)workspaceId {
  for (NSDictionary *record in [self registryObjectForRoot:root][@"records"]) {
    if ([record[@"workspace_id"] isEqual:workspaceId]) return record;
  }
  return nil;
}

- (NSURL *)authorityURLForRoot:(NSURL *)root
                           kind:(NSString *)kind
                    workspaceId:(NSString *)workspaceId
                       revision:(NSUInteger)revision {
  NSString *name = [NSString stringWithFormat:@"%@-%@-r%lu.json", kind,
                    workspaceId, (unsigned long)revision];
  return [[root URLByAppendingPathComponent:@"workspace-bindings"
                                isDirectory:YES]
      URLByAppendingPathComponent:name];
}

- (NSString *)sha256ForData:(NSData *)data {
  unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {};
  CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  NSMutableString *result = [NSMutableString stringWithCapacity:64];
  for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
    [result appendFormat:@"%02x", digest[index]];
  }
  return result;
}

- (NSString *)createRequestDigestForDisplayName:(NSString *)displayName {
  NSDictionary *request = @{
    @"operation": @"create",
    @"display_name": displayName,
  };
  return [self sha256ForData:[self canonicalData:request]];
}

- (NSString *)bootstrapRequestDigestForProjectId:(NSString *)projectId {
  NSDictionary *request = @{
    @"schema_version": @1,
    @"operation": @"bootstrap_legacy",
    @"project_id": projectId,
  };
  return [self sha256ForData:[self canonicalData:request]];
}

- (NSData *)canonicalData:(id)object {
  return DSHWorkspaceCanonicalJSONData(object, nil);
}

- (void)secureWriteObject:(id)object toURL:(NSURL *)url {
  NSData *data = [self canonicalData:object];
  XCTAssertNotNil(data);
  [self secureWriteData:data toURL:url];
}

- (void)secureWriteData:(NSData *)data toURL:(NSURL *)url {
  NSError *error = nil;
  XCTAssertTrue(DSHWriteProtectedTestFixture(data, url, &error), @"%@", error);
}

- (NSDictionary *)recordForWorkspaceId:(NSString *)workspaceId
                                  origin:(NSString *)origin
                         rootLocatorKind:(NSString *)rootLocatorKind
                           locationClass:(NSString *)locationClass
                     ownedDirectoryName:(nullable NSString *)ownedDirectoryName
                        legacyProjectId:(nullable NSString *)legacyProjectId
                        bindingRevision:(NSUInteger)bindingRevision {
  return @{
    @"schema_version": @1,
    @"workspace_id": workspaceId,
    @"display_name": [NSString stringWithFormat:@"Workspace %@",
                      [workspaceId substringToIndex:4]],
    @"origin": origin,
    @"root_locator_kind": rootLocatorKind,
    @"location_class": locationClass,
    @"owned_directory_name": ownedDirectoryName ?: NSNull.null,
    @"legacy_project_id": legacyProjectId ?: NSNull.null,
    @"binding_revision": @(bindingRevision),
    @"created_at": DSHTimestamp,
    @"last_opened_at": DSHTimestamp,
  };
}

- (NSDictionary *)legacyRecordWithRevision:(NSUInteger)revision {
  return [self recordForWorkspaceId:DSHWorkspaceA
                             origin:@"legacy_app_owned"
                    rootLocatorKind:@"legacy_app_owned"
                      locationClass:@"rish_owned"
                ownedDirectoryName:nil
                   legacyProjectId:DSHProjectA
                   bindingRevision:revision];
}

- (NSDictionary *)legacyAuthorityWithRevision:(NSUInteger)revision
                                authorityDigest:(NSString *)digest {
  return [self legacyAuthorityForWorkspace:DSHWorkspaceA
                                  projectId:DSHProjectA
                               displayName:[self legacyRecordWithRevision:revision][@"display_name"]
                                  revision:revision
                           authorityDigest:digest];
}

- (NSDictionary *)legacyAuthorityForWorkspace:(NSString *)workspaceId
                                     projectId:(NSString *)projectId
                                  displayName:(NSString *)displayName
                                     revision:(NSUInteger)revision
                              authorityDigest:(NSString *)digest {
  NSDictionary *base = @{
    @"schema_version": @1,
    @"workspace_id": workspaceId,
    @"binding_revision": @(revision),
    @"legacy_project_id": projectId,
    @"root_identity_sha256": digest,
    @"display_name": displayName,
    @"capabilities": @[@"read", @"write", @"git", @"project_context"],
    @"created_at": DSHTimestamp,
    @"last_opened_at": DSHTimestamp,
    @"recorded_at": DSHTimestamp,
    @"project_metadata_sha256": digest,
    @"projects_root_device_id": @"42",
    @"projects_root_inode_id": @"84",
    @"repository_device_id": @"7",
    @"repository_inode_id": @"9",
    @"git_device_id": @"11",
    @"git_inode_id": @"13",
  };
  NSDictionary *input = @{
    @"schema_version": @1,
    @"origin": @"legacy_app_owned",
    @"workspace_id": workspaceId,
    @"binding_revision": @(revision),
    @"root_locator_kind": @"legacy_app_owned",
    @"legacy_project_id": projectId,
    @"project_metadata_sha256": digest,
    @"projects_root_device_id": @"42",
    @"projects_root_inode_id": @"84",
    @"repository_device_id": @"7",
    @"repository_inode_id": @"9",
    @"git_device_id": @"11",
    @"git_inode_id": @"13",
  };
  NSMutableDictionary *authority = [base mutableCopy];
  authority[@"root_fingerprint_sha256"] =
      DSHWorkspaceRootFingerprintSHA256(input, nil);
  XCTAssertNotNil(authority[@"root_fingerprint_sha256"]);
  return authority;
}

- (NSDictionary *)ownedAuthorityForWorkspace:(NSString *)workspaceId
                                      revision:(NSUInteger)revision
                                 directoryName:(NSString *)directoryName
                                      deviceId:(NSString *)deviceId
                                       inodeId:(NSString *)inodeId {
  NSData *nameData = [directoryName dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *base = @{
    @"schema_version": @1,
    @"workspace_id": workspaceId,
    @"binding_revision": @(revision),
    @"device_id": deviceId,
    @"inode_id": inodeId,
    @"directory_name_sha256": [self sha256ForData:nameData],
    @"recorded_at": DSHTimestamp,
  };
  NSString *origin = [workspaceId isEqual:DSHWorkspaceB]
      ? @"imported" : @"rish_created";
  NSDictionary *record = [self recordForWorkspaceId:workspaceId
                                             origin:origin
                                    rootLocatorKind:@"documents_owned"
                                      locationClass:@"rish_owned"
                                ownedDirectoryName:directoryName
                                   legacyProjectId:nil
                                  bindingRevision:revision];
  NSString *authoritySHA256 = [self sha256ForData:[self canonicalData:base]];
  NSDictionary *input = @{
    @"schema_version": @1,
    @"origin": record[@"origin"],
    @"workspace_id": workspaceId,
    @"binding_revision": @(revision),
    @"root_locator_kind": @"documents_owned",
    @"device_id": deviceId,
    @"inode_id": inodeId,
    @"directory_name_sha256": base[@"directory_name_sha256"],
    @"authority_sha256": authoritySHA256,
  };
  NSMutableDictionary *authority = [base mutableCopy];
  authority[@"root_fingerprint_sha256"] =
      DSHWorkspaceRootFingerprintSHA256(input, nil);
  XCTAssertNotNil(authority[@"root_fingerprint_sha256"]);
  return authority;
}

- (NSDictionary *)ownedAuthorityForWorkspace:(NSString *)workspaceId
                                      revision:(NSUInteger)revision
                                 directoryName:(NSString *)directoryName {
  NSData *nameData = [directoryName dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *base = @{
    @"schema_version": @1,
    @"workspace_id": workspaceId,
    @"binding_revision": @(revision),
    @"device_id": @"42",
    @"inode_id": @"84",
    @"directory_name_sha256": [self sha256ForData:nameData],
    @"recorded_at": DSHTimestamp,
  };
  NSString *origin = [workspaceId isEqual:DSHWorkspaceB]
      ? @"imported" : @"rish_created";
  NSDictionary *record = [self recordForWorkspaceId:workspaceId
                                             origin:origin
                                    rootLocatorKind:@"documents_owned"
                                      locationClass:@"rish_owned"
                                ownedDirectoryName:directoryName
                                   legacyProjectId:nil
                                  bindingRevision:revision];
  NSString *authoritySHA256 = [self sha256ForData:[self canonicalData:base]];
  NSDictionary *input = @{
    @"schema_version": @1,
    @"origin": record[@"origin"],
    @"workspace_id": workspaceId,
    @"binding_revision": @(revision),
    @"root_locator_kind": @"documents_owned",
    @"device_id": @"42",
    @"inode_id": @"84",
    @"directory_name_sha256": base[@"directory_name_sha256"],
    @"authority_sha256": authoritySHA256,
  };
  NSMutableDictionary *authority = [base mutableCopy];
  authority[@"root_fingerprint_sha256"] =
      DSHWorkspaceRootFingerprintSHA256(input, nil);
  XCTAssertNotNil(authority[@"root_fingerprint_sha256"]);
  return authority;
}

- (NSDictionary *)bookmarkAuthorityForWorkspace:(NSString *)workspaceId
                                         revision:(NSUInteger)revision
                                            bytes:(NSData *)bytes {
  return @{
    @"schema_version": @1,
    @"workspace_id": workspaceId,
    @"binding_revision": @(revision),
    @"bookmark_sha256": [self sha256ForData:bytes],
    @"bookmark_bytes_base64": [bytes base64EncodedStringWithOptions:0],
    @"recorded_at": DSHTimestamp,
  };
}

- (NSDictionary *)grantedAuthorityForWorkspace:(NSString *)workspaceId
                                        revision:(NSUInteger)revision
                                   bookmarkDigest:(NSString *)bookmarkDigest {
  NSDictionary *base = @{
    @"schema_version": @1,
    @"workspace_id": workspaceId,
    @"binding_revision": @(revision),
    @"volume_identifier_sha256": DSHDigestA,
    @"resource_identifier_sha256": DSHDigestB,
    @"device_id": @"7",
    @"inode_id": @"9",
    @"bookmark_sha256": bookmarkDigest,
    @"classified_at": DSHTimestamp,
  };
  NSDictionary *record = [self recordForWorkspaceId:workspaceId
                                             origin:@"granted_folder"
                                    rootLocatorKind:@"security_scoped"
                                      locationClass:@"proven_local"
                                ownedDirectoryName:nil
                                   legacyProjectId:nil
                                  bindingRevision:revision];
  NSString *authoritySHA256 = [self sha256ForData:[self canonicalData:base]];
  NSDictionary *input = @{
    @"schema_version": @1,
    @"origin": record[@"origin"],
    @"workspace_id": workspaceId,
    @"binding_revision": @(revision),
    @"root_locator_kind": @"security_scoped",
    @"volume_identifier_sha256": base[@"volume_identifier_sha256"],
    @"resource_identifier_sha256": base[@"resource_identifier_sha256"],
    @"device_id": base[@"device_id"],
    @"inode_id": base[@"inode_id"],
    @"bookmark_sha256": bookmarkDigest,
    @"authority_sha256": authoritySHA256,
  };
  NSMutableDictionary *authority = [base mutableCopy];
  authority[@"root_fingerprint_sha256"] =
      DSHWorkspaceRootFingerprintSHA256(input, nil);
  XCTAssertNotNil(authority[@"root_fingerprint_sha256"]);
  return authority;
}

- (void)writeRegistryRecords:(NSArray<NSDictionary *> *)records
                   generation:(NSUInteger)generation
                         root:(NSURL *)root {
  [self secureWriteObject:@{
    @"schema_version": @1,
    @"generation": @(generation),
    @"records": records,
  } toURL:[self registryURLForRoot:root]];
}

- (NSDictionary *)bootstrapWithAccess:(DSHLocalWorkspaceAccess *)access
                           operationId:(NSString *)operationId
                                 error:(NSError **)error {
  return [access bootstrapLegacyProjectId:DSHProjectA
                                operationId:operationId
                                      error:error];
}

- (NSDictionary *)resolve:(DSHLocalWorkspaceAccess *)access
                  revision:(nullable NSNumber *)revision
               capabilities:(NSArray<NSString *> *)capabilities
                      error:(NSError **)error {
  return [access resolveWorkspaceId:DSHWorkspaceA
             expectedBindingRevision:revision
                requiredCapabilities:capabilities
                               error:error];
}

- (NSString *)JSONText:(id)object {
  if (object == nil) return @"";
  if ([object isKindOfClass:NSError.class]) {
    NSError *error = object;
    object = @{ @"domain": error.domain,
                @"code": @(error.code),
                @"description": error.localizedDescription,
                @"user_info": error.userInfo ?: @{} };
  }
  NSData *data = [NSJSONSerialization dataWithJSONObject:object
                                                  options:NSJSONWritingSortedKeys
                                                    error:nil];
  return data == nil ? [object description]
                     : [[NSString alloc] initWithData:data
                                              encoding:NSUTF8StringEncoding];
}

- (void)assertDictionary:(NSDictionary *)dictionary
             hasExactKeys:(NSArray<NSString *> *)keys {
  XCTAssertEqualObjects([NSSet setWithArray:dictionary.allKeys],
                        [NSSet setWithArray:keys]);
  XCTAssertEqual(dictionary.count, keys.count);
}

- (void)testPrivateLayoutUsesBoundedProtectedBackupExcludedFiles {
  NSError *error = nil;
  XCTAssertTrue([[self access] ensurePrivateLayoutWithError:&error]);
  XCTAssertNil(error);

  for (NSString *name in @[@"local-workspaces", @"workspace-bindings"]) {
    NSURL *directory = [self.rootURL URLByAppendingPathComponent:name
                                                      isDirectory:YES];
    NSDictionary *attributes = [NSFileManager.defaultManager
        attributesOfItemAtPath:directory.path error:&error];
    XCTAssertEqual([attributes[NSFilePosixPermissions] unsignedShortValue] & 0777,
                   0700);
    NSNumber *excluded = nil;
    XCTAssertTrue([directory getResourceValue:&excluded
                                       forKey:NSURLIsExcludedFromBackupKey
                                        error:&error]);
    XCTAssertTrue(excluded.boolValue);
  }

  NSURL *authorityLock = [[self.rootURL
      URLByAppendingPathComponent:@"local-workspaces" isDirectory:YES]
      URLByAppendingPathComponent:@"authority.lock"];
  NSURL *layoutManifest = [[self.rootURL
      URLByAppendingPathComponent:@"local-workspaces" isDirectory:YES]
      URLByAppendingPathComponent:@"layout-v1.json"];
  for (NSURL *file in @[[self registryURLForRoot:self.rootURL],
                        [self receiptsURLForRoot:self.rootURL], authorityLock,
                        layoutManifest]) {
    NSDictionary *attributes = [NSFileManager.defaultManager
        attributesOfItemAtPath:file.path error:&error];
    XCTAssertEqual([attributes[NSFilePosixPermissions] unsignedShortValue] & 0777,
                   0600);
    // The workspace store is read by AgentRootResolver while the phone is
    // locked after first unlock, so it must carry the same class as
    // sessions.json, agent-runtime/ and the workspace files it indexes.
    if (DSHTestHostIsSimulator()) {
      // CoreSimulator may not report a protection class; enforce it only
      // when the filesystem exposes one.
      if (attributes[NSFileProtectionKey] != nil) {
        XCTAssertEqualObjects(attributes[NSFileProtectionKey],
            NSFileProtectionCompleteUntilFirstUserAuthentication);
      }
    } else {
      XCTAssertEqualObjects(attributes[NSFileProtectionKey],
          NSFileProtectionCompleteUntilFirstUserAuthentication);
      XCTAssertNotEqualObjects(attributes[NSFileProtectionKey],
                               NSFileProtectionComplete);
    }
    NSNumber *excluded = nil;
    XCTAssertTrue([file getResourceValue:&excluded
                                  forKey:NSURLIsExcludedFromBackupKey
                                   error:&error]);
    XCTAssertTrue(excluded.boolValue);
  }
}

// Regression: earlier builds wrote local-workspaces/ with
// NSFileProtectionComplete, which the kernel refuses while the phone is
// locked (evidence: locked-phone copy of receipts-v1.json failed with EPERM
// while sessions.json and agent-runtime/ copied). The store must migrate
// such items to CompleteUntilFirstUserAuthentication in place on the next
// unlocked access instead of rejecting them or leaving them locked-out.
- (void)testLegacyCompleteProtectionMigratesToUntilFirstUserAuthentication {
  if (DSHTestHostIsSimulator()) {
    XCTSkip(@"CoreSimulator does not report NSFileProtectionKey through "
        @"NSFileManager, so a legacy Complete class cannot be observed or "
        @"migrated there; the migration is verified on a physical device.");
  }
  NSError *error = nil;
  XCTAssertTrue([[self access] ensurePrivateLayoutWithError:&error], @"%@", error);
  NSURL *store = [self.rootURL URLByAppendingPathComponent:@"local-workspaces"
                                                isDirectory:YES];
  NSURL *authorityLock = [store URLByAppendingPathComponent:@"authority.lock"];
  NSURL *layoutManifest = [store URLByAppendingPathComponent:@"layout-v1.json"];
  NSArray<NSURL *> *items = @[
    store, [self registryURLForRoot:self.rootURL],
    [self receiptsURLForRoot:self.rootURL], authorityLock, layoutManifest,
  ];
  for (NSURL *item in items) {
    XCTAssertTrue([NSFileManager.defaultManager
        setAttributes:@{NSFileProtectionKey : NSFileProtectionComplete}
         ofItemAtPath:item.path error:&error], @"%@ %@", item, error);
    XCTAssertEqualObjects([NSFileManager.defaultManager
        attributesOfItemAtPath:item.path error:nil][NSFileProtectionKey],
        NSFileProtectionComplete);
  }

  // A fresh store instance models the next launch after the update. Listing
  // metadata reads the registry, receipts and layout through the protected
  // reader and reacquires the authority lock.
  DSHLocalWorkspaceAccess *restarted = [self accessWithRoot:self.rootURL fault:nil];
  XCTAssertNotNil([restarted listWorkspaceMetadataWithError:&error], @"%@", error);
  XCTAssertNil(error);
  for (NSURL *item in items) {
    NSDictionary *attributes = [NSFileManager.defaultManager
        attributesOfItemAtPath:item.path error:&error];
    XCTAssertEqualObjects(attributes[NSFileProtectionKey],
        NSFileProtectionCompleteUntilFirstUserAuthentication, @"%@", item);
    NSNumber *excluded = nil;
    XCTAssertTrue([item getResourceValue:&excluded
                                  forKey:NSURLIsExcludedFromBackupKey
                                   error:&error]);
    XCTAssertTrue(excluded.boolValue);
  }
}

- (void)testInitializedStoreNeverRecreatesMissingRegistryOrReceipts {
  for (NSString *missing in @[@"registry", @"receipts"]) {
    NSURL *root = [self.rootURL URLByAppendingPathComponent:missing
                                                isDirectory:YES];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:root
                                         withIntermediateDirectories:YES
                                                          attributes:nil
                                                               error:nil]);
    DSHLocalWorkspaceAccess *access = [self accessWithRoot:root fault:nil];
    XCTAssertNotNil([access bootstrapLegacyProjectId:DSHProjectA
                                           operationId:DSHOperationA error:nil]);
    NSURL *target = [missing isEqual:@"registry"]
        ? [self registryURLForRoot:root] : [self receiptsURLForRoot:root];
    XCTAssertTrue([NSFileManager.defaultManager removeItemAtURL:target error:nil]);

    DSHLocalWorkspaceAccess *restarted = [self accessWithRoot:root fault:nil];
    NSError *error = nil;
    XCTAssertNil([restarted listWorkspaceMetadataWithError:&error]);
    XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_PERSISTENCE");
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:target.path]);
  }
}

- (void)testPrivateFilesRejectPermissionDriftFromExact0600 {
  DSHLocalWorkspaceAccess *access = [self access];
  XCTAssertTrue([access ensurePrivateLayoutWithError:nil]);
  XCTAssertEqual(chmod([self registryURLForRoot:self.rootURL]
                           .fileSystemRepresentation, 0400), 0);
  NSError *error = nil;
  XCTAssertNil([access listWorkspaceMetadataWithError:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_PERSISTENCE");
}

- (void)testRegistryRejectsNonExactOversizedUnsortedAndInvalidRecords {
  DSHLocalWorkspaceAccess *access = [self access];
  XCTAssertTrue([access ensurePrivateLayoutWithError:nil]);
  NSDictionary *recordA = [self legacyRecordWithRevision:1];
  [self secureWriteObject:[self legacyAuthorityWithRevision:1
                                               authorityDigest:DSHDigestA]
                    toURL:[self authorityURLForRoot:self.rootURL
                                               kind:@"legacy"
                                        workspaceId:DSHWorkspaceA
                                           revision:1]];

  NSMutableDictionary *extraEnvelope = [@{
    @"schema_version": @1, @"generation": @1,
    @"records": @[recordA], @"extra": @1,
  } mutableCopy];
  [self secureWriteObject:extraEnvelope
                    toURL:[self registryURLForRoot:self.rootURL]];
  XCTAssertNil([access listWorkspaceMetadataWithError:nil]);

  NSString *recordText = [[NSString alloc]
      initWithData:[self canonicalData:recordA]
           encoding:NSUTF8StringEncoding];
  NSString *duplicateKeyJSON = [NSString stringWithFormat:
      @"{\"schema_version\":1,\"generation\":0,\"generation\":1,"
       "\"records\":[%@]}", recordText];
  [self secureWriteData:[duplicateKeyJSON dataUsingEncoding:NSUTF8StringEncoding]
                   toURL:[self registryURLForRoot:self.rootURL]];
  XCTAssertNil([access listWorkspaceMetadataWithError:nil]);

  NSString *negativeZeroJSON = [NSString stringWithFormat:
      @"{\"schema_version\":1,\"generation\":-0e0,\"records\":[%@]}",
      recordText];
  [self secureWriteData:[negativeZeroJSON dataUsingEncoding:NSUTF8StringEncoding]
                   toURL:[self registryURLForRoot:self.rootURL]];
  XCTAssertNil([access listWorkspaceMetadataWithError:nil]);

  NSString *escapedDuplicateJSON = [NSString stringWithFormat:
      @"{\"schema_version\":1,\"generation\":0,"
       "\"gen\\u0065ration\":1,\"records\":[%@]}", recordText];
  [self secureWriteData:[escapedDuplicateJSON
      dataUsingEncoding:NSUTF8StringEncoding]
                   toURL:[self registryURLForRoot:self.rootURL]];
  XCTAssertNil([access listWorkspaceMetadataWithError:nil]);

  NSMutableString *tooDeep = [NSMutableString stringWithString:
      @"{\"schema_version\":1,\"generation\":0,\"records\":" ];
  for (NSUInteger index = 0; index < 65; index++) [tooDeep appendString:@"["];
  [tooDeep appendString:@"0"];
  for (NSUInteger index = 0; index < 65; index++) [tooDeep appendString:@"]"];
  [tooDeep appendString:@"}"];
  [self secureWriteData:[tooDeep dataUsingEncoding:NSUTF8StringEncoding]
                   toURL:[self registryURLForRoot:self.rootURL]];
  XCTAssertNil([access listWorkspaceMetadataWithError:nil]);

  NSMutableDictionary *invalidRecord = [recordA mutableCopy];
  invalidRecord[@"workspace_id"] = DSHProjectA.uppercaseString;
  [self writeRegistryRecords:@[invalidRecord] generation:1 root:self.rootURL];
  XCTAssertNil([access listWorkspaceMetadataWithError:nil]);

  NSDictionary *recordB = [self recordForWorkspaceId:DSHWorkspaceB
                                               origin:@"legacy_app_owned"
                                      rootLocatorKind:@"legacy_app_owned"
                                        locationClass:@"rish_owned"
                                  ownedDirectoryName:nil
                                     legacyProjectId:DSHProjectA
                                     bindingRevision:1];
  [self writeRegistryRecords:@[recordB, recordA]
                   generation:1 root:self.rootURL];
  XCTAssertNil([access listWorkspaceMetadataWithError:nil]);

  NSMutableArray *tooMany = [NSMutableArray arrayWithCapacity:1025];
  for (NSUInteger index = 0; index < 1025; index++) {
    NSString *workspace = [NSString stringWithFormat:@"%08lx-0000-4000-8000-%012lx",
                           (unsigned long)index, (unsigned long)index];
    [tooMany addObject:[self recordForWorkspaceId:workspace
                                           origin:@"legacy_app_owned"
                                  rootLocatorKind:@"legacy_app_owned"
                                    locationClass:@"rish_owned"
                              ownedDirectoryName:nil
                                 legacyProjectId:DSHProjectA
                                 bindingRevision:1]];
  }
  [self writeRegistryRecords:tooMany generation:1 root:self.rootURL];
  XCTAssertNil([access listWorkspaceMetadataWithError:nil]);

  NSMutableData *oversized = [NSMutableData dataWithLength:(1024 * 1024) + 1];
  [oversized replaceBytesInRange:NSMakeRange(0, 1) withBytes:"{"];
  XCTAssertTrue([oversized writeToURL:[self registryURLForRoot:self.rootURL]
                              options:NSDataWritingAtomic error:nil]);
  XCTAssertNil([access listWorkspaceMetadataWithError:nil]);
}

- (void)testIndependentAuthoritySchemasAreExactAndCorruptionFailsClosed {
  DSHLocalWorkspaceAccess *access = [self access];
  XCTAssertTrue([access ensurePrivateLayoutWithError:nil]);
  NSData *bookmark = [@"PRIVATE_BOOKMARK_BYTES" dataUsingEncoding:NSUTF8StringEncoding];
  NSString *bookmarkDigest = [self sha256ForData:bookmark];
  NSArray *records = @[
    [self recordForWorkspaceId:DSHWorkspaceA origin:@"rish_created"
               rootLocatorKind:@"documents_owned" locationClass:@"rish_owned"
         ownedDirectoryName:@"Owned A" legacyProjectId:nil bindingRevision:1],
    [self recordForWorkspaceId:DSHWorkspaceB origin:@"imported"
               rootLocatorKind:@"documents_owned" locationClass:@"rish_owned"
         ownedDirectoryName:@"Imported B" legacyProjectId:nil bindingRevision:1],
    [self recordForWorkspaceId:DSHWorkspaceC origin:@"granted_folder"
               rootLocatorKind:@"security_scoped" locationClass:@"proven_local"
         ownedDirectoryName:nil legacyProjectId:nil bindingRevision:1],
    [self recordForWorkspaceId:DSHWorkspaceD origin:@"legacy_app_owned"
               rootLocatorKind:@"legacy_app_owned" locationClass:@"rish_owned"
         ownedDirectoryName:nil legacyProjectId:DSHProjectA bindingRevision:1],
  ];
  [self writeRegistryRecords:records generation:1 root:self.rootURL];
  [self secureWriteObject:[self ownedAuthorityForWorkspace:DSHWorkspaceA
                                                   revision:1
                                              directoryName:@"Owned A"]
                    toURL:[self authorityURLForRoot:self.rootURL kind:@"owned"
                                        workspaceId:DSHWorkspaceA revision:1]];
  [self secureWriteObject:[self ownedAuthorityForWorkspace:DSHWorkspaceB
                                                   revision:1
                                              directoryName:@"Imported B"]
                    toURL:[self authorityURLForRoot:self.rootURL kind:@"owned"
                                        workspaceId:DSHWorkspaceB revision:1]];
  [self secureWriteObject:[self bookmarkAuthorityForWorkspace:DSHWorkspaceC
                                                      revision:1 bytes:bookmark]
                    toURL:[self authorityURLForRoot:self.rootURL kind:@"bookmark"
                                        workspaceId:DSHWorkspaceC revision:1]];
  [self secureWriteObject:[self grantedAuthorityForWorkspace:DSHWorkspaceC
                                                     revision:1
                                                bookmarkDigest:bookmarkDigest]
                    toURL:[self authorityURLForRoot:self.rootURL kind:@"granted"
                                        workspaceId:DSHWorkspaceC revision:1]];
  NSDictionary *legacy = [self legacyAuthorityForWorkspace:DSHWorkspaceD
                                                    projectId:DSHProjectA
                                                 displayName:@"Workspace 4444"
                                                    revision:1
                                             authorityDigest:DSHDigestA];
  [self secureWriteObject:legacy
                    toURL:[self authorityURLForRoot:self.rootURL kind:@"legacy"
                                        workspaceId:DSHWorkspaceD revision:1]];
  NSArray *listed = [access listWorkspaceMetadataWithError:nil];
  XCTAssertEqual(listed.count, 4u);

  NSMutableDictionary *corrupt = [[self grantedAuthorityForWorkspace:DSHWorkspaceC
                                                               revision:1
                                                          bookmarkDigest:bookmarkDigest]
      mutableCopy];
  corrupt[@"native_path"] = @"/private/secret";
  [self secureWriteObject:corrupt
                    toURL:[self authorityURLForRoot:self.rootURL kind:@"granted"
                                        workspaceId:DSHWorkspaceC revision:1]];
  NSError *error = nil;
  XCTAssertNil([access listWorkspaceMetadataWithError:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_PERSISTENCE");
  XCTAssertFalse([[self JSONText:error] containsString:@"/private/secret"]);

  [self secureWriteObject:[self grantedAuthorityForWorkspace:DSHWorkspaceC
                                                     revision:1
                                                bookmarkDigest:bookmarkDigest]
                    toURL:[self authorityURLForRoot:self.rootURL kind:@"granted"
                                        workspaceId:DSHWorkspaceC revision:1]];
  NSMutableDictionary *ownedCorrupt =
      [[self ownedAuthorityForWorkspace:DSHWorkspaceA
                               revision:1 directoryName:@"Owned A"] mutableCopy];
  ownedCorrupt[@"directory_name_sha256"] = DSHDigestA;
  [self secureWriteObject:ownedCorrupt
                    toURL:[self authorityURLForRoot:self.rootURL kind:@"owned"
                                        workspaceId:DSHWorkspaceA revision:1]];
  XCTAssertNil([access listWorkspaceMetadataWithError:nil]);
  [self secureWriteObject:[self ownedAuthorityForWorkspace:DSHWorkspaceA
                                                   revision:1
                                              directoryName:@"Owned A"]
                    toURL:[self authorityURLForRoot:self.rootURL kind:@"owned"
                                        workspaceId:DSHWorkspaceA revision:1]];

  NSMutableDictionary *bookmarkCorrupt =
      [[self bookmarkAuthorityForWorkspace:DSHWorkspaceC
                                  revision:1 bytes:bookmark] mutableCopy];
  bookmarkCorrupt[@"bookmark_sha256"] = DSHDigestA;
  [self secureWriteObject:bookmarkCorrupt
                    toURL:[self authorityURLForRoot:self.rootURL kind:@"bookmark"
                                        workspaceId:DSHWorkspaceC revision:1]];
  XCTAssertNil([access listWorkspaceMetadataWithError:nil]);

  NSData *oversizedBookmark = [NSMutableData
      dataWithLength:(256 * 1024) + 1];
  [self secureWriteObject:[self bookmarkAuthorityForWorkspace:DSHWorkspaceC
                                                      revision:1
                                                         bytes:oversizedBookmark]
                    toURL:[self authorityURLForRoot:self.rootURL kind:@"bookmark"
                                        workspaceId:DSHWorkspaceC revision:1]];
  XCTAssertNil([access listWorkspaceMetadataWithError:nil]);
  [self secureWriteObject:[self bookmarkAuthorityForWorkspace:DSHWorkspaceC
                                                      revision:1 bytes:bookmark]
                    toURL:[self authorityURLForRoot:self.rootURL kind:@"bookmark"
                                        workspaceId:DSHWorkspaceC revision:1]];

  NSMutableDictionary *legacyCorrupt = [legacy mutableCopy];
  legacyCorrupt[@"root_identity_sha256"] = @"not-a-digest";
  [self secureWriteObject:legacyCorrupt
                    toURL:[self authorityURLForRoot:self.rootURL kind:@"legacy"
                                        workspaceId:DSHWorkspaceD revision:1]];
  XCTAssertNil([access listWorkspaceMetadataWithError:nil]);
}

- (void)testMetadataProbeHasZeroOperationalCapabilitiesAndDoesNotResolveLegacyRoot {
  DSHLocalWorkspaceAccess *access = [self access];
  NSError *error = nil;
  NSDictionary *workspace = [self bootstrapWithAccess:access
                                           operationId:DSHOperationA error:&error];
  XCTAssertNotNil(workspace);
  self.resolverCalls = 0;
  NSDictionary *probe = [self resolve:access revision:nil
                            capabilities:@[@"read"] error:&error];
  XCTAssertNotNil(probe);
  XCTAssertEqual(self.resolverCalls, 1u);
  NSDictionary *caps = probe[@"workspace"][@"capabilities"];
  XCTAssertEqualObjects(caps[@"read"], @NO);
  XCTAssertEqualObjects(caps[@"write"], @NO);
  XCTAssertEqualObjects(caps[@"git"], @NO);
  XCTAssertEqualObjects(caps[@"project_context"], @NO);

  self.resolverIdentity = DSHDigestB;
  NSDictionary *unavailable = [self resolve:access revision:nil
                                  capabilities:@[@"read"] error:&error];
  XCTAssertEqualObjects(unavailable[@"workspace"][@"status"], @"unavailable");
  XCTAssertEqualObjects(unavailable[@"workspace"][@"capabilities"][@"read"],
                        @NO);
}

- (void)testRegistryCapacityRejectsThe1025thMutationBeforePublication {
  DSHLocalWorkspaceAccess *access = [self access];
  XCTAssertTrue([access ensurePrivateLayoutWithError:nil]);
  NSMutableArray *records = [NSMutableArray arrayWithCapacity:1024];
  for (NSUInteger index = 0; index < 1024; index++) {
    NSString *workspace = [NSString stringWithFormat:
        @"%08lx-0000-4000-8000-%012lx", (unsigned long)index,
        (unsigned long)index];
    NSString *directory = [NSString stringWithFormat:@"Owned %04lu",
                           (unsigned long)index];
    [records addObject:[self recordForWorkspaceId:workspace
                                           origin:@"rish_created"
                                  rootLocatorKind:@"documents_owned"
                                    locationClass:@"rish_owned"
                              ownedDirectoryName:directory
                                 legacyProjectId:nil
                                 bindingRevision:1]];
  }
  [self writeRegistryRecords:records generation:7 root:self.rootURL];
  NSData *before = [NSData dataWithContentsOfURL:
      [self registryURLForRoot:self.rootURL]];
  NSError *error = nil;
  XCTAssertNil([self bootstrapWithAccess:access operationId:DSHOperationA
                                   error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_BUSY");
  XCTAssertEqualObjects([NSData dataWithContentsOfURL:
      [self registryURLForRoot:self.rootURL]], before);
  XCTAssertFalse([NSFileManager.defaultManager
      fileExistsAtPath:[self journalURLForRoot:self.rootURL].path]);
  XCTAssertFalse([NSFileManager.defaultManager
      fileExistsAtPath:[self authorityURLForRoot:self.rootURL kind:@"legacy"
                                    workspaceId:DSHWorkspaceA revision:1].path]);
}

- (void)testRegistryGenerationOverflowFailsBeforeMutationEvidence {
  DSHLocalWorkspaceAccess *access = [self access];
  XCTAssertTrue([access ensurePrivateLayoutWithError:nil]);
  [self writeRegistryRecords:@[]
                   generation:(NSUInteger)9007199254740991ULL
                         root:self.rootURL];
  NSData *before = [NSData dataWithContentsOfURL:
      [self registryURLForRoot:self.rootURL]];
  NSError *error = nil;
  XCTAssertNil([self bootstrapWithAccess:access operationId:DSHOperationA
                                   error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_PERSISTENCE");
  XCTAssertEqualObjects([NSData dataWithContentsOfURL:
      [self registryURLForRoot:self.rootURL]], before);
  XCTAssertFalse([NSFileManager.defaultManager
      fileExistsAtPath:[self journalURLForRoot:self.rootURL].path]);
  XCTAssertFalse([NSFileManager.defaultManager
      fileExistsAtPath:[self authorityURLForRoot:self.rootURL kind:@"legacy"
                                    workspaceId:DSHWorkspaceA revision:1].path]);
}

- (void)testMutationFailsClosedOnUnrelatedPublishedAuthorityCorruption {
  DSHLocalWorkspaceAccess *access = [self access];
  XCTAssertTrue([access ensurePrivateLayoutWithError:nil]);
  NSDictionary *owned = [self recordForWorkspaceId:DSHWorkspaceB
                                             origin:@"rish_created"
                                    rootLocatorKind:@"documents_owned"
                                      locationClass:@"rish_owned"
                                ownedDirectoryName:@"Missing authority"
                                   legacyProjectId:nil bindingRevision:1];
  [self writeRegistryRecords:@[owned] generation:1 root:self.rootURL];
  NSData *before = [NSData dataWithContentsOfURL:
      [self registryURLForRoot:self.rootURL]];
  NSError *error = nil;
  XCTAssertNil([self bootstrapWithAccess:access operationId:DSHOperationA
                                   error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_PERSISTENCE");
  XCTAssertEqualObjects([NSData dataWithContentsOfURL:
      [self registryURLForRoot:self.rootURL]], before);
  XCTAssertFalse([NSFileManager.defaultManager
      fileExistsAtPath:[self journalURLForRoot:self.rootURL].path]);
  XCTAssertFalse([NSFileManager.defaultManager
      fileExistsAtPath:[self authorityURLForRoot:self.rootURL kind:@"legacy"
                                    workspaceId:DSHWorkspaceA revision:1].path]);
}

- (void)testOperationalResolveRequiresExactRevisionAndFailsBeforeAuthorityOpen {
  DSHLocalWorkspaceAccess *access = [self access];
  XCTAssertNotNil([self bootstrapWithAccess:access
                                operationId:DSHOperationA error:nil]);
  NSURL *authority = [self authorityURLForRoot:self.rootURL kind:@"legacy"
                                   workspaceId:DSHWorkspaceA revision:1];
  NSDictionary *originalAuthority = [NSJSONSerialization
      JSONObjectWithData:[NSData dataWithContentsOfURL:authority]
                 options:0 error:nil];
  [self secureWriteObject:@{@"corrupt": @YES} toURL:authority];

  NSError *error = nil;
  XCTAssertNil([self resolve:access revision:@2 capabilities:@[@"read"]
                       error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"],
                        @"E_WORKSPACE_REVISION_STALE");
  XCTAssertEqual(self.resolverCalls, 1u); // bootstrap only

  [self secureWriteObject:originalAuthority toURL:authority];
  NSDictionary *resolved = [self resolve:access revision:@1
                               capabilities:@[@"read", @"git"] error:&error];
  XCTAssertEqualObjects(resolved[@"disposition"], @"direct");
  XCTAssertEqualObjects(resolved[@"workspace"][@"capabilities"][@"read"], @YES);
  XCTAssertEqualObjects(resolved[@"workspace"][@"capabilities"][@"git"], @YES);
}

- (void)testRegistryCASRejectsOldGenerationAndDigestWithoutPublication {
  DSHLocalWorkspaceFaultHook hook = ^BOOL(NSString *stage) {
    return [stage isEqual:@"after_authority_ready"];
  };
  DSHLocalWorkspaceAccess *access = [self accessWithRoot:self.rootURL fault:hook];
  NSError *error = nil;
  XCTAssertNil([self bootstrapWithAccess:access operationId:DSHOperationA
                                   error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_PERSISTENCE");
  [self writeRegistryRecords:@[] generation:1 root:self.rootURL];

  DSHLocalWorkspaceAccess *restarted = [self accessWithRoot:self.rootURL fault:nil];
  NSArray *listed = [restarted listWorkspaceMetadataWithError:&error];
  XCTAssertNotNil(listed);
  XCTAssertEqual(listed.count, 0u);
  NSDictionary *query = [restarted queryOperationId:DSHOperationA error:&error];
  XCTAssertEqualObjects(query[@"status"], @"not_started");
}

- (void)testConflictRecoveryClearsJournalWhenUnreferencedAuthorityWasAlreadyRemoved {
  DSHLocalWorkspaceAccess *access = [self accessWithRoot:self.rootURL
      fault:^BOOL(NSString *stage) {
        return [stage isEqual:@"after_authority_ready"];
      }];
  XCTAssertNil([self bootstrapWithAccess:access operationId:DSHOperationA
                                   error:nil]);
  [self writeRegistryRecords:@[] generation:1 root:self.rootURL];
  NSURL *authority = [self authorityURLForRoot:self.rootURL kind:@"legacy"
                                   workspaceId:DSHWorkspaceA revision:1];
  XCTAssertTrue([NSFileManager.defaultManager removeItemAtURL:authority error:nil]);

  DSHLocalWorkspaceAccess *restarted = [self access];
  NSError *error = nil;
  NSArray *listed = [restarted listWorkspaceMetadataWithError:&error];
  XCTAssertNotNil(listed);
  XCTAssertEqual(listed.count, 0u);
  XCTAssertFalse([NSFileManager.defaultManager
      fileExistsAtPath:[self journalURLForRoot:self.rootURL].path]);
}

- (void)testThreePhaseRecoveryConvergesWithoutDuplicatePublication {
  for (NSString *stage in @[@"after_journal_prepared",
                            @"after_authority_write_before_journal",
                            @"after_authority_ready",
                            @"after_registry_publication_before_journal",
                            @"after_registry_committed",
                            @"after_receipt_written_before_journal_clear"]) {
    NSURL *root = [self.rootURL URLByAppendingPathComponent:stage
                                                isDirectory:YES];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:root
                                         withIntermediateDirectories:YES
                                                          attributes:nil
                                                               error:nil]);
    DSHLocalWorkspaceAccess *access = [self accessWithRoot:root
        fault:^BOOL(NSString *candidate) {
          return [candidate isEqual:stage];
        }];
    NSError *error = nil;
    XCTAssertNil([self bootstrapWithAccess:access operationId:DSHOperationA
                                     error:&error]);
    XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_PERSISTENCE");

    NSData *registryBytes = [NSData dataWithContentsOfURL:[self registryURLForRoot:root]];
    NSString *registryText = [[NSString alloc] initWithData:registryBytes
                                                   encoding:NSUTF8StringEncoding];
    BOOL registryCommitted =
        [stage isEqual:@"after_registry_publication_before_journal"] ||
        [stage isEqual:@"after_registry_committed"] ||
        [stage isEqual:@"after_receipt_written_before_journal_clear"];
    XCTAssertEqual([registryText containsString:DSHWorkspaceA], registryCommitted);

    DSHLocalWorkspaceAccess *restarted = [self accessWithRoot:root fault:nil];
    NSArray *listed = [restarted listWorkspaceMetadataWithError:&error];
    XCTAssertNotNil(listed);
    if ([stage isEqual:@"after_journal_prepared"] ||
        [stage isEqual:@"after_authority_write_before_journal"]) {
      XCTAssertEqual(listed.count, 0u);
      XCTAssertNotNil([self bootstrapWithAccess:restarted
                                    operationId:DSHOperationA error:&error]);
    } else {
      XCTAssertEqual(listed.count, 1u);
    }
    XCTAssertEqual([restarted listWorkspaceMetadataWithError:&error].count, 1u);
    XCTAssertEqualObjects([restarted queryOperationId:DSHOperationA
                                                error:&error][@"status"],
                          @"committed");
  }
}

- (void)testUnsupportedFutureJournalFailsClosedWithoutDeletingEvidence {
  DSHLocalWorkspaceAccess *access = [self access];
  XCTAssertTrue([access ensurePrivateLayoutWithError:nil]);
  NSData *registryData =
      [NSData dataWithContentsOfURL:[self registryURLForRoot:self.rootURL]];
  NSDictionary *futureJournal = @{
    @"schema_version": @1,
    @"operation_id": DSHOperationA,
    @"workspace_id": DSHWorkspaceA,
    @"operation": @"import",
    @"phase": @"prepared",
    @"binding_revision": @1,
    @"previous_registry_generation": @0,
    @"previous_registry_sha256": [self sha256ForData:registryData],
    @"authority_sha256": NSNull.null,
    @"record_sha256": NSNull.null,
    @"staging_name": @"staging-a",
    @"destination_name": @"destination-a",
    @"display_name": @"Import A",
    @"request_sha256": DSHDigestA,
    @"staging_device_id": NSNull.null,
    @"staging_inode_id": NSNull.null,
    @"staging_uid": NSNull.null,
    @"staging_gid": NSNull.null,
    @"destination_device_id": NSNull.null,
    @"destination_inode_id": NSNull.null,
    @"destination_uid": NSNull.null,
    @"destination_gid": NSNull.null,
    @"legacy_project_id": NSNull.null,
    @"clearance_receipt_id": NSNull.null,
    @"confirmation_id": NSNull.null,
    @"created_at": DSHTimestamp,
    @"last_opened_at": DSHTimestamp,
    @"updated_at": DSHTimestamp,
  };
  [self secureWriteObject:futureJournal
                    toURL:[self journalURLForRoot:self.rootURL]];

  DSHLocalWorkspaceAccess *restarted = [self access];
  NSError *error = nil;
  XCTAssertNil([restarted listWorkspaceMetadataWithError:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_PERSISTENCE");
  XCTAssertTrue([NSFileManager.defaultManager
      fileExistsAtPath:[self journalURLForRoot:self.rootURL].path]);
}

- (void)testPreparedRecoveryNeverDeletesAuthorityReferencedByRegistry {
  DSHLocalWorkspaceAccess *access = [self access];
  XCTAssertNotNil([self bootstrapWithAccess:access
                                operationId:DSHOperationA error:nil]);
  NSData *registryData =
      [NSData dataWithContentsOfURL:[self registryURLForRoot:self.rootURL]];
  NSDictionary *prepared = @{
    @"schema_version": @1,
    @"operation_id": DSHOperationB,
    @"workspace_id": DSHWorkspaceA,
    @"operation": @"bootstrap_legacy",
    @"phase": @"prepared",
    @"binding_revision": @1,
    @"previous_registry_generation": @1,
    @"previous_registry_sha256": [self sha256ForData:registryData],
    @"authority_sha256": NSNull.null,
    @"record_sha256": NSNull.null,
    @"staging_name": NSNull.null,
    @"destination_name": NSNull.null,
    @"display_name": @"Legacy Repo",
    @"request_sha256": [self bootstrapRequestDigestForProjectId:DSHProjectA],
    @"staging_device_id": NSNull.null,
    @"staging_inode_id": NSNull.null,
    @"staging_uid": NSNull.null,
    @"staging_gid": NSNull.null,
    @"destination_device_id": NSNull.null,
    @"destination_inode_id": NSNull.null,
    @"destination_uid": NSNull.null,
    @"destination_gid": NSNull.null,
    @"legacy_project_id": DSHProjectA,
    @"clearance_receipt_id": NSNull.null,
    @"confirmation_id": NSNull.null,
    @"created_at": DSHTimestamp,
    @"last_opened_at": DSHTimestamp,
    @"updated_at": DSHTimestamp,
  };
  [self secureWriteObject:prepared
                    toURL:[self journalURLForRoot:self.rootURL]];
  NSURL *authority = [self authorityURLForRoot:self.rootURL kind:@"legacy"
                                   workspaceId:DSHWorkspaceA revision:1];

  DSHLocalWorkspaceAccess *restarted = [self access];
  NSError *error = nil;
  XCTAssertNil([restarted listWorkspaceMetadataWithError:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_PERSISTENCE");
  XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:authority.path]);
  XCTAssertTrue([NSFileManager.defaultManager
      fileExistsAtPath:[self journalURLForRoot:self.rootURL].path]);
}

- (void)testAuthorityReadyRecordIsInvisibleUntilRegistryPublication {
  DSHLocalWorkspaceAccess *access = [self accessWithRoot:self.rootURL
      fault:^BOOL(NSString *stage) {
        return [stage isEqual:@"after_authority_ready"];
      }];
  XCTAssertNil([self bootstrapWithAccess:access operationId:DSHOperationA
                                   error:nil]);
  NSArray *listed = [access listWorkspaceMetadataWithError:nil];
  XCTAssertEqual(listed.count, 0u);
  XCTAssertTrue([NSFileManager.defaultManager
      fileExistsAtPath:[self authorityURLForRoot:self.rootURL kind:@"legacy"
                                    workspaceId:DSHWorkspaceA revision:1].path]);
}

- (void)testOperationIdRetryReturnsSameReceiptAcrossRestart {
  DSHLocalWorkspaceAccess *access = [self access];
  NSDictionary *first = [self bootstrapWithAccess:access
                                       operationId:DSHOperationA error:nil];
  XCTAssertNotNil(first);
  NSDictionary *second = [self bootstrapWithAccess:access
                                        operationId:DSHOperationA error:nil];
  XCTAssertEqualObjects(first, second);
  XCTAssertEqual([access listWorkspaceMetadataWithError:nil].count, 1u);

  DSHLocalWorkspaceAccess *restarted = [self access];
  NSDictionary *query = [restarted queryOperationId:DSHOperationA error:nil];
  XCTAssertEqualObjects(query[@"status"], @"committed");
  NSUInteger callsBeforeReplay = self.resolverCalls;
  NSDictionary *third = [self bootstrapWithAccess:restarted
                                       operationId:DSHOperationA error:nil];
  XCTAssertEqualObjects(first, third);
  XCTAssertEqual(self.resolverCalls, callsBeforeReplay);
  XCTAssertEqual([restarted listWorkspaceMetadataWithError:nil].count, 1u);

  NSURL *authority = [self authorityURLForRoot:self.rootURL kind:@"legacy"
                                   workspaceId:DSHWorkspaceA revision:1];
  NSDictionary *authorityObject = [NSJSONSerialization
      JSONObjectWithData:[NSData dataWithContentsOfURL:authority]
                 options:0 error:nil];
  XCTAssertTrue([NSFileManager.defaultManager removeItemAtURL:authority error:nil]);
  NSError *error = nil;
  XCTAssertNil([restarted bootstrapLegacyProjectId:DSHProjectA
                                        operationId:DSHOperationA error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_PERSISTENCE");

  [self secureWriteObject:authorityObject toURL:authority];
  self.resolverDisplayName = @"Renamed after commit";
  self.resolverIdentity = DSHDigestB;
  callsBeforeReplay = self.resolverCalls;
  NSDictionary *replayed = [restarted bootstrapLegacyProjectId:DSHProjectA
                                                     operationId:DSHOperationA
                                                           error:nil];
  XCTAssertEqualObjects(replayed, first);
  XCTAssertEqual(self.resolverCalls, callsBeforeReplay);
}

- (void)testSameInstanceRetryRecoversPostAuthorityJournalBeforeNewUUID {
  NSArray<NSString *> *stages = @[
    @"after_authority_ready",
    @"after_registry_publication_before_journal",
    @"after_registry_committed",
    @"after_receipt_written_before_journal_clear",
  ];
  for (NSString *stage in stages) {
    NSURL *root = [self.rootURL URLByAppendingPathComponent:
        [@"same-instance-" stringByAppendingString:stage] isDirectory:YES];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:root
                                         withIntermediateDirectories:YES
                                                          attributes:nil
                                                               error:nil]);
    __block NSString *nextWorkspaceId = DSHWorkspaceA;
    __block BOOL faultInjected = NO;
    DSHLocalWorkspaceAccess *access = [self accessWithRoot:root
        fault:^BOOL(NSString *candidate) {
          if (!faultInjected && [candidate isEqual:stage]) {
            faultInjected = YES;
            return YES;
          }
          return NO;
        }
        UUIDGenerator:^NSString *{
          return nextWorkspaceId;
        }];
    NSError *error = nil;
    XCTAssertNil([access bootstrapLegacyProjectId:DSHProjectA
                                        operationId:DSHOperationA error:&error]);
    XCTAssertTrue(faultInjected);
    nextWorkspaceId = DSHWorkspaceB;
    self.now = [self.now dateByAddingTimeInterval:1];
    error = nil;

    NSDictionary *retried = [access bootstrapLegacyProjectId:DSHProjectA
                                                    operationId:DSHOperationA
                                                          error:&error];
    XCTAssertNotNil(retried, @"stage %@", stage);
    XCTAssertEqualObjects(retried[@"workspace_id"], DSHWorkspaceA,
                          @"stage %@", stage);
    XCTAssertEqual([access listWorkspaceMetadataWithError:&error].count, 1u);
    XCTAssertEqualObjects([access queryOperationId:DSHOperationA
                                             error:&error][@"status"],
                          @"committed");
  }
}

- (void)testBootstrapUsesOneNativeEvidenceSnapshotAndPublishesRevisionOne {
  NSDictionary *workspace = [self bootstrapWithAccess:[self access]
                                           operationId:DSHOperationA
                                                 error:nil];
  XCTAssertNotNil(workspace);
  XCTAssertEqual(self.resolverCalls, 1u);
  XCTAssertEqualObjects(workspace[@"display_name"], @"Legacy Repo");
  XCTAssertEqualObjects(workspace[@"origin"], @"legacy_app_owned");
  XCTAssertEqualObjects(workspace[@"binding_revision"], @1);
  XCTAssertNil(workspace[@"path"]);

  NSDictionary *record = [self recordForRoot:self.rootURL
                                  workspaceId:DSHWorkspaceA];
  XCTAssertEqualObjects(record[@"root_locator_kind"], @"legacy_app_owned");
  NSDictionary *authority = [NSJSONSerialization JSONObjectWithData:
      [NSData dataWithContentsOfURL:[self authorityURLForRoot:self.rootURL
          kind:@"legacy" workspaceId:DSHWorkspaceA revision:1]]
      options:0 error:nil];
  XCTAssertEqualObjects(authority[@"project_metadata_sha256"], DSHDigestA);
  XCTAssertNotNil(authority[@"root_fingerprint_sha256"]);
  XCTAssertNil(authority[@"path"]);
}

- (void)testBootstrapOperationConflictAndDuplicateProjectFailClosed {
  DSHLocalWorkspaceAccess *access = [self access];
  XCTAssertNotNil([self bootstrapWithAccess:access
                                operationId:DSHOperationA error:nil]);
  NSUInteger callsAfterCommit = self.resolverCalls;

  NSError *error = nil;
  XCTAssertNil([access bootstrapLegacyProjectId:DSHProjectWide
                                      operationId:DSHOperationA error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_CONFLICT");
  XCTAssertEqual(self.resolverCalls, callsAfterCommit);

  error = nil;
  XCTAssertNil([access bootstrapLegacyProjectId:DSHProjectA
                                      operationId:DSHOperationB error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_CONFLICT");
  XCTAssertEqual(self.resolverCalls, callsAfterCommit);
  XCTAssertEqual([access listWorkspaceMetadataWithError:nil].count, 1u);
}

- (void)testCommittedBootstrapReplayWinsOverUnrelatedPendingJournal {
  DSHLocalWorkspaceAccess *existing = [self access];
  NSDictionary *first = [self bootstrapWithAccess:existing
                                       operationId:DSHOperationA error:nil];
  XCTAssertNotNil(first);

  self.resolverDisplayName = @"Second Legacy Repo";
  DSHLocalWorkspaceAccess *pending = [self accessWithRoot:self.rootURL
      fault:^BOOL(NSString *stage) {
        return [stage isEqual:@"after_authority_ready"];
      }
      workspaceId:DSHWorkspaceB];
  XCTAssertNil([pending bootstrapLegacyProjectId:DSHProjectWide
                                      operationId:DSHOperationB error:nil]);
  self.resolverDisplayName = @"Renamed while another journal is pending";
  NSUInteger callsBeforeReplay = self.resolverCalls;
  NSDictionary *replayed = [existing bootstrapLegacyProjectId:DSHProjectA
                                                    operationId:DSHOperationA
                                                          error:nil];
  XCTAssertEqualObjects(replayed, first);
  XCTAssertEqual(self.resolverCalls, callsBeforeReplay);
}

- (void)testLegacyPhysicalSwapMakesOperationalResolutionUnavailable {
  DSHLocalWorkspaceAccess *access = [self access];
  XCTAssertNotNil([self bootstrapWithAccess:access
                                operationId:DSHOperationA error:nil]);
  self.resolverRepositoryInode = @"10";
  NSError *error = nil;
  XCTAssertNil([self resolve:access revision:@1 capabilities:@[@"read"]
                       error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_UNAVAILABLE");
}

- (void)testLegacyProjectReverseLookupSucceedsAcrossRestart {
  DSHLocalWorkspaceAccess *access = [self access];
  XCTAssertNotNil([self bootstrapWithAccess:access
                                operationId:DSHOperationA error:nil]);
  NSError *error = nil;
  XCTAssertEqualObjects(
      [access legacyProjectIdForWorkspaceId:DSHWorkspaceA
                    expectedBindingRevision:1 error:&error],
      DSHProjectA);
  XCTAssertNil(error);

  DSHLocalWorkspaceAccess *restarted = [self access];
  XCTAssertEqualObjects(
      [restarted legacyProjectIdForWorkspaceId:DSHWorkspaceA
                       expectedBindingRevision:1 error:&error],
      DSHProjectA);
  XCTAssertNil(error);
}

- (void)testLegacyProjectReverseLookupRejectsWrongRevisionAndMissingWorkspace {
  DSHLocalWorkspaceAccess *access = [self access];
  XCTAssertNotNil([self bootstrapWithAccess:access
                                operationId:DSHOperationA error:nil]);
  NSUInteger callsAfterBootstrap = self.resolverCalls;
  NSError *error = nil;
  XCTAssertNil([access legacyProjectIdForWorkspaceId:DSHWorkspaceA
                              expectedBindingRevision:2 error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"],
                        @"E_WORKSPACE_REVISION_STALE");
  XCTAssertEqual(self.resolverCalls, callsAfterBootstrap);

  error = nil;
  XCTAssertNil([access legacyProjectIdForWorkspaceId:DSHWorkspaceB
                              expectedBindingRevision:1 error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_NOT_FOUND");
}

- (void)testLegacyProjectReverseLookupReturnsNoRelationForOrdinaryWorkspace {
  DSHLocalWorkspaceAccess *access = [self access];
  XCTAssertTrue([access ensurePrivateLayoutWithError:nil]);
  NSDictionary *ordinary = [self recordForWorkspaceId:DSHWorkspaceA
                                                origin:@"rish_created"
                                       rootLocatorKind:@"documents_owned"
                                         locationClass:@"rish_owned"
                                   ownedDirectoryName:@"Ordinary"
                                      legacyProjectId:nil
                                     bindingRevision:1];
  [self writeRegistryRecords:@[ordinary] generation:1 root:self.rootURL];
  NSError *error = nil;
  XCTAssertNil([access legacyProjectIdForWorkspaceId:DSHWorkspaceA
                              expectedBindingRevision:1 error:&error]);
  XCTAssertNil(error);
  XCTAssertEqual(self.resolverCalls, 0u);
}

- (void)testLegacyProjectReverseLookupRejectsEvidenceAndFingerprintDrift {
  DSHLocalWorkspaceAccess *access = [self access];
  XCTAssertNotNil([self bootstrapWithAccess:access
                                operationId:DSHOperationA error:nil]);
  self.resolverRepositoryInode = @"10";
  NSError *error = nil;
  XCTAssertNil([access legacyProjectIdForWorkspaceId:DSHWorkspaceA
                              expectedBindingRevision:1 error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"],
                        @"E_WORKSPACE_ROOT_CHANGED");

  self.resolverRepositoryInode = @"9";
  NSURL *authorityURL = [self authorityURLForRoot:self.rootURL kind:@"legacy"
                                      workspaceId:DSHWorkspaceA revision:1];
  NSMutableDictionary *authority = [[NSJSONSerialization JSONObjectWithData:
      [NSData dataWithContentsOfURL:authorityURL] options:0 error:nil]
      mutableCopy];
  authority[@"root_fingerprint_sha256"] = DSHDigestB;
  [self secureWriteObject:authority toURL:authorityURL];
  error = nil;
  XCTAssertNil([access legacyProjectIdForWorkspaceId:DSHWorkspaceA
                              expectedBindingRevision:1 error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"],
                        @"E_WORKSPACE_PERSISTENCE");
}

- (void)testAccessInstancesShareOneAuthorityExecutor {
  dispatch_semaphore_t authorityReady = dispatch_semaphore_create(0);
  dispatch_semaphore_t releaseFirst = dispatch_semaphore_create(0);
  dispatch_semaphore_t firstDone = dispatch_semaphore_create(0);
  dispatch_semaphore_t secondDone = dispatch_semaphore_create(0);
  DSHLocalWorkspaceAccess *first = [self accessWithRoot:self.rootURL
      fault:^BOOL(NSString *stage) {
        if ([stage isEqual:@"after_authority_ready"]) {
          dispatch_semaphore_signal(authorityReady);
          dispatch_semaphore_wait(releaseFirst,
              dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
        }
        return NO;
      }
      workspaceId:DSHWorkspaceA];
  DSHLocalWorkspaceAccess *second = [self accessWithRoot:self.rootURL
                                                   fault:nil
                                             workspaceId:DSHWorkspaceB];
  XCTAssertTrue([first ensurePrivateLayoutWithError:nil]);
  XCTAssertTrue([second ensurePrivateLayoutWithError:nil]);
  __block NSDictionary *firstResult = nil;
  __block NSDictionary *secondResult = nil;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    firstResult = [first bootstrapLegacyProjectId:DSHProjectA
                                        operationId:DSHOperationA error:nil];
    dispatch_semaphore_signal(firstDone);
  });
  XCTAssertEqual(dispatch_semaphore_wait(authorityReady,
      dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)), 0l);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    secondResult = [second bootstrapLegacyProjectId:DSHProjectWide
                                          operationId:DSHOperationB error:nil];
    dispatch_semaphore_signal(secondDone);
  });
  XCTAssertNotEqual(dispatch_semaphore_wait(secondDone,
      dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)), 0l);
  dispatch_semaphore_signal(releaseFirst);
  XCTAssertEqual(dispatch_semaphore_wait(firstDone,
      dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)), 0l);
  XCTAssertEqual(dispatch_semaphore_wait(secondDone,
      dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)), 0l);
  XCTAssertNotNil(firstResult);
  XCTAssertNotNil(secondResult);
  XCTAssertEqual([[self access] listWorkspaceMetadataWithError:nil].count, 2u);
}

- (void)testLegacyBootstrapAcceptsCanonicalUUIDOutsideVersionAndVariantSubset {
  DSHLocalWorkspaceAccess *access = [self access];
  NSError *error = nil;
  NSDictionary *workspace = [access bootstrapLegacyProjectId:DSHProjectWide
                                                    operationId:DSHOperationA
                                                          error:&error];
  XCTAssertNotNil(workspace);
  XCTAssertNil(error);
}

- (NSDictionary *)receiptWithIndex:(NSUInteger)index committedAt:(NSString *)timestamp {
  NSString *operationId = [NSString stringWithFormat:@"%08lx-0000-4000-8000-%012lx",
                           (unsigned long)index, (unsigned long)index];
  return @{
    @"schema_version": @1,
    @"operation_id": operationId,
    @"workspace_id": DSHWorkspaceB,
    @"operation": @"bootstrap_legacy",
    @"binding_revision": @1,
    @"registry_generation": @1,
    @"registry_sha256": DSHDigestA,
    @"request_sha256": DSHDigestB,
    @"outcome": @"committed",
    @"committed_at": timestamp,
  };
}

- (void)testReceiptTTLPrunesExpiredCapacityAndSurvivesRestart {
  DSHLocalWorkspaceAccess *access = [self access];
  XCTAssertTrue([access ensurePrivateLayoutWithError:nil]);
  NSMutableArray *receipts = [NSMutableArray arrayWithCapacity:2048];
  for (NSUInteger index = 0; index < 2048; index++) {
    [receipts addObject:[self receiptWithIndex:index committedAt:DSHTimestamp]];
  }
  [self secureWriteObject:@{@"schema_version": @1, @"receipts": receipts}
                    toURL:[self receiptsURLForRoot:self.rootURL]];
  NSError *error = nil;
  XCTAssertNil([self bootstrapWithAccess:access operationId:DSHOperationA
                                   error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_BUSY");

  self.now = [self.now dateByAddingTimeInterval:31 * 24 * 60 * 60];
  DSHLocalWorkspaceAccess *restarted = [self access];
  XCTAssertNotNil([self bootstrapWithAccess:restarted
                                operationId:DSHOperationA error:&error]);
  XCTAssertEqualObjects([restarted queryOperationId:DSHOperationA
                                              error:&error][@"status"],
                        @"committed");
}

- (void)testReceiptStoreRejectsImpossibleBootstrapOutcomeAndRevision {
  DSHLocalWorkspaceAccess *access = [self access];
  XCTAssertTrue([access ensurePrivateLayoutWithError:nil]);
  NSMutableDictionary *impossible =
      [[self receiptWithIndex:9 committedAt:DSHTimestamp] mutableCopy];
  impossible[@"outcome"] = @"purge_pending";
  [self secureWriteObject:@{@"schema_version": @1,
                            @"receipts": @[impossible]}
                    toURL:[self receiptsURLForRoot:self.rootURL]];
  XCTAssertNil([access queryOperationId:impossible[@"operation_id"] error:nil]);

  impossible[@"outcome"] = @"committed";
  impossible[@"binding_revision"] = @2;
  [self secureWriteObject:@{@"schema_version": @1,
                            @"receipts": @[impossible]}
                    toURL:[self receiptsURLForRoot:self.rootURL]];
  XCTAssertNil([access queryOperationId:impossible[@"operation_id"] error:nil]);
}

- (void)testRevisionStartsAtOneIncrementsMonotonicallyAndOverflowsClosed {
  DSHLocalWorkspaceAccess *access = [self access];
  NSDictionary *created = [self bootstrapWithAccess:access
                                        operationId:DSHOperationA error:nil];
  XCTAssertEqualObjects(created[@"binding_revision"], @1);

  NSError *error = nil;
  XCTAssertTrue(DSHLocalWorkspaceValidateBindingRevisionAdvance(@1, @2, &error));
  XCTAssertNil(error);
  XCTAssertFalse(DSHLocalWorkspaceValidateBindingRevisionAdvance(@2, @4, &error));
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_CONFLICT");
  XCTAssertFalse(DSHLocalWorkspaceValidateBindingRevisionAdvance(
      @((NSUInteger)9007199254740991ULL),
      @((NSUInteger)9007199254740991ULL), &error));
  XCTAssertEqualObjects(error.userInfo[@"code"],
                        @"E_WORKSPACE_REVISION_OVERFLOW");
}

- (void)testMalformedJournalReceiptRootReplacementAndForeignExceptionsAreValueFree {
  DSHLocalWorkspaceAccess *access = [self access];
  XCTAssertTrue([access ensurePrivateLayoutWithError:nil]);
  [self secureWriteObject:@{@"schema_version": @1, @"native_error": @"secret"}
                    toURL:[self journalURLForRoot:self.rootURL]];
  NSError *error = nil;
  XCTAssertNil([access listWorkspaceMetadataWithError:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_PERSISTENCE");
  XCTAssertFalse([[self JSONText:error] containsString:@"secret"]);

  [NSFileManager.defaultManager removeItemAtURL:[self journalURLForRoot:self.rootURL]
                                          error:nil];
  [self secureWriteObject:@{@"schema_version": @1,
                            @"receipts": @[@{@"bad": @"/private/secret"}]}
                    toURL:[self receiptsURLForRoot:self.rootURL]];
  DSHLocalWorkspaceAccess *receiptReader = [self access];
  XCTAssertNil([receiptReader queryOperationId:DSHOperationA error:&error]);
  XCTAssertFalse([[self JSONText:error] containsString:@"/private/secret"]);

  NSURL *moved = [self.rootURL URLByAppendingPathExtension:@"moved"];
  XCTAssertTrue([NSFileManager.defaultManager moveItemAtURL:self.rootURL
                                                     toURL:moved error:nil]);
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:self.rootURL
                                       withIntermediateDirectories:YES
                                                        attributes:nil error:nil]);
  XCTAssertNil([access listWorkspaceMetadataWithError:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_UNAVAILABLE");
  [NSFileManager.defaultManager removeItemAtURL:moved error:nil];

  NSURL *throwRoot = [self.rootURL URLByAppendingPathComponent:@"throw"
                                                   isDirectory:YES];
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:throwRoot
                                       withIntermediateDirectories:YES
                                                        attributes:nil error:nil]);
  self.resolverThrows = YES;
  DSHLocalWorkspaceAccess *throwing = [self accessWithRoot:throwRoot fault:nil];
  XCTAssertNil([self bootstrapWithAccess:throwing operationId:DSHOperationA
                                   error:&error]);
  NSString *errorText = [self JSONText:error];
  XCTAssertFalse([errorText containsString:@"PrivateResolverFailure"]);
  XCTAssertFalse([errorText containsString:@"/private/secret"]);
}

- (void)testPublicOutputsNeverExposePathsBookmarkBytesInodesOrNativeErrors {
  DSHLocalWorkspaceAccess *access = [self access];
  XCTAssertNotNil([self bootstrapWithAccess:access
                                operationId:DSHOperationA error:nil]);
  NSArray *listed = [access listWorkspaceMetadataWithError:nil];
  NSDictionary *resolved = [self resolve:access revision:@1
                               capabilities:@[@"read"] error:nil];
  NSDictionary *query = [access queryOperationId:DSHOperationA error:nil];
  NSString *text = [self JSONText:@{ @"list": listed,
                                     @"resolved": resolved,
                                     @"query": query }];
  for (NSString *forbidden in @[@"/private/", @"bookmark_bytes_base64",
                                @"PRIVATE_BOOKMARK_BYTES", @"inode_id",
                                @"device_id", @"root_identity_sha256",
                                @"native_error"]) {
    XCTAssertFalse([text containsString:forbidden], @"leaked %@", forbidden);
  }
  [self assertDictionary:listed.firstObject hasExactKeys:@[
    @"schema_version", @"workspace_id", @"display_name", @"origin", @"status",
    @"binding_revision", @"capabilities", @"created_at", @"last_opened_at"
  ]];
  [self assertDictionary:listed.firstObject[@"capabilities"] hasExactKeys:@[
    @"read", @"write", @"git", @"project_context", @"files_visible"
  ]];
  [self assertDictionary:resolved
             hasExactKeys:@[@"schema_version", @"disposition", @"workspace"]];
  [self assertDictionary:query
             hasExactKeys:@[@"schema_version", @"status", @"receipt"]];
  [self assertDictionary:query[@"receipt"] hasExactKeys:@[
    @"schema_version", @"operation_id", @"workspace_id", @"operation",
    @"binding_revision", @"registry_generation", @"registry_sha256",
    @"outcome", @"committed_at"
  ]];
  XCTAssertNil(query[@"receipt"][@"request_sha256"]);
}

- (void)testDocumentsAndGrantedOperationalResolveFailUnavailableWithZeroCapabilities {
  DSHLocalWorkspaceAccess *access = [self access];
  XCTAssertTrue([access ensurePrivateLayoutWithError:nil]);
  NSData *bookmark = [@"BOOKMARK" dataUsingEncoding:NSUTF8StringEncoding];
  NSString *bookmarkDigest = [self sha256ForData:bookmark];
  NSArray *records = @[
    [self recordForWorkspaceId:DSHWorkspaceA origin:@"rish_created"
               rootLocatorKind:@"documents_owned" locationClass:@"rish_owned"
         ownedDirectoryName:@"Owned A" legacyProjectId:nil bindingRevision:1],
    [self recordForWorkspaceId:DSHWorkspaceB origin:@"granted_folder"
               rootLocatorKind:@"security_scoped" locationClass:@"proven_local"
         ownedDirectoryName:nil legacyProjectId:nil bindingRevision:1],
  ];
  [self writeRegistryRecords:records generation:1 root:self.rootURL];
  [self secureWriteObject:[self ownedAuthorityForWorkspace:DSHWorkspaceA
                                                   revision:1 directoryName:@"Owned A"]
                    toURL:[self authorityURLForRoot:self.rootURL kind:@"owned"
                                        workspaceId:DSHWorkspaceA revision:1]];
  [self secureWriteObject:[self bookmarkAuthorityForWorkspace:DSHWorkspaceB
                                                      revision:1 bytes:bookmark]
                    toURL:[self authorityURLForRoot:self.rootURL kind:@"bookmark"
                                        workspaceId:DSHWorkspaceB revision:1]];
  [self secureWriteObject:[self grantedAuthorityForWorkspace:DSHWorkspaceB
                                                     revision:1
                                                bookmarkDigest:bookmarkDigest]
                    toURL:[self authorityURLForRoot:self.rootURL kind:@"granted"
                                        workspaceId:DSHWorkspaceB revision:1]];

  NSArray *listed = [access listWorkspaceMetadataWithError:nil];
  XCTAssertEqual(listed.count, 2u);
  for (NSDictionary *descriptor in listed) {
    NSString *expectedStatus = [descriptor[@"origin"] isEqual:@"granted_folder"]
        ? @"revoked" : @"unavailable";
    XCTAssertEqualObjects(descriptor[@"status"], expectedStatus);
    XCTAssertEqualObjects(descriptor[@"capabilities"][@"read"], @NO);
    XCTAssertEqualObjects(descriptor[@"capabilities"][@"write"], @NO);
    XCTAssertEqualObjects(descriptor[@"capabilities"][@"git"], @NO);
    XCTAssertEqualObjects(descriptor[@"capabilities"][@"project_context"], @NO);
    BOOL owned = [descriptor[@"workspace_id"] isEqual:DSHWorkspaceA];
    XCTAssertEqualObjects(descriptor[@"capabilities"][@"files_visible"],
                          @(owned));
    NSDictionary *probe = [access resolveWorkspaceId:descriptor[@"workspace_id"]
                             expectedBindingRevision:nil
                                requiredCapabilities:@[@"read"] error:nil];
    XCTAssertEqualObjects(probe[@"workspace"][@"status"], expectedStatus);
    XCTAssertEqualObjects(probe[@"workspace"][@"capabilities"][@"read"], @NO);
  }

  for (NSString *workspace in @[DSHWorkspaceA, DSHWorkspaceB]) {
    NSError *error = nil;
    NSDictionary *result = [access resolveWorkspaceId:workspace
                               expectedBindingRevision:@1
                                  requiredCapabilities:@[@"read"]
                                                 error:&error];
    XCTAssertNil(result);
    XCTAssertEqualObjects(error.userInfo[@"code"],
        [workspace isEqual:DSHWorkspaceB]
            ? @"E_WORKSPACE_REVOKED" : @"E_WORKSPACE_UNAVAILABLE");
  }
  XCTAssertEqual(self.resolverCalls, 0u);
}

#pragma mark - Task B: Rish-owned Files-visible roots (RED before implementation)

- (void)testCreateRishOwnedWorkspaceExactRequestPublishesFilesVisibleRootAndOwnedAuthority {
  NSURL *documents = [self documentsRootForRoot:self.rootURL];
  DSHLocalWorkspaceAccess *access =
      [self accessWithRoot:self.rootURL
          documentsRootURL:documents
                     fault:nil
               UUIDGenerator:^NSString *{
                 return DSHWorkspaceA;
               }];
  NSError *error = nil;
  NSDictionary *descriptor =
      [access createRishOwnedWorkspaceWithDisplayName:@"Scratch"
                                           operationId:DSHOperationA
                                                 error:&error];
  XCTAssertNotNil(descriptor, @"%@", error);
  XCTAssertNil(error);
  [self assertDictionary:descriptor hasExactKeys:@[
    @"schema_version", @"workspace_id", @"display_name", @"origin",
    @"status", @"binding_revision", @"capabilities", @"created_at",
    @"last_opened_at"
  ]];
  XCTAssertEqualObjects(descriptor[@"schema_version"], @2);
  XCTAssertEqualObjects(descriptor[@"workspace_id"], DSHWorkspaceA);
  XCTAssertEqualObjects(descriptor[@"display_name"], @"Scratch");
  XCTAssertEqualObjects(descriptor[@"origin"], @"rish_created");
  XCTAssertEqualObjects(descriptor[@"status"], @"ok");
  XCTAssertEqualObjects(descriptor[@"binding_revision"], @1);
  XCTAssertEqualObjects(descriptor[@"capabilities"], (@{
    @"read": @YES, @"write": @YES, @"git": @YES,
    @"project_context": @YES, @"files_visible": @YES
  }));

  NSDictionary *record = [self recordForRoot:self.rootURL
                                   workspaceId:DSHWorkspaceA];
  XCTAssertNotNil(record);
  XCTAssertEqualObjects(record[@"owned_directory_name"], @"Scratch");
  NSURL *ownedRoot = [[self ownedWorkspacesRootForRoot:self.rootURL]
      URLByAppendingPathComponent:record[@"owned_directory_name"]
                       isDirectory:YES];
  struct stat rootState = {};
  XCTAssertEqual(lstat(ownedRoot.fileSystemRepresentation, &rootState), 0);
  XCTAssertTrue(S_ISDIR(rootState.st_mode));
  NSURL *authorityURL = [self authorityURLForRoot:self.rootURL
                                             kind:@"owned"
                                      workspaceId:DSHWorkspaceA
                                         revision:1];
  NSData *authorityData = [NSData dataWithContentsOfURL:authorityURL];
  NSDictionary *authority = authorityData == nil
      ? nil
      : [NSJSONSerialization JSONObjectWithData:authorityData options:0 error:nil];
  XCTAssertNotNil(authority);
  XCTAssertEqualObjects(authority[@"workspace_id"], DSHWorkspaceA);
  XCTAssertEqualObjects(authority[@"binding_revision"], @1);
  XCTAssertEqualObjects(authority[@"device_id"],
                        ([NSString stringWithFormat:@"%llu",
                         (unsigned long long)rootState.st_dev]));
  XCTAssertEqualObjects(authority[@"inode_id"],
                        ([NSString stringWithFormat:@"%llu",
                         (unsigned long long)rootState.st_ino]));
  NSData *directoryData =
      [record[@"owned_directory_name"] dataUsingEncoding:NSUTF8StringEncoding];
  XCTAssertEqualObjects(authority[@"directory_name_sha256"],
                        [self sha256ForData:directoryData]);

  NSArray<NSURL *> *privateEntries = [NSFileManager.defaultManager
      contentsOfDirectoryAtURL:[self documentsRootForRoot:self.rootURL]
       includingPropertiesForKeys:nil
                          options:0
                            error:nil];
  for (NSURL *entry in privateEntries) {
    XCTAssertFalse([entry.lastPathComponent isEqual:@"local-workspaces"]);
    XCTAssertFalse([entry.lastPathComponent isEqual:@"workspace-bindings"]);
    XCTAssertFalse([entry.lastPathComponent hasSuffix:@".json"]);
  }
  NSNumber *excluded = nil;
  XCTAssertTrue([[self ownedWorkspacesRootForRoot:self.rootURL]
      getResourceValue:&excluded
                forKey:NSURLIsExcludedFromBackupKey
                 error:nil]);
  XCTAssertFalse(excluded.boolValue);
}

- (void)testCreateOwnedTerminalRevalidationRejectsAuthorityTamperAndRootReplacement {
  NSArray<NSString *> *tamperModes = @[@"authority", @"root"];
  for (NSString *mode in tamperModes) {
    NSURL *root = [self.rootURL URLByAppendingPathComponent:mode
                                                isDirectory:YES];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:root
                                         withIntermediateDirectories:YES
                                                          attributes:nil
                                                               error:nil]);
    __weak LocalWorkspaceAccessTests *weakSelf = self;
    DSHLocalWorkspaceAccess *access = [self accessWithRoot:root
        documentsRootURL:[self documentsRootForRoot:root]
        fault:^BOOL(NSString *stage) {
          if (![stage isEqual:@"before_create_terminal_validation"]) return NO;
          LocalWorkspaceAccessTests *strongSelf = weakSelf;
          if ([mode isEqual:@"authority"]) {
            NSURL *authorityURL = [strongSelf authorityURLForRoot:root
                                                              kind:@"owned"
                                                       workspaceId:DSHWorkspaceA
                                                          revision:1];
            NSMutableDictionary *authority = [[NSJSONSerialization
                JSONObjectWithData:[NSData dataWithContentsOfURL:authorityURL]
                             options:0
                               error:nil] mutableCopy];
            authority[@"root_fingerprint_sha256"] = DSHDigestB;
            [strongSelf secureWriteObject:authority toURL:authorityURL];
          } else {
            NSURL *ownedRoot = [[strongSelf ownedWorkspacesRootForRoot:root]
                URLByAppendingPathComponent:@"Scratch" isDirectory:YES];
            [NSFileManager.defaultManager removeItemAtURL:ownedRoot error:nil];
            [NSFileManager.defaultManager createDirectoryAtURL:ownedRoot
                                    withIntermediateDirectories:NO
                                                     attributes:nil
                                                          error:nil];
          }
          return NO;
        }
        UUIDGenerator:^NSString *{
          return DSHWorkspaceA;
        }];
    NSError *error = nil;
    XCTAssertNil([access createRishOwnedWorkspaceWithDisplayName:@"Scratch"
                                                     operationId:DSHOperationA
                                                           error:&error]);
    XCTAssertTrue([error.userInfo[@"code"] isEqual:@"E_WORKSPACE_PERSISTENCE"] ||
                  [error.userInfo[@"code"] isEqual:@"E_WORKSPACE_UNAVAILABLE"] ||
                  [error.userInfo[@"code"] isEqual:@"E_WORKSPACE_ROOT_CHANGED"]);
  }
}

- (void)testOwnedRootSurvivesADeviceIdentifierChangeButNotAnInodeChange {
  // iOS renumbers the data volume across reboots, so a persisted st_dev stops
  // matching while the directory itself is untouched. A workspace must still
  // resolve; only a genuinely different directory may be rejected.
  NSURL *documents = [self documentsRootForRoot:self.rootURL];
  DSHLocalWorkspaceAccess *access =
      [self accessWithRoot:self.rootURL
          documentsRootURL:documents
                     fault:nil
               UUIDGenerator:^NSString *{
                 return DSHWorkspaceA;
               }];
  NSDictionary *created =
      [access createRishOwnedWorkspaceWithDisplayName:@"Reboot"
                                          operationId:DSHOperationA
                                                error:nil];
  XCTAssertNotNil(created);
  NSString *directoryName =
      created[@"workspace"][@"owned_directory_name"] ?: @"Reboot";
  NSURL *ownedRoot = [[self ownedWorkspacesRootForRoot:self.rootURL]
      URLByAppendingPathComponent:directoryName isDirectory:YES];
  struct stat state = {};
  XCTAssertEqual(lstat(ownedRoot.fileSystemRepresentation, &state), 0);

  NSURL *authorityURL = [self authorityURLForRoot:self.rootURL
                                             kind:@"owned"
                                      workspaceId:DSHWorkspaceA
                                         revision:1];
  NSString *realInode = [NSString stringWithFormat:@"%llu",
                         (unsigned long long)state.st_ino];
  NSString *renumberedDevice = [NSString stringWithFormat:@"%llu",
                                (unsigned long long)state.st_dev + 7u];
  [self secureWriteObject:[self ownedAuthorityForWorkspace:DSHWorkspaceA
                                                  revision:1
                                             directoryName:directoryName
                                                  deviceId:renumberedDevice
                                                   inodeId:realInode]
                    toURL:authorityURL];

  NSError *error = nil;
  NSDictionary *resolved = [access resolveWorkspaceId:DSHWorkspaceA
                              expectedBindingRevision:@1
                                 requiredCapabilities:@[@"read"]
                                                error:&error];
  XCTAssertNotNil(resolved, @"%@", error);
  XCTAssertNil(error);

  NSString *foreignInode = [NSString stringWithFormat:@"%llu",
                            (unsigned long long)state.st_ino + 7u];
  [self secureWriteObject:[self ownedAuthorityForWorkspace:DSHWorkspaceA
                                                  revision:1
                                             directoryName:directoryName
                                                  deviceId:renumberedDevice
                                                   inodeId:foreignInode]
                    toURL:authorityURL];
  error = nil;
  XCTAssertNil([access resolveWorkspaceId:DSHWorkspaceA
                  expectedBindingRevision:@1
                     requiredCapabilities:@[@"read"]
                                    error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_ROOT_CHANGED");
}

- (void)testOwnedLeaseAndCoordinatedOperationUseTheVerifiedDescriptor {
  NSURL *documents = [self documentsRootForRoot:self.rootURL];
  DSHLocalWorkspaceAccess *access =
      [self accessWithRoot:self.rootURL
          documentsRootURL:documents
                     fault:nil
               UUIDGenerator:^NSString *{
                 return DSHWorkspaceA;
               }];
  XCTAssertNotNil([access createRishOwnedWorkspaceWithDisplayName:@"Lease"
                                                        operationId:DSHOperationA
                                                              error:nil]);
  NSError *error = nil;
  DSHLocalWorkspaceLease *lease =
      [access leaseWorkspaceId:DSHWorkspaceA
       expectedBindingRevision:1
          requiredCapabilities:[NSSet setWithArray:@[@"read"]]
                         error:&error];
  XCTAssertNotNil(lease, @"%@", error);
  XCTAssertNil(error);
  XCTAssertEqualObjects(lease.workspaceId, DSHWorkspaceA);
  XCTAssertEqual(lease.bindingRevision, 1u);
  XCTAssertGreaterThanOrEqual(lease.rootDescriptor, 0);
  XCTAssertTrue(lease.supportsGit);
  XCTAssertTrue(lease.supportsProjectContext);
  struct stat state = {};
  XCTAssertEqual(fstat(lease.rootDescriptor, &state), 0);
  XCTAssertTrue(S_ISDIR(state.st_mode));
  lease = nil;

  __block int coordinatedDescriptor = -1;
  BOOL coordinated = [access
      performCoordinatedWorkspaceOperationForId:DSHWorkspaceA
                       expectedBindingRevision:1
                          requiredCapabilities:[NSSet setWithArray:@[@"read"]]
                                         block:^BOOL(int descriptor,
                                                     NSError **blockError) {
    (void)blockError;
    coordinatedDescriptor = descriptor;
    struct stat coordinatedState = {};
    return fstat(descriptor, &coordinatedState) == 0 &&
           S_ISDIR(coordinatedState.st_mode);
  }
                                         error:&error];
  XCTAssertTrue(coordinated, @"%@", error);
  XCTAssertNil(error);
  XCTAssertGreaterThanOrEqual(coordinatedDescriptor, 0);
  XCTAssertEqual(fcntl(coordinatedDescriptor, F_GETFD), -1);
  XCTAssertEqualObjects(
      [[access resolveWorkspaceId:DSHWorkspaceA
            expectedBindingRevision:@2
               requiredCapabilities:@[] error:&error]
          valueForKey:@"disposition"], nil);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_REVISION_STALE");
}

- (void)testSecurityScopedRejectsNonFileCapabilitiesBeforeOpeningAuthority {
  DSHLocalWorkspaceAccess *access = [self access];
  XCTAssertTrue([access ensurePrivateLayoutWithError:nil]);
  [self writeRegistryRecords:@[
    [self recordForWorkspaceId:DSHWorkspaceA
                         origin:@"granted_folder"
                rootLocatorKind:@"security_scoped"
                  locationClass:@"proven_local"
            ownedDirectoryName:nil
               legacyProjectId:nil
              bindingRevision:1],
  ] generation:1 root:self.rootURL];
  for (NSString *capability in @[@"git", @"project_context"]) {
    NSError *error = nil;
    BOOL performed = [access
        performCoordinatedWorkspaceOperationForId:DSHWorkspaceA
                         expectedBindingRevision:1
                            requiredCapabilities:[NSSet setWithArray:@[capability]]
                                           block:^BOOL(__unused int descriptor,
                                                       __unused NSError **blockError) {
      XCTFail(@"capability rejection must happen before the block");
      return YES;
    }
                                           error:&error];
    XCTAssertFalse(performed);
    XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_CAPABILITY");
  }
  XCTAssertFalse([NSFileManager.defaultManager
      fileExistsAtPath:[self authorityURLForRoot:self.rootURL kind:@"bookmark"
                                     workspaceId:DSHWorkspaceA revision:1].path]);
}

- (void)testLegacyLeaseFailsClosedWithoutARealVerifiedRootDescriptor {
  DSHLocalWorkspaceAccess *access = [self access];
  XCTAssertNotNil([self bootstrapWithAccess:access
                                operationId:DSHOperationA
                                      error:nil]);
  NSError *error = nil;
  XCTAssertNil([access leaseWorkspaceId:DSHWorkspaceA
                  expectedBindingRevision:1
                     requiredCapabilities:[NSSet setWithArray:@[@"read"]]
                                    error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_UNAVAILABLE");
  error = nil;
  BOOL performed = [access
      performCoordinatedWorkspaceOperationForId:DSHWorkspaceA
                       expectedBindingRevision:1
                          requiredCapabilities:[NSSet setWithArray:@[@"read"]]
                                         block:^BOOL(__unused int descriptor,
                                                     __unused NSError **blockError) {
    XCTFail(@"legacy route must not pass descriptor -1");
    return YES;
  }
                                         error:&error];
  XCTAssertFalse(performed);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_ROOT_CHANGED");
}

- (void)testLeaseDoesNotRetainAuthorityFlockAcrossConcurrentEnsure {
  NSURL *documents = [self documentsRootForRoot:self.rootURL];
  DSHLocalWorkspaceAccess *access =
      [self accessWithRoot:self.rootURL
          documentsRootURL:documents
                     fault:nil
               UUIDGenerator:^NSString *{
                 return DSHWorkspaceA;
               }];
  XCTAssertNotNil([access createRishOwnedWorkspaceWithDisplayName:@"Concurrent"
                                                        operationId:DSHOperationA
                                                              error:nil]);
  DSHLocalWorkspaceLease *lease =
      [access leaseWorkspaceId:DSHWorkspaceA
       expectedBindingRevision:1
          requiredCapabilities:[NSSet setWithArray:@[@"read"]]
                         error:nil];
  XCTAssertNotNil(lease);
  XCTestExpectation *finished =
      [self expectationWithDescription:@"ensure completes while lease is active"];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
    NSError *error = nil;
    BOOL ensured = [access ensurePrivateLayoutWithError:&error];
    XCTAssertTrue(ensured, @"%@", error);
    [finished fulfill];
  });
  [self waitForExpectations:@[finished] timeout:2.0];
  lease = nil;
}

- (void)testCreateRishOwnedWorkspaceAllocatesCollisionSafeNormalizedDirectoryNames {
  NSURL *documents = [self documentsRootForRoot:self.rootURL];
  NSURL *container = [self ownedWorkspacesRootForRoot:self.rootURL];
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:container
                                           withIntermediateDirectories:YES
                                                            attributes:nil
                                                                 error:nil]);
  NSURL *preexisting = [container URLByAppendingPathComponent:@"scratch"
                                                    isDirectory:YES];
  XCTAssertEqual(mkdir(preexisting.fileSystemRepresentation, 0700), 0);

  DSHLocalWorkspaceAccess *first =
      [self accessWithRoot:self.rootURL
          documentsRootURL:documents
                     fault:nil
               UUIDGenerator:^NSString *{
                 return DSHWorkspaceA;
               }];
  NSError *error = nil;
  NSDictionary *one =
      [first createRishOwnedWorkspaceWithDisplayName:@"Scratch"
                                          operationId:DSHOperationA
                                                error:&error];
  XCTAssertNotNil(one, @"%@", error);
  XCTAssertEqualObjects([self recordForRoot:self.rootURL
                              workspaceId:DSHWorkspaceA][@"owned_directory_name"],
                        @"Scratch (1)");

  DSHLocalWorkspaceAccess *second =
      [self accessWithRoot:self.rootURL
          documentsRootURL:documents
                     fault:nil
               UUIDGenerator:^NSString *{
                 return DSHWorkspaceB;
               }];
  NSDictionary *two =
      [second createRishOwnedWorkspaceWithDisplayName:@"sCrAtCh"
                                           operationId:DSHOperationB
                                                 error:&error];
  XCTAssertNotNil(two, @"%@", error);
  XCTAssertEqualObjects([self recordForRoot:self.rootURL
                              workspaceId:DSHWorkspaceB][@"owned_directory_name"],
                        @"sCrAtCh (2)");
}

// A display name at the 120-byte bound has to give up bytes to make room for
// its ordinal suffix, and the cut falls on a composed character sequence.
// Foundation used to do that cutting inline; the core does it now, over
// clusters the host supplies, so this pins that the two agree. If the cut ever
// fell on a byte or a scalar boundary, the name would end in half a flag.
- (void)testOccupiedDisplayNameAtTheBoundIsTruncatedOnAClusterBoundary {
  NSURL *documents = [self documentsRootForRoot:self.rootURL];
  NSURL *container = [self ownedWorkspacesRootForRoot:self.rootURL];
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:container
                                       withIntermediateDirectories:YES
                                                        attributes:nil
                                                             error:nil]);
  NSString *flag = @"\U0001F1EF\U0001F1F5";
  XCTAssertEqual([flag lengthOfBytesUsingEncoding:NSUTF8StringEncoding], 8u);
  NSMutableString *name = [NSMutableString string];
  for (NSUInteger index = 0; index < 15; index += 1) [name appendString:flag];
  XCTAssertEqual([name lengthOfBytesUsingEncoding:NSUTF8StringEncoding], 120u);

  NSURL *preexisting = [container URLByAppendingPathComponent:name
                                                  isDirectory:YES];
  XCTAssertEqual(mkdir(preexisting.fileSystemRepresentation, 0700), 0);

  DSHLocalWorkspaceAccess *access =
      [self accessWithRoot:self.rootURL
          documentsRootURL:documents
                     fault:nil
             UUIDGenerator:^NSString *{
               return DSHWorkspaceA;
             }];
  NSError *error = nil;
  NSDictionary *created =
      [access createRishOwnedWorkspaceWithDisplayName:name
                                          operationId:DSHOperationA
                                                error:&error];
  XCTAssertNotNil(created, @"%@", error);

  NSMutableString *expected = [NSMutableString string];
  for (NSUInteger index = 0; index < 14; index += 1) [expected appendString:flag];
  [expected appendString:@" (1)"];
  XCTAssertEqual([expected lengthOfBytesUsingEncoding:NSUTF8StringEncoding], 116u);
  NSString *allocated = [self recordForRoot:self.rootURL
                                workspaceId:DSHWorkspaceA][@"owned_directory_name"];
  XCTAssertEqualObjects(allocated, expected);
  // Nothing partial survived the cut: every flag in the name is whole.
  NSUInteger whole = [[allocated componentsSeparatedByString:flag] count] - 1;
  XCTAssertEqual(whole, 14u);
}

// An authority written before root fingerprints existed carries every field
// its shape names except that one. Opening it upgrades it in place: the same
// contents, sealed with the fingerprint they imply. Nothing else in the suite
// exercised that path, so this is the only thing standing between the
// migration rules and a green board that means nothing.
- (void)testAnAuthorityWrittenBeforeFingerprintsIsUpgradedInPlace {
  NSURL *documents = [self documentsRootForRoot:self.rootURL];
  DSHLocalWorkspaceAccess *access =
      [self accessWithRoot:self.rootURL
          documentsRootURL:documents
                     fault:nil
             UUIDGenerator:^NSString *{
               return DSHWorkspaceA;
             }];
  NSError *error = nil;
  XCTAssertNotNil([access createRishOwnedWorkspaceWithDisplayName:@"Scratch"
                                                      operationId:DSHOperationA
                                                            error:&error],
                  @"%@", error);
  NSURL *authorityURL = [self authorityURLForRoot:self.rootURL kind:@"owned"
                                      workspaceId:DSHWorkspaceA revision:1];
  NSDictionary *sealed = [NSJSONSerialization
      JSONObjectWithData:[NSData dataWithContentsOfURL:authorityURL]
                 options:0 error:nil];
  NSString *fingerprint = sealed[@"root_fingerprint_sha256"];
  XCTAssertEqual(fingerprint.length, 64u);

  // Roll it back to the pre-fingerprint shape.
  NSMutableDictionary *old = [sealed mutableCopy];
  [old removeObjectForKey:@"root_fingerprint_sha256"];
  [self secureWriteObject:old toURL:authorityURL];

  NSArray *metadata = [access listWorkspaceMetadataWithError:&error];
  XCTAssertNotNil(metadata, @"%@", error);
  XCTAssertEqual(metadata.count, 1u);
  XCTAssertEqualObjects(metadata.firstObject[@"status"], @"ok");

  // Upgraded in place, and to exactly the fingerprint it had before: the
  // migration seals the contents it was given and invents nothing.
  NSDictionary *upgraded = [NSJSONSerialization
      JSONObjectWithData:[NSData dataWithContentsOfURL:authorityURL]
                 options:0 error:nil];
  XCTAssertEqualObjects(upgraded, sealed);
  XCTAssertEqualObjects(upgraded[@"root_fingerprint_sha256"], fingerprint);
}

// An authority missing a field its shape names is not a pre-fingerprint
// authority, so there is nothing to upgrade — and the listing fails **closed**
// with E_WORKSPACE_PERSISTENCE rather than reporting that one workspace as
// unavailable. Storage that cannot be read as itself is not a workspace in a
// bad state; it is storage that cannot be trusted to describe any of them.
// (Measured, not assumed: the first draft of this test expected a per-record
// non-ok status and was wrong.)
- (void)testAnIncompleteAuthorityIsNotUpgraded {
  NSURL *documents = [self documentsRootForRoot:self.rootURL];
  DSHLocalWorkspaceAccess *access =
      [self accessWithRoot:self.rootURL
          documentsRootURL:documents
                     fault:nil
             UUIDGenerator:^NSString *{
               return DSHWorkspaceA;
             }];
  NSError *error = nil;
  XCTAssertNotNil([access createRishOwnedWorkspaceWithDisplayName:@"Scratch"
                                                      operationId:DSHOperationA
                                                            error:&error],
                  @"%@", error);
  NSURL *authorityURL = [self authorityURLForRoot:self.rootURL kind:@"owned"
                                      workspaceId:DSHWorkspaceA revision:1];
  NSMutableDictionary *broken = [[NSJSONSerialization
      JSONObjectWithData:[NSData dataWithContentsOfURL:authorityURL]
                 options:0 error:nil] mutableCopy];
  [broken removeObjectForKey:@"root_fingerprint_sha256"];
  [broken removeObjectForKey:@"inode_id"];
  [self secureWriteObject:broken toURL:authorityURL];

  error = nil;
  XCTAssertNil([access listWorkspaceMetadataWithError:&error]);
  XCTAssertEqualObjects(error.domain, @"dev.zseven.rish.local-workspace-access");
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_PERSISTENCE");
  // Left exactly as it was found.
  NSDictionary *after = [NSJSONSerialization
      JSONObjectWithData:[NSData dataWithContentsOfURL:authorityURL]
                 options:0 error:nil];
  XCTAssertEqualObjects(after, broken);
}

// One operation id names one outcome. A receipt store holding two of them
// cannot say which retry is the one that happened, so the store is refused
// whole rather than read past the duplicate. Nothing exercised that before.
- (void)testAReceiptStoreWithARepeatedOperationIdIsRefused {
  NSURL *documents = [self documentsRootForRoot:self.rootURL];
  DSHLocalWorkspaceAccess *access =
      [self accessWithRoot:self.rootURL
          documentsRootURL:documents
                     fault:nil
             UUIDGenerator:^NSString *{
               return DSHWorkspaceA;
             }];
  NSError *error = nil;
  XCTAssertNotNil([access createRishOwnedWorkspaceWithDisplayName:@"Scratch"
                                                      operationId:DSHOperationA
                                                            error:&error],
                  @"%@", error);
  NSURL *receiptsURL = [self receiptsURLForRoot:self.rootURL];
  NSMutableDictionary *envelope = [[NSJSONSerialization
      JSONObjectWithData:[NSData dataWithContentsOfURL:receiptsURL]
                 options:0 error:nil] mutableCopy];
  NSDictionary *receipt = ((NSArray *)envelope[@"receipts"]).firstObject;
  XCTAssertNotNil(receipt);
  // The same operation id twice, with the second disagreeing about the
  // outcome — exactly the case a retry could not resolve.
  NSMutableDictionary *twin = [receipt mutableCopy];
  twin[@"operation"] = @"delete_owned";
  twin[@"outcome"] = @"purge_pending";
  envelope[@"receipts"] = @[receipt, twin];
  [self secureWriteObject:envelope toURL:receiptsURL];

  DSHLocalWorkspaceAccess *restarted = [self access];
  error = nil;
  XCTAssertNil([restarted queryOperationId:DSHOperationA error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_PERSISTENCE");
}

- (void)testCreateRishOwnedWorkspaceRejectsInvalidDisplayNamesBeforeDocumentsMutation {
  NSURL *documents = [self documentsRootForRoot:self.rootURL];
  NSArray<NSString *> *invalidNames = @[
    @"", @" ", @".", @"..", @".hidden", @"Rish Workspaces",
    @"scratch/escape", @"scratch\\escape",
    [@"x" stringByPaddingToLength:121 withString:@"x" startingAtIndex:0]
  ];
  for (NSString *name in invalidNames) {
    DSHLocalWorkspaceAccess *access =
        [self accessWithRoot:self.rootURL
            documentsRootURL:documents
                       fault:nil
                 UUIDGenerator:^NSString *{
                   return DSHWorkspaceA;
                 }];
    NSError *error = nil;
    XCTAssertNil([access createRishOwnedWorkspaceWithDisplayName:name
                                                     operationId:DSHOperationA
                                                           error:&error],
                 @"name=%@", name);
    XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_INVALID",
                          @"name=%@", name);
  }
  XCTAssertFalse([NSFileManager.defaultManager
      fileExistsAtPath:[self documentsRootForRoot:self.rootURL].path]);
}

- (void)testRishOwnedRootIdentityIsRevalidatedAfterRelaunchAndReplacement {
  NSURL *documents = [self documentsRootForRoot:self.rootURL];
  DSHLocalWorkspaceAccess *access =
      [self accessWithRoot:self.rootURL
          documentsRootURL:documents
                     fault:nil
               UUIDGenerator:^NSString *{
                 return DSHWorkspaceA;
               }];
  NSError *error = nil;
  XCTAssertNotNil([access createRishOwnedWorkspaceWithDisplayName:@"Stable"
                                                       operationId:DSHOperationA
                                                             error:&error]);
  NSDictionary *record = [self recordForRoot:self.rootURL
                                   workspaceId:DSHWorkspaceA];
  NSURL *ownedRoot = [[self ownedWorkspacesRootForRoot:self.rootURL]
      URLByAppendingPathComponent:record[@"owned_directory_name"]
                       isDirectory:YES];
  DSHLocalWorkspaceAccess *restarted =
      [self accessWithRoot:self.rootURL
          documentsRootURL:documents
                     fault:nil
               UUIDGenerator:^NSString *{
                 return DSHWorkspaceB;
               }];
  NSDictionary *listed = [restarted listWorkspaceMetadataWithError:&error].firstObject;
  XCTAssertEqualObjects(listed[@"status"], @"ok");
  XCTAssertEqualObjects(listed[@"binding_revision"], @1);

  XCTAssertTrue([NSFileManager.defaultManager removeItemAtURL:ownedRoot
                                                         error:&error]);
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:ownedRoot
                                           withIntermediateDirectories:NO
                                                            attributes:nil
                                                                 error:&error]);
  NSArray *replaced = [restarted listWorkspaceMetadataWithError:&error];
  XCTAssertNotNil(replaced);
  XCTAssertEqualObjects(replaced.firstObject[@"status"], @"unavailable");
  XCTAssertEqualObjects(replaced.firstObject[@"capabilities"], (@{
    @"read": @NO, @"write": @NO, @"git": @NO,
    @"project_context": @NO, @"files_visible": @YES
  }));
  XCTAssertNil([restarted resolveWorkspaceId:DSHWorkspaceA
                   expectedBindingRevision:@1
                      requiredCapabilities:@[@"read"]
                                     error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_ROOT_CHANGED");
}

- (void)testRishOwnedCreateFsyncFailureLeavesNoPublishedWorkspaceAndRecoversOnRelaunch {
  NSURL *documents = [self documentsRootForRoot:self.rootURL];
  DSHLocalWorkspaceAccess *access =
      [self accessWithRoot:self.rootURL
          documentsRootURL:documents
                     fault:^BOOL(NSString *stage) {
                       return [stage isEqual:@"create_after_staging_fsync"];
                     }
               UUIDGenerator:^NSString *{
                 return DSHWorkspaceA;
               }];
  NSError *error = nil;
  XCTAssertNil([access createRishOwnedWorkspaceWithDisplayName:@"Crash"
                                                    operationId:DSHOperationA
                                                          error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_PERSISTENCE");
  DSHLocalWorkspaceAccess *restarted =
      [self accessWithRoot:self.rootURL
          documentsRootURL:documents
                     fault:nil
               UUIDGenerator:^NSString *{
                 return DSHWorkspaceA;
               }];
  XCTAssertEqual([restarted listWorkspaceMetadataWithError:&error].count, 0u);
  XCTAssertEqualObjects([restarted queryOperationId:DSHOperationA
                                               error:&error][@"status"],
                        @"not_started");
}

// The journal records the staging directory's device, inode, uid and gid, and
// recovery checks them against what it stats before it touches anything. A
// journal whose recorded identity is not the directory on disk describes some
// other directory, so recovery refuses and preserves the evidence rather than
// deleting a folder it cannot account for.
//
// Nothing exercised this before: making DSHJournalIdentityMatchesState return
// YES unconditionally left all 68 tests green.
- (void)testRecoveryRefusesAJournalWhoseIdentityIsNotTheDirectoryOnDisk {
  NSURL *documents = [self documentsRootForRoot:self.rootURL];
  DSHLocalWorkspaceAccess *access =
      [self accessWithRoot:self.rootURL
          documentsRootURL:documents
                     fault:^BOOL(NSString *stage) {
                       return [stage isEqual:@"create_after_staging_fsync"];
                     }
             UUIDGenerator:^NSString *{
               return DSHWorkspaceA;
             }];
  NSError *error = nil;
  XCTAssertNil([access createRishOwnedWorkspaceWithDisplayName:@"Crash"
                                                   operationId:DSHOperationA
                                                         error:&error]);
  NSURL *journalURL = [self journalURLForRoot:self.rootURL];
  NSMutableDictionary *journal = [[NSJSONSerialization
      JSONObjectWithData:[NSData dataWithContentsOfURL:journalURL]
                 options:0 error:nil] mutableCopy];
  XCTAssertEqualObjects(journal[@"phase"], @"prepared");
  NSString *recordedInode = journal[@"staging_inode_id"];
  XCTAssertTrue([recordedInode isKindOfClass:NSString.class]);
  NSString *stagingName = journal[@"staging_name"];
  NSURL *staging = [[self ownedWorkspacesRootForRoot:self.rootURL]
      URLByAppendingPathComponent:stagingName isDirectory:YES];
  XCTAssertTrue([NSFileManager.defaultManager
      fileExistsAtPath:staging.path]);

  // Same directory, a different inode recorded: this journal is about some
  // other folder.
  journal[@"staging_inode_id"] =
      [@(recordedInode.longLongValue + 1) stringValue];
  [self secureWriteObject:journal toURL:journalURL];

  DSHLocalWorkspaceAccess *restarted =
      [self accessWithRoot:self.rootURL
          documentsRootURL:documents
                     fault:nil
             UUIDGenerator:^NSString *{
               return DSHWorkspaceA;
             }];
  error = nil;
  XCTAssertNil([restarted listWorkspaceMetadataWithError:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_CONFLICT");
  // The evidence is left exactly where it was.
  XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:staging.path]);
  XCTAssertTrue([NSFileManager.defaultManager
      fileExistsAtPath:journalURL.path]);
}

- (void)testRishOwnedCreateRegistryFailureRecoversAuthorityReadyPublication {
  NSURL *documents = [self documentsRootForRoot:self.rootURL];
  DSHLocalWorkspaceAccess *access =
      [self accessWithRoot:self.rootURL
          documentsRootURL:documents
                     fault:^BOOL(NSString *stage) {
                       return [stage isEqual:@"before_create_registry_publication"];
                     }
               UUIDGenerator:^NSString *{
                 return DSHWorkspaceA;
               }];
  NSError *error = nil;
  XCTAssertNil([access createRishOwnedWorkspaceWithDisplayName:@"Registry crash"
                                                    operationId:DSHOperationA
                                                          error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_PERSISTENCE");
  DSHLocalWorkspaceAccess *restarted =
      [self accessWithRoot:self.rootURL
          documentsRootURL:documents
                     fault:nil
               UUIDGenerator:^NSString *{
                 return DSHWorkspaceA;
               }];
  NSArray *listed = [restarted listWorkspaceMetadataWithError:&error];
  XCTAssertEqual(listed.count, 1u);
  XCTAssertEqualObjects(listed.firstObject[@"display_name"], @"Registry crash");
  XCTAssertEqualObjects([restarted queryOperationId:DSHOperationA
                                               error:&error][@"status"],
                        @"committed");
}

- (void)testRishOwnedCreateReceiptRecoveryIsIdempotentAcrossRelaunch {
  NSURL *documents = [self documentsRootForRoot:self.rootURL];
  DSHLocalWorkspaceAccess *access =
      [self accessWithRoot:self.rootURL
          documentsRootURL:documents
                     fault:^BOOL(NSString *stage) {
                       return [stage isEqual:@"after_create_registry_publication"];
                     }
               UUIDGenerator:^NSString *{
                 return DSHWorkspaceA;
               }];
  NSError *error = nil;
  XCTAssertNil([access createRishOwnedWorkspaceWithDisplayName:@"Retry"
                                                    operationId:DSHOperationA
                                                          error:&error]);
  DSHLocalWorkspaceAccess *restarted =
      [self accessWithRoot:self.rootURL
          documentsRootURL:documents
                     fault:nil
               UUIDGenerator:^NSString *{
                 return DSHWorkspaceB;
               }];
  NSArray *listed = [restarted listWorkspaceMetadataWithError:&error];
  XCTAssertEqual(listed.count, 1u);
  XCTAssertEqualObjects([restarted queryOperationId:DSHOperationA
                                               error:&error][@"status"],
                        @"committed");
  NSDictionary *retried =
      [restarted createRishOwnedWorkspaceWithDisplayName:@"Retry"
                                               operationId:DSHOperationA
                                                     error:&error];
  XCTAssertEqualObjects(retried, listed.firstObject);
  XCTAssertEqual([restarted listWorkspaceMetadataWithError:&error].count, 1u);
}

- (void)testRishOwnedCreateUsesRealDirectoryLinkSemanticsAndRecoversStaging {
  NSURL *documents = [self documentsRootForRoot:self.rootURL];
  DSHLocalWorkspaceAccess *access =
      [self accessWithRoot:self.rootURL
          documentsRootURL:documents
                     fault:^BOOL(NSString *stage) {
                       return [stage isEqual:@"create_after_staging_fsync"];
                     }
               UUIDGenerator:^NSString *{
                 return DSHWorkspaceA;
               }];
  NSError *error = nil;
  XCTAssertNil([access createRishOwnedWorkspaceWithDisplayName:@"Nlink"
                                                    operationId:DSHOperationA
                                                          error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_PERSISTENCE");

  NSURL *container = [self ownedWorkspacesRootForRoot:self.rootURL];
  NSURL *staging = [container URLByAppendingPathComponent:
      [@".rish-staging-" stringByAppendingString:DSHOperationA]
                                             isDirectory:YES];
  struct stat stagingState = {};
  XCTAssertEqual(lstat(staging.fileSystemRepresentation, &stagingState), 0);
  XCTAssertTrue(S_ISDIR(stagingState.st_mode));
  // APFS and other POSIX filesystems report an empty directory as at least
  // two links (self plus parent); one is never a valid directory invariant.
  XCTAssertGreaterThanOrEqual(stagingState.st_nlink, (nlink_t)2);

  DSHLocalWorkspaceAccess *restarted =
      [self accessWithRoot:self.rootURL
          documentsRootURL:documents
                     fault:nil
               UUIDGenerator:^NSString *{
                 return DSHWorkspaceA;
               }];
  XCTAssertEqual([restarted listWorkspaceMetadataWithError:&error].count, 0u);
  XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:staging.path]);
  XCTAssertEqualObjects([restarted queryOperationId:DSHOperationA
                                               error:&error][@"status"],
                        @"not_started");
}

- (void)testCreateRegistryCapacityRejectsBeforeDocumentsOrUUIDAllocation {
  NSURL *documents = [self documentsRootForRoot:self.rootURL];
  __block BOOL UUIDWasRequested = NO;
  DSHLocalWorkspaceAccess *access =
      [self accessWithRoot:self.rootURL
          documentsRootURL:documents
                     fault:nil
               UUIDGenerator:^NSString *{
                 UUIDWasRequested = YES;
                 return DSHWorkspaceA;
               }];
  NSError *error = nil;
  XCTAssertTrue([access ensurePrivateLayoutWithError:&error], @"%@", error);
  NSMutableArray *records = [NSMutableArray arrayWithCapacity:1024];
  for (NSUInteger index = 0; index < 1024; index++) {
    NSString *workspace = [NSString stringWithFormat:
        @"%08lx-0000-4000-8000-%012lx", (unsigned long)index,
        (unsigned long)index];
    [records addObject:[self recordForWorkspaceId:workspace
                                           origin:@"rish_created"
                                  rootLocatorKind:@"documents_owned"
                                    locationClass:@"rish_owned"
                              ownedDirectoryName:[NSString stringWithFormat:
                                                    @"Owned %04lu",
                                                    (unsigned long)index]
                                 legacyProjectId:nil
                                 bindingRevision:1]];
  }
  [self writeRegistryRecords:records generation:7 root:self.rootURL];
  NSData *before = [NSData dataWithContentsOfURL:
      [self registryURLForRoot:self.rootURL]];
  XCTAssertNil([access createRishOwnedWorkspaceWithDisplayName:@"Full"
                                                    operationId:DSHOperationA
                                                          error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_BUSY");
  XCTAssertFalse(UUIDWasRequested);
  XCTAssertFalse([NSFileManager.defaultManager
      fileExistsAtPath:documents.path]);
  XCTAssertEqualObjects([NSData dataWithContentsOfURL:
      [self registryURLForRoot:self.rootURL]], before);
  XCTAssertFalse([NSFileManager.defaultManager
      fileExistsAtPath:[self journalURLForRoot:self.rootURL].path]);
}

- (void)testPreparedCreateRecoveryPreservesExternalDestinationAndJournalEvidence {
  NSURL *documents = [self documentsRootForRoot:self.rootURL];
  DSHLocalWorkspaceAccess *access =
      [self accessWithRoot:self.rootURL
          documentsRootURL:documents
                     fault:nil
               UUIDGenerator:^NSString *{
                 return DSHWorkspaceA;
               }];
  NSError *error = nil;
  XCTAssertTrue([access ensurePrivateLayoutWithError:&error], @"%@", error);
  NSURL *container = [self ownedWorkspacesRootForRoot:self.rootURL];
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:container
                                           withIntermediateDirectories:YES
                                                            attributes:nil
                                                                 error:&error],
                @"%@", error);
  NSURL *destination = [container URLByAppendingPathComponent:@"Scratch"
                                                       isDirectory:YES];
  XCTAssertEqual(mkdir(destination.fileSystemRepresentation, 0755), 0);
  struct stat externalBefore = {};
  XCTAssertEqual(lstat(destination.fileSystemRepresentation, &externalBefore), 0);

  NSData *registryData =
      [NSData dataWithContentsOfURL:[self registryURLForRoot:self.rootURL]];
  NSDictionary *prepared = @{
    @"schema_version": @1,
    @"operation_id": DSHOperationA,
    @"workspace_id": DSHWorkspaceA,
    @"operation": @"create",
    @"phase": @"prepared",
    @"binding_revision": @1,
    @"previous_registry_generation": @0,
    @"previous_registry_sha256": [self sha256ForData:registryData],
    @"authority_sha256": NSNull.null,
    @"record_sha256": NSNull.null,
    @"staging_name": [@".rish-staging-" stringByAppendingString:DSHOperationA],
    @"destination_name": @"Scratch",
    @"display_name": @"Scratch",
    @"request_sha256": [self createRequestDigestForDisplayName:@"Scratch"],
    @"staging_device_id": NSNull.null,
    @"staging_inode_id": NSNull.null,
    @"staging_uid": NSNull.null,
    @"staging_gid": NSNull.null,
    @"destination_device_id": NSNull.null,
    @"destination_inode_id": NSNull.null,
    @"destination_uid": NSNull.null,
    @"destination_gid": NSNull.null,
    @"legacy_project_id": NSNull.null,
    @"clearance_receipt_id": NSNull.null,
    @"confirmation_id": NSNull.null,
    @"created_at": DSHTimestamp,
    @"last_opened_at": DSHTimestamp,
    @"updated_at": DSHTimestamp,
  };
  [self secureWriteObject:prepared toURL:[self journalURLForRoot:self.rootURL]];

  DSHLocalWorkspaceAccess *restarted =
      [self accessWithRoot:self.rootURL
          documentsRootURL:documents
                     fault:nil
               UUIDGenerator:^NSString *{
                 return DSHWorkspaceA;
               }];
  XCTAssertNil([restarted listWorkspaceMetadataWithError:&error]);
  BOOL failedClosed = [@[@"E_WORKSPACE_CONFLICT", @"E_WORKSPACE_PERSISTENCE"]
      containsObject:error.userInfo[@"code"]];
  XCTAssertTrue(failedClosed);
  struct stat externalAfter = {};
  XCTAssertEqual(lstat(destination.fileSystemRepresentation, &externalAfter), 0);
  XCTAssertEqual(externalBefore.st_dev, externalAfter.st_dev);
  XCTAssertEqual(externalBefore.st_ino, externalAfter.st_ino);
  XCTAssertEqual(externalBefore.st_uid, externalAfter.st_uid);
  XCTAssertEqual(externalBefore.st_gid, externalAfter.st_gid);
  XCTAssertTrue([NSFileManager.defaultManager
      fileExistsAtPath:[self journalURLForRoot:self.rootURL].path]);
}

- (void)testCreateReceiptBindsOperationIdToOriginalDisplayName {
  NSURL *documents = [self documentsRootForRoot:self.rootURL];
  DSHLocalWorkspaceAccess *access =
      [self accessWithRoot:self.rootURL
          documentsRootURL:documents
                     fault:nil
               UUIDGenerator:^NSString *{
                 return DSHWorkspaceA;
               }];
  NSError *error = nil;
  NSDictionary *first =
      [access createRishOwnedWorkspaceWithDisplayName:@"Scratch"
                                           operationId:DSHOperationA
                                                 error:&error];
  XCTAssertNotNil(first, @"%@", error);
  XCTAssertNil(error);
  XCTAssertEqualObjects(first[@"display_name"], @"Scratch");

  NSDictionary *retry =
      [access createRishOwnedWorkspaceWithDisplayName:@"Other"
                                           operationId:DSHOperationA
                                                 error:&error];
  XCTAssertNil(retry);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_CONFLICT");
  XCTAssertEqual([access listWorkspaceMetadataWithError:&error].count, 1u);
  XCTAssertEqualObjects([self recordForRoot:self.rootURL
                               workspaceId:DSHWorkspaceA][@"display_name"],
                        @"Scratch");
}

- (void)testCreateRecoveryKeepsOriginalDisplayNameWhenDirectoryGetsCollisionSuffix {
  NSURL *documents = [self documentsRootForRoot:self.rootURL];
  NSURL *container = [self ownedWorkspacesRootForRoot:self.rootURL];
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:container
                                           withIntermediateDirectories:YES
                                                            attributes:nil
                                                                 error:nil]);
  NSURL *preexisting = [container URLByAppendingPathComponent:@"Scratch"
                                                    isDirectory:YES];
  XCTAssertEqual(mkdir(preexisting.fileSystemRepresentation, 0700), 0);
  DSHLocalWorkspaceAccess *access =
      [self accessWithRoot:self.rootURL
          documentsRootURL:documents
          fault:^BOOL(NSString *stage) {
            return [stage isEqual:@"after_authority_ready"];
          }
          UUIDGenerator:^NSString *{
            return DSHWorkspaceA;
          }];
  NSError *error = nil;
  XCTAssertNil([access createRishOwnedWorkspaceWithDisplayName:@"Scratch"
                                                    operationId:DSHOperationA
                                                          error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_PERSISTENCE");
  // Recovery must reconstruct the original last_opened_at even when a
  // relaunch advances the journal's updated_at.
  NSMutableDictionary *journal = [[NSJSONSerialization
      JSONObjectWithData:[NSData dataWithContentsOfURL:
          [self journalURLForRoot:self.rootURL]]
                         options:0
                           error:nil] mutableCopy];
  journal[@"updated_at"] = @"2026-08-29T00:00:01.000Z";
  [self secureWriteObject:journal toURL:[self journalURLForRoot:self.rootURL]];
  self.now = [self.now dateByAddingTimeInterval:1];

  DSHLocalWorkspaceAccess *restarted =
      [self accessWithRoot:self.rootURL
          documentsRootURL:documents
                     fault:nil
               UUIDGenerator:^NSString *{
                 return DSHWorkspaceB;
               }];
  NSArray *listed = [restarted listWorkspaceMetadataWithError:&error];
  XCTAssertEqual(listed.count, 1u, @"%@", error);
  XCTAssertEqualObjects(listed.firstObject[@"display_name"], @"Scratch");
  XCTAssertEqualObjects([self recordForRoot:self.rootURL
                               workspaceId:DSHWorkspaceA][@"owned_directory_name"],
                        @"Scratch (1)");
  NSDictionary *retried =
      [restarted createRishOwnedWorkspaceWithDisplayName:@"Scratch"
                                               operationId:DSHOperationA
                                                     error:&error];
  XCTAssertEqualObjects(retried, listed.firstObject);
}

- (void)testCreateAuthorityReadyRecoveryPreflightsAllPublishedAuthorities {
  NSURL *documents = [self documentsRootForRoot:self.rootURL];
  DSHLocalWorkspaceAccess *bootstrapAccess =
      [self accessWithRoot:self.rootURL
          documentsRootURL:documents
                     fault:nil
               UUIDGenerator:^NSString *{
                 return DSHWorkspaceA;
               }];
  NSError *error = nil;
  XCTAssertNotNil([self bootstrapWithAccess:bootstrapAccess
                                operationId:DSHOperationA
                                      error:&error], @"%@", error);

  DSHLocalWorkspaceAccess *createAccess =
      [self accessWithRoot:self.rootURL
          documentsRootURL:documents
                     fault:^BOOL(NSString *stage) {
                       return [stage isEqual:@"after_authority_ready"];
                     }
               UUIDGenerator:^NSString *{
                 return DSHWorkspaceB;
               }];
  XCTAssertNil([createAccess createRishOwnedWorkspaceWithDisplayName:@"New"
                                                         operationId:DSHOperationB
                                                               error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_PERSISTENCE");

  NSURL *existingAuthority = [self authorityURLForRoot:self.rootURL
                                                  kind:@"legacy"
                                           workspaceId:DSHWorkspaceA
                                              revision:1];
  XCTAssertTrue([NSFileManager.defaultManager
      fileExistsAtPath:existingAuthority.path]);
  [self secureWriteObject:@{@"corrupt": @YES} toURL:existingAuthority];

  DSHLocalWorkspaceAccess *restarted =
      [self accessWithRoot:self.rootURL
          documentsRootURL:documents
                     fault:nil
               UUIDGenerator:^NSString *{
                 return DSHWorkspaceC;
               }];
  XCTAssertNil([restarted listWorkspaceMetadataWithError:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_PERSISTENCE");
  NSDictionary *registry = [self registryObjectForRoot:self.rootURL];
  XCTAssertEqual([registry[@"records"] count], 1u);
  XCTAssertNil([self recordForRoot:self.rootURL workspaceId:DSHWorkspaceB]);
  XCTAssertTrue([NSFileManager.defaultManager
      fileExistsAtPath:[self journalURLForRoot:self.rootURL].path]);
  XCTAssertTrue([NSFileManager.defaultManager
      fileExistsAtPath:[self authorityURLForRoot:self.rootURL
                                             kind:@"owned"
                                      workspaceId:DSHWorkspaceB
                                         revision:1].path]);
}

- (void)testLegacyAuthorityReadyRecoveryPreflightsAllPublishedAuthorities {
  NSURL *documents = [self documentsRootForRoot:self.rootURL];
  DSHLocalWorkspaceAccess *existing =
      [self accessWithRoot:self.rootURL
          documentsRootURL:documents
                     fault:nil
               UUIDGenerator:^NSString *{
                 return DSHWorkspaceA;
               }];
  NSError *error = nil;
  XCTAssertNotNil([existing bootstrapLegacyProjectId:DSHProjectA
                                           operationId:DSHOperationA
                                                 error:&error], @"%@", error);

  DSHLocalWorkspaceAccess *pending =
      [self accessWithRoot:self.rootURL
          documentsRootURL:documents
          fault:^BOOL(NSString *stage) {
            return [stage isEqual:@"after_authority_ready"];
          }
          UUIDGenerator:^NSString *{
            return DSHWorkspaceB;
          }];
  XCTAssertNil([pending bootstrapLegacyProjectId:DSHProjectWide
                                        operationId:DSHOperationB
                                              error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_PERSISTENCE");

  NSURL *existingAuthority = [self authorityURLForRoot:self.rootURL
                                                  kind:@"legacy"
                                           workspaceId:DSHWorkspaceA
                                              revision:1];
  [self secureWriteObject:@{@"corrupt": @YES} toURL:existingAuthority];

  DSHLocalWorkspaceAccess *restarted =
      [self accessWithRoot:self.rootURL
          documentsRootURL:documents
                     fault:nil
               UUIDGenerator:^NSString *{
                 return DSHWorkspaceC;
               }];
  XCTAssertNil([restarted listWorkspaceMetadataWithError:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_PERSISTENCE");
  NSDictionary *registry = [self registryObjectForRoot:self.rootURL];
  XCTAssertEqual([registry[@"records"] count], 1u);
  XCTAssertNil([self recordForRoot:self.rootURL workspaceId:DSHWorkspaceB]);
  XCTAssertTrue([NSFileManager.defaultManager
      fileExistsAtPath:[self journalURLForRoot:self.rootURL].path]);
  XCTAssertTrue([NSFileManager.defaultManager
      fileExistsAtPath:[self authorityURLForRoot:self.rootURL
                                             kind:@"legacy"
                                      workspaceId:DSHWorkspaceB
                                         revision:1].path]);
}

- (void)testLegacyRegistryCommittedRecoveryPreflightsAllPublishedAuthorities {
  NSURL *documents = [self documentsRootForRoot:self.rootURL];
  DSHLocalWorkspaceAccess *existing =
      [self accessWithRoot:self.rootURL
          documentsRootURL:documents
                     fault:nil
               UUIDGenerator:^NSString *{
                 return DSHWorkspaceA;
               }];
  NSError *error = nil;
  XCTAssertNotNil([existing bootstrapLegacyProjectId:DSHProjectA
                                           operationId:DSHOperationA
                                                 error:&error], @"%@", error);

  DSHLocalWorkspaceAccess *committed =
      [self accessWithRoot:self.rootURL
          documentsRootURL:documents
          fault:^BOOL(NSString *stage) {
            return [stage isEqual:@"after_registry_committed"];
          }
          UUIDGenerator:^NSString *{
            return DSHWorkspaceB;
          }];
  XCTAssertNil([committed bootstrapLegacyProjectId:DSHProjectWide
                                          operationId:DSHOperationB
                                                error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_PERSISTENCE");
  XCTAssertEqual([[[self registryObjectForRoot:self.rootURL]
      objectForKey:@"records"] count], 2u);

  NSURL *existingAuthority = [self authorityURLForRoot:self.rootURL
                                                  kind:@"legacy"
                                           workspaceId:DSHWorkspaceA
                                              revision:1];
  [self secureWriteObject:@{@"corrupt": @YES} toURL:existingAuthority];

  DSHLocalWorkspaceAccess *restarted =
      [self accessWithRoot:self.rootURL
          documentsRootURL:documents
                     fault:nil
               UUIDGenerator:^NSString *{
                 return DSHWorkspaceC;
               }];
  XCTAssertNil([restarted listWorkspaceMetadataWithError:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_PERSISTENCE");
  NSDictionary *registry = [self registryObjectForRoot:self.rootURL];
  XCTAssertEqual([registry[@"records"] count], 2u);
  XCTAssertNotNil([self recordForRoot:self.rootURL workspaceId:DSHWorkspaceB]);
  XCTAssertTrue([NSFileManager.defaultManager
      fileExistsAtPath:[self journalURLForRoot:self.rootURL].path]);
  NSDictionary *receipts = [NSJSONSerialization
      JSONObjectWithData:[NSData dataWithContentsOfURL:
          [self receiptsURLForRoot:self.rootURL]]
                 options:0
                   error:nil];
  for (NSDictionary *receipt in receipts[@"receipts"]) {
    XCTAssertFalse([receipt[@"operation_id"] isEqual:DSHOperationB]);
  }
}

- (void)testWorkspaceBridgeRejectsBooleanSchemaWithoutPersisting {
  NSArray<NSString *> *operations = @[@"create", @"resolve", @"query"];
  for (NSString *operation in operations) {
    NSURL *root = [self.rootURL URLByAppendingPathComponent:operation
                                                  isDirectory:YES];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:root
                                           withIntermediateDirectories:YES
                                                            attributes:nil
                                                                 error:nil]);
    DSHLocalWorkspaceAccess *access = [self accessWithRoot:root
                                                     fault:nil];
    id<DSHLocalWorkspacesModuleTesting> module =
        [self workspaceModuleWithAccess:access];
    XCTestExpectation *rejected =
        [self expectationWithDescription:[operation stringByAppendingString:@" boolean schema"]];
    DSHLWResolve resolve = ^(__unused id value) {
      XCTFail(@"%@ must reject boolean schema", operation);
      [rejected fulfill];
    };
    DSHLWReject reject = ^(NSString *code, __unused NSString *message,
                           NSError *nativeError) {
      XCTAssertEqualObjects(code, @"E_WORKSPACE_INVALID");
      XCTAssertNil(nativeError);
      [rejected fulfill];
    };
    if ([operation isEqual:@"create"]) {
      [module createWorkspaceRequest:@{
        @"schema_version": @YES,
        @"display_name": @"Boolean schema",
        @"operation_id": DSHOperationA,
      } resolver:resolve rejecter:reject];
    } else if ([operation isEqual:@"resolve"]) {
      [module resolveWorkspaceRequest:@{
        @"schema_version": @YES,
        @"workspace_id": DSHWorkspaceA,
        @"expected_binding_revision": NSNull.null,
        @"required_capabilities": @[],
      } resolver:resolve rejecter:reject];
    } else {
      [module queryOperationRequest:@{
        @"schema_version": @YES,
        @"operation_id": DSHOperationA,
      } resolver:resolve rejecter:reject];
    }
    [self waitForExpectations:@[rejected] timeout:1];
    XCTAssertFalse([NSFileManager.defaultManager
        fileExistsAtPath:[root URLByAppendingPathComponent:@"local-workspaces"
                                              isDirectory:YES].path]);
    XCTAssertFalse([NSFileManager.defaultManager
        fileExistsAtPath:[self documentsRootForRoot:root].path]);
  }
}

- (void)testPrivateRegistryRejectsBooleanSchemaVersion {
  DSHLocalWorkspaceAccess *access = [self access];
  NSError *error = nil;
  XCTAssertTrue([access ensurePrivateLayoutWithError:&error], @"%@", error);
  [self secureWriteObject:@{
    @"schema_version": @YES,
    @"generation": @0,
    @"records": @[],
  } toURL:[self registryURLForRoot:self.rootURL]];
  XCTAssertNil([access listWorkspaceMetadataWithError:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_PERSISTENCE");
}

- (void)testA1BootstrapReceiptWithoutRequestDigestRemainsQueryableAndRetryable {
  DSHLocalWorkspaceAccess *access = [self access];
  NSDictionary *first = [self bootstrapWithAccess:access
                                       operationId:DSHOperationA
                                             error:nil];
  XCTAssertNotNil(first);
  NSMutableDictionary *envelope = [[NSJSONSerialization
      JSONObjectWithData:[NSData dataWithContentsOfURL:
          [self receiptsURLForRoot:self.rootURL]]
                         options:0
                           error:nil] mutableCopy];
  NSMutableDictionary *oldReceipt =
      [((NSArray *)envelope[@"receipts"]).firstObject mutableCopy];
  [oldReceipt removeObjectForKey:@"request_sha256"];
  envelope[@"receipts"] = @[oldReceipt];
  [self secureWriteObject:envelope toURL:[self receiptsURLForRoot:self.rootURL]];

  DSHLocalWorkspaceAccess *restarted = [self access];
  NSDictionary *query = [restarted queryOperationId:DSHOperationA error:nil];
  XCTAssertEqualObjects(query[@"status"], @"committed");
  XCTAssertNil(query[@"receipt"][@"request_sha256"]);
  NSDictionary *retried = [self bootstrapWithAccess:restarted
                                         operationId:DSHOperationA
                                               error:nil];
  XCTAssertEqualObjects(retried, first);
}

- (void)testA1BootstrapJournalWithoutBFieldsRecoversAndKeepsReceiptReadable {
  DSHLocalWorkspaceAccess *access = [self accessWithRoot:self.rootURL
      fault:^BOOL(NSString *stage) {
        return [stage isEqual:@"after_authority_ready"];
      }];
  NSError *error = nil;
  XCTAssertNil([self bootstrapWithAccess:access
                              operationId:DSHOperationA
                                    error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_PERSISTENCE");

  NSMutableDictionary *oldJournal = [[NSJSONSerialization
      JSONObjectWithData:[NSData dataWithContentsOfURL:
          [self journalURLForRoot:self.rootURL]]
                         options:0
                           error:nil] mutableCopy];
  for (NSString *key in @[
    @"display_name", @"request_sha256", @"last_opened_at",
    @"staging_device_id", @"staging_inode_id", @"staging_uid", @"staging_gid",
    @"destination_device_id", @"destination_inode_id", @"destination_uid",
    @"destination_gid",
  ]) {
    [oldJournal removeObjectForKey:key];
  }
  [self secureWriteObject:oldJournal
                    toURL:[self journalURLForRoot:self.rootURL]];

  DSHLocalWorkspaceAccess *restarted = [self access];
  NSArray *listed = [restarted listWorkspaceMetadataWithError:&error];
  XCTAssertEqual(listed.count, 1u, @"%@", error);
  XCTAssertFalse([NSFileManager.defaultManager
      fileExistsAtPath:[self journalURLForRoot:self.rootURL].path]);
  NSDictionary *query = [restarted queryOperationId:DSHOperationA error:&error];
  XCTAssertEqualObjects(query[@"status"], @"committed");
  XCTAssertNil(query[@"receipt"][@"request_sha256"]);
  XCTAssertNotNil([self bootstrapWithAccess:restarted
                                operationId:DSHOperationA
                                      error:&error]);
}

- (void)testInfoPlistEnablesFilesVisibilityKeys {
  // Read the host app bundle rather than the source tree: the source path is
  // only reachable on the build machine, so a source-tree read passes on the
  // simulator even when the keys never reached the built app, and fails on a
  // device for a reason that says nothing about the product.
  NSDictionary *info = NSBundle.mainBundle.infoDictionary;
  XCTAssertEqualObjects(info[@"UIFileSharingEnabled"], @YES);
  XCTAssertEqualObjects(info[@"LSSupportsOpeningDocumentsInPlace"], @YES);
}

- (void)testForgetAndDeleteRemainFailClosedWithoutCommittedClearanceReceipt {
  DSHLocalWorkspaceAccess *access = [self access];
  NSError *error = nil;
  XCTAssertNil([access forgetWorkspaceId:DSHWorkspaceA
                expectedBindingRevision:@1
                              operationId:DSHOperationA
                        clearanceReceiptId:DSHOperationB
                                   error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_UNAVAILABLE");
  error = nil;
  XCTAssertNil([access prepareDeleteOwnedContentForWorkspaceId:DSHWorkspaceA
                                       expectedBindingRevision:@1
                                           clearanceReceiptId:DSHOperationB
                                                        error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_UNAVAILABLE");
  error = nil;
  XCTAssertNil([access deleteOwnedContentForWorkspaceId:DSHWorkspaceA
                                expectedBindingRevision:@1
                                              operationId:DSHOperationA
                                        clearanceReceiptId:DSHOperationB
                                           confirmationId:DSHOperationA
                                                     error:&error]);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_WORKSPACE_UNAVAILABLE");
}

@end
