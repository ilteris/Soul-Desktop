// SOUL-213: swallow SwiftUI's BarAppearanceBridge KVO mismatch.
//
// When we replace `window.toolbar` (SoulAppDelegate.installToolbar swap-with-nil
// approach, needed for the layered titlebar paint to work), SwiftUI's
// BarAppearanceBridge keeps an internal reference to the old NSToolbar instance
// it was observing. On the next layout pass (sidebar toggle, window resize),
// the bridge calls -removeObserver:forKeyPath:@"displayMode" on a toolbar it's
// no longer registered with → NSRangeException → process crashes.
//
// Apple-private code (we can't fix the bridge). We CAN intercept removeObserver
// at the NSObject layer, swallow ONLY this specific mismatch, re-raise anything
// else. Implemented as an +load-time method swizzle so no Swift bridging is
// needed — this file self-installs.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

@interface NSObject (SoulKVOShield)
@end

@implementation NSObject (SoulKVOShield)

+ (void)load {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = [NSObject class];
        SEL original = @selector(removeObserver:forKeyPath:context:);
        SEL swizzled = @selector(soul_safeRemoveObserver:forKeyPath:context:);
        Method originalMethod = class_getInstanceMethod(cls, original);
        Method swizzledMethod = class_getInstanceMethod(cls, swizzled);
        if (originalMethod && swizzledMethod) {
            method_exchangeImplementations(originalMethod, swizzledMethod);
        }
    });
}

- (void)soul_safeRemoveObserver:(NSObject *)observer
                     forKeyPath:(NSString *)keyPath
                        context:(void *)context {
    @try {
        // After swizzle, calling the renamed selector invokes the ORIGINAL
        // removeObserver implementation.
        [self soul_safeRemoveObserver:observer forKeyPath:keyPath context:context];
    } @catch (NSException *exception) {
        NSString *name = exception.name ?: @"";
        NSString *reason = exception.reason ?: @"";
        // Swallow ONLY the SwiftUI BarAppearanceBridge stale-observer case.
        // Any other observer-registration bug should still crash so we see it.
        BOOL isBridgeMismatch =
            [name isEqualToString:NSRangeException] &&
            [reason containsString:@"BarAppearanceBridge"] &&
            [reason containsString:@"displayMode"];
        if (!isBridgeMismatch) {
            @throw;
        }
        // Intentionally silent: the bridge throws this every frame during
        // sidebar-toggle animations. NSLog at 60fps stalls the runloop and
        // produces visible chop on the open transition.
    }
}

@end
