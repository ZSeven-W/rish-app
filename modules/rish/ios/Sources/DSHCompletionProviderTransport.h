#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol DSHProviderStreamResponseAssembling;

/// An execution owns cancellation without implying an HTTP session task.
@protocol DSHCompletionExecution <NSObject>
- (void)cancel;
@optional
/// Real HTTP task only, for existing delegate routing and strict-slot ownership.
/// Non-HTTP executions omit this method or return nil.
- (nullable NSURLSessionDataTask *)underlyingHTTPTask;
@end
typedef BOOL (^DSHCompletionProviderTransportBindExecutionBlock)(id<DSHCompletionExecution> execution);

/// Native-only ownership hooks used by the completion transport.  The
/// transport deliberately does not keep a credential store, create an
/// NSURLSession, or own the LocalRuntime completion slot.  A caller supplies
/// the already-shared slot operations so schema 2, schema 3, and the future
/// provider-round service cannot accidentally grow a second cancellation
/// registry.
typedef BOOL (^DSHCompletionProviderTransportBindTaskBlock)(NSURLSessionDataTask *task);
typedef BOOL (^DSHCompletionProviderTransportClaimRoundBlock)(BOOL * _Nullable redirected);
typedef BOOL (^DSHCompletionProviderTransportCredentialGenerationIsCurrentBlock)(
    NSUInteger credentialGeneration);
typedef void (^DSHCompletionProviderTransportMarkRedirectedBlock)(NSURLSessionDataTask *task);
typedef void (^DSHCompletionProviderTransportRedirectDecisionBlock)(BOOL rejected);
#if DEBUG
/// Debug/test-only, value-free transport diagnostics. The callback receives
/// only bounded phase/classification fields; it never contains URL, body,
/// headers, credentials, or NSError descriptions.
typedef void (^DSHCompletionProviderTransportDiagnosticBlock)(NSDictionary *diagnostic);
#endif

/// One round's request body, built by the shared core for the named dialect
/// (`chat-completions`, `messages` or `responses`). Returns nil and sets
/// `failureCode` to the core's word for the refusal.
NSDictionary * _Nullable DSHCompletionTransportRequestBody(
    NSString *dialect, NSString *model, NSString *thinkingMode,
    NSArray *messages, NSArray *tools, BOOL streaming,
    NSString * _Nullable * _Nullable failureCode);

@protocol DSHProviderStreamEventParsing <NSObject>

/// Feed raw chunk bytes. Returns the deltas decoded from complete SSE
/// events, or nil with *error on malformed/oversized input.
- (nullable NSArray<NSDictionary<NSString *, id> *> *)appendBytes:(const uint8_t *)bytes
                                                             length:(NSUInteger)length
                                                               error:(NSError **)error;

/// Flush any complete-but-unfed events at stream end.
- (nullable NSArray<NSDictionary<NSString *, id> *> *)finish:(NSError **)error;

/// Resets to a clean state for reuse.
- (void)reset;

@end

/// Completion carries only a sanitized provider result or a stable,
/// value-free error code.  Provider response bodies, request bytes, and
/// credentials never cross this seam.
typedef void (^DSHCompletionProviderTransportCompletionBlock)(
    NSDictionary<NSString *, id> * _Nullable result,
    NSString * _Nullable errorCode);

/// Preview deltas of a streamed round, in the parser vocabulary
/// {type:"delta", content?, reasoning?, tool_calls?:[{index,id?,name?,arguments?}],
/// finish_reason?}. Display material only: the round still settles through
/// `completion` with one result validated from the whole stream.
typedef void (^DSHCompletionProviderTransportPreviewBlock)(
    NSDictionary<NSString *, id> *delta);

/// Private shared DeepSeek HTTP transport for strict completion schema 2/3.
///
/// The injected NSURLSession is the module's one session and is not owned by
/// this object.  Likewise, credential material is accepted per request and
/// never persisted here.  Ownership and generation checks remain in the
/// caller's existing completion slot via the callbacks above.
@interface DSHCompletionProviderTransport : NSObject

#if DEBUG
@property(nonatomic, copy, nullable) DSHCompletionProviderTransportDiagnosticBlock diagnosticHandler;
#endif

- (instancetype)initWithSession:(nullable NSURLSession *)session
                   uuidGenerator:(NSString *(^ _Nullable)(void))uuidGenerator
                  monotonicClock:(NSTimeInterval (^ _Nullable)(void))monotonicClock;

/// Mints the provider correlation id after the caller has reserved its
/// completion slot.  The id is intentionally separate from the RN round id.
- (NSString * _Nullable)nextProviderRequestId:(NSString * _Nullable * _Nullable)errorCode;

/// Creates and starts one POST request once the caller has reserved its
/// shared slot.  `visibleHistory` and `modelInput` are already validated
/// native projections; the transport computes their canonical digests and
/// the exact request-body digest for the result.
/// `credentialGenerationIsCurrent` must consult the caller's existing
/// generation counter; it never reads or stores credential material.
///
/// A nil return means no task was started.  In that case `completion` is
/// still called when an owner callback is available, so a caller can settle
/// its already-reserved slot without leaking it.
- (NSURLSessionDataTask * _Nullable)startRequestWithSchemaVersion:(NSInteger)schemaVersion
                                                           roundId:(NSString *)roundId
                                                          generation:(NSUInteger)generation
                                                credentialGeneration:(NSUInteger)credentialGeneration
                                                 providerRequestId:(NSString *)providerRequestId
                                                       credential:(NSString *)credential
                                                   requestedModel:(NSString *)requestedModel
                                                    thinkingMode:(NSString *)thinkingMode
                                     credentialGenerationIsCurrent:(DSHCompletionProviderTransportCredentialGenerationIsCurrentBlock _Nullable)credentialGenerationIsCurrent
                                                        startedAt:(NSTimeInterval)startedAt
                                                        bodyData:(NSData *)bodyData
                                                  visibleHistory:(NSArray *)visibleHistory
                                                      modelInput:(NSArray *)modelInput
                                                       bindTask:(DSHCompletionProviderTransportBindTaskBlock)bindTask
                                                     claimRound:(DSHCompletionProviderTransportClaimRoundBlock)claimRound
                                                markRedirected:(DSHCompletionProviderTransportMarkRedirectedBlock _Nullable)markRedirected
                                              redirectDecision:(DSHCompletionProviderTransportRedirectDecisionBlock _Nullable)redirectDecision
                                                     completion:(DSHCompletionProviderTransportCompletionBlock)completion;

/// Generic execution entry point; HTTP transports adapt their existing task owner.
- (id<DSHCompletionExecution> _Nullable)startExecutionWithSchemaVersion:(NSInteger)schemaVersion
                                                           roundId:(NSString *)roundId
                                                          generation:(NSUInteger)generation
                                                credentialGeneration:(NSUInteger)credentialGeneration
                                                 providerRequestId:(NSString *)providerRequestId
                                                       credential:(NSString * _Nullable)credential
                                                   requestedModel:(NSString *)requestedModel
                                                    thinkingMode:(NSString *)thinkingMode
                                     credentialGenerationIsCurrent:(DSHCompletionProviderTransportCredentialGenerationIsCurrentBlock _Nullable)credentialGenerationIsCurrent
                                                        startedAt:(NSTimeInterval)startedAt
                                                        bodyData:(NSData *)bodyData
                                                  visibleHistory:(NSArray *)visibleHistory
                                                      modelInput:(NSArray *)modelInput
                                                       bindExecution:(DSHCompletionProviderTransportBindExecutionBlock)bindExecution
                                                     claimRound:(DSHCompletionProviderTransportClaimRoundBlock)claimRound
                                                markRedirected:(DSHCompletionProviderTransportMarkRedirectedBlock _Nullable)markRedirected
                                              redirectDecision:(DSHCompletionProviderTransportRedirectDecisionBlock _Nullable)redirectDecision
                                                     completion:(DSHCompletionProviderTransportCompletionBlock)completion;
/// Streams the provider round when `providerSupportsStreamingRounds` is
/// YES: the request body must have been built with `streaming:YES`, parsed
/// deltas are forwarded to `preview` as they arrive (on the session's
/// delegate queue), and `completion` still settles exactly once with one
/// result assembled from the whole stream and validated by the same
/// response parser as a single-shot round. Transports without streaming
/// rounds fall back to `startExecutionWithSchemaVersion:...` and never
/// call `preview`.
- (nullable id<DSHCompletionExecution>)startStreamingExecutionWithSchemaVersion:(NSInteger)schemaVersion
                                                                         roundId:(NSString *)roundId
                                                                      generation:(NSUInteger)generation
                                                            credentialGeneration:(NSUInteger)credentialGeneration
                                                               providerRequestId:(NSString *)providerRequestId
                                                                      credential:(NSString *)credential
                                                                  requestedModel:(NSString *)requestedModel
                                                                    thinkingMode:(NSString *)thinkingMode
                                                   credentialGenerationIsCurrent:(DSHCompletionProviderTransportCredentialGenerationIsCurrentBlock)credentialGenerationIsCurrent
                                                                       startedAt:(NSTimeInterval)startedAt
                                                                        bodyData:(NSData *)bodyData
                                                                  visibleHistory:(NSArray *)visibleHistory
                                                                      modelInput:(NSArray *)modelInput
                                                                         preview:(nullable DSHCompletionProviderTransportPreviewBlock)preview
                                                                   bindExecution:(DSHCompletionProviderTransportBindExecutionBlock)bindExecution
                                                                      claimRound:(DSHCompletionProviderTransportClaimRoundBlock)claimRound
                                                                  markRedirected:(DSHCompletionProviderTransportMarkRedirectedBlock _Nullable)markRedirected
                                                                redirectDecision:(DSHCompletionProviderTransportRedirectDecisionBlock _Nullable)redirectDecision
                                                                      completion:(DSHCompletionProviderTransportCompletionBlock)completion;

/// Session-delegate entry points for streamed tasks this transport owns
/// (`handlesTask:`). The owner's NSURLSession delegate forwards its data
/// callbacks here; tasks started with a completion handler never reach them.
- (void)streamingTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response;
- (void)streamingTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data;
- (void)streamingTask:(NSURLSessionTask *)task didCompleteWithError:(nullable NSError *)error;

- (BOOL)isReadyWithCredential:(nullable NSString *)credential;
- (BOOL)supportsTools;
/// Bounded owner wait, including local execution startup. HTTP stays at 120s.
- (NSTimeInterval)executionTimeoutInterval;


/// Returns whether this transport currently owns the task identifier.  The
/// module's NSURLSession delegate uses this to route only strict redirects to
/// this transport; legacy and streaming tasks keep their existing path.
- (BOOL)handlesTask:(NSURLSessionTask *)task;

/// Cancels a task and releases only its transport routing context.  The
/// caller still owns the shared completion slot and settles its promise;
/// this method never invokes a completion callback itself.  Tasks belonging
/// to legacy/streaming paths are simply cancelled.
- (void)cancelTask:(NSURLSessionDataTask *)task;

/// Rejects a redirect for an owned strict request without following the
/// destination.  Unknown tasks are followed unchanged by the caller's
/// existing delegate path.
- (void)handleHTTPRedirectionForTask:(NSURLSessionTask *)task
                          newRequest:(NSURLRequest *)request
                   completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler;

/// Provider hooks. The base class implements the DeepSeek dialect;
/// ClaudeProviderTransport and CodexProviderTransport override these to
/// produce the Anthropic and OpenAI wire dialects while inheriting the
/// shared slot, digest, cancellation, and redirect orchestration above.
/// Streaming parsers conform to DSHProviderStreamEventParsing and emit the
/// same delta vocabulary {type, content?, reasoning?, finish_reason?}.
- (BOOL)hasActiveRequests;
- (NSURL *)providerBaseURL;

/// Immutable non-secret identity attached to custom provider receipts.
- (nullable NSDictionary *)providerConfigurationForModel:(NSString *)model;

- (NSDictionary<NSString *, NSString *> *)providerHeadersWithCredential:(NSString *)credential;

/// Builds the provider request body from neutral message/tool inputs.
- (NSDictionary<NSString *, id> *)providerRequestBodyForModel:(NSString *)model
                                                 thinkingMode:(NSString *)thinkingMode
                                                     messages:(NSArray<NSDictionary<NSString *, id> *> *)messages
                                                        tools:(NSArray<NSDictionary<NSString *, id> *> *)tools
                                                    streaming:(BOOL)streaming
                                                        error:(NSError **)error;

/// Parses one complete provider response body into the canonical fragment
/// {provider_response_id, model, text, reasoning, tool_calls, finish_reason}.
- (NSDictionary<NSString *, id> *)providerParseResponseData:(NSData *)data
                                              requestedModel:(NSString *)requestedModel
                                                thinkingMode:(NSString *)thinkingMode
                                                      error:(NSError **)error;

/// The HTTP status the provider refused a request with, taken once: the
/// completion carries only a code, and "401" is what tells a person which
/// setting to fix. 0 when the request did not end on a status.
- (NSInteger)takeRefusalHTTPStatusForProviderRequestId:(NSString *)providerRequestId;

/// Maps a non-2xx HTTP status to a stable error code.
- (NSString *)providerErrorCodeForHTTPStatus:(NSInteger)statusCode
                                         data:(NSData * _Nullable)data;

/// Fresh streaming parser for this provider's SSE dialect.
- (id<DSHProviderStreamEventParsing>)providerNewStreamEventParser;

/// Whether agent rounds may be streamed through this transport. Requires a
/// parser that reports tool-call fragments and chunk identity so the
/// assembled response passes `providerParseResponseData:` unchanged.
- (BOOL)providerSupportsStreamingRounds;

/// Fresh assembler turning this dialect's streamed deltas back into its
/// single-shot response object for `providerParseResponseData:`. The base
/// class returns the chat-completions assembler.
- (id<DSHProviderStreamResponseAssembling>)providerNewStreamResponseAssemblerWithThinkingMode:(NSString *)thinkingMode
                                                                                  maximumBytes:(NSUInteger)maximumBytes;

/// Whether this transport serves the given model id.
- (BOOL)providerSupportsModel:(NSString *)model;

/// Request timeout for the streaming or single-shot flavor.
- (NSTimeInterval)providerTimeoutIntervalForStreaming:(BOOL)streaming;

/// Stable harness id recorded on results this transport produces.
- (NSString *)providerHarnessId;
@end

NS_ASSUME_NONNULL_END
