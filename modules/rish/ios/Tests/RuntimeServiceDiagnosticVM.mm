#import "RuntimeServiceDiagnosticVM.h"
#import "RuntimeWorkspaceSnapshot.h"
#import "RuntimeEnvironmentStore.h"

@interface DSHRuntimeServiceVM (DiagnosticTestSeam)
- (NSDictionary *)executeSession:(void *)session command:(NSArray *)command
                         deadline:(NSTimeInterval)deadline limit:(NSUInteger)limit
                           stdout:(NSData **)stdoutData error:(NSError **)error;
@end

@interface DSHRuntimeServiceDiagnosticVM ()
@property(nonatomic) NSTimeInterval diagnosticBegan;
@property(nonatomic) NSTimeInterval lastGuestSnapshot;
@property(nonatomic) NSUInteger calls;
@property(nonatomic) BOOL toolchainCaptured;
@end

@implementation DSHRuntimeServiceDiagnosticVM
- (void)guestSnapshot:(void *)session {
  NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
  if (self.lastGuestSnapshot > 0 && now - self.lastGuestSnapshot < 60) return;
  self.lastGuestSnapshot = now;
  NSString *toolchain = NSProcessInfo.processInfo.environment[@"RISH_RUNTIME_DIAGNOSTIC_TOOLCHAIN"];
  BOOL capture = !self.toolchainCaptured && now - self.diagnosticBegan >= 180 &&
      ([@"go" isEqual:toolchain] || [@"java" isEqual:toolchain]);
  if (capture) self.toolchainCaptured = YES;
  // Fixed, read-only proc fields from the disposable fixture VM. In
  // particular, cmdline/environ and the contents of random devices are absent.
  NSString *script = @"printf 'entropy='; cat /proc/sys/kernel/random/entropy_avail; "
      "for task in /proc/[0-9]*/task/[0-9]*; do "
      "test -r \"$task/comm\" || continue; read -r comm < \"$task/comm\"; "
      "case \"$comm\" in python3|python3.12|java|go|compile|link|rustc|rish-program|nc|sh|VM\\ Thread|main) ;; *) continue;; esac; "
      "wchan=unknown; test ! -r \"$task/wchan\" || read -r wchan < \"$task/wchan\" || :; "
      "call=unknown; test ! -r \"$task/syscall\" || read -r call rest < \"$task/syscall\" || :; "
      "printf 'process=%s wchan=%s syscall=%s\\n' \"$comm\" \"$wchan\" \"$call\"; "
      "if test \"$comm\" = python3 && test -f /runtime/tmp/rish-python-diag-ready; then "
      "pid=${task##*/}; /bin/busybox kill -USR1 \"$pid\"; fi; "
      "if test \"$1\" != none && test \"$comm\" = \"$1\"; then "
      "pid=${task#/proc/}; pid=${pid%%/*}; tid=${task##*/}; "
      "if test \"$pid\" = \"$tid\"; then mask=; "
      "while read -r key value rest; do test \"$key\" != SigCgt: || mask=$value; done < \"$task/status\"; "
      "case \"$mask\" in ''|*[!0-9a-fA-F]*) ;; *) "
      "if test \"$((0x$mask & 4))\" -ne 0; then printf 'RISH_TOOLCHAIN_STACK %s\\n' \"$comm\" > /dev/ttyS0; "
      "/bin/busybox kill -QUIT \"$pid\"; fi;; esac; fi; fi; done";
  NSData *bytes = nil; NSError *error = nil;
  NSDictionary *reply = [super executeSession:session command:@[@"/bin/sh", @"-c", script, @"sh", capture ? toolchain : @"none"]
      deadline:now + 45 limit:8192 stdout:&bytes error:&error];
  NSString *safeCode = [error.domain isEqual:DSHRuntimeProgramErrorDomain]
      ? error.userInfo[@"code"] : (error ? @"foreign" : @"none");
  NSLog(@"RISH_SERVICE_GUEST_STATE elapsed=%.3f exit=%@ error=%@ fields=%@",
      now - self.diagnosticBegan, reply[@"exit_code"], safeCode,
      bytes ? [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding] : @"");
}

- (NSDictionary *)executeSession:(void *)session command:(NSArray *)command
                         deadline:(NSTimeInterval)deadline limit:(NSUInteger)limit
                           stdout:(NSData **)stdoutData error:(NSError **)error {
  NSTimeInterval began = NSProcessInfo.processInfo.systemUptime;
  if (!self.diagnosticBegan) self.diagnosticBegan = began;
  NSString *script = command.count > 2 ? command[2] : @"";
  NSString *phase = [script containsString:@"mkfifo"] ? @"launch"
      : [script hasPrefix:@"exec /bin/busybox nc"] ? @"http"
      : [script hasPrefix:@"if test -s"] ? @"status"
      : [script hasPrefix:@"if test -f"] ? @"logs" : @"request_stage";
  NSUInteger call = ++self.calls;
  if ([phase isEqual:@"launch"]) {
    NSString *toolchain = NSProcessInfo.processInfo.environment[@"RISH_RUNTIME_DIAGNOSTIC_TOOLCHAIN"];
    NSString *variant = NSProcessInfo.processInfo.environment[@"RISH_RUNTIME_DIAGNOSTIC_VARIANT"];
    if ([@"go-importcfg" isEqual:variant]) {
      // Candidate experiment only: the exact table was exported from the
      // frozen Go disk, and refers exclusively to its pre-existing archives.
      NSURL *tableURL = [NSURL fileURLWithPath:NSProcessInfo.processInfo.environment[@"RISH_RUNTIME_DIAGNOSTIC_IMPORTCFG"] ?: @""];
      NSData *table = DSHEnvironmentReadSmallFile(tableURL, 65536);
      if (!table || ![DSHEnvironmentHashFile(tableURL, table.length, nil) isEqual:
          @"8ae1082fdfde92d5f00f78528fe1e1b407b3136d9060bb6de1a414a5899ba91e"]) {
        if (error) *error = DSHRuntimeProgramError(@"E_PROGRAM_ASSET_INTEGRITY");
        return nil;
      }
      NSString *stage = [NSString stringWithFormat:@"printf '%%s' '%@' | /bin/busybox base64 -d > /runtime/tmp/rish-stdlib.importcfg",
          [table base64EncodedStringWithOptions:0]];
      NSError *stagingError = nil;
      NSDictionary *staged = [super executeSession:session command:@[@"/bin/sh", @"-c", stage]
          deadline:deadline limit:4096 stdout:nil error:&stagingError];
      if (stagingError || ![staged[@"exit_code"] isEqual:@0]) {
        if (error) *error = stagingError ?: DSHRuntimeProgramError(@"E_PROGRAM_EXEC");
        return nil;
      }
    }
    NSMutableArray *diagnostic = [command mutableCopy];
    for (NSUInteger index = 0; index < diagnostic.count; index++) {
      if (![diagnostic[index] isKindOfClass:NSString.class]) continue;
      NSString *value = diagnostic[index];
      if ([@"go" isEqual:toolchain] && [value hasPrefix:@"cd /workspace"] && [value containsString:@"/usr/bin/go build"]) {
        value = [value stringByReplacingOccurrencesOfString:@"/usr/bin/go build -o" withString:@"GOTRACEBACK=system /usr/bin/go build -x -o"];
        diagnostic[index] = [value stringByReplacingOccurrencesOfString:@"\"$source\" &&" withString:@"\"$source\" 2>/dev/ttyS0 &&"];
      } else if ([@"java" isEqual:toolchain] && [value hasPrefix:@"cd /workspace"] && [value containsString:@"/usr/bin/java"]) {
        value = [value stringByReplacingOccurrencesOfString:@"/usr/bin/java" withString:@"/usr/bin/java -XX:+DisplayVMOutputToStderr -Xlog:startuptime=info,class+load=info:stderr:uptime,level,tags"];
        diagnostic[index] = [value stringByAppendingString:@" 2>/dev/ttyS0"];
      }
      if ([@"go-no-index" isEqual:variant] && [value hasPrefix:@"cd /workspace"] && [value containsString:@"/usr/bin/go build"]) {
        diagnostic[index] = [value stringByReplacingOccurrencesOfString:@"/usr/bin/go build" withString:@"GODEBUG=goindex=0 /usr/bin/go build"];
      } else if ([@"go-importcfg" isEqual:variant] && [value hasPrefix:@"cd /workspace"] && [value containsString:@"/usr/bin/go build"]) {
        diagnostic[index] = @"cd /workspace || exit; source=$1; shift; "
            "export GOROOT=/usr/lib/go; tool=/usr/lib/go/pkg/tool/linux_amd64; "
            "\"$tool/compile\" -o /tmp/rish-main.a -p main -lang=go1.25 -goversion go1.25.10 -complete -nolocalimports -pack -importcfg /tmp/rish-stdlib.importcfg \"$source\" && "
            "\"$tool/link\" -o /tmp/rish-program -importcfg /tmp/rish-stdlib.importcfg -buildmode=exe -extld=gcc /tmp/rish-main.a && "
            "exec /tmp/rish-program \"$@\"";
      } else if ([@"java-tier1" isEqual:variant] && [value hasPrefix:@"cd /workspace"] && [value containsString:@"/usr/bin/java"]) {
        diagnostic[index] = [value stringByReplacingOccurrencesOfString:@"/usr/bin/java" withString:@"/usr/bin/java -XX:TieredStopAtLevel=1"];
      } else if ([@"java-cds" isEqual:variant] && [value hasPrefix:@"cd /workspace"] && [value containsString:@"/usr/bin/java"]) {
        diagnostic[index] = [value stringByReplacingOccurrencesOfString:@"/usr/bin/java" withString:@"/usr/bin/java -Xshare:on -XX:SharedArchiveFile=/usr/lib/jvm/java-21-openjdk/lib/server/rish-compiler-http.jsa"];
      }
    }
    command = diagnostic;
  }
  if ([phase isEqual:@"launch"] &&
      [NSProcessInfo.processInfo.environment[@"RISH_RUNTIME_DIAGNOSTIC_FOREGROUND"] isEqual:@"1"]) {
    NSData *probeBytes = nil; NSError *probeError = nil;
    NSDictionary *probe = [super executeSession:session command:@[@"/bin/busybox", @"chroot", @"/runtime",
        @"/usr/bin/python3", @"-u", @"-c",
        @"print('before_http_import', flush=True); from http.server import HTTPServer, BaseHTTPRequestHandler; print('after_http_import', flush=True); s=HTTPServer(('127.0.0.1',8081), BaseHTTPRequestHandler); print('server_constructed', flush=True); s.server_close()"]
        deadline:began + 300 limit:4096 stdout:&probeBytes error:&probeError];
    NSLog(@"RISH_SERVICE_FOREGROUND_PROBE duration=%.3f exit=%@ code=%@ markers=%@",
        NSProcessInfo.processInfo.systemUptime - began, probe[@"exit_code"],
        [probeError.domain isEqual:DSHRuntimeProgramErrorDomain] ? probeError.userInfo[@"code"] : @"none",
        probeBytes ? [[NSString alloc] initWithData:probeBytes encoding:NSUTF8StringEncoding] : @"");
    [self cancel];
    if (error) *error = DSHRuntimeProgramError(@"E_PROGRAM_UNAVAILABLE");
    return nil;
  }
  NSLog(@"RISH_SERVICE_STAGE call=%lu phase=%@ event=begin elapsed=%.3f remaining=%.3f",
      (unsigned long)call, phase, began - self.diagnosticBegan, deadline - began);
  NSError *failure = nil;
  NSDictionary *reply = [super executeSession:session command:command deadline:deadline
      limit:limit stdout:stdoutData error:&failure];
  if (error) *error = failure;
  NSString *safeCode = [failure.domain isEqual:DSHRuntimeProgramErrorDomain]
      ? failure.userInfo[@"code"] : (failure ? @"foreign" : @"none");
  NSLog(@"RISH_SERVICE_STAGE call=%lu phase=%@ event=end elapsed=%.3f duration=%.3f exit=%@ error=%@",
      (unsigned long)call, phase, NSProcessInfo.processInfo.systemUptime - self.diagnosticBegan,
      NSProcessInfo.processInfo.systemUptime - began, reply[@"exit_code"], safeCode);
  if ([phase isEqual:@"http"] && [reply[@"exit_code"] integerValue] == 1 &&
      [NSProcessInfo.processInfo.environment[@"RISH_RUNTIME_DIAGNOSTIC_COAST"] isEqual:@"1"]) {
    NSTimeInterval coast = NSProcessInfo.processInfo.systemUptime;
    NSError *coastError = nil;
    NSDictionary *coasted = [super executeSession:session command:@[@"/bin/busybox", @"sleep", @"0.25"]
        deadline:deadline limit:4096 stdout:nil error:&coastError];
    NSLog(@"RISH_SERVICE_COAST elapsed=%.3f duration=%.3f exit=%@ error=%@",
        NSProcessInfo.processInfo.systemUptime - self.diagnosticBegan,
        NSProcessInfo.processInfo.systemUptime - coast, coasted[@"exit_code"],
        [coastError.domain isEqual:DSHRuntimeProgramErrorDomain] ? coastError.userInfo[@"code"] : @"none");
  }
  if (!self.cancelled && ([phase isEqual:@"launch"] || [phase isEqual:@"status"]))
    [self guestSnapshot:session];
  return reply;
}
@end
