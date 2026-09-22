// Host-only doubles for the Apple runtime boundary. No XCTest/device is loaded.
#import "../../Runner/RunnerPinchEvent.h"
#import <Foundation/Foundation.h>

@interface XCPointerEventPath : NSObject
@property NSMutableArray *events;
- (id)initForTouchAtPoint:(CGPoint)point offset:(double)offset;
- (void)moveToPoint:(CGPoint)point atOffset:(double)offset;
- (void)liftUpAtOffset:(double)offset;
@end
@implementation XCPointerEventPath
- (id)initForTouchAtPoint:(CGPoint)p offset:(double)t {
    self = [super init]; if (self) self.events = [NSMutableArray arrayWithObject:@[@"down", @(p.x), @(p.y), @(t)]]; return self;
}
- (void)moveToPoint:(CGPoint)p atOffset:(double)t { [self.events addObject:@[@"move", @(p.x), @(p.y), @(t)]]; }
- (void)liftUpAtOffset:(double)t { [self.events addObject:@[@"up", @(t)]]; }
@end
@interface XCSynthesizedEventRecord : NSObject
@property NSMutableArray *paths;
@property NSInteger orientation;
- (id)initWithName:(NSString *)name interfaceOrientation:(NSInteger)orientation;
- (void)addPointerEventPath:(id)path;
@end
@implementation XCSynthesizedEventRecord
- (id)initWithName:(NSString *)name interfaceOrientation:(NSInteger)orientation {
    self = [super init]; if (self) { self.paths = [NSMutableArray new]; self.orientation = orientation; } return self;
}
- (void)addPointerEventPath:(id)path { [self.paths addObject:path]; }
@end
static XCSynthesizedEventRecord *lastRecord;
static NSUInteger submissions;
static NSInteger behavior;
@interface XCTRunnerDaemonSession : NSObject
+ (id)sharedSession;
- (id)synthesizeEvent:(id)record completion:(void (^)(BOOL, NSError *))completion;
@end
@implementation XCTRunnerDaemonSession
+ (id)sharedSession { static id session; if (!session) session = [self new]; return session; }
- (id)synthesizeEvent:(id)record completion:(void (^)(BOOL, NSError *))completion {
    submissions++; lastRecord = record;
    if (behavior == 0) completion(YES, nil);
    if (behavior == 1) completion(NO, [NSError errorWithDomain:@"test" code:1 userInfo:nil]);
    if (behavior == 2) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ completion(YES, nil); });
    return nil;
}
@end

static RunnerPinchEvent *Prepare(NSInteger orientation) {
    NSError *error;
    RunnerPinchEvent *event = [RunnerPinchEvent prepareFrom:CGPointMake(130, 240) right:CGPointMake(210, 240)
        to:CGPointMake(70, 240) rightEnd:CGPointMake(270, 240) duration:0.5 orientation:orientation error:&error];
    NSCAssert(event && !error, @"preparation failed: %@", error); return event;
}
int main(void) {
    @autoreleasepool {
        for (NSInteger orientation = 1; orientation <= 4; orientation++) {
            RunnerPinchEvent *event = Prepare(orientation); NSError *error;
            NSCAssert([event sendWithTimeout:0.1 error:&error] && !error, @"success callback rejected");
            NSCAssert(lastRecord.orientation == orientation && lastRecord.paths.count == 2, @"orientation/contact count");
            for (NSUInteger i = 0; i < 2; i++) {
                NSArray *events = [lastRecord.paths[i] events];
                NSCAssert([events.firstObject[0] isEqual:@"down"] && [events.firstObject[3] doubleValue] == 0, @"synchronized down");
                NSCAssert([events.lastObject[0] isEqual:@"up"] && fabs([events.lastObject[1] doubleValue] - 0.62) < 1e-9, @"complete release");
                NSArray *end = events[events.count - 2];
                NSCAssert([end[1] doubleValue] == (i == 0 ? 70 : 270) && [end[2] doubleValue] == 240, @"exact endpoint");
            }
            NSUInteger before = submissions;
            NSCAssert(![event sendWithTimeout:0.1 error:&error] && error && submissions == before, @"no resubmission");
        }
        for (behavior = 1; behavior <= 2; behavior++) {
            NSError *error; RunnerPinchEvent *event = Prepare(3);
            NSCAssert(![event sendWithTimeout:0.01 error:&error] && error, @"failed/late callback cannot complete");
            NSUInteger before = submissions;
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
            NSCAssert(![event sendWithTimeout:0.1 error:&error] && submissions == before, @"late completion cannot replay");
        }
        NSError *error;
        NSCAssert(![RunnerPinchEvent prepareFrom:CGPointZero right:CGPointZero to:CGPointZero rightEnd:CGPointZero
            duration:0.5 orientation:5 error:&error] && error, @"physical face-up is not interface orientation");
        puts("Runner pinch runtime host tests passed: paths, orientations, releases, failure, timeout, late completion, no replay");
    }
}
