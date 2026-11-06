#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Pure RuntimeProofV3 attestation contract. V3 is intentionally limited to a
/// verified project-context attempt: project_id, snapshot_id, and
/// consent_receipt_id are mandatory canonical UUIDs. Ordinary unbound chat
/// continues to use the legacy proof until its versioned attempt contract is
/// migrated; callers must not synthesize placeholder UUIDs or null bindings.
/// This file deliberately owns no storage, bridge, transport, or audit-log
/// behavior.
extern const NSInteger DSHRuntimeProofV3SchemaVersion;
extern const NSUInteger DSHRuntimeProofV3MaxIncludedEntries;
extern const NSUInteger DSHRuntimeProofV3MaxOmittedEntries;
extern const NSUInteger DSHRuntimeProofV3MaxAttachments;
extern const NSUInteger DSHRuntimeProofV3MaxProviderRounds;
extern const NSUInteger DSHRuntimeProofV3MaxToolEvidenceEntries;

FOUNDATION_EXPORT NSErrorDomain const DSHRuntimeProofV3ErrorDomain;

/// Stable, value-free failure codes. They are returned verbatim as
/// NSError.localizedDescription and never interpolate caller data.
FOUNDATION_EXPORT NSString *const DSHRuntimeProofV3ErrorExactKeys;
FOUNDATION_EXPORT NSString *const DSHRuntimeProofV3ErrorSchema;
FOUNDATION_EXPORT NSString *const DSHRuntimeProofV3ErrorUntrustedContainer;
FOUNDATION_EXPORT NSString *const DSHRuntimeProofV3ErrorIdentifier;
FOUNDATION_EXPORT NSString *const DSHRuntimeProofV3ErrorTimestamp;
FOUNDATION_EXPORT NSString *const DSHRuntimeProofV3ErrorDigest;
FOUNDATION_EXPORT NSString *const DSHRuntimeProofV3ErrorText;
FOUNDATION_EXPORT NSString *const DSHRuntimeProofV3ErrorPath;
FOUNDATION_EXPORT NSString *const DSHRuntimeProofV3ErrorNumber;
FOUNDATION_EXPORT NSString *const DSHRuntimeProofV3ErrorOrder;
FOUNDATION_EXPORT NSString *const DSHRuntimeProofV3ErrorDuplicate;
FOUNDATION_EXPORT NSString *const DSHRuntimeProofV3ErrorEnum;
FOUNDATION_EXPORT NSString *const DSHRuntimeProofV3ErrorBounds;
FOUNDATION_EXPORT NSString *const DSHRuntimeProofV3ErrorRelation;
FOUNDATION_EXPORT NSString *const DSHRuntimeProofV3ErrorAttestationDigest;
FOUNDATION_EXPORT NSString *const DSHRuntimeProofV3ErrorCanonicalization;

/// Builds an exact RuntimeProofV3 root from an exact immutable attestation.
/// The initial diagnostics.updated_at equals attestation.attested_at. The
/// returned shape is exactly:
///
///   {schema_version, attestation, attestation_sha256, diagnostics}
///
/// `attestation_sha256` is SHA-256 over canonical attestation JSON only.
NSDictionary<NSString *, id> * _Nullable DSHBuildRuntimeProofV3(
    NSDictionary<NSString *, id> *attestation,
    NSError **error);

/// Validates an existing exact RuntimeProofV3 root, including its immutable
/// attestation digest, and returns a detached immutable deep copy.
NSDictionary<NSString *, id> * _Nullable DSHValidateRuntimeProofV3(
    id proof,
    NSError **error);

/// Returns deterministic sorted-key JSON bytes for a validated full proof.
NSData * _Nullable DSHCanonicalRuntimeProofV3Data(
    id proof,
    NSError **error);

/// Returns the validated immutable attestation digest. Diagnostics are never
/// included in this digest.
NSString * _Nullable DSHRuntimeProofV3AttestationSHA256(
    id proof,
    NSError **error);

/// Replaces only diagnostics.updated_at after validating both the original
/// proof and the timestamp. It cannot refresh attested_at or its digest.
NSDictionary<NSString *, id> * _Nullable
DSHRuntimeProofV3ByUpdatingDiagnosticsTimestamp(
    id proof,
    NSString *updatedAt,
    NSError **error);

/// Raw SHA-256 helper used by producers to digest bytes before entering this
/// metadata-only contract. Returns nil for nil, mutable/custom/wrong-typed
/// data, or payloads larger tha UINT32_MAX; lengths are never truncated.
NSString * _Nullable DSHRuntimeProofV3SHA256Hex(
    NSData * _Nullable data);

#ifdef __cplusplus
}  // extern "C"
#endif

NS_ASSUME_NONNULL_END
