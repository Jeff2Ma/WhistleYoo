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
    private var sessionRouter: MCPHTTPSessionRouter?
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
            let sessionRouter = MCPHTTPSessionRouter(state: state)
            self.sessionRouter = sessionRouter

            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            self.group = group
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 64)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline().flatMap {
                        channel.pipeline.addHandler(MCPHTTPHandler(
                            sessionRouter: sessionRouter,
                            bearerToken: token
                        ))
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
        if let sessionRouter {
            await sessionRouter.stop()
        }
        sessionRouter = nil
        if let group {
            try? await group.shutdownGracefully()
        }
        group = nil
        state.setMCPRuntimeState(.stopped)
    }
}

@MainActor
private final class MCPHTTPSessionRouter {
    private final class Session {
        let backend: MCPToolBackend
        let server: Server
        let transport: StatefulHTTPServerTransport
        var lastAccess = Date()

        init(
            backend: MCPToolBackend,
            server: Server,
            transport: StatefulHTTPServerTransport
        ) {
            self.backend = backend
            self.server = server
            self.transport = transport
        }
    }

    private static let maximumSessionCount = 32
    private static let maximumIdleTime: TimeInterval = 24 * 60 * 60

    private let state: AppStateController
    private var sessions: [String: Session] = [:]
    private var isStopped = false

    init(state: AppStateController) {
        self.state = state
    }

    func handle(_ request: MCP.HTTPRequest) async -> MCP.HTTPResponse {
        guard !isStopped else {
            return .error(
                statusCode: 503,
                .internalError("MCP HTTP server is stopping")
            )
        }

        await removeExpiredSessions()

        let method = request.method.uppercased()
        if method == "POST", Self.isInitializationRequest(request.body) {
            guard request.header(HTTPHeaderName.sessionID) == nil else {
                return .error(
                    statusCode: 400,
                    .invalidRequest("Bad Request: Initialize must not include an MCP session ID")
                )
            }
            return await initializeSession(for: request)
        }

        guard let sessionID = request.header(HTTPHeaderName.sessionID) else {
            return .error(
                statusCode: 400,
                .invalidRequest("Bad Request: Missing \(HTTPHeaderName.sessionID) header")
            )
        }
        guard let session = sessions[sessionID] else {
            return .error(
                statusCode: 404,
                .invalidRequest("Not Found: Invalid or expired session ID")
            )
        }

        session.lastAccess = Date()
        let response = await session.transport.handleRequest(request)
        if method == "DELETE", response.statusCode < 400 {
            sessions.removeValue(forKey: sessionID)
            await session.server.stop()
        }
        return response
    }

    func stop() async {
        guard !isStopped else { return }
        isStopped = true

        let activeSessions = Array(sessions.values)
        sessions.removeAll()
        for session in activeSessions {
            await session.server.stop()
        }
    }

    private func initializeSession(for request: MCP.HTTPRequest) async -> MCP.HTTPResponse {
        do {
            let backend = MCPToolBackend(
                state: state,
                client: Self.clientIdentity(from: request)
            )
            let server = await backend.makeServer()
            let transport = StatefulHTTPServerTransport()
            try await server.start(transport: transport)
            let session = Session(backend: backend, server: server, transport: transport)
            let response = await transport.handleRequest(request)

            guard response.statusCode < 400,
                  let sessionID = Self.sessionID(from: response) else {
                await server.stop()
                return response
            }

            guard !isStopped else {
                await server.stop()
                return .error(
                    statusCode: 503,
                    .internalError("MCP HTTP server is stopping")
                )
            }

            await makeRoomForNewSession()
            let replacedSession = sessions.updateValue(session, forKey: sessionID)
            if let replacedSession {
                await replacedSession.server.stop()
            }
            return response
        } catch {
            return .error(
                statusCode: 500,
                .internalError("Could not create MCP session: \(error.localizedDescription)")
            )
        }
    }

    private func makeRoomForNewSession() async {
        guard sessions.count >= Self.maximumSessionCount,
              let oldest = sessions.min(by: { $0.value.lastAccess < $1.value.lastAccess }) else {
            return
        }
        sessions.removeValue(forKey: oldest.key)
        await oldest.value.server.stop()
    }

    private func removeExpiredSessions() async {
        let cutoff = Date().addingTimeInterval(-Self.maximumIdleTime)
        let expired = sessions.filter { $0.value.lastAccess < cutoff }
        for (sessionID, session) in expired {
            sessions.removeValue(forKey: sessionID)
            await session.server.stop()
        }
    }

    nonisolated private static func isInitializationRequest(_ body: Data?) -> Bool {
        guard let body,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return false
        }
        return object["method"] as? String == "initialize"
    }

    nonisolated private static func clientIdentity(
        from request: MCP.HTTPRequest
    ) -> MCPClientIdentity {
        if let body = request.body,
           let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let parameters = object["params"] as? [String: Any],
           let clientInfo = parameters["clientInfo"] as? [String: Any] {
            let identity = MCPClientIdentity(
                reportedName: clientInfo["name"] as? String,
                version: clientInfo["version"] as? String
            )
            if identity.reportedName != nil {
                return identity
            }
        }

        guard let userAgent = request.header("User-Agent")?.lowercased() else {
            return .unknown
        }
        let recognizedName: String?
        if userAgent.contains("codebuddy") || userAgent.contains("coding-copilot") {
            recognizedName = "CodeBuddy"
        } else if userAgent.contains("cursor") {
            recognizedName = "Cursor"
        } else if userAgent.contains("codex") {
            recognizedName = "Codex"
        } else if userAgent.contains("claude") {
            recognizedName = "Claude"
        } else if userAgent.contains("windsurf") {
            recognizedName = "Windsurf"
        } else {
            recognizedName = nil
        }
        return MCPClientIdentity(reportedName: recognizedName, version: nil)
    }

    nonisolated private static func sessionID(from response: MCP.HTTPResponse) -> String? {
        response.headers.first {
            $0.key.caseInsensitiveCompare(HTTPHeaderName.sessionID) == .orderedSame
        }?.value
    }
}

private final class MCPHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let sessionRouter: MCPHTTPSessionRouter
    private let bearerToken: String?
    private var requestHead: HTTPRequestHead?
    private var requestBody: ByteBuffer?
    private var responseStreamTask: Task<Void, Never>?

    init(sessionRouter: MCPHTTPSessionRouter, bearerToken: String?) {
        self.sessionRouter = sessionRouter
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
            let response = await sessionRouter.handle(request)
            eventLoop.execute {
                self.write(response: response, context: loopBoundContext.value)
            }
        }
    }

    private func write(response: MCP.HTTPResponse, context: ChannelHandlerContext) {
        switch response {
        case .stream(let stream, let headers):
            writeStream(
                status: HTTPResponseStatus(statusCode: response.statusCode),
                headers: headers,
                stream: stream,
                context: context
            )
        default:
            write(
                status: HTTPResponseStatus(statusCode: response.statusCode),
                headers: response.headers,
                body: response.bodyData,
                context: context
            )
        }
    }

    private func writeStream(
        status: HTTPResponseStatus,
        headers: [String: String],
        stream: AsyncThrowingStream<Data, Swift.Error>,
        context: ChannelHandlerContext
    ) {
        var responseHeaders = HTTPHeaders()
        for (name, value) in headers {
            responseHeaders.replaceOrAdd(name: name, value: value)
        }
        responseHeaders.remove(name: "Content-Length")
        responseHeaders.replaceOrAdd(name: "Transfer-Encoding", value: "chunked")
        responseHeaders.replaceOrAdd(name: "Connection", value: "keep-alive")
        context.writeAndFlush(
            wrapOutboundOut(.head(.init(
                version: .http1_1,
                status: status,
                headers: responseHeaders
            ))),
            promise: nil
        )

        let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        let eventLoop = context.eventLoop
        responseStreamTask?.cancel()
        responseStreamTask = Task {
            do {
                for try await data in stream {
                    try Task.checkCancellation()
                    try await eventLoop.submit {
                        let context = loopBoundContext.value
                        guard context.channel.isActive else { return }
                        var buffer = context.channel.allocator.buffer(capacity: data.count)
                        buffer.writeBytes(data)
                        context.writeAndFlush(
                            self.wrapOutboundOut(.body(.byteBuffer(buffer))),
                            promise: nil
                        )
                    }.get()
                }
                try await eventLoop.submit {
                    let context = loopBoundContext.value
                    guard context.channel.isActive else { return }
                    context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
                }.get()
            } catch is CancellationError {
                // The HTTP channel closed or began another response.
            } catch {
                eventLoop.execute {
                    let context = loopBoundContext.value
                    if context.channel.isActive {
                        context.close(promise: nil)
                    }
                }
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
        responseStreamTask?.cancel()
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        responseStreamTask?.cancel()
        context.fireChannelInactive()
    }
}
