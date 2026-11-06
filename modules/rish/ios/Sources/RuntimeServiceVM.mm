#import "RuntimeServiceVM.h"
#import "RuntimeEnvironmentStore.h"
#import "RuntimeWorkspaceSnapshot.h"
#include "rish.h"

const NSUInteger DSHRuntimeServiceMaxRequestBytes = 96 * 1024;
const NSUInteger DSHRuntimeServiceMaxResponseBytes = 1024 * 1024;
static const NSUInteger LogLimit = 256 * 1024;
static const NSUInteger ChunkBytes = 2250;
static const NSUInteger QueueLimit = 8;
static const NSTimeInterval RequestSeconds = 30;
// Supervision runs a tiny shell command, but the guest is an emulated x86 core.
// A program that compiles or warms up saturates that core, and a spawn that
// costs milliseconds natively can then cost seconds. This bounds a wedged
// guest; it is not a health signal, so it stays far above the honest cost.
static const NSTimeInterval SuperviseSeconds = 45;

@interface DSHRuntimeServiceRequest : NSObject
@property(nonatomic, copy) NSData *request;
@property(nonatomic, copy) DSHRuntimeServiceHTTPCompletion completion;
@property(nonatomic) NSTimeInterval deadline;
@end
@implementation DSHRuntimeServiceRequest
@end

@interface DSHRuntimeServiceVM ()
@property(nonatomic, strong) NSCondition *condition;
@property(nonatomic, strong) NSMutableArray<DSHRuntimeServiceRequest *> *requests;
@property(nonatomic) BOOL serving;
@property(nonatomic) BOOL used;
@end

static void RawOutput(void *context, const char *bytes, size_t length) {
  if (!context || !bytes || length == 0 || length > 12 * 1024 * 1024) return;
  @autoreleasepool {
    id event = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes length:length] options:0 error:nil];
    if (![event isKindOfClass:NSDictionary.class] || ![event[@"protocol_version"] isEqual:@1] ||
        ![event[@"event"] isEqual:@"output"] || ![event[@"data_base64"] isKindOfClass:NSString.class]) return;
    if (![@[@"stdout", @"stderr"] containsObject:event[@"channel"]]) return;
    NSData *data = [[NSData alloc] initWithBase64EncodedString:event[@"data_base64"] options:0];
    if (data) ((__bridge DSHRuntimeProgramOutput)context)(event[@"channel"], data);
  }
}

static NSTimeInterval Now(void) { return NSProcessInfo.processInfo.systemUptime; }
static BOOL Fail(NSError **error, NSString *code) {
  if (error) *error = DSHRuntimeProgramError(code);
  return NO;
}

static BOOL LooksLikeHTTP(NSData *bytes) {
  if (bytes.length < 12) return NO;
  const char *raw = (const char *)bytes.bytes;
  return (!memcmp(raw, "HTTP/1.1 ", 9) || !memcmp(raw, "HTTP/1.0 ", 9)) &&
      raw[9] >= '1' && raw[9] <= '5' && raw[10] >= '0' && raw[10] <= '9' && raw[11] >= '0' && raw[11] <= '9';
}

static BOOL ValidArgs(id value) {
  if (![value isKindOfClass:NSArray.class] || [value count] > 64) return NO;
  NSUInteger total = 0;
  for (id item in value) {
    if (![item isKindOfClass:NSString.class] || [item containsString:@"\0"]) return NO;
    NSData *bytes = [item dataUsingEncoding:NSUTF8StringEncoding];
    if (!bytes || bytes.length > 4096 || bytes.length > 65536 - total) return NO;
    total += bytes.length;
  }
  return YES;
}

@implementation DSHRuntimeServiceVM
- (instancetype)initWithBundle:(NSBundle *)bundle {
  self = [super initWithBundle:bundle];
  if (self) { _condition = [[NSCondition alloc] init]; _requests = [NSMutableArray array]; }
  return self;
}
- (void)cancel {
  [super cancel];
  [self.condition lock]; [self.condition broadcast]; [self.condition unlock];
}
- (void)requestHTTP:(NSData *)request completion:(DSHRuntimeServiceHTTPCompletion)completion {
  if (!completion) return;
  if (![request isKindOfClass:NSData.class] || request.length == 0 || request.length > DSHRuntimeServiceMaxRequestBytes) {
    completion(nil, DSHRuntimeProgramError(@"E_PROGRAM_INVALID_REQUEST")); return;
  }
  [self.condition lock];
  BOOL accepted = self.serving && !self.cancelled && self.requests.count < QueueLimit;
  if (accepted) {
    DSHRuntimeServiceRequest *item = [[DSHRuntimeServiceRequest alloc] init];
    item.request = request; item.completion = completion; item.deadline = Now() + RequestSeconds;
    [self.requests addObject:item]; [self.condition signal];
  }
  [self.condition unlock];
  if (!accepted) completion(nil, DSHRuntimeProgramError(@"E_PROGRAM_BUSY"));
}

/// Native-only test seam; production always uses the streaming C ABI. Never
/// reconstruct HTTP bytes from the lossy stdout string in its final JSON.
- (NSDictionary *)executeSession:(void *)session command:(NSArray *)command
                         deadline:(NSTimeInterval)deadline limit:(NSUInteger)limit
                           stdout:(NSData **)stdoutData error:(NSError **)error {
  NSTimeInterval remaining = deadline - Now();
  if (remaining <= 0 || self.cancelled) { Fail(error, @"E_PROGRAM_TIMEOUT"); return nil; }
  NSMutableData *captured = [NSMutableData data];
  __block BOOL exceeded = NO;
  DSHRuntimeProgramOutput output = ^(NSString *channel, NSData *data) {
    if (![channel isEqual:@"stdout"]) return;
    NSUInteger accepted = MIN(data.length, limit - captured.length);
    [captured appendBytes:data.bytes length:accepted];
    if (accepted != data.length) exceeded = YES;
  };
  NSData *json = [NSJSONSerialization dataWithJSONObject:@{
    @"protocol_version":@2, @"command":command, @"cwd":@"/",
    @"timeout_ms":@(MAX(1ULL, (uint64_t)(remaining * 1000))), @"max_output_bytes":@(limit),
    @"env":@{@"HOME":@"/tmp/rish-home", @"PATH":@"/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
             @"TMPDIR":@"/tmp", @"GOCACHE":@"/tmp/go-build", @"CARGO_HOME":@"/tmp/cargo"},
  } options:0 error:nil];
  char *raw = json ? rish_vm_session_exec_stream_json(session, (const char *)json.bytes, json.length,
      (__bridge void *)output, RawOutput) : NULL;
  NSDictionary *reply = nil;
  if (raw) {
    NSUInteger count = strnlen(raw, 8 * 1024 * 1024 + 1);
    id value = count <= 8 * 1024 * 1024 ? [NSJSONSerialization JSONObjectWithData:
        [NSData dataWithBytes:raw length:count] options:0 error:nil] : nil;
    if ([value isKindOfClass:NSDictionary.class]) reply = value;
    rish_string_free(raw);
  }
  if (stdoutData) *stdoutData = [captured copy];
  NSString *failure = [reply[@"error"] isKindOfClass:NSString.class] ? reply[@"error"] : @"";
  if (exceeded || [failure containsString:@"E_VM_OUTPUT_LIMIT"]) {
    Fail(error, @"E_PROGRAM_OUTPUT_LIMIT"); return nil;
  }
  if (![reply[@"exit_code"] isKindOfClass:NSNumber.class]) {
    Fail(error, [failure containsString:@"E_VM_TIMEOUT"] ? @"E_PROGRAM_TIMEOUT" : @"E_PROGRAM_EXEC");
    return nil;
  }
  return reply;
}

- (BOOL)stageData:(NSData *)data path:(NSString *)path session:(void *)session
          deadline:(NSTimeInterval)deadline error:(NSError **)error {
  NSDictionary *reply = [self executeSession:session command:@[@"/bin/sh", @"-c", @": > \"$1\"", @"sh", path]
      deadline:deadline limit:4096 stdout:nil error:error];
  if (!reply) return NO;
  if ([reply[@"exit_code"] integerValue] != 0) return Fail(error, @"E_PROGRAM_EXEC");
  for (NSUInteger offset = 0; offset < data.length; offset += ChunkBytes) {
    NSData *chunk = [data subdataWithRange:NSMakeRange(offset, MIN(ChunkBytes, data.length - offset))];
    NSString *encoded = [chunk base64EncodedStringWithOptions:0];
    reply = [self executeSession:session command:@[@"/bin/sh", @"-c",
        @"printf '%s' \"$2\" | /bin/busybox base64 -d >> \"$1\"", @"sh", path, encoded]
        deadline:deadline limit:4096 stdout:nil error:error];
    if (!reply) return NO;
    if ([reply[@"exit_code"] integerValue] != 0) return Fail(error, @"E_PROGRAM_EXEC");
  }
  return YES;
}
- (NSData *)forwardRequest:(NSData *)request path:(NSString *)path port:(NSUInteger)port
                    session:(void *)session deadline:(NSTimeInterval)deadline error:(NSError **)error {
  if (![self stageData:request path:path session:session deadline:deadline error:error]) return nil;
  return [self forwardStagedRequestAtPath:path port:port session:session deadline:deadline error:error];
}
- (NSData *)forwardStagedRequestAtPath:(NSString *)path port:(NSUInteger)port
                    session:(void *)session deadline:(NSTimeInterval)deadline error:(NSError **)error {
  NSData *response = nil;
  // No guest-clock -w or timeout applet: the FFI host monotonic deadline
  // bounds the whole request, including staging and reading until TCP EOF.
  NSDictionary *reply = [self executeSession:session command:@[@"/bin/sh", @"-c",
      @"exec /bin/busybox nc 127.0.0.1 \"$1\" < \"$2\"", @"sh", @(port).stringValue, path]
      deadline:deadline limit:DSHRuntimeServiceMaxResponseBytes stdout:&response error:error];
  if (!reply) return nil;
  if ([reply[@"exit_code"] integerValue] != 0 || !LooksLikeHTTP(response)) {
    Fail(error, @"E_PROGRAM_EXEC"); return nil;
  }
  return response;
}

- (BOOL)launchSession:(void *)session command:(NSArray *)command root:(NSString *)root
                 port:(NSUInteger)port error:(NSError **)error {
  // Each detached process writes its PID only after setsid succeeded. The
  // supervisor kills the original shell's group on exit; this handshake is
  // essential. VM teardown, not a caller-supplied PID, owns these descendants.
  NSString *script = @"set -eu; root=$1; shift; mkdir -m 700 \"$root\"; "
      "mkfifo \"$root/out.pipe\" \"$root/err.pipe\"; "
      "for ch in out err; do "
      "/bin/busybox setsid /bin/sh -c 'printf \"%s\\n\" \"$$\" > \"$1\"; "
      "head -c 262144 > \"$2\"; cat > /dev/null' sh \"$root/$ch.pid\" \"$root/$ch.log\" < \"$root/$ch.pipe\" & "
      "done; "
      "/bin/busybox setsid /bin/sh -c 'root=$1; shift; printf \"%s\\n\" \"$$\" > \"$root/server.pid\"; "
      "\"$@\"; status=$?; printf \"%s\\n\" \"$status\" > \"$root/exit\"; exit \"$status\"' "
      "sh \"$root\" \"$@\" < /dev/null > \"$root/out.pipe\" 2> \"$root/err.pipe\" & "
      "while ! test -s \"$root/server.pid\" || ! test -s \"$root/out.pid\" || ! test -s \"$root/err.pid\"; do sleep 0.01; done";
  NSMutableArray *argv = [NSMutableArray arrayWithArray:@[@"/bin/sh", @"-c", script, @"sh", root]];
  [argv addObjectsFromArray:@[@"/bin/busybox", @"env", [@"PORT=" stringByAppendingString:@(port).stringValue], @"HOST=127.0.0.1"]];
  [argv addObjectsFromArray:command];
  NSDictionary *reply = [self executeSession:session command:argv deadline:Now() + SuperviseSeconds
      limit:4096 stdout:nil error:error];
  if (!reply) return NO;
  return [reply[@"exit_code"] integerValue] == 0 ? YES : Fail(error, @"E_PROGRAM_EXEC");
}

- (NSNumber *)exitStatus:(NSString *)root session:(void *)session error:(NSError **)error {
  NSData *bytes = nil;
  NSDictionary *reply = [self executeSession:session command:@[@"/bin/sh", @"-c",
      @"if test -s \"$1/exit\"; then cat \"$1/exit\"; else "
      "pid=$(cat \"$1/server.pid\"); case \"$pid\" in ''|*[!0-9]*) exit 4;; esac; "
      "state=; if test -r \"/proc/$pid/status\"; then "
      "while read -r key value rest; do test \"$key\" != State: || state=$value; done < \"/proc/$pid/status\"; fi; "
      "case \"$state\" in ''|Z|X) printf '255';; *) printf 'running';; esac; fi", @"sh", root]
      deadline:Now() + SuperviseSeconds limit:4096 stdout:&bytes error:error];
  if (!reply) return nil;
  if ([reply[@"exit_code"] integerValue] != 0) { Fail(error, @"E_PROGRAM_EXEC"); return nil; }
  NSString *value = [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
  if ([value isEqual:@"running"]) return nil;
  NSScanner *scanner = [NSScanner scannerWithString:value ?: @""];
  int status = 0;
  if (![scanner scanInt:&status] || !scanner.isAtEnd || status < 0 || status > 255) {
    Fail(error, @"E_PROGRAM_EXEC"); return nil;
  }
  return @(status);
}
- (BOOL)readLogs:(NSString *)root session:(void *)session offsets:(NSMutableDictionary *)offsets
          output:(DSHRuntimeProgramOutput)output error:(NSError **)error {
  for (NSString *name in @[@"out", @"err"]) {
    NSUInteger offset = [offsets[name] unsignedIntegerValue];
    if (offset >= LogLimit) continue;
    NSData *data = nil;
    NSDictionary *reply = [self executeSession:session command:@[@"/bin/sh", @"-c",
        @"if test -f \"$1\"; then tail -c \"+$2\" \"$1\"; fi", @"sh",
        [root stringByAppendingFormat:@"/%@.log", name], @(offset + 1).stringValue]
        deadline:Now() + SuperviseSeconds limit:LogLimit stdout:&data error:error];
    if (!reply) return NO;
    if ([reply[@"exit_code"] integerValue] != 0) return Fail(error, @"E_PROGRAM_EXEC");
    offsets[name] = @(offset + data.length);
    if (data.length) output([name isEqual:@"out"] ? @"stdout" : @"stderr", data);
  }
  return YES;
}

- (NSNumber *)serveLease:(DSHRuntimeEnvironmentLease *)lease snapshot:(DSHRuntimeWorkspaceSnapshot *)snapshot
                entryPath:(NSString *)entryPath args:(NSArray<NSString *> *)args guestPort:(NSUInteger)port
                    ready:(DSHRuntimeServiceReady)ready output:(DSHRuntimeProgramOutput)output error:(NSError **)error {
  if (!ValidArgs(args) || port == 0 || port > 65535 || !ready || !output) {
    Fail(error, @"E_PROGRAM_INVALID_REQUEST"); return nil;
  }
  NSArray *command = [DSHRuntimeProgramVM commandForManifest:lease.manifest entryPath:entryPath args:args];
  if (!command) {
    Fail(error, @"E_PROGRAM_INVALID_REQUEST"); return nil;
  }
  [self.condition lock]; BOOL fresh = !self.used; self.used = YES; [self.condition unlock];
  if (!fresh) { Fail(error, @"E_PROGRAM_BUSY"); return nil; }
  NSNumber *result = nil;
  @try {
    result = [self performWithLease:lease snapshot:snapshot operation:^NSNumber *(void *session, NSError **inner) {
      NSString *root = [@"/tmp/rish-http-" stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];
      NSString *requestPath = [root stringByAppendingString:@"/request"];
      if (![self launchSession:session command:command root:root port:port error:inner]) return nil;
      NSTimeInterval deadline = Now() + [DSHRuntimeProgramVM
          executionTimeoutMillisecondsForFamily:lease.manifest[@"family"] entryPath:entryPath] / 1000.0;
      NSData *probe = [[NSString stringWithFormat:@"GET / HTTP/1.1\r\nHost: 127.0.0.1:%lu\r\nConnection: close\r\n\r\n",
          (unsigned long)port] dataUsingEncoding:NSUTF8StringEncoding];
      // The readiness request is immutable. Rewriting it on every refused
      // connection spawns extra shells/base64 decoders alongside compilation.
      // nc and supervision still run the guest; no host-side sleep stalls it.
      if (![self stageData:probe path:requestPath session:session deadline:deadline error:inner]) return nil;
      NSMutableDictionary *offsets = [NSMutableDictionary dictionary];
      BOOL listening = NO;
      NSData *probeResponse = nil;
      while (!self.cancelled && Now() < deadline) {
        NSError *failure = nil;
        NSData *response = [self forwardStagedRequestAtPath:requestPath port:port session:session deadline:deadline error:&failure];
        if (response) { listening = YES; probeResponse = response; break; }
        if (![failure.userInfo[@"code"] isEqual:@"E_PROGRAM_EXEC"]) {
          // Host deadline/output-limit failures can poison the FFI session;
          // do not try more guest commands and obscure the original cause.
          *inner = failure; return nil;
        }
        NSError *supervision = nil;
        NSNumber *status = [self exitStatus:root session:session error:&supervision];
        if (supervision) {
          // A host-side FFI timeout permanently cancels this VM session.
          // Reusing it cannot recover the background process or its logs.
          *inner = supervision; return nil;
        }
        if (status) { [self readLogs:root session:session offsets:offsets output:output error:nil];
          *inner = DSHRuntimeProgramError(@"E_PROGRAM_EXEC"); return nil; }
      }
      if (!listening) {
        if (self.cancelled) return nil;
        // The shared startup budget is exhausted. A log RPC would exceed that
        // budget and may reuse a session already cancelled by the FFI.
        Fail(inner, @"E_PROGRAM_TIMEOUT"); return nil;
      }
      [self.condition lock]; self.serving = !self.cancelled; [self.condition unlock];
      if (self.cancelled) return nil;
      ready(probeResponse);
      NSTimeInterval nextStatus = Now();
      while (!self.cancelled) {
        [self.condition lock];
        if (self.requests.count == 0 && !self.cancelled)
          [self.condition waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
        DSHRuntimeServiceRequest *request = self.requests.firstObject;
        if (request) [self.requests removeObjectAtIndex:0];
        [self.condition unlock];
        if (request) {
          NSError *failure = nil;
          NSData *response = [self forwardRequest:request.request path:requestPath port:port session:session
              deadline:request.deadline error:&failure];
          request.completion(response, failure);
          if (!response) { *inner = failure; return nil; }
        }
        if (self.cancelled) break;
        if (Now() >= nextStatus) {
          NSError *supervision = nil;
          NSNumber *status = [self exitStatus:root session:session error:&supervision];
          if (!supervision) [self readLogs:root session:session offsets:offsets output:output error:&supervision];
          if (supervision) { *inner = supervision; return nil; }
          if (!supervision && status) return status;
          nextStatus = Now() + 0.5;
        }
      }
      return nil;
    } error:error];
  } @finally {
    [self.condition lock]; self.serving = NO;
    NSArray *pending = [self.requests copy]; [self.requests removeAllObjects];
    [self.condition unlock];
    for (DSHRuntimeServiceRequest *request in pending)
      request.completion(nil, DSHRuntimeProgramError(@"E_PROGRAM_UNAVAILABLE"));
  }
  return result;
}
@end
