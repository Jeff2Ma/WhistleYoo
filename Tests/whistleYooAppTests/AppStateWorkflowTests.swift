import XCTest
@testable import whistleYooApp
@testable import whistleYooCore

@MainActor
final class AppStateWorkflowTests: XCTestCase {
    func testOnboardingCompletesOnlyAfterSettingsPersist() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppStateController(
            settingsStore: SettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
        )

        let completed = await state.completeOnboarding(
            enableSystemProxy: false,
            skippedCertificate: true
        )

        XCTAssertTrue(completed)
        XCTAssertFalse(state.needsOnboarding)
        XCTAssertTrue(state.settings.certificateStepSkipped)
    }

    func testOnboardingRemainsIncompleteWhenSettingsCannotPersist() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppStateController(
            settingsStore: SettingsStore(fileURL: directory)
        )

        let completed = await state.completeOnboarding(
            enableSystemProxy: false,
            skippedCertificate: true
        )

        XCTAssertFalse(completed)
        XCTAssertTrue(state.needsOnboarding)
        XCTAssertFalse(state.settings.certificateStepSkipped)
    }
}
