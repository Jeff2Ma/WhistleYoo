import Foundation
import MCP
import NIOCore
import NIOHTTP1
import NIOPosix
#if canImport(whistleYooCore)
import whistleYooCore
#endif

@MainActor
final class MCPHTTPServerCoordinator {
    private let state: AppStateController
    private let tokenStore: MCPTokenStore
    private var server: Server?
    private var backend: MCPToolBackend?
    private var transport: StatelessHTTPServerTransport?
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?
    private(set) var endpoint: URL?
    private(set) var lastError: String?

    init(state: AppStateController, tokenStore: MCPTokenStore = MCPTokenStore()) {
        self.state = state
        self.tokenStore = tokenStore
    }

    @discardableResult
    func apply(_ settings: MCPSettings) async -> Bool {
        await stop()
        guard settings.enabled else { return true }
        state.setMCPRuntimeState(.starting)

        do {
            let token = settings.authenticationEnabled
                ? try tokenStore.loadOrCreate()
                : nil
            let backend = MCPToolBackend(state: state)
            let server = await backend.makeServer()
            let transport = StatelessHTTPServerTransport()
            try await server.start(transport: transport)
            self.server = server
            self.backend = backend
            self.transport = transport

            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            self.group = group
            let handler = MCPHTTPHandler(transport: transport, bearerToken: token)
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 64)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline().flatMap {
                        channel.pipeline.addHandler(handler)
                    }
                }
                .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .bind(host: "127.0.0.1", port: settings.port)
                .get()

            self.channel = channel
            let endpoint = URL(string: "http://127.0.0.1:\(settings.port)/mcp")!
            self.endpoint = endpoint
            lastError = nil
            state.setMCPRuntimeState(.listening(endpoint))
            return true
        } catch {
            lastError = error.localizedDescription
            await stop()
            state.reportMCPRuntimeFailure(error.localizedDescription)
            return false
        }
    }

    func stop() async {
        endpoint = nil
        if let channel {
            try? await channel.close().get()
        }
        channel = nil
        if let server {
            await server.stop()
        }
        server = nil
        backend = nil
        transport = nil
        if let group {
            try? await group.shutdownGracefully()
        }
        group = nil
        state.setMCPRuntimeState(.stopped)
    }
}

private final class MCPHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let transport: StatelessHTTPServerTransport
    private let bearerToken: String?
    private var requestHead: HTTPRequestHead?
    private var requestBody: ByteBuffer?

    init(transport: StatelessHTTPServerTransport, bearerToken: String?) {
        self.transport = transport
        self.bearerToken = bearerToken
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            requestHead = head
            requestBody = context.channel.allocator.buffer(capacity: 0)
        case .body(var body):
            requestBody?.writeBuffer(&body)
        case .end:
            guard let head = requestHead else {
                write(status: .badRequest, headers: [:], body: nil, context: context)
                return
            }
            let body = requestBody.flatMap { buffer -> Data? in
                Data(buffer.readableBytesView)
            }
            requestHead = nil
            requestBody = nil
            handle(head: head, body: body, context: context)
        }
    }

    private func handle(head: HTTPRequestHead, body: Data?, context: ChannelHandlerContext) {
        guard URLComponents(string: head.uri)?.path == "/mcp" else {
            write(status: .notFound, headers: [:], body: nil, context: context)
            return
        }
        if let bearerToken,
           head.headers.first(name: "Authorization") != "Bearer \(bearerToken)" {
            let data = Data(#"{"error":"unauthorized"}"#.utf8)
            write(
                status: .unauthorized,
                headers: ["Content-Type": "application/json", "WWW-Authenticate": "Bearer"],
                body: data,
                context: context
            )
            return
        }

        var headers: [String: String] = [:]
        for header in head.headers {
            headers[header.name] = header.value
        }
        let request = MCP.HTTPRequest(
            method: head.method.rawValue,
            headers: headers,
            body: body,
            path: "/mcp"
        )
        let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        let eventLoop = context.eventLoop
        Task {
            let response = await transport.handleRequest(request)
            eventLoop.execute {
                self.write(
                    status: HTTPResponseStatus(statusCode: response.statusCode),
                    headers: response.headers,
                    body: response.bodyData,
                    context: loopBoundContext.value
                )
            }
        }
    }

    private func write(
        status: HTTPResponseStatus,
        headers: [String: String],
        body: Data?,
        context: ChannelHandlerContext
    ) {
        var responseHeaders = HTTPHeaders()
        for (name, value) in headers {
            responseHeaders.replaceOrAdd(name: name, value: value)
        }
        responseHeaders.replaceOrAdd(name: "Content-Length", value: String(body?.count ?? 0))
        responseHeaders.replaceOrAdd(name: "Connection", value: "keep-alive")
        context.write(wrapOutboundOut(.head(.init(version: .http1_1, status: status, headers: responseHeaders))), promise: nil)
        if let body, !body.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
