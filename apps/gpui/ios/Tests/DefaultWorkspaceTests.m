#import <Foundation/Foundation.h>
#import "ShellWorkspaceModule.h"

// No real workspace module or application domain is initialized by this host
// regression. These fakes model only callbacks and the durable identity journal.
@interface RishTestPreferences : NSUserDefaults
@property(nonatomic, strong) NSMutableDictionary *values;
@property(nonatomic) BOOL failNextSync;
@end
@implementation RishTestPreferences
- (instancetype)init { self = [super init]; if (self) _values = [NSMutableDictionary dictionary]; return self; }
- (id)objectForKey:(NSString *)key { return self.values[key]; }
- (void)setObject:(id)value forKey:(NSString *)key { self.values[key] = [value copy]; }
- (void)removeObjectForKey:(NSString *)key { [self.values removeObjectForKey:key]; }
- (BOOL)synchronize { BOOL fails = self.failNextSync; self.failNextSync = NO; return !fails; }
@end

@interface RishTestWorkspaces : NSObject <RishDefaultWorkspaceBackend>
@property(nonatomic, strong) RishTestPreferences *preferences;
@property(nonatomic, strong) NSMutableDictionary *receipts;
@property(nonatomic, strong) NSMutableArray *creates;
@property(nonatomic, strong) NSMutableArray *resolves;
@property(nonatomic) BOOL failAfterCreate;
@property(nonatomic) BOOL failCheckpointAfterCreate;
@property(nonatomic) BOOL missing;
@property(nonatomic) BOOL unwritable;
@end
@implementation RishTestWorkspaces
- (instancetype)init {
  self = [super init];
  if (self) { _receipts = [NSMutableDictionary dictionary]; _creates = [NSMutableArray array]; _resolves = [NSMutableArray array]; }
  return self;
}
- (NSDictionary *)descriptor:(NSString *)workspaceID readable:(BOOL)readable {
  return @{@"schema_version": @2, @"workspace_id": workspaceID,
    @"display_name": @"默认工作空间", @"binding_revision": @1, @"origin": @"rish_created",
    @"status": @"ok", @"created_at": @"2026-10-15T00:00:00.000Z", @"last_opened_at": @"2026-10-15T00:00:00.000Z",
    @"capabilities": @{@"read": @(readable), @"write": @(readable && !self.unwritable),
      @"git": @(readable), @"project_context": @(readable), @"files_visible": @YES}};
}
- (void)createWorkspaceRequest:(id)request resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject {
  NSCAssert([request[@"operation_id"] isEqual:self.preferences.values[@"identity_v1"][@"pending_operation_id"]],
    @"Native create may only run after its exact operation ID is checkpointed");
  [self.creates addObject:request];
  NSString *operation = request[@"operation_id"];
  if (self.receipts[operation] == nil)
    self.receipts[operation] = [self descriptor:NSUUID.UUID.UUIDString.lowercaseString readable:YES];
  if (self.failAfterCreate) { self.failAfterCreate = NO; reject(@"E_WORKSPACE_IO", @"Interrupted", nil); return; }
  if (self.failCheckpointAfterCreate) { self.failCheckpointAfterCreate = NO; self.preferences.failNextSync = YES; }
  resolve(self.receipts[operation]);
}
- (void)resolveWorkspaceRequest:(id)request resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject {
  [self.resolves addObject:request];
  if (self.missing) { reject(@"E_WORKSPACE_NOT_FOUND", @"Missing", nil); return; }
  BOOL readable = request[@"expected_binding_revision"] != NSNull.null;
  NSArray *required = readable ? @[@"read", @"write"] : @[];
  NSCAssert([request[@"required_capabilities"] isEqual:required],
    @"Resolution must first probe metadata, then request read/write at its binding revision");
  resolve(@{@"schema_version": @1, @"disposition": @"direct",
    @"workspace": [self descriptor:request[@"workspace_id"] readable:readable]});
}
@end

static NSUInteger checks;
static void Check(BOOL condition, NSString *message) { checks++; NSCAssert(condition, @"%@", message); }
static NSDictionary *Ensure(ShellWorkspaceModule *module, NSDictionary *options) {
  __block NSDictionary *reply;
  dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
  [module ensureDefaultWithOptions:options resolver:^(id value) {
    reply = @{@"value": value}; dispatch_semaphore_signal(semaphore);
  } rejecter:^(NSString *code, NSString *message, NSError *error) {
    reply = @{@"error": code}; dispatch_semaphore_signal(semaphore);
  }];
  Check(dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0,
    @"Every request must settle");
  return reply;
}
static ShellWorkspaceModule *Module(RishTestPreferences *preferences, RishTestWorkspaces *backend) {
  backend.preferences = preferences;
  return [[ShellWorkspaceModule alloc] initWithDefaults:preferences backend:backend
    clock:^NSDate *{ return [NSDate dateWithTimeIntervalSince1970:2000000000]; }];
}

int main(void) {
  @autoreleasepool {
    RishTestPreferences *concurrentPreferences = [RishTestPreferences new];
    RishTestWorkspaces *concurrentBackend = [RishTestWorkspaces new];
    NSArray *concurrentModules = @[Module(concurrentPreferences, concurrentBackend),
                                  Module(concurrentPreferences, concurrentBackend)];
    NSMutableArray *concurrentReplies = [NSMutableArray array];
    dispatch_group_t group = dispatch_group_create();
    for (NSUInteger index = 0; index < 8; ++index) {
      dispatch_group_enter(group);
      [concurrentModules[index % 2] ensureDefaultWithOptions:@{@"display_name": @"默认工作空间"}
        resolver:^(id value) { [concurrentReplies addObject:value]; dispatch_group_leave(group); }
        rejecter:^(NSString *code, NSString *message, NSError *error) {
          [concurrentReplies addObject:code]; dispatch_group_leave(group);
        }];
    }
    Check(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0 &&
      concurrentReplies.count == 8, @"Concurrent ensure requests must each settle once");
    NSSet *identities = [NSSet setWithArray:[concurrentReplies valueForKey:@"workspace_id"]];
    Check(identities.count == 1 && concurrentBackend.receipts.count == 1,
      @"Concurrent service instances checkpoint one operation and share its workspace");
    NSDictionary *options = @{@"display_name": @"默认工作空间"};
    RishTestPreferences *preferences = [RishTestPreferences new];
    RishTestWorkspaces *backend = [RishTestWorkspaces new];
    ShellWorkspaceModule *module = Module(preferences, backend);
    NSDictionary *first = Ensure(module, options)[@"value"];
    Check(first != nil && backend.creates.count == 1 && backend.resolves.count == 2,
      @"Initial ensure creates one workspace and verifies operational capabilities");
    Check([preferences.values[@"identity_v1"][@"workspace_id"] isEqual:first[@"workspace_id"]] &&
      preferences.values[@"identity_v1"][@"pending_operation_id"] == nil,
      @"Success retains permanent identity and clears the pending operation");
    Check([Ensure(module, @{@"display_name": @"Default workspace"})[@"value"][@"workspace_id"] isEqual:first[@"workspace_id"]] &&
      backend.creates.count == 1, @"Locale/display-name changes must not create or adopt a different workspace");
    module = Module(preferences, backend);
    Check([Ensure(module, options)[@"value"][@"workspace_id"] isEqual:first[@"workspace_id"]] &&
      backend.creates.count == 1, @"A restarted service resolves the durable workspace identity");
    backend.missing = YES;
    Check([Ensure(module, options)[@"error"] isEqual:@"E_WORKSPACE_NOT_FOUND"] && backend.creates.count == 1 &&
      [preferences.values[@"identity_v1"][@"workspace_id"] isEqual:first[@"workspace_id"]],
      @"A deleted default workspace is an error, never permission to create a replacement");
    backend.missing = NO; backend.unwritable = YES;
    Check([Ensure(module, options)[@"error"] isEqual:@"E_WORKSPACE_CAPABILITY"],
      @"Default identity without write authority cannot become the active root");

    for (NSNumber *checkpointFailure in @[@NO, @YES]) {
      preferences = [RishTestPreferences new]; backend = [RishTestWorkspaces new];
      backend.failAfterCreate = !checkpointFailure.boolValue;
      backend.failCheckpointAfterCreate = checkpointFailure.boolValue;
      module = Module(preferences, backend);
      Check(Ensure(module, options)[@"error"] != nil, @"Injected interruption must be reported");
      NSDictionary *pending = preferences.values[@"identity_v1"];
      Check(pending[@"pending_operation_id"] != nil && pending[@"workspace_id"] == nil,
        @"An interrupted create or failed success checkpoint retains the original pending operation");
      NSDictionary *retry = Ensure(Module(preferences, backend), @{@"display_name": @"Default workspace"})[@"value"];
      Check(retry != nil && backend.receipts.count == 1 && backend.creates.count == 2 &&
        [backend.creates[0] isEqual:backend.creates[1]],
        @"Restart retries the identical operation and original localized name without creating a duplicate");
    }
    preferences = [RishTestPreferences new]; backend = [RishTestWorkspaces new];
    preferences.failNextSync = YES;
    Check([Ensure(Module(preferences, backend), options)[@"error"] isEqual:@"E_DEFAULT_WORKSPACE_PERSISTENCE"] &&
      backend.creates.count == 0, @"Creation never begins when the pending checkpoint cannot persist");
    preferences.values[@"identity_v1"] = @{@"schema_version": @1,
      @"pending_operation_id": NSUUID.UUID.UUIDString.lowercaseString, @"pending_display_name": @"默认工作空间",
      @"pending_started_at": @(2000000000 - 30 * 24 * 60 * 60)};
    Check([Ensure(Module(preferences, backend), options)[@"error"] isEqual:@"E_DEFAULT_WORKSPACE_RECOVERY_REQUIRED"] &&
      backend.creates.count == 0 && preferences.values[@"identity_v1"][@"pending_operation_id"] != nil,
      @"Expired receipt history requires recovery, never a new native create");
    preferences.values[@"identity_v1"] = @{@"schema_version": @1, @"workspace_id": @"corrupt"};
    Check([Ensure(Module(preferences, backend), options)[@"error"] isEqual:@"E_DEFAULT_WORKSPACE_RECOVERY_REQUIRED"] &&
      backend.creates.count == 0, @"Corrupt identity cannot silently reset the default");
    Check([Ensure(module, @{@"display_name": @"../bad"})[@"error"] isEqual:@"E_WORKSPACE_INVALID"],
      @"Invalid names cannot poison the pending identity");
    Check([Ensure(module, @{@"display_name": @"Default", @"path": @"/tmp"})[@"error"] isEqual:@"E_WORKSPACE_INVALID"],
      @"No caller-selected directory crosses the default workspace API");
    for (NSString *invalid in @[@"RÍSH Wórkspáces", @"a\u200bb", @"Cafe\u0301", @" padded "]) {
      Check([Ensure(module, @{@"display_name": invalid})[@"error"] isEqual:@"E_WORKSPACE_INVALID"],
        @"Default workspace names use the shared policy and retain canonical journal request bytes");
    }
    printf("PASS: %lu default-workspace identity checks, persistence before create, restart/retry, authority and receipt expiry\n",
      (unsigned long)checks);
  }
  return 0;
}
