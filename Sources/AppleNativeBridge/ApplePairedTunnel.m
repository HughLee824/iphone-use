#import "NativeChannelInternal.h"
#import <xpc/xpc.h>
#import <arpa/inet.h>
#import <unistd.h>

static NSError *PairingError(NSString *code, NSString *message) {
    return [NSError errorWithDomain:@"iPhone-use.ApplePairing" code:1
                          userInfo:@{NSLocalizedDescriptionKey: message, @"somaCode": code}];
}
static xpc_object_t DictionaryValue(xpc_object_t object, const char *key) {
    return object && xpc_get_type(object) == XPC_TYPE_DICTIONARY ? xpc_dictionary_get_value(object, key) : nil;
}
static NSString *StringValue(xpc_object_t object, const char *key) {
    xpc_object_t value = DictionaryValue(object, key);
    return value && xpc_get_type(value) == XPC_TYPE_STRING ? @(xpc_string_get_string_ptr(value)) : nil;
}
static xpc_object_t PairingMessage(const char *type, xpc_object_t body) {
    xpc_object_t message = xpc_dictionary_create_empty();
    xpc_dictionary_set_string(message, "mangledTypeName", type);
    xpc_dictionary_set_value(message, "value", body);
    return message;
}
static xpc_object_t Request(xpc_connection_t connection, dispatch_queue_t queue, xpc_object_t message) {
    NSLock *lock = [NSLock new];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block xpc_object_t response;
    __block BOOL finished = NO;
    xpc_connection_send_message_with_reply(connection, message, queue, ^(xpc_object_t reply) {
        [lock lock];
        if (!finished) { response = reply; finished = YES; dispatch_semaphore_signal(done); }
        [lock unlock];
    });
    long timedOut = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC));
    [lock lock]; finished = YES; xpc_object_t result = timedOut ? nil : response; [lock unlock];
    return result;
}

static xpc_object_t PairingRequest(xpc_connection_t connection, dispatch_queue_t queue, const char *type, xpc_object_t body) {
    return Request(connection, queue, PairingMessage(type, body));
}

NSArray<NSNumber *> *ASNativeRSDPorts(NSString *inventory, NSString *deviceAddress) {
    struct in6_addr target;
    if (inet_pton(AF_INET6, deviceAddress.UTF8String, &target) != 1 || inventory.length > 16 * 1024 * 1024) return @[];
    NSMutableOrderedSet<NSNumber *> *ports = [NSMutableOrderedSet new];
    for (NSString *line in [inventory componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSArray<NSString *> *fields = [[line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
            filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
        if (fields.count < 11 || ![fields[0] isEqual:@"tcp6"] || ![fields[5] isEqual:@"ESTABLISHED"]
            || ![fields[10] hasPrefix:@"remoted:"]) continue;
        NSString *owner = [fields[10] substringFromIndex:8];
        if (!owner.length || [owner rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound) continue;
        NSRange separator = [fields[4] rangeOfString:@"." options:NSBackwardsSearch];
        if (separator.location == NSNotFound) continue;
        NSString *address = [fields[4] substringToIndex:separator.location];
        NSString *number = [fields[4] substringFromIndex:separator.location + 1];
        struct in6_addr actual;
        if (inet_pton(AF_INET6, address.UTF8String, &actual) != 1 || memcmp(&target, &actual, sizeof(target)) != 0
            || !number.length || [number rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound) continue;
        NSInteger port = number.integerValue;
        if (port > 0 && port <= UINT16_MAX) [ports addObject:@(port)];
    }
    return ports.array;
}

@implementation ASPairedTunnel {
    dispatch_queue_t _queue;
    xpc_connection_t _browser, _device, _broker;
    NSString *_deviceIdentifier;
    xpc_object_t _coreDeviceVersion;
    BOOL _brokerFailed;
    xpc_object_t _assertion;
    ASNativeChannel *_discovery;
    NSLock *_lifecycle;
    BOOL _closed, _releaseAcknowledged, _assertionMayExist;
}
- (instancetype)fail:(NSError *)failure error:(NSError **)error {
    BOOL released = [self close];
    if (error) {
        NSMutableDictionary *info = [failure.userInfo mutableCopy];
        info[@"tunnelReleaseAcknowledged"] = @(released);
        *error = [NSError errorWithDomain:failure.domain code:failure.code userInfo:info];
    }
    return nil;
}
- (instancetype)initWithUDID:(NSString *)udid deviceIdentifier:(NSString *)identifier
          endpointInventory:(NSString *)inventory error:(NSError **)error {
    if (!(self = [super init])) return nil;
    _lifecycle = [NSLock new];
    NSUUID *deviceID = [[NSUUID alloc] initWithUUIDString:identifier];
    if (!deviceID) { if (error) *error = PairingError(@"native_device_mismatch", @"CoreDevice identifier must be a UUID"); return nil; }
    _deviceIdentifier = deviceID.UUIDString;
    _peerInfo = @{};
    _queue = dispatch_queue_create("iphone-use.apple.pairing", DISPATCH_QUEUE_SERIAL);
    _browser = xpc_connection_create_mach_service("com.apple.CoreDevice.remotepairingd", _queue, 0);
    NSLock *lock = [NSLock new]; dispatch_semaphore_t found = dispatch_semaphore_create(0);
    __block xpc_endpoint_t endpoint; __block BOOL finished = NO;
    xpc_connection_set_event_handler(_browser, ^(xpc_object_t event) {
        xpc_object_t info = DictionaryValue(DictionaryValue(DictionaryValue(DictionaryValue(event, "value"), "deviceFound"), "_0"), "deviceInfo");
        [lock lock];
        if (!finished && [StringValue(info, "udid") isEqual:udid]
            && [StringValue(DictionaryValue(info, "authState"), "rawCase") isEqual:@"authenticated"]
            && [StringValue(info, "transportProtocolType") isEqual:@"tcp"]) {
            xpc_object_t value = DictionaryValue(info, "endpoint");
            if (value && xpc_get_type(value) == XPC_TYPE_ENDPOINT) { endpoint = value; finished = YES; dispatch_semaphore_signal(found); }
        }
        [lock unlock];
    });
    xpc_connection_activate(_browser);
    xpc_object_t browse = xpc_dictionary_create_empty(); xpc_dictionary_set_bool(browse, "currentDevicesOnly", false);
    xpc_connection_send_message_with_reply(_browser, PairingMessage("RemotePairing.BrowseRequest", browse), _queue, ^(xpc_object_t reply) {});
    dispatch_semaphore_wait(found, dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC));
    [lock lock]; finished = YES; xpc_endpoint_t selected = endpoint; [lock unlock];
    if (!selected) {
        if (error) *error = PairingError(@"native_pairing_unavailable", @"No authenticated paired TCP endpoint for this device in the current user's pairing service"); return nil;
    }
    _device = xpc_connection_create_from_endpoint(selected);
    xpc_connection_set_target_queue(_device, _queue);
    xpc_connection_set_event_handler(_device, ^(xpc_object_t event) {});
    xpc_connection_activate(_device);
    xpc_object_t body = xpc_dictionary_create_empty(); xpc_dictionary_set_int64(body, "flags", 0);
    _assertionMayExist = YES; // A timeout may have created an assertion without returning its ID.
    xpc_object_t reply = PairingRequest(_device, _queue, "RemotePairing.CreateAssertionCommand", body);
    if (DictionaryValue(reply, "error")) _assertionMayExist = NO;
    xpc_object_t response = DictionaryValue(reply, "response");
    _assertion = DictionaryValue(response, "assertionIdentifier");
    _deviceAddress = StringValue(DictionaryValue(response, "info"), "tunnelIPAddress");
    if (!_assertion || xpc_get_type(_assertion) != XPC_TYPE_UUID || !_deviceAddress) {
        if (_assertion && xpc_get_type(_assertion) != XPC_TYPE_UUID) _assertion = nil;
        return [self fail:PairingError(@"native_pairing_denied", @"Apple did not grant a valid paired tunnel assertion; no pairing or identity fallback attempted") error:error];
    }
    if (!inventory) {
        // CoreDevice is the broker: request a named service for this actual device, with our own XPC identity.
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:@"/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/Info.plist"];
        NSString *version = info[@"CFBundleVersion"];
        NSArray<NSString *> *components = [version componentsSeparatedByString:@"."];
        if (!components.count) return [self fail:PairingError(@"native_version_unsupported", @"Installed CoreDevice version unavailable") error:error];
        xpc_object_t numbers = xpc_array_create_empty();
        for (NSString *part in components) {
            if (!part.length || [part rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound)
                return [self fail:PairingError(@"native_version_unsupported", @"Invalid installed CoreDevice version") error:error];
            xpc_array_set_uint64(numbers, XPC_ARRAY_APPEND, part.longLongValue);
        }
        _coreDeviceVersion = xpc_dictionary_create_empty();
        xpc_dictionary_set_value(_coreDeviceVersion, "components", numbers);
        xpc_dictionary_set_int64(_coreDeviceVersion, "originalComponentsCount", components.count);
        xpc_dictionary_set_string(_coreDeviceVersion, "stringValue", version.UTF8String);
        _broker = xpc_connection_create_mach_service("com.apple.CoreDevice.CoreDeviceService", _queue, 0);
        xpc_connection_set_event_handler(_broker, ^(xpc_object_t event) {});
        xpc_connection_activate(_broker);
        return self;
    }
    // Explicit diagnostic route only. Never fall back to socket inventory after a broker failure.
    NSArray<NSNumber *> *ports = ASNativeRSDPorts(inventory, _deviceAddress);
    if (ports.count != 1) return [self fail:PairingError(@"native_endpoint_unavailable",
        [NSString stringWithFormat:@"Expected one RSD endpoint on the granted tunnel; supplied inventory matched %lu candidates.", (unsigned long)ports.count]) error:error];
    NSDictionary *peer;
    NSError *connectionError;
    _discovery = [[ASNativeChannel alloc] initWithAddress:_deviceAddress port:ports.firstObject.unsignedShortValue
        versionFlags:0 handshake:YES peerInfo:&peer error:&connectionError];
    if (!_discovery) return [self fail:connectionError error:error];
    if (![peer[@"Properties"] isKindOfClass:NSDictionary.class] || ![peer[@"Properties"][@"UniqueDeviceID"] isEqual:udid]
        || ![peer[@"Services"] isKindOfClass:NSDictionary.class]) {
        return [self fail:PairingError(@"native_device_mismatch", @"RSD peer identity does not match the paired device") error:error];
    }
    _peerInfo = peer;
    return self;
}
- (ASNativeChannel *)openBrokerService:(NSString *)name error:(NSError **)error {
    if (_brokerFailed) { if (error) *error = PairingError(@"native_broker_closed", @"CoreDevice service connection failed; no replay"); return nil; }
    NSString *invocation = NSUUID.UUID.UUIDString;
    xpc_object_t request = xpc_dictionary_create_empty(), input = xpc_dictionary_create_empty();
    xpc_dictionary_set_string(request, "CoreDevice.deviceIdentifier", _deviceIdentifier.UTF8String);
    xpc_dictionary_set_string(request, "CoreDevice.invocationIdentifier", invocation.UTF8String);
    xpc_dictionary_set_string(request, "CoreDevice.featureIdentifier", "com.apple.dt.servicesocket.create");
    xpc_dictionary_set_string(request, "CoreDevice.actionIdentifier", "com.apple.coredevice.action.createservicesocket");
    xpc_dictionary_set_int64(request, "CoreDevice.CoreDeviceDDIProtocolVersion", 2);
    xpc_dictionary_set_value(request, "CoreDevice.coreDeviceVersion", _coreDeviceVersion);
    xpc_dictionary_set_string(input, "serviceName", name.UTF8String);
    xpc_dictionary_set_value(request, "CoreDevice.input", input);
    xpc_object_t reply = Request(_broker, _queue, request);
    xpc_object_t output = DictionaryValue(reply, "CoreDevice.output");
    xpc_object_t descriptor = DictionaryValue(output, "fileDescriptor");
    xpc_object_t flags = DictionaryValue(output, "remoteXPCVersionFlags");
    xpc_object_t features = DictionaryValue(output, "featureIdentifiers");
    NSString *echoed = StringValue(reply, "CoreDevice.invocationIdentifier");
    NSString *expectedFeature = @{
        @"com.apple.coredevice.hid.universalhidservice": @"com.apple.coredevice.feature.remote.universalhidservice",
        @"com.apple.coredevice.displayservice": @"com.apple.coredevice.feature.getmediastreamserverstatus",
        @"com.apple.coredevice.pasteboardservice": @"com.apple.coredevice.feature.pasteboard",
        @"com.apple.coredevice.hid.indigo": @"com.apple.coredevice.feature.remote.hid.button"
    }[name];
    __block BOOL featureMatched = NO;
    if (features && xpc_get_type(features) == XPC_TYPE_ARRAY) xpc_array_apply(features, ^bool(size_t index, xpc_object_t value) {
        if (xpc_get_type(value) == XPC_TYPE_STRING && [expectedFeature isEqualToString:@(xpc_string_get_string_ptr(value))]) featureMatched = YES;
        return true;
    });
    if (DictionaryValue(reply, "CoreDevice.error") || !descriptor || xpc_get_type(descriptor) != XPC_TYPE_FD || !flags || xpc_get_type(flags) != XPC_TYPE_UINT64
        || !featureMatched || (echoed && ![echoed isEqual:invocation])) {
        _brokerFailed = YES; xpc_connection_cancel(_broker);
        if (error) {
            NSString *reason = reply ? @"CoreDevice did not grant a valid descriptor/version/features"
                                    : @"CoreDevice service socket request timed out; result unknown";
            xpc_object_t remoteError = DictionaryValue(reply, "CoreDevice.error");
            if (remoteError) {
                char *description = xpc_copy_description(remoteError);
                NSString *detail = description ? @(description) : @"CoreDevice returned an error";
                free(description);
                reason = [detail substringToIndex:MIN(detail.length, 2000)];
            }
            *error = PairingError(@"native_service_socket_unavailable",
                [NSString stringWithFormat:@"%@: %@. No fallback or replay.", name, reason]);
        }
        return nil;
    }
    int fd = xpc_fd_dup(descriptor); // This owned duplicate is consumed by the channel even if validation fails.
    ASNativeChannel *channel = [[ASNativeChannel alloc] initWithConnectedFileDescriptor:fd deviceAddress:_deviceAddress
        versionFlags:xpc_uint64_get_value(flags) error:error];
    if (!channel) { _brokerFailed = YES; xpc_connection_cancel(_broker); }
    return channel;
}
- (ASNativeChannel *)openService:(NSString *)name error:(NSError **)error {
    [_lifecycle lock];
    @try {
        if (_closed) { if (error) *error = PairingError(@"native_tunnel_closed", @"Paired tunnel closed"); return nil; }
        if (![@[@"com.apple.coredevice.displayservice", @"com.apple.coredevice.hid.universalhidservice", @"com.apple.coredevice.pasteboardservice", @"com.apple.coredevice.hid.indigo"] containsObject:name]) {
            if (error) *error = PairingError(@"native_service_unsupported", @"Service outside the native media/HID/pasteboard scope"); return nil;
        }
        if (_broker) return [self openBrokerService:name error:error];
        NSDictionary *service = _peerInfo[@"Services"][name];
        if (![service isKindOfClass:NSDictionary.class] || ![service[@"Properties"] isKindOfClass:NSDictionary.class]) {
            if (error) *error = PairingError(@"native_service_unavailable", @"Peer service metadata is missing"); return nil;
        }
        id rawPort = [service isKindOfClass:NSDictionary.class] ? service[@"Port"] : nil;
        NSString *entitlement = service[@"Entitlement"];
        unsigned long port = [rawPort respondsToSelector:@selector(integerValue)] ? [rawPort integerValue] : 0;
        if (!port || port > UINT16_MAX || [entitlement isEqual:@"AppleInternal"] || ![service[@"Properties"][@"UsesRemoteXPC"] boolValue]
            || [service[@"Properties"][@"EncryptSocketData"] boolValue] || [service[@"Properties"][@"ServiceVersion"] integerValue] != 1) {
            if (error) *error = PairingError(@"native_service_unavailable", @"Peer did not advertise an eligible RemoteXPC media/HID/pasteboard endpoint"); return nil;
        }
        id version = _peerInfo[@"Properties"][@"RemoteXPCVersionFlags"];
        if (![version isKindOfClass:NSNumber.class]) {
            if (error) *error = PairingError(@"native_protocol_unsupported", @"Peer did not advertise RemoteXPC version flags"); return nil;
        }
        uint64_t flags = [version unsignedLongLongValue];
        return [[ASNativeChannel alloc] initWithAddress:_deviceAddress port:(uint16_t)port versionFlags:flags handshake:NO peerInfo:NULL error:error];
    } @finally { [_lifecycle unlock]; }
}
- (BOOL)close {
    [_lifecycle lock];
    if (!_closed) {
        _closed = YES;
        [_discovery cancel]; _discovery = nil;
        if (_broker) xpc_connection_cancel(_broker);
        _broker = nil;
        _releaseAcknowledged = !_assertionMayExist;
        if (_assertion && _device) {
            xpc_object_t body = xpc_dictionary_create_empty(); xpc_dictionary_set_value(body, "assertionIdentifier", _assertion);
            xpc_object_t reply = PairingRequest(_device, _queue, "RemotePairing.ReleaseAssertionRequest", body);
            _releaseAcknowledged = DictionaryValue(reply, "response") != nil && DictionaryValue(reply, "error") == nil;
        }
        _assertion = nil;
        if (_device) xpc_connection_cancel(_device);
        if (_browser) xpc_connection_cancel(_browser);
        _device = nil; _browser = nil;
    }
    BOOL acknowledged = _releaseAcknowledged; [_lifecycle unlock]; return acknowledged;
}
- (void)dealloc { [self close]; }
@end
