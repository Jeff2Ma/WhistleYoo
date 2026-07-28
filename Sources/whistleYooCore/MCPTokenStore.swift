import Foundation

public final class MCPTokenStore: @unchecked Sendable {
    public let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.devework.whistleyoo", isDirectory: true)
        self.fileURL = fileURL ?? support.appendingPathComponent("mcp-token")
        self.fileManager = fileManager
    }

    public func loadOrCreate() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if let token = try? String(contentsOf: fileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           token.count >= 32 {
            return token
        }
        return try writeNewToken()
    }

    public func rotate() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        return try writeNewToken()
    }

    private func writeNewToken() throws -> String {
        let token = (UUID().uuidString + UUID().uuidString)
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data((token + "\n").utf8).write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        return token
    }
}
