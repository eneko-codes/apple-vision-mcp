import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import MCP
import Testing
import UniformTypeIdentifiers

@testable import VisionMCPCore

/// Formatting and routing, against a store that returns canned content.
@Suite("Barcode formatting and routing")
struct BarcodeFormattingTests {

    private struct CannedStore: VisionStore {
        let content: BarcodeContent

        func canonicalise(_ path: String) throws -> CanonicalPath {
            CanonicalPath(path: path, exists: true)
        }
        func probe(_ path: String) -> RootState { .reachable }
        func ocr(_ path: ScopedPath, pages: PageRange?, languages: [String]) async throws
            -> OCRContent
        {
            throw ToolError.storeFailure("not used")
        }
        func barcodes(_ path: ScopedPath, pages: PageRange?) async throws -> BarcodeContent {
            content
        }
    }

    private let sample = BarcodeContent(
        pages: [
            .init(
                number: 1, pixelWidth: 400, pixelHeight: 300,
                barcodes: [
                    .init(symbology: "QR", payload: "ACME-REF-000123", x: 10, y: 20, width: 100, height: 100),
                    .init(symbology: "Code128", payload: nil, x: 150, y: 200, width: 200, height: 40),
                ])
        ],
        source: "image")

    @Test("Each code is listed with symbology, payload and a top-left pixel box")
    func formatsCodes() {
        let text = Format().barcodes(sample, path: "/invented/ticket.png")
        #expect(text.contains("barcodes 2"))
        #expect(text.contains("QR"))
        #expect(text.contains("ACME-REF-000123"))
        #expect(text.contains("x=10 y=20 w=100 h=100"))
        #expect(text.contains("(bytes that are not text)"))
        #expect(text.contains("image 400×300 px"))
    }

    @Test("An empty result says so instead of returning nothing")
    func formatsEmpty() {
        let empty = BarcodeContent(
            pages: [.init(number: 1, pixelWidth: 10, pixelHeight: 10, barcodes: [])],
            source: "image")
        #expect(Format().barcodes(empty, path: "/invented/blank.png").contains("no barcode"))
    }

    @Test("The tool is routed, scoped and rendered")
    func routesThroughTheScope() async {
        var configuration = Configuration()
        configuration.readRoots = ["/invented"]
        let tools = VisionTools(store: CannedStore(content: sample), configuration: configuration)

        let inside = await tools.handle(
            .init(name: "vision_barcodes", arguments: ["path": .string("/invented/ticket.png")]))
        #expect(inside.isError == false)

        let outside = await tools.handle(
            .init(name: "vision_barcodes", arguments: ["path": .string("/elsewhere/ticket.png")]))
        #expect(outside.isError == true)
    }
}

/// Real Vision over images made here, from nothing, inside a directory this suite creates
/// under `$TMPDIR` and removes before it returns. No file of the owner's is involved.
@Suite("Barcode detection on synthetic images")
struct BarcodeDetectionTests {

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "apple-vision-mcp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A barcode drawn black on white with a generous margin; Vision needs a quiet zone
    /// and the generators do not add one.
    /// `extraTop` pushes the code down the canvas, so a box measured from the wrong corner
    /// cannot pass by landing near the same place.
    private func render(
        _ filter: CIFilter, scale: CGFloat, margin: Int = 60, extraTop: Int = 0
    ) throws -> CGImage {
        let output = try #require(filter.outputImage)
        let context = CIContext()
        let code = try #require(
            context.createCGImage(
                output.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
                from: output.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).extent))
        let width = code.width + margin * 2
        let height = code.height + margin * 2 + extraTop
        let canvas = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        canvas.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
        canvas.interpolationQuality = .none
        canvas.draw(code, in: CGRect(x: margin, y: margin, width: code.width, height: code.height))
        return try #require(canvas.makeImage())
    }

    private func qr(_ message: String, extraTop: Int = 0) throws -> CGImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(message.utf8)
        return try render(filter, scale: 8, extraTop: extraTop)
    }

    private func code128(_ message: String) throws -> CGImage {
        let filter = CIFilter.code128BarcodeGenerator()
        filter.message = Data(message.utf8)
        return try render(filter, scale: 4)
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func writePDF(_ image: CGImage, to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.draw(image, in: box)
        context.endPDFPage()
        context.closePDF()
    }

    private func call(_ file: URL, in directory: URL) async -> CallTool.Result {
        var configuration = Configuration()
        configuration.readRoots = [directory.path]
        let tools = VisionTools(store: SystemVisionStore(), configuration: configuration)
        return await tools.handle(
            .init(name: "vision_barcodes", arguments: ["path": .string(file.path)]))
    }

    private func text(_ result: CallTool.Result) -> String {
        result.content.compactMap {
            if case .text(let text, _, _) = $0 { return text }
            return nil
        }.joined()
    }

    @Test("A QR code in a PNG is decoded with its payload and a box inside the image")
    func decodesQRInAnImage() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("qr.png")
        try writePNG(try qr("ACME-REF-000123", extraTop: 300), to: file)

        let result = await call(file, in: directory)
        #expect(result.isError == false)
        let output = text(result)
        #expect(output.contains("source   image"))
        #expect(output.contains("QR"))
        #expect(output.contains("ACME-REF-000123"))

        // 300 px of empty canvas sit above the 60 px margin, so in top-left pixels the
        // code's top edge is near y=360; measured from the bottom it would be near 60.
        let match = try #require(output.firstMatch(of: /x=(\d+) y=(\d+) w=(\d+) h=(\d+)/))
        let y = try #require(Int(match.2))
        #expect((340...400).contains(y), "y=\(y) is not measured from the top-left")
    }

    @Test("A Code 128 barcode is decoded and named")
    func decodesCode128() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("linear.png")
        try writePNG(try code128("REF000123"), to: file)

        let output = text(await call(file, in: directory))
        #expect(output.contains("Code128"))
        #expect(output.contains("REF000123"))
    }

    @Test("A QR code on a PDF page is rendered and decoded")
    func decodesQRInAPDF() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("scan.pdf")
        try writePDF(try qr("ACME-PDF-000456"), to: file)

        let output = text(await call(file, in: directory))
        #expect(output.contains("source   pdf"))
        #expect(output.contains("ACME-PDF-000456"))
    }

    @Test("An image with no code yields an explicit empty answer, not an error")
    func blankImageHasNoCode() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("blank.png")
        let canvas = try #require(
            CGContext(
                data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        canvas.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        try writePNG(try #require(canvas.makeImage()), to: file)

        let result = await call(file, in: directory)
        #expect(result.isError == false)
        #expect(text(result).contains("no barcode"))
    }

    @Test("A file that is not an image is refused with the decoding error")
    func notAnImage() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("notes.txt")
        try Data("plain text".utf8).write(to: file)

        let result = await call(file, in: directory)
        #expect(result.isError == true)
        #expect(text(result).contains("could not be decoded"))
    }
}

/// The version lives in three files; a build that disagrees with itself produces bug
/// reports about a binary nobody has.
@Suite("Version agreement")
struct VersionTests {

    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test("Manifest, server constant and Info.plist carry the same version")
    func versionsAgree() throws {
        let manifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("extension/manifest.json")))
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: root.appendingPathComponent("Resources/Info.plist")),
            format: nil)
        let manifestVersion = (manifest as? [String: Any])?["version"] as? String
        let plistVersion = (plist as? [String: Any])?["CFBundleShortVersionString"] as? String
        #expect(manifestVersion == VisionMCPServer.version)
        #expect(plistVersion == VisionMCPServer.version)
    }

    @Test("Every catalogue tool is declared in the manifest")
    func manifestListsEveryTool() throws {
        let manifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("extension/manifest.json")))
        let declared = ((manifest as? [String: Any])?["tools"] as? [[String: Any]] ?? [])
            .compactMap { $0["name"] as? String }
        #expect(Set(declared) == Set(ToolCatalog.all().map(\.name)))
    }
}
