#import <Foundation/Foundation.h>
#import "../../Runner/RunnerStartupGuard.h"

static NSInteger AppState;
static NSUInteger HomeCount;
static NSInteger StateAtHome = -1;
static BOOL InterruptedActivation;
static NSUInteger ActivationPhase;
static NSTimeInterval PhaseStarted;
static NSTimeInterval HomeTime;

#ifdef STARTUP_TEST_UNSUPPORTED
typedef NSUInteger TestButton;
#else
typedef NSInteger TestButton;
#endif

@interface UIApplication : NSObject
+ (instancetype)sharedApplication;
- (NSInteger)applicationState;
@end
@implementation UIApplication
+ (instancetype)sharedApplication { static id app; if (!app) app = [self new]; return app; }
- (NSInteger)applicationState {
    // Advance only after the preceding state was observed. Independent dispatch
    // timers can be coalesced under CI load, hiding the inactive interval from
    // the guard and no longer testing interrupted activation at all.
    if (InterruptedActivation && ActivationPhase < 3) {
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        if (now - PhaseStarted >= 0.1) {
            ActivationPhase++;
            PhaseStarted = now;
            AppState = ActivationPhase == 2 ? 1 : 0;
        }
    }
    return AppState;
}
@end

@interface XCUIDevice : NSObject
- (void)_silentPressButton:(TestButton)button;
@end
@implementation XCUIDevice
- (void)_silentPressButton:(TestButton)button {
    if (button == 1) {
        HomeCount++;
        StateAtHome = AppState;
        HomeTime = NSProcessInfo.processInfo.systemUptime;
    }
}
@end

static void Check(BOOL condition, NSString *message) {
    if (!condition) { NSLog(@"FAIL: %@ (%@)", message, [RunnerStartupGuard facts]); exit(1); }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *scenario = argc > 1 ? @(argv[1]) : @"active";
        XCUIDevice *device = [XCUIDevice new];
        AppState = 0;
        if ([scenario isEqualToString:@"unsupported"]) {
            Check([[RunnerStartupGuard facts][@"state"] isEqual:@"unsupported_runtime"], @"unknown method encoding must not install");
            [device _silentPressButton:1];
            Check(HomeCount == 1, @"unsupported runtime keeps XCTest unchanged");
            return 0;
        }
        if ([scenario isEqualToString:@"disabled"]) {
            Check(![[RunnerStartupGuard facts][@"armed"] boolValue], @"unmanaged launch must not install");
            [device _silentPressButton:1];
            Check(HomeCount == 1, @"unmanaged Home unchanged");
            return 0;
        }
        Check([[RunnerStartupGuard facts][@"armed"] boolValue], @"guard installed before XCTest bootstrap");
        if ([scenario isEqualToString:@"finish"]) {
            [RunnerStartupGuard finish];
            [device _silentPressButton:1];
            Check(HomeCount == 1 && [[RunnerStartupGuard facts][@"state"] isEqual:@"not_needed"], @"no hook after test starts");
            return 0;
        }
        if ([scenario isEqualToString:@"flapping"]) {
            AppState = 1;
            InterruptedActivation = YES;
            PhaseStarted = NSProcessInfo.processInfo.systemUptime;
        } else if ([scenario isEqualToString:@"inactive"]) {
            AppState = 1;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ AppState = 0; });
        } else if ([scenario isEqualToString:@"timeout"]) {
            AppState = 1;
        } else if ([scenario isEqualToString:@"background"]) {
            AppState = 2;
        } else if ([scenario isEqualToString:@"enter_background"]) {
            AppState = 1;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ AppState = 2; });
        } else if ([scenario isEqualToString:@"nonhome"]) {
            [device _silentPressButton:2];
            Check([[RunnerStartupGuard facts][@"armed"] boolValue], @"non-Home must not consume startup guard");
        } else if ([scenario isEqualToString:@"offmain"]) {
            dispatch_semaphore_t completed = dispatch_semaphore_create(0);
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                [device _silentPressButton:1];
                dispatch_semaphore_signal(completed);
            });
            Check(dispatch_semaphore_wait(completed, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0,
                  @"non-main-thread Home must not wait for the main run loop");
            Check(HomeCount == 1 && [[RunnerStartupGuard facts][@"armed"] boolValue],
                  @"non-main-thread Home forwards without consuming startup guard");
            HomeCount = 0;
        }
        NSTimeInterval start = NSProcessInfo.processInfo.systemUptime;
        [device _silentPressButton:1];
        NSTimeInterval elapsed = NSProcessInfo.processInfo.systemUptime - start;
        Check(![[RunnerStartupGuard facts][@"armed"] boolValue], @"restore original method after one startup request");
        if ([scenario isEqualToString:@"timeout"] || [scenario isEqualToString:@"background"] || [scenario isEqualToString:@"enter_background"]) {
            Check(HomeCount == 0, @"never send Home into unresolved activation or an already backgrounded app");
            Check([[RunnerStartupGuard facts][@"state"] isEqual:AppState == 2 ? @"already_background" : @"activation_timeout"], @"report why no input was sent");
            Check(elapsed < 5.2, @"activation wait bounded");
        } else {
            Check(HomeCount == 1 && StateAtHome == 0, @"exactly one original Home, only while active");
            Check(elapsed >= 0.35, @"active interval must settle before Home");
            if (InterruptedActivation) {
                Check(ActivationPhase == 3 && HomeTime - PhaseStarted >= 0.35,
                      @"observed inactive interval must restart the full active wait");
            }
        }
        NSUInteger count = HomeCount;
        start = NSProcessInfo.processInfo.systemUptime;
        [device _silentPressButton:1];
        Check(HomeCount == count + 1 && NSProcessInfo.processInfo.systemUptime - start < 0.1, @"later user Home unchanged");
        NSLog(@"PASS %@: %@", scenario, [RunnerStartupGuard facts]);
    }
    return 0;
}
