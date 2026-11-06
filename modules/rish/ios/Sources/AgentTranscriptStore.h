#import <Foundation/Foundation.h>

#import "AgentNativeWAL.h"

NS_ASSUME_NONNULL_BEGIN

/// Native-only transcript storage. The public result of every method is a
/// reference or a redacted status; raw assistant/tool messages stay inside the
/// protected WAL and are never returned by this class.
FOUNDATION_EXPORT void DSHAgentPruneRoundPresentationCache(NSURL *walRoot, NSSet<NSString *> *_Nullable conversationIds);

@interface DSHAgentTranscriptStore : NSObject

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithWAL:(DSHAgentNativeWAL *)wal
    NS_DESIGNATED_INITIALIZER;

- (nullable NSDictionary *)createAgentTranscriptWithRequest:(NSDictionary *)request
                                                      error:(NSError **)error;

- (nullable NSDictionary *)validateAgentTranscriptWithRequest:(NSDictionary *)request
                                                        error:(NSError **)error;

- (nullable NSDictionary *)markAgentTranscriptTerminalWithRequest:
    (NSDictionary *)request
                                                               error:(NSError **)error;

- (nullable NSDictionary *)discardAgentTranscriptWithRequest:(NSDictionary *)request
                                                       error:(NSError **)error;

- (nullable NSDictionary *)queryAgentTranscriptCleanupWithRequest:
    (NSDictionary *)request
                                                            error:(NSError **)error;

/// Native-only reconstruction used by the completion bridge. The request is
/// still bound to the complete attempt/root/reference token; this method must
/// never be exported as a UI-facing result.
- (nullable NSArray<NSDictionary *> *)nativeMessagesForTranscriptWithRequest:
    (NSDictionary *)request
                                                                          error:(NSError **)error;

/// Appends one exact native assistant/tool union and returns only the new
/// transcript reference. The expected reference is a complete CAS token;
/// stale/mismatched attempts, roots, generations, or hashes perform no write.
- (nullable NSDictionary *)appendAssistantMessage:(NSDictionary *)message
                             expectedTranscript:(NSDictionary *)expectedTranscript
                                          root:(NSDictionary *)root
                                      attemptId:(NSString *)attemptId
                                          error:(NSError **)error;

- (nullable NSDictionary *)appendToolMessage:(NSDictionary *)message
                         expectedTranscript:(NSDictionary *)expectedTranscript
                                      root:(NSDictionary *)root
                                  attemptId:(NSString *)attemptId
                                      error:(NSError **)error;

/// Private native helper used by AgentRoundJournal to co-commit provider
/// transcript append and round completion. It intentionally accepts a block
/// over the WAL state rather than exposing raw records to the UI.
- (BOOL)performAtomicTransaction:(DSHAgentNativeWALMutation)mutation
                           error:(NSError **)error;

/// Non-authority display cache. Only call after the round/transcript commit.
- (void)cacheRoundPresentationForRequest:(NSDictionary *)request message:(NSDictionary *)message kind:(NSString *)kind;
- (nullable NSDictionary *)roundPresentationsForConversation:(NSString *)conversationId attempt:(NSString *)attemptId error:(NSError **)error;

@property(nonatomic, strong, readonly) DSHAgentNativeWAL *wal;

@end

@compatibility_alias AgentTranscriptStore DSHAgentTranscriptStore;

NS_ASSUME_NONNULL_END
