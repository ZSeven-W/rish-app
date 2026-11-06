#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

static const NSUInteger DSHMaximumModelTransitionTraceEntries = 64;

/// Validates the exact shell-to-native model transition envelope and returns the
/// redacted row that may be persisted in runtime-proof.json. The conversation
/// identifier is replaced by its SHA-256 digest; caller text and paths are not
/// part of this contract.
NSDictionary<NSString *, id> * _Nullable DSHValidatedModelTransitionProofRow(
    id value,
    NSString *recordedAt,
    NSError **error);

/// Appends one already-validated row to a bounded trace. Invalid/corrupt
/// existing traces are treated as empty rather than copied into a new proof.
NSDictionary<NSString *, id> * DSHModelTransitionTraceByAppendingRow(
    id _Nullable existingTrace,
    NSDictionary<NSString *, id> *row,
    NSString *recordedAt);

/// Copies the two independent redacted traces that must survive every base
/// proof rewrite. Model traces are copied only when their persisted structure
/// is valid; agent traces remain owned by their existing writer.
void DSHPreserveRuntimeProofTraces(
    NSDictionary<NSString *, id> *previous,
    NSMutableDictionary<NSString *, id> *proof);

NS_ASSUME_NONNULL_END
