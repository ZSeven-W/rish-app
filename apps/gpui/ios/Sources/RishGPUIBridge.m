#import "RishGPUIBridge.h"
#import <RishNative/RishNativeBridge.h>
#import <RishNative/RishNativeModule.h>
#import <RishNative/RishEventEmitter.h>
#include <string.h>

#import "RishGPUIExports.h"

static const RishExport *FindExport(NSString *module, NSString *method) {
  for (NSUInteger i = 0; i < sizeof(RishExports) / sizeof(RishExport); ++i) {
    if ([RishExports[i].module isEqual:module] && [RishExports[i].name isEqual:method]) {
      return &RishExports[i];
    }
  }
  return NULL;
}

static NSString *Encode(id value) {
  @try {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value ?: NSNull.null
        options:NSJSONWritingFragmentsAllowed error:nil];
    return data == nil ? nil : [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  } @catch (__unused NSException *exception) {
    return nil;
  }
}

@interface RishReply : NSObject
@property(nonatomic) uint64_t requestID;
@property(nonatomic) BOOL settled;
- (void)send:(id)value error:(BOOL)isError;
- (void)fail:(NSString *)code message:(NSString *)message;
@end

@implementation RishReply
- (void)send:(id)value error:(BOOL)isError {
  @synchronized (self) {
    if (self.settled) return;
    self.settled = YES;
  }
  NSString *json = Encode(value);
  if (json == nil) {
    json = @"{\"code\":\"host_serialization\",\"message\":\"Native result is not JSON.\"}";
    isError = YES;
  }
  rish_gpui_host_reply(self.requestID, json.UTF8String, isError);
}
- (void)fail:(NSString *)code message:(NSString *)message {
  [self send:@{@"code": code ?: @"host_error", @"message": message ?: @"Native operation failed."}
       error:YES];
}
@end

@interface RishNativeBridge ()
@property(nonatomic, strong) NSMutableDictionary<NSString *, id> *modules;
@property(nonatomic, strong) NSMutableDictionary<NSString *, id> *queues;
@end

@implementation RishNativeBridge
- (instancetype)init {
  self = [super init];
  if (self) {
    _modules = [NSMutableDictionary dictionary];
    _queues = [NSMutableDictionary dictionary];
  }
  return self;
}
- (id)moduleForName:(NSString *)name lazilyLoadIfNecessary:(BOOL)load {
  @synchronized (self) {
    if (self.modules[name] != nil || !load) return self.modules[name];
    BOOL allowed = NO;
    for (NSUInteger i = 0; i < sizeof(RishExports) / sizeof(RishExport); ++i) {
      if ([RishExports[i].module isEqual:name]) { allowed = YES; break; }
    }
    if (!allowed) return nil;
    Class<RishNativeModule> cls = NSClassFromString([name stringByAppendingString:@"Module"]);
    if (cls == Nil) return nil;
    __block id module;
    void (^create)(void) = ^{ module = [[(Class)cls alloc] init]; };
    if ([cls respondsToSelector:@selector(requiresMainQueueSetup)] &&
        [cls requiresMainQueueSetup] && !NSThread.isMainThread) {
      dispatch_sync(dispatch_get_main_queue(), create);
    } else {
      create();
    }
    if (module == nil) return nil;
    self.modules[name] = module;
    dispatch_queue_t queue = [module respondsToSelector:@selector(methodQueue)]
        ? [(id<RishNativeModule>)module methodQueue] : nil;
    self.queues[name] = queue ?: dispatch_queue_create(
        [[@"tech.zseven.rish.gpui." stringByAppendingString:name] UTF8String],
        DISPATCH_QUEUE_SERIAL);
    if ([module isKindOfClass:RishEventEmitter.class]) {
      RishEventEmitter *emitter = module;
      emitter.bridge = self;
      // One GPUI event sink lives for the process lifetime. Start on the same
      // module queue before the first exported operation can publish previews.
      dispatch_async(self.queues[name], ^{ [emitter startObserving]; });
    }
    return module;
  }
}
- (dispatch_queue_t)queueForModule:(NSString *)name {
  @synchronized (self) { return self.queues[name]; }
}
@end

RishNativeBridge *RishGPUIBridgeShared(void) {
  static RishNativeBridge *bridge;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ bridge = [RishNativeBridge new]; });
  return bridge;
}

void RishGPUIEmitEvent(NSString *name, id body) {
  NSString *json = Encode(body);
  if (name.length > 0 && json != nil) rish_gpui_host_event(name.UTF8String, json.UTF8String);
}

static BOOL ValidArgument(id value, char type) {
  if (type == 'i') return YES; // The native module validates its own schema.
  if (type == 'b') return [value isKindOfClass:NSNumber.class] &&
      CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
  if (value == NSNull.null) return YES; // ObjC nullable arguments receive nil.
  switch (type) {
    case 's': return [value isKindOfClass:NSString.class];
    case 'd': return [value isKindOfClass:NSDictionary.class];
    case 'a': return [value isKindOfClass:NSArray.class];
    case 'n': return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID();
    default: return NO;
  }
}

static BOOL ValidSignature(NSMethodSignature *signature, const RishExport *entry) {
  NSUInteger count = strlen(entry->types);
  if (signature == nil || signature.numberOfArguments != count + (entry->synchronous ? 2 : 4)) return NO;
  if (strcmp(signature.methodReturnType, entry->synchronous ? "@" : "v") != 0) return NO;
  for (NSUInteger i = 0; i < count; ++i) {
    const char *expected = entry->types[i] == 'b' ? @encode(BOOL) : "@";
    if (strcmp([signature getArgumentTypeAtIndex:i + 2], expected) != 0) return NO;
  }
  if (!entry->synchronous &&
      (strcmp([signature getArgumentTypeAtIndex:count + 2], "@?") != 0 ||
       strcmp([signature getArgumentTypeAtIndex:count + 3], "@?") != 0)) return NO;
  return YES;
}

static void Invoke(id module, const RishExport *entry, NSArray *args, RishReply *reply) {
  @try {
    SEL selector = NSSelectorFromString(entry->selector);
    NSMethodSignature *signature = [module methodSignatureForSelector:selector];
    if (!ValidSignature(signature, entry)) {
      [reply fail:@"host_signature" message:@"Native export signature changed; rebuild the host registry."];
      return;
    }
    NSInvocation *call = [NSInvocation invocationWithMethodSignature:signature];
    call.target = module;
    call.selector = selector;
    for (NSUInteger i = 0; i < args.count; ++i) {
      if (entry->types[i] == 'b') {
        BOOL value = [args[i] boolValue];
        [call setArgument:&value atIndex:i + 2];
      } else {
        id value = args[i];
        if (value == NSNull.null && entry->types[i] != 'i') value = nil;
        [call setArgument:&value atIndex:i + 2];
      }
    }
    RishResolveBlock resolve = ^(id value) { [reply send:value error:NO]; };
    RishRejectBlock reject = ^(NSString *code, NSString *message, NSError *error) {
      [reply fail:code message:message];
    };
    if (!entry->synchronous) {
      [call setArgument:&resolve atIndex:args.count + 2];
      [call setArgument:&reject atIndex:args.count + 3];
    }
    [call retainArguments];
    [call invoke];
    if (entry->synchronous) {
      __unsafe_unretained id value = nil;
      [call getReturnValue:&value];
      [reply send:value error:NO];
    }
  } @catch (__unused NSException *exception) {
    [reply fail:@"host_exception" message:@"Native operation raised an exception."];
  }
}

static dispatch_queue_t IngressQueue(void) {
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    queue = dispatch_queue_create("tech.zseven.rish.gpui.ingress", DISPATCH_QUEUE_SERIAL);
  });
  return queue;
}

void rish_gpui_host_request(uint64_t requestID, const char *moduleName,
                           const char *methodName, const char *argsJSON) {
  @autoreleasepool {
    RishReply *reply = [RishReply new];
    reply.requestID = requestID;
    if (moduleName == NULL || methodName == NULL || argsJSON == NULL ||
        strnlen(moduleName, 128) == 128 || strnlen(methodName, 128) == 128 ||
        strnlen(argsJSON, 32 * 1024 * 1024 + 1) > 32 * 1024 * 1024) {
      [reply fail:@"host_invalid_request" message:@"Native request is missing or too large."];
      return;
    }
    NSString *name = [NSString stringWithUTF8String:moduleName];
    NSString *method = [NSString stringWithUTF8String:methodName];
    const RishExport *entry = FindExport(name, method);
    if (entry == NULL) {
      [reply fail:@"host_unknown_method" message:@"This native method is not exported."];
      return;
    }
    NSData *data = [NSData dataWithBytes:argsJSON length:strlen(argsJSON)];
    id args = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![args isKindOfClass:NSArray.class] || [args count] != strlen(entry->types)) {
      [reply fail:@"host_invalid_arguments" message:@"Expected a positional JSON array with the exported argument count."];
      return;
    }
    for (NSUInteger i = 0; i < [args count]; ++i) {
      if (!ValidArgument(args[i], entry->types[i])) {
        [reply fail:@"host_invalid_arguments" message:@"Native argument type does not match the exported method."];
        return;
      }
    }
    // Preserve call order while routing to the module queues. In particular,
    // completion reservation must reach LocalRuntime before its cancellation.
    // Native initialization and I/O never block GPUI's render thread.
    dispatch_async(IngressQueue(), ^{
      @autoreleasepool {
        @try {
          RishNativeBridge *bridge = RishGPUIBridgeShared();
          id module = [bridge moduleForName:name lazilyLoadIfNecessary:YES];
          if (module == nil) {
            [reply fail:@"host_module_unavailable" message:@"Native module is not linked in this application."];
            return;
          }
          dispatch_async([bridge queueForModule:name], ^{ Invoke(module, entry, args, reply); });
        } @catch (__unused NSException *exception) {
          [reply fail:@"host_initialization" message:@"Native module could not be initialized."];
        }
      }
    });
  }
}
