#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Optional CLI artifact downloads. This service owns no accounts and makes no
/// claim that a downloaded CLI has an assistant execution adapter.
@interface RishRuntimeEngineDownloads : NSObject <NSURLSessionDownloadDelegate>
+ (instancetype)shared;
+ (NSDictionary<NSString *, NSDictionary *> *)descriptors;
@property(nonatomic, readonly, nullable) NSURL *directory;
- (NSDictionary *)installationForEngine:(NSString *)engineID;
- (void)installEngine:(NSString *)engineID;
- (nullable NSURL *)verifiedArtifactForEngine:(NSString *)engineID;
- (nullable NSURL *)ensureDirectory;

/// Isolated test transport: never opens a URLSession or application storage.
- (instancetype)initWithDirectory:(NSURL *)directory
    descriptors:(NSDictionary<NSString *, NSDictionary *> *)descriptors
    starter:(nullable void (^)(NSString *engineID, NSURL *url))starter;
/// The real URLSession and fake transport pass through the same acceptance gate.
- (void)finishDownloadForEngine:(NSString *)engineID file:(NSURL *)file
    response:(nullable NSHTTPURLResponse *)response;
- (void)failDownloadForEngine:(NSString *)engineID;
- (void)recordProgress:(double)fraction forEngine:(NSString *)engineID;
@end

NS_ASSUME_NONNULL_END
