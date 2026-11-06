#import <XCTest/XCTest.h>

#import "../Sources/AgentNativeWAL.h"
#import "../Sources/AgentTranscriptStore.h"

#include <sys/stat.h>
#include <unistd.h>

static NSString *const DSHDisplayConversation = @"11111111-1111-4111-8111-111111111111";
static NSString *const DSHDisplayAttempt = @"22222222-2222-4222-8222-222222222222";
static NSString *const DSHDisplayRound = @"33333333-3333-4333-8333-333333333333";
static NSString *const DSHDisplayOtherRound = @"44444444-4444-4444-8444-444444444444";

@interface DSHDisplaySnapshotWAL : DSHAgentNativeWAL
@property(nonatomic, copy) NSDictionary *displayState;
@property(nonatomic) NSUInteger snapshotReads;
@property(nonatomic) NSUInteger transactions;
@end
@implementation DSHDisplaySnapshotWAL
- (NSDictionary *)snapshotWithError:(NSError **)error {
  self.snapshotReads += 1;
  return self.displayState;
}
- (BOOL)performAtomicTransaction:(DSHAgentNativeWALMutation)mutation error:(NSError **)error {
  self.transactions += 1;
  return NO;
}
@end

@interface AgentRoundPresentationTests : XCTestCase
@property(nonatomic, strong) NSURL *rootURL;
@property(nonatomic, strong) DSHDisplaySnapshotWAL *wal;
@property(nonatomic, strong) DSHAgentTranscriptStore *store;
@end

@implementation AgentRoundPresentationTests
- (void)setUp {
  [super setUp];
  self.rootURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
      [@"rish-presentation-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];
  XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:self.rootURL
      withIntermediateDirectories:YES attributes:nil error:nil]);
  self.wal = [[DSHDisplaySnapshotWAL alloc] initWithRootURL:self.rootURL
      clock:nil identifierGenerator:nil faultHook:nil];
  self.wal.displayState = @{ @"rounds": @[], @"transcripts": @[] };
  self.store = [[DSHAgentTranscriptStore alloc] initWithWAL:self.wal];
}
- (void)tearDown {
  [NSFileManager.defaultManager removeItemAtURL:self.rootURL error:nil];
  [super tearDown];
}
- (NSURL *)cacheFile {
  return [[self.rootURL URLByAppendingPathComponent:@"round-presentations-v1"]
      URLByAppendingPathComponent:[NSString stringWithFormat:@"%@_%@.json", DSHDisplayConversation, DSHDisplayAttempt]];
}
- (void)cacheText:(NSString *)text reasoning:(NSString *)reasoning index:(id)index round:(NSString *)round {
  [self.store cacheRoundPresentationForRequest:@{
      @"conversation_id": DSHDisplayConversation, @"attempt_id": DSHDisplayAttempt,
      @"round_id": round, @"round_index": index }
      message:@{ @"content": text, @"reasoning_content": reasoning } kind:@"final"];
}
- (NSDictionary *)presentation {
  NSError *error = nil;
  NSDictionary *result = [self.store roundPresentationsForConversation:DSHDisplayConversation
      attempt:DSHDisplayAttempt error:&error];
  XCTAssertNotNil(result); XCTAssertNil(error);
  return result;
}
- (void)testArchiveReplacementOrderingAndNativePermissions {
  [self cacheText:@"later" reasoning:@"" index:@1 round:DSHDisplayOtherRound];
  [self cacheText:@"early" reasoning:@"" index:@0 round:DSHDisplayRound];
  [self cacheText:@"更新 🐾\0正文" reasoning:@"推理" index:@0 round:DSHDisplayRound];
  NSArray *rounds = [self presentation][@"rounds"];
  XCTAssertEqual(rounds.count, 2U);
  XCTAssertEqualObjects(rounds[0][@"round_index"], @0);
  XCTAssertEqualObjects(rounds[0][@"text"], @"更新 🐾\0正文");
  XCTAssertEqualObjects(rounds[1][@"text"], @"later");
  struct stat metadata = {};
  XCTAssertEqual(lstat([self cacheFile].fileSystemRepresentation, &metadata), 0);
  XCTAssertEqual(metadata.st_mode & 0777, 0600);
  XCTAssertEqual(lstat([self cacheFile].URLByDeletingLastPathComponent.fileSystemRepresentation, &metadata), 0);
  XCTAssertEqual(metadata.st_mode & 0777, 0700);
  XCTAssertEqual(self.wal.transactions, 0U);
}
- (void)testRawCacheDecoderRejectsDuplicatesAndNonIntegerIndexes {
  [self cacheText:@"cached" reasoning:@"" index:@0 round:DSHDisplayRound];
  NSString *valid = [[NSString alloc] initWithData:[NSData dataWithContentsOfURL:[self cacheFile]]
      encoding:NSUTF8StringEncoding];
  NSMutableArray<NSString *> *invalid = [NSMutableArray array];
  [invalid addObject:[valid stringByReplacingOccurrencesOfString:@"\"schema_version\":1"
      withString:@"\"schema_version\":1,\"schema_version\":1"]];
  [invalid addObject:[valid stringByReplacingOccurrencesOfString:@"\"text\":\"cached\""
      withString:@"\"text\":\"cached\",\"text\":\"cached\""]];
  [invalid addObject:[valid stringByReplacingOccurrencesOfString:@"\"schema_version\":1"
      withString:@"\"schema_version\":1,\"extra\":null"]];
  for (NSString *number in @[@"true", @"0.0", @"0e0", @"-0", @"8"]) {
    [invalid addObject:[valid stringByReplacingOccurrencesOfString:@"\"round_index\":0"
        withString:[@"\"round_index\":" stringByAppendingString:number]]];
  }
  for (NSString *json in invalid) {
    XCTAssertNotEqualObjects(json, valid);
    XCTAssertTrue([[json dataUsingEncoding:NSUTF8StringEncoding] writeToURL:[self cacheFile] atomically:YES]);
    XCTAssertEqual([[self presentation][@"rounds"] count], 0U, @"%@", json);
  }
  XCTAssertEqual(self.wal.transactions, 0U);
}
- (void)testInvalidUpsertsAndEncodedBudgetPreserveCommittedCache {
  [self cacheText:@"committed" reasoning:@"" index:@0 round:DSHDisplayRound];
  NSData *before = [NSData dataWithContentsOfURL:[self cacheFile]];
  for (id index in @[@YES, @0.5, [NSNumber numberWithDouble:1.0], @(-0.0), @8, @(-1), @"1"]) {
    [self cacheText:@"invalid" reasoning:@"" index:index round:DSHDisplayOtherRound];
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:[self cacheFile]], before);
  }
  [self cacheText:@"duplicate round id" reasoning:@"" index:@1 round:DSHDisplayRound];
  XCTAssertEqualObjects([NSData dataWithContentsOfURL:[self cacheFile]], before);
  // Each source string fits its budget, but JSON escaping exceeds the file cap.
  NSString *escaped = [@"\\" stringByPaddingToLength:1024 * 1024 withString:@"\\" startingAtIndex:0];
  [self cacheText:escaped reasoning:@"" index:@0 round:DSHDisplayRound];
  XCTAssertEqualObjects([NSData dataWithContentsOfURL:[self cacheFile]], before);
  NSString *oversized = [@"x" stringByPaddingToLength:2 * 1024 * 1024 + 1 withString:@"x" startingAtIndex:0];
  [self cacheText:oversized reasoning:@"" index:@0 round:DSHDisplayRound];
  [self cacheText:@"" reasoning:oversized index:@0 round:DSHDisplayRound];
  XCTAssertEqualObjects([NSData dataWithContentsOfURL:[self cacheFile]], before);
}
- (void)testNativeCacheReadRejectsSymlinksAndOversizedFiles {
  [self cacheText:@"target" reasoning:@"" index:@0 round:DSHDisplayRound];
  NSURL *file = [self cacheFile];
  NSURL *target = [self.rootURL URLByAppendingPathComponent:@"outside.json"];
  XCTAssertTrue([NSFileManager.defaultManager moveItemAtURL:file toURL:target error:nil]);
  NSData *targetBytes = [NSData dataWithContentsOfURL:target];
  XCTAssertEqual(symlink(target.fileSystemRepresentation, file.fileSystemRepresentation), 0);
  XCTAssertEqual([[self presentation][@"rounds"] count], 0U);
  XCTAssertEqualObjects([NSData dataWithContentsOfURL:target], targetBytes);
  [self cacheText:@"replacement" reasoning:@"" index:@0 round:DSHDisplayRound];
  XCTAssertEqualObjects([NSData dataWithContentsOfURL:target], targetBytes);
  struct stat metadata = {};
  XCTAssertEqual(lstat(file.fileSystemRepresentation, &metadata), 0);
  XCTAssertTrue(S_ISREG(metadata.st_mode));
  XCTAssertEqualObjects([self presentation][@"rounds"][0][@"text"], @"replacement");
  XCTAssertTrue([NSFileManager.defaultManager removeItemAtURL:file error:nil]);
  XCTAssertTrue([[NSMutableData dataWithLength:2 * 1024 * 1024 + 1] writeToURL:file atomically:YES]);
  XCTAssertEqual([[self presentation][@"rounds"] count], 0U);
  XCTAssertTrue([NSFileManager.defaultManager removeItemAtURL:file error:nil]);
  XCTAssertEqual(mkfifo(file.fileSystemRepresentation, 0600), 0);
  XCTAssertEqual([[self presentation][@"rounds"] count], 0U);
}
- (NSDictionary *)roundRow:(NSString *)round index:(NSNumber *)index reference:(NSString *)reference {
  return @{ @"locator": @{ @"attempt_id": DSHDisplayAttempt, @"round_id": round, @"round_index": index },
      @"state": @"completed", @"terminal_kind": @"final",
      @"transcript_after": @{ @"transcript_ref": reference, @"generation": @1 } };
}
- (NSDictionary *)transcript:(NSString *)reference index:(NSNumber *)index text:(NSString *)text {
  return @{ @"attempt_id": DSHDisplayAttempt, @"transcript_ref": reference, @"generation": @2,
      @"messages": @[
        @{ @"role": @"assistant", @"round_index": index, @"content": @"older", @"reasoning_content": @"" },
        @{ @"role": @"assistant", @"round_index": index, @"content": text, @"reasoning_content": @"from WAL" } ] };
}
- (void)testVerifiedWALOverridesCacheWithoutAggregateFileCapOrAuthorityWrites {
  [self cacheText:@"stale cache" reasoning:@"" index:@0 round:DSHDisplayRound];
  NSData *before = [NSData dataWithContentsOfURL:[self cacheFile]];
  NSString *firstRef = @"55555555-5555-4555-8555-555555555555";
  NSString *secondRef = @"66666666-6666-4666-8666-666666666666";
  NSString *large = [@"a" stringByPaddingToLength:1100 * 1024 withString:@"a" startingAtIndex:0];
  self.wal.displayState = @{
    @"rounds": @[[self roundRow:DSHDisplayRound index:@0 reference:firstRef],
        [self roundRow:DSHDisplayOtherRound index:@1 reference:secondRef]],
    @"transcripts": @[[self transcript:firstRef index:@0 text:large],
        [self transcript:secondRef index:@1 text:large]] };
  NSDictionary *snapshot = self.wal.displayState;
  NSDictionary *result = [self presentation];
  XCTAssertEqual([result[@"rounds"] count], 2U);
  XCTAssertEqualObjects(result[@"rounds"][0][@"text"], large);
  XCTAssertEqualObjects(result[@"rounds"][1][@"reasoning"], @"from WAL");
  XCTAssertGreaterThan(DSHAgentCanonicalJSON(result, nil).length, 2 * 1024 * 1024U);
  XCTAssertEqualObjects(self.wal.displayState, snapshot);
  XCTAssertEqualObjects([NSData dataWithContentsOfURL:[self cacheFile]], before);
  XCTAssertEqual(self.wal.transactions, 0U);
}
- (void)testInvalidIdentityIsRejectedBeforeSnapshotOrFilesystemWork {
  NSError *error = nil;
  XCTAssertNil([self.store roundPresentationsForConversation:@"../outside" attempt:DSHDisplayAttempt error:&error]);
  XCTAssertEqual(error.code, DSHAgentNativeStoreErrorInvalidArgument);
  XCTAssertEqual(self.wal.snapshotReads, 0U);
  XCTAssertEqual(self.wal.transactions, 0U);
}
@end
