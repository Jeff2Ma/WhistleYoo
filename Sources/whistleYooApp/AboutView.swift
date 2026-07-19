import AppKit
import SwiftUI
#if canImport(whistleYooCore)
import whistleYooCore
#endif

struct AboutView: View {
    private static let repositoryURL = URL(string: "https://github.com/Jeff2Ma/WhistleYoo")!
    private static let issuesURL = URL(string: "https://github.com/Jeff2Ma/WhistleYoo/issues")!

    private var displayVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "v\(version ?? "0.0.3")"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header
                Divider()
                projectSection
                Divider()
                updateSection
            }
            .padding(30)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                Text("WhistleYoo")
                    .font(.title2.weight(.semibold))
                Text(Localization.string(.aboutANativeMacosControllerForWhistle))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var projectSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle(Localization.string(.aboutProjectInformation), detail: Localization.string(.aboutViewTheSourceCodeOrContactTheAuthorOnGithub))

            GroupBox {
                VStack(spacing: 0) {
                    informationRow(title: Localization.string(.aboutCurrentVersion), value: displayVersion)
                    Divider()
                    linkRow(
                        title: Localization.string(.aboutOfficialProject),
                        detail: "github.com/Jeff2Ma/WhistleYoo",
                        symbol: "link",
                        destination: Self.repositoryURL
                    )
                    Divider()
                    linkRow(
                        title: Localization.string(.aboutContactTheAuthor),
                        detail: Localization.string(.aboutReportAnIssueOrSuggestionInGithubIssues),
                        symbol: "bubble.left.and.bubble.right",
                        destination: Self.issuesURL
                    )
                }
                .padding(8)
            }
        }
    }

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle(Localization.string(.aboutSoftwareUpdate), detail: Localization.string(.aboutCheckForAndInstallWhistleyooUpdatesWithSparkle))

            HStack(spacing: 14) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Localization.string(.aboutStayUpToDate))
                        .fontWeight(.medium)
                    Text(Localization.string(.aboutCheckWhetherANewVersionIsAvailable))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(Localization.string(.aboutCheckForUpdates)) {
                    UpdateController.shared.checkForUpdates()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func informationRow(title: String, value: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(title)
            Spacer()
            Text(value)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
    }

    private func linkRow(
        title: String,
        detail: String,
        symbol: String,
        destination: URL
    ) -> some View {
        Link(destination: destination) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 10)
    }
}
