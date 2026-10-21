#import "AppleNativeBridge.h"
#import <dlfcn.h>
#import <string.h>

// MobileDevice's C ABI is isolated from the host: unavailable symbols or a
// stalled lockdown call cannot block connection or preview rendering.
BOOL ASReadDeviceLog(NSString *udid, void (^ready)(void), void (^line)(NSString *), NSError **error) {
    void *library = dlopen("/Library/Apple/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice", RTLD_NOW | RTLD_LOCAL);
    CFArrayRef (*devices)(void) = dlsym(library, "AMDCreateDeviceList");
    CFStringRef (*identifier)(CFTypeRef) = dlsym(library, "AMDeviceCopyDeviceIdentifier");
    int (*interface)(CFTypeRef) = dlsym(library, "AMDeviceGetInterfaceType");
    int (*connect)(CFTypeRef) = dlsym(library, "AMDeviceConnect");
    int (*start)(CFTypeRef) = dlsym(library, "AMDeviceStartSession");
    int (*stop)(CFTypeRef) = dlsym(library, "AMDeviceStopSession");
    int (*disconnect)(CFTypeRef) = dlsym(library, "AMDeviceDisconnect");
    int (*service)(CFTypeRef, CFStringRef, CFDictionaryRef, CFTypeRef *) = dlsym(library, "AMDeviceSecureStartService");
    int (*receive)(CFTypeRef, void *, unsigned int) = dlsym(library, "AMDServiceConnectionReceive");
    void (*invalidate)(CFTypeRef) = dlsym(library, "AMDServiceConnectionInvalidate");
    if (!library || !devices || !identifier || !interface || !connect || !start || !stop || !disconnect || !service || !receive || !invalidate) goto unavailable;
    {
        NSArray *list = CFBridgingRelease(devices());
        id selected = nil;
        for (id device in list) {
            NSString *serial = CFBridgingRelease(identifier((__bridge CFTypeRef)device));
            if ([serial isEqualToString:udid] && interface((__bridge CFTypeRef)device) == 1) {
                if (selected) goto unavailable;
                selected = device;
            }
        }
        if (!selected) goto unavailable;
        CFTypeRef device = (__bridge CFTypeRef)selected;
        if (connect(device) != 0) goto unavailable;
        if (start(device) != 0) { disconnect(device); goto unavailable; }
        CFTypeRef channel = NULL;
        int result = service(device, CFSTR("com.apple.syslog_relay"), NULL, &channel);
        stop(device); disconnect(device);
        if (result != 0 || !channel) goto unavailable;
        ready();
        NSMutableData *pending = [NSMutableData data];
        BOOL dropping = NO;
        char bytes[4096];
        int count;
        while ((count = receive(channel, bytes, sizeof(bytes))) > 0) {
            @autoreleasepool {
                int segment = 0;
                for (int i = 0; i < count; i++) {
                    if (bytes[i] == '\n' || bytes[i] == '\0') {
                        if (!dropping && pending.length + i - segment <= 16384) {
                            [pending appendBytes:bytes + segment length:i - segment];
                            // Filter before allocating/bridging strings. Unrelated
                            // device activity never reaches the Swift parser.
                            if (memmem(pending.bytes, pending.length, " testmanagerd", 13)) {
                                NSString *value = [[NSString alloc] initWithData:pending encoding:NSUTF8StringEncoding];
                                if (value) line(value);
                            }
                        }
                        pending.length = 0; dropping = NO; segment = i + 1;
                    }
                }
                if (!dropping) {
                    if (pending.length + count - segment <= 16384) [pending appendBytes:bytes + segment length:count - segment];
                    else { pending.length = 0; dropping = YES; }
                }
            }
        }
        invalidate(channel); CFRelease(channel);
    }
unavailable:
    if (error) *error = [NSError errorWithDomain:@"iPhone-use.DeviceLog" code:1
        userInfo:@{NSLocalizedDescriptionKey:@"Live authorization evidence unavailable; connection failures are not proof of an authorization prompt"}];
    return NO;
}
