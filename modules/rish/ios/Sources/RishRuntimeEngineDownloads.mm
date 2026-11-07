#import "RishRuntimeEngineDownloads.h"
#import <CommonCrypto/CommonDigest.h>
#include <math.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#import <TargetConditionals.h>
#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#endif

static NSString *RishEngineSHA256(NSURL *url) {
  NSInputStream *stream = [NSInputStream inputStreamWithURL:url];
  [stream open];
  CC_SHA256_CTX context;
  CC_SHA256_Init(&context);
  uint8_t buffer[64 * 1024];
  NSInteger count;
  while ((count = [stream read:buffer maxLength:sizeof(buffer)]) > 0)
    CC_SHA256_Update(&context, buffer, (CC_LONG)count);
  [stream close];
  if (count < 0) return nil;
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256_Final(digest, &context);
  NSMutableString *hex = [NSMutableString string];
  for (NSUInteger i = 0; i < sizeof(digest); ++i) [hex appendFormat:@"%02x", digest[i]];
  return hex;
}

@interface RishRuntimeEngineDownloads ()
@property(nonatomic, strong, readwrite) NSURL *directory;
@property(nonatomic, strong) NSDictionary *artifactDescriptors;
@property(nonatomic, strong) NSMutableDictionary *states;
@property(nonatomic, strong) NSMutableDictionary *verifiedFingerprints;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSURLSessionTask *> *tasks;
@property(nonatomic, strong) NSMutableSet<NSString *> *pendingInstalls;
@property(nonatomic) BOOL restoring;
@property(nonatomic) BOOL stateReadBlocked;
@property(nonatomic, strong) NSArray<NSURLSessionTask *> *deferredTasks;
@property(nonatomic, strong) NSMutableArray *backgroundCompletions;
@property(nonatomic) BOOL backgroundEventsFinished;
@property(nonatomic, copy) void (^starter)(NSString *, NSURL *);
@end

@implementation RishRuntimeEngineDownloads
+ (NSString *)backgroundSessionIdentifier { return @"tech.zseven.rish.harness-cli-download"; }
+ (NSDictionary<NSString *, NSDictionary *> *)descriptors {
  // Fixed release metadata reviewed 2026-10-29. Keep URL, version, length and
  // digest together; a successful HTTP transfer alone is not an installation.
  // https://api.github.com/repos/openai/codex/releases/tags/rust-v0.153.4
  // https://downloads.claude.ai/claude-code-releases/2.1.276/manifest.json
  return @{
    @"codex": @{@"version": @"0.153.4", @"file": @"codex-cli.tar.gz",
      @"url": @"https://github.com/openai/codex/releases/download/rust-v0.153.4/codex-x86_64-unknown-linux-musl.tar.gz",
      @"size": @98582872,
      @"sha256": @"f479424eca092484dc40d87ae28c44f4cc40234a60045d6131e493800d814a30"},
    @"claude-code": @{@"version": @"2.1.276", @"file": @"claude-cli.bin",
      @"url": @"https://downloads.claude.ai/claude-code-releases/2.1.276/linux-x64-musl/claude",
      @"size": @225980376,
      @"sha256": @"396c3914f3e25b6c66535a55ea06ce9927896ffb7cd25f368c703e06373ff97e"}
  };
}
+ (instancetype)shared {
  static RishRuntimeEngineDownloads *store;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
        inDomains:NSUserDomainMask].firstObject;
    store = [[self alloc] initWithDirectory:[support URLByAppendingPathComponent:@"harness-cli" isDirectory:YES]
        descriptors:self.descriptors starter:nil];
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration
        backgroundSessionConfigurationWithIdentifier:self.backgroundSessionIdentifier];
    configuration.sessionSendsLaunchEvents = YES;
    configuration.timeoutIntervalForResource = 6 * 3600;
    [store beginRestoringTasks];
    store.session = [NSURLSession sessionWithConfiguration:configuration delegate:store delegateQueue:nil];
    [store.session getAllTasksWithCompletionHandler:^(NSArray<__kindof NSURLSessionTask *> *tasks) {
      [store restoreTasks:tasks];
    }];
  });
  return store;
}
- (instancetype)initWithDirectory:(NSURL *)directory descriptors:(NSDictionary *)descriptors
    starter:(void (^)(NSString *, NSURL *))starter {
  if ((self = [super init])) {
    _directory = directory;
    _artifactDescriptors = [descriptors copy];
    _starter = [starter copy];
    _states = [NSMutableDictionary dictionary];
    _verifiedFingerprints = [NSMutableDictionary dictionary];
    _tasks = [NSMutableDictionary dictionary];
    _pendingInstalls = [NSMutableSet set];
    _backgroundCompletions = [NSMutableArray array];
    [self loadStates];
#if TARGET_OS_IOS
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(retryDeferredRestoration)
        name:UIApplicationProtectedDataDidBecomeAvailable object:nil];
#endif
  }
  return self;
}
- (NSURL *)ensureDirectory {
  struct stat metadata;
  if (!self.directory.isFileURL || !self.directory.path.isAbsolutePath ||
      (lstat(self.directory.fileSystemRepresentation, &metadata) == 0 && !S_ISDIR(metadata.st_mode))) return nil;
  if (![NSFileManager.defaultManager createDirectoryAtURL:self.directory withIntermediateDirectories:YES
      attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil]) return nil;
  // This directory and attempt journal contain public release metadata only.
  // Keep them readable for background reconciliation after the first unlock;
  // downloaded executable files retain Complete protection below.
  if (![NSFileManager.defaultManager setAttributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication}
      ofItemAtPath:self.directory.path error:nil]) return nil;
  [self.directory setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
  return self.directory;
}
- (NSURL *)artifactForEngine:(NSString *)engineID {
  NSString *filename = self.artifactDescriptors[engineID][@"file"];
  return filename ? [self.directory URLByAppendingPathComponent:filename] : nil;
}
- (NSString *)fingerprintForURL:(NSURL *)url expectedSize:(NSNumber *)size {
  struct stat metadata;
  if (!url || lstat(url.fileSystemRepresentation, &metadata) != 0 || !S_ISREG(metadata.st_mode) ||
      metadata.st_size != size.longLongValue) return nil;
  return [NSString stringWithFormat:@"%llu:%llu:%lld:%ld:%lld:%ld",
      (unsigned long long)metadata.st_dev, (unsigned long long)metadata.st_ino,
      (long long)metadata.st_mtimespec.tv_sec, metadata.st_mtimespec.tv_nsec,
      (long long)metadata.st_ctimespec.tv_sec, metadata.st_ctimespec.tv_nsec];
}
- (BOOL)verifyURL:(NSURL *)url descriptor:(NSDictionary *)descriptor {
  NSString *before = [self fingerprintForURL:url expectedSize:descriptor[@"size"]];
  if (!before || ![RishEngineSHA256(url) isEqual:descriptor[@"sha256"]]) return NO;
  return [before isEqual:[self fingerprintForURL:url expectedSize:descriptor[@"size"]]];
}
- (NSURL *)verifiedArtifactForEngine:(NSString *)engineID {
  @synchronized (self) {
    struct stat directory;
    if (lstat(self.directory.fileSystemRepresentation, &directory) != 0 || !S_ISDIR(directory.st_mode)) return nil;
    NSDictionary *descriptor = self.artifactDescriptors[engineID];
    NSURL *url = [self artifactForEngine:engineID];
    NSString *fingerprint = [self fingerprintForURL:url expectedSize:descriptor[@"size"]];
    if (!fingerprint) { [self.verifiedFingerprints removeObjectForKey:engineID]; return nil; }
    if ([fingerprint isEqual:self.verifiedFingerprints[engineID]]) return url;
    if (![self verifyURL:url descriptor:descriptor]) return nil;
    self.verifiedFingerprints[engineID] = fingerprint;
    return url;
  }
}
- (NSDictionary *)installationForEngine:(NSString *)engineID {
  @synchronized (self) {
    NSDictionary *descriptor = self.artifactDescriptors[engineID];
    if (!descriptor) return @{@"state": @"unavailable", @"version": NSNull.null,
      @"download_supported": @NO, @"integrity": @"unknown", @"reason_code": @"installer_unavailable"};
    if (self.stateReadBlocked) return @{@"state": @"installing", @"version": NSNull.null,
        @"available_version": descriptor[@"version"], @"download_supported": @NO, @"integrity": @"unknown",
        @"reason_code": @"download_storage_locked"};
    NSDictionary *state = self.states[engineID];
    BOOL verified = [self verifiedArtifactForEngine:engineID] != nil;
    struct stat metadata;
    NSURL *file = [self artifactForEngine:engineID];
    BOOL exists = file && lstat(file.fileSystemRepresentation, &metadata) == 0;
    NSString *phase = verified ? @"downloaded" : ([state[@"state"] isEqual:@"installing"] ? @"installing" :
        (exists ? @"downloaded" : @"not_installed"));
    NSMutableDictionary *result = [@{@"state": phase, @"version": verified ? descriptor[@"version"] : NSNull.null,
        @"available_version": descriptor[@"version"],
        @"download_supported": @YES, @"integrity": verified ? @"verified" : (exists ? @"unverified" : @"unknown")} mutableCopy];
    if ([phase isEqual:@"installing"] && state[@"progress"]) result[@"progress"] = state[@"progress"];
    if (!verified && state[@"error"]) result[@"error"] = state[@"error"];
    return result;
  }
}
// The durable attempt is the authority for every progress/completion callback.
// A cancelled or superseded system task can never publish into another attempt.
- (NSURL *)stateFile { return [self.directory URLByAppendingPathComponent:@".engine-download-state.json"]; }
- (void)loadStates {
  struct stat metadata;
  NSURL *file = [self stateFile];
  self.stateReadBlocked = NO;
  if (lstat(self.directory.fileSystemRepresentation, &metadata) != 0) {
    self.stateReadBlocked = errno != ENOENT; return;
  }
  if (!S_ISDIR(metadata.st_mode)) { self.stateReadBlocked = YES; return; }
  if (lstat(file.fileSystemRepresentation, &metadata) != 0) {
    self.stateReadBlocked = errno != ENOENT; return;
  }
  if (!S_ISREG(metadata.st_mode) || metadata.st_size > 65536) { self.stateReadBlocked = YES; return; }
  NSData *bytes = [NSData dataWithContentsOfURL:file];
  if (!bytes) { self.stateReadBlocked = YES; return; }
  id saved = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
  if (![saved isKindOfClass:NSDictionary.class]) return;
  for (NSString *engine in self.artifactDescriptors) {
    id record = saved[engine];
    if (![record isKindOfClass:NSDictionary.class] ||
        ![record[@"digest"] isEqual:self.artifactDescriptors[engine][@"sha256"]]) continue;
    NSString *attempt = record[@"attempt"];
    if (![attempt isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:attempt]) continue;
    NSString *phase = record[@"state"];
    if (![@[@"installing", @"cancelled", @"finished", @"failed"] containsObject:phase ?: @""]) continue;
    NSMutableDictionary *state = [@{@"attempt": attempt, @"digest": record[@"digest"], @"state": phase} mutableCopy];
    if ([@[@"download_failed", @"download_integrity_failed", @"download_storage_unavailable", @"download_interrupted"]
        containsObject:record[@"error"] ?: @""]) state[@"error"] = record[@"error"];
    self.states[engine] = state;
  }
}
- (BOOL)saveStates {
  if (self.stateReadBlocked || ![self ensureDirectory]) return NO;
  struct stat metadata;
  NSURL *file = [self stateFile];
  if (lstat(file.fileSystemRepresentation, &metadata) == 0 && !S_ISREG(metadata.st_mode)) return NO;
  NSData *data = [NSJSONSerialization dataWithJSONObject:self.states options:0 error:nil];
  return data && [data writeToURL:file options:NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:nil];
}
- (NSString *)attemptForEngine:(NSString *)engineID {
  @synchronized (self) { return self.states[engineID][@"attempt"]; }
}
- (BOOL)isCurrentEngine:(NSString *)engineID attempt:(NSString *)attempt {
  NSDictionary *state = self.states[engineID];
  return attempt && [state[@"attempt"] isEqual:attempt] && [state[@"state"] isEqual:@"installing"];
}
- (void)setTerminal:(NSString *)phase error:(NSString *)error engine:(NSString *)engineID {
  NSMutableDictionary *record = [self.states[engineID] mutableCopy];
  if (!record) return;
  record[@"state"] = phase;
  [record removeObjectForKey:@"progress"];
  if (error) record[@"error"] = error; else [record removeObjectForKey:@"error"];
  self.states[engineID] = record;
  [self.pendingInstalls removeObject:engineID];
  [self.tasks removeObjectForKey:engineID];
  if (![self saveStates]) {
    record[@"error"] = @"download_storage_unavailable";
    self.states[engineID] = record;
  }
}
- (NSArray<NSString *> *)identityForTask:(NSURLSessionTask *)task {
  NSArray *identity = [task.taskDescription componentsSeparatedByString:@"|"];
  if (identity.count != 3) return nil;
  NSDictionary *descriptor = self.artifactDescriptors[identity[0]];
  if (!descriptor || ![identity[2] isEqual:descriptor[@"sha256"]] ||
      ![[NSUUID alloc] initWithUUIDString:identity[1]] ||
      ![task.originalRequest.URL.absoluteString isEqual:descriptor[@"url"]]) return nil;
  return identity;
}
- (void)beginRestoringTasks {
  @synchronized (self) { self.restoring = YES; }
}
- (void)restoreTasks:(NSArray<NSURLSessionTask *> *)tasks {
  @synchronized (self) {
    if (!self.restoring) return;
    if (self.stateReadBlocked) { self.deferredTasks = [tasks copy]; return; }
    self.deferredTasks = nil;
    // The file rename can commit before the attempt journal is saved. Reuse
    // verified bytes rather than resuming a duplicate system download.
    for (NSString *engine in self.artifactDescriptors) {
      if ([self.states[engine][@"state"] isEqual:@"installing"] && [self verifiedArtifactForEngine:engine])
        [self setTerminal:@"finished" error:nil engine:engine];
    }
    [self publishDeferredDownloads];
    for (NSURLSessionTask *task in tasks) {
      NSArray *identity = [self identityForTask:task];
      NSString *engine = identity.firstObject;
      // Legacy engine-only tasks cannot prove an attempt or artifact version.
      // Cancel them and require an explicit retry instead of adopting blindly.
      if (!identity || ![self isCurrentEngine:engine attempt:identity[1]] ||
          (self.tasks[engine] && self.tasks[engine] != task) || task.state == NSURLSessionTaskStateCanceling || task.state == NSURLSessionTaskStateCompleted) {
        [task cancel]; continue;
      }
      self.tasks[engine] = task;
      [self.pendingInstalls removeObject:engine];
      if (task.state == NSURLSessionTaskStateSuspended) [task resume];
    }
    self.restoring = NO;
    for (NSString *engine in self.artifactDescriptors) {
      if (![self.states[engine][@"state"] isEqual:@"installing"] || self.tasks[engine]) continue;
      if ([self.pendingInstalls containsObject:engine]) [self startTransfer:engine];
      else [self setTerminal:@"failed" error:@"download_interrupted" engine:engine];
    }
    // Only unlink regular files with our exact staging-name format. Never
    // recurse into a directory or follow a link left in the cache.
    struct stat directory;
    if (lstat(self.directory.fileSystemRepresentation, &directory) != 0 || !S_ISDIR(directory.st_mode)) return;
    for (NSURL *file in [NSFileManager.defaultManager contentsOfDirectoryAtURL:self.directory
        includingPropertiesForKeys:nil options:0 error:nil]) {
      NSString *name = file.lastPathComponent;
      if (![name hasPrefix:@".engine-download-"]) continue;
      NSString *suffix = [name substringFromIndex:@".engine-download-".length];
      struct stat metadata;
      if ([[NSUUID alloc] initWithUUIDString:suffix] && lstat(file.fileSystemRepresentation, &metadata) == 0 && S_ISREG(metadata.st_mode))
        unlink(file.fileSystemRepresentation);
    }
  }
}
- (void)retryDeferredRestoration {
  @synchronized (self) {
    if (!self.stateReadBlocked) return;
    [self loadStates];
    if (!self.stateReadBlocked && self.deferredTasks) [self restoreTasks:self.deferredTasks];
  }
}
- (void)startTransfer:(NSString *)engineID {
  [self.pendingInstalls removeObject:engineID];
  NSURL *url = [NSURL URLWithString:self.artifactDescriptors[engineID][@"url"]];
  if (self.starter) { self.starter(engineID, url); return; }
  NSURLSessionDownloadTask *task = [self.session downloadTaskWithURL:url];
  if (!task) { [self setTerminal:@"failed" error:@"download_failed" engine:engineID]; return; }
  task.taskDescription = [NSString stringWithFormat:@"%@|%@|%@", engineID,
      self.states[engineID][@"attempt"], self.artifactDescriptors[engineID][@"sha256"]];
  self.tasks[engineID] = task;
  [task resume];
}
- (void)installEngine:(NSString *)engineID {
  @synchronized (self) {
    NSDictionary *descriptor = self.artifactDescriptors[engineID];
    if (self.stateReadBlocked || !descriptor || [self verifiedArtifactForEngine:engineID] ||
        [self.states[engineID][@"state"] isEqual:@"installing"]) return;
    self.states[engineID] = @{@"state": @"installing", @"progress": @0,
        @"attempt": NSUUID.UUID.UUIDString, @"digest": descriptor[@"sha256"]};
    if (![self saveStates]) { [self setTerminal:@"failed" error:@"download_storage_unavailable" engine:engineID]; return; }
    // Explicit retry clears only a corrupt regular artifact. Suspicious links
    // and directories are left untouched and prevent publication.
    NSURL *artifact = [self artifactForEngine:engineID];
    struct stat metadata;
    if (lstat(artifact.fileSystemRepresentation, &metadata) == 0 &&
        (!S_ISREG(metadata.st_mode) || unlink(artifact.fileSystemRepresentation) != 0)) {
      [self setTerminal:@"failed" error:@"download_storage_unavailable" engine:engineID]; return;
    }
    if (self.restoring) [self.pendingInstalls addObject:engineID];
    else [self startTransfer:engineID];
  }
}
- (void)cancelEngine:(NSString *)engineID {
  @synchronized (self) {
    if (![self.states[engineID][@"state"] isEqual:@"installing"]) return;
    NSURLSessionTask *task = self.tasks[engineID];
    [self setTerminal:@"cancelled" error:nil engine:engineID];
    [task cancel];
  }
}
- (void)discardTemporary:(NSURL *)file {
  // URLSession owns this transient path. Do not delete a cache artifact or
  // recursively remove a malformed directory supplied by the transport.
  for (NSString *engine in self.artifactDescriptors)
    if ([file.path isEqual:[self artifactForEngine:engine].path]) return;
  struct stat metadata;
  if (file.isFileURL && lstat(file.fileSystemRepresentation, &metadata) == 0 && S_ISREG(metadata.st_mode))
    unlink(file.fileSystemRepresentation);
}
- (void)finishDownloadForEngine:(NSString *)engineID attempt:(NSString *)attempt file:(NSURL *)file
    response:(NSHTTPURLResponse *)response {
  @synchronized (self) {
    if (![self isCurrentEngine:engineID attempt:attempt]) { [self discardTemporary:file]; return; }
    NSDictionary *descriptor = self.artifactDescriptors[engineID];
    if (!response || response.statusCode != 200 || ![self verifyURL:file descriptor:descriptor]) {
      [self discardTemporary:file];
      [self setTerminal:@"failed" error:@"download_integrity_failed" engine:engineID]; return;
    }
    NSURL *target = [self artifactForEngine:engineID];
    NSFileManager *manager = NSFileManager.defaultManager;
    struct stat metadata;
    if (![self ensureDirectory] || (lstat(target.fileSystemRepresentation, &metadata) == 0 && !S_ISREG(metadata.st_mode))) {
      [self discardTemporary:file];
      [self setTerminal:@"failed" error:@"download_storage_unavailable" engine:engineID]; return;
    }
    NSURL *staged = [self.directory URLByAppendingPathComponent:
        [@".engine-download-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    if (![manager moveItemAtURL:file toURL:staged error:nil]) {
      [self discardTemporary:file];
      [self setTerminal:@"failed" error:@"download_storage_unavailable" engine:engineID]; return;
    }
    if (![manager setAttributes:@{NSFileProtectionKey: NSFileProtectionComplete} ofItemAtPath:staged.path error:nil] ||
        rename(staged.fileSystemRepresentation, target.fileSystemRepresentation) != 0) {
      unlink(staged.fileSystemRepresentation);
      [self setTerminal:@"failed" error:@"download_storage_unavailable" engine:engineID]; return;
    }
    [self.verifiedFingerprints removeObjectForKey:engineID];
    [self setTerminal:@"finished" error:nil engine:engineID];
  }
}
- (void)failDownloadForEngine:(NSString *)engineID attempt:(NSString *)attempt {
  @synchronized (self) {
    if ([self isCurrentEngine:engineID attempt:attempt])
      [self setTerminal:@"failed" error:@"download_failed" engine:engineID];
  }
}
- (void)recordProgress:(double)fraction forEngine:(NSString *)engineID attempt:(NSString *)attempt {
  @synchronized (self) {
    if (isfinite(fraction) && [self isCurrentEngine:engineID attempt:attempt]) {
      NSMutableDictionary *state = [self.states[engineID] mutableCopy];
      NSUInteger progress = (NSUInteger)floor(MIN(100., MAX(0., fraction * 100.)));
      state[@"progress"] = @(MAX([state[@"progress"] unsignedIntegerValue], progress));
      self.states[engineID] = state;
    }
  }
}
// The system deletes a download URL when its delegate returns. Preserve bytes
// and a bounded public receipt while the authority journal is unreadable, then
// validate the attempt after unlock (also after a process restart).
- (BOOL)deferDownload:(NSURL *)location task:(NSURLSessionTask *)task {
  NSArray<NSString *> *identity = [self identityForTask:task];
  NSHTTPURLResponse *response = [task.response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)task.response : nil;
  if (!identity || response.statusCode != 200 || ![self verifyURL:location descriptor:self.artifactDescriptors[identity[0]]] ||
      ![self ensureDirectory]) return NO;
  NSString *name = [@".engine-deferred-" stringByAppendingString:identity[1].uppercaseString];
  NSURL *bytes = [self.directory URLByAppendingPathComponent:[name stringByAppendingString:@".bin"]];
  NSURL *receipt = [self.directory URLByAppendingPathComponent:[name stringByAppendingString:@".json"]];
  struct stat metadata;
  if (lstat(bytes.fileSystemRepresentation, &metadata) == 0 || errno != ENOENT ||
      lstat(receipt.fileSystemRepresentation, &metadata) == 0 || errno != ENOENT) return NO;
  if (![NSFileManager.defaultManager moveItemAtURL:location toURL:bytes error:nil]) return NO;
  NSDictionary *record = @{@"engine": identity[0], @"attempt": identity[1], @"digest": identity[2], @"status": @(response.statusCode)};
  NSData *data = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
  if (![NSFileManager.defaultManager setAttributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication}
      ofItemAtPath:bytes.path error:nil] ||
      ![data writeToURL:receipt options:NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:nil]) {
    unlink(bytes.fileSystemRepresentation); return NO;
  }
  return YES;
}
- (void)publishDeferredDownloads {
  struct stat directory;
  if (lstat(self.directory.fileSystemRepresentation, &directory) != 0 || !S_ISDIR(directory.st_mode)) return;
  for (NSURL *file in [NSFileManager.defaultManager contentsOfDirectoryAtURL:self.directory
      includingPropertiesForKeys:nil options:0 error:nil]) {
    NSString *name = file.lastPathComponent;
    if (![name hasPrefix:@".engine-deferred-"]) continue;
    NSString *identifier = [[name stringByDeletingPathExtension] substringFromIndex:@".engine-deferred-".length];
    struct stat metadata;
    if (![[NSUUID alloc] initWithUUIDString:identifier] ||
        lstat(file.fileSystemRepresentation, &metadata) != 0 || !S_ISREG(metadata.st_mode)) continue;
    NSURL *base = [file URLByDeletingPathExtension];
    if ([file.pathExtension isEqual:@"bin"]) {
      // The process can stop after moving the bytes but before writing the receipt.
      NSURL *receipt = [base URLByAppendingPathExtension:@"json"];
      if (lstat(receipt.fileSystemRepresentation, &metadata) != 0 && errno == ENOENT) [self discardTemporary:file];
      continue;
    }
    if (![file.pathExtension isEqual:@"json"] || metadata.st_size > 4096) continue;
    NSData *data = [NSData dataWithContentsOfURL:file];
    if (!data) continue;
    id record = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSURL *bytes = [base URLByAppendingPathExtension:@"bin"];
    if ([record isKindOfClass:NSDictionary.class] && [record[@"engine"] isKindOfClass:NSString.class] &&
        [record[@"attempt"] isKindOfClass:NSString.class] && [record[@"status"] isKindOfClass:NSNumber.class] &&
        [record[@"digest"] isEqual:self.artifactDescriptors[record[@"engine"]][@"sha256"]]) {
      NSURL *url = [NSURL URLWithString:self.artifactDescriptors[record[@"engine"]][@"url"]];
      NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:url statusCode:[record[@"status"] integerValue]
          HTTPVersion:@"HTTP/1.1" headerFields:@{}];
      [self finishDownloadForEngine:record[@"engine"] attempt:record[@"attempt"] file:bytes response:response];
    }
    [self discardTemporary:bytes];
    unlink(file.fileSystemRepresentation);
  }
}
- (NSArray<NSString *> *)callbackIdentityForTask:(NSURLSessionTask *)task bindIfRestoring:(BOOL)bind {
  @synchronized (self) {
    if (self.stateReadBlocked) return nil;
    NSArray *identity = [self identityForTask:task];
    if (!identity || ![self isCurrentEngine:identity[0] attempt:identity[1]]) return nil;
    NSURLSessionTask *owned = self.tasks[identity[0]];
    if ((owned && owned != task) || task.state == NSURLSessionTaskStateCanceling) return nil;
    // An unowned cancellation/error before enumeration may belong to a
    // duplicate rejected by the previous process. Let reconciliation decide.
    if (!owned && self.restoring && !bind) return nil;
    // A background delegate may arrive before getAllTasks completes. Bind it
    // now, so another task with a duplicate description cannot settle it.
    if (!owned && self.restoring) self.tasks[identity[0]] = task;
    return identity;
  }
}
- (void)handleBackgroundEventsWithCompletion:(void (^)(void))completion {
  @synchronized (self) {
    [self.backgroundCompletions addObject:[completion copy]];
    [self finishBackgroundEventsIfReady];
  }
}
- (void)finishBackgroundEventsIfReady {
  if (!self.backgroundEventsFinished || !self.backgroundCompletions.count) return;
  NSArray *completions = [self.backgroundCompletions copy];
  [self.backgroundCompletions removeAllObjects];
  self.backgroundEventsFinished = NO;
  dispatch_async(dispatch_get_main_queue(), ^{
    for (void (^completion)(void) in completions) completion();
  });
}
- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session {
  @synchronized (self) {
    self.backgroundEventsFinished = YES;
    [self finishBackgroundEventsIfReady];
  }
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task
    didFinishDownloadingToURL:(NSURL *)location {
  @synchronized (self) {
    if (self.stateReadBlocked) {
      if (![self deferDownload:location task:task]) [self discardTemporary:location];
      return;
    }
  }
  NSArray *identity = [self callbackIdentityForTask:task bindIfRestoring:YES];
  if (identity) [self finishDownloadForEngine:identity[0] attempt:identity[1] file:location
      response:[task.response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)task.response : nil];
  else [self discardTemporary:location];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
  NSArray *identity = [self callbackIdentityForTask:task bindIfRestoring:NO];
  if (error && identity) [self failDownloadForEngine:identity[0] attempt:identity[1]];
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task
    didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)total
    totalBytesExpectedToWrite:(int64_t)expected {
  @synchronized (self) {
    NSArray *identity = [self callbackIdentityForTask:task bindIfRestoring:YES];
    if (!identity) return;
    int64_t limit = [self.artifactDescriptors[identity[0]][@"size"] longLongValue];
    if (expected > limit || total > limit) {
      [self setTerminal:@"failed" error:@"download_integrity_failed" engine:identity[0]];
      [task cancel];
      return;
    }
    if (limit > 0 && total >= 0) [self recordProgress:(double)total / limit forEngine:identity[0] attempt:identity[1]];
  }
}
@end
