import AppKit
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

    private let state: AppStateController

    init(state: AppStateController) {
        self.state = state
        endpoints = state.localNetworkEndpoints
        selectedEndpointID = state.preferredLocalEndpoint?.id ?? ""
        engineReady = state.isEngineRunning
    }

    var proxyPort: Int { state.settings.engine.proxyPort }

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
        qrImage = nil
        isLoading = false
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
    @ObservedObject var model: MobileSetupViewModel
    let isActive: Bool
    @State private var copiedValue: String?

    var body: some View {
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
        .padding(32)
        .frame(maxWidth: 820, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            if isActive { await model.prepare() }
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
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 190, height: 190)
                    .padding(10)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                    .hairlineRoundedBorder(Color(nsColor: .separatorColor).opacity(0.55), cornerRadius: 8)
            }

            if let url = model.certificateURL {
                copyButton(title: Localization.string(.mobileCopyCertificateUrl), value: url.absoluteString)
            }
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .hairlineRoundedBorder(Color(nsColor: .separatorColor).opacity(0.45), cornerRadius: 12)
    }

    private var setupInstructions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(Localization.string(.mobileMobileSetupSteps), systemImage: "list.number")
                .font(.headline)
            instructionRow(
                number: 1,
                title: Localization.string(.mobileConnectThePhoneToTheSameWiFi),
                detail: Localization.string(.mobileMakeSureThePhoneAndMacAreOnTheSameLocalNetwork)
            )
            Divider()
            instructionRow(
                number: 2,
                title: Localization.string(.mobileSetHttpProxyToManual),
                detail: Localization.string(.mobileEnterTheProxyServerAndPortShownAbove)
            )
            Divider()
            instructionRow(
                number: 3,
                title: Localization.string(.mobileInstallAndTrustTheCertificate),
                detail: Localization.string(.mobileScanTheQrCodeOnTheRightThenEnableTrustInSystemSettings)
            )
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .hairlineRoundedBorder(Color(nsColor: .separatorColor).opacity(0.45), cornerRadius: 12)
    }

    private func informationBlock(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .textSelection(.enabled)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
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
