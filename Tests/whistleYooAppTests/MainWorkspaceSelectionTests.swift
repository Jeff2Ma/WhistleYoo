import XCTest
@testable import whistleYooApp

@MainActor
final class MainWorkspaceSelectionTests: XCTestCase {
    func testUnsavedDraftRequiresConfirmationForEverySelectionRequest() {
        var isDirty = true
        var discardCount = 0
        let selection = MainWorkspaceSelection(
            selected: .rules,
            hasUnsavedChanges: { isDirty },
            discardUnsavedChanges: {
                isDirty = false
                discardCount += 1
            }
        )

        selection.request(.settings)

        XCTAssertEqual(selection.selected, .rules)
        XCTAssertTrue(selection.isDiscardConfirmationPresented)
        selection.keepEditing()
        XCTAssertEqual(selection.selected, .rules)
        XCTAssertEqual(discardCount, 0)

        selection.request(.settings)
        selection.discardAndContinue()

        XCTAssertEqual(selection.selected, .settings)
        XCTAssertEqual(discardCount, 1)
        XCTAssertFalse(selection.isDiscardConfirmationPresented)
    }

    func testOperationInProgressBlocksNavigationWithoutDiscardingDraft() {
        var operationInProgress = true
        var discarded = false
        let selection = MainWorkspaceSelection(
            selected: .rules,
            hasUnsavedChanges: { true },
            hasOperationInProgress: { operationInProgress },
            discardUnsavedChanges: { discarded = true }
        )

        selection.request(.mcp)

        XCTAssertEqual(selection.selected, .rules)
        XCTAssertTrue(selection.isOperationAlertPresented)
        XCTAssertFalse(discarded)

        operationInProgress = false
        selection.isOperationAlertPresented = false
        selection.request(.mcp)
        selection.discardAndContinue()
        XCTAssertEqual(selection.selected, .mcp)
    }

    func testCleanWorkspaceChangesSelectionImmediately() {
        let selection = MainWorkspaceSelection(
            selected: .rules,
            hasUnsavedChanges: { false }
        )

        selection.request(.mobile)

        XCTAssertEqual(selection.selected, .mobile)
        XCTAssertFalse(selection.isDiscardConfirmationPresented)
    }

    func testTogglingSidebarSwitchesBetweenFullAndDetailOnlyLayout() {
        let selection = MainWorkspaceSelection(selected: .console)

        XCTAssertEqual(selection.columnVisibility, .all)

        selection.toggleSidebar()
        XCTAssertEqual(selection.columnVisibility, .detailOnly)

        selection.toggleSidebar()
        XCTAssertEqual(selection.columnVisibility, .all)
    }

    func testTogglingSidebarDoesNotChangeTheSelectedPage() {
        let selection = MainWorkspaceSelection(
            selected: .rules,
            hasUnsavedChanges: { true }
        )

        selection.toggleSidebar()

        XCTAssertEqual(selection.selected, .rules)
        XCTAssertFalse(selection.isDiscardConfirmationPresented)
    }

}
