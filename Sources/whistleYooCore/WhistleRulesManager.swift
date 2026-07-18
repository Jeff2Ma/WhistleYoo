import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct WhistleRuleDocument: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let value: String
    public let isEnabled: Bool
    public let isDefault: Bool

    public var id: String { name }

    public init(name: String, value: String, isEnabled: Bool, isDefault: Bool = false) {
        self.name = name
        self.value = value
        self.isEnabled = isEnabled
        self.isDefault = isDefault
    }
}

public struct WhistleRulesSnapshot: Codable, Equatable, Sendable {
    public let documents: [WhistleRuleDocument]
    public let allowMultipleChoice: Bool
    public let backRulesFirst: Bool

    public init(
        documents: [WhistleRuleDocument] = [],
        allowMultipleChoice: Bool = true,
        backRulesFirst: Bool = false
    ) {
        self.documents = documents
        self.allowMultipleChoice = allowMultipleChoice
        self.backRulesFirst = backRulesFirst
    }
}

/// Reads and writes the same Rules storage used by Whistle's Web UI.
///
/// The App starts Whistle with its own `-D` and `-S` arguments, so these CGI
/// calls are scoped to that running instance and Whistle remains responsible
/// for its internal on-disk storage format.
public struct WhistleRulesManager: Sendable {
    private static let clientID = "whistleyoo-native-rules"
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func load(baseURL: URL) async throws -> WhistleRulesSnapshot {
        var request = URLRequest(url: endpoint("cgi-bin/rules/list", baseURL: baseURL), timeoutInterval: 8)
        request.setValue("WhistleYoo/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        let result = try JSONDecoder().decode(ListResponse.self, from: data)
        try validate(result: result.result)

        if result.defaultRulesIsDisabled == true {
            try await post(
                "cgi-bin/rules/enable-default",
                form: ["name": "Default", "value": result.defaultRules ?? ""],
                baseURL: baseURL
            )
        }
        if result.allowMultipleChoice != true {
            try await enableMultipleChoice(baseURL: baseURL)
        }

        var documents = [WhistleRuleDocument(
            name: "Default",
            value: result.defaultRules ?? "",
            // WhistleYoo treats the built-in rule set as permanently enabled.
            // Keep that invariant in the model even if an older Whistle state
            // still reports it as disabled.
            isEnabled: true,
            isDefault: true
        )]
        documents.append(contentsOf: (result.list ?? []).map {
            WhistleRuleDocument(
                name: $0.name,
                value: $0.data ?? "",
                isEnabled: $0.selected ?? false
            )
        })
        return WhistleRulesSnapshot(
            documents: documents,
            // WhistleYoo models custom rules as independently enabled rule
            // groups. Keep Whistle's storage in multiple-choice mode so
            // selecting one document never silently unselects another.
            allowMultipleChoice: true,
            backRulesFirst: result.backRulesFirst ?? false
        )
    }

    public func save(
        name: String,
        value: String,
        isEnabled: Bool,
        baseURL: URL
    ) async throws {
        try Self.validateRuleName(name)
        guard name != "Default" else {
            throw WhistleYooError.commandFailed(coreLocalized("默认规则不能修改"))
        }

        try await enableMultipleChoice(baseURL: baseURL)
        try await post(
            "cgi-bin/rules/add",
            form: ["name": name, "value": value],
            baseURL: baseURL
        )
        try await persistEnabled(isEnabled, name: name, value: value, baseURL: baseURL)
    }

    public func setEnabled(
        _ enabled: Bool,
        name: String,
        value: String,
        baseURL: URL
    ) async throws {
        try Self.validateRuleName(name)
        guard name != "Default" else {
            throw WhistleYooError.commandFailed(coreLocalized("默认规则启用状态不能修改"))
        }
        try await enableMultipleChoice(baseURL: baseURL)
        try await persistEnabled(enabled, name: name, value: value, baseURL: baseURL)
    }

    /// Applies all named-rule edits in one explicit save operation.
    ///
    /// Whistle does not expose a transactional Rules endpoint, so this method
    /// computes the minimal set of remove/add/select requests. The built-in
    /// Default document is validated but never written by this API.
    public func applyChanges(
        from original: WhistleRulesSnapshot,
        to updated: WhistleRulesSnapshot,
        baseURL: URL
    ) async throws {
        try Self.validateDraft(original, referenceDefault: nil)
        try Self.validateDraft(updated, referenceDefault: original.documents.first(where: \.isDefault))

        // This must happen before the first select request. Whistle clears its
        // selectedList whenever a file is selected while multiple choice is
        // disabled, which would make the last enabled document win.
        try await enableMultipleChoice(baseURL: baseURL)
        let needsSelectionReconciliation = !original.allowMultipleChoice
            || !updated.allowMultipleChoice

        let originalNamed = Dictionary(uniqueKeysWithValues: original.documents
            .filter { !$0.isDefault }
            .map { ($0.name, $0) })
        let updatedNamed = Dictionary(uniqueKeysWithValues: updated.documents
            .filter { !$0.isDefault }
            .map { ($0.name, $0) })

        for name in originalNamed.keys.sorted() where updatedNamed[name] == nil {
            try await delete(name: name, baseURL: baseURL)
        }

        for document in updated.documents where !document.isDefault {
            let previous = originalNamed[document.name]
            if previous?.value != document.value {
                try await post(
                    "cgi-bin/rules/add",
                    form: ["name": document.name, "value": document.value],
                    baseURL: baseURL
                )
            }
            if previous?.isEnabled != document.isEnabled || needsSelectionReconciliation {
                try await persistEnabled(
                    document.isEnabled,
                    name: document.name,
                    value: document.value,
                    baseURL: baseURL
                )
            }
        }

        try await reconcileOrder(
            original: original.documents.filter { !$0.isDefault }.map(\.name),
            updated: updated.documents.filter { !$0.isDefault }.map(\.name),
            baseURL: baseURL
        )
        if original.backRulesFirst != updated.backRulesFirst {
            try await post(
                "cgi-bin/rules/enable-back-rules-first",
                form: ["backRulesFirst": updated.backRulesFirst ? "1" : "0"],
                baseURL: baseURL
            )
        }
    }

    public func delete(name: String, baseURL: URL) async throws {
        try Self.validateRuleName(name)
        guard name != "Default" else {
            throw WhistleYooError.commandFailed(coreLocalized("默认规则不能删除"))
        }
        try await post("cgi-bin/rules/remove", form: ["name": name], baseURL: baseURL)
    }

    public func rename(name: String, to newName: String, baseURL: URL) async throws {
        try Self.validateRuleName(name)
        try Self.validateRuleName(newName)
        guard name != "Default", newName != "Default" else {
            throw WhistleYooError.commandFailed(coreLocalized("默认规则不能重命名或覆盖"))
        }
        try await post(
            "cgi-bin/rules/rename",
            form: ["name": name, "newName": newName],
            baseURL: baseURL
        )
    }

    public static func validateRuleName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == name, !name.contains("\n"), !name.contains("\r") else {
            throw WhistleYooError.commandFailed(coreLocalized("规则名称不能为空或包含首尾空白"))
        }
    }

    private static func validateDraft(
        _ snapshot: WhistleRulesSnapshot,
        referenceDefault: WhistleRuleDocument?
    ) throws {
        let defaults = snapshot.documents.filter(\.isDefault)
        guard defaults.count == 1,
              let defaultDocument = defaults.first,
              defaultDocument.name == "Default",
              defaultDocument.isEnabled else {
            throw WhistleYooError.commandFailed(coreLocalized("默认规则必须保留且保持启用"))
        }
        if let referenceDefault, defaultDocument.value != referenceDefault.value {
            throw WhistleYooError.commandFailed(coreLocalized("默认规则不能修改"))
        }

        var names = Set<String>()
        for document in snapshot.documents {
            try validateRuleName(document.name)
            guard names.insert(document.name).inserted else {
                throw WhistleYooError.commandFailed(coreLocalized("规则名称不能重复"))
            }
            guard document.isDefault || document.name != "Default" else {
                throw WhistleYooError.commandFailed(coreLocalized("默认规则名称已保留"))
            }
        }
    }

    private func enableMultipleChoice(baseURL: URL) async throws {
        try await post(
            "cgi-bin/rules/allow-multiple-choice",
            form: ["allowMultipleChoice": "1"],
            baseURL: baseURL
        )
    }

    private func persistEnabled(
        _ enabled: Bool,
        name: String,
        value: String,
        baseURL: URL
    ) async throws {
        let path = enabled ? "cgi-bin/rules/select" : "cgi-bin/rules/unselect"
        // Whistle's select/unselect handlers call `rules.add` with body.value,
        // so omitting it would erase the rule.
        try await post(path, form: ["name": name, "value": value], baseURL: baseURL)
    }

    private func reconcileOrder(
        original: [String],
        updated: [String],
        baseURL: URL
    ) async throws {
        let updatedNames = Set(updated)
        var current = original.filter(updatedNames.contains)
        current.append(contentsOf: updated.filter { !current.contains($0) })

        for targetIndex in updated.indices where current[targetIndex] != updated[targetIndex] {
            let name = updated[targetIndex]
            guard let sourceIndex = current.firstIndex(of: name) else { continue }
            let anchor = current[targetIndex]
            try await post(
                "cgi-bin/rules/move-to",
                form: ["from": name, "to": anchor],
                baseURL: baseURL
            )
            current.remove(at: sourceIndex)
            current.insert(name, at: targetIndex)
        }
    }

    private func post(_ path: String, form: [String: String], baseURL: URL) async throws {
        var request = URLRequest(url: endpoint(path, baseURL: baseURL), timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("WhistleYoo/1.0", forHTTPHeaderField: "User-Agent")
        var fields = form
        fields["clientId"] = Self.clientID
        var components = URLComponents()
        components.queryItems = fields.keys.sorted().map {
            URLQueryItem(name: $0, value: fields[$0])
        }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        if !data.isEmpty, let result = try? JSONDecoder().decode(ActionResponse.self, from: data) {
            try validate(result: result)
        }
    }

    private func endpoint(_ path: String, baseURL: URL) -> URL {
        baseURL.appendingPathComponent(path)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? coreLocalized("Whistle 规则接口响应异常")
            throw WhistleYooError.invalidResponse(message)
        }
    }

    private func validate(result: ActionResponse) throws {
        guard result.ec == 0 else {
            throw WhistleYooError.invalidResponse(result.em ?? coreLocalized("Whistle 规则操作失败"))
        }
    }
}

private extension WhistleRulesManager {
    struct ListResponse: Decodable {
        let ec: Int
        let em: String?
        let defaultRulesIsDisabled: Bool?
        let defaultRules: String?
        let allowMultipleChoice: Bool?
        let backRulesFirst: Bool?
        let list: [ListItem]?

        var result: ActionResponse { ActionResponse(ec: ec, em: em) }
    }

    struct ListItem: Decodable {
        let name: String
        let data: String?
        let selected: Bool?
    }

    struct ActionResponse: Decodable {
        let ec: Int
        let em: String?
    }
}
