#import "AgentProviderRoundService.h"
#import "LocalAttachmentStore.h"

NS_ASSUME_NONNULL_BEGIN

/// Where an attachment reference's bytes come from. Defaults to the store's
/// own resolver; a test puts a double here to exercise the projection without
/// a real attachment on disk.
@interface DSHAgentProviderRoundService ()
@property(nonatomic, copy) DSHAttachmentResolver attachmentResolver;
@end

/// Private native-only state shared by the provider coordinator and its
/// bounded helper functions.  It is never exposed through RCT.
@interface DSHAgentProviderRoundContext : NSObject
@property(nonatomic, strong, nullable) id<DSHCompletionExecution> task;
@property(nonatomic, copy) NSString *nativeTaskId;
@property(nonatomic, copy) NSDictionary *locator;
@property(nonatomic, copy) NSDictionary *cas;
@property(nonatomic) dispatch_semaphore_t semaphore;
@property(nonatomic) BOOL finished;
@property(nonatomic) BOOL redirected;
@property(nonatomic) BOOL redirectRejected;
@property(nonatomic, copy, nullable) NSDictionary *providerResult;
@property(nonatomic, copy, nullable) NSString *providerErrorCode;
@end

FOUNDATION_EXPORT void DSHSetProviderError(NSError **error,
                                           DSHAgentNativeStoreErrorCode code);
FOUNDATION_EXPORT BOOL DSHProviderDigest(id value);
FOUNDATION_EXPORT BOOL DSHProviderOpaqueId(id value);
FOUNDATION_EXPORT BOOL DSHProviderResultShape(NSDictionary *result);
FOUNDATION_EXPORT BOOL DSHProviderResultMatchesRequest(
    NSDictionary *result, NSDictionary *request, NSString *providerRequestId);
FOUNDATION_EXPORT NSString * _Nullable DSHProviderJSONSHA256(id value,
                                                              NSError **error);
FOUNDATION_EXPORT NSDictionary *DSHProviderConflictResult(
    NSString *operationId, NSString *failureCode, NSDictionary *request,
    NSNumber *actualRoundRevision, NSString *actualRoundStatus,
    NSDictionary *actualTranscript);
FOUNDATION_EXPORT BOOL DSHProviderContextBundle(
    NSDictionary *bundle, NSString *expectedContextDigest,
    NSDictionary * _Nullable * _Nullable receiptOut,
    NSArray * _Nullable * _Nullable messagesOut,
    NSError **error);
FOUNDATION_EXPORT NSDictionary * _Nullable DSHProviderRoundRequestCopy(
    NSDictionary *request, NSError **error);
FOUNDATION_EXPORT NSDictionary *DSHProviderRoundLocator(NSDictionary *request);
FOUNDATION_EXPORT NSDictionary *DSHProviderOwner(DSHAgentNativeWAL *wal,
                                                 NSString *taskId,
                                                 NSString *nativeTaskId);
FOUNDATION_EXPORT NSDictionary *DSHProviderRoundCASForRow(NSDictionary *row);
FOUNDATION_EXPORT NSDictionary * _Nullable DSHProviderNativeToCompletionMessage(
    NSDictionary *message, NSError **error);
FOUNDATION_EXPORT NSDictionary *DSHProviderPublicReceipt(
    NSDictionary *provider, NSDictionary *request, NSString *providerRequestId,
    NSDictionary * _Nullable contextReceipt);
FOUNDATION_EXPORT NSDictionary * _Nullable DSHProviderRecoveredRoundProjection(
    NSDictionary *row, NSDictionary *request, NSArray *nativeMessages,
    NSError **error);
FOUNDATION_EXPORT NSDictionary *DSHProviderUnknownResult(
    NSDictionary *request, NSString *status, NSUInteger revision,
    NSString *failureCode);
FOUNDATION_EXPORT NSString *DSHProviderFailureCode(
    NSString * _Nullable providerErrorCode, BOOL digestMismatch);
FOUNDATION_EXPORT NSDictionary *DSHProviderOperationSafeResult(NSDictionary *result);
FOUNDATION_EXPORT NSArray * _Nullable DSHProviderToolsForAuthority(
    NSDictionary *authority, DSHAgentToolRegistry *registry, NSError **error);
FOUNDATION_EXPORT NSArray * _Nullable DSHProviderTranscriptForBody(
    NSArray *nativeMessages, NSUInteger roundIndex, NSString *thinkingMode,
    NSError **error);
FOUNDATION_EXPORT NSDictionary *DSHProviderRoundResultForRow(
    NSDictionary *request, NSDictionary *row, NSString *status,
    NSString * _Nullable failureCode);
FOUNDATION_EXPORT NSDictionary *DSHProviderQueryResultForRow(
    NSDictionary *request, NSDictionary *row, NSString *status,
    NSString * _Nullable failureCode);
FOUNDATION_EXPORT NSDictionary *DSHProviderSelectorConflict(
    NSDictionary *request, NSDictionary *row, NSString *failureCode);
FOUNDATION_EXPORT BOOL DSHProviderSelectorRequest(NSDictionary *request,
                                                 BOOL cancellation,
                                                 BOOL allowZeroRevision,
                                                 NSError **error);
FOUNDATION_EXPORT BOOL DSHProviderSelectorMatchesRow(NSDictionary *request,
                                                    NSDictionary *row);
FOUNDATION_EXPORT void DSHProviderFinishContext(
    DSHAgentProviderRoundContext *context, NSDictionary * _Nullable result,
    NSString * _Nullable errorCode);
FOUNDATION_EXPORT NSString * _Nullable DSHProviderLocatorKey(
    NSDictionary *locator);
/// The arguments for the round operation's own commit: which reference the
/// result points at, and the result itself.
FOUNDATION_EXPORT NSDictionary * _Nullable DSHProviderStartedOperationCommit(
    NSDictionary *request, NSString *requestSHA, NSDictionary * _Nullable row,
    NSString *status, NSString * _Nullable failureCode);
/// The public answer a completed round hands the controller.
FOUNDATION_EXPORT NSDictionary * _Nullable DSHProviderPublicResult(
    NSDictionary *request, NSDictionary *row, NSDictionary *round);
/// The failure code a round row's state implies. `kind` is one of "query",
/// "reconciled" or "cancelled"; "ownerless" additionally answers whether the
/// state is one recovery may report directly, through `reportable`.
FOUNDATION_EXPORT NSDictionary * _Nullable DSHProviderRoundFailureCode(
    NSString *kind, NSString * _Nullable state);

NS_ASSUME_NONNULL_END
