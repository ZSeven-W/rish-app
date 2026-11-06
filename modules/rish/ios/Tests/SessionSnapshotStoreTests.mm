#import "../../../../modules/rish/ios/Sources/ProviderConfiguration.h"
#import <XCTest/XCTest.h>

#import "DSHTestHost.h"

#import "../../../../modules/rish/ios/Sources/DSHWorkspaceCanonical.h"
#import "../../../../modules/rish/ios/Sources/LocalProjectAccess.h"
#import "../../../../modules/rish/ios/Sources/LocalWorkspaceAccess.h"
#import "../../../../modules/rish/ios/Sources/SessionSnapshotStore.h"
#import "../../../../modules/rish/ios/Sources/WorkspaceClearanceStore.h"

#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <string.h>
#include <unistd.h>

@interface LocalProjectsModule : NSObject
@end

@interface LocalProjectsModule (ClearanceRaceTesting)
- (nullable NSDictionary *)v2AttachWorkspaceProject:(NSDictionary *)request
                                               error:(NSError **)error;
@end

@interface DSHSessionSnapshotStore (MetadataHardeningTesting)
- (BOOL)requiresSessionResourceMetadata;
- (id)sessionProtectionPolicyValue;
- (NSFileManager *)sessionFileManager;
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
- (BOOL)ensurePrivateRoot:(NSError **)error;
- (BOOL)validateProtectedFileWithIdentity:(const struct stat *)expected
                                     error:(NSError **)error;
- (BOOL)hardenLegacyFileWithIdentity:(const struct stat *)expected
                                error:(NSError **)error;
- (BOOL)hardenPinnedDescriptor:(int)descriptor
                         atURL:(NSURL *)url
                     directory:(BOOL)directory
                 excludeBackup:(BOOL)excludeBackup
                         error:(NSError **)error;
- (int)acquireCASLock:(NSError **)error;
@end

// Forward to the real filesystem while recording which Foundation API the
// production protection helpers use. The metadata fake below only tests the
// surrounding guards and cannot catch an unsupported NSURL resource setter.
@interface DSHSessionTrackingFileManager : NSFileManager
@property(nonatomic, copy) NSDictionary *lastWrittenAttributes;
@property(nonatomic, copy) NSString *lastWritePath;
@property(nonatomic, copy) NSString *lastReadPath;
@end

@implementation DSHSessionTrackingFileManager
- (BOOL)setAttributes:(NSDictionary<NSFileAttributeKey, id> *)attributes
         ofItemAtPath:(NSString *)path
                error:(NSError **)error {
  self.lastWrittenAttributes = attributes;
  self.lastWritePath = path;
  return [super setAttributes:attributes ofItemAtPath:path error:error];
}
- (NSDictionary<NSFileAttributeKey, id> *)attributesOfItemAtPath:(NSString *)path
                                                       error:(NSError **)error {
  self.lastReadPath = path;
  return [super attributesOfItemAtPath:path error:error];
}
@end

@interface DSHSessionFileAttributesTestStore : DSHSessionSnapshotStore
@property(nonatomic, strong) DSHSessionTrackingFileManager *trackingFileManager;
@end

@implementation DSHSessionFileAttributesTestStore
- (NSFileManager *)sessionFileManager {
  return self.trackingFileManager;
}
@end

@interface DSHSessionMetadataTestStore : DSHSessionSnapshotStore
@property(nonatomic, strong) NSMutableDictionary<NSString *, id> *protections;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *backups;
@property(nonatomic) BOOL swapSessionDuringProtection;
@property(nonatomic) BOOL loseSessionProtectionReadback;
@property(nonatomic) BOOL preserveOldSessionProtection;
@property(nonatomic) BOOL observedLockHeldDuringMetadata;
@property(nonatomic) BOOL didSwapSession;
@end

@implementation DSHSessionMetadataTestStore

- (instancetype)initWithRootURL:(NSURL *)rootURL
                      sessionURL:(NSURL *)sessionURL
                launchInstanceId:(NSString *)launchInstanceId
                      coordinator:(DSHSessionWorkspaceCoordinator *)coordinator
                        faultHook:(DSHSessionSnapshotStoreFaultHook)faultHook {
  self = [super initWithRootURL:rootURL
                     sessionURL:sessionURL
               launchInstanceId:launchInstanceId
                     coordinator:coordinator
                       faultHook:faultHook];
  if (self != nil) {
    _protections = [NSMutableDictionary dictionary];
    _backups = [NSMutableDictionary dictionary];
  }
  return self;
}

- (BOOL)requiresSessionResourceMetadata {
  return YES;
}

- (BOOL)setSessionProtectionValue:(id)value
                            atURL:(NSURL *)url
                            error:(NSError **)error {
  if ([url.lastPathComponent isEqualToString:@".sessions.cas-lock"]) {
    int competing = open(url.fileSystemRepresentation,
                         O_RDWR | O_CLOEXEC | O_NOFOLLOW);
    if (competing >= 0) {
      int result = flock(competing, LOCK_EX | LOCK_NB);
      self.observedLockHeldDuringMetadata =
          result != 0 && (errno == EWOULDBLOCK || errno == EAGAIN);
      if (result == 0) flock(competing, LOCK_UN);
      close(competing);
    }
  }
  if (self.swapSessionDuringProtection && !self.didSwapSession &&
      [url.lastPathComponent isEqualToString:@"sessions.json"]) {
    NSData *bytes = [NSData dataWithContentsOfURL:url];
    if (bytes == nil ||
        ![NSFileManager.defaultManager removeItemAtURL:url error:error] ||
        ![bytes writeToURL:url options:0 error:error] ||
        ![NSFileManager.defaultManager
            setAttributes:@{ NSFilePosixPermissions : @0600 }
             ofItemAtPath:url.path
                    error:error]) {
      return NO;
    }
    self.didSwapSession = YES;
  }
  if (!(self.preserveOldSessionProtection &&
        [url.lastPathComponent isEqualToString:@"sessions.json"])) {
    self.protections[url.path] = value;
  }
  return YES;
}

- (BOOL)setSessionBackupExcluded:(BOOL)excluded
                           atURL:(NSURL *)url
                           error:(NSError **)error {
  (void)error;
  self.backups[url.path] = @(excluded);
  return YES;
}

- (BOOL)getSessionProtectionAtURL:(NSURL *)url
                            value:(id *)value
                            error:(NSError **)error {
  (void)error;
  if (value != nullptr) {
    *value = self.loseSessionProtectionReadback &&
            [url.lastPathComponent isEqualToString:@"sessions.json"]
        ? nil
        : self.protections[url.path];
  }
  return YES;
}

- (BOOL)getSessionBackupExcludedAtURL:(NSURL *)url
                                value:(NSNumber **)value
                                error:(NSError **)error {
  (void)error;
  if (value != nullptr) *value = self.backups[url.path];
  return YES;
}

@end

@interface SessionSnapshotStoreTests : XCTestCase
@property(nonatomic, strong) NSURL *rootURL;
@property(nonatomic, strong) DSHSessionSnapshotStore *store;
@end

@implementation SessionSnapshotStoreTests

static NSString *const DSHSessionTestLaunch =
    @"11111111-1111-4111-8111-111111111111";
static NSString *const DSHSessionTestOperationA =
    @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
static NSString *const DSHSessionTestOperationB =
    @"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";

- (void)setUp {
  [super setUp];
  NSString *name = [NSString stringWithFormat:@"rish-session-%@",
                    NSUUID.UUID.UUIDString.lowercaseString];
  NSURL *requestedRoot = [NSURL fileURLWithPath:
      [NSTemporaryDirectory() stringByAppendingPathComponent:name]
                                    isDirectory:YES];
  // Manual legacy/downgrade fixtures write directly to sessions.json. Create
  // the root before the store so those writes model a real private
  // Application Support directory instead of silently failing on a
  // nonexistent parent. Production hands the store a standardized root
  // (URLForDirectory: never spells "/private"); NSTemporaryDirectory() on a
  // physical device does, so standardize once here and use that single
  // spelling for the store, the metadata mocks and every path assertion.
  NSError *setupError = nil;
  XCTAssertTrue([NSFileManager.defaultManager
      createDirectoryAtURL:requestedRoot
      withIntermediateDirectories:YES
      attributes:@{ NSFilePosixPermissions : @0700 }
      error:&setupError]);
  XCTAssertNil(setupError);
  self.rootURL = [NSURL fileURLWithPath:requestedRoot.path.stringByStandardizingPath
                            isDirectory:YES];
  self.store = [[DSHSessionSnapshotStore alloc]
      initWithRootURL:self.rootURL
           sessionURL:[self.rootURL URLByAppendingPathComponent:@"sessions.json"]
     launchInstanceId:DSHSessionTestLaunch
           coordinator:nil
             faultHook:nil];
  XCTAssertNotNil(self.store);
  NSDictionary *initial = [self.store loadSessionSnapshotWithError:&setupError];
  XCTAssertNotNil(initial);
  XCTAssertEqualObjects(initial[@"status"], @"missing");
  XCTAssertNil(setupError);
}

- (void)tearDown {
  [NSFileManager.defaultManager removeItemAtURL:self.rootURL error:nil];
  [super tearDown];
}

- (DSHLocalWorkspaceAccess *)installDocumentsClearanceWorkspace {
  NSString *workspaceId = @"44444444-4444-4444-8444-444444444444";
  NSURL *documents = [self.rootURL
      URLByAppendingPathComponent:@"clearance-documents" isDirectory:YES];
  DSHLocalWorkspaceAccess *access = [[DSHLocalWorkspaceAccess alloc]
      initWithPrivateRootURL:self.rootURL
            documentsRootURL:documents
                         clock:^NSDate * { return NSDate.date; }
                 UUIDGenerator:^NSString * { return workspaceId; }
                legacyResolver:^BOOL(__unused NSString *projectId,
                                      NSDictionary **evidence,
                                      NSError **innerError) {
                  if (evidence != nil) *evidence = nil;
                  if (innerError != nil) *innerError = nil;
                  return NO;
                }
                     faultHook:nil];
  NSError *error = nil;
  XCTAssertTrue([access ensurePrivateLayoutWithError:&error], @"%@", error);
  NSDictionary *workspace = [access
      createRishOwnedWorkspaceWithDisplayName:@"Clearance Workspace"
                                  operationId:
                                      @"78787878-7878-4787-8787-787878787878"
                                        error:&error];
  XCTAssertNotNil(workspace, @"%@", error);
  [self.store setValue:access forKey:@"clearanceWorkspaceAccess"];
  return access;
}

- (DSHLocalWorkspaceAccess *)installLegacyClearanceWorkspace {
  NSString *workspaceId = @"44444444-4444-4444-8444-444444444444";
  NSString *digest =
      @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  NSString *legacyProject = @"67676767-6767-4767-8767-676767676767";
  DSHLocalWorkspaceAccess *access = [[DSHLocalWorkspaceAccess alloc]
      initWithPrivateRootURL:self.rootURL
            documentsRootURL:nil
                         clock:^NSDate * { return NSDate.date; }
                 UUIDGenerator:^NSString * { return workspaceId; }
                legacyResolver:^BOOL(NSString *projectId,
                                      NSDictionary **evidence,
                                      NSError **innerError) {
                  if (![projectId isEqual:legacyProject]) return NO;
                  if (evidence != nil) {
                    *evidence = @{
                      @"project_id" : projectId,
                      @"display_name" : @"Legacy Clearance",
                      @"metadata_sha256" : digest,
                      @"capabilities" : [NSSet setWithObjects:
                          @"read", @"write", @"git", @"project_context", nil],
                      @"projects_root_device_id" : @"42",
                      @"projects_root_inode_id" : @"84",
                      @"repository_device_id" : @"7",
                      @"repository_inode_id" : @"9",
                      @"git_device_id" : @"11",
                      @"git_inode_id" : @"13",
                    };
                  }
                  if (innerError != nil) *innerError = nil;
                  return YES;
                }
                     faultHook:nil];
  NSError *error = nil;
  XCTAssertNotNil([access bootstrapLegacyProjectId:legacyProject
                                         operationId:
                                             @"79797979-7979-4797-8797-797979797979"
                                               error:&error], @"%@", error);
  [self.store setValue:access forKey:@"clearanceWorkspaceAccess"];
  return access;
}

- (NSDictionary *)preferences {
  return @{
    @"schema_version" : @1,
    @"theme_mode" : @"system",
    @"locale" : @"en-US",
    @"default_model" : @"deepseek-v4-flash",
    @"selected_harness_id" : @"dsh",
    @"thinking_mode" : @"off",
    @"tool_permission" : @"read-only",
    @"show_reasoning" : @NO,
    @"auto_expand_tools" : @NO,
    @"confirm_destructive_file_actions" : @YES,
    @"git_https_proxy_url" : NSNull.null,
  };
}

- (NSDictionary *)candidate:(NSUInteger)marker {
  NSString *messageText = [NSString stringWithFormat:@"hello-%lu",
                           (unsigned long)marker];
  NSDictionary *message = @{
    @"id" : @"message-1",
    @"role" : @"user",
    @"text" : messageText,
    @"created_at" : @"2026-08-30T00:00:00.000Z",
    @"attachments" : @[],
  };
  NSDictionary *conversation = @{
    @"id" : @"chat-a",
    @"project_id" : NSNull.null,
    @"workspace_id" : NSNull.null,
    @"runtime_context_id" : NSNull.null,
    @"project_context" : NSNull.null,
    @"workspace_binding" : NSNull.null,
    @"workspace_bootstrap_state" : @"none",
    @"title" : @"New chat",
    @"title_source" : @"auto",
    @"model_id" : @"deepseek-v4-flash",
    @"thinking_mode" : @"off",
    @"messages" : @[message],
    @"turns" : @[],
    @"attempts" : @[],
    @"created_at" : @"2026-08-30T00:00:00.000Z",
    @"updated_at" : @"2026-08-30T00:00:00.000Z",
    @"agent_grants" : @[],
  };
  return @{
    @"schema_version" : @9,
    @"workspace_authority_outbox" : @[@{
      @"schema_version" : @1,
      @"operation_id" : @"33333333-3333-4333-8333-333333333333",
      @"action" : @"forget",
      @"workspace_id" : @"44444444-4444-4444-8444-444444444444",
      @"binding_revision" : @1,
      @"clearance_receipt_id" : @"55555555-5555-4555-8555-555555555555",
      @"created_at" : @"2026-08-30T00:00:00.000Z",
    }],
    @"agent_transcript_cleanup_outbox" : @[],
    @"project_context_destructive_epoch" : @0,
    @"project_context_destructive_transition" : NSNull.null,
    @"active_conversation_id" : @"chat-a",
    @"conversations" : @[conversation],
    @"messages" : @[message],
    @"session_events" : @[],
    @"preferences" : [self preferences],
  };
}

- (NSDictionary *)candidateWithAgentToolEvent {
  NSMutableDictionary *root = [[self candidate:1] mutableCopy];
  root[@"workspace_authority_outbox"] = @[];
  NSMutableDictionary *conversation =
      [root[@"conversations"][0] mutableCopy];
  NSString *workspaceId = @"44444444-4444-4444-8444-444444444444";
  NSString *turnId = @"11111111-1111-4111-8111-111111111111";
  NSString *attemptId = @"22222222-2222-4222-8222-222222222222";
  NSString *transcriptRef = @"33333333-3333-4333-8333-333333333333";
  NSDictionary *turn = @{
    @"schema_version" : @1,
    @"turn_id" : turnId,
    @"user_message_id" : @"message-1",
    @"attempt_ids" : @[ attemptId ],
    @"created_at" : @"2026-08-30T00:00:00.000Z",
  };
  NSDictionary *call = @{
    @"schema_version" : @3,
    @"call_id" : @"call-1",
    @"call_index" : @0,
    @"name" : @"list_dir",
    @"arguments_sha256" :
        @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    @"safe_summary_key" : @"agent.list_dir",
    @"access" : @"auto",
    @"approval_token" : NSNull.null,
    @"approval_decision" : @"pending",
    @"approval_reference" : NSNull.null,
    @"idempotency_key" :
        @"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    @"native_row_revision" : NSNull.null,
    @"receipt" : NSNull.null,
  };
  NSDictionary *journal = @{
    @"schema_version" : @3,
    @"phase" : @"batch_frozen",
    @"controller_generation" : @0,
    @"policy" : @{
      @"schema_version" : @1,
      @"policy_version" : @"agent-v1",
      @"max_single_write_bytes" : @32768,
      @"max_batch_write_bytes" : @(512 * 1024),
      @"max_attempt_write_bytes" : @(4 * 1024 * 1024),
    },
    @"root" : @{
      @"schema_version" : @1,
      @"kind" : @"workspace",
      @"workspace_id" : workspaceId,
      @"workspace_binding_revision" : @1,
      @"project_id" : NSNull.null,
      @"root_fingerprint_sha256" :
          @"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
      @"capabilities" : @[ @"file_read" ],
    },
    @"tool_registry_version" : @1,
    @"toolset_sha256" :
        @"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    @"transcript" : @{
      @"schema_version" : @1,
      @"transcript_ref" : transcriptRef,
      @"generation" : @0,
      @"transcript_sha256" :
          @"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
      @"transcript_bytes" : @0,
    },
    @"round_index" : @0,
    @"round_lineage" : @{
      @"schema_version" : @2,
      @"round_id" : @"55555555-5555-4555-8555-555555555555",
      @"round_index" : @0,
      @"launch_attempt" : @1,
      @"status" : @"completed",
      @"native_row_revision" : NSNull.null,
    },
    @"call_index" : @0,
    @"batch" : @[ call ],
    @"frozen_grant_ids" : @[],
    @"reserved_write_bytes" : @0,
    @"updated_at" : @"2026-08-30T00:00:00.000Z",
  };
  NSDictionary *attempt = @{
    @"schema_version" : @3,
    @"attempt_id" : attemptId,
    @"turn_id" : turnId,
    @"status" : @"prepared",
    @"visible_message_ids" : @[ @"message-1" ],
    @"visible_history_sha256" : NSNull.null,
    @"attachment_ids" : @[],
    @"model_id" : @"deepseek-v4-flash",
    @"thinking_mode" : @"off",
    @"context_disposition" : @"unbound",
    @"context_project_id" : NSNull.null,
    @"workspace_id" : workspaceId,
    @"workspace_binding_revision" : @1,
    @"project_context" : NSNull.null,
    @"active_round" : NSNull.null,
    @"rounds" : @[],
    @"assistant_message_id" : NSNull.null,
    @"failure_code" : NSNull.null,
    @"created_at" : @"2026-08-30T00:00:00.000Z",
    @"updated_at" : @"2026-08-30T00:00:00.000Z",
    @"journal_revision" : @1,
    @"agent" : journal,
  };
  conversation[@"workspace_id"] = workspaceId;
  conversation[@"workspace_binding"] = @{
    @"schema_version" : @1,
    @"workspace_id" : workspaceId,
    @"binding_revision" : @1,
    @"project_id" : NSNull.null,
  };
  conversation[@"turns"] = @[ turn ];
  conversation[@"attempts"] = @[ attempt ];
  root[@"conversations"] = @[ conversation ];
  root[@"session_events"] = @[@{
    @"schema_version" : @2,
    @"event_id" : @"66666666-6666-4666-8666-666666666666",
    @"attempt_id" : attemptId,
    @"seq" : @0,
    @"kind" : @"tool_call",
    @"round_index" : @0,
    @"call_id" : @"call-1",
    @"status" : @"waiting",
    @"safe_summary_key" : @"agent.list_dir",
    @"arguments_sha256" :
        @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    @"result_sha256" : NSNull.null,
    @"approval_reference" : NSNull.null,
    @"failure_code" : NSNull.null,
    @"created_at" : @"2026-08-30T00:00:00.000Z",
  }];
  return root;
}

- (NSDictionary *)visibleHistoryCandidateWithAgent:(BOOL)agent
                                     completedRound:(BOOL)completedRound {
  NSMutableDictionary *root = [[self candidateWithAgentToolEvent] mutableCopy];
  NSMutableDictionary *conversation = [root[@"conversations"][0] mutableCopy];
  NSMutableDictionary *attempt = [conversation[@"attempts"][0] mutableCopy];
  NSMutableDictionary *journal = [attempt[@"agent"] mutableCopy];
  NSString *controllerDigest =
      @"1111111111111111111111111111111111111111111111111111111111111111";
  NSString *providerDigest =
      @"2222222222222222222222222222222222222222222222222222222222222222";
  attempt[@"visible_history_sha256"] = controllerDigest;
  if (completedRound) {
    NSString *roundID = journal[@"round_lineage"][@"round_id"];
    attempt[@"rounds"] = @[@{
      @"schema_version" : @1,
      @"transport_schema_version" : @2,
      @"turn_id" : attempt[@"turn_id"],
      @"attempt_id" : attempt[@"attempt_id"],
      @"round_id" : roundID,
      @"round_index" : @0,
      @"provider_request_id" : @"77777777-7777-4777-8777-777777777777",
      @"provider_response_id" : @"provider-response-1",
      @"requested_model" : @"deepseek-v4-flash",
      @"model" : @"deepseek-v4-flash",
      @"thinking_mode" : @"off",
      @"finish_reason" : @"tool_calls",
      @"latency_ms" : @1,
      @"visible_history_sha256" : providerDigest,
      @"model_input_sha256" :
          @"3333333333333333333333333333333333333333333333333333333333333333",
      @"request_body_sha256" :
          @"4444444444444444444444444444444444444444444444444444444444444444",
      @"project_context_receipt" : NSNull.null,
    }];
    NSMutableDictionary *lineage = [journal[@"round_lineage"] mutableCopy];
    lineage[@"native_row_revision"] = @3;
    journal[@"round_lineage"] = lineage;
  }
  if (agent) {
    attempt[@"agent"] = journal;
  } else {
    attempt[@"agent"] = NSNull.null;
    attempt[@"journal_revision"] = @0;
    root[@"session_events"] = @[];
  }
  conversation[@"attempts"] = @[ attempt ];
  root[@"conversations"] = @[ conversation ];
  return root;
}

- (NSDictionary *)candidateWithAgentCancelEvents {
  NSMutableDictionary *root = [[self candidateWithAgentToolEvent] mutableCopy];
  NSMutableDictionary *conversation = [root[@"conversations"][0] mutableCopy];
  NSMutableDictionary *attempt = [conversation[@"attempts"][0] mutableCopy];
  NSMutableDictionary *journal = [attempt[@"agent"] mutableCopy];
  journal[@"phase"] = @"execution_intent";
  attempt[@"agent"] = journal;
  conversation[@"attempts"] = @[ attempt ];
  root[@"conversations"] = @[ conversation ];
  NSString *attemptID = attempt[@"attempt_id"];
  NSString *argumentsSHA =
      @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  root[@"session_events"] = @[
    @{
      @"schema_version" : @2,
      @"event_id" : @"77777777-7777-4777-8777-777777777777",
      @"attempt_id" : attemptID,
      @"seq" : @0,
      @"kind" : @"cancel",
      @"round_index" : NSNull.null,
      @"call_id" : NSNull.null,
      @"status" : @"cancelled",
      @"safe_summary_key" : NSNull.null,
      @"arguments_sha256" : NSNull.null,
      @"result_sha256" : NSNull.null,
      @"approval_reference" : @"77777777-7777-4777-8777-777777777777",
      @"failure_code" : @"E_AGENT_CANCELLED",
      @"created_at" : @"2026-08-30T00:00:00.000Z",
    },
    @{
      @"schema_version" : @2,
      @"event_id" : @"88888888-8888-4888-8888-888888888888",
      @"attempt_id" : attemptID,
      @"seq" : @1,
      @"kind" : @"cancel",
      @"round_index" : @0,
      @"call_id" : NSNull.null,
      @"status" : @"cancelled",
      @"safe_summary_key" : NSNull.null,
      @"arguments_sha256" : NSNull.null,
      @"result_sha256" : NSNull.null,
      @"approval_reference" : @"88888888-8888-4888-8888-888888888888",
      @"failure_code" : @"E_AGENT_ROOT_STALE",
      @"created_at" : @"2026-08-30T00:00:00.000Z",
    },
    @{
      @"schema_version" : @2,
      @"event_id" : @"99999999-9999-4999-8999-999999999999",
      @"attempt_id" : attemptID,
      @"seq" : @2,
      @"kind" : @"cancel",
      @"round_index" : @0,
      @"call_id" : @"call-1",
      @"status" : @"cancelled",
      @"safe_summary_key" : NSNull.null,
      @"arguments_sha256" : argumentsSHA,
      @"result_sha256" : NSNull.null,
      @"approval_reference" : @"99999999-9999-4999-8999-999999999999",
      @"failure_code" : @"E_AGENT_PERSISTENCE",
      @"created_at" : @"2026-08-30T00:00:00.000Z",
    },
  ];
  return root;
}

- (NSDictionary *)candidateWithAgentTranscriptCleanup {
  NSMutableDictionary *root = [[self candidateWithAgentToolEvent] mutableCopy];
  root[@"agent_transcript_cleanup_outbox"] = @[@{
    @"schema_version" : @1,
    @"cleanup_id" : @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    @"conversation_id" : @"chat-a",
    @"task_id" : @"11111111-1111-4111-8111-111111111111",
    @"attempt_id" : @"22222222-2222-4222-8222-222222222222",
    @"transcript_ref" : @"33333333-3333-4333-8333-333333333333",
    @"transcript_sha256" :
        @"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
    @"reason" : @"completed",
    @"created_at" : @"2026-08-30T00:00:00.000Z",
  }];
  return root;
}

- (NSString *)jsonForCandidate:(NSDictionary *)candidate {
  NSError *error = nil;
  NSData *data = DSHWorkspaceCanonicalJSONData(candidate, &error);
  XCTAssertNotNil(data);
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

- (NSDictionary *)sharedFixtureNamed:(NSString *)name {
  NSURL *url = [[NSBundle bundleForClass:self.class]
      URLForResource:name withExtension:@"json"];
  XCTAssertNotNil(url);
  if (url == nil) return nil;
  NSError *error = nil;
  NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&error];
  XCTAssertNotNil(data);
  XCTAssertNil(error);
  id value = data == nil ? nil
      : [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
  XCTAssertTrue([value isKindOfClass:NSDictionary.class]);
  XCTAssertNil(error);
  return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

- (NSMutableDictionary *)mutableJSONCopyOfDictionary:(NSDictionary *)source {
  NSError *error = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:source
                                                 options:0
                                                   error:&error];
  XCTAssertNotNil(data);
  XCTAssertNil(error);
  id value = data == nil ? nil : [NSJSONSerialization
      JSONObjectWithData:data
                  options:NSJSONReadingMutableContainers
                    error:&error];
  XCTAssertTrue([value isKindOfClass:NSMutableDictionary.class]);
  XCTAssertNil(error);
  return [value isKindOfClass:NSMutableDictionary.class] ? value : nil;
}

- (NSMutableDictionary *)mutableSharedFixtureNamed:(NSString *)name {
  NSDictionary *fixture = [self sharedFixtureNamed:name];
  return fixture == nil ? nil : [self mutableJSONCopyOfDictionary:fixture];
}

- (id)objectByReplacingCanonicalMilliseconds:(id)object
                                  milliseconds:(NSString *)milliseconds {
  if ([object isKindOfClass:NSString.class] &&
      [(NSString *)object hasSuffix:@".000Z"]) {
    return [(NSString *)object stringByReplacingCharactersInRange:
        NSMakeRange([(NSString *)object length] - 4, 3)
                                                   withString:milliseconds];
  }
  if ([object isKindOfClass:NSArray.class]) {
    NSMutableArray *result = [NSMutableArray array];
    for (id value in (NSArray *)object) {
      [result addObject:[self objectByReplacingCanonicalMilliseconds:value
                                                        milliseconds:milliseconds]];
    }
    return result;
  }
  if ([object isKindOfClass:NSDictionary.class]) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (id key in (NSDictionary *)object) {
      result[key] = [self objectByReplacingCanonicalMilliseconds:
          ((NSDictionary *)object)[key]
                                                        milliseconds:milliseconds];
    }
    return result;
  }
  return object;
}

- (NSMutableDictionary *)legacyV2SessionWithMilliseconds:
    (NSString *)milliseconds {
  NSMutableDictionary *legacySession =
      [self objectByReplacingCanonicalMilliseconds:[self candidate:1]
                                      milliseconds:milliseconds];
  legacySession[@"schema_version"] = @8;
  [legacySession removeObjectForKey:@"agent_transcript_cleanup_outbox"];
  [legacySession removeObjectForKey:@"session_events"];
  NSMutableArray *legacyConversations = [NSMutableArray array];
  for (NSDictionary *conversation in legacySession[@"conversations"]) {
    NSMutableDictionary *legacyConversation = [conversation mutableCopy];
    [legacyConversation removeObjectForKey:@"agent_grants"];
    [legacyConversations addObject:legacyConversation];
  }
  legacySession[@"conversations"] = legacyConversations;
  return legacySession;
}

- (NSDictionary *)casRequestWithOperation:(NSString *)operation
                                 expected:(NSDictionary *)expected
                                candidate:(NSDictionary *)candidate {
  return @{
    @"schema_version" : @1,
    @"operation_id" : operation,
    @"expected" : expected,
    @"candidate_json" : [self jsonForCandidate:candidate],
  };
}

- (DSHSessionSnapshotStore *)storeAtFreshRoot {
  NSString *name = [NSString stringWithFormat:@"rish-session-%@",
                    NSUUID.UUID.UUIDString.lowercaseString];
  NSURL *requested = [NSURL fileURLWithPath:
      [NSTemporaryDirectory() stringByAppendingPathComponent:name]
                                isDirectory:YES];
  XCTAssertTrue([NSFileManager.defaultManager
      createDirectoryAtURL:requested
      withIntermediateDirectories:YES
      attributes:@{ NSFilePosixPermissions : @0700 }
      error:nil]);
  NSURL *root = [NSURL fileURLWithPath:requested.path.stringByStandardizingPath
                           isDirectory:YES];
  return [[DSHSessionSnapshotStore alloc]
      initWithRootURL:root
           sessionURL:[root URLByAppendingPathComponent:@"sessions.json"]
     launchInstanceId:DSHSessionTestLaunch
           coordinator:nil
             faultHook:nil];
}

- (NSMutableDictionary *)failedAttemptCandidateWithCode:(NSString *)code {
  // Starts from the recovery fixture, whose attempts are already terminal
  // failures, and restates one attempt's failure code. That is the shape the
  // device produces when an Agent round settles on a stale workspace root.
  NSMutableDictionary *candidate =
      [self mutableSharedFixtureNamed:@"agent-interrupted-recovery-session"];
  XCTAssertNotNil(candidate);
  BOOL restated = NO;
  for (NSMutableDictionary *conversation in candidate[@"conversations"]) {
    for (NSMutableDictionary *attempt in conversation[@"attempts"]) {
      if (restated || ![attempt[@"status"] isEqual:@"failed"]) continue;
      attempt[@"failure_code"] = code;
      restated = YES;
    }
  }
  XCTAssertTrue(restated, @"fixture carries no failed attempt");
  return candidate;
}

- (NSDictionary *)casWithOperation:(NSString *)operation
                           expected:(NSDictionary *)expected
                          candidate:(NSDictionary *)candidate
                              error:(NSError **)error {
  return [self.store casPersistSession:@{
    @"schema_version" : @1,
    @"operation_id" : operation,
    @"expected" : expected,
    @"candidate_json" : [self jsonForCandidate:candidate],
  } error:error];
}

// Applies the exact metadata shape a store-written session file must
// carry. On a physical device data protection is enforced, so the class and
// backup-exclusion attributes are asserted by READING THEM BACK through the
// same fresh NSFileManager attributes the store validates, instead of
// trusting the setter's return value. CoreSimulator does not enforce data
// protection; backup exclusion remains an NSURL resource property.
- (void)applyPublishedSessionProtectionAtURL:(NSURL *)url {
  if (DSHTestHostIsSimulator()) {
    (void)[NSFileManager.defaultManager setAttributes:@{
        NSFileProtectionKey : NSFileProtectionCompleteUntilFirstUserAuthentication,
      } ofItemAtPath:url.path error:nil];
    (void)[url setResourceValue:@YES
                          forKey:NSURLIsExcludedFromBackupKey
                           error:nil];
    return;
  }
  NSError *error = nil;
  XCTAssertTrue(([NSFileManager.defaultManager
      setAttributes:@{
        NSFileProtectionKey :
            NSFileProtectionCompleteUntilFirstUserAuthentication,
      }
      ofItemAtPath:url.path
      error:&error]), @"%@", error);
  error = nil;
  XCTAssertTrue(([url setResourceValue:@YES
                                forKey:NSURLIsExcludedFromBackupKey
                                 error:&error]), @"%@", error);
  error = nil;
  NSDictionary *attributes = [NSFileManager.defaultManager
      attributesOfItemAtPath:url.path error:&error];
  XCTAssertNotNil(attributes, @"%@", error);
  XCTAssertEqualObjects(attributes[NSFileProtectionKey],
      NSFileProtectionCompleteUntilFirstUserAuthentication);
  NSNumber *excluded = nil;
  error = nil;
  XCTAssertTrue(([url getResourceValue:&excluded
                                forKey:NSURLIsExcludedFromBackupKey
                                 error:&error]), @"%@", error);
  XCTAssertTrue(excluded.boolValue);
}

- (void)writeProtectedBytes:(NSData *)data toURL:(NSURL *)url {
  XCTAssertTrue([data writeToURL:url options:NSDataWritingAtomic error:nil]);
  XCTAssertTrue(([NSFileManager.defaultManager
      setAttributes:@{
        NSFilePosixPermissions : @0600,
      }
      ofItemAtPath:url.path
      error:nil]));
  [self applyPublishedSessionProtectionAtURL:url];
}

- (void)writePublishedV2Bytes:(NSData *)data toURL:(NSURL *)url {
  XCTAssertTrue([data writeToURL:url options:NSDataWritingAtomic error:nil]);
  // The shipped V2 writer only guaranteed the private mode bit. The new
  // schema-9 store must accept this shape and harden metadata while locked.
  XCTAssertTrue(([NSFileManager.defaultManager
      setAttributes:@{ NSFilePosixPermissions : @0600 }
      ofItemAtPath:url.path
      error:nil]));
}

- (DSHSessionMetadataTestStore *)metadataTestStore {
  return [[DSHSessionMetadataTestStore alloc]
      initWithRootURL:self.rootURL
           sessionURL:self.store.sessionURL
     launchInstanceId:DSHSessionTestLaunch
           coordinator:nil
             faultHook:nil];
}

- (struct stat)writeMetadataFixtureWithMode:(NSNumber *)mode {
  NSData *bytes = [@"legacy-metadata-fixture" dataUsingEncoding:NSUTF8StringEncoding];
  XCTAssertTrue([bytes writeToURL:self.store.sessionURL options:0 error:nil]);
  XCTAssertTrue([NSFileManager.defaultManager
      setAttributes:@{ NSFilePosixPermissions : mode }
       ofItemAtPath:self.store.sessionURL.path
              error:nil]);
  struct stat state = {};
  XCTAssertEqual(lstat(self.store.sessionURL.fileSystemRepresentation, &state), 0);
  return state;
}

- (void)testCanonicalPathMetadataHardensPrivateFileAndKeepsRootBackedUp {
  struct stat expected = [self writeMetadataFixtureWithMode:@0600];
  DSHSessionMetadataTestStore *store = [self metadataTestStore];
  NSError *error = nil;
  XCTAssertTrue([store ensurePrivateRoot:&error], @"%@", error);
  XCTAssertTrue([store hardenLegacyFileWithIdentity:&expected error:&error],
                @"%@", error);
  XCTAssertNil(error);
  NSNumber *mode = [NSFileManager.defaultManager
      attributesOfItemAtPath:self.store.sessionURL.path
                       error:nil][NSFilePosixPermissions];
  XCTAssertEqualObjects(mode, @0600);
  XCTAssertEqualObjects(store.protections[self.rootURL.path],
                        NSFileProtectionCompleteUntilFirstUserAuthentication);
  XCTAssertEqualObjects(store.backups[self.rootURL.path], @NO);
  XCTAssertEqualObjects(store.protections[self.store.sessionURL.path],
                        NSFileProtectionCompleteUntilFirstUserAuthentication);
  XCTAssertEqualObjects(store.backups[self.store.sessionURL.path], @YES);
  for (NSString *path in store.protections) {
    XCTAssertFalse([path hasPrefix:@"/dev/fd/"]);
  }
}

- (void)testProtectionUsesFreshFileAttributesForDirectoryAndFile {
  [self writeMetadataFixtureWithMode:@0600];
  DSHSessionFileAttributesTestStore *store = [[DSHSessionFileAttributesTestStore alloc]
      initWithRootURL:self.rootURL sessionURL:self.store.sessionURL
      launchInstanceId:DSHSessionTestLaunch coordinator:nil faultHook:nil];
  store.trackingFileManager = [[DSHSessionTrackingFileManager alloc] init];
  NSData *original = [NSData dataWithContentsOfURL:self.store.sessionURL];
  for (NSURL *url in @[self.rootURL, self.store.sessionURL]) {
    NSError *error = nil;
    XCTAssertTrue([store setSessionProtectionValue:[store sessionProtectionPolicyValue]
                                            atURL:url error:&error], @"%@", error);
    XCTAssertEqualObjects(store.trackingFileManager.lastWritePath, url.path);
    XCTAssertEqualObjects(store.trackingFileManager.lastWrittenAttributes,
        (@{NSFileProtectionKey : NSFileProtectionCompleteUntilFirstUserAuthentication}));
    id protection = @"stale value";
    XCTAssertTrue([store getSessionProtectionAtURL:url value:&protection error:&error],
                  @"%@", error);
    XCTAssertEqualObjects(store.trackingFileManager.lastReadPath, url.path);
    NSDictionary *actual = [NSFileManager.defaultManager
        attributesOfItemAtPath:url.path error:&error];
    XCTAssertEqualObjects(protection, actual[NSFileProtectionKey]);
    if (!DSHTestHostIsSimulator()) {
      XCTAssertEqualObjects(protection, NSFileProtectionCompleteUntilFirstUserAuthentication);
    }
  }
  XCTAssertEqualObjects([NSData dataWithContentsOfURL:self.store.sessionURL], original);
  NSURL *missing = [self.rootURL URLByAppendingPathComponent:@"missing-protection-file"];
  id protection = @"stale value";
  NSError *error = nil;
  XCTAssertFalse([store getSessionProtectionAtURL:missing value:&protection error:&error]);
  XCTAssertNil(protection);
  XCTAssertNotNil(error);
}

- (void)testCanonicalPathMetadataDetectsInodeSwapAsConflict {
  struct stat expected = [self writeMetadataFixtureWithMode:@0600];
  DSHSessionMetadataTestStore *store = [self metadataTestStore];
  NSError *error = nil;
  XCTAssertTrue([store ensurePrivateRoot:&error], @"%@", error);
  store.swapSessionDuringProtection = YES;
  XCTAssertFalse([store hardenLegacyFileWithIdentity:&expected error:&error]);
  XCTAssertTrue(store.didSwapSession);
  XCTAssertEqual(error.code, DSHSessionSnapshotStoreErrorConflict);
}

- (void)testV1CompleteProtectionMigratesToV2UntilFirstAuthentication {
  struct stat expected = [self writeMetadataFixtureWithMode:@0600];
  DSHSessionMetadataTestStore *store = [self metadataTestStore];
  NSError *error = nil;
  XCTAssertTrue([store ensurePrivateRoot:&error], @"%@", error);
  store.protections[self.store.sessionURL.path] = NSFileProtectionComplete;
  XCTAssertTrue([store hardenLegacyFileWithIdentity:&expected error:&error],
                @"%@", error);
  XCTAssertNil(error);
  XCTAssertEqualObjects(
      store.protections[self.store.sessionURL.path],
      NSFileProtectionCompleteUntilFirstUserAuthentication);
}

// The read path only validates; it never hardens. An upgraded container whose
// session file still carries the legacy class, or lost its backup flag, must
// be repaired in place instead of failing every load and commit afterwards.
- (void)testReadValidationMigratesLegacyProtectionInsteadOfRefusingTheStore {
  struct stat expected = [self writeMetadataFixtureWithMode:@0600];
  DSHSessionMetadataTestStore *store = [self metadataTestStore];
  NSError *error = nil;
  XCTAssertTrue([store ensurePrivateRoot:&error], @"%@", error);
  XCTAssertTrue([store hardenLegacyFileWithIdentity:&expected error:&error],
                @"%@", error);
  store.protections[self.store.sessionURL.path] = NSFileProtectionComplete;
  store.backups[self.store.sessionURL.path] = @NO;
  error = nil;
  XCTAssertTrue([store validateProtectedFileWithIdentity:&expected error:&error],
                @"a legacy protection class must be migrated, not refused: %@", error);
  XCTAssertNil(error);
  XCTAssertEqualObjects(store.protections[self.store.sessionURL.path],
                        NSFileProtectionCompleteUntilFirstUserAuthentication);
  XCTAssertEqualObjects(store.backups[self.store.sessionURL.path], @YES);
}

- (void)testLockedV1CompleteProtectionFailsWhenV2CannotBeApplied {
  struct stat expected = [self writeMetadataFixtureWithMode:@0600];
  DSHSessionMetadataTestStore *store = [self metadataTestStore];
  NSError *error = nil;
  XCTAssertTrue([store ensurePrivateRoot:&error], @"%@", error);
  store.protections[self.store.sessionURL.path] = NSFileProtectionComplete;
  store.preserveOldSessionProtection = YES;
  XCTAssertFalse([store hardenLegacyFileWithIdentity:&expected error:&error]);
  XCTAssertEqualObjects(store.protections[self.store.sessionURL.path],
                        NSFileProtectionComplete);
  XCTAssertEqual(error.code, DSHSessionSnapshotStoreErrorProtection);
}

- (void)testV2ProtectionRejectsFreshReadbackLoss {
  struct stat expected = [self writeMetadataFixtureWithMode:@0600];
  DSHSessionMetadataTestStore *store = [self metadataTestStore];
  NSError *error = nil;
  XCTAssertTrue([store ensurePrivateRoot:&error], @"%@", error);
  store.loseSessionProtectionReadback = YES;
  XCTAssertFalse([store hardenLegacyFileWithIdentity:&expected error:&error]);
  XCTAssertEqual(error.code, DSHSessionSnapshotStoreErrorProtection);
}

- (void)testCanonicalPathMetadataMapsPathSyscallFailureToStorage {
  (void)[self writeMetadataFixtureWithMode:@0600];
  DSHSessionMetadataTestStore *store = [self metadataTestStore];
  NSError *error = nil;
  XCTAssertTrue([store ensurePrivateRoot:&error], @"%@", error);
  int descriptor = open(self.store.sessionURL.fileSystemRepresentation,
                        O_RDWR | O_CLOEXEC | O_NOFOLLOW);
  XCTAssertGreaterThanOrEqual(descriptor, 0);
  XCTAssertTrue([NSFileManager.defaultManager removeItemAtURL:self.store.sessionURL
                                                       error:nil]);
  XCTAssertFalse([store hardenPinnedDescriptor:descriptor
                                         atURL:self.store.sessionURL
                                     directory:NO
                                 excludeBackup:YES
                                         error:&error]);
  XCTAssertEqual(error.code, DSHSessionSnapshotStoreErrorStorage);
  if (descriptor >= 0) close(descriptor);
}

- (void)testCASLockIsHeldBeforeCanonicalPathMetadata {
  DSHSessionMetadataTestStore *store = [self metadataTestStore];
  NSError *error = nil;
  XCTAssertTrue([store ensurePrivateRoot:&error], @"%@", error);
  int descriptor = [store acquireCASLock:&error];
  XCTAssertGreaterThanOrEqual(descriptor, 0, @"%@", error);
  XCTAssertTrue(store.observedLockHeldDuringMetadata);
  NSURL *lockURL = [self.rootURL
      URLByAppendingPathComponent:@".sessions.cas-lock" isDirectory:NO];
  XCTAssertEqualObjects(
      store.protections[lockURL.path],
      NSFileProtectionCompleteUntilFirstUserAuthentication);
  XCTAssertEqualObjects(store.backups[lockURL.path], @YES);
  if (descriptor >= 0) close(descriptor);
}

- (void)testProtectionV2CoversRootLockSessionTombstoneAndTemporaryPaths {
  DSHSessionMetadataTestStore *store = [self metadataTestStore];
  NSError *error = nil;
  NSDictionary *result = [store casPersistSession:@{
    @"schema_version" : @1,
    @"operation_id" : DSHSessionTestOperationA,
    @"expected" : @{
      @"schema_version" : @1,
      @"kind" : @"missing",
    },
    @"candidate_json" : [self jsonForCandidate:[self candidate:1]],
  } error:&error];
  XCTAssertNotNil(result, @"%@", error);
  XCTAssertEqualObjects(result[@"status"], @"committed");

  NSSet<NSString *> *requiredNames = [NSSet setWithArray:@[
    @".sessions.cas-lock",
    @".sessions.commit-tombstones",
    @"sessions.json",
  ]];
  NSMutableSet<NSString *> *observedNames = [NSMutableSet set];
  BOOL sawSessionTemporary = NO;
  BOOL sawTombstoneTemporary = NO;
  for (NSString *path in store.protections) {
    XCTAssertEqualObjects(
        store.protections[path],
        NSFileProtectionCompleteUntilFirstUserAuthentication);
    NSURL *url = [NSURL fileURLWithPath:path];
    [observedNames addObject:url.lastPathComponent];
    if ([url.lastPathComponent hasPrefix:@".sessions.json."] &&
        [url.lastPathComponent hasSuffix:@".tmp"]) {
      sawSessionTemporary = YES;
    }
    if ([url.lastPathComponent
            hasPrefix:@"..sessions.commit-tombstones."] &&
        [url.lastPathComponent hasSuffix:@".tmp"]) {
      sawTombstoneTemporary = YES;
    }
    XCTAssertEqualObjects(store.backups[path],
                          [path isEqualToString:self.rootURL.path] ? @NO : @YES);
  }
  XCTAssertTrue([requiredNames isSubsetOfSet:observedNames]);
  XCTAssertTrue(sawSessionTemporary);
  XCTAssertTrue(sawTombstoneTemporary);
}

// Regression for the physical-device init failure: a root spelled with the
// "/private" prefix that already exists, paired with a sessions.json that does
// not exist yet, made `stringByStandardizingPath` drop the prefix from the
// root only, so the containment check failed and init returned nil. Every
// later message went to nil and every CAS "result" was nil with a nil error.
// NSTemporaryDirectory() is spelled that way on device; on the CoreSimulator
// host the per-user temp dir provides the same spelling.
- (void)testInitAcceptsPrivatePrefixedExistingRootBeforeSessionFileExists {
  // Device: NSTemporaryDirectory() is already "/private/var/...". Simulator
  // host: the container temp dir is under /Users, so fall back to the host's
  // per-user temp dir and finally /private/tmp.
  NSURL *root = nil;
  NSError *error = nil;
  for (NSString *candidate in @[ NSTemporaryDirectory(),
                                  [self hostUserTemporaryDirectory],
                                  @"/private/tmp" ]) {
    if (candidate.length == 0) continue;
    char resolved[PATH_MAX] = {0};
    if (realpath(candidate.fileSystemRepresentation, resolved) == NULL) continue;
    NSString *physical = [NSFileManager.defaultManager
        stringWithFileSystemRepresentation:resolved length:strlen(resolved)];
    if (![physical hasPrefix:@"/private/"]) continue;
    // One extra level so the store's parent directory is a real directory:
    // the store opens parents with O_NOFOLLOW and "/tmp" on the simulator
    // host is itself a symlink.
    NSURL *attempt = [[[NSURL fileURLWithPath:physical isDirectory:YES]
        URLByAppendingPathComponent:
            [NSString stringWithFormat:@"rish-private-%@",
                NSUUID.UUID.UUIDString.lowercaseString] isDirectory:YES]
        URLByAppendingPathComponent:@"store" isDirectory:YES];
    if ([NSFileManager.defaultManager createDirectoryAtURL:attempt
        withIntermediateDirectories:YES
        attributes:@{ NSFilePosixPermissions : @0700 } error:&error]) {
      root = attempt;
      break;
    }
  }
  if (root == nil) {
    XCTSkip(@"No writable temporary directory on this host is spelled with "
        @"the /private prefix, so the device path shape cannot be modeled.");
  }
  NSURL *sessionURL = [root URLByAppendingPathComponent:@"sessions.json"];
  XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:sessionURL.path]);
  // The root exists, so its standardized spelling drops "/private"; the
  // session file does not exist, so its own standardized spelling would not.
  XCTAssertFalse([root.path.stringByStandardizingPath hasPrefix:@"/private/"]);
  XCTAssertTrue([sessionURL.path.stringByStandardizingPath hasPrefix:@"/private/"]);

  DSHSessionSnapshotStore *store = [[DSHSessionSnapshotStore alloc]
      initWithRootURL:root
           sessionURL:sessionURL
     launchInstanceId:DSHSessionTestLaunch
           coordinator:nil
             faultHook:nil];
  XCTAssertNotNil(store);
  XCTAssertEqualObjects(store.sessionURL.URLByDeletingLastPathComponent.path,
                        store.rootURL.path);
  XCTAssertEqualObjects(store.sessionURL.lastPathComponent, @"sessions.json");
  NSDictionary *result = [store casPersistSession:@{
    @"schema_version" : @1,
    @"operation_id" : DSHSessionTestOperationA,
    @"expected" : @{ @"schema_version" : @1, @"kind" : @"missing" },
    @"candidate_json" : [self jsonForCandidate:[self candidate:1]],
  } error:&error];
  XCTAssertNotNil(result, @"%@", error);
  XCTAssertEqualObjects(result[@"status"], @"committed");
  XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:sessionURL.path]);
  [NSFileManager.defaultManager
      removeItemAtURL:root.URLByDeletingLastPathComponent error:nil];
}

- (NSString *)hostUserTemporaryDirectory {
  char buffer[PATH_MAX] = {0};
  size_t length = confstr(_CS_DARWIN_USER_TEMP_DIR, buffer, sizeof(buffer));
  if (length == 0 || length > sizeof(buffer)) return @"";
  return [NSFileManager.defaultManager
      stringWithFileSystemRepresentation:buffer length:strlen(buffer)];
}

- (void)testFreshStoreLoadsAsMissingAndFirstCASCommitsV3 {
  NSError *error = nil;
  NSDictionary *loaded = [self.store loadSessionSnapshotWithError:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(loaded[@"status"], @"missing");
  XCTAssertEqualObjects(loaded[@"snapshot"], NSNull.null);
  XCTAssertEqualObjects(loaded[@"session_json"], NSNull.null);

  NSDictionary *result = [self casWithOperation:DSHSessionTestOperationA
                                         expected:@{
                                           @"schema_version" : @1,
                                           @"kind" : @"missing",
                                         }
                                        candidate:[self candidate:1]
                                            error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"committed");
  XCTAssertEqualObjects(result[@"snapshot"][@"generation"], @1);
  XCTAssertEqualObjects(result[@"snapshot"][@"session_sha256"],
                        @"644e1c5edaa15648762be9787eeb284287d3d1ecbde13263ec93606400c5009c");

  loaded = [self.store loadSessionSnapshotWithError:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(loaded[@"status"], @"present");
  XCTAssertEqualObjects(loaded[@"snapshot"][@"generation"], @1);
  XCTAssertEqualObjects([NSFileManager.defaultManager
      attributesOfItemAtPath:self.store.sessionURL.path error:nil]
      [NSFilePosixPermissions], @0600);
}

- (void)testCASIsIdempotentAndRejectsStaleAuthority {
  NSError *error = nil;
  NSDictionary *missing = @{
    @"schema_version" : @1,
    @"kind" : @"missing",
  };
  NSDictionary *first = [self casWithOperation:DSHSessionTestOperationA
                                        expected:missing
                                       candidate:[self candidate:1]
                                           error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(first[@"status"], @"committed");
  NSDictionary *replay = [self casWithOperation:DSHSessionTestOperationA
                                         expected:missing
                                        candidate:[self candidate:1]
                                            error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(replay[@"status"], @"committed");
  XCTAssertEqualObjects(replay[@"snapshot"][@"generation"], @1);

  NSDictionary *present = @{
    @"schema_version" : @1,
    @"kind" : @"present",
    @"snapshot" : first[@"snapshot"],
  };
  NSDictionary *second = [self casWithOperation:DSHSessionTestOperationB
                                         expected:present
                                        candidate:[self candidate:2]
                                            error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(second[@"status"], @"committed");
  XCTAssertEqualObjects(second[@"snapshot"][@"generation"], @2);

  NSDictionary *stale = [self casWithOperation:
      @"cccccccc-cccc-4ccc-8ccc-cccccccccccc"
      expected:present
      candidate:[self candidate:3]
      error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(stale[@"status"], @"conflict");
  XCTAssertEqualObjects(stale[@"current"][@"snapshot"][@"generation"], @2);
}

- (void)testLegacyV2LoadsWithRawByteTokenAndMigratesOnlyWithThatToken {
  NSMutableDictionary *legacySession = [[self candidate:1] mutableCopy];
  legacySession[@"schema_version"] = @8;
  [legacySession removeObjectForKey:@"agent_transcript_cleanup_outbox"];
  [legacySession removeObjectForKey:@"session_events"];
  NSMutableArray *legacyConversations = [NSMutableArray array];
  for (NSDictionary *conversation in legacySession[@"conversations"]) {
    NSMutableDictionary *legacyConversation = [conversation mutableCopy];
    [legacyConversation removeObjectForKey:@"agent_grants"];
    [legacyConversations addObject:legacyConversation];
  }
  legacySession[@"conversations"] = legacyConversations;
  NSDictionary *legacyEnvelope = @{
    @"schema_version" : @2,
    @"writer_launch_instance_id" : DSHSessionTestLaunch,
    @"session" : legacySession,
  };
  NSError *serializationError = nil;
  NSData *legacyBytes = DSHWorkspaceCanonicalJSONData(legacyEnvelope,
                                                       &serializationError);
  XCTAssertNil(serializationError);
  [self writePublishedV2Bytes:legacyBytes toURL:self.store.sessionURL];

  NSError *error = nil;
  NSDictionary *loaded = [self.store loadSessionSnapshotWithError:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(loaded[@"status"], @"legacy_present");
  NSDictionary *legacy = loaded[@"legacy"];
  XCTAssertEqualObjects(legacy[@"schema_version"], @1);
  XCTAssertEqual(((NSString *)legacy[@"legacy_bytes_sha256"]).length, 64u);
  XCTAssertEqualObjects(legacy[@"legacy_bytes_sha256"],
                        @"ab32635dc1e3930cbbb9de5773fc46c544453f94921592ffa4b016ecc21d6e55");
  NSNumber *excluded = nil;
  if (DSHTestHostIsSimulator()) {
    // CoreSimulator filesystems may not implement the iOS backup-resource
    // key; the native store still enforces mode/inode/no-follow and treats
    // this key as best effort on simulator.
    (void)[self.store.sessionURL
        getResourceValue:&excluded
                  forKey:NSURLIsExcludedFromBackupKey
                   error:nil];
  } else {
    // Device: the hardened legacy file must carry the actual backup
    // exclusion attribute. Assert the read-back value, not the setter.
    XCTAssertTrue(([self.store.sessionURL
        getResourceValue:&excluded
                  forKey:NSURLIsExcludedFromBackupKey
                   error:nil]));
    XCTAssertTrue(excluded.boolValue);
  }

  NSDictionary *migrationExpected = @{
    @"schema_version" : @1,
    @"kind" : @"legacy_present",
    @"legacy" : legacy,
  };
  NSDictionary *result = [self casWithOperation:DSHSessionTestOperationA
                                         expected:migrationExpected
                                        candidate:[self candidate:1]
                                            error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"committed");
  XCTAssertEqualObjects(result[@"snapshot"][@"generation"], @1);
  loaded = [self.store loadSessionSnapshotWithError:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(loaded[@"status"], @"present");
}

- (void)testLegacyV2AcceptsNonzeroMillisecondsAndMigratesByRawToken {
  NSDictionary *legacyEnvelope = @{
    @"schema_version" : @2,
    @"writer_launch_instance_id" : DSHSessionTestLaunch,
    @"session" : [self legacyV2SessionWithMilliseconds:@"123"],
  };
  NSError *error = nil;
  NSData *legacyBytes = DSHWorkspaceCanonicalJSONData(legacyEnvelope, &error);
  XCTAssertNotNil(legacyBytes);
  XCTAssertNil(error);
  [self writePublishedV2Bytes:legacyBytes toURL:self.store.sessionURL];

  NSDictionary *loaded = [self.store loadSessionSnapshotWithError:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(loaded[@"status"], @"legacy_present");
  NSDictionary *legacy = loaded[@"legacy"];
  XCTAssertEqual(((NSString *)legacy[@"legacy_bytes_sha256"]).length, 64u);
  NSDictionary *result = [self casWithOperation:DSHSessionTestOperationA
                                         expected:@{
                                           @"schema_version" : @1,
                                           @"kind" : @"legacy_present",
                                           @"legacy" : legacy,
                                         }
                                        candidate:[self candidate:1]
                                            error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"committed");
  XCTAssertEqualObjects(result[@"snapshot"][@"generation"], @1);
  loaded = [self.store loadSessionSnapshotWithError:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(loaded[@"status"], @"present");
}

- (void)testLegacyV2RejectsNoncanonicalFractionAndTimezoneTimestamps {
  NSArray<NSString *> *invalidTimestamps = @[
    @"2026-08-30T00:00:00.1234Z",
    @"2026-08-30T00:00:00.123+00:00",
    @"2026-08-30T00:00:00Z",
  ];
  for (NSString *invalidTimestamp in invalidTimestamps) {
    NSMutableDictionary *legacySession =
        [self legacyV2SessionWithMilliseconds:@"123"];
    NSMutableArray *messages = [legacySession[@"messages"] mutableCopy];
    NSMutableDictionary *message = [messages[0] mutableCopy];
    message[@"created_at"] = invalidTimestamp;
    messages[0] = message;
    legacySession[@"messages"] = messages;
    NSDictionary *legacyEnvelope = @{
      @"schema_version" : @2,
      @"writer_launch_instance_id" : DSHSessionTestLaunch,
      @"session" : legacySession,
    };
    NSData *bytes = DSHWorkspaceCanonicalJSONData(legacyEnvelope, nil);
    XCTAssertNotNil(bytes);
    [self writePublishedV2Bytes:bytes toURL:self.store.sessionURL];
    NSError *error = nil;
    XCTAssertNil([self.store loadSessionSnapshotWithError:&error]);
    XCTAssertEqual(error.code, DSHSessionSnapshotStoreErrorCorrupt,
                   @"%@", invalidTimestamp);
  }
}

- (void)testSchema9CannotBeDowngradedThroughV2Envelope {
  NSDictionary *invalidEnvelope = @{
    @"schema_version" : @2,
    @"writer_launch_instance_id" : DSHSessionTestLaunch,
    @"session" : [self candidate:1],
  };
  NSData *bytes = DSHWorkspaceCanonicalJSONData(invalidEnvelope, nil);
  [self writeProtectedBytes:bytes toURL:self.store.sessionURL];
  NSError *error = nil;
  XCTAssertNil([self.store loadSessionSnapshotWithError:&error]);
  XCTAssertEqual(error.code, DSHSessionSnapshotStoreErrorCorrupt);
}

- (void)testFailedAtomicWriteLeavesMissingStoreUntouched {
  DSHSessionSnapshotStoreFaultHook hook =
      ^BOOL(DSHSessionSnapshotStoreFaultPoint point) {
        return point != DSHSessionSnapshotStoreFaultPointBeforeWrite;
      };
  DSHSessionSnapshotStore *faulted = [[DSHSessionSnapshotStore alloc]
      initWithRootURL:self.rootURL
           sessionURL:self.store.sessionURL
     launchInstanceId:DSHSessionTestLaunch
           coordinator:nil
             faultHook:hook];
  NSError *error = nil;
  NSDictionary *result = [faulted casPersistSession:@{
    @"schema_version" : @1,
    @"operation_id" : DSHSessionTestOperationA,
    @"expected" : @{
      @"schema_version" : @1,
      @"kind" : @"missing",
    },
    @"candidate_json" : [self jsonForCandidate:[self candidate:1]],
  } error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"not_committed");
  NSDictionary *loaded = [faulted loadSessionSnapshotWithError:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(loaded[@"status"], @"missing");
}

- (void)testQueryRecoversRetainedCommitAndReportsProvableAbsence {
  NSError *error = nil;
  NSDictionary *result = [self casWithOperation:DSHSessionTestOperationA
                                         expected:@{
                                           @"schema_version" : @1,
                                           @"kind" : @"missing",
                                         }
                                        candidate:[self candidate:1]
                                            error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"committed");

  NSDictionary *committed = [self.store querySessionCommit:@{
    @"schema_version" : @1,
    @"operation_id" : DSHSessionTestOperationA,
  } error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(committed[@"status"], @"committed");
  XCTAssertEqualObjects(committed[@"snapshot"], result[@"snapshot"]);

  NSDictionary *notStarted = [self.store querySessionCommit:@{
    @"schema_version" : @1,
    @"operation_id" : DSHSessionTestOperationB,
  } error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(notStarted[@"status"], @"not_started");
}

- (void)testWorkspaceClearanceBindsReceiptToSessionAndInvalidatesAfterNextCommit {
  [self installDocumentsClearanceWorkspace];
  NSDictionary *candidate = [self candidate:1];
  NSDictionary *operation = candidate[@"workspace_authority_outbox"][0];
  NSError *error = nil;
  NSDictionary *result = [self.store
      persistSessionWithWorkspaceClearance:@{
        @"schema_version" : @1,
        @"candidate_json" : [self jsonForCandidate:candidate],
        @"operation" : operation,
      }
      error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"committed");
  NSDictionary *receipt = result[@"receipt"];
  XCTAssertEqualObjects(receipt[@"operation_id"], operation[@"operation_id"]);
  XCTAssertEqualObjects(receipt[@"workspace_id"], operation[@"workspace_id"]);
  XCTAssertEqualObjects(receipt[@"binding_revision"], @1);
  XCTAssertEqualObjects(receipt[@"committed_session_generation"], @1);
  XCTAssertEqual(((NSString *)receipt[@"committed_session_sha256"]).length, 64u);

  NSDictionary *recovered = [self.store queryWorkspaceClearance:@{
    @"schema_version" : @1,
    @"operation_id" : operation[@"operation_id"],
  } error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(recovered[@"status"], @"committed");
  XCTAssertEqualObjects(recovered[@"receipt"], receipt);

  NSDictionary *next = [self casWithOperation:DSHSessionTestOperationB
                                       expected:@{
                                         @"schema_version" : @1,
                                         @"kind" : @"present",
                                         @"snapshot" : @{
                                           @"schema_version" : @1,
                                           @"generation" : @1,
                                           @"session_sha256" :
                                               receipt[@"committed_session_sha256"],
                                         },
                                       }
                                      candidate:[self candidate:2]
                                          error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(next[@"status"], @"committed");

  NSDictionary *stale = [self.store queryWorkspaceClearance:@{
    @"schema_version" : @1,
    @"operation_id" : operation[@"operation_id"],
  } error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(stale[@"status"], @"unknown");

  NSDictionary *replay = [self.store
      persistSessionWithWorkspaceClearance:@{
        @"schema_version" : @1,
        @"candidate_json" : [self jsonForCandidate:[self candidate:1]],
        @"operation" : operation,
      }
      error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(replay[@"status"], @"not_committed");
  XCTAssertEqualObjects(replay[@"receipt"], NSNull.null);
  NSDictionary *replayedQuery = [self.store queryWorkspaceClearance:@{
    @"schema_version" : @1,
    @"operation_id" : operation[@"operation_id"],
  } error:&error];
  XCTAssertEqualObjects(replayedQuery[@"status"], @"unknown");
  XCTAssertNil(error);

  XCTAssertFalse([self.store.clearanceStore
      validateReceipt:receipt
      operationId:operation[@"operation_id"]
      workspaceId:operation[@"workspace_id"]
      bindingRevision:1
      currentSessionGeneration:2
      currentSessionSHA256:next[@"snapshot"][@"session_sha256"]
      error:&error]);
  XCTAssertNotNil(error);
}

- (void)testWorkspaceClearanceRefusesPublishedProjectRelationAndPendingDetach {
  [self installDocumentsClearanceWorkspace];
  NSString *workspaceId = @"44444444-4444-4444-8444-444444444444";
  NSURL *gitdirs = [self.rootURL
      URLByAppendingPathComponent:@"workspace-gitdirs" isDirectory:YES];
  NSURL *workspace = [gitdirs URLByAppendingPathComponent:workspaceId
                                               isDirectory:YES];
  NSURL *project = [workspace
      URLByAppendingPathComponent:@"66666666-6666-4666-8666-666666666666"
                       isDirectory:YES];
  XCTAssertTrue([NSFileManager.defaultManager
      createDirectoryAtURL:project
      withIntermediateDirectories:YES
      attributes:@{ NSFilePosixPermissions : @0700 }
      error:nil]);
  NSURL *binding = [project URLByAppendingPathComponent:@"binding-v2.json"];
  XCTAssertTrue([@"published" dataUsingEncoding:NSUTF8StringEncoding]
      .length > 0);
  XCTAssertTrue([[@"published" dataUsingEncoding:NSUTF8StringEncoding]
      writeToURL:binding options:NSDataWritingAtomic error:nil]);
  XCTAssertTrue([NSFileManager.defaultManager
      setAttributes:@{ NSFilePosixPermissions : @0600 }
      ofItemAtPath:binding.path
      error:nil]);

  NSDictionary *candidate = [self candidate:1];
  NSDictionary *operation = candidate[@"workspace_authority_outbox"][0];
  NSError *error = nil;
  NSDictionary *result = [self.store
      persistSessionWithWorkspaceClearance:@{
        @"schema_version" : @1,
        @"candidate_json" : [self jsonForCandidate:candidate],
        @"operation" : operation,
      }
      error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"not_committed");
  XCTAssertEqualObjects(result[@"receipt"], NSNull.null);
  XCTAssertEqualObjects(
      [[self.store loadSessionSnapshotWithError:&error] objectForKey:@"status"],
      @"missing");
  XCTAssertNil(error);

  [NSFileManager.defaultManager removeItemAtURL:binding error:nil];
  DSHWorkspaceClearanceRegisterProjectDetachCheckpoint(workspaceId, 1);
  result = [self.store
      persistSessionWithWorkspaceClearance:@{
        @"schema_version" : @1,
        @"candidate_json" : [self jsonForCandidate:candidate],
        @"operation" : operation,
      }
      error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"not_committed");
  XCTAssertEqualObjects(result[@"receipt"], NSNull.null);
  DSHWorkspaceClearanceUnregisterProjectDetachCheckpoint(workspaceId, 1);
}

- (void)testWorkspaceClearanceAllowsMarkedDetachedCheckpointWithoutPublishedRelation {
  [self installDocumentsClearanceWorkspace];
  NSString *workspaceId = @"44444444-4444-4444-8444-444444444444";
  DSHWorkspaceClearanceRegisterProjectDetachCheckpoint(workspaceId, 1);
  DSHWorkspaceClearanceMarkProjectDetachCheckpointDetached(workspaceId, 1);
  NSDictionary *candidate = [self candidate:1];
  NSDictionary *operation = candidate[@"workspace_authority_outbox"][0];
  NSError *error = nil;
  NSDictionary *result = [self.store
      persistSessionWithWorkspaceClearance:@{
        @"schema_version" : @1,
        @"candidate_json" : [self jsonForCandidate:candidate],
        @"operation" : operation,
      }
      error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"committed");
  DSHWorkspaceClearanceUnregisterProjectDetachCheckpoint(workspaceId, 1);
}

- (void)testWorkspaceClearanceRejectsLegacyRelationWithoutGitdirsOrReceipt {
  [self installLegacyClearanceWorkspace];
  NSString *workspaceId = @"44444444-4444-4444-8444-444444444444";
  DSHWorkspaceClearanceRegisterProjectDetachCheckpoint(workspaceId, 1);
  DSHWorkspaceClearanceMarkProjectDetachCheckpointDetached(workspaceId, 1);
  NSDictionary *candidate = [self candidate:1];
  NSDictionary *operation = candidate[@"workspace_authority_outbox"][0];
  NSError *error = nil;
  NSDictionary *result = [self.store
      persistSessionWithWorkspaceClearance:@{
        @"schema_version" : @1,
        @"candidate_json" : [self jsonForCandidate:candidate],
        @"operation" : operation,
      }
      error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"not_committed");
  NSDictionary *query = [self.store queryWorkspaceClearance:@{
    @"schema_version" : @1,
    @"operation_id" : operation[@"operation_id"],
  } error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(query[@"status"], @"not_started");
  XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:
      [self.rootURL URLByAppendingPathComponent:@"workspace-gitdirs"].path]);
  DSHWorkspaceClearanceUnregisterProjectDetachCheckpoint(workspaceId, 1);
}

- (void)testWorkspaceClearanceHoldsSessionLockAcrossCASAndReceiptGap {
  dispatch_semaphore_t enteredReceiptGap = dispatch_semaphore_create(0);
  dispatch_semaphore_t releaseReceiptGap = dispatch_semaphore_create(0);
  __block NSUInteger validatorCalls = 0;
  DSHWorkspaceClearanceProjectDetachValidator validator =
      ^BOOL(__unused NSURL *rootURL,
            __unused NSString *workspaceId,
            __unused NSUInteger bindingRevision,
            __unused NSError **error) {
    validatorCalls += 1;
    if (validatorCalls == 2) {
      dispatch_semaphore_signal(enteredReceiptGap);
      dispatch_semaphore_wait(releaseReceiptGap, DISPATCH_TIME_FOREVER);
      return NO;
    }
    return YES;
  };
  DSHSessionSnapshotStore *writer = [[DSHSessionSnapshotStore alloc]
      initWithRootURL:self.rootURL
           sessionURL:self.store.sessionURL
     launchInstanceId:DSHSessionTestLaunch
           coordinator:[DSHSessionWorkspaceCoordinator sharedCoordinator]
             faultHook:nil
      projectDetachValidator:validator];
  XCTAssertNotNil(writer);

  NSDictionary *candidate = [self candidate:1];
  NSDictionary *operation = candidate[@"workspace_authority_outbox"][0];
  NSString *candidateJSON = [self jsonForCandidate:candidate];
  __block NSDictionary *writerResult = nil;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
    writerResult = [writer persistSessionWithWorkspaceClearance:@{
      @"schema_version" : @1,
      @"candidate_json" : candidateJSON,
      @"operation" : operation,
    } error:nil];
  });
  XCTAssertEqual(dispatch_semaphore_wait(
      enteredReceiptGap,
      dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)), 0);

  id allocated = [DSHSessionWorkspaceCoordinator alloc];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
  DSHSessionWorkspaceCoordinator *otherCoordinator =
      [allocated performSelector:NSSelectorFromString(@"initPrivate")];
#pragma clang diagnostic pop
  DSHSessionSnapshotStore *competitor = [[DSHSessionSnapshotStore alloc]
      initWithRootURL:self.rootURL
           sessionURL:self.store.sessionURL
     launchInstanceId:@"66666666-6666-4666-8666-666666666666"
           coordinator:otherCoordinator
             faultHook:nil];
  __block NSDictionary *competitorResult = nil;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
    competitorResult = [competitor casPersistSession:@{
      @"schema_version" : @1,
      @"operation_id" : DSHSessionTestOperationB,
      @"expected" : @{ @"schema_version" : @1, @"kind" : @"missing" },
      @"candidate_json" : [self jsonForCandidate:[self candidate:2]],
    } error:nil];
  });
  usleep(100000);
  XCTAssertNil(competitorResult);

  dispatch_semaphore_signal(releaseReceiptGap);
  for (NSUInteger index = 0; index < 500 &&
      (writerResult == nil || competitorResult == nil); index += 1) {
    usleep(10000);
  }
  XCTAssertEqualObjects(writerResult[@"status"], @"unknown");
  XCTAssertEqualObjects(competitorResult[@"status"], @"conflict");

  NSError *error = nil;
  NSDictionary *loaded = [self.store loadSessionSnapshotWithError:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(loaded[@"status"], @"present");
  NSDictionary *second = [self casWithOperation:DSHSessionTestOperationB
                                         expected:@{
                                           @"schema_version" : @1,
                                           @"kind" : @"present",
                                           @"snapshot" : loaded[@"snapshot"],
                                         }
                                        candidate:[self candidate:2]
                                            error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(second[@"status"], @"committed");
  NSDictionary *query = [self.store queryWorkspaceClearance:@{
    @"schema_version" : @1,
    @"operation_id" : operation[@"operation_id"],
  } error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(query[@"status"], @"unknown");
}

- (void)testAuthorityGuardPublishesReceiptBeforeAttachProducerAndConsumerRecheck {
  DSHLocalWorkspaceAccess *workspaceAccess =
      [self installDocumentsClearanceWorkspace];
  dispatch_semaphore_t enteredSecondProof = dispatch_semaphore_create(0);
  dispatch_semaphore_t releaseSecondProof = dispatch_semaphore_create(0);
  __block NSUInteger validatorCalls = 0;
  DSHWorkspaceClearanceProjectDetachValidator validator =
      ^BOOL(__unused NSURL *rootURL,
            __unused NSString *workspaceId,
            __unused NSUInteger bindingRevision,
            __unused NSError **error) {
    validatorCalls += 1;
    if (validatorCalls == 2) {
      dispatch_semaphore_signal(enteredSecondProof);
      dispatch_semaphore_wait(releaseSecondProof, DISPATCH_TIME_FOREVER);
    }
    return YES;
  };
  DSHSessionSnapshotStore *writer = [[DSHSessionSnapshotStore alloc]
      initWithRootURL:self.rootURL
           sessionURL:self.store.sessionURL
     launchInstanceId:DSHSessionTestLaunch
           coordinator:[DSHSessionWorkspaceCoordinator sharedCoordinator]
             faultHook:nil
      projectDetachValidator:validator];
  [writer setValue:workspaceAccess forKey:@"clearanceWorkspaceAccess"];

  DSHLocalProjectAccess *projectAccess = [[DSHLocalProjectAccess alloc]
      initWithWorkspaceAccess:workspaceAccess hook:nil];
  Class moduleClass = NSClassFromString(@"LocalProjectsModule");
  LocalProjectsModule *projects = [[moduleClass alloc] init];
  [projects setValue:workspaceAccess forKey:@"workspaceAccessV2"];
  [projects setValue:projectAccess forKey:@"projectAccessV2"];
  [projects setValue:nil forKey:@"v2AttachStartupError"];

  NSDictionary *candidate = [self candidate:1];
  NSDictionary *operation = candidate[@"workspace_authority_outbox"][0];
  __block NSDictionary *writerResult = nil;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
    writerResult = [writer persistSessionWithWorkspaceClearance:@{
      @"schema_version" : @1,
      @"candidate_json" : [self jsonForCandidate:candidate],
      @"operation" : operation,
    } error:nil];
  });
  XCTAssertEqual(dispatch_semaphore_wait(
      enteredSecondProof,
      dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)), 0);

  NSDictionary *workspaceRoot = @{
    @"schema_version" : @1,
    @"workspace_id" : operation[@"workspace_id"],
    @"binding_revision" : operation[@"binding_revision"],
    @"project_id" : NSNull.null,
  };
  __block NSDictionary *producerResult = nil;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
    producerResult = [projects v2AttachWorkspaceProject:@{
      @"schema_version" : @1,
      @"operation_id" : @"89898989-8989-4898-8989-898989898989",
      @"root" : workspaceRoot,
      @"mode" : @"init",
    } error:nil];
  });
  usleep(100000);
  XCTAssertNil(producerResult);
  dispatch_semaphore_signal(releaseSecondProof);
  for (NSUInteger index = 0; index < 1000 &&
      (writerResult == nil || producerResult == nil); index += 1) {
    usleep(10000);
  }
  XCTAssertEqualObjects(writerResult[@"status"], @"committed");
  XCTAssertEqualObjects(producerResult[@"status"], @"attached");
  NSDictionary *receiptQuery = [writer queryWorkspaceClearance:@{
    @"schema_version" : @1,
    @"operation_id" : operation[@"operation_id"],
  } error:nil];
  XCTAssertEqualObjects(receiptQuery[@"status"], @"committed");

  NSString *projectId = producerResult[@"project"][@"project_id"];
  NSDictionary *projectRoot = @{
    @"schema_version" : @1,
    @"workspace_id" : operation[@"workspace_id"],
    @"binding_revision" : operation[@"binding_revision"],
    @"project_id" : projectId,
  };
  NSError *leaseError = nil;
  DSHLocalProjectLease *consumer = [projectAccess
      leaseWorkspaceRootRef:projectRoot
                       mode:DSHLocalProjectAccessModeRead
            includeMetadata:YES timeout:1 error:&leaseError];
  XCTAssertNotNil(consumer, @"%@", leaseError);
  XCTAssertTrue([projectAccess validateWorkspaceLeaseIdentity:consumer
                                                       rootRef:projectRoot
                                                         error:&leaseError],
                @"%@", leaseError);
}

- (void)testCoordinatorIsProcessGlobalAndReentrant {
  DSHSessionWorkspaceCoordinator *coordinator =
      [DSHSessionWorkspaceCoordinator sharedCoordinator];
  __block BOOL nested = NO;
  [coordinator performSync:^{
    XCTAssertTrue(coordinator.isExecutingOnQueue);
    [coordinator performSync:^{ nested = YES; }];
  }];
  XCTAssertTrue(nested);
  XCTAssertFalse(coordinator.isExecutingOnQueue);
  XCTAssertEqual(DSHSessionWorkspaceSerialQueue(),
                 [DSHSessionWorkspaceCoordinator sharedQueue]);
}

- (void)testNestedMarkerObjectsAndFractionalNumbersAreRejected {
  NSMutableDictionary *invalid = [[self candidate:1] mutableCopy];
  invalid[@"messages"] = @[@{ @"marker" : @1 }];
  NSError *error = nil;
  XCTAssertNil(([self.store casPersistSession:@{
    @"schema_version" : @1,
    @"operation_id" : DSHSessionTestOperationA,
    @"expected" : @{ @"schema_version" : @1, @"kind" : @"missing" },
    @"candidate_json" : [self jsonForCandidate:invalid],
  } error:&error]));
  XCTAssertEqual(error.code, DSHSessionSnapshotStoreErrorInvalidArgument);

  NSMutableDictionary *unknownConversation =
      [[self candidate:1][@"conversations"][0] mutableCopy];
  unknownConversation[@"unexpected"] = @YES;
  NSMutableDictionary *unknownRoot = [[self candidate:1] mutableCopy];
  unknownRoot[@"conversations"] = @[ unknownConversation ];
  error = nil;
  XCTAssertNil(([self.store casPersistSession:@{
    @"schema_version" : @1,
    @"operation_id" : DSHSessionTestOperationA,
    @"expected" : @{ @"schema_version" : @1, @"kind" : @"missing" },
    @"candidate_json" : [self jsonForCandidate:unknownRoot],
  } error:&error]));
  XCTAssertEqual(error.code, DSHSessionSnapshotStoreErrorInvalidArgument);

  // The fractional schema number must be rejected by the raw JSON gate before
  // the schema validator or canonical digest sees it.
  NSString *fractional = [[self jsonForCandidate:[self candidate:1]]
      stringByReplacingOccurrencesOfString:@"\"schema_version\":9"
                                 withString:@"\"schema_version\":9.5"];
  error = nil;
  XCTAssertNil(([self.store casPersistSession:@{
    @"schema_version" : @1,
    @"operation_id" : DSHSessionTestOperationB,
    @"expected" : @{ @"schema_version" : @1, @"kind" : @"missing" },
    @"candidate_json" : fractional,
  } error:&error]));
  XCTAssertEqual(error.code, DSHSessionSnapshotStoreErrorInvalidArgument);

  NSString *negativeZero = [[self jsonForCandidate:[self candidate:1]]
      stringByReplacingOccurrencesOfString:@"\"schema_version\":9"
                                 withString:@"\"schema_version\":-0"];
  error = nil;
  XCTAssertNil(([self.store casPersistSession:@{
    @"schema_version" : @1,
    @"operation_id" : DSHSessionTestOperationB,
    @"expected" : @{ @"schema_version" : @1, @"kind" : @"missing" },
    @"candidate_json" : negativeZero,
  } error:&error]));
  XCTAssertEqual(error.code, DSHSessionSnapshotStoreErrorInvalidArgument);
}

- (void)testConversationDeletedCleanupCanOutliveItsConversationOwner {
  NSMutableDictionary *orphan = [[self candidate:1] mutableCopy];
  orphan[@"active_conversation_id"] = NSNull.null;
  orphan[@"conversations"] = @[];
  orphan[@"messages"] = @[];
  orphan[@"agent_transcript_cleanup_outbox"] = @[@{
    @"schema_version" : @1,
    @"cleanup_id" : @"66666666-6666-4666-8666-666666666666",
    @"conversation_id" : @"chat-deleted",
    @"task_id" : @"55555555-5555-4555-8555-555555555555",
    @"attempt_id" : @"77777777-7777-4777-8777-777777777777",
    @"transcript_ref" : @"88888888-8888-4888-8888-888888888888",
    @"transcript_sha256" :
        @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    @"reason" : @"conversation_deleted",
    @"created_at" : @"2026-08-30T00:00:00.000Z",
  }];
  NSError *error = nil;
  NSDictionary *result = [self casWithOperation:
      @"99999999-9999-4999-8999-999999999999"
      expected:@{ @"schema_version" : @1, @"kind" : @"missing" }
      candidate:orphan
      error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"committed");
  NSDictionary *loaded = [self.store loadSessionSnapshotWithError:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(loaded[@"status"], @"present");
  XCTAssertTrue([loaded[@"session_json"] isKindOfClass:NSString.class]);
  if (![loaded[@"session_json"] isKindOfClass:NSString.class]) return;
  NSData *bytes = [loaded[@"session_json"] dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *session = [NSJSONSerialization JSONObjectWithData:bytes
                                                           options:0
                                                             error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(session[@"agent_transcript_cleanup_outbox"][0]
                               [@"task_id"],
                        @"55555555-5555-4555-8555-555555555555");
}

- (void)testAgentTranscriptCleanupBindsExactTaskAndRejectsMissingWrongOrExtraTask {
  NSError *error = nil;
  NSDictionary *candidate = [self candidateWithAgentTranscriptCleanup];
  NSDictionary *result = [self casWithOperation:
      @"abababab-abab-4bab-8bab-abababababab"
      expected:@{ @"schema_version" : @1, @"kind" : @"missing" }
      candidate:candidate
      error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"committed");
  NSDictionary *loaded = [self.store loadSessionSnapshotWithError:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(loaded[@"session_json"], [self jsonForCandidate:candidate]);
  if (![result[@"snapshot"] isKindOfClass:NSDictionary.class]) return;

  NSDictionary *expected = @{
    @"schema_version" : @1,
    @"kind" : @"present",
    @"snapshot" : result[@"snapshot"],
  };
  NSMutableArray<NSDictionary *> *invalidCandidates = [NSMutableArray array];

  NSMutableDictionary *missing = [candidate mutableCopy];
  NSMutableDictionary *cleanup =
      [candidate[@"agent_transcript_cleanup_outbox"][0] mutableCopy];
  [cleanup removeObjectForKey:@"task_id"];
  missing[@"agent_transcript_cleanup_outbox"] = @[ cleanup ];
  [invalidCandidates addObject:missing];

  NSMutableDictionary *wrong = [candidate mutableCopy];
  cleanup = [candidate[@"agent_transcript_cleanup_outbox"][0] mutableCopy];
  cleanup[@"task_id"] = @"12121212-1212-4212-8212-121212121212";
  wrong[@"agent_transcript_cleanup_outbox"] = @[ cleanup ];
  [invalidCandidates addObject:wrong];

  NSMutableDictionary *extra = [candidate mutableCopy];
  cleanup = [candidate[@"agent_transcript_cleanup_outbox"][0] mutableCopy];
  cleanup[@"task"] = cleanup[@"task_id"];
  extra[@"agent_transcript_cleanup_outbox"] = @[ cleanup ];
  [invalidCandidates addObject:extra];

  for (NSUInteger index = 0; index < invalidCandidates.count; index += 1) {
    NSString *operationID = [NSString stringWithFormat:
        @"acacacac-acac-4cac-8cac-%012lx", (unsigned long)(index + 1)];
    error = nil;
    XCTAssertNil(([self.store casPersistSession:@{
      @"schema_version" : @1,
      @"operation_id" : operationID,
      @"expected" : expected,
      @"candidate_json" : [self jsonForCandidate:invalidCandidates[index]],
    } error:&error]));
    XCTAssertEqual(error.code, DSHSessionSnapshotStoreErrorInvalidArgument);
  }
}

- (void)testSessionEventCorrelationsFollowTheAgentJournal {
  NSError *error = nil;
  NSDictionary *result = [self casWithOperation:
      @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
      expected:@{ @"schema_version" : @1, @"kind" : @"missing" }
      candidate:[self candidateWithAgentToolEvent]
      error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"committed");

  NSMutableDictionary *invalid =
      [[self candidateWithAgentToolEvent] mutableCopy];
  NSMutableDictionary *event = [invalid[@"session_events"][0] mutableCopy];
  event[@"status"] = @"ok";
  invalid[@"session_events"] = @[ event ];
  error = nil;
  XCTAssertNil(([self.store casPersistSession:@{
    @"schema_version" : @1,
    @"operation_id" : @"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
    @"expected" : result[@"snapshot"] == nil
        ? @{ @"schema_version" : @1, @"kind" : @"missing" }
        : @{ @"schema_version" : @1,
             @"kind" : @"present",
             @"snapshot" : result[@"snapshot"] },
    @"candidate_json" : [self jsonForCandidate:invalid],
  } error:&error]));
  XCTAssertEqual(error.code, DSHSessionSnapshotStoreErrorInvalidArgument);
}

- (void)testRepeatedToolCallFallsBackFromNullPreviousApprovalToJournalAuthority {
  NSMutableDictionary *candidate =
      [self mutableJSONCopyOfDictionary:[self candidateWithAgentToolEvent]];
  NSMutableDictionary *conversation = candidate[@"conversations"][0];
  NSMutableDictionary *attempt = conversation[@"attempts"][0];
  NSMutableDictionary *journal = attempt[@"agent"];
  NSMutableDictionary *root = journal[@"root"];
  root[@"capabilities"] = @[ @"file_read", @"file_write" ];
  NSMutableDictionary *call = journal[@"batch"][0];
  NSString *approval = @"abababab-abab-4bab-8bab-abababababab";
  NSString *resultDigest =
      @"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
  call[@"name"] = @"write_file";
  call[@"safe_summary_key"] = @"agent.write_file";
  call[@"access"] = @"conversation_confirm";
  call[@"approval_token"] = @"bound-approval-token";
  call[@"approval_decision"] = @"allow_once";
  call[@"approval_reference"] = approval;
  call[@"native_row_revision"] = @1;
  call[@"receipt"] = @{
    @"schema_version" : @1,
    @"call_id" : call[@"call_id"],
    @"name" : call[@"name"],
    @"arguments_sha256" : call[@"arguments_sha256"],
    @"result_sha256" : resultDigest,
    @"result_bytes" : @1,
    @"truncated" : @NO,
    @"duration_ms" : @1,
    @"outcome" : @"ok",
    @"failure_code" : NSNull.null,
    @"approval_reference" : approval,
  };
  NSMutableDictionary *presentation = candidate[@"session_events"][0];
  presentation[@"safe_summary_key"] = @"agent.write_file";
  NSMutableDictionary *repeatedPresentation = [presentation mutableCopy];
  repeatedPresentation[@"event_id"] =
      @"77777777-7777-4777-8777-777777777777";
  repeatedPresentation[@"seq"] = @1;
  repeatedPresentation[@"status"] = @"running";
  NSMutableDictionary *result = [presentation mutableCopy];
  result[@"event_id"] = @"88888888-8888-4888-8888-888888888888";
  result[@"seq"] = @2;
  result[@"kind"] = @"tool_result";
  result[@"status"] = @"ok";
  result[@"result_sha256"] = resultDigest;
  result[@"approval_reference"] = approval;
  candidate[@"session_events"] = @[
    presentation,
    repeatedPresentation,
    result,
  ];

  NSError *error = nil;
  NSDictionary *commit = [self casWithOperation:DSHSessionTestOperationA
      expected:@{ @"schema_version" : @1, @"kind" : @"missing" }
      candidate:candidate error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(commit[@"status"], @"committed");
}

- (void)testAgentAttemptAcceptsFrozenVisibleHistoryBeforeFirstRound {
  NSError *error = nil;
  NSDictionary *result = [self casWithOperation:DSHSessionTestOperationA
      expected:@{ @"schema_version" : @1, @"kind" : @"missing" }
      candidate:[self visibleHistoryCandidateWithAgent:YES completedRound:NO]
      error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"committed");
}

- (void)testNonAgentAttemptStillRejectsVisibleHistoryWithoutRoundProvenance {
  NSError *error = nil;
  XCTAssertNil(([self casWithOperation:DSHSessionTestOperationA
      expected:@{ @"schema_version" : @1, @"kind" : @"missing" }
      candidate:[self visibleHistoryCandidateWithAgent:NO completedRound:NO]
      error:&error]));
  XCTAssertEqual(error.code, DSHSessionSnapshotStoreErrorInvalidArgument);
}

- (void)testAgentAttemptAcceptsDistinctControllerAndProviderHistoryDigests {
  NSError *error = nil;
  NSDictionary *result = [self casWithOperation:DSHSessionTestOperationA
      expected:@{ @"schema_version" : @1, @"kind" : @"missing" }
      candidate:[self visibleHistoryCandidateWithAgent:YES completedRound:YES]
      error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"committed");
}

- (void)testNonAgentAttemptStillRejectsDistinctRoundHistoryDigest {
  NSError *error = nil;
  XCTAssertNil(([self casWithOperation:DSHSessionTestOperationA
      expected:@{ @"schema_version" : @1, @"kind" : @"missing" }
      candidate:[self visibleHistoryCandidateWithAgent:NO completedRound:YES]
      error:&error]));
  XCTAssertEqual(error.code, DSHSessionSnapshotStoreErrorInvalidArgument);
}

- (void)testSharedJSBeginRoundFixtureCommitsThroughNativeStore {
  NSDictionary *candidate = [self sharedFixtureNamed:@"agent-begin-round-session"];
  XCTAssertNotNil(candidate);
  if (candidate == nil) return;
  NSError *error = nil;
  NSDictionary *result = [self casWithOperation:DSHSessionTestOperationA
      expected:@{ @"schema_version" : @1, @"kind" : @"missing" }
      candidate:candidate error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"committed");
}

- (void)testSharedJSFirstRoundFixtureCommitsThroughNativeStore {
  NSDictionary *candidate =
      [self sharedFixtureNamed:@"agent-first-round-complete-session"];
  XCTAssertNotNil(candidate);
  if (candidate == nil) return;
  NSError *error = nil;
  NSDictionary *result = [self casWithOperation:DSHSessionTestOperationA
      expected:@{ @"schema_version" : @1, @"kind" : @"missing" }
      candidate:candidate error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"committed");
}

- (void)testSharedJSNextRoundAfterToolFixtureCommitsThroughNativeStore {
  NSDictionary *candidate =
      [self sharedFixtureNamed:@"agent-next-round-after-tool-session"];
  XCTAssertNotNil(candidate);
  if (candidate == nil) return;
  NSError *error = nil;
  NSDictionary *result = [self casWithOperation:DSHSessionTestOperationA
      expected:@{ @"schema_version" : @1, @"kind" : @"missing" }
      candidate:candidate error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"committed");
}

- (void)testRetainedAgentEventsBeyond512CommitWithoutDroppingHistory {
  NSDictionary *fixture = [self sharedFixtureNamed:@"agent-next-round-after-tool-session"];
  NSMutableDictionary *candidate = [fixture mutableCopy];
  NSMutableArray *conversations = [NSMutableArray array];
  NSMutableArray *events = [NSMutableArray array];
  NSString *source = [self jsonForCandidate:fixture];
  NSRegularExpression *uuidPattern = [NSRegularExpression regularExpressionWithPattern:
      @"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}" options:0 error:nil];
  for (NSUInteger copy = 0; copy < 40; copy++) {
    NSMutableDictionary *ids = [NSMutableDictionary dictionary];
    NSString *text = source;
    for (NSTextCheckingResult *match in [uuidPattern matchesInString:source options:0 range:NSMakeRange(0, source.length)]) {
      NSString *old = [source substringWithRange:match.range];
      if (ids[old] == nil) {
        ids[old] = [NSString stringWithFormat:@"%08lx-1111-4111-8111-%012lx", (unsigned long)(copy + 1), (unsigned long)(ids.count + 1)];
        text = [text stringByReplacingOccurrencesOfString:old withString:ids[old]];
      }
    }
    NSDictionary *cloned = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingMutableContainers error:nil];
    for (NSMutableDictionary *conversation in cloned[@"conversations"]) {
      for (NSMutableDictionary *attempt in conversation[@"attempts"]) {
        for (NSMutableDictionary *round in attempt[@"rounds"]) {
          round[@"provider_response_id"] = [NSString stringWithFormat:@"%@-%lu", round[@"provider_response_id"], (unsigned long)copy];
        }
      }
    }
    [conversations addObjectsFromArray:cloned[@"conversations"]];
    [events addObjectsFromArray:cloned[@"session_events"]];
  }
  candidate[@"conversations"] = conversations;
  candidate[@"session_events"] = events;
  candidate[@"active_conversation_id"] = conversations[0][@"id"];
  candidate[@"messages"] = conversations[0][@"messages"];
  XCTAssertGreaterThan(events.count, 512U);
  NSError *error = nil;
  NSDictionary *result = [self casWithOperation:DSHSessionTestOperationA
      expected:@{ @"schema_version": @1, @"kind": @"missing" }
      candidate:candidate error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"committed");
}

- (void)testRetainedAgentEventLimitStillRejectsOversizedCandidates {
  NSMutableDictionary *candidate = [self mutableSharedFixtureNamed:@"agent-next-round-after-tool-session"];
  NSDictionary *event = candidate[@"session_events"][0];
  NSMutableArray *events = [NSMutableArray array];
  for (NSUInteger index = 0; index < 8193; index++) [events addObject:event];
  candidate[@"session_events"] = events;
  NSError *error = nil;
  XCTAssertNil(([self casWithOperation:DSHSessionTestOperationA
      expected:@{ @"schema_version": @1, @"kind": @"missing" }
      candidate:candidate error:&error]));
  XCTAssertEqual(error.code, DSHSessionSnapshotStoreErrorInvalidArgument);
}

- (void)testSharedJSInterruptedRecoveryFixtureCommitsThroughNativeStore {
  NSDictionary *candidate =
      [self sharedFixtureNamed:@"agent-interrupted-recovery-session"];
  XCTAssertNotNil(candidate);
  if (candidate == nil) return;
  NSError *error = nil;
  NSDictionary *result = [self casWithOperation:DSHSessionTestOperationA
      expected:@{ @"schema_version" : @1, @"kind" : @"missing" }
      candidate:candidate error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"committed");
  // Every recovered attempt must survive the exact schema-9 root validator:
  // interrupted attempts keep their journal phase as forensic evidence and
  // their failed/E_ATTEMPT_INTERRUPTED status, while their cleanup entries
  // reference the same journal transcript.
  NSDictionary *loaded = [self.store loadSessionSnapshotWithError:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(loaded[@"status"], @"present");
}

- (void)testLoadResultExposesWriterAndCurrentLaunchInstanceIds {
  NSError *error = nil;
  NSDictionary *missing = [self.store loadSessionSnapshotWithError:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(missing[@"writer_launch_instance_id"], NSNull.null);
  XCTAssertEqualObjects(missing[@"current_launch_instance_id"],
                        DSHSessionTestLaunch);

  NSDictionary *committed = [self casWithOperation:DSHSessionTestOperationA
      expected:@{ @"schema_version" : @1, @"kind" : @"missing" }
      candidate:[self candidate:1] error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(committed[@"status"], @"committed");
  NSDictionary *loaded = [self.store loadSessionSnapshotWithError:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(loaded[@"status"], @"present");
  XCTAssertEqualObjects(loaded[@"writer_launch_instance_id"],
                        DSHSessionTestLaunch);
  XCTAssertEqualObjects(loaded[@"current_launch_instance_id"],
                        DSHSessionTestLaunch);

  // A second store modelling the next process launch sees the persisted
  // writer id and its own current id, which is what the JS hydration layer
  // compares to decide stale-launch interruption.
  NSString *secondLaunch = @"99999999-9999-4999-8999-999999999999";
  DSHSessionSnapshotStore *relaunch = [[DSHSessionSnapshotStore alloc]
      initWithRootURL:self.rootURL
           sessionURL:self.store.sessionURL
      launchInstanceId:secondLaunch
            coordinator:nil
              faultHook:nil];
  XCTAssertNotNil(relaunch);
  NSError *relaunchError = nil;
  NSDictionary *relaunchLoad = [relaunch loadSessionSnapshotWithError:&relaunchError];
  XCTAssertNil(relaunchError);
  XCTAssertEqualObjects(relaunchLoad[@"status"], @"present");
  XCTAssertEqualObjects(relaunchLoad[@"writer_launch_instance_id"],
                        DSHSessionTestLaunch);
  XCTAssertEqualObjects(relaunchLoad[@"current_launch_instance_id"],
                        secondLaunch);
}

- (void)testInterruptedAttemptWithKeptJournalAndCleanupEntryValidates {
  // The hydration recovery keeps the Agent journal phase as forensic evidence
  // while marking the attempt failed with E_ATTEMPT_INTERRUPTED and enqueuing
  // a reason-"failed" cleanup entry; a journal-less zombie (the device's
  // failed fresh send) is interrupted without any entry.  The exact shape is
  // exercised through the shared parity fixture above; this test pins the
  // narrower rule that a failed interrupted attempt may retain any live
  // journal phase and an active_round-free projection.
  NSError *error = nil;
  NSDictionary *candidate =
      [self mutableSharedFixtureNamed:@"agent-interrupted-recovery-session"];
  XCTAssertNotNil(candidate);
  if (candidate == nil) return;
  NSUInteger interrupted = 0;
  NSUInteger journaled = 0;
  NSUInteger journalless = 0;
  for (NSMutableDictionary *conversation in candidate[@"conversations"]) {
    for (NSMutableDictionary *attempt in conversation[@"attempts"]) {
      if ([attempt[@"status"] isEqual:@"failed"] &&
          [attempt[@"failure_code"] isEqual:@"E_ATTEMPT_INTERRUPTED"]) {
        interrupted += 1;
        XCTAssertEqualObjects(attempt[@"active_round"], NSNull.null);
        if ([attempt[@"agent"] isKindOfClass:NSDictionary.class]) {
          journaled += 1;
        } else {
          XCTAssertEqualObjects(attempt[@"agent"], NSNull.null);
          XCTAssertEqualObjects(attempt[@"journal_revision"], @0);
          journalless += 1;
        }
      }
    }
  }
  XCTAssertGreaterThanOrEqual(interrupted, 30U);
  XCTAssertGreaterThanOrEqual(journaled, 30U);
  XCTAssertEqual(journalless, 1U);
  NSDictionary *result = [self casWithOperation:DSHSessionTestOperationA
      expected:@{ @"schema_version" : @1, @"kind" : @"missing" }
      candidate:candidate error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"committed");
}

- (void)testSharedClaudeCodeToolRoundFixtureCommitsThroughNativeStore {
  NSDictionary *candidate =
      [self sharedFixtureNamed:@"claude-code-tool-round-session"];
  XCTAssertNotNil(candidate);
  if (candidate == nil) return;
  NSError *error = nil;
  NSDictionary *result = [self casWithOperation:DSHSessionTestOperationA
      expected:@{ @"schema_version" : @1, @"kind" : @"missing" }
      candidate:candidate error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"committed");
}

- (void)testSharedCodexRoundFixtureCommitsThroughNativeStore {
  NSDictionary *candidate = [self sharedFixtureNamed:@"codex-round-session"];
  XCTAssertNotNil(candidate);
  if (candidate == nil) return;
  NSError *error = nil;
  NSDictionary *result = [self casWithOperation:DSHSessionTestOperationA
      expected:@{ @"schema_version" : @1, @"kind" : @"missing" }
      candidate:candidate error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"committed");
}

- (void)testLegacySessionWithoutHarnessIdStillCommitsThroughNativeStore {
  // The pre-adapter snapshot carries no harness_id on attempts or receipts;
  // the native store must keep accepting it so old sessions hydrate as DSH.
  NSDictionary *candidate =
      [self sharedFixtureNamed:@"legacy-pre-harness-session"];
  XCTAssertNotNil(candidate);
  if (candidate == nil) return;
  NSDictionary *attempt = candidate[@"conversations"][0][@"attempts"][0];
  XCTAssertNil(attempt[@"harness_id"]);
  XCTAssertNotNil(candidate);
  if (candidate == nil) return;
  NSError *error = nil;
  NSDictionary *result = [self casWithOperation:DSHSessionTestOperationA
      expected:@{ @"schema_version" : @1, @"kind" : @"missing" }
      candidate:candidate error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"committed");
}

- (void)testRejectsReceiptWhoseHarnessDoesNotOwnItsModel {
  NSMutableDictionary *candidate =
      [self mutableSharedFixtureNamed:@"claude-code-tool-round-session"];
  XCTAssertNotNil(candidate);
  if (candidate == nil) return;
  NSMutableDictionary *attempt = candidate[@"conversations"][0][@"attempts"][0];
  XCTAssertEqualObjects(attempt[@"harness_id"], @"claude-code");
  NSMutableDictionary *round = attempt[@"rounds"][0];
  XCTAssertEqualObjects(round[@"harness_id"], @"claude-code");
  XCTAssertEqualObjects(round[@"model"], @"claude-sonnet-5");
  round[@"harness_id"] = @"codex";
  NSError *error = nil;
  XCTAssertNil(([self casWithOperation:DSHSessionTestOperationA
      expected:@{ @"schema_version" : @1, @"kind" : @"missing" }
      candidate:candidate error:&error]));
  XCTAssertEqual(error.code, DSHSessionSnapshotStoreErrorInvalidArgument);
}

- (void)testRejectsAttemptWhoseHarnessDoesNotOwnItsModel {
  NSMutableDictionary *candidate =
      [self mutableSharedFixtureNamed:@"codex-round-session"];
  XCTAssertNotNil(candidate);
  if (candidate == nil) return;
  NSMutableDictionary *attempt = candidate[@"conversations"][0][@"attempts"][0];
  XCTAssertEqualObjects(attempt[@"harness_id"], @"codex");
  attempt[@"harness_id"] = @"dsh";
  NSError *error = nil;
  XCTAssertNil(([self casWithOperation:DSHSessionTestOperationA
      expected:@{ @"schema_version" : @1, @"kind" : @"missing" }
      candidate:candidate error:&error]));
  XCTAssertEqual(error.code, DSHSessionSnapshotStoreErrorInvalidArgument);
}

- (void)testFailedAttemptAcceptsAnAgentFailureCode {
  // An Agent round settles its attempt with the Agent's own code. Rejecting
  // those codes here made the durable write fail, so the user saw a
  // persistence error instead of the real cause (a stale workspace root).
  NSArray<NSString *> *codes = @[
    @"E_AGENT_ROOT_STALE", @"E_AGENT_CAPABILITY", @"E_ATTEMPT_INTERRUPTED", @"E_COMPLETION_TIMEOUT",
  ];
  NSDictionary *missing = @{ @"schema_version" : @1, @"kind" : @"missing" };
  for (NSString *code in codes) {
    NSMutableDictionary *candidate = [self failedAttemptCandidateWithCode:code];
    DSHSessionSnapshotStore *store = [self storeAtFreshRoot];
    NSError *error = nil;
    NSDictionary *result = [store casPersistSession:[self casRequestWithOperation:DSHSessionTestOperationA
                                                                         expected:missing
                                                                        candidate:candidate]
                                              error:&error];
    XCTAssertNotNil(result, @"%@ rejected: %@", code, error);
    XCTAssertEqualObjects(result[@"status"], @"committed", @"code %@", code);
    NSDictionary *loaded = [store loadSessionSnapshotWithError:&error];
    XCTAssertEqualObjects(loaded[@"status"], @"present");
    NSString *serialized = loaded[@"session_json"];
    XCTAssertTrue([serialized containsString:code]);

  }
}

- (void)testFailedAttemptStillRejectsAnUnknownFailureCode {
  NSDictionary *missing = @{ @"schema_version" : @1, @"kind" : @"missing" };
  NSMutableDictionary *candidate =
      [self failedAttemptCandidateWithCode:@"E_AGENT_NOT_A_REAL_CODE"];
  NSError *error = nil;
  NSDictionary *result = [self casWithOperation:DSHSessionTestOperationA
                                       expected:missing
                                      candidate:candidate
                                          error:&error];
  XCTAssertNil(result);
  XCTAssertEqual(error.code, DSHSessionSnapshotStoreErrorInvalidArgument);
}

- (void)testSharedJSGitPushConversationGrantFixtureCommitsThroughNativeStore {
  // git_push follows the git_commit pattern: the JS controller persisted a
  // conversation-scoped grant with tool_family git_push and an
  // allow_conversation decision. The native validator must accept exactly
  // that shape.
  NSDictionary *candidate =
      [self sharedFixtureNamed:@"agent-git-push-conversation-session"];
  XCTAssertNotNil(candidate);
  if (candidate == nil) return;
  NSString *json = [[NSString alloc] initWithData:
      [NSJSONSerialization dataWithJSONObject:candidate options:0 error:nil]
                                          encoding:NSUTF8StringEncoding];
  XCTAssertTrue([json containsString:@"\"tool_family\":\"git_push\""]);
  XCTAssertTrue([json containsString:@"\"approval_decision\":\"allow_conversation\""]);
  NSError *error = nil;
  NSDictionary *result = [self casWithOperation:DSHSessionTestOperationA
      expected:@{ @"schema_version" : @1, @"kind" : @"missing" }
      candidate:candidate error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"committed");
}

- (void)testSharedJSGitPushGrantRejectsOnceOnlyAccessForGitPush {
  NSMutableDictionary *candidate =
      [self mutableSharedFixtureNamed:@"agent-git-push-conversation-session"];
  XCTAssertNotNil(candidate);
  if (candidate == nil) return;
  BOOL mutated = NO;
  for (NSMutableDictionary *conversation in candidate[@"conversations"]) {
    for (NSMutableDictionary *attempt in conversation[@"attempts"]) {
      id agent = attempt[@"agent"];
      if (![agent isKindOfClass:NSDictionary.class]) continue;
      for (NSMutableDictionary *call in agent[@"batch"]) {
        if ([call[@"name"] isEqual:@"git_push"]) {
          call[@"access"] = @"confirm_once";
          mutated = YES;
        }
      }
    }
  }
  XCTAssertTrue(mutated, @"fixture carries no git_push call to mutate");
  NSError *error = nil;
  XCTAssertNil(([self casWithOperation:DSHSessionTestOperationA
      expected:@{ @"schema_version" : @1, @"kind" : @"missing" }
      candidate:candidate error:&error]));
  XCTAssertEqual(error.code, DSHSessionSnapshotStoreErrorInvalidArgument);
}

- (void)testSharedJSDeniedCallFixtureCommitsThroughNativeStore {
  // JS-to-native parity for a user denial: the journal is still frozen on
  // the batch, the denied call carries a native denied receipt with
  // E_AGENT_DENIED_BY_USER and a null approval reference, and the session
  // events hold the decide_approval marker followed by the structured denied
  // tool result.
  NSDictionary *candidate = [self sharedFixtureNamed:@"agent-denied-call-session"];
  XCTAssertNotNil(candidate);
  if (candidate == nil) return;
  NSError *error = nil;
  NSDictionary *result = [self casWithOperation:DSHSessionTestOperationA
      expected:@{ @"schema_version" : @1, @"kind" : @"missing" }
      candidate:candidate error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"committed");
  NSDictionary *journal = candidate[@"conversations"][0][@"attempts"][0][@"agent"];
  NSDictionary *deniedCall = nil;
  for (NSDictionary *call in journal[@"batch"]) {
    if ([call[@"call_id"] isEqual:@"commit-call"]) deniedCall = call;
  }
  XCTAssertEqualObjects(deniedCall[@"approval_decision"], @"denied");
  XCTAssertEqualObjects(deniedCall[@"approval_token"], NSNull.null);
  XCTAssertEqualObjects(deniedCall[@"approval_reference"], NSNull.null);
  XCTAssertEqualObjects(deniedCall[@"receipt"][@"outcome"], @"denied");
  XCTAssertEqualObjects(deniedCall[@"receipt"][@"failure_code"],
                        @"E_AGENT_DENIED_BY_USER");
}

- (void)testSharedJSDeniedCallFixtureRejectsReferenceOnDeniedResult {
  // A denied result that claims an approval reference is not a user denial:
  // the exact denied shape is the only accepted null-reference settlement.
  NSMutableDictionary *candidate =
      [self mutableSharedFixtureNamed:@"agent-denied-call-session"];
  XCTAssertNotNil(candidate);
  if (candidate == nil) return;
  for (NSMutableDictionary *event in candidate[@"session_events"]) {
    if ([event[@"kind"] isEqual:@"tool_result"] &&
        [event[@"call_id"] isEqual:@"commit-call"]) {
      event[@"approval_reference"] = @"abababab-abab-4bab-8bab-abababababab";
      break;
    }
  }
  NSError *error = nil;
  XCTAssertNil(([self casWithOperation:DSHSessionTestOperationA
      expected:@{ @"schema_version" : @1, @"kind" : @"missing" }
      candidate:candidate error:&error]));
  XCTAssertEqual(error.code, DSHSessionSnapshotStoreErrorInvalidArgument);
}

- (void)testSharedJSDeniedCallFixtureRejectsForeignFailureCodeOnDeniedResult {
  // Only the user-denial failure code may settle a denied call with a null
  // approval reference after its decide_approval marker.
  NSMutableDictionary *candidate =
      [self mutableSharedFixtureNamed:@"agent-denied-call-session"];
  XCTAssertNotNil(candidate);
  if (candidate == nil) return;
  for (NSMutableDictionary *event in candidate[@"session_events"]) {
    if ([event[@"kind"] isEqual:@"tool_result"] &&
        [event[@"call_id"] isEqual:@"commit-call"]) {
      event[@"failure_code"] = @"E_AGENT_TOOL_FAILED";
      break;
    }
  }
  NSMutableArray *conversations = candidate[@"conversations"];
  NSMutableDictionary *attempt = conversations[0][@"attempts"][0];
  for (NSMutableDictionary *call in attempt[@"agent"][@"batch"]) {
    if ([call[@"call_id"] isEqual:@"commit-call"]) {
      call[@"receipt"][@"failure_code"] = @"E_AGENT_TOOL_FAILED";
      break;
    }
  }
  NSError *error = nil;
  XCTAssertNil(([self casWithOperation:DSHSessionTestOperationA
      expected:@{ @"schema_version" : @1, @"kind" : @"missing" }
      candidate:candidate error:&error]));
  XCTAssertEqual(error.code, DSHSessionSnapshotStoreErrorInvalidArgument);
}

- (void)testHistoricalToolEventRejectsRoundMissingFromAttemptReceipts {
  NSMutableDictionary *candidate =
      [self mutableSharedFixtureNamed:@"agent-next-round-after-tool-session"];
  XCTAssertNotNil(candidate);
  if (candidate == nil) return;
  for (NSMutableDictionary *event in candidate[@"session_events"]) {
    if ([event[@"kind"] isEqual:@"approval"] &&
        [event[@"call_id"] isEqual:@"write-call"]) {
      event[@"round_index"] = @2;
      break;
    }
  }
  NSError *error = nil;
  XCTAssertNil(([self casWithOperation:DSHSessionTestOperationA
      expected:@{ @"schema_version" : @1, @"kind" : @"missing" }
      candidate:candidate error:&error]));
  XCTAssertEqual(error.code, DSHSessionSnapshotStoreErrorInvalidArgument);
}

- (void)testHistoricalToolResultRejectsDigestMismatchAfterToolCallReplay {
  NSMutableDictionary *candidate =
      [self mutableSharedFixtureNamed:@"agent-next-round-after-tool-session"];
  XCTAssertNotNil(candidate);
  if (candidate == nil) return;
  for (NSMutableDictionary *event in candidate[@"session_events"]) {
    if ([event[@"kind"] isEqual:@"tool_result"] &&
        [event[@"call_id"] isEqual:@"write-call"]) {
      event[@"arguments_sha256"] =
          @"4444444444444444444444444444444444444444444444444444444444444444";
      break;
    }
  }
  NSError *error = nil;
  XCTAssertNil(([self casWithOperation:DSHSessionTestOperationA
      expected:@{ @"schema_version" : @1, @"kind" : @"missing" }
      candidate:candidate error:&error]));
  XCTAssertEqual(error.code, DSHSessionSnapshotStoreErrorInvalidArgument);
}

- (void)testHistoricalToolResultRejectsApprovalMismatchAfterToolCallReplay {
  NSMutableDictionary *candidate =
      [self mutableSharedFixtureNamed:@"agent-next-round-after-tool-session"];
  XCTAssertNotNil(candidate);
  if (candidate == nil) return;
  for (NSMutableDictionary *event in candidate[@"session_events"]) {
    if ([event[@"kind"] isEqual:@"tool_result"] &&
        [event[@"call_id"] isEqual:@"write-call"]) {
      event[@"approval_reference"] =
          @"abababab-abab-4bab-8bab-abababababab";
      break;
    }
  }
  NSError *error = nil;
  XCTAssertNil(([self casWithOperation:DSHSessionTestOperationA
      expected:@{ @"schema_version" : @1, @"kind" : @"missing" }
      candidate:candidate error:&error]));
  XCTAssertEqual(error.code, DSHSessionSnapshotStoreErrorInvalidArgument);
}

- (void)testSchema8HydrateCanPersistExactCurrentAgentV3Shape {
  NSDictionary *legacyEnvelope = @{
    @"schema_version" : @2,
    @"writer_launch_instance_id" : DSHSessionTestLaunch,
    @"session" : [self legacyV2SessionWithMilliseconds:@"123"],
  };
  NSData *legacyBytes = DSHWorkspaceCanonicalJSONData(legacyEnvelope, nil);
  XCTAssertNotNil(legacyBytes);
  [self writePublishedV2Bytes:legacyBytes toURL:self.store.sessionURL];
  NSError *error = nil;
  NSDictionary *loaded = [self.store loadSessionSnapshotWithError:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(loaded[@"status"], @"legacy_present");

  NSDictionary *candidate = [self candidateWithAgentToolEvent];
  NSDictionary *result = [self casWithOperation:DSHSessionTestOperationA
                                         expected:@{
                                           @"schema_version" : @1,
                                           @"kind" : @"legacy_present",
                                           @"legacy" : loaded[@"legacy"],
                                         }
                                        candidate:candidate
                                            error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"committed");
  loaded = [self.store loadSessionSnapshotWithError:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(loaded[@"status"], @"present");
  XCTAssertEqualObjects(loaded[@"session_json"],
                        [self jsonForCandidate:candidate]);
}

- (void)testAgentV2AttemptJournalAndCallAreRejected {
  NSMutableDictionary *candidate =
      [[self candidateWithAgentToolEvent] mutableCopy];
  NSMutableDictionary *conversation =
      [candidate[@"conversations"][0] mutableCopy];
  NSMutableDictionary *attempt =
      [conversation[@"attempts"][0] mutableCopy];
  NSMutableDictionary *journal = [attempt[@"agent"] mutableCopy];
  NSMutableDictionary *call = [journal[@"batch"][0] mutableCopy];
  call[@"schema_version"] = @2;
  journal[@"schema_version"] = @2;
  journal[@"batch"] = @[ call ];
  attempt[@"schema_version"] = @2;
  attempt[@"agent"] = journal;
  conversation[@"attempts"] = @[ attempt ];
  candidate[@"conversations"] = @[ conversation ];

  NSError *error = nil;
  XCTAssertNil(([self.store casPersistSession:@{
    @"schema_version" : @1,
    @"operation_id" : DSHSessionTestOperationA,
    @"expected" : @{ @"schema_version" : @1, @"kind" : @"missing" },
    @"candidate_json" : [self jsonForCandidate:candidate],
  } error:&error]));
  XCTAssertEqual(error.code, DSHSessionSnapshotStoreErrorInvalidArgument);
}

- (void)testCancelEventsPersistLoadAndRejectNonExactSourceTargetEnvelope {
  NSError *error = nil;
  NSDictionary *candidate = [self candidateWithAgentCancelEvents];
  NSDictionary *result = [self casWithOperation:
      @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
      expected:@{ @"schema_version" : @1, @"kind" : @"missing" }
      candidate:candidate
      error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"committed");

  NSDictionary *loaded = [self.store loadSessionSnapshotWithError:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(loaded[@"status"], @"present");
  XCTAssertEqualObjects(loaded[@"session_json"], [self jsonForCandidate:candidate]);
  if (![loaded[@"session_json"] isKindOfClass:NSString.class]) return;
  NSData *loadedBytes = [loaded[@"session_json"] dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *loadedSession = [NSJSONSerialization JSONObjectWithData:loadedBytes
                                                                 options:0
                                                                   error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(loadedSession[@"session_events"],
                        candidate[@"session_events"]);
  XCTAssertEqualObjects(loadedSession[@"conversations"][0][@"attempts"][0]
                                      [@"turn_id"],
                        @"11111111-1111-4111-8111-111111111111");
  XCTAssertEqualObjects(loadedSession[@"conversations"][0][@"attempts"][0]
                                      [@"agent"][@"phase"],
                        @"execution_intent");

  NSDictionary *expected = @{
    @"schema_version" : @1,
    @"kind" : @"present",
    @"snapshot" : result[@"snapshot"],
  };
  NSMutableArray<NSDictionary *> *invalidCandidates = [NSMutableArray array];

  NSMutableDictionary *extra = [candidate mutableCopy];
  NSMutableArray *events = [candidate[@"session_events"] mutableCopy];
  NSMutableDictionary *event = [events[0] mutableCopy];
  event[@"source_event_id"] = event[@"event_id"];
  events[0] = event;
  extra[@"session_events"] = events;
  [invalidCandidates addObject:extra];

  NSMutableDictionary *nonCanonicalSource = [candidate mutableCopy];
  events = [candidate[@"session_events"] mutableCopy];
  event = [events[0] mutableCopy];
  event[@"event_id"] = @"77777777-7777-4777-8777-77777777777A";
  event[@"approval_reference"] = event[@"event_id"];
  events[0] = event;
  nonCanonicalSource[@"session_events"] = events;
  [invalidCandidates addObject:nonCanonicalSource];

  NSMutableDictionary *unknownAttempt = [candidate mutableCopy];
  events = [candidate[@"session_events"] mutableCopy];
  event = [events[0] mutableCopy];
  event[@"attempt_id"] = @"12121212-1212-4212-8212-121212121212";
  events[0] = event;
  unknownAttempt[@"session_events"] = events;
  [invalidCandidates addObject:unknownAttempt];

  NSMutableDictionary *wrongReference = [candidate mutableCopy];
  events = [candidate[@"session_events"] mutableCopy];
  event = [events[0] mutableCopy];
  event[@"approval_reference"] = @"88888888-8888-4888-8888-888888888888";
  events[0] = event;
  wrongReference[@"session_events"] = events;
  [invalidCandidates addObject:wrongReference];

  NSMutableDictionary *wrongReason = [candidate mutableCopy];
  events = [candidate[@"session_events"] mutableCopy];
  event = [events[1] mutableCopy];
  event[@"failure_code"] = @"E_AGENT_TOOL_FAILED";
  events[1] = event;
  wrongReason[@"session_events"] = events;
  [invalidCandidates addObject:wrongReason];

  NSMutableDictionary *brokenAttemptTarget = [candidate mutableCopy];
  events = [candidate[@"session_events"] mutableCopy];
  event = [events[0] mutableCopy];
  event[@"call_id"] = @"call-1";
  events[0] = event;
  brokenAttemptTarget[@"session_events"] = events;
  [invalidCandidates addObject:brokenAttemptTarget];

  NSMutableDictionary *brokenRoundTarget = [candidate mutableCopy];
  events = [candidate[@"session_events"] mutableCopy];
  event = [events[1] mutableCopy];
  event[@"arguments_sha256"] =
      @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  events[1] = event;
  brokenRoundTarget[@"session_events"] = events;
  [invalidCandidates addObject:brokenRoundTarget];

  NSMutableDictionary *wrongToolDigest = [candidate mutableCopy];
  events = [candidate[@"session_events"] mutableCopy];
  event = [events[2] mutableCopy];
  event[@"arguments_sha256"] =
      @"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
  events[2] = event;
  wrongToolDigest[@"session_events"] = events;
  [invalidCandidates addObject:wrongToolDigest];

  NSMutableDictionary *oversizedCall = [candidate mutableCopy];
  events = [candidate[@"session_events"] mutableCopy];
  event = [events[2] mutableCopy];
  event[@"call_id"] = [@"a" stringByPaddingToLength:129
                                           withString:@"a"
                                      startingAtIndex:0];
  events[2] = event;
  oversizedCall[@"session_events"] = events;
  [invalidCandidates addObject:oversizedCall];

  for (NSUInteger index = 0; index < invalidCandidates.count; index += 1) {
    NSString *operationID = [NSString stringWithFormat:
        @"bbbbbbbb-bbbb-4bbb-8bbb-%012lx", (unsigned long)(index + 1)];
    error = nil;
    XCTAssertNil(([self.store casPersistSession:@{
      @"schema_version" : @1,
      @"operation_id" : operationID,
      @"expected" : expected,
      @"candidate_json" : [self jsonForCandidate:invalidCandidates[index]],
    } error:&error]));
    XCTAssertEqual(error.code, DSHSessionSnapshotStoreErrorInvalidArgument);
  }
}

- (void)testTombstoneParserAcceptsItsFourHundredThousandEntryBound {
  NSError *error = nil;
  NSDictionary *first = [self casWithOperation:DSHSessionTestOperationA
                                        expected:@{
                                          @"schema_version" : @1,
                                          @"kind" : @"missing",
                                        }
                                       candidate:[self candidate:1]
                                           error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(first[@"status"], @"committed");

  NSMutableArray<NSString *> *operationIds =
      [NSMutableArray arrayWithCapacity:400000];
  for (NSUInteger index = 1; index <= 400000; index += 1) {
    [operationIds addObject:[NSString stringWithFormat:
        @"%08lx-0000-4000-8000-%012lx", (unsigned long)index,
        (unsigned long)index]];
  }
  NSDictionary *tombstones = @{
    @"schema_version" : @1,
    @"generation" : @1,
    @"operation_ids" : operationIds,
  };
  NSData *bytes = DSHWorkspaceCanonicalJSONData(tombstones, &error);
  XCTAssertNotNil(bytes);
  XCTAssertLessThan(bytes.length, 16U * 1024U * 1024U);
  NSURL *url = [self.store.rootURL
      URLByAppendingPathComponent:@".sessions.commit-tombstones"];
  XCTAssertTrue([bytes writeToURL:url options:NSDataWritingAtomic error:&error]);
  XCTAssertTrue(([NSFileManager.defaultManager
      setAttributes:@{ NSFilePosixPermissions : @0600 }
      ofItemAtPath:url.path
      error:&error]));
  // Device host: asserts the ACTUAL protection class read back from the
  // filesystem (see applyPublishedSessionProtectionAtURL).
  [self applyPublishedSessionProtectionAtURL:url];
  XCTAssertNil(error);
  NSDictionary *loaded = [self.store loadSessionSnapshotWithError:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(loaded[@"status"], @"present");
}

- (void)testPublicReaderWaitsForTheWriterLockDuringRollbackCheckpoint {
  NSError *error = nil;
  NSDictionary *first = [self casWithOperation:DSHSessionTestOperationA
                                        expected:@{
                                          @"schema_version" : @1,
                                          @"kind" : @"missing",
                                        }
                                       candidate:[self candidate:1]
                                           error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(first[@"status"], @"committed");
  NSData *oldBytes = [NSData dataWithContentsOfURL:self.store.sessionURL];
  XCTAssertNotNil(oldBytes);
  dispatch_semaphore_t entered = dispatch_semaphore_create(0);
  dispatch_semaphore_t release = dispatch_semaphore_create(0);
  __block NSUInteger afterRenameCount = 0;
  DSHSessionSnapshotStoreFaultHook hook =
      ^BOOL(DSHSessionSnapshotStoreFaultPoint point) {
        if (point == DSHSessionSnapshotStoreFaultPointAfterRename &&
            ++afterRenameCount == 2) {
          // The first after-rename callback belongs to the tombstone ledger;
          // block only after the session RENAME_SWAP. Restoring the protected
          // bytes models a failed native checkpoint rollback.
          [oldBytes writeToURL:self.store.sessionURL options:0 error:nil];
          dispatch_semaphore_signal(entered);
          dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER);
          return NO;
        }
        return YES;
      };
  DSHSessionSnapshotStore *writer = [[DSHSessionSnapshotStore alloc]
      initWithRootURL:self.rootURL
           sessionURL:self.store.sessionURL
     launchInstanceId:DSHSessionTestLaunch
           coordinator:nil
             faultHook:hook];
  DSHSessionSnapshotStore *reader = [[DSHSessionSnapshotStore alloc]
      initWithRootURL:self.rootURL
           sessionURL:self.store.sessionURL
     launchInstanceId:DSHSessionTestLaunch
           coordinator:nil
             faultHook:nil];
  __block NSDictionary *writerResult = nil;
  __block NSDictionary *readerResult = nil;
  dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0);
  dispatch_async(queue, ^{
    writerResult = [writer casPersistSession:@{
      @"schema_version" : @1,
      @"operation_id" : DSHSessionTestOperationB,
      @"expected" : @{
        @"schema_version" : @1,
        @"kind" : @"present",
        @"snapshot" : first[@"snapshot"],
      },
      @"candidate_json" : [self jsonForCandidate:[self candidate:2]],
    } error:nil];
  });
  XCTAssertEqual(dispatch_semaphore_wait(entered,
                                         dispatch_time(DISPATCH_TIME_NOW,
                                                       5 * NSEC_PER_SEC)), 0);
  dispatch_async(queue, ^{
    readerResult = [reader loadSessionSnapshotWithError:nil];
  });
  usleep(100000);
  XCTAssertNil(readerResult);
  dispatch_semaphore_signal(release);
  for (NSUInteger index = 0; index < 50 && readerResult == nil; index += 1) {
    usleep(10000);
  }
  XCTAssertEqualObjects(writerResult[@"status"], @"unknown");
  XCTAssertEqualObjects(readerResult[@"status"], @"present");
  XCTAssertEqualObjects(readerResult[@"snapshot"][@"generation"], @1);
}

- (void)testSecondProcessCASWaitsOutTheRenameRollbackCheckpoint {
  if (DSHTestHostIsDevice()) {
    XCTSkip(@"fork(2) is not permitted for iOS app processes on a physical "
        @"device. The same writer-lock/rollback property is verified "
        @"in-process on both hosts by "
        @"testIndependentStoreCASWaitsOutTheRenameRollbackCheckpoint.");
  }
  NSError *error = nil;
  NSDictionary *first = [self casWithOperation:DSHSessionTestOperationA
                                        expected:@{
                                          @"schema_version" : @1,
                                          @"kind" : @"missing",
                                        }
                                       candidate:[self candidate:1]
                                           error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(first[@"status"], @"committed");
  NSData *oldBytes = [NSData dataWithContentsOfURL:self.store.sessionURL];
  NSString *rootPath = self.rootURL.path.copy;
  NSString *candidateJSON = [self jsonForCandidate:[self candidate:2]];
  NSDictionary *expected = @{
    @"schema_version" : @1,
    @"kind" : @"present",
    @"snapshot" : first[@"snapshot"],
  };
  dispatch_semaphore_t entered = dispatch_semaphore_create(0);
  dispatch_semaphore_t release = dispatch_semaphore_create(0);
  __block NSUInteger afterRenameCount = 0;
  DSHSessionSnapshotStoreFaultHook hook =
      ^BOOL(DSHSessionSnapshotStoreFaultPoint point) {
        if (point == DSHSessionSnapshotStoreFaultPointAfterRename &&
            ++afterRenameCount == 2) {
          [oldBytes writeToURL:self.store.sessionURL options:0 error:nil];
          dispatch_semaphore_signal(entered);
          dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER);
          return NO;
        }
        return YES;
      };
  DSHSessionSnapshotStore *writer = [[DSHSessionSnapshotStore alloc]
      initWithRootURL:self.rootURL
           sessionURL:self.store.sessionURL
     launchInstanceId:DSHSessionTestLaunch
           coordinator:nil
             faultHook:hook];
  dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0);
  dispatch_async(queue, ^{
    (void)[writer casPersistSession:@{
      @"schema_version" : @1,
      @"operation_id" : DSHSessionTestOperationB,
      @"expected" : expected,
      @"candidate_json" : candidateJSON,
    } error:nil];
  });
  XCTAssertEqual(dispatch_semaphore_wait(entered,
                                         dispatch_time(DISPATCH_TIME_NOW,
                                                       5 * NSEC_PER_SEC)), 0);
  int pipeDescriptors[2] = { -1, -1 };
  XCTAssertEqual(pipe(pipeDescriptors), 0);
  pid_t child = fork();
  XCTAssertGreaterThanOrEqual(child, 0);
  if (child < 0) {
    close(pipeDescriptors[0]);
    close(pipeDescriptors[1]);
    return;
  }
  if (child == 0) {
    int childWrite = dup2(pipeDescriptors[1], STDOUT_FILENO);
    close(pipeDescriptors[0]);
    close(pipeDescriptors[1]);
    for (int descriptor = 3; descriptor < 256; descriptor += 1) {
      close(descriptor);
    }
    NSURL *childRoot = [NSURL fileURLWithPath:rootPath isDirectory:YES];
    id allocated = [DSHSessionWorkspaceCoordinator alloc];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    DSHSessionWorkspaceCoordinator *childCoordinator =
        [allocated performSelector:NSSelectorFromString(@"initPrivate")];
#pragma clang diagnostic pop
    DSHSessionSnapshotStore *childStore = [[DSHSessionSnapshotStore alloc]
        initWithRootURL:childRoot
           sessionURL:[childRoot URLByAppendingPathComponent:@"sessions.json"]
     launchInstanceId:DSHSessionTestLaunch
           coordinator:childCoordinator
             faultHook:nil];
    NSDictionary *childResult = [childStore casPersistSession:@{
      @"schema_version" : @1,
      @"operation_id" : @"cccccccc-cccc-4ccc-8ccc-cccccccccccc",
      @"expected" : expected,
      @"candidate_json" : candidateJSON,
    } error:nil];
    const char *status = [childResult[@"status"] UTF8String];
    if (status != nullptr) write(childWrite, status, strlen(status));
    close(childWrite);
    _exit(0);
  }
  close(pipeDescriptors[1]);
  int flags = fcntl(pipeDescriptors[0], F_GETFL, 0);
  fcntl(pipeDescriptors[0], F_SETFL, flags | O_NONBLOCK);
  char status[32] = {};
  ssize_t beforeRelease = read(pipeDescriptors[0], status, sizeof(status) - 1);
  XCTAssertEqual(beforeRelease, (ssize_t)-1);
  dispatch_semaphore_signal(release);
  int waitStatus = 0;
  XCTAssertEqual(waitpid(child, &waitStatus, 0), child);
  ssize_t afterRelease = read(pipeDescriptors[0], status, sizeof(status) - 1);
  close(pipeDescriptors[0]);
  XCTAssertTrue(WIFEXITED(waitStatus));
  XCTAssertGreaterThan(afterRelease, (ssize_t)0);
  status[afterRelease] = '\0';
  XCTAssertEqualObjects([NSString stringWithUTF8String:status], @"committed");
}

- (void)testIndependentStoreCASWaitsOutTheRenameRollbackCheckpoint {
  // In-process counterpart of the fork(2)-based
  // testSecondProcessCASWaitsOutTheRenameRollbackCheckpoint, which must
  // skip on the physical device because iOS app processes cannot fork.
  // Verifies the same property without a second process: while the writer
  // holds the shared CAS lock at its rename rollback checkpoint, a second
  // store on an independent coordinator must stay blocked, and it must
  // commit once the writer releases the lock after the rollback.
  NSError *error = nil;
  NSDictionary *first = [self casWithOperation:DSHSessionTestOperationA
                                        expected:@{
                                          @"schema_version" : @1,
                                          @"kind" : @"missing",
                                        }
                                       candidate:[self candidate:1]
                                           error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(first[@"status"], @"committed");
  NSData *oldBytes = [NSData dataWithContentsOfURL:self.store.sessionURL];
  XCTAssertNotNil(oldBytes);
  NSString *candidateJSON = [self jsonForCandidate:[self candidate:2]];
  NSDictionary *expected = @{
    @"schema_version" : @1,
    @"kind" : @"present",
    @"snapshot" : first[@"snapshot"],
  };
  dispatch_semaphore_t entered = dispatch_semaphore_create(0);
  dispatch_semaphore_t release = dispatch_semaphore_create(0);
  __block NSUInteger afterRenameCount = 0;
  DSHSessionSnapshotStoreFaultHook hook =
      ^BOOL(DSHSessionSnapshotStoreFaultPoint point) {
        if (point == DSHSessionSnapshotStoreFaultPointAfterRename &&
            ++afterRenameCount == 2) {
          // Roll the already protected session inode back while the lock
          // is held, then hold the lock at the rollback checkpoint.
          [oldBytes writeToURL:self.store.sessionURL options:0 error:nil];
          dispatch_semaphore_signal(entered);
          dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER);
          return NO;
        }
        return YES;
      };
  DSHSessionSnapshotStore *writer = [[DSHSessionSnapshotStore alloc]
      initWithRootURL:self.rootURL
           sessionURL:self.store.sessionURL
     launchInstanceId:DSHSessionTestLaunch
           coordinator:nil
             faultHook:hook];
  id allocated = [DSHSessionWorkspaceCoordinator alloc];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
  DSHSessionWorkspaceCoordinator *secondCoordinator =
      [allocated performSelector:NSSelectorFromString(@"initPrivate")];
#pragma clang diagnostic pop
  DSHSessionSnapshotStore *second = [[DSHSessionSnapshotStore alloc]
      initWithRootURL:self.rootURL
           sessionURL:self.store.sessionURL
     launchInstanceId:DSHSessionTestLaunch
           coordinator:secondCoordinator
             faultHook:nil];
  __block NSDictionary *writerResult = nil;
  __block NSDictionary *secondResult = nil;
  dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0);
  dispatch_async(queue, ^{
    writerResult = [writer casPersistSession:@{
      @"schema_version" : @1,
      @"operation_id" : DSHSessionTestOperationB,
      @"expected" : expected,
      @"candidate_json" : candidateJSON,
    } error:nil];
  });
  XCTAssertEqual(dispatch_semaphore_wait(entered,
                                         dispatch_time(DISPATCH_TIME_NOW,
                                                       5 * NSEC_PER_SEC)), 0);
  dispatch_async(queue, ^{
    secondResult = [second casPersistSession:@{
      @"schema_version" : @1,
      @"operation_id" : @"cccccccc-cccc-4ccc-8ccc-cccccccccccc",
      @"expected" : expected,
      @"candidate_json" : candidateJSON,
    } error:nil];
  });
  // The second store must remain blocked behind the writer's lock.
  usleep(100000);
  XCTAssertNil(secondResult);
  dispatch_semaphore_signal(release);
  for (NSUInteger index = 0; index < 500 &&
      (writerResult == nil || secondResult == nil); index += 1) {
    usleep(10000);
  }
  XCTAssertEqualObjects(writerResult[@"status"], @"unknown");
  XCTAssertEqualObjects(secondResult[@"status"], @"committed");
}

- (void)testConcurrentReaderCannotObserveAnInFlightRenameRollback {
  NSError *error = nil;
  NSDictionary *first = [self casWithOperation:DSHSessionTestOperationA
                                        expected:@{
                                          @"schema_version" : @1,
                                          @"kind" : @"missing",
                                        }
                                       candidate:[self candidate:1]
                                           error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(first[@"status"], @"committed");
  NSDictionary *expected = @{
    @"schema_version" : @1,
    @"kind" : @"present",
    @"snapshot" : first[@"snapshot"],
  };
  NSData *oldBytes = [NSData dataWithContentsOfURL:self.store.sessionURL];
  XCTAssertNotNil(oldBytes);
  dispatch_semaphore_t enteredHook = dispatch_semaphore_create(0);
  dispatch_semaphore_t releaseHook = dispatch_semaphore_create(0);
  __block NSUInteger afterRenameCount = 0;
  DSHSessionSnapshotStoreFaultHook hook =
      ^BOOL(DSHSessionSnapshotStoreFaultPoint point) {
        if (point == DSHSessionSnapshotStoreFaultPointAfterRename &&
            ++afterRenameCount == 2) {
          dispatch_semaphore_signal(enteredHook);
          // Simulate a native rollback checkpoint while the writer still owns
          // the shared lock. Directly rewrite the already protected inode so
          // the reader must observe the pre-swap generation after release.
          [oldBytes writeToURL:self.store.sessionURL options:0 error:nil];
          dispatch_semaphore_wait(releaseHook, DISPATCH_TIME_FOREVER);
          return NO;
        }
        return YES;
      };
  DSHSessionSnapshotStore *writer = [[DSHSessionSnapshotStore alloc]
      initWithRootURL:self.rootURL
           sessionURL:self.store.sessionURL
     launchInstanceId:DSHSessionTestLaunch
           coordinator:nil
             faultHook:hook];
  DSHSessionSnapshotStore *reader = [[DSHSessionSnapshotStore alloc]
      initWithRootURL:self.rootURL
           sessionURL:self.store.sessionURL
     launchInstanceId:DSHSessionTestLaunch
           coordinator:nil
             faultHook:nil];
  __block NSDictionary *writerResult = nil;
  __block NSDictionary *readerResult = nil;
  dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0);
  dispatch_async(queue, ^{
    writerResult = [writer casPersistSession:@{
      @"schema_version" : @1,
      @"operation_id" : DSHSessionTestOperationB,
      @"expected" : expected,
      @"candidate_json" : [self jsonForCandidate:[self candidate:2]],
    } error:nil];
  });
  XCTAssertEqual(dispatch_semaphore_wait(enteredHook,
                                         dispatch_time(DISPATCH_TIME_NOW,
                                                       5 * NSEC_PER_SEC)), 0);
  dispatch_async(queue, ^{
    readerResult = [reader loadSessionSnapshotWithError:nil];
  });
  // The reader must remain blocked while the writer owns the cross-process
  // lock at its post-swap checkpoint.
  usleep(100000);
  XCTAssertNil(readerResult);
  dispatch_semaphore_signal(releaseHook);
  for (NSUInteger index = 0; index < 50 && readerResult == nil; index += 1) {
    usleep(10000);
  }
  XCTAssertEqualObjects(writerResult[@"status"], @"unknown");
  XCTAssertEqualObjects(readerResult[@"status"], @"present");
  XCTAssertEqualObjects(readerResult[@"snapshot"][@"generation"], @1);
}

- (void)testEvictedOperationCannotBeReusedAfterTheRetentionWatermark {
  NSError *error = nil;
  NSDictionary *expected = @{ @"schema_version" : @1, @"kind" : @"missing" };
  NSString *firstOperation = nil;
  for (NSUInteger index = 0; index < 65; index += 1) {
    NSString *operation = [NSString stringWithFormat:
        @"%08lx-0000-4000-8000-%012lx", (unsigned long)(index + 1),
        (unsigned long)(index + 1)];
    if (index == 0) firstOperation = operation;
    NSDictionary *result = [self casWithOperation:operation
                                           expected:expected
                                          candidate:[self candidate:index]
                                              error:&error];
    XCTAssertNil(error);
    XCTAssertEqualObjects(result[@"status"], @"committed");
    expected = @{
      @"schema_version" : @1,
      @"kind" : @"present",
      @"snapshot" : result[@"snapshot"],
    };
  }
  NSDictionary *replay = [self casWithOperation:firstOperation
                                          expected:expected
                                         candidate:[self candidate:0]
                                             error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(replay[@"status"], @"unknown");
  XCTAssertEqualObjects(replay[@"current"][@"snapshot"][@"generation"], @65);
  NSDictionary *fresh = [self casWithOperation:
      @"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
      expected:expected
      candidate:[self candidate:65]
      error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(fresh[@"status"], @"committed");
  XCTAssertEqualObjects(fresh[@"snapshot"][@"generation"], @66);
  NSDictionary *evictedAgain = [self casWithOperation:firstOperation
                                                 expected:@{
                                                   @"schema_version" : @1,
                                                   @"kind" : @"present",
                                                   @"snapshot" : fresh[@"snapshot"],
                                                 }
                                                candidate:[self candidate:0]
                                                    error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(evictedAgain[@"status"], @"unknown");
  NSDictionary *freshQuery = [self.store querySessionCommit:@{
    @"schema_version" : @1,
    @"operation_id" : @"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
  } error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(freshQuery[@"status"], @"committed");
  NSDictionary *loaded = [self.store loadSessionSnapshotWithError:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(loaded[@"snapshot"][@"generation"], @66);
}


- (void)testCustomProviderManifestAndRoundReceiptCommitAndReload {
  NSMutableDictionary *candidate = [self mutableSharedFixtureNamed:@"claude-code-tool-round-session"];
  NSDictionary *configuration = @{@"schema_version": @1, @"harness_id": @"claude-code", @"name": @"Relay",
    @"endpoint_url": @"https://relay.example/v1/messages", @"protocol": @"messages", @"auth_type": @"bearer",
    @"send_reasoning": @NO, @"model_mappings": @{@"claude-sonnet-5": @"relay-sonnet"}};
  NSDictionary *binding = DSHProviderBindingFromConfiguration(configuration, @"claude-sonnet-5");
  XCTAssertNotNil(binding);
  NSUInteger receipts = 0;
  for (NSMutableDictionary *conversation in candidate[@"conversations"]) {
    id context = conversation[@"project_context"];
    if ([context isKindOfClass:NSDictionary.class] && [context[@"manifest"] isKindOfClass:NSDictionary.class]) {
      context[@"manifest"][@"provider_configuration"] = binding;
      context[@"manifest"][@"provider_host"] = @"relay.example";
    }
    for (NSMutableDictionary *attempt in conversation[@"attempts"]) {
      for (NSMutableDictionary *receipt in attempt[@"rounds"]) {
        receipt[@"provider_configuration"] = binding; receipts += 1;
      }
    }
  }
  XCTAssertGreaterThan(receipts, 0u);
  NSError *error = nil;
  NSDictionary *result = [self casWithOperation:DSHSessionTestOperationA
      expected:@{@"schema_version": @1, @"kind": @"missing"} candidate:candidate error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(result[@"status"], @"committed");
  NSDictionary *loaded = [self.store loadSessionSnapshotWithError:&error];
  XCTAssertNil(error);
  XCTAssertTrue([loaded[@"session_json"] containsString:@"provider_configuration"]);
  XCTAssertTrue([loaded[@"session_json"] containsString:@"relay-sonnet"]);
}

@end
