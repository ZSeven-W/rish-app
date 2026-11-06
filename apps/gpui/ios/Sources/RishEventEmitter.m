#import <RishNative/RishEventEmitter.h>
#import "RishGPUIBridge.h"

@implementation RishEventEmitter
- (NSArray<NSString *> *)supportedEvents { return @[]; }
- (void)startObserving {}
- (void)stopObserving {}
- (void)invalidate { [self stopObserving]; self.bridge = nil; }
- (void)sendEventWithName:(NSString *)name body:(id)body {
  if ([[self supportedEvents] containsObject:name]) RishGPUIEmitEvent(name, body);
}
@end
