import XCTest
@testable import whistleYooCore

final class WhistleEngineControllerTests: XCTestCase {
    func testStartupModePreservesConfiguredModesAndAddsKeepProxyUIOnce() {
        XCTAssertEqual(
            WhistleEngineController.startupMode(configuredMode: nil),
            "keepProxyUI"
        )
        XCTAssertEqual(
            WhistleEngineController.startupMode(configuredMode: "safe|keepProxyUI|safe"),
            "safe|keepProxyUI"
        )
        XCTAssertEqual(
            WhistleEngineController.startupMode(configuredMode: "safe, network&keepProxyUI"),
            "safe|network|keepProxyUI"
        )
    }

    @MainActor
    func testStartsWithIsolatedRuntimeAndStopsThroughCLI() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = EnvironmentInfo(
            nodeURL: URL(fileURLWithPath: "/usr/local/bin/node"),
            npmURL: nil,
            whistleURL: URL(fileURLWithPath: "/usr/local/bin/w2"),
            nodeVersion: SemanticVersion(22, 0, 0),
            whistleVersion: SemanticVersion(2, 10, 1)
        )
        let configuration = EngineConfiguration(
            baseDirectory: root.appendingPathComponent("data"),
            runtimeDirectory: root.appendingPathComponent("runtime")
        )
        let runner = RecordingProcessRunner { _, arguments, _ in
            if arguments.contains("status") {
                return CommandResult(exitCode: 0, standardOutput: "No running Whistle instances", standardError: "")
            }
            return CommandResult(exitCode: 0, standardOutput: "ok", standardError: "")
        }
        let health = FakeHealthChecker()
        let certificatePreparer = FakeRootCertificatePreparer()
        let controller = WhistleEngineController(
            environment: environment,
            configuration: configuration,
            runner: runner,
            healthChecker: health,
            portChecker: FakePortChecker(available: true),
            rootCertificatePreparer: certificatePreparer
        )

        try await controller.start()

        XCTAssertEqual(controller.state, .running(version: "2.10.1"))
        let start = runner.invocations.first { $0.arguments.contains("start") }
        XCTAssertNotNil(start)
        XCTAssertTrue(start!.arguments.contains("0.0.0.0"))
        XCTAssertTrue(start!.arguments.contains("127.0.0.1:8900"))
        let certDirectoryIndex = try XCTUnwrap(start!.arguments.firstIndex(of: "-z"))
        XCTAssertEqual(start!.arguments[certDirectoryIndex + 1], configuration.customCertificateDirectory.path)
        XCTAssertEqual(certificatePreparer.directories, [configuration.customCertificateDirectory])
        XCTAssertEqual(start!.environment?["STARTING_DATA_DIR"], configuration.runtimeDirectory.path)

        try await controller.stop()
        XCTAssertEqual(controller.state, .stopped)
        XCTAssertTrue(runner.invocations.contains { $0.arguments.contains("stop") })
        XCTAssertTrue(
            runner.invocations.allSatisfy { !$0.wasMainThread },
            "Whistle CLI commands must never block the main actor"
        )
    }

    @MainActor
    func testReportsPortConflictWithoutStarting() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let environment = EnvironmentInfo(
            nodeURL: URL(fileURLWithPath: "/node"), npmURL: nil,
            whistleURL: URL(fileURLWithPath: "/w2"),
            nodeVersion: SemanticVersion(22, 0, 0), whistleVersion: SemanticVersion(2, 10, 1)
        )
        let runner = RecordingProcessRunner { _, _, _ in
            CommandResult(exitCode: 0, standardOutput: "not running", standardError: "")
        }
        let controller = WhistleEngineController(
            environment: environment,
            configuration: EngineConfiguration(
                baseDirectory: root.appendingPathComponent("data"),
                runtimeDirectory: root.appendingPathComponent("runtime")
            ),
            runner: runner,
            healthChecker: FakeHealthChecker(),
            portChecker: FakePortChecker(available: false),
            rootCertificatePreparer: FakeRootCertificatePreparer()
        )
        do {
            try await controller.start()
            XCTFail("Expected port conflict")
        } catch {
            XCTAssertEqual(error as? WhistleYooError, .portInUse(8899))
        }
    }

    @MainActor
    func testConcurrentStopsRunWhistleStopCommandOnlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = EnvironmentInfo(
            nodeURL: URL(fileURLWithPath: "/node"), npmURL: nil,
            whistleURL: URL(fileURLWithPath: "/w2"),
            nodeVersion: SemanticVersion(22, 0, 0), whistleVersion: SemanticVersion(2, 10, 1)
        )
        let runner = RecordingProcessRunner { _, arguments, _ in
            if arguments.first == "stop" { Thread.sleep(forTimeInterval: 0.1) }
            return CommandResult(exitCode: 0, standardOutput: "ok", standardError: "")
        }
        let controller = WhistleEngineController(
            environment: environment,
            configuration: EngineConfiguration(
                baseDirectory: root.appendingPathComponent("data"),
                runtimeDirectory: root.appendingPathComponent("runtime")
            ),
            runner: runner,
            healthChecker: FakeHealthChecker(),
            portChecker: FakePortChecker(available: true),
            rootCertificatePreparer: FakeRootCertificatePreparer()
        )
        try await controller.start()

        async let first: Void = controller.stop()
        async let second: Void = controller.stop()
        _ = try await (first, second)

        XCTAssertEqual(
            runner.invocations.filter { $0.arguments.first == "stop" }.count,
            1
        )
        XCTAssertEqual(controller.state, .stopped)
    }
}
