#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "RunnerStartupGuard.h"

NS_ASSUME_NONNULL_BEGIN
// Runner-only Apple XCTest event synthesis; no host/device-control fallback.
@interface RunnerPinchEvent : NSObject
+ (NSInteger)interfaceOrientationForApplication:(NSObject *)application NS_SWIFT_NAME(interfaceOrientation(for:));
+ (nullable instancetype)prepareFrom:(CGPoint)left right:(CGPoint)right
                                to:(CGPoint)endLeft rightEnd:(CGPoint)endRight
                          duration:(NSTimeInterval)duration orientation:(NSInteger)orientation
                             error:(NSError **)error
    NS_SWIFT_NAME(prepare(left:right:endLeft:endRight:duration:orientation:));
- (BOOL)sendWithTimeout:(NSTimeInterval)timeout error:(NSError **)error NS_SWIFT_NAME(send(timeout:));
@end
NS_ASSUME_NONNULL_END
