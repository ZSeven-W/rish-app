// Native bridge integration with real Rust policy, coordinator, URLSession and
// loopback HTTP. Only Keychain reads are substituted with synthetic test bytes.
#define main ExistingCustomDiscoverySuiteMain
#define DSHCodexChatUsesSubscription ExistingCustomDiscoveryNoSubscription
#include "CustomProviderDiscoveryHostTests.mm"
#undef DSHCodexChatUsesSubscription
#undef main
#import <Security/Security.h>
#import "RishHarnessCatalog.h"
#import "SessionWorkspaceCoordinator.h"
#import "RishNative/RishNativeModule.h"

static NSMutableDictionary<NSString *, NSData *> *syntheticVault;
static NSMutableArray<NSString *> *keychainReads;
static NSUInteger subscriptionCredentialReads;

// A subscription may be selected, but the API catalog must not consume it.
extern "C" BOOL DSHCodexChatUsesSubscription(void) { return YES; }

static OSStatus TestSecItemCopyMatching(CFDictionaryRef rawQuery, CFTypeRef *result) {
  NSDictionary *query = (__bridge NSDictionary *)rawQuery;
  NSString *account = query[(__bridge id)kSecAttrAccount];
  Check([query[(__bridge id)kSecClass] isEqual:(__bridge id)kSecClassGenericPassword] &&
    [query[(__bridge id)kSecAttrService] isEqual:@"test.rish.api-model-keys"] &&
    [query[(__bridge id)kSecReturnData] isEqual:@YES], @"API discovery requests only its captured Keychain data");
  NSData *data;
  @synchronized(syntheticVault) {
    [keychainReads addObject:account ?: @"missing-account"];
    data = syntheticVault[account];
  }
  if (!data) return errSecItemNotFound;
  if (result) *result = CFBridgingRetain(data);
  return errSecSuccess;
}

@interface LocalRuntimeModule : NSObject
@property(nonatomic) BOOL blocked;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *generations;
@property(nonatomic, strong) DSHCustomProviderModelDiscovery *customProviderDiscovery;
@property(nonatomic, copy) NSString *customProviderDiscoveryId;
@property(nonatomic, copy) NSString *customProviderDiscoveryOperationId;
- (BOOL)providerConfigurationCanChange;
- (NSMutableDictionary *)keychainQueryForAccount:(NSString *)slot;
- (NSUInteger)credentialGenerationForSlot:(NSString *)slot;
- (NSString *)credentialForAccount:(NSString *)slot generation:(NSUInteger *)generation;
- (void)listProviderModelsWithResolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject;
- (void)saveProviderModels:(NSDictionary *)request resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject;
- (void)discoverProviderModels:(NSDictionary *)request resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject;
- (void)cancelProviderModelDiscovery:(NSDictionary *)request resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject;
@end

@implementation LocalRuntimeModule
- (instancetype)init {
  if ((self = [super init])) _generations = [NSMutableDictionary dictionary];
  return self;
}
- (BOOL)providerConfigurationCanChange {
  return !self.blocked && !self.customProviderDiscovery.isRunning;
}
- (NSMutableDictionary *)keychainQueryForAccount:(NSString *)slot {
  NSString *account = DSHEffectiveCredentialAccount(slot);
  if (!account) return nil;
  return [@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
    (__bridge id)kSecAttrService:@"test.rish.api-model-keys",
    (__bridge id)kSecAttrAccount:account} mutableCopy];
}
- (NSUInteger)credentialGenerationForSlot:(NSString *)slot {
  return [self.generations[slot] unsignedIntegerValue];
}
- (NSString *)credentialForAccount:(NSString *)slot generation:(NSUInteger *)generation {
  subscriptionCredentialReads++;
  if (generation) *generation = [self credentialGenerationForSlot:slot];
  return @"synthetic-subscription-token-never-for-api-origin";
}
#define SecItemCopyMatching TestSecItemCopyMatching
#include "LocalRuntimeProviderModels.inc"
#undef SecItemCopyMatching
@end

@interface BridgeCall : NSObject
@property(nonatomic, strong) dispatch_semaphore_t completed;
@property(nonatomic, strong) id result;
@property(nonatomic, copy) NSString *errorCode;
@property(nonatomic) NSUInteger count;
@end
@implementation BridgeCall
@end

static BridgeCall *Invoke(LocalRuntimeModule *runtime, NSString *operation, NSDictionary *request) {
  BridgeCall *call = [BridgeCall new]; call.completed = dispatch_semaphore_create(0);
  RishResolveBlock resolve = ^(id result) {
    call.result = result; call.count++; dispatch_semaphore_signal(call.completed);
  };
  RishRejectBlock reject = ^(NSString *code, NSString *message, NSError *error) {
    call.errorCode = code; call.count++; dispatch_semaphore_signal(call.completed);
  };
  if ([operation isEqual:@"list"]) [runtime listProviderModelsWithResolver:resolve rejecter:reject];
  else if ([operation isEqual:@"save"]) [runtime saveProviderModels:request resolver:resolve rejecter:reject];
  else if ([operation isEqual:@"fetch"]) [runtime discoverProviderModels:request resolver:resolve rejecter:reject];
  else if ([operation isEqual:@"cancel"]) [runtime cancelProviderModelDiscovery:request resolver:resolve rejecter:reject];
  else Check(NO, @"Known test operation");
  return call;
}
static void Settled(BridgeCall *call, NSString *error) {
  Check(Wait(call.completed), @"Production bridge completes its asynchronous call");
  Check(call.count == 1, @"Bridge resolves or rejects exactly once");
  if (error) Check(call.result == nil && [call.errorCode isEqual:error],
    [@"Bridge returns its fixed error: " stringByAppendingString:error]);
  else Check(call.result != nil && call.errorCode == nil, @"Bridge returns a successful value");
}
static NSDictionary *FetchRequest(NSString *harness, NSDictionary *profile) {
  return @{@"schema_version":@1, @"harness_id":harness,
    @"operation_id":NSUUID.UUID.UUIDString.lowercaseString, @"expected_profile":profile};
}
static NSDictionary *CancelRequest(NSDictionary *request) {
  return @{@"schema_version":@1, @"harness_id":request[@"harness_id"], @"operation_id":request[@"operation_id"]};
}
static NSDictionary *BuiltinConfiguration(LoopbackServer *server, NSString *harness, NSString *protocol, NSString *auth) {
  NSString *suffix = [protocol isEqual:@"messages"] ? @"messages" :
    ([protocol isEqual:@"responses"] ? @"responses" : @"chat/completions");
  NSDictionary *raw = @{@"schema_version":@1, @"harness_id":harness, @"name":@"API fixture",
    @"endpoint_url":[NSString stringWithFormat:@"http://127.0.0.1:%u/provider/%@/v1/%@",server.port,harness,suffix],
    @"protocol":protocol, @"auth_type":auth, @"send_reasoning":@NO, @"full_url":@YES, @"model_mappings":@{}};
  NSDictionary *profile = [DSHProviderConfigurationStore.sharedStore saveConfiguration:raw error:nil];
  Check(profile != nil, @"A built-in provider saves its native normalized profile");
  return profile;
}
static NSString *PutKey(NSString *harness, NSString *secret) {
  NSString *account = DSHEffectiveCredentialAccount(DSHCredentialAccountForHarnessId(harness));
  Check(account != nil, @"A built-in provider retains a distinct effective API key account");
  @synchronized(syntheticVault) { syntheticVault[account] = [secret dataUsingEncoding:NSUTF8StringEncoding]; }
  return account;
}
static NSDictionary *ProviderRows(NSDictionary *registry, NSString *harness) {
  for (NSDictionary *provider in registry[@"providers"]) if ([provider[@"harness_id"] isEqual:harness]) return provider;
  return nil;
}

static void CatalogBridgeCases(LocalRuntimeModule *runtime) {
  BridgeCall *listed = Invoke(runtime,@"list",nil); Settled(listed,nil);
  Check([listed.result[@"providers"] count] == 4 && [listed.result[@"revision"] isEqual:@0], @"Missing registry lists four empty provider catalogs");
  for (NSDictionary *provider in listed.result[@"providers"])
    Check([provider[@"models"] count] == 0, @"Built-in historical models do not populate visible defaults");
  NSDictionary *row = @{@"id":@"bridge-dynamic-model",@"name":@"Dynamic API model",@"supports_images":@YES};
  NSDictionary *save = @{@"schema_version":@1,@"harness_id":@"dsh",@"expected_revision":@0,@"models":@[row]};
  BridgeCall *saved = Invoke(runtime,@"save",save); Settled(saved,nil);
  Check([ProviderRows(saved.result,@"dsh")[@"models"] isEqual:@[row]] &&
    [DSHHarnessIdForModel(row[@"id"]) isEqual:@"dsh"] && DSHProviderModelIsActive(row[@"id"]),
    @"Production save dispatch registers a previously unknown raw ID with its explicit provider");
  BridgeCall *retry = Invoke(runtime,@"save",save); Settled(retry,nil);
  Check([retry.result isEqual:saved.result], @"An exact catalog retry does not create a second revision");
  NSDictionary *before = DSHProviderModelCatalog();
  NSMutableDictionary *conflict = [save mutableCopy]; conflict[@"harness_id"] = @"codex"; conflict[@"expected_revision"] = before[@"revision"];
  BridgeCall *rejected = Invoke(runtime,@"save",conflict); Settled(rejected,@"E_MODEL_CATALOG_INVALID");
  Check([DSHProviderModelCatalog() isEqual:before], @"A second provider cannot steal an established model identity");
  NSMutableDictionary *retire = [save mutableCopy]; retire[@"models"] = @[]; retire[@"expected_revision"] = before[@"revision"];
  BridgeCall *retired = Invoke(runtime,@"save",retire); Settled(retired,nil);
  Check([ProviderRows(retired.result,@"dsh")[@"models"] count] == 0 &&
    [ProviderRows(retired.result,@"dsh")[@"retired_models"] isEqual:@[row]] &&
    !DSHProviderModelIsActive(row[@"id"]) && [DSHHarnessIdForModel(row[@"id"]) isEqual:@"dsh"],
    @"Retiring a choice retains its historical provider mapping");
  NSMutableDictionary *stale = [save mutableCopy]; stale[@"models"] = @[@{@"id":@"stale-new",@"name":@"Stale",@"supports_images":@NO}];
  BridgeCall *staleCall = Invoke(runtime,@"save",stale); Settled(staleCall,@"E_MODEL_CATALOG_INVALID");
  Check([DSHProviderModelCatalog() isEqual:retired.result], @"Stale saves preserve the current catalog");
}

static void DialectBridgeCases(LocalRuntimeModule *runtime, LoopbackServer *server) {
  NSArray *harnesses = @[@"dsh",@"claude-code",@"codex",@"glm"];
  NSArray *protocols = @[@"chat-completions",@"messages",@"responses",@"messages"];
  NSArray *auth = @[@"bearer",@"x-api-key",@"bearer",@"x-api-key"];
  NSMutableSet *accounts = [NSMutableSet set];
  for (NSUInteger i=0;i<harnesses.count;i++) {
    NSDictionary *profile = BuiltinConfiguration(server,harnesses[i],protocols[i],auth[i]);
    NSString *secret = [NSString stringWithFormat:@"synthetic-api-key-%lu",(unsigned long)i];
    [accounts addObject:PutKey(harnesses[i],secret)];
    NSDictionary *before = DSHProviderModelCatalog(); NSUInteger hits = server.captured.count;
    Reply(server,Page(@[[NSString stringWithFormat:@"discovered-future-%lu",(unsigned long)i]],NO));
    NSDictionary *request = FetchRequest(harnesses[i],profile);
    BridgeCall *call = Invoke(runtime,@"fetch",request); Settled(call,nil);
    NSDictionary *sent = server.captured.lastObject;
    Check(server.captured.count == hits+1 && [sent[@"method"] isEqual:@"GET"] &&
      [sent[@"path"] isEqual:[NSString stringWithFormat:@"/provider/%@/v1/models",harnesses[i]]],
      @"Each built-in API provider derives its own same-origin models path");
    NSString *header = [auth[i] isEqual:@"bearer"] ? @"authorization" : @"x-api-key";
    NSString *expected = [auth[i] isEqual:@"bearer"] ? [@"Bearer " stringByAppendingString:secret] : secret;
    Check([sent[@"headers"][header] isEqual:expected] && subscriptionCredentialReads == 0,
      @"API model discovery sends its own captured API key, never the subscription credential accessor");
    if ([protocols[i] isEqual:@"messages"])
      Check([sent[@"headers"][@"anthropic-version"] isEqual:@"2023-06-01"], @"Messages catalog requests retain the protocol version");
    Check([call.result[@"harness_id"] isEqual:harnesses[i]] && [call.result[@"operation_id"] isEqual:request[@"operation_id"]] &&
      [call.result[@"models"] count] == 1, @"Bridge returns the exact provider/operation identity and validated candidates");
    Check([DSHProviderModelCatalog() isEqual:before], @"Fetching candidates never changes saved model choices");
    Check(runtime.customProviderDiscovery == nil, @"Settled discovery releases the native reservation");
  }
  Check(accounts.count == 4, @"Four API provider credential accounts remain independent");
}

static void BoundaryBridgeCases(LocalRuntimeModule *runtime, LoopbackServer *server) {
  NSDictionary *profile = [DSHProviderConfigurationStore.sharedStore configurationForHarness:@"codex"];
  NSString *account = DSHEffectiveCredentialAccount(DSHCredentialAccountForHarnessId(@"codex"));
  NSData *secret = syntheticVault[account]; NSUInteger hits = server.captured.count;
  [syntheticVault removeObjectForKey:account];
  BridgeCall *missing = Invoke(runtime,@"fetch",FetchRequest(@"codex",profile)); Settled(missing,@"E_PROVIDER_MODEL_DISCOVERY_CREDENTIAL");
  Check(server.captured.count == hits && subscriptionCredentialReads == 0, @"Missing API key refuses before HTTP even when subscription credentials exist");
  syntheticVault[account] = secret;
  runtime.blocked = YES;
  BridgeCall *busy = Invoke(runtime,@"fetch",FetchRequest(@"codex",profile)); Settled(busy,@"E_COMPLETION_BUSY");
  NSDictionary *registry = DSHProviderModelCatalog();
  BridgeCall *saveBusy = Invoke(runtime,@"save",@{@"schema_version":@1,@"harness_id":@"codex",@"expected_revision":registry[@"revision"],@"models":@[]});
  Settled(saveBusy,@"E_COMPLETION_BUSY");
  Check(server.captured.count == hits && [DSHProviderModelCatalog() isEqual:registry], @"Busy native attempts permit neither discovery nor catalog mutation");
  runtime.blocked = NO;
  NSMutableDictionary *wrong = [profile mutableCopy]; wrong[@"name"] = @"Stale profile";
  BridgeCall *stale = Invoke(runtime,@"fetch",FetchRequest(@"codex",wrong)); Settled(stale,@"E_PROVIDER_CONFIGURATION_CHANGED");
  Check(server.captured.count == hits, @"Stale source configuration cannot make an authenticated request");
}

static void RotationBridgeCases(LocalRuntimeModule *runtime, LoopbackServer *server) {
  for (NSUInteger mode=0;mode<4;mode++) {
    NSDictionary *profile = BuiltinConfiguration(server,@"dsh",@"chat-completions",@"bearer");
    NSString *account = PutKey(@"dsh",@"synthetic-rotation-key");
    LoopbackReply *reply = Reply(server,Page(@[@"late-model"],NO)); reply.releaseResponse = dispatch_semaphore_create(0);
    BridgeCall *call = Invoke(runtime,@"fetch",FetchRequest(@"dsh",profile));
    Check(Wait(reply.received), @"A real catalog fetch is held while its source changes");
    if (mode == 0) { NSMutableDictionary *changed = [profile mutableCopy]; changed[@"name"] = @"Changed metadata";
      Check([DSHProviderConfigurationStore.sharedStore saveConfiguration:changed error:nil] != nil,@"Profile rotation is a real native metadata write"); }
    if (mode == 1) { runtime.generations[@"DEEPSEEK_API_KEY"] = @([runtime credentialGenerationForSlot:@"DEEPSEEK_API_KEY"]+1); }
    if (mode == 2) { @synchronized(syntheticVault) { syntheticVault[account] = [@"synthetic-new-key" dataUsingEncoding:NSUTF8StringEncoding]; } }
    if (mode == 3) { NSDictionary *registry = DSHProviderModelCatalog();
      Check(DSHSaveProviderModelCatalog(@{@"schema_version":@1,@"harness_id":@"dsh",@"expected_revision":registry[@"revision"],
        @"models":@[@{@"id":@"concurrent-choice",@"name":@"Concurrent",@"supports_images":@NO}]},nil) != nil,
        @"Catalog revision changes through the real shared reducer"); }
    dispatch_semaphore_signal(reply.releaseResponse); Settled(call,@"E_PROVIDER_CONFIGURATION_CHANGED");
    Check(runtime.customProviderDiscovery == nil, @"Changed-source results do not keep a discovery reservation");
  }
}

static void CancellationBridgeCases(LocalRuntimeModule *runtime, LoopbackServer *server) {
  NSDictionary *profile = BuiltinConfiguration(server,@"claude-code",@"messages",@"x-api-key");
  PutKey(@"claude-code",@"synthetic-cancel-key");
  NSDictionary *oldRequest = FetchRequest(@"claude-code",profile);
  Reply(server,Page(@[@"old-operation"],NO)); BridgeCall *old = Invoke(runtime,@"fetch",oldRequest); Settled(old,nil);
  LoopbackReply *reply = Reply(server,Page(@[@"current-operation"],NO)); reply.releaseResponse = dispatch_semaphore_create(0);
  NSDictionary *currentRequest = FetchRequest(@"claude-code",profile);
  BridgeCall *current = Invoke(runtime,@"fetch",currentRequest); Check(Wait(reply.received),@"New operation is in flight");
  BridgeCall *oldCancel = Invoke(runtime,@"cancel",CancelRequest(oldRequest)); Settled(oldCancel,nil);
  Check([oldCancel.result[@"status"] isEqual:@"idle"] && runtime.customProviderDiscovery.isRunning,
    @"A delayed old cancellation cannot stop a newer fetch for the same provider");
  NSMutableDictionary *foreign = [CancelRequest(currentRequest) mutableCopy]; foreign[@"harness_id"] = @"dsh";
  BridgeCall *foreignCancel = Invoke(runtime,@"cancel",foreign); Settled(foreignCancel,nil);
  Check([foreignCancel.result[@"status"] isEqual:@"idle"] && runtime.customProviderDiscovery.isRunning,
    @"A different provider cannot cancel this fetch even with its operation ID");
  NSUInteger hits = server.captured.count;
  BridgeCall *overlap = Invoke(runtime,@"fetch",FetchRequest(@"dsh",[DSHProviderConfigurationStore.sharedStore configurationForHarness:@"dsh"]));
  Settled(overlap,@"E_COMPLETION_BUSY"); Check(server.captured.count == hits,@"A second discovery cannot overlap the reserved native operation");
  dispatch_semaphore_signal(reply.releaseResponse); Settled(current,nil);
  reply = Reply(server,Page(@[@"cancelled-operation"],NO)); reply.releaseResponse = dispatch_semaphore_create(0);
  NSDictionary *cancelRequest = FetchRequest(@"claude-code",profile);
  BridgeCall *cancelled = Invoke(runtime,@"fetch",cancelRequest); Check(Wait(reply.received),@"Matching cancellation has an active request");
  BridgeCall *cancel = Invoke(runtime,@"cancel",CancelRequest(cancelRequest)); Settled(cancel,nil);
  Check([cancel.result[@"status"] isEqual:@"cancelled"],@"Matching provider and operation cancel exactly that fetch");
  dispatch_semaphore_signal(reply.releaseResponse); Settled(cancelled,@"E_PROVIDER_MODEL_DISCOVERY_CANCELLED");
  Check(runtime.customProviderDiscovery == nil && subscriptionCredentialReads == 0,@"Cancellation clears state without reading subscription credentials");
}

int main(void) {
  @autoreleasepool {
    NSString *suite = [@"rish-builtin-model-bridge-" stringByAppendingString:NSUUID.UUID.UUIDString];
    testDefaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    syntheticVault = [NSMutableDictionary dictionary]; keychainReads = [NSMutableArray array];
    Method standard = class_getClassMethod(NSUserDefaults.class,@selector(standardUserDefaults));
    IMP original = method_setImplementation(standard,(IMP)IsolatedDefaults);
    LoopbackServer *server = [LoopbackServer new]; Check([server start],@"Bridge fixture binds only local loopback");
    @try {
      LocalRuntimeModule *runtime = [LocalRuntimeModule new];
      CatalogBridgeCases(runtime); DialectBridgeCases(runtime,server); BoundaryBridgeCases(runtime,server);
      RotationBridgeCases(runtime,server); CancellationBridgeCases(runtime,server);
      Check(subscriptionCredentialReads == 0 && keychainReads.count > 0,@"The complete native bridge suite uses API Keychain reads only");
    } @finally {
      [server stop]; [testDefaults removePersistentDomainForName:suite];
      method_setImplementation(standard,original); [syntheticVault removeAllObjects];
    }
    printf("Built-in provider model bridge checks passed: %lu\n",(unsigned long)checks);
  }
  return 0;
}
