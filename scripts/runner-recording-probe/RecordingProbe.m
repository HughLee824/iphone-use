#import "RecordingProbe.h"
#import <XCTest/XCTest.h>
#import <dlfcn.h>

// Signatures observed in the installed Xcode 27 XCTest runtime. This probe
// intentionally does not claim portability or expose a production capability.
@interface NSObject (IPhoneUseRecordingProbeRuntime)
+ (id)sharedSession;
+ (id)mainScreen;
- (id)daemonProxy;
- (BOOL)supportsScreenRecording;
- (NSInteger)displayID;
- (id)initWithCodec:(NSInteger)codec frameRate:(double)rate;
- (id)initWithScreenID:(NSInteger)screen rect:(CGRect)rect preferredEncoding:(id)encoding;
- (void)_XCT_startScreenRecordingWithRequest:(id)request withReply:(void (^)(id, NSError *))reply;
- (void)_XCT_stopScreenRecordingWithUUID:(NSUUID *)uuid withReply:(void (^)(NSError *))reply;
- (NSUUID *)attachmentUUID;
- (NSString *)dataContainerRelativeAttachmentPath;
- (NSURL *)dataContainerURLPrefix;
- (id)initWithAttachmentFutureMetadata:(id)metadata name:(NSString *)name deviceIdentifier:(id)identifier;
- (void)didFinishWritingAttachmentWithMetadata:(id)metadata;
@end

@implementation IPhoneUseRecordingProbe
+ (void)runWithCompletion:(void (^)(NSDictionary<NSString *, id> *))completion {
    @try {
        id session = [NSClassFromString(@"XCTRunnerDaemonSession") sharedSession];
        NSInteger *codec = dlsym(RTLD_DEFAULT, "XCTVideoCodecH264");
        if (!codec || ![session supportsScreenRecording]) {
            completion(@{@"error": @"recording_runtime_unsupported"});
            return;
        }
        id proxy = [session daemonProxy];
        id encoding = [[NSClassFromString(@"XCTVideoEncoding") alloc] initWithCodec:*codec frameRate:30];
        id screen = [NSClassFromString(@"XCUIScreen") mainScreen];
        id request = [[NSClassFromString(@"XCTScreenRecordingRequest") alloc]
                      initWithScreenID:[screen displayID] rect:CGRectNull preferredEncoding:encoding];
        // Exactly one start request. Even a late successful reply schedules an
        // owned UUID stop; a timeout never triggers another start.
        [proxy _XCT_startScreenRecordingWithRequest:request withReply:^(id metadata, NSError *error) {
            if (error || !metadata) {
                completion(@{@"error": error.description ?: @"missing_recording_metadata"});
                return;
            }
            NSUUID *uuid = [metadata attachmentUUID];
            if (![uuid isKindOfClass:NSUUID.class]) {
                completion(@{@"error": @"missing_owned_uuid", @"outcome": @"unknown"});
                return;
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                [proxy _XCT_stopScreenRecordingWithUUID:uuid withReply:^(NSError *stopError) {
                    // XCTest activity registration requires the main thread.
                    dispatch_async(dispatch_get_main_queue(), ^{
                        @try {
                            if (stopError) {
                                completion(@{@"recordingID": uuid.UUIDString,
                                             @"error": stopError.description, @"outcome": @"unknown"});
                                return;
                            }
                            XCTAttachment *attachment = [[NSClassFromString(@"XCTAttachmentFuture") alloc]
                                initWithAttachmentFutureMetadata:metadata name:@"iphone-use-owned-recording" deviceIdentifier:nil];
                            attachment.lifetime = XCTAttachmentLifetimeKeepAlways;
                            [XCTContext runActivityNamed:@"Owned recording" block:^(id<XCTActivity> activity) {
                                [activity addAttachment:attachment];
                            }];
                            [[NSClassFromString(@"XCTRunnerIDESession") sharedSession]
                                didFinishWritingAttachmentWithMetadata:metadata];
                            // Only the file returned for this exact recording is
                            // inspected. Permission failure is evidence, not a
                            // reason to attempt a different container/domain.
                            NSURL *prefix = [metadata dataContainerURLPrefix];
                            NSString *relative = [metadata dataContainerRelativeAttachmentPath];
                            NSError *readError = nil;
                            NSDictionary *attributes = nil;
                            if (prefix.isFileURL && relative.length > 0 && !relative.isAbsolutePath &&
                                ![relative.pathComponents containsObject:@".."]) {
                                attributes = [[NSFileManager defaultManager]
                                    attributesOfItemAtPath:[prefix URLByAppendingPathComponent:relative].path error:&readError];
                            }
                            completion(@{@"recordingID": uuid.UUIDString, @"stopAcknowledged": @YES,
                                         @"fileValidated": @NO, @"directReadSucceeded": @(attributes != nil),
                                         @"readErrorDomain": readError.domain ?: @"",
                                         @"readErrorCode": @(readError.code)});
                        } @catch (NSException *exception) {
                            completion(@{@"recordingID": uuid.UUIDString, @"error": exception.description});
                        }
                    });
                }];
            });
        }];
    } @catch (NSException *exception) {
        completion(@{@"error": exception.description, @"outcome": @"unknown"});
    }
}
@end
