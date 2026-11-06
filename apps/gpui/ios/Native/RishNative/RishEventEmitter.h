#pragma once
#import "RishNativeBridge.h"
#import "RishNativeModule.h"

@interface RishEventEmitter : NSObject <RishNativeModule>
@property(nonatomic, weak) RishNativeBridge *bridge;
- (NSArray<NSString *> *)supportedEvents;
- (void)startObserving;
- (void)stopObserving;
- (void)invalidate;
- (void)sendEventWithName:(NSString *)name body:(id)body;
@end
