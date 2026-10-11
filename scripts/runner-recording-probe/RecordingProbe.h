#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Experimental, fixed-duration XCTest probe. Not part of the released Runner.
@interface IPhoneUseRecordingProbe : NSObject
+ (void)runWithCompletion:(void (^)(NSDictionary<NSString *, id> *facts))completion;
@end
NS_ASSUME_NONNULL_END
