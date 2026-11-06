#import "ShellWorkspaceModule.h"
#import "RishNameValidation.h"
#include <math.h>

static NSString *const RishDefaultIdentityKey = @"identity_v1";
static NSTimeInterval const RishDefaultReceiptLifetime = 30 * 24 * 60 * 60;

static dispatch_queue_t RishDefaultQueue(void) {
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    queue = dispatch_queue_create("tech.zseven.rish.gpui.default-workspace", DISPATCH_QUEUE_SERIAL);
  });
  return queue;
}

static BOOL RishDefaultUUID(id value) {
  if (![value isKindOfClass:NSString.class] || [value length] != 36) return NO;
  NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:value];
  return uuid != nil && [uuid.UUIDString.lowercaseString isEqual:value];
}
static BOOL RishDefaultName(id value) {
  // Existing journals keep their exact request bytes for idempotent retries.
  return RishValidateName(value, @"workspace") == RishNameValidationIssueNone &&
    [RishNormalizedName(value) isEqual:value];
}
static BOOL RishDefaultSchema(id value, NSInteger version) {
  return [value isKindOfClass:NSNumber.class] &&
    CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() && [value isEqual:@(version)];
}
static BOOL RishDefaultRevision(id value) {
  return [value isKindOfClass:NSNumber.class] &&
    CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
    isfinite([value doubleValue]) && [value doubleValue] >= 1 &&
    [value doubleValue] <= 9007199254740991.0 && floor([value doubleValue]) == [value doubleValue];
}

@interface ShellWorkspaceModule ()
@property(nonatomic, strong) NSUserDefaults *defaults;
@property(nonatomic, strong) id<RishDefaultWorkspaceBackend> backend;
@property(nonatomic, copy) NSDate *(^clock)(void);
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *waiters;
@property(nonatomic, strong) NSObject *invocation;
@end

@implementation ShellWorkspaceModule
RISH_NATIVE_MODULE(ShellWorkspace)
+ (BOOL)requiresMainQueueSetup { return NO; }
- (instancetype)init {
  // No directory lookup by display name: this dedicated identity survives name
  // changes, locale changes and repeated launches without adopting another root.
  NSUserDefaults *defaults = [[NSUserDefaults alloc]
    initWithSuiteName:@"tech.zseven.rish.gpui.default-workspace"];
  id backend = [NSClassFromString(@"LocalWorkspacesModule") new];
  return [self initWithDefaults:defaults backend:backend clock:^NSDate *{ return NSDate.date; }];
}
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults
    backend:(id<RishDefaultWorkspaceBackend>)backend clock:(NSDate *(^)(void))clock {
  self = [super init];
  if (self) {
    _defaults = defaults;
    _backend = backend;
    _clock = [clock copy];
    _queue = RishDefaultQueue();
    _waiters = [NSMutableArray array];
  }
  return self;
}
- (dispatch_queue_t)methodQueue { return self.queue; }

- (void)finish:(id)value code:(NSString *)code message:(NSString *)message {
  NSArray *waiters = [self.waiters copy];
  [self.waiters removeAllObjects];
  self.invocation = nil;
  for (NSDictionary *waiter in waiters) {
    if (code != nil) {
      RishRejectBlock reject = waiter[@"reject"];
      reject(code, message ?: @"Default workspace is unavailable.", nil);
    } else {
      RishResolveBlock resolve = waiter[@"resolve"];
      resolve(value);
    }
  }
}
- (void)recover {
  [self finish:nil code:@"E_DEFAULT_WORKSPACE_RECOVERY_REQUIRED"
    message:@"The saved default workspace identity requires recovery."];
}
- (BOOL)persist:(NSDictionary *)record {
  id previous = [self.defaults objectForKey:RishDefaultIdentityKey];
  [self.defaults setObject:record forKey:RishDefaultIdentityKey];
  // The pending operation must reach durable preferences before creation. A
  // failed checkpoint restores the old pending identity so retry stays safe.
  if ([self.defaults synchronize]) return YES;
  if (previous != nil) [self.defaults setObject:previous forKey:RishDefaultIdentityKey];
  else [self.defaults removeObjectForKey:RishDefaultIdentityKey];
  [self.defaults synchronize];
  [self finish:nil code:@"E_DEFAULT_WORKSPACE_PERSISTENCE"
    message:@"The default workspace identity could not be saved."];
  return NO;
}
- (RishRejectBlock)rejectForInvocation:(NSObject *)invocation {
  return ^(NSString *code, NSString *message, NSError *error) {
    dispatch_async(self.queue, ^{
      if (self.invocation != invocation) return;
      [self finish:nil code:code ?: @"E_WORKSPACE_UNAVAILABLE" message:message];
    });
  };
}
- (void)resolveIdentity:(NSString *)workspaceID revision:(NSNumber *)revision invocation:(NSObject *)invocation {
  NSDictionary *request = @{@"schema_version": @1, @"workspace_id": workspaceID,
    @"expected_binding_revision": revision ?: NSNull.null,
    @"required_capabilities": revision ? @[@"read", @"write"] : @[]};
  [self.backend resolveWorkspaceRequest:request resolver:^(id result) {
    dispatch_async(self.queue, ^{
      if (self.invocation != invocation) return;
      NSDictionary *envelope = [result isKindOfClass:NSDictionary.class] ? result : nil;
      NSDictionary *descriptor = envelope[@"workspace"];
      if (!RishDefaultSchema(envelope[@"schema_version"], 1) || ![envelope[@"disposition"] isEqual:@"direct"] ||
          ![descriptor isKindOfClass:NSDictionary.class] ||
          !RishDefaultSchema(descriptor[@"schema_version"], 2) ||
          ![descriptor[@"workspace_id"] isEqual:workspaceID] ||
          !RishDefaultRevision(descriptor[@"binding_revision"])) { [self recover]; return; }
      if (![descriptor[@"status"] isEqual:@"ok"]) {
        [self finish:nil code:@"E_WORKSPACE_UNAVAILABLE" message:@"The default workspace is unavailable."];
        return;
      }
      if (revision == nil) {
        [self resolveIdentity:workspaceID revision:descriptor[@"binding_revision"] invocation:invocation];
        return;
      }
      id caps = descriptor[@"capabilities"];
      if (![caps isKindOfClass:NSDictionary.class] || ![caps[@"read"] isEqual:@YES] ||
          ![caps[@"write"] isEqual:@YES] || ![descriptor[@"binding_revision"] isEqual:revision]) {
        [self finish:nil code:@"E_WORKSPACE_CAPABILITY" message:@"The default workspace is not writable."];
        return;
      }
      [self finish:descriptor code:nil message:nil];
    });
  } rejecter:[self rejectForInvocation:invocation]];
}

RISH_NATIVE_METHOD(ensureDefault, ensureDefaultWithOptions:(NSDictionary *)options
    resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  if (![options isKindOfClass:NSDictionary.class] || options.count != 1 ||
      !RishDefaultName(options[@"display_name"])) {
    reject(@"E_WORKSPACE_INVALID", @"The default workspace options are invalid.", nil);
    return;
  }
  dispatch_async(self.queue, ^{
    [self.waiters addObject:@{@"resolve": [resolve copy], @"reject": [reject copy]}];
    if (self.invocation != nil) return;
    NSObject *invocation = [NSObject new];
    self.invocation = invocation;
    if (self.backend == nil || self.defaults == nil) {
      [self finish:nil code:@"E_WORKSPACE_UNAVAILABLE" message:@"Workspace services are unavailable."];
      return;
    }
    id saved = [self.defaults objectForKey:RishDefaultIdentityKey];
    if (saved != nil && (![saved isKindOfClass:NSDictionary.class] || !RishDefaultSchema(saved[@"schema_version"], 1))) {
      [self recover]; return;
    }
    NSDictionary *record = saved;
    if (record[@"workspace_id"] != nil) {
      if (record.count != 2 || !RishDefaultUUID(record[@"workspace_id"])) { [self recover]; return; }
      [self resolveIdentity:record[@"workspace_id"] revision:nil invocation:invocation];
      return;
    }
    if (record == nil) {
      record = @{@"schema_version": @1, @"pending_operation_id": NSUUID.UUID.UUIDString.lowercaseString,
        @"pending_display_name": options[@"display_name"], @"pending_started_at": @([self.clock() timeIntervalSince1970])};
      if (![self persist:record]) return;
    }
    id timestamp = record[@"pending_started_at"];
    NSTimeInterval now = [self.clock() timeIntervalSince1970];
    if (record.count != 4 || !RishDefaultUUID(record[@"pending_operation_id"]) ||
        !RishDefaultName(record[@"pending_display_name"]) ||
        ![timestamp isKindOfClass:NSNumber.class] || !isfinite([timestamp doubleValue]) ||
        [timestamp doubleValue] < 0 || [timestamp doubleValue] > now ||
        now - [timestamp doubleValue] >= RishDefaultReceiptLifetime) { [self recover]; return; }
    NSDictionary *request = @{@"schema_version": @1, @"operation_id": record[@"pending_operation_id"],
      @"display_name": record[@"pending_display_name"]};
    [self.backend createWorkspaceRequest:request resolver:^(id result) {
      dispatch_async(self.queue, ^{
        if (self.invocation != invocation) return;
        if (![result isKindOfClass:NSDictionary.class] || !RishDefaultSchema(result[@"schema_version"], 2) ||
            !RishDefaultUUID(result[@"workspace_id"])) { [self recover]; return; }
        NSString *workspaceID = result[@"workspace_id"];
        if (![self persist:@{@"schema_version": @1, @"workspace_id": workspaceID}]) return;
        [self resolveIdentity:workspaceID revision:nil invocation:invocation];
      });
    } rejecter:[self rejectForInvocation:invocation]];
  });
}
@end
