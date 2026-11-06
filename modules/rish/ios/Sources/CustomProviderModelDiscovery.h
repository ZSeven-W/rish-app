#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

/// Explicit, bounded native-only model listing. Credentials never leave this
/// object. The caller owns registry persistence and serializes configuration
/// changes against its discovery reservation.
FOUNDATION_EXPORT BOOL DSHCustomProviderDiscoveryIsOperationId(id _Nullable value);

@interface DSHCustomProviderModelDiscovery : NSObject <NSURLSessionDataDelegate>
- (instancetype)initWithConfiguration:(NSDictionary *)configuration
                         operationId:(NSString *)operationId
                          credential:(nullable NSString *)credential
                     sourceIsCurrent:(BOOL (^)(void))sourceIsCurrent
                          completion:(void (^)(NSDictionary *_Nullable result, NSString *_Nullable errorCode))completion;
- (void)start;
- (void)cancel;
/// Cancel only this exact provider/operation pair. Old UI requests cannot
/// cancel a newer discovery for the same provider.
- (BOOL)cancelForProviderId:(NSString *)providerId operationId:(NSString *)operationId;
/// Built-in API providers use their existing harness identity and credential
/// account. This must never reinterpret an API provider as a custom UUID slot.
- (BOOL)cancelForHarnessId:(NSString *)harnessId operationId:(NSString *)operationId;
- (BOOL)isRunning;
@end
NS_ASSUME_NONNULL_END
