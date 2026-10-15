#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// The guard only lives during XCTest bootstrap, before our command server exists.
@interface RunnerStartupGuard : NSObject
+ (void)finish;
+ (NSDictionary<NSString *, id> *)facts;
@end
NS_ASSUME_NONNULL_END
