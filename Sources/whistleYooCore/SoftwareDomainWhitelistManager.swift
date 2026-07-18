import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct SoftwareDomainWhitelistManager: Sendable {
    public static let domains = [
        "alilang-desktop-client.cn-hangzhou.log.aliyuncs.com",
        "s-api.alibaba-inc.com",
        "alilang.alibaba-inc.com",
        "auth-alilang.alibaba-inc.com",
        "mdm-alilang.alibaba-inc.com",
        "***.apple.com",
        "*.mzstatic.com",
        "*.cdn-apple.com",
        "***.apple-cloudkit.com",
        "***.icloud.com",
        "***.icloud-content.com",
        "***.icloud.com.cn",
        "txy.live-play.acgvideo.com",
        "ocs-oneagent-server.alibaba.com",
        "*.jetbrains.com",
        "*.dropbox.com",
        "hubble.netease.com",
        "app.home.netease.com",
        "mdoor.netease.com",
        "mam.netease.com",
        "api.home.netease.com"
    ]

    static let beginMarker = "# ===== whistleYoo software domain whitelist BEGIN ====="
    static let endMarker = "# ===== whistleYoo software domain whitelist END ====="

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func sync(
        baseURL: URL,
        enabled: Bool,
        domains: [String] = SoftwareDomainWhitelistManager.domains
    ) async throws {
        let listURL = baseURL.appendingPathComponent("cgi-bin/rules/list")
        var request = URLRequest(url: listURL, timeoutInterval: 8)
        request.setValue("whistleYoo/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        let state = try JSONDecoder().decode(RulesState.self, from: data)
        let defaultRules = state.defaultRules ?? ""
        let updated = Self.mergingManagedRules(into: defaultRules, enabled: enabled, domains: domains)
        // Default is a built-in WhistleYoo rule set and must never remain
        // disabled, even when compatibility-domain rules are turned off.
        let needsDefaultActivation = state.defaultRulesIsDisabled ?? false
        guard updated != defaultRules || needsDefaultActivation else { return }

        let endpoint = needsDefaultActivation
            ? "cgi-bin/rules/enable-default"
            : "cgi-bin/rules/add"
        try await postDefaultRules(updated, endpoint: endpoint, baseURL: baseURL)
    }

    public static func mergingManagedRules(
        into existing: String,
        enabled: Bool,
        domains: [String] = SoftwareDomainWhitelistManager.domains
    ) -> String {
        let cleaned = removingManagedRules(from: existing)
        guard enabled else { return cleaned }
        let rules = managedRules(domains: domains)
        guard !cleaned.isEmpty else { return rules }
        return rules + "\n\n" + cleaned
    }

    public static func removingManagedRules(from existing: String) -> String {
        guard let begin = existing.range(of: beginMarker),
              let end = existing.range(of: endMarker, range: begin.upperBound..<existing.endIndex) else {
            return existing
        }
        var result = existing
        var removal = begin.lowerBound..<end.upperBound
        while removal.lowerBound > result.startIndex {
            let previous = result.index(before: removal.lowerBound)
            guard result[previous].isNewline else { break }
            removal = previous..<removal.upperBound
        }
        while removal.upperBound < result.endIndex, result[removal.upperBound].isNewline {
            removal = removal.lowerBound..<result.index(after: removal.upperBound)
        }
        result.removeSubrange(removal)
        return result
    }

    public static var managedRules: String {
        managedRules(domains: domains)
    }

    public static func managedRules(domains: [String]) -> String {
        let values = normalizedDomains(domains).joined(separator: " ")
        return """
        \(beginMarker)
        # Keep common desktop software working without HTTPS interception or capture noise.
        disable://intercept \(values)
        enable://hide \(values)
        ignore://*|!enable|!disable \(values)
        \(endMarker)
        """
    }

    public static func normalizedDomains(_ domains: [String]) -> [String] {
        var seen = Set<String>()
        return domains
            .flatMap { $0.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
            .filter { seen.insert($0).inserted }
    }

    private func postDefaultRules(_ value: String, endpoint: String, baseURL: URL) async throws {
        var request = URLRequest(
            url: baseURL.appendingPathComponent(endpoint),
            timeoutInterval: 8
        )
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("whistleYoo/1.0", forHTTPHeaderField: "User-Agent")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "clientId", value: "whistleyoo-native"),
            URLQueryItem(name: "name", value: "Default"),
            URLQueryItem(name: "value", value: value)
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        if let result = try? JSONDecoder().decode(ActionResult.self, from: data), result.ec != 0 {
            throw WhistleYooError.invalidResponse(result.em ?? coreLocalized("Whistle 保存白名单规则失败"))
        }
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? coreLocalized("Whistle 规则接口响应异常")
            throw WhistleYooError.invalidResponse(message)
        }
    }
}

private extension SoftwareDomainWhitelistManager {
    struct RulesState: Decodable {
        let defaultRulesIsDisabled: Bool?
        let defaultRules: String?
    }

    struct ActionResult: Decodable {
        let ec: Int
        let em: String?
    }
}
