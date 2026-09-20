#import "AppleNativeBridge.h"
#import <xpc/xpc.h>
#import <dlfcn.h>
#import <CoreFoundation/CoreFoundation.h>
#import "NativeChannelInternal.h"
#import <arpa/inet.h>
#import <fcntl.h>
#import <poll.h>

static NSError *Failure(NSString *code, NSString *message) {
    return [NSError errorWithDomain:@"AgentSoma.AppleNative" code:1
                          userInfo:@{NSLocalizedDescriptionKey:message, @"somaCode":code}];
}

@implementation ASNativeUnsigned
- (instancetype)initWithValue:(uint64_t)value { if ((self = [super init])) _value = value; return self; }
@end

// Signatures checked against macOS 27 Apple RemoteXPC implementation and call sites.
// Keep handles loaded: OS objects and blocks can outlive an individual call.
static void *remote;
static void (*setHandler)(id, void (^)(xpc_object_t));
static void (*activateConnection)(id);
static void (*cancelConnection)(id);
static void (*sendMessage)(id, xpc_object_t);
static void (*sendReply)(id, xpc_object_t, dispatch_queue_t, void (^)(xpc_object_t));
static void (*sendBarrier)(id, dispatch_block_t);
static id (*createFDConnection)(int, dispatch_queue_t, uint64_t, uint64_t) __attribute__((ns_returns_retained));
static uint64_t (*failsafeVersion)(void);

static BOOL Load(NSError **error) {
    static dispatch_once_t once;
    static BOOL ready;
    dispatch_once(&once, ^{
        remote = dlopen("/System/Library/PrivateFrameworks/RemoteXPC.framework/RemoteXPC", RTLD_NOW | RTLD_LOCAL);
#define LOAD(handle, target, symbol) target = dlsym(handle, symbol)
        if (!remote) return;
        LOAD(remote, setHandler, "xpc_remote_connection_set_event_handler");
        LOAD(remote, activateConnection, "xpc_remote_connection_activate");
        LOAD(remote, cancelConnection, "xpc_remote_connection_cancel");
        LOAD(remote, sendMessage, "xpc_remote_connection_send_message");
        LOAD(remote, sendReply, "xpc_remote_connection_send_message_with_reply");
        LOAD(remote, sendBarrier, "xpc_remote_connection_send_barrier");
        LOAD(remote, createFDConnection, "xpc_remote_connection_create_with_connected_fd");
        LOAD(remote, failsafeVersion, "xpc_remote_connection_get_failsafe_version_flags");
#undef LOAD
        ready = setHandler && activateConnection && cancelConnection && sendMessage && sendReply && sendBarrier
            && createFDConnection && failsafeVersion;
    });
    if (!ready && error) *error = Failure(@"native_api_unavailable", @"Installed Apple RemoteXPC ABI is unavailable");
    return ready;
}

static xpc_object_t Encode(id value, NSUInteger depth, NSError **error) {
    if (depth > 32) { if (error) *error = Failure(@"native_invalid_message", @"XPC nesting exceeds 32"); return nil; }
    if ([value isKindOfClass:ASNativeUnsigned.class]) return xpc_uint64_create(((ASNativeUnsigned *)value).value);
    if ([value isKindOfClass:NSString.class]) return xpc_string_create([value UTF8String]);
    if ([value isKindOfClass:NSData.class]) return xpc_data_create([value bytes], [value length]);
    if ([value isKindOfClass:NSUUID.class]) { uuid_t bytes; [value getUUIDBytes:bytes]; return xpc_uuid_create(bytes); }
    if (value == NSNull.null) return xpc_null_create();
    if ([value isKindOfClass:NSNumber.class]) {
        if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return xpc_bool_create([value boolValue]);
        const char *type = [value objCType];
        if (strchr("fd", type[0])) return xpc_double_create([value doubleValue]);
        if (strchr("CISLQ", type[0])) return xpc_uint64_create([value unsignedLongLongValue]);
        return xpc_int64_create([value longLongValue]);
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        xpc_object_t result = xpc_dictionary_create_empty();
        for (id key in value) {
            if (![key isKindOfClass:NSString.class]) break;
            xpc_object_t item = Encode(value[key], depth + 1, error);
            if (!item) return nil;
            xpc_dictionary_set_value(result, [key UTF8String], item);
        }
        if (xpc_dictionary_get_count(result) == [value count]) return result;
    }
    if ([value isKindOfClass:NSArray.class]) {
        xpc_object_t result = xpc_array_create_empty();
        for (id item in value) {
            xpc_object_t encoded = Encode(item, depth + 1, error);
            if (!encoded) return nil;
            xpc_array_append_value(result, encoded);
        }
        return result;
    }
    if (error) *error = Failure(@"native_invalid_message", @"Unsupported XPC value");
    return nil;
}

static id Decode(xpc_object_t value, NSUInteger depth) {
    if (!value || depth > 32) return nil;
    xpc_type_t type = xpc_get_type(value);
    if (type == XPC_TYPE_STRING) return @(xpc_string_get_string_ptr(value));
    if (type == XPC_TYPE_INT64) return @(xpc_int64_get_value(value));
    if (type == XPC_TYPE_UINT64) return @(xpc_uint64_get_value(value));
    if (type == XPC_TYPE_DOUBLE) return @(xpc_double_get_value(value));
    if (type == XPC_TYPE_BOOL) return @(xpc_bool_get_value(value));
    if (type == XPC_TYPE_NULL) return NSNull.null;
    if (type == XPC_TYPE_UUID) return [[NSUUID alloc] initWithUUIDBytes:xpc_uuid_get_bytes(value)];
    if (type == XPC_TYPE_DATA) return [NSData dataWithBytes:xpc_data_get_bytes_ptr(value) length:xpc_data_get_length(value)];
    if (type == XPC_TYPE_DICTIONARY) {
        NSMutableDictionary *result = [NSMutableDictionary new];
        BOOL valid = xpc_dictionary_apply(value, ^bool(const char *key, xpc_object_t item) {
            id decoded = Decode(item, depth + 1);
            if (!decoded) return false;
            result[@(key)] = decoded; return true;
        });
        return valid ? result : nil;
    }
    if (type == XPC_TYPE_ARRAY) {
        NSMutableArray *result = [NSMutableArray new];
        BOOL valid = xpc_array_apply(value, ^bool(size_t index, xpc_object_t item) {
            id decoded = Decode(item, depth + 1);
            if (!decoded) return false;
            [result addObject:decoded]; return true;
        });
        return valid ? result : nil;
    }
    return nil;
}

NSDictionary *ASNativeRoundTrip(NSDictionary *value, NSError **error) {
    xpc_object_t encoded = Encode(value, 0, error);
    return encoded ? Decode(encoded, 0) : nil;
}

@implementation ASNativeChannel {
    id _connection;
    dispatch_queue_t _queue;
    NSError *_failure;
    NSNumber *_terminalEventUptime;
}
- (instancetype)initWithConnectedFileDescriptor:(int)fd deviceAddress:(NSString *)address
                                   versionFlags:(uint64_t)flags error:(NSError **)error {
    struct sockaddr_in6 peer = {0}; socklen_t size = sizeof(peer);
    struct in6_addr expected; int type = 0; socklen_t typeSize = sizeof(type);
    if (fd < 0 || inet_pton(AF_INET6, address.UTF8String, &expected) != 1
        || getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &typeSize) != 0 || type != SOCK_STREAM
        || getpeername(fd, (struct sockaddr *)&peer, &size) != 0 || size != sizeof(peer)
        || peer.sin6_family != AF_INET6 || !peer.sin6_port || memcmp(&peer.sin6_addr, &expected, sizeof(expected)) != 0) {
        if (fd >= 0) close(fd);
        if (error) *error = Failure(@"native_device_mismatch", @"CoreDevice did not deliver a TCP connection to the granted device tunnel");
        return nil;
    }
    if (!flags) {
        close(fd); if (error) *error = Failure(@"native_protocol_unsupported", @"CoreDevice omitted RemoteXPC version flags"); return nil;
    }
    return [self initWithConnectedFileDescriptor:fd versionFlags:flags handshake:NO peerInfo:NULL error:error];
}
- (instancetype)initWithAddress:(NSString *)address port:(uint16_t)port versionFlags:(uint64_t)flags
                     handshake:(BOOL)handshake peerInfo:(NSDictionary **)peerInfo error:(NSError **)error {
    struct sockaddr_in6 endpoint = { .sin6_len = sizeof(endpoint), .sin6_family = AF_INET6, .sin6_port = htons(port) };
    if (!port || inet_pton(AF_INET6, address.UTF8String, &endpoint.sin6_addr) != 1) {
        if (error) *error = Failure(@"native_endpoint_invalid", @"Invalid paired IPv6 endpoint"); return nil;
    }
    int fd = socket(AF_INET6, SOCK_STREAM, 0);
    if (fd < 0) { if (error) *error = Failure(@"native_socket_failed", @"Could not create paired socket"); return nil; }
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    fcntl(fd, F_SETFL, O_NONBLOCK);
    int connected = connect(fd, (struct sockaddr *)&endpoint, sizeof(endpoint));
    if (connected < 0 && errno == EINPROGRESS) {
        struct pollfd check = { .fd = fd, .events = POLLOUT };
        int socketError = 0; socklen_t size = sizeof(socketError);
        connected = poll(&check, 1, 5000) > 0 && getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0 && socketError == 0 ? 0 : -1;
    }
    if (connected < 0) {
        close(fd); if (error) *error = Failure(@"native_connect_failed", @"Paired socket connection failed or timed out"); return nil;
    }
    return [self initWithConnectedFileDescriptor:fd versionFlags:flags handshake:handshake peerInfo:peerInfo error:error];
}
- (instancetype)initWithConnectedFileDescriptor:(int)fd versionFlags:(uint64_t)flags
                                     handshake:(BOOL)handshake peerInfo:(NSDictionary **)peerInfo error:(NSError **)error {
    if (!(self = [super init]) || !Load(error)) { if (fd >= 0) close(fd); return nil; }
    if (fd < 0 || (flags && ((flags >> 56) != 1 || (flags & 0x00fffffffffffff9ULL)))) {
        if (fd >= 0) close(fd);
        if (error) *error = Failure(@"native_protocol_unsupported", @"Invalid connected descriptor or unsupported RemoteXPC version flags"); return nil;
    }
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    fcntl(fd, F_SETFL, O_NONBLOCK);
    _queue = dispatch_queue_create("agentsoma.apple.paired-channel", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(_queue, (__bridge const void *)self, (__bridge void *)self, NULL);
    // macOS 27 ABI: fd, queue, wire version flags, client/server mode flags. The created object owns fd.
    _connection = createFDConnection(fd, _queue, flags ?: failsafeVersion(), 0);
    if (!_connection) { close(fd); if (error) *error = Failure(@"native_connection_failed", @"RemoteXPC did not adopt the paired socket"); return nil; }
    NSLock *lock = [NSLock new];
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    __block NSDictionary *received;
    __block NSError *handshakeError;
    __block BOOL finished = NO;
    __weak ASNativeChannel *weakSelf = self;
    setHandler(_connection, ^(xpc_object_t event) {
        ASNativeChannel *owner = weakSelf;
        if (!owner) return;
        [lock lock];
        if (xpc_get_type(event) == XPC_TYPE_ERROR) {
            if (!owner->_terminalEventUptime) owner->_terminalEventUptime = @(NSProcessInfo.processInfo.systemUptime);
            owner->_failure = Failure(@"native_connection_lost", @"Paired RemoteXPC connection ended");
            if (!finished) { handshakeError = owner->_failure; finished = YES; dispatch_semaphore_signal(ready); }
        } else if (handshake && !finished) {
            id decoded = Decode(event, 0);
            if ([decoded isKindOfClass:NSDictionary.class] && [decoded[@"MessageType"] isEqual:@"Handshake"]) {
                received = decoded; finished = YES; dispatch_semaphore_signal(ready);
            }
        }
        [lock unlock];
    });
    activateConnection(_connection);
    if (handshake) {
        // A new, ordinary client identity. No Apple process identity or sensitive-properties claim.
        NSDictionary *hello = @{@"MessageType": @"Handshake", @"MessagingProtocolVersion": [[ASNativeUnsigned alloc] initWithValue:7],
            @"UUID": [NSUUID UUID], @"Properties": @{@"RemoteXPCVersionFlags": [[ASNativeUnsigned alloc] initWithValue:failsafeVersion()]}, @"Services": @{}};
        sendMessage(_connection, Encode(hello, 0, error));
        long timedOut = dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC));
        [lock lock]; finished = YES; NSDictionary *result = received; NSError *failure = handshakeError; [lock unlock];
        if (timedOut || !result) {
            [self cancel]; if (error) *error = failure ?: Failure(@"native_handshake_timeout", @"Paired RSD handshake timed out"); return nil;
        }
        if (peerInfo) *peerInfo = result;
    }
    return self;
}
- (void)request:(NSDictionary *)message completion:(void (^)(NSDictionary *, NSError *))completion {
    dispatch_async(_queue, ^{
        if (self->_failure || !self->_connection) { completion(nil, self->_failure ?: Failure(@"native_connection_closed", @"Connection is closed")); return; }
        NSError *error = nil;
        xpc_object_t encoded = Encode(message, 0, &error);
        if (!encoded) { completion(nil, error); return; }
        // Native RemoteXPC owns wire message IDs and reply channels. An event is never used as a reply.
        sendReply(self->_connection, encoded, self->_queue, ^(xpc_object_t reply) {
            id result = Decode(reply, 0);
            if ([result isKindOfClass:NSDictionary.class]) completion(result, nil);
            else completion(nil, Failure(@"native_invalid_reply", @"RemoteXPC failed or returned a non-dictionary reply"));
        });
    });
}
- (void)send:(NSDictionary *)message completion:(void (^)(NSError *))completion {
    dispatch_async(_queue, ^{
        if (self->_failure || !self->_connection) { completion(self->_failure ?: Failure(@"native_connection_closed", @"Connection is closed")); return; }
        NSError *error = nil;
        xpc_object_t encoded = Encode(message, 0, &error);
        if (!encoded) { completion(error); return; }
        sendMessage(self->_connection, encoded);
        sendBarrier(self->_connection, ^{ completion(self->_failure); });
    });
}
- (void)cancel {
    if (!_queue) return;
    dispatch_async(_queue, ^{
        if (self->_connection) { cancelConnection(self->_connection); self->_connection = nil; }
        self->_failure = Failure(@"native_connection_closed", @"Connection cancelled");
    });
}
- (NSDictionary *)diagnostics {
    __block NSDictionary *result;
    void (^snapshot)(void) = ^{
        result = @{@"connectionPresent": @(self->_connection != nil),
                   @"terminalEventAgeSeconds": self->_terminalEventUptime ? @(MAX(0, NSProcessInfo.processInfo.systemUptime - self->_terminalEventUptime.doubleValue)) : NSNull.null,
                   @"errorCode": self->_failure.userInfo[@"somaCode"] ?: NSNull.null};
    };
    if (dispatch_get_specific((__bridge const void *)self)) snapshot(); else dispatch_sync(_queue, snapshot);
    return result;
}
- (void)dealloc { if (_connection) cancelConnection(_connection); }
@end

@interface NSObject (AgentSomaAVC)
- (id)initWithMode:(NSInteger)mode options:(NSDictionary *)options error:(NSError **)error;
- (id)negotiatorSettings;
- (BOOL)createOffer;
- (NSData *)offer;
- (BOOL)setAnswer:(NSData *)answer withError:(NSError **)error;
@end
@implementation ASMediaNegotiator {
    id _negotiator;
}
- (instancetype)initWithError:(NSError **)error {
    if (!(self = [super init])) return nil;
    static void *avc;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ avc = dlopen("/System/Library/PrivateFrameworks/AVConference.framework/AVConference", RTLD_NOW | RTLD_LOCAL); });
    Class cls = avc ? NSClassFromString(@"AVCMediaStreamNegotiator") : Nil;
    if (!cls || ![cls instancesRespondToSelector:@selector(initWithMode:options:error:)]) {
        if (error) *error = Failure(@"native_media_unsupported", @"Apple media negotiator is unavailable"); return nil;
    }
    // Mode 5 resolves to CoreDeviceScreenSharing on macOS 27. Check the runtime class,
    // rather than using an unrelated mode if a later framework changes its meaning.
    _negotiator = [[cls alloc] initWithMode:5 options:@{@"AVCMediaStreamNegotiatorAccessNetworkType":@1,
                        @"AVCMediaStreamNegotiatorTransportProtocolType":@2} error:error];
    if (!_negotiator) return nil;
    if (![NSStringFromClass([[_negotiator negotiatorSettings] class]) isEqualToString:@"AVCMediaStreamNegotiatorSettingsCoreDeviceScreenSharing"]
        || ![_negotiator createOffer] || ![[_negotiator offer] isKindOfClass:NSData.class]) {
        if (error) *error = Failure(@"native_media_unsupported", @"Apple did not generate a CoreDevice screen sharing offer"); return nil;
    }
    return self;
}
- (NSData *)offer { return [_negotiator offer]; }
- (BOOL)acceptAnswer:(NSData *)answer error:(NSError **)error { return [_negotiator setAnswer:answer withError:error]; }
@end
