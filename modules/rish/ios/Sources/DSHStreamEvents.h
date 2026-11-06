#import <Foundation/Foundation.h>

#import "DSHCompletionProviderTransport.h"

NS_ASSUME_NONNULL_BEGIN

// Incremental Server-Sent-Events parser for DeepSeek streaming chunks.
// Pure state machine: feed it raw bytes as they arrive, receive parsed
// deltas. No I/O, no transport — fully unit-testable.

extern const NSInteger DSHStreamMaxLineBytes;
extern const NSInteger DSHStreamMaxBufferedLines;

/// Error domain for all parser errors (2101 invalid UTF-8, 2102 not a JSON
/// object, 2103 already finished, 2104 oversized line, 2105 too many lines).
extern NSString * const DSHStreamEventErrorDomain;

/// The shared core's own word for the refusal, in an error's userInfo. The
/// codes above are this file's vocabulary; this is the core's, for a caller
/// that distinguishes more finely than they do.
extern NSString * const DSHStreamFailureReasonKey;

/// A parsed streaming delta emitted to UI.
typedef NSDictionary<NSString *, id> DSHStreamDelta;

/// Error 2106: a tool-call fragment has an unusable shape.
@interface DSHStreamEventParser : NSObject <DSHProviderStreamEventParsing>

/// Provider identity observed on the chunks so far (`id` / `model` of the
/// OpenAI-style chunk object). nil until a chunk carried them.
@property(nonatomic, copy, readonly, nullable) NSString *streamedResponseId;
@property(nonatomic, copy, readonly, nullable) NSString *streamedModel;

/// Feed raw chunk bytes. Returns the deltas decoded from complete SSE
/// events, or nil with *error on malformed/oversized input.
- (nullable NSArray<DSHStreamDelta *> *)appendBytes:(const uint8_t *)bytes
                                             length:(NSUInteger)length
                                               error:(NSError **)error;

/// Flush any complete-but-unfed lines at stream end (a trailing event
/// without its blank-line terminator is tolerated once).
- (nullable NSArray<DSHStreamDelta *> *)finish:(NSError **)error;

/// Resets to a clean state for reuse.
- (void)reset;

/// The wire this reads, as the shared core names it: `chat-completions`,
/// `responses` or `messages`. A dialect overrides this and the two hooks
/// below, and nothing else -- the framing, the limits and the reading of an
/// event all live in the core.
- (NSString *)wire;

/// Translates the core's word for a refusal into this parser's own error
/// domain and codes. `failure` is the default, in this file's vocabulary.
- (NSError *)refusalForReason:(NSString *)reason fallback:(NSError *)failure;

/// Feeding or flushing a stream that is already over.
- (NSError *)alreadyFinished;

@end

/// Error domain / codes for the assembler (2201 over budget, 2202 tool
/// fragment cannot be placed).
extern NSString * const DSHStreamAssemblerErrorDomain;

/// Rebuilds a provider's single-shot response object from the streamed
/// delta vocabulary so a streamed round is validated by exactly the same
/// response parser as a non-streamed one. Each dialect supplies its own
/// wire shape through `responseObject`.
@protocol DSHProviderStreamResponseAssembling <NSObject>
- (void)noteResponseId:(nullable NSString *)responseId model:(nullable NSString *)model;
- (BOOL)appendDelta:(DSHStreamDelta *)delta error:(NSError **)error;
@property(nonatomic, readonly) NSUInteger accumulatedBytes;
- (NSDictionary<NSString *, id> *)responseObject;
@end

/// One assembled tool call: index, optional id/name, concatenated arguments.
typedef NSDictionary<NSString *, id> DSHStreamAssembledCall;

/// Accumulates text, reasoning, tool fragments, finish reason and identity
/// through the shared core, and emits the wire shape its `dialect` names.
/// A dialect overrides `dialect`; the accumulation, the byte budget and all
/// three shapes live in the core.
@interface DSHStreamResponseAssembler : NSObject <DSHProviderStreamResponseAssembling>

- (instancetype)initWithThinkingMode:(NSString *)thinkingMode
                        maximumBytes:(NSUInteger)maximumBytes;

/// Records the chunk identity; the first non-empty value wins.
- (void)noteResponseId:(nullable NSString *)responseId
                 model:(nullable NSString *)model;

/// Applies one parsed delta. NO with *error when the accumulated text,
/// reasoning and tool arguments exceed the byte budget or a tool fragment
/// cannot be placed.
- (BOOL)appendDelta:(DSHStreamDelta *)delta error:(NSError **)error;

/// Bytes of text, reasoning and arguments accumulated so far.
@property(nonatomic, readonly) NSUInteger accumulatedBytes;

/// The assembled object in the provider's single-shot shape. Missing
/// identity or finish reason is left for the response parser to reject.
- (NSDictionary<NSString *, id> *)responseObject;

/// The wire shape to answer in, as the shared core names it:
/// `chat-completions`, `responses` or `messages`. A dialect overrides this
/// and nothing else -- the accumulation and all three shapes are the core's.
- (NSString *)dialect;

@end

NS_ASSUME_NONNULL_END
