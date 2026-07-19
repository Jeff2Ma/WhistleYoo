import Foundation
import Darwin

public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public protocol ProcessRunning: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval
    ) throws -> CommandResult
}

public final class FoundationProcessRunner: ProcessRunning, @unchecked Sendable {
    public init() {}

    public func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 20
    ) throws -> CommandResult {
        let process = Process()
        let captureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("whistleyoo-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: captureDirectory) }
        let stdoutURL = captureDirectory.appendingPathComponent("stdout")
        let stderrURL = captureDirectory.appendingPathComponent("stderr")
        _ = FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        _ = FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        do {
            try process.run()
        } catch {
            throw WhistleYooError.commandFailed(Localization.format(.coreUnableToRunValueValue, executableURL.path, error.localizedDescription))
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            throw WhistleYooError.commandFailed(Localization.format(.coreCommandTimedOutValue, executableURL.lastPathComponent))
        }

        try stdout.synchronize()
        try stderr.synchronize()
        let outputData = try Data(contentsOf: stdoutURL)
        let errorData = try Data(contentsOf: stderrURL)
        return CommandResult(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self)
        )
    }
}
