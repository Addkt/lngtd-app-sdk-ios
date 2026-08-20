#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 Catching an `NSException` in Objective-C that has unwound through Swift frames leaves the
 process in an undefined state. Swift lacks any `NSException` unwinding mechanism: `defer`
 blocks will not execute, `deinit` will not be called, ARC retains/releases are skipped,
 and any logical invariants that were being maintained by the partially-executed function
 will be broken. In short, memory will leak.

 This memory leak is the accepted cost. The alternative is causing a hard crash in a
 publisher's app. A leak costing a few kilobytes per occurrence is strictly preferable
 to terminating someone else's application due to a bug in our SDK.

 Because of this severe consequence, the block passed to this function must be kept as
 small as possible. It should ideally wrap only the specific Objective-C call that is
 known to be capable of raising an exception—not a broad region of Swift logic.
 Currently, the two known sources of raised exceptions are GMA's KVC paths and Prebid's
 `validateAndAttachKeywords`.

 This function is strictly a damage-limitation mechanism at our SDK's boundaries. It is
 not a general-purpose error-handling strategy. Normal Swift errors should always be
 handled using `throws`. This shim exists solely because Swift has no native ability
 to catch an `NSException`.

 @return nil if `block` completed successfully, or the caught `NSException` if one was raised.
 */
NSException * _Nullable LNGTDRunCatchingNSException(void (NS_NOESCAPE ^ _Nonnull block)(void));

NS_ASSUME_NONNULL_END
