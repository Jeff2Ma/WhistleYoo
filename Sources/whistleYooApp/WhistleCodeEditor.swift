import AppKit
import SwiftUI

struct WhistleEditorPosition: Equatable {
    var line = 1
    var column = 1
}

enum WhistleEditorLanguage: Equatable {
    case rules
    case value(documentName: String)

    var commentPrefix: String? {
        switch self {
        case .rules:
            return "#"
        case let .value(documentName):
            switch WhistleValueLanguage(documentName: documentName, contents: "") {
            case .javascript:
                return "//"
            case .json, .css, .html, .plainText:
                return nil
            }
        }
    }
}

/// A native, Whistle-aware source editor built directly on AppKit's text
/// system. It intentionally owns only editor behavior; Rules/Values storage
/// and saving remain in the surrounding SwiftUI workspace.
struct WhistleCodeEditor: NSViewRepresentable {
    @Binding var text: String
    let documentID: String
    let language: WhistleEditorLanguage
    let isEditable: Bool
    let sidebarSearchQuery: String
    let valueNames: [String]
    let onPositionChange: (WhistleEditorPosition) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .windowBackgroundColor
        scrollView.clipsToBounds = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.usesPredominantAxisScrolling = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.findBarPosition = .aboveContent

        let textView = WhistleSourceTextView(frame: scrollView.contentView.bounds)
        textView.delegate = context.coordinator
        textView.string = text
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .textColor
        textView.insertionPointColor = .controlAccentColor
        textView.backgroundColor = .windowBackgroundColor
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.editorLanguage = language
        textView.completionWords = completionWords
        textView.valueNames = valueNames
        textView.onEditorCommand = { [weak coordinator = context.coordinator] command in
            coordinator?.perform(command)
        }
        scrollView.documentView = textView

        let lineNumberRuler = WhistleLineNumberRulerView(textView: textView)
        lineNumberRuler.clipsToBounds = true
        scrollView.verticalRulerView = lineNumberRuler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        context.coordinator.attach(
            scrollView: scrollView,
            textView: textView,
            lineNumberRuler: lineNumberRuler
        )
        context.coordinator.updateConfiguration(
            textBinding: $text,
            documentID: documentID,
            language: language,
            text: text,
            isEditable: isEditable,
            sidebarSearchQuery: sidebarSearchQuery,
            completionWords: completionWords,
            valueNames: valueNames,
            onPositionChange: onPositionChange
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.updateConfiguration(
            textBinding: $text,
            documentID: documentID,
            language: language,
            text: text,
            isEditable: isEditable,
            sidebarSearchQuery: sidebarSearchQuery,
            completionWords: completionWords,
            valueNames: valueNames,
            onPositionChange: onPositionChange
        )
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.prepareForDismantle()
    }

    private var completionWords: [String] {
        switch language {
        case .rules:
            return WhistleRuleSyntax.protocols.map { "\($0)://" }
        case .value:
            return []
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private var textBinding: Binding<String>?
        private weak var scrollView: NSScrollView?
        private weak var textView: WhistleSourceTextView?
        private weak var lineNumberRuler: WhistleLineNumberRulerView?
        private var boundsObserver: NSObjectProtocol?
        private var highlightWorkItem: DispatchWorkItem?
        private var isSynchronizingDocument = false
        private var documentID = ""
        private var language = WhistleEditorLanguage.rules
        private var sidebarSearchQuery = ""
        private var onPositionChange: (WhistleEditorPosition) -> Void = { _ in }
        private var lastPublishedPosition: WhistleEditorPosition?
        private var pendingPosition: WhistleEditorPosition?

        deinit {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
        }

        func attach(
            scrollView: NSScrollView,
            textView: WhistleSourceTextView,
            lineNumberRuler: WhistleLineNumberRulerView
        ) {
            self.scrollView = scrollView
            self.textView = textView
            self.lineNumberRuler = lineNumberRuler
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self, weak lineNumberRuler] _ in
                self?.lockHorizontalScrollPosition()
                lineNumberRuler?.needsDisplay = true
                self?.saveCurrentSession()
            }
        }

        func updateConfiguration(
            textBinding: Binding<String>,
            documentID newDocumentID: String,
            language newLanguage: WhistleEditorLanguage,
            text newText: String,
            isEditable: Bool,
            sidebarSearchQuery: String,
            completionWords: [String],
            valueNames: [String],
            onPositionChange: @escaping (WhistleEditorPosition) -> Void
        ) {
            guard let textView, let scrollView else { return }
            self.onPositionChange = onPositionChange

            if documentID != newDocumentID {
                commitMarkedText(in: textView)
                saveCurrentSession()
                self.textBinding = textBinding
                documentID = newDocumentID
                loadDocument(
                    id: newDocumentID,
                    text: newText,
                    in: textView,
                    scrollView: scrollView
                )
            } else {
                self.textBinding = textBinding
            }

            if documentID == newDocumentID,
               !textView.hasMarkedText(),
               textView.string != newText {
                synchronizeDocument {
                    replaceTextWithoutUndo(newText, in: textView)
                    restoreSafeSelection(in: textView)
                }
            }

            language = newLanguage
            self.sidebarSearchQuery = sidebarSearchQuery
            textView.editorLanguage = newLanguage
            textView.completionWords = completionWords
            textView.valueNames = valueNames.sorted()
            textView.isEditable = isEditable
            textView.isSelectable = true
            configureLineWrapping(textView: textView, scrollView: scrollView)
            updateHighlights(in: textView)
            invalidateLineNumbers()
            publishPosition(from: textView)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? WhistleSourceTextView else { return }
            guard !isSynchronizingDocument else { return }
            guard !textView.hasMarkedText() else {
                // An input method owns the marked range until the user commits a
                // candidate. Publishing or re-highlighting the intermediate value
                // can cause SwiftUI to update the representable while AppKit is
                // still composing, which cancels CJK input methods.
                highlightWorkItem?.cancel()
                invalidateLineNumbers()
                return
            }
            textBinding?.wrappedValue = textView.string
            scheduleHighlightUpdate(in: textView)
            invalidateLineNumbers()
            saveCurrentSession()
            publishPosition(from: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? WhistleSourceTextView else { return }
            guard !textView.hasMarkedText() else { return }
            updateHighlights(in: textView)
            if !isSynchronizingDocument {
                saveCurrentSession()
            }
            publishPosition(from: textView)
        }

        func textView(
            _ textView: NSTextView,
            completions words: [String],
            forPartialWordRange charRange: NSRange,
            indexOfSelectedItem index: UnsafeMutablePointer<Int>?
        ) -> [String] {
            guard let textView = textView as? WhistleSourceTextView else { return words }
            let source = textView.string as NSString
            guard NSMaxRange(charRange) <= source.length else { return textView.completionWords }
            let partial = source.substring(with: charRange)
            let beginsValueReference = charRange.location > 0
                && source.character(at: charRange.location - 1) == 123
            if beginsValueReference {
                return textView.valueNames.filter {
                    partial.isEmpty || $0.localizedCaseInsensitiveContains(partial)
                }.map { "\($0)}" }
            }
            guard !partial.isEmpty else { return textView.completionWords }
            return textView.completionWords.filter {
                $0.localizedCaseInsensitiveContains(partial)
            }
        }

        func perform(_ command: WhistleEditorCommand) {
            guard let textView, textView.isEditable else { return }
            switch command {
            case .indent:
                let selection = textView.selectedRange()
                applyMutation(
                    selection.length == 0
                        ? WhistleEditorTextMutation.insertIndentation(
                            textView.string,
                            selection: selection
                        )
                        : WhistleEditorTextMutation.indent(
                            textView.string,
                            selection: selection
                        ),
                    to: textView
                )
            case .outdent:
                applyMutation(
                    WhistleEditorTextMutation.outdent(
                        textView.string,
                        selection: textView.selectedRange()
                    ),
                    to: textView
                )
            case .toggleComment:
                guard let prefix = language.commentPrefix else { return }
                applyMutation(
                    WhistleEditorTextMutation.toggleComments(
                        textView.string,
                        selection: textView.selectedRange(),
                        prefix: prefix
                    ),
                    to: textView
                )
            case .duplicateLine:
                applyMutation(
                    WhistleEditorTextMutation.duplicateLines(
                        textView.string,
                        selection: textView.selectedRange()
                    ),
                    to: textView
                )
            }
        }

        func saveCurrentSession() {
            guard !documentID.isEmpty, let textView, let scrollView else { return }
            guard !textView.hasMarkedText() else { return }
            WhistleEditorSessionStore.shared.update(
                id: documentID,
                selection: textView.selectedRange(),
                visibleOrigin: scrollView.contentView.bounds.origin
            )
        }

        func prepareForDismantle() {
            if let textView {
                commitMarkedText(in: textView)
            }
            saveCurrentSession()
        }

        private func loadDocument(
            id newDocumentID: String,
            text: String,
            in textView: WhistleSourceTextView,
            scrollView: NSScrollView
        ) {
            let session = WhistleEditorSessionStore.shared.session(for: newDocumentID)
            synchronizeDocument {
                textView.documentUndoManager = session.undoManager
                replaceTextWithoutUndo(text, in: textView)
                textView.setSelectedRange(safeRange(session.selection, in: text))
                scrollView.contentView.scroll(to: NSPoint(
                    x: horizontalContentOrigin(in: scrollView),
                    y: session.visibleOrigin.y
                ))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        private func synchronizeDocument(_ updates: () -> Void) {
            isSynchronizingDocument = true
            defer { isSynchronizingDocument = false }
            updates()
        }

        private func commitMarkedText(in textView: WhistleSourceTextView) {
            guard textView.hasMarkedText() else { return }
            textView.unmarkText()
            if textBinding?.wrappedValue != textView.string {
                textBinding?.wrappedValue = textView.string
            }
        }

        private func replaceTextWithoutUndo(_ replacement: String, in textView: NSTextView) {
            let undoManager = textView.undoManager
            undoManager?.disableUndoRegistration()
            textView.string = replacement
            undoManager?.enableUndoRegistration()
        }

        private func restoreSafeSelection(in textView: NSTextView) {
            textView.setSelectedRange(safeRange(textView.selectedRange(), in: textView.string))
        }

        private func safeRange(_ range: NSRange, in value: String) -> NSRange {
            let length = (value as NSString).length
            let location = min(range.location, length)
            return NSRange(location: location, length: min(range.length, length - location))
        }

        private func applyMutation(
            _ mutation: WhistleEditorTextMutation.Result,
            to textView: WhistleSourceTextView
        ) {
            guard mutation.text != textView.string else { return }
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            guard textView.shouldChangeText(in: fullRange, replacementString: mutation.text) else {
                return
            }
            textView.textStorage?.replaceCharacters(in: fullRange, with: mutation.text)
            textView.didChangeText()
            textView.setSelectedRange(mutation.selection)
            textView.scrollRangeToVisible(mutation.selection)
        }

        private func scheduleHighlightUpdate(in textView: WhistleSourceTextView) {
            highlightWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.updateHighlights(in: textView)
            }
            highlightWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: workItem)
        }

        private func updateHighlights(in textView: WhistleSourceTextView) {
            guard !textView.hasMarkedText() else { return }
            WhistleSyntaxHighlighter.apply(
                to: textView,
                language: language,
                sidebarSearchQuery: sidebarSearchQuery
            )
        }

        private func invalidateLineNumbers() {
            lineNumberRuler?.needsDisplay = true
        }

        private func publishPosition(from textView: NSTextView) {
            guard !textView.hasMarkedText() else { return }
            let source = textView.string as NSString
            let location = min(textView.selectedRange().location, source.length)
            let prefix = source.substring(to: location) as NSString
            let line = 1 + prefix.components(separatedBy: "\n").count - 1
            let lineStart = source.lineRange(for: NSRange(location: location, length: 0)).location
            let position = WhistleEditorPosition(
                line: line,
                column: location - lineStart + 1
            )
            guard position != lastPublishedPosition, position != pendingPosition else { return }
            pendingPosition = position
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pendingPosition == position else { return }
                self.pendingPosition = nil
                guard self.lastPublishedPosition != position else { return }
                self.lastPublishedPosition = position
                self.onPositionChange(position)
            }
        }

        private func configureLineWrapping(textView: NSTextView, scrollView: NSScrollView) {
            scrollView.hasHorizontalScroller = false
            scrollView.horizontalScrollElasticity = .none
            scrollView.usesPredominantAxisScrolling = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainer?.widthTracksTextView = true

            let rulerWidth = verticalRulerWidth(in: scrollView)
            let contentWidth = max(1, scrollView.contentSize.width - rulerWidth)
            var frame = textView.frame
            frame.size.width = contentWidth
            textView.frame = frame
            textView.textContainer?.containerSize = NSSize(
                width: contentWidth,
                height: CGFloat.greatestFiniteMagnitude
            )
            lockHorizontalScrollPosition()
        }

        private func lockHorizontalScrollPosition() {
            guard let scrollView else { return }
            let contentView = scrollView.contentView
            let targetX = horizontalContentOrigin(in: scrollView)
            guard abs(contentView.bounds.origin.x - targetX) > 0.01 else { return }
            contentView.scroll(to: NSPoint(x: targetX, y: contentView.bounds.origin.y))
            scrollView.reflectScrolledClipView(contentView)
        }

        private func horizontalContentOrigin(in scrollView: NSScrollView) -> CGFloat {
            -verticalRulerWidth(in: scrollView)
        }

        private func verticalRulerWidth(in scrollView: NSScrollView) -> CGFloat {
            scrollView.rulersVisible && scrollView.hasVerticalRuler
                ? scrollView.verticalRulerView?.ruleThickness ?? 0
                : 0
        }
    }
}

enum WhistleEditorCommand {
    case indent
    case outdent
    case toggleComment
    case duplicateLine
}

final class WhistleSourceTextView: NSTextView {
    var editorLanguage = WhistleEditorLanguage.rules
    var completionWords: [String] = []
    var valueNames: [String] = []
    var onEditorCommand: ((WhistleEditorCommand) -> Void)?
    var documentUndoManager: UndoManager?

    override var undoManager: UndoManager? {
        documentUndoManager ?? super.undoManager
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command),
              !modifiers.contains(.control),
              let key = event.charactersIgnoringModifiers?.lowercased()
        else {
            return super.performKeyEquivalent(with: event)
        }

        if modifiers.contains(.shift), key == "d" {
            duplicateLine(nil)
            return true
        }
        if !modifiers.contains(.option), key == "/" {
            toggleComment(nil)
            return true
        }

        switch key {
        case "a" where !modifiers.contains(.option):
            selectAll(nil)
        case "c" where !modifiers.contains(.option):
            copy(nil)
        case "f" where !modifiers.contains(.option):
            showFindBar()
        case "v" where !modifiers.contains(.option):
            paste(nil)
        case "x" where !modifiers.contains(.option):
            cut(nil)
        default:
            return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        // Let NSTextInputContext own every keystroke while an IME candidate is
        // being composed. In particular, Tab and Space may navigate or commit a
        // candidate and must not trigger editor shortcuts.
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 48, modifiers.contains(.control),
           !modifiers.contains(.command), !modifiers.contains(.option) {
            if modifiers.contains(.shift) {
                window?.selectPreviousKeyView(self)
            } else {
                window?.selectNextKeyView(self)
            }
            return
        }
        if event.keyCode == 48, !modifiers.contains(.command), !modifiers.contains(.option) {
            onEditorCommand?(modifiers.contains(.shift) ? .outdent : .indent)
            return
        }
        super.keyDown(with: event)
    }

    @objc func toggleComment(_ sender: Any?) {
        onEditorCommand?(.toggleComment)
    }

    @objc func duplicateLine(_ sender: Any?) {
        onEditorCommand?(.duplicateLine)
    }

    override func insertNewline(_ sender: Any?) {
        guard isEditable else {
            super.insertNewline(sender)
            return
        }
        let source = string as NSString
        let location = min(selectedRange().location, source.length)
        let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
        let line = source.substring(with: NSRange(
            location: lineRange.location,
            length: max(0, location - lineRange.location)
        ))
        let indentation = String(line.prefix { $0 == " " || $0 == "\t" })
        super.insertNewline(sender)
        if !indentation.isEmpty {
            insertText(indentation, replacementRange: selectedRange())
        }
    }

    private func showFindBar() {
        let sender = NSMenuItem()
        sender.tag = NSTextFinder.Action.showFindInterface.rawValue
        performTextFinderAction(sender)
    }
}

enum WhistleEditorTextMutation {
    struct Result: Equatable {
        let text: String
        let selection: NSRange
    }

    static func insertIndentation(
        _ text: String,
        selection: NSRange,
        indentation: String = "    "
    ) -> Result {
        let source = NSMutableString(string: text)
        let safeSelection = safeRange(selection, length: source.length)
        source.replaceCharacters(in: safeSelection, with: indentation)
        return Result(
            text: source as String,
            selection: NSRange(
                location: safeSelection.location + indentation.utf16.count,
                length: 0
            )
        )
    }

    static func indent(
        _ text: String,
        selection: NSRange,
        indentation: String = "    "
    ) -> Result {
        transformLines(
            text,
            selection: selection,
            transform: { indentation + $0 },
            selectionDelta: { line, isFirstLine in
                (isFirstLine ? indentation.utf16.count : 0, indentation.utf16.count)
            }
        )
    }

    static func outdent(
        _ text: String,
        selection: NSRange,
        indentationWidth: Int = 4
    ) -> Result {
        transformLines(
            text,
            selection: selection,
            transform: { line in
                if line.hasPrefix("\t") {
                    return String(line.dropFirst())
                }
                let spaceCount = min(line.prefix { $0 == " " }.count, indentationWidth)
                return String(line.dropFirst(spaceCount))
            },
            selectionDelta: { line, isFirstLine in
                let removed: Int
                if line.hasPrefix("\t") {
                    removed = 1
                } else {
                    removed = min(line.prefix { $0 == " " }.count, indentationWidth)
                }
                return (isFirstLine ? -removed : 0, -removed)
            }
        )
    }

    static func toggleComments(
        _ text: String,
        selection: NSRange,
        prefix: String
    ) -> Result {
        let lines = selectedLines(in: text, selection: selection)
        let nonEmptyLines = lines.filter { !$0.body.trimmingCharacters(in: .whitespaces).isEmpty }
        let shouldUncomment = !nonEmptyLines.isEmpty && nonEmptyLines.allSatisfy {
            $0.body.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix(prefix)
        }
        let marker = prefix.hasSuffix(" ") ? prefix : prefix + " "

        return transformLines(
            text,
            selection: selection,
            transform: { line in
                let indentation = String(line.prefix { $0 == " " || $0 == "\t" })
                let body = String(line.dropFirst(indentation.count))
                if shouldUncomment, body.hasPrefix(prefix) {
                    var uncommented = String(body.dropFirst(prefix.count))
                    if uncommented.hasPrefix(" ") {
                        uncommented.removeFirst()
                    }
                    return indentation + uncommented
                }
                guard !body.isEmpty else { return line }
                return indentation + marker + body
            },
            selectionDelta: { line, isFirstLine in
                let indentationCount = line.prefix { $0 == " " || $0 == "\t" }.utf16.count
                let body = String(line.dropFirst(indentationCount))
                let delta: Int
                if shouldUncomment, body.hasPrefix(prefix) {
                    delta = -(prefix.utf16.count + (body.dropFirst(prefix.count).hasPrefix(" ") ? 1 : 0))
                } else if body.isEmpty {
                    delta = 0
                } else {
                    delta = marker.utf16.count
                }
                return (isFirstLine ? delta : 0, delta)
            }
        )
    }

    static func duplicateLines(_ text: String, selection: NSRange) -> Result {
        let source = text as NSString
        let safeSelection = safeRange(selection, length: source.length)
        let lineRange = selectedLineRange(in: source, selection: safeSelection)
        let selectedText = source.substring(with: lineRange)
        let insertion = selectedText.hasSuffix("\n")
            ? selectedText
            : "\n" + selectedText
        let mutable = NSMutableString(string: text)
        let insertionLocation = NSMaxRange(lineRange)
        mutable.insert(insertion, at: insertionLocation)
        let selectionOffset = selectedText.hasSuffix("\n") ? 0 : 1
        return Result(
            text: mutable as String,
            selection: NSRange(
                location: insertionLocation + selectionOffset,
                length: selectedText.hasSuffix("\n")
                    ? max(0, selectedText.utf16.count - 1)
                    : selectedText.utf16.count
            )
        )
    }

    private struct SelectedLine {
        let body: String
    }

    private static func selectedLines(in text: String, selection: NSRange) -> [SelectedLine] {
        let source = text as NSString
        let lineRange = selectedLineRange(
            in: source,
            selection: safeRange(selection, length: source.length)
        )
        let substring = source.substring(with: lineRange)
        return substring
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { SelectedLine(body: String($0)) }
    }

    private static func transformLines(
        _ text: String,
        selection: NSRange,
        transform: (String) -> String,
        selectionDelta: (_ originalLine: String, _ isFirstLine: Bool) -> (location: Int, length: Int)
    ) -> Result {
        let source = text as NSString
        let safeSelection = safeRange(selection, length: source.length)
        let lineRange = selectedLineRange(in: source, selection: safeSelection)
        let original = source.substring(with: lineRange)
        let hasTrailingNewline = original.hasSuffix("\n")
        var lines = original.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if hasTrailingNewline, lines.last == "" {
            lines.removeLast()
        }

        var locationDelta = 0
        var lengthDelta = 0
        let transformed = lines.enumerated().map { index, line in
            let delta = selectionDelta(line, index == 0)
            locationDelta += delta.location
            lengthDelta += delta.length
            return transform(line)
        }.joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")

        let mutable = NSMutableString(string: text)
        mutable.replaceCharacters(in: lineRange, with: transformed)
        let updatedLength = mutable.length
        let updatedLocation = min(max(0, safeSelection.location + locationDelta), updatedLength)
        let updatedSelectionLength = min(
            max(0, safeSelection.length + lengthDelta - locationDelta),
            updatedLength - updatedLocation
        )
        return Result(
            text: mutable as String,
            selection: NSRange(location: updatedLocation, length: updatedSelectionLength)
        )
    }

    private static func selectedLineRange(in source: NSString, selection: NSRange) -> NSRange {
        guard source.length > 0 else { return NSRange(location: 0, length: 0) }
        let effectiveLength = selection.length > 0 ? selection.length - 1 : 0
        return source.lineRange(for: NSRange(
            location: min(selection.location, source.length),
            length: min(effectiveLength, source.length - min(selection.location, source.length))
        ))
    }

    private static func safeRange(_ range: NSRange, length: Int) -> NSRange {
        let location = min(range.location, length)
        return NSRange(location: location, length: min(range.length, length - location))
    }
}

private final class WhistleEditorSessionStore {
    struct Session {
        var selection = NSRange(location: 0, length: 0)
        var visibleOrigin = NSPoint.zero
        let undoManager = UndoManager()
    }

    static let shared = WhistleEditorSessionStore()
    private var sessions: [String: Session] = [:]

    func session(for id: String) -> Session {
        if let session = sessions[id] {
            return session
        }
        let session = Session()
        sessions[id] = session
        return session
    }

    func update(id: String, selection: NSRange, visibleOrigin: NSPoint) {
        var session = session(for: id)
        session.selection = selection
        session.visibleOrigin = visibleOrigin
        sessions[id] = session
    }
}

private enum WhistleValueLanguage {
    case json
    case javascript
    case css
    case html
    case plainText

    init(documentName: String, contents: String) {
        switch (documentName as NSString).pathExtension.lowercased() {
        case "json":
            self = .json
        case "js", "jsx", "mjs", "cjs", "pac":
            self = .javascript
        case "css":
            self = .css
        case "html", "htm", "xml", "wtpl":
            self = .html
        default:
            let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            self = trimmed.hasPrefix("{") || trimmed.hasPrefix("[") ? .json : .plainText
        }
    }
}

enum WhistleSyntaxPalette {
    static let purple = dynamic(
        light: NSColor(srgbRed: 0.38, green: 0.12, blue: 0.58, alpha: 1),
        dark: NSColor(srgbRed: 0.84, green: 0.65, blue: 1.0, alpha: 1)
    )
    static let blue = dynamic(
        light: NSColor(srgbRed: 0.0, green: 0.31, blue: 0.64, alpha: 1),
        dark: NSColor(srgbRed: 0.46, green: 0.72, blue: 1.0, alpha: 1)
    )
    static let orange = dynamic(
        light: NSColor(srgbRed: 0.53, green: 0.25, blue: 0.0, alpha: 1),
        dark: NSColor(srgbRed: 1.0, green: 0.72, blue: 0.42, alpha: 1)
    )
    static let teal = dynamic(
        light: NSColor(srgbRed: 0.0, green: 0.40, blue: 0.42, alpha: 1),
        dark: NSColor(srgbRed: 0.43, green: 0.85, blue: 0.88, alpha: 1)
    )
    static let green = dynamic(
        light: NSColor(srgbRed: 0.13, green: 0.42, blue: 0.20, alpha: 1),
        dark: NSColor(srgbRed: 0.50, green: 0.85, blue: 0.58, alpha: 1)
    )
    static let red = dynamic(
        light: NSColor(srgbRed: 0.63, green: 0.14, blue: 0.13, alpha: 1),
        dark: NSColor(srgbRed: 1.0, green: 0.55, blue: 0.51, alpha: 1)
    )
    static let all = [purple, blue, orange, teal, green, red]

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}

private enum WhistleSyntaxHighlighter {
    private static let ruleComment = expression(#"(?m)^[\t ]*#.*$"#)
    private static let ruleScheme = expression(#"(?<![A-Za-z0-9+._-])!?([A-Za-z][A-Za-z0-9+._-]*)(?=://)"#)
    private static let ruleURL = expression(#"(?i)\b(?:https?|wss?|file)://[^\s#]+"#)
    private static let ruleValueReference = expression(#"\{[^{}\r\n]+\}"#)
    private static let ipAddress = expression(#"\b(?:\d{1,3}\.){3}\d{1,3}(?::\d{1,5})?\b"#)
    private static let quotedString = expression(#""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#)
    private static let jsonKey = expression(#""(?:\\.|[^"\\])*"(?=\s*:)"#)
    private static let number = expression(#"(?<![\w.])-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#)
    private static let jsonKeyword = expression(#"\b(?:true|false|null)\b"#)
    private static let slashComment = expression(#"(?m)//.*$"#)
    private static let blockComment = expression(#"(?s)/\*.*?\*/"#)
    private static let htmlComment = expression(#"(?s)<!--.*?-->"#)

    static func apply(
        to textView: NSTextView,
        language: WhistleEditorLanguage,
        sidebarSearchQuery: String
    ) {
        guard let layoutManager = textView.layoutManager else { return }
        let source = textView.string
        let fullRange = NSRange(location: 0, length: (source as NSString).length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
        layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: fullRange)
        layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: fullRange)

        guard fullRange.length > 0 else { return }
        highlightCurrentLine(in: textView, layoutManager: layoutManager)

        switch language {
        case .rules:
            let commentRanges = ranges(matching: ruleComment, in: source)
            add(
                WhistleSyntaxPalette.purple,
                matches: ruleScheme,
                source: source,
                group: 1,
                excluding: commentRanges,
                to: layoutManager
            )
            add(
                WhistleSyntaxPalette.blue,
                matches: ruleURL,
                source: source,
                excluding: commentRanges,
                to: layoutManager
            )
            add(
                WhistleSyntaxPalette.orange,
                matches: ruleValueReference,
                source: source,
                excluding: commentRanges,
                to: layoutManager
            )
            add(
                WhistleSyntaxPalette.teal,
                matches: ipAddress,
                source: source,
                excluding: commentRanges,
                to: layoutManager
            )
            underlineUnknownSchemes(
                in: source,
                excluding: commentRanges,
                layoutManager: layoutManager
            )
            add(WhistleSyntaxPalette.green, ranges: commentRanges, to: layoutManager)
        case let .value(documentName):
            switch WhistleValueLanguage(documentName: documentName, contents: source) {
            case .json:
                add(WhistleSyntaxPalette.red, matches: quotedString, source: source, to: layoutManager)
                add(WhistleSyntaxPalette.purple, matches: jsonKey, source: source, to: layoutManager)
                add(WhistleSyntaxPalette.blue, matches: number, source: source, to: layoutManager)
                add(WhistleSyntaxPalette.orange, matches: jsonKeyword, source: source, to: layoutManager)
            case .javascript:
                add(WhistleSyntaxPalette.red, matches: quotedString, source: source, to: layoutManager)
                add(WhistleSyntaxPalette.green, matches: slashComment, source: source, to: layoutManager)
                add(WhistleSyntaxPalette.green, matches: blockComment, source: source, to: layoutManager)
                add(WhistleSyntaxPalette.blue, matches: number, source: source, to: layoutManager)
            case .css:
                add(WhistleSyntaxPalette.green, matches: blockComment, source: source, to: layoutManager)
                add(WhistleSyntaxPalette.red, matches: quotedString, source: source, to: layoutManager)
                add(WhistleSyntaxPalette.blue, matches: number, source: source, to: layoutManager)
            case .html:
                add(WhistleSyntaxPalette.green, matches: htmlComment, source: source, to: layoutManager)
                add(WhistleSyntaxPalette.red, matches: quotedString, source: source, to: layoutManager)
            case .plainText:
                add(WhistleSyntaxPalette.orange, matches: ruleValueReference, source: source, to: layoutManager)
            }
        }

        highlightSearch(
            sidebarSearchQuery,
            in: source,
            fullRange: fullRange,
            layoutManager: layoutManager
        )
    }

    private static func highlightCurrentLine(
        in textView: NSTextView,
        layoutManager: NSLayoutManager
    ) {
        let source = textView.string as NSString
        let location = min(textView.selectedRange().location, source.length)
        let range = source.lineRange(for: NSRange(location: location, length: 0))
        layoutManager.addTemporaryAttribute(
            .backgroundColor,
            value: NSColor.controlAccentColor.withAlphaComponent(0.055),
            forCharacterRange: range
        )
    }

    private static func underlineUnknownSchemes(
        in source: String,
        excluding excludedRanges: [NSRange],
        layoutManager: NSLayoutManager
    ) {
        let range = NSRange(location: 0, length: (source as NSString).length)
        for match in ruleScheme.matches(in: source, range: range) {
            guard match.numberOfRanges > 1 else { continue }
            let schemeRange = match.range(at: 1)
            guard !overlapsAny(schemeRange, ranges: excludedRanges) else { continue }
            let scheme = (source as NSString).substring(with: schemeRange)
            guard !WhistleRuleSyntax.isKnownProtocol(scheme) else { continue }
            layoutManager.addTemporaryAttributes(
                [
                    .underlineStyle: NSUnderlineStyle.patternDot.rawValue
                        | NSUnderlineStyle.single.rawValue,
                    .underlineColor: WhistleSyntaxPalette.red
                ],
                forCharacterRange: schemeRange
            )
        }
    }

    private static func highlightSearch(
        _ query: String,
        in source: String,
        fullRange: NSRange,
        layoutManager: NSLayoutManager
    ) {
        guard !query.isEmpty else { return }
        let string = source as NSString
        var searchRange = fullRange
        while searchRange.length > 0 {
            let match = string.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchRange
            )
            guard match.location != NSNotFound else { break }
            layoutManager.addTemporaryAttributes(
                [
                    .backgroundColor: NSColor.systemYellow.withAlphaComponent(0.38),
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ],
                forCharacterRange: match
            )
            let nextLocation = NSMaxRange(match)
            searchRange = NSRange(location: nextLocation, length: string.length - nextLocation)
        }
    }

    private static func add(
        _ color: NSColor,
        matches expression: NSRegularExpression,
        source: String,
        group: Int = 0,
        excluding excludedRanges: [NSRange] = [],
        to layoutManager: NSLayoutManager
    ) {
        let range = NSRange(location: 0, length: (source as NSString).length)
        for match in expression.matches(in: source, range: range) {
            guard match.numberOfRanges > group else { continue }
            let matchRange = match.range(at: group)
            guard !overlapsAny(matchRange, ranges: excludedRanges) else { continue }
            layoutManager.addTemporaryAttribute(
                .foregroundColor,
                value: color,
                forCharacterRange: matchRange
            )
        }
    }

    private static func add(
        _ color: NSColor,
        ranges: [NSRange],
        to layoutManager: NSLayoutManager
    ) {
        for range in ranges {
            layoutManager.addTemporaryAttribute(
                .foregroundColor,
                value: color,
                forCharacterRange: range
            )
        }
    }

    private static func ranges(
        matching expression: NSRegularExpression,
        in source: String
    ) -> [NSRange] {
        let range = NSRange(location: 0, length: (source as NSString).length)
        return expression.matches(in: source, range: range).map(\.range)
    }

    private static func overlapsAny(_ range: NSRange, ranges: [NSRange]) -> Bool {
        guard range.length > 0, !ranges.isEmpty else { return false }

        var lowerBound = 0
        var upperBound = ranges.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if NSMaxRange(ranges[middle]) <= range.location {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        guard lowerBound < ranges.count else { return false }
        return ranges[lowerBound].location < NSMaxRange(range)
    }

    private static func expression(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }
}

private enum WhistleRuleSyntax {
    static let protocols = [
        "auth", "attachment", "cache", "cipher", "cssAppend", "cssBody",
        "cssPrepend", "delete", "disable", "enable", "excludeFilter", "file",
        "filter", "forwardedFor", "frameScript", "headerReplace", "host", "htmlAppend",
        "htmlBody", "htmlPrepend", "http", "https", "https-proxy", "ignore",
        "includeFilter", "jsAppend", "jsBody", "jsPrepend", "lineProps", "locationHref",
        "log", "method", "pac", "params", "pathReplace", "pipe", "proxy", "rawfile",
        "redirect", "referer", "replaceStatus", "reqAppend", "reqBody", "reqCharset",
        "reqCookies", "reqCors", "reqDelay", "reqHeaders", "reqMerge", "reqPrepend",
        "reqReplace", "reqRules", "reqScript", "reqSpeed", "reqType", "reqWrite",
        "reqWriteRaw", "resAppend", "resBody", "resCharset", "resCookies", "resCors",
        "resDelay", "resHeaders", "resMerge", "resPrepend", "resReplace", "resRules",
        "resScript", "resSpeed", "resType", "resWrite", "resWriteRaw", "responseFor",
        "rulesFile", "rulesScript", "skip", "sniCallback", "socks", "statusCode", "style",
        "tlsOptions", "tpl", "trailers", "tunnel", "ua", "urlParams", "weinre", "ws",
        "wss", "xfile", "xhost", "xhttps-proxy", "xproxy", "xrawfile", "xsocks", "xtpl"
    ]

    static func isKnownProtocol(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: CharacterSet(charactersIn: "!"))
        return protocols.contains { $0.caseInsensitiveCompare(normalized) == .orderedSame }
            || normalized.hasPrefix("plugin.")
            || normalized.hasPrefix("whistle.")
    }
}

@MainActor
final class WhistleRuleNameAlertController: NSObject, NSTextFieldDelegate {
    private let alert = NSAlert()
    private let nameField: NSTextField
    private let isValid: (String) -> Bool

    init(
        title: String,
        placeholder: String,
        initialName: String,
        confirmTitle: String,
        cancelTitle: String,
        isValid: @escaping (String) -> Bool
    ) {
        nameField = NSTextField(string: initialName)
        self.isValid = isValid
        super.init()

        alert.messageText = title
        alert.addButton(withTitle: confirmTitle)
        let cancelButton = alert.addButton(withTitle: cancelTitle)
        cancelButton.keyEquivalent = "\u{1b}"

        nameField.placeholderString = placeholder
        nameField.usesSingleLineMode = true
        nameField.lineBreakMode = .byTruncatingTail
        nameField.frame = NSRect(x: 0, y: 0, width: 400, height: 24)
        nameField.delegate = self
        alert.accessoryView = nameField
        alert.window.initialFirstResponder = nameField
        updateConfirmButton()
    }

    func present(attachedTo window: NSWindow?, completion: @escaping (String?) -> Void) {
        if let window {
            alert.beginSheetModal(for: window) { [self] response in
                completion(result(for: response))
            }
            nameField.selectText(nil)
            return
        }

        nameField.selectText(nil)
        completion(result(for: alert.runModal()))
    }

    func controlTextDidChange(_ notification: Notification) {
        updateConfirmButton()
    }

    private func updateConfirmButton() {
        alert.buttons.first?.isEnabled = isValid(nameField.stringValue)
    }

    private func result(for response: NSApplication.ModalResponse) -> String? {
        response == .alertFirstButtonReturn ? nameField.stringValue : nil
    }
}

final class WhistleLineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let scrollView = textView.enclosingScrollView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else { return }

        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.withAlphaComponent(0.12).setFill()
        let displayScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let hairlineWidth = 1 / max(displayScale, 1)
        NSRect(
            x: bounds.maxX - hairlineWidth,
            y: bounds.minY,
            width: hairlineWidth,
            height: bounds.height
        ).fill()

        let visibleRect = scrollView.contentView.bounds
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let characterRange = layoutManager.characterRange(
            forGlyphRange: glyphRange,
            actualGlyphRange: nil
        )
        let source = textView.string as NSString
        let safeLocation = min(characterRange.location, source.length)
        let firstLineRange = source.lineRange(for: NSRange(location: safeLocation, length: 0))
        var characterIndex = firstLineRange.location
        var lineNumber = 1 + newlineCount(in: source, before: characterIndex)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        while characterIndex <= source.length {
            let lineRect: NSRect
            if characterIndex == source.length {
                guard source.length == 0 || source.character(at: source.length - 1) == 10 else {
                    break
                }
                lineRect = layoutManager.extraLineFragmentRect
            } else {
                let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
                lineRect = layoutManager.lineFragmentRect(
                    forGlyphAt: glyphIndex,
                    effectiveRange: nil
                )
            }

            let drawingY = lineRect.minY
                + textView.textContainerOrigin.y
                - visibleRect.minY
            if drawingY > bounds.maxY { break }
            if drawingY + lineRect.height >= bounds.minY {
                let label = "\(lineNumber)" as NSString
                let labelSize = label.size(withAttributes: attributes)
                label.draw(
                    at: NSPoint(
                        x: ruleThickness - labelSize.width - 9,
                        y: drawingY + max(0, (lineRect.height - labelSize.height) / 2)
                    ),
                    withAttributes: attributes
                )
            }

            guard characterIndex < source.length else { break }
            let lineRange = source.lineRange(for: NSRange(location: characterIndex, length: 0))
            let nextIndex = NSMaxRange(lineRange)
            guard nextIndex > characterIndex else { break }
            characterIndex = nextIndex
            lineNumber += 1
        }
    }

    private func newlineCount(in source: NSString, before location: Int) -> Int {
        guard location > 0 else { return 0 }
        var count = 0
        for index in 0..<min(location, source.length) where source.character(at: index) == 10 {
            count += 1
        }
        return count
    }
}
