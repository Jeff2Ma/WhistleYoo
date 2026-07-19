import AppKit
import SwiftUI
#if canImport(whistleYooCore)
import whistleYooCore
#endif

/// A native counterpart of Whistle's Rules workspace: rule list on the left,
/// editor on the right, and explicit Create/Delete/Rename/Save interactions.
@MainActor
final class RuleConfigurationDraft: ObservableObject {
    @Published var selectedName: String?
    @Published private(set) var documents: [WhistleRuleDocument] = []

    private var savedDocuments: [WhistleRuleDocument] = []
    private var backRulesFirst = false

    var isDirty: Bool {
        documents != savedDocuments
    }

    var snapshot: WhistleRulesSnapshot {
        WhistleRulesSnapshot(
            documents: documents,
            allowMultipleChoice: true,
            backRulesFirst: backRulesFirst
        )
    }

    func synchronize(with snapshot: WhistleRulesSnapshot, preferredName: String?) {
        guard savedDocuments.isEmpty || !isDirty else { return }
        replace(with: snapshot, preferredName: preferredName)
    }

    func discardChanges() {
        documents = savedDocuments
        normalizeSelection(preferredName: selectedName)
    }

    func replace(with snapshot: WhistleRulesSnapshot, preferredName: String?) {
        documents = snapshot.documents.map { document in
            guard document.isDefault else { return document }
            return WhistleRuleDocument(
                name: document.name,
                value: document.value,
                isEnabled: true,
                isDefault: true
            )
        }
        savedDocuments = documents
        backRulesFirst = snapshot.backRulesFirst
        normalizeSelection(preferredName: preferredName)
    }

    func updateValue(_ value: String, name: String) {
        update(name: name) { document in
            guard !document.isDefault else { return document }
            return WhistleRuleDocument(
                name: document.name,
                value: value,
                isEnabled: document.isEnabled
            )
        }
    }

    func setEnabled(_ enabled: Bool, name: String) {
        guard let target = documents.first(where: { $0.name == name }), !target.isDefault else { return }
        update(name: name) { document in
            guard !document.isDefault else { return document }
            return WhistleRuleDocument(
                name: document.name,
                value: document.value,
                isEnabled: enabled
            )
        }
    }

    func create(name: String) {
        documents.append(WhistleRuleDocument(name: name, value: "", isEnabled: true))
        selectedName = name
    }

    func rename(name: String, to newName: String) {
        update(name: name) { document in
            guard !document.isDefault else { return document }
            return WhistleRuleDocument(
                name: newName,
                value: document.value,
                isEnabled: document.isEnabled
            )
        }
        if selectedName == name {
            selectedName = newName
        }
    }

    func delete(name: String) {
        guard let document = documents.first(where: { $0.name == name }), !document.isDefault else { return }
        documents.removeAll { $0.name == name }
        normalizeSelection(preferredName: selectedName == name ? nil : selectedName)
    }

    func move(name: String, over targetName: String) {
        guard name != targetName,
              let sourceIndex = documents.firstIndex(where: { $0.name == name && !$0.isDefault }),
              let targetIndex = documents.firstIndex(where: { $0.name == targetName && !$0.isDefault })
        else { return }

        documents.move(
            fromOffsets: IndexSet(integer: sourceIndex),
            toOffset: targetIndex > sourceIndex ? targetIndex + 1 : targetIndex
        )
    }

    private func update(
        name: String,
        transform: (WhistleRuleDocument) -> WhistleRuleDocument
    ) {
        guard let index = documents.firstIndex(where: { $0.name == name }) else { return }
        documents[index] = transform(documents[index])
    }

    private func normalizeSelection(preferredName: String?) {
        selectedName = documents.contains(where: { $0.name == preferredName })
            ? preferredName
            : documents.first?.name
    }
}

struct RuleConfigurationView: View {
    private static let defaultRuleExample = """
    # 初始规则可以让一些日常使用软件在代理下工作
    # command+s to save
    # Double click to enable/disable rule

    # hosts bindings
    # 10.101.73.189  g.alicdn.com
    # 140.205.215.168  i.alicdn.com b.alicdn.com  u.alicdn.com

    # mapping web page
    # https://www.google.com https://www.alibaba.com

    # mapping to file
    # https://www.google.com file:///User/xxx/xxx.html

    # mapping by wildcard
    # ^https://*.example.com file:///User/xxx/xxx.html
    """

    @ObservedObject var state: AppStateController
    @ObservedObject var draft: RuleConfigurationDraft

    @State private var filter = ""
    @State private var isCreating = false
    @State private var isDeleting = false
    @State private var isDiscardingForReload = false
    @State private var createName = ""
    @State private var saveFeedback: String?
    @State private var saveFeedbackID: UUID?

    private var selectedName: String? {
        get { draft.selectedName }
        nonmutating set { draft.selectedName = newValue }
    }

    private var editorValue: String {
        get { selectedDocument?.value ?? "" }
        nonmutating set {
            guard let selectedName else { return }
            draft.updateValue(newValue, name: selectedName)
        }
    }

    private var editorEnabled: Bool {
        get { selectedDocument?.isEnabled ?? false }
        nonmutating set {
            guard let selectedName else { return }
            draft.setEnabled(newValue, name: selectedName)
        }
    }

    private var displayedEditorValue: String {
        guard selectedDocument?.isDefault == true, editorValue.isEmpty else {
            return editorValue
        }
        return Self.defaultRuleExample
    }

    var body: some View {
        VStack(spacing: 0) {
            globalToolbar
            Divider()
            HSplitView {
                ruleList
                    .frame(minWidth: 230, idealWidth: 255, maxWidth: 320)
                editor
                    .frame(minWidth: 460)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            if state.rulesSnapshot.documents.isEmpty {
                _ = await state.loadRules()
            }
            synchronizeSelection(preferredName: selectedName)
        }
        .onChange(of: state.rulesSnapshot) { _ in
            synchronizeSelection(preferredName: selectedName)
        }
        .alert(Localization.string(.rulesCreateRule), isPresented: $isCreating) {
            TextField(Localization.string(.rulesRuleName), text: $createName)
            Button(Localization.string(.rulesCancel), role: .cancel) {}
            Button(Localization.string(.rulesCreate)) { createRule() }
                .disabled(!isValidCreateName)
        } message: {
            Text(Localization.string(.rulesTheNewRuleIsEnabledAutomaticallyClickSaveAfterFinishingAllRul))
        }
        .alert(Localization.string(.rulesConfirmDeleteRule), isPresented: $isDeleting) {
            Button(Localization.string(.rulesCancel), role: .cancel) {}
            Button(Localization.string(.rulesDelete), role: .destructive) { deleteRule() }
        } message: {
            Text(Localization.format(
                .rulesThisRemovesValueFromWhistleyooSDedicatedWhistleRuleStorageAfte,
                selectedName ?? ""
            ))
        }
        .alert(Localization.string(.rulesReloadAndDiscardChanges), isPresented: $isDiscardingForReload) {
            Button(Localization.string(.rulesKeepEditing), role: .cancel) {}
            Button(Localization.string(.rulesReload), role: .destructive) {
                draft.discardChanges()
                reloadRules()
            }
        }
        .onChange(of: isCreating) { isPresented in
            if !isPresented {
                createName = ""
            }
        }
    }

    private var globalToolbar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Localization.string(.rulesConfiguration))
                    .font(.title3.weight(.semibold))
                Text(Localization.string(.rulesCombineAndApplyRuleSetsFromWhistleInListOrder))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if isDirty {
                Label(Localization.string(.rulesUnsaved), systemImage: "circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.1), in: Capsule())
            } else if let saveFeedback {
                Label(saveFeedback, systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            }
            Spacer()
            Button {
                if isDirty {
                    isDiscardingForReload = true
                } else {
                    reloadRules()
                }
            } label: { Text(Localization.string(.rulesRefresh)) }
            .help(Localization.string(.rulesReloadRulesFromWhistle))
            .disabled(isRuleOperationInProgress)

            Button(Localization.string(.rulesSave)) { saveAllRules() }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!isDirty || isRuleOperationInProgress)
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
        .background(.bar)
    }

    private var ruleList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(Localization.string(.rulesRuleSets))
                            .font(.headline)
                        Text("\(draft.documents.count)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.055), in: Capsule())
                    }
                    Text(Localization.string(.rulesDragToChangeTheEffectiveOrder))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if state.isLoadingRules {
                    ProgressView().controlSize(.small)
                }
                Button {
                    createName = nextRuleName()
                    isCreating = true
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(HoverIconButtonStyle())
                .help(Localization.string(.rulesCreateRule))
                .accessibilityLabel(Localization.string(.rulesCreateRule))
                .disabled(isRuleOperationInProgress)
            }
            .padding(.horizontal, 12)
            .frame(height: 54)

            searchField
                .padding(.horizontal, 10)
                .padding(.bottom, 10)

            if filteredDocuments.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                    Text(Localization.string(.rulesNoMatchingRules))
                        .font(.callout.weight(.medium))
                    Text(Localization.string(.rulesTryAnotherSearchTerm))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(filteredDocuments) { document in
                            ruleRow(document)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .scrollContentBackground(.hidden)
            }

            if !filter.isEmpty {
                Text(Localization.format(.rulesValueRuleSetsFoundClearSearchToReorder, Int64(filteredDocuments.count)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Color.primary.opacity(0.025))
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(Localization.string(.rulesSearchNamesOrContent), text: $filter)
                .textFieldStyle(.plain)
            if !filter.isEmpty {
                Button { filter = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(Localization.string(.rulesClearSearch))
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .hairlineRoundedBorder(Color.primary.opacity(0.08), cornerRadius: 7)
    }

    @ViewBuilder
    private func ruleRow(_ document: WhistleRuleDocument) -> some View {
        if !document.isDefault && filter.isEmpty {
            ruleRowContent(document, isDraggable: true)
                .draggable(document.name)
                .dropDestination(for: String.self) { names, _ in
                    guard let draggedName = names.first, draggedName != document.name else {
                        return false
                    }
                    withAnimation(.easeInOut(duration: 0.14)) {
                        draft.move(name: draggedName, over: document.name)
                    }
                    return true
                }
        } else {
            ruleRowContent(document, isDraggable: false)
        }
    }

    private func ruleRowContent(
        _ document: WhistleRuleDocument,
        isDraggable: Bool
    ) -> some View {
        RuleListRow(
            document: document,
            isSelected: selectedName == document.name,
            isDraggable: isDraggable,
            query: filter,
            matchCount: matchCount(in: document),
            enabled: enabledBinding(for: document),
            isInteractionDisabled: isRuleOperationInProgress,
            select: { selectedName = document.name }
        )
    }

    @ViewBuilder
    private var editor: some View {
        if let document = selectedDocument {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    HStack(spacing: 3) {
                        Text(document.name)
                            .font(.headline)
                            .lineLimit(1)
                        if !document.isDefault {
                            Button {
                                presentRenameAlert(for: document)
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 11, weight: .medium))
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(HoverIconButtonStyle())
                            .help(Localization.string(.rulesRenameRule))
                            .accessibilityLabel(Localization.string(.rulesRenameRule))
                            .disabled(isRuleOperationInProgress)
                        }
                    }
                    Spacer()

                    Button(role: .destructive) {
                        isDeleting = true
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(HoverIconButtonStyle(role: .destructive))
                    .help(Localization.string(.rulesDeleteRule))
                    .accessibilityLabel(Localization.string(.rulesDeleteRule))
                    .disabled(document.isDefault || isRuleOperationInProgress)
                }
                .padding(.horizontal, 16)
                .frame(height: 48)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))

                Divider()

                RuleTextEditor(
                    text: Binding(
                        get: { displayedEditorValue },
                        set: { editorValue = $0 }
                    ),
                    isEditable: !document.isDefault && !isRuleOperationInProgress,
                    searchQuery: filter
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipped()

                Divider()

                HStack {
                    Text(document.isDefault
                        ? defaultCompatibilityHint
                        : Localization.string(.rulesEnterOneRulePerLineTheFullWhistleRuleSyntaxIsSupported))
                    Spacer()
                    if !filter.isEmpty {
                        Text(Localization.format(.rulesValueMatches, Int64(editorMatchCount)))
                        Text("·")
                    }
                    Text(Localization.format(.rulesValueLines, Int64(lineCount)))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .frame(height: 32)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
                Text(Localization.string(.rulesNoEditableRules))
                    .font(.title3.weight(.semibold))
                Text(Localization.string(.rulesRefreshTheRulesOrCreateANewRuleFile))
                    .foregroundStyle(.secondary)
                Button(Localization.string(.rulesRefresh)) { reloadRules() }
                    .buttonStyle(.bordered)
                    .disabled(isRuleOperationInProgress)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var filteredDocuments: [WhistleRuleDocument] {
        guard !filter.isEmpty else { return draft.documents }
        return draft.documents.filter {
            $0.name.localizedCaseInsensitiveContains(filter)
                || $0.value.localizedCaseInsensitiveContains(filter)
        }
    }

    private var selectedDocument: WhistleRuleDocument? {
        draft.documents.first { $0.name == selectedName }
    }

    private var editorMatchCount: Int {
        occurrenceCount(of: filter, in: displayedEditorValue)
    }

    private var defaultCompatibilityHint: String {
        guard state.settings.softwareDomainWhitelistEnabled, editorEnabled else {
            return Localization.string(.rulesBuiltInCompatibilityRulesAreDisabledManageThemInSettings)
        }
        let count = SoftwareDomainWhitelistManager.normalizedDomains(
            state.settings.softwareDomainWhitelistDomains
        ).count
        return Localization.format(
            .rulesBuiltInCompatibilityRulesAreEnabledValueDomainsManageThemInSe,
            Int64(count)
        )
    }

    private func enabledBinding(for document: WhistleRuleDocument) -> Binding<Bool> {
        Binding(
            get: {
                draft.documents.first(where: { $0.name == document.name })?.isEnabled
                    ?? document.isEnabled
            },
            set: { setRuleEnabled($0, document: document) }
        )
    }

    private func matchCount(in document: WhistleRuleDocument) -> Int {
        occurrenceCount(of: filter, in: document.name)
            + occurrenceCount(of: filter, in: document.value)
    }

    private func occurrenceCount(of query: String, in value: String) -> Int {
        guard !query.isEmpty else { return 0 }
        let source = value as NSString
        var searchRange = NSRange(location: 0, length: source.length)
        var count = 0
        while searchRange.length > 0 {
            let match = source.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchRange
            )
            guard match.location != NSNotFound else { break }
            count += 1
            let nextLocation = NSMaxRange(match)
            searchRange = NSRange(location: nextLocation, length: source.length - nextLocation)
        }
        return count
    }

    private var isDirty: Bool {
        draft.isDirty
    }

    private var isRuleOperationInProgress: Bool {
        state.isLoadingRules || state.isSavingRules
    }

    private var lineCount: Int {
        displayedEditorValue.isEmpty
            ? 1
            : displayedEditorValue.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    private var isValidCreateName: Bool {
        isValidRuleName(createName)
            && !draft.documents.contains(where: { $0.name == createName })
    }

    private func isValidRuleName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed == name
            && name != "Default"
    }

    private func synchronizeSelection(preferredName: String?) {
        draft.synchronize(with: state.rulesSnapshot, preferredName: preferredName)
    }

    private func saveAllRules() {
        guard isDirty, !isRuleOperationInProgress else { return }
        let updated = draft.snapshot
        let preferredName = selectedName
        saveFeedback = nil
        Task {
            if await state.saveRulesSnapshot(updated) {
                draft.replace(with: state.rulesSnapshot, preferredName: preferredName)
                showSaveFeedback()
            }
        }
    }

    private func setRuleEnabled(_ enabled: Bool, document: WhistleRuleDocument) {
        guard !document.isDefault, !isRuleOperationInProgress else { return }
        draft.setEnabled(enabled, name: document.name)
    }

    private func reloadRules() {
        guard !isRuleOperationInProgress else { return }
        saveFeedback = nil
        Task {
            if await state.loadRules() {
                draft.replace(with: state.rulesSnapshot, preferredName: selectedName)
            }
        }
    }

    private func createRule() {
        guard !isRuleOperationInProgress else { return }
        draft.create(name: createName)
    }

    private func presentRenameAlert(for document: WhistleRuleDocument) {
        guard !isRuleOperationInProgress else { return }
        let dialog = RuleNameAlertController(
            title: Localization.string(.rulesRenameRule),
            placeholder: Localization.string(.rulesRuleName),
            initialName: document.name,
            confirmTitle: Localization.string(.rulesRename),
            cancelTitle: Localization.string(.rulesCancel)
        ) { candidate in
            isValidRuleName(candidate)
                && candidate != document.name
                && !draft.documents.contains(where: {
                    $0.name == candidate && $0.name != document.name
                })
        }
        dialog.present(attachedTo: NSApp.keyWindow) { newName in
            guard let newName else { return }
            draft.rename(name: document.name, to: newName)
        }
    }

    private func deleteRule() {
        guard let name = selectedName, !isRuleOperationInProgress else { return }
        draft.delete(name: name)
    }

    private func nextRuleName() -> String {
        var index = 1
        while draft.documents.contains(where: { $0.name == "Rules \(index)" }) {
            index += 1
        }
        return "Rules \(index)"
    }

    private func showSaveFeedback() {
        let feedbackID = UUID()
        saveFeedbackID = feedbackID
        saveFeedback = Localization.string(.rulesSaved)
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard saveFeedbackID == feedbackID else { return }
            saveFeedback = nil
            saveFeedbackID = nil
        }
    }
}

private struct RuleListRow: View {
    let document: WhistleRuleDocument
    let isSelected: Bool
    let isDraggable: Bool
    let query: String
    let matchCount: Int
    @Binding var enabled: Bool
    let isInteractionDisabled: Bool
    let select: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 11)
                .opacity(isDraggable ? (isHovering ? 1 : 0.55) : 0)

            Button(action: select) {
                HStack(spacing: 9) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(enabled
                                ? Color.green.opacity(isSelected ? 0.18 : 0.11)
                                : Color.primary.opacity(0.055))
                        Image(systemName: document.isDefault ? "lock.doc" : "doc.text")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(enabled ? Color.green : Color.secondary)
                    }
                    .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 3) {
                        highlightedName
                            .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                        Text(document.isDefault ? Localization.string(.rulesDefaultAlwaysEnabled) : (enabled ? Localization.string(.rulesEnabledState) : Localization.string(.rulesNotEnabled)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isInteractionDisabled)

            if matchCount > 0 {
                Text("\(matchCount)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.1), in: Capsule())
            }

            Toggle(
                document.isDefault
                    ? Localization.string(.rulesTheDefaultRuleIsAlwaysEnabled)
                    : Localization.format(.rulesEnableRuleSetValue, document.name),
                isOn: $enabled
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help(document.isDefault
                ? Localization.string(.rulesTheDefaultRuleIsAlwaysEnabled)
                : Localization.format(.rulesEnableRuleSetValue, document.name))
            .disabled(document.isDefault || isInteractionDisabled)
        }
        .padding(.horizontal, 8)
        .frame(height: 48)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .hairlineRoundedBorder(
            isSelected ? Color.accentColor.opacity(0.18) : Color.clear,
            cornerRadius: 9,
            style: .continuous
        )
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.1), value: isHovering)
        .animation(.easeOut(duration: 0.1), value: isSelected)
    }

    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.12) }
        if isHovering { return Color.primary.opacity(0.045) }
        return .clear
    }

    private var highlightedName: Text {
        guard !query.isEmpty else { return Text(document.name) }
        let source = document.name as NSString
        let match = source.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive]
        )
        guard match.location != NSNotFound else { return Text(document.name) }
        let prefix = source.substring(to: match.location)
        let value = source.substring(with: match)
        let suffix = source.substring(from: NSMaxRange(match))
        return Text(prefix)
            + Text(value).foregroundColor(.accentColor).bold()
            + Text(suffix)
    }
}

private struct HoverIconButtonStyle: ButtonStyle {
    enum Role: Equatable {
        case standard
        case destructive
    }

    var role: Role = .standard

    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration, role: role)
    }

    struct Body: View {
        let configuration: Configuration
        let role: Role
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(foregroundColor)
                .background(backgroundColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.08), value: isHovering)
                .animation(.easeOut(duration: 0.06), value: configuration.isPressed)
        }

        private var foregroundColor: Color {
            guard isEnabled else { return .secondary.opacity(0.45) }
            if role == .destructive, isHovering { return .red }
            return isHovering ? .primary : .secondary
        }

        private var backgroundColor: Color {
            guard isEnabled else { return .clear }
            if configuration.isPressed { return Color.primary.opacity(0.12) }
            if isHovering {
                return role == .destructive ? Color.red.opacity(0.1) : Color.primary.opacity(0.07)
            }
            return .clear
        }
    }
}

/// AppKit's native text system provides the standard editing responder chain
/// even though WhistleYoo builds its main menu manually instead of using a
/// SwiftUI `App`. The explicit key-equivalent handling keeps the expected
/// Command-C/V/A behavior available in that setup.
private struct RuleTextEditor: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    let searchQuery: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .windowBackgroundColor
        scrollView.clipsToBounds = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.contentView.postsBoundsChangedNotifications = true

        let textView = StandardRuleTextView(frame: scrollView.contentView.bounds)
        textView.delegate = context.coordinator
        textView.string = text
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .windowBackgroundColor
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.documentView = textView

        let lineNumberRuler = RuleLineNumberRulerView(textView: textView)
        lineNumberRuler.clipsToBounds = true
        scrollView.verticalRulerView = lineNumberRuler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        context.coordinator.attach(
            scrollView: scrollView,
            lineNumberRuler: lineNumberRuler
        )
        context.coordinator.updateHighlights(in: textView, query: searchQuery)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? StandardRuleTextView else { return }
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(
                location: min(selection.location, (text as NSString).length),
                length: 0
            ))
        }
        textView.isEditable = isEditable
        textView.isSelectable = true
        context.coordinator.updateHighlights(in: textView, query: searchQuery)
        context.coordinator.invalidateLineNumbers()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private static let commentPattern = try! NSRegularExpression(
            pattern: #"(?m)^[\t ]*#.*$"#
        )

        @Binding private var text: String
        private weak var textView: NSTextView?
        private weak var lineNumberRuler: RuleLineNumberRulerView?
        private var boundsObserver: NSObjectProtocol?
        private var searchQuery = ""

        init(text: Binding<String>) {
            _text = text
        }

        deinit {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
        }

        func attach(scrollView: NSScrollView, lineNumberRuler: RuleLineNumberRulerView) {
            self.textView = scrollView.documentView as? NSTextView
            self.lineNumberRuler = lineNumberRuler
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak lineNumberRuler] _ in
                lineNumberRuler?.needsDisplay = true
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
            updateHighlights(in: textView, query: searchQuery)
            invalidateLineNumbers()
        }

        func updateHighlights(in textView: NSTextView, query: String) {
            self.textView = textView
            searchQuery = query
            guard let layoutManager = textView.layoutManager else { return }
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
            layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: fullRange)

            if fullRange.length > 0 {
                for match in Self.commentPattern.matches(
                    in: textView.string,
                    range: fullRange
                ) {
                    layoutManager.addTemporaryAttribute(
                        .foregroundColor,
                        value: NSColor.systemGreen,
                        forCharacterRange: match.range
                    )
                }
            }

            guard !query.isEmpty, fullRange.length > 0 else { return }

            let source = textView.string as NSString
            var searchRange = fullRange
            while searchRange.length > 0 {
                let match = source.range(
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
                searchRange = NSRange(location: nextLocation, length: source.length - nextLocation)
            }
        }

        func invalidateLineNumbers() {
            lineNumberRuler?.needsDisplay = true
        }
    }
}

@MainActor
private final class RuleNameAlertController: NSObject, NSTextFieldDelegate {
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

private final class RuleLineNumberRulerView: NSRulerView {
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
                guard source.length == 0 || source.character(at: source.length - 1) == 10 else { break }
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

private final class StandardRuleTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command),
              !modifiers.contains(.control),
              !modifiers.contains(.option),
              !modifiers.contains(.shift),
              let key = event.charactersIgnoringModifiers?.lowercased()
        else {
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case "a":
            selectAll(nil)
        case "c":
            copy(nil)
        case "v":
            paste(nil)
        case "x":
            cut(nil)
        default:
            return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
