import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Vision

/// The only file in this repository that touches the real disk.
///
/// Everything above the `VisionStore` seam is proven against an in-memory scope. This is
/// the part that cannot be, so it is kept as thin as it can be: no policy, no
/// formatting, no decisions about what is allowed — those all happen above, and by the
/// time a `ScopedPath` reaches any method here it has already passed the allow-list.
///
/// `PDFKit` appears here only as a rasterizer: a scanned PDF has no text layer, so the
/// only way Vision can read it is a bitmap of each page. This store never reads a PDF's
/// text, outline or metadata — that is `apple-pdf-mcp`'s `PDFStore`, a different
/// protocol in a different repository. See this repository's `CLAUDE.md` for why the
/// two are kept apart rather than merged for convenience.
public struct SystemVisionStore: VisionStore {

    /// Computed rather than stored: `FileManager` is not `Sendable`, so it cannot be
    /// held by a type that is. The shared instance is the only one documented as safe
    /// to use from several threads, and nothing here ever wanted a different one.
    private var fileManager: FileManager { .default }

    public init() {}

    // MARK: - Resolution

    /// Expands `~`, standardises away `.` and `..`, and resolves every symlink.
    ///
    /// A missing leaf is normal enough to tolerate — the same resolution the sibling
    /// filesystem server uses — so it walks up to the deepest ancestor that does exist,
    /// canonicalises that, and re-appends the components below it. Canonicalising only
    /// what exists is what stops a symlinked parent from hiding the real destination
    /// from the scope check.
    public func canonicalise(_ path: String) throws -> CanonicalPath {
        let expanded = (path as NSString).expandingTildeInPath
        // A relative path has no meaning here: the process's working directory is
        // whatever Claude Desktop happened to spawn it in, which is nobody's intent.
        guard expanded.hasPrefix("/") else {
            throw ToolError.badArgument(
                name: "path",
                reason: "'\(path)' is not absolute. Give a full path, or one starting with ~")
        }

        let standardised = URL(fileURLWithPath: expanded).standardizedFileURL
        if fileManager.fileExists(atPath: standardised.path) {
            return CanonicalPath(path: standardised.resolvingSymlinksInPath().path, exists: true)
        }

        var missing: [String] = []
        var ancestor = standardised
        while ancestor.path != "/" {
            missing.append(ancestor.lastPathComponent)
            ancestor = ancestor.deletingLastPathComponent()
            if fileManager.fileExists(atPath: ancestor.path) {
                let resolved = missing.reversed().reduce(ancestor.resolvingSymlinksInPath()) {
                    $0.appendingPathComponent($1)
                }
                return CanonicalPath(path: resolved.path, exists: false)
            }
        }
        return CanonicalPath(path: standardised.path, exists: false)
    }

    // MARK: - Status

    public func probe(_ path: String) -> RootState {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .missing
        }
        guard isDirectory.boolValue else {
            return fileManager.isReadableFile(atPath: path) ? .reachable : .notPermitted
        }
        // The only honest test of a TCC-protected folder is to open it: the path exists
        // and is perfectly visible, and the refusal only arrives on the first read.
        do {
            _ = try fileManager.contentsOfDirectory(atPath: path)
            return .reachable
        } catch {
            return Self.isPermissionError(error) ? .notPermitted : .missing
        }
    }

    // MARK: - Reads

    public func ocr(_ path: ScopedPath, pages: PageRange?, languages: [String]) async throws
        -> OCRContent
    {
        let (source, recognised) = try Self.eachPage(of: path, range: pages) { number, image in
            OCRContent.Page(number: number, lines: try Self.recogniseText(in: image, languages: languages))
        }
        return OCRContent(
            pages: recognised, source: source,
            recognisedLanguages: languages.isEmpty ? ["(Vision's choice)"] : languages)
    }

    public func barcodes(_ path: ScopedPath, pages: PageRange?) async throws -> BarcodeContent {
        let (source, scanned) = try Self.eachPage(of: path, range: pages) { number, image in
            BarcodeContent.Page(
                number: number, pixelWidth: image.width, pixelHeight: image.height,
                barcodes: try Self.detectBarcodes(in: image))
        }
        return BarcodeContent(pages: scanned, source: source)
    }

    // MARK: - Helpers

    /// Loads the file as an image, or as a PDF rendered page by page, and hands each
    /// bitmap to `body` in turn. One bitmap is alive at a time: a long scan rendered up
    /// front would hold every page in memory at once.
    private static func eachPage<Result>(
        of path: ScopedPath, range: PageRange?,
        _ body: (_ number: Int, _ image: CGImage) throws -> Result
    ) throws -> (source: String, results: [Result]) {
        let url = URL(fileURLWithPath: path.path)
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw ToolError.notFound(path: path.path)
        }

        if let document = PDFDocument(url: url), document.pageCount > 0, !document.isLocked {
            let clamped = (range ?? PageRange(first: 1, last: document.pageCount))
                .clamped(to: document.pageCount)
            var results: [Result] = []
            for number in clamped.first...clamped.last {
                guard let page = document.page(at: number - 1), let image = render(page)
                else { continue }
                results.append(try body(number, image))
            }
            return ("pdf", results)
        }

        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else {
            throw ToolError.unreadableImage(path: path.path)
        }
        return ("image", [try body(1, image)])
    }

    /// Every symbology Vision supports, which is its default when none is named.
    private static func detectBarcodes(in image: CGImage) throws -> [BarcodeContent.Barcode] {
        let request = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        return (request.results ?? []).map { observation in
            let box = observation.boundingBox
            return BarcodeContent.Barcode(
                symbology: observation.symbology.rawValue.replacingOccurrences(
                    of: "VNBarcodeSymbology", with: ""),
                payload: observation.payloadStringValue,
                x: Int((box.minX * width).rounded()),
                y: Int(((1 - box.maxY) * height).rounded()),
                width: Int((box.width * width).rounded()),
                height: Int((box.height * height).rounded()))
        }
    }

    /// Renders a PDF page into a bitmap for Vision.
    ///
    /// 2× the page's own size: Vision's accuracy falls off badly below roughly 150 dpi,
    /// and a PDF page is 72 dpi by definition. Drawn onto white because a PDF page has no
    /// background of its own and text on transparency recognises poorly.
    private static func render(_ page: PDFPage, scale: CGFloat = 2.0) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard width > 0, height > 0,
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    private static func recogniseText(in image: CGImage, languages: [String]) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if !languages.isEmpty { request.recognitionLanguages = languages }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == NSFileReadNoPermissionError
                || nsError.code == NSFileWriteNoPermissionError
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == Int(EACCES) || nsError.code == Int(EPERM)
        }
        return false
    }
}
