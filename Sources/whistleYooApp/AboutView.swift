import AppKit
import SwiftUI

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
                Text("Whistle 的原生 macOS 控制端")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var projectSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("项目信息", detail: "查看项目源码，或通过 GitHub 联系作者。")

            GroupBox {
                VStack(spacing: 0) {
                    informationRow(title: "当前版本", value: displayVersion)
                    Divider()
                    linkRow(
                        title: "官方项目",
                        detail: "github.com/Jeff2Ma/WhistleYoo",
                        symbol: "link",
                        destination: Self.repositoryURL
                    )
                    Divider()
                    linkRow(
                        title: "联系作者",
                        detail: "在 GitHub Issues 中反馈问题或建议",
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
            sectionTitle("软件更新", detail: "通过 Sparkle 检查并安装 WhistleYoo 更新。")

            HStack(spacing: 14) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text("保持最新版本")
                        .fontWeight(.medium)
                    Text("检查是否有可用的新版本。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("检查更新") {
                    UpdateController.shared.checkForUpdates()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func sectionTitle(_ title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func informationRow(title: LocalizedStringKey, value: String) -> some View {
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
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
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
