#import <Foundation/Foundation.h>

#import "AgentNativeWAL.h"
#import "AgentPreparedAttemptStore.h"
#import "AgentRoundJournal.h"
#import "AgentTranscriptStore.h"
#import "DSHCompletionProviderTransport.h"

NS_ASSUME_NONNULL_BEGIN

/// Native-only credential/history/body providers.  They are injected by the
/// existing LocalRuntime owner; none of these values are part of the UI
/// request or any service result. The credential provider receives the
/// harness id from the round request so the generic runtime can key the
/// Keychain slot (DEEPSEEK_API_KEY / ANTHROPIC_API_KEY / OPENAI_API_KEY /
/// BIGMODEL_API_KEY).
typedef NSString * _Nullable (^DSHAgentProviderRoundCredentialProvider)(
    NSString *harnessId, NSUInteger *generation);
typedef NSArray<NSDictionary *> * _Nullable (^DSHAgentProviderRoundVisibleHistoryProvider)(
    NSDictionary *authority, NSError **error);
typedef NSDictionary * _Nullable (^DSHAgentProviderRoundContextReceiptProvider)(
    NSDictionary *authority, NSError **error);
typedef DSHCompletionProviderTransport * _Nullable (^DSHAgentProviderRoundTransportResolver)(
    NSString *harnessId);
/// Display-only preview events of a streamed round (see `previewSink`).
typedef void (^DSHAgentProviderRoundPreviewSink)(NSDictionary<NSString *, id> *event);

/// For schema-3 rounds the callback returns exactly
/// `{project_context_sha256,receipt:{...},messages:[{role:"system",content,attachments:[]}]}`.
/// The digest is compared with the frozen authority before model input is
/// built. Context bytes/text are native-only model input; only the redacted
/// receipt appears in the completed public result.

/// Native-only coordinator for one transactional provider round.  The
/// request/result seam is intentionally not exported through the app UI:
/// callers provide only frozen authority assertions and receive redacted
/// receipts/projections.  Provider arguments and transcript messages stay in
/// native stores.
@interface DSHAgentProviderRoundService : NSObject

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithWAL:(DSHAgentNativeWAL *)wal
               preparedStore:(DSHAgentPreparedAttemptStore *)preparedStore
                  transcripts:(DSHAgentTranscriptStore *)transcripts
                       rounds:(DSHAgentRoundJournal *)rounds
                    transport:(DSHCompletionProviderTransport *)transport;

- (instancetype)initWithWAL:(DSHAgentNativeWAL *)wal
                preparedStore:(DSHAgentPreparedAttemptStore *)preparedStore
                   transcripts:(DSHAgentTranscriptStore *)transcripts
                        rounds:(DSHAgentRoundJournal *)rounds
                     transport:(DSHCompletionProviderTransport *)transport
          credentialProvider:(nullable DSHAgentProviderRoundCredentialProvider)credentialProvider
       visibleHistoryProvider:(nullable DSHAgentProviderRoundVisibleHistoryProvider)visibleHistoryProvider;

- (instancetype)initWithWAL:(DSHAgentNativeWAL *)wal
                preparedStore:(DSHAgentPreparedAttemptStore *)preparedStore
                   transcripts:(DSHAgentTranscriptStore *)transcripts
                        rounds:(DSHAgentRoundJournal *)rounds
                     transport:(DSHCompletionProviderTransport *)transport
          credentialProvider:(nullable DSHAgentProviderRoundCredentialProvider)credentialProvider
       visibleHistoryProvider:(nullable DSHAgentProviderRoundVisibleHistoryProvider)visibleHistoryProvider
       contextReceiptProvider:(nullable DSHAgentProviderRoundContextReceiptProvider)contextReceiptProvider;

/// Provider-agnostic coordinator entry point. `transport` remains the DSH
/// transport for legacy callers and tests. A request for a
/// harness whose transport is nil fails closed as unavailable.
- (instancetype)initWithWAL:(DSHAgentNativeWAL *)wal
                preparedStore:(DSHAgentPreparedAttemptStore *)preparedStore
                   transcripts:(DSHAgentTranscriptStore *)transcripts
                        rounds:(DSHAgentRoundJournal *)rounds
                     transport:(DSHCompletionProviderTransport *)transport
              claudeTransport:(nullable DSHCompletionProviderTransport *)claudeTransport
               codexTransport:(nullable DSHCompletionProviderTransport *)codexTransport
          credentialProvider:(nullable DSHAgentProviderRoundCredentialProvider)credentialProvider
       visibleHistoryProvider:(nullable DSHAgentProviderRoundVisibleHistoryProvider)visibleHistoryProvider
       contextReceiptProvider:(nullable DSHAgentProviderRoundContextReceiptProvider)contextReceiptProvider;

- (instancetype)initWithWAL:(DSHAgentNativeWAL *)wal
                preparedStore:(DSHAgentPreparedAttemptStore *)preparedStore
                   transcripts:(DSHAgentTranscriptStore *)transcripts
                        rounds:(DSHAgentRoundJournal *)rounds
                     transport:(DSHCompletionProviderTransport *)transport
              claudeTransport:(nullable DSHCompletionProviderTransport *)claudeTransport
               codexTransport:(nullable DSHCompletionProviderTransport *)codexTransport
                 glmTransport:(nullable DSHCompletionProviderTransport *)glmTransport
          credentialProvider:(nullable DSHAgentProviderRoundCredentialProvider)credentialProvider
       visibleHistoryProvider:(nullable DSHAgentProviderRoundVisibleHistoryProvider)visibleHistoryProvider
       contextReceiptProvider:(nullable DSHAgentProviderRoundContextReceiptProvider)contextReceiptProvider
    NS_DESIGNATED_INITIALIZER;

/// Synchronously composes one native round around the asynchronous provider
/// transport.  The blocking wait is confined to this native-private helper;
/// the future UI facade should invoke it off the main thread.
- (nullable NSDictionary *)completeAgentRoundV2WithRequest:(NSDictionary *)request
                                                     error:(NSError **)error;

/// Reopens only an existing `failed_retryable` row.  The locator and
/// expected row revision remain frozen; native claim increments the persisted
/// launch attempt and installs a fresh owner before the shared transport is
/// dispatched.  This never takes the insert-if-absent path.
- (nullable NSDictionary *)retryFailedAgentRoundV2WithRequest:(NSDictionary *)request
                                                         error:(NSError **)error;

- (nullable NSDictionary *)queryAgentRoundWithRequest:(NSDictionary *)request
                                                error:(NSError **)error;
- (nullable NSDictionary *)recoverAgentRoundWithRequest:(NSDictionary *)request
                                                   error:(NSError **)error;
- (nullable NSDictionary *)cancelAgentRoundWithRequest:(NSDictionary *)request
                                                  error:(NSError **)error;

@property(nonatomic, strong, readonly) DSHAgentNativeWAL *wal;
@property(nonatomic, strong, readonly) DSHAgentPreparedAttemptStore *preparedStore;
@property(nonatomic, strong, readonly) DSHAgentTranscriptStore *transcripts;
@property(nonatomic, strong, readonly) DSHAgentRoundJournal *rounds;
@property(nonatomic, strong, readonly) DSHCompletionProviderTransport *transport;
@property(nonatomic, strong, readonly, nullable) DSHCompletionProviderTransport *claudeTransport;
@property(nonatomic, strong, readonly, nullable) DSHCompletionProviderTransport *codexTransport;
@property(nonatomic, strong, readonly, nullable) DSHCompletionProviderTransport *glmTransport;
/// Optional per-round resolver consulted after initialization.
@property(nonatomic, copy, nullable) DSHAgentProviderRoundTransportResolver transportResolver;

/// When set, rounds on transports that support streaming are requested with
/// `stream:true` and their parsed deltas are coalesced (about every 50 ms,
/// 256 KiB per round) into versioned events delivered here from a private
/// queue, never from the serialized workspace queue:
///   {schema_version:1, kind:"delta", task_id, attempt_id, round_id,
///    round_index, operation_id, provider_request_id, harness_id, seq,
///    text?, reasoning?, tool_calls?:[{index,id?,name?,arguments?}],
///    finish_reason?}
///   {schema_version:1, kind:"end", ...same correlation..., seq,
///    status:"validated"|"failed", failure_code?, truncated}
/// Events are presentation material only; the round still returns exactly
/// one validated result, and that result is authoritative regardless of
/// which arrives first.
@property(nonatomic, copy, nullable) DSHAgentProviderRoundPreviewSink previewSink;

/// Missing harness_id preserves legacy DSH behavior. Unknown, mismatched,
/// or unavailable transports are rejected before reading credentials.
- (nullable DSHCompletionProviderTransport *)transportForRequest:(NSDictionary *)request;

@end

@compatibility_alias AgentProviderRoundService DSHAgentProviderRoundService;

NS_ASSUME_NONNULL_END
