#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Isolated XCTest runtime adapter. Missing capabilities fail closed.
@interface RunnerAXBinding : NSObject
+ (nullable NSNumber *)keyboardFocusOfElement:(NSObject *)element error:(NSError **)error
    NS_SWIFT_NAME(keyboardFocus(of:));
+ (nullable NSObject *)snapshotOfElement:(NSObject *)element error:(NSError **)error
    NS_SWIFT_NAME(snapshot(of:));
+ (nullable NSObject *)bindSnapshot:(id)snapshot inQuery:(NSObject *)query error:(NSError **)error
    NS_SWIFT_NAME(bind(snapshot:query:));
+ (nullable NSObject *)identityOfSnapshot:(id)snapshot error:(NSError **)error
    NS_SWIFT_NAME(identity(of:));
@end
NS_ASSUME_NONNULL_END
