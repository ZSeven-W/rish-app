#import "RishGuestCgiFeature.h"
#import "DSHAgentGuestCgiToolExecutor.h"

#import <CommonCrypto/CommonDigest.h>

#import "RishGuestCgiService.h"
#import "AgentWorkspaceToolExecutor.h"
#import "AgentNativeWAL.h"
#import "AgentRootResolver.h"
#import <objc/runtime.h>

static NSUInteger const DSHGuestCgiIndexMax = 32 * 1024;
static NSUInteger const DSHGuestCgiBackendMax = 8 * 1024;
static NSUInteger const DSHGuestCgiInitialMax = 4 * 1024;
static NSString *const DSHGuestCgiStart = @"start_guest_cgi";
static NSString *const DSHGuestCgiStop = @"stop_guest_cgi";

static void DSHGuestCgiSetError(NSError **error, NSString *description) {
  if (error != nullptr) {
    *error = [NSError errorWithDomain:@"DSHAgentGuestCgi"
                                  code:1
                              userInfo:@{NSLocalizedDescriptionKey : description}];
  }
}

static NSError *DSHGuestCgiMakeError(NSString *description) {
  return [NSError errorWithDomain:@"DSHAgentGuestCgi"
                              code:1
                          userInfo:@{NSLocalizedDescriptionKey : description}];
}

static BOOL DSHGuestCgiUUID(NSString *value) {
  static NSRegularExpression *expression;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    expression = [NSRegularExpression
        regularExpressionWithPattern:@"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
                               options:NSRegularExpressionCaseInsensitive
                                 error:nil];
  });
  return [value isKindOfClass:NSString.class] &&
      [expression firstMatchInString:value options:0
                                range:NSMakeRange(0, value.length)] != nil;
}

static BOOL DSHGuestCgiDigest(NSString *value) {
  static NSRegularExpression *expression;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    expression = [NSRegularExpression
        regularExpressionWithPattern:@"^[0-9a-f]{64}$"
                               options:NSRegularExpressionCaseInsensitive
                                 error:nil];
  });
  return [value isKindOfClass:NSString.class] &&
      [expression firstMatchInString:value options:0
                                range:NSMakeRange(0, value.length)] != nil;
}

static BOOL DSHGuestCgiRelativePath(NSString *path) {
  if (![path isKindOfClass:NSString.class] || path.length == 0 ||
      [path lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 1024 ||
      [path hasPrefix:@"/"] || [path containsString:@"\\"] ||
      [path containsString:@"\0"]) return NO;
  for (NSString *component in [path componentsSeparatedByString:@"/"]) {
    if (component.length == 0 || [component isEqual:@"."] ||
        [component isEqual:@".."] || [component.lowercaseString isEqual:@".git"] ||
        [component.lowercaseString hasPrefix:@".staging-"] ||
        [component.lowercaseString hasPrefix:@".rish-write-"]) return NO;
  }
  return YES;
}

static NSString *DSHGuestCgiHexDigest(NSData *data) {
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  NSMutableString *hex = [NSMutableString stringWithCapacity:64];
  for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index += 1)
    [hex appendFormat:@"%02x", digest[index]];
  return hex;
}

@interface DSHAgentGuestCgiToolExecutor ()
@property(nonatomic, strong) RishGuestCgiService *service;
@property(nonatomic, copy) DSHAgentGuestCgiReadFile fileReader;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, copy, nullable) NSString *ownerAttemptId;
@property(nonatomic, copy, nullable) NSString *ownerConversationId;
@property(nonatomic, copy, nullable) NSString *ownerRoundId;
@property(nonatomic, copy, nullable) NSString *serviceId;
@property(nonatomic, copy) NSDictionary *ownerRoot;
@property(nonatomic, strong) NSMutableSet *cancelledAttempts;
@property(nonatomic, weak) DSHAgentWorkspaceToolExecutor *workspace;
@end

@implementation DSHAgentGuestCgiToolExecutor

+ (instancetype)executorForWorkspaceExecutor:(DSHAgentWorkspaceToolExecutor *)workspace {
  static char key;
  @synchronized (workspace) {
    DSHAgentGuestCgiToolExecutor *executor = objc_getAssociatedObject(workspace, &key);
    if (executor == nil) {
      __weak DSHAgentWorkspaceToolExecutor *weakWorkspace = workspace;
      executor = [[self alloc] initWithService:[[RishGuestCgiService alloc] init] fileReader:^(NSString *path, NSDictionary *root, NSUInteger limit, void (^done)(NSData *, NSString *, NSError *)) {
        DSHAgentWorkspaceToolExecutor *reader = weakWorkspace;
        NSError *error = nil;
        NSDictionary *args = @{ @"path": path };
        NSDictionary *prepared = [reader prepareToolNamed:@"read_file" arguments:args root:root error:&error];
        NSDictionary *effect = prepared == nil ? nil : [reader executeToolNamed:@"read_file" arguments:args root:root precondition:prepared[@"precondition"] error:&error];
        NSData *feedback = [effect[@"feedback"] dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *object = feedback == nil ? nil : [NSJSONSerialization JSONObjectWithData:feedback options:0 error:&error];
        NSDictionary *payload = object[@"payload"];
        NSData *data = [payload[@"content"] isKindOfClass:NSString.class] ? [payload[@"content"] dataUsingEncoding:NSUTF8StringEncoding] : nil;
        if (![object[@"outcome"] isEqual:@"ok"] || [payload[@"truncated"] boolValue] || data == nil || data.length > limit) {
          done(nil, nil, DSHGuestCgiMakeError(@"E_AGENT_SOURCE_CONFLICT")); return;
        }
        done(data, payload[@"revision"], nil);
      }];
      executor.workspace = workspace;
      objc_setAssociatedObject(workspace, &key, executor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return executor;
  }
}

- (NSDictionary *)executeSynchronouslyToolNamed:(NSString *)name arguments:(NSDictionary *)arguments root:(NSDictionary *)root owner:(NSDictionary *)owner precondition:(NSDictionary *)precondition {
  NSAssert(!NSThread.isMainThread, @"Guest CGI must execute on the native worker");
  dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
  NSObject *lock = [[NSObject alloc] init];
  __block BOOL expired = NO;
  __block NSDictionary *value = nil;
  __block NSError *executionError = nil;
  [self executeToolNamed:name arguments:arguments root:root owner:owner precondition:precondition completion:^(NSDictionary *result, NSError *error) {
    @synchronized(lock) {
      if (expired) {
        if ([result[@"status"] isEqual:@"running"]) [self cancelServiceForAttempt:owner[@"attempt_id"] serviceId:result[@"service_id"] completion:^(BOOL stopped, NSError *stopError) {}];
      } else { value = result; executionError = error; }
    }
    dispatch_semaphore_signal(semaphore);
  }];
  BOOL timedOut = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 90LL * NSEC_PER_SEC)) != 0;
  @synchronized(lock) {
    expired = timedOut;
    if (timedOut) { value = nil; [self cancelAttempt:owner[@"attempt_id"]]; }
  }
  BOOL uncertain = timedOut || [executionError.localizedDescription isEqual:@"E_AGENT_EXECUTION_AMBIGUOUS"];
  NSString *outcome = value != nil ? @"ok" : (uncertain ? @"ambiguous" : @"failed");
  NSDictionary *payload = value ?: @{ @"schema_version": @1, @"failure_code": uncertain ? @"E_AGENT_EXECUTION_AMBIGUOUS" : @"E_AGENT_TOOL_FAILED" };
  NSData *json = DSHAgentCanonicalJSON(@{ @"schema_version": @1, @"name": name, @"outcome": outcome, @"payload": payload }, nil);
  return @{ @"schema_version": @1, @"status": outcome, @"feedback": [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding], @"settled_facts": value ? @{ @"schema_version": @1, @"kind": name, @"service_id": value[@"service_id"], @"status": value[@"status"] } : NSNull.null, @"truncated": @NO, @"effect_may_have_occurred": @(uncertain || value != nil) };
}


- (instancetype)initWithService:(RishGuestCgiService *)service
                       fileReader:(DSHAgentGuestCgiReadFile)fileReader {
  self = [super init];
  if (self != nil) {
    _service = service;
    _cancelledAttempts = [NSMutableSet set];
    _fileReader = [fileReader copy];
    _queue = dispatch_queue_create("dev.zseven.agent.guest-cgi-tool",
                                   DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (NSDictionary *)prepareToolNamed:(NSString *)name
                          arguments:(NSDictionary *)arguments
                               root:(NSDictionary *)root
                              error:(NSError **)error {
#if !DSH_GUEST_CGI_AVAILABLE
  DSHGuestCgiSetError(error, @"E_AGENT_CAPABILITY");
  return nil;
#endif
  if (![name isEqual:DSHGuestCgiStart] && ![name isEqual:DSHGuestCgiStop]) {
    DSHGuestCgiSetError(error, @"E_AGENT_UNKNOWN_TOOL");
    return nil;
  }
  if (![root isKindOfClass:NSDictionary.class] ||
      ![root[@"capabilities"] containsObject:@"guest_service"] ||
      ![root[@"root_fingerprint_sha256"] isKindOfClass:NSString.class] ||
      !DSHGuestCgiDigest(root[@"root_fingerprint_sha256"])) {
    DSHGuestCgiSetError(error, @"E_AGENT_BAD_ROOT");
    return nil;
  }
  if ([name isEqual:DSHGuestCgiStop]) {
    if (arguments.count != 1 || !DSHGuestCgiUUID(arguments[@"service_id"])) {
      DSHGuestCgiSetError(error, @"E_AGENT_BAD_ARGUMENTS");
      return nil;
    }
    return @{
      @"schema_version" : @1,
      @"kind" : @"stop_guest_cgi",
      @"service_id" : arguments[@"service_id"],
    };
  }
  NSSet *expected = [NSSet setWithObjects:@"index_path", @"index_sha256",
                     @"backend_path", @"backend_sha256", @"initial_data_path",
                     @"initial_data_sha256", nil];
  if (arguments.count != expected.count ||
      ![expected isEqualToSet:[NSSet setWithArray:arguments.allKeys]] ||
      !DSHGuestCgiRelativePath(arguments[@"index_path"]) ||
      !DSHGuestCgiRelativePath(arguments[@"backend_path"]) ||
      !DSHGuestCgiDigest(arguments[@"index_sha256"]) ||
      !DSHGuestCgiDigest(arguments[@"backend_sha256"])) {
    DSHGuestCgiSetError(error, @"E_AGENT_BAD_ARGUMENTS");
    return nil;
  }
  id initialPath = arguments[@"initial_data_path"];
  id initialDigest = arguments[@"initial_data_sha256"];
  if ((initialPath == NSNull.null) != (initialDigest == NSNull.null) ||
      (initialPath != NSNull.null &&
       (!DSHGuestCgiRelativePath(initialPath) || !DSHGuestCgiDigest(initialDigest)))) {
    DSHGuestCgiSetError(error, @"E_AGENT_BAD_ARGUMENTS");
    return nil;
  }
  return @{
    @"schema_version" : @1,
    @"kind" : @"start_guest_cgi",
    @"index_path" : arguments[@"index_path"],
    @"index_sha256" : arguments[@"index_sha256"],
    @"backend_path" : arguments[@"backend_path"],
    @"backend_sha256" : arguments[@"backend_sha256"],
    @"initial_data_path" : initialPath,
    @"initial_data_sha256" : initialDigest,
  };
}

// Automatic preview expiry belongs to the mechanism. Reconcile only its
// terminal idle state; a stopping guest still owns resources and stays busy.
- (BOOL)forgetServiceIfMechanismStopped {
  if (self.serviceId == nil) return NO;
  NSDictionary *status = [self.service status];
  if (![status[@"state"] isEqual:@"idle"] || status[@"service_id"] != nil) return NO;
  self.serviceId = nil; self.ownerAttemptId = nil;
  self.ownerConversationId = nil; self.ownerRoundId = nil; self.ownerRoot = nil;
  return YES;
}

- (void)executeToolNamed:(NSString *)name
               arguments:(NSDictionary *)arguments
                    root:(NSDictionary *)root
                    owner:(NSDictionary *)owner
            precondition:(NSDictionary *)precondition
               completion:(void (^)(NSDictionary *, NSError *))completion {
  __block NSError *error = nil;
  NSDictionary *prepared = [self prepareToolNamed:name arguments:arguments
                                              root:root error:&error];
  if (prepared == nil || ![prepared[@"kind"] isEqual:name] ||
      ![precondition isEqual:prepared]) {
    error = DSHGuestCgiMakeError(@"E_AGENT_CONFLICT");
    completion(nil, error ?: [NSError errorWithDomain:@"DSHAgentGuestCgi" code:1 userInfo:nil]);
    return;
  }
  dispatch_async(self.queue, ^{
    if (![owner isKindOfClass:NSDictionary.class] ||
        !DSHGuestCgiUUID(owner[@"conversation_id"]) ||
        !DSHGuestCgiUUID(owner[@"attempt_id"]) ||
        !DSHGuestCgiUUID(owner[@"round_id"])) {
      NSError *ownerError = nil; DSHGuestCgiSetError(&ownerError, @"E_AGENT_CONFLICT");
      completion(nil, ownerError); return;
    }
    if ([self.cancelledAttempts containsObject:owner[@"attempt_id"]] || (self.workspace != nil && ![self.workspace.rootResolver validateFrozenRoot:root error:nil])) {
      completion(nil, DSHGuestCgiMakeError(@"E_AGENT_CONFLICT")); return;
    }
    if ([name isEqual:DSHGuestCgiStop]) {
      if (self.serviceId == nil || ![self.serviceId isEqual:prepared[@"service_id"]] ||
          ![self.ownerConversationId isEqual:owner[@"conversation_id"]] ||
          ![self.ownerRoot isEqual:root]) {
        error = DSHGuestCgiMakeError(@"E_AGENT_CONFLICT");
        completion(nil, error);
        return;
      }
      if ([self forgetServiceIfMechanismStopped]) {
        completion(@{ @"schema_version": @1, @"status": @"stopped", @"service_id": prepared[@"service_id"] }, nil);
        return;
      }
      [self.service stop:prepared[@"service_id"] resolve:^(NSDictionary *result) {
        dispatch_async(self.queue, ^{
          (void)result;
          self.serviceId = nil;
          self.ownerAttemptId = nil;
          self.ownerConversationId = nil;
          self.ownerRoundId = nil;
          completion(@{ @"schema_version" : @1, @"status" : @"stopped",
                        @"service_id" : prepared[@"service_id"] }, nil);
        });
      } reject:^(NSString *code, NSString *message) {
        dispatch_async(self.queue, ^{
          (void)code; (void)message; error = DSHGuestCgiMakeError(@"E_AGENT_GUEST"); completion(nil, error);
        });
      }];
      return;
    }
    [self forgetServiceIfMechanismStopped];
    if (self.serviceId != nil) {
      error = DSHGuestCgiMakeError(@"E_AGENT_BUSY"); completion(nil, error); return;
    }
    // The fileReader is the native workspace-authority seam. It must read all
    // three files under the same root and compare revisions/digests before
    // this callback invokes RishGuestCgiService.start.
    [self readPrepared:prepared root:root completion:^(NSDictionary *request, NSError *readError) {
      dispatch_async(self.queue, ^{
      if (readError != nil) { completion(nil, readError); return; }
      [self.service start:request resolve:^(NSDictionary *result) {
        dispatch_async(self.queue, ^{
          if ([self.cancelledAttempts containsObject:owner[@"attempt_id"]] || (self.workspace != nil && ![self.workspace.rootResolver validateFrozenRoot:root error:nil])) {
            [self.service stop:result[@"service_id"] resolve:^(NSDictionary *stopped) { completion(nil, DSHGuestCgiMakeError(@"E_AGENT_CONFLICT")); } reject:^(NSString *code, NSString *message) { completion(nil, DSHGuestCgiMakeError(@"E_AGENT_EXECUTION_AMBIGUOUS")); }];
            return;
          }
          self.serviceId = result[@"service_id"];
          self.ownerAttemptId = owner[@"attempt_id"];
          self.ownerConversationId = owner[@"conversation_id"];
          self.ownerRoundId = owner[@"round_id"];
          self.ownerRoot = root;
          completion(@{ @"schema_version" : @1, @"status" : @"running",
                        @"service_id" : result[@"service_id"], @"url" : result[@"url"] }, nil);
        });
      } reject:^(NSString *code, NSString *message) {
        dispatch_async(self.queue, ^{
          (void)code; (void)message; error = DSHGuestCgiMakeError(@"E_AGENT_GUEST"); completion(nil, error);
        });
      }];
      });
    }];
  });
}

// Each native read verifies its descriptor-relative source revision. The
// supplied digests freeze the complete content snapshot across all reads.
- (void)readPrepared:(NSDictionary *)precondition
                root:(NSDictionary *)root
          completion:(void (^)(NSDictionary *, NSError *))completion {
  if (self.fileReader == nil) {
    NSError *error = DSHGuestCgiMakeError(@"E_AGENT_NATIVE"); completion(nil, error); return;
  }
  // No source bytes cross the app UI boundary.
  self.fileReader(precondition[@"index_path"], root, DSHGuestCgiIndexMax,
    ^(NSData *index, NSString *indexRevision, NSError *error) {
      (void)indexRevision;
      if (error != nil || index == nil || index.length > DSHGuestCgiIndexMax || ![DSHGuestCgiHexDigest(index) isEqual:precondition[@"index_sha256"]]) {
        completion(nil, error ?: DSHGuestCgiMakeError(@"E_AGENT_SOURCE_CONFLICT")); return;
      }
      self.fileReader(precondition[@"backend_path"], root, DSHGuestCgiBackendMax,
        ^(NSData *backend, NSString *backendRevision, NSError *error2) {
          (void)backendRevision;
          if (error2 != nil || backend == nil || backend.length > DSHGuestCgiBackendMax || ![DSHGuestCgiHexDigest(backend) isEqual:precondition[@"backend_sha256"]]) {
            completion(nil, error2 ?: DSHGuestCgiMakeError(@"E_AGENT_SOURCE_CONFLICT")); return;
          }
          NSDictionary *request = @{
            @"indexHtml" : [[NSString alloc] initWithData:index encoding:NSUTF8StringEncoding] ?: @"",
            @"backendScript" : [[NSString alloc] initWithData:backend encoding:NSUTF8StringEncoding] ?: @"",
          };
          id initialPath = precondition[@"initial_data_path"];
          if (initialPath == NSNull.null) {
            NSMutableDictionary *withoutInitial = [request mutableCopy];
            withoutInitial[@"initialData"] = @{};
            completion(withoutInitial, nil);
            return;
          }
          self.fileReader(initialPath, root, DSHGuestCgiInitialMax,
            ^(NSData *initialData, NSString *initialRevision, NSError *error3) {
              (void)initialRevision;
              if (error3 != nil || initialData == nil || initialData.length > DSHGuestCgiInitialMax ||
                  ![DSHGuestCgiHexDigest(initialData) isEqual:precondition[@"initial_data_sha256"]]) {
                completion(nil, error3 ?: DSHGuestCgiMakeError(@"E_AGENT_SOURCE_CONFLICT")); return;
              }
              id initialObject = [NSJSONSerialization JSONObjectWithData:initialData options:0 error:nil];
              if (![NSJSONSerialization isValidJSONObject:initialObject]) {
                NSError *invalid = nil; DSHGuestCgiSetError(&invalid, @"E_AGENT_BAD_ARGUMENTS"); completion(nil, invalid); return;
              }
              NSMutableDictionary *withInitial = [request mutableCopy];
              withInitial[@"initialData"] = initialObject;
              completion(withInitial, nil);
            });
        });
    });
}

- (void)cancelAttempt:(NSString *)attemptId {
  if (![attemptId isKindOfClass:NSString.class]) return;
  dispatch_async(self.queue, ^{
    [self.cancelledAttempts addObject:attemptId];
    if ([self.ownerAttemptId isEqual:attemptId] && self.serviceId != nil) {
      [self cancelServiceForAttempt:attemptId serviceId:self.serviceId completion:^(BOOL stopped, NSError *error) {}];
    }
  });
}

- (void)cancelServiceForAttempt:(NSString *)attemptId
                        serviceId:(NSString *)serviceId
                       completion:(void (^)(BOOL, NSError *))completion {
  dispatch_async(self.queue, ^{
    if (![attemptId isEqual:self.ownerAttemptId] || ![serviceId isEqual:self.serviceId]) {
      NSError *error = DSHGuestCgiMakeError(@"E_AGENT_CONFLICT"); completion(NO, error); return;
    }
    [self.service stop:serviceId resolve:^(NSDictionary *result) {
      dispatch_async(self.queue, ^{ (void)result; self.serviceId = nil; self.ownerAttemptId = nil; self.ownerConversationId = nil; self.ownerRoundId = nil; completion(YES, nil); });
    } reject:^(NSString *code, NSString *message) {
      (void)code; (void)message; NSError *error = DSHGuestCgiMakeError(@"E_AGENT_GUEST"); completion(NO, error);
    }];
  });
}

@end
