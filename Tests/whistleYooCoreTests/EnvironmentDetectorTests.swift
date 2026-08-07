import XCTest
@testable import whistleYooCore

final class EnvironmentDetectorTests: XCTestCase {
    func testDetectsNodeNpmAndWhistleFromExplicitPath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["node", "npm", "w2"] {
            let url = directory.appendingPathComponent(name)
            try Data("stub".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let runner = RecordingProcessRunner { _, arguments, _ in
            if arguments == ["--version"] {
                return CommandResult(exitCode: 0, standardOutput: "v22.12.0\n", standardError: "")
            }
            return CommandResult(exitCode: 0, standardOutput: "2.10.7\n", standardError: "")
        }
        let detector = EnvironmentDetector(
            runner: runner,
            environment: ["PATH": directory.path],
            homeDirectory: directory
        )

        let result = try detector.detect()

        XCTAssertEqual(result.nodeURL.lastPathComponent, "node")
        XCTAssertEqual(result.npmURL?.lastPathComponent, "npm")
        XCTAssertEqual(result.whistleURL.lastPathComponent, "w2")
        XCTAssertEqual(result.nodeVersion, SemanticVersion(22, 12, 0))
        XCTAssertEqual(result.whistleVersion, SemanticVersion(2, 10, 7))
    }

    func testRejectsOldNode() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let node = directory.appendingPathComponent("node")
        try Data().write(to: node)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)
        let runner = RecordingProcessRunner { _, _, _ in
            CommandResult(exitCode: 0, standardOutput: "v16.20.0", standardError: "")
        }
        XCTAssertThrowsError(try EnvironmentDetector(
            runner: runner, environment: ["PATH": directory.path], homeDirectory: directory
        ).detect()) { error in
            guard case .unsupportedVersion(let message) = error as? WhistleYooError else {
                return XCTFail("Unexpected error: \(error)")
            }
            let supportedMessages = ["en", "zh-Hans"].map {
                Localization.string(
                    .coreNodeJsIsTooOldVersion18OrLaterIsRequired,
                    localeIdentifier: $0
                )
            }
            XCTAssertTrue(supportedMessages.contains(message))
        }
    }

    func testRejectsWhistleOlderThanPluginsAPIRequirement() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["node", "w2"] {
            let url = directory.appendingPathComponent(name)
            try Data().write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let runner = RecordingProcessRunner { executableURL, _, _ in
            let version = executableURL.lastPathComponent == "node" ? "v22.12.0" : "2.10.6"
            return CommandResult(exitCode: 0, standardOutput: version, standardError: "")
        }
        let detector = EnvironmentDetector(
            runner: runner,
            environment: ["PATH": directory.path],
            homeDirectory: directory
        )

        XCTAssertThrowsError(try detector.detect()) { error in
            guard case .unsupportedVersion(let message) = error as? WhistleYooError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("2.10.7"))
            XCTAssertTrue(message.contains("2.10.6"))
        }
    }
}
