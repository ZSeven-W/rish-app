#pragma once
#import <Foundation/Foundation.h>

@interface RishNativeBridge : NSObject
- (id)moduleForName:(NSString *)name lazilyLoadIfNecessary:(BOOL)load;
@end
