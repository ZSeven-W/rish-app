#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Native-only attachment store contract. JavaScript receives opaque identifiers.
// ReadPayload validates the manifest, file type, size, and SHA-256 while holding
// the store lock, then returns an immutable snapshot that remains valid if the
// attachment is discarded concurrently. It is safe to call from any thread.
FOUNDATION_EXPORT NSData * _Nullable RishLocalAttachmentReadPayload(
  NSString *attachmentID,
  NSDictionary<NSString *, id> * _Nullable * _Nullable manifest,
  NSError * _Nullable * _Nullable error);

// ResolvePayload is retained for native file APIs that require a URL. The URL is
// app-owned and valid only until a concurrent discard/prune; new consumers should
// use ReadPayload so validation and consumption share one lock boundary.
FOUNDATION_EXPORT NSURL * _Nullable RishLocalAttachmentResolvePayload(
  NSString *attachmentID,
  NSDictionary<NSString *, id> * _Nullable * _Nullable manifest,
  NSError * _Nullable * _Nullable error);

FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable
RishLocalAttachmentLoadManifest(
  NSString *attachmentID,
  NSError * _Nullable * _Nullable error);

// Resolves one attachment reference from a visible history into the store's
// bytes and manifest. Returns the validated reference, or nil with `error`.
typedef NSDictionary * _Nullable (^DSHAttachmentResolver)(
  id value,
  NSData * _Nullable * _Nullable payloadData,
  NSDictionary * _Nullable * _Nullable manifestOut,
  NSError * _Nullable * _Nullable error);

// The store's own resolver, for callers that have no test double to inject.
FOUNDATION_EXPORT DSHAttachmentResolver DSHDefaultAttachmentResolver(void);

// A visible history, with every message's attachment references turned into
// what a model is shown: images become content parts, text and PDF are read
// and folded into the message's words. The plain chat path and the Agent
// round path both call this, so the two cannot disagree about the same file.
// Returns nil with `error` for anything that cannot be carried -- an image
// for a model that cannot see one, a file that no longer matches its
// reference -- rather than quietly sending less than the person attached.
FOUNDATION_EXPORT NSArray<NSDictionary *> * _Nullable DSHProjectHistoryAttachments(
  NSArray *history,
  NSString *model,
  DSHAttachmentResolver _Nullable resolver,
  NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
