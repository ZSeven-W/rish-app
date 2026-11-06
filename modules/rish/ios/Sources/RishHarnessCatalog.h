#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSDictionary *_Nullable DSHDshModelCatalog(void);
FOUNDATION_EXPORT NSDictionary *_Nullable DSHSaveDshModelCatalog(NSDictionary *request);
FOUNDATION_EXPORT NSDictionary *_Nullable DSHDshModelEntry(NSString *model);
FOUNDATION_EXPORT BOOL DSHDshModelSupportsImages(NSString *model);
/// API model choices are stored per provider. Fixed historical identities are
/// retained only for reading existing sessions and never appear as defaults.
FOUNDATION_EXPORT NSDictionary *_Nullable DSHProviderModelCatalog(void);
FOUNDATION_EXPORT NSDictionary *_Nullable DSHSaveProviderModelCatalog(NSDictionary *request, NSError **error);
FOUNDATION_EXPORT NSArray<NSDictionary *> *_Nullable DSHProviderModelRows(BOOL includeRetired);
FOUNDATION_EXPORT BOOL DSHProviderModelIsActive(NSString *model);
/// New work only. Historical validators must continue using the broad catalog.
FOUNDATION_EXPORT BOOL DSHHarnessModelIsExecutable(id _Nullable model);

/// Catalog of built-in and registered custom Rish Harnesses, the models they
/// serve, and the provider identity recorded on receipts, project-context
/// consent, and runtime proof. Keep these identities aligned with the Rust
/// shell catalog in apps/gpui/crates/rish-shell-core/src/model.rs. Every native
/// closed-shape validator resolves model ids, harness ids, provider ids, and
/// provider hosts through this catalog instead of carrying its own list.
/// DSH model identities additionally use the device model catalog. Registered
/// custom identities include retired entries for historical validation.
/// Provider, harness, host and credential identities also include registered
/// providers with no selected models; those providers have no model route.

/// These lookups recognize identities, including retired custom identities;
/// they do not authorize execution. A custom request's endpoint/model identity
/// is its immutable provider_configuration binding, and dispatch additionally
/// requires its current registry entry to be active.
/// All model ids across built-in and registered custom Harnesses.
FOUNDATION_EXPORT NSSet<NSString *> *DSHHarnessSupportedModels(void);
FOUNDATION_EXPORT BOOL DSHRegisterCodexSubscriptionModels(NSArray<NSString *> *models);
FOUNDATION_EXPORT BOOL DSHHarnessIsSupportedModel(id _Nullable value);

/// Built-in ids and registered "custom-<provider UUID>" ids.
FOUNDATION_EXPORT NSSet<NSString *> *DSHHarnessSupportedHarnessIds(void);
FOUNDATION_EXPORT BOOL DSHHarnessIsSupportedHarnessId(id _Nullable value);

/// The Harness that catalogs `model`, or nil for an unknown model.
FOUNDATION_EXPORT NSString *_Nullable DSHHarnessIdForModel(id _Nullable model);

/// Built-in provider ids and registered "custom-<provider UUID>" ids.
FOUNDATION_EXPORT NSSet<NSString *> *DSHHarnessSupportedProviderIds(void);
FOUNDATION_EXPORT BOOL DSHHarnessIsProviderId(id _Nullable value);
FOUNDATION_EXPORT NSString *_Nullable DSHProviderIdForHarnessId(id _Nullable harnessId);
FOUNDATION_EXPORT NSString *_Nullable DSHProviderIdForModel(id _Nullable model);

/// Official hosts and the registered custom providers' current endpoint hosts.
/// Historical request hosts are supplied by their captured provider binding.
FOUNDATION_EXPORT NSSet<NSString *> *DSHHarnessSupportedProviderHosts(void);
FOUNDATION_EXPORT BOOL DSHHarnessIsProviderHost(id _Nullable value);
FOUNDATION_EXPORT NSString *_Nullable DSHProviderHostForProviderId(id _Nullable providerId);
FOUNDATION_EXPORT NSString *_Nullable DSHProviderHostForModel(id _Nullable model);

/// Keychain account (credential slot) for a Harness:
/// Built-in slots and CUSTOM_API_KEY_<provider UUID>. The Keychain service name
/// stays owned by LocalRuntimeModule and never changes. Effective custom key
/// accounts additionally bind the endpoint, protocol and authentication type.
FOUNDATION_EXPORT NSSet<NSString *> *DSHHarnessCredentialAccounts(void);
FOUNDATION_EXPORT BOOL DSHHarnessIsCredentialAccount(id _Nullable value);
FOUNDATION_EXPORT NSString *_Nullable DSHCredentialAccountForHarnessId(id _Nullable harnessId);

NS_ASSUME_NONNULL_END
