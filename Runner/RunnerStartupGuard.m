#import "RunnerStartupGuard.h"
#import <objc/runtime.h>
#import <os/log.h>

// UIKit's public application-state API, resolved dynamically so this small
// bootstrap adapter can also be tested with host runtime doubles.
@interface NSObject (IPhoneUseApplicationState)
+ (id)sharedApplication;
- (NSInteger)applicationState;
@end

static Method HomeMethod;
static IMP OriginalHome;
static BOOL Armed;
static NSString *Outcome = @"not_installed";
static NSTimeInterval WaitSeconds;

static void Restore(void) {
    if (Armed) {
        method_setImplementation(HomeMethod, OriginalHome);
        Armed = NO;
    }
}

static void StartupHome(id device, SEL selector, NSInteger button) {
    // Only XCTest's first startup Home is guarded. Never delay or replay an
    // ordinary command, and do not interfere with non-Home buttons.
    if (button != 1 || !NSThread.isMainThread) {
        ((void (*)(id, SEL, NSInteger))OriginalHome)(device, selector, button);
        return;
    }
    Restore();
    id app = [NSClassFromString(@"UIApplication") sharedApplication];
    NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
    NSTimeInterval activeSince = -1;
    Outcome = @"waiting_for_active";
    os_log(OS_LOG_DEFAULT, "IPHONE_USE_STARTUP_HOME waiting state=%ld", (long)[app applicationState]);
    while (NSProcessInfo.processInfo.systemUptime - started < 5) {
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        NSInteger state = [app applicationState];
        // UIApplicationStateBackground. XCTest already registered its background
        // notification expectation before calling us; do not send another Home.
        if (state == 2) {
            Outcome = @"already_background";
            break;
        }
        // UIApplicationStateActive. Authentication returns before its remote
        // overlay disappears. Let UIKit finish activation and drain the dismissal
        // transition before sending the *one original* Home event.
        if (state == 0) {
            if (activeSince < 0) activeSince = now;
            if (now - activeSince >= 0.35) {
                Outcome = @"home_dispatched";
                ((void (*)(id, SEL, NSInteger))OriginalHome)(device, selector, button);
                break;
            }
        } else {
            activeSince = -1;
        }
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.025]];
    }
    WaitSeconds = NSProcessInfo.processInfo.systemUptime - started;
    if ([Outcome isEqualToString:@"waiting_for_active"]) Outcome = @"activation_timeout";
    // On timeout send no input into a potentially active system dialog. XCTest's
    // normal initialization failure remains authoritative; never fake readiness.
    os_log(OS_LOG_DEFAULT, "IPHONE_USE_STARTUP_HOME result=%{public}@ wait=%.3f", Outcome, WaitSeconds);
}

@implementation RunnerStartupGuard
+ (void)load {
    @autoreleasepool {
        NSDictionary *env = NSProcessInfo.processInfo.environment;
        if (![env[@"IPHONE_USE_HOST_MANAGED"] isEqualToString:@"1"] ||
            [env[@"IPHONE_USE_SESSION_TOKEN"] length] < 32) return;
        Class device = NSClassFromString(@"XCUIDevice");
        Class app = NSClassFromString(@"UIApplication");
        Method home = class_getInstanceMethod(device, NSSelectorFromString(@"_silentPressButton:"));
        Method state = class_getInstanceMethod(app, @selector(applicationState));
        if (!home || strcmp(method_getTypeEncoding(home), "v24@0:8q16") != 0 ||
            !state || strcmp(method_getTypeEncoding(state), "q16@0:8") != 0 ||
            ![app respondsToSelector:@selector(sharedApplication)]) {
            Outcome = @"unsupported_runtime";
            os_log(OS_LOG_DEFAULT, "IPHONE_USE_STARTUP_HOME unsupported runtime; XCTest unchanged");
            return;
        }
        HomeMethod = home;
        OriginalHome = method_setImplementation(home, (IMP)StartupHome);
        Armed = YES;
        Outcome = @"armed";
    }
}

+ (void)finish {
    // XCTest may already have started in the background and skipped Home. Do not
    // leave the startup hook installed when accepting user commands.
    Restore();
    if ([Outcome isEqualToString:@"armed"]) Outcome = @"not_needed";
}

+ (NSDictionary<NSString *, id> *)facts {
    return @{@"state": Outcome, @"waitSeconds": @(WaitSeconds), @"armed": @(Armed)};
}
@end
