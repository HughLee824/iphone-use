import Foundation
import Darwin
import CoreFoundation

// usbmuxd connects to the device's loopback listener. Never select a Network
// device or expose a host forwarding port. Each request gets a new USB stream.
struct RunnerUSBTransport {
    let device: String
    var openSocket: (TimeInterval) throws -> RunnerSocket = {
        try RunnerSocket(path: "/var/run/usbmuxd", deadline: $0)
    }

    func requireUSB(deadline: TimeInterval) throws -> Int {
        let socket = try openSocket(deadline)
        defer { socket.close() }
        let reply = try control("ListDevices", fields: [:], socket: socket)
        return try Self.deviceID(reply, serial: device)
    }

    static func deviceID(_ reply: [String: Any], serial: String) throws -> Int {
        guard let devices = reply["DeviceList"] as? [[String: Any]] else {
            throw IPhoneUseError("usbmux_invalid_response", "usbmuxd did not return a device list")
        }
        let matches = devices.filter {
            guard let properties = $0["Properties"] as? [String: Any] else { return false }
            return properties["SerialNumber"] as? String == serial
                && properties["ConnectionType"] as? String == "USB"
        }
        guard matches.count == 1, let number = matches[0]["DeviceID"] as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue > 0,
            number.doubleValue <= Double(UInt32.max), number.doubleValue == Double(number.intValue)
        else {
            throw IPhoneUseError(
                "runner_usb_required",
                """
                Connect the selected iPhone by USB; no unique wired usbmuxd device was found. Wireless\
                 fallback is disabled
                """
            )
        }
        return number.intValue
    }

    private func control(_ type: String, fields: [String: Any], socket: RunnerSocket) throws -> [String: Any] {
        var message = fields
        message["MessageType"] = type
        message["ClientVersionString"] = "iphone-use"
        message["ProgName"] = "iphone-use"
        message["kLibUSBMuxVersion"] = 3
        let body = try PropertyListSerialization.data(fromPropertyList: message, format: .xml, options: 0)
        var header = Data()
        for number in [UInt32(body.count + 16), 1, 8, 1] {
            var value = number.littleEndian
            withUnsafeBytes(of: &value) { header.append(contentsOf: $0) }
        }
        try socket.write(header + body)
        let responseHeader = try socket.read(count: 16)
        let size = try Self.payloadSize(responseHeader)
        guard
            let reply = try PropertyListSerialization.propertyList(
                from: socket.read(count: size), format: nil)
                as? [String: Any]
        else {
            throw IPhoneUseError("usbmux_invalid_response", "Invalid usbmuxd property list")
        }
        return reply
    }

    static func payloadSize(_ data: Data) throws -> Int {
        let bytes = Array(data)
        func word(_ index: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | UInt32(bytes[index + $1]) << ($1 * 8) }
        }
        guard bytes.count == 16, (17...1_048_576).contains(word(0)), word(4) == 1, word(8) == 8, word(12) == 1
        else {
            throw IPhoneUseError("usbmux_invalid_response", "Invalid usbmuxd response header")
        }
        return Int(word(0)) - 16
    }

    func exchange(
        _ request: [String: Any], timeout: TimeInterval, onProgress: (([String: Any]) throws -> Void)? = nil
    )
        throws -> [String: Any] {
        var possiblySent = false
        do {
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            // Re-resolve on every connection: a stale DeviceID can belong to a
            // different phone after unplug/replug. Never replay application data.
            let id = try requireUSB(deadline: deadline)
            let socket = try openSocket(deadline)
            defer { socket.close() }
            let reply = try control(
                "Connect", fields: ["DeviceID": id, "PortNumber": Int(UInt16(47821).bigEndian)],
                socket: socket)
            guard reply["MessageType"] as? String == "Result", reply["Number"] as? Int == 0 else {
                throw IPhoneUseError(
                    "runner_usb_connect_failed", "usbmuxd could not connect to the Runner loopback listener")
            }
            var wire = try jsonData(request)
            guard wire.count < 65536 else {
                throw IPhoneUseError("request_too_large", "Runner request exceeds its size limit")
            }
            wire.append(10)
            possiblySent = true
            try socket.write(wire)
            var receivedProgress = false
            while true {
                let response = try jsonObject(socket.readLine(limit: JSONTransport.limit))
                guard let expected = request["id"] as? String, response["id"] as? String == expected else {
                    throw IPhoneUseError("mismatched_response", "Response request ID does not match")
                }
                guard response["event"] != nil else { return response }
                guard response["event"] as? String == "input_started", !receivedProgress,
                    request["op"] as? String == "act", request["inputProgress"] as? Bool == true,
                    let onProgress
                else {
                    throw IPhoneUseError(
                        "invalid_progress", "Unexpected Runner input progress; no automatic replay")
                }
                receivedProgress = true
                try onProgress(response)
            }
        } catch {
            throw TransportError(description: String(describing: error), possiblySent: possiblySent)
        }
    }
}

// All reads/writes share one monotonic deadline, including short I/O and EINTR.
// Nonblocking sockets avoid a slow peer extending a per-read timeout forever.
final class RunnerSocket {
    private var descriptor: Int32
    private let deadline: TimeInterval
    private var lineBuffer = Data()

    init(ownedDescriptor: Int32, deadline: TimeInterval) throws {
        descriptor = ownedDescriptor
        self.deadline = deadline
        var one: Int32 = 1
        guard descriptor >= 0, fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
            fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
                == 0
        else {
            close()
            throw IPhoneUseError("runner_socket_failed", "Cannot configure Runner socket")
        }
    }

    convenience init(path: String, deadline: TimeInterval) throws {
        try self.init(ownedDescriptor: Darwin.socket(AF_UNIX, SOCK_STREAM, 0), deadline: deadline)
        do {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let name = Array(path.utf8) + [0]
            guard name.count <= MemoryLayout.size(ofValue: address.sun_path) else {
                throw IPhoneUseError("runner_socket_failed", "Unix socket path is too long")
            }
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: name) }
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result != 0 {
                guard errno == EINPROGRESS else { throw failure() }
                try wait(POLLOUT)
                var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                    throw failure()
                }
            }
        } catch { close(); throw error }
    }

    func close() { if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 } }
    deinit { close() }

    private func failure() -> IPhoneUseError {
        IPhoneUseError(
            "runner_socket_failed", "Runner USB socket failed (errno \(errno)); no automatic replay")
    }

    private func wait(_ events: Int32) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                throw IPhoneUseError(
                    "runner_socket_timeout", "Runner USB response timeout; no automatic replay")
            }
            var descriptor = pollfd(fd: descriptor, events: Int16(events), revents: 0)
            let result = poll(&descriptor, 1, Int32(min(remaining * 1000 + 1, Double(Int32.max))))
            if result > 0 { return } // read/write reports EOF or the concrete error.
            if result < 0, errno != EINTR { throw failure() }
        }
    }

    func write(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            try wait(POLLOUT)
            let count = data.withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if count > 0 {
                offset += count
            } else if count < 0, [EAGAIN, EINTR].contains(errno) {
                continue
            } else {
                throw failure()
            }
        }
    }

    private func chunk(maximum: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maximum)
        while true {
            try wait(POLLIN)
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 { return Data(buffer.prefix(count)) }
            if count < 0, [EAGAIN, EINTR].contains(errno) { continue }
            if count == 0 {
                throw IPhoneUseError("runner_socket_closed", "Runner USB connection closed before response")
            }
            throw failure()
        }
    }

    func read(count: Int) throws -> Data {
        var data = Data()
        while data.count < count { data.append(try chunk(maximum: count - data.count)) }
        return data
    }

    func readLine(limit: Int) throws -> Data {
        while true {
            if let end = lineBuffer.firstIndex(of: 10) {
                let line = Data(lineBuffer[..<end])
                guard line.count <= limit else {
                    throw IPhoneUseError("response_too_large", "Runner response exceeds size limit")
                }
                lineBuffer = Data(lineBuffer[lineBuffer.index(after: end)...])
                return line
            }
            guard lineBuffer.count <= limit else {
                throw IPhoneUseError("response_too_large", "Runner response exceeds size limit")
            }
            lineBuffer.append(try chunk(maximum: min(65536, limit - lineBuffer.count + 1)))
        }
    }
}
