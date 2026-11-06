#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const DSHWorkspaceCanonicalErrorDomain;

typedef NS_ERROR_ENUM(DSHWorkspaceCanonicalErrorDomain,
                      DSHWorkspaceCanonicalErrorCode) {
  DSHWorkspaceCanonicalErrorInvalid = 1,
};

/// RFC 8785/JCS JSON bytes. The returned bytes are UTF-8, contain no BOM, and
/// have no trailing newline. Only JSON values (null, booleans, finite
/// numbers, strings, arrays, and string-keyed dictionaries) are accepted.
FOUNDATION_EXPORT NSData * _Nullable DSHWorkspaceCanonicalJSONData(
    id object,
    NSError * _Nullable * _Nullable error);

/// Lowercase hexadecimal SHA-256. This helper is intentionally value-free and
/// is shared by private workspace authority, lease, and session code.
FOUNDATION_EXPORT NSString * _Nullable DSHWorkspaceSHA256Hex(NSData *data);

/// Validates the private schema-1 root-fingerprint union. The input is native
/// only; callers must never serialize it onto the app UI bridge.
FOUNDATION_EXPORT BOOL DSHWorkspaceValidateRootFingerprintInput(
    NSDictionary *input,
    NSError * _Nullable * _Nullable error);

/// Computes the domain-separated root fingerprint:
/// SHA-256(UTF8("rish.workspace-root-fingerprint.v1\\0") || JCS(input)).
/// The input is required to pass DSHWorkspaceValidateRootFingerprintInput.
FOUNDATION_EXPORT NSString * _Nullable DSHWorkspaceRootFingerprintSHA256(
    NSDictionary *input,
    NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
