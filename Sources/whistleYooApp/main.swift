import AppKit
import MCP

let isStdioMCP = CommandLine.arguments.contains("--mcp-stdio")
    || URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent == "whistleyoo-mcp"

if isStdioMCP {
    Task { @MainActor in
        do {
            let state = AppStateController()
            _ = await state.launch()
            let backend = MCPToolBackend(state: state)
            let server = await backend.makeServer()
            try await server.start(transport: StdioTransport())
            await server.waitUntilCompleted()
            _ = backend
            Foundation.exit(EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write(Data("whistleyoo-mcp: \(error)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }
    dispatchMain()
} else {
    MainActor.assumeIsolated {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
