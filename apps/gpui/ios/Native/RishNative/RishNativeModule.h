#pragma once
#import <Foundation/Foundation.h>

typedef void (^RishResolveBlock)(id result);
typedef void (^RishRejectBlock)(NSString *code, NSString *message, NSError *error);

/// Service declarations for the reviewed native selector registry.
@protocol RishNativeModule <NSObject>
@optional
+ (NSString *)moduleName;
+ (BOOL)requiresMainQueueSetup;
- (dispatch_queue_t)methodQueue;
@end

#define RISH_NATIVE_MODULE(name) + (NSString *)moduleName { return @#name; }
#define RISH_NATIVE_METHOD(name, method) - (void)method
#define RISH_NATIVE_SYNC(method) - (id)method
