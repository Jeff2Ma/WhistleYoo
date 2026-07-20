import AppKit
import SwiftUI
import UniformTypeIdentifiers
#if canImport(whistleYooCore)
import whistleYooCore
#endif

private struct HairlineRoundedBorderModifier: ViewModifier {
    let color: Color
    let cornerRadius: CGFloat
    let style: RoundedCornerStyle

    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: style)
                .strokeBorder(color, lineWidth: 1 / max(displayScale, 1))
        }
    }
}

extension View {
    func hairlineRoundedBorder(
        _ color: Color,
        cornerRadius: CGFloat,
        style: RoundedCornerStyle = .circular
    ) -> some View {
        modifier(HairlineRoundedBorderModifier(
            color: color,
            cornerRadius: cornerRadius,
            style: style
        ))
    }
}

struct StatusPopoverView: View {
    @ObservedObject var state: AppStateController
    @State private var optimisticSystemProxyEnabled: Bool?
    @State private var isIconAnimating = false
    let openConsole: () -> Void
    let openSettings: () -> Void
    let openOnboarding: () -> Void
    let openMobileSetup: () -> Void
    let quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 11) {
                    ZStack {
                        Circle()
                            .fill(engineStatusColor.opacity(0.14))
                            .frame(width: 42, height: 42)
                        Image(systemName: statusSymbol)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(engineStatusColor)
                            .scaleEffect(state.isEngineRunning && isIconAnimating ? 1.08 : 0.94)
                            .opacity(state.isEngineRunning && isIconAnimating ? 1.0 : 0.8)
                    }
                    .onAppear {
                        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                            isIconAnimating = true
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Localization.string(.mobileProxyEngine))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Circle()
                                .fill(engineStatusColor)
                                .frame(width: 7, height: 7)
                            Text(state.engineStatusTitle)
                                .font(.headline)
                        }
                        Text(state.engineDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }

                if !state.needsOnboarding && !isEnvironmentUnavailable {
                    enginePrimaryButton
                }
            }

            Divider()

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(Localization.string(.settingsGlobalSystemProxy))
                            .fontWeight(.medium)
                        Text(systemProxyDisplayTitle)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(systemProxyColor)
                    }
                    Text(state.proxyDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Toggle(Localization.string(.settingsGlobalSystemProxy), isOn: systemProxyToggleBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!state.isEngineRunning)
                .allowsHitTesting(!state.isTransitioning && optimisticSystemProxyEnabled == nil)
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 8) {
                addressRow(
                    title: Localization.string(.settingsThisMac),
                    detail: nil,
                    value: "127.0.0.1:\(state.settings.engine.proxyPort)"
                )
                if let endpoint = state.preferredLocalEndpoint {
                    addressRow(
                        title: endpoint.displayName,
                        detail: endpoint.isDefaultRoute ? Localization.string(.mobileRecommended) : endpoint.interfaceName,
                        value: "\(endpoint.address):\(state.settings.engine.proxyPort)"
                    )
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))

            if state.needsOnboarding || isEnvironmentUnavailable {
                Button(action: openOnboarding) {
                    Label(Localization.string(.onboardingRunSetupAssistant), systemImage: "wrench.and.screwdriver")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PopoverButtonStyle(emphasis: .prominent))
            } else {
                HStack(spacing: 8) {
                    Button(action: openConsole) {
                        Label(Localization.string(.consoleWhistleConsole), systemImage: "rectangle.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PopoverButtonStyle(emphasis: .standard))

                    Button(action: openMobileSetup) {
                        Label(Localization.string(.mobileMobileProxy), systemImage: "iphone")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PopoverButtonStyle(emphasis: .standard))
                }
                .controlSize(.large)
                .disabled(state.isTransitioning)
            }

            Divider()

            HStack {
                Button(action: openSettings) {
                    Label(Localization.string(.settingsMoreSettings), systemImage: "gearshape")
                }
                .buttonStyle(PopoverButtonStyle(emphasis: .quiet))
                Spacer()
                Button(action: quit) {
                    Label(Localization.string(.settingsShutDownAndQuit), systemImage: "power")
                }
                .buttonStyle(PopoverButtonStyle(emphasis: .quiet))
            }
            .font(.callout.weight(.medium))
        }
        .padding(16)
        .frame(width: 350)
        .background(.ultraThinMaterial)
    }

    private var isEnvironmentUnavailable: Bool {
        if case .unavailable = state.environmentStatus { return true }
        return false
    }

    private var engineStatusColor: Color {
        switch state.engineState {
        case .running: return .green
        case .starting, .stopping: return .orange
        case .stopped: return isEnvironmentUnavailable ? .red : .secondary
        case .failed: return .red
        }
    }

    private var systemProxyColor: Color {
        switch state.systemProxyStatus {
        case .enabledByThisApp: return .green
        case .partiallyEnabled: return .orange
        case .disabled, .configuredByOther: return .secondary
        case .unavailable: return .red
        }
    }

    private var isGlobalSystemProxyEnabled: Bool {
        if let optimisticSystemProxyEnabled {
            return optimisticSystemProxyEnabled
        }
        switch state.systemProxyStatus {
        case .enabledByThisApp, .partiallyEnabled: return true
        case .disabled, .configuredByOther, .unavailable: return false
        }
    }

    private var systemProxyToggleBinding: Binding<Bool> {
        Binding(
            get: { isGlobalSystemProxyEnabled },
            set: { enabled in
                guard state.isEngineRunning,
                      !state.isTransitioning,
                      optimisticSystemProxyEnabled == nil else { return }
                optimisticSystemProxyEnabled = enabled
                Task {
                    _ = await state.setSystemProxyEnabled(enabled)
                    optimisticSystemProxyEnabled = nil
                }
            }
        )
    }

    private var systemProxyDisplayTitle: String {
        switch state.systemProxyStatus {
        case .enabledByThisApp, .partiallyEnabled, .unavailable:
            return state.systemProxyTitle
        case .disabled, .configuredByOther:
            return Localization.string(.rulesNotEnabled)
        }
    }

    private var statusSymbol: String {
        switch state.engineState {
        case .running: return "dot.radiowaves.left.and.right"
        case .starting, .stopping: return "arrow.triangle.2.circlepath"
        case .stopped: return isEnvironmentUnavailable ? "exclamationmark.triangle.fill" : "network.slash"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func addressRow(title: String, detail: String?, value: String) -> some View {
        HStack {
            HStack(spacing: 4) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
        }
        .font(.caption)
    }

    private func engineButtonLabel(
        title: String,
        symbol: String,
        loadingTint: Color
    ) -> some View {
        HStack(spacing: 7) {
            if isEngineOperationTransitioning {
                ProgressView()
                    .controlSize(.small)
                    .tint(loadingTint)
            } else {
                Image(systemName: symbol)
            }
            Text(title)
        }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 32)
    }

    private var isEngineOperationTransitioning: Bool {
        state.isPerformingEngineOperation
            || state.engineState == .starting
            || state.engineState == .stopping
    }

    @ViewBuilder
    private var enginePrimaryButton: some View {
        switch state.engineState {
        case .running, .stopping:
            Button {
                Task { await state.stopEngine() }
            } label: {
                engineButtonLabel(
                    title: Localization.string(.settingsStopProxyEngine),
                    symbol: "stop.circle",
                    loadingTint: .primary
                )
            }
            .buttonStyle(PopoverButtonStyle(emphasis: .standard))
            .controlSize(.large)
            .disabled(state.isTransitioning || state.isChangingSystemProxy)
        case .starting, .stopped, .failed:
            Button {
                Task { await state.startEngine() }
            } label: {
                engineButtonLabel(
                    title: Localization.string(.mobileStartProxyEngine),
                    symbol: "play.circle",
                    loadingTint: .white
                )
            }
            .buttonStyle(PopoverButtonStyle(emphasis: .prominent))
            .controlSize(.large)
            .disabled(state.isTransitioning)
        }
    }

}

private struct PopoverButtonStyle: ButtonStyle {
    enum Emphasis {
        case prominent
        case outlined
        case standard
        case quiet
        case compact
    }

    let emphasis: Emphasis

    func makeBody(configuration: Configuration) -> some View {
        PopoverButtonBody(configuration: configuration, emphasis: emphasis)
    }

    private struct PopoverButtonBody: View {
        let configuration: Configuration
        let emphasis: Emphasis
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(foregroundColor)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .background(backgroundColor, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    if isStandard || isOutlined {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(borderColor, lineWidth: 1)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.08), value: isHovering)
                .animation(.easeOut(duration: 0.06), value: configuration.isPressed)
        }

        private var foregroundColor: Color {
            if isProminent { return .white }
            if isOutlined { return .accentColor }
            return .primary
        }

        private var backgroundColor: Color {
            if isProminent {
                if configuration.isPressed { return Color.accentColor.opacity(0.72) }
                if isHovering { return Color.accentColor.opacity(0.88) }
                return Color.accentColor
            }
            if isOutlined {
                if configuration.isPressed { return Color.accentColor.opacity(0.18) }
                if isHovering { return Color.accentColor.opacity(0.10) }
                return .clear
            }
            if configuration.isPressed { return Color.primary.opacity(0.16) }
            if isHovering { return Color.primary.opacity(0.09) }
            return isStandard ? Color.primary.opacity(0.055) : .clear
        }

        private var borderColor: Color {
            isOutlined
                ? Color.accentColor.opacity(isHovering ? 0.7 : 0.5)
                : Color.primary.opacity(0.14)
        }

        private var horizontalPadding: CGFloat {
            switch emphasis {
            case .prominent, .outlined, .standard: return 10
            case .quiet: return 8
            case .compact: return 5
            }
        }

        private var verticalPadding: CGFloat {
            switch emphasis {
            case .prominent, .outlined, .standard: return 2
            case .quiet: return 5
            case .compact: return 3
            }
        }

        private var cornerRadius: CGFloat {
            switch emphasis {
            case .compact: return 5
            case .prominent, .outlined, .standard, .quiet: return 7
            }
        }

        private var isProminent: Bool {
            if case .prominent = emphasis { return true }
            return false
        }

        private var isOutlined: Bool {
            if case .outlined = emphasis { return true }
            return false
        }

        private var isStandard: Bool {
            if case .standard = emphasis { return true }
            return false
        }
    }
}

enum MainWorkspaceTab: Hashable {
    case console
    case plugins
    case mobile
    case rules
    case settings
    case about
}

@MainActor
final class MainWorkspaceSelection: ObservableObject {
    @Published var selected: MainWorkspaceTab

    init(selected: MainWorkspaceTab) {
        self.selected = selected
    }
}

struct MainWorkspaceView: View {
    @ObservedObject var state: AppStateController
    @ObservedObject var consoleSession: WhistleConsoleSession
    @ObservedObject var selection: MainWorkspaceSelection
    @ObservedObject var mobileModel: MobileSetupViewModel
    @ObservedObject var rulesDraft: RuleConfigurationDraft
    let exportCertificate: () -> Void
    let runOnboarding: () -> Void
    @State private var pendingTabSelection: MainWorkspaceTab?
    @State private var isDiscardingRulesForTabChange = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 10) {
                sidebarButton(
                    title: Localization.string(.consoleWhistleConsole),
                    symbol: "rectangle.on.rectangle",
                    tab: .console
                )
                sidebarButton(
                    title: Localization.string(.pluginsWhistlePlugins),
                    symbol: "puzzlepiece.extension",
                    tab: .plugins
                )
                sidebarButton(
                    title: Localization.string(.rulesConfiguration),
                    symbol: "doc.text",
                    tab: .rules
                )
                sidebarButton(
                    title: Localization.string(.mobileMobileProxy),
                    symbol: "iphone.and.arrow.forward",
                    tab: .mobile
                )
                sidebarButton(
                    title: Localization.string(.rulesSettings),
                    symbol: "gearshape",
                    tab: .settings
                )
                sidebarButton(
                    title: Localization.string(.settingsAbout),
                    symbol: "info.circle",
                    tab: .about
                )
                Spacer()
                sidebarStatusSummary
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .frame(width: 170, alignment: .top)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(minWidth: 900, minHeight: 640)
        .alert(Localization.string(.settingsDiscardUnsavedChanges), isPresented: $isDiscardingRulesForTabChange) {
            Button(Localization.string(.rulesKeepEditing), role: .cancel) {
                pendingTabSelection = nil
            }
            Button(Localization.string(.rulesDiscardChanges), role: .destructive) {
                rulesDraft.discardChanges()
                if let pendingTabSelection {
                    selection.selected = pendingTabSelection
                }
                self.pendingTabSelection = nil
            }
        } message: {
            Text(Localization.string(.settingsSwitchingPagesWillDiscardTheUnsavedChangesInTheCurrentRule))
        }
    }

    private var sidebarStatusSummary: some View {
        Button {
            requestTabSelection(.console)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(sidebarEngineStatusColor)
                        .frame(width: 7, height: 7)
                    Text(Localization.string(.mobileProxyEngine))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text(state.engineStatusTitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                HStack(spacing: 6) {
                    Circle()
                        .fill(sidebarSystemProxyStatusColor)
                        .frame(width: 7, height: 7)
                    Text(Localization.string(.settingsGlobalSystemProxy))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text(state.systemProxyTitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
            .font(.system(size: 10.5, weight: .medium))
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarStatusButtonStyle())
        .help(Localization.string(.settingsOpenWhistleConsole))
    }

    private var sidebarEngineStatusColor: Color {
        switch state.engineState {
        case .running: return .green
        case .starting, .stopping: return .orange
        case .stopped: return .secondary
        case .failed: return .red
        }
    }

    private var sidebarSystemProxyStatusColor: Color {
        switch state.systemProxyStatus {
        case .enabledByThisApp: return .green
        case .partiallyEnabled: return .orange
        case .disabled, .configuredByOther: return .secondary
        case .unavailable: return .red
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        switch selection.selected {
        case .console:
            whistlePage(workspace: .network)
        case .plugins:
            whistlePage(workspace: .plugins)
        case .mobile:
            MobileSetupView(model: mobileModel, isActive: true)
        case .rules:
            RuleConfigurationView(state: state, draft: rulesDraft)
        case .settings:
            SettingsView(
                state: state,
                exportCertificate: exportCertificate,
                runOnboarding: runOnboarding
            )
        case .about:
            AboutView()
        }
    }

    private func sidebarButton(
        title: String,
        symbol: String,
        tab: MainWorkspaceTab
    ) -> some View {
        Button {
            requestTabSelection(tab)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 20)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(selection.selected == tab ? Color.accentColor : Color.primary)
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(
                selection.selected == tab ? Color.accentColor.opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .hairlineRoundedBorder(
                selection.selected == tab ? Color.accentColor.opacity(0.18) : Color.clear,
                cornerRadius: 9,
                style: .continuous
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private func requestTabSelection(_ tab: MainWorkspaceTab) {
        guard tab != selection.selected else { return }
        if selection.selected == .rules, state.isLoadingRules || state.isSavingRules {
            selection.selected = tab
            return
        }
        guard selection.selected == .rules, rulesDraft.isDirty else {
            selection.selected = tab
            return
        }
        pendingTabSelection = tab
        isDiscardingRulesForTabChange = true
    }

    @ViewBuilder
    private func whistlePage(workspace: WhistleConsoleSession.Workspace) -> some View {
        if state.isEngineRunning, let url = state.uiURL {
            WhistleWorkspaceView(
                session: consoleSession,
                baseURL: url,
                workspace: workspace
            )
        } else {
            VStack(spacing: 14) {
                Image(systemName: "rectangle.slash")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text(Localization.string(.settingsProxyEngineIsNotRunning))
                    .font(.title3.weight(.semibold))
                Text(Localization.string(workspace.engineUnavailableMessageKey))
                    .foregroundStyle(.secondary)
                Button(Localization.string(.mobileStartProxyEngine)) {
                    Task { await state.startEngine() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct SidebarStatusButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SidebarStatusButtonBody(configuration: configuration)
    }

    private struct SidebarStatusButtonBody: View {
        let configuration: Configuration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .background(
                    backgroundColor,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .hairlineRoundedBorder(
                    Color.primary.opacity(isHovering ? 0.13 : 0.08),
                    cornerRadius: 9,
                    style: .continuous
                )
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.08), value: isHovering)
                .animation(.easeOut(duration: 0.06), value: configuration.isPressed)
        }

        private var backgroundColor: Color {
            if configuration.isPressed { return Color.primary.opacity(0.13) }
            if isHovering { return Color.primary.opacity(0.08) }
            return Color.primary.opacity(0.04)
        }
    }
}

struct OnboardingView: View {
    private enum Step: Int, CaseIterable {
        case environment
        case ports
        case certificate
        case finish
    }

    @ObservedObject var state: AppStateController
    let completion: () -> Void
    @State private var step: Step = .environment
    @State private var proxyPort: String
    @State private var uiPort: String
    @State private var skippedCertificate: Bool
    @State private var enableSystemProxy = false
    @State private var isWorking = false
    @State private var portStatus: String?
    @State private var portStatusIsSuccess = false

    init(state: AppStateController, completion: @escaping () -> Void) {
        self.state = state
        self.completion = completion
        _proxyPort = State(initialValue: String(state.settings.engine.proxyPort))
        _uiPort = State(initialValue: String(state.settings.engine.uiPort))
        _skippedCertificate = State(initialValue: state.settings.certificateStepSkipped)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch step {
                case .environment: environmentStep
                case .ports: portsStep
                case .certificate: certificateStep
                case .finish: finishStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 620, height: 470)
        .task {
            await state.refreshEnvironment()
            await state.refreshCertificateStatus()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Image(systemName: "network.badge.shield.half.filled")
                    .font(.system(size: 27))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Localization.string(.onboardingWhistleyooSetupAssistant))
                        .font(.title2.weight(.semibold))
                    Text(Localization.string(.onboardingCheckTheEnvironmentPortsAndHttpsCertificate))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { item in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.18))
                        .frame(height: 4)
                }
            }
        }
        .padding(22)
    }

    private var environmentStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepTitle(Localization.string(.onboardingCheckNodeJsAndWhistle), detail: Localization.string(.onboardingWhistleyooUsesTheLocallyInstalledNodeJsAndGlobalWhistlePackage))

            statusCard(
                symbol: environmentReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                color: environmentReady ? .green : .orange,
                title: environmentReady ? Localization.string(.settingsRuntimeEnvironmentIsReady) : Localization.string(.settingsRuntimeEnvironmentNeedsAttention),
                detail: state.environmentDescription
            )

            HStack {
                Button(Localization.string(.onboardingDownloadNodeJs)) {
                    if let url = URL(string: "https://nodejs.org/en/download") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button(Localization.string(.settingsCopyWhistleInstallCommand)) {
                    copy("npm install -g whistle")
                }
                Spacer()
                Button {
                    Task { await state.refreshEnvironment() }
                } label: {
                    Label(Localization.string(.settingsCheckAgain), systemImage: "arrow.clockwise")
                }
            }
            Text(Localization.string(.onboardingWeRecommendManagingNodeJsWithNvmFnmVoltaOrHomebrewAfterInsta))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(28)
    }

    private var portsStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepTitle(Localization.string(.onboardingCheckProxyPorts), detail: Localization.string(.onboardingTheProxyPortAcceptsMacAndMobileConnectionsAndExposesTheWhistl))

            VStack(spacing: 12) {
                portRow(Localization.string(.onboardingProxyPort), text: $proxyPort, detail: Localization.string(.settingsListenOn0000))
                portRow(Localization.string(.onboardingWebUiPort), text: $uiPort, detail: Localization.string(.settingsListenOn127001Only))
            }
            .padding(16)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))

            if let portStatus {
                Label(portStatus, systemImage: portStatusIsSuccess ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(portStatusIsSuccess ? .green : .red)
            }
            Spacer()
        }
        .padding(28)
    }

    private var certificateStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepTitle(Localization.string(.mobileInstallHttpsRootCertificate), detail: Localization.string(.onboardingInstallTheCertificateToInspectHttpsRequestsItIsStoredInTheCu))

            statusCard(
                symbol: state.certificateInstalled ? "checkmark.seal.fill" : "lock.trianglebadge.exclamationmark",
                color: state.certificateInstalled ? .green : .orange,
                title: state.certificateInstalled ? Localization.string(.onboardingRootCertificateInstalled) : Localization.string(.onboardingRootCertificateNotInstalled),
                detail: state.certificateInstalled
                    ? Localization.string(.onboardingAMatchingFingerprintWasFoundInTheLoginKeychain)
                    : Localization.string(.settingsYouCanSkipThisForNowButHttpsCaptureWillNotWork)
            )

            HStack {
                Button(Localization.string(
                    state.certificateInstalled
                        ? .onboardingReinstallCertificate
                        : .onboardingInstallCertificate
                )) {
                    isWorking = true
                    Task {
                        _ = await state.installCertificate()
                        isWorking = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking)

                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Toggle(Localization.string(.onboardingSkipCertificateInstallationForNow), isOn: $skippedCertificate)
                .disabled(state.certificateInstalled)
            Spacer()
        }
        .padding(28)
    }

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepTitle(Localization.string(.onboardingSetupComplete), detail: Localization.string(.settingsWhistleIsReadyYouCanControlTheProxyFromTheMenuBarAtAnyTime))
            statusCard(
                symbol: "checkmark.circle.fill",
                color: .green,
                title: Localization.string(.settingsProxyEngineIsRunning),
                detail: Localization.format(.onboardingLocalEndpoint127001Value, String(state.settings.engine.proxyPort))
            )
            Toggle(isOn: $enableSystemProxy) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(Localization.string(.settingsEnableGlobalSystemProxy))
                        .fontWeight(.medium)
                    Text(Localization.string(.settingsWhenDisabledWhistleContinuesListeningForMobileDevicesAndManuall))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            Spacer()
        }
        .padding(28)
    }

    private var footer: some View {
        HStack {
            if step.rawValue > 0 {
                Button(Localization.string(.onboardingBack)) {
                    step = Step(rawValue: step.rawValue - 1) ?? .environment
                }
                .disabled(isWorking)
            }
            Spacer()

            switch step {
            case .environment:
                Button(Localization.string(.rulesContinue)) { step = .ports }
                    .buttonStyle(.borderedProminent)
                    .disabled(!environmentReady)
            case .ports:
                Button(Localization.string(.settingsCheckAndStart)) { applyPortsAndStart() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking)
            case .certificate:
                Button(Localization.string(.rulesContinue)) { step = .finish }
                    .buttonStyle(.borderedProminent)
                    .disabled(!state.certificateInstalled && !skippedCertificate)
            case .finish:
                Button(Localization.string(.rulesDone)) {
                    isWorking = true
                    Task {
                        await state.completeOnboarding(
                            enableSystemProxy: enableSystemProxy,
                            skippedCertificate: skippedCertificate && !state.certificateInstalled
                        )
                        isWorking = false
                        completion()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var environmentReady: Bool {
        if case .ready = state.environmentStatus { return true }
        return false
    }

    private func applyPortsAndStart() {
        guard let proxy = Int(proxyPort), let ui = Int(uiPort) else {
            portStatusIsSuccess = false
            portStatus = Localization.string(.onboardingEnterValidNumericPorts)
            return
        }
        isWorking = true
        portStatus = nil
        Task {
            let saved = await state.updatePorts(proxyPort: proxy, uiPort: ui)
            guard saved else {
                portStatusIsSuccess = false
                portStatus = state.lastErrorMessage ?? Localization.string(.onboardingPortIsUnavailable)
                isWorking = false
                return
            }
            let conflicts = state.portConflicts()
            guard conflicts.isEmpty else {
                portStatusIsSuccess = false
                portStatus = Localization.format(.onboardingPortsInUseValue, conflicts.map(String.init).joined(separator: ", "))
                isWorking = false
                return
            }
            guard await state.startEngine() else {
                portStatusIsSuccess = false
                portStatus = state.lastErrorMessage ?? Localization.string(.mobileFailedToStartTheProxyEngine)
                isWorking = false
                return
            }
            portStatusIsSuccess = true
            portStatus = Localization.string(.onboardingPortsAreAvailableAndTheProxyEngineHasStarted)
            isWorking = false
            step = .certificate
        }
    }

    private func stepTitle(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(detail)
                .foregroundStyle(.secondary)
        }
    }

    private func statusCard(symbol: String, color: Color, title: String, detail: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 27))
                .foregroundStyle(color)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private func portRow(_ title: String, text: Binding<String>, detail: String) -> some View {
        HStack {
            Text(title)
                .frame(width: 110, alignment: .leading)
            TextField(Localization.string(.mobilePort), text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

struct SettingsView: View {
    private enum FocusField: Hashable {
        case proxyPort
        case uiPort
        case whitelistDomains
    }

    @ObservedObject var state: AppStateController
    let exportCertificate: () -> Void
    let runOnboarding: () -> Void
    @FocusState private var focusedField: FocusField?
    @State private var proxyPort: String
    @State private var uiPort: String
    @State private var savingPorts = false
    @State private var portStatus: String?
    @State private var portStatusIsSuccess = false
    @State private var showNetworkServices = false
    @State private var showWhitelistDomains = false
    @State private var whitelistDomainsText: String
    @State private var savingWhitelistDomains = false
    @State private var updatingCompatibilityRules = false
    @State private var whitelistSaveFeedback: String?
    @State private var whitelistSaveFeedbackID: UUID?
    @State private var isHandlingConfigurationFile = false
    @State private var configurationFileStatus: String?
    @State private var configurationFileStatusIsSuccess = false

    init(
        state: AppStateController,
        exportCertificate: @escaping () -> Void,
        runOnboarding: @escaping () -> Void
    ) {
        self.state = state
        self.exportCertificate = exportCertificate
        self.runOnboarding = runOnboarding
        _proxyPort = State(initialValue: String(state.settings.engine.proxyPort))
        _uiPort = State(initialValue: String(state.settings.engine.uiPort))
        _whitelistDomainsText = State(
            initialValue: state.settings.softwareDomainWhitelistDomains.joined(separator: "\n")
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                configurationFileSection
                Divider()
                generalSection
                Divider()
                proxySection
                Divider()
                certificateSection
                Divider()
                environmentSection
            }
            .padding(30)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .defaultFocus($focusedField, nil)
        .onAppear {
            focusedField = nil
        }
        .task {
            await state.refreshNetworkServices()
            await state.refreshCertificateStatus()
        }
    }

    private var configurationFileSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle(
                Localization.string(.settingsWhistleyooConfigurationFile),
                detail: Localization.string(.settingsKeepAllSettingsAndRuleConfigurationInOneFileWithCloudDriveSy)
            )
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "doc.badge.gearshape")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(state.usesCustomConfigurationFileLocation ? Localization.string(.settingsCustomSaveLocation) : Localization.string(.settingsDefaultSaveLocation))
                                .fontWeight(.medium)
                            Text(state.configurationFileURL.path)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }

                    Text(Localization.string(.settingsWithACustomLocationTheAppReadsThisFileAtLaunchAndAtomically))
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    if let configurationFileStatus {
                        Label(
                            configurationFileStatus,
                            systemImage: configurationFileStatusIsSuccess
                                ? "checkmark.circle.fill"
                                : "exclamationmark.triangle.fill"
                        )
                        .font(.callout)
                        .foregroundStyle(configurationFileStatusIsSuccess ? Color.green : Color.red)
                    }

                    HStack {
                        Button(Localization.string(.settingsImportConfiguration), action: importConfiguration)
                        Button(Localization.string(.settingsExportConfiguration), action: exportConfiguration)
                        Button(Localization.string(.settingsChooseCustomSaveLocation), action: chooseConfigurationFileLocation)
                        if state.usesCustomConfigurationFileLocation {
                            Button(Localization.string(.settingsRestoreDefaultLocation), action: restoreDefaultConfigurationFileLocation)
                        }
                        Spacer()
                        if isHandlingConfigurationFile {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .padding(8)
            }
        }
        .disabled(isHandlingConfigurationFile || state.isTransitioning)
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionTitle(Localization.string(.settingsGeneral), detail: Localization.string(.settingsControlAppLaunchDockAndMenuBarBehavior))
            Toggle(Localization.string(.settingsLaunchWhistleyooAtLogin), isOn: Binding(
                get: { state.launchAtLoginEnabled },
                set: { state.setLaunchAtLogin($0) }
            ))
            Toggle(Localization.string(.settingsShowWhistleyooInTheDock), isOn: Binding(
                get: { state.showDockIcon },
                set: { state.setShowDockIcon($0) }
            ))
            Divider()
            Toggle(isOn: Binding(
                get: { state.settings.softwareDomainWhitelistEnabled },
                set: { enabled in
                    guard !isCompatibilityOperationInProgress else { return }
                    updatingCompatibilityRules = true
                    whitelistSaveFeedback = nil
                    Task {
                        await state.setSoftwareDomainWhitelistEnabled(enabled)
                        updatingCompatibilityRules = false
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Localization.string(.settingsCompatibilityDomainFiltering))
                        .fontWeight(.medium)
                    Text(Localization.string(.onboardingSkipHttpsDecryptionForAppleIcloudJetbrainsAndOtherServicesAnd))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(isCompatibilityOperationInProgress)

            DisclosureGroup(
                Localization.format(.settingsEditBuiltInDomainsValue, state.settings.softwareDomainWhitelistDomains.count),
                isExpanded: $showWhitelistDomains
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $whitelistDomainsText)
                        .focused($focusedField, equals: .whitelistDomains)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 150)
                        .padding(4)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                        .disabled(isCompatibilityOperationInProgress)
                    Text(Localization.string(.settingsEnterOneDomainPerLineAndWildcardFormsAreSupportedSavingImmedi))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button(Localization.string(.settingsRestoreDefaults)) {
                            whitelistDomainsText = SoftwareDomainWhitelistManager.domains.joined(separator: "\n")
                        }
                        .disabled(isCompatibilityOperationInProgress)
                        Spacer()
                        if isCompatibilityOperationInProgress {
                            ProgressView().controlSize(.small)
                        } else if let whitelistSaveFeedback {
                            Label(whitelistSaveFeedback, systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                        Button(Localization.string(.settingsSaveDomains)) {
                            savingWhitelistDomains = true
                            whitelistSaveFeedback = nil
                            let domains = whitelistDomainsText.components(separatedBy: .newlines)
                            Task {
                                let saved = await state.updateSoftwareDomainWhitelistDomains(domains)
                                if saved {
                                    whitelistDomainsText = state.settings.softwareDomainWhitelistDomains
                                        .joined(separator: "\n")
                                    showWhitelistSaveFeedback()
                                }
                                savingWhitelistDomains = false
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isCompatibilityOperationInProgress)
                    }
                }
                .padding(.top, 6)
            }
            Text(Localization.string(.settingsWhenTheAppQuitsItRestoresTheSystemProxySettingsChangedByWhis))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var proxySection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle(Localization.string(.onboardingProxyAndPorts), detail: Localization.string(.onboardingConfigureProxyListeningPortsAndTheNetworkServicesThatUseTheSy))

            GroupBox(Localization.string(.mobilePort)) {
                VStack(spacing: 12) {
                    settingsPortRow(Localization.string(.onboardingProxyPort), text: $proxyPort, focus: .proxyPort)
                    settingsPortRow(Localization.string(.onboardingWebUiPort), text: $uiPort, focus: .uiPort)
                    if portsAreDirty, parsedPorts == nil {
                        Label(Localization.string(.onboardingEnterTwoDifferentValidPorts165535), systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if let portStatus {
                        Label(
                            portStatus,
                            systemImage: portStatusIsSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .font(.callout)
                        .foregroundStyle(portStatusIsSuccess ? Color.green : Color.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack {
                        Text(Localization.string(
                            state.isEngineRunning
                                ? .settingsApplyingTheseChangesWillRestartTheProxyEngine
                                : .settingsTheProxyEngineIsNotRunning
                        ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if savingPorts { ProgressView().controlSize(.small) }
                        Button(Localization.string(
                            state.isEngineRunning ? .settingsApplyAndRestart : .rulesApply
                        )) { applyPorts() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canApplyPorts)
                    }
                }
                .padding(8)
            }

            GroupBox {
                DisclosureGroup(
                    Localization.format(.settingsNetworkServicesUsingTheSystemProxyValueSelected, selectedNetworkServiceCount),
                    isExpanded: $showNetworkServices
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        if state.networkServices.isEmpty {
                            Text(Localization.string(.settingsNoAvailableNetworkServicesDetected))
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(state.networkServices) { service in
                                Toggle(service.name, isOn: networkServiceBinding(service.name))
                                    .disabled(isNetworkServiceSelectionDisabled)
                            }
                        }
                        if state.isChangingSystemProxy {
                            Text(Localization.string(.settingsTheSystemProxyIsChangingPleaseWait))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if isSystemProxyActiveOrPartial {
                            Text(Localization.string(.settingsDisableSystemProxyBeforeChangingNetworkServicesHelp))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 8)
                }
                .padding(8)
            }
        }
    }

    private var certificateSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionTitle(Localization.string(.mobileHttpsRootCertificate), detail: Localization.string(.onboardingTheCertificateIsGeneratedByTheCurrentDedicatedWhistleInstance))
            HStack(spacing: 12) {
                Image(systemName: state.certificateHealth.isReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(state.certificateHealth.isReady ? .green : .orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Localization.string(
                        state.certificateHealth.isReady
                            ? .settingsHttpsCaptureIsReady
                            : .onboardingHttpsRootCertificateNeedsAttention
                    ))
                        .fontWeight(.medium)
                    certificateHealthRow(
                        title: state.certificateHealth.isInstalled ? Localization.string(.onboardingRootCertificateInstalled) : Localization.string(.settingsRootCertificateNotInstalled),
                        isHealthy: state.certificateHealth.isInstalled
                    )
                    certificateHealthRow(
                        title: state.certificateHealth.isTrusted ? Localization.string(.onboardingRootCertificateTrusted) : Localization.string(.onboardingRootCertificateNotTrusted),
                        isHealthy: state.certificateHealth.isTrusted
                    )
                    switch state.certificateHealth.matchesCurrentInstance {
                    case .some(let matchesCurrentInstance):
                        certificateHealthRow(
                            title: matchesCurrentInstance
                                ? Localization.string(.onboardingCertificateMatchesTheCurrentWhistleInstance)
                                : Localization.string(.onboardingCertificateDoesNotMatchTheCurrentWhistleInstance),
                            isHealthy: matchesCurrentInstance
                        )
                    case .none:
                        Text(Localization.string(.onboardingStartTheProxyEngineToVerifyTheInstanceCertificate))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                if state.certificateInstalled {
                    certificateInstallButton
                        .buttonStyle(.bordered)
                } else {
                    certificateInstallButton
                        .buttonStyle(.borderedProminent)
                }
                Button(Localization.string(.onboardingExportCertificate), action: exportCertificate)
                    .disabled(!state.isEngineRunning)
                Button(Localization.string(.settingsCheckAgain)) {
                    Task { await state.refreshCertificateStatus() }
                }
            }
            Text(Localization.string(.onboardingTheMobileProxyPageAlsoProvidesAQrCodeForDownloadingTheCertif))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var certificateInstallButton: some View {
        Button(certificateInstallButtonTitle) {
            Task { _ = await state.installCertificate() }
        }
    }

    private var certificateInstallButtonTitle: String {
        let health = state.certificateHealth
        if !health.isInstalled { return Localization.string(.onboardingInstallCertificateAction) }
        if !health.isTrusted { return Localization.string(.onboardingTrustCertificateAgain) }
        if health.matchesCurrentInstance == false { return Localization.string(.onboardingUpdateCertificate) }
        if health.isReady { return Localization.string(.settingsReinstallCertificateAction) }
        return Localization.string(.onboardingInstallOrUpdateCertificate)
    }

    private func certificateHealthRow(title: String, isHealthy: Bool) -> some View {
        Label(title, systemImage: isHealthy ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .font(.caption)
            .foregroundStyle(isHealthy ? Color.green : Color.orange)
    }

    private var environmentSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle(Localization.string(.settingsRuntimeEnvironment), detail: Localization.string(.settingsCheckTheFinderLaunchEnvironmentAndCommonNvmFnmVoltaAndHomebre))
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label(state.environmentDescription, systemImage: environmentReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(environmentReady ? .green : .orange)
                    if case .ready(let info) = state.environmentStatus {
                        pathRow("Node", info.nodeURL.path)
                        pathRow("Whistle", info.whistleURL.path)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            HStack {
                Button(Localization.string(.settingsCheckAgain)) {
                    Task { await state.refreshEnvironment() }
                }
                Button(Localization.string(.onboardingRunSetupAssistantAgain), action: runOnboarding)
            }
        }
    }

    private var environmentReady: Bool {
        if case .ready = state.environmentStatus { return true }
        return false
    }

    private var portsAreDirty: Bool {
        proxyPort != String(state.settings.engine.proxyPort) ||
            uiPort != String(state.settings.engine.uiPort)
    }

    private var parsedPorts: (proxy: Int, ui: Int)? {
        guard let proxy = Int(proxyPort), let ui = Int(uiPort),
              (1...65535).contains(proxy), (1...65535).contains(ui), proxy != ui else {
            return nil
        }
        return (proxy, ui)
    }

    private var canApplyPorts: Bool {
        portsAreDirty && parsedPorts != nil && !savingPorts && !state.isTransitioning
    }

    private var selectedNetworkServiceCount: Int {
        state.selectedNetworkServiceNames.count
    }

    private var isNetworkServiceSelectionDisabled: Bool {
        state.isTransitioning || isSystemProxyActiveOrPartial
    }

    private var isCompatibilityOperationInProgress: Bool {
        savingWhitelistDomains || updatingCompatibilityRules
    }

    private var isSystemProxyActiveOrPartial: Bool {
        state.systemProxyStatus.indicatesAppProxyIntent
    }

    private var legacyConfigurationContentType: UTType {
        UTType(filenameExtension: "whistleyoo", conformingTo: .json) ?? .data
    }

    private func importConfiguration() {
        let panel = NSOpenPanel()
        panel.title = Localization.string(.settingsImportWhistleyooConfiguration)
        panel.prompt = Localization.string(.settingsImport)
        panel.allowedContentTypes = [.json, legacyConfigurationContentType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = state.configurationFileURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }

        beginConfigurationFileOperation()
        Task {
            let imported = await state.importConfiguration(from: url)
            if imported {
                proxyPort = String(state.settings.engine.proxyPort)
                uiPort = String(state.settings.engine.uiPort)
                whitelistDomainsText = state.settings.softwareDomainWhitelistDomains
                    .joined(separator: "\n")
                finishConfigurationFileOperation(
                    message: Localization.string(.settingsConfigurationImportedAndApplied),
                    succeeded: true
                )
            } else {
                finishConfigurationFileOperation(
                    message: state.lastErrorMessage ?? Localization.string(.settingsConfigurationImportFailed),
                    succeeded: false
                )
            }
        }
    }

    private func exportConfiguration() {
        let panel = configurationSavePanel(
            title: Localization.string(.settingsExportWhistleyooConfiguration),
            prompt: Localization.string(.settingsExport)
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }

        beginConfigurationFileOperation()
        Task {
            let exported = await state.exportConfiguration(to: url)
            finishConfigurationFileOperation(
                message: exported
                    ? Localization.string(.settingsConfigurationExported)
                    : (state.lastErrorMessage ?? Localization.string(.settingsConfigurationExportFailed)),
                succeeded: exported
            )
        }
    }

    private func chooseConfigurationFileLocation() {
        let panel = configurationSavePanel(
            title: Localization.string(.settingsChooseWhistleyooConfigurationSaveLocation),
            prompt: Localization.string(.settingsUseThisLocation)
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }

        beginConfigurationFileOperation()
        Task {
            let changed = await state.useConfigurationFile(at: url)
            finishConfigurationFileOperation(
                message: changed
                    ? Localization.string(.settingsConfigurationSaveLocationUpdated)
                    : (state.lastErrorMessage ?? Localization.string(.settingsUnableToUpdateTheConfigurationSaveLocation)),
                succeeded: changed
            )
        }
    }

    private func restoreDefaultConfigurationFileLocation() {
        beginConfigurationFileOperation()
        Task {
            let restored = await state.restoreDefaultConfigurationFileLocation()
            finishConfigurationFileOperation(
                message: restored
                    ? Localization.string(.settingsDefaultConfigurationSaveLocationRestored)
                    : (state.lastErrorMessage ?? Localization.string(.settingsUnableToRestoreTheDefaultConfigurationSaveLocation)),
                succeeded: restored
            )
        }
    }

    private func configurationSavePanel(title: String, prompt: String) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.title = title
        panel.prompt = prompt
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.directoryURL = state.configurationFileURL.deletingLastPathComponent()
        panel.nameFieldStringValue = "WhistleYoo.json"
        return panel
    }

    private func beginConfigurationFileOperation() {
        isHandlingConfigurationFile = true
        configurationFileStatus = nil
    }

    private func finishConfigurationFileOperation(message: String, succeeded: Bool) {
        configurationFileStatus = message
        configurationFileStatusIsSuccess = succeeded
        isHandlingConfigurationFile = false
    }

    private func applyPorts() {
        guard let ports = parsedPorts else {
            portStatus = Localization.string(.onboardingEnterTwoDifferentValidPorts165535)
            portStatusIsSuccess = false
            return
        }
        let wasRunning = state.isEngineRunning
        savingPorts = true
        portStatus = nil
        Task {
            let saved = await state.updatePorts(proxyPort: ports.proxy, uiPort: ports.ui)
            if saved {
                proxyPort = String(state.settings.engine.proxyPort)
                uiPort = String(state.settings.engine.uiPort)
                portStatus = Localization.string(
                    wasRunning
                        ? .onboardingPortsAppliedAndProxyEngineRestarted
                        : .onboardingPortSettingsSaved
                )
                portStatusIsSuccess = true
            } else {
                portStatus = state.lastErrorMessage ?? Localization.string(.onboardingFailedToApplyPortSettings)
                portStatusIsSuccess = false
            }
            savingPorts = false
        }
    }

    private func showWhitelistSaveFeedback() {
        let feedbackID = UUID()
        whitelistSaveFeedbackID = feedbackID
        whitelistSaveFeedback = Localization.string(.settingsCompatibilityDomainsSaved)
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard whitelistSaveFeedbackID == feedbackID else { return }
            whitelistSaveFeedback = nil
            whitelistSaveFeedbackID = nil
        }
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title3.weight(.semibold))
            Text(detail).foregroundStyle(.secondary)
        }
    }

    private func settingsPortRow(
        _ title: String,
        text: Binding<String>,
        focus: FocusField
    ) -> some View {
        HStack {
            Text(title)
                .frame(width: 130, alignment: .leading)
            TextField(Localization.string(.mobilePort), text: text)
                .focused($focusedField, equals: focus)
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
                .onSubmit { applyPorts() }
                .onChange(of: text.wrappedValue) { _ in
                    portStatus = nil
                }
            Spacer()
        }
    }

    private func networkServiceBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: {
                state.selectedNetworkServiceNames.contains(name)
            },
            set: { enabled in
                var selected = Set(state.selectedNetworkServiceNames)
                if enabled { selected.insert(name) } else { selected.remove(name) }
                state.updateSelectedNetworkServices(selected)
            }
        )
    }

    private func pathRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}
