#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *const DSHRuntimeEnvironmentErrorDomain;
FOUNDATION_EXPORT NSError *DSHEnvironmentError(NSString *code);
FOUNDATION_EXPORT BOOL DSHEnvironmentValidId(id value);
FOUNDATION_EXPORT BOOL DSHEnvironmentValidWorkspaceId(id value);
FOUNDATION_EXPORT BOOL DSHEnvironmentValidHTTPSURL(id value);
FOUNDATION_EXPORT BOOL DSHEnvironmentValidateManifest(id value, NSString *kernelSHA256);
FOUNDATION_EXPORT BOOL DSHEnvironmentEnsureDirectory(NSURL *url);
FOUNDATION_EXPORT BOOL DSHEnvironmentProtectFile(NSURL *url);
FOUNDATION_EXPORT BOOL DSHEnvironmentHasCapacity(NSURL *url, uint64_t requiredBytes);
FOUNDATION_EXPORT NSData *_Nullable DSHEnvironmentReadSmallFile(NSURL *url, NSUInteger limit);
FOUNDATION_EXPORT NSString *_Nullable DSHEnvironmentHashFile(NSURL *url, uint64_t limit,
    BOOL (^_Nullable cancelled)(void));

/// Validates and streams one package into a new disk. Neither URL is exposed to UI.
@interface DSHRuntimeEnvironmentPackage : NSObject
+ (nullable NSDictionary *)unpackURL:(NSURL *)packageURL
                             diskURL:(NSURL *)diskURL
                       kernelSHA256:(NSString *)kernelSHA256
                     expectedRecord:(nullable NSDictionary *)record
                          cancelled:(BOOL (^)(void))cancelled
                              error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
