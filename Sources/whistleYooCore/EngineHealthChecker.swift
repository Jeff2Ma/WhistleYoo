import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol EngineHealthChecking: Sendable {
    func check(baseURL: URL) async -> EngineHealth?
    func waitUntilReady(baseURL: URL, timeout: TimeInterval) async -> EngineHealth?
    func waitUntilStopped(baseURL: URL, timeout: TimeInterval) async -> Bool
}

public struct EngineHealthChecker: EngineHealthChecking, Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func check(baseURL: URL) async -> EngineHealth? {
        let url = baseURL.appendingPathComponent("cgi-bin/init")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 2)
        request.setValue("whistleYoo/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let server = object["server"] as? [String: Any]
            guard let version = (object["version"] as? String) ?? (server?["version"] as? String),
                  SemanticVersion(version) != nil else {
                return nil
            }
            let port = (server?["port"] as? NSNumber)?.intValue
            return EngineHealth(version: version, port: port)
        } catch {
            return nil
        }
    }

    public func waitUntilReady(baseURL: URL, timeout: TimeInterval = 12) async -> EngineHealth? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        while clock.now < deadline {
            if let health = await check(baseURL: baseURL) { return health }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }

    public func waitUntilStopped(baseURL: URL, timeout: TimeInterval = 8) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        while clock.now < deadline {
            if await check(baseURL: baseURL) == nil { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return await check(baseURL: baseURL) == nil
    }
}
