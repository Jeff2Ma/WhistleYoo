import Darwin
import Foundation

public protocol ManagedProcessCleaning: Sendable {
    @discardableResult
    func cleanup(baseDirectory: URL) throws -> [Int32]
}

public struct ManagedProcessCleaner: ManagedProcessCleaning, Sendable {
    private let runner: ProcessRunning

    public init(runner: ProcessRunning = FoundationProcessRunner()) {
        self.runner = runner
    }

    @discardableResult
    public func cleanup(baseDirectory: URL) throws -> [Int32] {
        let result = try runner.run(
            executableURL: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axo", "pid=,command="],
            environment: nil,
            timeout: 10
        )
        guard result.exitCode == 0 else { return [] }
        let pids = Self.matchingPIDs(output: result.standardOutput, baseDirectory: baseDirectory)
        for pid in pids { Darwin.kill(pid, SIGTERM) }

        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline, pids.contains(where: Self.isRunning) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        for pid in pids where Self.isRunning(pid) {
            Darwin.kill(pid, SIGKILL)
        }
        return pids
    }

    public static func matchingPIDs(output: String, baseDirectory: URL) -> [Int32] {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        guard let encodedPath = baseDirectory.standardizedFileURL.path
            .addingPercentEncoding(withAllowedCharacters: allowed) else { return [] }
        return output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let separator = line.firstIndex(where: \.isWhitespace),
                  let pid = Int32(line[..<separator]) else { return nil }
            let command = line[separator...]
            guard command.contains("/pfork/"), command.contains(encodedPath) else { return nil }
            return pid
        }
    }

    private static func isRunning(_ pid: Int32) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno == EPERM
    }
}
