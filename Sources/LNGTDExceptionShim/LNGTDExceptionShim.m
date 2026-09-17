#import "LNGTDExceptionShim.h"

NSException * _Nullable LNGTDRunCatchingNSException(void (NS_NOESCAPE ^ _Nonnull block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception;
    }
}
