import Foundation
import MCP

public enum VisionMCPServer {

    public static let name = "apple-vision-mcp"
    public static let version = "1.0.0"

    /// Returned from `initialize`. It carries what per-tool descriptions cannot state
    /// once: the allow-list, and the boundary with the sibling PDF server.
    public static let instructions = """
        Runs Vision's text recognition on this Mac. No Finder, no Apple events, no \
        network.

        ONE SCOPE. A list of folders that may be READ, chosen by the person who installed \
        the extension. Every path is canonicalised — ~ expanded, .. removed, symlinks \
        followed — and then checked against that list before anything happens. A path \
        outside it is refused and the error names the configured scope. Call \
        vision_status first: it reports the list and whether macOS is actually letting \
        this process reach it.

        vision_ocr accepts an image (PNG, JPEG, HEIC, TIFF…) or a PDF. For a PDF it \
        renders each page to a bitmap first — PDFKit is used here only to turn a page \
        into pixels, never to read the PDF's own text, outline or metadata. That is \
        apple-pdf-mcp's job: its pdf_read tool is faster and more accurate whenever a PDF \
        actually has a text layer, and it says explicitly when one does not. Try pdf_read \
        first on any PDF; vision_ocr is what reads the scan pdf_read cannot.

        This server never writes anything and has no delete of any kind.
        """

    /// The store is a parameter so the whole server can be driven by a double. Nothing in
    /// this function opens a file by itself.
    public static func run(
        store: any VisionStore = SystemVisionStore(),
        configuration: Configuration = Configuration()
    ) async throws {
        let tools = VisionTools(store: store, configuration: configuration)
        let server = Server(
            name: name,
            version: version,
            instructions: instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in .init(tools: ToolCatalog.all()) }
        await server.withMethodHandler(CallTool.self) { await tools.handle($0) }

        // The default StdioTransport logger is a no-op handler. Leave it that way: a
        // logger writing to stdout would interleave with the JSON-RPC stream and break
        // every response after the first log line.
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }
}
