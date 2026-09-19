#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// NSNumber canonicalizes small signed/unsigned values. Preserve required XPC uint64 tags explicitly.
@interface ASNativeUnsigned : NSObject
- (instancetype)initWithValue:(uint64_t)value;
@property(nonatomic, readonly) uint64_t value;
@end
// Only C/Objective-C ABI; no private Swift ABI, entitlement or caller-identity shim.
@interface ASNativeChannel : NSObject
- (instancetype)init NS_UNAVAILABLE;
// Consumes an owned descriptor on every path. Require TCP on the granted device IPv6 address.
- (nullable instancetype)initWithConnectedFileDescriptor:(int)fd deviceAddress:(NSString *)address
                                           versionFlags:(uint64_t)flags error:(NSError **)error;
- (void)request:(NSDictionary *)message completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion;
// A barrier confirms local queue drainage, never device execution.
- (void)send:(NSDictionary *)message completion:(void (^)(NSError * _Nullable))completion;
- (void)cancel;
@end

// An assertion granted by the logged-in user's pairing daemon owns this tunnel.
// Opening services is explicit; it never retries a denied RemoteServiceDiscovery lookup.
@interface ASPairedTunnel : NSObject
- (instancetype)init NS_UNAVAILABLE;
- (nullable instancetype)initWithUDID:(NSString *)udid deviceIdentifier:(NSString *)identifier
                   endpointInventory:(nullable NSString *)inventory error:(NSError **)error;
@property(nonatomic, readonly) NSString *deviceAddress;
@property(nonatomic, readonly) NSDictionary *peerInfo;
- (nullable ASNativeChannel *)openService:(NSString *)name error:(NSError **)error;
- (BOOL)close;
@end

// Bounded parser for Apple netstat -anvl output; tested against malformed host fixtures.
FOUNDATION_EXPORT NSArray<NSNumber *> *ASNativeRSDPorts(NSString *inventory, NSString *deviceAddress);

@interface ASMediaNegotiator : NSObject
- (instancetype)init NS_UNAVAILABLE;
- (nullable instancetype)initWithError:(NSError **)error;
@property(nonatomic, readonly) NSData *offer;
- (BOOL)acceptAnswer:(NSData *)answer error:(NSError **)error;
@end

// Exercise the exact value conversion used by the native channel, without a device.
FOUNDATION_EXPORT NSDictionary * _Nullable ASNativeRoundTrip(NSDictionary *value, NSError **error);
NS_ASSUME_NONNULL_END
