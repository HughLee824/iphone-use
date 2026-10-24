#import "RunnerAXBinding.h"
#import <objc/message.h>

static void Fail(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"RunnerAXBinding" code:1
                                      userInfo:@{NSLocalizedDescriptionKey: message}];
}

static BOOL ObjectMethod(NSObject *object, SEL selector, NSUInteger arguments) {
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    return [object respondsToSelector:selector] && signature.numberOfArguments == arguments
        && signature.methodReturnType[0] == '@'
        && (arguments == 2 || [signature getArgumentTypeAtIndex:2][0] == '@');
}

@implementation RunnerAXBinding
+ (NSNumber *)keyboardFocusOfElement:(NSObject *)element error:(NSError **)error {
    @try {
        SEL selector = NSSelectorFromString(@"hasKeyboardFocus");
        NSMethodSignature *signature = [element methodSignatureForSelector:selector];
        if (![element respondsToSelector:selector] || signature.numberOfArguments != 2
            || strcmp(signature.methodReturnType, @encode(BOOL)) != 0) {
            Fail(error, @"XCTest keyboard focus is unavailable on this runtime");
            return nil;
        }
        return @(((BOOL (*)(id, SEL))objc_msgSend)(element, selector));
    } @catch (NSException *exception) {
        Fail(error, @"XCTest keyboard focus lookup failed");
        return nil;
    }
}

+ (NSObject *)snapshotOfElement:(NSObject *)element error:(NSError **)error {
    @try {
        SEL selector = NSSelectorFromString(@"snapshotWithParameters:error:");
        NSMethodSignature *signature = [element methodSignatureForSelector:selector];
        if (![element respondsToSelector:selector] || signature.numberOfArguments != 4
            || signature.methodReturnType[0] != '@' || [signature getArgumentTypeAtIndex:2][0] != '@'
            || strcmp([signature getArgumentTypeAtIndex:3], "^@") != 0) {
            Fail(error, @"Explicit XCTest snapshot parameters are unavailable on this runtime");
            return nil;
        }
        // Always request a new standard-attribute snapshot. A query's nonmodal
        // setting is not inherited by snapshotWithError:, and its cached root
        // is not a fresh observation. Visibility/actionability is checked separately.
        NSError *failure = nil;
        id snapshot = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(
            element, selector, @{@"snapshotKeyHonorModalViews": @NO}, &failure);
        Class snapshotClass = NSClassFromString(@"XCElementSnapshot");
        if (failure || !snapshotClass || ![snapshot isKindOfClass:snapshotClass]) {
            Fail(error, failure ? [NSString stringWithFormat:@"XCTest snapshot request failed (code %ld)",
                                  (long)failure.code] : @"XCTest did not return a valid explicit snapshot");
            return nil;
        }
        return snapshot;
    } @catch (NSException *exception) {
        Fail(error, @"Explicit XCTest snapshot request raised an exception");
        return nil;
    }
}

+ (NSObject *)identityOfSnapshot:(id)snapshot error:(NSError **)error {
    @try {
        SEL selector = NSSelectorFromString(@"accessibilityElement");
        if (!ObjectMethod(snapshot, selector, 2)) {
            Fail(error, @"XCTest snapshot identity is unavailable on this runtime");
            return nil;
        }
        id identity = ((id (*)(id, SEL))objc_msgSend)(snapshot, selector);
        if (![identity isKindOfClass:NSObject.class]) {
            Fail(error, @"XCTest snapshot has no accessibility identity");
            return nil;
        }
        return identity;
    } @catch (NSException *exception) {
        Fail(error, @"XCTest snapshot identity lookup failed");
        return nil;
    }
}

+ (NSObject *)bindSnapshot:(id)snapshot inQuery:(NSObject *)query error:(NSError **)error {
    @try {
        SEL selector = NSSelectorFromString(@"_elementMatchingAccessibilityElementOfSnapshot:");
        if (!ObjectMethod(query, selector, 3)) {
            Fail(error, @"XCTest snapshot binding is unavailable on this runtime");
            return nil;
        }
        if (![self identityOfSnapshot:snapshot error:error]) return nil;
        id element = ((id (*)(id, SEL, id))objc_msgSend)(query, selector, snapshot);
        Class elementClass = NSClassFromString(@"XCUIElement");
        if (!elementClass || ![element isKindOfClass:elementClass]) {
            Fail(error, @"XCTest did not bind the selected snapshot to an element");
            return nil;
        }
        return element;
    } @catch (NSException *exception) {
        Fail(error, @"XCTest snapshot binding failed");
        return nil;
    }
}
@end
