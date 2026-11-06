#import "RishGuestCgiService.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <errno.h>
#import <limits.h>
#import <math.h>
#import <os/log.h>

#import "LocalGuestModule.h"
#import "RishGuestCgiHTTP.h"

static NSUInteger const kMaxHtmlBytes = 32 * 1024;
static NSUInteger const kMaxScriptBytes = 8 * 1024;
static NSUInteger const kMaxInitialDataBytes = 4 * 1024;
static NSUInteger const kMaxResponseBytes = 1024 * 1024;
static NSUInteger const kMaxCommandArgBytes = 4096;
static NSUInteger const kStageChunkBytes = 3000;
static NSTimeInterval const kBackendTimeout = 5.0;
static NSTimeInterval const kSocketTimeout = 6.0;
// Never renew in background. Use the OS grant up to a two-minute total cap,
// reserving five seconds for closing sockets and owned guest teardown.
static NSTimeInterval const kPreviewTotalLimit = 120.0;
static NSTimeInterval const kPreviewCleanupReserve = 5.0;
static NSTimeInterval RishCgiPreviewDuration(NSTimeInterval remaining, NSTimeInterval limit) {
  if (isnan(remaining) || remaining <= kPreviewCleanupReserve) return 0;
  return MIN(MIN(limit, kPreviewTotalLimit - kPreviewCleanupReserve), remaining - kPreviewCleanupReserve);
}


static NSString *const kErrorInvalid = @"E_CGI_INVALID_REQUEST";
static NSString *const kErrorBusy = @"E_CGI_BUSY";
static NSString *const kErrorGuest = @"E_CGI_GUEST";
static NSString *const kErrorTimeout = @"E_CGI_TIMEOUT";

static BOOL RishGuestCgiCookieMatches(NSString *header,
                                      NSString *expectedValue,
                                      NSUInteger *ownCookieCountOut) {
  NSUInteger ownCookieCount = 0;
  BOOL valueMatches = NO;
  for (NSString *rawPair in [header componentsSeparatedByString:@";"]) {
    NSString *pair = [rawPair stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSRange equals = [pair rangeOfString:@"="];
    if (equals.location == NSNotFound) continue;
    NSString *name = [pair substringToIndex:equals.location];
    if (![name isEqualToString:@"rish_cgi"]) continue;
    ownCookieCount += 1;
    NSString *value = [pair substringFromIndex:equals.location + 1];
    valueMatches = ownCookieCount == 1 && [value isEqualToString:expectedValue];
  }
  if (ownCookieCountOut) *ownCookieCountOut = ownCookieCount;
  return ownCookieCount == 1 && valueMatches;
}

// A finite UIKit lease, not a background mode. All UIKit calls run on main.
@interface RishCgiPreviewLease : NSObject
@property(atomic) UIBackgroundTaskIdentifier identifier;
@property(atomic) BOOL finished;
@property(atomic) BOOL expired;
@property(nonatomic, copy) void (^endTask)(UIBackgroundTaskIdentifier);
- (void)finish;
@end
@implementation RishCgiPreviewLease
- (instancetype)init { if ((self = [super init])) _identifier = UIBackgroundTaskInvalid; return self; }
- (void)endOnMain {
  UIBackgroundTaskIdentifier task;
  void (^end)(UIBackgroundTaskIdentifier);
  @synchronized(self) {
    task = self.identifier; self.identifier = UIBackgroundTaskInvalid; end = self.endTask;
  }
  if (task != UIBackgroundTaskInvalid && end) end(task);
}
- (void)finish {
  @synchronized(self) { self.finished = YES; }
  // Even if cleanup already queued an end from the service queue, an expiry
  // handler on main must flush that end before returning to UIKit.
  if (NSThread.isMainThread) [self endOnMain];
  else dispatch_async(dispatch_get_main_queue(), ^{ [self endOnMain]; });
}
- (void)dealloc {
  UIBackgroundTaskIdentifier task = _identifier;
  void (^end)(UIBackgroundTaskIdentifier) = _endTask;
  if (task == UIBackgroundTaskInvalid || !end) return;
  if (NSThread.isMainThread) end(task);
  else dispatch_async(dispatch_get_main_queue(), ^{ end(task); });
}

@end

@interface RishGuestCgiService ()
@property(nonatomic, strong) LocalGuestModule *guest;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) dispatch_queue_t clientQueue;
@property(nonatomic, strong) NSMutableSet<NSValue *> *clients;
@property(nonatomic, copy) NSString *serviceId;
@property(nonatomic, copy) NSString *serviceRoot;
@property(nonatomic, copy) NSString *indexHtml;
@property(nonatomic, copy) NSString *backendScript;
@property(nonatomic, copy) NSString *initialDataPath;
@property(nonatomic, assign) int listenerFD;
@property(nonatomic, strong) dispatch_source_t listenerSource;
@property(nonatomic, assign) BOOL starting;
@property(nonatomic, assign) BOOL stopping;
@property(nonatomic, assign) BOOL guestOwned;
@property(nonatomic, assign) BOOL requestBusy;
@property(nonatomic, assign) NSUInteger generation;
@property(nonatomic, copy, nullable) void (^stopResolve)(NSDictionary *result);
@property(nonatomic, copy, nullable) RishGuestCgiReject stopReject;
@property(nonatomic, copy) NSString *cookieValue;
@property(nonatomic, copy, nullable) RishGuestCgiReject startReject;
@property(nonatomic, assign) BOOL startCompletionSent;
@property(nonatomic, strong) id backgroundObserver;
@property(nonatomic, strong) id foregroundObserver;
@property(nonatomic) BOOL backgrounded;
@property(nonatomic) NSUInteger previewEpoch;
@property(nonatomic, strong) RishCgiPreviewLease *previewLease;
@property(nonatomic, copy) UIBackgroundTaskIdentifier (^beginPreviewTask)(void (^)(void));
@property(nonatomic, copy) void (^endPreviewTask)(UIBackgroundTaskIdentifier);
@property(nonatomic) NSTimeInterval previewLimit;
@property(nonatomic, copy) NSTimeInterval (^previewRemaining)(void);

@end

@implementation RishGuestCgiService

- (instancetype)init {
  self = [super init];
  if (self) {
    _guest = [[LocalGuestModule alloc] init];
    _queue = dispatch_queue_create("dev.zseven.rish.experimental-cgi", DISPATCH_QUEUE_SERIAL);
    _clientQueue = dispatch_queue_create("dev.zseven.rish.experimental-cgi.clients", DISPATCH_QUEUE_CONCURRENT);
    _clients = [NSMutableSet set];
    _previewLimit = kPreviewTotalLimit - kPreviewCleanupReserve;
    _previewRemaining = ^NSTimeInterval { return UIApplication.sharedApplication.backgroundTimeRemaining; };
    _beginPreviewTask = ^UIBackgroundTaskIdentifier(void (^expiration)(void)) {
      NSCAssert(NSThread.isMainThread, @"UIKit background lease requires main");
      return [UIApplication.sharedApplication beginBackgroundTaskWithName:@"Rish finite CGI preview" expirationHandler:expiration];
    };
    _endPreviewTask = ^(UIBackgroundTaskIdentifier task) {
      NSCAssert(NSThread.isMainThread, @"UIKit background lease requires main");
      [UIApplication.sharedApplication endBackgroundTask:task];
    };
    __weak RishGuestCgiService *weakSelf = self;
    _backgroundObserver = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil usingBlock:^(NSNotification *note) { [weakSelf enterPreviewBackground]; }];
    _foregroundObserver = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:nil usingBlock:^(NSNotification *note) { [weakSelf leavePreviewBackground]; }];
    _listenerFD = -1;
  }
  return self;
}

// Test-only factory. Production callers use -init, which always creates the
// guest owned by this service. Keeping injection behind a test-named selector
// prevents arbitrary caller-owned sessions from becoming teardown targets.
- (instancetype)initWithGuestFactoryForTesting:(LocalGuestModule *(^)(void))factory {
  self = [self init];
  if (self && factory) _guest = factory();
  return self;
}

// Private test injection only; callers cannot acquire a lease through UI.
- (NSTimeInterval)previewDurationForTesting:(NSTimeInterval)remaining {
  return RishCgiPreviewDuration(remaining, kPreviewTotalLimit - kPreviewCleanupReserve);
}

- (void)setPreviewTaskForTesting:(UIBackgroundTaskIdentifier (^)(void (^)(void)))begin end:(void (^)(UIBackgroundTaskIdentifier))end limit:(NSTimeInterval)limit {
  self.beginPreviewTask = begin; self.endPreviewTask = end; self.previewLimit = MIN(kPreviewTotalLimit - kPreviewCleanupReserve, MAX(0.01, limit));
  self.previewRemaining = ^NSTimeInterval { return 30.0; };
}

- (void)stopForPreviewEnd {
  if (!self.serviceId || self.stopping) return;
  self.stopping = YES; ++self.generation;
  [self closeListener];
  if (!self.startCompletionSent && self.startReject) {
    self.startCompletionSent = YES;
    RishGuestCgiReject reject = self.startReject; self.startReject = nil;
    reject(@"E_CGI_STOPPING", @"finite background preview ended");
  }
  self.stopResolve = ^(NSDictionary *result) {};
  self.stopReject = ^(NSString *code, NSString *message) {};
  [self completeStopAfterGuestReady];
}

- (void)enterPreviewBackground {
  dispatch_async(self.queue, ^{
    if (self.backgrounded) return;
    self.backgrounded = YES;
    NSUInteger epoch = ++self.previewEpoch;
    if (!self.serviceId || self.stopping) return;
    if (self.starting || self.listenerFD < 0) { [self stopForPreviewEnd]; return; }
    __weak RishGuestCgiService *weakSelf = self;
    UIBackgroundTaskIdentifier (^begin)(void (^)(void)) = self.beginPreviewTask;
    void (^end)(UIBackgroundTaskIdentifier) = self.endPreviewTask;
    NSTimeInterval limit = self.previewLimit;
    NSTimeInterval (^remainingTime)(void) = self.previewRemaining;
    dispatch_async(dispatch_get_main_queue(), ^{
      RishCgiPreviewLease *lease = [RishCgiPreviewLease new]; lease.endTask = end;
      __weak RishCgiPreviewLease *weakLease = lease;
      void (^expire)(BOOL) = ^(BOOL systemExpiration) {
        RishCgiPreviewLease *owned = weakLease;
        if (!owned) return;
        @synchronized(owned) {
          if (owned.finished || owned.expired) return;
          owned.expired = YES;
        }
        RishGuestCgiService *service = weakSelf;
        if (!service) { [owned finish]; return; }
        void (^markStopped)(void) = ^{
          if (service.previewEpoch == epoch && service.backgrounded) [service stopForPreviewEnd];
        };
        if (systemExpiration) {
          // UIKit requires endBackgroundTask before this main-thread handler
          // returns. The service queue never waits for main, and this marks
          // stop/closes sockets only; owned guest cleanup is asynchronous.
          dispatch_sync(service.queue, markStopped);
          [owned finish];
          return;
        }
        dispatch_async(service.queue, markStopped);
        // Our own deadline reserves five additional seconds for teardown.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPreviewCleanupReserve * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [owned finish]; });
      };
      UIBackgroundTaskIdentifier task = begin(^{ expire(YES); });
      @synchronized(lease) {
        if (lease.finished) { if (task != UIBackgroundTaskInvalid) end(task); }
        else lease.identifier = task;
      }
      if (task == UIBackgroundTaskInvalid || lease.expired) [lease finish];
      NSTimeInterval remaining = remainingTime();
      NSTimeInterval allowedPreview = RishCgiPreviewDuration(remaining, limit);
#if DEBUG
      os_log(OS_LOG_DEFAULT, "cgi_preview grant_valid=%{public}d remaining_seconds_capped=%{public}.0f preview_seconds=%{public}.0f", task != UIBackgroundTaskInvalid, isnan(remaining) ? 0.0 : MAX(0.0, MIN(remaining, kPreviewTotalLimit)), allowedPreview);
#endif
      dispatch_async(self.queue, ^{
        if (self.previewEpoch != epoch || !self.backgrounded || self.stopping || self.listenerFD < 0 || lease.finished) {
          [lease finish];
          if (self.previewEpoch == epoch && self.backgrounded && !self.stopping) [self stopForPreviewEnd];
          return;
        }
        self.previewLease = lease;
      });
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(allowedPreview * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ expire(NO); });
    });
  });
}

- (void)leavePreviewBackground {
  dispatch_async(self.queue, ^{
    self.backgrounded = NO; ++self.previewEpoch;
    [self.previewLease finish]; self.previewLease = nil;
  });
}

- (NSDictionary *)status {
  __block NSDictionary *value;
  dispatch_sync(self.queue, ^{
    NSString *state = self.starting ? @"starting" : self.stopping ? @"stopping" :
        self.listenerFD >= 0 ? @"running" : @"idle";
    NSMutableDictionary *result = [@{ @"schema_version": @1, @"state": state } mutableCopy];
    if (self.serviceId) result[@"service_id"] = self.serviceId;
    if (self.listenerFD >= 0) result[@"url"] = [NSString stringWithFormat:@"http://127.0.0.1:%d/", [self port]];
    value = [result copy];
  });
  return value;
}

- (void)start:(NSDictionary *)request
       resolve:(RishGuestCgiResolve)resolve
        reject:(RishGuestCgiReject)reject {
  dispatch_async(self.queue, ^{
    if (self.backgrounded || self.starting || self.stopping || self.listenerFD >= 0) {
      reject(kErrorBusy, @"one guest CGI service is already active");
      return;
    }
    NSString *html = [self stringValue:request[@"indexHtml"] maxBytes:kMaxHtmlBytes];
    NSString *script = [self stringValue:request[@"backendScript"] maxBytes:kMaxScriptBytes];
    NSSet *keys = [NSSet setWithArray:request.allKeys];
    NSSet *requiredKeys = [NSSet setWithObjects:@"indexHtml", @"backendScript", nil];
    NSSet *optionalKeys = [NSSet setWithObjects:@"indexHtml", @"backendScript", @"initialData", nil];
    if (!html || !script || !([keys isEqualToSet:requiredKeys] || [keys isEqualToSet:optionalKeys]) ||
        (request[@"initialData"] && ![NSJSONSerialization isValidJSONObject:request[@"initialData"]])) {
      reject(kErrorInvalid, @"indexHtml/backendScript/initialData is invalid or exceeds bounds");
      return;
    }
    NSData *initial = request[@"initialData"]
        ? [NSJSONSerialization dataWithJSONObject:request[@"initialData"] options:0 error:nil]
        : [NSData dataWithBytes:"{}" length:2];
    if (!initial || initial.length > kMaxInitialDataBytes) {
      reject(kErrorInvalid, @"initialData exceeds the bounded JSON size");
      return;
    }
    self.starting = YES;
    self.serviceId = [NSUUID UUID].UUIDString.lowercaseString;
    self.serviceRoot = [NSString stringWithFormat:@"/tmp/rish-cgi/%@", self.serviceId];
    self.indexHtml = html;
    self.backendScript = script;
    self.initialDataPath = [self.serviceRoot stringByAppendingPathComponent:@"initial.json"];
    self.cookieValue = [NSUUID UUID].UUIDString.lowercaseString;
    self.startReject = reject;
    self.startCompletionSent = NO;
    NSUInteger generation = ++self.generation;
    [self bootGuestThenStageHtml:html script:script initial:initial generation:generation resolve:resolve reject:reject];
  });
}

- (void)bootGuestThenStageHtml:(NSString *)html
                         script:(NSString *)script
                         initial:(NSData *)initial
                     generation:(NSUInteger)generation
                          resolve:(RishGuestCgiResolve)resolve
                          reject:(RishGuestCgiReject)reject {
  NSDictionary *boot = @{ @"schema_version": @1, @"memory_mib": @1024 };
  __weak __typeof__(self) weakSelf = self;
  [self.guest bootGuestRequest:boot resolve:^(id result) {
    __typeof__(self) self = weakSelf;
    if (!self) return;
    dispatch_async(self.queue, ^{
      if (generation != self.generation || self.stopping) {
        self.starting = NO;
        self.guestOwned = YES;
        [self completeStopAfterGuestReady];
        return;
      }
      (void)result;
      self.guestOwned = YES;
      __weak __typeof__(self) chainSelf = self;
      [self stageData:[html dataUsingEncoding:NSUTF8StringEncoding]
                  path:[self.serviceRoot stringByAppendingPathComponent:@"www/index.html"]
            executable:NO generation:generation
            completion:^(BOOL ok, NSString *message) {
        __typeof__(self) self = chainSelf;
        if (!self) return;
        if (!ok) { [self failStart:reject message:message generation:generation]; return; }
        __weak __typeof__(self) nextSelf = self;
        [self stageData:[script dataUsingEncoding:NSUTF8StringEncoding]
                    path:[self.serviceRoot stringByAppendingPathComponent:@"backend.sh"]
              executable:YES generation:generation
              completion:^(BOOL ok2, NSString *message2) {
          __typeof__(self) self = nextSelf;
          if (!self) return;
          if (!ok2) { [self failStart:reject message:message2 generation:generation]; return; }
          __weak __typeof__(self) finalSelf = self;
          [self stageData:initial path:self.initialDataPath executable:NO generation:generation completion:^(BOOL ok3, NSString *message3) {
            __typeof__(self) self = finalSelf;
            if (!self) return;
            if (!ok3) { [self failStart:reject message:message3 generation:generation]; return; }
            if (generation != self.generation || self.stopping || ![self openListener]) {
              [self failStart:reject message:@"service stopped before listener startup" generation:generation]; return;
            }
            self.starting = NO;
            self.startCompletionSent = YES;
            self.startReject = nil;
            resolve(@{ @"schema_version": @1, @"service_id": self.serviceId,
                       @"url": [NSString stringWithFormat:@"http://127.0.0.1:%d/", [self port]],
                       @"state": @"running" });
          }];
        }];
      }];
    });
  } reject:^(NSString *code, NSString *message, NSError *error) {
    (void)code; (void)error;
    __typeof__(self) self = weakSelf;
    if (self) dispatch_async(self.queue, ^{
      if (generation != self.generation || self.stopping) {
        self.starting = NO;
        [self completeStopAfterGuestReady];
        return;
      }
      [self failStart:reject message:message generation:generation];
    });
  }];
}

- (void)failStart:(RishGuestCgiReject)reject message:(NSString *)message generation:(NSUInteger)generation {
  if (generation != self.generation) return;
  BOOL shouldShutdown = self.guestOwned;
  NSString *root = self.serviceRoot;
  self.starting = NO;
  self.guestOwned = NO;
  self.serviceId = nil;
  self.serviceRoot = nil;
  self.cookieValue = nil;
  if (!self.startCompletionSent) {
    self.startCompletionSent = YES;
    self.startReject = nil;
    reject(kErrorGuest, message ?: @"guest service start failed");
  }
  if (shouldShutdown) {
    NSString *cleanup = [NSString stringWithFormat:@"rm -rf '%@'", root];
    [self exec:@[@"/bin/sh", @"-c", cleanup] generation:generation allowStaleDuringStop:NO completion:^(BOOL ok, NSString *output) {
      (void)ok; (void)output;
      [self.guest shutdownGuestResolve:^(id result) {
        (void)result; dispatch_async(self.queue, ^{});
      } reject:^(NSString *code, NSString *shutdownMessage, NSError *error) {
        (void)code; (void)shutdownMessage; (void)error; dispatch_async(self.queue, ^{});
      }];
    }];
  }
}

- (void)stageData:(NSData *)data
             path:(NSString *)path
       executable:(BOOL)executable
       generation:(NSUInteger)generation
       completion:(void (^)(BOOL ok, NSString *message))completion {
  NSString *encoded = [data base64EncodedStringWithOptions:0];
  NSString *root = self.serviceRoot;
  NSString *mode = executable ? @"0755" : @"0644";
  if (![self safeGuestPath:path]) {
    completion(NO, @"unsafe staging path");
    return;
  }
  NSString *mkdirCommand = [NSString stringWithFormat:@"mkdir -p '%@/www' && : > '%@.b64.tmp'", root, path];
  __weak __typeof__(self) weakSelf = self;
  [self exec:@[@"/bin/sh", @"-c", mkdirCommand] generation:generation allowStaleDuringStop:NO completion:^(BOOL ok, NSString *message) {
    __typeof__(self) self = weakSelf;
    if (!self || generation != self.generation || self.stopping || !ok) { completion(NO, message ?: @"guest staging mkdir failed"); return; }
    __weak __typeof__(self) appendOwner = self;
    [self appendBase64:encoded offset:0 path:path generation:generation completion:^(BOOL appended, NSString *appendMessage) {
      __typeof__(self) self = appendOwner;
      if (!self) return;
      if (!appended) {
        [self cleanupGuestPaths:@[[path stringByAppendingString:@".tmp"], [path stringByAppendingString:@".b64.tmp"]]
                      generation:generation completion:^{ completion(NO, appendMessage); }];
        return;
      }
      NSString *tmpPath = [path stringByAppendingString:@".tmp"];
      NSString *b64Path = [path stringByAppendingString:@".b64.tmp"];
      NSString *decode = [NSString stringWithFormat:
          @"base64 -d '%@' > '%@' && chmod %@ '%@' && n=$(wc -c < '%@') && h=$(sha256sum '%@' | cut -d ' ' -f1) && test \"$n\" = \"%lu\" && test \"$h\" = \"%@\" && printf '%%s %%s' \"$n\" \"$h\" && mv -f '%@' '%@' && rm -f '%@'",
          b64Path, tmpPath, mode, tmpPath, tmpPath, tmpPath,
          (unsigned long)data.length, [self hexSHA256:data], tmpPath, path, b64Path];
      __weak __typeof__(self) decodeOwner = self;
      [self exec:@[@"/bin/sh", @"-c", decode] generation:generation allowStaleDuringStop:NO completion:^(BOOL decoded, NSString *output) {
        __typeof__(self) self = decodeOwner;
        if (!self) return;
        if (!decoded || generation != self.generation || self.stopping) {
          [self cleanupGuestPaths:@[tmpPath, b64Path] generation:generation completion:^{
            completion(NO, output ?: @"guest staging decode failed");
          }];
          return;
        }
        NSArray<NSString *> *parts = [output componentsSeparatedByString:@" "];
        NSString *expectedHash = [self hexSHA256:data];
        BOOL valid = parts.count == 2 && parts[0].integerValue == (NSInteger)data.length &&
            [parts[1] isEqualToString:expectedHash];
        if (!valid) {
          [self cleanupGuestPaths:@[tmpPath, b64Path] generation:generation completion:^{
            completion(NO, @"guest staged file size/digest mismatch");
          }];
        } else {
          completion(YES, @"");
        }
      }];
    }];
  }];
}

- (void)cleanupGuestPaths:(NSArray<NSString *> *)paths
                generation:(NSUInteger)generation
                completion:(void (^)(void))completion {
  NSMutableArray<NSString *> *safe = [NSMutableArray arrayWithCapacity:paths.count];
  for (NSString *path in paths) if ([self safeGuestPath:path]) [safe addObject:path];
  if (safe.count == 0) { completion(); return; }
  NSMutableString *command = [NSMutableString stringWithString:@"rm -f"];
  for (NSString *path in safe) [command appendFormat:@" '%@'", path];
  [self exec:@[@"/bin/sh", @"-c", command] generation:generation allowStaleDuringStop:NO completion:^(BOOL ok, NSString *output) {
    (void)ok; (void)output; completion();
  }];
}

- (void)appendBase64:(NSString *)encoded
              offset:(NSUInteger)offset
                path:(NSString *)path
          generation:(NSUInteger)generation
          completion:(void (^)(BOOL ok, NSString *message))completion {
  if (offset >= encoded.length) { completion(YES, @""); return; }
  NSUInteger length = MIN(kStageChunkBytes, encoded.length - offset);
  NSString *chunk = [encoded substringWithRange:NSMakeRange(offset, length)];
  NSString *command = [NSString stringWithFormat:@"printf '%%s' '%@' >> '%@.b64.tmp'", chunk, path];
  __weak __typeof__(self) weakSelf = self;
  [self exec:@[@"/bin/sh", @"-c", command] generation:generation allowStaleDuringStop:NO completion:^(BOOL ok, NSString *message) {
    __typeof__(self) self = weakSelf;
    if (!self || !ok) { completion(NO, message ?: @"guest staging chunk failed"); return; }
    __weak __typeof__(self) nextSelf = self;
    [self appendBase64:encoded offset:offset + length path:path generation:generation completion:^(BOOL nextOK, NSString *nextMessage) {
      __typeof__(self) self = nextSelf;
      if (!self) return;
      completion(nextOK, nextMessage);
    }];
  }];
}

- (void)exec:(NSArray<NSString *> *)argv
   generation:(NSUInteger)generation
   allowStaleDuringStop:(BOOL)allowStaleDuringStop
   completion:(void (^)(BOOL ok, NSString *output))completion {
  NSMutableArray *checked = [NSMutableArray arrayWithCapacity:argv.count];
  for (NSString *value in argv) {
    if (![value isKindOfClass:NSString.class] || [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > kMaxCommandArgBytes) {
      completion(NO, @"guest command argument exceeds bound");
      return;
    }
    [checked addObject:value];
  }
  __weak __typeof__(self) weakSelf = self;
  [self.guest guestExecRequest:@{ @"schema_version": @1, @"command": checked }
      resolve:^(id result) {
    __typeof__(self) self = weakSelf;
    if (!self) return;
    NSDictionary *reply = [result isKindOfClass:NSDictionary.class] ? result : nil;
    BOOL ok = reply && [reply[@"ok"] boolValue] && [reply[@"exit_code"] integerValue] == 0;
    NSString *output = [reply[@"stdout"] isKindOfClass:NSString.class] ? reply[@"stdout"] : @"";
    NSString *failure = [reply[@"stderr"] isKindOfClass:NSString.class] ? reply[@"stderr"] : @"guest exec failed";
    dispatch_async(self.queue, ^{
      if (generation != self.generation && !allowStaleDuringStop) return;
      completion(ok, ok ? output : failure);
    });
  } reject:^(NSString *code, NSString *message, NSError *error) {
    (void)code; (void)error;
    __typeof__(self) self = weakSelf;
    if (self) dispatch_async(self.queue, ^{
      if (generation != self.generation && !allowStaleDuringStop) return;
      completion(NO, message ?: @"guest exec failed");
    });
  }];
}

- (void)stop:(NSString *)serviceId resolve:(RishGuestCgiResolve)resolve reject:(RishGuestCgiReject)reject {
  dispatch_async(self.queue, ^{
    if (![serviceId isEqualToString:self.serviceId]) { reject(kErrorInvalid, @"unknown service id"); return; }
    if (self.stopping) { reject(kErrorBusy, @"guest service is already stopping"); return; }
    self.stopping = YES;
    ++self.generation;
    [self closeListener];
    if (!self.startCompletionSent && self.startReject) {
      self.startCompletionSent = YES;
      RishGuestCgiReject startReject = self.startReject;
      self.startReject = nil;
      startReject(@"E_CGI_STOPPING", @"guest service start cancelled");
    }
    self.stopResolve = resolve;
    self.stopReject = reject;
    [self completeStopAfterGuestReady];
  });
}

- (void)completeStopAfterGuestReady {
  if (!self.stopping) return;
  if (self.starting && !self.guestOwned) return;
  if (!self.guestOwned) { [self finishStop:YES message:nil]; return; }
  NSString *root = self.serviceRoot;
  __weak __typeof__(self) weakSelf = self;
  [self exec:@[@"/bin/sh", @"-c", [NSString stringWithFormat:@"rm -rf '%@'", root]] generation:self.generation allowStaleDuringStop:YES completion:^(BOOL ok, NSString *message) {
    __typeof__(self) self = weakSelf;
    if (!self) return;
    [self.guest shutdownGuestResolve:^(id result) {
      (void)result;
      dispatch_async(self.queue, ^{ [self finishStop:ok message:ok ? nil : message]; });
    } reject:^(NSString *code, NSString *shutdownMessage, NSError *error) {
      (void)code; (void)error;
      dispatch_async(self.queue, ^{ [self finishStop:NO message:shutdownMessage ?: @"guest shutdown failed"]; });
    }];
  }];
}

- (void)finishStop:(BOOL)ok message:(NSString *)message {
  if (!self.stopping) return;
  RishGuestCgiResolve resolve = self.stopResolve;
  RishGuestCgiReject reject = self.stopReject;
  self.stopResolve = nil;
  self.stopReject = nil;
  [self.previewLease finish]; self.previewLease = nil;
  ++self.previewEpoch;
  self.stopping = NO; self.starting = NO; self.guestOwned = NO; self.requestBusy = NO;
  self.serviceId = nil; self.serviceRoot = nil; self.initialDataPath = nil; self.cookieValue = nil;
  if (ok) resolve(@{ @"schema_version": @1, @"state": @"stopped" });
  else reject(kErrorGuest, message ?: @"guest service teardown failed");
}

- (BOOL)openListener {
  self.listenerFD = socket(AF_INET, SOCK_STREAM, 0);
  if (self.listenerFD < 0) return NO;
  int yes = 1;
  setsockopt(self.listenerFD, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
#ifdef SO_NOSIGPIPE
  setsockopt(self.listenerFD, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
#endif
  struct sockaddr_in address = {};
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  address.sin_port = htons(0);
  if (bind(self.listenerFD, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(self.listenerFD, 8) != 0) {
    close(self.listenerFD); self.listenerFD = -1; return NO;
  }
  self.listenerSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)self.listenerFD, 0, self.queue);
  __weak __typeof__(self) weakSelf = self;
  dispatch_source_set_event_handler(self.listenerSource, ^{
    __typeof__(self) self = weakSelf;
    if (!self) return;
    int client = accept(self.listenerFD, NULL, NULL);
    if (client >= 0) {
      [self.clients addObject:[NSValue valueWithPointer:(void *)(intptr_t)client]];
      dispatch_async(self.clientQueue, ^{ [self handleClient:client]; });
    }
  });
  dispatch_source_set_cancel_handler(self.listenerSource, ^{});
  dispatch_resume(self.listenerSource);
  return YES;
}

- (int)port {
  if (self.listenerFD < 0) return 0;
  struct sockaddr_in address = {}; socklen_t length = sizeof(address);
  return getsockname(self.listenerFD, (struct sockaddr *)&address, &length) == 0 ? ntohs(address.sin_port) : 0;
}

- (void)closeListener {
  if (self.listenerSource) { dispatch_source_cancel(self.listenerSource); self.listenerSource = nil; }
  if (self.listenerFD >= 0) { close(self.listenerFD); self.listenerFD = -1; }
  for (NSValue *value in [self.clients copy]) {
    int client = (int)(intptr_t)value.pointerValue;
    shutdown(client, SHUT_RDWR);
  }
}

- (void)handleClient:(int)client {
  struct sockaddr_in peer = {}; socklen_t peerLength = sizeof(peer);
  if (getpeername(client, (struct sockaddr *)&peer, &peerLength) != 0 ||
      peer.sin_family != AF_INET || peer.sin_addr.s_addr != htonl(INADDR_LOOPBACK)) {
    [self send:client status:403 type:@"text/plain" body:@"loopback only" headers:nil]; return;
  }
  struct timeval timeout = { .tv_sec = (long)kSocketTimeout, .tv_usec = 0 };
  setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
  setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
#ifdef SO_NOSIGPIPE
  int noSigPipe = 1;
  setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
#endif
  NSMutableData *request = [NSMutableData dataWithCapacity:4096];
  char buffer[4096];
  NSUInteger headerEnd = NSNotFound;
  while (request.length <= RishGuestHttpMaxHeaderBytes && headerEnd == NSNotFound) {
    ssize_t count = recv(client, buffer, sizeof(buffer), 0);
    if (count <= 0) { close(client); return; }
    [request appendBytes:buffer length:(NSUInteger)count];
    const uint8_t *bytes = (const uint8_t *)request.bytes;
    NSUInteger searchLimit = MIN(request.length, RishGuestHttpMaxHeaderBytes);
    for (NSUInteger i = 3; i < searchLimit; i++) if (bytes[i-3] == '\r' && bytes[i-2] == '\n' && bytes[i-1] == '\r' && bytes[i] == '\n') { headerEnd = i + 1; break; }
  }
  RishGuestHttpRequest *parsed = nil; NSString *parseError = nil;
  while (!RishParseGuestHttpRequest(request, &parsed, &parseError) &&
         ([parseError isEqualToString:@"incomplete headers"] || [parseError isEqualToString:@"incomplete body"]) &&
         request.length < RishGuestHttpMaxHeaderBytes + RishGuestHttpMaxBodyBytes) {
    ssize_t count = recv(client, buffer, sizeof(buffer), 0);
    if (count <= 0) break;
    [request appendBytes:buffer length:(NSUInteger)count];
  }
  if (!parsed) {
    int status = [parseError isEqualToString:@"body too large"] ? 413 : 400;
    [self send:client status:status type:@"text/plain" body:parseError ?: @"bad request" headers:nil];
    return;
  }
  __block NSUInteger generation = 0; __block BOOL running = NO; __block NSString *html = nil;
  __block NSString *cookie = nil; __block int port = 0;
  dispatch_sync(self.queue, ^{
    generation = self.generation; running = !self.stopping && !self.starting && self.listenerFD >= 0;
    html = self.indexHtml; cookie = self.cookieValue; port = [self port];
  });
  NSString *expectedHost = [NSString stringWithFormat:@"127.0.0.1:%d", port];
  if (!running || ![parsed.headers[@"host"] isEqualToString:expectedHost]) {
    [self send:client status:421 type:@"text/plain" body:@"host is not this loopback service" headers:nil]; return;
  }
  if ([parsed.method isEqualToString:@"GET"] && [parsed.path isEqualToString:@"/"]) {
    NSString *setCookie = [NSString stringWithFormat:@"rish_cgi=%@; Path=/; HttpOnly; SameSite=Strict", cookie];
    [self send:client status:200 type:@"text/html; charset=utf-8" body:html headers:@{@"Set-Cookie": setCookie}]; return;
  }
  if (![parsed.method isEqualToString:@"POST"] || ![parsed.path isEqualToString:@"/api"]) {
    [self send:client status:404 type:@"text/plain" body:@"not found" headers:nil]; return;
  }
  NSString *expectedOrigin = [NSString stringWithFormat:@"http://%@", expectedHost];
  BOOL originMatches = [parsed.headers[@"origin"] isEqualToString:expectedOrigin];
  BOOL cookiePresent = [parsed.headers[@"cookie"] isKindOfClass:NSString.class] && parsed.headers[@"cookie"].length > 0;
  NSUInteger ownCookieCount = 0;
  BOOL cookieMatches = cookiePresent && RishGuestCgiCookieMatches(parsed.headers[@"cookie"], cookie, &ownCookieCount);
#if DEBUG
  NSLog(@"RishGuestCgi request auth origin_matches=%d cookie_present=%d cookie_matches=%d own_cookie_count=%lu",
        originMatches, cookiePresent, cookieMatches, (unsigned long)ownCookieCount);
#endif
  if (!originMatches || !cookieMatches) {
    [self send:client status:403 type:@"text/plain" body:@"same-origin cookie required" headers:nil]; return;
  }
  dispatch_async(self.queue, ^{
    if (generation != self.generation || self.stopping || self.starting || self.requestBusy) {
      [self send:client status:503 type:@"text/plain" body:@"guest request busy or service stopping" headers:nil]; return;
    }
    self.requestBusy = YES;
    NSString *requestPath = [self.serviceRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"req-%@.body", [NSUUID UUID].UUIDString.lowercaseString]];
    __weak __typeof__(self) requestOwner = self;
    [self stageData:parsed.body path:requestPath executable:NO generation:generation completion:^(BOOL ok, NSString *message) {
      __typeof__(self) self = requestOwner;
      if (!self) return;
      (void)message;
      if (!ok || generation != self.generation || self.stopping) {
        self.requestBusy = NO;
        [self send:client status:503 type:@"text/plain" body:@"guest request stopped or staging failed" headers:nil]; return;
      }
      NSString *script = [self.serviceRoot stringByAppendingPathComponent:@"backend.sh"];
      NSString *command = [NSString stringWithFormat:@"timeout %.0f /bin/sh '%@' '%@' '%@'", kBackendTimeout, script, requestPath, self.initialDataPath];
      __weak __typeof__(self) executionOwner = self;
      [self exec:@[@"/bin/sh", @"-c", command] generation:generation allowStaleDuringStop:NO completion:^(BOOL executed, NSString *output) {
        __typeof__(self) self = executionOwner;
        if (!self) return;
        NSData *json = [output dataUsingEncoding:NSUTF8StringEncoding];
        BOOL valid = executed && output.length <= kMaxResponseBytes && json && [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
        __weak __typeof__(self) cleanupOwner = self;
        [self cleanupGuestPaths:@[requestPath] generation:generation completion:^{
          __typeof__(self) self = cleanupOwner;
          if (!self) return;
          self.requestBusy = NO;
          if (generation != self.generation || self.stopping) {
            [self send:client status:503 type:@"text/plain" body:@"guest request stopped" headers:nil]; return;
          }
          [self send:client status:valid ? 200 : 502 type:@"application/json" body:valid ? output : @"{\"error\":\"guest backend failed, timed out, or returned invalid JSON\"}" headers:nil];
        }];
      }];
    }];
  });
}

- (BOOL)sendAll:(int)client bytes:(const uint8_t *)bytes length:(NSUInteger)length {
  NSUInteger offset = 0;
  while (offset < length) {
    ssize_t sent = send(client, bytes + offset, length - offset,
#ifdef MSG_NOSIGNAL
                        MSG_NOSIGNAL
#else
                        0
#endif
    );
    if (sent <= 0) return NO;
    offset += (NSUInteger)sent;
  }
  return YES;
}

- (void)send:(int)client status:(int)status type:(NSString *)type body:(NSString *)body headers:(NSDictionary<NSString *, NSString *> *)headers {
  NSString *reason = status == 200 ? @"OK" : status == 403 ? @"Forbidden" : status == 404 ? @"Not Found" : status == 413 ? @"Payload Too Large" : status == 421 ? @"Misdirected Request" : status == 502 ? @"Bad Gateway" : status == 503 ? @"Service Unavailable" : @"Bad Request";
  NSData *data = [body dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
  NSMutableString *head = [NSMutableString stringWithFormat:@"HTTP/1.1 %d %@\r\nContent-Type: %@\r\nContent-Length: %lu\r\nConnection: close\r\n", status, reason, type, (unsigned long)data.length];
  [headers enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
    (void)stop; [head appendFormat:@"%@: %@\r\n", key, value];
  }];
  [head appendString:@"\r\n"];
  NSData *headData = [head dataUsingEncoding:NSUTF8StringEncoding];
  [self sendAll:client bytes:(const uint8_t *)headData.bytes length:headData.length];
  if (data.length) [self sendAll:client bytes:(const uint8_t *)data.bytes length:data.length];
  close(client);
  dispatch_async(self.queue, ^{ [self.clients removeObject:[NSValue valueWithPointer:(void *)(intptr_t)client]]; });
}

- (NSString *)stringValue:(id)value maxBytes:(NSUInteger)maxBytes {
  if (![value isKindOfClass:NSString.class] || [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > maxBytes || [value rangeOfString:@"\0"].location != NSNotFound) return nil;
  return value;
}

- (BOOL)safeGuestPath:(NSString *)path {
  return [path hasPrefix:self.serviceRoot] && [path rangeOfString:@".."].location == NSNotFound &&
      [path rangeOfString:@"'"].location == NSNotFound && [path rangeOfString:@"\0"].location == NSNotFound;
}

- (NSString *)hexSHA256:(NSData *)data {
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  NSMutableString *result = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
  for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [result appendFormat:@"%02x", digest[i]];
  return result;
}

- (void)dealloc {
  if (_backgroundObserver) [NSNotificationCenter.defaultCenter removeObserver:_backgroundObserver];
  if (_foregroundObserver) [NSNotificationCenter.defaultCenter removeObserver:_foregroundObserver];
  [_previewLease finish];
  [self closeListener];
  if (_guestOwned && _guest) {
    LocalGuestModule *guest = _guest;
    [guest shutdownGuestResolve:^(id result) { (void)result; }
        reject:^(NSString *code, NSString *message, NSError *error) {
      (void)code; (void)message; (void)error;
    }];
  }
}

@end
