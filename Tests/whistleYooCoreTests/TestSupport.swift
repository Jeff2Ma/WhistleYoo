import Foundation
@testable import whistleYooCore

final class RecordingProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Invocation: Equatable {
        let executableURL: URL
        let arguments: [String]
        let environment: [String: String]?
        let wasMainThread: Bool
    }

    private let lock = NSLock()
    private let handler: (URL, [String], [String: String]?) throws -> CommandResult
    private(set) var invocations: [Invocation] = []

    init(handler: @escaping (URL, [String], [String: String]?) throws -> CommandResult) {
        self.handler = handler
    }

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval
    ) throws -> CommandResult {
        lock.lock()
        invocations.append(Invocation(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            wasMainThread: Thread.isMainThread
        ))
        lock.unlock()
        return try handler(executableURL, arguments, environment)
    }
}

final class FakeHealthChecker: EngineHealthChecking, @unchecked Sendable {
    var health: EngineHealth?

    init(health: EngineHealth? = nil) {
        self.health = health
    }

    func check(baseURL: URL) async -> EngineHealth? { health }

    func waitUntilReady(baseURL: URL, timeout: TimeInterval) async -> EngineHealth? {
        health = EngineHealth(version: "2.10.1", port: 8899)
        return health
    }

    func waitUntilStopped(baseURL: URL, timeout: TimeInterval) async -> Bool {
        health = nil
        return true
    }
}

struct FakePortChecker: PortAvailabilityChecking {
    let available: Bool
    func isAvailable(port: Int, host: String) -> Bool { available }
}

final class FakeRootCertificatePreparer: RootCertificatePreparing, @unchecked Sendable {
    private(set) var directories: [URL] = []

    func prepareRootCertificate(in directory: URL) throws {
        directories.append(directory)
    }
}
