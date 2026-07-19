import Foundation
import XCTest
@testable import whistleYooCore

final class WhistleIntegrationTests: XCTestCase {
    func testRealWhistleLifecycleAndWebUI() async throws {
        guard ProcessInfo.processInfo.environment["WHISTLEYOO_RUN_INTEGRATION"] == "1" else {
            throw XCTSkip("Set WHISTLEYOO_RUN_INTEGRATION=1 to run the real Whistle test")
        }
        let environment = try EnvironmentDetector().detect()
        let checker = PortChecker()
        guard let proxyPort = (31000...45000).randomElement(where: {
            checker.isAvailable(port: $0, host: "127.0.0.1")
        }), let uiPort = (45001...60000).randomElement(where: {
            checker.isAvailable(port: $0, host: "127.0.0.1")
        }) else {
            XCTFail("No free ports")
            return
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("whistleyoo-integration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = EngineConfiguration(
            proxyPort: proxyPort,
            uiPort: uiPort,
            listenHost: "127.0.0.1",
            baseDirectory: root.appendingPathComponent("data"),
            runtimeDirectory: root.appendingPathComponent("runtime")
        )
        let controller = await MainActor.run {
            WhistleEngineController(environment: environment, configuration: configuration)
        }

        do {
            try await controller.start()
            let healthy = await controller.isHealthy()
            XCTAssertTrue(healthy)
            let (data, response) = try await URLSession.shared.data(
                from: configuration.uiURL.appendingPathComponent("cgi-bin/init")
            )
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNotNil(object["version"])

            let whitelistManager = SoftwareDomainWhitelistManager()
            try await whitelistManager.sync(baseURL: configuration.uiURL, enabled: true)
            let rulesURL = configuration.uiURL.appendingPathComponent("cgi-bin/rules/list")
            let (enabledRulesData, _) = try await URLSession.shared.data(from: rulesURL)
            let enabledRules = try XCTUnwrap(
                JSONSerialization.jsonObject(with: enabledRulesData) as? [String: Any]
            )
            XCTAssertTrue(
                (enabledRules["defaultRules"] as? String)?.contains(
                    SoftwareDomainWhitelistManager.managedRules
                ) == true
            )
            try await whitelistManager.sync(baseURL: configuration.uiURL, enabled: false)
            let (disabledRulesData, _) = try await URLSession.shared.data(from: rulesURL)
            let disabledRules = try XCTUnwrap(
                JSONSerialization.jsonObject(with: disabledRulesData) as? [String: Any]
            )
            XCTAssertFalse(
                (disabledRules["defaultRules"] as? String)?.contains(
                    SoftwareDomainWhitelistManager.managedRules
                ) == true
            )

            let rulesManager = WhistleRulesManager()
            let persistedRuleName = "WhistleYoo native persistence"
            let persistedRuleValue = "persist.example.test host://127.0.0.1"
            try await rulesManager.save(
                name: persistedRuleName,
                value: persistedRuleValue,
                isEnabled: false,
                baseURL: configuration.uiURL
            )
            let enabledRuleNames = [
                "WhistleYoo coexist one",
                "WhistleYoo coexist two"
            ]
            for (index, name) in enabledRuleNames.enumerated() {
                try await rulesManager.save(
                    name: name,
                    value: "coexist\(index).example.test host://127.0.0.1",
                    isEnabled: true,
                    baseURL: configuration.uiURL
                )
            }
            let coexistRules = try await rulesManager.load(baseURL: configuration.uiURL)
            XCTAssertTrue(coexistRules.allowMultipleChoice)
            XCTAssertTrue(enabledRuleNames.allSatisfy { name in
                coexistRules.documents.first(where: { $0.name == name })?.isEnabled == true
            })
            try await controller.stop()
            try await controller.start()
            let restartedRules = try await rulesManager.load(baseURL: configuration.uiURL)
            XCTAssertEqual(
                restartedRules.documents.first(where: { $0.name == persistedRuleName })?.value,
                persistedRuleValue
            )
            XCTAssertTrue(enabledRuleNames.allSatisfy { name in
                restartedRules.documents.first(where: { $0.name == name })?.isEnabled == true
            })
            try await rulesManager.delete(name: persistedRuleName, baseURL: configuration.uiURL)
            for name in enabledRuleNames {
                try await rulesManager.delete(name: name, baseURL: configuration.uiURL)
            }

            let proxyResult = try FoundationProcessRunner().run(
                executableURL: URL(fileURLWithPath: "/usr/bin/curl"),
                arguments: [
                    "--silent", "--show-error", "--fail", "--noproxy", "",
                    "--proxy", "http://127.0.0.1:\(proxyPort)",
                    configuration.uiURL.appendingPathComponent("cgi-bin/init").absoluteString
                ],
                environment: nil,
                timeout: 10
            )
            XCTAssertEqual(proxyResult.exitCode, 0)
            XCTAssertTrue(proxyResult.standardOutput.contains("\"version\""))

            let certificate = try await CertificateManager().fetchRootCertificate(baseURL: configuration.uiURL)
            let der = try XCTUnwrap(CertificateManager.certificateDER(from: certificate))
            XCTAssertGreaterThan(der.count, 500)
            let subjectResult = try FoundationProcessRunner().run(
                executableURL: URL(fileURLWithPath: "/usr/bin/openssl"),
                arguments: [
                    "x509", "-in",
                    configuration.customCertificateDirectory.appendingPathComponent("root.crt").path,
                    "-noout", "-subject"
                ],
                environment: nil,
                timeout: 10
            )
            XCTAssertEqual(subjectResult.exitCode, 0)
            XCTAssertNotNil(subjectResult.standardOutput.range(
                of: #"CN\s*=\s*WhistleYoo\..+\.\d{14}"#,
                options: .regularExpression
            ))
            try await controller.stop()
            let state = await MainActor.run { controller.state }
            XCTAssertEqual(state, .stopped)
            let processList = try FoundationProcessRunner().run(
                executableURL: URL(fileURLWithPath: "/bin/ps"),
                arguments: ["-axo", "pid=,command="], environment: nil, timeout: 10
            )
            XCTAssertTrue(ManagedProcessCleaner.matchingPIDs(
                output: processList.standardOutput, baseDirectory: configuration.baseDirectory
            ).isEmpty)
        } catch {
            try? await controller.stop()
            throw error
        }
    }
}

private extension ClosedRange where Bound == Int {
    func randomElement(where predicate: (Int) -> Bool) -> Int? {
        for _ in 0..<100 {
            let candidate = Int.random(in: self)
            if predicate(candidate) { return candidate }
        }
        return nil
    }
}
