#import <Foundation/Foundation.h>
#import <RishNative/RishEventEmitter.h>
#import "RishGPUIBridge.h"

static NSMutableDictionary *replies;
static dispatch_semaphore_t replyReady;
static NSUInteger replyCount;
static NSString *eventName;
static id eventPayload;
static char queueKey;

void rish_gpui_host_reply(uint64_t requestID, const char *json, bool isError) {
  NSData *data = [[NSString stringWithUTF8String:json] dataUsingEncoding:NSUTF8StringEncoding];
  id value = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:nil];
  @synchronized (replies) {
    replies[@(requestID)] = @{@"error": @(isError), @"value": value ?: NSNull.null};
    replyCount += 1;
  }
  dispatch_semaphore_signal(replyReady);
}

void rish_gpui_host_event(const char *name, const char *json) {
  eventName = [NSString stringWithUTF8String:name];
  NSData *data = [[NSString stringWithUTF8String:json] dataUsingEncoding:NSUTF8StringEncoding];
  eventPayload = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}

@interface LocalRuntimeModule : RishEventEmitter
@property(nonatomic, copy) NSString *activeCompletion;
@property(nonatomic) NSUInteger nextSequence;
@end
@implementation LocalRuntimeModule
RISH_NATIVE_MODULE(LocalRuntime)
- (dispatch_queue_t)methodQueue {
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    queue = dispatch_queue_create("rish.gpui.bridge-test", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(queue, &queueKey, &queueKey, NULL);
  });
  return queue;
}
- (NSArray *)supportedEvents { return @[@"completionChunk"]; }
RISH_NATIVE_METHOD(buildInfo, buildInfoWithResolver:(RishResolveBlock)resolve
    rejecter:(RishRejectBlock)reject) {
  NSCAssert(dispatch_get_specific(&queueKey) == &queueKey, @"Native queue must be honored");
  resolve(@{@"runtime": @"native", @"queue": @YES});
  reject(@"duplicate", @"Must be ignored", nil);
}
RISH_NATIVE_METHOD(providerConfiguration, providerConfigurationForHarness:(NSString *)harness
    resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  resolve(harness);
}
RISH_NATIVE_METHOD(dshModelCatalog, dshModelCatalogWithResolver:(RishResolveBlock)resolve
    rejecter:(RishRejectBlock)reject) {
  resolve(NSDate.date); // Invalid JSON must settle with a structured error.
}
RISH_NATIVE_METHOD(listProviderModels, listProviderModelsWithResolver:(RishResolveBlock)resolve
    rejecter:(RishRejectBlock)reject) { resolve(@{@"schema_version":@1, @"revision":@0, @"providers":@[]}); }
RISH_NATIVE_METHOD(saveProviderModels, saveProviderModels:(NSDictionary *)request
    resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) { resolve(request); }
RISH_NATIVE_METHOD(discoverProviderModels, discoverProviderModels:(NSDictionary *)request
    resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) { resolve(request); }
RISH_NATIVE_METHOD(cancelProviderModelDiscovery, cancelProviderModelDiscovery:(NSDictionary *)request
    resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) { resolve(request); }
RISH_NATIVE_METHOD(completeV2Stream, completeV2StreamEnvelopeJSON:(NSString *)request
    resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  if (self.activeCompletion != nil || request.integerValue != self.nextSequence) {
    reject(@"out_of_order", @"Completion arrived out of order", nil);
    return;
  }
  self.activeCompletion = request;
  self.nextSequence += 1;
  resolve(@"reserved");
}
RISH_NATIVE_METHOD(cancelCompletion, cancelCompletionRequestId:(NSString *)request
    resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  if (![self.activeCompletion isEqual:request]) {
    reject(@"out_of_order", @"Cancellation arrived before completion reservation", nil);
    return;
  }
  self.activeCompletion = nil;
  resolve(@"cancelled");
}
// Deliberately different from the compiled registry: must never be invoked.
- (void)bootstrapWithResolver:(id)resolve rejecter:(id)reject {
  NSCAssert(NO, @"Signature mismatch must be rejected");
}
@end

@interface SessionSnapshotsModule : NSObject
@end
@implementation SessionSnapshotsModule
RISH_NATIVE_MODULE(SessionSnapshots)
RISH_NATIVE_SYNC(sessionCandidateDigest:(id)candidate) {
  return [@"digest:" stringByAppendingString:candidate];
}
@end

@interface LocalProjectsModule : NSObject
@end
@implementation LocalProjectsModule
RISH_NATIVE_MODULE(LocalProjects)
RISH_NATIVE_METHOD(diff, diffForProject:(id)project staged:(BOOL)staged
    contextLines:(NSNumber *)lines resolver:(RishResolveBlock)resolve
    rejecter:(RishRejectBlock)reject) {
  resolve(@{@"staged": @(staged), @"lines": lines});
}
@end

// This stub verifies the reviewed dictionary ABI without requiring UIKit in
// the host executable. Form validation has separate tests against the real FFI.
@interface ShellInputModule : NSObject
@end
@implementation ShellInputModule
RISH_NATIVE_MODULE(ShellInput)
RISH_NATIVE_METHOD(inlineSync, inlineSyncWithOptions:(NSDictionary *)options
    resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) { resolve(options); reject(@"duplicate", @"Ignored", nil); }
RISH_NATIVE_METHOD(inlineWait, inlineWaitWithOptions:(NSDictionary *)options
    resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) { resolve(options); reject(@"duplicate", @"Ignored", nil); }
RISH_NATIVE_METHOD(inlineSnapshot, inlineSnapshotWithOptions:(NSDictionary *)options
    resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) { resolve(options); reject(@"duplicate", @"Ignored", nil); }
RISH_NATIVE_METHOD(inlineClose, inlineCloseWithOptions:(NSDictionary *)options
    resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) { resolve(options); reject(@"duplicate", @"Ignored", nil); }
RISH_NATIVE_METHOD(inlineClearIfUnchanged, inlineClearIfUnchangedWithOptions:(NSDictionary *)options
    resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) { resolve(options); reject(@"duplicate", @"Ignored", nil); }
RISH_NATIVE_METHOD(gitForm, gitFormWithOptions:(NSDictionary *)options
    resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  resolve(options);
  reject(@"duplicate", @"Must be ignored", nil);
}
RISH_NATIVE_METHOD(editFile, editFileWithOptions:(NSDictionary *)options
    resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  resolve(options[@"initial_text"]);
  reject(@"duplicate", @"Must be ignored", nil);
}
RISH_NATIVE_METHOD(name, nameWithOptions:(NSDictionary *)options
    resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  resolve(options);
  reject(@"duplicate", @"Must be ignored", nil);
}
@end

@interface ShellWorkspaceModule : NSObject
@end
@implementation ShellWorkspaceModule
RISH_NATIVE_MODULE(ShellWorkspace)
RISH_NATIVE_METHOD(ensureDefault, ensureDefaultWithOptions:(NSDictionary *)options
    resolver:(RishResolveBlock)resolve rejecter:(RishRejectBlock)reject) {
  resolve(options);
  reject(@"duplicate", @"Must be ignored", nil);
}
@end

static NSDictionary *Request(NSString *module, NSString *method, NSString *args) {
  static uint64_t requestID = 0;
  uint64_t current = ++requestID;
  rish_gpui_host_request(current, module.UTF8String, method.UTF8String, args.UTF8String);
  long timedOut = dispatch_semaphore_wait(replyReady, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
  NSCAssert(timedOut == 0, @"Native request timed out");
  @synchronized (replies) {
    NSDictionary *reply = replies[@(current)];
    NSCAssert(reply != nil, @"Reply request ID must match");
    return reply;
  }
}

static void Error(NSString *module, NSString *method, NSString *args, NSString *code) {
  NSDictionary *reply = Request(module, method, args);
  NSCAssert([reply[@"error"] boolValue], @"Request should fail");
  NSCAssert([reply[@"value"][@"code"] isEqual:code], @"Unexpected error code: %@", reply);
}

int main(void) {
  @autoreleasepool {
    replies = [NSMutableDictionary dictionary];
    replyReady = dispatch_semaphore_create(0);
    NSDictionary *build = Request(@"LocalRuntime", @"buildInfo", @"[]");
    NSCAssert(![build[@"error"] boolValue] && [build[@"value"][@"runtime"] isEqual:@"native"], @"Dispatch");
    NSDictionary *unicode = Request(@"LocalRuntime", @"providerConfiguration", @"[\"中文输入 🚀\"]");
    NSCAssert([unicode[@"value"] isEqual:@"中文输入 🚀"], @"UTF-8 preservation");
    NSDictionary *null = Request(@"LocalRuntime", @"providerConfiguration", @"[null]");
    NSCAssert(null[@"value"] == NSNull.null, @"Null result");
    Error(@"LocalRuntime", @"providerConfiguration", @"[42]", @"host_invalid_arguments");
    Error(@"LocalRuntime", @"buildInfo", @"{}", @"host_invalid_arguments");
    Error(@"LocalRuntime", @"buildInfo", @"[", @"host_invalid_arguments");
    Error(@"LocalRuntime", @"buildInfo", @"[null]", @"host_invalid_arguments");
    Error(@"LocalRuntime", @"bootstrap", @"[]", @"host_signature");
    Error(@"LocalRuntime", @"dshModelCatalog", @"[]", @"host_serialization");
    NSDictionary *providerModels = Request(@"LocalRuntime", @"listProviderModels", @"[]");
    NSCAssert([providerModels[@"value"][@"providers"] isEqual:@[]], @"Provider model catalog no-argument ABI");
    Error(@"LocalRuntime", @"listProviderModels", @"[{}]", @"host_invalid_arguments");
    for (NSString *method in @[@"saveProviderModels", @"discoverProviderModels", @"cancelProviderModelDiscovery"]) {
      NSDictionary *reply = Request(@"LocalRuntime", method, @"[{\"harness_id\":\"codex\",\"name\":\"自定义模型\"}]");
      NSCAssert([reply[@"value"][@"harness_id"] isEqual:@"codex"] && [reply[@"value"][@"name"] isEqual:@"自定义模型"], @"Provider model metadata dictionary ABI");
      Error(@"LocalRuntime", method, @"[42]", @"host_invalid_arguments");
      Error(@"LocalRuntime", method, @"[]", @"host_invalid_arguments");
    }
    Error(@"LocalRuntime", @"valueForKey:", @"[\"credentials\"]", @"host_unknown_method");
    Error(@"NSFileManager", @"defaultManager", @"[]", @"host_unknown_method");
    Error(@"LocalGuest", @"shutdownGuest", @"[]", @"host_module_unavailable");
    Error(@"LocalProjects", @"diff", @"[\"id\",1,3]", @"host_invalid_arguments");
    NSDictionary *diff = Request(@"LocalProjects", @"diff", @"[\"id\",true,3]");
    NSCAssert([diff[@"value"][@"staged"] boolValue], @"BOOL ABI");
    NSDictionary *sync = Request(@"SessionSnapshots", @"sessionCandidateDigest", @"[\"candidate\"]");
    NSCAssert([sync[@"value"] isEqual:@"digest:candidate"], @"Synchronous native export");
    for (NSString *method in @[@"inlineSync", @"inlineWait", @"inlineSnapshot", @"inlineClose", @"inlineClearIfUnchanged"]) {
      NSDictionary *inlineReply = Request(@"ShellInput", method, @"[{\"session_id\":\"测试\"}]");
      NSCAssert([inlineReply[@"value"][@"session_id"] isEqual:@"测试"], @"Inline dictionary ABI");
      Error(@"ShellInput", method, @"[42]", @"host_invalid_arguments");
      Error(@"ShellInput", method, @"[]", @"host_invalid_arguments");
      Error(@"ShellInput", [method stringByAppendingString:@"WithOptions"], @"[{}]", @"host_unknown_method");
    }
    NSDictionary *name = Request(@"ShellInput", @"name", @"[{\"label\":\"名称\"}]");
    NSCAssert([name[@"value"][@"label"] isEqual:@"名称"], @"Name options dictionary ABI");
    Error(@"ShellInput", @"name", @"[42]", @"host_invalid_arguments");
    Error(@"ShellInput", @"name", @"[]", @"host_invalid_arguments");
    Error(@"ShellInput", @"nameWithOptions", @"[{}]", @"host_unknown_method");
    NSDictionary *file = Request(@"ShellInput", @"editFile", @"[{\"initial_text\":\"\"}]");
    NSCAssert([file[@"value"] isEqual:@""], @"Empty file content must survive the dictionary ABI");
    Error(@"ShellInput", @"editFile", @"[42]", @"host_invalid_arguments");
    Error(@"ShellInput", @"editFile", @"[]", @"host_invalid_arguments");
    Error(@"ShellInput", @"editFileWithOptions", @"[{}]", @"host_unknown_method");
    NSDictionary *git = Request(@"ShellInput", @"gitForm", @"[{\"kind\":\"commit\",\"fields\":[{\"label\":\"提交说明\"}]}]");
    NSCAssert([git[@"value"][@"fields"][0][@"label"] isEqual:@"提交说明"], @"Git form dictionary and field array ABI");
    Error(@"ShellInput", @"gitForm", @"[42]", @"host_invalid_arguments");
    Error(@"ShellInput", @"gitForm", @"[]", @"host_invalid_arguments");
    Error(@"ShellInput", @"gitFormWithOptions", @"[{}]", @"host_unknown_method");
    NSDictionary *workspace = Request(@"ShellWorkspace", @"ensureDefault", @"[{\"display_name\":\"默认工作空间\"}]");
    NSCAssert([workspace[@"value"][@"display_name"] isEqual:@"默认工作空间"], @"Default workspace dictionary ABI");
    Error(@"ShellWorkspace", @"ensureDefault", @"[42]", @"host_invalid_arguments");
    Error(@"ShellWorkspace", @"ensureDefault", @"[]", @"host_invalid_arguments");
    Error(@"ShellWorkspace", @"ensureDefaultWithOptions", @"[{}]", @"host_unknown_method");
    RishEventEmitter *emitter = (id)[RishGPUIBridgeShared() moduleForName:@"LocalRuntime" lazilyLoadIfNecessary:NO];
    [emitter sendEventWithName:@"completionChunk" body:@{@"text": @"测试"}];
    NSCAssert([eventName isEqual:@"completionChunk"] && [eventPayload[@"text"] isEqual:@"测试"], @"Events");
    [emitter sendEventWithName:@"privateEvent" body:@{}];
    NSCAssert([eventName isEqual:@"completionChunk"], @"Only declared events");
    // A burst intentionally queues completion/cancellation before any replies.
    // A concurrent ingress executor can enqueue these pairs out of order.
    for (NSUInteger i = 0; i < 128; ++i) {
      NSString *args = [NSString stringWithFormat:@"[\"%lu\"]", (unsigned long)i];
      rish_gpui_host_request(1000 + i * 2, "LocalRuntime", "completeV2Stream", args.UTF8String);
      rish_gpui_host_request(1001 + i * 2, "LocalRuntime", "cancelCompletion", args.UTF8String);
    }
    for (NSUInteger i = 0; i < 256; ++i) {
      NSCAssert(dispatch_semaphore_wait(replyReady, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0,
                @"Ordered request burst timed out");
    }
    for (NSUInteger i = 0; i < 256; ++i) {
      NSCAssert(![replies[@(1000 + i)][@"error"] boolValue], @"Request dispatch order must be preserved");
    }
    NSCAssert(replyCount == 318, @"Exactly one reply per request, got %lu", (unsigned long)replyCount);
    puts("PASS: 318 bridge requests, completion/cancel ordering, once-only settlement, provider model metadata ABI, queues, Unicode, synchronous exports and events");
  }
  return 0;
}
