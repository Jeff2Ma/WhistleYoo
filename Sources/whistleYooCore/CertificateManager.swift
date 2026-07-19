import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CertificateRecord: Codable, Equatable, Sendable {
    public let sha256: String
    public let installedAt: Date

    public init(sha256: String, installedAt: Date = Date()) {
        self.sha256 = sha256
        self.installedAt = installedAt
    }
}

public struct CertificateHealth: Equatable, Sendable {
    public let isInstalled: Bool
    public let isTrusted: Bool
    public let matchesCurrentInstance: Bool?

    public init(
        isInstalled: Bool = false,
        isTrusted: Bool = false,
        matchesCurrentInstance: Bool? = nil
    ) {
        self.isInstalled = isInstalled
        self.isTrusted = isTrusted
        self.matchesCurrentInstance = matchesCurrentInstance
    }

    public var isReady: Bool {
        isInstalled && isTrusted && matchesCurrentInstance == true
    }
}

public protocol RootCertificatePreparing: Sendable {
    func prepareRootCertificate(in directory: URL) throws
}

public final class CertificateManager: RootCertificatePreparing, @unchecked Sendable {
    private let runner: ProcessRunning
    private let session: URLSession
    private let fileManager: FileManager
    private let computerName: () -> String
    private let now: () -> Date
    private let timeZone: TimeZone
    private let securityURL = URL(fileURLWithPath: "/usr/bin/security")
    private let opensslURL = URL(fileURLWithPath: "/usr/bin/openssl")
    private let recordURL: URL
    private let certificateURL: URL
    private let loginKeychainURL: URL

    public init(
        runner: ProcessRunning = FoundationProcessRunner(),
        session: URLSession = .shared,
        supportDirectory: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        computerName: @escaping () -> String = {
            Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        },
        now: @escaping () -> Date = { Date() },
        timeZone: TimeZone = .current
    ) {
        let support = supportDirectory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.devework.whistleyoo", isDirectory: true)
        self.runner = runner
        self.session = session
        self.fileManager = fileManager
        self.computerName = computerName
        self.now = now
        self.timeZone = timeZone
        recordURL = support.appendingPathComponent("certificate.json")
        certificateURL = support.appendingPathComponent("rootCA.crt")
        loginKeychainURL = homeDirectory.appendingPathComponent("Library/Keychains/login.keychain-db")
    }

    public func prepareRootCertificate(in directory: URL) throws {
        let keyURL = directory.appendingPathComponent("root.key")
        let rootCertificateURL = directory.appendingPathComponent("root.crt")
        let nameFormatMarkerURL = directory
            .appendingPathComponent(".whistleyoo-certificate-name-v2")
        if fileManager.fileExists(atPath: keyURL.path),
           fileManager.fileExists(atPath: rootCertificateURL.path),
           fileManager.fileExists(atPath: nameFormatMarkerURL.path) {
            return
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileManager.removeItem(at: keyURL)
        try? fileManager.removeItem(at: rootCertificateURL)
        try? fileManager.removeItem(at: nameFormatMarkerURL)

        let temporarySuffix = UUID().uuidString
        let temporaryKeyURL = directory.appendingPathComponent("root-\(temporarySuffix).key")
        let temporaryCertificateURL = directory.appendingPathComponent("root-\(temporarySuffix).crt")
        defer {
            try? fileManager.removeItem(at: temporaryKeyURL)
            try? fileManager.removeItem(at: temporaryCertificateURL)
        }

        let certificateName = Self.rootCertificateName(
            for: now(),
            computerName: computerName(),
            timeZone: timeZone
        )
        let escapedCertificateName = Self.opensslSubjectValue(certificateName)
        let result = try runner.run(
            executableURL: opensslURL,
            arguments: [
                "req", "-x509", "-newkey", "rsa:2048", "-sha256",
                "-days", "3650", "-nodes", "-utf8",
                "-subj", "/CN=\(escapedCertificateName)/O=whistleYoo/OU=whistleYoo",
                "-addext", "basicConstraints=critical,CA:TRUE",
                "-addext", "keyUsage=critical,keyCertSign,cRLSign,digitalSignature",
                "-addext", "subjectKeyIdentifier=hash",
                "-keyout", temporaryKeyURL.path,
                "-out", temporaryCertificateURL.path
            ],
            environment: nil,
            timeout: 30
        )
        guard result.exitCode == 0 else {
            throw WhistleYooError.commandFailed(result.standardError + result.standardOutput)
        }
        guard fileManager.fileExists(atPath: temporaryKeyURL.path),
              fileManager.fileExists(atPath: temporaryCertificateURL.path) else {
            throw WhistleYooError.commandFailed(Localization.string(.coreOpensslDidNotGenerateAWhistleRootCertificate))
        }

        try fileManager.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: temporaryKeyURL.path
        )
        try fileManager.moveItem(at: temporaryKeyURL, to: keyURL)
        try fileManager.moveItem(at: temporaryCertificateURL, to: rootCertificateURL)
        try Data("2".utf8).write(to: nameFormatMarkerURL, options: .atomic)
    }

    public static func rootCertificateName(
        for date: Date,
        computerName: String = Host.current().localizedName
            ?? ProcessInfo.processInfo.hostName,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMddHHmmss"
        let timestamp = formatter.string(from: date)
        let prefix = "WhistleYoo."
        let suffix = ".\(timestamp)"
        let maximumComputerNameLength = max(
            1,
            64 - prefix.utf8.count - suffix.utf8.count
        )
        var normalizedName = computerName
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedName.isEmpty {
            normalizedName = "Mac"
        }
        while normalizedName.utf8.count > maximumComputerNameLength {
            normalizedName.removeLast()
        }
        return "\(prefix)\(normalizedName)\(suffix)"
    }

    private static func opensslSubjectValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "/", with: "\\/")
    }

    public func fetchRootCertificate(baseURL: URL) async throws -> Data {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("cgi-bin/rootca"), resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "type", value: "crt")]
        var request = URLRequest(url: components.url!, timeoutInterval: 5)
        request.setValue("whistleYoo/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              Self.certificateDER(from: data) != nil else {
            throw WhistleYooError.certificateNotFound
        }
        return data
    }

    @discardableResult
    public func install(certificateData: Data) throws -> CertificateRecord {
        guard let der = Self.certificateDER(from: certificateData) else {
            throw WhistleYooError.invalidResponse(Localization.string(.coreTheRootCertificateFormatIsInvalid))
        }
        let fingerprint = Self.sha256(der)
        try fileManager.createDirectory(
            at: certificateURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try certificateData.write(to: certificateURL, options: .atomic)
        let result = try runner.run(
            executableURL: securityURL,
            arguments: [
                "add-trusted-cert", "-r", "trustRoot",
                "-k", loginKeychainURL.path, certificateURL.path
            ],
            environment: nil,
            timeout: 30
        )
        guard result.exitCode == 0 else {
            let message = (result.standardError + result.standardOutput)
            if message.localizedCaseInsensitiveContains("cancel") { throw WhistleYooError.userCancelled }
            throw WhistleYooError.commandFailed(message)
        }
        let record = CertificateRecord(sha256: fingerprint)
        try JSONEncoder().encode(record).write(to: recordURL, options: .atomic)
        return record
    }

    public func installedRecord() throws -> CertificateRecord? {
        guard fileManager.fileExists(atPath: recordURL.path) else { return nil }
        return try JSONDecoder().decode(CertificateRecord.self, from: Data(contentsOf: recordURL))
    }

    public func isInstalled() -> Bool {
        let record: CertificateRecord
        do {
            guard let value = try installedRecord() else { return false }
            record = value
        } catch {
            return false
        }
        return keychainContainsCertificate(sha256: record.sha256)
    }

    public func isInstalled(certificateData: Data) -> Bool {
        guard let der = Self.certificateDER(from: certificateData) else { return false }
        return keychainContainsCertificate(sha256: Self.sha256(der))
    }

    public func health(certificateData: Data? = nil) -> CertificateHealth {
        let record = try? installedRecord()
        let recordedCertificatePresent = record.map {
            keychainContainsCertificate(sha256: $0.sha256)
        } ?? false

        var currentCertificatePresent = false
        var matchesCurrentInstance: Bool?
        if let certificateData {
            if let der = Self.certificateDER(from: certificateData) {
                currentCertificatePresent = keychainContainsCertificate(sha256: Self.sha256(der))
                matchesCurrentInstance = currentCertificatePresent
            } else {
                matchesCurrentInstance = false
            }
        }

        let installed = recordedCertificatePresent || currentCertificatePresent
        let certificateToVerify: Data?
        if currentCertificatePresent {
            certificateToVerify = certificateData
        } else if recordedCertificatePresent,
                  let stored = try? Data(contentsOf: certificateURL),
                  let storedDER = Self.certificateDER(from: stored),
                  Self.sha256(storedDER) == record?.sha256 {
            certificateToVerify = stored
        } else {
            certificateToVerify = nil
        }

        return CertificateHealth(
            isInstalled: installed,
            isTrusted: certificateToVerify.map(certificateIsTrusted) ?? false,
            matchesCurrentInstance: matchesCurrentInstance
        )
    }

    private func keychainContainsCertificate(sha256: String) -> Bool {
        guard let result = try? runner.run(
            executableURL: securityURL,
            arguments: ["find-certificate", "-a", "-Z", loginKeychainURL.path],
            environment: nil,
            timeout: 15
        ), result.exitCode == 0 else { return false }
        return result.standardOutput.uppercased().contains(sha256.uppercased())
    }

    private func certificateIsTrusted(_ data: Data) -> Bool {
        guard Self.certificateDER(from: data) != nil else { return false }
        let temporaryURL = fileManager.temporaryDirectory
            .appendingPathComponent("whistleyoo-trust-\(UUID().uuidString).crt")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        do {
            try data.write(to: temporaryURL, options: .atomic)
            let result = try runner.run(
                executableURL: securityURL,
                arguments: [
                    "verify-cert", "-q", "-c", temporaryURL.path,
                    "-p", "basic", "-l", "-L", "-k", loginKeychainURL.path
                ],
                environment: nil,
                timeout: 15
            )
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    public func removeInstalledCertificate() throws {
        guard let record = try installedRecord() else { return }
        let result = try runner.run(
            executableURL: securityURL,
            arguments: ["delete-certificate", "-Z", record.sha256, loginKeychainURL.path],
            environment: nil,
            timeout: 20
        )
        guard result.exitCode == 0 else {
            throw WhistleYooError.commandFailed(result.standardError + result.standardOutput)
        }
        try? fileManager.removeItem(at: recordURL)
        try? fileManager.removeItem(at: certificateURL)
    }

    public static func certificateDER(from data: Data) -> Data? {
        if let text = String(data: data, encoding: .utf8), text.contains("BEGIN CERTIFICATE") {
            let payload = text
                .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
                .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
                .components(separatedBy: .whitespacesAndNewlines)
                .joined()
            return Data(base64Encoded: payload)
        }
        return data.isEmpty ? nil : data
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }
}
