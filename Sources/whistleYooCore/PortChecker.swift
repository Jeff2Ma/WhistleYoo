import Darwin
import Foundation

public protocol PortAvailabilityChecking: Sendable {
    func isAvailable(port: Int, host: String) -> Bool
}

public struct PortChecker: PortAvailabilityChecking, Sendable {
    public init() {}

    public func isAvailable(port: Int, host: String) -> Bool {
        guard (1...65535).contains(port) else { return false }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var yes: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        let bindHost = host == "localhost" ? "127.0.0.1" : host
        guard inet_pton(AF_INET, bindHost, &address.sin_addr) == 1 else { return false }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
