import Foundation
import Darwin

public struct NetworkService: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let device: String?
    public let hardwarePort: String?
    public let disabled: Bool

    public var id: String { name }

    public init(name: String, device: String?, hardwarePort: String?, disabled: Bool) {
        self.name = name
        self.device = device
        self.hardwarePort = hardwarePort
        self.disabled = disabled
    }
}

/// Resolves a portable network-service selection against the services that
/// actually exist on the current Mac.
public enum NetworkServiceSelection {
    public static func resolve(
        selectedNames: [String],
        availableServices: [NetworkService]
    ) -> [String] {
        let availableNames = availableServices.map(\.name)
        guard !selectedNames.isEmpty else { return availableNames }

        let selected = Set(selectedNames)
        let matchingNames = availableNames.filter(selected.contains)
        // Network service names are machine-local. If a synchronized
        // configuration only refers to services from another Mac, interpret
        // it like the default selection and use every service on this Mac.
        return matchingNames.isEmpty ? availableNames : matchingNames
    }
}

public struct LocalNetworkEndpoint: Equatable, Sendable, Identifiable {
    public enum Kind: Int, Equatable, Sendable {
        case wifi
        case wired
        case usb
        case other
        case virtual
    }

    public let address: String
    public let interfaceName: String
    public let displayName: String
    public let kind: Kind
    public let isDefaultRoute: Bool

    public var id: String { "\(interfaceName)|\(address)" }
    public var isVirtual: Bool { kind == .virtual }

    public init(
        address: String,
        interfaceName: String,
        displayName: String,
        kind: Kind,
        isDefaultRoute: Bool
    ) {
        self.address = address
        self.interfaceName = interfaceName
        self.displayName = displayName
        self.kind = kind
        self.isDefaultRoute = isDefaultRoute
    }
}

public struct NetworkInterfaceManager: Sendable {
    private let runner: ProcessRunning
    private let networkSetupURL: URL
    private let routeURL: URL

    public init(
        runner: ProcessRunning = FoundationProcessRunner(),
        networkSetupURL: URL = URL(fileURLWithPath: "/usr/sbin/networksetup"),
        routeURL: URL = URL(fileURLWithPath: "/sbin/route")
    ) {
        self.runner = runner
        self.networkSetupURL = networkSetupURL
        self.routeURL = routeURL
    }

    public func listServices() throws -> [NetworkService] {
        let result = try runner.run(
            executableURL: networkSetupURL,
            arguments: ["-listnetworkserviceorder"], environment: nil, timeout: 10
        )
        guard result.exitCode == 0 else {
            throw WhistleYooError.commandFailed(result.standardError)
        }
        return Self.parseServiceOrder(result.standardOutput)
    }

    public static func parseServiceOrder(_ output: String) -> [NetworkService] {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        var services: [NetworkService] = []
        var pendingName: String?
        var pendingDisabled = false
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("("), let close = line.firstIndex(of: ")") {
                let prefix = line[line.index(after: line.startIndex)..<close]
                if Int(prefix) != nil {
                    var name = String(line[line.index(after: close)...])
                        .trimmingCharacters(in: .whitespaces)
                    pendingDisabled = name.hasPrefix("*")
                    if pendingDisabled { name.removeFirst() }
                    pendingName = name.trimmingCharacters(in: .whitespaces)
                    continue
                }
            }
            if let name = pendingName, line.hasPrefix("(Hardware Port:"), line.hasSuffix(")") {
                let content = line.dropFirst("(Hardware Port:".count).dropLast()
                let pieces = content.components(separatedBy: ", Device:")
                guard pieces.count == 2 else { continue }
                services.append(NetworkService(
                    name: name,
                    device: pieces[1].trimmingCharacters(in: .whitespaces),
                    hardwarePort: pieces[0].trimmingCharacters(in: .whitespaces),
                    disabled: pendingDisabled
                ))
                pendingName = nil
            }
        }
        return services
    }

    public func localIPv4Endpoints(services: [NetworkService]) -> [LocalNetworkEndpoint] {
        let routeResult = try? runner.run(
            executableURL: routeURL,
            arguments: ["-n", "get", "default"],
            environment: nil,
            timeout: 5
        )
        let defaultInterface = routeResult.flatMap { result in
            result.exitCode == 0 ? Self.parseDefaultInterface(result.standardOutput) : nil
        }
        return Self.rankedEndpoints(
            addresses: Self.localIPv4InterfaceAddresses(),
            services: services,
            defaultInterface: defaultInterface
        )
    }

    public static func parseDefaultInterface(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let pieces = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if pieces.count == 2, pieces[0] == "interface" {
                return pieces[1]
            }
        }
        return nil
    }

    public static func rankedEndpoints(
        addresses: [(interfaceName: String, address: String)],
        services: [NetworkService],
        defaultInterface: String?
    ) -> [LocalNetworkEndpoint] {
        var servicesByDevice: [String: NetworkService] = [:]
        for service in services {
            guard let device = service.device, !device.isEmpty, servicesByDevice[device] == nil else {
                continue
            }
            servicesByDevice[device] = service
        }
        let endpoints = addresses.map { item -> LocalNetworkEndpoint in
            let service = servicesByDevice[item.interfaceName]
            let displayName = service?.name ?? service?.hardwarePort ?? item.interfaceName
            return LocalNetworkEndpoint(
                address: item.address,
                interfaceName: item.interfaceName,
                displayName: displayName,
                kind: endpointKind(
                    interfaceName: item.interfaceName,
                    serviceName: service?.name,
                    hardwarePort: service?.hardwarePort
                ),
                isDefaultRoute: item.interfaceName == defaultInterface
            )
        }

        return endpoints.sorted { lhs, rhs in
            let lhsRank = endpointRank(lhs)
            let rhsRank = endpointRank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            if lhs.displayName != rhs.displayName {
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
            return lhs.address.localizedStandardCompare(rhs.address) == .orderedAscending
        }
    }

    private static func endpointKind(
        interfaceName: String,
        serviceName: String?,
        hardwarePort: String?
    ) -> LocalNetworkEndpoint.Kind {
        let description = [serviceName, hardwarePort]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        let virtualPrefixes = ["bridge", "utun", "tun", "tap", "vmnet", "vboxnet", "awdl", "llw", "gif", "stf"]
        if virtualPrefixes.contains(where: interfaceName.lowercased().hasPrefix) ||
            description.contains("virtual") || description.contains("vpn") {
            return .virtual
        }
        if description.contains("wi-fi") || description.contains("wifi") || description.contains("airport") {
            return .wifi
        }
        if description.contains("iphone") || description.contains("usb") {
            return .usb
        }
        if description.contains("ethernet") || description.contains("lan") || description.contains("thunderbolt") || interfaceName.hasPrefix("en") {
            return .wired
        }
        return .other
    }

    private static func endpointRank(_ endpoint: LocalNetworkEndpoint) -> Int {
        if endpoint.isDefaultRoute { return 0 }
        switch endpoint.kind {
        case .wifi: return 1
        case .wired: return 2
        case .usb: return 3
        case .other: return 4
        case .virtual: return 5
        }
    }

    private static func localIPv4InterfaceAddresses() -> [(interfaceName: String, address: String)] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }
        var addresses: [(interfaceName: String, address: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = cursor {
            let flags = Int32(interface.pointee.ifa_flags)
            if let address = interface.pointee.ifa_addr,
               address.pointee.sa_family == UInt8(AF_INET),
               flags & IFF_UP != 0,
               flags & IFF_LOOPBACK == 0 {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let length = socklen_t(address.pointee.sa_len)
                if getnameinfo(address, length, &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                    addresses.append((
                        interfaceName: String(cString: interface.pointee.ifa_name),
                        address: String(cString: hostname)
                    ))
                }
            }
            cursor = interface.pointee.ifa_next
        }
        var seen = Set<String>()
        return addresses.filter { seen.insert("\($0.interfaceName)|\($0.address)").inserted }
    }
}
