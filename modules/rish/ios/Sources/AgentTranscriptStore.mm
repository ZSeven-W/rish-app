#import "AgentTranscriptStore.h"

#include "rish_agent_core.h"

#include <fcntl.h>
#include <unistd.h>

#include <errno.h>
#include <string.h>
#include <sys/stat.h>

static NSUInteger const DSHPresentationMaxFile = 2 * 1024 * 1024;
static NSUInteger const DSHPresentationMaxTotal = 64 * 1024 * 1024;
// Rust owns archive schema, record hashing, replacement and WAL projection.
// This facade retains only the cache's filesystem and byte-budget policy.
static id DSHPresentationReduce(NSDictionary *envelope, NSError **error) {
  NSData *bytes = DSHAgentCanonicalJSON(envelope, nil);
  if (!bytes) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  char *raw = rish_agent_round_presentation_reduce((const char *)bytes.bytes, bytes.length);
  if (!raw) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  NSData *reply = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  id parsed = [NSJSONSerialization JSONObjectWithData:reply options:0 error:nil];
  if (![parsed isKindOfClass:NSDictionary.class]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  if (![parsed[@"ok"] isEqual:@YES]) {
    NSInteger code = [parsed[@"error"] isKindOfClass:NSNumber.class]
        ? [parsed[@"error"] integerValue] : 0;
    if (code < DSHAgentNativeStoreErrorInvalidArgument || code > DSHAgentNativeStoreErrorPersistence) {
      code = DSHAgentNativeStoreErrorCorrupt;
    }
    DSHSetAgentNativeStoreError(error, (DSHAgentNativeStoreErrorCode)code);
    return nil;
  }
  return parsed[@"value"];
}
static NSMutableDictionary *DSHPresentationEnvelope(NSString *op, id conversationId, id attemptId) {
  return [@{ @"schema_version": @1, @"op": op,
    @"conversation_id": conversationId ?: NSNull.null,
    @"attempt_id": attemptId ?: NSNull.null } mutableCopy];
}
static BOOL DSHPresentationIdentity(id conversationId, id attemptId, NSError **error) {
  return [DSHPresentationReduce(DSHPresentationEnvelope(@"identity", conversationId, attemptId), error) isEqual:@YES];
}
static NSURL *DSHPresentationDirectory(NSURL *walRoot) {
  return [walRoot URLByAppendingPathComponent:@"round-presentations-v1" isDirectory:YES];
}
static NSDictionary *DSHPresentationRead(NSURL *url, NSString *conversationId, NSString *attemptId) {
  int fd = open(url.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
  if (fd < 0) return nil;
  struct stat metadata = {};
  if (fstat(fd, &metadata) != 0 || !S_ISREG(metadata.st_mode) || metadata.st_size < 0 || metadata.st_size > DSHPresentationMaxFile) { close(fd); return nil; }
  NSMutableData *bytes = [NSMutableData data];
  char buffer[8192];
  while (bytes.length <= DSHPresentationMaxFile) {
    ssize_t count = read(fd, buffer, MIN(sizeof(buffer), DSHPresentationMaxFile + 1 - bytes.length));
    if (count < 0 && errno == EINTR) continue;
    if (count < 0) { close(fd); return nil; }
    if (count == 0) break;
    [bytes appendBytes:buffer length:(NSUInteger)count];
  }
  close(fd);
  if (bytes.length > DSHPresentationMaxFile) return nil;
  NSString *json = [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
  if (!json) return nil;
  NSMutableDictionary *request = DSHPresentationEnvelope(@"decode", conversationId, attemptId);
  request[@"archive_json"] = json;
  // Preserve original JSON so the shared strict decoder can see duplicate keys.
  return DSHPresentationReduce(request, nil);
}
// Invoked after a committed session deletion as well as display reads. It
// never changes session/WAL authority. Capacity eviction affects display only.
void DSHAgentPruneRoundPresentationCache(NSURL *walRoot, NSSet<NSString *> *conversationIds) {
  @synchronized(DSHAgentTranscriptStore.class) {
    NSURL *directory = DSHPresentationDirectory(walRoot);
    NSArray<NSURL *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:directory includingPropertiesForKeys:@[NSURLFileSizeKey, NSURLContentModificationDateKey] options:0 error:nil];
    NSMutableArray<NSDictionary *> *retained = [NSMutableArray array]; NSUInteger total = 0;
    for (NSURL *file in files) {
      NSString *name = file.lastPathComponent;
      NSArray *parts = [[name stringByDeletingPathExtension] componentsSeparatedByString:@"_"];
      if (parts.count != 2 || !DSHAgentCanonicalUUID(parts[0]) || !DSHAgentCanonicalUUID(parts[1]) || ![file.pathExtension isEqual:@"json"]) continue;
      if (conversationIds && ![conversationIds containsObject:parts[0]]) { [NSFileManager.defaultManager removeItemAtURL:file error:nil]; continue; }
      NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:file.path error:nil];
      NSUInteger size = [attributes[NSFileSize] unsignedIntegerValue];
      if (![attributes[NSFileType] isEqual:NSFileTypeRegular] || size > DSHPresentationMaxFile) { [NSFileManager.defaultManager removeItemAtURL:file error:nil]; continue; }
      total += size;
      [retained addObject:@{ @"url": file, @"bytes": @(size), @"date": attributes[NSFileModificationDate] ?: NSDate.distantPast }];
    }
    [retained sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) { return [left[@"date"] compare:right[@"date"]]; }];
    NSUInteger count = retained.count;
    for (NSDictionary *entry in retained) {
      if (total <= DSHPresentationMaxTotal && count <= 256) break;
      [NSFileManager.defaultManager removeItemAtURL:entry[@"url"] error:nil]; total -= [entry[@"bytes"] unsignedIntegerValue]; count--;
    }
  }
}

@interface DSHAgentTranscriptStore ()
@property(nonatomic, strong, readwrite) DSHAgentNativeWAL *wal;
@end

@implementation DSHAgentTranscriptStore

- (void)cacheRoundPresentationForRequest:(NSDictionary *)request message:(NSDictionary *)message kind:(NSString *)kind {
  if (!DSHPresentationIdentity(request[@"conversation_id"], request[@"attempt_id"], nil)) return;
  if (!DSHAgentBoundedUTF8String(message[@"content"], DSHPresentationMaxFile, YES, nullptr) ||
      !DSHAgentBoundedUTF8String(message[@"reasoning_content"], DSHPresentationMaxFile, YES, nullptr)) return;
  id index = request[@"round_index"];
  // Canonical JSON renders integral floating NSNumbers as integer tokens. Keep
  // that transport coercion from hiding their original type from the reducer.
  if ([index isKindOfClass:NSNumber.class] && strchr("fdD", [index objCType][0])) return;
  @synchronized(DSHAgentTranscriptStore.class) {
    NSURL *directory = DSHPresentationDirectory(self.wal.rootURL);
    struct stat metadata = {};
    if (lstat(directory.fileSystemRepresentation, &metadata) == 0 && !S_ISDIR(metadata.st_mode)) return;
    if (![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700, NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil]) return;
    [directory setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    NSString *name = [NSString stringWithFormat:@"%@_%@.json", request[@"conversation_id"], request[@"attempt_id"]];
    NSURL *file = [directory URLByAppendingPathComponent:name];
    NSMutableDictionary *operation = DSHPresentationEnvelope(@"upsert", request[@"conversation_id"], request[@"attempt_id"]);
    operation[@"prior"] = DSHPresentationRead(file, request[@"conversation_id"], request[@"attempt_id"]) ?: NSNull.null;
    operation[@"round_id"] = request[@"round_id"] ?: NSNull.null;
    operation[@"round_index"] = index ?: NSNull.null;
    operation[@"kind"] = kind ?: NSNull.null;
    operation[@"text"] = message[@"content"];
    operation[@"reasoning"] = message[@"reasoning_content"];
    NSDictionary *projection = DSHPresentationReduce(operation, nil);
    NSData *data = projection ? DSHAgentCanonicalJSON(projection, nil) : nil;
    if (!data || data.length > DSHPresentationMaxFile) return;
    if (![data writeToURL:file options:NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:nil]) return;
    [NSFileManager.defaultManager setAttributes:@{ NSFilePosixPermissions: @0600 } ofItemAtPath:file.path error:nil];
    DSHAgentPruneRoundPresentationCache(self.wal.rootURL, nil);
  }
}

- (NSDictionary *)roundPresentationsForConversation:(NSString *)conversationId attempt:(NSString *)attemptId error:(NSError **)error {
  if (!DSHPresentationIdentity(conversationId, attemptId, error)) return nil;
  // Snapshot verification remains native authority. Display never reconciles,
  // replays, advances or writes the WAL, transcript or provider round.
  NSDictionary *state = [self.wal snapshotWithError:error];
  if (!state) return nil;
  NSMutableDictionary *operation = DSHPresentationEnvelope(@"project", conversationId, attemptId);
  @synchronized(DSHAgentTranscriptStore.class) {
    NSURL *file = [DSHPresentationDirectory(self.wal.rootURL) URLByAppendingPathComponent:[NSString stringWithFormat:@"%@_%@.json", conversationId, attemptId]];
    operation[@"cached"] = DSHPresentationRead(file, conversationId, attemptId) ?: NSNull.null;
  }
  // Collect only this attempt's verified rows. Rust owns all round/ref/message
  // selection and merge rules; the cache's encoded file cap is not a view cap.
  NSMutableArray *rounds = [NSMutableArray array], *transcripts = [NSMutableArray array];
  for (NSDictionary *row in state[@"rounds"]) {
    if ([row[@"locator"][@"attempt_id"] isEqual:attemptId]) [rounds addObject:row];
  }
  for (NSDictionary *row in state[@"transcripts"]) {
    if ([row[@"attempt_id"] isEqual:attemptId]) [transcripts addObject:row];
  }
  operation[@"rounds"] = rounds;
  operation[@"transcripts"] = transcripts;
  return DSHPresentationReduce(operation, error);
}

- (instancetype)initWithWAL:(DSHAgentNativeWAL *)wal {
  self = [super init];
  if (self) _wal = wal;
  return self;
}

#pragma mark - Shared-core facade

// Every store operation below is a facade over the Rust reducer in
// modules/rish/core (`rish_agent_transcript_reduce`). This side owns the WAL
// transaction or snapshot, generates the fresh transcript UUID and the
// retention timestamp, collects the view (the request's transcript row, the
// attempt's transcript rows, the matching cleanup entries and the round /
// ledger references discard must respect), and applies the returned changes
// verbatim. The display cache above uses its own shared reducer while this
// facade retains native file I/O; the cache is not authority.

typedef NS_ENUM(NSInteger, DSHAgentTranscriptRunMode) {
  DSHAgentTranscriptRunModeTransaction,
  DSHAgentTranscriptRunModeSnapshot,
};

static NSDictionary *DSHAgentTranscriptReduce(NSDictionary *envelope, NSError **error) {
  NSData *bytes = DSHAgentCanonicalJSON(envelope, nil);
  if (bytes == nil) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorInvalidArgument);
    return nil;
  }
  char *raw = rish_agent_transcript_reduce((const char *)bytes.bytes, bytes.length);
  if (raw == NULL) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  NSData *reply = [NSData dataWithBytes:raw length:strlen(raw)];
  rish_agent_string_free(raw);
  id parsed = [NSJSONSerialization JSONObjectWithData:reply options:0 error:nil];
  if (![parsed isKindOfClass:NSDictionary.class]) {
    DSHSetAgentNativeStoreError(error, DSHAgentNativeStoreErrorCorrupt);
    return nil;
  }
  if (![parsed[@"ok"] isEqual:@YES]) {
    NSInteger code = [parsed[@"error"] isKindOfClass:NSNumber.class]
        ? [parsed[@"error"] integerValue] : 0;
    if (code < DSHAgentNativeStoreErrorInvalidArgument ||
        code > DSHAgentNativeStoreErrorPersistence) {
      code = DSHAgentNativeStoreErrorCorrupt;
    }
    DSHSetAgentNativeStoreError(error, (DSHAgentNativeStoreErrorCode)code);
    return nil;
  }
  return parsed;
}

static id DSHAgentTranscriptField(id container, NSString *key) {
  return [container isKindOfClass:NSDictionary.class] ? container[key] : nil;
}

static NSArray *DSHAgentTranscriptRowReferences(NSArray *rows) {
  NSMutableArray *references = [NSMutableArray array];
  for (NSDictionary *row in rows) {
    if (![row isKindOfClass:NSDictionary.class]) continue;
    [references addObject:@{
      @"state" : DSHAgentTranscriptField(row, @"state") ?: NSNull.null,
      @"before_ref" : DSHAgentTranscriptField(row[@"transcript_before"], @"transcript_ref") ?: NSNull.null,
      @"after_ref" : DSHAgentTranscriptField(row[@"transcript_after"], @"transcript_ref") ?: NSNull.null,
    }];
  }
  return references;
}

- (id)runTranscriptOperation:(NSString *)op
                     request:(NSDictionary *)request
               transcriptRef:(id)transcriptRef
                        mode:(DSHAgentTranscriptRunMode)mode
                       error:(NSError **)error {
  id attemptId = DSHAgentTranscriptField(request, @"attempt_id");
  id cleanupId = DSHAgentTranscriptField(request, @"cleanup_id");
  NSDictionary *environment = @{
    @"launch_id" : self.wal.launchId,
    @"now" : [self.wal currentTimestamp],
    @"retention_until" : [self.wal currentTimestampAddingInterval:7 * 24 * 60 * 60],
    @"transcript_ref" : NSUUID.UUID.UUIDString.lowercaseString,
  };
  __block id output = nil;
  DSHAgentNativeWALMutation run = ^BOOL(NSMutableDictionary *state, NSError **mutationError) {
    NSArray *transcripts = state[@"transcripts"];
    BOOL transcriptsPresent = [transcripts isKindOfClass:NSArray.class];
    NSMutableArray *attemptRows = [NSMutableArray array];
    NSDictionary *row = nil;
    for (NSDictionary *candidate in transcripts) {
      if (![candidate isKindOfClass:NSDictionary.class]) continue;
      if (attemptId != nil && [candidate[@"attempt_id"] isEqual:attemptId]) [attemptRows addObject:candidate];
      if (row == nil && transcriptRef != nil && [candidate[@"transcript_ref"] isEqual:transcriptRef]) row = candidate;
    }
    NSMutableArray *cleanup = [NSMutableArray array];
    NSArray *cleanupTable = state[@"cleanup"];
    for (NSUInteger index = 0; index < cleanupTable.count; index += 1) {
      NSDictionary *entry = cleanupTable[index];
      if ([entry isKindOfClass:NSDictionary.class] && cleanupId != nil &&
          [entry[@"cleanup_id"] isEqual:cleanupId]) {
        [cleanup addObject:@{ @"slot" : @(index), @"record" : entry }];
      }
    }
    NSDictionary *envelope = @{
      @"op" : op,
      @"request" : request ?: NSNull.null,
      @"env" : environment,
      @"view" : @{
        @"transcripts_present" : transcriptsPresent ? @YES : @NO,
        @"transcript_count" : @(transcripts.count),
        @"attempt_transcripts" : attemptRows,
        @"transcript" : row ?: NSNull.null,
        @"cleanup" : cleanup,
        @"rounds" : DSHAgentTranscriptRowReferences(state[@"rounds"]),
        @"ledger" : DSHAgentTranscriptRowReferences(state[@"ledger"]),
      },
    };
    NSDictionary *result = DSHAgentTranscriptReduce(envelope, mutationError);
    if (result == nil) return NO;
    output = result[@"output"];
    if (output == nil || output == NSNull.null) {
      DSHSetAgentNativeStoreError(mutationError, DSHAgentNativeStoreErrorCorrupt);
      return NO;
    }
    if (mode == DSHAgentTranscriptRunModeSnapshot || ![result[@"commit"] isEqual:@YES]) return NO;
    NSArray *changes = [result[@"changes"] isKindOfClass:NSArray.class] ? result[@"changes"] : @[];
    for (NSDictionary *change in changes) {
      NSString *kind = DSHAgentTranscriptField(change, @"kind");
      if ([kind isEqualToString:@"insert_transcript"]) {
        NSMutableArray *next = [transcripts mutableCopy] ?: [NSMutableArray array];
        [next addObject:change[@"row"]];
        state[@"transcripts"] = next;
        transcripts = next;
      } else if ([kind isEqualToString:@"replace_transcript"] ||
                 [kind isEqualToString:@"remove_transcript"]) {
        id reference = [kind isEqualToString:@"replace_transcript"]
            ? DSHAgentTranscriptField(change[@"row"], @"transcript_ref") : change[@"transcript_ref"];
        NSMutableArray *next = [transcripts mutableCopy];
        NSUInteger index = NSNotFound;
        for (NSUInteger cursor = 0; cursor < next.count; cursor += 1) {
          if ([next[cursor][@"transcript_ref"] isEqual:reference]) {
            index = cursor;
            break;
          }
        }
        if (index == NSNotFound) {
          DSHSetAgentNativeStoreError(mutationError, DSHAgentNativeStoreErrorCorrupt);
          return NO;
        }
        if ([kind isEqualToString:@"replace_transcript"]) next[index] = change[@"row"];
        else [next removeObjectAtIndex:index];
        state[@"transcripts"] = next;
        transcripts = next;
      } else if ([kind isEqualToString:@"insert_cleanup"]) {
        NSMutableArray *next = [state[@"cleanup"] mutableCopy] ?: [NSMutableArray array];
        [next addObject:change[@"record"]];
        state[@"cleanup"] = next;
      } else if ([kind isEqualToString:@"replace_cleanup"]) {
        NSMutableArray *next = [state[@"cleanup"] mutableCopy];
        NSUInteger slot = [change[@"slot"] isKindOfClass:NSNumber.class]
            ? [change[@"slot"] unsignedIntegerValue] : NSNotFound;
        if (next == nil || slot >= next.count) {
          DSHSetAgentNativeStoreError(mutationError, DSHAgentNativeStoreErrorCorrupt);
          return NO;
        }
        next[slot] = change[@"record"];
        state[@"cleanup"] = next;
      } else {
        DSHSetAgentNativeStoreError(mutationError, DSHAgentNativeStoreErrorCorrupt);
        return NO;
      }
    }
    return YES;
  };
  if (mode == DSHAgentTranscriptRunModeSnapshot) {
    NSDictionary *snapshot = [self.wal snapshotWithError:error];
    if (snapshot == nil) return nil;
    NSError *runError = nil;
    (void)run([snapshot mutableCopy], &runError);
    if (runError != nil) {
      if (error != nullptr) *error = runError;
      return nil;
    }
    return output;
  }
  BOOL committed = [self.wal performAtomicTransaction:run error:error];
  return committed ? output : nil;
}

- (NSDictionary *)createAgentTranscriptWithRequest:(NSDictionary *)request
                                              error:(NSError **)error {
  return [self runTranscriptOperation:@"create" request:request transcriptRef:nil
                                 mode:DSHAgentTranscriptRunModeTransaction error:error];
}

- (NSDictionary *)validateAgentTranscriptWithRequest:(NSDictionary *)request
                                                error:(NSError **)error {
  return [self runTranscriptOperation:@"validate" request:request
                        transcriptRef:DSHAgentTranscriptField(request[@"transcript"], @"transcript_ref")
                                 mode:DSHAgentTranscriptRunModeSnapshot error:error];
}

- (NSArray<NSDictionary *> *)nativeMessagesForTranscriptWithRequest:
    (NSDictionary *)request
                                                                  error:(NSError **)error {
  id messages = [self runTranscriptOperation:@"native_messages" request:request
                               transcriptRef:DSHAgentTranscriptField(request[@"transcript"], @"transcript_ref")
                                        mode:DSHAgentTranscriptRunModeSnapshot error:error];
  return [messages isKindOfClass:NSArray.class] ? messages : nil;
}

- (NSDictionary *)appendMessage:(NSDictionary *)message
             expectedTranscript:(NSDictionary *)expectedTranscript
                           root:(NSDictionary *)root
                       attemptId:(NSString *)attemptId
                           error:(NSError **)error {
  NSDictionary *request = @{
    @"message" : message ?: NSNull.null,
    @"expected_transcript" : expectedTranscript ?: NSNull.null,
    @"root" : root ?: NSNull.null,
    @"attempt_id" : attemptId ?: NSNull.null,
  };
  return [self runTranscriptOperation:@"append" request:request
                        transcriptRef:DSHAgentTranscriptField(expectedTranscript, @"transcript_ref")
                                 mode:DSHAgentTranscriptRunModeTransaction error:error];
}

- (NSDictionary *)appendAssistantMessage:(NSDictionary *)message
                    expectedTranscript:(NSDictionary *)expectedTranscript
                                   root:(NSDictionary *)root
                               attemptId:(NSString *)attemptId
                                   error:(NSError **)error {
  return [self appendMessage:message expectedTranscript:expectedTranscript root:root
                   attemptId:attemptId error:error];
}

- (NSDictionary *)appendToolMessage:(NSDictionary *)message
                 expectedTranscript:(NSDictionary *)expectedTranscript
                               root:(NSDictionary *)root
                           attemptId:(NSString *)attemptId
                               error:(NSError **)error {
  return [self appendMessage:message expectedTranscript:expectedTranscript root:root
                   attemptId:attemptId error:error];
}

- (NSDictionary *)markAgentTranscriptTerminalWithRequest:(NSDictionary *)request
                                                    error:(NSError **)error {
  return [self runTranscriptOperation:@"mark_terminal" request:request
                        transcriptRef:DSHAgentTranscriptField(request[@"transcript"], @"transcript_ref")
                                 mode:DSHAgentTranscriptRunModeTransaction error:error];
}

- (NSDictionary *)discardAgentTranscriptWithRequest:(NSDictionary *)request
                                               error:(NSError **)error {
  return [self runTranscriptOperation:@"discard" request:request
                        transcriptRef:DSHAgentTranscriptField(request, @"transcript_ref")
                                 mode:DSHAgentTranscriptRunModeTransaction error:error];
}

- (NSDictionary *)queryAgentTranscriptCleanupWithRequest:(NSDictionary *)request
                                                    error:(NSError **)error {
  return [self runTranscriptOperation:@"query_cleanup" request:request transcriptRef:nil
                                 mode:DSHAgentTranscriptRunModeSnapshot error:error];
}

- (BOOL)performAtomicTransaction:(DSHAgentNativeWALMutation)mutation
                           error:(NSError **)error {
  return [self.wal performAtomicTransaction:mutation error:error];
}

@end
