#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Opaque process-local ownership; never serialized or supplied by the UI.
@interface DSHGuestVMOwner : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

/// A process may reserve one guest during both boot and live execution. Locks
/// protect only ownership changes; no VM boot, execution or teardown runs under
/// them. Mounted state is an observation, separate from the reservation.
@interface DSHGuestRuntimeState : NSObject

+ (instancetype)sharedState;

@property(nonatomic, readonly) BOOL guestRuntimeMounted;

/// nil means another guest owns the process reservation. Ownership is not
/// transferred or preempted; the caller must retry after that guest stops.
- (nullable DSHGuestVMOwner *)acquireGuestOwner;
- (BOOL)setGuestRuntimeMounted:(BOOL)mounted owner:(DSHGuestVMOwner *)owner;
/// Call only after the owner's guest handle is fully freed. A stale/wrong
/// token cannot change the mounted flag or release the current reservation.
- (BOOL)releaseGuestOwner:(DSHGuestVMOwner *)owner;

/// Compatibility observation for older native tests. Ignored while a real
/// owner is reserved; this method never grants or releases ownership.
- (void)setGuestRuntimeMounted:(BOOL)mounted;

@end

NS_ASSUME_NONNULL_END
