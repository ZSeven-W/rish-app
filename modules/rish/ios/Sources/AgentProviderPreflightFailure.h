#import <Foundation/Foundation.h>

@class DSHAgentNativeWAL;
@class DSHAgentRoundJournal;

NS_ASSUME_NONNULL_BEGIN

/// Records a failure only through the round journal's not-dispatched proof.
/// When a row already exists, its native owner is released before reconciliation.
/// Otherwise this creates/claims the same normal round intent first.
NSDictionary *_Nullable DSHProviderFailBeforeDispatch(
    DSHAgentNativeWAL *wal, DSHAgentRoundJournal *rounds,
    NSDictionary *request, NSString *requestSHA, BOOL retry,
    NSDictionary *_Nullable existingRow, NSString *_Nullable nativeTaskId,
    NSString *failureCode, NSError **error);

NS_ASSUME_NONNULL_END
