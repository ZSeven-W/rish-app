#import "RishRuntimeEngineDownloads.h"
#import <CommonCrypto/CommonDigest.h>
#include <math.h>
#include <stdio.h>
#include <sys/stat.h>

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
@property(nonatomic, copy) void (^starter)(NSString *, NSURL *);
@end

@implementation RishRuntimeEngineDownloads
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
        backgroundSessionConfigurationWithIdentifier:@"tech.zseven.rish.harness-cli-download"];
    configuration.sessionSendsLaunchEvents = YES;
    configuration.timeoutIntervalForResource = 6 * 3600;
    store.session = [NSURLSession sessionWithConfiguration:configuration delegate:store delegateQueue:nil];
    // Reattach to system-owned transfers after relaunch; this never starts one.
    [store.session getAllTasksWithCompletionHandler:^(NSArray<__kindof NSURLSessionTask *> *tasks) {
      @synchronized (store) {
        for (NSURLSessionTask *task in tasks) {
          NSString *engineID = task.taskDescription;
          if (engineID && store.artifactDescriptors[engineID] && !store.states[engineID])
            store.states[engineID] = @{@"state": @"installing"};
        }
      }
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
  }
  return self;
}
- (NSURL *)ensureDirectory {
  struct stat metadata;
  if (!self.directory.isFileURL || !self.directory.path.isAbsolutePath ||
      (lstat(self.directory.fileSystemRepresentation, &metadata) == 0 && !S_ISDIR(metadata.st_mode))) return nil;
  if (![NSFileManager.defaultManager createDirectoryAtURL:self.directory withIntermediateDirectories:YES
      attributes:@{NSFileProtectionKey: NSFileProtectionComplete} error:nil]) return nil;
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
- (void)installEngine:(NSString *)engineID {
  @synchronized (self) {
    NSDictionary *descriptor = self.artifactDescriptors[engineID];
    if (!descriptor || [self verifiedArtifactForEngine:engineID] ||
        [self.states[engineID][@"state"] isEqual:@"installing"]) return;
    if (![self ensureDirectory]) {
      self.states[engineID] = @{@"error": @"download_storage_unavailable"}; return;
    }
    self.states[engineID] = @{@"state": @"installing", @"progress": @0};
    NSURL *url = [NSURL URLWithString:descriptor[@"url"]];
    if (self.starter) { self.starter(engineID, url); return; }
    // Checking the existing background tasks also closes the startup window
    // before the asynchronous restoration callback has populated local state.
    [self.session getAllTasksWithCompletionHandler:^(NSArray<__kindof NSURLSessionTask *> *tasks) {
      for (NSURLSessionTask *task in tasks) if ([task.taskDescription isEqual:engineID]) return;
      NSURLSessionDownloadTask *task = [self.session downloadTaskWithURL:url];
      task.taskDescription = engineID;
      [task resume];
    }];
  }
}
- (void)finishDownloadForEngine:(NSString *)engineID file:(NSURL *)file response:(NSHTTPURLResponse *)response {
  @synchronized (self) {
    NSDictionary *descriptor = self.artifactDescriptors[engineID];
    if (!descriptor) return;
    if (!response || response.statusCode != 200 || ![self verifyURL:file descriptor:descriptor]) {
      self.states[engineID] = @{@"error": @"download_integrity_failed"}; return;
    }
    NSURL *target = [self artifactForEngine:engineID];
    NSFileManager *manager = NSFileManager.defaultManager;
    if (![self ensureDirectory]) { self.states[engineID] = @{@"error": @"download_storage_unavailable"}; return; }
    // Stage on the target filesystem, then atomically replace. A failed move,
    // protection update or rename leaves the previous cached artifact intact.
    NSURL *staged = [self.directory URLByAppendingPathComponent:
        [@".engine-download-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    if (![manager moveItemAtURL:file toURL:staged error:nil]) {
      self.states[engineID] = @{@"error": @"download_storage_unavailable"}; return;
    }
    if (![manager setAttributes:@{NSFileProtectionKey: NSFileProtectionComplete} ofItemAtPath:staged.path error:nil] ||
        rename(staged.fileSystemRepresentation, target.fileSystemRepresentation) != 0) {
      [manager removeItemAtURL:staged error:nil];
      self.states[engineID] = @{@"error": @"download_storage_unavailable"}; return;
    }
    [self.verifiedFingerprints removeObjectForKey:engineID];
    self.states[engineID] = @{};
  }
}
- (void)failDownloadForEngine:(NSString *)engineID {
  @synchronized (self) {
    if (self.artifactDescriptors[engineID] && ![self verifiedArtifactForEngine:engineID])
      self.states[engineID] = @{@"error": @"download_failed"};
  }
}
- (void)recordProgress:(double)fraction forEngine:(NSString *)engineID {
  @synchronized (self) {
    if (self.artifactDescriptors[engineID] && isfinite(fraction) &&
        [self.states[engineID][@"state"] isEqual:@"installing"])
      self.states[engineID] = @{@"state": @"installing", @"progress": @((NSUInteger)floor(MIN(100., MAX(0., fraction * 100.))))};
  }
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task
    didFinishDownloadingToURL:(NSURL *)location {
  if (task.taskDescription) [self finishDownloadForEngine:task.taskDescription file:location
      response:[task.response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)task.response : nil];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
  if (error && task.taskDescription) [self failDownloadForEngine:task.taskDescription];
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task
    didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)total
    totalBytesExpectedToWrite:(int64_t)expected {
  if (expected > 0 && task.taskDescription) [self recordProgress:(double)total / expected forEngine:task.taskDescription];
}
@end
