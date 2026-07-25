import AppKit
import SwiftUI
import XCTest
@testable import whistleYooApp

@MainActor
final class WhistleCodeEditorCoordinatorTests: XCTestCase {
    func testSwitchingDocumentsKeepsTextVisibleAndDoesNotWriteDuringLoad() {
        var first = "www.example.com proxy://127.0.0.1:8080"
        var second = "# Default rules\n# still visible"
        var firstWriteCount = 0
        var secondWriteCount = 0
        let editor = makeEditor()

        update(
            editor,
            binding: Binding(
                get: { first },
                set: {
                    first = $0
                    firstWriteCount += 1
                }
            ),
            documentID: "test:first",
            text: first,
            isEditable: true
        )
        update(
            editor,
            binding: Binding(
                get: { second },
                set: {
                    second = $0
                    secondWriteCount += 1
                }
            ),
            documentID: "test:second",
            text: second,
            isEditable: false
        )

        editor.layoutManager.ensureLayout(for: editor.textContainer)

        XCTAssertEqual(editor.textView.string, second)
        XCTAssertEqual(firstWriteCount, 0)
        XCTAssertEqual(secondWriteCount, 0)
        XCTAssertFalse(editor.scrollView.hasHorizontalScroller)
        XCTAssertEqual(editor.scrollView.horizontalScrollElasticity, .none)
        XCTAssertTrue(editor.scrollView.usesPredominantAxisScrolling)
        XCTAssertFalse(editor.textView.isHorizontallyResizable)
        XCTAssertTrue(editor.textContainer.widthTracksTextView)
        let rulerWidth = editor.scrollView.verticalRulerView?.ruleThickness ?? 0
        XCTAssertEqual(
            editor.textView.frame.width,
            editor.scrollView.contentSize.width - rulerWidth,
            accuracy: 0.01
        )
        XCTAssertEqual(
            editor.scrollView.contentView.bounds.origin.x,
            -rulerWidth,
            accuracy: 0.01
        )
        XCTAssertGreaterThan(editor.textContainer.containerSize.width, 0)
        XCTAssertGreaterThan(editor.layoutManager.usedRect(for: editor.textContainer).width, 0)

        editor.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 20))
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: editor.scrollView.contentView
        )

        XCTAssertEqual(
            editor.scrollView.contentView.bounds.origin.x,
            -rulerWidth,
            accuracy: 0.01
        )
        XCTAssertEqual(editor.scrollView.contentView.bounds.origin.y, 20, accuracy: 0.01)
    }

    func testEditsAfterSwitchWriteOnlyToCurrentDocumentBinding() {
        var first = "first"
        var second = "second"
        let editor = makeEditor()

        update(
            editor,
            binding: Binding(get: { first }, set: { first = $0 }),
            documentID: "test:binding:first",
            text: first,
            isEditable: true
        )
        update(
            editor,
            binding: Binding(get: { second }, set: { second = $0 }),
            documentID: "test:binding:second",
            text: second,
            isEditable: true
        )

        editor.textView.string = "second edited"
        editor.coordinator.textDidChange(
            Notification(name: NSText.didChangeNotification, object: editor.textView)
        )

        XCTAssertEqual(first, "first")
        XCTAssertEqual(second, "second edited")
    }

    func testSwitchingDocumentsRestoresSelectionForTheCorrectDocument() {
        var first = "first document"
        var second = "second document"
        let editor = makeEditor()
        let firstID = "test:selection:first:\(UUID())"
        let secondID = "test:selection:second:\(UUID())"

        update(
            editor,
            binding: Binding(get: { first }, set: { first = $0 }),
            documentID: firstID,
            text: first,
            isEditable: true
        )
        editor.textView.setSelectedRange(NSRange(location: 5, length: 0))

        update(
            editor,
            binding: Binding(get: { second }, set: { second = $0 }),
            documentID: secondID,
            text: second,
            isEditable: true
        )
        editor.textView.setSelectedRange(NSRange(location: 3, length: 0))

        update(
            editor,
            binding: Binding(get: { first }, set: { first = $0 }),
            documentID: firstID,
            text: first,
            isEditable: true
        )

        XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 5, length: 0))
    }

    func testRuleCommentLinesDoNotReceiveCodeTokenHighlights() {
        var text = """
        # unknown://127.0.0.1:8080 {commentValue}
        unknown://127.0.0.1:8080 {codeValue}
        """
        let editor = makeEditor()

        update(
            editor,
            binding: Binding(get: { text }, set: { text = $0 }),
            documentID: "test:highlight:rule-comment:\(UUID())",
            text: text,
            isEditable: true
        )

        let source = text as NSString
        let commentSchemeRange = source.range(of: "unknown")
        let codeSchemeRange = source.range(
            of: "unknown",
            options: [],
            range: NSRange(
                location: NSMaxRange(commentSchemeRange),
                length: source.length - NSMaxRange(commentSchemeRange)
            )
        )
        let commentIPRange = source.range(of: "127.0.0.1")
        let commentValueRange = source.range(of: "{commentValue}")

        XCTAssertEqual(
            editor.layoutManager.temporaryAttribute(
                .foregroundColor,
                atCharacterIndex: commentSchemeRange.location,
                effectiveRange: nil
            ) as? NSColor,
            .systemGreen
        )
        XCTAssertEqual(
            editor.layoutManager.temporaryAttribute(
                .foregroundColor,
                atCharacterIndex: commentIPRange.location,
                effectiveRange: nil
            ) as? NSColor,
            .systemGreen
        )
        XCTAssertEqual(
            editor.layoutManager.temporaryAttribute(
                .foregroundColor,
                atCharacterIndex: commentValueRange.location,
                effectiveRange: nil
            ) as? NSColor,
            .systemGreen
        )
        XCTAssertNil(
            editor.layoutManager.temporaryAttribute(
                .underlineStyle,
                atCharacterIndex: commentSchemeRange.location,
                effectiveRange: nil
            )
        )
        XCTAssertEqual(
            editor.layoutManager.temporaryAttribute(
                .foregroundColor,
                atCharacterIndex: codeSchemeRange.location,
                effectiveRange: nil
            ) as? NSColor,
            .systemPurple
        )
        XCTAssertNotNil(
            editor.layoutManager.temporaryAttribute(
                .underlineStyle,
                atCharacterIndex: codeSchemeRange.location,
                effectiveRange: nil
            )
        )
    }

    private typealias Editor = (
        coordinator: WhistleCodeEditor.Coordinator,
        scrollView: NSScrollView,
        textView: WhistleSourceTextView,
        textContainer: NSTextContainer,
        layoutManager: NSLayoutManager
    )

    private func makeEditor() -> Editor {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        scrollView.contentView.postsBoundsChangedNotifications = true

        let textView = WhistleSourceTextView(frame: scrollView.contentView.bounds)
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        scrollView.documentView = textView

        let ruler = WhistleLineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        let coordinator = WhistleCodeEditor.Coordinator()
        textView.delegate = coordinator
        coordinator.attach(
            scrollView: scrollView,
            textView: textView,
            lineNumberRuler: ruler
        )

        return (
            coordinator,
            scrollView,
            textView,
            textView.textContainer!,
            textView.layoutManager!
        )
    }

    private func update(
        _ editor: Editor,
        binding: Binding<String>,
        documentID: String,
        text: String,
        isEditable: Bool
    ) {
        editor.coordinator.updateConfiguration(
            textBinding: binding,
            documentID: documentID,
            language: .rules,
            text: text,
            isEditable: isEditable,
            sidebarSearchQuery: "",
            completionWords: [],
            valueNames: [],
            onPositionChange: { _ in }
        )
    }
}
