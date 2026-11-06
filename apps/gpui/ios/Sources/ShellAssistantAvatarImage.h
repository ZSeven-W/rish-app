#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface ShellAssistantAvatarImage : NSObject
// Imports one selected file into the private Assistant-v1/avatars directory.
// The returned relative ID remains valid when iOS relocates the app container.
+ (nullable NSDictionary *)importImageAtURL:(NSURL *)source
                    intoAssistantDirectory:(NSURL *)directory
                                     error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
