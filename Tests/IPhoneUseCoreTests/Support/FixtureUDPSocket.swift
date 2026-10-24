import XCTest
import Darwin

final class FixtureUDPSocket {
    let descriptor: Int32
    var endpoint = sockaddr_in6()

    init() throws {
        descriptor = socket(AF_INET6, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        endpoint.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        endpoint.sin6_family = sa_family_t(AF_INET6)
        XCTAssertEqual(inet_pton(AF_INET6, "::1", &endpoint.sin6_addr), 1)
        XCTAssertEqual(
            withUnsafePointer(to: &endpoint) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }, 0)
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        XCTAssertEqual(
            withUnsafeMutablePointer(to: &endpoint) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(descriptor, $0, &length)
                }
            }, 0)
    }
    func close() { Darwin.close(descriptor) }
}
