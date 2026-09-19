#import "AppleNativeBridge.h"
NS_ASSUME_NONNULL_BEGIN

@interface ASNativeChannel (PairedEndpoint)
// Consumes fd on success AND failure. The caller must pass an owned descriptor.
- (nullable instancetype)initWithConnectedFileDescriptor:(int)fd versionFlags:(uint64_t)flags
                                              handshake:(BOOL)handshake
                                               peerInfo:(NSDictionary * _Nullable * _Nullable)peerInfo error:(NSError **)error;
- (nullable instancetype)initWithAddress:(NSString *)address port:(uint16_t)port
                           versionFlags:(uint64_t)flags handshake:(BOOL)handshake
                               peerInfo:(NSDictionary * _Nullable * _Nullable)peerInfo error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
