import Foundation
import Darwin

// One host owns one device. The kernel releases this lock even if the host crashes.
// Keep the inode: unlinking a lock file can let two hosts lock different inodes.
final class DeviceLock {
    private let descriptor: Int32

    init(root: URL, device: String) throws {
        guard device.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil else {
            throw IPhoneUseError("invalid_device_id", "CoreDevice returned an invalid UDID")
        }
        let path = root.appendingPathComponent("device-\(device).lock").path
        descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw IPhoneUseError("device_lock_failed", "Cannot open device lock") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw IPhoneUseError("device_busy", "This device already has an iPhone-use session")
        }
    }

    deinit { Darwin.close(descriptor) }
}

// Hold the default-root lock as well as any selected-root lock so environment
// overrides cannot let separate sessions control the same device.
final class SessionDeviceLock {
    private let locks: [DeviceLock]

    init(root: URL, device: String) throws {
        let defaultRoot = SessionPaths.defaultRoot
        try SessionPaths.secureDirectory(defaultRoot)
        var held = [try DeviceLock(root: defaultRoot, device: device)]
        if root.resolvingSymlinksInPath() != defaultRoot.resolvingSymlinksInPath() {
            held.append(try DeviceLock(root: root, device: device))
        }
        locks = held
    }
}
