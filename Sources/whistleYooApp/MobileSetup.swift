import AppKit
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
#if canImport(whistleYooCore)
import whistleYooCore
#endif

@MainActor
final class MobileSetupViewModel: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var endpoints: [LocalNetworkEndpoint] = []
    @Published private(set) var selectedEndpointID = ""
    @Published private(set) var qrImage: NSImage?
    @Published private(set) var engineReady = false
    @Published private(set) var proxyPort: Int

    private let state: AppStateController
    private var cancellables: Set<AnyCancellable> = []
    private var refreshTask: Task<Void, Never>?
    private var isActive = false

    init(state: AppStateController) {
        self.state = state
        endpoints = state.localNetworkEndpoints
        selectedEndpointID = state.preferredLocalEndpoint?.id ?? ""
        engineReady = state.isEngineRunning
        proxyPort = state.settings.engine.proxyPort
        observeState()
    }

    var hasCachedConfiguration: Bool {
        engineReady && !endpoints.isEmpty && qrImage != nil
    }

    var selectedEndpoint: LocalNetworkEndpoint? {
        endpoints.first { $0.id == selectedEndpointID }
    }

    var certificateURL: URL? {
        guard let address = selectedEndpoint?.address else { return nil }
        return state.settings.engine.mobileRootCertificateURL(host: address)
    }

    var proxyAddress: String {
        guard let address = selectedEndpoint?.address else { return "" }
        return "\(address):\(proxyPort)"
    }

    func prepare() async {
        isActive = true
        startMonitoring()
        let isShowingCachedConfiguration = hasCachedConfiguration
        isLoading = !isShowingCachedConfiguration
        errorMessage = nil
        let previousEndpointID = selectedEndpointID
        await state.refreshNetworkServices()
        endpoints = state.localNetworkEndpoints
        engineReady = state.isEngineRunning
        guard !endpoints.isEmpty else {
            selectedEndpointID = ""
            qrImage = nil
            isLoading = false
            errorMessage = Localization.string(.mobileNoLocalIpv4AddressAvailableToMobileDevicesWasDetected)
            return
        }
        selectedEndpointID = endpoints.contains(where: { $0.id == previousEndpointID })
            ? previousEndpointID
            : (state.preferredLocalEndpoint?.id ?? endpoints[0].id)

        guard engineReady else {
            qrImage = nil
            isLoading = false
            return
        }
        updateQRCode()
        isLoading = false
    }

    func startAndPrepare() async {
        isLoading = true
        errorMessage = nil
        engineReady = await state.startEngine()
        guard engineReady else {
            isLoading = false
            errorMessage = state.lastErrorMessage ?? Localization.string(.mobileFailedToStartTheProxyEngine)
            return
        }
        await prepare()
    }

    func selectEndpoint(_ id: String) {
        selectedEndpointID = id
        state.selectLocalNetworkEndpoint(id: id)
        updateQRCode()
    }

    func stop() {
        isActive = false
        refreshTask?.cancel()
        refreshTask = nil
        qrImage = nil
        isLoading = false
    }

    private func observeState() {
        state.$engineState
            .sink { [weak self] engineState in
                guard let self else { return }
                if case .running = engineState {
                    self.engineReady = true
                    if self.isActive { self.updateQRCode() }
                } else {
                    self.engineReady = false
                    self.qrImage = nil
                }
            }
            .store(in: &cancellables)

        state.$localNetworkEndpoints
            .sink { [weak self] endpoints in
                guard let self else { return }
                self.endpoints = endpoints
                if endpoints.isEmpty, self.isActive {
                    self.errorMessage = Localization.string(
                        .mobileNoLocalIpv4AddressAvailableToMobileDevicesWasDetected
                    )
                } else if !endpoints.isEmpty {
                    self.errorMessage = nil
                }
                if !endpoints.contains(where: { $0.id == self.selectedEndpointID }) {
                    self.selectedEndpointID = self.state.preferredLocalEndpoint?.id
                        ?? endpoints.first?.id
                        ?? ""
                }
                if self.isActive && self.engineReady {
                    self.updateQRCode()
                }
            }
            .store(in: &cancellables)

        state.$selectedLocalEndpointID
            .sink { [weak self] selectedID in
                guard let self else { return }
                self.selectedEndpointID = selectedID
                    ?? self.state.preferredLocalEndpoint?.id
                    ?? ""
                if self.isActive && self.engineReady {
                    self.updateQRCode()
                }
            }
            .store(in: &cancellables)

        state.$settings
            .map(\.engine.proxyPort)
            .removeDuplicates()
            .sink { [weak self] proxyPort in
                guard let self else { return }
                self.proxyPort = proxyPort
                if self.isActive && self.engineReady {
                    self.updateQRCode()
                }
            }
            .store(in: &cancellables)
    }

    private func startMonitoring() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled, self.isActive else { return }
                await self.state.refreshNetworkServices()
            }
        }
    }

    private func updateQRCode() {
        guard let value = certificateURL?.absoluteString else {
            qrImage = nil
            return
        }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else {
            qrImage = nil
            return
        }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 9, y: 9))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        image.isTemplate = false
        qrImage = image
    }
}

struct MobileSetupView: View {
    enum SetupPlatform: String, CaseIterable, Identifiable {
        case ios = "iOS"
        case android = "Android"
        var id: Self { self }

        var icon: String {
            switch self {
            case .ios: return "apple.logo"
            case .android: return "phone.fill"
            }
        }
    }

    @ObservedObject var model: MobileSetupViewModel
    let isActive: Bool
    @State private var copiedValue: String?
    @State private var selectedPlatform: SetupPlatform = .ios
    @State private var isShowingEnlargedQR = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 12) {
                        Image(systemName: "iphone.and.arrow.forward")
                            .font(.system(size: 24))
                            .foregroundStyle(.blue)
                            .frame(width: 42, height: 42)
                            .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(Localization.string(.mobileMobileProxySetup))
                                .font(.title2.weight(.semibold))
                            Text(Localization.string(.mobileTheMobileDeviceAndMacMustBeOnTheSameLocalNetwork))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    if model.hasCachedConfiguration {
                        configurationContent
                    } else if let error = model.errorMessage, !model.isLoading {
                        Spacer()
                        VStack(spacing: 14) {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                            Button(Localization.string(.mobileRetry)) { Task { await model.prepare() } }
                        }
                        .frame(maxWidth: .infinity)
                        Spacer()
                    } else if !model.engineReady && !model.isLoading {
                        Spacer()
                        VStack(spacing: 14) {
                            Image(systemName: "network.slash")
                                .font(.system(size: 38))
                                .foregroundStyle(.secondary)
                            Text(Localization.string(.mobileProxyEngineRequired))
                                .font(.title3.weight(.semibold))
                            Text(Localization.string(.mobileStartTheEngineToPrepareTheMobileProxyAddressAndHttpsRootCert))
                                .foregroundStyle(.secondary)
                            Button(Localization.string(.mobileStartEngineAndPrepareSetup)) {
                                Task { await model.startAndPrepare() }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }
                        .frame(maxWidth: .infinity)
                        Spacer()
                    } else if model.isLoading {
                        Spacer()
                        ProgressView(Localization.string(.mobilePreparingMobileProxySetup))
                            .frame(maxWidth: .infinity)
                        Spacer()
                    }
                }
                .frame(
                    minHeight: max(0, geometry.size.height - 64),
                    alignment: .top
                )
                .padding(32)
                .frame(maxWidth: 820, alignment: .top)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollIndicators(.automatic)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            if isActive { await model.prepare() }
        }
        .onDisappear {
            model.stop()
        }
        .sheet(isPresented: $isShowingEnlargedQR) {
            enlargedQRModal
        }
    }

    private var configurationContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if model.selectedEndpoint?.isVirtual == true {
                Label(Localization.string(.mobileTheSelectedInterfaceIsVirtualAndMayNotBeReachableFromYourPho), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 18) {
                    proxyInformation
                    setupInstructions
                }
                    .frame(maxWidth: .infinity, alignment: .leading)
                certificatePanel
                    .frame(width: 300)
            }
        }
    }

    private var proxyInformation: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(Localization.string(.mobileProxyInformation), systemImage: "network")
                    .font(.headline)
                Spacer()
                Label(Localization.string(.mobileProxyServiceIsListening), systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
            }

            HStack(spacing: 12) {
                Text(Localization.string(.mobileCurrentNetwork))
                    .foregroundStyle(.secondary)
                Picker(Localization.string(.mobileNetworkInterface), selection: Binding(
                    get: { model.selectedEndpointID },
                    set: { model.selectEndpoint($0) }
                )) {
                    ForEach(model.endpoints) { endpoint in
                        Text(endpointOptionTitle(endpoint)).tag(endpoint.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityLabel(Localization.string(.mobileNetworkInterface))
                Spacer()
            }

            HStack(spacing: 12) {
                informationBlock(title: Localization.string(.mobileProxyServer), value: model.selectedEndpoint?.address ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
                informationBlock(title: Localization.string(.mobilePort), value: String(model.proxyPort))
                    .frame(width: 116, alignment: .leading)
            }

            copyButton(title: Localization.string(.mobileCopyProxyInfo), value: model.proxyAddress)
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .hairlineRoundedBorder(Color(nsColor: .separatorColor).opacity(0.45), cornerRadius: 12)
    }

    private var certificatePanel: some View {
        VStack(spacing: 14) {
            Label(Localization.string(.mobileInstallHttpsRootCertificate), systemImage: "checkmark.shield")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(Localization.string(.mobileTheQrCodeUsesWhistleSOfficialCertificateUrlOnTheSamePortAs))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let image = model.qrImage {
                Button {
                    isShowingEnlargedQR = true
                } label: {
                    ZStack(alignment: .bottomTrailing) {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 190, height: 190)
                            .padding(10)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                            .hairlineRoundedBorder(Color(nsColor: .separatorColor).opacity(0.55), cornerRadius: 8)

                        Label(Localization.string(.mobileClickToEnlargeQr), systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.68), in: Capsule())
                            .padding(8)
                    }
                }
                .buttonStyle(.plain)
                .help(Localization.string(.mobileClickToEnlargeQr))
            }

            if let url = model.certificateURL {
                VStack(spacing: 8) {
                    copyButton(title: Localization.string(.mobileCopyCertificateUrl), value: url.absoluteString)

                    Button {
                        shareCertificateFile(url: url)
                    } label: {
                        Label(Localization.string(.mobileShareCertificate), systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 26)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help(Localization.string(.mobileShareCertificate))
                }
            }
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .hairlineRoundedBorder(Color(nsColor: .separatorColor).opacity(0.45), cornerRadius: 12)
    }

    private var setupInstructions: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(Localization.string(.mobileMobileSetupSteps), systemImage: "list.number")
                    .font(.headline)
                Spacer()
                Picker("", selection: $selectedPlatform) {
                    ForEach(SetupPlatform.allCases) { platform in
                        Text(platform.rawValue).tag(platform)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }

            instructionRow(
                number: 1,
                title: Localization.string(.mobileConnectThePhoneToTheSameWiFi),
                detail: Localization.string(.mobileMakeSureThePhoneAndMacAreOnTheSameLocalNetwork)
            )
            HairlineDivider()
            instructionRow(
                number: 2,
                title: Localization.string(.mobileSetHttpProxyToManual),
                detail: Localization.string(.mobileEnterTheProxyServerAndPortShownAbove)
            )
            HairlineDivider()

            if selectedPlatform == .ios {
                instructionRow(
                    number: 3,
                    title: Localization.string(.mobileInstallAndTrustTheCertificate),
                    detail: "1. 扫码在 Safari 下载描述文件并安装\n2. 前往系统设置 -> 通用 -> 关于本机 -> 证书信任设置 -> 开启全信任"
                )
            } else {
                instructionRow(
                    number: 3,
                    title: Localization.string(.mobileInstallAndTrustTheCertificate),
                    detail: "1. 扫码或在手机浏览器中打开 URL 下载 CA 根证书文件\n2. 前往系统设置 -> 安全 -> 加密与凭据 -> 安装 CA 证书"
                )
            }
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .hairlineRoundedBorder(Color(nsColor: .separatorColor).opacity(0.45), cornerRadius: 12)
    }

    private var enlargedQRModal: some View {
        VStack(spacing: 20) {
            HStack {
                Text(Localization.string(.mobileInstallHttpsRootCertificate))
                    .font(.title3.weight(.bold))
                Spacer()
                Button {
                    isShowingEnlargedQR = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if let image = model.qrImage {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 320, height: 320)
                    .padding(14)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                    .hairlineRoundedBorder(Color.primary.opacity(0.12), cornerRadius: 12)
            }

            if let url = model.certificateURL {
                Text(url.absoluteString)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)

                HStack(spacing: 12) {
                    copyButton(title: Localization.string(.mobileCopyCertificateUrl), value: url.absoluteString)
                    Button {
                        isShowingEnlargedQR = false
                    } label: {
                        Text(Localization.string(.rulesDone))
                            .frame(minWidth: 80)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func informationBlock(title: String, value: String) -> some View {
        Button {
            copy(value)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.primary)
                }
                Spacer(minLength: 4)
                Image(systemName: copiedValue == value ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12))
                    .foregroundStyle(copiedValue == value ? Color.green : Color.secondary)
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .help(Localization.string(.mobileCopy))
    }

    private func instructionRow(
        number: Int,
        title: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(number))
                .font(.callout.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func copyButton(title: String, value: String) -> some View {
        Button {
            copy(value)
        } label: {
            Label(
                copiedValue == value ? Localization.string(.mobileCopied) : title,
                systemImage: copiedValue == value ? "checkmark" : "doc.on.doc"
            )
            .frame(maxWidth: .infinity)
            .frame(minHeight: 26)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private func endpointOptionTitle(_ endpoint: LocalNetworkEndpoint) -> String {
        var suffix = endpoint.isDefaultRoute ? Localization.string(.mobileRecommendedSuffix) : ""
        if endpoint.isVirtual { suffix += Localization.string(.mobileVirtual) }
        return "\(endpoint.displayName) · \(endpoint.address)\(suffix)"
    }

    private func shareCertificateFile(url: URL) {
        Task {
            let tempDir = FileManager.default.temporaryDirectory
            let certFile = tempDir.appendingPathComponent("whistle_rootCA.crt")
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                try data.write(to: certFile, options: .atomic)
                let picker = NSSharingServicePicker(items: [certFile])
                if let window = NSApp.keyWindow {
                    picker.show(relativeTo: .zero, of: window.contentView ?? NSView(), preferredEdge: .minY)
                }
            } catch {
                copy(url.absoluteString)
            }
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedValue = value
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            if copiedValue == value { copiedValue = nil }
        }
    }
}
