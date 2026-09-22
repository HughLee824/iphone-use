#import "RunnerPinchEvent.h"
#import <objc/runtime.h>

// Declarations describe selectors verified in the installed Apple framework.
// Classes are resolved at runtime; unavailable signatures fail before submission.
@interface NSObject (IPhoneUseEventRuntime)
- (NSInteger)interfaceOrientation;
- (id)initForTouchAtPoint:(CGPoint)point offset:(double)offset;
- (void)moveToPoint:(CGPoint)point atOffset:(double)offset;
- (void)liftUpAtOffset:(double)offset;
- (id)initWithName:(NSString *)name interfaceOrientation:(NSInteger)orientation;
- (void)addPointerEventPath:(id)path;
+ (id)sharedSession;
- (id)synthesizeEvent:(id)record completion:(void (^)(BOOL, NSError *))completion;
@end

static NSError *Failure(NSString *message) {
    return [NSError errorWithDomain:@"iphone-use.runner-pinch" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

static BOOL MethodMatches(Class cls, SEL selector, const char *encoding) {
    Method method = class_getInstanceMethod(cls, selector);
    return method && strcmp(method_getTypeEncoding(method), encoding) == 0;
}

@interface RunnerPinchEvent ()
@property (nonatomic, strong) id record;
@property (nonatomic, strong) id session;
@property (nonatomic) BOOL submitted;
@end

@implementation RunnerPinchEvent
+ (NSInteger)interfaceOrientationForApplication:(NSObject *)application {
    if (!MethodMatches(application.class, @selector(interfaceOrientation), "q16@0:8")) return 0;
    @try { return [application interfaceOrientation]; }
    @catch (NSException *exception) { return 0; }
}
+ (instancetype)prepareFrom:(CGPoint)left right:(CGPoint)right to:(CGPoint)endLeft rightEnd:(CGPoint)endRight
                  duration:(NSTimeInterval)duration orientation:(NSInteger)orientation error:(NSError **)error {
    Class pathClass = NSClassFromString(@"XCPointerEventPath");
    Class recordClass = NSClassFromString(@"XCSynthesizedEventRecord");
    Class sessionClass = NSClassFromString(@"XCTRunnerDaemonSession");
    if (!MethodMatches(pathClass, @selector(initForTouchAtPoint:offset:), "@40@0:8{CGPoint=dd}16d32") ||
        !MethodMatches(pathClass, @selector(moveToPoint:atOffset:), "v40@0:8{CGPoint=dd}16d32") ||
        !MethodMatches(pathClass, @selector(liftUpAtOffset:), "v24@0:8d16") ||
        !MethodMatches(recordClass, @selector(initWithName:interfaceOrientation:), "@32@0:8@16q24") ||
        !MethodMatches(recordClass, @selector(addPointerEventPath:), "v24@0:8@16") ||
        !MethodMatches(object_getClass(sessionClass), @selector(sharedSession), "@16@0:8") ||
        !MethodMatches(sessionClass, @selector(synthesizeEvent:completion:), "@32@0:8@16@?24")) {
        if (error) *error = Failure(@"Installed XCTest event synthesis runtime is incompatible");
        return nil;
    }
    if (!isfinite(duration) || duration < 0.1 || duration > 5 || orientation < 1 || orientation > 4) {
        if (error) *error = Failure(@"Invalid pinch duration or interface orientation");
        return nil;
    }
    @try {
        RunnerPinchEvent *event = [RunnerPinchEvent new];
        event.session = [sessionClass sharedSession];
        event.record = [[recordClass alloc] initWithName:@"iphone-use.pinch" interfaceOrientation:orientation];
        if (!event.session || !event.record) {
            if (error) *error = Failure(@"XCTest session or event record unavailable");
            return nil;
        }
        CGPoint starts[] = {left, right}, ends[] = {endLeft, endRight};
        for (int finger = 0; finger < 2; finger++) {
            if (!isfinite(starts[finger].x) || !isfinite(starts[finger].y) ||
                !isfinite(ends[finger].x) || !isfinite(ends[finger].y)) {
                if (error) *error = Failure(@"Invalid pinch coordinates");
                return nil;
            }
            id path = [[pathClass alloc] initForTouchAtPoint:starts[finger] offset:0];
            if (!path) { if (error) *error = Failure(@"XCTest touch path unavailable"); return nil; }
            // One finite event owns both complete paths, including release. Match
            // native geometry and short end holds; never send independent fingers.
            [path moveToPoint:starts[finger] atOffset:0.06];
            NSUInteger samples = (NSUInteger)ceil(duration * 60);
            for (NSUInteger i = 1; i <= samples; i++) {
                double t = (double)i / samples;
                CGPoint point = CGPointMake(starts[finger].x + (ends[finger].x - starts[finger].x) * t,
                                            starts[finger].y + (ends[finger].y - starts[finger].y) * t);
                [path moveToPoint:point atOffset:0.06 + duration * t];
            }
            [path liftUpAtOffset:duration + 0.12];
            [event.record addPointerEventPath:path];
        }
        return event;
    } @catch (NSException *exception) {
        if (error) *error = Failure(exception.reason ?: @"XCTest event preparation failed");
        return nil;
    }
}

- (BOOL)sendWithTimeout:(NSTimeInterval)timeout error:(NSError **)error {
    if (self.submitted || !isfinite(timeout) || timeout <= 0 || timeout > 15) {
        if (error) *error = Failure(@"Pinch event cannot be resubmitted or has an invalid timeout");
        return NO;
    }
    self.submitted = YES;
    NSObject *lock = [NSObject new];
    __block BOOL finished = NO, success = NO;
    __block NSError *failure = nil;
    @try {
        [self.session synthesizeEvent:self.record completion:^(BOOL ok, NSError *problem) {
            @synchronized (lock) { success = ok; failure = problem; finished = YES; }
        }];
        double deadline = NSProcessInfo.processInfo.systemUptime + timeout;
        for (;;) {
            @synchronized (lock) {
                if (finished) {
                    if ((!success || failure) && error) *error = failure ?: Failure(@"XCTest did not confirm pinch completion");
                    return success && !failure;
                }
            }
            if (NSProcessInfo.processInfo.systemUptime >= deadline) {
                if (error) *error = Failure(@"XCTest pinch completion timed out; result unknown, close this session without replay");
                return NO;
            }
            // Completion may arrive on the main run loop. No new command is
            // consumed while this synchronous Runner action is in progress.
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
    } @catch (NSException *exception) {
        if (error) *error = Failure(exception.reason ?: @"XCTest event submission failed");
        return NO;
    }
}
@end
