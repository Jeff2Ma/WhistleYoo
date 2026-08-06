import AppKit
import SwiftUI
#if canImport(whistleYooCore)
import whistleYooCore
#endif

/// A native counterpart of Whistle's Rules and Values workspaces.
@MainActor
final class RuleConfigurationDraft: ObservableObject {
    @Published var selectedName: String?
    @Published var selectedValueName: String?
    @Published private(set) var documents: [WhistleRuleDocument] = []
    @Published private(set) var valueDocuments: [WhistleValueDocument] = []

    private var savedDocuments: [WhistleRuleDocument] = []
    private var savedValueDocuments: [WhistleValueDocument] = []
    private var backRulesFirst = false

    var isDirty: Bool {
        rulesAreDirty || valuesAreDirty
    }

    var rulesAreDirty: Bool {
        documents != savedDocuments
    }

    var valuesAreDirty: Bool {
        valueDocuments != savedValueDocuments
    }

    var snapshot: WhistleRulesSnapshot {
        WhistleRulesSnapshot(
            documents: documents,
            allowMultipleChoice: true,
            backRulesFirst: backRulesFirst
        )
    }

    var valuesSnapshot: WhistleValuesSnapshot {
        WhistleValuesSnapshot(documents: valueDocuments)
    }

    func synchronize(with snapshot: WhistleRulesSnapshot, preferredName: String?) {
        guard savedDocuments.isEmpty || !rulesAreDirty else { return }
        replace(with: snapshot, preferredName: preferredName)
    }

    func synchronizeValues(with snapshot: WhistleValuesSnapshot, preferredName: String?) {
        guard savedValueDocuments.isEmpty || !valuesAreDirty else { return }
        replaceValues(with: snapshot, preferredName: preferredName)
    }

    func discardChanges() {
        discardRuleChanges()
        discardValueChanges()
    }

    func discardRuleChanges() {
        documents = savedDocuments
        normalizeSelection(preferredName: selectedName)
    }

    func discardValueChanges() {
        valueDocuments = savedValueDocuments
        normalizeValueSelection(preferredName: selectedValueName)
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

    func replaceValues(with snapshot: WhistleValuesSnapshot, preferredName: String?) {
        valueDocuments = snapshot.documents
        savedValueDocuments = valueDocuments
        normalizeValueSelection(preferredName: preferredName)
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

    func duplicate(name: String) {
        guard let target = documents.first(where: { $0.name == name }), !target.isDefault else { return }
        var index = 1
        var candidate = "\(name) (副本)"
        while documents.contains(where: { $0.name == candidate }) {
            index += 1
            candidate = "\(name) (副本 \(index))"
        }
        let copy = WhistleRuleDocument(name: candidate, value: target.value, isEnabled: true)
        if let sourceIdx = documents.firstIndex(where: { $0.name == name }) {
            documents.insert(copy, at: sourceIdx + 1)
        } else {
            documents.append(copy)
        }
        selectedName = candidate
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

    func updateValueDocument(_ value: String, name: String) {
        guard let index = valueDocuments.firstIndex(where: { $0.name == name }) else { return }
        valueDocuments[index] = WhistleValueDocument(name: name, value: value)
    }

    func createValue(name: String) {
        valueDocuments.append(WhistleValueDocument(name: name, value: ""))
        selectedValueName = name
    }

    func duplicateValue(name: String) {
        guard let target = valueDocuments.first(where: { $0.name == name }) else { return }
        var index = 1
        var candidate = "\(name) (副本)"
        while valueDocuments.contains(where: { $0.name == candidate }) {
            index += 1
            candidate = "\(name) (副本 \(index))"
        }
        let copy = WhistleValueDocument(name: candidate, value: target.value)
        if let sourceIdx = valueDocuments.firstIndex(where: { $0.name == name }) {
            valueDocuments.insert(copy, at: sourceIdx + 1)
        } else {
            valueDocuments.append(copy)
        }
        selectedValueName = candidate
    }

    func renameValue(name: String, to newName: String) {
        guard let index = valueDocuments.firstIndex(where: { $0.name == name }) else { return }
        valueDocuments[index] = WhistleValueDocument(
            name: newName,
            value: valueDocuments[index].value
        )
        if selectedValueName == name {
            selectedValueName = newName
        }
    }

    func deleteValue(name: String) {
        valueDocuments.removeAll { $0.name == name }
        normalizeValueSelection(preferredName: selectedValueName == name ? nil : selectedValueName)
    }

    func moveValue(name: String, over targetName: String) {
        guard name != targetName,
              let sourceIndex = valueDocuments.firstIndex(where: { $0.name == name }),
              let targetIndex = valueDocuments.firstIndex(where: { $0.name == targetName })
        else { return }

        valueDocuments.move(
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

    private func normalizeValueSelection(preferredName: String?) {
        selectedValueName = valueDocuments.contains(where: { $0.name == preferredName })
            ? preferredName
            : valueDocuments.first?.name
    }
}

enum RulesValuesWorkspace: String, CaseIterable, Identifiable {
    case rules
    case values

    var id: Self { self }

    var title: String {
        switch self {
        case .rules: return Localization.string(.rulesRules)
        case .values: return Localization.string(.valuesValues)
        }
    }
}

private enum RulesValuesLayout {
    static let listMinimumWidth: CGFloat = 220
    static let listIdealWidth: CGFloat = 250
    static let listMaximumWidth: CGFloat = 320
    static let editorMinimumWidth: CGFloat = 360
}

struct RuleConfigurationView: View {
    private static let defaultRuleExample = """
    # 初始规则可以让一些日常使用软件在代理下工作
    # command+s to save

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
    @Binding var workspace: RulesValuesWorkspace

    @State private var filter = ""
    @State private var isCreating = false
    @State private var isDeleting = false
    @State private var isDiscardingForReload = false
    @State private var pendingReloadWorkspace: RulesValuesWorkspace?
    @State private var createName = ""
    @State private var editorPosition = WhistleEditorPosition()

    private var selectedName: String? {
        get { draft.selectedName }
        nonmutating set { draft.selectedName = newValue }
    }

    private var editorValue: String {
        selectedDocument?.value ?? ""
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
            workspaceSwitcher
            HairlineDivider()
            if workspace == .rules {
                HSplitView {
                    ruleList
                        .frame(
                            minWidth: RulesValuesLayout.listMinimumWidth,
                            idealWidth: RulesValuesLayout.listIdealWidth,
                            maxWidth: RulesValuesLayout.listMaximumWidth
                        )
                    editor
                        .frame(minWidth: RulesValuesLayout.editorMinimumWidth)
                }
            } else {
                ValuesConfigurationContent(
                    state: state,
                    draft: draft,
                    isOperationInProgress: valuesOperationInProgress,
                    reload: reloadValues
                )
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            if state.rulesSnapshot.documents.isEmpty {
                _ = await state.loadRules()
            }
            if state.valuesSnapshot.documents.isEmpty {
                _ = await state.loadValues()
            }
            synchronizeSelection(preferredName: selectedName)
            synchronizeValueSelection(preferredName: draft.selectedValueName)
        }
        .onChange(of: state.rulesSnapshot) { _ in
            synchronizeSelection(preferredName: selectedName)
        }
        .onChange(of: state.valuesSnapshot) { _ in
            synchronizeValueSelection(preferredName: draft.selectedValueName)
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
            Button(Localization.string(.rulesKeepEditing), role: .cancel) {
                pendingReloadWorkspace = nil
            }
            Button(Localization.string(.rulesReload), role: .destructive) {
                guard let target = pendingReloadWorkspace else { return }
                discardChanges(in: target)
                reload(target)
                pendingReloadWorkspace = nil
            }
        }
        .onChange(of: isCreating) { isPresented in
            if !isPresented {
                createName = ""
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveRulesWorkspace)) { _ in
            saveCurrentWorkspace()
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshRulesWorkspace)) { _ in
            requestReload(workspace)
        }
    }

    private var workspaceSwitcher: some View {
        HStack(spacing: 10) {
            workspaceButton(.rules, symbol: "doc.text")
            workspaceButton(.values, symbol: "curlybraces.square")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
    }

    private func workspaceButton(
        _ target: RulesValuesWorkspace,
        symbol: String
    ) -> some View {
        let isSelected = workspace == target
        return Button {
            workspace = target
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected
                            ? Color.accentColor.opacity(0.16)
                            : Color.primary.opacity(0.055))
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(target.title)
                            .font(.system(size: 13, weight: .semibold))
                        if workspaceIsDirty(target) {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 6, height: 6)
                                .accessibilityLabel(Localization.string(.rulesUnsaved))
                        }
                    }
                    Text(workspaceDetail(target))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .padding(.horizontal, 11)
            .frame(minWidth: 160, idealWidth: 210, maxWidth: 210)
            .frame(height: 48)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.1)
                    : Color(nsColor: .windowBackgroundColor),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .hairlineRoundedBorder(
                isSelected ? Color.accentColor.opacity(0.38) : Color.primary.opacity(0.08),
                cornerRadius: 10,
                style: .continuous
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(target.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
                moveButton(
                    symbol: "arrow.up",
                    title: Localization.string(.rulesMoveUp),
                    enabled: canMoveSelectedRuleUp,
                    shortcut: .upArrow,
                    action: { moveSelectedRule(by: -1) }
                )
                moveButton(
                    symbol: "arrow.down",
                    title: Localization.string(.rulesMoveDown),
                    enabled: canMoveSelectedRuleDown,
                    shortcut: .downArrow,
                    action: { moveSelectedRule(by: 1) }
                )
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
                .disabled(rulesOperationInProgress)
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
            isInteractionDisabled: rulesOperationInProgress,
            select: { selectedName = document.name }
        )
        .contextMenu {
            if !document.isDefault {
                Button {
                    setRuleEnabled(!document.isEnabled, document: document)
                } label: {
                    Label(
                        document.isEnabled ? Localization.string(.rulesNotEnabled) : Localization.string(.rulesEnabled),
                        systemImage: document.isEnabled ? "power" : "checkmark.circle"
                    )
                }

                Button {
                    draft.duplicate(name: document.name)
                } label: {
                    Label(Localization.string(.rulesDuplicateRule), systemImage: "doc.on.doc")
                }

                Button {
                    presentRenameAlert(for: document)
                } label: {
                    Label(Localization.string(.rulesRenameRule), systemImage: "pencil")
                }

                Divider()

                Button {
                    moveSelectedRule(by: -1)
                } label: {
                    Label(Localization.string(.rulesMoveUp), systemImage: "arrow.up")
                }
                .disabled(!canMoveSelectedRuleUp)

                Button {
                    moveSelectedRule(by: 1)
                } label: {
                    Label(Localization.string(.rulesMoveDown), systemImage: "arrow.down")
                }
                .disabled(!canMoveSelectedRuleDown)

                Divider()

                Button(role: .destructive) {
                    selectedName = document.name
                    isDeleting = true
                } label: {
                    Label(Localization.string(.rulesDeleteRule), systemImage: "trash")
                }
            }
        }
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
                            .disabled(rulesOperationInProgress)
                        }
                    }
                    Spacer()

                    if !document.isDefault {
                        Button {
                            draft.duplicate(name: document.name)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .frame(width: 26, height: 26)
                        }
                        .buttonStyle(HoverIconButtonStyle())
                        .help(Localization.string(.rulesDuplicateRule))
                        .accessibilityLabel(Localization.string(.rulesDuplicateRule))
                        .disabled(rulesOperationInProgress)
                    }

                    Button(role: .destructive) {
                        isDeleting = true
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(HoverIconButtonStyle(role: .destructive))
                    .help(Localization.string(.rulesDeleteRule))
                    .accessibilityLabel(Localization.string(.rulesDeleteRule))
                    .disabled(document.isDefault || rulesOperationInProgress)
                }
                .padding(.horizontal, 16)
                .frame(height: 48)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))

                HairlineDivider()

                WhistleCodeEditor(
                    text: editorBinding(for: document),
                    documentID: "rules:\(document.name)",
                    language: .rules,
                    isEditable: !document.isDefault && !rulesOperationInProgress,
                    sidebarSearchQuery: filter,
                    valueNames: draft.valueDocuments.map(\.name),
                    onPositionChange: { editorPosition = $0 }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipped()

                HairlineDivider()

                EditorStatusBar(
                    hint: document.isDefault
                        ? defaultCompatibilityHint
                        : Localization.string(.rulesEnterOneRulePerLineTheFullWhistleRuleSyntaxIsSupported),
                    matchCount: filter.isEmpty ? nil : editorMatchCount,
                    lineCount: lineCount,
                    position: editorPosition
                )
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
                    .disabled(rulesOperationInProgress)
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

    private func editorBinding(for document: WhistleRuleDocument) -> Binding<String> {
        Binding(
            get: {
                let current = draft.documents.first { $0.name == document.name } ?? document
                guard current.isDefault, current.value.isEmpty else { return current.value }
                return Self.defaultRuleExample
            },
            set: { draft.updateValue($0, name: document.name) }
        )
    }

    private var selectedMovableRuleIndex: Int? {
        guard filter.isEmpty, let selectedName else { return nil }
        return movableRules.firstIndex { $0.name == selectedName }
    }

    private var movableRules: [WhistleRuleDocument] {
        draft.documents.filter { !$0.isDefault }
    }

    private var canMoveSelectedRuleUp: Bool {
        guard let selectedMovableRuleIndex else { return false }
        return selectedMovableRuleIndex > 0 && !rulesOperationInProgress
    }

    private var canMoveSelectedRuleDown: Bool {
        guard let selectedMovableRuleIndex else { return false }
        return selectedMovableRuleIndex < movableRules.count - 1 && !rulesOperationInProgress
    }

    private func moveSelectedRule(by offset: Int) {
        guard let selectedName, let selectedMovableRuleIndex else { return }
        let targetIndex = selectedMovableRuleIndex + offset
        guard movableRules.indices.contains(targetIndex) else { return }
        withAnimation(.easeInOut(duration: 0.14)) {
            draft.move(name: selectedName, over: movableRules[targetIndex].name)
        }
    }

    private func moveButton(
        symbol: String,
        title: String,
        enabled: Bool,
        shortcut: KeyEquivalent,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(HoverIconButtonStyle())
        .help(title)
        .accessibilityLabel(title)
        .keyboardShortcut(shortcut, modifiers: [.command, .option])
        .disabled(!enabled)
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

    private var rulesOperationInProgress: Bool {
        state.isLoadingRules || state.isSavingRules
    }

    private var valuesOperationInProgress: Bool {
        state.isLoadingValues || state.isSavingValues
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

    private func synchronizeValueSelection(preferredName: String?) {
        draft.synchronizeValues(with: state.valuesSnapshot, preferredName: preferredName)
    }

    private func workspaceIsDirty(_ workspace: RulesValuesWorkspace) -> Bool {
        workspace == .rules
            ? draft.rulesAreDirty
            : draft.valuesAreDirty
    }

    private func workspaceDetail(_ workspace: RulesValuesWorkspace) -> String {
        switch workspace {
        case .rules:
            return "\(draft.documents.count) · \(Localization.string(.rulesRuleSets))"
        case .values:
            return "\(draft.valueDocuments.count) · \(Localization.string(.valuesValueFiles))"
        }
    }

    private func requestReload(_ target: RulesValuesWorkspace) {
        guard !operationInProgress(in: target) else { return }
        if workspaceIsDirty(target) {
            pendingReloadWorkspace = target
            isDiscardingForReload = true
        } else {
            reload(target)
        }
    }

    private func reload(_ target: RulesValuesWorkspace) {
        switch target {
        case .rules: reloadRules()
        case .values: reloadValues()
        }
    }

    private func discardChanges(in target: RulesValuesWorkspace) {
        switch target {
        case .rules: draft.discardRuleChanges()
        case .values: draft.discardValueChanges()
        }
    }

    private func operationInProgress(in target: RulesValuesWorkspace) -> Bool {
        switch target {
        case .rules: return rulesOperationInProgress
        case .values: return valuesOperationInProgress
        }
    }

    private func saveCurrentWorkspace() {
        switch workspace {
        case .rules: saveRules()
        case .values: saveValues()
        }
    }

    private func saveRules() {
        guard draft.rulesAreDirty, !rulesOperationInProgress else { return }
        let updatedRules = draft.snapshot
        let preferredRuleName = selectedName
        Task {
            if await state.saveRulesSnapshot(updatedRules) {
                draft.replace(
                    with: state.rulesSnapshot,
                    preferredName: preferredRuleName
                )
            }
        }
    }

    private func saveValues() {
        guard draft.valuesAreDirty, !valuesOperationInProgress else { return }
        let updatedValues = draft.valuesSnapshot
        let preferredValueName = draft.selectedValueName
        Task {
            if await state.saveValuesSnapshot(updatedValues) {
                draft.replaceValues(
                    with: state.valuesSnapshot,
                    preferredName: preferredValueName
                )
            }
        }
    }

    private func setRuleEnabled(_ enabled: Bool, document: WhistleRuleDocument) {
        guard !document.isDefault, !rulesOperationInProgress else { return }
        draft.setEnabled(enabled, name: document.name)
    }

    private func reloadRules() {
        guard !rulesOperationInProgress else { return }
        Task {
            if await state.loadRules() {
                draft.replace(with: state.rulesSnapshot, preferredName: selectedName)
            }
        }
    }

    private func reloadValues() {
        guard !valuesOperationInProgress else { return }
        Task {
            if await state.loadValues() {
                draft.replaceValues(
                    with: state.valuesSnapshot,
                    preferredName: draft.selectedValueName
                )
            }
        }
    }

    private func createRule() {
        guard !rulesOperationInProgress else { return }
        draft.create(name: createName)
    }

    private func presentRenameAlert(for document: WhistleRuleDocument) {
        guard !rulesOperationInProgress else { return }
        let dialog = WhistleRuleNameAlertController(
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
        guard let name = selectedName, !rulesOperationInProgress else { return }
        draft.delete(name: name)
    }

    private func nextRuleName() -> String {
        var index = 1
        while draft.documents.contains(where: { $0.name == "Rules \(index)" }) {
            index += 1
        }
        return "Rules \(index)"
    }

}

private struct EditorStatusBar: View {
    let hint: String
    let matchCount: Int?
    let lineCount: Int
    let position: WhistleEditorPosition

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Text(hint)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 8)
                metrics
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                metrics
            }

            HStack {
                Spacer(minLength: 0)
                positionText
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 32)
        .help(hint)
    }

    private var metrics: some View {
        HStack(spacing: 6) {
            if let matchCount {
                Text(Localization.format(.rulesValueMatches, Int64(matchCount)))
                Text("·")
            }
            Text(Localization.format(.rulesValueLines, Int64(lineCount)))
            Text("·")
            positionText
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var positionText: some View {
        Text(Localization.format(
            .editorLineAndColumn,
            Int64(position.line),
            Int64(position.column)
        ))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct ValuesConfigurationContent: View {
    @ObservedObject var state: AppStateController
    @ObservedObject var draft: RuleConfigurationDraft
    let isOperationInProgress: Bool
    let reload: () -> Void

    @State private var filter = ""
    @State private var isCreating = false
    @State private var isDeleting = false
    @State private var createName = ""
    @State private var editorPosition = WhistleEditorPosition()

    private var selectedName: String? {
        get { draft.selectedValueName }
        nonmutating set { draft.selectedValueName = newValue }
    }

    private var selectedDocument: WhistleValueDocument? {
        draft.valueDocuments.first { $0.name == selectedName }
    }

    private var editorValue: String {
        selectedDocument?.value ?? ""
    }

    private func editorBinding(for document: WhistleValueDocument) -> Binding<String> {
        Binding(
            get: {
                draft.valueDocuments.first { $0.name == document.name }?.value ?? document.value
            },
            set: { draft.updateValueDocument($0, name: document.name) }
        )
    }

    var body: some View {
        HSplitView {
            valueList
                .frame(
                    minWidth: RulesValuesLayout.listMinimumWidth,
                    idealWidth: RulesValuesLayout.listIdealWidth,
                    maxWidth: RulesValuesLayout.listMaximumWidth
                )
            editor
                .frame(minWidth: RulesValuesLayout.editorMinimumWidth)
        }
        .alert(Localization.string(.valuesCreateValue), isPresented: $isCreating) {
            TextField(Localization.string(.valuesValueName), text: $createName)
            Button(Localization.string(.rulesCancel), role: .cancel) {}
            Button(Localization.string(.rulesCreate)) { createValue() }
                .disabled(!isValidCreateName)
        } message: {
            Text(Localization.string(.valuesEditTheNewValueOnTheRightThenSaveYourChanges))
        }
        .alert(Localization.string(.valuesConfirmDeleteValue), isPresented: $isDeleting) {
            Button(Localization.string(.rulesCancel), role: .cancel) {}
            Button(Localization.string(.rulesDelete), role: .destructive) { deleteValue() }
        } message: {
            Text(Localization.format(
                .valuesThisRemovesValueFromWhistleyooSDedicatedWhistleValuesStorage,
                selectedName ?? ""
            ))
        }
        .onChange(of: isCreating) { isPresented in
            if !isPresented {
                createName = ""
            }
        }
    }

    private var valueList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(Localization.string(.valuesValueFiles))
                            .font(.headline)
                        Text("\(draft.valueDocuments.count)")
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
                if state.isLoadingValues {
                    ProgressView().controlSize(.small)
                }
                valueMoveButton(
                    symbol: "arrow.up",
                    title: Localization.string(.rulesMoveUp),
                    enabled: canMoveSelectedValueUp,
                    shortcut: .upArrow,
                    action: { moveSelectedValue(by: -1) }
                )
                valueMoveButton(
                    symbol: "arrow.down",
                    title: Localization.string(.rulesMoveDown),
                    enabled: canMoveSelectedValueDown,
                    shortcut: .downArrow,
                    action: { moveSelectedValue(by: 1) }
                )
                Button {
                    createName = nextValueName()
                    isCreating = true
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(HoverIconButtonStyle())
                .help(Localization.string(.valuesCreateValue))
                .accessibilityLabel(Localization.string(.valuesCreateValue))
                .disabled(isOperationInProgress)
            }
            .padding(.horizontal, 12)
            .frame(height: 54)

            searchField
                .padding(.horizontal, 10)
                .padding(.bottom, 10)

            if filteredDocuments.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: filter.isEmpty ? "curlybraces.square" : "magnifyingglass")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                    Text(Localization.string(
                        filter.isEmpty ? .valuesNoValuesYet : .valuesNoMatchingValues
                    ))
                    .font(.callout.weight(.medium))
                    Text(Localization.string(
                        filter.isEmpty
                            ? .valuesCreateAValueFileToReuseContentAcrossRules
                            : .rulesTryAnotherSearchTerm
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(filteredDocuments) { document in
                            valueRow(document)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .scrollContentBackground(.hidden)
            }

            if !filter.isEmpty {
                Text(Localization.string(.valuesClearSearchToReorderValues))
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
            TextField(Localization.string(.valuesSearchNamesOrContent), text: $filter)
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
    private func valueRow(_ document: WhistleValueDocument) -> some View {
        if filter.isEmpty {
            valueRowContent(document, isDraggable: true)
                .draggable(document.name)
                .dropDestination(for: String.self) { names, _ in
                    guard let draggedName = names.first, draggedName != document.name else {
                        return false
                    }
                    withAnimation(.easeInOut(duration: 0.14)) {
                        draft.moveValue(name: draggedName, over: document.name)
                    }
                    return true
                }
        } else {
            valueRowContent(document, isDraggable: false)
        }
    }

    private func valueRowContent(
        _ document: WhistleValueDocument,
        isDraggable: Bool
    ) -> some View {
        ValueListRow(
            document: document,
            isSelected: selectedName == document.name,
            isDraggable: isDraggable,
            query: filter,
            matchCount: matchCount(in: document),
            isInteractionDisabled: isOperationInProgress,
            select: { selectedName = document.name }
        )
        .contextMenu {
            Button {
                draft.duplicateValue(name: document.name)
            } label: {
                Label(Localization.string(.valuesDuplicateValue), systemImage: "doc.on.doc")
            }

            Button {
                presentRenameAlert(for: document)
            } label: {
                Label(Localization.string(.valuesRenameValue), systemImage: "pencil")
            }

            Divider()

            Button {
                moveSelectedValue(by: -1)
            } label: {
                Label(Localization.string(.rulesMoveUp), systemImage: "arrow.up")
            }
            .disabled(!canMoveSelectedValueUp)

            Button {
                moveSelectedValue(by: 1)
            } label: {
                Label(Localization.string(.rulesMoveDown), systemImage: "arrow.down")
            }
            .disabled(!canMoveSelectedValueDown)

            Divider()

            Button(role: .destructive) {
                selectedName = document.name
                isDeleting = true
            } label: {
                Label(Localization.string(.valuesDeleteValue), systemImage: "trash")
            }
        }
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
                        Button {
                            presentRenameAlert(for: document)
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 11, weight: .medium))
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(HoverIconButtonStyle())
                        .help(Localization.string(.valuesRenameValue))
                        .accessibilityLabel(Localization.string(.valuesRenameValue))
                        .disabled(isOperationInProgress)
                    }
                    Spacer()

                    Button {
                        draft.duplicateValue(name: document.name)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(HoverIconButtonStyle())
                    .help(Localization.string(.valuesDuplicateValue))
                    .accessibilityLabel(Localization.string(.valuesDuplicateValue))
                    .disabled(isOperationInProgress)

                    Button(role: .destructive) {
                        isDeleting = true
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(HoverIconButtonStyle(role: .destructive))
                    .help(Localization.string(.valuesDeleteValue))
                    .accessibilityLabel(Localization.string(.valuesDeleteValue))
                    .disabled(isOperationInProgress)
                }
                .padding(.horizontal, 16)
                .frame(height: 48)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))

                HairlineDivider()

                WhistleCodeEditor(
                    text: editorBinding(for: document),
                    documentID: "values:\(document.name)",
                    language: .value(documentName: document.name),
                    isEditable: !isOperationInProgress,
                    sidebarSearchQuery: filter,
                    valueNames: [],
                    onPositionChange: { editorPosition = $0 }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipped()

                HairlineDivider()

                EditorStatusBar(
                    hint: Localization.string(.valuesReferenceValuesFromRulesWithTheValuesSyntax),
                    matchCount: filter.isEmpty ? nil : editorMatchCount,
                    lineCount: lineCount,
                    position: editorPosition
                )
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "curlybraces.square")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
                Text(Localization.string(.valuesNoValuesYet))
                    .font(.title3.weight(.semibold))
                Text(Localization.string(.valuesRefreshValuesOrCreateANewValueFile))
                    .foregroundStyle(.secondary)
                Button(Localization.string(.rulesRefresh), action: reload)
                    .buttonStyle(.bordered)
                    .disabled(isOperationInProgress)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var filteredDocuments: [WhistleValueDocument] {
        guard !filter.isEmpty else { return draft.valueDocuments }
        return draft.valueDocuments.filter {
            $0.name.localizedCaseInsensitiveContains(filter)
                || $0.value.localizedCaseInsensitiveContains(filter)
        }
    }

    private var editorMatchCount: Int {
        occurrenceCount(of: filter, in: editorValue)
    }

    private var lineCount: Int {
        editorValue.isEmpty ? 1 : editorValue.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    private var isValidCreateName: Bool {
        isValidValueName(createName)
            && !draft.valueDocuments.contains(where: { $0.name == createName })
    }

    private func isValidValueName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed == name
    }

    private func matchCount(in document: WhistleValueDocument) -> Int {
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

    private func createValue() {
        guard !isOperationInProgress else { return }
        draft.createValue(name: createName)
    }

    private func presentRenameAlert(for document: WhistleValueDocument) {
        guard !isOperationInProgress else { return }
        let dialog = WhistleRuleNameAlertController(
            title: Localization.string(.valuesRenameValue),
            placeholder: Localization.string(.valuesValueName),
            initialName: document.name,
            confirmTitle: Localization.string(.rulesRename),
            cancelTitle: Localization.string(.rulesCancel)
        ) { candidate in
            isValidValueName(candidate)
                && candidate != document.name
                && !draft.valueDocuments.contains(where: {
                    $0.name == candidate && $0.name != document.name
                })
        }
        dialog.present(attachedTo: NSApp.keyWindow) { newName in
            guard let newName else { return }
            draft.renameValue(name: document.name, to: newName)
        }
    }

    private func deleteValue() {
        guard let selectedName, !isOperationInProgress else { return }
        draft.deleteValue(name: selectedName)
    }

    private func nextValueName() -> String {
        var index = 1
        while draft.valueDocuments.contains(where: { $0.name == "Values \(index)" }) {
            index += 1
        }
        return "Values \(index)"
    }

    private var selectedValueIndex: Int? {
        guard filter.isEmpty, let selectedName else { return nil }
        return draft.valueDocuments.firstIndex { $0.name == selectedName }
    }

    private var canMoveSelectedValueUp: Bool {
        guard let selectedValueIndex else { return false }
        return selectedValueIndex > 0 && !isOperationInProgress
    }

    private var canMoveSelectedValueDown: Bool {
        guard let selectedValueIndex else { return false }
        return selectedValueIndex < draft.valueDocuments.count - 1 && !isOperationInProgress
    }

    private func moveSelectedValue(by offset: Int) {
        guard let selectedName, let selectedValueIndex else { return }
        let targetIndex = selectedValueIndex + offset
        guard draft.valueDocuments.indices.contains(targetIndex) else { return }
        withAnimation(.easeInOut(duration: 0.14)) {
            draft.moveValue(name: selectedName, over: draft.valueDocuments[targetIndex].name)
        }
    }

    private func valueMoveButton(
        symbol: String,
        title: String,
        enabled: Bool,
        shortcut: KeyEquivalent,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(HoverIconButtonStyle())
        .help(title)
        .accessibilityLabel(title)
        .keyboardShortcut(shortcut, modifiers: [.command, .option])
        .disabled(!enabled)
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
            .accessibilityLabel(document.name)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

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
        .opacity(!enabled && !document.isDefault ? 0.65 : 1.0)
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

private struct ValueListRow: View {
    let document: WhistleValueDocument
    let isSelected: Bool
    let isDraggable: Bool
    let query: String
    let matchCount: Int
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
                            .fill(Color.accentColor.opacity(isSelected ? 0.16 : 0.08))
                        Image(systemName: "curlybraces")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    }
                    .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 3) {
                        highlightedName
                            .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                        Text(Localization.format(
                            .rulesValueLines,
                            Int64(lineCount)
                        ))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isInteractionDisabled)
            .accessibilityLabel(document.name)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            if matchCount > 0 {
                Text("\(matchCount)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.1), in: Capsule())
            }
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

    private var lineCount: Int {
        document.value.isEmpty
            ? 1
            : document.value.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
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
