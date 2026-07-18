import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Network
import SwiftUI
#if canImport(whistleYooCore)
import whistleYooCore
#endif

final class MobileCertificateServer {
    enum ServerError: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .failed(let message): return appLocalizedFormat("无法启动手机证书服务：%@", message)
            }
        }
    }

    private let queue = DispatchQueue(label: "com.devework.whistleyoo.mobile-certificate")
    private var listener: NWListener?
    private var certificateData = Data()

    func start(certificateData: Data) async throws -> UInt16 {
        stop()
        self.certificateData = certificateData
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    guard let port = listener.port else {
                        continuation.resume(throwing: ServerError.failed(appLocalized("没有获得监听端口")))
                        return
                    }
                    continuation.resume(returning: port.rawValue)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: ServerError.failed(error.localizedDescription))
                case .cancelled:
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: ServerError.failed(appLocalized("服务已取消")))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, error in
            guard let self else {
                connection.cancel()
                return
            }
            guard error == nil,
                  let data,
                  let request = String(data: data, encoding: .utf8),
                  request.hasPrefix("GET /rootCA.crt ") else {
                self.sendNotFound(to: connection)
                return
            }
            let headers = [
                "HTTP/1.1 200 OK",
                "Content-Type: application/x-x509-ca-cert",
                "Content-Disposition: attachment; filename=WhistleYoo-rootCA.crt",
                "Cache-Control: no-store",
                "Content-Length: \(self.certificateData.count)",
                "Connection: close",
                "",
                ""
            ].joined(separator: "\r\n")
            var response = Data(headers.utf8)
            response.append(self.certificateData)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func sendNotFound(to connection: NWConnection) {
        let body = Data("Not Found".utf8)
        let headers = [
            "HTTP/1.1 404 Not Found",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Length: \(body.count)",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        var response = Data(headers.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

@MainActor
final class MobileSetupViewModel: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var endpoints: [LocalNetworkEndpoint] = []
    @Published private(set) var selectedEndpointID = ""
    @Published private(set) var serverPort: UInt16?
    @Published private(set) var qrImage: NSImage?
    @Published private(set) var engineReady = false

    private let state: AppStateController
    private let server = MobileCertificateServer()

    init(state: AppStateController) {
        self.state = state
        endpoints = state.localNetworkEndpoints
        selectedEndpointID = state.preferredLocalEndpoint?.id ?? ""
        engineReady = state.isEngineRunning
    }

    var proxyPort: Int { state.settings.engine.proxyPort }

    var hasCachedConfiguration: Bool {
        engineReady && !endpoints.isEmpty && serverPort != nil && qrImage != nil
    }

    var selectedEndpoint: LocalNetworkEndpoint? {
        endpoints.first { $0.id == selectedEndpointID }
    }

    var certificateURL: URL? {
        guard let address = selectedEndpoint?.address, let serverPort else { return nil }
        return URL(string: "http://\(address):\(serverPort)/rootCA.crt")
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
        let refreshedEndpoints = state.localNetworkEndpoints
        guard !refreshedEndpoints.isEmpty else {
            isLoading = false
            errorMessage = appLocalized("没有检测到可供手机连接的局域网 IPv4 地址")
            return
        }
        endpoints = refreshedEndpoints
        selectedEndpointID = endpoints.contains(where: { $0.id == previousEndpointID })
            ? previousEndpointID
            : (state.preferredLocalEndpoint?.id ?? "")
        engineReady = state.isEngineRunning

        guard engineReady else {
            isLoading = false
            return
        }
        do {
            let certificate = try await state.certificateData()
            serverPort = try await server.start(certificateData: certificate)
            updateQRCode()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func startAndPrepare() async {
        isLoading = true
        errorMessage = nil
        engineReady = await state.startEngine()
        guard engineReady else {
            isLoading = false
            errorMessage = state.lastErrorMessage ?? appLocalized("代理引擎启动失败")
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
        server.stop()
        serverPort = nil
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
                    Text("手机代理配置")
                        .font(.title2.weight(.semibold))
                    Text("手机与 Mac 需要连接同一个局域网")
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
                    Button("重试") { Task { await model.prepare() } }
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else if !model.engineReady && !model.isLoading {
                Spacer()
                VStack(spacing: 14) {
                    Image(systemName: "network.slash")
                        .font(.system(size: 38))
                        .foregroundStyle(.secondary)
                    Text("需要启动代理引擎")
                        .font(.title3.weight(.semibold))
                    Text("启动后才能准备手机代理地址和 HTTPS 根证书。")
                        .foregroundStyle(.secondary)
                    Button("启动引擎并准备配置") {
                        Task { await model.startAndPrepare() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else if model.isLoading {
                Spacer()
                ProgressView("正在准备手机代理配置…")
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
                Label("当前选择的是虚拟网卡，手机可能无法访问。建议选择 Wi-Fi 或当前默认网络。", systemImage: "exclamationmark.triangle.fill")
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
                Label("代理信息", systemImage: "network")
                    .font(.headline)
                Spacer()
                Label("代理服务已监听", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
            }

            HStack(spacing: 12) {
                Text("当前网络")
                    .foregroundStyle(.secondary)
                Picker("网络接口", selection: Binding(
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
                informationBlock(title: "代理服务器", value: model.selectedEndpoint?.address ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
                informationBlock(title: "端口", value: String(model.proxyPort))
                    .frame(width: 116, alignment: .leading)
            }

            copyButton(title: "复制代理信息", value: model.proxyAddress)
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .hairlineRoundedBorder(Color(nsColor: .separatorColor).opacity(0.45), cornerRadius: 12)
    }

    private var certificatePanel: some View {
        VStack(spacing: 14) {
            Label("安装 HTTPS 根证书", systemImage: "checkmark.shield")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("扫描二维码，在手机上下载并安装根证书。")
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
                copyButton(title: "复制证书地址", value: url.absoluteString)
            }
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .hairlineRoundedBorder(Color(nsColor: .separatorColor).opacity(0.45), cornerRadius: 12)
    }

    private var setupInstructions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("手机配置步骤", systemImage: "list.number")
                .font(.headline)
            instructionRow(
                number: 1,
                title: "手机连接相同 Wi-Fi",
                detail: "确保手机与 Mac 位于同一个局域网"
            )
            Divider()
            instructionRow(
                number: 2,
                title: "HTTP 代理选择“手动”",
                detail: "服务器和端口填写上方代理信息"
            )
            Divider()
            instructionRow(
                number: 3,
                title: "安装并信任证书",
                detail: "扫描右侧二维码，安装后在系统设置中开启信任"
            )
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .hairlineRoundedBorder(Color(nsColor: .separatorColor).opacity(0.45), cornerRadius: 12)
    }

    private func informationBlock(title: LocalizedStringKey, value: String) -> some View {
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
        title: LocalizedStringKey,
        detail: LocalizedStringKey
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

    private func copyButton(title: LocalizedStringKey, value: String) -> some View {
        Button {
            copy(value)
        } label: {
            Label(
                copiedValue == value ? "已复制" : title,
                systemImage: copiedValue == value ? "checkmark" : "doc.on.doc"
            )
            .frame(maxWidth: .infinity)
            .frame(minHeight: 26)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private func endpointOptionTitle(_ endpoint: LocalNetworkEndpoint) -> String {
        var suffix = endpoint.isDefaultRoute ? appLocalized(" · 推荐") : ""
        if endpoint.isVirtual { suffix += appLocalized(" · 虚拟网卡") }
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
