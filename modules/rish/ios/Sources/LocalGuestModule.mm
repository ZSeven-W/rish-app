#import "LocalGuestModule.h"
#import "DSHGuestRuntimeState.h"

#import <Foundation/Foundation.h>
#import <RishNative/RishNativeModule.h>

#import <CommonCrypto/CommonDigest.h>
#include <math.h>

#include "rish.h"

// This preview surface uses the bundled offline initramfs and omits network
// and root_disk_path (the FFI creates its scratch disk). Language programs use
// a separate disk/network configuration, with the same process-wide VM owner.

NSString *const DSHGuestKernelResourceName = @"vmlinuz-virt-6.18.35";
NSString *const DSHGuestInitramfsResourceName = @"rish-container.cpio";
NSString *const DSHGuestKernelSha256 =
    @"1e6bf9027720c75c3ed0d79171f21b5791ee40ca9795d07c7c6e04dc5ea2ae90";
NSString *const DSHGuestInitramfsSha256 =
    @"17923f268be4e0b6fbfa6d0410094fb9b9d216e69fd4341ffbb839ec592926b0";

NSString *const DSHGuestErrorInvalidRequest = @"E_GUEST_INVALID_REQUEST";
NSString *const DSHGuestErrorAssetsMissing = @"E_GUEST_ASSETS_MISSING";
NSString *const DSHGuestErrorAssetIntegrity = @"E_GUEST_ASSET_INTEGRITY";
NSString *const DSHGuestErrorBootInProgress = @"E_GUEST_BOOT_IN_PROGRESS";
NSString *const DSHGuestErrorAlreadyBooted = @"E_GUEST_ALREADY_BOOTED";
NSString *const DSHGuestErrorNotBooted = @"E_GUEST_NOT_BOOTED";
NSString *const DSHGuestErrorBootFailed = @"E_GUEST_BOOT_FAILED";
NSString *const DSHGuestErrorBootCancelled = @"E_GUEST_BOOT_CANCELLED";
NSString *const DSHGuestErrorExecFailed = @"E_GUEST_EXEC_FAILED";
NSString *const DSHGuestErrorUnavailable = @"E_GUEST_UNAVAILABLE";

static NSUInteger const DSHGuestMaximumCommandArgs = 64;
static NSUInteger const DSHGuestMaximumArgBytes = 4096;
static NSUInteger const DSHGuestMaximumCommandBytes = 65536;
static NSUInteger const DSHGuestMaximumStreamBytes = 1024 * 1024;
static uint64_t const DSHGuestMinimumMemoryMib = 256;
static uint64_t const DSHGuestMaximumMemoryMib = 4096;
static uint64_t const DSHGuestBootBudgetUnits = 80000000000ULL;
static uint64_t const DSHGuestHandshakeBudgetUnits = 80000000000ULL;

// Fixed, known-good kernel command line for the baked container initramfs.
static NSString *const DSHGuestCommandLine =
    @"console=ttyS0,115200n8 rdinit=/init panic=-1 oops=panic nokaslr "
    @"cgroup_no_v1=all 8250.nr_uarts=1";

typedef NS_ENUM(NSUInteger, DSHGuestSessionState) {
  DSHGuestSessionStateIdle = 0,
  DSHGuestSessionStateBooting,
  DSHGuestSessionStateBooted,
};

static NSString *DSHGuestHexSHA256(NSData *data) {
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  NSMutableString *hex =
      [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
  for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index += 1) {
    [hex appendFormat:@"%02x", digest[index]];
  }
  return hex;
}

static NSString *DSHGuestHexSHA256OfFile(NSURL *url) {
  NSData *data = [NSData dataWithContentsOfURL:url
                                       options:NSDataReadingMappedIfSafe
                                         error:nil];
  return data == nil ? nil : DSHGuestHexSHA256(data);
}

static BOOL DSHGuestSchemaVersionIsOne(id value) {
  return [value isKindOfClass:NSNumber.class] &&
         CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
         [value isEqual:@1];
}

static BOOL DSHGuestBoundedInteger(id value, uint64_t minimum, uint64_t maximum,
                                   uint64_t *output) {
  if (![value isKindOfClass:NSNumber.class] ||
      CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
    return NO;
  }
  NSNumber *number = value;
  double floating = number.doubleValue;
  uint64_t integer = number.unsignedLongLongValue;
  if (!isfinite(floating) || floating < 0 || floating != (double)integer ||
      integer < minimum || integer > maximum) {
    return NO;
  }
  if (output != nil) *output = integer;
  return YES;
}

static BOOL DSHGuestExactKeys(NSDictionary *value, NSArray<NSString *> *keys) {
  return [value isKindOfClass:NSDictionary.class] && value.count == keys.count &&
         [[NSSet setWithArray:value.allKeys] isEqualToSet:[NSSet setWithArray:keys]];
}

// Validates a command argv before anything reaches the FFI: bounded count,
// bounded byte sizes, strings only, and no embedded NULs.
static NSArray<NSString *> *DSHGuestValidatedCommand(id value) {
  NSArray *entries = [value isKindOfClass:NSArray.class] ? value : nil;
  if (entries == nil || entries.count == 0 ||
      entries.count > DSHGuestMaximumCommandArgs) {
    return nil;
  }
  NSMutableArray<NSString *> *command = [NSMutableArray arrayWithCapacity:entries.count];
  NSUInteger totalBytes = 0;
  for (id entry in entries) {
    if (![entry isKindOfClass:NSString.class]) return nil;
    NSString *argument = entry;
    NSUInteger bytes = [argument lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (argument.length == 0 || bytes > DSHGuestMaximumArgBytes ||
        [argument rangeOfString:@"\0"].location != NSNotFound ||
        bytes > DSHGuestMaximumCommandBytes - totalBytes) {
      return nil;
    }
    totalBytes += bytes;
    [command addObject:argument];
  }
  return command;
}

static const void *const DSHGuestStateQueueKey = &DSHGuestStateQueueKey;

@interface LocalGuestModule () <RishNativeModule>
@property(nonatomic, strong) dispatch_queue_t stateQueue;
@property(nonatomic, strong) dispatch_queue_t bootQueue;
@property(nonatomic, assign) DSHGuestSessionState sessionState;
@property(nonatomic, assign) void *session;
@property(nonatomic, assign) BOOL shutdownRequested;
@property(nonatomic, strong, nullable) DSHGuestVMOwner *vmOwner;
@property(nonatomic, copy, nullable) NSURL *resolvedKernelURL;
@property(nonatomic, copy, nullable) NSURL *resolvedInitramfsURL;
@end

@implementation LocalGuestModule

RISH_NATIVE_MODULE(LocalGuest)

+ (BOOL)requiresMainQueueSetup {
  return NO;
}

- (instancetype)init {
  return [self initWithBundle:NSBundle.mainBundle];
}

- (instancetype)initWithBundle:(NSBundle *)bundle {
  self = [super init];
  if (self != nil) {
    _stateQueue = dispatch_queue_create("tech.zseven.rish.local-guest",
                                        DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(_stateQueue, DSHGuestStateQueueKey,
                                (void *)DSHGuestStateQueueKey, NULL);
    _bootQueue = dispatch_queue_create(
        "tech.zseven.rish.local-guest-boot",
        dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    _sessionState = DSHGuestSessionStateIdle;
    _session = NULL;
    _shutdownRequested = NO;
    if (bundle != nil) {
      _resolvedKernelURL = [bundle URLForResource:DSHGuestKernelResourceName
                                       withExtension:nil];
      _resolvedInitramfsURL =
          [bundle URLForResource:DSHGuestInitramfsResourceName
                     withExtension:nil];
    }
  }
  return self;
}

- (NSURL *)kernelURL {
  return self.resolvedKernelURL;
}

- (NSURL *)initramfsURL {
  return self.resolvedInitramfsURL;
}

// Native-only seams permit lifecycle/concurrency tests to hold boot without
// allocating a second VM. Production always verifies the pinned bundle.
- (NSString *)bootAssetErrorCode {
  if (self.resolvedKernelURL == nil || self.resolvedInitramfsURL == nil) return DSHGuestErrorAssetsMissing;
  if (![DSHGuestHexSHA256OfFile(self.resolvedKernelURL) isEqual:DSHGuestKernelSha256] ||
      ![DSHGuestHexSHA256OfFile(self.resolvedInitramfsURL) isEqual:DSHGuestInitramfsSha256])
    return DSHGuestErrorAssetIntegrity;
  return nil;
}
- (void *)bootSessionData:(NSData *)encoded {
  return rish_vm_boot_session(static_cast<const char *>(encoded.bytes), encoded.length);
}
- (void)freeSessionHandle:(void *)handle { rish_vm_session_free(handle); }

// Runs only on the state queue. Releases the live session exactly once and
// clears the shared mounted flag.
- (void)releaseSessionLocked {
  if (self.session != NULL) {
    [self freeSessionHandle:self.session];
    self.session = NULL;
  }
  if (self.vmOwner) [DSHGuestRuntimeState.sharedState releaseGuestOwner:self.vmOwner];
  self.vmOwner = nil;
}

- (void)reject:(void (^)(NSString *, NSString *, NSError *))reject
          code:(NSString *)code
       message:(NSString *)message {
  reject(code, message, nil);
}

- (void)bootGuestRequest:(NSDictionary *)request
                 resolve:(void (^)(id result))resolve
                  reject:(void (^)(NSString *, NSString *, NSError *))reject {
  dispatch_async(self.stateQueue, ^{
    uint64_t memoryMib = 0;
    if (!DSHGuestExactKeys(request, @[ @"schema_version", @"memory_mib" ]) ||
        !DSHGuestSchemaVersionIsOne(request[@"schema_version"]) ||
        !DSHGuestBoundedInteger(request[@"memory_mib"],
                                DSHGuestMinimumMemoryMib,
                                DSHGuestMaximumMemoryMib, &memoryMib)) {
      [self reject:reject code:DSHGuestErrorInvalidRequest
           message:@"Guest boot request is invalid."];
      return;
    }
    if (self.sessionState != DSHGuestSessionStateIdle) {
      [self reject:reject
           code:self.sessionState == DSHGuestSessionStateBooting
                    ? DSHGuestErrorBootInProgress
                    : DSHGuestErrorAlreadyBooted
           message:@"A guest session is already active."];
      return;
    }
    self.vmOwner = [DSHGuestRuntimeState.sharedState acquireGuestOwner];
    if (self.vmOwner == nil) {
      [self reject:reject code:@"E_GUEST_BUSY"
           message:@"Another guest is starting or running. Stop it before starting this guest."];
      return;
    }
    NSString *assetError = [self bootAssetErrorCode];
    if (assetError != nil) {
      [self releaseSessionLocked];
      [self reject:reject code:assetError message:@"Guest boot assets are missing or failed verification."];
      return;
    }

    self.sessionState = DSHGuestSessionStateBooting;
    self.shutdownRequested = NO;
    NSString *kernelPath = self.resolvedKernelURL.path;
    NSString *initramfsPath = self.resolvedInitramfsURL.path;
    NSDictionary *envelope = @{
      @"kernel_path" : kernelPath,
      @"initrd_path" : initramfsPath,
      // vm_boot_session ignores the command field, but the Rust request
      // struct requires it — an empty argv satisfies the decoder.
      @"command" : @[],
      @"memory_mib" : @(memoryMib),
      @"command_line" : DSHGuestCommandLine,
      @"boot_budget_units" : @(DSHGuestBootBudgetUnits),
      @"handshake_budget_units" : @(DSHGuestHandshakeBudgetUnits),
    };
    NSError *error = nil;
    NSData *encoded = [NSJSONSerialization dataWithJSONObject:envelope
                                                       options:0
                                                         error:&error];
    if (encoded == nil) {
      [self releaseSessionLocked];
      self.sessionState = DSHGuestSessionStateIdle;
      [self reject:reject code:DSHGuestErrorInvalidRequest
           message:@"Guest boot request could not be encoded."];
      return;
    }

    // The interpreter boots a Linux guest: blocking and slow (~40 s). It must
    // never run on the state queue or the main thread. The block keeps a
    // strong reference to self so a boot in flight survives until it commits
    // or is cancelled.
    dispatch_async(self.bootQueue, ^{
      CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
      void *handle = NULL;
      @try { handle = [self bootSessionData:encoded]; }
      @catch (__unused NSException *exception) { handle = NULL; }
      NSTimeInterval bootMilliseconds =
          (CFAbsoluteTimeGetCurrent() - started) * 1000.0;
      dispatch_async(self.stateQueue, ^{
        if (handle == NULL) {
          [self releaseSessionLocked];
          self.sessionState = DSHGuestSessionStateIdle;
          [self reject:reject code:DSHGuestErrorBootFailed
               message:@"The guest failed to boot."];
          return;
        }
        if (self.shutdownRequested) {
          [self freeSessionHandle:handle];
          [self releaseSessionLocked];
          self.sessionState = DSHGuestSessionStateIdle;
          self.shutdownRequested = NO;
          [self reject:reject code:DSHGuestErrorBootCancelled
               message:@"Guest boot was cancelled by shutdown."];
          return;
        }
        self.session = handle;
        self.sessionState = DSHGuestSessionStateBooted;
        [DSHGuestRuntimeState.sharedState setGuestRuntimeMounted:YES owner:self.vmOwner];
        resolve(@{
          @"schema_version" : @1,
          @"status" : @"booted",
          @"boot_ms" : @((uint64_t)llround(bootMilliseconds)),
          @"memory_mib" : @(memoryMib),
          @"kernel" : DSHGuestKernelResourceName,
          @"initramfs" : DSHGuestInitramfsResourceName,
          @"kernel_sha256" : DSHGuestKernelSha256,
          @"initramfs_sha256" : DSHGuestInitramfsSha256,
        });
      });
    });
  });
}

- (void)guestExecRequest:(NSDictionary *)request
                 resolve:(void (^)(id result))resolve
                  reject:(void (^)(NSString *, NSString *, NSError *))reject {
  dispatch_async(self.stateQueue, ^{
    // Validate the request before consulting session state: invalid input
    // is rejected fail-closed regardless of what the session is doing.
    if (!DSHGuestExactKeys(request, @[ @"schema_version", @"command" ]) ||
        !DSHGuestSchemaVersionIsOne(request[@"schema_version"])) {
      [self reject:reject code:DSHGuestErrorInvalidRequest
           message:@"Guest exec request is invalid."];
      return;
    }
    NSArray<NSString *> *command = DSHGuestValidatedCommand(request[@"command"]);
    if (command == nil) {
      [self reject:reject code:DSHGuestErrorInvalidRequest
           message:@"Guest exec command is invalid."];
      return;
    }
    if (self.sessionState == DSHGuestSessionStateIdle) {
      [self reject:reject code:DSHGuestErrorNotBooted
           message:@"The guest is not booted."];
      return;
    }
    if (self.sessionState == DSHGuestSessionStateBooting) {
      [self reject:reject code:DSHGuestErrorBootInProgress
           message:@"The guest is still booting."];
      return;
    }
    if (self.session == NULL) {
      [self reject:reject code:DSHGuestErrorUnavailable
           message:@"The guest session handle is unavailable."];
      return;
    }

    NSError *error = nil;
    NSData *encoded =
        [NSJSONSerialization dataWithJSONObject:@{ @"command" : command }
                                        options:0
                                          error:&error];
    if (encoded == nil) {
      [self reject:reject code:DSHGuestErrorInvalidRequest
           message:@"Guest exec request could not be encoded."];
      return;
    }
    // Executes on the state queue so shutdown can never free the handle
    // mid-command: every state mutation is serialized behind this call.
    char *raw = rish_vm_session_exec_json(
        self.session, static_cast<const char *>(encoded.bytes), encoded.length);
    if (raw == NULL) {
      [self reject:reject code:DSHGuestErrorExecFailed
           message:@"The guest exec bridge returned no response."];
      return;
    }
    NSString *responseText = [NSString stringWithUTF8String:raw];
    rish_string_free(raw);
    NSDictionary *response = nil;
    if (responseText != nil) {
      response = [NSJSONSerialization
          JSONObjectWithData:[responseText dataUsingEncoding:NSUTF8StringEncoding]
                     options:0
                       error:nil];
    }
    if (![response isKindOfClass:NSDictionary.class]) {
      [self reject:reject code:DSHGuestErrorExecFailed
           message:@"The guest exec reply is invalid."];
      return;
    }
    BOOL ok = [response[@"ok"] boolValue];
    NSNumber *exitCode = [response[@"exit_code"] isKindOfClass:NSNumber.class]
        ? response[@"exit_code"]
        : nil;
    if (!ok && exitCode == nil) {
      NSString *detail = [response[@"error"] isKindOfClass:NSString.class]
          ? response[@"error"]
          : @"The guest command failed.";
      [self reject:reject code:DSHGuestErrorExecFailed message:detail];
      return;
    }
    NSString *stdoutText = [response[@"stdout"] isKindOfClass:NSString.class]
        ? response[@"stdout"]
        : @"";
    NSString *stderrText = [response[@"stderr"] isKindOfClass:NSString.class]
        ? response[@"stderr"]
        : @"";
    BOOL stdoutTruncated = stdoutText.length > DSHGuestMaximumStreamBytes;
    BOOL stderrTruncated = stderrText.length > DSHGuestMaximumStreamBytes;
    if (stdoutTruncated) {
      stdoutText = [stdoutText substringToIndex:DSHGuestMaximumStreamBytes];
    }
    if (stderrTruncated) {
      stderrText = [stderrText substringToIndex:DSHGuestMaximumStreamBytes];
    }
    NSMutableDictionary *receipt = [@{
      @"schema_version" : @1,
      @"ok" : @(ok),
      @"exit_code" : exitCode ?: @(0),
      @"stdout" : stdoutText,
      @"stderr" : stderrText,
      @"stdout_truncated" : @(stdoutTruncated),
      @"stderr_truncated" : @(stderrTruncated),
    } mutableCopy];
    if ([response[@"boot_units"] isKindOfClass:NSNumber.class]) {
      receipt[@"boot_units"] = response[@"boot_units"];
    }
    resolve(receipt);
  });
}

- (void)shutdownGuestResolve:(void (^)(id result))resolve
                      reject:(void (^)(NSString *, NSString *, NSError *))reject {
  (void)reject;
  dispatch_async(self.stateQueue, ^{
    switch (self.sessionState) {
      case DSHGuestSessionStateIdle:
        resolve(@{ @"schema_version" : @1, @"status" : @"already_idle" });
        return;
      case DSHGuestSessionStateBooting:
        // The boot worker will free the handle the moment it completes and
        // the boot promise rejects with E_GUEST_BOOT_CANCELLED.
        self.shutdownRequested = YES;
        resolve(@{ @"schema_version" : @1, @"status" : @"shutdown_scheduled" });
        return;
      case DSHGuestSessionStateBooted:
        [self releaseSessionLocked];
        self.sessionState = DSHGuestSessionStateIdle;
        resolve(@{ @"schema_version" : @1, @"status" : @"shutdown" });
        return;
    }
  });
}

- (void)dealloc {
  // The boot worker holds a strong reference while a boot is in flight, so
  // dealloc can only run when no boot is pending. Freeing here also covers
  // bridge teardown while a session is live. The queue-specific guard avoids
  // a dispatch_sync self-deadlock in the edge case where the last strong
  // reference drops from a block already running on the state queue.
  if (self.stateQueue == nil) return;
  if (dispatch_get_specific(DSHGuestStateQueueKey) != NULL) {
    [self releaseSessionLocked];
    self.sessionState = DSHGuestSessionStateIdle;
    return;
  }
  dispatch_sync(self.stateQueue, ^{
    [self releaseSessionLocked];
    self.sessionState = DSHGuestSessionStateIdle;
  });
}

RISH_NATIVE_METHOD(bootGuest,
                 bootGuestRequest:(NSDictionary *)request
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  [self bootGuestRequest:request resolve:resolve reject:reject];
}

RISH_NATIVE_METHOD(guestExec,
                 guestExecRequest:(NSDictionary *)request
                 resolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  [self guestExecRequest:request resolve:resolve reject:reject];
}

RISH_NATIVE_METHOD(shutdownGuest,
                 shutdownGuestWithResolver:(RishResolveBlock)resolve
                 rejecter:(RishRejectBlock)reject) {
  [self shutdownGuestResolve:resolve reject:reject];
}

@end
