import Foundation

public struct EnvironmentDetector {
    public static let minimumNodeVersion = SemanticVersion(18, 0, 0)
    public static let minimumWhistleVersion = SemanticVersion(2, 9, 0)

    private let runner: ProcessRunning
    private let fileManager: FileManager
    private let environment: [String: String]
    private let homeDirectory: URL

    public init(
        runner: ProcessRunning = FoundationProcessRunner(),
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.runner = runner
        self.fileManager = fileManager
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    public func detect() throws -> EnvironmentInfo {
        let searchDirectories = candidateDirectories()
        let executablePath = searchDirectories.map(\.path).joined(separator: ":")
        guard let nodeURL = findExecutable(named: "node", directories: searchDirectories) else {
            throw WhistleYooError.environmentUnavailable(Localization.string(.coreNodeJsWasNotFoundInstallNode18OrLater))
        }
        let nodeDetection = try readVersion(
            executableURL: nodeURL,
            argumentCandidates: [["--version"], ["-v"]],
            environment: ["PATH": executablePath]
        )
        guard let nodeVersion = nodeDetection.version else {
            throw WhistleYooError.environmentUnavailable(Localization.format(.coreUnableToReadTheNodeJsVersionValue, nodeDetection.diagnostic))
        }
        guard nodeVersion >= Self.minimumNodeVersion else {
            throw WhistleYooError.unsupportedVersion(Localization.string(.coreNodeJsIsTooOldVersion18OrLaterIsRequired))
        }

        guard let whistleURL = findExecutable(named: "w2", directories: searchDirectories)
                ?? findExecutable(named: "whistle", directories: searchDirectories) else {
            throw WhistleYooError.environmentUnavailable(Localization.string(.coreAGlobalWhistleInstallationWasNotFoundRunNpmInstallGWhistle))
        }
        let whistleDetection = try readVersion(
            executableURL: whistleURL,
            argumentCandidates: [["-V"], ["--version"]],
            environment: ["PATH": executablePath]
        )
        guard let whistleVersion = whistleDetection.version else {
            throw WhistleYooError.environmentUnavailable(Localization.format(.coreUnableToReadTheWhistleVersionValue, whistleDetection.diagnostic))
        }
        guard whistleVersion >= Self.minimumWhistleVersion else {
            throw WhistleYooError.unsupportedVersion(
                Localization.format(.coreWhistleIsTooOldVersion290OrLaterIsRequiredDetectedValue, whistleDetection.diagnostic)
            )
        }

        return EnvironmentInfo(
            nodeURL: nodeURL,
            npmURL: findExecutable(named: "npm", directories: searchDirectories),
            whistleURL: whistleURL,
            nodeVersion: nodeVersion,
            whistleVersion: whistleVersion
        )
    }

    public func candidateDirectories() -> [URL] {
        var values: [URL] = []
        if let path = environment["PATH"] {
            values.append(contentsOf: path.split(separator: ":").map { URL(fileURLWithPath: String($0)) })
        }
        values.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
            homeDirectory.appendingPathComponent(".volta/bin"),
            homeDirectory.appendingPathComponent(".local/bin")
        ])
        values.append(contentsOf: versionManagerBins())

        var seen = Set<String>()
        return values.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func versionManagerBins() -> [URL] {
        let roots = [
            homeDirectory.appendingPathComponent(".nvm/versions/node"),
            homeDirectory.appendingPathComponent(".fnm/node-versions"),
            homeDirectory.appendingPathComponent("Library/Application Support/fnm/node-versions")
        ]
        var bins: [URL] = []
        for root in roots {
            guard let versions = try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for version in versions.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
                let nvmBin = version.appendingPathComponent("bin")
                let fnmBin = version.appendingPathComponent("installation/bin")
                if fileManager.fileExists(atPath: nvmBin.path) { bins.append(nvmBin) }
                if fileManager.fileExists(atPath: fnmBin.path) { bins.append(fnmBin) }
            }
        }
        return bins
    }

    private func findExecutable(named name: String, directories: [URL]) -> URL? {
        directories.lazy
            .map { $0.appendingPathComponent(name) }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private func readVersion(
        executableURL: URL,
        argumentCandidates: [[String]],
        environment: [String: String]
    ) throws -> (version: SemanticVersion?, diagnostic: String) {
        var lastDiagnostic = ""
        for attempt in 0..<2 {
            for arguments in argumentCandidates {
                let result = try runner.run(
                    executableURL: executableURL,
                    arguments: arguments,
                    environment: environment,
                    timeout: 8
                )
                let output = (result.standardOutput + "\n" + result.standardError)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                lastDiagnostic = "exit=\(result.exitCode), output=\(output)"
                if result.exitCode == 0, let version = SemanticVersion(output) {
                    return (version, output)
                }
            }
            if attempt == 0 { Thread.sleep(forTimeInterval: 0.1) }
        }
        return (nil, lastDiagnostic)
    }
}
