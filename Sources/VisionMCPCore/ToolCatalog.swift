import Foundation
import MCP

/// The catalogue is the authorisation surface: a tool that is not listed here cannot be
/// called, and the name it is listed under is the label on the permission switch in
/// Claude Desktop.
public enum ToolCatalog {

    public static let statusName = "vision_status"
    public static let ocrName = "vision_ocr"

    public static func all() -> [Tool] {
        [status, ocr]
    }

    // MARK: Schema helpers

    private static func object(properties: [String: Value], required: [String] = []) -> Value {
        var schema: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        schema["additionalProperties"] = .bool(false)
        return .object(schema)
    }

    /// `type` is the single string `"string"`, never `["string", "null"]`. Claude
    /// Desktop's schema sanitiser drops a property whose `type` is a union and hands the
    /// model a bare `{}` in its place.
    private static func string(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func integer(
        _ description: String, minimum: Int, maximum: Int, default def: Int
    ) -> Value {
        .object([
            "type": .string("integer"), "description": .string(description),
            "minimum": .int(minimum), "maximum": .int(maximum), "default": .int(def),
        ])
    }

    private static func stringArray(_ description: String) -> Value {
        .object([
            "type": .string("array"),
            "items": .object(["type": .string("string")]),
            "description": .string(description),
        ])
    }

    private static let pathHelp = """
        Absolute path, or one starting with ~. It is canonicalised — ~ expanded, .. \
        removed, symlinks followed — and then checked against the configured folders \
        before anything happens.
        """

    // MARK: Tools

    static let status = Tool(
        name: statusName,
        title: "Vision scope and permissions",
        description: """
            Reports which folders this server may read and whether macOS is actually \
            letting it reach them. Reads no file contents.

            Call it first in any session that will run OCR, and again whenever \
            vision_ocr fails: it separates "outside the configured scope" from "macOS \
            refused", which are two different problems with two different fixes.
            """,
        inputSchema: object(properties: [:]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let ocr = Tool(
        name: ocrName,
        title: "Read text out of an image or a scan",
        description: """
            Runs Vision's text recognition over an image (PNG, JPEG, HEIC, TIFF…) or over a \
            PDF, rendering each page first. Returns the recognised lines in reading order.

            This is the tool for a scanned document, a screenshot, or a photograph of a \
            receipt. It is much slower than reading a PDF's own text layer and less \
            accurate than one, so for a PDF try apple-pdf-mcp's pdf_read tool first — it \
            will tell you when the file is a scan with nothing else to extract.

            Recognition is Vision's; the lines come back as it found them, with no \
            correction or reordering applied here.
            """,
        inputSchema: object(
            properties: [
                "path": string("Image or PDF to read. \(pathHelp)"),
                "languages": stringArray(
                    """
                    BCP-47 language codes in preference order, for example \
                    ["es-ES","en-US"]. Omit to let Vision choose. Naming the right language \
                    markedly improves accuracy on accented text.
                    """),
                "first_page": integer(
                    "First page to recognise, 1-based and inclusive. Omit for page 1. "
                        + "PDFs only.",
                    minimum: 1, maximum: 10_000, default: 1),
                "last_page": integer(
                    "Last page to recognise, 1-based and inclusive. Omit for the last "
                        + "page. PDFs only.",
                    minimum: 1, maximum: 10_000, default: 10_000),
            ],
            required: ["path"]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )
}
