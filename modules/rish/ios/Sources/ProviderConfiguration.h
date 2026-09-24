#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

/// Non-secret, versioned provider settings. Credentials stay in Keychain and
/// are namespaced by the exact endpoint/auth identity, separately from defaults.
@interface DSHProviderConfigurationStore : NSObject
+ (instancetype)sharedStore;
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults;
- (nullable NSDictionary *)configurationForHarness:(NSString *)harness;
- (nullable NSDictionary *)saveConfiguration:(NSDictionary *)configuration error:(NSError **)error;
- (NSDictionary *)resetHarness:(NSString *)harness;
@end

FOUNDATION_EXPORT NSDictionary *_Nullable DSHNormalizeProviderConfiguration(id value);
FOUNDATION_EXPORT NSDictionary *_Nullable DSHProviderBindingForModel(NSString *model);
FOUNDATION_EXPORT NSDictionary *_Nullable DSHProviderBindingFromConfiguration(NSDictionary *configuration, NSString *model);
FOUNDATION_EXPORT BOOL DSHValidateProviderBinding(id value, NSString *logicalModel);
FOUNDATION_EXPORT BOOL DSHProviderBindingIsCurrent(id _Nullable value, NSString *logicalModel);
FOUNDATION_EXPORT NSDictionary *_Nullable DSHProviderRecordWithoutConfiguration(NSDictionary *record, NSString *model);
FOUNDATION_EXPORT NSString *_Nullable DSHEffectiveCredentialAccount(NSString *slot);
/// The harness whose provider a credential slot belongs to, or nil.
FOUNDATION_EXPORT NSString *_Nullable DSHConfigurableHarnessForSlot(NSString *slot);
/// Whether the person configured a relay for this harness.
FOUNDATION_EXPORT BOOL DSHHarnessUsesCustomProvider(NSString *harness);
FOUNDATION_EXPORT NSString *_Nullable DSHNormalizeProviderEndpoint(NSString *value, NSString *protocol);
NS_ASSUME_NONNULL_END
