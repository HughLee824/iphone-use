#import <Foundation/Foundation.h>
#import "../../Runner/RunnerAXBinding.h"

@interface XCUIElement : NSObject
@end
@implementation XCUIElement
@end

@interface Snapshot : NSObject
@property NSObject *accessibilityElement;
@end
@implementation Snapshot
@end

@interface Query : NSObject
@property id selected;
@property id result;
@property BOOL raises;
- (id)_elementMatchingAccessibilityElementOfSnapshot:(id)snapshot;
@end
@implementation Query
- (id)_elementMatchingAccessibilityElementOfSnapshot:(id)snapshot {
    if (self.raises) [NSException raise:@"MockFailure" format:@"private UI text"];
    self.selected = snapshot;
    return self.result;
}
@end

@interface WrongSignature : NSObject
- (NSInteger)_elementMatchingAccessibilityElementOfSnapshot:(id)snapshot;
@end
@implementation WrongSignature
- (NSInteger)_elementMatchingAccessibilityElementOfSnapshot:(id)snapshot { abort(); }
@end

@interface XCElementSnapshot : NSObject
@end
@implementation XCElementSnapshot
@end

@interface SnapshotElement : NSObject
@property NSDictionary *parameters;
@property NSInteger requests;
@property id current;
@property NSError *failure;
@property BOOL raises;
- (id)snapshotWithParameters:(NSDictionary *)parameters error:(NSError **)error;
@end
@implementation SnapshotElement
- (id)snapshotWithParameters:(NSDictionary *)parameters error:(NSError **)error {
    self.requests++;
    self.parameters = parameters;
    if (self.raises) [NSException raise:@"SnapshotFailure" format:@"private UI text"];
    if (error) *error = self.failure;
    return self.current;
}
@end

@interface WrongSnapshotSignature : NSObject
- (NSInteger)snapshotWithParameters:(NSDictionary *)parameters error:(NSError **)error;
@end
@implementation WrongSnapshotSignature
- (NSInteger)snapshotWithParameters:(NSDictionary *)parameters error:(NSError **)error { abort(); }
@end

@interface FocusElement : NSObject
@property BOOL hasKeyboardFocus;
@end
@implementation FocusElement
@end

@interface WrongFocusSignature : NSObject
- (id)hasKeyboardFocus;
@end
@implementation WrongFocusSignature
- (id)hasKeyboardFocus { abort(); }
@end

static void Check(BOOL condition, NSString *message) {
    if (!condition) { NSLog(@"FAIL: %@", message); exit(1); }
}

int main(void) {
    @autoreleasepool {
        Snapshot *snapshot = [Snapshot new];
        snapshot.accessibilityElement = @"AX identity 1";
        Query *query = [Query new];
        query.result = [XCUIElement new];
        NSError *error = nil;
        FocusElement *focused = [FocusElement new];
        Check([[RunnerAXBinding keyboardFocusOfElement:focused error:&error] isEqual:@NO] && !error,
              @"false keyboard focus is a valid result");
        focused.hasKeyboardFocus = YES;
        Check([[RunnerAXBinding keyboardFocusOfElement:focused error:&error] isEqual:@YES],
              @"keyboard focus is queried afresh");
        Check(![RunnerAXBinding keyboardFocusOfElement:[NSObject new] error:&error] && error,
              @"missing keyboard focus fails closed");
        error = nil;
        Check(![RunnerAXBinding keyboardFocusOfElement:[WrongFocusSignature new] error:&error] && error,
              @"wrong keyboard focus signature is never invoked");
        error = nil;
        Check([RunnerAXBinding bindSnapshot:snapshot inQuery:query error:&error] == query.result,
              @"bind the exact snapshot object, not another query candidate");
        Check(query.selected == snapshot && !error, @"preserve selected snapshot");
        Check([[RunnerAXBinding identityOfSnapshot:snapshot error:&error] isEqual:@"AX identity 1"],
              @"return underlying accessibility identity");
        Check(![RunnerAXBinding bindSnapshot:snapshot inQuery:[NSObject new] error:&error] && error,
              @"missing selector fails closed");
        error = nil;
        Check(![RunnerAXBinding bindSnapshot:snapshot inQuery:[WrongSignature new] error:&error] && error,
              @"wrong signature must never be invoked");
        error = nil;
        Check(![RunnerAXBinding identityOfSnapshot:[NSObject new] error:&error] && error,
              @"missing identity fails closed");
        error = nil;
        snapshot.accessibilityElement = nil;
        Check(![RunnerAXBinding bindSnapshot:snapshot inQuery:query error:&error] && error,
              @"nil identity fails closed");
        snapshot.accessibilityElement = @"AX identity 1";
        error = nil;
        query.result = [NSObject new];
        Check(![RunnerAXBinding bindSnapshot:snapshot inQuery:query error:&error] && error,
              @"unexpected binding result fails closed");
        error = nil;
        query.raises = YES;
        Check(![RunnerAXBinding bindSnapshot:snapshot inQuery:query error:&error] && error,
              @"runtime exception is converted to a failure");
        Check(![error.localizedDescription containsString:@"private UI text"], @"no raw exception UI data");
        SnapshotElement *element = [SnapshotElement new];
        id first = [XCElementSnapshot new], second = [XCElementSnapshot new];
        element.current = first;
        error = nil;
        Check([RunnerAXBinding snapshotOfElement:element error:&error] == first && !error,
              @"explicit snapshot request succeeds");
        Check([element.parameters isEqual:@{@"snapshotKeyHonorModalViews": @NO}],
              @"snapshot collection disables modal filtering explicitly");
        element.current = second;
        Check([RunnerAXBinding snapshotOfElement:element error:&error] == second && element.requests == 2,
              @"each capture asks for a fresh snapshot instead of reusing a cached root");
        Check(![RunnerAXBinding snapshotOfElement:[NSObject new] error:&error] && error,
              @"missing parameterized snapshot API fails closed");
        error = nil;
        Check(![RunnerAXBinding snapshotOfElement:[WrongSnapshotSignature new] error:&error] && error,
              @"wrong snapshot signature is never invoked");
        error = nil;
        element.current = [NSObject new];
        Check(![RunnerAXBinding snapshotOfElement:element error:&error] && error,
              @"wrong snapshot result is rejected");
        error = nil;
        element.current = first;
        element.failure = [NSError errorWithDomain:@"Apple" code:42 userInfo:nil];
        Check(![RunnerAXBinding snapshotOfElement:element error:&error] && error,
              @"snapshot error is not ignored when a value is also returned");
        Check([error.localizedDescription containsString:@"42"], @"retain error code");
        error = nil;
        element.raises = YES;
        Check(![RunnerAXBinding snapshotOfElement:element error:&error] && error,
              @"snapshot exception becomes a failure");
        Check(![error.localizedDescription containsString:@"private UI text"], @"no raw exception UI data");
        puts("AX binding runtime regressions passed");
    }
    return 0;
}
