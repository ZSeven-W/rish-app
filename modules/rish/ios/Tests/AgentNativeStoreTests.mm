#import <XCTest/XCTest.h>

#import "../../../../modules/rish/ios/Sources/AgentExecutionLedger.h"
#import "../../../../modules/rish/ios/Sources/AgentNativeWAL.h"
#import "../../../../modules/rish/ios/Sources/AgentRoundJournal.h"
#import "../../../../modules/rish/ios/Sources/AgentTranscriptStore.h"

#include <sys/stat.h>

@interface DSHAgentNativeWAL (ProtectionTesting)
- (BOOL)requiresWALResourceMetadata;
- (NSFileManager *)walFileManager;
- (BOOL)setWALProtectionAtURL:(NSURL *)url error:(NSError **)error;
- (BOOL)getWALProtectionAtURL:(NSURL *)url value:(id *)value error:(NSError **)error;
- (BOOL)setWALBackupExcludedAtURL:(NSURL *)url error:(NSError **)error;
- (BOOL)getWALBackupExcludedAtURL:(NSURL *)url
                          value:(NSNumber **)value error:(NSError **)error;
@end

static NSString *DSHWALTestInode(NSString *path) {
  struct stat metadata = {};
  if (lstat(path.fileSystemRepresentation, &metadata) != 0) return nil;
  return [NSString stringWithFormat:@"%llu:%llu",
      (unsigned long long)metadata.st_dev, (unsigned long long)metadata.st_ino];
}

// Model the device's protection metadata while executing the production WAL
// transaction and every real descriptor, mode, no-follow and inode check.
// Metadata follows inodes across staging rename and a fresh WAL instance.
@interface DSHWALMetadataFileManager : NSFileManager
@property(nonatomic, strong) NSMutableDictionary *protections;
@property(nonatomic, copy) NSString *failure;
@property(nonatomic, copy) NSString *failureSuffix;
@property(nonatomic) NSUInteger protectionWrites;
@property(nonatomic) NSUInteger protectionReads;
@end

@implementation DSHWALMetadataFileManager
- (instancetype)init {
  self = [super init];
  if (self) _protections = [NSMutableDictionary dictionary];
  return self;
}
- (BOOL)fails:(NSString *)kind path:(NSString *)path {
  return [self.failure isEqual:kind] && [path hasSuffix:self.failureSuffix ?: @".tmp"];
}
- (BOOL)setAttributes:(NSDictionary<NSFileAttributeKey, id> *)attributes
         ofItemAtPath:(NSString *)path error:(NSError **)error {
  if (attributes[NSFileProtectionKey] == nil) {
    return [super setAttributes:attributes ofItemAtPath:path error:error];
  }
  self.protectionWrites += 1;
  if ([self fails:@"protection_write" path:path]) return NO;
  NSString *identity = DSHWALTestInode(path);
  if (identity == nil) return NO;
  self.protections[identity] = attributes[NSFileProtectionKey];
  return YES;
}
- (NSDictionary<NSFileAttributeKey, id> *)attributesOfItemAtPath:(NSString *)path
                                                       error:(NSError **)error {
  self.protectionReads += 1;
  if ([self fails:@"protection_read" path:path]) return nil;
  NSMutableDictionary *attributes =
      [[super attributesOfItemAtPath:path error:error] mutableCopy];
  NSString *identity = DSHWALTestInode(path);
  if (attributes == nil || identity == nil) return nil;
  id protection = self.protections[identity];
  if ([self fails:@"protection_missing" path:path]) protection = nil;
  if ([self fails:@"protection_wrong" path:path]) protection = NSFileProtectionNone;
  if (protection == nil) [attributes removeObjectForKey:NSFileProtectionKey];
  else attributes[NSFileProtectionKey] = protection;
  return attributes;
}
@end

@interface DSHWALDeviceMetadataStore : DSHAgentNativeWAL
@property(nonatomic, strong) DSHWALMetadataFileManager *metadata;
@property(nonatomic, strong) NSMutableDictionary *backups;
@property(nonatomic) BOOL swapStagedInode;
@property(nonatomic) BOOL didSwap;
@end

@implementation DSHWALDeviceMetadataStore
- (BOOL)requiresWALResourceMetadata { return YES; }
- (NSFileManager *)walFileManager { return self.metadata; }
- (BOOL)setWALBackupExcludedAtURL:(NSURL *)url error:(NSError **)error {
  if ([self.metadata fails:@"backup_write" path:url.path]) return NO;
  if (self.swapStagedInode && [url.lastPathComponent hasSuffix:@".tmp"]) {
    NSURL *moved = [url URLByAppendingPathExtension:@"swapped"];
    if (![NSFileManager.defaultManager moveItemAtURL:url toURL:moved error:error] ||
        ![[NSData dataWithContentsOfURL:moved] writeToURL:url options:0 error:error]) {
      return NO;
    }
    [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions : @0600}
                                  ofItemAtPath:url.path error:error];
    self.metadata.protections[DSHWALTestInode(url.path)] =
        NSFileProtectionCompleteUntilFirstUserAuthentication;
    self.didSwap = YES;
  }
  NSString *identity = DSHWALTestInode(url.path);
  if (identity == nil) return NO;
  self.backups[identity] = @YES;
  return YES;
}
- (BOOL)getWALBackupExcludedAtURL:(NSURL *)url
                          value:(NSNumber **)value error:(NSError **)error {
  (void)error;
  if (value != nullptr) *value = nil;
  if ([self.metadata fails:@"backup_read" path:url.path]) return NO;
  NSString *identity = DSHWALTestInode(url.path);
  NSNumber *excluded = identity == nil ? nil : self.backups[identity];
  if ([self.metadata fails:@"backup_missing" path:url.path]) excluded = nil;
  if ([self.metadata fails:@"backup_wrong" path:url.path]) excluded = @NO;
  if (value != nullptr) *value = excluded;
  return YES;
}
@end

@interface AgentNativeStoreTests : XCTestCase
@property(nonatomic, strong) NSURL *rootURL;
@property(nonatomic, strong) DSHAgentNativeWAL *wal;
@property(nonatomic, strong) DSHAgentTranscriptStore *transcripts;
@property(nonatomic, strong) DSHAgentRoundJournal *rounds;
@property(nonatomic, strong) DSHAgentExecutionLedger *ledger;
@end

@implementation AgentNativeStoreTests

- (void)setUp {
  [super setUp];
  NSString *name = [NSString stringWithFormat:
      @"rish-agent-native-%@", NSUUID.UUID.UUIDString.lowercaseString];
  self.rootURL = [NSURL fileURLWithPath:
      [NSTemporaryDirectory() stringByAppendingPathComponent:name]
                              isDirectory:YES];
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:self.rootURL
                                         withIntermediateDirectories:YES
                                                          attributes:nil
                                                               error:nil]);
  self.wal = [[DSHAgentNativeWAL alloc]
      initWithRootURL:self.rootURL
      clock:^NSDate * { return [NSDate dateWithTimeIntervalSince1970:1787961600]; }
      identifierGenerator:^NSString * {
        return @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
      }
      faultHook:nil];
  self.transcripts = [[DSHAgentTranscriptStore alloc] initWithWAL:self.wal];
  self.rounds = [[DSHAgentRoundJournal alloc] initWithWAL:self.wal];
  self.ledger = [[DSHAgentExecutionLedger alloc] initWithWAL:self.wal];
}

- (void)tearDown {
  [NSFileManager.defaultManager removeItemAtURL:self.rootURL error:nil];
  [super tearDown];
}

- (NSDictionary *)root {
  return @{
    @"schema_version" : @1,
    @"kind" : @"workspace",
    @"workspace_id" : @"11111111-1111-4111-8111-111111111111",
    @"workspace_binding_revision" : @1,
    @"project_id" : NSNull.null,
    @"root_fingerprint_sha256" :
        @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    @"capabilities" : @[@"file_read"],
  };
}

- (NSDictionary *)agentPolicy {
  return @{
    @"schema_version" : @1,
    @"policy_version" : @"agent-v1",
    @"max_single_write_bytes" : @32768,
    @"max_batch_write_bytes" : @32768,
    @"max_attempt_write_bytes" : @65536,
  };
}

- (NSDictionary *)agentRegistry {
  return @{
    @"schema_version" : @2,
    @"registry_version" : @1,
    @"toolset_sha256" :
        @"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    @"tools" : @[
      @{
        @"schema_version" : @2,
        @"name" : @"list_dir",
        @"safe_summary_key" : @"agent.list_dir",
        @"access" : @"auto",
      },
      @{
        @"schema_version" : @2,
        @"name" : @"read_file",
        @"safe_summary_key" : @"agent.read_file",
        @"access" : @"auto",
      },
    ],
  };
}

- (BOOL)writeCanonicalWALState:(NSDictionary *)state error:(NSError **)error {
  NSData *data = DSHAgentCanonicalJSON(state, error);
  if (data == nil || ![data writeToURL:self.wal.walURL
                                options:NSDataWritingAtomic
                                  error:error]) return NO;
  if (![NSFileManager.defaultManager
      setAttributes:@{
        NSFilePosixPermissions : @0600,
        NSFileProtectionKey :
            NSFileProtectionCompleteUntilFirstUserAuthentication,
      }
       ofItemAtPath:self.wal.walURL.path
              error:error]) return NO;
  return [self.wal.walURL setResourceValue:@YES
                                      forKey:NSURLIsExcludedFromBackupKey
                                       error:error];
}

- (NSDictionary *)emptyLegacyWALWithGeneration:(NSNumber *)generation {
  return @{
    @"schema_version" : @1,
    @"generation" : generation,
    @"transcripts" : @[],
    @"rounds" : @[],
    @"ledger" : @[],
    @"reservations" : @[],
    @"cleanup" : @[],
    @"dispatch" : @[],
    @"batches" : @[],
  };
}

- (NSDictionary *)readOnlyBatchWithRoundID:(NSString *)roundID
                                   revision:(NSNumber *)revision {
  return @{
    @"schema_version" : @2,
    @"kind" : @"read_only_batch",
    @"task_id" : @"33333333-3333-4333-8333-333333333333",
    @"attempt_id" : @"22222222-2222-4222-8222-222222222222",
    @"round_id" : roundID,
    @"round_index" : @0,
    @"batch_revision" : revision,
    @"manifest_sha256" : NSNull.null,
    @"reservation_delta_bytes" : @0,
    @"reserved_write_bytes" : @0,
    @"attempt_reserved_write_bytes" : @0,
    @"effect_gate" : @"not_applicable",
    @"created_at" : @"2026-08-30T00:00:00.000Z",
    @"updated_at" : @"2026-08-30T00:00:00.000Z",
  };
}

- (NSDictionary *)prepareAuthorityForTranscript:(NSDictionary *)transcript {
  return @{
    @"schema_version" : @2,
    @"task_id" : @"33333333-3333-4333-8333-333333333333",
    @"conversation_id" : @"77777777-7777-4777-8777-777777777777",
    @"attempt_id" : @"22222222-2222-4222-8222-222222222222",
    @"root" : [self root],
    @"policy" : [self agentPolicy],
    @"registry" : [self agentRegistry],
    @"transport_schema_version" : @2,
    @"model" : @"deepseek-v4-flash",
    @"thinking_mode" : @"off",
    @"visible_message_ids" : @[],
    @"visible_history_sha256" :
        @"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    @"visible_message_count" : @0,
    @"project_context_sha256" : NSNull.null,
    @"transcript" : transcript,
    @"reserved_write_bytes" : @0,
    @"authority_revision" : @1,
    @"state" : @"prepared",
    @"cleanup_id" : NSNull.null,
    @"created_at" : @"2026-08-30T00:00:00.000Z",
    @"updated_at" : @"2026-08-30T00:00:00.000Z",
  };
}

- (NSDictionary *)prepareRequestWithOperationID:(NSString *)operationID
                                      transcript:(NSDictionary *)transcript {
  return @{
    @"schema_version" : @2,
    @"operation_id" : operationID,
    @"controller_cas" : @{
      @"schema_version" : @1,
      @"conversation_id" : @"77777777-7777-4777-8777-777777777777",
      @"task_id" : @"33333333-3333-4333-8333-333333333333",
      @"attempt_id" : @"22222222-2222-4222-8222-222222222222",
      @"expected_controller_generation" : @1,
      @"expected_journal_revision" : @1,
      @"expected_session_generation" : @1,
      @"expected_session_sha256" :
          @"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
    },
    @"committed_checkpoint" : @{
      @"schema_version" : @1,
      @"journal_revision" : @1,
      @"session_generation" : @1,
      @"session_sha256" :
          @"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
    },
    @"task_id" : @"33333333-3333-4333-8333-333333333333",
    @"conversation_id" : @"77777777-7777-4777-8777-777777777777",
    @"attempt_id" : @"22222222-2222-4222-8222-222222222222",
    @"workspace_id" : @"11111111-1111-4111-8111-111111111111",
    @"project_id" : NSNull.null,
    @"workspace_binding_revision" : @1,
    @"transport_schema_version" : @2,
    @"model" : @"deepseek-v4-flash",
    @"thinking_mode" : @"off",
    @"visible_message_ids" : @[],
    @"visible_history_sha256" :
        @"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    @"visible_message_count" : @0,
    @"project_context_sha256" : NSNull.null,
    @"registry_version" : @1,
    @"expected_policy_version" : @"agent-v1",
    @"expected_transcript" : transcript,
  };
}

- (NSDictionary *)prepareSafeResultWithOperationID:(NSString *)operationID
                                         transcript:(NSDictionary *)transcript {
  NSDictionary *checkpoint = @{
    @"schema_version" : @1,
    @"journal_revision" : @1,
    @"session_generation" : @1,
    @"session_sha256" :
        @"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
  };
  NSDictionary *attempt = @{
    @"schema_version" : @2,
    @"task_id" : @"33333333-3333-4333-8333-333333333333",
    @"conversation_id" : @"77777777-7777-4777-8777-777777777777",
    @"attempt_id" : @"22222222-2222-4222-8222-222222222222",
    @"phase" : @"ready_for_round",
    @"controller_generation" : @1,
    @"journal_revision" : @1,
    @"authority_revision" : @1,
    @"root" : [self root],
    @"policy" : [self agentPolicy],
    @"registry" : [self agentRegistry],
    @"transcript" : transcript,
    @"round_index" : @0,
    @"round_id" : NSNull.null,
    @"round_revision" : NSNull.null,
    @"round_status" : @"ready",
    @"batch_kind" : NSNull.null,
    @"batch_revision" : NSNull.null,
    @"manifest_sha256" : NSNull.null,
    @"call_index" : NSNull.null,
    @"batch" : @[],
    @"frozen_grant_ids" : @[],
    @"reserved_write_bytes" : @0,
    @"cancel_source_event_id" : NSNull.null,
    @"cleanup_id" : NSNull.null,
  };
  return @{
    @"schema_version" : @2,
    @"result_kind" : @"prepare_agent_attempt",
    @"result" : @{
      @"schema_version" : @2,
      @"status" : @"prepared",
      @"operation_id" : operationID,
      @"attempt" : attempt,
      @"observed_checkpoint" : checkpoint,
    },
  };
}

- (void)testPresentationArchiveIsBoundedHashCheckedAndSurvivesTranscriptCleanup {
  NSString *conversation = @"11111111-1111-4111-8111-111111111111";
  NSString *attempt = @"22222222-2222-4222-8222-222222222222";
  NSDictionary *request = @{ @"conversation_id": conversation, @"attempt_id": attempt, @"round_id": @"33333333-3333-4333-8333-333333333333", @"round_index": @0 };
  NSDictionary *before = [self.wal snapshotWithError:nil];
  [self.transcripts cacheRoundPresentationForRequest:request message:@{ @"content": @"I will inspect the files.", @"reasoning_content": @"private reasoning" } kind:@"tool_batch"];
  NSDictionary *result = [self.transcripts roundPresentationsForConversation:conversation attempt:attempt error:nil];
  XCTAssertEqual([result[@"rounds"] count], 1U);
  XCTAssertEqualObjects(result[@"rounds"][0][@"text"], @"I will inspect the files.");
  XCTAssertEqualObjects([self.wal snapshotWithError:nil], before);
  DSHAgentTranscriptStore *reopened = [[DSHAgentTranscriptStore alloc] initWithWAL:self.wal];
  XCTAssertEqualObjects([reopened roundPresentationsForConversation:conversation attempt:attempt error:nil], result);
  XCTAssertEqual([[reopened roundPresentationsForConversation:@"44444444-4444-4444-8444-444444444444" attempt:attempt error:nil][@"rounds"] count], 0U);
  NSURL *file = [[self.rootURL URLByAppendingPathComponent:@"round-presentations-v1"] URLByAppendingPathComponent:[NSString stringWithFormat:@"%@_%@.json", conversation, attempt]];
  NSMutableDictionary *tampered = [result mutableCopy];
  NSMutableDictionary *round = [result[@"rounds"][0] mutableCopy]; round[@"text"] = @"tampered"; tampered[@"rounds"] = @[round];
  [DSHAgentCanonicalJSON(tampered, nil) writeToURL:file atomically:YES];
  XCTAssertEqual([[reopened roundPresentationsForConversation:conversation attempt:attempt error:nil][@"rounds"] count], 0U);
  [self.transcripts cacheRoundPresentationForRequest:request message:@{ @"content": @"restored", @"reasoning_content": @"" } kind:@"final"];
  DSHAgentPruneRoundPresentationCache(self.rootURL, [NSSet set]);
  XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:file.path]);
  XCTAssertEqualObjects([self.wal snapshotWithError:nil], before);
}

- (void)testGuestServiceRootCreatesAndReopensProtectedTranscript {
  NSMutableDictionary *root = [[self root] mutableCopy];
  root[@"capabilities"] = @[@"file_read", @"file_write", @"guest_service"];
  NSDictionary *request = @{ @"schema_version": @1, @"attempt_id": @"22222222-2222-4222-8222-222222222222", @"root": root };
  NSError *error = nil;
  NSDictionary *created = [self.transcripts createAgentTranscriptWithRequest:request error:&error];
  XCTAssertNotNil(created); XCTAssertNil(error);
  DSHAgentTranscriptStore *reopened = [[DSHAgentTranscriptStore alloc] initWithWAL:self.wal];
  NSDictionary *replayed = [reopened createAgentTranscriptWithRequest:request error:&error];
  XCTAssertEqualObjects(created, replayed); XCTAssertNil(error);
}

- (void)testTranscriptIsProtectedAndAppendUsesExactReferenceCAS {
  NSError *error = nil;
  NSDictionary *created = [self.transcripts
      createAgentTranscriptWithRequest:@{
        @"schema_version" : @1,
        @"attempt_id" : @"22222222-2222-4222-8222-222222222222",
        @"root" : [self root],
      }
      error:&error];
  XCTAssertNotNil(created);
  XCTAssertNil(error);
  NSDictionary *replayed = [self.transcripts
      createAgentTranscriptWithRequest:@{
        @"schema_version" : @1,
        @"attempt_id" : @"22222222-2222-4222-8222-222222222222",
        @"root" : [self root],
      }
      error:&error];
  XCTAssertEqualObjects(replayed, created);
  XCTAssertNil(error);

  NSDictionary *message = @{
    @"schema_version" : @1,
    @"role" : @"assistant",
    @"round_index" : @0,
    @"content" : @"",
    @"reasoning_content" : @"read",
    @"tool_calls" : @[],
  };
  NSDictionary *next = [self.transcripts
      appendAssistantMessage:message
          expectedTranscript:created
                           root:[self root]
                       attemptId:@"22222222-2222-4222-8222-222222222222"
                           error:&error];
  XCTAssertNotNil(next);
  XCTAssertGreaterThan(next[@"generation"], @0);

  struct stat metadata = {};
  XCTAssertEqual(lstat(self.rootURL.fileSystemRepresentation, &metadata), 0);
  XCTAssertTrue((metadata.st_mode & 0777) == 0700);
  XCTAssertEqual(lstat(self.wal.walURL.fileSystemRepresentation, &metadata), 0);
  XCTAssertTrue((metadata.st_mode & 0777) == 0600);
}

- (DSHWALDeviceMetadataStore *)deviceMetadataStore {
  DSHWALDeviceMetadataStore *store = [[DSHWALDeviceMetadataStore alloc]
      initWithRootURL:self.rootURL
      clock:^NSDate * { return [NSDate dateWithTimeIntervalSince1970:1787961600]; }
      identifierGenerator:^NSString * { return NSUUID.UUID.UUIDString.lowercaseString; }
      faultHook:nil];
  store.metadata = [[DSHWALMetadataFileManager alloc] init];
  store.backups = [NSMutableDictionary dictionary];
  return store;
}

- (NSDictionary *)createDeviceMetadataTranscript:(DSHWALDeviceMetadataStore *)wal
                                           error:(NSError **)error {
  return [[[DSHAgentTranscriptStore alloc] initWithWAL:wal]
      createAgentTranscriptWithRequest:@{
        @"schema_version" : @1,
        @"attempt_id" : @"22222222-2222-4222-8222-222222222222",
        @"root" : [self root],
      } error:error];
}

- (void)testDeviceMetadataFirstTransactionAndRelaunchPreserveTranscript {
  // First launch has an existing private parent and neither agent directory nor WAL.
  XCTAssertTrue([NSFileManager.defaultManager removeItemAtURL:self.rootURL error:nil]);
  DSHWALDeviceMetadataStore *first = [self deviceMetadataStore];
  NSError *error = nil;
  NSDictionary *created = [self createDeviceMetadataTranscript:first error:&error];
  XCTAssertNotNil(created, @"%@", error);
  XCTAssertNil(error);
  NSData *before = [NSData dataWithContentsOfURL:first.walURL];
  XCTAssertGreaterThan(before.length, 0U);
  XCTAssertGreaterThan(first.metadata.protectionReads, 0U);
  XCTAssertGreaterThan(first.metadata.protectionWrites, 0U);
  DSHWALDeviceMetadataStore *reopened = [self deviceMetadataStore];
  reopened.metadata = first.metadata;
  reopened.backups = first.backups;
  XCTAssertEqualObjects([self createDeviceMetadataTranscript:reopened error:&error], created);
  XCTAssertNil(error);
  XCTAssertEqualObjects([NSData dataWithContentsOfURL:reopened.walURL], before);
  XCTAssertNotNil([reopened snapshotWithError:&error]);
  XCTAssertNil(error);
}

// An install upgraded from a build that applied a different protection class
// (or none) must keep working: the verifier re-applies the required class and
// backup exclusion in place and reads them back, exactly as the workspace
// store migrates a legacy class, instead of refusing the WAL forever.
- (void)testDeviceMetadataMigratesLegacyProtectionInsteadOfRefusingTheWAL {
  DSHWALDeviceMetadataStore *wal = [self deviceMetadataStore];
  NSError *error = nil;
  NSDictionary *created = [self createDeviceMetadataTranscript:wal error:&error];
  XCTAssertNotNil(created, @"%@", error);
  NSData *before = [NSData dataWithContentsOfURL:wal.walURL];
  XCTAssertGreaterThan(before.length, 0U);

  // Model the upgraded container: every recorded item carries the legacy
  // class and no backup exclusion.
  for (NSString *identity in wal.metadata.protections.allKeys) {
    wal.metadata.protections[identity] = NSFileProtectionComplete;
  }
  [wal.backups removeAllObjects];

  DSHWALDeviceMetadataStore *reopened = [self deviceMetadataStore];
  reopened.metadata = wal.metadata;
  reopened.backups = wal.backups;
  error = nil;
  NSDictionary *state = [reopened snapshotWithError:&error];
  XCTAssertNotNil(state, @"a legacy protection class must be migrated, not refused: %@", error);
  XCTAssertNil(error);
  XCTAssertEqualObjects([NSData dataWithContentsOfURL:reopened.walURL], before);
  NSString *walIdentity = DSHWALTestInode(reopened.walURL.path);
  XCTAssertEqualObjects(reopened.metadata.protections[walIdentity],
                        NSFileProtectionCompleteUntilFirstUserAuthentication);
  XCTAssertEqualObjects(reopened.backups[walIdentity], @YES);
}

- (void)testDeviceMetadataFailuresPreserveCommittedWALBytes {
  DSHWALDeviceMetadataStore *wal = [self deviceMetadataStore];
  NSError *error = nil;
  NSDictionary *created = [self createDeviceMetadataTranscript:wal error:&error];
  XCTAssertNotNil(created, @"%@", error);
  NSData *before = [NSData dataWithContentsOfURL:wal.walURL];
  XCTAssertGreaterThan(before.length, 0U);
  NSArray *failures = @[@"protection_write", @"protection_read", @"protection_missing",
      @"protection_wrong", @"backup_write", @"backup_read", @"backup_missing", @"backup_wrong"];
  DSHAgentTranscriptStore *transcripts = [[DSHAgentTranscriptStore alloc] initWithWAL:wal];
  NSDictionary *message = @{@"schema_version": @1, @"role": @"assistant",
      @"round_index": @0, @"content": @"saved reply", @"reasoning_content": @"",
      @"tool_calls": @[]};
  for (NSString *failure in failures) {
    wal.metadata.failure = failure;
    error = nil;
    XCTAssertNil([transcripts appendAssistantMessage:message expectedTranscript:created
        root:[self root] attemptId:@"22222222-2222-4222-8222-222222222222" error:&error],
        @"%@ must fail", failure);
    XCTAssertEqual(error.code, DSHAgentNativeStoreErrorPersistence, @"%@", failure);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:wal.walURL], before, @"%@", failure);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:
        [wal.walURL.path stringByAppendingString:@".tmp"]], @"%@", failure);
    wal.metadata.failure = nil;
    XCTAssertNotNil([wal snapshotWithError:nil], @"%@", failure);
  }
  // The same exact CAS becomes writable after metadata recovery.
  error = nil;
  XCTAssertNotNil([transcripts appendAssistantMessage:message expectedTranscript:created
      root:[self root] attemptId:@"22222222-2222-4222-8222-222222222222" error:&error]);
  XCTAssertNil(error);
}

- (void)testDeviceMetadataReadFailureAndInodeSwapNeverReplaceCommittedWAL {
  DSHWALDeviceMetadataStore *wal = [self deviceMetadataStore];
  NSError *error = nil;
  XCTAssertNotNil([self createDeviceMetadataTranscript:wal error:&error]);
  NSData *before = [NSData dataWithContentsOfURL:wal.walURL];
  for (NSString *suffix in @[self.rootURL.lastPathComponent, wal.walURL.lastPathComponent]) {
    wal.metadata.failureSuffix = suffix;
    wal.metadata.failure = @"protection_missing";
    XCTAssertNil([wal snapshotWithError:&error]);
    XCTAssertEqual(error.code, DSHAgentNativeStoreErrorUnavailable);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:wal.walURL], before);
    wal.metadata.failure = nil;
  }
  wal.swapStagedInode = YES;
  error = nil;
  XCTAssertFalse([wal performAtomicTransaction:^BOOL(NSMutableDictionary *state, NSError **inner) {
    (void)state; (void)inner;
    return YES;
  } error:&error]);
  XCTAssertTrue(wal.didSwap);
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorPersistence);
  XCTAssertEqualObjects([NSData dataWithContentsOfURL:wal.walURL], before);
}

- (void)testWALProtectionUsesFreshFileAttributesForDirectoryAndFile {
  NSURL *file = [self.rootURL URLByAppendingPathComponent:@"metadata-probe.json"];
  XCTAssertTrue([[@"{}" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:file atomically:YES]);
  for (NSURL *url in @[self.rootURL, file]) {
    NSError *error = nil;
    XCTAssertTrue([self.wal setWALProtectionAtURL:url error:&error], @"%@", error);
    id protection = nil;
    XCTAssertTrue([self.wal getWALProtectionAtURL:url value:&protection error:&error], @"%@", error);
    NSDictionary *actual = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:&error];
    XCTAssertEqualObjects(protection, actual[NSFileProtectionKey]);
    if (protection != nil) {
      XCTAssertEqualObjects(protection, NSFileProtectionCompleteUntilFirstUserAuthentication);
    }
  }
  id protection = @"stale";
  NSError *error = nil;
  XCTAssertFalse([self.wal getWALProtectionAtURL:[file URLByAppendingPathExtension:@"missing"]
      value:&protection error:&error]);
  XCTAssertNil(protection);
  XCTAssertNotNil(error);
}

- (void)testArgumentsRejectDuplicateNegativeZeroAndUnsafeInteger {
  NSError *error = nil;
  XCTAssertNil(DSHAgentParseArgumentsJSON(@"{\"a\":1,\"a\":2}", &error));
  XCTAssertNotNil(error);
  error = nil;
  XCTAssertNil(DSHAgentParseArgumentsJSON(@"{\"a\":-0}", &error));
  XCTAssertNotNil(error);
  error = nil;
  XCTAssertNil(DSHAgentParseArgumentsJSON(@"{\"a\":9007199254740992}", &error));
  XCTAssertNotNil(error);
  error = nil;
  XCTAssertNotNil(DSHAgentParseArgumentsJSON(@"{\"a\":1}", &error));
  XCTAssertNil(error);
}

- (void)testArgumentsRejectUnsafeDecimalExponentAndAllowFullWritePayloadWrapper {
  NSError *error = nil;
  XCTAssertNil(DSHAgentParseArgumentsJSON(@"{\"a\":1e20}", &error));
  XCTAssertNotNil(error);
  error = nil;
  XCTAssertNil(DSHAgentParseArgumentsJSON(@"{\"a\":9007199254740991.1}", &error));
  XCTAssertNotNil(error);
  error = nil;
  XCTAssertNil(DSHAgentParseArgumentsJSON(@"{\"a\":-0e1}", &error));
  XCTAssertNotNil(error);

  NSMutableString *fullContent = [NSMutableString stringWithString:@"{\"content\":\""];
  [fullContent appendString:[@"x" stringByPaddingToLength:32768
                                             withString:@"x"
                                        startingAtIndex:0]];
  [fullContent appendString:@"\"}"];
  error = nil;
  XCTAssertNotNil(DSHAgentParseArgumentsJSON(fullContent, &error));
  XCTAssertNil(error);

  NSMutableString *worstEscaped = [NSMutableString stringWithString:
      @"{\"content\":\""];
  for (NSUInteger index = 0; index < 32768; index += 1) {
    [worstEscaped appendString:@"\\u0000"];
  }
  [worstEscaped appendString:
      @"\",\"path\":\"file.txt\",\"expected_revision\":null}"];
  NSUInteger escapedBytes = [worstEscaped lengthOfBytesUsingEncoding:
      NSUTF8StringEncoding];
  XCTAssertGreaterThan(escapedBytes, (NSUInteger)128 * 1024);
  XCTAssertLessThan(escapedBytes, (NSUInteger)256 * 1024);
  error = nil;
  XCTAssertNotNil(DSHAgentParseArgumentsJSON(worstEscaped, &error));
  XCTAssertNil(error);

  // Path legality is not part of a call's identity: the digest still binds
  // the call, and the tool refuses the arguments with a value-free reason.
  error = nil;
  XCTAssertNotNil(DSHAgentArgumentsSHA256(
      @"read_file", @"{\"path\":\"a\\u0000b\"}", &error));
  XCTAssertNil(error);
  NSString *code = nil;
  NSString *reason = nil;
  XCTAssertFalse(DSHAgentToolArgumentsAccepted(
      @"read_file", DSHAgentParseArgumentsJSON(@"{\"path\":\"a\\u0000b\"}", nil),
      &code, &reason));
  XCTAssertEqualObjects(code, @"E_AGENT_BAD_PATH");
  XCTAssertEqualObjects(reason, @"path_contains_disallowed_segment_or_character");
  XCTAssertNotNil(DSHAgentArgumentsSHA256(
      @"read_file", @"{\"path\":\"e\\u0301.txt\"}", &error));
  XCTAssertFalse(DSHAgentToolArgumentsAccepted(
      @"read_file", DSHAgentParseArgumentsJSON(@"{\"path\":\"e\\u0301.txt\"}", nil),
      &code, &reason));
  XCTAssertEqualObjects(code, @"E_AGENT_BAD_PATH");
  XCTAssertFalse(DSHAgentToolArgumentsAccepted(
      @"read_file", DSHAgentParseArgumentsJSON(@"{\"path\":\"/workspace/a.txt\"}", nil),
      &code, &reason));
  XCTAssertEqualObjects(code, @"E_AGENT_BAD_PATH");
  XCTAssertEqualObjects(reason, @"path_must_be_relative_to_workspace_root");
  XCTAssertTrue(DSHAgentToolArgumentsAccepted(
      @"read_file", DSHAgentParseArgumentsJSON(@"{\"path\":\"a.txt\"}", nil),
      &code, &reason));
}

- (void)testContractGitArgumentsOmitFrozenNativeFields {
  NSError *error = nil;
  XCTAssertNotNil(DSHAgentArgumentsSHA256(
      @"git_commit", @"{\"message\":\"m\"}", &error));
  XCTAssertNil(error);
  error = nil;
  XCTAssertNotNil(DSHAgentArgumentsSHA256(@"git_push", @"{}", &error));
  XCTAssertNil(error);

  // Frozen native fields are refused by the tool, not by the identity digest.
  NSString *code = nil;
  NSString *reason = nil;
  XCTAssertFalse(DSHAgentToolArgumentsAccepted(
      @"git_commit",
      DSHAgentParseArgumentsJSON(
          @"{\"message\":\"m\",\"tree_oid\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}", nil),
      &code, &reason));
  XCTAssertEqualObjects(code, @"E_AGENT_BAD_ARGUMENTS");
  XCTAssertEqualObjects(reason, @"arguments_do_not_match_tool_schema");
  XCTAssertFalse(DSHAgentToolArgumentsAccepted(
      @"git_push", DSHAgentParseArgumentsJSON(@"{\"remote_ref\":\"refs/heads/main\"}", nil),
      &code, &reason));
  XCTAssertEqualObjects(code, @"E_AGENT_BAD_ARGUMENTS");
  XCTAssertTrue(DSHAgentToolArgumentsAccepted(
      @"git_commit", DSHAgentParseArgumentsJSON(@"{\"message\":\"m\"}", nil), &code, &reason));
}

- (void)testGitCommitFeedbackMustMatchFrozenTreePrecondition {
  NSError *error = nil;
  NSMutableDictionary *root = [[self root] mutableCopy];
  root[@"kind"] = @"project";
  root[@"project_id"] = @"66666666-6666-4666-8666-666666666666";
  root[@"capabilities"] = @[@"git_commit"];
  NSString *attemptId = @"22222222-2222-4222-8222-222222222222";
  NSDictionary *transcript = [self.transcripts
      createAgentTranscriptWithRequest:@{
        @"schema_version" : @1,
        @"attempt_id" : attemptId,
        @"root" : root,
      }
      error:&error];
  XCTAssertNotNil(transcript);
  XCTAssertNil(error);

  NSString *arguments = @"{\"message\":\"m\"}";
  NSString *argumentsSHA = DSHAgentArgumentsSHA256(@"git_commit", arguments,
                                                    &error);
  NSData *messageBytes = [@"m" dataUsingEncoding:NSUTF8StringEncoding];
  NSString *messageSHA = DSHAgentHB(@"commit-message", messageBytes, &error);
  NSString *treeOID = [@"a" stringByPaddingToLength:40 withString:@"a"
                                      startingAtIndex:0];
  NSString *commitOID = [@"b" stringByPaddingToLength:40 withString:@"b"
                                        startingAtIndex:0];
  NSDictionary *identity = @{
    @"schema_version" : @1,
    @"name" : @"Rish Agent",
    @"email" : @"agent@rish.local",
    @"timestamp_seconds" : @1,
    @"timezone_offset" : @"+0000",
  };
  NSDictionary *precondition = @{
    @"schema_version" : @2,
    @"kind" : @"git_commit",
    @"object_format" : @"sha1",
    @"pre_head_oid" : NSNull.null,
    @"ordered_parent_oids" : @[],
    @"staged_index_sha256" :
        [@"c" stringByPaddingToLength:64 withString:@"c" startingAtIndex:0],
    @"tree_oid" : treeOID,
    @"author" : identity,
    @"committer" : identity,
    @"message_blob_ref" : @"message",
    @"message_sha256" : messageSHA,
    @"message_bytes" : @1,
    @"encoding_header" : NSNull.null,
    @"signature_policy" : @"unsigned",
    @"extra_headers" : @[],
    @"stage_all" : @YES,
    @"commit_payload_sha256" :
        [@"d" stringByPaddingToLength:64 withString:@"d" startingAtIndex:0],
    @"expected_commit_oid" : commitOID,
  };
  NSDictionary *baseLocator = @{
    @"schema_version" : @2,
    @"task_id" : @"33333333-3333-4333-8333-333333333333",
    @"attempt_id" : attemptId,
    @"round_id" : @"44444444-4444-4444-8444-444444444444",
    @"round_index" : @0,
    @"call_index" : @0,
    @"call_id" : @"git-call",
    @"idempotency_key" :
        [@"0" stringByPaddingToLength:64 withString:@"0" startingAtIndex:0],
  };
  NSMutableDictionary *locator = [baseLocator mutableCopy];
  locator[@"idempotency_key"] = DSHAgentIdempotencyKeyForLocator(
      baseLocator, root[@"root_fingerprint_sha256"], argumentsSHA, &error);
  NSDictionary *preparedBatch = [self.ledger prepareAgentToolBatchWithRequest:@{
    @"schema_version" : @2,
    @"task_id" : locator[@"task_id"],
    @"attempt_id" : locator[@"attempt_id"],
    @"round_id" : locator[@"round_id"],
    @"round_index" : locator[@"round_index"],
    @"round_revision" : @1,
    @"root" : root,
    @"transcript" : transcript,
    @"policy" : [self agentPolicy],
    @"expected_batch_revision" : @0,
    @"expected_reserved_write_bytes" : @0,
    @"calls" : @[@{
      @"call_index" : @0,
      @"call_id" : locator[@"call_id"],
      @"name" : @"git_commit",
      @"arguments_json" : arguments,
      @"arguments_sha256" : argumentsSHA,
      @"safe_summary_key" : @"agent.git_commit",
      @"access" : @"auto",
      @"precondition" : precondition,
      @"reserved_write_bytes" : @0,
    }],
  } error:&error];
  XCTAssertNotNil(preparedBatch);
  XCTAssertEqualObjects(preparedBatch[@"calls"][0][@"idempotency_key"],
                        locator[@"idempotency_key"]);
  XCTAssertEqualObjects(preparedBatch[@"effect_gate"], @"closed");
  XCTAssertNil(error);
  NSDictionary *opened = [self.ledger openAgentWriteBatchEffectGateWithRequest:@{
    @"schema_version" : @2,
    @"task_id" : locator[@"task_id"],
    @"attempt_id" : locator[@"attempt_id"],
    @"round_id" : locator[@"round_id"],
    @"round_index" : locator[@"round_index"],
    @"expected_batch_revision" : preparedBatch[@"batch_revision"],
    @"manifest_sha256" : preparedBatch[@"manifest_sha256"],
    @"expected_effect_gate" : @"closed",
  } error:&error];
  XCTAssertEqualObjects(opened[@"status"], @"open");
  XCTAssertNil(error);

  NSString *nativeTaskId = @"55555555-5555-4555-8555-555555555555";
  NSDictionary *owner = @{
    @"schema_version" : @1,
    @"task_id" : locator[@"task_id"],
    @"launch_id" : self.wal.launchId,
    @"native_task_id" : nativeTaskId,
    @"owner_generation" : @1,
    @"heartbeat_at" : @"2026-08-30T00:00:00.000Z",
  };
  XCTAssertTrue([self.wal registerNativeTaskId:nativeTaskId error:&error]);
  NSDictionary *claimed = [self.ledger
      claimAgentExecutionWithLocator:locator
                 expectedRowRevision:@1
                                owner:owner
                                error:&error];
  XCTAssertNotNil(claimed);
  NSDictionary *cas = @{
    @"schema_version" : @2,
    @"locator" : locator,
    @"expected_row_revision" : @2,
    @"expected_state" : @"running",
    @"expected_owner_generation" : @1,
    @"expected_launch_id" : self.wal.launchId,
    @"expected_native_task_id" : nativeTaskId,
    @"expected_transcript_generation" : transcript[@"generation"],
    @"expected_transcript_sha256" : transcript[@"transcript_sha256"],
    @"expected_root_fingerprint_sha256" : root[@"root_fingerprint_sha256"],
    @"expected_binding_revision" : @1,
  };
  XCTAssertNotNil([self.ledger markAgentExecutionDispatchedWithCAS:cas
                                                               error:&error]);
  XCTAssertNil(error);

  NSMutableDictionary *settleCAS = [cas mutableCopy];
  settleCAS[@"expected_row_revision"] = @3;
  __block NSError *settlementError = nil;
  NSDictionary *(^settleWithTree)(NSString *) = ^NSDictionary *(NSString *feedbackTree) {
    NSDictionary *feedbackObject = @{
      @"schema_version" : @1,
      @"name" : @"git_commit",
      @"outcome" : @"ok",
      @"payload" : @{
        @"schema_version" : @1,
        @"commit_oid" : commitOID,
        @"tree_oid" : feedbackTree,
      },
    };
    settlementError = nil;
    NSData *feedbackBytes = DSHAgentCanonicalJSON(feedbackObject, &settlementError);
    NSString *feedback = [[NSString alloc] initWithData:feedbackBytes
                                                encoding:NSUTF8StringEncoding];
    NSString *resultSHA = DSHAgentHB(@"tool-result", feedbackBytes, &settlementError);
    NSDictionary *receipt = @{
      @"schema_version" : @1,
      @"call_id" : locator[@"call_id"],
      @"name" : @"git_commit",
      @"arguments_sha256" : argumentsSHA,
      @"result_sha256" : resultSHA,
      @"result_bytes" : @(feedbackBytes.length),
      @"truncated" : @NO,
      @"duration_ms" : @1,
      @"outcome" : @"ok",
      @"failure_code" : NSNull.null,
      @"approval_reference" : NSNull.null,
    };
    return [self.ledger settleAgentExecutionWithCAS:settleCAS
                                               patch:@{
                                                 @"state" : @"settled",
                                                 @"settled_facts" : @{
                                                   @"schema_version" : @1,
                                                   @"kind" : @"git_commit",
                                                   @"actual_commit_oid" : commitOID,
                                                 },
                                                 @"receipt" : receipt,
                                               }
                                              message:@{
                                                @"schema_version" : @1,
                                                @"role" : @"tool",
                                                @"round_index" : @0,
                                                @"call_id" : locator[@"call_id"],
                                                @"content" : feedback,
                                                @"truncated" : @NO,
                                              }
                                                error:&settlementError];
  };

  NSString *mismatchedTree = [@"b" stringByPaddingToLength:40 withString:@"b"
                                           startingAtIndex:0];
  error = nil;
  XCTAssertNil(settleWithTree(mismatchedTree));
  error = settlementError;
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorConflict);
  NSDictionary *afterRejected = [self.wal snapshotWithError:&error];
  XCTAssertEqualObjects(afterRejected[@"ledger"][0][@"state"], @"running");

  error = nil;
  XCTAssertNotNil(settleWithTree(treeOID));
  error = settlementError;
  XCTAssertNil(error);
}

- (void)testTranscriptAttemptCannotRebindToDifferentRoot {
  NSError *error = nil;
  NSDictionary *created = [self.transcripts
      createAgentTranscriptWithRequest:@{
        @"schema_version" : @1,
        @"attempt_id" : @"22222222-2222-4222-8222-222222222222",
        @"root" : [self root],
      }
      error:&error];
  XCTAssertNotNil(created);
  NSMutableDictionary *differentRoot = [[self root] mutableCopy];
  differentRoot[@"root_fingerprint_sha256"] =
      @"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
  error = nil;
  NSDictionary *rebound = [self.transcripts
      createAgentTranscriptWithRequest:@{
        @"schema_version" : @1,
        @"attempt_id" : @"22222222-2222-4222-8222-222222222222",
        @"root" : differentRoot,
      }
      error:&error];
  XCTAssertNil(rebound);
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorConflict);
}

- (void)testFeedbackUnionIsClosedAndListFeedbackHasEncodedCap {
  NSError *error = nil;
  NSString *unknownFailure =
      @"{\"name\":\"read_file\",\"outcome\":\"failed\",\"payload\":{\"failure_code\":\"E_AGENT_NOT_ALLOWED\",\"schema_version\":1},\"schema_version\":1}";
  XCTAssertFalse(DSHAgentValidateNativeToolFeedbackString(unknownFailure, &error));
  XCTAssertNotNil(error);

  NSMutableArray *entries = [NSMutableArray arrayWithCapacity:1000];
  NSString *longName = [@"x" stringByPaddingToLength:128
                                      withString:@"x"
                                 startingAtIndex:0];
  for (NSUInteger index = 0; index < 1000; index += 1) {
    [entries addObject:@{
      @"schema_version" : @1,
      @"name" : longName,
      @"type" : @"file",
      @"revision" : @"r",
    }];
  }
  NSDictionary *feedback = @{
    @"schema_version" : @1,
    @"name" : @"list_dir",
    @"outcome" : @"ok",
    @"payload" : @{
      @"schema_version" : @1,
      @"entries" : entries,
      @"truncated" : @NO,
    },
  };
  NSData *bytes = DSHAgentCanonicalJSON(feedback, &error);
  XCTAssertGreaterThan(bytes.length, (NSUInteger)64 * 1024);
  NSString *encoded = [[NSString alloc] initWithData:bytes
                                             encoding:NSUTF8StringEncoding];
  error = nil;
  XCTAssertFalse(DSHAgentValidateNativeToolFeedbackString(encoded, &error));
  XCTAssertNotNil(error);
}

- (void)testTerminalCleanupRequiresOwnerAndIsIdempotent {
  NSError *error = nil;
  NSDictionary *transcript = [self.transcripts
      createAgentTranscriptWithRequest:@{
        @"schema_version" : @1,
        @"attempt_id" : @"22222222-2222-4222-8222-222222222222",
        @"root" : [self root],
      }
      error:&error];
  NSString *cleanupId = @"33333333-3333-4333-8333-333333333333";
  NSString *cleanupOwner = @"44444444-4444-4444-8444-444444444444";
  NSDictionary *terminal = [self.transcripts
      markAgentTranscriptTerminalWithRequest:@{
        @"schema_version" : @1,
        @"attempt_id" : @"22222222-2222-4222-8222-222222222222",
        @"root" : [self root],
        @"transcript" : transcript,
        @"reason" : @"completed",
        @"cleanup_id" : cleanupId,
        @"cleanup_owner" : cleanupOwner,
      }
      error:&error];
  XCTAssertEqualObjects(terminal[@"status"], @"terminal");
  XCTAssertNil(error);
  NSDictionary *discarded = [self.transcripts
      discardAgentTranscriptWithRequest:@{
        @"schema_version" : @1,
        @"attempt_id" : @"22222222-2222-4222-8222-222222222222",
        @"transcript_ref" : transcript[@"transcript_ref"],
        @"transcript_sha256" : transcript[@"transcript_sha256"],
        @"cleanup_id" : cleanupId,
        @"cleanup_owner" : cleanupOwner,
      }
      error:&error];
  XCTAssertEqualObjects(discarded[@"status"], @"discarded");
  XCTAssertNil(error);
  NSDictionary *cleanup = [self.transcripts
      queryAgentTranscriptCleanupWithRequest:@{
        @"schema_version" : @1,
        @"cleanup_id" : cleanupId,
      }
      error:&error];
  XCTAssertEqualObjects(cleanup[@"status"], @"discarded");

  error = nil;
  NSDictionary *mismatchedReplay = [self.transcripts
      discardAgentTranscriptWithRequest:@{
        @"schema_version" : @1,
        @"attempt_id" : @"22222222-2222-4222-8222-222222222222",
        @"transcript_ref" : transcript[@"transcript_ref"],
        @"transcript_sha256" : transcript[@"transcript_sha256"],
        @"cleanup_id" : cleanupId,
        @"cleanup_owner" : @"55555555-5555-4555-8555-555555555555",
      }
      error:&error];
  XCTAssertNil(mismatchedReplay);
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorConflict);
}

/// The core holds the committed state between transactions, so the store no
/// longer re-reads the file to learn what is committed. It is only allowed to
/// trust that while the file it was read from is still the file on disk: a
/// fixture, a restore or any future tool that replaces the WAL behind the
/// store's back must be seen, not served from memory.
- (void)testCommittedStateIsRereadWhenTheFileIsReplacedBehindTheStore {
  NSError *error = nil;
  XCTAssertTrue([self.wal performAtomicTransaction:^BOOL(NSMutableDictionary *state,
                                                          NSError **mutationError) {
    (void)mutationError;
    state[@"cleanup"] = @[];
    return YES;
  } error:&error]);
  XCTAssertNil(error);
  NSDictionary *committed = [self.wal snapshotWithError:&error];
  XCTAssertNotNil(committed);
  NSUInteger generation = [committed[@"generation"] unsignedIntegerValue];

  // Replace the file with a state the store has never seen. Its generation is
  // far ahead, so a stale resident state would refuse the next write for a
  // generation conflict instead of building on these bytes.
  NSMutableDictionary *replaced = [@{
    @"schema_version" : @2, @"generation" : @(generation + 41),
    @"authorities" : @[], @"operations" : @[], @"operation_results" : @[],
    @"transcripts" : @[], @"rounds" : @[], @"ledger" : @[],
    @"reservations" : @[], @"cleanup" : @[], @"dispatch" : @[],
    @"batches" : @[], @"denied_calls" : @[],
  } mutableCopy];
  XCTAssertTrue([self writeCanonicalWALState:replaced error:&error], @"%@", error);

  __block NSUInteger observed = 0;
  XCTAssertTrue([self.wal performAtomicTransaction:^BOOL(NSMutableDictionary *state,
                                                          NSError **mutationError) {
    (void)mutationError;
    observed = [state[@"generation"] unsignedIntegerValue];
    return YES;
  } error:&error]);
  XCTAssertNil(error);
  XCTAssertEqual(observed, generation + 41);
  XCTAssertEqual([[self.wal snapshotWithError:&error][@"generation"] unsignedIntegerValue],
                 generation + 42);
}

- (void)testSchemaOneMigrationIsAtomicExactAndUpgradesRoundV3MixedBatch {
  NSError *error = nil;
  NSDictionary *transcript = [self.transcripts
      createAgentTranscriptWithRequest:@{
        @"schema_version" : @1,
        @"attempt_id" : @"22222222-2222-4222-8222-222222222222",
        @"root" : [self root],
      }
      error:&error];
  XCTAssertNotNil(transcript);
  NSDictionary *v2 = [self.wal snapshotWithError:&error];
  NSDictionary *locator = @{
    @"schema_version" : @1,
    @"task_id" : @"33333333-3333-4333-8333-333333333333",
    @"attempt_id" : @"22222222-2222-4222-8222-222222222222",
    @"round_id" : @"44444444-4444-4444-8444-444444444444",
    @"round_index" : @0,
  };
  NSDictionary *legacyRound = @{
    @"schema_version" : @2,
    @"locator" : locator,
    @"row_revision" : @1,
    @"root_fingerprint_sha256" : [self root][@"root_fingerprint_sha256"],
    @"binding_revision" : @1,
    @"request_sha256" :
        @"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    @"transcript_before" : transcript,
    @"launch_attempt" : @1,
    @"state" : @"failed_retryable",
    @"owner" : NSNull.null,
    @"failure_code" : @"E_AGENT_TOOL_FAILED",
    @"completion_receipt" : NSNull.null,
    @"transcript_after" : NSNull.null,
    @"calls" : @[
      @{
        @"schema_version" : @1,
        @"call_id" : @"provider-unknown",
        @"name" : @"provider_unknown_tool",
        @"arguments_sha256" :
            @"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        @"safe_summary_key" : @"provider.unknown",
        @"access" : @"auto",
      },
      @{
        @"schema_version" : @1,
        @"call_id" : @"legacy-write",
        @"name" : @"write_file",
        @"arguments_sha256" :
            @"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        @"safe_summary_key" : @"agent.write_file",
        @"access" : @"conversation_confirm",
      },
    ],
    @"terminal_kind" : NSNull.null,
    @"created_at" : @"2026-08-30T00:00:00.000Z",
    @"updated_at" : @"2026-08-30T00:00:00.000Z",
  };
  NSDictionary *executionLocatorBase = @{
    @"schema_version" : @2,
    @"task_id" : locator[@"task_id"],
    @"attempt_id" : locator[@"attempt_id"],
    @"round_id" : locator[@"round_id"],
    @"round_index" : @0,
    @"call_index" : @1,
    @"call_id" : @"legacy-write",
    @"idempotency_key" :
        @"0000000000000000000000000000000000000000000000000000000000000000",
  };
  NSMutableDictionary *executionLocator = [executionLocatorBase mutableCopy];
  executionLocator[@"idempotency_key"] = DSHAgentIdempotencyKeyForLocator(
      executionLocatorBase, [self root][@"root_fingerprint_sha256"],
      @"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
      &error);
  XCTAssertNotNil(executionLocator[@"idempotency_key"]);
  NSDictionary *writePrecondition = @{
    @"schema_version" : @2,
    @"kind" : @"write_file",
    @"relative_path_sha256" :
        @"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    @"prior" : @{ @"schema_version" : @1, @"kind" : @"absent" },
    @"content_sha256" :
        @"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    @"content_bytes" : @1,
  };
  NSDictionary *legacyLedger = @{
    @"schema_version" : @2,
    @"locator" : executionLocator,
    @"row_revision" : @1,
    @"root_fingerprint_sha256" : [self root][@"root_fingerprint_sha256"],
    @"binding_revision" : @1,
    @"transcript_before" : transcript,
    @"name" : @"write_file",
    @"arguments_sha256" :
        @"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    @"precondition" : writePrecondition,
    @"reserved_write_bytes" : @1,
    @"state" : @"intent",
    @"owner" : NSNull.null,
    @"settled_facts" : NSNull.null,
    @"transcript_after" : NSNull.null,
    @"receipt" : NSNull.null,
    @"created_at" : @"2026-08-30T00:00:00.000Z",
    @"updated_at" : @"2026-08-30T00:00:00.000Z",
  };
  NSDictionary *legacyManifestCall = @{
    @"locator" : executionLocator,
    @"relative_path_sha256" : writePrecondition[@"relative_path_sha256"],
    @"prior" : writePrecondition[@"prior"],
    @"content_sha256" : writePrecondition[@"content_sha256"],
    @"content_bytes" : @1,
  };
  NSString *legacyManifestSHA = DSHAgentHJ(@"write-manifest", @{
    @"calls" : @[legacyManifestCall],
  }, &error);
  XCTAssertNotNil(legacyManifestSHA);
  NSDictionary *legacyBatch = @{
    @"schema_version" : @1,
    @"task_id" : locator[@"task_id"],
    @"attempt_id" : locator[@"attempt_id"],
    @"root_fingerprint_sha256" : [self root][@"root_fingerprint_sha256"],
    @"binding_revision" : @1,
    @"manifest_sha256" : legacyManifestSHA,
    @"manifest_calls" : @[legacyManifestCall],
    @"write_keys" : @[executionLocator[@"idempotency_key"]],
    @"reserved_write_bytes" : @1,
    @"reservation_delta_bytes" : @1,
    @"attempt_reserved_write_bytes" : @1,
    @"reservation_version" : @1,
    @"effect_gate" : @"closed",
    @"created_at" : @"2026-08-30T00:00:00.000Z",
    @"updated_at" : @"2026-08-30T00:00:00.000Z",
  };
  NSDictionary *legacyReservation = @{
    @"schema_version" : @1,
    @"task_id" : locator[@"task_id"],
    @"attempt_id" : locator[@"attempt_id"],
    @"root_fingerprint_sha256" : [self root][@"root_fingerprint_sha256"],
    @"binding_revision" : @1,
    @"policy" : [self agentPolicy],
    @"reserved_write_bytes" : @1,
    @"reservation_version" : @1,
    @"keys" : @[@{
      @"idempotency_key" : executionLocator[@"idempotency_key"],
      @"relative_path_sha256" : writePrecondition[@"relative_path_sha256"],
      @"content_sha256" : writePrecondition[@"content_sha256"],
      @"content_bytes" : @1,
      @"state" : @"active",
    }],
  };
  NSDictionary *legacy = @{
    @"schema_version" : @1,
    @"generation" : v2[@"generation"],
    @"transcripts" : v2[@"transcripts"],
    @"rounds" : @[legacyRound],
    @"ledger" : @[legacyLedger],
    @"reservations" : @[legacyReservation],
    @"cleanup" : @[],
    @"dispatch" : @[
      @{
        @"schema_version" : @1,
        @"kind" : @"round",
        @"locator" : locator,
        @"dispatch_state" : @"not_dispatched",
      },
      @{
        @"schema_version" : @1,
        @"kind" : @"execution",
        @"locator" : executionLocator,
        @"dispatch_state" : @"not_dispatched",
      },
    ],
    @"batches" : @[legacyBatch],
  };
  XCTAssertTrue([self writeCanonicalWALState:legacy error:&error]);

  DSHAgentNativeWAL *relaunch = [[DSHAgentNativeWAL alloc]
      initWithRootURL:self.rootURL
      clock:^NSDate * { return [NSDate dateWithTimeIntervalSince1970:1787961600]; }
      identifierGenerator:^NSString * {
        return @"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
      }
      faultHook:nil];
  XCTAssertTrue([relaunch ensureStorageWithError:&error]);
  NSDictionary *migrated = [relaunch snapshotWithError:&error];
  XCTAssertEqualObjects(migrated[@"schema_version"], @2);
  NSSet *expectedRootKeys = [NSSet setWithArray:@[
    @"schema_version", @"generation", @"authorities", @"operations",
    @"operation_results", @"transcripts", @"rounds", @"ledger",
    @"reservations", @"cleanup", @"dispatch", @"batches", @"denied_calls",
  ]];
  XCTAssertEqualObjects([NSSet setWithArray:migrated.allKeys], expectedRootKeys);
  XCTAssertEqualObjects(migrated[@"authorities"], @[]);
  XCTAssertEqualObjects(migrated[@"operations"], @[]);
  XCTAssertEqualObjects(migrated[@"operation_results"], @[]);
  XCTAssertEqualObjects(migrated[@"denied_calls"], @[]);
  NSDictionary *migratedBatch = migrated[@"batches"][0];
  XCTAssertEqualObjects(migratedBatch[@"schema_version"], @2);
  XCTAssertEqualObjects(migratedBatch[@"kind"], @"write_batch");
  XCTAssertEqualObjects(migratedBatch[@"round_id"], locator[@"round_id"]);
  XCTAssertEqualObjects(migratedBatch[@"round_index"], @0);
  XCTAssertEqualObjects(migratedBatch[@"batch_revision"], @1);
  XCTAssertNil(migratedBatch[@"reservation_version"]);
  NSDictionary *migratedCall = migratedBatch[@"manifest_calls"][0];
  XCTAssertEqualObjects(migratedCall[@"schema_version"], @2);
  XCTAssertEqualObjects(migratedCall[@"mutation_kind"], @"file_write");
  NSString *expectedPreconditionSHA = DSHAgentHJ(@"tool-precondition", @{
    @"schema_version" : @1,
    @"name" : @"write_file",
    @"precondition" : writePrecondition,
  }, &error);
  XCTAssertEqualObjects(migratedCall[@"precondition_sha256"],
                        expectedPreconditionSHA);
  XCTAssertEqualObjects(migratedBatch[@"manifest_sha256"],
                        DSHAgentHJ(@"write-manifest", @{
                          @"calls" : @[migratedCall],
                        }, &error));
  XCTAssertNil(error);
  NSDictionary *roundRow = migrated[@"rounds"][0];
  XCTAssertEqualObjects(roundRow[@"schema_version"], @3);
  XCTAssertEqualObjects(roundRow[@"batch_class"], @"mixed");
  XCTAssertEqualObjects(roundRow[@"executable_call_count"], @1);
  XCTAssertEqualObjects(roundRow[@"denied_call_count"], @1);
  XCTAssertEqualObjects(roundRow[@"calls"][0][@"call_index"], @0);
  XCTAssertEqualObjects(roundRow[@"calls"][0][@"access"], @"durable_deny");
  XCTAssertEqualObjects(roundRow[@"calls"][0][@"approval_state"],
                        @"durable_denied");
  XCTAssertEqualObjects(roundRow[@"calls"][1][@"call_index"], @1);
  XCTAssertEqualObjects(roundRow[@"calls"][1][@"access"],
                        @"conversation_confirm");
  XCTAssertEqualObjects(roundRow[@"calls"][1][@"approval_state"], @"deferred");
}

- (void)testPreparedOperationConflictsOnDifferentRequestAndReplaysSnapshot {
  NSError *error = nil;
  NSDictionary *transcript = [self.transcripts
      createAgentTranscriptWithRequest:@{
        @"schema_version" : @1,
        @"attempt_id" : @"22222222-2222-4222-8222-222222222222",
        @"root" : [self root],
      }
      error:&error];
  NSString *operationID = @"99999999-9999-4999-8999-999999999999";
  NSDictionary *authority = [self prepareAuthorityForTranscript:transcript];
  NSDictionary *request = [self prepareRequestWithOperationID:operationID
                                                    transcript:transcript];
  NSDictionary *safeResult = [self prepareSafeResultWithOperationID:operationID
                                                           transcript:transcript];
  NSDictionary *prepared = DSHAgentNativeWALPrepareAuthorityOperation(
      self.wal, authority, request, safeResult, &error);
  XCTAssertNotNil(prepared);
  XCTAssertEqualObjects(prepared[@"result"], safeResult);
  NSString *requestSHA = prepared[@"request_sha256"];
  XCTAssertNotNil(requestSHA);

  XCTAssertTrue([self.wal performAtomicTransaction:^BOOL(
      NSMutableDictionary *state, NSError **mutationError) {
    (void)mutationError;
    NSMutableArray *authorities = [state[@"authorities"] mutableCopy];
    NSMutableDictionary *current = [authorities[0] mutableCopy];
    current[@"authority_revision"] = @2;
    current[@"reserved_write_bytes"] = @1;
    current[@"updated_at"] = @"2026-08-30T00:00:01.000Z";
    authorities[0] = current;
    state[@"authorities"] = authorities;
    return YES;
  } error:&error]);
  NSDictionary *replayed = DSHAgentNativeWALPrepareAuthorityOperation(
      self.wal, authority, request, safeResult, &error);
  XCTAssertEqualObjects(replayed[@"status"], @"replayed");
  XCTAssertEqualObjects(replayed[@"result"], safeResult);

  NSMutableDictionary *differentRequest = [request mutableCopy];
  differentRequest[@"expected_policy_version"] = NSNull.null;
  error = nil;
  XCTAssertNil(DSHAgentNativeWALPrepareAuthorityOperation(
      self.wal, authority, differentRequest, safeResult, &error));
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorConflict);
  NSDictionary *state = [self.wal snapshotWithError:&error];
  XCTAssertEqual([(NSArray *)state[@"operations"] count], (NSUInteger)1);
  XCTAssertEqual([(NSArray *)state[@"operation_results"] count], (NSUInteger)1);

  NSDictionary *query = DSHAgentNativeWALQueryOperation(
      self.wal, operationID, requestSHA,
      @"33333333-3333-4333-8333-333333333333",
      @"22222222-2222-4222-8222-222222222222", &error);
  XCTAssertEqualObjects(query[@"status"], @"found");
  query = DSHAgentNativeWALQueryOperation(
      self.wal, operationID,
      @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      @"33333333-3333-4333-8333-333333333333",
      @"22222222-2222-4222-8222-222222222222", &error);
  XCTAssertEqualObjects(query[@"status"], @"conflict");
}

- (void)testUnknownAndAmbiguousOperationSnapshotsSurviveRelaunch {
  NSError *error = nil;
  NSString *taskID = @"33333333-3333-4333-8333-333333333333";
  NSString *attemptID = @"22222222-2222-4222-8222-222222222222";
  NSString *conversationID = @"77777777-7777-4777-8777-777777777777";
  NSDictionary *transcript = [self.transcripts
      createAgentTranscriptWithRequest:@{
        @"schema_version" : @1,
        @"attempt_id" : attemptID,
        @"root" : [self root],
      }
      error:&error];

  NSString *discardOperation = @"88888888-8888-4888-8888-888888888888";
  NSString *cleanupID = @"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
  NSDictionary *discardRequest = @{
    @"schema_version" : @2,
    @"operation_id" : discardOperation,
    @"cleanup_id" : cleanupID,
    @"task_id" : taskID,
    @"conversation_id" : conversationID,
    @"attempt_id" : attemptID,
    @"transcript_ref" : transcript[@"transcript_ref"],
    @"transcript_sha256" : transcript[@"transcript_sha256"],
  };
  NSDictionary *started = DSHAgentNativeWALStartOperation(
      self.wal, @"discard_agent_attempt", discardRequest, taskID, attemptID,
      @0, &error);
  XCTAssertEqualObjects(started[@"status"], @"started");
  NSDictionary *discardSafeResult = @{
    @"schema_version" : @2,
    @"result_kind" : @"discard_agent_attempt",
    @"result" : @{
      @"schema_version" : @2,
      @"status" : @"unknown",
      @"operation_id" : discardOperation,
      @"cleanup_id" : cleanupID,
      @"failure_code" : @"E_AGENT_PERSISTENCE",
    },
  };
  XCTAssertNotNil(DSHAgentNativeWALCommitOperation(
      self.wal, discardOperation, started[@"request_sha256"], taskID, attemptID,
      @"unknown", @"unknown", @{
        @"schema_version" : @2, @"kind" : @"none",
      }, nil, discardSafeResult, &error));

  NSString *roundOperation = @"77777777-8888-4888-8888-888888888888";
  NSString *roundID = @"44444444-4444-4444-8444-444444444444";
  NSDictionary *prepare = [self prepareRequestWithOperationID:roundOperation
                                                   transcript:transcript];
  NSDictionary *roundRequest = @{
    @"schema_version" : @2,
    @"operation_id" : roundOperation,
    @"controller_cas" : prepare[@"controller_cas"],
    @"committed_checkpoint" : prepare[@"committed_checkpoint"],
    @"task_id" : taskID,
    @"conversation_id" : conversationID,
    @"attempt_id" : attemptID,
    @"round_id" : roundID,
    @"round_index" : @0,
    @"launch_attempt" : @1,
    @"expected_round_revision" : @0,
    @"transport_schema_version" : @2,
    @"model" : @"deepseek-v4-flash",
    @"thinking_mode" : @"off",
    @"visible_history_sha256" : prepare[@"visible_history_sha256"],
    @"visible_message_count" : @0,
    @"project_context_sha256" : NSNull.null,
    @"transcript" : transcript,
    @"root" : [self root],
    @"registry_version" : @1,
    @"toolset_sha256" : [self agentRegistry][@"toolset_sha256"],
  };
  started = DSHAgentNativeWALStartOperation(
      self.wal, @"complete_agent_round_v2", roundRequest, taskID, attemptID,
      @0, &error);
  NSDictionary *ambiguousSafeResult = @{
    @"schema_version" : @2,
    @"result_kind" : @"complete_agent_round_v2",
    @"result" : @{
      @"schema_version" : @2,
      @"status" : @"ambiguous",
      @"operation_id" : roundOperation,
      @"task_id" : taskID,
      @"attempt_id" : attemptID,
      @"round_id" : roundID,
      @"round_index" : @0,
      @"launch_attempt" : @1,
      @"result_round_revision" : @1,
      @"transcript" : transcript,
      @"failure_code" : @"E_AGENT_ROUND_AMBIGUOUS",
    },
  };
  XCTAssertNotNil(DSHAgentNativeWALCommitOperation(
      self.wal, roundOperation, started[@"request_sha256"], taskID, attemptID,
      @"ambiguous", @"ambiguous", @{
        @"schema_version" : @2, @"kind" : @"none",
      }, nil, ambiguousSafeResult, &error));

  DSHAgentNativeWAL *relaunch = [[DSHAgentNativeWAL alloc]
      initWithRootURL:self.rootURL
      clock:^NSDate * { return [NSDate dateWithTimeIntervalSince1970:1787961600]; }
      identifierGenerator:^NSString * {
        return @"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
      }
      faultHook:nil];
  NSDictionary *state = [relaunch snapshotWithError:&error];
  XCTAssertNotNil(state);
  XCTAssertEqual([(NSArray *)state[@"operations"] count], (NSUInteger)2);
  XCTAssertEqualObjects(state[@"operations"][0][@"state"], @"unknown");
  XCTAssertEqualObjects(state[@"operations"][1][@"state"], @"ambiguous");
  XCTAssertEqual([(NSArray *)state[@"operation_results"] count], (NSUInteger)2);
}

- (void)testFailedToolOperationCommitsAndReplaysImmutableFailedSnapshot {
  NSError *error = nil;
  NSString *taskID = @"33333333-3333-4333-8333-333333333333";
  NSString *attemptID = @"22222222-2222-4222-8222-222222222222";
  NSString *conversationID = @"77777777-7777-4777-8777-777777777777";
  NSString *operationID = @"66666666-7777-4777-8777-777777777777";
  NSString *roundID = @"44444444-4444-4444-8444-444444444444";
  NSString *argumentsSHA =
      @"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
  NSString *idempotencyKey =
      @"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
  NSDictionary *transcript = [self.transcripts
      createAgentTranscriptWithRequest:@{
        @"schema_version" : @1,
        @"attempt_id" : attemptID,
        @"root" : [self root],
      }
      error:&error];
  XCTAssertNotNil(transcript);
  NSDictionary *prepare = [self prepareRequestWithOperationID:operationID
                                                   transcript:transcript];
  NSDictionary *request = @{
    @"schema_version" : @2,
    @"operation_id" : operationID,
    @"controller_cas" : prepare[@"controller_cas"],
    @"committed_checkpoint" : prepare[@"committed_checkpoint"],
    @"task_id" : taskID,
    @"conversation_id" : conversationID,
    @"attempt_id" : attemptID,
    @"round_id" : roundID,
    @"round_index" : @0,
    @"batch_kind" : @"read_only_batch",
    @"manifest_sha256" : NSNull.null,
    @"expected_batch_revision" : @1,
    @"call_index" : @0,
    @"call_id" : @"read-failed",
    @"name" : @"read_file",
    @"arguments_sha256" : argumentsSHA,
    @"idempotency_key" : idempotencyKey,
    @"expected_execution_revision" : @1,
    @"transcript" : transcript,
    @"root" : [self root],
    @"approval_reference" : NSNull.null,
  };
  NSDictionary *started = DSHAgentNativeWALStartOperation(
      self.wal, @"execute_agent_tool", request, taskID, attemptID, @0, &error);
  XCTAssertEqualObjects(started[@"status"], @"started");
  NSDictionary *receipt = @{
    @"schema_version" : @1,
    @"call_id" : @"read-failed",
    @"name" : @"read_file",
    @"arguments_sha256" : argumentsSHA,
    @"result_sha256" :
        @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    @"result_bytes" : @0,
    @"truncated" : @NO,
    @"duration_ms" : @1,
    @"outcome" : @"failed",
    @"failure_code" : @"E_AGENT_TOOL_FAILED",
    @"approval_reference" : NSNull.null,
  };
  NSDictionary *safeResult = @{
    @"schema_version" : @2,
    @"result_kind" : @"execute_agent_tool",
    @"result" : @{
      @"schema_version" : @2,
      @"status" : @"failed",
      @"operation_id" : operationID,
      @"task_id" : taskID,
      @"attempt_id" : attemptID,
      @"round_id" : roundID,
      @"round_index" : @0,
      @"call_index" : @0,
      @"call_id" : @"read-failed",
      @"name" : @"read_file",
      @"idempotency_key" : idempotencyKey,
      @"result_execution_revision" : @2,
      @"transcript" : transcript,
      @"receipt" : receipt,
      @"effect_may_have_occurred" : @NO,
    },
  };
  NSDictionary *resultRef = @{
    @"schema_version" : @2,
    @"kind" : @"tool",
    @"task_id" : taskID,
    @"attempt_id" : attemptID,
    @"round_id" : roundID,
    @"round_index" : @0,
    @"call_index" : @0,
    @"call_id" : @"read-failed",
    @"execution_revision" : @2,
  };
  NSDictionary *committed = DSHAgentNativeWALCommitOperation(
      self.wal, operationID, started[@"request_sha256"], taskID, attemptID,
      @"committed", @"failed", resultRef, @2, safeResult, &error);
  XCTAssertNotNil(committed);
  XCTAssertEqualObjects(committed[@"record"][@"state"], @"committed");
  XCTAssertEqualObjects(committed[@"record"][@"result_status"], @"failed");
  XCTAssertEqualObjects(committed[@"result"][@"result"][@"status"], @"failed");
  XCTAssertFalse([committed[@"result"] isKindOfClass:NSMutableDictionary.class]);
  XCTAssertFalse([committed[@"result"][@"result"]
      isKindOfClass:NSMutableDictionary.class]);

  NSDictionary *query = DSHAgentNativeWALQueryOperation(
      self.wal, operationID, started[@"request_sha256"], taskID, attemptID,
      &error);
  XCTAssertEqualObjects(query[@"status"], @"found");
  XCTAssertEqualObjects(query[@"record"][@"state"], @"committed");
  XCTAssertEqualObjects(query[@"record"][@"result_status"], @"failed");
  XCTAssertNotEqualObjects(query[@"record"][@"result_status"], @"completed");
  XCTAssertNotEqualObjects(query[@"record"][@"state"], @"rejected");

  DSHAgentNativeWAL *relaunch = [[DSHAgentNativeWAL alloc]
      initWithRootURL:self.rootURL
      clock:^NSDate * { return [NSDate dateWithTimeIntervalSince1970:1787961600]; }
      identifierGenerator:^NSString * {
        return @"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
      }
      faultHook:nil];
  NSDictionary *persisted = [relaunch snapshotWithError:&error];
  XCTAssertEqualObjects(persisted[@"operations"][0][@"state"], @"committed");
  XCTAssertEqualObjects(persisted[@"operations"][0][@"result_status"], @"failed");
  XCTAssertEqualObjects(
      persisted[@"operation_results"][0][@"result"][@"result"][@"status"],
      @"failed");
  NSDictionary *replayed = DSHAgentNativeWALStartOperation(
      relaunch, @"execute_agent_tool", request, taskID, attemptID, @0, &error);
  XCTAssertEqualObjects(replayed[@"status"], @"replayed");
  XCTAssertEqualObjects(replayed[@"record"][@"state"], @"committed");
  XCTAssertEqualObjects(replayed[@"record"][@"result_status"], @"failed");
  XCTAssertEqualObjects(replayed[@"result"][@"result"][@"status"], @"failed");
  XCTAssertNotEqualObjects(replayed[@"result"][@"result"][@"status"],
                           @"completed");
}

- (void)testTargetOperationBindsExactCancelAndRecoveryIdentityWithoutRewritingRequest {
  NSError *error = nil;
  NSString *taskID = @"31313131-3131-4131-8131-313131313131";
  NSString *attemptID = @"32323232-3232-4232-8232-323232323232";
  NSString *roundID = @"33333333-3333-4333-8333-333333333334";
  NSString *cancelOperationID = @"34343434-3434-4434-8434-343434343434";
  NSDictionary *toolTarget = @{
    @"schema_version" : @2, @"kind" : @"tool", @"task_id" : taskID,
    @"attempt_id" : attemptID, @"round_id" : roundID, @"round_index" : @0,
    @"call_index" : @0, @"call_id" : @"call-cancel",
    @"idempotency_key" :
        @"abababababababababababababababababababababababababababababababab",
  };
  NSDictionary *controller = @{
    @"schema_version" : @1,
    @"conversation_id" : @"35353535-3535-4535-8535-353535353535",
    @"task_id" : taskID, @"attempt_id" : attemptID,
    @"expected_controller_generation" : @1,
    @"expected_journal_revision" : @1,
    @"expected_session_generation" : @1,
    @"expected_session_sha256" :
        @"cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd",
  };
  NSDictionary *checkpoint = @{
    @"schema_version" : @1, @"journal_revision" : @1,
    @"session_generation" : @1,
    @"session_sha256" : controller[@"expected_session_sha256"],
  };
  NSDictionary *transcript = @{
    @"schema_version" : @1,
    @"transcript_ref" : @"36363636-3636-4636-8636-363636363636",
    @"generation" : @1,
    @"transcript_sha256" :
        @"dededededededededededededededededededededededededededededededede",
    @"transcript_bytes" : @1,
  };
  NSDictionary *cancelRequest = @{
    @"schema_version" : @2, @"operation_id" : cancelOperationID,
    @"controller_cas" : controller, @"committed_checkpoint" : checkpoint,
    @"target" : toolTarget,
    @"cancel_token" : @{
      @"schema_version" : @2, @"issuer" : @"completion_controller",
      @"source_event_id" : @"37373737-3737-4737-8737-373737373737",
      @"token" : @"38383838-3838-4838-8838-383838383838",
      @"task_id" : taskID, @"attempt_id" : attemptID,
      @"expected_phase" : @"execution_intent",
      @"reason_code" : @"E_AGENT_CANCELLED",
    },
    @"expected_round_revision" : NSNull.null,
    @"expected_execution_revision" : @1,
    @"expected_transcript" : transcript, @"root" : [self root],
  };
  NSString *expectedCancelSHA = DSHAgentHJ(@"agent-operation-request", @{
    @"operation_kind" : @"cancel_agent_attempt", @"request" : cancelRequest,
  }, &error);
  NSDictionary *started = DSHAgentNativeWALStartTargetOperation(
      self.wal, @"cancel_agent_attempt", cancelRequest, toolTarget, taskID,
      attemptID, @0, &error);
  XCTAssertNil(error);
  XCTAssertEqualObjects(started[@"status"], @"started");
  XCTAssertEqualObjects(started[@"request_sha256"], expectedCancelSHA);
  XCTAssertEqualObjects(started[@"record"][@"task_id"], taskID);
  XCTAssertEqualObjects(started[@"record"][@"attempt_id"], attemptID);
  XCTAssertNil(cancelRequest[@"task_id"]);
  XCTAssertNil(cancelRequest[@"attempt_id"]);

  // The ordinary helper remains strict and the target-aware helper does not
  // accept a caller-augmented public request.
  error = nil;
  XCTAssertNil(DSHAgentNativeWALStartOperation(
      self.wal, @"cancel_agent_attempt", cancelRequest, taskID, attemptID, @0,
      &error));
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorInvalidArgument);
  NSMutableDictionary *augmented = [cancelRequest mutableCopy];
  augmented[@"task_id"] = taskID;
  augmented[@"attempt_id"] = attemptID;
  error = nil;
  XCTAssertNil(DSHAgentNativeWALStartTargetOperation(
      self.wal, @"cancel_agent_attempt", augmented, toolTarget, taskID,
      attemptID, @0, &error));
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorInvalidArgument);

  NSDictionary *safeResult = @{
    @"schema_version" : @2, @"result_kind" : @"cancel_agent_attempt",
    @"result" : @{
      @"schema_version" : @2, @"status" : @"settled",
      @"operation_id" : cancelOperationID,
    },
  };
  NSDictionary *toolResultRef = @{
    @"schema_version" : @2, @"kind" : @"tool", @"task_id" : taskID,
    @"attempt_id" : attemptID, @"round_id" : roundID, @"round_index" : @0,
    @"call_index" : @0, @"call_id" : @"call-cancel",
    @"execution_revision" : @1,
  };
  error = nil;
  NSDictionary *committed = DSHAgentNativeWALCommitOperation(
      self.wal, cancelOperationID, expectedCancelSHA, taskID, attemptID,
      @"committed", @"settled", toolResultRef, @1, safeResult, &error);
  XCTAssertNil(error);
  XCTAssertEqualObjects(committed[@"record"][@"state"], @"committed");
  XCTAssertEqualObjects(committed[@"record"][@"result_status"], @"settled");
  NSDictionary *replayed = DSHAgentNativeWALStartTargetOperation(
      self.wal, @"cancel_agent_attempt", cancelRequest, toolTarget, taskID,
      attemptID, @0, &error);
  XCTAssertEqualObjects(replayed[@"status"], @"replayed");
  XCTAssertEqualObjects(replayed[@"result"], safeResult);

  NSMutableDictionary *otherTool = [toolTarget mutableCopy];
  otherTool[@"call_id"] = @"call-other";
  NSMutableDictionary *otherRequest = [cancelRequest mutableCopy];
  otherRequest[@"target"] = otherTool;
  error = nil;
  XCTAssertNil(DSHAgentNativeWALStartTargetOperation(
      self.wal, @"cancel_agent_attempt", otherRequest, otherTool, taskID,
      attemptID, @0, &error));
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorConflict);
  error = nil;
  XCTAssertNil(DSHAgentNativeWALStartTargetOperation(
      self.wal, @"cancel_agent_attempt", cancelRequest, otherTool, taskID,
      attemptID, @0, &error));
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorInvalidArgument);

  NSString *recoverOperationID = @"39393939-3939-4939-8939-393939393939";
  NSDictionary *roundTarget = @{
    @"schema_version" : @2, @"kind" : @"round", @"task_id" : taskID,
    @"attempt_id" : attemptID, @"round_id" : roundID, @"round_index" : @0,
  };
  NSDictionary *recoverRequest = @{
    @"schema_version" : @2, @"operation_id" : recoverOperationID,
    @"controller_cas" : controller, @"committed_checkpoint" : checkpoint,
    @"target" : roundTarget, @"action" : @"retry_failed_round",
    @"expected_round_revision" : @1,
    @"expected_execution_revision" : NSNull.null,
    @"expected_transcript" : transcript, @"root" : [self root],
  };
  error = nil;
  NSString *expectedRecoverSHA = DSHAgentHJ(@"agent-operation-request", @{
    @"operation_kind" : @"recover_agent_attempt", @"request" : recoverRequest,
  }, &error);
  NSDictionary *recoverStarted = DSHAgentNativeWALStartTargetOperation(
      self.wal, @"recover_agent_attempt", recoverRequest, roundTarget, taskID,
      attemptID, @0, &error);
  XCTAssertNil(error);
  XCTAssertEqualObjects(recoverStarted[@"status"], @"started");
  XCTAssertEqualObjects(recoverStarted[@"request_sha256"], expectedRecoverSHA);
  NSDictionary *invalidRecoverSettled = @{
    @"schema_version" : @2, @"result_kind" : @"recover_agent_attempt",
    @"result" : @{
      @"schema_version" : @2, @"status" : @"settled",
      @"operation_id" : recoverOperationID,
    },
  };
  error = nil;
  XCTAssertNil(DSHAgentNativeWALCommitOperation(
      self.wal, recoverOperationID, expectedRecoverSHA, taskID, attemptID,
      @"committed", @"settled", toolResultRef, @1, invalidRecoverSettled,
      &error));
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorConflict);
  error = nil;
  NSDictionary *snapshot = [self.wal snapshotWithError:&error];
  XCTAssertNil(error);
  XCTAssertEqual([snapshot[@"operations"] count], 2U);
  XCTAssertEqualObjects(snapshot[@"operations"][1][@"state"], @"started");
}

- (void)testAlreadyTerminalIsFinalizeOnlyAndReplaysImmutableSnapshot {
  NSError *error = nil;
  NSString *taskID = @"41414141-4141-4141-8141-414141414141";
  NSString *attemptID = @"42424242-4242-4242-8242-424242424242";
  NSString *finalizeOperationID = @"43434343-4343-4343-8343-434343434343";
  NSString *cleanupID = @"44444444-4444-4444-8444-444444444445";
  NSDictionary *finalizeRequest = @{
    @"schema_version" : @2,
    @"operation_id" : finalizeOperationID,
    @"task_id" : taskID,
    @"attempt_id" : attemptID,
    @"cleanup_id" : cleanupID,
  };
  NSDictionary *started = DSHAgentNativeWALStartOperation(
      self.wal, @"finalize_agent_attempt", finalizeRequest, taskID, attemptID,
      @7, &error);
  XCTAssertNil(error);
  XCTAssertEqualObjects(started[@"status"], @"started");

  NSDictionary *resultRef = @{
    @"schema_version" : @2,
    @"kind" : @"authority",
    @"task_id" : taskID,
    @"attempt_id" : attemptID,
    @"authority_revision" : @7,
  };
  NSDictionary *safeResult = @{
    @"schema_version" : @2,
    @"result_kind" : @"finalize_agent_attempt",
    @"result" : @{
      @"schema_version" : @2,
      @"status" : @"already_terminal",
      @"operation_id" : finalizeOperationID,
      @"cleanup_id" : cleanupID,
    },
  };
  NSDictionary *committed = DSHAgentNativeWALCommitOperation(
      self.wal, finalizeOperationID, started[@"request_sha256"], taskID,
      attemptID, @"committed", @"already_terminal", resultRef, @7,
      safeResult, &error);
  XCTAssertNil(error);
  XCTAssertEqualObjects(committed[@"record"][@"result_status"],
                        @"already_terminal");
  XCTAssertEqualObjects(committed[@"result"], safeResult);

  DSHAgentNativeWAL *relaunch = [[DSHAgentNativeWAL alloc]
      initWithRootURL:self.rootURL
      clock:^NSDate * { return [NSDate dateWithTimeIntervalSince1970:1787961600]; }
      identifierGenerator:^NSString * {
        return @"45454545-4545-4545-8545-454545454545";
      }
      faultHook:nil];
  NSDictionary *replayed = DSHAgentNativeWALStartOperation(
      relaunch, @"finalize_agent_attempt", finalizeRequest, taskID, attemptID,
      @7, &error);
  XCTAssertNil(error);
  XCTAssertEqualObjects(replayed[@"status"], @"replayed");
  XCTAssertEqualObjects(replayed[@"record"][@"result_status"],
                        @"already_terminal");
  XCTAssertEqualObjects(replayed[@"result"], safeResult);

  NSString *mismatchedOperationID = @"46464646-4646-4646-8646-464646464646";
  NSMutableDictionary *mismatchedRequest = [finalizeRequest mutableCopy];
  mismatchedRequest[@"operation_id"] = mismatchedOperationID;
  NSDictionary *mismatchedStarted = DSHAgentNativeWALStartOperation(
      relaunch, @"finalize_agent_attempt", mismatchedRequest, taskID, attemptID,
      @7, &error);
  XCTAssertNil(error);
  NSMutableDictionary *mismatchedResult = [safeResult mutableCopy];
  NSMutableDictionary *mismatchedInner = [safeResult[@"result"] mutableCopy];
  mismatchedInner[@"operation_id"] = mismatchedOperationID;
  mismatchedInner[@"status"] = @"terminal";
  mismatchedResult[@"result"] = mismatchedInner;
  error = nil;
  XCTAssertNil(DSHAgentNativeWALCommitOperation(
      relaunch, mismatchedOperationID, mismatchedStarted[@"request_sha256"],
      taskID, attemptID, @"committed", @"already_terminal", resultRef, @7,
      mismatchedResult, &error));
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorInvalidArgument);

  NSString *discardOperationID = @"47474747-4747-4747-8747-474747474747";
  NSDictionary *discardRequest = @{
    @"schema_version" : @2,
    @"operation_id" : discardOperationID,
    @"task_id" : taskID,
    @"attempt_id" : attemptID,
    @"cleanup_id" : cleanupID,
  };
  error = nil;
  NSDictionary *discardStarted = DSHAgentNativeWALStartOperation(
      relaunch, @"discard_agent_attempt", discardRequest, taskID, attemptID,
      @7, &error);
  XCTAssertNil(error);
  NSDictionary *discardSafeResult = @{
    @"schema_version" : @2,
    @"result_kind" : @"discard_agent_attempt",
    @"result" : @{
      @"schema_version" : @2,
      @"status" : @"already_terminal",
      @"operation_id" : discardOperationID,
      @"cleanup_id" : cleanupID,
    },
  };
  error = nil;
  XCTAssertNil(DSHAgentNativeWALCommitOperation(
      relaunch, discardOperationID, discardStarted[@"request_sha256"], taskID,
      attemptID, @"committed", @"already_terminal", resultRef, @7,
      discardSafeResult, &error));
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorConflict);
}

- (void)testReadOnlyBatchIsVersionedAndCapacityFailsClosed {
  NSError *error = nil;
  NSDictionary *first = [self readOnlyBatchWithRoundID:
      @"00000000-0000-4000-8000-000000000001" revision:@1];
  XCTAssertEqualObjects(DSHAgentNativeWALRecordBatch(self.wal, first, &error),
                        first);
  XCTAssertNil(error);
  XCTAssertEqualObjects(DSHAgentNativeWALRecordBatch(self.wal, first, &error),
                        first);

  NSMutableArray *full = [NSMutableArray arrayWithObject:first];
  for (NSUInteger index = 1; index < DSHAgentNativeWALMaxBatchesPerAttempt;
       index += 1) {
    NSString *roundID = [NSString stringWithFormat:
        @"00000000-0000-4000-8000-%012lx", (unsigned long)(index + 1)];
    [full addObject:[self readOnlyBatchWithRoundID:roundID revision:@1]];
  }
  XCTAssertTrue([self.wal performAtomicTransaction:^BOOL(
      NSMutableDictionary *state, NSError **mutationError) {
    (void)mutationError;
    state[@"batches"] = full;
    return YES;
  } error:&error]);
  NSDictionary *overflow = [self readOnlyBatchWithRoundID:
      @"00000000-0000-4000-8000-000000000081" revision:@1];
  error = nil;
  XCTAssertNil(DSHAgentNativeWALRecordBatch(self.wal, overflow, &error));
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorCapacity);
  XCTAssertEqualObjects(error.userInfo[@"code"], @"E_AGENT_CAPACITY");
  NSDictionary *state = [self.wal snapshotWithError:&error];
  XCTAssertEqual([(NSArray *)state[@"batches"] count],
                 DSHAgentNativeWALMaxBatchesPerAttempt);
  XCTAssertEqualObjects(state[@"batches"][0][@"effect_gate"],
                        @"not_applicable");
}

- (void)testDurableDeniedCallIsNotLedgerAndReplaysExactReceipt {
  NSError *error = nil;
  NSString *attemptID = @"22222222-2222-4222-8222-222222222222";
  NSDictionary *before = [self.transcripts
      createAgentTranscriptWithRequest:@{
        @"schema_version" : @1,
        @"attempt_id" : attemptID,
        @"root" : [self root],
      }
      error:&error];
  NSDictionary *feedback = @{
    @"schema_version" : @1,
    @"name" : @"provider_unknown_tool",
    @"outcome" : @"denied",
    @"payload" : @{
      @"schema_version" : @1,
      @"failure_code" : @"E_AGENT_UNKNOWN_TOOL",
    },
  };
  NSData *feedbackBytes = DSHAgentCanonicalJSON(feedback, &error);
  NSString *feedbackString = [[NSString alloc] initWithData:feedbackBytes
                                                    encoding:NSUTF8StringEncoding];
  NSDictionary *after = [self.transcripts appendToolMessage:@{
    @"schema_version" : @1,
    @"role" : @"tool",
    @"round_index" : @0,
    @"call_id" : @"provider-unknown",
    @"content" : feedbackString,
    @"truncated" : @NO,
  } expectedTranscript:before root:[self root] attemptId:attemptID error:&error];
  XCTAssertNotNil(after);
  NSString *argumentsSHA =
      @"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
  NSDictionary *receipt = @{
    @"schema_version" : @1,
    @"call_id" : @"provider-unknown",
    @"name" : @"provider_unknown_tool",
    @"arguments_sha256" : argumentsSHA,
    @"result_sha256" : DSHAgentHB(@"tool-result", feedbackBytes, &error),
    @"result_bytes" : @(feedbackBytes.length),
    @"truncated" : @NO,
    @"duration_ms" : @0,
    @"outcome" : @"denied",
    @"failure_code" : @"E_AGENT_UNKNOWN_TOOL",
    @"approval_reference" : NSNull.null,
  };
  NSDictionary *denied = @{
    @"schema_version" : @1,
    @"task_id" : @"33333333-3333-4333-8333-333333333333",
    @"attempt_id" : attemptID,
    @"round_id" : @"44444444-4444-4444-8444-444444444444",
    @"round_index" : @0,
    @"call_index" : @0,
    @"call_id" : @"provider-unknown",
    @"name" : @"provider_unknown_tool",
    @"arguments_sha256" : argumentsSHA,
    @"root_fingerprint_sha256" : [self root][@"root_fingerprint_sha256"],
    @"binding_revision" : @1,
    @"transcript_before" : before,
    @"state" : @"denied",
    @"row_revision" : @1,
    @"feedback" : feedback,
    @"transcript_after" : after,
    @"receipt" : receipt,
    @"created_at" : @"2026-08-30T00:00:00.000Z",
    @"updated_at" : @"2026-08-30T00:00:00.000Z",
  };
  XCTAssertEqualObjects(DSHAgentNativeWALRecordDeniedCall(self.wal, denied, &error),
                        denied);
  XCTAssertEqualObjects(DSHAgentNativeWALRecordDeniedCall(self.wal, denied, &error),
                        denied);
  NSDictionary *state = [self.wal snapshotWithError:&error];
  XCTAssertEqual([(NSArray *)state[@"denied_calls"] count], (NSUInteger)1);
  XCTAssertEqual([(NSArray *)state[@"ledger"] count], (NSUInteger)0);
  XCTAssertEqualObjects(state[@"denied_calls"][0][@"receipt"], receipt);
}

- (void)testSchemaOneMigrationTornWriteIsRejectedWithoutPartialV2 {
  NSError *error = nil;
  XCTAssertTrue([self writeCanonicalWALState:
      [self emptyLegacyWALWithGeneration:@7] error:&error]);
  DSHAgentNativeWAL *faulty = [[DSHAgentNativeWAL alloc]
      initWithRootURL:self.rootURL
      clock:^NSDate * { return [NSDate dateWithTimeIntervalSince1970:1787961600]; }
      identifierGenerator:^NSString * {
        return @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
      }
      faultHook:^BOOL(NSString *stage) {
        return ![stage isEqualToString:@"wal.after_temp_write"];
      }];
  XCTAssertFalse([faulty ensureStorageWithError:&error]);
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorPersistence);
  XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:
      [self.wal.walURL.path stringByAppendingString:@".tmp"]]);

  DSHAgentNativeWAL *relaunch = [[DSHAgentNativeWAL alloc]
      initWithRootURL:self.rootURL
      clock:^NSDate * { return [NSDate dateWithTimeIntervalSince1970:1787961600]; }
      identifierGenerator:^NSString * {
        return @"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
      }
      faultHook:nil];
  error = nil;
  XCTAssertFalse([relaunch ensureStorageWithError:&error]);
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorCorrupt);
}

- (void)testFaultAfterPreparedWALLeavesTornTransactionRejectedOnRelaunch {
  DSHAgentNativeWAL *faulty = [[DSHAgentNativeWAL alloc]
      initWithRootURL:self.rootURL
      clock:^NSDate * { return [NSDate dateWithTimeIntervalSince1970:1787961600]; }
      identifierGenerator:^NSString * {
        return @"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
      }
      faultHook:^BOOL(NSString *stage) {
        return ![stage isEqualToString:@"wal.after_temp_write"];
      }];
  DSHAgentTranscriptStore *store = [[DSHAgentTranscriptStore alloc]
      initWithWAL:faulty];
  NSError *error = nil;
  NSDictionary *created = [store createAgentTranscriptWithRequest:@{
    @"schema_version" : @1,
    @"attempt_id" : @"22222222-2222-4222-8222-222222222222",
    @"root" : [self root],
  } error:&error];
  XCTAssertNil(created);
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorPersistence);

  DSHAgentNativeWAL *relaunch = [[DSHAgentNativeWAL alloc]
      initWithRootURL:self.rootURL
      clock:^NSDate * { return [NSDate dateWithTimeIntervalSince1970:1787961600]; }
      identifierGenerator:^NSString * {
        return @"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
      }
      faultHook:nil];
  XCTAssertFalse([relaunch ensureStorageWithError:&error]);
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorCorrupt);
}

@end
