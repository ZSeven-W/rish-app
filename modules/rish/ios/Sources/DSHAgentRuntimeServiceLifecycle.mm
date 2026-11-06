#import "DSHAgentRuntimeToolInternals.h"

@implementation DSHAgentRuntimeToolExecutor (ServiceLifecycle)
- (NSDictionary *)performServiceStart:(DSHAgentRuntimeRecord *)record snapshot:(DSHRuntimeWorkspaceSnapshot *)snapshot
                                lease:(DSHRuntimeEnvironmentLease *)lease {
  DSHRuntimeServiceVM *vm = nil;
  @try { vm = self.serviceFactory(); }
  @catch (__unused NSException *exception) { /* No worker has taken the lease yet. */ }
  if (!vm) {
    [self.store releaseLease:lease];
    return DSHAgentRuntimeFailure(record, @"E_AGENT_TOOL_FAILED", @"service_initialization_failed", nil);
  }
  dispatch_semaphore_t startup = dispatch_semaphore_create(0);
  record.serviceDone = dispatch_group_create(); dispatch_group_enter(record.serviceDone);
  @synchronized (record) {
    record.vm = vm; record.serviceId = NSUUID.UUID.UUIDString.lowercaseString;
    record.effectStarted = !record.cancelled;
    if (record.cancelled) [vm cancel];
  }
  @synchronized (self) { self.services[record.serviceId] = record; }
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSNumber *exitCode = nil; NSError *failure = nil;
    @try {
      if (!record.cancelled) exitCode = [vm serveLease:lease snapshot:snapshot
          entryPath:record.arguments[@"entry_path"] args:record.arguments[@"args"]
          guestPort:[record.arguments[@"port"] unsignedIntegerValue]
          ready:^(NSData *probe) {
        if (![DSHRuntimeHTTPServer validateResponse:probe requestMethod:@"GET" error:nil] ||
            ![self recordCurrent:record execution:YES]) {
          @synchronized (record) { record.serviceError = DSHRuntimeProgramError(@"E_PROGRAM_EXEC"); }
          [vm cancel]; dispatch_semaphore_signal(startup); return;
        }
        __weak DSHAgentRuntimeToolExecutor *weakSelf = self;
        __weak DSHAgentRuntimeRecord *weakRecord = record;
        DSHRuntimeHTTPServer *http = [[DSHRuntimeHTTPServer alloc] initWithRequestHandler:
            ^(NSData *request, DSHRuntimeHTTPCompletion completion) {
          DSHAgentRuntimeToolExecutor *owner = weakSelf;
          DSHAgentRuntimeRecord *current = weakRecord;
          if (!owner || !current || ![owner recordCurrent:current execution:NO]) {
            if (owner && current) [owner cancelRecord:current];
            completion(nil, DSHRuntimeProgramError(@"E_PROGRAM_UNAVAILABLE")); return;
          }
          [vm requestHTTP:request completion:completion];
        }];
        NSError *error = nil;
        BOOL opened = [http startWithError:&error];
        @synchronized (record) {
          if (opened && !record.cancelled) { record.http = http; record.serviceReady = YES; }
          else { record.serviceError = error ?: DSHRuntimeProgramError(@"E_PROGRAM_EXEC"); opened = NO; }
        }
        if (!opened) { [http stop]; [vm cancel]; }
        dispatch_semaphore_signal(startup);
      } output:^(NSString *channel, NSData *bytes) { [self captureOutput:bytes channel:channel record:record]; }
          error:&failure];
    } @catch (__unused NSException *exception) {
      failure = DSHRuntimeProgramError(@"E_PROGRAM_NATIVE"); [vm cancel];
    } @finally {
      // serveLease has synchronously freed the entire VM before returning.
      DSHRuntimeHTTPServer *http;
      @synchronized (record) { http = record.http; record.http = nil; }
      [http stop];
      [self.store releaseLease:lease];
      @synchronized (record) {
        record.serviceExit = exitCode; record.serviceError = record.serviceError ?: failure;
        record.serviceFinished = YES; record.vm = nil; record.validator = nil;
      }
      dispatch_semaphore_signal(startup); dispatch_group_leave(record.serviceDone);
      if (record.durable) [self acknowledgeSettlementOwner:record.owner];
    }
  });
  NSTimeInterval seconds = 220.0 + [DSHRuntimeProgramVM
      executionTimeoutMillisecondsForFamily:lease.manifest[@"family"] entryPath:record.arguments[@"entry_path"]] / 1000.0;
  BOOL expired = dispatch_semaphore_wait(startup, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC))) != 0;
  if (expired) [self cancelRecord:record];
  BOOL ready, cancelled; NSURL *url; NSNumber *exitCode; NSError *serviceError;
  @synchronized (record) {
    ready = record.serviceReady && !record.serviceFinished; cancelled = record.cancelled;
    url = record.http.url; exitCode = record.serviceExit; serviceError = record.serviceError;
  }
  if (!ready || cancelled || !url || ![self recordCurrent:record execution:NO]) {
    [self cancelRecord:record];
    if (dispatch_group_wait(record.serviceDone, dispatch_time(DISPATCH_TIME_NOW, 30LL * NSEC_PER_SEC)))
      return DSHAgentRuntimeEffect(record.name, @"ambiguous", @{@"schema_version":@1,
          @"failure_code":@"E_AGENT_EXECUTION_AMBIGUOUS"}, record.precondition, YES);
    BOOL timedOut = expired || (!cancelled &&
        [serviceError.domain isEqual:DSHRuntimeProgramErrorDomain] &&
        [serviceError.userInfo[@"code"] isEqual:@"E_PROGRAM_TIMEOUT"]);
    return DSHAgentRuntimeFailure(record, cancelled ? @"E_AGENT_CANCELLED" : @"E_AGENT_TOOL_FAILED",
        timedOut ? @"service_start_timed_out" : (cancelled ? @"runtime_cancelled" : @"service_start_failed"), exitCode);
  }
  return DSHAgentRuntimeEffect(record.name, @"ok", @{@"schema_version":@1,
      @"environment_id":record.arguments[@"environment_id"], @"status":@"running",
      @"service_id":record.serviceId, @"url":url.absoluteString}, record.precondition, YES);
}

- (NSDictionary *)performServiceStop:(DSHAgentRuntimeRecord *)record {
  DSHAgentRuntimeRecord *service;
  @synchronized (self) { service = self.services[record.arguments[@"service_id"]]; }
  if (!service || ![service.owner[@"conversation_id"] isEqual:record.owner[@"conversation_id"]] ||
      ![service.root isEqual:record.root])
    return DSHAgentRuntimeFailure(record, @"E_AGENT_TOOL_FAILED", @"service_not_owned_by_conversation", nil);
  record.effectStarted = YES;
  [self cancelRecord:service];
  if (dispatch_group_wait(service.serviceDone, dispatch_time(DISPATCH_TIME_NOW, 30LL * NSEC_PER_SEC)))
    return DSHAgentRuntimeEffect(record.name, @"ambiguous", @{@"schema_version":@1,
        @"failure_code":@"E_AGENT_EXECUTION_AMBIGUOUS"}, record.precondition, YES);
  if (![self recordCurrent:record execution:YES]) return DSHAgentRuntimeFailure(record,
      @"E_AGENT_CANCELLED", @"runtime_cancelled", nil);
  return DSHAgentRuntimeEffect(record.name, @"ok", @{@"schema_version":@1,
      @"status":@"stopped", @"service_id":record.arguments[@"service_id"]}, record.precondition, YES);
}
@end
