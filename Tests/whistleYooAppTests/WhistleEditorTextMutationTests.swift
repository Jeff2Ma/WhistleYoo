import Foundation
import XCTest
@testable import whistleYooApp

final class WhistleEditorTextMutationTests: XCTestCase {
    func testInsertIndentationMovesCaretAtInsertionPoint() {
        let result = WhistleEditorTextMutation.insertIndentation(
            "one\ntwo",
            selection: NSRange(location: 5, length: 0)
        )

        XCTAssertEqual(result.text, "one\nt    wo")
        XCTAssertEqual(result.selection, NSRange(location: 9, length: 0))
    }

    func testIndentAndOutdentRoundTripForMultipleLines() {
        let original = "one\ntwo\nthree"
        let selection = NSRange(location: 0, length: 7)
        let indented = WhistleEditorTextMutation.indent(
            original,
            selection: selection
        )
        let outdented = WhistleEditorTextMutation.outdent(
            indented.text,
            selection: indented.selection
        )

        XCTAssertEqual(indented.text, "    one\n    two\nthree")
        XCTAssertEqual(outdented.text, original)
        XCTAssertEqual(outdented.selection, selection)
    }

    func testOutdentRemovesTabOrAtMostFourSpaces() {
        let result = WhistleEditorTextMutation.outdent(
            "\tone\n  two\nfive",
            selection: NSRange(location: 0, length: 11)
        )

        XCTAssertEqual(result.text, "one\ntwo\nfive")
    }

    func testToggleRuleCommentsPreservesIndentation() {
        let original = "  one\n\ttwo"
        let selection = NSRange(location: 0, length: (original as NSString).length)
        let commented = WhistleEditorTextMutation.toggleComments(
            original,
            selection: selection,
            prefix: "#"
        )
        let uncommented = WhistleEditorTextMutation.toggleComments(
            commented.text,
            selection: commented.selection,
            prefix: "#"
        )

        XCTAssertEqual(commented.text, "  # one\n\t# two")
        XCTAssertEqual(uncommented.text, original)
        XCTAssertEqual(uncommented.selection, selection)
    }

    func testDuplicateLastLineAddsMissingLineBreak() {
        let result = WhistleEditorTextMutation.duplicateLines(
            "one\ntwo",
            selection: NSRange(location: 5, length: 0)
        )

        XCTAssertEqual(result.text, "one\ntwo\ntwo")
        XCTAssertEqual(result.selection, NSRange(location: 8, length: 3))
    }

    func testMutationsUseUTF16SelectionOffsets() {
        let result = WhistleEditorTextMutation.indent(
            "😀\n规则",
            selection: NSRange(location: 3, length: 2)
        )

        XCTAssertEqual(result.text, "😀\n    规则")
        XCTAssertEqual(result.selection, NSRange(location: 7, length: 2))
    }

    func testCommentCommandOnlyUsesLineCommentsForSupportedDocuments() {
        XCTAssertEqual(WhistleEditorLanguage.rules.commentPrefix, "#")
        XCTAssertEqual(
            WhistleEditorLanguage.value(documentName: "rewrite.js").commentPrefix,
            "//"
        )
        XCTAssertEqual(
            WhistleEditorLanguage.value(documentName: "proxy.pac").commentPrefix,
            "//"
        )
        XCTAssertNil(WhistleEditorLanguage.value(documentName: "payload.json").commentPrefix)
        XCTAssertNil(WhistleEditorLanguage.value(documentName: "style.css").commentPrefix)
        XCTAssertNil(WhistleEditorLanguage.value(documentName: "template.html").commentPrefix)
    }
}
