import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import whistleYooCore

final class WhistleRulesManagerTests: XCTestCase {
    override func tearDown() {
        RulesURLProtocol.handler = nil
        super.tearDown()
    }

    func testLoadReturnsDefaultAndNamedRules() async throws {
        var capturedRequests = [URLRequest]()
        RulesURLProtocol.handler = { request in
            capturedRequests.append(request)
            if request.httpMethod == "POST" {
                return (200, #"{"ec":0}"#.data(using: .utf8)!)
            }
            let body = """
            {
              "ec": 0,
              "defaultRulesIsDisabled": true,
              "defaultRules": "example.com host://127.0.0.1",
              "allowMultipleChoice": true,
              "backRulesFirst": true,
              "list": [
                {"name": "API mocks", "data": "api.example.com file://mock.json", "selected": true},
                {"name": "Disabled", "data": "x.test host://1.1.1.1", "selected": false}
              ]
            }
            """.data(using: .utf8)!
            return (200, body)
        }

        let snapshot = try await makeManager().load(baseURL: URL(string: "http://127.0.0.1:8900/")!)

        XCTAssertEqual(snapshot.documents.map(\.name), ["Default", "API mocks", "Disabled"])
        XCTAssertEqual(snapshot.documents.map(\.isEnabled), [true, true, false])
        XCTAssertTrue(snapshot.documents[0].isDefault)
        XCTAssertTrue(snapshot.allowMultipleChoice)
        XCTAssertTrue(snapshot.backRulesFirst)
        XCTAssertEqual(capturedRequests.map { $0.url?.path }, [
            "/cgi-bin/rules/list",
            "/cgi-bin/rules/enable-default"
        ])
        XCTAssertEqual(
            Self.formFields(capturedRequests[1])["value"],
            "example.com host://127.0.0.1"
        )
    }

    func testSetEnabledSendsCurrentValueSoWhistleDoesNotEraseNamedRule() async throws {
        var captured = [(String, [String: String])]()
        RulesURLProtocol.handler = { request in
            captured.append((request.url!.path, Self.formFields(request)))
            return (200, #"{"ec":0}"#.data(using: .utf8)!)
        }
        let manager = makeManager()
        let baseURL = URL(string: "http://127.0.0.1:8900/")!

        try await manager.setEnabled(
            false,
            name: "API mocks",
            value: "api.example file://mock.json",
            baseURL: baseURL
        )

        XCTAssertEqual(captured.map(\.0), [
            "/cgi-bin/rules/allow-multiple-choice",
            "/cgi-bin/rules/unselect"
        ])
        XCTAssertEqual(captured[0].1["allowMultipleChoice"], "1")
        XCTAssertEqual(captured[1].1["name"], "API mocks")
        XCTAssertEqual(captured[1].1["value"], "api.example file://mock.json")
    }

    func testDefaultRuleCannotBeSavedOrDisabled() async throws {
        var requestCount = 0
        RulesURLProtocol.handler = { _ in
            requestCount += 1
            return (200, #"{"ec":0}"#.data(using: .utf8)!)
        }
        let manager = makeManager()
        let baseURL = URL(string: "http://127.0.0.1:8900/")!

        do {
            try await manager.save(name: "Default", value: "changed", isEnabled: true, baseURL: baseURL)
            XCTFail("Expected Default save to fail")
        } catch {}
        do {
            try await manager.setEnabled(false, name: "Default", value: "unchanged", baseURL: baseURL)
            XCTFail("Expected Default disable to fail")
        } catch {}

        XCTAssertEqual(requestCount, 0)
    }

    func testApplyChangesCommitsNamedRuleDraftAndGlobalFlags() async throws {
        var captured = [(String, [String: String])]()
        RulesURLProtocol.handler = { request in
            captured.append((request.url!.path, Self.formFields(request)))
            return (200, #"{"ec":0}"#.data(using: .utf8)!)
        }
        let defaultRule = WhistleRuleDocument(
            name: "Default",
            value: "built-in",
            isEnabled: true,
            isDefault: true
        )
        let original = WhistleRulesSnapshot(
            documents: [
                defaultRule,
                WhistleRuleDocument(name: "Edited", value: "old", isEnabled: true),
                WhistleRuleDocument(name: "Removed", value: "remove", isEnabled: false)
            ]
        )
        let updated = WhistleRulesSnapshot(
            documents: [
                defaultRule,
                WhistleRuleDocument(name: "Edited", value: "new", isEnabled: false),
                WhistleRuleDocument(name: "Created", value: "create", isEnabled: true)
            ],
            allowMultipleChoice: true,
            backRulesFirst: true
        )

        try await makeManager().applyChanges(
            from: original,
            to: updated,
            baseURL: URL(string: "http://127.0.0.1:8900/")!
        )

        XCTAssertEqual(captured.map(\.0), [
            "/cgi-bin/rules/allow-multiple-choice",
            "/cgi-bin/rules/remove",
            "/cgi-bin/rules/add",
            "/cgi-bin/rules/unselect",
            "/cgi-bin/rules/add",
            "/cgi-bin/rules/select",
            "/cgi-bin/rules/enable-back-rules-first"
        ])
        XCTAssertEqual(captured[0].1["allowMultipleChoice"], "1")
        XCTAssertEqual(captured[1].1["name"], "Removed")
        XCTAssertEqual(captured[2].1["value"], "new")
        XCTAssertEqual(captured[3].1["name"], "Edited")
        XCTAssertEqual(captured[4].1["value"], "create")
        XCTAssertEqual(captured[5].1["name"], "Created")
        XCTAssertEqual(captured[6].1["backRulesFirst"], "1")
    }

    func testApplyChangesPersistsCustomRuleOrder() async throws {
        var captured = [(String, [String: String])]()
        RulesURLProtocol.handler = { request in
            captured.append((request.url!.path, Self.formFields(request)))
            return (200, #"{"ec":0}"#.data(using: .utf8)!)
        }
        let defaultRule = WhistleRuleDocument(
            name: "Default",
            value: "built-in",
            isEnabled: true,
            isDefault: true
        )
        let first = WhistleRuleDocument(name: "First", value: "first", isEnabled: true)
        let second = WhistleRuleDocument(name: "Second", value: "second", isEnabled: true)
        let third = WhistleRuleDocument(name: "Third", value: "third", isEnabled: false)

        try await makeManager().applyChanges(
            from: WhistleRulesSnapshot(documents: [defaultRule, first, second, third]),
            to: WhistleRulesSnapshot(documents: [defaultRule, third, first, second]),
            baseURL: URL(string: "http://127.0.0.1:8900/")!
        )

        XCTAssertEqual(captured.map(\.0), [
            "/cgi-bin/rules/allow-multiple-choice",
            "/cgi-bin/rules/move-to"
        ])
        XCTAssertEqual(captured[1].1["from"], "Third")
        XCTAssertEqual(captured[1].1["to"], "First")
    }

    func testApplyChangesRejectsDefaultMutationBeforeSendingRequests() async throws {
        var requestCount = 0
        RulesURLProtocol.handler = { _ in
            requestCount += 1
            return (200, #"{"ec":0}"#.data(using: .utf8)!)
        }
        let originalDefault = WhistleRuleDocument(
            name: "Default",
            value: "original",
            isEnabled: true,
            isDefault: true
        )
        let changedDefault = WhistleRuleDocument(
            name: "Default",
            value: "changed",
            isEnabled: true,
            isDefault: true
        )

        do {
            try await makeManager().applyChanges(
                from: WhistleRulesSnapshot(documents: [originalDefault]),
                to: WhistleRulesSnapshot(documents: [changedDefault]),
                baseURL: URL(string: "http://127.0.0.1:8900/")!
            )
            XCTFail("Expected Default mutation to fail")
        } catch {}

        XCTAssertEqual(requestCount, 0)
    }

    func testSaveNamedRuleWritesContentThenSelectsWithoutLosingIt() async throws {
        var captured = [(String, [String: String])]()
        RulesURLProtocol.handler = { request in
            captured.append((request.url!.path, Self.formFields(request)))
            return (200, #"{"ec":0}"#.data(using: .utf8)!)
        }

        try await makeManager().save(
            name: "Local map",
            value: "www.example.com file:///tmp/index.html",
            isEnabled: true,
            baseURL: URL(string: "http://127.0.0.1:8900/")!
        )

        XCTAssertEqual(captured.map(\.0), [
            "/cgi-bin/rules/allow-multiple-choice",
            "/cgi-bin/rules/add",
            "/cgi-bin/rules/select"
        ])
        XCTAssertEqual(captured[0].1["allowMultipleChoice"], "1")
        XCTAssertEqual(captured[1].1["value"], "www.example.com file:///tmp/index.html")
        XCTAssertEqual(captured[2].1["value"], "www.example.com file:///tmp/index.html")
        XCTAssertEqual(captured[2].1["clientId"], "whistleyoo-native-rules")
    }

    func testLoadMigratesWhistleStorageToMultipleChoiceMode() async throws {
        var captured = [(String, [String: String])]()
        RulesURLProtocol.handler = { request in
            captured.append((request.url!.path, Self.formFields(request)))
            if request.httpMethod == "POST" {
                return (200, #"{"ec":0}"#.data(using: .utf8)!)
            }
            return (200, """
            {
              "ec": 0,
              "defaultRulesIsDisabled": false,
              "defaultRules": "",
              "allowMultipleChoice": false,
              "backRulesFirst": false,
              "list": [
                {"name": "One", "data": "one.test host://1.1.1.1", "selected": true},
                {"name": "Two", "data": "two.test host://2.2.2.2", "selected": false}
              ]
            }
            """.data(using: .utf8)!)
        }

        let snapshot = try await makeManager().load(
            baseURL: URL(string: "http://127.0.0.1:8900/")!
        )

        XCTAssertTrue(snapshot.allowMultipleChoice)
        XCTAssertEqual(snapshot.documents.map(\.isEnabled), [true, true, false])
        XCTAssertEqual(captured.map(\.0), [
            "/cgi-bin/rules/list",
            "/cgi-bin/rules/allow-multiple-choice"
        ])
        XCTAssertEqual(captured[1].1["allowMultipleChoice"], "1")
    }

    func testApplyChangesEnablesMultipleChoiceBeforeRestoringEnabledRules() async throws {
        var captured = [(String, [String: String])]()
        RulesURLProtocol.handler = { request in
            captured.append((request.url!.path, Self.formFields(request)))
            return (200, #"{"ec":0}"#.data(using: .utf8)!)
        }
        let defaultRule = WhistleRuleDocument(
            name: "Default",
            value: "",
            isEnabled: true,
            isDefault: true
        )
        let rules = [
            defaultRule,
            WhistleRuleDocument(name: "One", value: "one", isEnabled: true),
            WhistleRuleDocument(name: "Two", value: "two", isEnabled: true)
        ]

        try await makeManager().applyChanges(
            from: WhistleRulesSnapshot(documents: rules, allowMultipleChoice: false),
            to: WhistleRulesSnapshot(documents: rules, allowMultipleChoice: false),
            baseURL: URL(string: "http://127.0.0.1:8900/")!
        )

        XCTAssertEqual(captured.map(\.0), [
            "/cgi-bin/rules/allow-multiple-choice",
            "/cgi-bin/rules/select",
            "/cgi-bin/rules/select"
        ])
        XCTAssertEqual(captured[1].1["name"], "One")
        XCTAssertEqual(captured[2].1["name"], "Two")
    }

    func testLoadValuesReturnsWhistleValueDocumentsInStorageOrder() async throws {
        var capturedRequests = [URLRequest]()
        RulesURLProtocol.handler = { request in
            capturedRequests.append(request)
            return (200, """
            {
              "ec": 0,
              "list": [
                {"name": "Tokens", "data": "{\\"apiToken\\":\\"test\\"}"},
                {"name": "Template", "data": "hello {{name}}"}
              ]
            }
            """.data(using: .utf8)!)
        }

        let snapshot = try await makeValuesManager().load(
            baseURL: URL(string: "http://127.0.0.1:8900/")!
        )

        XCTAssertEqual(snapshot.documents.map(\.name), ["Tokens", "Template"])
        XCTAssertEqual(snapshot.documents[0].value, #"{"apiToken":"test"}"#)
        XCTAssertEqual(
            capturedRequests.map { $0.url?.path },
            ["/cgi-bin/values/list"]
        )
    }

    func testApplyValueChangesWritesContentAndPersistsOrder() async throws {
        var captured = [(String, [String: String])]()
        RulesURLProtocol.handler = { request in
            captured.append((request.url!.path, Self.formFields(request)))
            return (200, #"{"ec":0}"#.data(using: .utf8)!)
        }
        let original = WhistleValuesSnapshot(documents: [
            WhistleValueDocument(name: "First", value: "one"),
            WhistleValueDocument(name: "Second", value: "two")
        ])
        let updated = WhistleValuesSnapshot(documents: [
            WhistleValueDocument(name: "Second", value: "two edited"),
            WhistleValueDocument(name: "Created", value: "three"),
            WhistleValueDocument(name: "First", value: "one")
        ])

        try await makeValuesManager().applyChanges(
            from: original,
            to: updated,
            baseURL: URL(string: "http://127.0.0.1:8900/")!
        )

        XCTAssertEqual(captured.map(\.0), [
            "/cgi-bin/values/add",
            "/cgi-bin/values/add",
            "/cgi-bin/values/move-to",
            "/cgi-bin/values/move-to"
        ])
        XCTAssertEqual(captured[0].1["name"], "Second")
        XCTAssertEqual(captured[0].1["value"], "two edited")
        XCTAssertEqual(captured[1].1["name"], "Created")
        XCTAssertEqual(captured[2].1["from"], "Second")
        XCTAssertEqual(captured[2].1["to"], "First")
        XCTAssertEqual(captured[3].1["from"], "Created")
        XCTAssertEqual(captured[3].1["to"], "First")
        XCTAssertTrue(captured.allSatisfy {
            $0.1["clientId"] == "whistleyoo-native-values"
        })
    }

    func testApplyValueChangesRemovesDeletedDocuments() async throws {
        var captured = [(String, [String: String])]()
        RulesURLProtocol.handler = { request in
            captured.append((request.url!.path, Self.formFields(request)))
            return (200, #"{"ec":0}"#.data(using: .utf8)!)
        }

        try await makeValuesManager().applyChanges(
            from: WhistleValuesSnapshot(documents: [
                WhistleValueDocument(name: "Keep", value: "one"),
                WhistleValueDocument(name: "Delete", value: "two")
            ]),
            to: WhistleValuesSnapshot(documents: [
                WhistleValueDocument(name: "Keep", value: "one")
            ]),
            baseURL: URL(string: "http://127.0.0.1:8900/")!
        )

        XCTAssertEqual(captured.map(\.0), ["/cgi-bin/values/remove"])
        XCTAssertEqual(captured[0].1["name"], "Delete")
    }

    func testNativeDefaultRuleEditingPreservesManagedWhitelistBlock() {
        let userRules = "api.example.com file://mock.json\nwww.example.com host://127.0.0.1"
        let persisted = SoftwareDomainWhitelistManager.mergingManagedRules(
            into: userRules,
            enabled: true,
            domains: ["*.apple.com", "updates.example.com"]
        )

        let valueShownInNativeEditor = SoftwareDomainWhitelistManager.removingManagedRules(from: persisted)
        let savedAgain = SoftwareDomainWhitelistManager.mergingManagedRules(
            into: valueShownInNativeEditor,
            enabled: true,
            domains: ["*.apple.com", "updates.example.com"]
        )

        XCTAssertEqual(valueShownInNativeEditor, userRules)
        XCTAssertEqual(savedAgain, persisted)
        XCTAssertTrue(savedAgain.contains(SoftwareDomainWhitelistManager.beginMarker))
        XCTAssertTrue(savedAgain.contains("disable://intercept *.apple.com updates.example.com"))
    }

    private func makeManager() -> WhistleRulesManager {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RulesURLProtocol.self]
        return WhistleRulesManager(session: URLSession(configuration: configuration))
    }

    private func makeValuesManager() -> WhistleValuesManager {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RulesURLProtocol.self]
        return WhistleValuesManager(session: URLSession(configuration: configuration))
    }

    private static func formFields(_ request: URLRequest) -> [String: String] {
        guard let data = request.httpBody ?? readBodyStream(request.httpBodyStream),
              let query = String(data: data, encoding: .utf8) else { return [:] }
        var components = URLComponents()
        components.percentEncodedQuery = query
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })
    }

    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class RulesURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                throw WhistleYooError.commandFailed("Missing test handler")
            }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
